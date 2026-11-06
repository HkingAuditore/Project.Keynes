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

void NativeSimulationHost::set_country_economy_asset_protocol_error_locked(
        RuntimeEconomyAssetProtocolError code, uint64_t transaction_id,
        uint64_t request_id, const char *reason) noexcept {
    _country_economy_asset_protocol.last_error = code;
    _country_economy_asset_protocol.last_transaction_id = transaction_id;
    _country_economy_asset_protocol.last_request_id = request_id;
    country_peer_copy_reason(_country_economy_asset_protocol.last_reason,
                             reason == nullptr ? "" : reason);
}

bool NativeSimulationHost::publish_country_economy_asset_requests(
        const std::vector<RuntimeEconomyAssetRequest> &requests,
        std::string &error) {
    error.clear();
    if (requests.empty()) return true;

    std::lock_guard<std::mutex> lock(_country_transport_mutex);
    std::unordered_set<uint64_t> batch_ids;
    batch_ids.reserve(requests.size());
    size_t queue_additions = 0;
    const auto queued = [this](uint64_t request_id) {
        return std::find(_country_economy_asset_request_queue.begin(),
                         _country_economy_asset_request_queue.end(),
                         request_id) != _country_economy_asset_request_queue.end();
    };

    // Validate the complete vector before publishing any element.  A worker
    // plan is a semantic batch; transport capacity or one malformed request
    // must never leave a partially visible Economy batch behind.
    for (const RuntimeEconomyAssetRequest &request : requests) {
        std::string shape_error;
        if (!economy_asset_request_shape_valid(request, shape_error)) {
            error = shape_error.empty()
                ? "country_economy_asset_request_invalid" : shape_error;
            set_country_economy_asset_protocol_error_locked(
                request.protocol_version == RUNTIME_ECONOMY_ASSET_PROTOCOL_VERSION
                    ? RuntimeEconomyAssetProtocolError::REQUEST_INVALID
                    : RuntimeEconomyAssetProtocolError::PROTOCOL_MISMATCH,
                request.transaction_id, request.request_id, error.c_str());
            return false;
        }
        if (request.session_epoch != _country_worker_session_epoch) {
            error = "country_economy_asset_request_session_mismatch";
            set_country_economy_asset_protocol_error_locked(
                RuntimeEconomyAssetProtocolError::SESSION_MISMATCH,
                request.transaction_id, request.request_id, error.c_str());
            return false;
        }
        if (!batch_ids.insert(request.request_id).second) {
            error = "country_economy_asset_request_duplicate_mismatch";
            set_country_economy_asset_protocol_error_locked(
                RuntimeEconomyAssetProtocolError::REQUEST_DUPLICATE_MISMATCH,
                request.transaction_id, request.request_id, error.c_str());
            return false;
        }
        const auto existing = _country_economy_asset_requests.find(
            request.request_id);
        if (existing != _country_economy_asset_requests.end()) {
            const bool country_prepare_transition =
                economy_asset_country_prepare_transition_valid(
                    existing->second, request);
            if (!economy_asset_request_equal(existing->second, request) &&
                !country_prepare_transition) {
                error = "country_economy_asset_request_duplicate_mismatch";
                set_country_economy_asset_protocol_error_locked(
                    RuntimeEconomyAssetProtocolError::REQUEST_DUPLICATE_MISMATCH,
                    request.transaction_id, request.request_id, error.c_str());
                return false;
            }
            if (!country_prepare_transition)
                ++_country_economy_asset_protocol.duplicate_messages;
            if (_country_economy_asset_terminal_results.find(request.request_id) ==
                    _country_economy_asset_terminal_results.end() &&
                !queued(request.request_id) &&
                _country_economy_asset_dispatched.find(request.request_id) ==
                    _country_economy_asset_dispatched.end()) {
                ++queue_additions;
            }
            continue;
        }
        if (_country_economy_asset_terminal_results.find(request.request_id) !=
                _country_economy_asset_terminal_results.end()) {
            error = "country_economy_asset_request_duplicate_mismatch";
            set_country_economy_asset_protocol_error_locked(
                RuntimeEconomyAssetProtocolError::REQUEST_DUPLICATE_MISMATCH,
                request.transaction_id, request.request_id, error.c_str());
            return false;
        }
        ++queue_additions;
    }
    if (_country_economy_asset_request_queue.size() + queue_additions >
            RUNTIME_ECONOMY_ASSET_QUEUE_CAPACITY) {
        error = "country_economy_asset_request_capacity_exceeded";
        set_country_economy_asset_protocol_error_locked(
            RuntimeEconomyAssetProtocolError::CAPACITY_EXCEEDED, 0, 0,
            error.c_str());
        return false;
    }

    for (const RuntimeEconomyAssetRequest &request : requests) {
        auto existing = _country_economy_asset_requests.find(
            request.request_id);
        if (existing == _country_economy_asset_requests.end()) {
            _country_economy_asset_requests.emplace(request.request_id, request);
            ++_country_economy_asset_protocol.pending_requests;
            existing = _country_economy_asset_requests.find(request.request_id);
        } else if (economy_asset_country_prepare_transition_valid(
                       existing->second, request)) {
            existing->second = request;
            _country_economy_asset_dispatched.erase(request.request_id);
        }
        if (_country_economy_asset_terminal_results.find(request.request_id) ==
                _country_economy_asset_terminal_results.end() &&
            !queued(request.request_id) &&
            _country_economy_asset_dispatched.find(request.request_id) ==
                _country_economy_asset_dispatched.end()) {
            _country_economy_asset_request_queue.push_back(request.request_id);
        }
        _country_economy_asset_protocol.last_transaction_id =
            request.transaction_id;
        _country_economy_asset_protocol.last_request_id = request.request_id;
    }
    _country_economy_asset_protocol.queued_requests = static_cast<uint32_t>(
        std::min<size_t>(_country_economy_asset_request_queue.size(),
                         std::numeric_limits<uint32_t>::max()));
    std::sort(_country_economy_asset_request_queue.begin(),
              _country_economy_asset_request_queue.end(),
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
    _country_economy_asset_protocol.last_error =
        RuntimeEconomyAssetProtocolError::NONE;
    country_peer_copy_reason(_country_economy_asset_protocol.last_reason, "");
    _country_peer_signal.fetch_add(1, std::memory_order_acq_rel);
    _control_cv.notify_all();
    return true;
}

void NativeSimulationHost::defer_country_economy_asset_settlement(
        uint64_t request_id) {
    if (request_id == 0) return;
    std::lock_guard<std::mutex> lock(_country_transport_mutex);
    _country_economy_asset_self_settled.insert(request_id);
}

void NativeSimulationHost::release_country_economy_asset_settlement(
        uint64_t request_id) noexcept {
    if (request_id == 0) return;
    std::lock_guard<std::mutex> lock(_country_transport_mutex);
    _country_economy_asset_self_settled.erase(request_id);
}

bool NativeSimulationHost::country_economy_asset_settlement_deferred(
        uint64_t request_id) const {
    if (request_id == 0) return false;
    std::lock_guard<std::mutex> lock(_country_transport_mutex);
    return _country_economy_asset_self_settled.count(request_id) != 0;
}

void NativeSimulationHost::acknowledge_country_economy_asset_consumed(
        uint64_t request_id) noexcept {
    if (request_id == 0) return;
    std::lock_guard<std::mutex> lock(_country_transport_mutex);
    const auto request = _country_economy_asset_requests.find(request_id);
    const auto terminal = _country_economy_asset_terminal_results.find(request_id);
    if (request == _country_economy_asset_requests.end() ||
        terminal == _country_economy_asset_terminal_results.end() ||
        !economy_asset_result_terminal(terminal->second)) return;
    _country_economy_asset_request_queue.erase(
        std::remove(_country_economy_asset_request_queue.begin(),
                    _country_economy_asset_request_queue.end(), request_id),
        _country_economy_asset_request_queue.end());
    _economy_origin_asset_queue.erase(
        std::remove(_economy_origin_asset_queue.begin(),
                    _economy_origin_asset_queue.end(), request_id),
        _economy_origin_asset_queue.end());
    _country_economy_asset_requests.erase(request);
    _country_economy_asset_results.erase(request_id);
    _country_economy_asset_terminal_results.erase(terminal);
    _country_economy_asset_dispatched.erase(request_id);
    _country_economy_asset_committed.erase(request_id);
    _country_economy_asset_self_settled.erase(request_id);
    if (_country_economy_asset_protocol.pending_requests > 0)
        --_country_economy_asset_protocol.pending_requests;
    _country_economy_asset_protocol.queued_requests = static_cast<uint32_t>(
        std::min<size_t>(_country_economy_asset_request_queue.size(),
                         std::numeric_limits<uint32_t>::max()));
    _country_economy_asset_protocol.terminal_requests = static_cast<uint32_t>(
        std::min<size_t>(_country_economy_asset_terminal_results.size(),
                         std::numeric_limits<uint32_t>::max()));
}

bool NativeSimulationHost::poll_country_economy_asset_request(
        RuntimeEconomyAssetRequest &out) {
    std::lock_guard<std::mutex> lock(_country_transport_mutex);
    while (!_country_economy_asset_request_queue.empty()) {
        const uint64_t request_id =
            _country_economy_asset_request_queue.front();
        _country_economy_asset_request_queue.pop_front();
        const auto it = _country_economy_asset_requests.find(request_id);
        if (it == _country_economy_asset_requests.end()) continue;
        out = it->second;
        _country_economy_asset_dispatched.insert(request_id);
        _country_economy_asset_protocol.queued_requests = static_cast<uint32_t>(
            std::min<size_t>(_country_economy_asset_request_queue.size(),
                             std::numeric_limits<uint32_t>::max()));
        _country_economy_asset_protocol.last_transaction_id =
            out.transaction_id;
        _country_economy_asset_protocol.last_request_id = out.request_id;
        return true;
    }
    _country_economy_asset_protocol.queued_requests = static_cast<uint32_t>(
        std::min<size_t>(_country_economy_asset_request_queue.size(),
                         std::numeric_limits<uint32_t>::max()));
    return false;
}

bool NativeSimulationHost::country_economy_asset_terminal_result(
        uint64_t request_id, RuntimeEconomyAssetResult &out) const {
    if (request_id == 0) return false;
    std::lock_guard<std::mutex> lock(_country_transport_mutex);
    const auto it = _country_economy_asset_terminal_results.find(request_id);
    if (it == _country_economy_asset_terminal_results.end()) return false;
    out = it->second;
    return true;
}

bool NativeSimulationHost::submit_country_economy_asset_result(
        const RuntimeEconomyAssetResult &result, std::string &error) {
    error.clear();
    std::lock_guard<std::mutex> lock(_country_transport_mutex);
    const auto reject = [&](RuntimeEconomyAssetProtocolError code,
                            const char *reason) {
        error = reason == nullptr ? "country_economy_asset_result_rejected" : reason;
        set_country_economy_asset_protocol_error_locked(
            code, result.transaction_id, result.request_id, error.c_str());
        return false;
    };
    if (result.protocol_version != RUNTIME_ECONOMY_ASSET_PROTOCOL_VERSION)
        return reject(RuntimeEconomyAssetProtocolError::PROTOCOL_MISMATCH,
                      "country_economy_asset_result_protocol_mismatch");
    if (result.request_id == 0 || result.transaction_id == 0)
        return reject(RuntimeEconomyAssetProtocolError::REQUEST_INVALID,
                      "country_economy_asset_result_identity_invalid");

    const auto request = _country_economy_asset_requests.find(result.request_id);
    if (request == _country_economy_asset_requests.end()) {
        const auto terminal = _country_economy_asset_terminal_results.find(
            result.request_id);
        if (terminal != _country_economy_asset_terminal_results.end() &&
            economy_asset_result_equal(terminal->second, result)) {
            ++_country_economy_asset_protocol.duplicate_messages;
            return true;
        }
        return reject(RuntimeEconomyAssetProtocolError::REQUEST_UNKNOWN,
                      terminal == _country_economy_asset_terminal_results.end()
                          ? "country_economy_asset_result_request_unknown"
                          : "country_economy_asset_result_duplicate_mismatch");
    }
    const RuntimeEconomyAssetRequest &expected = request->second;
    if (expected.session_epoch != _country_worker_session_epoch ||
        result.session_epoch != expected.session_epoch)
        return reject(RuntimeEconomyAssetProtocolError::SESSION_MISMATCH,
                      "country_economy_asset_result_session_mismatch");
    if (result.transaction_id != expected.transaction_id ||
        result.operation != expected.operation ||
        result.continuation_index != expected.continuation_index ||
        result.day != expected.day ||
        result.country_slot != expected.country_slot ||
        result.target_slot != expected.target_slot) {
        // A Country PREPARED transition may replace the CREATED request after
        // the peer has already polled its old copy. The old result is then
        // stale, but no store has been mutated and the request can be safely
        // requeued against the canonical prepared identity. Keep genuine
        // mismatches on an in-flight dispatch fatal; only the transition race
        // is backpressure.
        const bool dispatch_is_current =
            _country_economy_asset_dispatched.find(result.request_id) !=
            _country_economy_asset_dispatched.end();
        return reject(RuntimeEconomyAssetProtocolError::RESULT_IDENTITY_MISMATCH,
                      dispatch_is_current
                          ? "country_economy_asset_result_identity_mismatch"
                          : "country_economy_asset_result_identity_retry_pending");
    }
    if (result.country_generation != expected.country_generation ||
        result.peer_generation != expected.peer_generation ||
        result.committed_peer_generation < result.peer_generation)
        return reject(RuntimeEconomyAssetProtocolError::GENERATION_MISMATCH,
                      "country_economy_asset_result_generation_mismatch");
    if (!economy_asset_operation_valid(result.operation) ||
        !economy_asset_state_valid(result.state) ||
        !economy_asset_result_code_state_valid(result))
        return reject(RuntimeEconomyAssetProtocolError::RESULT_STATE_INVALID,
                      "country_economy_asset_result_state_invalid");
    if (result.committed_quantity < 0 || result.committed_cash < 0 ||
        result.committed_goods_total < 0 ||
        (expected.requested_quantity != 0 &&
         result.committed_quantity > expected.requested_quantity) ||
        (expected.requested_cash != 0 &&
         result.committed_cash > expected.requested_cash) ||
        (expected.requested_goods_total != 0 &&
         result.committed_goods_total > expected.requested_goods_total))
        return reject(RuntimeEconomyAssetProtocolError::RESULT_STATE_INVALID,
                      "country_economy_asset_result_amount_invalid");

    // The request record is the durable transaction cursor. Keep its state in
    // lockstep with the newest accepted result so a D7T1 restore resumes from
    // the actual continuation boundary rather than from the original prepare.
    request->second.state = result.state;
    request->second.peer_generation = result.peer_generation;

    const auto existing = _country_economy_asset_results.find(
        result.request_id);
    if (existing != _country_economy_asset_results.end()) {
        if (economy_asset_result_equal(existing->second, result)) {
            ++_country_economy_asset_protocol.duplicate_messages;
            return true;
        }
        if (economy_asset_result_terminal(existing->second) ||
            economy_asset_state_rank(result.state) <=
                economy_asset_state_rank(existing->second.state)) {
            return reject(RuntimeEconomyAssetProtocolError::RESULT_DUPLICATE_MISMATCH,
                          "country_economy_asset_result_duplicate_mismatch");
        }
    }

    const bool was_terminal = existing != _country_economy_asset_results.end() &&
        economy_asset_result_terminal(existing->second);
    _country_economy_asset_results[result.request_id] = result;
    if (economy_asset_result_terminal(result)) {
        _country_economy_asset_terminal_results[result.request_id] = result;
        if (!was_terminal && _country_economy_asset_protocol.pending_requests > 0)
            --_country_economy_asset_protocol.pending_requests;
        _country_economy_asset_protocol.terminal_requests = static_cast<uint32_t>(
            std::min<size_t>(_country_economy_asset_terminal_results.size(),
                             std::numeric_limits<uint32_t>::max()));
        if (result.code == RuntimeEconomyAssetResultCode::REJECTED)
            ++_country_economy_asset_protocol.rejected_results;
        if (result.code == RuntimeEconomyAssetResultCode::FAULTED)
            ++_country_economy_asset_protocol.faulted_transactions;
    }
    _country_economy_asset_protocol.last_transaction_id = result.transaction_id;
    _country_economy_asset_protocol.last_request_id = result.request_id;
    _country_economy_asset_protocol.last_error =
        RuntimeEconomyAssetProtocolError::NONE;
    country_peer_copy_reason(_country_economy_asset_protocol.last_reason, "");
    _country_peer_signal.fetch_add(1, std::memory_order_acq_rel);
    _control_cv.notify_all();
    return true;
}

bool NativeSimulationHost::requeue_country_economy_asset_request(
        uint64_t request_id, std::string &error) {
    error.clear();
    if (request_id == 0) {
        error = "country_economy_asset_requeue_identity_invalid";
        return false;
    }
    std::lock_guard<std::mutex> lock(_country_transport_mutex);
    const auto request = _country_economy_asset_requests.find(request_id);
    if (request == _country_economy_asset_requests.end()) {
        error = "country_economy_asset_requeue_request_unknown";
        return false;
    }
    if (_country_economy_asset_terminal_results.find(request_id) !=
            _country_economy_asset_terminal_results.end())
        return true;
    _country_economy_asset_dispatched.erase(request_id);
    if (std::find(_country_economy_asset_request_queue.begin(),
                  _country_economy_asset_request_queue.end(), request_id) ==
            _country_economy_asset_request_queue.end()) {
        if (_country_economy_asset_request_queue.size() >=
                RUNTIME_ECONOMY_ASSET_QUEUE_CAPACITY) {
            error = "country_economy_asset_request_capacity_exceeded";
            return false;
        }
        _country_economy_asset_request_queue.push_back(request_id);
    }
    std::sort(_country_economy_asset_request_queue.begin(),
              _country_economy_asset_request_queue.end(),
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
    _country_economy_asset_protocol.queued_requests = static_cast<uint32_t>(
        std::min<size_t>(_country_economy_asset_request_queue.size(),
                         std::numeric_limits<uint32_t>::max()));
    _country_peer_signal.fetch_add(1, std::memory_order_acq_rel);
    _control_cv.notify_all();
    return true;
}

RuntimeEconomyAssetProtocolStatus
NativeSimulationHost::country_economy_asset_protocol_status() const {
    std::lock_guard<std::mutex> lock(_country_transport_mutex);
    RuntimeEconomyAssetProtocolStatus out = _country_economy_asset_protocol;
    out.queued_requests = static_cast<uint32_t>(
        std::min<size_t>(_country_economy_asset_request_queue.size(),
                         std::numeric_limits<uint32_t>::max()));
    size_t pending = 0;
    for (const auto &entry : _country_economy_asset_requests) {
        if (_country_economy_asset_terminal_results.find(entry.first) ==
                _country_economy_asset_terminal_results.end()) {
            ++pending;
        }
    }
    out.pending_requests = static_cast<uint32_t>(
        std::min<size_t>(pending, std::numeric_limits<uint32_t>::max()));
    out.terminal_requests = static_cast<uint32_t>(
        std::min<size_t>(_country_economy_asset_terminal_results.size(),
                         std::numeric_limits<uint32_t>::max()));
    out.session_epoch = _country_worker_session_epoch;
    return out;
}

bool NativeSimulationHost::country_economy_asset_protocol_self_test(
        std::string &error) const {
    error.clear();
    NativeSimulationHost probe;
    probe._country_worker_session_epoch = 41;
    probe.reserve_command_request_ids_through(9000);
    if (probe.allocate_command_request_id() != 9001) {
        error = "country_economy_asset_restored_request_floor_failed";
        return false;
    }
    probe.reserve_command_request_ids_through(7000);
    if (probe.allocate_command_request_id() != 9002) {
        error = "country_economy_asset_request_floor_rewound";
        return false;
    }

    RuntimeEconomyAssetRequest off_thread_cash;
    off_thread_cash.operation = RuntimeEconomyAssetOperation::CASH_FROM_COHORT;
    std::string boundary_error;
    if (probe.prepare_worker_cohort_cash(off_thread_cash, boundary_error) ||
        boundary_error != "country_worker_cohort_cash_boundary_invalid" ||
        !probe._country_economy_asset_requests.empty()) {
        error = "country_worker_cohort_cash_wrong_thread_accepted";
        return false;
    }
    // The two rejection classes must stay separated. A contract violation is a
    // caller bug and has to stay fatal; an open Country plan window is
    // backpressure and has to stay retryable. Collapsing them back into one
    // reason is what turned a normal continuation into an economy stop.
    if (runtime_country_asset_pending_reason(
            "country_worker_cohort_cash_boundary_invalid") ||
        !runtime_country_asset_pending_reason(
            "country_economy_asset_country_plan_pending")) {
        error = "country_worker_cohort_cash_reason_class_collapsed";
        return false;
    }
    // Same split for colonization. Under Country worker authority the paired
    // CLAIM commits on the worker's own boundary, so Economy SETTLE can observe
    // the target as still unowned. That is backpressure: classifying it as a
    // lost target sent the settlers home while the claim still landed, leaving
    // the player a cell they owned with nobody living on it.
    if (!runtime_country_asset_pending_reason(
            "country_economy_asset_territory_claim_pending")) {
        error = "country_economy_territory_claim_reason_class_collapsed";
        return false;
    }

    RuntimeEconomyAssetRequest request;
    request.operation = RuntimeEconomyAssetOperation::TREASURY_SPEND;
    request.state = RuntimeEconomyAssetState::COUNTRY_PREPARED;
    request.session_epoch = 41;
    request.transaction_id = 7001;
    request.request_id = 7101;
    request.origin_epoch = 2;
    request.origin_stage = 9;
    request.continuation_index = 3;
    request.day = 12;
    request.operation_sequence = 99;
    request.country_generation = 5;
    request.peer_generation = 9;
    request.country_handle = 0x100000001ULL;
    request.country_slot = 0;
    request.target_slot = 2;
    request.good_count = 1;
    request.good_ids[0] = 4;
    request.good_quantities[0] = 7;
    request.requested_cash = 10;
    request.reserved_cash = 10;
    std::string publish_error;
    if (!probe.publish_country_economy_asset_requests({request}, publish_error)) {
        error = publish_error.empty()
            ? "country_economy_asset_self_test_publish_failed" : publish_error;
        return false;
    }
    RuntimeEconomyAssetRequest polled;
    if (!probe.poll_country_economy_asset_request(polled) ||
        !economy_asset_request_equal(polled, request)) {
        error = "country_economy_asset_self_test_poll_mismatch";
        return false;
    }
    RuntimeEconomyAssetRequest mismatch = request;
    mismatch.requested_cash = 11;
    if (probe.publish_country_economy_asset_requests({mismatch}, publish_error) ||
        publish_error != "country_economy_asset_request_duplicate_mismatch") {
        error = "country_economy_asset_self_test_duplicate_admission_failed";
        return false;
    }

    RuntimeEconomyAssetResult prepared;
    prepared.code = RuntimeEconomyAssetResultCode::PEER_PREPARED;
    prepared.state = RuntimeEconomyAssetState::PEER_PREPARED;
    prepared.accepted = 1;
    prepared.session_epoch = request.session_epoch;
    prepared.transaction_id = request.transaction_id;
    prepared.request_id = request.request_id;
    prepared.operation = request.operation;
    prepared.continuation_index = request.continuation_index;
    prepared.day = request.day;
    prepared.country_generation = request.country_generation;
    prepared.peer_generation = request.peer_generation;
    prepared.committed_peer_generation = 10;
    prepared.country_slot = request.country_slot;
    prepared.target_slot = request.target_slot;
    std::string result_error;
    if (!probe.submit_country_economy_asset_result(prepared, result_error) ||
        !probe.submit_country_economy_asset_result(prepared, result_error)) {
        error = result_error.empty()
            ? "country_economy_asset_self_test_prepare_failed" : result_error;
        return false;
    }
    RuntimeEconomyAssetResult bad_generation = prepared;
    bad_generation.committed_peer_generation = 8;
    if (probe.submit_country_economy_asset_result(
            bad_generation, result_error) ||
        result_error != "country_economy_asset_result_generation_mismatch") {
        error = "country_economy_asset_self_test_generation_guard_failed";
        return false;
    }

    RuntimeEconomyAssetResult completed = prepared;
    completed.code = RuntimeEconomyAssetResultCode::COMPLETED;
    completed.state = RuntimeEconomyAssetState::COMPLETED;
    completed.committed_cash = 10;
    completed.committed_goods_total = 7;
    if (!probe.submit_country_economy_asset_result(completed, result_error) ||
        !probe.submit_country_economy_asset_result(completed, result_error)) {
        error = result_error.empty()
            ? "country_economy_asset_self_test_complete_failed" : result_error;
        return false;
    }
    RuntimeEconomyAssetResult mismatched_terminal = completed;
    mismatched_terminal.reason[0] = 'x';
    if (probe.submit_country_economy_asset_result(
            mismatched_terminal, result_error) ||
        result_error != "country_economy_asset_result_duplicate_mismatch") {
        error = "country_economy_asset_self_test_terminal_guard_failed";
        return false;
    }

    // A stale peer result after the CREATED->COUNTRY_PREPARED transition is
    // retryable: the old polled copy is no longer the canonical request, and
    // no asset was committed by the rejected message.
    auto transition_probe_host = std::make_unique<NativeSimulationHost>();
    transition_probe_host->_country_worker_session_epoch = request.session_epoch;
    RuntimeEconomyAssetRequest transition_probe;
    transition_probe.operation = RuntimeEconomyAssetOperation::RESEARCH_PURCHASE;
    transition_probe.state = RuntimeEconomyAssetState::CREATED;
    transition_probe.session_epoch = request.session_epoch;
    transition_probe.transaction_id = 7202;
    transition_probe.request_id = 7202;
    transition_probe.origin_domain = static_cast<uint32_t>(RuntimeDomainId::ECONOMY);
    transition_probe.origin_epoch = request.origin_epoch;
    transition_probe.origin_stage = request.origin_stage;
    transition_probe.day = request.day;
    transition_probe.operation_sequence = 7202;
    transition_probe.country_handle = request.country_handle;
    transition_probe.country_slot = -1;
    transition_probe.target_slot = request.target_slot;
    transition_probe.requested_quantity = 1;
    transition_probe.requested_cash = 1;
    transition_probe.requested_goods_total = 1;
    if (!transition_probe_host->publish_country_economy_asset_requests(
            {transition_probe}, publish_error)) {
        error = "country_economy_asset_self_test_transition_seed_failed";
        return false;
    }
    RuntimeEconomyAssetRequest stale_transition;
    if (!transition_probe_host->poll_country_economy_asset_request(stale_transition)) {
        error = "country_economy_asset_self_test_transition_poll_failed";
        return false;
    }
    RuntimeEconomyAssetRequest prepared_transition = stale_transition;
    prepared_transition.state = RuntimeEconomyAssetState::COUNTRY_PREPARED;
    prepared_transition.country_slot = request.country_slot;
    prepared_transition.country_generation = request.country_generation;
    prepared_transition.prepared_quantity = 1;
    prepared_transition.reserved_cash = 1;
    if (!transition_probe_host->publish_country_economy_asset_requests(
            {prepared_transition}, publish_error)) {
        error = "country_economy_asset_self_test_transition_publish_failed";
        return false;
    }
    RuntimeEconomyAssetResult stale_transition_result;
    stale_transition_result.code = RuntimeEconomyAssetResultCode::COMPLETED;
    stale_transition_result.state = RuntimeEconomyAssetState::COMPLETED;
    stale_transition_result.accepted = 1;
    stale_transition_result.session_epoch = stale_transition.session_epoch;
    stale_transition_result.transaction_id = stale_transition.transaction_id;
    stale_transition_result.request_id = stale_transition.request_id;
    stale_transition_result.operation = stale_transition.operation;
    stale_transition_result.day = stale_transition.day;
    stale_transition_result.country_slot = stale_transition.country_slot;
    stale_transition_result.target_slot = stale_transition.target_slot;
    stale_transition_result.country_generation = prepared_transition.country_generation;
    stale_transition_result.peer_generation = prepared_transition.peer_generation;
    stale_transition_result.committed_peer_generation = prepared_transition.peer_generation;
    stale_transition_result.committed_quantity = 1;
    stale_transition_result.committed_cash = 1;
    if (transition_probe_host->submit_country_economy_asset_result(
            stale_transition_result, result_error) ||
        result_error != "country_economy_asset_result_identity_retry_pending") {
        error = result_error.empty()
            ? "country_economy_asset_self_test_transition_retry_missing"
            : result_error;
        return false;
    }
    if (!transition_probe_host->requeue_country_economy_asset_request(
            stale_transition.request_id, publish_error)) {
        error = publish_error.empty()
            ? "country_economy_asset_self_test_transition_requeue_failed"
            : publish_error;
        return false;
    }
    const RuntimeEconomyAssetProtocolStatus status =
        probe.country_economy_asset_protocol_status();
    if (status.queued_requests != 0 || status.pending_requests != 0 ||
        status.terminal_requests != 1 || status.rejected_results != 0) {
        error = "country_economy_asset_self_test_status_mismatch";
        return false;
    }

    // D7T1 must retain all three durable shapes: terminal rows, a Country
    // request that has not yet been polled, and an Economy-origin request
    // waiting for Country prepare. The Country apply marker is included to
    // prove a restored duplicate cannot apply the same asset mutation twice.
    probe._country_economy_asset_committed.insert(request.request_id);
    RuntimeEconomyAssetRequest pending = request;
    pending.operation = RuntimeEconomyAssetOperation::FISCAL_RESERVE;
    pending.state = RuntimeEconomyAssetState::COUNTRY_PREPARED;
    pending.transaction_id = 7002;
    pending.request_id = 7102;
    pending.day = 13;
    pending.operation_sequence = 100;
    pending.continuation_index = 0;
    pending.peer_generation = 9;
    pending.good_count = 0;
    pending.good_id = -1;
    pending.good_ids = {};
    pending.good_quantities = {};
    pending.requested_quantity = 5;
    pending.prepared_quantity = 5;
    pending.requested_cash = 5;
    pending.reserved_cash = 5;
    pending.requested_goods_total = 0;
    pending.reserved_goods_total = 0;
    if (!probe.publish_country_economy_asset_requests({pending}, publish_error)) {
        error = publish_error.empty()
            ? "country_economy_asset_self_test_pending_seed_failed"
            : publish_error;
        return false;
    }
    RuntimeEconomyAssetRequest dispatched_pending;
    if (!probe.poll_country_economy_asset_request(dispatched_pending) ||
        dispatched_pending.request_id != pending.request_id) {
        error = "country_economy_asset_self_test_pending_dispatch_failed";
        return false;
    }
    RuntimeEconomyAssetRequest origin = pending;
    origin.operation = RuntimeEconomyAssetOperation::FISCAL_RETURN;
    origin.state = RuntimeEconomyAssetState::CREATED;
    origin.transaction_id = 7003;
    origin.request_id = 7103;
    origin.operation_sequence = 101;
    origin.prepared_quantity = 0;
    origin.reserved_cash = 0;
    if (!probe.enqueue_economy_origin_country_asset(origin, publish_error)) {
        error = publish_error.empty()
            ? "country_economy_asset_self_test_origin_seed_failed"
            : publish_error;
        return false;
    }
    std::vector<uint8_t> journal;
    std::string journal_error;
    // Terminal history may predate the current transport session. Its matched
    // request/result identity remains durable; unresolved requests may not.
    probe._country_economy_asset_requests.at(request.request_id).session_epoch = 40;
    probe._country_economy_asset_results.at(request.request_id).session_epoch = 40;
    probe._country_economy_asset_terminal_results.at(request.request_id).session_epoch = 40;
    if (!probe.serialize_country_economy_asset_journal(journal, journal_error) ||
        journal.size() < 16u) {
        error = journal_error.empty()
            ? "country_economy_asset_self_test_journal_encode_failed"
            : journal_error;
        return false;
    }
    auto restored = std::make_unique<NativeSimulationHost>();
    restored->_country_worker_session_epoch = 52;
    if (!restored->restore_country_economy_asset_journal(
            journal.data(), journal.size(), journal_error)) {
        error = journal_error.empty()
            ? "country_economy_asset_self_test_journal_restore_failed"
            : journal_error;
        return false;
    }
    probe._country_economy_asset_requests.at(pending.request_id).session_epoch = 40;
    std::vector<uint8_t> stale_pending_journal;
    if (!probe.serialize_country_economy_asset_journal(stale_pending_journal, journal_error)) {
        error = "country_economy_asset_self_test_stale_pending_encode_failed";
        return false;
    }
    auto stale_pending_restore = std::make_unique<NativeSimulationHost>();
    stale_pending_restore->_country_worker_session_epoch = 52;
    if (stale_pending_restore->restore_country_economy_asset_journal(
            stale_pending_journal.data(), stale_pending_journal.size(), journal_error) ||
        journal_error != "d7_transaction_journal_request_invalid") {
        error = "country_economy_asset_self_test_stale_pending_accepted";
        return false;
    }
    probe._country_economy_asset_requests.at(pending.request_id).session_epoch = 41;
    RuntimeEconomyAssetRequest bootstrap_history = request;
    bootstrap_history.operation = RuntimeEconomyAssetOperation::FISCAL_COLLECT;
    bootstrap_history.origin_domain = static_cast<uint32_t>(RuntimeDomainId::ECONOMY);
    bootstrap_history.day = -1;
    if (!economy_asset_journal_request_valid(bootstrap_history, journal_error, true) ||
        economy_asset_journal_request_valid(bootstrap_history, journal_error, false)) {
        error = "country_economy_asset_self_test_bootstrap_history_invalid";
        return false;
    }
    const auto restored_terminal =
        restored->_country_economy_asset_terminal_results.find(request.request_id);
    const auto restored_pending =
        restored->_country_economy_asset_requests.find(pending.request_id);
    const auto restored_origin =
        restored->_country_economy_asset_requests.find(origin.request_id);
    if (restored_terminal ==
            restored->_country_economy_asset_terminal_results.end() ||
        restored_pending == restored->_country_economy_asset_requests.end() ||
        restored_origin == restored->_country_economy_asset_requests.end() ||
        restored_pending->second.transaction_id != pending.transaction_id ||
        restored_origin->second.transaction_id != origin.transaction_id ||
        restored_pending->second.session_epoch != 52 ||
        restored_origin->second.session_epoch != 52 ||
        restored->_country_economy_asset_committed.find(request.request_id) ==
            restored->_country_economy_asset_committed.end()) {
        error = "country_economy_asset_self_test_journal_identity_failed";
        return false;
    }
    const RuntimeEconomyAssetProtocolStatus restored_status =
        restored->country_economy_asset_protocol_status();
    if (restored_status.queued_requests != 1 ||
        restored_status.pending_requests != 2 ||
        restored_status.terminal_requests != 1 ||
        restored_status.recovered_transactions != 3) {
        error = "country_economy_asset_self_test_journal_status_failed";
        return false;
    }
    RuntimeEconomyAssetRequest rebound_pending;
    if (!restored->poll_country_economy_asset_request(rebound_pending) ||
        rebound_pending.request_id != pending.request_id ||
        rebound_pending.session_epoch != 52) {
        error = "country_economy_asset_self_test_pending_requeue_failed";
        return false;
    }
    if (restored->_economy_origin_asset_queue.empty() ||
        restored->_economy_origin_asset_queue.front() != origin.request_id) {
        error = "country_economy_asset_self_test_origin_requeue_failed";
        return false;
    }
    RuntimeEconomyAssetResult old_session = completed;
    if (restored->submit_country_economy_asset_result(
            old_session, result_error) ||
        result_error != "country_economy_asset_result_session_mismatch") {
        error = "country_economy_asset_self_test_old_session_guard_failed";
        return false;
    }
    RuntimeEconomyAssetResult rebound = completed;
    rebound.session_epoch = 52;
    if (!restored->submit_country_economy_asset_result(rebound, result_error) ||
        restored->country_economy_asset_protocol_status().duplicate_messages == 0) {
        error = result_error.empty()
            ? "country_economy_asset_self_test_restored_duplicate_failed"
            : result_error;
        return false;
    }
    restored->acknowledge_country_economy_asset_consumed(request.request_id);
    if (restored->_country_economy_asset_requests.find(request.request_id) !=
            restored->_country_economy_asset_requests.end() ||
        restored->_country_economy_asset_terminal_results.find(request.request_id) !=
            restored->_country_economy_asset_terminal_results.end() ||
        restored->_country_economy_asset_requests.find(pending.request_id) ==
            restored->_country_economy_asset_requests.end()) {
        error = "country_economy_asset_self_test_consumed_retirement_failed";
        return false;
    }
    std::vector<uint8_t> retired_journal;
    if (!restored->serialize_country_economy_asset_journal(
            retired_journal, journal_error)) {
        error = journal_error.empty()
            ? "country_economy_asset_self_test_retired_journal_encode_failed"
            : journal_error;
        return false;
    }
    auto retired_restore = std::make_unique<NativeSimulationHost>();
    retired_restore->_country_worker_session_epoch = 54;
    if (!retired_restore->restore_country_economy_asset_journal(
            retired_journal.data(), retired_journal.size(), journal_error) ||
        retired_restore->_country_economy_asset_requests.find(request.request_id) !=
            retired_restore->_country_economy_asset_requests.end() ||
        retired_restore->_country_economy_asset_requests.find(pending.request_id) ==
            retired_restore->_country_economy_asset_requests.end()) {
        error = journal_error.empty()
            ? "country_economy_asset_self_test_retired_journal_restore_failed"
            : journal_error;
        return false;
    }
    std::vector<uint8_t> corrupted = journal;
    corrupted[4] ^= 0xffu;
    auto corrupt_probe = std::make_unique<NativeSimulationHost>();
    corrupt_probe->_country_worker_session_epoch = 53;
    if (corrupt_probe->restore_country_economy_asset_journal(
            corrupted.data(), corrupted.size(), journal_error)) {
        error = "country_economy_asset_self_test_corrupt_journal_accepted";
        return false;
    }

    // A goods-only treasury spend (colonization kit cargo) must move goods
    // without touching treasury cash, and a peer result that commits more cash
    // than prepare reserved must be refused rather than debited.
    {
        RuntimeCountryPodSnapshot pod;
        pod.country_count = 1;
        pod.good_count = 2;
        pod.generation = 3;
        pod.country_cash = {1000};
        pod.country_goods = {0, 50};
        pod.country_state_version = {0};
        const RuntimeCountryPodCatalog pod_catalog;
        RuntimeEconomyAssetRequest goods_spend;
        goods_spend.operation = RuntimeEconomyAssetOperation::TREASURY_SPEND;
        goods_spend.country_slot = 0;
        goods_spend.requested_cash = 0;
        goods_spend.requested_quantity = 7;
        goods_spend.requested_goods_total = 7;
        goods_spend.good_count = 1;
        goods_spend.good_id = 1;
        goods_spend.good_ids[0] = 1;
        goods_spend.good_quantities[0] = 7;
        std::string pod_error;
        if (!country_core_apply_economy_asset_prepare(
                pod, pod_catalog, goods_spend, pod_error) ||
            goods_spend.reserved_cash != 0) {
            error = "country_economy_asset_self_test_goods_spend_prepare_failed";
            return false;
        }
        RuntimeEconomyAssetResult goods_done;
        goods_done.code = RuntimeEconomyAssetResultCode::COMPLETED;
        goods_done.state = RuntimeEconomyAssetState::COMPLETED;
        goods_done.committed_quantity = 7;
        goods_done.committed_cash = 7;
        RuntimeCountryPodSnapshot legacy_pod = pod;
        if (country_core_apply_economy_asset_commit(
                legacy_pod, pod_catalog, goods_spend, goods_done, pod_error) ||
            pod_error != "country_economy_asset_commit_cash_exceeds_reserved" ||
            legacy_pod.country_cash[0] != 1000) {
            error = "country_economy_asset_self_test_goods_spend_cash_guard_failed";
            return false;
        }
        goods_done.committed_cash = 0;
        if (!country_core_apply_economy_asset_commit(
                pod, pod_catalog, goods_spend, goods_done, pod_error) ||
            pod.country_cash[0] != 1000 || pod.country_goods[1] != 43) {
            error = "country_economy_asset_self_test_goods_spend_commit_failed";
            return false;
        }
    }

    // A continuation-owned COMPLETED terminal is neither swept in by the
    // generic flush nor reported idle for authority handoff until its owner
    // settles it or releases it.
    {
        auto settle_probe = std::make_unique<NativeSimulationHost>();
        RuntimeEconomyAssetRequest owned = request;
        owned.request_id = 7201;
        owned.transaction_id = 7201;
        RuntimeEconomyAssetResult owned_done = completed;
        owned_done.request_id = owned.request_id;
        owned_done.transaction_id = owned.transaction_id;
        settle_probe->_country_economy_asset_requests[owned.request_id] = owned;
        settle_probe->_country_economy_asset_terminal_results[owned.request_id] =
            owned_done;
        settle_probe->defer_country_economy_asset_settlement(owned.request_id);
        std::string flush_error;
        if (!settle_probe->country_economy_asset_settlement_deferred(
                owned.request_id) ||
            !settle_probe->flush_country_economy_asset_commits(flush_error) ||
            settle_probe->_country_economy_asset_committed.count(
                owned.request_id) != 0 ||
            settle_probe->country_authority_drain_idle_locked()) {
            error = "country_economy_asset_self_test_deferred_settle_swept";
            return false;
        }
        settle_probe->release_country_economy_asset_settlement(owned.request_id);
        if (settle_probe->country_economy_asset_settlement_deferred(
                owned.request_id) ||
            !settle_probe->country_authority_drain_idle_locked()) {
            error = "country_economy_asset_self_test_deferred_release_failed";
            return false;
        }
    }
    return true;
}

} // namespace pk
