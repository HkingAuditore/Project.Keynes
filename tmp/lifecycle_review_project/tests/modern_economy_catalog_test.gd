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
	_audit_construction_category_validation()
	if bool(catalog.get("ok", false)):
		_audit_construction_substitution_breadth(catalog)
	print("=== modern economy catalog %s ===" % ("PASS" if failures == 0 else "FAIL"))
	quit(0 if failures == 0 else 1)

func _expect(label: String, condition: bool) -> void:
	print("  [%s] %s" % ["PASS" if condition else "FAIL", label])
	if not condition: failures += 1

func _audit_knowledge_building_owners(catalog: Dictionary,
		_buildings: PackedStringArray, _professions: PackedStringArray) -> void:
	var sectors: PackedInt32Array = catalog.get("building_economic_sectors", PackedInt32Array())
	var owners: PackedInt32Array = catalog.get("building_owner_profession_ids", PackedInt32Array())
	var profession_classes: PackedStringArray = catalog.get(
		"profession_class_ids", PackedStringArray())
	var goods: PackedStringArray = catalog.get("good_ids", PackedStringArray())
	var output_offsets: PackedInt32Array = catalog.get(
		"building_output_offsets", PackedInt32Array())
	var output_goods: PackedInt32Array = catalog.get(
		"building_output_good_ids", PackedInt32Array())
	var points_good := goods.find("technology_points")
	var knowledge_count := 0
	var points_count := 0
	for building_idx in range(_buildings.size()):
		var owner_idx := int(owners[building_idx]) if building_idx < owners.size() else -1
		var owner_class := String(profession_classes[owner_idx]) \
			if owner_idx >= 0 and owner_idx < profession_classes.size() else ""
		if building_idx < sectors.size() and int(sectors[building_idx]) == 4:
			knowledge_count += 1
			_expect("knowledge building owner is a technology profession: %s" %
				_buildings[building_idx], owner_class == "technology")
		if _building_outputs_good(output_offsets, output_goods, building_idx, points_good):
			points_count += 1
			_expect("technology-points producer owner is a technology profession: %s" %
				_buildings[building_idx], owner_class == "technology")
	_expect("knowledge building owner invariant covers all knowledge buildings",
		knowledge_count > 0)
	_expect("technology-points producer owner invariant covers all producers",
		points_count > 0)


func _audit_starter_knowledge_routes() -> void:
	var expected := {
		"early_knowledge_institution": {
			"output": 2000, "climate": "", "resource": "",
			"construction": PackedStringArray(["logs", "bast_fiber"]),
		},
		"oral_memory_circle": {
			"output": 1000, "climate": "", "resource": "",
			"construction": PackedStringArray(["logs", "bast_fiber"]),
		},
		"seasonal_observation_shelter": {
			"output": 1500, "climate": "phenology_observation", "resource": "",
			"construction": PackedStringArray(["logs", "bast_fiber"]),
		},
		"pastoral_council_tent": {
			"output": 1600, "climate": "pasture_livestock", "resource": "pasture",
			"construction": PackedStringArray(["turf_block", "bast_fiber"]),
		},
		"tide_observation_hut": {
			"output": 1700, "climate": "", "resource": "",
			"construction": PackedStringArray(["reed_bundle", "bast_fiber"]),
		},
		"flood_calendar_shrine": {
			"output": 1800, "climate": "", "resource": "paddy_land",
			"construction": PackedStringArray(["reed_bundle", "bast_fiber"]),
		},
	}
	for building_id in expected:
		var profile: BuildingProfile = load(
			"res://data/economy/buildings/%s.tres" % building_id)
		var spec: Dictionary = expected[building_id]
		_expect("starter knowledge route stays a lorekeeper workshop: %s" % building_id,
			profile != null and String(profile.economic_sector_id) == "knowledge"
			and String(profile.owner_profession_id) == "lorekeeper"
			and profile.owner_slots_per_building == 2
			and profile.employee_profession_ids.is_empty()
			and profile.output_good_ids == PackedStringArray(["technology_points"]))
		if profile == null:
			continue
		_expect("starter knowledge route has a distinct catalog yield: %s" % building_id,
			profile.output_quantities_per_day == PackedInt64Array([int(spec.output)]))
		_expect("starter knowledge route uses local construction: %s" % building_id,
			profile.construction_good_ids == spec.construction)
		_expect("starter knowledge climate matches the opening biome: %s" % building_id,
			String(profile.production_climate_profile_id) == String(spec.climate))
		var resource_id := String(spec.resource)
		if resource_id == "":
			_expect("universal starter knowledge has no geography gate: %s" % building_id,
				profile.condition_opcodes.is_empty())
		else:
			_expect("specialized starter knowledge requires local carrying capacity: %s" %
				building_id, profile.condition_opcodes == PackedInt32Array([1])
				and profile.condition_signals == PackedInt32Array([10])
				and profile.condition_compares == PackedInt32Array([4])
				and profile.condition_reference_ids == PackedStringArray([resource_id])
				and profile.condition_values == PackedInt64Array([0]))


func _building_outputs_good(offsets: PackedInt32Array, goods: PackedInt32Array,
		building_idx: int, good_idx: int) -> bool:
	if good_idx < 0 or building_idx < 0 or building_idx + 1 >= offsets.size():
		return false
	for edge in range(int(offsets[building_idx]), int(offsets[building_idx + 1])):
		if int(goods[edge]) == good_idx:
			return true
	return false


func _audit_two_owner_early_buildings() -> void:
	# Totals are building-level (already scaled for two owner slots). Freshwater
	# remains a one-owner soft-tool camp; the two-owner set is the shared early
	# craft/collector conversion family.
	var expected := {
		"marine_fish_collector": {
			"input": PackedInt64Array([66, 200]), "output": PackedInt64Array([4181]),
			"resource": PackedInt64Array([279]), "owners": 2},
		"bast_wrap_shelter": {
			"input": PackedInt64Array([3251, 200]), "output": PackedInt64Array([1083]),
			"resource": PackedInt64Array(), "owners": 2},
		"hide_scraping_shelter": {
			"input": PackedInt64Array([5231, 200]), "output": PackedInt64Array([1463]),
			"resource": PackedInt64Array(), "owners": 2},
		"fur_sewing_shelter": {
			"input": PackedInt64Array([4429, 200]), "output": PackedInt64Array([3467]),
			"resource": PackedInt64Array(), "owners": 2},
		"felt_making_tent": {
			"input": PackedInt64Array([7502, 200]), "output": PackedInt64Array([4875]),
			"resource": PackedInt64Array(), "owners": 2},
		"stone_collector": {
			"input": PackedInt64Array([200]), "output": PackedInt64Array([6968]),
			"resource": PackedInt64Array([3163]), "owners": 2},
		"timber_collector": {
			"input": PackedInt64Array([200]), "output": PackedInt64Array([6968]),
			"resource": PackedInt64Array([2346]), "owners": 2},
		"adobe_yard": {
			"input": PackedInt64Array([14203, 1420, 200]), "output": PackedInt64Array([6500]),
			"resource": PackedInt64Array(), "owners": 2},
		"freshwater_fishing_camp": {
			"input": PackedInt64Array([100]), "output": PackedInt64Array([1560]),
			"resource": PackedInt64Array([104]), "owners": 1},
	}
	for building_id in expected:
		var profile: BuildingProfile = load(
			"res://data/economy/buildings/%s.tres" % building_id)
		var row: Dictionary = expected[building_id]
		var owners := int(row.owners)
		_expect("early self-operated building has two owners and no employees: %s" %
			building_id, profile != null and profile.owner_slots_per_building == owners and
			profile.employee_profession_ids.is_empty() and
			profile.employee_slots_per_building.is_empty())
		if profile == null:
			continue
		_expect("two-owner conversion preserves per-owner throughput: %s" % building_id,
			profile.input_quantities_per_day == row.input and
			profile.output_quantities_per_day == row.output and
			profile.resource_quantities_per_day == row.resource)


func _scale_i64(values: PackedInt64Array, factor: int) -> PackedInt64Array:
	var out := PackedInt64Array()
	for value in values:
		out.append(int(value) * factor)
	return out


func _audit_zero_cost_starter_construction() -> void:
	var zero_cost_ids := PackedStringArray([
		"deadwood_gathering_camp", "earth_digging_pit", "reed_cutting_camp",
		"turf_cutting_ground", "rubble_stone_working",
	])
	for building_id in zero_cost_ids:
		var profile: BuildingProfile = load(
			"res://data/economy/buildings/%s.tres" % building_id)
		_expect("stone-age construction collector is a zero-bill lot: %s" % building_id,
			profile != null
			and EconomyCatalogScript.allows_zero_cost_construction(profile)
			and profile.construction_good_ids.is_empty()
			and profile.construction_quantities.is_empty())
	for building_id in ["gathering_ground", "stone_age_hunting_camp",
			"bast_fiber_camp", "timber_collector", "stone_collector", "adobe_yard"]:
		var profile: BuildingProfile = load(
			"res://data/economy/buildings/%s.tres" % building_id)
		_expect("later or food buildings keep an explicit construction bill: %s" %
			building_id, profile != null and not profile.construction_good_ids.is_empty()
			and not EconomyCatalogScript.allows_zero_cost_construction(profile))


func _audit_soft_complement_policy(catalog: Dictionary) -> void:
	const MINT_IDS := {
		"placer_gold_working": true,
		"surface_silver_working": true,
		"shallow_silver_working": true,
		"primitive_gold_sluice": true,
	}
	const PRODUCTIVITY_GOODS := {
		"tools": true,
		"chipped_stone_tools": true,
		"bronze_tools": true,
		"precision_tools": true,
		"fertilizer": true,
		"farm_machinery": true,
		"agricultural_machinery": true,
		"industrial_machinery": true,
	}
	const PRODUCTIVITY_CATEGORIES := {
		"tools": true,
		"fertilizer": true,
		"farm_machinery": true,
	}
	var building_ids: PackedStringArray = catalog.building_type_ids
	for building_id in building_ids:
		var profile: BuildingProfile = load(
			"res://data/economy/buildings/%s.tres" % building_id)
		if profile == null:
			_expect("soft-complement profile loads: %s" % building_id, false)
			continue
		var input_count := profile.input_good_ids.size()
		if input_count > 0:
			_expect("authored inputs keep matching required_q16: %s" % building_id,
				profile.input_required_q16.size() == input_count)
		var has_soft_complement := false
		for slot in range(input_count):
			var good_id := String(profile.input_good_ids[slot])
			var category_id := String(profile.input_category_ids[slot]) \
				if slot < profile.input_category_ids.size() else ""
			var required_q16 := 65536
			if slot < profile.input_required_q16.size():
				required_q16 = int(profile.input_required_q16[slot])
			var productivity := PRODUCTIVITY_GOODS.has(good_id) \
				or PRODUCTIVITY_CATEGORIES.has(category_id)
			if productivity:
				_expect("productivity complement stays soft: %s[%d]" % [building_id, slot],
					required_q16 < 65536)
				if PRODUCTIVITY_CATEGORIES.has("tools") and (category_id == "tools" \
						or good_id == "tools" or good_id.ends_with("_tools")):
					_expect("tool slot uses the tools category: %s[%d]" % [building_id, slot],
						category_id == "tools")
				if required_q16 < 65536:
					has_soft_complement = true
			elif required_q16 < 65536:
				has_soft_complement = true
		var skip_extractor := MINT_IDS.has(String(building_id)) \
			or String(profile.economic_sector_id) == "knowledge" \
			or String(profile.building_kind) == "service" \
			or String(profile.upgrade_family_id) == "household_cloth"
		if String(profile.building_kind) == "collector" \
				and not profile.resource_ids.is_empty() and not skip_extractor:
			_expect("extractive collector keeps a soft complement: %s" % building_id,
				has_soft_complement)


func _audit(catalog: Dictionary) -> void:
	var goods: PackedStringArray = catalog.good_ids
	var buildings: PackedStringArray = catalog.building_type_ids
	var professions: PackedStringArray = catalog.profession_ids
	var needs: PackedStringArray = catalog.need_ids
	var resources: PackedStringArray = catalog.building_resource_ids
	_audit_knowledge_building_owners(catalog, buildings, professions)
	_audit_starter_knowledge_routes()
	_audit_two_owner_early_buildings()
	_audit_zero_cost_starter_construction()
	_audit_soft_complement_policy(catalog)
	_audit_household_consumption_contract(catalog)
	_expect("network economy catalog has 134 goods", goods.size() == 134)
	_expect("network economy has 400 production methods", buildings.size() == 400)
	_expect("45 labor, institutional and research professions", professions.size() == 45)
	_expect("20 differentiated household needs", needs.size() == 20)
	_expect("31 registered natural resources", ResourceRegistryScript.count() == 31)
	_expect("building catalog references 31 distinct natural resources", resources.size() == 31)
	_audit_production_climate(catalog, buildings)
	for relation_profession in ["enslaved_laborer", "serf", "tenant_farmer",
			"indentured_laborer", "apprentice", "journeyman", "manager", "researcher"]:
		_expect("labor relation profession exists: %s" % relation_profession,
			professions.find(relation_profession) >= 0)

	for retired_profession in ["knapper", "potter", "bronze_founder", "mason",
			"printer", "shipwright", "navigator", "steam_engineer", "electrical_engineer",
			"nuclear_engineer", "software_developer",
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
	for retired_resource in ["cattle", "sheep", "pigs", "horses", "fresh_water"]:
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
	_expect("eleven consumption prototypes compile",
		catalog.plan_ids == PackedStringArray(["agrarian_household", "artisan_household",
			"extractive_household", "hunter_household", "industrial_worker_household",
			"merchant_household",
			"owner_household", "plan_unemployed", "scholarly_household", "survival_household",
			"technical_household"]))
	_expect("occupational and status needs compile",
		needs.has("work_equipment") and needs.has("status_goods"))
	var corn_farm = load("res://data/economy/buildings/landed_estate.tres")
	var wheat_farm = load("res://data/economy/buildings/wheat_farm.tres")
	_expect("corn collector remains an estate crop building",
		corn_farm != null and String(corn_farm.id) == "landed_estate" and
		corn_farm.resource_ids.has("arable_land"))
	_expect("wheat collector remains an arable crop building",
		wheat_farm != null and String(wheat_farm.id) == "wheat_farm" and
		wheat_farm.resource_ids.has("arable_land"))
	var construction_offsets: PackedInt32Array = catalog.building_construction_offsets
	var construction_quantities: PackedInt64Array = catalog.building_construction_quantities
	var construction_candidate_offsets: PackedInt32Array = \
		catalog.building_construction_candidate_offsets
	var construction_candidate_goods: PackedInt32Array = \
		catalog.building_construction_candidate_good_ids
	var every_building_is_pooled := true
	for building_index in range(buildings.size()):
		if int(construction_offsets[building_index + 1]) \
				- int(construction_offsets[building_index]) > 1:
			every_building_is_pooled = false
			break
	_expect("every building compiles to at most one construction pool",
		every_building_is_pooled)
	var placer_index: int = buildings.find("placer_gold_working")
	var placer_group := int(construction_offsets[placer_index])
	var placer_candidates := PackedStringArray()
	for candidate_edge in range(construction_candidate_offsets[placer_group],
			construction_candidate_offsets[placer_group + 1]):
		placer_candidates.append(goods[construction_candidate_goods[candidate_edge]])
	_expect("placer construction is one pooled bill with interchangeable materials",
		placer_index >= 0 and
		int(construction_offsets[placer_index + 1]) == placer_group + 1 and
		int(construction_quantities[placer_group]) == 2912 and
		placer_candidates.has("logs") and placer_candidates.has("bast_fiber") and
		placer_candidates.has("reed_bundle"))
	var stone_hunting = load(
		"res://data/economy/buildings/stone_age_hunting_camp.tres")
	_expect("stone hunting uses a soft tool complement at half capacity floor",
		stone_hunting != null and
		stone_hunting.input_good_ids == PackedStringArray(["tools"]) and
		stone_hunting.input_quantities_per_day == PackedInt64Array([100]) and
		stone_hunting.input_required_q16 == PackedInt32Array([32768]) and
		stone_hunting.input_category_ids == PackedStringArray(["tools"]))
	var stone_collector = load("res://data/economy/buildings/stone_collector.tres")
	var timber_collector = load("res://data/economy/buildings/timber_collector.tres")
	var bronze_tools = load("res://data/economy/buildings/bronze_tool_workshop.tres")
	var ore_bronze = load("res://data/economy/buildings/ore_bronzesmith_camp.tres")
	_expect("early collectors keep tool maintenance below local workshop output",
		stone_collector.owner_slots_per_building == 2 and
		timber_collector.owner_slots_per_building == 2 and
		stone_collector.input_quantities_per_day == PackedInt64Array([200]) and
		timber_collector.input_quantities_per_day == PackedInt64Array([200]) and
		stone_collector.input_required_q16 == PackedInt32Array([32768]) and
		timber_collector.input_required_q16 == PackedInt32Array([32768]) and
		stone_collector.input_quantities_per_day[0] /
			stone_collector.owner_slots_per_building == 100 and
		timber_collector.input_quantities_per_day[0] /
			timber_collector.owner_slots_per_building == 100)
	_expect("bronze workshops avoid material-cost dominated recipes",
		bronze_tools.input_quantities_per_day == PackedInt64Array([2857, 952]) and
		ore_bronze.input_quantities_per_day == PackedInt64Array([700, 300, 200]))
	var early_gold = load("res://data/economy/buildings/placer_gold_working.tres")
	var early_silver = load("res://data/economy/buildings/surface_silver_working.tres")
	var hearth = load("res://data/economy/buildings/communal_hearth.tres")
	var knapping = load("res://data/economy/buildings/knapping_workshop.tres")
	var early_weaving = load("res://data/economy/buildings/household_weaving_shelter.tres")
	_expect("stone production chains have physical, demand-scaled inputs",
		hearth.input_good_ids.find("gathered_plants") >= 0 and
		hearth.input_good_ids.find("game_meat") >= 0 and
		hearth.input_good_ids.find("tools") >= 0 and
		hearth.input_required_q16[hearth.input_good_ids.find("tools")] == 32768 and
		knapping.construction_good_ids == PackedStringArray(["logs", "flint"]) and
		knapping.construction_quantities == PackedInt64Array([24905, 12452]) and
		knapping.input_good_ids == PackedStringArray(["flint"]) and
		knapping.input_quantities_per_day.size() == 1 and
		knapping.input_quantities_per_day[0] > 0 and
		knapping.output_quantities_per_day.size() == 1 and
		knapping.output_quantities_per_day[0] > 0 and
		early_weaving.construction_good_ids == PackedStringArray(
			["logs", "gathered_plants"]) and
		early_weaving.construction_quantities == PackedInt64Array([17642, 35284]) and
		early_weaving.input_good_ids == PackedStringArray(["gathered_plants"]) and
		early_weaving.input_quantities_per_day == PackedInt64Array([1764]) and
		early_weaving.output_quantities_per_day == PackedInt64Array([813]) and
		String(early_weaving.building_kind) == "industrial")
	_expect("primitive logging extracts rather than creates timber",
		timber_collector.resource_generation_ids.is_empty() and
		String(timber_collector.behavior_id) == "consume_local_resources")
	_expect("early gold employment and wage scale is bounded",
		early_gold.owner_slots_per_building == 1 and
		early_gold.employee_profession_ids == PackedStringArray(["miner"]) and
		early_gold.employee_slots_per_building == PackedInt64Array([1]) and
		early_gold.employee_reference_wages_per_day == PackedInt64Array([40000]))
	var bronze_workshop = load("res://data/economy/buildings/bronze_tool_workshop.tres")
	var guild_hall = load("res://data/economy/buildings/guild_hall.tres")
	var steam_works = load("res://data/economy/buildings/steam_engine_works.tres")
	var stone_owner_policy := {
		"communal_hearth": "artisan", "flint_quarry": "forager",
		"gathering_ground": "forager", "household_weaving_shelter": "artisan",
		"knapping_workshop": "artisan", "lumber_plant": "artisan",
		"marine_fish_collector": "fisher",
		"stone_age_hunting_camp": "hunter", "stone_collector": "forager",
		"timber_collector": "forager",
	}
	for building_id in stone_owner_policy:
		var stone_building = load("res://data/economy/buildings/%s.tres" % building_id)
		_expect("stone production is owner-operated: %s" % building_id,
			stone_building != null and
			String(stone_building.owner_profession_id) == stone_owner_policy[building_id] and
			stone_building.employee_profession_ids.is_empty())
	_expect("stone hunting sustains its hunter and yields hides plus wearable fur",
		stone_hunting != null and
		stone_hunting.output_good_ids == PackedStringArray(["game_meat", "raw_hide", "fur"]) and
		stone_hunting.output_quantities_per_day == PackedInt64Array([1560, 72, 72]) and
		stone_hunting.output_quantities_per_day[0] >= 171 and
		stone_hunting.output_quantities_per_day[0] >
			stone_hunting.output_quantities_per_day[1] and
		stone_hunting.output_quantities_per_day[1] ==
			stone_hunting.output_quantities_per_day[2] and
		stone_hunting.resource_quantities_per_day == PackedInt64Array([326]) and
		stone_hunting.owner_slots_per_building == 1)
	_expect("rough bullion sites are merchant-owned mint collectors",
		String(early_gold.owner_profession_id) == "merchant" and
		String(early_silver.owner_profession_id) == "merchant" and
		early_gold.input_good_ids.is_empty() and early_silver.input_good_ids.is_empty() and
		early_gold.output_good_ids == PackedStringArray(["gold"]) and
		early_silver.output_good_ids == PackedStringArray(["silver"]) and
		early_gold.output_quantities_per_day == PackedInt64Array([100]) and
		early_gold.resource_quantities_per_day == PackedInt64Array([50]) and
		early_silver.output_quantities_per_day == PackedInt64Array([1000]) and
		early_silver.resource_quantities_per_day == PackedInt64Array([200]) and
		early_silver.employee_profession_ids == PackedStringArray(["miner"]) and
		early_silver.employee_slots_per_building == PackedInt64Array([2]) and
		early_gold.technology_tags.has("tech.gold_panning") and
		early_silver.technology_tags.has("tech.surface_silver_collection"))
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
		iron_tool_workshop.technology_tags.has("tech.iron_smelting") and
		iron_tool_workshop.required_technology_tags.has("tech.surface_iron_collection") and
		iron_tool_workshop.input_good_ids == PackedStringArray(["wrought_iron", "charcoal"]) and
		iron_tool_workshop.output_good_ids == PackedStringArray(["tools"]))
	_expect("steam steel tools are a later method for the same good",
		steel_tool_plant != null and steel_tool_plant.technology_tags.has("tech.machine_tools") and
		steel_tool_plant.output_good_ids == PackedStringArray(["tools"]))
	_expect("precision tools start before steam and require metal-quality tools",
		precision_tool_workshop != null and
		precision_tool_workshop.technology_tags.has("tech.precision_engineering") and
		precision_tool_workshop.input_category_ids == PackedStringArray(["tools", "", ""]) and
		precision_tool_workshop.input_min_quality_levels == PackedInt32Array([3, 0, 0]))
	var canning_workshop = load("res://data/economy/buildings/canning_workshop.tres")
	var canned_fish_plant = load("res://data/economy/buildings/canned_fish_plant.tres")
	_expect("canning begins in Enlightenment and industrializes with steam",
		canning_workshop != null and canned_fish_plant != null and
		canning_workshop.technology_tags.has("tech.canning") and
		canning_workshop.required_technology_tags.has("tech.experimental_science") and
		canned_fish_plant.technology_tags.has("tech.canning") and
		canned_fish_plant.required_technology_tags.has("tech.steam_power") and
		canned_fish_plant.required_technology_tags.has("tech.industrial_organization"))
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
	var tide_observation_hut = load(
		"res://data/economy/buildings/tide_observation_hut.tres")
	_expect("coastal knowledge observation is owned by a knowledge profession",
		tide_observation_hut != null and
		String(tide_observation_hut.owner_profession_id) == "lorekeeper" and
		tide_observation_hut.output_good_ids == PackedStringArray(["technology_points"]))
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
	_expect("marine resources use explicit coastal-land habitats",
		ResourceRegistryScript.habitat_code(ResourceRegistryScript.ordered().filter(
			func(p): return String(p.id) == "marine_fish")[0]) == 5)
	var flint_resource = ResourceRegistryScript.ordered().filter(
		func(p): return String(p.id) == "flint")[0]
	var rare_earth_resource = ResourceRegistryScript.ordered().filter(
		func(p): return String(p.id) == "rare_earth")[0]
	_expect("flint deposit requires local material identification",
		not ResourceRegistryScript.discovery_visible(flint_resource, PackedStringArray()) and
		ResourceRegistryScript.discovery_visible(flint_resource,
			PackedStringArray(["tech.flint_identification"])))
	_expect("abstract rare-earth deposit requires mineral spectral surveying",
		not ResourceRegistryScript.discovery_visible(rare_earth_resource, PackedStringArray()) and
		ResourceRegistryScript.discovery_visible(rare_earth_resource,
			PackedStringArray(["tech.mineral_spectral_survey"])))
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
		_expect("calibrated owner-operated households: %s" % buildings[type_id],
			owners[type_id] >= 1 and owners[type_id] <= 3)
		_expect("building has physical output: %s" % buildings[type_id],
			buildings[type_id] in ["merchant_post", "early_merchant_post"] or
			output_offsets[type_id + 1] > output_offsets[type_id])
		_expect("building kind is collector, industry, or service: %s" % buildings[type_id],
			kinds[type_id] in [0, 1, 2])
		_expect("building behavior remains physical: %s" % buildings[type_id],
			behavior_ids[type_id] in [0, 1, 2])
		_expect("merchant owns only matching bullion collectors: %s" % buildings[type_id],
			owner_professions[type_id] != merchant_profession or
			buildings[type_id] in ["merchant_post", "early_merchant_post", "placer_gold_working",
				"surface_silver_working"])
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
	_expect("collectors cover every referenced resource", collectors >= 50 and used_resources.size() == 31)
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
	_expect("every natural resource edge is strictly local",
		_range_all(resource_access_modes, 0, resource_access_modes.size(), 0))

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
	_expect("gold and silver issue values cover early mine labor and owner livelihood",
		issue_values[goods.find("gold")] == 800000 and issue_values[goods.find("silver")] == 50000)
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
	_expect("industrial footwear accepts raw latex, coagulated natural rubber, or synthetic rubber soles",
		candidate_goods.slice(candidate_offsets[footwear_sole_input],
			candidate_offsets[footwear_sole_input + 1]) ==
			PackedInt32Array([goods.find("latex"), goods.find("natural_rubber"),
				goods.find("synthetic_rubber")]))
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
			PackedInt32Array([goods.find("bast_fiber"), goods.find("flax_fiber"),
				goods.find("wool")]))
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
	_expect("professions are unlocked indirectly by buildings and jobs",
		_all_ranges_exclude_tech(catalog.profession_technology_tag_offsets,
			catalog.profession_technology_tags, professions.size()))

	var consumed := {}
	var input_goods: PackedInt32Array = catalog.building_input_good_ids
	for good_id in input_goods: consumed[int(good_id)] = true
	var input_candidates: PackedInt32Array = catalog.building_input_candidate_good_ids
	for good_id in input_candidates: consumed[int(good_id)] = true
	var construction_goods: PackedInt32Array = catalog.building_construction_good_ids
	for good_id in construction_goods: consumed[int(good_id)] = true
	var household_goods: PackedInt32Array = catalog.component_good_ids
	for good_id in household_goods: consumed[int(good_id)] = true
	for good in range(goods.size()):
		_expect("good has downstream use or monetary issue: %s" % goods[good],
			consumed.has(good) or issue_values[good] > 0 or
			goods[good] in ["railway_equipment", "oceanic_vessels"])


func _audit_household_consumption_contract(catalog: Dictionary) -> void:
	var goods: PackedStringArray = catalog.good_ids
	var needs: PackedStringArray = catalog.need_ids
	var plans: PackedStringArray = catalog.plan_ids
	var plan_offsets: PackedInt32Array = catalog.plan_need_offsets
	var need_stable: PackedInt32Array = catalog.need_stable_ids
	var need_offsets: PackedInt32Array = catalog.need_variant_offsets
	var variant_goods: PackedInt32Array = catalog.component_good_ids
	var variant_components: PackedInt32Array = catalog.variant_component_offsets
	var wealth_delta: PackedInt32Array = catalog.variant_class_wealth_elasticity_delta_q16
	var threshold_factor: PackedInt32Array = catalog.variant_class_savings_threshold_factor_q16
	_expect("class response columns cover every compiled variant",
		wealth_delta.size() == variant_goods.size() and
		threshold_factor.size() == variant_goods.size())
	var good_wealth: PackedInt32Array = catalog.good_household_wealth_elasticity_q16
	var good_thresholds: PackedInt32Array = catalog.good_household_savings_threshold_months_q16
	_expect("per-good household response columns align",
		good_wealth.size() == goods.size() and good_thresholds.size() == goods.size())
	var wheat_index := goods.find("wheat_grain")
	var gathered_index := goods.find("gathered_plants")
	var batteries_index := goods.find("batteries")
	_expect("cultivated staple has positive wealth response and no savings gate",
		wheat_index >= 0 and good_wealth[wheat_index] > 0 and
		good_thresholds[wheat_index] == 0)
	_expect("subsistence gathering stays immediately available",
		gathered_index >= 0 and good_thresholds[gathered_index] == 0)
	_expect("discretionary batteries have a savings gate",
		batteries_index >= 0 and good_thresholds[batteries_index] > 0)
	var staples := ["prepared_staples", "bread", "grain", "wheat_grain",
		"rice_grain", "corn_grain", "potatoes", "gathered_plants"]
	var expected_variants := {
		"staple_food": ["prepared_staples", "bread", "grain", "wheat_grain",
			"rice_grain", "corn_grain", "potatoes", "gathered_plants"],
		"protein": ["game_meat", "meat", "fish", "canned_fish", "dairy_products"],
		"produce": ["vegetables", "processed_food"],
		"food_fat": ["edible_oil"], "seasoning": ["salt", "spices"],
		"clothing": ["cloth", "fur", "clothing", "footwear"],
		"housing": ["reed_bundle+bast_fiber", "turf_block+lumber",
			"adobe_brick+lumber", "raw_stone+lime+lumber", "bricks+lime+lumber",
			"cement+glass+steel", "concrete+steel+glass", "construction_components"],
		"household_goods": ["furniture", "leather_goods"],
		"domestic_wares": ["pottery", "glassware", "metal_housewares"],
		"hygiene": ["soap", "detergent"],
		"healthcare": ["medicinal_herbs", "pharmaceuticals"],
		"home_energy": ["logs", "charcoal", "coal", "natural_gas", "refined_fuel",
			"electricity"],
		"transport": ["horses", "automobiles+refined_fuel"],
		"communication": ["radio_equipment", "telecom_equipment",
		"radio_equipment+batteries", "telecom_equipment+batteries"],
		"education_culture": ["manuscripts", "paper", "printed_materials",
			"computers"],
		"recreation": ["beverages", "computers"],
		"durable_goods": ["household_appliances", "autonomous_systems"],
		"work_equipment": ["chipped_stone_tools", "bronze_tools", "tools", "precision_tools"],
		"luxury": ["beverages", "fine_clothing", "fine_furniture"],
		"status_goods": ["jewelry", "fur"],
	}
	var seen_goods := {}
	for plan_idx in range(plans.size()):
		var plan_id := String(plans[plan_idx])
		var begin := int(plan_offsets[plan_idx])
		var end := int(plan_offsets[plan_idx + 1])
		var staple_need := -1
		for row in range(begin, end):
			var need_id := String(needs[int(need_stable[row])])
			if need_id == "staple_food":
				staple_need = row
			var variant_begin := int(need_offsets[row])
			var variant_end := int(need_offsets[row + 1])
			var actual_variants := PackedStringArray()
			for variant_row in range(variant_begin, variant_end):
				var component_begin := int(variant_components[variant_row])
				var component_end := int(variant_components[variant_row + 1])
				var signature := PackedStringArray()
				for component_row in range(component_begin, component_end):
					var component_good := String(goods[int(variant_goods[component_row])])
					signature.append(component_good)
					seen_goods[component_good] = true
				actual_variants.append("+".join(signature))
			actual_variants.sort()
			var expected_for_need := PackedStringArray(expected_variants.get(need_id, []))
			if plan_id == "technical_household" and need_id == "education_culture":
				expected_for_need = PackedStringArray([
					"manuscripts+technology_points",
					"paper+technology_points",
					"printed_materials+technology_points",
					"computers+technology_points"])
			expected_for_need.sort()
			_expect("plan variant contract: %s/%s" % [plan_id, need_id],
				actual_variants == expected_for_need)
			_expect("class response columns align: %s/%s" % [plan_id, need_id],
				wealth_delta.size() >= variant_end and
				threshold_factor.size() >= variant_end)
		_expect("plan has exact eight staple variants: %s" % plan_id,
			staple_need >= 0 and
			int(need_offsets[staple_need + 1]) - int(need_offsets[staple_need]) == 8)
		if staple_need < 0:
			continue
		var staple_begin := int(need_offsets[staple_need])
		var staple_end := int(need_offsets[staple_need + 1])
		for variant in range(staple_begin, staple_end):
			var component_begin := int(variant_components[variant])
			var component_end := int(variant_components[variant + 1])
			var good := goods[int(variant_goods[component_begin])]
			_expect("staple good is approved: %s/%s" % [plan_id, good],
				component_end - component_begin == 1 and good in staples)
	for required_good in ["glassware", "metal_housewares", "leather_goods"]:
		_expect("new terminal good exists: %s" % required_good,
			goods.find(required_good) >= 0)
	for required_need in ["food_fat", "seasoning", "domestic_wares"]:
		_expect("new resident need exists: %s" % required_need,
			needs.find(required_need) >= 0)
	var actual_household_goods := PackedStringArray()
	for good_id in seen_goods.keys():
		actual_household_goods.append(String(good_id))
	actual_household_goods.sort()
	var expected_household_goods := PackedStringArray([
		"prepared_staples", "bread", "grain", "wheat_grain", "rice_grain", "corn_grain",
		"gathered_plants", "potatoes", "game_meat", "meat", "fish", "canned_fish",
		"dairy_products", "vegetables", "processed_food", "edible_oil", "salt", "spices",
		"cloth", "fur", "clothing", "footwear", "reed_bundle", "bast_fiber", "turf_block",
		"lumber", "adobe_brick", "raw_stone", "lime", "bricks", "cement", "glass", "steel",
		"concrete", "construction_components", "furniture", "leather_goods", "pottery", "glassware",
		"metal_housewares", "soap", "detergent", "medicinal_herbs", "pharmaceuticals", "logs",
		"charcoal", "coal", "natural_gas", "refined_fuel", "electricity", "horses", "automobiles",
		"radio_equipment", "telecom_equipment", "batteries", "manuscripts", "paper",
		"printed_materials", "computers", "beverages", "household_appliances", "autonomous_systems",
		"chipped_stone_tools", "bronze_tools", "tools", "precision_tools", "fine_clothing",
		"fine_furniture", "jewelry", "technology_points"])
	expected_household_goods.sort()
	_expect("direct household good coverage is exact",
		actual_household_goods == expected_household_goods)
	for capital_good in ["railway_equipment", "oceanic_vessels", "scientific_instruments"]:
		_expect("capital good stays outside household demand: %s" % capital_good,
			not seen_goods.has(capital_good))


func _audit_production_climate(catalog: Dictionary,
		buildings: PackedStringArray) -> void:
	var profile_ids: PackedStringArray = catalog.get(
		"production_climate_profile_ids", PackedStringArray())
	_expect("production climate profiles compile in stable-id order",
		profile_ids == PackedStringArray(["dryland_crop", "foraging_plants",
			"paddy_crop", "pasture_livestock", "phenology_observation",
			"plantation_crop"]))
	var temp_opt: PackedInt32Array = catalog.get(
		"production_climate_temperature_opt_q16", PackedInt32Array())
	var temp_tol: PackedInt32Array = catalog.get(
		"production_climate_temperature_tolerance_q16", PackedInt32Array())
	var water_opt: PackedInt32Array = catalog.get(
		"production_climate_water_opt_q16", PackedInt32Array())
	var water_tol: PackedInt32Array = catalog.get(
		"production_climate_water_tolerance_q16", PackedInt32Array())
	var exposure: PackedInt32Array = catalog.get(
		"production_climate_exposure_q16", PackedInt32Array())
	var floors: PackedInt32Array = catalog.get(
		"production_climate_floor_q16", PackedInt32Array())
	var climate_columns_align := [temp_opt, temp_tol, water_opt, water_tol,
		exposure, floors].all(func(values): return values.size() == profile_ids.size())
	_expect("production climate fixed-point columns align", climate_columns_align)
	var dryland := profile_ids.find("dryland_crop")
	_expect("dryland climate profile compiles exact Q16 controls",
		dryland >= 0 and absi(temp_opt[dryland] - int(round(0.55 * 65536.0))) <= 1 and
		absi(temp_tol[dryland] - int(round(0.42 * 65536.0))) <= 1 and
		absi(water_opt[dryland] - int(round(0.55 * 65536.0))) <= 1 and
		absi(water_tol[dryland] - int(round(0.40 * 65536.0))) <= 1 and
		exposure[dryland] == 65536 and floors[dryland] == 16384)
	var building_profiles: PackedInt32Array = catalog.get(
		"building_production_climate_profile_indices", PackedInt32Array())
	_expect("building climate references align", building_profiles.size() == buildings.size())
	var expected := {
		"wheat_farm": "dryland_crop", "rice_collector": "paddy_crop",
		"rubber_tree_collector": "plantation_crop",
		"pastoral_camp": "pasture_livestock",
		"gathering_ground": "foraging_plants",
		"seasonal_observation_shelter": "phenology_observation",
		"pastoral_council_tent": "pasture_livestock",
	}
	for building_id in expected:
		var building_idx := buildings.find(building_id)
		var profile_idx := profile_ids.find(expected[building_id])
		_expect("%s explicitly selects %s" % [building_id, expected[building_id]],
			building_idx >= 0 and building_profiles[building_idx] == profile_idx)
	for building_id in ["household_weaving_shelter", "timber_collector",
			"stone_age_hunting_camp", "freshwater_fishing_camp",
			"marine_fish_collector", "oral_memory_circle", "tide_observation_hut",
			"flood_calendar_shrine"]:
		var building_idx := buildings.find(building_id)
		_expect("%s has no direct climate production penalty" % building_id,
			building_idx >= 0 and building_profiles[building_idx] == -1)


func _audit_household_consumption(catalog: Dictionary) -> void:
	# Compatibility entry point for older callers; the contract above is authoritative.
	_audit_household_consumption_contract(catalog)


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


const CONSTRUCTION_GOOD_INDEX := {
	"logs": 0, "turf_block": 1, "reed_bundle": 2, "bast_fiber": 3,
}
const CONSTRUCTION_QUALITY_LEVELS := [0, 0, 0, 1]
const CONSTRUCTION_EFFICIENCIES := [65536, 65536, 32768, 65536]


func _construction_categories() -> Dictionary:
	return {
		"primitive_construction": PackedInt32Array([0, 1, 2]),
		"primitive_lashing": PackedInt32Array([2, 3]),
	}


func _construction_profile(category_ids: PackedStringArray,
		min_levels: PackedInt32Array):
	var profile = BuildingProfileScript.new()
	profile.construction_good_ids = PackedStringArray(["logs"])
	profile.construction_quantities = PackedInt64Array([1000])
	profile.construction_category_ids = category_ids
	profile.construction_min_quality_levels = min_levels
	return profile


func _expand_construction(profile) -> Dictionary:
	var offsets := PackedInt32Array([0])
	var goods := PackedInt32Array()
	var efficiencies := PackedInt32Array()
	var error: String = EconomyCatalogScript._append_construction_candidates(
		profile, CONSTRUCTION_GOOD_INDEX, _construction_categories(),
		PackedInt32Array(CONSTRUCTION_QUALITY_LEVELS),
		PackedInt32Array(CONSTRUCTION_EFFICIENCIES),
		offsets, goods, efficiencies)
	return {"error": error, "offsets": offsets, "goods": goods,
		"efficiencies": efficiencies}


## Goods that are allowed to remain the only candidate of a construction group.
## Each is functional equipment or a signature input rather than a material with
## an interchangeable stand-in: a rail depot really does need rolling stock, and
## gathered plants stay out of the material pools so thatch never competes with
## the food supply.
const CONSTRUCTION_SOLE_CANDIDATE_GOODS := ["advanced_chips", "computers",
	"electrical_equipment", "electronic_components", "flint", "gathered_plants",
	"oceanic_vessels", "railway_equipment"]


func _audit_construction_substitution_breadth(catalog: Dictionary) -> void:
	# A construction group with one candidate is a hard dependency: a cell that
	# cannot reach that single good can never build the type, which is how
	# colonization used to deadlock on bast fibre. Materials must stay pooled.
	var offsets: PackedInt32Array = catalog.get(
		"building_construction_candidate_offsets", PackedInt32Array())
	var candidate_goods: PackedInt32Array = catalog.get(
		"building_construction_candidate_good_ids", PackedInt32Array())
	var good_ids: PackedStringArray = catalog.get("good_ids", PackedStringArray())
	var offenders := PackedStringArray()
	var pooled := 0
	for group in range(maxi(0, offsets.size() - 1)):
		var begin := int(offsets[group])
		var end := int(offsets[group + 1])
		if end - begin > 1:
			pooled += 1
			continue
		if end - begin != 1:
			continue
		var good := int(candidate_goods[begin])
		var stable_id := String(good_ids[good]) if good < good_ids.size() else str(good)
		if not CONSTRUCTION_SOLE_CANDIDATE_GOODS.has(stable_id) \
				and not offenders.has(stable_id):
			offenders.append(stable_id)
	_expect("every construction material group offers a substitute (%d pooled)" % pooled,
		offenders.is_empty())
	if not offenders.is_empty():
		print("      sole-candidate materials: %s" % ", ".join(offenders))


func _audit_construction_category_validation() -> void:
	var expanded := _expand_construction(_construction_profile(
		PackedStringArray(["primitive_construction"]), PackedInt32Array([0])))
	_expect("a construction category expands to every member good",
		String(expanded.error) == ""
		and expanded.goods == PackedInt32Array([0, 1, 2])
		and expanded.offsets == PackedInt32Array([0, 3])
		and expanded.efficiencies == PackedInt32Array([65536, 65536, 32768]))

	var lashing = _construction_profile(
		PackedStringArray(["primitive_lashing"]), PackedInt32Array([1]))
	lashing.construction_good_ids = PackedStringArray(["bast_fiber"])
	var gated := _expand_construction(lashing)
	_expect("a construction quality gate drops obsolete substitutes",
		String(gated.error) == "" and gated.goods == PackedInt32Array([3]))

	var untyped := _expand_construction(_construction_profile(
		PackedStringArray(), PackedInt32Array()))
	_expect("an uncategorised construction group keeps its single good",
		String(untyped.error) == "" and untyped.goods == PackedInt32Array([0]))

	var conflict = _construction_profile(
		PackedStringArray(["primitive_construction"]), PackedInt32Array([0]))
	conflict.construction_candidate_offsets = PackedInt32Array([0, 2])
	conflict.construction_candidate_good_ids = PackedStringArray(
		["logs", "turf_block"])
	conflict.construction_candidate_efficiency_q16 = PackedInt32Array(
		[65536, 65536])
	_expect("construction category and explicit candidates are mutually exclusive",
		"cannot combine category" in String(_expand_construction(conflict).error))

	var wrong_category := _expand_construction(_construction_profile(
		PackedStringArray(["primitive_lashing"]), PackedInt32Array([0])))
	_expect("a construction category must contain its representative good",
		"must include preferred good" in String(wrong_category.error))

	var short_columns := _expand_construction(_construction_profile(
		PackedStringArray(["primitive_construction", "primitive_lashing"]),
		PackedInt32Array([0])))
	_expect("construction category columns must align with the groups",
		"category columns mismatch" in String(short_columns.error))


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
			["subsistence_farm", 1, 1390, 1],
			["three_field_smallholding", 2, 3296, 1],
			["improved_smallholding", 3, 18540, 1],
		],
		"household_cloth": [
			["household_weaving_shelter", 1, 813, 1],
			["household_loom", 2, 1192, 1],
			["cottage_weaving", 3, 2438, 0],
			["improved_domestic_loom", 4, 4875, 0],
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
			var expected_inputs := int(row[3])
			_expect("subsistence tier has bounded inputs and no employees: %s" % row[0],
				type_id >= 0 and
				input_offsets[type_id + 1] - input_offsets[type_id] == expected_inputs and
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


func _all_ranges_have_tech_except(offsets: PackedInt32Array, tags: PackedStringArray,
		stable_ids: PackedStringArray, allowed_missing: Array) -> bool:
	if offsets.size() != stable_ids.size() + 1:
		return false
	for item in range(stable_ids.size()):
		var found := false
		for edge in range(offsets[item], offsets[item + 1]):
			found = found or String(tags[edge]).begins_with("tech.")
		if not found and not allowed_missing.has(String(stable_ids[item])):
			return false
	return true

func _all_ranges_exclude_tech(offsets: PackedInt32Array, tags: PackedStringArray,
		item_count: int) -> bool:
	if offsets.size() != item_count + 1:
		return false
	for item in range(item_count):
		for edge in range(offsets[item], offsets[item + 1]):
			if String(tags[edge]).begins_with("tech."):
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
