#include "economy_runtime.h"
#include "economy_runtime_variant_helpers.h"

#include <algorithm>
#include <array>
#include <limits>
#include <numeric>
#include <vector>

#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>
#include <godot_cpp/variant/packed_int32_array.hpp>
#include <godot_cpp/variant/packed_int64_array.hpp>
#include <godot_cpp/variant/packed_string_array.hpp>
#include <godot_cpp/variant/variant.hpp>

namespace pk {

using namespace godot;
using namespace variant_helpers;

namespace {

constexpr int32_t OVERVIEW_SECTOR_COUNT = 5;
constexpr int32_t OVERVIEW_REJECTION_COUNT = 19;
constexpr int32_t OVERVIEW_MAX_ROWS = 512;

int32_t clamp_q16(int64_t weighted, int64_t weight) {
    if (weight <= 0) return 0;
    return static_cast<int32_t>(std::clamp<int64_t>(
        weighted / weight, 0, std::numeric_limits<int32_t>::max()));
}

PackedInt64Array pack_i64(const std::vector<int64_t> &values) {
    PackedInt64Array out;
    out.resize(static_cast<int64_t>(values.size()));
    for (size_t i = 0; i < values.size(); ++i)
        out.set(static_cast<int64_t>(i), values[i]);
    return out;
}

PackedInt32Array pack_i32(const std::vector<int32_t> &values) {
    PackedInt32Array out;
    out.resize(static_cast<int64_t>(values.size()));
    for (size_t i = 0; i < values.size(); ++i)
        out.set(static_cast<int64_t>(i), values[i]);
    return out;
}

// Population-side totals for one aggregation bucket. Period values are the raw
// cohort epoch ledgers; *_day values divide each cell by its own elapsed days.
struct PopulationBucket {
    int64_t population = 0;
    int64_t cohorts = 0;
    int64_t owner_employed = 0;
    int64_t employee_employed = 0;
    int64_t unemployed = 0;
    int64_t funds = 0;
    int64_t epoch_income = 0;
    int64_t epoch_expense = 0;
    int64_t income_day = 0;
    int64_t expense_day = 0;
    int64_t tax_day = 0;
    int64_t subsidy_day = 0;
    int64_t in_kind_day = 0;
    int64_t composite_weighted = 0;
    int64_t survival_weighted = 0;
    std::array<int64_t, NativeEconomyRuntime::SAT_DIM_COUNT> dims_weighted{};
    std::array<int64_t, NativeEconomyRuntime::SAT_DIM_COUNT> dims_population{};
};

// Building-side totals for one aggregation bucket, all normalized per day.
struct BuildingBucket {
    int64_t units = 0;
    int64_t suspended_units = 0;
    int64_t groups = 0;
    int64_t revenue_day = 0;
    int64_t input_cost_day = 0;
    int64_t wages_paid_day = 0;
    int64_t wages_due_day = 0;
    int64_t maintenance_day = 0;
    int64_t business_tax_day = 0;
    int64_t producer_support_day = 0;
    int64_t output_day = 0;
    int64_t sold_day = 0;
    int64_t discarded_day = 0;
    int64_t climate_lost_day = 0;
    int64_t utilization_weighted = 0;
    int64_t capacity_weighted = 0;
    int64_t jobs_required = 0;
    int64_t jobs_filled = 0;
    int64_t pending_units = 0;
    std::array<int64_t, OVERVIEW_REJECTION_COUNT> rejection_units{};
};

} // namespace

Dictionary NativeEconomyRuntime::country_economy_overview(
        int64_t country_handle, const String &view, int32_t scope_cell,
        int32_t filter_id, int32_t offset, int32_t limit) const {
    static_assert(OVERVIEW_REJECTION_COUNT ==
                  INVESTMENT_REJECTION_NO_COST_ADVANTAGE + 1,
                  "overview rejection histogram must cover every reason");
    Dictionary out;
    out["country_handle"] = country_handle;
    out["view"] = view;
    out["scope_cell"] = scope_cell;
    out["filter_id"] = filter_id;
    out["committed"] = !_epoch_active && !_fatal;
    out["busy"] = _epoch_active;
    out["snapshot_source"] = "rolling_committed";
    if (!_configured || !_bootstrapped) {
        out["ok"] = false;
        out["reason"] = !_configured ? "economy_not_configured"
                                     : "economy_not_bootstrapped";
        return out;
    }
    const auto found = std::find(_epoch_country_handles.begin(),
        _epoch_country_handles.end(), static_cast<uint64_t>(country_handle));
    if (country_handle == 0 || found == _epoch_country_handles.end()) {
        out["ok"] = false;
        out["reason"] = "country_handle_invalid";
        return out;
    }
    const int32_t country = static_cast<int32_t>(
        found - _epoch_country_handles.begin());
    const int32_t cell_count = _cell_count.get();
    const auto cell_in_country = [&](int32_t cell) {
        return cell >= 0 && cell < cell_count &&
            cell < static_cast<int32_t>(_epoch_cell_country.size()) &&
            _epoch_cell_country[static_cast<size_t>(cell)] == country;
    };
    if (scope_cell >= 0 && !cell_in_country(scope_cell)) {
        out["ok"] = false;
        out["reason"] = "cell_not_in_country";
        return out;
    }

    std::vector<int32_t> cells;
    if (scope_cell >= 0) {
        cells.push_back(scope_cell);
    } else {
        for (int32_t cell = 0; cell < cell_count; ++cell)
            if (cell_in_country(cell)) cells.push_back(cell);
    }
    const bool building_csr = _building_cell_offsets.size() ==
        static_cast<size_t>(cell_count) + 1U;
    const auto group_begin = [&](int32_t cell) {
        return building_csr ? _building_cell_offsets[static_cast<size_t>(cell)] : 0;
    };
    const auto group_end = [&](int32_t cell) {
        return building_csr ? _building_cell_offsets[static_cast<size_t>(cell) + 1U] : 0;
    };

    int64_t sat = 0;
    int64_t state_day_min = std::numeric_limits<int64_t>::max();
    int64_t state_day_max = std::numeric_limits<int64_t>::min();
    int32_t populated_cells = 0;
    const int32_t need_count = static_cast<int32_t>(_need_ids.size());
    const int32_t profession_count = static_cast<int32_t>(_profession_ids.size());
    const int32_t type_count = static_cast<int32_t>(_building_types.size());
    const int32_t good_count = market_store().good_count.get();

    const auto add = [&](int64_t &target, int64_t value) {
        target = saturating_add(target, value, sat);
    };
    const auto weigh = [&](int64_t &target, int64_t value, int64_t weight) {
        target = saturating_add(target, saturating_mul(value, weight, sat), sat);
    };
    const auto accumulate_cohort = [&](PopulationBucket &bucket, int32_t slot,
                                       int64_t days) {
        const auto &store = population_store();
        const size_t s = static_cast<size_t>(slot);
        const int64_t people = std::max<int64_t>(0, store.population[s]);
        add(bucket.population, people);
        ++bucket.cohorts;
        const int64_t owner = std::max<int64_t>(0, store.owner_employed[s]);
        const int64_t employee = std::max<int64_t>(0, store.employee_employed[s]);
        add(bucket.owner_employed, owner);
        add(bucket.employee_employed, employee);
        add(bucket.unemployed, std::max<int64_t>(0, people - owner - employee));
        add(bucket.funds, store.funds[s]);
        add(bucket.epoch_income, store.epoch_income[s]);
        add(bucket.epoch_expense, store.epoch_expense[s]);
        add(bucket.income_day, store.epoch_income[s] / days);
        add(bucket.expense_day, store.epoch_expense[s] / days);
        add(bucket.tax_day, store.epoch_tax_paid[s] / days);
        add(bucket.subsidy_day, store.epoch_subsidy_received[s] / days);
        add(bucket.in_kind_day, store.epoch_in_kind_income[s] / days);
        weigh(bucket.composite_weighted,
              static_cast<int64_t>(store.composite_satisfaction[s]), people);
        weigh(bucket.survival_weighted,
              static_cast<int64_t>(store.needs_satisfaction[s]), people);
        const size_t dims_base = s * static_cast<size_t>(SAT_DIM_COUNT);
        const uint8_t mask = satisfaction_applicable_mask(slot);
        for (int32_t dim = 0; dim < SAT_DIM_COUNT; ++dim) {
            if (!(mask & (1U << dim))) continue;
            add(bucket.dims_population[dim], people);
            weigh(bucket.dims_weighted[static_cast<size_t>(dim)],
                  static_cast<int64_t>(store.satisfaction_dims[
                      dims_base + static_cast<size_t>(dim)]), people);
        }
    };
    const auto accumulate_group = [&](BuildingBucket &bucket,
                                      BuildingGroupConstRef group,
                                      int64_t days) {
        if (group.count <= 0) return;
        add(bucket.units, group.count);
        ++bucket.groups;
        if (group.operating_state == 1) add(bucket.suspended_units, group.count);
        add(bucket.revenue_day, group.last_revenue / days);
        add(bucket.input_cost_day, group.last_input_cost / days);
        add(bucket.wages_paid_day, group.last_wages_paid / days);
        add(bucket.wages_due_day, group.last_wages_due / days);
        add(bucket.maintenance_day, group.last_maintenance_cost / days);
        add(bucket.business_tax_day, group.last_business_tax_paid / days);
        add(bucket.producer_support_day,
            group.last_producer_support_receipt / days);
        add(bucket.output_day, group.last_output / days);
        add(bucket.sold_day, group.last_sold / days);
        add(bucket.discarded_day, group.last_discarded / days);
        add(bucket.climate_lost_day, group.last_climate_lost_output / days);
        weigh(bucket.utilization_weighted, group.operating_state == 1 ? 0 :
              std::clamp<int64_t>(group.planned_utilization_q16, 0, Q16_ONE),
              group.count);
        weigh(bucket.capacity_weighted,
              std::clamp<int64_t>(group.last_capacity_q16, 0, Q16_ONE),
              group.count);
        group_job_totals(group, bucket.jobs_required, bucket.jobs_filled, sat);
        const size_t row = group.index;
        const int32_t reason = row < _building_investment_rejection.size()
            ? _building_investment_rejection[row] : INVESTMENT_REJECTION_NONE;
        if (reason > INVESTMENT_REJECTION_NONE && reason < OVERVIEW_REJECTION_COUNT)
            add(bucket.rejection_units[static_cast<size_t>(reason)], group.count);
    };
    const auto note_state_day = [&](int32_t cell) {
        if (cell >= static_cast<int32_t>(_cell_last_settlement_day.size())) return;
        const int64_t day = _cell_last_settlement_day[cell];
        state_day_min = std::min(state_day_min, day);
        state_day_max = std::max(state_day_max, day);
    };
    const auto cell_population = [&](int32_t cell) {
        return cell < static_cast<int32_t>(_committed_cells.size())
            ? _committed_cells[static_cast<size_t>(cell)].population
            : population_total_for_cell(cell);
    };
    const auto pack_population = [&](Dictionary &target,
                                     const PopulationBucket &bucket) {
        target["population"] = bucket.population;
        target["cohort_count"] = bucket.cohorts;
        target["owner_employed"] = bucket.owner_employed;
        target["employee_employed"] = bucket.employee_employed;
        target["unemployed"] = bucket.unemployed;
        target["funds"] = bucket.funds;
        target["epoch_income"] = bucket.epoch_income;
        target["epoch_expense"] = bucket.epoch_expense;
        target["income_per_day"] = bucket.income_day;
        target["expense_per_day"] = bucket.expense_day;
        target["tax_per_day"] = bucket.tax_day;
        target["subsidy_per_day"] = bucket.subsidy_day;
        target["in_kind_income_per_day"] = bucket.in_kind_day;
        target["satisfaction_q16"] =
            clamp_q16(bucket.composite_weighted, bucket.population);
        target["survival_satisfaction_q16"] =
            clamp_q16(bucket.survival_weighted, bucket.population);
        PackedInt32Array dims;
        PackedInt64Array dims_population;
        for (int32_t dim = 0; dim < SAT_DIM_COUNT; ++dim)
            dims_population.push_back(bucket.dims_population[dim]);
        for (int32_t dim = 0; dim < SAT_DIM_COUNT; ++dim)
            dims.push_back(bucket.dims_population[dim] > 0 ? clamp_q16(bucket.dims_weighted[dim],
                                     bucket.dims_population[dim]) : -1);
        target["satisfaction_dims_q16"] = dims;
        target["satisfaction_dims_population"] = dims_population;
    };
    const auto finish = [&](Dictionary &target) {
        target["ok"] = true;
        target["territory_cell_count"] = static_cast<int64_t>(cells.size());
        target["populated_cell_count"] = populated_cells;
        target["state_day_min"] = state_day_min == std::numeric_limits<int64_t>::max()
            ? int64_t{-1} : state_day_min;
        target["state_day_max"] = state_day_max == std::numeric_limits<int64_t>::min()
            ? int64_t{-1} : state_day_max;
        target["epoch_id"] = _epoch_id.get();
        target["committed_generation"] = static_cast<int64_t>(_committed_generation);
        target["settlement_revision"] = _settlements.revision;
        target["sample_day"] = _sample_day;
        target["saturation_count"] = sat;
    };

    if (view == "summary") {
        PopulationBucket population;
        PopulationBucket merchants;
        BuildingBucket buildings;
        std::array<BuildingBucket, OVERVIEW_SECTOR_COUNT> sectors{};
        std::vector<int64_t> worst_need_population(
            static_cast<size_t>(std::max(0, need_count)), 0);
        int64_t merchant_inventory_value = 0;
        int64_t named_settlements = 0;
        int32_t max_tier = 0;
        for (const int32_t cell : cells) {
            const int64_t days = cell_elapsed_days(cell);
            if (cell_population(cell) > 0) {
                ++populated_cells;
                note_state_day(cell);
            }
            population_store().for_each_in_cell(cell, [&](int32_t slot) {
                accumulate_cohort(population, slot, days);
                if (is_merchant_slot(slot)) accumulate_cohort(merchants, slot, days);
                const uint16_t worst = population_store().worst_need_id[
                    static_cast<size_t>(slot)];
                if (worst < worst_need_population.size())
                    add(worst_need_population[worst], std::max<int64_t>(
                        0, population_store().population[static_cast<size_t>(slot)]));
            });
            for (int32_t g = group_begin(cell); g < group_end(cell); ++g) {
                const auto group = building_view(static_cast<size_t>(g));
                if (group.cell != cell || group.type_id < 0 ||
                    group.type_id >= type_count) continue;
                accumulate_group(buildings, group, days);
                const int32_t sector = _building_types[
                    static_cast<size_t>(group.type_id)].economic_sector;
                if (sector >= 0 && sector < OVERVIEW_SECTOR_COUNT)
                    accumulate_group(sectors[static_cast<size_t>(sector)], group, days);
            }
            const int32_t market = market_store().cell_to_market[cell];
            if (market >= 0) {
                for (int32_t good = 0; good < good_count; ++good) {
                    const int64_t index = market_store().index(market, good);
                    add(merchant_inventory_value, mul_div_sat(
                        std::max<int64_t>(0, market_store().stock[index]),
                        std::max<int64_t>(0, market_store().price[index]),
                        GOODS_SCALE, sat));
                }
            }
            if (cell < static_cast<int32_t>(_settlements.tier.size())) {
                max_tier = std::max<int32_t>(max_tier, _settlements.tier[cell]);
                if (_settlements.name_active[cell] != 0) ++named_settlements;
            }
        }
        for (const auto pending : pending_construction()) {
            if (pending.count <= 0) continue;
            if (scope_cell >= 0 ? pending.cell != scope_cell
                                : !cell_in_country(pending.cell)) continue;
            add(buildings.pending_units, pending.count);
            if (pending.type_id >= 0 && pending.type_id < type_count) {
                const int32_t sector = _building_types[
                    static_cast<size_t>(pending.type_id)].economic_sector;
                if (sector >= 0 && sector < OVERVIEW_SECTOR_COUNT)
                    add(sectors[static_cast<size_t>(sector)].pending_units, pending.count);
            }
        }
        pack_population(out, population);
        out["merchant_population"] = merchants.population;
        out["merchant_funds"] = merchants.funds;
        out["merchant_inventory_value"] = merchant_inventory_value;
        out["job_capacity"] = buildings.jobs_required;
        out["jobs_filled"] = buildings.jobs_filled;
        out["job_openings"] = std::max<int64_t>(
            0, buildings.jobs_required - buildings.jobs_filled);
        out["building_units"] = buildings.units;
        out["building_suspended_units"] = buildings.suspended_units;
        out["building_groups"] = buildings.groups;
        out["pending_construction_units"] = buildings.pending_units;
        out["revenue_per_day"] = buildings.revenue_day;
        out["input_cost_per_day"] = buildings.input_cost_day;
        out["wages_paid_per_day"] = buildings.wages_paid_day;
        out["wages_due_per_day"] = buildings.wages_due_day;
        out["maintenance_per_day"] = buildings.maintenance_day;
        out["business_tax_per_day"] = buildings.business_tax_day;
        out["producer_support_per_day"] = buildings.producer_support_day;
        out["output_per_day"] = buildings.output_day;
        out["sold_per_day"] = buildings.sold_day;
        out["discarded_per_day"] = buildings.discarded_day;
        out["climate_lost_per_day"] = buildings.climate_lost_day;
        out["utilization_q16"] = clamp_q16(buildings.utilization_weighted,
                                           buildings.units);
        out["capacity_q16"] = clamp_q16(buildings.capacity_weighted, buildings.units);
        std::vector<int64_t> sector_units, sector_suspended, sector_revenue,
            sector_cost, sector_wages, sector_jobs_required, sector_jobs_filled,
            sector_pending;
        std::vector<int32_t> sector_utilization, sector_capacity;
        for (const BuildingBucket &bucket : sectors) {
            sector_units.push_back(bucket.units);
            sector_suspended.push_back(bucket.suspended_units);
            sector_revenue.push_back(bucket.revenue_day);
            int64_t cost = 0;
            add(cost, bucket.input_cost_day);
            add(cost, bucket.wages_paid_day);
            add(cost, bucket.maintenance_day);
            sector_cost.push_back(cost);
            sector_wages.push_back(bucket.wages_paid_day);
            sector_jobs_required.push_back(bucket.jobs_required);
            sector_jobs_filled.push_back(bucket.jobs_filled);
            sector_pending.push_back(bucket.pending_units);
            sector_utilization.push_back(clamp_q16(bucket.utilization_weighted,
                                                   bucket.units));
            sector_capacity.push_back(clamp_q16(bucket.capacity_weighted, bucket.units));
        }
        out["sector_units"] = pack_i64(sector_units);
        out["sector_suspended_units"] = pack_i64(sector_suspended);
        out["sector_revenue_per_day"] = pack_i64(sector_revenue);
        out["sector_cost_per_day"] = pack_i64(sector_cost);
        out["sector_wages_per_day"] = pack_i64(sector_wages);
        out["sector_jobs_required"] = pack_i64(sector_jobs_required);
        out["sector_jobs_filled"] = pack_i64(sector_jobs_filled);
        out["sector_pending_units"] = pack_i64(sector_pending);
        out["sector_utilization_q16"] = pack_i32(sector_utilization);
        out["sector_capacity_q16"] = pack_i32(sector_capacity);
        PackedStringArray need_ids;
        for (const std::string &id : _need_ids) need_ids.push_back(from_utf8(id));
        out["need_ids"] = need_ids;
        out["worst_need_population"] = pack_i64(worst_need_population);
        out["named_settlement_count"] = named_settlements;
        out["max_prosperity_tier"] = max_tier;
        finish(out);
        return out;
    }

    if (view == "professions") {
        std::vector<PopulationBucket> buckets(static_cast<size_t>(std::max(0, profession_count)));
        std::vector<int64_t> worst_needs(static_cast<size_t>(
            std::max(0, profession_count)) * static_cast<size_t>(std::max(0, need_count)), 0);
        std::vector<int64_t> cell_presence(static_cast<size_t>(std::max(0, profession_count)), 0);
        std::vector<int32_t> last_cell(static_cast<size_t>(std::max(0, profession_count)), -1);
        for (const int32_t cell : cells) {
            const int64_t days = cell_elapsed_days(cell);
            if (cell_population(cell) > 0) {
                ++populated_cells;
                note_state_day(cell);
            }
            population_store().for_each_in_cell(cell, [&](int32_t slot) {
                const uint32_t signature = population_store().signature_id[
                    static_cast<size_t>(slot)];
                if (signature >= _signatures.size()) return;
                const int32_t profession = _signatures[signature].profession_id;
                if (profession < 0 || profession >= profession_count) return;
                const size_t p = static_cast<size_t>(profession);
                accumulate_cohort(buckets[p], slot, days);
                if (last_cell[p] != cell &&
                    population_store().population[static_cast<size_t>(slot)] > 0) {
                    last_cell[p] = cell;
                    ++cell_presence[p];
                }
                const uint16_t worst = population_store().worst_need_id[
                    static_cast<size_t>(slot)];
                if (worst < static_cast<uint32_t>(need_count))
                    add(worst_needs[p * static_cast<size_t>(need_count) + worst],
                        std::max<int64_t>(0, population_store().population[
                            static_cast<size_t>(slot)]));
            });
        }
        PackedInt32Array profession_indices;
        PackedStringArray stable_ids;
        PackedInt64Array population, cohorts, cells_present, owner, employee,
            unemployed, funds, epoch_income, epoch_expense, income, expense, tax,
            subsidy, in_kind, worst_need_population;
        PackedInt32Array satisfaction, survival, dims;
        PackedInt64Array dims_population;
        for (int32_t profession = 0; profession < profession_count; ++profession) {
            const PopulationBucket &bucket = buckets[static_cast<size_t>(profession)];
            if (bucket.cohorts <= 0) continue;
            profession_indices.push_back(profession);
            stable_ids.push_back(from_utf8(_profession_ids[profession]));
            population.push_back(bucket.population);
            cohorts.push_back(bucket.cohorts);
            cells_present.push_back(cell_presence[static_cast<size_t>(profession)]);
            owner.push_back(bucket.owner_employed);
            employee.push_back(bucket.employee_employed);
            unemployed.push_back(bucket.unemployed);
            funds.push_back(bucket.funds);
            epoch_income.push_back(bucket.epoch_income);
            epoch_expense.push_back(bucket.epoch_expense);
            income.push_back(bucket.income_day);
            expense.push_back(bucket.expense_day);
            tax.push_back(bucket.tax_day);
            subsidy.push_back(bucket.subsidy_day);
            in_kind.push_back(bucket.in_kind_day);
            satisfaction.push_back(clamp_q16(bucket.composite_weighted, bucket.population));
            survival.push_back(clamp_q16(bucket.survival_weighted, bucket.population));
            for (int32_t dim = 0; dim < SAT_DIM_COUNT; ++dim)
                dims_population.push_back(bucket.dims_population[dim]);
            for (int32_t dim = 0; dim < SAT_DIM_COUNT; ++dim)
                dims.push_back(bucket.dims_population[dim] > 0 ? clamp_q16(bucket.dims_weighted[dim],
                                         bucket.dims_population[dim]) : -1);
            for (int32_t need = 0; need < need_count; ++need)
                worst_need_population.push_back(worst_needs[
                    static_cast<size_t>(profession) * static_cast<size_t>(need_count) +
                    static_cast<size_t>(need)]);
        }
        PackedStringArray need_ids;
        for (const std::string &id : _need_ids) need_ids.push_back(from_utf8(id));
        out["profession_indices"] = profession_indices;
        out["profession_stable_ids"] = stable_ids;
        out["population"] = population;
        out["cohort_count"] = cohorts;
        out["cell_count"] = cells_present;
        out["owner_employed"] = owner;
        out["employee_employed"] = employee;
        out["unemployed"] = unemployed;
        out["funds"] = funds;
        out["epoch_income"] = epoch_income;
        out["epoch_expense"] = epoch_expense;
        out["income_per_day"] = income;
        out["expense_per_day"] = expense;
        out["tax_per_day"] = tax;
        out["subsidy_per_day"] = subsidy;
        out["in_kind_income_per_day"] = in_kind;
        out["satisfaction_q16"] = satisfaction;
        out["survival_satisfaction_q16"] = survival;
        out["satisfaction_dimension_count"] = SAT_DIM_COUNT;
        out["satisfaction_dims_q16"] = dims;
        out["satisfaction_dims_population"] = dims_population;
        out["need_ids"] = need_ids;
        out["need_count"] = need_count;
        out["worst_need_population"] = worst_need_population;
        finish(out);
        return out;
    }

    if (view == "buildings" || view == "investment") {
        std::vector<BuildingBucket> buckets(static_cast<size_t>(std::max(0, type_count)));
        std::vector<int64_t> type_cells(static_cast<size_t>(std::max(0, type_count)), 0);
        std::vector<int32_t> type_last_cell(static_cast<size_t>(std::max(0, type_count)), -1);
        std::vector<int64_t> pending_rows(static_cast<size_t>(std::max(0, type_count)), 0);
        std::vector<int64_t> pending_ready(static_cast<size_t>(std::max(0, type_count)),
                                           std::numeric_limits<int64_t>::max());
        const auto sector_matches = [&](int32_t type_id) {
            return filter_id < 0 ||
                _building_types[static_cast<size_t>(type_id)].economic_sector == filter_id;
        };
        for (const int32_t cell : cells) {
            const int64_t days = cell_elapsed_days(cell);
            if (cell_population(cell) > 0) {
                ++populated_cells;
                note_state_day(cell);
            }
            for (int32_t g = group_begin(cell); g < group_end(cell); ++g) {
                const auto group = building_view(static_cast<size_t>(g));
                if (group.cell != cell || group.type_id < 0 ||
                    group.type_id >= type_count || !sector_matches(group.type_id))
                    continue;
                const size_t t = static_cast<size_t>(group.type_id);
                accumulate_group(buckets[t], group, days);
                if (type_last_cell[t] != cell && group.count > 0) {
                    type_last_cell[t] = cell;
                    ++type_cells[t];
                }
            }
        }
        for (const auto pending : pending_construction()) {
            if (pending.count <= 0 || pending.type_id < 0 ||
                pending.type_id >= type_count || !sector_matches(pending.type_id))
                continue;
            if (scope_cell >= 0 ? pending.cell != scope_cell
                                : !cell_in_country(pending.cell)) continue;
            const size_t t = static_cast<size_t>(pending.type_id);
            add(buckets[t].pending_units, pending.count);
            ++pending_rows[t];
            pending_ready[t] = std::min(pending_ready[t], pending.ready_day);
        }
        if (view == "investment") {
            std::array<int64_t, OVERVIEW_REJECTION_COUNT> totals{};
            std::vector<int64_t> sector_rejections(
                static_cast<size_t>(OVERVIEW_SECTOR_COUNT * OVERVIEW_REJECTION_COUNT), 0);
            std::vector<int64_t> sector_pending(OVERVIEW_SECTOR_COUNT, 0);
            PackedInt32Array pending_types;
            PackedInt64Array pending_units, pending_groups, pending_first_ready;
            int64_t pending_total = 0;
            for (int32_t type = 0; type < type_count; ++type) {
                const BuildingBucket &bucket = buckets[static_cast<size_t>(type)];
                const int32_t sector = _building_types[static_cast<size_t>(type)].economic_sector;
                for (int32_t reason = 1; reason < OVERVIEW_REJECTION_COUNT; ++reason) {
                    const int64_t units = bucket.rejection_units[static_cast<size_t>(reason)];
                    if (units <= 0) continue;
                    add(totals[static_cast<size_t>(reason)], units);
                    if (sector >= 0 && sector < OVERVIEW_SECTOR_COUNT)
                        add(sector_rejections[static_cast<size_t>(
                            sector * OVERVIEW_REJECTION_COUNT + reason)], units);
                }
                if (bucket.pending_units <= 0) continue;
                pending_types.push_back(type);
                pending_units.push_back(bucket.pending_units);
                pending_groups.push_back(pending_rows[static_cast<size_t>(type)]);
                pending_first_ready.push_back(pending_ready[static_cast<size_t>(type)]);
                add(pending_total, bucket.pending_units);
                if (sector >= 0 && sector < OVERVIEW_SECTOR_COUNT)
                    add(sector_pending[static_cast<size_t>(sector)], bucket.pending_units);
            }
            std::vector<int64_t> total_vector(totals.begin(), totals.end());
            out["rejection_reason_count"] = OVERVIEW_REJECTION_COUNT;
            out["rejection_units"] = pack_i64(total_vector);
            out["sector_count"] = OVERVIEW_SECTOR_COUNT;
            out["sector_rejection_units"] = pack_i64(sector_rejections);
            out["sector_pending_units"] = pack_i64(sector_pending);
            out["pending_type_indices"] = pending_types;
            out["pending_units"] = pending_units;
            out["pending_groups"] = pending_groups;
            out["pending_first_ready_day"] = pending_first_ready;
            out["pending_total_units"] = pending_total;
            out["current_day"] = _current_day.get();
            finish(out);
            return out;
        }
        std::vector<int32_t> rows;
        for (int32_t type = 0; type < type_count; ++type) {
            const BuildingBucket &bucket = buckets[static_cast<size_t>(type)];
            if (bucket.units > 0 || bucket.pending_units > 0) rows.push_back(type);
        }
        std::sort(rows.begin(), rows.end(), [&](int32_t a, int32_t b) {
            const int64_t ra = buckets[static_cast<size_t>(a)].revenue_day;
            const int64_t rb = buckets[static_cast<size_t>(b)].revenue_day;
            if (ra != rb) return ra > rb;
            return a < b;
        });
        const int32_t total = static_cast<int32_t>(rows.size());
        const int32_t page_limit = limit <= 0 ? OVERVIEW_MAX_ROWS
                                              : std::clamp(limit, 1, OVERVIEW_MAX_ROWS);
        const int32_t begin = std::clamp(offset, 0, total);
        const int32_t end = std::min(total, begin + page_limit);
        PackedInt32Array type_indices, sectors, kinds, utilization, capacity;
        PackedStringArray stable_ids;
        PackedInt64Array units, suspended, groups, cells_present, revenue, input_cost,
            wages_paid, wages_due, maintenance, business_tax, producer_support,
            output, sold, discarded, climate_lost, jobs_required, jobs_filled,
            pending_units, rejection_units;
        for (int32_t p = begin; p < end; ++p) {
            const int32_t type = rows[static_cast<size_t>(p)];
            const BuildingBucket &bucket = buckets[static_cast<size_t>(type)];
            const BuildingType &info = _building_types[static_cast<size_t>(type)];
            type_indices.push_back(type);
            stable_ids.push_back(type < static_cast<int32_t>(_building_type_ids.size())
                ? from_utf8(_building_type_ids[static_cast<size_t>(type)]) : String());
            sectors.push_back(info.economic_sector);
            kinds.push_back(info.kind);
            units.push_back(bucket.units);
            suspended.push_back(bucket.suspended_units);
            groups.push_back(bucket.groups);
            cells_present.push_back(type_cells[static_cast<size_t>(type)]);
            revenue.push_back(bucket.revenue_day);
            input_cost.push_back(bucket.input_cost_day);
            wages_paid.push_back(bucket.wages_paid_day);
            wages_due.push_back(bucket.wages_due_day);
            maintenance.push_back(bucket.maintenance_day);
            business_tax.push_back(bucket.business_tax_day);
            producer_support.push_back(bucket.producer_support_day);
            output.push_back(bucket.output_day);
            sold.push_back(bucket.sold_day);
            discarded.push_back(bucket.discarded_day);
            climate_lost.push_back(bucket.climate_lost_day);
            utilization.push_back(clamp_q16(bucket.utilization_weighted, bucket.units));
            capacity.push_back(clamp_q16(bucket.capacity_weighted, bucket.units));
            jobs_required.push_back(bucket.jobs_required);
            jobs_filled.push_back(bucket.jobs_filled);
            pending_units.push_back(bucket.pending_units);
            for (int32_t reason = 0; reason < OVERVIEW_REJECTION_COUNT; ++reason)
                rejection_units.push_back(bucket.rejection_units[static_cast<size_t>(reason)]);
        }
        out["total"] = total;
        out["offset"] = begin;
        out["limit"] = page_limit;
        out["has_more"] = end < total;
        out["type_indices"] = type_indices;
        out["building_stable_ids"] = stable_ids;
        out["economic_sectors"] = sectors;
        out["building_kinds"] = kinds;
        out["units"] = units;
        out["suspended_units"] = suspended;
        out["groups"] = groups;
        out["cell_count"] = cells_present;
        out["revenue_per_day"] = revenue;
        out["input_cost_per_day"] = input_cost;
        out["wages_paid_per_day"] = wages_paid;
        out["wages_due_per_day"] = wages_due;
        out["maintenance_per_day"] = maintenance;
        out["business_tax_per_day"] = business_tax;
        out["producer_support_per_day"] = producer_support;
        out["output_per_day"] = output;
        out["sold_per_day"] = sold;
        out["discarded_per_day"] = discarded;
        out["climate_lost_per_day"] = climate_lost;
        out["utilization_q16"] = utilization;
        out["capacity_q16"] = capacity;
        out["jobs_required"] = jobs_required;
        out["jobs_filled"] = jobs_filled;
        out["pending_units"] = pending_units;
        out["rejection_reason_count"] = OVERVIEW_REJECTION_COUNT;
        out["rejection_units"] = rejection_units;
        finish(out);
        return out;
    }

    if (view == "goods") {
        const size_t goods = static_cast<size_t>(std::max(0, good_count));
        std::vector<int64_t> stock(goods, 0), demand(goods, 0), business(goods, 0),
            supply(goods, 0), withdrawal(goods, 0), imports(goods, 0),
            exports(goods, 0), value(goods, 0), price_weighted(goods, 0),
            price_weight(goods, 0), anchor_weighted(goods, 0), anchor_weight(goods, 0),
            shortage_weighted(goods, 0), shortage_weight(goods, 0),
            shortage_cells(goods, 0), market_cells(goods, 0);
        std::vector<int32_t> price_min(goods, std::numeric_limits<int32_t>::max()),
            price_max(goods, 0);
        NativeEconomyRuntime *self = const_cast<NativeEconomyRuntime *>(this);
        for (const int32_t cell : cells) {
            if (cell_population(cell) <= 0) continue;
            ++populated_cells;
            note_state_day(cell);
            const int32_t market = market_store().cell_to_market[cell];
            if (market < 0) continue;
            for (int32_t good = 0; good < good_count; ++good) {
                const size_t g = static_cast<size_t>(good);
                const int64_t index = market_store().index(market, good);
                const int64_t cell_stock = std::max<int64_t>(0, market_store().stock[index]);
                const int64_t cell_demand = std::max<int64_t>(0, market_store().demand_ema[index]);
                const int32_t signal = market_signal_index(cell, good);
                const int64_t cell_business = signal >= 0
                    ? std::max<int64_t>(0, _market_signals.business_demand_ema[signal]) : 0;
                const int64_t cell_supply = signal >= 0
                    ? std::max<int64_t>(0, _market_signals.offered_supply_ema[signal]) : 0;
                const int32_t flow = self->trade_flow_index(cell, good, false);
                const int64_t cell_import = flow >= 0 ? _trade_flows.import_ema[flow] : 0;
                const int64_t cell_export = flow >= 0 ? _trade_flows.export_ema[flow] : 0;
                if (cell_stock <= 0 && cell_demand <= 0 && cell_business <= 0 &&
                    cell_supply <= 0 && cell_import <= 0 && cell_export <= 0)
                    continue;
                ++market_cells[g];
                const int32_t price = std::max<int32_t>(0, market_store().price[index]);
                add(stock[g], cell_stock);
                add(demand[g], cell_demand);
                add(business[g], cell_business);
                add(supply[g], cell_supply);
                if (signal >= 0)
                    add(withdrawal[g], std::max<int64_t>(
                        0, _market_signals.realized_withdrawal_ema[signal]));
                add(imports[g], std::max<int64_t>(0, cell_import));
                add(exports[g], std::max<int64_t>(0, cell_export));
                add(value[g], mul_div_sat(cell_stock, price, GOODS_SCALE, sat));
                const int64_t weight = std::max<int64_t>(1, saturating_add(
                    cell_demand, cell_business, sat));
                weigh(price_weighted[g], price, weight);
                add(price_weight[g], weight);
                if (signal >= 0 && _market_signals.cost_anchor_price[signal] > 0) {
                    weigh(anchor_weighted[g], _market_signals.cost_anchor_price[signal], weight);
                    add(anchor_weight[g], weight);
                }
                const int64_t shortage = std::clamp<int64_t>(
                    market_store().last_shortage_q16[index], 0, Q16_ONE);
                weigh(shortage_weighted[g], shortage, weight);
                add(shortage_weight[g], weight);
                if (shortage >= Q16_ONE / 4) ++shortage_cells[g];
                price_min[g] = std::min(price_min[g], price);
                price_max[g] = std::max(price_max[g], price);
            }
        }
        PackedInt32Array good_indices, prices, mins, maxes, anchors, shortages;
        PackedStringArray stable_ids, categories;
        PackedInt64Array stock_out, demand_out, business_out, supply_out, withdrawal_out,
            import_out, export_out, value_out, shortage_cells_out, market_cells_out;
        for (int32_t good = 0; good < good_count; ++good) {
            const size_t g = static_cast<size_t>(good);
            if (market_cells[g] <= 0) continue;
            good_indices.push_back(good);
            stable_ids.push_back(from_utf8(_good_ids[good]));
            categories.push_back(g < _good_category_ids.size()
                ? from_utf8(_good_category_ids[g]) : String());
            stock_out.push_back(stock[g]);
            demand_out.push_back(demand[g]);
            business_out.push_back(business[g]);
            supply_out.push_back(supply[g]);
            withdrawal_out.push_back(withdrawal[g]);
            import_out.push_back(imports[g]);
            export_out.push_back(exports[g]);
            value_out.push_back(value[g]);
            prices.push_back(clamp_q16(price_weighted[g], price_weight[g]));
            anchors.push_back(clamp_q16(anchor_weighted[g], anchor_weight[g]));
            mins.push_back(price_min[g] == std::numeric_limits<int32_t>::max()
                ? 0 : price_min[g]);
            maxes.push_back(price_max[g]);
            shortages.push_back(clamp_q16(shortage_weighted[g], shortage_weight[g]));
            shortage_cells_out.push_back(shortage_cells[g]);
            market_cells_out.push_back(market_cells[g]);
        }
        out["goods_scale"] = GOODS_SCALE;
        out["good_indices"] = good_indices;
        out["good_stable_ids"] = stable_ids;
        out["category_ids"] = categories;
        out["stock"] = stock_out;
        out["demand_ema"] = demand_out;
        out["business_demand_ema"] = business_out;
        out["offered_supply_ema"] = supply_out;
        out["realized_withdrawal_ema"] = withdrawal_out;
        out["trade_import_ema"] = import_out;
        out["trade_export_ema"] = export_out;
        out["inventory_value"] = value_out;
        out["price"] = prices;
        out["cost_anchor_price"] = anchors;
        out["price_min"] = mins;
        out["price_max"] = maxes;
        out["shortage_q16"] = shortages;
        out["shortage_cell_count"] = shortage_cells_out;
        out["market_cell_count"] = market_cells_out;
        finish(out);
        return out;
    }

    if (view == "settlements") {
        struct SettlementRow {
            int32_t cell = -1;
            PopulationBucket population;
            BuildingBucket buildings;
            int32_t worst_good = -1;
            int32_t worst_shortage = 0;
        };
        std::vector<SettlementRow> rows;
        std::vector<int32_t> profession_offsets{0};
        std::vector<int32_t> profession_ids;
        std::vector<int64_t> profession_population;
        std::vector<int32_t> profession_satisfaction;
        std::vector<PopulationBucket> scratch(static_cast<size_t>(std::max(0, profession_count)));
        std::vector<int32_t> touched;
        for (const int32_t cell : cells) {
            if (cell_population(cell) <= 0) continue;
            ++populated_cells;
            note_state_day(cell);
            const int64_t days = cell_elapsed_days(cell);
            SettlementRow row;
            row.cell = cell;
            touched.clear();
            population_store().for_each_in_cell(cell, [&](int32_t slot) {
                accumulate_cohort(row.population, slot, days);
                const uint32_t signature = population_store().signature_id[
                    static_cast<size_t>(slot)];
                if (signature >= _signatures.size()) return;
                const int32_t profession = _signatures[signature].profession_id;
                if (profession < 0 || profession >= profession_count) return;
                PopulationBucket &bucket = scratch[static_cast<size_t>(profession)];
                if (bucket.cohorts == 0) touched.push_back(profession);
                accumulate_cohort(bucket, slot, days);
            });
            std::sort(touched.begin(), touched.end());
            for (const int32_t profession : touched) {
                PopulationBucket &bucket = scratch[static_cast<size_t>(profession)];
                profession_ids.push_back(profession);
                profession_population.push_back(bucket.population);
                profession_satisfaction.push_back(
                    clamp_q16(bucket.composite_weighted, bucket.population));
                bucket = PopulationBucket{};
            }
            for (int32_t g = group_begin(cell); g < group_end(cell); ++g) {
                const auto group = building_view(static_cast<size_t>(g));
                if (group.cell != cell) continue;
                accumulate_group(row.buildings, group, days);
            }
            const int32_t market = market_store().cell_to_market[cell];
            if (market >= 0) {
                int64_t worst_score = 0;
                for (int32_t good = 0; good < good_count; ++good) {
                    const int64_t index = market_store().index(market, good);
                    const int64_t shortage = std::clamp<int64_t>(
                        market_store().last_shortage_q16[index], 0, Q16_ONE);
                    const int64_t demand = std::max<int64_t>(0, market_store().demand_ema[index]);
                    if (shortage <= 0 || demand <= 0) continue;
                    const int64_t score = saturating_mul(shortage, demand, sat);
                    if (score > worst_score) {
                        worst_score = score;
                        row.worst_good = good;
                        row.worst_shortage = static_cast<int32_t>(shortage);
                    }
                }
            }
            profession_offsets.push_back(static_cast<int32_t>(profession_ids.size()));
            rows.push_back(std::move(row));
        }
        std::vector<int32_t> order(rows.size());
        std::iota(order.begin(), order.end(), 0);
        std::sort(order.begin(), order.end(), [&](int32_t a, int32_t b) {
            const int64_t pa = rows[static_cast<size_t>(a)].population.population;
            const int64_t pb = rows[static_cast<size_t>(b)].population.population;
            if (pa != pb) return pa > pb;
            return rows[static_cast<size_t>(a)].cell < rows[static_cast<size_t>(b)].cell;
        });
        const int32_t total = static_cast<int32_t>(order.size());
        const int32_t page_limit = limit <= 0 ? OVERVIEW_MAX_ROWS
                                              : std::clamp(limit, 1, OVERVIEW_MAX_ROWS);
        const int32_t begin = std::clamp(offset, 0, total);
        const int32_t end = std::min(total, begin + page_limit);
        PackedInt32Array cell_indices, tiers, satisfaction, survival, worst_goods,
            worst_shortages, out_offsets, out_professions, out_profession_satisfaction;
        PackedStringArray names, prosperity_names;
        PackedByteArray named;
        PackedInt64Array population, funds, income, expense, tax, unemployed,
            jobs_required, jobs_filled, units, suspended, revenue, profit, wages_due,
            wages_paid, state_days, out_profession_population;
        out_offsets.push_back(0);
        for (int32_t p = begin; p < end; ++p) {
            const int32_t index = order[static_cast<size_t>(p)];
            const SettlementRow &row = rows[static_cast<size_t>(index)];
            const int32_t cell = row.cell;
            cell_indices.push_back(cell);
            const int32_t tier = cell < static_cast<int32_t>(_settlements.tier.size())
                ? _settlements.tier[cell] : 0;
            tiers.push_back(tier);
            named.push_back(cell < static_cast<int32_t>(_settlements.name_active.size()) &&
                _settlements.name_active[cell] != 0 ? 1 : 0);
            names.push_back(from_utf8(settlement_name_for_cell(cell)));
            prosperity_names.push_back(tier >= 0 &&
                tier < static_cast<int32_t>(_prosperity_names.size())
                ? from_utf8(_prosperity_names[static_cast<size_t>(tier)]) : String());
            population.push_back(row.population.population);
            funds.push_back(row.population.funds);
            income.push_back(row.population.income_day);
            expense.push_back(row.population.expense_day);
            tax.push_back(row.population.tax_day);
            unemployed.push_back(row.population.unemployed);
            satisfaction.push_back(clamp_q16(row.population.composite_weighted,
                                             row.population.population));
            survival.push_back(clamp_q16(row.population.survival_weighted,
                                         row.population.population));
            jobs_required.push_back(row.buildings.jobs_required);
            jobs_filled.push_back(row.buildings.jobs_filled);
            units.push_back(row.buildings.units);
            suspended.push_back(row.buildings.suspended_units);
            revenue.push_back(row.buildings.revenue_day);
            int64_t cell_profit = row.buildings.revenue_day;
            cell_profit = saturating_add(cell_profit, -row.buildings.input_cost_day, sat);
            cell_profit = saturating_add(cell_profit, -row.buildings.wages_paid_day, sat);
            cell_profit = saturating_add(cell_profit, -row.buildings.maintenance_day, sat);
            profit.push_back(cell_profit);
            wages_due.push_back(row.buildings.wages_due_day);
            wages_paid.push_back(row.buildings.wages_paid_day);
            worst_goods.push_back(row.worst_good);
            worst_shortages.push_back(row.worst_shortage);
            state_days.push_back(cell < static_cast<int32_t>(_cell_last_settlement_day.size())
                ? _cell_last_settlement_day[cell] : int64_t{-1});
            for (int32_t k = profession_offsets[static_cast<size_t>(index)];
                 k < profession_offsets[static_cast<size_t>(index) + 1U]; ++k) {
                out_professions.push_back(profession_ids[static_cast<size_t>(k)]);
                out_profession_population.push_back(
                    profession_population[static_cast<size_t>(k)]);
                out_profession_satisfaction.push_back(
                    profession_satisfaction[static_cast<size_t>(k)]);
            }
            out_offsets.push_back(out_professions.size());
        }
        PackedStringArray good_ids;
        for (int32_t good = 0; good < good_count; ++good)
            good_ids.push_back(from_utf8(_good_ids[good]));
        out["total"] = total;
        out["offset"] = begin;
        out["limit"] = page_limit;
        out["has_more"] = end < total;
        out["cell_indices"] = cell_indices;
        out["settlement_names"] = names;
        out["name_active"] = named;
        out["prosperity_tiers"] = tiers;
        out["prosperity_names"] = prosperity_names;
        out["population"] = population;
        out["funds"] = funds;
        out["income_per_day"] = income;
        out["expense_per_day"] = expense;
        out["tax_per_day"] = tax;
        out["unemployed"] = unemployed;
        out["satisfaction_q16"] = satisfaction;
        out["survival_satisfaction_q16"] = survival;
        out["jobs_required"] = jobs_required;
        out["jobs_filled"] = jobs_filled;
        out["building_units"] = units;
        out["building_suspended_units"] = suspended;
        out["revenue_per_day"] = revenue;
        out["profit_per_day"] = profit;
        out["wages_due_per_day"] = wages_due;
        out["wages_paid_per_day"] = wages_paid;
        out["worst_shortage_good"] = worst_goods;
        out["worst_shortage_q16"] = worst_shortages;
        out["state_day"] = state_days;
        out["profession_offsets"] = out_offsets;
        out["profession_indices"] = out_professions;
        out["profession_population"] = out_profession_population;
        out["profession_satisfaction_q16"] = out_profession_satisfaction;
        out["good_ids"] = good_ids;
        finish(out);
        return out;
    }

    out["ok"] = false;
    out["reason"] = "country_economy_view_unknown";
    return out;
}

} // namespace pk
