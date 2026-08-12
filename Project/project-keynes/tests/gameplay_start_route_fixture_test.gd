extends SceneTree

const StartPolicy = preload("res://scripts/game/start_location_policy.gd")
const ResourceRegistry = preload("res://scripts/data/resource_profile_registry.gd")
const ResearchSignalCatalogScript = preload(
	"res://scripts/research/research_signal_catalog.gd")


func _init() -> void:
	var fixtures: Array[Dictionary] = [
		{
			"route": "cold_highland", "temperature": 0.30, "moisture": 0.42,
			"elevation": 0.72, "river": true, "coastal": false,
			"resources": {"pasture": 200000.0, "fertile_soil": 400000.0,
				"gold_ore": 100000.0},
			"signals": ["bio.potato", "resource.fertile_soil", "bio.flax",
				"resource.pasture", "resource.gold_ore"],
			"food": "potatoes", "construction": "turf_block",
			"knowledge_tech": "tech.pastoral_route_memory",
			"required_buildings": ["wild_tuber_patch", "bast_fiber_camp",
				"bast_wrap_shelter", "turf_cutting_ground", "pastoral_council_tent",
				"placer_gold_working", "early_merchant_post"],
		},
		{
			"route": "tropical_forest", "temperature": 0.75, "moisture": 0.75,
			"elevation": 0.25, "river": true, "coastal": false,
			"resources": {"fertile_soil": 400000.0, "timber": 400000.0,
				"silver_ore": 100000.0},
			"signals": ["resource.fertile_soil", "bio.flax", "resource.timber",
				"weather.drought", "resource.silver_ore"],
			"food": "gathered_plants", "construction": "logs",
			"knowledge_tech": "tech.oral_memory_practice",
			"required_buildings": ["gathering_ground", "bast_fiber_camp",
				"bast_wrap_shelter", "deadwood_gathering_camp", "oral_memory_circle",
				"surface_silver_working", "early_merchant_post"],
		},
		{
			"route": "floodplain", "temperature": 0.58, "moisture": 0.70,
			"elevation": 0.22, "river": true, "coastal": false,
			"resources": {"freshwater_fish": 150000.0, "fertile_soil": 400000.0,
				"paddy_land": 180000.0, "gold_ore": 100000.0},
			"signals": ["resource.freshwater_fish", "resource.fertile_soil",
				"bio.flax", "bio.reed", "landform.river_valley", "resource.gold_ore"],
			"food": "fish", "construction": "reed_bundle",
			"knowledge_tech": "tech.flood_calendar_practice",
			"required_buildings": ["freshwater_fishing_camp", "bast_fiber_camp",
				"bast_wrap_shelter", "reed_cutting_camp", "flood_calendar_shrine",
				"placer_gold_working", "early_merchant_post"],
		},
		{
			"route": "arid_highland", "temperature": 0.56, "moisture": 0.30,
			"elevation": 0.50, "river": true, "coastal": false,
			"resources": {"wild_game": 200000.0, "timber": 400000.0,
				"clay": 180000.0, "silver_ore": 100000.0},
			"signals": ["resource.wild_game", "resource.timber", "resource.clay",
				"landform.grassland", "weather.drought", "resource.silver_ore"],
			"food": "game_meat", "construction": "logs",
			"knowledge_tech": "tech.oral_memory_practice",
			"required_buildings": ["stone_age_hunting_camp", "hide_scraping_shelter",
				"deadwood_gathering_camp", "oral_memory_circle",
				"surface_silver_working", "early_merchant_post"],
		},
		{
			"route": "temperate", "temperature": 0.55, "moisture": 0.46,
			"elevation": 0.30, "river": true, "coastal": false,
			"resources": {"fertile_soil": 400000.0, "timber": 400000.0,
				"gold_ore": 100000.0},
			"signals": ["resource.fertile_soil", "bio.flax", "resource.timber",
				"weather.frost", "resource.gold_ore"],
			"food": "gathered_plants", "construction": "logs",
			"knowledge_tech": "tech.phenology_observation",
			"required_buildings": ["gathering_ground", "bast_fiber_camp",
				"bast_wrap_shelter", "deadwood_gathering_camp",
				"seasonal_observation_shelter", "placer_gold_working",
				"early_merchant_post"],
		},
		{
			"route": "coastal", "temperature": 0.62, "moisture": 0.62,
			"elevation": 0.20, "river": false, "coastal": true,
			"resources": {"marine_fish": 150000.0, "fertile_soil": 400000.0,
				"paddy_land": 180000.0, "silver_ore": 100000.0},
			"signals": ["resource.marine_fish", "landform.coast",
				"resource.fertile_soil", "bio.flax", "bio.reed",
				"resource.silver_ore"],
			"food": "fish", "construction": "reed_bundle",
			"knowledge_tech": "tech.tide_observation",
			"required_buildings": ["marine_fish_collector", "bast_fiber_camp",
				"bast_wrap_shelter", "reed_cutting_camp", "tide_observation_hut",
				"surface_silver_working", "early_merchant_post"],
		},
	]
	var fingerprints := {}
	for fixture in fixtures:
		var built := _make_fixture(fixture)
		var map: MapData = built.map
		var route: Dictionary = StartPolicy.evaluate_starter_route(map, int(built.cell))
		var expected_route := String(fixture.route)
		assert(String(route.get("regional_route", "")) == expected_route,
			"%s classified as %s" % [expected_route, route.get("regional_route", "")])
		assert(String(route.get("starter_food_good_id", "")) == String(fixture.food),
			"%s food route" % expected_route)
		assert(String(route.get("starter_construction_good_id", "")) ==
			String(fixture.construction), "%s construction route" % expected_route)
		var technologies: PackedStringArray = route.get(
			"starter_technology_ids", PackedStringArray())
		var buildings: PackedStringArray = route.get(
			"starter_building_ids", PackedStringArray())
		assert(technologies.has(String(fixture.knowledge_tech)),
			"%s knowledge route" % expected_route)
		for building_id in fixture.required_buildings:
			assert(buildings.has(String(building_id)), "%s missing %s" % [
				expected_route, building_id])
		assert(String(route.get("starter_clothing_good_id", "")) == "clothing")
		assert(String(route.get("starter_knowledge_good_id", "")) ==
			"technology_points")
		assert((route.get("missing_resource_ids", PackedStringArray()) as
			PackedStringArray).is_empty(), "%s must not top up resources" % expected_route)
		assert(not JSON.stringify(route).contains("resource.freshwater\""),
			"%s must not require the retired freshwater resource" % expected_route)
		assert(not route.has("resource_topups"), "%s must not expose legacy top-ups" %
			expected_route)
		assert(technologies.has("tech.early_trade"), "%s missing early trade" % expected_route)
		assert(buildings.has("early_merchant_post"), "%s missing early merchant post" %
			expected_route)
		var fingerprint := "%s|%s|%s|%s" % [route.starter_food_good_id,
			route.starter_clothing_resource_id, route.starter_construction_good_id,
			fixture.knowledge_tech]
		fingerprints[fingerprint] = true
	assert(fingerprints.size() == fixtures.size(),
		"fixed regional fixtures must produce six materially distinct routes")
	print("[PASS] six fixed geography fixtures select distinct closed starter routes")
	quit(0)


func _make_fixture(fixture: Dictionary) -> Dictionary:
	var map := MapData.new(3, 3)
	var center_cell: HexCell = null
	var coastal_cell: HexCell = null
	for row in range(3):
		for col in range(3):
			var cube := HexUtils.offset_to_cube(col, row)
			var cell := HexCell.new(cube.x, cube.y)
			cell.terrain = TerrainType.TERRAIN.PLAIN
			map.set_cell(cell)
			if col == 1 and row == 1:
				center_cell = cell
			elif col == 2 and row == 1:
				coastal_cell = cell
	map._build_indices()
	var count := map.cell_count()
	var center := map.index_of(center_cell)
	var coast := map.index_of(coastal_cell)
	map.temp_arr = _f32(count, 0.50)
	map.moisture_arr = _f32(count, 0.50)
	map.elevation_arr = _f32(count, 0.30)
	map.temp_arr[center] = float(fixture.temperature)
	map.moisture_arr[center] = float(fixture.moisture)
	map.elevation_arr[center] = float(fixture.elevation)
	map.terrain_arr = _u8(count, TerrainType.TERRAIN.PLAIN)
	map.is_water_arr = _u8(count, 0)
	map.has_river_arr = _u8(count, 0)
	map.is_lake_seed_arr = _u8(count, 0)
	if bool(fixture.coastal):
		map.terrain_arr[coast] = TerrainType.TERRAIN.OCEAN
		map.is_water_arr[coast] = 1
	if bool(fixture.river):
		map.has_river_arr[center] = 1
	ResourceRegistry.ensure_loaded()
	for profile in ResourceRegistry.ordered():
		var field := ResourceRegistry.reserve_map_field(profile)
		if not field.is_empty():
			map.set(field, _f32(count, 0.0))
	for raw_resource_id in fixture.resources:
		_set_resource(map, center, String(raw_resource_id),
			float(fixture.resources[raw_resource_id]))
	_set_signals(map, center, fixture.get("signals", []))
	return {"map": map, "cell": center}


func _set_resource(map: MapData, cell: int, resource_id: String, value: float) -> void:
	for profile in ResourceRegistry.ordered():
		if String(profile.id) != resource_id:
			continue
		var field := ResourceRegistry.reserve_map_field(profile)
		var values: PackedFloat32Array = map.get(field)
		values[cell] = value
		map.set(field, values)
		return
	assert(false, "unknown fixture resource %s" % resource_id)


func _set_signals(map: MapData, cell: int, signal_ids: Array) -> void:
	var compiled: Dictionary = ResearchSignalCatalogScript.compile_native_catalog()
	assert(bool(compiled.get("ok", false)), str(compiled))
	var stable_ids: PackedStringArray = compiled.research_signal_ids
	var dense := PackedInt32Array()
	for signal_id in signal_ids:
		var index := stable_ids.find(String(signal_id))
		assert(index >= 0, "unknown fixture signal %s" % signal_id)
		dense.append(index)
	dense.sort()
	var offsets := PackedInt32Array()
	offsets.resize(map.cell_count() + 1)
	var out_ids := PackedInt32Array()
	var values := PackedInt32Array()
	for map_cell in range(map.cell_count()):
		offsets[map_cell] = out_ids.size()
		if map_cell == cell:
			for signal_index in dense:
				out_ids.append(signal_index)
				values.append(65536)
	offsets[map.cell_count()] = out_ids.size()
	map.cell_research_signal_offsets = offsets
	map.cell_research_signal_ids = out_ids
	map.cell_research_signal_values = values


func _f32(count: int, value: float) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	out.resize(count)
	out.fill(value)
	return out


func _u8(count: int, value: int) -> PackedByteArray:
	var out := PackedByteArray()
	out.resize(count)
	out.fill(value)
	return out
