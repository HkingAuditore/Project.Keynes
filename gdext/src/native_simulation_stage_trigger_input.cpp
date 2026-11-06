#include "native_simulation_day_context.h"
#include <algorithm>
#include <chrono>
#include <cstring>

namespace pk {
bool NativeSimulationHost::stage_trigger_input(DayExecution &day, RuntimeDomainPlan &stage) {
    auto &plan = day.plan;
    auto &commit = day.commit;
    auto &climate_authority_requested = day.climate_authority_requested;
    auto &active_climate_ok = day.active_climate_ok;
    if (stage.domain == RuntimeDomainId::TRIGGER_INPUT &&
        _mode.load(std::memory_order_acquire) ==
            RuntimeSimulationMode::ACTIVE &&
        (_requested_authority_mask.load(std::memory_order_acquire) &
         runtime_domain_mask(RuntimeDomainId::TRIGGER_INPUT)) != 0u) {
        // H7 ACTIVE Trigger stage. It sits between Country and Ideology in
        // the stage order, so this day's effect intents are available to the
        // Effect stage's in-worker ACK drain below. Park with Climate like
        // Country/Ideology/Effect/Modifier.
        if (climate_authority_requested && !active_climate_ok) {
            stage.completed = 0;
            return true;
        }
        const uint32_t dirty_before = commit.dirty_families;
        const uint64_t work_before = commit.work_units;
        std::string trigger_error;
        const bool trigger_ok = execute_trigger_worker_stage(
            plan.context.day, plan.context.input_generation, commit,
            trigger_error);
        _trigger_pod_ready.store(trigger_ok, std::memory_order_release);
        const char *trigger_reason = trigger_ok ? "" :
            (trigger_error.empty() ? "trigger_pod_plan_failed"
                                   : trigger_error.c_str());
        size_t trigger_reason_index = 0;
        for (; trigger_reason_index + 1 <
                   _trigger_pod_fallback_reason.size() &&
               trigger_reason[trigger_reason_index] != '\0';
             ++trigger_reason_index) {
            _trigger_pod_fallback_reason[trigger_reason_index].store(
                trigger_reason[trigger_reason_index],
                std::memory_order_release);
        }
        for (; trigger_reason_index < _trigger_pod_fallback_reason.size();
             ++trigger_reason_index) {
            _trigger_pod_fallback_reason[trigger_reason_index].store(
                '\0', std::memory_order_release);
        }
        // Soft-complete input-not-ready failures so the shared grant is not
        // held hostage by Trigger. An incomplete ACK barrier is the normal
        // first-visit outcome for a firing day: the intents were published
        // above, the Effect stage ACKs them, and the next visit commits the
        // same replayed plan. ready stays false and the fallback reason
        // keeps the diagnosis. Hard kernel/command failures still isolate.
        const bool trigger_soft =
            !trigger_ok &&
            (trigger_error == "trigger_pod_not_configured" ||
             trigger_error == "trigger_pod_not_bootstrapped" ||
             trigger_error == "ack_barrier_incomplete" ||
             trigger_error == "ack_retry" ||
             trigger_error == "stale_generation" ||
             trigger_error == "ack_rejected");
        if (trigger_ok || trigger_soft) {
            if (trigger_ok) {
                stage.dirty_families =
                    (commit.dirty_families | dirty_before) &
                    RUNTIME_DIRTY_EVENTS;
                stage.work_units = commit.work_units >= work_before
                    ? commit.work_units - work_before : 0;
            }
            stage.completed = 1;
            commit.completed_domain_mask |=
                runtime_domain_mask(RuntimeDomainId::TRIGGER_INPUT);
            ++commit.completed_stage_count;
        } else {
            stage.completed = 0;
        }
        return true;
    }
    return true;
}
} // namespace pk
