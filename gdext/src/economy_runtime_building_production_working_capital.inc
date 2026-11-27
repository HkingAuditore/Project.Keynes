    struct WorkingCapitalCandidate {
        int32_t group = -1;
        int64_t score_q16 = 0;
        int64_t desired_cost = 0;
        int64_t minimum_executable_cost = 0;
        bool critical = false;
        bool survival = false;
    };
    thread_local std::vector<WorkingCapitalCandidate> candidates;
    std::fill(_building_funded_capacity_q16.begin() + begin,
              _building_funded_capacity_q16.begin() + end, 0);
    std::fill(_building_working_capital_allocated.begin() + begin,
              _building_working_capital_allocated.begin() + end, 0);
    for (size_t owner_index = 0; owner_index < payroll_owners.size(); ++owner_index) {
        const int32_t owner_signature = payroll_owners[owner_index];
        const int32_t owner_slot = find_cohort_slot(cell, owner_signature);
        if (owner_slot < 0) continue;
        int64_t wage_commitment = 0;
        int64_t expected_revenue = 0;
        int64_t filled_owner = 0;
        candidates.clear();
        candidates.reserve(static_cast<size_t>(std::max(0, end - begin)));
        for (int32_t gi = owner_group_offsets[owner_index];
             gi < owner_group_offsets[owner_index + 1]; ++gi) {
            const int32_t g = owner_groups[static_cast<size_t>(gi)];
            {
                const auto group_view = building_view(static_cast<size_t>(g));
                if (group_view.owner_signature_id != owner_signature ||
                    group_view.count <= 0 || group_view.operating_state == 1 ||
                    !building_available(cell, group_view.type_id, true)) continue;
            }
            auto group = building_at(static_cast<size_t>(g));
            const BuildingType &type = _building_types[group.type_id];
            wage_commitment = saturating_add(
                wage_commitment, group.last_base_wages_due, _saturation_count);
            expected_revenue = saturating_add(
                expected_revenue, group.last_expected_revenue, _saturation_count);
            filled_owner = saturating_add(filled_owner, group.filled_owner, _saturation_count);
            const int64_t desired_scale = desired_scale_for_group(group, type, false);
            group.purchase_intent_capacity_q16 = desired_scale;
            const int64_t desired_cost = group_input_cost_at_scale(
                group, type, desired_scale, false);
            int64_t survival_pressure = 0;
            int64_t ordinary_pressure = 0;
            int64_t downstream_pressure = 0;
            bool critical = false;
            bool survival_output = false;
            int64_t survival_absorption_q16 = 0;
            for (int32_t i = 0; i < type.output_count; ++i) {
                const int32_t good = _building_outputs[type.output_begin + i].good_id;
                const int64_t idx = market_store().index(market, good);
                const int64_t shortage = std::clamp<int64_t>(
                    market_store().last_shortage_q16[idx], 0, Q16_ONE);
                const bool survival = _survival_food_good_mask[good] != 0 ||
                    _survival_clothing_good_mask[good] != 0;
                if (survival) {
                    survival_pressure = std::max(survival_pressure, shortage);
                    critical = true;
                    survival_output = true;
                    const GoodAmount &output = _building_outputs[type.output_begin + i];
                    const int64_t offered =
                        effective_building_output_quantity(
                            group, output.good_id, output.quantity, desired_scale,
                            saturating_mul(group.count,
                                std::max(1, _epoch_days.get()), _saturation_count),
                            _saturation_count);
                    const int32_t signal = market_signal_index(cell, good);
                    const int64_t realized = signal >= 0
                        ? _market_signals.realized_withdrawal_ema[signal] : 0;
                    const int32_t flow = trade_flow_index(cell, good, false);
                    const int64_t exports = flow >= 0 ? _trade_flows.export_ema[flow] : 0;
                    const int64_t target = merchant_inventory_target(
                        market, good, signal, realized, exports,
                        offered / std::max(1, _epoch_days.get()), _saturation_count);
                    const int64_t quota = merchant_procurement_quota(
                        market, good, signal, offered, target,
                        market_store().stock[idx], realized, exports, _saturation_count);
                    if (offered > 0) {
                        survival_absorption_q16 = std::max<int64_t>(
                            survival_absorption_q16,
                            std::min<int64_t>(Q16_ONE, mul_div_sat(
                                quota, Q16_ONE, offered, _saturation_count)));
                    }
                } else {
                    ordinary_pressure = std::max(ordinary_pressure, shortage);
                }
                const int32_t signal = market_signal_index(cell, good);
                const int64_t demand = saturating_add(
                    signal >= 0 ? _market_signals.business_demand_ema[signal] : 0,
                    epoch_procurement_demand_daily(cell, good),
                    _saturation_count);
                if (demand > 0) {
                    const int64_t stock = market_store().stock[idx];
                    downstream_pressure = std::max<int64_t>(downstream_pressure,
                        std::clamp<int64_t>(mul_div_sat(
                            std::max<int64_t>(0, demand - stock), Q16_ONE,
                            std::max<int64_t>(1, demand), _saturation_count), 0, Q16_ONE));
                    critical = true;
                }
            }
            const int64_t contribution = std::clamp<int64_t>(
                Q16_ONE + group.last_margin_gap_q16, -Q16_ONE, 2 * Q16_ONE);
            const int64_t score = saturating_add(saturating_add(
                4 * survival_pressure, 3 * downstream_pressure, _saturation_count),
                saturating_add(2 * ordinary_pressure, contribution, _saturation_count),
                _saturation_count);
            int64_t executable_scale = desired_scale;
            if (survival_output) {
                // Survival output retained by the owner household is executable
                // even when the merchant inventory quota is temporarily zero.
                // Keep at least the owner share in the working-capital quote so
                // a subsistence producer can finance its required inputs.
                if (group.filled_owner > 0 && group.count > 0) {
                    survival_absorption_q16 = std::max<int64_t>(
                        survival_absorption_q16,
                        std::clamp<int64_t>(mul_div_sat(
                            std::min(group.filled_owner, group.count), Q16_ONE,
                            group.count, _saturation_count), 1, Q16_ONE));
                }
                executable_scale = mul_div_sat(executable_scale,
                    survival_absorption_q16, Q16_ONE, _saturation_count);
                if (type.behavior_id == 1 || type.behavior_id == 2) {
                    const int64_t building_days = saturating_mul(
                        group.count, std::max(1, _epoch_days.get()), _saturation_count);
                    for (int32_t edge = 0; edge < type.resource_count; ++edge) {
                        const ResourceAmount &item = _building_resources[
                            type.resource_begin + edge];
                        const int64_t base = item.mode == 1
                            ? saturating_mul(group.count, item.quantity, _saturation_count)
                            : saturating_mul(building_days, item.quantity, _saturation_count);
                        if (base <= 0) continue;
                        executable_scale = std::min<int64_t>(executable_scale,
                            resource_capacity_scale_q16(item, cell, base));
                    }
                }
            }
            const int64_t minimum_executable_cost = survival_output
                ? group_input_cost_at_scale(group, type,
                    std::clamp<int64_t>(executable_scale, 0, desired_scale), false)
                : 0;
            const int64_t fundable_cost = survival_output
                ? minimum_executable_cost : desired_cost;
            // A newly completed industrial group has no shortage EMA and may
            // still carry a PLAN margin of -1 while owner livelihood is high.
            // Without this cold-start bit, intent stays 1.0 and funded stays 0.
            const bool never_settled = group.last_output <= 0 &&
                group.last_input <= 0 && group.last_resource <= 0 &&
                group.last_resource_generated <= 0;
            if (never_settled && fundable_cost > 0 &&
                fundable_cost != std::numeric_limits<int64_t>::max()) {
                critical = true;
            }
            if (fundable_cost > 0 && fundable_cost != std::numeric_limits<int64_t>::max() &&
                (score > 0 || critical)) {
                candidates.push_back({g, score, fundable_cost,
                    minimum_executable_cost, critical, survival_output});
            }
        }
        const int64_t owner_cash = std::max<int64_t>(0, population_store().funds[owner_slot]);
        // Household clearing already protected this period's input float before
        // paying livelihood. Reserve only the wage gap here; holding livelihood
        // a second time permanently cuts the same owner's funded capacity.
        const int64_t wage_cash_gap = std::max<int64_t>(
            0, saturating_sub(wage_commitment, expected_revenue, _saturation_count));
        int64_t budget = std::max<int64_t>(
            0, owner_cash - std::min(owner_cash, wage_cash_gap));
        // After construction, remaining cash can sit below the unpaid wage bill.
        // Critical/survival groups still need that cash as input float; wages may
        // suspend if revenue does not cover them.
        if (budget == 0 && owner_cash > 0) {
            for (const WorkingCapitalCandidate &candidate : candidates) {
                if (candidate.critical || candidate.survival) {
                    budget = owner_cash;
                    break;
                }
            }
        }
        std::stable_sort(candidates.begin(), candidates.end(),
            [](const WorkingCapitalCandidate &a, const WorkingCapitalCandidate &b) {
                if (a.score_q16 != b.score_q16) return a.score_q16 > b.score_q16;
                return a.group < b.group;
            });
        auto allocate = [&](WorkingCapitalCandidate &candidate, int64_t target) {
            const int64_t current = _building_working_capital_allocated[candidate.group];
            const int64_t grant = std::min<int64_t>(budget, std::max<int64_t>(0, target - current));
            _building_working_capital_allocated[candidate.group] += grant;
            budget -= grant;
            _owner_working_capital_allocated = saturating_add(
                _owner_working_capital_allocated, grant, _saturation_count);
        };
        for (WorkingCapitalCandidate &candidate : candidates) {
            if (budget <= 0) break;
            if (candidate.survival) {
                allocate(candidate, candidate.minimum_executable_cost);
            } else if (candidate.critical) allocate(candidate, std::max<int64_t>(
                1, (candidate.desired_cost + 3) / 4));
        }
        for (WorkingCapitalCandidate &candidate : candidates) {
            if (budget <= 0) break;
            allocate(candidate, candidate.desired_cost);
        }
    }
    EconomyCostProbe::record("production.prepare.working_capital", _current_day.get(),
                             elapsed_ms(production_prepare_mark));
    EconomyCostProbe::record("production.sec_prepare", _current_day.get(),
                             elapsed_ms(production_cell_started));
