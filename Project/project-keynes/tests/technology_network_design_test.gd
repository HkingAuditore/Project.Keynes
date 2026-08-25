extends SceneTree

const NETWORK_PATH := "res://data/technology/technology_network.json"
const EXPECTED_NODES := 661
const EXPECTED_ERAS := 11
const EXPECTED_DOMAINS := 4
const CANDIDATES_PER_ERA := [8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18]
const CANDIDATES_REQUIRED := [4, 4, 4, 4, 5, 5, 5, 6, 6, 7, 7]
const ResearchPredicateScript = preload("res://scripts/research/research_predicate.gd")


func _init() -> void:
	var file := FileAccess.open(NETWORK_PATH, FileAccess.READ)
	assert(file != null)
	var parsed: Variant = JSON.parse_string(file.get_as_text())
	assert(parsed is Dictionary)
	var data: Dictionary = parsed
	assert(int(data.get("schema_version", 0)) == 3)
	var eras: Array = data.get("eras", [])
	var nodes: Array = data.get("nodes", [])
	assert(eras.size() == EXPECTED_ERAS)
	assert((data.get("domains", []) as Array).size() == EXPECTED_DOMAINS)
	assert(nodes.size() == EXPECTED_NODES)
	assert(not data.has("specialist_lanes"))

	var era_index := {}
	var milestone_ids := {}
	var candidate_ids := {}
	for era_position in range(eras.size()):
		var era_value = eras[era_position]
		var era: Dictionary = era_value
		var era_id := String(era.get("id", ""))
		assert(not era_id.is_empty() and not era_index.has(era_id))
		era_index[era_id] = era_index.size()
		var candidates: Array = era.get("milestone_candidate_ids", [])
		assert(candidates.size() == int(CANDIDATES_PER_ERA[era_position]))
		assert(int(era.get("candidate_required", 0)) ==
			int(CANDIDATES_REQUIRED[era_position]))
		var unique_candidates := {}
		for candidate_value in candidates:
			var candidate_id := String(candidate_value)
			assert(not unique_candidates.has(candidate_id))
			unique_candidates[candidate_id] = true
			candidate_ids[candidate_id] = true
		var milestone_id := String(era.get("milestone_id", ""))
		assert(not milestone_id.is_empty() and not milestone_ids.has(milestone_id))
		milestone_ids[milestone_id] = true

	var node_by_id := {}
	var node_index := {}
	for node_value in nodes:
		var node: Dictionary = node_value
		var id := String(node.get("id", ""))
		assert(id.begins_with("tech.") and not node_by_id.has(id))
		node_by_id[id] = node
		node_index[id] = node_index.size()
	for milestone_id in milestone_ids:
		assert(node_by_id.has(milestone_id), milestone_id)
	for candidate_id in candidate_ids:
		assert(node_by_id.has(candidate_id), candidate_id)

	var route_by_id := {}
	var route_target_by_id := {}
	var reveal_templates := {}
	var routes_after_kingdom := 0
	var nodes_after_kingdom := 0
	var alternative_edges := 0
	var branch_edges := 0
	var era_building_counts := {}
	var era_building_ids := {}
	for node_value in nodes:
		var node: Dictionary = node_value
		var id := String(node.id)
		var era := int(era_index[String(node.era_id)])
		var building_unlocks := 0
		for binding_value in node.get("expected_bindings", []):
			var binding: Dictionary = binding_value
			if int(binding.get("kind", 0)) == 2:
				building_unlocks += 1
				var building_ids: Array = era_building_ids.get(String(node.era_id), [])
				building_ids.append(String(binding.get("id", "")))
				era_building_ids[String(node.era_id)] = building_ids
		era_building_counts[String(node.era_id)] = int(era_building_counts.get(
			String(node.era_id), 0)) + building_unlocks
		assert(node.has("hard_prerequisite_ids"))
		assert(node.hard_prerequisite_ids is Array)
		assert(node.hard_prerequisite_ids.size() == node.prerequisite_rationales.size())
		assert(not node.has("research_condition"), "%s retains legacy authoring" % id)
		var reveal: Dictionary = node.get("reveal_condition", {})
		assert(reveal is Dictionary)
		_validate_condition(reveal)
		var reveal_signals := PackedStringArray()
		_collect_atoms(reveal, PackedStringArray(), reveal_signals)
		var reveal_key := JSON.stringify(reveal)
		if not reveal.is_empty():
			if reveal_templates.has(reveal_key):
				assert(not String(node.get("reveal_template_reason", "")).strip_edges().is_empty(), id)
			reveal_templates[reveal_key] = int(reveal_templates.get(reveal_key, 0)) + 1

		var hard: Array = node.hard_prerequisite_ids
		for prerequisite_value in hard:
			var prerequisite_id := String(prerequisite_value)
			assert(node_by_id.has(prerequisite_id))
			assert(int(node_index[prerequisite_id]) < int(node_index[id]))
			assert(not milestone_ids.has(prerequisite_id), "%s has node-level milestone edge" % id)

		var routes: Array = node.get("research_routes", [])
		assert(routes is Array)
		var is_application := String(node.get("anchor_kind", "")) == "application" \
			or (String(node.get("node_role", "")) == "applied_method" \
			and building_unlocks > 0)
		var knowledge_basis: Dictionary = node.get("knowledge_basis", {})
		assert(not knowledge_basis.is_empty(), "%s missing knowledge basis" % id)
		var knowledge_required: Array = knowledge_basis.get("required_ids", [])
		var knowledge_alternatives: Array = knowledge_basis.get("alternative_groups", [])
		var knowledge_exemption := String(knowledge_basis.get(
			"exemption_reason", "")).strip_edges()
		assert(knowledge_exemption.is_empty() or (knowledge_required.is_empty() \
			and knowledge_alternatives.is_empty()), "%s mixes knowledge exemption and basis" % id)
		assert(not (knowledge_required.is_empty() and knowledge_alternatives.is_empty() \
			and knowledge_exemption.is_empty()), "%s has empty knowledge basis" % id)
		var hard_history := {}
		for prerequisite_value in hard:
			_collect_ancestors(String(prerequisite_value), node_by_id, hard_history)
		for required_value in knowledge_required:
			assert(hard_history.has(String(required_value)),
				"%s knowledge basis is not a hard ancestor: %s" % [id, required_value])
		var route_knowledge := PackedStringArray()
		for route_value in routes:
			_collect_atoms((route_value as Dictionary).get("condition", {}),
				route_knowledge, PackedStringArray())
		for group_value in knowledge_alternatives:
			assert(group_value is Array and not (group_value as Array).is_empty(), id)
			for alternative_value in group_value as Array:
				assert(route_knowledge.has(String(alternative_value)),
					"%s alternative knowledge is not visible: %s" % [id, alternative_value])
		if is_application:
			assert(knowledge_required.size() >= 2,
				"application lacks two knowledge foundations: %s" % id)
			assert(building_unlocks == 1,
				"application must unlock exactly one building: %s" % id)
		if era >= 2 and not is_application:
			nodes_after_kingdom += 1
			if not routes.is_empty():
				routes_after_kingdom += 1
			else:
				assert(not String(node.get("route_exemption_reason", "")).strip_edges().is_empty(), id)
		var route_types := {}
		for route_value in routes:
			var route: Dictionary = route_value
			var route_id := String(route.get("id", ""))
			assert(route_id.begins_with("research_route."))
			assert(not route_by_id.has(route_id))
			assert(not String(route.get("display_name", "")).strip_edges().is_empty())
			assert(not String(route.get("route_type", "")).strip_edges().is_empty())
			assert(not String(route.get("description", "")).strip_edges().is_empty())
			var condition: Dictionary = route.get("condition", {})
			_validate_condition(condition)
			route_by_id[route_id] = route
			route_target_by_id[route_id] = id
			route_types[String(route.route_type)] = true
			var route_techs := PackedStringArray()
			var route_signals := PackedStringArray()
			_collect_atoms(condition, route_techs, route_signals)
			assert(not route_techs.has(id), "%s self-references" % route_id)
			for route_tech in route_techs:
				assert(node_by_id.has(String(route_tech)))
				var route_tech_node: Dictionary = node_by_id[String(route_tech)]
				assert(int(era_index[String(route_tech_node.era_id)]) <= era,
					"%s points to a later-era technology" % route_id)
				assert(not hard.has(String(route_tech)), "%s duplicates core knowledge" % route_id)
			var intersection := _intersection(reveal_signals, route_signals)
			if id not in ["tech.coastal_fishing", "tech.freshwater_fishing"]:
				assert(intersection.is_empty(), "%s reuses its reveal signal" % route_id)
		if routes.size() > 1:
			assert(route_types.size() >= 2, "%s route types are not distinct" % id)

		var requires_distinct_routes := era >= 2 and not is_application and ((
			candidate_ids.has(id) and not bool(node.get("is_milestone", false))) or
			["production_system", "power_scale", "institution"].has(
				String(node.get("node_role", ""))))
		if requires_distinct_routes:
			assert(routes.size() <= 3, "%s has too many research routes" % id)
			if routes.is_empty():
				assert(not String(node.get("route_exemption_reason", "")).strip_edges().is_empty(),
					"%s needs routes or a visible hard-foundation exemption" % id)

	var coverage := float(routes_after_kingdom) / float(maxi(1, nodes_after_kingdom))
	assert(coverage >= 0.80, "kingdom+ route coverage %.3f" % coverage)
	var pre_empire_buildings := 0
	var empire_and_later_buildings := 0
	for era_value in eras:
		var era_id := String((era_value as Dictionary).id)
		var actual_count := int(era_building_counts.get(era_id, 0))
		assert(actual_count >= 12 and actual_count <= 64,
			"%s has implausible building unlock load %d" % [era_id, actual_count])
		if int(era_index[era_id]) < int(era_index["empire"]):
			pre_empire_buildings += actual_count
		else:
			empire_and_later_buildings += actual_count
	assert(empire_and_later_buildings > pre_empire_buildings,
		"later eras must retain the majority of production unlocks")
	var stone_buildings: Array = era_building_ids.get("stone", [])
	stone_buildings.sort()
	for gathering_building in ["wild_wheat_stand", "wild_maize_stand",
			"wild_rice_marsh", "wild_tuber_patch", "reed_cutting_camp",
			"turf_cutting_ground", "earth_digging_pit"]:
		assert(stone_buildings.has(gathering_building), gathering_building)
	var agrarian_buildings: Array = era_building_ids.get("agrarian", [])
	for farming_building in ["rainfed_wheat_plot", "rainfed_maize_field",
			"upland_rice_plot", "wetland_rice_garden", "maize_garden",
			"highland_tuber_plot", "cotton_garden", "flax_collector",
			"spice_shade_garden", "pastoral_camp", "creamery"]:
		assert(agrarian_buildings.has(farming_building), farming_building)
	for collapsed_id in ["tech.method.wild_wheat_stand",
			"tech.method.reed_cutting_camp", "tech.method.turf_cutting_ground",
			"tech.method.earth_digging_pit", "tech.method.wild_maize_stand",
			"tech.method.rainfed_wheat_plot", "tech.method.rubble_stone_working",
			"tech.method.household_weaving_shelter", "tech.method.lumber_plant",
			"tech.method.wild_rice_marsh"]:
		assert(not node_by_id.has(collapsed_id), collapsed_id)
	assert(not node_by_id.has("tech.application.knapping_workshop"))
	var stone_knapping: Dictionary = node_by_id["tech.stone_knapping"]
	assert(_has_expected_building(stone_knapping, "flint_quarry"))
	assert(_has_expected_building(stone_knapping, "knapping_workshop"))
	var composite_tools: Dictionary = node_by_id["tech.composite_tools"]
	assert(composite_tools.hard_prerequisite_ids == ["tech.stone_knapping"])
	assert((composite_tools.knowledge_basis as Dictionary).required_ids == [
		"tech.stone_knapping"])
	assert((node_by_id["tech.controlled_burning"] as Dictionary).hard_prerequisite_ids == [
		"tech.fire_control"])
	var wild_flax: Dictionary = node_by_id["tech.wild_flax_collection"]
	assert(_has_expected_building(wild_flax, "bast_fiber_camp"))
	assert(not _has_expected_building(wild_flax, "bast_wrap_shelter"))
	var fiber_twisting: Dictionary = node_by_id["tech.fiber_twisting"]
	assert(_has_expected_building(fiber_twisting, "bast_wrap_shelter"))
	assert((fiber_twisting.hard_prerequisite_ids as Array).has(
		"tech.wild_flax_collection"))
	var ground_stone: Dictionary = node_by_id["tech.ground_stone_tools"]
	assert(_has_expected_building(ground_stone, "stone_collector"))

	# A reveal must introduce a new national problem, not repeat a signal already
	# implied by the target's irreducible knowledge history.
	for node_value in nodes:
		var node: Dictionary = node_value
		var id := String(node.id)
		var core_history := {}
		for prerequisite_value in node.hard_prerequisite_ids:
			_collect_ancestors(String(prerequisite_value), node_by_id, core_history)
		var implied_signals := PackedStringArray()
		for ancestor_id in core_history:
			_collect_atoms((node_by_id[ancestor_id] as Dictionary).get("reveal_condition", {}),
				PackedStringArray(), implied_signals)
		var own_signals := PackedStringArray()
		_collect_atoms(node.get("reveal_condition", {}), PackedStringArray(), own_signals)
		# Agrarian branches intentionally retain object/practice observations as
		# short-horizon evidence; from Kingdom onward a core history may not
		# already entail the national problem being revealed.
		if int(era_index[String(node.era_id)]) >= 2:
			assert(_intersection(own_signals, implied_signals).is_empty(),
				"reveal implied by core history: %s" % id)
		for route_value in node.get("research_routes", []):
			var route: Dictionary = route_value
			var route_techs := PackedStringArray()
			var route_signals := PackedStringArray()
			_collect_atoms(route.condition, route_techs, route_signals)
			var independent := false
			for route_tech in route_techs:
				if not core_history.has(String(route_tech)):
					independent = true
			for route_signal in route_signals:
				if not implied_signals.has(String(route_signal)):
					independent = true
			assert(independent, "route implied by core history: %s" % route.id)

	# Alternative edges are explainable and carry the route identity used by UI.
	for edge_value in data.get("visual_edges", []):
		var edge: Dictionary = edge_value
		var kind := String(edge.get("kind", ""))
		assert(kind in ["hard", "alternative", "application", "branch", "milestone_candidate"])
		if kind != "alternative":
			assert(not edge.has("route_id"))
			if kind == "branch":
				var branch_source: Dictionary = node_by_id[String(edge.get("from", ""))]
				assert((branch_source.get("branch_successor_ids", []) as Array).has(
					String(edge.get("to", ""))))
				branch_edges += 1
			continue
		alternative_edges += 1
		var route_id := String(edge.get("route_id", ""))
		assert(route_by_id.has(route_id))
		assert(String(route_target_by_id[route_id]) == String(edge.get("to", "")))
	assert(alternative_edges > 0)
	var visual_hard_edges := {}
	for edge_value in data.get("visual_edges", []):
		var edge: Dictionary = edge_value
		if String(edge.get("kind", "")) != "hard":
			continue
		var edge_key := "%s>%s" % [String(edge.get("from", "")), String(edge.get("to", ""))]
		visual_hard_edges[edge_key] = true
	for node_value in nodes:
		var node: Dictionary = node_value
		for prerequisite_value in node.get("hard_prerequisite_ids", []):
			var hard_key := "%s>%s" % [String(prerequisite_value), String(node.id)]
			assert(visual_hard_edges.has(hard_key),
				"missing visual hard edge: %s" % hard_key)
	var authored_branch_edges := 0
	for node_value in nodes:
		authored_branch_edges += (node_value as Dictionary).get(
			"branch_successor_ids", []).size()
	assert(branch_edges == authored_branch_edges)

	# Object-specific first handling is revealed only after identification.
	# Seeing the object must not make gathering/processing independently researchable.
	var identification_first := {
		"tech.stone_knapping": "tech.flint_identification",
		"tech.earth_building": "tech.clay_identification",
		"tech.wild_tuber_collection": "tech.potato_identification",
		"tech.wild_flax_collection": "tech.flax_identification",
		"tech.reed_harvesting": "tech.reed_identification",
		"tech.gold_panning": "tech.gold_placer_identification",
		"tech.wild_maize_collection": "tech.maize_identification",
		"tech.surface_silver_collection": "tech.silver_vein_identification",
	}
	var early_prerequisites := {
		"tech.composite_tools": "tech.stone_knapping",
		"tech.timber_sawing": "tech.composite_tools",
		"tech.natural_copper_working": "tech.natural_copper_identification",
		"tech.bronze_casting": "tech.tin_identification",
		"tech.herd_management": "tech.animal_husbandry",
		"tech.adobe_making": "tech.earth_building",
		"tech.copper_metallurgy": "tech.copper_ore_roasting",
		"tech.woodblock_printing": "tech.composite_tools",
		"tech.movable_type_printing": "tech.pottery",
		"tech.surface_coal_collection": "tech.ground_stone_tools",
		"tech.crop_domestication": "tech.natural_observation",
		"tech.fiber_twisting": "tech.natural_observation",
		"tech.food_storage": "tech.seasonal_foraging",
		"tech.charcoal_burning": "tech.fire_control",
		"tech.fur_sewing": "tech.animal_husbandry",
		"tech.felt_making": "tech.animal_husbandry",
	}
	for technology_id in early_prerequisites:
		assert(String(early_prerequisites[technology_id]) in
			(node_by_id[technology_id].hard_prerequisite_ids as Array), technology_id)
	for technology_id in ["tech.copper_metallurgy", "tech.woodblock_printing",
			"tech.movable_type_printing"]:
		assert((node_by_id[technology_id].hard_prerequisite_ids as Array).size() >= 2,
			technology_id)
	for copper_id in ["tech.natural_copper_identification",
			"tech.natural_copper_working", "tech.copper_annealing",
			"tech.tin_identification", "tech.copper_ore_roasting",
			"tech.copper_mining_application", "tech.copper_metallurgy"]:
		assert(String((node_by_id[copper_id] as Dictionary).era_id) != "stone",
			"copper chain leaked into the stone era: %s" % copper_id)
	var copper_mining: Dictionary = node_by_id["tech.copper_mining_application"]
	assert(String(copper_mining.get("anchor_kind", "")) == "application")
	assert("tech.natural_copper_identification" in copper_mining.hard_prerequisite_ids)
	assert("tech.stone_knapping" in copper_mining.hard_prerequisite_ids)
	assert(_has_expected_building(copper_mining, "copper_ore_collector"))
	var copper_metallurgy: Dictionary = node_by_id["tech.copper_metallurgy"]
	for prerequisite_id in ["tech.copper_ore_roasting", "tech.charcoal_burning",
			"tech.pottery"]:
		assert(prerequisite_id in copper_metallurgy.hard_prerequisite_ids)
	assert(_has_expected_building(copper_metallurgy, "early_copper_smelter"))
	for application_id in ["tech.application.early_tin_mine",
			"tech.application.ore_bronzesmith_camp",
			"tech.application.early_copper_mine"]:
		assert(String((node_by_id[application_id] as Dictionary).get(
			"anchor_kind", "")) == "application", application_id)
	var crop_reveal := JSON.stringify(node_by_id["tech.crop_domestication"].reveal_condition)
	for crop_signal in ["bio.maize", "bio.wheat", "bio.rice", "bio.potato"]:
		assert(crop_reveal.contains(crop_signal), crop_signal)
	for handling_id in identification_first:
		var handling: Dictionary = node_by_id[String(handling_id)]
		var identification_id := String(identification_first[handling_id])
		assert(identification_id in handling.hard_prerequisite_ids, handling_id)
		assert((handling.get("reveal_condition", {}) as Dictionary).is_empty(), handling_id)
		assert(int(node_index[identification_id]) < int(node_index[String(handling_id)]),
			handling_id)

	var knowledge_ids := PackedStringArray([
		"tech.oral_memory_practice", "tech.phenology_observation",
		"tech.flood_calendar_practice", "tech.pastoral_route_memory",
		"tech.tide_observation",
	])
	for knowledge_id in knowledge_ids:
		var knowledge: Dictionary = node_by_id[String(knowledge_id)]
		assert(not bool(knowledge.get("is_starter_eligible", false)), knowledge_id)
		assert((knowledge.get("hard_prerequisite_ids", []) as Array) == [
			"tech.early_knowledge_institution"], knowledge_id)
		assert((knowledge.get("reveal_condition", {}) as Dictionary).is_empty(), knowledge_id)
	var unified_knowledge: Dictionary = node_by_id["tech.early_knowledge_institution"]
	assert(not bool(unified_knowledge.get("is_starter_eligible", false)))
	for prerequisite_id in ["tech.gathering", "tech.deadwood_collection"]:
		assert(prerequisite_id in (unified_knowledge.get(
			"hard_prerequisite_ids", []) as Array), prerequisite_id)
	assert((unified_knowledge.get("research_routes", []) as Array).size() == 5)

	# Stone-era institution routes enter through the unified institution. The
	# five regional knowledge nodes remain visible downstream branches.
	var expected_opening_knowledge := PackedStringArray([
		"tech.early_knowledge_institution",
	])
	var opening_route_count := 0
	for node_value in nodes:
		var node: Dictionary = node_value
		if String(node.get("era_id", "")) != "stone":
			continue
		for route_value in node.get("research_routes", []):
			var route: Dictionary = route_value
			if not String(route.get("id", "")).ends_with(".knowledge_institution"):
				continue
			opening_route_count += 1
			var route_techs := PackedStringArray()
			_collect_atoms(route.condition, route_techs, PackedStringArray())
			assert(route_techs == expected_opening_knowledge,
				"stone route must use the unified knowledge institution: %s" % node.id)
	assert(opening_route_count > 0)

	for plant_id in ["tech.maize_identification", "tech.wheat_identification",
			"tech.rice_identification", "tech.potato_identification",
			"tech.cotton_identification", "tech.flax_identification"]:
		assert("tech.natural_observation" in
			(node_by_id[plant_id].hard_prerequisite_ids as Array), plant_id)
	for origin_id in ["tech.flint_identification", "tech.fire_control",
			"tech.seasonal_foraging", "tech.animal_husbandry",
			"tech.hide_scraping", "tech.turf_cutting"]:
		var origin: Dictionary = node_by_id[String(origin_id)]
		var origin_routes: Array = origin.get("research_routes", [])
		assert(origin_routes.size() == 1, origin_id)
		assert(String((origin_routes[0] as Dictionary).get("id", "")).ends_with(
			".knowledge_institution"), origin_id)
	for fishing_id in ["tech.coastal_fishing", "tech.freshwater_fishing"]:
		var fishing: Dictionary = node_by_id[fishing_id]
		var fishing_hard: Array = fishing.hard_prerequisite_ids
		assert(fishing_hard.has("tech.early_knowledge_institution"), fishing_id)
		assert(fishing_hard.has("tech.wild_flax_collection"), fishing_id)
		var fishing_routes: Array = fishing.get("research_routes", [])
		assert(fishing_routes.size() == 1, fishing_id)
		assert(String((fishing_routes[0] as Dictionary).route_type) == "geography",
			fishing_id)
	var deadwood: Dictionary = node_by_id["tech.deadwood_collection"]
	assert(bool(deadwood.get("is_starter_eligible", false)))
	assert((deadwood.get("research_routes", []) as Array).is_empty())

	# Locked regression sample: plantation estate management has a genuine
	# development reveal and three strategically different research routes.
	var plantation: Dictionary = node_by_id["tech.estate_plantation_management"]
	assert(plantation.hard_prerequisite_ids == ["tech.commodity_crop_management"])
	var plantation_reveal := JSON.stringify(plantation.reveal_condition)
	assert(plantation_reveal.contains("development.commodity_crop_variety_2"))
	assert(plantation_reveal.contains("development.commodity_crop_facilities_4_180d"))
	assert(not plantation_reveal.contains("bio.cotton") and not plantation_reveal.contains("bio.spice"))
	assert(plantation.research_routes.size() == 3)
	var plantation_route_types := {}
	for route_value in plantation.research_routes:
		var route: Dictionary = route_value
		plantation_route_types[String(route.route_type)] = true
		assert(not JSON.stringify(route.condition).contains("bio.cotton"))
		assert(not JSON.stringify(route.condition).contains("bio.spice"))
	assert(plantation_route_types.size() == 3)
	assert(JSON.stringify(plantation.research_routes).contains("tech.commercial_tenancy"))
	assert(JSON.stringify(plantation.research_routes).contains("tech.estate_accounting"))
	assert(JSON.stringify(plantation.research_routes).contains("tech.chartered_companies"))
	assert(JSON.stringify(plantation.research_routes).contains("development.commodity_crop_trade_value_100000"))
	assert(JSON.stringify(plantation.research_routes).contains("tech.crop_acclimatization"))
	assert(JSON.stringify(plantation.research_routes).contains("tech.indentured_contracts"))
	assert(JSON.stringify(plantation.research_routes).contains("development.agricultural_employment_100_360d"))

	print("[PASS] technology network schema v3: %d nodes / %.1f%% kingdom+ route coverage / %d routes" % [
		nodes.size(), coverage * 100.0, route_by_id.size()])
	quit(0)


func _validate_condition(value: Variant) -> void:
	assert(value is Dictionary)
	var condition: Dictionary = value
	if condition.is_empty():
		return
	if condition.has("kind"):
		var kind := int(condition.get("kind", -1))
		assert(kind in [ResearchPredicateScript.Kind.TECH_COMPLETED,
			ResearchPredicateScript.Kind.SIGNAL_PRESENT,
			ResearchPredicateScript.Kind.SIGNAL_COUNT])
		assert(not String(condition.get("id", "")).is_empty())
		return
	var children: Array = condition.get("children", [])
	assert(not children.is_empty())
	assert(int(condition.get("operator", -1)) in [1, 2, 3, 4])
	for child in children:
		_validate_condition(child)


func _collect_atoms(value: Variant, techs: PackedStringArray,
		signals: PackedStringArray) -> void:
	if not value is Dictionary:
		return
	var condition: Dictionary = value
	if condition.has("kind"):
		if int(condition.kind) == ResearchPredicateScript.Kind.TECH_COMPLETED:
			techs.append(String(condition.id))
		else:
			signals.append(String(condition.id))
		return
	for child in condition.get("children", []):
		_collect_atoms(child, techs, signals)


func _collect_ancestors(id: String, node_by_id: Dictionary, out: Dictionary) -> void:
	if out.has(id):
		return
	out[id] = true
	if not node_by_id.has(id):
		return
	for prerequisite in (node_by_id[id] as Dictionary).hard_prerequisite_ids:
		_collect_ancestors(String(prerequisite), node_by_id, out)


func _intersection(left: PackedStringArray, right: PackedStringArray) -> PackedStringArray:
	var right_set := {}
	for item in right:
		right_set[String(item)] = true
	var out := PackedStringArray()
	for item in left:
		if right_set.has(String(item)):
			out.append(String(item))
	return out


func _has_expected_building(node: Dictionary, building_id: String) -> bool:
	for binding_value in node.get("expected_bindings", []):
		var binding: Dictionary = binding_value
		if int(binding.get("kind", 0)) == 2 and \
				String(binding.get("id", "")) == building_id:
			return true
	return false
