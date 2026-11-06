#include "native_simulation_day_context.h"
#include <algorithm>
#include <chrono>
#include <cstring>

namespace pk {
bool NativeSimulationHost::stage_modifier(DayExecution &day, RuntimeDomainPlan &stage) {
    auto &plan = day.plan;
    auto &day_commands = day.day_commands;
    auto &commit = day.commit;
    auto &climate_authority_requested = day.climate_authority_requested;
    auto &active_climate_ok = day.active_climate_ok;
    if (stage.domain == RuntimeDomainId::MODIFIER &&
        _mode.load(std::memory_order_acquire) ==
            RuntimeSimulationMode::ACTIVE &&
        (_requested_authority_mask.load(std::memory_order_acquire) &
         runtime_domain_mask(RuntimeDomainId::MODIFIER)) != 0u) {
        // Park with Climate the same way Country does: when the worker
        // clock outruns the published environment, do not advance Modifier.
        if (climate_authority_requested && !active_climate_ok) {
            stage.completed = 0;
            return true;
        }
        // F8: when EFFECT is granted, the independent EFFECT stage already
        // ran. Otherwise keep the E8 embedded upstream for Mod-only grant.
        const bool effect_authority_requested =
            (_requested_authority_mask.load(std::memory_order_acquire) &
             runtime_domain_mask(RuntimeDomainId::EFFECT)) != 0u;
        bool effect_upstream_ok = false;
        if (effect_authority_requested) {
            effect_upstream_ok = _effect_day_stage_ok;
        } else {
            const bool effect_stage_enabled =
                _effect_pod_configured &&
                !_effect_pod_catalog.definitions.empty();
            if (effect_stage_enabled) {
                std::string effect_error;
                effect_upstream_ok = execute_effect_worker_stage(
                    plan.context.day, plan.context.input_generation,
                    commit, effect_error);
                _effect_pod_ready.store(effect_upstream_ok,
                                         std::memory_order_release);
                const char *effect_reason = effect_upstream_ok ? "" :
                    (effect_error.empty() ? "effect_pod_plan_failed"
                                          : effect_error.c_str());
                size_t effect_reason_index = 0;
                for (; effect_reason_index + 1 <
                           _effect_pod_fallback_reason.size() &&
                       effect_reason[effect_reason_index] != '\0';
                     ++effect_reason_index) {
                    _effect_pod_fallback_reason[effect_reason_index].store(
                        effect_reason[effect_reason_index],
                        std::memory_order_release);
                }
                for (; effect_reason_index <
                           _effect_pod_fallback_reason.size();
                     ++effect_reason_index) {
                    _effect_pod_fallback_reason[effect_reason_index].store(
                        '\0', std::memory_order_release);
                }
            } else {
                _effect_day_modifier_intents.clear();
                _effect_day_stage_ok = false;
            }
        }
        std::string modifier_error;
        std::string unused_authority_error;
        // ACTIVE: no diagnostic domain runner. Failure isolates Modifier —
        // Climate/Country already committed stay.
        if (execute_modifier_worker_stage(
                plan.context.day, plan.context.input_generation,
                day_commands, effect_upstream_ok, nullptr,
                unused_authority_error, modifier_error)) {
            stage.dirty_families = RUNTIME_DIRTY_COUNTRY_STATE;
            stage.work_units = _modifier_pod_work_units.load(
                std::memory_order_relaxed);
            stage.completed = 1;
            commit.dirty_families |= stage.dirty_families;
            commit.work_units += stage.work_units;
            commit.completed_domain_mask |=
                runtime_domain_mask(RuntimeDomainId::MODIFIER);
            // Modifier ACK of Effect catchup fires unlocks Country tech peers.
            resolve_pending_country_effect_peers();
            ++commit.completed_stage_count;
        } else {
            stage.completed = 0;
        }
        return true;
    }
    return true;
}
} // namespace pk
