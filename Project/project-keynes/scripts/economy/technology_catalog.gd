class_name TechnologyCatalog
extends RefCounted

const ResearchSignalCatalogScript = preload("res://scripts/research/research_signal_catalog.gd")
const ResearchConditionScript = preload("res://scripts/research/research_condition.gd")
const ResearchPredicateScript = preload("res://scripts/research/research_predicate.gd")
const EraRewardCatalogScript = preload("res://scripts/effect/era_reward_catalog.gd")

const NETWORK_DATA_PATH := "res://data/technology/technology_network.json"

static var _network_payload_cache: Dictionary = {}

# Building IDs whose direct technology tag is only one axis of an ALL gate.
# Keep this cold-path projection beside the technology presentation contract;
# EconomyCatalog still validates the authoritative required_technology_tags.
const COMPOSITE_BUILDING_IDS: PackedStringArray = [
	"adobe_yard", "bark_paper_workshop", "basic_semiconductor_fab", "bloomery",
	"bread_plant", "bricks_plant", "bunded_rice_field", "cabinetmaker_workshop",
	"cadastral_office", "canned_fish_plant", "canning_workshop", "charcoal_pit",
	"classical_masonry_yard", "cloth_plant", "coal_adit", "concrete_plant",
	"construction_components_plant", "copper_ore_collector", "cottage_weaving",
	"cotton_collector", "cotton_garden", "cotton_ginning_shelter", "dairy_products_plant",
	"detergent_plant", "dryland_wheat_field", "early_clay_pit", "early_copper_mine",
	"early_copper_smelter", "early_iron_mine", "early_tin_mine", "early_tin_smelter",
	"estate_paddy", "explosives_plant", "fertile_soil_collector", "fine_clothing_plant",
	"fine_furniture_plant", "fired_brick_kiln", "flax_collector", "flax_retting_pit",
	"floodplain_maize_plot", "floodplain_wheat_plot", "footwear_plant", "furniture_plant",
	"gas_power_plant", "geospatial_analysis_center", "gold_mine", "hide_scraping_shelter",
	"highland_tuber_plot", "household_appliances_plant", "household_loom", "hydropower_station",
	"improved_domestic_loom", "industrial_machinery_plant", "industrial_salt_mine",
	"iron_tool_workshop", "jewelry_plant", "knapping_workshop", "landed_estate",
	"latex_smoking_shelter", "lead_ore_collector", "lead_plant", "leather_plant",
	"limestone_collector", "lorekeeper_circle", "maize_garden", "mechanized_farm",
	"mechanized_slaughterhouse", "merchant_post", "method_aluminum_plant_r10",
	"method_automated_port", "method_automobiles_plant_r10", "method_autonomous_forestry",
	"method_autonomous_shipping", "method_batteries_plant_r10", "method_cement_plant_r9",
	"method_coke_ovens_r9", "method_concrete_plant_r9", "method_cotton_collector_r6",
	"method_detergent_plant_r10", "method_edible_oil_plant_r6", "method_electric_motor_plant_r10",
	"method_electronic_components_plant_r10", "method_engines_plant_r10",
	"method_explosives_plant_r10", "method_explosives_plant_r8", "method_flax_collector_r3",
	"method_flax_collector_r5", "method_flint_quarry_r1", "method_forest_remote_sensing",
	"method_highland_precision_agriculture", "method_household_appliances_plant_r10",
	"method_industrial_machinery_plant_r9", "method_insulated_cable_plant_r10",
	"method_landed_estate_r6", "method_lead_ore_collector_r9", "method_lead_plant_r9",
	"method_limestone_collector_r6", "method_lubricants_plant_r9", "method_lumber_plant_r6",
	"method_machine_parts_plant_r9", "method_manganese_ore_collector_r10",
	"method_marine_fish_collector_r4", "method_natural_gas_collector_r10",
	"method_nuclear_fuel_plant_r10", "method_oceanic_shipyard_r7", "method_packaging_plant_r7",
	"method_petrochemicals_plant_r10", "method_phosphate_rock_collector_r9",
	"method_plastics_plant_r10", "method_potato_collector_r6", "method_pottery_kiln_r3",
	"method_precision_tool_workshop_r10", "method_precision_tool_workshop_r8",
	"method_printed_materials_plant_r7", "method_radio_equipment_works_r10",
	"method_rare_earth_collector_r10", "method_rare_earth_metals_plant_r10",
	"method_reactor_component_works_r10", "method_refined_fuel_plant_r10",
	"method_rice_collector_r3", "method_rice_collector_r5", "method_rubber_tree_collector_r6",
	"method_saltpeter_collector_r10", "method_saltpeter_collector_r8",
	"method_scientific_instrument_works_r10", "method_scientific_instrument_works_r8",
	"method_smart_husbandry", "method_soap_plant_r6", "method_specialty_commodity_plantation",
	"method_spice_plants_collector_r6", "method_stainless_steel_plant_r10",
	"method_steam_engine_works_r9", "method_steam_shipping", "method_stone_collector_r2",
	"method_sulfur_collector_r10", "method_sulfur_collector_r8",
	"method_synthetic_fiber_plant_r10", "method_synthetic_rubber_plant_r10",
	"method_wheat_farm_r3", "method_wheat_farm_r5", "method_wire_plant_r10",
	"method_zinc_ore_collector_r9", "method_zinc_plant_r9", "movable_type_print_shop",
	"natural_copper_workshop", "natural_gas_collector", "oil_collector", "oil_power_plant",
	"open_pottery_hearth", "ore_bronzesmith_camp", "packaging_plant", "paper_plant",
	"parchment_workshop", "pastoral_camp", "plant_fiber_paper_workshop",
	"polytechnic_institute", "potato_collector", "pottery_kiln", "primitive_clay_pit",
	"primitive_gold_sluice", "printed_materials_plant", "printing_academy",
	"processed_food_plant", "rainfed_maize_field", "rainfed_wheat_plot", "rare_earth_collector",
	"rice_collector", "rubber_tapping_camp", "rubber_tree_collector", "rubble_stone_working",
	"shallow_silver_working", "sharecrop_paddy", "silica_sand_collector", "silver_mine",
	"small_game_trapline", "smart_water_network", "solar_salt_pan", "spice_plants_collector",
	"spice_shade_garden", "staple_food_plant", "subsistence_farm", "surface_coal_gathering",
	"swidden_maize_plot", "synthetic_textile_mill", "tenant_paddy",
	"tenant_rainfed_maize_field", "tenant_rainfed_wheat_field", "tin_ore_collector",
	"upland_rice_plot", "watershed_governance_center", "wetland_rice_garden", "wheat_farm",
	"woodblock_printing_house", "zinc_ore_collector",
]

const DOMAIN_IDS := ["agriculture", "engineering", "science", "society"]
const DOMAIN_NAMES := ["农业", "工程", "科学", "社会"]
const DOMAIN_COLORS := [
	Color(0.39, 0.62, 0.31), Color(0.72, 0.48, 0.24),
	Color(0.28, 0.58, 0.74), Color(0.67, 0.48, 0.68),
]
## No technology is completed globally for every geography. Starter eligibility
## is authored per node in technology_network.json.
const STARTING_IDS := []
const FLAG_ERA_KEY := 1
const FLAG_MILESTONE := 2
const FLAG_STARTING := 4

# Packed postfix IR shared with NativeCountryRuntime. Values are deliberately
# numeric here so no authoring StringName reaches the country hot path.
const CONDITION_PUSH_TECH_COMPLETED := 1
const CONDITION_PUSH_SIGNAL_PRESENT := 2
const CONDITION_PUSH_SIGNAL_COUNT := 3
const CONDITION_ALL_OF := 10
const CONDITION_ANY_OF := 11
const CONDITION_AT_LEAST := 12
const CONDITION_NOT := 13

const ROUTE_CATEGORY_NAMES_ZH := {
	"ai": "人工智能", "animal": "动物", "climate": "气候", "craft": "工艺",
	"crop": "作物", "ecology": "生态", "energy": "能源", "geography": "地理",
	"institution": "制度", "material": "材料", "resource": "资源", "trade": "贸易",
}

const ROUTE_VALUE_NAMES_ZH := {
	"academic": "学术", "alloys": "合金", "automated": "自动化", "autonomy": "自主系统",
	"biotechnology": "生物技术", "calendar": "历法", "chemistry": "化学", "clay": "黏土",
	"coal": "煤炭", "coast": "沿海", "cold": "寒冷", "collaboration": "人机协作",
	"combustion": "内燃", "communication": "通信", "community": "社群", "computing": "计算",
	"copper": "铜", "drought": "干旱", "education": "教育", "electric": "电力",
	"exchange": "交流", "experimental": "实验", "factory": "工厂", "fire": "火",
	"flood": "洪水", "forest": "森林", "game": "野生动物", "general": "通用农艺",
	"gold": "黄金",
	"guild": "行会", "health": "卫生", "heat": "高温", "highland": "高地",
	"horse": "马匹", "industrial": "工业农业", "inland": "内陆", "iron": "铁",
	"knowledge": "知识", "laboratory": "实验室", "learning": "机器学习", "machinery": "机械",
	"maize": "玉米", "maritime": "海运", "market": "市场", "materials": "合成材料",
	"mechanized": "机械化", "minerals": "矿产", "modeling": "建模", "network": "网络",
	"nuclear": "核能", "observation": "观察", "oil": "石油", "oral": "口述传承",
	"pasture": "牧场", "phosphate": "磷矿", "planning": "规划", "plants": "野生植物",
	"precision": "精准", "printing": "印刷", "rail": "铁路", "rare_earth": "稀土",
	"records": "记录", "rice": "水稻", "river": "河流", "saltpeter": "硝石",
	"settlement": "聚落", "silver": "白银", "state": "国家治理", "steam": "蒸汽", "steppe": "草原",
	"stone": "石材", "storage": "储藏", "sulfur": "硫", "survey": "测绘",
	"textiles": "纺织", "thermal": "热能", "tin": "锡", "tools": "工具",
	"tropical": "热带作物", "tuber": "块茎作物", "university": "大学", "urban": "城市",
	"water": "水力", "wheat": "小麦", "wind": "风力", "writing": "文字",
}

static func _network_payload() -> Dictionary:
	if not _network_payload_cache.is_empty():
		return _network_payload_cache
	var file := FileAccess.open(NETWORK_DATA_PATH, FileAccess.READ)
	if file == null:
		return {"ok": false, "reason": "technology_network_missing", "path": NETWORK_DATA_PATH}
	var parsed = JSON.parse_string(file.get_as_text())
	file.close()
	if not parsed is Dictionary:
		return {"ok": false, "reason": "technology_network_json_invalid"}
	_network_payload_cache = (parsed as Dictionary).duplicate(true)
	_network_payload_cache["ok"] = true
	return _network_payload_cache


static func compile_native_catalog() -> Dictionary:
	var signal_catalog := ResearchSignalCatalogScript.compile_native_catalog()
	if not bool(signal_catalog.get("ok", false)):
		return signal_catalog
	var network := _network_payload()
	if not bool(network.get("ok", false)):
		return network
	var technology_rows: Array = (network.get("nodes", []) as Array).duplicate(true)
	# Schema-v3 authoring is already era-grouped and topologically ordered. Do
	# not re-sort by legacy layout_order: a same-era dependency may legitimately
	# point from a later visual row to an earlier one.
	var era_rows: Array = network.get("eras", [])
	var domain_rows: Array = network.get("domains", [])
	if technology_rows.size() != 361 or era_rows.size() != 11 or domain_rows.size() != 4 \
			or int(network.get("schema_version", 0)) != 3:
		return {"ok": false, "reason": "technology_network_shape_invalid"}
	var ids := PackedStringArray()
	var names := PackedStringArray()
	var era_ids := PackedStringArray()
	var domain_indices := PackedInt32Array()
	var costs := PackedInt64Array()
	var prerequisite_offsets := PackedInt32Array([0])
	var prerequisites := PackedInt32Array()
	var milestone_offsets := PackedInt32Array([0])
	var milestone_candidates := PackedInt32Array()
	var milestone_required := PackedInt32Array()
	var flags := PackedInt32Array()
	var effects := PackedStringArray()
	var profiles := PackedStringArray()
	var route_tag_offsets := PackedInt32Array([0])
	var route_tags := PackedStringArray()
	var node_roles := PackedStringArray()
	var primary_route_tags := PackedStringArray()
	var layout_lanes := PackedStringArray()
	var network_roles := PackedStringArray()
	var anchor_kinds := PackedStringArray()
	var starter_capability_offsets := PackedInt32Array([0])
	var starter_capability_tags := PackedStringArray()
	var id_to_index := {}
	var era_index := {}
	var era_milestone_ids := PackedStringArray()
	var era_entry_milestone_ids := PackedStringArray()
	var era_candidate_ids := {}
	var milestone_required_by_id := {}
	var milestone_candidate_ids := {}
	for i in range(era_rows.size()):
		var era_row: Dictionary = era_rows[i]
		var authored_era_id := String(era_row.get("id", ""))
		var milestone_id := String(era_row.get("milestone_id", ""))
		var candidate_ids: Array = era_row.get("milestone_candidate_ids", [])
		var candidate_required := int(era_row.get("candidate_required", 0))
		if candidate_ids.size() != 12 or candidate_required != 4:
			return {"ok": false, "reason": "technology_era_candidate_contract_invalid",
				"era_id": authored_era_id}
		era_index[authored_era_id] = i
		era_milestone_ids.append(milestone_id)
		era_entry_milestone_ids.append(String(era_row.get("entry_milestone_id", "")))
		era_candidate_ids[authored_era_id] = candidate_ids.duplicate()
		milestone_required_by_id[milestone_id] = candidate_required
		for candidate_id in candidate_ids:
			var normalized_candidate := String(candidate_id)
			if milestone_candidate_ids.has(normalized_candidate):
				return {"ok": false, "reason": "technology_milestone_candidate_duplicate",
					"id": normalized_candidate}
			milestone_candidate_ids[normalized_candidate] = authored_era_id
	for row_value in technology_rows:
		var row: Dictionary = row_value
		var id := String(row.get("id", ""))
		if not id.begins_with("tech.") or id_to_index.has(id):
			return {"ok": false, "reason": "technology_id_invalid_or_duplicate", "id": id}
		id_to_index[id] = ids.size()
		ids.append(id)
		names.append(String(row.get("display_name", "")))
	var reveal_condition_specs := {}
	for row_value in technology_rows:
		var row: Dictionary = row_value
		var row_id := String(row.get("id", ""))
		var row_index := int(id_to_index[row_id])
		var era := String(row.get("era_id", ""))
		var domain := DOMAIN_IDS.find(String(row.get("domain_id", "")))
		var secondary_routes: Array = row.get("secondary_route_tags", [])
		if not era_index.has(era) or domain < 0 or int(row.get("cost_points", -1)) < 0 \
				or String(row.get("effect_profile", "")).is_empty() \
				or String(row.get("branch_family_id", "")).is_empty() or secondary_routes.is_empty():
			return {"ok": false, "reason": "technology_metadata_invalid", "id": row_id}
		era_ids.append(era)
		domain_indices.append(domain)
		var is_starter := bool(row.get("is_starter_eligible", false))
		costs.append(0 if is_starter else int(row.get("cost_points", 0)) * 1000)
		var hard_prerequisites: Array = row.get("hard_prerequisite_ids", [])
		var prerequisite_rationales: Array = row.get("prerequisite_rationales", [])
		if prerequisite_rationales.size() != hard_prerequisites.size():
			return {"ok": false, "reason": "technology_prerequisite_rationale_count_invalid",
				"id": row_id}
		var branch_successors: Array = row.get("branch_successor_ids", [])
		var branch_rationales: Array = row.get("branch_successor_rationales", [])
		var application_targets: Array = row.get("application_target_ids", [])
		var application_rationales: Array = row.get("application_target_rationales", [])
		if branch_successors.size() != branch_rationales.size():
			return {"ok": false, "reason": "technology_branch_rationale_count_invalid",
				"id": row_id}
		if application_targets.size() != application_rationales.size():
			return {"ok": false, "reason": "technology_application_rationale_count_invalid",
				"id": row_id}
		for prerequisite in hard_prerequisites:
			var prerequisite_id := String(prerequisite)
			if not id_to_index.has(prerequisite_id):
				return {"ok": false, "reason": "technology_prerequisite_missing", "id": row_id, "prerequisite": prerequisite_id}
			var prerequisite_index := int(id_to_index[prerequisite_id])
			if prerequisite_index >= row_index:
				return {"ok": false, "reason": "technology_catalog_not_topological", "id": row_id,
					"prerequisite": prerequisite_id}
			prerequisites.append(prerequisite_index)
		prerequisite_offsets.append(prerequisites.size())
		var is_milestone := bool(row.get("is_milestone", false))
		var candidate_ids: Array = []
		if is_milestone:
			candidate_ids = (era_candidate_ids.get(era, []) as Array).duplicate()
			for candidate_id in candidate_ids:
				var candidate_index := int(id_to_index.get(candidate_id, -1))
				if candidate_index < 0 or candidate_index >= row_index:
					return {"ok": false, "reason": "technology_era_candidate_invalid", "id": row_id, "candidate": candidate_id}
				if String(technology_rows[candidate_index].get("era_id", "")) != era:
					return {"ok": false, "reason": "technology_era_candidate_wrong_era", "id": row_id, "candidate": candidate_id}
				milestone_candidates.append(candidate_index)
		milestone_offsets.append(milestone_candidates.size())
		milestone_required.append(int(milestone_required_by_id.get(row_id, 0)) if is_milestone else 0)
		flags.append((FLAG_ERA_KEY if milestone_candidate_ids.has(row_id) else 0) \
			| (FLAG_MILESTONE if is_milestone else 0) \
			| (FLAG_STARTING if is_starter else 0))
		effects.append(_visible_effect_summary(
			String(row.get("effect_summary", "")), row.get("content_effects", [])))
		profiles.append(String(row.get("effect_profile", "")))
		var route_seen := {}
		for route_tag in secondary_routes:
			var normalized_route := String(route_tag).strip_edges()
			if not normalized_route.begins_with("route.") or route_seen.has(normalized_route):
				return {"ok": false, "reason": "technology_route_tag_invalid", "id": row_id}
			route_seen[normalized_route] = true
			route_tags.append(normalized_route)
		route_tag_offsets.append(route_tags.size())
		var primary_route := String(secondary_routes[0])
		primary_route_tags.append(primary_route)
		layout_lanes.append(String(row.get("branch_family_id", "")))
		node_roles.append(String(row.get("node_role", "")))
		network_roles.append(String(row.get("network_role", "")))
		anchor_kinds.append(String(row.get("anchor_kind", "")))
		for capability_tag in row.get("starter_capability_tags", []):
			starter_capability_tags.append(String(capability_tag))
		starter_capability_offsets.append(starter_capability_tags.size())
		var research_spec: Dictionary = (row.get("research_condition", {}) as Dictionary).duplicate(true)
		if not research_spec.is_empty():
			return {"ok": false, "reason": "technology_legacy_research_condition_forbidden",
				"id": row_id}
		var reveal_spec: Dictionary = (row.get("reveal_condition", {}) as Dictionary).duplicate(true)
		var content_effects: Array = row.get("content_effects", [])
		if row.has("content_effects") and not _validate_content_effects(content_effects,
				(row.get("expected_bindings", []) as Array)):
			return {"ok": false, "reason": "technology_content_effect_invalid", "id": row_id}
		if not reveal_spec.is_empty():
			reveal_condition_specs[row_id] = reveal_spec
	var era_ids_out := PackedStringArray()
	var era_names := PackedStringArray()
	var era_milestones := PackedInt32Array()
	var era_entry_milestones := PackedInt32Array()
	for index in range(era_rows.size()):
		var era_row: Dictionary = era_rows[index]
		var milestone_id := String(era_row.get("milestone_id", ""))
		if not id_to_index.has(milestone_id):
			return {"ok": false, "reason": "technology_milestone_missing", "id": milestone_id}
		era_ids_out.append(String(era_row.get("id", "")))
		era_names.append(String(era_row.get("display_name", "")))
		era_milestones.append(int(id_to_index[milestone_id]))
		var entry_milestone_id := String(era_row.get("entry_milestone_id", ""))
		if index == 0:
			if not entry_milestone_id.is_empty():
				return {"ok": false, "reason": "technology_first_era_entry_milestone_invalid"}
			era_entry_milestones.append(-1)
		else:
			if not id_to_index.has(entry_milestone_id) \
					or entry_milestone_id != String(era_milestone_ids[index - 1]):
				return {"ok": false, "reason": "technology_era_entry_milestone_invalid",
					"era_id": String(era_row.get("id", ""))}
			era_entry_milestones.append(int(id_to_index[entry_milestone_id]))
	var technology_entry_milestones := PackedInt32Array()
	for technology_era_id in era_ids:
		technology_entry_milestones.append(
			era_entry_milestones[int(era_index[String(technology_era_id)])])
	var signal_ids: PackedStringArray = signal_catalog.get("research_signal_ids", PackedStringArray())
	var conditions := _compile_research_routes(technology_rows, ids, signal_ids, era_index)
	if not bool(conditions.get("ok", false)):
		return conditions
	var reveal_conditions := _compile_condition_specs(ids, signal_ids,
		reveal_condition_specs, "technology_reveal_condition")
	if not bool(reveal_conditions.get("ok", false)):
		return reveal_conditions
	var reveal_reverse := _compile_reveal_reverse_index(ids.size(), signal_ids.size(),
		reveal_conditions)
	var modifier_ir := _compile_explicit_modifier_term_ir(technology_rows)
	if not bool(modifier_ir.get("ok", false)):
		return modifier_ir
	var recipe_ids := PackedStringArray()
	var recipe_versions := PackedInt32Array()
	var starter_eligible_ids := PackedStringArray()
	for row_value in technology_rows:
		if bool((row_value as Dictionary).get("is_starter_eligible", false)):
			starter_eligible_ids.append(String((row_value as Dictionary).get("id", "")))
	for id in ids:
		var is_starting := starter_eligible_ids.has(String(id))
		recipe_ids.append("" if is_starting else "technology.%s" % String(id))
		recipe_versions.append(0 if is_starting else 1)
	var out := {
		"ok": true,
		"technology_ids": ids,
		"technology_display_names": names,
		"technology_era_ids": era_ids,
		"technology_domain_indices": domain_indices,
		"technology_costs": costs,
		"technology_prerequisite_offsets": prerequisite_offsets,
		"technology_prerequisites": prerequisites,
		"technology_milestone_offsets": milestone_offsets,
		"technology_milestone_candidates": milestone_candidates,
		"technology_milestone_required_counts": milestone_required,
		"technology_flags": flags,
		"technology_effect_summaries": effects,
		"technology_effect_profile_ids": profiles,
		"technology_effect_recipe_ids": recipe_ids,
		"technology_effect_recipe_versions": recipe_versions,
		"technology_route_tag_offsets": route_tag_offsets,
		"technology_route_tags": route_tags,
		"technology_node_roles": node_roles,
		"technology_primary_route_tags": primary_route_tags,
		"technology_layout_lanes": layout_lanes,
		"technology_network_roles": network_roles,
		"technology_anchor_kinds": anchor_kinds,
		"technology_starter_capability_offsets": starter_capability_offsets,
		"technology_starter_capability_tags": starter_capability_tags,
		"technology_modifier_definition_keys": _modifier_definition_keys(
			ids, modifier_ir.technology_modifier_term_offsets),
		"technology_domain_ids": PackedStringArray(DOMAIN_IDS),
		"technology_domain_display_names": PackedStringArray(DOMAIN_NAMES),
		"technology_domain_default_weights_bp": PackedInt32Array([2500, 2500, 2500, 2500]),
		"technology_era_ids_ordered": era_ids_out,
		"technology_era_display_names": era_names,
		"technology_era_milestone_indices": era_milestones,
		"technology_era_entry_milestone_indices": era_entry_milestones,
		"technology_entry_milestone_indices": technology_entry_milestones,
		# Technology owns the stable milestone -> reward-pool routing. The
		# candidate rules and executable templates remain Effect catalog data.
		"technology_era_reward_pool_ids": PackedStringArray(),
		"starting_technology_ids": PackedStringArray(STARTING_IDS),
		"starter_eligible_technology_ids": starter_eligible_ids,
		"technology_visual_edges": (network.get("visual_edges", []) as Array).duplicate(true),
	}
	for era_index_value in range(era_rows.size()):
		out.technology_era_reward_pool_ids.append(
			"era_reward.pool.%s" % String((era_rows[era_index_value] as Dictionary).get("id", "")))
	for key in signal_catalog:
		if key != "ok":
			out[key] = signal_catalog[key]
	for key in conditions:
		if key != "ok":
			out[key] = conditions[key]
	for key in reveal_conditions:
		if key != "ok":
			out[key] = reveal_conditions[key]
	for key in reveal_reverse:
		if key != "ok":
			out[key] = reveal_reverse[key]
	for key in modifier_ir:
		if key != "ok":
			out[key] = modifier_ir[key]
	return out


static func _compile_explicit_modifier_term_ir(nodes: Array) -> Dictionary:
	var offsets := PackedInt32Array([0])
	var stat_keys := PackedStringArray()
	var operations := PackedInt32Array()
	var values := PackedFloat64Array()
	for node_value in nodes:
		var node: Dictionary = node_value
		var terms: Array = node.get("modifier_terms", [])
		for term_value in terms:
			var term: Dictionary = term_value
			var stat_key := String(term.get("stat", "")).strip_edges()
			var operation := int(term.get("operation", -1))
			var value := float(term.get("value", NAN))
			if stat_key.is_empty() or operation < 0 or operation > 3 or not is_finite(value):
				return {"ok": false, "reason": "technology_modifier_term_invalid",
					"id": String(node.get("id", ""))}
			stat_keys.append(stat_key)
			operations.append(operation)
			values.append(value)
		offsets.append(stat_keys.size())
	return {
		"ok": true,
		"technology_modifier_term_offsets": offsets,
		"technology_modifier_term_stat_keys": stat_keys,
		"technology_modifier_term_operations": operations,
		"technology_modifier_term_values": values,
	}


static func _validate_content_effects(effects: Array, expected_bindings: Array) -> bool:
	var expected := {}
	for binding_value in expected_bindings:
		var binding: Dictionary = binding_value
		expected["%d|%s" % [int(binding.get("kind", 0)), String(binding.get("id", ""))]] = false
	for effect_value in effects:
		if not effect_value is Dictionary:
			return false
		var effect: Dictionary = effect_value
		var effect_id := String(effect.get("id", "")).strip_edges()
		if String(effect.get("kind", "")).strip_edges().is_empty() or effect_id.is_empty() \
				or String(effect.get("subject", "")).is_empty() \
				or String(effect.get("attribute", "")).is_empty() \
				or String(effect.get("operation", "")).is_empty() \
				or String(effect.get("implementation", "")).is_empty() \
				or String(effect.get("status", "")).is_empty():
			return false
		var binding_kind := int(effect.get("binding_kind", 0))
		if binding_kind > 0:
			var key := "%d|%s" % [binding_kind, effect_id]
			if not expected.has(key):
				return false
			expected[key] = true
	for key in expected:
		if not bool(expected[key]):
			return false
	return true


static func _building_has_required_technology(building_id: String) -> bool:
	return COMPOSITE_BUILDING_IDS.has(building_id)


static func _visible_content_effects(effects: Array) -> Array:
	var visible: Array = []
	for effect_value in effects:
		if not effect_value is Dictionary:
			visible.append(effect_value)
			continue
		var effect: Dictionary = effect_value
		if String(effect.get("kind", "")) == "building" \
				and _building_has_required_technology(String(effect.get("id", ""))):
			continue
		visible.append(effect.duplicate(true))
	return visible


static func _visible_effect_summary(summary: String, effects: Array) -> String:
	var composite_names := PackedStringArray()
	for effect_value in effects:
		if not effect_value is Dictionary:
			continue
		var effect: Dictionary = effect_value
		if String(effect.get("kind", "")) != "building" \
				or not _building_has_required_technology(String(effect.get("id", ""))):
			continue
		var display_name := String(effect.get("display_name", "")).strip_edges()
		if not display_name.is_empty() and not composite_names.has(display_name):
			composite_names.append(display_name)
	if composite_names.is_empty():
		return summary
	var visible_chunks := PackedStringArray()
	for raw_chunk in summary.split("；", false):
		var chunk := String(raw_chunk).strip_edges()
		var hidden := false
		for display_name in composite_names:
			if chunk == "解锁建筑：%s" % display_name \
					or chunk == "解锁建筑: %s" % display_name:
				hidden = true
				break
		if not hidden and not chunk.is_empty():
			visible_chunks.append(chunk)
	return "；".join(visible_chunks)


static func _compile_research_routes(nodes: Array, technology_ids: PackedStringArray,
		signal_ids: PackedStringArray, era_index: Dictionary) -> Dictionary:
	var technology_route_offsets := PackedInt32Array([0])
	var route_ids := PackedStringArray()
	var route_names := PackedStringArray()
	var route_types := PackedStringArray()
	var route_descriptions := PackedStringArray()
	var route_condition_offsets := PackedInt32Array([0])
	var route_ops := PackedInt32Array()
	var route_refs := PackedInt32Array()
	var route_values := PackedInt64Array()
	var total_offsets := PackedInt32Array([0])
	var total_ops := PackedInt32Array()
	var total_refs := PackedInt32Array()
	var total_values := PackedInt64Array()
	var signal_index := {}
	var technology_index := {}
	var seen_route_ids := {}
	for i in range(signal_ids.size()):
		signal_index[String(signal_ids[i])] = i
	for i in range(technology_ids.size()):
		technology_index[String(technology_ids[i])] = i
	for technology in range(nodes.size()):
		var node: Dictionary = nodes[technology]
		var technology_id := String(node.get("id", ""))
		var routes: Array = node.get("research_routes", [])
		var era := int(era_index.get(String(node.get("era_id", "")), -1))
		if era >= 2 and routes.is_empty() and String(
				node.get("route_exemption_reason", "")).strip_edges().is_empty():
			return {"ok": false, "reason": "technology_route_exemption_reason_missing",
				"technology_id": technology_id}
		var route_type_seen := {}
		for route_value in routes:
			if not route_value is Dictionary:
				return {"ok": false, "reason": "technology_research_route_invalid",
					"technology_id": technology_id}
			var route: Dictionary = route_value
			var route_id := String(route.get("id", "")).strip_edges()
			var route_name := String(route.get("display_name", "")).strip_edges()
			var route_type := String(route.get("route_type", "")).strip_edges()
			var route_description := String(route.get("description", "")).strip_edges()
			var condition: Dictionary = route.get("condition", {})
			if not route_id.begins_with("research_route.") or seen_route_ids.has(route_id) \
					or route_name.is_empty() or route_type.is_empty() \
					or route_description.is_empty() or condition.is_empty():
				return {"ok": false, "reason": "technology_research_route_invalid",
					"technology_id": technology_id, "route_id": route_id}
			seen_route_ids[route_id] = true
			route_type_seen[route_type] = true
			var route_begin := route_ops.size()
			var error := _append_condition_postfix(condition, signal_index, technology_index,
				route_ops, route_refs, route_values)
			if not error.is_empty():
				return {"ok": false, "reason": error, "technology_id": technology_id,
					"route_id": route_id}
			for cursor in range(route_begin, route_ops.size()):
				if route_ops[cursor] == CONDITION_PUSH_TECH_COMPLETED \
						and route_refs[cursor] >= technology:
					return {"ok": false,
						"reason": "technology_research_route_reference_not_earlier",
						"technology_id": technology_id, "route_id": route_id}
			route_condition_offsets.append(route_ops.size())
			route_ids.append(route_id)
			route_names.append(route_name)
			route_types.append(route_type)
			route_descriptions.append(route_description)
			error = _append_condition_postfix(condition, signal_index, technology_index,
				total_ops, total_refs, total_values)
			if not error.is_empty():
				return {"ok": false, "reason": error, "technology_id": technology_id,
					"route_id": route_id}
		if routes.size() > 1:
			total_ops.append(CONDITION_ANY_OF)
			total_refs.append(routes.size())
			total_values.append(0)
		if routes.size() > 1 and route_type_seen.size() < 2:
			return {"ok": false, "reason": "technology_research_route_types_not_distinct",
				"technology_id": technology_id}
		technology_route_offsets.append(route_ids.size())
		total_offsets.append(total_ops.size())
	return {
		"ok": true,
		"technology_research_route_offsets": technology_route_offsets,
		"research_route_ids": route_ids,
		"research_route_display_names": route_names,
		"research_route_types": route_types,
		"research_route_descriptions": route_descriptions,
		"research_route_condition_offsets": route_condition_offsets,
		"research_route_condition_ops": route_ops,
		"research_route_condition_refs": route_refs,
		"research_route_condition_values": route_values,
		"technology_research_condition_offsets": total_offsets,
		"technology_research_condition_ops": total_ops,
		"technology_research_condition_refs": total_refs,
		"technology_research_condition_values": total_values,
	}

static func _compile_condition_specs(
		technology_ids: PackedStringArray, signal_ids: PackedStringArray,
		specs: Dictionary, prefix: String) -> Dictionary:
	var offsets := PackedInt32Array([0])
	var ops := PackedInt32Array()
	var refs := PackedInt32Array()
	var values := PackedInt64Array()
	var signal_index := {}
	var technology_index := {}
	for i in range(signal_ids.size()):
		signal_index[String(signal_ids[i])] = i
	for i in range(technology_ids.size()):
		technology_index[String(technology_ids[i])] = i
	for technology_id in technology_ids:
		var spec = specs.get(String(technology_id), null)
		if spec != null:
			var error := _append_condition_postfix(spec, signal_index, technology_index,
				ops, refs, values)
			if error != "":
				return {"ok": false, "reason": error, "technology_id": String(technology_id)}
		offsets.append(ops.size())
	return {
		"ok": true,
		"%s_offsets" % prefix: offsets,
		"%s_ops" % prefix: ops,
		"%s_refs" % prefix: refs,
		"%s_values" % prefix: values,
	}

static func _compile_reveal_reverse_index(
		technology_count: int, signal_count: int, conditions: Dictionary) -> Dictionary:
	var buckets: Array[PackedInt32Array] = []
	for _signal in range(signal_count):
		buckets.append(PackedInt32Array())
	var offsets: PackedInt32Array = conditions.get(
		"technology_reveal_condition_offsets", PackedInt32Array())
	var ops: PackedInt32Array = conditions.get(
		"technology_reveal_condition_ops", PackedInt32Array())
	var refs: PackedInt32Array = conditions.get(
		"technology_reveal_condition_refs", PackedInt32Array())
	for technology in range(technology_count):
		if technology + 1 >= offsets.size():
			continue
		for cursor in range(offsets[technology], offsets[technology + 1]):
			if cursor < 0 or cursor >= ops.size() or cursor >= refs.size():
				continue
			if ops[cursor] != CONDITION_PUSH_SIGNAL_PRESENT and \
					ops[cursor] != CONDITION_PUSH_SIGNAL_COUNT:
				continue
			var signal_index_value := int(refs[cursor])
			if signal_index_value < 0 or signal_index_value >= buckets.size():
				continue
			if not buckets[signal_index_value].has(technology):
				buckets[signal_index_value].append(technology)
	var reverse_offsets := PackedInt32Array([0])
	var reverse_technologies := PackedInt32Array()
	for bucket in buckets:
		var ordered := Array(bucket)
		ordered.sort()
		for technology in ordered:
			reverse_technologies.append(int(technology))
		reverse_offsets.append(reverse_technologies.size())
	return {
		"technology_reveal_signal_offsets": reverse_offsets,
		"technology_reveal_signal_technologies": reverse_technologies,
	}

static func _append_condition_postfix(spec, signal_index: Dictionary, technology_index: Dictionary,
		ops: PackedInt32Array, refs: PackedInt32Array, values: PackedInt64Array) -> String:
	if spec is ResearchPredicateScript:
		return _append_predicate(spec, signal_index, technology_index, ops, refs, values)
	if spec is Dictionary and spec.has("kind"):
		return _append_predicate_dict(spec, signal_index, technology_index, ops, refs, values)
	var operator_value := -1
	var children: Array = []
	var required_count := 0
	if spec is ResearchConditionScript:
		operator_value = int(spec.operator)
		children = spec.children
		required_count = int(spec.required_count)
	elif spec is Dictionary:
		operator_value = int(spec.get("operator", -1))
		children = spec.get("children", [])
		required_count = int(spec.get("required_count", 0))
	else:
		return "technology_condition_invalid_node"
	if operator_value == ResearchConditionScript.Operator.ATOM:
		if spec is ResearchConditionScript:
			return _append_condition_postfix(spec.atom, signal_index, technology_index, ops, refs, values)
		return _append_condition_postfix((spec as Dictionary).get("atom", null), signal_index, technology_index, ops, refs, values)
	if children.is_empty():
		return "technology_condition_empty_composite"
	for child in children:
		var error := _append_condition_postfix(child, signal_index, technology_index, ops, refs, values)
		if error != "":
			return error
	match operator_value:
		ResearchConditionScript.Operator.ALL_OF:
			ops.append(CONDITION_ALL_OF); refs.append(children.size()); values.append(0)
		ResearchConditionScript.Operator.ANY_OF:
			ops.append(CONDITION_ANY_OF); refs.append(children.size()); values.append(0)
		ResearchConditionScript.Operator.AT_LEAST:
			if required_count <= 0 or required_count > children.size():
				return "technology_condition_at_least_invalid"
			ops.append(CONDITION_AT_LEAST); refs.append(children.size()); values.append(required_count)
		ResearchConditionScript.Operator.NOT:
			if children.size() != 1:
				return "technology_condition_not_arity_invalid"
			ops.append(CONDITION_NOT); refs.append(1); values.append(0)
		_:
			return "technology_condition_operator_unsupported"
	return ""

static func _append_predicate(predicate: Resource, signal_index: Dictionary,
		technology_index: Dictionary, ops: PackedInt32Array, refs: PackedInt32Array,
		values: PackedInt64Array) -> String:
	return _append_predicate_dict({
		"kind": int(predicate.kind), "id": String(predicate.reference_id),
		"value": int(predicate.value), "comparator": int(predicate.comparator),
	}, signal_index, technology_index, ops, refs, values)

static func _append_predicate_dict(predicate: Dictionary, signal_index: Dictionary,
		technology_index: Dictionary, ops: PackedInt32Array, refs: PackedInt32Array,
		values: PackedInt64Array) -> String:
	var kind := int(predicate.get("kind", -1))
	var id := String(predicate.get("id", predicate.get("reference_id", "")))
	var value := int(predicate.get("value", 1))
	if kind == ResearchPredicateScript.Kind.TECH_COMPLETED:
		if not technology_index.has(id):
			return "technology_condition_technology_reference_unknown"
		ops.append(CONDITION_PUSH_TECH_COMPLETED); refs.append(int(technology_index[id])); values.append(1)
		return ""
	if kind == ResearchPredicateScript.Kind.SIGNAL_PRESENT:
		if not signal_index.has(id):
			return "technology_condition_signal_reference_unknown"
		ops.append(CONDITION_PUSH_SIGNAL_PRESENT); refs.append(int(signal_index[id])); values.append(1)
		return ""
	if kind == ResearchPredicateScript.Kind.SIGNAL_COUNT:
		if not signal_index.has(id) or value <= 0:
			return "technology_condition_signal_count_invalid"
		ops.append(CONDITION_PUSH_SIGNAL_COUNT); refs.append(int(signal_index[id])); values.append(value)
		return ""
	return "technology_condition_predicate_unsupported"

static func _modifier_definition_keys(ids: PackedStringArray,
		term_offsets: PackedInt32Array) -> PackedStringArray:
	var out := PackedStringArray()
	for index in range(ids.size()):
		var has_terms := index + 1 < term_offsets.size() \
			and term_offsets[index + 1] > term_offsets[index]
		out.append("technology.%s" % String(ids[index]).trim_prefix("tech.") \
			if has_terms else "")
	return out


static func public_definitions() -> Array[Dictionary]:
	var compiled := compile_native_catalog()
	if not bool(compiled.get("ok", false)):
		return []
	var network := _network_payload()
	if not bool(network.get("ok", false)):
		return []
	var source_by_id := {}
	for source_value in network.get("nodes", []):
		var source: Dictionary = source_value
		source_by_id[String(source.get("id", ""))] = source
	var out: Array[Dictionary] = []
	var ids: PackedStringArray = compiled.technology_ids
	for i in range(ids.size()):
		var technology_id := String(ids[i])
		var source: Dictionary = source_by_id.get(technology_id, {})
		var prerequisites_out := PackedStringArray()
		for edge in range(compiled.technology_prerequisite_offsets[i], compiled.technology_prerequisite_offsets[i + 1]):
			prerequisites_out.append(ids[compiled.technology_prerequisites[edge]])
		var candidates_out := PackedStringArray()
		for edge in range(compiled.technology_milestone_offsets[i], compiled.technology_milestone_offsets[i + 1]):
			candidates_out.append(ids[compiled.technology_milestone_candidates[edge]])
		var public_route_tags: PackedStringArray = compiled.technology_route_tags.slice(
			compiled.technology_route_tag_offsets[i],
			compiled.technology_route_tag_offsets[i + 1])
		var starter_capabilities: PackedStringArray = \
			compiled.technology_starter_capability_tags.slice(
				compiled.technology_starter_capability_offsets[i],
				compiled.technology_starter_capability_offsets[i + 1])
		out.append({
			"id": ids[i],
			"display_name": String(compiled.technology_display_names[i]),
			"era_id": compiled.technology_era_ids[i],
			"domain_id": DOMAIN_IDS[compiled.technology_domain_indices[i]],
			"cost_points": int(compiled.technology_costs[i]) / 1000,
			"prerequisite_ids": prerequisites_out,
			"hard_prerequisite_ids": prerequisites_out,
			"prerequisite_rationales": PackedStringArray(
				source.get("prerequisite_rationales", [])),
			"era_entry_milestone_id": String(source.get("era_entry_milestone_id", "")),
			"milestone_candidate_ids": candidates_out,
			"milestone_required_count": compiled.technology_milestone_required_counts[i],
			"is_milestone": (int(compiled.technology_flags[i]) & 2) != 0,
			"is_era_key": (int(compiled.technology_flags[i]) & 1) != 0,
			"is_starting": (int(compiled.technology_flags[i]) & 4) != 0,
			"is_starter_eligible": (compiled.starter_eligible_technology_ids as PackedStringArray).has(technology_id),
			"effect_summary": String(compiled.technology_effect_summaries[i]),
			"effect_profile": compiled.technology_effect_profile_ids[i],
			"node_role": String(compiled.technology_node_roles[i]),
			"network_role": String(compiled.technology_network_roles[i]),
			"anchor_kind": String(compiled.technology_anchor_kinds[i]),
			"primary_route_tag": String(compiled.technology_primary_route_tags[i]),
			"layout_lane": String(compiled.technology_layout_lanes[i]),
			"branch_family_id": String(compiled.technology_layout_lanes[i]),
			"starter_capability_tags": starter_capabilities,
			"route_tags": public_route_tags,
			"route_display_names": _localized_route_names(public_route_tags),
			"research_routes": (source.get("research_routes", []) as Array).duplicate(true),
			"route_exemption_reason": String(source.get("route_exemption_reason", "")),
			"reveal_condition": (source.get("reveal_condition", {}) as Dictionary).duplicate(true),
			"reveal_category": String(source.get("reveal_category", "")),
			"reveal_summary": String(source.get("reveal_summary", "")),
			"modifier_terms": (source.get("modifier_terms", []) as Array).duplicate(true),
			"expected_bindings": (source.get("expected_bindings", []) as Array).duplicate(true),
			"content_effects": _visible_content_effects(
				source.get("content_effects", []) as Array),
			"opportunity_cost": String(source.get("opportunity_cost", "")),
			"branch_successor_ids": PackedStringArray(source.get("branch_successor_ids", [])),
			"branch_successor_rationales": PackedStringArray(
				source.get("branch_successor_rationales", [])),
			"application_target_ids": PackedStringArray(source.get("application_target_ids", [])),
			"application_target_rationales": PackedStringArray(
				source.get("application_target_rationales", [])),
			"terminal_reason": String(source.get("terminal_reason", "")),
		})
	return out


static func public_visual_edges() -> Array[Dictionary]:
	var network := _network_payload()
	if not bool(network.get("ok", false)):
		return []
	var out: Array[Dictionary] = []
	for edge_value in network.get("visual_edges", []):
		out.append((edge_value as Dictionary).duplicate(true))
	return out


static func public_lane_metadata() -> Array[Dictionary]:
	var network := _network_payload()
	if not bool(network.get("ok", false)):
		return []
	var out: Array[Dictionary] = []
	for lane_value in (network.get("backbones", []) as Array) + (network.get("branch_families", []) as Array):
		out.append((lane_value as Dictionary).duplicate(true))
	return out


static func route_display_name(route_tag: String) -> String:
	var parts := route_tag.split(".", false)
	if parts.size() != 3 or parts[0] != "route":
		return route_tag
	var category := String(ROUTE_CATEGORY_NAMES_ZH.get(parts[1], parts[1]))
	var value := String(ROUTE_VALUE_NAMES_ZH.get(parts[2], parts[2]))
	return "%s · %s" % [category, value]


static func _localized_route_names(route_tags: PackedStringArray) -> PackedStringArray:
	var out := PackedStringArray()
	for route_tag in route_tags:
		out.append(route_display_name(String(route_tag)))
	return out

# Era and domain presentation metadata is authored here so no reader has to
# rediscover display names from raw ids.
static func public_era_metadata() -> Array[Dictionary]:
	var network := _network_payload()
	if not bool(network.get("ok", false)):
		return []
	var out: Array[Dictionary] = []
	var rows: Array = network.get("eras", [])
	for index in range(rows.size()):
		var row: Dictionary = rows[index]
		out.append({
			"id": String(row.get("id", "")),
			"display_name": String(row.get("display_name", "")),
			"milestone_id": String(row.get("milestone_id", "")),
			"entry_milestone_id": String(row.get("entry_milestone_id", "")),
			"milestone_candidate_ids": PackedStringArray(row.get("milestone_candidate_ids", [])),
			"candidate_required": int(row.get("candidate_required", 4)),
			"sort_order": index,
		})
	return out

static func public_domain_metadata() -> Array[Dictionary]:
	var network := _network_payload()
	if not bool(network.get("ok", false)):
		return []
	var out: Array[Dictionary] = []
	var rows: Array = network.get("domains", [])
	for index in range(rows.size()):
		var row: Dictionary = rows[index]
		var accent := Color.from_string(String(row.get("accent", "#ffffff")), Color.WHITE)
		out.append({
			"id": String(row.get("id", "")),
			"display_name": String(row.get("display_name", "")),
			"accent": accent,
			"sort_order": index,
		})
	return out


static func signal_named_by_completed_technologies(
		signal_id: String, completed_ids: PackedStringArray,
		compiled: Dictionary = Dictionary()) -> bool:
	if compiled.is_empty() or not bool(compiled.get("ok", false)):
		compiled = compile_native_catalog()
	if not bool(compiled.get("ok", false)) or signal_id.is_empty():
		return false
	var signal_ids: PackedStringArray = compiled.get(
		"research_signal_ids", PackedStringArray())
	var signal_index := signal_ids.find(signal_id)
	if signal_index < 0:
		return false
	var completed := {}
	for technology_id in completed_ids:
		completed[String(technology_id)] = true
	if completed.is_empty():
		return false
	var offsets: PackedInt32Array = compiled.get(
		"technology_reveal_signal_offsets", PackedInt32Array())
	var technologies: PackedInt32Array = compiled.get(
		"technology_reveal_signal_technologies", PackedInt32Array())
	var technology_ids: PackedStringArray = compiled.get(
		"technology_ids", PackedStringArray())
	if signal_index + 1 >= offsets.size():
		return false
	for edge in range(int(offsets[signal_index]), int(offsets[signal_index + 1])):
		if edge < 0 or edge >= technologies.size():
			continue
		var technology_index := int(technologies[edge])
		if technology_index < 0 or technology_index >= technology_ids.size():
			continue
		if completed.has(String(technology_ids[technology_index])):
			return true
	return false
