#include "economy_runtime.h"
#include "economy_runtime_variant_helpers.h"

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <limits>
#include <numeric>
#include <unordered_set>

#include <godot_cpp/variant/packed_byte_array.hpp>
#include <godot_cpp/variant/string_name.hpp>
#include <godot_cpp/variant/variant.hpp>

namespace pk {
EconomyFamilyCellInfluenceStore::EconomyFamilyCellInfluenceStore()
    : active(changes, {{7, 1}, "influence.active", EconomyFieldEncoding::U8, 1}),
      generation(changes, {{7, 2}, "influence.generation", EconomyFieldEncoding::U32, 4}),
      family_handle(changes, {{7, 3}, "influence.family_handle", EconomyFieldEncoding::U64, 8}),
      cell(changes, {{7, 4}, "influence.cell", EconomyFieldEncoding::I32, 4}),
      stable_id(changes, {{7, 5}, "influence.stable_id", EconomyFieldEncoding::I64, 8}),
      population(changes, {{7, 6}, "influence.population", EconomyFieldEncoding::I64, 8}),
      cash(changes, {{7, 7}, "influence.cash", EconomyFieldEncoding::I64, 8}),
      building_asset(changes, {{7, 8}, "influence.building_asset", EconomyFieldEncoding::I64, 8}),
      population_share_q16(changes, {{7, 9}, "influence.population_share_q16", EconomyFieldEncoding::I32, 4}),
      cash_share_q16(changes, {{7, 10}, "influence.cash_share_q16", EconomyFieldEncoding::I32, 4}),
      building_share_q16(changes, {{7, 11}, "influence.building_share_q16", EconomyFieldEncoding::I32, 4}),
      score_q16(changes, {{7, 12}, "influence.score_q16", EconomyFieldEncoding::I32, 4}),
      satisfaction_q16(changes, {{7, 13}, "influence.satisfaction_q16", EconomyFieldEncoding::I32, 4}),
      prestige_level(changes, {{7, 14}, "influence.prestige_level", EconomyFieldEncoding::U8, 1}),
      pending_target_level(changes, {{7, 15}, "influence.pending_target_level", EconomyFieldEncoding::U8, 1}),
      review_streak(changes, {{7, 16}, "influence.review_streak", EconomyFieldEncoding::U8, 1}),
      last_review_day(changes, {{7, 17}, "influence.last_review_day", EconomyFieldEncoding::I64, 8}),
      free_indices(changes, {{7, 18}, "influence.free_indices", EconomyFieldEncoding::U32, 4}) {}
EconomyFamilyCellInfluenceStore::EconomyFamilyCellInfluenceStore(const EconomyFamilyCellInfluenceStore &other)
    : EconomyFamilyCellInfluenceStore() { *this = other; }
EconomyFamilyCellInfluenceStore &EconomyFamilyCellInfluenceStore::operator=(const EconomyFamilyCellInfluenceStore &other) {
    if (this == &other) return *this;
    active.assign(other.active.values());
    generation.assign(other.generation.values());
    family_handle.assign(other.family_handle.values());
    cell.assign(other.cell.values());
    stable_id.assign(other.stable_id.values());
    population.assign(other.population.values());
    cash.assign(other.cash.values());
    building_asset.assign(other.building_asset.values());
    population_share_q16.assign(other.population_share_q16.values());
    cash_share_q16.assign(other.cash_share_q16.values());
    building_share_q16.assign(other.building_share_q16.values());
    score_q16.assign(other.score_q16.values());
    satisfaction_q16.assign(other.satisfaction_q16.values());
    prestige_level.assign(other.prestige_level.values());
    pending_target_level.assign(other.pending_target_level.values());
    review_streak.assign(other.review_streak.values());
    last_review_day.assign(other.last_review_day.values());
    free_indices.assign(other.free_indices.values());
    return *this;
}
EconomyFamilyCellInfluenceStore::EconomyFamilyCellInfluenceStore(EconomyFamilyCellInfluenceStore &&other)
    : EconomyFamilyCellInfluenceStore() { *this = std::move(other); }
EconomyFamilyCellInfluenceStore &EconomyFamilyCellInfluenceStore::operator=(EconomyFamilyCellInfluenceStore &&other) {
    if (this == &other) return *this;
    active.move_from(other.active);
    generation.move_from(other.generation);
    family_handle.move_from(other.family_handle);
    cell.move_from(other.cell);
    stable_id.move_from(other.stable_id);
    population.move_from(other.population);
    cash.move_from(other.cash);
    building_asset.move_from(other.building_asset);
    population_share_q16.move_from(other.population_share_q16);
    cash_share_q16.move_from(other.cash_share_q16);
    building_share_q16.move_from(other.building_share_q16);
    score_q16.move_from(other.score_q16);
    satisfaction_q16.move_from(other.satisfaction_q16);
    prestige_level.move_from(other.prestige_level);
    pending_target_level.move_from(other.pending_target_level);
    review_streak.move_from(other.review_streak);
    last_review_day.move_from(other.last_review_day);
    free_indices.move_from(other.free_indices);
    return *this;
}

using namespace godot;
using namespace variant_helpers;

namespace {
std::vector<uint8_t> economy_packed_u8(const Dictionary &d, const char *key) {
    std::vector<uint8_t> out;
    const StringName k(key);
    if (!d.has(k) || d[k].get_type() != Variant::PACKED_BYTE_ARRAY) return out;
    const PackedByteArray src = d[k];
    out.resize(src.size());
    if (!out.empty()) std::memcpy(out.data(), src.ptr(), out.size());
    return out;
}
} // namespace

bool NativeEconomyRuntime::compile_family_trait_catalog(
        const Dictionary &catalog, std::string &error) {
    _family_trait_catalog_version = dict_num<int32_t>(
        catalog, "family_trait_catalog_version", 0);
    _family_trait_catalog_hash = dict_num<int64_t>(
        catalog, "family_trait_catalog_hash", 0);
    _family_core_trait_min = dict_num<int32_t>(
        catalog, "family_core_trait_min", 0);
    _family_core_trait_max = dict_num<int32_t>(
        catalog, "family_core_trait_max", 0);
    _family_trait_ids = packed_strings(catalog, "family_trait_ids");
    _family_trait_display_names = packed_strings(
        catalog, "family_trait_display_names");
    _family_trait_weights = packed_i32(catalog, "family_trait_weights");
    _family_trait_core_eligible = economy_packed_u8(
        catalog, "family_trait_core_eligible");
    _family_trait_strength_min_q16 = packed_i32(
        catalog, "family_trait_strength_min_q16");
    _family_trait_strength_max_q16 = packed_i32(
        catalog, "family_trait_strength_max_q16");
    _family_trait_strength_step_q16 = packed_i32(
        catalog, "family_trait_strength_step_q16");
    _family_trait_prerequisite_offsets = packed_i32(
        catalog, "family_trait_prerequisite_offsets");
    _family_trait_prerequisites = packed_i32(
        catalog, "family_trait_prerequisites");
    _family_trait_exclusion_offsets = packed_i32(
        catalog, "family_trait_exclusion_offsets");
    _family_trait_exclusions = packed_i32(
        catalog, "family_trait_exclusions");
    _family_trait_technology_prerequisite_offsets = packed_i32(
        catalog, "family_trait_technology_prerequisite_offsets");
    _family_trait_technology_prerequisites = packed_i32(
        catalog, "family_trait_technology_prerequisites");
    _family_trait_technology_match_any = economy_packed_u8(
        catalog, "family_trait_technology_match_any");
    _family_trait_behavior_offsets = packed_i32(
        catalog, "family_trait_behavior_offsets");
    _family_trait_behavior_axes = packed_i32(
        catalog, "family_trait_behavior_axes");
    _family_trait_behavior_selector_kinds = packed_i32(
        catalog, "family_trait_behavior_selector_kinds");
    _family_trait_behavior_selector_ids = packed_i32(
        catalog, "family_trait_behavior_selector_ids");
    _family_trait_behavior_factors_q16 = packed_i32(
        catalog, "family_trait_behavior_factors_q16");
    _family_trait_behavior_score_terms = packed_i32(
        catalog, "family_trait_behavior_score_terms");
    _family_trait_behavior_condition_offsets = packed_i32(
        catalog, "family_trait_behavior_condition_offsets");
    _family_trait_behavior_condition_ops = packed_i32(
        catalog, "family_trait_behavior_condition_ops");
    _family_trait_behavior_condition_arg0 = packed_i32(
        catalog, "family_trait_behavior_condition_arg0");
    _family_trait_behavior_condition_values = packed_i64(
        catalog, "family_trait_behavior_condition_values");
    _family_trait_modifier_offsets = packed_i32(
        catalog, "family_trait_modifier_offsets");
    _family_trait_modifier_definition_keys = packed_strings(
        catalog, "family_trait_modifier_definition_keys");
    _family_trait_modifier_targets = packed_i32(
        catalog, "family_trait_modifier_targets");
    _family_trait_modifier_tier_magnitudes_q16 = packed_i32(
        catalog, "family_trait_modifier_tier_magnitudes_q16");
    _family_trait_trigger_offsets = packed_i32(
        catalog, "family_trait_trigger_offsets");
    _family_trait_trigger_definition_keys_by_tier = packed_strings(
        catalog, "family_trait_trigger_definition_keys_by_tier");
    _family_trait_trigger_reward_targets = packed_i32(
        catalog, "family_trait_trigger_reward_targets");
    _family_trait_effect_offsets = packed_i32(
        catalog, "family_trait_effect_offsets");
    _family_trait_effect_keys = packed_strings(
        catalog, "family_trait_effect_keys");
    _family_trait_origin_landform_offsets = packed_i32(
        catalog, "family_trait_origin_landform_offsets");
    _family_trait_origin_landforms = economy_packed_u8(
        catalog, "family_trait_origin_landforms");
    _family_trait_origin_adjacent_water = economy_packed_u8(
        catalog, "family_trait_origin_adjacent_water");
    _family_trait_origin_population_max = packed_i32(
        catalog, "family_trait_origin_population_max");
    _family_trait_origin_temperature_max_q16 = packed_i32(
        catalog, "family_trait_origin_temperature_max_q16");
    _family_trait_required_resource_offsets = packed_i32(
        catalog, "family_trait_required_resource_offsets");
    _family_trait_required_resource_ids = packed_i32(
        catalog, "family_trait_required_resource_ids");
    _family_trait_require_tax_or_subsidy = economy_packed_u8(
        catalog, "family_trait_require_tax_or_subsidy");

    const size_t count = _family_trait_ids.size();
    if (count == 0) {
        _family_trait_display_names.clear();
        _family_trait_weights.clear();
        _family_trait_core_eligible.clear();
        _family_trait_strength_min_q16.clear();
        _family_trait_strength_max_q16.clear();
        _family_trait_strength_step_q16.clear();
        _family_trait_prerequisite_offsets.assign(1, 0);
        _family_trait_prerequisites.clear();
        _family_trait_exclusion_offsets.assign(1, 0);
        _family_trait_exclusions.clear();
        _family_trait_technology_prerequisite_offsets.assign(1, 0);
        _family_trait_technology_prerequisites.clear();
        _family_trait_technology_match_any.clear();
        _family_trait_behavior_offsets.assign(1, 0);
        _family_trait_behavior_axes.clear();
        _family_trait_behavior_selector_kinds.clear();
        _family_trait_behavior_selector_ids.clear();
        _family_trait_behavior_factors_q16.clear();
        _family_trait_behavior_score_terms.clear();
        _family_trait_behavior_condition_offsets.assign(1, 0);
        _family_trait_behavior_condition_ops.clear();
        _family_trait_behavior_condition_arg0.clear();
        _family_trait_behavior_condition_values.clear();
        _family_trait_behavior_metric_masks.clear();
        _family_trait_modifier_offsets.assign(1, 0);
        _family_trait_modifier_definition_keys.clear();
        _family_trait_modifier_targets.clear();
        _family_trait_modifier_tier_magnitudes_q16.clear();
        _family_trait_trigger_offsets.assign(1, 0);
        _family_trait_trigger_definition_keys_by_tier.clear();
        _family_trait_trigger_reward_targets.clear();
        _family_trait_effect_offsets.assign(1, 0);
        _family_trait_effect_keys.clear();
        _family_trait_origin_landform_offsets.assign(1, 0);
        _family_trait_origin_landforms.clear();
        _family_trait_origin_adjacent_water.clear();
        _family_trait_origin_population_max.clear();
        _family_trait_origin_temperature_max_q16.clear();
        _family_trait_required_resource_offsets.assign(1, 0);
        _family_trait_required_resource_ids.clear();
        _family_trait_require_tax_or_subsidy.clear();
        return compile_family_effect_catalog(catalog, error);
    }
    const bool primary_shape = count > 0 &&
        _family_trait_display_names.size() == count &&
        _family_trait_weights.size() == count &&
        _family_trait_core_eligible.size() == count &&
        _family_trait_strength_min_q16.size() == count &&
        _family_trait_strength_max_q16.size() == count &&
        _family_trait_strength_step_q16.size() == count;
    if (_family_trait_technology_match_any.empty())
        _family_trait_technology_match_any.assign(count, 0);
    const bool match_any_shape =
        _family_trait_technology_match_any.size() == count;
    const bool csr_shape =
        _family_trait_prerequisite_offsets.size() == count + 1 &&
        _family_trait_exclusion_offsets.size() == count + 1 &&
        _family_trait_technology_prerequisite_offsets.size() == count + 1 &&
        _family_trait_behavior_offsets.size() == count + 1 &&
        _family_trait_modifier_offsets.size() == count + 1 &&
        _family_trait_trigger_offsets.size() == count + 1 &&
        _family_trait_effect_offsets.size() == count + 1 &&
        !_family_trait_prerequisite_offsets.empty() &&
        _family_trait_prerequisite_offsets.front() == 0 &&
        _family_trait_prerequisite_offsets.back() ==
            static_cast<int32_t>(_family_trait_prerequisites.size()) &&
        _family_trait_exclusion_offsets.front() == 0 &&
        _family_trait_exclusion_offsets.back() ==
            static_cast<int32_t>(_family_trait_exclusions.size()) &&
        _family_trait_technology_prerequisite_offsets.front() == 0 &&
        _family_trait_technology_prerequisite_offsets.back() ==
            static_cast<int32_t>(_family_trait_technology_prerequisites.size()) &&
        _family_trait_behavior_offsets.front() == 0 &&
        _family_trait_behavior_offsets.back() ==
            static_cast<int32_t>(_family_trait_behavior_axes.size()) &&
        _family_trait_modifier_offsets.front() == 0 &&
        _family_trait_modifier_offsets.back() == static_cast<int32_t>(
            _family_trait_modifier_definition_keys.size()) &&
        _family_trait_trigger_offsets.front() == 0 &&
        _family_trait_trigger_offsets.back() == static_cast<int32_t>(
            _family_trait_trigger_reward_targets.size()) &&
        _family_trait_effect_offsets.front() == 0 &&
        _family_trait_effect_offsets.back() == static_cast<int32_t>(
            _family_trait_effect_keys.size());
    if (_family_trait_origin_landform_offsets.empty())
        _family_trait_origin_landform_offsets.assign(count + 1, 0);
    if (_family_trait_origin_adjacent_water.empty())
        _family_trait_origin_adjacent_water.assign(count, 0);
    if (_family_trait_origin_population_max.empty())
        _family_trait_origin_population_max.assign(count, 0);
    if (_family_trait_origin_temperature_max_q16.empty())
        _family_trait_origin_temperature_max_q16.assign(count, -1);
    if (_family_trait_required_resource_offsets.empty())
        _family_trait_required_resource_offsets.assign(count + 1, 0);
    if (_family_trait_require_tax_or_subsidy.empty())
        _family_trait_require_tax_or_subsidy.assign(count, 0);
    const bool origin_gate_shape =
        _family_trait_origin_landform_offsets.size() == count + 1 &&
        !_family_trait_origin_landform_offsets.empty() &&
        _family_trait_origin_landform_offsets.front() == 0 &&
        _family_trait_origin_landform_offsets.back() == static_cast<int32_t>(
            _family_trait_origin_landforms.size()) &&
        _family_trait_origin_adjacent_water.size() == count &&
        _family_trait_origin_population_max.size() == count &&
        _family_trait_origin_temperature_max_q16.size() == count &&
        _family_trait_required_resource_offsets.size() == count + 1 &&
        _family_trait_required_resource_offsets.front() == 0 &&
        _family_trait_required_resource_offsets.back() == static_cast<int32_t>(
            _family_trait_required_resource_ids.size()) &&
        _family_trait_require_tax_or_subsidy.size() == count;
    const bool edge_shape =
        _family_trait_behavior_axes.size() ==
            _family_trait_behavior_selector_kinds.size() &&
        _family_trait_behavior_axes.size() ==
            _family_trait_behavior_selector_ids.size() &&
        _family_trait_behavior_axes.size() ==
            _family_trait_behavior_factors_q16.size() &&
        _family_trait_behavior_axes.size() ==
            _family_trait_behavior_score_terms.size() &&
        _family_trait_behavior_condition_offsets.size() ==
            _family_trait_behavior_axes.size() + 1 &&
        !_family_trait_behavior_condition_offsets.empty() &&
        _family_trait_behavior_condition_offsets.front() == 0 &&
        _family_trait_behavior_condition_offsets.back() ==
            static_cast<int32_t>(_family_trait_behavior_condition_ops.size()) &&
        _family_trait_behavior_condition_ops.size() ==
            _family_trait_behavior_condition_arg0.size() &&
        _family_trait_behavior_condition_ops.size() ==
            _family_trait_behavior_condition_values.size() &&
        _family_trait_modifier_definition_keys.size() ==
        _family_trait_modifier_targets.size() &&
        _family_trait_modifier_tier_magnitudes_q16.size() ==
            _family_trait_modifier_definition_keys.size() * 6 &&
        _family_trait_trigger_definition_keys_by_tier.size() ==
            _family_trait_trigger_reward_targets.size() * 6;
    if (_family_trait_catalog_version.get() <= 0 || _family_trait_catalog_hash.get() == 0 ||
        _family_core_trait_min < 0 ||
        _family_core_trait_max < _family_core_trait_min || !primary_shape ||
        !match_any_shape ||
        !csr_shape || !edge_shape || !origin_gate_shape) {
        error = "family_trait_catalog_shape_invalid";
        return false;
    }
    int32_t eligible = 0;
    for (size_t i = 0; i < count; ++i) {
        if (_family_trait_ids[i].empty() || _family_trait_weights[i] <= 0 ||
            (i > 0 && _family_trait_ids[i - 1] >= _family_trait_ids[i]) ||
            _family_trait_strength_min_q16[i] < 0 ||
            _family_trait_strength_max_q16[i] <
                _family_trait_strength_min_q16[i] ||
            _family_trait_strength_step_q16[i] <= 0) {
            error = "family_trait_catalog_entry_invalid";
            return false;
        }
        eligible += _family_trait_core_eligible[i] != 0 ? 1 : 0;
    }
    if (_family_core_trait_max > eligible) {
        error = "family_trait_core_count_exceeds_eligible";
        return false;
    }
    for (int32_t id : _family_trait_prerequisites)
        if (id < 0 || id >= static_cast<int32_t>(count)) {
            error = "family_trait_prerequisite_invalid";
            return false;
        }
    for (int32_t id : _family_trait_exclusions)
        if (id < 0 || id >= static_cast<int32_t>(count)) {
            error = "family_trait_exclusion_invalid";
            return false;
        }
    const int32_t technology_count = static_cast<int32_t>(
        packed_strings(catalog, "technology_ids").size());
    for (int32_t id : _family_trait_technology_prerequisites)
        if (id < 0 || (technology_count > 0 && id >= technology_count)) {
            error = "family_trait_technology_prerequisite_invalid";
            return false;
        }
    const int32_t resource_count = static_cast<int32_t>(
        packed_strings(catalog, "resource_ids").size());
    for (int32_t id : _family_trait_required_resource_ids)
        if (id < 0 || (resource_count > 0 && id >= resource_count)) {
            error = "family_trait_required_resource_invalid";
            return false;
        }
    for (int32_t term : _family_trait_behavior_score_terms)
        if (term < FAMILY_SCORE_CANDIDATE_WEIGHT ||
            term > FAMILY_SCORE_CAREER_MOBILITY) {
            error = "family_trait_behavior_score_term_invalid";
            return false;
        }
    for (int32_t op : _family_trait_behavior_condition_ops)
        if (op < 1 || op > 8) {
            error = "family_trait_behavior_condition_opcode_invalid";
            return false;
        }
    for (size_t edge = 0; edge + 1 < _family_trait_behavior_condition_offsets.size();
         ++edge) {
        if (_family_trait_behavior_condition_offsets[edge] >
            _family_trait_behavior_condition_offsets[edge + 1]) {
            error = "family_trait_behavior_condition_shape_invalid";
            return false;
        }
    }
    _family_trait_behavior_metric_masks.assign(count, MetricMask{});
    for (size_t trait = 0; trait < count; ++trait) {
        MetricMask mask;
        for (int32_t edge = _family_trait_behavior_offsets[trait];
             edge < _family_trait_behavior_offsets[trait + 1]; ++edge) {
            for (int32_t op_index = _family_trait_behavior_condition_offsets[edge];
                 op_index < _family_trait_behavior_condition_offsets[edge + 1];
                 ++op_index) {
                const int32_t op = _family_trait_behavior_condition_ops[op_index];
                const int32_t metric = _family_trait_behavior_condition_arg0[op_index];
                if (op >= 2 && op <= 4 && metric >= 0 && metric < FAMILY_METRIC_COUNT)
                    mask.set(metric);
            }
        }
        _family_trait_behavior_metric_masks[trait] = mask;
    }
    for (int32_t factor : _family_trait_behavior_factors_q16)
        if (factor < 0 || factor > 4 * Q16_ONE) {
            error = "family_trait_behavior_factor_invalid";
            return false;
        }
    for (int32_t magnitude : _family_trait_modifier_tier_magnitudes_q16)
        if (magnitude < 0 || magnitude > 4 * Q16_ONE) {
            error = "family_trait_modifier_magnitude_invalid";
            return false;
        }
    for (int32_t reward : _family_trait_trigger_reward_targets)
        if (reward < 0 || reward > 1) {
            error = "family_trait_trigger_reward_target_invalid";
            return false;
        }
    for (const std::string &key : _family_trait_effect_keys)
        if (key.empty() || key.rfind("family.effect.", 0) != 0) {
            error = "family_trait_effect_key_invalid";
            return false;
        }
    return compile_family_effect_catalog(catalog, error);
}

bool NativeEconomyRuntime::compile_family_effect_catalog(
        const Dictionary &catalog, std::string &error) {
    _family_effect_catalog_version = dict_num<int32_t>(
        catalog, "family_effect_catalog_version", 0);
    _family_effect_catalog_hash = dict_num<int64_t>(
        catalog, "family_effect_catalog_hash", 0);
    _family_effect_keys = packed_strings(catalog, "family_effect_keys");
    _family_effect_source_kinds = packed_i32(catalog, "family_effect_source_kinds");
    _family_effect_weights = packed_i32(catalog, "family_effect_weights");
    _family_effect_random_pool_eligible = economy_packed_u8(
        catalog, "family_effect_random_pool_eligible");
    _family_effect_technology_match_any = economy_packed_u8(
        catalog, "family_effect_technology_match_any");
    _family_effect_prerequisite_offsets = packed_i32(
        catalog, "family_effect_prerequisite_offsets");
    _family_effect_prerequisites = packed_i32(
        catalog, "family_effect_prerequisite_technology_indices");
    if (_family_effect_prerequisites.empty())
        _family_effect_prerequisites = packed_i32(
            catalog, "family_effect_prerequisites");
    _family_effect_exclusion_offsets = packed_i32(
        catalog, "family_effect_exclusion_offsets");
    _family_effect_exclusions = packed_i32(catalog, "family_effect_exclusions");
    _family_effect_magnitude_by_prestige_q16 = packed_i32(
        catalog, "family_effect_magnitude_by_prestige_q16");
    _family_effect_trigger_definition_keys_by_tier = packed_strings(
        catalog, "family_effect_trigger_definition_keys_by_tier");
    _family_effect_trigger_reward_targets = packed_i32(
        catalog, "family_effect_trigger_reward_targets");
    const size_t count = _family_effect_keys.size();
    if (count == 0) {
        _family_effect_source_kinds.clear();
        _family_effect_weights.clear();
        _family_effect_random_pool_eligible.clear();
        _family_effect_technology_match_any.clear();
        _family_effect_prerequisite_offsets.assign(1, 0);
        _family_effect_prerequisites.clear();
        _family_effect_exclusion_offsets.assign(1, 0);
        _family_effect_exclusions.clear();
        _family_effect_magnitude_by_prestige_q16.clear();
        _family_effect_trigger_definition_keys_by_tier.clear();
        _family_effect_trigger_reward_targets.clear();
        return true;
    }
    if (_family_effect_catalog_version <= 0 || _family_effect_catalog_hash == 0 ||
        _family_effect_source_kinds.size() != count ||
        _family_effect_weights.size() != count ||
        _family_effect_random_pool_eligible.size() != count) {
        error = "family_effect_catalog_shape_invalid";
        return false;
    }
    if (_family_effect_technology_match_any.empty())
        _family_effect_technology_match_any.assign(count, 0);
    if (_family_effect_technology_match_any.size() != count) {
        error = "family_effect_catalog_shape_invalid";
        return false;
    }
    if (_family_effect_prerequisite_offsets.empty())
        _family_effect_prerequisite_offsets.assign(count + 1, 0);
    if (_family_effect_exclusion_offsets.empty())
        _family_effect_exclusion_offsets.assign(count + 1, 0);
    if (_family_effect_prerequisite_offsets.size() != count + 1 ||
        _family_effect_exclusion_offsets.size() != count + 1 ||
        _family_effect_prerequisite_offsets.front() != 0 ||
        _family_effect_exclusion_offsets.front() != 0 ||
        _family_effect_prerequisite_offsets.back() !=
            static_cast<int32_t>(_family_effect_prerequisites.size()) ||
        _family_effect_exclusion_offsets.back() !=
            static_cast<int32_t>(_family_effect_exclusions.size())) {
        error = "family_effect_catalog_csr_invalid";
        return false;
    }
    if (_family_effect_magnitude_by_prestige_q16.empty())
        _family_effect_magnitude_by_prestige_q16.assign(count * 6, Q16_ONE);
    if (_family_effect_magnitude_by_prestige_q16.size() != count * 6) {
        error = "family_effect_prestige_magnitude_shape_invalid";
        return false;
    }
    if (_family_effect_trigger_definition_keys_by_tier.empty())
        _family_effect_trigger_definition_keys_by_tier.assign(count * 6, std::string());
    if (_family_effect_trigger_reward_targets.empty())
        _family_effect_trigger_reward_targets.assign(count, 0);
    if (_family_effect_trigger_definition_keys_by_tier.size() != count * 6 ||
        _family_effect_trigger_reward_targets.size() != count) {
        error = "family_effect_trigger_tier_shape_invalid";
        return false;
    }
    const int32_t technology_count = static_cast<int32_t>(
        packed_strings(catalog, "technology_ids").size());
    for (size_t i = 0; i < count; ++i) {
        if (_family_effect_keys[i].empty() ||
            _family_effect_keys[i].rfind("family.effect.", 0) != 0 ||
            (i > 0 && _family_effect_keys[i - 1] >= _family_effect_keys[i]) ||
            _family_effect_source_kinds[i] < 0 ||
            _family_effect_source_kinds[i] > 5 ||
            _family_effect_weights[i] <= 0 ||
            ((_family_effect_random_pool_eligible[i] != 0) !=
                (_family_effect_source_kinds[i] == 1))) {
            error = "family_effect_catalog_entry_invalid";
            return false;
        }
        for (int32_t tier = 0; tier < 6; ++tier) {
            const int32_t magnitude = _family_effect_magnitude_by_prestige_q16[
                i * 6 + static_cast<size_t>(tier)];
            if (magnitude < 0 || magnitude > 4 * Q16_ONE) {
                error = "family_effect_prestige_magnitude_invalid";
                return false;
            }
        }
    }
    for (int32_t id : _family_effect_prerequisites)
        if (id < 0 || (technology_count > 0 && id >= technology_count)) {
            error = "family_effect_technology_prerequisite_invalid";
            return false;
        }
    for (int32_t id : _family_effect_exclusions)
        if (id < 0 || id >= static_cast<int32_t>(count)) {
            error = "family_effect_exclusion_invalid";
            return false;
        }
    return true;
}

void EconomyFamilyCellInfluenceStore::clear() {
    active.clear(); generation.clear(); family_handle.clear(); cell.clear();
    stable_id.clear(); population.clear(); cash.clear(); building_asset.clear();
    population_share_q16.clear(); cash_share_q16.clear();
    building_share_q16.clear(); score_q16.clear(); satisfaction_q16.clear();
    prestige_level.clear();
    pending_target_level.clear(); review_streak.clear(); last_review_day.clear();
    free_indices.clear();
}

int32_t EconomyFamilyCellInfluenceStore::allocate() {
    int32_t index = -1;
    if (!free_indices.empty()) {
        const auto reusable = std::min_element(free_indices.begin(),
                                               free_indices.end());
        index = *reusable;
        free_indices.erase(reusable);
    } else {
        index = static_cast<int32_t>(active.size());
        active.push_back(0); generation.push_back(1); family_handle.push_back(0);
        cell.push_back(-1); stable_id.push_back(0); population.push_back(0);
        cash.push_back(0); building_asset.push_back(0);
        population_share_q16.push_back(0); cash_share_q16.push_back(0);
        building_share_q16.push_back(0); score_q16.push_back(0);
        satisfaction_q16.push_back(0);
        prestige_level.push_back(0); pending_target_level.push_back(0);
        review_streak.push_back(0); last_review_day.push_back(-1);
    }
    active.write_scalar(index, 1); family_handle.write_scalar(index, 0); cell.write_scalar(index, -1);
    stable_id.write_scalar(index, 0); population.write_scalar(index, 0); cash.write_scalar(index, 0);
    building_asset.write_scalar(index, 0); population_share_q16.write_scalar(index, 0);
    cash_share_q16.write_scalar(index, 0); building_share_q16.write_scalar(index, 0);
    score_q16.write_scalar(index, 0); satisfaction_q16.write_scalar(index, 0); prestige_level.write_scalar(index, 0);
    pending_target_level.write_scalar(index, 0); review_streak.write_scalar(index, 0);
    last_review_day.write_scalar(index, -1);
    return index;
}

void EconomyFamilyCellInfluenceStore::release(int32_t index) {
    if (index < 0 || index >= static_cast<int32_t>(active.size()) ||
        active[index] == 0) return;
    active.write_scalar(index, 0);
    generation.write_scalar(index, generation[index] == UINT32_MAX ? 1 : generation[index] + 1);
    free_indices.push_back(index);
}

uint64_t EconomyFamilyCellInfluenceStore::handle_for_index(
        int32_t index) const {
    if (index < 0 || index >= static_cast<int32_t>(active.size()) ||
        active[index] == 0) return 0;
    return (static_cast<uint64_t>(generation[index]) << 32) |
        static_cast<uint32_t>(index);
}

bool EconomyFamilyCellInfluenceStore::valid_handle(
        uint64_t handle, int32_t &index_out) const {
    const uint32_t index = static_cast<uint32_t>(handle & 0xffffffffULL);
    const uint32_t gen = static_cast<uint32_t>(handle >> 32);
    if (index >= active.size() || active[index] == 0 ||
        generation[index] != gen) return false;
    index_out = static_cast<int32_t>(index);
    return true;
}

// Storage implementation moved to economy_runtime_storage.cpp.

} // namespace pk
