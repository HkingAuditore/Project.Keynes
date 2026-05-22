extends DCSystem
class_name NativeEnvironmentRuntimeSystem

var generator = null
var map: MapData = null
var _last_result: Dictionary = {}
var _did_run_last_tick: bool = false
var _pipeline_cursor: StringName = &"ocean"


func _init(p_generator, p_map: MapData) -> void:
	generator = p_generator
	map = p_map
	id = &"native_environment_runtime"
	priority = 90
	must_run = false
	max_slices_per_tick = 1
	slice_budget_ms = 0.5
	starvation_threshold = 0


func feature_flag() -> StringName:
	return &""


func reset_run_flag() -> void:
	_did_run_last_tick = false


func did_run_last_tick() -> bool:
	return _did_run_last_tick


func last_result() -> Dictionary:
	return _last_result.duplicate(true)


func should_run(ctx: SusTickContext) -> bool:
	return generator != null and generator.has_method("environment_runtime_step_budgeted") and super.should_run(ctx)


func tick(_ctx) -> Dictionary:
	var pipeline_this_slice: StringName = _pipeline_cursor
	var t0: int = Time.get_ticks_usec()
	var res: Dictionary = generator.environment_runtime_step_budgeted(slice_budget_ms, 1024, 4096, 1024, pipeline_this_slice)
	var elapsed_ms: float = float(res.get("elapsed_ms", (Time.get_ticks_usec() - t0) / 1000.0))
	_did_run_last_tick = int(res.get("work_done", 0)) > 0
	_last_result = res.duplicate(true)
	_last_result["pipeline"] = String(pipeline_this_slice)
	if bool(res.get("done", true)):
		match pipeline_this_slice:
			&"ocean":
				_pipeline_cursor = &"weather"
			&"weather":
				_pipeline_cursor = &"climate"
			_:
				_pipeline_cursor = &"ocean"
	return {
		"done": bool(res.get("done", true)),
		"work_done": int(res.get("work_done", 0)),
		"elapsed_ms": elapsed_ms,
		"progress_ratio": float(res.get("progress_ratio", 1.0)),
		"stage_name": str(res.get("stage", "native_environment_runtime")),
		"substage": str(res.get("substage", "")),
		"path": str(res.get("path", "environment_runtime.step_budgeted")),
		"pipeline": String(pipeline_this_slice),
		"processed_cells": int(res.get("processed_cells", 0)),
		"processed_pixels": int(res.get("processed_pixels", 0)),
		"processed_indices": int(res.get("processed_indices", 0)),
		"cursor_start": int(res.get("cursor_start", -1)),
		"cursor_end": int(res.get("cursor_end", -1)),
	}


func reset_progress() -> void:
	super.reset_progress()
	_did_run_last_tick = false
	_last_result.clear()
	_pipeline_cursor = &"ocean"
