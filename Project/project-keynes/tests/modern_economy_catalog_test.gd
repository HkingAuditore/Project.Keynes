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
	_expect("at least 120 goods", goods.size() >= 120)
	_expect("at least 90 buildings", buildings.size() >= 90)
	_expect("39 cross-era professions", professions.size() == 39)
	_expect("exactly 15 household needs", needs.size() == 15)
	_expect("41 registered terrestrial resources", ResourceRegistryScript.count() == 41)
	_expect("all registered resources enter building catalog", resources.size() == 41)
	for retired_crop in ["wheat", "rice", "corn", "potato", "rubber_tree",
			"spice_plants", "flax", "cotton", "medicinal_herbs"]:
		_expect("cultivated crop is not a natural resource: %s" % retired_crop,
			resources.find(retired_crop) < 0)
	for capacity_id in ["arable_land", "paddy_land", "plantation_land"]:
		_expect("agricultural capacity resource exists: %s" % capacity_id,
			resources.find(capacity_id) >= 0)
	var corn_farm = load("res://data/economy/buildings/landed_estate.tres")
	var wheat_farm = load("res://data/economy/buildings/subsistence_farm.tres")
	_expect("corn collector is named 玉米农场", corn_farm != null and String(corn_farm.display_name) == "玉米农场")
	_expect("wheat collector is named 小麦农场", wheat_farm != null and String(wheat_farm.display_name) == "小麦农场")
	_expect("water resources use explicit geographic habitats",
		ResourceRegistryScript.habitat_code(ResourceRegistryScript.ordered().filter(
			func(p): return String(p.id) == "marine_fish")[0]) == 2 and
		ResourceRegistryScript.habitat_code(ResourceRegistryScript.ordered().filter(
			func(p): return String(p.id) == "fresh_water")[0]) == 3 and
		ResourceRegistryScript.habitat_code(ResourceRegistryScript.ordered().filter(
			func(p): return String(p.id) == "freshwater_fish")[0]) == 3)
	var flint_resource = ResourceRegistryScript.ordered().filter(
		func(p): return String(p.id) == "flint")[0]
	var lithium_resource = ResourceRegistryScript.ordered().filter(
		func(p): return String(p.id) == "lithium")[0]
	_expect("early flint deposit is visible without prospecting",
		ResourceRegistryScript.discovery_visible(flint_resource, PackedStringArray()))
	_expect("lithium deposit visibility is separate from physical existence",
		not ResourceRegistryScript.discovery_visible(lithium_resource, PackedStringArray()) and
		ResourceRegistryScript.discovery_visible(lithium_resource,
			PackedStringArray(["tech.geological_prospecting"])))

	var kinds: PackedInt32Array = catalog.building_kinds
	var owners: PackedInt64Array = catalog.building_owner_slots
	var resource_offsets: PackedInt32Array = catalog.building_resource_offsets
	var output_offsets: PackedInt32Array = catalog.building_output_offsets
	var employee_offsets: PackedInt32Array = catalog.building_employee_offsets
	var wages: PackedInt64Array = catalog.building_wage_per_employee_per_day
	var collectors := 0
	var used_resources := {}
	var production_resources: PackedInt32Array = catalog.building_production_resource_ids
	for type_id in range(buildings.size()):
		_expect("one owner job: %s" % buildings[type_id], owners[type_id] == 1)
		_expect("building has output: %s" % buildings[type_id], output_offsets[type_id + 1] > output_offsets[type_id])
		if employee_offsets[type_id + 1] > employee_offsets[type_id]:
			_expect("employee building has positive wage: %s" % buildings[type_id], wages[type_id] > 0)
		if kinds[type_id] == 0:
			collectors += 1
			_expect("collector has natural resource: %s" % buildings[type_id], resource_offsets[type_id + 1] > resource_offsets[type_id])
		else:
			_expect("industrial has no natural resource: %s" % buildings[type_id], resource_offsets[type_id + 1] == resource_offsets[type_id])
		for edge in range(resource_offsets[type_id], resource_offsets[type_id + 1]):
			used_resources[production_resources[edge]] = true
	_expect("at least one collector per resource", collectors >= 41 and used_resources.size() == 41)
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
	var technologies: PackedStringArray = catalog.get("technology_ids", PackedStringArray())
	for technology in ["tech.hunting", "tech.bronze_casting", "tech.writing",
			"tech.guild_organization", "tech.oceanic_navigation", "tech.steam_power",
			"tech.electrification", "tech.nuclear_fission", "tech.digital_computing",
			"tech.machine_learning", "tech.deep_space_systems"]:
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
	var household_goods: PackedInt32Array = catalog.component_good_ids
	for good_id in household_goods: consumed[int(good_id)] = true
	for good in range(goods.size()):
		_expect("good has downstream use or monetary issue: %s" % goods[good],
			consumed.has(good) or issue_values[good] > 0)


func _range_all(values: PackedInt32Array, begin: int, end: int, expected: int) -> bool:
	for i in range(begin, end):
		if i < 0 or i >= values.size() or int(values[i]) != expected:
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
