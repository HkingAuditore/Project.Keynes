        for (int32_t ethnicity = 0; ethnicity < static_cast<int32_t>(
                _ethnicity_ids.size()); ++ethnicity) {
            ++_investment_ethnicity_evaluations;
            const int32_t target_signature = signature_for_profession_ethnicity(
                type.owner_profession_id, ethnicity);
            if (target_signature < 0) continue;
            const int64_t living_cost = investment_living_cost(target_signature, _saturation_count);
            const int64_t owner_livelihood = saturating_mul(
                living_cost, std::max<int64_t>(1,
                    type.owner_slots_per_building), _saturation_count);
            int64_t daily_cash_revenue = 0;
            int64_t daily_merchant_cash_revenue = 0;
            int64_t daily_producer_support_revenue = 0;
            int64_t monetary_request_money_per_day = 0;
            int64_t monetary_expected_revenue_per_day = 0;
            int64_t daily_in_kind_livelihood = 0;
            int64_t driver_absorption_q16 = 0;
            for (int32_t i = 0; i < type.output_count; ++i) {
                const GoodAmount &output =
                    _building_outputs[type.output_begin + i];
                const OutputInvestmentSignal &output_signal = output_signals[i];
                const int64_t research_demand =
                    epoch_procurement_demand_daily(cell, output.good_id);
                const int64_t prospective_quantity =
                    effective_building_output_quantity_for_target(
                        cell, type_id, target_signature,
                        output.good_id, output.quantity, throughput_q16, 1,
                        _saturation_count);
                const int64_t retail_price = market_store().price[
                    market_store().index(market, output.good_id)];
                int64_t retained_quantity = 0;
                if (prospective_quantity > 0 && retail_price > 0 &&
                    (_survival_food_good_mask[output.good_id] != 0 ||
                     _survival_clothing_good_mask[output.good_id] != 0)) {
                    const int64_t livelihood_gap = std::max<int64_t>(0,
                        owner_livelihood - daily_in_kind_livelihood);
                    retained_quantity = std::min(prospective_quantity,
                        saturating_add(saturating_mul(livelihood_gap,
                            GOODS_SCALE, _saturation_count), retail_price - 1,
                            _saturation_count) / retail_price);
                    const int64_t retained_value = std::min(livelihood_gap,
                        mul_div_sat(retained_quantity, retail_price,
                            GOODS_SCALE, _saturation_count));
                    daily_in_kind_livelihood = saturating_add(
                        daily_in_kind_livelihood, retained_value,
                        _saturation_count);
                }
                const int64_t sellable_quantity = std::max<int64_t>(
                    0, prospective_quantity - retained_quantity);
                const int64_t issue_value =
                    _good_monetary_issue_values[output.good_id];
                const bool government_research_output =
                    output.good_id == _epoch_research_good_id &&
                    research_demand > 0;
                int64_t absorption_q16 = 0;
                if (issue_value > 0 && sellable_quantity > 0) {
                    // Face × sellable output. Investment must not treat the
                    // cell bullion pool as a demand ceiling.
                    absorption_q16 = Q16_ONE;
                }
                if (issue_value <= 0 && government_research_output &&
                    sellable_quantity > 0) {
                    // Government research procurement is a cash-backed
                    // buyer even before the first producer exists. Use
                    // only the demand-covered share so a large research
                    // institution cannot project revenue from points the
                    // country has neither queued nor budgeted.
                    absorption_q16 = std::min<int64_t>(Q16_ONE,
                        mul_div_sat(research_demand, Q16_ONE,
                            sellable_quantity, _saturation_count));
                } else if (issue_value <= 0 && output_signal.sellable > 0) {
                    absorption_q16 = output_signal.sell_through_q16;
                    // Installed producers can still face a real deficit
                    // with a 0 sell-through print (quota/cash timing).
                    // Restrict the deficit fallback to types that already
                    // have a local group so greenfield challengers keep
                    // using the normal absorption path.
                    if (absorption_q16 <= 0 && output_signal.deficit > 0 &&
                        sellable_quantity > 0 &&
                        (existing != nullptr || cell_request.reason ==
                            INVESTMENT_REQUEST_EMPLOYMENT_CATCHUP)) {
                        absorption_q16 = std::clamp<int64_t>(mul_div_sat(
                            output_signal.deficit, Q16_ONE, sellable_quantity,
                            _saturation_count), 0, Q16_ONE);
                    }
                } else if (issue_value <= 0 && sellable_quantity > 0) {
                    absorption_q16 = std::clamp<int64_t>(mul_div_sat(
                        output_signal.deficit, Q16_ONE, sellable_quantity,
                        _saturation_count), 0, Q16_ONE);
                }
                if (i == driver_index)
                    driver_absorption_q16 = absorption_q16;
                const int64_t absorbed_quantity = mul_div_sat(
                    sellable_quantity, absorption_q16, Q16_ONE,
                    _saturation_count);
                const int64_t settlement_price = issue_value > 0
                    ? issue_value
                    : government_research_output ? retail_price
                    : mul_div_sat(retail_price,
                        _good_merchant_buy_factor_q16[output.good_id], Q16_ONE,
                        _saturation_count);
                const int64_t merchant_revenue = mul_div_sat(
                    absorbed_quantity, settlement_price, GOODS_SCALE,
                    _saturation_count);
                daily_merchant_cash_revenue = saturating_add(
                    daily_merchant_cash_revenue, merchant_revenue,
                    _saturation_count);
                // Production settlement sends the sellable remainder to
                // producer support after merchant procurement.
                const int64_t support_quantity = issue_value > 0 ? 0 :
                    std::max<int64_t>(0,
                        sellable_quantity - absorbed_quantity);
                daily_producer_support_revenue = saturating_add(
                    daily_producer_support_revenue,
                    producer_support_receipt_value(cell, output.good_id,
                        support_quantity, _saturation_count),
                    _saturation_count);
                daily_cash_revenue = saturating_add(
                    daily_merchant_cash_revenue,
                    daily_producer_support_revenue, _saturation_count);
                if (issue_value > 0) {
                    monetary_request_money_per_day = saturating_add(
                        monetary_request_money_per_day,
                        mul_div_sat(sellable_quantity, issue_value,
                            GOODS_SCALE, _saturation_count),
                        _saturation_count);
                    monetary_expected_revenue_per_day = saturating_add(
                        monetary_expected_revenue_per_day,
                        mul_div_sat(absorbed_quantity, settlement_price,
                            GOODS_SCALE, _saturation_count),
                        _saturation_count);
                }
            }
            if (service_post && service_owner_income_per_day > 0) {
                // Merchant seat income, already net of income tax at
                // settlement. It funds wages and owner livelihood exactly like
                // a goods receipt so the margin gates below read one number.
                daily_cash_revenue = saturating_add(daily_cash_revenue,
                    service_owner_income_per_day, _saturation_count);
            }
            // Let the same expected revenue that drives the investment
            // decision fund a bounded profit share for labour.  This keeps
            // investment from pricing a scarce role at an obsolete catalog
            // wage while preserving the living-cost and market floors.
            const int64_t employee_slots = [&]() {
                int64_t total = 0;
                for (int32_t r = 0; r < type.employee_count; ++r)
                    total = saturating_add(total,
                        _building_employee_roles[type.employee_begin + r].slots_per_building,
                        _saturation_count);
                return total;
            }();
            const int64_t wage_profit_pool = std::max<int64_t>(0,
                saturating_sub(daily_cash_revenue,
                    saturating_add(daily_input_cost, daily_maintenance,
                        _saturation_count), _saturation_count));
            const int64_t profit_share_per_employee = employee_slots > 0
                ? mul_div_sat(wage_profit_pool, Q16_ONE / 4,
                    saturating_mul(employee_slots, Q16_ONE,
                        _saturation_count), _saturation_count) : 0;
            daily_wages = 0;
            for (int32_t r = 0; r < type.employee_count; ++r) {
                const JobRole &role = _building_employee_roles[
                    type.employee_begin + r];
                const int32_t signal = labor_signal_index(cell,
                    role.profession_id);
                const int64_t living_floor = signal >= 0
                    ? std::max(_labor_signals.base_living_cost[signal],
                        _labor_signals.role_living_cost[signal]) : 0;
                const int64_t market_quote = signal >= 0 && signal <
                        static_cast<int32_t>(_labor_signals.contract_wage_ema.size())
                    ? std::max(_labor_signals.contract_wage_ema[signal],
                        _labor_signals.paid_wage_ema[signal]) : 0;
                const int64_t wage = std::max({living_floor, market_quote,
                    profit_share_per_employee});
                daily_wages = saturating_add(daily_wages,
                    saturating_mul(role.slots_per_building, wage,
                        _saturation_count), _saturation_count);
            }
            quoted_daily_variable_cost = mul_div_sat(saturating_add(
                saturating_add(daily_input_cost, daily_wages, _saturation_count),
                daily_maintenance, _saturation_count), utilization_q16,
                Q16_ONE, _saturation_count);
            int64_t daily_variable_cost = quoted_daily_variable_cost;
            int64_t daily_after_tax_cash_revenue = daily_cash_revenue;
            const uint8_t investment_tax_mask = static_cast<uint8_t>(
                (1U << CountryApi::TAX_INCOME) |
                (1U << CountryApi::TAX_BUSINESS));
            if ((_epoch_active_tax_mask & investment_tax_mask) != 0) {
                const int64_t eligible_cost_base = mul_div_sat(
                    saturating_add(saturating_add(
                        daily_input_base_cost, daily_wages,
                        _saturation_count), daily_maintenance,
                        _saturation_count),
                    utilization_q16, Q16_ONE, _saturation_count);
                const BuildingTaxQuote tax_quote =
                    expected_building_tax_quote(
                        cell, type_id, type.owner_profession_id,
                        daily_merchant_cash_revenue,
                        daily_producer_support_revenue,
                        eligible_cost_base, daily_variable_cost,
                        owner_livelihood, 1, 1, _saturation_count);
                daily_after_tax_cash_revenue = tax_quote.after_tax_cash;
                if (service_post && service_owner_income_per_day > 0) {
                    // The tax quote prices goods receipts only, and the retail
                    // pool was already taxed when the market settled it. Add
                    // it back so the income gate does not read zero again.
                    daily_after_tax_cash_revenue = saturating_add(
                        daily_after_tax_cash_revenue,
                        service_owner_income_per_day, _saturation_count);
                }
            }
            // Incumbent expansion: forecast the marginal building from
            // revealed local unit economics so soft-input stock quotes
            // cannot contradict already-settled same-type camps.
            if (existing != nullptr && existing->active_count > 0 &&
                existing->sum_last_output > 0 && revealed_util_q16 > 0) {
                const int64_t days = std::max<int64_t>(1, _epoch_days.get());
                const int64_t buildings = existing->active_count;
                const int64_t unit_cash = existing->sum_last_revenue /
                    buildings / days;
                const int64_t unit_inkind =
                    existing->sum_last_in_kind_livelihood /
                    buildings / days;
                const int64_t unit_var =
                    saturating_add(saturating_add(
                        existing->sum_last_input_cost,
                        existing->sum_last_base_wages_due,
                        _saturation_count),
                        existing->sum_last_maintenance_cost,
                        _saturation_count) / buildings / days;
                int64_t absorption_q16 = driver_absorption_q16;
                if (absorption_q16 <= 0 && driver.good_id >= 0) {
                    absorption_q16 = std::max<int64_t>(
                        driver.sell_through_q16,
                        driver.deficit > 0 && driver.nameplate_output > 0
                            ? std::clamp<int64_t>(mul_div_sat(
                                driver.deficit, Q16_ONE,
                                driver.nameplate_output, _saturation_count),
                                0, Q16_ONE)
                            : 0);
                }
                absorption_q16 = std::clamp<int64_t>(absorption_q16, 0, Q16_ONE);
                daily_after_tax_cash_revenue = mul_div_sat(
                    unit_cash, absorption_q16, Q16_ONE, _saturation_count);
                daily_cash_revenue = daily_after_tax_cash_revenue;
                daily_in_kind_livelihood = std::min(unit_inkind,
                    owner_livelihood);
                daily_variable_cost = unit_var;
                monetary_expected_revenue_per_day =
                    daily_after_tax_cash_revenue;
            }
            const int64_t daily_economic_revenue = saturating_add(
                daily_after_tax_cash_revenue, daily_in_kind_livelihood,
                _saturation_count);
            const int64_t daily_operating_cost = saturating_add(
                daily_variable_cost, owner_livelihood, _saturation_count);
            const int64_t required_revenue = saturating_add(
                daily_operating_cost, mul_div_sat(daily_operating_cost,
                    type.target_operating_margin_q16, Q16_ONE,
                    _saturation_count), _saturation_count);
            const int64_t daily_profit = saturating_sub(
                daily_economic_revenue, daily_operating_cost,
                _saturation_count);
            const int64_t daily_net_owner_income = saturating_sub(
                daily_economic_revenue, daily_variable_cost,
                _saturation_count);
            const int64_t owner_slots = std::max<int64_t>(1,
                type.owner_slots_per_building);
            // Zero-material self-employed entry collectors require no upfront
            // construction or hired wages. When local unemployed labor exists
            // and the building produces positive net owner income, defer to
            // opportunity-cost sponsor matching instead of requiring full
            // theoretical owner_livelihood before unemployed people may work.
            const bool zero_build_self_employed_unemployed_fallback =
                entry_zero_build_margin_exempt &&
                type.employee_count == 0 &&
                ctx.cell_unemployed >= owner_slots &&
                daily_net_owner_income > 0;
            const bool sub_livelihood_fallback =
                daily_economic_revenue < daily_operating_cost &&
                zero_build_self_employed_unemployed_fallback;
            // Preserve the economic quote even when a candidate is
            // rejected by a downstream livelihood/margin gate. The
            // inspector uses this to distinguish a real unprofitable
            // catch-up lane from a missing sponsor/material lane.
            if (diagnostic != nullptr) {
                diagnostic->projected_profit_per_day = daily_profit;
            }
            if (daily_economic_revenue < daily_operating_cost &&
                !sub_livelihood_fallback) {
                reject(INVESTMENT_REJECTION_OWNER_LIVELIHOOD);
                continue;
            }
            if ((daily_profit <= 0 && !sub_livelihood_fallback) ||
                (daily_economic_revenue < required_revenue &&
                 !entry_zero_build_margin_exempt)) {
                reject(INVESTMENT_REJECTION_TARGET_MARGIN);
                continue;
            }
            const int64_t margin_q16 = sub_livelihood_fallback
                ? std::max<int64_t>(1, mul_div_sat(daily_net_owner_income,
                    Q16_ONE / 16, std::max<int64_t>(1, daily_operating_cost),
                    _saturation_count))
                : (daily_operating_cost > 0
                    ? mul_div_sat(daily_profit, Q16_ONE,
                        daily_operating_cost, _saturation_count)
                    : Q16_ONE);
            // Investment and employment compare one building's economic
            // signal. Self-use value remains in that same total; do not
            // dilute it by the number of owner slots.
            const int64_t projected_owner_income = saturating_add(
                std::max<int64_t>(0, saturating_sub(
                    daily_after_tax_cash_revenue, daily_variable_cost,
                    _saturation_count)),
                daily_in_kind_livelihood, _saturation_count);
            const int64_t effective_owner_startup_days =
                zero_build_self_employed_unemployed_fallback ? 0 : owner_startup_days;
            const int64_t required_capital = saturating_add(construction_cost,
                saturating_add(saturating_mul(daily_input_cost,
                    _investment_operating_cycles.get() * std::max(1, _epoch_days.get()),
                    _saturation_count), saturating_add(saturating_mul(
                        daily_wages, std::max(1, _epoch_days.get()), _saturation_count),
                        saturating_add(saturating_mul(owner_livelihood,
                            effective_owner_startup_days, _saturation_count),
                            saturating_mul(daily_maintenance, owner_startup_days,
                                _saturation_count),
                            _saturation_count),
                        _saturation_count), _saturation_count), _saturation_count);
            if (diagnostic != nullptr) {
                diagnostic->required_capital = required_capital;
                diagnostic->projected_profit_per_day = daily_profit;
                diagnostic->monetary_quota_initial = 0;
                diagnostic->monetary_quota_daily = 0;
                diagnostic->monetary_units = 0;
                diagnostic->monetary_candidate_slots = 0;
                diagnostic->monetary_request_money_per_day =
                    monetary_request_money_per_day;
                diagnostic->monetary_expected_revenue_per_day =
                    monetary_expected_revenue_per_day;
                // Publish the first shared quote/plan record.  The
                // legacy diagnostic fields remain populated for existing
                // UI/CSV consumers, while new callers can consume one
                // normalized economic decomposition.
                EconomicOpportunityQuote &quote =
                    diagnostic->opportunity_quote;
                quote.cell = cell;
                quote.type_id = type_id;
                quote.owner_signature_id = target_signature;
                quote.utilization_q16 = throughput_q16;
                quote.owner_use_value_per_day = daily_in_kind_livelihood;
                quote.cash_revenue_per_day = daily_after_tax_cash_revenue;
                quote.merchant_revenue_per_day = daily_merchant_cash_revenue;
                quote.producer_support_revenue_per_day =
                    daily_producer_support_revenue;
                quote.economic_revenue_per_day = daily_economic_revenue;
                quote.input_cost_per_day = daily_input_cost;
                quote.wage_cost_per_day = daily_wages;
                quote.maintenance_cost_per_day = daily_maintenance;
                quote.owner_living_cost_per_day = owner_livelihood;
                quote.after_tax_revenue_per_day = daily_after_tax_cash_revenue;
                quote.profit_per_day = daily_profit;
                quote.affordable_wage_per_day = employee_slots > 0
                    ? mul_div_sat(std::max<int64_t>(0, wage_profit_pool),
                        Q16_ONE, employee_slots, _saturation_count) : 0;
                quote.owner_slots = type.owner_slots_per_building;
                quote.employee_slots = employee_slots;
                quote.owner_jobs_filled = type.owner_slots_per_building;
                quote.employee_jobs_filled = employee_slots;
                InvestmentCandidatePlan &plan = diagnostic->candidate_plan;
                plan.cell = cell;
                plan.type_id = type_id;
                plan.owner_signature_id = target_signature;
                plan.utilization_q16 = throughput_q16;
                plan.construction_cost = construction_cost;
                plan.required_capital = required_capital;
                plan.target_profit_per_day = daily_profit;
                plan.target_return_on_capital_q16 = 0;
                plan.employee_slots = employee_slots;
                plan.owner_slots = type.owner_slots_per_building;
                plan.material_good_ids = material_plan.good_ids;
                plan.material_quantities = material_plan.quantities;
                plan.quote = quote;
            }
            const int64_t effective_daily_return = daily_profit > 0
                ? daily_profit
                : (sub_livelihood_fallback ? daily_net_owner_income : 0);
            const int64_t payback = effective_daily_return > 0
                ? (required_capital + effective_daily_return - 1) / effective_daily_return
                : std::numeric_limits<int64_t>::max();
            const int64_t return_on_capital_q16 = sub_livelihood_fallback
                ? margin_q16
                : (daily_profit > 0
                    ? mul_div_sat(daily_profit, Q16_ONE,
                        std::max<int64_t>(1, required_capital),
                        _saturation_count)
                    : 0);
            const int64_t cost_advantage_q16 = incumbent_unit_cost > 0 &&
                    challenger_unit_cost < incumbent_unit_cost
                ? mul_div_sat(incumbent_unit_cost - challenger_unit_cost,
                    Q16_ONE, incumbent_unit_cost, _saturation_count)
                : 0;
            if (diagnostic != nullptr) {
                diagnostic->return_on_capital_q16 =
                    return_on_capital_q16;
                diagnostic->cost_advantage_q16 = cost_advantage_q16;
                diagnostic->candidate_plan.payback_days = payback;
                diagnostic->candidate_plan.target_return_on_capital_q16 =
                    return_on_capital_q16;
            }
            const bool displacement_candidate = stealable > 0 &&
                cost_advantage_q16 > 0;
            if (payback > _investment_max_payback_days.get() &&
                !displacement_candidate) {
                reject(INVESTMENT_REJECTION_PAYBACK);
                continue;
            }
            bool had_eligible_sponsor = false;
            int64_t sponsor_capital = required_capital;
            int64_t merchant_credit = 0;
            int64_t willing_population = 0;
            int64_t transferable_capital = 0;
            int64_t income_improvement_q16 = 0;
            uint64_t sponsor_family_handle = 0;
            const int64_t sponsor_target_income = sub_livelihood_fallback
                ? std::max<int64_t>(1, daily_net_owner_income / owner_slots)
                : std::max<int64_t>(1, projected_owner_income);
            int32_t sponsor = find_entrepreneur_source(
                cell, target_signature, required_capital,
                sponsor_target_income, living_cost,
                owner_slots,
                type_id, had_eligible_sponsor, willing_population,
                transferable_capital, income_improvement_q16,
                sponsor_family_handle, &investment_living_cost_cache);
            bool uses_merchant_credit = false;
            if (sponsor < 0 && _merchant_credit_runtime_mode.get() == 2 &&
                construction_cost > 0) {
                const int64_t merchant_cash =
                    investment_merchant_cash(cell);
                const int64_t outstanding =
                    investment_outstanding_credit(cell);
                const int64_t exposure = mul_div_sat(
                    merchant_cash, _merchant_credit_exposure_q16.get(),
                    Q16_ONE, _saturation_count);
                const int64_t reserve = mul_div_sat(
                    merchant_cash, _merchant_procurement_cash_reserve_q16.get(),
                    Q16_ONE, _saturation_count);
                const int64_t available_credit = std::max<int64_t>(0, std::min(
                    exposure - std::min(exposure, outstanding),
                    merchant_cash - std::min(merchant_cash, reserve)));
                if (available_credit >= construction_cost) {
                    // Credit may fund the bounded startup reserve as well as
                    // construction during employment catch-up. Ordinary
                    // reviews retain the existing construction-only credit
                    // contract.
                    const int64_t credit_cover = cell_request.reason ==
                            INVESTMENT_REQUEST_EMPLOYMENT_CATCHUP
                        ? std::min(required_capital, available_credit)
                        : construction_cost;
                    sponsor_capital = std::max<int64_t>(
                        0, required_capital - credit_cover);
                    bool credit_sponsor_eligible = false;
                    sponsor = find_entrepreneur_source(
                        cell, target_signature, sponsor_capital,
                        std::max<int64_t>(1, projected_owner_income), living_cost,
                        std::max<int64_t>(1, type.owner_slots_per_building),
                        type_id, credit_sponsor_eligible, willing_population,
                        transferable_capital, income_improvement_q16,
                        sponsor_family_handle, &investment_living_cost_cache);
                    had_eligible_sponsor = had_eligible_sponsor ||
                        credit_sponsor_eligible;
                    uses_merchant_credit = sponsor >= 0;
                    if (uses_merchant_credit) {
                        merchant_credit = std::max<int64_t>(
                            0, required_capital - sponsor_capital);
                    }
                }
            }
            if (sponsor < 0) {
                if (had_eligible_sponsor) {
                    ++_building_investment_probability_skips;
                    reject(INVESTMENT_REJECTION_PROBABILITY);
                } else {
                    eligible_but_unfunded = true;
                    reject(INVESTMENT_REJECTION_SPONSOR_CAPITAL);
                }
                continue;
            }
            if (!materials_ready) {
                ++_building_investment_blocked_materials;
                record_investment_material_demand(cell, type_id, 1,
                    country_cost_factor);
                reject(INVESTMENT_REJECTION_MATERIALS);
                continue;
            }
            Candidate candidate;
            EconomicOpportunityQuote candidate_quote;
            candidate_quote.owner_use_value_per_day =
                daily_in_kind_livelihood;
            candidate_quote.cash_revenue_per_day =
                daily_after_tax_cash_revenue;
            candidate_quote.merchant_revenue_per_day =
                daily_merchant_cash_revenue;
            candidate_quote.producer_support_revenue_per_day =
                daily_producer_support_revenue;
            candidate_quote.economic_revenue_per_day =
                daily_economic_revenue;
            candidate_quote.input_cost_per_day = daily_input_cost;
            candidate_quote.wage_cost_per_day = daily_wages;
            candidate_quote.maintenance_cost_per_day = daily_maintenance;
            candidate_quote.owner_living_cost_per_day = owner_livelihood;
            candidate_quote.after_tax_revenue_per_day =
                daily_after_tax_cash_revenue;
            candidate_quote.profit_per_day = daily_profit;
            candidate_quote.owner_slots = type.owner_slots_per_building;
            candidate_quote.employee_slots = employee_slots;
            initialize_investment_candidate_plan(candidate.plan, cell,
                type_id, target_signature, throughput_q16,
                construction_cost, required_capital, payback, daily_profit,
                return_on_capital_q16, type.owner_slots_per_building,
                employee_slots, candidate_quote);
            candidate.plan.funding_capital = sponsor_capital;
            candidate.plan.merchant_credit = merchant_credit;
            candidate.plan.sponsor = sponsor;
            candidate.plan.sponsor_family_handle = sponsor_family_handle;
            candidate.shortage_q16 = shortage_q16;
            candidate.driver_good_id = driver.good_id;
            candidate.driver_deficit = driver_deficit;
            candidate.stealable = stealable;
            candidate.challenger_unit_cost = challenger_unit_cost;
            candidate.incumbent_unit_cost = incumbent_unit_cost;
            candidate.cost_advantage_q16 = cost_advantage_q16;
            candidate.displaces_incumbents = displaces_incumbents;
            candidate.startup_driven = driver.startup_incremental;
            for (int32_t i = 0; i < type.output_count; ++i) {
                const GoodAmount &output =
                    _building_outputs[type.output_begin + i];
                if (output.good_id != driver.good_id) continue;
                candidate.driver_output_per_building =
                    effective_building_output_quantity_for_target(
                        cell, type_id, target_signature,
                        output.good_id, output.quantity, throughput_q16, 1,
                        _saturation_count);
                break;
            }
            candidate.willing_population = willing_population;
            candidate.transferable_capital = transferable_capital;
            candidate.income_improvement_q16 = income_improvement_q16;
            candidate.plan.uses_merchant_credit = uses_merchant_credit;
            if (sponsor >= 0 &&
                sponsor < static_cast<int32_t>(
                    population_store().signature_id.size()) &&
                static_cast<int32_t>(
                    population_store().signature_id[sponsor]) !=
                    target_signature &&
                population_store().owner_employed[sponsor] > 0) {
                candidate.reallocates_owner_seat = true;
            }
            candidate.plan.request = cell_request;
            if (driver.startup_incremental && cell_request.reason !=
                    INVESTMENT_REQUEST_EMPLOYMENT_CATCHUP)
                candidate.plan.request.reason =
                    INVESTMENT_REQUEST_STARTUP_DEMAND;
            else if (driver.good_id == _epoch_research_good_id &&
                     cell_request.reason !=
                        INVESTMENT_REQUEST_EMPLOYMENT_CATCHUP)
                candidate.plan.request.reason =
                    INVESTMENT_REQUEST_RESEARCH_DEMAND;
            candidate.plan.request.demand_pressure = std::max<int64_t>(
                candidate.plan.request.demand_pressure,
                std::max<int64_t>(0, driver_deficit));
            candidate.plan.request.allow_reallocation =
                cell_request.allow_reallocation ||
                candidate.reallocates_owner_seat;
            const int64_t target_gap = mul_div_sat(
                std::max<int64_t>(0, driver_deficit),
                _investment_gap_fill_share_q16.get(), Q16_ONE,
                _saturation_count);
            candidate.desired_count =
                candidate.driver_output_per_building > 0 && target_gap > 0
                    ? std::max<int64_t>(1,
                        saturating_add(target_gap,
                            candidate.driver_output_per_building - 1,
                            _saturation_count) /
                            candidate.driver_output_per_building)
                    : 1;
            if (existing != nullptr && existing->installed_count > 0) {
                const int64_t scaled = saturating_mul(
                    existing->installed_count,
                    _investment_max_growth_share_q16.get(), _saturation_count);
                candidate.plan.max_batch_count = std::max<int64_t>(
                    1, saturating_add(scaled, Q16_ONE - 1,
                        _saturation_count) / Q16_ONE);
            } else {
            candidate.plan.max_batch_count =
                    _investment_new_type_seed_buildings.get();
            }
            candidate.plan.request.max_batch_count =
                candidate.plan.max_batch_count;
            candidate.jobs_per_building = std::max<int64_t>(
                1, type.owner_slots_per_building);
            // Portfolio ranking is a monetary return decision. Output
            // pressure and utilization have already informed the revenue
            // forecast and capacity; they are not additional preferences.
            candidate.score_q16 = std::max<int64_t>(
                return_on_capital_q16, margin_q16);
            if (candidate.plan.sponsor_family_handle != 0) {
                const int32_t stable_preference =
                    family_trait_behavior_factor_q16(
                        candidate.plan.sponsor_family_handle, 0, 0, type_id, cell);
                const int32_t sector_preference =
                    family_trait_behavior_factor_q16(
                        candidate.plan.sponsor_family_handle, 0, 1,
                        type.economic_sector, cell);
                candidate.score_q16 = mul_div_sat(candidate.score_q16,
                    stable_preference, Q16_ONE, _saturation_count);
                candidate.score_q16 = mul_div_sat(candidate.score_q16,
                    sector_preference, Q16_ONE, _saturation_count);
                int32_t family_index = -1;
                if (families_store().valid_handle(candidate.plan.sponsor_family_handle,
                        family_index) &&
                    family_index >= 0 && family_index < static_cast<int32_t>(
                        _family_investment_factor_q16.size())) {
                    candidate.score_q16 = mul_div_sat(candidate.score_q16,
                        _family_investment_factor_q16[
                            static_cast<size_t>(family_index)],
                        Q16_ONE, _saturation_count);
                }
                auto mix_score_term = [&](int32_t term, int32_t signal_q16) {
                    const int32_t factor = family_behavior_score_term_q16(
                        candidate.plan.sponsor_family_handle, cell, term);
                    if (factor == Q16_ONE) return;
                    const int64_t mix = saturating_add(Q16_ONE,
                        mul_div_sat(static_cast<int64_t>(factor) - Q16_ONE,
                            std::clamp<int32_t>(signal_q16, 0,
                                static_cast<int32_t>(Q16_ONE)),
                            Q16_ONE, _saturation_count),
                        _saturation_count);
                    candidate.score_q16 = mul_div_sat(candidate.score_q16,
                        mix, Q16_ONE, _saturation_count);
                };
                if (daily_cash_revenue > 0) {
                    const int32_t after_share = static_cast<int32_t>(
                        std::clamp<int64_t>(mul_div_sat(
                            daily_after_tax_cash_revenue, Q16_ONE,
                            daily_cash_revenue, _saturation_count),
                            0, Q16_ONE));
                    mix_score_term(FAMILY_SCORE_TAX_SENSITIVITY, after_share);
                }
                mix_score_term(FAMILY_SCORE_LOCAL_RESOURCE_ABUNDANCE,
                    building_local_resource_abundance_q16(cell, type_id));
                if (_max_building_upgrade_tier > 0)
                    mix_score_term(FAMILY_SCORE_UPGRADE_TIER,
                        static_cast<int32_t>(mul_div_sat(
                            type.upgrade_tier, Q16_ONE,
                            _max_building_upgrade_tier, _saturation_count)));
                mix_score_term(FAMILY_SCORE_LOCAL_POPULARITY,
                    static_cast<int32_t>(std::clamp<int64_t>(
                        margin_q16, 0, Q16_ONE)));
            }
            type_has_viable_candidate = true;
        if (diagnostic != nullptr) {
                diagnostic->rejection_reason = INVESTMENT_REJECTION_NONE;
                diagnostic->score_q16 = candidate.score_q16;
                diagnostic->payback_days = payback;
                diagnostic->required_capital = required_capital;
                diagnostic->projected_profit_per_day = daily_profit;
                diagnostic->return_on_capital_q16 = return_on_capital_q16;
                diagnostic->cost_advantage_q16 = cost_advantage_q16;
                diagnostic->stealable = stealable;
                diagnostic->challenger_unit_cost = challenger_unit_cost;
                diagnostic->incumbent_unit_cost = incumbent_unit_cost;
            }
            if (existing_group >= 0) {
                investment_mark_rejection(existing, INVESTMENT_REJECTION_NONE);
                for (int32_t group = existing->first_group;
                     group <= existing->last_group; ++group) {
                    if (buildings_store().cell[group] != cell ||
                        buildings_store().type_id[group] != type_id) break;
                    _building_investment_score_q16[group] = candidate.score_q16;
                    _building_investment_payback_days[group] = payback;
                }
            }
            if (BuildingInvestmentCellContext::better(candidate, type_best))
                type_best = candidate;
        }
