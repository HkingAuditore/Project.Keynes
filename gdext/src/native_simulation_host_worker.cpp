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

namespace {
// Peer-stall fault threshold. Production keeps the protocol default; headless
// test suites on a loaded machine may raise it via PK_PEER_STALL_TIMEOUT_MS so
// wall-clock contention is not reported as a protocol deadlock.
uint64_t peer_stall_fault_timeout_ms() {
    static const uint64_t value = [] () -> uint64_t {
        const char *raw = pk::runtime_switch_value(pk::RuntimeSwitch::PK_PEER_STALL_TIMEOUT_MS);
        if (raw == nullptr || raw[0] == '\0')
            return RUNTIME_DAY_STALL_PEER_FAULT_TIMEOUT_MS;
        const unsigned long long parsed = std::strtoull(raw, nullptr, 10);
        return parsed >= RUNTIME_DAY_STALL_PEER_FAULT_TIMEOUT_MS
            ? static_cast<uint64_t>(parsed)
            : RUNTIME_DAY_STALL_PEER_FAULT_TIMEOUT_MS;
    }();
    return value;
}

// Stateless diagnostic tags shared with the daily-plan assembly.
const char *runtime_domain_fault_tag(RuntimeDomainId domain) noexcept {
    switch (domain) {
    case RuntimeDomainId::INPUT_CAPTURE: return "input_capture";
    case RuntimeDomainId::CLIMATE: return "climate";
    case RuntimeDomainId::COUNTRY: return "country";
    case RuntimeDomainId::TRIGGER_INPUT: return "trigger_input";
    case RuntimeDomainId::IDEOLOGY: return "ideology";
    case RuntimeDomainId::EFFECT: return "effect";
    case RuntimeDomainId::MODIFIER: return "modifier";
    case RuntimeDomainId::GAMEPLAY_EFFECT: return "gameplay_effect";
    case RuntimeDomainId::ECONOMY: return "economy";
    case RuntimeDomainId::EVENTS: return "events";
    case RuntimeDomainId::VISUAL: return "visual";
    case RuntimeDomainId::COMMIT: return "commit";
    }
    return "unknown";
}
} // namespace

void NativeSimulationHost::request_stop() {
    _authority_control.revoke();
    RuntimeWorkerState current = _state.load(std::memory_order_acquire);
    if (current == RuntimeWorkerState::STOPPED) return;
    _stage_ops_day_phase_atomic.store(static_cast<uint8_t>(StageOpsDayPhase::Done), std::memory_order_release);
    // Revoke before the worker has actually wound down. The main-thread
    // schedule gate suppresses a promoted domain for as long as this mask names
    // it, so a domain must stop being worker-owned the instant a stop is asked
    // for. Leaving it set until the thread exits would drop the days in
    // between: nobody computes climate while the worker is on its way out.
    // Publish STOPPING before waking the worker. Never overwrite a concurrent
    // terminal state (STOPPED or FAULTED) with a stale stop request.
    // Inline execution has no worker loop to publish STOPPED at an idle boundary.
    const bool inline_idle = inline_daily_mode() &&
        _worker_day_inflight.load(std::memory_order_acquire) == 0u;
    while (current != RuntimeWorkerState::STOPPED &&
           current != RuntimeWorkerState::FAULTED &&
           current != RuntimeWorkerState::STOPPING) {
        if (_state.compare_exchange_weak(current,
                inline_idle ? RuntimeWorkerState::STOPPED : RuntimeWorkerState::STOPPING,
                std::memory_order_acq_rel, std::memory_order_acquire)) break;
    }
    if (inline_idle) _worker_timing.stop();
    _stop_requested.store(true, std::memory_order_release);
    _control_cv.notify_all();
}

void NativeSimulationHost::join_for_destruction() {
    if (_worker.joinable()) _worker.join();
    _retired_workers.wait();
    _authority_control.revoke();
    _state.store(RuntimeWorkerState::STOPPED, std::memory_order_release);
}

void NativeSimulationHost::set_clock(bool paused, double speed_days_per_second) {
    _worker_timing.pause(paused);
    _paused.store(paused, std::memory_order_release);
    _speed_days_per_second.store(std::max(0.0, speed_days_per_second),
                                 std::memory_order_release);
    _control_cv.notify_all();
}

void NativeSimulationHost::set_interactive(bool interactive) {
    _interactive.store(interactive, std::memory_order_release);
    _control_cv.notify_all();
}

void NativeSimulationHost::record_visual_timings(
        double ui_input_to_feedback_ms,
        double visual_apply_ms,
        double gpu_upload_ms) {
    // Clamp and ignore NaN/Inf at the boundary so a broken renderer probe can
    // never poison the diagnostic stream or make a CSV parser fail.
    const auto sanitize = [](double value) {
        return std::isfinite(value) ? std::max(0.0, value) : 0.0;
    };
    _ui_input_to_feedback_ms.store(sanitize(ui_input_to_feedback_ms),
                                   std::memory_order_release);
    _visual_apply_ms.store(sanitize(visual_apply_ms), std::memory_order_release);
    _gpu_upload_ms.store(sanitize(gpu_upload_ms), std::memory_order_release);
}

bool NativeSimulationHost::has_pending_climate_input() const {
    // 仅 ACTIVE Climate 有"未消费输入 = 有活可干"语义；SHADOW/OFF 恒 false，
    // 否则 begin_save 会在 ring/latest 未清时永久等（save_poll_timeout）。
    if (_mode.load(std::memory_order_acquire) != RuntimeSimulationMode::ACTIVE ||
        (_requested_authority_mask.load(std::memory_order_acquire) &
         runtime_domain_mask(RuntimeDomainId::CLIMATE)) == 0u) {
        return false;
    }
    return _environment_ring.size() > 0u;
}

bool NativeSimulationHost::environment_ring_full() const {
    return !_environment_ring.has_capacity();
}

size_t NativeSimulationHost::environment_ring_pending() const {
    return _environment_ring.size();
}

bool NativeSimulationHost::environment_ring_has_capacity() const {
    return _environment_ring.has_capacity();
}

uint32_t NativeSimulationHost::day_stall_reason_mask() const {
    uint32_t mask = _day_stall_reason_mask.load(std::memory_order_acquire);
    if (!_environment_ring.has_capacity()) {
        mask |= RUNTIME_DAY_STALL_CLIMATE_CAPACITY;
    }
    if (_economy_input_requested_day.load(std::memory_order_acquire) >= 0) {
        mask |= RUNTIME_DAY_STALL_ECONOMY_INPUT;
    }
    if (_country_worker_protocol.pending_intents != 0) {
        mask |= RUNTIME_DAY_STALL_COUNTRY_PEER;
    }
    return mask;
}

void NativeSimulationHost::note_day_stall(uint32_t bits, int64_t day) {
    if (bits == 0u) return;
    _day_stall_reason_mask.fetch_or(bits, std::memory_order_acq_rel);
    _day_stall_day.store(day, std::memory_order_release);
    const bool peer_bits =
        (bits & (RUNTIME_DAY_STALL_COUNTRY_PEER | RUNTIME_DAY_STALL_EFFECT_ACK |
                 RUNTIME_DAY_STALL_IDEOLOGY_ACK |
                 RUNTIME_DAY_STALL_FISCAL_PEER)) != 0u;
    if (!peer_bits) return;
    uint64_t expected = 0;
    const uint64_t started = now_us();
    _day_stall_peer_since_us.compare_exchange_strong(
        expected, started, std::memory_order_acq_rel, std::memory_order_acquire);
}

void NativeSimulationHost::note_day_park(uint32_t domain_mask,
                                        const char *reason) {
    _day_park_domain_mask.store(domain_mask, std::memory_order_release);
    const char *text = reason != nullptr ? reason : "";
    size_t index = 0;
    for (; index + 1 < _day_park_reason.size() && text[index] != '\0'; ++index) {
        _day_park_reason[index].store(text[index], std::memory_order_release);
    }
    for (; index < _day_park_reason.size(); ++index) {
        _day_park_reason[index].store('\0', std::memory_order_release);
    }
}

void NativeSimulationHost::clear_day_stall_bits(uint32_t bits) {
    if (bits == 0u) return;
    uint32_t current = _day_stall_reason_mask.load(std::memory_order_acquire);
    while ((current & bits) != 0u) {
        if (_day_stall_reason_mask.compare_exchange_weak(
                current, current & ~bits, std::memory_order_acq_rel,
                std::memory_order_acquire)) {
            break;
        }
    }
    constexpr uint32_t kPeerTimerBits =
        RUNTIME_DAY_STALL_COUNTRY_PEER | RUNTIME_DAY_STALL_EFFECT_ACK |
        RUNTIME_DAY_STALL_IDEOLOGY_ACK | RUNTIME_DAY_STALL_FISCAL_PEER |
        RUNTIME_DAY_STALL_ECONOMY_INPUT;
    if ((_day_stall_reason_mask.load(std::memory_order_acquire) &
         kPeerTimerBits) == 0u) {
        _day_stall_peer_since_us.store(0, std::memory_order_release);
    }
    if ((_day_stall_reason_mask.load(std::memory_order_acquire) &
         ~RUNTIME_DAY_STALL_CLIMATE_CAPACITY) == 0u) {
        _day_stall_day.store(-1, std::memory_order_release);
    }
}

void NativeSimulationHost::clear_day_stall_peer_bits() {
    clear_day_stall_bits(RUNTIME_DAY_STALL_COUNTRY_PEER |
                         RUNTIME_DAY_STALL_EFFECT_ACK |
                         RUNTIME_DAY_STALL_IDEOLOGY_ACK |
                         RUNTIME_DAY_STALL_FISCAL_PEER |
                         RUNTIME_DAY_STALL_ECONOMY_INPUT);
}

bool NativeSimulationHost::fault_if_peer_stall_timed_out(
        int64_t day, const char *fault_code) {
    // Derived-only stalls (pending_intents without note_day_stall) never armed
    // the timer — capacity forensics then showed peer_ms=0 forever. Arm here.
    if (_day_stall_peer_since_us.load(std::memory_order_acquire) == 0u &&
        (_country_worker_protocol.pending_intents != 0 ||
         (_day_stall_reason_mask.load(std::memory_order_acquire) &
          (RUNTIME_DAY_STALL_COUNTRY_PEER | RUNTIME_DAY_STALL_EFFECT_ACK |
           RUNTIME_DAY_STALL_FISCAL_PEER)) != 0u)) {
        note_day_stall(RUNTIME_DAY_STALL_COUNTRY_PEER |
                           RUNTIME_DAY_STALL_EFFECT_ACK,
                       day);
    }
    const uint64_t since =
        _day_stall_peer_since_us.load(std::memory_order_acquire);
    if (since == 0u) return false;
    const uint64_t elapsed_ms = (now_us() - since) / 1000u;
    if (elapsed_ms < peer_stall_fault_timeout_ms()) return false;
    const uint32_t mask = day_stall_reason_mask();
    const std::string fault_line = pk::log_format(
        "[day-stall-fault] day=%d stall=0x%x peer_ms=%d code=%s ring=%d",
        day, static_cast<int64_t>(mask), static_cast<int64_t>(elapsed_ms),
        std::string(fault_code != nullptr ? fault_code : "peer_stall_timeout").c_str(),
        static_cast<int64_t>(_environment_ring.size()));
    // print + printerr: Godot console may hide stderr-only lines.
    pk::log_line(fault_line);
    pk::log_line(fault_line, true);
    set_fault(fault_code != nullptr && fault_code[0] != '\0'
                  ? fault_code
                  : "peer_stall_timeout");
    return true;
}

void NativeSimulationHost::worker_main() {
    const RuntimeExecutionContext execution_context(this,
        _requested_authority_mask.load(std::memory_order_acquire));
    _worker_timing.pause(_paused.load(std::memory_order_acquire));
    _worker_timing.start();
#if defined(_WIN32)
    SetThreadPriority(GetCurrentThread(), THREAD_PRIORITY_BELOW_NORMAL);
#endif
    _state.store(_paused.load(std::memory_order_acquire)
            ? RuntimeWorkerState::PAUSED : RuntimeWorkerState::RUNNING,
            std::memory_order_release);
    auto last = std::chrono::steady_clock::now();
    // Allocate the bounded protocol capacity once when the worker starts.
    // Daily command processing must not grow a vector in the simulation hot
    // loop when a UI burst happens to exceed the usual batch size.
    std::vector<RuntimeCommandPacket> pending_commands;
    pending_commands.reserve(RUNTIME_COMMAND_QUEUE_CAPACITY);
    int64_t logged_pending_day = -1;
    uint32_t logged_pending_mask = 0;
    int64_t events_failed_wait_day = -1;
    uint64_t events_failed_since_us = 0;
    size_t pending_begin = 0;
    if (!_executor_pending_commands.empty()) {
        pending_commands = std::move(_executor_pending_commands);
    }
    std::vector<RuntimeCommandReceipt> day_receipts;
    day_receipts.reserve(RUNTIME_RECEIPT_QUEUE_CAPACITY);
    bool pending_commands_dirty = !pending_commands.empty();
    const auto compact_pending_commands = [&](bool force = false) {
        if (pending_begin == 0) return;
        if (pending_begin >= pending_commands.size()) {
            pending_commands.clear();
            pending_begin = 0;
            pending_commands_dirty = false;
            return;
        }
        // Front consumption is the common path. Compact only after a sizeable
        // prefix is dead so daily command handling stays O(1) amortized while
        // a save still receives a contiguous active tail.
        if (!force && pending_begin < 256u && pending_begin * 2u < pending_commands.size()) return;
        const auto active_begin = pending_commands.begin() +
            static_cast<ptrdiff_t>(pending_begin);
        std::move(active_begin, pending_commands.end(), pending_commands.begin());
        pending_commands.resize(pending_commands.size() - pending_begin);
        pending_begin = 0;
    };
    const auto publish_pending_count = [&]() {
        const size_t active = pending_commands.size() >= pending_begin
            ? pending_commands.size() - pending_begin : 0u;
        _economy_pending_command_count.store(static_cast<uint32_t>(std::min<size_t>(
            active, std::numeric_limits<uint32_t>::max())),
            std::memory_order_release);
        // A switch audit should measure the command that is still crossing
        // the boundary, never an unrelated command from an earlier epoch.
        if (active == 0u &&
            _command_enqueue_pos.load(std::memory_order_acquire) ==
                _command_dequeue_pos.load(std::memory_order_acquire)) {
            _last_command_admitted_us.store(0u, std::memory_order_release);
        }
    };
    publish_pending_count();
    std::shared_ptr<const RuntimeEnvironmentSnapshot> active_environment;
    try {
        while (!_stop_requested.load(std::memory_order_acquire) &&
               _state.load(std::memory_order_acquire) != RuntimeWorkerState::FAULTED) {
            if (_stop_requested.load(std::memory_order_acquire)) break;

            const bool retained_day_pending = active_environment != nullptr &&
                active_environment->day == _committed_day.load(std::memory_order_acquire) + 1;
            if (_save_requested.load(std::memory_order_acquire) && !retained_day_pending) {
                compact_pending_commands(true);
                if (service_save_request(pending_commands)) {
                    pending_commands_dirty = true;
                    publish_pending_count();
                    if (_state.load(std::memory_order_acquire) == RuntimeWorkerState::FAULTED)
                        break;
                    last = std::chrono::steady_clock::now();
                    continue;
                }
            }

            // 自动迁移在 worker 自己释放上一日边界后尝试，不再依赖主线程
            // 抢中两天之间的短暂空隙。沿用 M6 全部准入检查和审计。
            if (_economy_auto_pod_active.load(std::memory_order_acquire) &&
                _mode.load(std::memory_order_acquire) == RuntimeSimulationMode::ACTIVE &&
                _economy_production_runtime != nullptr &&
                !_economy_production_runtime->formula_owned_bound() &&
                _stage_ops_day_phase == StageOpsDayPhase::Done &&
                _economy_pod_authority.pod_active_ready() &&
                !_save_requested.load(std::memory_order_acquire) &&
                !_stop_requested.load(std::memory_order_acquire)) {
                std::string switch_error;
                switch_economy_authority(RuntimeEconomyAuthorityMode::POD_ACTIVE,
                                         switch_error);
            }
            const bool paused = _paused.load(std::memory_order_acquire);
            const double speed = _speed_days_per_second.load(std::memory_order_acquire);
            const bool climate_driven =
                _mode.load(std::memory_order_acquire) == RuntimeSimulationMode::ACTIVE &&
                (_requested_authority_mask.load(std::memory_order_acquire) &
                 runtime_domain_mask(RuntimeDomainId::CLIMATE)) != 0u;
            const bool climate_pending = has_pending_climate_input() || retained_day_pending;
            if ((climate_driven && !climate_pending) ||
                (!climate_driven && (paused || speed <= 0.0 || !std::isfinite(speed)))) {
                if (_stop_requested.load(std::memory_order_acquire)) break;
                _state.store(RuntimeWorkerState::PAUSED, std::memory_order_release);
                last = std::chrono::steady_clock::now();
                std::unique_lock<std::mutex> lock(_control_mutex);
                _worker_timing.set(RuntimeWorkerTiming::INPUT_WAIT);
                _control_cv.wait(lock, [&] {
                    return _stop_requested.load(std::memory_order_acquire) ||
                        _save_requested.load(std::memory_order_acquire) ||
                        (climate_driven ? (has_pending_climate_input() || retained_day_pending) :
                            (!_paused.load(std::memory_order_acquire) &&
                             _speed_days_per_second.load(std::memory_order_acquire) > 0.0));
                });
                _worker_timing.set(RuntimeWorkerTiming::OVERHEAD);
                continue;
            }
            if (_stop_requested.load(std::memory_order_acquire)) break;
            _state.store(RuntimeWorkerState::RUNNING, std::memory_order_release);
            const auto drain_commands = [&] {
                RuntimeCommandPacket incoming;
                while (pop_command(incoming)) {
                    pending_commands.push_back(incoming);
                    pending_commands_dirty = true;
                }
                publish_pending_count();
            };
            const bool country_delivery_boundary =
                _mode.load(std::memory_order_acquire) == RuntimeSimulationMode::ACTIVE &&
                (_requested_authority_mask.load(std::memory_order_acquire) &
                 runtime_domain_mask(RuntimeDomainId::COUNTRY)) != 0u;
            if (!country_delivery_boundary) drain_commands();
            const auto now = std::chrono::steady_clock::now();
            const double elapsed = std::chrono::duration<double>(now - last).count();
            last = now;
            double debt = climate_driven ? 1.0 : std::min(100.0,
                _time_debt_days.load(std::memory_order_relaxed) + elapsed * speed);
            int64_t target_days = static_cast<int64_t>(debt);
            if (target_days <= 0) {
                _time_debt_days.store(debt, std::memory_order_release);
                const double seconds_until_day = std::max(0.001, (1.0 - debt) / speed);
                std::unique_lock<std::mutex> lock(_control_mutex);
                _worker_timing.set(RuntimeWorkerTiming::CLOCK_WAIT);
                _control_cv.wait_until(lock, std::chrono::steady_clock::now() +
                    std::chrono::duration_cast<std::chrono::steady_clock::duration>(
                        std::chrono::duration<double>(seconds_until_day)));
                _worker_timing.set(RuntimeWorkerTiming::OVERHEAD);
                continue;
            }
            target_days = std::min<int64_t>(target_days, 8);
            debt -= static_cast<double>(target_days);
            _time_debt_days.store(std::min(100.0, debt), std::memory_order_release);
            for (int64_t step = 0; step < target_days; ++step) {
                if (_stop_requested.load(std::memory_order_acquire)) break;
                const int64_t from_day = _committed_day.load(std::memory_order_acquire);
                const int64_t day = from_day + 1;
                // Yield between days until every main-thread requester has
                // completed its protected inbox service; no authority lock is
                // held while waiting. Country commands are drained afterwards.
                if (_main_boundary_service_requested.load(std::memory_order_acquire) != 0u) {
                    std::unique_lock<std::mutex> control_lock(_control_mutex);
                    while (_main_boundary_service_requested.load(
                               std::memory_order_acquire) != 0u &&
                           !_stop_requested.load(std::memory_order_acquire)) {
                        // Completion is an atomic transport signal. Bound the
                        // sleep so a notify between predicate and wait cannot
                        // strand the worker after the main thread completed.
                        _control_cv.wait_for(control_lock, std::chrono::milliseconds(5));
                    }
                    if (_stop_requested.load(std::memory_order_acquire)) break;
                }
                // Keep the authority switch closed across the whole semantic
                // day transaction through publication and generation release.
                // Counting only execute_day_plan() leaves publication unprotected.
                _worker_timing.set(RuntimeWorkerTiming::BOUNDARY_WAIT);
                std::unique_lock<std::mutex> boundary_lock(
                    _economy_authority_boundary_mutex);
                _worker_timing.set(RuntimeWorkerTiming::OVERHEAD);
                AtomicCounterScope day_scope(_worker_day_inflight);
                if (try_fault_injection("worker.inflight.before")) {
                    break;
                }
                // Include commands delivered during the main boundary service;
                // draining before that service made their admission race a day.
                if (country_delivery_boundary) drain_commands();
                day_receipts.clear();
                if (pending_commands_dirty) {
                    std::stable_sort(pending_commands.begin() +
                        static_cast<ptrdiff_t>(pending_begin), pending_commands.end(),
                    command_packet_before);
                    pending_commands_dirty = false;
                }
                size_t consumed_commands = pending_begin;
                std::vector<RuntimeCommandPacket> day_commands;
                day_commands.reserve(16u);
                uint64_t admitted_submit_order = 0;
                for (size_t index = pending_begin;
                     index < pending_commands.size(); ++index) {
                    admitted_submit_order = std::max(
                        admitted_submit_order,
                        pending_commands[index].submit_order);
                }
                for (; consumed_commands < pending_commands.size(); ++consumed_commands) {
                    const RuntimeCommandPacket &command = pending_commands[consumed_commands];
                    if (command.envelope.effective_day > day) break;
                    day_commands.push_back(command);
                    RuntimeCommandReceipt receipt;
                    receipt.request_id = command.envelope.request_id;
                    receipt.producer_id = command.envelope.producer_id;
                    receipt.sequence = command.envelope.sequence;
                    receipt.effective_day = std::max(command.envelope.effective_day, day);
                    receipt.generation = _generation.load(std::memory_order_relaxed) + 1;
                    const bool domain_valid =
                        command.envelope.domain >= static_cast<uint16_t>(RuntimeDomainId::INPUT_CAPTURE) &&
                        command.envelope.domain <= static_cast<uint16_t>(RuntimeDomainId::COMMIT);
                    const bool events_probe = domain_valid &&
                        static_cast<RuntimeDomainId>(command.envelope.domain) ==
                            RuntimeDomainId::EVENTS &&
                        (_mode.load(std::memory_order_acquire) == RuntimeSimulationMode::SHADOW ||
                         _mode.load(std::memory_order_acquire) == RuntimeSimulationMode::ACTIVE) &&
                        _events_probe_enabled.load(std::memory_order_acquire);
                    const bool modifier_shadow = domain_valid &&
                        static_cast<RuntimeDomainId>(command.envelope.domain) ==
                            RuntimeDomainId::MODIFIER &&
                        _mode.load(std::memory_order_acquire) ==
                            RuntimeSimulationMode::SHADOW &&
                        _modifier_pod_configured;
                    const bool domain_implemented = domain_valid &&
                        ((implemented_domain_mask() & runtime_domain_mask(
                            static_cast<RuntimeDomainId>(command.envelope.domain))) != 0u ||
                         events_probe || modifier_shadow);
                    const bool payload_valid =
                        command.envelope.payload_offset <= RUNTIME_MAX_COMMAND_PAYLOAD &&
                        command.envelope.payload_size <= RUNTIME_MAX_COMMAND_PAYLOAD &&
                        command.envelope.payload_offset + command.envelope.payload_size <=
                            RUNTIME_MAX_COMMAND_PAYLOAD;
                    RuntimeModifierPodCommand modifier_command;
                    const bool modifier_payload_valid = !modifier_shadow ||
                        (decode_modifier_packet(command, modifier_command) &&
                         modifier_packet_shape_valid(modifier_command));
                    if (!payload_valid || !modifier_payload_valid) {
                        receipt.code = RuntimeReceiptCode::INVALID_PAYLOAD;
                    } else if (!domain_implemented || command.envelope.opcode == 0) {
                        // Unknown domain/opcode is a deterministic preflight
                        // rejection. It remains a receipt, never a dropped
                        // command, so callers can reconcile their request.
                        receipt.code = RuntimeReceiptCode::PREFLIGHT_REJECTED;
                    } else {
                        receipt.code = RuntimeReceiptCode::OK;
                    }
                    day_receipts.push_back(receipt);
                }
                // 与 build_day_plan 钉死同一份输入：同日重试不得换 latest。
                // 跨日时（environment.day < worker 下一拍）再从 FIFO 取最旧。
                if (!active_environment ||
                    active_environment->day < day) {
                    active_environment = environment_input_for_plan();
                }
                const auto &environment = active_environment;
                // 在执行前采样唤醒游标，避免执行期间已到达的 peer ACK 被漏掉。
                const uint64_t attempt_trace_signal =
                    _climate_trace_signal.load(std::memory_order_acquire);
                const uint64_t attempt_peer_signal =
                    _country_peer_signal.load(std::memory_order_acquire);
                const uint64_t attempt_environment_signal =
                    _environment_generation.load(std::memory_order_acquire);
                const uint64_t attempt_economy_signal =
                    _economy_input_signal.load(std::memory_order_acquire);
                _worker_timing.set(RuntimeWorkerTiming::EXECUTE);
                _day_waterfall.begin(day);
                RuntimeDayPlan day_plan = build_day_plan(
                    day, speed, environment.get(), admitted_submit_order);
                _day_waterfall.mark(RuntimeDayWaterfall::BUILD_PLAN);
                const auto day_attempt_started = std::chrono::steady_clock::now();
                const RuntimeDayCommit day_commit = execute_day_plan(
                    day_plan, environment.get(), day_commands, day_receipts,
                    admitted_submit_order);
                _day_waterfall.mark(RuntimeDayWaterfall::POST_LOOP);
                if (day % 100 == 0) {
                    std::fprintf(stderr, "[runtime-day-cost] day=%lld ok=%u ms=%.3f\n",
                        static_cast<long long>(day), static_cast<unsigned>(day_commit.preflight_ok),
                        std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - day_attempt_started).count());
                }
                bool country_commands_terminal = !day_commands.empty();
                if (country_commands_terminal) {
                    std::lock_guard<std::mutex> country_lock(
                        _country_transport_mutex);
                    for (const RuntimeCommandPacket &command : day_commands) {
                        if (command.envelope.domain != static_cast<uint16_t>(
                                RuntimeDomainId::COUNTRY) ||
                            command.envelope.request_id == 0 ||
                            _country_command_terminals.find(
                                command.envelope.request_id) ==
                                _country_command_terminals.end()) {
                            country_commands_terminal = false;
                            break;
                        }
                    }
                }
                // Command ownership transfers only after the semantic day
                // commits, or after Country has published a deterministic
                // terminal rejection. A missing/future Climate frame retries
                // the same day; consuming commands before that preflight
                // silently lost one-shot Effect/Bio ingress.
                if (day_commit.preflight_ok != 0 ||
                    country_commands_terminal) {
                    for (const RuntimeCommandReceipt &receipt : day_receipts)
                        push_receipt(receipt);
                    if (consumed_commands > pending_begin) {
                        // Country may idempotent-skip an already-committed day
                        // while Effect ACK packets still sit in day_commands.
                        // Dropping those on a successful M5 day leaves
                        // PREFLIGHTED transactions without a Host receipt.
                        std::vector<RuntimeCommandPacket> retain_country;
                        if (day_commit.preflight_ok != 0 &&
                            !country_commands_terminal) {
                            std::lock_guard<std::mutex> country_lock(
                                _country_transport_mutex);
                            for (size_t index = pending_begin;
                                 index < consumed_commands; ++index) {
                                const RuntimeCommandPacket &command =
                                    pending_commands[index];
                                if (command.envelope.domain !=
                                        static_cast<uint16_t>(
                                            RuntimeDomainId::COUNTRY) ||
                                    command.envelope.request_id == 0) {
                                    continue;
                                }
                                if (_country_command_terminals.find(
                                        command.envelope.request_id) ==
                                    _country_command_terminals.end()) {
                                    retain_country.push_back(command);
                                }
                            }
                        }
                        pending_begin = consumed_commands;
                        compact_pending_commands();
                        if (!retain_country.empty()) {
                            pending_commands.insert(
                                pending_commands.begin() +
                                    static_cast<ptrdiff_t>(pending_begin),
                                std::make_move_iterator(retain_country.begin()),
                                std::make_move_iterator(retain_country.end()));
                        }
                        publish_pending_count();
                    }
                }
                _day_waterfall.mark(RuntimeDayWaterfall::WORKER_RECEIPTS);
                if (day_commit.preflight_ok == 0) {
                    // execute_day_plan may already have set_fault (ledger /
                    // compact fatal). Do not arm fiscal or prepare on a dead
                    // worker — that printed empty yield= and hid the real code.
                    if (_state.load(std::memory_order_acquire) ==
                        RuntimeWorkerState::FAULTED) {
                        break;
                    }
                    const uint32_t missing = _requested_authority_mask.load(
                        std::memory_order_acquire) & ~day_commit.completed_domain_mask;
                    // Cold-path diagnostic: expose which domain parks the day
                    // while preflight_ok stays 0. Only runs on the failure
                    // branch and is throttled to the first few occurrences, so
                    // healthy days pay nothing but a compare.
                    {
                        static std::atomic<int> s_day_diag_tick{0};
                        const int tick = s_day_diag_tick.fetch_add(
                            1, std::memory_order_relaxed);
                        if (tick < 24 && tick % 4 == 0) {
                            std::string stage_text;
                            for (uint32_t si = 0; si < day_plan.stage_count; ++si) {
                                stage_text += runtime_domain_fault_tag(
                                    day_plan.stages[si].domain);
                                stage_text += ":";
                                stage_text += std::to_string(
                                    static_cast<unsigned>(
                                        day_plan.stages[si].completed));
                                stage_text += " ";
                            }
                            const int64_t env_day = environment != nullptr
                                ? environment->day : int64_t{-1};
                            const uint64_t env_gen = environment != nullptr
                                ? environment->generation : uint64_t{0};
                            // Plain string concatenation: MSVC's printf format
                            // checker mis-counts arguments in concatenated
                            // literals, so hand it a single "%s".
                            std::string diag;
                            diag += "[runtime-day-diag] day=" +
                                std::to_string(static_cast<long long>(day));
                            diag += " preflight=" + std::to_string(
                                static_cast<unsigned>(day_commit.preflight_ok));
                            diag += " missing=" + std::to_string(
                                static_cast<unsigned long long>(missing));
                            diag += " completed=" + std::to_string(
                                static_cast<unsigned long long>(
                                    day_commit.completed_domain_mask));
                            diag += " stages=" + std::to_string(
                                static_cast<unsigned>(
                                    day_commit.completed_stage_count)) +
                                "/" + std::to_string(
                                static_cast<unsigned>(day_plan.stage_count));
                            diag += " env_day=" + std::to_string(
                                static_cast<long long>(env_day));
                            diag += " env_gen=" + std::to_string(
                                static_cast<unsigned long long>(env_gen));
                            diag += " plan_day=" + std::to_string(
                                static_cast<long long>(day_plan.context.day));
                            diag += " plan_gen=" + std::to_string(
                                static_cast<unsigned long long>(
                                    day_plan.context.input_generation));
                            diag += " climate_store_day=" + std::to_string(
                                static_cast<long long>(
                                    _climate_authority.store().committed_day));
                            diag += " ring=" + std::to_string(
                                static_cast<unsigned long long>(
                                    _environment_ring.size()));
                            diag += " stages=" + stage_text + "\n";
                            std::fprintf(stderr, "%s", diag.c_str());
                        }
                    }
                    // Full domain coverage with preflight_ok=0 is a spurious
                    // barrier: parking here leaves future Climate envs stuck in
                    // a full ring and nails WorldClock on capacity forever.
                    if (missing == 0u &&
                        _requested_authority_mask.load(std::memory_order_acquire) !=
                            0u) {
                        static std::atomic<int> s_full_mask_preflight_left{8};
                        const int64_t climate_committed =
                            _climate_authority.store().committed_day;
                        if (s_full_mask_preflight_left.fetch_sub(
                                1, std::memory_order_relaxed) > 0) {
                            pk::log_info(
                                "[runtime-day-wait] day=%d missing=0x0 "
                                "forcing advance (spurious preflight_ok=0) "
                                "ring=%d climate_committed=%d continuation=%d "
                                "stall=0x%x",
                                day,
                                static_cast<int64_t>(_environment_ring.size()),
                                climate_committed,
                                static_cast<int64_t>(day_commit.continuation_pending),
                                static_cast<int64_t>(day_stall_reason_mask()));
                        }
                        // Only drop envs for this worker day (and earlier).
                        // Never drain through climate_committed when it is
                        // ahead — that erases futures Host already queued for
                        // catch-up days and leaves the FIFO empty/mismatched,
                        // after which Host sticks on capacity forever.
                        if (_environment_ring.pop_while_day_at_most(day) > 0u) {
                            _climate_wait_cv.notify_all();
                            _control_cv.notify_all();
                        }
                        clear_day_stall_peer_bits();
                        // Force the next iteration to re-peek FIFO instead of
                        // retaining a drained shared_ptr as active_environment.
                        active_environment.reset();
                        // Fall through to the success path below.
                    } else {
                    // 主线程唯一能读到「今天缺哪个域」的地方。stall 位只描述外部
                    // 等待（环满 / peer / 经济输入），缺口既不设位也不发 CV 时它恒
                    // 为 0x0，日志里只剩一句无声的冻结；这四个值把缺口钉住。
                    _day_wait_day.store(day, std::memory_order_release);
                    _day_wait_missing_mask.store(missing, std::memory_order_release);
                    _day_wait_env_day.store(
                        environment != nullptr ? environment->day : int64_t{-1},
                        std::memory_order_release);
                    _day_wait_ring.store(static_cast<uint32_t>(_environment_ring.size()),
                                         std::memory_order_release);
                    if (logged_pending_day != day || logged_pending_mask != missing) {
                        logged_pending_day = day;
                        logged_pending_mask = missing;
                        std::fprintf(stderr, "[runtime-day-wait] day=%lld env_day=%lld missing=0x%x stall=0x%x economy_input=%lld\n",
                            static_cast<long long>(day),
                            static_cast<long long>(environment ? environment->day : -1),
                            missing,
                            day_stall_reason_mask(),
                            static_cast<long long>(economy_input_requested_day()));
                        char country_fallback[64];
                        size_t fb = 0;
                        for (; fb + 1 < sizeof(country_fallback) &&
                               fb < _country_pod_fallback_reason.size(); ++fb) {
                            country_fallback[fb] =
                                _country_pod_fallback_reason[fb].load(
                                    std::memory_order_acquire);
                            if (country_fallback[fb] == '\0') break;
                        }
                        country_fallback[fb] = '\0';
                        pk::log_info(
                            "[runtime-day-wait] day=%d env_day=%d missing=0x%x "
                            "stall=0x%x economy_input=%d ring=%d country=%s",
                            day,
                            environment ? environment->day : -1,
                            static_cast<int64_t>(missing),
                            static_cast<int64_t>(day_stall_reason_mask()),
                            economy_input_requested_day(),
                            static_cast<int64_t>(_environment_ring.size()),
                            country_fallback);
                        // Economy incomplete with no stall bit has no CV wake
                        // source once Climate capacity fills. Arm a peer stall
                        // so the timeout fault surfaces instead of a silent hang.
                        if ((missing & runtime_domain_mask(
                                 RuntimeDomainId::ECONOMY)) != 0u &&
                            (day_stall_reason_mask() &
                             (RUNTIME_DAY_STALL_COUNTRY_PEER |
                              RUNTIME_DAY_STALL_EFFECT_ACK |
                              RUNTIME_DAY_STALL_FISCAL_PEER |
                              RUNTIME_DAY_STALL_ECONOMY_INPUT)) == 0u) {
                            note_day_stall(RUNTIME_DAY_STALL_FISCAL_PEER, day);
                            // Same drain as Economy fiscal-pending: free Host
                            // capacity so peer/fiscal pumps can make progress.
                            const int64_t climate_committed =
                                _climate_authority.store().committed_day;
                            if (climate_committed >= 0 &&
                                _environment_ring.pop_while_day_at_most(
                                    climate_committed) > 0u) {
                                _climate_wait_cv.notify_all();
                                _control_cv.notify_all();
                            }
                            char yield_reason[48];
                            size_t yi = 0;
                            for (; yi + 1 < sizeof(yield_reason) &&
                                   yi < _economy_yield_reason.size(); ++yi) {
                                yield_reason[yi] = _economy_yield_reason[yi].load(
                                    std::memory_order_relaxed);
                                if (yield_reason[yi] == '\0') break;
                            }
                            yield_reason[yi] = '\0';
                            pk::log_info(
                                "[runtime-day-wait] day=%d armed fiscal stall "
                                "for economy-missing-without-stall ring=%d "
                                "yield=%s climate_committed=%d",
                                day,
                                static_cast<int64_t>(_environment_ring.size()),
                                std::string(yield_reason).c_str(),
                                climate_committed);
                        }
                    }
                    // Events 硬失败不设任何 stall 位，peer 超时永不触发；
                    // 环满后主线程停在 capacity barrier，表现为无声卡死。
                    if ((missing & runtime_domain_mask(RuntimeDomainId::EVENTS)) != 0u &&
                        _events_failed_day.load(std::memory_order_acquire) == day) {
                        if (events_failed_wait_day != day) {
                            events_failed_wait_day = day;
                            events_failed_since_us = now_us();
                        } else if ((now_us() - events_failed_since_us) / 1000u >=
                                   peer_stall_fault_timeout_ms()) {
                            char events_reason[64];
                            size_t er = 0;
                            for (; er + 1 < sizeof(events_reason) &&
                                   er < _events_pod_fallback_reason.size(); ++er) {
                                events_reason[er] = _events_pod_fallback_reason[er].load(
                                    std::memory_order_acquire);
                                if (events_reason[er] == '\0') break;
                            }
                            events_reason[er] = '\0';
                            const std::string fault_line = pk::log_format(
                                "[day-stall-fault] day=%d events_day_failed reason=%s "
                                "ring=%d",
                                day, std::string(events_reason).c_str(),
                                static_cast<int64_t>(_environment_ring.size()));
                            pk::log_line(fault_line);
                            pk::log_line(fault_line, true);
                            set_fault("events_day_failed");
                            break;
                        }
                    } else {
                        events_failed_wait_day = -1;
                    }

                    if (_state.load(std::memory_order_acquire) ==
                        RuntimeWorkerState::FAULTED) {
                        break;
                    }
                    // An input/reference barrier failure must not advance the
                    // committed clock. Wait for the main thread to publish
                    // the matching reference or for a control message; this
                    // is a condition-variable wait, not a polling sleep.
                    if (day_commit.continuation_pending == 0) {
                        _time_debt_days.store(std::min(100.0,
                            _time_debt_days.load(std::memory_order_relaxed) + 1.0),
                            std::memory_order_release);
                    }
                    // Same-day Economy→Country asset prepare must happen before
                    // parking. Otherwise Climate ring stays full, main cannot
                    // publish, and country_peer_signal never fires.
                    std::string prepare_error;
                    const uint32_t prepared_before_wait =
                        prepare_economy_origin_country_assets(prepare_error);
                    _day_waterfall.mark(RuntimeDayWaterfall::WORKER_RETRY);
                    if (!prepare_error.empty()) {
                        set_fault(prepare_error.c_str());
                        break;
                    }
                    // 捕获输入时主线程必须可取得边界锁；等待期间没有公式写入。
                    boundary_lock.unlock();
                    // Peer-stall timeout must win over prepare-spin. Otherwise
                    // prepared>0 busy-retries the day forever while Host is
                    // stuck on a full Climate ring (day≈2745 hang: armed
                    // fiscal stall, weather LUT for minutes, then faulted).
                    if (fault_if_peer_stall_timed_out(
                            day, "day_wait_peer_stall_timeout")) {
                        break;
                    }
                    if (prepared_before_wait > 0u) {
                        // Origin assets are now pollable; retry this day without
                        // waiting for an external wake that may never arrive.
                        break;
                    }
                    // Country plan rejected a research enqueue (queue full /
                    // already queued) and published terminals. The bad command
                    // is consumed; parking forever with stall=0x0 freezes the
                    // calendar. Retry immediately.
                    if ((missing & runtime_domain_mask(
                             RuntimeDomainId::COUNTRY)) != 0u &&
                        country_commands_terminal) {
                        char reject_reason[64];
                        size_t rb = 0;
                        for (; rb + 1 < sizeof(reject_reason) &&
                               rb < _country_pod_fallback_reason.size(); ++rb) {
                            reject_reason[rb] =
                                _country_pod_fallback_reason[rb].load(
                                    std::memory_order_acquire);
                            if (reject_reason[rb] == '\0') break;
                        }
                        reject_reason[rb] = '\0';
                        if (std::strcmp(reject_reason,
                                        "country_research_queue_full") == 0 ||
                            std::strcmp(reject_reason,
                                        "country_research_already_queued") ==
                                0) {
                            break;
                        }
                    }
                    const auto next_input = _environment_ring.peek_oldest();
                    const bool stale_input_consumed = environment != nullptr &&
                        environment->day < day && next_input != nullptr &&
                        next_input->generation != environment->generation;
                    const uint64_t trace_signal = attempt_trace_signal;
                    // Under ACTIVE Climate authority there is no trace signal
                    // to wait for: production is suppressed and the only input
                    // that can unblock the day is a fresh environment publish
                    // from the main thread. Waiting on the trace alone would
                    // park the worker forever the first time the environment
                    // is not yet available.
                    const uint64_t environment_signal = attempt_environment_signal;
                    const uint64_t country_peer_signal = attempt_peer_signal;
                    std::unique_lock<std::mutex> lock(_control_mutex);
                    _day_waterfall.mark(RuntimeDayWaterfall::WORKER_RETRY);
                    _day_waterfall.finish(false, day_commit.completed_domain_mask);
                    _worker_timing.set(RuntimeWorkerTiming::INPUT_WAIT);
                    // Timed wait: peer-stall timeout must be polled while the
                    // Climate ring is full and no CV signal arrives.
                    constexpr auto kDayWaitSlice =
                        std::chrono::milliseconds(250);
                    _control_cv.wait_for(lock, kDayWaitSlice, [&] {
                        // Match the save admission condition above. A pending
                        // save cannot consume an unfinished environment day;
                        // waking on the request alone spins and starves the
                        // main-thread input capture needed to finish that day.
                        const bool save_can_run =
                            _save_requested.load(std::memory_order_acquire) &&
                            !has_pending_climate_input() &&
                            !(active_environment && active_environment->day == day);
                        return _stop_requested.load(std::memory_order_acquire) ||
                            save_can_run ||
                            (!climate_driven && _paused.load(std::memory_order_acquire)) ||
                            stale_input_consumed ||
                            _climate_trace_signal.load(std::memory_order_acquire) !=
                                trace_signal ||
                            _environment_generation.load(
                                std::memory_order_acquire) != environment_signal ||
                            _country_peer_signal.load(std::memory_order_acquire) !=
                                country_peer_signal ||
                            _economy_input_signal.load(std::memory_order_acquire) !=
                                attempt_economy_signal ||
                            (!climate_driven &&
                             _climate_trace.consumable_depth() != 0);
                    });
                    _worker_timing.set(RuntimeWorkerTiming::OVERHEAD);
                    if (fault_if_peer_stall_timed_out(
                            day, "day_wait_peer_stall_timeout")) {
                        break;
                    }
                    break;
                    } // missing != 0
                }
                if (day_commit.completed_stage_count == day_plan.stage_count &&
                    day_plan.stage_count == RUNTIME_DOMAIN_STAGE_COUNT &&
                    day_commit.completed_domain_mask == RUNTIME_ALL_DOMAIN_MASK &&
                    implemented_domain_mask() == RUNTIME_ALL_DOMAIN_MASK) {
                    _graph_coverage_complete.store(true, std::memory_order_release);
                    _authority_control.mark_graph_ready();
                }
                // Per-domain grant. A domain is promoted once this day's commit
                // covers it, independently of whether the whole graph is
                // complete. Granting only the requested subset keeps a domain
                // the caller did not ask for on the main thread even when its
                // handler happens to exist.
                if (_mode.load(std::memory_order_acquire) ==
                        RuntimeSimulationMode::ACTIVE) {
                    const uint32_t wanted =
                        _requested_authority_mask.load(std::memory_order_acquire);
                    if (wanted != 0u &&
                        (day_commit.completed_domain_mask & wanted) == wanted) {
                        publish_authority_grant(wanted);
                    }
                    // Publish the committed Climate state for main-thread
                    // write-back. Ordered before the authority grant becomes
                    // observable to a reader that has not seen a day yet: the
                    // schedule gate suppresses production the moment the grant
                    // lands, so the first suppressed tick must already have a
                    // snapshot to consume.
                    if ((wanted & runtime_domain_mask(RuntimeDomainId::CLIMATE))
                            != 0u) {
                        // Only a day Climate actually advanced may be
                        // published. The worker clock is free to run ahead of
                        // the main thread, and on those idle days the store is
                        // unchanged; handing the main thread a fresh cursor for
                        // it would make it re-apply the same state every day and
                        // report a healthy write-back cadence while Climate was
                        // in fact standing still. That is exactly how a stalled
                        // Climate stayed invisible behind writeback_days.
                        const int64_t climate_day =
                            _climate_authority.store().committed_day;
                        uint32_t slot = 0;
                        if (climate_day > _climate_writeback_last_day.load(
                                std::memory_order_relaxed) &&
                            _climate_writeback.try_begin_write(slot)) {
                            RuntimeClimateSnapshot &out =
                                _climate_writeback.write_buffer(slot);
                            _climate_authority.snapshot_into(out, true);
                            // Own monotonic sequence, not the commit
                            // generation: the commit generation is bumped later
                            // inside publish_day, so reading it here would
                            // hand out a stale cursor and the main thread would
                            // re-apply the same day.
                            out.generation = _climate_writeback_sequence.fetch_add(
                                1, std::memory_order_relaxed) + 1u;
                            // Climate's day, not the worker clock's: this is the
                            // day whose state the buffer carries.
                            out.committed_day = climate_day;
                            out.dirty_families = day_commit.dirty_families;
                            _climate_writeback.publish(slot);
                            _climate_writeback_last_day.store(
                                climate_day, std::memory_order_relaxed);
                        }
                    }
                }
                _day_waterfall.mark(RuntimeDayWaterfall::WORKER_CLIMATE_WRITEBACK);
                _last_day_stage_count.store(day_plan.stage_count,
                                            std::memory_order_release);
                _last_day_completed_stages.store(day_commit.completed_stage_count,
                                                 std::memory_order_release);
                _last_day_work_units.store(day_commit.work_units,
                                           std::memory_order_release);
                _committed_day.store(day, std::memory_order_release);
                _completed_days.fetch_add(1, std::memory_order_relaxed);
                publish_day(from_day, day, day_commit, day_receipts);
                // Still inside the boundary: the post-command committed state
                // is stable, so this is where main-thread read demand is served.
                if (_economy_production_runtime != nullptr &&
                    economy_worker_owns_execution())
                    _economy_production_runtime->serve_read_view();
                _day_waterfall.mark(RuntimeDayWaterfall::WORKER_PUBLISH_DAY);
                _day_waterfall.finish(true, day_commit.completed_domain_mask);
                _worker_timing.set(RuntimeWorkerTiming::OVERHEAD);
                // Control messages are intentionally checked at the day
                // barrier as well as the outer loop.  A long catch-up batch
                // must yield promptly to SAVE/PAUSE/STOP instead of spending
                // the whole debt budget before servicing the request.
                if (_save_requested.load(std::memory_order_acquire) ||
                    _paused.load(std::memory_order_acquire) ||
                    _stop_requested.load(std::memory_order_acquire)) {
                    break;
                }
            }
        }
        _authority_control.revoke();
    } catch (const std::exception &error) {
        // `unhandled_worker_exception` alone is a dead end: it names the symptom and
        // throws away the only cheap evidence. Log what() before publishing the same
        // fault code, so a worker that dies after a restart says why.
        const std::string line = pk::log_format(
            "[runtime-worker-exception] what=%s day=%d",
            error.what() != nullptr ? error.what() : "unknown",
            _committed_day.load(std::memory_order_relaxed));
        pk::log_line(line);
        pk::log_line(line, true);
        set_fault("unhandled_worker_exception");
    } catch (...) {
        set_fault("unhandled_worker_exception");
    }
    _worker_timing.stop();
    // STOPPED is the restart handoff: even timing cleanup must precede it,
    // otherwise the retiring worker can stop the next worker's timing state.
    if (_state.load(std::memory_order_acquire) != RuntimeWorkerState::FAULTED) {
        _state.store(RuntimeWorkerState::STOPPED, std::memory_order_release);
    }
}

} // namespace pk
