extends Node

## 开拓备货探针。以玩家国家发起一次家族开拓，然后每个权威提交日打印开拓快照、
## 采购拒绝原因与 Economy 的 D7 资产通道掩码。
##
## 读档模式（与 headless_save_replay.gd 同进程，由回放脚本推进时钟）：
##   $env:PK_SAVE_REPLAY = "1"; $env:PK_COLONIZATION_PROBE = "1"
## 新开局模式（探针自己开局并推进时钟，自动处理家族扶持与时代奖励弹窗）：
##   $env:PK_COLONIZATION_PROBE = "1"; $env:PK_COLONIZATION_PROBE_NEW_GAME = "1"
##   $env:PK_COLONIZATION_PROBE_AFTER_DAYS = "30"   # 开局后多少天发起开拓
##   $env:PK_COLONIZATION_PROBE_DAYS = "60"         # 发起后观察多少天
##   $env:PK_SAVE_DIR 指向临时目录，避免自动存档覆盖玩家槽位
## 通用：
##   $env:PK_COLONIZATION_PROBE_POPULATION = "20"   # 派遣人数上限

const RUNTIME_READY_FRAMES := 4800
const BOUNDARY_WAIT_FRAMES := 1200
const MAX_TARGET_PROBES := 2400
const STALL_FRAMES := 20000

var _expedition := 0
var _last_day := -1
var _new_game := false


func _ready() -> void:
	call_deferred("_run")


func _run() -> void:
	_new_game = _env("PK_COLONIZATION_PROBE_NEW_GAME", "0") == "1"
	if _new_game and not await _begin_new_game():
		_quit(1)
		return
	var host := await _wait_for_runtime()
	if host == null:
		push_error("[colonization-probe] runtime never became ready")
		_quit(1)
		return
	var scene := get_tree().current_scene
	var controller = scene.get_node_or_null("PlayerController")
	var clock := scene.get_node_or_null("WorldClock") as WorldClock
	var generator := host.generator()
	var ext = generator.get_data_core_world_ext()
	if controller == null:
		push_error("[colonization-probe] PlayerController missing")
		_quit(1)
		return
	var population_cap := maxi(1, int(_env("PK_COLONIZATION_PROBE_POPULATION", "20")))
	var after_days := int(_env("PK_COLONIZATION_PROBE_AFTER_DAYS", "0"))
	var observe_days := int(_env("PK_COLONIZATION_PROBE_DAYS", "60"))
	var speed := float(_env("PK_COLONIZATION_PROBE_SPEED", "20"))
	_print_mask(generator, "loaded")
	var start_day := -1
	var launch_day := -1
	var stall := 0
	while is_inside_tree():
		await get_tree().process_frame
		if _new_game:
			_drive(controller, clock, speed)
		var day := int(generator.get_runtime_perf_snapshot(0).get("simulation_committed_day", -1))
		if day < 0:
			continue
		if start_day < 0:
			start_day = day
		if day == _last_day:
			stall += 1
			if _new_game and stall > STALL_FRAMES:
				push_error("[colonization-probe] clock stalled at day %d paused=%s founding=%s era=%s" % [
					day, str(clock.paused if clock != null else null),
					str(controller.get("_family_founding_locked")),
					str(controller.get("_era_reward_locked"))])
				_quit(1)
				return
			continue
		stall = 0
		_last_day = day
		if _expedition == 0 and day - start_day >= after_days:
			_expedition = await _start(controller, host.current_map().cell_count(), population_cap)
			if _expedition != 0:
				launch_day = day
				_print_mask(generator, "launched")
			continue
		if _expedition <= 0:
			if _expedition < 0:
				_quit(1)
				return
			continue
		_report(day, controller, generator)
		if _new_game and day - launch_day >= observe_days:
			_quit(0)
			return


func _begin_new_game() -> bool:
	var game_flow := get_tree().root.get_node_or_null("GameFlow")
	if game_flow == null:
		push_error("[colonization-probe] GameFlow autoload missing")
		return false
	var config := NewGameConfig.new()
	config.country.name = "Probe Nation"
	config.country.foreign_count = int(_env("PK_COLONIZATION_PROBE_FOREIGN", "3"))
	config.base.initial_seed = int(_env("PK_COLONIZATION_PROBE_SEED", "20260718"))
	var begin: Dictionary = game_flow.call("begin_new_game", config)
	print("[colonization-probe] new game begin=%s" % JSON.stringify(begin))
	return bool(begin.get("ok", false))


func _drive(controller, clock: WorldClock, speed: float) -> void:
	if bool(controller.get("_family_founding_locked")):
		var result: Dictionary = controller.request_command(&"family.founding.choose", {
			"offer_id": int(controller.get("_family_founding_offer_id")),
			"generation": int(controller.get("_family_founding_generation")),
			"choice_index": 0,
		})
		if bool(result.get("ok", false)):
			print("[colonization-probe] family founding chosen: %s" % JSON.stringify(result))
	if bool(controller.get("_era_reward_locked")):
		var era: Dictionary = controller.request_command(&"era_reward.choose", {
			"offer_generation": int(controller.get("_era_reward_generation")),
			"choice_index": 0,
		})
		if bool(era.get("ok", false)):
			print("[colonization-probe] era reward chosen: %s" % JSON.stringify(era))
	if clock != null and clock.paused and not bool(controller.get("_family_founding_locked")) \
			and not bool(controller.get("_era_reward_locked")):
		clock.set_speed(speed)
		clock.pause(false)


func _report(day: int, controller, generator) -> void:
	var snap: Dictionary = controller.get_family_expedition_snapshot(_expedition)
	var thread: Dictionary = generator.get_runtime_thread_report()
	print("[colonization-probe] day=%d ok=%s state=%s blocker=%s material=%s/%s bridge=%s/%s missing=%s pending=%s phase=%s peer_blocked=%s reject_day=%s reject=%s gate_mask=0x%x" % [
		day, str(snap.get("ok", false)), str(snap.get("state", "")),
		str(snap.get("kit_blocker", "")),
		str(snap.get("kit_material_missing_units", "")), str(snap.get("kit_material_required_units", "")),
		str(snap.get("kit_bridge_missing_units", "")), str(snap.get("kit_bridge_required_units", "")),
		str(snap.get("kit_missing_good_ids", "")),
		str(snap.get("kit_procurement_pending", "")), str(snap.get("kit_procurement_phase", "")),
		str(snap.get("kit_procurement_blocked_by_peer", "")),
		str(snap.get("kit_procurement_rejected_day", "")),
		str(snap.get("kit_procurement_rejection", "")),
		int(thread.get("economy_pod_operation_gate_mask", -1)),
	])
	if not bool(snap.get("ok", false)):
		print("[colonization-probe] snapshot=%s" % JSON.stringify(snap))


func _start(controller, cell_count: int, population_cap: int) -> int:
	for target in range(mini(cell_count, MAX_TARGET_PROBES)):
		var page: Dictionary = controller.get_family_colonization_quotes(target, 0, -1, 0, 8)
		if not bool(page.get("ok", false)):
			if bool(page.get("busy", false)):
				return 0
			continue
		var tokens: PackedInt64Array = page.get("quote_tokens", PackedInt64Array())
		if tokens.is_empty() or String(page.get("kind", "")) != "colonize":
			continue
		var maxima: PackedInt64Array = page.get("maximum_populations", PackedInt64Array())
		var args := {
			"family_handle": int(page.get("family_handles")[0]),
			"source_cell": int(page.get("source_cells")[0]),
			"target_cell": target,
			"population": mini(population_cap, int(maxima[0])),
			"quote_token": int(tokens[0]),
		}
		var result: Dictionary = controller.request_command(&"family.colonization.start", args)
		print("[colonization-probe] start args=%s result=%s" % [JSON.stringify(args), JSON.stringify(result)])
		if not bool(result.get("ok", false)):
			continue
		var handle := int(result.get("expedition_handle", 0))
		if handle != 0:
			return handle
		# Queued starts settle at the next commit; the handle shows up in the list.
		for _frame in range(BOUNDARY_WAIT_FRAMES * 4):
			await get_tree().process_frame
			var listed: Dictionary = controller.get_family_expeditions(0, 8)
			var handles = listed.get("expedition_handles", PackedInt64Array())
			if handles.size() > 0:
				return int(handles[0])
		push_error("[colonization-probe] queued start never produced an expedition")
		return -1
	# No family or no colonize target yet; retry on a later day.
	return 0


func _print_mask(generator, label: String) -> void:
	var thread: Dictionary = generator.get_runtime_thread_report()
	var keys := PackedStringArray()
	for key in thread.keys():
		var name := String(key)
		if name.contains("operation_gate") or name.contains("authoritative_domain") \
				or name == "simulation_thread_mode" or name.contains("pod_authority_ready"):
			keys.append("%s=%s" % [name, str(thread[key])])
	print("[colonization-probe] %s %s" % [label, " ".join(keys)])


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


func _quit(code: int) -> void:
	if _new_game:
		print("[colonization-probe] done code=%d" % code)
		get_tree().quit(code)


func _env(name: String, fallback: String) -> String:
	var value := OS.get_environment(name).strip_edges()
	return value if not value.is_empty() else fallback
