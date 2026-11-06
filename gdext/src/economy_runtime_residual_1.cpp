// Extracted residual economy methods; function bodies are token-preserved.
// Residual economy methods extracted from economy_runtime.cpp; bodies are token-preserved.
#include "economy_cost_probe.h"
#include "economy_effect_forward.h"
#include "economy_runtime.h"
#include "economy_hash.h"
#include "runtime_switch_registry.h"
#include "economy_graph_kernels.h"
#include "economy_graph_live_ops.h"
#include "economy_graph_stage_dispatch.h"
#include "runtime_economy_pod.h"
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
        snapshot.technology_words != _technology_words) {
        error = "country_snapshot_shape_invalid";
        return false;
    }
    _epoch_cell_country = std::move(snapshot.cell_country_slot);
    _epoch_country_handles = std::move(snapshot.country_handles);
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
    // Must run right after _epoch_country_count so the CSR slice count matches
    // the ownership column it was derived from. Landing here (instead of at the
    // end of the capture) means a later capture failure leaves a territory index
    // that is stale in exactly the same way as the rest of the epoch state.
    rebuild_country_territory_index();
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
    // X12 consumes both the territory hash and the canal topology. Compute the
    // hash before the tag snapshot so the derived geography columns are current
    // when tag rows sample metrics 75/76.
    uint64_t topology_hash = 1469598103934665603ULL;
    for (const int32_t country : _epoch_cell_country) {
        const uint32_t value = static_cast<uint32_t>(country);
        for (int32_t byte = 0; byte < 4; ++byte) {
            topology_hash ^= static_cast<uint8_t>((value >> (byte * 8)) & 0xffU);
            topology_hash *= 1099511628211ULL;
        }
    }
    _epoch_country_topology_hash = (topology_hash & 0x7fffffffffffffffULL) | 1ULL;
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
    // (`rebuild_country_territory_index`) is still rewritten IN PLACE -- it always
    // was -- so a reader that needs territory and tags together must hold the input
    // capture boundary lock, which is why `step_ideology_instance_refresh` takes it.
    // Reading only the tag snapshot needs no lock at all.
    rebuild_epoch_tag_snapshot();
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
    const auto requirements_available = [&](int32_t country, int32_t begin,
                                             int32_t end,
                                             const std::vector<int32_t> &requirements) {
        if (begin < 0 || end < begin ||
            end > static_cast<int32_t>(requirements.size())) return false;
        if (begin == end) return true;
        for (int32_t i = begin; i < end; ++i) {
            const int32_t technology_id = requirements[i];
            if (technology_id < 0 ||
                technology_id >= static_cast<int32_t>(_technology_ids.size()))
                return false;
            const size_t word_index = static_cast<size_t>(country) *
                _epoch_country_technology_words + technology_id / 64;
            if (word_index < _epoch_country_technologies.size() &&
                (_epoch_country_technologies[word_index] &
                 (uint64_t{1} << (technology_id % 64))) != 0) return true;
        }
        return false;
    };
    const auto all_requirements_available = [&](int32_t country, int32_t begin,
                                                 int32_t end,
                                                 const std::vector<int32_t> &requirements) {
        if (begin < 0 || end < begin ||
            end > static_cast<int32_t>(requirements.size())) return false;
        for (int32_t i = begin; i < end; ++i) {
            const int32_t technology_id = requirements[i];
            if (technology_id < 0 ||
                technology_id >= static_cast<int32_t>(_technology_ids.size())) return false;
            const size_t word_index = static_cast<size_t>(country) *
                _epoch_country_technology_words + technology_id / 64;
            if (word_index >= _epoch_country_technologies.size() ||
                (_epoch_country_technologies[word_index] &
                 (uint64_t{1} << (technology_id % 64))) == 0) return false;
        }
        return true;
    };
    const auto dependency_requirements_available = [&](int32_t country,
                                                        int32_t type_id) {
        if (type_id < 0 || type_id + 1 >= static_cast<int32_t>(
                _building_dependency_branch_offsets.size())) return false;
        const int32_t branch_begin = _building_dependency_branch_offsets[
            static_cast<size_t>(type_id)];
        const int32_t branch_end = _building_dependency_branch_offsets[
            static_cast<size_t>(type_id + 1)];
        auto has_technology = [&](int32_t technology_id) {
            if (technology_id < 0 || technology_id >= static_cast<int32_t>(
                    _technology_ids.size())) return false;
            const size_t word_index = static_cast<size_t>(country) *
                _epoch_country_technology_words + technology_id / 64;
            return word_index < _epoch_country_technologies.size() &&
                (_epoch_country_technologies[word_index] &
                 (uint64_t{1} << (technology_id % 64))) != 0;
        };
        for (int32_t branch = branch_begin; branch < branch_end; ++branch) {
            const int32_t tech_begin = _building_dependency_branch_technology_offsets[
                static_cast<size_t>(branch)];
            const int32_t tech_end = _building_dependency_branch_technology_offsets[
                static_cast<size_t>(branch + 1)];
            bool branch_ready = true;
            for (int32_t edge = tech_begin; edge < tech_end; ++edge) {
                if (!has_technology(_building_dependency_branch_technologies[
                        static_cast<size_t>(edge)])) {
                    branch_ready = false;
                    break;
                }
            }
            if (!branch_ready) continue;
            const int32_t group_begin = _building_dependency_branch_group_offsets[
                static_cast<size_t>(branch)];
            const int32_t group_end = _building_dependency_branch_group_offsets[
                static_cast<size_t>(branch + 1)];
            for (int32_t group = group_begin; group < group_end; ++group) {
                if (!building_dependency_group_required_for_operation(group))
                    continue;
                bool group_ready = false;
                for (int32_t tag = _building_dependency_tag_offsets[
                        static_cast<size_t>(group)];
                     tag < _building_dependency_tag_offsets[
                        static_cast<size_t>(group + 1)]; ++tag) {
                    if (has_technology(_building_dependency_tags[
                            static_cast<size_t>(tag)])) {
                        group_ready = true;
                        break;
                    }
                }
                if (!group_ready) {
                    branch_ready = false;
                    break;
                }
            }
            if (branch_ready) return true;
        }
        return false;
    };
    _epoch_country_good_available.assign(
        static_cast<size_t>(std::max(0, _epoch_country_count)) *
            _good_ids.size(), 0);
    _epoch_country_market_available.assign(
        static_cast<size_t>(std::max(0, _epoch_country_count)) *
            _good_ids.size(), 0);
    _epoch_country_profession_available.assign(
        static_cast<size_t>(std::max(0, _epoch_country_count)) *
            _profession_ids.size(), 0);
    _epoch_country_variant_available.assign(
        static_cast<size_t>(std::max(0, _epoch_country_count)) *
            _variants.size(), 0);
    for (int32_t country = 0; country < _epoch_country_count; ++country) {
        for (int32_t good = 0;
             good < static_cast<int32_t>(_good_ids.size()); ++good) {
            const bool available =
                good + 1 < static_cast<int32_t>(
                    _good_technology_offsets.size()) &&
                requirements_available(country,
                    _good_technology_offsets[good],
                    _good_technology_offsets[good + 1],
                    _good_required_technologies);
            _epoch_country_good_available[
                static_cast<size_t>(country) * _good_ids.size() + good] =
                    available ? 1 : 0;
            const bool market_available = available ||
                (good < static_cast<int32_t>(_good_trade_enabled.size()) &&
                 _good_trade_enabled[good] != 0 &&
                 good < static_cast<int32_t>(_good_storage_modes.size()) &&
                 _good_storage_modes[good] == 0);
            _epoch_country_market_available[
                static_cast<size_t>(country) * _good_ids.size() + good] =
                    market_available ? 1 : 0;
        }
        for (int32_t profession = 0;
             profession < static_cast<int32_t>(_profession_ids.size());
             ++profession) {
            const bool available =
                profession + 1 < static_cast<int32_t>(
                    _profession_technology_offsets.size()) &&
                requirements_available(country,
                    _profession_technology_offsets[profession],
                    _profession_technology_offsets[profession + 1],
                    _profession_required_technologies);
            _epoch_country_profession_available[
                static_cast<size_t>(country) * _profession_ids.size() +
                profession] = available ? 1 : 0;
        }
        for (int32_t variant = 0;
             variant < static_cast<int32_t>(_variants.size()); ++variant) {
            const VariantChoice &choice = _variants[variant];
            bool available = true;
            for (int32_t component = 0;
                 component < choice.component_count; ++component) {
                const int32_t good = _components[
                    choice.component_begin + component].good_id;
                const size_t good_index = static_cast<size_t>(country) *
                    _good_ids.size() + static_cast<size_t>(std::max(0, good));
                if (good < 0 ||
                    good >= static_cast<int32_t>(_good_ids.size()) ||
                    good_index >= _epoch_country_good_available.size() ||
                    _epoch_country_good_available[good_index] == 0) {
                    available = false;
                    break;
                }
            }
            _epoch_country_variant_available[
                static_cast<size_t>(country) * _variants.size() + variant] =
                    available ? 1 : 0;
        }
    }
    _epoch_country_building_available.assign(
        static_cast<size_t>(std::max(0, _epoch_country_count)) *
            _building_types.size(), 0);
    _epoch_country_building_type_offsets.assign(
        static_cast<size_t>(std::max(0, _epoch_country_count)) + 1, 0);
    _epoch_country_building_type_indices.clear();
    _epoch_country_building_type_indices.reserve(
        static_cast<size_t>(std::max(0, _epoch_country_count)) *
            _building_types.size());
    for (int32_t country = 0; country < _epoch_country_count; ++country) {
        for (int32_t type_id = 0;
             type_id < static_cast<int32_t>(_building_types.size()); ++type_id) {
            const bool available = type_id + 1 < static_cast<int32_t>(
                    _building_technology_offsets.size()) &&
                requirements_available(country,
                    _building_technology_offsets[type_id],
                    _building_technology_offsets[type_id + 1],
                    _building_required_technologies) &&
                type_id + 1 < static_cast<int32_t>(
                    _building_all_technology_offsets.size()) &&
                all_requirements_available(country,
                    _building_all_technology_offsets[type_id],
                    _building_all_technology_offsets[type_id + 1],
                    _building_all_required_technologies) &&
                dependency_requirements_available(country, type_id);
            const size_t cache_index = static_cast<size_t>(country) *
                _building_types.size() + static_cast<size_t>(type_id);
            _epoch_country_building_available[cache_index] = available ? 1 : 0;
            if (available)
                _epoch_country_building_type_indices.push_back(type_id);
        }
        _epoch_country_building_type_offsets[country + 1] =
            static_cast<int32_t>(_epoch_country_building_type_indices.size());
    }
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
    if (!city_factors_done || !output_factors_done) {
        if (out_pending_city_factors != nullptr)
            *out_pending_city_factors = true;
        return true;
    }
    if (_modifier_runtime != nullptr) {
        for (int32_t country = 0; country < _epoch_country_count; ++country) {
            const uint64_t country_handle =
                _epoch_country_handles[static_cast<size_t>(country)];
            const auto freeze_tax_group = [&](const std::vector<int32_t> &stat_ids,
                                              std::vector<int32_t> &rates,
                                              const std::vector<int32_t> &modes,
                                              size_t item_count) {
                if (item_count == 0) return;
                const size_t begin = static_cast<size_t>(country) * item_count;
                std::vector<int32_t> percent_stat_ids;
                std::vector<int32_t> percent_bases;
                std::vector<size_t> percent_indices;
                percent_stat_ids.reserve(item_count);
                percent_bases.reserve(item_count);
                percent_indices.reserve(item_count);
                for (size_t item = 0; item < item_count; ++item) {
                    const size_t index = begin + item;
                    if (index >= modes.size() ||
                        modes[index] ==
                            NativeCountryRuntime::TAX_MODE_ABSOLUTE) {
                        continue;
                    }
                    percent_stat_ids.push_back(stat_ids[item]);
                    percent_bases.push_back(rates[index]);
                    percent_indices.push_back(index);
                }
                if (percent_stat_ids.empty()) return;
                std::vector<int32_t> effective = percent_bases;
                _modifier_runtime->effective_values(
                    ModifierRuntime::COUNTRY, percent_stat_ids.data(),
                    country_handle, percent_bases.data(), effective.data(),
                    percent_stat_ids.size());
                for (size_t i = 0; i < percent_indices.size(); ++i) {
                    rates[percent_indices[i]] = static_cast<int32_t>(
                        std::clamp<int64_t>(
                            effective[i],
                            NativeCountryRuntime::TAX_RATE_MIN_BP,
                            NativeCountryRuntime::TAX_RATE_MAX_BP));
                }
            };
            freeze_tax_group(_income_tax_stat_ids, _epoch_income_tax_rates,
                             _epoch_income_tax_modes, _profession_ids.size());
            freeze_tax_group(_consumption_tax_stat_ids,
                             _epoch_consumption_tax_rates,
                             _epoch_consumption_tax_modes, _good_ids.size());
            freeze_tax_group(_business_tax_stat_ids, _epoch_business_tax_rates,
                             _epoch_business_tax_modes, _building_types.size());
            freeze_tax_group(_import_tax_stat_ids, _epoch_import_tax_rates,
                             _epoch_import_tax_modes, _good_ids.size());
            freeze_tax_group(_export_tax_stat_ids, _epoch_export_tax_rates,
                             _epoch_export_tax_modes, _good_ids.size());
            _epoch_country_output_factor_q16[static_cast<size_t>(country)] =
                modifier_factor_q16(_modifier_runtime->country_economy_output_factor(
                    country_handle));
            for (int32_t sector = 0; sector < 5; ++sector)
                _epoch_country_sector_output_factor_q16[
                    static_cast<size_t>(country) * 5U + sector] =
                    modifier_factor_q16(
                        _modifier_runtime->country_sector_output_factor(
                            _epoch_country_handles[static_cast<size_t>(country)],
                            sector));
            _epoch_country_research_output_factor_q16[country] =
                modifier_factor_q16(
                    _modifier_runtime->country_research_institution_output_factor(
                        _epoch_country_handles[static_cast<size_t>(country)]));
            for (size_t family = 0;
                 family < _country_family_output_stat_ids.size(); ++family) {
                _epoch_country_family_output_factor_q16[
                    static_cast<size_t>(country) *
                        _country_family_output_stat_ids.size() + family] =
                    modifier_factor_q16(_modifier_runtime->effective_value(
                        ModifierRuntime::COUNTRY,
                        _country_family_output_stat_ids[family], country_handle,
                        0, 1.0));
            }
            for (size_t good = 0;
                 good < _country_good_output_stat_ids.size(); ++good) {
                _epoch_country_good_output_factor_q16[
                    static_cast<size_t>(country) *
                        _country_good_output_stat_ids.size() + good] =
                    modifier_factor_q16(_modifier_runtime->effective_value(
                        ModifierRuntime::COUNTRY,
                        _country_good_output_stat_ids[good], country_handle,
                        0, 1.0));
                _epoch_country_good_input_factor_q16[
                    static_cast<size_t>(country) * _good_ids.size() + good] =
                    modifier_factor_q16(_modifier_runtime->effective_value(
                        ModifierRuntime::COUNTRY,
                        _country_good_input_stat_ids[good], country_handle,
                        0, 1.0));
                _epoch_country_good_consumption_factor_q16[
                    static_cast<size_t>(country) * _good_ids.size() + good] =
                    modifier_factor_q16(_modifier_runtime->effective_value(
                        ModifierRuntime::COUNTRY,
                        _country_good_consumption_stat_ids[good], country_handle,
                        0, 1.0));
            }
            for (size_t resource = 0; resource < _resource_ids.size(); ++resource) {
                const size_t index = static_cast<size_t>(country) *
                    _resource_ids.size() + resource;
                _epoch_country_resource_use_factor_q16[index] =
                    modifier_factor_q16(_modifier_runtime->effective_value(
                        ModifierRuntime::COUNTRY,
                        _country_resource_use_stat_ids[resource], country_handle,
                        0, 1.0));
                _epoch_country_resource_generation_factor_q16[index] =
                    modifier_factor_q16(_modifier_runtime->effective_value(
                        ModifierRuntime::COUNTRY,
                        _country_resource_generation_stat_ids[resource],
                        country_handle, 0, 1.0));
            }
            // X16: per-profession tax tolerance (Q16, clamped to [0.5, 3.0]) and
            // satisfaction bias (bp, clamped to [-2500, 2500]).
            //
            // Clamped HERE rather than at the reader so the frozen epoch value is the
            // one the game actually uses: a card that stacks to 5x cannot overflow the
            // Q16 multiply later, and a bias cannot push satisfaction past the design
            // envelope.
            for (size_t profession = 0; profession < _profession_ids.size();
                 ++profession) {
                const size_t index = static_cast<size_t>(country) *
                    _profession_ids.size() + profession;
                const int32_t tolerance_stat =
                    profession < _profession_tax_tolerance_stat_ids.size()
                        ? _profession_tax_tolerance_stat_ids[profession] : -1;
                const int32_t bias_stat =
                    profession < _profession_satisfaction_bp_stat_ids.size()
                        ? _profession_satisfaction_bp_stat_ids[profession] : -1;
                int32_t tolerance_q16 = Q16_ONE;
                if (tolerance_stat >= 0)
                    tolerance_q16 = static_cast<int32_t>(std::clamp<int64_t>(
                        modifier_factor_q16(_modifier_runtime->effective_value(
                            ModifierRuntime::COUNTRY, tolerance_stat,
                            country_handle, 0, 1.0)),
                        Q16_ONE / 2, 3 * Q16_ONE));
                int32_t bias_bp = 0;
                if (bias_stat >= 0)
                    bias_bp = static_cast<int32_t>(std::clamp<int64_t>(
                        static_cast<int64_t>(std::llround(
                            _modifier_runtime->effective_value(
                                ModifierRuntime::COUNTRY, bias_stat,
                                country_handle, 0, 0.0))),
                        -2500, 2500));
                _epoch_country_profession_tax_tolerance_q16[index] = tolerance_q16;
                _epoch_country_profession_satisfaction_bp[index] = bias_bp;
                // X16 PROBE (temporary). Answers "why does the frozen table stay at the
                // default while the Modifier read is correct?" without guessing:
                //
                //   this          -- which NativeEconomyRuntime actually ran the freeze
                //   modifier      -- whether it had a ModifierRuntime at that moment
                //   stat / raw    -- the resolved id and what effective_value returned
                //   epoch_id      -- which epoch this row belongs to
                //
                // Compared against the same line printed by
                // `get_epoch_profession_report`, this separates "the report reads a
                // different instance" from "the freeze ran before Modifier had the row".
                static int64_t x16_freeze_probe_last_epoch = -1;
                if (pk::runtime_switch_value(pk::RuntimeSwitch::PK_X16_PROBE) != nullptr &&
                    profession == 0 && _epoch_id != x16_freeze_probe_last_epoch) {
                    x16_freeze_probe_last_epoch = _epoch_id;
                    const double raw = tolerance_stat >= 0
                        ? _modifier_runtime->effective_value(
                            ModifierRuntime::COUNTRY, tolerance_stat,
                            country_handle, 0, 1.0)
                        : 1.0;
                    pk::log_error("[x16-freeze] this=%p modifier=%p country=%d "
                        "handle=%lld epoch_id=%lld profession=%zu stat=%d raw=%.5f "
                        "frozen=%d",
                        static_cast<const void *>(this),
                        static_cast<const void *>(_modifier_runtime),
                        country, static_cast<long long>(country_handle),
                        static_cast<long long>(_epoch_id), profession,
                        tolerance_stat, raw, tolerance_q16);
                }
            }
            const auto freeze_geography = [&](const std::vector<int32_t> &stat_ids,
                    size_t geography_count, std::vector<int32_t> &target) {
                const size_t row_width = geography_count * 5U;
                for (size_t index = 0; index < row_width; ++index)
                    target[static_cast<size_t>(country) * row_width + index] =
                        modifier_factor_q16(_modifier_runtime->effective_value(
                            ModifierRuntime::COUNTRY, stat_ids[index],
                            country_handle, 0, 1.0));
            };
            freeze_geography(_country_terrain_sector_output_stat_ids,
                _modifier_terrain_ids.size(),
                _epoch_country_terrain_sector_output_factor_q16);
            freeze_geography(_country_landform_sector_output_stat_ids,
                _modifier_landform_ids.size(),
                _epoch_country_landform_sector_output_factor_q16);
            _epoch_country_production_input_factor_q16[country] =
                modifier_factor_q16(_modifier_runtime->effective_value(
                    ModifierRuntime::COUNTRY, _country_production_input_stat_id,
                    country_handle, 0, 1.0));
            _epoch_country_household_consumption_factor_q16[country] =
                modifier_factor_q16(_modifier_runtime->effective_value(
                    ModifierRuntime::COUNTRY,
                    _country_household_consumption_stat_id,
                    country_handle, 0, 1.0));
            if (_country_population_death_stat_id >= 0)
                _epoch_country_death_factor_q16[country] =
                    modifier_factor_q16(_modifier_runtime->effective_value(
                        ModifierRuntime::COUNTRY,
                        _country_population_death_stat_id,
                        country_handle, 0, 1.0));
            _epoch_country_resource_global_use_factor_q16[country] =
                modifier_factor_q16(_modifier_runtime->effective_value(
                    ModifierRuntime::COUNTRY, _country_resource_use_stat_id,
                    country_handle, 0, 1.0));
            // R-4 metric 69 is filled AFTER this loop, see the single-pass block
            // below: computing it here would be O(countries x cells x cohorts) per
            // epoch, and this loop already runs once per country.
            for (size_t building = 0;
                 building < _country_building_output_stat_ids.size(); ++building) {
                _epoch_country_building_output_factor_q16[
                    static_cast<size_t>(country) *
                        _country_building_output_stat_ids.size() + building] =
                    modifier_factor_q16(_modifier_runtime->effective_value(
                        ModifierRuntime::COUNTRY,
                        _country_building_output_stat_ids[building], country_handle,
                        0, 1.0));
            }
            for (size_t climate = 0;
                 climate < _country_climate_loss_stat_ids.size(); ++climate) {
                _epoch_country_climate_loss_factor_q16[
                    static_cast<size_t>(country) * 4U + climate] =
                    modifier_factor_q16(_modifier_runtime->effective_value(
                        ModifierRuntime::COUNTRY,
                        _country_climate_loss_stat_ids[climate], country_handle,
                        0, 1.0));
            }
            const size_t profile_climate_count =
                _production_climate_profile_ids.size() * 4U;
            for (size_t profile_climate = 0;
                 profile_climate < profile_climate_count; ++profile_climate) {
                _epoch_country_climate_profile_loss_factor_q16[
                    static_cast<size_t>(country) * profile_climate_count +
                        profile_climate] =
                    modifier_factor_q16(_modifier_runtime->effective_value(
                        ModifierRuntime::COUNTRY,
                        _country_climate_profile_loss_stat_ids[profile_climate],
                        country_handle, 0, 1.0));
            }
            _epoch_country_trade_capacity_factor_q16[country] =
                modifier_factor_q16(
                    _modifier_runtime->country_trade_capacity_factor(
                        _epoch_country_handles[static_cast<size_t>(country)]));
            _epoch_country_trade_speed_factor_q16[country] =
                modifier_factor_q16(
                    _modifier_runtime->country_trade_speed_factor(
                        _epoch_country_handles[static_cast<size_t>(country)]));
            _epoch_country_construction_cost_factor_q16[country] =
                modifier_factor_q16(
                    _modifier_runtime->country_construction_cost_factor(
                        _epoch_country_handles[static_cast<size_t>(country)]));
            _epoch_country_construction_time_factor_q16[country] =
                modifier_factor_q16(
                    _modifier_runtime->country_construction_time_factor(
                        _epoch_country_handles[static_cast<size_t>(country)]));
        }
    }
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
    const auto cell_tax_compile_started = Clock::now();
    _epoch_cell_compiled_tax_policy.assign(
        static_cast<size_t>(_cell_count.get()), 0);
    _epoch_cell_active_tax_mask.assign(static_cast<size_t>(_cell_count.get()), 0);
    _epoch_cell_negative_tax_mask.assign(static_cast<size_t>(_cell_count.get()), 0);
    _epoch_cell_absolute_tax_mask.assign(static_cast<size_t>(_cell_count.get()), 0);
    _epoch_compiled_cell_tax_policies.assign(1, CompiledCellTaxPolicy{});
    _epoch_compiled_cell_tax_overrides.clear();
    _epoch_compiled_cell_tax_default_rows.clear();
    _epoch_compiled_cell_tax_default_rates.clear();
    _epoch_compiled_cell_tax_default_modes.clear();
    _epoch_has_cell_tax_policies = false;
    std::unordered_map<uint64_t, uint32_t> compiled_policy_ids;
    std::unordered_map<uint64_t, int32_t> default_row_ids;
    const auto item_count_for_kind = [&](int32_t kind) -> size_t {
        switch (kind) {
            case NativeCountryRuntime::TAX_INCOME:
                return _profession_ids.size();
            case NativeCountryRuntime::TAX_BUSINESS:
                return _building_types.size();
            case NativeCountryRuntime::TAX_CONSUMPTION:
            case NativeCountryRuntime::TAX_IMPORT:
            case NativeCountryRuntime::TAX_EXPORT:
                return _good_ids.size();
            default: return 0;
        }
    };
    const auto &stat_ids_for_kind = [&](int32_t kind)
            -> const std::vector<int32_t> & {
        switch (kind) {
            case NativeCountryRuntime::TAX_INCOME:
                return _income_tax_stat_ids;
            case NativeCountryRuntime::TAX_CONSUMPTION:
                return _consumption_tax_stat_ids;
            case NativeCountryRuntime::TAX_BUSINESS:
                return _business_tax_stat_ids;
            case NativeCountryRuntime::TAX_IMPORT:
                return _import_tax_stat_ids;
            case NativeCountryRuntime::TAX_EXPORT:
                return _export_tax_stat_ids;
            default: {
                static const std::vector<int32_t> empty;
                return empty;
            }
        }
    };
    const auto ensure_default_row = [&](int32_t country, int32_t kind,
                                        int32_t base_rate,
                                        int32_t base_mode) -> int32_t {
        const uint64_t key =
            (static_cast<uint64_t>(static_cast<uint32_t>(country)) << 40U) |
            (static_cast<uint64_t>(static_cast<uint8_t>(kind)) << 32U) |
            (static_cast<uint64_t>(static_cast<uint8_t>(base_mode & 0xff))
             << 24U) |
            static_cast<uint32_t>(base_rate);
        const auto found = default_row_ids.find(key);
        if (found != default_row_ids.end()) return found->second;
        const size_t item_count = item_count_for_kind(kind);
        CompiledCellTaxDefaultRow row;
        row.kind = kind;
        row.country = country;
        row.base_rate = base_rate;
        row.base_mode = base_mode;
        row.offset = static_cast<int32_t>(
            _epoch_compiled_cell_tax_default_rates.size());
        row.count = static_cast<int32_t>(item_count);
        _epoch_compiled_cell_tax_default_rates.resize(
            _epoch_compiled_cell_tax_default_rates.size() + item_count,
            base_rate);
        _epoch_compiled_cell_tax_default_modes.resize(
            _epoch_compiled_cell_tax_default_modes.size() + item_count,
            base_mode);
        if (_modifier_runtime != nullptr && item_count > 0 &&
            base_mode != NativeCountryRuntime::TAX_MODE_ABSOLUTE) {
            const auto &stat_ids = stat_ids_for_kind(kind);
            _modifier_runtime->effective_values(
                ModifierRuntime::COUNTRY, stat_ids.data(),
                _epoch_country_handles[static_cast<size_t>(country)],
                _epoch_compiled_cell_tax_default_rates.data() + row.offset,
                _epoch_compiled_cell_tax_default_rates.data() + row.offset,
                item_count);
        }
        const int32_t row_id = static_cast<int32_t>(
            _epoch_compiled_cell_tax_default_rows.size());
        _epoch_compiled_cell_tax_default_rows.push_back(row);
        default_row_ids.emplace(key, row_id);
        return row_id;
    };
    const std::vector<int32_t> &tax_cells = _economy_live_cells.empty()
        ? std::vector<int32_t>() : _economy_live_cells;
    const bool scan_all_tax_cells = tax_cells.empty();
    const int32_t tax_scan_count = scan_all_tax_cells
        ? _cell_count.get() : static_cast<int32_t>(tax_cells.size());
    for (int32_t i = 0; i < tax_scan_count; ++i) {
        const int32_t cell = scan_all_tax_cells ? i : tax_cells[static_cast<size_t>(i)];
        const uint32_t authority_id =
            snapshot_cell_tax_policy_ids[static_cast<size_t>(cell)];
        const int32_t country = _epoch_cell_country[static_cast<size_t>(cell)];
        if (authority_id == 0 ||
            authority_id >= snapshot_cell_tax_policies.size() ||
            country < 0 || country >= _epoch_country_count)
            continue;
        _epoch_has_cell_tax_policies = true;
        const uint64_t key =
            (static_cast<uint64_t>(static_cast<uint32_t>(country)) << 32U) |
            authority_id;
        auto compiled_found = compiled_policy_ids.find(key);
        if (compiled_found == compiled_policy_ids.end()) {
            const auto &authority = snapshot_cell_tax_policies[authority_id];
            CompiledCellTaxPolicy compiled;
            for (int32_t kind = 0;
                 kind < NativeCountryRuntime::TAX_KIND_COUNT; ++kind) {
                compiled.override_begin[static_cast<size_t>(kind)] =
                    static_cast<int32_t>(
                        _epoch_compiled_cell_tax_overrides.size());
                for (const auto &entry : authority.overrides) {
                    if (entry.kind != kind) continue;
                    int32_t effective = entry.rate;
                    const int32_t mode =
                        entry.mode == NativeCountryRuntime::TAX_MODE_INHERIT
                            ? NativeCountryRuntime::TAX_MODE_PERCENT_BP
                            : entry.mode;
                    if (_modifier_runtime != nullptr &&
                        mode != NativeCountryRuntime::TAX_MODE_ABSOLUTE) {
                        const auto &stat_ids = stat_ids_for_kind(kind);
                        _modifier_runtime->effective_values(
                            ModifierRuntime::COUNTRY,
                            stat_ids.data() + entry.item,
                            _epoch_country_handles[static_cast<size_t>(country)],
                            &effective, &effective, 1);
                    }
                    _epoch_compiled_cell_tax_overrides.push_back(
                        {entry.item, effective, mode});
                    if (effective != 0)
                        compiled.active_mask |= static_cast<uint8_t>(1U << kind);
                }
                compiled.override_end[static_cast<size_t>(kind)] =
                    static_cast<int32_t>(
                        _epoch_compiled_cell_tax_overrides.size());
                const int32_t local_default =
                    authority.defaults[static_cast<size_t>(kind)];
                const int32_t local_default_mode =
                    authority.default_modes[static_cast<size_t>(kind)];
                if (local_default != NativeCountryRuntime::TAX_RATE_INHERIT ||
                    local_default_mode !=
                        NativeCountryRuntime::TAX_MODE_INHERIT) {
                    const int32_t resolved_mode =
                        local_default_mode ==
                                NativeCountryRuntime::TAX_MODE_INHERIT
                            ? NativeCountryRuntime::TAX_MODE_PERCENT_BP
                            : local_default_mode;
                    const int32_t resolved_rate =
                        local_default == NativeCountryRuntime::TAX_RATE_INHERIT
                            ? 0
                            : local_default;
                    const int32_t row_id = ensure_default_row(
                        country, kind, resolved_rate, resolved_mode);
                    compiled.default_row_ids[static_cast<size_t>(kind)] = row_id;
                    const CompiledCellTaxDefaultRow &row =
                        _epoch_compiled_cell_tax_default_rows[
                            static_cast<size_t>(row_id)];
                    if (std::any_of(
                            _epoch_compiled_cell_tax_default_rates.begin() +
                                row.offset,
                            _epoch_compiled_cell_tax_default_rates.begin() +
                                row.offset + row.count,
                            [](int32_t rate) { return rate != 0; })) {
                        compiled.active_mask |=
                            static_cast<uint8_t>(1U << kind);
                    }
                }
            }
            compiled.active_mask = 0;
            compiled.negative_mask = 0;
            compiled.absolute_mask = 0;
            const auto national_rates_for_kind = [&](int32_t kind)
                    -> const std::vector<int32_t> & {
                switch (kind) {
                    case NativeCountryRuntime::TAX_INCOME:
                        return _epoch_income_tax_rates;
                    case NativeCountryRuntime::TAX_CONSUMPTION:
                        return _epoch_consumption_tax_rates;
                    case NativeCountryRuntime::TAX_BUSINESS:
                        return _epoch_business_tax_rates;
                    case NativeCountryRuntime::TAX_IMPORT:
                        return _epoch_import_tax_rates;
                    default: return _epoch_export_tax_rates;
                    }
            };
            const auto national_modes_for_kind = [&](int32_t kind)
                    -> const std::vector<int32_t> & {
                switch (kind) {
                    case NativeCountryRuntime::TAX_INCOME:
                        return _epoch_income_tax_modes;
                    case NativeCountryRuntime::TAX_CONSUMPTION:
                        return _epoch_consumption_tax_modes;
                    case NativeCountryRuntime::TAX_BUSINESS:
                        return _epoch_business_tax_modes;
                    case NativeCountryRuntime::TAX_IMPORT:
                        return _epoch_import_tax_modes;
                    default: return _epoch_export_tax_modes;
                }
            };
            for (int32_t kind = 0;
                 kind < NativeCountryRuntime::TAX_KIND_COUNT; ++kind) {
                const size_t item_count = item_count_for_kind(kind);
                const auto &national = national_rates_for_kind(kind);
                const auto &national_modes = national_modes_for_kind(kind);
                int32_t override_cursor =
                    compiled.override_begin[static_cast<size_t>(kind)];
                const int32_t override_end =
                    compiled.override_end[static_cast<size_t>(kind)];
                const int32_t row_id =
                    compiled.default_row_ids[static_cast<size_t>(kind)];
                for (int32_t item = 0;
                     item < static_cast<int32_t>(item_count); ++item) {
                    int32_t rate = 0;
                    int32_t mode = NativeCountryRuntime::TAX_MODE_PERCENT_BP;
                    while (override_cursor < override_end &&
                           _epoch_compiled_cell_tax_overrides[
                               static_cast<size_t>(override_cursor)].item < item)
                        ++override_cursor;
                    if (override_cursor < override_end &&
                        _epoch_compiled_cell_tax_overrides[
                               static_cast<size_t>(override_cursor)].item == item) {
                        const CompiledCellTaxOverride &entry =
                            _epoch_compiled_cell_tax_overrides[
                                static_cast<size_t>(override_cursor)];
                        rate = entry.rate;
                        mode = entry.mode;
                    } else if (row_id >= 0) {
                        const CompiledCellTaxDefaultRow &row =
                            _epoch_compiled_cell_tax_default_rows[
                                static_cast<size_t>(row_id)];
                        rate = _epoch_compiled_cell_tax_default_rates[
                            static_cast<size_t>(row.offset + item)];
                        mode = _epoch_compiled_cell_tax_default_modes[
                            static_cast<size_t>(row.offset + item)];
                    } else {
                        rate = national[
                            static_cast<size_t>(country) * item_count +
                            static_cast<size_t>(item)];
                        mode = national_modes[
                            static_cast<size_t>(country) * item_count +
                            static_cast<size_t>(item)];
                    }
                    if (rate != 0) {
                        compiled.active_mask |=
                            static_cast<uint8_t>(1U << kind);
                        if (rate < 0)
                            compiled.negative_mask |=
                                static_cast<uint8_t>(1U << kind);
                        if (mode == NativeCountryRuntime::TAX_MODE_ABSOLUTE)
                            compiled.absolute_mask |=
                                static_cast<uint8_t>(1U << kind);
                    }
                }
            }
            const uint32_t compiled_id = static_cast<uint32_t>(
                _epoch_compiled_cell_tax_policies.size());
            _epoch_compiled_cell_tax_policies.push_back(compiled);
            compiled_policy_ids.emplace(key, compiled_id);
            compiled_found = compiled_policy_ids.find(key);
        }
        _epoch_cell_compiled_tax_policy[static_cast<size_t>(cell)] =
            compiled_found->second;
    }
    const size_t country_count = static_cast<size_t>(
        std::max(0, _epoch_country_count));
    std::vector<uint8_t> country_tax_masks(country_count, 0);
    std::vector<uint8_t> country_negative_tax_masks(country_count, 0);
    std::vector<uint8_t> country_absolute_tax_masks(country_count, 0);
    const auto mark_country_tax = [&](int32_t kind,
                                      const std::vector<int32_t> &rates,
                                      const std::vector<int32_t> &modes,
                                      size_t item_count) {
        for (int32_t country = 0; country < _epoch_country_count; ++country) {
            const size_t offset = static_cast<size_t>(country) * item_count;
            for (size_t item = 0; item < item_count; ++item) {
                const int32_t rate = rates[offset + item];
                if (rate == 0) continue;
                const uint8_t bit = static_cast<uint8_t>(1U << kind);
                country_tax_masks[static_cast<size_t>(country)] |= bit;
                if (rate < 0)
                    country_negative_tax_masks[static_cast<size_t>(country)] |= bit;
                if (modes[offset + item] == NativeCountryRuntime::TAX_MODE_ABSOLUTE)
                    country_absolute_tax_masks[static_cast<size_t>(country)] |= bit;
            }
        }
    };
    mark_country_tax(NativeCountryRuntime::TAX_INCOME,
                     _epoch_income_tax_rates, _epoch_income_tax_modes,
                     _profession_ids.size());
    mark_country_tax(NativeCountryRuntime::TAX_CONSUMPTION,
                     _epoch_consumption_tax_rates, _epoch_consumption_tax_modes,
                     _good_ids.size());
    mark_country_tax(NativeCountryRuntime::TAX_BUSINESS,
                     _epoch_business_tax_rates, _epoch_business_tax_modes,
                     _building_types.size());
    mark_country_tax(NativeCountryRuntime::TAX_IMPORT,
                     _epoch_import_tax_rates, _epoch_import_tax_modes,
                     _good_ids.size());
    mark_country_tax(NativeCountryRuntime::TAX_EXPORT,
                     _epoch_export_tax_rates, _epoch_export_tax_modes,
                     _good_ids.size());
    _epoch_active_tax_mask = 0;
    _epoch_negative_tax_mask = 0;
    _epoch_absolute_tax_mask = 0;
    const std::vector<int32_t> &tax_mask_cells = _economy_live_cells.empty()
        ? std::vector<int32_t>() : _economy_live_cells;
    const bool mask_all_cells = tax_mask_cells.empty();
    const int32_t tax_mask_count = mask_all_cells
        ? _cell_count.get() : static_cast<int32_t>(tax_mask_cells.size());
    for (int32_t i = 0; i < tax_mask_count; ++i) {
        const int32_t cell = mask_all_cells ? i : tax_mask_cells[static_cast<size_t>(i)];
        const int32_t country = _epoch_cell_country[static_cast<size_t>(cell)];
        uint8_t mask = 0;
        const uint32_t compiled_id =
            _epoch_cell_compiled_tax_policy[static_cast<size_t>(cell)];
        uint8_t negative_mask = 0;
        uint8_t absolute_mask = 0;
        if (compiled_id > 0 &&
            compiled_id < _epoch_compiled_cell_tax_policies.size()) {
            mask = _epoch_compiled_cell_tax_policies[compiled_id].active_mask;
            negative_mask = _epoch_compiled_cell_tax_policies[compiled_id].negative_mask;
            absolute_mask = _epoch_compiled_cell_tax_policies[compiled_id].absolute_mask;
        } else if (country >= 0 && country < _epoch_country_count) {
            mask = country_tax_masks[static_cast<size_t>(country)];
            negative_mask = country_negative_tax_masks[static_cast<size_t>(country)];
            absolute_mask = country_absolute_tax_masks[static_cast<size_t>(country)];
        }
        _epoch_cell_active_tax_mask[static_cast<size_t>(cell)] = mask;
        _epoch_cell_negative_tax_mask[static_cast<size_t>(cell)] = negative_mask;
        _epoch_cell_absolute_tax_mask[static_cast<size_t>(cell)] = absolute_mask;
        _epoch_active_tax_mask |= mask;
        _epoch_negative_tax_mask |= negative_mask;
        _epoch_absolute_tax_mask |= absolute_mask;
    }
    _epoch_cell_tax_cache_bytes = static_cast<int64_t>(
        _epoch_cell_compiled_tax_policy.size() * sizeof(uint32_t) +
        _epoch_cell_active_tax_mask.size() * sizeof(uint8_t) +
        _epoch_cell_negative_tax_mask.size() * sizeof(uint8_t) +
        _epoch_cell_absolute_tax_mask.size() * sizeof(uint8_t) +
        _epoch_compiled_cell_tax_policies.size() *
            sizeof(CompiledCellTaxPolicy) +
        _epoch_compiled_cell_tax_overrides.size() *
            sizeof(CompiledCellTaxOverride) +
        _epoch_compiled_cell_tax_default_rows.size() *
            sizeof(CompiledCellTaxDefaultRow) +
        _epoch_compiled_cell_tax_default_rates.size() * sizeof(int32_t));
    _epoch_cell_tax_compile_ms = elapsed_ms(cell_tax_compile_started);
    const auto building_factor_started = Clock::now();
    refresh_building_modifier_factors();
    _epoch_begin_building_factor_ms = elapsed_ms(building_factor_started);
    refresh_epoch_development();
    return true;
}

} // namespace pk
