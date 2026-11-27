        std::vector<OutputInvestmentSignal> &output_signals =
            _investment_output_signals_scratch;
        output_signals.clear();
        int32_t driver_index = -1;
        for (int32_t i = 0; i < type.output_count; ++i) {
            const GoodAmount &output = _building_outputs[type.output_begin + i];
            const int32_t representative_owner = existing_group >= 0
                ? buildings_store().owner_signature_id[existing_group]
                : signature_for_profession_ethnicity(
                    type.owner_profession_id, 0);
            int64_t effective_unit_output = existing_group >= 0
                ? effective_building_output_quantity(
                    building_view(static_cast<size_t>(existing_group)), output.good_id,
                    output.quantity,
                    Q16_ONE, 1, _saturation_count)
                : effective_building_output_quantity_for_target(
                    cell, type_id, representative_owner,
                    output.good_id, output.quantity, Q16_ONE, 1,
                    _saturation_count);
            const int64_t index = market_store().index(market, output.good_id);
            const int32_t signal = market_signal_index(cell, output.good_id);
            const bool monetary_issue =
                _good_monetary_issue_values[output.good_id] > 0;
            const int64_t research_demand =
                epoch_procurement_demand_daily(cell, output.good_id);
            const int64_t demand = saturating_add(
                saturating_add(
                    market_store().demand_ema[index],
                    saturating_add(
                        signal >= 0 ? _market_signals.business_demand_ema[signal] : 0,
                        research_demand, _saturation_count),
                    _saturation_count),
                saturating_add(
                    signal >= 0 && signal < static_cast<int32_t>(
                            _epoch_substitute_business_demand.size())
                        ? std::max<int64_t>(0,
                            _epoch_substitute_business_demand[signal]) : 0,
                    signal >= 0
                        ? mul_div_sat(merchant_protected_reserve(signal), Q16_ONE,
                            std::max<int64_t>(Q16_ONE,
                                _good_target_inventory_days_q16[output.good_id]),
                            _saturation_count) : 0,
                    _saturation_count),
                _saturation_count);
            const int64_t supply = signal >= 0
                ? _market_signals.offered_supply_ema[signal] : 0;
            const int64_t realized_withdrawal = signal >= 0
                ? _market_signals.realized_withdrawal_ema[signal] : 0;
            const int32_t output_flow = trade_flow_index(
                cell, output.good_id, false);
            const int64_t export_ema = output_flow >= 0
                ? _trade_flows.export_ema[output_flow] : 0;
            const int64_t inventory_target = merchant_inventory_target(
                market, output.good_id, signal, realized_withdrawal,
                export_ema, supply, _saturation_count);
            const int64_t inventory_gap = std::max<int64_t>(
                0, inventory_target - market_store().stock[index]);
            const int64_t gap_daily = inventory_gap > 0
                ? mul_div_sat(inventory_gap, Q16_ONE,
                    std::max<int64_t>(Q16_ONE,
                        _good_target_inventory_days_q16[output.good_id]),
                    _saturation_count) : 0;
            int64_t output_deficit = std::max<int64_t>(
                std::max<int64_t>(0, demand - supply), gap_daily);
            int64_t output_pressure_q16 =
                market_store().last_shortage_q16[index];
            if (monetary_issue) {
                // Mint clears at face. Executable output (labor + ore), not
                // the cell bullion pool, decides whether a gold lot can run.
                bool employee_supply = type.employee_count == 0;
                for (int32_t role_index = 0; role_index < type.employee_count;
                     ++role_index) {
                    const JobRole &role = _building_employee_roles[
                        type.employee_begin + role_index];
                    employee_supply = employee_supply ||
                        (role.profession_id >= 0 &&
                         role.profession_id < static_cast<int32_t>(
                             cell_profession_population.size()) &&
                         cell_profession_population[role.profession_id] > 0);
                }
                int64_t resource_capacity_q16 = Q16_ONE;
                const int64_t resource_days = std::max<int64_t>(1, _epoch_days.get());
                for (int32_t resource_index = 0;
                     resource_index < type.resource_count; ++resource_index) {
                    const ResourceAmount &resource = _building_resources[
                        type.resource_begin + resource_index];
                    const int64_t raw = resource.mode == 1
                        ? saturating_mul(1, resource.quantity, _saturation_count)
                        : saturating_mul(resource_days, resource.quantity,
                            _saturation_count);
                    const int64_t required = effective_resource_use_quantity(
                        cell, resource.resource_id, raw, _saturation_count);
                    if (required <= 0) continue;
                    resource_capacity_q16 = std::min(resource_capacity_q16,
                        std::clamp<int64_t>(mul_div_sat(
                            available_resource_amount(resource, cell), Q16_ONE,
                            required, _saturation_count), 0, Q16_ONE));
                }
                if (!employee_supply || resource_capacity_q16 <= 0)
                    effective_unit_output = 0;
                else if (resource_capacity_q16 < Q16_ONE)
                    effective_unit_output = mul_div_sat(effective_unit_output,
                        resource_capacity_q16, Q16_ONE, _saturation_count);
                const int64_t executable_output = employee_supply
                    ? effective_unit_output : 0;
                // Mint clears at face value, so executable output is the
                // absorbable demand — not the cell bullion pool.
                output_deficit = std::max(output_deficit, executable_output);
                if (executable_output > 0)
                    output_pressure_q16 = Q16_ONE;
            } else if (research_demand > 0 && supply <= 0) {
                // Government procurement is a cash-backed buyer even before
                // the first research producer exists. Seed one building of
                // entry pressure; absorption later still caps revenue at
                // the demand-covered share.
                output_deficit = std::max<int64_t>(
                    output_deficit, effective_unit_output);
                output_pressure_q16 = Q16_ONE;
            }
            const int64_t local_startup = startup_demand_for(
                cell, output.good_id);
            const int64_t remote_startup = remote_startup_demand_for(
                cell, output.good_id);
            // A completely new output has no EMA, stock gap, or startup
            // chain to identify it. Give only a greenfield candidate a
            // small structural absorption prior so a new profession or
            // good can be discovered; all capital, input, resource,
            // margin, payback, and tax gates still apply below. This is a
            // bounded discovery prior, never a full-capacity receipt.
            constexpr int64_t GREENFIELD_ABSORPTION_Q16 = Q16_ONE / 16;
            const bool no_market_evidence = demand <= 0 && supply <= 0 &&
                realized_withdrawal <= 0 && output_deficit <= 0 &&
                local_startup <= 0 && remote_startup <= 0;
            if (greenfield && no_market_evidence && effective_unit_output > 0) {
                const int64_t structural_deficit = std::max<int64_t>(
                    1, mul_div_sat(effective_unit_output,
                        GREENFIELD_ABSORPTION_Q16, Q16_ONE,
                        _saturation_count));
                output_deficit = structural_deficit;
                output_pressure_q16 = GREENFIELD_ABSORPTION_Q16;
            }
            const int64_t organic_output_deficit = output_deficit;
            output_deficit = std::max(output_deficit, local_startup);
            // Offered supply already contains the utilized portion of the
            // installed stock. Reserve the remaining installed capacity and
            // all construction in flight before treating a shortage as an
            // entry signal; otherwise each review reinvests into capacity
            // that merely has not started producing yet.
            int64_t reserved_capacity_q16 = pending_count > 0
                ? saturating_mul(pending_count, Q16_ONE,
                    _saturation_count) : 0;
            if (existing != nullptr) {
                reserved_capacity_q16 = saturating_add(
                    reserved_capacity_q16,
                    std::max<int64_t>(0, existing->idle_capacity_q16),
                    _saturation_count);
            }
            const int64_t reserved_output = mul_div_sat(
                effective_unit_output, reserved_capacity_q16, Q16_ONE,
                _saturation_count);
            output_deficit = std::max<int64_t>(
                0, output_deficit - std::min(output_deficit, reserved_output));
            const int64_t organic_after_reserved = std::max<int64_t>(
                0, organic_output_deficit -
                    std::min(organic_output_deficit, reserved_output));
            // Remote preparation already deducted executable capacity for
            // the component, so merge that lane after local reservations.
            output_deficit = std::max(output_deficit, remote_startup);
            // Derived-demand bootstrap: a scarce downstream recipe whose
            // price has conducted into this input is a committed indirect
            // buyer for its FIRST producer. Fold a bounded share of that
            // shadow quantity into the demand-backed deficit so the
            // absorption and revenue gates can see it. Price conduction
            // alone leaves expected sales at zero on an empty shelf, so
            // the upstream would still fail the owner-livelihood gate.
            if (greenfield && derived_startup_absorption_enabled() &&
                derived_price_conduction_enabled() && signal >= 0 &&
                signal < static_cast<int32_t>(
                    _epoch_derived_business_demand.size()) &&
                signal < static_cast<int32_t>(
                    _epoch_derived_anchor_price.size()) &&
                _epoch_derived_anchor_price[signal] > 0) {
                const int64_t derived_qty = std::max<int64_t>(0,
                    _epoch_derived_business_demand[signal]);
                if (derived_qty > 0) {
                    const int64_t committed = mul_div_sat(
                        derived_qty,
                        std::clamp<int64_t>(
                            _derived_startup_absorption_q16, 0, Q16_ONE),
                        Q16_ONE, _saturation_count);
                    output_deficit = std::max(output_deficit, committed);
                }
            }
            const int64_t anticipated_demand = std::max(
                local_startup, remote_startup);
            const int64_t demand_for_pressure = std::max(
                demand, anticipated_demand);
            if (output_deficit <= 0) output_pressure_q16 = 0;
            if (output_deficit > 0 && demand_for_pressure > 0) {
                output_pressure_q16 = std::max<int64_t>(
                    output_pressure_q16,
                    std::min<int64_t>(Q16_ONE, mul_div_sat(
                        output_deficit, Q16_ONE, demand_for_pressure,
                        _saturation_count)));
            }
            if (inventory_gap > 0 && inventory_target > 0) {
                output_pressure_q16 = std::max<int64_t>(output_pressure_q16,
                    std::min<int64_t>(Q16_ONE, mul_div_sat(
                        inventory_gap, Q16_ONE, inventory_target,
                        _saturation_count)));
            }
            OutputInvestmentSignal item;
            item.good_id = output.good_id;
            item.pressure_q16 = output_pressure_q16;
            item.deficit = output_deficit;
            item.utilization_q16 = effective_unit_output > 0
                ? std::clamp<int64_t>(mul_div_sat(
                    output_deficit, Q16_ONE, effective_unit_output,
                    _saturation_count), 0, Q16_ONE)
                : 0;
            if (signal >= 0 && signal < static_cast<int32_t>(
                    _epoch_producer_sellable_current.size())) {
                item.sellable = std::max<int64_t>(
                    0, _epoch_producer_sellable_current[signal]);
                item.merchant_sold = std::max<int64_t>(
                    0, _epoch_producer_merchant_sold_current[signal]);
                item.discarded = std::max<int64_t>(
                    0, _epoch_producer_discarded_current[signal]);
            }
            if (item.sellable > 0) {
                // Monetary output is fully supported at face value. For
                // ordinary goods, use the factual merchant purchase share.
                item.sell_through_q16 = monetary_issue
                    ? Q16_ONE
                    : std::clamp<int64_t>(mul_div_sat(
                        item.merchant_sold, Q16_ONE, item.sellable,
                        _saturation_count), 0, Q16_ONE);
                item.discard_q16 = std::clamp<int64_t>(mul_div_sat(
                    item.discarded, Q16_ONE, item.sellable,
                    _saturation_count), 0, Q16_ONE);
            }
            const int64_t unit_price = std::max<int64_t>(1,
                market_store().price[market_store().index(market, output.good_id)]);
            int64_t expected_absorption_q16 = 0;
            if (monetary_issue) {
                expected_absorption_q16 = effective_unit_output > 0
                    ? Q16_ONE
                    : 0;
            } else if (effective_unit_output > 0) {
                // Value only the quantity that has a factual or
                // demand-backed buyer. Demand itself is a daily flow;
                // converting it to a share of one candidate's output
                // avoids ranking a huge recipe by demand dollars that the
                // recipe cannot actually sell.
                const int64_t demand_absorption = std::clamp<int64_t>(
                    mul_div_sat(std::max<int64_t>(0, demand), Q16_ONE,
                        effective_unit_output, _saturation_count),
                    0, Q16_ONE);
                const int64_t startup_absorption = std::clamp<int64_t>(
                    mul_div_sat(std::max<int64_t>(0, output_deficit), Q16_ONE,
                        effective_unit_output, _saturation_count),
                    0, Q16_ONE);
                expected_absorption_q16 = std::max({
                    item.sell_through_q16, demand_absorption,
                    startup_absorption});
            }
            const int64_t expected_quantity = mul_div_sat(
                effective_unit_output, expected_absorption_q16,
                Q16_ONE, _saturation_count);
            const int64_t expected_price = monetary_issue
                ? _good_monetary_issue_values[output.good_id] : unit_price;
            item.expected_cash_value = mul_div_sat(expected_quantity,
                expected_price, GOODS_SCALE, _saturation_count);
            item.driver_strength_q16 = item.expected_cash_value;
            item.nameplate_output = effective_unit_output;
            item.demand = demand;
            item.startup_demand = local_startup;
            item.remote_startup_demand = remote_startup;
            item.startup_incremental = output_deficit >
                organic_after_reserved;
            output_signals.push_back(item);
            const OutputInvestmentSignal &candidate = output_signals.back();
            if (driver_index < 0) {
                driver_index = i;
            } else {
                const OutputInvestmentSignal &current =
                    output_signals[driver_index];
                if (candidate.expected_cash_value > current.expected_cash_value ||
                    (candidate.expected_cash_value == current.expected_cash_value &&
                     candidate.good_id < current.good_id)) {
                    driver_index = i;
                }
            }
        }
