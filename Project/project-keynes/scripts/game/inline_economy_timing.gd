extends RefCounted

## Records work and wall time for economy continuations.


static func _ensure_continuation_perf_pending(context) -> void:
	if not context._generator._continuation_perf_pending.is_empty():
		return
	context._generator._continuation_perf_pending = {
		"frames": 0,
		"slices": 0,
		"continuation_started_slices": 0,
		"continuation_completed_slices": 0,
		"continuation_budget_exhausted": false,
		"continuation_budget_overrun_frames": 0,
		"continuation_max_budget_overrun_ms": 0.0,
		"continuation_blocked_by_stage": "",
		"country_slices": 0,
		"economy_slices": 0,
		"wall_ms": 0.0,
		"max_frame_wall_ms": 0.0,
		"max_slice_ms": 0.0,
		"last_slice_ms": 0.0,
		"budget_ms": 0.0,
		"last_stage": "",
		"last_next_stage": "",
		"last_substage": "",
		"last_path": "",
		"done": false,

		"stage_counts": {},
		"stage_wall_ms": {},
		"stage_max_slice_ms": {},
		"substage_counts": {},
		"substage_wall_ms": {},
		"substage_max_slice_ms": {},
		"substage_work": {},
	}

static func _record_continuation_slice(context, source: String, result: Dictionary, wall_ms: float) -> float:
	context._generator._ensure_continuation_perf_pending()
	var slice_ms: float = maxf(wall_ms, 0.0)
	var stage: String = str(result.get("stage_name", result.get("stage", "")))
	var next_stage: String = str(result.get("next_stage", result.get("stage", "")))
	var substage: String = str(result.get("substage", ""))
	var path: String = str(result.get("path", ""))
	if stage.is_empty():
		stage = "unknown"
	var stage_key := "%s:%s" % [source, stage]
	var stage_counts: Dictionary = context._generator._continuation_perf_pending.get("stage_counts", {})
	stage_counts[stage_key] = int(stage_counts.get(stage_key, 0)) + 1
	context._generator._continuation_perf_pending["stage_counts"] = stage_counts
	var stage_wall_ms: Dictionary = context._generator._continuation_perf_pending.get("stage_wall_ms", {})
	stage_wall_ms[stage_key] = float(stage_wall_ms.get(stage_key, 0.0)) + slice_ms
	context._generator._continuation_perf_pending["stage_wall_ms"] = stage_wall_ms
	var stage_max_slice_ms: Dictionary = context._generator._continuation_perf_pending.get(
		"stage_max_slice_ms", {})
	stage_max_slice_ms[stage_key] = maxf(
		float(stage_max_slice_ms.get(stage_key, 0.0)), slice_ms)
	context._generator._continuation_perf_pending["stage_max_slice_ms"] = stage_max_slice_ms
	var breakdown_ms_value = result.get("stage_breakdown_ms", {})
	if breakdown_ms_value is Dictionary:
		var substage_counts: Dictionary = context._generator._continuation_perf_pending.get(
			"substage_counts", {})
		var substage_wall_ms: Dictionary = context._generator._continuation_perf_pending.get(
			"substage_wall_ms", {})
		var substage_max_slice_ms: Dictionary = context._generator._continuation_perf_pending.get(
			"substage_max_slice_ms", {})
		for breakdown_name in breakdown_ms_value:
			var breakdown_ms: float = maxf(
				0.0, float(breakdown_ms_value.get(breakdown_name, 0.0)))
			if breakdown_ms <= 0.0:
				continue
			var breakdown_key := "%s:%s" % [source, str(breakdown_name)]
			substage_counts[breakdown_key] = int(
				substage_counts.get(breakdown_key, 0)) + 1
			substage_wall_ms[breakdown_key] = float(
				substage_wall_ms.get(breakdown_key, 0.0)) + breakdown_ms
			substage_max_slice_ms[breakdown_key] = maxf(float(
				substage_max_slice_ms.get(breakdown_key, 0.0)), breakdown_ms)
		context._generator._continuation_perf_pending["substage_counts"] = substage_counts
		context._generator._continuation_perf_pending["substage_wall_ms"] = substage_wall_ms
		context._generator._continuation_perf_pending["substage_max_slice_ms"] = substage_max_slice_ms
	var breakdown_work_value = result.get("stage_breakdown_work", {})
	if breakdown_work_value is Dictionary:
		var substage_work: Dictionary = context._generator._continuation_perf_pending.get("substage_work", {})
		for work_name in breakdown_work_value:
			var work: int = int(breakdown_work_value.get(work_name, 0))
			if work <= 0:
				continue
			var work_key := "%s:%s" % [source, str(work_name)]
			substage_work[work_key] = int(substage_work.get(work_key, 0)) + work
		context._generator._continuation_perf_pending["substage_work"] = substage_work
	context._generator._continuation_perf_pending["slices"] = int(context._generator._continuation_perf_pending.get("slices", 0)) + 1
	context._generator._continuation_perf_pending["continuation_started_slices"] = int(
		context._generator._continuation_perf_pending.get("continuation_started_slices", 0)) + 1
	var source_key := "%s_slices" % source
	context._generator._continuation_perf_pending[source_key] = int(context._generator._continuation_perf_pending.get(source_key, 0)) + 1
	context._generator._continuation_perf_pending["max_slice_ms"] = maxf(
		float(context._generator._continuation_perf_pending.get("max_slice_ms", 0.0)), slice_ms)
	context._generator._continuation_perf_pending["last_slice_ms"] = slice_ms
	context._generator._continuation_perf_pending["last_stage"] = stage
	context._generator._continuation_perf_pending["last_next_stage"] = next_stage
	context._generator._continuation_perf_pending["last_substage"] = substage
	context._generator._continuation_perf_pending["last_path"] = path
	var completed := bool(result.get("done", false))
	context._generator._continuation_perf_pending["done"] = completed
	if completed:
		context._generator._continuation_perf_pending["continuation_completed_slices"] = int(
			context._generator._continuation_perf_pending.get("continuation_completed_slices", 0)) + 1
	return slice_ms

static func _finish_continuation_perf_frame(context, started_us: int, frame_slices: int,
		frame_max_slice_ms: float, budget_ms: float) -> void:
	if frame_slices <= 0 or context._generator._continuation_perf_pending.is_empty():
		return
	var frame_wall_ms: float = float(Time.get_ticks_usec() - started_us) / 1000.0
	context._generator._continuation_perf_pending["frames"] = int(context._generator._continuation_perf_pending.get("frames", 0)) + 1
	context._generator._continuation_perf_pending["wall_ms"] = float(context._generator._continuation_perf_pending.get("wall_ms", 0.0)) + frame_wall_ms
	context._generator._continuation_perf_pending["max_frame_wall_ms"] = maxf(
		float(context._generator._continuation_perf_pending.get("max_frame_wall_ms", 0.0)), frame_wall_ms)
	context._generator._continuation_perf_pending["max_slice_ms"] = maxf(
		float(context._generator._continuation_perf_pending.get("max_slice_ms", 0.0)), frame_max_slice_ms)
	context._generator._continuation_perf_pending["budget_ms"] = budget_ms
	# Completion is a semantic state transition, not permission to hide a
	# deadline overrun.  The final publish slice can complete after the budget;
	# keep that fact visible for the render-frame performance gate.
	var budget_exhausted := budget_ms > 0.0 and frame_wall_ms >= budget_ms
	context._generator._continuation_perf_pending["continuation_budget_exhausted"] = \
		bool(context._generator._continuation_perf_pending.get(
			"continuation_budget_exhausted", false)) or budget_exhausted
	if budget_exhausted:
		context._generator._continuation_perf_pending["continuation_budget_overrun_frames"] = int(
			context._generator._continuation_perf_pending.get(
				"continuation_budget_overrun_frames", 0)) + 1
		context._generator._continuation_perf_pending["continuation_max_budget_overrun_ms"] = maxf(
			float(context._generator._continuation_perf_pending.get(
				"continuation_max_budget_overrun_ms", 0.0)),
			maxf(0.0, frame_wall_ms - budget_ms))
		var last_stage := str(context._generator._continuation_perf_pending.get("last_stage", ""))
		if not last_stage.is_empty():
			context._generator._continuation_perf_pending["continuation_blocked_by_stage"] = last_stage
