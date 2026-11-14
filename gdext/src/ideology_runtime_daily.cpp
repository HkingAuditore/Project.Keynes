#include "ideology_runtime.h"
#include "ideology_runtime_internal.h"
#include "ideology_runtime_common.inc"
#include <cstdio>
#include <cstdlib>


namespace pk {

using namespace godot;

Dictionary NativeIdeologyRuntime::run_daily(int64_t day,
        const RuntimeIdeologyOpinionSnapshot *frozen_opinion) {
    if (!_configured) return fail("ideology_runtime_unconfigured");
    if (frozen_opinion != nullptr)
        accrue_points_from(*frozen_opinion, day);
    else
        accrue_points(day);
    return run_daily_slices(day);
}

Dictionary NativeIdeologyRuntime::run_daily_slices(int64_t day) {
    const Clock::time_point slice_started = Clock::now();
    int32_t handled = 0;    int32_t visits = 0;
    int32_t transition_visits = 0;
    auto finish = [&](bool done, const char *stage) {
        _daily_continuation_day = done ? -1 : day;
        _last_slice_ms = elapsed_ms(slice_started);
        _max_slice_ms = std::max(_max_slice_ms, _last_slice_ms);
        Dictionary out;
        out["ok"] = true; out["done"] = done; out["stage"] = stage;
        out["day_barrier"] = !done;
        out["path"] = "IDEOLOGY_GRAPH";
        out["commands_applied"] = handled; out["active_visits"] = visits;
        out["pending_transition_visits"] = transition_visits;
        out["dormant_scan_count"] = static_cast<int64_t>(_dormant_scan_count);
        out["sparse_idea_scan_count"] = static_cast<int64_t>(_sparse_idea_scan_count);
        out["pending_transitions"] = static_cast<int32_t>(_pending_transitions.size());
        out["pending_commands"] = static_cast<int32_t>(pending_command_count());
        out["cursor_start"] = _active_country_cursor;
        out["cursor_end"] = _active_country_cursor;
        out["progress_ratio"] = done ? 1.0 : (_countries.empty() ? 0.0 :
            static_cast<double>(_active_country_cursor) / static_cast<double>(_countries.size()));
        out["elapsed_ms"] = _last_slice_ms;
        return out;
    };
    const Clock::time_point transition_started = Clock::now();
    while (_pending_transition_cursor < _pending_transitions.size() &&
            transition_visits < _max_transition_polls_per_slice) {
        PendingTransitionRef &ref = _pending_transitions[_pending_transition_cursor++];
        ++transition_visits; ++_pending_transition_visits;
        if (!poll_pending_transition(ref, day)) ref.country_slot = -1;
    }
    _transition_poll_ms += elapsed_ms(transition_started);
    if (_pending_transition_cursor < _pending_transitions.size())
        return finish(false, "ideology_transition_poll");
    _pending_transition_cursor = 0;
    _pending_transitions.erase(std::remove_if(_pending_transitions.begin(),
        _pending_transitions.end(), [](const PendingTransitionRef &ref) {
            return ref.country_slot < 0;
        }), _pending_transitions.end());

    const Clock::time_point command_started = Clock::now();
    const Command *command = next_command();
    while (command != nullptr && command->effective_day <= day &&
            handled < _max_commands_per_slice) {
        std::string error;
        _applying_producer_id = command->producer_id;
        _applying_sequence = command->sequence;
        _applying_opcode = command->opcode;
        const bool applied = apply_command(*command, day, error);
        _applying_producer_id = 0;
        _applying_sequence = 0;
        _applying_opcode = 0;
        if (!applied) {
            ++_commands_rejected;
            _last_error = error;
            append_receipt(*command, RECEIPT_REJECTED, day, error);
        } else {
            ++_commands_applied;
            bool pending_receipt = false;
            const CountryState *country = country_state_for(command->country_handle);
            const IdeaState *state = country == nullptr ? nullptr :
                idea_state_for(*country, command->ideology_id);
            if (state != nullptr && state->transition.active != 0 &&
                    state->transition.producer_id == command->producer_id &&
                    state->transition.command_sequence == command->sequence)
                pending_receipt = true;
            append_receipt(*command, pending_receipt ? RECEIPT_PENDING :
                RECEIPT_SETTLED, day);
        }
        ++_command_cursor; ++handled;
        command = next_command();
    }
    if (_command_cursor == _commands.size()) {
        _commands.clear();
        _command_cursor = 0;
    }
    _command_apply_ms += elapsed_ms(command_started);
    command = next_command();
    if (command != nullptr && command->effective_day <= day)
        return finish(false, "ideology_commands");

    if (_active_progress_day != day && _last_day < day) {
        _active_progress_day = day;
        _active_country_cursor = 0;
        _active_item_cursor = 0;
        // Once per day is enough: the refresh gate only needs to know whether
        // any managed card is in play, and that set changes at most on equip.
        recount_managed_active();
    }
    const Clock::time_point active_started = Clock::now();
    while (_active_progress_day == day &&
            _active_country_cursor < static_cast<int32_t>(_countries.size())) {
        CountryState &country = _countries[static_cast<size_t>(_active_country_cursor)];
        int32_t country_slot = -1;
        if (country.handle == 0 || !validate_country(country.handle, country_slot) ||
                _active_item_cursor >= static_cast<int32_t>(country.active_state_indices.size())) {
            ++_active_country_cursor;
            _active_item_cursor = 0;
            continue;
        }
        if (visits >= _max_active_visits_per_slice) {
            _active_progress_ms += elapsed_ms(active_started);
            return finish(false, "ideology_active_progress");
        }
        const int32_t idea_slot = country.active_state_indices[
            static_cast<size_t>(_active_item_cursor++)];
        if (idea_slot >= 0 && idea_slot < static_cast<int32_t>(country.ideas.size())) {
            IdeaState *state = &country.ideas[static_cast<size_t>(idea_slot)];
            const int32_t ideology_id = state->ideology_id;
            if (state->location != INACTIVE) {
                ++visits; ++_active_visits;
                const Definition &definition = _definitions[static_cast<size_t>(ideology_id)];
                const int32_t growth_level = state->transition.active != 0
                    ? state->transition.previous_level : state->level;
                if (growth_level >= 0 && growth_level < definition.level_count) {
                    const int64_t daily =
                        _levels[definition.level_begin + growth_level].daily_understanding_q16;
                    // Levels that intentionally accrue nothing skip the modifier
                    // lookup entirely: 0 * anything is 0, and the accrual loop
                    // runs once per active idea per day.
                    if (daily != 0)
                        state->understanding_q16 = add_sat(
                            state->understanding_q16,
                            ideology_scaled_daily(daily, ideology_stat_factor_q16(
                                _understanding_gain_stat_key,
                                _understanding_gain_stat_id, country.handle)));
                }
                std::string error;
                if (!start_next_level_transition(country, *state, day, error)) {
                    ++_commands_rejected;
                    _last_error = error;
                }
            }
        }
    }
    _active_progress_ms += elapsed_ms(active_started);
    if (_active_progress_day == day) {
        _active_progress_day = -1;
        _active_country_cursor = 0;
        _active_item_cursor = 0;
        _last_day = day;
    }
    // P1-A: the instance refresh runs after the day's own work, and finishing
    // the day is NOT the same as being idle. While the pass still has countries
    // left, report done=false so the graph keeps scheduling this system.
    if (step_effect_instance_refresh(day))
        return finish(false, "ideology_instance_refresh");
    // §14.3: the derived rebuild is a SLICE STAGE. Reporting done=false keeps the
    // graph scheduling this system until the fold completes; nothing is installed
    // until then, so a reader never observes a half-built front.
    //
    // Unlike the first attempt (M4-18), the fold state lives in `_derived_rebuild_job`
    // across steps, so each step really does only its own share of the work.
    if (_modifier_runtime != nullptr && _effect_runtime != nullptr) {
        std::string rebuild_error;
        if (!step_derived_rebuild(day, rebuild_error)) {
            if (!rebuild_error.empty()) _last_error = rebuild_error;
            return finish(false, "ideology_derived_rebuild");
        }
        if (!rebuild_error.empty()) _last_error = rebuild_error;
    }
    return finish(true, "ideology_active_progress");
}
bool NativeIdeologyRuntime::needs_daily_continuation(int64_t day) const {
    const Command *command = next_command();
    return _configured && (_daily_continuation_day == day ||
        _active_progress_day == day || _last_day < day ||
        (command != nullptr && command->effective_day <= day));
}

bool NativeIdeologyRuntime::should_run(int64_t day) const {
    return _configured && (needs_daily_continuation(day) ||
        !_pending_transitions.empty() ||
        derived_rebuild_pending() ||
        // P1-A: a stale input revision has to wake the graph, otherwise the
        // refresh would only ever run on a day that had other work to do.
        // Ideology scalars are local derived inputs: their dirty flag must wake
        // the graph even when no Economy authority is attached.
        (_managed_active_total > 0 &&
         (_instance_refresh_pending || _instance_refresh_dirty ||
          (_economy_runtime != nullptr &&
           economy_api::effect_input_revision(*_economy_runtime) != _effect_input_revision_seen))));
}

} // namespace pk
