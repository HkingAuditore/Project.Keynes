#include "economy_authority_transfer.h"
#include "economy_invariant_probe.h"
#if defined(_WIN32)
#ifndef NOMINMAX
#define NOMINMAX
#endif
#endif
#include "native_simulation_host.h"
#include "native_simulation_day_context.h"
#include "runtime_module_descriptor.h"
#include <cassert>
#include "country_core_apply.h"
#include "country_ai_runtime.h"
#include "country_runtime.h"
#include "economy_runtime.h"
#include "economy_hash.h"
#include "effect_magnitude.h"
#include "runtime_economy_ecp2.h"
#include "native_parallel_executor.h"
#include "runtime_climate_parity.h"
#include "runtime_switch_registry.h"
#include "pk_log.h"

#include <algorithm>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cmath>
#include <exception>
#include <limits>
#include <type_traits>
#include <unordered_set>

#if defined(_WIN32)
#include <windows.h>
#endif

#include "native_simulation_host_support.h"

namespace pk {

uint32_t NativeSimulationHost::prepare_economy_origin_country_assets(
        std::string &error) {
    error.clear();
    if (!_country_pod_configured.load(std::memory_order_acquire)) return 0u;
    if (!domain_is_worker_authoritative(RuntimeDomainId::COUNTRY) &&
        !country_authority_owner_is_worker()) {
        return 0u;
    }

    const auto sort_origin_queue_locked = [this]() {
        std::sort(_economy_origin_asset_queue.begin(),
                  _economy_origin_asset_queue.end(),
                  [this](uint64_t lhs, uint64_t rhs) {
            const auto &a = _country_economy_asset_requests.at(lhs);
            const auto &b = _country_economy_asset_requests.at(rhs);
            if (a.day != b.day) return a.day < b.day;
            if (a.operation_sequence != b.operation_sequence)
                return a.operation_sequence < b.operation_sequence;
            if (a.continuation_index != b.continuation_index)
                return a.continuation_index < b.continuation_index;
            return lhs < rhs;
        });
    };

    // Recover CREATED orphans left after older prepare cleared the origin
    // queue then failed: without this, Economy parks forever, Climate stops
    // consuming, and WorldClock nails climate_input_capacity_day_barrier.
    {
        std::lock_guard<std::mutex> lock(_country_transport_mutex);
        bool recovered = false;
        for (const auto &entry : _country_economy_asset_requests) {
            if (entry.second.origin_domain !=
                    static_cast<uint32_t>(RuntimeDomainId::ECONOMY)) {
                continue;
            }
            if (entry.second.state != RuntimeEconomyAssetState::CREATED)
                continue;
            if (_country_economy_asset_terminal_results.find(entry.first) !=
                    _country_economy_asset_terminal_results.end()) {
                continue;
            }
            if (std::find(_economy_origin_asset_queue.begin(),
                          _economy_origin_asset_queue.end(),
                          entry.first) != _economy_origin_asset_queue.end()) {
                continue;
            }
            _economy_origin_asset_queue.push_back(entry.first);
            recovered = true;
        }
        if (recovered) sort_origin_queue_locked();
    }

    uint32_t prepared = 0u;
    while (true) {
        uint64_t request_id = 0;
        RuntimeEconomyAssetRequest request;
        bool already_prepared = false;
        {
            std::lock_guard<std::mutex> lock(_country_transport_mutex);
            if (_economy_origin_asset_queue.empty()) break;
            request_id = _economy_origin_asset_queue.front();
            _economy_origin_asset_queue.pop_front();
            const auto it = _country_economy_asset_requests.find(request_id);
            if (it == _country_economy_asset_requests.end()) continue;
            request = it->second;
            already_prepared =
                request.state == RuntimeEconomyAssetState::COUNTRY_PREPARED;
        }
        if (!already_prepared) {
            std::string snap_error;
            const RuntimeCountryPodSnapshot *borrowed =
                _country_pod_authority.borrow_state();
            if (borrowed == nullptr) {
                snap_error = "country_pod_not_bootstrapped";
            }
            if (borrowed == nullptr ||
                !country_core_apply_economy_asset_prepare(
                    *borrowed, _country_pod_catalog, request, snap_error)) {
                // Soft-reject this wire id so research/fiscal continuations
                // observe a terminal instead of a CREATED orphan.
                RuntimeEconomyAssetResult rejected;
                rejected.code = RuntimeEconomyAssetResultCode::REJECTED;
                rejected.state = RuntimeEconomyAssetState::REJECTED;
                rejected.accepted = 0;
                rejected.session_epoch = request.session_epoch;
                rejected.transaction_id = request.transaction_id;
                rejected.request_id = request.request_id;
                rejected.operation = request.operation;
                rejected.continuation_index = request.continuation_index;
                rejected.day = request.day;
                rejected.country_generation = request.country_generation;
                rejected.peer_generation = request.peer_generation;
                rejected.committed_peer_generation = request.peer_generation;
                rejected.country_slot = request.country_slot;
                rejected.target_slot = request.target_slot;
                const std::string reason = snap_error.empty()
                    ? "country_worker_economy_prepare_failed" : snap_error;
                const size_t n = std::min(reason.size(),
                                          rejected.reason.size() - 1u);
                std::memcpy(rejected.reason.data(), reason.data(), n);
                rejected.reason[n] = '\0';
                std::string submit_error;
                if (!submit_country_economy_asset_result(rejected,
                                                        submit_error)) {
                    std::lock_guard<std::mutex> lock(_country_transport_mutex);
                    _economy_origin_asset_queue.push_front(request_id);
                    sort_origin_queue_locked();
                    error = submit_error.empty() ? reason : submit_error;
                    return prepared;
                }
                continue;
            }
            request.state = RuntimeEconomyAssetState::COUNTRY_PREPARED;
            std::lock_guard<std::mutex> lock(_country_transport_mutex);
            _country_economy_asset_requests[request_id] = request;
        }
        std::string publish_error;
        if (!publish_country_economy_asset_requests({request}, publish_error)) {
            std::lock_guard<std::mutex> lock(_country_transport_mutex);
            _economy_origin_asset_queue.push_front(request_id);
            sort_origin_queue_locked();
            error = publish_error.empty()
                ? "country_worker_economy_request_failed" : publish_error;
            return prepared;
        }
        ++prepared;
    }
    if (prepared > 0u) {
        _country_peer_signal.fetch_add(1, std::memory_order_acq_rel);
        _control_cv.notify_all();
    }
    return prepared;
}

bool NativeSimulationHost::flush_country_economy_asset_commits(
        std::string &error, uint64_t settle_request_id,
        bool skip_audit_snapshot, int64_t shadow_through_day) {
    error.clear();
    struct PendingCommit {
        uint64_t request_id = 0;
        RuntimeEconomyAssetRequest request;
        RuntimeEconomyAssetResult result;
    };
    std::vector<PendingCommit> pending;
    const bool shadow = _mode.load(std::memory_order_acquire) ==
        RuntimeSimulationMode::SHADOW;
    {
        std::lock_guard<std::mutex> lock(_country_transport_mutex);
        pending.reserve(_country_economy_asset_terminal_results.size());
        for (const auto &entry : _country_economy_asset_terminal_results) {
            if (_country_economy_asset_committed.find(entry.first) !=
                    _country_economy_asset_committed.end()) {
                continue;
            }
            const auto request = _country_economy_asset_requests.find(entry.first);
            if (request == _country_economy_asset_requests.end()) continue;
            // The synchronous producer can lead SHADOW by several days. Apply
            // its mirrored treasury results at the same Country boundary as
            // the reference, never all at once on the worker's next pulse.
            if (shadow &&
                (shadow_through_day < 0 ||
                 request->second.day > shadow_through_day)) {
                continue;
            }
            // Country day-start / Economy stage-end flush must not debit
            // treasury for COMPLETED RESEARCH_PURCHASE before Economy phase 4
            // credits merchants in the same conservation window. Early flush
            // left opening cash already reduced while merchant credit landed
            // next epoch → money_conservation_failed / goods_error. The same
            // holds for wire ids whose Economy leg runs in the continuation
            // (colonization market purchase and treasury-to-cargo transfer).
            if (!shadow && (request->second.operation ==
                     RuntimeEconomyAssetOperation::RESEARCH_PURCHASE ||
                 _country_economy_asset_self_settled.count(entry.first) != 0) &&
                entry.second.code ==
                    RuntimeEconomyAssetResultCode::COMPLETED &&
                settle_request_id != entry.first) {
                continue;
            }
            pending.push_back(PendingCommit{
                entry.first, request->second, entry.second});
        }
    }
    if (shadow) {
        // Preserve the synchronous decision order within each dated boundary.
        // An unordered credit/debit replay can reject a valid spend that was
        // funded by an earlier credit in the same boundary.
        std::sort(pending.begin(), pending.end(),
            [](const PendingCommit &a, const PendingCommit &b) {
                if (a.request.day != b.request.day)
                    return a.request.day < b.request.day;
                if (a.request.operation_sequence != b.request.operation_sequence)
                    return a.request.operation_sequence < b.request.operation_sequence;
                return a.request_id < b.request_id;
            });
    }
    const bool plan_active = _country_pod_plan_active.load(std::memory_order_acquire);
    uint32_t applied = 0u;
    for (const PendingCommit &item : pending) {
        if (plan_active) {
            // Plan next_state must see the debit so commit_day stays consistent.
            if (!country_core_apply_economy_asset_commit(
                    _country_pod_plan.next_state, _country_pod_catalog,
                    item.request, item.result, error)) {
                return false;
            }
            // Also persist onto authority without bumping generation. Otherwise
            // publish_country_worker_snapshot still serves the pre-debit base,
            // Economy credits merchants against a flat treasury view, and a later
            // discard_plan would resurrect cash after the peer side-effect.
            if (!_country_pod_authority.apply_economy_asset_commit_to_authority_state(
                    item.request, item.result, error)) {
                return false;
            }
            _country_pod_plan.header.dirty_families |= RUNTIME_DIRTY_COUNTRY_STATE;
        } else if (!_country_pod_authority.apply_economy_asset_result(
                       item.request, item.result, error)) {
            return false;
        }
        std::lock_guard<std::mutex> lock(_country_transport_mutex);
        _country_economy_asset_committed.insert(item.request_id);
        ++applied;
    }
    // Authority treasury mutated outside an open plan must refresh the Economy
    // audit pin immediately. Otherwise opening/VERIFY keep reading the last
    // sealed day and report goods_error equal to the settled purchase.
    if (applied > 0u && !plan_active && !skip_audit_snapshot) {
        RuntimeCountryPodSnapshot audit_snap;
        std::string audit_error;
        if (_country_pod_authority.snapshot(audit_snap, audit_error)) {
            auto audit_copy =
                std::make_shared<const RuntimeCountryPodSnapshot>(
                    std::move(audit_snap));
            std::atomic_store_explicit(&_country_economy_audit_snapshot,
                                       audit_copy, std::memory_order_release);
        }
    }
    return true;
}

bool NativeSimulationHost::enqueue_economy_origin_country_asset(
        RuntimeEconomyAssetRequest request, std::string &error) {
    error.clear();
    if (request.request_id == 0)
        request.request_id = allocate_command_request_id();
    if (request.transaction_id == 0)
        request.transaction_id = request.request_id;
    if (request.session_epoch == 0)
        request.session_epoch = _country_worker_session_epoch;
    if (request.operation_sequence == 0)
        request.operation_sequence = request.request_id;
    request.origin_domain = static_cast<uint32_t>(RuntimeDomainId::ECONOMY);
    request.state = RuntimeEconomyAssetState::CREATED;
    std::string shape_error;
    if (!economy_asset_request_shape_valid(request, shape_error)) {
        error = shape_error.empty()
            ? "country_economy_asset_request_invalid" : shape_error;
        return false;
    }
    std::lock_guard<std::mutex> lock(_country_transport_mutex);
    const auto existing = _country_economy_asset_requests.find(request.request_id);
    if (existing != _country_economy_asset_requests.end()) {
        // A continuation retry repeats the original Economy-origin wire
        // request. Country may already have advanced it to COUNTRY_PREPARED;
        // treat that exact logical retry as idempotent rather than allocating
        // a second Country reservation.
        if (economy_asset_request_equal(existing->second, request) ||
            economy_asset_country_prepare_transition_valid(request,
                                                            existing->second)) {
            ++_country_economy_asset_protocol.duplicate_messages;
            return true;
        }
        error = "country_economy_asset_request_duplicate_mismatch";
        return false;
    }
    _country_economy_asset_requests.emplace(request.request_id, request);
    _economy_origin_asset_queue.push_back(request.request_id);
    std::sort(_economy_origin_asset_queue.begin(),
              _economy_origin_asset_queue.end(),
              [this](uint64_t lhs, uint64_t rhs) {
        const auto &a = _country_economy_asset_requests.at(lhs);
        const auto &b = _country_economy_asset_requests.at(rhs);
        if (a.day != b.day) return a.day < b.day;
        if (a.operation_sequence != b.operation_sequence)
            return a.operation_sequence < b.operation_sequence;
        if (a.continuation_index != b.continuation_index)
            return a.continuation_index < b.continuation_index;
        return lhs < rhs;
    });
    ++_country_economy_asset_protocol.pending_requests;
    _country_economy_asset_protocol.last_request_id = request.request_id;
    _country_economy_asset_protocol.last_transaction_id = request.transaction_id;
    // Wake the Country worker so same-day prepare can drain the origin queue
    // without waiting for the next unrelated peer signal.
    _country_peer_signal.fetch_add(1, std::memory_order_acq_rel);
    _control_cv.notify_all();
    return true;
}

bool NativeSimulationHost::prepare_worker_cohort_cash(
        RuntimeEconomyAssetRequest &request, std::string &error) {
    error.clear();
    // Contract violations. Wrong thread, Country not worker-authoritative, or
    // an operation outside the M2 cohort-cash pair are caller bugs: no retry
    // can make them valid.
    if (!on_worker_thread() ||
        !domain_is_worker_authoritative(RuntimeDomainId::COUNTRY) ||
        (request.operation != RuntimeEconomyAssetOperation::CASH_TO_COHORT &&
         request.operation != RuntimeEconomyAssetOperation::CASH_FROM_COHORT &&
         // Army pay (opcode 34) uses the same synchronous peer cycle for its
         // treasury debit: prepare -> Economy side effect -> finish, all inside
         // one epoch so the debit and the lane credit share an audit window.
         request.operation != RuntimeEconomyAssetOperation::TREASURY_SPEND)) {
        error = "country_worker_cohort_cash_boundary_invalid";
        return false;
    }
    // Timing window, not a contract violation. Country's plan for this day is
    // still open (its stage parked on a peer/asset terminal), so the POD
    // snapshot this prepare would read is mid-plan. Nothing has been allocated
    // or published yet, so the caller can safely retry on a later pulse once
    // commit_day closes the window.
    if (_country_pod_plan_active.load(std::memory_order_acquire)) {
        error = "country_economy_asset_country_plan_pending";
        return false;
    }
    request.session_epoch = _country_worker_session_epoch;
    request.request_id = allocate_command_request_id();
    request.transaction_id = request.request_id;
    request.operation_sequence = request.request_id;
    request.origin_domain = static_cast<uint32_t>(RuntimeDomainId::ECONOMY);
    const RuntimeCountryPodSnapshot *borrowed =
        _country_pod_authority.borrow_state();
    if (borrowed == nullptr) {
        error = "country_pod_not_bootstrapped";
        return false;
    }
    if (!country_core_apply_economy_asset_prepare(
            *borrowed, _country_pod_catalog, request, error)) return false;
    if (request.operation == RuntimeEconomyAssetOperation::CASH_FROM_COHORT &&
        borrowed->country_cash[static_cast<size_t>(request.country_slot)] >
            INT64_MAX - request.requested_cash) {
        error = "country_worker_cohort_cash_treasury_overflow";
        return false;
    }
    // Both owners execute on this thread. Publish directly to the existing
    // peer queue; there is no later Country stage to prepare this same day.
    return publish_country_economy_asset_requests({request}, error);
}

bool NativeSimulationHost::finish_worker_country_asset(
        uint64_t request_id, RuntimeEconomyAssetResult &result, std::string &error) {
    error.clear();
    if (!on_worker_thread() ||
        !country_economy_asset_terminal_result(request_id, result)) {
        error = "country_worker_cohort_cash_terminal_missing";
        return false;
    }
    if (result.code != RuntimeEconomyAssetResultCode::COMPLETED) {
        error = result.reason.data();
        if (error.empty()) error = "country_worker_cohort_cash_rejected";
        return false;
    }
    if (!flush_country_economy_asset_commits(error, request_id, true)) return false;
    if (!publish_country_worker_snapshot(RUNTIME_DIRTY_COUNTRY_STATE, error))
        return false;
    acknowledge_country_economy_asset_consumed(request_id);
    return true;
}

} // namespace pk
