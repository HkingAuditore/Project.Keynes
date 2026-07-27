extends SceneTree

const StartProfile = preload("res://scripts/game/start_location_profile.gd")

var _failures := PackedStringArray()


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var profile: ClimateProfile = load("res://data/world/earth_like.tres").duplicate(true)
	profile.native_generation_mode = ClimateProfile.NATIVE_MODE_ACTIVE
	profile.native_daily_sim_mode = ClimateProfile.NATIVE_MODE_ACTIVE
	profile.native_environment_runtime_enabled = false
	var config := NewGameConfig.new()
	config.country.name = "Runtime Test Nation"
	config.base.map_width = 40
	config.base.map_height = 28
	config.base.initial_seed = 20260727
	config.base.num_continents = 2
	config.base.continent_size = 0.9
	config.base.sea_level = 0.42
	config.base.river_count = 8
	_expect("new-game config is valid", bool(config.validate().get("ok", false)))

	var map_config := MapConfig.make(40, 28)
	map_config.seed = 20260727
	map_config.num_continents = 2
	map_config.continent_size = 0.9
	map_config.sea_level = 0.42
	map_config.river_count = 8
	map_config.climate_profile = profile
	var clock := WorldClock.new()
	var generator := MapGenerator.new()
	generator.climate_profile = profile
	generator.set_world_clock_ref(clock)
	generator.set_gameplay_start_config(config.to_dictionary())
	var generated: Dictionary = await generator.generate(map_config, 10.0)
	var map: MapData = generated.get("map", null)
	_expect("formal world generated", map != null)
	if map == null:
		_finish()
		return

	var start: Dictionary = generator.gameplay_start_report()
	_expect("formal start bootstrap succeeded", bool(start.get("ok", false)))
	var cell_idx := int(start.get("cell", -1))
	_expect("start cell is in range", cell_idx >= 0 and cell_idx < map.cell_count())
	if cell_idx >= 0 and cell_idx < map.cell_count():
		_expect("start cell has freshwater", _has_freshwater(map, cell_idx))
		for resource_id in StartProfile.MINIMUM_RESERVES:
			if String(resource_id) in ["gold_ore", "silver_ore"] \
					and String(resource_id) != String(start.get("precious_resource", "")):
				continue
			_expect("start resource %s reaches minimum" % resource_id,
				_resource_reserve(map, String(resource_id), cell_idx) + 0.001 >=
				float(StartProfile.MINIMUM_RESERVES[resource_id]))

	var country = generator.get_country_facade()
	_expect("country facade is configured", country != null and country.is_configured())
	if country != null:
		var owned := 0
		for index in range(map.cell_count()):
			var summary: Dictionary = country.cell_summary(index)
			if int(summary.get("country_slot", -1)) >= 0:
				owned += 1
				_expect("only the start cell is owned", index == cell_idx)
		_expect("player owns exactly one cell", owned == 1)
		var start_summary: Dictionary = country.cell_summary(cell_idx)
		var player: Dictionary = country.snapshot(int(start_summary.get("country_handle", -1)))
		_expect("stable player country id is preserved",
			String(player.get("country_id", "")) == "country.player")

	var economy = generator.get_economy_facade()
	_expect("economy facade is configured", economy != null and economy.is_configured())
	if economy != null and cell_idx >= 0:
		var population: Dictionary = economy.population_cell_snapshot(cell_idx)
		_expect("starter population is exactly 20", int(population.get("population", 0)) == 20)
		var buildings: Dictionary = economy.building_cell_snapshot(cell_idx)
		_expect("starter has exactly four buildings", _sum_i64(
			buildings.get("building_counts_by_type", PackedInt64Array())) == 4)
		for building_id in ["gathering_ground", "timber_collector", "merchant_post",
				"placer_gold_working" if String(start.get("precious_resource", "")) == "gold_ore"
				else "surface_silver_working"]:
			_expect("starter building %s exists" % building_id,
				_building_count(buildings, building_id) == 1)
	_expect("production bootstrap source is used",
		String(start.get("settlement_source", "")) == "starter_settlement_bootstrap_v1")
	_finish()


func _has_freshwater(map: MapData, cell_idx: int) -> bool:
	if map.has_river_arr[cell_idx] != 0 or map.is_lake_seed_arr[cell_idx] != 0:
		return true
	var neighbors := map.neighbor_indices_packed()
	for direction in range(6):
		var neighbor := int(neighbors[cell_idx * 6 + direction])
		if neighbor >= 0 and (map.has_river_arr[neighbor] != 0 \
				or map.is_lake_seed_arr[neighbor] != 0 \
				or int(map.terrain_arr[neighbor]) == int(TerrainType.TERRAIN.LAKE)):
			return true
	return false


func _resource_reserve(map: MapData, resource_id: String, cell_idx: int) -> float:
	ResourceProfileRegistry.ensure_loaded()
	for resource in ResourceProfileRegistry.ordered():
		if resource != null and String(resource.id) == resource_id:
			var values = map.get(ResourceProfileRegistry.reserve_map_field(resource))
			return float(values[cell_idx])
	return 0.0


func _building_count(snapshot: Dictionary, building_id: String) -> int:
	var ids: PackedStringArray = snapshot.get("building_type_ids", PackedStringArray())
	var counts: PackedInt64Array = snapshot.get("building_counts_by_type", PackedInt64Array())
	var index := ids.find(building_id)
	return int(counts[index]) if index >= 0 and index < counts.size() else 0


func _sum_i64(values: PackedInt64Array) -> int:
	var total := 0
	for value in values:
		total += int(value)
	return total


func _expect(label: String, condition: bool) -> void:
	print("  [%s] %s" % ["PASS" if condition else "FAIL", label])
	if not condition:
		_failures.append(label)


func _finish() -> void:
	print("gameplay start runtime: %d failures" % _failures.size())
	quit(0 if _failures.is_empty() else 1)
