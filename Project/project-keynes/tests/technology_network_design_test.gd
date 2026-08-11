extends SceneTree

const TechnologyCatalogScript = preload("res://scripts/economy/technology_catalog.gd")
const ResearchConditionScript = preload("res://scripts/research/research_condition.gd")
const ResearchPredicateScript = preload("res://scripts/research/research_predicate.gd")
const EconomyCatalogScript = preload("res://scripts/economy/economy_catalog.gd")

const NETWORK_PATH := "res://data/technology/technology_network.json"
const ERA_NON_MILESTONE_QUOTAS := [74, 58, 29, 27, 24, 25, 24, 23, 23, 22, 20]
const BROAD_PREFIXES := ["country.output.agriculture_factor",
	"country.output.extractive_factor", "country.output.manufacturing_factor",
	"country.output.energy_factor", "country.output.knowledge_factor",
	"country.research.", "country.trade."]
const SIGNAL_MINIMUM_ERA := {
	"breakthrough.printing": 3,
	"breakthrough.print_calibration": 3,
	"breakthrough.industrial_organization": 6,
	"breakthrough.steam_power": 6,
	"breakthrough.steam_sealing": 6,
	"breakthrough.assembly_line": 6,
	"breakthrough.chemical_process_control": 6,
	"breakthrough.electrification": 7,
	"breakthrough.motor_winding": 7,
	"breakthrough.automation": 8,
	"resource.rare_earth": 8,
	"breakthrough.climate_modeling": 9,
	"breakthrough.digital_control": 9,
	"breakthrough.energy_control": 9,
}

const REGIONAL_DISCOVERY_REQUIREMENTS := {
	"tech.hunting": ["resource.wild_game", "landform.grassland", "landform.forest"],
	"tech.gathering": ["resource.fertile_soil", "landform.forest", "landform.grassland"],
	"tech.stone_knapping": ["resource.flint", "resource.stone", "landform.mountain"],
	"tech.fire_control": ["resource.timber", "weather.drought", "landform.grassland"],
	"tech.freshwater_fishing": ["resource.freshwater_fish", "resource.freshwater", "landform.river_valley"],
	"tech.coastal_fishing": ["resource.marine_fish", "landform.coast", "landform.coastal_estuary"],
	"tech.earth_building": ["resource.clay", "landform.arid_basin", "landform.loess_plain"],
	"tech.wild_tuber_collection": ["bio.potato", "landform.high_plateau", "landform.mountain"],
	"tech.wild_flax_collection": ["bio.flax", "landform.grassland", "landform.forest"],
	"tech.gold_panning": ["resource.gold_ore", "resource.freshwater", "landform.river_valley"],
	"tech.surface_silver_collection": ["resource.silver_ore", "landform.mountain", "landform.high_plateau"],
	"tech.deadwood_collection": ["resource.timber", "landform.forest", "landform.conifer_forest"],
	"tech.reed_identification": ["bio.reed", "landform.marsh", "resource.freshwater"],
	"tech.reed_harvesting": ["bio.reed", "landform.marsh", "resource.freshwater"],
	"tech.turf_cutting": ["resource.pasture", "landform.tundra", "landform.high_plateau"],
	"tech.hide_scraping": ["resource.wild_game", "landform.grassland", "landform.forest"],
	"tech.fur_sewing": ["resource.wild_game", "landform.tundra", "landform.conifer_forest"],
	"tech.felt_making": ["bio.sheep", "resource.pasture", "landform.grassland"],
	"tech.oral_memory_practice": ["weather.repeated_crop_failure", "weather.major_flood", "weather.drought"],
	"tech.phenology_observation": ["weather.frost", "weather.monsoon", "weather.drought"],
	"tech.flood_calendar_practice": ["landform.floodplain", "landform.river_valley", "weather.major_flood"],
	"tech.pastoral_route_memory": ["resource.pasture", "landform.grassland", "landform.steppe_plain"],
	"tech.tide_observation": ["landform.coast", "landform.coastal_estuary", "weather.storm_surge"],
	"tech.swidden_maize_cultivation": ["bio.maize", "landform.forest", "weather.drought"],
	"tech.rainfed_maize_cultivation": ["bio.maize", "resource.arable_land", "weather.drought"],
	"tech.flood_recession_maize": ["bio.maize", "landform.floodplain", "weather.major_flood"],
	"tech.rainfed_wheat_cultivation": ["bio.wheat", "landform.loess_plain", "weather.drought"],
	"tech.flood_recession_wheat": ["bio.wheat", "landform.floodplain", "weather.major_flood"],
	"tech.dryland_wheat_cultivation": ["bio.wheat", "landform.arid_basin", "weather.drought"],
	"tech.upland_rice_propagation": ["bio.rice", "landform.high_plateau", "weather.drought"],
	"tech.wetland_rice_gardening": ["bio.rice", "landform.marsh", "resource.paddy_land"],
	"tech.rice_water_control": ["resource.paddy_land", "landform.river_valley", "breakthrough.paddy_control"],
	"tech.dryland_farming": ["resource.arable_land", "landform.arid_basin", "weather.drought"],
	"tech.terrace_farming": ["landform.mountain", "landform.high_plateau", "breakthrough.terrace_maintenance"],
	"tech.rainfed_field_system": ["resource.arable_land", "weather.drought", "breakthrough.rainfed_adaptation"],
	"tech.paddy_bunding": ["resource.paddy_land", "landform.floodplain", "breakthrough.paddy_control"],
	"tech.dryland_water_retention": ["resource.arable_land", "weather.drought", "breakthrough.rainfed_adaptation"],
	"tech.highland_tuber_farming": ["bio.potato", "landform.high_plateau", "landform.mountain"],
	"tech.river_transport": ["landform.river_valley", "resource.freshwater", "weather.major_flood"],
	"tech.tenant_paddy_management": ["resource.paddy_land", "landform.floodplain", "breakthrough.paddy_control"],
	"tech.estate_paddy_management": ["resource.paddy_land", "landform.floodplain", "breakthrough.paddy_control"],
	"tech.wind_power": ["landform.stable_wind_corridor", "weather.monsoon", "weather.typhoon"],
}


func _init() -> void:
	var file := FileAccess.open(NETWORK_PATH, FileAccess.READ)
	assert(file != null)
	var payload = JSON.parse_string(file.get_as_text())
	file.close()
	assert(payload is Dictionary)
	var data: Dictionary = payload
	var nodes: Array = data.nodes
	var edges: Array = data.visual_edges
	var eras: Array = data.eras
	var branches: Array = data.specialist_lanes
	var backbones: Array = data.backbones
	assert(nodes.size() == 360)
	assert(eras.size() == 11 and branches.size() == 16 and backbones.size() == 4)
	assert(edges.size() <= 1500)

	var node_by_id := {}
	var lane_by_id := {}
	var era_index := {}
	for i in range(eras.size()):
		era_index[String((eras[i] as Dictionary).id)] = i
	for node_value in nodes:
		var node: Dictionary = node_value
		assert(not node_by_id.has(String(node.id)))
		node_by_id[String(node.id)] = node
		lane_by_id[String(node.id)] = String(node.main_lane)

	var branch_ids := PackedStringArray()
	for lane in branches:
		branch_ids.append(String((lane as Dictionary).id))
	var backbone_ids := PackedStringArray()
	for lane in backbones:
		backbone_ids.append(String((lane as Dictionary).id))

	var route_anchor_by_key := {}
	var backbone_anchor_by_key := {}
	for era_slot in range(eras.size()):
		var era_id := String((eras[era_slot] as Dictionary).id)
		var era_nodes: Array = nodes.filter(func(node: Dictionary) -> bool:
			return String(node.era_id) == era_id)
		assert(era_nodes.size() == ERA_NON_MILESTONE_QUOTAS[era_slot] + 1)
		assert(era_nodes.filter(func(node: Dictionary) -> bool:
			return bool(node.is_milestone)).size() == 1)
		var route_anchors: Array = era_nodes.filter(func(node: Dictionary) -> bool:
			return String(node.anchor_kind) == "route_anchor")
		var backbone_anchors: Array = era_nodes.filter(func(node: Dictionary) -> bool:
			return String(node.anchor_kind) == "backbone_anchor")
		assert(route_anchors.size() == 16)
		assert(backbone_anchors.size() == 4)
		var milestone: Dictionary = era_nodes.filter(func(node: Dictionary) -> bool:
			return bool(node.is_milestone))[0]
		var milestone_cost := float(milestone.cost_points)
		var route_costs: Array[float] = []
		for node in route_anchors:
			route_costs.append(float((node as Dictionary).cost_points))
		route_costs.sort()
		var route_median := route_costs[route_costs.size() / 2]
		for node in route_anchors:
			var cost := float((node as Dictionary).cost_points)
			assert(cost >= milestone_cost * 0.60 and cost <= milestone_cost * 0.75)
			assert(absf(cost - route_median) <= route_median * 0.10)
		for node in backbone_anchors:
			var cost := float((node as Dictionary).cost_points)
			assert(cost >= milestone_cost * 0.55 and cost <= milestone_cost * 0.70)
		for node in era_nodes:
			if bool((node as Dictionary).is_starter_eligible) \
					or String((node as Dictionary).anchor_kind) != "support":
				continue
			var cost := float((node as Dictionary).cost_points)
			assert(cost >= milestone_cost * 0.70 and cost <= milestone_cost * 0.85)
		for node in era_nodes:
			assert(float((node as Dictionary).cost_points) <= milestone_cost)
		for node in route_anchors:
			var key := "%s|%s" % [era_id, String(node.main_lane)]
			assert(branch_ids.has(String(node.main_lane)) and not route_anchor_by_key.has(key))
			route_anchor_by_key[key] = String(node.id)
		for node in backbone_anchors:
			var key := "%s|%s" % [era_id, String(node.main_lane)]
			assert(backbone_ids.has(String(node.main_lane)) and not backbone_anchor_by_key.has(key))
			backbone_anchor_by_key[key] = String(node.id)
	assert(route_anchor_by_key.size() == 176)
	assert(backbone_anchor_by_key.size() == 44)

	var hard_count := 0
	var hard_cross_lane := 0
	var edge_kind_counts := {"hard": 0, "alternative": 0, "application": 0,
		"milestone_candidate": 0}
	var application_by_lane := {}
	var cross_application_by_lane := {}
	var feedback_by_lane := {}
	for edge_value in edges:
		var edge: Dictionary = edge_value
		assert(edge_kind_counts.has(String(edge.kind)))
		assert(node_by_id.has(String(edge.from)) and node_by_id.has(String(edge.to)))
		edge_kind_counts[String(edge.kind)] += 1
		if String(edge.kind) == "hard":
			hard_count += 1
			if String(lane_by_id[edge.from]) != String(lane_by_id[edge.to]) \
					and not bool((node_by_id[String(edge.from)] as Dictionary).is_milestone):
				hard_cross_lane += 1
		elif String(edge.kind) == "application":
			var source_lane := String(lane_by_id[edge.from])
			var target_lane := String(lane_by_id[edge.to])
			if branch_ids.has(source_lane):
				application_by_lane[source_lane] = int(application_by_lane.get(source_lane, 0)) + 1
				if branch_ids.has(target_lane) and target_lane != source_lane:
					cross_application_by_lane[source_lane] = int(cross_application_by_lane.get(source_lane, 0)) + 1
				if backbone_ids.has(target_lane):
					feedback_by_lane[source_lane] = int(feedback_by_lane.get(source_lane, 0)) + 1
	assert(hard_count <= 500)
	assert(float(hard_count) / float(nodes.size()) <= 1.40)
	assert(hard_cross_lane <= int(ceil(float(hard_count) * 0.10)))
	assert(int(edge_kind_counts.milestone_candidate) == 176)
	for lane in branch_ids:
		assert(int(application_by_lane.get(lane, 0)) >= 6)
		assert(int(cross_application_by_lane.get(lane, 0)) >= 4)
		assert(int(feedback_by_lane.get(lane, 0)) >= 2)

	var modifier_count := 0
	var nonstarting_count := 0
	var broad_node_count := 0
	var family_totals := {}
	var building_totals := {}
	var broad_totals := {}
	var content_kind_counts := {}
	for node_value in nodes:
		var node: Dictionary = node_value
		var hard: Array = node.hard_prerequisite_ids
		assert(hard.size() <= 2)
		var hard_set := {}
		for prerequisite_id in hard:
			assert(node_by_id.has(String(prerequisite_id)))
			assert(int((node_by_id[String(prerequisite_id)] as Dictionary).layout_order) < int(node.layout_order))
			hard_set[String(prerequisite_id)] = true
		var alternatives := PackedStringArray()
		_collect_technology_atoms(node.research_condition, alternatives)
		assert((node.research_condition as Dictionary).is_empty(),
			"research eligibility must be determined only by hard prerequisites: %s" % node.id)
		for alternative_id in alternatives:
			assert(not hard_set.has(String(alternative_id)))
		var reveal_signals := PackedStringArray()
		_collect_signal_atoms(node.reveal_condition, reveal_signals)
		if not bool(node.is_milestone):
			assert(not reveal_signals.is_empty(), "missing discovery inspiration: %s" % node.id)
		for signal_id in reveal_signals:
			if SIGNAL_MINIMUM_ERA.has(String(signal_id)):
				assert(int(era_index[String(node.era_id)]) >= int(
					SIGNAL_MINIMUM_ERA[String(signal_id)]),
					"anachronistic discovery signal %s -> %s" % [signal_id, node.id])
		var terms: Array = node.modifier_terms
		for effect_value in node.get("content_effects", []):
			var effect: Dictionary = effect_value
			var kind := String(effect.get("kind", ""))
			content_kind_counts[kind] = int(content_kind_counts.get(kind, 0)) + 1
		modifier_count += terms.size()
		if not bool(node.is_starter_eligible):
			nonstarting_count += 1
			assert(terms.size() >= 1 and terms.size() <= 3)
			var has_targeted := false
			var has_broad := false
			for term_value in terms:
				var term: Dictionary = term_value
				var stat := String(term.stat)
				if stat.begins_with("country.output.family."):
					has_targeted = true
					family_totals[stat] = float(family_totals.get(stat, 0.0)) + float(term.value)
				if stat.begins_with("country.output.building."):
					has_targeted = true
					building_totals[stat] = float(building_totals.get(stat, 0.0)) + float(term.value)
				if _is_broad(stat):
					has_broad = true
					broad_totals[stat] = float(broad_totals.get(stat, 0.0)) + float(term.value)
			assert(has_targeted)
			if has_broad:
				broad_node_count += 1
	assert(modifier_count >= 360 and modifier_count <= 480)
	assert(broad_node_count <= int(floor(float(nonstarting_count) * 0.20)))
	for stat in family_totals:
		assert(float(family_totals[stat]) <= 1.250001)
	for stat in building_totals:
		assert(float(building_totals[stat]) <= 1.250001)
	for stat in broad_totals:
		assert(float(broad_totals[stat]) <= 0.500001)
	for kind in ["building", "good", "class", "resource", "tile", "terrain",
			"landform", "climate"]:
		assert(int(content_kind_counts.get(kind, 0)) > 0,
			"missing structured technology effect kind: %s" % kind)

	_assert_signals(node_by_id, "tech.cotton_identification",
		["bio.cotton", "contact.cotton", "resource.plantation_land"],
		["bio.spice", "bio.rubber"])
	_assert_signals(node_by_id, "tech.kiln_firing",
		["resource.clay", "resource.silica_sand", "breakthrough.kiln_temperature"],
		["breakthrough.electrification", "resource.rare_earth"])
	for technology_id in REGIONAL_DISCOVERY_REQUIREMENTS:
		_assert_signals(node_by_id, String(technology_id),
			REGIONAL_DISCOVERY_REQUIREMENTS[technology_id], [])
	_assert_no_binding_token(node_by_id, "tech.kiln_firing", ["tin"])
	_assert_no_modifier_token(node_by_id, "tech.cotton_identification", ["chemical"])
	for technology_id in ["tech.digital_computing", "tech.networked_computing",
			"tech.software_engineering", "tech.information_theory",
			"tech.machine_learning", "tech.neural_networks"]:
		_assert_no_modifier_token(node_by_id, technology_id,
			["garment", "fertilizer", "fish", "glass", "clay"])
	var smart_grid_terms: Array = (node_by_id["tech.smart_grid"] as Dictionary).modifier_terms
	assert(smart_grid_terms.any(func(term: Dictionary) -> bool:
		var stat := String(term.stat)
		return stat.contains("batteries") or stat.contains("energy")))

	var anchor_with_inspiration := 0
	for era_slot in range(eras.size()):
		var era_id := String((eras[era_slot] as Dictionary).id)
		for lane in branch_ids:
			var anchor: Dictionary = node_by_id[route_anchor_by_key["%s|%s" % [era_id, lane]]]
			if _contains_operator(anchor.reveal_condition,
					[ResearchConditionScript.Operator.ANY_OF, ResearchConditionScript.Operator.AT_LEAST]):
				anchor_with_inspiration += 1
			if era_slot > 0:
				var previous_era: Dictionary = eras[era_slot - 1]
				var hard: PackedStringArray = anchor.hard_prerequisite_ids
				assert(hard.has(String(previous_era.milestone_id)))
				assert(hard.has(route_anchor_by_key["%s|%s" % [previous_era.id, lane]]))
			if era_slot == eras.size() - 1:
				assert(not String(anchor.terminal_reason).is_empty())
	assert(anchor_with_inspiration == 176)
	for era_slot in range(1, eras.size()):
		var era_id := String((eras[era_slot] as Dictionary).id)
		var previous_era: Dictionary = eras[era_slot - 1]
		for lane in backbone_ids:
			var anchor: Dictionary = node_by_id[backbone_anchor_by_key[
				"%s|%s" % [era_id, lane]]]
			assert((anchor.hard_prerequisite_ids as PackedStringArray).has(
				String(previous_era.milestone_id)))
	assert(int(edge_kind_counts.alternative) == 0)

	var compiled := TechnologyCatalogScript.compile_native_catalog()
	assert(bool(compiled.get("ok", false)))
	assert((compiled.technology_ids as PackedStringArray).size() == 360)
	assert((compiled.technology_prerequisites as PackedInt32Array).size() == hard_count)
	var economy := EconomyCatalogScript.compile_native_catalog()
	assert(bool(economy.get("ok", false)))
	print("[PASS] network technology design: nodes=%d hard=%d visual=%d modifiers=%d broad_nodes=%d" % [
		nodes.size(), hard_count, edges.size(), modifier_count, broad_node_count])
	quit(0)


func _collect_technology_atoms(spec: Dictionary, out: PackedStringArray) -> void:
	if spec.is_empty():
		return
	if spec.has("kind"):
		if int(spec.kind) == ResearchPredicateScript.Kind.TECH_COMPLETED:
			var id := String(spec.get("id", ""))
			if not out.has(id):
				out.append(id)
		return
	for child in spec.get("children", []):
		if child is Dictionary:
			_collect_technology_atoms(child, out)


func _collect_signal_atoms(spec: Dictionary, out: PackedStringArray) -> void:
	if spec.is_empty():
		return
	if spec.has("kind"):
		if int(spec.kind) in [ResearchPredicateScript.Kind.SIGNAL_PRESENT,
				ResearchPredicateScript.Kind.SIGNAL_COUNT]:
			var id := String(spec.get("id", ""))
			if not out.has(id):
				out.append(id)
		return
	for child in spec.get("children", []):
		if child is Dictionary:
			_collect_signal_atoms(child, out)


func _contains_operator(spec: Dictionary, operators: Array) -> bool:
	if spec.is_empty() or spec.has("kind"):
		return false
	if int(spec.get("operator", -1)) in operators:
		return true
	for child in spec.get("children", []):
		if child is Dictionary and _contains_operator(child, operators):
			return true
	return false


func _contains_signal(spec: Dictionary) -> bool:
	if spec.is_empty():
		return false
	if spec.has("kind"):
		return int(spec.kind) in [ResearchPredicateScript.Kind.SIGNAL_PRESENT,
			ResearchPredicateScript.Kind.SIGNAL_COUNT]
	for child in spec.get("children", []):
		if child is Dictionary and _contains_signal(child):
			return true
	return false


func _assert_signals(node_by_id: Dictionary, technology_id: String,
		required: Array, forbidden: Array) -> void:
	assert(node_by_id.has(technology_id))
	var signals := PackedStringArray()
	_collect_signal_atoms((node_by_id[technology_id] as Dictionary).reveal_condition,
		signals)
	for signal_id in required:
		assert(signals.has(String(signal_id)), "%s missing signal %s" % [
			technology_id, signal_id])
	for signal_id in forbidden:
		assert(not signals.has(String(signal_id)), "%s has unrelated signal %s" % [
			technology_id, signal_id])


func _assert_no_binding_token(node_by_id: Dictionary, technology_id: String,
		forbidden_tokens: Array) -> void:
	for binding_value in (node_by_id[technology_id] as Dictionary).expected_bindings:
		var binding_id := String((binding_value as Dictionary).id)
		for token in forbidden_tokens:
			assert(not binding_id.contains(String(token)),
				"%s has unrelated binding %s" % [technology_id, binding_id])


func _assert_no_modifier_token(node_by_id: Dictionary, technology_id: String,
		forbidden_tokens: Array) -> void:
	for term_value in (node_by_id[technology_id] as Dictionary).modifier_terms:
		var stat := String((term_value as Dictionary).stat)
		for token in forbidden_tokens:
			assert(not stat.contains(String(token)),
				"%s has unrelated modifier %s" % [technology_id, stat])


func _is_broad(stat: String) -> bool:
	for prefix in BROAD_PREFIXES:
		if stat == prefix or stat.begins_with(prefix):
			return true
	return false
