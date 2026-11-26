extends "res://scripts/ui/debug_console_recorders.gd"

## Developer overlay, simulation switches, and live telemetry.

# 信号：其它子系统不直接引用 DebugConsole 的按钮/下拉，通过信号解耦。
signal overlay_mode_changed(mode: int)
signal overlay_alpha_changed(alpha: float)

const ConsolePresentation = preload("res://scripts/ui/debug_console_presentation.gd")

# --- 内部 UI 节点缓存 -----------------------------------------------------
var _overlay_option_btn: OptionButton
var _overlay_alpha_slider: HSlider
var _overlay_alpha_label: Label
var _overlay_error_label: Label
var _tod_mode_label: Label
var _tod_light_angle_slider: HSlider
var _tod_light_angle_label: Label
var _tod_light_elevation_slider: HSlider
var _tod_light_elevation_label: Label
var _tod_sun_height_scale_slider: HSlider
var _tod_sun_height_scale_label: Label
var _tod_sun_position_label: Label

# 模拟开关：key=ClimateProfile 字段名，value=CheckBox
var _sim_checkboxes: Dictionary = {}

# 视觉开关：key=ClimateProfile 无关，直接 main.gd.@export 字段名，value=CheckBox
var _visual_checkboxes: Dictionary = {}

# 性能 / 渲染实验 toggle 开关：key=get_debug_toggle_state 的 state key，value=CheckBox
var _toggle_checkboxes: Dictionary = {}
var _telemetry_vbox: VBoxContainer
var _telemetry_labels: Dictionary = {}

# 防抖：在一次内部 setter 刷新 CheckBox.pressed 时不要反向触发 toggled 信号。
var _suppress_sync_signals: bool = false

# 外部快捷键 / main 侧状态变更后置 dirty，由可见性切换或 telemetry 低频同步一次。
var _state_sync_dirty: bool = false
var _perf_detail_tick: int = 0

# 2026-05-19：Telemetry 增强字段
# - _telemetry_paused: 冻结刷新，方便看清当前快照（解决"滚动太快"问题）
# - _pause_btn / _snapshot_btn: 按钮句柄，便于改文本反映状态
# - _topn_window: 滚动窗口 Top-N 排序模式（按 max_ms 降序，看长期热点）
var _telemetry_paused: bool = false
var _pause_btn: Button
var _topn_label: Label

# "涌现耦合"开关映射到 ClimateProfile 字段。下拉 / CheckBox 生成顺序与展示名一致。
# true_insolation_enabled 是兼容字段，运行时日照链条强制启用，不在这里提供回退开关。
const SIM_SWITCHES: Array = [
	["emergent_season_enabled", "涌现季节（Emergent Season）"],
	["enable_local_climate_coupling", "本地气候耦合（Local Coupling）"],
	["emergent_weather_coupling", "天气耦合（Weather Coupling）"],
	["fast_slow_layering_enabled", "快慢分层（Fast/Slow Layering）"],
]

# 视觉开关映射：main.gd 上的 @export 字段名 + HexRenderer 对应 setter。
# setter 为空表示不必推给 renderer（仅用于 main 自身的 perf_sampler 等）。
const VISUAL_SWITCHES: Array = [
	["day_night_enabled", "昼夜开关（day_night_enabled）", "set_day_night_enabled"],
	["water_effect_enabled", "水面效果（water_effect_enabled）", "set_water_effect_enabled"],
	["ocean_current_enabled", "洋流可视化（ocean_current_enabled）", "set_ocean_current_enabled"],
	["ocean_current_debug", "洋流高对比（F6）", "set_ocean_current_debug"],
	["extreme_weather_ground_effect_enabled", "极端天气地表特效", "set_extreme_weather_ground_effect_enabled"],
	["perf_sampler_enabled", "性能采样日志", "set_perf_sampler_enabled"],
]


# 由 main.gd 在 F6/F8 等外部路径修改状态后调用；不立即刷新，避免同帧 UI 抖动。
func request_state_sync() -> void:
	_state_sync_dirty = true
	if visible:
		_sync_state_if_dirty()


func _sync_state_if_dirty() -> void:
	if not _state_sync_dirty:
		return
	_state_sync_dirty = false
	_refresh_from_state()

# --- UI 构建 --------------------------------------------------------------


func _build_overlay_group(parent: VBoxContainer) -> void:
	ConsolePresentation._build_overlay_group(self, parent)


func _build_sim_group(parent: VBoxContainer) -> void:
	ConsolePresentation._build_sim_group(self, parent)


func _build_visual_group(parent: VBoxContainer) -> void:
	ConsolePresentation._build_visual_group(self, parent)


func _build_tod_group(parent: VBoxContainer) -> void:
	ConsolePresentation._build_tod_group(self, parent)


func _build_diagnose_group(parent: VBoxContainer) -> void:
	ConsolePresentation._build_diagnose_group(self, parent)


func _build_experiments_group(parent: VBoxContainer) -> void:
	ConsolePresentation._build_experiments_group(self, parent)


# CheckBox 翻转回调：调用 main 的 toggle 方法（翻转内部 flag），随后从权威真值
# 回读并强制对齐勾选态——即使 toggle 翻转方向与 pressed 不符也能 snap 回真值。
func _on_experiment_toggle(_pressed: bool, method: String, key: String) -> void:
	if _suppress_sync_signals:
		return
	if _main == null or not _main.has_method(method):
		push_warning("[DebugConsole] 实验开关方法缺失: %s" % method)
		return
	_main.call(method)
	# 回读真值并对齐（toggle_atlas_resolution 等可能伴随 regenerate，状态以 main 为准）
	var cb: CheckBox = _toggle_checkboxes.get(key, null)
	if cb != null and _main.has_method("get_debug_toggle_state"):
		_suppress_sync_signals = true
		var truth: bool = bool(_main.call("get_debug_toggle_state", key))
		if cb.button_pressed != truth:
			cb.button_pressed = truth
		_suppress_sync_signals = false


# 生成迁移（C++ DOTS 化）验收：parity 逐字段对比 + 异步气候 bench。
# 结果打到输出日志（[gen-parity] / [async/bench] 前缀）。
func _build_migration_group(parent: VBoxContainer) -> void:
	ConsolePresentation._build_migration_group(self, parent)


func _build_telemetry_group(parent: VBoxContainer) -> void:
	ConsolePresentation._build_telemetry_group(self, parent)


func _add_telemetry_label(key: String, initial: String) -> void:
	ConsolePresentation._add_telemetry_label(self, key, initial)


func _make_section_header(text: String) -> Label:
	return ConsolePresentation._make_section_header(self, text)

# --- 信号回调 -------------------------------------------------------------


func _on_overlay_option_selected(idx: int) -> void:
	if _suppress_sync_signals:
		return
	var mode: int = _overlay_option_btn.get_item_id(idx)
	emit_signal("overlay_mode_changed", mode)
	if _main != null and _main.has_method("_apply_overlay_mode"):
		_main.call("_apply_overlay_mode", mode)
	_refresh_overlay_error_line()


func _on_overlay_alpha_changed(v: float) -> void:
	if _suppress_sync_signals:
		return
	_overlay_alpha_label.text = "透明度 %.2f" % v
	emit_signal("overlay_alpha_changed", v)
	if _main != null and _main.has_method("_set_overlay_alpha"):
		_main.call("_set_overlay_alpha", v)


# 模拟开关：复用 main.gd 里 F8 的耦合同步语义，真日射链条保持常开。
func _on_sim_switch_toggled(pressed: bool, field: String) -> void:
	if _suppress_sync_signals:
		return
	var gen = _get_generator()
	if gen == null:
		_show_need_map_toast()
		return
	var cp = gen._c() if gen.has_method("_c") else null
	if cp == null:
		return
	cp.set(field, pressed)
	cp.set("true_insolation_enabled", true)
	# 跟 F8 行为一致：emergent_* 变化推到 WeatherSystem；shader 始终保持真日射分支。
	var renderer = _get_renderer()
	if renderer != null and renderer.has_method("set_true_insolation_enabled"):
		renderer.set_true_insolation_enabled(true)
	if gen._weather_system != null and gen._weather_system.has_method("configure_emergent_coupling"):
		gen._weather_system.configure_emergent_coupling(
			bool(cp.get("emergent_weather_coupling")),
			float(cp.get("rain_shadow_threshold")),
			float(cp.get("rain_shadow_factor")),
			float(cp.get("orographic_boost"))
		)
	if gen._weather_system != null and gen._weather_system.has_method("configure_ocean_spawn_bias"):
		gen._weather_system.configure_ocean_spawn_bias(float(cp.get("ocean_weather_spawn_bias")))
	# 立即推一次 refresh_climate_daily 让面板 / 温度 / 海冰即时响应
	var map = _get_map()
	var wc = _get_clock()
	if map != null and wc != null and gen.has_method("refresh_climate_daily"):
		gen.refresh_climate_daily(map, wc.season_phase())


func _on_visual_switch_toggled(pressed: bool, field: String, setter: String) -> void:
	if _suppress_sync_signals:
		return
	# main.gd 上的 @export 字段统一同步（保证 regenerate 后也能还原）
	if _main != null and _main.has_method("set"):
		_main.set(field, pressed)
	if setter != "" and _main != null and _main.has_method(setter):
		_main.call(setter, pressed)
		_refresh_tod_controls()
		return
	var renderer = _get_renderer()
	if renderer == null:
		return
	if setter != "" and renderer.has_method(setter):
		renderer.call(setter, pressed)
	_refresh_tod_controls()


func _on_tod_light_angle_changed(v: float) -> void:
	if _suppress_sync_signals:
		return
	_tod_light_angle_label.text = "光线方位 %d°" % int(round(v))
	if _main != null and _main.has_method("set_debug_tod_light_angle_deg"):
		_main.call("set_debug_tod_light_angle_deg", v)


func _on_tod_light_elevation_changed(v: float) -> void:
	if _suppress_sync_signals:
		return
	_tod_light_elevation_label.text = "光线高度 %d°" % int(round(v))
	if _main != null and _main.has_method("set_debug_tod_light_elevation_deg"):
		_main.call("set_debug_tod_light_elevation_deg", v)


func _on_tod_sun_height_scale_changed(v: float) -> void:
	if _suppress_sync_signals:
		return
	_tod_sun_height_scale_label.text = "太阳高度 x%.2f" % v
	if _main != null and _main.has_method("set_debug_tod_sun_height_scale"):
		_main.call("set_debug_tod_sun_height_scale", v)


func _on_btn_diagnose_ocean() -> void:
	if _main != null and _main.has_method("diagnose_ocean_heat"):
		_main.call("diagnose_ocean_heat")


func _on_btn_diagnose_temperature() -> void:
	if _main != null and _main.has_method("diagnose_selected_temperature"):
		_main.call("diagnose_selected_temperature")


func _on_btn_clear_selection() -> void:
	if _main != null and _main.has_method("_clear_selection"):
		_main.call("_clear_selection")

# --- 状态同步 -------------------------------------------------------------


# 从 main / ClimateProfile / HexRenderer 读回真值，刷新所有 CheckBox/滑条/下拉。
# 由：① _ready 后 set_main 注入时 ② visible=true 时 ③ 外部状态 dirty 时调用。
func _refresh_from_state() -> void:
	ConsolePresentation._refresh_from_state(self)


func _refresh_tod_controls() -> void:
	ConsolePresentation._refresh_tod_controls(self)


func _format_tod_sun_uv(uv: Vector2) -> String:
	var phase: float = fposmod(uv.x, 1.0)
	var lat: float = clampf(uv.y * 2.0 - 1.0, -1.0, 1.0) * 90.0
	var name := "日出"
	if phase >= 0.125 and phase < 0.375:
		name = "正午"
	elif phase >= 0.375 and phase < 0.625:
		name = "日落"
	elif phase >= 0.625 and phase < 0.875:
		name = "午夜"
	var lat_i := int(round(lat))
	var lat_text := "+%d" % lat_i if lat_i >= 0 else "%d" % lat_i
	return "太阳位置：地图按钮 %.3f / 纬度 %s°（%s）" % [phase, lat_text, name]


func _refresh_overlay_error_line() -> void:
	ConsolePresentation._refresh_overlay_error_line(self)


func _show_need_map_toast() -> void:
	push_warning("[DebugConsole] 请先生成地图（R 键）")

# --- Telemetry tick -------------------------------------------------------


# 低频刷新：收集并显示全局统计。模拟暂停时依然更新（暂停本身是状态 freeze，
# 数值停留在最后一次真实 tick 的快照；此处不额外判 paused，因为 stats 字典
# 本身已经是冻结态）。UI 控件状态只在 dirty 时同步，不在 telemetry 中全量轮询。
#
# 2026-05-19：新增 _telemetry_paused 守门 —— 用户按"暂停刷新"按钮后，
# 所有 telemetry label 文本冻结在按下那一刻的快照，方便看清 / 截图。
func _on_telemetry_tick() -> void:
	if _main == null:
		return
	if _telemetry_paused:
		# 暂停状态：状态同步仍然处理（CheckBox 等），但 telemetry label 全部跳过
		_sync_state_if_dirty()
		return
	_sync_state_if_dirty()
	# fast_tick

	var tick_n: int = 0
	var tick_ms: int = 0
	if _main.has_method("get_fast_tick_count"):
		tick_n = int(_main.call("get_fast_tick_count"))
	if _main.has_method("get_last_fast_tick_ms"):
		tick_ms = int(_main.call("get_last_fast_tick_ms"))
	_set_tele("fast_tick", "fast_tick #%d: %dms" % [tick_n, tick_ms])

	# overlay bake 时间 + stats
	var bake_ms: float = 0.0
	if _main.has_method("get_overlay_last_bake_ms"):
		bake_ms = float(_main.call("get_overlay_last_bake_ms"))
	_set_tele("overlay_bake", "overlay bake: %.2f ms" % bake_ms)

	_refresh_sim_perf_lines()

	var stats: Dictionary = {}
	if _main.has_method("get_overlay_stats"):
		stats = _main.call("get_overlay_stats")
	var mode: int = 0
	if _main.has_method("get_overlay_mode"):
		mode = int(_main.call("get_overlay_mode"))

	if stats == null or stats.is_empty() or mode == 0:
		_set_tele("overlay_stats", "overlay stats: —")
		_set_tele("overlay_invalid", "")
		_set_tele("overlay_buckets", "")
		_refresh_overlay_error_line()
		return


	if OverlayMode.is_discrete(mode):
		_set_tele("overlay_stats", "stats: %d cells（离散通道）" % int(stats.get("count", 0)))
		_set_tele("overlay_buckets", _format_buckets(mode, stats.get("buckets", {})))
	elif OverlayMode.is_vector(mode):
		# 方向型通道的 stats 描述的是"强度"（hue 不参与统计）。
		var mn_v: float = float(stats.get("min", 0.0))
		var mx_v: float = float(stats.get("max", 0.0))
		var mean_v: float = float(stats.get("mean", 0.0))
		var med_v: float = float(stats.get("median", 0.0))
		_set_tele("overlay_stats", "强度: min=%.3f max=%.3f mean=%.3f med=%.3f"
			% [mn_v, mx_v, mean_v, med_v])
		_set_tele("overlay_buckets", "")
	else:
		var mn: float = float(stats.get("min", 0.0))
		var mx: float = float(stats.get("max", 0.0))
		var mean: float = float(stats.get("mean", 0.0))
		var med: float = float(stats.get("median", 0.0))
		_set_tele("overlay_stats", "stats: min=%.3f max=%.3f mean=%.3f med=%.3f"
			% [mn, mx, mean, med])
		_set_tele("overlay_buckets", "")

	var invalid_n: int = int(stats.get("invalid_count", 0))
	var near_zero_n: int = int(stats.get("near_zero_count", 0))
	var inv_lb: Label = _telemetry_labels.get("overlay_invalid", null)
	if inv_lb != null:
		var hint := OverlayMode.domain_hint(mode)
		var line := "invalid cells: %d" % invalid_n
		if near_zero_n > 0:
			line += " / near-zero valid: %d" % near_zero_n
		if hint != "":
			line += "\n提示：%s" % hint
		inv_lb.text = line
		inv_lb.visible = line != ""
		if invalid_n > 0 or near_zero_n > 0:
			inv_lb.add_theme_color_override("font_color", Color(0.98, 0.85, 0.30))
		else:
			inv_lb.add_theme_color_override("font_color", Color(0.70, 0.75, 0.80))


	_refresh_overlay_error_line()


func _refresh_sim_perf_lines() -> void:
	ConsolePresentation._refresh_sim_perf_lines(self)


# 2026-05-19：新增 ── 暂停 / 快照 / Top-N 工具函数
# ─────────────────────────────────────────────────────────────────────────


func _on_btn_toggle_pause() -> void:
	_telemetry_paused = not _telemetry_paused
	if _pause_btn != null:
		IconButton.apply_with_text(_pause_btn, (&"action.play" if _telemetry_paused else &"action.pause"), _gm_sanitize_legacy_status("▶ 恢复刷新" if _telemetry_paused else "⏸ 暂停刷新"), 14)
		if _telemetry_paused:
			_pause_btn.add_theme_color_override("font_color", Color(0.98, 0.75, 0.30))
		else:
			_pause_btn.remove_theme_color_override("font_color")


# 30-tick 滚动窗口 Top-N，按 max_ms 降序。比 last-tick 列表更稳定，
# 能识别"持续慢 job"（max≈avg）vs"偶发慢 job"（max>>avg）。
const TOPN_LIMIT: int = 6


func _format_topn_jobs() -> String:
	var gen = _get_generator()
	if gen == null or not gen.has_method("sus_report_job_stats"):
		return "top by max_ms (window): —"
	var raw = gen.sus_report_job_stats()
	if not (raw is Dictionary) or raw.is_empty():
		return "top by max_ms (window): —"

	# 计算每个 job 的 avg / p95 / max（基于 samples 数组）
	var rows: Array = []
	for job_id in raw.keys():
		var entry: Dictionary = raw[job_id]
		var samples: Array = entry.get("samples", [])
		if samples == null or samples.is_empty():
			continue
		var max_ms: float = float(entry.get("max_ms", 0.0))
		var n: int = samples.size()
		var sum: float = 0.0
		for s in samples:
			sum += float(s)
		var avg: float = sum / float(n)
		var sorted_samples: Array = samples.duplicate()
		sorted_samples.sort()
		var p95_idx: int = clampi(int(round(float(n - 1) * 0.95)), 0, n - 1)
		var p95: float = float(sorted_samples[p95_idx])
		rows.append({"id": str(job_id), "avg": avg, "p95": p95, "max": max_ms, "n": n})

	if rows.is_empty():
		return "top by max_ms (window): —"

	rows.sort_custom(func(a, b): return float(a["max"]) > float(b["max"]))

	var lines: PackedStringArray = PackedStringArray()
	var shown: int = 0
	for r in rows:
		if shown >= TOPN_LIMIT:
			break
		lines.append("  %s  avg=%.2f  p95=%.2f  max=%.2fms  n=%d" % [
			r["id"], r["avg"], r["p95"], r["max"], r["n"],
		])
		shown += 1
	return "top by max_ms (window):\n" + "\n".join(lines)


func _format_sus_jobs(report: Dictionary) -> String:
	if report.is_empty():
		return "jobs: —"
	var keys: Array = report.keys()
	keys.sort_custom(func(a, b): return str(a) < str(b))
	var rows: PackedStringArray = PackedStringArray()
	for job_id in keys:
		var r: Dictionary = report[job_id]
		var skipped: String = str(r.get("skipped_reason", ""))
		if skipped != "":
			rows.append("%s skip:%s" % [str(job_id), skipped])
		else:
			rows.append("%s %.2fms slices=%d progress=%.0f%%%s" % [
				str(job_id),
				float(r.get("elapsed_ms", 0.0)),
				int(r.get("slices_run", 0)),
				float(r.get("progress_ratio", 0.0)) * 100.0,
				_format_stage_suffix(r),
			])
		if rows.size() >= 8:
			break
	return "jobs:\n  " + "\n  ".join(rows)


func _format_stage_suffix(r: Dictionary) -> String:
	var parts: PackedStringArray = PackedStringArray()
	var stage: String = str(r.get("stage", ""))
	var substage: String = str(r.get("substage", ""))
	var path: String = str(r.get("path", ""))
	if stage != "":
		parts.append(stage)
	if substage != "":
		parts.append(substage)
	if path != "":
		parts.append(path)
	if parts.is_empty():
		return ""
	return " [" + "/".join(parts) + "]"


func _format_sim_breakdowns(breakdowns: Dictionary) -> String:
	if breakdowns.is_empty():
		return "breakdown: —"
	var rows: PackedStringArray = PackedStringArray()
	for name in [
		"ui", "climate", "weather", "economy", "enum_atlas", "sea_ice_atlas",
		"dynamic_visual_atlas",
	]:
		var b = breakdowns.get(name, {})
		if b is Dictionary and not b.is_empty():
			rows.append("%s: %s" % [name, _format_ms_fields(b)])
	if rows.is_empty():
		return "breakdown: —"
	return "breakdown:\n  " + "\n  ".join(rows)


func _format_ms_fields(d: Dictionary) -> String:
	var keys: Array = d.keys()
	keys.sort_custom(func(a, b): return str(a) < str(b))
	var parts: PackedStringArray = PackedStringArray()
	for k in keys:
		var key_text: String = str(k)
		if key_text == "elapsed_ms" or key_text == "total_ms" or key_text.ends_with("_ms"):
			var value = d[k]
			var value_type := typeof(value)
			if value_type == TYPE_INT or value_type == TYPE_FLOAT:
				parts.append("%s=%.1f" % [key_text.replace("_ms", ""), float(value)])
		if parts.size() >= 7:
			break
	for meta_key in ["current_pass", "pass", "stage", "substage", "path", "tab", "ran"]:
		if d.has(meta_key) and str(d[meta_key]) != "":
			parts.append("%s=%s" % [meta_key, str(d[meta_key])])
	if parts.is_empty():
		return str(d)
	return " ".join(parts)


func _set_tele(key: String, text: String) -> void:
	ConsolePresentation._set_tele(self, key, text)


func _format_buckets(mode: int, buckets: Dictionary) -> String:
	return ConsolePresentation._format_buckets(self, mode, buckets)

# --- 访问辅助 -------------------------------------------------------------


func _get_renderer():
	if _main == null:
		return null
	if _main.has_method("get_renderer"):
		return _main.call("get_renderer")
	return null


func _get_map():
	if _main == null:
		return null
	if _main.has_method("get_current_map"):
		return _main.call("get_current_map")
	return null


func _get_clock():
	if _main == null:
		return null
	if _main.has_method("get_world_clock_ref"):
		return _main.call("get_world_clock_ref")
	return null
