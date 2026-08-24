extends SceneTree

const EconomyCatalogScript = preload("res://scripts/economy/economy_catalog.gd")
const TechnologyCatalogScript = preload("res://scripts/economy/technology_catalog.gd")
const ResourceRegistryScript = preload("res://scripts/data/resource_profile_registry.gd")
const NETWORK_PATH := "res://data/technology/technology_network.json"

const STEAM_BUILDING_ALLOWLIST := {
	"steam_engine_works": true,
	"steam_rail_works": true,
	"steam_steel_works": true,
	"method_steam_engine_works_r9": true,
}
const MECHANIZED_AGRICULTURE_BUILDING_ALLOWLIST := {
	"agricultural_machinery_plant": true,
	"mechanized_farm": true,
	"method_cotton_collector_r6": true,
	"method_landed_estate_r6": true,
	"method_potato_collector_r6": true,
	"method_rubber_tree_collector_r6": true,
	"method_spice_plants_collector_r6": true,

	"ranching_station": true,
}
const CRITICAL_DIRECT_CONSUMERS := [
	"tech.atmospheric_engine",
	"tech.steam_power",
	"tech.steam_pumping",
	"tech.synthetic_fertilizer",
	"tech.internal_combustion",
	"tech.electric_grid",
	"tech.rail_logistics",
	"tech.cold_chain",
	"tech.public_education",
	"tech.modern_medicine",
	"tech.nuclear_energy",
	"tech.software_engineering",
	"tech.precision_agriculture",
	"tech.automated_agriculture",
	"tech.digital_control",
	"tech.robotic_manufacturing",
	"tech.autonomous_mining",
	"tech.smart_grid",
	"tech.steam_sealing",
	"tech.automated_logistics",
	"tech.autonomous_logistics",
	"tech.neural_networks",
	"tech.water_power",
	"tech.hydrological_remote_sensing",
	"tech.algorithmic_governance",
	"tech.satellite_observation",
	"tech.modern_husbandry",
]


func _init() -> void:
	var catalog: Dictionary = EconomyCatalogScript.compile_native_catalog()
	assert(bool(catalog.get("ok", false)), str(catalog))
	assert(int(catalog.get("technology_catalog_identity_hash", 0)) > 0)
	assert(int(catalog.get("technology_content_binding_hash", 0)) > 0)
	assert(int(catalog.get("technology_trigger_definition_hash", 0)) > 0)
	var technology_ids: PackedStringArray = catalog.technology_ids
	_assert_required_bindings(catalog.good_ids,
		catalog.good_technology_tag_offsets,
		catalog.good_technology_tags, technology_ids)
	_assert_required_bindings(catalog.building_type_ids,
		catalog.building_technology_tag_offsets,
		catalog.building_technology_tags, technology_ids)
	_assert_professions_indirect(catalog.profession_ids,
		catalog.profession_technology_tag_offsets,
		catalog.profession_technology_tags)
	_assert_reverse_bindings(catalog)
	_assert_authoring_bindings_exact(catalog)
	_assert_public_building_effect_scope(catalog)
	_assert_binding_distribution(catalog)
	_assert_critical_direct_consumers(catalog)
	for resource in ResourceRegistryScript.ordered():
		var count := 0
		for raw_tag in resource.discovery_technology_tags:
			var tag := String(raw_tag).strip_edges()
			if not tag.begins_with("tech."):
				continue
			assert(technology_ids.has(tag), "%s -> %s" % [resource.id, tag])
			count += 1
		assert(count > 0, "missing resource discovery binding: %s" % resource.id)
	_assert_steam_scope(catalog)
	_assert_mechanized_agriculture_scope(catalog)
	_assert_electrification_scope(catalog)
	_assert_progressive_unlocks(catalog)
	_assert_networked_crop_and_resource_gates(catalog)
	_assert_estate_institution_scope(catalog)
	_assert_engineering_method_scope(catalog)
	_assert_specialized_production_methods(catalog)
	_assert_explicit_economic_sectors(catalog)
	print("[PASS] technology content bindings cover goods, production methods, and resources")
	quit(0)


func _assert_explicit_economic_sectors(catalog: Dictionary) -> void:
	var ids: PackedStringArray = catalog.building_type_ids
	var sectors: PackedInt32Array = catalog.building_economic_sectors
	assert(sectors.size() == ids.size())
	for farm_id in ["subsistence_farm", "wheat_farm", "rice_collector",
			"rainfed_maize_field", "pastoral_camp", "landed_estate",
			"medicinal_herbs_collector"]:
		var index := ids.find(farm_id)
		assert(index >= 0 and int(sectors[index]) == 0, farm_id)
	for mine_id in ["coal_mine", "iron_ore_collector", "copper_ore_collector"]:
		var index := ids.find(mine_id)
		assert(index >= 0 and int(sectors[index]) == 1, mine_id)
	for knowledge_id in ["oral_memory_circle", "seasonal_observation_shelter",
			"pastoral_council_tent", "tide_observation_hut", "flood_calendar_shrine"]:
		var knowledge_index := ids.find(knowledge_id)
		assert(knowledge_index >= 0 and int(sectors[knowledge_index]) == 4, knowledge_id)


func _assert_required_bindings(ids: PackedStringArray, offsets: PackedInt32Array,
		tags: PackedStringArray, technology_ids: PackedStringArray) -> void:
	assert(offsets.size() == ids.size() + 1)
	for item in range(ids.size()):
		var count := 0
		for edge in range(offsets[item], offsets[item + 1]):
			var tag := String(tags[edge]).strip_edges()
			if not tag.begins_with("tech."):
				continue
			assert(technology_ids.has(tag), "%s -> %s" % [ids[item], tag])
			count += 1
		assert(count > 0, "missing technology binding: %s" % ids[item])


func _assert_professions_indirect(ids: PackedStringArray, offsets: PackedInt32Array,
		tags: PackedStringArray) -> void:
	assert(offsets.size() == ids.size() + 1)
	for item in range(ids.size()):
		for edge in range(offsets[item], offsets[item + 1]):
			assert(not String(tags[edge]).begins_with("tech."),
				"profession has direct technology gate: %s" % ids[item])


func _assert_reverse_bindings(catalog: Dictionary) -> void:
	var technology_ids: PackedStringArray = catalog.technology_ids
	var offsets: PackedInt32Array = catalog.technology_content_binding_offsets
	var kinds: PackedByteArray = catalog.technology_content_binding_kinds
	var binding_ids: PackedStringArray = catalog.technology_content_binding_ids
	var consumer_flags: PackedByteArray = catalog.technology_consumer_flags
	assert(offsets.size() == technology_ids.size() + 1)
	assert(kinds.size() == binding_ids.size())
	assert(consumer_flags.size() == technology_ids.size())
	for technology_index in range(technology_ids.size()):
		assert(int(consumer_flags[technology_index]) != 0,
			"technology has no consumer: %s" % technology_ids[technology_index])
		for binding_index in range(offsets[technology_index], offsets[technology_index + 1]):
			assert(int(kinds[binding_index]) in [1, 2, 3])
			assert(not String(binding_ids[binding_index]).is_empty())


func _assert_authoring_bindings_exact(catalog: Dictionary) -> void:
	var file := FileAccess.open(NETWORK_PATH, FileAccess.READ)
	assert(file != null)
	var parsed = JSON.parse_string(file.get_as_text())
	assert(parsed is Dictionary)
	var expected_by_id := {}
	for node_value in (parsed as Dictionary).get("nodes", []):
		var node: Dictionary = node_value
		var expected := PackedStringArray()
		for binding_value in node.get("expected_bindings", []):
			var binding: Dictionary = binding_value
			expected.append("%d|%s" % [int(binding.get("kind", 0)),
				String(binding.get("id", ""))])
		expected.sort()
		expected_by_id[String(node.id)] = expected
	var technology_ids: PackedStringArray = catalog.technology_ids
	var offsets: PackedInt32Array = catalog.technology_content_binding_offsets
	var kinds: PackedByteArray = catalog.technology_content_binding_kinds
	var binding_ids: PackedStringArray = catalog.technology_content_binding_ids
	for technology_index in range(technology_ids.size()):
		var actual := PackedStringArray()
		for binding_index in range(offsets[technology_index], offsets[technology_index + 1]):
			actual.append("%d|%s" % [int(kinds[binding_index]),
				String(binding_ids[binding_index])])
		actual.sort()
		var technology_id := String(technology_ids[technology_index])
		assert(expected_by_id.has(technology_id), technology_id)
		assert(actual == expected_by_id[technology_id],
			"authoring binding drift: %s expected=%s actual=%s" % [
				technology_id, expected_by_id[technology_id], actual])


func _assert_public_building_effect_scope(catalog: Dictionary) -> void:
	var definitions: Array = TechnologyCatalogScript.public_definitions()
	var technology_ids: PackedStringArray = catalog.technology_ids
	var building_ids: PackedStringArray = catalog.building_type_ids
	var required_offsets: PackedInt32Array = \
		catalog.building_required_technology_tag_offsets
	var activation_offsets: PackedInt32Array = catalog.building_technology_tag_offsets
	var activation_tags: PackedStringArray = catalog.building_technology_tags
	var visible_owner_by_building := {}
	for building_index in range(building_ids.size()):
		assert(required_offsets[building_index] == required_offsets[building_index + 1],
			"building retains hidden required technology tags: %s" % building_ids[building_index])
		var direct_technology_ids := PackedStringArray()
		for edge in range(activation_offsets[building_index],
				activation_offsets[building_index + 1]):
			var tag := String(activation_tags[edge])
			if tag.begins_with("tech."):
				direct_technology_ids.append(tag)
		assert(direct_technology_ids.size() == 1,
			"building must have exactly one visible technology: %s" % building_ids[building_index])
		visible_owner_by_building[String(building_ids[building_index])] = \
			String(direct_technology_ids[0])
	var public_effect_owner_by_building := {}
	for definition_value in definitions:
		var definition: Dictionary = definition_value
		for effect_value in definition.get("content_effects", []):
			var effect: Dictionary = effect_value
			if String(effect.get("kind", "")) != "building":
				continue
			var building_id := String(effect.get("id", ""))
			var building_index := building_ids.find(building_id)
			assert(building_index >= 0, building_id)
			assert(not public_effect_owner_by_building.has(building_id),
				"building has multiple public unlock owners: %s" % building_id)
			public_effect_owner_by_building[building_id] = String(definition.get("id", ""))
	assert(public_effect_owner_by_building.size() == building_ids.size())
	for building_id in building_ids:
		assert(String(public_effect_owner_by_building.get(String(building_id), "")) ==
			String(visible_owner_by_building[String(building_id)]),
			"building public effect does not match its sole technology: %s" % building_id)
	var copper_index := technology_ids.find("tech.natural_copper_identification")
	assert(copper_index >= 0)
	var copper_summary := String((definitions[copper_index] as Dictionary).get(
		"effect_summary", ""))
	assert(not copper_summary.contains("解锁建筑：铜矿"),
		"copper composite building leaked into the technology summary")


func _assert_binding_distribution(catalog: Dictionary) -> void:
	var technology_ids: PackedStringArray = catalog.technology_ids
	var offsets: PackedInt32Array = catalog.technology_content_binding_offsets
	var kinds: PackedByteArray = catalog.technology_content_binding_kinds
	var flags: PackedInt32Array = catalog.technology_flags
	for technology_index in range(technology_ids.size()):
		var direct_count := 0
		var building_count := 0
		for binding_index in range(offsets[technology_index], offsets[technology_index + 1]):
			direct_count += 1
			match int(kinds[binding_index]):
				2:
					building_count += 1
		var is_milestone := (int(flags[technology_index]) \
				& 2) != 0
		if is_milestone:
			assert(direct_count == 0,
				"milestone directly unlocks content: %s -> %d" % [
					technology_ids[technology_index], direct_count])
			continue
		# Schema v2 deliberately has no authoring quota for direct consumers.
		# Composite production systems may unlock several goods, buildings and
		# methods together; their exact bindings are audited above instead.
		assert(direct_count >= building_count)


func _assert_critical_direct_consumers(catalog: Dictionary) -> void:
	for technology_id in CRITICAL_DIRECT_CONSUMERS:
		var bindings := _technology_bindings(catalog, technology_id)
		assert(not bindings.is_empty() or _technology_has_downstream_building(
			catalog, technology_id),
			"critical technology only has a modifier: %s" % technology_id)


func _assert_steam_scope(catalog: Dictionary) -> void:
	var ids: PackedStringArray = catalog.building_type_ids
	var offsets: PackedInt32Array = catalog.building_technology_tag_offsets
	var tags: PackedStringArray = catalog.building_technology_tags
	for item in range(ids.size()):
		for edge in range(offsets[item], offsets[item + 1]):
			if String(tags[edge]) == "tech.steam_power":
				assert(STEAM_BUILDING_ALLOWLIST.has(String(ids[item])), String(ids[item]))


func _assert_mechanized_agriculture_scope(catalog: Dictionary) -> void:
	var bindings := _technology_bindings(catalog, "tech.mechanized_agriculture")
	for binding in bindings:
		if int(binding.kind) != 2:
			continue
		assert(MECHANIZED_AGRICULTURE_BUILDING_ALLOWLIST.has(String(binding.id)),
			"mechanized agriculture unlocks unrelated building: %s" % binding.id)


func _assert_electrification_scope(catalog: Dictionary) -> void:
	var forbidden := {
		"automobiles": true,
		"engines": true,
		"automobiles_plant": true,
		"engines_plant": true,
	}
	for binding in _technology_bindings(catalog, "tech.electrification"):
		assert(not forbidden.has(String(binding.id)),
			"electrification bypasses internal combustion: %s" % binding.id)


func _assert_progressive_unlocks(catalog: Dictionary) -> void:
	_assert_technology_has_binding(catalog, "tech.atmospheric_engine",
		2, "atmospheric_engine_workshop")
	_assert_technology_has_binding(catalog, "tech.steam_power", 2, "steam_engine_works")
	_assert_technology_has_binding(catalog, "tech.steam_pumping", 2, "steam_coal_mine")
	_assert_technology_has_binding(catalog, "tech.synthetic_fertilizer", 2, "fertilizer_plant")
	_assert_technology_has_binding(catalog, "tech.software_engineering",
		2, "computing_research_center")
	_assert_technology_has_binding(catalog, "tech.semiconductor_manufacturing",
		2, "semiconductors_plant")
	_assert_technology_has_binding(catalog, "tech.surface_iron_collection",
		2, "iron_ore_collector")
	_assert_technology_has_binding(catalog, "tech.mine_timbering", 2, "early_iron_mine")
	_assert_building_supports(catalog, "early_iron_mine",
		["tech.surface_iron_collection", "tech.iron_smelting"])
	_assert_technology_has_binding(catalog, "tech.surface_silver_collection",
		2, "shallow_silver_working")
	_assert_technology_has_binding(catalog, "tech.surface_silver_collection",
		2, "surface_silver_working")
	_assert_building_supports(catalog, "shallow_silver_working",
		["tech.ground_stone_tools"])
	_assert_technology_has_binding(catalog, "tech.petroleum_extraction",
		2, "early_oil_well")
	_assert_technology_has_binding(catalog, "tech.petroleum_drilling", 2, "oil_collector")
	_assert_building_supports(catalog, "oil_collector", ["tech.petroleum_extraction"])
	_assert_upgrade_order(catalog, "early_oil_well", "oil_collector", "oil_extraction")
	_assert_upgrade_order(catalog, "iron_ore_collector", "early_iron_mine", "iron_extraction")
	var autonomous_buildings := 0
	for binding in _technology_bindings(catalog, "tech.autonomous_systems"):
		if int(binding.kind) == 2:
			autonomous_buildings += 1
	assert(autonomous_buildings <= 4,
		"autonomous systems became a catch-all building gate: %d" % autonomous_buildings)


func _assert_networked_crop_and_resource_gates(catalog: Dictionary) -> void:
	var file := FileAccess.open(NETWORK_PATH, FileAccess.READ)
	assert(file != null)
	var parsed = JSON.parse_string(file.get_as_text())
	assert(parsed is Dictionary)
	var identification_first := {
		"tech.surface_silver_collection": "tech.silver_vein_identification",
		"tech.gold_panning": "tech.gold_placer_identification",
		"tech.stone_knapping": "tech.flint_identification",
		"tech.earth_building": "tech.clay_identification",
		"tech.wild_tuber_collection": "tech.potato_identification",
		"tech.wild_flax_collection": "tech.flax_identification",
		"tech.reed_harvesting": "tech.reed_identification",
	}
	# A resource-identification node may unlock the first collector for that
	# resource. Later processing and production nodes must remain separate.
	var identification_first_seen := {}
	for node_value in (parsed as Dictionary).get("nodes", []):
		var node: Dictionary = node_value
		var node_id := String(node.get("id", ""))
		if identification_first.has(node_id):
			identification_first_seen[node_id] = true
			var required_identification := String(identification_first[node_id])
			assert(required_identification in node.get("hard_prerequisite_ids", []),
				"%s bypasses %s" % [node_id, required_identification])
			assert((node.get("reveal_condition", {}) as Dictionary).is_empty(),
				"%s keeps an object-witness reveal" % node_id)
		if String(node.get("node_role", "")) != "identification":
			continue
		var identification_id := String(node.get("id", ""))
		for binding in _technology_bindings(catalog, identification_id):
			assert(int(binding.kind) != 2,
				"identification directly constructs production: %s -> %s" % [
					identification_id, binding.id])
	assert(identification_first_seen.size() == identification_first.size())
	_assert_technology_has_binding(catalog, "tech.wild_maize_collection", 2,
		"wild_maize_stand")
	for binding in _technology_bindings(catalog, "tech.maize_propagation"):
		assert(int(binding.kind) != 2,
			"maize propagation bypasses field-system application: %s" % binding.id)
	_assert_building_supports(catalog, "rainfed_maize_field",
		["tech.maize_propagation", "tech.rainfed_field_system"])
	_assert_building_supports(catalog, "swidden_maize_plot",
		["tech.maize_propagation", "tech.controlled_burning"])
	_assert_building_supports(catalog, "tenant_rainfed_maize_field",
		["tech.maize_propagation", "tech.rainfed_field_system",
			"tech.customary_tenancy"])
	_assert_building_supports(catalog, "tenant_paddy",
		["tech.rice_water_control", "tech.customary_tenancy"])
	_assert_building_supports(catalog, "estate_paddy",
		["tech.rice_water_control", "tech.estate_accounting",
			"tech.serf_obligations"])
	_assert_building_supports(catalog, "rubber_tapping_camp",
		["tech.rubber_identification", "tech.composite_tools"])
	_assert_building_supports(catalog, "coal_adit",
		["tech.surface_coal_collection", "tech.masonry"])
	_assert_building_supports(catalog, "natural_copper_workshop",
		["tech.natural_copper_identification", "tech.stone_knapping"])
	_assert_building_supports(catalog, "copper_ore_collector",
		["tech.natural_copper_identification", "tech.stone_knapping"])
	_assert_technology_has_binding(catalog, "tech.natural_copper_identification",
		2, "copper_ore_collector")
	assert(not _technology_has_binding(catalog, "tech.copper_ore_roasting",
		2, "copper_ore_collector"),
		"copper extraction must not be gated by the later roasting technology")
	_assert_building_supports(catalog, "early_copper_smelter",
		["tech.copper_ore_roasting", "tech.charcoal_burning", "tech.pottery"])
	_assert_building_supports(catalog, "pottery_kiln",
		["tech.hand_pottery", "tech.clay_preparation", "tech.charcoal_burning"])
	_assert_technology_has_binding(catalog, "tech.canning", 2, "canning_workshop")
	_assert_technology_has_binding(catalog, "tech.canning", 2, "canned_fish_plant")
	_assert_building_supports(catalog, "canned_fish_plant",
		["tech.steam_power", "tech.industrial_organization"])
	_assert_technology_has_binding(catalog, "tech.cold_chain", 2,
		"dairy_products_plant")
	_assert_building_supports(catalog, "dairy_products_plant",
		["tech.refrigeration", "tech.assembly_line", "tech.industrial_organization"])
	assert(not (catalog.technology_ids as PackedStringArray).has(
		"tech.resource_remote_sensing"),
		"remote sensing must remain split by mineral, crop and hydrology applications")
	for binding in _technology_bindings(catalog, "tech.maize_identification"):
		assert(String(binding.id) != "landed_estate")
	for maize_technology in ["tech.wild_maize_collection",
			"tech.maize_seed_saving", "tech.maize_propagation"]:
		for binding in _technology_bindings(catalog, maize_technology):
			assert(String(binding.id) != "landed_estate")


func _assert_estate_institution_scope(catalog: Dictionary) -> void:
	var direct_owners := {
		"tech.estate_cereal_management": ["landed_estate", "method_wheat_farm_r3"],
		"tech.crop_breeding": ["method_wheat_farm_r5"],
		"tech.rice_water_control": ["method_rice_collector_r3"],
		"tech.estate_paddy_management": ["method_rice_collector_r5"],
		"tech.indentured_contracts": ["method_flax_collector_r3"],
		"tech.long_term_leases": ["method_flax_collector_r5"],
	}
	for technology_id in direct_owners:
		for building_id in direct_owners[technology_id]:
			_assert_technology_has_binding(
				catalog, String(technology_id), 2, String(building_id))
	_assert_building_supports(catalog, "method_wheat_farm_r3", [
		"tech.wheat_propagation", "tech.rainfed_field_system",
		"tech.estate_accounting", "tech.intensive_crop_rotation"])
	_assert_building_supports(catalog, "method_wheat_farm_r5", [
		"tech.wheat_propagation", "tech.rainfed_field_system",
		"tech.estate_accounting", "tech.intensive_crop_rotation",
		"tech.crop_breeding", "tech.long_term_leases"])
	for technology_id in ["tech.seed_selection", "tech.intensive_crop_rotation",
			"tech.rice_paddy_cultivation"]:
		for binding in _technology_bindings(catalog, technology_id):
			assert(String(binding.id) not in ["method_wheat_farm_r3",
				"method_wheat_farm_r5", "method_flax_collector_r3",
				"method_flax_collector_r5", "method_rice_collector_r3",
				"method_rice_collector_r5"],
				"agronomy technology directly unlocks an estate institution method: %s -> %s" % [
					technology_id, binding.id])


func _assert_engineering_method_scope(catalog: Dictionary) -> void:
	var expected_direct := {
		"tech.autonomous_labor_coordination": [
			"method_aluminum_plant_r10", "method_stainless_steel_plant_r10"],
		"tech.neural_networks": [
			"method_detergent_plant_r10", "method_rare_earth_metals_plant_r10"],
		"tech.nuclear_fuel_cycle": ["method_reactor_component_works_r10"],
		"tech.algorithmic_management": [
			"method_synthetic_fiber_plant_r10", "method_synthetic_rubber_plant_r10"],
		"tech.sensor_networks": ["method_coke_ovens_r9", "method_concrete_plant_r9"],
		"tech.fertilizer_processing": ["method_phosphate_rock_collector_r9"],
		"tech.systems_engineering": ["method_zinc_plant_r9"],
		"tech.corporate_management": ["beverages_plant", "fine_clothing_plant"],
		"tech.currency": ["jewelry_plant"],
		"tech.labor_organization": ["footwear_plant"],
		"tech.platform_coordination": [
			"method_industrial_machinery_plant_r9", "method_petrochemicals_plant_r10"],
		"tech.state_enterprises": [
			"method_saltpeter_collector_r8", "method_sulfur_collector_r8"],
		"tech.scientific_agents": [
			"method_sulfur_collector_r10", "method_zinc_ore_collector_r9"],
		"tech.smart_grid": ["method_electric_motor_plant_r10"],
		"tech.electronic_control": ["zinc_plant"],
		"tech.geographic_information_systems": ["method_limestone_collector_r6"],
		"tech.highland_tuber_farming": ["method_potato_collector_r6"],
		"tech.copper_metallurgy": ["early_tin_mine"],
		"tech.industrial_agronomy": ["method_agricultural_machinery_plant_r9"],
	}
	for technology_id in expected_direct:
		for building_id in expected_direct[technology_id]:
			_assert_technology_has_binding(
				catalog, String(technology_id), 2, String(building_id))
	var technology_ids: PackedStringArray = catalog.technology_ids
	for technology_id in technology_ids:
		var direct_buildings := 0
		for binding in _technology_bindings(catalog, String(technology_id)):
			if int(binding.kind) == 2:
				direct_buildings += 1
		assert(direct_buildings <= 2,
			"technology directly unlocks too many buildings: %s -> %d" % [
				technology_id, direct_buildings])
	_assert_building_supports(catalog, "method_oceanic_shipyard_r7", [
		"tech.oceanic_ship_design", "tech.coastal_shipyards",
		"tech.mass_production", "tech.industrial_statistics"])
	_assert_building_supports(catalog, "method_lead_plant_r9", [
		"tech.advanced_metallurgy", "tech.mineral_spectral_survey",
		"tech.sensor_networks", "tech.industrial_quality_control"])
	_assert_building_supports(catalog, "method_aluminum_plant_r10", [
		"tech.advanced_metallurgy", "tech.specialty_alloys",
		"tech.algorithmic_management", "tech.autonomous_labor_coordination"])


func _assert_specialized_production_methods(catalog: Dictionary) -> void:
	var methods := [
		["method_steam_shipping", "tech.steam_sealing",
			["tech.oceanic_navigation", "tech.steam_power", "tech.coastal_shipyards"]],
		["method_automated_port", "tech.automated_logistics",
			["tech.global_logistics", "tech.digital_control", "tech.electric_grid"]],
		["method_autonomous_shipping", "tech.autonomous_logistics",
			["tech.autonomous_systems", "tech.smart_grid", "tech.distributed_intelligence"]],
		["hydropower_station", "tech.water_power",
			["tech.hydraulic_engineering", "tech.electric_generation", "tech.electric_grid"]],
		["watershed_governance_center", "tech.hydrological_remote_sensing",
			["tech.hydraulic_engineering", "tech.geographic_information_systems"]],
		["smart_water_network", "tech.algorithmic_governance",
			["tech.hydrological_remote_sensing", "tech.smart_grid", "tech.autonomous_systems"]],
		["method_forest_remote_sensing", "tech.satellite_observation",
			["tech.forest_management", "tech.geographic_information_systems"]],
		["method_autonomous_forestry", "tech.autonomous_systems",
			["tech.satellite_observation", "tech.smart_grid", "tech.scientific_agents"]],
		["method_highland_precision_agriculture", "tech.precision_agriculture",
			["tech.highland_tuber_farming", "tech.geographic_information_systems",
				"tech.biotechnology"]],
		["method_smart_husbandry", "tech.modern_husbandry",
			["tech.sensor_networks", "tech.autonomous_systems", "tech.smart_grid"]],
		["method_specialty_commodity_plantation", "tech.commodity_crop_management",
			["tech.biotechnology", "tech.precision_agriculture", "tech.automated_agriculture"]],
	]
	for row in methods:
		_assert_technology_has_binding(catalog, String(row[1]), 2, String(row[0]))
		_assert_building_supports(catalog, String(row[0]), row[2])

	_assert_output_gain(catalog, "hydropower_station", "electricity",
		"electricity_plant", "electricity", 120)
	_assert_output_gain(catalog, "method_forest_remote_sensing", "logs",
		"method_timber_collector_r4", "logs", 120)
	_assert_output_gain(catalog, "method_autonomous_forestry", "logs",
		"method_forest_remote_sensing", "logs", 120)
	_assert_output_gain(catalog, "method_highland_precision_agriculture", "potatoes",
		"highland_tuber_plot", "potatoes", 120)
	_assert_output_gain(catalog, "method_smart_husbandry", "livestock_products",
		"ranching_station", "livestock_products", 120)
	assert(_output_reference_value(catalog, "method_specialty_commodity_plantation") * 100 \
		>= _output_reference_value(catalog, "method_rubber_tree_collector_r6") * 120)

	var ordinary_roles := ["industrial_worker", "machinist"]
	_assert_labor_replacement(catalog, "method_steam_shipping",
		"method_automated_port", ordinary_roles)
	_assert_labor_replacement(catalog, "method_automated_port",
		"method_autonomous_shipping", ordinary_roles)
	_assert_labor_replacement(catalog, "method_forest_remote_sensing",
		"method_autonomous_forestry", ["forestry_worker"])
	_assert_labor_replacement(catalog, "ranching_station",
		"method_smart_husbandry", ["agricultural_worker"])

	var capital_goods := ["steam_engines", "engines", "industrial_machinery",
		"agricultural_machinery", "electricity", "computers",
		"autonomous_systems", "technology_points"]
	_assert_capital_input_gain(catalog, "method_steam_shipping",
		"method_automated_port", capital_goods)
	_assert_capital_input_gain(catalog, "method_automated_port",
		"method_autonomous_shipping", capital_goods)
	_assert_capital_input_gain(catalog, "method_forest_remote_sensing",
		"method_autonomous_forestry", capital_goods)
	_assert_capital_input_gain(catalog, "ranching_station",
		"method_smart_husbandry", capital_goods)

	for conditioned_id in ["hydropower_station", "watershed_governance_center",
			"smart_water_network", "method_forest_remote_sensing",
			"method_autonomous_forestry", "method_highland_precision_agriculture",
			"method_smart_husbandry", "method_specialty_commodity_plantation"]:
		var building := (catalog.building_type_ids as PackedStringArray).find(conditioned_id)
		var offsets: PackedInt32Array = catalog.building_condition_offsets
		assert(building >= 0 and offsets[building + 1] > offsets[building],
			"specialized method lacks geography/resource condition: %s" % conditioned_id)


func _assert_output_gain(catalog: Dictionary, new_building: String, new_good: String,
		base_building: String, base_good: String, minimum_percent: int) -> void:
	assert(_output_quantity(catalog, new_building, new_good) * 100 \
		>= _output_quantity(catalog, base_building, base_good) * minimum_percent,
		"target output gain below %d%%: %s" % [minimum_percent, new_building])


func _assert_labor_replacement(catalog: Dictionary, base_building: String,
		new_building: String, ordinary_professions: Array) -> void:
	var base_slots := _employee_slots(catalog, base_building, ordinary_professions)
	var new_slots := _employee_slots(catalog, new_building, ordinary_professions)
	assert(base_slots > 0 and new_slots * 100 <= base_slots * 80 \
		and new_slots * 100 >= base_slots * 50,
		"ordinary labor replacement must be 20-50%%: %s -> %s" % [
			base_building, new_building])


func _assert_capital_input_gain(catalog: Dictionary, base_building: String,
		new_building: String, capital_goods: Array) -> void:
	var base_value := _input_reference_value(catalog, base_building, capital_goods)
	var new_value := _input_reference_value(catalog, new_building, capital_goods)
	assert(new_value * 100 >= base_value * 115,
		"automation capital/energy/technology input gain below 15%%: %s -> %s" % [
			base_building, new_building])


func _employee_slots(catalog: Dictionary, building_id: String,
		profession_ids: Array) -> int:
	var building := (catalog.building_type_ids as PackedStringArray).find(building_id)
	assert(building >= 0, building_id)
	var professions: PackedStringArray = catalog.profession_ids
	var offsets: PackedInt32Array = catalog.building_employee_offsets
	var role_ids: PackedInt32Array = catalog.building_employee_profession_ids
	var slots: PackedInt64Array = catalog.building_employee_slots
	var total := 0
	for edge in range(offsets[building], offsets[building + 1]):
		if profession_ids.has(String(professions[role_ids[edge]])):
			total += int(slots[edge])
	return total


func _input_reference_value(catalog: Dictionary, building_id: String,
		included_good_ids: Array) -> int:
	var building := (catalog.building_type_ids as PackedStringArray).find(building_id)
	assert(building >= 0, building_id)
	var good_ids: PackedStringArray = catalog.good_ids
	var prices: PackedInt32Array = catalog.good_default_price
	var offsets: PackedInt32Array = catalog.building_input_offsets
	var goods: PackedInt32Array = catalog.building_input_good_ids
	var quantities: PackedInt64Array = catalog.building_input_quantities
	var total := 0
	for edge in range(offsets[building], offsets[building + 1]):
		var good := int(goods[edge])
		if included_good_ids.has(String(good_ids[good])):
			total += int(quantities[edge]) * int(prices[good])
	return total


func _output_reference_value(catalog: Dictionary, building_id: String) -> int:
	var building := (catalog.building_type_ids as PackedStringArray).find(building_id)
	assert(building >= 0, building_id)
	var prices: PackedInt32Array = catalog.good_default_price
	var offsets: PackedInt32Array = catalog.building_output_offsets
	var goods: PackedInt32Array = catalog.building_output_good_ids
	var quantities: PackedInt64Array = catalog.building_output_quantities
	var total := 0
	for edge in range(offsets[building], offsets[building + 1]):
		total += int(quantities[edge]) * int(prices[goods[edge]])
	return total


func _output_quantity(catalog: Dictionary, building_id: String, good_id: String) -> int:
	var building := (catalog.building_type_ids as PackedStringArray).find(building_id)
	var good := (catalog.good_ids as PackedStringArray).find(good_id)
	assert(building >= 0 and good >= 0, "%s/%s" % [building_id, good_id])
	var offsets: PackedInt32Array = catalog.building_output_offsets
	var goods: PackedInt32Array = catalog.building_output_good_ids
	var quantities: PackedInt64Array = catalog.building_output_quantities
	for edge in range(offsets[building], offsets[building + 1]):
		if int(goods[edge]) == good:
			return int(quantities[edge])
	assert(false, "%s does not output %s" % [building_id, good_id])
	return 0


func _assert_building_supports(catalog: Dictionary, building_id: String,
		required_ids: Array) -> void:
	var building_index := (catalog.building_type_ids as PackedStringArray).find(building_id)
	assert(building_index >= 0, building_id)
	var actual := PackedStringArray()
	var required_offsets: PackedInt32Array = catalog.building_required_technology_tag_offsets
	assert(required_offsets[building_index] == required_offsets[building_index + 1])
	var activation_offsets: PackedInt32Array = catalog.building_technology_tag_offsets
	var activation_tags: PackedStringArray = catalog.building_technology_tags
	for edge in range(activation_offsets[building_index], activation_offsets[building_index + 1]):
		var technology_id := String(activation_tags[edge])
		if technology_id.begins_with("tech."):
			_collect_technology_ancestry(catalog, technology_id, actual)
	for technology_id in required_ids:
		assert(actual.has(technology_id), "%s missing ALL support %s" % [
			building_id, technology_id])


func _collect_technology_ancestry(catalog: Dictionary, technology_id: String,
		out: PackedStringArray) -> void:
	if out.has(technology_id):
		return
	out.append(technology_id)
	var technology_index := (catalog.technology_ids as PackedStringArray).find(technology_id)
	assert(technology_index >= 0, technology_id)
	var offsets: PackedInt32Array = catalog.technology_prerequisite_offsets
	var prerequisites: PackedInt32Array = catalog.technology_prerequisites
	for edge in range(offsets[technology_index], offsets[technology_index + 1]):
		_collect_technology_ancestry(catalog,
			String(catalog.technology_ids[int(prerequisites[edge])]), out)


func _technology_has_downstream_building(catalog: Dictionary,
		technology_id: String) -> bool:
	var ids: PackedStringArray = catalog.technology_ids
	for candidate_id in ids:
		var ancestry := PackedStringArray()
		_collect_technology_ancestry(catalog, String(candidate_id), ancestry)
		if not ancestry.has(technology_id):
			continue
		for binding in _technology_bindings(catalog, String(candidate_id)):
			if int(binding.kind) == 2:
				return true
	return false


func _assert_upgrade_order(catalog: Dictionary, earlier_id: String, later_id: String,
		expected_family: String) -> void:
	var ids: PackedStringArray = catalog.building_type_ids
	var earlier := ids.find(earlier_id)
	var later := ids.find(later_id)
	assert(earlier >= 0 and later >= 0, "%s/%s" % [earlier_id, later_id])
	var family_indices: PackedInt32Array = catalog.building_upgrade_family_indices
	var family_ids: PackedStringArray = catalog.building_upgrade_family_ids
	var tiers: PackedInt32Array = catalog.building_upgrade_tiers
	assert(int(family_indices[earlier]) >= 0 and int(family_indices[later]) >= 0)
	assert(String(family_ids[family_indices[earlier]]) == expected_family)
	assert(String(family_ids[family_indices[later]]) == expected_family)
	assert(int(tiers[earlier]) < int(tiers[later]),
		"upgrade tier must increase: %s T%d -> %s T%d" % [
			earlier_id, tiers[earlier], later_id, tiers[later]])


func _assert_technology_has_binding(catalog: Dictionary, technology_id: String,
		kind: int, binding_id: String) -> void:
	for binding in _technology_bindings(catalog, technology_id):
		if int(binding.kind) == kind and String(binding.id) == binding_id:
			return
	if kind == 2:
		var building_index := (catalog.building_type_ids as PackedStringArray).find(binding_id)
		if building_index >= 0:
			var offsets: PackedInt32Array = catalog.building_technology_tag_offsets
			var tags: PackedStringArray = catalog.building_technology_tags
			for edge in range(offsets[building_index], offsets[building_index + 1]):
				var direct_id := String(tags[edge])
				if not direct_id.begins_with("tech."):
					continue
				var ancestry := PackedStringArray()
				_collect_technology_ancestry(catalog, direct_id, ancestry)
				if ancestry.has(technology_id):
					return
	assert(false, "%s missing binding %s" % [technology_id, binding_id])


func _technology_has_binding(catalog: Dictionary, technology_id: String,
		kind: int, binding_id: String) -> bool:
	for binding in _technology_bindings(catalog, technology_id):
		if int(binding.kind) == kind and String(binding.id) == binding_id:
			return true
	return false


func _technology_bindings(catalog: Dictionary, technology_id: String) -> Array[Dictionary]:
	var technology_index := (catalog.technology_ids as PackedStringArray).find(technology_id)
	assert(technology_index >= 0, technology_id)
	var offsets: PackedInt32Array = catalog.technology_content_binding_offsets
	var kinds: PackedByteArray = catalog.technology_content_binding_kinds
	var binding_ids: PackedStringArray = catalog.technology_content_binding_ids
	var out: Array[Dictionary] = []
	for binding_index in range(offsets[technology_index], offsets[technology_index + 1]):
		out.append({
			"kind": int(kinds[binding_index]),
			"id": String(binding_ids[binding_index]),
		})
	return out
