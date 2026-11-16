# Carrying-capacity catalog columns; input order and arithmetic are unchanged.
extends RefCounted

static func compile(catalog: Dictionary, building_columns: Dictionary,
		good_columns: Dictionary, index_ids: Callable) -> Dictionary:
	const FAMILY_SPECS := [
		["staple", "staple_food"],
		["protein", "protein"],
		["produce", "produce"],
		["clothing", "clothing"],
		["housing", "housing"],
		["household", "household_goods"],
		["hygiene", "hygiene"],
		["healthcare", "healthcare"],
		["energy", "home_energy"],
		["transport", "transport"],
		["communication", "communication"],
		["education", "education_culture"],
		["recreation", "recreation"],
		["durables", "durable_goods"],
		["work_tools", "work_equipment"],
		["luxury", "luxury"],
		["status", "status_goods"],
	]
	const PRODUCER_SPECS := [
		["construction", [
			"primitive_construction", "masonry_material", "plant_construction",
			"construction_components", "raw_stone", "lumber"]],
		["mill_tools", ["tools", "tool_metal"]],
		["metals", ["ferrous_stock", "structural_metal", "tool_metal"]],
		["bullion", ["precious_metal"]],
	]
	const SUPPORT_RESOURCE_IDS := [
		"arable_land", "paddy_land", "pasture", "plantation_land",
		"wild_game", "freshwater_fish", "marine_fish",
	]
	var need_ids: PackedStringArray = catalog.get("need_ids", PackedStringArray())
	var need_index: Dictionary = index_ids.call(need_ids)
	var family_ids := PackedStringArray()
	var family_need_stable := PackedInt32Array()
	var family_good_offsets := PackedInt32Array([0])
	var family_goods := PackedInt32Array()
	var household_goods := {}
	for spec in FAMILY_SPECS:
		var family_id := String(spec[0])
		var need_id := String(spec[1])
		if not need_index.has(need_id):
			return {"ok": false, "reason": "carrying_need_family_missing:%s" % need_id}
		var need_stable := int(need_index[need_id])
		var goods := _carrying_need_goods(need_stable, catalog)
		family_ids.append(family_id)
		family_need_stable.append(need_stable)
		for good_id in goods:
			household_goods[int(good_id)] = true
			family_goods.append(int(good_id))
		family_good_offsets.append(family_goods.size())
	var category_goods := _carrying_category_goods(
		good_columns.get("good_substitution_category_offsets", PackedInt32Array()),
		good_columns.get("good_substitution_category_ids", PackedStringArray()),
		int((good_columns.get("good_ids", PackedStringArray()) as PackedStringArray).size()))
	if bool(category_goods.get("ok", true)) == false:
		return category_goods
	var used_producer_goods := {}
	for spec in PRODUCER_SPECS:
		var family_id := String(spec[0])
		var categories: Array = spec[1]
		var collected := PackedInt32Array()
		var seen := {}
		for category_id in categories:
			var members: PackedInt32Array = category_goods.get(String(category_id), PackedInt32Array())
			for good_id in members:
				var gid := int(good_id)
				if household_goods.has(gid) or used_producer_goods.has(gid) or seen.has(gid):
					continue
				seen[gid] = true
				collected.append(gid)
		collected.sort()
		for gid in collected:
			used_producer_goods[int(gid)] = true
			family_goods.append(int(gid))
		family_ids.append(family_id)
		family_need_stable.append(-1)
		family_good_offsets.append(family_goods.size())
	var resource_ids: PackedStringArray = building_columns.get(
		"building_resource_ids", PackedStringArray())
	var resource_index: Dictionary = index_ids.call(resource_ids)
	var support_resource_ids := PackedInt32Array()
	for resource_id in SUPPORT_RESOURCE_IDS:
		support_resource_ids.append(int(resource_index.get(String(resource_id), -1)))
	var food_need_stables := PackedInt32Array()
	for need_id in ["staple_food", "protein", "produce"]:
		food_need_stables.append(int(need_index[need_id]))
	var survival_food_goods := {}
	for need_stable in food_need_stables:
		for good_id in _carrying_need_goods(int(need_stable), catalog):
			survival_food_goods[int(good_id)] = true
	var fertile_soil_id := int(resource_index.get("fertile_soil", -1))
	var yield_offsets := PackedInt32Array()
	yield_offsets.resize(SUPPORT_RESOURCE_IDS.size() + 1)
	yield_offsets.fill(0)
	var yield_building := PackedInt32Array()
	var yield_resource := PackedInt32Array()
	var yield_secondary := PackedInt32Array()
	var yield_food := PackedInt64Array()
	var yield_qty := PackedInt64Array()
	var yield_secondary_qty := PackedInt64Array()
	var yield_modes := PackedInt32Array()
	var building_type_ids: PackedStringArray = building_columns.get(
		"building_type_ids", PackedStringArray())
	var output_offsets: PackedInt32Array = building_columns.get(
		"building_output_offsets", PackedInt32Array())
	var output_goods: PackedInt32Array = building_columns.get(
		"building_output_good_ids", PackedInt32Array())
	var output_qty: PackedInt64Array = building_columns.get(
		"building_output_quantities", PackedInt64Array())
	var resource_offsets: PackedInt32Array = building_columns.get(
		"building_resource_offsets", PackedInt32Array())
	var production_resources: PackedInt32Array = building_columns.get(
		"building_production_resource_ids", PackedInt32Array())
	var production_qty: PackedInt64Array = building_columns.get(
		"building_production_resource_quantities", PackedInt64Array())
	var production_modes: PackedInt32Array = building_columns.get(
		"building_production_resource_modes", PackedInt32Array())
	if output_offsets.size() != building_type_ids.size() + 1 \
			or resource_offsets.size() != building_type_ids.size() + 1:
		return {"ok": false, "reason": "carrying_food_yield_building_shape_invalid"}
	var rows_by_support: Array = []
	rows_by_support.resize(SUPPORT_RESOURCE_IDS.size())
	for support_idx in range(SUPPORT_RESOURCE_IDS.size()):
		rows_by_support[support_idx] = []
	for type_id in range(building_type_ids.size()):
		var food_output := 0
		for output_idx in range(int(output_offsets[type_id]), int(output_offsets[type_id + 1])):
			if output_idx < 0 or output_idx >= output_goods.size() \
					or output_idx >= output_qty.size():
				return {"ok": false, "reason": "carrying_food_yield_output_invalid"}
			if survival_food_goods.has(int(output_goods[output_idx])):
				food_output += int(output_qty[output_idx])
		if food_output <= 0:
			continue
		var primary_support := -1
		var primary_resource := -1
		var primary_qty := 0
		var primary_mode := 1
		var secondary_resource := -1
		var secondary_qty := 0
		for edge in range(int(resource_offsets[type_id]), int(resource_offsets[type_id + 1])):
			if edge < 0 or edge >= production_resources.size() \
					or edge >= production_qty.size() or edge >= production_modes.size():
				return {"ok": false, "reason": "carrying_food_yield_resource_invalid"}
			var resource_id := int(production_resources[edge])
			if resource_id == fertile_soil_id:
				secondary_resource = resource_id
				secondary_qty = int(production_qty[edge])
				continue
			for support_idx in range(support_resource_ids.size()):
				if int(support_resource_ids[support_idx]) == resource_id and primary_support < 0:
					primary_support = support_idx
					primary_resource = resource_id
					primary_qty = int(production_qty[edge])
					primary_mode = int(production_modes[edge])
		if primary_support < 0 or primary_qty <= 0:
			continue
		rows_by_support[primary_support].append({
			"building": type_id,
			"resource": primary_resource,
			"secondary": secondary_resource,
			"food": food_output,
			"qty": primary_qty,
			"secondary_qty": secondary_qty,
			"mode": primary_mode,
		})
	for support_idx in range(rows_by_support.size()):
		yield_offsets[support_idx] = yield_building.size()
		for row in rows_by_support[support_idx]:
			yield_building.append(int(row.building))
			yield_resource.append(int(row.resource))
			yield_secondary.append(int(row.secondary))
			yield_food.append(int(row.food))
			yield_qty.append(int(row.qty))
			yield_secondary_qty.append(int(row.secondary_qty))
			yield_modes.append(int(row.mode))
	yield_offsets[SUPPORT_RESOURCE_IDS.size()] = yield_building.size()
	return {
		"ok": true,
		"carrying_family_ids": family_ids,
		"carrying_family_need_stable_ids": family_need_stable,
		"carrying_family_good_offsets": family_good_offsets,
		"carrying_family_good_ids": family_goods,
		"carrying_support_resource_ids": support_resource_ids,
		"carrying_food_yield_offsets": yield_offsets,
		"carrying_food_yield_building_type_ids": yield_building,
		"carrying_food_yield_resource_ids": yield_resource,
		"carrying_food_yield_secondary_resource_ids": yield_secondary,
		"carrying_food_yield_food_output": yield_food,
		"carrying_food_yield_resource_qty": yield_qty,
		"carrying_food_yield_secondary_qty": yield_secondary_qty,
		"carrying_food_yield_modes": yield_modes,
	}


static func _carrying_need_goods(need_stable: int, catalog: Dictionary) -> PackedInt32Array:
	var need_stable_ids: PackedInt32Array = catalog.get("need_stable_ids", PackedInt32Array())
	var need_variant_offsets: PackedInt32Array = catalog.get("need_variant_offsets", PackedInt32Array())
	var variant_component_offsets: PackedInt32Array = catalog.get(
		"variant_component_offsets", PackedInt32Array())
	var component_good_ids: PackedInt32Array = catalog.get("component_good_ids", PackedInt32Array())
	var seen := {}
	if need_variant_offsets.size() != need_stable_ids.size() + 1:
		return PackedInt32Array()
	for entry in range(need_stable_ids.size()):
		if int(need_stable_ids[entry]) != need_stable:
			continue
		var variant_begin := int(need_variant_offsets[entry])
		var variant_end := int(need_variant_offsets[entry + 1])
		for variant_id in range(variant_begin, variant_end):
			if variant_id < 0 or variant_id + 1 >= variant_component_offsets.size():
				continue
			var component_begin := int(variant_component_offsets[variant_id])
			var component_end := int(variant_component_offsets[variant_id + 1])
			for component_idx in range(component_begin, component_end):
				if component_idx >= 0 and component_idx < component_good_ids.size():
					seen[int(component_good_ids[component_idx])] = true
	var goods := PackedInt32Array()
	for good_id in seen.keys():
		goods.append(int(good_id))
	goods.sort()
	return goods


static func _carrying_category_goods(offsets: PackedInt32Array, ids: PackedStringArray,
		good_count: int) -> Dictionary:
	var out := {}
	if offsets.size() != good_count + 1 or offsets.is_empty() or int(offsets[0]) != 0 \
			or int(offsets[-1]) != ids.size():
		return {"ok": false, "reason": "carrying_substitution_category_shape_invalid"}
	for good_idx in range(good_count):
		var begin := int(offsets[good_idx])
		var end := int(offsets[good_idx + 1])
		if begin < 0 or end < begin or end > ids.size():
			return {"ok": false, "reason": "carrying_substitution_category_offsets_invalid"}
		for edge in range(begin, end):
			var category_id := String(ids[edge])
			if category_id.is_empty():
				continue
			var members: PackedInt32Array = out.get(category_id, PackedInt32Array())
			members.append(good_idx)
			out[category_id] = members
	out["ok"] = true
	return out
