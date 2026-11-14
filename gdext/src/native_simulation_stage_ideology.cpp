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
        using Outcome = IdeologyStageOutcome;
        std::string ideology_error;
        const Outcome outcome = execute_ideology_worker_stage(
            plan.context.day, commit, ideology_error);
        const bool ideology_ok = outcome == Outcome::COMMITTED ||
                                 outcome == Outcome::ALREADY_COMMITTED;
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
        switch (outcome) {
        case Outcome::COMMITTED:
            stage.dirty_families = RUNTIME_DIRTY_COUNTRY_STATE;
            commit.dirty_families |= stage.dirty_families;
            break;
        case Outcome::ALREADY_COMMITTED:
            break;
        case Outcome::AWAITING_OPINION:
            // Ideology runs before Economy, so no opinion exists until
            // Economy's first commit. Skip the day (counted) rather than hold
            // the other domains' grant; ready stays false with the reason.
            _ideology_opinion_wait_days.fetch_add(1, std::memory_order_relaxed);
            break;
        case Outcome::PARKED:
            note_day_park(runtime_domain_mask(RuntimeDomainId::IDEOLOGY), ideology_reason);
            stage.completed = 0;
            return true;
        case Outcome::FAULT:
            set_fault(ideology_reason);
            stage.completed = 0;
            commit.preflight_ok = 0;
            return true;
        }
        stage.completed = 1;
        commit.completed_domain_mask |=
            runtime_domain_mask(RuntimeDomainId::IDEOLOGY);
        ++commit.completed_stage_count;
        return true;
    }
    return true;
}
} // namespace pk
