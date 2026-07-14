extends SceneTree

const EconomyFacadeScript = preload("res://scripts/economy/economy_facade.gd")
const EconomyTestBootstrapScript = preload("res://scripts/economy/economy_test_bootstrap.gd")
const EconomyCatalogScript = preload("res://scripts/economy/economy_catalog.gd")
const WorldSetupScript = preload("res://scripts/ui/world_setup.gd")
const CountryTestHelper = preload("res://tests/country_test_helper.gd")

var _failures := PackedStringArray()


func _initialize() -> void:
	var option_found := false
	for field in WorldSetupScript.BASE_FIELDS:
		if String(field.get("name", "")) == "generate_test_economy_data":
			option_found = true
			_expect("test economy option defaults off", not bool(field.get("default", true)))
	_expect("world setup exposes test economy option", option_found)
	if not ClassDB.class_exists("DCWorldExt"):
		print("[economy-test-bootstrap] SKIP: DCWorldExt unavailable")
		quit(0)
		return
	var map := _make_map()
	var ext: Object = ClassDB.instantiate("DCWorldExt")
	ext.create_entities(map.cell_count())
	var compiled: Dictionary = EconomyCatalogScript.compile_native_catalog()
	_expect("building catalog compiles", bool(compiled.get("ok", false)))
	var environment := PackedFloat32Array([0.5, 0.5, 0.5, 0.5])
	for slot_name in [&"cell_temp", &"cell_moisture", &"cell_snow_cover", &"cell_weather_intensity", &"cell_elevation"]:
		var sid: int = ext.register_component(slot_name, 0, 1, false)
		ext.write_f32_range(sid, 0, environment)
	var enum_values := map.terrain_arr
	for slot_name in [&"cell_terrain", &"cell_landform", &"cell_vegetation", &"cell_is_water", &"cell_has_river"]:
		var sid: int = ext.register_component(slot_name, 2, 1, false)
		ext.write_u8_range(sid, 0, enum_values if slot_name == &"cell_terrain" else PackedByteArray([0, 0, 0, 0]))
	for i in range((compiled.building_resource_ids as PackedStringArray).size()):
		var reserve_sid: int = ext.register_component(
			StringName(compiled.building_resource_reserve_slots[i]), 0, 1, false)
		var extra_sid: int = ext.register_component(
			StringName(compiled.building_resource_extra_slots[i]), 0, 1, false)
		ext.write_f32_range(reserve_sid, 0, _resource_values(
			map, StringName(compiled.building_resource_ids[i])))
		ext.write_f32_range(extra_sid, 0, PackedFloat32Array([0.0, 0.0, 0.0, 0.0]))
	var facade = EconomyFacadeScript.new()
	var profile = load("res://data/economy/default_economy.tres").duplicate(true)
	profile.market_cycle_days = 1
	var native_catalog := compiled.duplicate(true)
	native_catalog.erase("ok")
	_expect("all-technology test country bootstraps", CountryTestHelper.configure_all_technologies(
		ext, native_catalog, map.cell_count(), 42, map.is_water_arr))
	_expect("facade configures", bool(facade.configure(ext, map.cell_count(), 42, profile).get("ok", false)))
	var first: Dictionary = EconomyTestBootstrapScript.build(map, facade, 42)
	var same: Dictionary = EconomyTestBootstrapScript.build(map, facade, 42)
	_expect("fixture builds", bool(first.get("ok", false)))
	_expect("both passable land cells are populated", int(first.get("populated_cells", 0)) == 2)
	var catalog_buildings: PackedStringArray = facade.building_type_ids()
	_expect("fixture is restricted to a sparse mid-stone subset",
		int(first.get("building_group_count", 0)) > 0 and
		int(first.get("eligible_building_type_count", 0)) < catalog_buildings.size() / 4 and
		_fixture_uses_only_mid_stone_buildings(first, facade))
	_expect("professions follow actual local building jobs",
		int(first.get("generated_profession_count", 0)) > 1 and
		int(first.get("generated_profession_count", 0)) <= facade.profession_ids().size())
	_expect("population exactly matches generated building jobs",
		_population_matches_fixture(first, facade))
	_expect("bootstrap reports mid-stone unemployed population source",
		String(first.get("population_source", "")) == "mid_stone_visible_resources_unemployed_v5" and
		String(first.get("initial_employment", "")) == "unemployed")
	_expect("same seed is deterministic",
		first.population_packet.population == same.population_packet.population and
		first.population_packet.funds == same.population_packet.funds)
	_expect("fixture supplies no initial goods", first.market_packet.is_empty() and
		int(first.get("initial_stock_units", -1)) == 0)
	var boot: Dictionary = facade.bootstrap(
		first.population_packet, first.market_packet, first.building_packet)
	_expect("native bootstrap accepts fixture", bool(boot.get("ok", false)))
	_expect("native bootstrap receives all building groups",
		int(boot.get("building_group_count", 0)) == int(first.building_group_count))
	var buildings: Dictionary = facade.building_cell_snapshot(0)
	var second_buildings: Dictionary = facade.building_cell_snapshot(1)
	_expect("land cells receive different specialized building sets",
		_building_sets_differ(buildings, second_buildings))
	_expect("fertile soil and flint create their mid-stone chains",
		_has_building(buildings, "gathering_ground") and
		_has_building(buildings, "flint_quarry") and
		_has_building(buildings, "knapping_workshop"))
	_expect("wild game respects local and adjacent building access modes",
		_has_building(buildings, "stone_age_hunting_camp") and
		_has_building(second_buildings, "stone_age_hunting_camp") and
		not _has_building(buildings, "wild_game_collector") and
		_has_building(second_buildings, "wild_game_collector"))
	_expect("early bullion workings follow visible gold and silver deposits",
		_has_building(buildings, "placer_gold_working") and
		_has_building(second_buildings, "surface_silver_working"))
	_expect("stone household weaving is part of the self-sufficient fixture",
		_has_building(buildings, "household_weaving_shelter"))
	var initial_land: Dictionary = facade.population_cell_snapshot(0)
	var initial_second_land: Dictionary = facade.population_cell_snapshot(1)
	_expect("all bootstrapped people start unemployed",
		_all_population_unemployed(initial_land) and _all_population_unemployed(initial_second_land))
	_expect("native markets start with zero goods",
		_all_market_stock_zero(facade.market_cell_snapshot(0)) and
		_all_market_stock_zero(facade.market_cell_snapshot(1)))
	var cycle: Dictionary = _run_day(ext, 0)
	_expect("bootstrap economy cycle commits", bool(cycle.get("done", false)) and
		not bool(cycle.get("fatal", false)))
	var land: Dictionary = facade.population_cell_snapshot(0)
	var second_land: Dictionary = facade.population_cell_snapshot(1)
	var ocean: Dictionary = facade.population_cell_snapshot(2)
	var mountain: Dictionary = facade.population_cell_snapshot(3)
	_expect("land cells expose resource-specific professions",
		int(land.get("cohort_count", 0)) > 1 and int(second_land.get("cohort_count", 0)) > 1)
	_expect("land has merchant", _sum_u8(land.get("merchant_flags", PackedByteArray())) >= 1)
	_expect("water and impassable cells stay empty", int(ocean.get("population", -1)) == 0 and int(mountain.get("population", -1)) == 0)
	_expect("demand preview CSR aligns with cohorts",
		(land.get("demand_good_offsets", PackedInt32Array()) as PackedInt32Array).size() ==
		int(land.get("cohort_count", 0)) + 1)
	_expect("employment and unemployment account for every generated person",
		_sum_i64(land.get("owner_employed_by_cohort", PackedInt64Array())) +
		_sum_i64(land.get("employee_employed_by_cohort", PackedInt64Array())) +
		_sum_i64(land.get("unemployed_by_cohort", PackedInt64Array())) ==
		_sum_i64(land.get("populations", PackedInt64Array())))
	_expect("employment logic hires after bootstrap",
		_sum_i64(land.get("owner_employed_by_cohort", PackedInt64Array())) +
		_sum_i64(second_land.get("owner_employed_by_cohort", PackedInt64Array())) > 0)
	_expect("first cycle accumulates produced goods from zero",
		_market_stock_total(facade.market_cell_snapshot(0)) +
		_market_stock_total(facade.market_cell_snapshot(1)) > 0)
	_expect("early bullion creates the initial monetary inflow",
		int(cycle.get("gold_accepted", 0)) > 0 and
		int(cycle.get("silver_accepted", 0)) > 0 and
		int(cycle.get("bullion_money_issued", 0)) ==
			int(cycle.get("gold_money_issued", 0)) +
			int(cycle.get("silver_money_issued", 0)))
	_expect("early cloth production creates market stock from zero",
		_good_stock(facade.market_cell_snapshot(0), "cloth") +
		_good_stock(facade.market_cell_snapshot(1), "cloth") > 0)
	_expect("retired virtual mint is absent",
		not _has_building(buildings, "shell_money_station") and
		not _has_building(buildings, "stone_tool_exchange"))
	_expect("bootstrap cycle conserves population money and goods",
		int(cycle.get("population_error", 1)) == 0 and
		int(cycle.get("money_error", 1)) == 0 and int(cycle.get("goods_error", 1)) == 0)
	var substitute_stock: Dictionary = facade.add_stock(
		1, &"chipped_stone_tools", 100000, 1, 9001)
	_expect("stone tool substitute stock command is accepted",
		bool(substitute_stock.get("ok", false)))
	var second_cycle: Dictionary = _run_day(ext, 1)
	_expect("second cycle consumes category-compatible stone tools",
		bool(second_cycle.get("done", false)) and not bool(second_cycle.get("fatal", false)) and
		int(second_cycle.get("production_inputs_consumed", 0)) > 0 and
		_building_has_capacity(facade.building_cell_snapshot(1), "timber_collector"))
	_finish()


func _make_map() -> MapData:
	var map := MapData.new(4, 1)
	for col in range(4):
		var cube := HexUtils.offset_to_cube(col, 0)
		var cell := HexCell.new(cube.x, cube.y)
		cell.terrain = [TerrainType.TERRAIN.PLAIN, TerrainType.TERRAIN.PLAIN,
			TerrainType.TERRAIN.OCEAN, TerrainType.TERRAIN.MOUNTAIN][col]
		map.set_cell(cell)
	map._build_indices()
	map.terrain_arr = PackedByteArray([
		TerrainType.TERRAIN.PLAIN,
		TerrainType.TERRAIN.PLAIN,
		TerrainType.TERRAIN.OCEAN,
		TerrainType.TERRAIN.MOUNTAIN,
	])
	ResourceProfileRegistry.ensure_loaded()
	for profile in ResourceProfileRegistry.ordered():
		var field := ResourceProfileRegistry.reserve_map_field(profile)
		if field == "":
			continue
		var values := PackedFloat32Array([0.0, 0.0, 0.0, 0.0])
		if String(profile.id) in ["fertile_soil", "flint", "gold_ore"]:
			values[0] = 1000000.0
		elif String(profile.id) in ["wild_game", "timber", "rare_earth", "silver_ore"]:
			values[1] = 1000000.0
		map.set(field, values)
	return map


func _resource_values(map: MapData, resource_id: StringName) -> PackedFloat32Array:
	for profile in ResourceProfileRegistry.ordered():
		if StringName(profile.id) != resource_id:
			continue
		var field := ResourceProfileRegistry.reserve_map_field(profile)
		return map.get(field) if field != "" else PackedFloat32Array()
	return PackedFloat32Array()


func _sum_u8(values: PackedByteArray) -> int:
	var total := 0
	for value in values:
		total += int(value)
	return total


func _sum_i64(values: PackedInt64Array) -> int:
	var total := 0
	for value in values:
		total += int(value)
	return total


func _has_building(snapshot: Dictionary, building_id: String) -> bool:
	var ids: PackedStringArray = snapshot.get("building_type_ids", PackedStringArray())
	var counts: PackedInt64Array = snapshot.get("building_counts_by_type", PackedInt64Array())
	var idx := ids.find(building_id)
	return idx >= 0 and idx < counts.size() and counts[idx] > 0


func _building_sets_differ(first: Dictionary, second: Dictionary) -> bool:
	var first_ids: PackedStringArray = first.get("building_type_ids", PackedStringArray())
	var second_ids: PackedStringArray = second.get("building_type_ids", PackedStringArray())
	var first_counts: PackedInt64Array = first.get("building_counts_by_type", PackedInt64Array())
	var second_counts: PackedInt64Array = second.get("building_counts_by_type", PackedInt64Array())
	if first_ids.is_empty() or second_ids.is_empty():
		return false
	for i in range(first_ids.size()):
		var second_idx := second_ids.find(first_ids[i])
		var first_positive := i < first_counts.size() and first_counts[i] > 0
		var second_positive := second_idx >= 0 and second_idx < second_counts.size() \
			and second_counts[second_idx] > 0
		if first_positive != second_positive:
			return true
	return false


func _building_has_capacity(snapshot: Dictionary, building_id: String) -> bool:
	var ids: PackedStringArray = snapshot.get("building_type_ids", PackedStringArray())
	var groups: PackedInt32Array = snapshot.get("group_type_ids", PackedInt32Array())
	var capacities: PackedInt64Array = snapshot.get("capacity_q16", PackedInt64Array())
	var type_id := ids.find(building_id)
	for i in range(groups.size()):
		if groups[i] == type_id and i < capacities.size() and capacities[i] > 0:
			return true
	return false


func _fixture_uses_only_mid_stone_buildings(packet: Dictionary, facade) -> bool:
	var type_ids: PackedInt32Array = packet.building_packet.building_type_ids
	var stable_ids: PackedStringArray = facade.building_type_ids()
	for type_id in type_ids:
		if type_id < 0 or type_id >= stable_ids.size():
			return false
		var spec: Dictionary = facade.building_placement_spec(StringName(stable_ids[type_id]))
		for tag in spec.get("technology_tags", PackedStringArray()):
			var technology := String(tag)
			if technology.begins_with("tech.") and technology not in [
					"tech.hunting", "tech.gathering", "tech.stone_knapping", "tech.fire_control"]:
				return false
	return true


func _all_population_unemployed(snapshot: Dictionary) -> bool:
	var populations: PackedInt64Array = snapshot.get("populations", PackedInt64Array())
	return not populations.is_empty() and \
		_sum_i64(snapshot.get("owner_employed_by_cohort", PackedInt64Array())) == 0 and \
		_sum_i64(snapshot.get("employee_employed_by_cohort", PackedInt64Array())) == 0 and \
		_sum_i64(snapshot.get("unemployed_by_cohort", PackedInt64Array())) == _sum_i64(populations)


func _all_market_stock_zero(snapshot: Dictionary) -> bool:
	return _market_stock_total(snapshot) == 0


func _market_stock_total(snapshot: Dictionary) -> int:
	return _sum_i64(snapshot.get("stock", PackedInt64Array()))


func _good_stock(snapshot: Dictionary, good_id: String) -> int:
	var ids: PackedStringArray = snapshot.get("good_ids", PackedStringArray())
	var stock: PackedInt64Array = snapshot.get("stock", PackedInt64Array())
	var index := ids.find(good_id)
	return int(stock[index]) if index >= 0 and index < stock.size() else 0


func _population_matches_fixture(packet: Dictionary, facade) -> bool:
	var expected := {}
	var building_packet: Dictionary = packet.building_packet
	var building_cells: PackedInt32Array = building_packet.building_cells
	var building_types: PackedInt32Array = building_packet.building_type_ids
	var building_counts: PackedInt64Array = building_packet.building_counts
	var building_ids: PackedStringArray = EconomyCatalogScript.compile_native_catalog().building_type_ids
	for i in range(building_counts.size()):
		var spec: Dictionary = facade.building_job_spec(
			StringName(building_ids[building_types[i]]))
		if not bool(spec.get("ok", false)):
			return false
		var owner_signature: int = facade.signature_id(StringName(spec.owner_profession), &"default")
		var owner_key := "%d:%d" % [building_cells[i], owner_signature]
		expected[owner_key] = int(expected.get(owner_key, 0)) + \
			int(building_counts[i]) * int(spec.owner_slots)
		var professions: PackedStringArray = spec.employee_professions
		var slots: PackedInt64Array = spec.employee_slots
		for role in range(professions.size()):
			var signature: int = facade.signature_id(StringName(professions[role]), &"default")
			var key := "%d:%d" % [building_cells[i], signature]
			expected[key] = int(expected.get(key, 0)) + \
				int(building_counts[i]) * int(slots[role])
	var population_packet: Dictionary = packet.population_packet
	var cells: PackedInt32Array = population_packet.cell_indices
	var signatures: PackedInt32Array = population_packet.signature_ids
	var populations: PackedInt64Array = population_packet.population
	var actual := {}
	for i in range(populations.size()):
		var key := "%d:%d" % [cells[i], signatures[i]]
		if actual.has(key):
			return false
		actual[key] = int(populations[i])
	for key in expected:
		if int(actual.get(key, -1)) != int(expected[key]):
			return false
	return actual.size() == expected.size()


func _run_day(ext: Object, day: int) -> Dictionary:
	var report := {}
	for slice in range(256):
		report = ext.run_economy_slice({"day_index": day, "tick_index": day * 1000 + slice})
		if bool(report.get("done", false)):
			return report
	return report


func _expect(label: String, condition: bool) -> void:
	if not condition:
		_failures.append(label)


func _finish() -> void:
	if _failures.is_empty():
		print("[economy-test-bootstrap] PASS")
		quit(0)
		return
	for failure in _failures:
		push_error("[economy-test-bootstrap] FAIL: %s" % failure)
	quit(1)
