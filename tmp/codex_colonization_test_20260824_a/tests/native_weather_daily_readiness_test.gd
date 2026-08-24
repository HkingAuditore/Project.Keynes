extends SceneTree

# Headless:
#   godot --headless --script tests/native_weather_daily_readiness_test.gd --quit
#
# Runs legacy-authoritative weather for several days, then verifies that the
# native daily weather gate upgrades to native_active only after visible publish
# and the explicit active-owner profile gate are both enabled.

const CHECK_DAYS := 12

var _checks: int = 0
var _failures: int = 0


func _init() -> void:
	_run()
	quit(0 if _failures == 0 else 1)


func _run() -> void:
	print("=== native weather daily readiness ===")
	if not ClassDB.class_exists("DCWorldExt"):
		_skip("DCWorldExt class not found")
		return

	var profile: ClimateProfile = _make_profile()
	var cfg: MapConfig = MapConfig.make(10, 8)
	cfg.seed = 626262
	cfg.num_continents = 1
	cfg.sea_level = 0.58
	cfg.continent_size = 0.72
	cfg.climate_profile = profile

	var generator := MapGenerator.new()
	generator.climate_profile = profile
	var generated: Dictionary = await generator.generate(cfg, 10.0)
	var map: MapData = generated.get("map", null) as MapData
	var world: WorldData = generated.get("world_data", null) as WorldData
	_expect("map generation returned map", map != null)
	_expect("map generation returned world_data", world != null)
	if _failures > 0:
		_finish()
		return

	var ready_seen := false
	var weather_probe_seen := false
	var weather_owner_active_seen := false
	var weather_publish_slots_seen := false
	var weather_lut_intent_ready_seen := false

	for day in range(1, CHECK_DAYS + 1):
		var phase := float(day % 365) / 365.0
		generator.sus_tick_daily(null, day, phase)
		var readiness: Dictionary = generator.weather_native_daily_readiness_report()
		var native_res: Dictionary = generator.native_daily_last_result()
		var state: Dictionary = native_res.get("native_state_snapshot", {})
		var authority: Dictionary = native_res.get("authority_report", state.get("authority_report", {}))
		var weather_authority: Dictionary = authority.get("weather_transaction", {})
		var pass_keys: Array = native_res.get("bundle_pass_keys", native_res.get("pass_keys", []))
		if bool(readiness.get("ready", false)):
			ready_seen = true
		if pass_keys.has("weather_knobs"):
			weather_probe_seen = true
		if str(state.get("weather_transaction_state_owner", "")) == "native_active" \
				and bool(weather_authority.get("simulation_authority", false)):
			weather_owner_active_seen = true
		var expected_slots: Array = weather_authority.get("publish_slots_expected", [])
		if expected_slots.has("cell_weather_type") \
				and expected_slots.has("cell_weather_precip") \
				and expected_slots.has("cell_weather_transition_alpha"):
			weather_publish_slots_seen = true
		if bool(weather_authority.get("weather_lut_intent_ready", false)):
			weather_lut_intent_ready_seen = true

	_expect("weather visible publish readiness becomes true", ready_seen)
	_expect("native daily shadow includes weather knobs after readiness", weather_probe_seen)
	_expect("weather transaction owner becomes native-active", weather_owner_active_seen)
	_expect("weather publish slot contract is declared", weather_publish_slots_seen)
	_expect("weather LUT intent gate is ready", weather_lut_intent_ready_seen)

	var exec_ctx := SusTickContext.make(9000, CHECK_DAYS + 1, float((CHECK_DAYS + 1) % 365) / 365.0, 1.0, &"native_weather_exec")
	var exec_res: Dictionary = generator.run_native_daily_tick_from_job(exec_ctx, map, world)
	var exec_diff: Dictionary = exec_res.get("fronts_diff", {})
	_expect("native weather execution succeeds", int(exec_res.get("rc", -1)) == 0)
	_expect("native weather execution publishes LUT", bool(exec_res.get("weather_lut_published", false)))
	_expect("native weather execution reports LUT path", str(exec_res.get("weather_lut_publish_path", "")) != "")
	_expect("native weather execution reports front signature", str(exec_res.get("fronts_signature", "")) != "")
	_expect("native weather fronts_changed follows signature diff", bool(exec_res.get("fronts_changed", false)) == bool(exec_diff.get("changed", false)))
	_finish()


func _make_profile() -> ClimateProfile:
	var loaded := ResourceLoader.load("res://data/world/earth_like.tres", "Resource") as ClimateProfile
	var profile: ClimateProfile = loaded.duplicate(true) if loaded != null else ClimateProfile.new()
	profile.native_generation_mode = ClimateProfile.NATIVE_MODE_ACTIVE
	profile.native_daily_sim_mode = ClimateProfile.NATIVE_MODE_SHADOW
	profile.native_shadow_diff_enabled = true
	profile.native_weather_transaction_active_owner_enabled = true
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
