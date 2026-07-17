extends SceneTree

const EconomyCatalogScript = preload("res://scripts/economy/economy_catalog.gd")
const ResourceRegistryScript = preload("res://scripts/data/resource_profile_registry.gd")
const BuildingProfileScript = preload("res://scripts/data/building_profile.gd")

var failures := 0

func _init() -> void:
	var catalog: Dictionary = EconomyCatalogScript.compile_native_catalog()
	_expect("modern economy catalog compiles", bool(catalog.get("ok", false)))
	if bool(catalog.get("ok", false)):
		_audit(catalog)
	else:
		print(catalog)
	_audit_explicit_candidate_validation()
	print("=== modern economy catalog %s ===" % ("PASS" if failures == 0 else "FAIL"))
	quit(0 if failures == 0 else 1)

func _expect(label: String, condition: bool) -> void:
	print("  [%s] %s" % ["PASS" if condition else "FAIL", label])
	if not condition: failures += 1

func _audit(catalog: Dictionary) -> void:
	var goods: PackedStringArray = catalog.good_ids
	var buildings: PackedStringArray = catalog.building_type_ids
	var professions: PackedStringArray = catalog.profession_ids
	var needs: PackedStringArray = catalog.need_ids
	var resources: PackedStringArray = catalog.building_resource_ids
	_expect("simplified catalog has 120 goods", goods.size() == 120)
	_expect("bounded catalog has 259 production methods", buildings.size() == 259)
	_expect("32 labor-relation professions", professions.size() == 32)
	_expect("17 differentiated household needs", needs.size() == 17)
	_expect("30 registered natural resources", ResourceRegistryScript.count() == 30)
	_expect("building catalog references 30 distinct natural resources", resources.size() == 30)
	for relation_profession in ["enslaved_laborer", "serf", "tenant_farmer",
			"indentured_laborer", "apprentice", "journeyman", "manager", "researcher"]:
		_expect("labor relation profession exists: %s" % relation_profession,
			professions.find(relation_profession) >= 0)
	for retired_profession in ["knapper", "potter", "bronze_founder", "mason", "scribe",
			"printer", "shipwright", "navigator", "steam_engineer", "electrical_engineer",
			"nuclear_engineer", "software_developer", "ai_researcher",
			"space_systems_engineer", "astronaut"]:
		_expect("over-specialized profession retired: %s" % retired_profession,
			professions.find(retired_profession) < 0)
	for retired_crop in ["wheat", "rice", "corn", "potato", "rubber_tree",
			"spice_plants", "flax", "cotton", "medicinal_herbs"]:
		_expect("cultivated crop is not a natural resource: %s" % retired_crop,
			resources.find(retired_crop) < 0)
	for capacity_id in ["arable_land", "paddy_land", "plantation_land", "pasture"]:
		_expect("agricultural capacity resource exists: %s" % capacity_id,
			resources.find(capacity_id) >= 0)
	for retired_resource in ["cattle", "sheep", "pigs", "horses", "fresh_water", "freshwater_fish"]:
		_expect("retired natural resource absent: %s" % retired_resource,
			resources.find(retired_resource) < 0)
	for retired_good in ["cattle", "sheep", "pigs", "raw_water", "clean_water", "beef", "mutton", "pork"]:
		_expect("retired good absent: %s" % retired_good,
			goods.find(retired_good) < 0)
	for consolidated_good in ["livestock_products", "meat", "raw_hide", "wool", "horses"]:
		_expect("consolidated livestock good exists: %s" % consolidated_good,
			goods.find(consolidated_good) >= 0)
	_expect("horse breeding has two preindustrial methods without late-era pseudo-upgrades",
		buildings.has("horse_breeding_camp") and buildings.has("horse_breeder") and
		not buildings.has("method_horse_breeder_r5") and
		not buildings.has("method_horse_breeder_r8") and
		not buildings.has("method_horse_breeder_r9"))
	for retired_chain_good in ["flour", "rice_food", "corn_food", "potato_food", "wood_pulp",
			"pig_iron", "flax_yarn", "cotton_yarn", "textile", "cut_stone", "dressed_masonry",
			"codices", "papyrus", "parchment"]:
		_expect("redundant chain good retired: %s" % retired_chain_good,
			goods.find(retired_chain_good) < 0)
	for terminal_good in ["prepared_staples", "fine_clothing", "fine_furniture"]:
		_expect("new terminal good exists: %s" % terminal_good, goods.find(terminal_good) >= 0)
	_expect("eight consumption prototypes compile",
		catalog.plan_ids == PackedStringArray(["agrarian_household", "artisan_household",
			"extractive_household", "industrial_worker_household", "merchant_household",
			"owner_household", "survival_household", "technical_household"]))
	_expect("occupational and status needs compile",
		needs.has("work_equipment") and needs.has("status_goods"))
	_audit_household_consumption(catalog)
	var corn_farm = load("res://data/economy/buildings/landed_estate.tres")
	var wheat_farm = load("res://data/economy/buildings/wheat_farm.tres")
	_expect("corn collector remains an estate crop building",
		corn_farm != null and String(corn_farm.id) == "landed_estate" and
		corn_farm.resource_ids.has("arable_land"))
	_expect("wheat collector remains an arable crop building",
		wheat_farm != null and String(wheat_farm.id) == "wheat_farm" and
		wheat_farm.resource_ids.has("arable_land"))
	var gathering = load("res://data/economy/buildings/gathering_ground.tres")
	var stone_hunting = load(
		"res://data/economy/buildings/stone_age_hunting_camp.tres")
	_expect("stone hunting tool demand fits the local knapping chain",
		stone_hunting != null and
		stone_hunting.input_good_ids == PackedStringArray(["chipped_stone_tools"]) and
		stone_hunting.input_quantities_per_day == PackedInt64Array([5]))
	var stone_collector = load("res://data/economy/buildings/stone_collector.tres")
	var timber_collector = load("res://data/economy/buildings/timber_collector.tres")
	var bronze_tools = load("res://data/economy/buildings/bronze_tool_workshop.tres")
	var ore_bronze = load("res://data/economy/buildings/ore_bronzesmith_camp.tres")
	_expect("early collectors keep tool maintenance below local workshop output",
		stone_collector.input_quantities_per_day == PackedInt64Array([100]) and
		timber_collector.input_quantities_per_day == PackedInt64Array([100]))
	_expect("bronze workshops avoid material-cost dominated recipes",
		bronze_tools.input_quantities_per_day == PackedInt64Array([1500, 500]) and
		ore_bronze.input_quantities_per_day == PackedInt64Array([500, 500, 500]))
	var early_gold = load("res://data/economy/buildings/placer_gold_working.tres")
	var early_silver = load("res://data/economy/buildings/surface_silver_working.tres")
	var bronze_workshop = load("res://data/economy/buildings/bronze_tool_workshop.tres")
	var guild_hall = load("res://data/economy/buildings/guild_hall.tres")
	var steam_works = load("res://data/economy/buildings/steam_engine_works.tres")
	var stone_owner_policy := {
		"communal_hearth": "forager", "flint_quarry": "forager",
		"gathering_ground": "forager", "household_weaving_shelter": "artisan",
		"knapping_workshop": "artisan", "lumber_plant": "artisan",
		"marine_fish_collector": "fisher", "placer_gold_working": "merchant",
		"stone_age_hunting_camp": "hunter", "stone_collector": "forager",
		"surface_silver_working": "merchant", "timber_collector": "forager",
	}
	for building_id in stone_owner_policy:
		var stone_building = load("res://data/economy/buildings/%s.tres" % building_id)
		_expect("stone production is owner-operated: %s" % building_id,
			stone_building != null and
			String(stone_building.owner_profession_id) == stone_owner_policy[building_id] and
			stone_building.employee_profession_ids.is_empty())
	_expect("stone hunting sustains its hunter and yields fewer byproducts",
		stone_hunting != null and
		stone_hunting.output_good_ids == PackedStringArray(["game_meat", "raw_hide", "fur"]) and
		stone_hunting.output_quantities_per_day == PackedInt64Array([7000, 250, 100]) and
		stone_hunting.output_quantities_per_day[0] >= 171 and
		stone_hunting.output_quantities_per_day[0] >
			stone_hunting.output_quantities_per_day[1] and
		stone_hunting.output_quantities_per_day[1] >
			stone_hunting.output_quantities_per_day[2] and
		stone_hunting.resource_quantities_per_day == PackedInt64Array([715]) and
		stone_hunting.owner_slots_per_building == 5)
	_expect("early bullion production is owner-operated and input-free",
		String(early_gold.owner_profession_id) == "merchant" and
		String(early_silver.owner_profession_id) == "merchant" and
		early_gold.input_good_ids.is_empty() and early_silver.input_good_ids.is_empty() and
		early_gold.employee_profession_ids.is_empty() and
		early_silver.employee_profession_ids.is_empty() and
		early_gold.technology_tags.has("tech.gathering") and
		early_silver.technology_tags.has("tech.gathering"))
	_expect("bronze workshop uses a small apprentice household",
		String(bronze_workshop.owner_profession_id) == "artisan" and
		bronze_workshop.employee_profession_ids == PackedStringArray(["apprentice"]) and
		bronze_workshop.employee_slots_per_building == PackedInt64Array([3]) and
		bronze_workshop.input_good_ids == PackedStringArray(["copper", "tin"]))
	var monastic_scriptorium = load("res://data/economy/buildings/monastic_scriptorium.tres")
	var classical_scriptorium = load("res://data/economy/buildings/classical_scriptorium.tres")
	var manuscripts = load("res://data/goods/manuscripts.tres")
	_expect("monastic copying deepens the shared manuscripts good",
		monastic_scriptorium != null and
		monastic_scriptorium.output_good_ids == PackedStringArray(["manuscripts"]))
	_expect("hand-copied content is one unified good",
		manuscripts != null and manuscripts.display_name == "手抄本" and
		goods.find("codices") < 0)
	_expect("writing materials are folded into scriptorium recipes",
		classical_scriptorium != null and monastic_scriptorium != null and
		classical_scriptorium.input_good_ids == PackedStringArray(["gathered_plants"]) and
		monastic_scriptorium.input_good_ids == PackedStringArray(["raw_hide"]) and
		not buildings.has("papyrus_workshop") and not buildings.has("parchmenter"))
	var iron_tool_workshop = load("res://data/economy/buildings/iron_tool_workshop.tres")
	var steel_tool_plant = load("res://data/economy/buildings/tools_plant.tres")
	var precision_tool_workshop = load(
		"res://data/economy/buildings/precision_tool_workshop.tres")
	_expect("generic metal tools begin with classical iron working",
		iron_tool_workshop != null and
		iron_tool_workshop.technology_tags.has("tech.masonry") and
		iron_tool_workshop.output_good_ids == PackedStringArray(["tools"]))
	_expect("steam steel tools are a later method for the same good",
		steel_tool_plant != null and steel_tool_plant.technology_tags.has("tech.steam_power") and
		steel_tool_plant.output_good_ids == PackedStringArray(["tools"]))
	_expect("precision tools start before steam and require metal-quality tools",
		precision_tool_workshop != null and
		precision_tool_workshop.technology_tags.has("tech.precision_engineering") and
		precision_tool_workshop.input_category_ids == PackedStringArray(["tools", ""]) and
		precision_tool_workshop.input_min_quality_levels == PackedInt32Array([3, 0]))
	var canning_workshop = load("res://data/economy/buildings/canning_workshop.tres")
	var canned_fish_plant = load("res://data/economy/buildings/canned_fish_plant.tres")
	_expect("canning begins in Enlightenment and industrializes with steam",
		canning_workshop != null and canned_fish_plant != null and
		canning_workshop.technology_tags.has("tech.experimental_science") and
		canned_fish_plant.technology_tags.has("tech.steam_power"))
	var oceanic_shipyard = load("res://data/economy/buildings/oceanic_shipyard.tres")
	_expect("exploration production rejects stone and bronze tools",
		oceanic_shipyard != null and
		oceanic_shipyard.input_category_ids[-1] == "tools" and
		oceanic_shipyard.input_min_quality_levels[-1] == 3)
	var commercial_hunting = load(
		"res://data/economy/buildings/method_stone_age_hunting_camp_r4.tres")
	_expect("exploration commercial hunting replaces stone tools with metal tools",
		commercial_hunting != null and
		commercial_hunting.input_good_ids == PackedStringArray(["tools"]) and
		commercial_hunting.input_category_ids == PackedStringArray(["tools"]) and
		commercial_hunting.input_min_quality_levels == PackedInt32Array([3]))
	_expect("guild production distinguishes apprentices and journeymen",
		String(guild_hall.owner_profession_id) == "guild_master" and
		guild_hall.employee_profession_ids == PackedStringArray(["apprentice", "journeyman"]))
	var classical_fishery = load(
		"res://data/economy/buildings/method_marine_fish_collector_r2.tres")
	_expect("preindustrial collectors are owned and staffed by their trade",
		String(classical_fishery.owner_profession_id) == "fisher" and
		classical_fishery.employee_profession_ids == PackedStringArray(["fisher"]) and
		String(commercial_hunting.owner_profession_id) == "hunter" and
		commercial_hunting.employee_profession_ids == PackedStringArray(["hunter"]))
	var industrial_gold_mine = load("res://data/economy/buildings/gold_mine.tres")
	var industrial_silver_mine = load("res://data/economy/buildings/silver_mine.tres")
	_expect("industrial bullion mines use capital and mine labor",
		String(industrial_gold_mine.owner_profession_id) == "industrialist" and
		String(industrial_silver_mine.owner_profession_id) == "industrialist" and
		industrial_gold_mine.employee_profession_ids == PackedStringArray(["miner", "manager"]) and
		industrial_silver_mine.employee_profession_ids == PackedStringArray(["miner", "manager"]))
	_expect("steam factory introduces workers, engineers, and management",
		steam_works.employee_profession_ids ==
			PackedStringArray(["industrial_worker", "engineer", "manager"]))
	var guild_wheat_farm = load(
		"res://data/economy/buildings/method_wheat_farm_r3.tres")
	_expect("guild-era commercial farming uses landlord and tenant relations",
		guild_wheat_farm != null and
		String(guild_wheat_farm.owner_profession_id) == "landlord" and
		guild_wheat_farm.employee_profession_ids == PackedStringArray(["tenant_farmer"]) and
		guild_wheat_farm.employee_slots_per_building == PackedInt64Array([12]))
	var mechanized_farm = load("res://data/economy/buildings/mechanized_farm.tres")
	var intensive_farm = load("res://data/economy/buildings/intensive_farm.tres")
	var mechanized_cotton = load(
		"res://data/economy/buildings/method_cotton_collector_r6.tres")
	_expect("mechanization changes farm labor without turning the landowner industrial",
		mechanized_farm != null and intensive_farm != null and mechanized_cotton != null and
		String(mechanized_farm.owner_profession_id) == "landlord" and
		String(intensive_farm.owner_profession_id) == "landlord" and
		String(mechanized_cotton.owner_profession_id) == "landlord" and
		mechanized_farm.employee_profession_ids ==
			PackedStringArray(["agricultural_worker", "manager"]) and
		intensive_farm.employee_profession_ids ==
			PackedStringArray(["agricultural_worker", "manager"]))
	var sawmill = load("res://data/economy/buildings/lumber_plant.tres")
	var logging_camp = load("res://data/economy/buildings/timber_collector.tres")
	var coal_mine = load("res://data/economy/buildings/coal_mine.tres")
	var oil_field = load("res://data/economy/buildings/oil_collector.tres")
	_expect("building names describe their actual organization instead of generic collection",
		sawmill != null and sawmill.display_name == "锯木场" and
		logging_camp != null and logging_camp.display_name == "伐木场" and
		coal_mine != null and coal_mine.display_name == "煤矿" and
		oil_field != null and oil_field.display_name == "油田")
	var cabinetmaker = load("res://data/economy/buildings/cabinetmaker_workshop.tres")
	_expect("fine cabinetmaking is a staffed guild workshop with maintenance tools",
		cabinetmaker != null and String(cabinetmaker.owner_profession_id) == "guild_master" and
		cabinetmaker.employee_slots_per_building == PackedInt64Array([6, 6]) and
		cabinetmaker.input_good_ids.has("tools"))
	var computer_factory = load("res://data/economy/buildings/computers_plant.tres")
	var plastics_factory = load("res://data/economy/buildings/plastics_plant.tres")
	_expect("digital computer production has a larger technical workforce than plastics",
		computer_factory != null and plastics_factory != null and
		computer_factory.employee_profession_ids.has("engineer") and
		computer_factory.employee_profession_ids.has("researcher") and
		_sum_i64(computer_factory.employee_slots_per_building) >
			_sum_i64(plastics_factory.employee_slots_per_building))
	_expect("mature factories consume tools, electricity, and installed machinery",
		plastics_factory.input_good_ids.has("tools") and
		plastics_factory.input_good_ids.has("electricity") and
		plastics_factory.input_good_ids.has("industrial_machinery"))
	for retired_building in ["shell_money_station", "software_studio", "network_data_center",
			"digital_service_exchange", "ai_research_lab", "orbital_research_program",
			"orbital_technology_transfer", "deep_space_telemetry_program", "sail_loft",
			"naval_salvage_yard", "navigation_instrument_shop", "isotope_reactor",
			"bronze_foundry", "manganese_alloy_plant", "hafted_stone_tool_shelter"]:
		_expect("retired pseudo-service building removed: %s" % retired_building,
			buildings.find(retired_building) < 0)
	for bounded_method in ["method_gathering_ground_r1", "method_flint_quarry_r1",
			"method_stone_age_hunting_camp_r4", "method_pottery_kiln_r3",
			"method_spice_plants_collector_r6", "method_medicinal_herbs_collector_r7",
			"method_edible_oil_plant_r6", "method_soap_plant_r6",
			"method_packaging_plant_r7", "method_printed_materials_plant_r7",
			"method_oceanic_shipyard_r7"]:
		_expect("bounded industry keeps one meaningful terminal method: %s" % bounded_method,
			buildings.has(bounded_method))
	for pseudo_upgrade in ["method_gathering_ground_r8", "method_flint_quarry_r8",
			"method_stone_age_hunting_camp_r8", "method_pottery_kiln_r8",
			"method_spice_plants_collector_r8", "method_medicinal_herbs_collector_r8",
			"method_edible_oil_plant_r8", "method_soap_plant_r8",
			"method_packaging_plant_r8", "method_printed_materials_plant_r8",
			"method_landed_estate_r8", "method_potato_collector_r8",
			"method_cotton_collector_r8", "method_rubber_tree_collector_r8",
			"method_oceanic_shipyard_r8", "method_bricks_plant_r8",
			"method_lime_plant_r8", "method_limestone_collector_r8"]:
		_expect("negligible industry has no late pseudo-upgrade: %s" % pseudo_upgrade,
			not buildings.has(pseudo_upgrade))
	var processed_food_plant = load("res://data/economy/buildings/processed_food_plant.tres")
	_expect("edible oil feeds mass processed food",
		processed_food_plant != null and processed_food_plant.input_good_ids.has("edible_oil"))
	for retired_good in ["sailcloth", "navigation_instruments", "medical_isotopes",
			"bronze", "manganese_alloy"]:
		_expect("single-use intermediate removed: %s" % retired_good,
			goods.find(retired_good) < 0)
	_expect("water resources use explicit geographic habitats",
		ResourceRegistryScript.habitat_code(ResourceRegistryScript.ordered().filter(
			func(p): return String(p.id) == "marine_fish")[0]) == 2)
	var flint_resource = ResourceRegistryScript.ordered().filter(
		func(p): return String(p.id) == "flint")[0]
	var rare_earth_resource = ResourceRegistryScript.ordered().filter(
		func(p): return String(p.id) == "rare_earth")[0]
	_expect("early flint deposit is visible without prospecting",
		ResourceRegistryScript.discovery_visible(flint_resource, PackedStringArray()))
	_expect("abstract rare-earth deposit requires geological prospecting",
		not ResourceRegistryScript.discovery_visible(rare_earth_resource, PackedStringArray()) and
		ResourceRegistryScript.discovery_visible(rare_earth_resource,
			PackedStringArray(["tech.geological_prospecting"])))
	for retired_good in ["lithium_ore", "lithium", "cobalt_ore", "cobalt", "graphite",
			"nickel_ore", "nickel", "platinum_group_ore", "platinum", "uranium_ore",
			"uranium_fuel"]:
		_expect("specific rare mineral is merged: %s" % retired_good,
			goods.find(retired_good) < 0)

	var kinds: PackedInt32Array = catalog.building_kinds
	var owners: PackedInt64Array = catalog.building_owner_slots
	var resource_offsets: PackedInt32Array = catalog.building_resource_offsets
	var output_offsets: PackedInt32Array = catalog.building_output_offsets
	var employee_offsets: PackedInt32Array = catalog.building_employee_offsets
	var role_reference_wages: PackedInt64Array = \
		catalog.building_employee_reference_wages_per_day
	var owner_professions: PackedInt32Array = catalog.building_owner_profession_ids
	var behavior_ids: PackedInt32Array = catalog.building_behavior_ids
	var merchant_profession := professions.find("merchant")
	var collectors := 0
	var used_resources := {}
	var production_resources: PackedInt32Array = catalog.building_production_resource_ids
	for type_id in range(buildings.size()):
		var expected_owner_slots := 1
		if buildings[type_id] in ["gathering_ground", "stone_age_hunting_camp"]:
			expected_owner_slots = 5
		elif buildings[type_id] == "household_weaving_shelter":
			expected_owner_slots = 2
		elif buildings[type_id] == "marine_fish_collector":
			expected_owner_slots = 3
		_expect("calibrated owner jobs: %s" % buildings[type_id],
			owners[type_id] == expected_owner_slots)
		_expect("building has physical output: %s" % buildings[type_id],
			output_offsets[type_id + 1] > output_offsets[type_id])
		_expect("building kind is collector or industry: %s" % buildings[type_id],
			kinds[type_id] in [0, 1])
		_expect("building behavior remains physical: %s" % buildings[type_id],
			behavior_ids[type_id] in [0, 1, 2])
		_expect("merchant owns only matching bullion collectors: %s" % buildings[type_id],
			owner_professions[type_id] != merchant_profession or
			buildings[type_id] in ["placer_gold_working", "surface_silver_working"])
		if employee_offsets[type_id + 1] > employee_offsets[type_id]:
			_expect("employee roles have positive reference wages: %s" % buildings[type_id],
				_range_positive(role_reference_wages, employee_offsets[type_id],
					employee_offsets[type_id + 1]))
		if kinds[type_id] == 0:
			collectors += 1
			_expect("collector has natural resource: %s" % buildings[type_id], resource_offsets[type_id + 1] > resource_offsets[type_id])
		else:
			_expect("industrial has no natural resource: %s" % buildings[type_id], resource_offsets[type_id + 1] == resource_offsets[type_id])
		for edge in range(resource_offsets[type_id], resource_offsets[type_id + 1]):
			used_resources[production_resources[edge]] = true
	_expect("collectors cover every referenced resource", collectors >= 50 and used_resources.size() == 30)
	var resource_modes: PackedInt32Array = catalog.building_production_resource_modes
	var resource_access_modes: PackedInt32Array = catalog.building_production_resource_access_modes
	var output_quantities: PackedInt64Array = catalog.building_output_quantities
	var farm_type := buildings.find("subsistence_farm")
	var farm_begin := int(resource_offsets[farm_type])
	var farm_end := int(resource_offsets[farm_type + 1])
	_expect("wheat farm uses capacity resources only", farm_type >= 0 and farm_end > farm_begin and
			_range_all(resource_modes, farm_begin, farm_end, 1))
	var marine_type := buildings.find("marine_fish_collector")
	_expect("single fishery chain produces early fish",
		marine_type >= 0 and output_quantities[output_offsets[marine_type]] > 0)
	_expect("shore fisheries use local plus adjacent water resources",
		resource_access_modes[resource_offsets[marine_type]] == 1)

	var issue_values: PackedInt64Array = catalog.good_monetary_issue_values
	var storage_modes: PackedInt32Array = catalog.good_storage_modes
	var good_categories: PackedStringArray = catalog.good_category_ids
	var substitution_category_offsets: PackedInt32Array = \
		catalog.good_substitution_category_offsets
	var substitution_category_ids: PackedStringArray = catalog.good_substitution_category_ids
	var issued := PackedStringArray()
	var flows := PackedStringArray()
	for good in range(goods.size()):
		if issue_values[good] > 0: issued.append(goods[good])
		if storage_modes[good] == 1: flows.append(goods[good])
	_expect("only gold and silver issue money", issued == PackedStringArray(["gold", "silver"]))
	_expect("gold to silver issue ratio is 80 to 1",
		issue_values[goods.find("gold")] == 800000 and issue_values[goods.find("silver")] == 10000)
	_expect("electricity is the only cycle-flow good", flows == PackedStringArray(["electricity"]))
	for retired_bucket in ["primary", "forestry", "construction", "food", "textile",
			"chemicals", "metals", "machinery", "consumer", "energy"]:
		_expect("industry bucket is not a substitution category: %s" % retired_bucket,
			not good_categories.has(retired_bucket))
	_expect("footwear is distinct from fabric, garments, and raw hide",
		good_categories[goods.find("footwear")] != good_categories[goods.find("cloth")] and
		good_categories[goods.find("footwear")] != good_categories[goods.find("clothing")] and
		good_categories[goods.find("footwear")] != good_categories[goods.find("raw_hide")])
	_expect("prime movers share a potential pool without forcing every recipe to use it",
		good_categories[goods.find("steam_engines")] == &"prime_mover" and
		good_categories[goods.find("electric_motor")] == &"prime_mover" and
		good_categories[goods.find("engines")] == &"prime_mover")
	_expect("multi-role substitution CSR aligns with stable goods",
		substitution_category_offsets.size() == goods.size() + 1 and
		substitution_category_offsets[0] == 0 and
		substitution_category_offsets[-1] == substitution_category_ids.size())
	_expect("one prime mover can serve several recipe-specific roles",
		_good_has_substitution_category(goods, substitution_category_offsets,
			substitution_category_ids, "steam_engines", "prime_mover") and
		_good_has_substitution_category(goods, substitution_category_offsets,
			substitution_category_ids, "steam_engines", "industrial_prime_mover") and
		_good_has_substitution_category(goods, substitution_category_offsets,
			substitution_category_ids, "steam_engines", "agricultural_prime_mover") and
		not _good_has_substitution_category(goods, substitution_category_offsets,
			substitution_category_ids, "electric_motor", "agricultural_prime_mover"))
	_expect("potatoes share the starch staple role without being labelled a cereal",
		_good_has_substitution_category(goods, substitution_category_offsets,
			substitution_category_ids, "potatoes", "starchy_staple") and
		not _good_has_substitution_category(goods, substitution_category_offsets,
			substitution_category_ids, "potatoes", "cereal_grain"))
	_expect("food oil and industrial lubricant remain separate roles",
		good_categories[goods.find("edible_oil")] !=
			good_categories[goods.find("lubricants")])
	_audit_subsistence_upgrade_families(catalog)
	var elasticity: PackedInt32Array = catalog.good_demand_price_elasticity_q16
	var excess_weights: PackedInt32Array = catalog.good_excess_demand_weight_q16
	var cost_weights: PackedInt32Array = catalog.good_cost_anchor_weight_q16
	var idle_weights: PackedInt32Array = catalog.good_inactive_reversion_weight_q16
	var business_alphas: PackedInt32Array = catalog.good_business_demand_ema_alpha_q16
	var supply_alphas: PackedInt32Array = catalog.good_supply_ema_alpha_q16
	var cost_alphas: PackedInt32Array = catalog.good_cost_ema_alpha_q16
	_expect("price v3 good columns align and remain in Q16 range",
		elasticity.size() == goods.size() and _range_between(elasticity, 1, 262144) and
		excess_weights.size() == goods.size() and _range_between(excess_weights, 0, 65536) and
		cost_weights.size() == goods.size() and _range_between(cost_weights, 0, 65536) and
		idle_weights.size() == goods.size() and _range_between(idle_weights, 0, 65536) and
		business_alphas.size() == goods.size() and _range_between(business_alphas, 0, 65536) and
		supply_alphas.size() == goods.size() and _range_between(supply_alphas, 0, 65536) and
		cost_alphas.size() == goods.size() and _range_between(cost_alphas, 0, 65536))
	var margins: PackedInt32Array = catalog.building_target_operating_margin_q16
	var supply_elasticity: PackedInt32Array = catalog.building_supply_price_elasticity_q16
	var share_offsets: PackedInt32Array = catalog.building_output_cost_share_offsets
	var shares: PackedInt32Array = catalog.building_output_cost_shares_q16
	_expect("profit-driven supply columns align and output cost shares are normalized",
		margins.size() == buildings.size() and _range_between(margins, 0, 65536) and
		supply_elasticity.size() == buildings.size() and _range_between(supply_elasticity, 0, 262144) and
		_cost_shares_valid(share_offsets, shares, buildings.size()))
	_expect("v6 compatibility hashes are emitted for pke v7 migration",
		int(catalog.get("market_catalog_compat_hash_v6", 0)) > 0 and
		int(catalog.get("building_catalog_compat_hash_v6", 0)) > 0)
	_expect("v7 compatibility hashes are emitted for pke v8 migration",
		int(catalog.get("market_catalog_compat_hash_v7", 0)) > 0 and
		int(catalog.get("building_catalog_compat_hash_v7", 0)) > 0)
	_expect("v8 compatibility hash is emitted for pke v9 technology migration",
		int(catalog.get("market_catalog_compat_hash_v8", 0)) > 0)
	var timber_type := buildings.find("timber_collector")
	var input_offsets: PackedInt32Array = catalog.building_input_offsets
	var candidate_offsets: PackedInt32Array = catalog.building_input_candidate_offsets
	var candidate_goods: PackedInt32Array = catalog.building_input_candidate_good_ids
	var candidate_efficiency: PackedInt32Array = catalog.building_input_candidate_efficiency_q16
	var timber_input := int(input_offsets[timber_type])
	var timber_candidate_begin := int(candidate_offsets[timber_input])
	var timber_candidate_end := int(candidate_offsets[timber_input + 1])
	var timber_candidates := candidate_goods.slice(timber_candidate_begin, timber_candidate_end)
	_expect("timber accepts stone, bronze, standard, and precision tool substitutes",
		timber_candidates.has(goods.find("chipped_stone_tools")) and
		timber_candidates.has(goods.find("bronze_tools")) and
		timber_candidates.has(goods.find("tools")) and
		timber_candidates.has(goods.find("precision_tools")))
	_expect("tool substitute efficiencies preserve historical productivity tiers",
		candidate_efficiency[timber_candidate_begin] > 0 and
		candidate_efficiency[timber_candidate_begin] < 65536)
	var bakery_type := buildings.find("bakery")
	var bakery_input := int(input_offsets[bakery_type])
	var bakery_begin := int(candidate_offsets[bakery_input])
	var bakery_end := int(candidate_offsets[bakery_input + 1])
	var bakery_candidates := candidate_goods.slice(bakery_begin, bakery_end)
	_expect("bakery uses recipe-specific grain candidates",
		bakery_candidates == PackedInt32Array([goods.find("corn_grain"), goods.find("grain"),
			goods.find("wheat_grain")]))
	_expect("recipe-specific candidate efficiencies are preserved",
		candidate_efficiency.slice(bakery_begin, bakery_end) ==
			PackedInt32Array([49152, 58982, 65536]))
	var footwear_type := buildings.find("footwear_plant")
	var footwear_upper_input := int(input_offsets[footwear_type])
	var footwear_sole_input := footwear_upper_input + 1
	_expect("industrial footwear accepts leather or cloth uppers",
		candidate_goods.slice(candidate_offsets[footwear_upper_input],
			candidate_offsets[footwear_upper_input + 1]) ==
			PackedInt32Array([goods.find("cloth"), goods.find("leather")]))
	_expect("industrial footwear accepts natural or synthetic rubber soles",
		candidate_goods.slice(candidate_offsets[footwear_sole_input],
			candidate_offsets[footwear_sole_input + 1]) ==
			PackedInt32Array([goods.find("latex"), goods.find("synthetic_rubber")]))
	var packaging_input := int(input_offsets[buildings.find("packaging_plant")])
	_expect("packaging accepts paper, glass, metal, or plastic feedstocks",
		candidate_goods.slice(candidate_offsets[packaging_input],
			candidate_offsets[packaging_input + 1]) == PackedInt32Array([
				goods.find("aluminum"), goods.find("glass"), goods.find("paper"),
				goods.find("plastics"), goods.find("steel")]))
	var wire_input := int(input_offsets[buildings.find("wire_plant")])
	_expect("wire accepts copper or aluminum conductors without consuming insulation",
		candidate_goods.slice(candidate_offsets[wire_input],
			candidate_offsets[wire_input + 1]) ==
			PackedInt32Array([goods.find("aluminum"), goods.find("copper")]))
	var cable_type := buildings.find("insulated_cable_plant")
	var cable_insulation_input := int(input_offsets[cable_type]) + 1
	_expect("insulated cable adds plastic or synthetic-rubber insulation to wire",
		candidate_goods.slice(candidate_offsets[cable_insulation_input],
			candidate_offsets[cable_insulation_input + 1]) ==
			PackedInt32Array([goods.find("plastics"), goods.find("synthetic_rubber")]))
	var machine_parts_lubricant_input := \
		int(input_offsets[buildings.find("machine_parts_plant")]) + 1
	_expect("early machine parts may use inefficient edible oil before mineral lubricant",
		candidate_goods.slice(candidate_offsets[machine_parts_lubricant_input],
			candidate_offsets[machine_parts_lubricant_input + 1]) ==
			PackedInt32Array([goods.find("edible_oil"), goods.find("lubricants")]))
	var soap_fat_input := int(input_offsets[buildings.find("soap_plant")])
	_expect("soap accepts vegetable oil or livestock fats contextually",
		candidate_goods.slice(candidate_offsets[soap_fat_input],
			candidate_offsets[soap_fat_input + 1]) ==
			PackedInt32Array([goods.find("edible_oil"), goods.find("livestock_products")]))
	var battery_material_input := int(input_offsets[buildings.find("batteries_plant")])
	_expect("generic batteries can transition from lead to advanced mineral chemistry",
		candidate_goods.slice(candidate_offsets[battery_material_input],
			candidate_offsets[battery_material_input + 1]) ==
			PackedInt32Array([goods.find("lead"), goods.find("rare_earth_metals")]))
	for inherited_recipe in [
		["method_packaging_plant_r7", 0,
			["aluminum", "glass", "paper", "plastics", "steel"]],
		["method_wire_plant_r10", 0, ["aluminum", "copper"]],
		["method_batteries_plant_r10", 0, ["lead", "rare_earth_metals"]],
		["method_machine_parts_plant_r9", 1, ["edible_oil", "lubricants"]],
		["method_insulated_cable_plant_r10", 1,
			["plastics", "synthetic_rubber"]],
	]:
		var inherited_type := buildings.find(String(inherited_recipe[0]))
		var inherited_input := int(input_offsets[inherited_type]) + int(inherited_recipe[1])
		var expected_candidates := PackedInt32Array()
		for good_id in inherited_recipe[2]:
			expected_candidates.append(goods.find(String(good_id)))
		_expect("upgraded recipe preserves contextual candidates: %s" % inherited_recipe[0],
			inherited_type >= 0 and
			candidate_goods.slice(candidate_offsets[inherited_input],
				candidate_offsets[inherited_input + 1]) == expected_candidates)
	var staple_type := buildings.find("staple_kitchen")
	var staple_input := int(input_offsets[staple_type])
	_expect("starch staple recipe includes potatoes alongside regional grains",
		candidate_goods.slice(candidate_offsets[staple_input],
			candidate_offsets[staple_input + 1]) == PackedInt32Array([
				goods.find("corn_grain"), goods.find("grain"), goods.find("potatoes"),
				goods.find("rice_grain"), goods.find("wheat_grain")]))
	var industrial_machinery_type := buildings.find("industrial_machinery_plant")
	var industrial_prime_mover_input := int(input_offsets[industrial_machinery_type]) + 1
	var industrial_prime_mover_begin := int(candidate_offsets[industrial_prime_mover_input])
	var industrial_prime_mover_end := int(candidate_offsets[industrial_prime_mover_input + 1])
	_expect("industrial machinery accepts only steam or electric prime movers",
		candidate_goods.slice(industrial_prime_mover_begin, industrial_prime_mover_end) ==
			PackedInt32Array([goods.find("electric_motor"), goods.find("steam_engines")]))
	var agricultural_machinery_type := buildings.find("agricultural_machinery_plant")
	var agricultural_prime_mover_input := int(input_offsets[agricultural_machinery_type]) + 1
	var agricultural_prime_mover_begin := int(candidate_offsets[agricultural_prime_mover_input])
	var agricultural_prime_mover_end := int(candidate_offsets[agricultural_prime_mover_input + 1])
	_expect("agricultural machinery accepts combustion or steam but not electric motors",
		candidate_goods.slice(agricultural_prime_mover_begin, agricultural_prime_mover_end) ==
			PackedInt32Array([goods.find("engines"), goods.find("steam_engines")]))
	var goldsmith_type := buildings.find("goldsmith_workshop")
	var goldsmith_input := int(input_offsets[goldsmith_type])
	_expect("precious-metal role expands to gold and silver",
		candidate_goods.slice(candidate_offsets[goldsmith_input],
			candidate_offsets[goldsmith_input + 1]) ==
			PackedInt32Array([goods.find("gold"), goods.find("silver")]))
	var guild_weaving_type := buildings.find("guild_weaving_house")
	var guild_fiber_input := int(input_offsets[guild_weaving_type])
	_expect("guild fiber role stays narrower than the global spinnable-fiber role",
		candidate_goods.slice(candidate_offsets[guild_fiber_input],
			candidate_offsets[guild_fiber_input + 1]) ==
			PackedInt32Array([goods.find("flax_fiber"), goods.find("wool")]))
	var bricks_type := buildings.find("bricks_plant")
	var bricks_input := int(input_offsets[bricks_type])
	var bricks_begin := int(candidate_offsets[bricks_input])
	var bricks_end := int(candidate_offsets[bricks_input + 1])
	_expect("exact-good input compiles as one Q16 candidate",
		candidate_goods.slice(bricks_begin, bricks_end) ==
			PackedInt32Array([goods.find("clay")]) and
		candidate_efficiency.slice(bricks_begin, bricks_end) == PackedInt32Array([65536]))
	var technologies: PackedStringArray = catalog.get("technology_ids", PackedStringArray())
	for technology in ["tech.hunting", "tech.bronze_casting", "tech.writing",
			"tech.guild_organization", "tech.oceanic_navigation", "tech.steam_power",
			"tech.electrification", "tech.nuclear_fission", "tech.digital_computing",
			"tech.machine_learning", "tech.autonomous_systems"]:
		_expect("cross-era technology tag exists: %s" % technology,
			technologies.find(technology) >= 0)
	_expect("legacy metadata namespaces are not executable technologies",
		_not_contains_prefix(technologies, "industry.") and
		technologies.find("tech.legacy_modern_economy") < 0)
	_expect("every good has an executable technology requirement",
		_all_ranges_have_tech(catalog.good_technology_tag_offsets,
			catalog.good_technology_tags, goods.size()))
	_expect("every building has an executable technology requirement",
		_all_ranges_have_tech(catalog.building_technology_tag_offsets,
			catalog.building_technology_tags, buildings.size()))
	_expect("every profession has an executable technology requirement",
		_all_ranges_have_tech(catalog.profession_technology_tag_offsets,
			catalog.profession_technology_tags, professions.size()))

	var consumed := {}
	var input_goods: PackedInt32Array = catalog.building_input_good_ids
	for good_id in input_goods: consumed[int(good_id)] = true
	var input_candidates: PackedInt32Array = catalog.building_input_candidate_good_ids
	for good_id in input_candidates: consumed[int(good_id)] = true
	var household_goods: PackedInt32Array = catalog.component_good_ids
	for good_id in household_goods: consumed[int(good_id)] = true
	for good in range(goods.size()):
		_expect("good has downstream use or monetary issue: %s" % goods[good],
			consumed.has(good) or issue_values[good] > 0 or
			goods[good] in ["railway_equipment", "oceanic_vessels"])


func _audit_household_consumption(catalog: Dictionary) -> void:
	var goods: PackedStringArray = catalog.good_ids
	var needs: PackedStringArray = catalog.need_ids
	var need_names: Dictionary = EconomyCatalogScript.need_display_names()
	var expected_need_names := {
		"staple_food": "食品", "protein": "食品", "produce": "食品",
		"clothing": "衣着", "housing": "居住维护", "household_goods": "家庭用品",
		"hygiene": "清洁卫生", "healthcare": "医疗保健", "home_energy": "家庭能源",
		"transport": "个人交通", "communication": "通信",
		"education_culture": "教育与文化", "recreation": "休闲娱乐",
		"durable_goods": "耐用消费品", "work_equipment": "职业装备",
		"luxury": "奢侈消费", "status_goods": "身份消费",
	}
	for need_id in expected_need_names:
		_expect("household need has Chinese display name: %s" % need_id,
			String(need_names.get(need_id, "")) == String(expected_need_names[need_id]))

	var household_good_indices: PackedInt32Array = catalog.component_good_ids
	var actual_household_goods := PackedStringArray()
	for good_idx in household_good_indices:
		if good_idx >= 0 and good_idx < goods.size() and not actual_household_goods.has(goods[good_idx]):
			actual_household_goods.append(goods[good_idx])
	actual_household_goods.sort()
	var expected_household_goods := PackedStringArray([
		"prepared_staples", "bread", "grain", "gathered_plants", "game_meat", "meat", "fish",
		"canned_fish", "dairy_products", "vegetables", "processed_food", "cloth", "fur",
		"clothing", "footwear", "construction_components", "pottery", "furniture", "soap",
		"detergent", "medicinal_herbs", "pharmaceuticals", "logs", "coal", "natural_gas",
		"refined_fuel", "horses", "automobiles", "radio_equipment", "telecom_equipment",
		"manuscripts", "printed_materials", "computers", "beverages", "household_appliances",
		"autonomous_systems", "chipped_stone_tools", "bronze_tools", "tools", "precision_tools",
		"fine_clothing", "fine_furniture", "jewelry", "spices",
	])
	expected_household_goods.sort()
	_expect("direct household good coverage is exact",
		actual_household_goods == expected_household_goods)
	for capital_good in ["railway_equipment", "oceanic_vessels", "scientific_instruments",
			"electricity"]:
		_expect("capital or cycle-flow good stays outside household demand: %s" % capital_good,
			not household_good_indices.has(goods.find(capital_good)))

	var plan_ids: PackedStringArray = catalog.plan_ids
	var plan_offsets: PackedInt32Array = catalog.plan_need_offsets
	var need_stable_ids: PackedInt32Array = catalog.need_stable_ids
	var need_base: PackedInt64Array = catalog.need_base_qty_per_person
	var need_wealth: PackedInt32Array = catalog.need_wealth_elasticity_q16
	var need_min: PackedInt32Array = catalog.need_wealth_min_q16
	var need_max: PackedInt32Array = catalog.need_wealth_max_q16
	var need_variant_offsets: PackedInt32Array = catalog.need_variant_offsets
	var variant_price: PackedInt32Array = catalog.variant_price_elasticity_q16
	var variant_component_offsets: PackedInt32Array = catalog.variant_component_offsets
	var component_quantities: PackedInt64Array = catalog.component_qty_per_need
	var core_needs := ["staple_food", "protein", "produce", "clothing", "housing",
		"household_goods", "hygiene", "healthcare", "home_energy"]
	var expected_plan_needs := {
		"survival_household": core_needs,
		"agrarian_household": core_needs + ["transport", "work_equipment", "recreation"],
		"extractive_household": core_needs + ["transport", "work_equipment"],
		"industrial_worker_household": core_needs + ["transport", "work_equipment"],
		"artisan_household": core_needs + ["education_culture", "work_equipment", "luxury"],
		"technical_household": core_needs + ["transport", "communication", "education_culture",
			"recreation", "durable_goods", "work_equipment", "luxury"],
		"merchant_household": core_needs + ["transport", "communication", "education_culture",
			"recreation", "durable_goods", "luxury", "status_goods"],
		"owner_household": core_needs + ["transport", "communication", "education_culture",
			"recreation", "durable_goods", "luxury", "status_goods"],
	}
	var plan_scales := {
		"survival_household": [80, 35, 0], "agrarian_household": [95, 75, 0],
		"extractive_household": [105, 85, 0], "industrial_worker_household": [100, 85, 0],
		"artisan_household": [105, 105, 80], "technical_household": [110, 125, 120],
		"merchant_household": [115, 150, 180], "owner_household": [120, 175, 240],
	}
	var need_policies := {
		"staple_food": [550, 0, 4096, 49152, 81920, 98304],
		"protein": [180, 0, 16384, 32768, 131072, 98304],
		"produce": [300, 0, 16384, 32768, 131072, 98304],
		"clothing": [3, 0, 32768, 16384, 196608, 65536],
		"housing": [5, 0, 32768, 16384, 196608, 65536],
		"household_goods": [2, 1, 49152, 8192, 262144, 49152],
		"hygiene": [10, 0, 32768, 16384, 196608, 65536],
		"healthcare": [3, 0, 32768, 16384, 196608, 32768],
		"home_energy": [80, 0, 32768, 16384, 196608, 65536],
		"transport": [3, 1, 49152, 8192, 262144, 49152],
		"communication": [1, 1, 49152, 8192, 262144, 49152],
		"education_culture": [2, 1, 49152, 8192, 262144, 49152],
		"recreation": [3, 1, 49152, 8192, 262144, 49152],
		"durable_goods": [1, 2, 65536, 4096, 393216, 32768],
		"work_equipment": [2, 1, 49152, 8192, 262144, 49152],
		"luxury": [1, 2, 98304, 1024, 524288, 32768],
		"status_goods": [1, 2, 98304, 1024, 524288, 32768],
	}
	var expected_variants := {
		"staple_food": ["prepared_staples", "bread", "grain", "gathered_plants"],
		"protein": ["game_meat", "meat", "fish", "canned_fish", "dairy_products"],
		"produce": ["vegetables", "processed_food"],
		"clothing": ["cloth", "fur", "clothing", "footwear"],
		"housing": ["construction_components"], "household_goods": ["pottery", "furniture"],
		"hygiene": ["soap", "detergent"],
		"healthcare": ["medicinal_herbs", "pharmaceuticals"],
		"home_energy": ["logs", "coal", "natural_gas", "refined_fuel"],
		"transport": ["horses", "automobiles+refined_fuel"],
		"communication": ["radio_equipment", "telecom_equipment"],
		"education_culture": ["manuscripts", "printed_materials", "computers"],
		"recreation": ["beverages", "computers"],
		"durable_goods": ["household_appliances", "autonomous_systems"],
		"work_equipment": ["chipped_stone_tools", "bronze_tools", "tools", "precision_tools"],
		"luxury": ["beverages", "fine_clothing", "fine_furniture"],
		"status_goods": ["jewelry", "fur", "spices"],
	}
	var allowed_cross_uses := {
		"refined_fuel": ["home_energy", "transport"],
		"computers": ["education_culture", "recreation"],
		"beverages": ["recreation", "luxury"],
		"fur": ["clothing", "status_goods"],
	}
	for plan_idx in range(plan_ids.size()):
		var plan_id := String(plan_ids[plan_idx])
		var plan_needs := PackedStringArray()
		for cursor in range(plan_offsets[plan_idx], plan_offsets[plan_idx + 1]):
			plan_needs.append(needs[need_stable_ids[cursor]])
		var expected_needs: Array = expected_plan_needs.get(plan_id, [])
		var scales: Array = plan_scales.get(plan_id, [])
		var exact := plan_needs.size() <= 16 \
			and ",".join(plan_needs) == ",".join(expected_needs) and scales.size() == 3
		var good_uses := {}
		for local_need_idx in range(plan_needs.size()):
			var cursor := int(plan_offsets[plan_idx]) + local_need_idx
			var need_id := String(plan_needs[local_need_idx])
			var policy: Array = need_policies.get(need_id, [])
			if policy.size() != 6:
				exact = false
				continue
			var expected_base := maxi(1, int(floor(
				(float(policy[0]) * float(scales[policy[1]]) + 50.0) / 100.0)))
			exact = exact and need_base[cursor] == expected_base \
				and need_wealth[cursor] == policy[2] and need_min[cursor] == policy[3] \
				and need_max[cursor] == policy[4]
			var variant_begin := int(need_variant_offsets[cursor])
			var variant_end := int(need_variant_offsets[cursor + 1])
			exact = exact and variant_end > variant_begin and variant_end - variant_begin <= 8
			var actual_variants := PackedStringArray()
			for variant_idx in range(variant_begin, variant_end):
				exact = exact and variant_price[variant_idx] == policy[5]
				var component_begin := int(variant_component_offsets[variant_idx])
				var component_end := int(variant_component_offsets[variant_idx + 1])
				exact = exact and component_end > component_begin \
					and component_end - component_begin <= 4
				var signature := PackedStringArray()
				for component_idx in range(component_begin, component_end):
					var good_id := String(goods[household_good_indices[component_idx]])
					signature.append(good_id)
					exact = exact and component_quantities[component_idx] == 1000
					var uses: Array = good_uses.get(good_id, [])
					if not uses.has(need_id):
						uses.append(need_id)
					good_uses[good_id] = uses
				actual_variants.append("+".join(signature))
			actual_variants.sort()
			var expected_need_variants := PackedStringArray(expected_variants.get(need_id, []))
			expected_need_variants.sort()
			exact = exact and actual_variants == expected_need_variants
		for good_id in good_uses:
			var uses: Array = good_uses[good_id]
			if uses.size() <= 1:
				continue
			var expected_uses: Array = allowed_cross_uses.get(good_id, [])
			var filtered_expected := PackedStringArray()
			for expected_use in expected_uses:
				if plan_needs.has(expected_use):
					filtered_expected.append(expected_use)
			var actual_uses := PackedStringArray(uses)
			filtered_expected.sort()
			actual_uses.sort()
			exact = exact and allowed_cross_uses.has(good_id) \
				and actual_uses == filtered_expected
		_expect("consumption prototype compiles exact policy and classification: %s" % plan_id, exact)

	var expected_professions := {
		"owner_household": ["landlord", "industrialist"],
		"merchant_household": ["merchant"],
		"survival_household": ["subsistence_farmer", "forager", "enslaved_laborer", "serf", "apprentice"],
		"agrarian_household": ["agricultural_worker", "pastoralist", "hunter", "fisher", "forestry_worker", "tenant_farmer", "indentured_laborer"],
		"extractive_household": ["miner", "petroleum_worker"],
		"industrial_worker_household": ["worker", "construction_worker", "industrial_worker", "transport_worker"],
		"artisan_household": ["artisan", "metallurgist", "guild_master", "journeyman"],
		"technical_household": ["machinist", "technician", "engineer", "chemist", "electrician", "manager", "researcher"],
	}
	var professions: PackedStringArray = catalog.profession_ids
	var ethnicity_count: int = (catalog.ethnicity_ids as PackedStringArray).size()
	var signature_plan_ids: PackedInt32Array = catalog.signature_plan_ids
	for plan_id in expected_professions:
		var expected_plan_idx := plan_ids.find(plan_id)
		var mapping_ok := expected_plan_idx >= 0
		for profession_id in expected_professions[plan_id]:
			var profession_idx := professions.find(String(profession_id))
			mapping_ok = mapping_ok and profession_idx >= 0 \
				and int(signature_plan_ids[profession_idx * ethnicity_count]) == expected_plan_idx
		_expect("profession group uses expected consumption prototype: %s" % plan_id, mapping_ok)


func _audit_explicit_candidate_validation() -> void:
	var good_index := {"corn_grain": 0, "grain": 1, "wheat_grain": 2, "rice_grain": 3}
	var valid = _candidate_profile()
	_expect("valid explicit candidate CSR passes validation",
		EconomyCatalogScript._validate_explicit_input_candidates(valid, good_index) == "")

	var nonzero_start = _candidate_profile()
	nonzero_start.input_candidate_offsets = PackedInt32Array([1, 3])
	_expect("explicit candidate CSR must start at zero",
		"columns mismatch" in EconomyCatalogScript._validate_explicit_input_candidates(
			nonzero_start, good_index))

	var nonmonotonic = _candidate_profile()
	nonmonotonic.input_good_ids = PackedStringArray(["wheat_grain", "corn_grain"])
	nonmonotonic.input_category_ids = PackedStringArray(["", ""])
	nonmonotonic.input_candidate_offsets = PackedInt32Array([0, 3, 2])
	nonmonotonic.input_candidate_good_ids = PackedStringArray(["wheat_grain", "grain"])
	nonmonotonic.input_candidate_efficiency_q16 = PackedInt32Array([65536, 58982])
	_expect("explicit candidate CSR must be monotonic",
		"offsets invalid" in EconomyCatalogScript._validate_explicit_input_candidates(
			nonmonotonic, good_index))

	var efficiency_mismatch = _candidate_profile()
	efficiency_mismatch.input_candidate_efficiency_q16 = PackedInt32Array([65536, 58982])
	_expect("candidate goods and efficiencies must align",
		"columns mismatch" in EconomyCatalogScript._validate_explicit_input_candidates(
			efficiency_mismatch, good_index))

	var duplicate = _candidate_profile()
	duplicate.input_candidate_good_ids = PackedStringArray(
		["wheat_grain", "grain", "wheat_grain"])
	_expect("an explicit slot rejects duplicate goods",
		"invalid building explicit" in EconomyCatalogScript._validate_explicit_input_candidates(
			duplicate, good_index))

	var invalid_efficiency = _candidate_profile()
	invalid_efficiency.input_candidate_efficiency_q16 = PackedInt32Array([0, 58982, 49152])
	_expect("explicit candidate efficiency stays inside 1..262144",
		"invalid building explicit" in EconomyCatalogScript._validate_explicit_input_candidates(
			invalid_efficiency, good_index))

	var missing_preferred = _candidate_profile()
	missing_preferred.input_candidate_good_ids = PackedStringArray(
		["corn_grain", "grain", "rice_grain"])
	_expect("representative good must belong to its explicit slot",
		"preferred building input missing" in EconomyCatalogScript._validate_explicit_input_candidates(
			missing_preferred, good_index))

	var category_conflict = _candidate_profile()
	category_conflict.input_category_ids = PackedStringArray(["grain"])
	_expect("category and explicit candidates are mutually exclusive per slot",
		"cannot combine category" in EconomyCatalogScript._validate_explicit_input_candidates(
			category_conflict, good_index))


func _candidate_profile():
	var profile = BuildingProfileScript.new()
	profile.input_good_ids = PackedStringArray(["wheat_grain"])
	profile.input_category_ids = PackedStringArray([""])
	profile.input_candidate_offsets = PackedInt32Array([0, 3])
	profile.input_candidate_good_ids = PackedStringArray(
		["wheat_grain", "grain", "corn_grain"])
	profile.input_candidate_efficiency_q16 = PackedInt32Array([65536, 58982, 49152])
	return profile


func _audit_subsistence_upgrade_families(catalog: Dictionary) -> void:
	var buildings: PackedStringArray = catalog.building_type_ids
	var family_ids: PackedStringArray = catalog.building_upgrade_family_ids
	var family_indices: PackedInt32Array = catalog.building_upgrade_family_indices
	var tiers: PackedInt32Array = catalog.building_upgrade_tiers
	var expected := {
		"subsistence_food": [
			["gathering_ground", 1, 7000],
			["subsistence_farm", 2, 8000],
			["three_field_smallholding", 3, 12000],
			["improved_smallholding", 4, 16000],
		],
		"household_cloth": [
			["household_weaving_shelter", 1, 600],
			["household_loom", 2, 1320],
			["cottage_weaving", 3, 2400],
			["improved_domestic_loom", 4, 3600],
		],
	}
	var output_offsets: PackedInt32Array = catalog.building_output_offsets
	var output_quantities: PackedInt64Array = catalog.building_output_quantities
	var input_offsets: PackedInt32Array = catalog.building_input_offsets
	var employee_offsets: PackedInt32Array = catalog.building_employee_offsets
	for family_id in expected:
		var family_index := family_ids.find(family_id)
		_expect("upgrade family exists: %s" % family_id, family_index >= 0)
		var previous_output := 0
		for row in expected[family_id]:
			var type_id := buildings.find(row[0])
			var total_output := 0
			if type_id >= 0:
				for edge in range(output_offsets[type_id], output_offsets[type_id + 1]):
					total_output += int(output_quantities[edge])
			_expect("upgrade tier is unique and aligned: %s" % row[0],
				type_id >= 0 and family_indices[type_id] == family_index and
				tiers[type_id] == row[1])
			_expect("subsistence tier has no market input or employees: %s" % row[0],
				type_id >= 0 and input_offsets[type_id] == input_offsets[type_id + 1] and
				employee_offsets[type_id] == employee_offsets[type_id + 1])
			_expect("subsistence output is calibrated and rises: %s" % row[0],
				total_output == row[2] and total_output > previous_output)
			previous_output = total_output


func _range_all(values: PackedInt32Array, begin: int, end: int, expected: int) -> bool:
	for i in range(begin, end):
		if i < 0 or i >= values.size() or int(values[i]) != expected:
			return false
	return true


func _good_has_substitution_category(goods: PackedStringArray, offsets: PackedInt32Array,
		categories: PackedStringArray, good_id: String, category_id: String) -> bool:
	var good_idx := goods.find(good_id)
	if good_idx < 0 or good_idx + 1 >= offsets.size():
		return false
	for edge in range(offsets[good_idx], offsets[good_idx + 1]):
		if String(categories[edge]) == category_id:
			return true
	return false


func _range_positive(values: PackedInt64Array, begin: int, end: int) -> bool:
	for i in range(begin, end):
		if i < 0 or i >= values.size() or int(values[i]) <= 0:
			return false
	return true

func _sum_i64(values: PackedInt64Array) -> int:
	var total := 0
	for value in values:
		total += int(value)
	return total

func _all_ranges_have_tech(offsets: PackedInt32Array, tags: PackedStringArray,
		item_count: int) -> bool:
	if offsets.size() != item_count + 1:
		return false
	for item in range(item_count):
		var found := false
		for edge in range(offsets[item], offsets[item + 1]):
			found = found or String(tags[edge]).begins_with("tech.")
		if not found:
			return false
	return true

func _not_contains_prefix(values: PackedStringArray, prefix: String) -> bool:
	for value in values:
		if String(value).begins_with(prefix):
			return false
	return true

func _range_between(values: PackedInt32Array, minimum: int, maximum: int) -> bool:
	for value in values:
		if value < minimum or value > maximum:
			return false
	return true

func _cost_shares_valid(offsets: PackedInt32Array, shares: PackedInt32Array, type_count: int) -> bool:
	if offsets.size() != type_count + 1 or offsets[0] != 0 or offsets[-1] != shares.size():
		return false
	for type_id in range(type_count):
		var begin := int(offsets[type_id])
		var end := int(offsets[type_id + 1])
		if begin < 0 or end < begin or end > shares.size():
			return false
		if end > begin:
			var total := 0
			for edge in range(begin, end):
				total += int(shares[edge])
			if total != 65536:
				return false
	return true
