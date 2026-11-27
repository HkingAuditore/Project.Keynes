                                              std::string &error) {
    MarketResult *previous_market_sink = _market_result_sink;
    _market_result_sink = &result;
    struct MarketSinkRestore {
        MarketResult *&sink;
        MarketResult *previous = nullptr;
        ~MarketSinkRestore() { sink = previous; }
    } market_sink_restore{_market_result_sink, previous_market_sink};
    struct NeedState {
        int32_t local_cohort = -1;
        int32_t need_index = -1;
        int64_t desired_units = 0;
        int64_t filled_units = 0;
        int64_t spent_money = 0;
        int64_t living_target_units = 0;
    };
    struct ComponentRef {
        int32_t order = -1;
        int64_t required_qty = 0;
        int64_t qty_per_need = 0;
    };
    thread_local std::vector<int32_t> slots;
    thread_local std::vector<NeedState> need_states;
    thread_local std::vector<BundleOrder> primary_orders;
    thread_local std::vector<BundleOrder> fallback_orders;
    thread_local std::vector<int64_t> cohort_spend;
    thread_local std::vector<int64_t> cohort_base_spend;
    thread_local std::vector<int64_t> cohort_consumption_tax;
    thread_local std::vector<int64_t> cohort_consumption_subsidy;
    thread_local std::vector<int64_t> cohort_desired;
    thread_local std::vector<int64_t> cohort_filled;
    thread_local std::vector<int64_t> cohort_food_required;
    thread_local std::vector<int64_t> cohort_food_filled;
    thread_local std::vector<int64_t> cohort_subsistence_food_filled;
    thread_local std::vector<int64_t> cohort_best_food_q16;
    thread_local std::vector<int64_t> cohort_clothing_required;
    thread_local std::vector<int64_t> cohort_clothing_filled;
    thread_local std::vector<int64_t> cohort_working_capital_reserve;
    thread_local std::vector<int64_t> cohort_wealth_ratio_q16;
    thread_local std::vector<int64_t> cohort_savings_months_q16;
    thread_local std::vector<int64_t> production_input_floor;
    thread_local std::vector<int64_t> good_demand;
    // Physical demand requested by households before budget clipping. This is
    // still the same per-good market shortage signal; it prevents an empty
    // shelf from looking balanced merely because buyers could not afford the
    // order. `good_demand` remains the funded flow used by the demand EMA.
    thread_local std::vector<int64_t> good_desired_demand;
    thread_local std::vector<int64_t> good_sales;
    // Own-shelf shortfall by requested component demand. Budget clipping still
    // controls actual withdrawals and demand_ema, but an empty shelf must not
    // look balanced merely because the household could not fund the order.
    thread_local std::vector<int64_t> good_stock_shortfall;
    thread_local std::vector<int64_t> pass_sales;
    thread_local std::vector<int64_t> pass_demand;
    thread_local std::vector<int64_t> opening_stock;
    thread_local std::vector<int64_t> trace_funds_before;
    thread_local std::vector<int64_t> trace_income_before;
    thread_local std::vector<int64_t> trace_expense_before;
    thread_local std::vector<int64_t> trace_income_ema_before;
    thread_local std::vector<uint16_t> trace_satisfaction_before;
    thread_local std::vector<uint16_t> trace_worst_need_before;
    thread_local std::vector<int32_t> trace_price_before;
    thread_local std::vector<int64_t> trace_demand_ema_before;
    thread_local std::vector<uint16_t> trace_shortage_before;
    thread_local std::vector<int32_t> good_counts;
    thread_local std::vector<int32_t> good_offsets;
    thread_local std::vector<int32_t> good_cursor;
    thread_local std::vector<ComponentRef> component_refs;
    thread_local std::vector<int64_t> variant_score_cache;
    thread_local std::vector<int64_t> variant_price_cache;
    thread_local std::vector<int64_t> need_score_sum_cache;
    thread_local std::vector<int64_t> need_composite_cache;
    thread_local std::vector<int64_t> need_environment_cache;
    thread_local std::vector<int8_t> satisfaction_need_available_cache;
    thread_local std::vector<int64_t> cohort_worst_q16;
    thread_local std::vector<uint16_t> cohort_worst_need;
    // Applicable need-tier reductions, strided by SAT_TIER_COUNT per cohort.
    thread_local std::vector<int64_t> cohort_tier_weighted_q16;
    thread_local std::vector<int64_t> cohort_tier_weight_q16;
    thread_local std::vector<int64_t> cohort_basic_min_fill_q16;
    thread_local std::vector<int64_t> expected_births_q32_by_ethnicity;
    thread_local std::vector<int64_t> cohort_rescale_sat_q16;
    thread_local std::array<int64_t, 3> food_family_filled{};
    thread_local std::array<int64_t, 3> food_family_desired{};
    thread_local std::vector<int32_t> local_by_slot;
    thread_local std::vector<uint32_t> local_by_slot_stamp;
    thread_local uint32_t local_lookup_generation = 0;
    int64_t &sat = result.saturation_count;
    bool population_changed = false;
    if (market < 0 || market >= market_store().market_count.get()) {
        error = "household_market_out_of_range";
        return false;
    }
    if (_market_cell_offsets.size() != static_cast<size_t>(market_store().market_count.get() + 1)) {
        error = "market_cell_range_missing";
        return false;
    }
    const size_t expected_birth_residuals =
        static_cast<size_t>(_cell_count.get()) * _ethnicity_ids.size();
    if (_birth_residual_q32.size() != expected_birth_residuals) {
        error = "birth_residual_shape_mismatch";
        return false;
    }
    slots.clear();
    for (int32_t k = _market_cell_offsets[market]; k < _market_cell_offsets[market + 1]; ++k) {
        const int32_t market_cell = _market_cells[k];
        population_store().for_each_in_cell(market_cell, [&](int32_t slot) { slots.push_back(slot); });
    }
    const int32_t cohort_count = static_cast<int32_t>(slots.size());
    int64_t opening_market_population = 0;
    for (const int32_t slot : slots) {
        opening_market_population = saturating_add(
            opening_market_population, std::max<int64_t>(0, population_store().population[slot]),
            sat);
    }
    thread_local std::vector<int32_t> living_merchants;
    collect_living_merchant_slots(market, living_merchants);
    if (opening_market_population > 0 && living_merchants.empty()) {
        error = "market_revenue_has_no_merchant_owner";
        return false;
    }
    if (local_by_slot.size() < population_store().active.size()) {
        local_by_slot.resize(population_store().active.size(), -1);
        local_by_slot_stamp.resize(population_store().active.size(), 0);
    }
    ++local_lookup_generation;
    if (local_lookup_generation == 0) {
        std::fill(local_by_slot_stamp.begin(), local_by_slot_stamp.end(), 0);
        local_lookup_generation = 1;
    }
    for (int32_t local = 0; local < cohort_count; ++local) {
        const int32_t slot = slots[local];
        local_by_slot[slot] = local;
        local_by_slot_stamp[slot] = local_lookup_generation;
    }
    const bool trace_detail = trace_detail_for_cell(market);
    result.cashflows.clear();
    result.welfare_entries.clear();
    need_states.clear();
    primary_orders.clear();
    fallback_orders.clear();
    cohort_spend.assign(cohort_count, 0);
    cohort_base_spend.assign(cohort_count, 0);
    cohort_consumption_tax.assign(cohort_count, 0);
    cohort_consumption_subsidy.assign(cohort_count, 0);
    cohort_desired.assign(cohort_count, 0);
    cohort_filled.assign(cohort_count, 0);
    cohort_food_required.assign(cohort_count, 0);
    cohort_food_filled.assign(cohort_count, 0);
    cohort_subsistence_food_filled.assign(cohort_count, 0);
    cohort_best_food_q16.assign(cohort_count, 0);
    cohort_clothing_required.assign(cohort_count, 0);
    cohort_clothing_filled.assign(cohort_count, 0);
    cohort_tier_weighted_q16.assign(
        static_cast<size_t>(cohort_count) * SAT_TIER_COUNT, 0);
    cohort_tier_weight_q16.assign(
        static_cast<size_t>(cohort_count) * SAT_TIER_COUNT, 0);
    cohort_basic_min_fill_q16.assign(cohort_count, Q16_ONE - 1);
    expected_births_q32_by_ethnicity.assign(_ethnicity_ids.size(), 0);
    cohort_rescale_sat_q16.assign(cohort_count, Q16_ONE);
    food_family_filled.fill(0);
    food_family_desired.fill(0);
    result.retained_consumed_by_good.assign(market_store().good_count.get(), 0);
    auto food_equivalent = [&](int32_t good, int64_t quantity) -> int64_t {
        if (good < 0 || good >= static_cast<int32_t>(
                _good_food_equivalent_q16.size()) || quantity <= 0) return 0;
        const int64_t coefficient = _good_food_equivalent_q16[
            static_cast<size_t>(good)];
        return coefficient > 0 ? mul_div_sat(quantity, coefficient, Q16_ONE, sat) : 0;
    };
    auto record_food_access = [&](int32_t cell, int64_t food_eq) {
        if (cell < 0 || cell >= _cell_count.get() || food_eq <= 0) return;
        for (MarketResult::FoodAccessEntry &entry : result.food_access_by_cell) {
            if (entry.cell != cell) continue;
            entry.food_eq = saturating_add(entry.food_eq, food_eq, sat);
            return;
        }
        result.food_access_by_cell.push_back({cell, food_eq});
    };
    cohort_working_capital_reserve.assign(cohort_count, 0);
    cohort_wealth_ratio_q16.assign(cohort_count, 0);
    cohort_savings_months_q16.assign(cohort_count, 0);
    production_input_floor.assign(market_store().good_count.get(), 0);
    good_demand.assign(market_store().good_count.get(), 0);
    good_desired_demand.assign(market_store().good_count.get(), 0);
    good_sales.assign(market_store().good_count.get(), 0);
    good_stock_shortfall.assign(market_store().good_count.get(), 0);
    opening_stock.resize(market_store().good_count.get());
    for (int32_t good = 0; good < market_store().good_count.get(); ++good) {
        opening_stock[good] = market_store().stock[market_store().index(market, good)];
    }
    for (int32_t k = _market_cell_offsets[market];
         k < _market_cell_offsets[market + 1]; ++k) {
        const int32_t cell = _market_cells[k];
        if (_market_signals.cell_offsets.size() != static_cast<size_t>(_cell_count.get() + 1))
            continue;
        for (int32_t signal = _market_signals.cell_offsets[cell];
             signal < _market_signals.cell_offsets[cell + 1]; ++signal) {
            if (signal >= static_cast<int32_t>(_production_input_reserve.size())) continue;
            const int32_t good = _market_signals.good_ids[signal];
            production_input_floor[good] = saturating_add(
                production_input_floor[good],
                merchant_protected_reserve(signal), sat);
        }
    }
    if (trace_detail) {
        trace_funds_before.resize(cohort_count);
        trace_income_before.resize(cohort_count);
        trace_expense_before.resize(cohort_count);
        trace_income_ema_before.resize(cohort_count);
        trace_satisfaction_before.resize(cohort_count);
        trace_worst_need_before.resize(cohort_count);
        for (int32_t local = 0; local < cohort_count; ++local) {
            const int32_t slot = slots[local];
            trace_funds_before[local] = population_store().funds[slot];
            trace_income_before[local] = population_store().epoch_income[slot];
            trace_expense_before[local] = population_store().epoch_expense[slot];
            trace_income_ema_before[local] = population_store().income_ema[slot];
            trace_satisfaction_before[local] = population_store().needs_satisfaction[slot];
            trace_worst_need_before[local] = population_store().worst_need_id[slot];
        }
        trace_price_before.resize(market_store().good_count.get());
        trace_demand_ema_before.resize(market_store().good_count.get());
        trace_shortage_before.resize(market_store().good_count.get());
        for (int32_t good = 0; good < market_store().good_count.get(); ++good) {
            const int64_t idx = market_store().index(market, good);
            trace_price_before[good] = market_store().price[idx];
            trace_demand_ema_before[good] = market_store().demand_ema[idx];
            trace_shortage_before[good] = market_store().last_shortage_q16[idx];
        }
    }
    for (int32_t slot : slots) touch_accounting_slot(slot);

    // Household clearing must not consume the physical-input float needed to
    // start the next production period. Output is sold after inputs are bought,
    // so an owner cohort with no protected working capital cannot self-recover.
    for (int32_t k = _market_cell_offsets[market]; k < _market_cell_offsets[market + 1]; ++k) {
        const int32_t cell = _market_cells[k];
        if (_building_cell_offsets.size() != static_cast<size_t>(_cell_count.get() + 1)) continue;
        for (int32_t g = _building_cell_offsets[cell];
             g < _building_cell_offsets[cell + 1]; ++g) {
            const auto group = building_view(static_cast<size_t>(g));
            if (group.count <= 0 || group.operating_state == 1 ||
                !building_available(cell, group.type_id, true)) continue;
            const BuildingType &type = _building_types[group.type_id];
            if (type.input_count <= 0 || group.sample_unit_input_cost <= 0) continue;
            const int32_t owner_slot = find_cohort_slot(cell, group.owner_signature_id);
            if (owner_slot < 0 ||
                owner_slot >= static_cast<int32_t>(local_by_slot_stamp.size()) ||
                local_by_slot_stamp[owner_slot] != local_lookup_generation) continue;
            const int32_t local = local_by_slot[owner_slot];
            const int64_t owner_demand = saturating_mul(
                group.count, type.owner_slots_per_building, sat);
            const int64_t owner_scale_q16 = owner_demand > 0
                ? std::min<int64_t>(Q16_ONE, mul_div_sat(
                    group.filled_owner, Q16_ONE, owner_demand, sat)) : 0;
            const int64_t operation_scale_q16 = std::min<int64_t>(
                owner_scale_q16, std::clamp<int64_t>(
                    group.planned_utilization_q16, 0, Q16_ONE));
            const int64_t full_period_cost = saturating_mul(
                saturating_mul(group.sample_unit_input_cost, group.count, sat),
                std::max(1, _epoch_days.get()), sat);
            const int64_t reserve = mul_div_sat(
                full_period_cost, operation_scale_q16, Q16_ONE, sat);
            cohort_working_capital_reserve[local] = saturating_add(
                cohort_working_capital_reserve[local], reserve, sat);
            result.owner_working_capital_reserved = saturating_add(
                result.owner_working_capital_reserved, reserve, sat);
        }
    }

    const auto formula_start = Clock::now();
    // Price and environment are frozen for the whole market tick. Compile the
    // variant side once per market instead of repeating it for every cohort.
    const EnvironmentSample market_environment = environment_sample_for_cell(market);
    satisfaction_need_available_cache.assign(_needs.size(), -1);
    build_demand_basis_cached(market, market, market_environment,
                       variant_score_cache, variant_price_cache,
                       need_score_sum_cache, need_composite_cache,
                       need_environment_cache, sat);
    compute_cell_living_costs_from_basis(
        market, variant_score_cache, variant_price_cache,
        need_score_sum_cache, need_environment_cache, sat);
    // These two actor-level values are shared by every Need/variant. Keeping
    // them out of the inner loop is the key cost bound for class/good wealth
    // choice; the remaining per-variant work is integer interpolation/multiply.
    for (int32_t local = 0; local < cohort_count; ++local) {
        const int32_t slot = slots[local];
        const int64_t population = std::max<int64_t>(
            1, population_store().population[slot]);
        const int64_t wealth_pc = std::max<int64_t>(
            0, population_store().funds[slot]) / population;
        cohort_wealth_ratio_q16[local] = mul_div_sat(
            wealth_pc, Q16_ONE, _wealth_reference_per_capita, sat);
        const int32_t cell = slot >= 0 &&
                slot / COHORT_PAGE_SIZE < static_cast<int32_t>(population_store().page_cell.size())
            ? population_store().page_cell[slot / COHORT_PAGE_SIZE] : -1;
        const int64_t basic_living_cost = cell >= 0 &&
                cell < static_cast<int32_t>(_cell_living_cost_per_capita.size())
            ? _cell_living_cost_per_capita[cell] : 0;
        cohort_savings_months_q16[local] = basic_living_cost > 0
            ? mul_div_sat(wealth_pc, Q16_ONE,
                saturating_mul(basic_living_cost, 30, sat), sat) : 0;
    }
    // Market-invariant anytime frontier. The exact best-scoring variant is
    // always retained, then lower-ranked variants are added until the omitted
    // preference mass is within the configured certificate. Survival families
    // remain exact. PROBE builds the same frontier but does not apply it.
    std::vector<uint8_t> &approximation_variant_active =
        result.approximation_variant_active;
    bool approximation_policy_enabled =
        _accuracy_preset != 0 && _approximation_runtime_mode != 0 &&
        _approximation_cooldown_epochs_left == 0;
    if (approximation_policy_enabled &&
        _approximation_runtime_mode == 1) {
        uint64_t market_probe_hash = 1469598103934665603ULL;
        market_probe_hash = trace_hash_mix(
            market_probe_hash, static_cast<uint64_t>(_seed.get()));
        market_probe_hash = trace_hash_mix(
            market_probe_hash, static_cast<uint64_t>(_current_day.get()));
        market_probe_hash = trace_hash_mix(
            market_probe_hash, static_cast<uint32_t>(market));
        approximation_policy_enabled =
            static_cast<int32_t>(market_probe_hash & 0xffffULL) <
                _accuracy_exact_probe_rate_q16;
    }
    const bool approximation_apply =
        approximation_policy_enabled && _approximation_runtime_mode == 2;
    bool approximation_market_probe_failed = false;
    if (approximation_policy_enabled) {
        if (approximation_variant_active.size() != _variants.size()) {
            error = "approximation_worker_scratch_size_mismatch";
            return false;
        }
        std::fill(approximation_variant_active.begin(),
                  approximation_variant_active.end(), uint8_t{1});
        for (const Need &need : _needs) {
            const bool survival_need =
                (need.stable_id >= 0 &&
                 need.stable_id < static_cast<int32_t>(
                     _survival_food_need_mask.size()) &&
                 _survival_food_need_mask[need.stable_id] != 0) ||
                need.stable_id == _survival_clothing_need_stable_id;
            if (survival_need ||
                need.variant_count <= _accuracy_candidate_top_k) continue;
            uint64_t probe_hash = 1469598103934665603ULL;
            probe_hash = trace_hash_mix(
                probe_hash, static_cast<uint64_t>(_seed.get()));
            probe_hash = trace_hash_mix(
                probe_hash, static_cast<uint64_t>(_current_day.get()));
            probe_hash = trace_hash_mix(
                probe_hash, static_cast<uint32_t>(market));
            probe_hash = trace_hash_mix(
                probe_hash, static_cast<uint32_t>(need.stable_id));
            const bool exact_probe = _approximation_runtime_mode == 1 ||
                static_cast<int32_t>(probe_hash & 0xffffULL) <
                    _accuracy_exact_probe_rate_q16;
            if (exact_probe) ++result.approximation_exact_probes;
            ++result.approximation_decisions;
            result.approximation_frontier_candidates += need.variant_count;
            std::array<int32_t, MAX_VARIANTS_PER_NEED>
                approximation_variant_order{};
            const int32_t variant_count = std::min<int32_t>(
                need.variant_count, MAX_VARIANTS_PER_NEED);
            // Catalog ABI caps a need at eight variants. Stable insertion sort
            // avoids a heap-backed general sort in the market hot loop.
            for (int32_t candidate = 0; candidate < variant_count; ++candidate) {
                int32_t insert_at = candidate;
                const int64_t candidate_score =
                    variant_score_cache[need.variant_begin + candidate];
                while (insert_at > 0) {
                    const int32_t previous =
                        approximation_variant_order[insert_at - 1];
                    const int64_t previous_score =
                        variant_score_cache[need.variant_begin + previous];
                    if (previous_score >= candidate_score) break;
                    approximation_variant_order[insert_at] = previous;
                    --insert_at;
                }
                approximation_variant_order[insert_at] = candidate;
            }
            int64_t selected_score = 0;
            const int32_t initial_count = std::min(
                variant_count, _accuracy_candidate_top_k);
            for (int32_t rank = 0; rank < variant_count; ++rank) {
                approximation_variant_active[
                    need.variant_begin + approximation_variant_order[rank]] = 0;
            }
            for (int32_t rank = 0; rank < initial_count; ++rank) {
                const int32_t variant_id =
                    need.variant_begin + approximation_variant_order[rank];
                approximation_variant_active[variant_id] = 1;
                selected_score = saturating_add(
                    selected_score, std::max<int64_t>(
                        0, variant_score_cache[variant_id]), sat);
            }
            // Temperature widens the feasible near-best region; it does not
            // introduce RNG into authoritative choice or remove the optimum.
            const int64_t best_score = std::max<int64_t>(0,
                variant_score_cache[need.variant_begin +
                    approximation_variant_order[0]]);
            int32_t selected_count = initial_count;
            while (selected_count < variant_count) {
                const int32_t variant_id = need.variant_begin +
                    approximation_variant_order[selected_count];
                const int64_t score = std::max<int64_t>(
                    0, variant_score_cache[variant_id]);
                if (mul_div_sat(best_score,
                        Q16_ONE - _accuracy_choice_temperature_q16,
                        Q16_ONE, sat) > score) break;
                approximation_variant_active[variant_id] = 1;
                selected_score = saturating_add(
                    selected_score, score, sat);
                ++selected_count;
            }
            const int64_t total_score = std::max<int64_t>(
                0, need_score_sum_cache[&need - _needs.data()]);
            const int64_t allowed_omitted = mul_div_sat(
                total_score, _accuracy_household_tail_share_q16,
                Q16_ONE, sat);
            while (selected_count < variant_count &&
                   total_score - selected_score > allowed_omitted) {
                const int32_t variant_id = need.variant_begin +
                    approximation_variant_order[selected_count++];
                approximation_variant_active[variant_id] = 1;
                selected_score = saturating_add(
                    selected_score, std::max<int64_t>(
                        0, variant_score_cache[variant_id]), sat);
            }
            const bool certificate_valid =
                selected_count > 0 && selected_score > 0 &&
                total_score - selected_score <= allowed_omitted;
            if (!certificate_valid) {
                ++result.approximation_certificate_failures;
                ++result.approximation_exact_fallbacks;
                for (int32_t v = 0; v < variant_count; ++v)
                    approximation_variant_active[need.variant_begin + v] = 1;
                selected_count = variant_count;
                selected_score = total_score;
            }
            if (total_score > 0) {
                result.approximation_max_certified_regret_q16 = std::max(
                    result.approximation_max_certified_regret_q16,
                    mul_div_sat(std::max<int64_t>(
                        0, total_score - selected_score),
                        Q16_ONE, total_score, sat));
            }
            result.approximation_frontier_pruned +=
                variant_count - selected_count;

            if (exact_probe && certificate_valid &&
                selected_count < variant_count) {
                int64_t exact_price = 0;
                int64_t approximate_price = 0;
                for (int32_t rank = 0; rank < variant_count; ++rank) {
                    const int32_t variant_id = need.variant_begin +
                        approximation_variant_order[rank];
                    const int64_t score = std::max<int64_t>(
                        0, variant_score_cache[variant_id]);
                    const int64_t price = std::max<int64_t>(
                        0, variant_price_cache[variant_id]);
                    exact_price = saturating_add(exact_price, mul_div_sat(
                        price, score, std::max<int64_t>(1, total_score), sat),
                        sat);
                    if (rank < selected_count) {
                        approximate_price = saturating_add(
                            approximate_price, mul_div_sat(
                                price, score,
                                std::max<int64_t>(1, selected_score), sat),
                            sat);
                    }
                }
                const auto relative_error_q16 =
                    [&](int64_t actual, int64_t expected) -> int64_t {
                        const int64_t delta = actual >= expected
                            ? actual - expected : expected - actual;
                        return mul_div_sat(delta, Q16_ONE,
                            std::max<int64_t>(1, expected), sat);
                    };
                const int64_t spend_error_q16 =
                    relative_error_q16(approximate_price, exact_price);
                // With a frozen cohort budget, expected demand is inverse to
                // bundle price. Comparing the reciprocal cancels the budget.
                const int64_t demand_error_q16 = relative_error_q16(
                    exact_price, approximate_price);
                result.approximation_probe_max_spend_error_q16 = std::max(
                    result.approximation_probe_max_spend_error_q16,
                    spend_error_q16);
                result.approximation_probe_max_demand_error_q16 = std::max(
                    result.approximation_probe_max_demand_error_q16,
                    demand_error_q16);
                if (spend_error_q16 > _accuracy_max_regret_q16 ||
                    demand_error_q16 > _accuracy_max_regret_q16) {
                    ++result.approximation_probe_violations;
                    ++result.approximation_exact_fallbacks;
                    approximation_market_probe_failed = true;
                }
            }
        }
        if (approximation_market_probe_failed)
            std::fill(approximation_variant_active.begin(),
                      approximation_variant_active.end(), uint8_t{1});
    }
