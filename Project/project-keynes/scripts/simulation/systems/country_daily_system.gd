extends DCSystem
class_name CountryDailySystem

const SusPolicyScript = preload("res://scripts/simulation/sus/sus_policy.gd")

var facade = null
var world_clock: WorldClock = null
var generator = null
var _last_report: Dictionary = {}

func _init(p_facade, p_world_clock: WorldClock = null, p_generator = null) -> void:
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
	generator = p_generator

func feature_flag() -> StringName:
	return &""

func declare_writes() -> Array[StringName]:
	return [DCComponentIds.CELL_COUNTRY_SLOT]

func should_run(ctx: SusTickContext) -> bool:
	if generator != null and generator.has_method("runtime_graph_active") \
			and bool(generator.runtime_graph_active()):
		return false
	return facade != null and facade.is_configured() and \
		bool(facade.world_ext().country_should_run(ctx.day_index))


func is_deadline_critical(ctx: SusTickContext) -> bool:
	# Country commands effective today must commit before the economy freezes
	# its country snapshot for the same day.
	return ctx != null and should_run(ctx)

func tick(ctx) -> Dictionary:
	var started_us := Time.get_ticks_usec()
	if generator != null and generator.has_method("runtime_graph_active") \
			and bool(generator.runtime_graph_active()):
		return {"done": true, "elapsed_ms": 0.0,
			"stage_name": "country_owned_by_runtime_graph",
			"path": "native_runtime_graph"}
	if facade == null or not facade.is_configured():
		return {"done": true, "elapsed_ms": 0.0, "stage_name": "country_unavailable"}
	var result: Dictionary = facade.world_ext().run_country_slice({
		"day_index": int(ctx.day_index) if ctx != null else 0,
		"tick_index": int(ctx.tick_index) if ctx != null else 0,
	})
	var effect_ack: Dictionary = {}
	if facade.world_ext().has_method("ack_effect_native_country"):
		effect_ack = facade.world_ext().ack_effect_native_country()
	# native 每 slice 返回新分配的 Dictionary，跨过这个边界后不再被 native 改写。
	# 深拷贝等于把整份报告重建一遍，而 last_report() 出口本来就自带拷贝。
	_last_report = result
	var dispatch_started_us := Time.get_ticks_usec()
	facade.dispatch_committed_events(result)
	result["event_dispatch_ms"] = \
		float(Time.get_ticks_usec() - dispatch_started_us) / 1000.0
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
		"effect_native_acked": int(effect_ack.get("acknowledged", 0)),
	}

func last_report() -> Dictionary:
	return _last_report.duplicate(true)

func reset_progress() -> void:
	super.reset_progress()
	_last_report.clear()
	if world_clock != null and world_clock.has_method("request_simulation_backpressure"):
		world_clock.request_simulation_backpressure(&"country_day_barrier", false)
