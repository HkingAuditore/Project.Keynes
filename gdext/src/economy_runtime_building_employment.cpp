#include "economy_runtime.h"
#include "country_runtime.h"

#include <algorithm>
#include <chrono>
#include <limits>

namespace pk {

void NativeEconomyRuntime::replace_employment_metrics_for_cell(
        int32_t cell, int64_t owner_jobs, int64_t employee_jobs,
        int64_t unemployed_population) {
    if (cell < 0 || cell >= _cell_count) return;
    const size_t cells = static_cast<size_t>(_cell_count);
    if (_employment_metrics_epoch_by_cell.size() != cells) {
        _employment_metrics_epoch_by_cell.assign(
            cells, std::numeric_limits<int64_t>::min());
        _employment_owner_jobs_by_cell.assign(cells, 0);
        _employment_employee_jobs_by_cell.assign(cells, 0);
        _employment_unemployed_by_cell.assign(cells, 0);
    }
    const size_t index = static_cast<size_t>(cell);
    if (_employment_metrics_epoch_by_cell[index] == _epoch_id) {
        _filled_owner_jobs = saturating_sub(
            _filled_owner_jobs, _employment_owner_jobs_by_cell[index],
            _saturation_count);
        _filled_employee_jobs = saturating_sub(
            _filled_employee_jobs, _employment_employee_jobs_by_cell[index],
            _saturation_count);
        _unemployed_population = saturating_sub(
            _unemployed_population, _employment_unemployed_by_cell[index],
            _saturation_count);
    }
    _employment_metrics_epoch_by_cell[index] = _epoch_id;
    _employment_owner_jobs_by_cell[index] = std::max<int64_t>(0, owner_jobs);
    _employment_employee_jobs_by_cell[index] = std::max<int64_t>(0, employee_jobs);
    _employment_unemployed_by_cell[index] = std::max<int64_t>(
        0, unemployed_population);
    _filled_owner_jobs = saturating_add(
        _filled_owner_jobs, _employment_owner_jobs_by_cell[index],
        _saturation_count);
    _filled_employee_jobs = saturating_add(
        _filled_employee_jobs, _employment_employee_jobs_by_cell[index],
        _saturation_count);
    _unemployed_population = saturating_add(
        _unemployed_population, _employment_unemployed_by_cell[index],
        _saturation_count);
}

bool NativeEconomyRuntime::reconcile_building_employment_after_population_change(
        const std::vector<int32_t> &affected_cells, std::string &error) {
    thread_local std::vector<int32_t> stable_cells;
    thread_local std::vector<uint32_t> stable_cell_stamp;
    thread_local uint32_t stable_cell_generation = 0;
    if (stable_cell_stamp.size() < static_cast<size_t>(_cell_count))
        stable_cell_stamp.resize(static_cast<size_t>(_cell_count), 0);
    ++stable_cell_generation;
    if (stable_cell_generation == 0) {
        std::fill(stable_cell_stamp.begin(), stable_cell_stamp.end(), 0);
        stable_cell_generation = 1;
    }
    stable_cells.clear();
    for (const int32_t cell : affected_cells) {
        if (cell < 0 || cell >= _cell_count ||
            stable_cell_stamp[cell] == stable_cell_generation) continue;
        stable_cell_stamp[cell] = stable_cell_generation;
        stable_cells.push_back(cell);
    }
    std::sort(stable_cells.begin(), stable_cells.end());

    return reconcile_building_employment_cells_range(
        stable_cells, 0, static_cast<int32_t>(stable_cells.size()), error);
}

bool NativeEconomyRuntime::reconcile_building_employment_cells_range(
        const std::vector<int32_t> &stable_cells, int32_t begin, int32_t end,
        std::string &error) {
    const int32_t professions = static_cast<int32_t>(_profession_ids.size());
    thread_local std::vector<int32_t> priority;
    thread_local std::vector<int64_t> sig_population;
    thread_local std::vector<int64_t> sig_owner_filled;
    thread_local std::vector<int64_t> sig_owner_distributed;
    thread_local std::vector<int64_t> profession_capacity;
    thread_local std::vector<int64_t> profession_filled;
    thread_local std::vector<int64_t> profession_prefix;
    thread_local std::vector<int64_t> profession_distributed;
    thread_local std::vector<uint32_t> signature_stamp;
    thread_local std::vector<uint32_t> profession_stamp;
    thread_local uint32_t scratch_generation = 0;

    begin = std::clamp(begin, 0, static_cast<int32_t>(stable_cells.size()));
    end = std::clamp(end, begin, static_cast<int32_t>(stable_cells.size()));

    if (sig_population.size() < _signatures.size()) {
        sig_population.resize(_signatures.size(), 0);
        sig_owner_filled.resize(_signatures.size(), 0);
        sig_owner_distributed.resize(_signatures.size(), 0);
        signature_stamp.resize(_signatures.size(), 0);
    }
    if (profession_capacity.size() < static_cast<size_t>(professions)) {
        profession_capacity.resize(professions, 0);
        profession_filled.resize(professions, 0);
        profession_prefix.resize(professions, 0);
        profession_distributed.resize(professions, 0);
        profession_stamp.resize(professions, 0);
    }

    for (int32_t ordinal = begin; ordinal < end; ++ordinal) {
        const int32_t cell = stable_cells[ordinal];
        ++scratch_generation;
        if (scratch_generation == 0) {
            std::fill(signature_stamp.begin(), signature_stamp.end(), 0);
            std::fill(profession_stamp.begin(), profession_stamp.end(), 0);
            scratch_generation = 1;
        }
        auto touch_signature = [&](int32_t signature) {
            if (signature_stamp[signature] == scratch_generation) return;
            signature_stamp[signature] = scratch_generation;
            sig_population[signature] = 0;
            sig_owner_filled[signature] = 0;
            sig_owner_distributed[signature] = 0;
        };
        auto touch_profession = [&](int32_t profession) {
            if (profession_stamp[profession] == scratch_generation) return;
            profession_stamp[profession] = scratch_generation;
            profession_capacity[profession] = 0;
            profession_filled[profession] = 0;
            profession_prefix[profession] = 0;
            profession_distributed[profession] = 0;
        };
        const int32_t first = _building_cell_offsets[cell];
        const int32_t last = _building_cell_offsets[cell + 1];
        _population.for_each_in_cell(cell, [&](int32_t slot) {
            const uint32_t sig = _population.signature_id[slot];
            if (sig < sig_population.size()) {
                touch_signature(static_cast<int32_t>(sig));
                sig_population[sig] = saturating_add(sig_population[sig],
                    std::max<int64_t>(0, _population.population[slot]), _saturation_count);
            }
        });

        priority.clear();
        for (int32_t g = first; g < last; ++g) {
            BuildingGroup &group = _buildings[g];
            if (group.cell != cell || group.count <= 0 ||
                !building_available(cell, group.type_id, true)) {
                group.filled_owner = 0;
                if (group.type_id >= 0 &&
                    group.type_id < static_cast<int32_t>(_building_types.size())) {
                    const BuildingType &type = _building_types[group.type_id];
                    for (int32_t r = 0; r < type.employee_count; ++r)
                        _building_employee_filled[group.employee_fill_begin + r] = 0;
                }
                continue;
            }
            priority.push_back(g);
        }
        std::stable_sort(priority.begin(), priority.end(), [&](int32_t a, int32_t b) {
            const BuildingGroup &ga = _buildings[a];
            const BuildingGroup &gb = _buildings[b];
            if (ga.realized_profit_margin_q16 != gb.realized_profit_margin_q16)
                return ga.realized_profit_margin_q16 > gb.realized_profit_margin_q16;
            if (ga.planned_utilization_q16 != gb.planned_utilization_q16)
                return ga.planned_utilization_q16 > gb.planned_utilization_q16;
            return a < b;
        });

        for (int32_t g : priority) {
            BuildingGroup &group = _buildings[g];
            const int32_t sig = group.owner_signature_id;
            if (sig < 0 || sig >= static_cast<int32_t>(sig_population.size())) {
                error = "building_owner_signature_invalid_after_population_change";
                return false;
            }
            touch_signature(sig);
            const int64_t available = std::max<int64_t>(
                0, sig_population[sig] - sig_owner_filled[sig]);
            group.filled_owner = std::min(
                std::max<int64_t>(0, group.filled_owner), available);
            sig_owner_filled[sig] = saturating_add(
                sig_owner_filled[sig], group.filled_owner, _saturation_count);
        }

        _population.for_each_in_cell(cell, [&](int32_t slot) {
            if (is_merchant_slot(slot)) return;
            const int32_t sig = static_cast<int32_t>(_population.signature_id[slot]);
            const int32_t profession = _signatures[sig].profession_id;
            if (profession == _unemployed_profession_id) return;
            touch_profession(profession);
            const int64_t owner = std::min(sig_owner_filled[sig],
                std::max<int64_t>(0, _population.population[slot]));
            profession_capacity[profession] = saturating_add(
                profession_capacity[profession],
                std::max<int64_t>(0, _population.population[slot] - owner),
                _saturation_count);
        });
        for (int32_t g : priority) {
            BuildingGroup &group = _buildings[g];
            const BuildingType &type = _building_types[group.type_id];
            for (int32_t r = 0; r < type.employee_count; ++r) {
                const JobRole &role = _building_employee_roles[type.employee_begin + r];
                touch_profession(role.profession_id);
                const int32_t index = group.employee_fill_begin + r;
                const int64_t available = std::max<int64_t>(
                    0, profession_capacity[role.profession_id] -
                        profession_filled[role.profession_id]);
                _building_employee_filled[index] = std::min(
                    std::max<int64_t>(0, _building_employee_filled[index]), available);
                profession_filled[role.profession_id] = saturating_add(
                    profession_filled[role.profession_id],
                    _building_employee_filled[index], _saturation_count);
            }
        }

        int64_t owner_after = 0;
        int64_t employee_after = 0;
        int64_t unemployed_after = 0;
        _population.for_each_in_cell(cell, [&](int32_t slot) {
            const int32_t sig = static_cast<int32_t>(_population.signature_id[slot]);
            const int32_t profession = _signatures[sig].profession_id;
            const int64_t population = std::max<int64_t>(0, _population.population[slot]);
            const int64_t owner = std::min(population, std::max<int64_t>(
                0, sig_owner_filled[sig] - sig_owner_distributed[sig]));
            sig_owner_distributed[sig] = saturating_add(
                sig_owner_distributed[sig], owner, _saturation_count);
            int64_t employee = 0;
            if (!is_merchant_slot(slot) && profession != _unemployed_profession_id) {
                const int64_t capacity = std::max<int64_t>(0, population - owner);
                profession_prefix[profession] = saturating_add(
                    profession_prefix[profession], capacity, _saturation_count);
                const int64_t next = profession_capacity[profession] > 0
                    ? mul_div_sat(profession_filled[profession],
                        profession_prefix[profession], profession_capacity[profession],
                        _saturation_count) : 0;
                employee = std::min(capacity, std::max<int64_t>(
                    0, next - profession_distributed[profession]));
                profession_distributed[profession] = next;
            }
            _population.owner_employed[slot] = owner;
            _population.employee_employed[slot] = employee;
            owner_after = saturating_add(owner_after, owner, _saturation_count);
            employee_after = saturating_add(employee_after, employee, _saturation_count);
            unemployed_after = saturating_add(unemployed_after,
                std::max<int64_t>(0, population - owner - employee), _saturation_count);
        });
        replace_employment_metrics_for_cell(
            cell, owner_after, employee_after, unemployed_after);
    }
    return true;
}

namespace {
using Clock = std::chrono::steady_clock;

double elapsed_ms(const Clock::time_point &start) {
    return std::chrono::duration<double, std::milli>(Clock::now() - start).count();
}
} // namespace

bool NativeEconomyRuntime::prepare_cell_wages(int32_t cell, std::string &error) {
    const auto started = Clock::now();
    const int32_t begin = _building_cell_offsets[cell];
    const int32_t end = _building_cell_offsets[cell + 1];
    if (begin >= end) return true;
    for (int32_t signal = _labor_signals.cell_offsets[cell];
         signal < _labor_signals.cell_offsets[cell + 1]; ++signal) {
        const int32_t profession = _labor_signals.profession_ids[signal];
        const int64_t general_cost = _labor_signals.base_living_cost[signal];
        int64_t role_cost = _labor_signals.role_living_cost[signal];
        int64_t reference_total = 0;
        int64_t reference_weight = 0;
        for (int32_t g = begin; g < end; ++g) {
            const BuildingGroup &group = _buildings[g];
            if (!building_available(cell, group.type_id, true)) continue;
            const BuildingType &type = _building_types[group.type_id];
            for (int32_t r = 0; r < type.employee_count; ++r) {
                const JobRole &role = _building_employee_roles[type.employee_begin + r];
                if (role.profession_id != profession) continue;
                const int64_t slots = saturating_mul(
                    group.count, role.slots_per_building, _saturation_count);
                reference_total = saturating_add(reference_total,
                    saturating_mul(slots, role.reference_wage_per_day,
                                   _saturation_count), _saturation_count);
                reference_weight = saturating_add(reference_weight, slots,
                                                  _saturation_count);
            }
        }
        const int64_t reference = reference_weight > 0
            ? reference_total / reference_weight : 0;
        if (role_cost == 0) role_cost = std::max(general_cost, reference);
        const int64_t local_average = _labor_signals.contract_wage_ema[signal] > 0
            ? _labor_signals.contract_wage_ema[signal] : reference;
        for (int32_t g = begin; g < end; ++g) {
            BuildingGroup &group = _buildings[g];
            if (!building_available(cell, group.type_id, true)) continue;
            const BuildingType &type = _building_types[group.type_id];
            // Affordability damping is a daily-flow calculation. Historical
            // last_expected_revenue is an epoch total, so comparing it directly
            // with a per-day wage lets contract wages grow by roughly epoch_days.
            // Quote the current full-capacity daily output instead, reserve daily
            // inputs plus the configured operating margin, then divide the
            // remaining wage pool across all employee slots. This also gives a
            // suspended building a stable recovery quote instead of a zero basis.
            int64_t affordable_ceiling = 0;
            if (_wage_income_cap_ratio_q16 > 0) {
                int64_t group_employee_slots = 0;
                for (int32_t rr = 0; rr < type.employee_count; ++rr) {
                    const JobRole &rrole =
                        _building_employee_roles[type.employee_begin + rr];
                    group_employee_slots = saturating_add(group_employee_slots,
                        saturating_mul(group.count, rrole.slots_per_building,
                                       _saturation_count), _saturation_count);
                }
                const int32_t market = _market.cell_to_market[cell];
                int64_t daily_revenue_per_building = 0;
                for (int32_t output_index = 0;
                     output_index < type.output_count; ++output_index) {
                    const GoodAmount &output =
                        _building_outputs[type.output_begin + output_index];
                    const int64_t effective_output =
                        effective_building_output_quantity(
                            group, output.quantity, Q16_ONE, 1,
                            _saturation_count);
                    int64_t settlement = _good_monetary_issue_values[output.good_id];
                    if (settlement <= 0) {
                        const int32_t output_signal = market_signal_index(
                            cell, output.good_id);
                        const int32_t output_flow = trade_flow_index(
                            cell, output.good_id, false);
                        const int64_t output_target = merchant_inventory_target(
                            market, output.good_id, output_signal,
                            output_signal >= 0 ? _market_signals.realized_withdrawal_ema[
                                output_signal] : 0,
                            output_flow >= 0 ? _trade_flows.export_ema[output_flow] : 0,
                            effective_output, _saturation_count);
                        const int32_t buy_factor = effective_merchant_buy_factor_q16(
                            market, output.good_id, output_target,
                            _market.stock[_market.index(market, output.good_id)],
                            _saturation_count);
                        settlement = mul_div_sat(
                            _market.price[_market.index(market, output.good_id)],
                            buy_factor, Q16_ONE, _saturation_count);
                    }
                    daily_revenue_per_building = saturating_add(
                        daily_revenue_per_building, mul_div_sat(
                            effective_output, settlement, GOODS_SCALE,
                            _saturation_count), _saturation_count);
                }
                if (daily_revenue_per_building > 0 && group_employee_slots > 0) {
                    const int64_t daily_revenue = saturating_mul(
                        daily_revenue_per_building, group.count, _saturation_count);
                    const int64_t margin_denominator = saturating_add(
                        Q16_ONE, std::max<int32_t>(0,
                            type.target_operating_margin_q16), _saturation_count);
                    const int64_t operating_budget = mul_div_sat(
                        daily_revenue, Q16_ONE,
                        std::max<int64_t>(1, margin_denominator),
                        _saturation_count);
                    const int64_t daily_inputs = saturating_mul(
                        std::max<int64_t>(0, group.sample_unit_input_cost),
                        group.count, _saturation_count);
                    const int64_t daily_wage_pool = std::max<int64_t>(
                        0, saturating_sub(operating_budget, daily_inputs,
                                          _saturation_count));
                    const int64_t sustainable_per_employee =
                        daily_wage_pool / group_employee_slots;
                    affordable_ceiling = mul_div_sat(sustainable_per_employee,
                        _wage_income_cap_ratio_q16, Q16_ONE, _saturation_count);
                }
            }
            for (int32_t r = 0; r < type.employee_count; ++r) {
                const JobRole &role = _building_employee_roles[type.employee_begin + r];
                if (role.profession_id != profession) continue;
                const int32_t index = group.employee_fill_begin + r;
                int64_t floor = std::max(general_cost, role_cost);
                // Clamp the living-cost floor to the employer's ability to pay,
                // but never below the configured reference wage (so a viable
                // building still offers at least its nominal wage).
                if (affordable_ceiling > 0) {
                    const int64_t floor_cap = std::max(
                        role.reference_wage_per_day, affordable_ceiling);
                    floor = std::min(floor, floor_cap);
                }
                int64_t current = _building_role_contract_wage[index] > 0
                    ? _building_role_contract_wage[index] : role.reference_wage_per_day;
                int64_t next = role.reference_wage_per_day;
                if (role.wage_policy == 2) {
                    int64_t desired = std::max(floor, local_average);
                    // Damping also caps the target the wage chases toward, so an
                    // inflated local-average signal cannot drag wages past the
                    // employer's affordability either.
                    if (affordable_ceiling > 0) {
                        const int64_t desired_cap = std::max(
                            role.reference_wage_per_day, affordable_ceiling);
                        desired = std::min(desired, desired_cap);
                    }
                    if (desired > current) {
                        const int64_t cap = std::max<int64_t>(1, mul_div_sat(
                            current, saturating_mul(_wage_max_rise_q16_per_day,
                                                    std::max(1, _epoch_days),
                                                    _saturation_count),
                            Q16_ONE, _saturation_count));
                        next = std::min(desired, saturating_add(
                            current, cap, _saturation_count));
                    } else {
                        const int64_t cap = mul_div_sat(
                            current, saturating_mul(_wage_max_fall_q16_per_day,
                                                    std::max(1, _epoch_days),
                                                    _saturation_count),
                            Q16_ONE, _saturation_count);
                        next = std::max(desired, saturating_sub(
                            current, cap, _saturation_count));
                    }
                    next = std::max(next, floor);
                } else if (role.wage_policy == 1) {
                    next = role.reference_wage_per_day;
                } else {
                    next = 0;
                }
                _building_role_contract_wage[index] = next;
                _building_role_base_living_cost[index] = general_cost;
                _building_role_living_cost[index] = role_cost;
                _building_role_local_average_wage[index] = local_average;
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
                                std::max(1, _epoch_days), _saturation_count));
    for (int32_t signal = _labor_signals.cell_offsets[cell];
         signal < _labor_signals.cell_offsets[cell + 1]; ++signal) {
        const int32_t profession = _labor_signals.profession_ids[signal];
        int64_t jobs = 0;
        int64_t due = 0;
        int64_t paid = 0;
        for (int32_t g = _building_cell_offsets[cell];
             g < _building_cell_offsets[cell + 1]; ++g) {
            const BuildingGroup &group = _buildings[g];
            const BuildingType &type = _building_types[group.type_id];
            for (int32_t r = 0; r < type.employee_count; ++r) {
                const JobRole &role = _building_employee_roles[type.employee_begin + r];
                if (role.profession_id != profession) continue;
                const int32_t index = group.employee_fill_begin + r;
                jobs = saturating_add(jobs, saturating_mul(
                    _building_employee_filled[index], std::max(1, _epoch_days),
                    _saturation_count), _saturation_count);
                due = saturating_add(due, _building_role_base_wage_due[index],
                                     _saturation_count);
                paid = saturating_add(paid, _building_role_base_wage_paid[index],
                                      _saturation_count);
            }
        }
        if (jobs > 0) {
            const int64_t observed_contract = due / jobs;
            const int64_t observed_paid = paid / jobs;
            auto ema = [&](int64_t previous, int64_t observed) {
                if (previous <= 0) return observed;
                return saturating_add(previous, mul_div_sat(
                    saturating_sub(observed, previous, _saturation_count),
                    alpha, Q16_ONE, _saturation_count),
                    _saturation_count);
            };
            _labor_signals.contract_wage_ema[signal] =
                ema(_labor_signals.contract_wage_ema[signal], observed_contract);
            _labor_signals.paid_wage_ema[signal] =
                ema(_labor_signals.paid_wage_ema[signal], observed_paid);
            _labor_signals.job_days[signal] = jobs;
            _labor_signals.pay_ratio_q16[signal] = static_cast<int32_t>(
                std::clamp<int64_t>(mul_div_sat(paid, Q16_ONE,
                    std::max<int64_t>(1, due), _saturation_count), 0, Q16_ONE));
            ++_labor_signal_updates;
        }
    }
    _labor_signal_ms += elapsed_ms(started);
}

bool NativeEconomyRuntime::run_building_employment_cell(
        int32_t cell, bool allow_owner_job_reallocation, std::string &error) {
    if (!prepare_cell_wages(cell, error)) return false;
    // demand[p] = profession p 本周期 employee 目标之和；fill[p] = 夹紧后在岗
    // employee 之和。二者在 A1 两步逻辑中被 std::fill 重置复用（见下）。
    thread_local std::vector<int64_t> demand;
    thread_local std::vector<int64_t> fill;
    auto employment_utilization_q16 = [&](const BuildingGroup &group) {
        const int32_t index = static_cast<int32_t>(&group - _buildings.data());
        int64_t utilization = index >= 0 && index < static_cast<int32_t>(
                _building_planned_capacity_before_climate_q16.size())
            ? _building_planned_capacity_before_climate_q16[index]
            : group.planned_utilization_q16;
        if (group.operating_state == 2) {
            if (index >= 0 && index < static_cast<int32_t>(
                    _building_recovery_probe_capacity_q16.size()))
                utilization = std::min(utilization,
                    _building_recovery_probe_capacity_q16[index]);
        }
        return std::clamp<int64_t>(utilization, 0, Q16_ONE);
    };
    const int32_t professions = static_cast<int32_t>(_profession_ids.size());
    demand.assign(professions, 0);
    fill.assign(professions, 0);
    const int32_t first = _building_cell_offsets.size() == static_cast<size_t>(_cell_count + 1)
        ? _building_cell_offsets[cell] : 0;
    const int32_t last = _building_cell_offsets.size() == static_cast<size_t>(_cell_count + 1)
        ? _building_cell_offsets[cell + 1] : 0;
    auto planned_role_demand = [&](const BuildingGroup &group, const JobRole &role) {
        const int64_t full = saturating_mul(group.count, role.slots_per_building,
                                            _saturation_count);
        const int64_t utilization = employment_utilization_q16(group);
        int64_t scaled = mul_div_sat(full, utilization, Q16_ONE,
                                     _saturation_count);
        if (scaled == 0 && full > 0 && utilization > 0) scaled = 1;
        return scaled;
    };
    const bool trace_detail = trace_detail_for_cell(cell);
    // A1 迁移会 allocate/release slot，裸 slot id 会失效；trace 快照改存稳定
    // handle，事件生成时用 valid_handle 解析回当前 slot（失效则跳过该 leg）。
    thread_local std::vector<uint64_t> trace_handles;
    thread_local std::vector<int64_t> trace_owner_before;
    thread_local std::vector<int64_t> trace_employee_before;
    trace_handles.clear(); trace_owner_before.clear(); trace_employee_before.clear();
    if (trace_detail) {
        _population.for_each_in_cell(cell, [&](int32_t slot) {
            trace_handles.push_back(_population.handle_for_slot(slot));
            trace_owner_before.push_back(_population.owner_employed[slot]);
            trace_employee_before.push_back(_population.employee_employed[slot]);
        });
    }
    // ================================================================
    // A1 路径：失业池增量就业（统一净增量迁移，用户 2026-07-16 拍板）
    // ----------------------------------------------------------------
    // 不变量（employment 结束时对每个非 merchant、非 unemployed 的
    //   profession|eth slot 成立）：owner_employed + employee_employed
    //   == population，即在岗 slot 里没有闲置人口；任何未被任何建筑雇佣
    //   的人都真实迁往 unemployed|eth slot（独立 cohort 身份 + plan_unemployed，
    //   消费退化为 survival food → satisfaction 掉 → starvation 自然死上升，
    //   失业惩罚由 demography 自动施加，无需硬编死亡率）。
    //
    // 两步结构（数学上等价于"消失清理 + 建筑驱动裁员 + 优先级招人"三阶段
    //   合并，但 owner/employee 在同一 slot 内自然竞争 population，无需在阶段
    //   间显式传递 slot 剩余容量）：
    //   [第1步 析出] 每个在岗 slot 按本周期 planned_utilization 目标算
    //     desired_working；surplus = population - desired_working 的部分迁往
    //     unemployed|eth。消失/不可用建筑目标为 0，其在岗人口自然全部进池。
    //     执行后所有活跃 group 的 filled_* 被夹到"目标或更少"，多余人口全在池中。
    //   [第2步 招人] unemployed 池此刻汇集了各 eth 的全部失业者（含本周期刚
    //     进池的 + 历史长期失业的）。活跃 group 按优先级
    //     (realized_profit_margin_q16 desc, planned_utilization_q16 desc,
    //      group_index asc) 跨建筑类型排序，依次把 filled_owner/filled_employee
    //     补到目标，从 unemployed|eth 真实迁回对应 profession|eth slot（受池
    //     可用量约束）。低优先级/亏损 group 招不满即长期缺人 → "先喂最赚钱"。
    //     招人跨 profession：失业 farmer 可被招为 miner（profession 是可变就业
    //     状态，架构决策4）。
    //
    // 关键工程约束：move_cohort_population 会 allocate/release slot，破坏
    //   for_each_in_cell 的页链迭代器。故所有迁移都"先只读遍历收集计划到
    //   thread_local 缓冲，遍历结束后再统一执行迁移"（学 ensure_merchant_invariant）。
    //   Route B: 商栈(merchant_post) owner 现在参与就业分配——merchant slot 的
    //   owner_employed 计入 filled_owner、纳入析出/聚合；但保底每有人 cell 至少
    //   1 个 merchant 不被裁(护住 rebuild_merchant_ranges 做市索引不变量)。
    //   emp_capacity 第一遍仍跳过 merchant(商人不做 employee，仅 owner 岗)。
    // ================================================================
    // The same authoritative release/hire path also owns cells whose last
    // building was removed. Empty ranges must release every non-merchant
    // profession cohort into unemployed instead of leaving an idle profession.
    {
        const int32_t n_eth = static_cast<int32_t>(_ethnicity_ids.size());

        // ---- 目标计算：本周期各 group 期望的 owner / 各 role employee ----
        // 用 thread_local 缓冲避免每 cell 分配。
        thread_local std::vector<int64_t> group_owner_target;      // 每 group owner 目标
        group_owner_target.assign(static_cast<size_t>(last - first), 0);
        // profession 级 employee 目标 / 在岗（跨 eth 聚合，沿用旧 employee 语义）。
        std::fill(demand.begin(), demand.end(), 0);   // demand[p] = Σ planned_role_demand
        std::fill(fill.begin(), fill.end(), 0);       // fill[p]   = Σ 当前在岗 employee
        for (int32_t g = first; g < last; ++g) {
            BuildingGroup &group = _buildings[g];
            if (group.cell != cell) continue;
            const bool active = group.count > 0 && group.operating_state != 1 &&
                                 building_available(cell, group.type_id, true);
            const BuildingType &type = _building_types[group.type_id];
            // owner 目标：不可用/count<=0 → 0（其在岗人口将全部进池）。
            const bool suspended = group.count > 0 && group.operating_state == 1 &&
                                   building_available(cell, group.type_id, true);
            const int64_t owner_target = (active || suspended)
                ? planned_owner_demand(group, _saturation_count) : 0;
            group_owner_target[g - first] = owner_target;
            for (int32_t r = 0; r < type.employee_count; ++r) {
                const JobRole &role = _building_employee_roles[type.employee_begin + r];
                const int32_t p = role.profession_id;
                const int64_t role_target = active ? planned_role_demand(group, role) : 0;
                demand[p] = saturating_add(demand[p], role_target, _saturation_count);
                const int32_t fi = group.employee_fill_begin + r;
                fill[p] = saturating_add(fill[p],
                    std::max<int64_t>(0, _building_employee_filled[fi]), _saturation_count);
            }
        }
        // Reuse the same profitability/utilization priority for retaining incumbent
        // owners and for hiring replacements. Population can shrink after the prior
        // employment pass, so per-group target clamps alone are insufficient when
        // several groups share one owner signature.
        thread_local std::vector<int32_t> hire_order;
        thread_local std::vector<uint8_t> labor_survival_priority;
        thread_local std::vector<int32_t> labor_shortage_priority_q16;
        thread_local std::vector<int64_t> labor_tax_retention_q16;
        // Composite satisfaction of the group's owner cohort as of the previous
        // epoch. Employment runs before the market pass, so this is always last
        // epoch's published value and never introduces a same-epoch cycle.
        thread_local std::vector<int32_t> labor_owner_satisfaction_q16;
        const bool labor_income_tax_active =
            (_epoch_active_tax_mask & static_cast<uint8_t>(
                1U << NativeCountryRuntime::TAX_INCOME)) != 0;
        hire_order.clear();
        labor_survival_priority.assign(static_cast<size_t>(last - first), uint8_t{0});
        labor_shortage_priority_q16.assign(static_cast<size_t>(last - first), 0);
        labor_tax_retention_q16.assign(static_cast<size_t>(last - first),
                                       Q16_ONE);
        labor_owner_satisfaction_q16.assign(static_cast<size_t>(last - first), 0);
        for (int32_t g = first; g < last; ++g) {
            BuildingGroup &group = _buildings[g];
            if (group.cell != cell || group.count <= 0 ||
                !building_available(cell, group.type_id, true) ||
                group_owner_target[g - first] <= 0) continue;
            const BuildingType &type = _building_types[group.type_id];
            const int32_t market = _market.cell_to_market[cell];
            for (int32_t i = 0; i < type.output_count; ++i) {
                const int32_t good = _building_outputs[type.output_begin + i].good_id;
                const int64_t market_index = _market.index(market, good);
                int64_t shortage_q16 = _market.last_shortage_q16[market_index];
                const int32_t signal = market_signal_index(cell, good);
                if (signal >= 0) {
                    const int64_t business =
                        _market_signals.business_demand_ema[signal];
                    const int64_t withdrawal =
                        _market_signals.realized_withdrawal_ema[signal];
                    if (business > withdrawal && business > 0) {
                        const int64_t business_gap_q16 = std::min<int64_t>(
                            Q16_ONE, mul_div_sat(business - withdrawal, Q16_ONE,
                                business, _saturation_count));
                        shortage_q16 = std::max(shortage_q16, business_gap_q16);
                    }
                }
                const size_t local_group = static_cast<size_t>(g - first);
                labor_shortage_priority_q16[local_group] = static_cast<int32_t>(
                    std::max<int64_t>(labor_shortage_priority_q16[local_group],
                        shortage_q16));
                if (_survival_food_good_mask[good] != 0) {
                    const int64_t reserve = signal >= 0 && signal <
                            static_cast<int32_t>(_production_input_reserve.size())
                        ? _production_input_reserve[signal] : 0;
                    const int64_t household_stock = std::max<int64_t>(
                        0, _market.stock[market_index] - reserve);
                    if (household_stock <= 1 || shortage_q16 >= Q16_ONE / 8) {
                        labor_survival_priority[local_group] = 1;
                    }
                }
            }
            if (labor_income_tax_active)
                labor_tax_retention_q16[static_cast<size_t>(g - first)] =
                    projected_employee_tax_retention_q16(
                        group, _saturation_count);
            if (group.owner_signature_id >= 0) {
                const int32_t owner_slot = _population.find_signature(
                    cell, static_cast<uint32_t>(group.owner_signature_id));
                if (owner_slot >= 0)
                    labor_owner_satisfaction_q16[static_cast<size_t>(g - first)] =
                        _population.composite_satisfaction[owner_slot];
            }
            hire_order.push_back(g);
        }
        std::stable_sort(hire_order.begin(), hire_order.end(),
                         [&](int32_t a, int32_t b) {
            const BuildingGroup &ga = _buildings[a];
            const BuildingGroup &gb = _buildings[b];
            if ((ga.operating_state == 0) != (gb.operating_state == 0))
                return ga.operating_state == 0;
            const size_t local_a = static_cast<size_t>(a - first);
            const size_t local_b = static_cast<size_t>(b - first);
            if (labor_survival_priority[local_a] != labor_survival_priority[local_b])
                return labor_survival_priority[local_a] > labor_survival_priority[local_b];
            if (labor_shortage_priority_q16[local_a] != labor_shortage_priority_q16[local_b])
                return labor_shortage_priority_q16[local_a] >
                    labor_shortage_priority_q16[local_b];
            if (labor_income_tax_active &&
                    labor_tax_retention_q16[local_a] !=
                    labor_tax_retention_q16[local_b])
                return labor_tax_retention_q16[local_a] >
                    labor_tax_retention_q16[local_b];
            if (ga.realized_profit_margin_q16 != gb.realized_profit_margin_q16)
                return ga.realized_profit_margin_q16 > gb.realized_profit_margin_q16;
            if (ga.planned_utilization_q16 != gb.planned_utilization_q16)
                return ga.planned_utilization_q16 > gb.planned_utilization_q16;
            // Equally profitable employers are separated by how well their owner
            // class actually lived last epoch, so labour drifts toward the
            // trades that visibly pay off.
            if (labor_owner_satisfaction_q16[local_a] !=
                    labor_owner_satisfaction_q16[local_b])
                return labor_owner_satisfaction_q16[local_a] >
                    labor_owner_satisfaction_q16[local_b];
            return a < b;
        });

        // ---- 第1步 析出：把超出目标的在岗人口迁往 unemployed|eth ----
        // (a) 先把每个 group 的 filled_owner / _building_employee_filled 夹到目标
        //     （裁员：filled > target 的差额释放）。employee 按 profession 稳定序
        //     在多 group 间削减（同 profession 聚合，逐 group 削到 target）。
        // (b) 再按 profession|eth slot 聚合"该 slot 应保留的在岗人口"，把
        //     population - retained 迁往 unemployed|eth。
        //
        // owner 侧夹紧（建筑驱动：每 group 独立按自身 filled-target 裁）。
        for (int32_t g = first; g < last; ++g) {
            BuildingGroup &group = _buildings[g];
            if (group.cell != cell || group.count <= 0) continue;
            if (group.filled_owner > group_owner_target[g - first]) {
                group.filled_owner = group_owner_target[g - first];
            }
        }
        // A cohort can lose population during household demography while its
        // building-group fill counters still describe the previous epoch. Clamp
        // the aggregate fill for each owner signature to the live cohort population
        // before deriving retained employment. Higher-priority groups retain their
        // incumbents first; any released target is eligible for normal hiring below.
        thread_local std::vector<int64_t> sig_owner_remaining;
        sig_owner_remaining.assign(_signatures.size(), 0);
        _population.for_each_in_cell(cell, [&](int32_t slot) {
            const uint32_t sig = _population.signature_id[slot];
            if (sig >= sig_owner_remaining.size()) return;
            sig_owner_remaining[sig] = saturating_add(
                sig_owner_remaining[sig],
                std::max<int64_t>(0, _population.population[slot]), _saturation_count);
        });
        for (int32_t g : hire_order) {
            BuildingGroup &group = _buildings[g];
            if (group.owner_signature_id < 0 ||
                group.owner_signature_id >= static_cast<int32_t>(sig_owner_remaining.size())) {
                group.filled_owner = 0;
                continue;
            }
            int64_t &remaining = sig_owner_remaining[group.owner_signature_id];
            group.filled_owner = std::min(std::max<int64_t>(0, group.filled_owner), remaining);
            remaining -= group.filled_owner;
        }
        // Family ownership is a sparse overlay on the aggregated building
        // group. Family-owned owner slots can only be filled by local members
        // of that same family; anonymous buildings use only anonymous people.
        clamp_family_owner_employment_for_cell(cell);
        // employee 侧夹紧：profession p 若 Σfilled > Σtarget，按 group 稳定序
        // 从后往前削减各 role fill 到 demand。用 remaining[p] 追踪该 profession
        // 允许保留的总在岗数，逐 group 分配 min(role_filled, remaining)。
        thread_local std::vector<int64_t> emp_remaining;   // 每 profession 允许保留的在岗上限
        emp_remaining.assign(professions, 0);
        for (int32_t p = 0; p < professions; ++p) {
            emp_remaining[p] = std::min(fill[p], demand[p]);   // 裁员后保留 = min(在岗, 目标)
        }
        std::fill(fill.begin(), fill.end(), 0);   // 重算为夹紧后的实际在岗
        for (int32_t g = first; g < last; ++g) {
            BuildingGroup &group = _buildings[g];
            if (group.cell != cell || group.count <= 0) continue;
            const BuildingType &type = _building_types[group.type_id];
            for (int32_t r = 0; r < type.employee_count; ++r) {
                const JobRole &role = _building_employee_roles[type.employee_begin + r];
                const int32_t p = role.profession_id;
                const int32_t fi = group.employee_fill_begin + r;
                const int64_t cur = std::max<int64_t>(0, _building_employee_filled[fi]);
                const int64_t keep = std::min(cur, emp_remaining[p]);
                _building_employee_filled[fi] = keep;
                emp_remaining[p] -= keep;
                fill[p] = saturating_add(fill[p], keep, _saturation_count);
            }
        }

        // (b) 计算每个 profession|eth slot 夹紧后应保留的在岗人口，收集迁往池的差额。
        //     owner_retained[slot] = 该 signature 各 group filled_owner 之和；
        //     employee_retained[slot] = 该 profession 在岗 employee 按 slot 稳定序摊派。
        //     retained = owner_retained + employee_retained（A1: <= population）。
        //     surplus = population - retained → 迁往 unemployed|eth。
        //
        // 先按 signature 聚合 owner filled（owner 绑定精确 signature）。
        thread_local std::vector<int64_t> sig_owner_retained;   // 按 signature id
        sig_owner_retained.assign(_signatures.size(), 0);
        for (int32_t g = first; g < last; ++g) {
            BuildingGroup &group = _buildings[g];
            if (group.cell != cell || group.count <= 0) continue;
            if (group.owner_signature_id < 0 ||
                group.owner_signature_id >= static_cast<int32_t>(_signatures.size())) continue;
            sig_owner_retained[group.owner_signature_id] = saturating_add(
                sig_owner_retained[group.owner_signature_id],
                std::max<int64_t>(0, group.filled_owner), _saturation_count);
        }
        // employee 在岗按 profession 稳定序摊派到各 slot（同 profession 的多 eth
        // slot 按 signature_id 升序，用 cohort 可容纳量比例摊派，前缀和保确定）。
        thread_local std::vector<int64_t> emp_prefix;
        thread_local std::vector<int64_t> emp_distributed;
        thread_local std::vector<int64_t> emp_capacity;   // 每 profession 各 slot 可当 employee 的容量之和
        emp_prefix.assign(professions, 0);
        emp_distributed.assign(professions, 0);
        emp_capacity.assign(professions, 0);
        // 第一遍：算每 profession 的 employee 容量总量 = Σ(population - owner_retained)。
        _population.for_each_in_cell(cell, [&](int32_t slot) {
            if (is_merchant_slot(slot)) return;
            const int32_t sig = static_cast<int32_t>(_population.signature_id[slot]);
            const int32_t p = _signatures[sig].profession_id;
            if (p == _unemployed_profession_id) return;
            const int64_t owner_here = std::min(sig_owner_retained[sig],
                std::max<int64_t>(0, _population.population[slot]));
            const int64_t cap = std::max<int64_t>(0, _population.population[slot] - owner_here);
            emp_capacity[p] = saturating_add(emp_capacity[p], cap, _saturation_count);
        });
        // 第二遍：只读收集每个 slot 的 surplus（迁往池）到缓冲，遍历后统一迁移。
        // owner_retained 按 signature 在多 slot 间也需稳定序摊派（同 signature 通常
        // 只有一个 slot；多页时按遍历序，前缀和保确定）。
        thread_local std::vector<int64_t> sig_owner_distributed;
        sig_owner_distributed.assign(_signatures.size(), 0);
        thread_local std::vector<int32_t> shed_source_slots;   // surplus 来源 slot
        thread_local std::vector<int32_t> shed_dest_eth;       // 对应 eth（→ unemployed|eth）
        thread_local std::vector<int64_t> shed_pop;            // surplus 人数
        shed_source_slots.clear(); shed_dest_eth.clear(); shed_pop.clear();
        // Route B: merchant slots are no longer skipped wholesale. A merchant
        // slot may now carry a merchant-post owner (sig_owner_retained>0) that
        // must be aggregated/right-sized like any other owner. But the market
        // maker invariant (rebuild_merchant_ranges requires >=1 merchant per
        // populated cell) forbids shedding the last merchant, so a merchant
        // slot keeps a floor of max(owner_here, 1) retained. Non-merchant slots
        // are unchanged.
        _population.for_each_in_cell(cell, [&](int32_t slot) {
            const int32_t sig = static_cast<int32_t>(_population.signature_id[slot]);
            const int32_t p = _signatures[sig].profession_id;
            const int32_t eth = _signatures[sig].ethnicity_id;
            const int64_t pop = std::max<int64_t>(0, _population.population[slot]);
            if (p == _unemployed_profession_id) {
                // 失业 slot：本步不动（它是池，招人步骤才从中迁出）。
                return;
            }
            const bool merchant_here = is_merchant_slot(slot);
            // owner 在本 slot 的份额（同 signature 多 slot 时稳定序摊派）。
            const int64_t owner_here = std::min(
                std::max<int64_t>(0, sig_owner_retained[sig] - sig_owner_distributed[sig]), pop);
            sig_owner_distributed[sig] = saturating_add(sig_owner_distributed[sig],
                                                        owner_here, _saturation_count);
            if (merchant_here) {
                // 商人 slot 不做 employee（仅 owner 岗）；保底 1 个做市商不裁。
                const int64_t retained = std::min(pop,
                    std::max<int64_t>(owner_here, pop > 0 ? 1 : 0));
                _population.owner_employed[slot] = owner_here;
                _population.employee_employed[slot] = 0;
                const int64_t surplus = std::max<int64_t>(0, pop - retained);
                if (surplus > 0 && eth >= 0 && eth < n_eth) {
                    shed_source_slots.push_back(slot);
                    shed_dest_eth.push_back(eth);
                    shed_pop.push_back(surplus);
                }
                return;
            }
            // employee 在本 slot 的份额：按容量比例摊派 fill[p]。
            const int64_t cap_here = std::max<int64_t>(0, pop - owner_here);
            emp_prefix[p] = saturating_add(emp_prefix[p], cap_here, _saturation_count);
            const int64_t emp_next = emp_capacity[p] > 0
                ? mul_div_sat(fill[p], emp_prefix[p], emp_capacity[p], _saturation_count) : 0;
            const int64_t emp_here = std::max<int64_t>(0, emp_next - emp_distributed[p]);
            emp_distributed[p] = emp_next;
            const int64_t retained = std::min(pop, saturating_add(owner_here, emp_here,
                                                                   _saturation_count));
            _population.owner_employed[slot] = owner_here;
            _population.employee_employed[slot] = std::min(emp_here,
                std::max<int64_t>(0, pop - owner_here));
            const int64_t surplus = std::max<int64_t>(0, pop - retained);
            if (surplus > 0 && eth >= 0 && eth < n_eth) {
                shed_source_slots.push_back(slot);
                shed_dest_eth.push_back(eth);
                shed_pop.push_back(surplus);
            }
        });
        // 遍历外执行析出迁移（在岗 profession|eth → unemployed|eth）。
        for (size_t i = 0; i < shed_source_slots.size(); ++i) {
            const int32_t src = shed_source_slots[i];
            const int32_t dest_sig = unemployed_signature_for_ethnicity(shed_dest_eth[i]);
            if (dest_sig < 0) continue;   // 无 unemployed signature（向后兼容）：留原 slot。
            if (dest_sig == static_cast<int32_t>(_population.signature_id[src])) continue;
            bool drained = false;
            if (!move_cohort_population(src, cell, dest_sig, shed_pop[i], error, &drained)) {
                return false;
            }
        }

        // ---- 第2步 招人：按优先级从 unemployed 池增量迁回 ----
        // 优先级键：(realized_profit_margin_q16 desc, planned_utilization_q16 desc,
        //            group_index asc)。排序粒度=跨 BuildingGroup（跨建筑类型）；
        // 同 type_id+同 owner_signature 聚合的组内盈利/利用率相同，组内不排（稳定序）。
        // 池可用量：按 eth 缓存各 unemployed|eth slot 的当前人口与 slot id。
        // 招 owner 需精确 eth（group.owner_signature 的 eth）；招 employee 可跨 eth
        // （按 eth 升序取池，保确定）。招人在遍历外逐 group 执行迁移，每次迁移后
        // 重新定位池 slot（可能被 drain 释放）。
        auto pool_slot_for_eth = [&](int32_t eth) -> int32_t {
            const int32_t sig = unemployed_signature_for_ethnicity(eth);
            if (sig < 0) return -1;
            return _population.find_signature(cell, static_cast<uint32_t>(sig));
        };
        for (size_t oi = 0; oi < hire_order.size(); ++oi) {
            const int32_t g = hire_order[oi];
            BuildingGroup &group = _buildings[g];
            const BuildingType &type = _building_types[group.type_id];
            // --- owner 招募（精确 eth = owner_signature 的 eth）---
            const int64_t owner_target = group_owner_target[g - first];
            int64_t owner_need = std::max<int64_t>(0, owner_target - group.filled_owner);
            if (owner_need > 0 && group.owner_signature_id >= 0 &&
                group.owner_signature_id < static_cast<int32_t>(_signatures.size())) {
                const int32_t owner_eth = _signatures[group.owner_signature_id].ethnicity_id;
                const int32_t pool = pool_slot_for_eth(owner_eth);
                if (pool >= 0) {
                    const int64_t avail = std::max<int64_t>(0, _population.population[pool]);
                    const int64_t take = std::min(owner_need, avail);
                    if (take > 0 &&
                        group.owner_signature_id != static_cast<int32_t>(
                            _population.signature_id[pool])) {
                        bool drained = false;
                        const uint64_t preferred_family =
                            preferred_family_for_cohort(pool, 1, 0,
                                _signatures[group.owner_signature_id].profession_id);
                        if (!move_cohort_population(pool, cell, group.owner_signature_id,
                                                    take, error, &drained,
                                                    preferred_family)) {
                            return false;
                        }
                        group.filled_owner = saturating_add(group.filled_owner, take,
                                                            _saturation_count);
                        // 迁回的人在其目标 profession|eth slot 记为在岗 owner。
                        const int32_t dest = _population.find_signature(
                            cell, static_cast<uint32_t>(group.owner_signature_id));
                        if (dest >= 0) {
                            _population.owner_employed[dest] = saturating_add(
                                _population.owner_employed[dest], take, _saturation_count);
                        }
                    }
                }
            }
            if (group.operating_state == 1) continue;
            // --- employee 招募（每 role，profession 匹配，跨 eth 按升序取池）---
            for (int32_t r = 0; r < type.employee_count; ++r) {
                const JobRole &role = _building_employee_roles[type.employee_begin + r];
                const int32_t p = role.profession_id;
                if (!profession_available(cell, p, true)) continue;
                const int32_t fi = group.employee_fill_begin + r;
                const int64_t role_target = planned_role_demand(group, role);
                int64_t need = std::max<int64_t>(0,
                    role_target - std::max<int64_t>(0, _building_employee_filled[fi]));
                if (need <= 0) continue;
                // 目标 slot 按具体 eth 定（跨 eth 招募，按 eth 升序稳定取池）。
                for (int32_t eth = 0; eth < n_eth && need > 0; ++eth) {
                    const int32_t pool = pool_slot_for_eth(eth);
                    if (pool < 0) continue;
                    const int64_t avail = std::max<int64_t>(0, _population.population[pool]);
                    if (avail <= 0) continue;
                    const int32_t target_sig = signature_for_profession_ethnicity(p, eth);
                    if (target_sig < 0) continue;
                    if (target_sig == static_cast<int32_t>(_population.signature_id[pool]))
                        continue;
                    const int64_t take = std::min(need, avail);
                    if (take <= 0) continue;
                    bool drained = false;
                    const uint64_t preferred_family =
                        preferred_family_for_cohort(pool, 1, 0, p);
                    if (!move_cohort_population(pool, cell, target_sig, take, error,
                                                &drained, preferred_family)) {
                        return false;
                    }
                    _building_employee_filled[fi] = saturating_add(
                        _building_employee_filled[fi], take, _saturation_count);
                    const int32_t dest = _population.find_signature(
                        cell, static_cast<uint32_t>(target_sig));
                    if (dest >= 0) {
                        _population.employee_employed[dest] = saturating_add(
                            _population.employee_employed[dest], take, _saturation_count);
                    }
                    need -= take;
                }
            }
        }

        if (allow_owner_job_reallocation) {
        // Unemployed hiring remains authoritative and runs first. Remaining
        // ACTIVE owner vacancies may then attract one incumbent owner from a
        // lower-income ACTIVE group of the same ethnicity. Targets and sources
        // are snapshotted before matching so a group cannot chain through
        // several jobs in the same employment period.
        thread_local std::vector<int64_t> projected_owner_income;
        thread_local std::vector<int32_t> owner_job_targets;
        thread_local std::vector<int32_t> owner_job_sources;
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
        employee_owner_sources.clear();
        owner_job_group_used.assign(static_cast<size_t>(last - first), uint8_t{0});
        int64_t local_merchant_population = 0;
        _population.for_each_in_cell(cell, [&](int32_t slot) {
            if (is_merchant_slot(slot)) {
                local_merchant_population = saturating_add(
                    local_merchant_population,
                    std::max<int64_t>(0, _population.population[slot]),
                    _saturation_count);
            }
        });
        for (int32_t g = first; g < last; ++g) {
            const BuildingGroup &group = _buildings[g];
            if (group.cell != cell || group.count <= 0 ||
                group.operating_state == 1 ||
                !building_available(cell, group.type_id, true)) continue;
            const BuildingType &type = _building_types[group.type_id];
            if (group.owner_signature_id < 0 ||
                group.owner_signature_id >= static_cast<int32_t>(_signatures.size())) continue;
            const int64_t income = projected_owner_income_per_day(
                group, _saturation_count);
            projected_owner_income[g - first] = income;
            const int64_t owner_target = group_owner_target[g - first];
            if (type.kind != 2 && group.filled_owner < owner_target) {
                if (income > 0) owner_job_targets.push_back(g);
            }
            // Service owners may be sources. In particular, surplus merchant
            // post owners can take a materially better owner job; the matching
            // loop below still protects the final merchant in the cell.
            if (group.filled_owner > 0 && owner_target > 0) {
                const int32_t source_slot = _population.find_signature(
                    cell, static_cast<uint32_t>(group.owner_signature_id));
                if (source_slot >= 0 && _population.owner_employed[source_slot] > 0) {
                    owner_job_sources.push_back(g);
                }
            }
            for (int32_t r = 0; r < type.employee_count; ++r) {
                const int32_t fill_index = group.employee_fill_begin + r;
                if (_building_employee_filled[fill_index] <= 0) continue;
                const JobRole &role = _building_employee_roles[type.employee_begin + r];
                const int64_t gross_income = fill_index >= 0 && fill_index <
                        static_cast<int32_t>(_building_role_contract_wage.size())
                    ? _building_role_contract_wage[fill_index]
                    : role.reference_wage_per_day;
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
        std::stable_sort(owner_job_sources.begin(), owner_job_sources.end(),
                         [&](int32_t a, int32_t b) {
            const int64_t income_a = projected_owner_income[a - first];
            const int64_t income_b = projected_owner_income[b - first];
            return income_a != income_b ? income_a < income_b : a < b;
        });
        std::stable_sort(employee_owner_sources.begin(), employee_owner_sources.end(),
                         [](const EmployeeOwnerSource &a,
                            const EmployeeOwnerSource &b) {
            if (a.income != b.income) return a.income < b.income;
            if (a.group != b.group) return a.group < b.group;
            return a.role < b.role;
        });
        for (int32_t target_group_index : owner_job_targets) {
            if (owner_job_group_used[target_group_index - first] != 0) continue;
            BuildingGroup &target_group = _buildings[target_group_index];
            if (target_group.filled_owner >=
                    group_owner_target[target_group_index - first]) continue;
            const Signature &target_signature =
                _signatures[target_group.owner_signature_id];
            const int64_t target_income =
                projected_owner_income[target_group_index - first];
            int32_t source_group_index = -1;
            int32_t source_slot = -1;
            for (int32_t candidate : owner_job_sources) {
                if (candidate == target_group_index ||
                    owner_job_group_used[candidate - first] != 0) continue;
                const BuildingGroup &source_group = _buildings[candidate];
                const Signature &source_signature =
                    _signatures[source_group.owner_signature_id];
                const int64_t source_income =
                    projected_owner_income[candidate - first];
                const int64_t required_target = saturating_add(
                    source_income, mul_div_sat(source_income, Q16_ONE / 8,
                        Q16_ONE, _saturation_count), _saturation_count);
                if (source_signature.ethnicity_id != target_signature.ethnicity_id ||
                    target_income < required_target) continue;
                const int32_t slot = _population.find_signature(
                    cell, static_cast<uint32_t>(source_group.owner_signature_id));
                if (slot < 0 || _population.owner_employed[slot] <= 0) continue;
                if (source_signature.profession_id == _merchant_profession_id &&
                    local_merchant_population <= 1) continue;
                source_group_index = candidate;
                source_slot = slot;
                break;
            }
            if (source_group_index >= 0) {
                BuildingGroup &source_group = _buildings[source_group_index];
                const Signature &source_signature =
                    _signatures[source_group.owner_signature_id];
                if (source_signature.profession_id != target_signature.profession_id) {
                    bool source_drained = false;
                    const uint64_t preferred_family =
                        preferred_family_for_cohort(source_slot, 1, 0,
                            target_signature.profession_id);
                    if (!move_cohort_population(source_slot, cell,
                            target_group.owner_signature_id, 1, error,
                            &source_drained, preferred_family)) {
                        return false;
                    }
                    if (!source_drained) {
                        _population.owner_employed[source_slot] = std::max<int64_t>(
                            0, _population.owner_employed[source_slot] - 1);
                    }
                    const int32_t destination = _population.find_signature(
                        cell, static_cast<uint32_t>(target_group.owner_signature_id));
                    if (destination < 0) {
                        error = "owner_job_reallocation_destination_missing";
                        return false;
                    }
                    _population.owner_employed[destination] = saturating_add(
                        _population.owner_employed[destination], 1,
                        _saturation_count);
                    if (source_signature.profession_id == _merchant_profession_id) {
                        local_merchant_population = std::max<int64_t>(
                            0, local_merchant_population - 1);
                    }
                    ++_building_owner_job_profession_changes;
                }
                source_group.filled_owner -= 1;
                target_group.filled_owner = saturating_add(
                    target_group.filled_owner, 1, _saturation_count);
                owner_job_group_used[source_group_index - first] = 1;
                owner_job_group_used[target_group_index - first] = 1;
                ++_building_owner_job_reallocations;
                continue;
            }

            // If no lower-income owner is available, an incumbent employee may
            // take the materially better owner opening. This closes the price-to-
            // labor path when unemployment is zero: high realizable output prices
            // raise projected owner income and can attract labor out of a lower-
            // wage industry. Preserve ethnicity and move at most one person per
            // source/target group in an employment period.
            for (const EmployeeOwnerSource &candidate : employee_owner_sources) {
                if (owner_job_group_used[candidate.group - first] != 0 ||
                    _building_employee_filled[candidate.fill_index] <= 0) continue;
                const int64_t required_target = saturating_add(candidate.income,
                    mul_div_sat(candidate.income, Q16_ONE / 8, Q16_ONE,
                                _saturation_count), _saturation_count);
                if (target_income < required_target) continue;
                const int32_t source_signature_id =
                    signature_for_profession_ethnicity(candidate.profession,
                        target_signature.ethnicity_id);
                if (source_signature_id < 0) continue;
                const int32_t employee_slot = _population.find_signature(
                    cell, static_cast<uint32_t>(source_signature_id));
                if (employee_slot < 0 ||
                    _population.employee_employed[employee_slot] <= 0) continue;

                const bool profession_change =
                    candidate.profession != target_signature.profession_id;
                if (profession_change) {
                    bool source_drained = false;
                    const uint64_t preferred_family =
                        preferred_family_for_cohort(employee_slot, 1, 0,
                            target_signature.profession_id);
                    if (!move_cohort_population(employee_slot, cell,
                            target_group.owner_signature_id, 1, error,
                            &source_drained, preferred_family)) {
                        return false;
                    }
                    if (!source_drained) {
                        _population.employee_employed[employee_slot] =
                            std::max<int64_t>(0,
                                _population.employee_employed[employee_slot] - 1);
                    }
                    const int32_t destination = _population.find_signature(
                        cell, static_cast<uint32_t>(target_group.owner_signature_id));
                    if (destination < 0) {
                        error = "employee_owner_reallocation_destination_missing";
                        return false;
                    }
                    _population.owner_employed[destination] = saturating_add(
                        _population.owner_employed[destination], 1,
                        _saturation_count);
                    ++_building_owner_job_profession_changes;
                } else {
                    _population.employee_employed[employee_slot] -= 1;
                    _population.owner_employed[employee_slot] = saturating_add(
                        _population.owner_employed[employee_slot], 1,
                        _saturation_count);
                }
                _building_employee_filled[candidate.fill_index] -= 1;
                target_group.filled_owner = saturating_add(
                    target_group.filled_owner, 1, _saturation_count);
                owner_job_group_used[candidate.group - first] = 1;
                owner_job_group_used[target_group_index - first] = 1;
                ++_building_employee_to_owner_reallocations;
                ++_building_owner_job_reallocations;
                break;
            }
        }
        }
    }
    int64_t local_owner = 0;
    int64_t local_employee = 0;
    int64_t local_unemployed = 0;
    _population.for_each_in_cell(cell, [&](int32_t slot) {
        local_owner = saturating_add(local_owner, _population.owner_employed[slot],
                                     _saturation_count);
        local_employee = saturating_add(local_employee, _population.employee_employed[slot],
                                        _saturation_count);
        const int64_t unemployed = std::max<int64_t>(
            0, _population.population[slot] - _population.owner_employed[slot] -
               _population.employee_employed[slot]);
        local_unemployed = saturating_add(local_unemployed, unemployed, _saturation_count);
    });
    replace_employment_metrics_for_cell(
        cell, local_owner, local_employee, local_unemployed);
    bool employment_identity_valid = true;
    _population.for_each_in_cell(cell, [&](int32_t slot) {
        if (is_merchant_slot(slot)) return;
        const int32_t signature = static_cast<int32_t>(_population.signature_id[slot]);
        if (signature < 0 || signature >= static_cast<int32_t>(_signatures.size())) {
            employment_identity_valid = false;
            return;
        }
        if (_signatures[signature].profession_id == _unemployed_profession_id) return;
        const int64_t employed = saturating_add(
            std::max<int64_t>(0, _population.owner_employed[slot]),
            std::max<int64_t>(0, _population.employee_employed[slot]),
            _saturation_count);
        if (employed != std::max<int64_t>(0, _population.population[slot])) {
            employment_identity_valid = false;
        }
    });
    if (!employment_identity_valid) {
        error = "non_unemployed_cohort_has_idle_population";
        return false;
    }
    std::vector<EventLeg> event_legs;
    if (trace_detail) {
        for (size_t i = 0; i < trace_handles.size(); ++i) {
            int32_t slot = -1;
            if (!_population.valid_handle(trace_handles[i], slot)) {
                // 该 cohort 已被 A1 迁移完全 drain（例如整职业裁光进池并释放）：
                // 记为归零 leg，subject 用快照 handle，便于审计闭合。
                if (trace_owner_before[i] != 0) {
                    event_legs.push_back({FIELD_COHORT_OWNER_EMPLOYED, SUBJECT_COHORT,
                                          static_cast<int64_t>(trace_handles[i]), -1,
                                          trace_owner_before[i], 0});
                }
                if (trace_employee_before[i] != 0) {
                    event_legs.push_back({FIELD_COHORT_EMPLOYEE_EMPLOYED, SUBJECT_COHORT,
                                          static_cast<int64_t>(trace_handles[i]), -1,
                                          trace_employee_before[i], 0});
                }
                continue;
            }
            const int64_t handle = static_cast<int64_t>(trace_handles[i]);
            if (trace_owner_before[i] != _population.owner_employed[slot]) {
                event_legs.push_back({FIELD_COHORT_OWNER_EMPLOYED, SUBJECT_COHORT, handle,
                                      -1, trace_owner_before[i],
                                      _population.owner_employed[slot]});
            }
            if (trace_employee_before[i] != _population.employee_employed[slot]) {
                event_legs.push_back({FIELD_COHORT_EMPLOYEE_EMPLOYED, SUBJECT_COHORT, handle,
                                      -1, trace_employee_before[i],
                                      _population.employee_employed[slot]});
            }
        }
    }
    trace_append(EVENT_EMPLOYMENT_SETTLED,
                 static_cast<int32_t>(Stage::BUILDING_EMPLOYMENT), cell,
                 SUBJECT_BUILDING_GROUP, cell, first, last - first,
                 local_owner, local_employee, local_unemployed, last - first,
                 event_legs.empty() ? nullptr : &event_legs);
    return true;
}

// Employment metrics/reconciliation implementations live in
// economy_runtime_building_employment.cpp.


} // namespace pk
