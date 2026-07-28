extends Control
class_name CountryPanel


signal close_requested()
signal section_selected(section_id: String)

const SECTION_DEFINITIONS := [
	{"id": "technology", "label": "科技", "icon": &"country.technology", "accent": UITokens.CLIMATE},
	{"id": "politics", "label": "政治", "icon": &"country.politics", "accent": UITokens.ACCENT},
	{"id": "taxation", "label": "税收", "icon": &"country.taxation", "accent": UITokens.RESOURCE},
	{"id": "military", "label": "军事", "icon": &"country.military", "accent": UITokens.RISK},
	{"id": "diplomacy", "label": "外交", "icon": &"country.diplomacy", "accent": UITokens.WATER},
]

var _dialog: PanelContainer
var _center: MarginContainer
var _summary_grid: GridContainer
var _tabs_grid: GridContainer
var _title_label: Label
var _subtitle_label: Label
var _section_title: Label
var _empty_title: Label
var _empty_detail: Label
var _summary_values: Dictionary = {}
var _tab_buttons: Dictionary = {}
var _model: Dictionary = {}
var _section_id := ""


func _ready() -> void:
	if _dialog != null:
		return
	name = "CountryPanel"
	visible = false
	mouse_filter = Control.MOUSE_FILTER_STOP
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var scrim := ColorRect.new()
	scrim.color = Color(0.008, 0.007, 0.006, 0.64)
	scrim.mouse_filter = Control.MOUSE_FILTER_STOP
	scrim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(scrim)
	_center = MarginContainer.new()
	_center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_center.offset_left = UITokens.SPACE_SM
	_center.offset_top = PlayerTopBar.BAR_HEIGHT + UITokens.SPACE_SM
	_center.offset_right = -UITokens.SPACE_SM
	_center.offset_bottom = -CountryActionBar.BAR_HEIGHT - UITokens.SPACE_SM
	_center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_center)
	_dialog = PanelContainer.new()
	_dialog.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_dialog.size_flags_vertical = Control.SIZE_EXPAND_FILL
	var dialog_style := UITokens.panel_style(Color(0.048, 0.040, 0.032, 0.99), UITokens.RADIUS_MD, UITokens.BRASS_HIGHLIGHT)
	dialog_style.content_margin_left = UITokens.SPACE_LG
	dialog_style.content_margin_top = UITokens.SPACE_MD
	dialog_style.content_margin_right = UITokens.SPACE_LG
	dialog_style.content_margin_bottom = UITokens.SPACE_LG
	_dialog.add_theme_stylebox_override("panel", dialog_style)
	_center.add_child(_dialog)
	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_dialog.add_child(scroll)
	var content := VBoxContainer.new()
	content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	content.add_theme_constant_override("separation", UITokens.SPACE_MD)
	scroll.add_child(content)
	content.add_child(_build_header())
	content.add_child(_build_summary())
	content.add_child(_build_tabs())
	var rule := HSeparator.new()
	content.add_child(rule)
	content.add_child(_build_empty_state())
	call_deferred("_update_responsive_layout")


func _notification(what: int) -> void:
	if what == NOTIFICATION_RESIZED and _dialog != null:
		call_deferred("_update_responsive_layout")


func show_section(section_id: String, model: Dictionary) -> void:
	if _dialog == null:
		_ready()
	_model = model.duplicate(true)
	_section_id = _normalized_section(section_id)
	_apply_model()
	visible = true
	UIAnimation.crossfade(_dialog, UITokens.ANIM_MED)


func close_panel() -> void:
	if not visible:
		return
	UIAnimation.fade_slide_out(self, Vector2.ZERO, UITokens.ANIM_FAST)
	close_requested.emit()


func is_panel_open() -> bool:
	return visible


func current_section() -> String:
	return _section_id


func refresh_summary(model: Dictionary) -> void:
	if not visible:
		return
	_model = model.duplicate(true)
	_apply_model()


func layout_diagnostics() -> Dictionary:
	return {
		"visible": visible,
		"dialog_rect": Rect2(_dialog.global_position, _dialog.size) if _dialog != null else Rect2(),
		"viewport_rect": get_viewport().get_visible_rect(),
		"window_size": get_window().size if get_window() != null else Vector2i.ZERO,
	}


func _build_header() -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", UITokens.SPACE_SM)
	var crest := IconBadge.new()
	crest.custom_minimum_size = Vector2(34.0, 34.0)
	crest.set_semantic(&"country.world", UITokens.BRASS_HIGHLIGHT)
	row.add_child(crest)
	var titles := VBoxContainer.new()
	titles.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_title_label = Label.new()
	_title_label.add_theme_font_override("font", UITokens.font_with_weight(700))
	_title_label.add_theme_font_size_override("font_size", UITokens.FONT_TITLE)
	titles.add_child(_title_label)
	_subtitle_label = Label.new()
	_subtitle_label.add_theme_font_size_override("font_size", UITokens.FONT_SMALL)
	_subtitle_label.add_theme_color_override("font_color", UITokens.TEXT_MUTED)
	titles.add_child(_subtitle_label)
	row.add_child(titles)
	var close_button := Button.new()
	close_button.tooltip_text = "关闭国家事务"
	close_button.focus_mode = Control.FOCUS_NONE
	close_button.custom_minimum_size = Vector2(34.0, 30.0)
	IconButton.apply(close_button, &"action.close", IconButton.SMALL, "关闭国家事务")
	close_button.pressed.connect(close_panel)
	row.add_child(close_button)
	return row


func _build_summary() -> Control:
	_summary_grid = GridContainer.new()
	_summary_grid.columns = 4
	_summary_grid.add_theme_constant_override("h_separation", UITokens.SPACE_SM)
	_summary_grid.add_theme_constant_override("v_separation", UITokens.SPACE_SM)
	for definition in [
		{"id": "territory", "label": "领土", "icon": &"metric.territory", "accent": UITokens.GEO},
		{"id": "treasury", "label": "国库", "icon": &"metric.treasury", "accent": UITokens.RESOURCE},
		{"id": "goods", "label": "国库物资", "icon": &"metric.goods", "accent": UITokens.ECO},
		{"id": "technology", "label": "科技", "icon": &"metric.technology", "accent": UITokens.CLIMATE},
	]:
		var card := PanelContainer.new()
		card.custom_minimum_size = Vector2(116.0, 70.0)
		card.add_theme_stylebox_override("panel", UITokens.inset_panel_style(
			Color(0.075, 0.062, 0.047, 0.98), definition.accent))
		var body := VBoxContainer.new()
		body.add_theme_constant_override("separation", 2)
		card.add_child(body)
		var label_row := HBoxContainer.new()
		label_row.add_theme_constant_override("separation", 4)
		var icon := IconBadge.new()
		icon.custom_minimum_size = Vector2(22.0, 22.0)
		icon.set_semantic(definition.icon, definition.accent)
		label_row.add_child(icon)
		var label := Label.new()
		label.text = String(definition.label)
		label.add_theme_font_size_override("font_size", UITokens.FONT_SMALL)
		label.add_theme_color_override("font_color", UITokens.TEXT_MUTED)
		label_row.add_child(label)
		body.add_child(label_row)
		var value := Label.new()
		value.add_theme_font_override("font", UITokens.font_with_weight(650))
		value.add_theme_font_size_override("font_size", UITokens.FONT_VALUE)
		value.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		body.add_child(value)
		_summary_values[String(definition.id)] = value
		_summary_grid.add_child(card)
	return _summary_grid


func _build_tabs() -> Control:
	_tabs_grid = GridContainer.new()
	_tabs_grid.columns = 5
	_tabs_grid.add_theme_constant_override("h_separation", 5)
	_tabs_grid.add_theme_constant_override("v_separation", 5)
	for definition in SECTION_DEFINITIONS:
		var section_id := String(definition.id)
		var button := Button.new()
		button.toggle_mode = true
		button.focus_mode = Control.FOCUS_NONE
		button.tooltip_text = String(definition.label)
		button.custom_minimum_size = Vector2(92.0, 32.0)
		button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		button.text = String(definition.label)
		button.add_theme_font_size_override("font_size", 12)
		button.pressed.connect(func() -> void:
			_section_id = section_id
			_apply_section()
			section_selected.emit(section_id)
		)
		_tabs_grid.add_child(button)
		_tab_buttons[section_id] = button
	return _tabs_grid


func _build_empty_state() -> Control:
	var state := VBoxContainer.new()
	state.size_flags_vertical = Control.SIZE_EXPAND_FILL
	state.alignment = BoxContainer.ALIGNMENT_CENTER
	state.add_theme_constant_override("separation", UITokens.SPACE_SM)
	var icon := IconBadge.new()
	icon.custom_minimum_size = Vector2(48.0, 48.0)
	icon.set_semantic(&"country.affairs", UITokens.TEXT_MUTED)
	icon.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	state.add_child(icon)
	_section_title = Label.new()
	_section_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_section_title.add_theme_font_override("font", UITokens.font_with_weight(650))
	_section_title.add_theme_font_size_override("font_size", UITokens.FONT_VALUE)
	state.add_child(_section_title)
	_empty_title = Label.new()
	_empty_title.text = "系统建设中"
	_empty_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_empty_title.add_theme_color_override("font_color", UITokens.BRASS_HIGHLIGHT)
	state.add_child(_empty_title)
	_empty_detail = Label.new()
	_empty_detail.text = "该领域尚未接入模拟与操作命令。"
	_empty_detail.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_empty_detail.add_theme_font_size_override("font_size", UITokens.FONT_SMALL)
	_empty_detail.add_theme_color_override("font_color", UITokens.TEXT_MUTED)
	state.add_child(_empty_detail)
	return state


func _apply_model() -> void:
	var available := bool(_model.get("available", false))
	_title_label.text = String(_model.get("country_name", "国家事务"))
	_subtitle_label.text = "国家档案" if available else String(_model.get("reason", "国家档案暂不可用"))
	(_summary_values.get("territory") as Label).text = "%d 格" % int(_model.get("territory_count", 0))
	(_summary_values.get("treasury") as Label).text = UITokens.format_compact_number_cn(float(_model.get("cash", 0)) / 10000.0, 2)
	(_summary_values.get("goods") as Label).text = "%d 类" % int(_model.get("nonzero_good_count", 0))
	(_summary_values.get("technology") as Label).text = "%d 项" % int(_model.get("technology_count", 0))
	_apply_section()


func _apply_section() -> void:
	var definition := _definition_for(_section_id)
	_section_title.text = "%s事务" % String(definition.get("label", "国家"))
	for id in _tab_buttons:
		var button := _tab_buttons[id] as Button
		if button != null:
			button.set_pressed_no_signal(id == _section_id)


func _normalized_section(section_id: String) -> String:
	return section_id if not _definition_for(section_id).is_empty() else "technology"


func _definition_for(section_id: String) -> Dictionary:
	for definition in SECTION_DEFINITIONS:
		if String(definition.id) == section_id:
			return definition
	return {}


func _update_responsive_layout() -> void:
	if _dialog == null or _center == null:
		return
	var window_size := get_window().size if get_window() != null else Vector2i(_center.size)
	var compact := window_size.x < 720
	_dialog.custom_minimum_size = Vector2.ZERO
	if _summary_grid != null:
		_summary_grid.columns = 2 if compact else 4
	if _tabs_grid != null:
		_tabs_grid.columns = 3 if compact else 5
	for button in _tab_buttons.values():
		(button as Button).custom_minimum_size.x = 76.0 if compact else 92.0
