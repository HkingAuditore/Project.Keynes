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

// Moves `previous` one band at a time and only once `value` clears the
// neighbouring threshold by `margin`, so a cohort hovering on a boundary does
// not repaint its cell every day.
uint8_t hysteretic_band(int64_t value, const int64_t *thresholds, int32_t count,
                        uint8_t previous, int64_t margin) {
    int32_t level = 0;
    if (previous > count) {
        while (level < count && value >= thresholds[level]) ++level;
        return static_cast<uint8_t>(level);
    }
    level = previous;
    while (level < count && value >= thresholds[level] + margin) ++level;
    while (level > 0 && value < thresholds[level - 1] - margin) --level;
    return static_cast<uint8_t>(level);
}

constexpr int32_t VISUAL_RICH_LEVEL = 5;
constexpr int32_t VISUAL_POOR_LEVEL = 1;
constexpr int64_t VISUAL_SHARE_THRESHOLDS_Q16[3] = {
    NativeEconomyRuntime::Q16_ONE * 5 / 100, NativeEconomyRuntime::Q16_ONE * 20 / 100,
    NativeEconomyRuntime::Q16_ONE * 40 / 100,
};
constexpr int64_t VISUAL_SHARE_MARGIN_Q16 = NativeEconomyRuntime::Q16_ONE * 2 / 100;
constexpr int64_t VISUAL_LIVING_MARGIN_Q16 = NativeEconomyRuntime::Q16_ONE * 15 / 1000;
} // namespace

bool NativeEconomyRuntime::update_building_visual_social(
        int32_t cell, int64_t population, int64_t composite_q16, int64_t rich,
        int64_t poor) {
    const size_t index = static_cast<size_t>(cell);
    if (cell < 0 || index >= _visual_living_level.size()) return false;
    uint8_t living = BUILDING_VISUAL_UNKNOWN;
    uint8_t rich_bucket = BUILDING_VISUAL_UNKNOWN;
    uint8_t poor_bucket = BUILDING_VISUAL_UNKNOWN;
    if (population > 0) {
        living = hysteretic_band(composite_q16, LIVING_STANDARD_THRESHOLDS_Q16, 6,
                                 _visual_living_level[index], VISUAL_LIVING_MARGIN_Q16);
        rich_bucket = hysteretic_band(rich * Q16_ONE / population,
            VISUAL_SHARE_THRESHOLDS_Q16, 3, _visual_rich_bucket[index],
            VISUAL_SHARE_MARGIN_Q16);
        poor_bucket = hysteretic_band(poor * Q16_ONE / population,
            VISUAL_SHARE_THRESHOLDS_Q16, 3, _visual_poor_bucket[index],
            VISUAL_SHARE_MARGIN_Q16);
    }
    if (living == _visual_living_level[index] &&
        rich_bucket == _visual_rich_bucket[index] &&
        poor_bucket == _visual_poor_bucket[index])
        return false;
    _visual_living_level[index] = living;
    _visual_rich_bucket[index] = rich_bucket;
    _visual_poor_bucket[index] = poor_bucket;
    return true;
}

void NativeEconomyRuntime::mark_building_visual_cell(int32_t cell) {
    if (cell < 0 || cell >= _cell_count.get()) return;
    _building_visual_dirty_cells.push_back(cell);
    ++_building_visual_generation;
}

void NativeEconomyRuntime::rebuild_building_visual_social() {
    const size_t cells = static_cast<size_t>(std::max(0, _cell_count.get()));
    _visual_living_level.assign(cells, BUILDING_VISUAL_UNKNOWN);
    _visual_rich_bucket.assign(cells, BUILDING_VISUAL_UNKNOWN);
    _visual_poor_bucket.assign(cells, BUILDING_VISUAL_UNKNOWN);
    if (!_bootstrapped) return;
    for (int32_t cell = 0; cell < static_cast<int32_t>(cells); ++cell) {
        int64_t weighted = 0;
        int64_t population = 0;
        int64_t rich = 0;
        int64_t poor = 0;
        population_store().for_each_in_cell(cell, [&](int32_t slot) {
            const int64_t people = std::max<int64_t>(
                0, population_store().population[slot]);
            if (people <= 0) return;
            const int64_t composite = population_store().composite_satisfaction[slot];
            population = saturating_add(population, people, _saturation_count);
            weighted = saturating_add(weighted,
                saturating_mul(composite, people, _saturation_count),
                _saturation_count);
            const int32_t level = living_standard_level_for(composite);
            if (level >= VISUAL_RICH_LEVEL) rich += people;
            if (level <= VISUAL_POOR_LEVEL) poor += people;
        });
        if (population <= 0) continue;
        update_building_visual_social(cell, population,
            std::clamp<int64_t>(weighted / population, 0, Q16_ONE - 1), rich, poor);
    }
    ++_building_visual_generation;
}

void NativeEconomyRuntime::append_building_visual_social_rows(
        const std::vector<int32_t> &cells, Dictionary &out) const {
    PackedByteArray tiers;
    PackedByteArray living;
    PackedByteArray rich;
    PackedByteArray poor;
    tiers.resize(static_cast<int64_t>(cells.size()));
    living.resize(tiers.size());
    rich.resize(tiers.size());
    poor.resize(tiers.size());
    for (size_t i = 0; i < cells.size(); ++i) {
        const size_t cell = static_cast<size_t>(cells[i]);
        const int64_t at = static_cast<int64_t>(i);
        tiers.set(at, cell < _settlements.tier.size() ? _settlements.tier[cell] : 0);
        living.set(at, cell < _visual_living_level.size()
            ? _visual_living_level[cell] : BUILDING_VISUAL_UNKNOWN);
        rich.set(at, cell < _visual_rich_bucket.size()
            ? _visual_rich_bucket[cell] : BUILDING_VISUAL_UNKNOWN);
        poor.set(at, cell < _visual_poor_bucket.size()
            ? _visual_poor_bucket[cell] : BUILDING_VISUAL_UNKNOWN);
    }
    out["settlement_tiers"] = tiers;
    out["living_levels"] = living;
    out["rich_buckets"] = rich;
    out["poor_buckets"] = poor;
}

void NativeEconomyRuntime::publish_social_pressure_facts() {
    EconomyCostProbe probe("publish.social_pressure", _current_day.get());
    for (const int32_t cell : _epoch_settlement_cells) {
        if (cell < 0 || cell >= _cell_count.get() ||
            cell >= static_cast<int32_t>(_cell_social_pressure_level.size()))
            continue;
        int64_t weighted = 0;
        int64_t population = 0;
        int64_t rich = 0;
        int64_t poor = 0;
        int32_t grievance_slot = -1;
        int64_t grievance_q16 = Q16_ONE;
        population_store().for_each_in_cell(cell, [&](int32_t slot) {
            const int64_t people = std::max<int64_t>(
                0, population_store().population[slot]);
            if (people <= 0) return;
            const int64_t composite = population_store().composite_satisfaction[slot];
            population = saturating_add(population, people, _saturation_count);
            weighted = saturating_add(weighted,
                saturating_mul(composite, people, _saturation_count),
                _saturation_count);
            if (composite >= LIVING_STANDARD_THRESHOLDS_Q16[VISUAL_RICH_LEVEL - 1])
                rich += people;
            if (composite < LIVING_STANDARD_THRESHOLDS_Q16[VISUAL_POOR_LEVEL])
                poor += people;
            if (composite < grievance_q16) {
                grievance_q16 = composite;
                grievance_slot = slot;
            }
        });
        const int64_t composite_q16 = population <= 0 ? 0 : std::clamp<int64_t>(
            weighted / population, 0, Q16_ONE - 1);
        if (update_building_visual_social(cell, population, composite_q16, rich, poor))
            mark_building_visual_cell(cell);
        if (population <= 0) continue;
        const int32_t level = social_pressure_level_for(composite_q16);
        const int32_t previous = _cell_social_pressure_level[cell];
        if (level == previous) continue;
        _cell_social_pressure_level.write_scalar(cell, static_cast<uint8_t>(level), market_mutation_sink());
        CommittedGameplayFact fact;
        fact.kind = GAMEPLAY_FACT_SOCIAL_PRESSURE;
        fact.cell = cell;
        fact.entity_id = static_cast<int32_t>(std::clamp<int64_t>(
            population, 0, std::numeric_limits<int32_t>::max()));
        fact.value = composite_q16;
        const int32_t worst_dimension = grievance_slot >= 0 &&
                population_store().worst_dimension_id[grievance_slot] !=
                    std::numeric_limits<uint8_t>::max()
            ? static_cast<int32_t>(population_store().worst_dimension_id[grievance_slot])
            : -1;
        const int32_t worst_need = grievance_slot >= 0 &&
                population_store().worst_need_id[grievance_slot] !=
                    std::numeric_limits<uint16_t>::max()
            ? static_cast<int32_t>(population_store().worst_need_id[grievance_slot])
            : -1;
        fact.payload = {level, worst_dimension, worst_need, previous};
        fact.flags = level < previous ? 1 : 0;
        _staging_gameplay_facts.push_back(fact);
    }
}


void NativeEconomyRuntime::publish_technology_practice_facts() {
    EconomyCostProbe probe("publish.technology_practice", _current_day.get());
    if (_country_runtime == nullptr || _epoch_country_handles.empty() ||
        _building_technology_practice_masks.size() != _building_types.size())
        return;
    struct Aggregate {
        std::array<int64_t, PRACTICE_RULE_COUNT> values{};
        std::array<int32_t, PRACTICE_RULE_COUNT> groups{};
        std::array<int32_t, PRACTICE_RULE_COUNT> first_cells{};
        int32_t research_groups = 0;
        int32_t climate_samples = 0;
        Aggregate() { first_cells.fill(-1); }
    };
    std::vector<Aggregate> countries(_epoch_country_handles.size());
    std::vector<int32_t> crop_failure_cells(_epoch_country_handles.size(), -1);
    std::vector<int32_t> crop_failure_counts(_epoch_country_handles.size(), 0);
    auto add_first = [](Aggregate &aggregate, int32_t rule, int32_t cell) {
        if (aggregate.first_cells[static_cast<size_t>(rule)] < 0)
            aggregate.first_cells[static_cast<size_t>(rule)] = cell;
    };
    auto active_group = [](BuildingGroupConstRef group) {
        return group.count > 0 && group.last_output > 0 &&
            group.last_capacity_q16 > 0;
    };
    for (size_t pk_row = 0; pk_row < building_count(); ++pk_row) {
        const auto group = building_view(pk_row);
        if (group.count <= 0 || group.cell < 0 || group.cell >= _cell_count.get() ||
            group.type_id < 0 ||
            group.type_id >= static_cast<int32_t>(_building_types.size()) ||
            group.cell >= static_cast<int32_t>(_epoch_cell_country.size()))
            continue;
        const int32_t country = _epoch_cell_country[static_cast<size_t>(group.cell)];
        if (country < 0 || country >= static_cast<int32_t>(countries.size()) ||
            _epoch_country_handles[static_cast<size_t>(country)] == 0)
            continue;
        Aggregate &aggregate = countries[static_cast<size_t>(country)];
        const BuildingType &type = _building_types[static_cast<size_t>(group.type_id)];
        const bool climate_crop_failure = type.economic_sector == 0 &&
            group.operating_state != 1 &&
            group.last_climate_capacity_q16 <= Q16_ONE / 2 &&
            group.last_climate_lost_output > 0;
        if (climate_crop_failure) {
            ++crop_failure_counts[static_cast<size_t>(country)];
            if (crop_failure_cells[static_cast<size_t>(country)] < 0)
                crop_failure_cells[static_cast<size_t>(country)] = group.cell;
        }
        if (!active_group(group)) continue;
        const uint32_t mask = _building_technology_practice_masks[
            static_cast<size_t>(group.type_id)];
        for (int32_t rule = 0; rule < PRACTICE_RULE_COUNT; ++rule) {
            if ((mask & (uint32_t{1} << rule)) == 0) continue;
            ++aggregate.groups[static_cast<size_t>(rule)];
            add_first(aggregate, rule, group.cell);
        }
        const int64_t period_days = std::max(1, _epoch_days.get());
        const int64_t utilization_q16 = std::clamp<int64_t>(
            group.last_capacity_q16, 0, Q16_ONE);
        const int64_t effective_days = std::max<int64_t>(
            1, (period_days * utilization_q16) / Q16_ONE);
        if ((mask & (uint32_t{1} << PRACTICE_MAIZE_SELECTION)) != 0)
            aggregate.values[PRACTICE_MAIZE_SELECTION] = effective_days;
        if ((mask & (uint32_t{1} << PRACTICE_DRYLAND_DAYS)) != 0)
            aggregate.values[PRACTICE_DRYLAND_DAYS] = effective_days;
        if ((mask & (uint32_t{1} << PRACTICE_DRYLAND_DROUGHTS)) != 0) {
            const EnvironmentSample sample = environment_sample_for_cell(group.cell);
            if (sample.ready && sample.plant_available_water_q16 <= Q16_ONE / 4)
                aggregate.values[PRACTICE_DRYLAND_DROUGHTS] = 1;
        }
        if ((mask & (uint32_t{1} << PRACTICE_HYDRAULIC_ENGINEERING)) != 0) {
            const EnvironmentSample sample = environment_sample_for_cell(group.cell);
            if (sample.ready && sample.moisture_q16 >= (Q16_ONE * 7) / 8 &&
                sample.weather_q16 >= Q16_ONE / 2)
                aggregate.values[PRACTICE_HYDRAULIC_ENGINEERING] = 1;
        }
        if ((mask & (uint32_t{1} << PRACTICE_METALWORKING)) != 0)
            aggregate.values[PRACTICE_METALWORKING] = saturating_add(
                aggregate.values[PRACTICE_METALWORKING], group.last_output,
                _saturation_count);
        if ((mask & (uint32_t{1} << PRACTICE_PRINTING)) != 0)
            aggregate.values[PRACTICE_PRINTING] = saturating_add(
                aggregate.values[PRACTICE_PRINTING], group.last_output,
                _saturation_count);
        for (const int32_t rule : {PRACTICE_STEAM_POWER,
                                   PRACTICE_ELECTRIFICATION,
                                   PRACTICE_INDUSTRIAL_ORGANIZATION,
                                   PRACTICE_AUTOMATION}) {
            if ((mask & (uint32_t{1} << rule)) != 0)
                aggregate.values[static_cast<size_t>(rule)] = saturating_add(
                    aggregate.values[static_cast<size_t>(rule)], effective_days,
                    _saturation_count);
        }
        for (const int32_t rule : {PRACTICE_SEED_SAVING,
                                   PRACTICE_RAINFED_ADAPTATION,
                                   PRACTICE_PADDY_CONTROL,
                                   PRACTICE_TERRACE_MAINTENANCE,
                                   PRACTICE_MINE_SUPPORT,
                                   PRACTICE_MINE_DRAINAGE,
                                   PRACTICE_KILN_TEMPERATURE,
                                   PRACTICE_PRINT_CALIBRATION,
                                   PRACTICE_STEAM_SEALING,
                                   PRACTICE_MOTOR_WINDING,
                                   PRACTICE_ASSEMBLY_LINE,
                                   PRACTICE_DIGITAL_CONTROL,
                                   PRACTICE_MARITIME_OPERATIONS,
                                   PRACTICE_WATERSHED_MANAGEMENT,
                                   PRACTICE_FOREST_MANAGEMENT,
                                   PRACTICE_CHEMICAL_PROCESS_CONTROL,
                                   PRACTICE_ENERGY_CONTROL,
                                   PRACTICE_HIDE_WORKING}) {
            if ((mask & (uint32_t{1} << rule)) != 0)
                aggregate.values[static_cast<size_t>(rule)] = std::max(
                    aggregate.values[static_cast<size_t>(rule)], effective_days);
        }
        if (type.upgrade_family_id >= 0 &&
            type.upgrade_family_id < static_cast<int32_t>(
                _building_upgrade_family_ids.size()) &&
            _building_upgrade_family_ids[static_cast<size_t>(
                type.upgrade_family_id)] == "research_institution")
            ++aggregate.research_groups;
    }
    for (const int32_t cell : _epoch_settlement_cells) {
        if (cell < 0 || cell >= _cell_count.get() ||
            cell >= static_cast<int32_t>(_epoch_cell_country.size())) continue;
        const int32_t country = _epoch_cell_country[static_cast<size_t>(cell)];
        if (country < 0 || country >= static_cast<int32_t>(countries.size())) continue;
        const EnvironmentSample sample = environment_sample_for_cell(cell);
        if (!sample.ready) continue;
        const bool extreme = sample.weather_q16 >= (Q16_ONE * 3) / 4 ||
            sample.plant_available_water_q16 <= Q16_ONE / 5 ||
            sample.moisture_q16 >= (Q16_ONE * 7) / 8 ||
            sample.temperature_30d_q16 <= Q16_ONE / 8 ||
            sample.temperature_30d_q16 >= (Q16_ONE * 7) / 8;
        if (extreme) ++countries[static_cast<size_t>(country)].climate_samples;
    }
    static constexpr std::array<int32_t, PRACTICE_RULE_COUNT> SIGNAL_BY_RULE{
        0, 1, 1, 2, 3, 4, 5, 6, 7, 8, 9,
        10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21,
        22, 23, 24, 25, 26, 27};
    for (int32_t country = 0; country < static_cast<int32_t>(countries.size()); ++country) {
        Aggregate &aggregate = countries[static_cast<size_t>(country)];
        const uint64_t country_handle = _epoch_country_handles[static_cast<size_t>(country)];
        if (country_handle == 0) continue;
        aggregate.values[PRACTICE_CLIMATE_MODELING] =
            aggregate.groups[PRACTICE_CLIMATE_MODELING] > 0 &&
            aggregate.climate_samples >= 3 ? 1 : 0;
        if (aggregate.groups[PRACTICE_HYDRAULIC_ENGINEERING] < 2)
            aggregate.values[PRACTICE_HYDRAULIC_ENGINEERING] = 0;
        if (aggregate.groups[PRACTICE_STEAM_POWER] < 3)
            aggregate.values[PRACTICE_STEAM_POWER] = 0;
        if (aggregate.groups[PRACTICE_ELECTRIFICATION] < 3)
            aggregate.values[PRACTICE_ELECTRIFICATION] = 0;
        if (aggregate.groups[PRACTICE_INDUSTRIAL_ORGANIZATION] < 3)
            aggregate.values[PRACTICE_INDUSTRIAL_ORGANIZATION] = 0;
        if (aggregate.groups[PRACTICE_AUTOMATION] < 2)
            aggregate.values[PRACTICE_AUTOMATION] = 0;
        if (_bio_maize_signal_id < 0 ||
            country_reads().research_signal_evidence_count(
                country, _bio_maize_signal_id) < 3)
            aggregate.values[PRACTICE_MAIZE_SELECTION] = 0;
        bool metal_seen = false;
        for (const int32_t signal : _metal_resource_signal_ids) {
            if (signal >= 0 && country_reads().has_research_signal(country, signal)) {
                metal_seen = true;
                break;
            }
        }
        if (!metal_seen) aggregate.values[PRACTICE_METALWORKING] = 0;
        if (aggregate.research_groups <= 0)
            aggregate.values[PRACTICE_PRINTING] = 0;
        if (crop_failure_counts[static_cast<size_t>(country)] > 0 &&
            crop_failure_cells[static_cast<size_t>(country)] >= 0) {
            CommittedGameplayFact weather_fact;
            weather_fact.kind = GAMEPLAY_FACT_REPEATED_CROP_FAILURE;
            weather_fact.cell = crop_failure_cells[static_cast<size_t>(country)];
            weather_fact.entity_handle = country_handle;
            weather_fact.entity_id = country;
            // Accumulate qualifying economy cycles, not the number of farms in
            // one cycle. The payload retains the affected-group count.
            weather_fact.value = 1;
            weather_fact.payload = {6,
                crop_failure_counts[static_cast<size_t>(country)],
                crop_failure_cells[static_cast<size_t>(country)], 1};
            _staging_gameplay_facts.push_back(weather_fact);
        }
        for (int32_t rule = 0; rule < PRACTICE_RULE_COUNT; ++rule) {
            const int64_t value = aggregate.values[static_cast<size_t>(rule)];
            const int32_t signal_slot = SIGNAL_BY_RULE[static_cast<size_t>(rule)];
            const int32_t signal = _breakthrough_signal_ids[
                static_cast<size_t>(signal_slot)];
            const int32_t first_cell = aggregate.first_cells[static_cast<size_t>(rule)];
            if (value <= 0 || signal < 0 || first_cell < 0 ||
                country_reads().has_research_signal(country, signal))
                continue;
            CommittedGameplayFact fact;
            fact.kind = GAMEPLAY_FACT_TECHNOLOGY_PRACTICE;
            fact.cell = first_cell;
            fact.entity_handle = country_handle;
            fact.entity_id = country;
            fact.value = value;
            fact.payload = {rule, aggregate.groups[static_cast<size_t>(rule)],
                            first_cell, 1};
            _staging_gameplay_facts.push_back(fact);
        }
    }
}


bool NativeEconomyRuntime::trace_detail_for_cell(int32_t cell) const {
    if (_trace_mode == TRACE_FULL_DEBUG) return true;
    return _trace_mode == TRACE_SELECTIVE && cell >= 0 &&
           ((cell < static_cast<int32_t>(_trace_cell_mask.size()) &&
             _trace_cell_mask[cell] != 0) || cell == _inspector_trace_cell);
}

Dictionary NativeEconomyRuntime::country_class_opinion_snapshot_debug() const {
    const CountryClassOpinionSnapshot &snapshot =
        country_class_opinion_snapshot();
    PackedStringArray class_ids;
    PackedInt64Array country_handles;
    PackedInt32Array country_generations;
    PackedInt64Array population;
    PackedInt64Array funds;
    PackedInt64Array owner_employed;
    PackedInt64Array satisfaction_weighted;
    PackedInt32Array satisfaction_q16;
    for (const std::string &id : _political_class_ids)
        class_ids.append(String(id.c_str()));
    for (const uint64_t value : snapshot.country_handles)
        country_handles.append(static_cast<int64_t>(value));
    for (const uint32_t value : snapshot.country_generations)
        country_generations.append(static_cast<int32_t>(value));
    for (const int64_t value : snapshot.population) population.append(value);
    for (const int64_t value : snapshot.funds) funds.append(value);
    for (const int64_t value : snapshot.owner_employed)
        owner_employed.append(value);
    for (const int64_t value : snapshot.satisfaction_weighted)
        satisfaction_weighted.append(value);
    for (const int32_t value : snapshot.satisfaction_q16)
        satisfaction_q16.append(value);
    Dictionary out;
    out["ok"] = true;
    out["revision"] = static_cast<int64_t>(snapshot.revision);
    out["class_hash"] = static_cast<int64_t>(snapshot.class_hash);
    out["epoch_day"] = snapshot.epoch_day;
    out["commit_day"] = snapshot.commit_day;
    out["country_count"] = snapshot.country_count;
    out["class_count"] = snapshot.class_count;
    out["class_ids"] = class_ids;
    out["country_handles"] = country_handles;
    out["country_generations"] = country_generations;
    out["population"] = population;
    out["funds"] = funds;
    out["owner_employed"] = owner_employed;
    out["satisfaction_weighted"] = satisfaction_weighted;
    out["satisfaction_q16"] = satisfaction_q16;
    out["cells_scanned"] =
        static_cast<int64_t>(_class_opinion_cells_scanned);
    out["slots_scanned"] =
        static_cast<int64_t>(_class_opinion_slots_scanned);
    out["zero_population_rows"] =
        static_cast<int64_t>(_class_opinion_zero_population_rows);
    out["elapsed_ms"] = _class_opinion_ms;
    return out;
}


void NativeEconomyRuntime::trace_record_cashflow(int32_t cell, uint64_t cohort_handle,
                                                  int32_t source, int64_t income,
                                                  int64_t expense) {
    if (_production_result_sink != nullptr) {
        if (_trace_mode != TRACE_OFF && cell >= 0 &&
            cell == _staging_events.cashflow_cell && cohort_handle != 0 &&
            (income != 0 || expense != 0)) {
            _production_result_sink->cashflow_drafts.push_back(
                {cell, {cohort_handle, source, income, expense}});
        }
        return;
    }
    if (_trace_mode == TRACE_OFF || cell < 0 || cell != _staging_events.cashflow_cell ||
        cohort_handle == 0 || (income == 0 && expense == 0)) return;
    for (CashflowEntry &entry : _staging_events.cashflows) {
        if (entry.cohort_handle != cohort_handle || entry.source != source) continue;
        entry.income = saturating_add(entry.income, income, _saturation_count);
        entry.expense = saturating_add(entry.expense, expense, _saturation_count);
        return;
    }
    _staging_events.cashflows.push_back({cohort_handle, source, income, expense});
}


void NativeEconomyRuntime::trace_reconcile_inspector_cashflows() {
    const int32_t cell = _staging_events.cashflow_cell;
    if (cell < 0 || cell >= _cell_count.get()) return;
    population_store().for_each_in_cell(cell, [&](int32_t slot) {
        const uint64_t handle = population_store().handle_for_slot(slot);
        int64_t recorded_income = 0;
        int64_t recorded_expense = 0;
        for (const CashflowEntry &entry : _staging_events.cashflows) {
            if (entry.cohort_handle != handle) continue;
            recorded_income = saturating_add(recorded_income, entry.income, _saturation_count);
            recorded_expense = saturating_add(recorded_expense, entry.expense, _saturation_count);
        }
        const int64_t missing_income = std::max<int64_t>(
            0, population_store().epoch_income[slot] - recorded_income);
        const int64_t missing_expense = std::max<int64_t>(
            0, population_store().epoch_expense[slot] - recorded_expense);
        trace_record_cashflow(cell, handle, CASHFLOW_OTHER,
                              missing_income, missing_expense);
    });
    std::sort(_staging_events.cashflows.begin(), _staging_events.cashflows.end(),
              [](const CashflowEntry &a, const CashflowEntry &b) {
                  if (a.cohort_handle != b.cohort_handle) {
                      return a.cohort_handle < b.cohort_handle;
                  }
                  return a.source < b.source;
              });
    _staging_events.cashflow_complete = true;
}


void NativeEconomyRuntime::trace_begin_epoch() {
	_staging_gameplay_facts.clear();
    _staging_construction_receipts.clear();
    if (_trace_filter_pending) {
        _trace_cell_mask.swap(_pending_trace_cell_mask);
        _pending_trace_cell_mask.clear();
        _trace_filter_pending = false;
    }
    if (_inspector_trace_pending) {
        _inspector_trace_cell = _pending_inspector_trace_cell;
        _inspector_trace_pending = false;
    }
    _staging_events = {};
    _staging_events.epoch_id = _epoch_id.get();
    _staging_events.sample_day = _sample_day;
    _staging_events.commit_day = _sample_day < 0 ? _current_day.get() :
        _sample_day + std::max(0, _epoch_days.get() - 1);
    _staging_events.period_days = std::max(1, _epoch_days.get());
    const bool inspector_trace_due = _inspector_trace_cell >= 0 &&
        _inspector_trace_cell < _cell_count.get() &&
        cell_in_market_workset(_inspector_trace_cell, _sample_day);
    _staging_events.cashflow_cell =
        (_trace_mode == TRACE_SELECTIVE || _trace_mode == TRACE_FULL_DEBUG) &&
                inspector_trace_due
            ? _inspector_trace_cell : -1;
    if (_staging_events.cashflow_cell >= 0) {
        _staging_events.cashflows.reserve(64);
    }
    _staging_events.stream_hash = _event_stream_hash.get();
    _staging_events.stream_hash = trace_hash_mix(
        _staging_events.stream_hash, static_cast<uint64_t>(_staging_events.epoch_id));
    _staging_events.stream_hash = trace_hash_mix(
        _staging_events.stream_hash, static_cast<uint64_t>(_staging_events.sample_day));
    if (_trace_mode != TRACE_OFF) {
        const int64_t estimated_events = static_cast<int64_t>(market_store().market_count.get()) +
            static_cast<int64_t>(building_count()) * 3 +
            static_cast<int64_t>(_pending_commands.size()) + 64;
        _staging_events.events.reserve(static_cast<size_t>(std::clamp<int64_t>(
            estimated_events, 64, 250000)));
    }
}


void NativeEconomyRuntime::trace_append(int32_t kind, int32_t stage, int32_t cell,
                                        int32_t subject_kind, int64_t subject_id,
                                        int32_t subject_i0, int32_t subject_i1,
                                        int64_t value0, int64_t value1, int64_t value2,
                                        int64_t value3, const std::vector<EventLeg> *legs,
                                        int32_t flags) {
    if (_production_result_sink != nullptr) {
        if (_trace_mode != TRACE_OFF) {
            ProductionTraceDraft draft;
            draft.kind = kind;
            draft.stage = stage;
            draft.cell = cell;
            draft.subject_kind = subject_kind;
            draft.subject_id = subject_id;
            draft.subject_i0 = subject_i0;
            draft.subject_i1 = subject_i1;
            draft.value0 = value0;
            draft.value1 = value1;
            draft.value2 = value2;
            draft.value3 = value3;
            draft.flags = flags;
            if (legs != nullptr) draft.legs = *legs;
            _production_result_sink->trace_drafts.push_back(std::move(draft));
        }
        return;
    }
    if (_trace_mode == TRACE_OFF) return;
    EventRecord event;
    event.stage = stage;
    event.kind = kind;
    event.flags = flags;
    event.cell = cell;
    event.subject_kind = subject_kind;
    event.subject_id = subject_id;
    event.subject_i0 = subject_i0;
    event.subject_i1 = subject_i1;
    event.value0 = value0;
    event.value1 = value1;
    event.value2 = value2;
    event.value3 = value3;
    if (legs != nullptr && !legs->empty()) {
        const int64_t next_bytes = static_cast<int64_t>(
            (_staging_events.legs.size() + legs->size()) * sizeof(EventLeg));
        if (next_bytes <= _trace_detail_epoch_budget) {
            event.flags |= EVENT_FLAG_DETAIL_PRESENT;
            event.leg_begin = static_cast<uint32_t>(_staging_events.legs.size());
            event.leg_count = static_cast<uint32_t>(legs->size());
            _staging_events.legs.insert(_staging_events.legs.end(), legs->begin(), legs->end());
        } else {
            event.flags |= EVENT_FLAG_DETAIL_TRUNCATED;
            ++_trace_detail_truncated;
        }
    }
    event.event_id = _next_event_id.get() + static_cast<int64_t>(_staging_events.events.size());
    uint64_t hash = _staging_events.stream_hash;
    hash = trace_hash_mix(hash, static_cast<uint64_t>(event.event_id));
    hash = trace_hash_mix(hash, static_cast<uint64_t>(event.kind));
    hash = trace_hash_mix(hash, static_cast<uint64_t>(event.cell));
    hash = trace_hash_mix(hash, static_cast<uint64_t>(event.subject_id));
    hash = trace_hash_mix(hash, static_cast<uint64_t>(event.value0));
    hash = trace_hash_mix(hash, static_cast<uint64_t>(event.value1));
    hash = trace_hash_mix(hash, static_cast<uint64_t>(event.value2));
    hash = trace_hash_mix(hash, static_cast<uint64_t>(event.value3));
    for (uint32_t i = 0; i < event.leg_count; ++i) {
        const EventLeg &leg = _staging_events.legs[event.leg_begin + i];
        hash = trace_hash_mix(hash, static_cast<uint64_t>(leg.field));
        hash = trace_hash_mix(hash, static_cast<uint64_t>(leg.subject_id));
        hash = trace_hash_mix(hash, static_cast<uint64_t>(leg.key_id));
        hash = trace_hash_mix(hash, static_cast<uint64_t>(leg.before));
        hash = trace_hash_mix(hash, static_cast<uint64_t>(leg.after));
    }
    _staging_events.stream_hash = hash;
    _staging_events.events.push_back(event);
}


void NativeEconomyRuntime::trace_commit_epoch(int64_t population_error,
                                              int64_t money_error,
                                              int64_t goods_error) {
    const auto start = Clock::now();
    trace_reconcile_inspector_cashflows();
    trace_append(EVENT_EPOCH_COMMITTED, static_cast<int32_t>(Stage::AGGREGATE_PUBLISH), -1,
                 SUBJECT_NONE, _epoch_id.get(), -1, -1,
                 static_cast<int64_t>(_staging_events.events.size()),
                 population_error, money_error, goods_error, nullptr, 0);
    const int64_t event_count = static_cast<int64_t>(_staging_events.events.size());
    if (!_staging_gameplay_facts.empty()) {
        _committed_gameplay_facts.insert(_committed_gameplay_facts.end(),
            _staging_gameplay_facts.begin(), _staging_gameplay_facts.end());
        _staging_gameplay_facts.clear();
    }
    for (ConstructionCommandReceipt &receipt : _staging_construction_receipts) {
        receipt.receipt_id = _next_construction_receipt_id++;
        _committed_construction_receipts.push_back(std::move(receipt));
    }
    _staging_construction_receipts.clear();
    // The display batch consumes all of today's receipts, including days
    // with more entries than the diagnostic history page can return.
    while (_committed_construction_receipts.size() > 256U &&
           _committed_construction_receipts.front().settled_day < _current_day.get()) {
        _committed_construction_receipts.pop_front();
    }
    const int64_t leg_count = static_cast<int64_t>(_staging_events.legs.size());
    if (_trace_mode != TRACE_OFF) {
        _staging_events.first_event_id = _next_event_id.get();
        _next_event_id += event_count;
        _staging_events.last_event_id = _next_event_id.get() - 1;
        _event_stream_hash = _staging_events.stream_hash;
        _committed_event_batches.push_back(std::move(_staging_events));
    }
    _audit_history.push_back({_epoch_id.get(), _sample_day, _current_day.get(), event_count, leg_count,
                              population_error, money_error, goods_error,
                              _event_stream_hash.get()});
    while (static_cast<int32_t>(_audit_history.size()) > _trace_retention_epochs) {
        _audit_history.pop_front();
    }
    _staging_events = {};
    trace_evict_to_budget();
    _event_publish_ms += elapsed_ms(start);
}


void NativeEconomyRuntime::trace_abort_epoch() {
	_staging_gameplay_facts.clear();
    _staging_construction_receipts.clear();
    if (!_staging_events.events.empty()) {
        _trace_uncommitted_discarded += static_cast<int64_t>(_staging_events.events.size());
    }
    _staging_events = {};
}


int64_t NativeEconomyRuntime::trace_memory_bytes() const {
    int64_t bytes = _staging_events.bytes();
    for (const EventBatch &batch : _committed_event_batches) bytes += batch.bytes();
    bytes += static_cast<int64_t>(_audit_history.size() * sizeof(AuditFrame));
    bytes += static_cast<int64_t>(_trace_cell_mask.capacity() +
                                  _pending_trace_cell_mask.capacity());
    return bytes;
}


void NativeEconomyRuntime::trace_evict_to_budget() {
    if (_event_archive.active) return;
    while (!_committed_event_batches.empty() &&
           (static_cast<int32_t>(_committed_event_batches.size()) > _trace_retention_epochs ||
            trace_memory_bytes() > _trace_memory_budget)) {
        const EventBatch &batch = _committed_event_batches.front();
        if (batch.last_event_id > 0) {
            if (_first_evicted_event_id == 0) _first_evicted_event_id = batch.first_event_id;
            _event_evicted_count += static_cast<int64_t>(batch.events.size());
        }
        _committed_event_batches.pop_front();
    }
}


} // namespace pk

