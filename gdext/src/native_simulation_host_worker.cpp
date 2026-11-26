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
#include <utility>

#if defined(_WIN32)
#include <windows.h>
#endif

#include "native_simulation_host_support.h"
#include "runtime_control_wakeup.h"

namespace pk {

namespace {
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
    std::lock_guard<std::mutex> admission(_command_producer_mutex);
    request_stop_locked();
}

void NativeSimulationHost::request_stop_locked() {
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
    runtime_control_wakeup(_control_mutex, _control_cv, [this] {
        _stop_requested.store(true, std::memory_order_release);
    });
}

void NativeSimulationHost::join_for_destruction() {
    if (_worker.joinable()) _worker.join();
    _retired_workers.wait();
    _authority_control.revoke();
    _state.store(RuntimeWorkerState::STOPPED, std::memory_order_release);
}

void NativeSimulationHost::set_clock(bool paused, double speed_days_per_second) {
    const bool calendar_suspended = paused || !std::isfinite(speed_days_per_second) ||
        speed_days_per_second <= 0.0;
    runtime_control_wakeup(_control_mutex, _control_cv, [&] {
        _worker_timing.pause(paused);
        _paused.store(paused, std::memory_order_release);
        _calendar_suspended.store(calendar_suspended, std::memory_order_release);
        if (speed_days_per_second <= 1.0 && _world_environment) {
            const int64_t permitted = std::min(
                _clock_requested_day.load(std::memory_order_relaxed), committed_day_value() + 1);
            _clock_requested_day.store(permitted, std::memory_order_release);
        }
        _speed_days_per_second.store(std::max(0.0, speed_days_per_second),
                                     std::memory_order_release);
    });
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

int64_t NativeSimulationHost::command_seal_day() const noexcept {
    const int64_t next = committed_day_value() + 1;
    if (_world_environment) {
        return std::max(next,
            frozen_command_day() + 1);
    }
    const bool climate_driven =
        _mode.load(std::memory_order_acquire) == RuntimeSimulationMode::ACTIVE &&
        (_requested_authority_mask.load(std::memory_order_acquire) &
         runtime_domain_mask(RuntimeDomainId::CLIMATE)) != 0u;
    return climate_driven ? std::max(next, next_environment_day()) : next;
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

void NativeSimulationHost::log_slow_peer(int64_t day) {
    const auto since = _day_stall_peer_since_us.load(std::memory_order_acquire);
    if (since == 0 || since == _last_peer_stall_warning) return;
    const auto ms = (now_us() - since) / 1000u;
    if (ms < 5000u) return;
    _last_peer_stall_warning = since;
    pk::log_info("[day-stall] day=%lld stall=0x%x peer_ms=%llu ring=%zu",
        static_cast<long long>(day), day_stall_reason_mask(),
        static_cast<unsigned long long>(ms), _environment_ring.size());
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
    // The executor owns this world backlog until it exits. Keep it on Host so
    // stop/start and switching executors preserve accepted, unconsumed work.
    auto &pending_commands = _executor_pending_commands;
    pending_commands.reserve(RUNTIME_COMMAND_QUEUE_CAPACITY);
    int64_t logged_pending_day = -1;
    uint32_t logged_pending_mask = 0;
    size_t pending_begin = 0;
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
    auto &active_environment = _executor_day_environment;
    try {
        while (!_stop_requested.load(std::memory_order_acquire) &&
               _state.load(std::memory_order_acquire) != RuntimeWorkerState::FAULTED) {
            if (_stop_requested.load(std::memory_order_acquire)) break;

            service_economy_read_view();
            if (service_military_commands() || service_economy_boundary_requests() ||
                service_era_reward_requests() || service_annual_presentations() ||
                service_narrative_requests() || service_player_confirmations()) continue;

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
            const auto daily_work_ready = [&] {
                if (_world_environment) {
                    return retained_day_pending || player_response_admits(committed_day_value() + 1) ||
                        (!_calendar_suspended.load(std::memory_order_acquire) &&
                         _clock_requested_day.load(std::memory_order_acquire) > committed_day_value());
                }
                return has_pending_climate_input() || retained_day_pending;
            };
            const bool climate_pending = daily_work_ready();
            const bool awaiting_player = player_confirmation_block() != nullptr;
            if (awaiting_player || (climate_driven && !climate_pending) ||
                (!climate_driven && (paused || speed <= 0.0 || !std::isfinite(speed)))) {
                if (_stop_requested.load(std::memory_order_acquire)) break;
                _state.store(RuntimeWorkerState::PAUSED, std::memory_order_release);
                last = std::chrono::steady_clock::now();
                std::unique_lock<std::mutex> lock(_control_mutex);
                _worker_timing.set(awaiting_player ? RuntimeWorkerTiming::PAUSED :
                    (climate_driven && !_world_environment ? RuntimeWorkerTiming::ENVIRONMENT_WAIT
                                                          : RuntimeWorkerTiming::CLOCK_WAIT));
                _control_cv.wait(lock, [&] {
                    const bool blocked = awaiting_player;
                    const bool ready = _stop_requested.load(std::memory_order_acquire) ||
                        _save_requested.load(std::memory_order_acquire) ||
                        player_requests_pending_locked() ||
                        (_economy_read_view_requested && !retained_day_pending) ||
                        (!blocked && (climate_driven ?
                            daily_work_ready() :
                            (!_paused.load(std::memory_order_acquire) &&
                             _speed_days_per_second.load(std::memory_order_acquire) > 0.0)));
                    if (!ready && climate_driven && !_world_environment && !blocked &&
                            !_paused.load(std::memory_order_acquire))
                        _worker_timing.observe_main_wait(committed_day_value() + 1,
                            RuntimeWorkerTiming::ENVIRONMENT_INPUT);
                    return ready;
                });
                _worker_timing.finish_main_wait();
                _worker_timing.set(RuntimeWorkerTiming::OVERHEAD);
                continue;
            }
            if (_stop_requested.load(std::memory_order_acquire)) break;
            _state.store(RuntimeWorkerState::RUNNING, std::memory_order_release);
            const auto drain_commands = [&] {
                const size_t previous = pending_commands.size();
                drain_command_inbox(pending_commands);
                pending_commands_dirty |= previous != pending_commands.size();
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
                        std::chrono::duration<double>(seconds_until_day)), [&] {
                    return _stop_requested.load(std::memory_order_acquire) ||
                        player_requests_pending_locked() || _save_requested.load(std::memory_order_acquire) ||
                        (_economy_read_view_requested && !retained_day_pending) ||
                        _paused.load(std::memory_order_acquire) ||
                        _speed_days_per_second.load(std::memory_order_acquire) != speed;
                });
                _worker_timing.set(RuntimeWorkerTiming::OVERHEAD);
                continue;
            }
            target_days = std::min<int64_t>(target_days, 8);
            debt -= static_cast<double>(target_days);
            _time_debt_days.store(std::min(100.0, debt), std::memory_order_release);
#include "native_simulation_host_worker_section_run_authoritative_days.inc"
        }
        _authority_control.revoke();
    } catch (const std::exception &error) {
        // `unhandled_worker_exception` alone is a dead end: it names the symptom and
        // throws away the only cheap evidence. Log what() before publishing the same
        // fault code, so a worker that dies after a restart says why.
        const std::string line = pk::log_format(
            "[runtime-worker-exception] what=%s day=%lld",
            error.what() != nullptr ? error.what() : "unknown",
            static_cast<long long>(_committed_day.load(std::memory_order_relaxed)));
        pk::log_line(line);
        pk::log_line(line, true);
        set_fault("unhandled_worker_exception");
    } catch (...) {
        set_fault("unhandled_worker_exception");
    }
    // Complete already accepted value-only work before a same-world restart.
    compact_pending_commands(true);
    publish_pending_count();
    std::deque<RuntimePlayerConfirmationRequest> abandoned_confirmations;
    {
        std::lock_guard<std::mutex> control(_control_mutex);
        _military_commands.clear();
        _economy_boundary_requests.clear();
        _colonization_read_results.clear();
        _colonization_quotes_ready = false;
        _era_reward_requests.clear();
        _narrative_requests.clear();
        _annual_presentations.clear();
        abandoned_confirmations.swap(_player_confirmation.requests);
        _player_confirmation.ideology_input_changed = false;
        _control_cv.notify_all();
    }
    for (const auto &request : abandoned_confirmations) {
        constexpr const char *code = "executor_stopped_before_player_confirmation_service";
        godot::Dictionary result;
        result["ok"] = false;
        result["code"] = code;
        result["reason"] = code;
        result["settled_day"] = committed_day_value();
        const char *command = request.kind == RuntimePlayerConfirmationRequest::Kind::DISMISS_IDEOLOGY
            ? "ideology.offer.dismiss" : "ui.hide_all_except_gm";
        publish_boundary_command_result(command, 0, std::move(result));
    }
    _worker_timing.stop();
    // STOPPED is the restart handoff: even timing cleanup must precede it,
    // otherwise the retiring worker can stop the next worker's timing state.
    if (_state.load(std::memory_order_acquire) != RuntimeWorkerState::FAULTED) {
        _state.store(RuntimeWorkerState::STOPPED, std::memory_order_release);
    }
}

} // namespace pk
