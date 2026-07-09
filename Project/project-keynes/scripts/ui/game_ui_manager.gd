extends CanvasLayer
class_name GameUIManager

signal pause_toggled(paused: bool)
signal speed_selected(speed: float)
signal fit_requested()
signal setup_requested()
signal regenerate_requested()
signal clear_selection_requested()

const SPEED_PRESETS: Array = [1.0, 2.0, 5.0, 10.0, 20.0, 50.0]
const TOP_BAR_HEIGHT: float = 48.0
const RIGHT_PANEL_WIDTH: float = 500.0

var _top_bar: PanelContainer = null
var _time_label: Label = null
var _pause_btn: Button = null
var _speed_buttons: Dictionary = {}
var _right_panel: PanelContainer = null
var _loading_overlay: Control = null
var _loading_label: Label = null
var _loading_stage_label: Label = null
var _loading_progress: ProgressBar = null
var _inspector_panel: InspectorPanel = null
var _inspector_view_model: CellInspectorViewModel = null
var _selected_cell: HexCell = null
var _last_cached_panel_ms: int = 0

var _world_clock: WorldClock = null


func _ready() -> void:
	layer = 20
	var player_theme := UITokens.make_player_theme()
	for child in get_children():
		if child is Control:
			(child as Control).theme = player_theme
	_build_ui()
	show_loading("正在生成世界...")


func set_world_context(
		map: MapData,
		generator: MapGenerator,
		view_adapter: DCViewAdapter,
		world_clock: WorldClock,
		sea_level: float,
		hex_size: float
) -> void:
	_world_clock = world_clock
	if _inspector_view_model == null:
		_inspector_view_model = CellInspectorViewModel.new()
	_inspector_view_model.set_context(map, generator, view_adapter, world_clock, sea_level, hex_size)


func show_cell_panel(cell: HexCell) -> void:
	_selected_cell = cell
	_last_cached_panel_ms = Time.get_ticks_msec()
	if _inspector_view_model == null or _inspector_panel == null:
		return
	if cell != null:
		_inspector_panel.set_model(_inspector_view_model.build(cell))
		UIAnimation.fade_slide_in(_right_panel)
	else:
		hide_cell_panel()


func hide_cell_panel() -> void:
	_selected_cell = null
	if _right_panel != null:
		UIAnimation.fade_slide_out(_right_panel)


func refresh_selected_daily_lines() -> void:
	if _selected_cell == null or _inspector_view_model == null or _inspector_panel == null:
		return
	var now_ms := Time.get_ticks_msec()
	if now_ms - _last_cached_panel_ms < 750:
		return
	_last_cached_panel_ms = now_ms
	# 快进时只刷新数据缓存，不重建节点树，避免按钮/滚动/表格闪烁和位移。
	_inspector_panel.set_model(_inspector_view_model.build(_selected_cell), false)


func refresh_selected_panel() -> void:
	if _selected_cell == null or _inspector_view_model == null or _inspector_panel == null:
		return
	_inspector_panel.set_model(_inspector_view_model.build(_selected_cell))


func update_time_state(
		day_idx: int,
		year_idx: int,
		season_idx: int,
		_season_phase: float,
		visual_day_phase: float,
		climate_anomaly: float,
		paused: bool,
		speed: float
) -> void:
	if _time_label != null:
		_time_label.text = "Y%d · D%d · %s" % [year_idx, day_idx, _season_name(season_idx)]
	if _pause_btn != null:
		_pause_btn.set_pressed_no_signal(paused)
		_pause_btn.text = "▶" if paused else "Ⅱ"
	for speed_key in _speed_buttons.keys():
		var btn: Button = _speed_buttons[speed_key] as Button
		if btn != null:
			btn.set_pressed_no_signal(is_equal_approx(float(speed_key), speed))


func set_world_summary(_width: int, _height: int, _cells: int, _seed: int) -> void:
	pass


func show_loading(message: String) -> void:
	if _loading_overlay == null:
		return
	_loading_overlay.visible = true
	_loading_overlay.modulate.a = 1.0
	if _loading_label != null:
		_loading_label.text = message
	if _loading_stage_label != null:
		_loading_stage_label.text = "正在准备地图运行时"
	if _loading_progress != null:
		_loading_progress.value = 0.0


func set_generation_progress(stage: String, fraction: float) -> void:
	if _loading_label == null:
		return
	var pct := clampi(int(round(fraction * 100.0)), 0, 100)
	_loading_label.text = "正在生成世界"
	if _loading_stage_label != null:
		_loading_stage_label.text = "%s · %d%%" % [stage, pct]
	if _loading_progress != null:
		_loading_progress.value = pct


func hide_loading() -> void:
	if _loading_overlay != null:
		var tween := _loading_overlay.create_tween()
		tween.tween_property(_loading_overlay, "modulate:a", 0.0, UITokens.ANIM_MED)
		tween.tween_callback(func() -> void:
			if _loading_overlay != null:
				_loading_overlay.visible = false
				_loading_overlay.modulate.a = 1.0
		)


func map_safe_area() -> Rect2:
	var vp := get_viewport().get_visible_rect().size
	var top_h := TOP_BAR_HEIGHT + 4.0
	var right_w := 0.0
	if _right_panel != null and _right_panel.visible:
		right_w = RIGHT_PANEL_WIDTH
	return Rect2(Vector2(0.0, top_h), Vector2(maxf(vp.x - right_w, 1.0), maxf(vp.y - top_h, 1.0)))


func _build_ui() -> void:
	var player_theme := UITokens.make_player_theme()
	_build_top_bar()
	_build_right_panel()
	_build_loading_overlay()
	for child in get_children():
		if child is Control:
			(child as Control).theme = player_theme


func _build_top_bar() -> void:
	_top_bar = PanelContainer.new()
	_top_bar.name = "TopBar"
	_top_bar.set_anchors_preset(Control.PRESET_TOP_WIDE)
	_top_bar.offset_bottom = TOP_BAR_HEIGHT
	_top_bar.add_theme_stylebox_override("panel", UITokens.panel_style(Color(0.065, 0.050, 0.036, 0.94), UITokens.RADIUS_SM, Color(0.48, 0.36, 0.20, 0.66)))
	add_child(_top_bar)

	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", UITokens.SPACE_MD)
	margin.add_theme_constant_override("margin_top", UITokens.SPACE_SM)
	margin.add_theme_constant_override("margin_right", UITokens.SPACE_MD)
	margin.add_theme_constant_override("margin_bottom", UITokens.SPACE_SM)
	_top_bar.add_child(margin)

	var hbox := HBoxContainer.new()
	hbox.name = "HBox"
	hbox.add_theme_constant_override("separation", UITokens.SPACE_MD)
	margin.add_child(hbox)

	var setup_btn := Button.new()
	setup_btn.text = "⚙"
	setup_btn.tooltip_text = "设置"
	setup_btn.custom_minimum_size = Vector2(44.0, 32.0)
	setup_btn.pressed.connect(func(): setup_requested.emit())
	hbox.add_child(setup_btn)

	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hbox.add_child(spacer)

	_time_label = Label.new()
	_time_label.text = "Y0 · D0 · Spring"
	_time_label.add_theme_font_size_override("font_size", 18)
	_time_label.add_theme_color_override("font_color", UITokens.ACCENT)
	hbox.add_child(_time_label)

	var right_spacer := Control.new()
	right_spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hbox.add_child(right_spacer)

	_pause_btn = Button.new()
	_pause_btn.toggle_mode = true
	_pause_btn.text = "Ⅱ"
	_pause_btn.tooltip_text = "暂停/继续"
	_pause_btn.custom_minimum_size = Vector2(44.0, 32.0)
	_pause_btn.toggled.connect(func(pressed: bool): pause_toggled.emit(pressed))
	hbox.add_child(_pause_btn)

	for speed_value in SPEED_PRESETS:
		var speed := float(speed_value)
		var btn := Button.new()
		btn.text = "x%d" % int(speed)
		btn.toggle_mode = true
		btn.custom_minimum_size = Vector2(48.0, 32.0)
		btn.pressed.connect(_on_speed_button_pressed.bind(speed))
		hbox.add_child(btn)
		_speed_buttons[int(speed)] = btn


func _build_right_panel() -> void:
	_inspector_panel = InspectorPanel.new()
	_right_panel = _inspector_panel
	_right_panel.name = "RightPanel"
	_right_panel.visible = false
	_right_panel.custom_minimum_size = Vector2(RIGHT_PANEL_WIDTH, 0.0)
	_right_panel.set_anchors_preset(Control.PRESET_RIGHT_WIDE)
	_right_panel.offset_left = -RIGHT_PANEL_WIDTH
	_right_panel.offset_top = TOP_BAR_HEIGHT + 4.0
	_right_panel.offset_bottom = -UITokens.SPACE_MD
	_inspector_panel.close_requested.connect(func(): clear_selection_requested.emit())
	add_child(_right_panel)


func _build_loading_overlay() -> void:
	_loading_overlay = ColorRect.new()
	_loading_overlay.name = "LoadingOverlay"
	_loading_overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	_loading_overlay.color = Color(0.030, 0.024, 0.018, 0.90)
	add_child(_loading_overlay)

	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	_loading_overlay.add_child(center)

	var card := PanelContainer.new()
	card.custom_minimum_size = Vector2(420.0, 180.0)
	card.add_theme_stylebox_override("panel", UITokens.panel_style(UITokens.PANEL_BG, UITokens.RADIUS_LG))
	center.add_child(card)

	var margin2 := MarginContainer.new()
	margin2.add_theme_constant_override("margin_left", UITokens.SPACE_XL)
	margin2.add_theme_constant_override("margin_top", UITokens.SPACE_LG)
	margin2.add_theme_constant_override("margin_right", UITokens.SPACE_XL)
	margin2.add_theme_constant_override("margin_bottom", UITokens.SPACE_LG)
	card.add_child(margin2)

	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", UITokens.SPACE_MD)
	margin2.add_child(box)

	_loading_label = Label.new()
	_loading_label.text = "正在生成世界"
	_loading_label.add_theme_font_size_override("font_size", 26)
	_loading_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(_loading_label)

	_loading_stage_label = Label.new()
	_loading_stage_label.text = "正在准备地图运行时"
	_loading_stage_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_loading_stage_label.add_theme_color_override("font_color", UITokens.TEXT_MUTED)
	box.add_child(_loading_stage_label)

	_loading_progress = ProgressBar.new()
	_loading_progress.min_value = 0.0
	_loading_progress.max_value = 100.0
	_loading_progress.value = 0.0
	_loading_progress.show_percentage = false
	_loading_progress.custom_minimum_size = Vector2(360.0, 10.0)
	box.add_child(_loading_progress)


func _on_speed_button_pressed(speed: float) -> void:
	speed_selected.emit(speed)


func _season_name(season_idx: int) -> String:
	match season_idx:
		0:
			return "冬"
		1:
			return "春"
		2:
			return "夏"
		3:
			return "秋"
		_:
			return "季%d" % season_idx
