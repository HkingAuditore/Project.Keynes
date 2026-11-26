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

#include "native_simulation_host_country_assets_section_selftest.inc"

} // namespace pk
