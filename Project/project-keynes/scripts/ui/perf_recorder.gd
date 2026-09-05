# perf_recorder.gd
# Plan: perf-recording-csv-export
#
# 性能录制器 —— 在 fast_tick 末尾被动接收一帧的关键耗时指标，停止时把整段
# 录制导出为宽表 CSV，方便事后用 Excel / Pandas 对照分析瓶颈。
#
# 数据来源（全部经由 main.gd 的既有 getter，不直接耦合 SUS / MapGenerator）：
#   - sample（由 main.gd._publish_fast_tick_perf_sample 构造）：tick_idx /
#     timestamp_ms / fast_ms / t_sus_ms / t_render_ms / t_ui_ms / was_skipped_day / fps
#   - main.get_sus_last_tick_report()    → 各 Job 的 elapsed_ms / slices_run / skipped_reason
#   - main.get_sus_last_tick_summary()   → largest_slice_* + sus_sim_p95_300 等
#   - main.get_sim_breakdowns()          → { ui / climate / weather / economy / atlas... } 子 dict
#
# CSV 列顺序：
#   1. 固定列（FIXED_COLUMNS，下方常量）
#   2. 动态 job 列：每个出现过的 job_id 展开为 j_<id>_ms / j_<id>_slices / j_<id>_skip
#   3. 动态 breakdown 列：bd_<group>_<key>，按首次出现顺序
#
# 跳日帧（was_skipped_day=true）的 SUS 段不刷新，对应 cell 留空字符串，避免
# 误把"未刷新"读作"0ms"。
#
# 不持有 SUS 引用，不修改任何 Job 内部逻辑；continuation 计时由 MapGenerator
# 聚合后随 fast-tick sample 传入，避免 recorder 自己驱动调度。
class_name PerfRecorder
extends RefCounted


# 固定列（出现在 CSV 最左侧，写死保证跨录制 diff 友好）
# 注意：GDScript 的 const 不允许调构造函数，因此用 Array 字面量。
# _collect_columns / _format_*_line 内部只读迭代，不依赖具体类型。
const FIXED_COLUMNS: Array = [
	"row_idx",
	"tick_idx",
	"timestamp_ms",
	"was_skipped_day",
	"fps",
	"speed_multiplier",
	"fast_ms",
	"t_sus_ms",
	"t_render_ms",
	"t_ui_ms",
	"largest_slice_job",
	"largest_slice_stage",
	"largest_slice_substage",
	"largest_slice_path",
	"largest_slice_ms",
	"largest_slice_work_done",
	"largest_slice_processed_cells",
	"largest_slice_processed_pixels",
	"largest_slice_processed_indices",
	"largest_slice_cursor_start",
	"largest_slice_cursor_end",
	"largest_slice_fallback_path",
	"largest_slice_processed_per_ms",
	"sus_sim_avg_300",
	"sus_sim_p95_300",
	"sus_sim_max_300",
	"over_1ms_count_300",
	"sim_frame_budget_ms",
	"sim_slice_budget_ms",
	"sim_upload_slice_budget_ms",
	"sim_strict_budget_enabled",
	"sim_budget_warn_ms",
	"economy_reserved_budget_ms",
	"country_ui_refresh_reason",
	"country_ui_snapshot_ms",
	"country_ui_cache_hit",
	"country_ui_dirty_domains",
	"country_ui_event_refresh_enabled",
	"country_report_mode",
	"country_state_hash_ms",
	"country_report_build_ms",
	"research_queue_size",
	"research_full_scan_fallbacks",
	"research_activation_ms",
	"research_allocation_ms",
	"research_effect_ack_ms",
	"research_discovery_ms",
	"research_modifier_ms",
	"research_report_ms",
	"research_countries_scanned",
	"research_active_countries",
	"research_pending_checks",
	"research_discovery_checks",
	"research_discovery_frontier_mismatches",
	"research_modifier_queries",
	"research_modifier_cache_hits",
	"research_remainder_iterations",
	# Economy epoch/workset telemetry. These aliases are copied from the
	# freshness-gated bd_economy_* breakdown so the CSV contract remains easy to
	# query without knowing the dynamic breakdown prefix.
	"prepare_reuse_count",
	"workset_cells_planned",
	"workset_cells_executed",
	"duplicate_range_count",
	"household_market_prepare_ms",
	"household_market_worker_ms",
	"household_market_merge_ms",
	"bio_slice_native_ms",
	"bio_slice_publish_ms",
	"bio_knob_cache_hit",
	"bio_knob_cache_build_ms",
	"bio_slice_fallback_reason",
	"natural_resource_factor_lookup_ms",
	"natural_resource_slot_refresh_ms",
	"natural_resource_knob_update_ms",
	"natural_resource_native_call_ms",
	"natural_resource_fallback_ms",
	# The rows are emitted at fast-tick boundaries. These fields describe the
	# economy/country continuation pulses that completed since the prior row.
	"continuation_frames",
	"continuation_slices",
	"continuation_started_slices",
	"continuation_completed_slices",
	"continuation_budget_exhausted",
	"continuation_budget_overrun_frames",
	"continuation_max_budget_overrun_ms",
	"continuation_blocked_by_stage",
	"continuation_country_slices",
	"continuation_economy_slices",
	"continuation_wall_ms",
	"continuation_max_frame_wall_ms",
	"continuation_max_slice_ms",
	"continuation_last_slice_ms",
	"continuation_budget_ms",
	"continuation_last_stage",
	"continuation_last_next_stage",
	"continuation_last_substage",
	"continuation_last_path",
	"continuation_done",
	"continuation_stage_counts",
	"continuation_stage_wall_ms",
	"continuation_stage_max_slice_ms",
	"continuation_substage_counts",
	"continuation_substage_wall_ms",
	"continuation_substage_max_slice_ms",
	"continuation_substage_work",
	# WorldClock 帧内分解（毫秒）：pulse = continuation 脉冲段（日循环之前、
	# fast_ms 之外的盲区）；loop/full 比本行滞后一帧。frame_tail ≈
	# (1000/fps) - clock_full_ms 即帧尾残余（标签/overlay/植被队列/deferred/渲染提交）。
	"clock_pulse_ms",
	"clock_loop_ms",
	"clock_full_ms",
	# 帧尾探针（毫秒）：tick 触发、帧尾执行的三条已知路径。label/vegetation 比
	# 本行滞后一帧；overlay 是自上一行以来的累计。frame_tail 残余 =
	# (1000/fps) - clock_full_ms；减去这三项即未知帧尾。
	"tail_label_ms",
	"tail_label_count",
	"tail_vegetation_ms",
	"tail_vegetation_inflight",
	"tail_vegetation_dedup_skips",
	"tail_vegetation_tasks",
	"tail_vegetation_forced_tasks",
	"tail_vegetation_max_task_ms",
	"tail_vegetation_plan_ms",
	"tail_vegetation_encode_ms",
	"tail_vegetation_cache_update_ms",
	"tail_vegetation_assemble_ms",
	"tail_vegetation_upload_ms",
	"tail_overlay_ms",
	"tail_overlay_last_bake_ms",
	"tail_overlay_interval_msec",
	"tail_overlay_refresh_count",
	# 帧级渲染残差探针：frame_wall_ms = 相邻 perf 行间的平均帧墙钟（引擎帧号差分，
	# 1 tick/帧时即逐帧墙钟）；render_residual_ms = wall - clock_full - 已知帧尾
	# （植被/标签/overlay）≈ 渲染提交 + GPU present + 未埋点 _process 节点。
	# engine_process/physics_ms 为引擎监视器原始值（口径与帧墙钟不严格可比，
	# 仅作信息列）；render_*_in_frame 为绘制负载。
	"frame_wall_ms",
	"engine_process_ms",
	"engine_physics_ms",
	"render_residual_ms",
	"render_objects_in_frame",
	"render_primitives_in_frame",
	"render_draw_calls_in_frame",
	"runtime_graph_pulse_count",
	"runtime_graph_abi_calls",
	"runtime_graph_gdscript_callbacks",
	"runtime_graph_work_done",
	"runtime_graph_budget_yields",
	"runtime_graph_last_elapsed_us",
	"runtime_graph_last_status",
	"runtime_graph_dirty_mask",
	"runtime_graph_post_pulse_flush_ms",
	"runtime_graph_flush_slot_count",
	"runtime_graph_visual_diff_cell_count",
	"runtime_graph_country_territory_sync_ms",
	"runtime_graph_event_dispatch_ms",
	"runtime_graph_full_flush_count",
	"runtime_graph_simulation_thread_mode",
	"runtime_graph_requested_simulation_thread_mode",
	"runtime_graph_coverage_state",
	"runtime_graph_required_domain_mask",
	"runtime_graph_implemented_domain_mask",
	"runtime_graph_missing_domain_mask",
	"runtime_graph_coverage_blocker",
	"runtime_graph_simulation_worker_ready",
	"runtime_graph_native_executor_workers",
	"runtime_graph_native_executor_interactive",
	"runtime_graph_native_executor_fault_count",
	"runtime_graph_country_pod_active_index_count",
	"runtime_graph_climate_pod_ready",
	"runtime_graph_climate_pod_plan_ms",
	"runtime_graph_climate_pod_replay_ms",
	"runtime_graph_climate_pod_work_units",
	"runtime_graph_climate_pod_changed_cells",
	"runtime_graph_climate_pod_state_hash",
	"runtime_graph_climate_pod_fallback_reason",
	"runtime_graph_climate_trace_depth",
	"runtime_graph_climate_trace_front_day",
	"runtime_graph_climate_trace_lag_days",
	"runtime_graph_climate_trace_latest_hash",
	"runtime_graph_climate_trace_capacity_exceeded",
	"runtime_graph_climate_trace_consumed",
	"runtime_graph_climate_trace_missing",
	"runtime_graph_climate_trace_reference_rejected",
	"runtime_graph_climate_trace_reference_pending",
	"runtime_graph_simulation_host_state",
	"runtime_graph_simulation_committed_day",
	"runtime_graph_simulation_generation",
	"runtime_graph_simulation_time_debt_days",
	"runtime_graph_last_visual_publish_at_us",
	"runtime_graph_snapshot_staleness_ms",
	"runtime_graph_ui_input_to_feedback_ms",
	"runtime_graph_visual_apply_ms",
	"runtime_graph_gpu_upload_ms",
	"runtime_graph_main_wait_on_sim_us",
	"runtime_graph_simulation_environment_generation",
	"runtime_graph_simulation_environment_day",
	"runtime_graph_simulation_environment_cell_count",
	"runtime_graph_simulation_environment_topology_validated",
	"runtime_graph_stale_environment_rejected",
	"runtime_graph_command_queue_depth",
	"runtime_graph_receipt_queue_depth",
	"runtime_graph_snapshot_publish_drop_count",
	"runtime_graph_snapshot_publish_throttled_count",
	"runtime_graph_worker_fault_count",
	"runtime_graph_day_stage_count",
	"runtime_graph_day_completed_stage_count",
	"runtime_graph_day_work_units",
]

# 软上限：避免误开后台跑爆内存。约 60000 帧 ≈ 30 分钟 30FPS。
const HARD_ROW_LIMIT: int = 60000

const JOB_COL_PREFIX: String = "j_"
const JOB_COL_MS_SUFFIX: String = "_ms"
const JOB_COL_SLICES_SUFFIX: String = "_slices"
const JOB_COL_SKIP_SUFFIX: String = "_skip"
const JOB_COL_WORK_SUFFIX: String = "_work_done"
const JOB_COL_PROGRESS_SUFFIX: String = "_progress"
const JOB_COL_STAGE_SUFFIX: String = "_stage"
const JOB_COL_SUBSTAGE_SUFFIX: String = "_substage"
const JOB_COL_PATH_SUFFIX: String = "_path"
const JOB_COL_CELLS_SUFFIX: String = "_processed_cells"
const JOB_COL_PIXELS_SUFFIX: String = "_processed_pixels"
const JOB_COL_INDICES_SUFFIX: String = "_processed_indices"
const JOB_COL_CURSOR_START_SUFFIX: String = "_cursor_start"
const JOB_COL_CURSOR_END_SUFFIX: String = "_cursor_end"
const JOB_COL_FALLBACK_SUFFIX: String = "_fallback"
const JOB_COL_SLICE_ACTUAL_SUFFIX: String = "_slice_actual_ms"
const JOB_COL_SLICE_REPORTED_SUFFIX: String = "_slice_reported_ms"
const JOB_COL_SLICE_REPORTED_GAP_SUFFIX: String = "_slice_reported_gap_ms"
const JOB_COL_SLICE_WRAPPER_WALL_SUFFIX: String = "_slice_wrapper_wall_ms"
const JOB_COL_SLICE_JOB_SHELL_SUFFIX: String = "_slice_job_shell_wall_ms"
const JOB_COL_SLICE_JOB_SHELL_GAP_SUFFIX: String = "_slice_job_shell_wrapper_gap_ms"
const JOB_COL_JOB_WRAPPER_GAP_SUFFIX: String = "_job_wrapper_gap_ms"
const JOB_SUFFIXES: Array = [
	JOB_COL_SLICE_REPORTED_GAP_SUFFIX,
	JOB_COL_SLICE_WRAPPER_WALL_SUFFIX,
	JOB_COL_SLICE_JOB_SHELL_GAP_SUFFIX,
	JOB_COL_SLICE_JOB_SHELL_SUFFIX,
	JOB_COL_SLICE_REPORTED_SUFFIX,
	JOB_COL_SLICE_ACTUAL_SUFFIX,
	JOB_COL_JOB_WRAPPER_GAP_SUFFIX,
	JOB_COL_FALLBACK_SUFFIX,
	JOB_COL_CURSOR_START_SUFFIX,
	JOB_COL_CURSOR_END_SUFFIX,
	JOB_COL_INDICES_SUFFIX,
	JOB_COL_PIXELS_SUFFIX,
	JOB_COL_CELLS_SUFFIX,
	JOB_COL_SUBSTAGE_SUFFIX,
	JOB_COL_PROGRESS_SUFFIX,
	JOB_COL_SLICES_SUFFIX,
	JOB_COL_STAGE_SUFFIX,
	JOB_COL_WORK_SUFFIX,
	JOB_COL_PATH_SUFFIX,
	JOB_COL_SKIP_SUFFIX,
	JOB_COL_MS_SUFFIX,
]
const BD_COL_PREFIX: String = "bd_"
const DESKTOP_EXPORT_DIR_RELATIVE: String = "../../tmp"
const MOBILE_EXPORT_DIR: String = "user://perf"


var _main = null  # 鸭子类型（运行时只 has_method/call 调用）；
                  # 留 untyped 是为了单测可注入 RefCounted Mock 而不必 extends Node。
var _recording: bool = false
var _rows: Array = []
var _start_tick: int = 0
var _hit_limit: bool = false
var _detail_mode: String = "CORE"
var _detail_period_days: int = 30


func bind_main(m) -> void:
	_main = m


func is_recording() -> bool:
	return _recording


func row_count() -> int:
	return _rows.size()


func hit_limit() -> bool:
	return _hit_limit


# 开始录制：清空缓冲。多次调用 start 等价于"丢弃旧录制重开"。
func start(detail_mode: String = "CORE", detail_period_days: int = 30) -> void:
	_rows.clear()
	_recording = true
	_hit_limit = false
	_detail_mode = "DETAIL" if detail_mode.to_upper() == "DETAIL" else "CORE"
	_detail_period_days = maxi(1, detail_period_days)
	if _main != null and _main.has_method("get_fast_tick_count"):
		_start_tick = int(_main.get_fast_tick_count())
	else:
		_start_tick = 0
	print("[perf-record] start (start_tick=%d mode=%s detail_period=%d)" % [
		_start_tick, _detail_mode, _detail_period_days])


# 停止录制并导出。
# 返回 globalize 后的导出路径；失败返回空字符串（push_error 打印细节）。
# 不论成功失败都会把 _recording 置 false；失败时保留 _rows 让用户决定下一步。
func stop_and_export() -> String:
	_recording = false
	if _rows.is_empty():
		print("[perf-record] stop: no rows captured, skip export")
		return ""

	var dt: Dictionary = Time.get_datetime_dict_from_system()
	var export_dir: String = _export_dir_absolute()
	var fname: String = export_dir.path_join("perf_record_%04d%02d%02d_%02d%02d%02d.csv" % [
		int(dt.get("year", 0)), int(dt.get("month", 0)), int(dt.get("day", 0)),
		int(dt.get("hour", 0)), int(dt.get("minute", 0)), int(dt.get("second", 0)),
	])
	# Keep perf CSV outside res:// so Godot does not import it as csv_translation.
	DirAccess.make_dir_recursive_absolute(export_dir)

	var f := FileAccess.open(fname, FileAccess.WRITE)
	if f == null:
		var err: int = FileAccess.get_open_error()
		push_error("[perf-record] open failed path=%s err=%d" % [fname, err])
		return ""

	var columns: PackedStringArray = _collect_columns(_rows)

	# UTF-8 BOM（Excel 友好，能正确识别中文/Emoji；其他工具会忽略）
	f.store_8(0xEF)
	f.store_8(0xBB)
	f.store_8(0xBF)

	# Header
	f.store_line(_format_header_line(columns))

	# Body：逐行写盘，避免大 String 内存峰值
	for i in _rows.size():
		var row: Dictionary = _rows[i]
		f.store_line(_format_row_line(row, columns))

	f.close()

	print("[perf-record] exported rows=%d cols=%d → %s%s" % [
		_rows.size(), columns.size(), fname,
		"  (HIT LIMIT)" if _hit_limit else "",
	])
	# 导出后清空缓冲，避免下次 start 误算（start 会重新 clear，但 stop 后即清更直观）
	_rows.clear()
	_hit_limit = false
	return fname


static func _export_dir_absolute() -> String:
	if OS.has_feature("mobile"):
		return ProjectSettings.globalize_path(MOBILE_EXPORT_DIR).simplify_path()
	return ProjectSettings.globalize_path("res://").path_join(DESKTOP_EXPORT_DIR_RELATIVE).simplify_path()


# main.gd._run_fast_tick() 末尾调用。recorder 自己拉 SUS 数据，sample 只承载
# 那些只有 main 局部知道的字段。
func on_fast_tick(sample: Dictionary) -> void:
	if not _recording:
		return
	if _hit_limit:
		return
	var row: Dictionary = sample.duplicate()

	# 计算 row_idx（录制内序号，从 0 开始；区别于 tick_idx 的全局序号）
	row["row_idx"] = _rows.size()
	var runtime_graph = sample.get("runtime_graph", {})
	if runtime_graph is Dictionary:
		for key in ["pulse_count", "abi_calls", "gdscript_callbacks", "work_done",
				"budget_yields", "economy_slices", "economy_commits",
				"last_elapsed_us", "last_status", "dirty_mask",
				"post_pulse_flush_ms", "flush_slot_count",
				"visual_diff_cell_count", "country_territory_sync_ms",
				"event_dispatch_ms", "full_flush_count",
				"simulation_thread_mode", "graph_coverage_state",
				"requested_simulation_thread_mode", "required_domain_mask",
				"implemented_domain_mask", "missing_domain_mask",
				"coverage_blocker",
				"simulation_worker_ready",
				"native_executor_workers", "native_executor_interactive",
				"native_executor_fault_count", "simulation_host_state",
				"country_pod_active_index_count",
				"climate_pod_ready", "climate_pod_plan_ms",
				"climate_pod_replay_ms", "climate_pod_work_units",
				"climate_pod_changed_cells", "climate_pod_state_hash",
				"climate_pod_fallback_reason",
				"simulation_committed_day", "simulation_generation",
				"simulation_time_debt_days", "last_visual_publish_at_us",
				"snapshot_staleness_ms",
				"ui_input_to_feedback_ms", "visual_apply_ms", "gpu_upload_ms",
				"main_wait_on_sim_us", "simulation_environment_generation",
				"simulation_environment_day", "simulation_environment_cell_count",
				"simulation_environment_topology_validated",
				"stale_environment_rejected", "snapshot_publish_throttled_count",
				"command_queue_depth",
				"receipt_queue_depth", "snapshot_publish_drop_count",
				"worker_fault_count", "day_stage_count",
				"day_completed_stage_count", "day_work_units"]:
			row["runtime_graph_%s" % key] = runtime_graph.get(key, 0)

	# CORE 只保留固定帧/预算/守恒字段。完整 job/breakdown 展开属于 DETAIL，
	# 默认不进入每帧热路径；DETAIL 也按日周期采样，避免重复序列化。
	if _main != null:
		if _main.has_method("get_sus_last_tick_summary"):
			var summary: Dictionary = _main.get_sus_last_tick_summary()
			_merge_summary(row, summary)
		var detail_due := _detail_mode == "DETAIL" and (
			int(sample.get("tick_idx", 0)) % _detail_period_days == 0 or
			bool(sample.get("detail_requested", false)) or
			bool(sample.get("anomaly", false)))
		if detail_due and _main.has_method("get_sus_last_tick_report"):
			var report: Dictionary = _main.get_sus_last_tick_report()
			_merge_jobs(row, report, bool(sample.get("was_skipped_day", false)))
		if detail_due and _main.has_method("get_sim_breakdowns"):
			var bds: Dictionary = _main.get_sim_breakdowns()
			_merge_breakdowns(row, bds)

	_rows.append(row)
	if _rows.size() >= HARD_ROW_LIMIT:
		_hit_limit = true
		_recording = false
		push_warning("[perf-record] hit hard row limit (%d), auto-stop. Press 停止并导出 to flush." % HARD_ROW_LIMIT)


# ---------- 内部：合并器 ----------

# largest_slice_* + sus_sim_p95_300 / sus_sim_max_300 / over_1ms_count_300
func _merge_summary(row: Dictionary, summary: Dictionary) -> void:
	if summary.is_empty():
		return
	for k in [
		"largest_slice_job", "largest_slice_stage", "largest_slice_substage",
		"largest_slice_path", "largest_slice_ms", "largest_slice_work_done",
		"largest_slice_processed_cells", "largest_slice_processed_pixels",
		"largest_slice_processed_indices", "largest_slice_cursor_start",
		"largest_slice_cursor_end", "largest_slice_fallback_path",
		"largest_slice_processed_per_ms", "sus_sim_avg_300", "sus_sim_p95_300",
		"sus_sim_max_300", "over_1ms_count_300", "sim_frame_budget_ms",
		"sim_slice_budget_ms", "sim_upload_slice_budget_ms",
		"sim_strict_budget_enabled", "sim_budget_warn_ms", "economy_reserved_budget_ms",
	]:
		if summary.has(k):
			row[k] = summary[k]


# 跳日帧 SUS 没运行——_last_report 仍是上一非跳日 tick 的内容。为避免污染，
# 跳日帧的 job 列全部留空。
func _merge_jobs(row: Dictionary, report: Dictionary, was_skipped_day: bool) -> void:
	if was_skipped_day or report.is_empty():
		return
	for job_id in report.keys():
		var r: Dictionary = report[job_id]
		var key_ms: String = JOB_COL_PREFIX + str(job_id) + JOB_COL_MS_SUFFIX
		var key_slices: String = JOB_COL_PREFIX + str(job_id) + JOB_COL_SLICES_SUFFIX
		var key_skip: String = JOB_COL_PREFIX + str(job_id) + JOB_COL_SKIP_SUFFIX
		var key_work: String = JOB_COL_PREFIX + str(job_id) + JOB_COL_WORK_SUFFIX
		var key_progress: String = JOB_COL_PREFIX + str(job_id) + JOB_COL_PROGRESS_SUFFIX
		var key_stage: String = JOB_COL_PREFIX + str(job_id) + JOB_COL_STAGE_SUFFIX
		var key_substage: String = JOB_COL_PREFIX + str(job_id) + JOB_COL_SUBSTAGE_SUFFIX
		var key_path: String = JOB_COL_PREFIX + str(job_id) + JOB_COL_PATH_SUFFIX
		var key_cells: String = JOB_COL_PREFIX + str(job_id) + JOB_COL_CELLS_SUFFIX
		var key_pixels: String = JOB_COL_PREFIX + str(job_id) + JOB_COL_PIXELS_SUFFIX
		var key_indices: String = JOB_COL_PREFIX + str(job_id) + JOB_COL_INDICES_SUFFIX
		var key_cursor_start: String = JOB_COL_PREFIX + str(job_id) + JOB_COL_CURSOR_START_SUFFIX
		var key_cursor_end: String = JOB_COL_PREFIX + str(job_id) + JOB_COL_CURSOR_END_SUFFIX
		var key_fallback: String = JOB_COL_PREFIX + str(job_id) + JOB_COL_FALLBACK_SUFFIX
		var key_slice_actual: String = JOB_COL_PREFIX + str(job_id) + JOB_COL_SLICE_ACTUAL_SUFFIX
		var key_slice_reported: String = JOB_COL_PREFIX + str(job_id) + JOB_COL_SLICE_REPORTED_SUFFIX
		var key_slice_reported_gap: String = JOB_COL_PREFIX + str(job_id) + JOB_COL_SLICE_REPORTED_GAP_SUFFIX
		var key_slice_wrapper_wall: String = JOB_COL_PREFIX + str(job_id) + JOB_COL_SLICE_WRAPPER_WALL_SUFFIX
		var key_slice_job_shell: String = JOB_COL_PREFIX + str(job_id) + JOB_COL_SLICE_JOB_SHELL_SUFFIX
		var key_slice_job_shell_gap: String = JOB_COL_PREFIX + str(job_id) + JOB_COL_SLICE_JOB_SHELL_GAP_SUFFIX
		var key_job_wrapper_gap: String = JOB_COL_PREFIX + str(job_id) + JOB_COL_JOB_WRAPPER_GAP_SUFFIX
		row[key_ms] = float(r.get("elapsed_ms", 0.0))
		row[key_slices] = int(r.get("slices_run", 0))
		row[key_skip] = str(r.get("skipped_reason", ""))
		row[key_work] = int(r.get("work_done", r.get("last_slice_work_done", 0)))
		row[key_progress] = float(r.get("progress_ratio", 0.0))
		row[key_stage] = str(r.get("stage", ""))
		row[key_substage] = str(r.get("substage", ""))
		row[key_path] = str(r.get("path", ""))
		row[key_cells] = int(r.get("last_slice_processed_cells", 0))
		row[key_pixels] = int(r.get("last_slice_processed_pixels", 0))
		row[key_indices] = int(r.get("last_slice_processed_indices", 0))
		row[key_cursor_start] = int(r.get("last_slice_cursor_start", -1))
		row[key_cursor_end] = int(r.get("last_slice_cursor_end", -1))
		row[key_fallback] = str(r.get("last_slice_fallback_path", ""))
		row[key_slice_actual] = float(r.get("last_slice_actual_ms", 0.0))
		row[key_slice_reported] = float(r.get("last_slice_reported_ms", 0.0))
		row[key_slice_reported_gap] = float(r.get("last_slice_reported_gap_ms", 0.0))
		row[key_slice_wrapper_wall] = float(r.get("last_slice_wrapper_wall_ms", 0.0))
		row[key_slice_job_shell] = float(r.get("last_slice_job_shell_wall_ms", 0.0))
		row[key_slice_job_shell_gap] = float(r.get("last_slice_job_shell_wrapper_gap_ms", 0.0))
		row[key_job_wrapper_gap] = float(r.get("job_wrapper_gap_ms", 0.0))
		if str(job_id) == "bio_occupancy_daily":
			row["bio_slice_native_ms"] = float(r.get("bio_slice_native_ms", 0.0))
			row["bio_slice_publish_ms"] = float(r.get("bio_slice_publish_ms", 0.0))
			row["bio_knob_cache_hit"] = bool(r.get("bio_knob_cache_hit", false))
			row["bio_knob_cache_build_ms"] = float(r.get("bio_knob_cache_build_ms", 0.0))
			row["bio_slice_fallback_reason"] = str(
				r.get("bio_slice_fallback_reason", r.get("fallback_reason", "")))
		if str(job_id) == "natural_resource_daily":
			row["natural_resource_factor_lookup_ms"] = float(
				r.get("factor_lookup_ms", 0.0))
			row["natural_resource_slot_refresh_ms"] = float(
				r.get("slot_refresh_ms", 0.0))
			row["natural_resource_knob_update_ms"] = float(
				r.get("knob_update_ms", 0.0))
			row["natural_resource_native_call_ms"] = float(
				r.get("native_call_ms", 0.0))
			row["natural_resource_fallback_ms"] = float(r.get("fallback_ms", 0.0))


# breakdowns = { "ui": {...}, "climate": {...}, "weather": {...}, "economy": {...}, ... }
# 每个子 dict 的 key 集合不固定，全部展开为 bd_<group>_<key>。
#
# 方案 ④ Step 1（freshness 过滤）：
#   每个 sub dict 的写入点会打一个 `_tick_idx` 字段。若 sub 的 _tick_idx 与本 row
#   的 tick_idx 不一致 —— 说明本帧没真正刷新过，看到的是 stale 快照回放 ——
#   则整组 sub 字段全部跳过（在 CSV 里留空），避免"305 行重复值"被误读为持续耗时。
#   `_tick_idx` 自身永不写入 CSV（开头判定丢弃，避免污染列表）。
func _merge_breakdowns(row: Dictionary, bds: Dictionary) -> void:
	if bds.is_empty():
		return
	var row_tick: int = int(row.get("tick_idx", -1))
	for group in bds.keys():
		var sub = bds[group]
		if not (sub is Dictionary):
			continue
		var sub_dict: Dictionary = sub as Dictionary
		# Freshness gate：sub 必须显式带 `_tick_idx` 且匹配本 row。
		# - 不带 _tick_idx：兼容旧路径（视为"未追踪 freshness"，照旧写入，避免
		#   未改造点突然全列空白；任何写入点都应在改造完成后带上 _tick_idx）。
		# - 带 _tick_idx 但不等于 row_tick：本帧未刷新，跳过整组。
		if sub_dict.has("_tick_idx"):
			var sub_tick: int = int(sub_dict["_tick_idx"])
			if sub_tick != row_tick:
				continue
		for k in sub_dict.keys():
			var ks: String = str(k)
			# `_tick_idx` 是内部标记，不进 CSV 列。
			if ks == "_tick_idx":
				continue
			var col: String = BD_COL_PREFIX + str(group) + "_" + ks
			var value = sub_dict[k]
			# 原生 atlas 报告会携带完整 LUT。把数千/数万项数组逐 tick 写入 CSV
			# 既放大文件，也会把 Variant -> String 序列化成本记到性能样本本身。
			# 路径、尺寸、刷新耗时等 LUT 标量仍按原名保留；仅摘要容器 payload。
			if _is_lut_payload(ks, value):
				row[col + "_size"] = _collection_size(value)
				row[col + "_hash"] = hash(value)
				row[col + "_summary_version"] = 1
			else:
				row[col] = value
			if str(group) == "country" and ks in [
				"country_report_mode", "country_state_hash_ms",
				"country_report_build_ms", "research_queue_size",
				"research_full_scan_fallbacks", "research_activation_ms",
				"research_allocation_ms", "research_effect_ack_ms",
				"research_discovery_ms", "research_modifier_ms",
				"research_report_ms", "research_countries_scanned",
				"research_active_countries", "research_pending_checks",
				"research_discovery_checks", "research_discovery_frontier_mismatches",
				"research_modifier_queries",
				"research_modifier_cache_hits", "research_remainder_iterations"]:
				# Stable aliases for perf gates; keep bd_country_* for existing
				# consumers and historical CSV compatibility.
				row[ks] = value
			if str(group) == "economy" and ks in [
				"prepare_reuse_count", "workset_cells_planned",
				"workset_cells_executed", "duplicate_range_count",
				"household_market_prepare_ms", "household_market_worker_ms",
				"household_market_merge_ms"]:
				# Keep the exact plan field names as stable top-level CSV aliases;
				# the bd_economy_* columns remain available for historical consumers.
				row[ks] = value
		if str(group) == "economy" and bool(sub_dict.get(
				"last_completed_perf_valid", false)):
			# Performance gates compare completed epochs, not whichever in-flight
			# stage happened to be sampled at the fast-tick boundary.
			var completed_aliases := {
				"prepare_reuse_count": "last_completed_prepare_reuse_count",
				"workset_cells_planned": "last_completed_workset_cells_planned",
				"workset_cells_executed": "last_completed_workset_cells_executed",
				"duplicate_range_count": "last_completed_duplicate_range_count",
				"household_market_prepare_ms":
					"last_completed_household_market_prepare_ms",
				"household_market_worker_ms":
					"last_completed_household_market_worker_ms",
				"household_market_merge_ms":
					"last_completed_household_market_merge_ms",
			}
			for alias in completed_aliases:
				var completed_key: String = completed_aliases[alias]
				if sub_dict.has(completed_key):
					row[alias] = sub_dict[completed_key]


static func _is_lut_payload(key: String, value) -> bool:
	if key.to_lower().find("lut") == -1:
		return false
	var value_type: int = typeof(value)
	return value_type == TYPE_ARRAY \
		or value_type == TYPE_PACKED_BYTE_ARRAY \
		or value_type == TYPE_PACKED_INT32_ARRAY \
		or value_type == TYPE_PACKED_INT64_ARRAY \
		or value_type == TYPE_PACKED_FLOAT32_ARRAY \
		or value_type == TYPE_PACKED_FLOAT64_ARRAY \
		or value_type == TYPE_PACKED_COLOR_ARRAY \
		or value_type == TYPE_PACKED_VECTOR2_ARRAY \
		or value_type == TYPE_PACKED_VECTOR3_ARRAY \
		or value_type == TYPE_PACKED_VECTOR4_ARRAY


static func _collection_size(value) -> int:
	return int(value.size())


# ---------- 静态：列并集 / CSV 拼装 ----------

# 收集所有出现过的列名：固定列 → job 列（按首次出现顺序，且按 ms/slices/skip 三元组聚簇） → bd 列。
static func _collect_columns(rows: Array) -> PackedStringArray:
	var out: PackedStringArray = PackedStringArray()
	var seen: Dictionary = {}

	# Phase 1：固定列
	for c in FIXED_COLUMNS:
		out.append(c)
		seen[c] = true

	# Phase 2：扫描 rows，按首次出现顺序收集 job 与 bd 的"基名"（不含 job 后缀）
	var job_bases: Array = []
	var job_base_seen: Dictionary = {}
	var bd_keys: Array = []
	var bd_key_seen: Dictionary = {}

	for row in rows:
		var d: Dictionary = row
		for k in d.keys():
			var ks: String = str(k)
			if seen.has(ks):
				continue
			if ks.begins_with(JOB_COL_PREFIX):
				# 找最长后缀匹配，避免 _cursor_start 被 _stage 之类短后缀误伤。
				var base: String = ""
				for suffix in JOB_SUFFIXES:
					var suffix_s: String = str(suffix)
					if ks.ends_with(suffix_s):
						base = ks.substr(0, ks.length() - suffix_s.length())
						break
				if base != "" and not job_base_seen.has(base):
					job_base_seen[base] = true
					job_bases.append(base)
			elif ks.begins_with(BD_COL_PREFIX):
				if not bd_key_seen.has(ks):
					bd_key_seen[ks] = true
					bd_keys.append(ks)

	# Phase 3：每个 job_base 输出固定聚簇列
	for base in job_bases:
		out.append(base + JOB_COL_MS_SUFFIX)
		out.append(base + JOB_COL_SLICES_SUFFIX)
		out.append(base + JOB_COL_SKIP_SUFFIX)
		out.append(base + JOB_COL_WORK_SUFFIX)
		out.append(base + JOB_COL_PROGRESS_SUFFIX)
		out.append(base + JOB_COL_STAGE_SUFFIX)
		out.append(base + JOB_COL_SUBSTAGE_SUFFIX)
		out.append(base + JOB_COL_PATH_SUFFIX)
		out.append(base + JOB_COL_CELLS_SUFFIX)
		out.append(base + JOB_COL_PIXELS_SUFFIX)
		out.append(base + JOB_COL_INDICES_SUFFIX)
		out.append(base + JOB_COL_CURSOR_START_SUFFIX)
		out.append(base + JOB_COL_CURSOR_END_SUFFIX)
		out.append(base + JOB_COL_FALLBACK_SUFFIX)
		out.append(base + JOB_COL_SLICE_ACTUAL_SUFFIX)
		out.append(base + JOB_COL_SLICE_REPORTED_SUFFIX)
		out.append(base + JOB_COL_SLICE_REPORTED_GAP_SUFFIX)
		out.append(base + JOB_COL_SLICE_WRAPPER_WALL_SUFFIX)
		out.append(base + JOB_COL_SLICE_JOB_SHELL_SUFFIX)
		out.append(base + JOB_COL_SLICE_JOB_SHELL_GAP_SUFFIX)
		out.append(base + JOB_COL_JOB_WRAPPER_GAP_SUFFIX)

	# Phase 4：bd 列
	for k in bd_keys:
		out.append(k)

	return out


static func _format_header_line(columns: PackedStringArray) -> String:
	var parts: PackedStringArray = PackedStringArray()
	for c in columns:
		parts.append(_csv_escape(c))
	return ",".join(parts)


static func _format_row_line(row: Dictionary, columns: PackedStringArray) -> String:
	var parts: PackedStringArray = PackedStringArray()
	for c in columns:
		if row.has(c):
			parts.append(_csv_escape(row[c]))
		else:
			parts.append("")  # 缺失值留空字符串
	return ",".join(parts)


# RFC 4180 转义：
#   - 数字 → 直接 str()（GDScript float 默认精度足够分析；不强行限位）
#   - bool → "true" / "false"
#   - 字符串：含 ',' '"' '\n' '\r' 时加双引号包裹，内部 '"' 翻倍
static func _csv_escape(value) -> String:
	var s: String = ""
	var t: int = typeof(value)
	if t == TYPE_NIL:
		return ""
	elif t == TYPE_BOOL:
		s = "true" if bool(value) else "false"
	elif t == TYPE_INT:
		s = str(int(value))
	elif t == TYPE_FLOAT:
		# 保留 6 位小数，去尾零；NaN / INF 转空，避免 Excel 报错
		var fv: float = float(value)
		if is_nan(fv) or is_inf(fv):
			return ""
		s = ("%.6f" % fv).rstrip("0").rstrip(".")
		if s == "" or s == "-":
			s = "0"
	else:
		s = str(value)

	# 是否需要转义
	if s.find(",") != -1 or s.find("\"") != -1 or s.find("\n") != -1 or s.find("\r") != -1:
		s = s.replace("\"", "\"\"")
		return "\"" + s + "\""
	return s
