extends CanvasLayer
class_name GameUIManager

signal pause_toggled(paused: bool)
signal speed_selected(speed: float)
signal fit_requested()
signal setup_requested()
signal regenerate_requested()
signal clear_selection_requested()

const RIGHT_PANEL_WIDTH := 460.0

var _top_bar: PlayerTopBar
var _right_panel: InspectorPanel
var _loading_overlay: WorldLoadingOverlay
var _inspector_view_model: CellInspectorViewModel
var _selected_cell: HexCell
var _last_cached_panel_ms: int = 0


func _ready() -> void:
	layer = 20
	_build_ui()
	show_loading("正在生成世界")


func set_world_context(
		map: MapData,
		generator: MapGenerator,
		view_adapter: DCViewAdapter,
		world_clock: WorldClock,
		sea_level: float,
		hex_size: float
) -> void:
	if _inspector_view_model == null:
		_inspector_view_model = CellInspectorViewModel.new()
	_inspector_view_model.set_context(map, generator, view_adapter, world_clock, sea_level, hex_size)
	if _right_panel != null:
		_right_panel.reset_for_world()


func show_cell_panel(cell: HexCell) -> void:
	_selected_cell = cell
	_last_cached_panel_ms = Time.get_ticks_msec()
	if _inspector_view_model == null or _right_panel == null:
		return
	if cell == null:
		hide_cell_panel()
		return
	_set_inspector_trace_cell(int(cell.index))
	_right_panel.set_model_for_selection(_inspector_view_model.build(cell))
	if not _right_panel.visible:
		UIAnimation.fade_slide_in(_right_panel, Vector2(24.0, 0.0), UITokens.ANIM_MED)


func hide_cell_panel() -> void:
	_selected_cell = null
	_set_inspector_trace_cell(-1)
	if _right_panel != null:
		UIAnimation.fade_slide_out(_right_panel, Vector2(24.0, 0.0), UITokens.ANIM_FAST)


func refresh_selected_daily_lines(force: bool = false, day_idx: int = -1) -> void:
	if _selected_cell == null or _inspector_view_model == null or _right_panel == null:
		return
	_inspector_view_model.observe_temperature(_selected_cell, day_idx)
	var now_ms := Time.get_ticks_msec()
	if not force and now_ms - _last_cached_panel_ms < 750:
		return
	_last_cached_panel_ms = now_ms
	var patch := _inspector_view_model.build_live_patch(_selected_cell, _right_panel.current_tab())
	_right_panel.apply_live_patch(patch)


func refresh_selected_panel() -> void:
	if _selected_cell == null or _inspector_view_model == null or _right_panel == null:
		return
	_right_panel.set_model_for_selection(_inspector_view_model.build(_selected_cell))


func _on_inspector_tab_data_requested(tab_id: String) -> void:
	if _selected_cell == null or _inspector_view_model == null or _right_panel == null:
		return
	_right_panel.set_tab_category(
		tab_id, _inspector_view_model.build_tab_category(_selected_cell, tab_id))


func _set_inspector_trace_cell(cell_idx: int) -> void:
	if _inspector_view_model == null:
		return
	_inspector_view_model.set_inspector_trace_cell(cell_idx)


func update_time_state(
		year_idx: int,
		month: int,
		day_of_month: int,
		paused: bool,
		speed: float
) -> void:
	if _top_bar != null:
		_top_bar.update_time_state(
			year_idx,
			month,
			day_of_month,
			paused,
			speed
		)


func set_world_summary(width: int, height: int, cells: int, seed: int) -> void:
	if _top_bar != null:
		_top_bar.set_world_summary(width, height, cells, seed)


func show_loading(message: String) -> void:
	if _loading_overlay != null:
		_loading_overlay.show_message(message)


func set_generation_progress(stage: String, fraction: float) -> void:
	if _loading_overlay != null:
		_loading_overlay.set_progress(stage, fraction)


func hide_loading() -> void:
	if _loading_overlay != null:
		_loading_overlay.hide_completed()


func map_safe_area() -> Rect2:
	var viewport_size := get_viewport().get_visible_rect().size
	var top_height := PlayerTopBar.BAR_HEIGHT + 4.0
	if _top_bar != null and _top_bar.size.y > 0.0:
		top_height = _top_bar.size.y + 4.0
	var right_width := 0.0
	if _right_panel != null and _right_panel.visible:
		right_width = _right_panel.size.x if _right_panel.size.x > 0.0 else RIGHT_PANEL_WIDTH
	return Rect2(
		Vector2(0.0, top_height),
		Vector2(maxf(viewport_size.x - right_width, 1.0), maxf(viewport_size.y - top_height, 1.0))
	)


func _build_ui() -> void:
	var player_theme := UITokens.make_player_theme()

	_top_bar = PlayerTopBar.new()
	_top_bar.set_anchors_preset(Control.PRESET_TOP_WIDE)
	_top_bar.offset_bottom = PlayerTopBar.BAR_HEIGHT
	_top_bar.pause_toggled.connect(func(paused: bool) -> void: pause_toggled.emit(paused))
	_top_bar.speed_selected.connect(func(speed: float) -> void: speed_selected.emit(speed))
	_top_bar.setup_requested.connect(func() -> void: setup_requested.emit())
	add_child(_top_bar)

	_right_panel = InspectorPanel.new()
	_right_panel.name = "RightPanel"
	_right_panel.visible = false
	_right_panel.custom_minimum_size = Vector2(RIGHT_PANEL_WIDTH, 0.0)
	_right_panel.set_anchors_preset(Control.PRESET_RIGHT_WIDE)
	_right_panel.offset_left = -RIGHT_PANEL_WIDTH
	_right_panel.offset_top = PlayerTopBar.BAR_HEIGHT + 4.0
	_right_panel.offset_bottom = -UITokens.SPACE_MD
	_right_panel.close_requested.connect(func() -> void: clear_selection_requested.emit())
	_right_panel.tab_data_requested.connect(_on_inspector_tab_data_requested)
	add_child(_right_panel)

	_loading_overlay = WorldLoadingOverlay.new()
	add_child(_loading_overlay)

	for child in get_children():
		if child is Control:
			(child as Control).theme = player_theme
