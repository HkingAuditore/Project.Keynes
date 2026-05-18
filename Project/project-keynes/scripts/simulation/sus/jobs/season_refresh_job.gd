extends "res://scripts/simulation/sus/sus_job.gd"
class_name SeasonRefreshJob

const SusPolicyScript = preload("res://scripts/simulation/sus/sus_policy.gd")

var generator = null
var map: MapData = null
var world: WorldData = null
var _stage: int = 0
var _stage_cursor: int = 0
var _season_idx: int = 0
var _round_active: bool = false

# ─── Periodic-driver (慢变量周期重算) ─────────────────────────────────────
# 旧设计：season_refresh 由 WorldClock.season_changed 信号触发，速度档 x20
#   时每 ~15 ticks 就排一次 round → 12 stages × 1 tick/stage = 12 ticks 工作
#   → 几乎 100% 占用主循环；
# 新设计："季节"在游戏世界里只是温度/降水/风的连续涌现表象，已由
#   refresh_climate_daily 每天连续推进；season_refresh 退化为"低频慢变量批量
#   重算器"——按真实 SUS tick 自驱，每 `period_ticks` tick 启动一个 round，
#   速度档无关，玩家观感无差异。
# 兼容开关：generator.use_legacy_season_signal == true 时退回旧路径（仍消费
#   has_pending_season_refresh），默认 false。
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
	world = p_world
	policy = SusPolicyScript.AlwaysPolicy.new()
	# 从 ClimateProfile 读 period_ticks（如配置）
	if p_generator != null and p_generator.has_method("_c"):
		var cp = p_generator._c()
		if cp != null and "season_refresh_period_ticks" in cp:
			period_ticks = max(1, int(cp.season_refresh_period_ticks))


func should_run(ctx: SusTickContext) -> bool:
	if generator == null or map == null or world == null:
		return false
	if _round_active:
		return true
	# 兼容开关：保留旧的"信号脉冲驱动"路径供回归对照
	var legacy_signal: bool = false
	if generator.has_method("_c"):
		var cp = generator._c()
		if cp != null and "season_refresh_legacy_signal" in cp:
			legacy_signal = bool(cp.season_refresh_legacy_signal)
	if legacy_signal:
		if not generator.has_method("has_pending_season_refresh"):
			return false
		return bool(generator.has_pending_season_refresh())
	# 新路径：周期自驱。每 period_ticks 启动一次 round，
	# 速度档 x1/x5/x20 都按"真实 tick"计数，玩家无感。
	_ticks_since_last_round += 1
	if _ticks_since_last_round < period_ticks:
		return false
	return true


func run_slice(ctx: SusTickContext) -> Dictionary:
	var t_start_us: int = Time.get_ticks_usec()
	if generator == null or map == null or world == null:
		return { "done": true, "work_done": 0, "elapsed_ms": 0.0, "progress_ratio": 1.0 }

	if not _round_active:
		# 新路径优先：周期自驱调用 begin_periodic_season_refresh，从 WorldClock
		# 取当前 season_index。legacy_signal 模式下走 begin_pending_season_refresh
		# 消费 pending flag（与旧行为完全一致）。
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

	var micro_handled: bool = false
	var micro_done: bool = false
	var micro_stage_name: String = ""
	var micro_work_done: int = 1
	var stage_started: int = _stage
	if generator.has_method("run_season_refresh_stage_micro"):
		var micro: Dictionary = generator.run_season_refresh_stage_micro(map, world, _season_idx, _stage, _stage_cursor)
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
		generator.run_season_refresh_stage(map, world, _season_idx, _stage)
		_stage += 1
		_stage_cursor = 0
	if micro_stage_name == "":
		micro_stage_name = _season_stage_name(stage_started)

	# 12 stages：moisture / rain_shadow / redecide / river / veg_fb / shrubland /
	# mangrove / glacier / swamp / sync_current / rebake_biome / consume_feedback。
	# 拆细后每 stage 上界 < 30ms（原 7-stage 时单 stage 可能 ~100ms）。
	var done: bool = _stage >= 12
	if done:
		_round_active = false
		if generator.has_method("finish_season_refresh"):
			generator.finish_season_refresh(map, world, _season_idx)
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
