extends DCSystem
class_name CountryDailySystem

const SusPolicyScript = preload("res://scripts/simulation/sus/sus_policy.gd")

var facade = null
var world_clock: WorldClock = null
var _last_report: Dictionary = {}

func _init(p_facade, p_world_clock: WorldClock = null) -> void:
	id = &"country_daily"
	priority = 255
	must_run = false
	max_slices_per_tick = 1
	use_job_should_run = true
	use_job_deadline_critical = true
	starvation_threshold = 2
	slice_budget_ms = 0.8
	policy = SusPolicyScript.AlwaysPolicy.new()
	facade = p_facade
	world_clock = p_world_clock

func feature_flag() -> StringName:
	return &""

func declare_writes() -> Array[StringName]:
	return [DCComponentIds.CELL_COUNTRY_SLOT]

func should_run(ctx: SusTickContext) -> bool:
	return facade != null and facade.is_configured() and \
		bool(facade.world_ext().country_should_run(ctx.day_index))


func is_deadline_critical(ctx: SusTickContext) -> bool:
	# Country commands effective today must commit before the economy freezes
	# its country snapshot for the same day.
	return ctx != null and should_run(ctx)

func tick(ctx) -> Dictionary:
	var started_us := Time.get_ticks_usec()
	if facade == null or not facade.is_configured():
		return {"done": true, "elapsed_ms": 0.0, "stage_name": "country_unavailable"}
	var result: Dictionary = facade.world_ext().run_country_slice({
		"day_index": int(ctx.day_index) if ctx != null else 0,
		"tick_index": int(ctx.tick_index) if ctx != null else 0,
	})
	_last_report = result.duplicate(true)
	facade.dispatch_committed_events(result)
	var barrier := bool(result.get("country_day_barrier", false))
	if world_clock != null and world_clock.has_method("request_simulation_backpressure"):
		world_clock.request_simulation_backpressure(&"country_day_barrier", barrier)
	return {
		"done": bool(result.get("done", true)),
		"work_done": int(result.get("changed_cells", 0)) + int(result.get("changed_countries", 0)),
		"elapsed_ms": float(Time.get_ticks_usec() - started_us) / 1000.0,
		"progress_ratio": 1.0 if bool(result.get("done", true)) else 0.0,
		"stage_name": String(result.get("stage", "country_daily")),
		"path": String(result.get("path", "COUNTRY_GRAPH")),
		"changed_cells": int(result.get("changed_cells", 0)),
		"changed_countries": int(result.get("changed_countries", 0)),
		"published_to_slot": bool(result.get("published_to_slot", false)),
	}

func last_report() -> Dictionary:
	return _last_report.duplicate(true)

func reset_progress() -> void:
	super.reset_progress()
	_last_report.clear()
	if world_clock != null and world_clock.has_method("request_simulation_backpressure"):
		world_clock.request_simulation_backpressure(&"country_day_barrier", false)
