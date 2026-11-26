bool RuntimeIdeologyPodAuthority::requirements_met(
        const RuntimeIdeologyPodSnapshot &state,
        const RuntimeCountryPodSnapshot &country, uint32_t slot,
        int32_t ideology_id) const {
    const auto &d = _catalog.definitions[static_cast<size_t>(ideology_id)];
    for (uint32_t i = 0; i < d.technology_count; ++i) {
        const int32_t id = _catalog.technology_requirements[d.technology_begin + i];
        const size_t index = static_cast<size_t>(slot) * country.technology_words + id / 64;
        if ((country.country_technologies[index] & (1ull << (id % 64))) == 0) return false;
    }
    for (uint32_t i = 0; i < d.signal_count; ++i) {
        const int32_t id = _catalog.signal_requirements[d.signal_begin + i];
        const size_t index = static_cast<size_t>(slot) * country.research_signal_words + id / 64;
        if ((country.country_research_signals[index] & (1ull << (id % 64))) == 0) return false;
    }
    for (uint32_t i = 0; i < d.gate_count; ++i)
        if (!bit_get(state.countries[slot].gate_bits, _catalog.gate_requirements[d.gate_begin + i])) return false;
    return true;
}

bool RuntimeIdeologyPodAuthority::support_allows(
        const RuntimeIdeologyPodSnapshot &state,
        const RuntimeIdeologyOpinionSnapshot &opinion, uint32_t slot,
        int32_t ideology_id, uint32_t direction) const {
    if (ideology_id < 0 ||
        static_cast<size_t>(ideology_id) >= _catalog.definitions.size())
        return false;
    // `PK_DISABLE_SUPPORT_GATE` 是文档化的模拟开关（runtime_switch_registry.cpp:28），
    // 主线程路径已经在 world_ext_ideology.cpp:164 应用它；worker/pod 路径若忽略它，
    // 同一开关就会在不同权威形态下表现不一致（x6c 实测：fixture 设了开关仍然被拒）。
    if (pk::runtime_switch_value(
            pk::RuntimeSwitch::PK_DISABLE_SUPPORT_GATE) != nullptr) {
        return true;
    }
    const auto &d = _catalog.definitions[static_cast<size_t>(ideology_id)];
    if (d.stance_count == 0) return true;
    if (_catalog.incidence.channel_count <= 0) return true;  // no model yet
    int32_t level = 0;
    if (slot < state.countries.size() &&
        static_cast<size_t>(ideology_id) < state.countries[slot].ideas.size())
        level = std::max<int32_t>(0,
            state.countries[slot].ideas[static_cast<size_t>(ideology_id)].level);
    if (!_catalog.incidence.level_has_effect(level)) return true;
    return ideology_incidence::support_allows_material(_catalog.incidence,
        opinion, slot, _catalog.class_count, static_cast<uint32_t>(level),
        d.support_threshold_q16[direction], _catalog.owner_influence_weight,
        _catalog.funds_per_influence);
}
int32_t RuntimeIdeologyPodAuthority::unlocked_level(
        const RuntimeIdeologyPodIdeaState &idea, int32_t ideology_id) const {
    const auto &d = _catalog.definitions[static_cast<size_t>(ideology_id)];
    int32_t unlocked = -1;
    for (uint32_t level = 0; level < d.level_count; ++level) {
        if (idea.understanding_q16 < _catalog.levels[d.level_begin + level].threshold_q16) break;
        unlocked = static_cast<int32_t>(level);
    }
    return unlocked;
}

void RuntimeIdeologyPodAuthority::compute_synergies(
        const RuntimeIdeologyPodCountryState &country, int32_t override_ideology,
        int32_t override_level, RuntimeIdeologyPodLocation override_location,
        std::vector<uint64_t> &out) const {
    out = country.synergy_bits;
    if (out.size() != (_catalog.synergies.size() + 63u) / 64u)
        out.assign((_catalog.synergies.size() + 63u) / 64u, 0);
    if (override_ideology < 0 ||
        static_cast<size_t>(override_ideology + 1) >=
            _catalog.ideology_synergy_offsets.size()) return;
    const uint32_t candidate_begin = _catalog.ideology_synergy_offsets[
        static_cast<size_t>(override_ideology)];
    const uint32_t candidate_end = _catalog.ideology_synergy_offsets[
        static_cast<size_t>(override_ideology + 1)];
    for (uint32_t candidate = candidate_begin; candidate < candidate_end;
         ++candidate) {
        const uint32_t synergy_id = static_cast<uint32_t>(
            _catalog.ideology_synergy_ids[candidate]);
        const auto &synergy = _catalog.synergies[synergy_id];
        const uint32_t needed = synergy.min_count == 0 ? synergy.requirement_count : synergy.min_count;
        uint32_t held = 0;
        for (uint32_t row = 0; row < synergy.requirement_count; ++row) {
            const auto &requirement = _catalog.synergy_requirements[synergy.requirement_begin + row];
            const auto &idea = country.ideas[static_cast<size_t>(requirement.ideology_id)];
            const int32_t level = requirement.ideology_id == override_ideology ? override_level : idea.level;
            const RuntimeIdeologyPodLocation location = requirement.ideology_id == override_ideology ? override_location : idea.location;
            if (level >= requirement.minimum_level &&
                (requirement.location_mask & (1u << static_cast<uint8_t>(location))) != 0)
                ++held;
        }
        bit_set(out, static_cast<int32_t>(synergy_id), held >= needed);
    }
}

uint64_t RuntimeIdeologyPodAuthority::transition_identity(
        const RuntimeIdeologyPodTransition &transition,
        RuntimeIdeologyPodOpcode opcode) const {
    uint64_t hash = FNV_OFFSET;
    hash = hash_value(hash, _catalog.catalog_hash); hash = hash_value(hash, transition.request_id);
    hash = hash_value(hash, transition.producer_id); hash = hash_value(hash, transition.sequence);
    hash = hash_value(hash, transition.effective_day); hash = hash_value(hash, transition.country_slot);
    hash = hash_value(hash, transition.country_generation); hash = hash_value(hash, transition.ideology_id);
    hash = hash_value(hash, transition.desired_level); hash = hash_value(hash, transition.desired_location);
    hash = hash_value(hash, opcode);
    return hash == 0 ? 1 : hash;
}

void RuntimeIdeologyPodAuthority::emit_transition(
        const RuntimeIdeologyPodSnapshot &state,
        RuntimeIdeologyPodTransition &transition,
        RuntimeIdeologyPodPlan &plan) const {
    if (transition.intent_emitted != 0) return;
    // Level rows of the retained (pre-ACK) state versus the desired state.
    // UniqueSource APPLY is an upsert, so a tier change re-applies with the
    // new magnitude and only definitions absent from the new tier are removed.
    if (transition.country_slot < state.countries.size()) {
        const auto &country = state.countries[transition.country_slot];
        const auto &definition = _catalog.definitions[static_cast<size_t>(transition.ideology_id)];
        const auto &idea = country.ideas[static_cast<size_t>(transition.ideology_id)];
        auto tier = [&](int32_t level, RuntimeIdeologyPodLocation location,
                        uint32_t &begin, uint32_t &count) {
            begin = count = 0;
            if (location == RuntimeIdeologyPodLocation::INACTIVE || level < 0 ||
                level >= static_cast<int32_t>(definition.level_count)) return;
            const auto &row = _catalog.levels[definition.level_begin + static_cast<uint32_t>(level)];
            begin = row.modifier_begin; count = row.modifier_count;
        };
        uint32_t old_begin = 0, old_count = 0, new_begin = 0, new_count = 0;
        tier(idea.level, idea.location, old_begin, old_count);
        tier(transition.desired_level, transition.desired_location, new_begin, new_count);
        const uint64_t handle = (static_cast<uint64_t>(transition.country_generation) << 32u) | transition.country_slot;
        uint32_t ordinal = 0;
        auto push = [&](const RuntimeIdeologyPodModifierTemplate &templ, uint16_t opcode) {
            RuntimeIdeologyPodModifierRow row;
            row.transition_id = transition.intent_id;
            row.country_handle = handle;
            row.country_generation = transition.country_generation;
            row.opcode = opcode;
            row.domain = static_cast<uint16_t>(templ.domain);
            row.definition_key_hash = templ.definition_key_hash;
            row.source_id = static_cast<uint64_t>(transition.ideology_id + 1);
            row.magnitude_q16 = templ.magnitude_q16;
            row.ordinal = ordinal++;
            row.effective_day = transition.effective_day;
            plan.modifier_rows.push_back(row);
        };
        for (uint32_t i = 0; i < old_count; ++i) {
            const auto &old_row = _catalog.level_modifiers[old_begin + i];
            bool kept = false;
            for (uint32_t j = 0; j < new_count; ++j) {
                const auto &new_row = _catalog.level_modifiers[new_begin + j];
                if (new_row.definition_key_hash == old_row.definition_key_hash && new_row.domain == old_row.domain) { kept = true; break; }
            }
            if (!kept) push(old_row, 2u);
        }
        for (uint32_t j = 0; j < new_count; ++j) {
            const auto &new_row = _catalog.level_modifiers[new_begin + j];
            bool unchanged = false;
            for (uint32_t i = 0; i < old_count; ++i) {
                const auto &old_row = _catalog.level_modifiers[old_begin + i];
                if (old_row.definition_key_hash == new_row.definition_key_hash && old_row.domain == new_row.domain &&
                    old_row.magnitude_q16 == new_row.magnitude_q16) { unchanged = true; break; }
            }
            if (!unchanged) push(new_row, 1u);
        }
    }
    RuntimeDomainIntent intent;
    intent.source_domain = static_cast<uint16_t>(RuntimeDomainId::IDEOLOGY);
    intent.target_domain = static_cast<uint16_t>(RuntimeDomainId::EFFECT);
    intent.opcode = EFFECT_TRANSITION_OPCODE;
    intent.flags = RUNTIME_DOMAIN_INTENT_DEFERRED | RUNTIME_DOMAIN_INTENT_REQUIRES_ACK;
    intent.source_id = transition.intent_id;
    intent.target_handle = (static_cast<uint64_t>(transition.country_generation) << 32u) |
        transition.country_slot;
    intent.target_generation = transition.country_generation;
    intent.effective_day = transition.effective_day;
    intent.payload[0] = transition.ideology_id;
    intent.payload[1] = transition.desired_level;
    intent.payload[2] = static_cast<int64_t>(transition.desired_location);
    intent.payload[3] = static_cast<int64_t>(transition.desired_entered_levels);
    intent.request_id = transition.request_id != 0 ? transition.request_id : transition.intent_id;
    intent.producer_id = transition.producer_id;
    intent.sequence = transition.sequence;
    intent.idempotency_key = transition.intent_id;
    plan.intents.push_back(intent);
    transition.intent_emitted = 1;
}

bool RuntimeIdeologyPodAuthority::begin_transition(
        RuntimeIdeologyPodSnapshot &state, uint32_t slot, int32_t ideology_id,
        int32_t desired_level, RuntimeIdeologyPodLocation desired_location,
        uint8_t desired_slot_index, uint64_t entered_levels,
        const RuntimeIdeologyPodCommand *command, int64_t day,
        RuntimeIdeologyPodPlan &plan, std::string &error) const {
    for (const auto &pending : state.pending_transitions)
        if (pending.country_slot == slot && pending.ideology_id == ideology_id) {
            error = "ideology_transition_pending"; return false;
        }
    if (state.pending_transitions.size() >= RUNTIME_IDEOLOGY_POD_MAX_TRANSITIONS) {
        error = "ideology_transition_capacity_exceeded"; return false;
    }
    if (plan.intents.size() >= _catalog.max_transition_commands) {
        error = "ideology_transition_command_slice_exceeded";
        return false;
    }
    RuntimeIdeologyPodTransition transition;
    transition.request_id = command != nullptr ? command->request_id : 0;
    transition.producer_id = command != nullptr ? command->producer_id : 0;
    transition.sequence = command != nullptr ? command->sequence :
        (static_cast<uint64_t>(day) << 32u) | static_cast<uint32_t>(ideology_id + 1);
    transition.effective_day = day;
    transition.country_slot = slot;
    transition.country_generation = state.countries[slot].generation;
    transition.ideology_id = ideology_id;
    transition.desired_level = desired_level;
    transition.desired_location = desired_location;
    transition.desired_slot_index = desired_slot_index;
    transition.desired_entered_levels = entered_levels;
    transition.previous_entered_levels =
        state.countries[slot].ideas[static_cast<size_t>(ideology_id)]
            .entered_levels;
    compute_synergies(state.countries[slot], ideology_id, desired_level,
                      desired_location, transition.desired_synergy_bits);
    transition.intent_id = transition_identity(transition,
        command != nullptr ? command->opcode : RuntimeIdeologyPodOpcode::ADD_UNDERSTANDING);
    state.pending_transitions.push_back(std::move(transition));
    emit_transition(state, state.pending_transitions.back(), plan);
    return true;
}

uint8_t RuntimeIdeologyPodAuthority::next_free_slot(
        const RuntimeIdeologyPodCountryState &country,
        RuntimeIdeologyPodLocation location, int32_t exclude_ideology_id) const {
    if (location == RuntimeIdeologyPodLocation::INACTIVE) return 0;
    std::array<bool, 64> occupied{};
    for (const RuntimeIdeologyPodIdeaState &idea : country.ideas) {
        if (idea.slot_index >= occupied.size()) continue;
        const int32_t ideology_id = static_cast<int32_t>(
            &idea - country.ideas.data());
        if (ideology_id == exclude_ideology_id ||
                idea.location != location) continue;
        occupied[static_cast<size_t>(idea.slot_index)] = true;
    }
    for (uint8_t slot = 0; slot < static_cast<uint8_t>(occupied.size());
            ++slot)
        if (!occupied[static_cast<size_t>(slot)]) return slot;
    return 63;
}

void RuntimeIdeologyPodAuthority::settle_synergies(
        RuntimeIdeologyPodCountryState &country, uint32_t country_slot,
        int32_t ideology_id, int64_t day, RuntimeIdeologyPodPlan &plan) const {
    // Recompute only the reverse-CSR candidates against the settled state, so
    // two same-day transitions of one school still reach a shared resonance.
    std::vector<uint64_t> next;
    compute_synergies(country, ideology_id,
        country.ideas[static_cast<size_t>(ideology_id)].level,
        country.ideas[static_cast<size_t>(ideology_id)].location, next);
    const uint32_t begin = _catalog.ideology_synergy_offsets[static_cast<size_t>(ideology_id)];
    const uint32_t end = _catalog.ideology_synergy_offsets[static_cast<size_t>(ideology_id + 1)];
    for (uint32_t candidate = begin; candidate < end; ++candidate) {
        const int32_t synergy_id = _catalog.ideology_synergy_ids[candidate];
        const bool was = bit_get(country.synergy_bits, synergy_id);
        const bool now = bit_get(next, synergy_id);
        if (was == now) continue;
        const auto &synergy = _catalog.synergies[static_cast<size_t>(synergy_id)];
        for (uint32_t row_index = 0; row_index < synergy.modifier_count; ++row_index) {
            const auto &templ = _catalog.synergy_modifiers[synergy.modifier_begin + row_index];
            RuntimeIdeologyPodModifierRow row;
            row.transition_id = 0;
            row.country_handle = country.handle;
            row.country_generation = country.generation;
            row.opcode = now ? 1u : 2u;
            row.domain = static_cast<uint16_t>(templ.domain);
            row.definition_key_hash = templ.definition_key_hash;
            row.source_id = (1ull << 32u) | static_cast<uint64_t>(synergy_id + 1);
            row.magnitude_q16 = templ.magnitude_q16;
            row.ordinal = row_index;
            row.effective_day = day;
            plan.modifier_rows.push_back(row);
        }
        bit_set(country.synergy_bits, synergy_id, now);
    }
    (void)country_slot;
}

bool RuntimeIdeologyPodAuthority::apply_ack(
        RuntimeIdeologyPodSnapshot &state, const RuntimeDomainAck &ack,
        int64_t day, RuntimeIdeologyPodPlan &plan, std::string &error) const {
    if (ack.domain != static_cast<uint16_t>(RuntimeDomainId::EFFECT)) return true;
    for (size_t i = 0; i < state.pending_transitions.size(); ++i) {
        auto &transition = state.pending_transitions[i];
        if (ack.transaction_id != transition.intent_id && ack.request_id != transition.intent_id &&
            ack.request_id != transition.request_id) continue;
        if (ack.target_handle != ((static_cast<uint64_t>(transition.country_generation) << 32u) | transition.country_slot) ||
            ack.target_generation != transition.country_generation) {
            error = "ideology_ack_generation_mismatch"; return false;
        }
        if (ack.effective_day != transition.effective_day) {
            error = "ideology_ack_effective_day_mismatch"; return false;
        }
        if (ack.code == RuntimeDomainAckCode::RETRY || ack.code == RuntimeDomainAckCode::STALE_GENERATION) {
            transition.intent_emitted = 0;
            return true;
        }
        auto &country = state.countries[transition.country_slot];
        auto &idea = country.ideas[static_cast<size_t>(transition.ideology_id)];
        RuntimeIdeologyPodReceiptStatus status = RuntimeIdeologyPodReceiptStatus::REJECTED;
        if (ack.code == RuntimeDomainAckCode::OK) {
            const auto previous = idea.location;
            const auto &definition = _catalog.definitions[static_cast<size_t>(transition.ideology_id)];
            if (previous == RuntimeIdeologyPodLocation::IDEOLOGY) country.ideology_slots_used -= definition.ideology_cost;
            if (previous == RuntimeIdeologyPodLocation::NATIONAL_SPIRIT) country.spirit_slots_used -= definition.spirit_cost;
            idea.level = transition.desired_level;
            idea.location = transition.desired_location;
            idea.slot_index = transition.desired_slot_index;
            idea.entered_levels |= transition.desired_entered_levels;
            // X6-b on-enter grants are part of the same ACK-gated transition.
            // Appending here makes a retry/restore idempotent by construction:
            // the pending row is erased only after this successful commit.
            const auto entered = transition.desired_entered_levels &
                ~transition.previous_entered_levels;
            for (int32_t entered_level = 0; entered_level < 64; ++entered_level) {
                if ((entered & (1ull << entered_level)) == 0) continue;
                const uint32_t level_index = definition.level_begin +
                    static_cast<uint32_t>(entered_level);
                if (level_index >= _catalog.levels.size()) continue;
                const uint16_t count =
                    _catalog.levels[level_index].on_enter_free_draws;
                if (count == 0) continue;
                country.free_draws = static_cast<uint16_t>(
                    std::min<uint32_t>(65535u,
                        static_cast<uint32_t>(country.free_draws) + count));
            }
            ++idea.generation;
            if (idea.location == RuntimeIdeologyPodLocation::IDEOLOGY) country.ideology_slots_used += definition.ideology_cost;
            if (idea.location == RuntimeIdeologyPodLocation::NATIONAL_SPIRIT) country.spirit_slots_used += definition.spirit_cost;
            if (country.synergy_bits.size() != (_catalog.synergies.size() + 63u) / 64u)
                country.synergy_bits.assign((_catalog.synergies.size() + 63u) / 64u, 0);
            settle_synergies(country, transition.country_slot, transition.ideology_id, day, plan);
            rebuild_active_idea_ids(country);
            status = RuntimeIdeologyPodReceiptStatus::SETTLED;
        }
        for (auto &receipt : state.receipts) {
            if (receipt.status == RuntimeIdeologyPodReceiptStatus::PENDING &&
                receipt.request_id == transition.request_id &&
                receipt.producer_id == transition.producer_id &&
                receipt.sequence == transition.sequence) {
                receipt.status = status;
                receipt.settled_day = day;
                receipt.reason_code = status == RuntimeIdeologyPodReceiptStatus::SETTLED ? 0u : 1u;
                if (status != RuntimeIdeologyPodReceiptStatus::SETTLED)
                    receipt.reason_text = "effect_transition_rejected";
            }
        }
        state.pending_transitions.erase(state.pending_transitions.begin() + static_cast<std::ptrdiff_t>(i));
        if (state.pending_cursor > i) --state.pending_cursor;
        return true;
    }
    return true;
}
