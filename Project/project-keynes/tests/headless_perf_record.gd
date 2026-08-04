extends SceneTree

# Production-path headless performance recorder.
#
# Example:
#   godot --headless --path . --script res://tests/headless_perf_record.gd -- \
#     days=50 speed=50 seed=20260718 label=baseline
#
# This reuses WorldRuntimeHost and PerfRecorder, so the exported CSV has the
# same perf_record_YYYYMMDD_HHMMSS.csv schema as the GM performance panel.

const PerfRecorderScript = preload("res://scripts/ui/perf_recorder.gd")

const DEFAULT_DAYS := 50
const DEFAULT_SPEED := 50.0
const DEFAULT_SEED := 20260718
const DEFAULT_MAP_WIDTH := 60
const DEFAULT_MAP_HEIGHT := 40
const DEFAULT_POPULATION_SCALE := 0
const MAX_BARRIER_PULSES_PER_DAY := 4096


func _init() -> void:
	var exit_code := await _run()
	quit(exit_code)


func _run() -> int:
	var args := _arguments()
	var days := int(args.get("days", DEFAULT_DAYS))
	var speed := float(args.get("speed", DEFAULT_SPEED))
	var seed := int(args.get("seed", DEFAULT_SEED))
	var map_width := int(args.get("width", DEFAULT_MAP_WIDTH))
	var map_height := int(args.get("height", DEFAULT_MAP_HEIGHT))
	var population_scale := int(args.get("population_scale", DEFAULT_POPULATION_SCALE))
	var label := str(args.get("label", "headless"))
	var accuracy_mode := str(args.get("accuracy_mode", "")).to_upper()
	var accuracy_preset := str(args.get("accuracy_preset", "")).to_upper()
	var closing_audit_mode := str(args.get("closing_audit_mode", "")).to_upper()
	var worker_mode := str(args.get("worker_mode", "")).to_upper()
	# NS 化四方向深化 A/B:ns_gates=ON 在本进程内把 earth_like.tres 的四个方向
	# gate 全部打开(动量/轨迹表+共享/散度阻尼/洋流),运行结束后恢复原值;
	# 不落盘(.tres 从不保存)。ns_gates=WIND 只开风场三件套(Phase 1-3)。
	var ns_gates := str(args.get("ns_gates", "")).to_upper()
	var use_saved_setup := str(args.get("use_saved_setup", "false")).to_lower() in [
		"1", "true", "yes", "on",
	]

	if days <= 0:
		push_error("[headless-perf] days must be positive")
		return 2
	if speed <= 0.0:
		push_error("[headless-perf] speed must be positive")
		return 2
	if map_width < 10 or map_height < 8:
		push_error("[headless-perf] map dimensions must be at least 10x8")
		return 2
	if population_scale not in [0, 1, 10, 100, 1000]:
		push_error("[headless-perf] population_scale must be one of 0,1,10,100,1000")
		return 2
	if not ClassDB.class_exists("DCWorldExt"):
		push_error("[headless-perf] DCWorldExt unavailable; rebuild and restart Godot")
		return 3

	var clock := WorldClock.new()
	clock.auto_start = false
	clock.initial_speed = speed
	clock.debug_step_log = false
	get_root().add_child(clock)
	clock.set_speed(speed)
	clock.pause(true)

	var host := WorldRuntimeHost.new()
	host.map_width = map_width
	host.map_height = map_height
	host.initial_seed = seed
	host.generate_test_economy_data = true
	host.test_economy_population_scale = population_scale
	get_root().add_child(host)
	host.configure(null, null, clock)
	var economy_profile: Resource = load(
		"res://data/economy/default_economy.tres")
	var previous_accuracy_mode := ""
	var previous_accuracy_preset := ""
	var previous_closing_audit_mode := ""
	var previous_worker_enabled := true
	if economy_profile != null:
		previous_accuracy_mode = str(
			economy_profile.get("economy_approximation_runtime_mode"))
		previous_accuracy_preset = str(
			economy_profile.get("economy_accuracy_preset"))
		previous_closing_audit_mode = str(
			economy_profile.get("economy_closing_audit_mode"))
		previous_worker_enabled = bool(economy_profile.get("worker_enabled"))
		if accuracy_mode in ["OFF", "PROBE", "ACTIVE"]:
			economy_profile.set(
				"economy_approximation_runtime_mode", accuracy_mode)
		if accuracy_preset in ["EXACT", "BALANCED", "FAST", "CUSTOM"]:
			economy_profile.set("economy_accuracy_preset", accuracy_preset)
		if closing_audit_mode in ["FULL", "PROBE", "INCREMENTAL"]:
			economy_profile.set("economy_closing_audit_mode", closing_audit_mode)
		if worker_mode in ["ON", "OFF"]:
			economy_profile.set("worker_enabled", worker_mode == "ON")

	if use_saved_setup:
		var saved_setup := _load_saved_world_setup()
		if saved_setup.is_empty():
			push_error("[headless-perf] saved world setup requested but unavailable")
			return 2
		Engine.set_meta(WorldRuntimeHost.WORLD_SETUP_META, saved_setup)

	# NS gate A/B:进程内改共享 climate profile(MapGenerator 懒加载同一缓存实例),
	# 覆盖生成 + 运行全程,退出前恢复。
	var climate_profile_res: Resource = null
	var ns_prev_values: Dictionary = {}
	if ns_gates in ["ON", "WIND", "ALL"]:
		var gate_knobs: Dictionary = {
			"wind_traj_table_enabled": true,
			"wind_traj_weather_share": true,
			"wind_momentum_advect_w": 0.3,
			"wind_momentum_diffuse_w_daily": 0.08,
			"wind_div_damp_alpha": 0.2,
		}
		if ns_gates in ["ON", "ALL"]:
			gate_knobs["ocean_topo_steer_w"] = 0.15
			gate_knobs["ocean_depth_curl_damp"] = 0.5
		climate_profile_res = ResourceLoader.load("res://data/world/earth_like.tres", "Resource")
		if climate_profile_res == null:
			push_error("[headless-perf] ns_gates requested but earth_like.tres missing")
			return 2
		for k in gate_knobs:
			ns_prev_values[k] = climate_profile_res.get(k)
			climate_profile_res.set(k, gate_knobs[k])
		print("[headless-perf] ns_gates=%s applied: %s" % [ns_gates, str(gate_knobs)])

	var generation_started := Time.get_ticks_usec()
	await host.generate_world(-1 if use_saved_setup else seed)
	if economy_profile != null:
		economy_profile.set(
			"economy_approximation_runtime_mode", previous_accuracy_mode)
		economy_profile.set("economy_accuracy_preset", previous_accuracy_preset)
		economy_profile.set(
			"economy_closing_audit_mode", previous_closing_audit_mode)
		economy_profile.set("worker_enabled", previous_worker_enabled)
	if use_saved_setup:
		Engine.remove_meta(WorldRuntimeHost.WORLD_SETUP_META)
	if host.get_current_map() == null or host.get_generator() == null:
		push_error("[headless-perf] world generation failed")
		return 4
	var actual_map := host.get_current_map()
	var actual_width := actual_map.width
	var actual_height := actual_map.height
	var actual_seed := host.last_seed()
	var generation_ms := float(Time.get_ticks_usec() - generation_started) / 1000.0

	var recorder: RefCounted = PerfRecorderScript.new()
	recorder.call("bind_main", host)
	host.set_perf_recorder(recorder)
	recorder.call("start")

	var run_started := Time.get_ticks_usec()
	var barrier_pulses := 0
	var ledger_failures := 0
	var fatal := false
	for day in range(1, days + 1):
		clock.current_day = float(day)
		var phase := clock.season_phase_for_day(day)
		host.run_daily_tick(day, phase)
		host.finish_daily_tick(0.0, {})

		var drained := _drain_hard_barrier(clock, day)
		barrier_pulses += int(drained.get("pulses", 0))
		if not bool(drained.get("ok", false)):
			push_error("[headless-perf] hard barrier did not drain at day %d" % day)
			fatal = true
			break

		var generator := host.get_generator()
		if generator != null and generator.has_method("get_economy_report"):
			var economy: Dictionary = generator.get_economy_report()
			fatal = fatal or bool(economy.get("fatal", false))
			if int(economy.get("population_error", 0)) != 0 \
					or int(economy.get("money_error", 0)) != 0 \
					or int(economy.get("goods_error", 0)) != 0:
				ledger_failures += 1
		if fatal:
			push_error("[headless-perf] fatal economy report at day %d" % day)
			break

	var output_path := String(recorder.call("stop_and_export"))
	var run_ms := float(Time.get_ticks_usec() - run_started) / 1000.0
	var rows := _csv_data_row_count(output_path)
	var expected_rows := days if not fatal else host.get_fast_tick_count()
	var output_ok := output_path != "" and FileAccess.file_exists(output_path)
	var rows_ok := rows == expected_rows
	print("[headless-perf/result] label=%s days=%d speed=%.3f seed=%d map=%dx%d population_scale=%d saved_setup=%s generation_ms=%.1f run_ms=%.1f barrier_pulses=%d ledger_failures=%d fatal=%s rows=%d expected_rows=%d path=%s" % [
		label, days, speed, actual_seed, actual_width, actual_height, population_scale,
		str(use_saved_setup),
		generation_ms, run_ms, barrier_pulses, ledger_failures, str(fatal),
		rows, expected_rows, output_path,
	])
	host.set_perf_recorder(null)
	recorder.call("bind_main", null)
	host.free()
	clock.free()
	if climate_profile_res != null:
		for k in ns_prev_values:
			climate_profile_res.set(k, ns_prev_values[k])
	await process_frame
	if not output_ok:
		push_error("[headless-perf] performance CSV export failed")
		return 5
	if not rows_ok:
		push_error("[headless-perf] CSV row count mismatch: got %d expected %d" % [
			rows, expected_rows])
		return 6
	if fatal or ledger_failures > 0:
		return 7
	return 0


func _drain_hard_barrier(clock: WorldClock, day: int) -> Dictionary:
	var pulses := 0
	while _has_hard_barrier(clock) and pulses < MAX_BARRIER_PULSES_PER_DAY:
		clock.simulation_backpressure_pulse.emit(day)
		pulses += 1
	return {
		"ok": not _has_hard_barrier(clock),
		"pulses": pulses,
	}


func _has_hard_barrier(clock: WorldClock) -> bool:
	return clock._simulation_backpressure_sources.has(&"country_day_barrier") \
		or clock._simulation_backpressure_sources.has(&"economy_day_barrier")


func _csv_data_row_count(path: String) -> int:
	if path == "" or not FileAccess.file_exists(path):
		return -1
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return -1
	var line_count := 0
	while not file.eof_reached():
		var line := file.get_line()
		if not line.is_empty():
			line_count += 1
	return maxi(0, line_count - 1)


func _arguments() -> Dictionary:
	var out := {}
	for raw in OS.get_cmdline_user_args():
		var item := str(raw)
		var split := item.find("=")
		if split > 0:
			out[item.substr(0, split)] = item.substr(split + 1)
	return out


func _load_saved_world_setup() -> Dictionary:
	var path := "user://world_setup_settings.json"
	if not FileAccess.file_exists(path):
		return {}
	var parsed = JSON.parse_string(FileAccess.get_file_as_string(path))
	if parsed is not Dictionary:
		return {}
	var setup := parsed as Dictionary
	if str(setup.get("source", "")) != "world_setup":
		setup["source"] = "world_setup"
	return setup
