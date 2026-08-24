extends SceneTree

const TechnologyCatalogScript = preload("res://scripts/economy/technology_catalog.gd")

func _init() -> void:
	var catalog: Dictionary = TechnologyCatalogScript.compile_native_catalog()
	assert(bool(catalog.get("ok", false)), str(catalog))
	const EXPECTED_TECHNOLOGY_COUNT := 361
	const EXPECTED_STARTER_COUNT := 7
	assert((catalog.technology_ids as PackedStringArray).size() == EXPECTED_TECHNOLOGY_COUNT)
	assert((catalog.starting_technology_ids as PackedStringArray).is_empty())
	assert((catalog.starter_eligible_technology_ids as PackedStringArray).size() == EXPECTED_STARTER_COUNT)
	assert((catalog.starter_eligible_technology_ids as PackedStringArray).has("tech.early_trade"))
	for starter_id in ["tech.gathering", "tech.hunting", "tech.early_trade",
			"tech.gold_panning", "tech.surface_silver_collection",
			"tech.hide_scraping", "tech.deadwood_collection"]:
		assert((catalog.starter_eligible_technology_ids as PackedStringArray).has(starter_id),
			starter_id)
	for leftover_id in ["tech.stone_knapping",
			"tech.freshwater_fishing", "tech.wild_flax_collection",
			"tech.oral_memory_practice", "tech.turf_cutting"]:
		var leftover_index := (catalog.technology_ids as PackedStringArray).find(leftover_id)
		assert(leftover_index >= 0)
		assert(not (catalog.starter_eligible_technology_ids as PackedStringArray).has(leftover_id))
		assert(int(catalog.technology_costs[leftover_index]) > 0)
		assert(not String(catalog.technology_effect_recipe_ids[leftover_index]).is_empty())
	assert((catalog.technology_era_ids_ordered as PackedStringArray).size() == 11)
	assert((catalog.technology_domain_ids as PackedStringArray).size() == 4)
	assert((catalog.technology_effect_profile_ids as PackedStringArray).size() == EXPECTED_TECHNOLOGY_COUNT)
	assert((catalog.technology_effect_recipe_ids as PackedStringArray).size() == EXPECTED_TECHNOLOGY_COUNT)
	assert((catalog.technology_effect_recipe_versions as PackedInt32Array).size() == EXPECTED_TECHNOLOGY_COUNT)
	assert((catalog.technology_route_tag_offsets as PackedInt32Array).size() == EXPECTED_TECHNOLOGY_COUNT + 1)
	assert((catalog.technology_research_route_offsets as PackedInt32Array).size() == EXPECTED_TECHNOLOGY_COUNT + 1)
	assert((catalog.research_route_ids as PackedStringArray).has(
		"research_route.flint_identification.knowledge_institution"))
	assert((catalog.research_route_ids as PackedStringArray).size() > 680)
	var gathering_index := (catalog.technology_ids as PackedStringArray).find("tech.gathering")
	var oral_index := (catalog.technology_ids as PackedStringArray).find(
		"tech.oral_memory_practice")
	var flint_index := (catalog.technology_ids as PackedStringArray).find(
		"tech.flint_identification")
	assert(gathering_index >= 0 and oral_index == gathering_index + 1)
	assert(flint_index > oral_index)
	assert(int(catalog.technology_costs[oral_index]) > 0)
	assert((catalog.research_route_ids as PackedStringArray).size() ==
		(catalog.research_route_display_names as PackedStringArray).size())
	assert((catalog.research_route_ids as PackedStringArray).size() ==
		(catalog.research_route_types as PackedStringArray).size())
	assert((catalog.research_route_ids as PackedStringArray).size() ==
		(catalog.research_route_descriptions as PackedStringArray).size())
	assert((catalog.research_route_condition_offsets as PackedInt32Array).size() ==
		(catalog.research_route_ids as PackedStringArray).size() + 1)
	assert((catalog.technology_research_condition_offsets as PackedInt32Array).size() == EXPECTED_TECHNOLOGY_COUNT + 1)
	assert((catalog.technology_reveal_condition_offsets as PackedInt32Array).size() == EXPECTED_TECHNOLOGY_COUNT + 1)
	assert((catalog.technology_modifier_term_offsets as PackedInt32Array).size() == EXPECTED_TECHNOLOGY_COUNT + 1)
	assert((catalog.technology_node_roles as PackedStringArray).size() == EXPECTED_TECHNOLOGY_COUNT)
	assert((catalog.technology_primary_route_tags as PackedStringArray).size() == EXPECTED_TECHNOLOGY_COUNT)
	assert((catalog.technology_layout_lanes as PackedStringArray).size() == EXPECTED_TECHNOLOGY_COUNT)
	assert((catalog.technology_starter_capability_offsets as PackedInt32Array).size() == EXPECTED_TECHNOLOGY_COUNT + 1)
	assert((catalog.technology_entry_milestone_indices as PackedInt32Array).size() == EXPECTED_TECHNOLOGY_COUNT)
	var writing_index := (catalog.technology_ids as PackedStringArray).find("tech.writing")
	var agrarian_milestone_index := (catalog.technology_ids as PackedStringArray).find(
		"tech.agrarian_society")
	assert(writing_index >= 0 and agrarian_milestone_index >= 0)
	assert(int((catalog.technology_entry_milestone_indices as PackedInt32Array)[writing_index])
		== agrarian_milestone_index)
	assert((catalog.technology_era_entry_milestone_indices as PackedInt32Array).size() == 11)
	var definitions: Array = TechnologyCatalogScript.public_definitions()
	assert(definitions.size() == EXPECTED_TECHNOLOGY_COUNT)
	assert(String(catalog.technology_display_names[0]) == "狩猎")
	assert(String((definitions[0] as Dictionary).display_name) == "狩猎")
	var hunting_summary := String((definitions[0] as Dictionary).effect_summary)
	assert(hunting_summary.begins_with(
		"解锁物资：野味；解锁物资：生皮；解锁建筑：狩猎营地；可利用资源：野生动物"))
	assert(hunting_summary.contains("作为必要支撑"))
	for era in TechnologyCatalogScript.public_era_metadata():
		assert(int((era as Dictionary).candidate_required) == 4)
		assert(((era as Dictionary).milestone_candidate_ids as PackedStringArray).size() == 12)
	var researchable := 0
	var milestones := 0
	var recipe_ids := {}
	var modifier_stats: PackedStringArray = catalog.technology_modifier_term_stat_keys
	for i in range(catalog.technology_ids.size()):
		var public_definition: Dictionary = definitions[i]
		assert(String(public_definition.display_name) \
			== String(catalog.technology_display_names[i]))
		assert(String(public_definition.effect_summary) \
			== String(catalog.technology_effect_summaries[i]))
		assert(not String(public_definition.display_name).is_empty())
		assert(not String(public_definition.display_name).begins_with("tech."))
		var public_route_tags: PackedStringArray = public_definition.route_tags
		var public_route_names: PackedStringArray = public_definition.route_display_names
		assert(public_route_names.size() == public_route_tags.size())
		for route_index in range(public_route_tags.size()):
			var route_parts := String(public_route_tags[route_index]).split(".", false)
			assert(route_parts.size() == 3)
			assert(TechnologyCatalogScript.ROUTE_CATEGORY_NAMES_ZH.has(route_parts[1]))
			assert(TechnologyCatalogScript.ROUTE_VALUE_NAMES_ZH.has(route_parts[2]))
			assert(String(public_route_names[route_index]) \
				!= String(public_route_tags[route_index]))
			assert(not String(public_route_names[route_index]).contains("route."))
		if int(catalog.technology_costs[i]) > 0:
			researchable += 1
		assert(not String(catalog.technology_effect_profile_ids[i]).is_empty())
		assert(String(public_definition.node_role) in ["identification", "handling",
			"production_system", "power_scale", "institution", "applied_method", "milestone"])
		assert(not String(public_definition.layout_lane).is_empty())
		var is_starting := (int(catalog.technology_flags[i]) \
			& TechnologyCatalogScript.FLAG_STARTING) != 0
		var recipe_id := String(catalog.technology_effect_recipe_ids[i])
		if is_starting:
			assert(recipe_id.is_empty())
			assert(int(catalog.technology_effect_recipe_versions[i]) == 0)
			assert(int(catalog.technology_modifier_term_offsets[i + 1]) \
				== int(catalog.technology_modifier_term_offsets[i]))
		else:
			assert(not recipe_id.is_empty() and not recipe_ids.has(recipe_id))
			recipe_ids[recipe_id] = true
			assert(int(catalog.technology_effect_recipe_versions[i]) == 1)
		assert(int(catalog.technology_route_tag_offsets[i + 1])
			- int(catalog.technology_route_tag_offsets[i]) >= 1)
		if (int(catalog.technology_flags[i]) & 2) != 0:
			milestones += 1
			assert(int(catalog.technology_milestone_required_counts[i]) == 4)
			assert(int(catalog.technology_milestone_offsets[i + 1]) - int(catalog.technology_milestone_offsets[i]) == 12)
	assert(researchable == EXPECTED_TECHNOLOGY_COUNT - EXPECTED_STARTER_COUNT)
	assert(milestones == 11)
	assert(recipe_ids.size() == EXPECTED_TECHNOLOGY_COUNT - EXPECTED_STARTER_COUNT)
	for retired_crop_bundle in ["tech.maize_cultivation", "tech.wheat_cultivation",
			"tech.rice_cultivation", "tech.potato_cultivation",
			"tech.cotton_cultivation", "tech.flax_cultivation"]:
		assert((catalog.technology_ids as PackedStringArray).find(retired_crop_bundle) < 0,
			retired_crop_bundle)
	var maximum_hard_prerequisites := 0
	for i in range(EXPECTED_TECHNOLOGY_COUNT):
		maximum_hard_prerequisites = maxi(maximum_hard_prerequisites,
			int(catalog.technology_prerequisite_offsets[i + 1])
			- int(catalog.technology_prerequisite_offsets[i]))
	assert(maximum_hard_prerequisites >= 2 and maximum_hard_prerequisites <= 3)
	assert(modifier_stats.size() > 0)
	assert((catalog.technology_network_roles as PackedStringArray).size() \
		== EXPECTED_TECHNOLOGY_COUNT)
	assert((catalog.technology_anchor_kinds as PackedStringArray).size() \
		== EXPECTED_TECHNOLOGY_COUNT)
	var visual_edges: Array = catalog.technology_visual_edges
	assert(visual_edges.size() <= 1800)
	var visual_kind_counts := {"hard": 0, "alternative": 0, "application": 0, "branch": 0,
		"milestone_candidate": 0}
	for edge in visual_edges:
		var kind := String((edge as Dictionary).get("kind", ""))
		assert(visual_kind_counts.has(kind))
		visual_kind_counts[kind] += 1
		if kind == "alternative":
			assert(not String((edge as Dictionary).get("route_id", "")).is_empty())
	assert(int(visual_kind_counts.milestone_candidate) == 132)
	assert(int(visual_kind_counts.alternative) > 0)
	var authored_branch_edges := 0
	for definition_value in definitions:
		authored_branch_edges += (definition_value as Dictionary).get(
			"branch_successor_ids", PackedStringArray()).size()
	assert(int(visual_kind_counts.branch) == authored_branch_edges)
	for formal_id in ["tech.atmospheric_engine", "tech.geographic_information_systems"]:
		var formal_index := (catalog.technology_ids as PackedStringArray).find(formal_id)
		assert(formal_index >= 0)
		var formal_term_count := int(catalog.technology_modifier_term_offsets[formal_index + 1]) \
			- int(catalog.technology_modifier_term_offsets[formal_index])
		assert(formal_term_count >= 1 and formal_term_count <= 6)
	var signals: PackedStringArray = catalog.research_signal_ids
	assert(signals.has("development.population.100_90d"))
	assert(signals.has("development.commodity_crop_facilities_4_180d"))
	for resource_id in ["timber", "stone", "fertile_soil", "arable_land", "paddy_land",
			"plantation_land", "pasture", "coal", "oil", "natural_gas", "copper_ore",
			"iron_ore", "gold_ore", "silver_ore", "salt", "saltpeter", "rare_earth",
			"clay", "wild_game", "marine_fish", "bauxite", "limestone", "silica_sand",
			"phosphate_rock", "tin_ore", "lead_ore", "zinc_ore", "manganese_ore",
			"sulfur", "flint", "freshwater_fish"]:
		assert(signals.has("resource.%s" % resource_id), resource_id)
	for signal_id in ["bio.maize", "bio.wheat", "bio.rice", "bio.potato", "bio.horse",
			"bio.cotton", "bio.flax", "bio.spice", "bio.rubber",
			"breakthrough.maize_selection", "breakthrough.dryland_adaptation",
			"breakthrough.hydraulic_engineering", "breakthrough.metalworking",
			"breakthrough.printing", "breakthrough.steam_power",
			"breakthrough.electrification", "breakthrough.industrial_organization",
			"breakthrough.automation", "breakthrough.climate_modeling"]:
		assert(signals.has(signal_id), signal_id)
	print("[PASS] authoritative technology catalog: %d definitions / %d researchable" % [
		EXPECTED_TECHNOLOGY_COUNT, EXPECTED_TECHNOLOGY_COUNT - EXPECTED_STARTER_COUNT])
	quit(0)


func _assert_prerequisite(catalog: Dictionary, technology_id: String,
		prerequisite_id: String) -> void:
	var ids: PackedStringArray = catalog.technology_ids
	var technology_index := ids.find(technology_id)
	var prerequisite_index := ids.find(prerequisite_id)
	assert(technology_index >= 0 and prerequisite_index >= 0)
	var offsets: PackedInt32Array = catalog.technology_prerequisite_offsets
	var prerequisites: PackedInt32Array = catalog.technology_prerequisites
	var found := false
	for edge in range(offsets[technology_index], offsets[technology_index + 1]):
		found = found or int(prerequisites[edge]) == prerequisite_index
	assert(found, "%s requires %s" % [technology_id, prerequisite_id])


func _assert_modifier_at_least(catalog: Dictionary, technology_id: String,
		stat_key: String, minimum: float) -> void:
	var technology_index := (catalog.technology_ids as PackedStringArray).find(technology_id)
	assert(technology_index >= 0)
	var offsets: PackedInt32Array = catalog.technology_modifier_term_offsets
	var stats: PackedStringArray = catalog.technology_modifier_term_stat_keys
	var values: PackedFloat64Array = catalog.technology_modifier_term_values
	var found := false
	for edge in range(offsets[technology_index], offsets[technology_index + 1]):
		if String(stats[edge]) == stat_key and float(values[edge]) >= minimum:
			found = true
			break
	assert(found, "%s missing strong %s modifier" % [technology_id, stat_key])
