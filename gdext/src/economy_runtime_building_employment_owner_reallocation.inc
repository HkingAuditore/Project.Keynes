        if (allow_owner_job_reallocation) {
        // Unemployed hiring remains authoritative and runs first. Remaining
        // ACTIVE owner vacancies may then attract one incumbent owner along the
        // opportunity gradient. Any ACTIVE lot with at least one owner may be a
        // source; understaffed鈫攗nderstaffed moves with positive source income
        // pay an extra hurdle so small noisy gaps cannot thrash each epoch.
        // Targets and sources are snapshotted before matching so a group
        // cannot chain through several jobs in the same employment period.
        thread_local std::vector<int64_t> projected_owner_income;
        thread_local std::vector<int32_t> owner_job_targets;
        thread_local std::vector<int32_t> owner_job_sources;
        thread_local std::vector<uint8_t> owner_job_source_understaffed;
        thread_local std::vector<uint8_t> owner_job_group_used;
        struct EmployeeOwnerSource {
            int32_t group = -1;
            int32_t role = -1;
            int32_t fill_index = -1;
            int32_t profession = -1;
            int64_t income = 0;
        };
        thread_local std::vector<EmployeeOwnerSource> employee_owner_sources;
        projected_owner_income.assign(static_cast<size_t>(last - first), 0);
        owner_job_targets.clear();
        owner_job_sources.clear();
        owner_job_source_understaffed.clear();
        employee_owner_sources.clear();
        owner_job_group_used.assign(static_cast<size_t>(last - first), uint8_t{0});
        int64_t local_merchant_population = 0;
        auto owner_slot_for_profession = [&](int32_t profession) -> int32_t {
            if (profession < 0) return -1;
            for (int32_t eth = 0; eth < n_eth; ++eth) {
                const int32_t signature = signature_for_profession_ethnicity(
                    profession, eth);
                if (signature < 0) continue;
                const int32_t slot = population_store().find_signature(
                    cell, static_cast<uint32_t>(signature));
                if (slot >= 0 && population_store().owner_employed[slot] > 0)
                    return slot;
            }
            return -1;
        };
        population_store().for_each_in_cell(cell, [&](int32_t slot) {
            if (is_merchant_slot(slot)) {
                local_merchant_population = saturating_add(
                    local_merchant_population,
                    std::max<int64_t>(0, population_store().population[slot]),
                    _saturation_count);
            }
        });
        for (int32_t g = first; g < last; ++g) {
            const auto group = building_view(static_cast<size_t>(g));
            if (group.cell != cell || group.count <= 0 ||
                !building_available(cell, group.type_id, true)) continue;
            const BuildingType &type = _building_types[group.type_id];
            if (group.owner_signature_id < 0 ||
                group.owner_signature_id >= static_cast<int32_t>(_signatures.size())) continue;
            // Suspended survival-food lots can receive owners, but only
            // active incumbents are sources for the opportunity gradient.
            const int64_t income = owner_mobility_income(group, _saturation_count);
            projected_owner_income[g - first] = income;
            const int64_t owner_target = group_owner_target[g - first];
            if ((type.kind != 2 || is_merchant_service_post(type)) &&
                group.filled_owner < owner_target && income > 0)
                owner_job_targets.push_back(g);
            if (group.operating_state == 1) continue;
            // Opportunity-gradient sources: any ACTIVE lot that still has an
            // attached owner may lose one person to a higher-opportunity
            // vacancy. The matching loop applies asymmetric hysteresis so two
            // understaffed positive-income lots cannot thrash on noise, while
            // leaving non-positive opportunity lots stays on the base hurdle.
            // The final local merchant remains protected below.
            // A restart reservation is only worth protecting while its owners
            // can wait for it; starving owners of a lot that produced nothing
            // (e.g. a hunted-out camp) must be free to take another job.
            const int32_t incumbent_owner_slot = owner_slot_for_profession(
                _signatures[group.owner_signature_id].profession_id);
            static const bool diag_no_starving_release = pk::runtime_switch_value(pk::RuntimeSwitch::PK_DIAG_NO_STARVING_RELEASE) != nullptr;
            const bool incumbent_owners_starving = !diag_no_starving_release && incumbent_owner_slot >= 0 &&
                population_store().needs_satisfaction[incumbent_owner_slot] <
                    Q16_ONE / 2;
            const bool protected_restart_source =
                !incumbent_owners_starving &&
                group.purchase_intent_capacity_q16 > 0 &&
                group.last_output <= 0 && group.last_sold <= 0 &&
                group.last_observed_capacity_days_q16 > 0;
            if (group.filled_owner > 0 && owner_target > 0) {
                // An ACTIVE lot with a bounded restart intent is still an
                // operating business, even when the last quote could not
                // execute any physical input. Keep its incumbent owner
                // attached so employment mobility cannot erase the retry
                // reservation before the next funding/stock review.
                // Healthy settled producers are no longer absolute pins:
                // understaffed gathering vacancies must not forbid higher-
                // income cross-profession exits (e.g. forager → hunter).
                // Match hysteresis still dampens same-class thrash.
                if (protected_restart_source) {
                    // Preserve the owner, but still collect employee sources
                    // below; only the owner mobility lane is protected.
                } else if (profession_is_state_service_only(
                        _signatures[group.owner_signature_id].profession_id)) {
                    // Military v1: state-service owners never move (state
                    // buildings are owned by the reserved sentinel).
                } else {
                    const int32_t source_slot = owner_slot_for_profession(
                        _signatures[group.owner_signature_id].profession_id);
                    if (source_slot >= 0 && population_store().owner_employed[
                            source_slot] > 0) {
                        const bool source_understaffed =
                            group.filled_owner < owner_target;
                        owner_job_sources.push_back(g);
                        owner_job_source_understaffed.push_back(
                            source_understaffed ? uint8_t{1} : uint8_t{0});
                    }
                }
            }
            for (int32_t r = 0; r < type.employee_count; ++r) {
                const int32_t fill_index = group.employee_fill_begin + r;
                if (_building_employee_filled[fill_index] <= 0) continue;
                const JobRole &role = _building_employee_roles[type.employee_begin + r];
                // Military v1: soldiers never transfer OUT voluntarily.
                if (profession_is_state_service_only(role.profession_id))
                    continue;
                const int64_t gross_income = expected_employee_gross(
                    role, fill_index);
                employee_owner_sources.push_back({g, r, fill_index,
                    role.profession_id, expected_after_tax_income(cell,
                        role.profession_id, gross_income, _saturation_count)});
            }
        }
        std::stable_sort(owner_job_targets.begin(), owner_job_targets.end(),
                         [&](int32_t a, int32_t b) {
            const int64_t income_a = projected_owner_income[a - first];
            const int64_t income_b = projected_owner_income[b - first];
            return income_a != income_b ? income_a > income_b : a < b;
        });
        // Keep understaffed flags aligned with sources while sorting by income.
        thread_local std::vector<size_t> owner_source_order;
        owner_source_order.resize(owner_job_sources.size());
        for (size_t i = 0; i < owner_source_order.size(); ++i)
            owner_source_order[i] = i;
        std::stable_sort(owner_source_order.begin(), owner_source_order.end(),
                         [&](size_t a, size_t b) {
            const int32_t ga = owner_job_sources[a];
            const int32_t gb = owner_job_sources[b];
            const int64_t income_a = projected_owner_income[ga - first];
            const int64_t income_b = projected_owner_income[gb - first];
            return income_a != income_b ? income_a < income_b : ga < gb;
        });
        {
            thread_local std::vector<int32_t> sorted_sources;
            thread_local std::vector<uint8_t> sorted_understaffed;
            sorted_sources.clear();
            sorted_understaffed.clear();
            sorted_sources.reserve(owner_job_sources.size());
            sorted_understaffed.reserve(owner_job_sources.size());
            for (size_t idx : owner_source_order) {
                sorted_sources.push_back(owner_job_sources[idx]);
                sorted_understaffed.push_back(owner_job_source_understaffed[idx]);
            }
            owner_job_sources.swap(sorted_sources);
            owner_job_source_understaffed.swap(sorted_understaffed);
        }
        std::stable_sort(employee_owner_sources.begin(), employee_owner_sources.end(),
                         [](const EmployeeOwnerSource &a,
                            const EmployeeOwnerSource &b) {
            if (a.income != b.income) return a.income < b.income;
            if (a.group != b.group) return a.group < b.group;
                             return a.role < b.role;
                         });

        EconomyCostProbe::record("employment.hire_mobility", _current_day.get(),
                                 elapsed_ms(employment_mobility_started));
        employment_ownerjob_started = Clock::now();
        // A cell can have no unemployed people while still having a profitable
        // employee vacancy.  Let one incumbent owner from a lower-opportunity
        // lot cross that boundary.  This is deliberately a separate lane from
        // owner↔owner reallocation: it preserves one owner on each source lot,
        // moves at most one person per source/target group in this period, and
        // uses the same audited cohort transfer as every other profession move.
        if (mobility_period_q16 > 0 && !employee_targets.empty() &&
            !owner_job_sources.empty()) {
            for (const EmployeeRoleOpportunity &target : employee_targets) {
                const int32_t target_group_index = target.group;
                if (target_group_index < first || target_group_index >= last ||
                    owner_job_group_used[target_group_index - first] != 0)
                    continue;
                auto target_group = building_view(static_cast<size_t>(
                    target_group_index));
                if (target_group.cell != cell || target_group.count <= 0 ||
                    target_group.operating_state == 1 ||
                    !building_available(cell, target_group.type_id, true))
                    continue;
                const BuildingType &target_type = _building_types[
                    target_group.type_id];
                const int32_t target_role_offset = target.fill_index -
                    target_group.employee_fill_begin;
                if (target_role_offset < 0 || target_role_offset >=
                        target_type.employee_count)
                    continue;
                const JobRole &target_role = _building_employee_roles[
                    target_type.employee_begin + target_role_offset];
                const int64_t target_need = planned_role_demand(
                    target_group, target_role, target.fill_index);
                if (_building_employee_filled[target.fill_index] >= target_need)
                    continue;
                const int64_t target_slots = std::max<int64_t>(1,
                    saturating_mul(target_group.count,
                        target_role.slots_per_building, _saturation_count));
                const int64_t target_filled = std::clamp<int64_t>(
                    _building_employee_filled[target.fill_index], 0,
                    target_slots);
                const int64_t target_vacancy_q16 = mul_div_sat(
                    target_slots - target_filled, Q16_ONE, target_slots,
                    _saturation_count);
                // This lane is reserved for a real labor shortage with a
                // material opportunity. Ordinary vacancies continue through
                // unemployed hiring and employee↔employee mobility.
                if (target_vacancy_q16 < Q16_ONE / 2 ||
                    vacancy_profit_signal_q16(target_group) < Q16_ONE / 4)
                    continue;

                int32_t source_group_index = -1;
                int32_t source_slot = -1;
                int32_t source_target_signature = -1;
                for (size_t source_i = 0; source_i < owner_job_sources.size();
                     ++source_i) {
                    const int32_t candidate = owner_job_sources[source_i];
                    if (candidate == target_group_index ||
                        owner_job_group_used[candidate - first] != 0)
                        continue;
                    const auto source_group = building_view(static_cast<size_t>(
                        candidate));
                    const int32_t source_profession =
                        _signatures[source_group.owner_signature_id].profession_id;
                    const int64_t source_income =
                        projected_owner_income[candidate - first];
                    int32_t candidate_target_signature = -1;
                    int32_t candidate_source_slot = -1;
                    for (int32_t source_eth = 0; source_eth < n_eth;
                         ++source_eth) {
                        const int32_t source_signature =
                            signature_for_profession_ethnicity(
                                source_profession, source_eth);
                        if (source_signature < 0) continue;
                        const int32_t slot = population_store().find_signature(
                            cell, static_cast<uint32_t>(source_signature));
                        if (slot < 0 || population_store().owner_employed[slot] <= 0)
                            continue;
                        const int32_t target_signature =
                            signature_for_profession_ethnicity(
                                target.profession, source_eth);
                        if (target_signature < 0) continue;
                        if (!entry_savings_allows(slot, source_profession,
                                target.profession)) continue;
                        candidate_source_slot = slot;
                        candidate_target_signature = target_signature;
                        break;
                    }
                    if (candidate_source_slot < 0 ||
                        candidate_target_signature < 0)
                        continue;
                    const int64_t improvement = improvement_q16(
                        source_income, target.disposable_income);
                    const int64_t hurdle = vacancy_adjusted_hurdle_q16(
                        transition_hurdle_q16(source_profession,
                            target.profession), target_group_index,
                        target.fill_index);
                    // Monetary / bullion outputs must not waive the disposable-
                    // income hurdle. Vacancy and face-value profit may ease the
                    // hurdle via vacancy_adjusted_hurdle_q16, but a worse job
                    // (e.g. forager in-kind >> miner wage) stays ineligible.
                    if (improvement < hurdle) continue;
                    if (source_profession == _merchant_profession_id &&
                        local_merchant_population <= 1) {
                        ++_last_merchant_protected_rejects;
                        continue;
                    }
                    source_group_index = candidate;
                    source_slot = candidate_source_slot;
                    source_target_signature = candidate_target_signature;
                    break;
                }
                if (source_group_index < 0) continue;

                auto source_group = building_at(static_cast<size_t>(
                    source_group_index));
                const int32_t source_profession =
                    _signatures[source_group.owner_signature_id].profession_id;
                const bool profession_change = source_profession !=
                    target.profession;
                if (profession_change) {
                    bool source_drained = false;
                    const uint64_t preferred_family =
                        preferred_family_for_cohort(source_slot, 1, 0,
                            target.profession);
                    if (!move_cohort_population(source_slot, cell,
                            source_target_signature, 1, error, &source_drained,
                            preferred_family))
                        return false;
                    if (!source_drained) {
                        population_store().owner_employed.write_scalar(source_slot, std::max<int64_t>(0,
                                population_store().owner_employed[source_slot] - 1), market_mutation_sink());
                    }
                    const int32_t destination = population_store().find_signature(
                        cell, static_cast<uint32_t>(source_target_signature));
                    if (destination < 0) {
                        error = "owner_employee_reallocation_destination_missing";
                        return false;
                    }
                    population_store().employee_employed.write_scalar(destination, saturating_add(
                            population_store().employee_employed[destination],
                            1, _saturation_count), market_mutation_sink());
                    ++_building_employee_job_profession_changes;
                } else {
                    // Same-profession owner→employee conversion stays in the
                    // existing cohort and therefore needs no population move.
                    population_store().owner_employed.write_scalar(source_slot, std::max<int64_t>(0,
                            population_store().owner_employed[source_slot] - 1), market_mutation_sink());
                    population_store().employee_employed.write_scalar(source_slot, saturating_add(
                            population_store().employee_employed[source_slot],
                            1, _saturation_count), market_mutation_sink());
                }
                source_group.filled_owner = std::max<int64_t>(0,
                    source_group.filled_owner - 1);
                _building_employee_filled.write_scalar(target.fill_index, saturating_add(
                        _building_employee_filled[target.fill_index], 1,
                        _saturation_count), market_mutation_sink());
                owner_job_group_used[source_group_index - first] = 1;
                owner_job_group_used[target_group_index - first] = 1;
                ++_building_employee_job_reallocations;
            }
        }
        for (int32_t target_group_index : owner_job_targets) {
            if (owner_job_group_used[target_group_index - first] != 0) continue;
            auto target_group = building_at(static_cast<size_t>(target_group_index));
            if (target_group.filled_owner >=
                    group_owner_target[target_group_index - first]) continue;
            const Signature &target_signature =
                _signatures[target_group.owner_signature_id];
            const int32_t target_owner_profession = target_signature.profession_id;
            const int64_t target_income =
                projected_owner_income[target_group_index - first];
            int32_t source_group_index = -1;
            int32_t source_slot = -1;
            int32_t source_target_signature = -1;
            bool matched_understaffed_source = false;
            // The target row is not mutated while scanning sources, so its
            // quote is evaluated once; every visit still charges its saturation.
            bool target_quote_ready = false;
            bool target_survival_priority_cached = false;
            int64_t target_survival_sat = 0;
            for (size_t source_i = 0; source_i < owner_job_sources.size();
                 ++source_i) {
                const int32_t candidate = owner_job_sources[source_i];
                if (candidate == target_group_index ||
                    owner_job_group_used[candidate - first] != 0) continue;
                const auto source_group = building_view(static_cast<size_t>(candidate));
                const int32_t source_profile_profession =
                    _signatures[source_group.owner_signature_id].profession_id;
                const int32_t source_slot_candidate = owner_slot_for_profession(
                    source_profile_profession);
                if (source_slot_candidate < 0) continue;
                const int32_t source_signature_id = static_cast<int32_t>(
                    population_store().signature_id[source_slot_candidate]);
                if (source_signature_id < 0 || source_signature_id >=
                        static_cast<int32_t>(_signatures.size())) continue;
                const Signature &source_signature = _signatures[source_signature_id];
                const int32_t candidate_target_signature =
                    signature_for_profession_ethnicity(target_owner_profession,
                        source_signature.ethnicity_id);
                if (candidate_target_signature < 0) continue;
                const int64_t source_income =
                    projected_owner_income[candidate - first];
                if (!entry_savings_allows(source_slot_candidate,
                        source_signature.profession_id,
                        target_owner_profession)) continue;
                const int64_t improvement = improvement_q16(
                    source_income, target_income);
                const int64_t base_hurdle = transition_hurdle_q16(
                    source_signature.profession_id, target_owner_profession);
                // Asymmetric hysteresis: easy exit from non-positive opportunity,
                // raised bar only for understaffed→understaffed with positive
                // source income (the historical thrash pair). Survival-priority
                // food vacancies skip the understaffed raise so gathering
                // vacancies cannot permanently block protein recovery.
                int64_t effective_hurdle = base_hurdle;
                const bool source_understaffed =
                    source_i < owner_job_source_understaffed.size() &&
                    owner_job_source_understaffed[source_i] != 0;
                const bool target_understaffed = target_group.filled_owner <
                    group_owner_target[target_group_index - first];
                const bool source_full = source_group.filled_owner >=
                    group_owner_target[candidate - first];
                if (!target_quote_ready) {
                    EconomyCostProbe::record("owner_quote.call.emp_target_priority",
                                              _current_day.get(), 0.0, 1);
                    target_survival_priority_cached = owner_opportunity_quote(
                        target_group, Q16_ONE, Q16_ONE,
                        target_survival_sat).survival_priority;
                    target_quote_ready = true;
                }
                const bool target_survival_priority =
                    target_survival_priority_cached;
                _saturation_count = saturating_add(
                    _saturation_count, target_survival_sat, _saturation_count);
                if (!target_survival_priority &&
                    !(source_income <= 0 && target_income > 0) &&
                    source_income > 0 &&
                    (source_understaffed || (source_full && target_understaffed))) {
                    effective_hurdle = mul_div_sat(
                        base_hurdle,
                        std::max<int32_t>(Q16_ONE,
                            _employment_understaffed_reallocation_hurdle_mult_q16.get()),
                        Q16_ONE, _saturation_count);
                    if (source_understaffed && target_understaffed &&
                        owner_mobility_cooldown_active(candidate,
                            target_group_index)) {
                        continue;
                    }
                }
                effective_hurdle = vacancy_adjusted_hurdle_q16(
                    effective_hurdle, target_group_index, -1);
                const bool source_hungry =
                    population_store().needs_satisfaction[
                        source_slot_candidate] < Q16_ONE / 2;
                // Hungry owners may leave any non-food seat for a positive
                // survival-food vacancy without the ordinary career hurdle.
                if (!(source_hungry && target_survival_priority_cached &&
                        target_income > 0) &&
                    improvement < effective_hurdle) continue;
                if (source_signature.profession_id == _merchant_profession_id &&
                    local_merchant_population <= 1) {
                    ++_last_merchant_protected_rejects;
                    continue;
                }
                source_group_index = candidate;
                source_slot = source_slot_candidate;
                source_target_signature = candidate_target_signature;
                matched_understaffed_source = source_understaffed;
                break;
            }
            if (source_group_index >= 0) {
                auto source_group = building_at(static_cast<size_t>(source_group_index));
                const Signature &source_signature =
                    _signatures[source_group.owner_signature_id];
                if (source_signature.profession_id != target_owner_profession) {
                    bool source_drained = false;
                    const uint64_t preferred_family =
                        preferred_family_for_cohort(source_slot, 1, 0,
                            target_owner_profession);
                    if (!move_cohort_population(source_slot, cell,
                            source_target_signature, 1, error,
                            &source_drained, preferred_family)) {
                        return false;
                    }
                    if (!source_drained) {
                        population_store().owner_employed.write_scalar(source_slot, std::max<int64_t>(
                            0, population_store().owner_employed[source_slot] - 1), market_mutation_sink());
                    }
                    const int32_t destination = population_store().find_signature(
                        cell, static_cast<uint32_t>(source_target_signature));
                    if (destination < 0) {
                        error = "owner_job_reallocation_destination_missing";
                        return false;
                    }
                    population_store().owner_employed.write_scalar(destination, saturating_add(
                        population_store().owner_employed[destination], 1,
                        _saturation_count), market_mutation_sink());
                    if (source_signature.profession_id == _merchant_profession_id) {
                        local_merchant_population = std::max<int64_t>(
                            0, local_merchant_population - 1);
                    }
                    ++_building_owner_job_profession_changes;
                }
                source_group.filled_owner -= 1;
                target_group.filled_owner = saturating_add(
                    target_group.filled_owner, 1, _saturation_count);
                schedule_suspended_survival_restart(target_group);
                {
                    int64_t realloc_sat = 0;
                    EconomyCostProbe::record("owner_quote.call.emp_realloc_owner",
                                              _current_day.get(), 0.0, 1);
                    if (owner_opportunity_quote(target_group, Q16_ONE, Q16_ONE,
                            realloc_sat).survival_priority)
                        ++_building_owner_survival_reallocations;
                    _saturation_count = saturating_add(_saturation_count,
                        realloc_sat, _saturation_count);
                }
                owner_job_group_used[source_group_index - first] = 1;
                owner_job_group_used[target_group_index - first] = 1;
                if (matched_understaffed_source) {
                    record_owner_mobility_cooldown(source_group_index,
                        target_group_index);
                    ++_building_owner_understaffed_reallocations;
                }
                ++_building_owner_job_reallocations;
                continue;
            }

            // If no lower-income owner is available, an incumbent employee may
            // take the materially better owner opening. This closes the price-to-
            // labor path when unemployment is zero: high realizable output prices
            // raise projected owner income and can attract labor out of a lower-
            // wage industry. Preserve ethnicity and move at most one person per
            // source/target group in an employment period.
            int32_t selected_employee_target_signature = -1;
            for (const EmployeeOwnerSource &candidate : employee_owner_sources) {
                if (owner_job_group_used[candidate.group - first] != 0 ||
                    _building_employee_filled[candidate.fill_index] <= 0) continue;
                int32_t source_signature_id = -1;
                int32_t employee_slot = -1;
                bool candidate_eligible = false;
                // Employee cohorts retain their ethnicity while moving into
                // the target owner profession. Search all local ethnicities;
                // the first eligible slot is deterministic and no ethnicity
                // equality with the building profile is required.
                for (int32_t source_eth = 0; source_eth < n_eth; ++source_eth) {
                    // Military v1: a soldier never leaves the service for an
                    // owner seat, so a state-service profession is not a source.
                    if (profession_is_state_service_only(candidate.profession))
                        break;
                    const int32_t candidate_source_signature =
                        signature_for_profession_ethnicity(candidate.profession,
                            source_eth);
                    if (candidate_source_signature < 0) continue;
                    const int32_t candidate_employee_slot = population_store().find_signature(
                        cell, static_cast<uint32_t>(candidate_source_signature));
                    if (candidate_employee_slot < 0 ||
                        population_store().employee_employed[candidate_employee_slot] <= 0) continue;
                    const int32_t candidate_target_signature =
                        signature_for_profession_ethnicity(target_owner_profession,
                            source_eth);
                    if (candidate_target_signature < 0) continue;
                    if (!entry_savings_allows(candidate_employee_slot,
                            candidate.profession, target_owner_profession))
                        continue;
                    const int64_t candidate_source_cost = living_cost_for_signature(
                        cell, candidate_source_signature, -1, _saturation_count);
                    const int64_t candidate_current_disposable = candidate.income -
                        std::max(candidate_source_cost,
                            recent_expense_per_day(candidate_employee_slot));
                    const int64_t candidate_improvement = improvement_q16(
                        candidate_current_disposable, target_income);
                    const int64_t owner_hurdle =
                        vacancy_adjusted_hurdle_q16(
                            transition_hurdle_q16(candidate.profession,
                                target_owner_profession),
                            target_group_index, -1);
                    if (candidate_improvement < owner_hurdle) continue;
                    source_signature_id = candidate_source_signature;
                    employee_slot = candidate_employee_slot;
                    selected_employee_target_signature = candidate_target_signature;
                    candidate_eligible = true;
                    break;
                }
                if (!candidate_eligible) continue;
                // Even a same-profession employee鈫抩wner move opens a new
                // business position and therefore needs the target reserve;
                // only the counter update differs from a profession change.
                const bool profession_change =
                    candidate.profession != target_owner_profession;
                if (profession_change) {
                    bool source_drained = false;
                    const uint64_t preferred_family =
                        preferred_family_for_cohort(employee_slot, 1, 0,
                            target_owner_profession);
                    if (!move_cohort_population(employee_slot, cell,
                            selected_employee_target_signature, 1, error,
                            &source_drained, preferred_family)) {
                        return false;
                    }
                    if (!source_drained) {
                        population_store().employee_employed.write_scalar(employee_slot, std::max<int64_t>(0,
                                population_store().employee_employed[employee_slot] - 1), market_mutation_sink());
                    }
                    const int32_t destination = population_store().find_signature(
                        cell, static_cast<uint32_t>(selected_employee_target_signature));
                    if (destination < 0) {
                        error = "employee_owner_reallocation_destination_missing";
                        return false;
                    }
                    population_store().owner_employed.write_scalar(destination, saturating_add(
                        population_store().owner_employed[destination], 1,
                        _saturation_count), market_mutation_sink());
                    ++_building_owner_job_profession_changes;
                } else {
                    population_store().employee_employed.write_scalar(employee_slot, population_store().employee_employed[employee_slot] - (1), market_mutation_sink());
                    population_store().owner_employed.write_scalar(employee_slot, saturating_add(
                        population_store().owner_employed[employee_slot], 1,
                        _saturation_count), market_mutation_sink());
                }
                _building_employee_filled.write_scalar(candidate.fill_index, _building_employee_filled[candidate.fill_index] - (1), market_mutation_sink());
                target_group.filled_owner = saturating_add(
                    target_group.filled_owner, 1, _saturation_count);
                schedule_suspended_survival_restart(target_group);
                {
                    int64_t realloc_sat = 0;
                    EconomyCostProbe::record("owner_quote.call.emp_realloc_employee",
                                              _current_day.get(), 0.0, 1);
                    if (owner_opportunity_quote(target_group, Q16_ONE, Q16_ONE,
                            realloc_sat).survival_priority)
                        ++_building_owner_survival_reallocations;
                    _saturation_count = saturating_add(_saturation_count,
                        realloc_sat, _saturation_count);
                }
                owner_job_group_used[candidate.group - first] = 1;
                owner_job_group_used[target_group_index - first] = 1;
                ++_building_employee_to_owner_reallocations;
                ++_building_owner_job_reallocations;
                break;
            }
        }
        }
