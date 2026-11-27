        // ---- 鐩爣璁＄畻锛氭湰鍛ㄦ湡鍚?group 鏈熸湜鐨?owner / 鍚?role employee ----
        // 鐢?thread_local 缂撳啿閬垮厤姣?cell 鍒嗛厤銆?
        EconomyCostProbe::record("employment.cell_pre", _current_day.get(),
                                 elapsed_ms(employment_targets_started));
        const auto employment_migrate_started = Clock::now();
        thread_local std::vector<int64_t> group_owner_target;      // 姣?group owner 鐩爣
        group_owner_target.assign(static_cast<size_t>(last - first), 0);
        // profession 绾?employee 鐩爣 / 鍦ㄥ矖锛堣法 eth 鑱氬悎锛屾部鐢ㄦ棫 employee 璇箟锛夈€?
        std::fill(demand.begin(), demand.end(), 0);   // demand[p] = 危 planned_role_demand
        std::fill(fill.begin(), fill.end(), 0);       // fill[p]   = 危 褰撳墠鍦ㄥ矖 employee
        for (int32_t g = first; g < last; ++g) {
            auto group = building_view(static_cast<size_t>(g));
            if (group.cell != cell) continue;
            const bool active = group.count > 0 && group.operating_state != 1 &&
                                 building_available(cell, group.type_id, true);
            const BuildingType &type = _building_types[group.type_id];
            // owner 鐩爣锛氫笉鍙敤/count<=0 鈫?0锛堝叾鍦ㄥ矖浜哄彛灏嗗叏閮ㄨ繘姹狅級銆?
            const bool suspended = group.count > 0 && group.operating_state == 1 &&
                                   building_available(cell, group.type_id, true);
            int64_t owner_target = (active || suspended)
                ? planned_owner_demand(group, _saturation_count) : 0;
            if (active && owner_target > 0) {
                bool derived_only_output = false;
                const BuildingType &owner_type = _building_types[group.type_id];
                bool any_real_output_demand = false;
                bool survival_output = false;
                for (int32_t oi = 0; oi < owner_type.output_count; ++oi) {
                    const int32_t good = _building_outputs[
                        owner_type.output_begin + oi].good_id;
                    if (good >= 0 && good < static_cast<int32_t>(
                            _survival_food_good_mask.size()) &&
                        (_survival_food_good_mask[good] != 0 ||
                         _survival_clothing_good_mask[good] != 0)) {
                        survival_output = true;
                    }
                    const int32_t signal = market_signal_index(group.cell, good);
                    const int64_t frozen_real = signal >= 0 && signal <
                            static_cast<int32_t>(_epoch_desired_business_demand.size())
                        ? _epoch_desired_business_demand[signal]
                        : 0;
                    const int64_t frozen_funded = signal >= 0 && signal <
                            static_cast<int32_t>(_epoch_funded_business_demand.size())
                        ? _epoch_funded_business_demand[signal]
                        : 0;
                    const int64_t observed_business = signal >= 0 && signal <
                            static_cast<int32_t>(
                                _market_signals.business_demand_ema.size())
                        ? std::max<int64_t>(0,
                            _market_signals.business_demand_ema[signal]) : 0;
                    const int64_t observed_withdrawal = signal >= 0 && signal <
                            static_cast<int32_t>(
                                _market_signals.realized_withdrawal_ema.size())
                        ? std::max<int64_t>(0,
                            _market_signals.realized_withdrawal_ema[signal]) : 0;
                    // Employment runs after the frozen demand arrays have
                    // been captured.  A real business lane may therefore be
                    // visible only through the committed EMA/withdrawal
                    // evidence from the prior cycle.  Treat that evidence as
                    // real demand, while keeping shadow-derived demand out of
                    // owner recruitment.
                    if (frozen_real > 0 || frozen_funded > 0 ||
                        observed_business > 0 || observed_withdrawal > 0 ||
                        epoch_procurement_demand_daily(group.cell, good) > 0)
                        any_real_output_demand = true;
                    if (signal >= 0 && signal < static_cast<int32_t>(
                            _epoch_derived_business_demand.size()) &&
                        _epoch_derived_business_demand[signal] > 0)
                        derived_only_output = true;
                }
                // An input good carrying shadow derived demand does not make
                // this building's own output shadow-only.  Upstream pressure
                // is exactly what should create a real production
                // opportunity once the downstream buyer is funded.  Only the
                // building's output lane can suppress a vacant owner target.
                bool output_stock_available = false;
                const int32_t owner_market = market_store().cell_to_market[group.cell];
                if (owner_market >= 0 && owner_market < market_store().market_count.get()) {
                    for (int32_t oi = 0; oi < owner_type.output_count; ++oi) {
                        const int32_t output_good = _building_outputs[
                            owner_type.output_begin + oi].good_id;
                        if (output_good < 0 || output_good >= market_store().good_count.get())
                            continue;
                        const int32_t lane = market_store().index(owner_market, output_good);
                        if (lane >= 0 && lane < static_cast<int32_t>(market_store().stock.size()) &&
                            market_store().stock[lane] > 0) {
                            output_stock_available = true;
                            break;
                        }
                    }
                }
                // Shadow demand cannot create a vacant owner in a cold-start
                // output lane.  If some real output stock already exists, the
                // price/opportunity signal is a legitimate bootstrap lane and
                // may recruit the first owner.
                const bool narrow_knapping_cold_start =
                    group.type_id >= 0 && group.type_id <
                        static_cast<int32_t>(_building_type_ids.size()) &&
                    _building_type_ids[group.type_id] == "knapping_workshop";
                if (narrow_knapping_cold_start && !survival_output && derived_only_output &&
                    !any_real_output_demand && !output_stock_available) {
                    owner_target = std::min(owner_target, group.filled_owner);
                }
                const int32_t existing_owner_slot = find_cohort_slot(
                    group.cell, group.owner_signature_id);
                const bool existing_owner_cohort = existing_owner_slot >= 0 &&
                    existing_owner_slot < static_cast<int32_t>(
                        population_store().population.size()) &&
                    population_store().population[existing_owner_slot] > 0;
                // A cold-start industrial lot with no live owner, no buyer,
                // and no output stock is not an executable employment target.
                // This closes the path where an unemployed cohort would be
                // converted into an owner before any real demand exists.
                if (narrow_knapping_cold_start && !survival_output &&
                    !existing_owner_cohort && !any_real_output_demand &&
                    !output_stock_available)
                    owner_target = 0;
                // A vacant industrial group with no canonical owner cohort is
                // not allowed to recruit an owner from shadow upstream demand.
                // Real output demand (or a survival lane) may establish the
                // owner through the normal startup path; a derived-only input
                // pressure must remain a price signal only.
            }
            // Soldiers enter only through Military ENLIST/LEVY; a state-service
            // owner seat never recruits (see planned_role_demand).
            if (group.owner_signature_id >= 0 && profession_is_state_service_only(
                    _signatures[group.owner_signature_id].profession_id))
                owner_target = 0;
            group_owner_target[g - first] = owner_target;
            for (int32_t r = 0; r < type.employee_count; ++r) {
                const JobRole &role = _building_employee_roles[type.employee_begin + r];
                const int32_t p = role.profession_id;
                const int32_t fi = group.employee_fill_begin + r;
                const int64_t role_target = active
                    ? planned_role_demand(group, role, fi) : 0;
                demand[p] = saturating_add(demand[p], role_target, _saturation_count);
                fill[p] = saturating_add(fill[p],
                    std::max<int64_t>(0, _building_employee_filled[fi]), _saturation_count);
            }
        }
        // Reuse the same profitability/utilization priority for retaining incumbent
        // owners and for hiring replacements. Population can shrink after the prior
        // employment pass, so per-group target clamps alone are insufficient when
        // several groups share one owner signature.
        thread_local std::vector<int32_t> hire_order;
        thread_local std::vector<int64_t> labor_expected_employee_income;
        thread_local std::vector<int64_t> labor_expected_owner_income;
        // The hire-order pass already evaluates every candidate role's hiring
        // gross and after-tax net for this cell. Cache them per role lane so the
        // hire loop below does not recompute the same tax formula per vacancy.
        thread_local std::vector<int64_t> hire_role_gross_cache;
        thread_local std::vector<int64_t> hire_role_net_cache;
        thread_local std::vector<uint32_t> hire_role_stamp;
        thread_local uint32_t hire_role_generation = 0;
        const size_t hire_role_lane_count = _building_employee_filled.size();
        if (hire_role_stamp.size() < hire_role_lane_count) {
            hire_role_stamp.assign(hire_role_lane_count, 0);
            hire_role_gross_cache.resize(hire_role_lane_count, 0);
            hire_role_net_cache.resize(hire_role_lane_count, 0);
        }
        if (++hire_role_generation == 0) {
            std::fill(hire_role_stamp.begin(), hire_role_stamp.end(), 0);
            hire_role_generation = 1;
        }
        hire_order.clear();
        labor_expected_employee_income.assign(static_cast<size_t>(last - first), 0);
        labor_expected_owner_income.assign(static_cast<size_t>(last - first), 0);
        for (int32_t g = first; g < last; ++g) {
            auto group = building_view(static_cast<size_t>(g));
            if (group.cell != cell || group.count <= 0 ||
                !building_available(cell, group.type_id, true) ||
                group_owner_target[g - first] <= 0) continue;
            const BuildingType &type = _building_types[group.type_id];
            int64_t score_sat = 0;
            labor_expected_owner_income[static_cast<size_t>(g - first)] =
                owner_mobility_income(group, score_sat);
            int64_t weighted_net = 0;
            int64_t weighted_slots = 0;
            for (int32_t r = 0; r < type.employee_count; ++r) {
                const JobRole &role = _building_employee_roles[type.employee_begin + r];
                const int32_t role_index = group.employee_fill_begin + r;
                const int64_t gross = expected_employee_hiring_gross(
                    role, role_index);
                const int64_t net = expected_after_tax_income(
                    cell, role.profession_id, gross, score_sat);
                const int64_t slots = std::max<int64_t>(0, role.slots_per_building);
                if (role_index >= 0 && static_cast<size_t>(role_index) <
                        hire_role_stamp.size()) {
                    hire_role_stamp[static_cast<size_t>(role_index)] =
                        hire_role_generation;
                    hire_role_gross_cache[static_cast<size_t>(role_index)] = gross;
                    hire_role_net_cache[static_cast<size_t>(role_index)] = net;
                }
                weighted_net = saturating_add(weighted_net,
                    saturating_mul(net, slots, score_sat), score_sat);
                weighted_slots = saturating_add(weighted_slots, slots, score_sat);
            }
            labor_expected_employee_income[static_cast<size_t>(g - first)] =
                weighted_slots > 0 ? weighted_net / weighted_slots : 0;
            _saturation_count = saturating_add(
                _saturation_count, score_sat, _saturation_count);
            hire_order.push_back(g);
        }
        std::stable_sort(hire_order.begin(), hire_order.end(),
                         [&](int32_t a, int32_t b) {
            const auto ga = building_view(static_cast<size_t>(a));
            const auto gb = building_view(static_cast<size_t>(b));
            if ((ga.operating_state == 0) != (gb.operating_state == 0))
                return ga.operating_state == 0;
            const size_t local_a = static_cast<size_t>(a - first);
            const size_t local_b = static_cast<size_t>(b - first);
            if (labor_expected_employee_income[local_a] !=
                    labor_expected_employee_income[local_b])
                return labor_expected_employee_income[local_a] >
                    labor_expected_employee_income[local_b];
            if (labor_expected_owner_income[local_a] !=
                    labor_expected_owner_income[local_b])
                return labor_expected_owner_income[local_a] >
                    labor_expected_owner_income[local_b];
            return a < b;
        });

        // Distress career exit: expected disposable income that cannot cover
        // livelihood must not pin workers on a dead job. Zero the retained
        // seats so the shed pass moves them into unemployed|eth; the hire
        // pass can place them onto survival-food vacancies in the same
        // period (active career switch, not treasury relief).
        auto profession_cohort_distressed = [&](int32_t profession) -> bool {
            if (profession < 0 ||
                profession == _unemployed_profession_id ||
                profession == _merchant_profession_id ||
                profession_is_state_service_only(profession)) {
                return false;
            }
            bool any = false;
            population_store().for_each_in_cell(cell, [&](int32_t slot) {
                if (any) return;
                const uint32_t sig = population_store().signature_id[slot];
                if (sig >= _signatures.size()) return;
                if (_signatures[sig].profession_id != profession) return;
                const int64_t people = population_store().population[slot];
                if (people <= 0) return;
                if (population_store().needs_satisfaction[slot] < Q16_ONE / 2) {
                    any = true;
                    return;
                }
                const int64_t living = cell >= 0 &&
                        cell < static_cast<int32_t>(
                            _cell_living_cost_per_capita.size())
                    ? std::max<int64_t>(0, _cell_living_cost_per_capita[cell])
                    : 0;
                if (living > 0 &&
                    population_store().funds[slot] / people < living) {
                    any = true;
                }
            });
            return any;
        };
        for (int32_t g = first; g < last; ++g) {
            auto group = building_view(static_cast<size_t>(g));
            if (group.cell != cell || group.count <= 0) continue;
            const BuildingType &type = _building_types[group.type_id];
            if (type.kind == 2) continue;
            const size_t local = static_cast<size_t>(g - first);
            if (group.filled_owner > 0 &&
                labor_expected_owner_income[local] <= 0 &&
                group.owner_signature_id >= 0 &&
                group.owner_signature_id <
                    static_cast<int32_t>(_signatures.size())) {
                const int32_t owner_prof =
                    _signatures[group.owner_signature_id].profession_id;
                if (profession_cohort_distressed(owner_prof)) {
                    const int64_t released = group.filled_owner;
                    group_owner_target[local] = 0;
                    _building_distress_career_exits = saturating_add(
                        _building_distress_career_exits, released,
                        _saturation_count);
                }
            }
            for (int32_t r = 0; r < type.employee_count; ++r) {
                const JobRole &role =
                    _building_employee_roles[type.employee_begin + r];
                const int32_t fi = group.employee_fill_begin + r;
                if (fi < 0 ||
                    fi >= static_cast<int32_t>(_building_employee_filled.size()))
                    continue;
                const int64_t filled =
                    std::max<int64_t>(0, _building_employee_filled[fi]);
                if (filled <= 0) continue;
                int64_t role_sat = 0;
                const int64_t gross =
                    expected_employee_hiring_gross(role, fi);
                const int64_t net = expected_after_tax_income(
                    cell, role.profession_id, gross, role_sat);
                _saturation_count = saturating_add(
                    _saturation_count, role_sat, _saturation_count);
                if (net > 0) continue;
                if (!profession_cohort_distressed(role.profession_id)) continue;
                const int64_t role_target = group.operating_state == 0
                    ? planned_role_demand(group, role, fi) : 0;
                if (role.profession_id >= 0 &&
                    role.profession_id < professions) {
                    demand[role.profession_id] = saturating_sub(
                        demand[role.profession_id], role_target,
                        _saturation_count);
                    fill[role.profession_id] = saturating_sub(
                        fill[role.profession_id], filled, _saturation_count);
                }
                _building_employee_filled.write_scalar(
                    fi, 0, market_mutation_sink());
                _building_distress_career_exits = saturating_add(
                    _building_distress_career_exits, filled,
                    _saturation_count);
            }
        }
