    update_cell_labor_signals(cell);
    const auto signal_started = Clock::now();
    thread_local std::vector<int64_t> business_observed;
    thread_local std::vector<int64_t> supply_observed;
    thread_local std::vector<int64_t> anchor_weighted;
    thread_local std::vector<int64_t> anchor_quantity;
    business_observed.assign(cell_signal_count, 0);
    supply_observed.assign(cell_signal_count, 0);
    anchor_weighted.assign(cell_signal_count, 0);
    anchor_quantity.assign(cell_signal_count, 0);
    for (size_t i = 0; i < cell_signal_count; ++i) {
        business_observed[i] = maintenance_observed[i];
    }
    for (int32_t g = begin; g < end; ++g) {
        const auto group = building_view(static_cast<size_t>(g));
        if (group.cell != cell || group.count <= 0 ||
            !building_available(cell, group.type_id, true)) continue;
        const BuildingType &type = _building_types[group.type_id];
        const int64_t building_days = saturating_mul(
            group.count, std::max(1, _epoch_days.get()), _saturation_count);
        // Suspended groups do not purchase, but they still publish nameplate
        // desired input demand (and business EMA observations) so upstream
        // producers can discover the latent restart buyer. Funded demand
        // stays active-only — suspended buildings must not claim cash-backed
        // procurement.
        const bool suspended = group.operating_state == 1;
        const int64_t intent_q16 = suspended
            ? Q16_ONE
            : group.purchase_intent_capacity_q16;
        for (int32_t i = 0; i < type.input_count; ++i) {
            const ProductionInput &item = _building_inputs[type.input_begin + i];
            const int64_t required = std::clamp<int64_t>(
                item.required_q16, 0, Q16_ONE);
            if (required > 0 && required < Q16_ONE &&
                !soft_input_purchase_allowed(group, type, i)) continue;
            const int32_t selected = select_input_candidate(item, false, 0);
            if (selected < 0) continue;
            const InputCandidate &candidate = _building_input_candidates[selected];
            const int64_t effective = mul_div_sat(saturating_mul(
                building_days, item.quantity, _saturation_count),
                intent_q16, Q16_ONE, _saturation_count);
            const int64_t planned = effective_production_input_quantity(
                cell, candidate.good_id,
                physical_input_quantity(effective, candidate),
                _saturation_count);
            const int32_t signal = market_signal_index(cell, candidate.good_id);
            if (signal >= cell_signal_begin && signal < cell_signal_end) {
                const size_t local_signal = static_cast<size_t>(signal - cell_signal_begin);
                business_observed[local_signal] = saturating_add(
                    business_observed[local_signal], planned, _saturation_count);
            }
            credit_input_substitute_demand(cell, item, selected, planned);
            // Soft tools: financed activity does not mean the shelf was bought.
            // Fund only the stocked share so missing soft tools still print as
            // unfunded upstream demand.
            int64_t funded_scale_q16 = suspended ? 0 :
                (g < static_cast<int32_t>(_building_funded_capacity_q16.size())
                    ? _building_funded_capacity_q16[g] : group.last_capacity_q16);
            if (!suspended && required > 0 && required < Q16_ONE &&
                planned > 0) {
                const int64_t stock = std::max<int64_t>(0,
                    market_store().stock[market_store().index(
                        market, candidate.good_id)]);
                const int64_t coverage_q16 = std::min<int64_t>(Q16_ONE,
                    mul_div_sat(stock, Q16_ONE, planned, _saturation_count));
                funded_scale_q16 = mul_div_sat(
                    funded_scale_q16, coverage_q16, Q16_ONE, _saturation_count);
            }
            const int64_t funded_effective = suspended ? 0 : mul_div_sat(
                saturating_mul(building_days, item.quantity, _saturation_count),
                funded_scale_q16, Q16_ONE, _saturation_count);
            const int64_t funded = suspended ? 0 : effective_production_input_quantity(
                cell, candidate.good_id,
                physical_input_quantity(funded_effective, candidate),
                _saturation_count);
            if (signal >= 0) {
                if (signal < static_cast<int32_t>(_epoch_desired_business_demand.size())) {
                    _epoch_desired_business_demand[signal] = saturating_add(
                        _epoch_desired_business_demand[signal], planned, _saturation_count);
                }
                if (!suspended &&
                    signal < static_cast<int32_t>(_epoch_funded_business_demand.size())) {
                    _epoch_funded_business_demand[signal] = saturating_add(
                        _epoch_funded_business_demand[signal], funded, _saturation_count);
                }
            }
            _desired_business_demand = saturating_add(
                _desired_business_demand, planned, _saturation_count);
            if (!suspended) {
                _funded_business_demand = saturating_add(
                    _funded_business_demand, funded, _saturation_count);
                _unfunded_business_demand = saturating_add(
                    _unfunded_business_demand, std::max<int64_t>(0, planned - funded),
                    _saturation_count);
            } else {
                _unfunded_business_demand = saturating_add(
                    _unfunded_business_demand, planned, _saturation_count);
            }
        }
    }
    for (const Offer &sale : accepted_anchor_sales) {
        if (sale.merchant_sold <= 0 || sale.good < 0 ||
            sale.type_id < 0 ||
            sale.type_id >= static_cast<int32_t>(_building_types.size()) ||
            sale.group < 0 ||
            sale.group >= static_cast<int32_t>(building_count())) continue;
        const auto sale_group = building_view(static_cast<size_t>(sale.group));
        if (sale_group.operating_state == 1) continue;
        const int32_t output_signal = market_signal_index(cell, sale.good);
        if (output_signal < cell_signal_begin || output_signal >= cell_signal_end)
            continue;
        const BuildingType &sale_type = _building_types[sale.type_id];
        const int64_t owner_livelihood = saturating_mul(saturating_mul(
            living_cost_for_signature(cell, sale_group.owner_signature_id, -1,
                                      _saturation_count),
            std::max<int64_t>(0, sale_group.filled_owner), _saturation_count),
            std::max(1, _epoch_days.get()), _saturation_count);
        const int64_t viability_operating_cost = saturating_add(
            std::max<int64_t>(0, sale_group.last_operating_cost),
            owner_livelihood, _saturation_count);
        const int64_t allocated = allocated_output_operating_cost(
            sale_type, sale.output_index, viability_operating_cost,
            _saturation_count);
        const int64_t unit_cost = sale.qty > 0
            ? mul_div_sat(allocated, GOODS_SCALE, sale.qty, _saturation_count)
            : 0;
        const int64_t required = saturating_add(unit_cost, mul_div_sat(
            unit_cost, sale_type.target_operating_margin_q16, Q16_ONE,
            _saturation_count), _saturation_count);
        const int32_t output_flow = trade_flow_index(cell, sale.good, false);
        const int64_t output_target = merchant_inventory_target(
            market, sale.good, output_signal,
            output_signal >= 0 ? _market_signals.realized_withdrawal_ema[
                output_signal] : 0,
            output_flow >= 0 ? _trade_flows.export_ema[output_flow] : 0,
            sale.qty / std::max(1, _epoch_days.get()), _saturation_count);
        const int32_t buy_factor = effective_merchant_buy_factor_q16(
            market, sale.good, output_target,
            market_store().stock[market_store().index(market, sale.good)],
            _saturation_count);
        const int64_t retail_target = mul_div_sat(
            required, Q16_ONE,
            std::max<int32_t>(1, buy_factor),
            _saturation_count);
        const size_t local_signal = static_cast<size_t>(
            output_signal - cell_signal_begin);
        anchor_weighted[local_signal] = saturating_add(
            anchor_weighted[local_signal], saturating_mul(
                retail_target, sale.merchant_sold, _saturation_count),
            _saturation_count);
        anchor_quantity[local_signal] = saturating_add(
            anchor_quantity[local_signal], sale.merchant_sold,
            _saturation_count);
    }
    for (int32_t g = begin; g < end; ++g) {
        const auto group = building_view(static_cast<size_t>(g));
        if (group.cell != cell || group.count <= 0 ||
            group.operating_state == 1 ||
            !building_available(cell, group.type_id, true)) continue;
        const BuildingType &type = _building_types[group.type_id];
        const int64_t building_days = saturating_mul(
            group.count, std::max(1, _epoch_days.get()), _saturation_count);
        for (int32_t i = 0; i < type.output_count; ++i) {
            const GoodAmount &item = _building_outputs[type.output_begin + i];
            const int32_t output_signal = market_signal_index(cell, item.good_id);
            if (output_signal < cell_signal_begin ||
                output_signal >= cell_signal_end) continue;
            const size_t local_signal = static_cast<size_t>(
                output_signal - cell_signal_begin);
            if (anchor_quantity[local_signal] > 0) continue;
            const int64_t qty = mul_div_sat(saturating_mul(
                building_days, item.quantity, _saturation_count),
                group.last_capacity_q16, Q16_ONE, _saturation_count);
            if (qty <= 0) continue;
            const int64_t owner_livelihood = saturating_mul(saturating_mul(
                living_cost_for_signature(cell, group.owner_signature_id, -1,
                                          _saturation_count),
                std::max<int64_t>(0, group.filled_owner), _saturation_count),
                std::max(1, _epoch_days.get()), _saturation_count);
            const int64_t viability_operating_cost = saturating_add(
                std::max<int64_t>(0, group.last_operating_cost),
                owner_livelihood, _saturation_count);
            const int64_t allocated = allocated_output_operating_cost(
                type, i, viability_operating_cost, _saturation_count);
            const int64_t unit_cost = mul_div_sat(
                allocated, GOODS_SCALE, qty, _saturation_count);
            const int64_t required = saturating_add(unit_cost, mul_div_sat(
                unit_cost, type.target_operating_margin_q16, Q16_ONE,
                _saturation_count), _saturation_count);
            const int32_t output_flow = trade_flow_index(cell, item.good_id, false);
            const int64_t output_target = merchant_inventory_target(
                market, item.good_id, output_signal,
                output_signal >= 0 ? _market_signals.realized_withdrawal_ema[
                    output_signal] : 0,
                output_flow >= 0 ? _trade_flows.export_ema[output_flow] : 0,
                qty / std::max(1, _epoch_days.get()), _saturation_count);
            const int32_t buy_factor = effective_merchant_buy_factor_q16(
                market, item.good_id, output_target,
                market_store().stock[market_store().index(market, item.good_id)],
                _saturation_count);
            const int64_t retail_target = mul_div_sat(
                required, Q16_ONE, std::max<int32_t>(1, buy_factor),
                _saturation_count);
            anchor_weighted[local_signal] = saturating_add(
                anchor_weighted[local_signal], saturating_mul(
                    retail_target, qty, _saturation_count),
                _saturation_count);
            anchor_quantity[local_signal] = saturating_add(
                anchor_quantity[local_signal], qty, _saturation_count);
        }
    }
    if (has_cell_signals) {
        for (int32_t signal = cell_signal_begin; signal < cell_signal_end; ++signal) {
            const size_t local_signal = static_cast<size_t>(signal - cell_signal_begin);
            const int32_t good = _market_signals.good_ids[signal];
            supply_observed[local_signal] = signal >= 0 && signal <
                    static_cast<int32_t>(_epoch_producer_sellable_current.size())
                ? std::max<int64_t>(0,
                    _epoch_producer_sellable_current[signal]) : 0;
            const int64_t desired_daily = signal < static_cast<int32_t>(
                    _epoch_desired_business_demand.size())
                ? _epoch_desired_business_demand[signal] /
                    std::max(1, _epoch_days.get()) : 0;
            const int64_t business_daily = std::max<int64_t>(
                business_observed[local_signal] / std::max(1, _epoch_days.get()),
                desired_daily);
            const int64_t supply_daily =
                supply_observed[local_signal] / std::max(1, _epoch_days.get());
            const int64_t business_alpha = std::min<int64_t>(Q16_ONE,
                static_cast<int64_t>(_good_business_demand_ema_alpha_q16[good]) * _epoch_days.get());
            const int64_t supply_alpha = std::min<int64_t>(Q16_ONE,
                static_cast<int64_t>(_good_supply_ema_alpha_q16[good]) * _epoch_days.get());
            _market_signals.business_demand_ema.write_scalar(signal, saturating_add(
                mul_div_sat(_market_signals.business_demand_ema[signal],
                            Q16_ONE - business_alpha, Q16_ONE, _saturation_count),
                mul_div_sat(business_daily, business_alpha, Q16_ONE, _saturation_count),
                _saturation_count), market_mutation_sink());
            // Preserve a one-unit memory of a previously observed real
            // business lane. This is hysteresis for production planning only;
            // it does not create stock, procurement, sales, or owner slots.
            if (_market_signals.business_demand_ema[signal] <= 0 &&
                business_daily <= 0 &&
                _epoch_business_demand_ema[signal] > 0)
                _market_signals.business_demand_ema.write_scalar(signal, 1, market_mutation_sink());
            _market_signals.offered_supply_ema.write_scalar(signal, saturating_add(
                mul_div_sat(_market_signals.offered_supply_ema[signal],
                            Q16_ONE - supply_alpha, Q16_ONE, _saturation_count),
                mul_div_sat(supply_daily, supply_alpha, Q16_ONE, _saturation_count),
                _saturation_count), market_mutation_sink());
            if (anchor_quantity[local_signal] > 0) {
                const int64_t observed =
                    anchor_weighted[local_signal] / anchor_quantity[local_signal];
                const int64_t cost_alpha = std::min<int64_t>(Q16_ONE,
                    static_cast<int64_t>(_good_cost_ema_alpha_q16[good]) * _epoch_days.get());
                const int64_t old_anchor = _market_signals.cost_anchor_price[signal] > 0
                    ? _market_signals.cost_anchor_price[signal] : observed;
                const int64_t next_anchor = saturating_add(
                    mul_div_sat(old_anchor, Q16_ONE - cost_alpha, Q16_ONE, _saturation_count),
                    mul_div_sat(observed, cost_alpha, Q16_ONE, _saturation_count),
                    _saturation_count);
                _market_signals.cost_anchor_price.write_scalar(signal, static_cast<int32_t>(
                    std::clamp<int64_t>(next_anchor, PRICE_NUMERIC_GUARD_MIN,
                                        PRICE_NUMERIC_GUARD_MAX)), market_mutation_sink());
            }
            ++_market_signal_updates;
        }
    }
    _market_signal_ms += elapsed_ms(signal_started);
    for (int32_t g = begin; g < end; ++g) {
        const auto group = building_view(static_cast<size_t>(g));
        if (group.cell != cell || group.count <= 0) continue;
        std::vector<EventLeg> legs;
        if (trace_detail) {
            const BuildingGroup &before = trace_before[static_cast<size_t>(g - begin)];
            auto add = [&](int32_t field, int64_t old_value, int64_t new_value) {
                if (old_value != new_value) {
                    legs.push_back({field, SUBJECT_BUILDING_GROUP,
                                    group.owner_signature_id, group.type_id,
                                    old_value, new_value});
                }
            };
            add(FIELD_BUILDING_CAPACITY, before.last_capacity_q16, group.last_capacity_q16);
            add(FIELD_BUILDING_INPUT, before.last_input, group.last_input);
            add(FIELD_BUILDING_OUTPUT, before.last_output, group.last_output);
            add(FIELD_BUILDING_SOLD, before.last_sold, group.last_sold);
            add(FIELD_BUILDING_DISCARDED, before.last_discarded, group.last_discarded);
            add(FIELD_BUILDING_RESOURCE, before.last_resource, group.last_resource);
            add(FIELD_BUILDING_RESOURCE_GENERATED, before.last_resource_generated,
                group.last_resource_generated);
            add(FIELD_BUILDING_REVENUE, before.last_revenue, group.last_revenue);
            add(FIELD_BUILDING_INPUT_COST, before.last_input_cost, group.last_input_cost);
            add(FIELD_BUILDING_WAGES_PAID, before.last_wages_paid, group.last_wages_paid);
            add(FIELD_BUILDING_WAGES_DUE, before.last_wages_due, group.last_wages_due);
            add(FIELD_BUILDING_EXPECTED_REVENUE, before.last_expected_revenue,
                group.last_expected_revenue);
            add(FIELD_BUILDING_OPERATING_COST, before.last_operating_cost,
                group.last_operating_cost);
            add(FIELD_BUILDING_MARGIN_GAP, before.last_margin_gap_q16,
                group.last_margin_gap_q16);
            add(FIELD_BUILDING_PLANNED_UTILIZATION, before.planned_utilization_q16,
                group.planned_utilization_q16);
            add(FIELD_BUILDING_BASE_WAGES_PAID, before.last_base_wages_paid,
                group.last_base_wages_paid);
            add(FIELD_BUILDING_BASE_WAGES_DUE, before.last_base_wages_due,
                group.last_base_wages_due);
            add(FIELD_BUILDING_BONUS_PAID, before.last_bonus_paid,
                group.last_bonus_paid);
            add(FIELD_BUILDING_BONUS_DUE, before.last_bonus_due,
                group.last_bonus_due);
            add(FIELD_BUILDING_WAGE_SUSPENDED, before.wage_suspended,
                group.wage_suspended);
        }
        trace_append(EVENT_BUILDING_PRODUCTION_SETTLED,
                     static_cast<int32_t>(Stage::BUILDING_PRODUCTION), cell,
                     SUBJECT_BUILDING_GROUP, group.owner_signature_id,
                     group.type_id, -1, group.last_output, group.last_sold,
                     group.last_revenue, group.last_wages_paid,
                     legs.empty() ? nullptr : &legs);
    }
    if (trace_detail) {
        std::vector<EventLeg> cell_legs;
        auto add = [&](int32_t field, int32_t subject_kind, int64_t subject_id,
                       int32_t key_id, int64_t before, int64_t after) {
            if (before != after) {
                cell_legs.push_back({field, subject_kind, subject_id, key_id, before, after});
            }
        };
        for (size_t i = 0; i < trace_cell_slots.size(); ++i) {
            const int32_t slot = trace_cell_slots[i];
            const int64_t handle = static_cast<int64_t>(population_store().handle_for_slot(slot));
            add(FIELD_COHORT_FUNDS, SUBJECT_COHORT, handle, -1,
                trace_cell_funds[i], population_store().funds[slot]);
            add(FIELD_COHORT_EPOCH_INCOME, SUBJECT_COHORT, handle, -1,
                trace_cell_income[i], population_store().epoch_income[slot]);
            add(FIELD_COHORT_EPOCH_EXPENSE, SUBJECT_COHORT, handle, -1,
                trace_cell_expense[i], population_store().epoch_expense[slot]);
        }
        for (int32_t good = 0; good < market_store().good_count.get(); ++good) {
            add(FIELD_MARKET_STOCK, SUBJECT_MARKET, market, good,
                trace_market_stock[good], market_store().stock[market_store().index(market, good)]);
        }
        for (size_t resource = 0; resource < _resource_ids.size(); ++resource) {
            const int64_t after = resource_delta_lanes()[
                resource * static_cast<size_t>(_cell_count.get()) + cell];
            add(FIELD_RESOURCE_DELTA, SUBJECT_RESOURCE, cell,
                static_cast<int32_t>(resource), trace_resource_delta[resource], after);
        }
        if (!cell_legs.empty()) {
            trace_append(EVENT_BUILDING_PRODUCTION_SETTLED,
                         static_cast<int32_t>(Stage::BUILDING_PRODUCTION), cell,
                         SUBJECT_MARKET, market, -1, -1,
                         static_cast<int64_t>(cell_legs.size()), 0, 0, 0, &cell_legs);
        }
    }
    if (cell >= 0 && cell < static_cast<int32_t>(
            _merchant_procurement_paid_by_cell.size())) {
        _merchant_procurement_paid_by_cell[cell] = saturating_add(
            _merchant_procurement_paid_by_cell[cell],
            std::max<int64_t>(0, _merchant_procurement_spent -
                cell_procurement_paid_before), _saturation_count);
        _merchant_procurement_retail_by_cell[cell] = saturating_add(
            _merchant_procurement_retail_by_cell[cell],
            std::max<int64_t>(0, _merchant_procurement_retail_value -
                cell_procurement_retail_before), _saturation_count);
        _merchant_procurement_factor_weighted_cash_by_cell[cell] =
            saturating_add(
                _merchant_procurement_factor_weighted_cash_by_cell[cell],
                std::max<int64_t>(0,
                    _merchant_procurement_factor_weighted_cash_q16 -
                    cell_procurement_factor_before), _saturation_count);
        _merchant_credit_drawn_by_cell[cell] = saturating_add(
            _merchant_credit_drawn_by_cell[cell],
            std::max<int64_t>(0, result.merchant_credit_drawn -
                cell_credit_drawn_before), _saturation_count);
    }
