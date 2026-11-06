#include "native_simulation_day_context.h"
#include <algorithm>
#include <chrono>
#include <cstring>

namespace pk {
bool NativeSimulationHost::stage_ideology(DayExecution &day, RuntimeDomainPlan &stage) {
    auto &plan = day.plan;
    auto &commit = day.commit;
    auto &climate_authority_requested = day.climate_authority_requested;
    auto &active_climate_ok = day.active_climate_ok;
    if (stage.domain == RuntimeDomainId::IDEOLOGY &&
        _mode.load(std::memory_order_acquire) ==
            RuntimeSimulationMode::ACTIVE &&
        (_requested_authority_mask.load(std::memory_order_acquire) &
         runtime_domain_mask(RuntimeDomainId::IDEOLOGY)) != 0u) {
        // G8 ACTIVE Ideology stage. It runs before Effect in the stage
        // order, so this day's transition intents are still available to
        // the in-worker ACK bridge below. Park with Climate like
        // Country/Effect/Modifier.
        if (climate_authority_requested && !active_climate_ok) {
            stage.completed = 0;
            return true;
        }
        std::string ideology_error;
        const bool ideology_ok = execute_ideology_worker_stage(
            plan.context.day, commit, ideology_error);
        _ideology_pod_ready.store(ideology_ok, std::memory_order_release);
        const char *ideology_reason = ideology_ok ? "" :
            (ideology_error.empty() ? "ideology_pod_plan_failed"
                                    : ideology_error.c_str());
        size_t ideology_reason_index = 0;
        for (; ideology_reason_index + 1 <
                   _ideology_pod_fallback_reason.size() &&
               ideology_reason[ideology_reason_index] != '\0';
             ++ideology_reason_index) {
            _ideology_pod_fallback_reason[ideology_reason_index].store(
                ideology_reason[ideology_reason_index],
                std::memory_order_release);
        }
        for (; ideology_reason_index <
                   _ideology_pod_fallback_reason.size();
             ++ideology_reason_index) {
            _ideology_pod_fallback_reason[ideology_reason_index].store(
                '\0', std::memory_order_release);
        }
        // Soft-complete input-not-ready failures so Climate|Country|
        // Effect|Modifier grant is not held hostage by Ideology's
        // Economy-opinion dependency (revision stays 0 until the first
        // Economy COMMIT after generate). ready stays false; fallback
        // reason keeps the diagnosis. Hard plan failures still isolate.
        const bool ideology_soft =
            !ideology_ok &&
            (ideology_error == "ideology_opinion_snapshot_missing" ||
             ideology_error == "ideology_country_snapshot_missing" ||
             ideology_error == "ideology_pod_not_configured" ||
             ideology_error == "ideology_day_not_monotonic");
        if (!ideology_ok)
            note_day_park(runtime_domain_mask(RuntimeDomainId::IDEOLOGY), ideology_reason);
        if (ideology_ok || ideology_soft) {
            if (ideology_ok) {
                stage.dirty_families = RUNTIME_DIRTY_COUNTRY_STATE;
                commit.dirty_families |= stage.dirty_families;
            }
            stage.completed = 1;
            commit.completed_domain_mask |=
                runtime_domain_mask(RuntimeDomainId::IDEOLOGY);
            ++commit.completed_stage_count;
        } else {
            stage.completed = 0;
        }
        return true;
    }
    return true;
}
} // namespace pk
