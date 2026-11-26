        const int32_t n_eth = static_cast<int32_t>(_ethnicity_ids.size());

        // Owner mobility prefers the previous committed cycle's settled
        // cashflow. Speculative shadow demand must not invent industrial
        // owner moves. Never-operated vacancies are different: with no
        // settled period, mobility income was permanently 0, so UI
        // opportunity quotes looked huge while nobody would transfer into
        // empty wild_tuber_patch / wild_wheat_stand shells. Use the
        // counterfactual opportunity (already gated for knapping shadow)
        // as a per-owner discovery signal until the first settled period.
        auto owner_mobility_income = [&](BuildingGroupConstRef group,
                                         int64_t &sat) -> int64_t {
            if (group.type_id < 0 || group.type_id >= static_cast<int32_t>(
                    _building_types.size()) || group.count <= 0) return 0;
            // Suspended survival-food lots still need a discovery income so
            // empty hunting camps rank as mobility targets. Other suspended
            // shells stay at zero (planned_owner_demand already zeros them).
            if (group.operating_state == 1) {
                const BuildingType &suspended_type =
                    _building_types[group.type_id];
                bool survival_food = false;
                for (int32_t oi = 0; oi < suspended_type.output_count; ++oi) {
                    const int32_t good = _building_outputs[
                        suspended_type.output_begin + oi].good_id;
                    if (good >= 0 &&
                        good < static_cast<int32_t>(
                            _survival_food_good_mask.size()) &&
                        _survival_food_good_mask[good] != 0) {
                        survival_food = true;
                        break;
                    }
                }
                if (!survival_food) return 0;
            }
            const bool has_settled = group.last_output > 0 ||
                group.last_sold > 0 || group.last_market_receipt > 0 ||
                group.last_in_kind_livelihood_value > 0 ||
                group.last_input_cost > 0 || group.last_base_wages_paid > 0;
            if (!has_settled || group.operating_state == 1) {
                int64_t quote_sat = 0;
                EconomyCostProbe::record("owner_quote.call.emp_settle_gate",
                                          _current_day.get(), 0.0, 1);
                const OwnerOpportunityQuote quote = owner_opportunity_quote(
                    group, Q16_ONE, Q16_ONE, quote_sat);
                sat = saturating_add(sat, quote_sat, sat);
                if (!quote.feasible || quote.executable_capacity_q16 <= 0)
                    return 0;
                // Per-owner disposable (quote already ÷ owner seats).
                return std::max<int64_t>(0,
                    quote.disposable_survival_power_per_day);
            }
            return projected_owner_income_per_day(group, sat);
        };

        auto schedule_suspended_survival_restart = [&](BuildingGroupRef group) {
            if (group.operating_state != 1 || group.filled_owner <= 0) return;
            if (group.type_id < 0 || group.type_id >= static_cast<int32_t>(
                    _building_types.size())) return;
            const BuildingType &type = _building_types[group.type_id];
            bool survival_food = false;
            for (int32_t oi = 0; oi < type.output_count; ++oi) {
                const int32_t good =
                    _building_outputs[type.output_begin + oi].good_id;
                if (good >= 0 &&
                    good < static_cast<int32_t>(
                        _survival_food_good_mask.size()) &&
                    _survival_food_good_mask[good] != 0) {
                    survival_food = true;
                    break;
                }
            }
            if (!survival_food) return;
            // Employment refill is the unlock for labour-empty SUSPENDED_LOSS
            // food lots. Apply ACTIVE at the next due-cell boundary so this
            // period's production slice stays on the frozen operating state.
            group.pending_operating_state = 0;
            group.severe_loss_cycles = 0;
            group.recovery_failed_reviews = 0;
            group.recovery_cooldown_cycles = 0;
        };

        auto owner_mobility_cooldown_active = [&](int32_t source_group,
                                                  int32_t target_group) -> bool {
            for (const OwnerMobilityCooldown &entry : _owner_mobility_cooldowns) {
                if (entry.cell != cell) continue;
                if (entry.until_day < _current_day.get()) continue;
                if ((entry.source_group == source_group &&
                     entry.target_group == target_group) ||
                    (entry.source_group == target_group &&
                     entry.target_group == source_group)) {
                    return true;
                }
            }
            return false;
        };
        auto record_owner_mobility_cooldown = [&](int32_t source_group,
                                                  int32_t target_group) {
            const int64_t until = _current_day.get() + std::max<int32_t>(
                1, _employment_understaffed_mobility_cooldown_days);
            for (OwnerMobilityCooldown &entry : _owner_mobility_cooldowns) {
                if (entry.cell == cell &&
                    ((entry.source_group == source_group &&
                      entry.target_group == target_group) ||
                     (entry.source_group == target_group &&
                      entry.target_group == source_group))) {
                    entry.until_day = std::max(entry.until_day, until);
                    entry.source_group = source_group;
                    entry.target_group = target_group;
                    return;
                }
            }
            _owner_mobility_cooldowns.push_back(
                {cell, source_group, target_group, until});
        };


        // Employment mobility is evaluated in disposable-income space.  Owner
        // income already excludes the owner's living cost; employee wages do
        // not, so subtract the target signature's cost before comparing them.
        // The cadence-invariant period mobility was frozen before target
        // construction so retention and hiring use the same hazard.
        auto transition_hurdle_q16 = [&](int32_t source_profession,
                                         int32_t target_profession) -> int64_t {
            // The unemployed pool is the normal bootstrap and layoff entry
            // point. Requiring a positive income improvement here makes a
            // break-even first job unreachable when the target contract wage
            // equals the target livelihood floor.
            if (source_profession == _unemployed_profession_id)
                return 0;
            if (source_profession == target_profession)
                return std::max<int64_t>(1, _investment_displacement_min_advantage_q16);
            int64_t hurdle = std::max<int64_t>(Q16_ONE / 8,
                _investment_displacement_min_advantage_q16);
            if (target_profession == _merchant_profession_id &&
                source_profession != _merchant_profession_id) {
                hurdle = std::max<int64_t>(hurdle,
                    _investment_merchant_transition_min_improvement_q16.get());
            }
            return hurdle;
        };
        auto vacancy_profit_signal_q16 = [&](BuildingGroupConstRef group)
                -> int64_t {
            int64_t signal = std::clamp<int64_t>(
                group.realized_profit_margin_q16, 0, Q16_ONE);
            if (group.type_id < 0 || group.type_id >= static_cast<int32_t>(
                    _building_types.size()) || group.count <= 0)
                return signal;
            const BuildingType &type = _building_types[group.type_id];
            int64_t potential_revenue = 0;
            for (int32_t output_index = 0;
                 output_index < type.output_count; ++output_index) {
                const GoodAmount &output = _building_outputs[
                    type.output_begin + output_index];
                if (output.good_id < 0 || output.good_id >= static_cast<int32_t>(
                        _good_monetary_issue_values.size())) continue;
                const int64_t issue_value =
                    _good_monetary_issue_values[output.good_id];
                if (issue_value <= 0) continue;
                const int64_t quantity = effective_building_output_quantity(
                    group, output.good_id, output.quantity,
                    std::clamp<int64_t>(group.planned_utilization_q16,
                        0, Q16_ONE), 1, _saturation_count);
                int64_t executable_quantity = quantity;
                if (executable_quantity <= 0 && issue_value > 0) {
                    // Vacant collectors still bid on face × nameplate output.
                    executable_quantity = mul_div_sat(
                        std::max<int64_t>(0, output.quantity),
                        std::clamp<int64_t>(group.planned_utilization_q16,
                            0, Q16_ONE), Q16_ONE, _saturation_count);
                }
                executable_quantity = saturating_mul(
                    executable_quantity, std::max<int64_t>(1, group.count),
                    _saturation_count);
                potential_revenue = saturating_add(potential_revenue,
                    mul_div_sat(executable_quantity, issue_value, GOODS_SCALE,
                        _saturation_count), _saturation_count);
            }
            if (potential_revenue <= 0) return signal;
            int64_t living_floor_wage_pool = 0;
            for (int32_t role_offset = 0;
                 role_offset < type.employee_count; ++role_offset) {
                const JobRole &role = _building_employee_roles[
                    type.employee_begin + role_offset];
                const int64_t slots = saturating_mul(
                    group.count, role.slots_per_building, _saturation_count);
                const int32_t signal = labor_signal_index(cell, role.profession_id);
                const int64_t living_floor = signal >= 0
                    ? std::max(_labor_signals.base_living_cost[signal],
                        _labor_signals.role_living_cost[signal]) : 0;
                const int64_t market_quote = signal >= 0 && signal <
                        static_cast<int32_t>(_labor_signals.contract_wage_ema.size())
                    ? std::max(_labor_signals.contract_wage_ema[signal],
                        _labor_signals.paid_wage_ema[signal]) : 0;
                living_floor_wage_pool = saturating_add(living_floor_wage_pool,
                    saturating_mul(slots,
                        std::max(living_floor, market_quote),
                        _saturation_count), _saturation_count);
            }
            const int64_t input_cost = saturating_mul(
                std::max<int64_t>(0, group.sample_unit_input_cost),
                group.count, _saturation_count);
            const int64_t potential_profit = std::max<int64_t>(0,
                saturating_sub(potential_revenue,
                    saturating_add(input_cost, living_floor_wage_pool,
                        _saturation_count), _saturation_count));
            const int64_t potential_margin = mul_div_sat(
                potential_profit, Q16_ONE, potential_revenue,
                _saturation_count);
            return std::max(signal, std::clamp<int64_t>(
                potential_margin, 0, Q16_ONE));
        };
        auto vacancy_adjusted_hurdle_q16 = [&](int64_t base_hurdle,
                                               int32_t group_index,
                                               int32_t fill_index) -> int64_t {
            // Zero is the deliberate unemployed-entry hurdle. Vacancy relief
            // must not turn a break-even first job into an ineligible job.
            if (base_hurdle <= 0) return 0;
            if (group_index < 0 || group_index >= static_cast<int32_t>(
                    buildings_store().group_units.size()))
                return base_hurdle;
            const auto group = building_view(static_cast<size_t>(group_index));
            const BuildingType &type = _building_types[group.type_id];
            int64_t slots = 0;
            int64_t filled = 0;
            if (fill_index < 0) {
                slots = saturating_mul(group.count, type.owner_slots_per_building,
                    _saturation_count);
                filled = group.filled_owner;
            } else {
                if (fill_index < group.employee_fill_begin ||
                        fill_index >= group.employee_fill_begin + type.employee_count ||
                        fill_index >= static_cast<int32_t>(
                            _building_employee_filled.size()))
                    return base_hurdle;
                const JobRole &role = _building_employee_roles[
                    type.employee_begin + (fill_index - group.employee_fill_begin)];
                slots = saturating_mul(group.count, role.slots_per_building,
                    _saturation_count);
                filled = _building_employee_filled[fill_index];
            }
            slots = std::max<int64_t>(1, slots);
            filled = std::clamp<int64_t>(filled, 0, slots);
            const int64_t vacancy_q16 = mul_div_sat(
                slots - filled, Q16_ONE, slots, _saturation_count);
            const int64_t profit_q16 = vacancy_profit_signal_q16(group);
            // High-margin, deeply understaffed jobs are allowed to poach
            // earlier.  The relief is capped so a bad job cannot attract labor
            // merely by advertising a large vacancy.
            const int64_t relief_q16 = mul_div_sat(
                vacancy_q16, profit_q16, Q16_ONE, _saturation_count);
            const int64_t relief_cap = Q16_ONE / 2;
            const int64_t effective_relief = std::min(relief_cap, relief_q16);
            return std::max<int64_t>(1, mul_div_sat(
                base_hurdle, Q16_ONE - effective_relief, Q16_ONE,
                _saturation_count));
        };
        auto improvement_q16 = [&](int64_t current_disposable,
                                   int64_t target_disposable) -> int64_t {
            const int64_t gain = saturating_sub(target_disposable,
                                                current_disposable,
                                                _saturation_count);
            if (gain <= 0) return 0;
            // Both sides already include their livelihood terms. Reusing raw
            // living costs in this denominator applies the livelihood hurdle
            // twice and can make every positive vacancy unreachable from zero
            // unemployment income.
            const int64_t denominator = std::max<int64_t>(
                1, std::llabs(current_disposable));
            return std::clamp<int64_t>(mul_div_sat(
                gain, Q16_ONE, denominator, _saturation_count), 0,
                Q16_ONE * 4);
        };
        auto choice_factor_q16 = [&](int64_t improvement) -> int64_t {
            const int64_t temperature = std::max<int64_t>(1,
                _employment_choice_temperature_q16.get());
            const int64_t softened = mul_div_sat(
                std::max<int64_t>(0, improvement), Q16_ONE,
                saturating_add(Q16_ONE, temperature, _saturation_count),
                _saturation_count);
            return std::clamp<int64_t>(
                saturating_add(Q16_ONE, softened, _saturation_count),
                Q16_ONE, Q16_ONE * 5);
        };
        auto owner_entry_capital = [&](BuildingGroupConstRef group) -> int64_t {
            const int64_t owner_demand = std::max<int64_t>(1,
                planned_owner_demand(group, _saturation_count));
            if (group.sample_unit_input_cost <= 0 || group.count <= 0)
                return 0;
            const int64_t full_period_cost = saturating_mul(
                saturating_mul(group.sample_unit_input_cost, group.count,
                               _saturation_count),
                std::max<int64_t>(1, _epoch_days.get()), _saturation_count);
            // Match the household-market reserve: one entrant carries its
            // proportional share of the period's physical input bill.
            const int64_t operation_scale = employment_utilization_q16(group);
            return mul_div_sat(full_period_cost, operation_scale,
                Q16_ONE, _saturation_count) / owner_demand;
        };
        auto recent_expense_per_day = [&](int32_t slot) -> int64_t {
            if (slot < 0 || slot >= static_cast<int32_t>(population_store().population.size()))
                return 0;
            const int64_t people = std::max<int64_t>(1,
                population_store().population[slot]);
            const int64_t days = std::max<int64_t>(1, _epoch_days.get());
            return std::max<int64_t>(0, population_store().epoch_expense[slot]) /
                people / days;
        };
        auto unemployed_disposable_income = [&](int32_t slot) -> int64_t {
            if (slot < 0 || slot >= static_cast<int32_t>(
                    population_store().population.size())) return 0;
            const int32_t signature = static_cast<int32_t>(
                population_store().signature_id[slot]);
            if (signature < 0 || signature >= static_cast<int32_t>(
                    _signatures.size())) return 0;
            const int32_t profession = _signatures[signature].profession_id;
            if (profession != _unemployed_profession_id) return 0;
            // Savings and proportional ledger/EMA values carried into the
            // unemployed cohort are stocks or prior-period attribution, not
            // current employment income. A funded negative income tax is the
            // one current reservation-income source and must remain visible.
            const int32_t income_rate = frozen_tax_rate(
                cell, CountryApi::TAX_INCOME, profession);
            if (income_rate >= 0) return 0;
            const int64_t daily_floor = living_cost_for_signature(
                cell, signature, _living_cost_base_plan_id,
                _saturation_count);
            const int64_t signed_transfer = expected_resolved_fiscal_transfer(
                cell, CountryApi::TAX_INCOME, profession,
                daily_floor, 1, _saturation_count);
            const int64_t funded_transfer = std::max<int64_t>(0, saturating_sub(
                0, signed_transfer, _saturation_count));
            // A funded unemployment lane is reservation income during the
            // employment decision itself. Settlement runs later in the same
            // epoch, so expose the already reserved floor here as well.
            const int32_t fulfillment = static_cast<int32_t>(std::clamp<int64_t>(
                _fiscal_fulfillment_q16[static_cast<size_t>(cell) *
                    ACTIVE_TAX_KIND_COUNT + CountryApi::TAX_INCOME],
                0, Q16_ONE));
            const int64_t funded_period_floor = mul_div_sat(
                saturating_mul(daily_floor, std::max<int64_t>(1, _epoch_days.get()),
                    _saturation_count),
                fulfillment, Q16_ONE, _saturation_count);
            return std::max<int64_t>(funded_transfer, funded_period_floor);
        };
