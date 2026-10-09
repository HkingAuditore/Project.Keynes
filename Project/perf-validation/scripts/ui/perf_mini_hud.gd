# perf_mini_hud.gd
# 2026-05-19：常驻迷你性能 HUD（右上角浮窗）。
#
# 解决的问题：
#   - DebugConsole 要按 ` 才能看到，且 2 秒刷新一次，眼神跟不上
#   - Godot Profiler 不能看 SUS per-job 明细
#   - 想随时瞄一眼 FPS / 模拟开销 / 当前最慢 Job，不切上下文
#
# 显示内容（4 行紧凑文本，颜色按阈值着色）：
#   FPS  60.0  Δ16.6ms              （绿/黄/橙/红）
#   SUS  total=1.83ms  jobs=12/3  p95=2.41ms
#   slow dyn_atlas_upload  0.92ms  [smooth]
#   fast_tick #4823: 0ms
#
# 快捷键：F4 切换显隐（默认显示）
# 位置：屏幕右上角，anchor 跟随窗口大小
# 数据源：完全复用 main.gd 已有 getter（get_sus_last_tick_summary 等），不引入新统计。

class_name PerfMiniHUD
extends PanelContainer

const REFRESH_INTERVAL: float = 0.25

@export var start_visible: bool = true

var _main: Node = null
var _label: RichTextLabel
var _timer: Timer

# 平滑 FPS（避免每 0.25s 跳动）
var _fps_smooth: float = 60.0
const FPS_SMOOTH_ALPHA: float = 0.3


func _ready() -> void:
	visible = start_visible
	mouse_filter = Control.MouseFilter.MOUSE_FILTER_IGNORE
	# 半透明背景
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.04, 0.05, 0.08, 0.72)
	sb.set_corner_radius_all(4)
	sb.set_content_margin_all(6.0)
	add_theme_stylebox_override("panel", sb)

	_label = RichTextLabel.new()
	_label.bbcode_enabled = true
	_label.fit_content = true
	_label.scroll_active = false
	_label.mouse_filter = Control.MouseFilter.MOUSE_FILTER_IGNORE
	_label.add_theme_font_size_override("normal_font_size", 12)
	_label.add_theme_font_size_override("bold_font_size", 12)
	_label.add_theme_font_size_override("mono_font_size", 12)
	_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_label.text = "perf hud: waiting for main..."
	add_child(_label)

	_timer = Timer.new()
	_timer.wait_time = REFRESH_INTERVAL
	_timer.autostart = start_visible
	_timer.timeout.connect(_refresh)
	add_child(_timer)


func set_main(m: Node) -> void:
	_main = m


func toggle_visible() -> void:
	visible = not visible
	if visible and _timer != null:
		_timer.start()
	elif _timer != null:
		_timer.stop()


# ── 刷新 ─────────────────────────────────────────────────────────────────────

func _refresh() -> void:
	if _main == null or not is_instance_valid(_main):
		return

	# 1) FPS（指数平滑）
	var raw_fps: float = float(Engine.get_frames_per_second())
	_fps_smooth = lerp(_fps_smooth, raw_fps, FPS_SMOOTH_ALPHA)
	var frame_ms: float = 0.0
	if _fps_smooth > 0.01:
		frame_ms = 1000.0 / _fps_smooth

	# 2) SUS summary
	var summary: Dictionary = {}
	if _main.has_method("get_sus_last_tick_summary"):
		var raw = _main.call("get_sus_last_tick_summary")
		if raw is Dictionary:
			summary = raw

	# 3) fast_tick
	var ft_n: int = 0
	var ft_ms: int = 0
	if _main.has_method("get_fast_tick_count"):
		ft_n = int(_main.call("get_fast_tick_count"))
	if _main.has_method("get_last_fast_tick_ms"):
		ft_ms = int(_main.call("get_last_fast_tick_ms"))

	# ── 拼 BBCode ──
	var lines: PackedStringArray = PackedStringArray()
	lines.append("[color=#%s]FPS  %5.1f  Δ%4.1fms[/color]" % [
		_color_hex_for_fps(_fps_smooth),
		_fps_smooth,
		frame_ms,
	])

	if summary.is_empty():
		lines.append("[color=#888888]SUS  —[/color]")
		lines.append("[color=#888888]slow —[/color]")
	else:
		var total_ms: float = float(summary.get("total_ms", 0.0))
		var p95_ms: float = float(summary.get("sus_sim_p95_300", 0.0))
		var jobs_ran: int = int(summary.get("jobs_ran", 0))
		var jobs_skipped: int = int(summary.get("jobs_skipped", 0))
		lines.append("[color=#%s]SUS  total=%4.2fms  jobs=%d/%d  p95=%4.2fms[/color]" % [
			_color_hex_for_sim(total_ms),
			total_ms, jobs_ran, jobs_skipped, p95_ms,
		])

		var largest_job: String = str(summary.get("largest_slice_job", "—"))
		var largest_ms: float = float(summary.get("largest_slice_ms", 0.0))
		var stage: String = str(summary.get("largest_slice_stage", ""))
		var substage: String = str(summary.get("largest_slice_substage", ""))
		var stage_suffix: String = ""
		var parts: PackedStringArray = PackedStringArray()
		if stage != "": parts.append(stage)
		if substage != "": parts.append(substage)
		if not parts.is_empty():
			stage_suffix = " [" + "/".join(parts) + "]"
		lines.append("[color=#%s]slow %s  %4.2fms[/color]%s" % [
			_color_hex_for_sim(largest_ms),
			largest_job, largest_ms, stage_suffix,
		])

	lines.append("[color=#a0b0c0]fast_tick #%d: %dms[/color]" % [ft_n, ft_ms])

	_label.text = "\n".join(lines)


# 颜色阈值
func _color_hex_for_fps(fps: float) -> String:
	if fps >= 55.0: return "8FE388"
	if fps >= 45.0: return "E5D26F"
	if fps >= 30.0: return "E59D52"
	return "E5605A"


func _color_hex_for_sim(ms: float) -> String:
	if ms <= 1.5: return "8FE388"
	if ms <= 3.0: return "E5D26F"
	if ms <= 6.0: return "E59D52"
	return "E5605A"
