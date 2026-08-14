extends SceneTree

const NETWORK_PATH := "res://data/technology/technology_network.json"
const EXPECTED_NODES := 361
const EXPECTED_ERAS := 11
const EXPECTED_DOMAINS := 4
const CANDIDATES_PER_ERA := 8
const CANDIDATES_REQUIRED := 4
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
	for era_value in eras:
		var era: Dictionary = era_value
		var era_id := String(era.get("id", ""))
		assert(not era_id.is_empty() and not era_index.has(era_id))
		era_index[era_id] = era_index.size()
		var candidates: Array = era.get("milestone_candidate_ids", [])
		assert(candidates.size() == CANDIDATES_PER_ERA)
		assert(int(era.get("candidate_required", 0)) == CANDIDATES_REQUIRED)
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
	for node_value in nodes:
		var node: Dictionary = node_value
		var id := String(node.id)
		var era := int(era_index[String(node.era_id)])
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
		if era >= 2:
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
				assert(int(node_index[String(route_tech)]) < int(node_index[id]),
					"%s points to future technology" % route_id)
				assert(not hard.has(String(route_tech)), "%s duplicates core knowledge" % route_id)
			var intersection := _intersection(reveal_signals, route_signals)
			assert(intersection.is_empty(), "%s reuses its reveal signal" % route_id)
		if routes.size() > 1:
			assert(route_types.size() >= 2, "%s route types are not distinct" % id)

		var requires_distinct_routes := era >= 2 and ((
			candidate_ids.has(id) and not bool(node.get("is_milestone", false))) or
			["production_system", "power_scale", "institution"].has(
				String(node.get("node_role", ""))))
		if requires_distinct_routes:
			assert(routes.size() >= 2 and routes.size() <= 3, "%s needs 2-3 routes" % id)

	var coverage := float(routes_after_kingdom) / float(maxi(1, nodes_after_kingdom))
	assert(coverage >= 0.80, "kingdom+ route coverage %.3f" % coverage)

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
		assert(kind in ["hard", "alternative", "application", "milestone_candidate"])
		if kind != "alternative":
			assert(not edge.has("route_id"))
			continue
		alternative_edges += 1
		var route_id := String(edge.get("route_id", ""))
		assert(route_by_id.has(route_id))
		assert(String(route_target_by_id[route_id]) == String(edge.get("to", "")))
	assert(alternative_edges > 0)

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
