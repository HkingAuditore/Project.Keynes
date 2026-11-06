#include "economy_cost_probe.h"
#include "economy_effect_forward.h"
#include "economy_runtime.h"
#include "economy_hash.h"
#include "runtime_switch_registry.h"
#include "economy_graph_kernels.h"
#include "economy_graph_live_ops.h"
#include "economy_graph_stage_dispatch.h"
#include "runtime_economy_pod.h"
#include "native_simulation_host.h"
#include "economy_runtime_variant_helpers.h"
#include "parallel_dispatcher.h"
#include "pk_log.h"

#include <algorithm>
#include <array>
#include <cassert>
#include <chrono>
#include <charconv>
#include <cmath>
#include <cstdlib>
#include <cstring>
#include <iterator>
#include <limits>
#include <map>
#include <numeric>
#include <tuple>
#include <type_traits>
#include <unordered_map>
#include <unordered_set>

#if defined(_MSC_VER) && defined(_M_X64)
#include <intrin.h>
#endif

#include <godot_cpp/variant/packed_int32_array.hpp>
#include <godot_cpp/variant/packed_int64_array.hpp>
#include <godot_cpp/variant/packed_string_array.hpp>
#include <godot_cpp/variant/utility_functions.hpp>
#include <godot_cpp/variant/variant.hpp>

namespace pk {
using namespace godot;
using namespace variant_helpers;

void NativeEconomyRuntime::fill_family_behavior_metrics(
        int32_t family_index, int32_t branch, int32_t cell, int64_t *metrics,
        int32_t metric_count, const MetricMask &metric_mask) const {
    if (metrics == nullptr || metric_count <= 0) return;
    // Escape hatch: force every declared metric, so a wrong mask shows up as a
    // parity failure instead of a silently-zero reading.
    static const bool full_metrics = [] {
        const char *value = pk::runtime_switch_value(pk::RuntimeSwitch::PK_ECONOMY_FAMILY_METRIC_MASK_DISABLE);
        return value && std::strcmp(value, "1") == 0;
    }();
    auto requested = [&](int32_t metric) {
        if (metric < 0 || metric >= metric_count) return false;
        return full_metrics || metric_mask.test(metric);
    };
    std::fill(metrics, metrics + metric_count, 0);
    auto count_q16 = [](int64_t value) -> int64_t {
        if (value <= 0) return 0;
        if (value > std::numeric_limits<int64_t>::max() / Q16_ONE)
            return std::numeric_limits<int64_t>::max();
        return value * Q16_ONE;
    };
    uint64_t family_handle = 0;
    if (family_index >= 0 && family_index < static_cast<int32_t>(
            families_store().active.size()) && families_store().active[family_index] != 0) {
        family_handle = families_store().handle_for_index(family_index);
        if (requested(FAMILY_METRIC_MAGNITUDE_Q16))
            metrics[FAMILY_METRIC_MAGNITUDE_Q16] = Q16_ONE;
        if (requested(FAMILY_METRIC_FAMILY_POPULATION))
            metrics[FAMILY_METRIC_FAMILY_POPULATION] =
                count_q16(family_population(family_handle));
        if (requested(FAMILY_METRIC_FAMILY_CASH_CLAIM))
            metrics[FAMILY_METRIC_FAMILY_CASH_CLAIM] =
                count_q16(family_cash_claim(family_handle));
    }
    if (branch >= 0 && branch < static_cast<int32_t>(
            family_influences().active.size()) &&
        family_influences().active[branch] != 0) {
        if (requested(FAMILY_METRIC_BRANCH_PRESTIGE_Q16))
            metrics[FAMILY_METRIC_BRANCH_PRESTIGE_Q16] =
                family_influences().score_q16[branch];
        if (requested(FAMILY_METRIC_BRANCH_POPULATION))
            metrics[FAMILY_METRIC_BRANCH_POPULATION] =
                count_q16(family_influences().population[branch]);
        if (requested(FAMILY_METRIC_BRANCH_IS_LOCAL_PRESTIGE_MAX)) {
            int32_t best_score = family_influences().score_q16[branch];
            uint64_t best_handle = family_handle;
            const int32_t local_cell = family_influences().cell[branch];
            for (int32_t i = 0; i < static_cast<int32_t>(
                    family_influences().active.size()); ++i) {
                if (family_influences().active[i] == 0 ||
                    family_influences().cell[i] != local_cell) continue;
                const int32_t score = family_influences().score_q16[i];
                const uint64_t handle = family_influences().family_handle[i];
                if (score > best_score || (score == best_score &&
                        handle < best_handle)) {
                    best_score = score;
                    best_handle = handle;
                }
            }
            metrics[FAMILY_METRIC_BRANCH_IS_LOCAL_PRESTIGE_MAX] =
                (family_handle != 0 && family_handle == best_handle)
                    ? Q16_ONE : 0;
        }
    }
    if (cell < 0 || cell >= _cell_count.get()) return;
    if (requested(FAMILY_METRIC_CELL_TEMPERATURE_Q16))
        metrics[FAMILY_METRIC_CELL_TEMPERATURE_Q16] =
            cell < static_cast<int32_t>(_environment_temperature_q16.size())
                ? _environment_temperature_q16[cell] : 0;
    if (requested(FAMILY_METRIC_CELL_PRECIPITATION_Q16))
        metrics[FAMILY_METRIC_CELL_PRECIPITATION_Q16] =
            cell < static_cast<int32_t>(_environment_precipitation_q16.size())
                ? _environment_precipitation_q16[cell] : 0;
    if (requested(FAMILY_METRIC_CELL_RESOURCE_SHORTAGE_Q16))
        metrics[FAMILY_METRIC_CELL_RESOURCE_SHORTAGE_Q16] =
            cell < static_cast<int32_t>(_cell_effect_shortage_q16.size())
                ? std::clamp<int64_t>(_cell_effect_shortage_q16[cell], 0, Q16_ONE)
                : 0;
    if (requested(FAMILY_METRIC_CELL_TRADE_EVENTS))
        metrics[FAMILY_METRIC_CELL_TRADE_EVENTS] =
            cell < static_cast<int32_t>(_cell_trade_gen.size())
                ? count_q16(static_cast<int64_t>(_cell_trade_gen[cell])) : 0;
    if (requested(FAMILY_METRIC_CELL_POPULATION))
        metrics[FAMILY_METRIC_CELL_POPULATION] =
            cell < static_cast<int32_t>(_committed_cells.size())
                ? count_q16(_committed_cells[cell].population) : 0;
    if (requested(FAMILY_METRIC_CELL_LANDFORM)) {
        const int32_t landform = cell < static_cast<int32_t>(
                _building_landform.size()) ? _building_landform[cell] : 0;
        metrics[FAMILY_METRIC_CELL_LANDFORM] = count_q16(landform);
    }
    if (requested(FAMILY_METRIC_CELL_TERRAIN)) {
        // uint8_t widened before the ternary so a missing cell and a genuine
        // terrain id 0 stay distinguishable in the expression, not just in the
        // comment.
        const int32_t terrain = cell < static_cast<int32_t>(
                _building_terrain.size())
            ? static_cast<int32_t>(_building_terrain[cell]) : 0;
        metrics[FAMILY_METRIC_CELL_TERRAIN] = count_q16(terrain);
    }
    if (requested(FAMILY_METRIC_CELL_ESSENTIALS_SHORTAGE_Q16))
        metrics[FAMILY_METRIC_CELL_ESSENTIALS_SHORTAGE_Q16] =
            cell < static_cast<int32_t>(_cell_essentials_shortage_q16.size())
                ? std::clamp<int64_t>(_cell_essentials_shortage_q16[cell], 0,
                    Q16_ONE) : 0;
    if (requested(FAMILY_METRIC_CELL_RAIN_EVENT))
        metrics[FAMILY_METRIC_CELL_RAIN_EVENT] =
            cell < static_cast<int32_t>(_cell_rain_event_q16.size())
                ? _cell_rain_event_q16[cell] : 0;
    if (requested(FAMILY_METRIC_CELL_TEMPERATURE_ANNUAL_Q16))
        metrics[FAMILY_METRIC_CELL_TEMPERATURE_ANNUAL_Q16] =
            cell < static_cast<int32_t>(_cell_temperature_annual_q16.size())
                ? _cell_temperature_annual_q16[cell] : 0;
    if (requested(FAMILY_METRIC_CELL_DRY_STREAK_DAYS))
        metrics[FAMILY_METRIC_CELL_DRY_STREAK_DAYS] =
            cell < static_cast<int32_t>(_cell_dry_streak_days.size())
                ? count_q16(_cell_dry_streak_days[cell]) : 0;
    if (requested(FAMILY_METRIC_CELL_HAZARD_TODAY_MASK))
        metrics[FAMILY_METRIC_CELL_HAZARD_TODAY_MASK] =
            cell < static_cast<int32_t>(_cell_hazard_today_mask.size())
                ? count_q16(_cell_hazard_today_mask[cell]) : 0;
    if (requested(FAMILY_METRIC_CELL_DAYS_SINCE_HAZARD))
        metrics[FAMILY_METRIC_CELL_DAYS_SINCE_HAZARD] =
            cell < static_cast<int32_t>(_cell_days_since_hazard.size())
                ? count_q16(_cell_days_since_hazard[cell]) : 0;
    if (requested(FAMILY_METRIC_CELL_TEMPERATURE_ANOMALY_Q16))
        metrics[FAMILY_METRIC_CELL_TEMPERATURE_ANOMALY_Q16] =
            cell < static_cast<int32_t>(_cell_temperature_anomaly_q16.size())
                ? _cell_temperature_anomaly_q16[cell] : 0;
    if (requested(FAMILY_METRIC_CELL_RESOURCE_ABUNDANCE_Q16))
        metrics[FAMILY_METRIC_CELL_RESOURCE_ABUNDANCE_Q16] =
            cell < static_cast<int32_t>(_cell_resource_abundance_q16.size())
                ? std::clamp<int64_t>(_cell_resource_abundance_q16[cell], 0,
                    Q16_ONE) : 0;
    // Ids 15..21 are the industry-family rows. Scanning the industry stats is
    // the expensive part of this function, so it only happens when one of them
    // is actually requested.
    MetricMask industry_mask;
    for (int32_t industry_metric = 15; industry_metric <= 21; ++industry_metric)
        industry_mask.set(industry_metric);
    const bool wants_industry = full_metrics ||
        !(metric_mask & industry_mask).is_none();
    const FamilyIndustryStats *stats = wants_industry
        ? family_industry_stats_for(family_index, cell) : nullptr;
    if (requested(FAMILY_METRIC_HAS_OWNED_MANUFACTURING))
        metrics[FAMILY_METRIC_HAS_OWNED_MANUFACTURING] =
            stats != nullptr && stats->has_owned_manufacturing != 0 ? Q16_ONE : 0;
    if (requested(FAMILY_METRIC_DISTINCT_SECTOR_COUNT))
        metrics[FAMILY_METRIC_DISTINCT_SECTOR_COUNT] =
            stats != nullptr ? count_q16(stats->distinct_sector_count) : 0;
    if (requested(FAMILY_METRIC_DOMINANT_SECTOR_ID))
        metrics[FAMILY_METRIC_DOMINANT_SECTOR_ID] =
            stats == nullptr || stats->dominant_sector_id < 0
                ? -Q16_ONE : count_q16(stats->dominant_sector_id);
    if (requested(FAMILY_METRIC_DOMINANT_SECTOR_SHARE_Q16))
        metrics[FAMILY_METRIC_DOMINANT_SECTOR_SHARE_Q16] =
            stats != nullptr ? stats->dominant_sector_share_q16 : 0;
    if (requested(FAMILY_METRIC_COMPLETE_CHAIN_COUNT))
        metrics[FAMILY_METRIC_COMPLETE_CHAIN_COUNT] =
            stats != nullptr ? count_q16(stats->complete_chain_count) : 0;
    if (requested(FAMILY_METRIC_MAX_LOCAL_CHAIN_SHARE_Q16))
        metrics[FAMILY_METRIC_MAX_LOCAL_CHAIN_SHARE_Q16] =
            stats != nullptr ? stats->max_local_chain_share_q16 : 0;
    if (requested(FAMILY_METRIC_MAX_CHAIN_UPGRADE_FAMILY_ID))
        metrics[FAMILY_METRIC_MAX_CHAIN_UPGRADE_FAMILY_ID] =
            stats == nullptr || stats->max_chain_upgrade_family_id < 0
                ? 0 : count_q16(stats->max_chain_upgrade_family_id);
    int64_t cell_population = 0;
    int64_t cell_employed = 0;
    int64_t cell_funds = 0;
    std::vector<uint8_t> employed_professions;
    // X3: the profession mix needs per-profession population, which is the same
    // walk the unemployment rows already do. One extra accumulator beats a
    // second pass over the cell's cohorts.
    const bool wants_dominant_profession =
        requested(FAMILY_METRIC_CELL_DOMINANT_PROFESSION_ID) ||
        requested(FAMILY_METRIC_CELL_DOMINANT_PROFESSION_SHARE_Q16) ||
        requested(FAMILY_METRIC_CELL_PROFESSION_COUNT);
    const bool wants_profession_shares =
        requested(FAMILY_METRIC_CELL_PROFESSION_SHARE_FARMER_Q16) ||
        requested(FAMILY_METRIC_CELL_PROFESSION_SHARE_INDUSTRIAL_Q16) ||
        requested(FAMILY_METRIC_CELL_PROFESSION_SHARE_COOPERATIVE_Q16);
    const bool wants_profession_mix =
        wants_dominant_profession || wants_profession_shares;
    std::vector<int64_t> profession_people;
    std::vector<int64_t> employed_profession_people;
    if (requested(FAMILY_METRIC_CELL_UNEMPLOYMENT_Q16) ||
        requested(FAMILY_METRIC_CELL_VACANT_PROFESSION_COUNT) ||
        requested(FAMILY_METRIC_FAMILY_CASH_PER_CAPITA_VS_CELL_Q16) ||
        wants_profession_mix) {
        if (requested(FAMILY_METRIC_CELL_VACANT_PROFESSION_COUNT))
            employed_professions.assign(_profession_ids.size(), 0);
        if (wants_profession_mix)
            profession_people.assign(_profession_ids.size(), 0);
        if (wants_dominant_profession)
            employed_profession_people.assign(_profession_ids.size(), 0);
        population_store().for_each_in_cell(cell, [&](int32_t slot) {
            const int64_t people = std::max<int64_t>(0, population_store().population[slot]);
            cell_population += people;
            const int64_t employed = std::max<int64_t>(0,
                population_store().owner_employed[slot]) +
                std::max<int64_t>(0, population_store().employee_employed[slot]);
            cell_employed += employed;
            cell_funds += std::max<int64_t>(0, population_store().funds[slot]);
            const int32_t signature = static_cast<int32_t>(
                population_store().signature_id[slot]);
            if (signature < 0 ||
                signature >= static_cast<int32_t>(_signatures.size()))
                return;
            const int32_t profession = _signatures[
                static_cast<size_t>(signature)].profession_id;
            if (profession < 0) return;
            if (static_cast<size_t>(profession) < profession_people.size())
                profession_people[static_cast<size_t>(profession)] += people;
            if (employed <= 0) return;
            if (static_cast<size_t>(profession) < employed_professions.size())
                employed_professions[static_cast<size_t>(profession)] = 1;
            if (static_cast<size_t>(profession) <
                    employed_profession_people.size())
                employed_profession_people[static_cast<size_t>(profession)] +=
                    people;
        });
    }
    if (wants_dominant_profession) {
        int64_t total_people = 0;
        int64_t best_people = 0;
        int32_t best_profession = -1;
        int32_t profession_count = 0;
        for (size_t profession = 0;
             profession < employed_profession_people.size(); ++profession) {
            const int64_t people = employed_profession_people[profession];
            if (people <= 0) continue;
            ++profession_count;
            total_people += people;
            if (people > best_people) {
                best_people = people;
                best_profession = static_cast<int32_t>(profession);
            }
        }
        if (requested(FAMILY_METRIC_CELL_DOMINANT_PROFESSION_ID))
            metrics[FAMILY_METRIC_CELL_DOMINANT_PROFESSION_ID] =
                best_profession < 0 ? -Q16_ONE : count_q16(best_profession);
        if (requested(FAMILY_METRIC_CELL_DOMINANT_PROFESSION_SHARE_Q16))
            metrics[FAMILY_METRIC_CELL_DOMINANT_PROFESSION_SHARE_Q16] =
                total_people > 0
                    ? std::clamp<int64_t>(best_people * Q16_ONE / total_people,
                        0, Q16_ONE)
                    : 0;
        if (requested(FAMILY_METRIC_CELL_PROFESSION_COUNT))
            metrics[FAMILY_METRIC_CELL_PROFESSION_COUNT] = count_q16(profession_count);
    }
    if (wants_profession_shares) {
        int64_t total_people = 0;
        int64_t farmer_people = 0;
        int64_t industrial_people = 0;
        int64_t cooperative_people = 0;
        for (size_t profession = 0; profession < profession_people.size();
             ++profession) {
            const int64_t people = profession_people[profession];
            if (people <= 0) continue;
            total_people += people;
            const std::string &profession_id =
                _profession_ids[static_cast<size_t>(profession)];
            if (profession_id == "household_farmer" ||
                    profession_id == "subsistence_farmer" ||
                    profession_id == "tenant_farmer" ||
                    profession_id == "sharecropper" ||
                    profession_id == "agricultural_worker" ||
                    profession_id == "serf")
                farmer_people += people;
            if (profession_id == "industrial_worker")
                industrial_people += people;
            if (profession_id == "cooperative_member")
                cooperative_people += people;
        }
        const auto share = [total_people](int64_t people) {
            return total_people > 0
                ? std::clamp<int64_t>(people * Q16_ONE / total_people,
                    0, Q16_ONE)
                : 0;
        };
        if (requested(FAMILY_METRIC_CELL_PROFESSION_SHARE_FARMER_Q16))
            metrics[FAMILY_METRIC_CELL_PROFESSION_SHARE_FARMER_Q16] =
                share(farmer_people);
        if (requested(FAMILY_METRIC_CELL_PROFESSION_SHARE_INDUSTRIAL_Q16))
            metrics[FAMILY_METRIC_CELL_PROFESSION_SHARE_INDUSTRIAL_Q16] =
                share(industrial_people);
        if (requested(FAMILY_METRIC_CELL_PROFESSION_SHARE_COOPERATIVE_Q16))
            metrics[FAMILY_METRIC_CELL_PROFESSION_SHARE_COOPERATIVE_Q16] =
                share(cooperative_people);
    }
    // X2: the neighbourhood's population. O(6), so it is safe in the hot path;
    // a missing or stale neighbour graph reads 0 rather than guessing.
    if (requested(FAMILY_METRIC_CELL_NEIGHBOR_POPULATION_Q16)) {
        int64_t neighbor_population = 0;
        if (_building_neighbors.size() ==
                static_cast<size_t>(_cell_count.get()) * 6) {
            for (int32_t direction = 0; direction < 6; ++direction) {
                const int32_t neighbor = _building_neighbors[
                    static_cast<size_t>(cell) * 6 + static_cast<size_t>(direction)];
                if (neighbor < 0 ||
                    neighbor >= static_cast<int32_t>(_committed_cells.size()))
                    continue;
                neighbor_population += std::max<int64_t>(
                    0, _committed_cells[static_cast<size_t>(neighbor)].population);
            }
        }
        int64_t neighbor_saturate = 0;
        metrics[FAMILY_METRIC_CELL_NEIGHBOR_POPULATION_Q16] = saturating_mul(
            neighbor_population, Q16_ONE, neighbor_saturate);
    }
    // X2 extension: count neighbours that are agriculture pillars, using the
    // same "agriculture output share >= 50%" definition as
    // `cell.sector.agriculture`. Reading the current building rows avoids
    // depending on the previous epoch's tag snapshot while that snapshot is
    // being rebuilt.
    if (requested(FAMILY_METRIC_CELL_NEIGHBOR_AGRICULTURE_COUNT)) {
        int32_t agriculture_neighbors = 0;
        const bool neighbor_graph_ready = _building_neighbors.size() ==
            static_cast<size_t>(_cell_count.get()) * 6;
        const bool building_csr_ready = _building_cell_offsets.size() ==
            static_cast<size_t>(_cell_count.get()) + 1;
        if (neighbor_graph_ready && building_csr_ready) {
            for (int32_t direction = 0; direction < 6; ++direction) {
                const int32_t neighbor = _building_neighbors[
                    static_cast<size_t>(cell) * 6 +
                    static_cast<size_t>(direction)];
                if (neighbor < 0 || neighbor == cell ||
                    neighbor >= static_cast<int32_t>(_cell_count.get()))
                    continue;
                int64_t total_output = 0;
                int64_t agriculture_output = 0;
                for (int32_t group_index = _building_cell_offsets[neighbor];
                     group_index < _building_cell_offsets[neighbor + 1];
                     ++group_index) {
                    const auto group = building_view(
                        static_cast<size_t>(group_index));
                    if (group.count <= 0 || group.last_output <= 0 ||
                        group.type_id < 0 ||
                        group.type_id >= static_cast<int32_t>(
                            _building_economic_sectors.size()))
                        continue;
                    total_output += group.last_output;
                    if (_building_economic_sectors[
                            static_cast<size_t>(group.type_id)] == 0)
                        agriculture_output += group.last_output;
                }
                if (total_output > 0 &&
                    agriculture_output >= (total_output + 1) / 2)
                    ++agriculture_neighbors;
            }
        }
        metrics[FAMILY_METRIC_CELL_NEIGHBOR_AGRICULTURE_COUNT] =
            count_q16(agriculture_neighbors);
    }
    // X11: mean income-tax rate across professions, in basis points. Read from
    // the frozen epoch shape (see `tax_shape_valid`), never from live stores.
    if (requested(FAMILY_METRIC_COUNTRY_INCOME_TAX_BURDEN_BP)) {
        const int32_t tax_country = cell_country_slot(cell);
        const int64_t professions =
            static_cast<int64_t>(_profession_ids.size());
        int64_t burden = 0;
        if (tax_country >= 0 && professions > 0 &&
            _epoch_income_tax_rates.size() >=
                static_cast<size_t>(tax_country + 1) * _profession_ids.size()) {
            int64_t total = 0;
            const size_t begin = static_cast<size_t>(tax_country) *
                _profession_ids.size();
            for (size_t profession = 0; profession < _profession_ids.size();
                    ++profession)
                total += _epoch_income_tax_rates[begin + profession];
            burden = total / professions;
        }
        metrics[FAMILY_METRIC_COUNTRY_INCOME_TAX_BURDEN_BP] = burden;
    }
    // X7: how many of the country's own cells match each counted tag. Published
    // as a country scalar on every cell, so a cell-domain card can gate on "my
    // country owns at least N mining cells". Counts go through count_q16 like
    // every other count/id metric, because tag thresholds are Q16 too.
    if (requested(FAMILY_METRIC_COUNTRY_AGRICULTURE_CELL_COUNT) ||
        requested(FAMILY_METRIC_COUNTRY_EXTRACTIVE_CELL_COUNT) ||
        requested(FAMILY_METRIC_COUNTRY_MANUFACTURING_CELL_COUNT) ||
        requested(FAMILY_METRIC_COUNTRY_CHAINED_CELL_COUNT) ||
        requested(FAMILY_METRIC_COUNTRY_SPECIALIZED_CELL_COUNT) ||
        requested(FAMILY_METRIC_COUNTRY_MARKET_CELL_COUNT) ||
        requested(FAMILY_METRIC_COUNTRY_SETTLEMENT_CELL_COUNT) ||
        requested(FAMILY_METRIC_COUNTRY_SILVER_CELL_COUNT) ||
        requested(FAMILY_METRIC_COUNTRY_SALT_CELL_COUNT) ||
        requested(FAMILY_METRIC_COUNTRY_IRON_ORE_CELL_COUNT) ||
        requested(FAMILY_METRIC_COUNTRY_COAL_CELL_COUNT)) {
        // R-3: ONE atomic load of the immutable snapshot. The local pointer keeps
        // the counts alive for this read even if a commit publishes a new epoch
        // underneath it, so `count_in_range` and the reads below all describe the
        // same snapshot.
        const std::shared_ptr<const TagSnapshot> tag_snapshot_local = tag_snapshot();
        // Slot count must match kCountryTagCountSlots exactly; the metric id
        // array below is the other half of that contract.
        constexpr int32_t kSlots = 11;
        const int32_t count_country = cell_country_slot(cell);
        const size_t base = count_country >= 0
            ? static_cast<size_t>(count_country) * kSlots : 0;
        const bool count_in_range = count_country >= 0 &&
            tag_snapshot_local != nullptr &&
            base + kSlots <= tag_snapshot_local->country_tag_counts.size();
        const int32_t count_metric_ids[kSlots] = {
            FAMILY_METRIC_COUNTRY_AGRICULTURE_CELL_COUNT,
            FAMILY_METRIC_COUNTRY_EXTRACTIVE_CELL_COUNT,
            FAMILY_METRIC_COUNTRY_MANUFACTURING_CELL_COUNT,
            FAMILY_METRIC_COUNTRY_CHAINED_CELL_COUNT,
            FAMILY_METRIC_COUNTRY_SPECIALIZED_CELL_COUNT,
            FAMILY_METRIC_COUNTRY_MARKET_CELL_COUNT,
            FAMILY_METRIC_COUNTRY_SETTLEMENT_CELL_COUNT,
            FAMILY_METRIC_COUNTRY_SILVER_CELL_COUNT,
            FAMILY_METRIC_COUNTRY_SALT_CELL_COUNT,
            FAMILY_METRIC_COUNTRY_IRON_ORE_CELL_COUNT,
            FAMILY_METRIC_COUNTRY_COAL_CELL_COUNT,
        };
        for (int32_t slot = 0; slot < kSlots; ++slot) {
            metrics[count_metric_ids[slot]] = count_in_range
                ? count_q16(tag_snapshot_local->country_tag_counts[
                    base + static_cast<size_t>(slot)])
                : 0;
        }
    }
    // X7b: distinct goods with at least one specialized cell in this country.
    if (requested(FAMILY_METRIC_COUNTRY_DISTINCT_SPECIALIZED_GOOD_COUNT)) {
        // R-3: read from the same immutable snapshot as the tag counts, one load.
        const std::shared_ptr<const TagSnapshot> specialized_snapshot =
            tag_snapshot();
        const int32_t distinct_country = cell_country_slot(cell);
        metrics[FAMILY_METRIC_COUNTRY_DISTINCT_SPECIALIZED_GOOD_COUNT] =
            specialized_snapshot != nullptr && distinct_country >= 0 &&
            static_cast<size_t>(distinct_country) <
                specialized_snapshot->country_specialized_good_count.size()
            ? count_q16(specialized_snapshot->country_specialized_good_count[
                static_cast<size_t>(distinct_country)])
            : 0;
    }
    if (requested(FAMILY_METRIC_CELL_UNEMPLOYMENT_Q16)) {
        const int64_t unemployed = std::max<int64_t>(0, cell_population - cell_employed);
        metrics[FAMILY_METRIC_CELL_UNEMPLOYMENT_Q16] = cell_population > 0
            ? std::clamp<int64_t>(unemployed * Q16_ONE / cell_population, 0, Q16_ONE)
            : 0;
    }
    if (requested(FAMILY_METRIC_CELL_RESOURCE_CLASS_COUNT)) {
        int32_t resource_classes = 0;
        const size_t resources = _resource_ids.size();
        if (resources > 0 && resource_stock_lanes().size() >=
                resources * static_cast<size_t>(_cell_count.get())) {
            for (size_t resource = 0; resource < resources; ++resource) {
                const size_t idx = resource * static_cast<size_t>(_cell_count.get()) +
                    static_cast<size_t>(cell);
                if (resource_stock_lanes()[idx] > 0) ++resource_classes;
            }
        }
        metrics[FAMILY_METRIC_CELL_RESOURCE_CLASS_COUNT] = count_q16(resource_classes);
    }
    int64_t sector_count[5] = {0, 0, 0, 0, 0};
    // Output-flow twin of sector_count. last_output is already net of
    // output_factor_q16, so this is the only sector aggregate that reacts when a
    // sector coefficient changes -- which is what lets an output-share
    // condition feed back on the effect that raised the coefficient.
    int64_t sector_output[5] = {0, 0, 0, 0, 0};
    int64_t total_output = 0;
    int64_t total_buildings = 0;
    int32_t manufacturing_groups = 0;
    int32_t knowledge_groups = 0;
    int32_t extractive_groups = 0;
    bool can_produce_corn = false;
    int32_t vacant_professions = 0;
    std::vector<uint8_t> demanded_professions;
    if (requested(FAMILY_METRIC_CELL_VACANT_PROFESSION_COUNT))
        demanded_professions.assign(_profession_ids.size(), 0);
    const bool needs_building_scan =
        requested(FAMILY_METRIC_CELL_MANUFACTURING_BUILDING_COUNT) ||
        requested(FAMILY_METRIC_CELL_DISTINCT_SECTOR_COUNT) ||
        requested(FAMILY_METRIC_CELL_DOMINANT_SECTOR_ID) ||
        requested(FAMILY_METRIC_CELL_DOMINANT_SECTOR_SHARE_Q16) ||
        requested(FAMILY_METRIC_CELL_SECTOR_OUTPUT_SHARE_AGRICULTURE_Q16) ||
        requested(FAMILY_METRIC_CELL_SECTOR_OUTPUT_SHARE_EXTRACTIVE_Q16) ||
        requested(FAMILY_METRIC_CELL_SECTOR_OUTPUT_SHARE_MANUFACTURING_Q16) ||
        requested(FAMILY_METRIC_CELL_SECTOR_OUTPUT_SHARE_ENERGY_Q16) ||
        requested(FAMILY_METRIC_CELL_SECTOR_OUTPUT_SHARE_KNOWLEDGE_Q16) ||
        requested(FAMILY_METRIC_CELL_DOMINANT_SECTOR_OUTPUT_SHARE_Q16) ||
        requested(FAMILY_METRIC_CELL_HAS_EXTRACTIVE_RESOURCE) ||
        requested(FAMILY_METRIC_CELL_VACANT_PROFESSION_COUNT) ||
        requested(FAMILY_METRIC_CELL_KNOWLEDGE_BUILDING_CLASS_COUNT) ||
        requested(FAMILY_METRIC_CELL_CAN_PRODUCE_CORN);
    const bool building_csr = _building_cell_offsets.size() ==
        static_cast<size_t>(_cell_count.get()) + 1;
    if (needs_building_scan && building_csr) {
        for (int32_t group_index = _building_cell_offsets[cell];
             group_index < _building_cell_offsets[cell + 1]; ++group_index) {
            const auto group = building_view(static_cast<size_t>(static_cast<size_t>(group_index)));
            if (group.count <= 0 || group.type_id < 0 ||
                group.type_id >= static_cast<int32_t>(_building_types.size()))
                continue;
            const int32_t sector = group.type_id < static_cast<int32_t>(
                    _building_economic_sectors.size())
                ? _building_economic_sectors[static_cast<size_t>(group.type_id)] : 2;
            if (sector >= 0 && sector < 5) {
                sector_count[sector] += group.count;
                total_buildings += group.count;
                if (group.last_output > 0) {
                    sector_output[sector] += group.last_output;
                    total_output += group.last_output;
                }
            }
            if (sector == 2) ++manufacturing_groups;
            if (sector == 4) ++knowledge_groups;
            if (sector == 1) ++extractive_groups;
            const BuildingType &type = _building_types[
                static_cast<size_t>(group.type_id)];
            if (requested(FAMILY_METRIC_CELL_CAN_PRODUCE_CORN) && _family_corn_good_id >= 0) {
                for (int32_t output = type.output_begin;
                     output < type.output_begin + type.output_count; ++output) {
                    if (_building_outputs[static_cast<size_t>(output)].good_id ==
                            _family_corn_good_id) {
                        can_produce_corn = true;
                        break;
                    }
                }
            }
            if (requested(FAMILY_METRIC_CELL_VACANT_PROFESSION_COUNT))
            for (int32_t edge = type.labor_signal_begin;
                 edge < type.labor_signal_begin + type.labor_signal_count; ++edge) {
                if (edge < 0 || edge >= static_cast<int32_t>(
                        _building_type_labor_signal_professions.size()))
                    continue;
                const int32_t profession = _building_type_labor_signal_professions[
                    static_cast<size_t>(edge)];
                if (profession >= 0 &&
                    static_cast<size_t>(profession) < demanded_professions.size())
                    demanded_professions[static_cast<size_t>(profession)] = 1;
            }
        }
    }
    for (size_t profession = 0; profession < demanded_professions.size(); ++profession) {
        if (demanded_professions[profession] != 0 &&
            (profession >= employed_professions.size() ||
             employed_professions[profession] == 0))
            ++vacant_professions;
    }
    if (requested(FAMILY_METRIC_CELL_MANUFACTURING_BUILDING_COUNT))
        metrics[FAMILY_METRIC_CELL_MANUFACTURING_BUILDING_COUNT] =
            count_q16(manufacturing_groups);
    int32_t distinct_sectors = 0;
    int32_t dominant_sector = -1;
    int64_t dominant_owned = 0;
    for (int32_t sector = 0; sector < 5; ++sector) {
        if (sector_count[sector] <= 0) continue;
        ++distinct_sectors;
        if (sector_count[sector] > dominant_owned ||
            (sector_count[sector] == dominant_owned &&
             (dominant_sector < 0 || sector < dominant_sector))) {
            dominant_owned = sector_count[sector];
            dominant_sector = sector;
        }
    }
    if (requested(FAMILY_METRIC_CELL_DISTINCT_SECTOR_COUNT))
        metrics[FAMILY_METRIC_CELL_DISTINCT_SECTOR_COUNT] =
            count_q16(distinct_sectors);
    if (requested(FAMILY_METRIC_CELL_DOMINANT_SECTOR_ID))
        metrics[FAMILY_METRIC_CELL_DOMINANT_SECTOR_ID] =
            dominant_sector < 0 ? -Q16_ONE : count_q16(dominant_sector);
    if (requested(FAMILY_METRIC_CELL_DOMINANT_SECTOR_SHARE_Q16))
        metrics[FAMILY_METRIC_CELL_DOMINANT_SECTOR_SHARE_Q16] = total_buildings > 0
            ? static_cast<int32_t>(std::clamp<int64_t>(
                dominant_owned * Q16_ONE / total_buildings, 0, Q16_ONE)) : 0;
    {
        // Output-share rows. Same bucket layout as sector_count above, but
        // weighted by last_output so a sector coefficient actually moves them.
        const int32_t sector_output_metric_ids[5] = {
            FAMILY_METRIC_CELL_SECTOR_OUTPUT_SHARE_AGRICULTURE_Q16,
            FAMILY_METRIC_CELL_SECTOR_OUTPUT_SHARE_EXTRACTIVE_Q16,
            FAMILY_METRIC_CELL_SECTOR_OUTPUT_SHARE_MANUFACTURING_Q16,
            FAMILY_METRIC_CELL_SECTOR_OUTPUT_SHARE_ENERGY_Q16,
            FAMILY_METRIC_CELL_SECTOR_OUTPUT_SHARE_KNOWLEDGE_Q16,
        };
        int64_t dominant_output = 0;
        for (int32_t sector = 0; sector < 5; ++sector) {
            const int32_t share = total_output > 0
                ? static_cast<int32_t>(std::clamp<int64_t>(
                    sector_output[sector] * Q16_ONE / total_output, 0, Q16_ONE))
                : 0;
            if (requested(sector_output_metric_ids[sector]))
                metrics[sector_output_metric_ids[sector]] = share;
            if (sector_output[sector] > dominant_output)
                dominant_output = sector_output[sector];
        }
        if (requested(FAMILY_METRIC_CELL_DOMINANT_SECTOR_OUTPUT_SHARE_Q16))
            metrics[FAMILY_METRIC_CELL_DOMINANT_SECTOR_OUTPUT_SHARE_Q16] =
                total_output > 0
                    ? static_cast<int32_t>(std::clamp<int64_t>(
                        dominant_output * Q16_ONE / total_output, 0, Q16_ONE))
                    : 0;
    }
    if (requested(FAMILY_METRIC_CELL_DOMINANT_RESOURCE_ID)) {
        const int32_t resource = dominant_resource_at(cell);
        metrics[FAMILY_METRIC_CELL_DOMINANT_RESOURCE_ID] =
            resource < 0 ? -Q16_ONE : count_q16(resource);
    }
    if (requested(FAMILY_METRIC_CELL_DOMINANT_RESOURCE_STOCK_SHARE_Q16))
        metrics[FAMILY_METRIC_CELL_DOMINANT_RESOURCE_STOCK_SHARE_Q16] =
            dominant_resource_stock_share_q16(cell);
    if (requested(FAMILY_METRIC_CELL_DOMINANT_OUTPUT_GOOD_ID) ||
        requested(FAMILY_METRIC_CELL_TOP_OUTPUT_GOOD_SHARE_Q16)) {
        int32_t output_share = 0;
        const int32_t good = dominant_output_good_at(cell, output_share);
        if (requested(FAMILY_METRIC_CELL_DOMINANT_OUTPUT_GOOD_ID))
            metrics[FAMILY_METRIC_CELL_DOMINANT_OUTPUT_GOOD_ID] =
                good < 0 ? -Q16_ONE : count_q16(good);
        if (requested(FAMILY_METRIC_CELL_TOP_OUTPUT_GOOD_SHARE_Q16))
            metrics[FAMILY_METRIC_CELL_TOP_OUTPUT_GOOD_SHARE_Q16] = output_share;
    }
    if (requested(FAMILY_METRIC_CELL_NEIGHBOR_DISTINCT_GOODS)) {
        metrics[FAMILY_METRIC_CELL_NEIGHBOR_DISTINCT_GOODS] =
            cell >= 0 && cell < static_cast<int32_t>(
                _epoch_cell_neighbor_distinct_goods.size())
                ? count_q16(_epoch_cell_neighbor_distinct_goods[
                    static_cast<size_t>(cell)])
                : 0;
    }
    if (requested(FAMILY_METRIC_COUNTRY_POPULATION_Q16) ||
        requested(FAMILY_METRIC_COUNTRY_BUILDINGS_INSTALLED) ||
        requested(FAMILY_METRIC_COUNTRY_TRADE_BASE_VALUE_Q16)) {
        // Published from the frozen per-publish snapshot, never from live
        // Economy stores: ideology conditions must not sample a country that is
        // still being written this pass.
        const int32_t country_slot = cell_country_slot(cell);
        const CountryClassOpinionSnapshot &opinion = country_class_opinion_snapshot();
        const size_t slot = static_cast<size_t>(std::max(0, country_slot));
        const bool in_range = country_slot >= 0 &&
            slot < opinion.country_population.size() &&
            slot < opinion.country_buildings_installed.size() &&
            slot < opinion.country_trade_base_value.size();
        // Local saturation counter: this reader is const, so the member counter
        // is not writable here and a saturation would be silently swallowed.
        int64_t sat = 0;
        if (requested(FAMILY_METRIC_COUNTRY_POPULATION_Q16))
            metrics[FAMILY_METRIC_COUNTRY_POPULATION_Q16] = in_range
                ? saturating_mul(std::max<int64_t>(0, opinion.country_population[slot]),
                    Q16_ONE, sat) : 0;
        if (requested(FAMILY_METRIC_COUNTRY_BUILDINGS_INSTALLED))
            metrics[FAMILY_METRIC_COUNTRY_BUILDINGS_INSTALLED] = in_range
                ? std::max<int64_t>(0, opinion.country_buildings_installed[slot]) : 0;
        if (requested(FAMILY_METRIC_COUNTRY_TRADE_BASE_VALUE_Q16))
            metrics[FAMILY_METRIC_COUNTRY_TRADE_BASE_VALUE_Q16] = in_range
                ? saturating_mul(std::max<int64_t>(0, opinion.country_trade_base_value[slot]),
                    Q16_ONE, sat) : 0;
    }
    if (requested(FAMILY_METRIC_CELL_COMPLETE_CHAIN_COUNT)) {
        int32_t complete = 0;
        if (building_csr) {
            std::unordered_map<int32_t, uint32_t> owned_tiers;
            std::unordered_map<int32_t, int32_t> catalog_tier_count;
            std::unordered_map<int32_t, uint32_t> catalog_tiers;
            for (size_t type = 0; type < _building_upgrade_family_indices.size();
                 ++type) {
                const int32_t family = _building_upgrade_family_indices[type];
                const int32_t tier = type < _building_upgrade_tiers.size()
                    ? _building_upgrade_tiers[type] : -1;
                if (family < 0 || tier < 0 || tier >= 32) continue;
                const uint32_t bit = 1u << static_cast<uint32_t>(tier);
                if ((catalog_tiers[family] & bit) == 0)
                    ++catalog_tier_count[family];
                catalog_tiers[family] |= bit;
            }
            for (int32_t group_index = _building_cell_offsets[cell];
                 group_index < _building_cell_offsets[cell + 1]; ++group_index) {
                const auto group = building_view(static_cast<size_t>(static_cast<size_t>(group_index)));
                if (group.count <= 0 || group.type_id < 0 ||
                    group.type_id >= static_cast<int32_t>(
                        _building_upgrade_family_indices.size()))
                    continue;
                const int32_t family = _building_upgrade_family_indices[
                    static_cast<size_t>(group.type_id)];
                const int32_t tier = group.type_id < static_cast<int32_t>(
                        _building_upgrade_tiers.size())
                    ? _building_upgrade_tiers[static_cast<size_t>(group.type_id)] : -1;
                if (family < 0 || tier < 0 || tier >= 32) continue;
                owned_tiers[family] |= 1u << static_cast<uint32_t>(tier);
            }
            for (const auto &owned : owned_tiers) {
                const uint32_t required = catalog_tiers[owned.first];
                const int32_t required_count = catalog_tier_count[owned.first];
                if (required_count >= 2 && required != 0 &&
                    (owned.second & required) == required)
                    ++complete;
            }
        }
        metrics[FAMILY_METRIC_CELL_COMPLETE_CHAIN_COUNT] = count_q16(complete);
    }
    if (requested(FAMILY_METRIC_CELL_HAS_EXTRACTIVE_RESOURCE)) {
        bool extractive = extractive_groups > 0;
        if (!extractive && !resource_stock_lanes().empty()) {
            const size_t resources = _resource_ids.size();
            for (size_t resource = 0; resource < resources && !extractive; ++resource) {
                const size_t idx = resource * static_cast<size_t>(_cell_count.get()) +
                    static_cast<size_t>(cell);
                if (idx < resource_stock_lanes().size() && resource_stock_lanes()[idx] > 0)
                    extractive = true;
            }
        }
        metrics[FAMILY_METRIC_CELL_HAS_EXTRACTIVE_RESOURCE] =
            extractive ? Q16_ONE : 0;
    }
    if (requested(FAMILY_METRIC_CELL_LEGAL_BUILDING_TYPE_COUNT)) {
        int32_t legal = 0;
        const int32_t country = cell < static_cast<int32_t>(_epoch_cell_country.size())
            ? _epoch_cell_country[static_cast<size_t>(cell)] : -1;
        if (country >= 0 &&
            country + 1 < static_cast<int32_t>(_epoch_country_building_type_offsets.size()))
            legal = std::max(0, _epoch_country_building_type_offsets[country + 1] -
                _epoch_country_building_type_offsets[country]);
        metrics[FAMILY_METRIC_CELL_LEGAL_BUILDING_TYPE_COUNT] = count_q16(legal);
    }
    if (requested(FAMILY_METRIC_CELL_VACANT_PROFESSION_COUNT))
        metrics[FAMILY_METRIC_CELL_VACANT_PROFESSION_COUNT] =
            count_q16(vacant_professions);
    if (requested(FAMILY_METRIC_FAMILY_BRANCH_COUNT) ||
        requested(FAMILY_METRIC_FAMILY_REMOTE_BRANCH_COUNT)) {
        int32_t branches = 0;
        int32_t remote = 0;
        const int32_t home = family_index >= 0 && family_index < static_cast<int32_t>(
                families_store().home_cell.size())
            ? families_store().home_cell[family_index] : -1;
        for (int32_t i = 0; i < static_cast<int32_t>(family_influences().active.size());
             ++i) {
            if (family_influences().active[i] == 0 || family_handle == 0 ||
                family_influences().family_handle[i] != family_handle)
                continue;
            ++branches;
            if (family_influences().cell[i] != home) ++remote;
        }
        if (requested(FAMILY_METRIC_FAMILY_BRANCH_COUNT))
            metrics[FAMILY_METRIC_FAMILY_BRANCH_COUNT] = count_q16(branches);
        if (requested(FAMILY_METRIC_FAMILY_REMOTE_BRANCH_COUNT))
            metrics[FAMILY_METRIC_FAMILY_REMOTE_BRANCH_COUNT] = count_q16(remote);
    }
    if (requested(FAMILY_METRIC_FAMILY_CASH_PER_CAPITA_VS_CELL_Q16) &&
        family_handle != 0) {
        const int64_t family_people = std::max<int64_t>(1,
            family_population(family_handle));
        const int64_t family_cash = family_cash_claim(family_handle);
        const int64_t family_capita = family_cash / family_people;
        const int64_t cell_people = std::max<int64_t>(1, cell_population);
        const int64_t cell_capita = cell_funds / cell_people;
        metrics[FAMILY_METRIC_FAMILY_CASH_PER_CAPITA_VS_CELL_Q16] = cell_capita > 0
            ? std::clamp<int64_t>(family_capita * Q16_ONE / cell_capita, 0,
                4 * Q16_ONE)
            : (family_capita > 0 ? 4 * Q16_ONE : 0);
    }
    if (requested(FAMILY_METRIC_CELL_KNOWLEDGE_BUILDING_CLASS_COUNT))
        metrics[FAMILY_METRIC_CELL_KNOWLEDGE_BUILDING_CLASS_COUNT] =
            count_q16(knowledge_groups);
    if (requested(FAMILY_METRIC_CELL_CAN_PRODUCE_CORN))
        metrics[FAMILY_METRIC_CELL_CAN_PRODUCE_CORN] =
            can_produce_corn ? Q16_ONE : 0;
    // R-4 metric 68: this cell's net tax burden over the current epoch.
    //
    // Same arithmetic as the satisfaction tax dimension a few hundred lines up, so a
    // card that ramps on this metric moves the number the player actually feels. The
    // ACCOUNTING_EPOCH_BIT parity comes from `touch_accounting_slot` -- a cohort that
    // has not booked this epoch is skipped rather than counted with last epoch's
    // leftovers, which would make the metric jump on the first day of every epoch.
    if (requested(FAMILY_METRIC_CELL_NET_TAX_BURDEN_Q16)) {
        const int64_t parity = ((_epoch_id & 1) != 0) ? 0x8000 : 0;
        int64_t net_total = 0;
        int64_t gross_total = 0;
        if (cell >= 0 && cell < static_cast<int32_t>(_cell_count.get())) {
            population_store().for_each_in_cell(cell, [&](int32_t slot) {
                if ((population_store().flags[slot] & 0x8000) != parity) return;
                net_total += population_store().epoch_tax_paid[slot];
                net_total -= population_store().epoch_subsidy_received[slot];
                const int64_t income = population_store().epoch_income[slot];
                const int64_t in_kind = population_store().epoch_in_kind_income[slot];
                gross_total += std::max<int64_t>(0, income) +
                    std::max<int64_t>(0, in_kind);
            });
        }
        int64_t burden_q16 = Q16_ONE;
        if (gross_total > 0) {
            if (net_total <= 0) {
                burden_q16 = 0;
            } else {
                int64_t saturate = 0;
                burden_q16 = std::clamp<int64_t>(
                    saturating_mul(net_total, Q16_ONE, saturate) /
                        std::max<int64_t>(1, gross_total),
                    0, Q16_ONE);
            }
        }
        metrics[FAMILY_METRIC_CELL_NET_TAX_BURDEN_Q16] = burden_q16;
    }
    if (requested(FAMILY_METRIC_CELL_GEO_FLAGS)) {
        metrics[FAMILY_METRIC_CELL_GEO_FLAGS] =
            cell < static_cast<int32_t>(_epoch_cell_geo_flags.size())
                ? _epoch_cell_geo_flags[static_cast<size_t>(cell)] : 0;
    }
    if (requested(FAMILY_METRIC_CELL_WATERWAY_COMPONENT_SIZE)) {
        metrics[FAMILY_METRIC_CELL_WATERWAY_COMPONENT_SIZE] = count_q16(
            cell < static_cast<int32_t>(_epoch_cell_waterway_component_size.size())
                ? _epoch_cell_waterway_component_size[static_cast<size_t>(cell)] : 0);
    }
    if (requested(FAMILY_METRIC_CELL_FAMILY_BRANCH_COUNT)) {
        metrics[FAMILY_METRIC_CELL_FAMILY_BRANCH_COUNT] = count_q16(
            cell < static_cast<int32_t>(_epoch_cell_family_branch_count.size())
                ? _epoch_cell_family_branch_count[static_cast<size_t>(cell)] : 0);
    }
    if (requested(FAMILY_METRIC_CELL_MAX_BRANCH_PRESTIGE_Q16)) {
        metrics[FAMILY_METRIC_CELL_MAX_BRANCH_PRESTIGE_Q16] =
            cell < static_cast<int32_t>(
                _epoch_cell_max_branch_prestige_q16.size())
                ? _epoch_cell_max_branch_prestige_q16[static_cast<size_t>(cell)]
                : 0;
    }
    if (requested(FAMILY_METRIC_CELL_FAMILY_ASSET_SHARE_Q16)) {
        metrics[FAMILY_METRIC_CELL_FAMILY_ASSET_SHARE_Q16] =
            cell < static_cast<int32_t>(
                _epoch_cell_family_asset_share_q16.size())
                ? _epoch_cell_family_asset_share_q16[static_cast<size_t>(cell)]
                : 0;
    }
    if (requested(FAMILY_METRIC_COUNTRY_CLASS_SATISFACTION_Q16) ||
        requested(FAMILY_METRIC_COUNTRY_WEIGHTED_SATISFACTION_Q16) ||
        requested(FAMILY_METRIC_COUNTRY_FARMER_SATISFACTION_Q16) ||
        requested(FAMILY_METRIC_COUNTRY_WORKER_CLASS_SATISFACTION_Q16)) {
        const int32_t opinion_country = cell_country_slot(cell);
        const bool in_range = opinion_country >= 0 &&
            static_cast<size_t>(opinion_country) <
                _epoch_country_class_satisfaction_q16.size() &&
            static_cast<size_t>(opinion_country) <
                _epoch_country_weighted_satisfaction_q16.size() &&
            static_cast<size_t>(opinion_country) <
                _epoch_country_farmer_satisfaction_q16.size() &&
            static_cast<size_t>(opinion_country) <
                _epoch_country_worker_satisfaction_q16.size();
        if (requested(FAMILY_METRIC_COUNTRY_CLASS_SATISFACTION_Q16))
            metrics[FAMILY_METRIC_COUNTRY_CLASS_SATISFACTION_Q16] = in_range
                ? _epoch_country_class_satisfaction_q16[
                    static_cast<size_t>(opinion_country)]
                : static_cast<int64_t>(Q16_ONE);
        if (requested(FAMILY_METRIC_COUNTRY_WEIGHTED_SATISFACTION_Q16))
            metrics[FAMILY_METRIC_COUNTRY_WEIGHTED_SATISFACTION_Q16] = in_range
                ? _epoch_country_weighted_satisfaction_q16[
                    static_cast<size_t>(opinion_country)]
                : static_cast<int64_t>(Q16_ONE);
        if (requested(FAMILY_METRIC_COUNTRY_FARMER_SATISFACTION_Q16))
            metrics[FAMILY_METRIC_COUNTRY_FARMER_SATISFACTION_Q16] = in_range
                ? _epoch_country_farmer_satisfaction_q16[
                    static_cast<size_t>(opinion_country)]
                : static_cast<int64_t>(Q16_ONE);
        if (requested(FAMILY_METRIC_COUNTRY_WORKER_CLASS_SATISFACTION_Q16))
            metrics[FAMILY_METRIC_COUNTRY_WORKER_CLASS_SATISFACTION_Q16] = in_range
                ? _epoch_country_worker_satisfaction_q16[
                    static_cast<size_t>(opinion_country)]
                : static_cast<int64_t>(Q16_ONE);
    }
    if (requested(FAMILY_METRIC_COUNTRY_COMPLETED_TECH_COUNT) ||
        requested(FAMILY_METRIC_COUNTRY_COMPLETED_TECH_COUNT_DOMAIN_0) ||
        requested(FAMILY_METRIC_COUNTRY_COMPLETED_TECH_COUNT_DOMAIN_1) ||
        requested(FAMILY_METRIC_COUNTRY_COMPLETED_TECH_COUNT_DOMAIN_2) ||
        requested(FAMILY_METRIC_COUNTRY_COMPLETED_TECH_COUNT_DOMAIN_3)) {
        const int32_t technology_country = cell_country_slot(cell);
        const bool in_range = technology_country >= 0 &&
            static_cast<size_t>(technology_country) <
                _epoch_country_completed_tech_count.size();
        if (requested(FAMILY_METRIC_COUNTRY_COMPLETED_TECH_COUNT))
            metrics[FAMILY_METRIC_COUNTRY_COMPLETED_TECH_COUNT] = count_q16(
                in_range ? _epoch_country_completed_tech_count[
                    static_cast<size_t>(technology_country)] : 0);
        const std::array<const std::vector<int64_t> *, 4> domain_columns = {
            &_epoch_country_completed_tech_count_domain_0,
            &_epoch_country_completed_tech_count_domain_1,
            &_epoch_country_completed_tech_count_domain_2,
            &_epoch_country_completed_tech_count_domain_3,
        };
        const std::array<int32_t, 4> domain_metrics = {
            FAMILY_METRIC_COUNTRY_COMPLETED_TECH_COUNT_DOMAIN_0,
            FAMILY_METRIC_COUNTRY_COMPLETED_TECH_COUNT_DOMAIN_1,
            FAMILY_METRIC_COUNTRY_COMPLETED_TECH_COUNT_DOMAIN_2,
            FAMILY_METRIC_COUNTRY_COMPLETED_TECH_COUNT_DOMAIN_3,
        };
        for (size_t domain = 0; domain < domain_columns.size(); ++domain) {
            const std::vector<int64_t> &column = *domain_columns[domain];
            if (!requested(domain_metrics[domain])) continue;
            metrics[domain_metrics[domain]] = count_q16(
                in_range && static_cast<size_t>(technology_country) <
                    column.size()
                ? column[static_cast<size_t>(technology_country)] : 0);
        }
    }
    // R-4 metric 69: country treasury reserve ratio, 1 point = 1%.
    //
    // Frozen per country per epoch in `capture_country_epoch`; this is the published
    // copy, mirroring metric 55's "read the frozen epoch shape, never the live store"
    // rule. `count_q16` because the generator's ramp treats the value as a COUNT of
    // percentage points, not a Q16 ratio.
    if (requested(FAMILY_METRIC_COUNTRY_TREASURY_RESERVE_RATIO_PCT)) {
        const int32_t reserve_country = cell_country_slot(cell);
        int64_t reserve_pct = 0;
        if (reserve_country >= 0 &&
            static_cast<size_t>(reserve_country) <
                _epoch_country_reserve_pct.size())
            reserve_pct = _epoch_country_reserve_pct[
                static_cast<size_t>(reserve_country)];
        metrics[FAMILY_METRIC_COUNTRY_TREASURY_RESERVE_RATIO_PCT] =
            count_q16(reserve_pct);
    }
    // X13 residual metric 88: already Q16, so publish the frozen ratio directly.
    // A country with no owned cells reads 0; no fallback to 1.0 would be honest.
    if (requested(FAMILY_METRIC_COUNTRY_HAZARD_FREE_CELL_SHARE_Q16)) {
        const int32_t hazard_country = cell_country_slot(cell);
        metrics[FAMILY_METRIC_COUNTRY_HAZARD_FREE_CELL_SHARE_Q16] =
            hazard_country >= 0 &&
                static_cast<size_t>(hazard_country) <
                    _epoch_country_hazard_free_cell_share_q16.size()
            ? _epoch_country_hazard_free_cell_share_q16[
                static_cast<size_t>(hazard_country)] : 0;
    }
    if (requested(FAMILY_METRIC_COUNTRY_FAMILY_REMOTE_BRANCH_COUNT) ||
        requested(FAMILY_METRIC_COUNTRY_FAMILIES_WITH_AT_LEAST_3_BRANCHES) ||
        requested(FAMILY_METRIC_COUNTRY_MAX_FAMILY_AGE_DAYS) ||
        requested(FAMILY_METRIC_COUNTRY_AVG_FAMILY_AGE_DAYS)) {
        const int32_t family_country = cell_country_slot(cell);
        const bool in_range = family_country >= 0 &&
            static_cast<size_t>(family_country) <
                _epoch_country_family_remote_branch_count.size();
        if (requested(FAMILY_METRIC_COUNTRY_FAMILY_REMOTE_BRANCH_COUNT))
            metrics[FAMILY_METRIC_COUNTRY_FAMILY_REMOTE_BRANCH_COUNT] =
                count_q16(in_range
                    ? _epoch_country_family_remote_branch_count[
                        static_cast<size_t>(family_country)] : 0);
        if (requested(FAMILY_METRIC_COUNTRY_FAMILIES_WITH_AT_LEAST_3_BRANCHES))
            metrics[FAMILY_METRIC_COUNTRY_FAMILIES_WITH_AT_LEAST_3_BRANCHES] =
                count_q16(in_range
                    ? _epoch_country_families_with_at_least_3_branches[
                        static_cast<size_t>(family_country)] : 0);
        const int32_t family_count = in_range &&
                static_cast<size_t>(family_country) <
                    _epoch_country_family_count.size()
            ? _epoch_country_family_count[static_cast<size_t>(family_country)]
            : 0;
        if (requested(FAMILY_METRIC_COUNTRY_MAX_FAMILY_AGE_DAYS)) {
            int32_t age = 0;
            if (family_count > 0 && in_range &&
                static_cast<size_t>(family_country) <
                    _epoch_country_oldest_family_founded_day.size())
                age = static_cast<int32_t>(std::clamp<int64_t>(
                    _current_day.get() - _epoch_country_oldest_family_founded_day[
                        static_cast<size_t>(family_country)],
                    0, std::numeric_limits<int32_t>::max()));
            metrics[FAMILY_METRIC_COUNTRY_MAX_FAMILY_AGE_DAYS] = count_q16(age);
        }
        if (requested(FAMILY_METRIC_COUNTRY_AVG_FAMILY_AGE_DAYS)) {
            int64_t age_sum = 0;
            if (family_count > 0 && in_range &&
                static_cast<size_t>(family_country) <
                    _epoch_country_family_founded_day_sum.size()) {
                const int64_t founded_sum = _epoch_country_family_founded_day_sum[
                    static_cast<size_t>(family_country)];
                age_sum = std::max<int64_t>(0,
                    _current_day.get() * family_count - founded_sum);
            }
            const int64_t avg_age = family_count > 0
                ? age_sum / family_count : 0;
            metrics[FAMILY_METRIC_COUNTRY_AVG_FAMILY_AGE_DAYS] = count_q16(
                std::clamp<int64_t>(avg_age, 0,
                    std::numeric_limits<int32_t>::max()));
        }
    }
    if (requested(FAMILY_METRIC_COUNTRY_ENERGY_CELL_COUNT) ||
        requested(
            FAMILY_METRIC_COUNTRY_ABUNDANT_MOUNTAIN_FOREST_CELL_COUNT) ||
        requested(FAMILY_METRIC_COUNTRY_LANDFORM_SIGNAL_COUNT) ||
        requested(FAMILY_METRIC_COUNTRY_WEATHER_SIGNAL_COUNT) ||
        requested(FAMILY_METRIC_COUNTRY_BIO_SIGNAL_COUNT)) {
        const int32_t metric_country = cell_country_slot(cell);
        const size_t country = static_cast<size_t>(std::max(0, metric_country));
        const bool in_range = metric_country >= 0;
        const auto read_count = [&](const std::vector<int32_t> &column) {
            return in_range && country < column.size()
                ? static_cast<int64_t>(column[country]) : 0;
        };
        if (requested(FAMILY_METRIC_COUNTRY_ENERGY_CELL_COUNT))
            metrics[FAMILY_METRIC_COUNTRY_ENERGY_CELL_COUNT] =
                count_q16(read_count(_epoch_country_energy_cell_count));
        if (requested(
                FAMILY_METRIC_COUNTRY_ABUNDANT_MOUNTAIN_FOREST_CELL_COUNT))
            metrics[
                FAMILY_METRIC_COUNTRY_ABUNDANT_MOUNTAIN_FOREST_CELL_COUNT] =
                count_q16(read_count(
                    _epoch_country_abundant_mountain_forest_cell_count));
        if (requested(FAMILY_METRIC_COUNTRY_LANDFORM_SIGNAL_COUNT))
            metrics[FAMILY_METRIC_COUNTRY_LANDFORM_SIGNAL_COUNT] =
                count_q16(read_count(_epoch_country_landform_signal_count));
        if (requested(FAMILY_METRIC_COUNTRY_WEATHER_SIGNAL_COUNT))
            metrics[FAMILY_METRIC_COUNTRY_WEATHER_SIGNAL_COUNT] =
                count_q16(read_count(_epoch_country_weather_signal_count));
        if (requested(FAMILY_METRIC_COUNTRY_BIO_SIGNAL_COUNT))
            metrics[FAMILY_METRIC_COUNTRY_BIO_SIGNAL_COUNT] =
                count_q16(read_count(_epoch_country_bio_signal_count));
    }
    static const bool verify_metrics = [] {
        const char *value = pk::runtime_switch_value(pk::RuntimeSwitch::PK_ECONOMY_MEMO_VERIFY);
        return value && std::strcmp(value, "1") == 0;
    }();
    if (verify_metrics && !metric_mask.is_all() &&
        metric_count <= FAMILY_METRIC_COUNT) {
        std::array<int64_t, FAMILY_METRIC_COUNT> reference{};
        fill_family_behavior_metrics(family_index, branch, cell, reference.data(), metric_count);
        for (int32_t metric = 0; metric < metric_count; ++metric) {
            if (requested(metric) && metrics[metric] != reference[metric]) {
                std::fprintf(stderr, "[family-metric-mask-mismatch] day=%lld family=%d cell=%d metric=%d\n",
                    static_cast<long long>(_current_day.get()), family_index, cell, metric);
                std::abort();
            }
        }
    }

}

} // namespace pk
