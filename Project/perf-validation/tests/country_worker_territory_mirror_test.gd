extends SceneTree

# Under COUNTRY worker authority the synchronous NativeCountryRuntime store is
# frozen at its pre-handoff contents, so every claim the worker commits after
# the grant lives only in the committed asset snapshot. MapData.country_slot_arr
# is what vision and CountryBorderLayer read, and sync_country_territory_to_map
# used to republish the frozen sync plane over it — which both dropped the new
# claim and overwrote the correct plane the Host read view had already patched
# in. The player saw the cell's country update in the Inspector while the
# country border never grew to include it.

const EconomyCatalogScript = preload("res://scripts/economy/economy_catalog.gd")
const CountryFacadeScript = preload("res://scripts/country/country_facade.gd")

const CELLS := 2
const CLAIMED_CELL := 1

var _checks := 0
var _failures := 0


func _init() -> void:
	_run()
	print("country worker territory mirror: %d checks, %d failures" % [
		_checks, _failures])
	quit(0 if _failures == 0 else 1)


func _expect(label: String, condition: bool) -> void:
	_checks += 1
	print("  [%s] %s" % ["PASS" if condition else "FAIL", label])
	if not condition:
		_failures += 1


func _make_map() -> MapData:
	var map := MapData.new(CELLS, 1)
	for q in range(CELLS):
		var cell := HexCell.new(q, 0)
		cell.terrain = TerrainType.TERRAIN.PLAIN
		cell.landform = LandformType.LF.PLAIN
		map.set_cell(cell)
	map._build_indices()
	map.init_soa_from_bake()
	map.visible_arr.fill(1)
	map.explored_arr.fill(1)
	map.vision_revision = 1
	return map


func _register_environment(ext: Object) -> void:
	var scalar := PackedFloat32Array()
	scalar.resize(CELLS)
	scalar.fill(0.5)
	for slot_name in [&"cell_temp", &"cell_temp_30d", &"cell_moisture",
			&"cell_plant_available_water", &"cell_weather_precip", &"cell_snow_cover",
			&"cell_weather_intensity", &"cell_elevation"]:
		ext.write_f32_range(ext.register_component(slot_name, 0, 1, false), 0, scalar)
	var bytes := PackedByteArray()
	bytes.resize(CELLS)
	for slot_name in [&"cell_terrain", &"cell_landform", &"cell_vegetation",
			&"cell_is_water", &"cell_has_river"]:
		ext.write_u8_range(ext.register_component(slot_name, 2, 1, false), 0, bytes)


# The worker consumes one environment per day; publish for the day it is
# actually waiting on, otherwise it parks on the input barrier.
func _publish_day_input(ext: Object, generation: int) -> void:
	var next_day := int(ext.get_runtime_thread_report().get(
		"simulation_committed_day", 0)) + 1
	var temp := PackedFloat32Array()
	temp.resize(CELLS)
	temp.fill(15.0)
	var moisture := PackedFloat32Array()
	moisture.resize(CELLS)
	moisture.fill(0.5)
	var terrain := PackedByteArray()
	terrain.resize(CELLS)
	terrain.fill(1)
	ext.capture_runtime_inputs({
		"generation": generation,
		"day": next_day,
		"terrain": terrain,
		"neighbor_offsets": PackedInt32Array([0, 0, 0]),
		"neighbor_indices": PackedInt32Array(),
		"cell_temp": temp,
		"cell_moisture": moisture,
		"cell_plant_available_water": moisture,
	})


func _run() -> void:
	if not ClassDB.class_exists("DCWorldExt"):
		_expect("DCWorldExt available", false)
		return
	var compiled: Dictionary = EconomyCatalogScript.compile_native_catalog()
	_expect("catalog compiles", bool(compiled.get("ok", false)))
	if not bool(compiled.get("ok", false)):
		return

	var map := _make_map()
	var ext: Object = ClassDB.instantiate("DCWorldExt")
	_expect("map binds to native world", bool(ext.bind_map_data(map)))
	_register_environment(ext)

	var country = CountryFacadeScript.new()
	country.configure(ext, CELLS, 5507,
		load("res://data/country/default_country.tres"), compiled)
	var water := PackedByteArray()
	water.resize(CELLS)
	country.bootstrap(water, {
		"country_ids": PackedStringArray(["country.territory_mirror"]),
		"country_names": PackedStringArray(["TerritoryMirror"]),
		"country_cash": PackedInt64Array([100000000]),
		"territory_offsets": PackedInt32Array([0, 1]),
		"territory_cells": PackedInt32Array([0]),
		"technology_offsets": PackedInt32Array([0, 0]),
		"technology_indices": PackedInt32Array(),
	})
	var handle := int(country.cell_summary(0).country_handle)
	var slot := int(country.cell_summary(0).country_slot)
	ext.run_country_slice({"day_index": 0})
	_expect("bootstrap publishes the founding cell into MapData",
		handle != 0 and int(map.country_slot_arr[0]) == slot
		and int(map.country_slot_arr[CLAIMED_CELL]) == -1)

	ext.capture_country_pod_catalog()
	ext.capture_country_runtime_snapshot()
	_publish_day_input(ext, 1)
	ext.configure_runtime_graph({"enabled": true, "day": 0})
	var started: Dictionary = ext.start_runtime_worker({
		"simulation_thread_mode": "ACTIVE",
		"graph_coverage_complete": true,
		"authoritative_domain_mask": 0x004,
		"day": 0,
		"speed_days_per_second": 1000.0,
		"paused": false,
	})
	_expect("Country-only ACTIVE worker starts", bool(started.get("ok", false)))
	if not bool(started.get("ok", false)):
		return
	var granted := false
	for _attempt in range(200):
		if (int(ext.get_runtime_thread_report().get(
				"authoritative_domain_mask", 0)) & 0x004) != 0:
			granted = true
			break
		OS.delay_msec(2)
	_expect("Country worker grant is observed", granted)
	if not granted:
		ext.request_runtime_stop()
		return
	ext.set_runtime_clock(true, 1000.0)

	var input_generation := 1
	for _step in range(16):
		input_generation += 1
		_publish_day_input(ext, input_generation)
		ext.advance_runtime_pulse(0, 0.0, 1.0, 4000)
		ext.set_runtime_clock(false, 1000.0)
		OS.delay_msec(2)
		ext.set_runtime_clock(true, 1000.0)

	var claim: Dictionary = country.submit([{
		"opcode": CountryFacadeScript.Opcode.CLAIM_UNOWNED_TERRITORY,
		"target_handle": handle,
		"cell": CLAIMED_CELL,
		"effective_day": int(ext.get_runtime_thread_report().get(
			"simulation_committed_day", 0)) + 1,
		"sequence": 1,
	}])
	_expect("claim is admitted under worker authority",
		bool(claim.get("ok", false)))

	var committed := false
	for _step in range(240):
		input_generation += 1
		_publish_day_input(ext, input_generation)
		ext.advance_runtime_pulse(0, 0.0, 1.0, 4000)
		ext.set_runtime_clock(false, 1000.0)
		OS.delay_msec(3)
		ext.set_runtime_clock(true, 1000.0)
		if int(ext.get_country_cell_summary(CLAIMED_CELL).get(
				"country_handle", 0)) == handle:
			committed = true
			break
	# This is the half the player already saw working: the Inspector reads the
	# committed snapshot through country_query_runtime().
	_expect("worker commits the claim into the queryable snapshot", committed)
	if not committed:
		ext.request_runtime_stop()
		return

	# The regression. sync_country_territory_to_map is the only writer the
	# border/vision refresh runs before rebuilding, so it must publish the same
	# territory the query path reports — not the frozen synchronous plane.
	var synced: Dictionary = ext.sync_country_territory_to_map()
	_expect("territory sync succeeds", bool(synced.get("ok", false)))
	_expect("territory sync mirrors the worker claim into MapData",
		int(map.country_slot_arr[CLAIMED_CELL]) == slot)
	_expect("territory sync keeps the founding cell owned",
		int(map.country_slot_arr[0]) == slot)

	# A second sync must be idempotent: re-running the visual refresh cannot
	# revert a cell the Host read view already patched in.
	ext.sync_country_territory_to_map()
	_expect("repeated territory sync never reverts a committed claim",
		int(map.country_slot_arr[CLAIMED_CELL]) == slot)

	ext.request_runtime_stop()
