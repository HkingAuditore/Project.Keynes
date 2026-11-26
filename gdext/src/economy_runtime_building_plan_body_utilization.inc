        constexpr int64_t recovery_probe_floor_q16 = 0;
        // Dead by intent, not by accident: d3d061c96 replaced this old
        // "recovery probe" capacity pass with the executable/viable restart
        // decision above (pending_operating_state + credit_needed) and left the
        // block behind with a zero floor. Its only consumer,
        // economy_runtime_slice_execution.cpp's liquidation capacity, takes
        // max(planned_utilization_q16, probe_capacity), so a missing writer
        // degrades to planned utilization instead of blocking retirement.
        // Delete the block (and the zero floor constant) in a dedicated cleanup;
        // re-enabling it would double count _recovery_candidates and re-add a
        // cost model of zero.
        if (false && type.kind != 2 && group.operating_state == 1 && !suspended_now &&
            group.recovery_cooldown_cycles == 0) {
            const int32_t owner_slot = find_cohort_slot(group.cell, group.owner_signature_id);
            ++_recovery_candidates;
            const int64_t restart_input_cost = mul_div_sat(saturating_mul(
                saturating_mul(input_cost, group.count, _saturation_count),
                std::max(1, _epoch_days.get()), _saturation_count),
                recovery_probe_floor_q16, Q16_ONE, _saturation_count);
            const int64_t owner_cash = owner_slot >= 0
                ? std::max<int64_t>(0, population_store().funds[owner_slot]) : 0;
            const int64_t credit_needed = std::max<int64_t>(
                0, restart_input_cost - std::min(restart_input_cost, owner_cash));
            const bool credit_allowed = group.merchant_debt_delinquent_cycles == 0 &&
                credit_needed <= cell_credit_remaining;
            const bool finance_available = credit_needed == 0 ||
                (_merchant_credit_runtime_mode.get() != 0 && credit_allowed);
            bool physical_inputs_available = inputs_available;
            recovery_probe_goods.clear();
            const int64_t building_days = saturating_mul(
                group.count, std::max(1, _epoch_days.get()), _saturation_count);
            for (int32_t i = 0; physical_inputs_available && i < type.input_count; ++i) {
                const ProductionInput &item = _building_inputs[type.input_begin + i];
                const int64_t required_q16 = std::clamp<int64_t>(
                    item.required_q16, 0, Q16_ONE);
                if (required_q16 <= 0) continue;
                const int64_t floor_q16 = Q16_ONE - required_q16;
                if (recovery_probe_floor_q16 <= floor_q16) continue;
                const int64_t purchase_scale_q16 = std::min<int64_t>(Q16_ONE,
                    mul_div_sat(recovery_probe_floor_q16 - floor_q16,
                        Q16_ONE, required_q16, _saturation_count));
                const int64_t effective = saturating_mul(
                    building_days, item.quantity, _saturation_count);
                int32_t selected_good = -1;
                int64_t selected_quantity = 0;
                int64_t best_spare = -1;
                bool best_sufficient = false;
                int64_t best_effective_price = std::numeric_limits<int64_t>::max();
                for (int32_t c = item.candidate_begin;
                     c < item.candidate_begin + item.candidate_count; ++c) {
                    const InputCandidate &candidate = _building_input_candidates[c];
                if (!good_input_candidate_available(group.cell, candidate.good_id, true)) continue;
                    int64_t physical = mul_div_sat(
                        effective, Q16_ONE, candidate.efficiency_q16,
                        _saturation_count);
                    if (mul_div_sat(physical, candidate.efficiency_q16, Q16_ONE,
                                    _saturation_count) < effective) {
                        physical = saturating_add(physical, 1, _saturation_count);
                    }
                    physical = effective_production_input_quantity(
                        group.cell, candidate.good_id, physical,
                        _saturation_count);
                    int64_t quantity = saturating_add(saturating_mul(
                        physical, purchase_scale_q16, _saturation_count),
                        Q16_ONE - 1, _saturation_count) / Q16_ONE;
                    quantity = std::max<int64_t>(1, quantity);
                    int64_t reserved = 0;
                    for (const auto &entry : recovery_probe_goods) {
                        if (entry.first == candidate.good_id) reserved = entry.second;
                    }
                    const int64_t spare = std::max<int64_t>(0,
                        market_store().stock[market_store().index(market, candidate.good_id)] - reserved);
                    const int64_t unit_numerator = saturating_add(saturating_mul(
                        GOODS_SCALE, Q16_ONE, _saturation_count),
                        candidate.efficiency_q16 - 1, _saturation_count);
                    const int64_t unit_physical = effective_production_input_quantity(
                        group.cell, candidate.good_id,
                        unit_numerator / candidate.efficiency_q16,
                        _saturation_count);
                    const int64_t effective_price = mul_div_sat(
                        market_store().price[market_store().index(market, candidate.good_id)],
                        unit_physical, GOODS_SCALE, _saturation_count);
                    const bool sufficient = spare >= quantity;
                    if (sufficient != best_sufficient ? sufficient :
                        (spare > best_spare ||
                         (spare == best_spare &&
                          effective_price < best_effective_price))) {
                        selected_good = candidate.good_id;
                        selected_quantity = quantity;
                        best_spare = spare;
                        best_sufficient = sufficient;
                        best_effective_price = effective_price;
                    }
                }
                if (selected_good < 0 || best_spare < selected_quantity) {
                    physical_inputs_available = false;
                    break;
                }
                auto total = std::find_if(recovery_probe_goods.begin(),
                    recovery_probe_goods.end(), [&](const auto &entry) {
                        return entry.first == selected_good;
                    });
                if (total == recovery_probe_goods.end()) {
                    recovery_probe_goods.push_back({selected_good, selected_quantity});
                } else {
                    total->second = saturating_add(
                        total->second, selected_quantity, _saturation_count);
                }
            }
            bool physical_resources_available = true;
            if (type.behavior_id == 1 || type.behavior_id == 2) {
                for (int32_t i = 0; i < type.resource_count; ++i) {
                    const ResourceAmount &item =
                        _building_resources[type.resource_begin + i];
                    const int64_t raw_base = item.mode == 1
                        ? saturating_mul(group.count, item.quantity, _saturation_count)
                        : saturating_mul(building_days, item.quantity, _saturation_count);
                    const int64_t base = effective_resource_use_quantity(
                        group.cell, item.resource_id, raw_base, _saturation_count);
                    const int64_t required = saturating_add(saturating_mul(
                        base, recovery_probe_floor_q16, _saturation_count),
                        Q16_ONE - 1, _saturation_count) / Q16_ONE;
                    if (required > available_resource_amount(item, group.cell)) {
                        physical_resources_available = false;
                        break;
                    }
                }
            }
            const bool executable = physical_inputs_available &&
                physical_resources_available && finance_available;
            const bool viable = expected_profit_margin >= _building_restart_margin_q16.get() &&
                executable;
            if (group_index < static_cast<int32_t>(
                    _building_recovery_liquidation_eligible.size())) {
                _building_recovery_liquidation_eligible[group_index] =
                    executable &&
                    expected_profit_margin < _building_restart_margin_q16.get();
            }
            if (viable) {
                _building_merchant_credit_limit[group_index] = credit_needed;
                _merchant_credit_committed = saturating_add(
                    _merchant_credit_committed, credit_needed, _saturation_count);
                cell_credit_remaining -= credit_needed;
                if (_merchant_credit_runtime_mode.get() == 2) {
                    // The legacy probe branch is unreachable. Keep any
                    // defensive transition in the suspended state so an old
                    // execution path can never publish state 2.
                    group.operating_state = 1;
                    group.pending_operating_state = 255;
                    group.recovery_cycles = 0;
                    ++_recovery_approved;
                    invalidate_cell_monetary_units(group.cell);
                }
            }
        }
        if (group.operating_state != 1) {
            // A rational operator scales only against expected after-tax cash
            // profit. Demand, inventory, sell-through and shortages contribute
            // to the revenue forecast above, but are not independent priorities
            // or health gates. Physical input/resource capacity remains applied
            // below because it is an execution constraint, not a preference.
            const int64_t expected_operating_cost = saturating_add(
                saturating_add(input_cost, employee_wages, _saturation_count),
                saturating_add(owner_living_cost, maintenance_cost,
                    _saturation_count), _saturation_count);
            const int64_t expected_business_eligible_cost = saturating_add(
                saturating_add(input_cost, employee_wages, _saturation_count),
                maintenance_cost, _saturation_count);
            const int32_t business_rate = frozen_tax_rate(
                group.cell, CountryApi::TAX_BUSINESS, group.type_id);
            const int64_t business_base = business_rate < 0
                ? expected_business_eligible_cost : std::max<int64_t>(0, revenue);
            const int64_t business_transfer = expected_resolved_fiscal_transfer(
                group.cell, CountryApi::TAX_BUSINESS, group.type_id,
                business_base, 1, _saturation_count);
            const int64_t income_base = std::max<int64_t>(0,
                saturating_sub(saturating_sub(
                    revenue, expected_business_eligible_cost, _saturation_count),
                    std::max<int64_t>(0, business_transfer), _saturation_count));
            const int32_t income_rate = frozen_tax_rate(
                group.cell, CountryApi::TAX_INCOME,
                type.owner_profession_id);
            const int64_t income_transfer = expected_resolved_fiscal_transfer(
                group.cell, CountryApi::TAX_INCOME,
                type.owner_profession_id,
                income_rate < 0
                    ? std::max<int64_t>(income_base, owner_living_cost)
                    : income_base,
                1, _saturation_count);
            // Owner-retained output is economic income for every building.
            // Cache the current-price opportunity quote for this group during
            // the frozen epoch, rather than reusing last epoch's currency
            // value. A new epoch invalidates the cache and observes prices,
            // stocks, and demand again.
            thread_local const NativeEconomyRuntime *in_kind_cache_runtime = nullptr;
            thread_local int64_t in_kind_cache_epoch = std::numeric_limits<int64_t>::min();
            thread_local std::vector<int64_t> in_kind_cache_values;
            thread_local std::vector<uint8_t> in_kind_cache_valid;
            if (in_kind_cache_runtime != this || in_kind_cache_epoch != _epoch_id.get()) {
                in_kind_cache_runtime = this;
                in_kind_cache_epoch = _epoch_id.get();
                in_kind_cache_values.assign(building_count(), 0);
                in_kind_cache_valid.assign(building_count(), 0);
            } else if (in_kind_cache_values.size() < building_count()) {
                const size_t old_size = in_kind_cache_values.size();
                in_kind_cache_values.resize(building_count(), 0);
                in_kind_cache_valid.resize(building_count(), 0);
                std::fill(in_kind_cache_valid.begin() + old_size,
                    in_kind_cache_valid.end(), 0);
            }
            int64_t expected_in_kind = 0;
            if (group.index >= 0 && group.index < static_cast<int32_t>(
                    in_kind_cache_values.size())) {
                const size_t cache_index = static_cast<size_t>(group.index);
                if (in_kind_cache_valid[cache_index] == 0) {
                    EconomyCostProbe::record("owner_quote.call.plan_inkind",
                                              _current_day.get(), 0.0, 1);
                    const OwnerOpportunityQuote opportunity = owner_opportunity_quote(
                        group, Q16_ONE, Q16_ONE, _saturation_count);
                    in_kind_cache_values[cache_index] = std::max<int64_t>(0,
                        opportunity.in_kind_retail_value);
                    in_kind_cache_valid[cache_index] = 1;
                }
                expected_in_kind = in_kind_cache_values[cache_index];
            }
            const int64_t expected_cash_profit = saturating_sub(
                saturating_sub(saturating_sub(revenue, expected_operating_cost,
                    _saturation_count), business_transfer, _saturation_count),
                income_transfer, _saturation_count);
            // When an observed group uses its realized-receipt quote above,
            // retained owner output is already part of `revenue`.  Add the
            // counterfactual in-kind quote only for unobserved groups so the
            // unified income basis does not count the same livelihood twice.
            const int64_t expected_profit = saturating_add(
                expected_cash_profit,
                observed_capacity ? 0 : expected_in_kind,
                _saturation_count);
            // Pure self-employment (no employees) with positive net owner income
            // after operating costs and taxes keeps full planned utilization
            // instead of collapsing to the 3.1% probe floor on planning days
            // (matching positive_self_employment in the suspension gate above).
            const int64_t expected_owner_net_income = saturating_add(
                expected_profit, owner_living_cost, _saturation_count);
            const bool positive_planned_self_employment =
                type.employee_count == 0 && expected_owner_net_income > 0;
            group.planned_utilization_q16 =
                (expected_profit > 0 || positive_planned_self_employment)
                    ? static_cast<int32_t>(Q16_ONE) : 0;
            // Survival output is a bounded exception to pure cash-profit
            // gating. It may run only far enough to cover the frozen
            // subsistence/clothing floor computed for this owner, while its
            // monetary forecast remains the factual receipt above (possibly
            // zero). Resource, input, climate, and working-capital checks
            // below still constrain what can actually execute.
            if (group_index >= 0 && group_index < static_cast<int32_t>(
                    _building_survival_utilization_floor_q16.size())) {
                group.planned_utilization_q16 = std::max<int32_t>(
                    group.planned_utilization_q16,
                    static_cast<int32_t>(std::clamp<int64_t>(
                        _building_survival_utilization_floor_q16[group_index],
                        0, Q16_ONE)));
            }
            // Keep a bounded industrial probe for an occupied group even when
            // the current quote is temporarily unprofitable or input-funded
            // production is blocked. This preserves intent and the next
            // cycle's demand signal without creating a vacant owner or
            // bypassing physical input checks.
            if (group.filled_owner > 0 && type.input_count > 0 &&
                type.output_count > 0) {
                int32_t probe_floor_q16 = Q16_ONE / 32 + 1;
                for (int32_t i = 0; i < type.output_count; ++i) {
                    const int32_t output_good = _building_outputs[
                        type.output_begin + i].good_id;
                    if (output_good >= 0 && output_good <
                            static_cast<int32_t>(_good_storage_modes.size()) &&
                        _good_storage_modes[output_good] == 1) {
                        probe_floor_q16 = std::max<int32_t>(
                            probe_floor_q16, Q16_ONE / 6 + 1);
                    }
                }
                group.planned_utilization_q16 = std::max<int32_t>(
                    group.planned_utilization_q16, probe_floor_q16);
            }
        } else {
            group.planned_utilization_q16 = 0;
        }
        // Natural constraints are applied once by the production quote.  The
        // planning pass only decides whether the group wants to operate; it
        // must not pre-clamp the same plan by resource and climate again.
        // Otherwise owner/finance intent, resource capacity, and climate are
        // all counted as competing utilization minima before production even
        // gets a chance to form the final output quantity.
        if (group_index < static_cast<int32_t>(
                _building_planned_capacity_before_climate_q16.size())) {
            _building_planned_capacity_before_climate_q16[group_index] =
                group.planned_utilization_q16;
        }
        const int64_t effective_execution_q16 = std::min<int64_t>(
            std::clamp<int64_t>(actual_workforce_capacity_q16, 0, Q16_ONE),
            std::clamp<int64_t>(group.planned_utilization_q16, 0, Q16_ONE));
        group.purchase_intent_capacity_q16 = 0;
        const int64_t group_days = saturating_mul(
            group.count, std::max(1, _epoch_days.get()), _saturation_count);
        group.last_expected_revenue = mul_div_sat(
            saturating_mul(group_days, full_capacity_revenue, _saturation_count),
            effective_execution_q16, Q16_ONE, _saturation_count);
        group.last_quoted_market_receipt = group.last_expected_revenue;
        group.last_quoted_operating_cost = mul_div_sat(
            saturating_mul(group_days, operating, _saturation_count),
            effective_execution_q16, Q16_ONE, _saturation_count);
        group.last_maintenance_due = mul_div_sat(
            saturating_mul(group_days, maintenance_cost, _saturation_count),
            effective_execution_q16, Q16_ONE, _saturation_count);
        if (margin_gap < 0) ++_unprofitable_building_groups;
        if (group.operating_state != 0) ++_loss_suspended_building_groups;
        _utilization_sum_q16 = saturating_add(
            _utilization_sum_q16, group.planned_utilization_q16, _saturation_count);
