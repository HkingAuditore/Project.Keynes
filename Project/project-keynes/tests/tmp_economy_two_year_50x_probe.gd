extends SceneTree

# Headless two-year economy/resource probe. It uses the production MapGenerator,
# SUS daily graph, native economy recorder, and a real 50x WorldClock context.

const TARGET_CELL := 1227
const DEFAULT_SEED := 20260718
const DEFAULT_DAYS := 730


func _init() -> void:
	var exit_code := _run()
	quit(exit_code)


func _run() -> int:
	if not ClassDB.class_exists("DCWorldExt"):
		push_error("[economy-50x-2y] DCWorldExt unavailable")
		return 2
	var args := _arguments()
	var seed := int(args.get("seed", DEFAULT_SEED))
	var days := int(args.get("days", DEFAULT_DAYS))
	var profile := _make_profile()
	var setup := _load_world_setup()
	_apply_climate_settings(profile, setup.get("climate", {}))
	var base: Dictionary = setup.get("base", {})
	var width := int(base.get("map_width", 60))
	var height := int(base.get("map_height", 40))
	var cfg := MapConfig.make(width, height)
	cfg.seed = seed
	cfg.num_continents = int(base.get("num_continents", 2))
	cfg.sea_level = float(base.get("sea_level", 0.60))
	cfg.continent_size = float(base.get("continent_size", 0.90))
	cfg.climate_profile = profile

	var clock := WorldClock.new()
	clock.days_per_year_count = 365
	clock.debug_step_log = false
	clock.set_speed(50.0)
	var generator := MapGenerator.new()
	generator.climate_profile = profile
	generator.set_world_clock_ref(clock)
	generator.set_test_economy_bootstrap_enabled(true)
	var generation_started := Time.get_ticks_usec()
	var generated: Dictionary = await generator.generate(cfg, 10.0)
	var map: MapData = generated.get("map", null)
	if map == null:
		push_error("[economy-50x-2y] map generation failed")
		return 3
	var facade = generator.get_economy_facade()
	if facade == null or not facade.is_configured():
		push_error("[economy-50x-2y] economy facade unavailable")
		return 4
	if TARGET_CELL >= map.cell_count():
		push_error("[economy-50x-2y] target cell is outside generated map")
		return 5
	var target_population := int(facade.population_cell_snapshot(TARGET_CELL).get("population", 0))
	var target_cell = map.cell_at(TARGET_CELL)
	if str(args.get("catalog", "false")) == "true":
		var finance: Dictionary = facade.bootstrap_finance_columns()
		print("[economy-50x-2y/catalog] ", JSON.stringify({
			"buildings": facade.building_type_ids(),
			"professions": facade.profession_ids(),
			"needs": finance.get("need_ids", PackedStringArray()),
		}))
	print("[economy-50x-2y/setup] seed=%d map=%dx%d cell=%d q=%d r=%d s=%d population=%d generation_ms=%.1f" % [
		seed, width, height, TARGET_CELL, target_cell.q, target_cell.r, target_cell.s,
		target_population, float(Time.get_ticks_usec() - generation_started) / 1000.0,
	])
	if target_population <= 0:
		print("[economy-50x-2y/target-empty] seed=%d" % seed)
		return 6
	if days <= 0:
		return 0
	var resource_start := _resource_snapshot(map, TARGET_CELL)

	var world: Object = generator.get_data_core_world_ext()
	var paths := _recording_paths(seed, TARGET_CELL,
		str(args.get("label", "local_resource_mining_fix")))
	var start: Dictionary = world.start_economy_csv_recording(_recording_options(
		world, map, TARGET_CELL, paths))
	if not bool(start.get("ok", false)):
		push_error("[economy-50x-2y] recorder start failed: %s" % str(start))
		return 7

	var run_started := Time.get_ticks_usec()
	var barrier_pulses := 0
	var ledger_failures := 0
	var fatal := false
	for day in range(1, days + 1):
		clock.current_day = float(day)
		var phase := clock.season_phase_for_day(day)
		generator.sus_tick_daily(clock, day, phase)
		var guard := 0
		while (clock._simulation_backpressure_sources.has(&"country_day_barrier") or \
				clock._simulation_backpressure_sources.has(&"economy_day_barrier")) and guard < 512:
			generator._continue_economy_inflight(day)
			guard += 1
			barrier_pulses += 1
		if guard >= 512:
			push_error("[economy-50x-2y] same-day barrier did not drain at day %d" % day)
			fatal = true
			break
		var report: Dictionary = generator.get_economy_report()
		fatal = fatal or bool(report.get("fatal", false))
		if int(report.get("population_error", 0)) != 0 or \
				int(report.get("money_error", 0)) != 0 or int(report.get("goods_error", 0)) != 0:
			ledger_failures += 1
		if fatal:
			push_error("[economy-50x-2y] fatal economy report at day %d: %s" % [day, str(report)])
			break
		_wait_for_writer(world, 2000)
		if day % 365 == 0:
			var status: Dictionary = world.get_economy_csv_recording_status()
			print("[economy-50x-2y/progress] day=%d captured=%d written=%d population=%d" % [
				day, int(status.get("captured_epochs", 0)), int(status.get("written_epochs", 0)),
				int(facade.population_cell_snapshot(TARGET_CELL).get("population", 0)),
			])

	world.request_stop_economy_csv_recording()
	var final_status := _wait_for_terminal(world, 10000)
	var run_ms := float(Time.get_ticks_usec() - run_started) / 1000.0
	print("[economy-50x-2y/resources] ", JSON.stringify({
		"day_0": resource_start,
		"day_end": _resource_snapshot(map, TARGET_CELL),
	}))
	print("[economy-50x-2y/result] seed=%d days=%d speed=50 cell=%d run_ms=%.1f barrier_pulses=%d ledger_failures=%d fatal=%s state=%s captured=%d written=%d paths=%s" % [
		seed, days, TARGET_CELL, run_ms, barrier_pulses, ledger_failures, str(fatal),
		str(final_status.get("state", "")), int(final_status.get("captured_epochs", 0)),
		int(final_status.get("written_epochs", 0)), JSON.stringify(paths),
	])
	return 0 if not fatal and str(final_status.get("state", "")) == "completed" else 8


func _arguments() -> Dictionary:
	var out := {}
	for raw in OS.get_cmdline_user_args():
		var item := str(raw)
		var split := item.find("=")
		if split > 0:
			out[item.substr(0, split)] = item.substr(split + 1)
	return out


func _make_profile() -> ClimateProfile:
	var loaded := load("res://data/world/earth_like.tres") as ClimateProfile
	var profile: ClimateProfile = loaded.duplicate(true) if loaded != null else ClimateProfile.new()
	profile.native_generation_mode = ClimateProfile.NATIVE_MODE_ACTIVE
	profile.native_daily_sim_mode = ClimateProfile.NATIVE_MODE_ACTIVE
	profile.native_shadow_diff_enabled = false
	profile.native_climate_round_active_owner_enabled = true
	profile.native_weather_transaction_active_owner_enabled = true
	profile.native_ocean_physical_active_owner_enabled = true
	profile.native_daily_spread_across_ticks = false
	return profile


func _load_world_setup() -> Dictionary:
	var path := "user://world_setup_settings.json"
	if not FileAccess.file_exists(path):
		return {}
	var parsed = JSON.parse_string(FileAccess.get_file_as_string(path))
	return parsed if parsed is Dictionary else {}


func _apply_climate_settings(profile: ClimateProfile, values: Dictionary) -> void:
	for key in values:
		if profile.get(str(key)) != null:
			profile.set(str(key), values[key])


func _recording_paths(seed: int, cell: int, label: String) -> Dictionary:
	var directory := ProjectSettings.globalize_path("res://../../tmp")
	DirAccess.make_dir_recursive_absolute(directory)
	var safe_label := label.validate_filename().replace(" ", "_")
	var prefix := "economy_50x_2y_seed%d_cell%d_%s" % [seed, cell, safe_label]
	var paths := {}
	for dim in ["summary", "cohorts", "buildings", "resources", "market"]:
		paths[dim] = directory.path_join("%s_%s.csv" % [prefix, dim])
		if FileAccess.file_exists(paths[dim]):
			DirAccess.remove_absolute(paths[dim])
	return paths


func _resource_snapshot(map: MapData, cell: int) -> Dictionary:
	var out := {}
	ResourceProfileRegistry.ensure_loaded()
	for resource in ResourceProfileRegistry.ordered():
		var field := ResourceProfileRegistry.reserve_map_field(resource)
		if field == "":
			continue
		var values: PackedFloat32Array = map.get(field)
		if cell >= 0 and cell < values.size():
			out[str(resource.id)] = float(values[cell])
	return out


func _recording_options(world: Object, map: MapData, cell: int, paths: Dictionary) -> Dictionary:
	var count := map.cell_count()
	var q := PackedInt32Array()
	var r := PackedInt32Array()
	var s := PackedInt32Array()
	q.resize(count)
	r.resize(count)
	s.resize(count)
	for idx in range(count):
		var hex = map.cell_at(idx)
		q[idx] = hex.q
		r[idx] = hex.r
		s[idx] = hex.s
	var resource_slots := PackedInt32Array()
	var resource_ids := PackedStringArray()
	ResourceProfileRegistry.ensure_loaded()
	for resource in ResourceProfileRegistry.ordered():
		var sid := int(world.component_id("cell_res_%s_reserve" % str(resource.id)))
		if sid >= 0:
			resource_slots.append(sid)
			resource_ids.append(str(resource.id))
	return {
		"record_summary": true,
		"record_cohorts": true,
		"record_buildings": true,
		"record_resources": true,
		"record_market": true,
		"cell_stride": 1,
		"cell_indices": PackedInt32Array([cell]),
		"max_rows": 1000000,
		"q_arr": q,
		"r_arr": r,
		"s_arr": s,
		"resource_slot_ids": resource_slots,
		"resource_ids": resource_ids,
		"paths": paths,
	}


func _wait_for_writer(world: Object, timeout_ms: int) -> void:
	var deadline := Time.get_ticks_msec() + timeout_ms
	while Time.get_ticks_msec() < deadline:
		var status: Dictionary = world.get_economy_csv_recording_status()
		if str(status.get("state", "")) == "error" or \
				int(status.get("written_epochs", 0)) >= int(status.get("captured_epochs", 0)):
			return
		OS.delay_msec(1)


func _wait_for_terminal(world: Object, timeout_ms: int) -> Dictionary:
	var deadline := Time.get_ticks_msec() + timeout_ms
	var status: Dictionary = world.get_economy_csv_recording_status()
	while str(status.get("state", "")) == "draining" and Time.get_ticks_msec() < deadline:
		OS.delay_msec(1)
		status = world.get_economy_csv_recording_status()
	return status
