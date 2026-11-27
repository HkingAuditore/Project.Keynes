Dictionary NativeEconomyRuntime::market_cell_snapshot(int32_t cell_idx) const {
    Dictionary out;
    out["cell_idx"] = cell_idx;
    out["committed"] = !_epoch_active && !_fatal;
    out["busy"] = _epoch_active;
    out["snapshot_source"] = "rolling_committed";
    out["economy_generation"] = static_cast<int64_t>(_committed_generation);
    if (!_bootstrapped || cell_idx < 0 || cell_idx >= _cell_count.get()) {
        out["ok"] = false;
        out["reason"] = !_bootstrapped ? "economy_not_bootstrapped" : "cell_out_of_range";
        return out;
    }
    const int32_t market = market_store().cell_to_market[cell_idx];
    out["ok"] = true;
    out["state_day"] = _cell_last_settlement_day[cell_idx];
    out["age_days"] = std::max<int64_t>(0,
        _current_day.get() - _cell_last_settlement_day[cell_idx]);
    out["settlement_generation"] = static_cast<int64_t>(
        _cell_settlement_generation[cell_idx]);
    out["market_id"] = market;
    out["epoch_id"] = _epoch_id.get();
    PackedStringArray good_ids;
    PackedInt64Array stock;
    PackedInt64Array demand_ema;
    PackedInt64Array business_demand_ema;
    PackedInt64Array colonization_pending_demand, colonization_demand_daily;
    PackedInt64Array military_demand_daily;
    PackedInt64Array derived_business_demand;
    PackedInt64Array desired_business_demand;
    PackedInt64Array funded_business_demand;
    PackedInt64Array unfunded_business_demand;
    PackedInt64Array offered_supply_ema;
    PackedInt64Array realized_withdrawal_ema;
    PackedInt64Array production_input_reserve;
    PackedInt64Array construction_material_reserve;
    PackedInt64Array household_available_stock;
    PackedInt64Array merchant_inventory_target;
    PackedInt64Array merchant_procurement_shortfall;
    PackedInt64Array trade_export_safety_stock;
    PackedInt64Array trade_import_fill_target;
    PackedInt32Array trade_relief_pressure_values_q16;
    PackedInt32Array trade_signal_age_days;
    PackedInt32Array trade_first_dispatch_delay_days;
    PackedInt64Array trade_last_attempt_day;
    PackedInt32Array trade_last_rejection_reason;
    PackedByteArray trade_deadline_exceeded;
    PackedInt32Array cost_anchor_price;
    PackedInt32Array price;
    PackedInt32Array reference_ceiling, base_ceiling, effective_ceiling, target_ceiling, ceiling_days;
    PackedInt32Array shortage_q16;
    PackedInt32Array pressure_excess_q16;
    PackedInt64Array price_inventory_target;
    PackedInt32Array pressure_inventory_q16;
    PackedInt32Array pressure_shortage_q16;
    PackedInt32Array pressure_cost_q16;
    PackedByteArray cost_glut_damped;
    PackedInt32Array pressure_idle_q16;
    PackedInt32Array pressure_total_q16;
    PackedInt32Array price_change_q16;
	PackedByteArray trade_enabled;
	PackedInt32Array transport_load_per_unit_q16;
	PackedInt64Array trade_import_ema;
	PackedInt64Array trade_export_ema;
	PackedInt64Array trade_inbound;
	PackedInt64Array trade_outbound;
	PackedStringArray category_ids;
	PackedInt32Array storage_modes;
	PackedInt64Array monetary_issue_values;
	PackedInt32Array technology_tag_offsets;
	PackedStringArray technology_tags;
	PackedByteArray technology_available;
	technology_tag_offsets.push_back(0);
    int64_t snapshot_saturation = 0;
    int64_t merchant_inventory_retail_value = 0;
    int64_t merchant_inventory_liquidation_value = 0;
    std::vector<int64_t> inbound(static_cast<size_t>(market_store().good_count.get()), 0);
    std::vector<int64_t> outbound(static_cast<size_t>(market_store().good_count.get()), 0);
    int64_t next_arrival = -1;
    int64_t inbound_escrow = 0;
    int64_t outbound_escrow = 0;
    for (int32_t order = 0; order < trade_orders_store().size(); ++order) {
        const bool destination_order = trade_orders_store().destinations[order] == cell_idx;
        const bool source_order = trade_orders_store().sources[order] == cell_idx;
        const bool is_inbound = destination_order &&
            trade_orders_store().cargo_delivered[order] == 0;
        const bool is_outbound = source_order &&
            trade_orders_store().cargo_delivered[order] == 0;
        if (!destination_order && !source_order) continue;
        if ((is_inbound || is_outbound) &&
            (next_arrival < 0 || trade_orders_store().arrival_days[order] < next_arrival))
            next_arrival = trade_orders_store().arrival_days[order];
        if (destination_order) inbound_escrow += trade_orders_store().cash_escrow[order];
        if (source_order) outbound_escrow += trade_orders_store().cash_escrow[order];
        for (int32_t line = trade_orders_store().line_offsets[order];
             line < trade_orders_store().line_offsets[order + 1]; ++line) {
            const int32_t good = trade_orders_store().line_goods[line];
            if (is_inbound) inbound[good] += trade_orders_store().line_quantities[line];
            if (is_outbound) outbound[good] += trade_orders_store().line_quantities[line];
        }
    }
    for (int32_t g = 0; g < market_store().good_count.get(); ++g) {
        colonization_pending_demand.push_back(epoch_colonization_demand(cell_idx, g));
        military_demand_daily.push_back(epoch_military_demand_daily(cell_idx, g));
        colonization_demand_daily.push_back(epoch_colonization_demand_daily(cell_idx, g));
        const int64_t market_index = market_store().index(market, g);
        const int64_t retail_value = mul_div_sat(
            std::max<int64_t>(0, market_store().stock[market_index]),
            std::max<int64_t>(0, market_store().price[market_index]),
            GOODS_SCALE, snapshot_saturation);
        merchant_inventory_retail_value = saturating_add(
            merchant_inventory_retail_value, retail_value,
            snapshot_saturation);
        merchant_inventory_liquidation_value = saturating_add(
            merchant_inventory_liquidation_value,
            mul_div_sat(retail_value, std::clamp<int64_t>(
                _good_merchant_buy_factor_q16[g], 0, Q16_ONE),
                Q16_ONE, snapshot_saturation), snapshot_saturation);
        good_ids.push_back(String(_good_ids[g].c_str()));
        technology_available.push_back(good_available(cell_idx, g, false) ? 1 : 0);
        stock.push_back(market_store().stock[market_store().index(market, g)]);
        price.push_back(market_store().price[market_store().index(market, g)]);
        demand_ema.push_back(market_store().demand_ema[market_store().index(market, g)]);
        shortage_q16.push_back(market_store().last_shortage_q16[market_store().index(market, g)]);
        const int32_t signal = market_signal_index(cell_idx, g);
        business_demand_ema.push_back(signal >= 0 ?
            _market_signals.business_demand_ema[signal] : 0);
        derived_business_demand.push_back(signal >= 0 && signal < static_cast<int32_t>(
                _epoch_derived_business_demand.size())
            ? _epoch_derived_business_demand[signal] : 0);
        const int64_t substitute_business = signal >= 0 && signal < static_cast<int32_t>(
                _epoch_substitute_business_demand.size())
            ? _epoch_substitute_business_demand[signal] : 0;
        // Expose substitute pressure through the derived snapshot field so
        // inspectors/tests that already read derived_business_demand also see
        // same-edge co-candidate demand without a schema bump.
        if (substitute_business > 0) {
            derived_business_demand[derived_business_demand.size() - 1] =
                saturating_add(
                    derived_business_demand[derived_business_demand.size() - 1],
                    substitute_business, snapshot_saturation);
        }
        const int64_t desired_business = signal >= 0 && signal < static_cast<int32_t>(
                _epoch_desired_business_demand.size())
            ? _epoch_desired_business_demand[signal] : 0;
        const int64_t funded_business = signal >= 0 && signal < static_cast<int32_t>(
                _epoch_funded_business_demand.size())
            ? _epoch_funded_business_demand[signal] : 0;
        desired_business_demand.push_back(desired_business);
        funded_business_demand.push_back(funded_business);
        unfunded_business_demand.push_back(std::max<int64_t>(
            0, desired_business - funded_business));
        offered_supply_ema.push_back(signal >= 0 ?
            _market_signals.offered_supply_ema[signal] : 0);
        const int64_t realized = signal >= 0 ?
            _market_signals.realized_withdrawal_ema[signal] : 0;
        realized_withdrawal_ema.push_back(realized);
        const int64_t input_reserve = signal >= 0 && signal <
                static_cast<int32_t>(_production_input_reserve.size())
            ? _production_input_reserve[signal] : 0;
        const int64_t construction_reserve = signal >= 0 && signal <
                static_cast<int32_t>(_construction_material_reserve.size())
            ? _construction_material_reserve[signal] : 0;
        production_input_reserve.push_back(input_reserve);
        construction_material_reserve.push_back(construction_reserve);
        household_available_stock.push_back(std::max<int64_t>(0,
            market_store().stock[market_store().index(market, g)] -
            std::max(input_reserve, construction_reserve)));
        const int32_t flow = const_cast<NativeEconomyRuntime *>(this)->trade_flow_index(
            cell_idx, g, false);
        const int64_t export_ema = flow >= 0 ? _trade_flows.export_ema[flow] : 0;
        const int64_t inventory_target = this->merchant_inventory_target(
            market, g, signal, realized, export_ema,
            signal >= 0 ? _market_signals.offered_supply_ema[signal] : 0,
            snapshot_saturation);
        merchant_inventory_target.push_back(inventory_target);
        merchant_procurement_shortfall.push_back(std::max<int64_t>(
            0, inventory_target - market_store().stock[market_store().index(market, g)]));
        trade_export_safety_stock.push_back(trade_export_floor(
            market, g, snapshot_saturation));
        trade_import_fill_target.push_back(trade_local_stock_target(
            market, g, snapshot_saturation));
        trade_relief_pressure_values_q16.push_back(static_cast<int32_t>(
            this->trade_relief_pressure_q16(market, g, snapshot_saturation)));
        const int32_t signal_clock = trade_signal_clock_index(cell_idx, g);
        const int64_t first_seen = signal_clock >= 0 && signal_clock < static_cast<int32_t>(
                _trade_signal_first_seen_day.size())
            ? _trade_signal_first_seen_day[signal_clock] : -1;
        const int64_t first_dispatch = signal_clock >= 0 && signal_clock < static_cast<int32_t>(
                _trade_signal_first_dispatch_day.size())
            ? _trade_signal_first_dispatch_day[signal_clock] : -1;
        trade_signal_age_days.push_back(first_seen >= 0 ? static_cast<int32_t>(
            std::clamp<int64_t>(_sample_day - first_seen, 0,
                                std::numeric_limits<int32_t>::max())) : 0);
        trade_first_dispatch_delay_days.push_back(
            first_seen >= 0 && first_dispatch >= first_seen
                ? static_cast<int32_t>(std::clamp<int64_t>(
                    first_dispatch - first_seen, 0,
                    std::numeric_limits<int32_t>::max())) : -1);
        trade_last_attempt_day.push_back(signal_clock >= 0 && signal_clock <
                static_cast<int32_t>(_trade_signal_last_attempt_day.size())
            ? _trade_signal_last_attempt_day[signal_clock] : -1);
        trade_last_rejection_reason.push_back(signal_clock >= 0 && signal_clock <
                static_cast<int32_t>(_trade_signal_last_rejection_reason.size())
            ? _trade_signal_last_rejection_reason[signal_clock] :
                TRADE_SIGNAL_DIAG_NONE);
        trade_deadline_exceeded.push_back(first_seen >= 0 && first_dispatch < 0 &&
            _sample_day - first_seen > _trade_response_days.get() ? 1 : 0);
        cost_anchor_price.push_back(signal >= 0 ?
            _market_signals.cost_anchor_price[signal] : 0);
        const PricePressure pressure = price_pressure(
            market, g, market_store().demand_ema[market_store().index(market, g)],
            market_store().stock[market_store().index(market, g)],
            market_store().last_shortage_q16[market_store().index(market, g)], signal,
            snapshot_saturation);
        const int32_t base_limit = base_price_ceiling(_good_reference_max_price[g],
            _good_default_price[g], pressure.adjustment_anchor_price);
        const int32_t target_limit = market_price_ceiling(market, g, pressure.adjustment_anchor_price);
        reference_ceiling.push_back(_good_reference_max_price[g]);
        base_ceiling.push_back(base_limit);
        target_ceiling.push_back(target_limit);
        effective_ceiling.push_back(std::max(target_limit, market_store().price[market_store().index(market, g)]));
        const auto &ceiling_rows = market_store().price_ceilings[market];
        const auto ceiling_it = std::lower_bound(ceiling_rows.begin(), ceiling_rows.end(), g,
            [](const PriceCeilingState &state, int32_t good) { return state.good < good; });
        ceiling_days.push_back(ceiling_it != ceiling_rows.end() && ceiling_it->good == g
            ? ceiling_it->confirmation_days : 0);
        pressure_excess_q16.push_back(static_cast<int32_t>(pressure.excess_q16));
        price_inventory_target.push_back(pressure.inventory_target);
        pressure_inventory_q16.push_back(static_cast<int32_t>(pressure.inventory_q16));
        pressure_shortage_q16.push_back(static_cast<int32_t>(pressure.shortage_q16));
        cost_glut_damped.push_back(pressure.glut_cost_damped ? 1 : 0);
        pressure_cost_q16.push_back(static_cast<int32_t>(pressure.cost_q16));
        pressure_idle_q16.push_back(static_cast<int32_t>(pressure.idle_q16));
        pressure_total_q16.push_back(static_cast<int32_t>(std::clamp<int64_t>(
            pressure.total_q16, std::numeric_limits<int32_t>::min(),
            std::numeric_limits<int32_t>::max())));
        price_change_q16.push_back(static_cast<int32_t>(std::clamp<int64_t>(
            pressure.change_q16, std::numeric_limits<int32_t>::min(),
            std::numeric_limits<int32_t>::max())));
		trade_enabled.push_back(_good_trade_enabled[g]);
		transport_load_per_unit_q16.push_back(_good_transport_load_per_unit_q16[g]);
		trade_import_ema.push_back(flow >= 0 ? _trade_flows.import_ema[flow] : 0);
		trade_export_ema.push_back(flow >= 0 ? _trade_flows.export_ema[flow] : 0);
		trade_inbound.push_back(inbound[g]);
		trade_outbound.push_back(outbound[g]);
		category_ids.push_back(String(_good_category_ids[g].c_str()));
		storage_modes.push_back(_good_storage_modes[g]);
		monetary_issue_values.push_back(_good_monetary_issue_values[g]);
		for (int32_t k = _good_technology_tag_offsets[g];
			 k < _good_technology_tag_offsets[g + 1]; ++k) {
			technology_tags.push_back(String(_good_technology_tags[k].c_str()));
		}
		technology_tag_offsets.push_back(technology_tags.size());
    }
    out["good_ids"] = good_ids;
    out["stock"] = stock;
    out["price"] = price;
    out["price_reference_ceiling"] = reference_ceiling;
    out["price_base_ceiling"] = base_ceiling;
    out["price_effective_ceiling"] = effective_ceiling;
    out["price_target_ceiling"] = target_ceiling;
    out["price_ceiling_confirmation_days"] = ceiling_days;
    out["demand_ema"] = demand_ema;
    out["business_demand_ema"] = business_demand_ema;
    out["colonization_pending_demand"] = colonization_pending_demand;
    out["military_demand_daily"] = military_demand_daily;
    out["colonization_demand_daily"] = colonization_demand_daily;
    out["derived_business_demand"] = derived_business_demand;
    out["desired_business_demand"] = desired_business_demand;
    out["funded_business_demand"] = funded_business_demand;
    out["unfunded_business_demand"] = unfunded_business_demand;
    out["offered_supply_ema"] = offered_supply_ema;
    out["realized_withdrawal_ema"] = realized_withdrawal_ema;
    out["production_input_reserve"] = production_input_reserve;
    out["construction_material_reserve"] = construction_material_reserve;
    out["household_available_stock"] = household_available_stock;
    out["merchant_inventory_target"] = merchant_inventory_target;
    out["merchant_procurement_shortfall"] = merchant_procurement_shortfall;
    out["trade_export_safety_stock"] = trade_export_safety_stock;
    out["trade_import_fill_target"] = trade_import_fill_target;
    out["trade_relief_pressure_q16"] = trade_relief_pressure_values_q16;
    out["trade_signal_age_days"] = trade_signal_age_days;
    out["trade_first_dispatch_delay_days"] = trade_first_dispatch_delay_days;
    out["trade_last_attempt_day"] = trade_last_attempt_day;
    out["trade_last_rejection_reason"] = trade_last_rejection_reason;
    out["trade_deadline_exceeded"] = trade_deadline_exceeded;
    out["cost_anchor_price"] = cost_anchor_price;
    out["shortage_q16"] = shortage_q16;
    out["price_pressure_excess_q16"] = pressure_excess_q16;
    out["price_inventory_target"] = price_inventory_target;
    out["price_pressure_inventory_q16"] = pressure_inventory_q16;
    out["price_pressure_shortage_q16"] = pressure_shortage_q16;
    out["price_pressure_cost_q16"] = pressure_cost_q16;
    out["price_cost_glut_damped"] = cost_glut_damped;
    out["price_numeric_min"] = PRICE_NUMERIC_GUARD_MIN;
    out["price_pressure_idle_q16"] = pressure_idle_q16;
    out["price_pressure_total_q16"] = pressure_total_q16;
    out["price_change_q16"] = price_change_q16;
    out["price_preview_saturation_count"] = snapshot_saturation;
	out["good_category_ids"] = category_ids;
	out["good_storage_modes"] = storage_modes;
	out["good_monetary_issue_values"] = monetary_issue_values;
	out["good_technology_tag_offsets"] = technology_tag_offsets;
	out["good_technology_tags"] = technology_tags;
	out["good_technology_available"] = technology_available;
	out["good_trade_enabled"] = trade_enabled;
	out["good_transport_load_per_unit_q16"] = transport_load_per_unit_q16;
	out["trade_import_ema"] = trade_import_ema;
	out["trade_export_ema"] = trade_export_ema;
	out["trade_inbound"] = trade_inbound;
	out["trade_outbound"] = trade_outbound;
	out["trade_next_arrival_day"] = next_arrival;
	out["trade_inbound_escrow_cash"] = inbound_escrow;
	out["trade_outbound_escrow_cash"] = outbound_escrow;
    PackedInt64Array merchant_handles;
    PackedInt64Array merchant_population;
    PackedInt64Array merchant_funds;
    int64_t merchant_cash = 0;
    // Merchant CSR is rebuilt only after structural commit. Scan this one
    // selected cell so a live query remains valid between structural slices.
    population_store().for_each_in_cell(cell_idx, [&](int32_t slot) {
        if (!is_merchant_slot(slot)) return;
        merchant_handles.push_back(static_cast<int64_t>(population_store().handle_for_slot(slot)));
        merchant_population.push_back(population_store().population[slot]);
        merchant_funds.push_back(population_store().funds[slot]);
        merchant_cash = saturating_add(
            merchant_cash, std::max<int64_t>(0, population_store().funds[slot]),
            snapshot_saturation);
    });
    const int64_t procurement_paid =
        cell_idx < static_cast<int32_t>(_merchant_procurement_paid_by_cell.size())
            ? _merchant_procurement_paid_by_cell[cell_idx] : 0;
    const int64_t procurement_retail =
        cell_idx < static_cast<int32_t>(_merchant_procurement_retail_by_cell.size())
            ? _merchant_procurement_retail_by_cell[cell_idx] : 0;
    const int64_t procurement_factor_weighted_cash =
        cell_idx < static_cast<int32_t>(
            _merchant_procurement_factor_weighted_cash_by_cell.size())
            ? _merchant_procurement_factor_weighted_cash_by_cell[cell_idx] : 0;
    const int64_t trade_purchase =
        cell_idx < static_cast<int32_t>(_merchant_trade_purchase_by_cell.size())
            ? _merchant_trade_purchase_by_cell[cell_idx] : 0;
    const int64_t trade_sale =
        cell_idx < static_cast<int32_t>(_merchant_trade_sale_by_cell.size())
            ? _merchant_trade_sale_by_cell[cell_idx] : 0;
    const int64_t credit_drawn =
        cell_idx < static_cast<int32_t>(_merchant_credit_drawn_by_cell.size())
            ? _merchant_credit_drawn_by_cell[cell_idx] : 0;
    const int64_t operating_outflow = saturating_add(
        saturating_add(procurement_paid, trade_purchase,
            snapshot_saturation), credit_drawn, snapshot_saturation);
    out["merchant_handles"] = merchant_handles;
    out["merchant_population"] = merchant_population;
    out["merchant_funds"] = merchant_funds;
    out["merchant_cash"] = merchant_cash;
    out["merchant_inventory_retail_value"] =
        merchant_inventory_retail_value;
    out["merchant_inventory_liquidation_value"] =
        merchant_inventory_liquidation_value;
    out["merchant_economic_assets"] = saturating_add(
        merchant_cash, merchant_inventory_liquidation_value,
        snapshot_saturation);
    out["merchant_procurement_margin_value"] = std::max<int64_t>(
        0, procurement_retail - procurement_paid);
    out["merchant_trade_purchase_cash"] = trade_purchase;
    out["merchant_trade_sale_cash"] = trade_sale;
    // Split the two components of `merchant_operating_outflow` that were
    // folded in but never published. Without them a per-cell audit can see
    // cash leave but cannot tell spending from construction capital, so a
    // cell that liquidates inventory to fund a post looks identical to a
    // leak. Read-only projections of existing epoch metrics.
    out["merchant_procurement_paid"] = procurement_paid;
    out["merchant_credit_drawn"] = credit_drawn;
    out["merchant_operating_outflow"] = operating_outflow;
    out["merchant_liquidity_coverage_q16"] = operating_outflow > 0
        ? mul_div_sat(merchant_cash, Q16_ONE, operating_outflow,
            snapshot_saturation)
        : Q16_ONE;
    out["merchant_effective_buy_factor_q16"] = procurement_paid > 0
        ? std::clamp<int64_t>(
            procurement_factor_weighted_cash / procurement_paid,
            0, Q16_ONE)
        : Q16_ONE;
    out["merchant_snapshot_saturation_count"] = snapshot_saturation;
    return out;
}


Dictionary NativeEconomyRuntime::cell_satisfaction_attractiveness(
        int32_t cell_idx) const {
    Dictionary out;
    if (!_configured || cell_idx < 0 || cell_idx >= _cell_count.get()) {
        out["ok"] = false;
        out["reason"] = !_configured ? "economy_not_configured"
                                     : "cell_index_invalid";
        return out;
    }
    int64_t population = 0;
    int64_t weighted = 0;
    std::array<int64_t, SAT_DIM_COUNT> dim_weighted{};
    std::array<int64_t, SAT_DIM_COUNT> dim_population{};
    int32_t cohort_count = 0;
    population_store().for_each_in_cell(cell_idx, [&](int32_t slot) {
        const int64_t people = std::max<int64_t>(0, population_store().population[slot]);
        ++cohort_count;
        if (people <= 0) return;
        int64_t diagnostic_sat = 0;
        population = saturating_add(population, people, diagnostic_sat);
        weighted = saturating_add(weighted, saturating_mul(
            population_store().composite_satisfaction[slot], people, diagnostic_sat),
            diagnostic_sat);
        const size_t base = static_cast<size_t>(slot) *
            static_cast<size_t>(SAT_DIM_COUNT);
        const uint8_t mask = satisfaction_applicable_mask(slot);
        for (int32_t dim = 0; dim < SAT_DIM_COUNT; ++dim) {
            if (!(mask & (1U << dim))) continue;
            dim_population[dim] += people;
            dim_weighted[static_cast<size_t>(dim)] = saturating_add(
                dim_weighted[static_cast<size_t>(dim)],
                saturating_mul(population_store().satisfaction_dims[
                    base + static_cast<size_t>(dim)], people, diagnostic_sat),
                diagnostic_sat);
        }
    });
    const int64_t composite_q16 = population > 0
        ? std::clamp<int64_t>(weighted / population, 0, Q16_ONE - 1)
        : Q16_ONE - 1;
    PackedInt32Array dims;
    for (int32_t dim = 0; dim < SAT_DIM_COUNT; ++dim)
        dims.push_back(static_cast<int32_t>(dim_population[dim] > 0
            ? std::clamp<int64_t>(dim_weighted[dim] / dim_population[dim], 0, Q16_ONE - 1)
            : -1));
    out["ok"] = true;
    out["cell_index"] = cell_idx;
    out["population"] = population;
    out["cohort_count"] = cohort_count;
    out["composite_q16"] = static_cast<int32_t>(composite_q16);
    out["dim_values_q16"] = dims;
    out["living_standard_level"] = living_standard_level_for(composite_q16);
    out["social_pressure_level"] = social_pressure_level_for(composite_q16);
    out["published_pressure_level"] = cell_idx < static_cast<int32_t>(
            _cell_social_pressure_level.size())
        ? static_cast<int32_t>(_cell_social_pressure_level[cell_idx]) : 0;
    out["development_q16"] = cell_idx < static_cast<int32_t>(
            _epoch_cell_development_q16.size())
        ? _epoch_cell_development_q16[cell_idx] : 0;
    out["living_cost_per_capita"] = cell_idx < static_cast<int32_t>(
            _cell_living_cost_per_capita.size())
        ? _cell_living_cost_per_capita[cell_idx] : 0;
    return out;
}
