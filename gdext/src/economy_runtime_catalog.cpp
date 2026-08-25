#include "economy_runtime.h"
#include "economy_runtime_variant_helpers.h"

#include <algorithm>
#include <cmath>
#include <cstring>
#include <limits>
#include <numeric>
#include <unordered_set>

#include <godot_cpp/variant/packed_byte_array.hpp>
#include <godot_cpp/variant/string_name.hpp>
#include <godot_cpp/variant/variant.hpp>

namespace pk {

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
    if (_family_trait_catalog_version <= 0 || _family_trait_catalog_hash == 0 ||
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

void NativeEconomyRuntime::FamilyCellInfluenceStore::clear() {
    active.clear(); generation.clear(); family_handle.clear(); cell.clear();
    stable_id.clear(); population.clear(); cash.clear(); building_asset.clear();
    population_share_q16.clear(); cash_share_q16.clear();
    building_share_q16.clear(); score_q16.clear(); satisfaction_q16.clear();
    prestige_level.clear();
    pending_target_level.clear(); review_streak.clear(); last_review_day.clear();
    free_indices.clear();
}

int32_t NativeEconomyRuntime::FamilyCellInfluenceStore::allocate() {
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
    active[index] = 1; family_handle[index] = 0; cell[index] = -1;
    stable_id[index] = 0; population[index] = 0; cash[index] = 0;
    building_asset[index] = 0; population_share_q16[index] = 0;
    cash_share_q16[index] = 0; building_share_q16[index] = 0;
    score_q16[index] = 0; satisfaction_q16[index] = 0; prestige_level[index] = 0;
    pending_target_level[index] = 0; review_streak[index] = 0;
    last_review_day[index] = -1;
    return index;
}

void NativeEconomyRuntime::FamilyCellInfluenceStore::release(int32_t index) {
    if (index < 0 || index >= static_cast<int32_t>(active.size()) ||
        active[index] == 0) return;
    active[index] = 0;
    generation[index] = generation[index] == UINT32_MAX ? 1 : generation[index] + 1;
    free_indices.push_back(index);
}

uint64_t NativeEconomyRuntime::FamilyCellInfluenceStore::handle_for_index(
        int32_t index) const {
    if (index < 0 || index >= static_cast<int32_t>(active.size()) ||
        active[index] == 0) return 0;
    return (static_cast<uint64_t>(generation[index]) << 32) |
        static_cast<uint32_t>(index);
}

bool NativeEconomyRuntime::FamilyCellInfluenceStore::valid_handle(
        uint64_t handle, int32_t &index_out) const {
    const uint32_t index = static_cast<uint32_t>(handle & 0xffffffffULL);
    const uint32_t gen = static_cast<uint32_t>(handle >> 32);
    if (index >= active.size() || active[index] == 0 ||
        generation[index] != gen) return false;
    index_out = static_cast<int32_t>(index);
    return true;
}

// Storage implementation moved to economy_runtime_storage.cpp.


bool NativeEconomyRuntime::compile_catalog(const Dictionary &catalog, std::string &error) {
    _profession_ids = packed_strings(catalog, "profession_ids");
    _ethnicity_ids = packed_strings(catalog, "ethnicity_ids");
    _good_ids = packed_strings(catalog, "good_ids");
    _family_corn_good_id = -1;
    for (size_t i = 0; i < _good_ids.size(); ++i) {
        if (_good_ids[i] == "corn_grain") {
            _family_corn_good_id = static_cast<int32_t>(i);
            break;
        }
    }
    _plan_ids = packed_strings(catalog, "plan_ids");
    _technology_ids = packed_strings(catalog, "technology_ids");
    const std::vector<int32_t> technology_prerequisite_offsets = packed_i32(
        catalog, "technology_prerequisite_offsets");
    const std::vector<int32_t> technology_prerequisites = packed_i32(
        catalog, "technology_prerequisites");
    _water_tech_river = -1;
    _water_tech_shallow = -1;
    _water_tech_far = -1;
    _water_tech_deep = -1;
    if (_profession_ids.empty() || _ethnicity_ids.empty() || _good_ids.empty() || _plan_ids.empty()) {
        error = "catalog_id_table_empty";
        return false;
    }
    if (_good_ids.size() > 256) {
        error = "good_count_exceeds_256";
        return false;
    }
    auto unique_sorted = [&](const std::vector<std::string> &ids, const char *name) {
        if (!std::is_sorted(ids.begin(), ids.end()) ||
            std::adjacent_find(ids.begin(), ids.end()) != ids.end()) {
            error = std::string(name) + "_ids_not_sorted_unique";
            return false;
        }
        return true;
    };
    if (!unique_sorted(_profession_ids, "profession") ||
        !unique_sorted(_ethnicity_ids, "ethnicity") ||
        !unique_sorted(_good_ids, "good") || !unique_sorted(_plan_ids, "plan"))
        return false;
    {
        std::unordered_set<std::string> technology_ids;
        technology_ids.reserve(_technology_ids.size());
        for (const std::string &id : _technology_ids) {
            if (id.empty() || !technology_ids.insert(id).second) {
                error = "technology_ids_not_unique";
                return false;
            }
        }
    }
    if (_technology_ids.size() > 4096) {
        error = "technology_count_exceeds_4096";
        return false;
    }
    if (technology_prerequisite_offsets.size() != _technology_ids.size() + 1 ||
        technology_prerequisite_offsets.empty() ||
        technology_prerequisite_offsets.front() != 0 ||
        !std::is_sorted(technology_prerequisite_offsets.begin(),
                        technology_prerequisite_offsets.end()) ||
        technology_prerequisite_offsets.back() !=
            static_cast<int32_t>(technology_prerequisites.size())) {
        error = "technology_prerequisite_catalog_invalid";
        return false;
    }
    const size_t technology_ancestor_words = (_technology_ids.size() + 63) / 64;
    std::vector<uint64_t> technology_ancestor_bits(
        _technology_ids.size() * technology_ancestor_words, 0);
    for (size_t technology = 0; technology < _technology_ids.size(); ++technology) {
        uint64_t *row = technology_ancestor_bits.data() +
            technology * technology_ancestor_words;
        row[technology / 64] |= uint64_t{1} << (technology % 64);
        for (int32_t edge = technology_prerequisite_offsets[technology];
             edge < technology_prerequisite_offsets[technology + 1]; ++edge) {
            const int32_t prerequisite = technology_prerequisites[static_cast<size_t>(edge)];
            if (prerequisite < 0 || prerequisite >= static_cast<int32_t>(technology)) {
                error = "technology_prerequisite_order_invalid";
                return false;
            }
            const uint64_t *prerequisite_row = technology_ancestor_bits.data() +
                static_cast<size_t>(prerequisite) * technology_ancestor_words;
            for (size_t word = 0; word < technology_ancestor_words; ++word)
                row[word] |= prerequisite_row[word];
        }
    }
    auto resolve_tech = [&](const char *id) -> int32_t {
        const auto it = std::find(_technology_ids.begin(), _technology_ids.end(), id);
        return it == _technology_ids.end()
            ? -1 : static_cast<int32_t>(it - _technology_ids.begin());
    };
    _water_tech_river = resolve_tech("tech.river_transport");
    _water_tech_shallow = resolve_tech("tech.celestial_navigation");
    _water_tech_far = resolve_tech("tech.oceanic_navigation");
    _water_tech_deep = resolve_tech("tech.oceanic_ship_design");
    auto compile_technology_tags = [&](const std::vector<int32_t> &tag_offsets,
                                       const std::vector<std::string> &tags,
                                       size_t item_count,
                                       std::vector<int32_t> &offsets,
                                       std::vector<int32_t> &requirements,
                                       const char *reason) {
        if (tag_offsets.size() != item_count + 1 || tag_offsets.empty() ||
            tag_offsets.front() != 0 ||
            !std::is_sorted(tag_offsets.begin(), tag_offsets.end()) ||
            tag_offsets.back() != static_cast<int32_t>(tags.size())) {
            error = reason;
            return false;
        }
        offsets.clear(); requirements.clear(); offsets.push_back(0);
        for (size_t item = 0; item < item_count; ++item) {
            for (int32_t k = tag_offsets[item]; k < tag_offsets[item + 1]; ++k) {
                const std::string &tag = tags[k];
                if (tag.rfind("tech.", 0) != 0) continue;
                const auto it = std::find(_technology_ids.begin(), _technology_ids.end(), tag);
                if (it == _technology_ids.end() || *it != tag) {
                    error = std::string(reason) + ":" + tag;
                    return false;
                }
                requirements.push_back(static_cast<int32_t>(it - _technology_ids.begin()));
            }
            std::sort(requirements.begin() + offsets.back(), requirements.end());
            requirements.erase(std::unique(requirements.begin() + offsets.back(),
                                            requirements.end()), requirements.end());
            offsets.push_back(static_cast<int32_t>(requirements.size()));
        }
        return true;
    };

    const std::vector<int32_t> profession_tag_offsets =
        packed_i32(catalog, "profession_technology_tag_offsets");
    const std::vector<std::string> profession_tags =
        packed_strings(catalog, "profession_technology_tags");
    if (!compile_technology_tags(profession_tag_offsets, profession_tags,
            _profession_ids.size(), _profession_technology_offsets,
            _profession_required_technologies, "profession_technology_catalog_invalid")) return false;

    _good_default_price = packed_i32(catalog, "good_default_price");
    _good_default_stock = packed_i64(catalog, "good_initial_stock");
    _good_min_price = packed_i32(catalog, "good_min_price");
    _good_max_price = packed_i32(catalog, "good_max_price");
    _good_price_adjust_q16 = packed_i32(catalog, "good_price_adjust_q16");
    _good_demand_price_elasticity_q16 = packed_i32(catalog, "good_demand_price_elasticity_q16");
    _good_demand_ema_alpha_q16 = packed_i32(catalog, "good_demand_ema_alpha_q16");
    const std::vector<int32_t> good_inventory_target_ratios_q16 = packed_i32(
        catalog, "good_inventory_target_ratios_q16");
    _good_target_inventory_days_q16 = packed_i32(
        catalog, "good_target_inventory_days_q16");
    _good_inventory_weight_q16 = packed_i32(catalog, "good_inventory_weight_q16");
    _good_shortage_weight_q16 = packed_i32(catalog, "good_shortage_weight_q16");
    _good_excess_demand_weight_q16 = packed_i32(catalog, "good_excess_demand_weight_q16");
    _good_cost_anchor_weight_q16 = packed_i32(catalog, "good_cost_anchor_weight_q16");
    _good_inactive_reversion_weight_q16 = packed_i32(catalog, "good_inactive_reversion_weight_q16");
    _good_business_demand_ema_alpha_q16 = packed_i32(catalog, "good_business_demand_ema_alpha_q16");
    _good_supply_ema_alpha_q16 = packed_i32(catalog, "good_supply_ema_alpha_q16");
    _good_cost_ema_alpha_q16 = packed_i32(catalog, "good_cost_ema_alpha_q16");
    _good_max_price_rise_q16 = packed_i32(catalog, "good_max_price_rise_q16");
    _good_max_price_fall_q16 = packed_i32(catalog, "good_max_price_fall_q16");
    _good_merchant_buy_factor_q16 = packed_i32(catalog, "good_merchant_buy_factor_q16");
	const std::vector<int32_t> good_trade_enabled = packed_i32(catalog, "good_trade_enabled");
	_good_transport_load_per_unit_q16 = packed_i32(
		catalog, "good_transport_load_per_unit_q16");
	_good_category_ids = packed_strings(catalog, "good_category_ids");
    _good_is_essential.assign(_good_category_ids.size(), 0);
    for (size_t good = 0; good < _good_category_ids.size(); ++good) {
        const std::string &category = _good_category_ids[good];
        if (category == "staple_food" || category == "protein" ||
            category == "produce" || category == "clothing" ||
            category == "housing" || category == "household_goods" ||
            category == "hygiene" || category == "home_energy")
            _good_is_essential[good] = 1;
    }
	_good_storage_modes = packed_i32(catalog, "good_storage_modes");
	_good_monetary_issue_values = packed_i64(catalog, "good_monetary_issue_values");
	_good_technology_tag_offsets = packed_i32(catalog, "good_technology_tag_offsets");
	_good_technology_tags = packed_strings(catalog, "good_technology_tags");
    const size_t goods = _good_ids.size();
    if (!good_inventory_target_ratios_q16.empty()) {
        if (good_inventory_target_ratios_q16.size() != goods) {
            error = "good_inventory_target_ratio_size_mismatch";
            return false;
        }
        _good_target_inventory_days_q16.resize(goods);
        for (size_t i = 0; i < goods; ++i) {
            if (good_inventory_target_ratios_q16[i] < 0 ||
                good_inventory_target_ratios_q16[i] > Q16_ONE * 4) {
                error = "good_inventory_target_ratio_out_of_range";
                return false;
            }
            _good_target_inventory_days_q16[i] = static_cast<int32_t>(mul_div_sat(
                _merchant_market_making_days_q16,
                good_inventory_target_ratios_q16[i], Q16_ONE,
                _saturation_count));
        }
    }
    if (_good_excess_demand_weight_q16.empty())
        _good_excess_demand_weight_q16.assign(goods, Q16_ONE / 8);
    if (_good_cost_anchor_weight_q16.empty())
        _good_cost_anchor_weight_q16.assign(goods, Q16_ONE / 4);
    if (_good_inactive_reversion_weight_q16.empty())
        _good_inactive_reversion_weight_q16.assign(goods, 512);
    if (_good_business_demand_ema_alpha_q16.empty())
        _good_business_demand_ema_alpha_q16.assign(goods, Q16_ONE / 8);
    if (_good_supply_ema_alpha_q16.empty())
        _good_supply_ema_alpha_q16.assign(goods, Q16_ONE / 8);
    if (_good_cost_ema_alpha_q16.empty())
        _good_cost_ema_alpha_q16.assign(goods, Q16_ONE / 16);
    if (_good_default_price.size() != goods || _good_default_stock.size() != goods ||
        _good_min_price.size() != goods || _good_max_price.size() != goods ||
        _good_price_adjust_q16.size() != goods ||
        _good_demand_price_elasticity_q16.size() != goods ||
        _good_demand_ema_alpha_q16.size() != goods ||
        _good_target_inventory_days_q16.size() != goods ||
        _good_inventory_weight_q16.size() != goods ||
        _good_shortage_weight_q16.size() != goods ||
        _good_excess_demand_weight_q16.size() != goods ||
        _good_cost_anchor_weight_q16.size() != goods ||
        _good_inactive_reversion_weight_q16.size() != goods ||
        _good_business_demand_ema_alpha_q16.size() != goods ||
        _good_supply_ema_alpha_q16.size() != goods ||
        _good_cost_ema_alpha_q16.size() != goods ||
        _good_max_price_rise_q16.size() != goods ||
        _good_max_price_fall_q16.size() != goods ||
		_good_category_ids.size() != goods || _good_storage_modes.size() != goods ||
		_good_monetary_issue_values.size() != goods ||
		_good_technology_tag_offsets.size() != goods + 1 ||
		_good_technology_tag_offsets.empty() || _good_technology_tag_offsets.front() != 0 ||
		!std::is_sorted(_good_technology_tag_offsets.begin(), _good_technology_tag_offsets.end()) ||
		_good_technology_tag_offsets.back() != static_cast<int32_t>(_good_technology_tags.size()) ||
        (!_good_merchant_buy_factor_q16.empty() &&
         _good_merchant_buy_factor_q16.size() != goods)) {
        error = "good_parameter_size_mismatch";
        return false;
    }
    if (_good_merchant_buy_factor_q16.empty()) {
        _good_merchant_buy_factor_q16.assign(goods, 62259); // 0.95 Q16.
    }
    _good_trade_enabled.assign(goods, 1);
    if (!good_trade_enabled.empty()) {
        if (good_trade_enabled.size() != goods) {
            error = "good_trade_enabled_size_mismatch";
            return false;
        }
        for (size_t i = 0; i < goods; ++i)
            _good_trade_enabled[i] = good_trade_enabled[i] != 0 ? 1 : 0;
    }
    if (_good_transport_load_per_unit_q16.empty())
        _good_transport_load_per_unit_q16.assign(goods, Q16_ONE);
    if (_good_transport_load_per_unit_q16.size() != goods) {
        error = "good_transport_load_size_mismatch";
        return false;
    }
    if (!compile_technology_tags(_good_technology_tag_offsets, _good_technology_tags,
            goods, _good_technology_offsets, _good_required_technologies,
            "good_technology_catalog_invalid")) return false;
    for (size_t i = 0; i < goods; ++i) {
        if (_good_default_price[i] < PRICE_NUMERIC_GUARD_MIN || _good_min_price[i] < 0 ||
            _good_max_price[i] < _good_min_price[i] || _good_default_stock[i] < 0 ||
            _good_demand_price_elasticity_q16[i] <= 0 ||
            _good_excess_demand_weight_q16[i] < 0 ||
            _good_cost_anchor_weight_q16[i] < 0 ||
            _good_inactive_reversion_weight_q16[i] < 0 ||
            _good_business_demand_ema_alpha_q16[i] < 0 ||
            _good_business_demand_ema_alpha_q16[i] > Q16_ONE ||
            _good_supply_ema_alpha_q16[i] < 0 ||
            _good_supply_ema_alpha_q16[i] > Q16_ONE ||
            _good_cost_ema_alpha_q16[i] < 0 ||
            _good_cost_ema_alpha_q16[i] > Q16_ONE ||
            _good_merchant_buy_factor_q16[i] < 0 ||
			_good_merchant_buy_factor_q16[i] > Q16_ONE ||
			_good_category_ids[i].empty() || _good_storage_modes[i] < 0 ||
			_good_storage_modes[i] > 1 || _good_monetary_issue_values[i] < 0 ||
			(_good_storage_modes[i] == 1 && _good_ids[i] != "electricity") ||
			(_good_monetary_issue_values[i] > 0 && _good_ids[i] != "gold" &&
			 _good_ids[i] != "silver") || _good_transport_load_per_unit_q16[i] <= 0) {
            error = "good_parameter_out_of_range";
            return false;
        }
    }
	_cycle_flow_good_ids.clear();
	for (size_t i = 0; i < goods; ++i) {
		if (_good_storage_modes[i] == 1) {
			_cycle_flow_good_ids.push_back(static_cast<int32_t>(i));
			_good_trade_enabled[i] = 0;
		}
	}

    _need_ids = packed_strings(catalog, "need_ids");
    const std::vector<std::string> curve_ids = packed_strings(catalog, "environment_curve_ids");
    const std::vector<int32_t> curve_signals = packed_i32(catalog, "environment_curve_signal_ids");
    const std::vector<int32_t> curve_values = packed_i32(catalog, "environment_curve_values_q16");
    if (_need_ids.empty() || _need_ids.size() > 32 || curve_ids.size() != curve_signals.size() ||
        curve_values.size() != curve_ids.size() * ENV_CURVE_SAMPLES ||
        !unique_sorted(_need_ids, "need") || !unique_sorted(curve_ids, "environment_curve")) {
        error = "need_or_environment_curve_catalog_invalid";
        return false;
    }
    _survival_food_need_stable_ids.clear();
    for (const char *id : {"staple_food", "protein", "produce"}) {
        const auto found = std::lower_bound(_need_ids.begin(), _need_ids.end(), id);
        if (found == _need_ids.end() || *found != id) {
            error = std::string("survival_food_need_missing:") + id;
            return false;
        }
        _survival_food_need_stable_ids.push_back(
            static_cast<int32_t>(found - _need_ids.begin()));
    }
    _survival_food_need_mask.assign(_need_ids.size(), uint8_t{0});
    for (const int32_t stable_need : _survival_food_need_stable_ids)
        _survival_food_need_mask[stable_need] = 1;
    const auto clothing = std::lower_bound(_need_ids.begin(), _need_ids.end(), "clothing");
    if (clothing == _need_ids.end() || *clothing != "clothing") {
        error = "survival_clothing_need_missing:clothing";
        return false;
    }
    _survival_clothing_need_stable_id =
        static_cast<int32_t>(clothing - _need_ids.begin());
    _environment_curves.resize(curve_ids.size());
    for (size_t c = 0; c < curve_ids.size(); ++c) {
        if (curve_signals[c] < 0 || curve_signals[c] > 3) {
            error = "environment_curve_signal_invalid";
            return false;
        }
        _environment_curves[c].signal_id = curve_signals[c];
        for (int32_t k = 0; k < ENV_CURVE_SAMPLES; ++k) {
            _environment_curves[c].values_q16[k] = std::max(0, curve_values[c * ENV_CURVE_SAMPLES + k]);
        }
    }

    const std::vector<int32_t> plan_offsets = packed_i32(catalog, "plan_need_offsets");
    const std::vector<int32_t> need_stable = packed_i32(catalog, "need_stable_ids");
    const std::vector<int32_t> need_living_weights =
        packed_i32(catalog, "need_living_cost_weights_q16");
    // Satisfaction tier/weight columns are authored per global need id. An older
    // catalog that predates them classifies everything as basic at full weight,
    // which reproduces a plain per-need average.
    std::vector<int32_t> need_satisfaction_tiers =
        packed_i32(catalog, "need_satisfaction_tiers");
    std::vector<int32_t> need_satisfaction_weights =
        packed_i32(catalog, "need_satisfaction_weights_q16");
    if (need_satisfaction_tiers.empty())
        need_satisfaction_tiers.assign(_need_ids.size(), SAT_DIM_BASIC);
    if (need_satisfaction_weights.empty())
        need_satisfaction_weights.assign(_need_ids.size(),
                                         static_cast<int32_t>(Q16_ONE));
    if (need_satisfaction_tiers.size() != _need_ids.size() ||
        need_satisfaction_weights.size() != _need_ids.size()) {
        error = "need_satisfaction_columns_invalid";
        return false;
    }
    const std::vector<int32_t> need_priority = packed_i32(catalog, "need_priorities");
    const std::vector<int64_t> need_base = packed_i64(catalog, "need_base_qty_per_person");
    const std::vector<int32_t> need_wealth_elasticity = packed_i32(catalog, "need_wealth_elasticity_q16");
    const std::vector<int32_t> need_wealth_min = packed_i32(catalog, "need_wealth_min_q16");
    const std::vector<int32_t> need_wealth_max = packed_i32(catalog, "need_wealth_max_q16");
    const std::vector<int32_t> need_price_quantity_elasticity = packed_i32(
        catalog, "need_price_quantity_elasticity_q16");
    const std::vector<int32_t> need_price_quantity_floor = packed_i32(
        catalog, "need_price_quantity_floor_q16");
    const std::vector<int32_t> need_env = packed_i32(catalog, "need_quantity_env_curve_ids");
    const std::vector<int32_t> need_variant_offsets = packed_i32(catalog, "need_variant_offsets");
    const size_t need_count = need_stable.size();
    if (plan_offsets.size() != _plan_ids.size() + 1 || plan_offsets.front() != 0 ||
        plan_offsets.back() != static_cast<int32_t>(need_count) || need_priority.size() != need_count ||
        need_base.size() != need_count || need_wealth_elasticity.size() != need_count ||
        need_wealth_min.size() != need_count || need_wealth_max.size() != need_count ||
        need_price_quantity_elasticity.size() != need_count ||
        need_price_quantity_floor.size() != need_count ||
        need_env.size() != need_count ||
        need_living_weights.size() != _need_ids.size() ||
        need_variant_offsets.size() != need_count + 1 ||
        need_variant_offsets.front() != 0) {
        error = "market_v2_need_columns_invalid";
        return false;
    }
    const std::vector<int32_t> variant_preference = packed_i32(catalog, "variant_preference_q16");
    const std::vector<int32_t> variant_elasticity = packed_i32(catalog, "variant_price_elasticity_q16");
    const std::vector<int32_t> variant_env = packed_i32(catalog, "variant_preference_env_curve_ids");
    const std::vector<int32_t> variant_component_offsets = packed_i32(catalog, "variant_component_offsets");
    const size_t variant_count = variant_preference.size();
    if (need_variant_offsets.back() != static_cast<int32_t>(variant_count) ||
        variant_elasticity.size() != variant_count || variant_env.size() != variant_count ||
        variant_component_offsets.size() != variant_count + 1 || variant_component_offsets.front() != 0) {
        error = "market_v2_variant_columns_invalid";
        return false;
    }
    const std::vector<int32_t> component_goods = packed_i32(catalog, "component_good_ids");
    const std::vector<int64_t> component_qty = packed_i64(catalog, "component_qty_per_need");
    if (variant_component_offsets.back() != static_cast<int32_t>(component_goods.size()) ||
        component_qty.size() != component_goods.size()) {
        error = "market_v2_component_columns_invalid";
        return false;
    }
    _plans.resize(_plan_ids.size());
    for (size_t p = 0; p < _plans.size(); ++p) {
        const int32_t begin = plan_offsets[p];
        const int32_t count = plan_offsets[p + 1] - begin;
        if (begin < 0 || count < 0 || count > MAX_NEEDS_PER_PLAN) {
            error = "plan_need_limit_exceeded";
            return false;
        }
        _plans[p] = {begin, count};
    }
    _needs.resize(need_count);
    for (size_t n = 0; n < need_count; ++n) {
        const int32_t variants_begin = need_variant_offsets[n];
        const int32_t variants_count = need_variant_offsets[n + 1] - variants_begin;
        if (need_stable[n] < 0 || need_stable[n] >= static_cast<int32_t>(_need_ids.size()) ||
            need_base[n] < 0 || need_wealth_min[n] < 0 || need_wealth_max[n] < need_wealth_min[n] ||
            need_price_quantity_elasticity[n] < 0 ||
            need_price_quantity_elasticity[n] > Q16_ONE * 4 ||
            need_price_quantity_floor[n] < 0 || need_price_quantity_floor[n] > Q16_ONE ||
            need_env[n] < -1 || need_env[n] >= static_cast<int32_t>(_environment_curves.size()) ||
            need_living_weights[need_stable[n]] < 0 ||
            need_living_weights[need_stable[n]] > Q16_ONE ||
            need_satisfaction_tiers[need_stable[n]] < 0 ||
            need_satisfaction_tiers[need_stable[n]] >= SAT_TIER_COUNT ||
            need_satisfaction_weights[need_stable[n]] < 0 ||
            need_satisfaction_weights[need_stable[n]] > Q16_ONE ||
            variants_count <= 0 || variants_count > MAX_VARIANTS_PER_NEED) {
            error = "market_v2_need_entry_invalid";
            return false;
        }
        _needs[n] = {need_stable[n], need_priority[n], variants_begin, variants_count,
                     need_base[n], need_wealth_elasticity[n], need_wealth_min[n],
                     need_wealth_max[n], need_price_quantity_elasticity[n],
                     need_price_quantity_floor[n], need_env[n],
                     need_living_weights[need_stable[n]],
                     need_satisfaction_tiers[need_stable[n]],
                     need_satisfaction_weights[need_stable[n]]};
    }
    _variants.resize(variant_count);
    for (size_t v = 0; v < variant_count; ++v) {
        const int32_t comp_begin = variant_component_offsets[v];
        const int32_t comp_count = variant_component_offsets[v + 1] - comp_begin;
        if (variant_preference[v] < 0 || variant_elasticity[v] < 0 ||
            variant_env[v] < -1 || variant_env[v] >= static_cast<int32_t>(_environment_curves.size()) ||
            comp_count <= 0 || comp_count > MAX_COMPONENTS_PER_VARIANT) {
            error = "market_v2_variant_entry_invalid";
            return false;
        }
        int64_t reference_cost = 0;
        for (int32_t k = 0; k < comp_count; ++k) {
            const int32_t component = comp_begin + k;
            if (component_goods[component] < 0 || component_goods[component] >= static_cast<int32_t>(goods) ||
                component_qty[component] <= 0) {
                error = "market_v2_component_entry_invalid";
                return false;
            }
            reference_cost = saturating_add(reference_cost,
                mul_div_sat(component_qty[component], _good_default_price[component_goods[component]],
                            GOODS_SCALE, _saturation_count), _saturation_count);
        }
        _variants[v] = {comp_begin, comp_count, variant_preference[v], variant_elasticity[v],
                        variant_env[v], std::max<int64_t>(1, reference_cost)};
    }
    _components.resize(component_goods.size());
    for (size_t c = 0; c < component_goods.size(); ++c) {
        _components[c] = {component_goods[c], component_qty[c]};
    }
    _survival_food_good_mask.assign(goods, uint8_t{0});
    _survival_clothing_good_mask.assign(goods, uint8_t{0});
    for (const Need &need : _needs) {
        const bool survival_food_need = need.stable_id >= 0 &&
            need.stable_id < static_cast<int32_t>(
                _survival_food_need_mask.size()) &&
            _survival_food_need_mask[need.stable_id] != 0;
        const bool survival_clothing_need =
            need.stable_id == _survival_clothing_need_stable_id;
        if (!survival_food_need && !survival_clothing_need) continue;
        for (int32_t v = 0; v < need.variant_count; ++v) {
            const VariantChoice &variant = _variants[need.variant_begin + v];
            if (variant.component_count != 1) continue;
            const NeedComponent &component = _components[variant.component_begin];
            if (component.qty_per_need == GOODS_SCALE) {
                if (survival_food_need) {
                    _survival_food_good_mask[component.good_id] = 1;
                }
                if (survival_clothing_need)
                    _survival_clothing_good_mask[component.good_id] = 1;
            }
        }
    }
    if (std::none_of(_survival_food_good_mask.begin(),
                     _survival_food_good_mask.end(), [](uint8_t value) {
                         return value != 0;
                     })) {
        error = "survival_food_good_catalog_empty";
        return false;
    }

    const std::vector<int32_t> sig_prof = packed_i32(catalog, "signature_profession_ids");
    const std::vector<int32_t> sig_eth = packed_i32(catalog, "signature_ethnicity_ids");
    const std::vector<int32_t> sig_plan = packed_i32(catalog, "signature_plan_ids");
    const std::vector<int64_t> sig_birth = packed_i64(catalog, "signature_birth_rate_q32");
    const std::vector<int64_t> sig_death = packed_i64(catalog, "signature_death_rate_q32");
    std::vector<int64_t> sig_sat_weight = packed_i64(catalog, "signature_satisfaction_birth_weight_q16");
    const size_t sig_count = sig_prof.size();
    if (sig_count == 0 || sig_eth.size() != sig_count || sig_plan.size() != sig_count ||
        sig_birth.size() != sig_count || sig_death.size() != sig_count) {
        error = "signature_table_size_mismatch";
        return false;
    }
    if (sig_sat_weight.empty()) sig_sat_weight.assign(sig_count, Q16_ONE);
    if (sig_sat_weight.size() != sig_count) {
        error = "signature_satisfaction_weight_size_mismatch";
        return false;
    }
    // Per-signature composite weights. A profession that authors nothing emits
    // -1 in every slot and inherits the profile default.
    const std::vector<int32_t> sig_dimension_weights = packed_i32(
        catalog, "signature_satisfaction_dimension_weights_q16");
    const bool has_dimension_weights = !sig_dimension_weights.empty();
    if (has_dimension_weights &&
        sig_dimension_weights.size() !=
            sig_count * static_cast<size_t>(SAT_DIM_COUNT)) {
        error = "signature_satisfaction_dimension_weight_size_mismatch";
        return false;
    }
    _signatures.resize(sig_count);
    for (size_t i = 0; i < sig_count; ++i) {
        if (sig_prof[i] < 0 || sig_prof[i] >= static_cast<int32_t>(_profession_ids.size()) ||
            sig_eth[i] < 0 || sig_eth[i] >= static_cast<int32_t>(_ethnicity_ids.size()) ||
            sig_plan[i] < 0 || sig_plan[i] >= static_cast<int32_t>(_plans.size()) ||
            sig_birth[i] < 0 || sig_death[i] < 0) {
            error = "signature_entry_invalid";
            return false;
        }
        _signatures[i] = {sig_prof[i], sig_eth[i], sig_plan[i], sig_birth[i], sig_death[i],
                          sig_sat_weight[i], {}};
        Signature &signature = _signatures[i];
        int64_t weight_total = 0;
        for (int32_t dim = 0; dim < SAT_DIM_COUNT; ++dim) {
            const int32_t authored = has_dimension_weights
                ? sig_dimension_weights[i * static_cast<size_t>(SAT_DIM_COUNT) +
                                        static_cast<size_t>(dim)]
                : -1;
            const int32_t weight = authored < 0
                ? _satisfaction_default_weights_q16[static_cast<size_t>(dim)]
                : authored;
            if (weight > Q16_ONE) {
                error = "signature_satisfaction_dimension_weight_out_of_range";
                return false;
            }
            signature.satisfaction_weights_q16[static_cast<size_t>(dim)] = weight;
            weight_total += weight;
        }
        if (weight_total <= 0) {
            error = "signature_satisfaction_dimension_weights_empty";
            return false;
        }
    }
    _merchant_profession_id = -1;
    for (size_t p = 0; p < _profession_ids.size(); ++p) {
        if (_profession_ids[p] == _merchant_profession_stable_id) {
            _merchant_profession_id = static_cast<int32_t>(p);
            break;
        }
    }
    if (_merchant_profession_id < 0) {
        error = "merchant_profession_missing:" + _merchant_profession_stable_id;
        return false;
    }
    // The unemployed profession is optional: catalogs that predate the explicit
    // unemployment model simply leave it unresolved (-1), and the employment pass
    // falls back to the derived population - owner - employee accounting. When it
    // is present it enables the persistent unemployed-pool signatures.
    _unemployed_profession_id = -1;
    for (size_t p = 0; p < _profession_ids.size(); ++p) {
        if (_profession_ids[p] == _unemployed_profession_stable_id) {
            _unemployed_profession_id = static_cast<int32_t>(p);
            break;
        }
    }
    // Build the dense (profession, ethnicity) -> signature lookup. Deterministic:
    // signatures are the profession x ethnicity cartesian product, so at most one
    // entry per (profession, ethnicity). Any unfilled cell stays -1.
    {
        const size_t n_prof = _profession_ids.size();
        const size_t n_eth = _ethnicity_ids.size();
        _signature_by_profession_ethnicity.assign(n_prof * n_eth, -1);
        for (size_t i = 0; i < _signatures.size(); ++i) {
            const int32_t prof = _signatures[i].profession_id;
            const int32_t eth = _signatures[i].ethnicity_id;
            if (prof < 0 || eth < 0 || static_cast<size_t>(prof) >= n_prof ||
                static_cast<size_t>(eth) >= n_eth) {
                error = "signature_profession_ethnicity_out_of_range";
                return false;
            }
            const size_t idx = static_cast<size_t>(prof) * n_eth + static_cast<size_t>(eth);
            if (_signature_by_profession_ethnicity[idx] < 0) {
                _signature_by_profession_ethnicity[idx] = static_cast<int32_t>(i);
            }
        }
    }
    _ethnicity_need_factor_q16 = packed_i32(catalog, "ethnicity_need_factor_q16");
    if (_ethnicity_need_factor_q16.empty()) {
        _ethnicity_need_factor_q16.assign(_ethnicity_ids.size() * _need_ids.size(), Q16_ONE);
    }
    if (_ethnicity_need_factor_q16.size() != _ethnicity_ids.size() * _need_ids.size()) {
        error = "ethnicity_need_factor_size_mismatch";
        return false;
    }
    if (!compile_building_catalog(catalog, error)) return false;
    if (!compile_technology_tags(_building_technology_tag_offsets,
            _building_technology_tags, _building_type_ids.size(),
            _building_technology_offsets, _building_required_technologies,
            "building_technology_catalog_invalid")) return false;
    if (!compile_technology_tags(_building_required_technology_tag_offsets,
            _building_required_technology_tags, _building_type_ids.size(),
            _building_all_technology_offsets, _building_all_required_technologies,
            "building_required_technology_catalog_invalid")) return false;
    _building_technology_practice_masks.assign(_building_type_ids.size(), 0);
    auto type_has_technology = [&](size_t type, const char *wanted) {
        const auto wanted_it = std::find(_technology_ids.begin(), _technology_ids.end(), wanted);
        if (wanted_it == _technology_ids.end()) return false;
        const size_t wanted_id = static_cast<size_t>(wanted_it - _technology_ids.begin());
        auto requirement_has_ancestor = [&](int32_t requirement) {
            return requirement >= 0 &&
                requirement < static_cast<int32_t>(_technology_ids.size()) &&
                (technology_ancestor_bits[static_cast<size_t>(requirement) *
                    technology_ancestor_words + wanted_id / 64] &
                    (uint64_t{1} << (wanted_id % 64))) != 0;
        };
        for (int32_t edge = _building_technology_offsets[type];
             edge < _building_technology_offsets[type + 1]; ++edge)
            if (requirement_has_ancestor(
                    _building_required_technologies[static_cast<size_t>(edge)]))
                return true;
        for (int32_t edge = _building_all_technology_offsets[type];
             edge < _building_all_technology_offsets[type + 1]; ++edge)
            if (requirement_has_ancestor(
                    _building_all_required_technologies[static_cast<size_t>(edge)]))
                return true;
        return false;
    };
    auto type_outputs = [&](size_t type, const char *wanted) {
        if (type >= _building_types.size()) return false;
        const BuildingType &building = _building_types[type];
        for (int32_t i = building.output_begin;
             i < building.output_begin + building.output_count; ++i) {
            const int32_t good = _building_outputs[static_cast<size_t>(i)].good_id;
            if (good >= 0 && good < static_cast<int32_t>(_good_ids.size()) &&
                _good_ids[static_cast<size_t>(good)] == wanted)
                return true;
        }
        return false;
    };
    auto practice_bit = [](int32_t rule) { return uint32_t{1} << rule; };
    for (size_t type = 0; type < _building_type_ids.size(); ++type) {
        const std::string &id = _building_type_ids[type];
        const BuildingType &building = _building_types[type];
        uint32_t mask = 0;
        if (id.find("landed_estate") != std::string::npos ||
            type_outputs(type, "corn_grain"))
            mask |= practice_bit(PRACTICE_MAIZE_SELECTION);
        if (building.production_climate_profile_id >= 0 &&
            building.production_climate_profile_id <
                static_cast<int32_t>(_production_climate_profile_ids.size()) &&
            _production_climate_profile_ids[static_cast<size_t>(
                building.production_climate_profile_id)] == "dryland_crop") {
            mask |= practice_bit(PRACTICE_DRYLAND_DAYS) |
                    practice_bit(PRACTICE_DRYLAND_DROUGHTS);
        }
        if (type_has_technology(type, "tech.irrigation") ||
            type_has_technology(type, "tech.canal_engineering") ||
            type_has_technology(type, "tech.hydraulic_engineering") ||
            type_has_technology(type, "tech.rice_paddy_cultivation"))
            mask |= practice_bit(PRACTICE_HYDRAULIC_ENGINEERING);
        if (type_outputs(type, "tools") ||
            id.find("tool_workshop") != std::string::npos)
            mask |= practice_bit(PRACTICE_METALWORKING);
        if (type_outputs(type, "printed_materials"))
            mask |= practice_bit(PRACTICE_PRINTING);
        if (id.rfind("steam_", 0) == 0 ||
            type_has_technology(type, "tech.steam_power"))
            mask |= practice_bit(PRACTICE_STEAM_POWER);
        if (id.find("electric") != std::string::npos ||
            type_has_technology(type, "tech.electrification") ||
            type_has_technology(type, "tech.electric_grid"))
            mask |= practice_bit(PRACTICE_ELECTRIFICATION);
        if (building.kind == 1 && building.employee_count > 0)
            mask |= practice_bit(PRACTICE_INDUSTRIAL_ORGANIZATION);
        if (type_has_technology(type, "tech.robotic_manufacturing") ||
            type_has_technology(type, "tech.autonomous_systems") ||
            type_has_technology(type, "tech.automated_agriculture") ||
            type_has_technology(type, "tech.autonomous_mining") ||
            type_has_technology(type, "tech.digital_control") ||
            type_has_technology(type, "tech.automated_logistics") ||
            id.find("robot") != std::string::npos)
            mask |= practice_bit(PRACTICE_AUTOMATION);
        if (id == "computing_research_center" ||
            id == "industrial_research_laboratory" ||
            type_has_technology(type, "tech.climate_modeling"))
            mask |= practice_bit(PRACTICE_CLIMATE_MODELING);
        if (type_outputs(type, "corn_grain") || type_outputs(type, "wheat_grain") ||
            type_outputs(type, "rice_grain") || type_outputs(type, "potatoes") ||
            type_outputs(type, "seed_cotton"))
            mask |= practice_bit(PRACTICE_SEED_SAVING);
        if (building.production_climate_profile_id >= 0 &&
            building.production_climate_profile_id <
                static_cast<int32_t>(_production_climate_profile_ids.size())) {
            const std::string &climate = _production_climate_profile_ids[
                static_cast<size_t>(building.production_climate_profile_id)];
            if (climate == "dryland_crop")
                mask |= practice_bit(PRACTICE_RAINFED_ADAPTATION);
            if (climate == "paddy_crop")
                mask |= practice_bit(PRACTICE_PADDY_CONTROL);
        }
        if (id == "wild_tuber_patch" || id.find("terrace") != std::string::npos ||
            type_has_technology(type, "tech.terrace_farming"))
            mask |= practice_bit(PRACTICE_TERRACE_MAINTENANCE);
        const bool mine_working = id.find("mine") != std::string::npos ||
            id.find("adit") != std::string::npos ||
            id.find("placer_gold") != std::string::npos ||
            id.find("silver_working") != std::string::npos;
        if (mine_working)
            mask |= practice_bit(PRACTICE_MINE_SUPPORT);
        if (mine_working && (type_has_technology(type, "tech.deep_mining") ||
            type_has_technology(type, "tech.shaft_sinking") ||
            type_has_technology(type, "tech.mine_drainage") ||
            id.rfind("steam_", 0) == 0))
            mask |= practice_bit(PRACTICE_MINE_DRAINAGE);
        if (id.find("kiln") != std::string::npos ||
            id.find("smelter") != std::string::npos || id == "charcoal_pit" ||
            id == "bricks_plant")
            mask |= practice_bit(PRACTICE_KILN_TEMPERATURE);
        if (type_outputs(type, "printed_materials"))
            mask |= practice_bit(PRACTICE_PRINT_CALIBRATION);
        if (id.rfind("steam_", 0) == 0 || id == "atmospheric_engine_workshop")
            mask |= practice_bit(PRACTICE_STEAM_SEALING);
        if (type_outputs(type, "electric_motor") ||
            type_has_technology(type, "tech.electric_motors"))
            mask |= practice_bit(PRACTICE_MOTOR_WINDING);
        if (type_has_technology(type, "tech.assembly_line") ||
            type_has_technology(type, "tech.mass_production"))
            mask |= practice_bit(PRACTICE_ASSEMBLY_LINE);
        if (type_has_technology(type, "tech.digital_control") ||
            type_has_technology(type, "tech.autonomous_systems") ||
            type_has_technology(type, "tech.robotic_manufacturing"))
            mask |= practice_bit(PRACTICE_DIGITAL_CONTROL);
        if (id.find("shipyard") != std::string::npos ||
            type_has_technology(type, "tech.oceanic_navigation") ||
            type_has_technology(type, "tech.oceanic_ship_design") ||
            type_has_technology(type, "tech.coastal_shipyards") ||
            type_has_technology(type, "tech.automated_logistics") ||
            type_has_technology(type, "tech.autonomous_logistics"))
            mask |= practice_bit(PRACTICE_MARITIME_OPERATIONS);
        if (id.find("irrigation") != std::string::npos ||
            id.find("waterworks") != std::string::npos ||
            type_has_technology(type, "tech.canal_engineering") ||
            type_has_technology(type, "tech.hydraulic_engineering") ||
            type_has_technology(type, "tech.hydrological_remote_sensing") ||
            type_has_technology(type, "tech.precision_irrigation") ||
            type_has_technology(type, "tech.adaptive_irrigation"))
            mask |= practice_bit(PRACTICE_WATERSHED_MANAGEMENT);
        if (id.find("timber") != std::string::npos ||
            id.find("lumber") != std::string::npos ||
            type_outputs(type, "paper") || type_outputs(type, "lumber") ||
            type_has_technology(type, "tech.forest_management") ||
            type_has_technology(type, "tech.steam_sawmilling"))
            mask |= practice_bit(PRACTICE_FOREST_MANAGEMENT);
        if (id.find("chemical") != std::string::npos ||
            id.find("fertilizer") != std::string::npos ||
            id.find("petrochemical") != std::string::npos ||
            type_has_technology(type, "tech.industrial_chemistry") ||
            type_has_technology(type, "tech.electrochemistry") ||
            type_has_technology(type, "tech.petrochemical_cracking"))
            mask |= practice_bit(PRACTICE_CHEMICAL_PROCESS_CONTROL);
        if (id.find("power_plant") != std::string::npos ||
            type_has_technology(type, "tech.electric_generation") ||
            type_has_technology(type, "tech.electric_grid") ||
            type_has_technology(type, "tech.nuclear_energy") ||
            type_has_technology(type, "tech.smart_grid"))
            mask |= practice_bit(PRACTICE_ENERGY_CONTROL);
        _building_technology_practice_masks[type] = mask;
    }
    for (int32_t rule = 0; rule < PRACTICE_RULE_COUNT; ++rule) {
        bool has_publisher = false;
        for (const uint32_t mask : _building_technology_practice_masks) {
            if ((mask & (uint32_t{1} << rule)) != 0) {
                has_publisher = true;
                break;
            }
        }
        if (!has_publisher) {
            error = "technology_practice_publisher_missing:" +
                std::to_string(rule);
            return false;
        }
    }
    const std::vector<std::string> research_signals = packed_strings(
        catalog, "research_signal_ids");
    auto signal_id = [&](const char *wanted) {
        const auto found = std::find(research_signals.begin(),
                                     research_signals.end(), wanted);
        return found != research_signals.end() && *found == wanted
            ? static_cast<int32_t>(found - research_signals.begin()) : -1;
    };
    _bio_maize_signal_id = signal_id("bio.maize");
    _good_occupancy_bit_offsets.assign(_good_ids.size() + 1, 0);
    _good_occupancy_bits.clear();
    {
        const std::vector<std::string> intro_goods = packed_strings(
            catalog, "research_bio_introduce_good_ids");
        const std::vector<int32_t> intro_bits = packed_i32(
            catalog, "research_bio_introduce_occupancy_bits");
        const size_t pair_count = std::min(intro_goods.size(), intro_bits.size());
        std::vector<std::vector<int32_t>> bits_by_good(_good_ids.size());
        for (size_t i = 0; i < pair_count; ++i) {
            const auto found = std::find(_good_ids.begin(), _good_ids.end(),
                                         intro_goods[i]);
            if (found == _good_ids.end() || *found != intro_goods[i]) continue;
            const int32_t bit = intro_bits[i];
            if (bit < 0 || bit >= 32) continue;
            bits_by_good[size_t(found - _good_ids.begin())].push_back(bit);
        }
        _good_occupancy_bit_offsets[0] = 0;
        for (size_t g = 0; g < _good_ids.size(); ++g) {
            auto &row = bits_by_good[g];
            std::sort(row.begin(), row.end());
            row.erase(std::unique(row.begin(), row.end()), row.end());
            _good_occupancy_bits.insert(_good_occupancy_bits.end(),
                                        row.begin(), row.end());
            _good_occupancy_bit_offsets[g + 1] =
                static_cast<int32_t>(_good_occupancy_bits.size());
        }
    }
    const std::array<const char *, 27> breakthrough_ids{
        "breakthrough.maize_selection", "breakthrough.dryland_adaptation",
        "breakthrough.hydraulic_engineering", "breakthrough.metalworking",
        "breakthrough.printing", "breakthrough.steam_power",
        "breakthrough.electrification", "breakthrough.industrial_organization",
        "breakthrough.automation", "breakthrough.climate_modeling",
        "breakthrough.seed_saving", "breakthrough.rainfed_adaptation",
        "breakthrough.paddy_control", "breakthrough.terrace_maintenance",
        "breakthrough.mine_support", "breakthrough.mine_drainage",
        "breakthrough.kiln_temperature", "breakthrough.print_calibration",
        "breakthrough.steam_sealing", "breakthrough.motor_winding",
        "breakthrough.assembly_line", "breakthrough.digital_control",
        "breakthrough.maritime_operations", "breakthrough.watershed_management",
        "breakthrough.forest_management", "breakthrough.chemical_process_control",
        "breakthrough.energy_control"};
    for (size_t i = 0; i < breakthrough_ids.size(); ++i)
        _breakthrough_signal_ids[i] = signal_id(breakthrough_ids[i]);
    for (size_t i = 22; i < breakthrough_ids.size(); ++i) {
        if (_breakthrough_signal_ids[i] < 0) {
            error = "technology_practice_signal_missing:" +
                std::string(breakthrough_ids[i]);
            return false;
        }
    }
    const std::array<const char *, 8> metal_signal_ids{
        "resource.copper_ore", "resource.iron_ore", "resource.tin_ore",
        "resource.gold_ore", "resource.silver_ore", "resource.lead_ore",
        "resource.zinc_ore", "resource.manganese_ore"};
    for (size_t i = 0; i < metal_signal_ids.size(); ++i)
        _metal_resource_signal_ids[i] = signal_id(metal_signal_ids[i]);
    _living_cost_base_plan_id = -1;
    for (size_t p = 0; p < _plan_ids.size(); ++p) {
        if (_plan_ids[p] == _living_cost_base_plan_stable_id) {
            _living_cost_base_plan_id = static_cast<int32_t>(p);
            break;
        }
    }
    if (_living_cost_base_plan_id < 0) {
        error = "living_cost_base_plan_missing:" + _living_cost_base_plan_stable_id;
        return false;
    }
    _survival_required_need_indices.assign(_need_ids.size(), -1);
    const Plan &survival_plan = _plans[_living_cost_base_plan_id];
    for (int32_t n = 0; n < survival_plan.need_count; ++n) {
        const int32_t need_index = survival_plan.need_begin + n;
        const int32_t stable_need = _needs[need_index].stable_id;
        if (_survival_required_need_indices[stable_need] >= 0) {
            error = "survival_required_need_duplicate:" + _need_ids[stable_need];
            return false;
        }
        _survival_required_need_indices[stable_need] = need_index;
    }
    for (int32_t stable_need : _survival_food_need_stable_ids) {
        if (_survival_required_need_indices[stable_need] < 0) {
            error = "survival_required_food_missing:" + _need_ids[stable_need];
            return false;
        }
    }
    if (_survival_required_need_indices[_survival_clothing_need_stable_id] < 0) {
        error = "survival_required_clothing_missing:" +
            _need_ids[_survival_clothing_need_stable_id];
        return false;
    }
    _catalog_hash = dict_num<int64_t>(catalog, "catalog_hash", 0);
    _catalog_compat_hash_v8 = dict_num<int64_t>(catalog, "market_catalog_compat_hash_v8", 0);
    _catalog_compat_hash_v10 = dict_num<int64_t>(catalog, "catalog_compat_hash_v10", 0);
    _catalog_compat_hash_v13 = dict_num<int64_t>(catalog, "catalog_compat_hash_v13", 0);
    _catalog_compat_hash_v39 = dict_num<int64_t>(catalog, "catalog_compat_hash_v39", 0);
    _catalog_compat_hash_v6 = dict_num<int64_t>(catalog, "market_catalog_compat_hash_v6", 0);
    _catalog_compat_hash_v7 = dict_num<int64_t>(catalog, "market_catalog_compat_hash_v7", 0);
    _building_catalog_hash = dict_num<int64_t>(catalog, "building_catalog_hash", 1);
    _building_catalog_compat_hash_v6 =
        dict_num<int64_t>(catalog, "building_catalog_compat_hash_v6", 0);
    _building_catalog_compat_hash_v7 =
        dict_num<int64_t>(catalog, "building_catalog_compat_hash_v7", 0);
    _building_catalog_compat_hash_v13 =
        dict_num<int64_t>(catalog, "building_catalog_compat_hash_v13", 0);
    if (_catalog_hash == 0) {
        error = "catalog_hash_required";
        return false;
    }
    if (!compile_carrying_catalog(catalog, error)) return false;
    if (!compile_settlement_catalog(catalog, error)) return false;
    if (!compile_family_catalog(catalog, error)) return false;
    if (!compile_person_catalog(catalog, error)) return false;
    return compile_development_catalog(catalog, error);
}


bool NativeEconomyRuntime::compile_development_catalog(
        const Dictionary &catalog, std::string &error) {
    _development_metric_signal_indices = packed_i32(
        catalog, "development_metric_signal_indices");
    _development_metric_era_indices = packed_i32(
        catalog, "development_metric_era_indices");
    _development_metric_types = packed_i32(catalog, "development_metric_types");
    _development_metric_subject_kinds = packed_i32(
        catalog, "development_metric_subject_kinds");
    const std::vector<int32_t> authored_offsets = packed_i32(
        catalog, "development_metric_subject_offsets");
    const std::vector<std::string> authored_subject_ids = packed_strings(
        catalog, "development_metric_subject_ids");
    _development_metric_qualifier_thresholds = packed_i64(
        catalog, "development_metric_qualifier_thresholds");
    _development_metric_duration_days = packed_i32(
        catalog, "development_metric_duration_days");
    const size_t count = _development_metric_types.size();
    if (_development_metric_signal_indices.size() != count ||
        _development_metric_era_indices.size() != count ||
        _development_metric_subject_kinds.size() != count ||
        _development_metric_qualifier_thresholds.size() != count ||
        _development_metric_duration_days.size() != count ||
        authored_offsets.size() != count + 1 || authored_offsets.empty() ||
        authored_offsets.front() != 0 ||
        authored_offsets.back() != static_cast<int32_t>(authored_subject_ids.size())) {
        error = "development_metric_catalog_columns_invalid";
        return false;
    }
    _development_metric_subject_offsets.assign(1, 0);
    _development_metric_subject_indices.clear();
    for (size_t metric = 0; metric < count; ++metric) {
        const int32_t type = _development_metric_types[metric];
        const int32_t kind = _development_metric_subject_kinds[metric];
        if (type <= 0 || type > 14 || kind < 0 || kind > 4 ||
            _development_metric_era_indices[metric] < 0 ||
            _development_metric_era_indices[metric] >= 11 ||
            _development_metric_qualifier_thresholds[metric] < 0 ||
            _development_metric_duration_days[metric] <= 0) {
            error = "development_metric_definition_invalid";
            return false;
        }
        for (int32_t cursor = authored_offsets[metric];
             cursor < authored_offsets[metric + 1]; ++cursor) {
            const std::string &subject = authored_subject_ids[static_cast<size_t>(cursor)];
            int32_t resolved = -1;
            if (kind == 1) { // economic sector
                static const char *SECTORS[] = {
                    "agriculture", "extractive", "manufacturing", "energy", "knowledge"};
                for (int32_t i = 0; i < 5; ++i)
                    if (subject == SECTORS[i]) resolved = i;
            } else if (kind == 2) {
                const auto it = std::find(_building_type_ids.begin(),
                                          _building_type_ids.end(), subject);
                if (it != _building_type_ids.end())
                    resolved = static_cast<int32_t>(it - _building_type_ids.begin());
            } else if (kind == 3) {
                const auto it = std::find(_building_upgrade_family_ids.begin(),
                                          _building_upgrade_family_ids.end(), subject);
                if (it != _building_upgrade_family_ids.end())
                    resolved = static_cast<int32_t>(it - _building_upgrade_family_ids.begin());
            } else if (kind == 4) {
                const auto it = std::find(_good_ids.begin(), _good_ids.end(), subject);
                if (it != _good_ids.end())
                    resolved = static_cast<int32_t>(it - _good_ids.begin());
            } else {
                // Settlement count uses a numeric tier as its subject.
                try { resolved = std::stoi(subject); } catch (...) { resolved = -1; }
            }
            if (resolved < 0) {
                error = "development_metric_subject_unknown:" + subject;
                return false;
            }
            _development_metric_subject_indices.push_back(resolved);
        }
        _development_metric_subject_offsets.push_back(
            static_cast<int32_t>(_development_metric_subject_indices.size()));
    }
    return true;
}


bool NativeEconomyRuntime::compile_family_catalog(
        const Dictionary &catalog, std::string &error) {
    _family_surname_pack_id = dict_string(
        catalog, "family_surname_pack_id", "default_zh");
    _family_surname_ids = packed_strings(catalog, "family_surname_ids");
    _family_surname_text = packed_strings(catalog, "family_surname_text");
    _family_surname_weights = packed_i32(catalog, "family_surname_weights");
    _family_culture_group_ids = packed_strings(catalog, "family_culture_group_ids");
    _family_culture_group_display_names = packed_strings(catalog, "family_culture_group_display_names");
    _family_culture_group_naming_formats = packed_strings(catalog, "family_culture_group_naming_formats");
    _family_culture_group_separators = packed_strings(catalog, "family_culture_group_separators");
    _family_culture_group_suffixes = packed_strings(catalog, "family_culture_group_suffixes");
    _family_surname_culture_group_ids = packed_i32(catalog, "family_surname_culture_group_ids");
    const std::vector<std::string> ethnicity_culture_group_keys =
        packed_strings(catalog, "ethnicity_culture_group_ids");
    _ethnicity_culture_group_ids.assign(_ethnicity_ids.size(), -1);
    if (ethnicity_culture_group_keys.size() != _ethnicity_ids.size()) {
        error = "ethnicity_culture_group_columns_mismatch";
        return false;
    }
    for (size_t i = 0; i < ethnicity_culture_group_keys.size(); ++i) {
        const auto it = std::lower_bound(_family_culture_group_ids.begin(),
            _family_culture_group_ids.end(), ethnicity_culture_group_keys[i]);
        if (it == _family_culture_group_ids.end() || *it != ethnicity_culture_group_keys[i]) {
            error = "ethnicity_culture_group_unknown";
            return false;
        }
        _ethnicity_culture_group_ids[i] = static_cast<int32_t>(
            it - _family_culture_group_ids.begin());
    }
    _family_catalog_hash = dict_num<int64_t>(catalog, "family_catalog_hash", 0);
    _family_catalog_compat_hash_v39 = dict_num<int64_t>(
        catalog, "family_catalog_compat_hash_v39", 0);
    if (_family_surname_ids.empty() || _family_culture_group_ids.empty() ||
        _family_surname_ids.size() != _family_surname_text.size() ||
        _family_surname_ids.size() != _family_surname_weights.size() ||
        _family_surname_ids.size() != _family_surname_culture_group_ids.size() ||
        _family_culture_group_ids.size() != _family_culture_group_display_names.size() ||
        _family_culture_group_ids.size() != _family_culture_group_naming_formats.size() ||
        _family_culture_group_ids.size() != _family_culture_group_separators.size() ||
        _family_culture_group_ids.size() != _family_culture_group_suffixes.size() ||
        _family_catalog_hash == 0) {
        error = "family_surname_catalog_invalid";
        return false;
    }
    for (size_t i = 0; i < _family_culture_group_ids.size(); ++i) {
        if (_family_culture_group_ids[i].empty() ||
            (i > 0 && _family_culture_group_ids[i - 1] >= _family_culture_group_ids[i]) ||
            _family_culture_group_naming_formats[i] != "CITY_SURNAME_SUFFIX" &&
            _family_culture_group_naming_formats[i] != "CITY_SEPARATOR_SURNAME" &&
            _family_culture_group_naming_formats[i] != "CITY_SURNAME") {
            error = "family_culture_group_catalog_invalid";
            return false;
        }
    }
    int64_t weight_sum = 0;
    for (size_t i = 0; i < _family_surname_ids.size(); ++i) {
        if (_family_surname_ids[i].empty() || _family_surname_text[i].empty() ||
            _family_surname_weights[i] <= 0 ||
            (i > 0 && std::tie(_family_surname_culture_group_ids[i - 1],
                _family_surname_ids[i - 1]) >= std::tie(
                _family_surname_culture_group_ids[i], _family_surname_ids[i]))) {
            error = "family_surname_catalog_not_sorted_unique";
            return false;
        }
        weight_sum += _family_surname_weights[i];
        if (_family_surname_culture_group_ids[i] < 0 ||
            _family_surname_culture_group_ids[i] >=
                static_cast<int32_t>(_family_culture_group_ids.size())) {
            error = "family_surname_culture_group_invalid";
            return false;
        }
    }
    if (weight_sum <= 0) {
        error = "family_surname_weight_sum_invalid";
        return false;
    }
    return compile_family_trait_catalog(catalog, error);
}


bool NativeEconomyRuntime::compile_person_catalog(
        const Dictionary &catalog, std::string &error) {
    _person_given_name_pack_id = dict_string(
        catalog, "person_given_name_pack_id", "default_zh");
    _person_given_name_ids = packed_strings(catalog, "person_given_name_ids");
    _person_given_name_text = packed_strings(catalog, "person_given_name_text");
    _person_given_name_weights = packed_i32(catalog, "person_given_name_weights");
    _person_catalog_hash = dict_num<int64_t>(catalog, "person_catalog_hash", 0);
    if (_person_given_name_ids.empty() ||
        _person_given_name_ids.size() != _person_given_name_text.size() ||
        _person_given_name_ids.size() != _person_given_name_weights.size() ||
        _person_catalog_hash == 0) {
        error = "person_given_name_catalog_invalid";
        return false;
    }
    int64_t weight_sum = 0;
    for (size_t i = 0; i < _person_given_name_ids.size(); ++i) {
        if (_person_given_name_ids[i].empty() ||
            _person_given_name_text[i].empty() ||
            _person_given_name_weights[i] <= 0 ||
            (i > 0 && _person_given_name_ids[i - 1] >=
                _person_given_name_ids[i])) {
            error = "person_given_name_catalog_not_sorted_unique";
            return false;
        }
        weight_sum += _person_given_name_weights[i];
    }
    if (weight_sum <= 0) {
        error = "person_given_name_weight_sum_invalid";
        return false;
    }
    return true;
}


bool NativeEconomyRuntime::compile_settlement_catalog(
        const Dictionary &catalog, std::string &error) {
    _prosperity_thresholds = packed_i64(catalog, "prosperity_thresholds");
    _prosperity_ids = packed_strings(catalog, "prosperity_ids");
    _prosperity_names = packed_strings(catalog, "prosperity_names");
    _settlement_full_name_ids = packed_strings(
        catalog, "settlement_full_name_ids");
    _settlement_full_name_text = packed_strings(
        catalog, "settlement_full_name_text");
    _settlement_full_name_weights = packed_i32(
        catalog, "settlement_full_name_weights");
    _settlement_full_name_alias_ids = packed_strings(
        catalog, "settlement_full_name_alias_ids");
    _settlement_full_name_alias_targets = packed_strings(
        catalog, "settlement_full_name_alias_targets");
    _settlement_full_name_share_q16 = dict_num<int32_t>(
        catalog, "settlement_full_name_share_q16", 32768);
    _settlement_prefix_ids = packed_strings(catalog, "settlement_prefix_ids");
    _settlement_prefix_text = packed_strings(catalog, "settlement_prefix_text");
    _settlement_prefix_weights = packed_i32(catalog, "settlement_prefix_weights");
    _settlement_prefix_alias_ids = packed_strings(
        catalog, "settlement_prefix_alias_ids");
    _settlement_prefix_alias_targets = packed_strings(
        catalog, "settlement_prefix_alias_targets");
    _settlement_root_ids = packed_strings(catalog, "settlement_root_ids");
    _settlement_root_text = packed_strings(catalog, "settlement_root_text");
    _settlement_root_weights = packed_i32(catalog, "settlement_root_weights");
    _settlement_root_alias_ids = packed_strings(
        catalog, "settlement_root_alias_ids");
    _settlement_root_alias_targets = packed_strings(
        catalog, "settlement_root_alias_targets");
    _settlement_suffix_ids = packed_strings(catalog, "settlement_suffix_ids");
    _settlement_suffix_text = packed_strings(catalog, "settlement_suffix_text");
    _settlement_suffix_weights = packed_i32(catalog, "settlement_suffix_weights");
    _settlement_suffix_alias_ids = packed_strings(
        catalog, "settlement_suffix_alias_ids");
    _settlement_suffix_alias_targets = packed_strings(
        catalog, "settlement_suffix_alias_targets");
    _settlement_name_pack_id = dict_string(
        catalog, "settlement_name_pack_id", "default_zh");
    _settlement_named_tier = dict_num<int32_t>(
        catalog, "settlement_named_tier", 2);
    _settlement_downgrade_bp = dict_num<int32_t>(
        catalog, "settlement_downgrade_bp", 9000);
    _prosperity_profile_hash = dict_num<int64_t>(
        catalog, "prosperity_profile_hash", 0);
    _settlement_catalog_hash = dict_num<int64_t>(
        catalog, "settlement_catalog_hash", 0);
    const size_t tiers = _prosperity_thresholds.size();
    if (tiers < 2 || tiers > 32 || _prosperity_ids.size() != tiers ||
        _prosperity_names.size() != tiers || _prosperity_thresholds[0] != 0 ||
        !std::is_sorted(_prosperity_thresholds.begin(),
                        _prosperity_thresholds.end()) ||
        std::adjacent_find(_prosperity_thresholds.begin(),
                           _prosperity_thresholds.end()) !=
            _prosperity_thresholds.end() ||
        _settlement_named_tier < 1 ||
        _settlement_named_tier >= static_cast<int32_t>(tiers) ||
        _settlement_downgrade_bp < 1 || _settlement_downgrade_bp > 10000 ||
        _settlement_full_name_share_q16 < 0 ||
        _settlement_full_name_share_q16 > 65536 ||
        _prosperity_profile_hash == 0 || _settlement_catalog_hash == 0) {
        error = "settlement_profile_invalid";
        return false;
    }
    const auto valid_part = [](const std::vector<std::string> &ids,
                               const std::vector<std::string> &text,
                               const std::vector<int32_t> &weights) {
        return !ids.empty() && ids.size() == text.size() &&
            ids.size() == weights.size() &&
            std::all_of(weights.begin(), weights.end(),
                        [](int32_t value) { return value > 0; });
    };
    const bool has_full_names = !_settlement_full_name_ids.empty();
    const bool has_components = !_settlement_prefix_ids.empty();
    if ((!has_full_names && !has_components) ||
        (has_full_names && !valid_part(
            _settlement_full_name_ids, _settlement_full_name_text,
            _settlement_full_name_weights)) ||
        (has_components && (!valid_part(_settlement_prefix_ids, _settlement_prefix_text,
                    _settlement_prefix_weights) ||
        !valid_part(_settlement_root_ids, _settlement_root_text,
                    _settlement_root_weights) ||
        !valid_part(_settlement_suffix_ids, _settlement_suffix_text,
                    _settlement_suffix_weights)))) {
        error = "settlement_name_catalog_invalid";
        return false;
    }
    const auto valid_aliases = [](const std::vector<std::string> &aliases,
                                  const std::vector<std::string> &targets,
                                  const std::vector<std::string> &ids) {
        if (aliases.size() != targets.size()) return false;
        for (size_t i = 0; i < aliases.size(); ++i) {
            if (aliases[i].empty() ||
                std::find(ids.begin(), ids.end(), targets[i]) == ids.end())
                return false;
        }
        return true;
    };
    if ((has_full_names && !valid_aliases(
            _settlement_full_name_alias_ids,
            _settlement_full_name_alias_targets,
            _settlement_full_name_ids)) ||
        (has_components && (!valid_aliases(_settlement_prefix_alias_ids,
                       _settlement_prefix_alias_targets,
                       _settlement_prefix_ids) ||
        !valid_aliases(_settlement_root_alias_ids,
                       _settlement_root_alias_targets,
                       _settlement_root_ids) ||
        !valid_aliases(_settlement_suffix_alias_ids,
                       _settlement_suffix_alias_targets,
                       _settlement_suffix_ids)))) {
        error = "settlement_name_alias_invalid";
        return false;
    }
    const uint64_t component_combinations = has_components
        ? static_cast<uint64_t>(_settlement_prefix_ids.size()) *
        static_cast<uint64_t>(_settlement_root_ids.size()) *
        static_cast<uint64_t>(_settlement_suffix_ids.size()) : 0;
    const uint64_t combinations =
        static_cast<uint64_t>(_settlement_full_name_ids.size()) +
        component_combinations;
    if (combinations == 0 ||
        (has_components && component_combinations < 4096) ||
        combinations > 0x7fffffffULL) {
        error = "settlement_name_combination_count_invalid";
        return false;
    }
    return true;
}


bool NativeEconomyRuntime::compile_building_catalog(const Dictionary &catalog,
                                                     std::string &error) {
    _building_type_ids = packed_strings(catalog, "building_type_ids");
	_production_climate_profile_ids = packed_strings(
		catalog, "production_climate_profile_ids");
	const std::vector<int32_t> climate_temp_opt = packed_i32(
		catalog, "production_climate_temperature_opt_q16");
	const std::vector<int32_t> climate_temp_tol = packed_i32(
		catalog, "production_climate_temperature_tolerance_q16");
	const std::vector<int32_t> climate_water_opt = packed_i32(
		catalog, "production_climate_water_opt_q16");
	const std::vector<int32_t> climate_water_tol = packed_i32(
		catalog, "production_climate_water_tolerance_q16");
	const std::vector<int32_t> climate_exposure = packed_i32(
		catalog, "production_climate_exposure_q16");
	const std::vector<int32_t> climate_floor = packed_i32(
		catalog, "production_climate_floor_q16");
	const size_t climate_count = _production_climate_profile_ids.size();
	if (climate_temp_opt.size() != climate_count || climate_temp_tol.size() != climate_count ||
		climate_water_opt.size() != climate_count || climate_water_tol.size() != climate_count ||
		climate_exposure.size() != climate_count || climate_floor.size() != climate_count ||
		!std::is_sorted(_production_climate_profile_ids.begin(),
			_production_climate_profile_ids.end()) ||
		std::adjacent_find(_production_climate_profile_ids.begin(),
			_production_climate_profile_ids.end()) != _production_climate_profile_ids.end()) {
		error = "production_climate_catalog_invalid";
		return false;
	}
	_production_climate_profiles.resize(climate_count);
	for (size_t i = 0; i < climate_count; ++i) {
		if (climate_temp_opt[i] < 0 || climate_temp_opt[i] > Q16_ONE ||
			climate_water_opt[i] < 0 || climate_water_opt[i] > Q16_ONE ||
			climate_temp_tol[i] <= 0 || climate_temp_tol[i] > Q16_ONE ||
			climate_water_tol[i] <= 0 || climate_water_tol[i] > Q16_ONE ||
			climate_exposure[i] < 0 || climate_exposure[i] > Q16_ONE ||
			climate_floor[i] < 0 || climate_floor[i] > Q16_ONE) {
			error = "production_climate_profile_invalid";
			return false;
		}
		_production_climate_profiles[i] = {climate_temp_opt[i], climate_temp_tol[i],
			climate_water_opt[i], climate_water_tol[i], climate_exposure[i], climate_floor[i]};
	}
	_building_upgrade_family_ids = packed_strings(catalog, "building_upgrade_family_ids");
	_building_upgrade_family_indices = packed_i32(catalog, "building_upgrade_family_indices");
	_building_upgrade_tiers = packed_i32(catalog, "building_upgrade_tiers");
    _max_building_upgrade_tier = 0;
    for (int32_t tier : _building_upgrade_tiers)
        _max_building_upgrade_tier = std::max(_max_building_upgrade_tier, tier);
    _resource_ids = packed_strings(catalog, "building_resource_ids");
    _modifier_sector_ids = packed_strings(catalog, "modifier_sector_ids");
    _modifier_terrain_ids = packed_strings(catalog, "modifier_terrain_ids");
    _modifier_landform_ids = packed_strings(catalog, "modifier_landform_ids");
    _resource_reserve_slots = packed_strings(catalog, "building_resource_reserve_slots");
    _resource_extra_slots = packed_strings(catalog, "building_resource_extra_slots");
    _resource_gen_base = packed_i64(catalog, "building_resource_gen_base");
    _resource_gen_temp = packed_i64(catalog, "building_resource_gen_temp");
    _resource_gen_moisture = packed_i64(catalog, "building_resource_gen_moisture");
    _resource_gen_self = packed_i64(catalog, "building_resource_gen_self");
    _resource_decay_base = packed_i64(catalog, "building_resource_decay_base");
    _resource_decay_temp = packed_i64(catalog, "building_resource_decay_temp");
    _resource_decay_moisture = packed_i64(catalog, "building_resource_decay_moisture");
    _resource_decay_self_q16 = packed_i32(catalog, "building_resource_decay_self_q16");
    _resource_ecology_capacity = packed_i64(catalog, "building_resource_ecology_capacity");
    _resource_ecology_growth_q16 = packed_i32(catalog, "building_resource_ecology_growth_q16");
    _resource_temp_lo_q16 = packed_i32(catalog, "building_resource_temp_lo_q16");
    _resource_temp_hi_q16 = packed_i32(catalog, "building_resource_temp_hi_q16");
    const size_t resource_count = _resource_ids.size();
    if (_resource_ids.size() != _resource_reserve_slots.size() ||
        _resource_ids.size() != _resource_extra_slots.size() ||
        _resource_gen_base.size() != resource_count ||
        _resource_gen_temp.size() != resource_count ||
        _resource_gen_moisture.size() != resource_count ||
        _resource_gen_self.size() != resource_count ||
        _resource_decay_base.size() != resource_count ||
        _resource_decay_temp.size() != resource_count ||
        _resource_decay_moisture.size() != resource_count ||
        _resource_decay_self_q16.size() != resource_count ||
        _resource_ecology_capacity.size() != resource_count ||
        _resource_ecology_growth_q16.size() != resource_count ||
        _resource_temp_lo_q16.size() != resource_count ||
        _resource_temp_hi_q16.size() != resource_count ||
        !std::is_sorted(_resource_ids.begin(), _resource_ids.end()) ||
        std::adjacent_find(_resource_ids.begin(), _resource_ids.end()) != _resource_ids.end() ||
        _modifier_sector_ids.size() != 5 || _modifier_terrain_ids.empty() ||
        _modifier_landform_ids.empty()) {
        error = "building_resource_catalog_invalid";
        return false;
    }
    if (_building_type_ids.empty()) {
        _building_technology_tag_offsets = packed_i32(catalog, "building_technology_tag_offsets");
        _building_technology_tags = packed_strings(catalog, "building_technology_tags");
        _building_required_technology_tag_offsets = packed_i32(
            catalog, "building_required_technology_tag_offsets");
        _building_required_technology_tags = packed_strings(
            catalog, "building_required_technology_tags");
        if (_building_technology_tag_offsets.size() != 1 ||
            _building_technology_tag_offsets.front() != 0 ||
            !_building_technology_tags.empty() ||
            _building_required_technology_tag_offsets.size() != 1 ||
            _building_required_technology_tag_offsets.front() != 0 ||
            !_building_required_technology_tags.empty() || !_building_upgrade_family_ids.empty() ||
            !_building_upgrade_family_indices.empty() || !_building_upgrade_tiers.empty()) {
            error = "building_technology_catalog_invalid";
            return false;
        }
        _building_types.clear();
        _building_type_market_signal_goods.clear();
        _building_type_labor_signal_professions.clear();
        _building_employee_roles.clear();
        _building_construction_goods.clear();
        _building_construction_candidate_offsets.clear();
        _building_construction_candidates.clear();
        _building_maintenance_author_offsets.clear();
        _building_maintenance_author_goods.clear();
        _building_maintenance_goods.clear();
        _building_inputs.clear();
        _building_input_candidates.clear();
        _building_outputs.clear();
        _building_output_cost_shares_q16.clear();
        _building_resources.clear();
        _building_resource_generation.clear();
        _building_conditions.clear();
        return true;
    }
    if (!std::is_sorted(_building_type_ids.begin(), _building_type_ids.end()) ||
        std::adjacent_find(_building_type_ids.begin(), _building_type_ids.end()) !=
            _building_type_ids.end() || _building_type_ids.size() > 4096) {
        error = "building_type_ids_not_sorted_unique";
        return false;
    }
    if (!std::is_sorted(_building_upgrade_family_ids.begin(),
                        _building_upgrade_family_ids.end()) ||
        std::adjacent_find(_building_upgrade_family_ids.begin(),
                           _building_upgrade_family_ids.end()) !=
            _building_upgrade_family_ids.end()) {
        error = "building_upgrade_family_ids_not_sorted_unique";
        return false;
    }
    const size_t types = _building_type_ids.size();
	const std::vector<int32_t> climate_profile_indices = packed_i32(
		catalog, "building_production_climate_profile_indices");
    const std::vector<int32_t> owner_prof = packed_i32(catalog, "building_owner_profession_ids");
    const std::vector<int64_t> owner_slots = packed_i64(catalog, "building_owner_slots");
    const std::vector<int64_t> wages = packed_i64(catalog, "building_wage_per_employee_per_day");
    const std::vector<int32_t> construction_days = packed_i32(catalog, "building_construction_days");
    const std::vector<int32_t> behavior_ids = packed_i32(catalog, "building_behavior_ids");
    const std::vector<int32_t> behavior_versions = packed_i32(catalog, "building_behavior_versions");
    const std::vector<int32_t> target_margins =
        packed_i32(catalog, "building_target_operating_margin_q16");
    const std::vector<int32_t> supply_elasticities =
        packed_i32(catalog, "building_supply_price_elasticity_q16");
	_building_kinds = packed_i32(catalog, "building_kinds");
    _building_economic_sectors = packed_i32(catalog, "building_economic_sectors");
	_building_technology_tag_offsets = packed_i32(catalog, "building_technology_tag_offsets");
	_building_technology_tags = packed_strings(catalog, "building_technology_tags");
    _building_required_technology_tag_offsets = packed_i32(
        catalog, "building_required_technology_tag_offsets");
    _building_required_technology_tags = packed_strings(
        catalog, "building_required_technology_tags");
    _building_dependency_branch_offsets = packed_i32(
        catalog, "building_dependency_branch_offsets");
    _building_dependency_branch_technologies = packed_i32(
        catalog, "building_dependency_branch_technologies");
    _building_dependency_branch_technology_offsets = packed_i32(
        catalog, "building_dependency_branch_technology_offsets");
    _building_dependency_branch_group_offsets = packed_i32(
        catalog, "building_dependency_branch_group_offsets");
    _building_dependency_kinds = economy_packed_u8(
        catalog, "building_dependency_kinds");
    _building_dependency_ids = packed_i32(catalog, "building_dependency_ids");
    _building_dependency_tag_offsets = packed_i32(
        catalog, "building_dependency_tag_offsets");
    _building_dependency_tags = packed_i32(catalog, "building_dependency_tags");
    const std::vector<int32_t> employee_offsets = packed_i32(catalog, "building_employee_offsets");
    const std::vector<int32_t> construction_offsets = packed_i32(catalog, "building_construction_offsets");
    const std::vector<int32_t> maintenance_offsets = packed_i32(catalog, "building_maintenance_offsets");
    const std::vector<int32_t> maintenance_horizons = packed_i32(
        catalog, "building_maintenance_horizon_days");
    const std::vector<int32_t> input_offsets = packed_i32(catalog, "building_input_offsets");
    const std::vector<int32_t> output_offsets = packed_i32(catalog, "building_output_offsets");
    const std::vector<int32_t> output_cost_share_offsets =
        packed_i32(catalog, "building_output_cost_share_offsets");
    const std::vector<int32_t> resource_offsets = packed_i32(catalog, "building_resource_offsets");
    const std::vector<int32_t> generation_offsets = packed_i32(catalog, "building_resource_generation_offsets");
    const std::vector<int32_t> generation_floors = packed_i32(catalog, "building_resource_generation_floor_q16");
    const std::vector<int32_t> condition_offsets = packed_i32(catalog, "building_condition_offsets");
    auto offsets_valid = [&](const std::vector<int32_t> &v) {
        return v.size() == types + 1 && !v.empty() && v.front() == 0 &&
               std::is_sorted(v.begin(), v.end());
    };
    if (owner_prof.size() != types || owner_slots.size() != types || wages.size() != types ||
        construction_days.size() != types || behavior_ids.size() != types ||
		behavior_versions.size() != types || target_margins.size() != types ||
        supply_elasticities.size() != types || _building_kinds.size() != types ||
        _building_economic_sectors.size() != types || climate_profile_indices.size() != types ||
		_building_upgrade_family_indices.size() != types ||
		_building_upgrade_tiers.size() != types ||
		!offsets_valid(_building_technology_tag_offsets) ||
		_building_technology_tag_offsets.back() != static_cast<int32_t>(
			_building_technology_tags.size()) ||
        !offsets_valid(_building_required_technology_tag_offsets) ||
        _building_required_technology_tag_offsets.back() != static_cast<int32_t>(
            _building_required_technology_tags.size()) || !offsets_valid(employee_offsets) ||
        _building_dependency_branch_offsets.size() != types + 1 ||
        _building_dependency_branch_offsets.empty() ||
        _building_dependency_branch_offsets.front() != 0 ||
        !std::is_sorted(_building_dependency_branch_offsets.begin(),
                        _building_dependency_branch_offsets.end()) ||
        _building_dependency_branch_technology_offsets.empty() ||
        _building_dependency_branch_technology_offsets.front() != 0 ||
        !std::is_sorted(_building_dependency_branch_technology_offsets.begin(),
                        _building_dependency_branch_technology_offsets.end()) ||
        _building_dependency_branch_technology_offsets.back() !=
            static_cast<int32_t>(_building_dependency_branch_technologies.size()) ||
        _building_dependency_branch_group_offsets.empty() ||
        _building_dependency_branch_group_offsets.front() != 0 ||
        !std::is_sorted(_building_dependency_branch_group_offsets.begin(),
                        _building_dependency_branch_group_offsets.end()) ||
        _building_dependency_branch_group_offsets.back() !=
            static_cast<int32_t>(_building_dependency_kinds.size()) ||
        _building_dependency_kinds.size() != _building_dependency_ids.size() ||
        _building_dependency_tag_offsets.size() != _building_dependency_kinds.size() + 1 ||
        _building_dependency_tag_offsets.empty() ||
        _building_dependency_tag_offsets.front() != 0 ||
        !std::is_sorted(_building_dependency_tag_offsets.begin(),
                        _building_dependency_tag_offsets.end()) ||
        _building_dependency_tag_offsets.back() !=
            static_cast<int32_t>(_building_dependency_tags.size()) ||
        !offsets_valid(construction_offsets) ||
        (!maintenance_offsets.empty() && !offsets_valid(maintenance_offsets)) ||
        (!maintenance_horizons.empty() && maintenance_horizons.size() != types) ||
        !offsets_valid(input_offsets) ||
        !offsets_valid(output_offsets) || !offsets_valid(resource_offsets) ||
        !offsets_valid(output_cost_share_offsets) ||
        !offsets_valid(generation_offsets) || generation_floors.size() != types ||
        !offsets_valid(condition_offsets)) {
        error = "building_type_column_size_mismatch";
        return false;
    }
    const std::vector<int32_t> employee_prof = packed_i32(catalog, "building_employee_profession_ids");
    const std::vector<int64_t> employee_slots = packed_i64(catalog, "building_employee_slots");
    const std::vector<int32_t> employee_wage_policies =
        packed_i32(catalog, "building_employee_wage_policies");
    const std::vector<int64_t> employee_reference_wages =
        packed_i64(catalog, "building_employee_reference_wages_per_day");
    const std::vector<int32_t> construction_goods = packed_i32(catalog, "building_construction_good_ids");
    const std::vector<int64_t> construction_qty = packed_i64(catalog, "building_construction_quantities");
    std::vector<int32_t> construction_candidate_offsets = packed_i32(
        catalog, "building_construction_candidate_offsets");
    std::vector<int32_t> construction_candidate_goods = packed_i32(
        catalog, "building_construction_candidate_good_ids");
    std::vector<int32_t> construction_candidate_efficiencies = packed_i32(
        catalog, "building_construction_candidate_efficiency_q16");
    // v1/v2 catalogs did not carry construction candidate CSR. Expand every
    // legacy fixed material into a one-candidate group before validation.
    if (construction_candidate_offsets.empty() &&
            construction_candidate_goods.empty() &&
            construction_candidate_efficiencies.empty()) {
        construction_candidate_offsets.push_back(0);
        for (const int32_t good : construction_goods) {
            construction_candidate_goods.push_back(good);
            construction_candidate_efficiencies.push_back(Q16_ONE);
            construction_candidate_offsets.push_back(
                static_cast<int32_t>(construction_candidate_goods.size()));
        }
    }
    const std::vector<int32_t> maintenance_goods = packed_i32(
        catalog, "building_maintenance_good_ids");
    const std::vector<int64_t> maintenance_qty = packed_i64(
        catalog, "building_maintenance_quantities");
    const std::vector<int32_t> input_goods = packed_i32(catalog, "building_input_good_ids");
    const std::vector<int64_t> input_qty = packed_i64(catalog, "building_input_quantities");
    std::vector<int32_t> input_required_q16 = packed_i32(catalog, "building_input_required_q16");
    if (input_required_q16.empty() && !input_goods.empty()) {
        input_required_q16.assign(input_goods.size(), static_cast<int32_t>(Q16_ONE));
    }
    const std::vector<int32_t> input_candidate_offsets =
        packed_i32(catalog, "building_input_candidate_offsets");
    const std::vector<int32_t> input_candidate_goods =
        packed_i32(catalog, "building_input_candidate_good_ids");
    const std::vector<int32_t> input_candidate_efficiencies =
        packed_i32(catalog, "building_input_candidate_efficiency_q16");
    const std::vector<int32_t> output_goods = packed_i32(catalog, "building_output_good_ids");
    const std::vector<int64_t> output_qty = packed_i64(catalog, "building_output_quantities");
    _building_output_cost_shares_q16 =
        packed_i32(catalog, "building_output_cost_shares_q16");
    const std::vector<int32_t> resource_ids = packed_i32(catalog, "building_production_resource_ids");
    const std::vector<int64_t> resource_qty = packed_i64(catalog, "building_production_resource_quantities");
    const std::vector<int32_t> resource_modes = packed_i32(catalog, "building_production_resource_modes");
    const std::vector<int32_t> resource_access_modes =
        packed_i32(catalog, "building_production_resource_access_modes");
    const std::vector<int32_t> generation_ids = packed_i32(catalog, "building_resource_generation_ids");
    const std::vector<int64_t> generation_qty = packed_i64(catalog, "building_resource_generation_quantities");
    const std::vector<int32_t> condition_opcodes = packed_i32(catalog, "building_condition_opcodes");
    const std::vector<int32_t> condition_signals = packed_i32(catalog, "building_condition_signals");
    const std::vector<int32_t> condition_compares = packed_i32(catalog, "building_condition_compares");
    const std::vector<int32_t> condition_refs = packed_i32(catalog, "building_condition_references");
    const std::vector<int64_t> condition_values = packed_i64(catalog, "building_condition_values");
    if (employee_offsets.back() != static_cast<int32_t>(employee_prof.size()) ||
        employee_slots.size() != employee_prof.size() ||
        employee_wage_policies.size() != employee_prof.size() ||
        employee_reference_wages.size() != employee_prof.size() ||
        construction_offsets.back() != static_cast<int32_t>(construction_goods.size()) ||
        construction_qty.size() != construction_goods.size() ||
        construction_candidate_offsets.size() != construction_goods.size() + 1 ||
        construction_candidate_offsets.empty() || construction_candidate_offsets.front() != 0 ||
        !std::is_sorted(construction_candidate_offsets.begin(),
                        construction_candidate_offsets.end()) ||
        construction_candidate_offsets.back() !=
            static_cast<int32_t>(construction_candidate_goods.size()) ||
        construction_candidate_efficiencies.size() != construction_candidate_goods.size() ||
        input_offsets.back() != static_cast<int32_t>(input_goods.size()) ||
        input_qty.size() != input_goods.size() ||
        input_required_q16.size() != input_goods.size() ||
        input_candidate_offsets.size() != input_goods.size() + 1 ||
        input_candidate_offsets.empty() || input_candidate_offsets.front() != 0 ||
        !std::is_sorted(input_candidate_offsets.begin(), input_candidate_offsets.end()) ||
        input_candidate_offsets.back() != static_cast<int32_t>(input_candidate_goods.size()) ||
        input_candidate_efficiencies.size() != input_candidate_goods.size() ||
        output_offsets.back() != static_cast<int32_t>(output_goods.size()) ||
        output_qty.size() != output_goods.size() ||
        output_cost_share_offsets.back() !=
            static_cast<int32_t>(_building_output_cost_shares_q16.size()) ||
        resource_offsets.back() != static_cast<int32_t>(resource_ids.size()) ||
        resource_qty.size() != resource_ids.size() || resource_modes.size() != resource_ids.size() ||
        resource_access_modes.size() != resource_ids.size() ||
        generation_offsets.back() != static_cast<int32_t>(generation_ids.size()) ||
        generation_qty.size() != generation_ids.size() ||
        condition_offsets.back() != static_cast<int32_t>(condition_opcodes.size()) ||
        condition_signals.size() != condition_opcodes.size() ||
        condition_compares.size() != condition_opcodes.size() ||
        condition_refs.size() != condition_opcodes.size() ||
        condition_values.size() != condition_opcodes.size()) {
        error = "building_child_column_size_mismatch";
        return false;
    }
    const size_t dependency_branch_count =
        _building_dependency_branch_technologies.size() > 0
            ? static_cast<size_t>(_building_dependency_branch_technology_offsets.size() - 1)
            : 0;
    if (_building_dependency_branch_offsets.back() !=
            static_cast<int32_t>(dependency_branch_count) ||
        _building_dependency_branch_group_offsets.size() != dependency_branch_count + 1) {
        error = "building_dependency_branch_shape_invalid";
        return false;
    }
    for (size_t branch = 0; branch < dependency_branch_count; ++branch) {
        if (_building_dependency_branch_technology_offsets[branch] >=
                _building_dependency_branch_technology_offsets[branch + 1] ||
            _building_dependency_branch_group_offsets[branch] >
                _building_dependency_branch_group_offsets[branch + 1]) {
            error = "building_dependency_branch_empty";
            return false;
        }
    }
    for (size_t group = 0; group < _building_dependency_kinds.size(); ++group) {
        const int32_t kind = _building_dependency_kinds[group];
        const int32_t id = _building_dependency_ids[group];
        if (kind < 1 || kind > 5 ||
            _building_dependency_tag_offsets[group] >=
                _building_dependency_tag_offsets[group + 1] ||
            (kind <= 3 && (id < 0 || id >= static_cast<int32_t>(_good_ids.size()))) ||
            (kind >= 4 && (id < 0 || id >= static_cast<int32_t>(_resource_ids.size())))) {
            error = "building_dependency_group_invalid";
            return false;
        }
        for (int32_t tag = _building_dependency_tag_offsets[group];
             tag < _building_dependency_tag_offsets[group + 1]; ++tag) {
            if (_building_dependency_tags[static_cast<size_t>(tag)] < 0 ||
                _building_dependency_tags[static_cast<size_t>(tag)] >=
                    static_cast<int32_t>(_technology_ids.size())) {
                error = "building_dependency_technology_invalid";
                return false;
            }
        }
    }
    _building_employee_roles.resize(employee_prof.size());
    for (size_t i = 0; i < employee_prof.size(); ++i) {
        if (employee_prof[i] < 0 || employee_prof[i] >= static_cast<int32_t>(_profession_ids.size()) ||
            employee_slots[i] <= 0 || employee_wage_policies[i] < 0 ||
            employee_wage_policies[i] > 2 || employee_reference_wages[i] < 0 ||
            (employee_wage_policies[i] != 0 && employee_reference_wages[i] <= 0)) {
            error = "building_employee_role_invalid";
            return false;
        }
        _building_employee_roles[i] = {employee_prof[i], employee_slots[i],
                                       employee_wage_policies[i],
                                       employee_reference_wages[i]};
    }
    auto compile_goods = [&](const std::vector<int32_t> &ids, const std::vector<int64_t> &qty,
                             std::vector<GoodAmount> &dst, const char *reason) {
        dst.resize(ids.size());
        for (size_t i = 0; i < ids.size(); ++i) {
            if (ids[i] < 0 || ids[i] >= static_cast<int32_t>(_good_ids.size()) || qty[i] <= 0) {
                error = reason;
                return false;
            }
            dst[i] = {ids[i], qty[i]};
        }
        return true;
    };
    if (!compile_goods(construction_goods, construction_qty, _building_construction_goods,
                       "building_construction_good_invalid") ||
        !compile_goods(output_goods, output_qty, _building_outputs,
                       "building_output_good_invalid")) return false;
    if (maintenance_offsets.empty()) {
        _building_maintenance_author_offsets.assign(types + 1, 0);
        _building_maintenance_author_goods.clear();
    } else {
        if (maintenance_offsets.back() != static_cast<int32_t>(maintenance_goods.size()) ||
            maintenance_goods.size() != maintenance_qty.size()) {
            error = "building_maintenance_column_size_mismatch";
            return false;
        }
        if (!compile_goods(maintenance_goods, maintenance_qty,
                           _building_maintenance_author_goods,
                           "building_maintenance_good_invalid")) return false;
        _building_maintenance_author_offsets = maintenance_offsets;
    }
    for (GoodAmount &output : _building_outputs) {
        output.quantity = mul_div_sat(output.quantity,
            _building_output_efficiency_q16, Q16_ONE, _saturation_count);
    }
    _building_inputs.resize(input_goods.size());
    _building_input_candidates.resize(input_candidate_goods.size());
    for (size_t i = 0; i < input_goods.size(); ++i) {
        if (input_goods[i] < 0 || input_goods[i] >= static_cast<int32_t>(_good_ids.size()) ||
            input_qty[i] <= 0 || input_candidate_offsets[i] >= input_candidate_offsets[i + 1] ||
            input_required_q16[i] < 0 || input_required_q16[i] > Q16_ONE) {
            error = "building_input_good_invalid";
            return false;
        }
        _building_inputs[i] = {input_goods[i], input_qty[i], input_candidate_offsets[i],
                               input_candidate_offsets[i + 1] - input_candidate_offsets[i],
                               input_required_q16[i]};
    }
    for (size_t i = 0; i < input_candidate_goods.size(); ++i) {
        if (input_candidate_goods[i] < 0 ||
            input_candidate_goods[i] >= static_cast<int32_t>(_good_ids.size()) ||
            input_candidate_efficiencies[i] <= 0 ||
            input_candidate_efficiencies[i] > Q16_ONE * 4) {
            error = "building_input_candidate_invalid";
            return false;
        }
        _building_input_candidates[i] = {
            input_candidate_goods[i], input_candidate_efficiencies[i]};
    }
    _building_resources.resize(resource_ids.size());
    for (size_t i = 0; i < resource_ids.size(); ++i) {
        if (resource_ids[i] < 0 || resource_ids[i] >= static_cast<int32_t>(_resource_ids.size()) ||
            resource_qty[i] <= 0 || resource_modes[i] < 0 || resource_modes[i] > 1 ||
            resource_access_modes[i] != 0) {
            error = "building_production_resource_invalid";
            return false;
        }
        _building_resources[i] = {resource_ids[i], resource_qty[i], resource_modes[i],
                                  resource_access_modes[i]};
    }
    _building_resource_generation.resize(generation_ids.size());
    for (size_t i = 0; i < generation_ids.size(); ++i) {
        if (generation_ids[i] < 0 ||
            generation_ids[i] >= static_cast<int32_t>(_resource_ids.size()) ||
            generation_qty[i] <= 0) {
            error = "building_resource_generation_invalid";
            return false;
        }
        _building_resource_generation[i] = {generation_ids[i], generation_qty[i], 0, 0};
    }
    _building_conditions.resize(condition_opcodes.size());
    for (size_t i = 0; i < condition_opcodes.size(); ++i) {
        if (condition_opcodes[i] < 1 || condition_opcodes[i] > 4 ||
            condition_compares[i] < 0 || condition_compares[i] > 5) {
            error = "building_condition_token_invalid";
            return false;
        }
        _building_conditions[i] = {condition_opcodes[i], condition_signals[i],
                                   condition_compares[i], condition_refs[i],
                                   condition_values[i]};
    }
    _building_types.resize(types);
    std::vector<std::pair<int32_t, int32_t>> upgrade_pairs;
    upgrade_pairs.reserve(types);
    for (size_t i = 0; i < types; ++i) {
        const int32_t family = _building_upgrade_family_indices[i];
        const int32_t tier = _building_upgrade_tiers[i];
        if (family < -1 || family >= static_cast<int32_t>(_building_upgrade_family_ids.size()) ||
            (family < 0 && tier != 0) || (family >= 0 && tier <= 0)) {
            error = "building_upgrade_entry_invalid";
            return false;
        }
        if (family >= 0) upgrade_pairs.emplace_back(family, tier);
        // Route B: building_kind 2 == service (merchant post): no output, no
        // resource, behavior_id must be none(0). Kinds 0 (collector) and 1
        // (industrial) keep their original output/resource/behavior coupling.
        const bool kind_is_service = _building_kinds[i] == 2;
        if (owner_prof[i] < 0 || owner_prof[i] >= static_cast<int32_t>(_profession_ids.size()) ||
            owner_slots[i] <= 0 || wages[i] < 0 || construction_days[i] < 0 ||
            _building_kinds[i] < 0 || _building_kinds[i] > 2 ||
            _building_economic_sectors[i] < 0 ||
            _building_economic_sectors[i] >= 5 ||
			climate_profile_indices[i] < -1 ||
			climate_profile_indices[i] >= static_cast<int32_t>(climate_count) ||
            behavior_ids[i] < 0 || behavior_ids[i] > 2 || behavior_versions[i] != 1 ||
            (!kind_is_service && output_offsets[i] == output_offsets[i + 1]) ||
			(kind_is_service && output_offsets[i] != output_offsets[i + 1]) ||
			(_building_kinds[i] == 0 && resource_offsets[i] == resource_offsets[i + 1]) ||
			(_building_kinds[i] != 0 && resource_offsets[i] != resource_offsets[i + 1]) ||
			(_building_kinds[i] == 0 && behavior_ids[i] == 0) ||
			(_building_kinds[i] == 1 && behavior_ids[i] != 0) ||
			(kind_is_service && behavior_ids[i] != 0) ||
            target_margins[i] < 0 || target_margins[i] > Q16_ONE * 4 ||
            supply_elasticities[i] < 0 || supply_elasticities[i] > Q16_ONE * 4 ||
            (output_cost_share_offsets[i + 1] - output_cost_share_offsets[i] != 0 &&
             output_cost_share_offsets[i + 1] - output_cost_share_offsets[i] !=
                 output_offsets[i + 1] - output_offsets[i]) ||
            generation_floors[i] < 0 || generation_floors[i] > Q16_ONE ||
            (behavior_ids[i] == 2 && generation_offsets[i] == generation_offsets[i + 1]) ||
            (behavior_ids[i] != 2 && generation_offsets[i] != generation_offsets[i + 1])) {
            error = "building_type_entry_invalid";
            return false;
        }
        if (owner_prof[i] == _merchant_profession_id && !kind_is_service) {
            // Route B: a service merchant post (kind 2) is a valid
            // merchant-owned building. Its no-output/no-resource/behavior-none
            // shape is already enforced above, so it bypasses the bullion
            // collector requirement. Non-service merchant buildings must still
            // be a matching gold/silver collector.
            const bool one_output = output_offsets[i + 1] - output_offsets[i] == 1;
            const bool one_resource = resource_offsets[i + 1] - resource_offsets[i] == 1;
            const int32_t output_good = one_output ? output_goods[output_offsets[i]] : -1;
            const int32_t resource = one_resource ? resource_ids[resource_offsets[i]] : -1;
            const bool gold = output_good >= 0 && _good_ids[output_good] == "gold" &&
                resource >= 0 && _resource_ids[resource] == "gold_ore";
            const bool silver = output_good >= 0 && _good_ids[output_good] == "silver" &&
                resource >= 0 && _resource_ids[resource] == "silver_ore";
            if (_building_kinds[i] != 0 || behavior_ids[i] != 1 ||
                !one_output || !one_resource ||
                generation_offsets[i] != generation_offsets[i + 1] ||
                resource_modes[resource_offsets[i]] != 0 || (!gold && !silver)) {
                error = "merchant_building_must_be_matching_bullion_collector";
                return false;
            }
        }
        int64_t explicit_share_sum = 0;
        for (int32_t s = output_cost_share_offsets[i];
             s < output_cost_share_offsets[i + 1]; ++s) {
            if (_building_output_cost_shares_q16[s] < 0) {
                error = "building_output_cost_share_invalid";
                return false;
            }
            explicit_share_sum += _building_output_cost_shares_q16[s];
        }
        if (output_cost_share_offsets[i + 1] > output_cost_share_offsets[i] &&
            explicit_share_sum != Q16_ONE) {
            error = "building_output_cost_share_sum_invalid";
            return false;
        }
        _building_types[i] = {
			_building_kinds[i], _building_economic_sectors[i], climate_profile_indices[i], family, tier,
            owner_prof[i], owner_slots[i], wages[i],
            employee_offsets[i], employee_offsets[i + 1] - employee_offsets[i],
            construction_offsets[i], construction_offsets[i + 1] - construction_offsets[i],
            0, 0,
            maintenance_horizons.empty() ? 0 : std::max(0, maintenance_horizons[i]),
            input_offsets[i], input_offsets[i + 1] - input_offsets[i],
            output_offsets[i], output_offsets[i + 1] - output_offsets[i],
            resource_offsets[i], resource_offsets[i + 1] - resource_offsets[i],
            generation_offsets[i], generation_offsets[i + 1] - generation_offsets[i],
            generation_floors[i],
            condition_offsets[i], condition_offsets[i + 1] - condition_offsets[i],
            construction_days[i], behavior_ids[i], behavior_versions[i],
            target_margins[i], supply_elasticities[i], output_cost_share_offsets[i],
            output_cost_share_offsets[i + 1] - output_cost_share_offsets[i]};
    }
    resolve_building_maintenance_csr();
    _building_type_market_signal_goods.clear();
    _building_type_labor_signal_professions.clear();
    _building_type_market_signal_goods.reserve(
        _building_input_candidates.size() + _building_outputs.size());
    _building_type_labor_signal_professions.reserve(
        _building_employee_roles.size());
    std::vector<int32_t> baked_keys;
    for (BuildingType &type : _building_types) {
        baked_keys.clear();
        for (int32_t input_index = type.input_begin;
             input_index < type.input_begin + type.input_count; ++input_index) {
            const ProductionInput &input = _building_inputs[input_index];
            for (int32_t candidate = input.candidate_begin;
                 candidate < input.candidate_begin + input.candidate_count;
                 ++candidate) {
                baked_keys.push_back(
                    _building_input_candidates[candidate].good_id);
            }
        }
        for (int32_t output = type.output_begin;
             output < type.output_begin + type.output_count; ++output) {
            baked_keys.push_back(_building_outputs[output].good_id);
        }
        for (int32_t item = type.construction_begin;
             item < type.construction_begin + type.construction_count; ++item) {
            baked_keys.push_back(_building_construction_goods[item].good_id);
        }
        for (int32_t item = type.maintenance_begin;
             item < type.maintenance_begin + type.maintenance_count; ++item) {
            baked_keys.push_back(_building_maintenance_goods[item].good_id);
        }
        std::sort(baked_keys.begin(), baked_keys.end());
        baked_keys.erase(std::unique(baked_keys.begin(), baked_keys.end()),
                         baked_keys.end());
        type.market_signal_begin = static_cast<int32_t>(
            _building_type_market_signal_goods.size());
        type.market_signal_count = static_cast<int32_t>(baked_keys.size());
        _building_type_market_signal_goods.insert(
            _building_type_market_signal_goods.end(), baked_keys.begin(),
            baked_keys.end());

        baked_keys.clear();
        for (int32_t role = type.employee_begin;
             role < type.employee_begin + type.employee_count; ++role) {
            baked_keys.push_back(_building_employee_roles[role].profession_id);
        }
        std::sort(baked_keys.begin(), baked_keys.end());
        baked_keys.erase(std::unique(baked_keys.begin(), baked_keys.end()),
                         baked_keys.end());
        type.labor_signal_begin = static_cast<int32_t>(
            _building_type_labor_signal_professions.size());
        type.labor_signal_count = static_cast<int32_t>(baked_keys.size());
        _building_type_labor_signal_professions.insert(
            _building_type_labor_signal_professions.end(), baked_keys.begin(),
            baked_keys.end());
    }
    {
        const std::vector<int32_t> semantic_offsets =
            packed_i32(catalog, "building_semantic_tag_offsets");
        const std::vector<std::string> semantic_tags =
            packed_strings(catalog, "building_semantic_tags");
        if (!semantic_offsets.empty()) {
            if (semantic_offsets.size() != types + 1 ||
                semantic_offsets.front() != 0 ||
                !std::is_sorted(semantic_offsets.begin(), semantic_offsets.end()) ||
                semantic_offsets.back() !=
                    static_cast<int32_t>(semantic_tags.size())) {
                error = "building_semantic_tag_column_size_mismatch";
                return false;
            }
            for (size_t type = 0; type < types; ++type) {
                uint32_t mask = _building_types[type].kit_role_mask;
                for (int32_t tag = semantic_offsets[type];
                     tag < semantic_offsets[type + 1]; ++tag) {
                    const std::string &name = semantic_tags[static_cast<size_t>(tag)];
                    if (name == "starter.trade")
                        mask |= BUILDING_KIT_ROLE_TRADE;
                    else if (name == "starter.construction")
                        mask |= BUILDING_KIT_ROLE_CONSTRUCTION;
                    else if (name == "starter.clothing_input")
                        mask |= BUILDING_KIT_ROLE_CLOTHING_INPUT;
                    else if (name == "starter.clothing")
                        mask |= BUILDING_KIT_ROLE_CLOTHING;
                }
                _building_types[type].kit_role_mask = mask;
            }
        }
        for (size_t type = 0; type < types; ++type) {
            const BuildingType &building = _building_types[type];
            bool survival_food = false;
            for (int32_t output = building.output_begin;
                 output < building.output_begin + building.output_count; ++output) {
                const int32_t good = _building_outputs[output].good_id;
                if (good >= 0 &&
                    good < static_cast<int32_t>(_survival_food_good_mask.size()) &&
                    _survival_food_good_mask[static_cast<size_t>(good)] != 0) {
                    survival_food = true;
                    break;
                }
            }
            if (survival_food)
                _building_types[type].kit_role_mask |=
                    BUILDING_KIT_ROLE_SURVIVAL_FOOD;
        }
    }
    _investment_good_type_offsets.assign(_good_ids.size() + 1, 0);
    for (int32_t type_id = 0;
         type_id < static_cast<int32_t>(_building_types.size()); ++type_id) {
        const BuildingType &type = _building_types[type_id];
        baked_keys.clear();
        for (int32_t output = type.output_begin;
             output < type.output_begin + type.output_count; ++output) {
            baked_keys.push_back(_building_outputs[output].good_id);
        }
        std::sort(baked_keys.begin(), baked_keys.end());
        baked_keys.erase(std::unique(baked_keys.begin(), baked_keys.end()),
                         baked_keys.end());
        for (const int32_t good : baked_keys) {
            if (good >= 0 && good < static_cast<int32_t>(_good_ids.size()))
                ++_investment_good_type_offsets[good + 1];
        }
    }
    for (size_t good = 0; good < _good_ids.size(); ++good)
        _investment_good_type_offsets[good + 1] +=
            _investment_good_type_offsets[good];
    _investment_good_type_indices.assign(
        static_cast<size_t>(_investment_good_type_offsets.back()), -1);
    std::vector<int32_t> investment_good_cursors(
        _investment_good_type_offsets.begin(),
        _investment_good_type_offsets.end() - 1);
    for (int32_t type_id = 0;
         type_id < static_cast<int32_t>(_building_types.size()); ++type_id) {
        const BuildingType &type = _building_types[type_id];
        baked_keys.clear();
        for (int32_t output = type.output_begin;
             output < type.output_begin + type.output_count; ++output) {
            baked_keys.push_back(_building_outputs[output].good_id);
        }
        std::sort(baked_keys.begin(), baked_keys.end());
        baked_keys.erase(std::unique(baked_keys.begin(), baked_keys.end()),
                         baked_keys.end());
        for (const int32_t good : baked_keys) {
            if (good >= 0 && good < static_cast<int32_t>(_good_ids.size()))
                _investment_good_type_indices[investment_good_cursors[good]++] =
                    type_id;
        }
    }
    _investment_type_stamp.assign(_building_types.size(), 0);
    _investment_good_stamp.assign(_good_ids.size(), 0);
    _investment_review_stamp_generation = 0;
    _startup_monetary_good_indices.clear();
    _startup_monetary_good_indices.reserve(_good_ids.size());
    for (int32_t good = 0; good < static_cast<int32_t>(_good_ids.size()); ++good) {
        if (_good_monetary_issue_values[good] > 0)
            _startup_monetary_good_indices.push_back(good);
    }
    std::sort(upgrade_pairs.begin(), upgrade_pairs.end());
    if (std::adjacent_find(upgrade_pairs.begin(), upgrade_pairs.end()) != upgrade_pairs.end()) {
        error = "building_upgrade_family_tier_duplicate";
        return false;
    }
    _building_construction_candidate_offsets = construction_candidate_offsets;
    _building_construction_candidates.resize(construction_candidate_goods.size());
    for (size_t i = 0; i < construction_candidate_goods.size(); ++i) {
        if (construction_candidate_goods[i] < 0 ||
            construction_candidate_goods[i] >= static_cast<int32_t>(_good_ids.size()) ||
            construction_candidate_efficiencies[i] <= 0 ||
            construction_candidate_efficiencies[i] > Q16_ONE * 4) {
            error = "building_construction_candidate_invalid";
            return false;
        }
        _building_construction_candidates[i] = {
            construction_candidate_goods[i], construction_candidate_efficiencies[i]};
    }
    for (size_t group = 0; group < _building_construction_goods.size(); ++group) {
        const int32_t begin = _building_construction_candidate_offsets[group];
        const int32_t end = _building_construction_candidate_offsets[group + 1];
        if (begin >= end) {
            error = "building_construction_candidate_group_empty";
            return false;
        }
        bool preferred_seen = false;
        for (int32_t candidate = begin; candidate < end; ++candidate) {
            if (_building_construction_candidates[candidate].good_id ==
                    _building_construction_goods[group].good_id) {
                preferred_seen = true;
                break;
            }
        }
        if (!preferred_seen) {
            error = "building_construction_preferred_candidate_missing";
            return false;
        }
    }
    return true;
}


} // namespace pk
