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
##   $env:PK_COLONIZATION_PROBE_REQUIRE_OUTBOUND = "1" # 未观察到出发回执则失败
##   $env:PK_COLONIZATION_PROBE_SAVE_PENDING = "1" # 阶段 5 时在隔离目录保存
##   $env:PK_COLONIZATION_PROBE_WIDTH / HEIGHT     # 重放指定地图大小

const RUNTIME_READY_FRAMES := 4800
const BOUNDARY_WAIT_FRAMES := 1200
const MAX_TARGET_PROBES := 2400
const STALL_FRAMES := 20000

var _expedition := 0
var _last_day := -1
var _new_game := false
var _save_attempted := false
var _reached_outbound := false
var _quote_diag_left := 3


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
	_audit_colony_state(-1, controller, ext)
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
		_audit_colony_state(day, controller, ext)
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
		var expedition := _report(day, controller, generator)
		if int(expedition.get("state", -1)) in [1, 2]:
			_reached_outbound = true
		if not _reached_outbound:
			# Background disk writes resume the clock before returning. A short
			# route can finish during that await, so use durable receipts too.
			var receipts: Dictionary = ext.get_family_colonization_receipts(
				controller.get_player_country_handle(), 0, 256)
			for receipt in receipts.get("receipts", []):
				if int(receipt.get("expedition_handle", 0)) == _expedition \
						and String(receipt.get("code", "")) == "STARTED":
					_reached_outbound = true
					print("[colonization-probe] departure receipt=%s" % JSON.stringify(receipt))
		if _new_game and not _save_attempted \
				and _env("PK_COLONIZATION_PROBE_SAVE_PENDING", "0") == "1" \
				and bool(expedition.get("kit_procurement_pending", false)) \
				and int(expedition.get("kit_procurement_phase", 0)) == 5:
			_save_attempted = true
			var saved: Dictionary = await get_tree().root.get_node("GameSave").request_manual_save("manual_3")
			print("[colonization-probe] pending-save result=%s" % JSON.stringify({
				"ok": saved.get("ok", false), "code": saved.get("code", ""),
				"message": saved.get("message", ""),
				"day": saved.get("header", {}).get("day", -1)}))
			if not bool(saved.get("ok", false)):
				_quit(1)
				return
		if _new_game and day - launch_day >= observe_days:
			var require_outbound := _env("PK_COLONIZATION_PROBE_REQUIRE_OUTBOUND", "0") == "1"
			if require_outbound and not _reached_outbound:
				push_error("[colonization-probe] expedition never reached OUTBOUND")
			_quit(0 if not require_outbound or _reached_outbound else 1)
			return


## Read-only colony audit. A restored save may already carry an expedition
## stuck in SETTLING; replaying it is a better check of population landing than
## trying to dispatch a fresh one (quotes can be unavailable in headless).
## Prints the expedition rows, their target cell population, the in-transit
## population and durable receipts on load and on every authoritative day.
func _audit_colony_state(day: int, controller, ext) -> void:
	if controller == null or ext == null:
		return
	var country := int(controller.get_player_country_handle()) \
		if controller.has_method("get_player_country_handle") else 0
	var page: Dictionary = controller.get_family_expeditions(0, 8) \
		if controller.has_method("get_family_expeditions") else {}
	var handles: Array = page.get("expedition_handles", [])
	var targets: Array = page.get("target_cells", [])
	var states: Array = page.get("states", [])
	var populations: Array = page.get("populations", [])
	var rows: Array = []
	for index in range(handles.size()):
		var target := int(targets[index]) if index < targets.size() else -1
		var cell_pop := -1
		var cohorts := -1
		if target >= 0 and ext.has_method("get_population_cell_summary"):
			var cell: Dictionary = ext.get_population_cell_summary(target)
			cell_pop = int(cell.get("population", 0))
			cohorts = int(cell.get("cohort_count", 0))
		rows.append({
			"handle": int(handles[index]),
			"state": int(states[index]) if index < states.size() else -1,
			"target": target,
			"party": int(populations[index]) if index < populations.size() else -1,
			"cell_pop": cell_pop,
			"cohorts": cohorts,
		})
	var econ: Dictionary = ext.get_economy_report() \
		if ext.has_method("get_economy_report") else {}
	var receipts: Dictionary = ext.get_family_colonization_receipts(country, 0, 256) \
		if ext.has_method("get_family_colonization_receipts") else {}
	var codes: Array = []
	for raw in receipts.get("receipts", []):
		codes.append(String((raw as Dictionary).get("code", "")))
	print("[colony-audit] day=%d country=%d active=%s transit=%s due=%s page_ok=%s page_total=%s receipts_ok=%s rows=%s receipts=%s" % [
		day, country,
		str(econ.get("family_expedition_active_count", -1)),
		str(econ.get("family_expedition_transit_population", -1)),
		str(econ.get("family_expedition_due_heap_count", -1)),
		str(page.get("ok", false)), str(page.get("total", -1)),
		str(receipts.get("ok", false)),
		JSON.stringify(rows), JSON.stringify(codes)])
	if day < 0 or day % 5 == 0:
		_audit_territory_population(day, ext, country)


## Direct evidence for "the colonized cell has 0 population": count the
## player's owned cells whose authoritative population is still zero.
func _audit_territory_population(day: int, ext, country: int) -> void:
	if ext == null or not ext.has_method("get_country_snapshot") \
			or not ext.has_method("get_population_cell_summary"):
		return
	var snap: Dictionary = ext.get_country_snapshot(country)
	var cells: PackedInt32Array = snap.get("territory_cells", PackedInt32Array())
	var zero: Array = []
	var total_pop := 0
	for cell in cells:
		var summary: Dictionary = ext.get_population_cell_summary(int(cell))
		var pop := int(summary.get("population", 0))
		total_pop += pop
		if pop <= 0:
			zero.append(int(cell))
	var sample: Array = zero.slice(0, 10)
	print("[colony-territory] day=%d country=%d snapshot_ok=%s cells=%d total_pop=%d zero_count=%d zero_sample=%s" % [
		day, country, str(snap.get("ok", snap.get("country_ok", false))),
		cells.size(), total_pop, zero.size(), JSON.stringify(sample)])


func _begin_new_game() -> bool:
	var game_flow := get_tree().root.get_node_or_null("GameFlow")
	if game_flow == null:
		push_error("[colonization-probe] GameFlow autoload missing")
		return false
	var config := NewGameConfig.new()
	config.country.name = "Probe Nation"
	config.country.foreign_count = int(_env("PK_COLONIZATION_PROBE_FOREIGN", "3"))
	config.base.initial_seed = int(_env("PK_COLONIZATION_PROBE_SEED", "20260718"))
	config.base.map_width = int(_env("PK_COLONIZATION_PROBE_WIDTH", str(config.base.map_width)))
	config.base.map_height = int(_env("PK_COLONIZATION_PROBE_HEIGHT", str(config.base.map_height)))
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
		# Match the UI choice handler: the modal can pause daily callbacks, so
		# refresh the resolved offer lock on frame pulses as well.
		controller._sync_family_founding_offer()
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


func _report(day: int, controller, generator) -> Dictionary:
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
	elif bool(snap.get("kit_procurement_pending", false)):
		print("[colonization-probe] procurement=%s" % JSON.stringify({
			"day": day, "good_id": snap.get("kit_procurement_good_id", -1),
			"quantity": snap.get("kit_procurement_quantity", 0),
			"started_day": snap.get("kit_procurement_started_day", -1),
			"read_view_source": snap.get("read_view_source", ""),
			"read_view_day": snap.get("read_view_day", -1),
		}))
	return snap


func _start(controller, cell_count: int, population_cap: int) -> int:
	var target_limit := int(_env("PK_COLONIZATION_PROBE_TARGET_LIMIT", str(MAX_TARGET_PROBES)))
	# A silent "return 0" used to hide why no expedition was ever dispatched.
	var diag_ok := 0
	var diag_busy := 0
	var diag_rejected := 0
	var diag_empty := 0
	var last_code := ""
	var last_kind := ""
	for target in range(mini(cell_count, target_limit)):
		var page: Dictionary = controller.get_family_colonization_quotes(target, 0, -1, 0, 8)
		if not bool(page.get("ok", false)):
			last_code = String(page.get("code", ""))
			if bool(page.get("busy", false)):
				diag_busy += 1
				break
			diag_rejected += 1
			continue
		diag_ok += 1
		var tokens: PackedInt64Array = page.get("quote_tokens", PackedInt64Array())
		var kind := String(page.get("kind", ""))
		last_kind = kind
		if tokens.is_empty() or kind != "colonize":
			diag_empty += 1
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
	if _quote_diag_left > 0:
		_quote_diag_left -= 1
		print("[colonization-probe] quote scan ok=%d busy=%d rejected=%d empty=%d last_code=%s last_kind=%s targets=%d" % [
			diag_ok, diag_busy, diag_rejected, diag_empty,
			last_code, last_kind, target_limit])
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
