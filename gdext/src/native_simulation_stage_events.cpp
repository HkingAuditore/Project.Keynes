#include "native_simulation_day_context.h"
#include <algorithm>
#include <chrono>
#include <cstring>

namespace pk {
bool NativeSimulationHost::stage_events(DayExecution &day, RuntimeDomainPlan &stage) {
    auto &plan = day.plan;
    auto &commit = day.commit;
    auto &climate_authority_requested = day.climate_authority_requested;
    auto &active_climate_ok = day.active_climate_ok;
    if (stage.domain == RuntimeDomainId::EVENTS &&
        _mode.load(std::memory_order_acquire) ==
            RuntimeSimulationMode::ACTIVE &&
        (_requested_authority_mask.load(std::memory_order_acquire) &
         runtime_domain_mask(RuntimeDomainId::EVENTS)) != 0u) {
        // ACTIVE Events is the production journal and consumer-cursor
        // owner. A rejected packet is receipted and consumed; only a
        // plan/commit failure holds COMMIT at the sealed day.
        if (climate_authority_requested && !active_climate_ok) {
            stage.completed = 0;
            return true;
        }
        const bool events_ok = run_day_events(day, plan.context.day);
        if (_events_pod_event_count.load(std::memory_order_relaxed) > 0u) {
            stage.dirty_families = RUNTIME_DIRTY_EVENTS;
            commit.dirty_families |= stage.dirty_families;
        }
        stage.work_units =
            _events_pod_event_count.load(std::memory_order_relaxed);
        commit.work_units += stage.work_units;
        if (!events_ok) {
            stage.completed = 0;
            commit.preflight_ok = 0;
            return true;
        }
        forward_committed_events_to_trigger(plan.context.day);
        stage.completed = 1;
        commit.completed_domain_mask |=
            runtime_domain_mask(RuntimeDomainId::EVENTS);
        ++commit.completed_stage_count;
        if (stage.work_units > 0u) {
            _active_evidence_mask.fetch_or(
                runtime_domain_mask(RuntimeDomainId::EVENTS),
                std::memory_order_release);
        }
        return true;
    }
    return true;
}
} // namespace pk
