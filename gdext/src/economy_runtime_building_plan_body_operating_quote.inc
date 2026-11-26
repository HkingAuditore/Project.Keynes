        const int32_t market = market_store().cell_to_market[group.cell];
        // The production result is still constrained by the capacity that can
        // actually operate in this cell. The planning quote itself is kept
        // independent of current staffing so a vacant installed group can
        // attract labour and recover instead of locking into zero demand.
        const int64_t owner_slots = saturating_mul(
            group.count, type.owner_slots_per_building, _saturation_count);
        // Epoch planning runs before the employment stage. A newly installed
        // or never-observed group therefore has no factual fill yet, but it
        // still needs a bounded nameplate prior so its first owner/employee
        // positions can be hired. Once production has emitted a capacity-day
        // receipt, replace that prior with the minimum observed role fill.
        const bool observed_capacity = group.last_observed_capacity_days_q16 > 0;
        // Keep the factual execution scale separate from the economic forecast.
        // A partially staffed group must produce proportionally less, but its
        // building-level attraction must not collapse merely because the same
        // vacancy caused the partial staffing in the first place.
        int64_t actual_workforce_capacity_q16 = !observed_capacity ? Q16_ONE
            : owner_slots > 0
                ? std::clamp<int64_t>(mul_div_sat(
                    std::max<int64_t>(0, group.filled_owner), Q16_ONE,
                    owner_slots, _saturation_count), 0, Q16_ONE)
                : Q16_ONE;
        for (int32_t r = 0; r < type.employee_count; ++r) {
            const JobRole &role = _building_employee_roles[type.employee_begin + r];
            const int64_t role_slots = saturating_mul(
                group.count, role.slots_per_building, _saturation_count);
            const int32_t role_index = group.employee_fill_begin + r;
            const int64_t role_fill = role_index >= 0 && role_index <
                    static_cast<int32_t>(_building_employee_filled.size())
                ? std::max<int64_t>(0, _building_employee_filled[role_index]) : 0;
            const int64_t role_capacity = !observed_capacity ? Q16_ONE
                : role_slots > 0
                ? std::clamp<int64_t>(mul_div_sat(
                    role_fill, Q16_ONE, role_slots, _saturation_count),
                    0, Q16_ONE) : Q16_ONE;
            actual_workforce_capacity_q16 = std::min(actual_workforce_capacity_q16,
                                              role_capacity);
        }
        constexpr int64_t forecast_workforce_capacity_q16 = Q16_ONE;
        // Suspended recovery must quote the counterfactual full-capacity lot.
        // Scaling living cost by the emptied workforce collapses both sides of
        // the margin to zero and permanently blocks restart after SUSPENDED_LOSS
        // releases owners into unemployment.
        const int64_t planning_workforce_capacity_q16 =
            group.operating_state == 1 ? forecast_workforce_capacity_q16
                                      : actual_workforce_capacity_q16;
        int64_t input_cost = 0;
        int64_t employee_wages = 0;
        const int64_t owner_living_cost_full = saturating_mul(
            living_cost_for_signature(group.cell, group.owner_signature_id, -1,
                                      _saturation_count),
            type.owner_slots_per_building, _saturation_count);
        const int64_t owner_living_cost = mul_div_sat(
            owner_living_cost_full, planning_workforce_capacity_q16, Q16_ONE,
            _saturation_count);
        int64_t revenue = 0;
        bool inputs_available = true;
        bool hard_input_market_available = true;
        for (int32_t i = 0; i < type.input_count; ++i) {
            const ProductionInput &item = _building_inputs[type.input_begin + i];
            // Soft inputs add a productivity bonus on top of the base recipe,
            // and production buys them only when the bonus output is worth
            // more than their outlay. The quote here prices base output only,
            // so billing a soft input would charge for a bonus never counted.
            if (std::clamp<int64_t>(item.required_q16, 0, Q16_ONE) < Q16_ONE)
                continue;
            int64_t best_effective_price = std::numeric_limits<int64_t>::max();
            for (int32_t c = item.candidate_begin;
                 c < item.candidate_begin + item.candidate_count; ++c) {
                const InputCandidate &candidate = _building_input_candidates[c];
                if (!good_input_candidate_available(group.cell, candidate.good_id, true)) continue;
                const int64_t physical_numerator = saturating_add(
                    saturating_mul(item.quantity, Q16_ONE, _saturation_count),
                    candidate.efficiency_q16 - 1, _saturation_count);
                const int64_t physical = effective_production_input_quantity(
                    group.cell, candidate.good_id,
                    physical_numerator / candidate.efficiency_q16,
                    _saturation_count);
                const int64_t candidate_cost = mul_div_sat(
                    physical,
                    market_store().price[market_store().index(market, candidate.good_id)],
                    GOODS_SCALE, _saturation_count);
                best_effective_price = std::min(best_effective_price, candidate_cost);
            }
            if (best_effective_price == std::numeric_limits<int64_t>::max()) {
                if (item.required_q16 >= Q16_ONE) {
                    hard_input_market_available = false;
                    inputs_available = false;
                    break;
                }
                continue;
            }
            input_cost = saturating_add(
                input_cost, best_effective_price, _saturation_count);
        }
        int64_t maintenance_cost = daily_maintenance_cost_for_type(
            group.cell, type, _saturation_count);
        if (maintenance_cost == std::numeric_limits<int64_t>::max())
            maintenance_cost = 0;
        if (!inputs_available) {
            group.sample_unit_input_cost = 0;
            group.sample_unit_maintenance_cost = 0;
            group.last_margin_gap_q16 = -Q16_ONE;
            group.planned_utilization_q16 = 0;
            // A hard input shortage blocks execution, but it must not erase
            // the downstream signal that can restart the upstream producer.
            // Keep a bounded, cash-backed probe in the transient planning
            // vector; production will still re-check stock and settle zero
            // output when the input is absent.
            int64_t structural_intent_q16 = 0;
            const int32_t owner_slot = find_cohort_slot(
                group.cell, group.owner_signature_id);
            if (type.kind != 2 && hard_input_market_available && owner_slot >= 0 &&
                    population_store().population[owner_slot] > 0 &&
                    group.operating_state == 0) {
                int64_t output_pressure_q16 = 0;
                bool has_output_gap = false;
                bool cycle_flow_output = false;
                for (int32_t i = 0; i < type.output_count; ++i) {
                    const int32_t good = _building_outputs[
                        type.output_begin + i].good_id;
                    if (good < 0 || good >= market_store().good_count.get()) continue;
                    cycle_flow_output = cycle_flow_output ||
                        _good_storage_modes[good] == 1;
                    const int32_t signal = market_signal_index(group.cell, good);
                    const int64_t business_demand = signal >= 0
                        ? std::max<int64_t>(0,
                            _market_signals.business_demand_ema[signal]) : 0;
                    const int64_t stock = std::max<int64_t>(0,
                        market_store().stock[market_store().index(market, good)]);
                    const int64_t demand_gap_q16 = business_demand > 0
                        ? std::clamp<int64_t>(mul_div_sat(
                            std::max<int64_t>(0, business_demand - stock),
                            Q16_ONE, std::max<int64_t>(business_demand, GOODS_SCALE),
                            _saturation_count), 0, Q16_ONE) : 0;
                    const int64_t household_shortage_q16 = std::clamp<int64_t>(
                        market_store().last_shortage_q16[market_store().index(market, good)],
                        0, Q16_ONE);
                    output_pressure_q16 = std::max(output_pressure_q16,
                        std::max(demand_gap_q16, household_shortage_q16));
                    has_output_gap = has_output_gap || demand_gap_q16 > 0 ||
                        household_shortage_q16 > 0;
                }
                if (has_output_gap) {
                    const int64_t probe_floor_q16 = cycle_flow_output
                        ? std::max<int64_t>(1, Q16_ONE / 6)
                        : std::max<int64_t>(1, Q16_ONE / 32);
                    structural_intent_q16 = std::clamp<int64_t>(
                        std::max(output_pressure_q16, probe_floor_q16),
                        0, Q16_ONE);
                    const int64_t period_input_cost = saturating_mul(
                        saturating_mul(std::max<int64_t>(0, input_cost),
                            std::max<int64_t>(1, group.count),
                            _saturation_count),
                        std::max(1, _epoch_days.get()), _saturation_count);
                    int64_t available_cash = std::max<int64_t>(0,
                        population_store().funds[owner_slot]);
                    for (int32_t k = _merchant_offsets[group.cell];
                         k < _merchant_offsets[group.cell + 1]; ++k) {
                        available_cash = saturating_add(available_cash,
                            std::max<int64_t>(0,
                                population_store().funds[_merchant_slots[k]]),
                            _saturation_count);
                    }
                    if (period_input_cost > 0) {
                        structural_intent_q16 = std::min<int64_t>(
                            structural_intent_q16,
                            std::clamp<int64_t>(mul_div_sat(
                                available_cash, Q16_ONE, period_input_cost,
                                _saturation_count), 0, Q16_ONE));
                    }
                }
            }
            group.purchase_intent_capacity_q16 = structural_intent_q16;
            const int32_t missing_input_index = static_cast<int32_t>(group.index);
            if (missing_input_index >= 0 && missing_input_index <
                    static_cast<int32_t>(
                        _building_planned_capacity_before_climate_q16.size())) {
                _building_planned_capacity_before_climate_q16[
                    missing_input_index] = structural_intent_q16;
            }
            group.recovery_cycles = 0;
            group.last_expected_revenue = 0;
            group.last_quoted_market_receipt = 0;
            group.last_quoted_operating_cost = 0;
            group.last_maintenance_due = 0;
            if (type.kind != 2 && group.operating_state == 2) {
                group.operating_state = 1;
                group.pending_operating_state = 255;
                invalidate_cell_monetary_units(group.cell);
            }
            // Missing a technologically available hard input is a recoverable
            // execution blockage, not evidence of a realized operating loss.
            // Keep the installed group active/idle so it retains a labor claim
            // and can resume as soon as the input chain supplies it.
            if (type.kind != 2 && group.operating_state == 0)
                group.severe_loss_cycles = 0;
            if (group.operating_state != 0) ++_loss_suspended_building_groups;
            continue;
        }
        for (int32_t r = 0; r < type.employee_count; ++r) {
            const JobRole &role = _building_employee_roles[type.employee_begin + r];
            const int32_t role_index = group.employee_fill_begin + r;
            const int64_t wage = role_index >= 0 &&
                role_index < static_cast<int32_t>(_building_role_contract_wage.size())
                    ? _building_role_contract_wage[role_index]
                    : 0;
            const int32_t filled_index = role_index;
            const int64_t filled = filled_index >= 0 && filled_index <
                    static_cast<int32_t>(_building_employee_filled.size())
                ? std::max<int64_t>(0, _building_employee_filled[filled_index]) : 0;
            // Recovery quotes the full roster; staffed quotes use current fill.
            const int64_t wage_heads = group.operating_state == 1
                ? saturating_mul(group.count, role.slots_per_building,
                    _saturation_count)
                : filled;
            employee_wages = saturating_add(employee_wages, saturating_mul(
                wage_heads, wage, _saturation_count), _saturation_count);
        }
        for (int32_t i = 0; i < type.output_count; ++i) {
            const GoodAmount &item = _building_outputs[type.output_begin + i];
            int64_t settlement = _good_monetary_issue_values[item.good_id];
            if (settlement > 0) {
                // Monetary income is face × quantity. Never rewrite settlement
                // from the cell bullion pool — a rich merchant's cash weight
                // used to inflate expected revenue far above face×output.
            } else {
                const int32_t output_signal = market_signal_index(
                    group.cell, item.good_id);
                const int32_t output_flow = trade_flow_index(
                    group.cell, item.good_id, false);
                const int64_t output_target = merchant_inventory_target(
                    market, item.good_id, output_signal,
                    output_signal >= 0 ? _market_signals.realized_withdrawal_ema[
                        output_signal] : 0,
                    output_flow >= 0 ? _trade_flows.export_ema[output_flow] : 0,
                    item.quantity, _saturation_count);
                const int32_t buy_factor = effective_merchant_buy_factor_q16(
                    market, item.good_id, output_target,
                    market_store().stock[market_store().index(market, item.good_id)],
                    _saturation_count);
                settlement = mul_div_sat(
                    market_store().price[market_store().index(market, item.good_id)],
                    buy_factor, Q16_ONE, _saturation_count);
            }
            revenue = saturating_add(revenue, mul_div_sat(
                item.quantity, settlement, GOODS_SCALE, _saturation_count),
                _saturation_count);
        }
        // Keep a full-capacity daily quote separate from the current staffed
        // quote. The latter is used for margin gating; the former is used at
        // the end of the plan to apply the effective execution scale exactly
        // once. Mixing the two double-counts workforce when utilization is
        // below nameplate capacity.
        int64_t full_capacity_revenue = revenue;
        revenue = mul_div_sat(full_capacity_revenue, forecast_workforce_capacity_q16,
                              Q16_ONE, _saturation_count);
        // Active lots forecast from committed cash receipts. Suspended lots keep
        // the nameplate counterfactual above: in-kind self-employment often has
        // zero market/bullion receipts, and observing that zero would make every
        // restart margin fail after owners are shed.
        if (observed_capacity && group.operating_state != 1) {
            // Installed groups forecast from the previous committed receipt,
            // normalized by the observed workforce-capacity-days. A zero
            // receipt therefore remains zero; it cannot fall back to a stale
            // nameplate quote or a frozen commodity price.
            // Economic receipts include both cash settlement and the market
            // value of output consumed in kind by the owner household.  A
            // survival producer can legitimately receive zero cash while its
            // retained food fully pays for the owner's livelihood; treating
            // that period as zero revenue creates a self reinforcing shutdown.
            const int64_t observed_sales = saturating_add(
                saturating_add(std::max<int64_t>(0, group.last_market_receipt),
                               std::max<int64_t>(0, group.last_bullion_mint_receipt),
                               _saturation_count),
                std::max<int64_t>(0, group.last_producer_support_receipt),
                _saturation_count);
            const int64_t observed_in_kind = std::max<int64_t>(
                0, group.last_in_kind_livelihood_value);
            // `last_observed_capacity_days_q16` already contains the prior
            // group count, elapsed days, and Q16 workforce share. Convert
            // the receipt to a full-capacity per-building-day quote here;
            // apply the current effective scale only once below.
            //
            // Production ran at min(workforce, previous plan). Sales scale
            // with that chosen activity, so divide it back out; otherwise a
            // group parked on its survival floor reads its own throttling as
            // low prices and never quotes a profitable full run again. In-kind
            // retention is capped by the owner basket, so it is not scaled.
            const int64_t observed_days = std::max<int64_t>(
                1, group.last_observed_capacity_days_q16);
            const int64_t observed_workforce_q16 = std::clamp<int64_t>(
                observed_days / std::max<int64_t>(1, saturating_mul(
                    group.count, std::max(1, _epoch_days.get()),
                    _saturation_count)), 0, Q16_ONE);
            const int64_t previous_plan_q16 = group_index >= 0 &&
                    group_index < static_cast<int32_t>(
                        _building_planned_capacity_before_climate_q16.size())
                ? std::clamp<int64_t>(
                    _building_planned_capacity_before_climate_q16[group_index],
                    0, Q16_ONE)
                : Q16_ONE;
            // A zero plan observed nothing about prices; a tiny probe floor
            // is capped so one noisy sale cannot be amplified without bound.
            const int64_t chosen_activity_share_q16 = previous_plan_q16 > 0 &&
                    observed_workforce_q16 > 0 &&
                    previous_plan_q16 < observed_workforce_q16
                ? std::max<int64_t>(Q16_ONE / 32, mul_div_sat(
                    previous_plan_q16, Q16_ONE, observed_workforce_q16,
                    _saturation_count))
                : Q16_ONE;
            full_capacity_revenue = group.last_observed_capacity_days_q16 > 0
                ? saturating_add(
                    mul_div_sat(observed_sales, Q16_ONE,
                        std::max<int64_t>(1, mul_div_sat(observed_days,
                            chosen_activity_share_q16, Q16_ONE,
                            _saturation_count)),
                        _saturation_count),
                    mul_div_sat(observed_in_kind, Q16_ONE, observed_days,
                        _saturation_count),
                    _saturation_count)
                : 0;
            revenue = mul_div_sat(full_capacity_revenue,
                                  forecast_workforce_capacity_q16, Q16_ONE,
                                  _saturation_count);
        }
        const int64_t operating = saturating_add(saturating_add(
            saturating_add(input_cost, employee_wages, _saturation_count),
            owner_living_cost, _saturation_count),
            maintenance_cost, _saturation_count);
        const int64_t required = saturating_add(operating, mul_div_sat(
            operating, type.target_operating_margin_q16, Q16_ONE,
            _saturation_count), _saturation_count);
        int64_t margin_gap = required <= 0 ? (revenue > 0 ? Q16_ONE : 0) :
            mul_div_sat(saturating_sub(revenue, required, _saturation_count), Q16_ONE,
                        std::max<int64_t>(MONEY_SCALE, required), _saturation_count);
        margin_gap = std::clamp<int64_t>(margin_gap, -Q16_ONE, Q16_ONE);
        int64_t expected_profit_margin = operating <= 0 ? (revenue > 0 ? Q16_ONE : 0) :
            mul_div_sat(saturating_sub(revenue, operating, _saturation_count), Q16_ONE,
                        std::max<int64_t>(MONEY_SCALE, operating), _saturation_count);
        // Owners and employees evaluate the same after-tax operating cash that
        // production will settle. Positive business tax is a deductible cost;
        // negative business tax is a cost reimbursement and negative income tax
        // is valued only at the funded fiscal fulfillment ratio.
        const int32_t expected_business_rate = frozen_tax_rate(
            group.cell, CountryApi::TAX_BUSINESS, group.type_id);
        const int64_t expected_business_eligible_cost = saturating_add(
            saturating_add(input_cost, employee_wages, _saturation_count),
            maintenance_cost, _saturation_count);
        const int64_t expected_business_base = expected_business_rate < 0
            ? expected_business_eligible_cost : std::max<int64_t>(0, revenue);
        const int64_t expected_business_transfer =
            expected_resolved_fiscal_transfer(
                group.cell, CountryApi::TAX_BUSINESS, group.type_id,
                expected_business_base, 1, _saturation_count);
        // Income tax excludes owner livelihood from the tax base. Business
        // tax is deductible only when positive; a business subsidy is a
        // transfer and must not recursively increase taxable income.
        const int64_t expected_income_base = std::max<int64_t>(0,
            saturating_sub(saturating_sub(
                revenue, expected_business_eligible_cost, _saturation_count),
                std::max<int64_t>(0, expected_business_transfer),
                _saturation_count));
        const int32_t expected_income_rate = frozen_tax_rate(
            group.cell, CountryApi::TAX_INCOME,
            type.owner_profession_id);
        const int64_t expected_income_transfer =
            expected_resolved_fiscal_transfer(
                group.cell, CountryApi::TAX_INCOME,
                type.owner_profession_id,
                expected_income_rate < 0
                    ? std::max<int64_t>(expected_income_base, owner_living_cost)
                    : expected_income_base,
                1, _saturation_count);
        const int64_t expected_after_tax_profit = saturating_sub(
            saturating_sub(saturating_sub(revenue, operating,
                _saturation_count), expected_business_transfer,
                _saturation_count), expected_income_transfer,
            _saturation_count);
        expected_profit_margin = operating <= 0
            ? (expected_after_tax_profit > 0 ? Q16_ONE : 0)
            : mul_div_sat(expected_after_tax_profit, Q16_ONE,
                std::max<int64_t>(MONEY_SCALE, operating), _saturation_count);
        expected_profit_margin = std::clamp<int64_t>(
            expected_profit_margin, -Q16_ONE, Q16_ONE);
        group.sample_unit_input_cost = input_cost;
        group.sample_unit_maintenance_cost = maintenance_cost;
        group.last_margin_gap_q16 = static_cast<int32_t>(margin_gap);
        bool suspended_now = false;
        if (type.kind != 2 && group.operating_state == 0) {
            // 停业沿用实际经营收支；业主生活成本属于岗位机会评价。
            // 不可把单座单日生活报价加到整组已结算的成本中。
            const bool settled_production = group.last_output > 0 ||
                group.last_resource_generated > 0 ||
                (type.employee_count == 0 && type.input_count == 0 &&
                 type.resource_count == 0 && group.filled_owner > 0 &&
                 owner_living_cost > 0);
            const int64_t owner_business_income = saturating_add(
                group.last_revenue,
                std::max<int64_t>(0, group.last_in_kind_livelihood_value),
                _saturation_count);
            const int64_t owner_business_cost = saturating_add(
                saturating_add(group.last_input_cost,
                    group.last_base_wages_due, _saturation_count),
                group.last_maintenance_cost, _saturation_count);
            const int64_t realized_taxable_cost = saturating_add(
                saturating_add(group.last_input_cost, group.last_base_wages_paid,
                    _saturation_count),
                group.last_maintenance_cost, _saturation_count);
            const int32_t realized_business_rate = frozen_tax_rate(
                group.cell, CountryApi::TAX_BUSINESS,
                group.type_id);
            // Fiscal bases follow realized cash, while lifecycle viability still
            // includes wage obligations through owner_business_cost.
            const int64_t realized_business_eligible_cost = realized_taxable_cost;
            const int64_t absolute_building_days = saturating_mul(
                group.count, std::max<int64_t>(1, _epoch_days.get()),
                _saturation_count);
            const int64_t realized_business_transfer = realized_business_rate < 0
                ? expected_resolved_fiscal_transfer(
                    group.cell, CountryApi::TAX_BUSINESS,
                    group.type_id, realized_business_eligible_cost,
                    absolute_building_days, _saturation_count)
                : 0;
            const bool positive_self_employment = type.employee_count == 0 &&
                saturating_add(owner_business_income,
                    std::max<int64_t>(0, -realized_business_transfer),
                    _saturation_count) > owner_business_cost;
            const int32_t realized_profession = group.owner_signature_id >= 0 &&
                    group.owner_signature_id < static_cast<int32_t>(_signatures.size())
                ? _signatures[group.owner_signature_id].profession_id : -1;
            const int32_t realized_income_rate = frozen_tax_rate(
                group.cell, CountryApi::TAX_INCOME,
                realized_profession);
            const int64_t realized_income_base = std::max<int64_t>(0,
                saturating_sub(group.last_revenue, realized_taxable_cost,
                    _saturation_count));
            const int64_t absolute_owner_days = saturating_mul(
                std::max<int64_t>(1, group.count),
                std::max<int64_t>(1, _epoch_days.get()), _saturation_count);
            const int64_t realized_income_transfer =
                expected_resolved_fiscal_transfer(
                    group.cell, CountryApi::TAX_INCOME,
                    realized_profession,
                    realized_income_rate < 0
                        ? std::max<int64_t>(realized_income_base, owner_living_cost)
                        : realized_income_base,
                    absolute_owner_days, _saturation_count);
            const int64_t realized_after_tax_profit = saturating_sub(
                saturating_sub(
                    // Retained output pays owner livelihood in kind. Include
                    // the same income used by the self-employment gate above;
                    // cash-only profit falsely suspends subsistence producers.
                    saturating_sub(owner_business_income, owner_business_cost,
                        _saturation_count), realized_business_transfer,
                    _saturation_count),
                realized_income_transfer, _saturation_count);
            const int64_t realized_after_tax_margin = mul_div_sat(
                realized_after_tax_profit, Q16_ONE,
                std::max<int64_t>(MONEY_SCALE, owner_business_cost),
                _saturation_count);
            const bool realized_severe_loss = settled_production &&
                !positive_self_employment &&
                realized_after_tax_margin <= _building_severe_loss_threshold_q16.get();
            if (realized_severe_loss) {
                // Count consecutive observed owner losses. A single settled loss
                // must remain visible to employment and audit while the configured
                // hysteresis threshold decides when the group is suspended.
                const int32_t threshold = std::max(1, _building_severe_loss_cycles.get());
                group.severe_loss_cycles = static_cast<uint16_t>(std::min<int32_t>(
                    threshold, static_cast<int32_t>(group.severe_loss_cycles) + 1));
                if (group.severe_loss_cycles >= threshold) {
                    group.operating_state = 1;
                    group.recovery_cycles = 0;
                    suspended_now = true;
                    invalidate_cell_monetary_units(group.cell);
                }
            } else {
                // Zero settlement covers labor, input, resource and financing
                // blockages. None is a realized loss observation.
                group.severe_loss_cycles = 0;
            }
            group.pending_operating_state = 255;
            group.recovery_cooldown_cycles = 0;
            if (!suspended_now && group.severe_loss_cycles >= _building_severe_loss_cycles.get()) {
                group.operating_state = 1;
                group.recovery_cycles = 0;
                suspended_now = true;
                invalidate_cell_monetary_units(group.cell);
            }
        }
