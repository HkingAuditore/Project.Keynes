#include "runtime_domain_authorities.h"

#include "runtime_climate_kernel.h"
#include "runtime_country_pod.h"

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstring>
#include <limits>

namespace pk {

namespace {
#include "runtime_domain_authorities_stage_helpers.inc"
} // namespace

RuntimeDomainReport RuntimeDomainAuthorityRunner::run_trigger_input(
        const RuntimeDayContext &context, uint64_t &work_units) {
    RuntimeDomainReport out;
    out.domain = RuntimeDomainId::TRIGGER_INPUT;
    out.day = context.day;
    out.input_generation = context.input_generation;
    const auto started = std::chrono::steady_clock::now();
    if (_trigger_configured) {
        std::lock_guard<std::mutex> lock(_trigger_mutex);
        std::string trigger_error;
        if (!_trigger_authority.plan_day(context.day, context.input_generation,
                                         _trigger_plan, trigger_error)) {
            set_report_error(out, trigger_error.empty()
                ? "trigger_pod_transaction_failed" : trigger_error.c_str());
            out.timing.elapsed_ms = elapsed_ms(started);
            return out;
        }
        // plan.acks describes the ACK identities required by the plan; it is
        // not a receipt from Effect/another domain. In the SHADOW runner no
        // peer adapter is wired for Trigger yet, so pass only real receipts
        // (currently none). This keeps missing ACKs visible instead of
        // turning the requirement list into a synthetic success.
        static const std::vector<RuntimeDomainAck> no_trigger_acks;
        if (!_trigger_authority.commit_day(_trigger_plan, no_trigger_acks,
                                           trigger_error)) {
            _trigger_authority.discard_plan();
            set_report_error(out, trigger_error.empty()
                ? "trigger_pod_transaction_failed" : trigger_error.c_str());
            out.timing.elapsed_ms = elapsed_ms(started);
            return out;
        }
        work_units += _trigger_plan.intents.size() +
            _trigger_plan.next_state.states.size();
        out.completed = 1;
        out.preflight_ok = 1;
        out.dirty_families = RUNTIME_DIRTY_EVENTS;
        out.timing.work_units = _trigger_plan.intents.size() +
            _trigger_plan.next_state.states.size();
        out.timing.intent_count = static_cast<uint32_t>(_trigger_plan.intents.size());
        out.timing.ack_count = _trigger_plan.required_ack_count;
        out.timing.state_hash = _trigger_authority.state_hash();
        out.timing.elapsed_ms = elapsed_ms(started);
        return out;
    }
    uint64_t last_event = 0;
    for (RuntimeTriggerState &state : _next.trigger.states) {
        for (const RuntimeEventRecord &event : _next.events.journal) {
            if (event.committed == 0 || event.day > context.day ||
                event.event_id <= state.last_event_id) continue;
            const uint64_t dedupe = hash_mix(event.source_id, event.event_id);
            if (std::find(_next.trigger.distinct_keys.begin(),
                          _next.trigger.distinct_keys.end(), dedupe) !=
                    _next.trigger.distinct_keys.end()) {
                state.last_event_id = std::max(state.last_event_id, event.event_id);
                continue;
            }
            if (_next.trigger.distinct_keys.size() >=
                    _next.trigger.distinct_keys.capacity()) {
                set_report_error(out, "trigger_distinct_capacity_exceeded");
                out.timing.elapsed_ms = elapsed_ms(started);
                return out;
            }
            _next.trigger.distinct_keys.push_back(dedupe);
            state.accumulator += event.value;
            state.last_event_id = event.event_id;
            state.fire_sequence += 1u;
            last_event = std::max(last_event, event.event_id);
        }
    }
    _next.trigger.committed_day = context.day;
    _next.trigger.generation = _current.trigger.generation + 1u;
    work_units += _next.trigger.states.size() + _next.trigger.distinct_keys.size();
    out.completed = 1;
    out.preflight_ok = 1;
    out.dirty_families = RUNTIME_DIRTY_EVENTS;
    out.timing.work_units = static_cast<uint64_t>(
        _next.trigger.states.size() + _next.trigger.distinct_keys.size());
    out.timing.state_hash = _next.trigger.state_hash();
    (void)last_event;
    out.timing.elapsed_ms = elapsed_ms(started);
    return out;
}

RuntimeDomainReport RuntimeDomainAuthorityRunner::run_ideology(
        const RuntimeDayContext &context, uint64_t &work_units) {
    RuntimeDomainReport out;
    out.domain = RuntimeDomainId::IDEOLOGY;
    out.day = context.day;
    out.input_generation = context.input_generation;
    const auto started = std::chrono::steady_clock::now();
    std::stable_sort(_next.ideology.countries.begin(),
                     _next.ideology.countries.end(),
        [](const RuntimeIdeologyCountry &a, const RuntimeIdeologyCountry &b) {
            return a.country_handle < b.country_handle;
        });
    for (RuntimeIdeologyCountry &country : _next.ideology.countries) {
        if (country.pending_transition >= 0) {
            country.dominant_id = country.pending_transition;
            country.pending_transition = -1;
            ++country.revision;
        }
        // Deterministic xorshift stream; it is part of the snapshot/hash and
        // never seeded from wall-clock time.
        country.rng_state ^= country.rng_state << 7u;
        country.rng_state ^= country.rng_state >> 9u;
        country.rng_state ^= country.rng_state << 8u;
    }
    _next.ideology.committed_day = context.day;
    _next.ideology.generation = _current.ideology.generation + 1u;
    work_units += _next.ideology.countries.size();
    out.completed = 1;
    out.preflight_ok = 1;
    out.dirty_families = RUNTIME_DIRTY_COUNTRY_STATE;
    out.timing.work_units = _next.ideology.countries.size();
    out.timing.state_hash = _next.ideology.state_hash();
    out.timing.elapsed_ms = elapsed_ms(started);
    return out;
}

RuntimeDomainReport RuntimeDomainAuthorityRunner::run_effect(
        const RuntimeDayContext &context, uint64_t &work_units) {
    RuntimeDomainReport out;
    out.domain = RuntimeDomainId::EFFECT;
    out.day = context.day;
    out.input_generation = context.input_generation;
    const auto started = std::chrono::steady_clock::now();
    for (RuntimeEffectInstance &instance : _next.effect.instances) {
        if (instance.active == 0 || instance.next_due_day < 0 ||
            instance.next_due_day > context.day) continue;
        if (instance.expiry_day >= 0 && context.day > instance.expiry_day) {
            instance.active = 0;
            continue;
        }
        if (_intents.size() >= RUNTIME_DOMAIN_INTENT_CAPACITY) {
            set_report_error(out, "effect_intent_capacity_exceeded");
            out.timing.elapsed_ms = elapsed_ms(started);
            return out;
        }
        RuntimeDomainIntent intent;
        intent.source_domain = static_cast<uint16_t>(RuntimeDomainId::EFFECT);
        intent.target_domain = static_cast<uint16_t>(RuntimeDomainId::MODIFIER);
        intent.opcode = 1;
        intent.source_id = instance.instance_id;
        intent.target_handle = instance.target_handle;
        intent.target_generation = instance.target_generation;
        intent.effective_day = context.day;
        intent.value = 1;
        intent.request_id = hash_mix(instance.instance_id,
                                     instance.fire_sequence + 1u);
        intent.producer_id = static_cast<uint32_t>(RuntimeDomainId::EFFECT);
        intent.sequence = instance.fire_sequence + 1u;
        // The compact runner's fixture effect is an APPLY intent. Real effect
        // adapters may replace these numeric lanes with their compiled IR.
        intent.payload[0] = 0; // definition_id
        intent.payload[1] = 0; // Modifier domain
        intent.payload[2] = 2; // entity scope
        intent.payload[3] = 1; // stacks
        intent.duration_days = -2;
        intent.stacks = 1;
        intent.magnitude_q16 = 65536;
        _intents.push_back(intent);
        ++instance.fire_sequence;
        instance.next_due_day = context.day + 1;
    }
    _next.effect.committed_day = context.day;
    _next.effect.generation = _current.effect.generation + 1u;
    work_units += _next.effect.instances.size();
    out.completed = 1;
    out.preflight_ok = 1;
    out.dirty_families = RUNTIME_DIRTY_EVENTS;
    out.timing.work_units = _next.effect.instances.size();
    out.timing.state_hash = _next.effect.state_hash();
    out.timing.intent_count = static_cast<uint32_t>(_intents.size());
    out.timing.elapsed_ms = elapsed_ms(started);
    return out;
}

RuntimeDomainReport RuntimeDomainAuthorityRunner::run_modifier(
        const RuntimeDayContext &context, uint64_t &work_units) {
    RuntimeDomainReport out;
    out.domain = RuntimeDomainId::MODIFIER;
    out.day = context.day;
    out.input_generation = context.input_generation;
    const auto started = std::chrono::steady_clock::now();
    uint64_t modifier_intents = 0;
    for (const RuntimeDomainIntent &intent : _intents) {
        if (intent.target_domain != static_cast<uint16_t>(RuntimeDomainId::MODIFIER))
            continue;
        ++modifier_intents;
    }
    // The dedicated RuntimeModifierPodAuthority owns all Modifier mutation.
    // This shared runner only records the stage and waits for its real ACKs.
    work_units += modifier_intents;
    out.completed = 1;
    out.preflight_ok = 1;
    out.dirty_families = modifier_intents != 0 ? RUNTIME_DIRTY_COUNTRY_STATE : 0;
    out.timing.work_units = modifier_intents;
    out.timing.intent_count = static_cast<uint32_t>(modifier_intents);
    out.timing.state_hash = _current.modifier.state_hash();
    out.timing.ack_count = 0;
    out.timing.elapsed_ms = elapsed_ms(started);
    return out;
}

RuntimeDomainReport RuntimeDomainAuthorityRunner::run_gameplay_effect(
        const RuntimeDayContext &context, uint64_t &work_units) {
    RuntimeDomainReport out;
    out.domain = RuntimeDomainId::GAMEPLAY_EFFECT;
    out.day = context.day;
    out.input_generation = context.input_generation;
    out.completed = 1;
    out.preflight_ok = 1;
    out.timing.work_units = ++work_units;
    out.timing.state_hash = hash_mix(FNV_OFFSET,
                                     static_cast<uint64_t>(context.day));
    return out;
}

RuntimeDomainReport RuntimeDomainAuthorityRunner::run_economy(
        const RuntimeDayContext &context,
        const RuntimeEnvironmentSnapshot *environment,
        uint64_t &work_units, uint32_t &changed_cells) {
    RuntimeDomainReport out;
    out.domain = RuntimeDomainId::ECONOMY;
    out.day = context.day;
    out.input_generation = context.input_generation;
    const auto started = std::chrono::steady_clock::now();
    _economy_replay_report = RuntimeEconomyReplayReport{};
    std::string validation_error;
    if (!_next.economy.validate(validation_error)) {
        set_report_error(out, validation_error.empty()
            ? "economy_store_shape_invalid" : validation_error.c_str());
        out.timing.elapsed_ms = elapsed_ms(started);
        return out;
    }
    const uint32_t cells = _next.economy.cell_count;
    if (environment == nullptr || environment->cell_count != cells) {
        set_report_error(out, "economy_j2b_environment_shape_invalid");
        copy_text(_economy_replay_report.fallback_reason,
                    "economy_input_missing");
        out.timing.elapsed_ms = elapsed_ms(started);
        return out;
    }

    RuntimeEconomyEpochInput input;
    input.sample_day = context.day;
    input.session_epoch = 1;
    input.economy_generation = _next.economy.generation;
    input.input_generation = context.input_generation;
    input.country_generation = _next.country.generation;
    input.catalog_hash = environment->generation;
    input.policy_hash = _next.country.state_hash();
    input.environment_shape_hash = environment->generation ^ cells;
    input.cell_count = cells;
    input.market_cycle_days = 5;
    input.production_cycle_days = 10;
    input.investment_cycle_days = 20;
    input.valid = true;

    _economy_pod_authority.reset();
    if (_economy_reference_day == context.day &&
        _economy_reference_generation != 0) {
        _economy_pod_authority.set_stage_reference(
            RuntimeEconomyGraphStage::BUILDING_PLAN, _economy_reference_day,
            _economy_reference_generation, _economy_reference_hash, cells);
    }
    std::string authority_error;
    if (!_economy_pod_authority.plan_epoch(input, authority_error)) {
        set_report_error(out, authority_error.empty()
            ? "economy_pod_plan_failed" : authority_error.c_str());
        copy_text(_economy_replay_report.fallback_reason,
                    authority_error.empty()
                        ? "economy_pod_plan_failed" : authority_error.c_str());
        out.timing.elapsed_ms = elapsed_ms(started);
        return out;
    }
    for (size_t stage = 0; stage < RUNTIME_ECONOMY_GRAPH_STAGE_COUNT; ++stage) {
        if (!_economy_pod_authority.advance_stage(authority_error)) {
            set_report_error(out, authority_error.empty()
                ? "economy_pod_advance_failed" : authority_error.c_str());
            copy_text(_economy_replay_report.fallback_reason,
                        authority_error.empty()
                            ? "economy_pod_advance_failed"
                            : authority_error.c_str());
            out.timing.elapsed_ms = elapsed_ms(started);
            return out;
        }
    }
    if (!_economy_pod_authority.commit_epoch(authority_error)) {
        set_report_error(out, authority_error.empty()
            ? "economy_pod_commit_failed" : authority_error.c_str());
        copy_text(_economy_replay_report.fallback_reason,
                    authority_error.empty()
                        ? "economy_pod_commit_failed" : authority_error.c_str());
        out.timing.elapsed_ms = elapsed_ms(started);
        return out;
    }

    const RuntimeEconomyPodReplayReport &pod =
        _economy_pod_authority.replay_report();
    _economy_replay_report.completed_stage_mask = pod.completed_stage_mask;
    _economy_replay_report.stage_cursor = pod.stage_cursor;
    _economy_replay_report.input_hash = pod.input_hash;
    _economy_replay_report.base_hash = pod.base_hash;
    _economy_replay_report.next_hash = pod.next_hash;
    _economy_replay_report.reference_hash = pod.reference_hash;
    _economy_replay_report.reference_generation = pod.reference_generation;
    _economy_replay_report.reference_day = pod.reference_day;
    _economy_replay_report.stage_hash = pod.stage_hash;
    _economy_replay_report.stage_work = pod.stage_work;
    _economy_replay_report.stage_ms = pod.stage_ms;
    _economy_replay_report.input_captured = pod.input_captured;
    _economy_replay_report.committed = pod.committed;
    _economy_replay_report.parity_ready = pod.parity_ready;
    _economy_replay_report.reference_captured = pod.reference_captured;
    _economy_replay_report.parity_compared = pod.parity_compared;
    _economy_replay_report.parity_matched = pod.parity_matched;
    copy_text(_economy_replay_report.fallback_reason, pod.fallback_reason);

    // Diagnostic lanes only: do not invent production/household_demand from
    // population. Keep committed_day/generation in lockstep with the POD epoch.
    _next.economy.committed_day = context.day;
    _next.economy.generation = _current.economy.generation + 1u;
    changed_cells = 0;
    work_units += static_cast<uint64_t>(cells) *
        static_cast<uint64_t>(RUNTIME_ECONOMY_GRAPH_STAGE_COUNT);
    out.completed = 1;
    out.preflight_ok = 1;
    out.dirty_families = RUNTIME_DIRTY_ECONOMY_UI;
    out.timing.work_units = static_cast<uint64_t>(cells) *
        static_cast<uint64_t>(RUNTIME_ECONOMY_GRAPH_STAGE_COUNT);
    out.timing.state_hash = pod.next_hash;
    out.timing.elapsed_ms = elapsed_ms(started);
    return out;
}

RuntimeDomainReport RuntimeDomainAuthorityRunner::run_events(
        const RuntimeDayContext &context, uint64_t &work_units) {
    RuntimeDomainReport out;
    out.domain = RuntimeDomainId::EVENTS;
    out.day = context.day;
    out.input_generation = context.input_generation;
    const auto started = std::chrono::steady_clock::now();
    for (const RuntimeDomainIntent &intent : _intents) {
        if (intent.target_domain != static_cast<uint16_t>(RuntimeDomainId::EVENTS))
            continue;
        if (_next.events.journal.size() >= _next.events.journal.capacity()) {
            set_report_error(out, "events_journal_capacity_exceeded");
            out.timing.elapsed_ms = elapsed_ms(started);
            return out;
        }
        RuntimeEventRecord event{};
        event.source_id = intent.source_id;
        event.event_id = _next.events.next_event_id++;
        event.day = context.day;
        event.type = intent.opcode;
        event.entity_handle = intent.target_handle;
        event.value = intent.value;
        event.payload = intent.payload;
        event.committed = 1;
        _next.events.journal.push_back(event);
    }
    std::stable_sort(_next.events.journal.begin(),
                     _next.events.journal.end(),
        [](const RuntimeEventRecord &a, const RuntimeEventRecord &b) {
            if (a.day != b.day) return a.day < b.day;
            if (a.source_id != b.source_id) return a.source_id < b.source_id;
            if (a.type != b.type) return a.type < b.type;
            if (a.entity_handle != b.entity_handle)
                return a.entity_handle < b.entity_handle;
            return a.event_id < b.event_id;
        });
    for (RuntimeEventRecord &event : _next.events.journal) {
        if (event.day <= context.day) event.committed = 1;
    }
    _next.events.committed_day = context.day;
    _next.events.generation = _current.events.generation + 1u;
    work_units += _next.events.journal.size();
    out.completed = 1;
    out.preflight_ok = 1;
    out.dirty_families = RUNTIME_DIRTY_EVENTS;
    out.timing.work_units = _next.events.journal.size();
    out.timing.state_hash = _next.events.state_hash();
    out.timing.elapsed_ms = elapsed_ms(started);
    return out;
}

RuntimeDomainReport RuntimeDomainAuthorityRunner::run_visual(
        const RuntimeDayContext &context) const {
    RuntimeDomainReport out;
    out.domain = RuntimeDomainId::VISUAL;
    out.day = context.day;
    out.input_generation = context.input_generation;
    out.completed = 1;
    out.preflight_ok = 1;
    out.dirty_families = RUNTIME_DIRTY_CLOCK;
    out.timing.work_units = 1;
    out.timing.state_hash = hash_mix(FNV_OFFSET,
                                     static_cast<uint64_t>(context.day));
    return out;
}

RuntimeDomainReport RuntimeDomainAuthorityRunner::run_commit(
        const RuntimeDayContext &context) const {
    RuntimeDomainReport out;
    out.domain = RuntimeDomainId::COMMIT;
    out.day = context.day;
    out.input_generation = context.input_generation;
    out.completed = 1;
    out.preflight_ok = 1;
    out.dirty_families = RUNTIME_DIRTY_CLOCK;
    out.timing.work_units = 1;
    out.timing.state_hash = _next.state_hash();
    return out;
}

} // namespace pk
