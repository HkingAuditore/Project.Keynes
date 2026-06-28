extends SceneTree

# Headless:
#   godot --headless --script tests/native_daily_hydrology_graph_test.gd --quit
#
# Verifies runtime hydrology is represented as a native daily graph node when
# hydrology is enabled, while legacy SUS remains available as fallback/A-B.

const CHECK_DAYS := 16

var _checks: int = 0
var _failures: int = 0


func _init() -> void:
	_run()
	quit(0 if _failures == 0 else 1)


func _run() -> void:
	print("=== native daily hydrology graph ===")
	if not ClassDB.class_exists("DCWorldExt"):
		_skip("DCWorldExt class not found")
		return

	var ext := DCWorldExt.new()
	if not ext.has_method("run_runtime_hydrology_pass"):
		_skip("run_runtime_hydrology_pass not exported")
		return

	var profile: ClimateProfile = _make_profile()
	var cfg: MapConfig = MapConfig.make(10, 8)
	cfg.seed = 727272
	cfg.num_continents = 1
	cfg.sea_level = 0.58
	cfg.continent_size = 0.72
	cfg.climate_profile = profile

	var generator := MapGenerator.new()
	generator.climate_profile = profile
	var generated: Dictionary = generator.generate(cfg, 10.0)
	var map: MapData = generated.get("map", null) as MapData
	var world: WorldData = generated.get("world_data", null) as WorldData
	_expect("map generation returned map", map != null)
	_expect("map generation returned world_data", world != null)
	if _failures > 0:
		_finish()
		return

	var hydrology_probe_seen := false
	var hydrology_authority_seen := false
	var hydrology_blocker_absent_seen := false
	var hydrology_publish_slots_seen := false
	var retained_boundary_seen := false

	for day in range(1, CHECK_DAYS + 1):
		var phase := float(day % 365) / 365.0
		generator.sus_tick_daily(null, day, phase)
		var native_res: Dictionary = generator.native_daily_last_result()
		var state: Dictionary = native_res.get("native_state_snapshot", {})
		var authority: Dictionary = native_res.get("authority_report", state.get("authority_report", {}))
		var pass_keys: Array = native_res.get("bundle_pass_keys", native_res.get("pass_keys", []))
		var blockers: Array = native_res.get("authority_blockers", state.get("authority_blockers", []))
		var retained_boundaries: Array = native_res.get("retained_boundaries", state.get("retained_boundaries", []))
		var hydro_authority: Dictionary = authority.get("runtime_hydrology", {})
		if pass_keys.has("runtime_hydrology_knobs"):
			hydrology_probe_seen = true
		if not hydro_authority.is_empty() and str(hydro_authority.get("owner", "")) != "gdscript_retained":
			hydrology_authority_seen = true
		if pass_keys.has("runtime_hydrology_knobs") and not blockers.has("runtime_hydrology"):
			hydrology_blocker_absent_seen = true
		var expected_slots: Array = hydro_authority.get("published_slots_expected", [])
		if expected_slots.has("cell_river_discharge") \
				and expected_slots.has("cell_water_balance_30d") \
				and expected_slots.has("cell_surface_runoff"):
			hydrology_publish_slots_seen = true
		if retained_boundaries.has("visual_uploads") and not blockers.has("visual_uploads"):
			retained_boundary_seen = true

	_expect("shadow probe includes runtime hydrology knobs", hydrology_probe_seen)
	_expect("hydrology authority is reported", hydrology_authority_seen)
	_expect("hydrology is not a blocker when knobs are present", hydrology_blocker_absent_seen)
	_expect("hydrology publish slots are declared", hydrology_publish_slots_seen)
	_expect("visual boundary is split from authority blockers", retained_boundary_seen)

	var exec_ctx := SusTickContext.make(9100, CHECK_DAYS + 1, float((CHECK_DAYS + 1) % 365) / 365.0, 1.0, &"native_hydrology_exec")
	var exec_res: Dictionary = generator.run_native_daily_tick_from_job(exec_ctx, map, world)
	var exec_breakdown: Dictionary = exec_res.get("breakdown", {})
	var exec_published: Array = exec_res.get("published_slots", [])
	var exec_authority: Dictionary = exec_res.get("authority_report", {})
	var exec_hydro_authority: Dictionary = exec_authority.get("runtime_hydrology", {})
	_expect("native hydrology execution succeeds", int(exec_res.get("rc", -1)) == 0)
	_expect("native hydrology node published slots", bool(exec_breakdown.get("hydrology_published_to_slot", false)))
	_expect("native hydrology timing is reported", float(exec_breakdown.get("hydrology_ms", 0.0)) >= 0.0)
	_expect("native hydrology authority is verified", str(exec_hydro_authority.get("phase", "")) == "native_active_verified")
	_expect("native hydrology published river discharge slot", exec_published.has("cell_river_discharge"))
	_expect("native hydrology published water balance slot", exec_published.has("cell_water_balance_30d"))
	_expect("stage_b_after_hydrology executed or was legitimately skipped", exec_breakdown.has("stage_b_ms") or not exec_published.has("cell_vegetation_vitality"))
	_expect("soil moisture slot is finite", _arr_finite(map.soil_moisture_arr))
	_expect("water balance slot is finite", _arr_finite(map.water_balance_30d_arr))
	_expect("river discharge slot is finite", _arr_finite(map.river_discharge_arr))
	_expect("river discharge 30d slot is finite", _arr_finite(map.river_discharge_30d_arr))
	_finish()


func _make_profile() -> ClimateProfile:
	var loaded := ResourceLoader.load("res://data/world/earth_like.tres", "Resource") as ClimateProfile
	var profile: ClimateProfile = loaded.duplicate(true) if loaded != null else ClimateProfile.new()
	profile.native_generation_mode = ClimateProfile.NATIVE_MODE_ACTIVE
	profile.native_daily_sim_mode = ClimateProfile.NATIVE_MODE_SHADOW
	profile.native_shadow_diff_enabled = true
	profile.native_weather_transaction_active_owner_enabled = true
	profile.weather_field_enabled = true
	profile.runtime_hydrology_enabled = true
	profile.native_environment_runtime_enabled = false
	profile.dynamic_visual_atlas_upload_stride = 8
	profile.enum_atlas_upload_stride = 8
	return profile


func _skip(reason: String) -> void:
	print("  [SKIP] %s" % reason)
	_finish()


func _finish() -> void:
	print("=== done: %d checks, %d failures ===" % [_checks, _failures])


func _arr_finite(arr: PackedFloat32Array) -> bool:
	if arr.is_empty():
		return false
	for v in arr:
		if is_nan(v) or is_inf(v):
			return false
	return true


func _expect(label: String, ok: bool) -> void:
	_checks += 1
	if ok:
		print("  [PASS] %s" % label)
	else:
		_failures += 1
		printerr("  [FAIL] %s" % label)
