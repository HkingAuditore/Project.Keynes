class_name StarterSettlementBootstrap
extends RefCounted

const MONEY_SCALE := 10000
const GOODS_SCALE := 1000
const STARTER_POPULATION := 20
const SURVIVAL_DAYS := 15
const SURVIVAL_FOOD_PER_PERSON_DAY := 240
const LOCAL_INPUT_BUFFER_DAYS := 3


static func build(map: MapData, facade: EconomyFacade, start_cell: int,
		precious_resource: String) -> Dictionary:
	return build_many(map, facade, [_fallback_start(start_cell, precious_resource)])


static func build_many(map: MapData, facade: EconomyFacade,
		starts: Array[Dictionary]) -> Dictionary:
	if map == null or facade == null or starts.is_empty():
		return _error("starter_context_invalid", "初始聚落上下文无效。")
	var goods := facade.good_ids()
	var stock := PackedInt64Array()
	stock.resize(map.cell_count() * goods.size())
	var signature_ids := PackedInt32Array()
	var cell_indices := PackedInt32Array()
	var populations := PackedInt64Array()
	var funds := PackedInt64Array()
	var building_cells := PackedInt32Array()
	var building_types := PackedInt32Array()
	var building_owners := PackedInt32Array()
	var building_counts := PackedInt64Array()
	var founder_family_cells := PackedInt32Array()
	var founder_family_building_types := PackedInt32Array()
	var founder_family_owner_signatures := PackedInt32Array()
	var settlement_cells := PackedInt32Array()
	var precious_resources := PackedStringArray()
	var regional_routes := PackedStringArray()
	var starter_building_offsets := PackedInt32Array([0])
	var starter_building_ids := PackedStringArray()
	var total_population := 0

	for start in starts:
		var start_cell := int(start.get("cell", -1))
		var precious_resource := String(start.get("precious_resource", ""))
		if start_cell < 0 or start_cell >= map.cell_count() \
				or precious_resource not in ["gold_ore", "silver_ore"]:
			return _error("starter_context_invalid", "初始聚落地点或贵金属路线无效。")
		var route_buildings: PackedStringArray = start.get(
			"starter_building_ids", PackedStringArray())
		if route_buildings.is_empty():
			route_buildings = (_fallback_start(start_cell, precious_resource).get(
				"starter_building_ids", PackedStringArray()) as PackedStringArray)
		var profession_population := {}
		var profession_order := PackedStringArray()
		var first_building_type := -1
		var first_owner_signature := -1
		for building_id in route_buildings:
			var building_type := facade.building_type_id(building_id)
			if building_type < 0:
				return _error("starter_building_missing",
					"经济目录缺少初始建筑：%s" % building_id)
			var job_spec: Dictionary = facade.building_job_spec(building_id)
			if not bool(job_spec.get("ok", false)):
				return _error("starter_building_job_invalid",
					"初始建筑职业配置无效：%s" % building_id)
			var owner_profession := String(job_spec.owner_profession)
			var owner_signature := facade.signature_id(
				StringName(owner_profession), &"default")
			if owner_signature < 0:
				return _error("starter_signature_missing",
					"经济目录缺少初始职业：%s" % owner_profession)
			if not profession_population.has(owner_profession):
				profession_order.append(owner_profession)
				profession_population[owner_profession] = 0
			profession_population[owner_profession] = int(
				profession_population[owner_profession]) + clampi(
					int(job_spec.owner_slots), 1, 2)
			building_cells.append(start_cell)
			building_types.append(building_type)
			building_owners.append(owner_signature)
			building_counts.append(1)
			starter_building_ids.append(String(building_id))
			if first_building_type < 0:
				first_building_type = building_type
				first_owner_signature = owner_signature
		starter_building_offsets.append(starter_building_ids.size())

		var allocated_population := 0
		for profession_id in profession_order:
			allocated_population += int(profession_population[profession_id])
		if allocated_population >= STARTER_POPULATION:
			return _error("starter_population_overcommitted",
				"初始弱建筑所需的业主人口超过 20 人。")
		profession_order.append("unemployed")
		profession_population["unemployed"] = STARTER_POPULATION - allocated_population
		for profession_id in profession_order:
			var population := int(profession_population[profession_id])
			var signature := facade.signature_id(StringName(profession_id), &"default")
			if signature < 0:
				return _error("starter_signature_missing",
					"经济目录缺少初始职业：%s" % profession_id)
			signature_ids.append(signature)
			cell_indices.append(start_cell)
			populations.append(population)
			funds.append(population * SURVIVAL_DAYS * 8 * MONEY_SCALE)
		total_population += STARTER_POPULATION

		var food_good := String(start.get("starter_food_good_id", "gathered_plants"))
		var food_index := goods.find(food_good)
		if food_index < 0:
			return _error("starter_good_missing", "经济目录缺少当地食物：%s" % food_good)
		stock[start_cell * goods.size() + food_index] += STARTER_POPULATION \
			* SURVIVAL_DAYS * SURVIVAL_FOOD_PER_PERSON_DAY
		var input_buffer_good := String(start.get("starter_input_buffer_good_id", ""))
		if not input_buffer_good.is_empty():
			var input_index := goods.find(input_buffer_good)
			if input_index < 0:
				return _error("starter_good_missing",
					"经济目录缺少当地生产投入：%s" % input_buffer_good)
			stock[start_cell * goods.size() + input_index] += \
				LOCAL_INPUT_BUFFER_DAYS * GOODS_SCALE

		settlement_cells.append(start_cell)
		precious_resources.append(precious_resource)
		regional_routes.append(String(start.get("regional_route", "fallback")))
		founder_family_cells.append(start_cell)
		founder_family_building_types.append(first_building_type)
		founder_family_owner_signatures.append(first_owner_signature)

	return {
		"ok": true,
		"code": "ok",
		"message": "",
		"population_packet": {
			"cell_indices": cell_indices,
			"signature_ids": signature_ids,
			"population": populations,
			"funds": funds,
			"forced_named_cells": settlement_cells,
		},
		"market_packet": {"stock": stock},
		"building_packet": {
			"building_cells": building_cells,
			"building_type_ids": building_types,
			"building_owner_signature_ids": building_owners,
			"building_counts": building_counts,
			"founder_family_cells": founder_family_cells,
			"founder_family_building_type_ids": founder_family_building_types,
			"founder_family_owner_signature_ids": founder_family_owner_signatures,
		},
		"total_population": total_population,
		"settlement_count": starts.size(),
		"settlement_cells": settlement_cells,
		"precious_resources": precious_resources,
		"precious_resource": String(precious_resources[0]),
		"regional_routes": regional_routes,
		"starter_building_offsets": starter_building_offsets,
		"starter_building_ids": starter_building_ids,
		"survival_days": SURVIVAL_DAYS,
		"source": "starter_settlement_bootstrap_v4",
	}


static func _fallback_start(start_cell: int, precious_resource: String) -> Dictionary:
	var technologies := PackedStringArray([
		"tech.gathering", "tech.wild_flax_collection", "tech.fiber_twisting",
		"tech.deadwood_collection", "tech.oral_memory_practice",
	])
	var buildings := PackedStringArray([
		"gathering_ground", "bast_fiber_camp", "bast_wrap_shelter",
		"deadwood_gathering_camp", "oral_memory_circle", "merchant_post",
	])
	if precious_resource == "silver_ore":
		technologies.append("tech.surface_silver_collection")
		buildings.append("surface_silver_working")
	else:
		technologies.append("tech.gold_panning")
		buildings.append("placer_gold_working")
	return {
		"cell": start_cell,
		"precious_resource": precious_resource,
		"regional_route": "fallback",
		"starter_technology_ids": technologies,
		"starter_building_ids": buildings,
		"starter_food_good_id": "gathered_plants",
		"starter_input_buffer_good_id": "bast_fiber",
	}


static func _error(code: String, message: String) -> Dictionary:
	return {"ok": false, "code": code, "message": message}
