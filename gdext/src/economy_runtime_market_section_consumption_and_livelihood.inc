    cohort_filled.assign(cohort_count, 0);
    if (trace_detail) {
        result.welfare_entries.resize(cohort_count);
        for (int32_t local = 0; local < cohort_count; ++local) {
            result.welfare_entries[local].cohort_handle =
                population_store().handle_for_slot(slots[local]);
        }
    }
    // Military v1: stamp the ration-need states with the per-cell military
    // ration satisfaction before any need is reduced, so the survival /
    // basic dimension ratios, the food-required ledger and the notable-person
    // attribution all read the same supplied quantity.
    if (has_state_supplied_needs) {
        for (NeedState &state : need_states) {
            const int32_t local = state.local_cohort;
            if (state.filled_units > 0 ||
                cohort_has_ration_needs[static_cast<size_t>(local)] == 0)
                continue;
            const int32_t stable_need = _needs[state.need_index].stable_id;
            if (!profession_need_is_state_supplied(
                    _signatures[population_store().signature_id[
                        slots[local]]].profession_id, stable_need)) continue;
            const int32_t cell = population_store().page_cell[
                slots[local] / COHORT_PAGE_SIZE];
            const int64_t ration_q16 = std::clamp<int64_t>(
                military_ration_satisfaction_q16(cell), 0, Q16_ONE);
            state.filled_units = std::max<int64_t>(0, mul_div_sat(
                state.living_target_units, ration_q16, Q16_ONE, sat));
        }
    }
    for (const NeedState &state : need_states) {
        const int32_t local = state.local_cohort;
        cohort_filled[local] = saturating_add(cohort_filled[local], state.filled_units, sat);
        const int32_t stable_need = _needs[state.need_index].stable_id;
        if (stable_need >= 0 &&
            static_cast<size_t>(stable_need) < _need_carrying_family.size()) {
            const int32_t family = _need_carrying_family[static_cast<size_t>(stable_need)];
            if (family >= 0 && family < 3) {
                food_family_filled[static_cast<size_t>(family)] = saturating_add(
                    food_family_filled[static_cast<size_t>(family)],
                    state.filled_units, sat);
                food_family_desired[static_cast<size_t>(family)] = saturating_add(
                    food_family_desired[static_cast<size_t>(family)],
                    state.desired_units, sat);
            }
        }
        if (stable_need >= 0 &&
            stable_need < static_cast<int32_t>(
                _survival_food_need_mask.size()) &&
            _survival_food_need_mask[stable_need] != 0) {
            cohort_food_filled[local] = saturating_add(
                cohort_food_filled[local], state.filled_units, sat);
        } else if (stable_need == _survival_clothing_need_stable_id) {
            cohort_clothing_filled[local] = saturating_add(
                cohort_clothing_filled[local], state.filled_units, sat);
        }
        const int64_t satisfaction = state.desired_units <= 0
            ? 0
            : std::clamp<int64_t>(mul_div_sat(state.filled_units, Q16_ONE,
                                              state.desired_units, sat), 0, Q16_ONE - 1);
        if (stable_need >= 0 &&
            stable_need < static_cast<int32_t>(_survival_food_need_mask.size()) &&
            _survival_food_need_mask[stable_need] != 0) {
            // Any complete food sub-basket is caloric evidence. Protein is not
            // a decorative luxury: a fully satisfied fish/meat basket keeps a
            // cohort alive even when the preferred staple basket is empty.
            cohort_best_food_q16[local] = std::max(
                cohort_best_food_q16[local], satisfaction);
        }
        const Need &need = _needs[state.need_index];
        const int64_t living_satisfaction = state.living_target_units > 0
            ? std::clamp<int64_t>(mul_div_sat(state.filled_units, Q16_ONE,
                state.living_target_units, sat), 0, Q16_ONE - 1) : 0;
        const int64_t tier_weight = need.satisfaction_weight_q16;
        if (tier_weight > 0 && state.living_target_units > 0) {
            const size_t tier_index = static_cast<size_t>(local) * SAT_TIER_COUNT +
                static_cast<size_t>(need.satisfaction_tier);
            cohort_tier_weighted_q16[tier_index] = saturating_add(
                cohort_tier_weighted_q16[tier_index],
                saturating_mul(living_satisfaction, tier_weight, sat), sat);
            cohort_tier_weight_q16[tier_index] = saturating_add(
                cohort_tier_weight_q16[tier_index], tier_weight, sat);
            if (need.satisfaction_tier == SAT_DIM_BASIC)
                cohort_basic_min_fill_q16[local] = std::min(
                    cohort_basic_min_fill_q16[local], living_satisfaction);
        }
        if (trace_detail) {
            CohortWelfareEntry &entry = result.welfare_entries[local];
            entry.need_ids.push_back(stable_need);
            entry.need_satisfaction_q16.push_back(static_cast<int32_t>(living_satisfaction));
            entry.need_weight_q16.push_back(state.living_target_units > 0 ? static_cast<int32_t>(tier_weight) : 0);
            entry.need_tiers.push_back(static_cast<int32_t>(need.satisfaction_tier));
        }
        if (satisfaction < cohort_worst_q16[local]) {
            cohort_worst_q16[local] = satisfaction;
            cohort_worst_need[local] = static_cast<uint16_t>(_needs[state.need_index].stable_id);
        }
    }
    // Sparse post-settlement attribution. Important people do not submit
    // orders; they inherit the cohort's realized need satisfaction and receive
    // a deterministic share of the actual buyer outflow.
    if (_person_runtime_mode.get() == 2 &&
        _person_cohort_offsets.size() == population_store().active.size() + 1) {
        thread_local std::vector<int32_t> local_persons;
        thread_local std::vector<int64_t> person_weights;
        for (int32_t local = 0; local < cohort_count; ++local) {
            const int32_t slot = slots[local];
            const int32_t begin_person = _person_cohort_offsets[slot];
            const int32_t end_person = _person_cohort_offsets[slot + 1];
            if (begin_person >= end_person) continue;
            local_persons.clear();
            for (int32_t p = begin_person; p < end_person; ++p) {
                const int32_t person = _person_cohort_indices[p];
                if (persons_store().active[person] == 0) continue;
                local_persons.push_back(person);
                result.person_attributions.push_back({
                    persons_store().handle_for_index(person), 0, 0,
                    static_cast<uint16_t>(cohort_worst_q16[local]),
                    cohort_worst_need[local]});
            }
            const size_t attr_begin = result.person_attributions.size() -
                local_persons.size();
            for (const NeedState &state : need_states) {
                if (state.local_cohort != local) continue;
                const int32_t stable_need = _needs[state.need_index].stable_id;
                const int64_t satisfaction = state.desired_units <= 0
                    ? Q16_ONE - 1
                    : std::clamp<int64_t>(mul_div_sat(state.filled_units,
                        Q16_ONE, state.desired_units, sat), 0, Q16_ONE - 1);
                person_weights.assign(local_persons.size(), 0);
                int64_t notable_weight = 0;
                for (size_t pi = 0; pi < local_persons.size(); ++pi) {
                    const int32_t person = local_persons[pi];
                    const int64_t funds = person < static_cast<int32_t>(
                            _person_opening_cash_claim.size())
                        ? _person_opening_cash_claim[person]
                        : persons_store().cash_claim[person];
                    int64_t desired = desired_need_units_for_actor(
                        slot, state.need_index, _epoch_days.get(),
                        need_environment_cache[state.need_index],
                        need_composite_cache[state.need_index], 1, funds, sat);
                    const int64_t cohort_population = std::max<int64_t>(
                        1, population_store().population[slot]);
                    const int64_t survival_share = std::max<int64_t>(0,
                        survival_required_units(slot, stable_need, _epoch_days.get(),
                            market_environment, sat) / cohort_population);
                    desired = std::max(desired, survival_share);
                    person_weights[pi] = desired;
                    notable_weight = saturating_add(notable_weight, desired, sat);
                }
                const int64_t denominator = std::max<int64_t>(
                    state.desired_units, notable_weight);
                int64_t prefix_weight = 0, distributed_spend = 0;
                for (size_t pi = 0; pi < local_persons.size(); ++pi) {
                    prefix_weight = saturating_add(prefix_weight,
                        person_weights[pi], sat);
                    const int64_t next_spend = denominator > 0
                        ? mul_div_sat(state.spent_money, prefix_weight,
                            denominator, sat) : 0;
                    const int64_t share = std::max<int64_t>(0,
                        next_spend - distributed_spend);
                    distributed_spend = next_spend;
                    const int32_t person = local_persons[pi];
                    result.person_needs.push_back({
                        persons_store().handle_for_index(person), stable_need,
                        person_weights[pi], static_cast<uint16_t>(satisfaction),
                        share});
                    result.person_attributions[attr_begin + pi].consumption_expense =
                        saturating_add(result.person_attributions[
                            attr_begin + pi].consumption_expense, share, sat);
                }
            }
            const int64_t cohort_outflow = std::max<int64_t>(
                1, cohort_spend[local]);
            int64_t expense_prefix = 0, distributed_tax = 0;
            for (size_t pi = 0; pi < local_persons.size(); ++pi) {
                PersonMarketAttribution &attribution =
                    result.person_attributions[attr_begin + pi];
                expense_prefix = saturating_add(expense_prefix,
                    attribution.consumption_expense, sat);
                const int64_t next_tax = mul_div_sat(
                    cohort_consumption_tax[local], expense_prefix,
                    cohort_outflow, sat);
                attribution.consumption_tax = std::max<int64_t>(
                    0, next_tax - distributed_tax);
                distributed_tax = next_tax;
            }
        }
    }
    int64_t remaining_market_population = 0;
    for (int32_t slot : slots) remaining_market_population = saturating_add(
        remaining_market_population, std::max<int64_t>(0, population_store().population[slot]), sat);
    int64_t sat_cell_num = 0;
    int64_t sat_cell_den = 0;
    for (int32_t local = 0; local < cohort_count; ++local) {
        const int32_t slot = slots[local];
        cohort_food_filled[local] = saturating_add(
            cohort_food_filled[local], cohort_subsistence_food_filled[local], sat);
        const int64_t balanced_food_q16 = cohort_food_required[local] <= 0 ? Q16_ONE - 1
            : std::clamp<int64_t>(mul_div_sat(
                cohort_food_filled[local], Q16_ONE, cohort_food_required[local], sat),
                0, Q16_ONE - 1);
        // The three food needs are preference/price sub-baskets, not mutually
        // exclusive starvation gates. A complete protein or produce basket is
        // sufficient evidence of calories, just like a complete staple basket.
        const int64_t food_q16 = std::max(
            balanced_food_q16, cohort_best_food_q16[local]);
        const int64_t clothing_q16 = cohort_clothing_required[local] <= 0 ? Q16_ONE - 1
            : std::clamp<int64_t>(mul_div_sat(
                cohort_clothing_filled[local], Q16_ONE,
                cohort_clothing_required[local], sat), 0, Q16_ONE - 1);
        const int32_t cell = population_store().page_cell[slot / COHORT_PAGE_SIZE];
        const int64_t temperature_q16 = cell >= 0 && cell < _cell_count.get()
            ? _environment_temperature_q16[cell] : Q16_ONE / 2;
        const int64_t snow_q16 = cell >= 0 && cell < _cell_count.get()
            ? _environment_snow_q16[cell] : 0;
        const int64_t temperature_exposure_q16 = std::clamp<int64_t>(
            (Q16_ONE / 2 - temperature_q16) * 2, 0, Q16_ONE);
        const int64_t cold_exposure_q16 = std::max<int64_t>(
            temperature_exposure_q16, std::clamp<int64_t>(snow_q16, 0, Q16_ONE));
        const int64_t clothing_deficit_q16 = Q16_ONE - clothing_q16;
        const int64_t cold_clothing_ceiling_q16 = Q16_ONE - mul_div_sat(
            cold_exposure_q16, clothing_deficit_q16, Q16_ONE, sat);
        const int64_t survival_q16 = std::min(food_q16, cold_clothing_ceiling_q16);
        population_store().needs_satisfaction.write_scalar(slot, static_cast<uint16_t>(survival_q16), market_mutation_sink());
        population_store().worst_need_id.write_scalar(slot, cohort_worst_need[local], market_mutation_sink());
        const int64_t net_income = saturating_sub(population_store().epoch_income[slot],
                                                  population_store().epoch_expense[slot], sat);
        const int64_t daily_net_income = net_income / std::max(1, _epoch_days.get());
        const int64_t income_alpha_q16 = std::min<int64_t>(
            Q16_ONE, static_cast<int64_t>(_epoch_days.get()) * (Q16_ONE / 8));
        population_store().income_ema.write_scalar(slot, saturating_add(
            mul_div_sat(population_store().income_ema[slot], Q16_ONE - income_alpha_q16,
                        Q16_ONE, sat),
            mul_div_sat(daily_net_income, income_alpha_q16, Q16_ONE, sat), sat), market_mutation_sink());
        const int64_t baseline_alpha_q16 = std::min<int64_t>(
            Q16_ONE, static_cast<int64_t>(_epoch_days.get()) *
                _satisfaction_income_baseline_alpha_q16);
        population_store().income_baseline_ema.write_scalar(slot, saturating_add(
            mul_div_sat(population_store().income_baseline_ema[slot],
                        Q16_ONE - baseline_alpha_q16, Q16_ONE, sat),
            mul_div_sat(daily_net_income, baseline_alpha_q16, Q16_ONE, sat), sat), market_mutation_sink());

        const uint32_t signature_id = population_store().signature_id[slot];
        const Signature &signature = _signatures[signature_id];
        const int64_t composite_q16 = update_cohort_satisfaction(
            slot, cell, survival_q16, signature,
            &cohort_tier_weighted_q16[static_cast<size_t>(local) * SAT_TIER_COUNT],
            &cohort_tier_weight_q16[static_cast<size_t>(local) * SAT_TIER_COUNT],
            cohort_basic_min_fill_q16[local],
            sat);
        if (trace_detail && local < static_cast<int32_t>(
                result.welfare_entries.size())) {
            CohortWelfareEntry &entry = result.welfare_entries[local];
            entry.overall_satisfaction_q16 = static_cast<int32_t>(composite_q16);
            entry.living_standard_level = consumption_living_standard_level(slot);
            entry.worst_dimension_id = population_store().worst_dimension_id[slot] ==
                    std::numeric_limits<uint8_t>::max()
                ? -1 : static_cast<int32_t>(population_store().worst_dimension_id[slot]);
            const size_t dims_base = static_cast<size_t>(slot) *
                static_cast<size_t>(SAT_DIM_COUNT);
            for (int32_t dim = 0; dim < SAT_DIM_COUNT; ++dim)
                entry.satisfaction_dims_q16[static_cast<size_t>(dim)] =
                    population_store().satisfaction_dims[dims_base +
                                                  static_cast<size_t>(dim)];
        }
        int64_t rescale_q16 = std::clamp<int64_t>(
            mul_div_sat(composite_q16, Q16_ONE,
                        std::max(1, _satisfaction_birth_reference_q16), sat),
            _carrying_sat_floor_q16, std::min<int64_t>(Q16_ONE, _carrying_sat_cap_q16));
        // Above the reference, fertility rises linearly to the cap at the
        // bonus reference instead of continuing the steeper sub-reference slope.
        if (_carrying_sat_cap_q16 > Q16_ONE &&
                composite_q16 > _satisfaction_birth_reference_q16) {
            const int64_t span = std::max<int64_t>(1,
                _satisfaction_birth_bonus_reference_q16 -
                _satisfaction_birth_reference_q16);
            const int64_t t_q16 = std::clamp<int64_t>(mul_div_sat(
                composite_q16 - _satisfaction_birth_reference_q16, Q16_ONE,
                span, sat), 0, Q16_ONE);
            rescale_q16 = saturating_add(Q16_ONE, mul_div_sat(
                _carrying_sat_cap_q16 - Q16_ONE, t_q16, Q16_ONE, sat), sat);
        }
        cohort_rescale_sat_q16[static_cast<size_t>(local)] = rescale_q16;
        int32_t class_weight = Q16_ONE;
        if (signature.profession_id >= 0 &&
            signature.profession_id < static_cast<int32_t>(
                _profession_class_index.size())) {
            const int32_t class_index =
                _profession_class_index[static_cast<size_t>(signature.profession_id)];
            if (class_index >= 0 && class_index < static_cast<int32_t>(
                    _carrying_class_weight_q16.size())) {
                class_weight = std::max(1,
                    _carrying_class_weight_q16[static_cast<size_t>(class_index)]);
            }
        }
        const int64_t pop = std::max<int64_t>(0, population_store().population[slot]);
        sat_cell_num = saturating_add(sat_cell_num, saturating_mul(
            saturating_mul(pop, class_weight, sat), rescale_q16, sat), sat);
        sat_cell_den = saturating_add(sat_cell_den,
            saturating_mul(pop, class_weight, sat), sat);
    }
    const int32_t birth_cell = _market_cell_offsets[market] <
            _market_cell_offsets[market + 1]
        ? _market_cells[_market_cell_offsets[market]] : market;
    const int64_t sat_cell_q16 = sat_cell_den > 0
        ? std::clamp<int64_t>(mul_div_sat(sat_cell_num, 1, sat_cell_den, sat),
                              _carrying_sat_floor_q16, _carrying_sat_cap_q16)
        : Q16_ONE;
    int64_t k_geo = 0;
    const int64_t k_eff = food_flow_capacity_for_cell(
        birth_cell, k_geo, sat);
    const bool food_flow_valid = birth_cell >= 0 && birth_cell < _cell_count.get() &&
        static_cast<size_t>(birth_cell) < _cell_food_flow_valid.size() &&
        _cell_food_flow_valid[static_cast<size_t>(birth_cell)] != 0;
    if (birth_cell >= 0 && static_cast<size_t>(birth_cell) < _cell_carrying_k_geo.size()) {
        _cell_carrying_k_geo[static_cast<size_t>(birth_cell)] = k_geo;
        _cell_carrying_k_eff[static_cast<size_t>(birth_cell)] = k_eff;
        _cell_carrying_sat_q16[static_cast<size_t>(birth_cell)] =
            static_cast<int32_t>(sat_cell_q16);
    }
    const int64_t load_q16 = food_flow_valid ? mul_div_sat(
        remaining_market_population, Q16_ONE, std::max<int64_t>(1, k_eff), sat) : 0;
    for (int32_t local = 0; local < cohort_count; ++local) {
        const int32_t slot = slots[local];
        const uint32_t signature_id = population_store().signature_id[slot];
        const Signature &signature = _signatures[signature_id];
        const int32_t cell = population_store().page_cell[slot / COHORT_PAGE_SIZE];
        const int64_t survival_q16 = population_store().needs_satisfaction[slot];
        int64_t base_death_rate_q32 = std::max<int64_t>(0, signature.death_rate_q32);
        const int32_t death_country = cell >= 0 && cell < static_cast<int32_t>(
                _epoch_cell_country.size()) ? _epoch_cell_country[cell] : -1;
        if (death_country >= 0 && death_country < static_cast<int32_t>(
                _epoch_country_death_factor_q16.size()))
            base_death_rate_q32 = mul_div_sat(base_death_rate_q32,
                _epoch_country_death_factor_q16[death_country], Q16_ONE, sat);
        if (signature.ethnicity_id >= 0 && signature.ethnicity_id <
                static_cast<int32_t>(expected_births_q32_by_ethnicity.size())) {
            int64_t fertility_land_q16 = Q16_ONE;
            int64_t rescale_q16 = cohort_rescale_sat_q16[static_cast<size_t>(local)];
            if (load_q16 > _carrying_soft_start_q16) {
                const int64_t replacement_q16 = std::clamp<int64_t>(
                    mul_div_sat(base_death_rate_q32,
                                Q16_ONE,
                                std::max<int64_t>(1, signature.birth_rate_q32), sat),
                    0, Q16_ONE);
                const int64_t span = std::max<int64_t>(
                    1, Q16_ONE - _carrying_soft_start_q16);
                const int64_t t_q16 = std::clamp<int64_t>(
                    mul_div_sat(load_q16 - _carrying_soft_start_q16, Q16_ONE,
                                span, sat), 0, Q16_ONE);
                fertility_land_q16 = saturating_add(Q16_ONE, mul_div_sat(
                    t_q16, replacement_q16 - Q16_ONE, Q16_ONE, sat), sat);
                if (rescale_q16 > Q16_ONE)
                    rescale_q16 = saturating_add(Q16_ONE, mul_div_sat(
                        rescale_q16 - Q16_ONE, Q16_ONE - t_q16, Q16_ONE, sat), sat);
            }
            int64_t effective_birth_rate_q32 = mul_div_sat(
                mul_div_sat(std::max<int64_t>(0, signature.birth_rate_q32),
                            fertility_land_q16, Q16_ONE, sat),
                rescale_q16, Q16_ONE, sat);
            if (cell >= 0 && cell < static_cast<int32_t>(
                    _epoch_cell_birth_factor_q16.size())) {
                effective_birth_rate_q32 = mul_div_sat(
                    effective_birth_rate_q32,
                    _epoch_cell_birth_factor_q16[cell], Q16_ONE, sat);
            }
            const int32_t birth_country = cell >= 0 && cell < static_cast<int32_t>(
                    _epoch_cell_country.size())
                ? _epoch_cell_country[static_cast<size_t>(cell)] : -1;
            if (birth_country >= 0 && birth_country < static_cast<int32_t>(
                    _epoch_country_population.size())) {
                constexpr int64_t SMALL_COUNTRY_FULL_BONUS_POPULATION = 40;
                constexpr int64_t SMALL_COUNTRY_NO_BONUS_POPULATION = 200;
                const int64_t country_population = _epoch_country_population[
                    static_cast<size_t>(birth_country)];
                if (country_population < SMALL_COUNTRY_NO_BONUS_POPULATION) {
                    const int64_t span = SMALL_COUNTRY_NO_BONUS_POPULATION -
                        SMALL_COUNTRY_FULL_BONUS_POPULATION;
                    const int64_t t_q16 = std::clamp<int64_t>(mul_div_sat(
                        std::max<int64_t>(0, country_population -
                            SMALL_COUNTRY_FULL_BONUS_POPULATION),
                        Q16_ONE, span, sat), 0, Q16_ONE);
                    const int64_t bonus_q16 = saturating_add(
                        Q16_ONE, mul_div_sat(Q16_ONE / 2,
                            Q16_ONE - t_q16, Q16_ONE, sat), sat);
                    const int64_t load_fade_q16 = load_q16 <= _carrying_soft_start_q16
                        ? Q16_ONE
                        : Q16_ONE - std::clamp<int64_t>(mul_div_sat(
                            load_q16 - _carrying_soft_start_q16, Q16_ONE,
                            std::max<int64_t>(1, Q16_ONE - _carrying_soft_start_q16),
                            sat), 0, Q16_ONE);
                    const int64_t effective_bonus_q16 = saturating_add(
                        Q16_ONE, mul_div_sat(bonus_q16 - Q16_ONE,
                            load_fade_q16, Q16_ONE, sat), sat);
                    effective_birth_rate_q32 = mul_div_sat(
                        effective_birth_rate_q32, effective_bonus_q16, Q16_ONE, sat);
                }
            }
            if (_family_cohort_offsets.size() == population_store().active.size() + 1 &&
                !_family_birth_factor_q16.empty()) {
                const int64_t cohort_population = std::max<int64_t>(1,
                    population_store().population[slot]);
                int64_t weighted = saturating_mul(cohort_population, Q16_ONE, sat);
                for (int32_t p = _family_cohort_offsets[slot];
                     p < _family_cohort_offsets[slot + 1]; ++p) {
                    const FamilyMembershipEdge &edge = family_memberships()[
                        _family_cohort_edge_indices[p]];
                    if (edge.people <= 0 || edge.family_handle == 0) continue;
                    int32_t family = -1;
                    if (!families_store().valid_handle(edge.family_handle, family) ||
                        family < 0 || family >= static_cast<int32_t>(
                            _family_birth_factor_q16.size()))
                        continue;
                    const int32_t factor = _family_birth_factor_q16[
                        static_cast<size_t>(family)];
                    if (factor == Q16_ONE) continue;
                    weighted = saturating_add(weighted,
                        saturating_mul(edge.people,
                            static_cast<int64_t>(factor) - Q16_ONE, sat), sat);
                }
                const int64_t mix = mul_div_sat(weighted, 1, cohort_population, sat);
                effective_birth_rate_q32 = mul_div_sat(
                    effective_birth_rate_q32, mix, Q16_ONE, sat);
            }
            const int64_t expected_births_q32 = saturating_mul(
                saturating_mul(std::max<int64_t>(0, population_store().population[slot]),
                               effective_birth_rate_q32, sat),
                std::max(1, _epoch_days.get()), sat);
            expected_births_q32_by_ethnicity[signature.ethnicity_id] = saturating_add(
                expected_births_q32_by_ethnicity[signature.ethnicity_id],
                expected_births_q32, sat);
        }
        // Invariant: starvation mortality reads SAT_DIM_SUBSISTENCE and nothing
        // else. Dying of hunger is a physiological fact, so a heavy tax burden,
        // an empty purse, or a backward settlement must never kill anyone here.
        const int64_t survival_deficit = std::max<int64_t>(
            0, _starvation_satisfaction_threshold_q16 - survival_q16);
        const int64_t starvation_rate_q32 = mul_div_sat(
            _starvation_death_rate_q32, survival_deficit,
            _starvation_satisfaction_threshold_q16, sat);
        const int64_t effective_death_rate_q32 = saturating_add(
            base_death_rate_q32, starvation_rate_q32, sat);
        int64_t death_numerator_q32 = saturating_add(
            population_store().demography_residual[slot], saturating_mul(
                saturating_mul(std::max<int64_t>(0, population_store().population[slot]),
                               effective_death_rate_q32, sat),
                std::max(1, _epoch_days.get()), sat), sat);
        int64_t deaths = death_numerator_q32 / Q32_ONE;
        const int64_t population_before = std::max<int64_t>(0, population_store().population[slot]);
        const int64_t market_survivor_floor = remaining_market_population <= population_before ? 1 : 0;
        deaths = std::clamp<int64_t>(deaths, 0,
            std::max<int64_t>(0, population_before - market_survivor_floor));
        population_store().demography_residual.write_scalar(slot, deaths >= population_before
            ? 0 : death_numerator_q32 % Q32_ONE, market_mutation_sink());
        if (deaths > 0) {
            // Cohorts that may hold family members are attributed on the
            // main thread at merge; the worker only reads the frozen CSR.
            const bool family_slot = _family_runtime_mode.get() == 2 &&
                !family_memberships().empty() &&
                (_family_csr_edge_count != family_memberships().size() ||
                 static_cast<size_t>(slot) + 1 >= _family_cohort_offsets.size() ||
                 _family_cohort_offsets[slot] < _family_cohort_offsets[slot + 1]);
            if (family_slot)
                result.family_demography.push_back({
                    population_store().handle_for_slot(slot), population_before, deaths});
            else if (_person_runtime_mode.get() == 2 &&
                _person_cohort_offsets.size() == population_store().active.size() + 1 &&
                _person_cohort_offsets[slot] < _person_cohort_offsets[slot + 1])
                result.person_demography.push_back({
                    population_store().handle_for_slot(slot), population_before, deaths});
            population_store().population.write_scalar(slot, population_store().population[slot] - (deaths), market_mutation_sink());
            population_changed = true;
            remaining_market_population -= deaths;
            result.deaths = saturating_add(result.deaths, deaths, sat);
            if (birth_cell >= 0 && birth_cell < _cell_count.get() &&
                birth_cell < static_cast<int32_t>(_cell_deaths.size()))
                _cell_deaths[static_cast<size_t>(birth_cell)] =
                    saturating_add(_cell_deaths[static_cast<size_t>(birth_cell)],
                        deaths, sat);
            if (population_store().population[slot] == 0) {
                result.structural_commands.push_back({
                    0, slot, cell, static_cast<int32_t>(signature_id), 0, 0, _epoch_id.get()});
            }
        }
    }
