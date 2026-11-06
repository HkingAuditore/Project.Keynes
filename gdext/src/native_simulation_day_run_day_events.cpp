#include "native_simulation_day_context.h"
#include "economy_cost_probe.h"
#include "pk_log.h"

namespace pk {
bool NativeSimulationHost::run_day_events(DayExecution &day, int64_t event_day) {
    auto &day_commands = day.day_commands;
    auto &gameplay_event_commands = day.gameplay_event_commands;

    if (!_events_probe_enabled.load(std::memory_order_acquire) ||
        _events_last_processed_day >= event_day) {
        return true;
    }
    thread_local RuntimeEventsSnapshot events_snapshot;
    RuntimeEventsReport events_report;
    std::string events_error;
    // RuntimeEventsAuthority owns its receipt vector. Keep that vector
    // separate from the host's ordinary command receipts: plan_day()
    // intentionally clears its output before replaying Events commands.
    std::vector<RuntimeCommandReceipt> event_receipts;
    const auto events_plan_started = std::chrono::steady_clock::now();
    const std::vector<RuntimeCommandPacket> *event_inputs = &day_commands;
    std::vector<RuntimeCommandPacket> merged_event_inputs;
    if (!gameplay_event_commands.empty()) {
        merged_event_inputs.reserve(day_commands.size() +
                                    gameplay_event_commands.size());
        merged_event_inputs.insert(merged_event_inputs.end(),
                                   day_commands.begin(), day_commands.end());
        merged_event_inputs.insert(merged_event_inputs.end(),
                                   gameplay_event_commands.begin(),
                                   gameplay_event_commands.end());
        event_inputs = &merged_event_inputs;
    }
    bool events_ok = true;
    if (try_fault_injection("events.append.before")) {
        events_ok = false;
        events_error = "events_append_fault_injected_before";
    } else {
        events_ok = _events_authority.plan_day(
            event_day, *event_inputs, events_snapshot, event_receipts,
            events_report, events_error);
    }
    const double events_plan_ms = std::chrono::duration<double, std::milli>(
        std::chrono::steady_clock::now() - events_plan_started).count();
    double events_replay_ms = 0.0;
    if (events_ok) {
        if (try_fault_injection("events.append.after")) {
            events_ok = false;
            events_error = "events_append_fault_injected_after";
            _events_authority.discard_plan();
        }
    }
    if (events_ok) {
        if (try_fault_injection("events.commit.before")) {
            events_ok = false;
            events_error = "events_commit_fault_injected_before";
            _events_authority.discard_plan();
        } else {
            const auto events_replay_started = std::chrono::steady_clock::now();
            events_ok = _events_authority.commit_day(events_snapshot, events_error);
            events_replay_ms = std::chrono::duration<double, std::milli>(
                std::chrono::steady_clock::now() - events_replay_started).count();
            if (events_ok && try_fault_injection("events.commit.after")) {
                events_ok = false;
                events_error = "events_commit_fault_injected_after";
            }
        }
    } else {
        _events_authority.discard_plan();
    }
    // plan_day 只为包级拒绝填 fallback_reason；commit/注入失败只有 events_error。
    if (!events_ok && events_report.fallback_reason[0] == '\0') {
        const char *source = events_error.empty() ? "events_commit_failed"
                                                  : events_error.c_str();
        size_t n = 0;
        for (; n + 1u < sizeof(events_report.fallback_reason) && source[n] != '\0'; ++n)
            events_report.fallback_reason[n] = source[n];
        events_report.fallback_reason[n] = '\0';
    }
    if (events_ok && events_report.rejected_commands > 0u) {
        _events_pod_rejected_count.fetch_add(events_report.rejected_commands,
                                             std::memory_order_relaxed);
        static std::atomic<int> s_events_reject_logs_left{16};
        if (s_events_reject_logs_left.fetch_sub(1, std::memory_order_relaxed) > 0) {
            pk::log_info(
                "[runtime-events] day=%d rejected=%d reason=%s",
                event_day, static_cast<int64_t>(events_report.rejected_commands),
                std::string(events_report.fallback_reason).c_str());
        }
    }
    const bool events_authoritative =
        _mode.load(std::memory_order_acquire) ==
            RuntimeSimulationMode::ACTIVE &&
        (_requested_authority_mask.load(std::memory_order_acquire) &
         runtime_domain_mask(RuntimeDomainId::EVENTS)) != 0u;
    // Probe mode records a rejected attempt once. Authority mode must retry
    // the same sealed day and cannot advance its watermark on failure.
    if (events_ok || !events_authoritative)
        _events_last_processed_day = event_day;
    _events_failed_day.store(events_ok || !events_authoritative ? -1 : event_day,
                             std::memory_order_release);
    _events_pod_ready.store(events_ok, std::memory_order_release);
    _events_pod_plan_ms.store(events_plan_ms, std::memory_order_release);
    _events_pod_replay_ms.store(events_replay_ms, std::memory_order_release);
    _events_pod_state_hash.store(_events_authority.snapshot().state_hash,
                                 std::memory_order_release);
    _events_pod_snapshot_generation.store(
        _events_authority.snapshot().generation, std::memory_order_release);
    _events_pod_event_count.store(events_report.appended_events,
                                  std::memory_order_release);
    _events_pod_ack_count.store(events_report.acknowledged_consumers,
                                std::memory_order_release);
    _events_pod_drop_count.store(_events_authority.snapshot().dropped_event_count,
                                 std::memory_order_release);
    for (size_t i = 0; i < _events_pod_fallback_reason.size(); ++i) {
        _events_pod_fallback_reason[i].store(
            events_report.fallback_reason[i], std::memory_order_release);
        if (events_report.fallback_reason[i] == '\0') break;
    }
    if (!events_ok) return false;
    uint32_t events_slot = 0;
    if (_events_snapshots.try_begin_write(events_slot)) {
        _events_snapshots.write_buffer(events_slot) = _events_authority.snapshot();
        _events_snapshots.publish(events_slot);
    } else {
        _events_pod_ready.store(false, std::memory_order_release);
    }
    return true;
    }
} // namespace pk
