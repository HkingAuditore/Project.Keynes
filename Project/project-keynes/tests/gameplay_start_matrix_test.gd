extends SceneTree

const StartProfile = preload("res://scripts/game/start_location_profile.gd")

var _checks := 0
var _failures := 0


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var cases := [
		{"label": "small", "size": Vector2i(40, 28), "seed": 20260727},
		{"label": "standard", "size": Vector2i(60, 40), "seed": 20260728},
		{"label": "large", "size": Vector2i(100, 64), "seed": 20260729},
	]
	var standard_result := {}
	for test_case in cases:
		var result: Dictionary = await _run_case(
			String(test_case.label), test_case.size, int(test_case.seed))
		if test_case.label == "standard":
			standard_result = result
		await process_frame
	var standard_repeat: Dictionary = await _run_case(
		"standard repeat", Vector2i(60, 40), 20260728)
	_expect("same standard config selects the same start cell",
		int(standard_result.get("start_cell", -1)) == int(
			standard_repeat.get("start_cell", -2)))
	for component in ["world", "country", "economy", "start"]:
		var first_hash := String(standard_result.get(component, ""))
		var repeated_hash := String(standard_repeat.get(component, "different"))
		if first_hash != repeated_hash:
			print("  authority hash mismatch %s: %s != %s" % [
				component, first_hash, repeated_hash])
		_expect("same standard config produces the same %s authority hash" % component,
			first_hash == repeated_hash)
	print("gameplay start matrix: %d checks, %d failures" % [_checks, _failures])
	quit(0 if _failures == 0 else 1)


func _run_case(label: String, size: Vector2i, seed: int) -> Dictionary:
	var profile: ClimateProfile = load("res://data/world/earth_like.tres").duplicate(true)
	profile.native_generation_mode = ClimateProfile.NATIVE_MODE_ACTIVE
	profile.native_daily_sim_mode = ClimateProfile.NATIVE_MODE_ACTIVE
	profile.native_environment_runtime_enabled = false
	var config := NewGameConfig.create_default()
	config.country.name = "Matrix Nation"
	config.base.map_width = size.x
	config.base.map_height = size.y
	config.base.initial_seed = seed
	config.base.num_continents = 2
	config.base.continent_size = 0.9
	config.base.sea_level = 0.42
	config.base.river_count = maxi(8, size.x / 5)
	var map_config := MapConfig.make(size.x, size.y)
	map_config.seed = seed
	map_config.num_continents = int(config.base.num_continents)
	map_config.continent_size = float(config.base.continent_size)
	map_config.sea_level = float(config.base.sea_level)
	map_config.river_count = int(config.base.river_count)
	map_config.climate_profile = profile
	var clock := WorldClock.new()
	var generator := MapGenerator.new()
	generator.climate_profile = profile
	generator.set_world_clock_ref(clock)
	generator.set_gameplay_start_config(config.to_dictionary())
	var generated: Dictionary = await generator.generate(map_config, 10.0)
	var map: MapData = generated.get("map", null)
	_expect("%s world generates" % label, map != null)
	if map == null:
		return {}
	var start: Dictionary = generator.gameplay_start_report()
	var cell := int(start.get("cell", -1))
	_expect("%s start succeeds" % label, bool(start.get("ok", false)) \
		and cell >= 0 and cell < map.cell_count())
	if cell < 0 or cell >= map.cell_count():
		return {}
	_expect("%s start has river/lake or coastal access" % label,
		_has_water_access(map, cell))
	var player_start: Dictionary = (start.get("country_starts", []) as Array)[0]
	_expect("%s has a classified regional route" % label,
		String(player_start.get("regional_route", "")) in ["coastal", "floodplain",
			"cold_highland", "tropical_forest", "arid_highland", "temperate"])
	_expect("%s never tops up generated resources" % label,
		not player_start.has("resource_topups") and
		(player_start.get("missing_resource_ids", PackedStringArray()) as
			PackedStringArray).is_empty())
	for resource_id in player_start.get("starter_food_resource_ids", PackedStringArray()):
		_expect("%s selected food resource %s exists" % [label, resource_id],
			not String(resource_id).is_empty() and _resource_reserve(
				map, String(resource_id), cell) > 0.0)
	for resource_id in [String(player_start.get("starter_clothing_resource_id", "")),
			String(player_start.get("starter_construction_resource_id", "")),
			String(player_start.get("precious_resource", ""))]:
		_expect("%s selected resource %s exists" % [label, resource_id],
			not resource_id.is_empty() and _resource_reserve(map, resource_id, cell) > 0.0)
	var country = generator.get_country_facade()
	var owned_by_slot := {}
	for index in range(map.cell_count()):
		var slot := int(country.cell_summary(index).get("country_slot", -1))
		if slot >= 0:
			owned_by_slot[slot] = int(owned_by_slot.get(slot, 0)) + 1
	var one_cell_countries := owned_by_slot.size() == (start.get(
		"country_starts", []) as Array).size()
	for owned_count in owned_by_slot.values():
		one_cell_countries = one_cell_countries and int(owned_count) == 1
	_expect("%s bootstraps every country with exactly one owned cell" % label,
		one_cell_countries and
		int(country.cell_summary(cell).get("country_slot", -1)) == 0)
	var economy = generator.get_economy_facade()
	var population: Dictionary = economy.population_cell_snapshot(cell)
	_expect("%s starter population is 20" % label,
		int(population.get("population", 0)) == 20)
	_expect("%s starter capital is named" % label,
		bool(population.get("settlement_name_active", false)) and
		bool(population.get("settlement_name_forced", false)) and
		not String(population.get("settlement_name", "")).is_empty())
	var buildings: Dictionary = economy.building_cell_snapshot(cell)
	var route_buildings: PackedStringArray = player_start.get(
		"starter_building_ids", PackedStringArray())
	var route_counts: PackedInt64Array = player_start.get(
		"starter_building_counts", PackedInt64Array())
	var route_technologies: PackedStringArray = player_start.get(
		"starter_technology_ids", PackedStringArray())
	_expect("%s grants early trade and prebuilds its merchant post" % label,
		route_technologies.has("tech.early_trade") and
		route_buildings.has("early_merchant_post"))
	_expect("%s prebuilds exactly its route bundle" % label,
		_sum_i64(buildings.get("building_counts_by_type", PackedInt64Array())) ==
		_sum_i64(route_counts))
	for building_index in range(route_buildings.size()):
		var building_id := String(route_buildings[building_index])
		_expect("%s route building %s exists" % [label, building_id],
			_building_count(buildings, building_id) == int(route_counts[building_index]))
	_expect("%s route has 20 self-operated job slots" % label,
		int(player_start.get("starter_job_capacity", 0)) == 20)
	_expect("%s route has no employee slots" % label,
		int(player_start.get("starter_employee_job_capacity", 0)) == 0)
	_expect("%s route does not preallocate professions" % label,
		not player_start.has("owner_job_capacity_by_profession"))
	_expect("%s leaves non-founder population for native job matching" % label,
		_profession_population(population, "unemployed") > 0
		and _sum_i64(population.get("owner_employed_by_cohort",
			PackedInt64Array())) > 0
		and _sum_i64(population.get("owner_employed_by_cohort",
			PackedInt64Array())) < 20
		and _sum_i64(population.get("employee_employed_by_cohort",
			PackedInt64Array())) == 0)
	var precious_building := "placer_gold_working" \
		if String(start.get("precious_resource", "")) == "gold_ore" \
		else "surface_silver_working"
	_expect("%s precious work site matches deposit" % label,
		_building_count(buildings, precious_building) == 1)
	var market: Dictionary = economy.market_cell_snapshot(cell)
	var food_goods: PackedStringArray = player_start.get(
		"starter_food_good_ids", PackedStringArray())
	var food_bridge_present := not food_goods.is_empty()
	for food_good in food_goods:
		food_bridge_present = food_bridge_present and _market_stock(
			market, String(food_good)) > 0
	_expect("%s uses a fifteen-day local food bridge" % label,
		food_bridge_present and _market_stock(market, "processed_food") == 0)
	var normalized_start := {
		"cell": cell,
		"precious_resource": str(start.get("precious_resource", "")),
		"regional_route": str(player_start.get("regional_route", "")),
		"starter_technology_ids": player_start.get(
			"starter_technology_ids", PackedStringArray()),
		"starter_building_ids": route_buildings,
		"country_id": "country.player",
		"settlement_source": str(start.get("settlement_source", "")),
	}
	return {
		"start_cell": cell,
		"world": _hash_variant(generator.get_data_core_world().serialize()),
		"country": str(country.report().get("state_hash", 0)),
		"economy": str(economy.report().get("state_hash", 0)),
		"start": _hash_variant(normalized_start),
	}


func _has_water_access(map: MapData, cell: int) -> bool:
	if map.has_river_arr[cell] != 0 or map.is_lake_seed_arr[cell] != 0:
		return true
	var neighbors := map.neighbor_indices_packed()
	for direction in range(6):
		var neighbor := int(neighbors[cell * 6 + direction])
		if neighbor >= 0 and (map.is_water_arr[neighbor] != 0 \
				or map.has_river_arr[neighbor] != 0 \
				or map.is_lake_seed_arr[neighbor] != 0 \
				or int(map.terrain_arr[neighbor]) == int(TerrainType.TERRAIN.LAKE)):
			return true
	return false


func _resource_reserve(map: MapData, resource_id: String, cell: int) -> float:
	ResourceProfileRegistry.ensure_loaded()
	for resource in ResourceProfileRegistry.ordered():
		if resource != null and String(resource.id) == resource_id:
			return float(map.get(ResourceProfileRegistry.reserve_map_field(resource))[cell])
	return 0.0


func _building_count(snapshot: Dictionary, building_id: String) -> int:
	var ids: PackedStringArray = snapshot.get("building_type_ids", PackedStringArray())
	var counts: PackedInt64Array = snapshot.get(
		"building_counts_by_type", PackedInt64Array())
	var index := ids.find(building_id)
	return int(counts[index]) if index >= 0 and index < counts.size() else 0


func _market_stock(snapshot: Dictionary, good_id: String) -> int:
	var ids: PackedStringArray = snapshot.get("good_ids", PackedStringArray())
	var stock: PackedInt64Array = snapshot.get("stock", PackedInt64Array())
	var index := ids.find(good_id)
	return int(stock[index]) if index >= 0 and index < stock.size() else 0


func _sum_i64(values: PackedInt64Array) -> int:
	var total := 0
	for value in values:
		total += int(value)
	return total


func _profession_population(snapshot: Dictionary, stable_id: String) -> int:
	var catalog_ids: PackedStringArray = snapshot.get(
		"profession_stable_ids", PackedStringArray())
	var row_professions: PackedInt32Array = snapshot.get(
		"profession_ids", PackedInt32Array())
	var row_populations: PackedInt64Array = snapshot.get(
		"populations", PackedInt64Array())
	var total := 0
	for row in range(mini(row_professions.size(), row_populations.size())):
		var profession := int(row_professions[row])
		if profession >= 0 and profession < catalog_ids.size() \
				and String(catalog_ids[profession]) == stable_id:
			total += int(row_populations[row])
	return total


func _hash_variant(value) -> String:
	var context := HashingContext.new()
	context.start(HashingContext.HASH_SHA256)
	context.update(var_to_bytes(value))
	return context.finish().hex_encode()


func _expect(label: String, condition: bool) -> void:
	_checks += 1
	print("  [%s] %s" % ["PASS" if condition else "FAIL", label])
	if not condition:
		_failures += 1
