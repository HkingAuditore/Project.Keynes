        int64_t daily_wages = 0;
        for (int32_t r = 0; r < type.employee_count; ++r) {
            const JobRole &role = _building_employee_roles[type.employee_begin + r];
            const int32_t signal = labor_signal_index(cell, role.profession_id);
            const int64_t living_floor = signal >= 0
                ? std::max(_labor_signals.base_living_cost[signal],
                    _labor_signals.role_living_cost[signal]) : 0;
            const int64_t market_quote = signal >= 0 && signal <
                    static_cast<int32_t>(_labor_signals.contract_wage_ema.size())
                ? std::max(_labor_signals.contract_wage_ema[signal],
                    _labor_signals.paid_wage_ema[signal]) : 0;
            const int64_t dynamic_wage = std::max(living_floor, market_quote);
            daily_wages = saturating_add(daily_wages, saturating_mul(
                role.slots_per_building, dynamic_wage,
                _saturation_count), _saturation_count);
        }
        const int64_t daily_maintenance = daily_maintenance_cost_for_type(
            cell, type, _saturation_count);
        if (daily_maintenance == std::numeric_limits<int64_t>::max()) {
            reject(INVESTMENT_REJECTION_INPUT_CHAIN);
            continue;
        }
        const int64_t nameplate_output = std::max<int64_t>(
            0, driver.nameplate_output);
        const int64_t full_operating_cost = saturating_add(
            saturating_add(daily_input_cost, daily_wages, _saturation_count),
            daily_maintenance, _saturation_count);
        const int64_t allocated_driver_cost = driver_index >= 0
            ? allocated_output_operating_cost(
                type, driver_index, full_operating_cost, _saturation_count)
            : 0;
        challenger_unit_cost = nameplate_output > 0
            ? mul_div_sat(allocated_driver_cost, GOODS_SCALE,
                nameplate_output, _saturation_count)
            : 0;
        const int64_t cost_threshold = mul_div_sat(
            challenger_unit_cost,
            saturating_add(Q16_ONE,
                std::max<int32_t>(0,
                    _investment_displacement_min_advantage_q16),
                _saturation_count),
            Q16_ONE, _saturation_count);
        for (const InvestmentIncumbentLane &lane : incumbent_lanes) {
            if (lane.good_id != driver.good_id ||
                lane.type_id == type_id) continue;
            if (lane.unit_cost <= cost_threshold) continue;
            const int64_t lane_stealable = std::max<int64_t>(
                lane.stealable_capacity, lane.daily_offered);
            stealable = saturating_add(
                stealable, lane_stealable, _saturation_count);
            if (incumbent_unit_cost <= 0 ||
                lane.unit_cost < incumbent_unit_cost) {
                incumbent_unit_cost = lane.unit_cost;
            }
        }
        if (stealable > 0)
            ++_investment_displacement_type_evaluations;
        // Same-type seat expansion: when local incumbents are already
        // staffed and strongly profitable, allow a catch-up-sized quote so
        // sponsors can buy an owner seat (profession change) even if the
        // market gap is closed. Losing industries stay out via margin.
        bool profitable_incumbent_seat_expansion = false;
        if (existing != nullptr && existing->active_count > 0 &&
            existing->filled_owner >= existing->owner_required &&
            existing->representative_group >= 0 &&
            existing->representative_group < static_cast<int32_t>(
                building_count())) {
            const auto incumbent = building_view(static_cast<size_t>(
                existing->representative_group));
            profitable_incumbent_seat_expansion =
                incumbent.realized_profit_margin_q16 >= Q16_ONE / 4;
        }
        if (driver_deficit > 0 && utilization_q16 > 0) {
            // Keep the ordinary shortage path.
        } else if (stealable > 0 && nameplate_output > 0) {
            utilization_q16 = std::clamp<int64_t>(mul_div_sat(
                stealable, Q16_ONE, nameplate_output, _saturation_count),
                0, Q16_ONE);
            shortage_q16 = std::min<int64_t>(Q16_ONE, mul_div_sat(
                stealable, Q16_ONE,
                std::max<int64_t>(1, driver.demand), _saturation_count));
            driver_deficit = stealable;
            driver.deficit = stealable;
            driver.pressure_q16 = shortage_q16;
            driver.utilization_q16 = utilization_q16;
            driver.sellable = 0;
            displaces_incumbents = true;
            if (driver_index >= 0 &&
                driver_index < static_cast<int32_t>(output_signals.size())) {
                output_signals[driver_index].deficit = stealable;
                output_signals[driver_index].pressure_q16 = shortage_q16;
                output_signals[driver_index].utilization_q16 =
                    utilization_q16;
                output_signals[driver_index].sellable = 0;
            }
        } else if (nameplate_output > 0 &&
                   (cell_request.reason ==
                        INVESTMENT_REQUEST_EMPLOYMENT_CATCHUP ||
                    profitable_incumbent_seat_expansion)) {
            // 位移必须先于 catch-up：高失业格上的低成本挑战者仍要走 stealable。
            // Profitable full incumbents share the same bounded util so
            // seat-creation cannot outrun ordinary catch-up.
            utilization_q16 = std::max<int64_t>(
                utilization_q16, Q16_ONE / 6);
            shortage_q16 = std::max<int64_t>(
                shortage_q16, Q16_ONE / 8);
            if (driver_deficit <= 0) {
                driver_deficit = mul_div_sat(
                    nameplate_output, utilization_q16, Q16_ONE,
                    _saturation_count);
                driver.deficit = driver_deficit;
                if (driver_index >= 0 &&
                    driver_index < static_cast<int32_t>(
                        output_signals.size())) {
                    output_signals[driver_index].deficit = driver_deficit;
                }
            }
            driver.utilization_q16 = utilization_q16;
            driver.pressure_q16 = shortage_q16;
        } else {
            reject(INVESTMENT_REJECTION_NO_COST_ADVANTAGE);
            if (diagnostic != nullptr) {
                diagnostic->stealable = stealable;
                diagnostic->challenger_unit_cost = challenger_unit_cost;
                diagnostic->incumbent_unit_cost = incumbent_unit_cost;
            }
            continue;
        }
        const int64_t climate_capacity_q16 = production_climate_capacity_q16(
            type, cell, nullptr, nullptr, _saturation_count);
        int64_t revealed_util_q16 = 0;
        if (existing != nullptr && existing->active_count > 0 &&
            existing->sum_last_output > 0) {
            int64_t recipe_qty = 0;
            for (int32_t i = 0; i < type.output_count; ++i) {
                recipe_qty = saturating_add(recipe_qty,
                    std::max<int64_t>(0,
                        _building_outputs[type.output_begin + i].quantity),
                    _saturation_count);
            }
            const int64_t nameplate = saturating_mul(
                saturating_mul(existing->active_count, recipe_qty,
                    _saturation_count),
                std::max<int64_t>(1, _epoch_days.get()), _saturation_count);
            if (recipe_qty > 0 && nameplate > 0) {
                revealed_util_q16 = std::clamp<int64_t>(mul_div_sat(
                    existing->sum_last_output, Q16_ONE, nameplate,
                    _saturation_count), 0, Q16_ONE);
            }
        }
        // Market/climate and hard-input stock may still bind expansion.
        // Soft-tool coverage lowers throughput via soft_efficiency below,
        // and must not undercut the executable intensity incumbents already
        // revealed in this cell.
        if (!service_post) {
            utilization_q16 = std::min(utilization_q16, climate_capacity_q16);
            if (revealed_util_q16 > 0) {
                utilization_q16 = std::min(utilization_q16,
                    std::max(hard_input_coverage_bound_q16, revealed_util_q16));
            } else {
                utilization_q16 = std::min(utilization_q16,
                    hard_input_coverage_bound_q16);
            }
        }
        if (utilization_q16 <= 0) {
            // Preserve upstream construction pressure even when the
            // first executable utilization is currently zero.  This is
            // needed for hard-input bootstrap chains whose producer must
            // be built before utilization can become positive.
            record_investment_material_demand(cell, type_id, 1,
                country_cost_factor);
            reject(INVESTMENT_REJECTION_INPUT_CHAIN);
            continue;
        }
        const int64_t throughput_q16 = mul_div_sat(
            utilization_q16, soft_efficiency_q16, Q16_ONE, _saturation_count);
        if (diagnostic != nullptr) {
            diagnostic->shortage_q16 = shortage_q16;
            diagnostic->utilization_q16 = throughput_q16;
            diagnostic->driver_pressure_q16 = driver.pressure_q16;
            diagnostic->driver_utilization_q16 = driver.utilization_q16;
            diagnostic->stealable = stealable;
            diagnostic->challenger_unit_cost = challenger_unit_cost;
            diagnostic->incumbent_unit_cost = incumbent_unit_cost;
        }
        int64_t quoted_daily_variable_cost = mul_div_sat(saturating_add(
            saturating_add(daily_input_cost, daily_wages, _saturation_count),
            daily_maintenance, _saturation_count), utilization_q16,
            Q16_ONE, _saturation_count);
        // Zero-material entry collectors are starter infrastructure, not
        // industrial capital. Their owner profession authors no entry-savings
        // gate, so the 15% target-margin hurdle would reject a profitable
        // one-building livelihood merely for earning less than the industrial
        // return target. Require only a positive daily profit; the owner
        // livelihood, capital, payback, sponsor, resource and input gates
        // still apply unchanged.
        const int32_t owner_entry_days =
            type.owner_profession_id >= 0 && type.owner_profession_id <
                    static_cast<int32_t>(_profession_entry_savings_days.size())
                ? _profession_entry_savings_days[
                    static_cast<size_t>(type.owner_profession_id)]
                : 0;
        const int64_t owner_startup_days =
            type.owner_profession_id >= 0 && type.owner_profession_id <
                    static_cast<int32_t>(_profession_startup_capital_days.size())
                ? std::max<int64_t>(0, _profession_startup_capital_days[
                    static_cast<size_t>(type.owner_profession_id)])
                : 30;
        const bool entry_zero_build_margin_exempt =
            type.construction_count == 0 && owner_entry_days == 0;
