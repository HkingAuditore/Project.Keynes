extends PanelContainer

## Snapshot and recorder controls shared by the developer console and player GM panel.

const RecordingPage = preload("res://scripts/ui/debug_console_recording_page.gd")
const DebugPerformanceSnapshot = preload("res://scripts/ui/debug_performance_snapshot.gd")

enum ConsoleMode {
	LEGACY_DEBUG_LAB,
	PLAYER_GM,
}

# 主场景引用（提供 getter 读取运行时状态；所有回调都通过它调用 main 的方法）
var _main: Node = null
@export var console_mode: ConsoleMode = ConsoleMode.LEGACY_DEBUG_LAB
var _gm_command_output: RichTextLabel
var _gm_output_lines: Array = []
var _gm_record_status_labels: Dictionary = {}
var _snapshot_btn: Button

# 性能录制按钮 + 录制器实例（与 _pause_btn / _snapshot_btn 同行展示）。
# _perf_recorder 在 set_main() 时创建并注入到 _main，避免与 main 自己生命周期解耦。
const PerfRecorderScript = preload("res://scripts/ui/perf_recorder.gd")
const TileDataRecorderScript = preload("res://scripts/ui/tile_data_recorder.gd")
const EconomyDataRecorderScript = preload("res://scripts/ui/economy_data_recorder.gd")

var _record_btn: Button
var _perf_recorder: RefCounted = null
var _tile_record_btn: Button
var _tile_data_recorder: RefCounted = null
var _economy_record_btn: Button
var _economy_record_checkboxes: Dictionary = {}
var _economy_current_cell_checkbox: CheckBox
var _economy_data_recorder: RefCounted = null
var _atlas_river_probe_dump_btn: Button
var _atlas_river_probe_status_label: Label
var _open_log_dir_btn: Button
var _open_log_dir_label: Label
var _log_dir_opener: Callable

# _show_record_toast 期间冻结 _refresh_record_btn_text，避免 timer 把绿色提示文本盖回去
var _record_btn_toast_until_msec: int = 0
var _tile_record_btn_toast_until_msec: int = 0


func _build_gm_recording_page(parent: Control) -> void:
	RecordingPage._build_gm_recording_page(self, parent)


func _append_gm_output(message: String, is_error: bool) -> void:
	if message == "":
		return
	_gm_output_lines.append("[错误] %s" % message if is_error else message)
	while _gm_output_lines.size() > 100:
		_gm_output_lines.pop_front()
	if _gm_command_output != null:
		_gm_command_output.text = "\n".join(PackedStringArray(_gm_output_lines))


func _on_gm_recorder_pressed(recorder_id: String, callback: Callable, button: Button) -> void:
	callback.call()
	var result_text := _gm_sanitize_legacy_status(button.text)
	IconButton.apply(button, &"action.history", 15)
	if result_text.length() > 1:
		_append_gm_output(result_text, false)
	_refresh_gm_recorders()


func _on_gm_snapshot_pressed() -> void:
	_on_btn_snapshot()
	var result_text := _gm_sanitize_legacy_status(_snapshot_btn.text)
	IconButton.apply(_snapshot_btn, &"action.save", 15)
	if result_text.length() > 1:
		_append_gm_output(result_text, result_text.contains("失败"))


# render-profile dump 不绑热键：统一走 GM「记录」页按钮，实现由运行时宿主
# （WorldRuntimeHost.dump_render_profile）提供，与录制器按钮同一套鸭子类型约定。
func _on_gm_render_profile_pressed() -> void:
	if _main == null or not _main.has_method("dump_render_profile"):
		_append_gm_output("当前运行时不支持 render-profile dump", true)
		return
	_append_gm_output("render-profile：开始采样 120 帧（约数秒）…", false)
	var result = await _main.call("dump_render_profile")
	if result is Dictionary and bool(result.get("ok", false)):
		_append_gm_output("render-profile 已写出：%s" % String(result.get("txt_path", "")), false)
	elif result is Dictionary:
		_append_gm_output("render-profile 写出失败：%s" % String(result.get("error", "未知错误")), true)
	else:
		_append_gm_output("render-profile：采样完成（控制台输出）", false)


func _on_gm_atlas_river_probe_record_pressed() -> void:
	if _main == null or not _main.has_method("execute_gm_command"):
		_append_gm_output("运行时不支持 Atlas 河谷采样", true)
		return
	var state: Dictionary = _main.call("get_gm_toggle_state", "diagnostics.atlas_river_probe")
	var recording := bool(state.get("enabled", false))
	var next_state: Dictionary = _main.call("set_gm_toggle", "diagnostics.atlas_river_probe", not recording)
	if not bool(next_state.get("ok", false)):
		_append_gm_output(String(next_state.get("message", next_state.get("code", "Atlas 采样状态更新失败"))), true)
		return
	if not recording:
		_append_gm_output("Atlas 河谷采样已开始；再次点击停止并导出", false)
	else:
		var result: Dictionary = _main.call("execute_gm_command", "diagnostics.dump_atlas_river_probe", {})
		if bool(result.get("ok", false)):
			_append_gm_output("Atlas 河谷采样已导出：%s（%d 行）" % [
				String(result.get("path", "")), int(result.get("rows", 0))], false)
		else:
			_append_gm_output(String(result.get("message", result.get("code", "导出失败"))), true)
	_refresh_gm_atlas_river_probe_status()


static func _resolve_log_output_dir() -> String:
	var log_path := String(
		ProjectSettings.get_setting("debug/file_logging/log_path", "user://logs/godot.log")
	).strip_edges()
	if log_path.is_empty():
		log_path = "user://logs/godot.log"
	var log_dir := log_path.get_base_dir()
	if log_dir.is_empty():
		log_dir = "user://logs"
	return ProjectSettings.globalize_path(log_dir).simplify_path()


func _on_gm_open_log_dir_pressed() -> void:
	var log_dir := _resolve_log_output_dir()
	DirAccess.make_dir_recursive_absolute(log_dir)
	var err: Error = OK
	if _log_dir_opener.is_valid():
		err = int(_log_dir_opener.call(log_dir)) as Error
	elif OS.has_feature("mobile"):
		DisplayServer.clipboard_set(log_dir)
		if _open_log_dir_label != null:
			_open_log_dir_label.text = "打开日志文件夹 · 路径已复制"
		_append_gm_output("日志文件夹路径已复制：%s" % log_dir, false)
		return
	else:
		err = OS.shell_open(log_dir)
	if err == OK:
		if _open_log_dir_label != null:
			_open_log_dir_label.text = "打开日志文件夹 · 已打开"
		_append_gm_output("已打开日志文件夹：%s" % log_dir, false)
	else:
		if _open_log_dir_label != null:
			_open_log_dir_label.text = "打开日志文件夹 · 失败 (%d)" % err
		_append_gm_output("打开日志文件夹失败（err=%d）：%s" % [err, log_dir], true)


func _refresh_gm_atlas_river_probe_status() -> void:
	if _atlas_river_probe_status_label == null or _main == null:
		return
	var state: Dictionary = _main.call("get_gm_toggle_state", "diagnostics.atlas_river_probe")
	if not bool(state.get("ok", false)):
		_atlas_river_probe_status_label.text = "Atlas 河谷采样 · 不可用"
		return
	var recording := bool(state.get("enabled", false))
	var rows := int(state.get("sample_count", 0))
	_atlas_river_probe_status_label.text = "Atlas 河谷采样 · %s · %d/64 行" % [
		"录制中" if recording else "已停止", rows]
	_atlas_river_probe_status_label.add_theme_color_override("font_color",
		UITokens.WARN if recording else UITokens.TEXT_MAIN)


func _refresh_gm_recorders() -> void:
	_refresh_gm_atlas_river_probe_status()
	var recorder_map := {
		"performance": _perf_recorder,
		"tiles": _tile_data_recorder,
		"economy": _economy_data_recorder,
	}
	var names := {"performance": "性能采样", "tiles": "地块全量", "economy": "经济周期"}
	for key in recorder_map.keys():
		var recorder: RefCounted = recorder_map[key]
		var label := _gm_record_status_labels.get(key) as Label
		if label == null:
			continue
		var recording := recorder != null and recorder.has_method("is_recording") and bool(recorder.call("is_recording"))
		var rows := int(recorder.call("row_count")) if recorder != null and recorder.has_method("row_count") else 0
		label.text = "%s · %s · %d 行" % [names[key], "录制中" if recording else "已停止", rows]
		label.add_theme_color_override("font_color", UITokens.WARN if recording else UITokens.TEXT_MAIN)
	for button in [_record_btn, _tile_record_btn, _economy_record_btn]:
		if button != null:
			IconButton.apply(button, &"action.history", 15)


func _gm_sanitize_legacy_status(text: String) -> String:
	var result := text
	for marker in ["⏹", "⏺", "⏳", "⏸", "📸", "⚠", "✓", "→"]:
		result = result.replace(marker, "")
	return result.strip_edges()


# 把当前所有性能数据 dump 成 JSON 文件，便于事后分析 / 跨会话比对。
# 路径：res://tmp/perf_snapshot_YYYYMMDD_HHMMSS.json
# 内容：last_tick summary + per-job + 30-tick 窗口统计 + breakdowns + overlay
func _on_btn_snapshot() -> void:
	if _main == null:
		return
	var dt: Dictionary = Time.get_datetime_dict_from_system()
	var fname: String = "res://tmp/perf_snapshot_%04d%02d%02d_%02d%02d%02d.json" % [
		int(dt.get("year", 0)), int(dt.get("month", 0)), int(dt.get("day", 0)),
		int(dt.get("hour", 0)), int(dt.get("minute", 0)), int(dt.get("second", 0)),
	]
	# 兜底：保证 tmp/ 目录存在（项目里已 commit，但留个保险）
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://tmp"))

	var payload: Dictionary = _build_snapshot_payload()
	var f := FileAccess.open(fname, FileAccess.WRITE)
	if f == null:
		var err := FileAccess.get_open_error()
		push_warning("[DebugConsole] 快照写入失败：%s (err=%d)" % [fname, err])
		_show_snapshot_toast("写入失败 err=%d" % err, true)
		return
	# 采样窗口为空时 avg/min/max 可能是 NaN/INF；JSON.stringify 会把它们写成
	# null 并只报一次警告，事后无法知道是哪个指标。这里替换成 null 并指出键路径。
	var non_finite_paths: Array = []
	var safe_payload = DebugPerformanceSnapshot.sanitize_non_finite(payload, "$", non_finite_paths)
	if not non_finite_paths.is_empty():
		push_warning("[PerfSnapshot] non-finite float replaced with null at %s"
			% ", ".join(PackedStringArray(non_finite_paths.slice(0, 4))))
	f.store_string(JSON.stringify(safe_payload, "  "))
	f.close()

	# 转成绝对路径打印到控制台（res:// 在 dev 下 = 项目根目录）
	var abs_path: String = ProjectSettings.globalize_path(fname)
	print_rich("[color=cyan][PerfSnapshot][/color] saved to %s" % abs_path)
	_show_snapshot_toast("已保存：%s" % fname.get_file(), false)


func _build_snapshot_payload() -> Dictionary:
	var out: Dictionary = {
		"timestamp": Time.get_datetime_string_from_system(),
		"frame": Engine.get_frames_drawn(),
		"fps": Engine.get_frames_per_second(),
	}
	if _main.has_method("get_sus_last_tick_summary"):
		out["sus_last_tick_summary"] = _main.call("get_sus_last_tick_summary")
	if _main.has_method("get_sus_last_tick_report"):
		out["sus_last_tick_jobs"] = _main.call("get_sus_last_tick_report")
	if _main.has_method("get_sim_breakdowns"):
		out["sim_breakdowns"] = _main.call("get_sim_breakdowns")
	if _main.has_method("get_environment_perf_summary"):
		out["environment_perf_summary"] = _main.call("get_environment_perf_summary")
	if _main.has_method("get_fast_tick_count"):
		out["fast_tick_count"] = _main.call("get_fast_tick_count")
	if _main.has_method("get_last_fast_tick_ms"):
		out["fast_tick_last_ms"] = _main.call("get_last_fast_tick_ms")
	if _main.has_method("get_overlay_last_bake_ms"):
		out["overlay_last_bake_ms"] = _main.call("get_overlay_last_bake_ms")
	if _main.has_method("get_overlay_stats"):
		out["overlay_stats"] = _main.call("get_overlay_stats")

	# SUS 滚动统计（30-tick 窗口）：从 generator 透传到 sus_scheduler
	var gen = _get_generator()
	if gen != null:
		if gen.has_method("sus_report_job_stats"):
			out["sus_job_stats_window"] = gen.sus_report_job_stats()
		if gen.has_method("sus_report_skipped_summary"):
			out["sus_skipped_summary"] = gen.sus_report_skipped_summary()
		if gen.has_method("sus_report_sim_budget_window"):
			out["sus_sim_budget_window"] = gen.sus_report_sim_budget_window()
	return out


func _show_snapshot_toast(msg: String, is_error: bool) -> void:
	if console_mode == ConsoleMode.PLAYER_GM:
		_append_gm_output(msg, is_error)
		IconButton.apply(_snapshot_btn, &"action.save", 15)
		return
	if _snapshot_btn == null:
		return
	var prev: String = "📸 快照→文件"
	IconButton.apply_with_text(_snapshot_btn, (&"status.warning" if is_error else &"action.confirm"), _gm_sanitize_legacy_status(("⚠ " if is_error else "✓ ") + msg), 14)
	if is_error:
		_snapshot_btn.add_theme_color_override("font_color", Color(0.98, 0.45, 0.30))
	else:
		_snapshot_btn.add_theme_color_override("font_color", Color(0.55, 0.95, 0.55))
	var t := get_tree().create_timer(2.0)
	t.timeout.connect(func() -> void:
		if _snapshot_btn != null and is_instance_valid(_snapshot_btn):
			IconButton.apply_with_text(_snapshot_btn, &"action.save", _gm_sanitize_legacy_status(prev), 14)
			_snapshot_btn.remove_theme_color_override("font_color")
	)


# 录制按钮按下：
#   - 未录制 → start：清空缓冲，按钮变红
#   - 录制中 → stop_and_export：写 CSV，按钮 2 秒绿色提示路径，再回到默认态
func _on_btn_toggle_record() -> void:
	if _perf_recorder == null:
		return
	if _perf_recorder.has_method("is_recording") and bool(_perf_recorder.call("is_recording")):
		var path: String = ""
		if _perf_recorder.has_method("stop_and_export"):
			path = String(_perf_recorder.call("stop_and_export"))
		if path == "":
			_show_record_toast("导出失败（无数据或写盘失败）", true)
		else:
			# 截短路径：只显示文件名部分，避免按钮被撑爆
			var fname: String = path.get_file()
			_show_record_toast("已导出 " + fname, false)
	else:
		if _perf_recorder.has_method("start"):
			# Production capture uses the compact CORE schema. DETAIL remains
			# available for explicit forensic recordings and legacy callers.
			_perf_recorder.call("start", "CORE")
		_refresh_record_btn_text(true)


# 录制按钮文案随状态/帧数刷新；force=true 时立即更新（按下瞬间），
# 否则由 _telemetry_timer 每 2 秒 tick 顺带刷新。
# Toast 期间（_record_btn_toast_until_msec > now）冻结刷新，避免覆盖绿色提示。
func _refresh_record_btn_text(force: bool = false) -> void:
	if _record_btn == null or _perf_recorder == null:
		return
	if console_mode == ConsoleMode.PLAYER_GM:
		IconButton.apply(_record_btn, &"action.history", 15)
		return
	if not force and Time.get_ticks_msec() < _record_btn_toast_until_msec:
		return
	var recording: bool = false
	if _perf_recorder.has_method("is_recording"):
		recording = bool(_perf_recorder.call("is_recording"))
	if recording:
		var n: int = 0
		if _perf_recorder.has_method("row_count"):
			n = int(_perf_recorder.call("row_count"))
		IconButton.apply_with_text(_record_btn, &"action.history", _gm_sanitize_legacy_status("⏹ 停止并导出（已录 %d 帧）" % n), 14)
		_record_btn.add_theme_color_override("font_color", Color(0.98, 0.45, 0.45))
	else:
		IconButton.apply_with_text(_record_btn, &"action.history", _gm_sanitize_legacy_status("⏺ 开始录制"), 14)
		_record_btn.remove_theme_color_override("font_color")


func _show_record_toast(msg: String, is_error: bool) -> void:
	if console_mode == ConsoleMode.PLAYER_GM:
		_append_gm_output(msg, is_error)
		IconButton.apply(_record_btn, &"action.history", 15)
		return
	if _record_btn == null:
		return
	IconButton.apply_with_text(_record_btn, (&"status.warning" if is_error else &"action.confirm"), _gm_sanitize_legacy_status(("⚠ " if is_error else "✓ ") + msg), 14)
	if is_error:
		_record_btn.add_theme_color_override("font_color", Color(0.98, 0.45, 0.30))
	else:
		_record_btn.add_theme_color_override("font_color", Color(0.55, 0.95, 0.55))
	# 2 秒内冻结 _refresh_record_btn_text，让绿色提示稳定显示
	_record_btn_toast_until_msec = Time.get_ticks_msec() + 2000
	var t := get_tree().create_timer(2.0)
	t.timeout.connect(func() -> void:
		if _record_btn != null and is_instance_valid(_record_btn):
			_record_btn.remove_theme_color_override("font_color")
			_refresh_record_btn_text(true)
	)


# 地块数据录制按钮按下：
#   - 未录制 → start：打开 CSV 并写 header
#   - 录制中 → stop_and_export：关闭文件，按钮短暂显示导出结果
func _on_btn_toggle_tile_record() -> void:
	if _tile_data_recorder == null:
		return
	if _tile_data_recorder.has_method("is_recording") and bool(_tile_data_recorder.call("is_recording")):
		var path: String = ""
		if _tile_data_recorder.has_method("stop_and_export"):
			path = String(_tile_data_recorder.call("stop_and_export"))
		if path == "":
			_show_tile_record_toast("导出失败（无数据或写盘失败）", true)
		else:
			_show_tile_record_toast("已导出 " + path.get_file(), false)
	else:
		if _tile_data_recorder.has_method("start"):
			_tile_data_recorder.call("start")
		_refresh_tile_record_btn_text(true)


func _refresh_tile_record_btn_text(force: bool = false) -> void:
	if _tile_record_btn == null or _tile_data_recorder == null:
		return
	if console_mode == ConsoleMode.PLAYER_GM:
		IconButton.apply(_tile_record_btn, &"action.history", 15)
		return
	if not force and Time.get_ticks_msec() < _tile_record_btn_toast_until_msec:
		return
	var recording: bool = false
	if _tile_data_recorder.has_method("is_recording"):
		recording = bool(_tile_data_recorder.call("is_recording"))
	if recording:
		var ticks: int = 0
		var recorded_ticks: int = 0
		var rows: int = 0
		var stride_txt: String = ""
		var last_ms: float = 0.0
		var detail_txt: String = ""
		if _tile_data_recorder.has_method("tick_count"):
			ticks = int(_tile_data_recorder.call("tick_count"))
		if _tile_data_recorder.has_method("recorded_tick_count"):
			recorded_ticks = int(_tile_data_recorder.call("recorded_tick_count"))
		if _tile_data_recorder.has_method("row_count"):
			rows = int(_tile_data_recorder.call("row_count"))
		if _tile_data_recorder.has_method("sampling_summary"):
			var summary: Dictionary = _tile_data_recorder.call("sampling_summary")
			stride_txt = " / t%d c%d" % [
				int(summary.get("tick_stride", 1)),
				int(summary.get("cell_stride", 1)),
			]
			last_ms = float(summary.get("last_tick_ms", 0.0))
			detail_txt = " f%.1f/w%.1f" % [
				float(summary.get("last_tick_format_ms", 0.0)),
				float(summary.get("last_tick_flush_ms", 0.0)),
			]
		IconButton.apply_with_text(_tile_record_btn, &"action.history", _gm_sanitize_legacy_status("⏹ 停止并导出（全量 %d/%d 帧 / %d 行%s / %.1fms%s）" % [
			recorded_ticks, ticks, rows, stride_txt, last_ms, detail_txt,
		]), 14)
		_tile_record_btn.add_theme_color_override("font_color", Color(0.98, 0.45, 0.45))
	else:
		IconButton.apply_with_text(_tile_record_btn, &"action.history", _gm_sanitize_legacy_status("⏺ 开始地块全量录制"), 14)
		_tile_record_btn.remove_theme_color_override("font_color")


func _show_tile_record_toast(msg: String, is_error: bool) -> void:
	if console_mode == ConsoleMode.PLAYER_GM:
		_append_gm_output(msg, is_error)
		IconButton.apply(_tile_record_btn, &"action.history", 15)
		return
	if _tile_record_btn == null:
		return
	IconButton.apply_with_text(_tile_record_btn, (&"status.warning" if is_error else &"action.confirm"), _gm_sanitize_legacy_status(("⚠ " if is_error else "✓ ") + msg), 14)
	if is_error:
		_tile_record_btn.add_theme_color_override("font_color", Color(0.98, 0.45, 0.30))
	else:
		_tile_record_btn.add_theme_color_override("font_color", Color(0.55, 0.95, 0.55))
	_tile_record_btn_toast_until_msec = Time.get_ticks_msec() + 2000
	var t := get_tree().create_timer(2.0)
	t.timeout.connect(func() -> void:
		if _tile_record_btn != null and is_instance_valid(_tile_record_btn):
			_tile_record_btn.remove_theme_color_override("font_color")
			_refresh_tile_record_btn_text(true)
	)


# 经济录制维度开关（录制中改会被忽略，start 时生效）
func _on_economy_dim_toggled(dim_key: String, chk: CheckBox) -> void:
	if _economy_data_recorder == null:
		return
	var pressed: bool = chk.button_pressed
	match dim_key:
		"summary":
			_economy_data_recorder.call("set_record_summary", pressed)
		"cohorts":
			_economy_data_recorder.call("set_record_cohorts", pressed)
		"buildings":
			_economy_data_recorder.call("set_record_buildings", pressed)
		"resources":
			_economy_data_recorder.call("set_record_resources", pressed)
		"market":
			_economy_data_recorder.call("set_record_market", pressed)


func _on_economy_scope_toggled() -> void:
	if _economy_data_recorder == null or _economy_current_cell_checkbox == null:
		return
	_economy_data_recorder.call(
		"set_current_cell_only", _economy_current_cell_checkbox.button_pressed)


func _on_btn_toggle_economy_record() -> void:
	if _economy_data_recorder == null:
		return
	var summary: Dictionary = _economy_data_recorder.call("sampling_summary") \
		if _economy_data_recorder.has_method("sampling_summary") else {}
	var state: String = str(summary.get("state", "idle"))
	if state == "draining" or state == "opening":
		_show_economy_record_toast("后台正在收尾，请稍候", false)
		return
	if state == "recording":
		if _economy_data_recorder.has_method("stop_and_export"):
			_economy_data_recorder.call("stop_and_export")
		_show_economy_record_toast("已停止抓取，后台正在写完剩余批次", false)
	else:
		if _economy_data_recorder.has_method("start"):
			_economy_data_recorder.call("start")
		_refresh_economy_record_btn_text(true)


func _refresh_economy_record_btn_text(force: bool = false) -> void:
	if _economy_record_btn == null or _economy_data_recorder == null:
		return
	if console_mode == ConsoleMode.PLAYER_GM:
		IconButton.apply(_economy_record_btn, &"action.history", 15)
		return
	var summary: Dictionary = _economy_data_recorder.call("sampling_summary") \
		if _economy_data_recorder.has_method("sampling_summary") else {}
	var state: String = str(summary.get("state", "idle"))
	var captured_epochs: int = int(summary.get("captured_epochs", 0))
	var written_epochs: int = int(summary.get("written_epochs", 0))
	var rows: int = int(summary.get("captured_rows", 0))
	var queue: int = int(summary.get("queued_batches", 0))
	var capture_ms: float = float(summary.get("capture_ms_last", 0.0))
	var current_cell_only: bool = bool(summary.get("current_cell_only", false))
	var selected_cell_index: int = int(summary.get("selected_cell_index", -1))
	if _economy_current_cell_checkbox != null:
		_economy_current_cell_checkbox.disabled = state in ["opening", "recording", "draining"]
	if state == "recording":
		var scope_text: String = "地块 #%d，" % selected_cell_index \
			if current_cell_only else "全图，"
		IconButton.apply_with_text(_economy_record_btn, &"action.history", _gm_sanitize_legacy_status("⏹ 停止并导出（%s抓取 %d / 写入 %d epoch，%d 行，队列 %d，%.1fms）" % [
			scope_text, captured_epochs, written_epochs, rows, queue, capture_ms,
		]), 14)
		_economy_record_btn.add_theme_color_override("font_color", Color(0.98, 0.45, 0.45))
	elif state == "draining" or state == "opening":
		IconButton.apply_with_text(_economy_record_btn, &"action.history", _gm_sanitize_legacy_status("⏳ 正在后台收尾（写入 %d/%d epoch，队列 %d）" % [
			written_epochs, captured_epochs, queue,
		]), 14)
		_economy_record_btn.add_theme_color_override("font_color", Color(0.95, 0.75, 0.30))
	elif state == "error":
		var error_label: String = str(summary.get("error_message", ""))
		if error_label == "":
			error_label = str(summary.get("error_code", "write_failed"))
		IconButton.apply_with_text(_economy_record_btn, &"action.history", _gm_sanitize_legacy_status("⚠ 录制停止：%s（点击重新开始）" % error_label), 14)
		_economy_record_btn.add_theme_color_override("font_color", Color(0.98, 0.45, 0.30))
	elif state == "completed":
		var path_count: int = (summary.get("paths", PackedStringArray()) as PackedStringArray).size()
		IconButton.apply_with_text(_economy_record_btn, &"action.history", _gm_sanitize_legacy_status("✓ 已导出 %d 个 CSV（点击重新开始）" % path_count), 14)
		_economy_record_btn.add_theme_color_override("font_color", Color(0.55, 0.95, 0.55))
	else:
		IconButton.apply_with_text(_economy_record_btn, &"action.history", _gm_sanitize_legacy_status("⏺ 开始经济数据录制"), 14)
		_economy_record_btn.remove_theme_color_override("font_color")


func _show_economy_record_toast(msg: String, is_error: bool) -> void:
	if console_mode == ConsoleMode.PLAYER_GM:
		_append_gm_output(msg, is_error)
		IconButton.apply(_economy_record_btn, &"action.history", 15)
		return
	if _economy_record_btn == null:
		return
	IconButton.apply_with_text(_economy_record_btn, (&"status.warning" if is_error else &"action.confirm"), _gm_sanitize_legacy_status(("⚠ " if is_error else "✓ ") + msg), 14)
	if is_error:
		_economy_record_btn.add_theme_color_override("font_color", Color(0.98, 0.45, 0.30))
	else:
		_economy_record_btn.add_theme_color_override("font_color", Color(0.55, 0.95, 0.55))
	var t := get_tree().create_timer(2.0)
	t.timeout.connect(func() -> void:
		if _economy_record_btn != null and is_instance_valid(_economy_record_btn):
			_economy_record_btn.remove_theme_color_override("font_color")
			_refresh_economy_record_btn_text(true)
	)


func _get_generator():
	if _main == null:
		return null
	if _main.has_method("get_generator"):
		return _main.call("get_generator")
	return null
