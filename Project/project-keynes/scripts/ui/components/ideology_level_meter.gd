class_name IdeologyLevelMeter
extends HBoxContainer

## Brass level seal plus the understanding track shared by the cabinet and the
## collection. The control is presentation-only; callers pass the native Q16
## thresholds and understanding value from the ideology snapshot.

const ArtScript = preload("res://scripts/ui/components/ideology_art.gd")

var level := 0
var level_count := 1
var level_label := ""
var understanding_q16 := 0
var threshold_q16 := 0
var progress := 0.0
var maxed := false
var compact := false
var accent := ArtScript.GOLD_LEAF
var kind := 1

var _seal: LevelSeal
var _seal_text: Label
var _name: Label
var _amount: Label
var _track: LevelTrack
var _text_column: VBoxContainer
var _top_line: HBoxContainer
var _progress_tween: Tween


func _init() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_theme_constant_override("separation", 8)
	_seal = LevelSeal.new()
	_seal.custom_minimum_size = Vector2(34, 34)
	_seal.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_seal.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_seal)
	_seal_text = ArtScript.label("", 13, Color(1.0, 0.91, 0.69),
		HORIZONTAL_ALIGNMENT_CENTER)
	_seal_text.add_theme_font_override("font",
		preload("res://assets/fonts/annual_pencil/Muyao-Softbrush-2.ttf"))
	_seal_text.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_seal_text.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_seal.add_child(_seal_text)
	_text_column = VBoxContainer.new()
	_text_column.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_text_column.add_theme_constant_override("separation", 2)
	_text_column.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_text_column)
	_top_line = HBoxContainer.new()
	_top_line.add_theme_constant_override("separation", 4)
	_top_line.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_text_column.add_child(_top_line)
	_name = ArtScript.label("", 11, ArtScript.GOLD_LEAF,
		HORIZONTAL_ALIGNMENT_LEFT)
	_name.add_theme_font_override("font",
		UITokens.dossier_font("sans"))
	_name.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_name.clip_text = true
	_name.max_lines_visible = 1
	_top_line.add_child(_name)
	_amount = ArtScript.label("", 9, Color(0.94, 0.84, 0.63, 0.92),
		HORIZONTAL_ALIGNMENT_RIGHT)
	_amount.clip_text = false
	_amount.max_lines_visible = 1
	_top_line.add_child(_amount)
	_track = LevelTrack.new()
	_track.custom_minimum_size = Vector2(0, 10)
	_track.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_track.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_text_column.add_child(_track)


func configure(data: Dictionary, compact_value := false) -> void:
	var previous_progress := progress
	compact = compact_value
	visible = data.has("level")
	level = clampi(int(data.get("level", 0)), 0, 64)
	level_count = maxi(1, int(data.get("level_count", 1)))
	level_label = String(data.get("level_label", ""))
	understanding_q16 = maxi(0, int(data.get("understanding_q16", 0)))
	threshold_q16 = maxi(0, int(data.get("threshold_q16", 0)))
	progress = clampf(float(data.get("progress", 0.0)), 0.0, 1.0)
	maxed = bool(data.get("maxed", false))
	accent = data.get("accent", ArtScript.GOLD_LEAF)
	_apply_metrics()
	_seal.level = level
	_seal.level_count = level_count
	_seal.accent = accent
	_seal.maxed = maxed
	_seal.queue_redraw()
	_seal_text.text = str(level + 1)
	_name.text = level_label if not level_label.is_empty() \
		else "境界 %d" % (level + 1)
	_name.add_theme_color_override("font_color", ArtScript.INK)
	_amount.add_theme_color_override("font_color", ArtScript.INK_MUTED)
	_amount.text = "已完成" if maxed else "理解 %s / %s" % [
		_format_q16(understanding_q16), _format_q16(threshold_q16)]
	_track.progress = progress
	_track.maxed = maxed
	_track.accent = accent
	_track.track_height = 8.0 if compact else 10.0
	_track.kind = kind
	if not is_inside_tree() or UIAnimation.reduced_motion():
		_track.shown_progress = progress
	elif not is_equal_approx(previous_progress, progress):
		if _progress_tween != null and _progress_tween.is_valid():
			_progress_tween.kill()
		_progress_tween = create_tween()
		_progress_tween.tween_method(_show_progress, _track.shown_progress, progress, 0.20) \
			.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	_track.queue_redraw()
	tooltip_text = _tooltip_text()


func _show_progress(value: float) -> void:
	_track.shown_progress = value
	_track.queue_redraw()


func _apply_metrics() -> void:
	var seal_size := 28.0 if compact else 34.0
	_seal.custom_minimum_size = Vector2(seal_size, seal_size)
	_seal_text.add_theme_font_size_override("font_size", 16)
	_name.add_theme_font_size_override("font_size", 16)
	_amount.add_theme_font_size_override("font_size", 15)
	_track.custom_minimum_size.y = 10.0 if compact else 11.0
	_track.track_height = _track.custom_minimum_size.y
	add_theme_constant_override("separation", 6 if compact else 8)


func _tooltip_text() -> String:
	if maxed:
		return "境界 %d / %d · %s\n理解度已满" % [
			level + 1, level_count, level_label]
	return "境界 %d / %d · %s\n理解度 %s / %s（%d%%）" % [
		level + 1, level_count, level_label, _format_q16(understanding_q16),
		_format_q16(threshold_q16), int(round(progress * 100.0))]


static func _format_q16(value: int) -> String:
	return "%.2f" % (float(value) / 65536.0)


## A brass cartouche, intentionally drawn instead of using a flat pill. The
## notch cut and engraved ring make the same number read as a physical seal.
class LevelSeal:
	extends Control
	var level := 0
	var level_count := 1
	var accent := Color(0.86, 0.67, 0.30)
	var maxed := false

	func _draw() -> void:
		if size.x < 8.0 or size.y < 8.0:
			return
		var center := size * 0.5
		var radius := minf(size.x, size.y) * 0.42
		var fill := Color(0.24, 0.15, 0.07, 0.98)
		var gold := accent
		var points := PackedVector2Array()
		for index in 12:
			var angle := -PI * 0.5 + TAU * float(index) / 12.0
			var r := radius if index % 3 != 0 else radius * 0.88
			points.append(center + Vector2(cos(angle), sin(angle)) * r)
		draw_colored_polygon(points, fill)
		_ring(points, gold.darkened(0.38), 2.0)
		draw_arc(center, radius * 0.73, 0, TAU, 28,
			Color(gold, 0.75), 1.0, true)
		draw_arc(center, radius * 0.60, -PI * 0.82, PI * 0.22, 18,
			Color(1.0, 0.91, 0.67, 0.55 if not maxed else 0.90), 1.2, true)
		if maxed:
			for index in 4:
				var angle := TAU * float(index) / 4.0 + PI * 0.25
				draw_line(center + Vector2(cos(angle), sin(angle)) * radius * 1.06,
					center + Vector2(cos(angle), sin(angle)) * radius * 1.20,
					Color(gold, 0.72), 1.4, true)

	func _ring(points: PackedVector2Array, color: Color, width: float) -> void:
		var closed := PackedVector2Array(points)
		closed.append(points[0])
		draw_polyline(closed, color, width, true)


## Double-layer channel: a recessed ink slot, a narrow inner rule and a wet
## brass fill. The leading bead is the level threshold, not an extra progress
## label; it gives the bar a physical end instead of looking like a debug line.
class LevelTrack:
	extends Control
	var progress := 0.0
	var shown_progress := 0.0
	var maxed := false
	var accent := Color(0.86, 0.67, 0.30)
	var track_height := 12.0
	var kind := 1

	func _draw() -> void:
		if size.x < 12.0 or size.y < 4.0:
			return
		var h := clampf(track_height, 7.0, size.y)
		var track := Rect2(Vector2(0, (size.y - h) * 0.5),
			Vector2(size.x, h))
		draw_rect(track, Color(0.18, 0.10, 0.05, 0.86) if kind == 1
			else Color(0.13, 0.20, 0.15, 0.92))
		draw_rect(track.grow(-1.5), Color(0.94, 0.88, 0.73, 0.48) if kind == 1
			else Color(0.92, 0.82, 0.58, 0.56))
		draw_line(Vector2(track.position.x + 2.0, track.position.y + 2.0),
			Vector2(track.end.x - 2.0, track.position.y + 2.0),
			Color(1.0, 0.95, 0.82, 0.20), 1.0)
		var inner := track.grow(-2.5)
		var filled_width := maxf(0.0, inner.size.x * shown_progress)
		if filled_width > 0.0:
			var fill_rect := Rect2(inner.position,
				Vector2(filled_width, inner.size.y))
			draw_rect(fill_rect, Color(accent.darkened(0.18), 0.96))
			draw_rect(Rect2(fill_rect.position, Vector2(filled_width,
				maxf(1.0, fill_rect.size.y * 0.36))),
				Color(1.0, 0.90, 0.58, 0.36))
			var tip_x := fill_rect.end.x
			draw_line(Vector2(tip_x, inner.position.y),
				Vector2(tip_x, inner.end.y), Color(1.0, 0.91, 0.65, 0.92), 1.0)
		# Quarter ticks are engraved into the channel and never need a legend.
		for index in range(1, 4):
			var x := inner.position.x + inner.size.x * float(index) / 4.0
			draw_line(Vector2(x, inner.position.y - 1.0),
				Vector2(x, inner.end.y + 1.0),
				Color(0.24, 0.14, 0.06, 0.38), 1.0)
		var bead_radius := 2.2 if not maxed else 3.0
		if maxed:
			for index in 3:
				var angle := -PI * 0.5 + TAU * float(index) / 3.0
				draw_circle(track.get_center() + Vector2(
					cos(angle), sin(angle)) * track.size.x * 0.35,
					bead_radius, Color(accent, 0.78))
