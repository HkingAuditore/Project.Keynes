extends RefCounted

## Resource estimates, population tiers, and building and household goods requirements.

const Finance = preload("res://scripts/economy/bootstrap/test_start_finance.gd")
const Policy = preload("res://scripts/economy/bootstrap/test_start_policy.gd")
const GOODS_SCALE = Policy.GOODS_SCALE
const Q16_ONE = Policy.Q16_ONE
const INT64_MAX = Policy.INT64_MAX
const COLLECTOR_COUNT_CAP = Policy.COLLECTOR_COUNT_CAP
const CELL_POPULATION_CAP = Policy.CELL_POPULATION_CAP
const RESOURCE_TIER_SCALES = Policy.RESOURCE_TIER_SCALES
const INITIAL_RESOURCE_HORIZON_DAYS = Policy.INITIAL_RESOURCE_HORIZON_DAYS
const FOOD_REQUIREMENT_PER_CAPITA = Policy.FOOD_REQUIREMENT_PER_CAPITA
const CLOTHING_REQUIREMENT_PER_CAPITA = Policy.CLOTHING_REQUIREMENT_PER_CAPITA
const RESOURCE_BUILDING_RUNWAY_DAYS = Policy.RESOURCE_BUILDING_RUNWAY_DAYS
const RENEWABLE_SAFE_HARVEST_Q16 = Policy.RENEWABLE_SAFE_HARVEST_Q16
const RENEWABLE_MIN_RESERVE_Q16 = Policy.RENEWABLE_MIN_RESERVE_Q16
const RENEWABLE_GROWTH_DIVISOR = Policy.RENEWABLE_GROWTH_DIVISOR
const PLANNED_UTILIZATION_Q16 = Policy.PLANNED_UTILIZATION_Q16
const TEST_COLLECTOR_COUNT_CAPS = Policy.TEST_COLLECTOR_COUNT_CAPS
const FOOD_GOOD_IDS = Policy.FOOD_GOOD_IDS
const CLOTHING_GOOD_IDS = Policy.CLOTHING_GOOD_IDS


static func _uniform_population_scales(count: int, scale: int) -> PackedInt32Array:
	var scales := PackedInt32Array()
	scales.resize(count)
	scales.fill(scale)
	return scales

static func _building_supply_by_good(groups: Array) -> Dictionary:
	var supply := {}
	for group_raw in groups:
		var group: Dictionary = group_raw
		var outputs: PackedStringArray = group.spec.get(
			"output_good_ids", PackedStringArray())
		var quantities: PackedInt64Array = group.spec.get(
			"output_quantities", PackedInt64Array())
		for i in range(mini(outputs.size(), quantities.size())):
			var good := StringName(outputs[i])
			supply[good] = Finance.sat_add_nonnegative(int(supply.get(good, 0)),
				Finance.sat_mul_nonnegative(int(group.count), int(quantities[i])))
	return supply

static func _household_basic_demand(population: int, supply: Dictionary) -> Dictionary:
	var demand := {}
	_add_category_demand(demand, supply, population * 440,
		{"prepared_staples": true, "bread": true, "grain": true,
		"gathered_plants": true, "potatoes": true})
	_add_category_demand(demand, supply, population * 144,
		{"game_meat": true, "meat": true, "fish": true,
		"canned_fish": true, "dairy_products": true})
	_add_category_demand(demand, supply, population * 240,
		{"vegetables": true, "processed_food": true})
	_add_category_demand(demand, supply, population * 2, CLOTHING_GOOD_IDS)
	return demand

static func _add_category_demand(demand: Dictionary, supply: Dictionary,
		quantity: int, category: Dictionary) -> void:
	var total_supply := 0
	for good in category:
		total_supply = Finance.sat_add_nonnegative(
			total_supply, int(supply.get(StringName(good), 0)))
	if quantity <= 0 or total_supply <= 0:
		return
	var prefix := 0
	var allocated := 0
	for good in category:
		var stable_id := StringName(good)
		var available := int(supply.get(stable_id, 0))
		if available <= 0:
			continue
		prefix += available
		var next := quantity * prefix / total_supply
		demand[stable_id] = int(demand.get(stable_id, 0)) + next - allocated
		allocated = next

static func _add_building_input_demand(
		demand: Dictionary, groups: Array, finance: Dictionary) -> void:
	for group_raw in groups:
		var group: Dictionary = group_raw
		var spec: Dictionary = group.spec
		var quantities: PackedInt64Array = spec.get(
			"input_quantities", PackedInt64Array())
		for input_idx in range(quantities.size()):
			var selected := Finance.initial_building_input(
				spec, input_idx, int(quantities[input_idx]))
			var good := StringName(selected.good_id)
			if good == &"":
				continue
			demand[good] = Finance.sat_add_nonnegative(int(demand.get(good, 0)),
				Finance.sat_mul_nonnegative(int(group.count), int(selected.quantity)))

static func _resource_building_count_cap(spec: Dictionary, cell_idx: int,
		resource_arrays: Dictionary, resource_rules: Dictionary) -> int:
	var ids: PackedStringArray = spec.get("resource_ids", PackedStringArray())
	var quantities: PackedInt64Array = spec.get(
		"resource_quantities", PackedInt64Array())
	var modes: PackedInt32Array = spec.get("resource_modes", PackedInt32Array())
	if ids.is_empty():
		return -1
	var cap := INT64_MAX
	for i in range(mini(ids.size(), mini(quantities.size(), modes.size()))):
		var reserves: PackedFloat32Array = resource_arrays.get(
			StringName(ids[i]), PackedFloat32Array())
		if cell_idx < 0 or cell_idx >= reserves.size() or int(quantities[i]) <= 0:
			return 0
		var required := float(quantities[i]) / float(GOODS_SCALE)
		if int(modes[i]) == 0:
			var resource_id := StringName(ids[i])
			var sustainable_daily_yield := _renewable_safe_yield_per_day(
				resource_rules, resource_id, maxf(0.0, reserves[cell_idx]))
			if _resource_is_renewable(resource_rules, resource_id):
				cap = mini(cap, int(floor(
					sustainable_daily_yield / required)))
			else:
				cap = mini(cap, int(floor(maxf(0.0, reserves[cell_idx]) /
					(required * float(RESOURCE_BUILDING_RUNWAY_DAYS)))))
		else:
			cap = mini(cap, int(floor(
				maxf(0.0, reserves[cell_idx]) / required)))
	return cap

static func _renewable_safe_yield_per_day(rules: Dictionary,
		resource_id: StringName, local_reserve: float) -> float:
	var rule: Dictionary = rules.get(resource_id, {})
	var capacity := float(rule.get("capacity", 0.0))
	var growth := float(rule.get("growth", 0.0))
	if capacity <= 0.0 or growth <= 0.0:
		return 0.0
	var reserve_floor := local_reserve * float(RENEWABLE_MIN_RESERVE_Q16) / float(Q16_ONE)
	var yield_biomass := minf(capacity / float(RENEWABLE_GROWTH_DIVISOR), maxf(0.0, local_reserve - reserve_floor))
	return yield_biomass * growth * float(RENEWABLE_SAFE_HARVEST_Q16) / float(Q16_ONE)

static func _resource_is_renewable(rules: Dictionary, resource_id: StringName) -> bool:
	var rule: Dictionary = rules.get(resource_id, {})
	return float(rule.get("capacity", 0.0)) > 0.0 and float(rule.get("growth", 0.0)) > 0.0

static func _resource_population_scores(cell_indices: PackedInt32Array,
		calibrated_population: PackedInt64Array, input_coverage_q16: PackedInt32Array,
		resource_arrays: Dictionary, resource_peaks: Dictionary) -> PackedInt64Array:
	var scores := PackedInt64Array()
	scores.resize(cell_indices.size())
	for i in range(cell_indices.size()):
		var capacity := maxi(0, int(calibrated_population[i])) \
			if i < calibrated_population.size() else 0
		var coverage := clampi(int(input_coverage_q16[i]), 0, Q16_ONE) \
			if i < input_coverage_q16.size() else 0
		var abundance := _local_resource_abundance_q16(
			int(cell_indices[i]), resource_arrays, resource_peaks)
		# Capacity dominates because it already combines jobs, food, and clothing;
		# coverage and abundance deterministically separate otherwise equal cells.
		scores[i] = capacity * Q16_ONE * 2 + coverage + abundance
	return scores

static func _local_resource_abundance_q16(cell_idx: int,
		resource_arrays: Dictionary, resource_peaks: Dictionary) -> int:
	var total := 0
	var measured := 0
	for resource_id in resource_arrays:
		var peak := float(resource_peaks.get(resource_id, 0.0))
		var reserves: PackedFloat32Array = resource_arrays[resource_id]
		if peak <= 0.0 or cell_idx < 0 or cell_idx >= reserves.size():
			continue
		total += clampi(roundi(maxf(0.0, reserves[cell_idx]) / peak * Q16_ONE),
			0, Q16_ONE)
		measured += 1
	return total / measured if measured > 0 else 0

static func _population_scales_by_resource(cell_indices: PackedInt32Array,
		calibrated_population: PackedInt64Array,
		resource_scores: PackedInt64Array) -> PackedInt32Array:
	var scales := PackedInt32Array()
	scales.resize(cell_indices.size())
	scales.fill(1)
	var ranked := []
	for i in range(calibrated_population.size()):
		if int(calibrated_population[i]) <= 0:
			continue
		ranked.append(i)
	ranked.sort_custom(func(a: int, b: int) -> bool:
		var score_a := int(resource_scores[a])
		var score_b := int(resource_scores[b])
		if score_a != score_b:
			return score_a < score_b
		return int(cell_indices[a]) < int(cell_indices[b]))
	if ranked.is_empty():
		return scales
	for rank in range(ranked.size()):
		var tier := mini(RESOURCE_TIER_SCALES.size() - 1,
			rank * RESOURCE_TIER_SCALES.size() / ranked.size())
		scales[int(ranked[rank])] = int(RESOURCE_TIER_SCALES[tier])
	return scales

static func _population_tier_counts(calibrated_population: PackedInt64Array,
		population_scales: PackedInt32Array) -> Dictionary:
	var counts := {"tens": 0, "hundreds": 0, "thousands": 0, "ten_thousands": 0}
	for i in range(mini(calibrated_population.size(), population_scales.size())):
		if int(calibrated_population[i]) <= 0:
			continue
		match int(population_scales[i]):
			1: counts.tens += 1
			10: counts.hundreds += 1
			100: counts.thousands += 1
			500: counts.ten_thousands += 1
	return counts

static func _planned_survival_capacity(totals: Dictionary) -> int:
	# Bootstrap uses the same carrying contract as runtime K_eff: food supply
	# over the authored survival ration. Clothing remains a reported production
	# column, but is not a second population-capacity axis.
	var food := maxi(0, int(totals.food)) * PLANNED_UTILIZATION_Q16 / Q16_ONE
	return clampi(food / FOOD_REQUIREMENT_PER_CAPITA, 0, CELL_POPULATION_CAP)

static func _groups_input_covered(groups: Array) -> bool:
	return _groups_input_paths_exist(groups) and \
		_groups_input_coverage_q16(groups) >= Q16_ONE

static func _groups_input_coverage_q16(groups: Array) -> int:
	var outputs := {}
	var inputs := {}
	for group in groups:
		var count := int(group.count)
		if count <= 0:
			continue
		var spec: Dictionary = group.spec
		var output_ids: PackedStringArray = spec.get("output_good_ids", PackedStringArray())
		var output_quantities: PackedInt64Array = spec.get(
			"output_quantities", PackedInt64Array())
		var output_categories: PackedStringArray = spec.get(
			"output_category_ids", PackedStringArray())
		for i in range(mini(output_ids.size(), output_quantities.size())):
			var output_id := StringName(output_ids[i])
			var quantity := count * int(output_quantities[i])
			outputs[output_id] = int(outputs.get(output_id, 0)) + quantity
			if i < output_categories.size() and String(output_categories[i]) != "":
				var category_id := StringName(
					"category:%s" % String(output_categories[i]))
				outputs[category_id] = int(outputs.get(category_id, 0)) + quantity
		var input_ids: PackedStringArray = spec.get("input_good_ids", PackedStringArray())
		var input_quantities: PackedInt64Array = spec.get(
			"input_quantities", PackedInt64Array())
		var input_categories: PackedStringArray = spec.get(
			"input_category_ids", PackedStringArray())
		var input_required_q16: PackedInt32Array = spec.get(
			"input_required_q16", PackedInt32Array())
		for i in range(mini(input_ids.size(), input_quantities.size())):
			if i < input_required_q16.size() and input_required_q16[i] < Q16_ONE:
				continue
			var input_id := StringName("category:%s" % String(input_categories[i])) \
				if i < input_categories.size() and String(input_categories[i]) != "" \
				else StringName(input_ids[i])
			inputs[input_id] = int(inputs.get(input_id, 0)) + \
				count * int(input_quantities[i])
	var coverage := Q16_ONE
	for input_id in inputs:
		var required := int(inputs[input_id])
		if required <= 0:
			continue
		coverage = mini(coverage, int(outputs.get(input_id, 0)) * Q16_ONE / required)
	return maxi(0, coverage)

static func _groups_input_paths_exist(groups: Array) -> bool:
	var outputs := {}
	for group in groups:
		if int(group.count) > 0:
			_mark_outputs(group.spec, outputs)
	for group in groups:
		var inputs: PackedStringArray = group.spec.get("input_good_ids", PackedStringArray())
		var required_q16: PackedInt32Array = group.spec.get(
			"input_required_q16", PackedInt32Array())
		if int(group.count) <= 0:
			continue
		for i in range(inputs.size()):
			if i < required_q16.size() and required_q16[i] < Q16_ONE:
				continue
			if not _input_slot_ready(group.spec, i, outputs):
				return false
	return true

static func _spec_outputs_needed(spec: Dictionary, needed: Dictionary) -> bool:
	var output_ids: PackedStringArray = spec.get(
		"output_good_ids", PackedStringArray())
	var output_categories: PackedStringArray = spec.get(
		"output_category_ids", PackedStringArray())
	for i in range(output_ids.size()):
		if needed.has(StringName(output_ids[i])):
			return true
		if i < output_categories.size() and String(output_categories[i]) != "" and \
				needed.has(StringName("category:%s" % String(output_categories[i]))):
			return true
	return false

static func _mark_required_inputs(spec: Dictionary, needed: Dictionary) -> void:
	var input_ids: PackedStringArray = spec.get("input_good_ids", PackedStringArray())
	var input_categories: PackedStringArray = spec.get(
		"input_category_ids", PackedStringArray())
	var required_q16: PackedInt32Array = spec.get(
		"input_required_q16", PackedInt32Array())
	for i in range(input_ids.size()):
		if i < required_q16.size() and required_q16[i] < Q16_ONE:
			continue
		if i < input_categories.size() and String(input_categories[i]) != "":
			needed[StringName("category:%s" % String(input_categories[i]))] = true
		else:
			needed[StringName(input_ids[i])] = true

static func _groups_have_survival_output(groups: Array,
		good_ids: Dictionary) -> bool:
	for group_raw in groups:
		var group: Dictionary = group_raw
		for good_id in group.spec.get("output_good_ids", PackedStringArray()):
			if good_ids.has(String(good_id)):
				return true
	return false

static func _regional_planned_survival_capacity(totals: Dictionary,
		active_cell_count: int) -> int:
	# Regional bootstrap K_eff uses the same food-ration denominator as the
	# runtime flow estimator; active_cell_count only supplies the hard cell cap.
	var food := maxi(0, int(totals.food)) * PLANNED_UTILIZATION_Q16 / Q16_ONE
	return clampi(food / FOOD_REQUIREMENT_PER_CAPITA, 0,
		maxi(0, active_cell_count) * CELL_POPULATION_CAP)

static func _find_group(groups: Array, stable_id: StringName) -> Dictionary:
	for group_raw in groups:
		var group: Dictionary = group_raw
		if StringName(group.spec.get("stable_id", "")) == stable_id:
			return group
	return {}

static func _count_buildings(groups_by_cell: Dictionary,
		stable_id: StringName) -> int:
	var total := 0
	for groups_raw in groups_by_cell.values():
		for group_raw in groups_raw:
			var group: Dictionary = group_raw
			if StringName(group.spec.get("stable_id", "")) == stable_id:
				total += maxi(0, int(group.count))
	return total

static func _has_survival_food_root(groups: Array) -> bool:
	for group_raw in groups:
		var group: Dictionary = group_raw
		var outputs: PackedStringArray = group.spec.get(
			"output_good_ids", PackedStringArray())
		for good_id in outputs:
			if FOOD_GOOD_IDS.has(String(good_id)):
				return true
	return false

static func _construction_source_component_summaries(components: Array) -> Array:
	var summaries := []
	for component_raw in components:
		var component: Dictionary = component_raw
		summaries.append({
			"timber_cell": int(component.get("timber_cell", -1)),
			"stone_cell": int(component.get("stone_cell", -1)),
			"cell_count": (component.get("cells", []) as Array).size(),
		})
	return summaries

static func _basic_capacity_deficit_people(totals: Dictionary) -> int:
	var population := maxi(0, int(totals.population))
	var food_deficit := maxi(
		0, population * FOOD_REQUIREMENT_PER_CAPITA - int(totals.food))
	var clothing_deficit := maxi(
		0, population * CLOTHING_REQUIREMENT_PER_CAPITA - int(totals.clothing))
	return ceili(float(food_deficit) / float(FOOD_REQUIREMENT_PER_CAPITA)) + \
		ceili(float(clothing_deficit) / float(CLOTHING_REQUIREMENT_PER_CAPITA))

static func _carrying_capacity_population(totals: Dictionary) -> int:
	var workforce := maxi(0, int(totals.population))
	var food_capacity := int(maxi(0, int(totals.food)) / FOOD_REQUIREMENT_PER_CAPITA)
	return clampi(mini(workforce, food_capacity),
		0, CELL_POPULATION_CAP)

static func _basic_capacity_totals(groups: Array, reserved_population: int = 0) -> Dictionary:
	var population := maxi(0, reserved_population)
	var food := 0
	var clothing := 0
	for group in groups:
		var count := int(group.count)
		var per_building := _building_basic_capacity(group.spec)
		population += count * int(per_building.jobs)
		food += count * int(per_building.food)
		clothing += count * int(per_building.clothing)
	return {"population": population, "food": food, "clothing": clothing}

static func _building_basic_capacity(spec: Dictionary) -> Dictionary:
	var jobs := int(spec.owner_slots)
	for slots in spec.employee_slots:
		jobs += int(slots)
	var food := 0
	var clothing := 0
	var input_ids: PackedStringArray = spec.get("input_good_ids", PackedStringArray())
	var input_quantities: PackedInt64Array = spec.get("input_quantities", PackedInt64Array())
	for i in range(mini(input_ids.size(), input_quantities.size())):
		if FOOD_GOOD_IDS.has(String(input_ids[i])):
			food -= int(input_quantities[i])
		if CLOTHING_GOOD_IDS.has(String(input_ids[i])):
			clothing -= int(input_quantities[i])
	var output_ids: PackedStringArray = spec.get("output_good_ids", PackedStringArray())
	var output_quantities: PackedInt64Array = spec.get("output_quantities", PackedInt64Array())
	for i in range(mini(output_ids.size(), output_quantities.size())):
		if FOOD_GOOD_IDS.has(String(output_ids[i])):
			food += int(output_quantities[i])
		if CLOTHING_GOOD_IDS.has(String(output_ids[i])):
			clothing += int(output_quantities[i])
	return {"jobs": jobs, "food": food, "clothing": clothing}

static func _resource_peaks(resource_arrays: Dictionary,
		passable_cells: PackedInt32Array) -> Dictionary:
	var out := {}
	for resource_id in resource_arrays:
		var reserves: PackedFloat32Array = resource_arrays[resource_id]
		var peak := 0.0
		for cell_idx in passable_cells:
			if cell_idx >= 0 and cell_idx < reserves.size():
				peak = maxf(peak, maxf(0.0, reserves[cell_idx]))
		out[resource_id] = peak
	return out

static func _collector_count_at(spec: Dictionary, cell_idx: int,
		resource_arrays: Dictionary, resource_peaks: Dictionary,
		resource_horizon_days: int = INITIAL_RESOURCE_HORIZON_DAYS) -> int:
	var resource_ids: PackedStringArray = spec.resource_ids
	var quantities: PackedInt64Array = spec.resource_quantities
	var modes: PackedInt32Array = spec.resource_modes
	var access_modes: PackedInt32Array = spec.resource_access_modes
	if resource_ids.is_empty() or resource_ids.size() != quantities.size() \
			or resource_ids.size() != modes.size() or resource_ids.size() != access_modes.size():
		return 0
	var count_cap := clampi(int(TEST_COLLECTOR_COUNT_CAPS.get(
		String(spec.get("stable_id", "")), COLLECTOR_COUNT_CAP)), 1, COLLECTOR_COUNT_CAP)
	var supported := count_cap
	for i in range(resource_ids.size()):
		var resource_id := StringName(resource_ids[i])
		if not resource_arrays.has(resource_id):
			return 0
		var reserves: PackedFloat32Array = resource_arrays[resource_id]
		var required := float(quantities[i]) / float(GOODS_SCALE)
		if cell_idx < 0 or cell_idx >= reserves.size() or required <= 0.0:
			return 0
		if int(access_modes[i]) != 0:
			return 0
		var available := maxf(0.0, reserves[cell_idx])
		var peak := float(resource_peaks.get(resource_id, 0.0))
		if available <= 0.0 or peak <= 0.0:
			return 0
		var abundance_supported := clampi(
			ceili(float(count_cap) * available / peak), 1, count_cap)
		var reserve_days := maxi(1, resource_horizon_days) if int(modes[i]) == 0 else 1
		var horizon_supported := int(floor(
			available / (required * float(reserve_days))))
		var local_supported := mini(abundance_supported, horizon_supported)
		if local_supported <= 0:
			return 0
		supported = mini(supported, local_supported)
	return clampi(supported, 0, count_cap)

static func _mark_outputs(spec: Dictionary, local_outputs: Dictionary) -> void:
	var output_ids: PackedStringArray = spec.output_good_ids
	var output_categories: PackedStringArray = spec.get(
		"output_category_ids", PackedStringArray())
	for i in range(output_ids.size()):
		var good_id := output_ids[i]
		local_outputs[StringName(good_id)] = true
		if i < output_categories.size() and String(output_categories[i]) != "":
			local_outputs[StringName("category:%s" % String(output_categories[i]))] = true

static func _inputs_ready(spec: Dictionary, available_outputs: Dictionary) -> bool:
	var input_ids: PackedStringArray = spec.input_good_ids
	if input_ids.is_empty():
		return false
	for i in range(input_ids.size()):
		if not _input_slot_ready(spec, i, available_outputs):
			return false
	return true

static func _input_slot_ready(spec: Dictionary, input_idx: int,
		available_outputs: Dictionary) -> bool:
	var input_ids: PackedStringArray = spec.get("input_good_ids", PackedStringArray())
	var input_categories: PackedStringArray = spec.get(
		"input_category_ids", PackedStringArray())
	if input_idx < 0 or input_idx >= input_ids.size():
		return false
	var category := String(input_categories[input_idx]) \
		if input_idx < input_categories.size() else ""
	if category != "" and available_outputs.has(StringName("category:%s" % category)):
		return true
	return available_outputs.has(StringName(input_ids[input_idx]))

static func _largest_nonmerchant_profession(jobs: Dictionary,
		profession_ids: PackedStringArray) -> StringName:
	var selected := StringName()
	var selected_population := 0
	for profession_id in profession_ids:
		var profession := StringName(profession_id)
		if profession == &"merchant":
			continue
		var population := int(jobs.get(profession, 0))
		if population > selected_population:
			selected = profession
			selected_population = population
	return selected

static func _append_building_group(cells: PackedInt32Array, types: PackedInt32Array,
		owners: PackedInt32Array, counts: PackedInt64Array, cell: int, type_id: int,
		owner_signature: int, count: int) -> void:
	if count <= 0:
		return
	cells.append(cell)
	types.append(type_id)
	owners.append(owner_signature)
	counts.append(count)

static func _accumulate_building_jobs(spec: Dictionary, count: int, jobs: Dictionary) -> void:
	if count <= 0:
		return
	var owner_profession := StringName(spec.owner_profession)
	jobs[owner_profession] = int(jobs.get(owner_profession, 0)) + count * int(spec.owner_slots)
	var professions: PackedStringArray = spec.employee_professions
	var slots: PackedInt64Array = spec.employee_slots
	for i in range(professions.size()):
		var profession := StringName(professions[i])
		var full_positions := count * int(slots[i])
		var retained_positions := full_positions * PLANNED_UTILIZATION_Q16 / Q16_ONE
		if retained_positions == 0 and full_positions > 0 and PLANNED_UTILIZATION_Q16 > 0:
			retained_positions = 1
		jobs[profession] = int(jobs.get(profession, 0)) + retained_positions
