extends Node

## 玩家存档 → 无头续跑 N 天。
##
## 这是"把玩家遇到的停机交给 AI 复现"的唯一入口。在它之前，无头能力是断的：
## headless_perf_record.gd 只能从新开局跑，game_save_roundtrip_test.gd 只能用
## 固定槽位续跑 6 天，都无法回放崩溃现场。
##
## 走的是生产恢复路径（GameFlow.begin_load_game → player_game.tscn →
## GameSaveCoordinator），不是另写一套 restore，所以复现出来的行为和玩家一致。
##
## 用法（由 GameFlowService 按 PK_SAVE_REPLAY=1 注入）：
##   $env:PK_SAVE_REPLAY = "1"
##   $env:PK_SAVE_REPLAY_SLOT = "autosave"     # manual_1|manual_2|manual_3|autosave
##   $env:PK_SAVE_REPLAY_DAYS = "60"
##   $env:PK_SAVE_REPLAY_SPEED = "20"
##   godot --headless --path Project/project-keynes
##
## 回放任意 .pksv 文件用 tools/runtime/Invoke-SaveReplay.ps1：它把文件拷进临时
## 目录并设置 PK_SAVE_DIR，避免覆盖玩家自己的槽位。
##
## 退出码：0 = 跑满 N 天且非 fatal；1 = fatal / 卡死 / 加载失败。

const RuntimeForensics = preload("res://scripts/game/runtime_forensics.gd")

const DEFAULT_SLOT := "autosave"
const DEFAULT_DAYS := 30
const DEFAULT_SPEED := 20.0
## 单日墙钟上限。超过就判定卡死并落盘取证 —— 对无头复现来说，"永远跑不完"和
## "崩了"同样是失败，必须给出产物而不是让进程挂着。
const DEFAULT_DAY_TIMEOUT_MSEC := 60000
const RUNTIME_READY_FRAMES := 4800

var _game_flow: Node
var _failures := PackedStringArray()
var _result := {}
var _finished := false


func _ready() -> void:
	call_deferred("_run")


func _run() -> void:
	var slot := _env("PK_SAVE_REPLAY_SLOT", DEFAULT_SLOT)
	var days := int(_env("PK_SAVE_REPLAY_DAYS", str(DEFAULT_DAYS)))
	var speed := float(_env("PK_SAVE_REPLAY_SPEED", str(DEFAULT_SPEED)))
	var day_timeout := int(_env("PK_SAVE_REPLAY_DAY_TIMEOUT_MSEC",
		str(DEFAULT_DAY_TIMEOUT_MSEC)))
	_result = {
		"slot": slot, "requested_days": days, "speed": speed,
		"day_timeout_msec": day_timeout,
	}
	print("[save-replay] slot=%s days=%d speed=%.1f day_timeout=%dms" % [
		slot, days, speed, day_timeout])

	_game_flow = get_tree().root.get_node_or_null("GameFlow")
	if _game_flow == null:
		_fail("game_flow_autoload_missing")
		return
	if days <= 0:
		_fail("days_must_be_positive")
		return

	var begin: Dictionary = _game_flow.call("begin_load_game", slot)
	if not bool(begin.get("ok", false)):
		_fail("load_rejected:%s" % String(begin.get("code", "unknown")))
		return
	var host: WorldRuntimeHost = await _wait_for_runtime()
	if host == null:
		_fail("runtime_never_became_ready")
		return

	var scene := host.get_parent() as PlayerGame
	var clock: WorldClock = scene.get_node("WorldClock")
	var generator := host.generator()
	# 场景起来了不等于存档恢复成功。PKSR/PKCN 恢复失败时世界照样存在、时钟照样
	# 能跑，只是没有任何权威在模拟 —— 那种情况下"跑满 N 天"是假绿，必须拦住。
	var restore_error := _restore_defect(generator)
	if not restore_error.is_empty():
		_result["forensics"] = RuntimeForensics.capture_and_dump(
			restore_error, generator, clock, "save_replay_restore_failed",
			{"slot": slot})
		_fail(restore_error)
		return
	var start_day := clock.day_index()
	if OS.get_environment("PK_SAVE_MIGRATE") == "1" and not OS.get_environment("PK_SAVE_MIGRATE_OUTPUT_SLOT").is_empty():
		var format: Dictionary = generator.get_data_core_world_ext().get_economy_checkpoint_format()
		if int(format.get("hash_version", 0)) != 2 or int(format.get("schema_version", 0)) != 54:
			_fail("save_migration_requires_hash_v2_extension")
			return
		clock.pause(true)
		var save = get_tree().root.get_node("GameSave")
		# Tool-local suppression; do not change the player's persisted settings.
		save.set("_autosave_enabled", false)
		var migrated: Dictionary = await save.request_manual_save(OS.get_environment("PK_SAVE_MIGRATE_OUTPUT_SLOT"))
		_result["migration"] = migrated
		_result["checkpoint_format"] = format
		_result["start_day"] = start_day
		_result["end_day"] = clock.day_index()
		if not bool(migrated.get("ok", false)) or clock.day_index() != start_day:
			_fail("save_migration_failed_or_advanced_day")
			return
		_finish()
		return
	_result["start_day"] = start_day
	_result["target_day"] = start_day + days
	print("[save-replay] loaded day=%d country=%s economy=%s" % [
		start_day,
		JSON.stringify(generator.get_country_report().get("state_hash", "")),
		JSON.stringify(generator.get_economy_report().get("state_hash", "")),
	])

	await _advance(host, clock, generator, start_day + days, day_timeout)
	_finish()


## 推进到目标日。每帧检查三件事：fatal、日推进、单日超时。
## 不复制 WorldRuntimeHost 的调度，只是驱动时钟并观察。
func _advance(host: WorldRuntimeHost, clock: WorldClock, generator,
		target_day: int, day_timeout: int) -> void:
	clock.set_speed(_result["speed"])
	clock.pause(false)
	# 时钟前进不等于模拟前进。经济结算水位不动的话，这轮回放什么也没验证。
	var start_newest_day := int(
		generator.get_economy_report().get("newest_state_day", -1))
	var last_day_msec := Time.get_ticks_msec()
	var started_msec := last_day_msec
	var thread_start: Dictionary = generator.get_runtime_perf_snapshot(0)
	var worker_start := int(thread_start.get("simulation_committed_day", -1))
	var worker_target := worker_start + int(_result["requested_days"])
	var worker_end := worker_start
	var last_day := worker_start if worker_start >= 0 else clock.day_index()
	var warmup_days := maxi(0, int(_env("PK_SAVE_REPLAY_WARMUP_DAYS", "0")))
	var warmup_target := worker_start + warmup_days
	var measuring := warmup_days == 0
	_result["warmup_days"] = warmup_days
	_result["warmup_start_authoritative_day"] = worker_start
	_result["target_authoritative_day"] = worker_target
	while true:
		await get_tree().process_frame
		var progress: Dictionary = generator.get_runtime_perf_snapshot(0)
		worker_end = int(progress.get("simulation_committed_day", -1))
		if not measuring and worker_start >= 0 and worker_end >= warmup_target:
			# Anchor to the actual observed commit, including any frame coalescing.
			worker_start = worker_end
			worker_target = worker_start + int(_result["requested_days"])
			_result["target_authoritative_day"] = worker_target
			_result["warmup_actual_days"] = worker_start - int(_result["warmup_start_authoritative_day"])
			thread_start = progress
			started_msec = Time.get_ticks_msec()
			measuring = true
		if measuring and worker_start >= 0 and worker_end >= worker_target:
			break
		if worker_start < 0 and clock.day_index() >= target_day:
			break
		var economy: Dictionary = generator.get_economy_perf_report()
		var worker_fault := int(progress.get("worker_fault_count", 0)) > 0 \
			or bool(progress.get("economy_authority_fault_paused", false)) \
			or not String(progress.get("economy_capture_fatal_reason", "")).is_empty()
		if worker_fault or bool(economy.get("fatal", false)):
			clock.set_speed(0.0)
			_result["fatal_day"] = clock.day_index()
			_result["forensics"] = RuntimeForensics.capture_and_dump(
				String(economy.get("fatal_reason", "unknown")),
				generator, clock, "save_replay_fatal",
				{"slot": _result["slot"], "start_day": _result["start_day"]})
			_fail("economy_fatal:%s" % String(economy.get("fatal_reason",
				progress.get("fault_code", "unknown"))))
			return
		var day := worker_end if worker_start >= 0 else clock.day_index()
		var now := Time.get_ticks_msec()
		if day != last_day:
			last_day = day
			last_day_msec = now
			continue
		if now - last_day_msec < day_timeout:
			continue
		clock.set_speed(0.0)
		_result["stalled_day"] = day
		_result["stalled_ms"] = now - last_day_msec
		_result["forensics"] = RuntimeForensics.capture_and_dump(
			"save_replay_day_stalled", generator, clock, "save_replay_stall",
			{"slot": _result["slot"], "stalled_day": day,
			 "stalled_ms": now - last_day_msec})
		_fail("day_stalled:%d" % day)
		return
	clock.set_speed(0.0)
	var elapsed := Time.get_ticks_msec() - started_msec
	_result["end_day"] = clock.day_index()
	_result["elapsed_msec"] = elapsed
	_result["days_per_sec"] = (
		float(worker_end - worker_start if worker_start >= 0 else
			clock.day_index() - _result["start_day"]) / max(0.001, elapsed / 1000.0))
	_result["start_authoritative_day"] = worker_start
	_result["end_authoritative_day"] = worker_end
	var final_progress: Dictionary = generator.get_runtime_perf_snapshot(0)
	var timing_deltas := {}
	for category in ["execute", "input_wait", "clock_wait", "save_build",
			"save_pause", "paused", "overhead", "boundary_wait"]:
		var key := "worker_time_%s_us" % category
		timing_deltas[category] = int(final_progress.get(key, 0)) - int(thread_start.get(key, 0))
	_result["measurement_worker_time_us"] = timing_deltas
	# The compatibility bridge deliberately returns its last safe report while
	# the worker owns mutable arrays. A final assertion must wait for a fresh
	# boundary report, rather than interpret a marked cached revision as final.
	var final_report_started := Time.get_ticks_msec()
	var final_economy: Dictionary = generator.get_economy_report()
	while bool(final_economy.get("report_boundary_pending", false)) \
			and Time.get_ticks_msec() - final_report_started < 5000:
		await get_tree().process_frame
		final_economy = generator.get_economy_report()
	_result["final_report_wait_msec"] = Time.get_ticks_msec() - final_report_started
	if bool(final_economy.get("report_boundary_pending", false)):
		_failures.append("final_economy_report_pending")
	var final_audit := final_economy
	var audit_ext = generator.get_data_core_world_ext()
	if audit_ext != null and audit_ext.has_method("get_economy_committed_audit_report"):
		final_audit = audit_ext.get_economy_committed_audit_report()
		if not bool(final_audit.get("available", false)):
			_failures.append("committed_audit_missing")
		_result["committed_audit"] = final_audit
	_result["start_newest_state_day"] = start_newest_day
	_result["end_newest_state_day"] = int(
		final_economy.get("newest_state_day", -1))
	if int(final_economy.get("newest_state_day", -1)) <= start_newest_day:
		_failures.append("economy_never_settled")
	var worker_error := _worker_defect(generator)
	if not worker_error.is_empty():
		_failures.append(worker_error)
	# One cold report at the end also supplies reproducible workload counters.
	_dump_full_thread_report(generator)
	_result["audit_incomplete"] = bool(final_audit.get("audit_incomplete", true))
	for key in ["population_error", "money_error", "goods_error"]:
		_result[key] = int(final_audit.get(key, 0))
		if int(final_audit.get(key, 0)) != 0:
			_failures.append("%s=%d" % [key, int(final_audit.get(key, 0))])
	# 走到这里意味着复现没有重现故障。这同样是结论，而且要留下现场以便和失败
	# 的那一次逐字段比对。
	_result["forensics"] = RuntimeForensics.capture_and_dump(
		"save_replay_completed", generator, clock, "save_replay_ok",
		{"slot": _result["slot"], "days": _result["requested_days"]})


## 返回空串表示恢复正常；否则是该报告的失败原因。
func _restore_defect(generator) -> String:
	var country: Dictionary = generator.get_country_report()
	var economy: Dictionary = generator.get_economy_report()
	_result["restore"] = {
		"country_bootstrapped": bool(country.get("bootstrapped", false)),
		"economy_bootstrapped": bool(economy.get("bootstrapped", false)),
		"settlement_source": String(
			generator.gameplay_start_report().get("settlement_source", "")),
	}
	if not bool(country.get("bootstrapped", false)):
		return "restore_country_not_bootstrapped"
	if not bool(economy.get("bootstrapped", false)):
		return "restore_economy_not_bootstrapped"
	var thread: Dictionary = generator.get_runtime_thread_report() \
		if generator.has_method("get_runtime_thread_report") else {}
	_result["restore"]["host_state"] = String(thread.get(
		"simulation_host_state", ""))
	# 读档完成时 worker 还没被第一次 tick 拉起，STOPPED 在这里是正常的；
	# 是否真的在跑由 _advance 结束时的 _worker_defect 判定。
	if String(thread.get("simulation_host_state", "")) == "FAULTED":
		return "restore_worker_faulted:%s" % String(thread.get("fault_code", ""))
	return ""


## 跑完之后 worker 仍停在 STOPPED/FAULTED，说明请求了后台权威却从未真正启动。
func _worker_defect(generator) -> String:
	var thread: Dictionary = generator.get_runtime_thread_report() \
		if generator.has_method("get_runtime_thread_report") else {}
	_result["end_host_state"] = String(thread.get("simulation_host_state", ""))
	if String(thread.get("requested_simulation_thread_mode", "OFF")) != "OFF" \
			and String(thread.get("simulation_host_state", "")) in ["STOPPED", "FAULTED"]:
		return "worker_not_running:%s" % String(thread.get("simulation_host_state", ""))
	return ""


func _dump_full_thread_report(generator) -> void:
	if not generator.has_method("get_runtime_thread_report"):
		return
	var path := ProjectSettings.globalize_path("res://").path_join(
		"..\\..\\tmp\\save_replay_thread_report.json").simplify_path()
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		return
	var report: Dictionary = generator.get_runtime_thread_report()
	# 跨域资产事务（财政/研究/cohort 现金）的 D7 协议状态不在 thread report 里，
	# 而经济卡在 *_peer_pending 时答案往往就在这里。
	var ext = generator.get_data_core_world_ext() \
		if generator.has_method("get_data_core_world_ext") else null
	if ext != null and ext.has_method("get_country_economy_asset_protocol_status"):
		report["d7_asset_protocol"] = ext.get_country_economy_asset_protocol_status()
	report["economy_report"] = generator.get_economy_report()
	file.store_string(JSON.stringify(report, "  "))
	file.close()
	_result["thread_report"] = path


func _wait_for_runtime() -> WorldRuntimeHost:
	for _frame in range(RUNTIME_READY_FRAMES):
		await get_tree().process_frame
		var scene := get_tree().current_scene
		if scene == null or not scene is PlayerGame:
			continue
		var host := scene.get_node_or_null("RuntimeHost") as WorldRuntimeHost
		if host != null and host.current_map() != null and host.generator() != null \
				and bool(host.generator().gameplay_start_report().get("ok", false)):
			await get_tree().process_frame
			return host
	return null


func _env(name: String, fallback: String) -> String:
	var value := OS.get_environment(name).strip_edges()
	return value if not value.is_empty() else fallback


func _fail(reason: String) -> void:
	_failures.append(reason)
	push_error("[save-replay] %s" % reason)
	_finish()


func _finish() -> void:
	if _finished:
		return
	_finished = true
	_result["failures"] = _failures
	_result["ok"] = _failures.is_empty()
	# 单行机器可读结果。包装脚本按这个前缀解析，不要改前缀。
	print("[save-replay/result] %s" % JSON.stringify(_result))
	get_tree().quit(0 if _failures.is_empty() else 1)
