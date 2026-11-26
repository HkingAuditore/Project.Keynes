        OutputInvestmentSignal driver = driver_index >= 0
            ? output_signals[driver_index] : OutputInvestmentSignal{};
        int64_t shortage_q16 = driver.pressure_q16;
        int64_t utilization_q16 = driver.utilization_q16;
        int64_t driver_deficit = driver.deficit;
        // A merchant post sells no good: it has no marketable output, so the
        // market-signal gate and every output-derived gate below are blind to
        // it and rejected it unconditionally before this lane existed. Price
        // its owner seat from the market retail pool instead.
        const bool service_post = is_merchant_service_post(type);
        int64_t service_owner_income_per_day = 0;
        if (service_post) {
            service_owner_income_per_day = merchant_retail_owner_income_per_day(
                cell, std::max<int64_t>(1, type.owner_slots_per_building),
                std::max<int64_t>(1, type.owner_slots_per_building),
                _saturation_count);
        }
        // Shadow-derived demand is only a pricing/investment pressure
        // signal.  It must not by itself justify a normal greenfield or
        // expansion candidate, even when an incumbent has already left
        // output stock in the market.  Use only committed buyer evidence
        // for this gate; catch-up startup remains an explicit exception.
        bool driver_real_evidence = false;
        if (driver.good_id >= 0) {
            const int64_t output_index = market_store().index(
                market, driver.good_id);
            const int32_t signal = market_signal_index(cell, driver.good_id);
            const int64_t household_demand = output_index >= 0 &&
                    output_index < static_cast<int64_t>(
                        market_store().demand_ema.size())
                ? std::max<int64_t>(0, market_store().demand_ema[output_index]) : 0;
            const int64_t business_demand = signal >= 0 && signal <
                    static_cast<int32_t>(_market_signals.business_demand_ema.size())
                ? std::max<int64_t>(0, _market_signals.business_demand_ema[signal]) : 0;
            const int64_t withdrawal = signal >= 0 && signal <
                    static_cast<int32_t>(_market_signals.realized_withdrawal_ema.size())
                ? std::max<int64_t>(0, _market_signals.realized_withdrawal_ema[signal]) : 0;
            const int64_t epoch_real = signal >= 0 && signal <
                    static_cast<int32_t>(_epoch_desired_business_demand.size())
                ? std::max<int64_t>(0, _epoch_desired_business_demand[signal]) : 0;
            const int64_t epoch_substitute = signal >= 0 && signal <
                    static_cast<int32_t>(_epoch_substitute_business_demand.size())
                ? std::max<int64_t>(0, _epoch_substitute_business_demand[signal]) : 0;
            const int64_t epoch_funded = signal >= 0 && signal <
                    static_cast<int32_t>(_epoch_funded_business_demand.size())
                ? std::max<int64_t>(0, _epoch_funded_business_demand[signal]) : 0;
            const int64_t research = epoch_procurement_demand_daily(
                cell, driver.good_id);
            const int64_t startup = std::max<int64_t>(
                startup_demand_for(cell, driver.good_id),
                remote_startup_demand_for(cell, driver.good_id));
            const int32_t flow = trade_flow_index(cell, driver.good_id, false);
            const int64_t exports = flow >= 0 && flow < static_cast<int32_t>(
                    _trade_flows.export_ema.size())
                ? std::max<int64_t>(0, _trade_flows.export_ema[flow]) : 0;
            // A priced Leontief shadow demand is a claim from a real
            // downstream shortage, not a speculative ranking signal.
            // Accept it as buyer evidence only for the first producer of
            // that input, and only once conduction has actually priced it.
            const int32_t boot_signal = market_signal_index(
                cell, driver.good_id);
            const bool derived_boot_evidence =
                greenfield && derived_startup_absorption_enabled() &&
                derived_price_conduction_enabled() && boot_signal >= 0 &&
                boot_signal < static_cast<int32_t>(
                    _epoch_derived_business_demand.size()) &&
                boot_signal < static_cast<int32_t>(
                    _epoch_derived_anchor_price.size()) &&
                _epoch_derived_business_demand[boot_signal] > 0 &&
                _epoch_derived_anchor_price[boot_signal] > 0;
            driver_real_evidence = household_demand > 0 || business_demand > 0 ||
                withdrawal > 0 || epoch_real > 0 || epoch_substitute > 0 ||
                epoch_funded > 0 ||
                research > 0 || startup > 0 || exports > 0 ||
                derived_boot_evidence;
        }
        const int32_t driver_signal = driver.good_id >= 0
            ? market_signal_index(cell, driver.good_id) : -1;
        const bool driver_shadow_only =
            driver_signal >= 0 && driver_signal < static_cast<int32_t>(
                _epoch_derived_business_demand.size()) &&
              _epoch_derived_business_demand[driver_signal] > 0 &&
              !driver_real_evidence;
        int64_t stealable = 0;
        int64_t challenger_unit_cost = 0;
        int64_t incumbent_unit_cost = 0;
        bool displaces_incumbents = false;
        if (diagnostic != nullptr) {
            diagnostic->shortage_q16 = shortage_q16;
            diagnostic->utilization_q16 = utilization_q16;
            diagnostic->driver_good_id = driver.good_id;
            diagnostic->driver_pressure_q16 = driver.pressure_q16;
            diagnostic->driver_utilization_q16 = driver.utilization_q16;
            diagnostic->driver_sellable = driver.sellable;
            diagnostic->driver_merchant_sold = driver.merchant_sold;
            diagnostic->driver_sell_through_q16 = driver.sell_through_q16;
            diagnostic->driver_discard_q16 = driver.discard_q16;
        }
        if (driver.good_id < 0 && !service_post) {
            ++_investment_market_signal_rejections;
            reject(INVESTMENT_REJECTION_MARKET_SIGNAL);
            continue;
        }
        if (driver_shadow_only) {
            ++_investment_market_signal_rejections;
            reject(INVESTMENT_REJECTION_MARKET_SIGNAL);
            continue;
        }
        if (service_post) {
            // A post is either staffed or it is not, so executable utilization
            // is full whenever the pool can pay a seat. The pool itself is the
            // demand evidence the goods lane would have taken from a shortage
            // signal, so the shortage branch below is satisfied by construction
            // and the climate/hard-input clamp is skipped for this lane.
            utilization_q16 = service_owner_income_per_day > 0 ? Q16_ONE : 0;
            shortage_q16 = utilization_q16;
            driver_deficit = service_owner_income_per_day;
            driver.deficit = driver_deficit;
            driver.pressure_q16 = shortage_q16;
            driver.utilization_q16 = utilization_q16;
        }
        if (!evaluate_building_conditions(type_id, cell)) {
            ++_building_investment_blocked_resources;
            reject(INVESTMENT_REJECTION_RESOURCE);
            continue;
        }
        bool resource_budget_ready = true;
        for (int32_t edge = 0; edge < type.resource_count; ++edge) {
            const ResourceAmount &item = _building_resources[
                type.resource_begin + edge];
            if (item.quantity <= 0) continue;
            const size_t resource_idx = static_cast<size_t>(
                item.resource_id) * _cell_count.get() + cell;
            const int64_t committed =
                investment_resource_committed(resource_idx);
            const int64_t effective_quantity =
                effective_resource_use_quantity(
                    cell, item.resource_id, item.quantity,
                    _saturation_count);
            if (effective_quantity <= 0) continue;
            if (item.mode == 1) {
                // Capacity edges claim standing habitat against reserve.
                // Skipping them let wild_wheat_stand expand past fertile_soil.
                const int64_t available =
                    available_resource_amount(item, cell);
                if (committed > available ||
                    effective_quantity > available - committed) {
                    resource_budget_ready = false;
                    break;
                }
                continue;
            }
            if (item.mode != 0 || _resource_safe_harvest_q16.get() <= 0) continue;
            int64_t daily_budget = 0;
            if (resource_is_renewable(item.resource_id)) {
                daily_budget = renewable_safe_harvest(
                    item.resource_id, cell);
            } else if (resource_idx <
                       resource_remaining_lanes().size()) {
                daily_budget = std::max<int64_t>(0,
                    resource_remaining_lanes()[resource_idx]) /
                    std::max<int64_t>(1, _resource_min_horizon_days.get());
            }
            if (committed > daily_budget ||
                effective_quantity > daily_budget - committed) {
                resource_budget_ready = false;
                break;
            }
        }
        if (!resource_budget_ready) {
            ++_building_investment_blocked_resources;
            reject(INVESTMENT_REJECTION_RESOURCE);
            continue;
        }
        const int32_t country_cost_factor = country >= 0 &&
                country < static_cast<int32_t>(
                    _epoch_country_construction_cost_factor_q16.size())
            ? _epoch_country_construction_cost_factor_q16[country] : Q16_ONE;
        ConstructionMaterialPlan material_plan;
        const bool materials_ready = plan_construction_materials(
            cell, type_id, 1, country_cost_factor, material_plan);
        const int32_t failed_material_group = material_plan.failed_group;
        if (!materials_ready) {
            // 缺货仍按完整材料账单评估利润/出资人；虚拟库存仅用于报价。
            std::vector<int64_t> quote_stock(_good_ids.size(),
                std::numeric_limits<int64_t>::max() / 4);
            if (!plan_construction_materials(cell, type_id, 1,
                    country_cost_factor, material_plan, nullptr, &quote_stock)) {
                reject(INVESTMENT_REJECTION_MATERIALS);
                continue;
            }
        }
        if (diagnostic != nullptr) {
            diagnostic->failed_material_group = materials_ready ? -1 : failed_material_group;
            diagnostic->selected_material_good_ids = material_plan.good_ids;
            diagnostic->selected_material_quantities = material_plan.quantities;
        }
        const int64_t construction_cost = material_plan.total_cost;
        // Capital-feasibility gate (see precomputation above): without an
        // affordable construction bundle this type can never find a
        // sponsor. required_capital >= construction_cost and transferable
        // funds <= raw funds make this an exact no-false-negative skip.
        if (construction_cost > 0 &&
            construction_cost > cell_max_sponsor_funds &&
            construction_cost > cell_credit_construction_cover) {
            ++_investment_gate_capital_type_skips;
            eligible_but_unfunded = true;
            reject(INVESTMENT_REJECTION_SPONSOR_CAPITAL);
            continue;
        }
        int64_t daily_input_cost = 0;
        int64_t daily_input_base_cost = 0;
        // Hard inputs may ceiling entry utilization. Soft tools only cut
        // throughput efficiency (and bill the covered share) — matching
        // production's optional-productivity path.
        int64_t hard_input_coverage_bound_q16 = Q16_ONE;
        int64_t soft_efficiency_q16 = Q16_ONE;
        // Value of one full daily recipe's outputs at the frozen local
        // prices. This is used only for the optional-input decision: a
        // soft input is purchased when its marginal output value exceeds
        // its full purchase cost, otherwise the investment is evaluated
        // at bare efficiency with zero soft-input cost.
        int64_t daily_output_value = 0;
        for (int32_t output_edge = 0;
             output_edge < type.output_count; ++output_edge) {
            const GoodAmount &output = _building_outputs[
                type.output_begin + output_edge];
            if (output.good_id < 0 || output.good_id >= market_store().good_count.get())
                continue;
            const int64_t price = std::max<int64_t>(0,
                market_store().price[market_store().index(
                    market, output.good_id)]);
            daily_output_value = saturating_add(daily_output_value,
                goods_cost(std::max<int64_t>(0, output.quantity), price,
                    _saturation_count), _saturation_count);
        }
        for (int32_t i = 0; i < type.input_count; ++i) {
            const ProductionInput &input = _building_inputs[type.input_begin + i];
            int64_t best_price = std::numeric_limits<int64_t>::max();
            int64_t best_base_price = 0;
            int64_t best_coverage_q16 = -1;
            int64_t best_cold_cover = -1;
            int32_t best_efficiency_q16 = Q16_ONE;
            for (int32_t c = input.candidate_begin;
                 c < input.candidate_begin + input.candidate_count; ++c) {
                const InputCandidate &candidate = _building_input_candidates[c];
                if (!good_input_candidate_available(cell, candidate.good_id, true)) continue;
                int64_t physical_daily = mul_div_sat(
                    input.quantity, Q16_ONE, candidate.efficiency_q16,
                    _saturation_count);
                if (mul_div_sat(physical_daily, candidate.efficiency_q16,
                                Q16_ONE, _saturation_count) < input.quantity) {
                    physical_daily = saturating_add(
                        physical_daily, 1, _saturation_count);
                }
                const int64_t input_index = market_store().index(
                    market, candidate.good_id);
                const int32_t input_signal = market_signal_index(
                    cell, candidate.good_id);
                const int64_t reserved = input_signal >= 0 && input_signal <
                        static_cast<int32_t>(_production_input_reserve.size())
                    ? _production_input_reserve[input_signal] : 0;
                const int64_t free_stock = std::max<int64_t>(
                    0, market_store().stock[input_index] - reserved);
                const int64_t offered = input_signal >= 0
                    ? _market_signals.offered_supply_ema[input_signal] : 0;
                const int64_t effective_period_supply = saturating_add(
                    free_stock, saturating_mul(offered,
                        std::max(1, _epoch_days.get()), _saturation_count),
                    _saturation_count);
                const int64_t required_period = saturating_mul(
                    physical_daily, std::max(1, _epoch_days.get()), _saturation_count);
                const int64_t coverage_q16 = required_period > 0
                    ? std::min<int64_t>(Q16_ONE, mul_div_sat(
                        effective_period_supply, Q16_ONE, required_period,
                        _saturation_count)) : Q16_ONE;
                const int64_t cold_cover = (free_stock <= 0 && offered <= 0)
                    ? startup_producer_hard_input_cover_q16(
                        cell, candidate.good_id, _saturation_count)
                    : Q16_ONE;
                const int64_t base_effective_price = mul_div_sat(
                    market_store().price[market_store().index(market, candidate.good_id)], Q16_ONE,
                    candidate.efficiency_q16, _saturation_count);
                const TransactionQuote input_quote = quote_transaction(
                    cell, candidate.good_id, base_effective_price,
                    false, true, _saturation_count, GOODS_SCALE);
                const int64_t effective_price = input_quote.buyer_outlay;
                if (coverage_q16 > best_coverage_q16 ||
                    (coverage_q16 == best_coverage_q16 &&
                     cold_cover > best_cold_cover) ||
                    (coverage_q16 == best_coverage_q16 &&
                     cold_cover == best_cold_cover &&
                     effective_price < best_price)) {
                    best_coverage_q16 = coverage_q16;
                    best_cold_cover = cold_cover;
                    best_price = effective_price;
                    best_base_price = base_effective_price;
                    best_efficiency_q16 = std::max<int32_t>(1,
                        candidate.efficiency_q16);
                }
            }
            const int64_t required_q16 = std::clamp<int64_t>(
                input.required_q16, 0, Q16_ONE);
            // Soft inputs match production: missing every candidate is
            // zero coverage / zero bill, not a hard INPUT_CHAIN reject.
            // Hard-required edges with no priced SKU still fail the chain.
            if (best_price == std::numeric_limits<int64_t>::max()) {
                if (required_q16 >= Q16_ONE) {
                    daily_input_cost = std::numeric_limits<int64_t>::max();
                    break;
                }
                soft_efficiency_q16 = std::min<int64_t>(
                    soft_efficiency_q16,
                    std::clamp<int64_t>(Q16_ONE - required_q16, 0, Q16_ONE));
                continue;
            }
            if (required_q16 >= Q16_ONE) {
                hard_input_coverage_bound_q16 = std::min<int64_t>(
                    hard_input_coverage_bound_q16,
                    std::clamp<int64_t>(
                        std::max<int64_t>(0, best_coverage_q16), 0, Q16_ONE));
            } else if (required_q16 > 0) {
                // Evaluate both soft-input choices. The bare branch keeps
                // only (1 - required) productivity and pays nothing. The
                // tooled branch restores full productivity and pays the
                // complete physical input bill. This makes investment
                // profitability use max(bare, tooled), rather than
                // treating a partially available tool as mandatory cost.
                const int64_t physical_daily = mul_div_sat(
                    input.quantity, Q16_ONE,
                    best_efficiency_q16,
                    _saturation_count);
                const int64_t tooled_cost = goods_cost(
                    std::max<int64_t>(1, physical_daily), best_price,
                    _saturation_count);
                const int64_t marginal_output_value = mul_div_sat(
                    daily_output_value, required_q16, Q16_ONE,
                    _saturation_count);
                const bool buy_soft = tooled_cost > 0 &&
                    marginal_output_value >= tooled_cost;
                if (buy_soft) {
                    daily_input_cost = saturating_add(daily_input_cost,
                        tooled_cost, _saturation_count);
                    daily_input_base_cost = saturating_add(
                        daily_input_base_cost,
                        goods_cost(std::max<int64_t>(1, physical_daily),
                            best_base_price, _saturation_count),
                        _saturation_count);
                } else {
                    soft_efficiency_q16 = std::min<int64_t>(
                        soft_efficiency_q16,
                        std::clamp<int64_t>(Q16_ONE - required_q16,
                            0, Q16_ONE));
                }
                continue;
            }
            // Hard inputs bill their full physical recipe quantity;
            // utilization scales the period bill later.
            const int64_t bill_quantity = input.quantity;
            daily_input_cost = saturating_add(daily_input_cost,
                goods_cost(bill_quantity, best_price, _saturation_count),
                _saturation_count);
            daily_input_base_cost = saturating_add(
                daily_input_base_cost, goods_cost(bill_quantity, best_base_price, _saturation_count), _saturation_count);
        }
        if (daily_input_cost == std::numeric_limits<int64_t>::max()) {
            // A hard production input shortage must still expose the
            // construction BOM.  Otherwise a producer such as the
            // knapping workshop is rejected before the material pass and
            // its flint/log demand never reaches the upstream producer.
            // The reserve update is monotonic, so repeated review passes
            // do not multiply the same demand.
            record_investment_material_demand(cell, type_id, 1,
                country_cost_factor);
            reject(INVESTMENT_REJECTION_INPUT_CHAIN);
            continue;
        }
