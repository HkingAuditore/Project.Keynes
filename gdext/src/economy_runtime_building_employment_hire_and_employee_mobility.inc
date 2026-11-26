        for (size_t oi = 0; oi < hire_order.size(); ++oi) {
            const int32_t g = hire_order[oi];
            auto group = building_at(static_cast<size_t>(g));
            const BuildingType &type = _building_types[group.type_id];
            // --- owner 鎷涘嫙锛堟寜鏉ユ簮 ethnicity 淇濈暀韬唤锛屼笉瑕佹眰鍖归厤 canonical owner ethnicity锛?--
            const int64_t owner_target = group_owner_target[g - first];
            int64_t owner_need = std::max<int64_t>(0, owner_target - group.filled_owner);
            if (owner_need > 0 && group.owner_signature_id >= 0 &&
                group.owner_signature_id < static_cast<int32_t>(_signatures.size())) {
                const int32_t owner_profession =
                    _signatures[group.owner_signature_id].profession_id;
                for (int32_t source_eth = 0; source_eth < n_eth && owner_need > 0;
                     ++source_eth) {
                    const int32_t pool = pool_slot_for_eth(source_eth);
                    const int32_t target_sig = signature_for_profession_ethnicity(
                        owner_profession, source_eth);
                    EmploymentDiagnostic *slot = slot_diagnostic(
                        source_eth, g, -1, target_sig);
                    auto drop = [&](int32_t reason) {
                        if (slot != nullptr) slot->rejection_reason = reason;
                    };
                    if (pool < 0 || target_sig < 0) {
                        drop(pool < 0 ? EMPLOYMENT_REJECTION_POOL_MISSING
                                      : EMPLOYMENT_REJECTION_TARGET_SIGNATURE);
                        continue;
                    }
                    const int64_t avail = std::max<int64_t>(0,
                        population_store().population[pool]);
                    if (avail <= 0 || candidate_allocation(source_eth, g, -1,
                            target_sig) <= 0) {
                        drop(avail <= 0 ? EMPLOYMENT_REJECTION_POOL_EMPTY
                                        : EMPLOYMENT_REJECTION_NO_ALLOCATION);
                        continue;
                    }
                    const int64_t target_disposable = labor_expected_owner_income[
                        g - first];
                    const int64_t source_disposable =
                        unemployed_disposable_income(pool);
                    const int32_t source_profession = _signatures[
                        population_store().signature_id[pool]].profession_id;
                    const int64_t improvement = improvement_q16(
                        source_disposable, target_disposable);
                    int64_t &budget = unemployed_budget_by_eth[
                        static_cast<size_t>(source_eth)];
                    const bool source_hungry =
                        population_store().needs_satisfaction[pool] <
                            Q16_ONE / 2;
                    bool survival_food_target = false;
                    for (int32_t oi = 0; oi < type.output_count; ++oi) {
                        const int32_t good = _building_outputs[
                            type.output_begin + oi].good_id;
                        if (good >= 0 &&
                            good < static_cast<int32_t>(
                                _survival_food_good_mask.size()) &&
                            _survival_food_good_mask[good] != 0) {
                            survival_food_target = true;
                            break;
                        }
                    }
                    // Hungry cohorts switch into self-provisioning food jobs
                    // on any positive disposable quote, without waiting for
                    // the ordinary career hurdle.
                    const bool hungry_food_switch = source_hungry &&
                        survival_food_target && target_disposable > 0;
                    const bool eligible = hungry_food_switch ||
                        (target_disposable >= 0 &&
                        target_disposable >= source_disposable && improvement >=
                        transition_hurdle_q16(source_profession, owner_profession));
                    const int64_t proportional = eligible
                        ? candidate_allocation(source_eth, g, -1, target_sig) : 0;
                    const int64_t capped_take = std::min({owner_need, avail, proportional});
                    if (capped_take <= 0 || target_sig == static_cast<int32_t>(
                            population_store().signature_id[pool])) {
                        if (target_sig == static_cast<int32_t>(
                                population_store().signature_id[pool]))
                            drop(EMPLOYMENT_REJECTION_SIGNATURE_SELF);
                        else if (!eligible)
                            drop(EMPLOYMENT_REJECTION_HURDLE);
                        else
                            drop(EMPLOYMENT_REJECTION_ZERO_TAKE);
                        continue;
                    }
                    if (slot != nullptr) {
                        slot->take = capped_take;
                        slot->rejection_reason = EMPLOYMENT_REJECTION_NONE;
                    }
                    bool drained = false;
                    // A family-owned lot staffs its owner seats from the
                    // owning family before anonymous entrants.
                    uint64_t preferred_family = target_sig == group.owner_signature_id
                        ? owning_family_for_owner_hire(g, pool) : 0;
                    const bool owner_family_first = preferred_family != 0;
                    if (!owner_family_first)
                        preferred_family = preferred_family_for_cohort(
                            pool, 1, 0, owner_profession);
                    if (!move_cohort_population(pool, cell, target_sig, capped_take,
                                                error, &drained, preferred_family,
                                                owner_family_first)) {
                        return false;
                    }
                    group.filled_owner = saturating_add(group.filled_owner, capped_take,
                                                        _saturation_count);
                    schedule_suspended_survival_restart(group);
                    owner_need = std::max<int64_t>(0, owner_need - capped_take);
                    const int32_t dest = population_store().find_signature(
                        cell, static_cast<uint32_t>(target_sig));
                    if (dest >= 0) {
                        population_store().owner_employed.write_scalar(dest, saturating_add(
                            population_store().owner_employed[dest], capped_take,
                            _saturation_count), market_mutation_sink());
                    }
                    budget = std::max<int64_t>(0, budget - capped_take);
                }
            }
            if (group.operating_state == 1) continue;
            // --- employee 鎷涘嫙锛堟瘡 role锛宲rofession 鍖归厤锛岃法 eth 鎸夊崌搴忓彇姹狅級---
            for (int32_t r = 0; r < type.employee_count; ++r) {
                const JobRole &role = _building_employee_roles[type.employee_begin + r];
                const int32_t p = role.profession_id;
                if (!profession_available(cell, p, true)) {
                    drop_role_diagnostics(g, r,
                        EMPLOYMENT_REJECTION_PROFESSION_UNAVAILABLE);
                    continue;
                }
                const int32_t fi = group.employee_fill_begin + r;
                int64_t gross_wage = 0;
                int64_t expected_wage = 0;
                if (fi >= 0 && static_cast<size_t>(fi) < hire_role_stamp.size() &&
                    hire_role_stamp[static_cast<size_t>(fi)] ==
                        hire_role_generation) {
                    gross_wage = hire_role_gross_cache[static_cast<size_t>(fi)];
                    expected_wage = hire_role_net_cache[static_cast<size_t>(fi)];
                } else {
                    gross_wage = expected_employee_hiring_gross(role, fi);
                    expected_wage = expected_after_tax_income(
                        cell, p, gross_wage, _saturation_count);
                }
                const int64_t role_target = planned_role_demand(
                    group, role, fi);
                int64_t need = std::max<int64_t>(0,
                    role_target - std::max<int64_t>(0, _building_employee_filled[fi]));
                if (need <= 0) continue;
                // 鐩爣 slot 鎸夊叿浣?eth 瀹氾紙璺?eth 鎷涘嫙锛屾寜 eth 鍗囧簭绋冲畾鍙栨睜锛夈€?
                for (int32_t eth = 0; eth < n_eth && need > 0; ++eth) {
                    const int32_t pool = pool_slot_for_eth(eth);
                    const int32_t target_sig = signature_for_profession_ethnicity(p, eth);
                    EmploymentDiagnostic *slot = slot_diagnostic(
                        eth, g, r, target_sig);
                    auto drop = [&](int32_t reason) {
                        if (slot != nullptr) slot->rejection_reason = reason;
                    };
                    if (pool < 0) {
                        drop(EMPLOYMENT_REJECTION_POOL_MISSING);
                        continue;
                    }
                    const int64_t avail = std::max<int64_t>(0, population_store().population[pool]);
                    if (avail <= 0) {
                        drop(EMPLOYMENT_REJECTION_POOL_EMPTY);
                        continue;
                    }
                    if (target_sig < 0) {
                        drop(EMPLOYMENT_REJECTION_TARGET_SIGNATURE);
                        continue;
                    }
                    if (target_sig == static_cast<int32_t>(population_store().signature_id[pool])) {
                        drop(EMPLOYMENT_REJECTION_SIGNATURE_SELF);
                        continue;
                    }
                    if (candidate_allocation(eth, g, r, target_sig) <= 0) {
                        drop(EMPLOYMENT_REJECTION_NO_ALLOCATION);
                        continue;
                    }
                    const int64_t target_cost = employee_living_cost(fi);
                    const int64_t target_disposable = expected_wage - target_cost;
                    const int64_t source_disposable =
                        unemployed_disposable_income(pool);
                    const int32_t source_profession = _signatures[
                        population_store().signature_id[pool]].profession_id;
                    const int64_t improvement = improvement_q16(
                        source_disposable, target_disposable);
                    const bool desperate = population_store().needs_satisfaction[pool] <
                        _starvation_satisfaction_threshold_q16;
                    const int64_t survival_floor = desperate
                        ? mul_div_sat(target_cost,
                            _starvation_satisfaction_threshold_q16, Q16_ONE,
                            _saturation_count) : target_cost;
                    int64_t &budget = unemployed_budget_by_eth[
                        static_cast<size_t>(eth)];
                    const int64_t hiring_hurdle = vacancy_adjusted_hurdle_q16(
                        transition_hurdle_q16(source_profession, p), g, fi);
                    const bool eligible = expected_wage >= survival_floor &&
                        improvement >= hiring_hurdle;
                    const int64_t proportional = eligible
                        ? candidate_allocation(eth, g, r, target_sig) : 0;
                    const int64_t take = std::min({need, avail, proportional});
                    if (take <= 0) {
                        drop(eligible
                            ? EMPLOYMENT_REJECTION_ZERO_TAKE
                            : (expected_wage < survival_floor
                                ? EMPLOYMENT_REJECTION_SURVIVAL_FLOOR
                                : EMPLOYMENT_REJECTION_HURDLE));
                        continue;
                    }
                    if (slot != nullptr) {
                        slot->take = take;
                        slot->rejection_reason = EMPLOYMENT_REJECTION_NONE;
                    }
                    bool drained = false;
                    const uint64_t preferred_family =
                        preferred_family_for_cohort(pool, 1, 0, p);
                    if (!move_cohort_population(pool, cell, target_sig, take, error,
                                                &drained, preferred_family)) {
                        return false;
                    }
                    _building_employee_filled.write_scalar(fi, saturating_add(
                        _building_employee_filled[fi], take, _saturation_count), market_mutation_sink());
                    const int32_t dest = population_store().find_signature(
                        cell, static_cast<uint32_t>(target_sig));
                    if (dest >= 0) {
                        population_store().employee_employed.write_scalar(dest, saturating_add(
                            population_store().employee_employed[dest], take, _saturation_count), market_mutation_sink());
                    }
                    need -= take;
                    budget = std::max<int64_t>(0, budget - take);
                }
            }
        }

        EconomyCostProbe::record("employment.hire_main", _current_day.get(),
                                 elapsed_ms(employment_hire_started));
        employment_mobility_started = Clock::now();
        // Zero-unemployment job-to-job mobility. Role fills are already
        // aggregate SoA counters, so pair the lowest collectible-pay source
        // roles with the highest collectible-pay vacancies. A cross-profession
        // move changes one deterministic ethnicity cohort signature; a
        // same-profession move only rebalances role fill.
        struct EmployeeRoleOpportunity {
            int32_t group = -1;
            int32_t fill_index = -1;
            int32_t profession = -1;
            int64_t disposable_income = 0;
            int64_t mobile = 0;
        };
        thread_local std::vector<EmployeeRoleOpportunity> employee_sources;
        thread_local std::vector<EmployeeRoleOpportunity> employee_targets;
        employee_sources.clear();
        employee_targets.clear();
        if (mobility_period_q16 > 0) {
            for (int32_t group_index = first; group_index < last; ++group_index) {
                auto group = building_view(static_cast<size_t>(group_index));
                if (group.cell != cell || group.count <= 0 ||
                    group.operating_state == 1 ||
                    !building_available(cell, group.type_id, true)) continue;
                const BuildingType &type = _building_types[group.type_id];
                for (int32_t role_offset = 0;
                        role_offset < type.employee_count; ++role_offset) {
                    const JobRole &role = _building_employee_roles[
                        type.employee_begin + role_offset];
                    const int32_t fill_index =
                        group.employee_fill_begin + role_offset;
                    const int64_t gross =
                        expected_employee_gross(role, fill_index);
                    const int64_t net = expected_after_tax_income(
                        cell, role.profession_id, gross, _saturation_count);
                    const int64_t living = fill_index >= 0 && fill_index <
                            static_cast<int32_t>(
                                _building_role_living_cost.size())
                        ? std::max<int64_t>(
                            0, _building_role_living_cost[fill_index]) : 0;
                    const EmployeeRoleOpportunity opportunity{
                        group_index, fill_index, role.profession_id,
                        saturating_sub(net, living, _saturation_count), 0};
                    // Military v1: soldiers never transfer OUT voluntarily.
                    const bool role_is_state_service =
                        profession_is_state_service_only(role.profession_id);
                    if (!role_is_state_service &&
                        _building_employee_filled[fill_index] > 0) {
                        EmployeeRoleOpportunity source = opportunity;
                        source.mobile = mul_div_sat(
                            _building_employee_filled[fill_index],
                            mobility_period_q16, Q16_ONE, _saturation_count);
                        if (source.mobile > 0)
                            employee_sources.push_back(source);
                    }
                    const int64_t target = planned_role_demand(
                        group, role, fill_index);
                    if (_building_employee_filled[fill_index] < target)
                        employee_targets.push_back(opportunity);
                }
            }
            std::sort(employee_sources.begin(), employee_sources.end(),
                [](const EmployeeRoleOpportunity &a,
                   const EmployeeRoleOpportunity &b) {
                    if (a.disposable_income != b.disposable_income)
                        return a.disposable_income < b.disposable_income;
                    if (a.group != b.group) return a.group < b.group;
                    return a.fill_index < b.fill_index;
                });
            std::sort(employee_targets.begin(), employee_targets.end(),
                [](const EmployeeRoleOpportunity &a,
                   const EmployeeRoleOpportunity &b) {
                    if (a.disposable_income != b.disposable_income)
                        return a.disposable_income > b.disposable_income;
                    if (a.group != b.group) return a.group < b.group;
                    return a.fill_index < b.fill_index;
                });
            size_t source_cursor = 0;
            for (const EmployeeRoleOpportunity &target : employee_targets) {
                while (source_cursor < employee_sources.size()) {
                    const EmployeeRoleOpportunity &source =
                        employee_sources[source_cursor++];
                    if (source.fill_index == target.fill_index ||
                        source.mobile <= 0 ||
                        _building_employee_filled[source.fill_index] <= 0)
                        continue;
                    const int64_t improvement = improvement_q16(
                        source.disposable_income, target.disposable_income);
                    if (improvement < vacancy_adjusted_hurdle_q16(
                            transition_hurdle_q16(source.profession,
                                target.profession), target.group,
                            target.fill_index)) {
                        ++_building_employee_job_hurdle_rejections;
                        continue;
                    }
                    if (source.profession != target.profession) {
                        int32_t source_slot = -1;
                        int32_t target_signature = -1;
                        for (int32_t ethnicity = 0;
                                ethnicity < n_eth; ++ethnicity) {
                            const int32_t source_signature =
                                signature_for_profession_ethnicity(
                                    source.profession, ethnicity);
                            const int32_t candidate_slot =
                                source_signature >= 0
                                ? population_store().find_signature(
                                    cell, static_cast<uint32_t>(
                                        source_signature)) : -1;
                            if (candidate_slot < 0 ||
                                population_store().employee_employed[
                                    candidate_slot] <= 0) continue;
                            const int32_t candidate_target =
                                signature_for_profession_ethnicity(
                                    target.profession, ethnicity);
                            if (candidate_target < 0) continue;
                            if (!entry_savings_allows(candidate_slot,
                                    source.profession, target.profession))
                                continue;
                            source_slot = candidate_slot;
                            target_signature = candidate_target;
                            break;
                        }
                        if (source_slot < 0) continue;
                        bool source_drained = false;
                        const uint64_t preferred_family =
                            preferred_family_for_cohort(
                                source_slot, 1, 0, target.profession);
                        if (!move_cohort_population(source_slot, cell,
                                target_signature, 1, error, &source_drained,
                                preferred_family)) return false;
                        if (!source_drained) {
                            population_store().employee_employed.write_scalar(source_slot, std::max<int64_t>(0,
                                    population_store().employee_employed[
                                        source_slot] - 1), market_mutation_sink());
                        }
                        const int32_t destination =
                            population_store().find_signature(
                                cell, static_cast<uint32_t>(target_signature));
                        if (destination < 0) {
                            error =
                                "employee_job_reallocation_destination_missing";
                            return false;
                        }
                        population_store().employee_employed.write_scalar(destination, saturating_add(
                                population_store().employee_employed[destination],
                                1, _saturation_count), market_mutation_sink());
                        ++_building_employee_job_profession_changes;
                    }
                    _building_employee_filled.write_scalar(source.fill_index,
                        _building_employee_filled[source.fill_index] - 1, market_mutation_sink());
                    _building_employee_filled.write_scalar(target.fill_index, saturating_add(
                            _building_employee_filled[target.fill_index], 1,
                            _saturation_count), market_mutation_sink());
                    ++_building_employee_job_reallocations;
                    break;
                }
                if (source_cursor >= employee_sources.size()) break;
            }
        }
