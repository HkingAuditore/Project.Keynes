int32_t RuntimeIdeologyPodAuthority::ideology_capacity_for(
        const RuntimeCountryPodSnapshot &country, uint32_t slot) const {
    int64_t capacity = _catalog.ideology_capacity;
    for (const auto &unlock : _catalog.capacity_unlocks) {
        if (unlock.ideology_delta == 0) continue;
        const size_t index = static_cast<size_t>(slot) * country.technology_words + static_cast<size_t>(unlock.technology_id / 64);
        if (index < country.country_technologies.size() &&
            (country.country_technologies[index] & (1ull << (unlock.technology_id % 64))) != 0)
            capacity += unlock.ideology_delta;
    }
    return static_cast<int32_t>(std::min<int64_t>(capacity, _catalog.ideology_capacity_max));
}

int32_t RuntimeIdeologyPodAuthority::spirit_capacity_for(
        const RuntimeCountryPodSnapshot &country, uint32_t slot) const {
    int64_t capacity = _catalog.spirit_capacity;
    for (const auto &unlock : _catalog.capacity_unlocks) {
        if (unlock.spirit_delta == 0) continue;
        const size_t index = static_cast<size_t>(slot) * country.technology_words + static_cast<size_t>(unlock.technology_id / 64);
        if (index < country.country_technologies.size() &&
            (country.country_technologies[index] & (1ull << (unlock.technology_id % 64))) != 0)
            capacity += unlock.spirit_delta;
    }
    return static_cast<int32_t>(std::min<int64_t>(capacity, _catalog.spirit_capacity_max));
}

int64_t RuntimeIdeologyPodAuthority::offer_cost_for(uint64_t draw_sequence) const {
    return runtime_ideology_offer_cost_q16(_catalog.offer_cost_q16,
        _catalog.offer_cost_growth_percent, _catalog.offer_cost_max_q16, draw_sequence);
}

int64_t RuntimeIdeologyPodAuthority::reroll_cost_for(
        uint64_t draw_sequence, int32_t factor_q16) const {
    // The open offer was paid at draw_sequence - 1; rerolls cost a share of it.
    const int64_t paid = offer_cost_for(draw_sequence == 0 ? 0 : draw_sequence - 1u);
    // Scale the share, never the base draw: a discount card must not turn into
    // a blanket discount on the whole draw economy. ideology_reroll_percent owns
    // the cap so the main thread cannot cap it differently.
    return mul_sat(paid, ideology_reroll_percent(
        _catalog.reroll_cost_percent, factor_q16)) / 100;
}

int32_t RuntimeIdeologyPodAuthority::unlocked_era_for(
        const RuntimeCountryPodSnapshot &country, uint32_t slot) const {
    int32_t reached = 0;
    for (int32_t era = 0;
            era < static_cast<int32_t>(_catalog.era_milestone_technologies.size()); ++era) {
        const int32_t technology = _catalog.era_milestone_technologies[static_cast<size_t>(era)];
        if (technology < 0 || era <= reached) continue;
        const size_t index =
            static_cast<size_t>(slot) * country.technology_words + technology / 64;
        if ((country.country_technologies[index] & (1ull << (technology % 64))) != 0)
            reached = era;
    }
    return reached;
}

bool RuntimeIdeologyPodAuthority::draw_offer(
        RuntimeIdeologyPodSnapshot &state, const RuntimeCountryPodSnapshot &country,
        uint32_t slot, const RuntimeIdeologyOpinionSnapshot &opinion,
        std::string &error) const {
    auto &row = state.countries[slot];
    // Must stay step-for-step identical to NativeIdeologyRuntime::draw_offer.
    row.unlocked_era = unlocked_era_for(country, slot);
    const int32_t decay_floor_bp = ideology_frozen_bp(opinion.era_decay_floor_bp, slot);
    std::vector<IdeologyDrawCandidate> pool;
    std::vector<uint8_t> pool_recent;
    std::vector<IdeologyDrawCandidate> fallback_rows;
    for (int32_t id = 0; id < static_cast<int32_t>(_catalog.definitions.size()); ++id) {
        const RuntimeIdeologyPodDefinition &definition = _catalog.definitions[static_cast<size_t>(id)];
        if (bit_get(row.banned_bits, id) || (definition.acquisition & ACQUIRE_DRAW) == 0 ||
            !requirements_met(state, country, slot, id)) continue;
        const uint8_t recent = definition.era_index >= row.unlocked_era - 1 ? 1u : 0u;
        const int32_t weight = ideology_draw_weight(definition.rarity_weight,
            _catalog.era_decay_bp.data(), _catalog.era_decay_bp.size(),
            row.unlocked_era, definition.era_index, decay_floor_bp);
        IdeologyDrawCandidate candidate;
        candidate.id = id;
        if (!bit_get(row.known_bits, id)) {
            candidate.weight = weight;
            pool.push_back(candidate);
            pool_recent.push_back(recent);
            fallback_rows.push_back(candidate);
        } else if (_catalog.refine_weight_bp > 0) {
            const RuntimeIdeologyPodIdeaState &idea = row.ideas[static_cast<size_t>(id)];
            if (definition.level_count == 0 ||
                idea.level >= static_cast<int32_t>(definition.level_count) - 1) continue;
            candidate.weight = static_cast<int64_t>(definition.rarity_weight) *
                static_cast<int64_t>(_catalog.refine_weight_bp);
            pool.push_back(candidate);
            pool_recent.push_back(recent);
        }
    }
    if (pool.empty()) { error = "ideology_offer_pool_insufficient"; return false; }
    std::vector<IdeologyDrawCandidate> weighted;
    std::vector<uint8_t> weighted_recent;
    weighted.reserve(pool.size());
    weighted_recent.reserve(pool.size());
    for (size_t index = 0; index < pool.size(); ++index) {
        if (pool[index].weight > 0) {
            weighted.push_back(pool[index]);
            weighted_recent.push_back(pool_recent[index]);
        }
    }
    // Late eras only carry a handful of ideas, so once they are all known the
    // decayed pool empties permanently. Fall back to raw rarity weight; the
    // branch is a pure function of `fallback_rows`, so both authorities agree.
    if (weighted.empty()) {
        for (const IdeologyDrawCandidate &candidate : fallback_rows) {
            IdeologyDrawCandidate fallback = candidate;
            fallback.weight = static_cast<int64_t>(
                _catalog.definitions[static_cast<size_t>(candidate.id)].rarity_weight) * 10000;
            weighted.push_back(fallback);
            weighted_recent.push_back(
                _catalog.definitions[static_cast<size_t>(candidate.id)].era_index
                    >= row.unlocked_era - 1 ? 1u : 0u);
        }
    }
    if (weighted.empty()) { error = "ideology_offer_weight_invalid"; return false; }
    // Row count: the frozen bonus, on top of the base, clamped to the array. The
    // main thread reads the same bonus from ModifierRuntime; the host freezes it
    // into `opinion.offer_choice_bonus` so the two never disagree.
    const int32_t bonus = slot < opinion.offer_choice_bonus.size()
        ? std::clamp<int32_t>(opinion.offer_choice_bonus[slot], 0,
            IDEOLOGY_OFFER_CHOICE_CAPACITY - IDEOLOGY_OFFER_CHOICE_BASE) : 0;
    // The catalog's row count is the base; the stat adds on top. `IDEOLOGY_OFFER_
    // CHOICE_BASE` is only the fallback when the catalog omits the field, which
    // `configure()` already resolved into `draw_count`.
    const int32_t base_rows = std::clamp(static_cast<int32_t>(_catalog.draw_count),
        1, IDEOLOGY_OFFER_CHOICE_CAPACITY);
    const int32_t want = std::min(base_rows + bonus,
        static_cast<int32_t>(weighted.size()));
    int32_t drawn_ids[IDEOLOGY_OFFER_CHOICE_CAPACITY] = {-1, -1, -1, -1, -1};
    const int32_t drawn = ideology_weighted_draw_recent_first(weighted,
        weighted_recent, std::clamp(want, 1, IDEOLOGY_OFFER_CHOICE_CAPACITY),
        [&row]() { return next_random(row.rng_state); }, drawn_ids);
    if (drawn <= 0) { error = "ideology_offer_weight_invalid"; return false; }
    const uint32_t generation = std::max<uint32_t>(1, row.offer.generation + 1u);
    row.offer.clear();
    row.offer.active = 1;
    row.offer.generation = generation;
    for (int32_t n = 0; n < drawn; ++n)
        row.offer.ideology_ids[static_cast<size_t>(n)] = drawn_ids[static_cast<size_t>(n)];
    row.offer.choice_count = static_cast<uint8_t>(drawn);
    return true;
}

void RuntimeIdeologyPodAuthority::accrue_points(
        RuntimeIdeologyPodSnapshot &state,
        const RuntimeIdeologyOpinionSnapshot &opinion, int64_t day) const {
    // Wait for the first real row before initializing a new country's baseline.
    const size_t countries = opinion.country_count;
    if (opinion.country_population.size() != countries ||
        opinion.country_buildings_installed.size() != countries ||
        opinion.country_trade_base_value.size() != countries) return;
    const int64_t period = std::max<int64_t>(1, opinion.period_days);
    // R9-2: settle once per COMMITTED DAY, never per publish and never per
    // `period_index`.
    //
    // `period_index` was `commit_day / period_days`, and `period_days` comes from
    // `_epoch_days`, which the workset recalculates. With period 5 day 10 is
    // period 2, and after the epoch widens to 6 day 12 is ALSO period 2, so a
    // genuinely new commit was skipped as "already settled" (and the reverse split
    // one period into two). `commit_day` is monotone and independent of how many
    // times Economy publishes, so it is the only safe key on both sides.
    // `period_index` remains in the snapshot for diagnostics only.
    const uint64_t settle_key = opinion.committed_day >= 0
        ? static_cast<uint64_t>(opinion.committed_day) + 1u
        : opinion.revision;
    for (uint32_t slot = 0; slot < countries; ++slot) {
        auto &row = state.countries[slot];
        if (row.handle == 0 || row.points_revision == settle_key) continue;
        row.points_revision = settle_key;
        const int64_t population = std::max<int64_t>(0, opinion.country_population[slot]);
        const int64_t buildings = std::max<int64_t>(0, opinion.country_buildings_installed[slot]);
        if (row.baseline_ready == 0) {
            // First observation is the baseline; it never pays out.
            row.baseline_population = population;
            row.baseline_buildings = buildings;
            row.baseline_ready = 1;
            // R9-5: seed the trade marker HERE, mirroring the main thread. Left at
            // INT64_MIN, the kernel's first call did the seeding one settlement
            // later, so the whole first period's trade flow was silently dropped.
            if (row.trade_paid_day == INT64_MIN) row.trade_paid_day = day;
            continue;
        }
        // High-water baselines: only new peaks pay, so decline/recovery loops
        // cannot farm points.
        const int64_t population_gain = std::max<int64_t>(0, population - row.baseline_population);
        const int64_t building_gain = std::max<int64_t>(0, buildings - row.baseline_buildings);
        row.baseline_population = std::max(row.baseline_population, population);
        row.baseline_buildings = std::max(row.baseline_buildings, buildings);
        const int64_t trade_per_day = std::max<int64_t>(0, opinion.country_trade_base_value[slot]) / period;
        RuntimeIdeologyPodPointLedger ledger;
        ledger.day = day;
        ledger.population_q16 = ideology_point_term_q16(
            mul_sat(population_gain, _catalog.point_population_weight_q16),
            opinion.point_population_factor_q16, slot);
        ledger.building_q16 = ideology_point_term_q16(
            mul_sat(building_gain, _catalog.point_building_weight_q16),
            opinion.point_building_factor_q16, slot);
        // Trade is a flow: pay for the days that elapsed since this row last
        // paid. Clamping the span to `period` was removed: it broke "total depends
        // only on elapsed days" (1 settlement paid 5000 where 30 settled paid
        // 29000 over the same 30 days). Settling once, thirty times, or a random
        // number of times over the same span now pays the same total.
        //
        // `ledger_span_days` is the same span and feeds the per-day cap (R9-3).
        const int64_t trade_paid_before = row.trade_paid_day;
        const int64_t trade_days_q16 = ideology_trade_flow_q16(
            trade_per_day, day, period, row.trade_paid_day);
        const int64_t ledger_span_days = trade_paid_before == INT64_MIN
            ? 1 : std::max<int64_t>(1, day - trade_paid_before);
        ledger.trade_q16 = ideology_point_term_q16(
            mul_sat(trade_days_q16, _catalog.point_trade_weight_q16) /
                TRADE_MONEY_SCALE,
            opinion.point_trade_factor_q16, slot);
        int64_t total_influence = 0;
        int64_t weighted = 0;
        for (uint32_t class_index = 0; class_index < _catalog.class_count; ++class_index) {
            const size_t lane = static_cast<size_t>(slot) * _catalog.class_count + class_index;
            int64_t influence = std::max<int64_t>(0, opinion.population[lane]);
            influence = add_sat(influence, mul_sat(std::max<int64_t>(0, opinion.owner_employed[lane]), _catalog.owner_influence_weight));
            influence = add_sat(influence, std::max<int64_t>(0, opinion.funds[lane]) / _catalog.funds_per_influence);
            total_influence = add_sat(total_influence, influence);
            weighted = add_sat(weighted, mul_sat(influence, std::clamp<int64_t>(opinion.satisfaction_q16[lane], 0, Q16_ONE)));
        }
        const int64_t satisfaction = total_influence > 0 ? std::clamp<int64_t>(weighted / total_influence, 0, Q16_ONE) : Q16_ONE / 2;
        ledger.opinion_factor_q16 = ideology_opinion_factor_q16(
            satisfaction, opinion.opinion_factor_floor_q16, slot);
        ledger.gain_factor_q16 = slot < opinion.point_gain_factor_q16.size()
            ? std::clamp<int32_t>(opinion.point_gain_factor_q16[slot], 0, 4 * Q16_ONE) : static_cast<int32_t>(Q16_ONE);
        const int64_t raw = add_sat(add_sat(ledger.population_q16, ledger.building_q16), ledger.trade_q16);
        int64_t gain = mul_sat(raw, ledger.opinion_factor_q16) / Q16_ONE;
        gain = mul_sat(gain, ledger.gain_factor_q16) / Q16_ONE;
        // R9-3: the cap is authored PER DAY, so a settlement that covers a span
        // of days must be allowed `cap x span`. Applying the raw per-day cap to
        // the whole settlement made a rare settler (large span) lose to a daily
        // settler: "1 settlement == 30 settlements" held in the kernel and broke
        // here. Mirrors the main thread exactly.
        const int64_t covered_days = std::max<int64_t>(1, ledger_span_days);
        if (_catalog.point_gain_cap_q16 > 0) {
            gain = std::min(gain,
                mul_sat(_catalog.point_gain_cap_q16, covered_days * Q16_ONE) / Q16_ONE);
        }
        ledger.gain_q16 = std::max<int64_t>(0, gain);
        row.ideology_points_q16 = add_sat(row.ideology_points_q16, ledger.gain_q16);
        row.lifetime_points_q16 = add_sat(row.lifetime_points_q16, ledger.gain_q16);
        row.ledger = ledger;
        row.history_q16[row.history_head] = ledger.gain_q16;
        row.history_head = static_cast<uint8_t>((row.history_head + 1u) % RUNTIME_IDEOLOGY_POD_HISTORY);
        if (row.history_count < RUNTIME_IDEOLOGY_POD_HISTORY) ++row.history_count;
    }
}

bool RuntimeIdeologyPodAuthority::apply_command(
        RuntimeIdeologyPodSnapshot &state,
        const RuntimeCountryPodSnapshot &country,
        const RuntimeIdeologyOpinionSnapshot &opinion,
        const RuntimeIdeologyPodCommand &command,
        RuntimeIdeologyPodPlan &plan, std::string &error) const {
    const uint32_t slot = static_cast<uint32_t>(command.country_handle & 0xffffffffull);
    if (slot >= state.countries.size() || state.countries[slot].handle != command.country_handle ||
        state.countries[slot].generation != static_cast<uint32_t>(command.country_handle >> 32u) ||
        country.country_active[slot] == 0) {
        error = "ideology_country_handle_invalid"; return false;
    }
    auto &row = state.countries[slot];
    const int32_t idea_id = command.ideology_id;
    switch (command.opcode) {
        case RuntimeIdeologyPodOpcode::DISCOVER:
            if ((_catalog.definitions[idea_id].acquisition & ACQUIRE_DISCOVER) == 0 ||
                !requirements_met(state, country, slot, idea_id)) { error = "ideology_discovery_not_allowed"; return false; }
            bit_set(row.known_bits, idea_id, true); return true;
        case RuntimeIdeologyPodOpcode::GRANT_POINTS:
            row.ideology_points_q16 = add_sat(row.ideology_points_q16, command.value_q16); return true;
        case RuntimeIdeologyPodOpcode::GRANT_FREE_DRAW:
            row.free_draws = static_cast<uint16_t>(std::min<int64_t>(
                65535, static_cast<int64_t>(row.free_draws) + command.value_q16));
            return true;
        case RuntimeIdeologyPodOpcode::OPEN_OFFER: {
            const int64_t cost = offer_cost_for(row.draw_sequence);
            if (row.offer.active != 0) { error = "ideology_offer_pending"; return false; }
            if (row.free_draws == 0 && row.ideology_points_q16 < cost) {
                error = "ideology_points_insufficient"; return false;
            }
            if (!draw_offer(state, country, slot, opinion, error)) return false;
            if (row.free_draws > 0) --row.free_draws;
            else row.ideology_points_q16 -= cost;
            ++row.draw_sequence; return true;
        }
        case RuntimeIdeologyPodOpcode::REROLL_OFFER: {
            const int64_t cost = reroll_cost_for(row.draw_sequence,
                ideology_frozen_factor(opinion.reroll_cost_q16, slot));
            if (row.offer.active == 0) { error = "ideology_offer_not_active"; return false; }
            if (command.offer_generation != 0 && command.offer_generation != row.offer.generation) { error = "ideology_offer_generation_stale"; return false; }
            if (row.ideology_points_q16 < cost) { error = "ideology_points_insufficient"; return false; }
            if (!draw_offer(state, country, slot, opinion, error)) return false;
            row.ideology_points_q16 -= cost; return true;
        }
        case RuntimeIdeologyPodOpcode::CHOOSE_OFFER: {
            if (row.offer.active == 0 || row.offer.generation != command.offer_generation ||
                command.choice_index < 0 ||
                command.choice_index >= static_cast<int32_t>(row.offer.choice_count)) {
                error = "ideology_offer_generation_stale"; return false;
            }
            const int32_t chosen = row.offer.ideology_ids[static_cast<size_t>(command.choice_index)];
            if (chosen < 0 || bit_get(row.banned_bits, chosen)) { error = "ideology_offer_choice_invalid"; return false; }
            if (bit_get(row.known_bits, chosen)) {
                // 精进: the row only exists because the card is owned and not
                // maxed, so the pick pays understanding and may raise the level.
                auto &idea = row.ideas[static_cast<size_t>(chosen)];
                idea.understanding_q16 = add_sat(idea.understanding_q16,
                    _catalog.refine_understanding_q16);
                const int32_t unlocked = unlocked_level(idea, chosen);
                if (unlocked > idea.level) { idea.level = unlocked; ++idea.generation; }
            } else {
                bit_set(row.known_bits, chosen, true);
            }
            row.offer.clear();
            return true;
        }
        case RuntimeIdeologyPodOpcode::BAN_CARD: {
            if (idea_id < 0 || idea_id >= static_cast<int32_t>(_catalog.definitions.size())) {
                error = "ideology_ideology_invalid"; return false;
            }
            if (bit_get(row.known_bits, idea_id)) { error = "ideology_ban_known"; return false; }
            if (bit_get(row.banned_bits, idea_id)) { error = "ideology_ban_already_banned"; return false; }
            const int64_t ban_cost = offer_cost_for(row.draw_sequence);
            if (row.ideology_points_q16 < ban_cost) { error = "ideology_points_insufficient"; return false; }
            row.ideology_points_q16 -= ban_cost;
            bit_set(row.banned_bits, idea_id, true);
            return true;
        }
        case RuntimeIdeologyPodOpcode::EQUIP: {
            if (!bit_get(row.known_bits, idea_id)) { error = "ideology_unknown"; return false; }
            auto &idea = row.ideas[idea_id];
            if (idea.location == RuntimeIdeologyPodLocation::NATIONAL_SPIRIT) { error = "ideology_is_national_spirit"; return false; }
            if (idea.location == RuntimeIdeologyPodLocation::IDEOLOGY) return true;
            const auto &definition = _catalog.definitions[idea_id];
            for (int32_t other = 0; other < static_cast<int32_t>(row.ideas.size()); ++other)
                if (other != idea_id && row.ideas[other].location != RuntimeIdeologyPodLocation::INACTIVE && definition.exclusion_group_id >= 0 && _catalog.definitions[other].exclusion_group_id == definition.exclusion_group_id) { error = "ideology_exclusion_group_conflict"; return false; }
            if (!support_allows(state, opinion, slot, idea_id, 0)) { error = "ideology_support_threshold_not_met"; return false; }
            if (row.ideology_slots_used + definition.ideology_cost > ideology_capacity_for(country, slot)) { error = "ideology_slot_capacity_exceeded"; return false; }
            const int32_t level = std::max(idea.level, unlocked_level(idea, idea_id));
            const uint64_t entered = level < 0 ? 0 : ((level == 63 ? ~0ull : ((1ull << (level + 1)) - 1ull)) & ~idea.entered_levels);
            return begin_transition(state, slot, idea_id, level,
                RuntimeIdeologyPodLocation::IDEOLOGY,
                next_free_slot(row, RuntimeIdeologyPodLocation::IDEOLOGY,
                    idea_id), entered, &command, command.effective_day, plan,
                error);
        }
        case RuntimeIdeologyPodOpcode::UNEQUIP: {
            auto &idea = row.ideas[idea_id];
            if (idea.location != RuntimeIdeologyPodLocation::IDEOLOGY) { error = "ideology_not_equipped"; return false; }
            if (!support_allows(state, opinion, slot, idea_id, 1)) { error = "ideology_support_threshold_not_met"; return false; }
            return begin_transition(state, slot, idea_id, idea.level,
                RuntimeIdeologyPodLocation::INACTIVE, idea.slot_index, 0,
                &command, command.effective_day, plan, error);
        }
        case RuntimeIdeologyPodOpcode::PROMOTE: {
            auto &idea = row.ideas[idea_id];
            const auto &definition = _catalog.definitions[idea_id];
            if (idea.location != RuntimeIdeologyPodLocation::IDEOLOGY) { error = "ideology_promotion_requires_equipped"; return false; }
            if (idea.level < definition.min_spirit_level) { error = "ideology_national_spirit_level_insufficient"; return false; }
            if (row.spirit_slots_used + definition.spirit_cost > spirit_capacity_for(country, slot)) { error = "national_spirit_slot_capacity_exceeded"; return false; }
            if (!support_allows(state, opinion, slot, idea_id, 2)) { error = "ideology_support_threshold_not_met"; return false; }
            return begin_transition(state, slot, idea_id, idea.level,
                RuntimeIdeologyPodLocation::NATIONAL_SPIRIT,
                next_free_slot(row, RuntimeIdeologyPodLocation::NATIONAL_SPIRIT,
                    idea_id), 0, &command, command.effective_day, plan, error);
        }
        case RuntimeIdeologyPodOpcode::ADD_UNDERSTANDING: {
            if (!bit_get(row.known_bits, idea_id)) { error = "ideology_unknown"; return false; }
            auto &idea = row.ideas[idea_id];
            idea.understanding_q16 = add_sat(idea.understanding_q16, command.value_q16);
            const int32_t unlocked = unlocked_level(idea, idea_id);
            if (idea.location == RuntimeIdeologyPodLocation::INACTIVE) {
                if (unlocked > idea.level) { idea.level = unlocked; ++idea.generation; }
                return true;
            }
            if (unlocked > idea.level) {
                const uint64_t entered = unlocked == 63 ? ~idea.entered_levels : (((1ull << (unlocked + 1)) - 1ull) & ~idea.entered_levels);
                return begin_transition(state, slot, idea_id, unlocked,
                    idea.location, idea.slot_index, entered, &command,
                    command.effective_day, plan, error);
            }
            return true;
        }
        case RuntimeIdeologyPodOpcode::SET_GATE:
            bit_set(row.gate_bits, command.gate_id, command.value_q16 != 0); return true;
    }
    error = "ideology_command_unknown"; return false;
}
