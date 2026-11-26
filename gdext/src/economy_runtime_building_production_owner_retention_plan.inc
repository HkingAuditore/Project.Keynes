    for (int32_t g = begin; g < end; ++g) {
        {
            const auto group_view = building_view(static_cast<size_t>(g));
            if (group_view.cell != cell || group_view.count <= 0) continue;
        }
        auto group = building_at(static_cast<size_t>(g));
        group.last_capacity_q16 = 0;
        group.last_input = group.last_output = group.last_sold = group.last_discarded = 0;
        group.last_resource = group.last_revenue = 0;
        group.last_resource_generated = 0;
        group.last_input_cost = group.last_wages_paid = group.last_wages_due = 0;
        group.last_operating_cost = 0;
        group.last_maintenance_cost = 0;
        group.last_market_receipt = 0;
        group.last_bullion_mint_receipt = 0;
        group.last_producer_support_receipt = 0;
        group.last_business_tax_paid = 0;
        group.last_business_subsidy_received = 0;
        group.last_maintenance_due = 0;
        // This flag is refreshed from the current period's actual workforce.
        // A positive value means receipts are factual for this period; zero
        // keeps a genuinely unstaffed greenfield group eligible for bootstrap.
        group.last_observed_capacity_days_q16 = 0;
        group.purchase_intent_capacity_q16 = 0;
        group.last_base_wages_paid = group.last_base_wages_due = 0;
        group.last_bonus_paid = group.last_bonus_due = 0;
        group.wage_suspended = 0;
        const BuildingType &type = _building_types[group.type_id];
        {
            const int32_t climate_type_id = group.type_id;
            const bool climate_cacheable = climate_type_id >= 0 &&
                static_cast<size_t>(climate_type_id) < climate_type_stamp.size();
            int64_t capacity = 0;
            int64_t temperature_fit = Q16_ONE;
            int64_t water_fit = Q16_ONE;
            if (climate_cacheable &&
                climate_type_stamp[static_cast<size_t>(climate_type_id)] ==
                    climate_type_generation) {
                const size_t slot = static_cast<size_t>(climate_type_id);
                capacity = climate_type_capacity[slot];
                temperature_fit = climate_type_temperature_fit[slot];
                water_fit = climate_type_water_fit[slot];
            } else {
                capacity = production_climate_capacity_q16(
                    type, group.cell, &temperature_fit, &water_fit,
                    _saturation_count);
                if (climate_cacheable) {
                    const size_t slot = static_cast<size_t>(climate_type_id);
                    climate_type_stamp[slot] = climate_type_generation;
                    climate_type_capacity[slot] = capacity;
                    climate_type_temperature_fit[slot] = temperature_fit;
                    climate_type_water_fit[slot] = water_fit;
                }
            }
            group.last_climate_capacity_q16 = capacity;
            group.last_temperature_fit_q16 = temperature_fit;
            group.last_water_fit_q16 = water_fit;
            group.last_climate_lost_output = 0;
        }
        for (int32_t input = 0; input < type.input_count; ++input) {
            _building_last_input_selected_goods[
                group.last_input_selection_begin + input] = -1;
        }
        if (!building_available(cell, group.type_id, true)) continue;
        // Military v1: a state-owned lot pays nothing from building cash. Its
        // payroll role is the "state_payroll" policy — the wage is the country
        // military pay, transferred by Military through
        // COMMAND_TRANSFER_TO_COHORT directly into the soldier cohort. Keeping
        // due == paid == 0 here leaves no arrear, no wage suspension and no
        // owner-cash draw for the state lot.
        const bool state_payroll_group = type.kind == 3;
        for (int32_t r = 0; r < type.employee_count; ++r) {
            const int32_t role_index = group.employee_fill_begin + r;
            const int64_t wage_due = state_payroll_group ? 0 : saturating_mul(
                saturating_mul(_building_employee_filled[role_index],
                               _building_role_contract_wage[role_index],
                               _saturation_count),
                std::max(1, _epoch_days.get()), _saturation_count);
            _building_role_base_wage_due.write_scalar(role_index, wage_due, market_mutation_sink());
            _building_role_base_wage_paid.write_scalar(role_index, 0, market_mutation_sink());
            _building_role_bonus_due.write_scalar(role_index, 0, market_mutation_sink());
            _building_role_bonus_paid.write_scalar(role_index, 0, market_mutation_sink());
            group.last_base_wages_due = saturating_add(
                group.last_base_wages_due, wage_due, _saturation_count);
        }
        group.last_wages_due = group.last_base_wages_due;
    }
    thread_local std::vector<int32_t> payroll_owners;
    payroll_owners.clear();
    for (int32_t g = begin; g < end; ++g) {
        if (buildings_store().group_units[g] > 0 && building_available(cell, buildings_store().type_id[g], true))
            payroll_owners.push_back(buildings_store().owner_signature_id[g]);
    }
    std::sort(payroll_owners.begin(), payroll_owners.end());
    payroll_owners.erase(std::unique(payroll_owners.begin(), payroll_owners.end()),
                         payroll_owners.end());
    thread_local std::vector<int32_t> retention_owner_slots;
    thread_local std::vector<int64_t> retention_targets;
    thread_local std::vector<int64_t> retention_used;
    thread_local std::vector<int32_t> retention_lane_by_owner_good;
    thread_local std::vector<uint32_t> retention_lane_stamp;
    thread_local std::vector<int32_t> retention_owner_by_signature;
    thread_local std::vector<uint32_t> retention_signature_stamp;
    thread_local std::vector<int32_t> retention_owner_by_slot;
    thread_local std::vector<uint32_t> retention_slot_stamp;
    thread_local uint32_t retention_generation = 0;
    thread_local std::vector<int64_t> retention_food_targets;
    thread_local std::vector<int64_t> retention_food_used;
    thread_local std::vector<int64_t> retention_clothing_targets;
    thread_local std::vector<int64_t> retention_clothing_used;
    thread_local std::vector<uint8_t> retention_produces_survival_food;
    thread_local std::vector<int64_t> retention_variant_scores;
    thread_local std::vector<int64_t> retention_variant_prices;
    thread_local std::vector<int64_t> retention_need_score_sums;
    thread_local std::vector<int64_t> retention_need_composites;
    thread_local std::vector<int64_t> retention_need_environment;
    ++retention_generation;
    if (retention_generation == 0) {
        std::fill(retention_lane_stamp.begin(), retention_lane_stamp.end(), 0);
        std::fill(retention_signature_stamp.begin(), retention_signature_stamp.end(), 0);
        std::fill(retention_slot_stamp.begin(), retention_slot_stamp.end(), 0);
        retention_generation = 1;
    }
    const size_t retention_dense_size = payroll_owners.size() *
        static_cast<size_t>(market_store().good_count.get());
    if (retention_lane_by_owner_good.size() < retention_dense_size) {
        retention_lane_by_owner_good.resize(retention_dense_size, -1);
        retention_lane_stamp.resize(retention_dense_size, 0);
    }
    if (retention_owner_by_signature.size() < _signatures.size()) {
        retention_owner_by_signature.resize(_signatures.size(), -1);
        retention_signature_stamp.resize(_signatures.size(), 0);
    }
    if (retention_owner_by_slot.size() < population_store().active.size()) {
        retention_owner_by_slot.resize(population_store().active.size(), -1);
        retention_slot_stamp.resize(population_store().active.size(), 0);
    }
    for (size_t owner = 0; owner < payroll_owners.size(); ++owner) {
        const int32_t signature = payroll_owners[owner];
        if (signature < 0 || signature >= static_cast<int32_t>(_signatures.size())) continue;
        retention_owner_by_signature[signature] = static_cast<int32_t>(owner);
        retention_signature_stamp[signature] = retention_generation;
    }
    // Each payroll owner's groups in ascending group order: exactly the groups
    // a full `owner_signature_id == owner` scan of [begin, end) would visit.
    // Group ownership is not mutated anywhere in production.
    thread_local std::vector<int32_t> owner_group_offsets;
    thread_local std::vector<int32_t> owner_groups;
    thread_local std::vector<int32_t> group_payroll_owner;
    owner_group_offsets.assign(payroll_owners.size() + 1, 0);
    group_payroll_owner.assign(static_cast<size_t>(std::max(0, end - begin)), -1);
    for (int32_t g = begin; g < end; ++g) {
        const int32_t signature = buildings_store().owner_signature_id[g];
        const auto it = std::lower_bound(payroll_owners.begin(), payroll_owners.end(), signature);
        if (it == payroll_owners.end() || *it != signature) continue;
        const int32_t owner = static_cast<int32_t>(it - payroll_owners.begin());
        group_payroll_owner[static_cast<size_t>(g - begin)] = owner;
        ++owner_group_offsets[static_cast<size_t>(owner) + 1];
    }
    for (size_t owner = 0; owner < payroll_owners.size(); ++owner)
        owner_group_offsets[owner + 1] += owner_group_offsets[owner];
    owner_groups.resize(static_cast<size_t>(owner_group_offsets.back()));
    {
        thread_local std::vector<int32_t> fill_cursor;
        fill_cursor.assign(owner_group_offsets.begin(), owner_group_offsets.end() - 1);
        for (int32_t g = begin; g < end; ++g) {
            const int32_t owner = group_payroll_owner[static_cast<size_t>(g - begin)];
            if (owner >= 0)
                owner_groups[static_cast<size_t>(fill_cursor[static_cast<size_t>(owner)]++)] = g;
        }
    }
    EconomyCostProbe::record("production.prepare.owners", _current_day.get(),
                             elapsed_ms(production_prepare_mark));
    production_prepare_mark = Clock::now();
    auto retention_lane = [&](size_t owner, int32_t good) -> int32_t {
        if (owner >= payroll_owners.size() || good < 0 || good >= market_store().good_count.get())
            return -1;
        const size_t key = owner * static_cast<size_t>(market_store().good_count.get()) +
            static_cast<size_t>(good);
        return retention_lane_stamp[key] == retention_generation
            ? retention_lane_by_owner_good[key] : -1;
    };
    auto ensure_retention_lane = [&](size_t owner, int32_t good) -> int32_t {
        const size_t key = owner * static_cast<size_t>(market_store().good_count.get()) +
            static_cast<size_t>(good);
        if (retention_lane_stamp[key] == retention_generation)
            return retention_lane_by_owner_good[key];
        const int32_t lane = static_cast<int32_t>(retention_targets.size());
        retention_lane_by_owner_good[key] = lane;
        retention_lane_stamp[key] = retention_generation;
        retention_targets.push_back(0);
        retention_used.push_back(0);
        return lane;
    };
    retention_owner_slots.assign(payroll_owners.size(), -1);
    retention_targets.clear();
    retention_used.clear();
    retention_food_targets.assign(payroll_owners.size(), 0);
    retention_food_used.assign(payroll_owners.size(), 0);
    retention_clothing_targets.assign(payroll_owners.size(), 0);
    retention_clothing_used.assign(payroll_owners.size(), 0);
    retention_produces_survival_food.assign(payroll_owners.size(), uint8_t{0});
    for (int32_t g = begin; g < end; ++g) {
        const auto group = building_view(static_cast<size_t>(g));
        if (group.cell != cell || group.count <= 0) continue;
        if (group.owner_signature_id < 0 ||
            group.owner_signature_id >= static_cast<int32_t>(_signatures.size()) ||
            retention_signature_stamp[group.owner_signature_id] != retention_generation)
            continue;
        const size_t owner_index = static_cast<size_t>(
            retention_owner_by_signature[group.owner_signature_id]);
        const BuildingType &type = _building_types[group.type_id];
        for (int32_t i = 0; i < type.output_count; ++i) {
            const int32_t good = _building_outputs[type.output_begin + i].good_id;
            ensure_retention_lane(owner_index, good);
            if (_survival_food_good_mask[good] != 0) {
                retention_produces_survival_food[owner_index] = 1;
            }
        }
    }
    EconomyCostProbe::record("production.prepare.retention_setup", _current_day.get(),
                             elapsed_ms(production_prepare_mark));
    production_prepare_mark = Clock::now();
    const EnvironmentSample retention_environment = environment_sample_for_cell(cell);
    build_demand_basis_cached(cell, market, retention_environment,
                       retention_variant_scores, retention_variant_prices,
                       retention_need_score_sums, retention_need_composites,
                       retention_need_environment, _saturation_count);
    EconomyCostProbe::record("production.prepare.basis", _current_day.get(),
                             elapsed_ms(production_prepare_mark));
    production_prepare_mark = Clock::now();
    thread_local std::vector<int32_t> retention_family_factors;
    for (size_t owner = 0; owner < payroll_owners.size(); ++owner) {
        retention_family_factors.assign(_good_ids.size(), -1);
        const int32_t owner_slot = find_cohort_slot(cell, payroll_owners[owner]);
        retention_owner_slots[owner] = owner_slot;
        if (owner_slot < 0) continue;
        retention_owner_by_slot[owner_slot] = static_cast<int32_t>(owner);
        retention_slot_stamp[owner_slot] = retention_generation;
        const uint32_t signature_id = population_store().signature_id[owner_slot];
        if (signature_id >= _signatures.size()) continue;
        const Signature &signature = _signatures[signature_id];
        const Plan &plan = _plans[signature.plan_id];
        const int64_t population = std::max<int64_t>(0, population_store().population[owner_slot]);
        const bool produces_survival_food =
            retention_produces_survival_food[owner] != 0;
        const int64_t temperature_exposure_q16 = std::clamp<int64_t>(
            (Q16_ONE / 2 - retention_environment.temperature_q16) * 2,
            0, Q16_ONE);
        const int64_t cold_exposure_q16 = std::max<int64_t>(
            temperature_exposure_q16,
            std::clamp<int64_t>(retention_environment.snow_q16, 0, Q16_ONE));
        int64_t clothing_retention_q16 = 0;
        if (cold_exposure_q16 > Q16_ONE - _survival_production_target_q16) {
            clothing_retention_q16 = Q16_ONE - mul_div_sat(
                Q16_ONE - _survival_production_target_q16,
                Q16_ONE, cold_exposure_q16, _saturation_count);
        }
        int64_t survival_food_desired = 0;
        int64_t produced_food_desired = 0;
        for (int32_t n = 0; n < plan.need_count; ++n) {
            const int32_t need_index = plan.need_begin + n;
            const Need &need = _needs[need_index];
            const int32_t stable_need = need.stable_id;
            const bool survival_food = stable_need >= 0 &&
                stable_need < static_cast<int32_t>(
                    _survival_food_need_mask.size()) &&
                _survival_food_need_mask[stable_need] != 0;
            if (survival_food) {
                const int64_t food_desired = survival_required_units(
                    owner_slot, stable_need, _epoch_days.get(),
                    retention_environment, _saturation_count);
                survival_food_desired = saturating_add(
                    survival_food_desired, food_desired,
                    _saturation_count);
            }
            const bool survival_clothing =
                stable_need == _survival_clothing_need_stable_id &&
                population > 0 && clothing_retention_q16 > 0;
            int64_t desired = survival_food
                ? survival_required_units(owner_slot, stable_need, _epoch_days.get(),
                    retention_environment, _saturation_count)
                : (survival_clothing
                    ? 0
                    : desired_need_units(owner_slot, need_index, _epoch_days.get(),
                        need_index < static_cast<int32_t>(
                            retention_need_environment.size())
                            ? retention_need_environment[need_index] : Q16_ONE,
                        need_index < static_cast<int32_t>(
                            retention_need_composites.size())
                            ? retention_need_composites[need_index] : Q16_ONE,
                        _saturation_count));
            if (survival_clothing) {
                const int64_t full_desired = survival_required_units(
                    owner_slot, stable_need, _epoch_days.get(),
                    retention_environment, _saturation_count);
                desired = std::max<int64_t>(desired, mul_div_sat(
                    full_desired, clothing_retention_q16, Q16_ONE,
                    _saturation_count));
                retention_clothing_targets[owner] = std::max<int64_t>(
                    retention_clothing_targets[owner], desired);
            }
            if (!survival_food && !survival_clothing && desired <= 0) continue;
            std::array<int64_t, MAX_VARIANTS_PER_NEED>
                owner_variant_scores{};
            int64_t score_sum = 0;
            for (int32_t v = 0; v < need.variant_count; ++v) {
                const int32_t variant_id = need.variant_begin + v;
                // 目录的数量界也保证 family variant 加权不会饱和；零基础分数
                // 因而可直接保留零，不必为未解锁/零偏好项反复查家族 CSR。
                static_assert(GOODS_SCALE <= INT64_MAX / (4LL * Q16_ONE * Q16_ONE));
                static const bool full_variant = [] {
                    const char *value = pk::runtime_switch_value(pk::RuntimeSwitch::PK_ECONOMY_ACTIVE_WORKSET_DISABLE);
                    return value && std::strcmp(value, "1") == 0;
                }();
                if (!full_variant && retention_variant_scores[variant_id] == 0 &&
                        _variants[variant_id].preview_price_saturation_free)
                    continue;
                owner_variant_scores[v] = std::max<int64_t>(0, mul_div_sat(
                    retention_variant_scores[variant_id],
                    family_variant_preference_factor_q16(
                        owner_slot, variant_id, _saturation_count, retention_family_factors.data()),
                    Q16_ONE, _saturation_count));
                score_sum = saturating_add(
                    score_sum, owner_variant_scores[v], _saturation_count);
            }
            if (desired <= 0 || score_sum <= 0) continue;
            int64_t score_prefix = 0;
            int64_t allocated = 0;
            for (int32_t v = 0; v < need.variant_count; ++v) {
                const int32_t variant_id = need.variant_begin + v;
                const VariantChoice &variant = _variants[variant_id];
                score_prefix = saturating_add(
                    score_prefix, owner_variant_scores[v], _saturation_count);
                const int64_t next = mul_div_sat(
                    desired, score_prefix, score_sum, _saturation_count);
                const int64_t units = std::max<int64_t>(0, next - allocated);
                allocated = next;
                if (units <= 0) continue;
                // Composite variant components are retained only when the owner produces them.
                // Other components continue through normal market procurement.
                for (int32_t c = 0; c < variant.component_count; ++c) {
                    const NeedComponent &component = _components[
                        variant.component_begin + c];
                    const int32_t lane = retention_lane(owner, component.good_id);
                    if (lane < 0) continue;
                    const int64_t quantity = mul_div_sat(
                        units, component.qty_per_need, GOODS_SCALE,
                        _saturation_count);
                    if (survival_food) {
                        produced_food_desired = saturating_add(
                            produced_food_desired, quantity, _saturation_count);
                    } else {
                        retention_targets[lane] = saturating_add(
                            retention_targets[lane], quantity, _saturation_count);
                    }
                }
            }
        }
        if (produces_survival_food && population > 0) {
            // Every survival-food output can satisfy the aggregate healthy food
            // basket through emergency substitution, so retain against the
            // complete food pool rather than a single nutrition row.
            const int64_t desired = survival_food_desired;
            const int64_t numerator = saturating_add(saturating_mul(
                desired, _survival_production_target_q16,
                _saturation_count), Q16_ONE - 1, _saturation_count);
            // Keep the configured survival retention fraction authoritative.
            // Clamping to the amount of a preferred variant could retain an
            // entire small production batch and remove the cash-backed lane.
            retention_food_targets[owner] = numerator / Q16_ONE;
        }
    }
    const bool has_cell_signals =
        _market_signals.cell_offsets.size() == static_cast<size_t>(_cell_count.get() + 1);
    const int32_t cell_signal_begin = has_cell_signals
        ? _market_signals.cell_offsets[cell] : 0;
    const int32_t cell_signal_end = has_cell_signals
        ? _market_signals.cell_offsets[cell + 1] : 0;
    const size_t cell_signal_count = static_cast<size_t>(
        std::max(0, cell_signal_end - cell_signal_begin));
    EconomyCostProbe::record("production.prepare.retention_plan", _current_day.get(),
                             elapsed_ms(production_prepare_mark));
    production_prepare_mark = Clock::now();
