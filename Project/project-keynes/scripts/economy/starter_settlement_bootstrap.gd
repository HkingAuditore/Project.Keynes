class_name StarterSettlementBootstrap
extends RefCounted

const MONEY_SCALE := 10000
const GOODS_SCALE := 1000
const SURVIVAL_DAYS := 60


static func build(map: MapData, facade: EconomyFacade, start_cell: int,
		precious_resource: String) -> Dictionary:
	return build_many(map, facade, [{
		"cell": start_cell,
		"precious_resource": precious_resource,
	}])


static func build_many(map: MapData, facade: EconomyFacade,
		starts: Array[Dictionary]) -> Dictionary:
	if map == null or facade == null or starts.is_empty():
		return _error("starter_context_invalid", "初始聚落上下文无效。")
	var professions := [&"forager", &"merchant", &"miner", &"unemployed"]
	var signature_by_profession := PackedInt32Array()
	for profession in professions:
		var signature := facade.signature_id(profession, &"default")
		if signature < 0:
			return _error("starter_signature_missing",
				"经济目录缺少初始职业：%s" % String(profession))
		signature_by_profession.append(signature)
	var building_ids_by_precious := {
		"gold_ore": PackedStringArray([
			"gathering_ground", "timber_collector", "merchant_post",
			"placer_gold_working"]),
		"silver_ore": PackedStringArray([
			"gathering_ground", "timber_collector", "merchant_post",
			"surface_silver_working"]),
	}
	var building_owner_professions := [&"forager", &"forager", &"merchant", &"merchant"]
	var building_types_by_precious := {}
	var building_owners := PackedInt32Array()
	for owner_profession in building_owner_professions:
		var owner_signature := facade.signature_id(owner_profession, &"default")
		if owner_signature < 0:
			return _error("starter_signature_missing",
				"经济目录缺少初始职业：%s" % String(owner_profession))
		building_owners.append(owner_signature)
	for precious_id in building_ids_by_precious:
		var type_ids := PackedInt32Array()
		for building_id in building_ids_by_precious[precious_id]:
			var type_id := facade.building_type_id(building_id)
			if type_id < 0:
				return _error("starter_building_missing",
					"经济目录缺少初始建筑：%s" % building_id)
			type_ids.append(type_id)
		building_types_by_precious[precious_id] = type_ids

	var signature_ids := PackedInt32Array()
	var cell_indices := PackedInt32Array()
	var populations := PackedInt64Array()
	var funds := PackedInt64Array()
	var total_population := 0
	var goods := facade.good_ids()
	var stock := PackedInt64Array()
	stock.resize(map.cell_count() * goods.size())
	var initial_stock := {
		"gathered_plants": 20 * SURVIVAL_DAYS * GOODS_SCALE,
		"game_meat": 10 * SURVIVAL_DAYS * GOODS_SCALE,
		"logs": 7000 * GOODS_SCALE,
		"flint": 500 * GOODS_SCALE,
		"chipped_stone_tools": 240 * GOODS_SCALE,
	}
	var initial_stock_indices := {}
	for good_id in initial_stock:
		var good_idx := goods.find(String(good_id))
		if good_idx < 0:
			return _error("starter_good_missing",
				"经济目录缺少初始物资：%s" % String(good_id))
		initial_stock_indices[good_id] = good_idx
	var building_cells := PackedInt32Array()
	var building_types := PackedInt32Array()
	var all_building_owners := PackedInt32Array()
	var building_counts := PackedInt64Array()
	var settlement_cells := PackedInt32Array()
	var precious_resources := PackedStringArray()
	for start in starts:
		var start_cell := int(start.get("cell", -1))
		var precious_resource := String(start.get("precious_resource", ""))
		if start_cell < 0 or start_cell >= map.cell_count() \
				or not building_types_by_precious.has(precious_resource):
			return _error("starter_context_invalid", "初始聚落上下文无效。")
		settlement_cells.append(start_cell)
		precious_resources.append(precious_resource)
		var settlement_populations := PackedInt64Array([
			3, 2, 1 if precious_resource == "gold_ore" else 2,
			14 if precious_resource == "gold_ore" else 13])
		var settlement_population := 0
		for index in range(professions.size()):
			var population := int(settlement_populations[index])
			signature_ids.append(int(signature_by_profession[index]))
			cell_indices.append(start_cell)
			populations.append(population)
			funds.append(population * SURVIVAL_DAYS * 8 * MONEY_SCALE)
			settlement_population += population
		if settlement_population != 20:
			return _error("starter_population_mismatch",
				"每个初始聚落人口必须严格等于 20。")
		total_population += settlement_population
		var settlement_building_types: PackedInt32Array = \
			building_types_by_precious[precious_resource]
		for index in range(settlement_building_types.size()):
			building_cells.append(start_cell)
			building_types.append(int(settlement_building_types[index]))
			all_building_owners.append(int(building_owners[index]))
			building_counts.append(1)
		for good_id in initial_stock:
			var good_idx := int(initial_stock_indices[good_id])
			stock[start_cell * goods.size() + good_idx] = int(initial_stock[good_id])
	return {
		"ok": true,
		"code": "ok",
		"message": "",
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
			"building_owner_signature_ids": all_building_owners,
			"building_counts": building_counts,
		},
		"total_population": total_population,
		"settlement_count": starts.size(),
		"settlement_cells": settlement_cells,
		"precious_resources": precious_resources,
		"precious_resource": String(precious_resources[0]),
		"source": "starter_settlement_bootstrap_v2",
	}


static func _error(code: String, message: String) -> Dictionary:
	return {"ok": false, "code": code, "message": message}
