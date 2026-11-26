        if (type.kind != 2 && group.operating_state == 1 && !suspended_now &&
            group.recovery_cooldown_cycles == 0) {
            ++_recovery_candidates;
            const int64_t building_days = saturating_mul(
                group.count, std::max(1, _epoch_days.get()), _saturation_count);
            // Soft inputs (required_q16 < 1) are optional productivity, not an
            // entry gate. Match production/investment: missing soft stock only
            // lowers executable throughput via (1-required)+required*coverage,
            // and must not keep a profitable suspended lot permanently idle
            // (e.g. flint_quarry tools shelf empty after a price spike).
            bool physical_inputs_available = true;
            int64_t soft_coverage_scale_q16 = Q16_ONE;
            int64_t restart_input_unit_cost = 0;
            int64_t restart_hard_input_unit_cost = 0;
            for (int32_t i = 0; i < type.input_count && physical_inputs_available; ++i) {
                const ProductionInput &item = _building_inputs[type.input_begin + i];
                const int64_t required_q16 = std::clamp<int64_t>(
                    item.required_q16, 0, Q16_ONE);
                if (required_q16 <= 0) continue;
                const int64_t effective = saturating_mul(
                    building_days, item.quantity, _saturation_count);
                bool candidate_available = false;
                int64_t best_unit_cost = std::numeric_limits<int64_t>::max();
                for (int32_t c = item.candidate_begin;
                     c < item.candidate_begin + item.candidate_count; ++c) {
                    const InputCandidate &candidate = _building_input_candidates[c];
                    if (!good_input_candidate_available(group.cell, candidate.good_id, true)) continue;
                    int64_t physical = mul_div_sat(effective, Q16_ONE,
                        std::max<int32_t>(1, candidate.efficiency_q16),
                        _saturation_count);
                    if (mul_div_sat(physical, candidate.efficiency_q16,
                            Q16_ONE, _saturation_count) < effective)
                        physical = saturating_add(physical, 1, _saturation_count);
                    physical = effective_production_input_quantity(
                        group.cell, candidate.good_id, physical, _saturation_count);
                    const int64_t physical_numerator = saturating_add(
                        saturating_mul(item.quantity, Q16_ONE, _saturation_count),
                        candidate.efficiency_q16 - 1, _saturation_count);
                    const int64_t unit_physical = effective_production_input_quantity(
                        group.cell, candidate.good_id,
                        physical_numerator / std::max<int32_t>(1, candidate.efficiency_q16),
                        _saturation_count);
                    const int64_t candidate_cost = mul_div_sat(
                        unit_physical,
                        market_store().price[market_store().index(market, candidate.good_id)],
                        GOODS_SCALE, _saturation_count);
                    if (market_store().stock[market_store().index(market, candidate.good_id)] >= physical) {
                        candidate_available = true;
                        best_unit_cost = std::min(best_unit_cost, candidate_cost);
                    }
                }
                if (required_q16 >= Q16_ONE) {
                    physical_inputs_available = candidate_available;
                    if (candidate_available &&
                        best_unit_cost != std::numeric_limits<int64_t>::max()) {
                        restart_input_unit_cost = saturating_add(
                            restart_input_unit_cost, best_unit_cost,
                            _saturation_count);
                        restart_hard_input_unit_cost = saturating_add(
                            restart_hard_input_unit_cost, best_unit_cost,
                            _saturation_count);
                    }
                } else if (candidate_available &&
                    best_unit_cost != std::numeric_limits<int64_t>::max()) {
                    // Soft and stocked: bill only the covered share that
                    // production would actually purchase.
                    restart_input_unit_cost = saturating_add(
                        restart_input_unit_cost, best_unit_cost,
                        _saturation_count);
                } else {
                    // Soft and unstocked: coverage 0 → efficiency 1-required.
                    soft_coverage_scale_q16 = std::min<int64_t>(
                        soft_coverage_scale_q16, Q16_ONE - required_q16);
                }
            }
            // Production clamps a resource-limited group to its capacity or
            // safe-harvest budget, so restart needs one building's worth, not
            // the whole group: 35 hunting camps built in a good decade need
            // far more than the regrown game's safe harvest and would
            // otherwise stay shut forever while the cell starves of protein.
            bool physical_resources_available = true;
            if (type.behavior_id == 1 || type.behavior_id == 2) {
                for (int32_t i = 0; i < type.resource_count; ++i) {
                    const ResourceAmount &item = _building_resources[type.resource_begin + i];
                    const int64_t raw_base = item.mode == 1
                        ? item.quantity
                        : saturating_mul(std::max(1, _epoch_days.get()),
                            item.quantity, _saturation_count);
                    const int64_t base = effective_resource_use_quantity(
                        group.cell, item.resource_id, raw_base, _saturation_count);
                    if (base > available_resource_amount(item, group.cell)) {
                        physical_resources_available = false;
                        break;
                    }
                }
            }
            const int32_t owner_slot = find_cohort_slot(
                group.cell, group.owner_signature_id);
            int64_t owner_slot_cash = owner_slot >= 0
                ? std::max<int64_t>(0, population_store().funds[owner_slot]) : 0;
            // Suspension moves the owner, including savings, into unemployment.
            // Quote the cash that idle recruits would carry back with them;
            // an empty canonical slot must not force a wealthy former owner to
            // borrow (or reject them because the old lot has overdue debt).
            // This is eligibility only: employment transfers the actual share,
            // and production independently caps purchases by installed cash.
            int64_t recruitable = std::max<int64_t>(0,
                saturating_mul(group.count, type.owner_slots_per_building,
                    _saturation_count) - (owner_slot >= 0
                    ? population_store().population[owner_slot] : 0));
            population_store().for_each_in_cell(group.cell, [&](int32_t slot) {
                if (recruitable <= 0 || slot == owner_slot || is_merchant_slot(slot)) return;
                const int64_t people = population_store().population[slot];
                if (people <= 0) return;
                const uint32_t signature = population_store().signature_id[slot];
                if (signature >= _signatures.size()) return;
                const int32_t profession = _signatures[signature].profession_id;
                if (profession != _unemployed_profession_id &&
                    profession != type.owner_profession_id) return;
                const int64_t idle = std::max<int64_t>(0, people -
                    population_store().owner_employed[slot] -
                    population_store().employee_employed[slot]);
                const int64_t moving = std::min(recruitable, idle);
                owner_slot_cash = saturating_add(owner_slot_cash,
                    mul_div_sat(std::max<int64_t>(0, population_store().funds[slot]),
                        moving, people, _saturation_count), _saturation_count);
                recruitable -= moving;
            });
            // Restart finance bills only hard inputs and employee wages. Soft
            // tools are optional productivity bought from the recruited
            // owners' carried savings; billing them, or owner livelihood
            // (paid by the lot's own output, cash or in kind), made every
            // suspended lot with delinquent merchant debt need credit it could
            // never get, so a profitable hunting camp stayed shut forever
            // while its cell starved.
            const int64_t restart_cost = saturating_add(
                saturating_mul(restart_hard_input_unit_cost, building_days,
                    _saturation_count), saturating_mul(employee_wages,
                    building_days, _saturation_count), _saturation_count);
            const int64_t credit_needed = std::max<int64_t>(0,
                restart_cost - std::min(restart_cost, owner_slot_cash));
            const bool finance_available = credit_needed == 0 ||
                (_merchant_credit_runtime_mode.get() != 0 &&
                 group.merchant_debt_delinquent_cycles == 0 &&
                 credit_needed <= cell_credit_remaining);
            // Owner-operated buildings cannot restart without local labour that
            // can refill the canonical owner signature. SUSPENDED_LOSS sheds
            // owners into unemployment, so an emptied signature alone must not
            // block restart when the unemployed pool (or same profession) still
            // has people. Ledger population commands apply after this plan
            // stage; early-apply due population adjusts before planning so the
            // hireable check and tests that drain labour stay coherent.
            bool owner_cohort_live = owner_slot >= 0 &&
                owner_slot < static_cast<int32_t>(
                    population_store().population.size()) &&
                population_store().population[owner_slot] > 0;
            int64_t hireable_owner_labor = 0;
            if (!owner_cohort_live && type.owner_slots_per_building > 0) {
                population_store().for_each_in_cell(group.cell, [&](int32_t slot) {
                    if (is_merchant_slot(slot)) return;
                    const uint32_t sig = population_store().signature_id[slot];
                    if (sig >= _signatures.size()) return;
                    // Profitable recovery may draw cross-profession labour via
                    // the next employment pass (same path as survival-food
                    // restarts). Counting only unemployed / same-profession
                    // workers left flint quarries locked when every local adult
                    // was pinned on gathering after the unemployed pool cleared.
                    hireable_owner_labor = saturating_add(
                        hireable_owner_labor,
                        std::max<int64_t>(0, population_store().population[slot]),
                        _saturation_count);
                });
            }
            const bool owner_available = type.owner_slots_per_building <= 0 ||
                owner_cohort_live || hireable_owner_labor > 0;
            const bool executable = owner_available && physical_inputs_available &&
                physical_resources_available && finance_available;
            // Counterfactual restart margin must match the executable soft path:
            // unstocked soft inputs cut throughput and drop out of operating cost.
            int64_t recovery_profit_margin = expected_profit_margin;
            int64_t recovery_margin_denominator = std::max<int64_t>(
                MONEY_SCALE, operating);
            if (soft_coverage_scale_q16 < Q16_ONE ||
                restart_input_unit_cost != input_cost) {
                const int64_t recovery_revenue = mul_div_sat(
                    revenue, soft_coverage_scale_q16, Q16_ONE, _saturation_count);
                const int64_t recovery_operating = saturating_add(
                    saturating_add(saturating_add(restart_input_unit_cost,
                        employee_wages, _saturation_count),
                        owner_living_cost, _saturation_count),
                    maintenance_cost, _saturation_count);
                recovery_margin_denominator = std::max<int64_t>(
                    MONEY_SCALE, recovery_operating);
                const int64_t recovery_business_eligible = saturating_add(
                    saturating_add(restart_input_unit_cost, employee_wages,
                        _saturation_count),
                    maintenance_cost, _saturation_count);
                const int64_t recovery_business_base = expected_business_rate < 0
                    ? recovery_business_eligible
                    : std::max<int64_t>(0, recovery_revenue);
                const int64_t recovery_business_transfer =
                    expected_resolved_fiscal_transfer(
                        group.cell, CountryApi::TAX_BUSINESS,
                        group.type_id, recovery_business_base, 1,
                        _saturation_count);
                const int64_t recovery_income_base = std::max<int64_t>(0,
                    saturating_sub(saturating_sub(
                        recovery_revenue, recovery_business_eligible,
                        _saturation_count),
                        std::max<int64_t>(0, recovery_business_transfer),
                        _saturation_count));
                const int64_t recovery_income_transfer =
                    expected_resolved_fiscal_transfer(
                        group.cell, CountryApi::TAX_INCOME,
                        type.owner_profession_id,
                        expected_income_rate < 0
                            ? std::max<int64_t>(
                                recovery_income_base, owner_living_cost)
                            : recovery_income_base,
                        1, _saturation_count);
                const int64_t recovery_after_tax = saturating_sub(
                    saturating_sub(saturating_sub(recovery_revenue,
                        recovery_operating, _saturation_count),
                        recovery_business_transfer, _saturation_count),
                    recovery_income_transfer, _saturation_count);
                recovery_profit_margin = recovery_operating <= 0
                    ? (recovery_after_tax > 0 ? Q16_ONE : 0)
                    : mul_div_sat(recovery_after_tax, Q16_ONE,
                        std::max<int64_t>(MONEY_SCALE, recovery_operating),
                        _saturation_count);
                recovery_profit_margin = std::clamp<int64_t>(
                    recovery_profit_margin, -Q16_ONE, Q16_ONE);
            }
            // Owner-retained output is income for every building, including a
            // suspended one. Revalue it at the current market price in the
            // same recovery decision; do not create a food-only exception.
            if (executable) {
                int64_t quote_sat = 0;
                EconomyCostProbe::record("owner_quote.call.plan_recovery",
                                          _current_day.get(), 0.0, 1);
                const OwnerOpportunityQuote recovery_quote =
                    owner_opportunity_quote(group, Q16_ONE, Q16_ONE, quote_sat);
                const int64_t recovery_cash_profit = mul_div_sat(
                    recovery_profit_margin, recovery_margin_denominator,
                    Q16_ONE, _saturation_count);
                const int64_t recovery_total_profit = saturating_add(
                    recovery_cash_profit,
                    std::max<int64_t>(0, recovery_quote.in_kind_retail_value),
                    _saturation_count);
                recovery_profit_margin = std::clamp<int64_t>(mul_div_sat(
                    recovery_total_profit, Q16_ONE,
                    recovery_margin_denominator, _saturation_count),
                    -Q16_ONE, Q16_ONE);
                _saturation_count = saturating_add(_saturation_count, quote_sat,
                    _saturation_count);
            }
            if (group_index < static_cast<int32_t>(
                    _building_recovery_liquidation_eligible.size())) {
                _building_recovery_liquidation_eligible[group_index] =
                    executable &&
                    recovery_profit_margin < _building_restart_margin_q16.get();
            }
            // Recovery must be able to bootstrap an empty owner roster. The
            // employment pass only advertises vacancies for ACTIVE groups, so
            // requiring an already seated owner here creates a circular gate.
            // All buildings use the same current-price cash + owner-retained
            // income test; survival goods receive no special profitability
            // exemption.
            const bool viable = executable &&
                recovery_profit_margin >= _building_restart_margin_q16.get();
            if (viable) {
                group.pending_operating_state = 0;
                group.severe_loss_cycles = 0;
                group.recovery_failed_reviews = 0;
                group.recovery_cooldown_cycles = 0;
                if (credit_needed > 0) {
                    _building_merchant_credit_limit[group_index] = credit_needed;
                    _merchant_credit_committed = saturating_add(
                        _merchant_credit_committed, credit_needed, _saturation_count);
                    cell_credit_remaining -= credit_needed;
                }
                ++_recovery_approved;
                ++_recovery_restarted;
            }
        }
