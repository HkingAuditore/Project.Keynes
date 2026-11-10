#include "native_simulation_host.h"

#include <algorithm>
#include <limits>

namespace pk {

bool NativeSimulationHost::command_packet_before(
        const RuntimeCommandPacket &a, const RuntimeCommandPacket &b) {
    if (a.envelope.effective_day != b.envelope.effective_day)
        return a.envelope.effective_day < b.envelope.effective_day;
    if (a.envelope.sequence != b.envelope.sequence)
        return a.envelope.sequence < b.envelope.sequence;
    if (a.submit_order != b.submit_order) return a.submit_order < b.submit_order;
    return a.envelope.request_id < b.envelope.request_id;
}

void NativeSimulationHost::seed_executor_command_orders() {
    // Old wire envelopes omit the live watermark. Rebuild it before either
    // executor can admit new commands, preserving the archive's saved order.
    for (auto &packet : _executor_pending_commands) {
        if (packet.submit_order == 0) {
            packet.submit_order = _command_submit_order.fetch_add(
                1u, std::memory_order_relaxed) + 1u;
        } else {
            auto current = _command_submit_order.load(std::memory_order_relaxed);
            while (current < packet.submit_order &&
                   !_command_submit_order.compare_exchange_weak(
                       current, packet.submit_order, std::memory_order_relaxed)) {}
        }
    }
}

bool NativeSimulationHost::service_save_request(
        std::vector<RuntimeCommandPacket> &pending_commands) {
    if (!_save_requested.load(std::memory_order_acquire)) return false;
    // Pending environment frames describe future days and are regenerated on
    // restore. The caller must first finish any day that already consumed one.
    if (has_pending_climate_input() && _environment_ring.pop_while_day_at_most(
            std::numeric_limits<int64_t>::max()) > 0u) {
        _climate_wait_cv.notify_all();
        _control_cv.notify_all();
    }
    if (has_pending_climate_input() ||
        !_save_requested.exchange(false, std::memory_order_acq_rel)) return false;
    const uint64_t request_id = _save_request_id.load(std::memory_order_acquire);
    RuntimeCommandPacket queued;
    while (pop_command(queued)) pending_commands.push_back(std::move(queued));
    _economy_pending_command_count.store(static_cast<uint32_t>(std::min<size_t>(
        pending_commands.size(), std::numeric_limits<uint32_t>::max())), std::memory_order_release);
    _state.store(RuntimeWorkerState::SAVE_PENDING, std::memory_order_release);
    _worker_timing.set(RuntimeWorkerTiming::SAVE_BUILD);
    build_save_bundle(request_id, pending_commands);
    _worker_timing.set(RuntimeWorkerTiming::OVERHEAD);
    const auto built = std::atomic_load_explicit(&_save_bundle, std::memory_order_acquire);
    if (built == nullptr || built->request_id != request_id) {
        if (save_failure_reason().empty()) {
            char fault[64]{};
            for (size_t i = 0; i + 1 < sizeof(fault) && i < _fault_code.size(); ++i)
                fault[i] = _fault_code[i].load(std::memory_order_relaxed);
            record_save_failure(fault[0] != '\0' ? fault : "save_bundle_not_published");
        }
        _save_failed_request_id.store(request_id, std::memory_order_release);
    }
    _save_request_id.store(0, std::memory_order_release);
    if (_state.load(std::memory_order_acquire) != RuntimeWorkerState::FAULTED)
        _state.store(_paused.load(std::memory_order_acquire)
                ? RuntimeWorkerState::PAUSED : RuntimeWorkerState::RUNNING,
                std::memory_order_release);
    return true;
}

void NativeSimulationHost::service_inline_save_request() {
    if (!inline_daily_mode() || !_save_requested.load(std::memory_order_acquire)) return;
    auto boundary = try_lock_economy_input_capture();
    if (!boundary.owns_lock() || _inline_day_pending.load(std::memory_order_acquire)) return;
    const RuntimeExecutionContext execution_context(this,
        _requested_authority_mask.load(std::memory_order_acquire));
    service_save_request(_executor_pending_commands);
}

} // namespace pk
