#include "economy_cost_probe.h"
#include "economy_runtime.h"
#include "economy_hash.h"
#include "runtime_switch_registry.h"
#include "economy_graph_kernels.h"
#include "economy_graph_live_ops.h"
#include "economy_graph_stage_dispatch.h"
#include "runtime_economy_pod.h"
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

void NativeEconomyRuntime::record_fiscal_peer_terminal(
        const RuntimeEconomyAssetRequest &request,
        RuntimeEconomyAssetResultCode code,
        RuntimeEconomyAssetState state,
        int64_t committed_quantity, int64_t committed_cash,
        const char *reason) {
    FiscalPeerJournalRecord record;
    record.request_id = request.request_id;
    record.transaction_id = request.transaction_id;
    record.session_epoch = request.session_epoch;
    record.country_handle = request.country_handle;
    record.country_generation = request.country_generation;
    record.peer_generation = request.peer_generation;
    record.committed_peer_generation = std::max(
        request.peer_generation, _committed_generation);
    record.day = request.day;
    record.effective_day = request.day;
    record.operation_sequence = request.operation_sequence;
    record.sequence = request.operation_sequence;
    record.continuation_index = request.continuation_index;
    record.source_domain = request.origin_domain != 0
        ? request.origin_domain
        : static_cast<uint32_t>(RuntimeDomainId::COUNTRY);
    record.target_domain = static_cast<uint32_t>(RuntimeDomainId::ECONOMY);
    record.country_slot = request.country_slot;
    record.operation = request.operation;
    record.result_code = code;
    record.state = state;
    record.reservation_state =
        runtime_d7_reservation_state_from_asset(state, code, reason);
    record.terminal_result =
        runtime_d7_terminal_result_from_asset(code, state, reason);
    record.accepted = code == RuntimeEconomyAssetResultCode::COMPLETED ? 1 : 0;
    record.requested_quantity = request.requested_quantity;
    record.requested_cash = request.requested_cash;
    record.committed_quantity = committed_quantity;
    record.committed_cash = committed_cash;
    record.retry_identity = request.request_id ^
        (static_cast<uint64_t>(request.continuation_index) << 1);
    record.state_hash_before = _committed_generation;
    record.state_hash_after = record.committed_peer_generation;
    if (reason != nullptr) {
        const size_t size = std::min(std::strlen(reason), record.reason.size() - 1);
        std::memcpy(record.reason.data(), reason, size);
        record.reason[size] = '\0';
        if (code == RuntimeEconomyAssetResultCode::REJECTED &&
            (std::strstr(reason, "late") != nullptr ||
             std::strstr(reason, "session") != nullptr ||
             std::strstr(reason, "generation") != nullptr)) {
            std::memcpy(record.late_ack_rejection_reason.data(), reason, size);
            record.late_ack_rejection_reason[size] = '\0';
        }
    }
    _asset_peer_journal.write_record(request.request_id, record);
    if (runtime_chunk_hash_enabled()) {
        const uint64_t digest = fiscal_record_digest(record);
        const auto [it, inserted] =
            _fiscal_record_digests.insert_or_assign(request.request_id, digest);
        (void)it;
        if (!_fiscal_digest_rebuild && !_fiscal_words_dirty) {
            if (inserted && (_fiscal_hash_words.empty() ||
                             request.request_id >
                                 _fiscal_hash_words[_fiscal_hash_words.size() - 2])) {
                _fiscal_hash_dirty_from_word = std::min(
                    _fiscal_hash_dirty_from_word, _fiscal_hash_words.size());
                _fiscal_hash_words.push_back(request.request_id);
                _fiscal_hash_words.push_back(digest);
            } else {
                size_t low = 0;
                size_t high = _fiscal_hash_words.size() / 2;
                while (low < high) {
                    const size_t mid = low + (high - low) / 2;
                    if (_fiscal_hash_words[mid * 2] < request.request_id) {
                        low = mid + 1;
                    } else {
                        high = mid;
                    }
                }
                const size_t pos = low * 2;
                _fiscal_hash_dirty_from_word =
                    std::min(_fiscal_hash_dirty_from_word, pos);
                if (!inserted && pos < _fiscal_hash_words.size() &&
                    _fiscal_hash_words[pos] == request.request_id) {
                    _fiscal_hash_words[pos + 1] = digest;
                } else {
                    const uint64_t pair[2] = {request.request_id, digest};
                    _fiscal_hash_words.insert(
                        _fiscal_hash_words.begin() + static_cast<ptrdiff_t>(pos),
                        std::begin(pair), std::end(pair));
                }
            }
        } else {
            _fiscal_words_dirty = true;
        }
    }
}

uint64_t NativeEconomyRuntime::fiscal_record_digest(const FiscalPeerJournalRecord &record) {
    // Schema 57 persists the seven legacy environment lanes. The two new
    // lanes are validated inputs and derived columns, not save authority, so
    // they must not enter the hash that restore recomputes from the stream.
    uint64_t hash = 1469598103934665603ULL;
    auto mix = [&](uint64_t value) { hash = economy_hash_u64(hash, value); };
    mix(record.request_id); mix(record.transaction_id); mix(record.country_handle);
    mix(record.country_generation); mix(record.peer_generation); mix(record.committed_peer_generation);
    mix(static_cast<uint64_t>(record.day)); mix(record.operation_sequence); mix(record.continuation_index);
    mix(static_cast<uint64_t>(record.country_slot)); mix(static_cast<uint16_t>(record.operation));
    mix(static_cast<uint8_t>(record.result_code)); mix(static_cast<uint8_t>(record.state)); mix(record.accepted);
    mix(static_cast<uint64_t>(record.requested_quantity)); mix(static_cast<uint64_t>(record.requested_cash));
    mix(static_cast<uint64_t>(record.committed_quantity)); mix(static_cast<uint64_t>(record.committed_cash));
    for (char byte : record.reason) mix(static_cast<uint8_t>(byte));
    mix(record.session_epoch); mix(record.source_domain); mix(record.target_domain);
    mix(static_cast<uint64_t>(record.effective_day)); mix(record.sequence);
    mix(static_cast<uint8_t>(record.reservation_state)); mix(static_cast<uint8_t>(record.terminal_result));
    mix(record.retry_identity); mix(record.state_hash_before); mix(record.state_hash_after);
    for (char byte : record.late_ack_rejection_reason) mix(static_cast<uint8_t>(byte));
    return hash;
}

bool NativeEconomyRuntime::apply_peer_asset_side_effects(
        const RuntimeEconomyAssetRequest &request, std::string &error) {
    error.clear();
    const int64_t amount = request.prepared_quantity > 0
        ? request.prepared_quantity : request.requested_quantity;
    switch (request.operation) {
    case RuntimeEconomyAssetOperation::CASH_TO_COHORT:
    case RuntimeEconomyAssetOperation::CASH_FROM_COHORT: {
        const int32_t slot = request.target_slot;
        if (slot < 0 ||
            slot >= static_cast<int32_t>(population_store().funds.size()) ||
            amount <= 0) {
            error = "country_economy_cohort_cash_slot_invalid";
            return false;
        }
        if (request.target_handle != 0 &&
            population_store().handle_for_slot(slot) != request.target_handle) {
            error = "country_economy_cohort_cash_handle_stale";
            return false;
        }
        audit_touch_population_lane(slot);
        touch_accounting_slot(slot);
        if (request.operation == RuntimeEconomyAssetOperation::CASH_TO_COHORT) {
            if (population_store().funds[slot] >
                    std::numeric_limits<int64_t>::max() - amount) {
                error = "country_economy_cohort_cash_overflow";
                return false;
            }
            population_store().funds.write_scalar(slot, population_store().funds[slot] + (amount), market_mutation_sink());
            population_store().epoch_income.write_scalar(slot, population_store().epoch_income[slot] + amount, market_mutation_sink());
        } else {
            if (population_store().funds[slot] < amount) {
                error = "country_economy_cohort_cash_insufficient";
                return false;
            }
            population_store().funds.write_scalar(slot, population_store().funds[slot] - (amount), market_mutation_sink());
            population_store().epoch_expense.write_scalar(slot, population_store().epoch_expense[slot] + amount, market_mutation_sink());
        }
        return true;
    }
    case RuntimeEconomyAssetOperation::GOOD_TO_MARKET:
    case RuntimeEconomyAssetOperation::GOOD_FROM_MARKET: {
        const int32_t market = request.target_slot;
        const int32_t good = request.good_id >= 0 ? request.good_id
            : (request.good_count > 0 ? request.good_ids[0] : -1);
        if (market < 0 || market >= market_store().market_count.get() || good < 0 ||
            good >= market_store().good_count.get() || amount <= 0) {
            error = "country_economy_market_goods_lane_invalid";
            return false;
        }
        const size_t index = static_cast<size_t>(market_store().index(market, good));
        if (index >= market_store().stock.size()) {
            error = "country_economy_market_goods_lane_invalid";
            return false;
        }
        if (request.operation == RuntimeEconomyAssetOperation::GOOD_TO_MARKET) {
            if (market_store().stock[index] >
                    std::numeric_limits<int64_t>::max() - amount) {
                error = "country_economy_market_goods_overflow";
                return false;
            }
            audit_touch_market_lane(index);
            market_store().stock.write_scalar(index, market_store().stock[index] + (amount), market_mutation_sink());
        } else {
            if (market_store().stock[index] < amount) {
                error = "country_economy_market_goods_insufficient";
                return false;
            }
            audit_touch_market_lane(index);
            market_store().stock.write_scalar(index, market_store().stock[index] - (amount), market_mutation_sink());
        }
        return true;
    }
    case RuntimeEconomyAssetOperation::RESEARCH_PURCHASE:
        // Country already transferred treasury value; no Economy-local store.
        return true;
    case RuntimeEconomyAssetOperation::TREASURY_SPEND: {
        // Country already debited the treasury. An ordinary spend (upkeep, building
        // materials) has no Economy-local counterpart, so there is nothing to do.
        //
        // Army pay (opcode 34) is the one treasury spend that must land in an
        // Economy-owned store: the formation's personnel lane. It arrives with the
        // formation handle in `target_handle` (ordinary spends leave it 0), so the
        // lane is credited exactly what Country committed. This is the same
        // conserved treasury -> lane movement the synchronous path performs, just
        // driven from the peer so it works while Country is worker-authoritative.
        if (request.target_handle == 0) return true;
        const int32_t row = _army_personnel.find(request.target_handle);
        if (row == ArmyPersonnelStore::NO_ROW) {
            // The formation was disbanded (or its lane released) between the debit
            // and the credit. Reject: the money left the treasury for a lane that
            // no longer exists, and pretending otherwise would hide a conservation
            // break.
            error = "army_lane_pay_lane_missing";
            return false;
        }
        if (amount <= 0) return true;
        const size_t lane_row = static_cast<size_t>(row);
        _army_personnel.funds[lane_row] = saturating_add(
            _army_personnel.funds[lane_row], amount, _saturation_count);
        _army_personnel.epoch_income[lane_row] = saturating_add(
            _army_personnel.epoch_income[lane_row], amount, _saturation_count);
        trace_record_cashflow(_army_personnel.cell[lane_row],
                              request.target_handle, CASHFLOW_TRANSFER, 0, amount);
        return true;
    }
    case RuntimeEconomyAssetOperation::FISCAL_RESERVE:
    case RuntimeEconomyAssetOperation::FISCAL_RETURN:
    case RuntimeEconomyAssetOperation::FISCAL_COLLECT:
        error = "country_economy_asset_side_effect_fiscal_unexpected";
        return false;
    }
    error = "country_economy_asset_side_effect_unknown";
    return false;
}

} // namespace pk
