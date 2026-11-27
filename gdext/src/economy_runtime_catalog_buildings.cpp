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
    _abundant_mountain_landform_id = -1;
    _abundant_forest_terrain_id = -1;
    {
        const auto lookup_id = [](const std::vector<std::string> &ids,
                                  const char *wanted) {
            const auto found = std::find(ids.begin(), ids.end(), wanted);
            return found != ids.end() && *found == wanted
                ? static_cast<int32_t>(found - ids.begin()) : -1;
        };
        _abundant_mountain_landform_id = lookup_id(
            _modifier_landform_ids, "mountain");
        // The design's "mountain/forest" means the forest terrain row, not
        // landform.forest (which is not a LandformType.LF member).
        _abundant_forest_terrain_id = lookup_id(
            _modifier_terrain_ids, "forest");
        if ((_abundant_mountain_landform_id < 0 ||
             _abundant_forest_terrain_id < 0) &&
            !_catalog_geography_lookup_warning_emitted) {
            std::fprintf(stderr,
                "[economy-x7b] abundant mountain/forest ids missing "
                "(landform=mountain terrain=forest); metric 103 stays 0\n");
            _catalog_geography_lookup_warning_emitted = true;
        }
    }
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
    _resource_climate_temp_opt_q16 =
        packed_i32(catalog, "building_resource_climate_temp_opt_q16");
    _resource_climate_temp_tol_q16 =
        packed_i32(catalog, "building_resource_climate_temp_tol_q16");
    _resource_climate_moisture_opt_q16 =
        packed_i32(catalog, "building_resource_climate_moisture_opt_q16");
    _resource_climate_moisture_tol_q16 =
        packed_i32(catalog, "building_resource_climate_moisture_tol_q16");
    _resource_runtime_fit_weight_q16 =
        packed_i32(catalog, "building_resource_runtime_fit_weight_q16");
    _resource_temperature_signal =
        packed_i32(catalog, "building_resource_temperature_signal");
    _resource_moisture_signal =
        packed_i32(catalog, "building_resource_moisture_signal");
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
        _resource_climate_temp_opt_q16.size() != resource_count ||
        _resource_climate_temp_tol_q16.size() != resource_count ||
        _resource_climate_moisture_opt_q16.size() != resource_count ||
        _resource_climate_moisture_tol_q16.size() != resource_count ||
        _resource_runtime_fit_weight_q16.size() != resource_count ||
        _resource_temperature_signal.size() != resource_count ||
        _resource_moisture_signal.size() != resource_count ||
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
    const std::vector<int32_t> construction_days = packed_i32(catalog, "building_construction_days");
    const std::vector<int32_t> behavior_ids = packed_i32(catalog, "building_behavior_ids");
    const std::vector<int32_t> behavior_versions = packed_i32(catalog, "building_behavior_versions");
    const std::vector<int32_t> target_margins =
        packed_i32(catalog, "building_target_operating_margin_q16");
    const std::vector<int32_t> supply_elasticities =
        packed_i32(catalog, "building_supply_price_elasticity_q16");
	_building_kinds = packed_i32(catalog, "building_kinds");
    // Military v1: kind 3 == state-owned. `building_state_roles` carries the
    // authored role and is optional (legacy catalogs have no state buildings).
    std::vector<int32_t> building_state_roles = packed_i32(
        catalog, "building_state_roles");
    if (building_state_roles.empty())
        building_state_roles.assign(types, 0);
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
    if (owner_prof.size() != types || owner_slots.size() != types ||
        construction_days.size() != types || behavior_ids.size() != types ||
		behavior_versions.size() != types || target_margins.size() != types ||
        supply_elasticities.size() != types || _building_kinds.size() != types ||
        building_state_roles.size() != types ||
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
#include "economy_runtime_catalog_building_columns.inc"
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
        // resource, behavior_id must be none(0). Kind 3 == state-owned: exactly
        // the same no-output/no-resource/behavior-none shape (its effect comes
        // from the Military side reading the lot), an authored state_role, and
        // no state role anywhere else. Kinds 0 (collector) and 1 (industrial)
        // keep their original output/resource/behavior coupling.
        const bool kind_is_service = _building_kinds[i] == 2 ||
            _building_kinds[i] == 3;
        const bool kind_is_state = _building_kinds[i] == 3;
        const int32_t state_role = building_state_roles[i];
        if (kind_is_state) {
            if (state_role < STATE_ROLE_BARRACKS ||
                state_role > STATE_ROLE_WAR_COLLEGE) {
                error = "state_building_role_invalid";
                return false;
            }
        } else if (state_role != STATE_ROLE_NONE) {
            error = "state_building_role_on_non_state_type";
            return false;
        }
        // State buildings are payroll posts: at least one employee role, and
        // only state-service professions may be staffed into them.
        if (kind_is_state) {
            if (employee_offsets[i + 1] <= employee_offsets[i]) {
                error = "state_building_without_employee_role";
                return false;
            }
            for (int32_t role = employee_offsets[i];
                 role < employee_offsets[i + 1]; ++role) {
                const int32_t profession = employee_prof[static_cast<size_t>(role)];
                if (profession < 0 ||
                    static_cast<size_t>(profession) >=
                        _profession_state_service_only.size() ||
                    _profession_state_service_only[
                        static_cast<size_t>(profession)] == 0) {
                    error = "state_building_role_requires_state_service_profession";
                    return false;
                }
            }
        }
        if (owner_prof[i] < 0 || owner_prof[i] >= static_cast<int32_t>(_profession_ids.size()) ||
            owner_slots[i] <= 0 || construction_days[i] < 0 ||
            _building_kinds[i] < 0 || _building_kinds[i] > 3 ||
            _building_economic_sectors[i] < 0 ||
            _building_economic_sectors[i] >= BUILDING_SECTOR_COUNT ||
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
			_building_kinds[i], state_role, _building_economic_sectors[i],
            climate_profile_indices[i], family, tier,
            owner_prof[i], owner_slots[i],
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
