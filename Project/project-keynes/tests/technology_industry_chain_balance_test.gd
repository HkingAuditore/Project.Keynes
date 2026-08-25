extends SceneTree

const EconomyCatalogScript = preload("res://scripts/economy/economy_catalog.gd")
const NETWORK_PATH := "res://data/technology/technology_network.json"
const ERA_IDS := [
	"stone", "agrarian", "kingdom", "empire", "exploration", "enlightenment",
	"steam", "electrical", "atomic", "information", "intelligent",
]
const ERA_FOOD_LABOR_CAPACITY := [
	1.15, 1.35, 1.60, 2.00, 2.50, 3.20, 6.00, 18.00, 40.00, 90.00, 180.00,
]
const SURVIVAL_FOOD_UNITS_PER_PERSON := 824.0
const FOOD_EQUIVALENT_GOODS := [
	"prepared_staples", "bread", "grain", "gathered_plants", "potatoes",
	"game_meat", "meat", "fish", "canned_fish", "dairy_products",
	"vegetables", "processed_food", "wheat_grain", "rice_grain",
	"corn_grain", "livestock_products",
]
const RUNTIME_GOOD_SINKS := {
	"gold": "bullion monetary issue",
	"silver": "bullion monetary issue",
	"technology_points": "government research procurement",
}
const RUNTIME_TECHNOLOGY_CONSUMERS := {
	"tech.river_transport": "domestic river and lake transport capability",
	"tech.celestial_navigation": "domestic shallow-sea transport capability",
	"tech.oceanic_navigation": "domestic open-ocean transport capability",
	"tech.oceanic_ship_design": "domestic deep-ocean transport capability",
}


func _init() -> void:
	var catalog: Dictionary = EconomyCatalogScript.compile_native_catalog()
	assert(bool(catalog.get("ok", false)), str(catalog))
	var failures := []
	_audit_good_sinks(catalog, failures)
	_audit_first_real_applications(failures)
	_audit_unlock_semantics(catalog, failures)
	_audit_productivity(catalog, failures)
	_audit_early_farm_capacity(catalog, failures)
	_assert_negative_fixtures(catalog)
	for failure in failures:
		push_error(JSON.stringify(failure))
	if not failures.is_empty():
		push_error("%d technology/industry timing failures" % failures.size())
		quit(1)
		return
	print("[PASS] industry closure, semantic unlock timing, food capacity, and era productivity ladder")
	quit(0)


func _audit_good_sinks(catalog: Dictionary, failures: Array) -> void:
	var good_ids: PackedStringArray = catalog.good_ids
	var technology_ids: PackedStringArray = catalog.technology_ids
	var technology_eras: PackedStringArray = catalog.technology_era_ids
	var producer_era := {}
	var sink_era := {}
	var building_ids: PackedStringArray = catalog.building_type_ids
	for building in range(building_ids.size()):
		var owner := _building_owner(catalog, building)
		var era := ERA_IDS.find(String(technology_eras[owner]))
		for edge in range(catalog.building_output_offsets[building],
				catalog.building_output_offsets[building + 1]):
			var good := int(catalog.building_output_good_ids[edge])
			producer_era[good] = mini(int(producer_era.get(good, era)), era)
		for edge in range(catalog.building_construction_offsets[building],
				catalog.building_construction_offsets[building + 1]):
			for candidate_edge in range(catalog.building_construction_candidate_offsets[edge],
					catalog.building_construction_candidate_offsets[edge + 1]):
				var good := int(catalog.building_construction_candidate_good_ids[candidate_edge])
				sink_era[good] = mini(int(sink_era.get(good, era)), era)
		for edge in range(catalog.building_input_offsets[building],
				catalog.building_input_offsets[building + 1]):
			for candidate_edge in range(catalog.building_input_candidate_offsets[edge],
					catalog.building_input_candidate_offsets[edge + 1]):
				var good := int(catalog.building_input_candidate_good_ids[candidate_edge])
				sink_era[good] = mini(int(sink_era.get(good, era)), era)
	for good in catalog.component_good_ids:
		sink_era[int(good)] = -1
	for good_value in producer_era:
		var good := int(good_value)
		var good_id := String(good_ids[good])
		if RUNTIME_GOOD_SINKS.has(good_id):
			continue
		if not sink_era.has(good):
			failures.append({"kind": "good_without_sink", "good": good_id,
				"producer_era": ERA_IDS[int(producer_era[good])]})
			continue
		var first_supply := int(producer_era[good])
		var raw_sink := int(sink_era[good])
		var first_effective_sink := first_supply if raw_sink < 0 else maxi(first_supply, raw_sink)
		if first_effective_sink - first_supply > 1:
			failures.append({"kind": "good_sink_gap", "good": good_id,
				"producer_era": ERA_IDS[first_supply],
				"sink_era": ERA_IDS[first_effective_sink],
				"gap": first_effective_sink - first_supply})


func _audit_first_real_applications(failures: Array) -> void:
	var file := FileAccess.open(NETWORK_PATH, FileAccess.READ)
	assert(file != null)
	var parsed: Variant = JSON.parse_string(file.get_as_text())
	assert(parsed is Dictionary)
	var nodes: Array = (parsed as Dictionary).nodes
	var by_id := {}
	for node_value in nodes:
		var node: Dictionary = node_value
		by_id[String(node.id)] = node
	var memo := {}
	for node_value in nodes:
		var node: Dictionary = node_value
		if bool(node.get("is_milestone", false)) \
				or String(node.get("node_role", "")) == "identification":
			continue
		var id := String(node.id)
		var source_era := ERA_IDS.find(String(node.era_id))
		if _has_direct_consumer(node) or RUNTIME_TECHNOLOGY_CONSUMERS.has(id):
			continue
		var first_consumer := 1 << 29
		for target_value in nodes:
			var target: Dictionary = target_value
			if not _has_direct_consumer(target):
				continue
			if _hard_ancestors(String(target.id), by_id, memo).has(id):
				first_consumer = mini(first_consumer, ERA_IDS.find(String(target.era_id)))
		if first_consumer == 1 << 29:
			failures.append({"kind": "technology_without_application", "technology": id,
				"era": String(node.era_id)})
		elif first_consumer - source_era > 1:
			failures.append({"kind": "technology_application_gap", "technology": id,
				"era": String(node.era_id), "consumer_era": ERA_IDS[first_consumer],
				"gap": first_consumer - source_era})


func _has_direct_consumer(node: Dictionary) -> bool:
	return not (node.get("expected_bindings", []) as Array).is_empty() \
		or not (node.get("modifier_terms", []) as Array).is_empty()


func _hard_ancestors(id: String, by_id: Dictionary, memo: Dictionary) -> Dictionary:
	if memo.has(id):
		return memo[id]
	var result := {}
	for prerequisite_value in (by_id[id] as Dictionary).get("hard_prerequisite_ids", []):
		var prerequisite := String(prerequisite_value)
		result[prerequisite] = true
		for ancestor in _hard_ancestors(prerequisite, by_id, memo):
			result[ancestor] = true
	memo[id] = result
	return result


func _building_owner(catalog: Dictionary, building: int) -> int:
	for edge in range(catalog.building_technology_tag_offsets[building],
			catalog.building_technology_tag_offsets[building + 1]):
		var tag := String(catalog.building_technology_tags[edge])
		if tag.begins_with("tech."):
			return (catalog.technology_ids as PackedStringArray).find(tag)
	return -1


func _audit_unlock_semantics(catalog: Dictionary, failures: Array) -> void:
	var expected_eras := {
		"wild_wheat_stand": "stone", "wild_maize_stand": "stone",
		"wild_rice_marsh": "stone", "wild_tuber_patch": "stone",
		"rainfed_wheat_plot": "agrarian", "rainfed_maize_field": "agrarian",
		"upland_rice_plot": "agrarian", "wetland_rice_garden": "agrarian",
		"maize_garden": "agrarian", "highland_tuber_plot": "agrarian",
		"flax_collector": "agrarian", "spice_shade_garden": "agrarian",
		"pastoral_camp": "agrarian", "creamery": "agrarian",
		"wheat_farm": "kingdom", "rice_collector": "kingdom",
		"tenant_rainfed_maize_field": "kingdom",
		"tenant_rainfed_wheat_field": "kingdom", "tenant_paddy": "kingdom",
		"guild_weaving_house": "empire", "cottage_weaving": "exploration",
		"atmospheric_engine_workshop": "enlightenment",
		"improved_domestic_loom": "steam", "electricity_plant": "electrical",
		"wire_plant": "electrical", "basic_electrical_equipment_works": "electrical",
		"scientific_instrument_works": "electrical",
		"industrial_research_laboratory": "electrical",
		"polytechnic_institute": "atomic", "nuclear_power_plant": "information",
	}
	var building_ids: PackedStringArray = catalog.building_type_ids
	var technology_eras: PackedStringArray = catalog.technology_era_ids
	for building_id in expected_eras:
		var building := building_ids.find(String(building_id))
		if building < 0:
			failures.append({"kind": "missing_semantic_building", "building": building_id})
			continue
		var owner := _building_owner(catalog, building)
		var actual := String(technology_eras[owner]) if owner >= 0 else ""
		if actual != String(expected_eras[building_id]):
			failures.append({"kind": "semantic_era_mismatch", "building": building_id,
				"expected": expected_eras[building_id], "actual": actual})


func _audit_productivity(catalog: Dictionary, failures: Array) -> void:
	var building_ids: PackedStringArray = catalog.building_type_ids
	var good_ids: PackedStringArray = catalog.good_ids
	var prices: PackedInt32Array = catalog.good_default_price
	var owner_slots: PackedInt64Array = catalog.building_owner_slots
	var employee_offsets: PackedInt32Array = catalog.building_employee_offsets
	var employee_slots: PackedInt64Array = catalog.building_employee_slots
	var output_offsets: PackedInt32Array = catalog.building_output_offsets
	var output_goods: PackedInt32Array = catalog.building_output_good_ids
	var output_quantities: PackedInt64Array = catalog.building_output_quantities
	var technology_eras: PackedStringArray = catalog.technology_era_ids
	var family_indices: PackedInt32Array = catalog.building_upgrade_family_indices
	var family_ids: PackedStringArray = catalog.building_upgrade_family_ids
	var tiers: PackedInt32Array = catalog.building_upgrade_tiers
	var era_productivity := {}
	var family_rows := {}
	var precious_rows := {"gold": [], "silver": []}
	var era_food_capacity := {}
	var input_offsets: PackedInt32Array = catalog.building_input_offsets
	var input_goods: PackedInt32Array = catalog.building_input_good_ids
	var input_quantities: PackedInt64Array = catalog.building_input_quantities
	var input_required: PackedInt32Array = catalog.building_input_required_q16
	for building in range(building_ids.size()):
		var labor := maxi(1, int(owner_slots[building]))
		for role in range(employee_offsets[building], employee_offsets[building + 1]):
			labor += int(employee_slots[role])
		var value := 0.0
		var special := false
		var precious_id := ""
		var food_output := 0.0
		for edge in range(output_offsets[building], output_offsets[building + 1]):
			var good := int(output_goods[edge])
			var good_id := String(good_ids[good])
			value += float(output_quantities[edge]) * float(prices[good])
			if good_id == "technology_points":
				special = true
			if good_id in ["gold", "silver"]:
				special = true
				precious_id = good_id
			if good_id in FOOD_EQUIVALENT_GOODS:
				food_output += float(output_quantities[edge])
		if value <= 0.0:
			continue
		var productivity := value / float(labor)
		var owner := _building_owner(catalog, building)
		var era_id := String(technology_eras[owner]) if owner >= 0 else ""
		var era := ERA_IDS.find(era_id)
		var food_capacity := food_output / float(labor) / SURVIVAL_FOOD_UNITS_PER_PERSON
		if food_output > 0.0 and era >= 0:
			var food_rows: Array = era_food_capacity.get(era_id, [])
			food_rows.append(food_capacity)
			era_food_capacity[era_id] = food_rows
			var food_input := 0.0
			for edge in range(input_offsets[building], input_offsets[building + 1]):
				var input_good_id := String(good_ids[int(input_goods[edge])])
				if input_good_id in FOOD_EQUIVALENT_GOODS \
						and int(input_required[edge]) > 0:
					food_input += float(input_quantities[edge])
			if food_input > 0.0 and food_output / food_input > 1.12:
				failures.append({"kind": "food_processing_amplification",
					"building": String(building_ids[building]),
					"output_input_ratio": food_output / food_input})
		if not special and era >= 0:
			var era_rows: Array = era_productivity.get(era_id, [])
			era_rows.append(productivity)
			era_productivity[era_id] = era_rows
		if not precious_id.is_empty():
			(precious_rows[precious_id] as Array).append(productivity)
		var family := int(family_indices[building])
		if family >= 0:
			var rows: Array = family_rows.get(family, [])
			rows.append({"tier": int(tiers[building]), "productivity": productivity,
				"food_capacity": food_capacity, "food": food_output > 0.0,
				"building": String(building_ids[building])})
			family_rows[family] = rows

	for family in family_rows:
		var rows: Array = family_rows[family]
		if rows.size() < 2:
			continue
		# Research capacity follows its own deliberately smoother 1x -> 16x curve.
		# It is checked as a complete chain below instead of enforcing +35% per tier.
		if String(family_ids[int(family)]) == "research_institution":
			continue
		rows.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
			return int(a.tier) < int(b.tier))
		if rows.any(func(row: Dictionary) -> bool: return bool(row.food)):
			for index in range(1, rows.size()):
				var ratio := float((rows[index] as Dictionary).food_capacity) / maxf(0.001,
					float((rows[index - 1] as Dictionary).food_capacity))
				if ratio < 1.04:
					failures.append({"kind": "food_upgrade_productivity_gap",
						"family": String(family_ids[int(family)]),
						"earlier": (rows[index - 1] as Dictionary).building,
						"later": (rows[index] as Dictionary).building, "ratio": ratio})
			continue
		for index in range(1, rows.size()):
			var ratio := float((rows[index] as Dictionary).productivity) / maxf(1.0,
				float((rows[index - 1] as Dictionary).productivity))
			if ratio < 1.34:
				failures.append({"kind": "upgrade_productivity_gap",
					"family": String(family_ids[int(family)]),
					"earlier": (rows[index - 1] as Dictionary).building,
					"later": (rows[index] as Dictionary).building, "ratio": ratio})

	var stone_median := _median_float(era_productivity.get("stone", []))
	for era_id in ["information", "intelligent"]:
		var ratio := _median_float(era_productivity.get(era_id, [])) / maxf(1.0, stone_median)
		# Same-era higher-tier methods can lift the era-wide median above the
		# authored baseline; food capacity is intentionally not upper-clamped.
		if ratio < 15.0 or ratio > 30.5:
			failures.append({"kind": "era_productivity_gap", "era": era_id,
				"ratio_to_stone": ratio})
	for era in range(ERA_IDS.size()):
		var era_id := String(ERA_IDS[era])
		var rows: Array = era_food_capacity.get(era_id, [])
		if rows.is_empty():
			continue
		var expected := float(ERA_FOOD_LABOR_CAPACITY[era])
		for capacity in rows:
			if float(capacity) < expected * 0.995:
				failures.append({"kind": "food_labor_capacity_out_of_range",
					"era": era_id, "capacity": capacity, "expected": expected})
	if not era_food_capacity.get("stone", []).is_empty() \
			and not era_food_capacity.get("intelligent", []).is_empty():
		var food_ratio := _median_float(era_food_capacity["intelligent"]) / maxf(0.001,
			_median_float(era_food_capacity["stone"]))
		if food_ratio < 140.0:
			failures.append({"kind": "food_long_run_productivity_gap",
				"ratio_to_stone": food_ratio})
	var research_family := family_ids.find("research_institution")
	if research_family >= 0 and family_rows.has(research_family):
		var research: Array = family_rows[research_family]
		research.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
			return int(a.tier) < int(b.tier))
		var ratio := float((research.back() as Dictionary).productivity) / maxf(1.0,
			float((research.front() as Dictionary).productivity))
		if ratio < 12.0 or ratio > 20.0:
			failures.append({"kind": "research_productivity_gap", "ratio": ratio})
	for good_id in precious_rows:
		var rows: Array = precious_rows[good_id]
		if rows.size() < 2:
			continue
		rows.sort()
		var ratio := float(rows.back()) / maxf(1.0, float(rows.front()))
		if ratio < 8.0 or ratio > 15.0:
			failures.append({"kind": "precious_productivity_gap", "good": good_id,
				"ratio": ratio})


func _audit_early_farm_capacity(catalog: Dictionary, failures: Array) -> void:
	var expected := {
		"wild_wheat_stand": ["stone", 1.10, 1.20],
		"wild_rice_marsh": ["stone", 1.10, 1.20],
		"wild_maize_stand": ["stone", 1.10, 1.20],
		"wild_tuber_patch": ["stone", 1.10, 1.20],
		"subsistence_farm": ["agrarian", 1.30, 1.40],
		"floodplain_wheat_plot": ["agrarian", 1.30, 1.40],
		"upland_rice_plot": ["agrarian", 1.30, 1.40],
		"maize_garden": ["agrarian", 1.40, 1.50],
		"rainfed_wheat_plot": ["agrarian", 1.40, 1.50],
		"wetland_rice_garden": ["agrarian", 1.40, 1.50],
		"rainfed_maize_field": ["agrarian", 1.50, 1.60],
		"swidden_maize_plot": ["agrarian", 1.50, 1.60],
	}
	var ids: PackedStringArray = catalog.building_type_ids
	var output_offsets: PackedInt32Array = catalog.building_output_offsets
	var output_goods: PackedInt32Array = catalog.building_output_good_ids
	var output_quantities: PackedInt64Array = catalog.building_output_quantities
	var owner_slots: PackedInt64Array = catalog.building_owner_slots
	var employee_offsets: PackedInt32Array = catalog.building_employee_offsets
	var employee_slots: PackedInt64Array = catalog.building_employee_slots
	var good_ids: PackedStringArray = catalog.good_ids
	for building_id in expected:
		var building := ids.find(String(building_id))
		if building < 0:
			failures.append({"kind": "missing_early_farm_capacity_fixture",
				"building": building_id})
			continue
		var labor := maxi(1, int(owner_slots[building]))
		for role in range(employee_offsets[building], employee_offsets[building + 1]):
			labor += int(employee_slots[role])
		var food_output := 0.0
		for edge in range(output_offsets[building], output_offsets[building + 1]):
			var good_id := String(good_ids[int(output_goods[edge])])
			if good_id in FOOD_EQUIVALENT_GOODS:
				food_output += float(output_quantities[edge])
		var capacity := food_output / float(labor) / SURVIVAL_FOOD_UNITS_PER_PERSON
		var bounds: Array = expected[building_id]
		if capacity < float(bounds[1]) or capacity > float(bounds[2]):
			failures.append({"kind": "early_farm_capacity_out_of_range",
				"building": building_id, "capacity": capacity,
				"expected_era": bounds[0], "range": [bounds[1], bounds[2]]})


func _median_float(values: Array) -> float:
	if values.is_empty():
		return 0.0
	var sorted := values.duplicate()
	sorted.sort()
	var middle := sorted.size() / 2
	if sorted.size() % 2 == 1:
		return float(sorted[middle])
	return (float(sorted[middle - 1]) + float(sorted[middle])) * 0.5


func _assert_negative_fixtures(catalog: Dictionary) -> void:
	var file := FileAccess.open(NETWORK_PATH, FileAccess.READ)
	assert(file != null)
	var parsed: Variant = JSON.parse_string(file.get_as_text())
	assert(parsed is Dictionary)
	var nodes: Array = (parsed as Dictionary).nodes
	var by_id := {}
	for node_value in nodes:
		var node: Dictionary = node_value
		by_id[String(node.id)] = node
	var composite_fixture: Dictionary = (by_id["tech.composite_tools"] as Dictionary).duplicate(true)
	assert(_composite_tools_fixture_valid(composite_fixture))
	composite_fixture.hard_prerequisite_ids = []
	assert(not _composite_tools_fixture_valid(composite_fixture),
		"composite tools without stone knapping was not rejected")
	var bast_index := (catalog.good_ids as PackedStringArray).find("bast_fiber")
	assert(bast_index >= 0)
	var producer_count := 0
	for building in range((catalog.building_type_ids as PackedStringArray).size()):
		for edge in range(catalog.building_output_offsets[building],
				catalog.building_output_offsets[building + 1]):
			if int(catalog.building_output_good_ids[edge]) == bast_index:
				producer_count += 1
	assert(_producer_fixture_valid(producer_count))
	producer_count = 0
	assert(not _producer_fixture_valid(producer_count),
		"bast-fiber demand without an executable producer was not rejected")


func _composite_tools_fixture_valid(node: Dictionary) -> bool:
	return (node.get("hard_prerequisite_ids", []) as Array).has(
		"tech.stone_knapping")


func _producer_fixture_valid(producer_count: int) -> bool:
	return producer_count > 0
