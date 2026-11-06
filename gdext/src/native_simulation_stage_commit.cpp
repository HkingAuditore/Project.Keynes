#include "native_simulation_day_context.h"
#include <algorithm>
#include <chrono>
#include <cstring>

namespace pk {
bool NativeSimulationHost::stage_commit(DayExecution &day, RuntimeDomainPlan &stage) {
    auto &commit = day.commit;
    if (stage.domain != RuntimeDomainId::COMMIT) return true;
    stage.dirty_families = RUNTIME_DIRTY_CLOCK;
    stage.work_units = 1;
    stage.completed = 1;
    commit.dirty_families |= stage.dirty_families;
    commit.work_units += stage.work_units;
    commit.completed_domain_mask |= runtime_domain_mask(stage.domain);
    ++commit.completed_stage_count;
    return true;
}
} // namespace pk
