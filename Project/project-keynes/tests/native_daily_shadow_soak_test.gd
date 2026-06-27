extends SceneTree

# Headless:
#   godot --headless --script tests/native_daily_shadow_soak_test.gd --quit
#
# Multi-day SHADOW soak for native_daily wind graph coverage. Legacy SUS remains
# authoritative; the daily SHADOW path is a readiness probe, so this checks the
# contract over a short real-map window and then runs one explicit native tick
# sample to verify execution-only report fields such as wind timings.

const SOAK_DAYS := 32

var _checks: int = 0
var _failures: int = 0


func _init() -> void:
	_run()
	quit(0 if _failures == 0 else 1)


func _run() -> void:
	print("=== native daily shadow soak ===")
	if not ClassDB.class_exists("DCWorldExt"):
		_skip("DCWorldExt class not found")
		return

	var profile: ClimateProfile = _make_profile()
	var cfg: MapConfig = MapConfig.make(10, 8)
	cfg.seed = 515151
	cfg.num_continents = 1
	cfg.sea_level = 0.62
	cfg.continent_size = 0.65
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

	var rc_ok := 0
	var authoritative_ready_ok := 0
	var wind_key_ok := 0
	var missing_ok := 0
	var retained_wind_bad := 0
	var climate_owner_native_ready_ok := 0
	var climate_state_mirror_ok := 0
	var native_probe_state_ok := 0
	var native_probe_not_authority_ok := 0
	var native_lifecycle_probe_ok := 0
	var native_ready_with_boundaries_ok := 0
	var native_ready_sim_fallback_ok := 0
	var native_boundary_intents_ok := 0
	var native_finalize_front_intents_ok := 0
	var native_finalize_mid_intents_ok := 0
	var authority_report_ok := 0
	var authority_blockers_ok := 0
	var partial_coverage_ok := 0
	var ocean_state_ok := 0
	var ocean_native_ready_probe_ok := 0
	var season_state_ok := 0
	var season_dirty_intents_ok := 0
	var boundary_contract_ok := 0
	var temp_sane_ok := 0

	for day in range(1, SOAK_DAYS + 1):
		var phase := float(day % 365) / 365.0
		generator.sus_tick_daily(null, day, phase)
		var native_res: Dictionary = generator.native_daily_last_result()
		if int(native_res.get("rc", -1)) == 0:
			rc_ok += 1
		if bool(native_res.get("authoritative_ready", false)):
			authoritative_ready_ok += 1

		var pass_keys: Array = native_res.get("bundle_pass_keys", [])
		if pass_keys.has("wind_air_knobs") and pass_keys.has("wind_surface_knobs"):
			wind_key_ok += 1
		var missing: Array = native_res.get("missing_pass_keys", [])
		if missing.is_empty():
			missing_ok += 1

		var retained: Array = native_res.get("retained_gdscript_authority", [])
		if retained.has("wind_air") or retained.has("wind_surface"):
			retained_wind_bad += 1
		var state: Dictionary = native_res.get("native_state_snapshot", {})
		var authority_report: Dictionary = native_res.get("authority_report", {})
		var authority_blockers: Array = native_res.get("authority_blockers", [])
		if authority_report.is_empty():
			authority_report = state.get("authority_report", {})
		if authority_blockers.is_empty():
			authority_blockers = state.get("authority_blockers", [])
		if authority_report.has("weather_transaction") \
				and authority_report.has("ocean_physical") \
				and authority_report.has("season_refresh"):
			authority_report_ok += 1
		if not authority_blockers.is_empty() \
				and authority_blockers.has("legacy_sus_fallback_enabled"):
			authority_blockers_ok += 1
		if str(native_res.get("graph_coverage_state", state.get("graph_coverage_state", ""))) != "complete":
			partial_coverage_ok += 1
		var ocean_state: Dictionary = state.get("ocean_physical_state", {})
		if not ocean_state.is_empty():
			ocean_state_ok += 1
		if str(state.get("ocean_physical_state_owner", "")) == "native_ready_probe":
			var ocean_authority: Dictionary = authority_report.get("ocean_physical", {})
			var ocean_slots: Array = ocean_authority.get("native_owned_output_slots", [])
			if ocean_slots.has("cell_wind_x") and ocean_slots.has("cell_ocean_current_x"):
				ocean_native_ready_probe_ok += 1
		var season_state: Dictionary = state.get("season_refresh_state", {})
		if not season_state.is_empty():
			season_state_ok += 1
		var season_authority: Dictionary = authority_report.get("season_refresh", {})
		var season_dirty: Array = season_authority.get("simulation_slot_dirty_intents", [])
		if season_dirty.has("cell_vegetation") and season_dirty.has("cell_weather_dirty"):
			season_dirty_intents_ok += 1
		var boundary_contract: Dictionary = native_res.get("boundary_contract", {})
		var bootstrap_keys: Array = boundary_contract.get("bootstrap_config_keys", [])
		var tick_delta_keys: Array = boundary_contract.get("tick_delta_keys", [])
		if bootstrap_keys.has("climate_round_state_snapshot") and tick_delta_keys.has("wind_air_knobs"):
			boundary_contract_ok += 1
		var climate_state: Dictionary = state.get("climate_round_state", {})
		var native_probe_state: Dictionary = climate_state.get("native_probe_state", {})
		if str(state.get("climate_round_state_owner", "")) == "native_ready":
			climate_owner_native_ready_ok += 1
		if str(climate_state.get("owner", "")) == "native_ready":
			climate_state_mirror_ok += 1
		if str(native_probe_state.get("authority", "")) == "probe_native_state":
			native_probe_state_ok += 1
		if not bool(native_probe_state.get("simulation_authority", true)):
			native_probe_not_authority_ok += 1
		if str(native_probe_state.get("lifecycle_owner", "")) == "native_probe_lifecycle":
			native_lifecycle_probe_ok += 1
		var remaining_boundaries: Array = native_probe_state.get("remaining_gdscript_authority", [])
		if bool(native_probe_state.get("climate_round_authority_ready", false)) \
				and remaining_boundaries.has("godot_mapdata_boundary_execution"):
			native_ready_with_boundaries_ok += 1
		var remaining_sim_authority: Array = native_probe_state.get("remaining_gdscript_simulation_authority", [])
		if remaining_sim_authority.has("sync_sliced_fallback"):
			native_ready_sim_fallback_ok += 1
		var boundary_intents: Array = native_probe_state.get("boundary_intents", [])
		if boundary_intents.has("sync_runtime_terrain_views") and boundary_intents.has("soa_begin_climate_transaction"):
			native_boundary_intents_ok += 1
		if "_last_climate_breakdown" in generator:
			var finalize_tail_intents: Array = generator._last_climate_breakdown.get("finalize_tail_boundary_intents", [])
			var finalizer_source_intent_ok: bool = finalize_tail_intents.has("use_worker_finalizer_diag") \
					or finalize_tail_intents.has("apply_gdscript_finalizer_fallback")
			if finalizer_source_intent_ok and finalize_tail_intents.has("advance_full_sweep_counter"):
				native_finalize_front_intents_ok += 1
			if finalize_tail_intents.has("publish_climate_breakdown") \
					and finalize_tail_intents.has("annual_log") \
					and finalize_tail_intents.has("soak_dump") \
					and finalize_tail_intents.has("integrity_check"):
				native_finalize_mid_intents_ok += 1

		if _array_is_sane(map.temp_arr):
			temp_sane_ok += 1

	var exec_ctx := SusTickContext.make(10000, SOAK_DAYS + 1, float((SOAK_DAYS + 1) % 365) / 365.0, 1.0, &"native_daily_exec_sample")
	var exec_res: Dictionary = generator.run_native_daily_tick_from_job(exec_ctx, map, world)
	var exec_breakdown: Dictionary = exec_res.get("breakdown", {})
	var exec_published: Array = exec_res.get("published_slots", [])
	var exec_wind_slots_ok: bool = exec_published.has("cell_temp") \
			and exec_published.has("cell_air_mass_temp_anomaly") \
			and exec_published.has("cell_ocean_thermal_anomaly") \
			and exec_published.has("cell_local_thermal_anomaly")
	var exec_wind_timing_ok: bool = exec_breakdown.has("wind_air_ms") and exec_breakdown.has("wind_surface_ms")
	var exec_wind_ms: float = float(exec_breakdown.get("wind_air_ms", 0.0)) + float(exec_breakdown.get("wind_surface_ms", 0.0))

	print("[native_daily/soak] days=%d rc_ok=%d wind_key_ok=%d missing_ok=%d retained_wind_bad=%d exec_rc=%d exec_native=%.3fms exec_wind=%.3fms exec_published_slots=%s"
		% [
			SOAK_DAYS,
			rc_ok,
			wind_key_ok,
			missing_ok,
			retained_wind_bad,
			int(exec_res.get("rc", -1)),
			float(exec_res.get("native_ms", 0.0)),
			exec_wind_ms,
			str(exec_published),
		])

	_expect("all shadow probes succeeded", rc_ok == SOAK_DAYS)
	_expect("all shadow probes are ready", authoritative_ready_ok == SOAK_DAYS)
	_expect("all ticks include wind pass keys", wind_key_ok == SOAK_DAYS)
	_expect("all ticks have complete required pass keys", missing_ok == SOAK_DAYS)
	_expect("wind authority is not retained by GDScript", retained_wind_bad == 0)
	_expect("climate round owner is native-ready", climate_owner_native_ready_ok == SOAK_DAYS)
	_expect("climate round state mirror is native-ready", climate_state_mirror_ok == SOAK_DAYS)
	_expect("native climate probe state is present", native_probe_state_ok == SOAK_DAYS)
	_expect("native climate probe is not authority", native_probe_not_authority_ok == SOAK_DAYS)
	_expect("native climate lifecycle probe is present", native_lifecycle_probe_ok == SOAK_DAYS)
	_expect("native climate ready keeps boundary list", native_ready_with_boundaries_ok == SOAK_DAYS)
	_expect("native climate ready reports sync fallback authority", native_ready_sim_fallback_ok == SOAK_DAYS)
	_expect("native climate boundary intents are present", native_boundary_intents_ok == SOAK_DAYS)
	_expect("native climate finalize front intents are present", native_finalize_front_intents_ok > 0)
	_expect("native climate finalize mid intents are present", native_finalize_mid_intents_ok > 0)
	_expect("native authority report is present every day", authority_report_ok == SOAK_DAYS)
	_expect("native authority blockers are present every day", authority_blockers_ok == SOAK_DAYS)
	_expect("native graph coverage is not complete", partial_coverage_ok == SOAK_DAYS)
	_expect("ocean physical state is mirrored every day", ocean_state_ok == SOAK_DAYS)
	_expect("ocean physical reaches native-ready probe", ocean_native_ready_probe_ok > 0)
	_expect("season refresh state is mirrored every day", season_state_ok == SOAK_DAYS)
	_expect("season simulation dirty intents are reported", season_dirty_intents_ok == SOAK_DAYS)
	_expect("native boundary contract is reported every day", boundary_contract_ok == SOAK_DAYS)
	_expect("temperature array stays finite", temp_sane_ok == SOAK_DAYS)
	_expect("execution sample succeeds", int(exec_res.get("rc", -1)) == 0)
	_expect("execution sample publishes wind-related climate slots", exec_wind_slots_ok)
	_expect("execution sample reports wind timings", exec_wind_timing_ok)
	_finish()


func _make_profile() -> ClimateProfile:
	var loaded := ResourceLoader.load("res://data/world/earth_like.tres", "Resource") as ClimateProfile
	var profile: ClimateProfile = loaded.duplicate(true) if loaded != null else ClimateProfile.new()
	profile.native_generation_mode = ClimateProfile.NATIVE_MODE_ACTIVE
	profile.native_daily_sim_mode = ClimateProfile.NATIVE_MODE_SHADOW
	profile.native_shadow_diff_enabled = true
	profile.weather_field_enabled = false
	profile.runtime_hydrology_enabled = false
	profile.native_environment_runtime_enabled = false
	profile.dynamic_visual_atlas_upload_stride = 8
	profile.enum_atlas_upload_stride = 8
	return profile


func _array_is_sane(values: PackedFloat32Array) -> bool:
	if values.is_empty():
		return false
	for v in values:
		if is_nan(v) or is_inf(v) or absf(v) > 100000.0:
			return false
	return true


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
