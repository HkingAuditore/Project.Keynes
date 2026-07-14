extends SceneTree

const EconomyCatalogScript = preload("res://scripts/economy/economy_catalog.gd")
const ResourceRegistryScript = preload("res://scripts/data/resource_profile_registry.gd")

var failures := 0

func _init() -> void:
	var catalog: Dictionary = EconomyCatalogScript.compile_native_catalog()
	_expect("modern economy catalog compiles", bool(catalog.get("ok", false)))
	if bool(catalog.get("ok", false)):
		_audit(catalog)
	else:
		print(catalog)
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
	_expect("audited catalog has 142 goods", goods.size() == 142)
	_expect("audited catalog has 174 buildings", buildings.size() == 174)
	_expect("32 labor-relation professions", professions.size() == 32)
	_expect("exactly 15 household needs", needs.size() == 15)
	_expect("35 registered terrestrial resources", ResourceRegistryScript.count() == 35)
	_expect("all registered resources enter building catalog", resources.size() == 35)
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
	for capacity_id in ["arable_land", "paddy_land", "plantation_land"]:
		_expect("agricultural capacity resource exists: %s" % capacity_id,
			resources.find(capacity_id) >= 0)
	var corn_farm = load("res://data/economy/buildings/landed_estate.tres")
	var wheat_farm = load("res://data/economy/buildings/wheat_farm.tres")
	_expect("corn collector is named 玉米农场", corn_farm != null and String(corn_farm.display_name) == "玉米农场")
	_expect("wheat collector is named 小麦农场", wheat_farm != null and String(wheat_farm.display_name) == "小麦农场")
	var gathering = load("res://data/economy/buildings/gathering_ground.tres")
	var early_gold = load("res://data/economy/buildings/placer_gold_working.tres")
	var early_silver = load("res://data/economy/buildings/surface_silver_working.tres")
	var bronze_foundry = load("res://data/economy/buildings/bronze_foundry.tres")
	var guild_hall = load("res://data/economy/buildings/guild_hall.tres")
	var steam_works = load("res://data/economy/buildings/steam_engine_works.tres")
	_expect("stone production is owner-operated",
		String(gathering.owner_profession_id) == "forager" and
		gathering.employee_profession_ids.is_empty())
	_expect("early bullion production is owner-operated and input-free",
		String(early_gold.owner_profession_id) == "merchant" and
		String(early_silver.owner_profession_id) == "merchant" and
		early_gold.input_good_ids.is_empty() and early_silver.input_good_ids.is_empty() and
		early_gold.employee_profession_ids.is_empty() and
		early_silver.employee_profession_ids.is_empty() and
		early_gold.technology_tags.has("tech.gathering") and
		early_silver.technology_tags.has("tech.gathering"))
	_expect("bronze workshop uses a small apprentice household",
		String(bronze_foundry.owner_profession_id) == "artisan" and
		bronze_foundry.employee_profession_ids == PackedStringArray(["apprentice"]) and
		bronze_foundry.employee_slots_per_building == PackedInt64Array([4]))
	_expect("guild production distinguishes apprentices and journeymen",
		String(guild_hall.owner_profession_id) == "guild_master" and
		guild_hall.employee_profession_ids == PackedStringArray(["apprentice", "journeyman"]))
	_expect("steam factory introduces workers, engineers, and management",
		steam_works.employee_profession_ids ==
			PackedStringArray(["industrial_worker", "engineer", "manager"]))
	for retired_building in ["shell_money_station", "software_studio", "network_data_center",
			"digital_service_exchange", "ai_research_lab", "orbital_research_program",
			"orbital_technology_transfer", "deep_space_telemetry_program"]:
		_expect("retired pseudo-service building removed: %s" % retired_building,
			buildings.find(retired_building) < 0)
	_expect("water resources use explicit geographic habitats",
		ResourceRegistryScript.habitat_code(ResourceRegistryScript.ordered().filter(
			func(p): return String(p.id) == "marine_fish")[0]) == 2 and
		ResourceRegistryScript.habitat_code(ResourceRegistryScript.ordered().filter(
			func(p): return String(p.id) == "fresh_water")[0]) == 3 and
		ResourceRegistryScript.habitat_code(ResourceRegistryScript.ordered().filter(
			func(p): return String(p.id) == "freshwater_fish")[0]) == 3)
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
		_expect("one owner job: %s" % buildings[type_id], owners[type_id] == 1)
		_expect("building has physical output: %s" % buildings[type_id],
			output_offsets[type_id + 1] > output_offsets[type_id])
		_expect("building kind is collector or industry: %s" % buildings[type_id],
			kinds[type_id] in [0, 1])
		_expect("building behavior remains physical: %s" % buildings[type_id],
			behavior_ids[type_id] in [0, 1, 2])
		_expect("merchant owns only early bullion collectors: %s" % buildings[type_id],
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
	_expect("at least one collector per resource", collectors >= 35 and used_resources.size() == 35)
	var resource_modes: PackedInt32Array = catalog.building_production_resource_modes
	var resource_access_modes: PackedInt32Array = catalog.building_production_resource_access_modes
	var output_quantities: PackedInt64Array = catalog.building_output_quantities
	var farm_type := buildings.find("subsistence_farm")
	var farm_begin := int(resource_offsets[farm_type])
	var farm_end := int(resource_offsets[farm_type + 1])
	_expect("wheat farm uses capacity resources only", farm_type >= 0 and farm_end > farm_begin and
			_range_all(resource_modes, farm_begin, farm_end, 1))
	var marine_type := buildings.find("marine_fish_collector")
	var freshwater_type := buildings.find("freshwater_fish_collector")
	_expect("marine and freshwater fisheries retain distinct daily yields",
		output_quantities[output_offsets[marine_type]] == 1000 and
		output_quantities[output_offsets[freshwater_type]] == 400)
	_expect("shore fisheries use local plus adjacent water resources",
		resource_access_modes[resource_offsets[marine_type]] == 1 and
		resource_access_modes[resource_offsets[freshwater_type]] == 1)

	var issue_values: PackedInt64Array = catalog.good_monetary_issue_values
	var storage_modes: PackedInt32Array = catalog.good_storage_modes
	var issued := PackedStringArray()
	var flows := PackedStringArray()
	for good in range(goods.size()):
		if issue_values[good] > 0: issued.append(goods[good])
		if storage_modes[good] == 1: flows.append(goods[good])
	_expect("only gold and silver issue money", issued == PackedStringArray(["gold", "silver"]))
	_expect("gold to silver issue ratio is 80 to 1",
		issue_values[goods.find("gold")] == 800000 and issue_values[goods.find("silver")] == 10000)
	_expect("electricity is the only cycle-flow good", flows == PackedStringArray(["electricity"]))
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
	var technologies: PackedStringArray = catalog.get("technology_ids", PackedStringArray())
	for technology in ["tech.hunting", "tech.bronze_casting", "tech.writing",
			"tech.guild_organization", "tech.oceanic_navigation", "tech.steam_power",
			"tech.electrification", "tech.nuclear_fission", "tech.digital_computing",
			"tech.machine_learning", "tech.autonomous_systems"]:
		_expect("cross-era technology tag exists: %s" % technology,
			technologies.find(technology) >= 0)
	_expect("legacy metadata namespaces are not executable technologies",
		_not_contains_prefix(technologies, "industry."))
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
			consumed.has(good) or issue_values[good] > 0)


func _audit_subsistence_upgrade_families(catalog: Dictionary) -> void:
	var buildings: PackedStringArray = catalog.building_type_ids
	var family_ids: PackedStringArray = catalog.building_upgrade_family_ids
	var family_indices: PackedInt32Array = catalog.building_upgrade_family_indices
	var tiers: PackedInt32Array = catalog.building_upgrade_tiers
	var expected := {
		"subsistence_food": [
			["gathering_ground", 1, 3000],
			["subsistence_farm", 2, 8000],
			["three_field_smallholding", 3, 12000],
			["improved_smallholding", 4, 16000],
		],
		"household_cloth": [
			["household_weaving_shelter", 1, 120],
			["household_loom", 2, 220],
			["cottage_weaving", 3, 400],
			["improved_domestic_loom", 4, 600],
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


func _range_positive(values: PackedInt64Array, begin: int, end: int) -> bool:
	for i in range(begin, end):
		if i < 0 or i >= values.size() or int(values[i]) <= 0:
			return false
	return true

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
