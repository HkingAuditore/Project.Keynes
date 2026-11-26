    // A zero climate capacity is the uninitialized value before the first
    // production observation, not evidence that the counterfactual lot is
    // climatically impossible. Apply the measured capacity only after the
    // group has an observed period; otherwise vacant owner openings can never
    // attract their first owner.
    if (group.last_observed_capacity_days_q16 > 0) {
        quote.climate_factor_q16 = std::clamp<int64_t>(
            group.last_climate_capacity_q16, 0, Q16_ONE);
        natural_scale_q16 = mul_div_sat(natural_scale_q16,
            quote.climate_factor_q16, Q16_ONE, sat);
    }
    // The previous plan may be zero because this established group is vacant.
    // It is not an executable constraint for a counterfactual quote; otherwise
    // vacancy would feed back into a permanent zero-income quote.
    // Resource capacity is part of the opportunity, even when the installed
    // group is currently empty. This keeps a quote executable rather than a
    // nameplate-only accounting value.
    const auto setup_res_started = Clock::now();
    const int64_t building_days = saturating_mul(
        group.count, std::max<int64_t>(1, _epoch_days.get()), sat);
    for (int32_t i = 0; i < type.resource_count; ++i) {
        const ResourceAmount &resource = _building_resources[type.resource_begin + i];
        const int64_t base = resource.mode == 1
            ? saturating_mul(group.count, resource.quantity, sat)
            : saturating_mul(building_days, resource.quantity, sat);
        if (base <= 0) continue;
        const int64_t effective = effective_resource_use_quantity(
            group.cell, resource.resource_id, base, sat);
        if (effective <= 0) {
            resource_factor_q16 = 0;
            break;
        }
        const int64_t available = available_resource_amount(resource, group.cell);
        int64_t availability_factor_q16 = std::clamp<int64_t>(mul_div_sat(
            available, Q16_ONE, effective, sat), 0, Q16_ONE);
        if (resource.mode == 0 &&
            resource_is_renewable(resource.resource_id)) {
            const int64_t density_q16 = std::clamp<int64_t>(
                resource_stock_density_q16(resource.resource_id, group.cell),
                0, Q16_ONE);
            availability_factor_q16 = mul_div_sat(availability_factor_q16,
                density_q16, Q16_ONE, sat);
        }
        resource_factor_q16 = mul_div_sat(resource_factor_q16,
            availability_factor_q16, Q16_ONE, sat);
    }
    if (quote_trace)
        add_quote_section(quote_sections.setup_res_ms, setup_res_started);
    quote.owner_run_q16 = owner_scale_q16;
    quote.climate_factor_q16 = group.last_observed_capacity_days_q16 > 0
        ? std::clamp<int64_t>(group.last_climate_capacity_q16, 0, Q16_ONE)
        : Q16_ONE;
    quote.resource_factor_q16 = resource_factor_q16;
    quote.natural_capacity_q16 = mul_div_sat(
        quote.climate_factor_q16, resource_factor_q16, Q16_ONE, sat);
    natural_scale_q16 = quote.natural_capacity_q16;
    int64_t scale = mul_div_sat(workforce_scale_q16,
        natural_scale_q16, Q16_ONE, sat);
    quote.prospective_scale_q16 = scale;
    quote.executable_capacity_q16 = scale;
    if (scale <= 0) return quote;

    int64_t owner_slots = saturating_mul(group.count,
        type.owner_slots_per_building, sat);
    owner_slots = std::max<int64_t>(1, owner_slots);
    const auto setup_living_started = Clock::now();
    uint64_t living_hits_before = 0;
    uint64_t living_misses_before = 0;
    if (quote_trace) {
        const auto &living_memo = living_cost_memo_state();
        living_hits_before = living_memo.hits;
        living_misses_before = living_memo.misses;
    }
    quote.owner_living_cost = saturating_mul(
        living_cost_for_signature(group.cell, group.owner_signature_id,
            _living_cost_base_plan_id, sat), owner_slots, sat);
    if (quote_trace) {
        const auto &living_memo = living_cost_memo_state();
        quote_sections.setup_living_hits +=
            living_memo.hits - living_hits_before;
        quote_sections.setup_living_misses +=
            living_memo.misses - living_misses_before;
    }
    if (quote_trace)
        add_quote_section(quote_sections.setup_living_ms, setup_living_started);
    const auto setup_wages_started = Clock::now();
    int64_t wages_at_full_scale = 0;
    for (int32_t r = 0; r < type.employee_count; ++r) {
        const JobRole &role = _building_employee_roles[type.employee_begin + r];
        const int32_t ri = group.employee_fill_begin + r;
        const int32_t signal = labor_signal_index(group.cell, role.profession_id);
        const int64_t living_floor = signal >= 0
            ? std::max(_labor_signals.base_living_cost[signal],
                _labor_signals.role_living_cost[signal]) : 0;
        const int64_t market_quote = signal >= 0 && signal <
                static_cast<int32_t>(_labor_signals.contract_wage_ema.size())
            ? std::max(_labor_signals.contract_wage_ema[signal],
                _labor_signals.paid_wage_ema[signal]) : 0;
        const int64_t wage = ri >= 0 && ri < static_cast<int32_t>(
                _building_role_contract_wage.size())
            ? std::max<int64_t>(0, _building_role_contract_wage[ri]) : 0;
        const int64_t effective_wage = std::max({living_floor, market_quote, wage});
        wages_at_full_scale = saturating_add(wages_at_full_scale, saturating_mul(
            group.count, saturating_mul(role.slots_per_building, effective_wage, sat), sat), sat);
    }
    if (quote_trace)
        add_quote_section(quote_sections.setup_wages_ms, setup_wages_started);
    const auto setup_maint_started = Clock::now();
    int64_t maintenance_at_full_scale = daily_maintenance_cost_for_type(
        group.cell, type, sat);
    if (maintenance_at_full_scale == std::numeric_limits<int64_t>::max())
        maintenance_at_full_scale = 0;
    maintenance_at_full_scale = mul_div_sat(maintenance_at_full_scale,
        group.count, 1, sat);

    if (quote_trace)
        add_quote_section(quote_sections.setup_maint_ms, setup_maint_started);
    const auto setup_env_started = Clock::now();
    const int32_t owner_plan_id = group.owner_signature_id >= 0 &&
            group.owner_signature_id < static_cast<int32_t>(_signatures.size())
        ? _signatures[group.owner_signature_id].plan_id : -1;
    const EnvironmentSample owner_environment = environment_sample_for_cell(group.cell);
    if (quote_trace)
        add_quote_section(quote_sections.setup_env_ms, setup_env_started);
