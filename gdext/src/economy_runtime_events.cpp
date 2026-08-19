#include "economy_runtime.h"
#include "economy_runtime_binary_codec.h"
#include "economy_runtime_variant_helpers.h"
#include "country_runtime.h"

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

constexpr uint32_t EVENT_ARCHIVE_MAGIC = 0x4a454b50U; // "PKEJ" little endian
constexpr uint16_t EVENT_ARCHIVE_VERSION = 3;
constexpr uint16_t EVENT_ARCHIVE_HEADER = 0;
constexpr uint16_t EVENT_ARCHIVE_EVENTS = 1;
constexpr uint16_t EVENT_ARCHIVE_END = 2;

PackedByteArray make_event_archive_chunk(uint16_t section, uint32_t records,
                                         const std::vector<uint8_t> &payload) {
    std::vector<uint8_t> bytes;
    bytes.reserve(16 + payload.size());
    append_le<uint32_t>(bytes, EVENT_ARCHIVE_MAGIC);
    append_le<uint16_t>(bytes, EVENT_ARCHIVE_VERSION);
    append_le<uint16_t>(bytes, section);
    append_le<uint32_t>(bytes, records);
    append_le<uint32_t>(bytes, static_cast<uint32_t>(payload.size()));
    bytes.insert(bytes.end(), payload.begin(), payload.end());
    PackedByteArray out;
    out.resize(static_cast<int64_t>(bytes.size()));
    if (!bytes.empty()) std::memcpy(out.ptrw(), bytes.data(), bytes.size());
    return out;
}
} // namespace

void NativeEconomyRuntime::publish_social_pressure_facts() {
    for (const int32_t cell : _epoch_settlement_cells) {
        if (cell < 0 || cell >= _cell_count ||
            cell >= static_cast<int32_t>(_cell_social_pressure_level.size()))
            continue;
        int64_t weighted = 0;
        int64_t population = 0;
        int32_t grievance_slot = -1;
        int64_t grievance_q16 = Q16_ONE;
        _population.for_each_in_cell(cell, [&](int32_t slot) {
            const int64_t people = std::max<int64_t>(
                0, _population.population[slot]);
            if (people <= 0) return;
            const int64_t composite = _population.composite_satisfaction[slot];
            population = saturating_add(population, people, _saturation_count);
            weighted = saturating_add(weighted,
                saturating_mul(composite, people, _saturation_count),
                _saturation_count);
            if (composite < grievance_q16) {
                grievance_q16 = composite;
                grievance_slot = slot;
            }
        });
        if (population <= 0) continue;
        const int64_t composite_q16 = std::clamp<int64_t>(
            weighted / population, 0, Q16_ONE - 1);
        const int32_t level = social_pressure_level_for(composite_q16);
        const int32_t previous = _cell_social_pressure_level[cell];
        if (level == previous) continue;
        _cell_social_pressure_level[cell] = static_cast<uint8_t>(level);
        CommittedGameplayFact fact;
        fact.kind = GAMEPLAY_FACT_SOCIAL_PRESSURE;
        fact.cell = cell;
        fact.entity_id = static_cast<int32_t>(std::clamp<int64_t>(
            population, 0, std::numeric_limits<int32_t>::max()));
        fact.value = composite_q16;
        const int32_t worst_dimension = grievance_slot >= 0 &&
                _population.worst_dimension_id[grievance_slot] !=
                    std::numeric_limits<uint8_t>::max()
            ? static_cast<int32_t>(_population.worst_dimension_id[grievance_slot])
            : -1;
        const int32_t worst_need = grievance_slot >= 0 &&
                _population.worst_need_id[grievance_slot] !=
                    std::numeric_limits<uint16_t>::max()
            ? static_cast<int32_t>(_population.worst_need_id[grievance_slot])
            : -1;
        fact.payload = {level, worst_dimension, worst_need, previous};
        fact.flags = level < previous ? 1 : 0;
        _staging_gameplay_facts.push_back(fact);
    }
}


void NativeEconomyRuntime::publish_technology_practice_facts() {
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
    auto active_group = [](const BuildingGroup &group) {
        return group.count > 0 && group.last_output > 0 &&
            group.last_capacity_q16 > 0;
    };
    for (const BuildingGroup &group : _buildings) {
        if (group.count <= 0 || group.cell < 0 || group.cell >= _cell_count ||
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
        const int64_t period_days = std::max(1, _epoch_days);
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
                                   PRACTICE_ENERGY_CONTROL}) {
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
        if (cell < 0 || cell >= _cell_count ||
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
        22, 23, 24, 25, 26};
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
            _country_runtime->research_signal_evidence_count(
                country, _bio_maize_signal_id) < 3)
            aggregate.values[PRACTICE_MAIZE_SELECTION] = 0;
        bool metal_seen = false;
        for (const int32_t signal : _metal_resource_signal_ids) {
            if (signal >= 0 && _country_runtime->has_research_signal(country, signal)) {
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
                _country_runtime->has_research_signal(country, signal))
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


void NativeEconomyRuntime::publish_country_development_facts() {
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
    class_snapshot.commit_day = _current_day;
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
    uint64_t cells_scanned = 0;
    uint64_t slots_scanned = 0;
    auto finalize_class_snapshot = [&]() {
        uint64_t zero_population_rows = 0;
        for (size_t row = 0; row < class_row_count; ++row) {
            const int64_t population =
                class_snapshot.population[row];
            if (population <= 0) {
                ++zero_population_rows;
                class_snapshot.satisfaction_q16[row] = 0;
                continue;
            }
            class_snapshot.satisfaction_q16[row] =
                static_cast<int32_t>(std::clamp<int64_t>(
                    class_snapshot.satisfaction_weighted[row] /
                        population, 0, Q16_ONE));
        }
        _class_opinion_cells_scanned += cells_scanned;
        _class_opinion_slots_scanned += slots_scanned;
        _last_class_opinion_cells_scanned = cells_scanned;
        _last_class_opinion_slots_scanned = slots_scanned;
        _class_opinion_zero_population_rows += zero_population_rows;
        _last_class_opinion_zero_population_rows = zero_population_rows;
        _class_opinion_ms = elapsed_ms(class_opinion_started);
        _class_opinion_committed_buffer =
            1 - _class_opinion_committed_buffer;
    };

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

    // `_market_cells` is the existing stable market/settlement CSR. Only cells
    // with a committed population are evidence-bearing settlements; empty map
    // cells never enter the development scan or emit a fact.
    if (_committed_cells.size() == static_cast<size_t>(_cell_count)) {
        for (const int32_t cell : _market_cells) {
            ++cells_scanned;
            if (cell < 0 || cell >= _cell_count ||
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
            _population.for_each_in_cell(cell, [&](int32_t slot) {
                ++slots_scanned;
                const int64_t people = std::max<int64_t>(
                    0, _population.population[static_cast<size_t>(slot)]);
                if (people <= 0) return;
                cell_population = saturating_add(cell_population, people,
                                                 _saturation_count);
                cell_satisfaction = saturating_add(cell_satisfaction,
                    saturating_mul(static_cast<int64_t>(_population
                        .composite_satisfaction[static_cast<size_t>(slot)]),
                        people, _saturation_count), _saturation_count);
                const uint32_t signature_id =
                    _population.signature_id[static_cast<size_t>(slot)];
                if (signature_id >= _signatures.size()) return;
                const int32_t profession =
                    _signatures[signature_id].profession_id;
                if (profession < 0 || profession >= static_cast<int32_t>(
                        _profession_political_class_index.size()))
                    return;
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
                    std::max<int64_t>(0, _population.funds[
                        static_cast<size_t>(slot)]), _saturation_count);
                class_snapshot.owner_employed[class_row] = saturating_add(
                    class_snapshot.owner_employed[class_row],
                    std::max<int64_t>(0, _population.owner_employed[
                        static_cast<size_t>(slot)]), _saturation_count);
                class_snapshot.satisfaction_weighted[class_row] =
                    saturating_add(
                        class_snapshot.satisfaction_weighted[class_row],
                        saturating_mul(static_cast<int64_t>(
                            _population.composite_satisfaction[
                                static_cast<size_t>(slot)]),
                            people, _saturation_count),
                        _saturation_count);
            });
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
    finalize_class_snapshot();
    if (!publish_development) return;

    const int64_t period_days = std::max<int64_t>(1, _epoch_days);
    for (const BuildingGroup &group : _buildings) {
        if (group.count <= 0 || group.cell < 0 || group.cell >= _cell_count ||
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
        int64_t employment = std::max<int64_t>(0, group.filled_owner);
        if (group.employee_fill_begin >= 0 && group.type_id >= 0) {
            for (int32_t role = 0; role < type.employee_count; ++role) {
                const int32_t index = group.employee_fill_begin + role;
                if (index >= 0 && index < static_cast<int32_t>(
                        _building_employee_filled.size()))
                    employment = saturating_add(employment,
                        std::max<int64_t>(0, _building_employee_filled[
                            static_cast<size_t>(index)]), _saturation_count);
            }
        }
        for (size_t metric = 0; metric < metric_count; ++metric) {
            const int32_t metric_type = _development_metric_types[metric];
            if (!metric_matches_group(metric, group.type_id, type)) continue;
            if (metric_type == METRIC_BUILDING_INSTALLED) {
                metric_at(country, metric).value = saturating_add(
                    metric_at(country, metric).value, group.count, _saturation_count);
            } else if (metric_type == METRIC_BUILDING_ACTIVE && active) {
                metric_at(country, metric).value = saturating_add(
                    metric_at(country, metric).value, group.count, _saturation_count);
            } else if (metric_type == METRIC_INDUSTRY_EMPLOYMENT) {
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

    for (int32_t country = 0; country < _epoch_country_count; ++country) {
        if (_epoch_country_handles[static_cast<size_t>(country)] == 0 ||
            metric_at(country, 0).first_cell < 0)
            continue;
        const size_t country_index = static_cast<size_t>(country);
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
            if (signal < 0 || _country_runtime->has_research_signal(country, signal))
                continue;
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
    if (cell < 0 || cell >= _cell_count) return;
    _population.for_each_in_cell(cell, [&](int32_t slot) {
        const uint64_t handle = _population.handle_for_slot(slot);
        int64_t recorded_income = 0;
        int64_t recorded_expense = 0;
        for (const CashflowEntry &entry : _staging_events.cashflows) {
            if (entry.cohort_handle != handle) continue;
            recorded_income = saturating_add(recorded_income, entry.income, _saturation_count);
            recorded_expense = saturating_add(recorded_expense, entry.expense, _saturation_count);
        }
        const int64_t missing_income = std::max<int64_t>(
            0, _population.epoch_income[slot] - recorded_income);
        const int64_t missing_expense = std::max<int64_t>(
            0, _population.epoch_expense[slot] - recorded_expense);
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
    _staging_events.epoch_id = _epoch_id;
    _staging_events.sample_day = _sample_day;
    _staging_events.commit_day = _sample_day < 0 ? _current_day :
        _sample_day + std::max(0, _epoch_days - 1);
    _staging_events.period_days = std::max(1, _epoch_days);
    const bool inspector_trace_due = _inspector_trace_cell >= 0 &&
        _inspector_trace_cell < _cell_count &&
        cell_in_market_workset(_inspector_trace_cell, _sample_day);
    _staging_events.cashflow_cell =
        (_trace_mode == TRACE_SELECTIVE || _trace_mode == TRACE_FULL_DEBUG) &&
                inspector_trace_due
            ? _inspector_trace_cell : -1;
    if (_staging_events.cashflow_cell >= 0) {
        _staging_events.cashflows.reserve(64);
    }
    _staging_events.stream_hash = _event_stream_hash;
    _staging_events.stream_hash = trace_hash_mix(
        _staging_events.stream_hash, static_cast<uint64_t>(_staging_events.epoch_id));
    _staging_events.stream_hash = trace_hash_mix(
        _staging_events.stream_hash, static_cast<uint64_t>(_staging_events.sample_day));
    if (_trace_mode != TRACE_OFF) {
        const int64_t estimated_events = static_cast<int64_t>(_market.market_count) +
            static_cast<int64_t>(_buildings.size()) * 3 +
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
    event.event_id = _next_event_id + static_cast<int64_t>(_staging_events.events.size());
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
                 SUBJECT_NONE, _epoch_id, -1, -1,
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
    while (_committed_construction_receipts.size() > 256U) {
        _committed_construction_receipts.pop_front();
    }
    const int64_t leg_count = static_cast<int64_t>(_staging_events.legs.size());
    if (_trace_mode != TRACE_OFF) {
        _staging_events.first_event_id = _next_event_id;
        _next_event_id += event_count;
        _staging_events.last_event_id = _next_event_id - 1;
        _event_stream_hash = _staging_events.stream_hash;
        _committed_event_batches.push_back(std::move(_staging_events));
    }
    _audit_history.push_back({_epoch_id, _sample_day, _current_day, event_count, leg_count,
                              population_error, money_error, goods_error,
                              _event_stream_hash});
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


Dictionary NativeEconomyRuntime::event_schema() const {
    Dictionary out;
    out["version"] = 5;
    out["format"] = "economy_header_and_delta_legs";
    Dictionary kinds;
    kinds["COMMAND_SETTLED"] = EVENT_COMMAND_SETTLED;
    kinds["MARKET_SETTLED"] = EVENT_MARKET_SETTLED;
    kinds["STRUCTURAL_CHANGE"] = EVENT_STRUCTURAL_CHANGE;
    kinds["CONSTRUCTION_STARTED"] = EVENT_CONSTRUCTION_STARTED;
    kinds["CONSTRUCTION_COMPLETED"] = EVENT_CONSTRUCTION_COMPLETED;
    kinds["BUILDING_DEMOLISHED"] = EVENT_BUILDING_DEMOLISHED;
    kinds["EMPLOYMENT_SETTLED"] = EVENT_EMPLOYMENT_SETTLED;
    kinds["WAGE_SETTLED"] = EVENT_WAGE_SETTLED;
    kinds["BUILDING_PRODUCTION_SETTLED"] = EVENT_BUILDING_PRODUCTION_SETTLED;
    kinds["EPOCH_COMMITTED"] = EVENT_EPOCH_COMMITTED;
    kinds["RESTORE_BOUNDARY"] = EVENT_RESTORE_BOUNDARY;
    kinds["TRADE_DISPATCHED"] = EVENT_TRADE_DISPATCHED;
    kinds["TRADE_ARRIVED"] = EVENT_TRADE_ARRIVED;
    kinds["POPULATION_SOURCE"] = EVENT_POPULATION_SOURCE;
    kinds["TARIFF_SUBSIDY_INTENT"] = EVENT_TARIFF_SUBSIDY_INTENT;
    out["kinds"] = kinds;
    Dictionary fields;
    fields["COHORT_POPULATION"] = FIELD_COHORT_POPULATION;
    fields["COHORT_FUNDS"] = FIELD_COHORT_FUNDS;
    fields["COHORT_EPOCH_INCOME"] = FIELD_COHORT_EPOCH_INCOME;
    fields["COHORT_EPOCH_EXPENSE"] = FIELD_COHORT_EPOCH_EXPENSE;
    fields["COHORT_INCOME_EMA"] = FIELD_COHORT_INCOME_EMA;
    fields["COHORT_SATISFACTION"] = FIELD_COHORT_SATISFACTION;
    fields["COHORT_WORST_NEED"] = FIELD_COHORT_WORST_NEED;
    fields["COHORT_OWNER_EMPLOYED"] = FIELD_COHORT_OWNER_EMPLOYED;
    fields["COHORT_EMPLOYEE_EMPLOYED"] = FIELD_COHORT_EMPLOYEE_EMPLOYED;
    fields["COHORT_SIGNATURE"] = FIELD_COHORT_SIGNATURE;
    fields["TREASURY_CASH"] = FIELD_TREASURY_CASH;
    fields["MARKET_STOCK"] = FIELD_MARKET_STOCK;
    fields["MARKET_PRICE"] = FIELD_MARKET_PRICE;
    fields["MARKET_DEMAND_EMA"] = FIELD_MARKET_DEMAND_EMA;
    fields["MARKET_SHORTAGE"] = FIELD_MARKET_SHORTAGE;
    fields["BUILDING_COUNT"] = FIELD_BUILDING_COUNT;
    fields["BUILDING_OWNER_FILLED"] = FIELD_BUILDING_OWNER_FILLED;
    fields["BUILDING_EMPLOYEE_FILLED"] = FIELD_BUILDING_EMPLOYEE_FILLED;
    fields["BUILDING_CAPACITY"] = FIELD_BUILDING_CAPACITY;
    fields["BUILDING_INPUT"] = FIELD_BUILDING_INPUT;
    fields["BUILDING_OUTPUT"] = FIELD_BUILDING_OUTPUT;
    fields["BUILDING_SOLD"] = FIELD_BUILDING_SOLD;
    fields["BUILDING_DISCARDED"] = FIELD_BUILDING_DISCARDED;
    fields["BUILDING_RESOURCE"] = FIELD_BUILDING_RESOURCE;
    fields["BUILDING_RESOURCE_GENERATED"] = FIELD_BUILDING_RESOURCE_GENERATED;
    fields["BUILDING_REVENUE"] = FIELD_BUILDING_REVENUE;
    fields["BUILDING_INPUT_COST"] = FIELD_BUILDING_INPUT_COST;
    fields["BUILDING_WAGES_PAID"] = FIELD_BUILDING_WAGES_PAID;
    fields["BUILDING_WAGES_DUE"] = FIELD_BUILDING_WAGES_DUE;
    fields["BUILDING_EXPECTED_REVENUE"] = FIELD_BUILDING_EXPECTED_REVENUE;
    fields["BUILDING_OPERATING_COST"] = FIELD_BUILDING_OPERATING_COST;
    fields["BUILDING_MARGIN_GAP"] = FIELD_BUILDING_MARGIN_GAP;
    fields["BUILDING_PLANNED_UTILIZATION"] = FIELD_BUILDING_PLANNED_UTILIZATION;
    fields["BUILDING_BASE_WAGES_PAID"] = FIELD_BUILDING_BASE_WAGES_PAID;
    fields["BUILDING_BASE_WAGES_DUE"] = FIELD_BUILDING_BASE_WAGES_DUE;
    fields["BUILDING_BONUS_PAID"] = FIELD_BUILDING_BONUS_PAID;
    fields["BUILDING_BONUS_DUE"] = FIELD_BUILDING_BONUS_DUE;
    fields["BUILDING_WAGE_SUSPENDED"] = FIELD_BUILDING_WAGE_SUSPENDED;
    fields["RESOURCE_DELTA"] = FIELD_RESOURCE_DELTA;
    fields["COHORT_DEMOGRAPHY_RESIDUAL"] = FIELD_COHORT_DEMOGRAPHY_RESIDUAL;
    fields["TRADE_QUANTITY"] = FIELD_TRADE_QUANTITY;
    fields["TRADE_BASE_VALUE"] = FIELD_TRADE_BASE_VALUE;
    fields["TRADE_RETAIL_VALUE"] = FIELD_TRADE_RETAIL_VALUE;
    fields["TRADE_IMPORT_TRANSFER"] = FIELD_TRADE_IMPORT_TRANSFER;
    fields["TRADE_EXPORT_TRANSFER"] = FIELD_TRADE_EXPORT_TRANSFER;
    out["fields"] = fields;
    Dictionary cashflow_sources;
    cashflow_sources["WAGES"] = CASHFLOW_WAGES;
    cashflow_sources["OWNER_OPERATIONS"] = CASHFLOW_OWNER_OPERATIONS;
    cashflow_sources["MERCHANT_HOUSEHOLD_SALES"] = CASHFLOW_MERCHANT_HOUSEHOLD;
    cashflow_sources["MERCHANT_BUSINESS_SALES"] = CASHFLOW_MERCHANT_BUSINESS;
    cashflow_sources["TRANSFER"] = CASHFLOW_TRANSFER;
    cashflow_sources["HOUSEHOLD_CONSUMPTION"] = CASHFLOW_HOUSEHOLD_CONSUMPTION;
    cashflow_sources["PRODUCTION_INPUTS"] = CASHFLOW_PRODUCTION_INPUT;
    cashflow_sources["OWNER_WAGES"] = CASHFLOW_OWNER_WAGES;
    cashflow_sources["CONSTRUCTION"] = CASHFLOW_CONSTRUCTION;
    cashflow_sources["MERCHANT_PROCUREMENT"] = CASHFLOW_MERCHANT_PROCUREMENT;
    cashflow_sources["OTHER"] = CASHFLOW_OTHER;
    cashflow_sources["PRODUCER_SUPPORT_ISSUANCE"] = CASHFLOW_PRODUCER_SUPPORT;
    cashflow_sources["INCOME_TAX"] = CASHFLOW_INCOME_TAX;
    cashflow_sources["CONSUMPTION_TAX"] = CASHFLOW_CONSUMPTION_TAX;
    cashflow_sources["BUSINESS_TAX"] = CASHFLOW_BUSINESS_TAX;
    cashflow_sources["INCOME_SUBSIDY"] = CASHFLOW_INCOME_SUBSIDY;
    cashflow_sources["CONSUMPTION_SUBSIDY"] = CASHFLOW_CONSUMPTION_SUBSIDY;
    cashflow_sources["BUSINESS_SUBSIDY"] = CASHFLOW_BUSINESS_SUBSIDY;
    cashflow_sources["FISCAL_ESCROW"] = CASHFLOW_FISCAL_ESCROW;
    cashflow_sources["IMPORT_TAX"] = CASHFLOW_IMPORT_TAX;
    cashflow_sources["EXPORT_TAX"] = CASHFLOW_EXPORT_TAX;
    cashflow_sources["IMPORT_SUBSIDY"] = CASHFLOW_IMPORT_SUBSIDY;
    cashflow_sources["EXPORT_SUBSIDY"] = CASHFLOW_EXPORT_SUBSIDY;
    out["cashflow_sources"] = cashflow_sources;
    out["money_scale"] = MONEY_SCALE;
    out["goods_scale"] = GOODS_SCALE;
    out["ratio_scale"] = Q16_ONE;
    return out;
}


Dictionary NativeEconomyRuntime::set_trace_filter(const Dictionary &filter) {
    Dictionary out;
    std::vector<int32_t> cells = packed_i32(filter, "cells");
    std::vector<uint8_t> mask(static_cast<size_t>(std::max(0, _cell_count)), 0);
    for (int32_t cell : cells) {
        if (cell < 0 || cell >= _cell_count) {
            out["ok"] = false;
            out["reason"] = "economy_trace_cell_out_of_range";
            return out;
        }
        mask[cell] = 1;
    }
    if (_epoch_active) {
        _pending_trace_cell_mask = std::move(mask);
        _trace_filter_pending = true;
    } else {
        _trace_cell_mask = std::move(mask);
        _pending_trace_cell_mask.clear();
        _trace_filter_pending = false;
    }
    out["ok"] = true;
    out["effective_next_epoch"] = _epoch_active;
    out["cell_count"] = static_cast<int64_t>(cells.size());
    return out;
}


Dictionary NativeEconomyRuntime::set_inspector_trace_cell(int32_t cell_idx) {
    Dictionary out;
    if (cell_idx < -1 || cell_idx >= _cell_count) {
        out["ok"] = false;
        out["reason"] = "economy_inspector_trace_cell_out_of_range";
        return out;
    }
    if (_epoch_active) {
        _pending_inspector_trace_cell = cell_idx;
        _inspector_trace_pending = true;
    } else {
        _inspector_trace_cell = cell_idx;
        _pending_inspector_trace_cell = cell_idx;
        _inspector_trace_pending = false;
    }
    if (cell_idx != _investment_diagnostic_cell) {
        _investment_diagnostic_cell = -1;
        _investment_diagnostic_day = -1;
        _investment_diagnostics.clear();
    }
    out["ok"] = true;
    out["cell_idx"] = cell_idx;
    out["effective_next_epoch"] = _epoch_active;
    return out;
}


Dictionary NativeEconomyRuntime::poll_events(const Dictionary &opts) const {
    const StringName consumer = opts.has("consumer_id")
        ? StringName(opts["consumer_id"]) : StringName("default");
    const std::string consumer_key = to_utf8(String(consumer));
    const auto ack_it = _event_consumer_ack.find(consumer_key);
    const int64_t acked = ack_it == _event_consumer_ack.end() ? 0 : ack_it->second;
    const int64_t after = dict_num<int64_t>(opts, "after_event_id", acked);
    const int32_t max_events = std::clamp(
        dict_num<int32_t>(opts, "max_events", _trace_poll_max_events), 1, 65536);
    const int32_t kind_filter = dict_num<int32_t>(opts, "kind", 0);
    const int32_t cell_filter = dict_num<int32_t>(opts, "cell", -1);
    PackedInt64Array event_id, cause_id, epoch_id, sample_day, commit_day, subject_id;
    PackedInt32Array period_days, stage, kind, flags, cell, subject_kind, subject_i0,
        subject_i1, leg_offset, leg_count;
    PackedInt64Array value0, value1, value2, value3;
    PackedInt32Array leg_field, leg_subject_kind, leg_key_id;
    PackedInt64Array leg_subject_id, leg_before, leg_after;
    int64_t last_id = after;
    for (const EventBatch &batch : _committed_event_batches) {
        if (batch.last_event_id <= after) continue;
        for (const EventRecord &event : batch.events) {
            if (event.event_id <= after || (kind_filter > 0 && event.kind != kind_filter) ||
                (cell_filter >= 0 && event.cell != cell_filter)) continue;
            event_id.append(event.event_id); cause_id.append(event.event_id);
            epoch_id.append(batch.epoch_id); sample_day.append(batch.sample_day);
            commit_day.append(batch.commit_day); period_days.append(batch.period_days);
            stage.append(event.stage); kind.append(event.kind); flags.append(event.flags);
            cell.append(event.cell); subject_kind.append(event.subject_kind);
            subject_id.append(event.subject_id); subject_i0.append(event.subject_i0);
            subject_i1.append(event.subject_i1);
            leg_offset.append(leg_field.size()); leg_count.append(event.leg_count);
            value0.append(event.value0); value1.append(event.value1);
            value2.append(event.value2); value3.append(event.value3);
            for (uint32_t i = 0; i < event.leg_count; ++i) {
                const EventLeg &leg = batch.legs[event.leg_begin + i];
                leg_field.append(leg.field); leg_subject_kind.append(leg.subject_kind);
                leg_subject_id.append(leg.subject_id); leg_key_id.append(leg.key_id);
                leg_before.append(leg.before); leg_after.append(leg.after);
            }
            last_id = event.event_id;
            if (event_id.size() >= max_events) break;
        }
        if (event_id.size() >= max_events) break;
    }
    Dictionary out;
    out["event_id"] = event_id; out["cause_id"] = cause_id; out["epoch_id"] = epoch_id;
    out["sample_day"] = sample_day; out["commit_day"] = commit_day;
    out["period_days"] = period_days; out["stage"] = stage; out["kind"] = kind;
    out["flags"] = flags; out["cell"] = cell; out["subject_kind"] = subject_kind;
    out["subject_id"] = subject_id; out["subject_i0"] = subject_i0;
    out["subject_i1"] = subject_i1; out["leg_offset"] = leg_offset;
    out["leg_count"] = leg_count; out["value0"] = value0; out["value1"] = value1;
    out["value2"] = value2; out["value3"] = value3;
    out["leg_field"] = leg_field; out["leg_subject_kind"] = leg_subject_kind;
    out["leg_subject_id"] = leg_subject_id; out["leg_key_id"] = leg_key_id;
    out["leg_before"] = leg_before; out["leg_after"] = leg_after;
    out["count"] = event_id.size(); out["last_event_id"] = last_id;
    out["consumer_id"] = consumer;
    out["consumer_lag"] = std::max<int64_t>(0, _next_event_id - 1 - last_id);
    out["gap"] = !_committed_event_batches.empty() &&
        after < _committed_event_batches.front().first_event_id - 1;
    out["ok"] = true;
    return out;
}


Dictionary NativeEconomyRuntime::ack_events(const StringName &consumer_id,
                                            int64_t up_to_event_id) {
    const std::string key = to_utf8(String(consumer_id));
    const int64_t previous = _event_consumer_ack.count(key) ? _event_consumer_ack[key] : 0;
    const int64_t next = std::max(previous, up_to_event_id);
    _event_consumer_ack[key] = next;
    Dictionary out;
    out["ok"] = true;
    out["consumer_id"] = consumer_id;
    out["previous_event_id"] = previous;
    out["acked_event_id"] = next;
    return out;
}


Dictionary NativeEconomyRuntime::trace_report() const {
    Dictionary out;
    int64_t events = 0, legs = 0;
    for (const EventBatch &batch : _committed_event_batches) {
        events += static_cast<int64_t>(batch.events.size());
        legs += static_cast<int64_t>(batch.legs.size());
    }
    out["ok"] = true;
    out["mode"] = _trace_mode == TRACE_OFF ? "OFF" :
        (_trace_mode == TRACE_SUMMARY ? "SUMMARY" :
        (_trace_mode == TRACE_FULL_DEBUG ? "FULL_DEBUG" : "SELECTIVE"));
    out["event_count"] = events;
    out["leg_count"] = legs;
    out["batch_count"] = static_cast<int64_t>(_committed_event_batches.size());
    out["audit_frame_count"] = static_cast<int64_t>(_audit_history.size());
    out["oldest_event_id"] = _committed_event_batches.empty() ? 0 :
        _committed_event_batches.front().first_event_id;
    out["newest_event_id"] = _next_event_id - 1;
    out["next_event_id"] = _next_event_id;
    out["stream_hash"] = static_cast<int64_t>(_event_stream_hash);
    out["memory_bytes"] = trace_memory_bytes();
    out["memory_budget_bytes"] = _trace_memory_budget;
    out["evicted_event_count"] = _event_evicted_count;
    out["first_evicted_event_id"] = _first_evicted_event_id;
    out["detail_truncated_count"] = _trace_detail_truncated;
    out["uncommitted_discarded_count"] = _trace_uncommitted_discarded;
    out["filter_pending"] = _trace_filter_pending;
    out["inspector_trace_cell"] = _inspector_trace_cell;
    out["inspector_trace_pending"] = _inspector_trace_pending;
    out["event_summary_ms"] = _event_summary_ms;
    out["event_detail_ms"] = _event_detail_ms;
    out["event_publish_ms"] = _event_publish_ms;
    out["archive_active"] = _event_archive.active;
    return out;
}


Dictionary NativeEconomyRuntime::begin_event_archive(int32_t chunk_bytes) {
    Dictionary out;
    if (!_bootstrapped || _epoch_active || _event_archive.active || _save.active ||
        _restore.active) {
        out["ok"] = false;
        out["reason"] = !_bootstrapped ? "economy_not_bootstrapped" :
            (_epoch_active ? "archive_requires_committed_boundary" : "archive_already_active");
        return out;
    }
    _event_archive = {};
    _event_archive.active = true;
    _event_archive.chunk_bytes = std::clamp(chunk_bytes, 64 * 1024, 16 * 1024 * 1024);
    _event_archive.batch_limit = _committed_event_batches.size();
    out["ok"] = true;
    out["chunk_bytes"] = _event_archive.chunk_bytes;
    out["batch_count"] = static_cast<int64_t>(_committed_event_batches.size());
    return out;
}


PackedByteArray NativeEconomyRuntime::read_event_archive_chunk(int32_t max_bytes) {
    if (!_event_archive.active || _event_archive.end_emitted) return {};
    const int32_t budget = std::clamp(max_bytes > 0 ? max_bytes : _event_archive.chunk_bytes,
                                      64 * 1024, 16 * 1024 * 1024);
    std::vector<uint8_t> payload;
    if (!_event_archive.header_emitted) {
        append_le<int64_t>(payload, _catalog_hash);
        append_le<int64_t>(payload, _building_catalog_hash);
        append_le<int64_t>(payload, _next_event_id);
        append_le<uint64_t>(payload, _event_stream_hash);
        append_le<int32_t>(payload, static_cast<int32_t>(_event_archive.batch_limit));
        _event_archive.header_emitted = true;
        return make_event_archive_chunk(EVENT_ARCHIVE_HEADER, 1, payload);
    }
    uint32_t records = 0;
    while (_event_archive.batch_cursor < _event_archive.batch_limit) {
        const EventBatch &batch = _committed_event_batches[_event_archive.batch_cursor];
        if (_event_archive.event_cursor >= batch.events.size()) {
            ++_event_archive.batch_cursor;
            _event_archive.event_cursor = 0;
            continue;
        }
        const EventRecord &event = batch.events[_event_archive.event_cursor];
        const size_t record_bytes = 116 + static_cast<size_t>(event.leg_count) * 40;
        if (!payload.empty() && payload.size() + record_bytes > static_cast<size_t>(budget - 16)) break;
        append_le<int64_t>(payload, event.event_id);
        append_le<int64_t>(payload, event.event_id);
        append_le<int64_t>(payload, batch.epoch_id);
        append_le<int64_t>(payload, batch.sample_day);
        append_le<int64_t>(payload, batch.commit_day);
        append_le<int32_t>(payload, batch.period_days);
        append_le<int32_t>(payload, event.stage);
        append_le<int32_t>(payload, event.kind);
        append_le<int32_t>(payload, event.flags);
        append_le<int32_t>(payload, event.cell);
        append_le<int32_t>(payload, event.subject_kind);
        append_le<int64_t>(payload, event.subject_id);
        append_le<int32_t>(payload, event.subject_i0);
        append_le<int32_t>(payload, event.subject_i1);
        append_le<uint32_t>(payload, event.leg_count);
        append_le<int64_t>(payload, event.value0);
        append_le<int64_t>(payload, event.value1);
        append_le<int64_t>(payload, event.value2);
        append_le<int64_t>(payload, event.value3);
        for (uint32_t i = 0; i < event.leg_count; ++i) {
            const EventLeg &leg = batch.legs[event.leg_begin + i];
            append_le<int32_t>(payload, leg.field);
            append_le<int32_t>(payload, leg.subject_kind);
            append_le<int64_t>(payload, leg.subject_id);
            append_le<int32_t>(payload, leg.key_id);
            append_le<int64_t>(payload, leg.before);
            append_le<int64_t>(payload, leg.after);
        }
        ++_event_archive.event_cursor;
        ++records;
    }
    if (records > 0) return make_event_archive_chunk(EVENT_ARCHIVE_EVENTS, records, payload);
    _event_archive.end_emitted = true;
    return make_event_archive_chunk(EVENT_ARCHIVE_END, 0, payload);
}


Dictionary NativeEconomyRuntime::end_event_archive() {
    Dictionary out;
    if (!_event_archive.active || !_event_archive.end_emitted) {
        out["ok"] = false;
        out["reason"] = !_event_archive.active ? "event_archive_not_active" :
            "event_archive_not_fully_read";
        return out;
    }
    _event_archive = {};
    trace_evict_to_budget();
    out["ok"] = true;
    return out;
}


} // namespace pk

