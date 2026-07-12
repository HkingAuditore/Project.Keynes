extends DCSystem
class_name EconomyDailySystem

const SusPolicyScript = preload("res://scripts/simulation/sus/sus_policy.gd")
const ResourceRegistryScript = preload("res://scripts/data/resource_profile_registry.gd")

var facade = null
var world_clock: WorldClock = null
var _last_report: Dictionary = {}
var _fatal_reported: bool = false

func _init(p_facade, p_world_clock: WorldClock = null) -> void:
	id = &"economy_daily"
	priority = 260
	must_run = false
	max_slices_per_tick = 1
	use_job_should_run = true
	starvation_threshold = 2
	slice_budget_ms = 0.8
	policy = SusPolicyScript.AlwaysPolicy.new()
	facade = p_facade
	world_clock = p_world_clock

func feature_flag() -> StringName:
	return &""

func declare_reads() -> Array[StringName]:
	var reads: Array[StringName] = [
		DCComponentIds.CELL_TEMP,
		DCComponentIds.CELL_MOISTURE,
		DCComponentIds.CELL_SNOW_COVER,
		DCComponentIds.CELL_WEATHER_INTENSITY,
		DCComponentIds.CELL_ELEVATION,
		DCComponentIds.CELL_TERRAIN,
		DCComponentIds.CELL_LANDFORM,
		DCComponentIds.CELL_VEGETATION,
		DCComponentIds.CELL_IS_WATER,
		DCComponentIds.CELL_HAS_RIVER,
	]
	for profile in ResourceRegistryScript.ordered():
		reads.append(profile.reserve_component)
	return reads

func should_run(ctx: SusTickContext) -> bool:
	if facade == null or not facade.is_configured():
		return false
	var ext: Object = facade.world_ext()
	return ext != null and ext.has_method("economy_should_run") \
		and bool(ext.economy_should_run(ctx.day_index))

func tick(ctx) -> Dictionary:
	var started_us := Time.get_ticks_usec()
	if facade == null or not facade.is_configured():
		return {"done": true, "work_done": 0, "elapsed_ms": 0.0, "stage_name": "economy_unavailable"}
	var native_ctx := {
		"day_index": int(ctx.day_index) if ctx != null else 0,
		"tick_index": int(ctx.tick_index) if ctx != null else 0,
		"speed_scale": float(ctx.speed_scale) if ctx != null else 1.0,
	}
	var ext: Object = facade.world_ext()
	var result: Dictionary = ext.run_economy_slice(native_ctx)
	_last_report = result.duplicate(true)
	if facade.has_method("dispatch_committed_events"):
		facade.dispatch_committed_events(result)
	var over_budget := bool(result.get("commit_over_budget", false))
	# A multi-day frozen cycle is expected to remain in-flight while the world
	# advances. Only stop the calendar at its settlement deadline (or on fatal),
	# then use real-frame continuation pulses to finish any missed slices.
	var commit_due := bool(result.get("commit_due", false))
	var day_barrier := bool(result.get("fatal", false)) or (
		not bool(result.get("done", true)) and commit_due)
	if world_clock != null and world_clock.has_method("request_simulation_backpressure"):
		world_clock.request_simulation_backpressure(&"economy", over_budget)
		world_clock.request_simulation_backpressure(&"economy_day_barrier", day_barrier)
	if bool(result.get("fatal", false)) and not _fatal_reported:
		_fatal_reported = true
		push_error("[economy_daily] native economy paused: %s" % String(result.get("fatal_reason", "unknown")))
	return {
		"done": bool(result.get("done", true)),
		"work_done": int(result.get("work_done", 0)),
		"elapsed_ms": float(Time.get_ticks_usec() - started_us) / 1000.0,
		"progress_ratio": float(result.get("progress_q16", 65535)) / 65536.0,
		"stage_name": String(result.get("stage", "economy_daily")),
		"path": String(result.get("path", "ECONOMY_GRAPH")),
		"cursor_start": int(result.get("cursor_start", 0)),
		"cursor_end": int(result.get("cursor_end", 0)),
		"processed_cells": int(result.get("processed_cells", 0)),
		"processed_cohorts": int(result.get("processed_cohorts", 0)),
		"processed_rules": int(result.get("processed_rules", 0)),
		"commit_over_budget": over_budget,
		"commit_due": commit_due,
		"market_cycle_days": int(result.get("market_cycle_days", 1)),
		"fatal": bool(result.get("fatal", false)),
	}

func last_report() -> Dictionary:
	return _last_report.duplicate(true)

func reset_progress() -> void:
	super.reset_progress()
	_last_report.clear()
	_fatal_reported = false
	if world_clock != null and world_clock.has_method("request_simulation_backpressure"):
		world_clock.request_simulation_backpressure(&"economy", false)
		world_clock.request_simulation_backpressure(&"economy_day_barrier", false)
