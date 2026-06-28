extends DCSystem
class_name NativeDailySimJob

const SusPolicyScript = preload("res://scripts/simulation/sus/sus_policy.gd")

var generator = null
var map: MapData = null
var world: WorldData = null
var _did_run_last_tick: bool = false
var _native_round_active: bool = false
var _last_result: Dictionary = {}


func _init(p_generator, p_map: MapData, p_world: WorldData, p_stride: int = 1) -> void:
	generator = p_generator
	map = p_map
	world = p_world
	id = &"native_daily_sim"
	# Keep native daily after the retained ocean physical boundary (SLP/wind/ocean
	# current), but before visual uploads. Weather consumes the latest physical slots.
	priority = 210
	must_run = false
	use_job_should_run = true
	max_slices_per_tick = 1
	slice_budget_ms = 1.0
	starvation_threshold = 2
	policy = SusPolicyScript.StridePolicy.new(max(1, p_stride), 0)


func reset_run_flag() -> void:
	_did_run_last_tick = false


func did_run_last_tick() -> bool:
	return _did_run_last_tick


func last_result() -> Dictionary:
	return _last_result.duplicate(true)


func declare_reads() -> Array[StringName]:
	# Partial ACTIVE keeps season/ocean/visual boundary jobs registered. Declaring
	# the whole native graph here creates true-but-unusable cycles with those
	# retained systems; native graph dependencies are reported by C++ until the
	# graph becomes the sole owner of these slots.
	return []


func declare_writes() -> Array[StringName]:
	return []


func should_run(ctx: SusTickContext) -> bool:
	return generator != null \
			and generator.has_method("run_native_daily_slice_from_job") \
			and (_native_round_active or super.should_run(ctx))


func run_slice(ctx: SusTickContext) -> Dictionary:
	var t0: int = Time.get_ticks_usec()
	var res: Dictionary
	if generator.has_method("run_native_daily_slice_from_job"):
		res = generator.run_native_daily_slice_from_job(ctx, map, world)
	else:
		res = {
			"rc": -1,
			"done": true,
			"path": "gdext_native_daily_slice",
			"fail_stage": "missing_run_native_daily_slice_from_job",
			"fallback_reason": "missing_run_native_daily_slice_from_job",
		}
	_last_result = res.duplicate(true)
	_did_run_last_tick = int(res.get("rc", -1)) == 0
	_native_round_active = _did_run_last_tick and not bool(res.get("done", true))
	var elapsed_ms: float = float(res.get("wrapper_wall_ms", (Time.get_ticks_usec() - t0) / 1000.0))
	var breakdown: Dictionary = res.get("breakdown", {})
	var published_slots = res.get("published_slots", [])
	var published_slot_count: int = 0
	if published_slots is Array or published_slots is PackedStringArray:
		published_slot_count = published_slots.size()
	return {
		"done": bool(res.get("done", true)),
		"work_done": 1 if _did_run_last_tick else 0,
		"elapsed_ms": elapsed_ms,
		"progress_ratio": float(res.get("progress_ratio", 1.0)),
		"stage_name": str(res.get("stage_name", "native_daily")),
		"substage": str(res.get("substage", "ok" if _did_run_last_tick else str(res.get("fail_stage", "failed")))),
		"path": str(res.get("path", "gdext_native_daily_slice")),
		"fail_stage": str(res.get("fail_stage", "")),
		"fallback_reason": str(res.get("fallback_reason", res.get("reason", ""))),
		"native_ms": float(res.get("native_ms", breakdown.get("native_ms", 0.0))),
		"round_native_ms": float(res.get("round_native_ms", breakdown.get("round_native_ms", 0.0))),
		"compute_ms": float(res.get("compute_ms", breakdown.get("compute_ms", 0.0))),
		"refresh_ms": float(res.get("refresh_ms", breakdown.get("refresh_ms", 0.0))),
		"flush_ms": float(res.get("flush_ms", breakdown.get("flush_ms", 0.0))),
		"bundle_ms": float(res.get("bundle_ms", breakdown.get("bundle_ms", 0.0))),
		"native_call_ms": float(res.get("native_call_ms", breakdown.get("native_call_ms", 0.0))),
		"apply_ms": float(res.get("apply_ms", breakdown.get("apply_ms", 0.0))),
		"wrapper_wall_ms": float(res.get("wrapper_wall_ms", elapsed_ms)),
		"published_slots": published_slots,
		"published_to_slot": published_slot_count > 0,
		"dirty_cells": int(res.get("dirty_cells", breakdown.get("dirty_cells", 0))),
		"visual_dirty_intents": res.get("visual_dirty_intents", []),
		"graph_coverage_complete": bool(res.get("graph_coverage_complete", false)),
		"graph_coverage_state": str(res.get("graph_coverage_state", breakdown.get("graph_coverage_state", ""))),
		"retained_gdscript_authority": res.get("retained_gdscript_authority", []),
		"authority_report": res.get("authority_report", breakdown.get("authority_report", {})),
		"authority_blockers": res.get("authority_blockers", breakdown.get("authority_blockers", [])),
		"native_state_snapshot": res.get("native_state_snapshot", breakdown.get("native_state_snapshot", {})),
		"native_daily_report": res,
	}


func reset_progress() -> void:
	super.reset_progress()
	_did_run_last_tick = false
	_native_round_active = false
	_last_result.clear()
