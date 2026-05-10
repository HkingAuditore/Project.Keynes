extends "res://scripts/simulation/sus/sus_job.gd"
class_name WeatherRefreshJob

## WeatherRefreshJob — wraps the daily weather advance + feedback chain
## (MapGenerator.refresh_daily) under a StridePolicy. Single-slice per tick.
##
## Driven by: SUS daily tick (sourced from main.gd._on_day_changed).
## Strategy:  StridePolicy(stride). x1→1, x5→4, x20→8 mapped from speed by
##            main.gd._on_speed_changed.
##
## Why a Job instead of a direct call:
##   1. Centralizes stride configuration in SUS (single source of truth).
##   2. Allows future replacement with sliced strategies (e.g. spread the
##      transpiration / albedo passes across multiple ticks) without touching
##      the dispatcher.
##   3. Captures the "active fronts" output via job-local snapshot so the
##      renderer can poll it after SUS.tick() returns.
##
## Note on stride semantics: Legacy refresh_daily had its own internal stride
## counter (`_refresh_daily_call_index`) that returned `_last_active_fronts`
## on skip days. Now SUS.policy gates the call entirely; on gated days the
## Job is not invoked at all and the renderer keeps polling the cached
## fronts from the last unsuppressed run. Behavior equivalent.

const SusPolicyScript = preload("res://scripts/simulation/sus/sus_policy.gd")

# External references — wired up by MapGenerator at registration time.
var generator = null  # MapGenerator (untyped to avoid circular preload)
var map: MapData = null
var world: WorldData = null
# WorldClock-bound getters; nil-safe at call sites.
var season_index_getter: Callable = Callable()
var season_phase_getter: Callable = Callable()
var climate_anomaly_getter: Callable = Callable()

# Mirrored stride.
var stride: int = 1
# Cached output from the most recent successful run; renderer polls it.
var _last_fronts: Array[WeatherFront] = [] as Array[WeatherFront]
# Set true on every tick where run_slice actually fired (i.e. policy gate
# passed). Used by main.gd to decide whether to refresh per-cell UI lines.
var ran_this_tick: bool = false
# Drift-fix（2026-05-10）：fronts 数据是否真的在本 tick 更新。
# 历史背景：原 2-tick split 下 ran_this_tick 在 stage_a/stage_b 都为真，但
# _last_fronts 只在 stage_b 翻新——所以引入这个标志区分"slice 跑了"与"fronts 真变了"，
# 以避免在 stage_a tick 让 weather_layer 收到一份未变的 fronts → blend reset → 云冻结。
# Frequency-fix（2026-05-10）：现在 stage_a/stage_b 合并在同 slice 跑完，
# fronts_changed 与 ran_this_tick 同步置位。保留这个 API 以便：
#   1) main.gd 与 weather_layer 接口语义清晰（"fronts 是否真变了"独立可查）
#   2) 将来如重新引入切片时不必再翻这层结构
var _fronts_changed_this_tick: bool = false

# Frequency-fix（2026-05-10）：原 2-tick split（stage_a 一 tick，stage_b 下一
# tick）被 slice_budget_ms=8.0 强制——但 stage_a 本身就 50-60ms 远超 budget，
# 所以单 slice 内一定 break，stage_b 必须等下一 tick。结果是：
#   stride=1 下天气每 2 游戏日才完整推进一次，1× 速度下 = 2 秒一次
#   stride=2（5×）= 4 游戏日一次；stride=4（20×）= 8 游戏日一次
# 玩家在加速档下会感觉"几十天才更新一次天气"。
#
# 现在 stage_a + stage_b 合并在同一 slice 内跑完，run_slice 一次 return done=true。
# 单次 tick 总耗时 55-75ms（vs 之前 50-60ms + 5-15ms 分两 tick），峰值略升但
# 总吞吐相同；stride=1 下天气真正每 1 游戏日推进一次，玩家可见的更新频率翻倍。
# _round_active / _round_stage / _round_fronts 保留为 no-op 状态字段，仅
# reset_progress 时清理，避免破坏老快照逻辑（reset_progress 被外部调）。
var _round_active: bool = false
var _round_stage: int = 0
var _round_fronts: Array[WeatherFront] = [] as Array[WeatherFront]


func _init(p_generator, p_map: MapData, p_world: WorldData,
		p_season_index_getter: Callable,
		p_season_phase_getter: Callable,
		p_climate_anomaly_getter: Callable,
		p_stride: int) -> void:
	id = &"weather_refresh"
	priority = 150  # after refresh_climate_daily (100), before ocean_currents (200)
	# Frequency-fix：合并 stage_a (~50-60ms) + stage_b (~5-15ms) 后单 slice 实测 55-75ms。
	# slice_budget_ms 仅在 done=false 时生效；现在永远 done=true 所以不影响调度，但
	# 保持数值真实以避免误导读者以为 weather 是个 8ms 的轻量 Job。
	slice_budget_ms = 80.0
	# Daily-sim perf bugfix：weather 推进必须每日发生（受 stride 节流），否则
	# 全图天气前沿冻结、降水/温度异常驱动失效。绕过 frame_budget 守卫，避免
	# 因 climate Job 超预算而被 frame_budget_exhausted 全数跳过。
	must_run = true
	generator = p_generator
	map = p_map
	world = p_world
	season_index_getter = p_season_index_getter
	season_phase_getter = p_season_phase_getter
	climate_anomaly_getter = p_climate_anomaly_getter
	stride = max(1, p_stride)
	policy = SusPolicyScript.StridePolicy.new(stride, 0)
	# Drift-fix（2026-05-10）：原 depends_on=[refresh_climate_daily] 是导致云"几十天才动一次"
	# 的真凶。RefreshClimateDailyJob 是 6-sub-pass 切片（每 tick 一个 sub-pass，整 round 6 游戏日），
	# round 期间 in_flight=true → SUS 把 weather 标 dep_pending 并 skip，所以 weather 实际上每
	# 6+ 游戏日才能跑一次。诊断日志里看到 snap_interval=6-16s 完全对应这个 cadence。
	#
	# 取消硬依赖：weather 读的是 cell.temperature/moisture 等慢层 baseline，即使读到上一日的
	# 值（climate round 还在中间 sub-pass，未来字段尚未写入），1 天差异在天气/降水驱动里
	# 完全不可察——慢层本身的日变化就远小于 weather 自己的 stochastic 项。
	# 副作用：weather 现在每 game day 都跑（stride=1 下），云能流畅平移，与玩家时间感知对齐。
	depends_on = []


func should_run(ctx: SusTickContext) -> bool:
	if generator == null or map == null or world == null:
		return false
	return super.should_run(ctx)


func run_slice(ctx: SusTickContext) -> Dictionary:
	var t_start_us: int = Time.get_ticks_usec()
	if generator == null or map == null or world == null:
		ran_this_tick = false
		return { "done": true, "work_done": 0, "elapsed_ms": 0.0 }

	# Frequency-fix（2026-05-10）：合并 stage_a + stage_b 在同 tick 跑完。
	# 详见文件顶部 Frequency-fix 注释。原 2-tick split 在 1× 速度下让天气每 2 游戏日
	# 才推进一次，玩家可见频率减半；高速档 stride×2 后差距更大，所以"感觉几十天才更新一次"。
	var season_idx: int = 0
	if season_index_getter.is_valid():
		season_idx = int(season_index_getter.call())
	var season_phase: float = ctx.season_phase
	if season_phase_getter.is_valid():
		season_phase = float(season_phase_getter.call())
	var anomaly: float = 0.0
	if climate_anomaly_getter.is_valid():
		anomaly = float(climate_anomaly_getter.call())

	var fronts: Array[WeatherFront] = generator.refresh_daily_stage_a(map, world, season_idx, anomaly, season_phase)
	generator.refresh_daily_stage_b(map, world)

	_last_fronts = fronts
	_round_fronts = fronts
	# 合并模式不再有"半成品 round"——_round_active 始终为 false。
	_round_active = false
	_round_stage = 0
	ran_this_tick = true
	# 每次 run_slice 都把 _last_fronts 翻新，所以 fronts_changed 与 ran_this_tick 同步。
	_fronts_changed_this_tick = true

	var elapsed_ms: float = (Time.get_ticks_usec() - t_start_us) / 1000.0
	return {
		"done": true,
		"work_done": fronts.size(),
		"elapsed_ms": elapsed_ms,
		"progress_ratio": 1.0,
	}


## Read-only accessor for main.gd; cheap, no SUS state mutation.
func last_fronts() -> Array[WeatherFront]:
	return _last_fronts


## Was run_slice invoked on the most recent SUS.tick()? Used by main.gd to
## skip per-cell UI line refresh on stride-gated days (matches legacy
## `was_skipped_day` UX).
func did_run_last_tick() -> bool:
	return ran_this_tick


## Drift-fix（2026-05-10）：本 tick 是否真的翻转了 _last_fronts？
## main.gd 用它 gate set_weather_fronts，避免冗余推送触发 weather_layer 的
## blend reset → 云冻结。Frequency-fix 后 stage_a/stage_b 合并，与 ran_this_tick 同步置位。
func did_change_fronts_last_tick() -> bool:
	return _fronts_changed_this_tick


## Called by SUS.tick() at the *start* of each tick wouldn't work (we'd lose
## the prior tick's value). Instead main.gd resets this via reset_run_flag()
## before sus_tick_daily — see MapGenerator.sus_tick_daily for details.
func reset_run_flag() -> void:
	ran_this_tick = false
	# Drift-fix：fronts_changed 也每 tick 入场前清零；run_slice 跑完会重新置位。
	_fronts_changed_this_tick = false


## Allow MapGenerator to retune the stride on the fly (speed_changed callback).
func reconfigure(p_stride: int) -> void:
	stride = max(1, p_stride)
	policy = SusPolicyScript.StridePolicy.new(stride, 0)


## Map regenerate / SUS-wide reset：清状态字段。
## Frequency-fix 后已无 round 半成品概念，但保留接口与字段一致性。
func reset_progress() -> void:
	super.reset_progress()
	_round_active = false
	_round_stage = 0
	_round_fronts = [] as Array[WeatherFront]
	_fronts_changed_this_tick = false
