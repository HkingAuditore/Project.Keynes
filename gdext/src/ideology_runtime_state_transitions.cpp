#include "ideology_runtime.h"
#include "runtime_switch_registry.h"
#include "ideology_runtime_internal.h"
#include "ideology_runtime_common.inc"
#include <cstdio>
#include <cstdlib>


namespace pk {
using namespace godot;

bool NativeIdeologyRuntime::start_transition(CountryState &country, IdeaState &state,
        uint8_t location, int32_t level, uint8_t slot_index,
        bool remove_previous_persistent, bool apply_current_persistent,
        uint64_t entered_on_success, int64_t day, std::string &error) {
    if (state.transition.active != 0) { error = "ideology_transition_pending"; return false; }
    const auto index_it = country.idea_indices.find(state.ideology_id);
    if (index_it == country.idea_indices.end()) {
        error = "ideology_state_index_missing";
        return false;
    }
    const int32_t idea_slot = index_it->second;
    IdeaState::Transition transition;
    transition.active = 1;
    transition.producer_id = _applying_producer_id;
    transition.command_sequence = _applying_sequence;
    transition.command_opcode = _applying_opcode;
    transition.previous_level = state.level;
    transition.previous_entered_levels = state.entered_levels;
    transition.previous_generation = state.generation;
    transition.previous_location = state.location;
    transition.previous_slot_index = state.slot_index;
    transition.entered_on_success = entered_on_success;
    const int64_t previous_binding_id = state.binding_id;
    const uint32_t previous_binding_generation = state.binding_generation;
    const uint64_t previous_binding_signature = state.binding_signature;
    const uint64_t previous_binding_program_hash = state.binding_program_hash;
    bool new_binding_created = false;
    auto rollback_before_transition = [&]() {
        rollback_synergies(country, transition);
        if (new_binding_created && state.binding_id > 0 &&
                state.binding_generation != 0 && _effect_runtime != nullptr) {
            std::string ignored;
            _effect_runtime->retire_external_binding_pod(state.binding_id,
                state.binding_generation, ignored);
        }
        set_state_location(country, idea_slot, transition.previous_location);
        state.slot_index = transition.previous_slot_index;
        state.level = transition.previous_level;
        state.generation = transition.previous_generation;
        state.binding_id = previous_binding_id;
        state.binding_generation = previous_binding_generation;
        state.binding_signature = previous_binding_signature;
        state.binding_program_hash = previous_binding_program_hash;
        // A level replacement keeps the same external identity.  Restore its
        // previous durable binding after the failed new generation has been
        // retired; without this, a failed transition would leave PKID active
        // while PKEF held an inactive binding for that same identity.
        if (state.location != INACTIVE && _effect_runtime != nullptr) {
            std::string restore_error;
            if (!sync_external_binding(country.handle, state, restore_error) &&
                    error.empty())
                error = restore_error.empty()
                    ? "ideology_effect_binding_rollback_failed" : restore_error;
        }
    };
    _transition_command_scratch.clear();
    if (_transition_command_scratch.capacity() <
            static_cast<size_t>(_max_transition_commands))
        _transition_command_scratch.reserve(
            static_cast<size_t>(_max_transition_commands));
    set_state_location(country, idea_slot, location);
    state.slot_index = slot_index;
    state.level = level;
    ++state.generation;
    // Effect transactions are compacted after ACK.  Record a separate
    // durable binding before issuing any command so PKID can prove, on load,
    // which active ideology generation owns the persistent source.
    if (location != INACTIVE && !sync_external_binding(country.handle, state, error)) {
        rollback_before_transition();
        return false;
    }
    new_binding_created = location != INACTIVE;
    // REMOVE and APPLY go into SEPARATE batches, because they must name DIFFERENT
    // generations.
    //
    // Both are `enqueue_external_effect_batch_pod` calls, and that function derives
    // the Effect instance id from (source_type, transition_source_id, first.effect_id,
    // fire_sequence) (`effect_runtime.cpp:3465`). `transition_source_id` embeds the
    // idea's generation, and `NATIVE_MODIFIER_IDEOLOGY` then sets the Modifier row's
    // `source_id` from that instance (`effect_runtime.cpp:5509`).
    //
    // The row being removed was applied at `previous_generation`; the row being added
    // belongs to `state.generation`. Sharing one batch id therefore always mismatches
    // one side:
    //   * unequip (remove only): nothing is found, `already_removed`, row survives;
    //   * level-up / relocation (remove + apply in one transaction): the OLD level's
    //     row keeps its old `source_id`, so the REMOVE cannot find it and BOTH levels
    //     stay live.
    // Splitting the enqueue by generation fixes both cases with one rule instead of a
    // special case per command kind.
    if (remove_previous_persistent && transition.previous_location != INACTIVE &&
            transition.previous_level >= 0) {
        _removed_command_scratch.clear();
        if (!emit_level_effects(country, state, transition.previous_level, true,
                false, day, _removed_command_scratch, error)) {
            rollback_before_transition();
            return false;
        }
        if (!_removed_command_scratch.empty()) {
            const int64_t remove_source_id = static_cast<int64_t>(
                (static_cast<uint64_t>(state.ideology_id + 1) << 32U) |
                static_cast<uint32_t>(transition.previous_generation));
            int64_t remove_transaction_id = 0;
            if (!_effect_runtime->enqueue_external_effect_batch_pod(
                    day, 0x4944454F, remove_source_id, country.handle,
                    country.handle, static_cast<uint32_t>(country.handle >> 32U),
                    _removed_command_scratch.data(),
                    _removed_command_scratch.size(), error,
                    &remove_transaction_id) ||
                    remove_transaction_id <= 0) {
                if (error.empty()) error = "ideology_effect_batch_enqueue_failed";
                rollback_before_transition();
                return false;
            }
            transition.transaction_ids.push_back(remove_transaction_id);
        }
    }
    if (apply_current_persistent && location != INACTIVE && level >= 0 &&
            !emit_level_effects(country, state, level, false, false, day,
                _transition_command_scratch, error)) {
        rollback_before_transition();
        return false;
    }
    const Definition &definition = _definitions[static_cast<size_t>(state.ideology_id)];
    for (int32_t entered_level = 0; entered_level < definition.level_count && entered_level < 64; ++entered_level) {
        if ((entered_on_success & (1ULL << entered_level)) == 0) continue;
        const Level &row = _levels[definition.level_begin + entered_level];
        if (!emit_templates(country.handle, state.ideology_id, entered_level, row.on_enter_begin,
                row.on_enter_count, false, day, static_cast<uint64_t>(entered_level + 1),
                _transition_command_scratch, error)) {
            rollback_before_transition();
            return false;
        }
    }
    if (!collect_affected_synergies(country, state.ideology_id, day,
            transition, _transition_command_scratch, error)) {
        rollback_before_transition();
        return false;
    }
    if (!_transition_command_scratch.empty()) {
        int64_t transaction_id = 0;
        // Remaining scratch holds everything that BELONGS to the new generation: the
        // APPLY rows, on-enter one-shots and synergy rows. The REMOVE rows were
        // already enqueued above under `previous_generation` (see that block for why
        // the two cannot share a batch id).
        const int64_t transition_source_id = static_cast<int64_t>(
            (static_cast<uint64_t>(state.ideology_id + 1) << 32U) |
            static_cast<uint32_t>(state.generation));
        if (!_effect_runtime->enqueue_external_effect_batch_pod(
                day, 0x4944454F, transition_source_id, country.handle,
                country.handle, static_cast<uint32_t>(country.handle >> 32U),
                _transition_command_scratch.data(),
                _transition_command_scratch.size(), error, &transaction_id) ||
                transaction_id <= 0) {
            if (error.empty()) error = "ideology_effect_batch_enqueue_failed";
            rollback_before_transition();
            return false;
        }
        transition.transaction_ids.push_back(transaction_id);
    }
    if (transition.transaction_ids.empty()) {
        state.entered_levels |= entered_on_success;
        if (transition.previous_location != INACTIVE && _effect_runtime != nullptr) {
            std::string ignored;
            const int64_t retired_id = previous_binding_id > 0 ? previous_binding_id
                : static_cast<int64_t>(binding_id_for(country.handle, state.ideology_id,
                    transition.previous_location));
            const uint32_t retired_generation = previous_binding_generation != 0
                ? previous_binding_generation : transition.previous_generation;
            _effect_runtime->retire_external_binding_pod(retired_id,
                retired_generation, ignored);
        }
        if (state.location == INACTIVE) {
            state.binding_id = 0;
            state.binding_generation = 0;
            state.binding_signature = 0;
            state.binding_program_hash = 0;
        }
        // Allocated at the top for the deferred path; see the note there.
        {
            std::string reconcile_error;
            if (!reconcile_effect_activations(country, state, day,
                    reconcile_error))
                _last_error = reconcile_error;
        }
        return true;
    }
    state.transition = std::move(transition);
    ++country.pending_transition_count;
    append_pending_transition(country, idea_slot);
    return true;
}

bool NativeIdeologyRuntime::poll_pending_transition(PendingTransitionRef &ref,
        int64_t day) {
    if (_effect_runtime == nullptr || ref.country_slot < 0 ||
            ref.country_slot >= static_cast<int32_t>(_countries.size())) return false;
    CountryState &country = _countries[static_cast<size_t>(ref.country_slot)];
    if (country.handle != ref.country_handle || ref.idea_slot < 0 ||
            ref.idea_slot >= static_cast<int32_t>(country.ideas.size())) return false;
    IdeaState &state = country.ideas[static_cast<size_t>(ref.idea_slot)];
    if (state.transition.active == 0 || state.generation != ref.state_generation)
        return false;
    bool pending = false;
    bool failed = false;
    for (const int64_t transaction_id : state.transition.transaction_ids) {
        const int32_t status = _effect_runtime->transaction_status_pod(transaction_id);
        if (status == EffectRuntime::ACKED) continue;
        if (status == EffectRuntime::REJECTED ||
                status == EffectRuntime::RESYNC_REQUIRED || status == 0) {
            failed = true;
            break;
        }
        pending = true;
    }
    if (pending && !failed) return true;
    if (failed) {
        _last_error = "ideology_effect_transition_rejected";
        append_transition_receipt(state.transition, state, country.handle,
            RECEIPT_REJECTED, day, _last_error);
        rollback_synergies(country, state.transition);
        if (state.location != INACTIVE) {
            std::string ignored;
            _effect_runtime->retire_external_binding_pod(state.binding_id,
                state.binding_generation, ignored);
        }
        const uint8_t previous_location = state.transition.previous_location;
        const uint8_t previous_slot_index =
            state.transition.previous_slot_index;
        state.level = state.transition.previous_level;
        state.entered_levels = state.transition.previous_entered_levels;
        state.generation = state.transition.previous_generation;
        set_state_location(country, ref.idea_slot, previous_location);
        state.slot_index = previous_slot_index;
        state.binding_id = 0;
        state.binding_generation = 0;
        state.binding_signature = 0;
        state.binding_program_hash = 0;
        if (state.location != INACTIVE) {
            std::string restore_error;
            if (!sync_external_binding(country.handle, state, restore_error))
                _last_error = restore_error;
        }
        mark_instance_refresh_dirty();
    } else {
        append_transition_receipt(state.transition, state, country.handle,
            RECEIPT_SETTLED, day);
        state.entered_levels |= state.transition.entered_on_success;
        if (state.transition.previous_location != INACTIVE) {
            std::string ignored;
            _effect_runtime->retire_external_binding_pod(
                binding_id_for(country.handle, state.ideology_id,
                    state.transition.previous_location),
                state.transition.previous_generation, ignored);
        }
        if (state.location == INACTIVE) {
            state.binding_id = 0;
            state.binding_generation = 0;
            state.binding_signature = 0;
            state.binding_program_hash = 0;
        }
        mark_instance_refresh_dirty();
    }
    country.pending_transition_count =
        std::max(0, country.pending_transition_count - 1);
    state.transition = IdeaState::Transition{};
    if (!failed) {
        // ── plan §9.3: the projection is confirmed TODAY, eligible TOMORROW ──
        //
        // "该确认投影的 eligible_from_day = D+1. 在 sample_day = S 的新经济冻结边界，只能
        // 选择满足 eligible_from_day <= S 的最新已确认投影."
        //
        // Recorded only on the success path: a rejected transition produces no
        // projection, so it must not move the dates.
        _derived_basis_confirmed_day = day;
        _derived_basis_eligible_day = day + 1;
        // Deferred success is the only point where level/location are durably
        // committed, so the instance set converges here rather than at request
        // time. A failure leaves the previous set untouched by construction.
        std::string reconcile_error;
        if (!reconcile_effect_activations(country, state, day,
                reconcile_error))
            _last_error = reconcile_error;
    }
    return false;
}

bool NativeIdeologyRuntime::start_next_level_transition(CountryState &country,
        IdeaState &state, int64_t day, std::string &error) {
    if (state.location == INACTIVE || state.transition.active != 0) return true;
    if (country.pending_transition_count > 0 && !_synergies.empty())
        return true;
    const int32_t unlocked = unlocked_level(state);
    const int32_t next = state.level + 1;
    if (unlocked < next) return true;
    const uint64_t entered = next < 64 && (state.entered_levels & (1ULL << next)) == 0
        ? (1ULL << next) : 0;
    const bool started = start_transition(country, state, state.location, next,
        state.slot_index, state.level >= 0, true, entered, day, error);
    if (started) ++_levels_advanced;
    return started;
}

} // namespace pk
