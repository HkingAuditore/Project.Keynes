extends SceneTree

const PkmapIOScript = preload("res://scripts/geography/pkmap_io.gd")

var _checks := 0
var _failures := 0


func _init() -> void:
	_run()
	print("=== authored map: %d checks, %d failures ===" % [_checks, _failures])
	quit(0 if _failures == 0 else 1)


func _expect(label: String, condition: bool) -> void:
	_checks += 1
	print("  [%s] %s" % ["PASS" if condition else "FAIL", label])
	if not condition:
		_failures += 1


func _run() -> void:
	_test_pkmap_roundtrip()
	_test_pkmap_bypass()
	_test_post_base_lake()


func _filled_f32(n: int, value: float) -> PackedFloat32Array:
	var arr := PackedFloat32Array()
	arr.resize(n)
	for i in range(n):
		arr[i] = value
	return arr


func _filled_u8(n: int, value: int) -> PackedByteArray:
	var arr := PackedByteArray()
	arr.resize(n)
	for i in range(n):
		arr[i] = value
	return arr


func _filled_i32(n: int, value: int) -> PackedInt32Array:
	var arr := PackedInt32Array()
	arr.resize(n)
	for i in range(n):
		arr[i] = value
	return arr


func _synthetic_payload(width: int, height: int) -> Dictionary:
	var qr: Dictionary = PkmapIOScript.odd_r_qr_arrays(width, height)
	var n: int = int(qr["n_cells"])
	var elevation := PackedFloat32Array()
	elevation.resize(n)
	for row in range(height):
		for col in range(width):
			var i := row * width + col
			var inland: bool = col > 2 and col < width - 3 and row > 1 and row < height - 2
			elevation[i] = 0.62 if inland else 0.22
	var terrain: PackedByteArray = PkmapIOScript.initial_terrain_from_elevation(elevation, width, height, 0.5)
	return {
		"q_arr": qr["q_arr"],
		"r_arr": qr["r_arr"],
		"elevation_arr": elevation,
		"moisture_arr": _filled_f32(n, 0.45),
		"base_moisture_arr": _filled_f32(n, 0.45),
		"temp_arr": _filled_f32(n, 0.55),
		"terrain_arr": terrain,
		"landform_arr": _filled_u8(n, 0),
		"vegetation_arr": _filled_u8(n, 0),
		"cover_arr": _filled_u8(n, 0),
		"vegetation_vitality_arr": _filled_f32(n, 0.5),
		"soil_moisture_arr": _filled_f32(n, 0.4),
		"water_balance_30d_arr": _filled_f32(n, 0.0),
		"plant_available_water_arr": _filled_f32(n, 0.4),
		"vegetation_growth_pressure_arr": _filled_f32(n, 0.0),
		"vegetation_heat_stress_arr": _filled_f32(n, 0.0),
		"vegetation_drought_stress_arr": _filled_f32(n, 0.0),
		"vegetation_cold_stress_arr": _filled_f32(n, 0.0),
		"vegetation_regen_score_arr": _filled_f32(n, 0.0),
		"has_river_arr": _filled_u8(n, 0),
		"river_flow_arr": _filled_f32(n, 0.0),
		"river_downstream_arr": _filled_i32(n, -1),
		"hydro_parent_arr": _filled_i32(n, -1),
		"n_cells": n,
	}


func _test_pkmap_roundtrip() -> void:
	var width := 10
	var height := 8
	var payload := _synthetic_payload(width, height)
	var path := "user://authored_map_roundtrip.pkmap"
	var written: Dictionary = PkmapIOScript.write_pkmap(path, {
		"width": width,
		"height": height,
		"n_cells": width * height,
		"sea_level": 0.5,
		"seed": 11,
	}, payload)
	_expect("pkmap write ok", bool(written.get("ok", false)))
	var loaded: Dictionary = PkmapIOScript.read_pkmap(path)
	_expect("pkmap read ok", bool(loaded.get("ok", false)))
	_expect("pkmap n_cells", int(loaded.get("n_cells", 0)) == width * height)
	_expect("pkmap generator_hash",
		String((loaded.get("header", {}) as Dictionary).get("generator_hash", ""))
		== SaveRepository.compatibility_hash())
	var cfg := MapConfig.make(width, height)
	var assembled: MapData = DCTerrainGenerator.new(null).assemble_native_result(
		PkmapIOScript.native_result_from_payload(loaded.get("payload", {}), loaded.get("header", {})),
		cfg)
	_expect("assemble synthetic pkmap", assembled != null and assembled.cell_count() == width * height)


func _test_pkmap_bypass() -> void:
	if not ClassDB.class_exists("DCWorldExt"):
		print("[SKIP] DCWorldExt unavailable for pkmap bypass")
		return
	var ext: Object = ClassDB.instantiate("DCWorldExt")
	if ext == null or not ext.has_method("restuff_generation_river_cache"):
		print("[SKIP] restuff_generation_river_cache missing; rebuild dots_ext.dll")
		return
	var width := 10
	var height := 8
	var payload := _synthetic_payload(width, height)
	var path := "user://authored_map_bypass.pkmap"
	var written: Dictionary = PkmapIOScript.write_pkmap(path, {
		"width": width,
		"height": height,
		"n_cells": width * height,
		"sea_level": 0.5,
		"seed": 13,
	}, payload)
	_expect("bypass pkmap write", bool(written.get("ok", false)))
	var generator := MapGenerator.new()
	var cfg := MapConfig.make(width, height)
	cfg.map_source = "pkmap"
	cfg.pkmap_path = ProjectSettings.globalize_path(path)
	cfg.sea_level = 0.5
	cfg.seed = 13
	var map: MapData = generator._generate_cells_native_base(cfg, 13)
	_expect("generate pkmap returns map", map != null)
	_expect("generate pkmap n_cells", map != null and map.cell_count() == width * height)
	_expect("generate path=pkmap", String(generator._native_generation_base_report.get("path", "")) == "pkmap")
	_expect("generate pkmap no fallback", not bool(generator._native_generation_base_report.get("fallback", true)))
	var procedural := MapConfig.make(width, height)
	procedural.map_source = "pkmap"
	procedural.pkmap_path = ""
	var failed: MapData = generator._generate_cells_native_base(procedural, 13)
	_expect("empty pkmap_path hard-aborts", failed == null)
	_expect("empty path does not fallback to gdscript generate",
		String(generator._native_generation_base_report.get("path", "")) == "pkmap")


func _test_post_base_lake() -> void:
	if not ClassDB.class_exists("DCWorldExt"):
		print("[SKIP] DCWorldExt unavailable for lake post_base")
		return
	var ext: Object = ClassDB.instantiate("DCWorldExt")
	if ext == null or not ext.has_method("run_native_world_generate_post_base_pass"):
		print("[SKIP] post_base missing")
		return
	var width := 16
	var height := 12
	var n := width * height
	var sea_level := 0.5
	var qr: Dictionary = PkmapIOScript.odd_r_qr_arrays(width, height)
	var elevation := PackedFloat32Array()
	var moisture := PackedFloat32Array()
	var lake_seed := PackedByteArray()
	elevation.resize(n)
	moisture.resize(n)
	lake_seed.resize(n)
	for row in range(height):
		for col in range(width):
			var i := row * width + col
			var inland: bool = col > 2 and col < width - 3 and row > 2 and row < height - 3
			var basin: bool = col >= 6 and col <= 9 and row >= 5 and row <= 7
			if not inland:
				elevation[i] = 0.22
			elif basin:
				elevation[i] = 0.505
				lake_seed[i] = 1
			else:
				elevation[i] = 0.64
			moisture[i] = 0.55
	var terrain: PackedByteArray = PkmapIOScript.initial_terrain_from_elevation(
		elevation, width, height, sea_level)
	var generator := MapGenerator.new()
	var cfg := MapConfig.make(width, height)
	cfg.sea_level = sea_level
	var post_res: Dictionary = ext.run_native_world_generate_post_base_pass(
		21,
		generator._native_generation_cfg_dict(cfg),
		generator._native_generation_profile_dict(),
		{
			"q_arr": qr["q_arr"],
			"r_arr": qr["r_arr"],
			"elevation_arr": elevation,
			"moisture_arr": moisture,
			"terrain_arr": terrain,
			"is_lake_seed_arr": lake_seed,
		},
	)
	_expect("post_base rc=0", int(post_res.get("rc", -1)) == 0)
	_expect("post_base no fallback", not bool(post_res.get("fallback", true)))
	_expect("post_base n_cells", int(post_res.get("n_cells", 0)) == n)
	var lakes := 0
	if post_res.has("terrain_arr"):
		var tarr: PackedByteArray = post_res["terrain_arr"]
		for i in range(tarr.size()):
			if int(tarr[i]) == TerrainType.TERRAIN.LAKE:
				lakes += 1
	_expect("lake basin becomes LAKE", lakes >= 8)
	var restuff_in := post_res.duplicate(true)
	restuff_in["width"] = width
	restuff_in["height"] = height
	if ext.has_method("restuff_generation_river_cache"):
		var restuff: Dictionary = ext.restuff_generation_river_cache(restuff_in)
		_expect("restuff rc=0", int(restuff.get("rc", -1)) == 0 and bool(restuff.get("ok", false)))
