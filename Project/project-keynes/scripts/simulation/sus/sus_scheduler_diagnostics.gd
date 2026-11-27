extends RefCounted

## Records sliced work timing and reports scheduler budget pressure.


static func report_last_tick(owner: SlicedUpdateScheduler) -> Dictionary:
	if owner._ext != null:
		return owner._ext.report_last_tick()
	return owner._last_report.duplicate(true)


## Perf instrumentation: 上一 tick 的整体摘要（耗时 / 跑/跳数 / 切片总数）。
## main.gd 用它来：
##   1. 把 SUS 那段耗时与 fast tick 总耗时对比
##   2. 触发 > 12ms WARN 时附带打印
static func report_last_tick_summary(owner: SlicedUpdateScheduler) -> Dictionary:
	if owner._ext != null:
		return owner._ext.report_last_tick_summary()
	return owner._last_tick_summary.duplicate(true)



static func report_sim_budget_window(owner: SlicedUpdateScheduler) -> Dictionary:
	if owner._ext != null:
		return owner._ext.report_sim_budget_window()
	return owner._sim_budget_window_dict().duplicate(true)


## Perf instrumentation: 滚动窗口内的 skipped_reason 累计 + max_ms。
## 用于诊断"某 Job 长期被节流"等慢性问题。
static func report_skipped_summary(owner: SlicedUpdateScheduler) -> Dictionary:
	if owner._ext != null:
		return owner._ext.report_skipped_summary()
	var out: Dictionary = {}
	for job_id in owner._stats.keys():
		var s: Dictionary = owner._stats[job_id]
		out[job_id] = {
			"skipped": (s.get("skipped", {}) as Dictionary).duplicate(),
			"max_ms": float(s.get("max_ms", 0.0)),
		}
	return out


## DOTS-Final-Push 任务 10：返回 `_stats` 全表的深拷贝，供
## DCDotsFinalPushPerfVerdict.evaluate() 使用。schema 与 _record_stats 一致：
##   { job_id -> { samples: Array[float], slices_total: int,
##                 skipped: Dictionary, max_ms: float } }
## 注意：`samples` 在每次 log_interval_ticks 被清空（line 362），所以读取窗口
## 由 SUS scheduler 的滚动周期决定（默认 30 tick）。caller 若要 200 tick 长
## 窗口，应在 main.gd 自行累积 fast tick total_ms 数组，本表仅供 SUS Job
## p95 比对（30 tick 滚动 p95 已足以判定稳态门槛）。
static func report_job_stats(owner: SlicedUpdateScheduler) -> Dictionary:
	if owner._ext != null:
		return owner._ext.report_job_stats()
	var out: Dictionary = {}
	for job_id in owner._stats.keys():
		var s: Dictionary = owner._stats[job_id]
		var samples: Array = s.get("samples", [])
		out[job_id] = {
			"samples": samples.duplicate(),
			"slices_total": int(s.get("slices_total", 0)),
			"skipped": (s.get("skipped", {}) as Dictionary).duplicate(),
			"max_ms": float(s.get("max_ms", 0.0)),
		}
	return out



static func _record_tick_budget_sample(owner: SlicedUpdateScheduler, total_ms: float, largest_job: StringName, largest_stage: String,
		largest_substage: String, largest_path: String, largest_ms: float,
		largest_work_done: int = 0, largest_processed_cells: int = 0,
		largest_processed_pixels: int = 0, largest_processed_indices: int = 0,
		largest_cursor_start: int = -1, largest_cursor_end: int = -1,
		largest_fallback_path: String = "") -> void:
	owner._tick_budget_samples.append({
		"total_ms": total_ms,
		"largest_slice_job": largest_job,
		"largest_slice_stage": largest_stage,
		"largest_slice_substage": largest_substage,
		"largest_slice_path": largest_path,
		"largest_slice_ms": largest_ms,
		"largest_slice_work_done": largest_work_done,
		"largest_slice_processed_cells": largest_processed_cells,
		"largest_slice_processed_pixels": largest_processed_pixels,
		"largest_slice_processed_indices": largest_processed_indices,
		"largest_slice_cursor_start": largest_cursor_start,
		"largest_slice_cursor_end": largest_cursor_end,
		"largest_slice_fallback_path": largest_fallback_path,
	})
	while owner._tick_budget_samples.size() > maxi(1, owner.sim_budget_window_size):
		owner._tick_budget_samples.remove_at(0)



static func _sim_budget_window_dict(owner: SlicedUpdateScheduler) -> Dictionary:
	var sample_count: int = owner._tick_budget_samples.size()
	if sample_count <= 0:
		return {
			"sus_sim_p95_300": 0.0,
			"sus_sim_max_300": 0.0,
			"over_1ms_count_300": 0,
			"largest_slice_job": &"",
			"largest_slice_stage": "",
			"largest_slice_substage": "",
			"largest_slice_path": "",
			"largest_slice_ms": 0.0,
			"largest_slice_work_done": 0,
			"largest_slice_processed_cells": 0,
			"largest_slice_processed_pixels": 0,
			"largest_slice_processed_indices": 0,
			"largest_slice_cursor_start": -1,
			"largest_slice_cursor_end": -1,
			"largest_slice_fallback_path": "",
			"largest_slice_processed_per_ms": 0.0,
			"sus_sim_avg_300": 0.0,
			"sim_frame_budget_ms": owner.frame_budget_ms,
			"sim_slice_budget_ms": owner._max_registered_slice_budget_ms(false),
			"sim_upload_slice_budget_ms": owner._max_registered_slice_budget_ms(true),
			"sim_strict_budget_enabled": owner.strict_budget_enabled,
			"sim_budget_warn_ms": owner.sim_budget_warn_ms,
			"economy_reserved_budget_ms": maxf(0.0, 16.666 - owner.frame_budget_ms),
			"sample_count": 0,
		}
	var totals: Array = []
	var sum_total_ms: float = 0.0
	var max_total_ms: float = 0.0
	var over_count: int = 0
	var largest_job: StringName = &""
	var largest_stage: String = ""
	var largest_substage: String = ""
	var largest_path: String = ""
	var largest_ms: float = 0.0
	var largest_work_done: int = 0
	var largest_processed_cells: int = 0
	var largest_processed_pixels: int = 0
	var largest_processed_indices: int = 0
	var largest_cursor_start: int = -1
	var largest_cursor_end: int = -1
	var largest_fallback_path: String = ""
	for sample in owner._tick_budget_samples:
		var d: Dictionary = sample
		var total_ms: float = float(d.get("total_ms", 0.0))
		totals.append(total_ms)
		sum_total_ms += total_ms
		max_total_ms = maxf(max_total_ms, total_ms)
		if total_ms > owner.sim_budget_warn_ms:
			over_count += 1
		var slice_ms: float = float(d.get("largest_slice_ms", 0.0))
		if slice_ms > largest_ms:
			largest_ms = slice_ms
			largest_job = StringName(str(d.get("largest_slice_job", "")))
			largest_stage = str(d.get("largest_slice_stage", ""))
			largest_substage = str(d.get("largest_slice_substage", ""))
			largest_path = str(d.get("largest_slice_path", ""))
			largest_work_done = int(d.get("largest_slice_work_done", 0))
			largest_processed_cells = int(d.get("largest_slice_processed_cells", 0))
			largest_processed_pixels = int(d.get("largest_slice_processed_pixels", 0))
			largest_processed_indices = int(d.get("largest_slice_processed_indices", 0))
			largest_cursor_start = int(d.get("largest_slice_cursor_start", -1))
			largest_cursor_end = int(d.get("largest_slice_cursor_end", -1))
			largest_fallback_path = str(d.get("largest_slice_fallback_path", ""))
	totals.sort()
	var p95_idx: int = clampi(int(ceil(totals.size() * 0.95)) - 1, 0, totals.size() - 1)
	var avg_total_ms: float = sum_total_ms / float(maxi(1, sample_count))
	var processed_per_ms: float = owner._processed_per_ms(largest_work_done, largest_processed_cells,
		largest_processed_pixels, largest_processed_indices, largest_ms)
	return {
		"sus_sim_avg_300": avg_total_ms,
		"sus_sim_p95_300": float(totals[p95_idx]),
		"sus_sim_max_300": max_total_ms,
		"over_1ms_count_300": over_count,
		"largest_slice_job": largest_job,
		"largest_slice_stage": largest_stage,
		"largest_slice_substage": largest_substage,
		"largest_slice_path": largest_path,
		"largest_slice_ms": largest_ms,
		"largest_slice_work_done": largest_work_done,
		"largest_slice_processed_cells": largest_processed_cells,
		"largest_slice_processed_pixels": largest_processed_pixels,
		"largest_slice_processed_indices": largest_processed_indices,
		"largest_slice_cursor_start": largest_cursor_start,
		"largest_slice_cursor_end": largest_cursor_end,
		"largest_slice_fallback_path": largest_fallback_path,
		"largest_slice_processed_per_ms": processed_per_ms,
		"sim_frame_budget_ms": owner.frame_budget_ms,
		"sim_slice_budget_ms": owner._max_registered_slice_budget_ms(false),
		"sim_upload_slice_budget_ms": owner._max_registered_slice_budget_ms(true),
		"sim_strict_budget_enabled": owner.strict_budget_enabled,
		"sim_budget_warn_ms": owner.sim_budget_warn_ms,
		"economy_reserved_budget_ms": maxf(0.0, 16.666 - owner.frame_budget_ms),
		"sample_count": sample_count,
	}



static func _slice_stage_name(owner: SlicedUpdateScheduler, slice_result: Dictionary) -> String:
	for key in ["stage_name", "stage", "pass", "axis"]:
		if slice_result.has(key):
			return str(slice_result[key])
	return ""



static func _slice_substage_name(owner: SlicedUpdateScheduler, slice_result: Dictionary) -> String:
	for key in ["substage", "micro_stage", "stage_detail"]:
		if slice_result.has(key):
			return str(slice_result[key])
	return ""



static func _is_upload_job(owner: SlicedUpdateScheduler, job_id: StringName) -> bool:
	return job_id == &"enum_atlas_upload" \
		or job_id == &"dynamic_visual_atlas_upload"



static func _slice_stage_looks_cell_based(owner: SlicedUpdateScheduler, stage: String) -> bool:
	return stage.begins_with("weather_") or stage.begins_with("pass_") \
		or stage == "ocean_water" or stage == "ocean_land" \
		or stage == "sea_ice" or stage == "transp"



static func _slice_stage_looks_pixel_based(owner: SlicedUpdateScheduler, stage: String) -> bool:
	return stage.find("pixel") >= 0 or stage.find("raster") >= 0



static func _processed_per_ms(owner: SlicedUpdateScheduler, work_done: int, processed_cells: int, processed_pixels: int,
		processed_indices: int, elapsed_ms: float) -> float:
	if elapsed_ms <= 0.0:
		return 0.0
	var processed: int = max(work_done, max(processed_cells, max(processed_pixels, processed_indices)))
	return float(processed) / elapsed_ms



static func _max_registered_slice_budget_ms(owner: SlicedUpdateScheduler, upload_jobs: bool) -> float:
	var out: float = 0.0
	for j in owner._jobs:
		if owner._is_upload_job(j.id) == upload_jobs:
			out = maxf(out, float(j.slice_budget_ms))
	return out



static func _record_stats(owner: SlicedUpdateScheduler, job_id: StringName, elapsed_ms: float, slices_run: int) -> void:
	if not owner._stats.has(job_id):
		owner._stats[job_id] = {
			"samples": [],
			"slices_total": 0,
			"skipped": {},
			"max_ms": 0.0,
		}
	var s: Dictionary = owner._stats[job_id]
	(s["samples"] as Array).append(elapsed_ms)
	s["slices_total"] = int(s["slices_total"]) + slices_run
	if elapsed_ms > float(s.get("max_ms", 0.0)):
		s["max_ms"] = elapsed_ms



static func _record_skipped(owner: SlicedUpdateScheduler, job_id: StringName, reason: String) -> void:
	if not owner._stats.has(job_id):
		owner._stats[job_id] = {
			"samples": [],
			"slices_total": 0,
			"skipped": {},
			"max_ms": 0.0,
		}
	var s: Dictionary = owner._stats[job_id]
	var skipped: Dictionary = s.get("skipped", {})
	skipped[reason] = int(skipped.get(reason, 0)) + 1
	s["skipped"] = skipped



static func _emit_periodic_log(owner: SlicedUpdateScheduler) -> void:
	for job_id in owner._stats.keys():
		var s: Dictionary = owner._stats[job_id]
		var samples: Array = s["samples"]
		if samples.is_empty() and (s.get("skipped", {}) as Dictionary).is_empty():
			continue
		var avg_ms: float = 0.0
		var p95_ms: float = 0.0
		var max_ms: float = float(s.get("max_ms", 0.0))
		if not samples.is_empty():
			var sum_ms: float = 0.0
			for v in samples:
				sum_ms += float(v)
			avg_ms = sum_ms / float(samples.size())
			var sorted: Array = samples.duplicate()
			sorted.sort()
			var p95_idx: int = clampi(int(ceil(sorted.size() * 0.95)) - 1, 0, sorted.size() - 1)
			p95_ms = float(sorted[p95_idx])
		# Perf instrumentation: 把 skipped 各原因压进同一行，看个分布
		var skipped: Dictionary = s.get("skipped", {})
		var skipped_str: String = ""
		if not skipped.is_empty():
			var parts: PackedStringArray = []
			for k in skipped.keys():
				parts.append("%s=%d" % [str(k), int(skipped[k])])
			skipped_str = " skipped[" + ",".join(parts) + "]"
		print("[SUS] last %d ticks: %s ran=%d avg=%.2fms p95=%.2fms max=%.2fms slices=%d%s"
			% [owner.log_interval_ticks, str(job_id), samples.size(), avg_ms, p95_ms, max_ms,
				int(s["slices_total"]), skipped_str])
		# Reset rolling window.
		s["samples"] = []
		s["slices_total"] = 0
		s["skipped"] = {}
		s["max_ms"] = 0.0
	var bw: Dictionary = owner._sim_budget_window_dict()
	if int(bw.get("sample_count", 0)) > 0:
		print("[SUS] budget last %d ticks: total_p95=%.2fms max=%.2fms over_1ms=%d largest=%s/%s/%s path=%s %.2fms"
			% [int(bw.get("sample_count", 0)),
				float(bw.get("sus_sim_p95_300", 0.0)),
				float(bw.get("sus_sim_max_300", 0.0)),
				int(bw.get("over_1ms_count_300", 0)),
				str(bw.get("largest_slice_job", "")),
				str(bw.get("largest_slice_stage", "")),
				str(bw.get("largest_slice_substage", "")),
				str(bw.get("largest_slice_path", "")),
				float(bw.get("largest_slice_ms", 0.0))])
	# DataCore 状态尾巴一行（dots-foundation-and-weather-migration 任务 10）。
	# 仅在已 bind World 时打印；未 bind 时（默认 legacy）保持静默以减少 log 噪声。
	if owner.world != null:
		var bound: bool = owner.world.has_method("is_bound") and owner.world.is_bound()
		if bound:
			var ent_n: int = int(owner.world.entity_count()) if owner.world.has_method("entity_count") else 0
			var comp_n: int = int(owner.world.component_count()) if owner.world.has_method("component_count") else 0
			var pool_n: int = int(owner.world.pool_count()) if owner.world.has_method("pool_count") else 0
			print("[SUS] world: bound=true entities=%d components=%d pools=%d" % [ent_n, comp_n, pool_n])
