extends "res://scripts/simulation/sus/sus_job.gd"
class_name WeatherRefreshJob

## WeatherRefreshJob — wraps the daily weather advance + feedback chain
## (MapGenerator.refresh_daily) under a StridePolicy. Single-slice per tick.
##
## Driven by: SUS daily tick (sourced from main.gd._on_day_changed).
## Strategy:  StridePolicy(stride). x1→1, x5→2, x20→4 mapped from speed by
##            main.gd._on_speed_changed (preserves legacy behavior).
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


func _init(p_generator, p_map: MapData, p_world: WorldData,
		p_season_index_getter: Callable,
		p_season_phase_getter: Callable,
		p_climate_anomaly_getter: Callable,
		p_stride: int) -> void:
	id = &"weather_refresh"
	priority = 150  # after refresh_climate_daily (100), before ocean_currents (200)
	slice_budget_ms = 8.0
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
	depends_on = [&"refresh_climate_daily"]


func should_run(ctx: SusTickContext) -> bool:
	if generator == null or map == null or world == null:
		return false
	return super.should_run(ctx)


func run_slice(ctx: SusTickContext) -> Dictionary:
	var t_start_us: int = Time.get_ticks_usec()
	if generator == null or map == null or world == null:
		ran_this_tick = false
		return { "done": true, "work_done": 0, "elapsed_ms": 0.0 }

	var season_idx: int = 0
	if season_index_getter.is_valid():
		season_idx = int(season_index_getter.call())
	var season_phase: float = ctx.season_phase
	if season_phase_getter.is_valid():
		season_phase = float(season_phase_getter.call())
	var anomaly: float = 0.0
	if climate_anomaly_getter.is_valid():
		anomaly = float(climate_anomaly_getter.call())

	# generator 是 untyped（避免循环 preload），其返回值被视为 Variant，
	# 这里显式声明 fronts 类型以满足 GDScript 强类型推断。
	var fronts: Array[WeatherFront] = generator.refresh_daily(map, world, season_idx, anomaly, season_phase)
	# Defensive copy: refresh_daily may return its internal `_last_active_fronts`
	# directly (on the legacy internal-stride skip path which is now dead, but
	# keep the contract robust).
	_last_fronts = fronts
	ran_this_tick = true

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


## Called by SUS.tick() at the *start* of each tick wouldn't work (we'd lose
## the prior tick's value). Instead main.gd resets this via reset_run_flag()
## before sus_tick_daily — see MapGenerator.sus_tick_daily for details.
func reset_run_flag() -> void:
	ran_this_tick = false


## Allow MapGenerator to retune the stride on the fly (speed_changed callback).
func reconfigure(p_stride: int) -> void:
	stride = max(1, p_stride)
	policy = SusPolicyScript.StridePolicy.new(stride, 0)
