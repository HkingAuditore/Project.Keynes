class_name StarterEconomyPlanner
extends RefCounted

const BuildingProfileScript = preload("res://scripts/data/building_profile.gd")
const ResourceProfileRegistry = preload(
	"res://scripts/data/resource_profile_registry.gd")

const BUILDING_DIR := "res://data/economy/buildings"
const SURVIVAL_PLAN_PATH := \
	"res://data/economy/consumption_plans/survival_household.tres"
const CLOTHING_CURVE_PATH := \
	"res://data/economy/environment_curves/cold_clothing_quantity.tres"
const PRODUCTION_CLIMATE_DIR := "res://data/economy/production_climates"
const STARTER_POPULATION := 20
const GOODS_SCALE := 1000
const Q16_ONE := 65536
const RESOURCE_RUNWAY_DAYS := 365
const RENEWABLE_SAFE_HARVEST_Q16 := 32768
const RENEWABLE_MIN_RESERVE_Q16 := 22938
const RENEWABLE_GROWTH_DIVISOR := 8
const MIN_FOOD_COVERAGE_Q16 := 72090 # 110%
const TARGET_SUPPLY_MAX_Q16 := 75366 # 115%
const TARGET_FOOD_MAX_Q16 := 81920 # 125%

const FIXED_BUILDING_IDS := {
	"early_merchant_post": true,
	"placer_gold_working": true,
	"surface_silver_working": true,
}
const PRECIOUS_GOOD_IDS := {"gold_ore": true, "silver_ore": true}

static var _building_profiles: Array = []
static var _resource_profiles: Dictionary = {}
static var _climate_profiles: Dictionary = {}


## Cold-path, deterministic starter-settlement capacity planner. It only reads
## authored catalogs and MapData; runtime ownership remains in NativeEconomyRuntime.
static func plan(map: MapData, cell_idx: int, starter_route: Dictionary,
		facade = null) -> Dictionary:
	if map == null or cell_idx < 0 or cell_idx >= map.cell_count():
		return _error("starter_planner_cell_invalid",
			"开局经济规划器收到无效地块。")
	var selected_ids: PackedStringArray = starter_route.get(
		"starter_building_ids", PackedStringArray())
	var technology_ids: PackedStringArray = starter_route.get(
		"starter_technology_ids", PackedStringArray())
	if selected_ids.is_empty() or technology_ids.is_empty():
		return _error("starter_planner_route_invalid",
			"开局经济规划器缺少建筑或科技路线。")
	_ensure_profiles_loaded()
	var completed := {}
	for technology_id in technology_ids:
		completed[String(technology_id)] = true
	var selected := {}
	for building_id in selected_ids:
		selected[String(building_id)] = true

	var relevant_goods := {}
	for good_id in starter_route.get("starter_food_good_ids", PackedStringArray()):
		relevant_goods[String(good_id)] = true
	for key in ["starter_clothing_good_id", "starter_construction_good_id",
			"starter_knowledge_good_id", "starter_precious_good_id"]:
		var stable_id := String(starter_route.get(key, ""))
		if not stable_id.is_empty():
			relevant_goods[stable_id] = true
	for profile in _building_profiles:
		if selected.has(String(profile.id)):
			for input_good in profile.input_good_ids:
				relevant_goods[String(input_good)] = true

	var candidates: Array[Dictionary] = []
	var profile_by_id := {}
	for profile in _building_profiles:
		profile_by_id[String(profile.id)] = profile
		var building_id := String(profile.id)
		var is_selected := selected.has(building_id)
		if not is_selected and not _technology_available(profile, completed):
			continue
		if not is_selected and not _profile_relevant(profile, relevant_goods):
			continue
		if _is_unselected_precious_profile(profile, is_selected):
			continue
		if _is_unselected_knowledge_profile(profile, is_selected):
			continue
		if not profile.employee_profession_ids.is_empty() \
				or not profile.employee_slots_per_building.is_empty():
			if is_selected:
				return _error("starter_employee_role_forbidden",
					"石器时代初始建筑不得包含雇员岗位：%s" % building_id)
			continue
		var owner_slots := int(profile.owner_slots_per_building)
		if owner_slots <= 0:
			continue
		var resource_cap := _resource_building_count_cap(profile, map, cell_idx)
		if resource_cap == 0 or not _conditions_met(profile, map, cell_idx):
			if is_selected:
				return _error("starter_building_geography_unsatisfied",
					"当地资源或地理条件不能承载初始建筑：%s" % building_id)
			continue
		var fixed := FIXED_BUILDING_IDS.has(building_id) \
			or _profile_outputs(profile, "technology_points")
		var minimum := 1 if is_selected else 0
		var maximum := 1 if fixed else STARTER_POPULATION / owner_slots
		if resource_cap >= 0:
			maximum = mini(maximum, resource_cap)
		maximum = mini(maximum, _useful_count_limit(profile, starter_route, map,
			cell_idx, maximum, is_selected))
		if maximum < minimum:
			return _error("starter_building_capacity_unsatisfied",
				"当地资源承载力不足以预建：%s" % building_id)
		candidates.append({
			"id": building_id,
			"profile": profile,
			"owner_slots": owner_slots,
			"min_count": minimum,
			"max_count": maximum,
			"resource_cap": resource_cap,
			"climate_q16": _production_climate_q16(profile, map, cell_idx),
		})

	for building_id in selected_ids:
		var found := false
		for candidate in candidates:
			if String(candidate.id) == String(building_id):
				found = true
				break
		if not found:
			return _error("starter_building_missing",
				"规划目录缺少路线建筑：%s" % building_id)
	if candidates.is_empty():
		return _error("starter_planner_no_candidates", "当地没有可规划的石器时代建筑。")
	candidates.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return String(a.id) < String(b.id))
	var search_context := _compile_search_context(
		candidates, map, cell_idx, starter_route)
	if not bool(search_context.get("ok", false)):
		return search_context

	var minimum_owner_slots := 0
	for candidate in candidates:
		minimum_owner_slots += int(candidate.min_count) * int(candidate.owner_slots)
	if minimum_owner_slots > STARTER_POPULATION:
		return _error("starter_population_overcommitted",
			"路线基础建筑的自营岗位容量已经超过 20 个。")
	var suffix_min := PackedInt32Array()
	var suffix_max := PackedInt32Array()
	suffix_min.resize(candidates.size() + 1)
	suffix_max.resize(candidates.size() + 1)
	for index in range(candidates.size() - 1, -1, -1):
		suffix_min[index] = suffix_min[index + 1] + \
			int(candidates[index].min_count) * int(candidates[index].owner_slots)
		suffix_max[index] = suffix_max[index + 1] + \
			int(candidates[index].max_count) * int(candidates[index].owner_slots)
	var search := {"best": {}, "evaluated": 0}
	_search_counts(candidates, 0, PackedInt32Array(), 0, suffix_min, suffix_max,
		search_context, search)
	var best: Dictionary = search.best
	if best.is_empty():
		return {
			"ok": false,
			"code": "starter_capacity_plan_unsatisfied",
			"message": "当地资源无法组成恰好覆盖 20 个可自主匹配岗位容量的可持续开局产业。",
			"candidate_building_ids": _candidate_ids(candidates),
			"evaluated_combinations": int(search.evaluated),
		}
	if facade != null:
		var facade_check := _validate_facade(best, facade)
		if not bool(facade_check.get("ok", false)):
			return facade_check
	var construction_contract := _compile_starter_construction_contract(
		best, starter_route, completed, map, cell_idx, profile_by_id)
	if not bool(construction_contract.get("ok", false)):
		return construction_contract
	best.merge(construction_contract, true)
	best["candidate_building_ids"] = _candidate_ids(candidates)
	best["evaluated_combinations"] = int(search.evaluated)
	return best


static func _compile_starter_construction_contract(plan_result: Dictionary,
		starter_route: Dictionary, completed: Dictionary, map: MapData,
		cell_idx: int, profile_by_id: Dictionary) -> Dictionary:
	var seed_building_id := String(plan_result.get("primary_food_building_id", ""))
	if seed_building_id.is_empty() or not profile_by_id.has(seed_building_id):
		return _error("starter_construction_seed_missing",
			"开局食物种子建筑缺少可编译的建材配方。")
	var seed_profile = profile_by_id[seed_building_id]
	var seed_groups := _construction_groups(seed_profile)
	if seed_groups.is_empty():
		return _error("starter_construction_groups_missing",
			"开局食物种子建筑没有建材组：%s" % seed_building_id)

	# A good is locally reachable when it is already provisioned or when an
	# unlocked, geographically executable local building can produce it.
	var locally_reachable := _starter_initial_goods(starter_route)
	for profile in _building_profiles:
		if not _technology_available(profile, completed) \
				or not _conditions_met(profile, map, cell_idx) \
				or _resource_building_count_cap(profile, map, cell_idx) == 0:
			continue
		for good_id in profile.output_good_ids:
			locally_reachable[String(good_id)] = true

	var preferred_good := String(starter_route.get(
		"starter_construction_good_id", ""))
	var group_offsets := PackedInt32Array([0])
	var candidate_good_ids := PackedStringArray()
	var candidate_efficiencies := PackedInt32Array()
	var legacy_candidates := PackedStringArray()
	var selected_by_good := {}
	for group_index in range(seed_groups.size()):
		var group: Dictionary = seed_groups[group_index]
		var viable: Array[Dictionary] = []
		for candidate in group.candidates:
			var good_id := String(candidate.good_id)
			candidate_good_ids.append(good_id)
			candidate_efficiencies.append(int(candidate.efficiency_q16))
			if not legacy_candidates.has(good_id):
				legacy_candidates.append(good_id)
			if locally_reachable.has(good_id):
				var physical := _construction_physical_quantity(
					int(group.quantity), int(candidate.efficiency_q16))
				viable.append({"good_id": good_id, "physical": physical})
		group_offsets.append(candidate_good_ids.size())
		if viable.is_empty():
			return {
				"ok": false,
				"code": "starter_construction_group_unreachable",
				"message": "出生地缺少种子建筑第 %d 个建材组的本地可达材料。" % group_index,
				"failed_group": group_index,
				"seed_building_id": seed_building_id,
			}
		viable.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
			var a_preferred := String(a.good_id) == preferred_good
			var b_preferred := String(b.good_id) == preferred_good
			if a_preferred != b_preferred:
				return a_preferred
			if int(a.physical) != int(b.physical):
				return int(a.physical) < int(b.physical)
			return String(a.good_id) < String(b.good_id))
		var selected: Dictionary = viable[0]
		selected_by_good[String(selected.good_id)] = int(selected_by_good.get(
			String(selected.good_id), 0)) + int(selected.physical)

	var selected_good_ids := PackedStringArray(selected_by_good.keys())
	selected_good_ids.sort()
	var selected_quantities := PackedInt64Array()
	for good_id in selected_good_ids:
		selected_quantities.append(int(selected_by_good[String(good_id)]))
	var dependency_check := _validate_starter_construction_closure(
		plan_result, starter_route, completed, map, cell_idx, profile_by_id,
		selected_good_ids)
	if not bool(dependency_check.get("ok", false)):
		return dependency_check
	return {
		"ok": true,
		"starter_construction_seed_building_id": seed_building_id,
		"starter_construction_group_offsets": group_offsets,
		"starter_construction_candidate_good_ids": candidate_good_ids,
		"starter_construction_candidate_efficiency_q16": candidate_efficiencies,
		"starter_construction_selected_good_ids": selected_good_ids,
		"starter_construction_selected_quantities": selected_quantities,
		# Read-only compatibility metadata. Bootstrap never consumes these fields.
		"starter_construction_good_id": preferred_good,
		"starter_construction_good_ids": legacy_candidates,
	}


static func _validate_starter_construction_closure(plan_result: Dictionary,
		starter_route: Dictionary, completed: Dictionary, map: MapData,
		cell_idx: int, profile_by_id: Dictionary,
		selected_materials: PackedStringArray) -> Dictionary:
	var reachable := _starter_initial_goods(starter_route)
	for good_id in selected_materials:
		reachable[String(good_id)] = true
	var local_profiles: Array = []
	for profile in _building_profiles:
		if _technology_available(profile, completed) \
				and _conditions_met(profile, map, cell_idx) \
				and _resource_building_count_cap(profile, map, cell_idx) != 0:
			local_profiles.append(profile)
	for profile in local_profiles:
		var outputs := {}
		for output_good in profile.output_good_ids:
			outputs[String(output_good)] = true
		for group in _construction_groups(profile):
			for candidate in group.candidates:
				if outputs.has(String(candidate.good_id)):
					return _error("starter_construction_self_dependency",
						"开局可达建筑不得使用自身产物建造：%s -> %s" % [
							String(profile.id), String(candidate.good_id)])
	var changed := true
	while changed:
		changed = false
		for profile in local_profiles:
			if not _construction_groups_reachable(profile, reachable):
				continue
			for output_good in profile.output_good_ids:
				var good_id := String(output_good)
				if not reachable.has(good_id):
					reachable[good_id] = true
					changed = true
	var starter_ids: PackedStringArray = plan_result.get(
		"starter_building_ids", PackedStringArray())
	for building_id in starter_ids:
		var stable_id := String(building_id)
		if not profile_by_id.has(stable_id) \
				or not _construction_groups_reachable(profile_by_id[stable_id], reachable):
			return _error("starter_construction_dependency_cycle",
				"开局建筑没有外部入口可完成重建：%s" % stable_id)
	return {"ok": true}


static func _starter_initial_goods(starter_route: Dictionary) -> Dictionary:
	var goods := {}
	for good_id in starter_route.get("starter_food_good_ids", PackedStringArray()):
		goods[String(good_id)] = true
	for key in ["starter_clothing_good_id", "starter_input_buffer_good_id"]:
		var good_id := String(starter_route.get(key, ""))
		if not good_id.is_empty():
			goods[good_id] = true
	return goods


static func _construction_groups(profile) -> Array[Dictionary]:
	var groups: Array[Dictionary] = []
	var good_ids: PackedStringArray = profile.construction_good_ids
	var quantities: PackedInt64Array = profile.construction_quantities
	var offsets: PackedInt32Array = profile.construction_candidate_offsets
	var candidate_ids: PackedStringArray = profile.construction_candidate_good_ids
	var efficiencies: PackedInt32Array = profile.construction_candidate_efficiency_q16
	for group_index in range(mini(good_ids.size(), quantities.size())):
		var candidates: Array[Dictionary] = []
		if offsets.size() == good_ids.size() + 1:
			for candidate_index in range(int(offsets[group_index]),
					int(offsets[group_index + 1])):
				if candidate_index >= 0 and candidate_index < candidate_ids.size():
					candidates.append({
						"good_id": String(candidate_ids[candidate_index]),
						"efficiency_q16": int(efficiencies[candidate_index]) \
							if candidate_index < efficiencies.size() else Q16_ONE,
					})
		if candidates.is_empty():
			candidates.append({"good_id": String(good_ids[group_index]),
				"efficiency_q16": Q16_ONE})
		groups.append({"preferred_good_id": String(good_ids[group_index]),
			"quantity": int(quantities[group_index]), "candidates": candidates})
	return groups


static func _construction_groups_reachable(profile, reachable: Dictionary) -> bool:
	for group in _construction_groups(profile):
		var group_ready := false
		for candidate in group.candidates:
			if reachable.has(String(candidate.good_id)):
				group_ready = true
				break
		if not group_ready:
			return false
	return true


static func _construction_physical_quantity(quantity: int, efficiency_q16: int) -> int:
	var efficiency := maxi(1, efficiency_q16)
	return maxi(1, (quantity * Q16_ONE + efficiency - 1) / efficiency)


static func _search_counts(candidates: Array[Dictionary], index: int,
		counts: PackedInt32Array, owner_slots: int, suffix_min: PackedInt32Array,
		suffix_max: PackedInt32Array, context: Dictionary,
		search: Dictionary) -> void:
	if owner_slots + int(suffix_min[index]) > STARTER_POPULATION \
			or owner_slots + int(suffix_max[index]) < STARTER_POPULATION:
		return
	if index >= candidates.size():
		if owner_slots != STARTER_POPULATION:
			return
		search.evaluated = int(search.evaluated) + 1
		var result := _evaluate_counts(candidates, counts, context)
		if bool(result.get("ok", false)) and (search.best as Dictionary).is_empty() \
				or (bool(result.get("ok", false)) and _plan_better(result, search.best)):
			search.best = result
		return
	var candidate: Dictionary = candidates[index]
	var slots := int(candidate.owner_slots)
	var remaining_after_min := int(suffix_min[index + 1])
	var maximum := mini(int(candidate.max_count),
		(STARTER_POPULATION - owner_slots - remaining_after_min) / slots)
	for count in range(int(candidate.min_count), maximum + 1):
		counts.append(count)
		_search_counts(candidates, index + 1, counts, owner_slots + count * slots,
			suffix_min, suffix_max, context, search)
		counts.resize(counts.size() - 1)


static func _compile_search_context(candidates: Array[Dictionary], map: MapData,
		cell_idx: int, starter_route: Dictionary) -> Dictionary:
	var food_goods: PackedStringArray = starter_route.get(
		"starter_food_good_ids", PackedStringArray())
	var resource_limits := {}
	var resource_caps := {}
	for candidate_index in range(candidates.size()):
		var candidate: Dictionary = candidates[candidate_index]
		var profile = candidate.profile
		var outputs := {}
		var inputs := {}
		var resources := {}
		var food_output := 0
		for output_index in range(mini(profile.output_good_ids.size(),
				profile.output_quantities_per_day.size())):
			var good_id := String(profile.output_good_ids[output_index])
			var quantity := int(profile.output_quantities_per_day[output_index]) * \
				int(candidate.climate_q16) / Q16_ONE
			outputs[good_id] = int(outputs.get(good_id, 0)) + quantity
			if food_goods.has(good_id):
				food_output += quantity
		for input_index in range(mini(profile.input_good_ids.size(),
				profile.input_quantities_per_day.size())):
			var good_id := String(profile.input_good_ids[input_index])
			inputs[good_id] = int(inputs.get(good_id, 0)) + \
				int(profile.input_quantities_per_day[input_index])
		for resource_index in range(mini(profile.resource_ids.size(), mini(
				profile.resource_quantities_per_day.size(),
				profile.resource_interaction_modes.size()))):
			var resource_id := String(profile.resource_ids[resource_index])
			var mode := String(profile.resource_interaction_modes[resource_index])
			var resource_key := "%s|%s" % [mode, resource_id]
			var quantity := float(profile.resource_quantities_per_day[resource_index]) / \
				float(GOODS_SCALE)
			resources[resource_key] = float(resources.get(resource_key, 0.0)) + quantity
			if not resource_limits.has(resource_key):
				var reserve := _reserve(map, resource_id, cell_idx)
				var limit := reserve
				if mode != "capacity":
					limit = _renewable_safe_yield_per_day(resource_id, reserve) \
						if _resource_is_renewable(resource_id) \
						else reserve / RESOURCE_RUNWAY_DAYS
				resource_limits[resource_key] = maxf(0.0, limit)
				resource_caps[resource_id] = maxf(0.0, limit)
		candidate["outputs"] = outputs
		candidate["inputs"] = inputs
		candidate["resources"] = resources
		candidate["food_output"] = food_output
		candidates[candidate_index] = candidate
	var food_categories := _compile_food_categories(starter_route)
	if food_categories.is_empty():
		return _error("starter_food_contract_invalid",
			"当地食物未映射到 survival_household 生存篮子。")
	return {
		"ok": true,
		"food_categories": food_categories,
		"clothing_good_id": String(starter_route.get(
			"starter_clothing_good_id", "clothing")),
		"clothing_demand": _clothing_demand(map, cell_idx),
		"resource_limits": resource_limits,
		"resource_caps": resource_caps,
	}


static func _evaluate_counts(candidates: Array[Dictionary], counts: PackedInt32Array,
		context: Dictionary) -> Dictionary:
	var supply := {}
	var inputs := {}
	var resource_use := {}
	var total_buildings := 0
	for index in range(candidates.size()):
		var count := int(counts[index])
		if count <= 0:
			continue
		var candidate: Dictionary = candidates[index]
		total_buildings += count
		for good_id in candidate.outputs:
			supply[good_id] = int(supply.get(good_id, 0)) + \
				count * int(candidate.outputs[good_id])
		for good_id in candidate.inputs:
			inputs[good_id] = int(inputs.get(good_id, 0)) + \
				count * int(candidate.inputs[good_id])
		for resource_key in candidate.resources:
			resource_use[resource_key] = float(resource_use.get(resource_key, 0.0)) + \
				count * float(candidate.resources[resource_key])

	var upstream_excess := 0
	var weakest_supply_q16 := Q16_ONE * 16
	for good_id in inputs:
		var demand := int(inputs[good_id])
		var available := int(supply.get(good_id, 0))
		if available < demand:
			return {}
		var coverage_q16 := available * Q16_ONE / maxi(1, demand)
		weakest_supply_q16 = mini(weakest_supply_q16, coverage_q16)
		if coverage_q16 > TARGET_SUPPLY_MAX_Q16:
			upstream_excess += available - demand * TARGET_SUPPLY_MAX_Q16 / Q16_ONE

	var resource_pressure_q16 := 0
	var resource_limits: Dictionary = context.resource_limits
	for resource_key in resource_use:
		var used := float(resource_use[resource_key])
		var limit := float(resource_limits.get(resource_key, 0.0))
		if used > limit + 0.000001:
			return {}
		resource_pressure_q16 = maxi(resource_pressure_q16,
			roundi(used / maxf(limit, 0.000001) * Q16_ONE))

	var food := _food_coverage_compiled(supply, context.food_categories)
	if not bool(food.get("ok", false)):
		return {}
	weakest_supply_q16 = mini(weakest_supply_q16, int(food.coverage_q16))
	var clothing_demand := int(context.clothing_demand)
	var clothing_supply := int(supply.get(String(context.clothing_good_id), 0))
	if clothing_supply * Q16_ONE < clothing_demand * MIN_FOOD_COVERAGE_Q16:
		return {}
	var clothing_coverage_q16 := clothing_supply * Q16_ONE / maxi(1, clothing_demand)
	weakest_supply_q16 = mini(weakest_supply_q16, clothing_coverage_q16)
	var overproduction := upstream_excess + int(food.excess)
	if clothing_coverage_q16 > TARGET_FOOD_MAX_Q16:
		overproduction += clothing_supply - clothing_demand * TARGET_FOOD_MAX_Q16 / Q16_ONE

	# This is a building-capacity report only. It is deliberately not split by
	# profession: native employment owns the population-to-job transition.
	var ids := PackedStringArray()
	var out_counts := PackedInt64Array()
	var primary_food_building_id := ""
	var primary_food_output := -1
	for index in range(candidates.size()):
		var count := int(counts[index])
		if count <= 0:
			continue
		var candidate: Dictionary = candidates[index]
		ids.append(String(candidate.id))
		out_counts.append(count)
		var contribution := int(candidate.food_output) * count
		if contribution > primary_food_output:
			primary_food_output = contribution
			primary_food_building_id = String(candidates[index].id)
	var fingerprint := _count_fingerprint(ids, out_counts)
	var ordered := _primary_building_first(ids, out_counts,
		primary_food_building_id)
	ids = ordered.ids
	out_counts = ordered.counts

	return {
		"ok": true,
		"code": "ok",
		"message": "",
		"starter_building_ids": ids,
		"starter_building_counts": out_counts,
		"starter_job_capacity": STARTER_POPULATION,
		"starter_employee_job_capacity": 0,
		"primary_food_building_id": primary_food_building_id,
		"resource_caps": context.resource_caps,
		"resource_pressure_q16": resource_pressure_q16,
		"supply_by_good": supply,
		"input_demand_by_good": inputs,
		"food_need_id": String(food.need_id),
		"food_coverage_q16": int(food.coverage_q16),
		"clothing_demand_per_day": clothing_demand,
		"clothing_coverage_q16": clothing_coverage_q16,
		"weakest_supply_coverage_q16": weakest_supply_q16,
		"overproduction_quantity": overproduction,
		"starter_building_total": total_buildings,
		"plan_fingerprint": fingerprint,
	}


static func _plan_better(candidate: Dictionary, current: Dictionary) -> bool:
	if int(candidate.weakest_supply_coverage_q16) != int(current.weakest_supply_coverage_q16):
		return int(candidate.weakest_supply_coverage_q16) > int(current.weakest_supply_coverage_q16)
	if int(candidate.resource_pressure_q16) != int(current.resource_pressure_q16):
		return int(candidate.resource_pressure_q16) < int(current.resource_pressure_q16)
	if int(candidate.overproduction_quantity) != int(current.overproduction_quantity):
		return int(candidate.overproduction_quantity) < int(current.overproduction_quantity)
	if int(candidate.starter_building_total) != int(current.starter_building_total):
		return int(candidate.starter_building_total) < int(current.starter_building_total)
	return String(candidate.plan_fingerprint) < String(current.plan_fingerprint)


static func _compile_food_categories(starter_route: Dictionary) -> Array:
	var plan = load(SURVIVAL_PLAN_PATH)
	if plan == null:
		return []
	var available_foods: PackedStringArray = starter_route.get(
		"starter_food_good_ids", PackedStringArray())
	var categories: Array[Dictionary] = []
	for need_index in range(plan.need_ids.size()):
		var need_id := String(plan.need_ids[need_index])
		if need_id not in ["staple_food", "protein", "produce"]:
			continue
		var goods := PackedStringArray()
		for variant in range(int(plan.need_variant_offsets[need_index]),
				int(plan.need_variant_offsets[need_index + 1])):
			for component in range(int(plan.variant_component_offsets[variant]),
					int(plan.variant_component_offsets[variant + 1])):
				var good_id := String(plan.component_good_ids[component])
				if available_foods.has(good_id) and not goods.has(good_id):
					goods.append(good_id)
		if goods.is_empty():
			continue
		var demand := STARTER_POPULATION * int(plan.base_qty_per_person[need_index])
		categories.append({"need_id": need_id, "goods": goods, "demand": demand})
	return categories


static func _food_coverage_compiled(supply: Dictionary,
		categories: Array) -> Dictionary:
	var best := {}
	for category in categories:
		var category_supply := 0
		for good_id in category.goods:
			category_supply += int(supply.get(String(good_id), 0))
		var demand := int(category.demand)
		var coverage_q16 := category_supply * Q16_ONE / maxi(1, demand)
		if coverage_q16 < MIN_FOOD_COVERAGE_Q16:
			continue
		var excess := maxi(0, category_supply - demand * TARGET_FOOD_MAX_Q16 / Q16_ONE)
		var result := {"ok": true, "need_id": String(category.need_id),
			"coverage_q16": coverage_q16, "excess": excess}
		if best.is_empty() or abs(coverage_q16 - MIN_FOOD_COVERAGE_Q16) < \
				abs(int(best.coverage_q16) - MIN_FOOD_COVERAGE_Q16):
			best = result
	return best


static func _clothing_demand(map: MapData, cell_idx: int) -> int:
	var curve = load(CLOTHING_CURVE_PATH)
	var factor_q16 := Q16_ONE
	if curve != null and curve.values_q16.size() == 17:
		var temperature := clampf(_array_value(map.temp_arr, cell_idx, 0.5), 0.0, 1.0)
		var scaled := temperature * 16.0
		var lower := mini(16, floori(scaled))
		var upper := mini(16, lower + 1)
		var fraction := scaled - lower
		factor_q16 = roundi(lerpf(float(curve.values_q16[lower]),
			float(curve.values_q16[upper]), fraction))
	return maxi(1, STARTER_POPULATION * 2 * factor_q16 / Q16_ONE)


static func _technology_available(profile, completed: Dictionary) -> bool:
	var direct_present := false
	var direct_met := false
	for raw_tag in profile.technology_tags:
		var tag := String(raw_tag)
		if not tag.begins_with("tech."):
			continue
		direct_present = true
		direct_met = direct_met or completed.has(tag)
	if not direct_present or not direct_met:
		return false
	for raw_tag in profile.required_technology_tags:
		var tag := String(raw_tag)
		if tag.begins_with("tech.") and not completed.has(tag):
			return false
	return true


static func _profile_relevant(profile, relevant_goods: Dictionary) -> bool:
	if String(profile.id) == "early_merchant_post":
		return true
	for good_id in profile.output_good_ids:
		if relevant_goods.has(String(good_id)):
			return true
	return false


static func _is_unselected_precious_profile(profile, selected: bool) -> bool:
	if selected:
		return false
	for good_id in profile.output_good_ids:
		if PRECIOUS_GOOD_IDS.has(String(good_id)):
			return true
	for resource_id in profile.resource_ids:
		if PRECIOUS_GOOD_IDS.has(String(resource_id)):
			return true
	return false


static func _is_unselected_knowledge_profile(profile, selected: bool) -> bool:
	return not selected and _profile_outputs(profile, "technology_points")


static func _profile_outputs(profile, good_id: String) -> bool:
	return profile.output_good_ids.has(good_id)


static func _useful_count_limit(profile, starter_route: Dictionary, map: MapData,
		cell_idx: int, maximum: int, selected: bool) -> int:
	if maximum <= 1:
		return maximum
	var output_per_building := 0
	var food_goods: PackedStringArray = starter_route.get(
		"starter_food_good_ids", PackedStringArray())
	for index in range(mini(profile.output_good_ids.size(),
			profile.output_quantities_per_day.size())):
		if food_goods.has(String(profile.output_good_ids[index])):
			output_per_building += int(profile.output_quantities_per_day[index]) * \
				_production_climate_q16(profile, map, cell_idx) / Q16_ONE
	if output_per_building > 0:
		# Leave two buildings above the nominal survival target available to the
		# integer solver; the objective penalizes unused surplus deterministically.
		var largest_food_demand := STARTER_POPULATION * 440
		return mini(maximum, maxi(1 if selected else 0,
			(largest_food_demand * 2 + output_per_building - 1) / output_per_building + 2))
	if _profile_outputs(profile, "clothing"):
		return mini(maximum, 6)
	for good_id in profile.output_good_ids:
		if String(good_id) == "bast_fiber":
			return mini(maximum, 4)
	return mini(maximum, 4 if selected else 2)


static func _resource_building_count_cap(profile, map: MapData, cell_idx: int) -> int:
	if profile.resource_ids.is_empty():
		return -1
	var cap := 0x3fffffff
	for index in range(mini(profile.resource_ids.size(), mini(
			profile.resource_quantities_per_day.size(),
			profile.resource_interaction_modes.size()))):
		var resource_id := String(profile.resource_ids[index])
		var required := float(profile.resource_quantities_per_day[index]) / \
			float(GOODS_SCALE)
		if required <= 0.0:
			return 0
		var reserve := _reserve(map, resource_id, cell_idx)
		if String(profile.resource_interaction_modes[index]) == "capacity":
			cap = mini(cap, floori(reserve / required))
		elif _resource_is_renewable(resource_id):
			cap = mini(cap, floori(_renewable_safe_yield_per_day(
				resource_id, reserve) / required))
		else:
			cap = mini(cap, floori(reserve /
				(required * RESOURCE_RUNWAY_DAYS)))
	return maxi(0, cap)


static func _renewable_safe_yield_per_day(resource_id: String,
		local_reserve: float) -> float:
	var profile = _resource_profiles.get(resource_id)
	if profile == null:
		return 0.0
	var capacity := maxf(0.0, float(profile.ecology_capacity)) * \
		ResourceProfileRegistry.CELL_AREA_RESOURCE_SCALE
	var growth := maxf(0.0, float(profile.ecology_growth_rate))
	if capacity <= 0.0 or growth <= 0.0:
		return 0.0
	var reserve_floor := local_reserve * float(RENEWABLE_MIN_RESERVE_Q16) / Q16_ONE
	var yield_biomass := minf(capacity / RENEWABLE_GROWTH_DIVISOR,
		maxf(0.0, local_reserve - reserve_floor))
	return yield_biomass * growth * float(RENEWABLE_SAFE_HARVEST_Q16) / Q16_ONE


static func _resource_is_renewable(resource_id: String) -> bool:
	var profile = _resource_profiles.get(resource_id)
	return profile != null and float(profile.ecology_capacity) > 0.0 \
		and float(profile.ecology_growth_rate) > 0.0


static func _production_climate_q16(profile, map: MapData, cell_idx: int) -> int:
	var climate_id := String(profile.production_climate_profile_id)
	if climate_id.is_empty() or not _climate_profiles.has(climate_id):
		return Q16_ONE
	var climate = _climate_profiles[climate_id]
	var temperature := _array_value(map.temp_arr, cell_idx, 0.5)
	var water := _array_value(map.plant_available_water_arr, cell_idx,
		_array_value(map.moisture_arr, cell_idx, 0.5))
	var temperature_fit := clampf(1.0 - absf(temperature -
		float(climate.temperature_opt)) / maxf(float(climate.temperature_tolerance),
		0.000001), 0.0, 1.0)
	var water_fit := clampf(1.0 - absf(water - float(climate.water_opt)) /
		maxf(float(climate.water_tolerance), 0.000001), 0.0, 1.0)
	var bounded := maxf(float(climate.floor_q16) / Q16_ONE,
		minf(temperature_fit, water_fit))
	var capacity := 1.0 - float(climate.exposure_q16) / Q16_ONE * (1.0 - bounded)
	return clampi(roundi(capacity * Q16_ONE), 0, Q16_ONE)


static func _conditions_met(profile, map: MapData, cell_idx: int) -> bool:
	if profile.condition_opcodes.is_empty():
		return true
	var stack: Array[bool] = []
	for index in range(profile.condition_opcodes.size()):
		match int(profile.condition_opcodes[index]):
			1:
				var actual := _condition_signal(profile, index, map, cell_idx)
				stack.append(_compare_condition(actual,
					int(profile.condition_compares[index]),
					int(profile.condition_values[index])))
			2:
				if stack.size() < 2: return false
				var right_and := bool(stack.pop_back())
				var left_and := bool(stack.pop_back())
				stack.append(left_and and right_and)
			3:
				if stack.size() < 2: return false
				var right_or := bool(stack.pop_back())
				var left_or := bool(stack.pop_back())
				stack.append(left_or or right_or)
			4:
				if stack.is_empty(): return false
				stack.append(not bool(stack.pop_back()))
			_:
				return false
	return stack.size() == 1 and bool(stack[0])


static func _condition_signal(profile, token: int, map: MapData, cell_idx: int) -> int:
	match int(profile.condition_signals[token]):
		0: return roundi(_array_value(map.temp_arr, cell_idx, 0.5) * Q16_ONE)
		1: return roundi(_array_value(map.moisture_arr, cell_idx, 0.5) * Q16_ONE)
		2: return roundi(_array_value(map.snow_cover_arr, cell_idx, 0.0) * Q16_ONE)
		3: return roundi(_array_value(map.weather_intensity_arr, cell_idx, 0.0) * Q16_ONE)
		4: return roundi(_array_value(map.elevation_arr, cell_idx, 0.0) * Q16_ONE)
		5: return int(map.terrain_arr[cell_idx]) if cell_idx < map.terrain_arr.size() else 0
		6: return int(map.landform_arr[cell_idx]) if cell_idx < map.landform_arr.size() else 0
		7: return int(map.vegetation_arr[cell_idx]) if cell_idx < map.vegetation_arr.size() else 0
		8: return int(map.is_water_arr[cell_idx]) if cell_idx < map.is_water_arr.size() else 0
		9: return int(map.has_river_arr[cell_idx]) if cell_idx < map.has_river_arr.size() else 0
		10:
			return roundi(_reserve(map, String(profile.condition_reference_ids[token]),
				cell_idx) * GOODS_SCALE)
	return 0


static func _compare_condition(actual: int, compare: int, expected: int) -> bool:
	match compare:
		0: return actual == expected
		1: return actual != expected
		2: return actual < expected
		3: return actual <= expected
		4: return actual > expected
		5: return actual >= expected
	return false


static func _reserve(map: MapData, resource_id: String, cell_idx: int) -> float:
	var profile = _resource_profiles.get(resource_id)
	if profile == null:
		return 0.0
	var field := ResourceProfileRegistry.reserve_map_field(profile)
	if field.is_empty():
		return 0.0
	var values = map.get(field)
	if not values is PackedFloat32Array or cell_idx < 0 or cell_idx >= values.size():
		return 0.0
	return maxf(0.0, float(values[cell_idx]))


static func _array_value(values: PackedFloat32Array, index: int,
		fallback: float) -> float:
	return float(values[index]) if index >= 0 and index < values.size() else fallback


static func _validate_facade(plan_result: Dictionary, facade) -> Dictionary:
	var ids: PackedStringArray = plan_result.starter_building_ids
	var counts: PackedInt64Array = plan_result.starter_building_counts
	var job_total := 0
	for index in range(ids.size()):
		var job_spec: Dictionary = facade.building_job_spec(ids[index])
		if not bool(job_spec.get("ok", false)):
			return _error("starter_facade_catalog_mismatch",
				"运行时目录缺少规划建筑：%s" % ids[index])
		if not (job_spec.employee_professions as PackedStringArray).is_empty() \
				or not (job_spec.employee_slots as PackedInt64Array).is_empty():
			return _error("starter_employee_role_forbidden",
				"石器时代初始建筑不得包含雇员岗位：%s" % ids[index])
		job_total += int(job_spec.owner_slots) * int(counts[index])
	if job_total != STARTER_POPULATION:
		return _error("starter_facade_job_capacity_mismatch",
			"规划目录与运行时目录的可自主匹配岗位容量不一致。")
	return {"ok": true}


static func _candidate_ids(candidates: Array[Dictionary]) -> PackedStringArray:
	var result := PackedStringArray()
	for candidate in candidates:
		result.append(String(candidate.id))
	return result


static func _count_fingerprint(ids: PackedStringArray,
		counts: PackedInt64Array) -> String:
	var parts := PackedStringArray()
	for index in range(mini(ids.size(), counts.size())):
		parts.append("%s=%d" % [ids[index], counts[index]])
	return "|".join(parts)


static func _primary_building_first(ids: PackedStringArray,
		counts: PackedInt64Array, primary_id: String) -> Dictionary:
	var primary_index := ids.find(primary_id)
	if primary_index <= 0:
		return {"ids": ids, "counts": counts}
	var ordered_ids := PackedStringArray([primary_id])
	var ordered_counts := PackedInt64Array([counts[primary_index]])
	for index in range(ids.size()):
		if index == primary_index:
			continue
		ordered_ids.append(ids[index])
		ordered_counts.append(counts[index])
	return {"ids": ordered_ids, "counts": ordered_counts}


static func _ensure_profiles_loaded() -> void:
	if not _building_profiles.is_empty():
		return
	ResourceProfileRegistry.ensure_loaded()
	for profile in ResourceProfileRegistry.ordered():
		_resource_profiles[String(profile.id)] = profile
	var building_paths := PackedStringArray()
	for file_name in ResourceLoader.list_directory(BUILDING_DIR):
		if file_name.get_extension().to_lower() == "tres":
			building_paths.append("%s/%s" % [BUILDING_DIR, file_name])
	building_paths.sort()
	for path in building_paths:
		var profile = ResourceLoader.load(path, "Resource")
		if profile is BuildingProfile and not String(profile.id).is_empty():
			_building_profiles.append(profile)
	_building_profiles.sort_custom(func(a, b) -> bool:
		return String(a.id) < String(b.id))
	for file_name in ResourceLoader.list_directory(PRODUCTION_CLIMATE_DIR):
		if file_name.get_extension().to_lower() != "tres":
			continue
		var profile = ResourceLoader.load(
			"%s/%s" % [PRODUCTION_CLIMATE_DIR, file_name], "Resource")
		if profile != null and not String(profile.get("id")).is_empty():
			_climate_profiles[String(profile.id)] = profile


static func _error(code: String, message: String) -> Dictionary:
	return {"ok": false, "code": code, "message": message}
