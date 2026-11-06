#include "native_simulation_day_context.h"
#include "pk_log.h"
#include <algorithm>
#include <chrono>
#include <cstring>

namespace pk {
bool NativeSimulationHost::stage_effect(DayExecution &day, RuntimeDomainPlan &stage) {
    auto &plan = day.plan;
    auto &commit = day.commit;
    auto &climate_authority_requested = day.climate_authority_requested;
    auto &active_climate_ok = day.active_climate_ok;
    auto &gameplay_event_commands = day.gameplay_event_commands;
    if (stage.domain == RuntimeDomainId::EFFECT &&
        _mode.load(std::memory_order_acquire) ==
            RuntimeSimulationMode::ACTIVE &&
        (_requested_authority_mask.load(std::memory_order_acquire) &
         runtime_domain_mask(RuntimeDomainId::EFFECT)) != 0u) {
        // F8 ACTIVE independent Effect stage (Ideology order already passed
        // in the stage list). Park with Climate like Country/Modifier.
        if (climate_authority_requested && !active_climate_ok) {
            // Still absorb ENSURE registrations so technology instances are
            // present when Climate unblocks the Effect plan lane.
            std::string drain_error;
            drain_effect_transport_queues(drain_error);
            note_day_park(runtime_domain_mask(RuntimeDomainId::EFFECT),
                          "effect_parked_climate_input");
            stage.completed = 0;
            return true;
        }
        const bool effect_stage_enabled =
            _effect_pod_configured &&
            !_effect_pod_catalog.definitions.empty();
        if (!effect_stage_enabled) {
            _effect_day_modifier_intents.clear();
            _effect_day_stage_ok = false;
            note_day_park(runtime_domain_mask(RuntimeDomainId::EFFECT),
                          _effect_pod_configured
                              ? "effect_catalog_empty"
                              : "effect_stage_not_configured");
            stage.completed = 0;
            return true;
        }
        // Same M5 retry shape as Country: Effect commits its POD day
        // before later domains (Economy/Ideology continuation) can still
        // fail the atomic gate. Re-planning that day then dies on
        // effect_pod_day_not_sequential and pins 0xFFF forever.
        const int64_t effect_committed =
            _effect_pod_authority.snapshot().committed_day;
        if (plan.context.day <= effect_committed) {
            _effect_day_modifier_intents.clear();
            _effect_day_intents.clear();
            // Soft-skip must still drain ENSURE queues and re-emit
            // COMMITTED→ACK handoffs. Otherwise technology instances stay
            // present=0 / queued>0 across advancing pod days.
            size_t queued_before = 0;
            {
                std::lock_guard<std::mutex> lock(_effect_transport_mutex);
                queued_before = _effect_instance_queue.size();
            }
            std::string drain_error;
            drain_effect_transport_queues(drain_error);
            const uint32_t nudged =
                _effect_pod_authority.reschedule_unfired_due_instances(
                    effect_committed);
            reemit_effect_committed_pending_intents(plan.context.day);
            std::string catchup_error;
            const uint32_t catchup_fired =
                _effect_pod_authority.catchup_fire_never_fired_instances(
                    effect_committed + 1, _effect_day_intents,
                    catchup_error);
            if (!drain_error.empty() || !catchup_error.empty()) {
                note_day_park(runtime_domain_mask(RuntimeDomainId::EFFECT),
                    !drain_error.empty() ? drain_error.c_str() : catchup_error.c_str());
                stage.completed = 0; _effect_day_stage_ok = false;
                return true;
            }
            _effect_day_modifier_intents.clear();
            for (const RuntimeDomainIntent &intent : _effect_day_intents) {
                if (intent.target_domain ==
                    static_cast<uint16_t>(RuntimeDomainId::MODIFIER)) {
                    _effect_day_modifier_intents.push_back(intent);
                }
            }
            {
                const auto &snap = _effect_pod_authority.snapshot();
                static int s_drain_left = 12;
                int unfired_due = 0;
                for (const auto &inst : snap.instances) {
                    if (inst.active != 0 && inst.fire_sequence == 0 &&
                        inst.next_due_day >= 0 &&
                        inst.next_due_day <= effect_committed + 1)
                        ++unfired_due;
                }
                if ((queued_before > 0 || unfired_due > 0 || nudged > 0 ||
                     catchup_fired > 0) &&
                    s_drain_left-- > 0) {
                    pk::log_info(
                        "[tech-ack-diag/soft-skip] day=%d committed=%d "
                        "queued_before=%d instances=%d unfired_due=%d "
                        "nudged=%d catchup=%d drain_err=%s catchup_err=%s",
                        plan.context.day, effect_committed,
                        static_cast<int64_t>(queued_before),
                        static_cast<int64_t>(snap.instances.size()),
                        unfired_due, static_cast<int64_t>(nudged),
                        static_cast<int64_t>(catchup_fired),
                        std::string(drain_error.c_str()).c_str(),
                        std::string(catchup_error.c_str()).c_str());
                }
            }
            ack_effect_events_intents_in_worker(_effect_day_intents);
            const uint32_t promoted = resolve_pending_country_effect_peers();
            if (catchup_fired > 0 && promoted == 0u) {
                static int s_no_promote_left = 8;
                if (s_no_promote_left-- > 0) {
                    pk::log_info(
                        "[tech-ack-diag/soft-skip-no-promote] day=%d "
                        "catchup=%d promoted=0 (Modifier ACK may still be "
                        "pending; Country stage runs before Effect)",
                        plan.context.day,
                        static_cast<int64_t>(catchup_fired));
                }
            }
            _effect_day_stage_ok = true;
            stage.completed = 1;
            commit.completed_domain_mask |=
                runtime_domain_mask(RuntimeDomainId::EFFECT);
            ++commit.completed_stage_count;
            _effect_pod_ready.store(true, std::memory_order_release);
            for (size_t i = 0; i < _effect_pod_fallback_reason.size(); ++i)
                _effect_pod_fallback_reason[i].store(
                    '\0', std::memory_order_release);
            return true;
        }
        std::string effect_error;
        const bool effect_ok = execute_effect_worker_stage(
            plan.context.day, plan.context.input_generation,
            commit, effect_error);
        _effect_pod_ready.store(effect_ok, std::memory_order_release);
        const char *effect_reason = effect_ok ? "" :
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
        if (effect_ok) {
            // Production ACTIVE Effect→Events: typed intents become
            // APPEND_BATCH commands for the subsequent EVENTS stage.
            // Events failure clears EVENTS completion and blocks COMMIT.
            resolve_pending_country_effect_peers();
            for (const RuntimeDomainIntent &intent : _effect_day_intents) {
                gameplay_event_commands.push_back(
                    make_effect_intent_events_packet(
                        intent, plan.context.day));
            }
            stage.completed = 1;
            commit.completed_domain_mask |=
                runtime_domain_mask(RuntimeDomainId::EFFECT);
            ++commit.completed_stage_count;
            if (!_effect_day_intents.empty()) {
                _active_evidence_mask.fetch_or(
                    runtime_domain_mask(RuntimeDomainId::EFFECT),
                    std::memory_order_release);
            }
            // Ideology transitions no longer receive a synthetic OK here:
            // under IDEOLOGY|MODIFIER the Modifier stage applies their rows
            // as atomic batches and derives the ACK from that result.
            // H8: same bridge for Trigger. Its effect intents are delivered
            // by this stage under a joint TRIGGER|EFFECT grant, so ACK them
            // here and let the next Trigger visit clear its barrier.
            if ((_requested_authority_mask.load(std::memory_order_acquire) &
                 runtime_domain_mask(RuntimeDomainId::TRIGGER_INPUT)) != 0u) {
                ack_trigger_intents_in_worker(plan.context.day);
            }
        } else {
            stage.completed = 0;
        }
        return true;
    }
    return true;
}
} // namespace pk
