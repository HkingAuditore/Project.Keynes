class_name StarterSettlementBootstrap
extends RefCounted

const StarterEconomyPlannerScript = preload(
	"res://scripts/economy/starter_economy_planner.gd")
const MONEY_SCALE := 10000
const GOODS_SCALE := 1000
const STARTER_POPULATION := 20
const SURVIVAL_DAYS := 15
const LOCAL_INPUT_BUFFER_DAYS := 3
const SURVIVAL_PLAN_PATH := "res://data/economy/consumption_plans/survival_household.tres"


static func build(map: MapData, facade: EconomyFacade, start_cell: int,
		precious_resource: String) -> Dictionary:
	var fallback := _fallback_start(start_cell, precious_resource)
	var planned := StarterEconomyPlannerScript.plan(
		map, start_cell, fallback, facade)
	if not bool(planned.get("ok", false)):
		return planned
	fallback.merge(planned, true)
	return build_many(map, facade, [fallback])


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
		var route_counts: PackedInt64Array = start.get(
			"starter_building_counts", PackedInt64Array())
		if route_buildings.is_empty():
			return _error("starter_route_missing", "出生点没有经过验证的初始建筑路线。")
		if route_counts.size() != route_buildings.size():
			return _error("starter_building_count_contract_invalid",
				"开局建筑 ID 与数量必须一一对应。")
		if not route_buildings.has("early_merchant_post"):
			return _error("starter_trade_building_missing", "开局路线必须预建早期商栈。")
		var first_building_type := -1
		var first_owner_signature := -1
		var first_owner_slots := 0
		var job_capacity := 0
		var food_owner_slots_by_signature := {}
		var food_owner_total := 0
		for building_index in range(route_buildings.size()):
			var building_id := String(route_buildings[building_index])
			var planned_count := int(route_counts[building_index])
			if planned_count <= 0:
				return _error("starter_building_count_contract_invalid",
					"开局建筑数量必须大于零：%s" % building_id)
			var building_type := facade.building_type_id(building_id)
			if building_type < 0:
				return _error("starter_building_missing",
					"经济目录缺少初始建筑：%s" % building_id)
			var job_spec: Dictionary = facade.building_job_spec(building_id)
			if not bool(job_spec.get("ok", false)):
				return _error("starter_building_job_invalid",
					"初始建筑职业配置无效：%s" % building_id)
			if not (job_spec.employee_professions as PackedStringArray).is_empty() \
					or not (job_spec.employee_slots as PackedInt64Array).is_empty():
				if not StarterEconomyPlannerScript.allows_starter_employee_roles(building_id):
					return _error("starter_employee_role_forbidden",
						"石器时代初始建筑不得包含雇员岗位：%s" % building_id)
			var owner_profession := String(job_spec.owner_profession)
			var owner_signature := facade.signature_id(
				StringName(owner_profession), &"default")
			if owner_signature < 0:
				return _error("starter_signature_missing",
					"经济目录缺少初始职业：%s" % owner_profession)
			var owner_slots := int(job_spec.owner_slots)
			job_capacity += planned_count * owner_slots
			building_cells.append(start_cell)
			building_types.append(building_type)
			building_owners.append(owner_signature)
			building_counts.append(planned_count)
			starter_building_ids.append(String(building_id))
			if first_building_type < 0:
				first_building_type = building_type
				first_owner_signature = owner_signature
				first_owner_slots = owner_slots
			if _is_opening_food_building(building_id):
				food_owner_slots_by_signature[owner_signature] = int(
					food_owner_slots_by_signature.get(owner_signature, 0)) \
					+ planned_count * owner_slots
				food_owner_total += planned_count * owner_slots
		starter_building_offsets.append(starter_building_ids.size())

		if job_capacity <= 0 or job_capacity > STARTER_POPULATION:
			return _error("starter_population_capacity_mismatch",
				"初始建筑自营岗位容量必须为正且不超过 20。")
		if first_owner_slots <= 0 or first_owner_slots >= STARTER_POPULATION:
			return _error("starter_founder_capacity_invalid",
				"首栋生产建筑必须为待业人口保留可自主匹配的岗位空间。")
		if food_owner_total <= 0 or food_owner_total >= STARTER_POPULATION:
			return _error("starter_food_operator_capacity_invalid",
				"开局食品建筑自营岗位必须为正且为待业人口留出匹配空间。")
		for owner_signature in food_owner_slots_by_signature.keys():
			_append_population_row(signature_ids, cell_indices, populations, funds,
				start_cell, int(owner_signature),
				int(food_owner_slots_by_signature[owner_signature]))
		var unemployed_signature := facade.signature_id(&"unemployed", &"default")
		if unemployed_signature < 0:
			return _error("starter_signature_missing", "经济目录缺少 unemployed 职业。")
		_append_population_row(signature_ids, cell_indices, populations, funds,
			start_cell, unemployed_signature, STARTER_POPULATION - food_owner_total)
		total_population += STARTER_POPULATION

		var food_goods: PackedStringArray = start.get(
			"starter_food_good_ids", PackedStringArray())
		var food_bridge := _food_bridge_quantities(food_goods)
		if food_goods.is_empty() or food_bridge.size() != food_goods.size():
			return _error("starter_food_contract_invalid",
				"开局食物必须全部映射到 survival_household 的食品子篮子。")
		for food_good in food_goods:
			var food_index := goods.find(String(food_good))
			if food_index < 0:
				return _error("starter_good_missing", "经济目录缺少当地食物：%s" % food_good)
			stock[start_cell * goods.size() + food_index] += STARTER_POPULATION \
				* SURVIVAL_DAYS * int(food_bridge[String(food_good)])
		var clothing_good := String(start.get("starter_clothing_good_id", ""))
		if clothing_good.is_empty() or goods.find(clothing_good) < 0:
			return _error("starter_good_missing", "经济目录缺少开局衣物：%s" % clothing_good)
		stock[start_cell * goods.size() + goods.find(clothing_good)] += \
			STARTER_POPULATION * (SURVIVAL_DAYS if route_buildings.has(
				"hide_scraping_shelter") else LOCAL_INPUT_BUFFER_DAYS) * GOODS_SCALE
		var construction_seed := String(start.get(
			"starter_construction_seed_building_id", ""))
		var selected_construction_goods: PackedStringArray = start.get(
			"starter_construction_selected_good_ids", PackedStringArray())
		var selected_construction_quantities: PackedInt64Array = start.get(
			"starter_construction_selected_quantities", PackedInt64Array())
		if construction_seed != String(start.get("primary_food_building_id", "")) \
				or selected_construction_goods.is_empty() \
				or selected_construction_goods.size() != selected_construction_quantities.size():
			return _error("starter_construction_contract_invalid",
				"开局建材必须来自食物种子建筑的完整分组选择结果。")
		for selected_index in range(selected_construction_goods.size()):
			var construction_good := String(selected_construction_goods[selected_index])
			var good_index := goods.find(construction_good)
			if construction_good.is_empty() or good_index < 0:
				return _error("starter_good_missing",
					"经济目录缺少开局建材：%s" % construction_good)
			var four_seed_buildings := maxi(0,
				int(selected_construction_quantities[selected_index])) * 4
			var three_day_buffer := STARTER_POPULATION * \
				LOCAL_INPUT_BUFFER_DAYS * GOODS_SCALE
			stock[start_cell * goods.size() + good_index] += maxi(
				four_seed_buildings, three_day_buffer)
		var pending_knowledge_goods: PackedStringArray = start.get(
			"pending_knowledge_construction_good_ids", PackedStringArray())
		var pending_knowledge_quantities: PackedInt64Array = start.get(
			"pending_knowledge_construction_quantities", PackedInt64Array())
		if pending_knowledge_goods.size() != pending_knowledge_quantities.size():
			return _error("starter_knowledge_construction_invalid",
				"待建知识棚建材 ID 与数量必须一一对应。")
		for pending_index in range(pending_knowledge_goods.size()):
			var pending_good := String(pending_knowledge_goods[pending_index])
			var pending_good_index := goods.find(pending_good)
			if pending_good.is_empty() or pending_good_index < 0:
				return _error("starter_good_missing",
					"经济目录缺少待建知识棚建材：%s" % pending_good)
			stock[start_cell * goods.size() + pending_good_index] += maxi(
				int(pending_knowledge_quantities[pending_index]), 0)
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
		"source": "starter_settlement_bootstrap_v9",
	}


static func _append_population_row(signature_ids: PackedInt32Array,
		cell_indices: PackedInt32Array, populations: PackedInt64Array,
		funds: PackedInt64Array, cell: int, signature: int, population: int) -> void:
	signature_ids.append(signature)
	cell_indices.append(cell)
	populations.append(population)
	funds.append(population * SURVIVAL_DAYS * 8 * MONEY_SCALE)


static func _fallback_start(start_cell: int, precious_resource: String) -> Dictionary:
	var technologies := PackedStringArray([
		"tech.gathering", "tech.hunting", "tech.early_trade",
		"tech.deadwood_collection",
	])
	var buildings := PackedStringArray([
		"gathering_ground", "stone_age_hunting_camp", "early_merchant_post",
		"deadwood_gathering_camp",
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
		"starter_discovered_technology_ids": PackedStringArray([
			"tech.early_knowledge_institution",
		]),
		"pending_knowledge_tech_id": "tech.early_knowledge_institution",
		"pending_knowledge_building_id": "early_knowledge_institution",
		"starter_building_ids": buildings,
		"starter_food_good_ids": PackedStringArray(["gathered_plants", "game_meat"]),
		"starter_clothing_good_id": "clothing",
		"starter_construction_good_id": "logs",
		"starter_knowledge_good_id": "technology_points",
		"starter_food_resource_ids": PackedStringArray(["fertile_soil", "wild_game"]),
		"starter_clothing_resource_id": "",
		"starter_construction_resource_id": "timber",
		"starter_input_buffer_good_id": "raw_hide",
		"starter_precious_good_id": "silver" if precious_resource == "silver_ore" else "gold",
		"starter_treasury_good_id": "technology_points",
		"starter_treasury_quantity":
			StarterEconomyPlannerScript.STARTER_TREASURY_TECHNOLOGY_POINTS,
	}


static func _is_opening_food_building(building_id: String) -> bool:
	return building_id == "gathering_ground" or building_id == "stone_age_hunting_camp"


static func _food_bridge_quantities(food_goods: PackedStringArray) -> Dictionary:
	var plan = load(SURVIVAL_PLAN_PATH)
	if plan == null:
		return {}
	var food_need_ids := {"staple_food": true, "protein": true, "produce": true}
	var allocations := {}
	for need_index in range(plan.need_ids.size()):
		var need_id := String(plan.need_ids[need_index])
		if not food_need_ids.has(need_id):
			continue
		var choices := PackedStringArray()
		var variant_begin := int(plan.need_variant_offsets[need_index])
		var variant_end := int(plan.need_variant_offsets[need_index + 1])
		for variant_index in range(variant_begin, variant_end):
			var component_begin := int(plan.variant_component_offsets[variant_index])
			var component_end := int(plan.variant_component_offsets[variant_index + 1])
			if component_end - component_begin != 1:
				continue
			var good_id := String(plan.component_good_ids[component_begin])
			if food_goods.has(good_id) and not choices.has(good_id):
				choices.append(good_id)
		if choices.is_empty():
			continue
		var base_quantity := int(plan.base_qty_per_person[need_index])
		for choice_index in range(choices.size()):
			# Split a need's bridge evenly between multiple discovered substitutes
			# so fish/game_meat do not duplicate the protein allowance.
			var upper := floori(float(base_quantity * (choice_index + 1)) / choices.size())
			var lower := floori(float(base_quantity * choice_index) / choices.size())
			allocations[choices[choice_index]] = int(allocations.get(
				choices[choice_index], 0)) + upper - lower
	return allocations


static func _error(code: String, message: String) -> Dictionary:
	return {"ok": false, "code": code, "message": message}
