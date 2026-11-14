# Pure building catalog compiler. It owns only temporary arrays while compiling.
extends RefCounted

const BuildingPlacementScript = preload(
	"res://scripts/economy/building_placement_catalog.gd")

const ResourceRegistryScript = preload("res://scripts/data/resource_profile_registry.gd")
const Q16_ONE := 65536
const UNEMPLOYED_PROFESSION_ID := "unemployed"
const BUILDING_SECTOR_IDS := [
	"agriculture", "extractive", "manufacturing", "energy", "knowledge",
	"military",
]
const BUILDING_KIND_INDICES := {
	"collector": 0,
	"industrial": 1,
	"service": 2,
	"state": 3,
}

static func compile(
		profiles: Array, climate_profiles: Array, profession_index: Dictionary,
		good_index: Dictionary, good_storage_modes: PackedInt32Array,
		good_monetary_issue_values: PackedInt64Array,
		good_substitution_category_offsets: PackedInt32Array,
		good_substitution_category_ids: PackedStringArray,
		good_quality_levels: PackedInt32Array,
		good_efficiencies_q16: PackedInt32Array,
		profession_state_service_only: PackedInt32Array = PackedInt32Array()) -> Dictionary:
	var progression_columns := BuildingPlacementScript.validate_building_progression_profiles(profiles)
	if not bool(progression_columns.get("ok", false)):
		return progression_columns
	var climate_profile_ids := PackedStringArray()
	var climate_temperature_opt_q16 := PackedInt32Array()
	var climate_temperature_tolerance_q16 := PackedInt32Array()
	var climate_water_opt_q16 := PackedInt32Array()
	var climate_water_tolerance_q16 := PackedInt32Array()
	var climate_exposure_q16 := PackedInt32Array()
	var climate_floor_q16 := PackedInt32Array()
	var climate_profile_index := {}
	for climate in climate_profiles:
		var climate_id := String(climate.id).strip_edges()
		if climate_id == "" or climate_profile_index.has(climate_id) \
				or float(climate.temperature_opt) < 0.0 or float(climate.temperature_opt) > 1.0 \
				or float(climate.water_opt) < 0.0 or float(climate.water_opt) > 1.0 \
				or float(climate.temperature_tolerance) <= 0.0 \
				or float(climate.temperature_tolerance) > 1.0 \
				or float(climate.water_tolerance) <= 0.0 \
				or float(climate.water_tolerance) > 1.0 \
				or int(climate.exposure_q16) < 0 or int(climate.exposure_q16) > Q16_ONE \
				or int(climate.floor_q16) < 0 or int(climate.floor_q16) > Q16_ONE:
			return {"ok": false, "reason": "invalid production climate profile: %s" % climate_id}
		climate_profile_index[climate_id] = climate_profile_ids.size()
		climate_profile_ids.append(climate_id)
		climate_temperature_opt_q16.append(roundi(float(climate.temperature_opt) * Q16_ONE))
		climate_temperature_tolerance_q16.append(roundi(float(climate.temperature_tolerance) * Q16_ONE))
		climate_water_opt_q16.append(roundi(float(climate.water_opt) * Q16_ONE))
		climate_water_tolerance_q16.append(roundi(float(climate.water_tolerance) * Q16_ONE))
		climate_exposure_q16.append(int(climate.exposure_q16))
		climate_floor_q16.append(int(climate.floor_q16))
	var good_count := good_quality_levels.size()
	if good_efficiencies_q16.size() != good_count \
			or good_substitution_category_offsets.size() != good_count + 1 \
			or good_substitution_category_offsets[0] != 0 \
			or good_substitution_category_offsets[-1] != good_substitution_category_ids.size():
		return {"ok": false, "reason": "good substitution category columns mismatch"}
	var category_good_indices := {}
	for good_idx in range(good_count):
		var begin := int(good_substitution_category_offsets[good_idx])
		var end := int(good_substitution_category_offsets[good_idx + 1])
		if begin < 0 or end <= begin or end > good_substitution_category_ids.size():
			return {"ok": false, "reason": "good substitution category offsets invalid"}
		for category_edge in range(begin, end):
			var category_id := String(good_substitution_category_ids[category_edge])
			if category_id == "":
				return {"ok": false, "reason": "empty good substitution category"}
			if not category_good_indices.has(category_id):
				category_good_indices[category_id] = PackedInt32Array()
			var members: PackedInt32Array = category_good_indices[category_id]
			members.append(good_idx)
			category_good_indices[category_id] = members
	var used_resource_ids := {}
	for profile in profiles:
		for resource_id in profile.resource_ids:
			used_resource_ids[String(resource_id)] = true
		for resource_id in profile.resource_generation_ids:
			used_resource_ids[String(resource_id)] = true
		for i in range(profile.condition_signals.size()):
			if int(profile.condition_signals[i]) == 10 and i < profile.condition_reference_ids.size():
				used_resource_ids[String(profile.condition_reference_ids[i])] = true
	var resources: Array = ResourceRegistryScript.ordered().duplicate()
	resources.sort_custom(func(a, b) -> bool: return String(a.id) < String(b.id))
	var resource_ids := PackedStringArray()
	var resource_reserve_slots := PackedStringArray()
	var resource_extra_slots := PackedStringArray()
	var resource_index := {}
	var resource_gen_base := PackedInt64Array()
	var resource_gen_temp := PackedInt64Array()
	var resource_gen_moisture := PackedInt64Array()
	var resource_gen_self := PackedInt64Array()
	var resource_decay_base := PackedInt64Array()
	var resource_decay_temp := PackedInt64Array()
	var resource_decay_moisture := PackedInt64Array()
	var resource_decay_self_q16 := PackedInt32Array()
	var resource_ecology_capacity := PackedInt64Array()
	var resource_ecology_growth_q16 := PackedInt32Array()
	var resource_temp_lo_q16 := PackedInt32Array()
	var resource_temp_hi_q16 := PackedInt32Array()
	var resource_climate_temp_opt_q16 := PackedInt32Array()
	var resource_climate_temp_tol_q16 := PackedInt32Array()
	var resource_climate_moisture_opt_q16 := PackedInt32Array()
	var resource_climate_moisture_tol_q16 := PackedInt32Array()
	var resource_runtime_fit_weight_q16 := PackedInt32Array()
	var resource_temperature_signal := PackedInt32Array()
	var resource_moisture_signal := PackedInt32Array()
	var resource_semantic_tag_offsets := PackedInt32Array([0])
	var resource_semantic_tags := PackedStringArray()
	var resource_technology_tag_offsets := PackedInt32Array([0])
	var resource_technology_tags := PackedStringArray()
	for resource in resources:
		var stable_id := String(resource.id)
		if not used_resource_ids.has(stable_id):
			continue
		var reserve_slot: String = ResourceRegistryScript.reserve_cpp_name(resource)
		var extra_slot: String = ResourceRegistryScript.extra_change_cpp_name(resource)
		if stable_id == "" or reserve_slot == "" or extra_slot == "" or resource_index.has(stable_id):
			return {"ok": false, "reason": "invalid building resource: %s" % stable_id}
		resource_index[stable_id] = resource_ids.size()
		resource_ids.append(stable_id)
		resource_reserve_slots.append(reserve_slot)
		resource_extra_slots.append(extra_slot)
		var quantity_scale := ResourceRegistryScript.CELL_AREA_RESOURCE_SCALE * 1000.0
		resource_gen_base.append(roundi(float(resource.gen_base) * quantity_scale))
		resource_gen_temp.append(roundi(float(resource.gen_temp) * quantity_scale))
		resource_gen_moisture.append(roundi(float(resource.gen_moisture) * quantity_scale))
		resource_gen_self.append(roundi(float(resource.gen_self) * quantity_scale))
		resource_decay_base.append(roundi(float(resource.decay_base) * quantity_scale))
		resource_decay_temp.append(roundi(float(resource.decay_temp) * quantity_scale))
		resource_decay_moisture.append(roundi(float(resource.decay_moisture) * quantity_scale))
		resource_decay_self_q16.append(roundi(float(resource.decay_self) * Q16_ONE))
		resource_ecology_capacity.append(roundi(float(resource.ecology_capacity) * quantity_scale))
		resource_ecology_growth_q16.append(roundi(float(resource.ecology_growth_rate) * Q16_ONE))
		resource_temp_lo_q16.append(roundi(float(resource.temp_lo) * Q16_ONE))
		resource_temp_hi_q16.append(roundi(float(resource.temp_hi) * Q16_ONE))
		resource_climate_temp_opt_q16.append(roundi(float(resource.climate_temp_opt) * Q16_ONE))
		resource_climate_temp_tol_q16.append(roundi(float(resource.climate_temp_tol) * Q16_ONE))
		resource_climate_moisture_opt_q16.append(roundi(float(resource.climate_moisture_opt) * Q16_ONE))
		resource_climate_moisture_tol_q16.append(roundi(float(resource.climate_moisture_tol) * Q16_ONE))
		resource_runtime_fit_weight_q16.append(roundi(
			float(resource.runtime_climate_fit_weight) * Q16_ONE))
		resource_temperature_signal.append(
			1 if String(resource.runtime_temperature_signal) == "mean_30d" else 0)
		resource_moisture_signal.append(
			1 if String(resource.runtime_moisture_signal) == "plant_available_water" else 0)
		var normalized_resource_tags := PackedStringArray()
		for tag in resource.semantic_tags:
			var normalized := String(tag).strip_edges()
			if normalized.is_empty() or normalized_resource_tags.has(normalized):
				return {"ok": false, "reason": "invalid resource semantic tag: %s" % stable_id}
			normalized_resource_tags.append(normalized)
		normalized_resource_tags.sort()
		resource_semantic_tags.append_array(normalized_resource_tags)
		resource_semantic_tag_offsets.append(resource_semantic_tags.size())
		for tag in resource.discovery_technology_tags:
			var normalized_technology_tag := String(tag).strip_edges()
			if normalized_technology_tag.is_empty():
				return {"ok": false, "reason": "resource_technology_binding_empty",
					"id": stable_id}
			resource_technology_tags.append(normalized_technology_tag)
		resource_technology_tag_offsets.append(resource_technology_tags.size())

	var type_ids := PackedStringArray()
	var owner_professions := PackedInt32Array()
	var owner_slots := PackedInt64Array()
	var construction_days := PackedInt32Array()
	var behavior_ids := PackedInt32Array()
	var behavior_versions := PackedInt32Array()
	var target_operating_margins := PackedInt32Array()
	var supply_price_elasticities := PackedInt32Array()
	var building_kinds := PackedInt32Array()
	var building_state_roles := PackedInt32Array()
	var building_economic_sectors := PackedInt32Array()
	var building_climate_profile_indices := PackedInt32Array()
	var technology_tag_offsets := PackedInt32Array([0])
	var technology_tags := PackedStringArray()
	var required_technology_tag_offsets := PackedInt32Array([0])
	var required_technology_tags := PackedStringArray()
	var semantic_tag_offsets := PackedInt32Array([0])
	var semantic_tags := PackedStringArray()
	var upgrade_family_set := {}
	for profile in profiles:
		var family_id := String(profile.upgrade_family_id).strip_edges()
		if family_id != "":
			upgrade_family_set[family_id] = true
	var upgrade_family_ids := PackedStringArray(upgrade_family_set.keys())
	upgrade_family_ids.sort()
	var upgrade_family_indices := PackedInt32Array()
	var upgrade_tiers := PackedInt32Array()
	var used_upgrade_tiers := {}
	var employee_offsets := PackedInt32Array([0])
	var employee_professions := PackedInt32Array()
	var employee_slot_counts := PackedInt64Array()
	var employee_wage_policies := PackedInt32Array()
	var construction_offsets := PackedInt32Array([0])
	var construction_goods := PackedInt32Array()
	var construction_quantities := PackedInt64Array()
	var construction_candidate_offsets := PackedInt32Array([0])
	var construction_candidate_goods := PackedInt32Array()
	var construction_candidate_efficiencies := PackedInt32Array()
	var maintenance_offsets := PackedInt32Array([0])
	var maintenance_goods := PackedInt32Array()
	var maintenance_quantities := PackedInt64Array()
	var maintenance_horizon_days := PackedInt32Array()
	var input_offsets := PackedInt32Array([0])
	var input_goods := PackedInt32Array()
	var input_quantities := PackedInt64Array()
	var input_required_q16 := PackedInt32Array()
	var input_category_ids := PackedStringArray()
	var input_min_quality_levels := PackedInt32Array()
	var input_candidate_offsets := PackedInt32Array([0])
	var input_candidate_goods := PackedInt32Array()
	var input_candidate_efficiencies := PackedInt32Array()
	var output_offsets := PackedInt32Array([0])
	var output_goods := PackedInt32Array()
	var output_quantities := PackedInt64Array()
	var output_cost_share_offsets := PackedInt32Array([0])
	var output_cost_shares := PackedInt32Array()
	var production_resource_offsets := PackedInt32Array([0])
	var production_resources := PackedInt32Array()
	var production_resource_quantities := PackedInt64Array()
	var production_resource_modes := PackedInt32Array()
	var production_resource_access_modes := PackedInt32Array()
	var generation_resource_offsets := PackedInt32Array([0])
	var generation_resources := PackedInt32Array()
	var generation_resource_quantities := PackedInt64Array()
	var generation_floor_q16 := PackedInt32Array()
	var condition_offsets := PackedInt32Array([0])
	var condition_opcodes := PackedInt32Array()
	var condition_signals := PackedInt32Array()
	var condition_compares := PackedInt32Array()
	var condition_references := PackedInt32Array()
	var condition_values := PackedInt64Array()

	for profile in profiles:
		var stable_id := String(profile.id)
		var owner_id := String(profile.owner_profession_id)
		if stable_id == "" or type_ids.has(stable_id) or not profession_index.has(owner_id) \
				or owner_id == UNEMPLOYED_PROFESSION_ID \
				or int(profile.owner_slots_per_building) <= 0 or int(profile.construction_days) < 0:
			return {"ok": false, "reason": "invalid building type: %s" % stable_id}
		var building_kind := String(profile.building_kind)
		# Explicit kind table. The previous nested ternary ended in a bare
		# `else 1`, so any unrecognised kind - a typo like "state_" or a
		# newly authored kind this runtime does not know - compiled into
		# `industrial` and started bidding for inputs and selling output.
		if not BUILDING_KIND_INDICES.has(building_kind):
			return {"ok": false, "reason": "invalid building kind: %s" % stable_id,
				"kind": building_kind}
		building_kinds.append(int(BUILDING_KIND_INDICES[building_kind]))
		# Military v1 (design §5.2/§5.3): a state-owned lot carries an authored
		# role; every other kind must leave it at `none`.
		var state_role_id := String(profile.state_role).strip_edges()
		if state_role_id not in ["none", "barracks", "fortification", "war_college"]:
			return {"ok": false, "reason": "invalid building state role: %s" % stable_id}
		var state_role := ["none", "barracks", "fortification", "war_college"].find(
			state_role_id)
		if building_kind == "state" and state_role <= 0:
			return {"ok": false, "reason": "state building requires a state role: %s" % stable_id}
		if building_kind != "state" and state_role != 0:
			return {"ok": false, "reason": "state role on non-state building: %s" % stable_id}
		building_state_roles.append(state_role)
		var sector_id := String(profile.economic_sector_id).strip_edges()
		var sector := BUILDING_SECTOR_IDS.find(sector_id)
		if sector < 0:
			return {"ok": false, "reason": "invalid building economic sector: %s" % stable_id,
				"sector": sector_id}
		building_economic_sectors.append(sector)
		var climate_id := String(profile.production_climate_profile_id).strip_edges()
		if climate_id != "" and not climate_profile_index.has(climate_id):
			return {"ok": false, "reason": "missing production climate profile: %s" % climate_id}
		building_climate_profile_indices.append(int(climate_profile_index.get(climate_id, -1)))
		var upgrade_family_id := String(profile.upgrade_family_id).strip_edges()
		var upgrade_tier := int(profile.upgrade_tier)
		if (upgrade_family_id == "" and upgrade_tier != 0) \
				or (upgrade_family_id != "" and upgrade_tier <= 0):
			return {"ok": false, "reason": "invalid building upgrade tier: %s" % stable_id}
		var upgrade_family_idx := upgrade_family_ids.find(upgrade_family_id) \
			if upgrade_family_id != "" else -1
		var upgrade_key := "%d:%d" % [upgrade_family_idx, upgrade_tier]
		if upgrade_family_idx >= 0 and used_upgrade_tiers.has(upgrade_key):
			return {"ok": false, "reason": "duplicate building upgrade tier: %s" % stable_id}
		if upgrade_family_idx >= 0:
			used_upgrade_tiers[upgrade_key] = true
		upgrade_family_indices.append(upgrade_family_idx)
		upgrade_tiers.append(upgrade_tier)
		for tag in profile.technology_tags:
			if String(tag).strip_edges() == "":
				return {"ok": false, "reason": "empty building technology tag: %s" % stable_id}
			technology_tags.append(String(tag))
		technology_tag_offsets.append(technology_tags.size())
		# Military v1 (design §1.4/§1.5): every state lot is unlocked by
		# exactly one technology. The generic binding rule below also rejects
		# a double binding, but it reports a bare count; a state lot is the
		# one kind whose whole purpose is a single gate, so fail with the
		# role named and the offending count attached.
		if building_kind == "state":
			var state_technology_count := 0
			for tag in profile.technology_tags:
				if String(tag).strip_edges().begins_with("tech."):
					state_technology_count += 1
			if state_technology_count != 1:
				return {"ok": false, "reason":
					"state building requires exactly one technology tag: %s" % stable_id,
					"count": state_technology_count}
		var required_seen := {}
		for tag in profile.required_technology_tags:
			var required_tag := String(tag).strip_edges()
			if not required_tag.begins_with("tech.") or required_seen.has(required_tag):
				return {"ok": false,
					"reason": "invalid required building technology tag: %s" % stable_id,
					"tag": required_tag}
			required_seen[required_tag] = true
			required_technology_tags.append(required_tag)
		required_technology_tag_offsets.append(required_technology_tags.size())
		var normalized_building_tags := PackedStringArray()
		for tag in profile.semantic_tags:
			var normalized := String(tag).strip_edges()
			if normalized.is_empty() or normalized_building_tags.has(normalized):
				return {"ok": false, "reason": "invalid building semantic tag: %s" % stable_id}
			normalized_building_tags.append(normalized)
		normalized_building_tags.sort()
		semantic_tags.append_array(normalized_building_tags)
		semantic_tag_offsets.append(semantic_tags.size())
		var wage_policy := String(profile.wage_policy_id)
		if wage_policy not in ["none", "fixed", "adaptive"]:
			return {"ok": false, "reason": "unsupported building wage policy: %s" % stable_id}
		type_ids.append(stable_id)
		owner_professions.append(int(profession_index[owner_id]))
		owner_slots.append(int(profile.owner_slots_per_building))
		construction_days.append(int(profile.construction_days))
		var behavior_id := String(profile.behavior_id)
		if behavior_id not in ["none", "consume_local_resources", "cultivate_local_resources"]:
			return {"ok": false, "reason": "unsupported building behavior: %s" % stable_id}
		behavior_ids.append(2 if behavior_id == "cultivate_local_resources" else (
			1 if behavior_id == "consume_local_resources" else 0))
		behavior_versions.append(int(profile.behavior_version))
		var target_margin := int(profile.target_operating_margin_q16)
		var supply_elasticity := int(profile.supply_price_elasticity_q16)
		if target_margin < 0 or target_margin > 262144 \
				or supply_elasticity < 0 or supply_elasticity > 262144:
			return {"ok": false, "reason": "invalid building price response: %s" % stable_id}
		target_operating_margins.append(target_margin)
		supply_price_elasticities.append(supply_elasticity)
		var generation_floor := int(profile.resource_generation_floor_q16)
		if generation_floor < 0 or generation_floor > Q16_ONE:
			return {"ok": false, "reason": "invalid building resource generation floor: %s" % stable_id}
		generation_floor_q16.append(generation_floor)

		var role_ids: PackedStringArray = profile.employee_profession_ids
		var role_slots: PackedInt64Array = profile.employee_slots_per_building
		var role_wage_policies: PackedStringArray = profile.employee_wage_policy_ids
		if role_ids.size() != role_slots.size():
			return {"ok": false, "reason": "building employee columns mismatch: %s" % stable_id}
		if not role_wage_policies.is_empty() and role_wage_policies.size() != role_ids.size():
			return {"ok": false, "reason": "building role wage policies mismatch: %s" % stable_id}
		for i in range(role_ids.size()):
			var profession_id := String(role_ids[i])
			var role_policy := String(role_wage_policies[i]) if not role_wage_policies.is_empty() else wage_policy
			if not profession_index.has(profession_id) or int(role_slots[i]) <= 0 \
					or profession_id == UNEMPLOYED_PROFESSION_ID \
					or role_policy not in ["none", "fixed", "adaptive", "state_payroll"]:
				return {"ok": false, "reason": "invalid building employee role: %s" % stable_id}
			# Military v1: a state-owned lot is staffed only by state-service
			# professions, and every one of those roles runs "state_payroll".
			var role_state_service: bool = profession_state_service_only[
				int(profession_index[profession_id])] != 0
			if building_kind == "state":
				if not role_state_service:
					return {"ok": false, "reason":
						"state building role requires state-service profession: %s" % stable_id}
				# Design §3.2/§3.3: the treasury pays every state role, so the
				# policy must be authored explicitly. The earlier form skipped
				# this check whenever `employee_wage_policy_ids` was empty, which
				# let a state lot fall back to the building-level market wage
				# and compile with a wage the treasury never settles.
				if role_wage_policies.is_empty() or role_policy != "state_payroll":
					return {"ok": false, "reason":
						"state building role must use state_payroll: %s" % stable_id}
			elif role_state_service:
				return {"ok": false, "reason":
					"state-service profession only fills state buildings: %s" % stable_id}
			employee_professions.append(int(profession_index[profession_id]))
			employee_slot_counts.append(int(role_slots[i]))
			# Employee wages are always discovered from the live labour market.
			# Keep accepting legacy "fixed" content for load compatibility, but
			# never compile it into a fixed native wage policy. `state_payroll`
			# is not a wage amount: the treasury pays the military wage, so the
			# role posts no building contract wage either.
			employee_wage_policies.append(2)
		employee_offsets.append(employee_professions.size())

		var zero_cost_construction: bool = BuildingPlacementScript.allows_zero_cost_construction(profile)
		if profile.construction_good_ids.is_empty() and not zero_cost_construction:
			return {"ok": false, "reason": "building requires explicit construction goods: %s" % stable_id}
		var error := ""
		var authored_construction_goods := PackedInt32Array()
		var authored_construction_quantities := PackedInt64Array()
		if not profile.construction_good_ids.is_empty():
			error = BuildingPlacementScript._append_building_goods(profile.construction_good_ids,
				profile.construction_quantities, good_index,
				authored_construction_goods, authored_construction_quantities)
		if error != "": return {"ok": false, "reason": "%s: %s" % [error, stable_id]}
		var authored_candidate_offsets := PackedInt32Array([0])
		var authored_candidate_goods := PackedInt32Array()
		var authored_candidate_efficiencies := PackedInt32Array()
		var construction_candidate_error := BuildingPlacementScript._append_construction_candidates(
			profile, good_index, category_good_indices, good_quality_levels,
			good_efficiencies_q16, authored_candidate_offsets,
			authored_candidate_goods, authored_candidate_efficiencies)
		if construction_candidate_error != "":
			return {"ok": false, "reason": "%s: %s" % [construction_candidate_error, stable_id]}
		if not authored_construction_goods.is_empty():
			var pooled_error := BuildingPlacementScript._append_pooled_construction(
				authored_construction_goods, authored_construction_quantities,
				authored_candidate_offsets, authored_candidate_goods,
				authored_candidate_efficiencies, construction_goods,
				construction_quantities, construction_candidate_offsets,
				construction_candidate_goods, construction_candidate_efficiencies)
			if pooled_error != "":
				return {"ok": false, "reason": "%s: %s" % [pooled_error, stable_id]}
		construction_offsets.append(construction_goods.size())
		# Design §7.3: a state lot is a pure treasury cash sink. Its upkeep is
		# settled by the military runtime, so a material maintenance bill here
		# would charge the same building twice - once in goods, once in cash.
		# Reject the authoring outright instead of silently dropping the
		# column, so the double bill can never come back through content.
		if building_kind == "state":
			if not profile.maintenance_good_ids.is_empty():
				return {"ok": false, "reason":
					"state building must not declare maintenance goods: %s" % stable_id}
			if int(profile.maintenance_horizon_days) != 0:
				return {"ok": false, "reason":
					"state building must not declare a maintenance horizon: %s" % stable_id}
		var authored_maintenance_ids: PackedStringArray = profile.maintenance_good_ids
		var authored_maintenance_qty: PackedInt64Array = profile.maintenance_quantities_per_day
		if authored_maintenance_ids.size() != authored_maintenance_qty.size():
			return {"ok": false, "reason": "building maintenance columns mismatch: %s" % stable_id}
		if not authored_maintenance_ids.is_empty():
			for item in range(authored_maintenance_ids.size()):
				var maintenance_id := String(authored_maintenance_ids[item])
				if not good_index.has(maintenance_id) or int(authored_maintenance_qty[item]) <= 0:
					return {"ok": false, "reason": "invalid building maintenance good: %s" % stable_id}
				var maintenance_good := int(good_index[maintenance_id])
				if maintenance_good < 0 or maintenance_good >= good_storage_modes.size() \
						or int(good_storage_modes[maintenance_good]) != 0:
					continue
				if maintenance_good < good_monetary_issue_values.size() \
						and int(good_monetary_issue_values[maintenance_good]) > 0:
					continue
				maintenance_goods.append(maintenance_good)
				maintenance_quantities.append(int(authored_maintenance_qty[item]))
		var horizon := int(profile.maintenance_horizon_days)
		if horizon < 0:
			return {"ok": false, "reason": "invalid building maintenance horizon: %s" % stable_id}
		maintenance_horizon_days.append(horizon)
		maintenance_offsets.append(maintenance_goods.size())
		error = BuildingPlacementScript._append_building_goods(profile.input_good_ids,
			profile.input_quantities_per_day, good_index, input_goods, input_quantities)
		if error != "": return {"ok": false, "reason": "%s: %s" % [error, stable_id]}
		var configured_required: PackedInt32Array = profile.input_required_q16
		if not configured_required.is_empty() and configured_required.size() != profile.input_good_ids.size():
			return {"ok": false, "reason": "building input required columns mismatch: %s" % stable_id}
		var configured_categories: PackedStringArray = profile.input_category_ids
		var configured_min_levels: PackedInt32Array = profile.input_min_quality_levels
		var explicit_offsets: PackedInt32Array = profile.input_candidate_offsets
		var explicit_good_ids: PackedStringArray = profile.input_candidate_good_ids
		var explicit_efficiencies: PackedInt32Array = profile.input_candidate_efficiency_q16
		if not configured_categories.is_empty() and configured_categories.size() != profile.input_good_ids.size():
			return {"ok": false, "reason": "building input category columns mismatch: %s" % stable_id}
		if not configured_min_levels.is_empty() and configured_min_levels.size() != profile.input_good_ids.size():
			return {"ok": false, "reason": "building input quality columns mismatch: %s" % stable_id}
		var explicit_candidate_error := BuildingPlacementScript._validate_explicit_input_candidates(profile, good_index)
		if explicit_candidate_error != "":
			return {"ok": false, "reason": "%s: %s" % [explicit_candidate_error, stable_id]}
		var has_explicit_candidates := explicit_offsets.size() > 1 \
			or not explicit_good_ids.is_empty() or not explicit_efficiencies.is_empty()
		for input_idx in range(profile.input_good_ids.size()):
			var required_q16 := int(configured_required[input_idx]) if not configured_required.is_empty() else Q16_ONE
			var category_id := String(configured_categories[input_idx]) if not configured_categories.is_empty() else ""
			var min_level := int(configured_min_levels[input_idx]) if not configured_min_levels.is_empty() else 0
			if required_q16 < 0 or required_q16 > Q16_ONE:
				return {"ok": false, "reason": "invalid building input required q16: %s" % stable_id}
			if min_level < 0:
				return {"ok": false, "reason": "negative building input quality: %s" % stable_id}
			input_required_q16.append(required_q16)
			input_category_ids.append(category_id)
			input_min_quality_levels.append(min_level)
			var explicit_begin := int(explicit_offsets[input_idx]) if has_explicit_candidates else 0
			var explicit_end := int(explicit_offsets[input_idx + 1]) if has_explicit_candidates else 0
			if explicit_end > explicit_begin:
				var sorted_candidates: Array[Dictionary] = []
				for candidate_idx in range(explicit_begin, explicit_end):
					var candidate_id := String(explicit_good_ids[candidate_idx])
					var efficiency := int(explicit_efficiencies[candidate_idx])
					sorted_candidates.append({"id": candidate_id, "efficiency": efficiency})
				sorted_candidates.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
					return String(a.id) < String(b.id))
				for candidate in sorted_candidates:
					input_candidate_goods.append(int(good_index[String(candidate.id)]))
					input_candidate_efficiencies.append(int(candidate.efficiency))
			elif category_id == "":
				input_candidate_goods.append(int(good_index[String(profile.input_good_ids[input_idx])]))
				input_candidate_efficiencies.append(Q16_ONE)
			else:
				var category_members: PackedInt32Array = category_good_indices.get(
					category_id, PackedInt32Array())
				for good_idx in category_members:
					if int(good_quality_levels[good_idx]) >= min_level:
						input_candidate_goods.append(good_idx)
						input_candidate_efficiencies.append(int(good_efficiencies_q16[good_idx]))
				if input_candidate_offsets[-1] == input_candidate_goods.size():
					return {"ok": false, "reason": "building input category has no candidates: %s" % stable_id}
			input_candidate_offsets.append(input_candidate_goods.size())
		input_offsets.append(input_goods.size())
		error = BuildingPlacementScript._append_building_goods(profile.output_good_ids,
			profile.output_quantities_per_day, good_index, output_goods, output_quantities)
		if error != "": return {"ok": false, "reason": "%s: %s" % [error, stable_id]}
		output_offsets.append(output_goods.size())
		var configured_cost_shares: PackedInt32Array = profile.output_cost_shares_q16
		if not configured_cost_shares.is_empty():
			if configured_cost_shares.size() != profile.output_good_ids.size():
				return {"ok": false, "reason": "building output cost shares mismatch: %s" % stable_id}
			var share_total := 0
			for share in configured_cost_shares:
				if int(share) < 0:
					return {"ok": false, "reason": "negative building output cost share: %s" % stable_id}
				share_total += int(share)
				output_cost_shares.append(int(share))
			if share_total != Q16_ONE:
				return {"ok": false, "reason": "building output cost shares must sum to Q16: %s" % stable_id}
		output_cost_share_offsets.append(output_cost_shares.size())
		if building_kind == "service" or building_kind == "state":
			if not profile.output_good_ids.is_empty():
				return {"ok": false, "reason": "service/state building must have no output: %s" % stable_id}
		elif profile.output_good_ids.is_empty():
			return {"ok": false, "reason": "building has no output: %s" % stable_id}
		var produces_cycle_flow := false
		var consumes_cycle_flow := false
		for good_id in profile.output_good_ids:
			produces_cycle_flow = produces_cycle_flow or int(
				good_storage_modes[int(good_index[String(good_id)])]) == 1
		for good_id in profile.input_good_ids:
			consumes_cycle_flow = consumes_cycle_flow or int(
				good_storage_modes[int(good_index[String(good_id)])]) == 1
		if produces_cycle_flow and consumes_cycle_flow:
			return {"ok": false, "reason": "cycle-flow producer consumes cycle flow: %s" % stable_id}

		var prod_ids: PackedStringArray = profile.resource_ids
		var prod_qty: PackedInt64Array = profile.resource_quantities_per_day
		var prod_modes: PackedStringArray = profile.resource_interaction_modes
		var prod_access: PackedStringArray = profile.resource_access_modes
		if prod_ids.size() != prod_qty.size() or prod_ids.size() != prod_modes.size() \
				or prod_ids.size() != prod_access.size():
			return {"ok": false, "reason": "building resource columns mismatch: %s" % stable_id}
		for i in range(prod_ids.size()):
			var resource_id := String(prod_ids[i])
			var interaction_mode := String(prod_modes[i])
			var access_mode := String(prod_access[i])
			if not resource_index.has(resource_id) or int(prod_qty[i]) <= 0 \
					or interaction_mode not in ["extract", "capacity"] \
					or access_mode != "local":
				return {"ok": false, "reason": "invalid building production resource: %s" % stable_id}
			production_resources.append(int(resource_index[resource_id]))
			production_resource_quantities.append(int(prod_qty[i]))
			production_resource_modes.append(0 if interaction_mode == "extract" else 1)
			production_resource_access_modes.append(0)
		production_resource_offsets.append(production_resources.size())
		# Design §7.3: a state lot neither extracts nor cultivates. The
		# generic collector/cultivation rules below would reject these too,
		# but with a reason that never names the state contract, and the
		# collector rule in particular reads as if a state lot could be
		# fixed by re-tagging its kind.
		if building_kind == "state":
			if not prod_ids.is_empty():
				return {"ok": false, "reason":
					"state building must not consume natural resources: %s" % stable_id}
			if not profile.resource_generation_ids.is_empty():
				return {"ok": false, "reason":
					"state building must not generate resources: %s" % stable_id}
		if owner_id == "merchant":
			# Route B: a merchant may own either a matching bullion collector
			# (gold/silver) or a service "merchant post" (no output/resource).
			var merchant_service_valid: bool = building_kind == "service" \
				and behavior_id == "none" \
				and profile.output_good_ids.is_empty() and prod_ids.is_empty() \
				and profile.resource_generation_ids.is_empty()
			var merchant_bullion_valid: bool = building_kind == "collector" \
				and behavior_id == "consume_local_resources" \
				and profile.output_good_ids.size() == 1 and prod_ids.size() == 1 \
				and String(prod_modes[0]) == "extract" \
				and profile.resource_generation_ids.is_empty()
			if merchant_bullion_valid:
				var bullion_id := String(profile.output_good_ids[0])
				merchant_bullion_valid = (bullion_id == "gold" and String(prod_ids[0]) == "gold_ore") \
					or (bullion_id == "silver" and String(prod_ids[0]) == "silver_ore")
			if not merchant_bullion_valid and not merchant_service_valid:
				return {"ok": false, "reason": "merchant may only own matching bullion collector or service post: %s" % stable_id}
		if building_kind == "collector" and prod_ids.is_empty():
			return {"ok": false, "reason": "collector requires natural resource: %s" % stable_id}
		if building_kind != "collector" and not prod_ids.is_empty():
			return {"ok": false, "reason": "non-collector building cannot consume natural resource: %s" % stable_id}
		if building_kind == "collector" and behavior_id == "none":
			return {"ok": false, "reason": "collector requires resource behavior: %s" % stable_id}
		if building_kind == "industrial" and behavior_id != "none":
			return {"ok": false, "reason": "industrial building cannot use resource behavior: %s" % stable_id}
		if building_kind == "service" and behavior_id != "none":
			return {"ok": false, "reason": "service building cannot use resource behavior: %s" % stable_id}
		if building_kind == "state" and behavior_id != "none":
			return {"ok": false, "reason": "state building cannot use resource behavior: %s" % stable_id}
		if building_kind == "state" and role_ids.is_empty():
			return {"ok": false, "reason": "state building requires an employee role: %s" % stable_id}
		var generation_ids: PackedStringArray = profile.resource_generation_ids
		var generation_qty: PackedInt64Array = profile.resource_generation_quantities_per_day
		if generation_ids.size() != generation_qty.size():
			return {"ok": false, "reason": "building resource generation columns mismatch: %s" % stable_id}
		if behavior_id != "cultivate_local_resources" and not generation_ids.is_empty():
			return {"ok": false, "reason": "building resource generation requires cultivation behavior: %s" % stable_id}
		if behavior_id == "cultivate_local_resources" and generation_ids.is_empty():
			return {"ok": false, "reason": "cultivation behavior requires resource generation: %s" % stable_id}
		for i in range(generation_ids.size()):
			var resource_id := String(generation_ids[i])
			if not resource_index.has(resource_id) or int(generation_qty[i]) <= 0:
				return {"ok": false, "reason": "invalid building generated resource: %s" % stable_id}
			generation_resources.append(int(resource_index[resource_id]))
			generation_resource_quantities.append(int(generation_qty[i]))
		generation_resource_offsets.append(generation_resources.size())

		var ops: PackedInt32Array = profile.condition_opcodes
		var signals: PackedInt32Array = profile.condition_signals
		var compares: PackedInt32Array = profile.condition_compares
		var refs: PackedStringArray = profile.condition_reference_ids
		var values: PackedInt64Array = profile.condition_values
		if ops.size() != signals.size() or ops.size() != compares.size() \
				or ops.size() != refs.size() or ops.size() != values.size():
			return {"ok": false, "reason": "building condition columns mismatch: %s" % stable_id}
		var depth := 0
		for i in range(ops.size()):
			var opcode := int(ops[i])
			if opcode == 1:
				depth += 1
			elif opcode == 4:
				if depth < 1: return {"ok": false, "reason": "building condition stack underflow: %s" % stable_id}
			elif opcode == 2 or opcode == 3:
				if depth < 2: return {"ok": false, "reason": "building condition stack underflow: %s" % stable_id}
				depth -= 1
			else:
				return {"ok": false, "reason": "building condition opcode invalid: %s" % stable_id}
			var reference := -1
			if int(signals[i]) == 10:
				var ref_id := String(refs[i])
				if not resource_index.has(ref_id):
					return {"ok": false, "reason": "building condition resource missing: %s" % stable_id}
				reference = int(resource_index[ref_id])
			condition_opcodes.append(opcode)
			condition_signals.append(int(signals[i]))
			condition_compares.append(int(compares[i]))
			condition_references.append(reference)
			condition_values.append(int(values[i]))
		if not ops.is_empty() and depth != 1:
			return {"ok": false, "reason": "building condition postfix invalid: %s" % stable_id}
		condition_offsets.append(condition_opcodes.size())

	return {
		"ok": true,
		"building_type_ids": type_ids,
		"building_kinds": building_kinds,
		"building_state_roles": building_state_roles,
		"building_economic_sectors": building_economic_sectors,
		"building_production_climate_profile_indices": building_climate_profile_indices,
		"production_climate_profile_ids": climate_profile_ids,
		"production_climate_temperature_opt_q16": climate_temperature_opt_q16,
		"production_climate_temperature_tolerance_q16": climate_temperature_tolerance_q16,
		"production_climate_water_opt_q16": climate_water_opt_q16,
		"production_climate_water_tolerance_q16": climate_water_tolerance_q16,
		"production_climate_exposure_q16": climate_exposure_q16,
		"production_climate_floor_q16": climate_floor_q16,
		"building_technology_tag_offsets": technology_tag_offsets,
		"building_technology_tags": technology_tags,
		"building_required_technology_tag_offsets": required_technology_tag_offsets,
		"building_required_technology_tags": required_technology_tags,
		"building_semantic_tag_offsets": semantic_tag_offsets,
		"building_semantic_tags": semantic_tags,
		"building_upgrade_family_ids": upgrade_family_ids,
		"building_upgrade_family_indices": upgrade_family_indices,
		"building_upgrade_tiers": upgrade_tiers,
		"building_industry_chain_ids": progression_columns.building_industry_chain_ids,
		"building_progression_steps": progression_columns.building_progression_steps,
		"building_maturity_ranks": progression_columns.building_maturity_ranks,
		"building_maturity_display_names": progression_columns.building_maturity_display_names,
		"building_progression_roles": progression_columns.building_progression_roles,
		"building_progression_predecessor_offsets": progression_columns.building_progression_predecessor_offsets,
		"building_progression_predecessor_indices": progression_columns.building_progression_predecessor_indices,
		"building_progression_terminal_reasons": progression_columns.building_progression_terminal_reasons,
		"building_owner_profession_ids": owner_professions,
		"building_owner_slots": owner_slots,
		"building_construction_days": construction_days,
		"building_behavior_ids": behavior_ids,
		"building_behavior_versions": behavior_versions,
		"building_target_operating_margin_q16": target_operating_margins,
		"building_supply_price_elasticity_q16": supply_price_elasticities,
		"building_employee_offsets": employee_offsets,
		"building_employee_profession_ids": employee_professions,
		"building_employee_slots": employee_slot_counts,
		"building_employee_wage_policies": employee_wage_policies,
		"building_construction_offsets": construction_offsets,
		"building_construction_good_ids": construction_goods,
		"building_construction_quantities": construction_quantities,
		"building_construction_candidate_offsets": construction_candidate_offsets,
		"building_construction_candidate_good_ids": construction_candidate_goods,
		"building_construction_candidate_efficiency_q16": construction_candidate_efficiencies,
		"building_maintenance_offsets": maintenance_offsets,
		"building_maintenance_good_ids": maintenance_goods,
		"building_maintenance_quantities": maintenance_quantities,
		"building_maintenance_horizon_days": maintenance_horizon_days,
		"building_input_offsets": input_offsets,
		"building_input_good_ids": input_goods,
		"building_input_quantities": input_quantities,
		"building_input_required_q16": input_required_q16,
		"building_input_category_ids": input_category_ids,
		"building_input_min_quality_levels": input_min_quality_levels,
		"building_input_candidate_offsets": input_candidate_offsets,
		"building_input_candidate_good_ids": input_candidate_goods,
		"building_input_candidate_efficiency_q16": input_candidate_efficiencies,
		"building_output_offsets": output_offsets,
		"building_output_good_ids": output_goods,
		"building_output_quantities": output_quantities,
		"building_output_cost_share_offsets": output_cost_share_offsets,
		"building_output_cost_shares_q16": output_cost_shares,
		"building_resource_ids": resource_ids,
		"building_resource_reserve_slots": resource_reserve_slots,
		"building_resource_extra_slots": resource_extra_slots,
		"building_resource_gen_base": resource_gen_base,
		"building_resource_gen_temp": resource_gen_temp,
		"building_resource_gen_moisture": resource_gen_moisture,
		"building_resource_gen_self": resource_gen_self,
		"building_resource_decay_base": resource_decay_base,
		"building_resource_decay_temp": resource_decay_temp,
		"building_resource_decay_moisture": resource_decay_moisture,
		"building_resource_decay_self_q16": resource_decay_self_q16,
		"building_resource_ecology_capacity": resource_ecology_capacity,
		"building_resource_ecology_growth_q16": resource_ecology_growth_q16,
		"building_resource_temp_lo_q16": resource_temp_lo_q16,
		"building_resource_temp_hi_q16": resource_temp_hi_q16,
		"building_resource_climate_temp_opt_q16": resource_climate_temp_opt_q16,
		"building_resource_climate_temp_tol_q16": resource_climate_temp_tol_q16,
		"building_resource_climate_moisture_opt_q16": resource_climate_moisture_opt_q16,
		"building_resource_climate_moisture_tol_q16": resource_climate_moisture_tol_q16,
		"building_resource_runtime_fit_weight_q16": resource_runtime_fit_weight_q16,
		"building_resource_temperature_signal": resource_temperature_signal,
		"building_resource_moisture_signal": resource_moisture_signal,
		"building_resource_semantic_tag_offsets": resource_semantic_tag_offsets,
		"building_resource_semantic_tags": resource_semantic_tags,
		"building_resource_technology_tag_offsets": resource_technology_tag_offsets,
		"building_resource_technology_tags": resource_technology_tags,
		"building_resource_offsets": production_resource_offsets,
		"building_production_resource_ids": production_resources,
		"building_production_resource_quantities": production_resource_quantities,
		"building_production_resource_modes": production_resource_modes,
		"building_production_resource_access_modes": production_resource_access_modes,
		"building_resource_generation_offsets": generation_resource_offsets,
		"building_resource_generation_ids": generation_resources,
		"building_resource_generation_quantities": generation_resource_quantities,
		"building_resource_generation_floor_q16": generation_floor_q16,
		"building_condition_offsets": condition_offsets,
		"building_condition_opcodes": condition_opcodes,
		"building_condition_signals": condition_signals,
		"building_condition_compares": condition_compares,
		"building_condition_references": condition_references,
		"building_condition_values": condition_values,
	}
