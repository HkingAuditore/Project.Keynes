class_name EconomyTestBootstrap
extends RefCounted

const GOODS_SCALE := 1000
const Q16_ONE := 65536
const INT64_MAX := 9223372036854775807
const COLLECTOR_COUNT_CAP := 24
const CELL_POPULATION_CAP := 300
const EXTRACT_RESERVE_DAYS := 5
const FOOD_REQUIREMENT_PER_CAPITA := 1300
const CLOTHING_REQUIREMENT_PER_CAPITA := 4
const SURVIVAL_FUND_DAYS := 30
const OWNER_OPERATING_CYCLES := 2
const MIN_SMALL_PROFESSION_POPULATION := 2

const TEST_COLLECTOR_COUNT_CAPS := {
	"flint_quarry": 1,
	"household_weaving_shelter": 2,
	"placer_gold_working": 1,
	"stone_collector": 1,
	"surface_silver_working": 1,
	"timber_collector": 3,
}

const MID_STONE_EXCLUDED_BUILDING_IDS := {
	"lumber_plant": true,
	"stone_collector": true,
}

const FOOD_GOOD_IDS := {
	"prepared_staples": true, "bread": true, "grain": true, "gathered_plants": true,
	"game_meat": true, "meat": true, "fish": true, "canned_fish": true,
	"dairy_products": true, "vegetables": true, "processed_food": true,
}
const CLOTHING_GOOD_IDS := {
	"cloth": true, "fur": true, "clothing": true, "footwear": true,
}

const MID_STONE_TECHNOLOGY_IDS := [
	"tech.hunting", "tech.gathering", "tech.stone_knapping", "tech.fire_control",
]


static func build(map: MapData, facade: EconomyFacade, _seed: int) -> Dictionary:
	if map == null or facade == null or not facade.is_configured():
		return {"ok": false, "reason": "test_bootstrap_runtime_unavailable"}
	var profession_ids := facade.profession_ids()
	var signatures := {}
	for profession_id in profession_ids:
		var signature := facade.signature_id(StringName(profession_id), &"default")
		if signature < 0:
			return {
				"ok": false,
				"reason": "test_bootstrap_catalog_incomplete",
				"missing_signature": "%s|default" % String(profession_id),
			}
		signatures[StringName(profession_id)] = signature
	var building_ids := facade.building_type_ids()
	var finance: Dictionary = facade.bootstrap_finance_columns()
	if building_ids.is_empty():
		return {"ok": false, "reason": "test_bootstrap_building_catalog_empty"}
	var building_specs := {}
	var eligible_building_ids := PackedStringArray()
	for building_id in building_ids:
		var job_spec: Dictionary = facade.building_job_spec(StringName(building_id))
		var placement_spec: Dictionary = facade.building_placement_spec(StringName(building_id))
		if not bool(job_spec.get("ok", false)) or not bool(placement_spec.get("ok", false)):
			return {
				"ok": false,
				"reason": "test_bootstrap_building_catalog_incomplete",
				"missing_building": String(building_id),
			}
		for key in placement_spec:
			job_spec[key] = placement_spec[key]
		building_specs[StringName(building_id)] = job_spec
		if _technology_available(placement_spec.technology_tags) and not \
			MID_STONE_EXCLUDED_BUILDING_IDS.has(String(building_id)):
			eligible_building_ids.append(building_id)
	var highest_tier_by_family := {}
	for building_id in eligible_building_ids:
		var spec: Dictionary = building_specs[StringName(building_id)]
		var family := String(spec.get("upgrade_family_id", ""))
		if family != "":
			highest_tier_by_family[family] = maxi(
				int(highest_tier_by_family.get(family, 0)), int(spec.get("upgrade_tier", 0)))
	var filtered_eligible := PackedStringArray()
	for building_id in eligible_building_ids:
		var spec: Dictionary = building_specs[StringName(building_id)]
		var family := String(spec.get("upgrade_family_id", ""))
		if family == "" or int(spec.get("upgrade_tier", 0)) == int(
				highest_tier_by_family.get(family, 0)):
			filtered_eligible.append(building_id)
	eligible_building_ids = filtered_eligible
	if eligible_building_ids.is_empty():
		return {"ok": false, "reason": "test_bootstrap_mid_stone_catalog_empty"}

	var passable_cells := PackedInt32Array()
	for cell_idx in range(map.cell_count()):
		var terrain := _terrain_at(map, cell_idx)
		if not MapData.terrain_is_water(terrain) and TerrainType.is_passable_land(terrain):
			passable_cells.append(cell_idx)
	if passable_cells.is_empty():
		return {"ok": false, "reason": "test_bootstrap_no_passable_land"}
	var resource_arrays := _resource_arrays(map, PackedStringArray(MID_STONE_TECHNOLOGY_IDS))
	var groups_by_cell := {}
	var outputs_by_cell := {}
	for cell_idx in passable_cells:
		groups_by_cell[cell_idx] = []
		outputs_by_cell[cell_idx] = {}

	for building_id_raw in eligible_building_ids:
		var building_id := StringName(building_id_raw)
		var spec: Dictionary = building_specs[building_id]
		if int(spec.kind) != 0:
			continue
		for cell_idx in passable_cells:
			var count := _collector_count_at(spec, cell_idx, resource_arrays)
			if count <= 0:
				continue
			(groups_by_cell[cell_idx] as Array).append({"spec": spec, "count": count})
			_mark_outputs(spec, outputs_by_cell[cell_idx])

	var pending_industries := []
	for building_id_raw in eligible_building_ids:
		var building_id := StringName(building_id_raw)
		var spec: Dictionary = building_specs[building_id]
		if int(spec.kind) == 1:
			pending_industries.append(spec)
	while not pending_industries.is_empty():
		var placed_any := false
		for i in range(pending_industries.size() - 1, -1, -1):
			var spec: Dictionary = pending_industries[i]
			var selected_cells := PackedInt32Array()
			for cell_idx in passable_cells:
				if _inputs_ready(spec, outputs_by_cell[cell_idx]):
					selected_cells.append(cell_idx)
			if selected_cells.is_empty():
				continue
			pending_industries.remove_at(i)
			placed_any = true
			for cell_idx in selected_cells:
				(groups_by_cell[cell_idx] as Array).append({"spec": spec, "count": 1})
				_mark_outputs(spec, outputs_by_cell[cell_idx])
		if not placed_any:
			break

	var merchant_post_spec: Dictionary = building_specs.get(&"merchant_post", {})
	var merchant_post_available := not merchant_post_spec.is_empty() \
		and _technology_available(merchant_post_spec.get("technology_tags", PackedStringArray()))
	var basic_capacity_initial_buildings := 0
	var basic_capacity_trimmed_buildings := 0
	var basic_capacity_deficient_cells := 0
	var carrying_capacity_cell_indices := PackedInt32Array()
	var carrying_capacity_population := PackedInt64Array()
	var carrying_capacity_min := CELL_POPULATION_CAP
	var carrying_capacity_max := 0
	var carrying_capacity_total := 0
	var basic_capacity_cell_indices := PackedInt32Array()
	var basic_capacity_population := PackedInt64Array()
	var basic_food_capacity := PackedInt64Array()
	var basic_clothing_capacity := PackedInt64Array()
	for cell_idx in passable_cells:
		for group in groups_by_cell[cell_idx]:
			basic_capacity_initial_buildings += maxi(0, int(group.count))
		var reserved_population := 1 if merchant_post_available and not \
			(groups_by_cell[cell_idx] as Array).is_empty() else 0
		var balance := _balance_basic_capacity(
			groups_by_cell[cell_idx], reserved_population)
		basic_capacity_trimmed_buildings += int(balance.trimmed_buildings)
		carrying_capacity_cell_indices.append(cell_idx)
		var target_population := int(balance.target_population)
		carrying_capacity_population.append(target_population)
		carrying_capacity_min = mini(carrying_capacity_min, target_population)
		carrying_capacity_max = maxi(carrying_capacity_max, target_population)
		carrying_capacity_total += target_population
		if not bool(balance.covered):
			basic_capacity_deficient_cells += 1
		var totals: Dictionary = balance.totals
		if int(totals.population) > 0:
			basic_capacity_cell_indices.append(cell_idx)
			basic_capacity_population.append(int(totals.population))
			basic_food_capacity.append(int(totals.food))
			basic_clothing_capacity.append(int(totals.clothing))

	var cell_indices := PackedInt32Array()
	var signature_ids := PackedInt32Array()
	var populations := PackedInt64Array()
	var funds := PackedInt64Array()
	var populated_cells := PackedInt32Array()
	var total_population := 0
	var building_cells := PackedInt32Array()
	var building_types := PackedInt32Array()
	var building_owners := PackedInt32Array()
	var building_counts := PackedInt64Array()
	var generated_professions := {}
	var placed_building_types := {}
	var merchant_bootstrap_substitutions := 0
	var owner_daily_input_cost_by_key := {}
	var merchant_daily_inventory_value_by_cell := {}

	# Route B: every populated cell gets exactly one merchant post (商栈). Its
	# owner (merchant) is the cell's market maker and now lives inside the
	# employment system as a real building owner. A cell has population iff it
	# already holds at least one collector/industrial group, so we attach the
	# post to those cells. This replaces the old "carve a merchant out of the
	# largest non-merchant profession" substitution (189-199 below): the post's
	# owner accumulates merchant jobs directly, so that path stops firing.
	for cell_idx in passable_cells:
		var generated_groups: Array = groups_by_cell[cell_idx]
		if generated_groups.is_empty():
			continue
		if merchant_post_available:
			generated_groups.append({"spec": merchant_post_spec, "count": 1})
		generated_groups.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
			return int(a.spec.type_id) < int(b.spec.type_id))
		for group in generated_groups:
			var job_spec: Dictionary = group.spec
			var count := int(group.count)
			var owner_signature := facade.signature_id(
				StringName(job_spec.owner_profession), &"default")
			_append_building_group(building_cells, building_types, building_owners,
				building_counts, cell_idx, int(job_spec.type_id),
				owner_signature, count)
			var owner_key := "%d:%d" % [cell_idx, owner_signature]
			owner_daily_input_cost_by_key[owner_key] = int(
				owner_daily_input_cost_by_key.get(owner_key, 0)) + \
				_default_input_cost_per_day(job_spec, finance) * count
			merchant_daily_inventory_value_by_cell[cell_idx] = int(
				merchant_daily_inventory_value_by_cell.get(cell_idx, 0)) + \
				_default_output_inventory_value_per_day(job_spec, finance) * count
			placed_building_types[StringName(job_spec.stable_id)] = true

		var jobs_by_profession := {}
		for group in generated_groups:
			_accumulate_building_jobs(group.spec, int(group.count), jobs_by_profession)
		if int(jobs_by_profession.get(&"merchant", 0)) <= 0:
			var merchant_source := _largest_nonmerchant_profession(
				jobs_by_profession, profession_ids)
			if merchant_source != &"":
				jobs_by_profession[merchant_source] = \
					int(jobs_by_profession.get(merchant_source, 0)) - 1
				jobs_by_profession[&"merchant"] = 1
				merchant_bootstrap_substitutions += 1
		var actual_population := 0
		for profession_id in profession_ids:
			var profession := StringName(profession_id)
			var population := int(jobs_by_profession.get(profession, 0))
			if population <= 0:
				continue
			if population < MIN_SMALL_PROFESSION_POPULATION and profession != &"merchant":
				population = MIN_SMALL_PROFESSION_POPULATION
			cell_indices.append(cell_idx)
			signature_ids.append(int(signatures[profession]))
			populations.append(population)
			funds.append(0)
			actual_population += population
			generated_professions[profession] = true
		if actual_population > 0:
			populated_cells.append(cell_idx)
			total_population += actual_population
			var capacity_idx := carrying_capacity_cell_indices.find(cell_idx)
			if capacity_idx >= 0:
				carrying_capacity_population[capacity_idx] = actual_population

	carrying_capacity_min = CELL_POPULATION_CAP
	carrying_capacity_max = 0
	carrying_capacity_total = 0
	for population in carrying_capacity_population:
		carrying_capacity_min = mini(carrying_capacity_min, int(population))
		carrying_capacity_max = maxi(carrying_capacity_max, int(population))
		carrying_capacity_total += int(population)

	var cycle_days := facade.bootstrap_cycle_days(populations.size())
	var initial_survival_funds := 0
	var initial_owner_operating_funds := 0
	var initial_merchant_inventory_funds := 0
	var survival_funds_by_cohort := PackedInt64Array()
	var owner_operating_funds_by_cohort := PackedInt64Array()
	var merchant_inventory_funds_by_cohort := PackedInt64Array()
	var merchant_signature := int(signatures.get(&"merchant", -1))
	for cohort in range(populations.size()):
		var cell_idx := int(cell_indices[cohort])
		var signature_id := int(signature_ids[cohort])
		var survival := _sat_mul_nonnegative(_sat_mul_nonnegative(
			_survival_cost_per_person_per_day(map, cell_idx, signature_id, finance),
			int(populations[cohort])), SURVIVAL_FUND_DAYS)
		var owner := _sat_mul_nonnegative(_sat_mul_nonnegative(int(
			owner_daily_input_cost_by_key.get("%d:%d" % [cell_idx, signature_id], 0)),
			cycle_days), OWNER_OPERATING_CYCLES)
		var merchant := int(merchant_daily_inventory_value_by_cell.get(cell_idx, 0)) \
			if signature_id == merchant_signature else 0
		funds[cohort] = _sat_add_nonnegative(
			_sat_add_nonnegative(survival, owner), merchant)
		survival_funds_by_cohort.append(survival)
		owner_operating_funds_by_cohort.append(owner)
		merchant_inventory_funds_by_cohort.append(merchant)
		initial_survival_funds = _sat_add_nonnegative(initial_survival_funds, survival)
		initial_owner_operating_funds = _sat_add_nonnegative(
			initial_owner_operating_funds, owner)
		initial_merchant_inventory_funds = _sat_add_nonnegative(
			initial_merchant_inventory_funds, merchant)

	return {
		"ok": true,
		"population_packet": {
			"cell_indices": cell_indices,
			"signature_ids": signature_ids,
			"population": populations,
			"funds": funds,
		},
		"market_packet": {},
		"building_packet": {
			"building_cells": building_cells,
			"building_type_ids": building_types,
			"building_owner_signature_ids": building_owners,
			"building_counts": building_counts,
		},
		"populated_cells": populated_cells.size(),
		"cohort_count": populations.size(),
		"building_group_count": building_counts.size(),
		"total_population": total_population,
		"population_source": "mid_stone_visible_resources_carrying_capacity_bootstrap_finance_v11",
		"cell_population_cap": CELL_POPULATION_CAP,
		"initial_employment": "unemployed",
		"initial_stock_units": 0,
		"bootstrap_cycle_days": cycle_days,
		"survival_fund_days": SURVIVAL_FUND_DAYS,
		"owner_operating_cycles": OWNER_OPERATING_CYCLES,
		"initial_survival_funds": initial_survival_funds,
		"initial_owner_operating_funds": initial_owner_operating_funds,
		"initial_merchant_inventory_funds": initial_merchant_inventory_funds,
		"survival_funds_by_cohort": survival_funds_by_cohort,
		"owner_operating_funds_by_cohort": owner_operating_funds_by_cohort,
		"merchant_inventory_funds_by_cohort": merchant_inventory_funds_by_cohort,
		"merchant_bootstrap_substitutions": merchant_bootstrap_substitutions,
		"technology_ids": PackedStringArray(MID_STONE_TECHNOLOGY_IDS),
		"visible_resource_type_count": resource_arrays.size(),
		"building_type_count": building_ids.size(),
		"eligible_building_type_count": eligible_building_ids.size(),
		"placed_building_type_count": placed_building_types.size(),
		"unplaced_building_type_count": building_ids.size() - placed_building_types.size(),
		"catalog_profession_count": profession_ids.size(),
		"generated_profession_count": generated_professions.size(),
		"basic_capacity_initial_buildings": basic_capacity_initial_buildings,
		"basic_capacity_final_buildings":
			basic_capacity_initial_buildings - basic_capacity_trimmed_buildings,
		"basic_capacity_trimmed_buildings": basic_capacity_trimmed_buildings,
		"basic_capacity_deficient_cells": basic_capacity_deficient_cells,
		"carrying_capacity_cell_indices": carrying_capacity_cell_indices,
		"carrying_capacity_population": carrying_capacity_population,
		"carrying_capacity_min": carrying_capacity_min,
		"carrying_capacity_max": carrying_capacity_max,
		"carrying_capacity_total": carrying_capacity_total,
		"food_requirement_per_capita": FOOD_REQUIREMENT_PER_CAPITA,
		"clothing_requirement_per_capita": CLOTHING_REQUIREMENT_PER_CAPITA,
		"basic_capacity_cell_indices": basic_capacity_cell_indices,
		"basic_capacity_population": basic_capacity_population,
		"basic_food_capacity": basic_food_capacity,
		"basic_clothing_capacity": basic_clothing_capacity,
		"good_count": facade.good_ids().size(),
	}


static func _balance_basic_capacity(groups: Array, reserved_population: int = 0) -> Dictionary:
	var trimmed := 0
	var initial_totals := _basic_capacity_totals(groups, reserved_population)
	var target_population := _carrying_capacity_population(initial_totals)
	while true:
		var totals := _basic_capacity_totals(groups, reserved_population)
		var population := int(totals.population)
		var current_deficit := _basic_capacity_deficit_people(totals)
		if population <= target_population and current_deficit == 0:
			break
		var best := -1
		var best_deficit := current_deficit
		for i in range(groups.size()):
			var group: Dictionary = groups[i]
			if int(group.count) <= 1:
				continue
			var per_building := _building_basic_capacity(group.spec)
			var next_population := maxi(0, population - int(per_building.jobs))
			var next_food := int(totals.food) - int(per_building.food)
			var next_clothing := int(totals.clothing) - int(per_building.clothing)
			if next_population <= 0:
				continue
			var deficit := _basic_capacity_deficit_people({
				"population": next_population,
				"food": next_food,
				"clothing": next_clothing,
			})
			var acceptable := deficit < current_deficit or \
				(current_deficit == 0 and population > target_population and deficit == 0)
			if acceptable and (best < 0 or deficit < best_deficit or \
					(deficit == best_deficit and i > best)):
				best = i
				best_deficit = deficit
		if best < 0:
			break
		groups[best].count = int(groups[best].count) - 1
		trimmed += 1
	for i in range(groups.size() - 1, -1, -1):
		if int(groups[i].count) <= 0:
			groups.remove_at(i)
	var final_totals := _basic_capacity_totals(groups, reserved_population)
	var final_population := int(final_totals.population)
	var covered := final_population > 0 and \
		int(final_totals.food) >= final_population * FOOD_REQUIREMENT_PER_CAPITA and \
		int(final_totals.clothing) >= final_population * CLOTHING_REQUIREMENT_PER_CAPITA
	if not covered:
		for group in groups:
			trimmed += maxi(0, int(group.count))
		groups.clear()
		target_population = 0
		final_totals = {"population": 0, "food": 0, "clothing": 0}
	return {
		"trimmed_buildings": trimmed,
		"target_population": target_population,
		"covered": covered,
		"totals": final_totals,
	}


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
	var clothing_capacity := int(
		maxi(0, int(totals.clothing)) / CLOTHING_REQUIREMENT_PER_CAPITA)
	return clampi(mini(workforce, mini(food_capacity, clothing_capacity)),
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


static func _resource_arrays(map: MapData, technology_ids: PackedStringArray) -> Dictionary:
	ResourceProfileRegistry.ensure_loaded()
	var out := {}
	for profile in ResourceProfileRegistry.ordered():
		if not ResourceProfileRegistry.discovery_visible(profile, technology_ids):
			continue
		var field := ResourceProfileRegistry.reserve_map_field(profile)
		if field == "":
			continue
		var values: PackedFloat32Array = map.get(field)
		if values.size() >= map.cell_count():
			out[StringName(profile.id)] = values
	return out


static func _collector_count_at(spec: Dictionary, cell_idx: int,
		resource_arrays: Dictionary) -> int:
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
		if int(modes[i]) == 0:
			required *= EXTRACT_RESERVE_DAYS
		if cell_idx < 0 or cell_idx >= reserves.size() or required <= 0.0:
			return 0
		if int(access_modes[i]) != 0:
			return 0
		var available := maxf(0.0, reserves[cell_idx])
		var local_supported := int(floor(available / required))
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
	var input_categories: PackedStringArray = spec.get(
		"input_category_ids", PackedStringArray())
	if input_ids.is_empty():
		return false
	for i in range(input_ids.size()):
		var category := String(input_categories[i]) if i < input_categories.size() else ""
		if category != "" and available_outputs.has(StringName("category:%s" % category)):
			continue
		if not available_outputs.has(StringName(input_ids[i])):
			return false
	return true


static func _technology_available(tags: PackedStringArray) -> bool:
	for tag in tags:
		var stable_id := String(tag)
		if stable_id.begins_with("tech.") and not MID_STONE_TECHNOLOGY_IDS.has(stable_id):
			return false
	return true


static func _default_input_cost_per_day(spec: Dictionary, finance: Dictionary) -> int:
	var good_ids: PackedStringArray = finance.get("good_ids", PackedStringArray())
	var prices: PackedInt32Array = finance.get("good_default_price", PackedInt32Array())
	var quantities: PackedInt64Array = spec.get("input_quantities", PackedInt64Array())
	var offsets: PackedInt32Array = spec.get("input_candidate_offsets", PackedInt32Array())
	var candidates: PackedStringArray = spec.get("input_candidate_good_ids", PackedStringArray())
	var efficiencies: PackedInt32Array = spec.get(
		"input_candidate_efficiency_q16", PackedInt32Array())
	var total := 0
	for input_idx in range(quantities.size()):
		if input_idx + 1 >= offsets.size():
			continue
		var cheapest := -1
		for candidate_idx in range(int(offsets[input_idx]), int(offsets[input_idx + 1])):
			if candidate_idx >= candidates.size() or candidate_idx >= efficiencies.size():
				continue
			var good_idx := good_ids.find(String(candidates[candidate_idx]))
			var efficiency := int(efficiencies[candidate_idx])
			if good_idx < 0 or good_idx >= prices.size() or efficiency <= 0:
				continue
			var physical := (int(quantities[input_idx]) * Q16_ONE + efficiency - 1) / efficiency
			var cost := physical * int(prices[good_idx]) / GOODS_SCALE
			if cheapest < 0 or cost < cheapest:
				cheapest = cost
		if cheapest > 0:
			total += cheapest
	return total


static func _default_output_inventory_value_per_day(
		spec: Dictionary, finance: Dictionary) -> int:
	var good_ids: PackedStringArray = finance.get("good_ids", PackedStringArray())
	var prices: PackedInt32Array = finance.get("good_default_price", PackedInt32Array())
	var target_days: PackedInt32Array = finance.get(
		"good_target_inventory_days_q16", PackedInt32Array())
	var buy_factors: PackedInt32Array = finance.get(
		"good_merchant_buy_factor_q16", PackedInt32Array())
	var issue_values: PackedInt64Array = finance.get(
		"good_monetary_issue_values", PackedInt64Array())
	var outputs: PackedStringArray = spec.get("output_good_ids", PackedStringArray())
	var quantities: PackedInt64Array = spec.get("output_quantities", PackedInt64Array())
	var total := 0
	for output_idx in range(mini(outputs.size(), quantities.size())):
		var good_idx := good_ids.find(String(outputs[output_idx]))
		if good_idx < 0 or good_idx >= prices.size() or good_idx >= target_days.size() \
				or good_idx >= buy_factors.size():
			continue
		if good_idx < issue_values.size() and int(issue_values[good_idx]) > 0:
			continue
		var target_quantity := int(quantities[output_idx]) * int(target_days[good_idx]) / Q16_ONE
		var buy_price := int(prices[good_idx]) * int(buy_factors[good_idx]) / Q16_ONE
		total += target_quantity * buy_price / GOODS_SCALE
	return total


static func _survival_cost_per_person_per_day(
		map: MapData, cell_idx: int, signature_id: int, finance: Dictionary) -> int:
	var plan_ids: PackedStringArray = finance.get("plan_ids", PackedStringArray())
	var plan_id := plan_ids.find(String(finance.get(
		"living_cost_base_plan_id", "survival_household")))
	var plan_offsets: PackedInt32Array = finance.get("plan_need_offsets", PackedInt32Array())
	var signature_ethnicity: PackedInt32Array = finance.get(
		"signature_ethnicity_ids", PackedInt32Array())
	if plan_id < 0 or plan_id + 1 >= plan_offsets.size() \
			or signature_id < 0 or signature_id >= signature_ethnicity.size():
		return 0
	var need_ids: PackedStringArray = finance.get("need_ids", PackedStringArray())
	var living_weights: PackedInt32Array = finance.get(
		"need_living_cost_weights_q16", PackedInt32Array())
	var stable_needs: PackedInt32Array = finance.get("need_stable_ids", PackedInt32Array())
	var base_quantities: PackedInt64Array = finance.get(
		"need_base_qty_per_person", PackedInt64Array())
	var need_curves: PackedInt32Array = finance.get(
		"need_quantity_env_curve_ids", PackedInt32Array())
	var need_variant_offsets: PackedInt32Array = finance.get(
		"need_variant_offsets", PackedInt32Array())
	var preferences: PackedInt32Array = finance.get(
		"variant_preference_q16", PackedInt32Array())
	var preference_curves: PackedInt32Array = finance.get(
		"variant_preference_env_curve_ids", PackedInt32Array())
	var component_offsets: PackedInt32Array = finance.get(
		"variant_component_offsets", PackedInt32Array())
	var component_goods: PackedInt32Array = finance.get(
		"component_good_ids", PackedInt32Array())
	var component_quantities: PackedInt64Array = finance.get(
		"component_qty_per_need", PackedInt64Array())
	var prices: PackedInt32Array = finance.get("good_default_price", PackedInt32Array())
	var ethnicity_factors: PackedInt32Array = finance.get(
		"ethnicity_need_factor_q16", PackedInt32Array())
	var ethnicity := int(signature_ethnicity[signature_id])
	var total := 0
	for need_idx in range(int(plan_offsets[plan_id]), int(plan_offsets[plan_id + 1])):
		if need_idx >= stable_needs.size() or need_idx >= base_quantities.size() \
				or need_idx >= need_curves.size() or need_idx + 1 >= need_variant_offsets.size():
			continue
		var stable_need := int(stable_needs[need_idx])
		if stable_need < 0 or stable_need >= living_weights.size():
			continue
		var score_sum := 0
		var weighted_price := 0
		for variant in range(int(need_variant_offsets[need_idx]),
				int(need_variant_offsets[need_idx + 1])):
			if variant >= preferences.size() or variant >= preference_curves.size() \
					or variant + 1 >= component_offsets.size():
				continue
			var unit_price := 0
			for component in range(int(component_offsets[variant]),
					int(component_offsets[variant + 1])):
				if component >= component_goods.size() or component >= component_quantities.size():
					continue
				var good_idx := int(component_goods[component])
				if good_idx >= 0 and good_idx < prices.size():
					unit_price += int(component_quantities[component]) * int(prices[good_idx]) / GOODS_SCALE
			var score := int(preferences[variant]) * _sample_environment_curve(
				finance, int(preference_curves[variant]), map, cell_idx) / Q16_ONE
			score_sum += maxi(0, score)
			weighted_price += maxi(1, unit_price) * maxi(0, score)
		if score_sum <= 0:
			continue
		var quantity := int(base_quantities[need_idx]) * int(living_weights[stable_need]) / Q16_ONE
		quantity = quantity * _sample_environment_curve(
			finance, int(need_curves[need_idx]), map, cell_idx) / Q16_ONE
		var factor_index := ethnicity * need_ids.size() + stable_need
		if factor_index >= 0 and factor_index < ethnicity_factors.size():
			quantity = quantity * int(ethnicity_factors[factor_index]) / Q16_ONE
		total += quantity * (weighted_price / score_sum) / GOODS_SCALE
	return maxi(0, total)


static func _sample_environment_curve(
		finance: Dictionary, curve_id: int, map: MapData, cell_idx: int) -> int:
	if curve_id < 0:
		return Q16_ONE
	var signals: PackedInt32Array = finance.get(
		"environment_curve_signal_ids", PackedInt32Array())
	var values: PackedInt32Array = finance.get(
		"environment_curve_values_q16", PackedInt32Array())
	if curve_id >= signals.size() or (curve_id + 1) * 17 > values.size():
		return 0
	var signal_q16 := _environment_signal_q16(map, cell_idx, int(signals[curve_id]))
	var scaled := clampi(signal_q16, 0, Q16_ONE) * 16
	var lo := mini(16, scaled / Q16_ONE)
	var hi := mini(16, lo + 1)
	var fraction := scaled - lo * Q16_ONE
	var begin := curve_id * 17
	return int(values[begin + lo]) + \
		(int(values[begin + hi]) - int(values[begin + lo])) * fraction / Q16_ONE


static func _environment_signal_q16(map: MapData, cell_idx: int, signal_id: int) -> int:
	var values: PackedFloat32Array
	var fallback := 0.0
	match signal_id:
		0:
			values = map.temp_arr
			fallback = 0.5
		1:
			values = map.moisture_arr
			fallback = 0.5
		2:
			values = map.snow_cover_arr
		3:
			values = map.weather_intensity_arr
		_:
			return 0
	var value := float(values[cell_idx]) if cell_idx >= 0 and cell_idx < values.size() else fallback
	if not is_finite(value):
		value = fallback
	return clampi(roundi(clampf(value, 0.0, 1.0) * Q16_ONE), 0, Q16_ONE)


static func _sat_add_nonnegative(a: int, b: int) -> int:
	a = maxi(0, a)
	b = maxi(0, b)
	return INT64_MAX if a > INT64_MAX - b else a + b


static func _sat_mul_nonnegative(a: int, b: int) -> int:
	a = maxi(0, a)
	b = maxi(0, b)
	if a == 0 or b == 0:
		return 0
	return INT64_MAX if a > INT64_MAX / b else a * b


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
		jobs[profession] = int(jobs.get(profession, 0)) + count * int(slots[i])


static func _terrain_at(map: MapData, cell_idx: int) -> int:
	if cell_idx >= 0 and cell_idx < map.terrain_arr.size():
		return int(map.terrain_arr[cell_idx])
	var cell := map.cell_at(cell_idx)
	return int(cell.terrain) if cell != null else TerrainType.TERRAIN.OCEAN
