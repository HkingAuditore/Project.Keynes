extends ColorRect
class_name WorldLoadingOverlay

const STAGE_LABELS := {
	"preparing": "正在建立世界生成参数",
	"continents": "正在塑造大陆与海盆",
	"climate": "正在校准纬度、气候与海冰",
	"terrain": "正在烘焙地形与水文图层",
	"physical": "正在求解风带与海洋环流",
	"atlas": "正在整理生态与地块索引",
	"encode": "正在编码地图材质与图集",
	"ecology": "正在建立资源与生态档案",
	"simulation": "正在装配国家、经济与模拟系统",
	"done": "世界测绘完成",
}

var _card: PanelContainer
var _title_label: Label
var _stage_label: Label
var _percent_label: Label
var _progress: ProgressBar
var _active_tween: Tween
var _last_stage: String = ""
var _last_fraction: float = 0.0


class LoadingAtlasBackdrop extends Control:
	func _ready() -> void:
		mouse_filter = Control.MOUSE_FILTER_IGNORE
		set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		resized.connect(queue_redraw)

	func _draw() -> void:
		var canvas := Rect2(Vector2.ZERO, size)
		draw_rect(canvas, Color(0.020, 0.027, 0.028, 1.0))
		var grid_color := Color(0.32, 0.43, 0.42, 0.13)
		var major_color := Color(0.52, 0.43, 0.27, 0.18)
		for column in range(1, 12):
			var x := size.x * float(column) / 12.0
			draw_line(Vector2(x, 0.0), Vector2(x, size.y),
				major_color if column == 6 else grid_color, 1.0)
		for row in range(1, 8):
			var y := size.y * float(row) / 8.0
			draw_line(Vector2(0.0, y), Vector2(size.x, y),
				major_color if row == 4 else grid_color, 1.0)
		var contour_color := Color(0.34, 0.50, 0.46, 0.16)
		for band in range(5):
			var points := PackedVector2Array()
			for sample in range(33):
				var t := float(sample) / 32.0
				var wave := sin(t * TAU * (1.15 + band * 0.17) + band * 1.7)
				var secondary := sin(t * TAU * 3.1 - band * 0.8) * 0.32
				points.append(Vector2(
					t * size.x,
					size.y * (0.18 + band * 0.155) + (wave + secondary) * size.y * 0.026
				))
			draw_polyline(points, contour_color, 1.25, true)
		var compass_center := Vector2(size.x * 0.84, size.y * 0.76)
		var compass_radius := minf(size.x, size.y) * 0.085
		draw_arc(compass_center, compass_radius, 0.0, TAU, 64, major_color, 1.5, true)
		draw_arc(compass_center, compass_radius * 0.72, 0.0, TAU, 48, grid_color, 1.0, true)
		draw_line(compass_center - Vector2(compass_radius, 0.0),
			compass_center + Vector2(compass_radius, 0.0), major_color, 1.0)
		draw_line(compass_center - Vector2(0.0, compass_radius),
			compass_center + Vector2(0.0, compass_radius), major_color, 1.0)


func _ready() -> void:
	if _card != null:
		return
	name = "WorldLoadingOverlay"
	color = Color(0.018, 0.022, 0.021, 1.0)
	mouse_filter = Control.MOUSE_FILTER_STOP
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

	var backdrop := LoadingAtlasBackdrop.new()
	add_child(backdrop)

	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(center)

	_card = PanelContainer.new()
	_card.custom_minimum_size = Vector2(520.0, 220.0)
	_card.add_theme_stylebox_override(
		"panel",
		UITokens.panel_style(
			Color(0.045, 0.040, 0.033, 0.99),
			UITokens.RADIUS_LG,
			UITokens.BRASS_HIGHLIGHT
		)
	)
	center.add_child(_card)

	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", UITokens.SPACE_XXL)
	margin.add_theme_constant_override("margin_top", UITokens.SPACE_XL)
	margin.add_theme_constant_override("margin_right", UITokens.SPACE_XXL)
	margin.add_theme_constant_override("margin_bottom", UITokens.SPACE_XL)
	_card.add_child(margin)

	var content := VBoxContainer.new()
	content.add_theme_constant_override("separation", UITokens.SPACE_MD)
	margin.add_child(content)

	var kicker := Label.new()
	kicker.text = "PROJECT KEYNES · WORLD SURVEY"
	kicker.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	kicker.add_theme_font_size_override("font_size", UITokens.FONT_SMALL)
	kicker.add_theme_color_override("font_color", UITokens.ACCENT)
	content.add_child(kicker)

	_title_label = Label.new()
	_title_label.text = "正在生成世界"
	_title_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_title_label.add_theme_font_override("font", UITokens.font_with_weight(700))
	_title_label.add_theme_font_size_override("font_size", 26)
	_title_label.add_theme_color_override("font_color", UITokens.TEXT_MAIN)
	content.add_child(_title_label)

	var rule := HSeparator.new()
	rule.add_theme_color_override("separator", UITokens.PANEL_BORDER)
	content.add_child(rule)

	var stage_row := HBoxContainer.new()
	stage_row.add_theme_constant_override("separation", UITokens.SPACE_SM)
	content.add_child(stage_row)
	var stage_icon := IconBadge.new()
	stage_icon.custom_minimum_size = Vector2(28.0, 28.0)
	stage_icon.set_icon("world", UITokens.ACCENT)
	stage_row.add_child(stage_icon)
	_stage_label = Label.new()
	_stage_label.text = "正在准备地图运行时"
	_stage_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_stage_label.add_theme_color_override("font_color", UITokens.TEXT_MUTED)
	stage_row.add_child(_stage_label)
	_percent_label = Label.new()
	_percent_label.text = "0%"
	_percent_label.add_theme_font_override("font", UITokens.font_with_weight(650))
	_percent_label.add_theme_color_override("font_color", UITokens.BRASS_HIGHLIGHT)
	stage_row.add_child(_percent_label)

	_progress = ProgressBar.new()
	_progress.min_value = 0.0
	_progress.max_value = 100.0
	_progress.value = 0.0
	_progress.show_percentage = false
	_progress.custom_minimum_size = Vector2(440.0, 10.0)
	content.add_child(_progress)

	var note := Label.new()
	note.text = "正在校准地形、水文、气候与生态资料"
	note.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	note.add_theme_font_size_override("font_size", UITokens.FONT_SMALL)
	note.add_theme_color_override("font_color", UITokens.TEXT_FAINT)
	content.add_child(note)


func show_message(message: String) -> void:
	if _card == null:
		_ready()
	_kill_tween()
	visible = true
	modulate = Color.WHITE
	_card.modulate = Color.WHITE
	_title_label.text = message
	_stage_label.text = "正在准备地图运行时"
	_percent_label.text = "0%"
	_progress.value = 0.0
	_last_stage = ""
	_last_fraction = 0.0


func set_progress(stage: String, fraction: float) -> void:
	if _card == null:
		_ready()
	_last_fraction = maxf(_last_fraction, clampf(fraction, 0.0, 1.0))
	var percent := clampi(int(round(_last_fraction * 100.0)), 0, 100)
	_title_label.text = "正在生成世界"
	_percent_label.text = "%d%%" % percent
	_progress.value = percent
	if stage != _last_stage:
		_last_stage = stage
		_stage_label.text = String(STAGE_LABELS.get(stage, stage))


func hide_completed() -> void:
	if not visible:
		return
	_kill_tween()
	_title_label.text = "世界测绘完成"
	_stage_label.text = "档案已就绪，正在揭示地图"
	_percent_label.text = "100%"
	_progress.value = 100.0
	_active_tween = create_tween()
	_active_tween.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	_active_tween.tween_property(_card, "modulate", Color(1.08, 1.04, 0.92, 1.0), 0.12)
	_active_tween.tween_interval(0.10)
	_active_tween.parallel().tween_property(self, "modulate:a", 0.0, UITokens.ANIM_SLOW)
	_active_tween.parallel().tween_property(_card, "scale", Vector2(0.985, 0.985), UITokens.ANIM_SLOW)
	_active_tween.tween_callback(func() -> void:
		visible = false
		modulate = Color.WHITE
		_card.modulate = Color.WHITE
		_card.scale = Vector2.ONE
	)


func _kill_tween() -> void:
	if _active_tween != null and _active_tween.is_valid():
		_active_tween.kill()
	_active_tween = null
