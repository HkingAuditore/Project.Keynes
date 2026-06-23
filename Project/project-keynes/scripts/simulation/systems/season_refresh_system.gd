extends DCSystem
class_name SeasonRefreshSystem

## Phase C.3 — DCSystem 改写自 [`SeasonRefreshJob`](../sus/jobs/season_refresh_job.gd)。
##
## 行为完全等价（11-stage round 切片在 generator 内部，本 system 仅协调 stage 推进）。
##
## reads / writes 声明：
##   - reads:  季节切换时整张地图都要参与，但内部计算的中间字段未对外暴露
##             component；这里仅声明对调度器有意义的 high-level 输入
##   - writes: cell.terrain / cell.landform / cell.vegetation / cell.cover /
##             cell.moisture / cell.base_moisture / cell.weather_dirty_mask /
##             不发布视觉 cell.snow_cover；运行时雪盖由 weather distribute 统一写入。
##
## feature_flag：留空（季节切换是世界推进必跑流程，无 toggle）。

const _SusPolicyScript = preload("res://scripts/simulation/sus/sus_policy.gd")

var generator = null
var map: MapData = null
var world_data: WorldData = null
var _stage: int = 0
var _stage_cursor: int = 0
var _season_idx: int = 0
var _round_active: bool = false
# DOTS-Final-Frontier Phase B+：本 round 是否走"全 round 单 C++ 调用"路径。
# 与 SeasonRefreshJob 完全等价：round 启动尝试 start_season_round_b_plus，成功
# 则整 round 走 run_season_round_slice_b_plus；失败/中途 fallback 退回 12-stage。
var _b_plus_active: bool = false

# ─── Periodic-driver（与 SeasonRefreshJob 完全等价）──────────────────────────
# 旧设计：season_refresh 由 WorldClock.season_changed → queue_season_refresh
#   信号触发，速度档 x20 时每 ~15 ticks 排一次 round，几乎 100% 占满主循环。
# 新设计："季节"在游戏世界里只是温度/降水/风的连续涌现表象（refresh_climate_daily
#   每天连续推进）；本 System 退化为低频"慢变量批量重算器"——按真实 SUS tick
#   自驱，每 `period_ticks` tick 启动一个 round，速度档无关，玩家观感无差异。
# 兼容开关：ClimateProfile.season_refresh_legacy_signal=true 时退回旧路径
#   （仍消费 has_pending_season_refresh），默认 false。
var period_ticks: int = 30
var _ticks_since_last_round: int = 0


func _init(p_generator, p_map: MapData, p_world: WorldData) -> void:
	id = &"season_refresh"
	priority = 50
	slice_budget_ms = 0.55
	max_slices_per_tick = 1
	must_run = false
	generator = p_generator
	map = p_map
	world_data = p_world
	policy = _SusPolicyScript.AlwaysPolicy.new()
	# 从 ClimateProfile 读 period_ticks（如配置）— 与 SeasonRefreshJob 同步。
	if p_generator != null and p_generator.has_method("_c"):
		var cp = p_generator._c()
		if cp != null and "season_refresh_period_ticks" in cp:
			period_ticks = max(1, int(cp.season_refresh_period_ticks))


func declare_reads() -> Array[StringName]:
	# 季节计算大量读 base_*  / lat_norm / elevation 等慢层字段
	return [
		DCComponentIds.CELL_BASE_MOISTURE,
		DCComponentIds.CELL_LAT_NORM,
		DCComponentIds.CELL_ELEVATION,
		DCComponentIds.CELL_LANDFORM,
		DCComponentIds.CELL_VEGETATION,
	]


func declare_writes() -> Array[StringName]:
	# 季节 redecide 改写的字段
	return [
		DCComponentIds.CELL_TERRAIN,
		DCComponentIds.CELL_LANDFORM,
		DCComponentIds.CELL_VEGETATION,
		DCComponentIds.CELL_COVER,
		DCComponentIds.CELL_MOISTURE,
		DCComponentIds.CELL_BASE_MOISTURE,
		DCComponentIds.CELL_WEATHER_DIRTY,
	]


func feature_flag() -> StringName:
	return &""


func should_run(_ctx: SusTickContext) -> bool:
	if generator == null or map == null or world_data == null:
		return false
	if _round_active:
		return true
	# 兼容开关：保留旧"信号脉冲驱动"路径供回归对照（与 SeasonRefreshJob 同步）。
	var legacy_signal: bool = false
	if generator.has_method("_c"):
		var cp = generator._c()
		if cp != null and "season_refresh_legacy_signal" in cp:
			legacy_signal = bool(cp.season_refresh_legacy_signal)
	if legacy_signal:
		if not generator.has_method("has_pending_season_refresh"):
			return false
		return bool(generator.has_pending_season_refresh())
	# 新路径：周期自驱。每 period_ticks 启动一次 round，速度档 x1/x5/x20
	# 都按"真实 tick"计数，玩家无感。
	_ticks_since_last_round += 1
	if _ticks_since_last_round < period_ticks:
		return false
	return true


func tick(_ctx) -> Dictionary:
	var t_start_us: int = Time.get_ticks_usec()
	if generator == null or map == null or world_data == null:
		return {"done": true, "work_done": 0, "elapsed_ms": 0.0, "progress_ratio": 1.0}

	if not _round_active:
		# 新路径优先：周期自驱调用 begin_periodic_season_refresh；legacy_signal
		# 模式下走 begin_pending_season_refresh 消费 pending flag（与旧行为完
		# 全一致）。与 SeasonRefreshJob 同模式。
		var legacy_signal: bool = false
		if generator.has_method("_c"):
			var cp = generator._c()
			if cp != null and "season_refresh_legacy_signal" in cp:
				legacy_signal = bool(cp.season_refresh_legacy_signal)
		if legacy_signal and generator.has_method("begin_pending_season_refresh"):
			_season_idx = int(generator.begin_pending_season_refresh())
		elif generator.has_method("begin_periodic_season_refresh"):
			_season_idx = int(generator.begin_periodic_season_refresh())
		elif generator.has_method("begin_pending_season_refresh"):
			# 防御性回退（旧 generator 没新方法时）
			_season_idx = int(generator.begin_pending_season_refresh())
		_stage = 0
		_stage_cursor = 0
		_round_active = true
		_ticks_since_last_round = 0
		# DOTS-Final-Frontier Phase B+：尝试启用 round-level 单 C++ 调用路径。
		# 与 SeasonRefreshJob 行为完全等价。
		_b_plus_active = false
		if generator.has_method("season_round_b_plus_available") and generator.season_round_b_plus_available():
			if generator.has_method("start_season_round_b_plus"):
				var bp_handle: int = int(generator.start_season_round_b_plus(map, world_data, _season_idx))
				_b_plus_active = bp_handle > 0

	# B+ 路径：整个 round 用 1 个 C++ 调度器跑，slice 由 b1 stage-boundary 切片。
	if _b_plus_active:
		var bp_max_us: int = int(slice_budget_ms * 1000.0)
		var bp_res: Dictionary = generator.run_season_round_slice_b_plus(map, world_data, bp_max_us)
		var bp_done: bool = bool(bp_res.get("done", false)) or bool(bp_res.get("fallback", false))
		var bp_stages_done: int = int(bp_res.get("stages_done", _stage))
		var bp_elapsed_ms_inner: float = float(bp_res.get("elapsed_ms", 0.0))
		_stage = clampi(bp_stages_done, 0, 12)
		if bool(bp_res.get("fallback", false)):
			# C++ 端中途 fallback：本 round 残余 stage 由后续 12-stage micro/main 跑完。
			_b_plus_active = false
		var bp_elapsed_ms: float = (Time.get_ticks_usec() - t_start_us) / 1000.0
		var bp_progress: float = 1.0 if (bp_done and _stage >= 12) else float(_stage) / 12.0
		if bp_done:
			if _stage >= 12:
				_round_active = false
				if generator.has_method("finish_season_round_b_plus"):
					generator.finish_season_round_b_plus(map, world_data, _season_idx)
				if generator.has_method("finish_season_refresh"):
					generator.finish_season_refresh(map, world_data, _season_idx)
				_stage = 0
				_stage_cursor = 0
		var _unused_inner: float = bp_elapsed_ms_inner
		return {
			"done": bp_done and _stage >= 12,
			"work_done": 1,
			"elapsed_ms": bp_elapsed_ms,
			"progress_ratio": bp_progress,
			"stage": _stage,
			"stage_name": "b_plus_round",
			"substage": "stages_done_%d" % _stage,
			"path": "b_plus",
			"cursor": 0,
		}

	var micro_handled: bool = false
	var micro_done: bool = false
	var micro_stage_name: String = ""
	var micro_work_done: int = 1
	var stage_started: int = _stage
	if generator.has_method("run_season_refresh_stage_micro"):
		var micro: Dictionary = generator.run_season_refresh_stage_micro(map, world_data, _season_idx, _stage, _stage_cursor)
		micro_handled = bool(micro.get("handled", false))
		if micro_handled:
			_stage_cursor = int(micro.get("cursor", _stage_cursor))
			micro_done = bool(micro.get("done", false))
			micro_stage_name = str(micro.get("stage_name", ""))
			micro_work_done = int(micro.get("work_done", micro_work_done))
			if micro_done:
				_stage += 1
				_stage_cursor = 0

	if not micro_handled and generator.has_method("run_season_refresh_stage"):
		generator.run_season_refresh_stage(map, world_data, _season_idx, _stage)
		_stage += 1
		_stage_cursor = 0
	if micro_stage_name == "":
		micro_stage_name = _season_stage_name(stage_started)

	# 与 SeasonRefreshJob 一致：12 stages
	var done: bool = _stage >= 12
	if done:
		_round_active = false
		if generator.has_method("finish_season_refresh"):
			generator.finish_season_refresh(map, world_data, _season_idx)
		_stage = 0
		_stage_cursor = 0

	var elapsed_ms: float = (Time.get_ticks_usec() - t_start_us) / 1000.0
	var progress: float = 1.0 if done else float(_stage) / 12.0
	if micro_handled and not micro_done and map != null and map.cell_count() > 0:
		progress = (float(_stage) + clampf(float(_stage_cursor) / float(map.cell_count()), 0.0, 1.0)) / 12.0
	return {
		"done": done,
		"work_done": micro_work_done if micro_handled else 1,
		"elapsed_ms": elapsed_ms,
		"progress_ratio": progress,
		"stage": stage_started,
		"stage_name": micro_stage_name,
		"substage": "cursor_%d" % _stage_cursor,
		"path": "micro" if micro_handled else "stage",
		"cursor": _stage_cursor,
	}


func reset_progress() -> void:
	super.reset_progress()
	_stage = 0
	_stage_cursor = 0
	_round_active = false
	# B+ 路径残留 round handle 强制清理（generator 内部会 abort 掉 C++ 端 round_state）。
	if _b_plus_active and generator != null and generator.has_method("_abort_season_round_b_plus_safe"):
		generator._abort_season_round_b_plus_safe()
	_b_plus_active = false


func _season_stage_name(stage: int) -> String:
	match stage:
		0: return "stage_0_moisture"
		1: return "stage_1_rain_shadow"
		2: return "stage_2_redecide"
		3: return "stage_3_river"
		4: return "stage_4_veg_feedback"
		5: return "stage_5_shrubland"
		6: return "stage_6_mangrove"
		7: return "stage_7_glacier"
		8: return "stage_8_swamp"
		9: return "stage_9_sync"
		10: return "stage_10_atlas_queue"
		11: return "stage_11_feedback"
		_: return "stage_%d" % stage
