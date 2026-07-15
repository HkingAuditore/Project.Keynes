class_name EconomyTestBootstrap
extends RefCounted

const GOODS_SCALE := 1000
const MONEY_SCALE := 10000
const COLLECTOR_COUNT_CAP := 24
const EXTRACT_RESERVE_DAYS := 5
const FOOD_REQUIREMENT_PER_CAPITA := 1300
const CLOTHING_REQUIREMENT_PER_CAPITA := 4

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
		if _technology_available(placement_spec.technology_tags):
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
	var neighbor_indices: PackedInt32Array = map.neighbor_indices_packed()
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
			var count := _collector_count_at(spec, cell_idx, resource_arrays, neighbor_indices,
				map.cell_count())
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

	var basic_capacity_trimmed_buildings := 0
	var basic_capacity_deficient_cells := 0
	var basic_capacity_cell_indices := PackedInt32Array()
	var basic_capacity_population := PackedInt64Array()
	var basic_food_capacity := PackedInt64Array()
	var basic_clothing_capacity := PackedInt64Array()
	for cell_idx in passable_cells:
		var balance := _balance_basic_capacity(groups_by_cell[cell_idx])
		basic_capacity_trimmed_buildings += int(balance.trimmed_buildings)
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

	for cell_idx in passable_cells:
		var generated_groups: Array = groups_by_cell[cell_idx]
		if generated_groups.is_empty():
			continue
		generated_groups.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
			return int(a.spec.type_id) < int(b.spec.type_id))
		for group in generated_groups:
			var job_spec: Dictionary = group.spec
			var count := int(group.count)
			_append_building_group(building_cells, building_types, building_owners,
				building_counts, cell_idx, int(job_spec.type_id),
				facade.signature_id(StringName(job_spec.owner_profession), &"default"), count)
			placed_building_types[StringName(job_spec.stable_id)] = true

		var jobs_by_profession := {}
		for group in generated_groups:
			_accumulate_building_jobs(group.spec, int(group.count), jobs_by_profession)
		var actual_population := 0
		for profession_id in profession_ids:
			var profession := StringName(profession_id)
			var population := int(jobs_by_profession.get(profession, 0))
			if population <= 0:
				continue
			cell_indices.append(cell_idx)
			signature_ids.append(int(signatures[profession]))
			populations.append(population)
			funds.append(population * _money_per_capita(profession) * MONEY_SCALE)
			actual_population += population
			generated_professions[profession] = true
		if actual_population > 0:
			populated_cells.append(cell_idx)
			total_population += actual_population

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
		"population_source": "mid_stone_visible_resources_capacity_balanced_unemployed_v6",
		"initial_employment": "unemployed",
		"initial_stock_units": 0,
		"technology_ids": PackedStringArray(MID_STONE_TECHNOLOGY_IDS),
		"visible_resource_type_count": resource_arrays.size(),
		"building_type_count": building_ids.size(),
		"eligible_building_type_count": eligible_building_ids.size(),
		"placed_building_type_count": placed_building_types.size(),
		"unplaced_building_type_count": building_ids.size() - placed_building_types.size(),
		"catalog_profession_count": profession_ids.size(),
		"generated_profession_count": generated_professions.size(),
		"basic_capacity_trimmed_buildings": basic_capacity_trimmed_buildings,
		"basic_capacity_deficient_cells": basic_capacity_deficient_cells,
		"food_requirement_per_capita": FOOD_REQUIREMENT_PER_CAPITA,
		"clothing_requirement_per_capita": CLOTHING_REQUIREMENT_PER_CAPITA,
		"basic_capacity_cell_indices": basic_capacity_cell_indices,
		"basic_capacity_population": basic_capacity_population,
		"basic_food_capacity": basic_food_capacity,
		"basic_clothing_capacity": basic_clothing_capacity,
		"good_count": facade.good_ids().size(),
	}


static func _balance_basic_capacity(groups: Array) -> Dictionary:
	var trimmed := 0
	while true:
		var totals := _basic_capacity_totals(groups)
		var population := int(totals.population)
		var current_deficit := _basic_capacity_deficit_people(totals)
		if population > 0 and current_deficit == 0:
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
			if deficit < best_deficit or \
					(best >= 0 and deficit == best_deficit and i > best):
				best = i
				best_deficit = deficit
		if best < 0:
			break
		groups[best].count = int(groups[best].count) - 1
		trimmed += 1
	for i in range(groups.size() - 1, -1, -1):
		if int(groups[i].count) <= 0:
			groups.remove_at(i)
	var final_totals := _basic_capacity_totals(groups)
	var final_population := int(final_totals.population)
	var covered := final_population > 0 and \
		int(final_totals.food) >= final_population * FOOD_REQUIREMENT_PER_CAPITA and \
		int(final_totals.clothing) >= final_population * CLOTHING_REQUIREMENT_PER_CAPITA
	if not covered:
		for group in groups:
			trimmed += maxi(0, int(group.count))
		groups.clear()
		final_totals = {"population": 0, "food": 0, "clothing": 0}
	return {
		"trimmed_buildings": trimmed,
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


static func _basic_capacity_totals(groups: Array) -> Dictionary:
	var population := 0
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
		resource_arrays: Dictionary, neighbor_indices: PackedInt32Array,
		cell_count: int) -> int:
	var resource_ids: PackedStringArray = spec.resource_ids
	var quantities: PackedInt64Array = spec.resource_quantities
	var modes: PackedInt32Array = spec.resource_modes
	var access_modes: PackedInt32Array = spec.resource_access_modes
	if resource_ids.is_empty() or resource_ids.size() != quantities.size() \
			or resource_ids.size() != modes.size() or resource_ids.size() != access_modes.size():
		return 0
	var supported := COLLECTOR_COUNT_CAP
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
		var available := _accessible_resource_reserve(reserves, cell_idx,
			int(access_modes[i]), neighbor_indices, cell_count)
		var local_supported := int(floor(available / required))
		if local_supported <= 0:
			return 0
		supported = mini(supported, local_supported)
	return clampi(supported, 0, COLLECTOR_COUNT_CAP)


static func _accessible_resource_reserve(reserves: PackedFloat32Array, cell_idx: int,
		access_mode: int, neighbor_indices: PackedInt32Array, cell_count: int) -> float:
	if cell_idx < 0 or cell_idx >= reserves.size():
		return 0.0
	var total := maxf(0.0, reserves[cell_idx])
	if access_mode != 1 or neighbor_indices.size() != cell_count * 6:
		return total
	var visited := {cell_idx: true}
	for direction in range(6):
		var neighbor := int(neighbor_indices[cell_idx * 6 + direction])
		if neighbor < 0 or neighbor >= reserves.size() or visited.has(neighbor):
			continue
		visited[neighbor] = true
		total += maxf(0.0, reserves[neighbor])
	return total


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


static func _money_per_capita(profession: StringName) -> int:
	if profession == &"landlord" or profession == &"industrialist":
		return 500
	if profession == &"merchant":
		return 200
	if profession == &"subsistence_farmer":
		return 20
	if profession in [&"artisan", &"chemist", &"electrician", &"engineer", &"machinist",
			&"metallurgist", &"petroleum_worker", &"technician"]:
		return 80
	return 40


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
