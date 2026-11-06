#include "economy_cost_probe.h"
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

void NativeEconomyRuntime::rebuild_building_handle_index() const {
    _building_handle_index.clear();
    _building_handle_index.reserve(building_count() * 2 + 1);
    // Reverse order so the surviving entry matches the lowest index, which is
    // what the previous forward linear scan returned for duplicate handles.
    for (int32_t i = static_cast<int32_t>(building_count()) - 1; i >= 0; --i)
        if (buildings_store().group_units[i] > 0 && buildings_store().modifier_handle[i] != 0)
            _building_handle_index[buildings_store().modifier_handle[i]] = i;
    _building_handle_index_stamp = building_count();
    _building_handle_index_clean = true;
}

const std::unordered_map<uint64_t, int32_t> &
NativeEconomyRuntime::building_handle_index() const {
    if (_building_handle_index_stamp != building_count())
        _building_handle_index_clean = false;
    if (!_building_handle_index_clean) rebuild_building_handle_index();
    return _building_handle_index;
}

int32_t NativeEconomyRuntime::building_index_for_handle(
        uint64_t building_handle) const {
    if (building_handle == 0) return -1;
    building_handle_index();
    auto it = _building_handle_index.find(building_handle);
    if (it != _building_handle_index.end()) {
        const int32_t index = it->second;
        if (index >= 0 && index < static_cast<int32_t>(building_count()) &&
            buildings_store().group_units[index] > 0 &&
            buildings_store().modifier_handle[index] == building_handle) return index;
        rebuild_building_handle_index();
        it = _building_handle_index.find(building_handle);
        return it == _building_handle_index.end() ? -1 : it->second;
    }
    return -1;
}

int32_t NativeEconomyRuntime::roll_core_family_traits(
        uint64_t stable_id, int32_t tech_cell, int32_t origin_cell,
        std::vector<int32_t> &selected, std::vector<int32_t> &strengths) const {
    selected.clear();
    strengths.clear();
    if (_family_trait_ids.empty()) return 0;
    uint64_t rng = 1469598103934665603ULL;
    rng = trace_hash_mix(rng, static_cast<uint64_t>(_seed.get()));
    rng = trace_hash_mix(rng, stable_id);
    rng = trace_hash_mix(rng, static_cast<uint32_t>(
        _family_trait_catalog_version.get()));
    const int32_t span = _family_core_trait_max - _family_core_trait_min + 1;
    const int32_t desired = _family_core_trait_min + static_cast<int32_t>(
        trace_hash_mix(rng, 0x434f554e54ULL) %
        static_cast<uint64_t>(std::max(1, span)));
    selected.reserve(desired);
    strengths.reserve(desired);
    for (int32_t pick = 0; pick < desired; ++pick) {
        std::vector<int32_t> candidates;
        int64_t total_weight = 0;
        for (int32_t trait_id = 0; trait_id < static_cast<int32_t>(
                _family_trait_ids.size()); ++trait_id) {
            if (_family_trait_core_eligible[trait_id] == 0 ||
                std::find(selected.begin(), selected.end(), trait_id) !=
                    selected.end()) continue;
            bool allowed = true;
            for (int32_t p = _family_trait_prerequisite_offsets[trait_id];
                 p < _family_trait_prerequisite_offsets[trait_id + 1]; ++p)
                allowed = allowed && std::find(selected.begin(), selected.end(),
                    _family_trait_prerequisites[p]) != selected.end();
            for (int32_t p = _family_trait_exclusion_offsets[trait_id];
                 allowed && p < _family_trait_exclusion_offsets[trait_id + 1]; ++p)
                allowed = std::find(selected.begin(), selected.end(),
                    _family_trait_exclusions[p]) == selected.end();
            for (int32_t chosen : selected) {
                for (int32_t p = _family_trait_exclusion_offsets[chosen];
                     allowed && p < _family_trait_exclusion_offsets[chosen + 1]; ++p)
                    allowed = _family_trait_exclusions[p] != trait_id;
            }
            allowed = allowed &&
                family_trait_technology_unlocked(trait_id, tech_cell) &&
                family_trait_origin_gates_allow(trait_id, origin_cell);
            if (!allowed) continue;
            candidates.push_back(trait_id);
            total_weight += _family_trait_weights[trait_id];
        }
        if (candidates.empty() || total_weight <= 0) break;
        int64_t roll = static_cast<int64_t>(trace_hash_mix(
            rng, 0x5049434bULL + static_cast<uint64_t>(pick)) %
            static_cast<uint64_t>(total_weight));
        int32_t chosen = candidates.back();
        for (int32_t candidate : candidates) {
            if (roll < _family_trait_weights[candidate]) {
                chosen = candidate;
                break;
            }
            roll -= _family_trait_weights[candidate];
        }
        selected.push_back(chosen);
        const int32_t lo = _family_trait_strength_min_q16[chosen];
        const int32_t hi = _family_trait_strength_max_q16[chosen];
        const int32_t step = _family_trait_strength_step_q16[chosen];
        const int32_t steps = std::max(0, (hi - lo) / step);
        const int32_t strength = lo + step * static_cast<int32_t>(
            trace_hash_mix(rng, 0x535452454e475448ULL +
                static_cast<uint64_t>(pick)) %
            static_cast<uint64_t>(steps + 1));
        strengths.push_back(strength);
    }
    return static_cast<int32_t>(selected.size());
}

bool NativeEconomyRuntime::track_b_aggregate_hash_reuse(int64_t day,
                                                       uint64_t &cached_hash) {
    static const bool track_b_enabled = [] {
        const char *value = pk::runtime_switch_value(pk::RuntimeSwitch::PK_ECONOMY_TRACK_B);
        return !(value && std::strcmp(value, "0") == 0);
    }();
    static const int32_t hash_cadence = [] {
        const char *value = pk::runtime_switch_value(pk::RuntimeSwitch::PK_ECONOMY_TRACK_B_HASH_CADENCE);
        const int32_t parsed = value ? std::atoi(value) : 0;
        return parsed > 0 ? std::min<int32_t>(parsed, 30) : 8;
    }();
    static const int32_t hash_offset = [] {
        const char *value = pk::runtime_switch_value(pk::RuntimeSwitch::PK_ECONOMY_TRACK_B_HASH_OFFSET);
        const int32_t parsed = value ? std::atoi(value) : 0;
        return parsed != 0 ? std::abs(parsed) : 2;
    }();
    if (!track_b_enabled || hash_cadence <= 1) return false;
    if (_track_b_hash_last_day != day - 1) return false;
    if (_track_b_hash_last_value == 0) return false;
    const int32_t hash_phase =
        static_cast<int32_t>(((day - hash_offset) % hash_cadence +
            hash_cadence) % hash_cadence);
    if (hash_phase == 0) return false;
    cached_hash = _track_b_hash_last_value;
    _track_b_hash_last_day = day;
    EconomyCostProbe::record("dispatch.track_b_hash_reuse", day, 0.0, 1u);
    return true;
}

void NativeEconomyRuntime::track_b_aggregate_hash_store(int64_t day,
                                                        uint64_t hash) {
    _track_b_hash_last_day = day;
    _track_b_hash_last_value = hash;
}

void NativeEconomyRuntime::mark_family_behavior_cache_dirty(uint32_t reason) {
    _family_behavior_cache_dirty = true;
    _family_behavior_cache_dirty_reasons |= reason;
}

void NativeEconomyRuntime::ensure_family_policy_factors() {
    const size_t n = families_store().active.size();
    if (_family_purchase_factor_q16.size() < n)
        _family_purchase_factor_q16.resize(n, Q16_ONE);
    if (_family_investment_factor_q16.size() < n)
        _family_investment_factor_q16.resize(n, Q16_ONE);
    if (_family_birth_factor_q16.size() < n)
        _family_birth_factor_q16.resize(n, Q16_ONE);
    if (_family_absorb_bonus_q16.size() < n)
        _family_absorb_bonus_q16.resize(n, 0);
    if (_family_colonization_population_reward.size() < n)
        _family_colonization_population_reward.resize(n, 0);
}

void NativeEconomyRuntime::reset_family_policy_factors(int32_t family_index) {
    ensure_family_policy_factors();
    if (family_index < 0 || family_index >= static_cast<int32_t>(
            _family_purchase_factor_q16.size()))
        return;
    _family_purchase_factor_q16[static_cast<size_t>(family_index)] = Q16_ONE;
    if (family_index < static_cast<int32_t>(_family_investment_factor_q16.size()))
        _family_investment_factor_q16[static_cast<size_t>(family_index)] = Q16_ONE;
    if (family_index < static_cast<int32_t>(_family_birth_factor_q16.size()))
        _family_birth_factor_q16[static_cast<size_t>(family_index)] = Q16_ONE;
    if (family_index < static_cast<int32_t>(_family_absorb_bonus_q16.size()))
        _family_absorb_bonus_q16[static_cast<size_t>(family_index)] = 0;
    if (family_index < static_cast<int32_t>(
            _family_colonization_population_reward.size()))
        _family_colonization_population_reward[static_cast<size_t>(family_index)] = 0;
}

int32_t NativeEconomyRuntime::family_colonization_population_reward_amount(
        uint64_t family_handle) const {
    int32_t family = -1;
    if (!families_store().valid_handle(family_handle, family) || family < 0 ||
        family >= static_cast<int32_t>(_family_colonization_population_reward.size()))
        return 0;
    return std::max(0, _family_colonization_population_reward[
        static_cast<size_t>(family)]);
}

bool NativeEconomyRuntime::family_trait_technology_unlocked(
        int32_t trait_id, int32_t cell) const {
    if (trait_id < 0 || trait_id >= static_cast<int32_t>(
            _family_trait_technology_prerequisite_offsets.size()) - 1)
        return true;
    const int32_t begin = _family_trait_technology_prerequisite_offsets[
        static_cast<size_t>(trait_id)];
    const int32_t end = _family_trait_technology_prerequisite_offsets[
        static_cast<size_t>(trait_id) + 1];
    if (begin >= end)
        return true;
    const uint8_t match_any =
        trait_id < static_cast<int32_t>(_family_trait_technology_match_any.size())
            ? _family_trait_technology_match_any[static_cast<size_t>(trait_id)]
            : 0;
    if (match_any != 0)
        return cell_has_requirements(cell, begin, end,
            _family_trait_technology_prerequisites, true);
    return cell_has_all_requirements(cell, begin, end,
        _family_trait_technology_prerequisites, true);
}

bool NativeEconomyRuntime::family_effect_technology_unlocked(
        int32_t effect_id, int32_t cell) const {
    if (effect_id < 0 || effect_id >= static_cast<int32_t>(
            _family_effect_prerequisite_offsets.size()) - 1)
        return true;
    const int32_t begin = _family_effect_prerequisite_offsets[
        static_cast<size_t>(effect_id)];
    const int32_t end = _family_effect_prerequisite_offsets[
        static_cast<size_t>(effect_id) + 1];
    if (begin >= end)
        return true;
    const uint8_t match_any =
        effect_id < static_cast<int32_t>(_family_effect_technology_match_any.size())
            ? _family_effect_technology_match_any[static_cast<size_t>(effect_id)]
            : 0;
    if (match_any != 0)
        return cell_has_requirements(cell, begin, end,
            _family_effect_prerequisites, true);
    return cell_has_all_requirements(cell, begin, end,
        _family_effect_prerequisites, true);
}

bool NativeEconomyRuntime::family_trait_origin_gates_allow(
        int32_t trait_id, int32_t origin_cell) const {
    if (trait_id < 0) return true;
    const size_t count = _family_trait_ids.size();
    if (static_cast<size_t>(trait_id) >= count) return true;
    auto needs_place = [&]() -> bool {
        const bool landform = trait_id + 1 < static_cast<int32_t>(
                _family_trait_origin_landform_offsets.size()) &&
            _family_trait_origin_landform_offsets[trait_id] <
                _family_trait_origin_landform_offsets[trait_id + 1];
        const bool water = trait_id < static_cast<int32_t>(
                _family_trait_origin_adjacent_water.size()) &&
            _family_trait_origin_adjacent_water[trait_id] != 0;
        const bool population = trait_id < static_cast<int32_t>(
                _family_trait_origin_population_max.size()) &&
            _family_trait_origin_population_max[trait_id] > 0;
        const bool temperature = trait_id < static_cast<int32_t>(
                _family_trait_origin_temperature_max_q16.size()) &&
            _family_trait_origin_temperature_max_q16[trait_id] >= 0;
        const bool resource = trait_id + 1 < static_cast<int32_t>(
                _family_trait_required_resource_offsets.size()) &&
            _family_trait_required_resource_offsets[trait_id] <
                _family_trait_required_resource_offsets[trait_id + 1];
        const bool tax = trait_id < static_cast<int32_t>(
                _family_trait_require_tax_or_subsidy.size()) &&
            _family_trait_require_tax_or_subsidy[trait_id] != 0;
        return landform || water || population || temperature || resource || tax;
    };
    if (origin_cell < 0 || origin_cell >= _cell_count.get())
        return !needs_place();
    if (trait_id + 1 < static_cast<int32_t>(
            _family_trait_origin_landform_offsets.size())) {
        const int32_t begin = _family_trait_origin_landform_offsets[trait_id];
        const int32_t end = _family_trait_origin_landform_offsets[trait_id + 1];
        if (begin < end) {
            const int32_t landform = origin_cell < static_cast<int32_t>(
                    _building_landform.size())
                ? _building_landform[static_cast<size_t>(origin_cell)] : -1;
            bool matched = false;
            for (int32_t i = begin; i < end; ++i) {
                if (static_cast<int32_t>(_family_trait_origin_landforms[
                        static_cast<size_t>(i)]) == landform) {
                    matched = true;
                    break;
                }
            }
            if (!matched) return false;
        }
    }
    if (trait_id < static_cast<int32_t>(
            _family_trait_origin_adjacent_water.size()) &&
        _family_trait_origin_adjacent_water[trait_id] != 0) {
        constexpr int32_t kLandformDelta = 9;
        const int32_t landform = origin_cell < static_cast<int32_t>(
                _building_landform.size())
            ? _building_landform[static_cast<size_t>(origin_cell)] : -1;
        bool wet = landform == kLandformDelta;
        if (!wet && _building_neighbors.size() ==
                static_cast<size_t>(_cell_count.get()) * 6 &&
            _building_is_water.size() == static_cast<size_t>(_cell_count.get())) {
            for (int32_t dir = 0; dir < 6 && !wet; ++dir) {
                const int32_t neighbor = _building_neighbors[
                    static_cast<size_t>(origin_cell) * 6 + dir];
                if (neighbor >= 0 && neighbor < _cell_count.get() &&
                    _building_is_water[static_cast<size_t>(neighbor)] != 0)
                    wet = true;
            }
        }
        if (!wet) return false;
    }
    if (trait_id < static_cast<int32_t>(
            _family_trait_origin_population_max.size()) &&
        _family_trait_origin_population_max[trait_id] > 0) {
        const int64_t population = origin_cell < static_cast<int32_t>(
                _committed_cells.size())
            ? _committed_cells[static_cast<size_t>(origin_cell)].population : 0;
        if (population > _family_trait_origin_population_max[trait_id])
            return false;
    }
    if (trait_id < static_cast<int32_t>(
            _family_trait_origin_temperature_max_q16.size()) &&
        _family_trait_origin_temperature_max_q16[trait_id] >= 0) {
        const int32_t temperature = origin_cell < static_cast<int32_t>(
                _environment_temperature_q16.size())
            ? _environment_temperature_q16[static_cast<size_t>(origin_cell)]
            : Q16_ONE;
        if (temperature > _family_trait_origin_temperature_max_q16[trait_id])
            return false;
    }
    if (trait_id + 1 < static_cast<int32_t>(
            _family_trait_required_resource_offsets.size())) {
        const int32_t begin = _family_trait_required_resource_offsets[trait_id];
        const int32_t end = _family_trait_required_resource_offsets[trait_id + 1];
        if (begin < end) {
            bool found = false;
            for (int32_t i = begin; i < end; ++i) {
                const int32_t resource_id = _family_trait_required_resource_ids[
                    static_cast<size_t>(i)];
                if (carrying_resource_stock(resource_id, origin_cell) > 0) {
                    found = true;
                    break;
                }
                const size_t idx = static_cast<size_t>(std::max(0, resource_id)) *
                    static_cast<size_t>(_cell_count.get()) +
                    static_cast<size_t>(origin_cell);
                if (resource_id >= 0 && idx < resource_stock_lanes().size() &&
                    resource_stock_lanes()[idx] > 0) {
                    found = true;
                    break;
                }
            }
            if (!found) return false;
        }
    }
    if (trait_id < static_cast<int32_t>(
            _family_trait_require_tax_or_subsidy.size()) &&
        _family_trait_require_tax_or_subsidy[trait_id] != 0) {
        const bool cell_tax = origin_cell < static_cast<int32_t>(
                _epoch_cell_active_tax_mask.size()) &&
            _epoch_cell_active_tax_mask[static_cast<size_t>(origin_cell)] != 0;
        bool country_tax = _epoch_active_tax_mask != 0;
        if (!cell_tax && !country_tax) {
            for (int32_t rate : _epoch_business_tax_rates) {
                if (rate != 0) {
                    country_tax = true;
                    break;
                }
            }
        }
        if (!cell_tax && !country_tax) return false;
    }
    return true;
}

bool NativeEconomyRuntime::family_trait_context_allows(
        int32_t trait_id, int32_t family_index) const {
    if (family_index < 0 || family_index >= static_cast<int32_t>(
            families_store().active.size()) || families_store().active[family_index] == 0)
        return false;
    const int32_t origin = families_store().origin_cell[family_index];
    const int32_t home = families_store().home_cell[family_index];
    const int32_t tech_cell = origin >= 0 && origin < _cell_count.get() ? origin : home;
    const int32_t origin_cell = origin >= 0 && origin < _cell_count.get()
        ? origin : tech_cell;
    return family_trait_technology_unlocked(trait_id, tech_cell) &&
        family_trait_origin_gates_allow(trait_id, origin_cell);
}

} // namespace pk
