#include "native_simulation_day_context.h"
#include <algorithm>
#include <chrono>
#include <cstring>

namespace pk {
bool NativeSimulationHost::stage_input_capture(DayExecution &day, RuntimeDomainPlan &stage) {
    auto &plan = day.plan;
    auto &environment = day.environment;
    auto &commit = day.commit;
    auto &climate_authority_requested = day.climate_authority_requested;
    if (stage.domain == RuntimeDomainId::INPUT_CAPTURE &&
        _mode.load(std::memory_order_acquire) ==
            RuntimeSimulationMode::ACTIVE &&
        (_requested_authority_mask.load(std::memory_order_acquire) &
         runtime_domain_mask(RuntimeDomainId::INPUT_CAPTURE)) != 0u) {
        // M4/M5: INPUT_CAPTURE owns the immutable manifest for the whole
        // sealed day.  A missing, stale, or malformed frame parks the
        // day before any downstream domain can publish a partial result.
        // When Climate already committed this worker day (idempotent M5
        // retry / force-advance catch-up), allow the stage to complete
        // without a matching FIFO frame — Climate will not re-read it.
        const int64_t climate_committed_for_input =
            _climate_authority.store().committed_day;
        std::string input_error;
        const bool input_ok = environment != nullptr &&
            environment->generation == plan.context.input_generation &&
            environment->day == plan.context.day &&
            validate_runtime_environment_snapshot(*environment, input_error);
        if (!input_ok) {
            if (climate_authority_requested &&
                climate_committed_for_input >= plan.context.day) {
                stage.work_units = 0;
                stage.completed = 1;
                commit.completed_domain_mask |=
                    runtime_domain_mask(RuntimeDomainId::INPUT_CAPTURE);
                ++commit.completed_stage_count;
                return true;
            }
            stage.completed = 0;
            commit.preflight_ok = 0;
            commit.continuation_pending = 1;
            return true;
        }
        if (!capture_day_input(day, *environment)) {
            stage.completed = 0;
            commit.preflight_ok = 0;
            return false;
        }
        stage.work_units = 1;
        stage.completed = 1;
        commit.work_units += stage.work_units;
        commit.completed_domain_mask |=
            runtime_domain_mask(RuntimeDomainId::INPUT_CAPTURE);
        ++commit.completed_stage_count;
        _active_evidence_mask.fetch_or(
            runtime_domain_mask(RuntimeDomainId::INPUT_CAPTURE),
            std::memory_order_release);
        return true;
    }
    return true;
}
} // namespace pk
