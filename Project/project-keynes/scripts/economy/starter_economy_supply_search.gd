extends RefCounted

## Searches building counts and compares candidate starter supply plans.

const StarterInputs = preload("res://scripts/economy/starter_economy_inputs.gd")
const SURVIVAL_PLAN_PATH := \
	"res://data/economy/consumption_plans/survival_household.tres"
const STARTER_POPULATION := 40
const GOODS_SCALE := 1000
const Q16_ONE := 65536
const RESOURCE_RUNWAY_DAYS := 365
const RENEWABLE_SAFE_HARVEST_Q16 := 0
const MIN_FOOD_COVERAGE_Q16 := 85197 # 130%; climate and population-growth buffer
const TARGET_SUPPLY_MAX_Q16 := 91750 # 140%
const TARGET_FOOD_MAX_Q16 := 98304 # 150%


static func _search_counts(candidates: Array[Dictionary], index: int,
		counts: PackedInt32Array, owner_slots: int, suffix_min: PackedInt32Array,
		suffix_max: PackedInt32Array, context: Dictionary,
		search: Dictionary) -> void:
	if owner_slots + int(suffix_min[index]) > STARTER_POPULATION:
		return
	if index >= candidates.size():
		if owner_slots <= 0 or owner_slots > STARTER_POPULATION:
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
		cell_idx: int, starter_route: Dictionary,
		output_efficiency_q16: int = Q16_ONE) -> Dictionary:
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
			var quantity := StarterInputs._starter_output_quantity(
				int(profile.output_quantities_per_day[output_index]),
				int(candidate.climate_q16), output_efficiency_q16)
			outputs[good_id] = int(outputs.get(good_id, 0)) + quantity
			if food_goods.has(good_id):
				food_output += quantity
		for input_index in range(mini(profile.input_good_ids.size(),
				profile.input_quantities_per_day.size())):
			if not _slot_is_hard_input(profile, input_index):
				continue
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
				var reserve := StarterInputs._reserve(map, resource_id, cell_idx)
				var limit := reserve
				if mode != "capacity":
					if not StarterInputs._resource_is_renewable(resource_id):
						limit = reserve / RESOURCE_RUNWAY_DAYS
					elif RENEWABLE_SAFE_HARVEST_Q16 > 0:
						limit = StarterInputs._renewable_safe_yield_per_day(resource_id, reserve)
					else:
						# Open access matches _resource_building_count_cap: only
						# the one-day physical stock bounds startup extraction.
						limit = reserve
				resource_limits[resource_key] = maxf(0.0, limit)
				resource_caps[resource_id] = maxf(0.0, limit)
		candidate["outputs"] = outputs
		candidate["inputs"] = inputs
		candidate["resources"] = resources
		candidate["food_output"] = food_output
		candidates[candidate_index] = candidate
	var food_categories := _compile_food_categories(starter_route)
	if food_categories.is_empty():
		return StarterInputs._error("starter_food_contract_invalid",
			"当地食物未映射到 survival_household 生存篮子。")
	return {
		"ok": true,
		"food_categories": food_categories,
		"clothing_good_id": String(starter_route.get(
			"starter_clothing_good_id", "clothing")),
		"clothing_demand": StarterInputs._clothing_demand(map, cell_idx),
		"buffered_goods": StarterInputs._starter_buffered_goods(starter_route),
		"resource_limits": resource_limits,
		"resource_caps": resource_caps,
	}

static func _slot_is_hard_input(profile, input_index: int) -> bool:
	var required: PackedInt32Array = profile.input_required_q16
	if required.is_empty() or input_index >= required.size():
		return true
	return int(required[input_index]) >= Q16_ONE

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
	var buffered: Dictionary = context.get("buffered_goods", {})
	for good_id in inputs:
		var demand := int(inputs[good_id])
		var available := int(supply.get(good_id, 0))
		if available < demand:
			if buffered.has(String(good_id)):
				continue
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
	# Cold starts prebuild scraping capacity; the 15-day clothing bridge covers opening.
	var clothing_coverage_q16 := Q16_ONE
	if clothing_supply > 0:
		clothing_coverage_q16 = clothing_supply * Q16_ONE / maxi(1, clothing_demand)
	var overproduction := upstream_excess + int(food.excess)
	if clothing_supply > 0 and clothing_coverage_q16 > TARGET_FOOD_MAX_Q16:
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
	var ordered := StarterInputs._primary_building_first(ids, out_counts,
		primary_food_building_id)
	ids = ordered.ids
	out_counts = ordered.counts
	var employee_capacity := 0
	var job_capacity := 0
	for index in range(ids.size()):
		for candidate in candidates:
			if String(candidate.id) != String(ids[index]):
				continue
			job_capacity += int(candidate.owner_slots) * int(out_counts[index])
			employee_capacity += int(candidate.get("employee_slots", 0)) * int(out_counts[index])
			break

	return {
		"ok": true,
		"code": "ok",
		"message": "",
		"starter_building_ids": ids,
		"starter_building_counts": out_counts,
		"starter_job_capacity": job_capacity,
		"starter_employee_job_capacity": employee_capacity,
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
	# Prefer the smallest core satisfying the 130% food floor.
	if int(candidate.starter_building_total) != int(current.starter_building_total):
		return int(candidate.starter_building_total) < int(current.starter_building_total)
	if int(candidate.overproduction_quantity) != int(current.overproduction_quantity):
		return int(candidate.overproduction_quantity) < int(current.overproduction_quantity)
	if int(candidate.resource_pressure_q16) != int(current.resource_pressure_q16):
		return int(candidate.resource_pressure_q16) < int(current.resource_pressure_q16)
	if int(candidate.weakest_supply_coverage_q16) != int(current.weakest_supply_coverage_q16):
		return int(candidate.weakest_supply_coverage_q16) > int(current.weakest_supply_coverage_q16)
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
