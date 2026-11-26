#include "economy_runtime.h"
#include "economy_cost_probe.h"
#include "economy_runtime_binary_codec.h"
#include "economy_runtime_variant_helpers.h"

#include <algorithm>
#include <chrono>
#include <cstring>
#include <limits>

#include <godot_cpp/variant/packed_byte_array.hpp>
#include <godot_cpp/variant/packed_int32_array.hpp>
#include <godot_cpp/variant/packed_int64_array.hpp>
#include <godot_cpp/variant/packed_string_array.hpp>

namespace pk {

using namespace godot;
using namespace binary_codec;
using namespace variant_helpers;

namespace {
using Clock = std::chrono::steady_clock;

double elapsed_ms(const Clock::time_point &start) {
    return std::chrono::duration<double, std::milli>(Clock::now() - start).count();
}

} // namespace

void NativeEconomyRuntime::publish_country_development_facts() {
    EconomyCostProbe probe("publish.country_development", _current_day.get());
    if (_country_runtime == nullptr || _epoch_country_count <= 0 ||
        _epoch_country_handles.size() != static_cast<size_t>(_epoch_country_count))
        return;
    const Clock::time_point class_opinion_started = Clock::now();
    const size_t metric_count = _development_metric_types.size();
    const bool development_columns_invalid = metric_count != 0 && (
        _development_metric_signal_indices.size() != metric_count ||
        _development_metric_era_indices.size() != metric_count ||
        _development_metric_subject_kinds.size() != metric_count ||
        _development_metric_subject_offsets.size() != metric_count + 1 ||
        _development_metric_qualifier_thresholds.size() != metric_count ||
        _development_metric_duration_days.size() != metric_count);
    const bool publish_development = metric_count != 0 &&
        !development_columns_invalid;
    const int32_t class_count =
        static_cast<int32_t>(_political_class_ids.size());
    CountryClassOpinionSnapshot &class_snapshot =
        _class_opinion_buffers[static_cast<size_t>(
            1 - _class_opinion_committed_buffer)];
    class_snapshot.revision = ++_class_opinion_revision;
    class_snapshot.class_hash = _political_class_hash;
    class_snapshot.epoch_day = _sample_day;
    class_snapshot.commit_day = _current_day.get();
    class_snapshot.country_count = _epoch_country_count;
    class_snapshot.class_count = class_count;
    class_snapshot.country_handles.assign(_epoch_country_handles.begin(),
        _epoch_country_handles.end());
    class_snapshot.country_generations.assign(
        static_cast<size_t>(_epoch_country_count), 0);
    for (int32_t country = 0; country < _epoch_country_count; ++country)
        class_snapshot.country_generations[static_cast<size_t>(country)] =
            static_cast<uint32_t>(_epoch_country_handles[
                static_cast<size_t>(country)] >> 32U);
    const size_t class_row_count = static_cast<size_t>(
        std::max(0, _epoch_country_count)) *
        static_cast<size_t>(std::max(0, class_count));
    class_snapshot.population.assign(class_row_count, 0);
    class_snapshot.funds.assign(class_row_count, 0);
    class_snapshot.owner_employed.assign(class_row_count, 0);
    class_snapshot.satisfaction_weighted.assign(class_row_count, 0);
    class_snapshot.satisfaction_q16.assign(class_row_count, 0);
    const size_t opinion_country_count =
        static_cast<size_t>(std::max(0, _epoch_country_count));
    class_snapshot.country_population.assign(opinion_country_count, 0);
    class_snapshot.country_buildings_installed.assign(opinion_country_count, 0);
    class_snapshot.country_trade_base_value.assign(opinion_country_count, 0);
    class_snapshot.period_days = std::max<int64_t>(1, _epoch_days.get());
    // Derived from the day, NOT from a publish counter: two authorities that
    // publish the same simulated day at different rates must produce the same
    // period index, because it is ideology's accrual idempotency key (A1).
    class_snapshot.period_index =
        class_snapshot.commit_day / class_snapshot.period_days;
    uint64_t cells_scanned = 0;
    uint64_t slots_scanned = 0;
    // Material-incidence scratch, in ABSOLUTE money. Shares are derived at
    // finalize time so a class row is normalized against its own income (or its
    // own expense, for the need channels) instead of a mixed denominator.
    const int32_t incidence_need_count = static_cast<int32_t>(_needs.size());
    const int32_t incidence_stride = EconomyApi::kIncidencePrefixChannelCount +
        incidence_need_count;
    std::vector<int64_t> incidence_income(class_row_count, 0);
    std::vector<int64_t> incidence_expense(class_row_count, 0);
    std::vector<int64_t> incidence_sector_income(
        class_row_count * static_cast<size_t>(EconomyApi::kIncidenceSectorCount), 0);
    std::vector<int64_t> incidence_input_cost(class_row_count, 0);
    std::vector<int64_t> incidence_owner_surplus(class_row_count, 0);
    std::vector<int64_t> incidence_merchant_income(class_row_count, 0);
    std::vector<int64_t> incidence_need_spend(
        class_row_count * static_cast<size_t>(std::max(0, incidence_need_count)), 0);
#include "economy_runtime_events_class_opinion_finalize.inc"
    // These values are the stable enum shared with DevelopmentAchievementCatalog.
    constexpr int32_t METRIC_POPULATION = 1;
    constexpr int32_t METRIC_MAX_SETTLEMENT_TIER = 2;
    constexpr int32_t METRIC_SETTLEMENT_COUNT = 3;
    constexpr int32_t METRIC_BUILDING_INSTALLED = 4;
    constexpr int32_t METRIC_BUILDING_ACTIVE = 5;
    constexpr int32_t METRIC_INDUSTRY_EMPLOYMENT = 6;
    constexpr int32_t METRIC_INDUSTRY_OUTPUT = 7;
    constexpr int32_t METRIC_SATISFACTION_Q16 = 8;
    constexpr int32_t METRIC_TRADE_QUANTITY = 9;
    constexpr int32_t METRIC_TRADE_BASE_VALUE = 10;
    constexpr int32_t METRIC_TRADE_ORDER_COUNT = 11;
    constexpr int32_t METRIC_TRADE_GOOD_VARIETY = 12;
    constexpr int32_t METRIC_TRADE_PARTNER_COUNT = 13;
    constexpr int32_t METRIC_PRODUCED_GOOD_VARIETY = 14;

    struct MetricValue {
        int64_t value = 0;
        int32_t first_cell = -1;
    };
    const size_t country_count = static_cast<size_t>(_epoch_country_count);
    std::vector<MetricValue> values(country_count * metric_count);
    std::vector<int64_t> satisfaction_weighted(country_count, 0);
    std::vector<int64_t> satisfaction_population(country_count, 0);
    std::vector<std::vector<int32_t>> produced_goods(country_count);
    std::vector<std::vector<int32_t>> traded_goods(country_count);
    std::vector<std::vector<int32_t>> traded_partners(country_count);

    auto metric_at = [&](int32_t country, size_t metric) -> MetricValue & {
        return values[static_cast<size_t>(country) * metric_count + metric];
    };
    auto subject_begin = [&](size_t metric) {
        return _development_metric_subject_offsets[metric];
    };
    auto subject_end = [&](size_t metric) {
        return _development_metric_subject_offsets[metric + 1];
    };
    auto subject_contains = [&](size_t metric, int32_t value) {
        for (int32_t cursor = subject_begin(metric); cursor < subject_end(metric);
             ++cursor) {
            if (cursor >= 0 && cursor < static_cast<int32_t>(
                    _development_metric_subject_indices.size()) &&
                _development_metric_subject_indices[static_cast<size_t>(cursor)] == value)
                return true;
        }
        return false;
    };
    auto metric_matches_group = [&](size_t metric, int32_t type_id,
                                    const BuildingType &type) {
        const int32_t kind = _development_metric_subject_kinds[metric];
        if (kind == 0) return true; // ANY
        if (kind == 1) return subject_contains(metric, type.economic_sector);
        if (kind == 2) return subject_contains(metric, type_id);
        if (kind == 3) return subject_contains(metric, type.upgrade_family_id);
        if (kind == 4) {
            for (int32_t output = type.output_begin;
                 output < type.output_begin + type.output_count; ++output) {
                if (output >= 0 && output < static_cast<int32_t>(
                        _building_outputs.size()) &&
                    subject_contains(metric, _building_outputs[
                        static_cast<size_t>(output)].good_id))
                    return true;
            }
        }
        return false;
    };
    auto metric_matches_good = [&](size_t metric, int32_t good) {
        const int32_t kind = _development_metric_subject_kinds[metric];
        return kind == 0 || (kind == 4 && subject_contains(metric, good));
    };
    auto add_unique = [](std::vector<int32_t> &items, int32_t value) {
        if (value >= 0 && std::find(items.begin(), items.end(), value) == items.end())
            items.push_back(value);
    };
    // metric_matches_group() only depends on the building type, so evaluate it
    // once per type rather than once per (group row, metric): the development
    // scan visits every building group each committed day and the subject scans
    // inside metric_matches_group() dominated that loop.
    // The mask used to be a single uint32_t per building type. Once the authored
    // catalog grew past 32 metrics the shift aliased (metric i shared bit i%32
    // with metric i-32), and because ANY-subject metrics always match, they kept
    // those aliased bits lit for every building: every SECTOR/BUILDING/GOOD
    // filtered metric silently aggregated the whole country. Pack one bit per
    // metric across as many 64-bit words as the catalog needs.
    const size_t metric_words = (metric_count + 63U) / 64U;
    thread_local std::vector<uint64_t> type_metric_mask;
    thread_local int32_t type_metric_mask_config = -1;
    thread_local size_t type_metric_mask_words = 0;
    const int32_t metric_config_token = static_cast<int32_t>(metric_count) * 7919 +
        (development_columns_invalid ? 1 : 0);
    if (type_metric_mask_config != metric_config_token ||
        type_metric_mask_words != metric_words ||
        type_metric_mask.size() != _building_types.size() * metric_words) {
        type_metric_mask_config = metric_config_token;
        type_metric_mask_words = metric_words;
        type_metric_mask.assign(_building_types.size() * metric_words, 0U);
        for (size_t type_id = 0; type_id < _building_types.size(); ++type_id) {
            const size_t base = type_id * metric_words;
            for (size_t metric = 0; metric < metric_count; ++metric) {
                if (metric_matches_group(metric, static_cast<int32_t>(type_id),
                                         _building_types[type_id]))
                    type_metric_mask[base + metric / 64] |= uint64_t{1} << (metric % 64);
            }
        }
    }

    // Per-cell profession scratch for the sparse organization table. The
    // generation stamp avoids clearing the 50-entry arrays for every cell.
    const int32_t mob_profession_count =
        static_cast<int32_t>(_profession_political_class_index.size());
    thread_local std::vector<int64_t> mob_prof_pop;
    thread_local std::vector<int64_t> mob_prof_sat;
    thread_local std::vector<uint8_t> mob_prof_touched;
    thread_local std::vector<int32_t> mob_touched;
    if (mob_profession_count > 0 &&
        mob_prof_pop.size() != static_cast<size_t>(mob_profession_count)) {
        mob_prof_pop.assign(static_cast<size_t>(mob_profession_count), 0);
        mob_prof_sat.assign(static_cast<size_t>(mob_profession_count), 0);
        mob_prof_touched.assign(static_cast<size_t>(mob_profession_count), 0);
    }

    // `_market_cells` is the existing stable market/settlement CSR. Only cells
    // with a committed population are evidence-bearing settlements; empty map
    // cells never enter the development scan or emit a fact.
    if (_committed_cells.size() == static_cast<size_t>(_cell_count.get())) {
        for (const int32_t cell : _market_cells) {
            ++cells_scanned;
            if (cell < 0 || cell >= _cell_count.get() ||
                _committed_cells[static_cast<size_t>(cell)].population <= 0 ||
                cell >= static_cast<int32_t>(_epoch_cell_country.size()))
                continue;
            const int32_t country = _epoch_cell_country[static_cast<size_t>(cell)];
            if (country < 0 || country >= _epoch_country_count ||
                _epoch_country_handles[static_cast<size_t>(country)] == 0)
                continue;
            for (size_t metric = 0; metric < metric_count; ++metric)
                metric_at(country, metric).first_cell =
                    metric_at(country, metric).first_cell < 0
                    ? cell : std::min(metric_at(country, metric).first_cell, cell);

            int64_t cell_population = 0;
            int64_t cell_satisfaction = 0;
            population_store().for_each_in_cell(cell, [&](int32_t slot) {
                ++slots_scanned;
                const int64_t people = std::max<int64_t>(
                    0, population_store().population[static_cast<size_t>(slot)]);
                if (people <= 0) return;
                cell_population = saturating_add(cell_population, people,
                                                 _saturation_count);
                cell_satisfaction = saturating_add(cell_satisfaction,
                    saturating_mul(static_cast<int64_t>(
                        population_store().composite_satisfaction[
                            static_cast<size_t>(slot)]),
                        people, _saturation_count), _saturation_count);
                const uint32_t signature_id =
                    population_store().signature_id[static_cast<size_t>(slot)];
                if (signature_id >= _signatures.size()) return;
                const int32_t profession =
                    _signatures[signature_id].profession_id;
                if (profession < 0 || profession >= static_cast<int32_t>(
                        _profession_political_class_index.size()))
                    return;
                if (profession < mob_profession_count) {
                    if (mob_prof_touched[static_cast<size_t>(profession)] == 0) {
                        mob_prof_touched[static_cast<size_t>(profession)] = 1;
                        mob_touched.push_back(profession);
                        mob_prof_pop[static_cast<size_t>(profession)] = 0;
                        mob_prof_sat[static_cast<size_t>(profession)] = 0;
                    }
                    mob_prof_pop[static_cast<size_t>(profession)] = saturating_add(
                        mob_prof_pop[static_cast<size_t>(profession)], people,
                        _saturation_count);
                    mob_prof_sat[static_cast<size_t>(profession)] = saturating_add(
                        mob_prof_sat[static_cast<size_t>(profession)],
                        saturating_mul(static_cast<int64_t>(
                            population_store().composite_satisfaction[
                                static_cast<size_t>(slot)]),
                            people, _saturation_count),
                        _saturation_count);
                }
                const int32_t political_class =
                    _profession_political_class_index[
                        static_cast<size_t>(profession)];
                if (political_class < 0 ||
                        political_class >= class_count)
                    return;
                const size_t class_row =
                    static_cast<size_t>(country) *
                        static_cast<size_t>(class_count) +
                    static_cast<size_t>(political_class);
                class_snapshot.population[class_row] = saturating_add(
                    class_snapshot.population[class_row], people,
                    _saturation_count);
                class_snapshot.funds[class_row] = saturating_add(
                    class_snapshot.funds[class_row],
                    std::max<int64_t>(0, population_store().funds[
                        static_cast<size_t>(slot)]), _saturation_count);
                class_snapshot.owner_employed[class_row] = saturating_add(
                    class_snapshot.owner_employed[class_row],
                    std::max<int64_t>(0, population_store().owner_employed[
                        static_cast<size_t>(slot)]), _saturation_count);
                class_snapshot.satisfaction_weighted[class_row] =
                    saturating_add(
                        class_snapshot.satisfaction_weighted[class_row],
                        saturating_mul(static_cast<int64_t>(
                            population_store().composite_satisfaction[
                                static_cast<size_t>(slot)]),
                            people, _saturation_count),
                        _saturation_count);
                // Material incidence: what this class actually earned, spent, and
                // earned as a merchant this period. Absolute money here; the Q16
                // shares are derived at finalize time.
                const int64_t cohort_income = std::max<int64_t>(0,
                    population_store().epoch_income[static_cast<size_t>(slot)]);
                const int64_t cohort_expense = std::max<int64_t>(0,
                    population_store().epoch_expense[static_cast<size_t>(slot)]);
                incidence_income[class_row] = saturating_add(
                    incidence_income[class_row], cohort_income, _saturation_count);
                incidence_expense[class_row] = saturating_add(
                    incidence_expense[class_row], cohort_expense, _saturation_count);
                if (is_merchant_slot(slot))
                    incidence_merchant_income[class_row] = saturating_add(
                        incidence_merchant_income[class_row], cohort_income,
                        _saturation_count);
                if (incidence_need_count > 0 && cohort_expense > 0 &&
                    static_cast<size_t>(profession) *
                            static_cast<size_t>(incidence_need_count) +
                            static_cast<size_t>(incidence_need_count) <=
                        _profession_need_weight_q16.size()) {
                    const int32_t *basket = &_profession_need_weight_q16[
                        static_cast<size_t>(profession) *
                            static_cast<size_t>(incidence_need_count)];
                    for (int32_t need = 0; need < incidence_need_count; ++need) {
                        if (basket[need] <= 0) continue;
                        const int64_t spend = mul_div_sat(
                            cohort_expense, basket[need], Q16_ONE, _saturation_count);
                        if (spend <= 0) continue;
                        int64_t &bucket = incidence_need_spend[
                            class_row * static_cast<size_t>(incidence_need_count) +
                            static_cast<size_t>(need)];
                        bucket = saturating_add(bucket, spend, _saturation_count);
                    }
                }
            });
            if (country >= 0 && cell_population > 0) {
                advance_cell_mobilization(cell, country, cell_population,
                    cell_satisfaction, mob_touched, mob_prof_pop, mob_prof_sat);
            }
            for (const int32_t touched_profession : mob_touched)
                mob_prof_touched[static_cast<size_t>(touched_profession)] = 0;
            mob_touched.clear();
            for (size_t metric = 0; metric < metric_count; ++metric) {
                const int32_t type = _development_metric_types[metric];
                if (type == METRIC_POPULATION)
                    metric_at(country, metric).value = saturating_add(
                        metric_at(country, metric).value, cell_population,
                        _saturation_count);
            }
            satisfaction_population[static_cast<size_t>(country)] =
                saturating_add(satisfaction_population[static_cast<size_t>(country)],
                               cell_population, _saturation_count);
            satisfaction_weighted[static_cast<size_t>(country)] =
                saturating_add(satisfaction_weighted[static_cast<size_t>(country)],
                               cell_satisfaction, _saturation_count);
            class_snapshot.country_population[static_cast<size_t>(country)] =
                saturating_add(class_snapshot.country_population[
                    static_cast<size_t>(country)], cell_population,
                    _saturation_count);

            const int64_t tier = cell < static_cast<int32_t>(_settlements.tier.size())
                ? static_cast<int64_t>(_settlements.tier[static_cast<size_t>(cell)]) : 0;
            for (size_t metric = 0; metric < metric_count; ++metric) {
                const int32_t type = _development_metric_types[metric];
                if (type == METRIC_MAX_SETTLEMENT_TIER) {
                    metric_at(country, metric).value = std::max(
                        metric_at(country, metric).value, tier);
                } else if (type == METRIC_SETTLEMENT_COUNT) {
                    const int32_t begin = subject_begin(metric);
                    const int64_t required = begin < subject_end(metric) &&
                            begin >= 0 && begin < static_cast<int32_t>(
                                _development_metric_subject_indices.size())
                        ? _development_metric_subject_indices[static_cast<size_t>(begin)] : 0;
                    if (tier >= required)
                        metric_at(country, metric).value = saturating_add(
                            metric_at(country, metric).value, 1, _saturation_count);
                }
            }
        }
    }
    // Ideology development lanes: installed buildings and the period's
    // import+export base value. Sparse building groups and trade rows only.
    for (size_t pk_row = 0; pk_row < building_count(); ++pk_row) {
        const auto group = building_view(pk_row);
        if (group.count <= 0 || group.cell < 0 ||
            group.cell >= static_cast<int32_t>(_epoch_cell_country.size()))
            continue;
        const int32_t country = _epoch_cell_country[static_cast<size_t>(group.cell)];
        if (country < 0 || country >= _epoch_country_count) continue;
        class_snapshot.country_buildings_installed[static_cast<size_t>(country)] =
            saturating_add(class_snapshot.country_buildings_installed[
                static_cast<size_t>(country)], group.count, _saturation_count);
        // Material incidence: attribute this group's period cash flow to the
        // classes that earned it. Owner profit is the gross operating surplus
        // (revenue - inputs - maintenance - wages - business tax), clamped at
        // zero: a loss period must not become a negative "income share" that
        // silently cancels a class's other exposure.
        if (group.type_id < 0 ||
            group.type_id >= static_cast<int32_t>(_building_types.size()))
            continue;
        const BuildingType &type = _building_types[static_cast<size_t>(group.type_id)];
        const int32_t sector = type.economic_sector;
        if (sector < 0 || sector >= EconomyApi::kIncidenceSectorCount) continue;
        const int64_t wages_paid = std::max<int64_t>(0, group.last_wages_paid);
        const int64_t surplus = std::max<int64_t>(0,
            group.last_revenue - group.last_input_cost -
            group.last_maintenance_cost - wages_paid -
            group.last_business_tax_paid);
        if (type.owner_profession_id >= 0 &&
            type.owner_profession_id < static_cast<int32_t>(
                _profession_political_class_index.size())) {
            const int32_t owner_class = _profession_political_class_index[
                static_cast<size_t>(type.owner_profession_id)];
            if (owner_class >= 0 && owner_class < class_count) {
                const size_t class_row =
                    static_cast<size_t>(country) * static_cast<size_t>(class_count) +
                    static_cast<size_t>(owner_class);
                int64_t &bucket = incidence_sector_income[
                    class_row * static_cast<size_t>(EconomyApi::kIncidenceSectorCount) +
                    static_cast<size_t>(sector)];
                bucket = saturating_add(bucket,
                    saturating_add(surplus, wages_paid, _saturation_count),
                    _saturation_count);
                incidence_owner_surplus[class_row] = saturating_add(
                    incidence_owner_surplus[class_row], surplus, _saturation_count);
                incidence_input_cost[class_row] = saturating_add(
                    incidence_input_cost[class_row],
                    std::max<int64_t>(0, group.last_input_cost), _saturation_count);
            }
        }
        for (int32_t role = 0; group.employee_fill_begin >= 0 &&
                role < type.employee_count; ++role) {
            const int32_t role_index = group.employee_fill_begin + role;
            const int32_t role_lane = type.employee_begin + role;
            if (role_lane < 0 || role_lane >= static_cast<int32_t>(
                    _building_employee_roles.size()))
                continue;
            const int32_t profession =
                _building_employee_roles[static_cast<size_t>(role_lane)].profession_id;
            if (profession < 0 || profession >= static_cast<int32_t>(
                    _profession_political_class_index.size()))
                continue;
            const int32_t employee_class = _profession_political_class_index[
                static_cast<size_t>(profession)];
            if (employee_class < 0 || employee_class >= class_count) continue;
            int64_t role_wages = 0;
            if (role_index >= 0 &&
                role_index < static_cast<int32_t>(_building_role_base_wage_paid.size()))
                role_wages = saturating_add(role_wages,
                    std::max<int64_t>(0, _building_role_base_wage_paid[
                        static_cast<size_t>(role_index)]), _saturation_count);
            if (role_index >= 0 &&
                role_index < static_cast<int32_t>(_building_role_bonus_paid.size()))
                role_wages = saturating_add(role_wages,
                    std::max<int64_t>(0, _building_role_bonus_paid[
                        static_cast<size_t>(role_index)]), _saturation_count);
            if (role_wages <= 0) continue;
            const size_t class_row =
                static_cast<size_t>(country) * static_cast<size_t>(class_count) +
                static_cast<size_t>(employee_class);
            int64_t &bucket = incidence_sector_income[
                class_row * static_cast<size_t>(EconomyApi::kIncidenceSectorCount) +
                static_cast<size_t>(sector)];
            bucket = saturating_add(bucket, role_wages, _saturation_count);
        }
    }
    for (size_t row = 0; row < _country_good_trade.countries.size(); ++row) {
        const int32_t country = _country_good_trade.countries[row];
        if (country < 0 || country >= _epoch_country_count ||
            row >= _country_good_trade.import_base.size() ||
            row >= _country_good_trade.export_base.size())
            continue;
        const int64_t base_value = saturating_add(
            std::max<int64_t>(0, _country_good_trade.import_base[row]),
            std::max<int64_t>(0, _country_good_trade.export_base[row]),
            _saturation_count);
        class_snapshot.country_trade_base_value[static_cast<size_t>(country)] =
            saturating_add(class_snapshot.country_trade_base_value[
                static_cast<size_t>(country)], base_value, _saturation_count);
    }
    finalize_class_snapshot();
    if (!publish_development) return;

    const int64_t period_days = std::max<int64_t>(1, _epoch_days.get());
    for (size_t pk_row = 0; pk_row < building_count(); ++pk_row) {
        const auto group = building_view(pk_row);
        if (group.count <= 0 || group.cell < 0 || group.cell >= _cell_count.get() ||
            group.type_id < 0 || group.type_id >= static_cast<int32_t>(_building_types.size()) ||
            group.cell >= static_cast<int32_t>(_epoch_cell_country.size()))
            continue;
        const int32_t country = _epoch_cell_country[static_cast<size_t>(group.cell)];
        if (country < 0 || country >= _epoch_country_count ||
            _epoch_country_handles[static_cast<size_t>(country)] == 0)
            continue;
        const BuildingType &type = _building_types[static_cast<size_t>(group.type_id)];
        const bool active = group.count > 0 && group.last_output > 0 &&
            group.last_capacity_q16 > 0;
        const uint64_t *metric_mask = metric_words > 0U
            ? &type_metric_mask[static_cast<size_t>(group.type_id) * metric_words]
            : nullptr;
        if (metric_mask == nullptr) continue;
        bool metric_mask_empty = true;
        for (size_t word = 0; word < metric_words; ++word) {
            if (metric_mask[word] != 0U) {
                metric_mask_empty = false;
                break;
            }
        }
        if (metric_mask_empty) continue;
        int64_t employment = -1;
        for (size_t metric = 0; metric < metric_count; ++metric) {
            if ((metric_mask[metric / 64] & (uint64_t{1} << (metric % 64))) == 0U) continue;
            const int32_t metric_type = _development_metric_types[metric];
            if (metric_type == METRIC_BUILDING_INSTALLED) {
                metric_at(country, metric).value = saturating_add(
                    metric_at(country, metric).value, group.count, _saturation_count);
            } else if (metric_type == METRIC_BUILDING_ACTIVE && active) {
                metric_at(country, metric).value = saturating_add(
                    metric_at(country, metric).value, group.count, _saturation_count);
            } else if (metric_type == METRIC_INDUSTRY_EMPLOYMENT) {
                if (employment < 0) {
                    employment = std::max<int64_t>(0, group.filled_owner);
                    if (group.employee_fill_begin < 0)
                        metric_at(country, metric).value = saturating_add(
                            metric_at(country, metric).value, employment,
                            _saturation_count);
                    for (int32_t role = 0; group.employee_fill_begin >= 0 &&
                         role < type.employee_count; ++role) {
                        const int32_t index = group.employee_fill_begin + role;
                        if (index >= 0 && index < static_cast<int32_t>(
                                _building_employee_filled.size()))
                            employment = saturating_add(employment,
                                std::max<int64_t>(0, _building_employee_filled[
                                    static_cast<size_t>(index)]), _saturation_count);
                    }
                }
                metric_at(country, metric).value = saturating_add(
                    metric_at(country, metric).value, employment, _saturation_count);
            } else if (metric_type == METRIC_INDUSTRY_OUTPUT) {
                metric_at(country, metric).value = saturating_add(
                    metric_at(country, metric).value,
                    std::max<int64_t>(0, group.last_output) / period_days,
                    _saturation_count);
            }
        }
        if (active && type.output_count > 0) {
            std::vector<int32_t> &goods = produced_goods[static_cast<size_t>(country)];
            for (int32_t output = type.output_begin;
                 output < type.output_begin + type.output_count; ++output) {
                if (output < 0 || output >= static_cast<int32_t>(_building_outputs.size()))
                    continue;
                const GoodAmount &item = _building_outputs[static_cast<size_t>(output)];
                if (item.good_id < 0 || item.quantity <= 0) continue;
                add_unique(goods, item.good_id);
            }
        }
    }

    for (size_t row = 0; row < _country_good_trade.countries.size(); ++row) {
        const int32_t country = _country_good_trade.countries[row];
        if (country < 0 || country >= _epoch_country_count ||
            metric_at(country, 0).first_cell < 0 || row >= _country_good_trade.goods.size())
            continue;
        const int32_t good = _country_good_trade.goods[row];
        const int64_t quantity = saturating_add(
            std::max<int64_t>(0, _country_good_trade.import_quantity[row]),
            std::max<int64_t>(0, _country_good_trade.export_quantity[row]),
            _saturation_count);
        const int64_t base_value = saturating_add(
            std::max<int64_t>(0, _country_good_trade.import_base[row]),
            std::max<int64_t>(0, _country_good_trade.export_base[row]),
            _saturation_count);
        if (quantity <= 0 && base_value <= 0) continue;
        add_unique(traded_goods[static_cast<size_t>(country)], good);
        for (size_t metric = 0; metric < metric_count; ++metric) {
            if (!metric_matches_good(metric, good)) continue;
            const int32_t type = _development_metric_types[metric];
            if (type == METRIC_TRADE_QUANTITY)
                metric_at(country, metric).value = saturating_add(
                    metric_at(country, metric).value, quantity, _saturation_count);
            else if (type == METRIC_TRADE_BASE_VALUE)
                metric_at(country, metric).value = saturating_add(
                    metric_at(country, metric).value, base_value, _saturation_count);
        }
    }
    for (size_t row = 0; row < _country_partner_trade.countries.size(); ++row) {
        const int32_t country = _country_partner_trade.countries[row];
        if (country < 0 || country >= _epoch_country_count ||
            metric_at(country, 0).first_cell < 0 || row >= _country_partner_trade.partners.size())
            continue;
        const int64_t orders = row < _country_partner_trade.order_count.size()
            ? std::max<int64_t>(0, _country_partner_trade.order_count[row]) : 0;
        if (orders <= 0) continue;
        add_unique(traded_partners[static_cast<size_t>(country)],
                   _country_partner_trade.partners[row]);
        for (size_t metric = 0; metric < metric_count; ++metric) {
            if (_development_metric_types[metric] == METRIC_TRADE_ORDER_COUNT)
                metric_at(country, metric).value = saturating_add(
                    metric_at(country, metric).value, orders, _saturation_count);
        }
    }

    constexpr int64_t NEVER_PUBLISHED = std::numeric_limits<int64_t>::min();
    if (_development_fact_country_handles.size() != country_count ||
        _development_fact_last_day.size() != country_count * metric_count) {
        _development_fact_country_handles.assign(country_count, 0);
        _development_fact_last_day.assign(country_count * metric_count, NEVER_PUBLISHED);
        _development_fact_qualified.assign(country_count * metric_count, 0);
    }
    for (int32_t country = 0; country < _epoch_country_count; ++country) {
        if (_epoch_country_handles[static_cast<size_t>(country)] == 0 ||
            metric_at(country, 0).first_cell < 0)
            continue;
        const size_t country_index = static_cast<size_t>(country);
        if (_development_fact_country_handles[country_index] !=
                _epoch_country_handles[country_index]) {
            _development_fact_country_handles[country_index] =
                _epoch_country_handles[country_index];
            std::fill_n(_development_fact_last_day.begin() +
                            static_cast<std::ptrdiff_t>(country_index * metric_count),
                        metric_count, NEVER_PUBLISHED);
            std::fill_n(_development_fact_qualified.begin() +
                            static_cast<std::ptrdiff_t>(country_index * metric_count),
                        metric_count, uint8_t{0});
        }
        const int64_t population = satisfaction_population[country_index];
        const int64_t satisfaction = population > 0
            ? std::clamp<int64_t>(satisfaction_weighted[country_index] / population,
                                  0, Q16_ONE - 1) : 0;
        for (size_t metric = 0; metric < metric_count; ++metric) {
            MetricValue &value = metric_at(country, metric);
            const int32_t type = _development_metric_types[metric];
            if (type == METRIC_SATISFACTION_Q16) value.value = satisfaction;
            else if (type == METRIC_TRADE_GOOD_VARIETY) {
                int64_t count = 0;
                for (const int32_t good : traded_goods[country_index])
                    if (metric_matches_good(metric, good)) ++count;
                value.value = count;
            }
            else if (type == METRIC_TRADE_PARTNER_COUNT) value.value =
                static_cast<int64_t>(traded_partners[country_index].size());
            else if (type == METRIC_PRODUCED_GOOD_VARIETY) {
                int64_t count = 0;
                for (const int32_t good : produced_goods[country_index])
                    if (metric_matches_good(metric, good)) ++count;
                value.value = count;
            }
            const int32_t signal = _development_metric_signal_indices[metric];
            if (signal < 0 || country_reads().has_research_signal(country, signal))
                continue;
            // A skipped below-qualifier sample is still a reset for Trigger: the
            // next qualified sample lands after a coverage gap and restarts the
            // consecutive count.
            const size_t row = country_index * metric_count + metric;
            const bool qualified =
                value.value >= _development_metric_qualifier_thresholds[metric];
            const int64_t last_day = _development_fact_last_day[row];
            if (!qualified && _development_fact_qualified[row] == 0 &&
                last_day != NEVER_PUBLISHED &&
                _sample_day - last_day < DEVELOPMENT_IDLE_FACT_INTERVAL_DAYS)
                continue;
            _development_fact_qualified[row] = qualified ? 1 : 0;
            _development_fact_last_day[row] = _sample_day;
            CommittedGameplayFact fact;
            fact.kind = GAMEPLAY_FACT_COUNTRY_DEVELOPMENT_METRIC;
            fact.cell = value.first_cell;
            fact.entity_handle = _epoch_country_handles[country_index];
            fact.entity_id = country;
            fact.value = std::max<int64_t>(0, value.value);
            const int32_t coverage = _development_metric_duration_days[metric] > 1
                ? static_cast<int32_t>(std::clamp<int64_t>(period_days, 1,
                    std::numeric_limits<int32_t>::max())) : 1;
            fact.payload = {static_cast<int32_t>(metric), coverage, 0, 1};
            _staging_gameplay_facts.push_back(fact);
        }
    }
}

} // namespace pk
