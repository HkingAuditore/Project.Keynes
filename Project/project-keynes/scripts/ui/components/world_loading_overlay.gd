extends ColorRect
class_name WorldLoadingOverlay

var _card: PanelContainer
var _title_label: Label
var _stage_label: Label
var _percent_label: Label
var _progress: ProgressBar
var _active_tween: Tween
var _last_stage: String = ""


func _ready() -> void:
	if _card != null:
		return
	name = "WorldLoadingOverlay"
	color = Color(0.018, 0.017, 0.015, 0.94)
	mouse_filter = Control.MOUSE_FILTER_STOP
	set_anchors_preset(Control.PRESET_FULL_RECT)

	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
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


func set_progress(stage: String, fraction: float) -> void:
	if _card == null:
		_ready()
	var percent := clampi(int(round(fraction * 100.0)), 0, 100)
	_title_label.text = "正在生成世界"
	_percent_label.text = "%d%%" % percent
	_progress.value = percent
	if stage != _last_stage:
		_last_stage = stage
		_stage_label.text = stage
		UIAnimation.crossfade(_stage_label, UITokens.ANIM_FAST)


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
