#include "native_simulation_day_context.h"
#include <algorithm>
#include <chrono>
#include <cstring>

namespace pk {
bool NativeSimulationHost::stage_visual(DayExecution &day, RuntimeDomainPlan &stage) {
    auto &plan = day.plan;
    auto &commit = day.commit;
    if (stage.domain == RuntimeDomainId::VISUAL &&
        _mode.load(std::memory_order_acquire) ==
            RuntimeSimulationMode::ACTIVE &&
        (_requested_authority_mask.load(std::memory_order_acquire) &
         runtime_domain_mask(RuntimeDomainId::VISUAL)) != 0u) {
        stage.work_units = commit.dirty_families != 0 ? 1u : 0u;
        stage.dirty_families = 0;
        stage.completed = 1;
        commit.work_units += stage.work_units;
        commit.completed_domain_mask |=
            runtime_domain_mask(RuntimeDomainId::VISUAL);
        ++commit.completed_stage_count;
        if (stage.work_units != 0u) {
            _active_evidence_mask.fetch_or(
                runtime_domain_mask(RuntimeDomainId::VISUAL),
                std::memory_order_release);
        }
        return true;
    }
    return true;
}
} // namespace pk
