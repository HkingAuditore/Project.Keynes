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
        // VISUAL authority ends at deterministic intent production.  The
        // Godot renderer/GPU remains outside the worker; publish_day()
        // later sorts, deduplicates and commits this POD batch atomically.
        uint32_t intent_index = 0;
        const uint32_t dirty = commit.dirty_families;
        for (uint32_t bit = 0; bit < RUNTIME_DIRTY_FAMILY_COUNT; ++bit) {
            const uint32_t family_bit = 1u << bit;
            if ((dirty & family_bit) == 0u) continue;
            RuntimeVisualIntent intent{};
            intent.family = family_bit;
            intent.cell_index = 0;
            intent.field_id = bit;
            intent.value_i32 = static_cast<int32_t>(plan.context.day);
            intent.value_f32 = 0.0f;
            _pod_visual_intents.push_back(intent);
            ++intent_index;
        }
        stage.work_units = intent_index;
        stage.dirty_families = 0;
        stage.completed = 1;
        commit.work_units += stage.work_units;
        commit.completed_domain_mask |=
            runtime_domain_mask(RuntimeDomainId::VISUAL);
        ++commit.completed_stage_count;
        if (intent_index > 0u) {
            _active_evidence_mask.fetch_or(
                runtime_domain_mask(RuntimeDomainId::VISUAL),
                std::memory_order_release);
        }
        return true;
    }
    return true;
}
} // namespace pk
