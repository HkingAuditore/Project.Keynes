# tile_data_recorder_test.gd
#
# Headless execution:
#     godot --headless --script tests/tile_data_recorder_test.gd --quit

extends SceneTree


var _failures: int = 0
var _checks: int = 0


class _Cell:
	extends RefCounted
	var q: int = 0
	var r: int = 0
	var s: int = 0

	func _init(p_q: int, p_r: int, p_s: int) -> void:
		q = p_q
		r = p_r
		s = p_s


class _MockMap:
	extends RefCounted
	var _cells: Array = []
	var _has_soa: bool = true
	var temp_arr: PackedFloat32Array = PackedFloat32Array()
	var temp_arr_prev: PackedFloat32Array = PackedFloat32Array()
	var moisture_arr: PackedFloat32Array = PackedFloat32Array()
	var moisture_arr_prev: PackedFloat32Array = PackedFloat32Array()
	var snow_cover_arr: PackedFloat32Array = PackedFloat32Array()
	var snow_cover_arr_prev: PackedFloat32Array = PackedFloat32Array()
	var thermal_energy_arr: PackedFloat32Array = PackedFloat32Array()
	var snowpack_arr: PackedFloat32Array = PackedFloat32Array()
	var water_balance_30d_arr: PackedFloat32Array = PackedFloat32Array()
	var slp_arr: PackedFloat32Array = PackedFloat32Array()
	var wind_x_arr: PackedFloat32Array = PackedFloat32Array()
	var wind_y_arr: PackedFloat32Array = PackedFloat32Array()
	var wind_speed_arr: PackedFloat32Array = PackedFloat32Array()
	var ocean_current_x_arr: PackedFloat32Array = PackedFloat32Array()
	var ocean_current_y_arr: PackedFloat32Array = PackedFloat32Array()
	var upwelling_strength_arr: PackedFloat32Array = PackedFloat32Array()
	var terrain_arr: PackedByteArray = PackedByteArray()
	var country_slot_arr: PackedInt32Array = PackedInt32Array()
	var _neighbor_indices: PackedInt32Array = PackedInt32Array()
	var demo_thermal_gradient_arr: PackedFloat32Array = PackedFloat32Array()

	func _init(n: int = 2) -> void:
		_cells.resize(n)
		for i in range(n):
			_cells[i] = _Cell.new(i, -i, 0)
		temp_arr.resize(n)
		temp_arr_prev.resize(n)
		moisture_arr.resize(n)
		moisture_arr_prev.resize(n)
		snow_cover_arr.resize(n)
		snow_cover_arr_prev.resize(n)
		thermal_energy_arr.resize(n)
		snowpack_arr.resize(n)
		water_balance_30d_arr.resize(n)
		slp_arr.resize(n)
		wind_x_arr.resize(n)
		wind_y_arr.resize(n)
		wind_speed_arr.resize(n)
		ocean_current_x_arr.resize(n)
		ocean_current_y_arr.resize(n)
		upwelling_strength_arr.resize(n)
		terrain_arr.resize(n)
		country_slot_arr.resize(n)
		_neighbor_indices.resize(n * 6)
		for i in range(n):
			temp_arr[i] = 10.0 + float(i)
			temp_arr_prev[i] = 9.5 + float(i)
			moisture_arr[i] = 0.25 + float(i) * 0.1
			moisture_arr_prev[i] = 0.20 + float(i) * 0.1
			snow_cover_arr[i] = 0.10 * float(i)
			snow_cover_arr_prev[i] = 0.05 * float(i)
			thermal_energy_arr[i] = temp_arr[i]
			snowpack_arr[i] = 0.03 + 0.02 * float(i)
			water_balance_30d_arr[i] = -0.10 + 0.05 * float(i)
			slp_arr[i] = -0.25 + 0.50 * float(i)
			wind_x_arr[i] = 1.0
			wind_y_arr[i] = 0.0
			wind_speed_arr[i] = 0.75 + 0.25 * float(i)
			ocean_current_x_arr[i] = 0.0
			ocean_current_y_arr[i] = 0.20 * float(i)
			upwelling_strength_arr[i] = -0.10 * float(i)
			terrain_arr[i] = i + 3
			country_slot_arr[i] = 0

	func has_soa() -> bool:
		return _has_soa

	func cell_count() -> int:
		return _cells.size()

	func cell_at(idx: int):
		if idx < 0 or idx >= _cells.size():
			return null
		return _cells[idx]


class _MockMain:
	extends RefCounted
	var map = null
	var fast_tick: int = 0
	var generator = _MockGenerator.new()

	func get_current_map():
		return map

	func get_fast_tick_count() -> int:
		return fast_tick

	func get_generator():
		return generator

	func climate_authority_diagnostics() -> Dictionary:
		return {"writeback_last_day": 2}


class _MockGenerator:
	extends RefCounted
	var country = _MockCountryFacade.new()

	func get_runtime_thread_report() -> Dictionary:
		return {"simulation_committed_day": 2, "worker_fault_count": 0}

	func get_country_facade():
		return country


class _MockCountryWorldExt:
	extends RefCounted

	func get_country_worker_read_view(_after_generation: int) -> Dictionary:
		return {
			"ok": true, "available": true, "generation": 3,
			"committed_day": 2, "state_hash": 222,
			"territory_watermark": 1, "research_watermark": 2,
			"tax_watermark": 3,
		}


class _MockCountryFacade:
	extends RefCounted
	var ext = _MockCountryWorldExt.new()

	func report() -> Dictionary:
		return {
			"configured": true, "bootstrapped": true,
			"generation": 3, "state_hash": 111,
		}

	func cell_summary(_cell: int) -> Dictionary:
		return {
			"country_handle": 4294967296, "country_id": "country.test",
			"state_version": 4, "territory_count": 2, "cash": 100,
		}

	func snapshot(_handle: int) -> Dictionary:
		return {"technology_ids": PackedStringArray(["tech.hunting"])}

	func treasury_snapshot(_handle: int) -> Dictionary:
		return {
			"cash": 100, "good_ids": PackedStringArray(["grain"]),
			"quantities": PackedInt64Array([25]),
		}

	func research_snapshot(_handle: int) -> Dictionary:
		return {
			"technology_states": PackedInt32Array([4]),
			"queue_technology_indices": PackedInt32Array(),
		}

	func world_ext():
		return ext

	func poll_worker_command_receipts(after_request_id: int,
			_limit: int) -> Dictionary:
		if after_request_id > 0:
			return {
				"ok": true, "available": false, "receipts": [],
				"last_request_id": after_request_id,
			}
		return {
			"ok": true, "available": true, "last_request_id": 7,
			"receipts": [{
				"request_id": 7, "status": "Committed", "code": 2,
			}],
		}


func _init() -> void:
	_run()
	quit(0 if _failures == 0 else 1)


func _expect(cond: bool, name: String) -> void:
	_checks += 1
	if cond:
		print("  [PASS] %s" % name)
	else:
		print("  [FAIL] %s" % name)
		_failures += 1


func _run() -> void:
	print("=== tile_data_recorder test ===")
	_test_csv_escape()
	_test_collect_soa_fields()
	_test_native_csv_encoder_if_available()
	_test_state_machine_and_export()
	_test_auto_stop_on_map_change()
	_test_auto_stop_on_cell_count_change()
	_test_sidecar_metadata_and_export_path()
	print("=== tile_data_recorder test summary: %d checks, %d failures ===" % [_checks, _failures])


func _sample(tick_idx: int = 1) -> Dictionary:
	return {
		"tick_idx": tick_idx,
		"timestamp_ms": 1000 + tick_idx,
		"was_skipped_day": false,
		"fps": 60,
		"fast_ms": 1.5,
		"t_sus_ms": 0.5,
		"t_render_ms": 0.25,
		"t_ui_ms": 0.1,
	}


func _test_csv_escape() -> void:
	_expect(TileDataRecorder._csv_escape("a,b") == "\"a,b\"", "comma quoted")
	_expect(TileDataRecorder._csv_escape("a\"b") == "\"a\"\"b\"", "quote doubled")
	_expect(TileDataRecorder._csv_escape(NAN) == "", "NaN blank")
	_expect(TileDataRecorder._csv_escape(1.25) == "1.25", "float trimmed")


func _test_collect_soa_fields() -> void:
	var map := _MockMap.new(2)
	map.demo_thermal_gradient_arr.resize(0)
	var fields: PackedStringArray = TileDataRecorder._collect_soa_fields(map, 2)
	_expect(fields.find("temp_arr") != -1, "temp_arr included")
	_expect(fields.find("temp_arr_prev") != -1, "temp_arr_prev included")
	_expect(fields.find("moisture_arr") != -1, "moisture_arr included")
	_expect(fields.find("snow_cover_arr_prev") != -1, "snow_cover_arr_prev included")
	_expect(fields.find("thermal_energy_arr") != -1, "thermal_energy_arr included")
	_expect(fields.find("snowpack_arr") != -1, "snowpack_arr included")
	_expect(fields.find("water_balance_30d_arr") != -1, "water_balance_30d_arr included")
	_expect(fields.find("slp_arr") != -1 and fields.find("wind_x_arr") != -1, "physical field SoA columns included")
	_expect(fields.find("terrain_arr") != -1, "terrain_arr included")
	_expect(fields.find("country_slot_arr") != -1,
		"country ownership SoA column included")
	_expect(fields.find("demo_thermal_gradient_arr") == -1, "size 0 demo array excluded")
	_expect(fields.find("_neighbor_indices") == -1, "neighbor topology excluded")


func _test_native_csv_encoder_if_available() -> void:
	if not ClassDB.class_exists("DCWorldExt"):
		print("  [SKIP] native csv encoder unavailable")
		return
	var ext = ClassDB.instantiate("DCWorldExt")
	if ext == null or not ext.has_method("encode_tile_csv_rows"):
		print("  [SKIP] native csv encoder method unavailable")
		return

	var arrays: Array = [
		PackedFloat32Array([1.25, NAN]),
		PackedInt32Array([7, -8]),
		PackedByteArray([255, 0]),
	]
	var field_types := PackedInt32Array([
		TYPE_PACKED_FLOAT32_ARRAY,
		TYPE_PACKED_INT32_ARRAY,
		TYPE_PACKED_BYTE_ARRAY,
	])
	var q_arr := PackedInt32Array([10, 11])
	var r_arr := PackedInt32Array([20, 21])
	var s_arr := PackedInt32Array([-30, -32])
	var fixed_suffix: String = ",101,2000,false"
	var encoded: PackedByteArray = ext.call("encode_tile_csv_rows", {
		"row_start": 5,
		"fixed_suffix": fixed_suffix,
		"cell_start": 0,
		"cell_count": 2,
		"cell_stride": 1,
		"q_arr": q_arr,
		"r_arr": r_arr,
		"s_arr": s_arr,
		"arrays": arrays,
	})
	var expected: String = TileDataRecorder._format_record_line(
		5, fixed_suffix, 0, q_arr[0], r_arr[0], s_arr[0], arrays, field_types
	) + "\n" + TileDataRecorder._format_record_line(
		6, fixed_suffix, 1, q_arr[1], r_arr[1], s_arr[1], arrays, field_types
	) + "\n"
	_expect(encoded.get_string_from_utf8() == expected, "native csv encoder matches GDScript formatter")


func _test_state_machine_and_export() -> void:
	var main := _MockMain.new()
	main.map = _MockMap.new(2)
	var rec := TileDataRecorder.new()
	rec.bind_main(main)
	rec.start()
	_expect(rec.is_recording(), "start recording")
	rec.on_fast_tick(_sample(1))
	rec.on_fast_tick(_sample(2))
	_expect(rec.tick_count() == 2, "2 ticks captured")
	_expect(rec.row_count() == 4, "2 cells * 2 ticks = 4 rows")
	var path: String = rec.stop_and_export()
	_expect(path != "", "stop returns path")
	_expect(not rec.is_recording(), "stopped")
	if path == "":
		return
	var f := FileAccess.open(path, FileAccess.READ)
	_expect(f != null, "export readable")
	if f == null:
		return
	f.get_8(); f.get_8(); f.get_8()
	var header: String = f.get_line()
	var line0: String = f.get_line()
	var line1: String = f.get_line()
	f.close()
	_expect(header.begins_with("row_idx,tick_idx,timestamp_ms"), "header fixed columns first")
	var cols: PackedStringArray = header.split(",")
	_expect(cols.find("cell_index") != -1, "cell_index column present")
	_expect(cols.find("q") != -1 and cols.find("r") != -1 and cols.find("s") != -1, "cube columns present")
	_expect(cols.find("temp_arr") != -1 and cols.find("temp_arr_prev") != -1 and cols.find("terrain_arr") != -1, "SoA columns present")
	_expect(cols.find("country_slot_arr") != -1,
		"country ownership column present")
	_expect(cols.find("snowpack_arr") != -1 and cols.find("water_balance_30d_arr") != -1, "new climate closure columns present")
	_expect(cols.find("climate_slp_abs_p95") != -1, "slp p95 column present")
	_expect(cols.find("climate_wind_mag_p95") != -1, "wind magnitude p95 column present")
	_expect(cols.find("climate_ocean_mag_p95") != -1, "ocean magnitude p95 column present")
	_expect(cols.find("climate_upwelling_abs_p95") != -1, "upwelling p95 column present")
	_expect(cols.find("climate_moisture_committed") != -1 \
		and cols.find("climate_moisture_commit_path") != -1 \
		and cols.find("climate_moisture_commit_slot_size") != -1 \
		and cols.find("climate_moisture_commit_flush_ms") != -1,
		"moisture commit diagnostics present")
	var parts0: PackedStringArray = line0.split(",")
	var parts1: PackedStringArray = line1.split(",")
	_expect(parts0[cols.find("row_idx")] == "0", "row 0 row_idx")
	_expect(parts1[cols.find("row_idx")] == "1", "row 1 row_idx")
	_expect(parts0[cols.find("cell_index")] == "0", "row 0 cell_index")
	_expect(parts1[cols.find("cell_index")] == "1", "row 1 cell_index")
	_expect(parts0[cols.find("climate_wind_mag_p95")] == "0.75", "wind speed p95 value")


func _test_auto_stop_on_map_change() -> void:
	var main := _MockMain.new()
	main.map = _MockMap.new(2)
	var rec := TileDataRecorder.new()
	rec.bind_main(main)
	rec.start()
	main.map = _MockMap.new(2)
	rec.on_fast_tick(_sample(1))
	_expect(not rec.is_recording(), "map change auto-stops")


func _test_auto_stop_on_cell_count_change() -> void:
	var main := _MockMain.new()
	var map := _MockMap.new(2)
	main.map = map
	var rec := TileDataRecorder.new()
	rec.bind_main(main)
	rec.start()
	map._cells.append(_Cell.new(2, -2, 0))
	rec.on_fast_tick(_sample(1))
	_expect(not rec.is_recording(), "cell_count change auto-stops")


func _test_sidecar_metadata_and_export_path() -> void:
	var main := _MockMain.new()
	main.map = _MockMap.new(2)
	var rec := TileDataRecorder.new()
	rec.bind_main(main)
	var output_dir := ProjectSettings.globalize_path("user://stage_c_tests/tile")
	var csv_path := output_dir.path_join("tile_data.csv")
	var sidecar_path := output_dir.path_join("tile_data.sidecar.json")
	rec.start({
		"run_id": "test-active", "seed": 20260718, "map_width": 60,
		"map_height": 40, "graphics_profile": "high", "authority_mode": "ACTIVE",
		"worker_mode": "ACTIVE", "tick_stride": 1, "cell_stride": 1,
		"compact_fields": false, "output_dir": output_dir,
		"csv_path": csv_path, "sidecar_path": sidecar_path,
	})
	rec.on_fast_tick(_sample(1))
	var exported := rec.stop_and_export()
	_expect(exported == csv_path and FileAccess.file_exists(csv_path), "explicit tile CSV path")
	_expect(rec.sidecar_path() == sidecar_path and FileAccess.file_exists(sidecar_path),
		"sidecar path exported")
	var parsed = JSON.parse_string(FileAccess.get_file_as_string(sidecar_path))
	_expect(parsed is Dictionary, "sidecar JSON parses")
	if not (parsed is Dictionary):
		return
	var sidecar: Dictionary = parsed
	_expect(sidecar.schema == "TileDataRecorderSidecar" and sidecar.complete,
		"sidecar schema and completion")
	_expect(sidecar.authority_mode == "ACTIVE" and sidecar.worker_mode == "ACTIVE",
		"sidecar authority metadata")
	_expect(sidecar.tick_coverage.recorded_ticks == 1 and sidecar.cell_coverage.rows == 2,
		"sidecar tick and cell coverage")
	_expect(sidecar.soa_fields.has("temp_arr") and sidecar.runtime.committed_day == 2 \
		and sidecar.runtime.writeback_day == 2, "sidecar fields and runtime days")
	var country_evidence: Dictionary = sidecar.get("country_evidence", {})
	var country_samples: Array = country_evidence.get("samples", [])
	var receipts: Array = country_evidence.get("terminal_receipts", [])
	_expect(country_evidence.get("schema", "") == "CountryClientEvidence" \
		and country_samples.size() == 1,
		"sidecar includes one Country client evidence sample")
	if country_samples.size() == 1:
		var country_sample: Dictionary = country_samples[0]
		var countries: Array = country_sample.get("countries", [])
		_expect(int(country_sample.get("reference_state_hash", 0)) == 111 \
			and int(country_sample.get("worker_state_hash", 0)) == 222 \
			and countries.size() == 1 \
			and int((countries[0] as Dictionary).get("cash", 0)) == 100,
			"Country evidence records reference/worker hash and treasury")
	_expect(receipts.size() == 1 \
		and String((receipts[0] as Dictionary).get("status", "")) == "Committed" \
		and int(country_evidence.get("last_receipt_request_id", 0)) == 7,
		"Country evidence records terminal receipt lifecycle")
