extends SceneTree

const EconomyCatalogScript = preload("res://scripts/economy/economy_catalog.gd")

const ERA_IDS := [
	"stone", "agrarian", "kingdom", "empire", "exploration",
	"enlightenment", "steam", "electrical", "atomic", "information",
	"intelligent",
]
const UNAVAILABLE := 1 << 20
const SYSTEM_DEMAND_GOODS := {
	"technology_points": "country_research_procurement",
}


func _init() -> void:
	var catalog: Dictionary = EconomyCatalogScript.compile_native_catalog()
	assert(bool(catalog.get("ok", false)), str(catalog))
	var report := audit(catalog)
	for failure in report.failures:
		push_error(JSON.stringify(failure))
	if not report.failures.is_empty():
		push_error("%d goods fail lifecycle closure (%d unavailable buildings)" % [
			report.failures.size(), report.unavailable_buildings.size()])
		quit(1)
		return
	print("[PASS] %d goods have reachable production and same-era demand; %d buildings close" % [
		report.audited_goods, report.closed_buildings])
	quit(0)


static func audit(catalog: Dictionary) -> Dictionary:
	var good_ids: PackedStringArray = catalog.good_ids
	var technology_ids: PackedStringArray = catalog.technology_ids
	var technology_era_ids: PackedStringArray = catalog.technology_era_ids
	var technology_eras := PackedInt32Array()
	technology_eras.resize(technology_ids.size())
	for technology in range(technology_ids.size()):
		technology_eras[technology] = ERA_IDS.find(String(technology_era_ids[technology]))
		assert(technology_eras[technology] >= 0, String(technology_ids[technology]))

	var good_unlock_eras := _minimum_tag_eras(
		good_ids.size(), catalog.good_technology_tag_offsets,
		catalog.good_technology_tags, technology_ids, technology_eras)
	var resource_unlock_eras := _minimum_tag_eras(
		catalog.building_resource_ids.size(),
		catalog.building_resource_technology_tag_offsets,
		catalog.building_resource_technology_tags,
		technology_ids, technology_eras)
	var building_unlock_eras := _minimum_tag_eras(
		catalog.building_type_ids.size(), catalog.building_technology_tag_offsets,
		catalog.building_technology_tags, technology_ids, technology_eras)

	var production_eras := PackedInt32Array()
	production_eras.resize(good_ids.size())
	production_eras.fill(UNAVAILABLE)
	var building_closure_eras := PackedInt32Array()
	building_closure_eras.resize(catalog.building_type_ids.size())
	building_closure_eras.fill(UNAVAILABLE)
	var changed := true
	while changed:
		changed = false
		for building in range(catalog.building_type_ids.size()):
			var closure_era := _building_closure_era(catalog, building,
				building_unlock_eras[building], production_eras,
				resource_unlock_eras)
			if closure_era >= building_closure_eras[building]:
				continue
			building_closure_eras[building] = closure_era
			changed = true
			for edge in range(catalog.building_output_offsets[building],
					catalog.building_output_offsets[building + 1]):
				var good := int(catalog.building_output_good_ids[edge])
				var available_era := maxi(closure_era, int(good_unlock_eras[good]))
				if available_era < production_eras[good]:
					production_eras[good] = available_era

	var demand_eras := PackedInt32Array()
	demand_eras.resize(good_ids.size())
	demand_eras.fill(UNAVAILABLE)
	var demand_kinds: Array = []
	demand_kinds.resize(good_ids.size())
	for good in range(good_ids.size()):
		demand_kinds[good] = PackedStringArray()
	for good_value in catalog.component_good_ids:
		var household_good := int(good_value)
		_record_demand(household_good, int(good_unlock_eras[household_good]),
			"household_consumption", demand_eras, demand_kinds)
	for building in range(catalog.building_type_ids.size()):
		var era := int(building_closure_eras[building])
		if era >= UNAVAILABLE:
			continue
		_record_building_good_demands(catalog, building, era, demand_eras,
			demand_kinds)
	var monetary_values: PackedInt64Array = catalog.good_monetary_issue_values
	for good in range(good_ids.size()):
		if monetary_values[good] > 0:
			_record_demand(good, production_eras[good], "bullion_issuance",
				demand_eras, demand_kinds)
		var stable_id := String(good_ids[good])
		if SYSTEM_DEMAND_GOODS.has(stable_id):
			_record_demand(good, production_eras[good],
				String(SYSTEM_DEMAND_GOODS[stable_id]), demand_eras, demand_kinds)

	var failures := []
	var producer_names: Array = []
	producer_names.resize(good_ids.size())
	var demand_names: Array = []
	demand_names.resize(good_ids.size())
	for good in range(good_ids.size()):
		producer_names[good] = PackedStringArray()
		demand_names[good] = PackedStringArray()
	for building in range(catalog.building_type_ids.size()):
		var closure_era := int(building_closure_eras[building])
		if closure_era >= UNAVAILABLE:
			continue
		for edge in range(catalog.building_output_offsets[building],
				catalog.building_output_offsets[building + 1]):
			var output_good := int(catalog.building_output_good_ids[edge])
			_append_unique(producer_names[output_good],
				String(catalog.building_type_ids[building]))
		for edge in range(catalog.building_construction_offsets[building],
				catalog.building_construction_offsets[building + 1]):
			_append_demand_building_names(catalog, building, edge,
				catalog.building_construction_good_ids,
				catalog.building_construction_candidate_offsets,
				catalog.building_construction_candidate_good_ids,
				demand_names)
		for edge in range(catalog.building_input_offsets[building],
				catalog.building_input_offsets[building + 1]):
			_append_demand_building_names(catalog, building, edge,
				catalog.building_input_good_ids,
				catalog.building_input_candidate_offsets,
				catalog.building_input_candidate_good_ids,
				demand_names)
	for good in range(good_ids.size()):
		var stable_id := String(good_ids[good])
		var production_era := int(production_eras[good])
		var demand_era := int(demand_eras[good])
		if production_era >= UNAVAILABLE:
			failures.append({
				"good": stable_id,
				"reason": "no_reachable_producer",
				"unlock_era": _era_name(good_unlock_eras[good]),
			})
			continue
		if demand_era >= UNAVAILABLE:
			failures.append({
				"good": stable_id,
				"reason": "no_demand_sink",
				"production_era": _era_name(production_era),
			})
			continue
		if demand_era > production_era:
			failures.append({
				"good": stable_id,
				"reason": "demand_lag",
				"production_era": _era_name(production_era),
				"demand_era": _era_name(demand_era),
				"lag_eras": demand_era - production_era,
				"demand_kinds": demand_kinds[good],
				"producers": producer_names[good],
				"demand_buildings": demand_names[good],
			})
	var unavailable_buildings := PackedStringArray()
	for building in range(catalog.building_type_ids.size()):
		if building_closure_eras[building] >= UNAVAILABLE:
			unavailable_buildings.append(String(catalog.building_type_ids[building]))
	return {
		"failures": failures,
		"unavailable_buildings": unavailable_buildings,
		"closed_buildings": catalog.building_type_ids.size() - unavailable_buildings.size(),
		"audited_goods": good_ids.size(),
}


static func _append_unique(values: PackedStringArray, value: String) -> void:
	if not values.has(value):
		values.append(value)


static func _append_demand_building_names(catalog: Dictionary, building: int,
		edge: int, preferred_ids: PackedInt32Array,
		candidate_offsets: PackedInt32Array,
		candidate_ids: PackedInt32Array, demand_names: Array) -> void:
	var building_name := String(catalog.building_type_ids[building])
	if edge + 1 < candidate_offsets.size() \
			and candidate_offsets[edge + 1] > candidate_offsets[edge]:
		for candidate_edge in range(candidate_offsets[edge], candidate_offsets[edge + 1]):
			_append_unique(demand_names[int(candidate_ids[candidate_edge])], building_name)
	else:
		_append_unique(demand_names[int(preferred_ids[edge])], building_name)


static func _minimum_tag_eras(row_count: int, offsets: PackedInt32Array,
		tags: PackedStringArray, technology_ids: PackedStringArray,
		technology_eras: PackedInt32Array) -> PackedInt32Array:
	var out := PackedInt32Array()
	out.resize(row_count)
	out.fill(UNAVAILABLE)
	for row in range(row_count):
		for edge in range(offsets[row], offsets[row + 1]):
			var technology := technology_ids.find(String(tags[edge]))
			if technology >= 0:
				out[row] = mini(out[row], int(technology_eras[technology]))
	return out


static func _building_closure_era(catalog: Dictionary, building: int,
		unlock_era: int, production_eras: PackedInt32Array,
		resource_unlock_eras: PackedInt32Array) -> int:
	if unlock_era >= UNAVAILABLE:
		return UNAVAILABLE
	var era := unlock_era
	for edge in range(catalog.building_construction_offsets[building],
			catalog.building_construction_offsets[building + 1]):
		var group_era := _candidate_group_era(edge,
			catalog.building_construction_good_ids,
			catalog.building_construction_candidate_offsets,
			catalog.building_construction_candidate_good_ids, production_eras)
		if group_era >= UNAVAILABLE:
			return UNAVAILABLE
		era = maxi(era, group_era)
	for edge in range(catalog.building_input_offsets[building],
			catalog.building_input_offsets[building + 1]):
		var group_era := _candidate_group_era(edge,
			catalog.building_input_good_ids,
			catalog.building_input_candidate_offsets,
			catalog.building_input_candidate_good_ids, production_eras)
		if group_era >= UNAVAILABLE:
			return UNAVAILABLE
		era = maxi(era, group_era)
	for edge in range(catalog.building_resource_offsets[building],
			catalog.building_resource_offsets[building + 1]):
		var resource := int(catalog.building_production_resource_ids[edge])
		if resource_unlock_eras[resource] >= UNAVAILABLE:
			return UNAVAILABLE
		era = maxi(era, int(resource_unlock_eras[resource]))
	return era


static func _candidate_group_era(edge: int, preferred_ids: PackedInt32Array,
		candidate_offsets: PackedInt32Array, candidate_ids: PackedInt32Array,
		production_eras: PackedInt32Array) -> int:
	var era := UNAVAILABLE
	if edge + 1 < candidate_offsets.size() \
			and candidate_offsets[edge + 1] > candidate_offsets[edge]:
		for candidate_edge in range(candidate_offsets[edge],
				candidate_offsets[edge + 1]):
			era = mini(era, int(production_eras[int(candidate_ids[candidate_edge])]))
	else:
		era = int(production_eras[int(preferred_ids[edge])])
	return era


static func _record_building_good_demands(catalog: Dictionary, building: int,
		era: int, demand_eras: PackedInt32Array, demand_kinds: Array) -> void:
	for spec in [
		[catalog.building_construction_offsets,
			catalog.building_construction_good_ids,
			catalog.building_construction_candidate_offsets,
			catalog.building_construction_candidate_good_ids,
			"building_construction"],
		[catalog.building_input_offsets, catalog.building_input_good_ids,
			catalog.building_input_candidate_offsets,
			catalog.building_input_candidate_good_ids, "building_input"],
	]:
		var offsets: PackedInt32Array = spec[0]
		var preferred_ids: PackedInt32Array = spec[1]
		var candidate_offsets: PackedInt32Array = spec[2]
		var candidate_ids: PackedInt32Array = spec[3]
		for edge in range(offsets[building], offsets[building + 1]):
			if edge + 1 < candidate_offsets.size() \
					and candidate_offsets[edge + 1] > candidate_offsets[edge]:
				for candidate_edge in range(candidate_offsets[edge],
						candidate_offsets[edge + 1]):
					_record_demand(int(candidate_ids[candidate_edge]), era,
						String(spec[4]), demand_eras, demand_kinds)
			else:
				_record_demand(int(preferred_ids[edge]), era, String(spec[4]),
					demand_eras, demand_kinds)


static func _record_demand(good: int, era: int, kind: String,
		demand_eras: PackedInt32Array, demand_kinds: Array) -> void:
	if era < demand_eras[good]:
		demand_eras[good] = era
	var kinds: PackedStringArray = demand_kinds[good]
	if not kinds.has(kind):
		kinds.append(kind)
		demand_kinds[good] = kinds


static func _era_name(era: int) -> String:
	return String(ERA_IDS[era]) if era >= 0 and era < ERA_IDS.size() else "unavailable"
