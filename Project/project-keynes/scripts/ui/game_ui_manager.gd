extends CanvasLayer
class_name GameUIManager

signal pause_toggled(paused: bool)
signal speed_selected(speed: float)
signal day_night_toggled(enabled: bool)
signal fit_requested()
signal setup_requested()
signal regenerate_requested()
signal clear_selection_requested()
signal map_overlay_requested(request: Dictionary)
signal map_overlay_cleared()

const RIGHT_PANEL_WIDTH := 460.0
const OVERLAY_LEGEND_WIDTH := 198.0
const DemandDetailDialogScript = preload("res://scripts/ui/components/demand_detail_dialog.gd")

var _top_bar: PlayerTopBar
var _right_panel: InspectorPanel
var _loading_overlay: WorldLoadingOverlay
var _demand_detail_dialog
var _inspector_view_model: CellInspectorViewModel
var _selected_cell: HexCell
var _last_cached_panel_ms: int = 0
var _live_revision_cell := -1
var _live_revision_tab := ""
var _live_common_hash := 0
var _live_category_generation := -1
var _live_category_hash := 0
var _live_revision_valid := false
var _country_facade = null
var _gm_console: DebugConsole
var _perf_hud: PerfMiniHUD
var _diagnostics_source: Node = null
var _map_overlay_toolbar: MapOverlayToolbar
var _map_overlay_legend: OverlayLegend


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
	if _country_facade != null and _country_facade.has_signal("country_committed"):
		var old_callback := Callable(self, "_on_country_committed")
		if _country_facade.country_committed.is_connected(old_callback):
			_country_facade.country_committed.disconnect(old_callback)
	if _inspector_view_model == null:
		_inspector_view_model = CellInspectorViewModel.new()
	_inspector_view_model.set_context(map, generator, view_adapter, world_clock, sea_level, hex_size)
	_invalidate_live_revision()
	_country_facade = generator.get_country_facade() if generator != null and \
		generator.has_method("get_country_facade") else null
	if _country_facade != null and _country_facade.has_signal("country_committed"):
		var callback := Callable(self, "_on_country_committed")
		if not _country_facade.country_committed.is_connected(callback):
			_country_facade.country_committed.connect(callback)
	if _right_panel != null:
		_right_panel.reset_for_world()
	if _map_overlay_toolbar != null:
		_map_overlay_toolbar.reset_for_world()
	if _map_overlay_legend != null:
		_map_overlay_legend.update_for_mode(OverlayMode.MODE.NONE)
	if _demand_detail_dialog != null:
		_demand_detail_dialog.close_dialog()


func set_diagnostics_source(source: Node) -> void:
	_diagnostics_source = source
	if _gm_console != null:
		_gm_console.set_main(source)
	if _perf_hud != null:
		_perf_hud.set_main(source)


func toggle_gm_panel() -> void:
	if _gm_console != null:
		_gm_console.visible = not _gm_console.visible


func toggle_perf_hud() -> void:
	if _perf_hud != null:
		_perf_hud.toggle_visible()


func show_cell_panel(cell: HexCell) -> void:
	_selected_cell = cell
	_invalidate_live_revision()
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
	_invalidate_live_revision()
	_set_inspector_trace_cell(-1)
	if _demand_detail_dialog != null:
		_demand_detail_dialog.close_dialog()
	if _right_panel != null:
		UIAnimation.fade_slide_out(_right_panel, Vector2(24.0, 0.0), UITokens.ANIM_FAST)


func refresh_selected_daily_lines(force: bool = false, day_idx: int = -1) -> Dictionary:
	var timing: Dictionary = {
		"ran": false,
		"tab": "",
		"live_patch_build_ms": 0.0,
		"live_patch_apply_ms": 0.0,
	}
	if _selected_cell == null or _inspector_view_model == null or _right_panel == null:
		return timing
	var tab_id := _right_panel.current_tab()
	timing["tab"] = tab_id
	_inspector_view_model.observe_temperature(_selected_cell, day_idx)
	var now_ms := Time.get_ticks_msec()
	if not force and now_ms - _last_cached_panel_ms < 750:
		return timing
	_last_cached_panel_ms = now_ms
	var include_category := true
	var revision: Dictionary = {}
	var common_dirty := true
	var category_dirty := true
	var cell_idx := int(_selected_cell.index)
	var same_target := _live_revision_valid and _live_revision_cell == cell_idx \
		and _live_revision_tab == tab_id
	if tab_id == "population":
		revision = _inspector_view_model.live_patch_revision(_selected_cell, tab_id)
		var common_hash := int(revision.get("common_hash", 0))
		var category_generation := int(revision.get("category_generation", -1))
		common_dirty = force or not same_target or common_hash != _live_common_hash
		category_dirty = force or not same_target or \
			category_generation != _live_category_generation
		include_category = category_dirty
		if not common_dirty and not category_dirty:
			return timing
	var build_started_usec := Time.get_ticks_usec()
	var patch := _inspector_view_model.build_live_patch(
		_selected_cell,
		tab_id,
		include_category,
		revision.get("population_summary", {})
	)
	timing["live_patch_build_ms"] = (
		Time.get_ticks_usec() - build_started_usec) / 1000.0
	if tab_id == "population":
		if not common_dirty:
			patch.erase("header")
			patch.erase("score")
			patch.erase("summary_cards")
		if patch.has("category"):
			var category_hash := hash(patch["category"])
			if not force and same_target and category_hash == _live_category_hash:
				patch.erase("category")
			else:
				_live_category_hash = category_hash
		_live_revision_cell = cell_idx
		_live_revision_tab = tab_id
		_live_common_hash = int(revision.get("common_hash", 0))
		_live_category_generation = int(revision.get("category_generation", -1))
		_live_revision_valid = true
		if not common_dirty and not patch.has("category"):
			return timing
	var apply_started_usec := Time.get_ticks_usec()
	_right_panel.apply_live_patch(patch)
	timing["live_patch_apply_ms"] = (
		Time.get_ticks_usec() - apply_started_usec) / 1000.0
	timing["ran"] = true
	return timing


func refresh_selected_panel() -> void:
	if _selected_cell == null or _inspector_view_model == null or _right_panel == null:
		return
	_invalidate_live_revision()
	_right_panel.set_model_for_selection(_inspector_view_model.build(_selected_cell))


func _on_country_committed(_report: Dictionary) -> void:
	# Country identity/territory changes are rare and may rebuild one selected
	# dossier. Daily economy/climate ticks continue to use the live-value patch.
	refresh_selected_panel()


func _on_inspector_tab_data_requested(tab_id: String) -> void:
	if _selected_cell == null or _inspector_view_model == null or _right_panel == null:
		return
	_invalidate_live_revision()
	_right_panel.set_tab_category(
		tab_id, _inspector_view_model.build_tab_category(_selected_cell, tab_id))


func _invalidate_live_revision() -> void:
	_live_revision_cell = -1
	_live_revision_tab = ""
	_live_common_hash = 0
	_live_category_generation = -1
	_live_category_hash = 0
	_live_revision_valid = false


func _on_demand_details_requested(details: Dictionary) -> void:
	if _demand_detail_dialog != null:
		_demand_detail_dialog.show_details(details)


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


func set_day_night_enabled(enabled: bool) -> void:
	if _top_bar != null:
		_top_bar.set_day_night_enabled(enabled)


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
	var left_width := _map_overlay_toolbar.primary_safe_width() \
		if _map_overlay_toolbar != null else 0.0
	return Rect2(
		Vector2(left_width, top_height),
		Vector2(
			maxf(viewport_size.x - right_width - left_width, 1.0),
			maxf(viewport_size.y - top_height, 1.0)
		)
	)


func dismiss_overlay_menu() -> bool:
	return _map_overlay_toolbar != null and _map_overlay_toolbar.dismiss_submenu()


func set_resource_discovery_context(
	technology_ids: PackedStringArray,
	enforce_discovery: bool = false
) -> void:
	if _map_overlay_toolbar != null:
		_map_overlay_toolbar.set_resource_discovery_context(
			technology_ids, enforce_discovery)


func _build_ui() -> void:
	var player_theme := UITokens.make_player_theme()

	_top_bar = PlayerTopBar.new()
	_top_bar.set_anchors_preset(Control.PRESET_TOP_WIDE)
	_top_bar.offset_bottom = PlayerTopBar.BAR_HEIGHT
	_top_bar.pause_toggled.connect(func(paused: bool) -> void: pause_toggled.emit(paused))
	_top_bar.speed_selected.connect(func(speed: float) -> void: speed_selected.emit(speed))
	_top_bar.day_night_toggled.connect(
		func(enabled: bool) -> void: day_night_toggled.emit(enabled))
	_top_bar.setup_requested.connect(func() -> void: setup_requested.emit())
	_top_bar.gm_requested.connect(toggle_gm_panel)
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
	_right_panel.visibility_changed.connect(_layout_overlay_legend)
	_right_panel.demand_details_requested.connect(_on_demand_details_requested)
	add_child(_right_panel)

	_demand_detail_dialog = DemandDetailDialogScript.new()
	_demand_detail_dialog.name = "DemandDetailDialog"
	add_child(_demand_detail_dialog)

	_gm_console = DebugConsole.new()
	_gm_console.name = "GMConsole"
	_gm_console.runtime_diagnostics_only = true
	add_child(_gm_console)
	_gm_console.position = Vector2(
		UITokens.SPACE_SM, PlayerTopBar.BAR_HEIGHT + UITokens.SPACE_SM)

	_perf_hud = PerfMiniHUD.new()
	_perf_hud.name = "PerfMiniHUD"
	_perf_hud.start_visible = false
	_perf_hud.set_anchors_preset(Control.PRESET_CENTER_TOP)
	_perf_hud.offset_left = -180.0
	_perf_hud.offset_top = PlayerTopBar.BAR_HEIGHT + UITokens.SPACE_SM
	_perf_hud.offset_right = 180.0
	add_child(_perf_hud)

	_map_overlay_toolbar = MapOverlayToolbar.new()
	_map_overlay_toolbar.name = "MapOverlayToolbar"
	_map_overlay_toolbar.overlay_requested.connect(_on_map_overlay_requested)
	_map_overlay_toolbar.overlay_cleared.connect(_on_map_overlay_cleared)
	add_child(_map_overlay_toolbar)

	_map_overlay_legend = OverlayLegend.new()
	_map_overlay_legend.name = "MapOverlayLegend"
	# Bottom-right is outside the map's main reading line and the left tool
	# palette. The layout helper shifts it left whenever Inspector is visible.
	_map_overlay_legend.set_anchors_preset(Control.PRESET_BOTTOM_RIGHT)
	_map_overlay_legend.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	_map_overlay_legend.grow_vertical = Control.GROW_DIRECTION_BEGIN
	add_child(_map_overlay_legend)
	get_viewport().size_changed.connect(_layout_overlay_legend)
	_layout_overlay_legend()

	if _diagnostics_source != null:
		set_diagnostics_source(_diagnostics_source)

	_loading_overlay = WorldLoadingOverlay.new()
	_loading_overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(_loading_overlay)

	for child in get_children():
		if child is Control:
			(child as Control).theme = player_theme


func _on_map_overlay_requested(request: Dictionary) -> void:
	var mode := int(request.get("mode", OverlayMode.MODE.NONE))
	var title := ""
	var icon_key := ""
	if mode == OverlayMode.MODE.RESOURCE_RESERVE:
		var resource_id := StringName(request.get("resource_id", &""))
		for profile in ResourceProfileRegistry.ordered():
			if profile != null and profile.id == resource_id:
				title = profile.display_name
				icon_key = ResourceProfileRegistry.icon_key(profile)
				break
	if _map_overlay_legend != null:
		var hint := "透明区域无可用储量" if mode == OverlayMode.MODE.RESOURCE_RESERVE else ""
		_map_overlay_legend.update_for_mode(mode, title, hint, icon_key)
		call_deferred("_layout_overlay_legend")
	map_overlay_requested.emit(request)


func _on_map_overlay_cleared() -> void:
	if _map_overlay_legend != null:
		_map_overlay_legend.update_for_mode(OverlayMode.MODE.NONE)
	map_overlay_cleared.emit()


func _layout_overlay_legend() -> void:
	if _map_overlay_legend == null:
		return
	var right_inset := UITokens.SPACE_MD
	if _right_panel != null and _right_panel.visible:
		var panel_width := _right_panel.size.x
		if panel_width <= 0.0:
			panel_width = RIGHT_PANEL_WIDTH
		right_inset += panel_width + UITokens.SPACE_MD
	_map_overlay_legend.set_anchors_preset(Control.PRESET_BOTTOM_RIGHT)
	_map_overlay_legend.offset_right = -right_inset
	_map_overlay_legend.offset_left = -right_inset - OVERLAY_LEGEND_WIDTH
	_map_overlay_legend.offset_bottom = -UITokens.SPACE_MD
	# A zero-height anchored rect plus BEGIN growth keeps variable legend
	# content attached to the bottom edge instead of growing off-screen.
	_map_overlay_legend.offset_top = -UITokens.SPACE_MD
