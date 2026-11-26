    if (population_changed) result.population_changed_cells.push_back(birth_cell);
    for (int32_t ethnicity = 0; ethnicity <
            static_cast<int32_t>(expected_births_q32_by_ethnicity.size()); ++ethnicity) {
        const int64_t expected_q32 = expected_births_q32_by_ethnicity[ethnicity];
        if (expected_q32 <= 0) continue;
        const size_t residual_lane = static_cast<size_t>(birth_cell) *
            _ethnicity_ids.size() + static_cast<size_t>(ethnicity);
        const int64_t accumulated_q32 = saturating_add(
            _birth_residual_q32[residual_lane], expected_q32, sat);
        const int64_t births = accumulated_q32 / Q32_ONE;
        _birth_residual_q32.write_scalar(residual_lane, accumulated_q32 % Q32_ONE, market_mutation_sink());
        if (births <= 0) continue;
        const int32_t unemployed_signature = unemployed_signature_for_ethnicity(ethnicity);
        if (unemployed_signature < 0) {
            error = "birth_unemployed_signature_missing";
            return false;
        }
        result.births = saturating_add(result.births, births, sat);
        if (birth_cell >= 0 && birth_cell < _cell_count.get() &&
            birth_cell < static_cast<int32_t>(_cell_births.size()))
            _cell_births[static_cast<size_t>(birth_cell)] =
                saturating_add(_cell_births[static_cast<size_t>(birth_cell)],
                    births, sat);
        result.structural_commands.push_back({
            STRUCTURAL_BIRTH, -1, birth_cell, unemployed_signature,
            births, 0, _epoch_id.get()});
    }
    result.merchant_settle_ms += elapsed_ms(merchant_start);

    // Sparse ceiling attribution is exceptional-path work near the numeric
    // guard only; ordinary prices skip it (no authored economic cap).
    bool observe_ceiling = !market_store().price_ceilings[market].empty();
    for (int32_t good = 0; good < market_store().good_count.get() && !observe_ceiling; ++good)
        observe_ceiling = int64_t(market_store().price[market_store().index(market, good)]) * 5 >=
                          int64_t(PRICE_NUMERIC_GUARD_MAX) * 4;
    thread_local std::vector<int64_t> ceiling_requested, ceiling_unfilled, primary_unfilled;
    if (observe_ceiling) {
        ceiling_requested.assign(market_store().good_count.get(), 0);
        ceiling_unfilled.assign(market_store().good_count.get(), 0);
        primary_unfilled.assign(need_states.size(), 0);
        result.price_ceiling_observations.reserve(market_store().good_count.get());
        for (const auto &order : primary_orders)
            primary_unfilled[order.need_index] = saturating_add(primary_unfilled[order.need_index],
                std::max<int64_t>(0, order.funded_units - order.filled_units), sat);
        for (const auto &order : primary_orders) {
            const auto &need = need_states[order.need_index];
            const int64_t unresolved = std::min(primary_unfilled[order.need_index],
                std::max<int64_t>(0, need.desired_units - need.filled_units));
            const int64_t missing_units = mul_div_sat(unresolved,
                std::max<int64_t>(0, order.funded_units - order.filled_units),
                std::max<int64_t>(1, primary_unfilled[order.need_index]), sat);
            const auto &variant = _variants[order.variant_index];
            for (int32_t c = 0; c < variant.component_count; ++c) {
                const auto &component = _components[variant.component_begin + c];
                const int64_t missing = mul_div_sat(missing_units,
                    component_quantity(order.slot, component), GOODS_SCALE, sat);
                const int64_t delivered = mul_div_sat(order.filled_units,
                    component_quantity(order.slot, component), GOODS_SCALE, sat);
                ceiling_requested[component.good_id] = saturating_add(ceiling_requested[component.good_id],
                    saturating_add(missing, delivered, sat), sat);
                ceiling_unfilled[component.good_id] = saturating_add(ceiling_unfilled[component.good_id], missing, sat);
            }
        }
        for (const auto &order : fallback_orders) {
            const auto &variant = _variants[order.variant_index];
            for (int32_t c = 0; c < variant.component_count; ++c) {
                const auto &component = _components[variant.component_begin + c];
                const int64_t delivered = mul_div_sat(order.filled_units,
                    component_quantity(order.slot, component), GOODS_SCALE, sat);
                ceiling_requested[component.good_id] = saturating_add(ceiling_requested[component.good_id], delivered, sat);
            }
        }
    }
    size_t ceiling_cursor = 0;
    const auto price_start = Clock::now();
    for (int32_t good = 0; good < market_store().good_count.get(); ++good) {
        const int64_t idx = market_store().index(market, good);
        const int64_t old_ema = market_store().demand_ema[idx];
        const int32_t signal_index = market_signal_index(market, good);
        // Price is formed from one total-demand stream.  Household demand is
        // already in good_demand; desired business demand includes operating
        // inputs and prospective investment inputs recorded this epoch.  Keep
        // it in the same units before applying the EMA so upstream demand is
        // not lost when the household component is small or zero.
        const int64_t business_desired = signal_index >= 0 &&
                signal_index < static_cast<int32_t>(_epoch_desired_business_demand.size())
            ? std::max<int64_t>(0, _epoch_desired_business_demand[signal_index]) : 0;
        const int64_t total_demand = saturating_add(
            std::max<int64_t>(0, good_demand[good]), business_desired, sat);
        const int64_t daily_demand = total_demand / std::max(1, _epoch_days.get());
        const int64_t alpha = std::min<int64_t>(Q16_ONE,
            static_cast<int64_t>(std::clamp<int32_t>(
                _good_demand_ema_alpha_q16[good], 0, Q16_ONE)) * _epoch_days.get());
        const int64_t ema = saturating_add(
            mul_div_sat(old_ema, Q16_ONE - alpha, Q16_ONE, sat),
            mul_div_sat(daily_demand, alpha, Q16_ONE, sat), sat);
        market_store().demand_ema.write_scalar(idx, ema, market_mutation_sink());
        if (signal_index >= 0) {
            const int64_t nonhousehold = signal_index < static_cast<int32_t>(
                    _epoch_nonhousehold_withdrawals.size())
                ? _epoch_nonhousehold_withdrawals[signal_index] : 0;
            const int64_t observed_daily = saturating_add(
                saturating_add(good_sales[good], nonhousehold, sat),
                result.retained_consumed_by_good[good], sat) /
                std::max(1, _epoch_days.get());
            const int64_t old_withdrawal =
                _market_signals.realized_withdrawal_ema[signal_index];
            _market_signals.realized_withdrawal_ema.write_scalar(signal_index, saturating_add(
                mul_div_sat(old_withdrawal, Q16_ONE - alpha, Q16_ONE, sat),
                mul_div_sat(observed_daily, alpha, Q16_ONE, sat), sat), market_mutation_sink());
        }
        const int64_t desired_total = saturating_add(
            std::max<int64_t>(0, good_desired_demand[good]), business_desired, sat);
        const int64_t shortage_demand = desired_total > 0
            ? desired_total : total_demand;
        const int64_t shortage = shortage_demand <= 0 ? 0 : std::clamp<int64_t>(
            mul_div_sat(good_stock_shortfall[good], Q16_ONE, shortage_demand, sat),
            0, Q16_ONE);
        market_store().last_shortage_q16.write_scalar(idx, static_cast<uint16_t>(
            std::min<int64_t>(Q16_ONE - 1, shortage)), market_mutation_sink());
        const PricePressure pressure = price_pressure(
            market, good, ema, market_store().stock[idx], shortage, signal_index, sat);
        if (pressure.glut_cost_damped) ++result.price_glut_cost_damp_hits;
        if (pressure.cost_q16 != 0) ++result.price_cost_anchor_hits;
        if (pressure.idle_q16 != 0) ++result.price_inactive_reversions;
        bool rate_clamped = false;
        bool rise_damped = false;
        bool minimum_tick = false, headroom_tick = false;
        const int64_t current_price = market_store().price[idx];
        const int64_t next_price = next_price_v6(good, current_price, pressure,
            _epoch_days.get(), sat, rate_clamped, rise_damped, &minimum_tick);
        bool headroom_damped = false;
        bool catalog_bound = false;
        const int32_t base_ceiling = base_price_ceiling(_good_reference_max_price[good],
            _good_default_price[good], pressure.adjustment_anchor_price);
        const auto &ceiling_rows = market_store().price_ceilings[market];
        while (ceiling_cursor < ceiling_rows.size() && ceiling_rows[ceiling_cursor].good < good) ++ceiling_cursor;
        const bool has_ceiling = ceiling_cursor < ceiling_rows.size() && ceiling_rows[ceiling_cursor].good == good;
        const int32_t ceiling = has_ceiling ? std::max(base_ceiling, ceiling_rows[ceiling_cursor].limit) : base_ceiling;
        const int64_t bounded = shape_price(ceiling, current_price, next_price, sat,
            &headroom_damped, &catalog_bound, &headroom_tick);
        if (next_price > current_price && bounded == current_price) ++result.price_ceiling_blocked_rises;
        if (observe_ceiling && (has_ceiling || current_price * 5 >= int64_t(base_ceiling) * 4)) {
            int64_t requested = ceiling_requested[good], unfilled = ceiling_unfilled[good];
            if (signal_index >= 0 && signal_index < static_cast<int32_t>(_epoch_ceiling_business_requested.size())) {
                requested = saturating_add(requested, _epoch_ceiling_business_requested[signal_index], sat);
                unfilled = saturating_add(unfilled, _epoch_ceiling_business_unfilled[signal_index], sat);
            }
            result.price_ceiling_observations.push_back({market, good, static_cast<int32_t>(current_price),
                base_ceiling, static_cast<int32_t>(std::min<int64_t>(_epoch_days.get(), _sample_day + 1)),
                requested, unfilled});
        }
        if (next_price > PRICE_NUMERIC_GUARD_MAX)
            ++result.price_numeric_ceiling_hits;
        if (bounded == PRICE_NUMERIC_GUARD_MIN) ++result.price_numeric_floor_hits;
        if (bounded != current_price && (minimum_tick || headroom_tick))
            ++result.price_min_tick_hits;
        if (rate_clamped) ++result.price_rate_clamp_hits;
        if (rise_damped) ++result.price_rise_fade_hits;
        if (headroom_damped) ++result.price_headroom_damp_hits;
        if (catalog_bound) ++result.price_catalog_bound_hits;
        if (rate_clamped || rise_damped || headroom_damped || catalog_bound) {
            ++result.price_cap_hits;
        }
        if (market_store().price[idx] != bounded) ++result.changed_prices;
        market_store().price.write_scalar(idx, static_cast<int32_t>(bounded), market_mutation_sink());
        const int32_t flow_index = trade_flow_index(market, good, false);
        if (_good_trade_enabled[good] != 0 && _good_storage_modes[good] == 0 &&
            (market_store().stock[idx] > 0 || ema > 0 || shortage > 0 || signal_index >= 0 ||
             flow_index >= 0)) {
            result.trade_active_goods.push_back(good);
        }
    }
    // Every produced good follows the same local chain and remains in stock
    // until household use, merchant purchase, or producer support settles it.
    // There is no cycle-flow discard sink in the unified economy rule.
    result.mutation_hash = trace_hash_mix(result.mutation_hash,
                                          static_cast<uint64_t>(result.revenue));
    result.mutation_hash = trace_hash_mix(result.mutation_hash,
                                          static_cast<uint64_t>(result.consumed_goods));
    result.mutation_hash = trace_hash_mix(result.mutation_hash,
                                          static_cast<uint64_t>(result.changed_prices));
    result.mutation_hash = trace_hash_mix(result.mutation_hash,
                                          static_cast<uint64_t>(result.price_cap_hits));
    // BEGIN army personnel lane (contract §1.3): guest consumption.
    // Runs after the resident clearing (so the merchant revenue, prices and
    // cohort satisfaction of this market are final) and inside the same market
    // settlement, using the soldier plan's non-state-supplied needs only.
    // Every lane belongs to exactly one cell and therefore to exactly one
    // market, so no two market tasks ever touch the same lane.
    run_army_personnel_consumption(market, result);
    // END army personnel lane
    if (trace_detail) {
        // 价格更新已结束；旧价格向量与当前市场价在整个归因范围内都不再修改。
        // 资金变化仍由各 actor 单独计算，两个价格基础分别只计算一次。
        LivingCostMemoScope attribution_memo(*this, false, false, true);
        const EnvironmentSample attribution_environment = environment_sample_for_cell(market);
        for (int32_t local = 0; local < cohort_count; ++local) {
            const int32_t slot = slots[local];
            CohortWelfareEntry &entry = result.welfare_entries[local];
            std::vector<int64_t> previous;
            std::vector<int64_t> wealth_only;
            std::vector<int64_t> current;
            compute_cohort_demand_preview(slot, market, attribution_environment,
                &trace_price_before, trace_funds_before[local], previous, sat);
            compute_cohort_demand_preview(slot, market, attribution_environment,
                &trace_price_before, population_store().funds[slot], wealth_only, sat);
            compute_cohort_demand_preview(slot, market, attribution_environment,
                nullptr, population_store().funds[slot], current, sat);
            entry.previous_demand_per_capita_daily = previous;
            entry.wealth_demand_delta_per_capita_daily.resize(market_store().good_count.get(), 0);
            entry.price_demand_delta_per_capita_daily.resize(market_store().good_count.get(), 0);
            for (int32_t good = 0; good < market_store().good_count.get(); ++good) {
                entry.wealth_demand_delta_per_capita_daily[good] =
                    wealth_only[good] - previous[good];
                entry.price_demand_delta_per_capita_daily[good] =
                    current[good] - wealth_only[good];
            }
        }
        auto add_leg = [&](int32_t field, int32_t subject_kind, int64_t subject_id,
                           int32_t key_id, int64_t before, int64_t after) {
            if (before != after) result.trace_legs.push_back(
                {field, subject_kind, subject_id, key_id, before, after});
        };
        for (int32_t local = 0; local < cohort_count; ++local) {
            const int32_t slot = slots[local];
            const int64_t handle = static_cast<int64_t>(population_store().handle_for_slot(slot));
            add_leg(FIELD_COHORT_FUNDS, SUBJECT_COHORT, handle, -1,
                    trace_funds_before[local], population_store().funds[slot]);
            add_leg(FIELD_COHORT_EPOCH_INCOME, SUBJECT_COHORT, handle, -1,
                    trace_income_before[local], population_store().epoch_income[slot]);
            add_leg(FIELD_COHORT_EPOCH_EXPENSE, SUBJECT_COHORT, handle, -1,
                    trace_expense_before[local], population_store().epoch_expense[slot]);
            add_leg(FIELD_COHORT_INCOME_EMA, SUBJECT_COHORT, handle, -1,
                    trace_income_ema_before[local], population_store().income_ema[slot]);
            add_leg(FIELD_COHORT_SATISFACTION, SUBJECT_COHORT, handle, -1,
                    trace_satisfaction_before[local], population_store().needs_satisfaction[slot]);
            add_leg(FIELD_COHORT_WORST_NEED, SUBJECT_COHORT, handle, -1,
                    trace_worst_need_before[local], population_store().worst_need_id[slot]);
        }
        for (int32_t good = 0; good < market_store().good_count.get(); ++good) {
            const int64_t idx = market_store().index(market, good);
            add_leg(FIELD_MARKET_STOCK, SUBJECT_MARKET, market, good,
                    opening_stock[good], market_store().stock[idx]);
            add_leg(FIELD_MARKET_PRICE, SUBJECT_MARKET, market, good,
                    trace_price_before[good], market_store().price[idx]);
            add_leg(FIELD_MARKET_DEMAND_EMA, SUBJECT_MARKET, market, good,
                    trace_demand_ema_before[good], market_store().demand_ema[idx]);
            add_leg(FIELD_MARKET_SHORTAGE, SUBJECT_MARKET, market, good,
                    trace_shortage_before[good], market_store().last_shortage_q16[idx]);
        }
    }
    result.price_ms += elapsed_ms(price_start);
    result.processed_cohorts += cohort_count;
    result.processed_rules += result.processed_components;
    finalize_market_result(market, result);
    return true;
