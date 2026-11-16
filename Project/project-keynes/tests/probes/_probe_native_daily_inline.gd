extends SceneTree

# native_daily_inline 的 headless 验证探针。
#
# 目的：证明"单线程内联日"能让日历连续推进，而默认 worker 路径不变。
#
#   PK_NATIVE_DAILY_INLINE=1  内联日：host 不 spawn worker 线程，主线程逐日跑
#                             12 域日屏障（DCWorldExt.run_native_daily_inline_day）
#   不设该变量                桌面默认：worker 线程 + ACTIVE（对照，行为必须不变）
#
# 每天打印：clock day / host committed_day / 内联结果（ok/reason/attempts/
# peer_pumped）/ 域掩码 / 授权位。最后给出推进了几天。
#
#   godot --headless --path Project/project-keynes \
#       -s tests/probes/_probe_native_daily_inline.gd -- --days=6 --width=28 --height=22
#
# 参数：--days / --width / --height / --seed / --summary=<json 路径>

var _cli: Dictionary = {}


func _arg(name: String) -> String:
	return String(_cli.get(name, ""))


func _setting_int(name: String, fallback: int) -> int:
	var via_cli := _arg(name)
	if via_cli != "" and via_cli.is_valid_int():
		return int(via_cli)
	return fallback


func _init() -> void:
	for raw in OS.get_cmdline_user_args():
		var text := String(raw)
		if not text.begins_with("--"):
			continue
		var body := text.substr(2)
		var split_at := body.find("=")
		if split_at <= 0:
			continue
		_cli[body.substr(0, split_at)] = body.substr(split_at + 1)
	var days := _setting_int("days", 6)
	var width := _setting_int("width", 28)
	var height := _setting_int("height", 22)
	var seed := _setting_int("seed", 20260907)
	var inline_env := OS.get_environment("PK_NATIVE_DAILY_INLINE") == "1"
	print("[inline-probe/start] days=%d %dx%d seed=%d PK_NATIVE_DAILY_INLINE=%s" % [
		days, width, height, seed, str(inline_env)])
	var rc := await _run(seed, width, height, days, inline_env)
	quit(rc)


func _run(seed: int, width: int, height: int, days: int, inline_env: bool) -> int:
	# SceneTree 脚本模式下 _init() 跑在主循环启动之前：这时 get_root() 存在但
	# 树上节点的 is_inside_tree() 还是 false，WorldRuntimeHost.generate_world()
	# 会在第一个 is_inside_tree() 检查处直接返回。先等一帧把树跑起来。
	await process_frame
	var clock := WorldClock.new()
	clock.auto_start = false
	clock.initial_speed = 1.0
	clock.debug_step_log = false
	get_root().add_child(clock)
	clock.pause(true)

	var host := WorldRuntimeHost.new()
	host.map_width = width
	host.map_height = height
	host.initial_seed = seed
	host.generate_test_economy_data = false
	host.runtime_climate_authority_enabled = true
	host.runtime_native_daily_inline = true
	get_root().add_child(host)
	print("[inline-probe/tree] inside=%s root=%s" % [
		str(host.is_inside_tree()), str(get_root() != null)])
	host.configure(null, null, clock)
	print("[inline-probe/tree2] inside=%s" % str(host.is_inside_tree()))
	host.world_generation_failed.connect(func(reason: String) -> void:
		print("[inline-probe/gen-failed-signal] %s" % reason))
	var session: Dictionary = _configure_formal_start(host, width, height, seed, 3)
	if not bool(session.get("ok", false)):
		print("[inline-probe/FAIL] formal start failed: %s" % str(session))
		return 1
	print("[inline-probe/tree3] inside=%s generator=%s" % [
		str(host.is_inside_tree()), str(host.get_generator())])
	var gen_started := Time.get_ticks_msec()
	await host.generate_world(seed)
	print("[inline-probe/gen] ms=%d" % (Time.get_ticks_msec() - gen_started))
	var gen_probe = host.get_generator()
	if gen_probe != null:
		var base_report: Variant = gen_probe.get("_native_generation_base_report")
		var base_path := "?"
		if typeof(base_report) == TYPE_DICTIONARY:
			base_path = String((base_report as Dictionary).get("path", "?"))
		print("[inline-probe/gen-state] epoch=%d base_path=%s" % [
			int(gen_probe.get("_loading_epoch")), base_path])
	var map: MapData = host.get_current_map()
	var generator: MapGenerator = host.get_generator()
	if map == null or generator == null:
		print("[inline-probe/FAIL] generate_failed")
		return 1
	var ext = generator.get_data_core_world_ext()
	if ext == null:
		print("[inline-probe/FAIL] no_world_ext")
		return 1
	var start_report: Dictionary = generator.get_runtime_thread_report()
	print("[inline-probe/start-report] mode=%s requested=%s inline=%s state=%s committed_day=%d" % [
		str(start_report.get("simulation_thread_mode", "?")),
		str(start_report.get("requested_simulation_thread_mode", "?")),
		str(start_report.get("native_daily_inline", "?")),
		str(start_report.get("simulation_host_state", "?")),
		int(start_report.get("simulation_committed_day", -101))])

	var start_day := int(clock.current_day)
	var advanced := 0
	var inline_days := 0
	# 分域耗时账本：day -> {stage -> ms}，最后打印"首日 vs 稳态"对比。
	var stage_ledger: Array = []
	var frame_ms_ledger: Array = []
	for day in range(1, days + 1):
		clock.current_day = float(day)
		# 生产路径就是 WorldClock.day_changed → WorldRuntimeHost._on_clock_day_changed；
		# headless 下时钟不 _process，所以直接调用同一个入口。
		var frame_started := Time.get_ticks_usec()
		host._on_clock_day_changed(day)
		host.finish_daily_tick(0.0, {})
		var frame_ms := float(Time.get_ticks_usec() - frame_started) / 1000.0
		var report: Dictionary = generator.get_runtime_thread_report()
		var committed := int(report.get("simulation_committed_day", -1))
		var last: Dictionary = host.get("_runtime_native_daily_inline_last")
		var line := "[inline-probe/day] clock_day=%d committed_day=%d mode=%s inline=%s auth_mask=0x%x coverage=%s ready=%s" % [
			day, committed, str(report.get("simulation_thread_mode", "?")),
			str(report.get("native_daily_inline", "?")),
			int(report.get("authoritative_domain_mask", 0)),
			str(report.get("graph_coverage_state", "?")),
			str(report.get("authority_ready", "?"))]
		if not last.is_empty():
			line += " inline_ok=%s reason=%s attempts=%d peer=%d mask=0x%x elapsed=%.1fms" % [
				str(last.get("ok", false)), str(last.get("reason", "")),
				int(last.get("attempts", 0)), int(last.get("peer_pumped", 0)),
				int(last.get("completed_domain_mask", 0)),
				float(last.get("elapsed_ms", 0.0))]
			if bool(last.get("ok", false)):
				inline_days += 1
		print(line)
		if not last.is_empty():
			print("[inline-probe/timing] day=%d frame=%.1fms capture=%.1fms native=%.1fms plan=%.1fms pre=%.1fms climate=%.1fms tail=%.1fms peer=%.1fms attempts=%s serial_only=%s budget_hit=%s" % [
				day, frame_ms, float(last.get("capture_ms", 0.0)),
				float(last.get("elapsed_ms", 0.0)),
				float(last.get("plan_build_ms", 0.0)),
				float(last.get("pre_stage_ms", 0.0)),
				float(last.get("climate_ms", 0.0)),
				float(last.get("commit_tail_ms", 0.0)),
				float(last.get("peer_ms", 0.0)),
				str(last.get("attempt_ms", [])),
				str(last.get("executor_serial_only", "?")),
				str(last.get("budget_exceeded", "?"))])
			print("[inline-probe/stages] day=%d %s" % [
				day, _format_stages(last.get("stage_ms", {}))])
			print("[inline-probe/executor] day=%d serial_only=%s workers=%d dispatch=%d serial_dispatch=%d tasks=%d" % [
				day, str(last.get("executor_serial_only", "?")),
				int(last.get("executor_workers", -1)),
				int(last.get("executor_dispatch", -1)),
				int(last.get("executor_serial_dispatch", -1)),
				int(last.get("executor_tasks", -1))])
			stage_ledger.append(last.get("stage_ms", {}).duplicate())
			frame_ms_ledger.append(frame_ms)
		else:
			stage_ledger.append({})
			frame_ms_ledger.append(frame_ms)
		if committed >= day:
			advanced += 1

	_print_stage_compare(stage_ledger, frame_ms_ledger)

	var end_report: Dictionary = generator.get_runtime_thread_report()
	var committed_end := int(end_report.get("simulation_committed_day", -1))
	var days_advanced := committed_end - start_day
	print("[inline-probe/end] clock_day=%d committed_day=%d days_advanced=%d inline_days=%d ticks_advanced=%d pending=%d fault=%s" % [
		int(clock.current_day), committed_end, days_advanced, inline_days, advanced,
		int(host.get("_runtime_native_daily_inline_pending_days")),
		str(end_report.get("fault_code", ""))])
	var summary_path := _arg("summary")
	if summary_path != "":
		var file := FileAccess.open(summary_path, FileAccess.WRITE)
		if file != null:
			file.store_string(JSON.stringify({
				"inline_env": inline_env,
				"start_day": start_day,
				"committed_day": committed_end,
				"days_advanced": days_advanced,
				"inline_days": inline_days,
				"requested_mode": str(end_report.get("requested_simulation_thread_mode", "")),
				"effective_mode": str(end_report.get("simulation_thread_mode", "")),
				"native_daily_inline": bool(end_report.get("native_daily_inline", false)),
				"authoritative_domain_mask": int(end_report.get("authoritative_domain_mask", 0)),
				"fault_code": str(end_report.get("fault_code", "")),
			}, "  "))
			file.close()
	clock.pause(true)
	host.free()
	clock.free()
	await process_frame
	return 0 if days_advanced >= days else 2


## 12 域耗时压成一行：name=ms 按毫秒降序，>0.05ms 才打印，避免噪声。
func _format_stages(stage_ms: Variant) -> String:
	if typeof(stage_ms) != TYPE_DICTIONARY:
		return "stage_ms=<missing>"
	var pairs: Array = []
	for key in (stage_ms as Dictionary).keys():
		var ms := float((stage_ms as Dictionary)[key])
		if ms <= 0.05:
			continue
		pairs.append([String(key), ms])
	pairs.sort_custom(func(a, b): return float(a[1]) > float(b[1]))
	var parts: Array = []
	for pair in pairs:
		parts.append("%s=%.1f" % [pair[0], pair[1]])
	return " ".join(parts) if not parts.is_empty() else "all=0"


## 首日 vs 稳态（第 2 天起均值）分域对比。这就是"一次性成本落在哪一域"的证据。
func _print_stage_compare(stage_ledger: Array, frame_ms_ledger: Array) -> void:
	if stage_ledger.is_empty():
		return
	var first: Dictionary = stage_ledger[0]
	var steady: Dictionary = {}
	var steady_frames := 0
	for index in range(1, stage_ledger.size()):
		var entry: Dictionary = stage_ledger[index]
		for key in entry.keys():
			steady[key] = float(steady.get(key, 0.0)) + float(entry[key])
		steady_frames += 1
	var keys: Array = []
	for key in first.keys():
		keys.append(String(key))
	for key in steady.keys():
		if not keys.has(String(key)):
			keys.append(String(key))
	var rows: Array = []
	for key in keys:
		var first_ms := float(first.get(key, 0.0))
		var steady_ms := float(steady.get(key, 0.0)) / maxf(1.0, float(steady_frames))
		rows.append([key, first_ms, steady_ms, first_ms - steady_ms])
	rows.sort_custom(func(a, b): return float(a[1]) > float(b[1]))
	var total_first := 0.0
	var total_steady := 0.0
	for row in rows:
		total_first += float(row[1])
		total_steady += float(row[2])
		if float(row[1]) < 0.05 and float(row[2]) < 0.05:
			continue
		print("[inline-probe/compare] %-16s first=%9.2fms steady=%8.2fms oneoff=%9.2fms" % [
			row[0], row[1], row[2], row[3]])
	print("[inline-probe/compare] %-16s first=%9.2fms steady=%8.2fms oneoff=%9.2fms" % [
		"TOTAL(12 domains)", total_first, total_steady, total_first - total_steady])
	if not frame_ms_ledger.is_empty():
		print("[inline-probe/compare] frame_total first=%.2fms" % float(frame_ms_ledger[0]))


func _configure_formal_start(host: WorldRuntimeHost, width: int, height: int,
		seed: int, foreign_count: int) -> Dictionary:
	var config := NewGameConfig.create_default()
	config.country.name = "Inline Probe"
	config.country.foreign_count = foreign_count
	config.base.map_width = width
	config.base.map_height = height
	config.base.initial_seed = seed
	var validation := config.validate()
	if not bool(validation.get("ok", false)):
		return validation
	return host.configure_session({
		"kind": "new_game",
		"config": config.to_dictionary(),
	})
