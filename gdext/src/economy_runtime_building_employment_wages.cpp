#include "economy_runtime_building_employment_includes.inc"

namespace pk {

namespace {
}

namespace {
using Clock = std::chrono::steady_clock;

double elapsed_ms(const Clock::time_point &start) {
    return std::chrono::duration<double, std::milli>(Clock::now() - start).count();
}
} // namespace

bool NativeEconomyRuntime::prepare_cell_wages(int32_t cell, std::string &error) {
    EconomyCostProbe cost("employment.wage_prepare", _current_day.get());
    uint64_t quoted_pairs = 0;
    const auto started = Clock::now();
    if (cell < 0 || cell >= _cell_count.get() ||
        _building_cell_offsets.size() != static_cast<size_t>(_cell_count.get() + 1) ||
        _labor_signals.cell_offsets.size() != static_cast<size_t>(_cell_count.get() + 1)) {
        error = "building_employment_restore_index_invalid";
        return false;
    }
    const int32_t begin = _building_cell_offsets[cell];
    const int32_t end = _building_cell_offsets[cell + 1];
    if (begin >= end) return true;
    const int32_t market = market_store().cell_to_market[cell];
    // Employment precedes consumption. Quote the current frozen basket here,
    // including the first settlement; the consumption pass has not populated
    // this cycle's living costs yet. Otherwise a new role posts a zero wage
    // while its recruitment check subtracts the real basket cost.
    thread_local std::vector<int64_t> variant_scores, variant_prices;
    thread_local std::vector<int64_t> need_scores, need_composites, need_environment;
    build_demand_basis_cached(cell, market, environment_sample_for_cell(cell),
        variant_scores, variant_prices, need_scores, need_composites,
        need_environment, _saturation_count);
    compute_cell_living_costs_from_basis(cell, variant_scores, variant_prices,
        need_scores, need_environment, _saturation_count);
    int64_t merchant_cash = 0;
    if (market >= 0 && market + 1 < static_cast<int32_t>(
            _merchant_offsets.size())) {
        for (int32_t i = _merchant_offsets[market];
                i < _merchant_offsets[market + 1]; ++i) {
            const int32_t slot = _merchant_slots[i];
            if (slot < 0 || slot >= static_cast<int32_t>(
                    population_store().active.size()) ||
                !population_store().active[slot] ||
                population_store().page_cell[slot / COHORT_PAGE_SIZE] != cell ||
                !is_merchant_slot(slot)) continue;
            merchant_cash = saturating_add(
                merchant_cash, std::max<int64_t>(
                    0, population_store().funds[slot]), _saturation_count);
        }
    }
    const int64_t daily_merchant_cash =
        merchant_cash / std::max(1, _epoch_days.get());
    for (int32_t signal = _labor_signals.cell_offsets[cell];
         signal < _labor_signals.cell_offsets[cell + 1]; ++signal) {
        const int32_t profession = _labor_signals.profession_ids[signal];
        const int64_t general_cost = _labor_signals.base_living_cost[signal];
        int64_t role_cost = _labor_signals.role_living_cost[signal];
        // Wage amounts are not content primitives. Legacy resource fields may
        // load for compatibility, but they never enter this live quote.
        role_cost = std::max<int64_t>(0, role_cost);
        const int64_t local_average = _labor_signals.contract_wage_ema[signal] > 0
            ? _labor_signals.contract_wage_ema[signal]
            : (_labor_signals.paid_wage_ema[signal] > 0
                ? _labor_signals.paid_wage_ema[signal]
                : std::max(general_cost, role_cost));
        for (int32_t g = begin; g < end; ++g) {
            auto group = building_view(static_cast<size_t>(g));
            if (!building_available(cell, group.type_id, true)) continue;
            const BuildingType &type = _building_types[group.type_id];
            // Military v1: a state-owned lot runs the "state_payroll" policy.
            // Its wage is the country military pay paid by the treasury
            // directly to the soldier cohort, so the lot posts no contract
            // wage of its own. Leaving the lane at zero keeps the labour quote
            // out of it without pretending the role pays "nothing".
            if (type.kind == 3) continue;
            // Only this profession's employee roles consume the quote below.
            // Previously every labor signal evaluated every producer's inputs,
            // outputs and workforce, even when the final role loop was empty.
            bool has_profession = false;
            for (int32_t role = 0; role < type.employee_count; ++role) {
                if (_building_employee_roles[type.employee_begin + role].profession_id == profession) {
                    has_profession = true;
                    break;
                }
            }
            if (!has_profession) continue;
            ++quoted_pairs;
            cost.set_work(quoted_pairs);
            // Affordability damping is a daily-flow calculation. Historical
            // last_expected_revenue is an epoch total, so comparing it directly
            // with a per-day wage lets contract wages grow by roughly epoch_days.
            // Quote only demand-backed daily output, reserve daily inputs plus
            // the configured operating margin, then divide the remaining wage
            // pool across all employee slots. Passing zero expected supply to
            // the inventory target is intentional: a new recipe must not create
            // its own merchant demand merely by advertising nameplate output.
            int64_t affordable_ceiling = 0;
            // Keep a positive opportunity signal for a cold-start vacancy.  A
            // producer can have no realized margin yet simply because its
            // employee lane is empty; for monetary outputs face × output is
            // the counterfactual receipt used below.
            int64_t profit_signal_q16 = std::clamp<int64_t>(
                group.realized_profit_margin_q16, 0, Q16_ONE);
            if (_wage_income_cap_ratio_q16 > 0) {
                // Wage affordability must track the staffed lot, not nameplate
                // full employment across every empty seat (that made a 1/5
                // staffed placer bid as if all five mines minted).
                const int64_t owner_slots = saturating_mul(
                    group.count, type.owner_slots_per_building, _saturation_count);
                int64_t workforce_q16 = owner_slots > 0
                    ? std::clamp<int64_t>(mul_div_sat(
                        std::max<int64_t>(0, group.filled_owner), Q16_ONE,
                        owner_slots, _saturation_count), 0, Q16_ONE)
                    : Q16_ONE;
                int64_t group_employee_slots = 0;
                int64_t filled_employee_heads = 0;
                int64_t living_floor_wage_pool = 0;
                for (int32_t rr = 0; rr < type.employee_count; ++rr) {
                    const JobRole &rrole =
                        _building_employee_roles[type.employee_begin + rr];
                    const int64_t role_slots = saturating_mul(
                        group.count, rrole.slots_per_building, _saturation_count);
                    const int32_t role_index = group.employee_fill_begin + rr;
                    const int64_t role_filled = role_index >= 0 &&
                            role_index < static_cast<int32_t>(
                                _building_employee_filled.size())
                        ? std::clamp<int64_t>(
                            _building_employee_filled[role_index], 0, role_slots)
                        : 0;
                    group_employee_slots = saturating_add(group_employee_slots,
                        role_slots, _saturation_count);
                    filled_employee_heads = saturating_add(
                        filled_employee_heads, role_filled, _saturation_count);
                    const int64_t role_capacity = role_slots > 0
                        ? std::clamp<int64_t>(mul_div_sat(
                            role_filled, Q16_ONE, role_slots, _saturation_count),
                            0, Q16_ONE)
                        : Q16_ONE;
                    workforce_q16 = std::min(workforce_q16, role_capacity);
                    const int32_t role_signal = labor_signal_index(
                        cell, rrole.profession_id);
                    const int64_t role_floor = role_signal >= 0
                        ? std::max(_labor_signals.base_living_cost[role_signal],
                            _labor_signals.role_living_cost[role_signal])
                        : 0;
                    living_floor_wage_pool = saturating_add(living_floor_wage_pool,
                        saturating_mul(role_filled,
                            std::max<int64_t>(role_floor, local_average),
                            _saturation_count), _saturation_count);
                }
                // Vacant employee lanes still need a first-hire bid: quote the
                // revenue one seat could earn under current owners, not zero
                // and not the fully staffed nameplate.
                if (filled_employee_heads <= 0 && group_employee_slots > 0) {
                    const int64_t owner_ratio = owner_slots > 0
                        ? std::clamp<int64_t>(mul_div_sat(
                            std::max<int64_t>(0, group.filled_owner), Q16_ONE,
                            owner_slots, _saturation_count), 0, Q16_ONE)
                        : Q16_ONE;
                    const int64_t first_seat_q16 = mul_div_sat(
                        Q16_ONE, 1, group_employee_slots, _saturation_count);
                    workforce_q16 = std::min(owner_ratio, first_seat_q16);
                    if (workforce_q16 <= 0 && owner_ratio > 0)
                        workforce_q16 = first_seat_q16;
                    living_floor_wage_pool = 0;
                    for (int32_t rr = 0; rr < type.employee_count; ++rr) {
                        const JobRole &rrole =
                            _building_employee_roles[type.employee_begin + rr];
                        if (rrole.slots_per_building <= 0) continue;
                        const int32_t role_signal = labor_signal_index(
                            cell, rrole.profession_id);
                        const int64_t role_floor = role_signal >= 0
                            ? std::max(_labor_signals.base_living_cost[role_signal],
                                _labor_signals.role_living_cost[role_signal])
                            : 0;
                        living_floor_wage_pool = saturating_add(living_floor_wage_pool,
                            std::max<int64_t>(role_floor, local_average),
                            _saturation_count);
                        break;
                    }
                }
                int64_t daily_market_revenue_per_building = 0;
                int64_t daily_issue_revenue_per_building = 0;
                for (int32_t output_index = 0;
                     output_index < type.output_count; ++output_index) {
                    const GoodAmount &output =
                        _building_outputs[type.output_begin + output_index];
                    const int64_t effective_output =
                        effective_building_output_quantity(
                            group, output.good_id, output.quantity,
                            std::clamp<int64_t>(
                                group.planned_utilization_q16, 0, Q16_ONE), 1,
                            _saturation_count);
                    const bool monetary_issue =
                        output.good_id >= 0 &&
                        output.good_id < static_cast<int32_t>(
                            _good_monetary_issue_values.size()) &&
                        _good_monetary_issue_values[output.good_id] > 0;
                    // Monetary income is face value × output. Do not route
                    // through bullion quota here — quota must not redefine
                    // what a unit of gold is worth.
                    int64_t settlement =
                        monetary_issue ? _good_monetary_issue_values[output.good_id] : 0;
                    int64_t funded_output = effective_output;
                    if (settlement <= 0) {
                        const int32_t output_signal = market_signal_index(
                            cell, output.good_id);
                        const int32_t output_flow = trade_flow_index(
                            cell, output.good_id, false);
                        const size_t market_lane =
                            market_store().index(market, output.good_id);
                        const int64_t historical_household_demand =
                            std::max<int64_t>(0, market_store().demand_ema[market_lane]);
                        const int64_t historical_withdrawal = output_signal >= 0
                            ? std::max<int64_t>(0,
                                _market_signals.realized_withdrawal_ema[
                                    output_signal])
                            : 0;
                        const int64_t historical_business_demand =
                            output_signal >= 0
                            ? std::max<int64_t>(0,
                                _market_signals.business_demand_ema[
                                    output_signal])
                            : 0;
                        const int64_t startup_demand = std::max<int64_t>(
                            startup_demand_for(cell, output.good_id),
                            remote_startup_demand_for(cell, output.good_id));
                        const int64_t export_demand = output_flow >= 0
                            ? std::max<int64_t>(
                                0, _trade_flows.export_ema[output_flow])
                            : 0;
                        const int64_t demand_backed_absorption = std::max({
                            epoch_procurement_demand_daily(cell, output.good_id),
                            historical_household_demand,
                            historical_withdrawal,
                            historical_business_demand,
                            startup_demand,
                            export_demand});
                        const int64_t output_target = merchant_inventory_target(
                            market, output.good_id, output_signal,
                            historical_withdrawal, export_demand, 0,
                            _saturation_count);
                        const int64_t inventory_gap = std::max<int64_t>(
                            0, output_target - market_store().stock[market_lane]);
                        funded_output = std::min<int64_t>(
                            effective_output, std::max(
                                demand_backed_absorption, inventory_gap));
                        const int32_t buy_factor = effective_merchant_buy_factor_q16(
                            market, output.good_id, output_target,
                            market_store().stock[market_lane],
                            _saturation_count);
                        settlement = mul_div_sat(
                            market_store().price[market_lane],
                            buy_factor, Q16_ONE, _saturation_count);
                    }
                    int64_t &revenue_lane = monetary_issue
                        ? daily_issue_revenue_per_building
                        : daily_market_revenue_per_building;
                    revenue_lane = saturating_add(
                        revenue_lane, mul_div_sat(
                            funded_output, settlement, GOODS_SCALE,
                            _saturation_count), _saturation_count);
                }
                int64_t nameplate_daily = saturating_mul(
                    daily_issue_revenue_per_building, group.count,
                    _saturation_count);
                nameplate_daily = saturating_add(
                    nameplate_daily, std::min<int64_t>(
                        daily_merchant_cash,
                        saturating_mul(daily_market_revenue_per_building,
                            group.count, _saturation_count)),
                    _saturation_count);
                int64_t daily_revenue = mul_div_sat(
                    nameplate_daily, std::max<int64_t>(0, workforce_q16),
                    Q16_ONE, _saturation_count);
                // Once the lot has minted/sold, never bid wages against more
                // cash than the previous period actually brought in per day.
                if (group.last_observed_capacity_days_q16 > 0) {
                    const int64_t epoch_days = std::max(1, _epoch_days.get());
                    const int64_t realized_period = saturating_add(
                        saturating_add(
                            std::max<int64_t>(0, group.last_bullion_mint_receipt),
                            std::max<int64_t>(0, group.last_market_receipt),
                            _saturation_count),
                        std::max<int64_t>(0, group.last_producer_support_receipt),
                        _saturation_count);
                    if (realized_period > 0) {
                        const int64_t realized_daily = realized_period / epoch_days;
                        daily_revenue = daily_revenue > 0
                            ? std::min(daily_revenue, realized_daily)
                            : realized_daily;
                    }
                }
                const int64_t wage_heads = std::max<int64_t>(1,
                    filled_employee_heads > 0 ? filled_employee_heads : 1);
                if (daily_revenue > 0 && wage_heads > 0) {
                    const int64_t margin_denominator = saturating_add(
                        Q16_ONE, std::max<int32_t>(0,
                            type.target_operating_margin_q16), _saturation_count);
                    const int64_t operating_budget = mul_div_sat(
                        daily_revenue, Q16_ONE,
                        std::max<int64_t>(1, margin_denominator),
                        _saturation_count);
                    const int64_t daily_inputs = mul_div_sat(
                        saturating_mul(
                            std::max<int64_t>(0, group.sample_unit_input_cost),
                            group.count, _saturation_count),
                        std::max<int64_t>(0, workforce_q16), Q16_ONE,
                        _saturation_count);
                    const int64_t daily_wage_pool = std::max<int64_t>(
                        0, saturating_sub(operating_budget, daily_inputs,
                                          _saturation_count));
                    const int64_t potential_profit = std::max<int64_t>(0,
                        saturating_sub(daily_revenue,
                            saturating_add(daily_inputs, living_floor_wage_pool,
                                _saturation_count), _saturation_count));
                    const int64_t potential_margin_q16 = mul_div_sat(
                        potential_profit, Q16_ONE, daily_revenue,
                        _saturation_count);
                    profit_signal_q16 = std::max(profit_signal_q16,
                        std::clamp<int64_t>(potential_margin_q16, 0, Q16_ONE));
                    const int64_t sustainable_per_employee =
                        daily_wage_pool / wage_heads;
                    affordable_ceiling = mul_div_sat(sustainable_per_employee,
                        _wage_income_cap_ratio_q16, Q16_ONE, _saturation_count);
                }
            }
            for (int32_t r = 0; r < type.employee_count; ++r) {
                const JobRole &role = _building_employee_roles[type.employee_begin + r];
                if (role.profession_id != profession) continue;
                const int32_t index = group.employee_fill_begin + r;
                int64_t floor = std::max(general_cost, role_cost);
                // Living cost may spike above what face×output can pay (e.g.
                // food shortage). Never lift the wage ceiling above revenue:
                // that made placer contract wages >> mint income while rich
                // owners still funded payroll from cash stock.
                // Clamp the living-cost floor to the employer's ability to pay,
                // but never below the living-cost floor.
                if (affordable_ceiling > 0) {
                    floor = std::min(floor, affordable_ceiling);
                }
                int64_t current = _building_role_contract_wage[index] > 0
                    ? _building_role_contract_wage[index] : std::max(floor, local_average);
                int64_t next = std::max(floor, local_average);
                {
                    int64_t desired = std::max(floor, local_average);
                    // A vacancy is a market signal in its own right.  The old
                    // target followed only the profession-wide wage EMA, so a
                    // newly profitable but understaffed mine could keep posting
                    // its cold-start wage forever.  Bid part of the affordable
                    // wage pool up in proportion to the unfilled share and the
                    // realized margin; this remains bounded by the employer's
                    // sustainable ceiling below.
                    const int64_t role_slots = std::max<int64_t>(1,
                        saturating_mul(group.count, role.slots_per_building,
                                       _saturation_count));
                    const int64_t role_filled = index >= 0 &&
                            index < static_cast<int32_t>(_building_employee_filled.size())
                        ? std::clamp<int64_t>(_building_employee_filled[index], 0,
                            role_slots) : 0;
                    const int64_t vacancy_q16 = mul_div_sat(
                        role_slots - role_filled, Q16_ONE, role_slots,
                        _saturation_count);
                    const int64_t profit_q16 = profit_signal_q16;
                    if (affordable_ceiling > 0 && vacancy_q16 > 0 && profit_q16 > 0) {
                        const int64_t shortage_bid = mul_div_sat(
                            affordable_ceiling, vacancy_q16, Q16_ONE,
                            _saturation_count);
                        const int64_t profit_bid = mul_div_sat(
                            shortage_bid, profit_q16, Q16_ONE,
                            _saturation_count);
                        desired = std::max(desired,
                            saturating_add(floor,
                                profit_bid / 2, _saturation_count));
                    }
                    // Damping also caps the target the wage chases toward, so an
                    // inflated local-average signal cannot drag wages past the
                    // employer's affordability either.
                    if (affordable_ceiling > 0) {
                        const int64_t desired_cap = std::max(
                            floor, affordable_ceiling);
                        desired = std::min(desired, desired_cap);
                    }
                    if (desired > current) {
                        const int64_t cap = std::max<int64_t>(1, mul_div_sat(
                            current, saturating_mul(_wage_max_rise_q16_per_day,
                                                    std::max(1, _epoch_days.get()),
                                                    _saturation_count),
                            Q16_ONE, _saturation_count));
                        next = std::min(desired, saturating_add(
                            current, cap, _saturation_count));
                    } else {
                        const int64_t cap = mul_div_sat(
                            current, saturating_mul(_wage_max_fall_q16_per_day,
                                                    std::max(1, _epoch_days.get()),
                                                    _saturation_count),
                            Q16_ONE, _saturation_count);
                        next = std::max(desired, saturating_sub(
                            current, cap, _saturation_count));
                    }
                    next = std::max(next, floor);
                }
                _building_role_contract_wage.write_scalar(index, next, market_mutation_sink());
                int32_t forecast_pay_ratio_q16 =
                    next <= 0 ? Q16_ONE
                    : _wage_income_cap_ratio_q16 <= 0 ? Q16_ONE
                    : static_cast<int32_t>(std::clamp<int64_t>(
                        mul_div_sat(affordable_ceiling, Q16_ONE, next,
                                    _saturation_count),
                        0, Q16_ONE));
                if (_building_role_base_wage_due[index] <= 0)
                    ++_building_employee_cold_start_forecasts;
                _building_role_forecast_pay_ratio_q16[index] =
                    forecast_pay_ratio_q16;
                if (forecast_pay_ratio_q16 < Q16_ONE)
                    ++_building_employee_funding_limited_forecasts;
                _building_role_base_living_cost.write_scalar(index, general_cost, market_mutation_sink());
                _building_role_living_cost.write_scalar(index, role_cost, market_mutation_sink());
                _building_role_local_average_wage.write_scalar(index, local_average, market_mutation_sink());
            }
        }
    }
    _wage_plan_ms += elapsed_ms(started);
    return error.empty();
}

void NativeEconomyRuntime::update_cell_labor_signals(int32_t cell) {
    const auto started = Clock::now();
    const int64_t alpha = std::min<int64_t>(
        Q16_ONE, saturating_mul(_wage_ema_alpha_q16,
                                std::max(1, _epoch_days.get()), _saturation_count));
    const int32_t signal_begin = _labor_signals.cell_offsets[cell];
    const int32_t signal_end = _labor_signals.cell_offsets[cell + 1];
    const int32_t signal_count = signal_end - signal_begin;
    if (signal_count > 0) {
        // Group-major accumulation: the old signal-major loop re-scanned every
        // building role for each profession signal. Per-signal sums keep the
        // same group order, so the aggregated EMA inputs are unchanged.
        thread_local std::vector<int64_t> signal_jobs;
        thread_local std::vector<int64_t> signal_due;
        thread_local std::vector<int64_t> signal_paid;
        signal_jobs.assign(static_cast<size_t>(signal_count), 0);
        signal_due.assign(static_cast<size_t>(signal_count), 0);
        signal_paid.assign(static_cast<size_t>(signal_count), 0);
        const int64_t day_scale = std::max(1, _epoch_days.get());
        for (int32_t g = _building_cell_offsets[cell];
             g < _building_cell_offsets[cell + 1]; ++g) {
            const auto group = building_view(static_cast<size_t>(g));
            const BuildingType &type = _building_types[group.type_id];
            for (int32_t r = 0; r < type.employee_count; ++r) {
                const JobRole &role = _building_employee_roles[type.employee_begin + r];
                const int32_t signal = labor_signal_index(cell, role.profession_id);
                if (signal < signal_begin || signal >= signal_end) continue;
                const size_t local = static_cast<size_t>(signal - signal_begin);
                const int32_t index = group.employee_fill_begin + r;
                signal_jobs[local] = saturating_add(signal_jobs[local],
                    saturating_mul(_building_employee_filled[index], day_scale,
                                   _saturation_count), _saturation_count);
                signal_due[local] = saturating_add(signal_due[local],
                    _building_role_base_wage_due[index], _saturation_count);
                signal_paid[local] = saturating_add(signal_paid[local],
                    _building_role_base_wage_paid[index], _saturation_count);
            }
        }
        for (int32_t local = 0; local < signal_count; ++local) {
            const int32_t signal = signal_begin + local;
            const int64_t jobs = signal_jobs[static_cast<size_t>(local)];
            if (jobs <= 0) continue;
            const int64_t due = signal_due[static_cast<size_t>(local)];
            const int64_t paid = signal_paid[static_cast<size_t>(local)];
            const int64_t observed_contract = due / jobs;
            const int64_t observed_paid = paid / jobs;
            auto ema = [&](int64_t previous, int64_t observed) {
                if (previous <= 0) return observed;
                return saturating_add(previous, mul_div_sat(
                    saturating_sub(observed, previous, _saturation_count),
                    alpha, Q16_ONE, _saturation_count),
                    _saturation_count);
            };
            _labor_signals.contract_wage_ema.write_scalar(signal, ema(_labor_signals.contract_wage_ema[signal], observed_contract), market_mutation_sink());
            _labor_signals.paid_wage_ema.write_scalar(signal, ema(_labor_signals.paid_wage_ema[signal], observed_paid), market_mutation_sink());
            _labor_signals.job_days.write_scalar(signal, jobs, market_mutation_sink());
            _labor_signals.pay_ratio_q16.write_scalar(signal, static_cast<int32_t>(
                std::clamp<int64_t>(mul_div_sat(paid, Q16_ONE,
                    std::max<int64_t>(1, due), _saturation_count), 0, Q16_ONE)), market_mutation_sink());
            ++_labor_signal_updates;
        }
    }
    _labor_signal_ms += elapsed_ms(started);
}

} // namespace pk
