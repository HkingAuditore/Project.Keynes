bool RuntimeIdeologyPodAuthority::plan_day(
        int64_t day, const RuntimeCountryPodSnapshot &country,
        const RuntimeIdeologyOpinionSnapshot &opinion,
        const std::vector<RuntimeDomainAck> &acks,
        RuntimeIdeologyPodPlan &plan, std::string &error) {
    error.clear(); plan = RuntimeIdeologyPodPlan{};
    if (_plan_ready) { error = "ideology_plan_already_ready"; return false; }
    if (!validate_inputs(country, opinion, error)) return false;
    if (_current.countries.empty()) { error = "ideology_pod_not_bootstrapped"; return false; }
    plan.base_generation = _current.generation;
    plan.input_generation = country.generation;
    plan.next_snapshot = _current;
    auto &state = plan.next_snapshot;
    append_country_rows(state, country.country_active, country.country_generation, opinion.revision);
    if (state.round_day < 0) {
        if (day <= state.committed_day) {
            // ── a RESTORED state is ahead of this worker's calendar ──────────
            //
            // A restore replaces the POD's whole state INCLUDING its committed day. The
            // worker's own calendar can be behind that day: a worker world starts at the
            // host's `day`, and a save carries the day it was taken on, so a load into a
            // younger worker session (or into a fresh one) has `day <= committed_day`.
            //
            // The unguarded monotonicity rule then refuses EVERY worker day until the
            // calendar catches up -- `ideology_day_not_monotonic`, an Ideology stage that
            // fails for the rest of the session, and (because the stage returns before it
            // publishes) NO snapshot at all, so the restored rows would be frozen rather
            // than adopted. Freezing is not what "supersede" means.
            //
            // The imported state already settles those days, so the honest plan for them
            // is "nothing changes": the day completes, a generation is published so the
            // main-thread mirror is refreshed FROM the imported state, and the calendar
            // advances one day per day until it passes the floor. The rule is armed only
            // by `restore`, so a genuine backwards move still fails loudly.
            if (!_import_supersedes_calendar) {
                error = "ideology_day_not_monotonic"; return false;
            }
            plan.superseded_day = 1;
            plan.completed_day = 1;
            state.generation = _current.generation + 1u;
            state.state_hash = compute_state_hash(state);
            plan.plan_hash = state.state_hash;
            plan.preflight_ok = 1;
            _planned = state;
            _plan_ready = true;
            return true;
        }
        state.round_day = day;
        state.phase = RuntimeIdeologyPodPhase::PENDING_TRANSITIONS;
        state.pending_cursor = state.command_cursor = 0;
        state.active_country_cursor = state.active_idea_cursor = 0;
        state.input_generation = country.generation;
        // Revision 0 cannot reach here (validate_inputs rejects it); the guard
        // documents why accrual is skipped rather than booked for a non-opinion.
        if (opinion.revision != 0) accrue_points(state, opinion, day);
    } else if (state.round_day != day || state.input_generation != country.generation) {
        error = "ideology_same_day_continuation_input_changed"; return false;
    } else if (state.opinion_revision != opinion.revision) {
        error = "ideology_same_day_continuation_opinion_changed"; return false;
    }
    state.opinion_revision = opinion.revision;
    if (state.phase == RuntimeIdeologyPodPhase::PENDING_TRANSITIONS) {
        for (const auto &ack : acks) if (!apply_ack(state, ack, day, plan, error)) return false;
        uint32_t visits = 0;
        while (state.pending_cursor < state.pending_transitions.size() &&
               visits < _catalog.max_transition_polls_per_slice) {
            emit_transition(state, state.pending_transitions[state.pending_cursor], plan);
            ++state.pending_cursor; ++visits;
        }
        plan.transition_visits = visits;
        if (state.pending_cursor < state.pending_transitions.size()) {
            plan.preflight_ok = 1; goto finish;
        }
        state.pending_cursor = 0;
        state.phase = RuntimeIdeologyPodPhase::COMMANDS;
    }
    if (state.phase == RuntimeIdeologyPodPhase::COMMANDS) {
        uint32_t consumed = 0;
        while (state.command_cursor < state.commands.size() &&
               state.commands[state.command_cursor].effective_day <= day &&
               consumed < _catalog.max_commands_per_slice) {
            const auto &command = state.commands[state.command_cursor];
            if (command.sequence <= producer_high_watermark(state,
                                                            command.producer_id)) {
                ++state.command_cursor;
                ++consumed;
                continue;
            }
            std::string command_error;
            const size_t pending_before = state.pending_transitions.size();
            const bool applied = apply_command(state, country, opinion, command, plan, command_error);
            RuntimeIdeologyPodReceipt receipt;
            receipt.request_id = command.request_id; receipt.producer_id = command.producer_id;
            receipt.sequence = command.sequence; receipt.opcode = command.opcode;
            receipt.country_handle = command.country_handle; receipt.ideology_id = command.ideology_id;
            receipt.settled_day = day;
            if (!applied) {
                receipt.status = RuntimeIdeologyPodReceiptStatus::REJECTED;
                receipt.reason_code = 1;
                receipt.reason_text = command_error;
            } else if (state.pending_transitions.size() > pending_before) { receipt.status = RuntimeIdeologyPodReceiptStatus::PENDING; receipt.settled_day = -1; }
            else receipt.status = RuntimeIdeologyPodReceiptStatus::SETTLED;
            state.receipts.push_back(receipt);
            update_producer_high_watermark(state, command.producer_id,
                                           command.sequence);
            ++state.command_cursor; ++consumed;
        }
        plan.commands_consumed = consumed;
        if (state.command_cursor < state.commands.size() &&
            state.commands[state.command_cursor].effective_day <= day) {
            plan.preflight_ok = 1; goto finish;
        }
        state.phase = RuntimeIdeologyPodPhase::ACTIVE_PROGRESS;
    }
    if (state.phase == RuntimeIdeologyPodPhase::ACTIVE_PROGRESS) {
        uint32_t visits = 0;
        while (state.active_country_cursor < state.countries.size()) {
            auto &country_row = state.countries[state.active_country_cursor];
            if (country_row.handle == 0 ||
                state.active_idea_cursor >= country_row.active_idea_ids.size()) {
                ++state.active_country_cursor; state.active_idea_cursor = 0; continue;
            }
            if (visits >= _catalog.max_active_visits_per_slice) break;
            const int32_t idea_id = static_cast<int32_t>(
                country_row.active_idea_ids[state.active_idea_cursor++]);
            auto &idea = country_row.ideas[idea_id];
            if (idea.location == RuntimeIdeologyPodLocation::INACTIVE) continue;
            ++visits;
            const auto &definition = _catalog.definitions[idea_id];
            if (idea.level >= 0 && idea.level < static_cast<int32_t>(definition.level_count)) {
                const int64_t daily = _catalog.levels[
                    definition.level_begin + static_cast<uint32_t>(idea.level)]
                    .daily_understanding_q16;
                // A zero-rate level skips the read entirely: the loop runs once
                // per active idea per day and most levels accrue nothing.
                if (daily != 0)
                    idea.understanding_q16 = add_sat(idea.understanding_q16,
                        ideology_scaled_daily(daily, ideology_frozen_factor(
                            opinion.understanding_gain_q16,
                            state.active_country_cursor)));
            }
            bool pending = false;
            for (const auto &transition : state.pending_transitions)
                if (transition.country_slot == state.active_country_cursor && transition.ideology_id == idea_id) { pending = true; break; }
            const int32_t unlocked = unlocked_level(idea, idea_id);
            if (!pending && unlocked > idea.level) {
                const uint64_t entered = unlocked == 63 ? ~idea.entered_levels : (((1ull << (unlocked + 1)) - 1ull) & ~idea.entered_levels);
                if (!begin_transition(state, state.active_country_cursor, idea_id, unlocked,
                                      idea.location, idea.slot_index, entered,
                                      nullptr, day, plan, error)) return false;
            }
        }
        plan.active_visits = visits;
        if (state.active_country_cursor < state.countries.size()) {
            plan.preflight_ok = 1; goto finish;
        }
        if (state.command_cursor > 0) {
            state.commands.erase(state.commands.begin(), state.commands.begin() + static_cast<std::ptrdiff_t>(state.command_cursor));
            state.command_cursor = 0;
        }
        state.committed_day = day; state.round_day = -1;
        state.phase = RuntimeIdeologyPodPhase::PENDING_TRANSITIONS;
        state.active_country_cursor = state.active_idea_cursor = 0;
        plan.completed_day = 1;
    }

finish:
    state.generation = _current.generation + 1u;
    state.state_hash = compute_state_hash(state);
    plan.plan_hash = state.state_hash;
    plan.preflight_ok = 1;
    _planned = state;
    _plan_ready = true;
    return true;
}

bool RuntimeIdeologyPodAuthority::commit_day(
        RuntimeIdeologyPodPlan &plan, std::string &error) {
    if (!_plan_ready || plan.preflight_ok == 0 || plan.committed != 0 ||
        plan.base_generation != _current.generation ||
        plan.next_snapshot.state_hash != _planned.state_hash ||
        compute_state_hash(plan.next_snapshot) != plan.next_snapshot.state_hash) {
        error = "ideology_plan_commit_invalid"; return false;
    }
    _current = std::move(plan.next_snapshot);
    _planned = _current;
    plan.committed = 1;
    _plan_ready = false;
    // A day that actually advanced the calendar past the restored floor retires the
    // supersede rule; a day the import already settles keeps it armed.
    if (plan.superseded_day == 0) _import_supersedes_calendar = false;
    return true;
}

void RuntimeIdeologyPodAuthority::rearm_pending_transitions() {
    bool changed = false;
    for (auto &transition : _current.pending_transitions) {
        if (transition.intent_emitted == 0) continue;
        transition.intent_emitted = 0;
        changed = true;
    }
    if (changed) {
        _current.pending_cursor = 0;
        _current.state_hash = compute_state_hash(_current);
        _planned = _current;
        _plan_ready = false;
    }
}
