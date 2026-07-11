class_name EconomyTestBootstrap
extends RefCounted

const GOODS_SCALE := 1000
const MONEY_SCALE := 10000
const STOCK_DAYS := 30
const FARM_CAPACITY_PERCENT := 60
const WORKER_CAPACITY_PERCENT := 30
const LANDLORD_CAPACITY_PERCENT := 9
const MERCHANT_CAPACITY_PERCENT := 1

const COHORT_SPECS := [
	{"profession": &"subsistence_farmer", "money_pc": 20},
	{"profession": &"worker", "money_pc": 40},
	{"profession": &"landlord", "money_pc": 500},
	{"profession": &"merchant", "money_pc": 200},
]


static func build(map: MapData, facade: EconomyFacade, seed: int) -> Dictionary:
	if map == null or facade == null or not facade.is_configured():
		return {"ok": false, "reason": "test_bootstrap_runtime_unavailable"}
	var signatures := PackedInt32Array()
	for spec in COHORT_SPECS:
		var signature := facade.signature_id(spec.profession, &"default")
		if signature < 0:
			return {
				"ok": false,
				"reason": "test_bootstrap_catalog_incomplete",
				"missing_signature": "%s|default" % String(spec.profession),
			}
		signatures.append(signature)
	var building_specs := {}
	for building_id in [&"landed_estate", &"market_stall", &"subsistence_farm", &"textile_workshop"]:
		var job_spec: Dictionary = facade.building_job_spec(building_id)
		if not bool(job_spec.get("ok", false)):
			return {
				"ok": false,
				"reason": "test_bootstrap_building_catalog_incomplete",
				"missing_building": String(building_id),
			}
		building_specs[building_id] = job_spec

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
	var target_settlement_capacity := 0

	for cell_idx in range(map.cell_count()):
		var terrain := _terrain_at(map, cell_idx)
		if MapData.terrain_is_water(terrain) or not TerrainType.is_passable_land(terrain):
			continue
		var settlement_capacity := 1000 + _population_jitter(seed, cell_idx)
		target_settlement_capacity += settlement_capacity
		var farm: Dictionary = building_specs[&"subsistence_farm"]
		var stall: Dictionary = building_specs[&"market_stall"]
		var workshop: Dictionary = building_specs[&"textile_workshop"]
		var estate: Dictionary = building_specs[&"landed_estate"]
		var farm_count := _ceil_div(
			maxi(1, settlement_capacity * FARM_CAPACITY_PERCENT / 100), int(farm.owner_slots))
		var stall_count := _ceil_div(
			maxi(1, settlement_capacity * MERCHANT_CAPACITY_PERCENT / 100), int(stall.owner_slots))
		var worker_target := maxi(1, settlement_capacity * WORKER_CAPACITY_PERCENT / 100)
		var stall_worker_jobs := stall_count * _employee_slots_for(stall, &"worker")
		var workshop_worker_slots := _employee_slots_for(workshop, &"worker")
		var workshop_count := _ceil_div(
			maxi(0, worker_target - stall_worker_jobs), workshop_worker_slots)
		var landlord_target := maxi(1, settlement_capacity * LANDLORD_CAPACITY_PERCENT / 100)
		var workshop_owner_jobs := workshop_count * int(workshop.owner_slots)
		var estate_count := _ceil_div(
			maxi(0, landlord_target - workshop_owner_jobs), int(estate.owner_slots))
		var generated_groups := [
			{"spec": farm, "count": farm_count},
			{"spec": workshop, "count": workshop_count},
			{"spec": estate, "count": estate_count},
			{"spec": stall, "count": stall_count},
		]
		for group in generated_groups:
			var job_spec: Dictionary = group.spec
			var count := int(group.count)
			_append_building_group(building_cells, building_types, building_owners,
				building_counts, cell_idx, int(job_spec.type_id),
				facade.signature_id(StringName(job_spec.owner_profession), &"default"), count)

		var jobs_by_profession := {}
		for group in generated_groups:
			_accumulate_building_jobs(group.spec, int(group.count), jobs_by_profession)
		var actual_population := 0
		for i in range(COHORT_SPECS.size()):
			var profession: StringName = COHORT_SPECS[i].profession
			var population := int(jobs_by_profession.get(profession, 0))
			if population <= 0:
				return {"ok": false, "reason": "test_bootstrap_generated_empty_job_class",
					"profession": String(profession)}
			cell_indices.append(cell_idx)
			signature_ids.append(signatures[i])
			populations.append(population)
			funds.append(population * int(COHORT_SPECS[i].money_pc) * MONEY_SCALE)
			actual_population += population
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
		"population_source": "building_jobs_v1",
		"good_count": good_ids.size(),
	}


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


static func _employee_slots_for(spec: Dictionary, profession: StringName) -> int:
	var professions: PackedStringArray = spec.employee_professions
	var slots: PackedInt64Array = spec.employee_slots
	var total := 0
	for i in range(professions.size()):
		if StringName(professions[i]) == profession:
			total += int(slots[i])
	return total


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
