extends "res://scripts/simulation/sus/sus_job.gd"
class_name OceanCurrentsJob

## OceanCurrentsJob — slices the ocean currents + upwelling bake across many
## days so no single day_changed tick takes the legacy ~1000ms hit.
##
## Driven by: SUS daily tick (sourced from main.gd._on_day_changed).
## Strategy:  ContinuousSlicedPolicy(period_ticks, slice_count). Each slice
##            bakes ⌈total_pixels / slice_count⌉ pixels into the baker's
##            pending double-buffer. After the last slice the buffers are
##            atomically committed to world_data and per-cell ocean current
##            samples are recomputed.

const MapBakerScript = preload("res://scripts/rendering/map_baker.gd")
const SusJobScript = preload("res://scripts/simulation/sus/sus_job.gd")
const SusPolicyScript = preload("res://scripts/simulation/sus/sus_policy.gd")

# External references — wired up by MapGenerator at registration time.
var baker: MapBakerScript = null
var map: MapData = null
var world: WorldData = null
var cfg: MapConfig = null
var hex_size: float = 0.0
# Optional: callback to invoke on commit so MapGenerator can refill per-cell
# samples (avoids a hard import dependency from this file to MapGenerator).
var on_commit: Callable = Callable()
# Optional: phase getter from world_clock; if not set, falls back to ctx.season_phase.
var season_phase_getter: Callable = Callable()

# Internal slice cursor and locked phase for the in-flight bake round.
var _next_pixel_idx: int = 0
var _total_pixels: int = 0
# Locked at the start of each round so mid-round slices all use the same
# season_phase (avoids tiny per-slice drift).
var _phase_locked: float = 0.0
# False until the very first slice of the very first round runs (we need to
# know when to lock the phase fresh).
var _round_active: bool = false

# Tunables — sourced from ClimateProfile at registration time, but stored
# here so policy and job stay in sync.
var period_ticks: int = 30
var slice_count: int = 10


func _init(p_baker: MapBakerScript, p_map: MapData, p_world: WorldData,
		p_cfg: MapConfig, p_hex_size: float,
		p_period_ticks: int, p_slice_count: int) -> void:
	id = &"ocean_currents"
	priority = 200  # runs after refresh_climate_daily (100) / weather (150)
	slice_budget_ms = 4.0
	# Daily-sim perf bugfix：洋流切片每天最多跑 1/slice_count 的工作量（已切片化），
	# 必须坚持推进否则一年也烘不完。绕过 frame_budget 守卫，避免被 climate Job
	# 大预算饥饿掉。
	must_run = true
	baker = p_baker
	map = p_map
	world = p_world
	cfg = p_cfg
	hex_size = p_hex_size
	period_ticks = max(1, p_period_ticks)
	slice_count = max(1, p_slice_count)
	policy = SusPolicyScript.ContinuousSlicedPolicy.new(period_ticks, slice_count)


## Total pixels for the current world. Cached at round start.
func _total_pixels_for(p_world: WorldData) -> int:
	if p_world == null:
		return 0
	return p_world.derived_size.x * p_world.derived_size.y


## Pixel quota per slice — ceil(total / slice_count).
func _pixels_per_slice() -> int:
	return int(ceil(float(_total_pixels) / float(max(1, slice_count))))


func reset_progress() -> void:
	super.reset_progress()
	_next_pixel_idx = 0
	_total_pixels = 0
	_round_active = false
	if baker != null and baker.has_method("discard_ocean_buffers"):
		baker.discard_ocean_buffers()


func should_run(ctx: SusTickContext) -> bool:
	# Guard against missing dependencies (e.g. before bake_world finishes).
	if baker == null or world == null or map == null or cfg == null:
		return false
	# Always defer to policy, even when a round is in flight: that keeps the
	# 'one slice every ticks_per_slice ticks' cadence intact (e.g. 1 slice
	# every 3 days). Drift of mid-round phase is bounded by the locked
	# _phase_locked, so spreading slices across the full period_ticks window
	# is exactly the desired behavior.
	return super.should_run(ctx)


func run_slice(ctx: SusTickContext) -> Dictionary:
	var t_start_us: int = Time.get_ticks_usec()
	if baker == null or world == null or map == null:
		return { "done": true, "work_done": 0, "elapsed_ms": 0.0 }

	# Begin a new round: lock total pixels and phase.
	if not _round_active:
		_total_pixels = _total_pixels_for(world)
		if _total_pixels <= 0:
			return { "done": true, "work_done": 0, "elapsed_ms": 0.0 }
		_next_pixel_idx = 0
		if season_phase_getter.is_valid():
			_phase_locked = float(season_phase_getter.call())
		else:
			_phase_locked = ctx.season_phase
		_round_active = true

	var pps: int = _pixels_per_slice()
	var s: int = _next_pixel_idx
	var e: int = mini(_total_pixels, s + pps)
	# Bake slice for both currents and upwelling using the same idx range.
	# Both share the locked phase to avoid intra-round drift.
	baker.bake_ocean_currents_slice(map, world, hex_size, cfg, _phase_locked, s, e)
	baker.bake_ocean_upwelling_slice(map, world, hex_size, cfg, _phase_locked, s, e)
	_next_pixel_idx = e

	var done: bool = (_next_pixel_idx >= _total_pixels)
	if done:
		baker.commit_ocean_buffers(world)
		if on_commit.is_valid():
			on_commit.call()
		_round_active = false
		_next_pixel_idx = 0

	var elapsed_ms: float = (Time.get_ticks_usec() - t_start_us) / 1000.0
	var progress: float = 0.0
	if _total_pixels > 0:
		progress = float(_next_pixel_idx) / float(_total_pixels) if not done else 1.0
	return {
		"done": done,
		"work_done": e - s,
		"elapsed_ms": elapsed_ms,
		"progress_ratio": progress,
	}


## Allow MapGenerator to retune the policy on the fly (e.g. after climate
## profile reload). Re-creates the underlying ContinuousSlicedPolicy.
func reconfigure(p_period_ticks: int, p_slice_count: int) -> void:
	period_ticks = max(1, p_period_ticks)
	slice_count = max(1, p_slice_count)
	policy = SusPolicyScript.ContinuousSlicedPolicy.new(period_ticks, slice_count)
	# A round mid-flight stays as-is — only future rounds use the new pace.
