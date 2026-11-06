#include "economy_cost_probe.h"
#include "economy_runtime.h"
#include "economy_hash.h"
#include "runtime_switch_registry.h"
#include "economy_graph_kernels.h"
#include "economy_graph_live_ops.h"
#include "economy_graph_stage_dispatch.h"
#include "runtime_economy_pod.h"
#include "native_simulation_host.h"
#include "economy_runtime_variant_helpers.h"
#include "parallel_dispatcher.h"
#include "pk_log.h"

#include <algorithm>
#include <array>
#include <cassert>
#include <chrono>
#include <charconv>
#include <cmath>
#include <cstdlib>
#include <cstring>
#include <iterator>
#include <limits>
#include <map>
#include <numeric>
#include <tuple>
#include <type_traits>
#include <unordered_map>
#include <unordered_set>

#if defined(_MSC_VER) && defined(_M_X64)
#include <intrin.h>
#endif

#include <godot_cpp/variant/packed_int32_array.hpp>
#include <godot_cpp/variant/packed_int64_array.hpp>
#include <godot_cpp/variant/packed_string_array.hpp>
#include <godot_cpp/variant/utility_functions.hpp>
#include <godot_cpp/variant/variant.hpp>

namespace pk {
using namespace godot;
using namespace variant_helpers;

bool NativeEconomyRuntime::service_country_economy_asset_peer(
        uint32_t max_requests, std::string &error) {
    error.clear();
    // Must match block_or_enqueue / research host-peer admission: Country may
    // be unique-writer via Host domain authority even when the local
    // sync_store_writes_forbidden flag has not been mirrored yet. Servicing
    // only on the flag left RESEARCH_PURCHASE rows COUNTRY_PREPARED forever
    // (enqueue worked, poll never ran) → climate ring fill → day_wait timeout.
    const bool country_unique_writer =
        (_country_runtime != nullptr &&
         country_reads().sync_store_writes_forbidden()) ||
        (_simulation_host != nullptr &&
         _simulation_host->domain_is_worker_authoritative(
             RuntimeDomainId::COUNTRY));
    if (max_requests == 0 || _simulation_host == nullptr ||
        _country_runtime == nullptr || !country_unique_writer) {
        return true;
    }

    // Continuation-owned requests (colonization procurement) run their
    // Economy legs between epochs. Journaling one inside an open epoch would
    // apply its market leg inside the conservation window while the
    // continuation's merchant/cargo leg lands outside it, so leave them queued
    // for the next out-of-epoch service.
    struct RequeueOnExit {
        NativeSimulationHost *host;
        std::vector<uint64_t> ids;
        ~RequeueOnExit() {
            for (const uint64_t id : ids) {
                std::string ignored;
                host->requeue_country_economy_asset_request(id, ignored);
            }
        }
    } outside_epoch{_simulation_host, {}};

    for (uint32_t inspected = 0; inspected < max_requests; ++inspected) {
        RuntimeEconomyAssetRequest request;
        if (!_simulation_host->poll_country_economy_asset_request(request))
            break;
        if (_epoch_active &&
            _simulation_host->country_economy_asset_settlement_deferred(
                request.request_id)) {
            outside_epoch.ids.push_back(request.request_id);
            continue;
        }

        const auto journal = _asset_peer_journal.find(request.request_id);
        if (journal != _asset_peer_journal.end()) {
            std::string identity_error;
            if (!fiscal_peer_journal_matches(request, journal->second,
                                             identity_error)) {
                error = identity_error;
                return false;
            }
            RuntimeEconomyAssetResult result = fiscal_peer_result_from_journal(
                request, journal->second);
            std::string submit_error;
            if (!_simulation_host->submit_country_economy_asset_result(
                    result, submit_error)) {
                std::string requeue_error;
                if (!_simulation_host->requeue_country_economy_asset_request(
                        request.request_id, requeue_error)) {
                    error = requeue_error.empty() ? submit_error : requeue_error;
                    return false;
                }
                error = submit_error.empty()
                    ? "country_economy_fiscal_terminal_retry_pending"
                    : submit_error;
                return false;
            }
            continue;
        }

        const auto submit_terminal = [this](
                const RuntimeEconomyAssetRequest &request,
                RuntimeEconomyAssetResultCode code,
                RuntimeEconomyAssetState state,
                int64_t committed_quantity, int64_t committed_cash,
                const char *reason, std::string &submit_error) {
            RuntimeEconomyAssetResult result;
            result.code = code;
            result.state = state;
            result.accepted = code == RuntimeEconomyAssetResultCode::COMPLETED ? 1 : 0;
            result.session_epoch = request.session_epoch;
            result.transaction_id = request.transaction_id;
            result.request_id = request.request_id;
            result.operation = request.operation;
            result.continuation_index = request.continuation_index;
            result.day = request.day;
            result.country_generation = request.country_generation;
            result.peer_generation = request.peer_generation;
            result.committed_peer_generation = std::max(
                request.peer_generation, _committed_generation);
            result.country_slot = request.country_slot;
            result.target_slot = request.target_slot;
            result.committed_quantity = committed_quantity;
            result.committed_cash = committed_cash;
            result.committed_goods_total = 0;
            if (reason != nullptr) {
                const size_t size = std::min(std::strlen(reason),
                    result.reason.size() - 1);
                std::memcpy(result.reason.data(), reason, size);
                result.reason[size] = '\0';
            }
            return _simulation_host->submit_country_economy_asset_result(
                result, submit_error);
        };

        const bool fiscal = request.operation ==
                RuntimeEconomyAssetOperation::FISCAL_RESERVE ||
            request.operation == RuntimeEconomyAssetOperation::FISCAL_RETURN ||
            request.operation == RuntimeEconomyAssetOperation::FISCAL_COLLECT;
        const uint32_t op_bit =
            1u << static_cast<uint32_t>(request.operation);
        const bool gate_open = (_d7_operation_gate_mask & op_bit) != 0u;
        const bool prepared =
            request.state == RuntimeEconomyAssetState::COUNTRY_PREPARED;

        if (!fiscal) {
            // Non-fiscal (M2–M5): Country already committed treasury value.
            // Apply local cohort/market side effects when simple, then journal
            // COMPLETED with prepared cash/quantity as the committed amounts.
            // Cash never falls back to the goods quantity: a goods-only
            // treasury spend or market delivery (requested_cash == 0) must
            // commit zero cash, or Country debits its treasury by the goods
            // count with no Economy-side counterpart.
            const int64_t committed_qty = request.prepared_quantity > 0
                ? request.prepared_quantity : request.requested_quantity;
            const int64_t committed_cash = request.reserved_cash > 0
                ? request.reserved_cash : request.requested_cash;
            if (!gate_open || !prepared ||
                request.origin_domain !=
                    static_cast<uint32_t>(RuntimeDomainId::ECONOMY)) {
                record_fiscal_peer_terminal(
                    request, RuntimeEconomyAssetResultCode::REJECTED,
                    RuntimeEconomyAssetState::REJECTED, 0, 0,
                    "country_economy_asset_request_invalid");
                std::string submit_error;
                if (!submit_terminal(
                        request, RuntimeEconomyAssetResultCode::REJECTED,
                        RuntimeEconomyAssetState::REJECTED, 0, 0,
                        "country_economy_asset_request_invalid",
                        submit_error)) {
                    std::string requeue_error;
                    if (!_simulation_host->requeue_country_economy_asset_request(
                            request.request_id, requeue_error)) {
                        error = requeue_error.empty() ? submit_error
                                                      : requeue_error;
                        return false;
                    }
                    error = submit_error.empty()
                        ? "country_economy_asset_rejection_retry_pending"
                        : submit_error;
                    return false;
                }
                continue;
            }
            std::string side_error;
            if (!apply_peer_asset_side_effects(request, side_error)) {
                record_fiscal_peer_terminal(
                    request, RuntimeEconomyAssetResultCode::REJECTED,
                    RuntimeEconomyAssetState::REJECTED, 0, 0,
                    side_error.empty() ? "country_economy_asset_side_effect_failed"
                                       : side_error.c_str());
                std::string submit_error;
                if (!submit_terminal(
                        request, RuntimeEconomyAssetResultCode::REJECTED,
                        RuntimeEconomyAssetState::REJECTED, 0, 0,
                        side_error.empty()
                            ? "country_economy_asset_side_effect_failed"
                            : side_error.c_str(),
                        submit_error)) {
                    std::string requeue_error;
                    if (!_simulation_host->requeue_country_economy_asset_request(
                            request.request_id, requeue_error)) {
                        error = requeue_error.empty() ? submit_error
                                                      : requeue_error;
                        return false;
                    }
                    error = submit_error.empty()
                        ? "country_economy_asset_rejection_retry_pending"
                        : submit_error;
                    return false;
                }
                continue;
            }
            record_fiscal_peer_terminal(
                request, RuntimeEconomyAssetResultCode::COMPLETED,
                RuntimeEconomyAssetState::COMPLETED, committed_qty,
                committed_cash, "");
            std::string submit_error;
            if (!submit_terminal(
                    request, RuntimeEconomyAssetResultCode::COMPLETED,
                    RuntimeEconomyAssetState::COMPLETED, committed_qty,
                    committed_cash, "", submit_error)) {
                std::string requeue_error;
                if (!_simulation_host->requeue_country_economy_asset_request(
                        request.request_id, requeue_error)) {
                    error = requeue_error.empty() ? submit_error : requeue_error;
                    return false;
                }
                error = submit_error.empty()
                    ? "country_economy_asset_completion_retry_pending"
                    : submit_error;
                return false;
            }
            continue;
        }

        const bool request_ready = request.origin_domain ==
                static_cast<uint32_t>(RuntimeDomainId::ECONOMY) &&
            prepared &&
            request.country_slot >= 0 &&
            request.country_slot < static_cast<int32_t>(
                _fiscal_escrow_by_country.size());
        const int64_t amount = request.prepared_quantity > 0
            ? request.prepared_quantity : request.requested_quantity;
        if (!request_ready || amount <= 0 ||
            request.requested_cash != amount ||
            request.requested_quantity != amount) {
            record_fiscal_peer_terminal(
                request, RuntimeEconomyAssetResultCode::REJECTED,
                RuntimeEconomyAssetState::REJECTED, 0, 0,
                "country_economy_fiscal_request_invalid");
            std::string submit_error;
            if (!submit_terminal(
                    request, RuntimeEconomyAssetResultCode::REJECTED,
                    RuntimeEconomyAssetState::REJECTED, 0, 0,
                    "country_economy_fiscal_request_invalid", submit_error)) {
                std::string requeue_error;
                if (!_simulation_host->requeue_country_economy_asset_request(
                        request.request_id, requeue_error)) {
                    error = requeue_error.empty() ? submit_error : requeue_error;
                    return false;
                }
                error = submit_error.empty()
                    ? "country_economy_fiscal_rejection_retry_pending"
                    : submit_error;
                return false;
            }
            continue;
        }

        const size_t country = static_cast<size_t>(request.country_slot);
        const int64_t escrow = _fiscal_escrow_by_country[country];
        int64_t updated_escrow = escrow;
        if (request.operation == RuntimeEconomyAssetOperation::FISCAL_RESERVE) {
            if (escrow > std::numeric_limits<int64_t>::max() - amount) {
                record_fiscal_peer_terminal(
                    request, RuntimeEconomyAssetResultCode::REJECTED,
                    RuntimeEconomyAssetState::REJECTED, 0, 0,
                    "country_economy_fiscal_escrow_overflow");
                std::string submit_error;
                if (!submit_terminal(
                        request, RuntimeEconomyAssetResultCode::REJECTED,
                        RuntimeEconomyAssetState::REJECTED, 0, 0,
                        "country_economy_fiscal_escrow_overflow", submit_error)) {
                    std::string requeue_error;
                    if (!_simulation_host->requeue_country_economy_asset_request(
                            request.request_id, requeue_error)) {
                        error = requeue_error.empty() ? submit_error : requeue_error;
                        return false;
                    }
                    error = submit_error.empty()
                        ? "country_economy_fiscal_rejection_retry_pending"
                        : submit_error;
                    return false;
                }
                continue;
            }
            updated_escrow = escrow + amount;
        } else {
            if (escrow < amount) {
                record_fiscal_peer_terminal(
                    request, RuntimeEconomyAssetResultCode::REJECTED,
                    RuntimeEconomyAssetState::REJECTED, 0, 0,
                    "country_economy_fiscal_escrow_insufficient");
                std::string submit_error;
                if (!submit_terminal(
                        request, RuntimeEconomyAssetResultCode::REJECTED,
                        RuntimeEconomyAssetState::REJECTED, 0, 0,
                        "country_economy_fiscal_escrow_insufficient", submit_error)) {
                    std::string requeue_error;
                    if (!_simulation_host->requeue_country_economy_asset_request(
                            request.request_id, requeue_error)) {
                        error = requeue_error.empty() ? submit_error : requeue_error;
                        return false;
                    }
                    error = submit_error.empty()
                        ? "country_economy_fiscal_rejection_retry_pending"
                        : submit_error;
                    return false;
                }
                continue;
            }
            updated_escrow = escrow - amount;
        }

        _fiscal_escrow_by_country.write_scalar(country, updated_escrow, market_mutation_sink());
        record_fiscal_peer_terminal(
            request, RuntimeEconomyAssetResultCode::COMPLETED,
            RuntimeEconomyAssetState::COMPLETED, amount, amount, "");
        std::string submit_error;
        if (!submit_terminal(
                request, RuntimeEconomyAssetResultCode::COMPLETED,
                RuntimeEconomyAssetState::COMPLETED, amount, amount, "",
                submit_error)) {
            std::string requeue_error;
            if (!_simulation_host->requeue_country_economy_asset_request(
                    request.request_id, requeue_error)) {
                error = requeue_error.empty() ? submit_error : requeue_error;
                return false;
            }
            error = submit_error.empty()
                ? "country_economy_fiscal_completion_retry_pending"
                : submit_error;
            return false;
        }
    }
    return true;
}

} // namespace pk
