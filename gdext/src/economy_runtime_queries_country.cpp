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
    int64_t living_standard_weighted = 0;
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

struct WeightedMetric {
    int64_t weighted_value = 0;
    int64_t weight = 0;
    bool saturated = false;
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
        weigh(bucket.living_standard_weighted,
              static_cast<int64_t>(consumption_living_standard_level(slot)) * Q16_ONE,
              people);
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
        target["living_standard_level_q16"] =
            bucket.population > 0
                ? static_cast<int32_t>(bucket.living_standard_weighted / bucket.population)
                : 0;
        target["living_standard_level_valid"] = bucket.population > 0;
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
        WeightedMetric consumer_price_index;
        WeightedMetric producer_price_index;
        WeightedMetric consumer_shortage;
        WeightedMetric industrial_shortage;
        std::array<BuildingBucket, OVERVIEW_SECTOR_COUNT> sectors{};
        std::vector<int64_t> worst_need_population(
            static_cast<size_t>(std::max(0, need_count)), 0);
        int64_t merchant_inventory_value = 0;
        int64_t named_settlements = 0;
        int32_t max_tier = 0;
        const auto good_has_tag = [&](int32_t good, const char *tag) {
            if (good < 0 || good >= good_count ||
                _good_technology_tag_offsets.size() !=
                    static_cast<size_t>(good_count) + 1U) return false;
            const int32_t begin = _good_technology_tag_offsets[static_cast<size_t>(good)];
            const int32_t end = _good_technology_tag_offsets[static_cast<size_t>(good) + 1U];
            for (int32_t i = begin; i < end; ++i)
                if (_good_technology_tags[static_cast<size_t>(i)] == tag) return true;
            return false;
        };
        const auto add_metric_sample = [&](WeightedMetric &metric, int64_t value,
                                           int64_t weight) {
            if (weight <= 0) return;
            const int64_t sat_before = sat;
            add(metric.weighted_value, saturating_mul(value, weight, sat));
            add(metric.weight, weight);
            if (sat != sat_before) metric.saturated = true;
        };
        const auto add_price_index_sample = [&](WeightedMetric &metric, int32_t price,
                                                int32_t anchor, int64_t weight) {
            if (weight <= 0 || anchor <= 0) return;
            const int64_t sat_before = sat;
            const int64_t ratio_q16 = mul_div_sat(
                std::max<int32_t>(0, price), Q16_ONE, anchor, sat);
            if (sat != sat_before) metric.saturated = true;
            add_metric_sample(metric, ratio_q16, weight);
        };
        std::vector<uint8_t> consumer_goods(static_cast<size_t>(good_count), 0);
        std::vector<uint8_t> consumer_shortage_goods(static_cast<size_t>(good_count), 0);
        std::vector<uint8_t> industrial_goods(static_cast<size_t>(good_count), 0);
        for (int32_t good = 0; good < good_count; ++good) {
            const bool food = good_has_tag(good, "industry.food");
            const bool textile = good_has_tag(good, "industry.textile");
            const bool consumer = good_has_tag(good, "industry.consumer");
            consumer_goods[static_cast<size_t>(good)] = food || textile || consumer;
            consumer_shortage_goods[static_cast<size_t>(good)] = textile || consumer;
            industrial_goods[static_cast<size_t>(good)] =
                good_has_tag(good, "industry.primary") ||
                good_has_tag(good, "industry.construction") ||
                good_has_tag(good, "industry.metals") ||
                good_has_tag(good, "industry.chemicals") ||
                good_has_tag(good, "industry.energy") ||
                good_has_tag(good, "industry.machinery");
        }
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

                    const int32_t signal = market_signal_index(cell, good);
                    const int64_t household_demand = std::max<int64_t>(
                        0, market_store().demand_ema[index]);
                    const int64_t offered_supply = signal >= 0
                        ? std::max<int64_t>(0,
                            _market_signals.offered_supply_ema[signal]) : 0;
                    const int64_t business_demand = signal >= 0
                        ? std::max<int64_t>(0,
                            _market_signals.business_demand_ema[signal]) : 0;
                    const int32_t price = market_store().price[index];
                    const int32_t anchor = signal >= 0
                        ? _market_signals.cost_anchor_price[signal] : 0;
                    const size_t good_index = static_cast<size_t>(good);
                    if (consumer_goods[good_index])
                        add_price_index_sample(consumer_price_index, price, anchor,
                                               household_demand);
                    add_price_index_sample(producer_price_index, price, anchor,
                                           offered_supply);
                    if (consumer_shortage_goods[good_index])
                        add_metric_sample(consumer_shortage,
                            std::clamp<int64_t>(market_store().last_shortage_q16[index],
                                                0, Q16_ONE), household_demand);
                    if (industrial_goods[good_index])
                        add_metric_sample(industrial_shortage,
                            std::clamp<int64_t>(market_store().last_shortage_q16[index],
                                                0, Q16_ONE), business_demand);
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
        const auto metric_valid = [](const WeightedMetric &metric) {
            return metric.weight > 0 && !metric.saturated;
        };
        const auto metric_value = [&](const WeightedMetric &metric) {
            return metric_valid(metric) ? metric.weighted_value / metric.weight : int64_t{0};
        };
        out["consumer_price_index_q16"] = metric_value(consumer_price_index);
        out["consumer_price_index_valid"] = metric_valid(consumer_price_index);
        out["producer_price_index_q16"] = metric_value(producer_price_index);
        out["producer_price_index_valid"] = metric_valid(producer_price_index);
        out["consumer_shortage_q16"] = metric_value(consumer_shortage);
        out["consumer_shortage_valid"] = metric_valid(consumer_shortage);
        out["industrial_shortage_q16"] = metric_value(industrial_shortage);
        out["industrial_shortage_valid"] = metric_valid(industrial_shortage);
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
        PackedInt32Array living;
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
            // Same population-weighted consumption tier the summary exposes, so a
            // stratum card can name a living standard without re-deriving the
            // native thresholds in GDScript.
            living.push_back(bucket.population > 0
                ? static_cast<int32_t>(bucket.living_standard_weighted / bucket.population)
                : 0);
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
        out["living_standard_level_q16"] = living;
        out["satisfaction_dimension_count"] = SAT_DIM_COUNT;
        out["satisfaction_dims_q16"] = dims;
        out["satisfaction_dims_population"] = dims_population;
        out["need_ids"] = need_ids;
        out["need_count"] = need_count;
        out["worst_need_population"] = worst_need_population;
        finish(out);
        return out;
    }

#include "economy_runtime_queries_country_section_building_and_investment_view.inc"
#include "economy_runtime_queries_country_section_goods_view.inc"
#include "economy_runtime_queries_country_section_settlements_view.inc"
    out["ok"] = false;
    out["reason"] = "country_economy_view_unknown";
    return out;
}

} // namespace pk
