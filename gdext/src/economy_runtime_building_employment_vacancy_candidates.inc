        // Upward mobility requires per-capita savings worth the target
        // profession's entry days of local living cost, standing in for the
        // education the simulation does not model. Moves from a profession
        // with an equal or higher gate stay free.
        const int64_t entry_living_cost = cell < static_cast<int32_t>(
                _cell_living_cost_per_capita.size())
            ? std::max<int64_t>(0, _cell_living_cost_per_capita[cell]) : 0;
        auto entry_savings_days = [&](int32_t profession) -> int64_t {
            return profession >= 0 && profession < static_cast<int32_t>(
                    _profession_entry_savings_days.size())
                ? _profession_entry_savings_days[static_cast<size_t>(profession)] : 0;
        };
        auto entry_savings_allows = [&](int32_t source_slot,
                                        int32_t source_profession,
                                        int32_t target_profession) -> bool {
            const int64_t required_days = entry_savings_days(target_profession);
            if (required_days <= 0 ||
                    entry_savings_days(source_profession) >= required_days)
                return true;
            if (source_slot < 0) return false;
            const int64_t people = std::max<int64_t>(1,
                population_store().population[source_slot]);
            const int64_t per_capita = std::max<int64_t>(0,
                population_store().funds[source_slot]) / people;
            return per_capita >= saturating_mul(
                entry_living_cost, required_days, _saturation_count);
        };

        // ---- 绗?姝?鎷涗汉锛氭寜 cell-local attraction 姣斾緥浠?unemployed 姹犲閲忚縼鍥?----
        // 浼樺厛绾ч敭锛?realized_profit_margin_q16 desc, planned_utilization_q16 desc,
        //            group_index asc)銆傛帓搴忕矑搴?璺?BuildingGroup锛堣法寤虹瓚绫诲瀷锛夛紱
        // 鍚?type_id+鍚?owner_signature 鑱氬悎鐨勭粍鍐呯泩鍒?鍒╃敤鐜囩浉鍚岋紝缁勫唴涓嶆帓锛堢ǔ瀹氬簭锛夈€?
        // 姹犲彲鐢ㄩ噺锛氭寜 eth 缂撳瓨鍚?unemployed|eth slot 鐨勫綋鍓嶄汉鍙ｄ笌 slot id銆?
        // 鎷?owner 闇€绮剧‘ eth锛坓roup.owner_signature 鐨?eth锛夛紱鎷?employee 鍙法 eth
        // 锛堟寜 eth 鍗囧簭鍙栨睜锛屼繚纭畾锛夈€傛嫑浜哄湪閬嶅巻澶栭€?group 鎵ц杩佺Щ锛屾瘡娆¤縼绉诲悗
        // 閲嶆柊瀹氫綅姹?slot锛堝彲鑳借 drain 閲婃斁锛夈€?
        EconomyCostProbe::record("employment.cell_migrate", _current_day.get(),
                                 elapsed_ms(employment_hire_started));
        auto pool_slot_for_eth = [&](int32_t eth) -> int32_t {
            ++employment_pool_lookups;
            const int32_t sig = unemployed_signature_for_ethnicity(eth);
            if (sig < 0) return -1;
            return population_store().find_signature(cell, static_cast<uint32_t>(sig));
        };
        const bool capture_employment_diagnostics = cell == _inspector_trace_cell;
        if (capture_employment_diagnostics) {
            _employment_diagnostic_cell = cell;
            _employment_diagnostic_day = _current_day.get();
            _employment_diagnostics.clear();
        }
        thread_local std::vector<int64_t> unemployed_budget_by_eth;
        struct EmploymentSourcePool {
            int32_t source_slot = -1;
            int32_t source_group = -1;
            int32_t source_role = -1;
            int32_t profession = -1;
            int32_t ethnicity = -1;
            int64_t available_population = 0;
            int64_t current_disposable_income = 0;
            int64_t transferable_funds = 0;
        };
        thread_local std::vector<EmploymentSourcePool> employment_source_pools;
        unemployed_budget_by_eth.assign(static_cast<size_t>(n_eth), 0);
        employment_source_pools.clear();
        for (int32_t eth = 0; eth < n_eth; ++eth) {
            const int32_t pool = pool_slot_for_eth(eth);
            if (pool < 0) continue;
            const int32_t source_signature = static_cast<int32_t>(
                population_store().signature_id[pool]);
            const int64_t source_cost = living_cost_for_signature(
                cell, source_signature, -1, _saturation_count);
            const int64_t available = std::max<int64_t>(0,
                population_store().population[pool]);
            const int64_t current_disposable = available > 0
                ? unemployed_disposable_income(pool) : 0;
            employment_source_pools.push_back({
                pool, -1, -1,
                source_signature >= 0 && source_signature <
                    static_cast<int32_t>(_signatures.size())
                    ? _signatures[source_signature].profession_id : -1,
                eth, available, current_disposable,
                std::max<int64_t>(0, population_store().funds[pool] -
                    saturating_mul(saturating_mul(source_cost, available,
                        _saturation_count), 30, _saturation_count))});
            unemployed_budget_by_eth[static_cast<size_t>(eth)] = mul_div_sat(
                available,
                mobility_period_q16, Q16_ONE, _saturation_count);
            if (mobility_period_q16 > 0 &&
                population_store().population[pool] > 0 &&
                unemployed_budget_by_eth[static_cast<size_t>(eth)] == 0) {
                unemployed_budget_by_eth[static_cast<size_t>(eth)] = 1;
            }
        }
        auto labor_pay_ratio_q16 = [&](int32_t profession) -> int64_t {
            const int32_t signal = labor_signal_index(cell, profession);
            if (signal < 0 || signal >= static_cast<int32_t>(
                    _labor_signals.pay_ratio_q16.size())) return Q16_ONE;
            return std::clamp<int64_t>(
                _labor_signals.pay_ratio_q16[signal], 0, Q16_ONE);
        };
        auto vacancy_weight = [&](int64_t target_disposable,
                                  int64_t vacancy,
                                  int32_t profession,
                                  int64_t utilization_q16) -> int64_t {
            if (vacancy <= 0) return 0;
            const int64_t income_term = target_disposable <= 0
                ? Q16_ONE / 4
                : choice_factor_q16(std::clamp<int64_t>(
                    target_disposable, 0, Q16_ONE * 4));
            const int64_t payment_term = (Q16_ONE +
                labor_pay_ratio_q16(profession)) / 2;
            const int64_t utilization_term = (Q16_ONE +
                std::clamp<int64_t>(utilization_q16, 0, Q16_ONE)) / 2;
            int64_t weight = saturating_mul(vacancy, income_term,
                                             _saturation_count);
            weight = mul_div_sat(weight, payment_term, Q16_ONE,
                                 _saturation_count);
            return mul_div_sat(weight, utilization_term, Q16_ONE,
                               _saturation_count);
        };
        // Keep all candidates in one cell-local pool. An unemployed cohort has
        // one source signature per ethnicity, so ethnicity remains the compact
        // source-pool key while every feasible vacancy participates in the
        // attraction denominator.
        struct EmploymentJobOption {
            int32_t group = -1;
            int32_t role = -1; // -1 = owner vacancy, otherwise role index
            int32_t target_signature = -1;
            int32_t profession = -1;
            int32_t source_ethnicity = -1;
            int64_t vacancy = 0;
            int64_t target_disposable = 0;
            int64_t weight_q16 = 0;
            int64_t allocated_move = 0;
            int64_t remainder = 0;
            int32_t margin_q16 = 0;
            int64_t utilization_q16 = 0;
            int32_t diagnostic_index = -1;
        };
        thread_local std::vector<EmploymentJobOption> employment_candidates;
        employment_candidates.clear();
        employment_candidates.reserve(hire_order.size() *
            static_cast<size_t>(std::max(1, n_eth)) * 2);
        auto candidate_better = [&](const EmploymentJobOption &a,
                                    const EmploymentJobOption &b) {
            if (a.target_disposable != b.target_disposable)
                return a.target_disposable > b.target_disposable;
            if (a.margin_q16 != b.margin_q16)
                return a.margin_q16 > b.margin_q16;
            if (a.utilization_q16 != b.utilization_q16)
                return a.utilization_q16 > b.utilization_q16;
            if (a.group != b.group) return a.group < b.group;
            return a.role < b.role;
        };
        auto add_candidate = [&](int32_t eth, const EmploymentJobOption &candidate) {
            if (eth < 0 || eth >= n_eth || candidate.vacancy <= 0) return;
            EmploymentJobOption option = candidate;
            option.weight_q16 = vacancy_weight(option.target_disposable,
                option.vacancy, option.profession, option.utilization_q16);
            option.source_ethnicity = eth;
            if (capture_employment_diagnostics &&
                _employment_diagnostics.size() < EMPLOYMENT_DIAGNOSTIC_LIMIT) {
                option.diagnostic_index =
                    static_cast<int32_t>(_employment_diagnostics.size());
                EmploymentDiagnostic diagnostic;
                // Match the recorder's dense per-cell group ordering so these
                // rows join against the regular building rows.
                int32_t dense_group = 0;
                for (int32_t prior = first; prior < option.group; ++prior)
                    if (buildings_store().group_units[prior] > 0) ++dense_group;
                diagnostic.group_index = dense_group;
                diagnostic.type_id = buildings_store().type_id[option.group];
                diagnostic.role = option.role;
                diagnostic.target_signature = option.target_signature;
                diagnostic.profession_id = option.profession;
                diagnostic.source_ethnicity = eth;
                diagnostic.vacancy = option.vacancy;
                diagnostic.target_disposable = option.target_disposable;
                diagnostic.weight_q16 = option.weight_q16;
                diagnostic.budget =
                    unemployed_budget_by_eth[static_cast<size_t>(eth)];
                const int32_t pool = pool_slot_for_eth(eth);
                diagnostic.pool_slot = pool;
                if (pool >= 0) {
                    diagnostic.pool_signature = static_cast<int32_t>(
                        population_store().signature_id[pool]);
                    diagnostic.pool_population = population_store().population[pool];
                }
                diagnostic.owner_target = group_owner_target[option.group - first];
                if (trace_employment) {
                    diagnostic.filled_before_clamp =
                        trace_filled_before_clamp[option.group - first];
                    diagnostic.filled_after_profession_clamp =
                        trace_filled_after_profession[option.group - first];
                    const int32_t owner_sig =
                        buildings_store().owner_signature_id[option.group];
                    if (owner_sig >= 0 && owner_sig < static_cast<int32_t>(
                            trace_shed_by_signature.size()))
                        diagnostic.shed_surplus =
                            trace_shed_by_signature[owner_sig];
                    for (const FamilyOwnerClampTrace &trace :
                            _family_clamp_traces) {
                        if (trace.group_index != option.group) continue;
                        diagnostic.filled_after_family_clamp = trace.filled_after;
                        diagnostic.family_owned = trace.family_owned;
                        diagnostic.family_member_people =
                            trace.family_member_people;
                        diagnostic.anonymous_people = trace.anonymous_people;
                        diagnostic.owner_cohort_population =
                            trace.owner_cohort_population;
                        break;
                    }
                }
                _employment_diagnostics.push_back(diagnostic);
            }
            employment_candidates.push_back(option);
        };
        auto diagnostic_for = [&](const EmploymentJobOption &option)
                -> EmploymentDiagnostic * {
            if (!capture_employment_diagnostics || option.diagnostic_index < 0 ||
                option.diagnostic_index >= static_cast<int32_t>(
                    _employment_diagnostics.size())) return nullptr;
            return &_employment_diagnostics[
                static_cast<size_t>(option.diagnostic_index)];
        };
        // Snapshot the total acceptable vacancy weight per ethnicity.  The
        // sequential pass below consumes this denominator as it allocates, so
        // each successive job receives its proportional share of the remaining
        // mobile unemployed pool rather than winning by loop order.
        for (int32_t g : hire_order) {
            const auto group = building_view(static_cast<size_t>(g));
            const BuildingType &type = _building_types[group.type_id];
            const int64_t owner_need = std::max<int64_t>(0,
                group_owner_target[g - first] - group.filled_owner);
            if (owner_need > 0 && group.owner_signature_id >= 0 &&
                group.owner_signature_id < static_cast<int32_t>(_signatures.size())) {
                const int32_t owner_profession =
                    _signatures[group.owner_signature_id].profession_id;
                for (int32_t eth = 0; eth < n_eth; ++eth) {
                    const int32_t target_sig = signature_for_profession_ethnicity(
                        owner_profession, eth);
                    if (target_sig < 0) continue;
                    add_candidate(eth, EmploymentJobOption{
                        g, -1, target_sig, owner_profession,
                        eth, owner_need, labor_expected_owner_income[g - first], 0, 0, 0,
                        group.realized_profit_margin_q16,
                        employment_utilization_q16(group)});
                }
            }
            if (group.operating_state == 1) continue;
            for (int32_t r = 0; r < type.employee_count; ++r) {
                const JobRole &role = _building_employee_roles[type.employee_begin + r];
                const int32_t fi = group.employee_fill_begin + r;
                const int64_t need = std::max<int64_t>(0,
                    planned_role_demand(group, role, fi) -
                    std::max<int64_t>(0, _building_employee_filled[fi]));
                if (need <= 0) continue;
                const int64_t gross = expected_employee_hiring_gross(role, fi);
                const int64_t wage = expected_after_tax_income(
                    cell, role.profession_id, gross, _saturation_count);
                for (int32_t eth = 0; eth < n_eth; ++eth) {
                    const int32_t target_sig = signature_for_profession_ethnicity(
                        role.profession_id, eth);
                    if (target_sig < 0) continue;
                    const int64_t target_disposable = wage - employee_living_cost(fi);
                    add_candidate(eth, EmploymentJobOption{
                        g, r, target_sig, role.profession_id, eth, need,
                        target_disposable, 0, 0, 0, group.realized_profit_margin_q16,
                        employment_utilization_q16(group)});
                }
            }
        }
        auto candidate_eligible_for_pool = [&](const EmploymentJobOption &candidate,
                                               int32_t eth,
                                               EmploymentDiagnostic *diagnostic) {
            auto deny = [&](int32_t reason) {
                if (diagnostic != nullptr) {
                    diagnostic->eligible = false;
                    diagnostic->rejection_reason = reason;
                }
                return false;
            };
            const int32_t pool = pool_slot_for_eth(eth);
            if (pool < 0) return deny(EMPLOYMENT_REJECTION_POOL_MISSING);
            if (population_store().population[pool] <= 0)
                return deny(EMPLOYMENT_REJECTION_POOL_EMPTY);
            const int32_t source_signature = static_cast<int32_t>(
                population_store().signature_id[pool]);
            if (source_signature < 0 || source_signature >=
                    static_cast<int32_t>(_signatures.size()))
                return deny(EMPLOYMENT_REJECTION_SOURCE_SIGNATURE);
            const int64_t target_cost = candidate.role >= 0
                ? employee_living_cost(static_cast<int32_t>(
                    building_view(static_cast<size_t>(candidate.group)).employee_fill_begin)
                    + candidate.role)
                : living_cost_for_signature(
                    cell, candidate.target_signature, -1, _saturation_count);
            const int64_t source_disposable = unemployed_disposable_income(pool);
            // Apply the entry-savings gate before proportional allocation so a
            // gated vacancy cannot reserve unemployed moves it will never take.
            if (!entry_savings_allows(pool,
                    _signatures[source_signature].profession_id,
                    candidate.profession))
                return deny(EMPLOYMENT_REJECTION_ENTRY_SAVINGS);
            const int64_t improvement = improvement_q16(
                source_disposable, candidate.target_disposable);
            const int64_t hurdle = transition_hurdle_q16(
                _signatures[source_signature].profession_id, candidate.profession);
            if (diagnostic != nullptr) {
                diagnostic->source_disposable = source_disposable;
                diagnostic->improvement_q16 = improvement;
                diagnostic->hurdle_q16 = hurdle;
            }
            if (candidate.role < 0) {
                if (candidate.target_disposable < 0)
                    return deny(EMPLOYMENT_REJECTION_TARGET_DISPOSABLE);
                // A funded unemployment transfer is reservation income. An
                // owner vacancy may not consume that pool when its projected
                // disposable return is lower than the guaranteed transfer.
                if (source_disposable > candidate.target_disposable)
                    return deny(EMPLOYMENT_REJECTION_HURDLE);
                if (improvement < hurdle)
                    return deny(EMPLOYMENT_REJECTION_HURDLE);
            } else {
                const bool desperate = population_store().needs_satisfaction[pool] <
                    _starvation_satisfaction_threshold_q16;
                const int64_t target_wage = saturating_add(
                    candidate.target_disposable, target_cost, _saturation_count);
                const int64_t survival_floor = desperate
                    ? mul_div_sat(target_cost, _starvation_satisfaction_threshold_q16,
                        Q16_ONE, _saturation_count) : target_cost;
                if (target_wage < survival_floor)
                    return deny(EMPLOYMENT_REJECTION_SURVIVAL_FLOOR);
                if (improvement < hurdle)
                    return deny(EMPLOYMENT_REJECTION_HURDLE);
            }
            if (diagnostic != nullptr) {
                diagnostic->eligible = true;
                diagnostic->rejection_reason = EMPLOYMENT_REJECTION_NONE;
            }
            return true;
        };
        // Remove infeasible vacancies before proportional allocation. All
        // feasible vacancies remain in the pool; there is intentionally no
        // frontier, so a lower-ranked but executable building can still
        // receive its proportional share. Build a compact per-eth index so
        // allocation is O(candidates + sources) instead of rescanning the
        // complete candidate list once per ethnicity.
        thread_local std::vector<int64_t> candidate_allocations;
        candidate_allocations.assign(employment_candidates.size(), 0);
        thread_local std::vector<int32_t> candidate_eth_offsets;
        thread_local std::vector<int32_t> candidate_eth_indices;
        candidate_eth_offsets.assign(static_cast<size_t>(n_eth) + 1, 0);
        for (const EmploymentJobOption &candidate : employment_candidates) {
            if (candidate.source_ethnicity >= 0 && candidate.source_ethnicity < n_eth &&
                candidate_eligible_for_pool(candidate, candidate.source_ethnicity,
                    diagnostic_for(candidate))) {
                ++candidate_eth_offsets[static_cast<size_t>(candidate.source_ethnicity) + 1];
            }
        }
        for (int32_t eth = 0; eth < n_eth; ++eth) {
            candidate_eth_offsets[static_cast<size_t>(eth) + 1] +=
                candidate_eth_offsets[static_cast<size_t>(eth)];
        }
        candidate_eth_indices.assign(
            static_cast<size_t>(candidate_eth_offsets.back()), -1);
        thread_local std::vector<int32_t> candidate_eth_write;
        candidate_eth_write = candidate_eth_offsets;
        for (int32_t index = 0; index < static_cast<int32_t>(
                employment_candidates.size()); ++index) {
            const EmploymentJobOption &candidate = employment_candidates[
                static_cast<size_t>(index)];
            if (candidate.source_ethnicity < 0 || candidate.source_ethnicity >= n_eth ||
                !candidate_eligible_for_pool(candidate, candidate.source_ethnicity,
                    nullptr)) continue;
            candidate_eth_indices[static_cast<size_t>(candidate_eth_write[
                static_cast<size_t>(candidate.source_ethnicity)]++)] = index;
        }
        // Deterministic largest-remainder allocation over the complete
        // cell-local candidate set.
        for (int32_t eth = 0; eth < n_eth; ++eth) {
            int64_t total_weight = 0;
            int64_t allocated = 0;
            const int32_t begin = candidate_eth_offsets[static_cast<size_t>(eth)];
            const int32_t end = candidate_eth_offsets[static_cast<size_t>(eth) + 1];
            for (int32_t cursor = begin; cursor < end; ++cursor) {
                const int32_t index = candidate_eth_indices[static_cast<size_t>(cursor)];
                const EmploymentJobOption &candidate = employment_candidates[
                    static_cast<size_t>(index)];
                total_weight = saturating_add(total_weight,
                    std::max<int64_t>(1, candidate.weight_q16), _saturation_count);
            }
            if (total_weight <= 0) continue;
            const int64_t budget = unemployed_budget_by_eth[static_cast<size_t>(eth)];
            for (int32_t cursor = begin; cursor < end; ++cursor) {
                const int32_t index = candidate_eth_indices[static_cast<size_t>(cursor)];
                EmploymentJobOption &candidate = employment_candidates[
                    static_cast<size_t>(index)];
                const int64_t weight = std::max<int64_t>(1, candidate.weight_q16);
                const int64_t scaled = saturating_mul(budget, weight,
                    _saturation_count);
                const int64_t base_take = std::min(candidate.vacancy,
                    scaled / total_weight);
                candidate_allocations[static_cast<size_t>(index)] = base_take;
                candidate.remainder = scaled % total_weight;
                allocated = saturating_add(allocated, base_take,
                    _saturation_count);
            }
            int64_t left = std::max<int64_t>(0, budget - allocated);
            while (left > 0) {
                int64_t residual_weight = 0;
                for (int32_t cursor = begin; cursor < end; ++cursor) {
                    const int32_t index = candidate_eth_indices[static_cast<size_t>(cursor)];
                    const EmploymentJobOption &candidate =
                        employment_candidates[static_cast<size_t>(index)];
                    if (candidate_allocations[static_cast<size_t>(index)] <
                            candidate.vacancy)
                        residual_weight = saturating_add(residual_weight,
                            std::max<int64_t>(1, candidate.weight_q16),
                            _saturation_count);
                }
                if (residual_weight <= 0) break;
                int64_t distributed = 0;
                for (int32_t cursor = begin; cursor < end; ++cursor) {
                    const int32_t index = candidate_eth_indices[static_cast<size_t>(cursor)];
                    EmploymentJobOption &candidate = employment_candidates[
                        static_cast<size_t>(index)];
                    const int64_t room = candidate.vacancy -
                        candidate_allocations[static_cast<size_t>(index)];
                    if (room <= 0) continue;
                    const int64_t weight = std::max<int64_t>(1, candidate.weight_q16);
                    const int64_t scaled = saturating_mul(left, weight,
                        _saturation_count);
                    const int64_t extra = std::min(room,
                        scaled / residual_weight);
                    if (extra <= 0) continue;
                    candidate_allocations[static_cast<size_t>(index)] += extra;
                    distributed = saturating_add(distributed, extra,
                        _saturation_count);
                }
                if (distributed > 0) {
                    left -= distributed;
                    continue;
                }
                // The remaining amount is smaller than the candidate count;
                // resolve only this rounding tail by largest remainder.
                int32_t best = -1;
                for (int32_t cursor = begin; cursor < end; ++cursor) {
                    const int32_t index = candidate_eth_indices[static_cast<size_t>(cursor)];
                    const EmploymentJobOption &candidate =
                        employment_candidates[static_cast<size_t>(index)];
                    if (candidate_allocations[static_cast<size_t>(index)] >=
                            candidate.vacancy) continue;
                    if (best < 0 || candidate.remainder >
                            employment_candidates[static_cast<size_t>(best)].remainder ||
                        (candidate.remainder == employment_candidates[static_cast<size_t>(best)].remainder &&
                            candidate_better(candidate,
                                employment_candidates[static_cast<size_t>(best)])))
                        best = index;
                }
                if (best < 0) break;
                ++candidate_allocations[static_cast<size_t>(best)];
                --left;
            }
        }
        if (capture_employment_diagnostics) {
            for (int32_t index = 0; index < static_cast<int32_t>(
                    employment_candidates.size()); ++index) {
                EmploymentDiagnostic *diagnostic = diagnostic_for(
                    employment_candidates[static_cast<size_t>(index)]);
                if (diagnostic == nullptr) continue;
                diagnostic->allocation =
                    candidate_allocations[static_cast<size_t>(index)];
                if (diagnostic->eligible && diagnostic->allocation <= 0)
                    diagnostic->rejection_reason =
                        EMPLOYMENT_REJECTION_NO_ALLOCATION;
            }
        }
        auto slot_diagnostic = [&](int32_t eth, int32_t group, int32_t role,
                                   int32_t target_signature)
                -> EmploymentDiagnostic * {
            if (!capture_employment_diagnostics) return nullptr;
            for (const EmploymentJobOption &candidate : employment_candidates) {
                if (candidate.source_ethnicity == eth && candidate.group == group &&
                    candidate.role == role &&
                    candidate.target_signature == target_signature)
                    return diagnostic_for(candidate);
            }
            return nullptr;
        };
        auto drop_role_diagnostics = [&](int32_t group, int32_t role,
                                         int32_t reason) {
            if (!capture_employment_diagnostics) return;
            for (const EmploymentJobOption &candidate : employment_candidates) {
                if (candidate.group != group || candidate.role != role) continue;
                EmploymentDiagnostic *diagnostic = diagnostic_for(candidate);
                if (diagnostic != nullptr) diagnostic->rejection_reason = reason;
            }
        };
        auto candidate_allocation = [&](int32_t eth, int32_t group, int32_t role,
                                        int32_t target_signature) -> int64_t {
            if (eth < 0 || eth >= n_eth) return 0;
            const int32_t begin = candidate_eth_offsets[static_cast<size_t>(eth)];
            const int32_t end = candidate_eth_offsets[static_cast<size_t>(eth) + 1];
            employment_candidate_scans += end - begin;
            for (int32_t cursor = begin; cursor < end; ++cursor) {
                const int32_t index = candidate_eth_indices[static_cast<size_t>(cursor)];
                const EmploymentJobOption &candidate =
                    employment_candidates[static_cast<size_t>(index)];
                if (candidate.group == group && candidate.role == role &&
                    candidate.target_signature == target_signature &&
                    candidate_allocations[static_cast<size_t>(index)] > 0)
                    return candidate_allocations[static_cast<size_t>(index)];
            }
            return 0;
        };
