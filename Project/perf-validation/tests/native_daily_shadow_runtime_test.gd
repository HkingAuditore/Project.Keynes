extends SceneTree

# Headless:
#   godot --headless --script tests/native_daily_shadow_runtime_test.gd --quit
#
# Generates a compact real map, runs one legacy-authoritative SUS day with
# native_daily_sim_mode=SHADOW, and verifies that the native daily probe now
# covers wind_air/wind_surface instead of failing the bundle contract.

var _checks: int = 0
var _failures: int = 0


func _init() -> void:
	_run()
	quit(0 if _failures == 0 else 1)


func _run() -> void:
	print("=== native daily shadow runtime smoke ===")
	if not ClassDB.class_exists("DCWorldExt"):
		_skip("DCWorldExt class not found")
		return

	var profile: ClimateProfile = _make_profile()
	var cfg: MapConfig = MapConfig.make(10, 8)
	cfg.seed = 424242
	cfg.num_continents = 1
	cfg.sea_level = 0.62
	cfg.continent_size = 0.65
	cfg.climate_profile = profile

	var generator := MapGenerator.new()
	generator.climate_profile = profile
	var generated: Dictionary = await generator.generate(cfg, 10.0)
	_expect("map generation returned map", generated.has("map") and generated["map"] != null)
	_expect("map generation returned world_data", generated.has("world_data") and generated["world_data"] != null)
	if _failures > 0:
		_finish()
		return

	var tick_res: Dictionary = generator.sus_tick_daily(null, 1, 0.25)
	_expect("sus tick returns dictionary", typeof(tick_res) == TYPE_DICTIONARY)

	var native_res: Dictionary = generator.native_daily_last_result()
	_expect("shadow probe ran", str(native_res.get("mode", "")) == "shadow_probe")
	_expect("shadow probe succeeded", int(native_res.get("rc", -1)) == 0)
	_expect("shadow probe is authoritative-ready", bool(native_res.get("authoritative_ready", false)))
	var boundary_contract: Dictionary = native_res.get("boundary_contract", {})
	_expect("native boundary contract is reported", not boundary_contract.is_empty())
	_expect("native boundary contract has bootstrap keys", boundary_contract.get("bootstrap_config_keys", []).has("climate_round_state_snapshot"))
	_expect("native boundary contract has tick delta keys", boundary_contract.get("tick_delta_keys", []).has("wind_air_knobs"))

	var pass_keys: Array = native_res.get("bundle_pass_keys", [])
	if pass_keys.is_empty():
		pass_keys = native_res.get("pass_keys", [])
	_expect("bundle includes wind_air", pass_keys.has("wind_air_knobs"))
	_expect("bundle includes wind_surface", pass_keys.has("wind_surface_knobs"))

	var missing: Array = native_res.get("missing_pass_keys", [])
	_expect("required pass keys are complete", missing.is_empty())
	var state: Dictionary = native_res.get("native_state_snapshot", {})
	var authority_report: Dictionary = native_res.get("authority_report", {})
	var authority_blockers: Array = native_res.get("authority_blockers", [])
	if authority_report.is_empty():
		authority_report = state.get("authority_report", {})
	if authority_blockers.is_empty():
		authority_blockers = state.get("authority_blockers", [])
	_expect("native authority report is present", not authority_report.is_empty())
	_expect("native authority blockers are present", not authority_blockers.is_empty())
	_expect("weather authority is reported", authority_report.has("weather_transaction"))
	_expect("ocean authority is reported", authority_report.has("ocean_physical"))
	_expect("season authority is reported", authority_report.has("season_refresh"))
	_expect("graph coverage remains partial", str(native_res.get("graph_coverage_state", state.get("graph_coverage_state", ""))) != "complete")
	var ocean_state: Dictionary = state.get("ocean_physical_state", {})
	var ocean_authority: Dictionary = authority_report.get("ocean_physical", {})
	_expect("ocean physical state is mirrored", not ocean_state.is_empty())
	_expect("ocean physical authority state is reported", typeof(ocean_authority.get("state", {})) == TYPE_DICTIONARY)
	var season_state: Dictionary = state.get("season_refresh_state", {})
	var season_authority: Dictionary = authority_report.get("season_refresh", {})
	var season_dirty: Array = season_authority.get("simulation_slot_dirty_intents", [])
	_expect("season refresh state is mirrored", not season_state.is_empty())
	_expect("season simulation dirty intents are reported", season_dirty.has("cell_vegetation") and season_dirty.has("cell_weather_dirty"))
	var weather_authority: Dictionary = authority_report.get("weather_transaction", {})
	_expect("weather readiness is reported", typeof(weather_authority.get("readiness", {})) == TYPE_DICTIONARY)
	_expect("weather publish slots are declared", weather_authority.get("publish_slots_expected", []).has("cell_weather_transition_alpha") or not bool(weather_authority.get("visible_publish_ready", false)))
	var climate_state: Dictionary = state.get("climate_round_state", {})
	var native_probe_state: Dictionary = climate_state.get("native_probe_state", {})
	_expect("climate round owner is native-active", str(state.get("climate_round_state_owner", "")) == "native_active")
	_expect("climate round state mirror is native-active", str(climate_state.get("owner", "")) == "native_active")
	_expect("native climate active state is present", str(native_probe_state.get("authority", "")) == "native_active_owner")
	_expect("native climate active owner is authority", bool(native_probe_state.get("simulation_authority", false)))
	_expect("native climate lifecycle probe is present", str(native_probe_state.get("lifecycle_owner", "")) == "native_probe_lifecycle")
	_expect("native climate readiness is true", bool(native_probe_state.get("climate_round_authority_ready", false)))
	var remaining_boundaries: Array = native_probe_state.get("remaining_gdscript_authority", [])
	_expect("native climate active keeps boundary list", remaining_boundaries.has("godot_mapdata_boundary_execution"))
	var remaining_sim_authority: Array = native_probe_state.get("remaining_gdscript_simulation_authority", [])
	_expect("native climate active retires simulation authority list", remaining_sim_authority.is_empty())
	_expect("native climate active fallback is failure-only", str(native_probe_state.get("fallback_mode", "")) == "explicit_failure_only")
	var boundary_intents: Array = native_probe_state.get("boundary_intents", [])
	_expect("native climate boundary intents are present", boundary_intents.has("sync_runtime_terrain_views") and boundary_intents.has("soa_begin_climate_transaction"))
	_finish()


func _make_profile() -> ClimateProfile:
	var loaded := ResourceLoader.load("res://data/world/earth_like.tres", "Resource") as ClimateProfile
	var profile: ClimateProfile = loaded.duplicate(true) if loaded != null else ClimateProfile.new()
	profile.native_generation_mode = ClimateProfile.NATIVE_MODE_ACTIVE
	profile.native_daily_sim_mode = ClimateProfile.NATIVE_MODE_SHADOW
	profile.native_shadow_diff_enabled = true
	profile.native_climate_round_active_owner_enabled = true
	profile.weather_field_enabled = false
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
