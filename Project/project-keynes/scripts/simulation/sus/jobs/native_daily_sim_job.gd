extends DCSystem
class_name NativeDailySimJob

const SusPolicyScript = preload("res://scripts/simulation/sus/sus_policy.gd")

var generator = null
var map: MapData = null
var world: WorldData = null
var _did_run_last_tick: bool = false
var _native_round_active: bool = false
var _last_result: Dictionary = {}
var _slow_dump_last_tick: int = -100000

const _SLOW_DUMP_MS: float = 5.0
const _SLOW_DUMP_MIN_INTERVAL_TICKS: int = 30


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
	return _last_result.duplicate()


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
	var job_shell_after_wrapper_ms: float = float(Time.get_ticks_usec() - t0) / 1000.0
	_did_run_last_tick = int(res.get("rc", -1)) == 0
	_native_round_active = _did_run_last_tick and not bool(res.get("done", true))
	var elapsed_ms: float = float(res.get("wrapper_wall_ms", (Time.get_ticks_usec() - t0) / 1000.0))
	var breakdown: Dictionary = res.get("breakdown", {})
	var published_slots = res.get("published_slots", [])
	var published_slot_count: int = 0
	if published_slots is Array or published_slots is PackedStringArray:
		published_slot_count = published_slots.size()
	var report := {
		"done": bool(res.get("done", true)),
		"work_done": 1 if _did_run_last_tick else 0,
		"elapsed_ms": elapsed_ms,
		"progress_ratio": float(res.get("progress_ratio", 1.0)),
		"stage": str(res.get("stage_name", "native_daily")),
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
	}
	var diagnostic_fields: Array[String] = [
		"node_index",
		"next_node_index",
		"last_completed_node",
		"processed_nodes",
		"deferred_wait_node",
		"deferred_wait_key",
		"jit_patch_build_ms",
		"jit_patch_keys",
		"bundle_cache_hit",
		"bundle_cache_rebuild_reason",
		"bundle_static_ms",
		"bundle_dynamic_ms",
		"deferred_node_count",
		"weather_knobs_prebuilt",
		"node_range_enabled",
		"node_range_active",
		"node_range_done",
		"node_range_budget",
		"node_range_node",
		"node_cell_cursor_start",
		"node_cell_cursor_end",
		"node_cell_count",
		"node_cell_processed",
		"native_daily_contract_version",
		"native_daily_contract_state",
		"native_daily_round_seq",
		"native_daily_stride_days",
		"native_daily_commit_lag_budget_days",
		"native_daily_sample_day",
		"native_daily_sample_tick",
		"native_daily_current_day",
		"native_daily_current_tick",
		"native_daily_commit_day",
		"native_daily_commit_tick",
		"native_daily_age_days",
		"native_daily_age_ticks",
		"native_daily_commit_over_budget",
		"native_daily_finalizer_pending",
	]
	for key in diagnostic_fields:
		if res.has(key):
			report[key] = res[key]
		elif breakdown.has(key):
			report[key] = breakdown[key]
	report["last_slice_processed_cells"] = int(report.get("node_cell_processed",
			res.get("processed_cells", breakdown.get("processed_cells", 0))))
	report["last_slice_cursor_start"] = int(report.get("node_cell_cursor_start",
			res.get("cursor_start", breakdown.get("cursor_start", -1))))
	report["last_slice_cursor_end"] = int(report.get("node_cell_cursor_end",
			res.get("cursor_end", breakdown.get("cursor_end", -1))))
	var finalizer_fields: Array[String] = [
		"thermal_finalizer_applied",
		"finalizer_path",
		"finalizer_total_ms",
		"finalizer_cell_ms",
		"finalizer_temp_ms",
		"finalizer_tta_ms",
		"finalizer_thermal_ms",
		"finalizer_sort_ms",
		"finalizer_sea_ice_ms",
		"finalizer_precip_ms",
		"finalizer_write_dense_ms",
		"finalizer_write_mode",
		"finalizer_dirty_collect_ms",
		"finalizer_sparse_components",
		"finalizer_dense_components",
		"finalizer_dirty_count_temp",
		"finalizer_dirty_count_tta",
		"finalizer_dirty_count_thermal",
		"finalizer_dirty_ratio",
		"finalizer_dirty_collect_skipped",
		"finalizer_dirty_collect_skip_components",
		"finalizer_sparse_write_ms",
		"finalizer_cells_seen",
		"finalizer_temperature_cell_mirror",
		"finalizer_tta_cell_mirror",
		"finalizer_tta_cell_mirror_count",
		"finalizer_tta_clamped_count",
		"finalizer_thermal_init_count",
		"temp_delta_clamped_count",
		"max_temp_delta",
		"preclamp_max_temp_delta",
		"temp_delta_gt_005_count",
		"temp_delta_gt_010_count",
		"temp_delta_gt_020_count",
	]
	for key in finalizer_fields:
		if res.has(key):
			report[key] = res[key]
		elif breakdown.has(key):
			report[key] = breakdown[key]
	var complete_apply_fields: Array[String] = [
		"complete_apply_total_ms",
		"complete_apply_observed_ms",
		"complete_apply_other_ms",
		"complete_apply_publish_tta_ms",
		"complete_apply_weather_result_ms",
		"complete_apply_visual_intents_ms",
		"complete_apply_finalizer_ms",
		"complete_apply_finalizer_merge_ms",
		"complete_apply_result_patch_ms",
	]
	for key in complete_apply_fields:
		if res.has(key):
			report[key] = res[key]
		elif breakdown.has(key):
			report[key] = breakdown[key]
	var job_shell_wall_ms: float = float(Time.get_ticks_usec() - t0) / 1000.0
	var wrapper_wall_ms: float = float(report.get("wrapper_wall_ms", elapsed_ms))
	report["job_shell_wall_ms"] = job_shell_wall_ms
	report["job_shell_wrapper_gap_ms"] = maxf(0.0, job_shell_wall_ms - wrapper_wall_ms)
	report["job_shell_report_build_ms"] = maxf(0.0, job_shell_wall_ms - job_shell_after_wrapper_ms)
	res["job_shell_wall_ms"] = job_shell_wall_ms
	res["job_shell_wrapper_gap_ms"] = report["job_shell_wrapper_gap_ms"]
	res["job_shell_report_build_ms"] = report["job_shell_report_build_ms"]
	if generator != null and generator.has_method("_record_native_daily_job_shell_diag"):
		generator._record_native_daily_job_shell_diag({
			"job_shell_wall_ms": job_shell_wall_ms,
			"job_shell_wrapper_gap_ms": report["job_shell_wrapper_gap_ms"],
			"job_shell_report_build_ms": report["job_shell_report_build_ms"],
		})
	# Keep only a shallow top-level copy in the job. Large nested arrays/dicts are immutable
	# for this diagnostic path and can be read from MapGenerator.native_daily_last_result().
	_last_result = res.duplicate()
	_maybe_dump_slow_slice(ctx, res, report, breakdown, elapsed_ms)
	return report


func _maybe_dump_slow_slice(ctx: SusTickContext, res: Dictionary, report: Dictionary,
		breakdown: Dictionary, elapsed_ms: float) -> void:
	var tick_idx: int = ctx.tick_index if ctx != null else -1
	if elapsed_ms < _SLOW_DUMP_MS:
		return
	if tick_idx >= 0 and tick_idx - _slow_dump_last_tick < _SLOW_DUMP_MIN_INTERVAL_TICKS:
		return
	_slow_dump_last_tick = tick_idx
	var stage: String = str(report.get("stage_name", res.get("stage_name", "")))
	var substage: String = str(report.get("substage", res.get("substage", "")))
	var cursor_start: int = int(res.get("cursor_start", breakdown.get("cursor_start", -1)))
	var cursor_end: int = int(res.get("cursor_end", breakdown.get("cursor_end", -1)))
	var cell_start: int = int(report.get("node_cell_cursor_start", breakdown.get("node_cell_cursor_start", -1)))
	var cell_end: int = int(report.get("node_cell_cursor_end", breakdown.get("node_cell_cursor_end", -1)))
	var cell_count: int = int(report.get("node_cell_count", breakdown.get("node_cell_count", 0)))
	var node_report: Dictionary = breakdown.get("node_report", {})
	var node_name: String = str(node_report.get("name", breakdown.get("last_completed_node", "")))
	var node_key: String = str(node_report.get("bundle_key", substage))
	print("[native_daily/slow-dump] tick=%d day=%d sample=%d commit=%d age=%d/%d over=%s state=%s stage=%s/%s node=%s/%s cursor=%d-%d cells=%d-%d/%d done=%s progress=%.2f wall=%.2f shell=%.2f shell_gap=%.2f bundle=%.2f jit=%.2f keys=%s native_call=%.2f cpp=%.2f compute=%.2f refresh=%.2f flush=%.2f apply=%.2f round=%.2f weather=%.2f prebuilt=%s path=%s" % [
		tick_idx,
		ctx.day_index if ctx != null else -1,
		int(report.get("native_daily_sample_day", res.get("native_daily_sample_day", -1))),
		int(report.get("native_daily_commit_day", res.get("native_daily_commit_day", -1))),
		int(report.get("native_daily_age_days", res.get("native_daily_age_days", 0))),
		int(report.get("native_daily_commit_lag_budget_days", res.get("native_daily_commit_lag_budget_days", 0))),
		str(report.get("native_daily_commit_over_budget", res.get("native_daily_commit_over_budget", false))),
		str(report.get("native_daily_contract_state", res.get("native_daily_contract_state", ""))),
		stage,
		substage,
		node_name,
		node_key,
		cursor_start,
		cursor_end,
		cell_start,
		cell_end,
		cell_count,
		str(bool(res.get("done", report.get("done", true)))),
		float(report.get("progress_ratio", res.get("progress_ratio", 1.0))),
		elapsed_ms,
		float(report.get("job_shell_wall_ms", res.get("job_shell_wall_ms", elapsed_ms))),
		float(report.get("job_shell_wrapper_gap_ms", res.get("job_shell_wrapper_gap_ms", 0.0))),
		float(report.get("bundle_ms", res.get("bundle_ms", 0.0))),
		float(report.get("jit_patch_build_ms", res.get("jit_patch_build_ms", breakdown.get("jit_patch_build_ms", 0.0)))),
		str(report.get("jit_patch_keys", res.get("jit_patch_keys", breakdown.get("jit_patch_keys", PackedStringArray())))),
		float(report.get("native_call_ms", res.get("native_call_ms", 0.0))),
		float(report.get("native_ms", res.get("native_ms", 0.0))),
		float(report.get("compute_ms", res.get("compute_ms", breakdown.get("compute_ms", 0.0)))),
		float(report.get("refresh_ms", res.get("refresh_ms", breakdown.get("refresh_ms", 0.0)))),
		float(report.get("flush_ms", res.get("flush_ms", breakdown.get("flush_ms", 0.0)))),
		float(report.get("apply_ms", res.get("apply_ms", 0.0))),
		float(report.get("round_native_ms", res.get("round_native_ms", 0.0))),
		float(breakdown.get("weather_ms", breakdown.get("weather_tick_ms", 0.0))),
		str(report.get("weather_knobs_prebuilt", breakdown.get("weather_knobs_prebuilt", false))),
		str(report.get("path", res.get("path", ""))),
	])
	if breakdown.has("weather_field_ms") or breakdown.has("weather_commit_ms") \
			or breakdown.has("weather_distribute_ms") or breakdown.has("weather_stage_b_ms"):
		print("[native_daily/slow-dump/weather] tick=%d field=%.2f commit=%.2f commit_loop=%.2f dist=%.2f summary=%.2f cyclone=%.2f stage_b=%.2f adv=%.2f fronts=%d active=%.3f lut_dirty=%d conv_dirty=%d" % [
			tick_idx,
			float(breakdown.get("weather_field_ms", 0.0)),
			float(breakdown.get("weather_commit_ms", breakdown.get("field_commit_total_ms", 0.0))),
			float(breakdown.get("field_commit_loop_ms", 0.0)),
			float(breakdown.get("weather_distribute_ms", breakdown.get("distribute_ms", 0.0))),
			float(breakdown.get("weather_summary_ms", breakdown.get("summary_ms", 0.0))),
			float(breakdown.get("weather_cyclone_ms", breakdown.get("cyclone_ms", 0.0))),
			float(breakdown.get("weather_stage_b_ms", 0.0)),
			float(breakdown.get("advance_ms", 0.0)),
			int(breakdown.get("fronts_count", 0)),
			float(breakdown.get("active_weather_ratio", 0.0)),
			int(breakdown.get("weather_lut_dirty_count", 0)),
			int(breakdown.get("weather_convergence_dirty_count", 0)),
		])
	var complete_apply_total: float = float(report.get("complete_apply_total_ms", breakdown.get("complete_apply_total_ms", 0.0)))
	if complete_apply_total > 0.0 or stage == "native_daily_complete":
		print("[native_daily/slow-dump/complete-apply] tick=%d total=%.3f observed=%.3f other=%.3f publish_tta=%.3f weather_result=%.3f visual=%.3f finalizer=%.3f merge=%.3f result_patch=%.3f" % [
			tick_idx,
			complete_apply_total,
			float(report.get("complete_apply_observed_ms", breakdown.get("complete_apply_observed_ms", 0.0))),
			float(report.get("complete_apply_other_ms", breakdown.get("complete_apply_other_ms", 0.0))),
			float(report.get("complete_apply_publish_tta_ms", breakdown.get("complete_apply_publish_tta_ms", 0.0))),
			float(report.get("complete_apply_weather_result_ms", breakdown.get("complete_apply_weather_result_ms", 0.0))),
			float(report.get("complete_apply_visual_intents_ms", breakdown.get("complete_apply_visual_intents_ms", 0.0))),
			float(report.get("complete_apply_finalizer_ms", breakdown.get("complete_apply_finalizer_ms", 0.0))),
			float(report.get("complete_apply_finalizer_merge_ms", breakdown.get("complete_apply_finalizer_merge_ms", 0.0))),
			float(report.get("complete_apply_result_patch_ms", breakdown.get("complete_apply_result_patch_ms", 0.0))),
		])
	var finalizer_total: float = float(report.get("finalizer_total_ms", breakdown.get("finalizer_total_ms", 0.0)))
	if finalizer_total > 0.0 or stage == "native_daily_complete":
		print("[native_daily/slow-dump/finalizer] tick=%d total=%.3f cell=%.3f temp=%.3f tta=%.3f thermal=%.3f sea_ice=%.3f precip=%.3f write_mode=%s dense=%.3f sparse=%.3f dirty_collect=%.3f dirty_skip=%s skip_comps=%s dirty_ratio=%.3f dirty=%d/%d/%d comps_dense=%s comps_sparse=%s" % [
			tick_idx,
			finalizer_total,
			float(report.get("finalizer_cell_ms", breakdown.get("finalizer_cell_ms", 0.0))),
			float(report.get("finalizer_temp_ms", breakdown.get("finalizer_temp_ms", 0.0))),
			float(report.get("finalizer_tta_ms", breakdown.get("finalizer_tta_ms", 0.0))),
			float(report.get("finalizer_thermal_ms", breakdown.get("finalizer_thermal_ms", 0.0))),
			float(report.get("finalizer_sea_ice_ms", breakdown.get("finalizer_sea_ice_ms", 0.0))),
			float(report.get("finalizer_precip_ms", breakdown.get("finalizer_precip_ms", 0.0))),
			str(report.get("finalizer_write_mode", breakdown.get("finalizer_write_mode", ""))),
			float(report.get("finalizer_write_dense_ms", breakdown.get("finalizer_write_dense_ms", 0.0))),
			float(report.get("finalizer_sparse_write_ms", breakdown.get("finalizer_sparse_write_ms", 0.0))),
			float(report.get("finalizer_dirty_collect_ms", breakdown.get("finalizer_dirty_collect_ms", 0.0))),
			str(report.get("finalizer_dirty_collect_skipped", breakdown.get("finalizer_dirty_collect_skipped", false))),
			str(report.get("finalizer_dirty_collect_skip_components", breakdown.get("finalizer_dirty_collect_skip_components", []))),
			float(report.get("finalizer_dirty_ratio", breakdown.get("finalizer_dirty_ratio", 0.0))),
			int(report.get("finalizer_dirty_count_temp", breakdown.get("finalizer_dirty_count_temp", 0))),
			int(report.get("finalizer_dirty_count_tta", breakdown.get("finalizer_dirty_count_tta", 0))),
			int(report.get("finalizer_dirty_count_thermal", breakdown.get("finalizer_dirty_count_thermal", 0))),
			str(report.get("finalizer_dense_components", breakdown.get("finalizer_dense_components", []))),
			str(report.get("finalizer_sparse_components", breakdown.get("finalizer_sparse_components", []))),
		])


func reset_progress() -> void:
	super.reset_progress()
	_did_run_last_tick = false
	_native_round_active = false
	_last_result.clear()
