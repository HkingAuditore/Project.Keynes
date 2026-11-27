        offers.clear();
        for (int32_t g = begin; g < end; ++g) {
            {
                const auto group_view = building_view(static_cast<size_t>(g));
                if (group_view.cell != cell || group_view.count <= 0 ||
                    !building_available(cell, group_view.type_id, true)) continue;
                if (group_view.operating_state == 1) continue;
                if (produces_cycle_flow(
                        _building_types[group_view.type_id]) != cycle_flow_phase) continue;
            }
            auto group = building_at(static_cast<size_t>(g));
            const BuildingType &type = _building_types[group.type_id];
            ++_processed_building_groups;
            if (type.production_climate_profile_id >= 0) {
                ++_climate_profiled_building_groups;
                if (group.last_climate_capacity_q16 < Q16_ONE)
                    ++_climate_limited_building_groups;
                _climate_capacity_sum_q16 = saturating_add(
                    _climate_capacity_sum_q16,
                    group.last_climate_capacity_q16, _saturation_count);
            }
            const int32_t owner_slot = find_cohort_slot(cell, group.owner_signature_id);
            if (owner_slot < 0) continue;
            int64_t workforce_capacity_q16 = Q16_ONE;
            const int64_t owner_slots = saturating_mul(
                group.count, type.owner_slots_per_building, _saturation_count);
            workforce_capacity_q16 = owner_slots > 0
                ? std::clamp<int64_t>(mul_div_sat(
                    std::max<int64_t>(0, group.filled_owner), Q16_ONE,
                    owner_slots, _saturation_count), 0, Q16_ONE)
                : 0;
            if (workforce_capacity_q16 > 0) {
                group.last_observed_capacity_days_q16 = std::max<int64_t>(
                    1, saturating_mul(workforce_capacity_q16,
                        saturating_mul(std::max<int64_t>(1, group.count),
                            std::max<int64_t>(1, _epoch_days.get()), _saturation_count),
                        _saturation_count));
            }
            const int64_t intent_scale_without_climate = desired_scale_for_group(
                group, type, false);
            int64_t intent_scale_q16 = intent_scale_without_climate;
            const int64_t building_days = saturating_mul(
                group.count, std::max(1, _epoch_days.get()), _saturation_count);
            const int64_t group_budget = g < static_cast<int32_t>(
                _building_working_capital_allocated.size())
                ? _building_working_capital_allocated[g] : 0;
            // `_building_merchant_credit_limit` is populated by the review
            // pass when it already reserved a restart.  For an ACTIVE group
            // with no pre-existing reservation, derive a bounded request from
            // the frozen input quote so a poor owner can still finance normal
            // operating inputs.  This is deliberately input-only credit;
            // wages and owner livelihood remain ordinary settled obligations.
            int64_t requested_credit = g < static_cast<int32_t>(
                _building_merchant_credit_limit.size())
                ? std::max<int64_t>(0, _building_merchant_credit_limit[g]) : 0;
            // Military v1: an explicitly state-owned building is financed by
            // the treasury and never borrows merchant operating credit.
            const bool state_owned_group = type.kind == 3;
            if (state_owned_group) requested_credit = 0;
            bool survival_output = false;
            bool cycle_flow_output = false;
            for (int32_t oi = 0; oi < type.output_count; ++oi) {
                const int32_t good = _building_outputs[type.output_begin + oi].good_id;
                if (good >= 0 && good < static_cast<int32_t>(_survival_food_good_mask.size()) &&
                    (_survival_food_good_mask[good] != 0 || _survival_clothing_good_mask[good] != 0)) {
                    survival_output = true;
                }
                if (good >= 0 && good < static_cast<int32_t>(_good_storage_modes.size()) &&
                    _good_storage_modes[good] == 1) {
                    cycle_flow_output = true;
                }
            }
            // Probe floors: durable industrial 1/32, cycle-flow 1/6.
            const int64_t industrial_probe_floor = cycle_flow_output
                ? std::max<int64_t>(1, Q16_ONE / 6)
                : std::max<int64_t>(1, Q16_ONE / 32);
            const int64_t credit_floor_scale = survival_output
                ? std::clamp<int64_t>(intent_scale_q16, 0, Q16_ONE)
                : std::clamp<int64_t>(
                    std::min<int64_t>(intent_scale_q16, industrial_probe_floor),
                    0, Q16_ONE);
            if (requested_credit <= 0 && !state_owned_group &&
                _merchant_credit_runtime_mode.get() == 2 &&
                credit_floor_scale > 0) {
                // Hunter/collector livelihood and bounded industrial probe
                // floors may auto-request merchant-backed input credit.
                // Shadow derived demand never expands this request.
                const int64_t quoted_request = group_input_cost_at_scale(
                    group, type, credit_floor_scale, false);
                if (quoted_request != std::numeric_limits<int64_t>::max())
                    requested_credit = std::max<int64_t>(0, quoted_request);
            }
            const int64_t credit_cap = _merchant_credit_runtime_mode.get() == 2
                ? std::min<int64_t>(cell_credit_remaining, requested_credit) : 0;
            const int64_t owner_capital_budget = std::max<int64_t>(
                0, group_budget - std::min(group_budget, credit_cap));
            const int64_t owner_contribution_cap = std::min<int64_t>(
                owner_capital_budget, std::max<int64_t>(
                    0, population_store().funds[owner_slot]));
            int64_t merchant_credit_cash = 0;
            if (_merchant_credit_runtime_mode.get() == 2 && credit_cap > 0) {
                for (int32_t k = _merchant_offsets[cell];
                     k < _merchant_offsets[cell + 1]; ++k) {
                    merchant_credit_cash = saturating_add(
                        merchant_credit_cash,
                        std::max<int64_t>(0, population_store().funds[_merchant_slots[k]]),
                        _saturation_count);
                }
            }
            const int64_t drawable_credit = std::min<int64_t>(
                credit_cap, merchant_credit_cash);
            const int64_t settlement_budget = saturating_add(
                owner_contribution_cap, drawable_credit, _saturation_count);
            auto clamp_scale_to_group_budget = [&](int64_t output_scale_q16,
                                                   bool require_stock) -> int64_t {
                if (group_input_cost_at_scale(group, type, output_scale_q16,
                                              require_stock) <= settlement_budget) {
                    return output_scale_q16;
                }
                int64_t lo = 0;
                int64_t hi = std::clamp<int64_t>(output_scale_q16, 0, Q16_ONE);
                // Keep the allocation conservative while still allowing a
                // financed survival producer to find a sub-probe scale when
                // only a small merchant-credit remainder is available.
                // Sixteen probes resolve the Q16 interval to one unit.
                for (int iter = 0; iter < 16; ++iter) {
                    const int64_t mid = (lo + hi + 1) / 2;
                    if (group_input_cost_at_scale(group, type, mid, require_stock) <= settlement_budget) lo = mid;
                    else hi = mid - 1;
                }
                _working_capital_scale_error_bound_q16 = std::max<int64_t>(
                    _working_capital_scale_error_bound_q16,
                    std::max<int64_t>(0, hi - lo));
                return lo;
            };
            int64_t scale_q16 = intent_scale_q16;
            for (int32_t i = 0; i < type.input_count; ++i) {
                const ProductionInput &item = _building_inputs[type.input_begin + i];
                const int64_t required = std::clamp<int64_t>(
                    item.required_q16, 0, Q16_ONE);
                if (required < Q16_ONE) continue; // soft: not an objective clamp
                const int64_t effective = saturating_mul(
                    building_days, item.quantity, _saturation_count);
                const int32_t selected = select_input_candidate(
                    item, true, effective, group.output_factor_q16);
                if (selected < 0) {
                    scale_q16 = 0;
                    continue;
                }
                const InputCandidate &candidate = _building_input_candidates[selected];
                const int64_t physical = effective_production_input_quantity(
                    cell, candidate.good_id,
                    physical_input_quantity(effective, candidate),
                    _saturation_count, group.output_factor_q16);
                int64_t raw_capacity_q16 = Q16_ONE;
                if (physical > 0) {
                    raw_capacity_q16 = std::min<int64_t>(Q16_ONE, mul_div_sat(
                        market_store().stock[market_store().index(market, candidate.good_id)], Q16_ONE,
                        physical, _saturation_count));
                }
                scale_q16 = std::min<int64_t>(scale_q16, raw_capacity_q16);
            }
            scale_q16 = clamp_scale_to_group_budget(scale_q16, true);
            const int64_t non_resource_scale_without_climate_q16 =
                std::clamp<int64_t>(scale_q16, 0, Q16_ONE);
            bool resource_limited = false;
            bool resource_capacity_limited = false;
            int64_t resource_factor_q16 = Q16_ONE;
            int64_t ceiling_resource_scale = intent_scale_q16;
            if (type.behavior_id == 1 || type.behavior_id == 2) {
                for (int32_t i = 0; i < type.resource_count; ++i) {
                    const ResourceAmount &item = _building_resources[type.resource_begin + i];
                    const int64_t raw_base = item.mode == 1
                        ? saturating_mul(group.count, item.quantity, _saturation_count)
                        : saturating_mul(building_days, item.quantity, _saturation_count);
                    const int64_t base = effective_resource_use_quantity(
                        cell, item.resource_id, raw_base, _saturation_count);
                    if (base <= 0) continue;
                    if (item.mode == 1) ++_building_resource_capacity_checks;
                    const int64_t resource_scale = resource_capacity_scale_q16(
                        item, cell, base);
                    const bool resource_capacity_bound = intent_scale_q16 > 0 &&
                        resource_scale < Q16_ONE &&
                        resource_scale <= intent_scale_q16;
                    if (resource_capacity_bound || resource_scale < Q16_ONE)
                        resource_limited = true;
                    if (item.mode == 1 &&
                        (resource_capacity_bound || resource_scale < Q16_ONE)) {
                        resource_capacity_limited = true;
                    }
                    resource_factor_q16 = mul_div_sat(resource_factor_q16,
                        resource_scale, Q16_ONE, _saturation_count);
                    ceiling_resource_scale = mul_div_sat(
                        ceiling_resource_scale, resource_scale, Q16_ONE,
                        _saturation_count);
                }
            }
            const int64_t scale_without_climate_q16 = std::clamp<int64_t>(
                mul_div_sat(scale_q16, resource_factor_q16, Q16_ONE,
                    _saturation_count), 0, Q16_ONE);
            intent_scale_q16 = mul_div_sat(
                std::clamp<int64_t>(intent_scale_without_climate, 0, Q16_ONE),
                std::clamp<int64_t>(group.last_climate_capacity_q16, 0, Q16_ONE),
                Q16_ONE, _saturation_count);
            scale_q16 = mul_div_sat(
                scale_without_climate_q16,
                std::clamp<int64_t>(group.last_climate_capacity_q16, 0, Q16_ONE),
                Q16_ONE, _saturation_count);
            // Soft inputs are capped productivity bonuses, not activity-capacity
            // constraints.  Keep the activity scale bounded by owners,
            // employees, hard inputs, resources, and climate; apply the
            // capped productivity multiplier only to output.
            int64_t soft_bonus_sum_q16 = 0;
            for (int32_t i = 0; i < type.input_count; ++i) {
                const ProductionInput &item = _building_inputs[type.input_begin + i];
                const int64_t required = std::clamp<int64_t>(
                    item.required_q16, 0, Q16_ONE);
                if (required <= 0 || required >= Q16_ONE) continue;
                const int64_t effective = saturating_mul(
                    building_days, item.quantity, _saturation_count);
                const int64_t need_at_activity = mul_div_sat(
                    effective, scale_q16, Q16_ONE, _saturation_count);
                const int32_t selected = select_input_candidate(
                    item, true, effective, group.output_factor_q16);
                int64_t coverage_q16 = 0;
                const bool soft_purchase_enabled = required >= Q16_ONE ||
                    soft_input_purchase_allowed(group, type, i);
                if (soft_purchase_enabled && selected >= 0 && need_at_activity > 0) {
                    const InputCandidate &candidate =
                        _building_input_candidates[selected];
                    const int64_t physical = effective_production_input_quantity(
                        cell, candidate.good_id,
                        physical_input_quantity(need_at_activity, candidate),
                        _saturation_count, group.output_factor_q16);
                    const int64_t stock = market_store().stock[
                        market_store().index(market, candidate.good_id)];
                    coverage_q16 = physical > 0
                        ? std::min<int64_t>(Q16_ONE, mul_div_sat(
                            std::max<int64_t>(0, stock), Q16_ONE, physical,
                            _saturation_count))
                        : Q16_ONE;
                }
                const int64_t bonus_q16 = mul_div_sat(
                    soft_input_marginal_bonus_q16(type, required), coverage_q16,
                    Q16_ONE, _saturation_count);
                soft_bonus_sum_q16 = saturating_add(
                    soft_bonus_sum_q16, bonus_q16, _saturation_count);
            }
            const int64_t soft_productivity_bonus_q16 =
                clamp_soft_productivity_bonus_q16(soft_bonus_sum_q16);
            const int64_t activity_scale_q16 = scale_q16;
            if (resource_limited) ++_building_resource_limited_groups;
            if (resource_capacity_limited) ++_building_resource_capacity_limited_groups;
            group.purchase_intent_capacity_q16 = intent_scale_q16;
            group.last_capacity_q16 = scale_q16;
            _building_funded_capacity_q16[g] = activity_scale_q16;
            // ACTIVE_UNFUNDED: retain bounded purchase intent and stay ACTIVE
            // when finance (not physics) is the binding constraint.
            if (group.operating_state == 0 && intent_scale_q16 > 0 &&
                scale_q16 < intent_scale_q16 && settlement_budget <= 0 &&
                credit_cap <= 0) {
                group.purchase_intent_capacity_q16 = std::max<int64_t>(
                    group.purchase_intent_capacity_q16,
                    industrial_probe_floor);
                result.active_unfunded_building_groups = saturating_add(
                    result.active_unfunded_building_groups, 1, _saturation_count);
            } else if (group.operating_state == 0 && intent_scale_q16 > 0 &&
                       scale_q16 == 0 && owner_contribution_cap <= 0 &&
                       drawable_credit <= 0) {
                group.purchase_intent_capacity_q16 = std::max<int64_t>(
                    group.purchase_intent_capacity_q16,
                    industrial_probe_floor);
                result.active_unfunded_building_groups = saturating_add(
                    result.active_unfunded_building_groups, 1, _saturation_count);
            }
            auto output_with_productivity = [&](const GoodAmount &output,
                                                int64_t output_scale_q16) -> int64_t {
                const int64_t base_output = effective_building_output_quantity(
                    group, output.good_id, output.quantity, output_scale_q16,
                    building_days, _saturation_count);
                return mul_div_sat(base_output, soft_productivity_bonus_q16,
                    Q16_ONE, _saturation_count);
            };
            if (group.last_climate_capacity_q16 < Q16_ONE) {
                for (int32_t i = 0; i < type.output_count; ++i) {
                    const GoodAmount &output = _building_outputs[type.output_begin + i];
                    const int64_t without_climate = output_with_productivity(
                        output, scale_without_climate_q16);
                    const int64_t with_climate = output_with_productivity(
                        output, scale_q16);
                    group.last_climate_lost_output = saturating_add(
                        group.last_climate_lost_output,
                        std::max<int64_t>(0, without_climate - with_climate),
                        _saturation_count);
                }
            }
            if (type.behavior_id == 2) {
                const int64_t generation_scale_q16 = mul_div_sat(
                    std::max<int64_t>(scale_q16, type.generation_floor_q16),
                    std::clamp<int64_t>(group.last_climate_capacity_q16,
                        0, Q16_ONE), Q16_ONE, _saturation_count);
                for (int32_t i = 0; i < type.generation_count; ++i) {
                    const ResourceAmount &item =
                        _building_resource_generation[type.generation_begin + i];
                    const int64_t raw_qty = mul_div_sat(saturating_mul(
                        building_days, item.quantity, _saturation_count),
                        generation_scale_q16, Q16_ONE, _saturation_count);
                    const int64_t qty = effective_managed_resource_generation(
                        cell, item.resource_id, raw_qty, _saturation_count);
                    const size_t idx = static_cast<size_t>(item.resource_id) * _cell_count.get() + cell;
                    ensure_resource_lane(idx);
                    resource_delta_lanes()[idx] = saturating_add(
                        resource_delta_lanes()[idx], qty, _saturation_count);
                    group.last_resource_generated = saturating_add(
                        group.last_resource_generated, qty, _saturation_count);
                    _building_resource_generated = saturating_add(
                        _building_resource_generated, qty, _saturation_count);
                }
            }
            if (observe_price_ceiling && type.input_count > 0) {
                const int64_t affordable_scale = clamp_scale_to_group_budget(
                    std::min(intent_scale_q16, ceiling_resource_scale), false);
                const int64_t intent_cost = quote_group_inputs(group, type, affordable_scale, false,
                    &ceiling_input_candidates, &ceiling_input_quantities);
                if (intent_cost <= settlement_budget) {
                    for (int32_t i = 0; i < type.input_count; ++i) {
                        const int32_t selected = ceiling_input_candidates[i];
                        const int64_t requested = ceiling_input_quantities[i];
                        if (selected < 0 || requested <= 0) continue;
                        const auto &item = _building_inputs[type.input_begin + i];
                        const int64_t requested_scale = input_purchase_scale_q16(
                            item, affordable_scale,
                            soft_input_purchase_allowed(group, type, i));
                        // Test this recipe edge independently. A missing
                        // complementary input must not make stocked goods scarce.
                        const int64_t effective = saturating_mul(building_days,
                            item.quantity, _saturation_count);
                        const int32_t available = select_input_candidate(
                            item, true, effective, group.output_factor_q16);
                        int64_t available_scale = 0;
                        if (available >= 0) {
                            const auto &candidate = _building_input_candidates[available];
                            const int64_t physical = effective_production_input_quantity(cell,
                                candidate.good_id, physical_input_quantity(effective, candidate),
                                _saturation_count, group.output_factor_q16);
                            available_scale = physical > 0 ? std::min<int64_t>(Q16_ONE,
                                mul_div_sat(market_store().stock[market_store().index(market, candidate.good_id)],
                                    Q16_ONE, physical, _saturation_count)) : Q16_ONE;
                        }
                        const int64_t unfilled = mul_div_sat(requested,
                            std::max<int64_t>(0, requested_scale - available_scale),
                            std::max<int64_t>(1, requested_scale), _saturation_count);
                        const int32_t signal = market_signal_index(cell, _building_input_candidates[selected].good_id);
                        if (signal >= 0 && signal < static_cast<int32_t>(_epoch_ceiling_business_requested.size())) {
                            _epoch_ceiling_business_requested[signal] = saturating_add(
                                _epoch_ceiling_business_requested[signal], requested, _saturation_count);
                            _epoch_ceiling_business_unfilled[signal] = saturating_add(
                                _epoch_ceiling_business_unfilled[signal], unfilled, _saturation_count);
                        }
                    }
                }
            }
            if (activity_scale_q16 == 0) continue;
            touch_accounting_slot(owner_slot);
            // Soft tools are bought for objective activity; their stock changes
            // only the output productivity multiplier, not activity capacity or
            // the buy intent.
            const int64_t actual_cost = quote_group_inputs(
                group, type, activity_scale_q16, true,
                &quoted_input_candidates, &quoted_input_quantities);
            if (actual_cost == std::numeric_limits<int64_t>::max() ||
                actual_cost > settlement_budget) {
                error = "building_input_quote_drift:cell=" + std::to_string(cell) +
                    ",group=" + std::to_string(g) +
                    ",type=" + std::to_string(group.type_id) +
                    ",cost=" + std::to_string(actual_cost) +
                    ",budget=" + std::to_string(settlement_budget);
                return false;
            }
            if (actual_cost > 0 && !local_merchants_can_receive(cell)) {
                // A famine can empty every merchant cohort while stock is
                // still on the shelf; with no seller the lot cannot buy.
                group.last_capacity_q16 = 0;
                _building_funded_capacity_q16[g] = 0;
                group.purchase_intent_capacity_q16 = std::max<int64_t>(
                    group.purchase_intent_capacity_q16, industrial_probe_floor);
                result.active_unfunded_building_groups = saturating_add(
                    result.active_unfunded_building_groups, 1, _saturation_count);
                continue;
            }
            int64_t base_input_cost = 0;
            int64_t input_fiscal_transfer = 0;
            int64_t settled_input_outlay = 0;
            const FiscalLaneSnapshot input_tax_lane = snapshot_fiscal_lane(
                cell, CountryApi::TAX_TRANSACTION);
            // Reuse the final preflight bills verbatim, so splitting a recipe
            // into several input edges cannot change the rounded fee or tax.
            for (size_t policy = 0; policy < input_policy_count; ++policy) {
                const InputPolicyBill &bill = input_policy_bills[policy];
                const TransactionQuote quote = quote_transaction(cell, bill.good,
                    bill.bill.total(_saturation_count), true, true,
                    _saturation_count, bill.quantity);
                base_input_cost = saturating_add(
                    base_input_cost, quote.base_value, _saturation_count);
                input_fiscal_transfer = saturating_add(
                    input_fiscal_transfer, quote.fiscal_transfer,
                    _saturation_count);
                settled_input_outlay = saturating_add(
                    settled_input_outlay, quote.buyer_outlay,
                    _saturation_count);
            }
            const int64_t cash_input_outlay = std::max<int64_t>(
                0, settled_input_outlay);
            const int64_t input_subsidy_income = std::max<int64_t>(
                0, -settled_input_outlay);
            const int64_t owner_contribution = std::min<int64_t>(
                cash_input_outlay, owner_contribution_cap);
            const int64_t draw = cash_input_outlay - owner_contribution;
            if (draw > 0) {
                const bool credit_allowed =
                    _merchant_credit_runtime_mode.get() == 2 &&
                    group.operating_state == 0 &&
                    group.merchant_debt_delinquent_cycles == 0 &&
                    draw <= drawable_credit;
                const int64_t merchant_debited = credit_allowed
                    ? debit_local_merchants(cell, draw, CASHFLOW_MERCHANT_BUSINESS,
                                            &_saturation_count)
                    : 0;
                if (merchant_debited != draw) {
                    // Credit exhaustion must keep the building ACTIVE with
                    // bounded purchase intent. Fail-closed abort of the whole
                    // cell would masquerade finance shortfalls as hard errors.
                    // The abandoned purchase must not leave settled tax or a
                    // partial merchant debit behind.
                    restore_fiscal_lane(input_tax_lane);
                    if (merchant_debited > 0 &&
                        credit_local_merchants(cell, merchant_debited,
                                               CASHFLOW_MERCHANT_BUSINESS,
                                               &_saturation_count) != merchant_debited) {
                        error = "building_input_credit_refund_drift";
                        return false;
                    }
                    group.last_capacity_q16 = 0;
                    _building_funded_capacity_q16[g] = 0;
                    group.purchase_intent_capacity_q16 = std::max<int64_t>(
                        group.purchase_intent_capacity_q16,
                        industrial_probe_floor);
                    result.active_unfunded_building_groups = saturating_add(
                        result.active_unfunded_building_groups, 1,
                        _saturation_count);
                    continue;
                }
                touch_accounting_slot(owner_slot);
                population_store().funds.write_scalar(owner_slot, saturating_add(
                    population_store().funds[owner_slot], draw, _saturation_count), market_mutation_sink());
                trace_record_cashflow(cell, population_store().handle_for_slot(owner_slot),
                                      CASHFLOW_OTHER, draw, 0);
                const int64_t premium = saturating_add(saturating_mul(
                    draw, _merchant_credit_premium_q16.get(), _saturation_count),
                    Q16_ONE - 1, _saturation_count) / Q16_ONE;
                group.merchant_debt_principal = saturating_add(
                    group.merchant_debt_principal, draw, _saturation_count);
                group.merchant_debt_premium = saturating_add(
                    group.merchant_debt_premium, premium, _saturation_count);
                group.merchant_debt_term_cycles_left = static_cast<uint16_t>(
                    _merchant_credit_term_cycles.get());
                result.merchant_credit_drawn = saturating_add(
                    result.merchant_credit_drawn, draw, _saturation_count);
                cell_credit_remaining = std::max<int64_t>(0,
                    cell_credit_remaining - draw);
            }
            for (int32_t i = 0; i < type.input_count; ++i) {
                const int32_t selected = quoted_input_candidates[i];
                const int64_t qty = quoted_input_quantities[i];
                if (selected < 0 || qty <= 0) continue;
                const InputCandidate &candidate = _building_input_candidates[selected];
                _building_last_input_selected_goods[
                    group.last_input_selection_begin + i] = candidate.good_id;
                const int64_t stock_index =
                    market_store().index(market, candidate.good_id);
                audit_touch_market_lane(static_cast<size_t>(stock_index));
                market_store().stock.write_scalar(stock_index, market_store().stock[stock_index] - (qty), market_mutation_sink());
                const int32_t signal = market_signal_index(cell, candidate.good_id);
                if (signal >= 0 && signal < static_cast<int32_t>(
                        _epoch_nonhousehold_withdrawals.size())) {
                    _epoch_nonhousehold_withdrawals[signal] = saturating_add(
                        _epoch_nonhousehold_withdrawals[signal], qty, _saturation_count);
                }
                group.last_input = saturating_add(group.last_input, qty, _saturation_count);
                _production_inputs_consumed = saturating_add(
                    _production_inputs_consumed, qty, _saturation_count);
                if (candidate.good_id >= 0 && candidate.good_id <
                        static_cast<int32_t>(_good_food_equivalent_q16.size())) {
                    const int64_t coefficient = _good_food_equivalent_q16[
                        static_cast<size_t>(candidate.good_id)];
                    if (coefficient > 0) {
                        ++result.food_input_events;
                        _food_input_eq = saturating_add(_food_input_eq,
                            mul_div_sat(qty, coefficient, Q16_ONE,
                                _saturation_count), _saturation_count);
                    }
                }
                if (_good_storage_modes[candidate.good_id] == 1) {
                    _cycle_flow_consumed = saturating_add(
                        _cycle_flow_consumed, qty, _saturation_count);
                }
            }
            population_store().funds.write_scalar(owner_slot, saturating_add(
                population_store().funds[owner_slot] - cash_input_outlay,
                input_subsidy_income, _saturation_count), market_mutation_sink());
            group.last_input_cost = base_input_cost;
            group.last_operating_cost = saturating_add(
                cash_input_outlay, group.last_wages_due, _saturation_count);
            population_store().epoch_expense.write_scalar(owner_slot, saturating_add(
                population_store().epoch_expense[owner_slot], cash_input_outlay,
                _saturation_count), market_mutation_sink());
            population_store().epoch_income.write_scalar(owner_slot, saturating_add(
                population_store().epoch_income[owner_slot], input_subsidy_income,
                _saturation_count), market_mutation_sink());
            record_cohort_fiscal(owner_slot, input_fiscal_transfer);
            trace_record_cashflow(cell, population_store().handle_for_slot(owner_slot),
                                  CASHFLOW_PRODUCTION_INPUT, 0,
                                  cash_input_outlay);
            if (credit_local_merchants(cell, base_input_cost,
                                       CASHFLOW_MERCHANT_BUSINESS,
                                       &_saturation_count) != base_input_cost) {
                error = "building_input_has_no_merchant_owner";
                return false;
            }
            if (type.behavior_id == 1 || type.behavior_id == 2) {
                for (int32_t i = 0; i < type.resource_count; ++i) {
                    const ResourceAmount &item = _building_resources[type.resource_begin + i];
                    if (item.mode == 1) continue;
                    const int64_t raw_qty = mul_div_sat(saturating_mul(
                        building_days, item.quantity, _saturation_count),
                        scale_q16, Q16_ONE, _saturation_count);
                    const int64_t qty = effective_resource_use_quantity(
                        cell, item.resource_id, raw_qty, _saturation_count);
                    consume_resource_amount(item, cell, qty);
                    group.last_resource = saturating_add(
                        group.last_resource, qty, _saturation_count);
                    _building_resource_consumed = saturating_add(
                        _building_resource_consumed, qty, _saturation_count);
                }
            }
            for (int32_t i = 0; i < type.output_count; ++i) {
                const GoodAmount &item = _building_outputs[type.output_begin + i];
                const int64_t qty = output_with_productivity(item, scale_q16);
                if (qty > 0) {
                    offers.push_back({item.good_id, owner_slot, g, i, group.type_id,
                        qty, 0, qty});
                    queue_bio_introduce_from_good(cell, item.good_id);
                    if (item.good_id >= 0 && item.good_id <
                            static_cast<int32_t>(_good_food_equivalent_q16.size())) {
                        const int64_t coefficient = _good_food_equivalent_q16[
                            static_cast<size_t>(item.good_id)];
                        if (coefficient > 0) {
                            ++result.food_output_events;
                            _food_output_eq = saturating_add(_food_output_eq,
                                mul_div_sat(qty, coefficient, Q16_ONE,
                                    _saturation_count), _saturation_count);
                        }
                    }
                }
                group.last_output = saturating_add(
                    group.last_output, qty, _saturation_count);
            }
        }
