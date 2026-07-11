extends SceneTree

const EconomyFacadeScript = preload("res://scripts/economy/economy_facade.gd")
const EconomyTestBootstrapScript = preload("res://scripts/economy/economy_test_bootstrap.gd")
const EconomyCatalogScript = preload("res://scripts/economy/economy_catalog.gd")
const WorldSetupScript = preload("res://scripts/ui/world_setup.gd")

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
	var environment := PackedFloat32Array([0.5, 0.5, 0.5])
	for slot_name in [&"cell_temp", &"cell_moisture", &"cell_snow_cover", &"cell_weather_intensity", &"cell_elevation"]:
		var sid: int = ext.register_component(slot_name, 0, 1, false)
		ext.write_f32_range(sid, 0, environment)
	var enum_values := PackedByteArray([0, 1, 2])
	for slot_name in [&"cell_terrain", &"cell_landform", &"cell_vegetation", &"cell_is_water", &"cell_has_river"]:
		var sid: int = ext.register_component(slot_name, 2, 1, false)
		ext.write_u8_range(sid, 0, enum_values if slot_name == &"cell_terrain" else PackedByteArray([0, 0, 0]))
	for i in range((compiled.building_resource_ids as PackedStringArray).size()):
		var reserve_sid: int = ext.register_component(
			StringName(compiled.building_resource_reserve_slots[i]), 0, 1, false)
		var extra_sid: int = ext.register_component(
			StringName(compiled.building_resource_extra_slots[i]), 0, 1, false)
		ext.write_f32_range(reserve_sid, 0, PackedFloat32Array([1000.0, 0.0, 0.0]))
		ext.write_f32_range(extra_sid, 0, PackedFloat32Array([0.0, 0.0, 0.0]))
	var facade = EconomyFacadeScript.new()
	var profile = load("res://data/economy/default_economy.tres").duplicate(true)
	profile.market_cycle_days = 1
	_expect("facade configures", bool(facade.configure(ext, map.cell_count(), 42, profile).get("ok", false)))
	var first: Dictionary = EconomyTestBootstrapScript.build(map, facade, 42)
	var same: Dictionary = EconomyTestBootstrapScript.build(map, facade, 42)
	var different: Dictionary = EconomyTestBootstrapScript.build(map, facade, 43)
	_expect("fixture builds", bool(first.get("ok", false)))
	_expect("only one passable land cell populated", int(first.get("populated_cells", 0)) == 1)
	_expect("four cohorts generated", int(first.get("cohort_count", 0)) == 4)
	_expect("four compressed building groups generated", int(first.get("building_group_count", 0)) == 4)
	_expect("population is derived exactly from generated building jobs",
		_population_matches_building_jobs(first, facade))
	_expect("bootstrap reports building-first population source",
		String(first.get("population_source", "")) == "building_jobs_v1")
	_expect("same seed is deterministic", first.population_packet.population == same.population_packet.population and first.population_packet.funds == same.population_packet.funds)
	_expect("different seed changes population", first.population_packet.population != different.population_packet.population)
	var goods := facade.good_ids()
	var stock: PackedInt64Array = first.market_packet.stock
	_expect("dense market matrix matches cells by goods", stock.size() == map.cell_count() * goods.size())
	_expect("passable land stocks every good", _row_all_positive(stock, 0, goods.size()))
	_expect("ocean has zero stock", _row_all_zero(stock, 1, goods.size()))
	_expect("impassable mountain has zero stock", _row_all_zero(stock, 2, goods.size()))
	var boot: Dictionary = facade.bootstrap(
		first.population_packet, first.market_packet, first.building_packet)
	_expect("native bootstrap accepts fixture", bool(boot.get("ok", false)))
	_expect("native bootstrap receives all building groups", int(boot.get("building_group_count", 0)) == 4)
	var buildings: Dictionary = facade.building_cell_snapshot(0)
	_expect("land contains farm workshop estate and stall",
		_all_fixture_buildings_positive(buildings))
	_expect("workshop and stall have distinct fixed wages", _fixture_wages_are_distinct(buildings))
	var cycle: Dictionary = _run_day(ext, 0)
	_expect("bootstrap economy cycle commits", bool(cycle.get("done", false)) and
		not bool(cycle.get("fatal", false)))
	var land: Dictionary = facade.population_cell_snapshot(0)
	var ocean: Dictionary = facade.population_cell_snapshot(1)
	var mountain: Dictionary = facade.population_cell_snapshot(2)
	_expect("land has exact four cohort signatures", int(land.get("cohort_count", 0)) == 4)
	_expect("land has merchant", _sum_u8(land.get("merchant_flags", PackedByteArray())) >= 1)
	_expect("water and impassable cells stay empty", int(ocean.get("population", -1)) == 0 and int(mountain.get("population", -1)) == 0)
	_expect("demand preview CSR aligns with cohorts", (land.get("demand_good_offsets", PackedInt32Array()) as PackedInt32Array).size() == 5)
	_expect("generated buildings provide real jobs for every cohort",
		_sum_i64(land.get("unemployed_by_cohort", PackedInt64Array())) == 0)
	var worker_signature := facade.signature_id(&"worker", &"default")
	var worker_row := (land.signature_ids as PackedInt32Array).find(worker_signature)
	_expect("generated workplaces pay worker wages", worker_row >= 0 and
		int((land.epoch_income_by_cohort as PackedInt64Array)[worker_row]) > 0 and
		int(cycle.get("building_wages_paid", 0)) > 0)
	_expect("bootstrap cycle conserves population money and goods",
		int(cycle.get("population_error", 1)) == 0 and
		int(cycle.get("money_error", 1)) == 0 and int(cycle.get("goods_error", 1)) == 0)
	_finish()


func _make_map() -> MapData:
	var map := MapData.new(3, 1)
	for col in range(3):
		var cube := HexUtils.offset_to_cube(col, 0)
		var cell := HexCell.new(cube.x, cube.y)
		cell.terrain = [TerrainType.TERRAIN.PLAIN, TerrainType.TERRAIN.OCEAN, TerrainType.TERRAIN.MOUNTAIN][col]
		map.set_cell(cell)
	map._build_indices()
	map.terrain_arr = PackedByteArray([
		TerrainType.TERRAIN.PLAIN,
		TerrainType.TERRAIN.OCEAN,
		TerrainType.TERRAIN.MOUNTAIN,
	])
	return map


func _row_all_positive(values: PackedInt64Array, cell: int, goods: int) -> bool:
	for good in range(goods):
		if values[cell * goods + good] <= 0:
			return false
	return true


func _row_all_zero(values: PackedInt64Array, cell: int, goods: int) -> bool:
	for good in range(goods):
		if values[cell * goods + good] != 0:
			return false
	return true


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


func _all_fixture_buildings_positive(snapshot: Dictionary) -> bool:
	var ids: PackedStringArray = snapshot.get("building_type_ids", PackedStringArray())
	var counts: PackedInt64Array = snapshot.get("building_counts_by_type", PackedInt64Array())
	for id in ["landed_estate", "market_stall", "subsistence_farm", "textile_workshop"]:
		var idx := ids.find(id)
		if idx < 0 or idx >= counts.size() or counts[idx] <= 0:
			return false
	return true


func _fixture_wages_are_distinct(snapshot: Dictionary) -> bool:
	var ids: PackedStringArray = snapshot.get("building_type_ids", PackedStringArray())
	var wages: PackedInt64Array = snapshot.get(
		"wage_per_employee_per_day_by_type", PackedInt64Array())
	var workshop := ids.find("textile_workshop")
	var stall := ids.find("market_stall")
	return workshop >= 0 and stall >= 0 and workshop < wages.size() and stall < wages.size() and \
		wages[workshop] == 5000 and wages[stall] == 6000


func _population_matches_building_jobs(packet: Dictionary, facade) -> bool:
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
	if expected.size() != populations.size():
		return false
	for i in range(populations.size()):
		var key := "%d:%d" % [cells[i], signatures[i]]
		if int(expected.get(key, -1)) != int(populations[i]):
			return false
	return true


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
