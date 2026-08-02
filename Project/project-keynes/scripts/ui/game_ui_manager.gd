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
signal pause_menu_visibility_changed(open: bool)
signal return_main_menu_requested()
signal exit_game_requested()

const RIGHT_PANEL_WIDTH := 460.0
const OVERLAY_LEGEND_WIDTH := 198.0
const GM_PANEL_TARGET_WIDTH := 560.0
const GM_PANEL_MIN_WIDTH := 300.0
var _top_bar: PlayerTopBar
var _right_panel: InspectorPanel
var _loading_overlay: WorldLoadingOverlay
var _demand_detail_dialog
var _object_detail_dialog
var _object_detail_context: Dictionary = {}
var _inspector_view_model: CellInspectorViewModel
var _map: MapData
var _selected_cell: HexCell
var _selected_fog_state := VisionSolver.FOG_VISIBLE
var _last_cached_panel_ms: int = 0
var _live_revision_cell := -1
var _live_revision_tab := ""
var _live_common_hash := 0
var _live_category_generation := -1
var _live_category_hash := 0
var _live_revision_valid := false
var _country_facade = null
var _country_view_model: CountryViewModel
var _country_action_bar: CountryActionBar
var _country_panel: CountryPanel
var _gm_console: DebugConsole
var _perf_hud: PerfMiniHUD
var _diagnostics_source: Node = null
var _map_overlay_toolbar: MapOverlayToolbar
var _map_overlay_legend: OverlayLegend
var _pause_menu
var _gm_available := false
var _debug_layer: Control


func _ready() -> void:
	layer = 20
	_gm_available = gm_available_for_build(OS.is_debug_build(), Engine.is_editor_hint())
	_bind_ui()
	show_loading("正在生成世界")


static func gm_available_for_build(debug_build: bool, editor_hint: bool) -> bool:
	return debug_build or editor_hint


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
	_map = map
	_inspector_view_model.set_context(map, generator, view_adapter, world_clock, sea_level, hex_size)
	_invalidate_live_revision()
	_country_facade = generator.get_country_facade() if generator != null and \
		generator.has_method("get_country_facade") else null
	if _country_view_model == null:
		_country_view_model = CountryViewModel.new()
	_country_view_model.set_context(generator)
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
	_close_object_detail_dialog()
	if _gm_console != null:
		_gm_console.refresh_gm_capabilities()
	if _country_panel != null:
		_country_panel.visible = false
	if _country_action_bar != null:
		_country_action_bar.set_active("")


func set_diagnostics_source(source: Node) -> void:
	if _diagnostics_source != null and _diagnostics_source.has_signal("gm_toggle_changed"):
		var old_callback := Callable(self, "_on_runtime_gm_toggle_changed")
		if _diagnostics_source.is_connected("gm_toggle_changed", old_callback):
			_diagnostics_source.disconnect("gm_toggle_changed", old_callback)
	_diagnostics_source = source
	if source != null and source.has_signal("gm_toggle_changed"):
		var callback := Callable(self, "_on_runtime_gm_toggle_changed")
		if not source.is_connected("gm_toggle_changed", callback):
			source.connect("gm_toggle_changed", callback)
	if _gm_console != null:
		_gm_console.set_main(source)
	if _perf_hud != null:
		_perf_hud.set_main(source)


func toggle_gm_panel() -> void:
	if not _gm_available or _gm_console == null:
		return
	if _gm_console.is_panel_open():
		_gm_console.close_panel()
	else:
		_gm_console.open_panel()


func is_gm_available() -> bool:
	return _gm_available and _gm_console != null


func toggle_perf_hud() -> void:
	if _perf_hud != null:
		_perf_hud.toggle_visible()


func show_cell_panel(cell: HexCell) -> void:
	_close_object_detail_dialog()
	_selected_cell = cell
	_invalidate_live_revision()
	_last_cached_panel_ms = Time.get_ticks_msec()
	if _inspector_view_model == null or _right_panel == null:
		return
	if cell == null:
		hide_cell_panel()
		return
	# 只有当前可见的格子才值得开经济追踪：未探索与已探索但看不见的格子都拿不到
	# 经济页签，追踪它只会让 recorder 白算一份。
	_selected_fog_state = VisionSolver.fog_state(_map, int(cell.index))
	_set_inspector_trace_cell(int(cell.index) \
		if _selected_fog_state == VisionSolver.FOG_VISIBLE else -1)
	_right_panel.set_model_for_selection(_inspector_view_model.build(cell))
	if not _right_panel.visible:
		UIAnimation.fade_slide_in(_right_panel, Vector2(24.0, 0.0), UITokens.ANIM_MED)


func hide_cell_panel() -> void:
	_selected_cell = null
	_invalidate_live_revision()
	_set_inspector_trace_cell(-1)
	if _demand_detail_dialog != null:
		_demand_detail_dialog.close_dialog()
	_close_object_detail_dialog()
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
	# 视野状态变了意味着页签集合变了，打补丁改不动页签栏，必须整块重建。
	var fog := VisionSolver.fog_state(_map, int(_selected_cell.index))
	if fog != _selected_fog_state:
		_selected_fog_state = fog
		_set_inspector_trace_cell(int(_selected_cell.index) \
			if fog == VisionSolver.FOG_VISIBLE else -1)
		refresh_selected_panel()
		timing["ran"] = true
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
	refresh_country_summary()
	_refresh_object_detail_tax()


func open_country_section(section_id: String) -> void:
	if _country_panel == null or _country_view_model == null:
		return
	_country_action_bar.set_active(section_id)
	_country_panel.show_section(section_id, _country_view_model.build(section_id == "economy"))


func close_country_panel() -> void:
	if _country_panel != null and _country_panel.is_panel_open():
		_country_panel.close_panel()
	if _country_action_bar != null:
		_country_action_bar.set_active("")


func refresh_country_summary() -> Dictionary:
	var timing := {"ran": false, "elapsed_ms": 0.0}
	if _country_panel == null or not _country_panel.is_panel_open() \
			or _country_view_model == null:
		return timing
	var started_usec := Time.get_ticks_usec()
	_country_panel.refresh_summary(_country_view_model.build(
		_country_panel.current_section() == "economy"))
	timing["ran"] = true
	timing["elapsed_ms"] = (Time.get_ticks_usec() - started_usec) / 1000.0
	return timing


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


func _on_object_details_requested(request: Dictionary) -> void:
	if _selected_cell == null or _inspector_view_model == null \
			or _object_detail_dialog == null:
		return
	var payload := _inspector_view_model.build_object_detail(_selected_cell, request)
	if payload.is_empty():
		return
	_object_detail_context = {
		"cell_idx": int(_selected_cell.index),
		"kind": String(payload.get("kind", "")),
		"item_id": String(payload.get("item_id", "")),
	}
	_object_detail_dialog.show_details(payload)


func _close_object_detail_dialog() -> void:
	_object_detail_context = {}
	if _object_detail_dialog != null:
		_object_detail_dialog.close_dialog()


func _refresh_object_detail_tax() -> void:
	if _object_detail_dialog == null or not _object_detail_dialog.is_open() \
			or _object_detail_context.is_empty() or _inspector_view_model == null:
		return
	_object_detail_dialog.refresh_tax(_inspector_view_model.tax_slice_for_object(
		int(_object_detail_context.get("cell_idx", -1)),
		String(_object_detail_context.get("kind", "")),
		String(_object_detail_context.get("item_id", ""))))


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
	var bottom_height := CountryActionBar.BAR_HEIGHT + UITokens.SPACE_SM
	return Rect2(
		Vector2(left_width, top_height),
		Vector2(
			maxf(viewport_size.x - right_width - left_width, 1.0),
			maxf(viewport_size.y - top_height - bottom_height, 1.0)
		)
	)


func dismiss_overlay_menu() -> bool:
	if _country_panel != null and _country_panel.is_panel_open():
		close_country_panel()
		return true
	if _gm_console != null and _gm_console.is_panel_open():
		_gm_console.close_panel()
		return true
	return _map_overlay_toolbar != null and _map_overlay_toolbar.dismiss_submenu()


func toggle_pause_menu() -> void:
	if _pause_menu != null:
		_pause_menu.toggle()


func show_exit_save_failure(action: String, result: Dictionary) -> void:
	if _pause_menu != null:
		_pause_menu.show_save_failure(action, result)


func set_resource_discovery_context(
	technology_ids: PackedStringArray,
	enforce_discovery: bool = false
) -> void:
	if _map_overlay_toolbar != null:
		_map_overlay_toolbar.set_resource_discovery_context(
			technology_ids, enforce_discovery)


func _bind_ui() -> void:
	_top_bar = get_node("UIRoot/HUDLayer/PlayerTopBar") as PlayerTopBar
	_top_bar.pause_toggled.connect(func(paused: bool) -> void: pause_toggled.emit(paused))
	_top_bar.speed_selected.connect(func(speed: float) -> void: speed_selected.emit(speed))
	_top_bar.day_night_toggled.connect(
		func(enabled: bool) -> void: day_night_toggled.emit(enabled))
	_top_bar.setup_requested.connect(func() -> void: setup_requested.emit())
	_top_bar.gm_requested.connect(toggle_gm_panel)
	_top_bar.set_gm_available(_gm_available)

	_right_panel = get_node("UIRoot/PanelLayer/RightPanel") as InspectorPanel
	_right_panel.close_requested.connect(func() -> void: clear_selection_requested.emit())
	_right_panel.tab_data_requested.connect(_on_inspector_tab_data_requested)
	_right_panel.visibility_changed.connect(_layout_overlay_legend)
	_right_panel.demand_details_requested.connect(_on_demand_details_requested)
	_right_panel.object_details_requested.connect(_on_object_details_requested)

	_demand_detail_dialog = get_node("UIRoot/ModalLayer/DemandDetailDialog")
	_object_detail_dialog = get_node("UIRoot/ModalLayer/ObjectDetailDialog")
	_debug_layer = get_node("UIRoot/DebugLayer") as Control

	if _gm_available:
		_gm_console = DebugConsole.new()
		_gm_console.name = "GMConsole"
		_gm_console.console_mode = DebugConsole.ConsoleMode.PLAYER_GM
		_gm_console.set_anchors_preset(Control.PRESET_LEFT_WIDE)
		_gm_console.custom_minimum_size = Vector2.ZERO
		_debug_layer.add_child(_gm_console)
		_gm_console.set_gm_local_toggle_provider(
			Callable(self, "_get_local_gm_toggle_state"),
			Callable(self, "_set_local_gm_toggle"))
		_layout_gm_panel()

	_perf_hud = get_node("UIRoot/HUDLayer/PerfMiniHUD") as PerfMiniHUD

	_map_overlay_toolbar = get_node("UIRoot/HUDLayer/MapOverlayToolbar") as MapOverlayToolbar
	_map_overlay_toolbar.overlay_requested.connect(_on_map_overlay_requested)
	_map_overlay_toolbar.overlay_cleared.connect(_on_map_overlay_cleared)

	_country_action_bar = get_node("UIRoot/HUDLayer/CountryActionBar") as CountryActionBar
	_country_action_bar.section_selected.connect(open_country_section)
	_layout_country_action_bar()

	_map_overlay_legend = get_node("UIRoot/HUDLayer/MapOverlayLegend") as OverlayLegend
	# Bottom-right is outside the map's main reading line and the left tool
	# palette. The layout helper shifts it left whenever Inspector is visible.
	_map_overlay_legend.set_anchors_preset(Control.PRESET_BOTTOM_RIGHT)
	_map_overlay_legend.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	_map_overlay_legend.grow_vertical = Control.GROW_DIRECTION_BEGIN
	get_viewport().size_changed.connect(_layout_overlay_legend)
	get_viewport().size_changed.connect(_layout_gm_panel)
	get_viewport().size_changed.connect(_layout_country_action_bar)
	_layout_overlay_legend()

	if _diagnostics_source != null:
		set_diagnostics_source(_diagnostics_source)

	_country_panel = get_node("UIRoot/PanelLayer/CountryPanel") as CountryPanel
	_country_panel.close_requested.connect(func() -> void:
		if _country_action_bar != null:
			_country_action_bar.set_active("")
	)
	_country_panel.section_selected.connect(func(section_id: String) -> void:
		if _country_action_bar != null:
			_country_action_bar.set_active(section_id)
	)

	_loading_overlay = get_node("UIRoot/ModalLayer/WorldLoadingOverlay") as WorldLoadingOverlay

	_pause_menu = get_node("UIRoot/ModalLayer/PauseMenu") as PauseMenu
	_pause_menu.visibility_requested.connect(
		func(open: bool) -> void: pause_menu_visibility_changed.emit(open))
	_pause_menu.return_menu_requested.connect(func() -> void: return_main_menu_requested.emit())
	_pause_menu.exit_requested.connect(func() -> void: exit_game_requested.emit())

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
	_map_overlay_legend.offset_bottom = -CountryActionBar.BAR_HEIGHT - UITokens.SPACE_LG
	# A zero-height anchored rect plus BEGIN growth keeps variable legend
	# content attached to the bottom edge instead of growing off-screen.
	_map_overlay_legend.offset_top = _map_overlay_legend.offset_bottom


func _layout_country_action_bar() -> void:
	if _country_action_bar == null:
		return
	var viewport_width := get_viewport().get_visible_rect().size.x
	var side_margin := maxf((viewport_width - 320.0) * 0.5, UITokens.SPACE_SM)
	_country_action_bar.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	_country_action_bar.offset_left = side_margin
	_country_action_bar.offset_right = -side_margin
	_country_action_bar.offset_top = -CountryActionBar.BAR_HEIGHT - UITokens.SPACE_SM
	_country_action_bar.offset_bottom = -UITokens.SPACE_SM
	var window_width := get_window().size.x if get_window() != null else int(viewport_width)
	_country_action_bar.set_compact(window_width < 720)


func _layout_gm_panel() -> void:
	if _gm_console == null:
		return
	var viewport_width := get_viewport().get_visible_rect().size.x
	var available := viewport_width - RIGHT_PANEL_WIDTH - UITokens.SPACE_MD * 3.0
	var panel_width := clampf(available, GM_PANEL_MIN_WIDTH, GM_PANEL_TARGET_WIDTH)
	_gm_console.offset_left = UITokens.SPACE_SM
	_gm_console.offset_right = UITokens.SPACE_SM + panel_width
	_gm_console.offset_top = PlayerTopBar.BAR_HEIGHT + UITokens.SPACE_SM
	_gm_console.offset_bottom = -UITokens.SPACE_SM


func _get_local_gm_toggle_state(toggle_id: String) -> Dictionary:
	if toggle_id == "diagnostics.perf_hud" and _perf_hud != null:
		return {"ok": true, "enabled": _perf_hud.visible}
	return {"ok": false, "message": "未知本地 GM 开关。"}


func _set_local_gm_toggle(toggle_id: String, enabled: bool) -> Dictionary:
	if toggle_id != "diagnostics.perf_hud" or _perf_hud == null:
		return {"ok": false, "message": "未知本地 GM 开关。"}
	if _perf_hud.visible != enabled:
		_perf_hud.toggle_visible()
	return {"ok": true, "enabled": _perf_hud.visible, "message": "Perf HUD 已更新。"}


func _on_runtime_gm_toggle_changed(toggle_id: String, enabled: bool) -> void:
	if toggle_id == "visual.day_night":
		set_day_night_enabled(enabled)
