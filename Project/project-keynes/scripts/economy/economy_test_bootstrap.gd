class_name EconomyTestBootstrap
extends RefCounted

const GOODS_SCALE := 1000
const MONEY_SCALE := 10000
const STOCK_DAYS := 30
const MERCHANT_CAPACITY_PERCENT := 1
const COLLECTOR_COUNT_CAP := 24
const EXTRACT_RESERVE_DAYS := 5
const INDUSTRIAL_CELL_DIVISOR := 12
const INDUSTRIAL_CELL_CAP := 24

const BASE_BUILDING_IDS := [
	&"distribution_center",
]


static func build(map: MapData, facade: EconomyFacade, seed: int) -> Dictionary:
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
	for building_id in BASE_BUILDING_IDS:
		if not building_specs.has(building_id):
			return {
				"ok": false,
				"reason": "test_bootstrap_base_building_missing",
				"missing_building": String(building_id),
			}

	var passable_cells := PackedInt32Array()
	for cell_idx in range(map.cell_count()):
		var terrain := _terrain_at(map, cell_idx)
		if not MapData.terrain_is_water(terrain) and TerrainType.is_passable_land(terrain):
			passable_cells.append(cell_idx)
	if passable_cells.is_empty():
		return {"ok": false, "reason": "test_bootstrap_no_passable_land"}
	var resource_arrays := _resource_arrays(map)
	var neighbor_indices: PackedInt32Array = map.neighbor_indices_packed()
	var groups_by_cell := {}
	var outputs_by_cell := {}
	var produced_goods := {}
	var target_settlement_capacity := 0
	for cell_idx in passable_cells:
		var settlement_capacity := 1000 + _population_jitter(seed, cell_idx)
		target_settlement_capacity += settlement_capacity
		var distribution: Dictionary = building_specs[&"distribution_center"]
		var distribution_count := _ceil_div(
			maxi(1, settlement_capacity * MERCHANT_CAPACITY_PERCENT / 100),
			int(distribution.owner_slots))
		groups_by_cell[cell_idx] = [{"spec": distribution, "count": distribution_count}]
		outputs_by_cell[cell_idx] = {}
		_mark_outputs(distribution, outputs_by_cell[cell_idx], produced_goods)

	for building_id_raw in building_ids:
		var building_id := StringName(building_id_raw)
		var spec: Dictionary = building_specs[building_id]
		if building_id in BASE_BUILDING_IDS or int(spec.kind) != 0:
			continue
		for cell_idx in passable_cells:
			var count := _collector_count_at(spec, cell_idx, resource_arrays, neighbor_indices,
				map.cell_count())
			if count <= 0:
				continue
			(groups_by_cell[cell_idx] as Array).append({"spec": spec, "count": count})
			_mark_outputs(spec, outputs_by_cell[cell_idx], produced_goods)

	var pending_industries := []
	for building_id_raw in building_ids:
		var building_id := StringName(building_id_raw)
		var spec: Dictionary = building_specs[building_id]
		if building_id not in BASE_BUILDING_IDS and int(spec.kind) == 1:
			pending_industries.append(spec)
	while not pending_industries.is_empty():
		var best_idx := 0
		var best_readiness := -1
		for i in range(pending_industries.size()):
			var readiness := _input_readiness(pending_industries[i], produced_goods)
			if readiness > best_readiness:
				best_readiness = readiness
				best_idx = i
		var spec: Dictionary = pending_industries.pop_at(best_idx)
		for cell_idx in _select_industrial_cells(
				spec, passable_cells, outputs_by_cell, seed):
			(groups_by_cell[cell_idx] as Array).append({"spec": spec, "count": 1})
			_mark_outputs(spec, outputs_by_cell[cell_idx], produced_goods)

	var cell_indices := PackedInt32Array()
	var signature_ids := PackedInt32Array()
	var populations := PackedInt64Array()
	var funds := PackedInt64Array()
	var populated_cells := PackedInt32Array()
	var population_by_cell := PackedInt64Array()
	population_by_cell.resize(map.cell_count())
	population_by_cell.fill(0)
	var building_cells := PackedInt32Array()
	var building_types := PackedInt32Array()
	var building_owners := PackedInt32Array()
	var building_counts := PackedInt64Array()
	var generated_professions := {}
	var placed_building_types := {}

	for cell_idx in passable_cells:
		var generated_groups: Array = groups_by_cell[cell_idx]
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
		populated_cells.append(cell_idx)
		population_by_cell[cell_idx] = actual_population

	var good_ids := facade.good_ids()
	var stock := PackedInt64Array()
	stock.resize(map.cell_count() * good_ids.size())
	stock.fill(0)
	for cell_idx in populated_cells:
		var stock_per_good := int(population_by_cell[cell_idx]) * STOCK_DAYS * GOODS_SCALE
		var row_begin := int(cell_idx) * good_ids.size()
		for good_idx in range(good_ids.size()):
			stock[row_begin + good_idx] = stock_per_good

	return {
		"ok": true,
		"population_packet": {
			"cell_indices": cell_indices,
			"signature_ids": signature_ids,
			"population": populations,
			"funds": funds,
		},
		"market_packet": {"stock": stock},
		"building_packet": {
			"building_cells": building_cells,
			"building_type_ids": building_types,
			"building_owner_signature_ids": building_owners,
			"building_counts": building_counts,
		},
		"populated_cells": populated_cells.size(),
		"cohort_count": populations.size(),
		"building_group_count": building_counts.size(),
		"total_population": _sum_i64(population_by_cell),
		"target_settlement_capacity": target_settlement_capacity,
		"population_source": "resource_specialized_building_jobs_v4",
		"building_type_count": building_ids.size(),
		"placed_building_type_count": placed_building_types.size(),
		"unplaced_building_type_count": building_ids.size() - placed_building_types.size(),
		"catalog_profession_count": profession_ids.size(),
		"generated_profession_count": generated_professions.size(),
		"good_count": good_ids.size(),
}


static func _resource_arrays(map: MapData) -> Dictionary:
	ResourceProfileRegistry.ensure_loaded()
	var out := {}
	for profile in ResourceProfileRegistry.ordered():
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


static func _mark_outputs(spec: Dictionary, local_outputs: Dictionary,
		global_outputs: Dictionary) -> void:
	var output_ids: PackedStringArray = spec.output_good_ids
	for good_id in output_ids:
		local_outputs[StringName(good_id)] = true
		global_outputs[StringName(good_id)] = true


static func _input_readiness(spec: Dictionary, available_outputs: Dictionary) -> int:
	var score := 0
	var input_ids: PackedStringArray = spec.input_good_ids
	for good_id in input_ids:
		if available_outputs.has(StringName(good_id)):
			score += 1
	return score


static func _select_industrial_cells(spec: Dictionary, passable_cells: PackedInt32Array,
		outputs_by_cell: Dictionary, seed: int) -> PackedInt32Array:
	var scored := []
	for cell_idx in passable_cells:
		var upstream := _input_readiness(spec, outputs_by_cell[cell_idx])
		var tie_break := int(hash("%d:%d:%s" % [seed, cell_idx, String(spec.stable_id)])) \
			& 0x3fffffff
		scored.append({"cell": int(cell_idx), "score": upstream * 0x40000000 + tie_break})
	scored.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		if int(a.score) != int(b.score):
			return int(a.score) > int(b.score)
		return int(a.cell) < int(b.cell))
	var target_count := clampi(_ceil_div(passable_cells.size(), INDUSTRIAL_CELL_DIVISOR),
		1, mini(INDUSTRIAL_CELL_CAP, passable_cells.size()))
	var selected := PackedInt32Array()
	for i in range(target_count):
		selected.append(int(scored[i].cell))
	return selected


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


static func _ceil_div(numerator: int, denominator: int) -> int:
	if numerator <= 0:
		return 0
	return (numerator + maxi(1, denominator) - 1) / maxi(1, denominator)


static func _terrain_at(map: MapData, cell_idx: int) -> int:
	if cell_idx >= 0 and cell_idx < map.terrain_arr.size():
		return int(map.terrain_arr[cell_idx])
	var cell := map.cell_at(cell_idx)
	return int(cell.terrain) if cell != null else TerrainType.TERRAIN.OCEAN


static func _population_jitter(seed: int, cell_idx: int) -> int:
	var seed_part := absi(seed % 2147483647)
	return int((seed_part * 1103 + cell_idx * 9176 + 2654435761) % 1024)


static func _sum_i64(values: PackedInt64Array) -> int:
	var total := 0
	for value in values:
		total += int(value)
	return total
