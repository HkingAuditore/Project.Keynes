extends SceneTree

const StartPolicy = preload("res://scripts/game/start_location_policy.gd")
const StarterEconomyPlannerScript = preload(
	"res://scripts/economy/starter_economy_planner.gd")
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
			"foods": ["potatoes", "gathered_plants"], "food_technologies": ["tech.wild_tuber_collection", "tech.gathering"], "construction": "turf_block",
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
			"foods": ["gathered_plants"], "food_technologies": ["tech.gathering"], "construction": "logs",
			"extra_technology_ids": ["tech.fire_control", "tech.deadwood_collection"],
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
			"foods": ["fish", "gathered_plants"], "food_technologies": ["tech.freshwater_fishing", "tech.gathering"], "construction": "reed_bundle",
			"knowledge_tech": "tech.flood_calendar_practice",
			"required_buildings": ["freshwater_fishing_camp", "bast_fiber_camp",
				"bast_wrap_shelter", "reed_cutting_camp", "flood_calendar_shrine",
				"placer_gold_working", "early_merchant_post"],
		},
		{
			"route": "arid_highland", "temperature": 0.56, "moisture": 0.30,
			"elevation": 0.50, "river": true, "coastal": false,
			"resources": {"wild_game": 200000.0, "timber": 400000.0,
				"clay": 180000.0, "silver_ore": 100000.0,
				"fertile_soil": 400000.0},
			"signals": ["resource.wild_game", "resource.timber", "resource.clay",
				"resource.fertile_soil", "bio.flax", "landform.grassland", "weather.drought",
				"resource.silver_ore"],
			"foods": ["gathered_plants", "game_meat"], "food_technologies": ["tech.hunting", "tech.gathering"], "construction": "logs",
			"extra_technology_ids": ["tech.fire_control", "tech.deadwood_collection",
				"tech.earth_building", "tech.hide_scraping", "tech.fur_sewing"],
			"knowledge_tech": "tech.oral_memory_practice",
			"required_buildings": ["bast_fiber_camp", "bast_wrap_shelter",
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
			"foods": ["gathered_plants"], "food_technologies": ["tech.gathering"], "construction": "logs",
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
			"foods": ["fish", "gathered_plants"], "food_technologies": ["tech.coastal_fishing", "tech.gathering"], "construction": "reed_bundle",
			"knowledge_tech": "tech.tide_observation",
			"required_buildings": ["marine_fish_collector", "bast_fiber_camp",
				"bast_wrap_shelter", "reed_cutting_camp", "tide_observation_hut",
				"surface_silver_working", "early_merchant_post"],
		},
	]
	var fingerprints := {}
	for fixture in fixtures:
		var fixture_started := Time.get_ticks_msec()
		var built := _make_fixture(fixture)
		var map: MapData = built.map
		var route: Dictionary = StartPolicy.evaluate_starter_route(map, int(built.cell))
		var expected_route := String(fixture.route)
		print("[starter-plan] %s ms=%d candidates=%d combinations=%d plan=%s" % [
			expected_route, Time.get_ticks_msec() - fixture_started,
			(route.get("candidate_building_ids", PackedStringArray()) as PackedStringArray).size(),
			int(route.get("evaluated_combinations", 0)),
			String(route.get("plan_fingerprint", ""))])
		assert(String(route.get("regional_route", "")) == expected_route,
			"%s classified as %s: %s" % [expected_route,
				route.get("regional_route", ""), str(route)])
		var foods: PackedStringArray = route.get("starter_food_good_ids", PackedStringArray())
		assert(foods.size() == (fixture.foods as Array).size(),
			"%s food discovery count" % expected_route)
		for food_id in fixture.foods:
			assert(foods.has(String(food_id)), "%s food discovery %s" % [expected_route, food_id])
		assert(String(route.get("starter_construction_good_id", "")) ==
			String(fixture.construction), "%s construction route" % expected_route)
		var technologies: PackedStringArray = route.get(
			"starter_technology_ids", PackedStringArray())
		for technology_id in fixture.food_technologies:
			assert(technologies.has(String(technology_id)), "%s missing discovered food technology %s" % [expected_route, technology_id])
		for technology_id in fixture.get("extra_technology_ids", []):
			assert(technologies.has(String(technology_id)), "%s missing catalog-wide discovered technology %s" % [expected_route, technology_id])
		var buildings: PackedStringArray = route.get(
			"starter_building_ids", PackedStringArray())
		_assert_plan_contract(expected_route, route)
		assert(technologies.has(String(fixture.knowledge_tech)),
			"%s knowledge route" % expected_route)
		for building_id in fixture.required_buildings:
			if not buildings.has(String(building_id)) and \
					_is_food_producer(String(building_id), foods):
				assert(buildings.has(String(route.get(
					"primary_food_building_id", ""))),
					"%s keeps one discovered primary food producer" % expected_route)
				continue
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
		var fingerprint := "%s|%s|%s|%s" % [str(foods),
			route.starter_clothing_resource_id, route.starter_construction_good_id,
			fixture.knowledge_tech]
		fingerprints[fingerprint] = true
	assert(fingerprints.size() == fixtures.size(),
		"fixed regional fixtures must produce six materially distinct routes")
	_assert_food_discovery_union()
	_assert_hide_only_route_rejected()
	_assert_resource_count_monotonicity()
	print("[PASS] six fixed geography fixtures select distinct closed starter routes")
	quit(0)


func _assert_food_discovery_union() -> void:
	# A single cell can expose several independent food routes. The selected
	# physical producer may still be one building, but the route contract must
	# retain every discovered food substitute for the bootstrap bridge.
	var fixture := {
		"temperature": 0.30, "moisture": 0.42, "elevation": 0.72,
		"river": true, "coastal": false,
		"resources": {"freshwater_fish": 150000.0, "wild_game": 200000.0,
			"fertile_soil": 400000.0, "pasture": 200000.0,
			"timber": 400000.0, "gold_ore": 100000.0},
		"signals": ["resource.freshwater_fish", "resource.wild_game",
			"resource.fertile_soil", "bio.potato", "bio.flax",
			"resource.pasture", "resource.timber", "resource.gold_ore"],
	}
	var built := _make_fixture(fixture)
	var route: Dictionary = StartPolicy.evaluate_starter_route(
		built.map, int(built.cell))
	assert(bool(route.get("ok", false)), "food-rich fixture route succeeds")
	var foods: PackedStringArray = route.get("starter_food_good_ids",
		PackedStringArray())
	for food_id in ["fish", "game_meat", "potatoes", "gathered_plants"]:
		assert(foods.has(food_id), "food-rich fixture discovers %s" % food_id)
	assert(foods.size() == 4, "food-rich fixture deduplicates food goods")
	var food_resources: PackedStringArray = route.get(
		"starter_food_resource_ids", PackedStringArray())
	for resource_id in ["freshwater_fish", "wild_game", "fertile_soil"]:
		assert(food_resources.has(resource_id),
			"food-rich fixture retains %s" % resource_id)
	var technologies: PackedStringArray = route.get(
		"starter_technology_ids", PackedStringArray())
	for technology_id in ["tech.freshwater_fishing", "tech.hunting",
			"tech.wild_tuber_collection", "tech.gathering"]:
		assert(technologies.has(technology_id),
			"food-rich fixture unlocks %s" % technology_id)


func _assert_plan_contract(label: String, route: Dictionary) -> void:
	var ids: PackedStringArray = route.get(
		"starter_building_ids", PackedStringArray())
	var counts: PackedInt64Array = route.get(
		"starter_building_counts", PackedInt64Array())
	assert(ids.size() == counts.size() and not ids.is_empty(),
		"%s building ids/counts are parallel" % label)
	var job_capacity := 0
	var employee_capacity := 0
	for index in range(ids.size()):
		assert(int(counts[index]) > 0, "%s positive count for %s" % [label, ids[index]])
		var profile: BuildingProfile = load(
			"res://data/economy/buildings/%s.tres" % ids[index])
		assert(profile != null, "%s profile exists for %s" % [label, ids[index]])
		var allows_employees := StarterEconomyPlannerScript.allows_starter_employee_roles(
			String(ids[index]))
		var has_employees := not profile.employee_profession_ids.is_empty() \
			or not profile.employee_slots_per_building.is_empty()
		if allows_employees:
			assert(has_employees, "%s %s keeps authored employee roles" % [label, ids[index]])
			for slot in profile.employee_slots_per_building:
				employee_capacity += int(slot) * int(counts[index])
		else:
			assert(not has_employees, "%s %s has no employee role" % [label, ids[index]])
		job_capacity += int(counts[index]) * int(profile.owner_slots_per_building)
	assert(job_capacity == 20 and int(route.get("starter_job_capacity", 0)) == 20,
		"%s has exactly 20 self-operated job slots" % label)
	assert(int(route.get("starter_employee_job_capacity", -1)) == employee_capacity,
		"%s confines employee slots to precious workings" % label)
	assert(not route.has("owner_job_capacity_by_profession"),
		"%s does not expose a population profession allocation" % label)
	for fixed_id in ["early_merchant_post", "placer_gold_working",
			"surface_silver_working"]:
		var fixed_index := ids.find(fixed_id)
		if fixed_index >= 0:
			assert(int(counts[fixed_index]) == 1,
				"%s keeps %s at one building" % [label, fixed_id])
	var supply: Dictionary = route.get("supply_by_good", {})
	var demand: Dictionary = route.get("input_demand_by_good", {})
	for good_id in demand:
		assert(int(supply.get(good_id, 0)) >= int(demand[good_id]),
			"%s closes input %s" % [label, good_id])
	assert(int(route.get("food_coverage_q16", 0)) >= 72090,
		"%s supplies at least 110%% survival food" % label)
	assert(String(ids[0]) == String(route.get("primary_food_building_id", "")),
		"%s keeps the founder building on the primary food route" % label)
	var seed_id := String(route.get(
		"starter_construction_seed_building_id", ""))
	assert(seed_id == String(route.get("primary_food_building_id", "")),
		"%s construction seed is the primary food building" % label)
	var group_offsets: PackedInt32Array = route.get(
		"starter_construction_group_offsets", PackedInt32Array())
	var candidate_ids: PackedStringArray = route.get(
		"starter_construction_candidate_good_ids", PackedStringArray())
	var efficiencies: PackedInt32Array = route.get(
		"starter_construction_candidate_efficiency_q16", PackedInt32Array())
	assert(group_offsets.size() >= 2 and int(group_offsets[0]) == 0 and
		int(group_offsets[-1]) == candidate_ids.size() and
		candidate_ids.size() == efficiencies.size(),
		"%s construction groups have aligned CSR columns" % label)
	for group_index in range(group_offsets.size() - 1):
		assert(int(group_offsets[group_index + 1]) > int(group_offsets[group_index]),
			"%s construction group %d has candidates" % [label, group_index])
	var selected_ids: PackedStringArray = route.get(
		"starter_construction_selected_good_ids", PackedStringArray())
	var selected_quantities: PackedInt64Array = route.get(
		"starter_construction_selected_quantities", PackedInt64Array())
	assert(not selected_ids.is_empty() and
		selected_ids.size() == selected_quantities.size(),
		"%s selected construction goods are aggregated" % label)
	for selected_index in range(selected_ids.size()):
		assert(candidate_ids.has(String(selected_ids[selected_index])) and
			int(selected_quantities[selected_index]) > 0,
			"%s selected construction material is a positive candidate" % label)
	for building_id in ids:
		var profile: BuildingProfile = load(
			"res://data/economy/buildings/%s.tres" % building_id)
		var authored_candidates: PackedStringArray = \
			profile.construction_candidate_good_ids \
			if not profile.construction_candidate_good_ids.is_empty() \
			else profile.construction_good_ids
		for output_good in profile.output_good_ids:
			assert(not authored_candidates.has(String(output_good)),
				"%s %s cannot be built from its own output %s" % [
					label, building_id, output_good])


func _is_food_producer(building_id: String,
		food_goods: PackedStringArray) -> bool:
	var profile: BuildingProfile = load(
		"res://data/economy/buildings/%s.tres" % building_id)
	if profile == null:
		return false
	for output_good in profile.output_good_ids:
		if food_goods.has(String(output_good)):
			return true
	return false


func _assert_hide_only_route_rejected() -> void:
	var fixture := {
		"temperature": 0.56, "moisture": 0.30, "elevation": 0.50,
		"river": true, "coastal": false,
		"resources": {"wild_game": 200000.0, "timber": 400000.0,
			"clay": 180000.0, "silver_ore": 100000.0,
			"fertile_soil": 400000.0},
		"signals": ["resource.wild_game", "resource.timber", "resource.clay",
			"resource.fertile_soil", "landform.grassland", "weather.drought",
			"resource.silver_ore"],
	}
	var built := _make_fixture(fixture)
	var route: Dictionary = StartPolicy.evaluate_starter_route(
		built.map, int(built.cell))
	assert(not bool(route.get("ok", false)),
		"hide-only route is rejected when 9:1 closure exceeds the 20-owner budget")
	assert(not String(route.get("code", "")).is_empty(),
		"hide-only rejection reports a deterministic failure code")


func _assert_resource_count_monotonicity() -> void:
	var cases: Array[Dictionary] = [
		{"resource": "wild_game", "building": "stone_age_hunting_camp",
			"low": 2.0, "high": 200000.0, "base": {
				"temperature": 0.56, "moisture": 0.30, "elevation": 0.50,
				"river": true, "coastal": false,
				"resources": {"wild_game": 200000.0, "timber": 400000.0,
					"fertile_soil": 400000.0, "silver_ore": 100000.0},
				"signals": ["resource.wild_game", "resource.timber",
					"resource.fertile_soil", "bio.flax", "landform.grassland",
					"weather.drought", "resource.silver_ore"]}},
		{"resource": "marine_fish", "building": "marine_fish_collector",
			"low": 1000.0, "high": 150000.0, "base": {
				"temperature": 0.62, "moisture": 0.62, "elevation": 0.20,
				"river": false, "coastal": true, "construction": "reed_bundle",
				"resources": {"marine_fish": 150000.0, "fertile_soil": 400000.0,
					"paddy_land": 180000.0, "silver_ore": 100000.0},
				"signals": ["resource.marine_fish", "landform.coast",
					"resource.fertile_soil", "bio.flax", "bio.reed",
					"resource.silver_ore"]}},
		{"resource": "fertile_soil", "building": "gathering_ground",
			"low": 4.0, "high": 400000.0, "base": {
				"temperature": 0.55, "moisture": 0.46, "elevation": 0.30,
				"river": true, "coastal": false,
				"resources": {"fertile_soil": 400000.0, "timber": 400000.0,
					"gold_ore": 100000.0},
				"signals": ["resource.fertile_soil", "bio.flax", "resource.timber",
					"weather.frost", "resource.gold_ore"]}},
		{"resource": "timber", "building": "deadwood_gathering_camp",
			"low": 60.0, "high": 400000.0, "base": {
				"temperature": 0.75, "moisture": 0.75, "elevation": 0.25,
				"river": true, "coastal": false,
				"resources": {"fertile_soil": 400000.0, "timber": 400000.0,
					"silver_ore": 100000.0},
				"signals": ["resource.fertile_soil", "bio.flax", "resource.timber",
					"weather.drought", "resource.silver_ore"]}},
	]
	for case in cases:
		var low_fixture: Dictionary = (case.base as Dictionary).duplicate(true)
		var high_fixture: Dictionary = (case.base as Dictionary).duplicate(true)
		(low_fixture.resources as Dictionary)[String(case.resource)] = float(case.low)
		(high_fixture.resources as Dictionary)[String(case.resource)] = float(case.high)
		var low_built := _make_fixture(low_fixture)
		var high_built := _make_fixture(high_fixture)
		var low_route: Dictionary = StartPolicy.evaluate_starter_route(
			low_built.map, int(low_built.cell))
		var high_route: Dictionary = StartPolicy.evaluate_starter_route(
			high_built.map, int(high_built.cell))
		assert(bool(low_route.get("ok", false)) and bool(high_route.get("ok", false)),
			"resource scaling routes succeed for %s low=%s high=%s" % [
				case.resource, str(low_route), str(high_route)])
		var low_count := _planned_count(low_route, String(case.building))
		var high_count := _planned_count(high_route, String(case.building))
		print("[starter-resource-scale] %s building=%s low=%d high=%d" % [
			case.resource, case.building, low_count, high_count])
		assert(high_count >= low_count,
			"%s count is monotonic with %s reserve" % [case.building, case.resource])
		_assert_resource_cap(low_route, String(case.building), String(case.resource),
			low_count)
		_assert_resource_cap(high_route, String(case.building), String(case.resource),
			high_count)


func _planned_count(route: Dictionary, building_id: String) -> int:
	var ids: PackedStringArray = route.get("starter_building_ids", PackedStringArray())
	var counts: PackedInt64Array = route.get("starter_building_counts", PackedInt64Array())
	var index := ids.find(building_id)
	return int(counts[index]) if index >= 0 and index < counts.size() else 0


func _assert_resource_cap(route: Dictionary, building_id: String,
		resource_id: String, count: int) -> void:
	if count <= 0:
		return
	var profile: BuildingProfile = load(
		"res://data/economy/buildings/%s.tres" % building_id)
	var resource_index := profile.resource_ids.find(resource_id)
	assert(resource_index >= 0, "%s consumes %s" % [building_id, resource_id])
	var required := float(profile.resource_quantities_per_day[resource_index]) / 1000.0
	var limit := float((route.get("resource_caps", {}) as Dictionary).get(
		resource_id, 0.0))
	assert(float(count) * required <= limit + 0.000001,
		"%s count stays within %s safe limit" % [building_id, resource_id])


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
	if String(fixture.get("construction", "")) == "reed_bundle":
		# Reed construction has the same SWAMP/FLOODPLAIN placement predicate as
		# the native runtime; paddy reserve alone is not a valid geography fixture.
		map.terrain_arr[center] = TerrainType.TERRAIN.FLOODPLAIN
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
	var occupancy := PackedInt32Array()
	occupancy.resize(map.cell_count())
	var occupancy_lookup: PackedInt32Array = compiled.get(
		"research_signal_occupancy_bit", PackedInt32Array())
	var bits := 0
	for signal_index in dense:
		if signal_index < occupancy_lookup.size():
			var bit := int(occupancy_lookup[signal_index])
			if bit >= 0 and bit < 32:
				bits |= 1 << bit
	if cell < occupancy.size():
		occupancy[cell] = bits
	map.bio_occupancy_bits_arr = occupancy


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
