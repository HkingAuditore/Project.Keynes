// Capture the frozen Country input and prepare Economy's derived country views.
#include "economy_cost_probe.h"
#include "economy_effect_forward.h"
#include "economy_runtime.h"
#include "economy_hash.h"
#include "runtime_switch_registry.h"
#include "economy_graph_kernels.h"
#include "economy_graph_live_ops.h"
#include "economy_graph_stage_dispatch.h"
#include "runtime_economy_pod.h"
#include "modifier_api.h"
#include "country_api.h"
#include "economy_runtime_internal_external_types.inc"
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

int32_t popcount_u64(uint64_t value) {
    int32_t count = 0;
    while (value != 0) { value &= value - 1; ++count; }
    return count;
}


using namespace godot;
using namespace variant_helpers;


namespace {
int32_t modifier_factor_q16(double factor) {
    if (!std::isfinite(factor) || factor <= 0.0) return 0;
    const double scaled = std::round(factor *
        static_cast<double>(NativeEconomyRuntime::Q16_ONE));
    return static_cast<int32_t>(std::clamp(
        scaled, 0.0, static_cast<double>(std::numeric_limits<int32_t>::max())));
}
} // namespace

namespace {

using Clock = std::chrono::steady_clock;

// effect_pod_upsert / effect_pod_metric / effect_pod_retire now live in
// economy_effect_forward.h: the family write points are split across
// economy_runtime.cpp and economy_runtime_family_buff.cpp, and both translation
// units have to funnel through the same routing decision.

constexpr int64_t price_adjustment_reference(
        int64_t current_price, int64_t adjustment_anchor_price,
        int64_t period_change_q16) {
    return period_change_q16 < 0
        ? std::max<int64_t>(NativeEconomyRuntime::PRICE_NUMERIC_GUARD_MIN,
                            current_price)
        : adjustment_anchor_price;
}

static_assert(price_adjustment_reference(100, 1000, -1) == 100);
static_assert(price_adjustment_reference(100, 1000, 1) == 1000);

double elapsed_ms(const Clock::time_point &start) {
    return std::chrono::duration<double, std::milli>(Clock::now() - start).count();
}


} // namespace

// ─── PopulationStore ───────────────────────────────────────────────────

// PopulationStore implementation moved to economy_runtime_storage.cpp.

// PopulationStore allocation and lookup implementation moved to
// economy_runtime_storage.cpp.

// PopulationStore::allocate_slot implementation moved to
// economy_runtime_storage.cpp.

// PopulationStore handle/release implementation moved to
// economy_runtime_storage.cpp.



bool NativeEconomyRuntime::capture_country_epoch(
        std::string &error, bool *out_pending_city_factors) {
    auto phase_started = Clock::now();
    const auto record_phase = [&](const char *name) {
        const auto now = Clock::now();
        EconomyCostProbe::record(name, _current_day.get(),
            std::chrono::duration<double, std::milli>(now - phase_started).count());
        phase_started = now;
    };
    if (out_pending_city_factors != nullptr)
        *out_pending_city_factors = false;
    _technology_words = static_cast<int32_t>((_technology_ids.size() + 63) / 64);
    if (_country_runtime == nullptr || !country_reads().economy_available() ||
        country_reads().good_count() != static_cast<int32_t>(_good_ids.size()) ||
        country_reads().technology_count() != static_cast<int32_t>(_technology_ids.size())) {
        error = "country_runtime_required";
        return false;
    }
    CountryReadView::Snapshot snapshot;
    if (!country_reads().copy_economy_snapshot(snapshot) ||
        snapshot.cell_country_slot.size() != static_cast<size_t>(_cell_count.get()) ||
        snapshot.country_handles.size() != static_cast<size_t>(snapshot.country_count) ||
        (!snapshot.country_capital_cells.empty() &&
         snapshot.country_capital_cells.size() !=
             static_cast<size_t>(snapshot.country_count)) ||
        snapshot.country_political_regime_capabilities.size() !=
            static_cast<size_t>(snapshot.country_count) ||
        snapshot.technology_words != _technology_words) {
        error = "country_snapshot_shape_invalid";
        return false;
    }
    record_phase("country_capture.snapshot");
    _epoch_cell_country = std::move(snapshot.cell_country_slot);
    _epoch_country_handles = std::move(snapshot.country_handles);
    _epoch_country_political_regime_capabilities = std::move(
        snapshot.country_political_regime_capabilities);
    _epoch_country_capital_cells = std::move(snapshot.country_capital_cells);
    _epoch_player_country_slot = country_reads().starting_country_slot();
    _epoch_country_technologies = std::move(snapshot.country_technologies);
    _epoch_country_count = snapshot.country_count;
    _epoch_country_technology_words = snapshot.technology_words;
    if (snapshot.research_signal_words < 0 ||
        snapshot.research_signal_count < 0 ||
        snapshot.country_research_signals.size() !=
            static_cast<size_t>(std::max(0, _epoch_country_count)) *
                static_cast<size_t>(std::max(0, snapshot.research_signal_words)) ||
        snapshot.research_signal_words * 64 < snapshot.research_signal_count ||
        (snapshot.research_signal_count > 0 &&
         snapshot.research_signal_words <= 0)) {
        error = "country_research_signal_snapshot_shape_invalid";
        return false;
    }
    if (snapshot.research_signal_words != _research_signal_prefix_words) {
        error = "country_research_signal_words_mismatch";
        return false;
    }
    _epoch_country_research_signals =
        std::move(snapshot.country_research_signals);
    _epoch_country_research_signal_words = snapshot.research_signal_words;
    const size_t expected_technology_words =
        static_cast<size_t>(std::max(0, _epoch_country_count)) *
        static_cast<size_t>(std::max(0, _epoch_country_technology_words));
    if (_technology_metric_input_override_enabled) {
        if (_technology_metric_input_override.size() ==
            expected_technology_words) {
            _epoch_country_technologies = _technology_metric_input_override;
        } else {
            _technology_metric_input_override.clear();
            _technology_metric_input_override_enabled = false;
        }
    }
    refresh_technology_metrics();
    // X14 reads the last COMMITTED class-opinion rows. This capture runs before
    // today's publish pass, so it cannot observe the buffer being written for
    // the day. The refresh itself reuses the rows when the source revision has
    // not advanced.
    refresh_class_opinion_metrics();
    record_phase("country_capture.technology_metrics");
    // Must run right after _epoch_country_count so the CSR slice count matches
    // the ownership column it was derived from. Landing here (instead of at the
    // end of the capture) means a later capture failure leaves a territory index
    // that is stale in exactly the same way as the rest of the epoch state.
    refresh_country_territory_cache();
    // X13 residual: one pass over the same ownership column the CSR was built
    // from. `advance_climate_day_columns` has already updated today's hazard
    // counters, so this is the frozen country answer every metric sample reads.
    _epoch_country_hazard_free_cell_share_q16.assign(
        static_cast<size_t>(std::max(0, _epoch_country_count)), 0);
    if (_epoch_country_hazard_free_cell_share_q16.size() > 0 &&
        _epoch_cell_country.size() == static_cast<size_t>(_cell_count.get()) &&
        _cell_days_since_hazard.size() == _epoch_cell_country.size()) {
        std::vector<int32_t> owned_by_country(
            _epoch_country_hazard_free_cell_share_q16.size(), 0);
        std::vector<int32_t> hazard_free_by_country(
            _epoch_country_hazard_free_cell_share_q16.size(), 0);
        for (int32_t cell = 0; cell < _cell_count.get(); ++cell) {
            const int32_t country = _epoch_cell_country[static_cast<size_t>(cell)];
            if (country < 0 || static_cast<size_t>(country) >=
                    owned_by_country.size()) continue;
            ++owned_by_country[static_cast<size_t>(country)];
            if (_cell_days_since_hazard[cell] >= 365)
                ++hazard_free_by_country[static_cast<size_t>(country)];
        }
        for (size_t country = 0; country < owned_by_country.size(); ++country) {
            const int32_t owned = owned_by_country[country];
            if (owned <= 0) continue;
            _epoch_country_hazard_free_cell_share_q16[country] =
                static_cast<int32_t>(std::clamp<int64_t>(
                    static_cast<int64_t>(hazard_free_by_country[country]) *
                        Q16_ONE / owned, 0, Q16_ONE));
        }
    }
    // X12 consumes the territory hash refreshed with the index above and the
    // canal topology. Keep geography current before tag rows sample 75/76.
    rebuild_epoch_geo_columns();
    // X9-a reads the branch table frozen by the previous FAMILY_COMMIT. Refresh
    // the aggregate columns before tag evaluation so day-one `cell.clan` and
    // `cell.eminent_clan` rows describe the same branch table as the metrics.
    rebuild_epoch_family_cell_metrics();
    rebuild_epoch_family_country_metrics();
    // X7-b: freeze the three non-tag country counts beside the existing family
    // aggregates. Building groups, landform/terrain, and resource abundance are
    // all Economy-owned committed columns; no live Country read is involved.
    _epoch_country_energy_cell_count.assign(
        static_cast<size_t>(std::max(0, _epoch_country_count)), 0);
    _epoch_country_abundant_mountain_forest_cell_count.assign(
        static_cast<size_t>(std::max(0, _epoch_country_count)), 0);
    _epoch_country_landform_signal_count.assign(
        static_cast<size_t>(std::max(0, _epoch_country_count)), 0);
    _epoch_country_weather_signal_count.assign(
        static_cast<size_t>(std::max(0, _epoch_country_count)), 0);
    _epoch_country_bio_signal_count.assign(
        static_cast<size_t>(std::max(0, _epoch_country_count)), 0);
    const int32_t x7b_cells = std::max(0, _cell_count.get());
    const int32_t x7b_countries = std::max(0, _epoch_country_count);
    const bool x7b_building_csr =
        _building_cell_offsets.size() == static_cast<size_t>(x7b_cells + 1);
    for (int32_t cell = 0; cell < x7b_cells; ++cell) {
        const int32_t country = _epoch_cell_country[static_cast<size_t>(cell)];
        if (country < 0 || country >= x7b_countries) continue;
        if (x7b_building_csr) {
            for (int32_t group_index = _building_cell_offsets[cell];
                 group_index < _building_cell_offsets[cell + 1]; ++group_index) {
                const auto group = building_view(static_cast<size_t>(group_index));
                if (group.count <= 0 || group.type_id < 0 ||
                    group.type_id >= static_cast<int32_t>(
                        _building_economic_sectors.size()))
                    continue;
                if (_building_economic_sectors[
                        static_cast<size_t>(group.type_id)] == 3) {
                    ++_epoch_country_energy_cell_count[
                        static_cast<size_t>(country)];
                    break;
                }
            }
        }
        const int32_t abundance = cell < static_cast<int32_t>(
                _cell_resource_abundance_q16.size())
            ? _cell_resource_abundance_q16[static_cast<size_t>(cell)] : 0;
        const int32_t landform = cell < static_cast<int32_t>(
                _building_landform.size())
            ? _building_landform[static_cast<size_t>(cell)] : -1;
        const int32_t terrain = cell < static_cast<int32_t>(
                _building_terrain.size())
            ? _building_terrain[static_cast<size_t>(cell)] : -1;
        // cell.abundant is >=80% Q16. The design's mountain/forest pair is
        // LandformType.MOUNTAIN plus TerrainType.FOREST (not
        // landform.forest); named ids are resolved at catalog compile time.
        if (abundance >= static_cast<int32_t>(Q16_ONE * 80 / 100) &&
            _abundant_mountain_landform_id >= 0 &&
            _abundant_forest_terrain_id >= 0 &&
            (landform == _abundant_mountain_landform_id ||
             terrain == _abundant_forest_terrain_id)) {
            ++_epoch_country_abundant_mountain_forest_cell_count[
                static_cast<size_t>(country)];
        }
    }
    const size_t signal_stride = static_cast<size_t>(
        std::max(0, _epoch_country_research_signal_words));
    if (signal_stride > 0) {
        for (int32_t country = 0; country < x7b_countries; ++country) {
            const size_t base = static_cast<size_t>(country) * signal_stride;
            for (size_t prefix = 0; prefix < 3; ++prefix) {
                int32_t count = 0;
                for (size_t word = 0; word < signal_stride; ++word) {
                    const size_t prefix_index =
                        prefix * signal_stride + word;
                    if (prefix_index >= _research_signal_prefix_masks.size())
                        break;
                    count += popcount_u64(
                        _epoch_country_research_signals[base + word] &
                        _research_signal_prefix_masks[prefix_index]);
                }
                if (prefix == 0)
                    _epoch_country_landform_signal_count[
                        static_cast<size_t>(country)] = count;
                else if (prefix == 1)
                    _epoch_country_weather_signal_count[
                        static_cast<size_t>(country)] = count;
                else
                    _epoch_country_bio_signal_count[
                        static_cast<size_t>(country)] = count;
            }
        }
    }
    // The tag tables read per-cell metrics, so they are only valid for the epoch
    // that produced them.
    //
    // R-3, stated precisely: the tag tables are safe to read concurrently because
    // they are immutable snapshots swapped by atomic store, NOT because this whole
    // function is atomic. The territory index right above
    // (`refresh_country_territory_cache`) is rewritten IN PLACE when ownership
    // changes, so a reader that needs territory and tags together must hold the input
    // capture boundary lock, which is why `step_ideology_instance_refresh` takes it.
    // Reading only the tag snapshot needs no lock at all.
    record_phase("country_capture.derived_metrics");
    rebuild_epoch_tag_snapshot();
    record_phase("country_capture.tags");
    _epoch_country_generation = snapshot.generation;
    _epoch_country_hash = snapshot.state_hash;
    _epoch_tax_policy_version = snapshot.tax_policy_version;
    _epoch_income_tax_rates = std::move(snapshot.income_tax_rates);
    _epoch_consumption_tax_rates = std::move(snapshot.consumption_tax_rates);
    _epoch_business_tax_rates = std::move(snapshot.business_tax_rates);
    _epoch_import_tax_rates = std::move(snapshot.import_tax_rates);
    _epoch_export_tax_rates = std::move(snapshot.export_tax_rates);
    _epoch_income_tax_modes = std::move(snapshot.income_tax_modes);
    _epoch_consumption_tax_modes = std::move(snapshot.consumption_tax_modes);
    _epoch_business_tax_modes = std::move(snapshot.business_tax_modes);
    _epoch_import_tax_modes = std::move(snapshot.import_tax_modes);
    _epoch_export_tax_modes = std::move(snapshot.export_tax_modes);
    std::vector<uint32_t> snapshot_cell_tax_policy_ids =
        std::move(snapshot.cell_tax_policy_ids);
    auto snapshot_cell_tax_policies = std::move(snapshot.cell_tax_policies);
    const auto tax_shape_valid = [&](const std::vector<int32_t> &rates,
                                     size_t item_count) {
        return rates.size() == static_cast<size_t>(
            std::max(0, _epoch_country_count)) * item_count;
    };
    if (!tax_shape_valid(_epoch_income_tax_rates, _profession_ids.size()) ||
        !tax_shape_valid(_epoch_consumption_tax_rates, _good_ids.size()) ||
        !tax_shape_valid(_epoch_business_tax_rates, _building_types.size()) ||
        !tax_shape_valid(_epoch_import_tax_rates, _good_ids.size()) ||
        !tax_shape_valid(_epoch_export_tax_rates, _good_ids.size()) ||
        !tax_shape_valid(_epoch_income_tax_modes, _profession_ids.size()) ||
        !tax_shape_valid(_epoch_consumption_tax_modes, _good_ids.size()) ||
        !tax_shape_valid(_epoch_business_tax_modes, _building_types.size()) ||
        !tax_shape_valid(_epoch_import_tax_modes, _good_ids.size()) ||
        !tax_shape_valid(_epoch_export_tax_modes, _good_ids.size())) {
        error = "country_tax_snapshot_shape_invalid";
        return false;
    }
    if (snapshot_cell_tax_policy_ids.size() !=
            static_cast<size_t>(_cell_count.get()) ||
        snapshot_cell_tax_policies.empty()) {
        error = "country_cell_tax_snapshot_shape_invalid";
        return false;
    }
    record_phase("country_capture.tax_snapshot");
    refresh_country_availability_cache();
    record_phase("country_capture.availability");
    _epoch_country_merchant_population.assign(
        static_cast<size_t>(std::max(0, _epoch_country_count)), 0);
    _epoch_country_population.assign(
        static_cast<size_t>(std::max(0, _epoch_country_count)), 0);
    if (_merchant_offsets.size() == static_cast<size_t>(_cell_count.get() + 1)) {
        const bool use_index = _merchant_nonempty_cells_valid;
        const int32_t scan_count = use_index
            ? static_cast<int32_t>(_merchant_nonempty_cells.size()) : _cell_count.get();
        for (int32_t scan = 0; scan < scan_count; ++scan) {
            const int32_t cell = use_index ? _merchant_nonempty_cells[
                static_cast<size_t>(scan)] : scan;
            const int32_t country = _epoch_cell_country[cell];
            if (country < 0 || country >= _epoch_country_count) continue;
            for (int32_t k = _merchant_offsets[cell];
                 k < _merchant_offsets[cell + 1]; ++k) {
                const int32_t slot = _merchant_slots[k];
                if (slot < 0 || slot >= static_cast<int32_t>(population_store().population.size()))
                    continue;
                _epoch_country_merchant_population[static_cast<size_t>(country)] =
                    saturating_add(_epoch_country_merchant_population[
                        static_cast<size_t>(country)],
                        std::max<int64_t>(0, population_store().population[slot]),
                        _saturation_count);
            }
        }
    }
    _epoch_country_output_factor_q16.assign(
        static_cast<size_t>(std::max(0, _epoch_country_count)), Q16_ONE);
    _epoch_country_sector_output_factor_q16.assign(
        static_cast<size_t>(std::max(0, _epoch_country_count)) * 5U, Q16_ONE);
    _epoch_country_research_output_factor_q16.assign(
        static_cast<size_t>(std::max(0, _epoch_country_count)), Q16_ONE);
    _epoch_country_family_output_factor_q16.assign(
        static_cast<size_t>(std::max(0, _epoch_country_count)) *
            _building_upgrade_family_ids.size(), Q16_ONE);
    _epoch_country_good_output_factor_q16.assign(
        static_cast<size_t>(std::max(0, _epoch_country_count)) *
            _good_ids.size(), Q16_ONE);
    _epoch_country_good_input_factor_q16.assign(
        static_cast<size_t>(std::max(0, _epoch_country_count)) *
            _good_ids.size(), Q16_ONE);
    _epoch_country_good_consumption_factor_q16.assign(
        static_cast<size_t>(std::max(0, _epoch_country_count)) *
            _good_ids.size(), Q16_ONE);
    _epoch_country_resource_use_factor_q16.assign(
        static_cast<size_t>(std::max(0, _epoch_country_count)) *
            _resource_ids.size(), Q16_ONE);
    _epoch_country_resource_generation_factor_q16.assign(
        static_cast<size_t>(std::max(0, _epoch_country_count)) *
            _resource_ids.size(), Q16_ONE);
    // X16: default 1.0 tolerance and 0 bp bias, overwritten per country below for the
    // professions that actually declare the stat.
    //
    // The row width is the REAL profession count, not `max(1, count)`: the stride is
    // used to index `_epoch_country_profession_*` and a `max(1, 0)` width would make
    // country N and country N+1 overlap when the catalog has no professions yet.
    _epoch_country_profession_tax_tolerance_q16.assign(
        static_cast<size_t>(std::max(0, _epoch_country_count)) *
            _profession_ids.size(), Q16_ONE);
    _epoch_country_profession_satisfaction_bp.assign(
        static_cast<size_t>(std::max(0, _epoch_country_count)) *
            _profession_ids.size(), 0);
    _epoch_country_general_satisfaction_bp.assign(
        static_cast<size_t>(std::max(0, _epoch_country_count)), 0);
    _epoch_country_reserve_pct.assign(
        static_cast<size_t>(std::max(0, _epoch_country_count)), 0);
    _epoch_country_terrain_sector_output_factor_q16.assign(
        static_cast<size_t>(std::max(0, _epoch_country_count)) *
            _modifier_terrain_ids.size() * 5U, Q16_ONE);
    _epoch_country_landform_sector_output_factor_q16.assign(
        static_cast<size_t>(std::max(0, _epoch_country_count)) *
            _modifier_landform_ids.size() * 5U, Q16_ONE);
    _epoch_country_building_output_factor_q16.assign(
        static_cast<size_t>(std::max(0, _epoch_country_count)) *
            _building_type_ids.size(), Q16_ONE);
    _epoch_country_production_input_factor_q16.assign(
        static_cast<size_t>(std::max(0, _epoch_country_count)), Q16_ONE);
    _epoch_country_household_consumption_factor_q16.assign(
        static_cast<size_t>(std::max(0, _epoch_country_count)), Q16_ONE);
    _epoch_country_death_factor_q16.assign(
        static_cast<size_t>(std::max(0, _epoch_country_count)), Q16_ONE);
    _epoch_country_resource_global_use_factor_q16.assign(
        static_cast<size_t>(std::max(0, _epoch_country_count)), Q16_ONE);
    _epoch_country_climate_loss_factor_q16.assign(
        static_cast<size_t>(std::max(0, _epoch_country_count)) * 4U, Q16_ONE);
    _epoch_country_climate_profile_loss_factor_q16.assign(
        static_cast<size_t>(std::max(0, _epoch_country_count)) *
            _production_climate_profile_ids.size() * 4U, Q16_ONE);
    _epoch_country_trade_capacity_factor_q16.assign(
        static_cast<size_t>(std::max(0, _epoch_country_count)), Q16_ONE);
    _epoch_country_trade_speed_factor_q16.assign(
        static_cast<size_t>(std::max(0, _epoch_country_count)), Q16_ONE);
    // Dense [country][good] twins. Q16_ONE -- not 0 -- is the whole point: a good
    // with no `country.trade.good.*` stat keeps the neutral factor, while a zero
    // fill would silently kill every trade of that good without any error.
    _epoch_country_good_trade_capacity_factor_q16.assign(
        static_cast<size_t>(std::max(0, _epoch_country_count)) *
            _good_ids.size(), Q16_ONE);
    _epoch_country_good_trade_speed_factor_q16.assign(
        static_cast<size_t>(std::max(0, _epoch_country_count)) *
            _good_ids.size(), Q16_ONE);
    _epoch_country_water_capability.assign(
        static_cast<size_t>(std::max(0, _epoch_country_count)), 0);
    auto country_has_frozen_tech = [&](int32_t country, int32_t tech) {
        if (tech < 0 || country < 0 || country >= _epoch_country_count ||
            _epoch_country_technology_words <= 0) return false;
        const size_t index = static_cast<size_t>(country) *
            static_cast<size_t>(_epoch_country_technology_words) +
            static_cast<size_t>(tech / 64);
        return index < _epoch_country_technologies.size() &&
            (_epoch_country_technologies[index] &
                (uint64_t{1} << (tech % 64))) != 0;
    };
    for (int32_t country = 0; country < _epoch_country_count; ++country) {
        uint8_t cap = 0;
        if (country_has_frozen_tech(country, _water_tech_river))
            cap |= WATER_CAP_RIVER;
        if (country_has_frozen_tech(country, _water_tech_shallow))
            cap |= WATER_CAP_SHALLOW_SEA;
        if (country_has_frozen_tech(country, _water_tech_far))
            cap |= WATER_CAP_FAR_SEA;
        if (country_has_frozen_tech(country, _water_tech_deep))
            cap |= WATER_CAP_DEEP_SEA;
        _epoch_country_water_capability[static_cast<size_t>(country)] = cap;
    }
    _epoch_country_construction_cost_factor_q16.assign(
        static_cast<size_t>(std::max(0, _epoch_country_count)), Q16_ONE);
    _epoch_country_construction_time_factor_q16.assign(
        static_cast<size_t>(std::max(0, _epoch_country_count)), Q16_ONE);
    record_phase("country_capture.population_and_defaults");
    const auto city_factor_started = Clock::now();
    // The city-factor reader can now yield mid-work-set (plan §14.3). Report it
    // so the caller parks and resumes instead of treating a yield as success:
    // publishing `_epoch_city_factor_valid` early would hand consumers a matrix
    // with only the first shard painted.
    // Both readers advance independently (plan §14.3). Chaining them made the
    // output factors update only on the LAST city shard, so on a multi-shard
    // epoch production factors stayed stale for the intermediate slices.
    const bool city_factors_done = refresh_city_modifier_factors();
    const bool output_factors_done = refresh_city_output_modifier_factors();
    _epoch_begin_city_factor_ms = elapsed_ms(city_factor_started);
    record_phase("country_capture.city_modifiers");
    if (!city_factors_done || !output_factors_done) {
        if (out_pending_city_factors != nullptr)
            *out_pending_city_factors = true;
        return true;
    }
#include "economy_runtime_country_epoch_capture_modifiers.inc"
    record_phase("country_capture.country_modifiers");
    // R-4 metric 69: treasury reserve ratio per country, in percentage points.
    //
    // ONE pass over the cohorts, not one pass per country: the per-country version
    // scanned every cell for every country, which on a 192-cell world with several
    // countries is O(C x cells x cohorts) inside the epoch capture -- and the capture
    // runs on the critical path of the daily barrier. It made the worker miss the
    // climate handshake (`[climate/worker][b8] physics_knobs ready=0`) and the whole
    // day never committed.
    //
    // v0 denominator is 365 x the country's summed `income_ema`. `income_ema` is the
    // daily net-income EMA already in the save, so this adds NO save state; a true
    // rolling-year accumulator is deferred to M4 (09 §8).
    {
        const size_t reserve_countries = _epoch_country_reserve_pct.size();
        if (reserve_countries > 0) {
            std::vector<int64_t> annual_income(reserve_countries, 0);
            const size_t reserve_cells = std::min(
                _epoch_cell_country.size(),
                static_cast<size_t>(std::max(0, _cell_count.get())));
            for (size_t cell_index = 0; cell_index < reserve_cells; ++cell_index) {
                const int32_t slot_country =
                    _epoch_cell_country[cell_index];
                if (slot_country < 0 ||
                    static_cast<size_t>(slot_country) >= reserve_countries)
                    continue;
                population_store().for_each_in_cell(
                    static_cast<int32_t>(cell_index), [&](int32_t slot) {
                    annual_income[static_cast<size_t>(slot_country)] +=
                        std::max<int64_t>(0, population_store().income_ema[slot]);
                });
            }
            for (size_t country = 0; country < reserve_countries; ++country) {
                const int64_t yearly = annual_income[country] * 365;
                int64_t reserve_pct = 0;
                if (yearly > 0 && _country_runtime != nullptr) {
                    const int64_t cash = country_reads().cash_for_slot(
                        static_cast<int32_t>(country));
                    reserve_pct = std::clamp<int64_t>(
                        cash * 100 / yearly, 0, 1000);
                }
                _epoch_country_reserve_pct[country] =
                    static_cast<int32_t>(reserve_pct);
            }
        }
    }
    record_phase("country_capture.reserves");
#include "economy_runtime_country_epoch_capture_tax_rows.inc"
    const auto building_factor_started = Clock::now();
    refresh_building_modifier_factors();
    _epoch_begin_building_factor_ms = elapsed_ms(building_factor_started);
    refresh_epoch_development();
    record_phase("country_capture.building_factors_and_development");
    return true;
}

} // namespace pk
