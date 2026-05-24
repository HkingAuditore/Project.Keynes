extends DCSystem
class_name SeaIceDailySystem

## Independent sea-ice daily system.
##
## This runs the existing MapGenerator sea_ice climate pass through the shared
## sliced state machine, but gives sea ice its own StridePolicy instead of
## waiting behind the full refresh_climate_daily round.

const SusPolicyScript = preload("res://scripts/simulation/sus/sus_policy.gd")

var generator = null
var map: MapData = null
var season_phase_getter: Callable = Callable()
var stride: int = 1

var _round_active: bool = false
var _phase_locked: float = 0.0
var ran_this_tick: bool = false
var _last_slice_elapsed_ms: float = 0.0


func _init(p_generator, p_map: MapData, p_phase_getter: Callable, p_stride: int) -> void:
	id = &"sea_ice_daily"
	priority = 115
	slice_budget_ms = 0.55
	max_slices_per_tick = 1
	must_run = false
	generator = p_generator
	map = p_map
	season_phase_getter = p_phase_getter
	stride = max(1, p_stride)
	policy = SusPolicyScript.StridePolicy.new(stride, 0)


func declare_reads() -> Array[StringName]:
	return [
		DCComponentIds.CELL_TEMP,
		DCComponentIds.CELL_TERRAIN,
		DCComponentIds.CELL_BASE_TERRAIN,
		DCComponentIds.CELL_SEA_ICE_FRAC,
		DCComponentIds.CELL_TEMPERATURE_TRANSPORT_ANOMALY,
		DCComponentIds.CELL_UPWELLING_STRENGTH,
	]


func declare_writes() -> Array[StringName]:
	# Terrain flips are committed by the shared sea-ice state machine as a
	# render/atlas side effect. Declaring CELL_TERRAIN here would create a false
	# cycle with ClimateDailySystem, which reads terrain while producing temp.
	return [
		DCComponentIds.CELL_SEA_ICE_FRAC,
		DCComponentIds.CELL_CLIMATE_DIRTY,
	]


func declare_pools() -> Array[StringName]:
	return [DCComponentIds.POOL_CELLS]


func feature_flag() -> StringName:
	return &""


func should_run(ctx: SusTickContext) -> bool:
	if generator == null or map == null:
		return false
	if not _enabled_from_profile():
		if _round_active and generator.has_method("abort_climate_pass"):
			generator.abort_climate_pass("sea_ice", "sea_ice_daily_disabled")
		_round_active = false
		return false
	if _round_active:
		return true
	return super.should_run(ctx)


func run_slice(ctx: SusTickContext) -> Dictionary:
	if generator == null or map == null:
		return { "done": true, "work_done": 0, "elapsed_ms": 0.0, "progress_ratio": 1.0 }
	if not _enabled_from_profile():
		_round_active = false
		return { "done": true, "work_done": 0, "elapsed_ms": 0.0, "progress_ratio": 1.0 }
	if not generator.has_method("run_climate_pass_slice"):
		return { "done": true, "work_done": 0, "elapsed_ms": 0.0, "progress_ratio": 1.0 }

	if not _round_active:
		if season_phase_getter.is_valid():
			_phase_locked = float(season_phase_getter.call())
		else:
			_phase_locked = ctx.season_phase
		_round_active = true

	var t_us0: int = Time.get_ticks_usec()
	var result: Dictionary = generator.run_climate_pass_slice("sea_ice", map, _phase_locked)
	var elapsed_ms: float = (Time.get_ticks_usec() - t_us0) / 1000.0
	if result.has("elapsed_ms"):
		elapsed_ms = float(result.get("elapsed_ms", elapsed_ms))

	var done: bool = bool(result.get("done", true))
	_round_active = not done
	ran_this_tick = true
	_last_slice_elapsed_ms = elapsed_ms

	var stage: String = str(result.get("stage", result.get("stage_name", "sea_ice")))
	var progress: float = 1.0 if done else 0.0
	if result.has("cursor_remaining") and result.has("budget_cells"):
		var remaining: int = int(result.get("cursor_remaining", 0))
		var budget: int = max(1, int(result.get("budget_cells", 1)))
		progress = 1.0 / float(max(1, int(ceil(float(remaining + budget) / float(budget)))))

	return {
		"done": done,
		"work_done": map.cell_count() if done else 0,
		"elapsed_ms": elapsed_ms,
		"progress_ratio": 1.0 if done else progress,
		"stage_name": "sea_ice",
		"substage": stage,
		"path": str(result.get("path", "climate_chunk_api")),
		"processed_cells": int(result.get("processed_cells", 0)),
		"cursor_start": int(result.get("cursor_start", -1)),
		"cursor_end": int(result.get("cursor_end", -1)),
		"budget_interrupted": bool(result.get("budget_interrupted", not done)),
		"status": str(result.get("status", "done" if done else "continue")),
	}


func reset_progress() -> void:
	super.reset_progress()
	if generator != null and generator.has_method("abort_climate_pass"):
		generator.abort_climate_pass("sea_ice", "sea_ice_daily_reset")
	_round_active = false
	_phase_locked = 0.0
	ran_this_tick = false
	_last_slice_elapsed_ms = 0.0


func reconfigure(p_stride: int) -> void:
	stride = max(1, p_stride)
	policy = SusPolicyScript.StridePolicy.new(stride, 0)


func _enabled_from_profile() -> bool:
	if generator == null or not generator.has_method("_c"):
		return true
	var cp = generator._c()
	return cp == null \
			or cp.get("sea_ice_independent_system_enabled") == null \
			or bool(cp.sea_ice_independent_system_enabled)


func reset_run_flag() -> void:
	ran_this_tick = false
	_last_slice_elapsed_ms = 0.0


func did_run_last_tick() -> bool:
	return ran_this_tick


func last_slice_elapsed_ms() -> float:
	return _last_slice_elapsed_ms
