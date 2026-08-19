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
const DEFAULT_FOREIGN_COUNT := 3
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
	var foreign_count := int(args.get("foreign_count", DEFAULT_FOREIGN_COUNT))
	var import_tariff_rate := int(args.get("import_tariff_rate", 0))
	var export_tariff_rate := int(args.get("export_tariff_rate", 0))
	var synthetic_test_economy := _argument_enabled(
		args.get("synthetic_test_economy", "false"))
	var trade_scenario := _argument_enabled(args.get("trade_scenario", "false"))
	var label := str(args.get("label", "headless"))
	var accuracy_mode := str(args.get("accuracy_mode", "")).to_upper()
	var accuracy_preset := str(args.get("accuracy_preset", "")).to_upper()
	var closing_audit_mode := str(args.get("closing_audit_mode", "")).to_upper()
	var worker_mode := str(args.get("worker_mode", "")).to_upper()
	var country_report_mode := str(args.get("country_report_mode", "LIGHT")).to_upper()
	var country_full_diagnostics := country_report_mode in ["FULL", "PROBE"]
	var country_light_report_enabled := not country_full_diagnostics
	var country_pending_queue_enabled := true
	if args.has("country_pending_queue"):
		country_pending_queue_enabled = _argument_enabled(
			args.get("country_pending_queue", "true"))
	var bio_occupancy_slice_enabled := _argument_enabled(
		args.get("bio_occupancy_slice_enabled", "false"))
	Engine.set_meta(&"country_full_diagnostics", country_full_diagnostics)
	Engine.set_meta(&"country_light_report_enabled", country_light_report_enabled)
	Engine.set_meta(&"country_pending_queue_enabled", country_pending_queue_enabled)
	Engine.set_meta(&"bio_occupancy_slice_enabled", bio_occupancy_slice_enabled)
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
	if foreign_count < NewGameConfig.MIN_FOREIGN_COUNT \
			or foreign_count > NewGameConfig.MAX_FOREIGN_COUNT:
		push_error("[headless-perf] foreign_count must be within %d..%d" % [
			NewGameConfig.MIN_FOREIGN_COUNT, NewGameConfig.MAX_FOREIGN_COUNT])
		return 2
	if import_tariff_rate < -100 or import_tariff_rate > 100 \
			or export_tariff_rate < -100 or export_tariff_rate > 100:
		push_error("[headless-perf] tariff rates must be within -100..100")
		return 2
	if trade_scenario and (synthetic_test_economy or foreign_count < 1):
		push_error("[headless-perf] trade_scenario requires a formal start with a foreign country")
		return 2
	if not ClassDB.class_exists("DCWorldExt"):
		push_error("[headless-perf] DCWorldExt unavailable; rebuild and restart Godot")
		return 3

	var saved_setup: Dictionary = {}
	if use_saved_setup:
		saved_setup = _load_saved_world_setup()
		if saved_setup.is_empty():
			push_error("[headless-perf] saved world setup requested but unavailable")
			return 2

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
	host.generate_test_economy_data = synthetic_test_economy
	host.test_economy_population_scale = population_scale
	get_root().add_child(host)
	host.configure(null, null, clock)
	if not synthetic_test_economy:
		var session_result := _configure_formal_start(
			host, map_width, map_height, seed, foreign_count, saved_setup)
		if not bool(session_result.get("ok", false)):
			push_error("[headless-perf] formal start configuration failed: %s" %
				str(session_result))
			return 3
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

	if use_saved_setup and synthetic_test_economy:
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
	if use_saved_setup and synthetic_test_economy:
		Engine.remove_meta(WorldRuntimeHost.WORLD_SETUP_META)
	if host.get_current_map() == null or host.get_generator() == null:
		push_error("[headless-perf] world generation failed")
		return 4
	var actual_map := host.get_current_map()
	var generator := host.get_generator()
	var economy = generator.get_economy_facade()
	var country = generator.get_country_facade()
	var start_report: Dictionary = generator.gameplay_start_report() \
		if generator.has_method("gameplay_start_report") else {}
	var economy_report: Dictionary = generator.get_economy_report()
	var country_report: Dictionary = country.report() if country != null else {}
	var economy_configured: bool = economy != null and economy.is_configured() \
		and bool(economy_report.get("configured", false))
	var country_count := int(country_report.get("country_count", 0))
	var opening_population := _opening_population(actual_map, economy, start_report)
	var country_handles := PackedInt64Array()
	var country_cells := PackedInt32Array()
	if not economy_configured or opening_population <= 0:
		push_error("[headless-perf] economy did not start: configured=%s population=%d report=%s" % [
			str(economy_configured), opening_population, str(start_report)])
		return 4
	if not synthetic_test_economy:
		if not bool(start_report.get("ok", false)) \
				or country_count < foreign_count + 1:
			push_error("[headless-perf] formal multi-country start failed: %s" %
				str(start_report))
			return 4
		country_handles = _country_handles(actual_map, country)
		if country_handles.size() != country_count:
			push_error("[headless-perf] country handle discovery mismatch: got %d expected %d" % [
				country_handles.size(), country_count])
			return 4
		var tariff_result := _submit_tariff_defaults(
			country, country_handles, import_tariff_rate, export_tariff_rate)
		if not bool(tariff_result.get("ok", false)):
			push_error("[headless-perf] tariff setup failed: %s" % str(tariff_result))
			return 4
		country_cells = _country_cells_for_handles(actual_map, country, country_handles)
		if trade_scenario:
			var scenario_result := _submit_trade_scenario(
				actual_map, economy, country_handles, country_cells)
			if not bool(scenario_result.get("ok", false)):
				push_error("[headless-perf] trade scenario setup failed: %s" %
					str(scenario_result))
				return 4
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

		if generator != null and generator.has_method("get_economy_report"):
			economy_report = generator.get_economy_report()
			fatal = fatal or bool(economy_report.get("fatal", false))
			if int(economy_report.get("population_error", 0)) != 0 \
					or int(economy_report.get("money_error", 0)) != 0 \
					or int(economy_report.get("goods_error", 0)) != 0:
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
	var tariff_totals := _tariff_totals(country, country_handles)
	var trade_totals := _trade_totals(economy, country_handles)
	print("[headless-perf/result] label=%s days=%d speed=%.3f seed=%d map=%dx%d formal_start=%s trade_scenario=%s foreign_count=%d import_tariff_rate=%d export_tariff_rate=%d population_scale=%d saved_setup=%s economy_configured=%s country_count=%d population=%d generation_ms=%.1f run_ms=%.1f barrier_pulses=%d ledger_failures=%d fatal=%s trade_orders_dispatched=%d trade_orders_arrived=%d trade_orders_cumulative=%d trade_base_cumulative=%d trade_route_expansions=%d trade_tariff_lanes=%d trade_country_goods=%d trade_country_partners=%d tariff_collected=%d tariff_subsidy_paid=%d economy_memory_bytes=%d rows=%d expected_rows=%d path=%s" % [
		label, days, speed, actual_seed, actual_width, actual_height,
		str(not synthetic_test_economy), str(trade_scenario), foreign_count, import_tariff_rate,
		export_tariff_rate, population_scale, str(use_saved_setup),
		str(economy_configured), country_count, opening_population,
		generation_ms, run_ms, barrier_pulses, ledger_failures, str(fatal),
		int(economy_report.get("trade_orders_dispatched", 0)),
		int(economy_report.get("trade_orders_arrived", 0)),
		int(trade_totals.get("orders", 0)),
		int(trade_totals.get("base", 0)),
		int(economy_report.get("trade_route_expansions", 0)),
		int(economy_report.get("trade_tariff_lane_count", 0)),
		int(economy_report.get("trade_country_good_aggregate_count", 0)),
		int(economy_report.get("trade_country_partner_aggregate_count", 0)),
		int(tariff_totals.get("collected", 0)),
		int(tariff_totals.get("subsidy_paid", 0)),
		int(economy_report.get("memory_bytes", 0)), rows, expected_rows, output_path,
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


func _argument_enabled(value) -> bool:
	return str(value).to_lower() in ["1", "true", "yes", "on"]


func _configure_formal_start(host: WorldRuntimeHost, map_width: int,
		map_height: int, seed: int, foreign_count: int,
		saved_setup: Dictionary) -> Dictionary:
	var config := NewGameConfig.create_default()
	config.country.name = "Headless Benchmark"
	config.country.foreign_count = foreign_count
	config.base.map_width = map_width
	config.base.map_height = map_height
	config.base.initial_seed = seed
	if not saved_setup.is_empty():
		var saved_base = saved_setup.get("base", {})
		if saved_base is Dictionary:
			for key in config.base.keys():
				if (saved_base as Dictionary).has(key):
					config.base[key] = (saved_base as Dictionary)[key]
		var saved_world_controls = saved_setup.get("world_controls", {})
		if saved_world_controls is Dictionary:
			config.world_controls = (saved_world_controls as Dictionary).duplicate(true)
		var saved_climate = saved_setup.get("climate", {})
		if saved_climate is Dictionary:
			config.climate = (saved_climate as Dictionary).duplicate(true)
	var validation := config.validate()
	if not bool(validation.get("ok", false)):
		return validation
	return host.configure_session({
		"kind": "new_game",
		"config": config.to_dictionary(),
	})


func _opening_population(map: MapData, economy, start_report: Dictionary) -> int:
	var formal_population := int(start_report.get("total_population", 0))
	if formal_population > 0:
		return formal_population
	if economy == null:
		return 0
	var total := 0
	for cell in map.cell_count():
		total += int(economy.population_cell_snapshot(cell).get("population", 0))
	return total


func _country_handles(map: MapData, country) -> PackedInt64Array:
	var handles := PackedInt64Array()
	var seen := {}
	for cell in map.cell_count():
		var handle := int(country.cell_summary(cell).get("country_handle", 0))
		if handle == 0 or seen.has(handle):
			continue
		seen[handle] = true
		handles.append(handle)
	handles.sort()
	return handles


func _country_cells_for_handles(map: MapData, country,
		handles: PackedInt64Array) -> PackedInt32Array:
	var cells := PackedInt32Array()
	cells.resize(handles.size())
	cells.fill(-1)
	var handle_to_index := {}
	for index in handles.size():
		handle_to_index[int(handles[index])] = index
	for cell in map.cell_count():
		var handle := int(country.cell_summary(cell).get("country_handle", 0))
		if not handle_to_index.has(handle):
			continue
		var index := int(handle_to_index[handle])
		if cells[index] < 0:
			cells[index] = cell
	return cells


func _submit_trade_scenario(map: MapData, economy, handles: PackedInt64Array,
		cells: PackedInt32Array) -> Dictionary:
	var pair := _connected_trade_pair(map, cells)
	if pair.size() != 2:
		return {"ok": false, "reason": "no_connected_foreign_endpoints"}
	var source_cell := int(pair[0])
	var destination_cell := int(pair[1])
	var good_index: int = economy.good_ids().find("game_meat")
	if good_index < 0:
		return {"ok": false, "reason": "game_meat_good_missing"}
	var destination_population: Dictionary = economy.population_cell_snapshot(
		destination_cell)
	var cohort_handles: PackedInt64Array = destination_population.get(
		"handles", PackedInt64Array())
	var merchant_flags: PackedByteArray = destination_population.get(
		"merchant_flags", PackedByteArray())
	var merchant_handle := 0
	var consumer_handle := 0
	for index in cohort_handles.size():
		var handle := int(cohort_handles[index])
		if index < merchant_flags.size() and merchant_flags[index] != 0:
			merchant_handle = handle
		elif consumer_handle == 0:
			consumer_handle = handle
	if merchant_handle == 0 or consumer_handle == 0:
		return {"ok": false, "reason": "trade_scenario_cohorts_missing"}
	var commands: Array[Dictionary] = [
		{
			"opcode": EconomyFacade.Opcode.ADD_STOCK,
			"effective_day": 1,
			"sequence": 20001,
			"i32_0": source_cell,
			"i32_1": good_index,
			"i64_0": 2_000_000,
		},
		{
			"opcode": EconomyFacade.Opcode.ADD_POPULATION,
			"effective_day": 1,
			"sequence": 20002,
			"target_handle": consumer_handle,
			"i64_0": 180,
		},
		{
			"opcode": EconomyFacade.Opcode.MINT_TO_COHORT,
			"effective_day": 1,
			"sequence": 20003,
			"target_handle": consumer_handle,
			"i64_0": 500_000_000,
		},
		{
			"opcode": EconomyFacade.Opcode.MINT_TO_COHORT,
			"effective_day": 1,
			"sequence": 20004,
			"target_handle": merchant_handle,
			"i64_0": 500_000_000,
		},
	]
	return economy.submit(commands)


func _connected_trade_pair(map: MapData, cells: PackedInt32Array) -> PackedInt32Array:
	var passable_lut := map.economy_trade_passable_lut()
	for source_index in range(maxi(0, cells.size() - 1)):
		var source := int(cells[source_index])
		if source < 0:
			continue
		var reached := PackedByteArray()
		reached.resize(map.cell_count())
		var queue := PackedInt32Array([source])
		var cursor := 0
		reached[source] = 1
		while cursor < queue.size():
			var cell := int(queue[cursor])
			cursor += 1
			for direction in 6:
				var neighbor := map.neighbor_index(cell, direction)
				if neighbor < 0 or reached[neighbor] != 0:
					continue
				var terrain := int(map.terrain_arr[neighbor])
				if terrain < 0 or terrain >= passable_lut.size() \
						or passable_lut[terrain] == 0:
					continue
				reached[neighbor] = 1
				queue.append(neighbor)
		for destination_index in range(source_index + 1, cells.size()):
			var destination := int(cells[destination_index])
			if destination >= 0 and reached[destination] != 0:
				return PackedInt32Array([source, destination])
	return PackedInt32Array()


func _tariff_totals(country, handles: PackedInt64Array) -> Dictionary:
	var collected := 0
	var subsidy_paid := 0
	if country == null:
		return {"collected": collected, "subsidy_paid": subsidy_paid}
	for handle in handles:
		var fiscal: Dictionary = country.fiscal_snapshot(int(handle))
		var cumulative_collected: PackedInt64Array = fiscal.get(
			"cumulative_collected", PackedInt64Array())
		var cumulative_paid: PackedInt64Array = fiscal.get(
			"cumulative_subsidy_paid", PackedInt64Array())
		for kind in [CountryFacade.TaxKind.IMPORT, CountryFacade.TaxKind.EXPORT]:
			if kind < cumulative_collected.size():
				collected += int(cumulative_collected[kind])
			if kind < cumulative_paid.size():
				subsidy_paid += int(cumulative_paid[kind])
	return {"collected": collected, "subsidy_paid": subsidy_paid}


func _trade_totals(economy, handles: PackedInt64Array) -> Dictionary:
	var directed_orders := 0
	var directed_base := 0
	if economy == null:
		return {"orders": 0, "base": 0}
	for handle in handles:
		var partners: Dictionary = economy.country_trade_snapshot(
			int(handle), "partners", 0, 64)
		var orders: PackedInt64Array = partners.get(
			"cumulative_order_count", PackedInt64Array())
		var imports: PackedInt64Array = partners.get(
			"cumulative_import_base", PackedInt64Array())
		var exports: PackedInt64Array = partners.get(
			"cumulative_export_base", PackedInt64Array())
		for value in orders:
			directed_orders += int(value)
		for value in imports:
			directed_base += int(value)
		for value in exports:
			directed_base += int(value)
	return {"orders": directed_orders / 2, "base": directed_base / 2}


func _submit_tariff_defaults(country, handles: PackedInt64Array,
		import_rate: int, export_rate: int) -> Dictionary:
	var commands: Array[Dictionary] = []
	var sequence := 1
	for handle in handles:
		if import_rate != 0:
			commands.append({
				"opcode": CountryFacade.Opcode.SET_TAX_DEFAULT,
				"target_handle": int(handle),
				"tax_kind": CountryFacade.TaxKind.IMPORT,
				"tax_rate_percent": import_rate,
				"effective_day": 1,
				"sequence": sequence,
			})
			sequence += 1
		if export_rate != 0:
			commands.append({
				"opcode": CountryFacade.Opcode.SET_TAX_DEFAULT,
				"target_handle": int(handle),
				"tax_kind": CountryFacade.TaxKind.EXPORT,
				"tax_rate_percent": export_rate,
				"effective_day": 1,
				"sequence": sequence,
			})
			sequence += 1
	return {"ok": true} if commands.is_empty() else country.submit(commands)


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
