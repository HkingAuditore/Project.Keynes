#include "ideology_runtime.h"
#include "ideology_runtime_internal.h"
#include "ideology_runtime_common.inc"
#include <cstdio>
#include <cstdlib>


namespace pk {

using namespace godot;

int32_t NativeIdeologyRuntime::resolve_ideology_stat_id(
        const std::string &key, int32_t &cache) const {
    if (cache >= 0 || key.empty() || _modifier_runtime == nullptr ||
            !modifier_api::configured(*_modifier_runtime)) return cache;
    cache = modifier_api::stat_id_for_key(*_modifier_runtime, key);
    return cache;
}
int32_t NativeIdeologyRuntime::ideology_stat_factor_q16(
        const std::string &key, int32_t &cache, uint64_t handle) const {
    if (resolve_ideology_stat_id(key, cache) < 0)
        return static_cast<int32_t>(Q16_ONE);
    double factor = modifier_api::effective_value(*_modifier_runtime, ModifierApi::COUNTRY,
        cache, handle, 0, 1.0);
    if (!std::isfinite(factor)) factor = 1.0;
    return static_cast<int32_t>(std::lround(std::clamp(factor, 0.0, 4.0) * 65536.0));
}
int32_t NativeIdeologyRuntime::ideology_stat_bp(
        const std::string &key, int32_t &cache, uint64_t handle) const {
    if (resolve_ideology_stat_id(key, cache) < 0) return 0;
    double value = modifier_api::effective_value(*_modifier_runtime, ModifierApi::COUNTRY,
        cache, handle, 0, 0.0);
    if (!std::isfinite(value)) return 0;
    return static_cast<int32_t>(std::lround(std::clamp(value, 0.0, 10000.0)));
}

int32_t NativeIdeologyRuntime::ideology_stat_count(
        const std::string &key, int32_t &cache, uint64_t handle,
        int32_t cap) const {
    if (resolve_ideology_stat_id(key, cache) < 0) return 0;
    double value = modifier_api::effective_value(*_modifier_runtime, ModifierApi::COUNTRY,
        cache, handle, 0, 0.0);
    if (!std::isfinite(value)) return 0;
    return static_cast<int32_t>(std::lround(std::clamp(
        value, 0.0, static_cast<double>(std::max(0, cap)))));
}

int32_t NativeIdeologyRuntime::magnitude_scale_for(
        const CountryState &country, const std::string &program) const {
    if (_synergy_override_scales.empty() || program.empty()) return static_cast<int32_t>(Q16_ONE);
    // Product, not max: two cards that each rewrite the same program stack, and
    // taking the larger one would make the second card silently do nothing.
    // Clamped once at the end -- clamping per step would turn 1.5^3 into 1.5^2.
    const auto found = _synergy_override_index.find(program);
    if (found == _synergy_override_index.end()) return static_cast<int32_t>(Q16_ONE);
    ++_synergy_scale_lookups;
    int64_t scale = Q16_ONE;
    for (const auto &entry : found->second) {
        ++_synergy_scale_scans;
        if (!synergy_active(country, entry.first)) continue;
        scale = scale * entry.second / Q16_ONE;
        if (scale > 4 * Q16_ONE) { scale = 4 * Q16_ONE; break; }
    }
    if (scale < Q16_ONE / 4) scale = Q16_ONE / 4;
    if (scale > 4 * Q16_ONE) scale = 4 * Q16_ONE;
    return static_cast<int32_t>(scale);
}

bool NativeIdeologyRuntime::program_writes_school_strength(
        const std::string &program, int32_t school_index) const {
    if (_effect_runtime == nullptr || _modifier_runtime == nullptr ||
            school_index < 0 ||
            school_index >= static_cast<int32_t>(
                _school_strength_factor_stat_keys.size())) {
        return false;
    }
    const int32_t stat_id = modifier_api::stat_id_for_key(*_modifier_runtime,
        _school_strength_factor_stat_keys[static_cast<size_t>(school_index)]);
    if (stat_id < 0) return false;
    std::vector<EffectRuntime::ProgramModifierCommand> commands;
    if (!_effect_runtime->program_modifier_commands(program, commands))
        return false;
    for (const EffectRuntime::ProgramModifierCommand &command : commands) {
        std::vector<ModifierApi::ResolvedTerm> terms;
        if (!modifier_api::resolve_definition_terms(*_modifier_runtime,
                command.definition_key, terms)) {
            continue;
        }
        for (const ModifierApi::ResolvedTerm &term : terms)
            if (term.stat_id == stat_id) return true;
    }
    return false;
}

int32_t NativeIdeologyRuntime::school_strength_scale_q16(
        const CountryState &country, int32_t school_index) const {
    if (school_index < 0 ||
            school_index >= static_cast<int32_t>(_school_keys.size()))
        return static_cast<int32_t>(Q16_ONE);
    int32_t scale = static_cast<int32_t>(Q16_ONE);
    const size_t school_count = _school_keys.size();
    const size_t slot = static_cast<size_t>(
        static_cast<uint32_t>(country.handle & 0xffffffffULL));
    const RuntimeIdeologyOpinionSnapshot &opinion = _worker_opinion_inputs;
    if (_worker_opinion_inputs_valid && school_count > 0 &&
            opinion.school_strength_factor_q16.size() ==
                opinion.country_count * school_count) {
        for (size_t country_row = 0; country_row < opinion.country_count;
                ++country_row) {
            if (opinion.country_handles[country_row] != country.handle)
                continue;
            scale = opinion.school_strength_factor_q16[
                country_row * school_count +
                static_cast<size_t>(school_index)];
            break;
        }
    } else {
        // Synchronous/main-thread fallback. Prefer the cached country slot so a
        // worker snapshot with no country row cannot silently read the global
        // modifier bucket. If the catalog has no ModifierRuntime, the authored
        // base stays 1.0.
        (void)slot;
        if (_modifier_runtime != nullptr &&
                school_index < static_cast<int32_t>(
                    _school_strength_factor_stat_keys.size())) {
            scale = ideology_stat_factor_q16(
                _school_strength_factor_stat_keys[
                    static_cast<size_t>(school_index)],
                _school_strength_factor_stat_ids[
                    static_cast<size_t>(school_index)],
                country.handle);
        }
    }
    return std::clamp(scale, static_cast<int32_t>(Q16_ONE / 2),
        static_cast<int32_t>(2 * Q16_ONE));
}

bool NativeIdeologyRuntime::resolve_synergy_override_tags(
        std::string &error) const {
    error.clear();
    if (_synergy_override_tags_resolved) return true;
    // configure() is allowed to run before configure_effects(). Attaching the
    // EffectRuntime only clears this flag; resolve here, on the first actual
    // selector call, so both startup orders and direct test fixtures converge.
    if (_effect_runtime == nullptr) return false;
    _synergy_tag_overrides.clear();
    const TargetTagTable &tags = _effect_runtime->target_tags();
    std::unordered_map<std::string, int32_t> tag_ids;
    tag_ids.reserve(tags.names.size());
    for (size_t i = 0; i < tags.names.size(); ++i)
        tag_ids[tags.names[i]] = static_cast<int32_t>(i);
    for (size_t row = 0; row < _synergy_overrides.size(); ++row) {
        SynergyOverride &override = _synergy_overrides[row];
        if (override.field != 5) continue;
        override.match_tag_id = -1;
        override.tag_id = -1;
        const auto match = tag_ids.find(override.match_value);
        if (match == tag_ids.end()) {
            error = "ideology_synergy_override_tag_unknown";
            return false;
        }
        override.match_tag_id = match->second;
        const auto found = tag_ids.find(override.tag_name);
        if (found == tag_ids.end()) {
            error = "ideology_synergy_override_tag_unknown";
            return false;
        }
        override.tag_id = found->second;
        _synergy_tag_overrides[override.match_tag_id].push_back(
            static_cast<int32_t>(row));
    }
    _synergy_override_tags_resolved = true;
    return true;
}

EffectRuntime::FamilyEffectMetadataPod
NativeIdeologyRuntime::effective_selector_metadata(
        const CountryState &country, const std::string &program,
        const EffectRuntime::FamilyEffectMetadataPod &metadata) const {
    EffectRuntime::FamilyEffectMetadataPod out = metadata;
    if (_synergy_overrides.empty() || program.empty()) return out;
    std::string tag_error;
    if (!resolve_synergy_override_tags(tag_error)) return out;
    std::vector<int32_t> candidates;
    const auto by_program = _synergy_program_overrides.find(program);
    if (by_program != _synergy_program_overrides.end())
        candidates.insert(candidates.end(), by_program->second.begin(),
            by_program->second.end());
    if (out.target_selector_param[1] > 0) {
        const auto by_tag =
            _synergy_tag_overrides.find(out.target_selector_param[1] - 1);
        if (by_tag != _synergy_tag_overrides.end())
            candidates.insert(candidates.end(), by_tag->second.begin(),
                by_tag->second.end());
    }
    if (candidates.empty()) return out;
    std::sort(candidates.begin(), candidates.end());
    candidates.erase(std::unique(candidates.begin(), candidates.end()),
        candidates.end());
    struct Winner {
        int32_t minimum_level = -1;
        int32_t synergy_id = -1;
        int32_t value = 0;
        bool found = false;
    };
    Winner tag;
    Winner kind;
    Winner cap;
    for (const int32_t row : candidates) {
        if (row < 0 ||
                row >= static_cast<int32_t>(_synergy_overrides.size()))
            continue;
        const SynergyOverride &override =
            _synergy_overrides[static_cast<size_t>(row)];
        int32_t synergy_id = -1;
        for (size_t candidate = 0; candidate < _synergies.size(); ++candidate) {
            const Synergy &synergy = _synergies[candidate];
            if (row >= synergy.override_begin &&
                    row < synergy.override_begin + synergy.override_count) {
                synergy_id = static_cast<int32_t>(candidate);
                break;
            }
        }
        if (synergy_id < 0 || !synergy_active(country, synergy_id)) continue;
        const Synergy &synergy =
            _synergies[static_cast<size_t>(synergy_id)];
        int32_t minimum_level = 0;
        for (int32_t requirement = synergy.requirement_begin;
                requirement < synergy.requirement_begin +
                    synergy.requirement_count; ++requirement) {
            minimum_level = std::max(minimum_level,
                _synergy_requirements[static_cast<size_t>(requirement)]
                    .minimum_level);
        }
        Winner *target = nullptr;
        int32_t value = override.value;
        if (override.field == 5) {
            target = &tag;
            value = override.tag_id;
        } else if (override.field == 6) {
            target = &kind;
        } else if (override.field == 7) {
            target = &cap;
        }
        if (target == nullptr) continue;
        const bool wins = !target->found ||
            minimum_level > target->minimum_level ||
            (minimum_level == target->minimum_level &&
             synergy_id > target->synergy_id);
        if (wins) {
            target->minimum_level = minimum_level;
            target->synergy_id = synergy_id;
            target->value = value;
            target->found = true;
        }
    }
    // TAG only applies to a tag selector. A MATCH_TAG rewrite that reaches a
    // non-tag program is an authoring error caught by the generator lint; at
    // runtime it is ignored rather than changing an unrelated slot.
    if (tag.found && tag.value >= 0 &&
            (out.target_selector_kind == EffectRuntime::SELECTOR_OWN_TERRITORY ||
             out.target_selector_kind == EffectRuntime::SELECTOR_TAG_ANY_CELL ||
             out.target_selector_kind == EffectRuntime::SELECTOR_TAG_SOURCE_R1 ||
             out.target_selector_kind == EffectRuntime::SELECTOR_TAG_SOURCE_R2 ||
             out.target_selector_kind == EffectRuntime::SELECTOR_TAG_SOURCE_COUNT))
        out.target_selector_param[1] = tag.value + 1;
    if (kind.found)
        out.target_selector_kind = kind.value;
    if (cap.found)
        out.target_selector_param[0] = cap.value;
    return out;
}






bool NativeIdeologyRuntime::equip(CountryState &country, int32_t ideology_id,
        int64_t day, std::string &error) {
    if (!known(country, ideology_id)) { error = "ideology_unknown"; return false; }
    if (country.pending_transition_count > 0 && !_synergies.empty()) {
        error = "ideology_country_transition_pending"; return false;
    }
    IdeaState *state = idea_state_for(country, ideology_id, true);
    if (state == nullptr) { error = "ideology_state_unavailable"; return false; }
    if (state->transition.active != 0) { error = "ideology_transition_pending"; return false; }
    if (state->location == NATIONAL_SPIRIT) { error = "ideology_is_national_spirit"; return false; }
    if (state->location == IDEOLOGY) return true;
    if (!exclusion_allows(country, ideology_id, error) ||
            !support_gate(country, ideology_id, SUPPORT_ADOPT, error))
        return false;
    if (ideology_slot_cost(country) + _definitions[ideology_id].ideology_cost >
            ideology_capacity_for(static_cast<int32_t>(country.handle & 0xffffffffULL))) {
        error = "ideology_slot_capacity_exceeded"; return false;
    }
    reconcile_level(*state); // inactive, therefore no Effect needs replacement yet.
    const uint64_t entered = unentered_level_mask(*state, state->level);
    if (!start_transition(country, *state, IDEOLOGY, state->level,
            next_free_slot(country, IDEOLOGY, ideology_id), false, true,
            entered, day, error))
        return false;
    return true;
}

bool NativeIdeologyRuntime::unequip(CountryState &country, int32_t ideology_id,
        int64_t day, std::string &error) {
    if (country.pending_transition_count > 0 && !_synergies.empty()) {
        error = "ideology_country_transition_pending"; return false;
    }
    IdeaState *state = idea_state_for(country, ideology_id, false);
    if (state == nullptr || state->location != IDEOLOGY) { error = "ideology_not_equipped"; return false; }
    if (state->transition.active != 0) { error = "ideology_transition_pending"; return false; }
    if (!support_gate(country, ideology_id, SUPPORT_REPEAL, error))
        return false;
    if (!start_transition(country, *state, INACTIVE, state->level,
            state->slot_index, state->level >= 0, false, 0, day, error))
        return false;
    return true;
}

bool NativeIdeologyRuntime::promote(CountryState &country, int32_t ideology_id,
        int64_t day, std::string &error) {
    if (!known(country, ideology_id)) { error = "ideology_unknown"; return false; }
    if (country.pending_transition_count > 0 && !_synergies.empty()) {
        error = "ideology_country_transition_pending"; return false;
    }
    IdeaState *state = idea_state_for(country, ideology_id, true);
    if (state == nullptr) { error = "ideology_state_unavailable"; return false; }
    if (state->transition.active != 0) { error = "ideology_transition_pending"; return false; }
    if (state->location == NATIONAL_SPIRIT) return true;
    if (state->location != IDEOLOGY) {
        error = "ideology_promotion_requires_equipped"; return false;
    }
    reconcile_level(*state);
    const Definition &definition = _definitions[ideology_id];
    if (state->level < definition.min_spirit_level) { error = "ideology_national_spirit_level_insufficient"; return false; }
    if (spirit_slot_cost(country) + definition.spirit_cost >
            spirit_capacity_for(static_cast<int32_t>(country.handle & 0xffffffffULL))) {
        error = "national_spirit_slot_capacity_exceeded"; return false;
    }
    if (!support_gate(country, ideology_id, SUPPORT_PROMOTE, error))
        return false;
    if (!start_transition(country, *state, NATIONAL_SPIRIT, state->level,
            next_free_slot(country, NATIONAL_SPIRIT, ideology_id), false,
            false, 0, day, error)) return false;
    return true;
}
bool NativeIdeologyRuntime::validate_command_shape(const Command&cmd,std::string&error) const {
    if (cmd.opcode < DISCOVER_IDEOLOGY || cmd.opcode > GRANT_IDEOLOGY_FREE_DRAW ||
            cmd.country_handle == 0 || cmd.producer_id <= 0 ||
            cmd.sequence < 0) {
        error = "ideology_command_invalid";
        return false;
    }
    if ((cmd.opcode == DISCOVER_IDEOLOGY || cmd.opcode == EQUIP_IDEOLOGY ||
            cmd.opcode == UNEQUIP_IDEOLOGY ||
            cmd.opcode == PROMOTE_NATIONAL_SPIRIT ||
            cmd.opcode == ADD_UNDERSTANDING ||
            cmd.opcode == BAN_IDEOLOGY_CARD) &&
            (cmd.ideology_id < 0 ||
             cmd.ideology_id >= static_cast<int32_t>(_definitions.size()))) {
        error = "ideology_id_invalid";
        return false;
    }
    if (cmd.opcode == SET_IDEOLOGY_GATE &&
            (cmd.gate_id < 0 || cmd.gate_id >= _gate_count)) {
        error = "ideology_gate_invalid";
        return false;
    }
    if ((cmd.opcode == GRANT_IDEOLOGY_POINTS ||
            cmd.opcode == ADD_UNDERSTANDING) && cmd.value_q16 < 0) {
        error = "ideology_value_negative";
        return false;
    }
    if (cmd.opcode == GRANT_IDEOLOGY_FREE_DRAW &&
            (cmd.value_q16 <= 0 || cmd.value_q16 > 65535)) {
        error = "ideology_free_draw_invalid";
        return false;
    }
    return true;
}

size_t NativeIdeologyRuntime::pending_command_count() const {
    return _command_cursor <= _commands.size() ? _commands.size() - _command_cursor : 0;
}

const NativeIdeologyRuntime::Command *NativeIdeologyRuntime::next_command() const {
    return _command_cursor < _commands.size() ? &_commands[_command_cursor] : nullptr;
}

void NativeIdeologyRuntime::merge_staged_commands(std::vector<Command> &&staged) {
    std::stable_sort(staged.begin(), staged.end(), command_less);
    std::vector<Command> merged;
    merged.reserve(pending_command_count() + staged.size());
    auto existing = _commands.begin() + static_cast<std::ptrdiff_t>(
        std::min(_command_cursor, _commands.size()));
    std::merge(existing, _commands.end(), staged.begin(), staged.end(),
        std::back_inserter(merged), command_less);
    _command_queue_merge_steps += pending_command_count() + staged.size();
    _commands.swap(merged);
    _command_cursor = 0;
}

void NativeIdeologyRuntime::append_receipt(const Command &command, int32_t status,
        int64_t day, const std::string &reason) {
    Receipt receipt;
    receipt.receipt_id = _next_receipt_id++;
    receipt.producer_id = command.producer_id;
    receipt.sequence = command.sequence;
    receipt.status = status;
    receipt.opcode = command.opcode;
    receipt.country_handle = command.country_handle;
    receipt.ideology_id = command.ideology_id;
    receipt.settled_day = day;
    receipt.reason = reason;
    _receipts.push_back(std::move(receipt));
    if (static_cast<int32_t>(_receipts.size()) > _max_receipts) {
        const size_t remove_count = _receipts.size() -
            static_cast<size_t>(_max_receipts);
        _receipts.erase(_receipts.begin(),
            _receipts.begin() + static_cast<std::ptrdiff_t>(remove_count));
    }
}

void NativeIdeologyRuntime::append_transition_receipt(
        const IdeaState::Transition &transition, const IdeaState &state,
        uint64_t country_handle, int32_t status, int64_t day,
        const std::string &reason) {
    if (transition.producer_id <= 0) return;
    Command command;
    command.producer_id = transition.producer_id;
    command.sequence = transition.command_sequence;
    command.country_handle = country_handle;
    command.ideology_id = state.ideology_id;
    command.opcode = transition.command_opcode;
    append_receipt(command, status, day, reason);
}

Dictionary NativeIdeologyRuntime::poll_receipts(int64_t after_receipt_id,
        int32_t limit) const {
    const int32_t bounded_limit = std::max(1, std::min(limit, 4096));
    PackedInt64Array receipt_ids;
    PackedInt32Array producer_ids;
    PackedInt64Array sequences;
    PackedInt32Array statuses;
    PackedInt32Array opcodes;
    PackedInt64Array country_handles;
    PackedInt32Array ideology_ids;
    PackedInt64Array settled_days;
    PackedStringArray reasons;
    for (const Receipt &receipt : _receipts) {
        if (receipt.receipt_id <= after_receipt_id ||
                receipt_ids.size() >= bounded_limit) continue;
        receipt_ids.append(receipt.receipt_id);
        producer_ids.append(receipt.producer_id);
        sequences.append(receipt.sequence);
        statuses.append(receipt.status);
        opcodes.append(receipt.opcode);
        country_handles.append(static_cast<int64_t>(receipt.country_handle));
        ideology_ids.append(receipt.ideology_id);
        settled_days.append(receipt.settled_day);
        reasons.append(String(receipt.reason.c_str()));
    }
    Dictionary out;
    out["ok"] = true;
    out["receipt_ids"] = receipt_ids;
    out["producer_ids"] = producer_ids;
    out["sequences"] = sequences;
    out["statuses"] = statuses;
    out["opcodes"] = opcodes;
    out["country_handles"] = country_handles;
    out["ideology_ids"] = ideology_ids;
    out["settled_days"] = settled_days;
    out["reasons"] = reasons;
    out["count"] = receipt_ids.size();
    out["latest_receipt_id"] = _next_receipt_id - 1;
    return out;
}

Dictionary NativeIdeologyRuntime::submit_commands(const Dictionary &batch) {
    if (!_configured) return fail("ideology_runtime_unconfigured");
    const PackedInt32Array ops=i32s(batch,"opcodes"),producers=i32s(batch,"producer_ids"),prio=i32s(batch,"source_priorities"),ids=i32s(batch,"ideology_ids"),choices=i32s(batch,"choice_indices"),gates=i32s(batch,"gate_ids");
    const PackedInt64Array days=i64s(batch,"effective_days"),seq=i64s(batch,"sequences"),handles=i64s(batch,"country_handles"),values=i64s(batch,"values_q16"),offer=i64s(batch,"offer_generations");
    const int32_t count=ops.size();
    if(count<=0||(!producers.is_empty()&&producers.size()!=count)||days.size()!=count||prio.size()!=count||seq.size()!=count||handles.size()!=count||ids.size()!=count||values.size()!=count||offer.size()!=count||choices.size()!=count||gates.size()!=count)
        return fail("ideology_command_columns_invalid");
    std::vector<Command> staged;
    staged.reserve(static_cast<size_t>(count));
    auto staged_high_watermarks = _producer_high_watermarks;
    int32_t duplicates = 0;
    for(int32_t i=0;i<count;++i) {
        Command c;
        c.opcode=ops[i];c.effective_day=days[i];
        c.producer_id=producers.is_empty()?1:producers[i];c.source_priority=prio[i];
        c.sequence=seq[i];c.country_handle=static_cast<uint64_t>(handles[i]);
        c.ideology_id=ids[i];c.value_q16=values[i];
        c.offer_generation=static_cast<uint32_t>(std::max<int64_t>(0,offer[i]));
        c.choice_index=choices[i];c.gate_id=gates[i];
        c.submit_order=_submit_order+static_cast<uint64_t>(i)+1;
        std::string error;
        if(!validate_command_shape(c,error)) return fail(error);
        const auto found = staged_high_watermarks.find(c.producer_id);
        if (found != staged_high_watermarks.end() && c.sequence <= found->second) {
            ++duplicates;
            continue;
        }
        staged_high_watermarks[c.producer_id] = c.sequence;
        staged.push_back(c);
    }
    _submit_order+=static_cast<uint64_t>(count);
    _producer_high_watermarks.swap(staged_high_watermarks);
    merge_staged_commands(std::move(staged));
    Dictionary out;
    out["ok"]=true;
    out["accepted"]=count-duplicates;
    out["duplicates"]=duplicates;
    out["pending"]=static_cast<int32_t>(pending_command_count());
    return out;
}

bool NativeIdeologyRuntime::submit_trigger_command_pod(int32_t opcode, int64_t effective_day,
        int32_t source_priority, int64_t sequence, uint64_t country_handle,
        int32_t ideology_id, int64_t value_q16, uint32_t offer_generation,
        int32_t choice_index, int32_t gate_id, std::string &error) {
    if (!_configured) { error = "ideology_runtime_unconfigured"; return false; }
    Command command;
    command.opcode = opcode; command.effective_day = effective_day;
    command.producer_id = 2;
    command.source_priority = source_priority; command.sequence = sequence;
    command.country_handle = country_handle; command.ideology_id = ideology_id;
    command.value_q16 = value_q16; command.offer_generation = offer_generation;
    command.choice_index = choice_index; command.gate_id = gate_id;
    command.submit_order = _submit_order + 1;
    if (!validate_command_shape(command, error)) return false;
    const auto found = _producer_high_watermarks.find(command.producer_id);
    if (found != _producer_high_watermarks.end() &&
            command.sequence <= found->second) return true;
    _producer_high_watermarks[command.producer_id] = command.sequence;
    ++_submit_order;
    std::vector<Command> staged;
    staged.push_back(command);
    merge_staged_commands(std::move(staged));
    return true;
}
bool NativeIdeologyRuntime::apply_command(const Command &command, int64_t day,
        std::string &error) {
    int32_t country_slot = -1;
    if (!validate_country(command.country_handle, country_slot)) {
        error = "ideology_country_handle_stale"; return false;
    }
    CountryState *country = country_state_for(command.country_handle, true);
    if (country == nullptr) { error = "ideology_country_state_unavailable"; return false; }
    switch (command.opcode) {
        case DISCOVER_IDEOLOGY: {
            if ((_definitions[command.ideology_id].acquisition & DISCOVER) == 0) {
                error = "ideology_discovery_not_allowed"; return false;
            }
            set_known(*country, command.ideology_id);
            IdeaState *state = idea_state_for(*country, command.ideology_id, true);
            if (state != nullptr && state->location == INACTIVE) reconcile_level(*state);
            return true;
        }
        case GRANT_IDEOLOGY_POINTS:
            country->ideology_points_q16 = add_sat(country->ideology_points_q16, command.value_q16);
            return true;
        case GRANT_IDEOLOGY_FREE_DRAW:
            country->free_draws = static_cast<uint16_t>(std::min<int64_t>(
                65535, static_cast<int64_t>(country->free_draws) +
                    command.value_q16));
            return true;
        case OPEN_IDEOLOGY_OFFER: return open_offer(*country, country_slot, error);
        case REROLL_IDEOLOGY_OFFER: return reroll_offer(*country, country_slot, command, error);
        case CHOOSE_IDEOLOGY_OFFER: return choose_offer(*country, command, error);
        case BAN_IDEOLOGY_CARD: return ban_card(*country, command, error);
        case EQUIP_IDEOLOGY: return equip(*country, command.ideology_id, day, error);
        case UNEQUIP_IDEOLOGY: return unequip(*country, command.ideology_id, day, error);
        case PROMOTE_NATIONAL_SPIRIT: return promote(*country, command.ideology_id, day, error);
        case ADD_UNDERSTANDING: {
            if (!known(*country, command.ideology_id)) { error = "ideology_unknown"; return false; }
            IdeaState *state = idea_state_for(*country, command.ideology_id, true);
            if (state == nullptr) { error = "ideology_state_unavailable"; return false; }
            state->understanding_q16 = add_sat(state->understanding_q16, command.value_q16);
            if (state->location == INACTIVE) {
                reconcile_level(*state);
                return true;
            }
            return start_next_level_transition(*country, *state, day, error);
        }
        case SET_IDEOLOGY_GATE:
            set_gate(*country, command.gate_id, command.value_q16 != 0); return true;
        default: error = "ideology_command_unknown"; return false;
    }
}

} // namespace pk
