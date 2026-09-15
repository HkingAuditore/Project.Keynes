#include "economy_runtime.h"
#include "country_runtime.h"

#include <algorithm>
#include <chrono>
#include <cstdlib>
#include <limits>

namespace pk {

namespace {
}

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
    thread_local std::vector<int64_t> mobile_population_by_profession;
    thread_local std::vector<int64_t> profession_capacity;
    thread_local std::vector<int64_t> profession_filled;
    thread_local std::vector<int64_t> profession_prefix;
    thread_local std::vector<int64_t> profession_distributed;
    thread_local std::vector<int64_t> owner_filled_by_profession;
    thread_local std::vector<int64_t> owner_population_by_profession;
    thread_local std::vector<int64_t> owner_prefix_by_profession;
    thread_local std::vector<int64_t> owner_distributed_by_profession;
    thread_local std::vector<uint32_t> signature_stamp;
    thread_local std::vector<uint32_t> profession_stamp;
    thread_local uint32_t scratch_generation = 0;
    // 鏈牸瀹為檯鍑虹幇杩囩殑 signature銆傛憡娲惧惊鐜潬瀹冨彇浠ｅ鏁村紶 _signatures 琛ㄧ殑鎵弿銆?
    thread_local std::vector<int32_t> touched_signatures;

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
    mobile_population_by_profession.assign(static_cast<size_t>(professions), 0);
    owner_filled_by_profession.assign(static_cast<size_t>(professions), 0);
    owner_population_by_profession.assign(static_cast<size_t>(professions), 0);
    owner_prefix_by_profession.assign(static_cast<size_t>(professions), 0);
    owner_distributed_by_profession.assign(static_cast<size_t>(professions), 0);

    for (int32_t ordinal = begin; ordinal < end; ++ordinal) {
        const int32_t cell = stable_cells[ordinal];
        ++scratch_generation;
        if (scratch_generation == 0) {
            std::fill(signature_stamp.begin(), signature_stamp.end(), 0);
            std::fill(profession_stamp.begin(), profession_stamp.end(), 0);
            scratch_generation = 1;
        }
        std::fill(mobile_population_by_profession.begin(),
                  mobile_population_by_profession.end(), 0);
        std::fill(owner_filled_by_profession.begin(),
                  owner_filled_by_profession.end(), 0);
        std::fill(owner_population_by_profession.begin(),
                  owner_population_by_profession.end(), 0);
        std::fill(owner_prefix_by_profession.begin(),
                  owner_prefix_by_profession.end(), 0);
        std::fill(owner_distributed_by_profession.begin(),
                  owner_distributed_by_profession.end(), 0);
        touched_signatures.clear();
        auto touch_signature = [&](int32_t signature) {
            if (signature_stamp[signature] == scratch_generation) return;
            signature_stamp[signature] = scratch_generation;
            touched_signatures.push_back(signature);
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
        int64_t mobile_population_total = 0;
        population_store().for_each_in_cell(cell, [&](int32_t slot) {
            const uint32_t sig = population_store().signature_id[slot];
            if (sig < sig_population.size()) {
                touch_signature(static_cast<int32_t>(sig));
                sig_population[sig] = saturating_add(sig_population[sig],
                    std::max<int64_t>(0, population_store().population[slot]), _saturation_count);
                if (!is_merchant_slot(slot) && sig < _signatures.size()) {
                    const int32_t profession = _signatures[sig].profession_id;
                    if (profession >= 0 && profession < professions) {
                        const int64_t pop = std::max<int64_t>(0, population_store().population[slot]);
                        const int64_t attached = saturating_add(
                            std::max<int64_t>(0, population_store().owner_employed[slot]),
                            std::max<int64_t>(0, population_store().employee_employed[slot]),
                            _saturation_count);
                        mobile_population_by_profession[profession] = saturating_add(
                            mobile_population_by_profession[profession],
                            std::max<int64_t>(0, pop - attached), _saturation_count);
                        mobile_population_total = saturating_add(
                            mobile_population_total,
                            std::max<int64_t>(0, pop - attached), _saturation_count);
                    }
                }
            }
        });

        priority.clear();
        thread_local std::vector<int64_t> priority_income;
        thread_local std::vector<uint8_t> priority_survival;
        priority_income.assign(static_cast<size_t>(last - first), 0);
        priority_survival.assign(static_cast<size_t>(last - first), 0);
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
            int64_t priority_sat = 0;
            const BuildingType &type = _building_types[group.type_id];
            const int32_t owner_profession = group.owner_signature_id >= 0 &&
                    group.owner_signature_id < static_cast<int32_t>(_signatures.size())
                ? _signatures[group.owner_signature_id].profession_id : -1;
            // A mobile unemployed cohort can enter a different profession;
            // do not use its current (usually unemployed) profession as a
            // hard fillability gate for the target role.
            // Vacancy is an outcome, not a reason to lower the building's
            // counterfactual income signal. Current staffing remains an
            // execution constraint in production, but never suppresses demand.
            const int64_t owner_fillability = Q16_ONE;
            int64_t employee_fillability = Q16_ONE;
            for (int32_t r = 0; r < type.employee_count; ++r) {
                const JobRole &role = _building_employee_roles[type.employee_begin + r];
                const int64_t slots = saturating_mul(group.count,
                    role.slots_per_building, priority_sat);
                const int32_t fill_index = group.employee_fill_begin + r;
                const int64_t filled = fill_index >= 0 && fill_index <
                        static_cast<int32_t>(_building_employee_filled.size())
                    ? std::max<int64_t>(0, _building_employee_filled[fill_index]) : 0;
                const int64_t available = mobile_population_total;
                employee_fillability = std::min(employee_fillability,
                    slots > 0 ? std::clamp<int64_t>(mul_div_sat(
                        saturating_add(filled, available, priority_sat), Q16_ONE,
                        slots, priority_sat), 0, Q16_ONE) : Q16_ONE);
            }
            const OwnerOpportunityQuote quote = owner_opportunity_quote(
                group, owner_fillability, employee_fillability, priority_sat);
            priority_income[static_cast<size_t>(g - first)] =
                quote.disposable_survival_power_per_day;
            priority_survival[static_cast<size_t>(g - first)] =
                quote.survival_priority ? 1 : 0;
            if (quote.survival_priority) ++_building_survival_priority_candidates;
            ++_building_owner_opportunity_quotes;
            if (!quote.feasible) ++_building_owner_opportunity_zero_feasible;
            _saturation_count = saturating_add(
                _saturation_count, priority_sat, _saturation_count);
            priority.push_back(g);
        }
        std::stable_sort(priority.begin(), priority.end(), [&](int32_t a, int32_t b) {
            const uint8_t survival_a = priority_survival[static_cast<size_t>(a - first)];
            const uint8_t survival_b = priority_survival[static_cast<size_t>(b - first)];
            if (survival_a != survival_b) return survival_a > survival_b;
            const int64_t income_a = priority_income[static_cast<size_t>(a - first)];
            const int64_t income_b = priority_income[static_cast<size_t>(b - first)];
            if (income_a != income_b) return income_a > income_b;
            return a < b;
        });

        // Clamp owner fills by profession rather than canonical signature. The
        // latter would silently evict owners whose ethnicity differs from the
        // building profile during this reconciliation pass.
        //
        // 涓嬮潰涓夊鎽婃淳寰幆鍘熸潵鍚勬壂涓€閬嶆暣寮?_signatures 琛紙闅忓瓨妗ｅ崟璋冨闀夸笖姘镐笉
        // 鏀剁缉锛夛紝鍙负鎸戝嚭鏈牸瀹為檯鍑虹幇鐨勯偅鍑犱釜 signature銆傛敼鎴愰亶鍘?touched 鍒楄〃锛?
        // 鎺掑簭涓€娆″嵆鍙繚鎸佸悓涓€涓?signature id 鍗囧簭锛屽墠缂€鍜屾憡娲鹃€愪綅涓嶅彉銆?
        std::sort(touched_signatures.begin(), touched_signatures.end());
        for (const int32_t sig : touched_signatures) {
            if (sig_population[sig] <= 0) continue;
            const int32_t profession = _signatures[sig].profession_id;
            if (profession < 0 || profession >= professions ||
                profession == _unemployed_profession_id) continue;
            owner_population_by_profession[profession] = saturating_add(
                owner_population_by_profession[profession], sig_population[sig],
                _saturation_count);
        }
        for (int32_t g : priority) {
            BuildingGroup &group = _buildings[g];
            const int32_t sig = group.owner_signature_id;
            if (sig < 0 || sig >= static_cast<int32_t>(sig_population.size())) {
                error = "building_owner_signature_invalid_after_population_change";
                return false;
            }
            const int32_t profession = _signatures[sig].profession_id;
            if (profession < 0 || profession >= professions ||
                profession == _unemployed_profession_id) {
                group.filled_owner = 0;
                continue;
            }
            int64_t &remaining = owner_population_by_profession[profession];
            group.filled_owner = std::min(
                std::max<int64_t>(0, group.filled_owner), remaining);
            remaining -= group.filled_owner;
            owner_filled_by_profession[profession] = saturating_add(
                owner_filled_by_profession[profession], group.filled_owner,
                _saturation_count);
        }

        // Distribute each profession's owner jobs over the live local
        // profession|ethnicity cohorts in stable signature order.
        for (const int32_t sig : touched_signatures) sig_owner_filled[sig] = 0;
        std::fill(owner_population_by_profession.begin(),
                  owner_population_by_profession.end(), 0);
        for (const int32_t sig : touched_signatures) {
            if (sig_population[sig] <= 0) continue;
            const int32_t profession = _signatures[sig].profession_id;
            if (profession < 0 || profession >= professions ||
                profession == _unemployed_profession_id) continue;
            owner_population_by_profession[profession] = saturating_add(
                owner_population_by_profession[profession], sig_population[sig],
                _saturation_count);
        }
        std::fill(owner_prefix_by_profession.begin(), owner_prefix_by_profession.end(), 0);
        std::fill(owner_distributed_by_profession.begin(),
                  owner_distributed_by_profession.end(), 0);
        for (const int32_t sig : touched_signatures) {
            if (sig_population[sig] <= 0) continue;
            const int32_t profession = _signatures[sig].profession_id;
            if (profession < 0 || profession >= professions ||
                profession == _unemployed_profession_id) continue;
            owner_prefix_by_profession[profession] = saturating_add(
                owner_prefix_by_profession[profession], sig_population[sig],
                _saturation_count);
            const int64_t next = owner_population_by_profession[profession] > 0
                ? mul_div_sat(owner_filled_by_profession[profession],
                    owner_prefix_by_profession[profession],
                    owner_population_by_profession[profession], _saturation_count)
                : 0;
            sig_owner_filled[sig] = std::max<int64_t>(0,
                next - owner_distributed_by_profession[profession]);
            owner_distributed_by_profession[profession] = next;
        }

        population_store().for_each_in_cell(cell, [&](int32_t slot) {
            if (is_merchant_slot(slot)) return;
            const int32_t sig = static_cast<int32_t>(population_store().signature_id[slot]);
            const int32_t profession = _signatures[sig].profession_id;
            if (profession == _unemployed_profession_id) return;
            touch_profession(profession);
            const int64_t owner = std::min(sig_owner_filled[sig],
                std::max<int64_t>(0, population_store().population[slot]));
            profession_capacity[profession] = saturating_add(
                profession_capacity[profession],
                std::max<int64_t>(0, population_store().population[slot] - owner),
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
        population_store().for_each_in_cell(cell, [&](int32_t slot) {
            const int32_t sig = static_cast<int32_t>(population_store().signature_id[slot]);
            const int32_t profession = _signatures[sig].profession_id;
            const int64_t population = std::max<int64_t>(0, population_store().population[slot]);
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
            population_store().owner_employed[slot] = owner;
            population_store().employee_employed[slot] = employee;
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
    if (cell < 0 || cell >= _cell_count ||
        _building_cell_offsets.size() != static_cast<size_t>(_cell_count + 1) ||
        _labor_signals.cell_offsets.size() != static_cast<size_t>(_cell_count + 1)) {
        error = "building_employment_restore_index_invalid";
        return false;
    }
    const int32_t begin = _building_cell_offsets[cell];
    const int32_t end = _building_cell_offsets[cell + 1];
    if (begin >= end) return true;
    const int32_t market = market_store().cell_to_market[cell];
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
        merchant_cash / std::max(1, _epoch_days);
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
            // Quote only demand-backed daily output, reserve daily inputs plus
            // the configured operating margin, then divide the remaining wage
            // pool across all employee slots. Passing zero expected supply to
            // the inventory target is intentional: a new recipe must not create
            // its own merchant demand merely by advertising nameplate output.
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
                        _good_monetary_issue_values[output.good_id] > 0;
                    int64_t settlement =
                        _good_monetary_issue_values[output.good_id];
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
                int64_t daily_revenue = saturating_mul(
                    daily_issue_revenue_per_building, group.count,
                    _saturation_count);
                daily_revenue = saturating_add(
                    daily_revenue, std::min<int64_t>(
                        daily_merchant_cash,
                        saturating_mul(daily_market_revenue_per_building,
                            group.count, _saturation_count)),
                    _saturation_count);
                if (daily_revenue > 0 && group_employee_slots > 0) {
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
    // demand[p] = profession p 鏈懆鏈?employee 鐩爣涔嬪拰锛沠ill[p] = 澶圭揣鍚庡湪宀?
    // employee 涔嬪拰銆備簩鑰呭湪 A1 涓ゆ閫昏緫涓 std::fill 閲嶇疆澶嶇敤锛堣涓嬶級銆?
    thread_local std::vector<int64_t> demand;
    thread_local std::vector<int64_t> fill;
    auto employment_utilization_q16 = [&](const BuildingGroup &group) {
        const int32_t index = static_cast<int32_t>(&group - _buildings.data());
        int64_t utilization = index >= 0 && index < static_cast<int32_t>(
                _building_planned_capacity_before_climate_q16.size())
            ? _building_planned_capacity_before_climate_q16[index]
            : group.planned_utilization_q16;
        return std::clamp<int64_t>(utilization, 0, Q16_ONE);
    };
    auto expected_employee_gross = [&](const JobRole &role,
                                       int32_t role_index) -> int64_t {
        const int64_t contract = role_index >= 0 && role_index <
                static_cast<int32_t>(_building_role_contract_wage.size())
            ? std::max<int64_t>(0, _building_role_contract_wage[role_index])
            : std::max<int64_t>(0, role.reference_wage_per_day);
        if (contract <= 0) return 0;
        const int32_t signal = labor_signal_index(cell, role.profession_id);
        const int64_t profession_paid = signal >= 0 && signal <
                static_cast<int32_t>(_labor_signals.paid_wage_ema.size())
            ? std::max<int64_t>(0, _labor_signals.paid_wage_ema[signal]) : 0;
        const int64_t due = role_index >= 0 && role_index <
                static_cast<int32_t>(_building_role_base_wage_due.size())
            ? std::max<int64_t>(0, _building_role_base_wage_due[role_index]) : 0;
        const int64_t paid = role_index >= 0 && role_index <
                static_cast<int32_t>(_building_role_base_wage_paid.size())
            ? std::max<int64_t>(0, _building_role_base_wage_paid[role_index]) : 0;
        const int64_t forecast_ratio_q16 = role_index >= 0 && role_index <
                static_cast<int32_t>(
                    _building_role_forecast_pay_ratio_q16.size())
            ? std::clamp<int64_t>(
                _building_role_forecast_pay_ratio_q16[role_index],
                0, Q16_ONE)
            : Q16_ONE;
        const int64_t forecast_expected = mul_div_sat(
            contract, forecast_ratio_q16, Q16_ONE, _saturation_count);
        // A new or currently empty role has no role-specific observation. Use
        // its funded absorption forecast directly; do not assume the contract
        // is collectible and do not inherit another employer's arrears.
        if (due <= 0) return forecast_expected;
        const int64_t fulfillment_q16 = due > 0
            ? std::clamp<int64_t>(mul_div_sat(
                paid, Q16_ONE, due, _saturation_count), 0, Q16_ONE)
            : Q16_ONE;
        const int64_t role_expected = mul_div_sat(
            contract, fulfillment_q16, Q16_ONE, _saturation_count);
        const int64_t blended = profession_paid > 0
            ? saturating_add(role_expected, std::min(contract, profession_paid),
                _saturation_count) / 2
            : role_expected;
        return std::clamp<int64_t>(
            std::min(blended, forecast_expected), 0, contract);
    };
    auto expected_employee_hiring_gross = [&](const JobRole &role,
                                              int32_t role_index) -> int64_t {
        const int64_t expected = expected_employee_gross(role, role_index);
        const int64_t due = role_index >= 0 && role_index <
                static_cast<int32_t>(_building_role_base_wage_due.size())
            ? std::max<int64_t>(
                0, _building_role_base_wage_due[role_index])
            : 0;
        if (due > 0) return expected;
        const int64_t contract = role_index >= 0 && role_index <
                static_cast<int32_t>(_building_role_contract_wage.size())
            ? std::max<int64_t>(
                0, _building_role_contract_wage[role_index])
            : std::max<int64_t>(0, role.reference_wage_per_day);
        // A cold-start vacancy has no realized payroll ratio yet. Use the
        // nominal contract for the unemployed entry path; affordability is
        // still enforced by the owner/production working-capital and input
        // gates after the person is admitted. Using contract/8 puts a
        // break-even role below its own livelihood floor and strands the
        // initial unemployed pool.
        return std::max<int64_t>(expected, contract);
    };
    const int32_t professions = static_cast<int32_t>(_profession_ids.size());
    demand.assign(professions, 0);
    fill.assign(professions, 0);
    const int32_t first = _building_cell_offsets.size() == static_cast<size_t>(_cell_count + 1)
        ? _building_cell_offsets[cell] : 0;
    const int32_t last = _building_cell_offsets.size() == static_cast<size_t>(_cell_count + 1)
        ? _building_cell_offsets[cell + 1] : 0;
    int64_t stay_q16 = Q16_ONE;
    const int64_t daily_mobility_q16 = std::clamp<int64_t>(
        _employment_mobility_daily_q16, 0, Q16_ONE);
    for (int32_t d = 0; d < std::max(1, _epoch_days); ++d) {
        stay_q16 = mul_div_sat(stay_q16,
            Q16_ONE - daily_mobility_q16, Q16_ONE, _saturation_count);
    }
    const int64_t mobility_period_q16 = std::clamp<int64_t>(
        Q16_ONE - stay_q16, 0, Q16_ONE);
    auto planned_role_demand = [&](const BuildingGroup &group,
                                   const JobRole &role, int32_t role_index) {
        const int64_t full = saturating_mul(group.count, role.slots_per_building,
                                            _saturation_count);
        const int64_t utilization = employment_utilization_q16(group);
        int64_t scaled = mul_div_sat(full, utilization, Q16_ONE,
                                     _saturation_count);
        if (scaled == 0 && full > 0 && utilization > 0) scaled = 1;
        return scaled;
    };
    const bool trace_detail = trace_detail_for_cell(cell);
    // A1 杩佺Щ浼?allocate/release slot锛岃８ slot id 浼氬け鏁堬紱trace 蹇収鏀瑰瓨绋冲畾
    // handle锛屼簨浠剁敓鎴愭椂鐢?valid_handle 瑙ｆ瀽鍥炲綋鍓?slot锛堝け鏁堝垯璺宠繃璇?leg锛夈€?
    thread_local std::vector<uint64_t> trace_handles;
    thread_local std::vector<int64_t> trace_owner_before;
    thread_local std::vector<int64_t> trace_employee_before;
    trace_handles.clear(); trace_owner_before.clear(); trace_employee_before.clear();
    if (trace_detail) {
        population_store().for_each_in_cell(cell, [&](int32_t slot) {
            trace_handles.push_back(population_store().handle_for_slot(slot));
            trace_owner_before.push_back(population_store().owner_employed[slot]);
            trace_employee_before.push_back(population_store().employee_employed[slot]);
        });
    }
    // ================================================================
    // A1 璺緞锛氬け涓氭睜澧為噺灏变笟锛堢粺涓€鍑€澧為噺杩佺Щ锛岀敤鎴?2026-07-16 鎷嶆澘锛?
    // ----------------------------------------------------------------
    // 涓嶅彉閲忥紙employment 缁撴潫鏃跺姣忎釜闈?merchant銆侀潪 unemployed 鐨?
    //   profession|eth slot 鎴愮珛锛夛細owner_employed + employee_employed
    //   == population锛屽嵆鍦ㄥ矖 slot 閲屾病鏈夐棽缃汉鍙ｏ紱浠讳綍鏈浠讳綍寤虹瓚闆囦剑
    //   鐨勪汉閮界湡瀹炶縼寰€ unemployed|eth slot锛堢嫭绔?cohort 韬唤 + plan_unemployed锛?
    //   娑堣垂閫€鍖栦负 survival food 鈫?satisfaction 鎺?鈫?starvation 鑷劧姝讳笂鍗囷紝
    //   澶变笟鎯╃綒鐢?demography 鑷姩鏂藉姞锛屾棤闇€纭紪姝讳骸鐜囷級銆?
    //
    // 涓ゆ缁撴瀯锛堟暟瀛︿笂绛変环浜?娑堝け娓呯悊 + 寤虹瓚椹卞姩瑁佸憳 + 鏈夐檺娴佸姩鎷涗汉"涓夐樁娈?
    //   鍚堝苟锛屼絾 owner/employee 鍦ㄥ悓涓€ slot 鍐呰嚜鐒剁珵浜?population锛屾棤闇€鍦ㄩ樁娈?
    //   闂存樉寮忎紶閫?slot 鍓╀綑瀹归噺锛夛細
    //   [绗?姝?鏋愬嚭] 姣忎釜鍦ㄥ矖 slot 鎸夋湰鍛ㄦ湡 planned_utilization 鐩爣绠?
    //     desired_working锛泂urplus = population - desired_working 鐨勯儴鍒嗚縼寰€
    //     unemployed|eth銆傛秷澶?涓嶅彲鐢ㄥ缓绛戠洰鏍囦负 0锛屽叾鍦ㄥ矖浜哄彛鑷劧鍏ㄩ儴杩涙睜銆?
    //     鎵ц鍚庢墍鏈夋椿璺?group 鐨?filled_* 琚す鍒?鐩爣鎴栨洿灏?锛屽浣欎汉鍙ｅ叏鍦ㄦ睜涓€?
    //   [绗?姝?鎷涗汉] unemployed 姹犳鍒绘眹闆嗕簡鍚?eth 鐨勫叏閮ㄥけ涓氳€咃紙鍚湰鍛ㄦ湡鍒?
    //     杩涙睜鐨?+ 鍘嗗彶闀挎湡澶变笟鐨勶級銆傛椿璺?group 鎸変紭鍏堢骇
    //     (realized_profit_margin_q16 desc, planned_utilization_q16 desc,
    //      group_index asc) 璺ㄥ缓绛戠被鍨嬫帓搴忥紝渚濇鎶?filled_owner/filled_employee
    //     琛ュ埌鐩爣锛屼粠 unemployed|eth 鐪熷疄杩佸洖瀵瑰簲 profession|eth slot锛堝彈姹?
    //     鍙敤閲忕害鏉燂級銆傛墍鏈夊彲琛屽€欓€夋寜 pay ratio 鍜?utilization 鍔犳潈姣斾緥
    //     浠庢湁闄?mobility budget 杩佸洖锛屼笉鍐嶇敱鍗曚竴鏈€楂樻敹鍏?group 鍚歌蛋鏁翠釜
    //     澶变笟姹狅紝涔熶笉鍥犲€欓€夋埅鏂€岄タ姝讳綆鎺掑悕寤虹瓚銆?
    //     鎷涗汉璺?profession锛氬け涓?farmer 鍙鎷涗负 miner锛坧rofession 鏄彲鍙樺氨涓?
    //     鐘舵€侊紝鏋舵瀯鍐崇瓥4锛夈€?
    //
    // 鍏抽敭宸ョ▼绾︽潫锛歮ove_cohort_population 浼?allocate/release slot锛岀牬鍧?
    //   for_each_in_cell 鐨勯〉閾捐凯浠ｅ櫒銆傛晠鎵€鏈夎縼绉婚兘"鍏堝彧璇婚亶鍘嗘敹闆嗚鍒掑埌
    //   thread_local 缂撳啿锛岄亶鍘嗙粨鏉熷悗鍐嶇粺涓€鎵ц杩佺Щ"锛堝 ensure_merchant_invariant锛夈€?
    //   Route B: 鍟嗘爤(merchant_post) owner 鐜板湪鍙備笌灏变笟鍒嗛厤鈥斺€攎erchant slot 鐨?
    //   owner_employed 璁″叆 filled_owner銆佺撼鍏ユ瀽鍑?鑱氬悎锛涗絾淇濆簳姣忔湁浜?cell 鑷冲皯
    //   1 涓?merchant 涓嶈瑁?鎶や綇 rebuild_merchant_ranges 鍋氬競绱㈠紩涓嶅彉閲?銆?
    //   emp_capacity 绗竴閬嶄粛璺宠繃 merchant(鍟嗕汉涓嶅仛 employee锛屼粎 owner 宀?銆?
    // ================================================================
    // The same authoritative release/hire path also owns cells whose last
    // building was removed. Empty ranges must release every non-merchant
    // profession cohort into unemployed instead of leaving an idle profession.
    {
        const int32_t n_eth = static_cast<int32_t>(_ethnicity_ids.size());

        // Owner mobility always uses the read-only opportunity quote. This is
        // intentionally independent of realized filled_owner so an established
        // but temporarily vacant lot can attract labor again.
        auto owner_mobility_income = [&](const BuildingGroup &group,
                                         int64_t &sat) -> int64_t {
            if (group.type_id < 0 || group.type_id >= static_cast<int32_t>(
                    _building_types.size()) || group.operating_state == 1 ||
                group.count <= 0) return 0;
            const BuildingType &type = _building_types[group.type_id];
            // Evaluate the whole executable owner capacity. Using the current
            // filled_owner ratio here creates the same self-reinforcing vacancy
            // loop as the production planner.
            const int64_t owner_fillability = Q16_ONE;
            int64_t employee_fillability = Q16_ONE;
            for (int32_t r = 0; r < type.employee_count; ++r) {
                const JobRole &role = _building_employee_roles[type.employee_begin + r];
                const int64_t slots = saturating_mul(group.count,
                    role.slots_per_building, sat);
                const int32_t index = group.employee_fill_begin + r;
                const int64_t filled = index >= 0 && index < static_cast<int32_t>(
                        _building_employee_filled.size())
                    ? std::max<int64_t>(0, _building_employee_filled[index]) : 0;
                employee_fillability = std::min(employee_fillability,
                    slots > 0 ? std::clamp<int64_t>(mul_div_sat(filled, Q16_ONE,
                        slots, sat), 0, Q16_ONE) : Q16_ONE);
            }
            return owner_opportunity_quote(group, owner_fillability,
                employee_fillability, sat).disposable_survival_power_per_day;
        };

        // Employment mobility is evaluated in disposable-income space.  Owner
        // income already excludes the owner's living cost; employee wages do
        // not, so subtract the target signature's cost before comparing them.
        // The cadence-invariant period mobility was frozen before target
        // construction so retention and hiring use the same hazard.
        auto transition_hurdle_q16 = [&](int32_t source_profession,
                                         int32_t target_profession) -> int64_t {
            // The unemployed pool is the normal bootstrap and layoff entry
            // point. Requiring a positive income improvement here makes a
            // break-even first job unreachable when the target contract wage
            // equals the target livelihood floor.
            if (source_profession == _unemployed_profession_id)
                return 0;
            if (source_profession == target_profession)
                return std::max<int64_t>(1, _investment_displacement_min_advantage_q16);
            int64_t hurdle = std::max<int64_t>(Q16_ONE / 8,
                _investment_displacement_min_advantage_q16);
            if (target_profession == _merchant_profession_id &&
                source_profession != _merchant_profession_id) {
                hurdle = std::max<int64_t>(hurdle,
                    _investment_merchant_transition_min_improvement_q16);
            }
            return hurdle;
        };
        auto improvement_q16 = [&](int64_t current_disposable,
                                   int64_t target_disposable) -> int64_t {
            const int64_t gain = saturating_sub(target_disposable,
                                                current_disposable,
                                                _saturation_count);
            if (gain <= 0) return 0;
            // Both sides already include their livelihood terms. Reusing raw
            // living costs in this denominator applies the livelihood hurdle
            // twice and can make every positive vacancy unreachable from zero
            // unemployment income.
            const int64_t denominator = std::max<int64_t>(
                1, std::llabs(current_disposable));
            return std::clamp<int64_t>(mul_div_sat(
                gain, Q16_ONE, denominator, _saturation_count), 0,
                Q16_ONE * 4);
        };
        auto choice_factor_q16 = [&](int64_t improvement) -> int64_t {
            const int64_t temperature = std::max<int64_t>(1,
                _employment_choice_temperature_q16);
            const int64_t softened = mul_div_sat(
                std::max<int64_t>(0, improvement), Q16_ONE,
                saturating_add(Q16_ONE, temperature, _saturation_count),
                _saturation_count);
            return std::clamp<int64_t>(
                saturating_add(Q16_ONE, softened, _saturation_count),
                Q16_ONE, Q16_ONE * 5);
        };
        auto owner_entry_capital = [&](const BuildingGroup &group) -> int64_t {
            const int64_t owner_demand = std::max<int64_t>(1,
                planned_owner_demand(group, _saturation_count));
            if (group.sample_unit_input_cost <= 0 || group.count <= 0)
                return 0;
            const int64_t full_period_cost = saturating_mul(
                saturating_mul(group.sample_unit_input_cost, group.count,
                               _saturation_count),
                std::max<int64_t>(1, _epoch_days), _saturation_count);
            // Match the household-market reserve: one entrant carries its
            // proportional share of the period's physical input bill.
            const int64_t operation_scale = employment_utilization_q16(group);
            return mul_div_sat(full_period_cost, operation_scale,
                Q16_ONE, _saturation_count) / owner_demand;
        };
        auto recent_expense_per_day = [&](int32_t slot) -> int64_t {
            if (slot < 0 || slot >= static_cast<int32_t>(population_store().population.size()))
                return 0;
            const int64_t people = std::max<int64_t>(1,
                population_store().population[slot]);
            const int64_t days = std::max<int64_t>(1, _epoch_days);
            return std::max<int64_t>(0, population_store().epoch_expense[slot]) /
                people / days;
        };
        auto unemployed_disposable_income = [&](int32_t slot) -> int64_t {
            if (slot < 0 || slot >= static_cast<int32_t>(
                    population_store().population.size())) return 0;
            const int32_t signature = static_cast<int32_t>(
                population_store().signature_id[slot]);
            if (signature < 0 || signature >= static_cast<int32_t>(
                    _signatures.size())) return 0;
            const int32_t profession = _signatures[signature].profession_id;
            if (profession != _unemployed_profession_id) return 0;
            // Savings and proportional ledger/EMA values carried into the
            // unemployed cohort are stocks or prior-period attribution, not
            // current employment income. A funded negative income tax is the
            // one current reservation-income source and must remain visible.
            const int32_t income_rate = frozen_tax_rate(
                cell, NativeCountryRuntime::TAX_INCOME, profession);
            if (income_rate >= 0) return 0;
            const int64_t daily_floor = living_cost_for_signature(
                cell, signature, _living_cost_base_plan_id,
                _saturation_count);
            const int64_t signed_transfer = expected_resolved_fiscal_transfer(
                cell, NativeCountryRuntime::TAX_INCOME, profession,
                daily_floor, 1, _saturation_count);
            return std::max<int64_t>(0, saturating_sub(
                0, signed_transfer, _saturation_count));
        };

        // ---- 鐩爣璁＄畻锛氭湰鍛ㄦ湡鍚?group 鏈熸湜鐨?owner / 鍚?role employee ----
        // 鐢?thread_local 缂撳啿閬垮厤姣?cell 鍒嗛厤銆?
        thread_local std::vector<int64_t> group_owner_target;      // 姣?group owner 鐩爣
        group_owner_target.assign(static_cast<size_t>(last - first), 0);
        // profession 绾?employee 鐩爣 / 鍦ㄥ矖锛堣法 eth 鑱氬悎锛屾部鐢ㄦ棫 employee 璇箟锛夈€?
        std::fill(demand.begin(), demand.end(), 0);   // demand[p] = 危 planned_role_demand
        std::fill(fill.begin(), fill.end(), 0);       // fill[p]   = 危 褰撳墠鍦ㄥ矖 employee
        for (int32_t g = first; g < last; ++g) {
            BuildingGroup &group = _buildings[g];
            if (group.cell != cell) continue;
            const bool active = group.count > 0 && group.operating_state != 1 &&
                                 building_available(cell, group.type_id, true);
            const BuildingType &type = _building_types[group.type_id];
            // owner 鐩爣锛氫笉鍙敤/count<=0 鈫?0锛堝叾鍦ㄥ矖浜哄彛灏嗗叏閮ㄨ繘姹狅級銆?
            const bool suspended = group.count > 0 && group.operating_state == 1 &&
                                   building_available(cell, group.type_id, true);
            const int64_t owner_target = (active || suspended)
                ? planned_owner_demand(group, _saturation_count) : 0;
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
        hire_order.clear();
        labor_expected_employee_income.assign(static_cast<size_t>(last - first), 0);
        labor_expected_owner_income.assign(static_cast<size_t>(last - first), 0);
        for (int32_t g = first; g < last; ++g) {
            BuildingGroup &group = _buildings[g];
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
            const BuildingGroup &ga = _buildings[a];
            const BuildingGroup &gb = _buildings[b];
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

        // ---- 绗?姝?鏋愬嚭锛氭妸瓒呭嚭鐩爣鐨勫湪宀椾汉鍙ｈ縼寰€ unemployed|eth ----
        // (a) 鍏堟妸姣忎釜 group 鐨?filled_owner / _building_employee_filled 澶瑰埌鐩爣
        //     锛堣鍛橈細filled > target 鐨勫樊棰濋噴鏀撅級銆俥mployee 鎸?profession 绋冲畾搴?
        //     鍦ㄥ group 闂村墛鍑忥紙鍚?profession 鑱氬悎锛岄€?group 鍓婂埌 target锛夈€?
        // (b) 鍐嶆寜 profession|eth slot 鑱氬悎"璇?slot 搴斾繚鐣欑殑鍦ㄥ矖浜哄彛"锛屾妸
        //     population - retained 杩佸線 unemployed|eth銆?
        //
        // owner 渚уす绱э紙寤虹瓚椹卞姩锛氭瘡 group 鐙珛鎸夎嚜韬?filled-target 瑁侊級銆?
        const bool trace_employment = cell == _inspector_trace_cell;
        thread_local std::vector<int64_t> trace_filled_before_clamp;
        thread_local std::vector<int64_t> trace_filled_after_profession;
        if (trace_employment) {
            trace_filled_before_clamp.assign(
                static_cast<size_t>(std::max(0, last - first)), 0);
            trace_filled_after_profession.assign(
                static_cast<size_t>(std::max(0, last - first)), 0);
            for (int32_t g = first; g < last; ++g)
                trace_filled_before_clamp[g - first] = _buildings[g].filled_owner;
        }
        for (int32_t g = first; g < last; ++g) {
            BuildingGroup &group = _buildings[g];
            if (group.cell != cell || group.count <= 0) continue;
            if (group.filled_owner > group_owner_target[g - first]) {
                group.filled_owner = group_owner_target[g - first];
            }
        }
        // A building's canonical owner signature describes its occupation, not an
        // ethnicity admission rule. Clamp aggregate owner fills by profession so
        // owners hired from another local ethnicity remain valid in the next pass.
        thread_local std::vector<int64_t> owner_remaining_by_profession;
        owner_remaining_by_profession.assign(professions, 0);
        population_store().for_each_in_cell(cell, [&](int32_t slot) {
            const uint32_t sig = population_store().signature_id[slot];
            if (sig >= _signatures.size()) return;
            const int32_t profession = _signatures[sig].profession_id;
            if (profession < 0 || profession >= professions ||
                profession == _unemployed_profession_id) return;
            owner_remaining_by_profession[profession] = saturating_add(
                owner_remaining_by_profession[profession],
                std::max<int64_t>(0, population_store().population[slot]),
                _saturation_count);
        });
        for (int32_t g : hire_order) {
            BuildingGroup &group = _buildings[g];
            if (group.owner_signature_id < 0 ||
                group.owner_signature_id >= static_cast<int32_t>(_signatures.size())) {
                group.filled_owner = 0;
                continue;
            }
            const int32_t profession =
                _signatures[group.owner_signature_id].profession_id;
            if (profession < 0 || profession >= professions ||
                profession == _unemployed_profession_id) {
                group.filled_owner = 0;
                continue;
            }
            int64_t &remaining = owner_remaining_by_profession[profession];
            group.filled_owner = std::min(std::max<int64_t>(0, group.filled_owner), remaining);
            remaining -= group.filled_owner;
        }
        if (trace_employment) {
            for (int32_t g = first; g < last; ++g)
                trace_filled_after_profession[g - first] =
                    _buildings[g].filled_owner;
        }
        // Family ownership is a sparse attribution overlay on the aggregated
        // building group, not an admission rule: it records which families the
        // seated proprietors belong to, and never reduces the fill.
        attribute_family_owner_employment_for_cell(cell);
        // employee 渚уす绱э細profession p 鑻?危filled > 危target锛屾寜 group 绋冲畾搴?
        // 浠庡悗寰€鍓嶅墛鍑忓悇 role fill 鍒?demand銆傜敤 remaining[p] 杩借釜璇?profession
        // 鍏佽淇濈暀鐨勬€诲湪宀楁暟锛岄€?group 鍒嗛厤 min(role_filled, remaining)銆?
        thread_local std::vector<int64_t> emp_remaining;   // 姣?profession 鍏佽淇濈暀鐨勫湪宀椾笂闄?
        emp_remaining.assign(professions, 0);
        for (int32_t p = 0; p < professions; ++p) {
            emp_remaining[p] = std::min(fill[p], demand[p]);   // 瑁佸憳鍚庝繚鐣?= min(鍦ㄥ矖, 鐩爣)
        }
        std::fill(fill.begin(), fill.end(), 0);   // 閲嶇畻涓哄す绱у悗鐨勫疄闄呭湪宀?
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

        // (b) 璁＄畻姣忎釜 profession|eth slot 澶圭揣鍚庡簲淇濈暀鐨勫湪宀椾汉鍙ｏ紝鏀堕泦杩佸線姹犵殑宸銆?
        //     owner_retained[slot] = 璇?signature 鍚?group filled_owner 涔嬪拰锛?
        //     employee_retained[slot] = 璇?profession 鍦ㄥ矖 employee 鎸?slot 绋冲畾搴忔憡娲俱€?
        //     retained = owner_retained + employee_retained锛圓1: <= population锛夈€?
        //     surplus = population - retained 鈫?杩佸線 unemployed|eth銆?
        //
        // First aggregate filled owner jobs by profession, then distribute them
        // over local profession|ethnicity cohorts in stable signature order. A
        // BuildingGroup has no per-owner identity, so retaining by its canonical
        // signature would recreate an ethnicity partition after every pass.
        thread_local std::vector<int64_t> sig_owner_retained;
        thread_local std::vector<int64_t> sig_owner_population;
        thread_local std::vector<int64_t> owner_filled_by_profession;
        thread_local std::vector<int64_t> owner_population_by_profession;
        thread_local std::vector<int64_t> owner_prefix_by_profession;
        thread_local std::vector<int64_t> owner_distributed_by_profession;
        thread_local std::vector<int32_t> owner_active_signatures;
        thread_local std::vector<int64_t> sig_owner_distributed;
        // 杩欎笁鏉?signature 閫氶亾鍘熸潵鍦ㄦ瘡鏍煎紑澶村悇 assign 涓€閬嶆暣寮?_signatures 琛ㄣ€傝〃闅?
        // 瀛樻。鍗曡皟澧為暱涓旀案涓嶆敹缂╋紝鑰屾瘡鏍煎疄闄呰Е纰扮殑 signature 鍙湁鏈湴鍑犱釜銆俫eneration
        // stamp 璁╂棫鍊艰嚜鍔ㄥけ鏁堬細stamp 鏈懡涓殑妲戒綅涓€寰嬭涓?0锛屼笌娓呰〃鍚庣殑璇绘硶涓€鑷淬€?
        thread_local std::vector<uint32_t> sig_owner_stamp;
        thread_local uint32_t sig_owner_generation = 0;
        ++sig_owner_generation;
        if (sig_owner_stamp.size() < _signatures.size()) {
            sig_owner_retained.resize(_signatures.size(), 0);
            sig_owner_population.resize(_signatures.size(), 0);
            sig_owner_distributed.resize(_signatures.size(), 0);
            sig_owner_stamp.resize(_signatures.size(), 0);
        }
        if (sig_owner_generation == 0) {
            std::fill(sig_owner_stamp.begin(), sig_owner_stamp.end(), 0);
            sig_owner_generation = 1;
        }
        owner_filled_by_profession.assign(professions, 0);
        owner_population_by_profession.assign(professions, 0);
        owner_prefix_by_profession.assign(professions, 0);
        owner_distributed_by_profession.assign(professions, 0);
        owner_active_signatures.clear();
        for (int32_t g = first; g < last; ++g) {
            BuildingGroup &group = _buildings[g];
            if (group.cell != cell || group.count <= 0) continue;
            if (group.owner_signature_id < 0 ||
                group.owner_signature_id >= static_cast<int32_t>(_signatures.size())) continue;
            const int32_t profession =
                _signatures[group.owner_signature_id].profession_id;
            if (profession < 0 || profession >= professions ||
                profession == _unemployed_profession_id) continue;
            owner_filled_by_profession[profession] = saturating_add(
                owner_filled_by_profession[profession],
                std::max<int64_t>(0, group.filled_owner), _saturation_count);
        }
        population_store().for_each_in_cell(cell, [&](int32_t slot) {
            const int32_t sig = static_cast<int32_t>(population_store().signature_id[slot]);
            if (sig < 0 || sig >= static_cast<int32_t>(_signatures.size())) return;
            const int32_t profession = _signatures[sig].profession_id;
            if (profession < 0 || profession >= professions ||
                profession == _unemployed_profession_id) return;
            if (sig_owner_stamp[sig] != sig_owner_generation) {
                sig_owner_stamp[sig] = sig_owner_generation;
                sig_owner_population[sig] = 0;
                sig_owner_retained[sig] = 0;
                sig_owner_distributed[sig] = 0;
            }
            if (sig_owner_population[sig] == 0) owner_active_signatures.push_back(sig);
            const int64_t population = std::max<int64_t>(0,
                population_store().population[slot]);
            sig_owner_population[sig] = saturating_add(sig_owner_population[sig],
                population, _saturation_count);
            owner_population_by_profession[profession] = saturating_add(
                owner_population_by_profession[profession], population,
                _saturation_count);
        });
        std::sort(owner_active_signatures.begin(), owner_active_signatures.end());
        for (const int32_t sig : owner_active_signatures) {
            const int32_t profession = _signatures[sig].profession_id;
            owner_prefix_by_profession[profession] = saturating_add(
                owner_prefix_by_profession[profession], sig_owner_population[sig],
                _saturation_count);
            const int64_t next = owner_population_by_profession[profession] > 0
                ? mul_div_sat(owner_filled_by_profession[profession],
                    owner_prefix_by_profession[profession],
                    owner_population_by_profession[profession], _saturation_count)
                : 0;
            sig_owner_retained[sig] = std::max<int64_t>(0,
                next - owner_distributed_by_profession[profession]);
            owner_distributed_by_profession[profession] = next;
        }
        // employee 鍦ㄥ矖鎸?profession 绋冲畾搴忔憡娲惧埌鍚?slot锛堝悓 profession 鐨勫 eth
        // slot 鎸?signature_id 鍗囧簭锛岀敤 cohort 鍙绾抽噺姣斾緥鎽婃淳锛屽墠缂€鍜屼繚纭畾锛夈€?
        thread_local std::vector<int64_t> emp_prefix;
        thread_local std::vector<int64_t> emp_distributed;
        thread_local std::vector<int64_t> emp_capacity;   // 姣?profession 鍚?slot 鍙綋 employee 鐨勫閲忎箣鍜?
        emp_prefix.assign(professions, 0);
        emp_distributed.assign(professions, 0);
        emp_capacity.assign(professions, 0);
        // 绗竴閬嶏細绠楁瘡 profession 鐨?employee 瀹归噺鎬婚噺 = 危(population - owner_retained)銆?
        population_store().for_each_in_cell(cell, [&](int32_t slot) {
            if (is_merchant_slot(slot)) return;
            const int32_t sig = static_cast<int32_t>(population_store().signature_id[slot]);
            const int32_t p = _signatures[sig].profession_id;
            if (p == _unemployed_profession_id) return;
            const int64_t retained_here = sig_owner_stamp[sig] == sig_owner_generation
                ? sig_owner_retained[sig] : 0;
            const int64_t owner_here = std::min(retained_here,
                std::max<int64_t>(0, population_store().population[slot]));
            const int64_t cap = std::max<int64_t>(0, population_store().population[slot] - owner_here);
            emp_capacity[p] = saturating_add(emp_capacity[p], cap, _saturation_count);
        });
        // 绗簩閬嶏細鍙鏀堕泦姣忎釜 slot 鐨?surplus锛堣縼寰€姹狅級鍒扮紦鍐诧紝閬嶅巻鍚庣粺涓€杩佺Щ銆?
        // owner_retained 鎸?signature 鍦ㄥ slot 闂翠篃闇€绋冲畾搴忔憡娲撅紙鍚?signature 閫氬父
        // 鍙湁涓€涓?slot锛涘椤垫椂鎸夐亶鍘嗗簭锛屽墠缂€鍜屼繚纭畾锛夈€?
        thread_local std::vector<int32_t> shed_source_slots;   // surplus 鏉ユ簮 slot
        thread_local std::vector<int32_t> shed_dest_eth;       // 瀵瑰簲 eth锛堚啋 unemployed|eth锛?
        thread_local std::vector<int64_t> shed_pop;            // surplus 浜烘暟
        shed_source_slots.clear(); shed_dest_eth.clear(); shed_pop.clear();
        // Route B: merchant slots are no longer skipped wholesale. A merchant
        // slot may now carry a merchant-post owner (sig_owner_retained>0) that
        // must be aggregated/right-sized like any other owner. But the market
        // maker invariant (rebuild_merchant_ranges requires >=1 merchant per
        // populated cell) forbids shedding the last merchant, so a merchant
        // slot keeps a floor of max(owner_here, 1) retained. Non-merchant slots
        // are unchanged.
        population_store().for_each_in_cell(cell, [&](int32_t slot) {
            const int32_t sig = static_cast<int32_t>(population_store().signature_id[slot]);
            const int32_t p = _signatures[sig].profession_id;
            const int32_t eth = _signatures[sig].ethnicity_id;
            const int64_t pop = std::max<int64_t>(0, population_store().population[slot]);
            if (p == _unemployed_profession_id) {
                // 澶变笟 slot锛氭湰姝ヤ笉鍔紙瀹冩槸姹狅紝鎷涗汉姝ラ鎵嶄粠涓縼鍑猴級銆?
                return;
            }
            const bool merchant_here = is_merchant_slot(slot);
            // owner 鍦ㄦ湰 slot 鐨勪唤棰濓紙鍚?signature 澶?slot 鏃剁ǔ瀹氬簭鎽婃淳锛夈€?
            const bool sig_active = sig_owner_stamp[sig] == sig_owner_generation;
            const int64_t retained_here = sig_active ? sig_owner_retained[sig] : 0;
            const int64_t distributed_here = sig_active ? sig_owner_distributed[sig] : 0;
            const int64_t owner_here = std::min(
                std::max<int64_t>(0, retained_here - distributed_here), pop);
            if (sig_active)
                sig_owner_distributed[sig] = saturating_add(distributed_here,
                                                            owner_here, _saturation_count);
            if (merchant_here) {
                // 鍟嗕汉 slot 涓嶅仛 employee锛堜粎 owner 宀楋級锛涗繚搴?1 涓仛甯傚晢涓嶈銆?
                const int64_t retained = std::min(pop,
                    std::max<int64_t>(owner_here, pop > 0 ? 1 : 0));
                population_store().owner_employed[slot] = owner_here;
                population_store().employee_employed[slot] = 0;
                const int64_t surplus = std::max<int64_t>(0, pop - retained);
                if (surplus > 0 && eth >= 0 && eth < n_eth) {
                    shed_source_slots.push_back(slot);
                    shed_dest_eth.push_back(eth);
                    shed_pop.push_back(surplus);
                }
                return;
            }
            // employee 鍦ㄦ湰 slot 鐨勪唤棰濓細鎸夊閲忔瘮渚嬫憡娲?fill[p]銆?
            const int64_t cap_here = std::max<int64_t>(0, pop - owner_here);
            emp_prefix[p] = saturating_add(emp_prefix[p], cap_here, _saturation_count);
            const int64_t emp_next = emp_capacity[p] > 0
                ? mul_div_sat(fill[p], emp_prefix[p], emp_capacity[p], _saturation_count) : 0;
            const int64_t emp_here = std::max<int64_t>(0, emp_next - emp_distributed[p]);
            emp_distributed[p] = emp_next;
            const int64_t retained = std::min(pop, saturating_add(owner_here, emp_here,
                                                                   _saturation_count));
            population_store().owner_employed[slot] = owner_here;
            population_store().employee_employed[slot] = std::min(emp_here,
                std::max<int64_t>(0, pop - owner_here));
            const int64_t surplus = std::max<int64_t>(0, pop - retained);
            if (surplus > 0 && eth >= 0 && eth < n_eth) {
                shed_source_slots.push_back(slot);
                shed_dest_eth.push_back(eth);
                shed_pop.push_back(surplus);
            }
        });
        // Signature must be read before the moves below rewrite the slots.
        thread_local std::vector<int64_t> trace_shed_by_signature;
        if (trace_employment) {
            trace_shed_by_signature.assign(_signatures.size(), 0);
            for (size_t i = 0; i < shed_source_slots.size(); ++i) {
                const int32_t sig = static_cast<int32_t>(
                    population_store().signature_id[shed_source_slots[i]]);
                if (sig >= 0 && sig < static_cast<int32_t>(_signatures.size()))
                    trace_shed_by_signature[sig] += shed_pop[i];
            }
        }
        // 閬嶅巻澶栨墽琛屾瀽鍑鸿縼绉伙紙鍦ㄥ矖 profession|eth 鈫?unemployed|eth锛夈€?
        for (size_t i = 0; i < shed_source_slots.size(); ++i) {
            const int32_t src = shed_source_slots[i];
            const int32_t dest_sig = unemployed_signature_for_ethnicity(shed_dest_eth[i]);
            if (dest_sig < 0) continue;   // 鏃?unemployed signature锛堝悜鍚庡吋瀹癸級锛氱暀鍘?slot銆?
            if (dest_sig == static_cast<int32_t>(population_store().signature_id[src])) continue;
            bool drained = false;
            if (!move_cohort_population(src, cell, dest_sig, shed_pop[i], error, &drained)) {
                return false;
            }
        }

        // Knowledge work is deliberately a soft local cap: it blocks new
        // hiring/transfers once knowledge owners+employees reach 30% of the
        // living population, but does not evict incumbents when population
        // later falls.  Keep one slot available in tiny settlements so a
        // population of 1鈥? is not permanently barred from its first scribe.
        auto is_knowledge_group = [&](const BuildingGroup &group) -> bool {
            return group.type_id >= 0 &&
                group.type_id < static_cast<int32_t>(_building_types.size()) &&
                _building_types[static_cast<size_t>(group.type_id)].economic_sector == 4;
        };
        int64_t local_population_for_knowledge = 0;
        int64_t local_knowledge_employment = 0;
        population_store().for_each_in_cell(cell, [&](int32_t slot) {
            const int64_t pop = std::max<int64_t>(0, population_store().population[slot]);
            local_population_for_knowledge = saturating_add(
                local_population_for_knowledge, pop, _saturation_count);
        });
        // Count sector employment from the building graph rather than cohort
        // profession totals: one cohort may own/serve both knowledge and
        // non-knowledge groups, while the cap is about actual knowledge jobs.
        for (int32_t g = first; g < last; ++g) {
            const BuildingGroup &group = _buildings[g];
            if (group.cell != cell || !is_knowledge_group(group)) continue;
            local_knowledge_employment = saturating_add(
                local_knowledge_employment, std::max<int64_t>(0, group.filled_owner),
                _saturation_count);
            if (group.type_id < 0 || group.type_id >=
                    static_cast<int32_t>(_building_types.size())) continue;
            const BuildingType &type = _building_types[group.type_id];
            for (int32_t r = 0; r < type.employee_count; ++r) {
                const int32_t fill_index = group.employee_fill_begin + r;
                if (fill_index >= 0 && fill_index < static_cast<int32_t>(
                        _building_employee_filled.size())) {
                    local_knowledge_employment = saturating_add(
                        local_knowledge_employment,
                        std::max<int64_t>(0, _building_employee_filled[fill_index]),
                        _saturation_count);
                }
            }
        }
        const int64_t knowledge_cap = local_population_for_knowledge > 0
            ? std::max<int64_t>(1, mul_div_sat(
                local_population_for_knowledge, 30, 100, _saturation_count)) : 0;
        auto knowledge_slot_available = [&](const BuildingGroup &group,
                                            int64_t add, bool source_is_knowledge) {
            if (!is_knowledge_group(group) || source_is_knowledge) return true;
            return local_knowledge_employment < knowledge_cap &&
                add <= knowledge_cap - local_knowledge_employment;
        };

        // ---- 绗?姝?鎷涗汉锛氭寜 cell-local attraction 姣斾緥浠?unemployed 姹犲閲忚縼鍥?----
        // 浼樺厛绾ч敭锛?realized_profit_margin_q16 desc, planned_utilization_q16 desc,
        //            group_index asc)銆傛帓搴忕矑搴?璺?BuildingGroup锛堣法寤虹瓚绫诲瀷锛夛紱
        // 鍚?type_id+鍚?owner_signature 鑱氬悎鐨勭粍鍐呯泩鍒?鍒╃敤鐜囩浉鍚岋紝缁勫唴涓嶆帓锛堢ǔ瀹氬簭锛夈€?
        // 姹犲彲鐢ㄩ噺锛氭寜 eth 缂撳瓨鍚?unemployed|eth slot 鐨勫綋鍓嶄汉鍙ｄ笌 slot id銆?
        // 鎷?owner 闇€绮剧‘ eth锛坓roup.owner_signature 鐨?eth锛夛紱鎷?employee 鍙法 eth
        // 锛堟寜 eth 鍗囧簭鍙栨睜锛屼繚纭畾锛夈€傛嫑浜哄湪閬嶅巻澶栭€?group 鎵ц杩佺Щ锛屾瘡娆¤縼绉诲悗
        // 閲嶆柊瀹氫綅姹?slot锛堝彲鑳借 drain 閲婃斁锛夈€?
        auto pool_slot_for_eth = [&](int32_t eth) -> int32_t {
            const int32_t sig = unemployed_signature_for_ethnicity(eth);
            if (sig < 0) return -1;
            return population_store().find_signature(cell, static_cast<uint32_t>(sig));
        };
        const bool capture_employment_diagnostics = cell == _inspector_trace_cell;
        if (capture_employment_diagnostics) {
            _employment_diagnostic_cell = cell;
            _employment_diagnostic_day = _current_day;
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
            const int64_t income_term = choice_factor_q16(
                std::clamp<int64_t>(target_disposable, 0, Q16_ONE * 4));
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
                    if (_buildings[prior].count > 0) ++dense_group;
                diagnostic.group_index = dense_group;
                diagnostic.type_id = _buildings[option.group].type_id;
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
                        _buildings[option.group].owner_signature_id;
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
            const BuildingGroup &group = _buildings[g];
            const BuildingType &type = _building_types[group.type_id];
            const int64_t owner_need = std::max<int64_t>(0,
                group_owner_target[g - first] - group.filled_owner);
            if (owner_need > 0 && group.owner_signature_id >= 0 &&
                group.owner_signature_id < static_cast<int32_t>(_signatures.size())) {
                const int32_t owner_profession =
                    _signatures[group.owner_signature_id].profession_id;
                // Owner eligibility is profession-based.  Generate one target
                // signature per source ethnicity so migration preserves the
                // person's identity instead of forcing the building's
                // canonical ethnicity onto the cohort.
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
                    const int64_t target_disposable = wage -
                        living_cost_for_signature(cell, target_sig, -1,
                            _saturation_count);
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
            const int64_t target_cost = living_cost_for_signature(
                cell, candidate.target_signature, -1, _saturation_count);
            const int64_t source_disposable = unemployed_disposable_income(pool);
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
        for (size_t oi = 0; oi < hire_order.size(); ++oi) {
            const int32_t g = hire_order[oi];
            BuildingGroup &group = _buildings[g];
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
                    const bool eligible = target_disposable >= 0 && improvement >=
                        transition_hurdle_q16(source_profession, owner_profession);
                    const int64_t proportional = eligible
                        ? candidate_allocation(source_eth, g, -1, target_sig) : 0;
                    const int64_t take = std::min({owner_need, avail, proportional});
                    const bool knowledge_ok = knowledge_slot_available(group, take, false);
                    const int64_t capped_take = knowledge_ok
                        ? take : std::max<int64_t>(0, knowledge_cap -
                            local_knowledge_employment);
                    if (capped_take <= 0 || target_sig == static_cast<int32_t>(
                            population_store().signature_id[pool])) {
                        if (target_sig == static_cast<int32_t>(
                                population_store().signature_id[pool]))
                            drop(EMPLOYMENT_REJECTION_SIGNATURE_SELF);
                        else if (!knowledge_ok)
                            drop(EMPLOYMENT_REJECTION_KNOWLEDGE_CAP);
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
                    const uint64_t preferred_family =
                        preferred_family_for_cohort(pool, 1, 0, owner_profession);
                    if (!move_cohort_population(pool, cell, target_sig, capped_take,
                                                error, &drained, preferred_family)) {
                        return false;
                    }
                    group.filled_owner = saturating_add(group.filled_owner, capped_take,
                                                        _saturation_count);
                    owner_need = std::max<int64_t>(0, owner_need - capped_take);
                    if (is_knowledge_group(group)) {
                        local_knowledge_employment = saturating_add(
                            local_knowledge_employment, capped_take, _saturation_count);
                    }
                    const int32_t dest = population_store().find_signature(
                        cell, static_cast<uint32_t>(target_sig));
                    if (dest >= 0) {
                        population_store().owner_employed[dest] = saturating_add(
                            population_store().owner_employed[dest], capped_take,
                            _saturation_count);
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
                const int64_t gross_wage =
                    expected_employee_hiring_gross(role, fi);
                const int64_t expected_wage = expected_after_tax_income(
                    cell, p, gross_wage, _saturation_count);
                const int64_t role_target = planned_role_demand(
                    group, role, fi);
                int64_t need = std::max<int64_t>(0,
                    role_target - std::max<int64_t>(0, _building_employee_filled[fi]));
                if (need <= 0) continue;
                if (is_knowledge_group(group) &&
                    local_knowledge_employment >= knowledge_cap) {
                    drop_role_diagnostics(g, r, EMPLOYMENT_REJECTION_KNOWLEDGE_CAP);
                    continue;
                }
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
                    const int64_t target_cost = living_cost_for_signature(
                        cell, target_sig, -1, _saturation_count);
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
                    const bool eligible = expected_wage >= survival_floor &&
                        improvement >= transition_hurdle_q16(
                            source_profession, p);
                    const int64_t proportional = eligible
                        ? candidate_allocation(eth, g, r, target_sig) : 0;
                    const int64_t take = std::min({need, avail, proportional,
                        is_knowledge_group(group)
                            ? std::max<int64_t>(0, knowledge_cap -
                                local_knowledge_employment)
                            : need});
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
                    _building_employee_filled[fi] = saturating_add(
                        _building_employee_filled[fi], take, _saturation_count);
                    if (is_knowledge_group(group)) {
                        local_knowledge_employment = saturating_add(
                            local_knowledge_employment, take, _saturation_count);
                    }
                    const int32_t dest = population_store().find_signature(
                        cell, static_cast<uint32_t>(target_sig));
                    if (dest >= 0) {
                        population_store().employee_employed[dest] = saturating_add(
                            population_store().employee_employed[dest], take, _saturation_count);
                    }
                    need -= take;
                    budget = std::max<int64_t>(0, budget - take);
                }
            }
        }

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
                BuildingGroup &group = _buildings[group_index];
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
                    if (_building_employee_filled[fill_index] > 0) {
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
                    if (improvement < transition_hurdle_q16(
                            source.profession, target.profession)) {
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
                            population_store().employee_employed[source_slot] =
                                std::max<int64_t>(0,
                                    population_store().employee_employed[
                                        source_slot] - 1);
                        }
                        const int32_t destination =
                            population_store().find_signature(
                                cell, static_cast<uint32_t>(target_signature));
                        if (destination < 0) {
                            error =
                                "employee_job_reallocation_destination_missing";
                            return false;
                        }
                        population_store().employee_employed[destination] =
                            saturating_add(
                                population_store().employee_employed[destination],
                                1, _saturation_count);
                        ++_building_employee_job_profession_changes;
                    }
                    --_building_employee_filled[source.fill_index];
                    _building_employee_filled[target.fill_index] =
                        saturating_add(
                            _building_employee_filled[target.fill_index], 1,
                            _saturation_count);
                    ++_building_employee_job_reallocations;
                    break;
                }
                if (source_cursor >= employee_sources.size()) break;
            }
        }

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
            const BuildingGroup &group = _buildings[g];
            if (group.cell != cell || group.count <= 0 ||
                group.operating_state == 1 ||
                !building_available(cell, group.type_id, true)) continue;
            const BuildingType &type = _building_types[group.type_id];
            if (group.owner_signature_id < 0 ||
                group.owner_signature_id >= static_cast<int32_t>(_signatures.size())) continue;
            const int64_t income = owner_mobility_income(
                group, _saturation_count);
            projected_owner_income[g - first] = income;
            const int64_t owner_target = group_owner_target[g - first];
            if (type.kind != 2 && group.filled_owner < owner_target) {
                if (income > 0) owner_job_targets.push_back(g);
            }
            // Opportunity-gradient sources: any ACTIVE lot that still has an
            // attached owner may lose one person to a higher-opportunity
            // vacancy. The matching loop applies asymmetric hysteresis so two
            // understaffed positive-income lots cannot thrash on noise, while
            // leaving non-positive opportunity lots stays on the base hurdle.
            // The final local merchant remains protected below.
            if (group.filled_owner > 0 && owner_target > 0) {
                const int32_t source_slot = owner_slot_for_profession(
                    _signatures[group.owner_signature_id].profession_id);
                if (source_slot >= 0 && population_store().owner_employed[source_slot] > 0) {
                    owner_job_sources.push_back(g);
                    owner_job_source_understaffed.push_back(
                        group.filled_owner < owner_target ? uint8_t{1} : uint8_t{0});
                }
            }
            for (int32_t r = 0; r < type.employee_count; ++r) {
                const int32_t fill_index = group.employee_fill_begin + r;
                if (_building_employee_filled[fill_index] <= 0) continue;
                const JobRole &role = _building_employee_roles[type.employee_begin + r];
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
        for (int32_t target_group_index : owner_job_targets) {
            if (owner_job_group_used[target_group_index - first] != 0) continue;
            BuildingGroup &target_group = _buildings[target_group_index];
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
            for (size_t source_i = 0; source_i < owner_job_sources.size();
                 ++source_i) {
                const int32_t candidate = owner_job_sources[source_i];
                if (candidate == target_group_index ||
                    owner_job_group_used[candidate - first] != 0) continue;
                const BuildingGroup &source_group = _buildings[candidate];
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
                const bool source_is_knowledge = is_knowledge_group(source_group);
                if (!knowledge_slot_available(target_group, 1,
                                              source_is_knowledge)) continue;
                const int64_t source_cost = living_cost_for_signature(
                    cell, source_group.owner_signature_id, -1,
                    _saturation_count);
                const int64_t improvement = improvement_q16(
                    source_income, target_income);
                const int64_t base_hurdle = transition_hurdle_q16(
                    source_signature.profession_id, target_owner_profession);
                // Asymmetric hysteresis: easy exit from non-positive opportunity,
                // raised bar only for understaffed鈫抲nderstaffed with positive
                // source income (the historical thrash pair).
                int64_t effective_hurdle = base_hurdle;
                const bool source_understaffed =
                    source_i < owner_job_source_understaffed.size() &&
                    owner_job_source_understaffed[source_i] != 0;
                if (!(source_income <= 0 && target_income > 0) &&
                    source_understaffed && source_income > 0) {
                    effective_hurdle = mul_div_sat(
                        base_hurdle,
                        std::max<int32_t>(Q16_ONE,
                            _employment_understaffed_reallocation_hurdle_mult_q16),
                        Q16_ONE, _saturation_count);
                }
                if (improvement < effective_hurdle) continue;
                if (source_signature.profession_id == _merchant_profession_id &&
                    local_merchant_population <= 1) continue;
                if (source_signature.profession_id != target_signature.profession_id) {
                    const int64_t source_population = std::max<int64_t>(1,
                        population_store().population[source_slot_candidate]);
                    const int64_t source_reserve = saturating_mul(saturating_mul(
                        source_cost, source_population, _saturation_count), 30,
                        _saturation_count);
                    const int64_t transferable = std::max<int64_t>(0,
                        population_store().funds[source_slot_candidate] - source_reserve);
                    if (transferable < owner_entry_capital(target_group)) continue;
                }
                source_group_index = candidate;
                source_slot = source_slot_candidate;
                source_target_signature = candidate_target_signature;
                matched_understaffed_source = source_understaffed;
                break;
            }
            if (source_group_index >= 0) {
                BuildingGroup &source_group = _buildings[source_group_index];
                const bool source_is_knowledge = is_knowledge_group(source_group);
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
                        population_store().owner_employed[source_slot] = std::max<int64_t>(
                            0, population_store().owner_employed[source_slot] - 1);
                    }
                    const int32_t destination = population_store().find_signature(
                        cell, static_cast<uint32_t>(source_target_signature));
                    if (destination < 0) {
                        error = "owner_job_reallocation_destination_missing";
                        return false;
                    }
                    population_store().owner_employed[destination] = saturating_add(
                        population_store().owner_employed[destination], 1,
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
                if (source_is_knowledge != is_knowledge_group(target_group)) {
                    local_knowledge_employment = std::max<int64_t>(0,
                        local_knowledge_employment +
                        (is_knowledge_group(target_group) ? 1 : -1));
                }
                {
                    int64_t realloc_sat = 0;
                    if (owner_opportunity_quote(target_group, Q16_ONE, Q16_ONE,
                            realloc_sat).survival_priority)
                        ++_building_owner_survival_reallocations;
                    _saturation_count = saturating_add(_saturation_count,
                        realloc_sat, _saturation_count);
                }
                owner_job_group_used[source_group_index - first] = 1;
                owner_job_group_used[target_group_index - first] = 1;
                ++_building_owner_job_reallocations;
                if (matched_understaffed_source)
                    ++_building_owner_understaffed_reallocations;
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
                const BuildingGroup &source_group = _buildings[candidate.group];
                const bool source_is_knowledge = is_knowledge_group(source_group);
                if (!knowledge_slot_available(target_group, 1,
                                              source_is_knowledge)) continue;
                int32_t source_signature_id = -1;
                int32_t employee_slot = -1;
                int64_t source_cost = 0;
                bool candidate_eligible = false;
                // Employee cohorts retain their ethnicity while moving into
                // the target owner profession. Search all local ethnicities;
                // the first eligible slot is deterministic and no ethnicity
                // equality with the building profile is required.
                for (int32_t source_eth = 0; source_eth < n_eth; ++source_eth) {
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
                    const int64_t candidate_source_cost = living_cost_for_signature(
                        cell, candidate_source_signature, -1, _saturation_count);
                    const int64_t candidate_current_disposable = candidate.income -
                        std::max(candidate_source_cost,
                            recent_expense_per_day(candidate_employee_slot));
                    const int64_t candidate_improvement = improvement_q16(
                        candidate_current_disposable, target_income);
                    if (candidate_improvement < transition_hurdle_q16(
                            candidate.profession, target_owner_profession)) continue;
                    source_signature_id = candidate_source_signature;
                    employee_slot = candidate_employee_slot;
                    selected_employee_target_signature = candidate_target_signature;
                    source_cost = candidate_source_cost;
                    candidate_eligible = true;
                    break;
                }
                if (!candidate_eligible) continue;
                // Even a same-profession employee鈫抩wner move opens a new
                // business position and therefore needs the target reserve;
                // only the counter update differs from a profession change.
                const int64_t source_population = std::max<int64_t>(1,
                    population_store().population[employee_slot]);
                const int64_t source_reserve = saturating_mul(saturating_mul(
                    source_cost, source_population, _saturation_count), 30,
                    _saturation_count);
                const int64_t transferable = std::max<int64_t>(0,
                    population_store().funds[employee_slot] - source_reserve);
                if (transferable < owner_entry_capital(target_group)) continue;

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
                        population_store().employee_employed[employee_slot] =
                            std::max<int64_t>(0,
                                population_store().employee_employed[employee_slot] - 1);
                    }
                    const int32_t destination = population_store().find_signature(
                        cell, static_cast<uint32_t>(selected_employee_target_signature));
                    if (destination < 0) {
                        error = "employee_owner_reallocation_destination_missing";
                        return false;
                    }
                    population_store().owner_employed[destination] = saturating_add(
                        population_store().owner_employed[destination], 1,
                        _saturation_count);
                    ++_building_owner_job_profession_changes;
                } else {
                    population_store().employee_employed[employee_slot] -= 1;
                    population_store().owner_employed[employee_slot] = saturating_add(
                        population_store().owner_employed[employee_slot], 1,
                        _saturation_count);
                }
                _building_employee_filled[candidate.fill_index] -= 1;
                target_group.filled_owner = saturating_add(
                    target_group.filled_owner, 1, _saturation_count);
                if (source_is_knowledge != is_knowledge_group(target_group)) {
                    local_knowledge_employment = std::max<int64_t>(0,
                        local_knowledge_employment +
                        (is_knowledge_group(target_group) ? 1 : -1));
                }
                {
                    int64_t realloc_sat = 0;
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
    }
    int64_t local_owner = 0;
    int64_t local_employee = 0;
    int64_t local_unemployed = 0;
    population_store().for_each_in_cell(cell, [&](int32_t slot) {
        local_owner = saturating_add(local_owner, population_store().owner_employed[slot],
                                     _saturation_count);
        local_employee = saturating_add(local_employee, population_store().employee_employed[slot],
                                        _saturation_count);
        const int64_t unemployed = std::max<int64_t>(
            0, population_store().population[slot] - population_store().owner_employed[slot] -
               population_store().employee_employed[slot]);
        local_unemployed = saturating_add(local_unemployed, unemployed, _saturation_count);
    });
    replace_employment_metrics_for_cell(
        cell, local_owner, local_employee, local_unemployed);
    bool employment_identity_valid = true;
    population_store().for_each_in_cell(cell, [&](int32_t slot) {
        if (is_merchant_slot(slot)) return;
        const int32_t signature = static_cast<int32_t>(population_store().signature_id[slot]);
        if (signature < 0 || signature >= static_cast<int32_t>(_signatures.size())) {
            employment_identity_valid = false;
            return;
        }
        if (_signatures[signature].profession_id == _unemployed_profession_id) return;
        const int64_t employed = saturating_add(
            std::max<int64_t>(0, population_store().owner_employed[slot]),
            std::max<int64_t>(0, population_store().employee_employed[slot]),
            _saturation_count);
        if (employed != std::max<int64_t>(0, population_store().population[slot])) {
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
            if (!population_store().valid_handle(trace_handles[i], slot)) {
                // 璇?cohort 宸茶 A1 杩佺Щ瀹屽叏 drain锛堜緥濡傛暣鑱屼笟瑁佸厜杩涙睜骞堕噴鏀撅級锛?
                // 璁颁负褰掗浂 leg锛宻ubject 鐢ㄥ揩鐓?handle锛屼究浜庡璁￠棴鍚堛€?
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
            if (trace_owner_before[i] != population_store().owner_employed[slot]) {
                event_legs.push_back({FIELD_COHORT_OWNER_EMPLOYED, SUBJECT_COHORT, handle,
                                      -1, trace_owner_before[i],
                                      population_store().owner_employed[slot]});
            }
            if (trace_employee_before[i] != population_store().employee_employed[slot]) {
                event_legs.push_back({FIELD_COHORT_EMPLOYEE_EMPLOYED, SUBJECT_COHORT, handle,
                                      -1, trace_employee_before[i],
                                      population_store().employee_employed[slot]});
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
