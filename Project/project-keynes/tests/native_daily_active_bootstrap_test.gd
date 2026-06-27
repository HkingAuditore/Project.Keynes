extends SceneTree

# Headless:
#   godot --headless --script tests/native_daily_active_bootstrap_test.gd --quit
#
# Verifies native_daily_sim_mode=ACTIVE can cold-start through the unified
# weather path when the explicit weather active-owner gate is enabled.

var _checks: int = 0
var _failures: int = 0


func _init() -> void:
	_run()
	quit(0 if _failures == 0 else 1)


func _run() -> void:
	print("=== native daily active bootstrap ===")
	if not ClassDB.class_exists("DCWorldExt"):
		_skip("DCWorldExt class not found")
		return

	var profile: ClimateProfile = _make_profile()
	var cfg: MapConfig = MapConfig.make(10, 8)
	cfg.seed = 717171
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

	var tick_res: Dictionary = {}
	var native_res: Dictionary = {}
	var completed_native_res: Dictionary = {}
	var ocean_report: Dictionary = {}
	var first_ocean_day: int = -1
	var completed_native_day: int = -1
	var native_completed_days: int = 0
	var max_native_slices_in_tick: int = 0
	for day in range(1, 25):
		tick_res = generator.sus_tick_daily(null, day, float(day % 365) / 365.0)
		native_res = generator.native_daily_last_result()
		if int(native_res.get("rc", -1)) == 0 \
				and str(native_res.get("path", "")) == "gdext_native_daily_slice" \
				and bool(native_res.get("done", false)):
			if completed_native_res.is_empty():
				completed_native_res = native_res
			native_completed_days += 1
			if completed_native_day < 0:
				completed_native_day = day
		var tick_report_now: Dictionary = generator.sus_report_last_tick()
		var native_report_now: Dictionary = tick_report_now.get(&"native_daily_sim", tick_report_now.get("native_daily_sim", {}))
		if not native_report_now.is_empty():
			max_native_slices_in_tick = maxi(max_native_slices_in_tick, int(native_report_now.get("slices_run", 0)))
		var ocean_report_now: Dictionary = tick_report_now.get(&"ocean_currents", tick_report_now.get("ocean_currents", {}))
		if not ocean_report_now.is_empty() and int(ocean_report_now.get("slices_run", 0)) > 0:
			ocean_report = ocean_report_now
			if first_ocean_day < 0:
				first_ocean_day = day
		if not completed_native_res.is_empty() and not ocean_report.is_empty() and native_completed_days >= 3:
			break
	if completed_native_res.is_empty():
		completed_native_res = native_res
	var state: Dictionary = completed_native_res.get("native_state_snapshot", native_res.get("native_state_snapshot", {}))
	var pass_keys: Array = completed_native_res.get("bundle_pass_keys", native_res.get("bundle_pass_keys", native_res.get("pass_keys", [])))
	var authority: Dictionary = completed_native_res.get("authority_report", state.get("authority_report", {}))
	var weather_authority: Dictionary = authority.get("weather_transaction", {})
	var weather_breakdown: Dictionary = generator.sus_weather_breakdown()
	var native_breakdown: Dictionary = completed_native_res.get("breakdown", {})
	var tta_arr: PackedFloat32Array = map.temperature_transport_anomaly_arr
	var tta_has_signal: bool = false
	for v in tta_arr:
		if absf(float(v)) > 0.000001:
			tta_has_signal = true
			break

	_expect("sus tick returns dictionary", typeof(tick_res) == TYPE_DICTIONARY)
	_expect("active path retains ocean physical boundary", not ocean_report.is_empty() and int(ocean_report.get("slices_run", 0)) > 0)
	_expect("active path does not bucket-gate daily wind", first_ocean_day > 0 and first_ocean_day <= 2)
	_expect("active native daily completed through slice path", int(completed_native_res.get("rc", -1)) == 0 and str(completed_native_res.get("path", "")) == "gdext_native_daily_slice" and bool(completed_native_res.get("done", false)))
	_expect("active native daily completes during bootstrap", completed_native_day > 0 and completed_native_day <= 4)
	_expect("active native daily keeps completing rounds", native_completed_days >= 3)
	_expect("active native daily can consume multiple graph slices in one tick", max_native_slices_in_tick > 1)
	_expect("active native daily includes moisture pass", pass_keys.has("climate_pass_b_knobs") and completed_native_res.get("published_slots", []).has("cell_moisture"))
	_expect("active native daily applies jit bundle patches", int(native_breakdown.get("jit_patch_key_count", 0)) > 0)
	_expect("active native daily applies climate finalizer", bool(native_breakdown.get("thermal_finalizer_applied", false)))
	_expect("active native daily publishes ocean heat transport state", bool(native_breakdown.get("native_daily_tta_published", false)))
	_expect("ocean heat transport anomaly has signal", tta_arr.size() == map.soa_size() and tta_has_signal)
	_expect("active bundle embeds weather knobs", pass_keys.has("weather_knobs"))
	_expect("weather owner becomes native-active on bootstrap", str(state.get("weather_transaction_state_owner", "")) == "native_active")
	_expect("weather active bootstrap reason is reported", str(weather_authority.get("readiness", {}).get("reason", "")) == "active_bootstrap_unified_publish")
	_expect("weather LUT is published in active bootstrap", bool(completed_native_res.get("weather_lut_published", false)))
	_expect("front signature is reported in active bootstrap", str(completed_native_res.get("fronts_signature", "")) != "")
	_expect("weather breakdown fronts is numeric", typeof(weather_breakdown.get("fronts", null)) == TYPE_INT)
	_finish()


func _make_profile() -> ClimateProfile:
	var loaded := ResourceLoader.load("res://data/world/earth_like.tres", "Resource") as ClimateProfile
	var profile: ClimateProfile = loaded.duplicate(true) if loaded != null else ClimateProfile.new()
	profile.native_generation_mode = ClimateProfile.NATIVE_MODE_ACTIVE
	profile.native_daily_sim_mode = ClimateProfile.NATIVE_MODE_ACTIVE
	profile.native_shadow_diff_enabled = true
	profile.native_climate_round_active_owner_enabled = true
	profile.native_weather_transaction_active_owner_enabled = true
	profile.native_ocean_physical_active_owner_enabled = true
	profile.weather_field_enabled = true
	profile.runtime_hydrology_enabled = false
	profile.native_environment_runtime_enabled = false
	profile.dynamic_visual_atlas_upload_stride = 8
	profile.enum_atlas_upload_stride = 8
	return profile


func _skip(reason: String) -> void:
	print("  [SKIP] %s" % reason)
	_finish()


func _finish() -> void:
	print("=== done: %d checks, %d failures ===" % [_checks, _failures])


func _expect(label: String, ok: bool) -> void:
	_checks += 1
	if ok:
		print("  [PASS] %s" % label)
	else:
		_failures += 1
		printerr("  [FAIL] %s" % label)
