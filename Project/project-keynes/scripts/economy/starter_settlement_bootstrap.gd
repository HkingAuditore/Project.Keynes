class_name StarterSettlementBootstrap
extends RefCounted

const MONEY_SCALE := 10000
const GOODS_SCALE := 1000
const SURVIVAL_DAYS := 60


static func build(map: MapData, facade: EconomyFacade, start_cell: int,
		precious_resource: String) -> Dictionary:
	if map == null or facade == null or start_cell < 0 or start_cell >= map.cell_count():
		return _error("starter_context_invalid", "初始聚落上下文无效。")
	var professions := [&"forager", &"merchant", &"miner", &"unemployed"]
	var populations := PackedInt64Array([3, 2, 1 if precious_resource == "gold_ore" else 2,
		14 if precious_resource == "gold_ore" else 13])
	var signature_ids := PackedInt32Array()
	var cell_indices := PackedInt32Array()
	var funds := PackedInt64Array()
	for index in range(professions.size()):
		var signature := facade.signature_id(professions[index], &"default")
		if signature < 0:
			return _error("starter_signature_missing", "经济目录缺少初始职业：%s" % String(professions[index]))
		signature_ids.append(signature)
		cell_indices.append(start_cell)
		funds.append(int(populations[index]) * SURVIVAL_DAYS * 8 * MONEY_SCALE)
	var total_population := 0
	for population in populations: total_population += int(population)
	if total_population != 20:
		return _error("starter_population_mismatch", "初始人口必须严格等于 20。")

	var building_ids := PackedStringArray([
		"gathering_ground", "timber_collector", "merchant_post",
		"placer_gold_working" if precious_resource == "gold_ore" else "surface_silver_working",
	])
	var building_types := PackedInt32Array()
	var building_owners := PackedInt32Array()
	var owner_professions := [&"forager", &"forager", &"merchant", &"merchant"]
	for index in range(building_ids.size()):
		var type_id := facade.building_type_id(building_ids[index])
		var owner_id := facade.signature_id(owner_professions[index], &"default")
		if type_id < 0 or owner_id < 0:
			return _error("starter_building_missing", "经济目录缺少初始建筑：%s" % building_ids[index])
		building_types.append(type_id)
		building_owners.append(owner_id)

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
	for good_id in initial_stock:
		var good_idx := goods.find(String(good_id))
		if good_idx >= 0:
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
			"building_cells": PackedInt32Array([start_cell, start_cell, start_cell, start_cell]),
			"building_type_ids": building_types,
			"building_owner_signature_ids": building_owners,
			"building_counts": PackedInt64Array([1, 1, 1, 1]),
		},
		"total_population": total_population,
		"precious_resource": precious_resource,
		"source": "starter_settlement_bootstrap_v1",
	}


static func _error(code: String, message: String) -> Dictionary:
	return {"ok": false, "code": code, "message": message}
