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
	config.country.foreign_count = 5
	config.base.map_width = 60
	config.base.map_height = 40
	config.base.initial_seed = 20260727
	config.base.num_continents = 2
	config.base.continent_size = 0.9
	config.base.sea_level = 0.42
	config.base.river_count = 8
	_expect("new-game config is valid", bool(config.validate().get("ok", false)))

	var map_config := MapConfig.make(60, 40)
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
	var country_starts: Array = start.get("country_starts", [])
	_expect("requested foreign countries generated",
		int(start.get("foreign_count", -1)) == 5 and country_starts.size() == 6)
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
		var owned_cells := {}
		for index in range(map.cell_count()):
			var summary: Dictionary = country.cell_summary(index)
			if int(summary.get("country_slot", -1)) >= 0:
				owned += 1
				owned_cells[index] = true
		_expect("every country owns exactly one cell", owned == country_starts.size())
		for start_value in country_starts:
			var country_start: Dictionary = start_value
			var country_cell := int(country_start.get("cell", -1))
			_expect("country start is owned", owned_cells.has(country_cell))
			var summary: Dictionary = country.cell_summary(country_cell)
			var snapshot: Dictionary = country.snapshot(
				int(summary.get("country_handle", -1)))
			_expect("stable country id is preserved",
				String(snapshot.get("country_id", "")) ==
					String(country_start.get("country_id", "")))
			_expect("country has one-cell territory",
				(snapshot.get("territory_cells", PackedInt32Array())
					as PackedInt32Array).size() == 1)
		var start_summary: Dictionary = country.cell_summary(cell_idx)
		var player: Dictionary = country.snapshot(int(start_summary.get("country_handle", -1)))
		_expect("stable player country id is preserved",
			String(player.get("country_id", "")) == "country.player")
		var minimum_distance := int(start.get("minimum_country_distance", 0))
		for left in range(country_starts.size()):
			for right in range(left + 1, country_starts.size()):
				var distance := _land_distance(map,
					int((country_starts[left] as Dictionary).cell),
					int((country_starts[right] as Dictionary).cell))
				_expect("country starts respect minimum distance",
					distance >= minimum_distance)

	var economy = generator.get_economy_facade()
	_expect("economy facade is configured", economy != null and economy.is_configured())
	if economy != null and cell_idx >= 0:
		for start_value in country_starts:
			var country_start: Dictionary = start_value
			var settlement_cell := int(country_start.get("cell", -1))
			var precious := String(country_start.get("precious_resource", ""))
			var population: Dictionary = economy.population_cell_snapshot(settlement_cell)
			_expect("starter population is exactly 20",
				int(population.get("population", 0)) == 20)
			_expect("starter capital has a deterministic settlement name",
				bool(population.get("settlement_name_active", false)) and
				bool(population.get("settlement_name_forced", false)) and
				not String(population.get("settlement_name", "")).is_empty())
			var buildings: Dictionary = economy.building_cell_snapshot(settlement_cell)
			_expect("starter has exactly four buildings", _sum_i64(
				buildings.get("building_counts_by_type", PackedInt64Array())) == 4)
			for building_id in ["gathering_ground", "timber_collector", "merchant_post",
					"placer_gold_working" if precious == "gold_ore"
					else "surface_silver_working"]:
				_expect("starter building %s exists" % building_id,
					_building_count(buildings, building_id) == 1)
			var families: Dictionary = economy.family_cell_snapshot(
				settlement_cell, 0, 64)
			var family_handles: PackedInt64Array = families.get(
				"family_handles", PackedInt64Array())
			_expect("starter capital has exactly one founder family",
				bool(families.get("ok", false)) and family_handles.size() == 1)
			if family_handles.size() == 1:
				var family_handle := int(family_handles[0])
				var family: Dictionary = economy.family_snapshot(family_handle)
				var industries: Dictionary = economy.family_industries(
					family_handle, 0, 64)
				_expect("founder family conserves two gathering-ground owners",
					int(family.get("population", 0)) == 2
					and int(family.get("owned_buildings", 0)) == 1
					and (industries.get("building_type_stable_ids",
						PackedStringArray()) as PackedStringArray).has(
						"gathering_ground"))
				var people: Dictionary = economy.family_notable_people(
					family_handle, 0, 64)
				var person_handles: PackedInt64Array = people.get(
					"person_handles", PackedInt64Array())
				_expect("founder family has exactly one notable founder",
					person_handles.size() == 1)
				if person_handles.size() == 1:
					var person: Dictionary = economy.notable_person_snapshot(
						int(person_handles[0]))
					_expect("notable founder traces to the gathering-ground owner job",
						bool(person.get("ok", false))
						and not String(person.get("full_name", "")).is_empty()
						and String(person.get("profession_stable_id", "")) == "forager"
						and String(person.get("building_type_stable_id", "")) ==
							"gathering_ground"
						and int(person.get("job_kind", 0)) == 1
						and int(person.get("building_handle", 0)) != 0)
	_expect("all settlements contribute population",
		int(start.get("total_population", 0)) == country_starts.size() * 20)
	_expect("all capitals receive one founder family and notable person",
		int(start.get("founder_family_count", 0)) == country_starts.size()
		and int(start.get("founder_person_count", 0)) == country_starts.size())
	_expect("production bootstrap source is used",
		String(start.get("settlement_source", "")) == "starter_settlement_bootstrap_v3")
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


func _land_distance(map: MapData, source: int, target: int) -> int:
	var distances := PackedInt32Array()
	distances.resize(map.cell_count())
	distances.fill(-1)
	var queue := PackedInt32Array()
	queue.resize(map.cell_count())
	var head := 0
	var tail := 1
	queue[0] = source
	distances[source] = 0
	var neighbors := map.neighbor_indices_packed()
	while head < tail:
		var cell := int(queue[head])
		head += 1
		if cell == target:
			return int(distances[cell])
		for direction in range(6):
			var neighbor := int(neighbors[cell * 6 + direction])
			if neighbor < 0 or distances[neighbor] >= 0 \
					or map.is_water_arr[neighbor] != 0 \
					or not TerrainType.is_passable_land(int(map.terrain_arr[neighbor])):
				continue
			distances[neighbor] = int(distances[cell]) + 1
			queue[tail] = neighbor
			tail += 1
	return 0x3fffffff


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
