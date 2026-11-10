extends RefCounted

# Pure catalog projection shared by opening planners; no runtime state.
static func query(catalog: Dictionary, building_id: StringName) -> Dictionary:
	var type_ids: PackedStringArray = catalog.get("building_type_ids", PackedStringArray())
	var type_id := type_ids.find(String(building_id))
	if type_id < 0:
		return {"ok": false, "reason": "unknown building type: %s" % String(building_id)}
	var good_ids: PackedStringArray = catalog.get("good_ids", PackedStringArray())
	var resource_ids: PackedStringArray = catalog.get(
		"building_resource_ids", PackedStringArray())
	var input_goods := _stable_ids_from_catalog_range(catalog, type_id, good_ids,
		"building_input_offsets", "building_input_good_ids")
	var output_goods := _stable_ids_from_catalog_range(catalog, type_id, good_ids,
		"building_output_offsets", "building_output_good_ids")
	var input_quantities_all: PackedInt64Array = catalog.get(
		"building_input_quantities", PackedInt64Array())
	var input_required_all: PackedInt32Array = catalog.get(
		"building_input_required_q16", PackedInt32Array())
	var output_quantities_all: PackedInt64Array = catalog.get(
		"building_output_quantities", PackedInt64Array())
	var production_resources := _stable_ids_from_catalog_range(catalog, type_id, resource_ids,
		"building_resource_offsets", "building_production_resource_ids")
	var technology_offsets: PackedInt32Array = catalog.get(
		"building_technology_tag_offsets", PackedInt32Array())
	var technology_tags: PackedStringArray = catalog.get(
		"building_technology_tags", PackedStringArray())
	var required_offsets: PackedInt32Array = catalog.get("building_required_technology_tag_offsets", PackedInt32Array())
	var required_tags: PackedStringArray = catalog.get("building_required_technology_tags", PackedStringArray())
	var input_categories_all: PackedStringArray = catalog.get(
		"building_input_category_ids", PackedStringArray())
	var input_min_levels_all: PackedInt32Array = catalog.get(
		"building_input_min_quality_levels", PackedInt32Array())
	var candidate_offsets_all: PackedInt32Array = catalog.get(
		"building_input_candidate_offsets", PackedInt32Array())
	var candidate_goods_all: PackedInt32Array = catalog.get(
		"building_input_candidate_good_ids", PackedInt32Array())
	var candidate_efficiencies_all: PackedInt32Array = catalog.get(
		"building_input_candidate_efficiency_q16", PackedInt32Array())
	var good_categories: PackedStringArray = catalog.get(
		"good_category_ids", PackedStringArray())
	var good_substitution_offsets: PackedInt32Array = catalog.get(
		"good_substitution_category_offsets", PackedInt32Array())
	var good_substitution_ids: PackedStringArray = catalog.get(
		"good_substitution_category_ids", PackedStringArray())
	if not bool(input_goods.get("ok", false)) or not bool(output_goods.get("ok", false)) \
			or not bool(production_resources.get("ok", false)):
		return {"ok": false, "reason": "building placement catalog shape invalid"}
	var kinds: PackedInt32Array = catalog.get("building_kinds", PackedInt32Array())
	var quantities: PackedInt64Array = catalog.get(
		"building_production_resource_quantities", PackedInt64Array())
	var modes: PackedInt32Array = catalog.get(
		"building_production_resource_modes", PackedInt32Array())
	var access_modes: PackedInt32Array = catalog.get(
		"building_production_resource_access_modes", PackedInt32Array())
	var family_ids: PackedStringArray = catalog.get(
		"building_upgrade_family_ids", PackedStringArray())
	var family_indices: PackedInt32Array = catalog.get(
		"building_upgrade_family_indices", PackedInt32Array())
	var upgrade_tiers: PackedInt32Array = catalog.get(
		"building_upgrade_tiers", PackedInt32Array())
	var resource_begin := int(production_resources.begin)
	var resource_end := int(production_resources.end)
	if type_id >= kinds.size() or type_id >= family_indices.size() \
			or type_id >= upgrade_tiers.size() \
			or resource_end > quantities.size() or resource_end > modes.size() \
			or resource_end > access_modes.size() or type_id + 1 >= technology_offsets.size() \
			or type_id + 1 >= required_offsets.size():
		return {"ok": false, "reason": "building placement resource columns invalid"}
	var technology_begin := int(technology_offsets[type_id])
	var technology_end := int(technology_offsets[type_id + 1])
	var required_begin := int(required_offsets[type_id])
	var required_end := int(required_offsets[type_id + 1])
	var input_begin := int(input_goods.begin)
	var input_end := int(input_goods.end)
	if required_begin < 0 or required_end < required_begin or required_end > required_tags.size() \
			or technology_begin < 0 or technology_end < technology_begin \
			or technology_end > technology_tags.size() or input_end > input_categories_all.size() \
			or input_end > input_min_levels_all.size() or input_end >= candidate_offsets_all.size() \
			or input_end > input_quantities_all.size() \
			or input_end > input_required_all.size() \
			or int(output_goods.end) > output_quantities_all.size():
		return {"ok": false, "reason": "building placement technology columns invalid"}
	var local_candidate_offsets := PackedInt32Array([0])
	var local_candidate_good_ids := PackedStringArray()
	var local_candidate_efficiencies := PackedInt32Array()
	for input_idx in range(input_begin, input_end):
		var candidate_begin := int(candidate_offsets_all[input_idx])
		var candidate_end := int(candidate_offsets_all[input_idx + 1])
		if candidate_begin < 0 or candidate_end < candidate_begin \
				or candidate_end > candidate_goods_all.size() \
				or candidate_end > candidate_efficiencies_all.size():
			return {"ok": false, "reason": "building placement candidate columns invalid"}
		for candidate_idx in range(candidate_begin, candidate_end):
			var good_idx := int(candidate_goods_all[candidate_idx])
			if good_idx < 0 or good_idx >= good_ids.size():
				return {"ok": false, "reason": "building placement candidate good invalid"}
			local_candidate_good_ids.append(good_ids[good_idx])
			local_candidate_efficiencies.append(candidate_efficiencies_all[candidate_idx])
		local_candidate_offsets.append(local_candidate_good_ids.size())
	var output_categories := PackedStringArray()
	var output_substitution_offsets := PackedInt32Array([0])
	var output_substitution_ids := PackedStringArray()
	for good_id in output_goods.ids:
		var good_idx := good_ids.find(String(good_id))
		output_categories.append(String(good_categories[good_idx]) \
			if good_idx >= 0 and good_idx < good_categories.size() else "")
		if good_idx < 0 or good_idx + 1 >= good_substitution_offsets.size():
			return {"ok": false, "reason": "building output substitution categories invalid"}
		var category_begin := int(good_substitution_offsets[good_idx])
		var category_end := int(good_substitution_offsets[good_idx + 1])
		if category_begin < 0 or category_end <= category_begin \
				or category_end > good_substitution_ids.size():
			return {"ok": false, "reason": "building output substitution category range invalid"}
		output_substitution_ids.append_array(
			good_substitution_ids.slice(category_begin, category_end))
		output_substitution_offsets.append(output_substitution_ids.size())
	var family_idx := int(family_indices[type_id])
	var higher_tier_ids := PackedStringArray()
	if family_idx >= 0:
		for candidate in range(type_ids.size()):
			if candidate < family_indices.size() and candidate < upgrade_tiers.size() \
					and int(family_indices[candidate]) == family_idx \
					and int(upgrade_tiers[candidate]) > int(upgrade_tiers[type_id]):
				higher_tier_ids.append(type_ids[candidate])
	return {
		"ok": true,
		"type_id": type_id,
		"stable_id": String(building_id),
		"kind": int(kinds[type_id]),
		"upgrade_family_id": family_ids[family_idx] \
			if family_idx >= 0 and family_idx < family_ids.size() else "",
		"upgrade_tier": int(upgrade_tiers[type_id]),
		"higher_tier_building_ids": higher_tier_ids,
		"input_good_ids": input_goods.ids,
		"input_quantities": input_quantities_all.slice(input_begin, input_end),
		"input_required_q16": input_required_all.slice(input_begin, input_end),
		"input_category_ids": input_categories_all.slice(input_begin, input_end),
		"input_min_quality_levels": input_min_levels_all.slice(input_begin, input_end),
		"input_candidate_offsets": local_candidate_offsets,
		"input_candidate_good_ids": local_candidate_good_ids,
		"input_candidate_efficiency_q16": local_candidate_efficiencies,
		"output_good_ids": output_goods.ids,
		"output_quantities": output_quantities_all.slice(
			int(output_goods.begin), int(output_goods.end)),
		"output_category_ids": output_categories,
		"output_substitution_category_offsets": output_substitution_offsets,
		"output_substitution_category_ids": output_substitution_ids,
		"resource_ids": production_resources.ids,
		"resource_quantities": quantities.slice(resource_begin, resource_end),
		"resource_modes": modes.slice(resource_begin, resource_end),
		"resource_access_modes": access_modes.slice(resource_begin, resource_end),
		"technology_tags": technology_tags.slice(technology_begin, technology_end),
		"required_technology_tags": required_tags.slice(required_begin, required_end),
	}

static func _stable_ids_from_catalog_range(catalog: Dictionary, type_id: int, stable_ids: PackedStringArray,
		offset_key: String, index_key: String) -> Dictionary:
	var offsets: PackedInt32Array = catalog.get(offset_key, PackedInt32Array())
	var indices: PackedInt32Array = catalog.get(index_key, PackedInt32Array())
	if type_id + 1 >= offsets.size():
		return {"ok": false}
	var begin := int(offsets[type_id])
	var end := int(offsets[type_id + 1])
	if begin < 0 or end < begin or end > indices.size():
		return {"ok": false}
	var ids := PackedStringArray()
	for edge in range(begin, end):
		var stable_idx := int(indices[edge])
		if stable_idx < 0 or stable_idx >= stable_ids.size():
			return {"ok": false}
		ids.append(stable_ids[stable_idx])
	return {"ok": true, "ids": ids, "begin": begin, "end": end}
