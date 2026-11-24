# military_budget_terrain_refresh_test.gd
# 玩家报的缺陷：国库页里把「军事预算 / 军饷 / 维护 / 采购」调到某个档位后，过几个
# tick 会自动复位（总份额回 0、三条通道回默认 60/20/20）。
#
# 复现的序列（与玩家看到的一致）：
#   1. 玩家提交 `military.policy.set_budget`，命令在下一个军事日生效；
#   2. 世界继续推进若干 tick；
#   3. 季节刷新把新的 cover 推给军事地形（`refresh_military_terrain`）；
#   4. 再次读国家快照 —— 档位必须还是玩家设的那个。
#
# 为什么会在第 3 步丢：`MilitaryFacade.set_terrain()` 为了保住军队/战争，会先
# `encode_military_state()`（PKMI）再把整份状态 `restore_military_state()` 回来。
# 而预算三份额按需求 9.3 是 transient，**不进 PKMI**（`military_core_save.cpp`
# 的 `write_policies` 不写，restore 按默认值重建 policy 行），所以这一圈往返会
# 把它们打回默认值；地形重推不是读档，`PlayerController._repush_military_budget()`
# 不会被触发，于是一路保持归零。
#
# 本测试同时钉一条控制断言：**原生**的 same-topology `set_military_terrain`
# 本身不会动 policy（`MilitaryCore::set_terrain` 只在 shape 变化时 reset_state）。
# 也就是说第 3 步的损伤完全来自那圈多余的 PKMI 往返，而不是地形推送本身。
#
# Headless:
#   <godot> --headless --path Project/project-keynes \
#     -s res://tests/military/military_budget_terrain_refresh_test.gd

extends SceneTree

const SEED := 20260801
const MAP_W := 48
const MAP_H := 32
const FOREIGN_COUNT := 2
const PIPELINE_DEPTH := 3
const MAX_BARRIER_PULSES_PER_DAY := 4096
## 玩家设的档位：总份额 30%，通道 45% / 25% / 30%。
const TOTAL_BP := 3000
const WAGE_BP := 4500
const UPKEEP_BP := 2500
const PROCUREMENT_BP := 3000
## 设档之后先过几个 tick 再遇到季节地形重推，与玩家报的时序一致。
const TICKS_BEFORE_REFRESH := 3
## 复现里的兵额目标：一条与预算无关的 policy 字段，用来证明地形推送本身不清 policy。
const TARGET_VALUE := 8

var _failures := PackedStringArray()
var _skips := PackedStringArray()
var _clock: WorldClock = null
var _host: WorldRuntimeHost = null
var _generator = null
var _facade = null
var _ext = null
var _map = null
var _player := 0
var _day := 0


func _init() -> void:
	await process_frame
	var code: int = await _run()
	quit(code)


func _run() -> int:
	if not ClassDB.class_exists("DCWorldExt"):
		_skip("military budget terrain refresh", "DCWorldExt is not in this build")
		return _finish()
	if not await _boot_world():
		return _finish()
	_facade = _generator.get_military_facade() \
		if _generator.has_method("get_military_facade") else null
	if _facade == null or not _facade.is_configured():
		_expect("military facade is configured", false,
			"null" if _facade == null else str(_facade.configure_result()))
		return _finish()
	_ext = _generator.get_data_core_world_ext() \
		if _generator.has_method("get_data_core_world_ext") else null
	_map = _host.get_current_map()
	if _ext == null or _map == null:
		_expect("world ext and map are available", false)
		return _finish()

	var start: Dictionary = _generator.gameplay_start_report()
	var capital := int(start.get("cell", -1))
	var country = _generator.get_country_facade() \
		if _generator.has_method("get_country_facade") else null
	if country == null or capital < 0:
		_expect("player country resolves", false,
			"cell=%d country=%s" % [capital, str(country != null)])
		return _finish()
	_player = int(country.cell_summary(capital).get("country_handle", 0))
	if _player == 0:
		_expect("player country handle resolves", false)
		return _finish()

	# 先把一条与预算无关的 policy 字段立起来，后面用它区分「地形推送清空」和
	# 「PKMI 往返清空」：target_value 进 PKMI，预算三份额不进。
	var target_submit: Dictionary = _facade.set_target(_player, 0, TARGET_VALUE)
	_expect("force.set_target is accepted", bool(target_submit.get("ok", false)),
		str(target_submit))
	if not await _advance_to(_day + 1):
		return _finish()
	var after_target: Dictionary = _snapshot()
	_expect("target value lands on D+1",
		int(after_target.get("target_value", -1)) == TARGET_VALUE,
		"target_value=%d" % int(after_target.get("target_value", -1)))

	# ---- 控制组：原生 same-topology 地形重推不清 policy --------------------
	# 直接把同一份地形再推一次（与 facade 走的是同一个原生入口），不做 PKMI
	# 往返。target 与（此时还是 0 的）预算都应原样保留。
	var native_push: Dictionary = _ext.set_military_terrain(_terrain_payload())
	_expect("native same-topology terrain push succeeds",
		bool(native_push.get("ok", false)), str(native_push))
	var after_native: Dictionary = _snapshot()
	_expect("native terrain push keeps the stored policy (target)",
		int(after_native.get("target_value", -1)) == TARGET_VALUE,
		"target_value=%d" % int(after_native.get("target_value", -1)))

	# ---- 缺陷本身：设档 → 过几个 tick → 季节地形重推 ---------------------
	var budget_submit: Dictionary = _facade.set_budget(
		_player, TOTAL_BP, WAGE_BP, UPKEEP_BP, PROCUREMENT_BP)
	_expect("policy.set_budget is accepted", bool(budget_submit.get("ok", false)),
		str(budget_submit))
	if not await _advance_to(_day + 1):
		return _finish()
	var set_snapshot: Dictionary = _snapshot()
	_expect("the budget total lands on D+1",
		int(set_snapshot.get("budget_share_bp", -1)) == TOTAL_BP,
		"budget_share_bp=%d" % int(set_snapshot.get("budget_share_bp", -1)))
	_expect("the channel shares land on D+1",
		int(set_snapshot.get("budget_wage_bp", -1)) == WAGE_BP
			and int(set_snapshot.get("budget_upkeep_bp", -1)) == UPKEEP_BP
			and int(set_snapshot.get("procurement_share_bp", -1)) == PROCUREMENT_BP,
		"wage=%d upkeep=%d procurement=%d" % [
			int(set_snapshot.get("budget_wage_bp", -1)),
			int(set_snapshot.get("budget_upkeep_bp", -1)),
			int(set_snapshot.get("procurement_share_bp", -1))])

	if not await _advance_to(_day + TICKS_BEFORE_REFRESH):
		return _finish()
	var ticked: Dictionary = _snapshot()
	_expect("the budget survives %d plain ticks" % TICKS_BEFORE_REFRESH,
		int(ticked.get("budget_share_bp", -1)) == TOTAL_BP,
		"budget_share_bp=%d" % int(ticked.get("budget_share_bp", -1)))

	# 控制组：同一份地形直接推给原生（不经过 facade 的 PKMI 往返）同样不动预算。
	# 这条把「地形推送本身」和「那圈多余的往返」区分开：前者无害，后者才是元凶。
	var native_budget_push: Dictionary = _ext.set_military_terrain(_terrain_payload())
	_expect("native same-topology terrain push succeeds with a live budget",
		bool(native_budget_push.get("ok", false)), str(native_budget_push))
	var after_native_budget: Dictionary = _snapshot()
	_expect("native terrain push keeps the transient budget shares",
		int(after_native_budget.get("budget_share_bp", -1)) == TOTAL_BP
			and int(after_native_budget.get("budget_wage_bp", -1)) == WAGE_BP
			and int(after_native_budget.get("budget_upkeep_bp", -1)) == UPKEEP_BP,
		"budget_share_bp=%d wage=%d upkeep=%d" % [
			int(after_native_budget.get("budget_share_bp", -1)),
			int(after_native_budget.get("budget_wage_bp", -1)),
			int(after_native_budget.get("budget_upkeep_bp", -1))])

	# 季节刷新：cover 变了 -> facade 把新地形推给军事（`refresh_military_terrain`）。
	_dirty_cover()
	var refresh: Dictionary = _generator.refresh_military_terrain(_day)
	_expect("season terrain refresh actually pushes",
		bool(refresh.get("ok", false)) and not bool(refresh.get("skipped", false)),
		str(refresh))
	var after_refresh: Dictionary = _snapshot()
	_expect("the budget total survives a season terrain refresh",
		int(after_refresh.get("budget_share_bp", -1)) == TOTAL_BP,
		"budget_share_bp=%d (expected %d)" % [
			int(after_refresh.get("budget_share_bp", -1)), TOTAL_BP])
	_expect("the channel shares survive a season terrain refresh",
		int(after_refresh.get("budget_wage_bp", -1)) == WAGE_BP
			and int(after_refresh.get("budget_upkeep_bp", -1)) == UPKEEP_BP
			and int(after_refresh.get("procurement_share_bp", -1)) == PROCUREMENT_BP,
		"wage=%d upkeep=%d procurement=%d" % [
			int(after_refresh.get("budget_wage_bp", -1)),
			int(after_refresh.get("budget_upkeep_bp", -1)),
			int(after_refresh.get("procurement_share_bp", -1))])
	_expect("the envelope stays enabled after a season terrain refresh",
		bool(after_refresh.get("budget_enabled", false)))
	_expect("a non-transient policy field also survives the refresh",
		int(after_refresh.get("target_value", -1)) == TARGET_VALUE,
		"target_value=%d" % int(after_refresh.get("target_value", -1)))

	# 读档 finalize（`map_runtime_bridge.finalize_save_restore_runtime`）把同一张图
	# 强制再推一次，并要求 `state_preserved` 为真，否则整个读档会被判成
	# military_restore_terrain_failed。这条把该契约连同「不碰玩家档位」一起钉住。
	var forced: Dictionary = _facade.set_terrain(_map, _day, true,
		_generator._get_map_country_initializer()._military_settlement_tiers(_map))
	_expect("a forced same-topology push reports state_preserved",
		bool(forced.get("ok", false)) and bool(forced.get("state_preserved", false)),
		str(forced))
	var after_forced: Dictionary = _snapshot()
	_expect("the budget survives a forced same-topology push",
		int(after_forced.get("budget_share_bp", -1)) == TOTAL_BP
			and int(after_forced.get("budget_wage_bp", -1)) == WAGE_BP
			and int(after_forced.get("budget_upkeep_bp", -1)) == UPKEEP_BP,
		"budget_share_bp=%d wage=%d upkeep=%d" % [
			int(after_forced.get("budget_share_bp", -1)),
			int(after_forced.get("budget_wage_bp", -1)),
			int(after_forced.get("budget_upkeep_bp", -1))])

	return _finish()


# ------------------------------------------------------------------ world

func _boot_world() -> bool:
	_clock = WorldClock.new()
	_clock.auto_start = false
	_clock.initial_speed = 50.0
	_clock.debug_step_log = false
	get_root().add_child(_clock)
	_clock.set_speed(50.0)
	_clock.pause(true)
	_host = WorldRuntimeHost.new()
	_host.map_width = MAP_W
	_host.map_height = MAP_H
	_host.initial_seed = SEED
	get_root().add_child(_host)
	_host.configure(null, null, _clock)
	var config := NewGameConfig.create_default()
	config.country.name = "Military Budget Terrain"
	config.country.foreign_count = FOREIGN_COUNT
	config.base.map_width = MAP_W
	config.base.map_height = MAP_H
	config.base.initial_seed = SEED
	var session: Dictionary = _host.configure_session({
		"kind": "new_game", "config": config.to_dictionary()})
	if not bool(session.get("ok", false)):
		_expect("new game session configures", false, str(_compact(session)))
		return false
	await _host.generate_world(SEED)
	_generator = _host.get_generator()
	if _host.get_current_map() == null or _generator == null:
		_expect("world generates", false)
		return false
	var runtime_ext = _generator.get_data_core_world_ext() \
		if _generator.has_method("get_data_core_world_ext") else null
	if _host.runtime_climate_authority_enabled and runtime_ext != null \
			and runtime_ext.has_method("set_runtime_clock"):
		runtime_ext.set_runtime_clock(false, 50.0)
	_day = 0
	return true


func _advance_to(target_day: int) -> bool:
	if not _economy_is_healthy():
		return false
	while _day < target_day:
		if not await _step_one_day():
			return false
	# 军事日的可见性比日历晚：host 只能 replay worker 已经提交的日界，而 worker
	# 相对日历有 PIPELINE_DEPTH 的管线滞后（`simulation_committed_day >= day - 1
	# - PIPELINE_DEPTH`，与 military_maintenance_conservation_test 同一契约）。
	# 所以「军事日 target_day 已经跑过」通常需要日历再往前走几天；这里继续走，
	# 步数有上限，断言本身不放宽（仍然要求 last_step_day 精确到达 target_day）。
	var guard := 0
	while int(_facade.report().get("last_step_day", -1)) < target_day \
			and guard < PIPELINE_DEPTH + 2:
		guard += 1
		if not await _step_one_day():
			return false
	_diag("advance->%d done" % target_day)
	if int(_facade.report().get("last_step_day", -1)) < target_day:
		_expect("the military day reaches day %d" % target_day, false,
			"last_step_day=%d clock_day=%d" % [
				int(_facade.report().get("last_step_day", -1)), _day])
		return false
	return _economy_is_healthy()


func _step_one_day() -> bool:
	_day += 1
	_clock.current_day = float(_day)
	var phase := _clock.season_phase_for_day(_day)
	if _host.runtime_climate_authority_enabled:
		var capacity_deadline := Time.get_ticks_usec() + 60000000
		while not bool(_host.wait_for_climate_consumed(0).get("ok", true)) \
				and Time.get_ticks_usec() < capacity_deadline:
			_host._consume_runtime_commit_if_ready()
			if not _economy_is_healthy():
				return false
			await process_frame
		_host._consume_runtime_commit_if_ready()
	_host.run_daily_tick(_day, phase)
	_host.finish_daily_tick(0.0, {})
	# 让 worker 与军事 replay 追上「日历 - 管线深度」，与官方契约一致。
	for _frame in range(240):
		_host._consume_runtime_commit_if_ready()
		if not _economy_is_healthy():
			return false
		var progress: Dictionary = _generator.get_runtime_thread_report()
		var committed := int(progress.get("simulation_committed_day",
			progress.get("committed_day", -1)))
		if committed >= _day - PIPELINE_DEPTH \
				and int(_facade.report().get("last_step_day", -1)) >= _day - PIPELINE_DEPTH:
			break
		await process_frame
	var pulses := 0
	while _has_hard_barrier() and pulses < MAX_BARRIER_PULSES_PER_DAY:
		_clock.simulation_backpressure_pulse.emit(_day)
		pulses += 1
		await process_frame
		if not _economy_is_healthy():
			return false
	if _has_hard_barrier():
		_expect("hard barrier drains at day %d" % _day, false)
		return false
	_diag("after clock day %d" % _day)
	return _economy_is_healthy()


func _diag(tag: String) -> void:
	if _host == null or _facade == null or _generator == null:
		return
	var control: Dictionary = _host._runtime_control_state()
	var mil: Dictionary = _facade.report()
	print("[diag] %s :: clock_day=%d mil_last_step=%d host_mil_last=%d host_mil_pending=%d commit_day=%d commit_gen=%d worker_day=%d worker_ready=%s mode=%s" % [
		tag, _day,
		int(mil.get("last_step_day", -1)),
		int(_host._runtime_military_last_commit_day),
		int(_host._runtime_military_pending_target_day),
		int(_host._runtime_commit_day),
		int(_host._runtime_commit_generation),
		int(control.get("simulation_committed_day", control.get("committed_day", -1))),
		str(bool(control.get("simulation_worker_ready", control.get("authority_ready", false)))),
		String(control.get("simulation_thread_mode",
			control.get("requested_simulation_thread_mode", "OFF")))])


func _economy_is_healthy() -> bool:
	var report: Dictionary = _generator.get_economy_report()
	if bool(report.get("fatal", false)):
		_expect("economy stays non-fatal (day %d)" % _day, false,
			str(report.get("fatal_reason", "")))
		return false
	return true


func _has_hard_barrier() -> bool:
	return _clock._simulation_backpressure_sources.has(&"country_day_barrier") \
		or _clock._simulation_backpressure_sources.has(&"economy_day_barrier")


## 与 `MilitaryFacade.set_terrain` 交给原生的地形载荷同形：同一张地图、同一份
## 邻居表，只有 cover 之后会被测试改脏。
func _terrain_payload() -> Dictionary:
	var tiers: PackedByteArray = _generator._get_map_country_initializer() \
		._military_settlement_tiers(_map)
	return {
		"cell_count": int(_map.cell_count()),
		"width": int(_map.width),
		"height": int(_map.height),
		"neighbors": _map.neighbor_indices_packed(),
		"landform": _map.base_landform_arr,
		"vegetation": _map.vegetation_arr,
		"cover": _map.cover_arr,
		"is_water": _map.is_water_arr,
		"has_river": _map.has_river_arr,
		"settlement_tier": tiers,
	}


## 改脏 cover 数组，让 facade 的 cover 签名与上一次推送不同（季节刷新时雪线 /
## 洪水 / 冰川就是这样变的），于是这次推送不会被 `terrain_unchanged` 跳过。
func _dirty_cover() -> void:
	var cover: PackedByteArray = _map.cover_arr
	if cover.is_empty():
		return
	var budget := mini(64, cover.size())
	for index in range(budget):
		cover[index] = (int(cover[index]) + 1) % 4
	_map.cover_arr = cover


func _snapshot() -> Dictionary:
	var snapshot = _facade.country_snapshot(_player)
	return snapshot if snapshot is Dictionary else {}


# ------------------------------------------------------------------ output

static func _compact(value: Dictionary) -> Dictionary:
	var out := {}
	for key in value.keys():
		var item = value[key]
		if item is Array or item is Dictionary or typeof(item) >= TYPE_PACKED_BYTE_ARRAY:
			continue
		out[key] = item
	return out


func _expect(label: String, ok: bool, detail := "") -> void:
	print("  [%s] %s%s" % ["PASS" if ok else "FAIL", label,
		"" if detail.is_empty() else " :: " + detail])
	if not ok:
		_failures.append(label)


func _skip(what: String, reason: String) -> void:
	print("SKIP: %s :: %s" % [what, reason])
	_skips.append(what)


func _finish() -> int:
	print("=== military budget terrain refresh: %d failures, %d skips ===" % [
		_failures.size(), _skips.size()])
	for failure in _failures:
		print("  FAILED: " + failure)
	return 0 if _failures.is_empty() else 1
