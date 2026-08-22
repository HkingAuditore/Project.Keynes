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
signal era_reward_choice_requested(offer_generation: int, choice_index: int)

const RIGHT_PANEL_WIDTH := 460.0
const DETAIL_LAYOUT_BREAKPOINT := 1180.0
const FAMILY_WORKSPACE_BREAKPOINT := 1280.0
const DETAIL_PANEL_MIN_WIDTH := 860.0
const DETAIL_PANEL_MAX_WIDTH := 1040.0
const MAP_REMAINING_MIN_WIDTH := 320.0
const OVERLAY_LEGEND_WIDTH := 198.0
const GM_PANEL_TARGET_WIDTH := 560.0
const GM_PANEL_MIN_WIDTH := 300.0
const INSPECTOR_FULL_PATCH_INTERVAL_MSEC := 750
var _top_bar: PlayerTopBar
var _right_panel: InspectorPanel
var _loading_overlay: WorldLoadingOverlay
var _colonization_panel: ColonizationPlannerPanel
var _colonization_route: ColonizationRouteLayer
var _colonization_targeting: Dictionary = {}
var _object_detail_context: Dictionary = {}
var _inspector_view_model: CellInspectorViewModel
var _map: MapData
var _selected_cell: HexCell
var _selected_fog_state := VisionSolver.FOG_VISIBLE
var _last_cached_panel_ms: int = 0
var _last_object_detail_ms: int = 0
var _live_revision_cell := -1
var _live_revision_tab := ""
var _live_common_hash := 0
var _live_category_generation := -1
var _live_tax_policy_version := -1
var _live_category_hash := 0
var _live_revision_valid := false
var _selection_context := ""
var _player_controller = null
var _country_view_model: CountryViewModel
var _country_action_bar: CountryActionBar
var _country_panel: CountryPanel
var _gm_console: DebugConsole
var _perf_hud: PerfMiniHUD
var _diagnostics_source: Node = null
var _map_overlay_toolbar: MapOverlayToolbar
var _map_overlay_legend: OverlayLegend
var _pause_menu
var _era_reward_dialog: EraRewardDialog
var _gm_available := false
var _debug_layer: Control
var _inspector_suppressed_for_country := false
var _country_runtime_facade = null
var _economy_runtime_facade = null
var _ideology_runtime_facade = null
var _country_refresh_queued := false
var _country_open_generation := 0
var _country_dirty_domains := 0
var _country_refresh_reason := ""
var _country_ui_event_refresh_enabled := true
var _country_ui_perf_pending: Dictionary = {}

const COUNTRY_DIRTY_TECHNOLOGY := 1
const COUNTRY_DIRTY_ECONOMY := 2
const COUNTRY_DIRTY_IDEOLOGY := 4
const COUNTRY_DIRTY_ALL := COUNTRY_DIRTY_TECHNOLOGY | COUNTRY_DIRTY_ECONOMY | COUNTRY_DIRTY_IDEOLOGY


func _ready() -> void:
	layer = 20
	_country_ui_event_refresh_enabled = bool(Engine.get_meta(
		&"country_ui_event_refresh_enabled", true))
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
	if _inspector_view_model == null:
		_inspector_view_model = CellInspectorViewModel.new()
	_map = map
	if _colonization_route != null:
		var wrap_period := float(_diagnostics_source.map_wrap_period_x()) \
			if _diagnostics_source != null and _diagnostics_source.has_method(
				"map_wrap_period_x") else 0.0
		_colonization_route.set_context(map, world_clock, hex_size, wrap_period)
	_inspector_view_model.set_context(map, generator, view_adapter, world_clock, sea_level, hex_size)
	_object_detail_context.clear()
	_selection_context = ""
	_invalidate_live_revision()
	if _country_view_model == null:
		_country_view_model = CountryViewModel.new()
	_country_view_model.set_context(generator)
	_bind_country_runtime_events(generator)
	_refresh_player_discovery_context()
	if _right_panel != null:
		_right_panel.reset_for_world()
	if _country_panel != null and _country_panel.has_method("set_player_controller"):
		_country_panel.set_player_controller(_player_controller)
	if _map_overlay_toolbar != null:
		_map_overlay_toolbar.reset_for_world()
	if _map_overlay_legend != null:
		_map_overlay_legend.update_for_mode(OverlayMode.MODE.NONE)
	if _right_panel != null:
		_right_panel.close_detail(false)
	if _colonization_panel != null:
		_colonization_panel.close_panel()
	if _gm_console != null:
		_gm_console.refresh_gm_capabilities()
	if _country_panel != null:
		_country_panel.visible = false
	if _country_action_bar != null:
		_country_action_bar.set_active("")


func _bind_country_runtime_events(generator) -> void:
	if _country_runtime_facade != null and _country_runtime_facade.has_signal(
			"research_signal_discovered"):
		var old_research := Callable(self, "_on_country_research_signal_discovered")
		if _country_runtime_facade.research_signal_discovered.is_connected(old_research):
			_country_runtime_facade.research_signal_discovered.disconnect(old_research)
	if _economy_runtime_facade != null and _economy_runtime_facade.has_signal(
			"economy_event_batch_available"):
		var old_economy := Callable(self, "_on_economy_event_batch_available")
		if _economy_runtime_facade.economy_event_batch_available.is_connected(old_economy):
			_economy_runtime_facade.economy_event_batch_available.disconnect(old_economy)
	if _ideology_runtime_facade != null and _ideology_runtime_facade.has_signal(
			"command_settled"):
		var old_ideology := Callable(self, "_on_ideology_runtime_settled")
		if _ideology_runtime_facade.command_settled.is_connected(old_ideology):
			_ideology_runtime_facade.command_settled.disconnect(old_ideology)
	_country_runtime_facade = generator.get_country_facade() if generator != null \
		and generator.has_method("get_country_facade") else null
	_economy_runtime_facade = generator.get_economy_facade() if generator != null \
		and generator.has_method("get_economy_facade") else null
	_ideology_runtime_facade = generator.get_ideology_facade() if generator != null \
		and generator.has_method("get_ideology_facade") else null
	if _country_runtime_facade != null and _country_runtime_facade.has_signal(
			"research_signal_discovered"):
		var research := Callable(self, "_on_country_research_signal_discovered")
		if not _country_runtime_facade.research_signal_discovered.is_connected(research):
			_country_runtime_facade.research_signal_discovered.connect(research)
	if _economy_runtime_facade != null and _economy_runtime_facade.has_signal(
			"economy_event_batch_available"):
		var economy := Callable(self, "_on_economy_event_batch_available")
		if not _economy_runtime_facade.economy_event_batch_available.is_connected(economy):
			_economy_runtime_facade.economy_event_batch_available.connect(economy)
	if _ideology_runtime_facade != null and _ideology_runtime_facade.has_signal(
			"command_settled"):
		var ideology := Callable(self, "_on_ideology_runtime_settled")
		if not _ideology_runtime_facade.command_settled.is_connected(ideology):
			_ideology_runtime_facade.command_settled.connect(ideology)
	_country_dirty_domains = COUNTRY_DIRTY_ALL
	_country_refresh_queued = false


func _on_country_research_signal_discovered(_event: Dictionary) -> void:
	_mark_country_panel_dirty(COUNTRY_DIRTY_TECHNOLOGY, "research_signal")


func _on_economy_event_batch_available(_meta: Dictionary) -> void:
	_mark_country_panel_dirty(COUNTRY_DIRTY_ECONOMY, "economy_commit")


func _on_ideology_runtime_settled(_result: Dictionary) -> void:
	_mark_country_panel_dirty(COUNTRY_DIRTY_IDEOLOGY, "ideology_commit")


func _country_section_mask(section_id: String) -> int:
	match section_id:
		"economy":
			return COUNTRY_DIRTY_ECONOMY
		"ideology":
			return COUNTRY_DIRTY_IDEOLOGY
		_:
			return COUNTRY_DIRTY_TECHNOLOGY


func _mark_country_panel_dirty(domains: int, reason: String) -> void:
	_country_dirty_domains |= domains
	_country_refresh_reason = reason
	if _country_view_model != null:
		_country_view_model.invalidate_cache(domains)
	if _country_panel == null or not _country_panel.is_panel_open() \
			or _country_refresh_queued:
		return
	if not _country_ui_event_refresh_enabled:
		refresh_country_summary()
		_country_dirty_domains &= ~_country_section_mask(
			_country_panel.current_section())
		return
	_country_refresh_queued = true
	call_deferred("_flush_country_panel_refresh")


func _flush_country_panel_refresh() -> void:
	_country_refresh_queued = false
	if _country_panel == null or not _country_panel.is_panel_open():
		return
	var section_mask := _country_section_mask(_country_panel.current_section())
	if (_country_dirty_domains & section_mask) == 0:
		return
	refresh_country_summary()
	_country_dirty_domains &= ~section_mask
	_country_refresh_reason = ""


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


func set_colonization_route_layer(layer: ColonizationRouteLayer) -> void:
	_colonization_route = layer


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
	if _right_panel != null:
		_right_panel.close_detail(false)
	_object_detail_context.clear()
	_selected_cell = cell
	if not _colonization_targeting.is_empty():
		var targeting := _colonization_targeting.duplicate()
		_colonization_targeting.clear()
		_open_colonization_target(int(cell.index),
			int(targeting.get("family_handle", 0)),
			int(targeting.get("source_cell", -1)))
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
	_selection_context = _revision_selection_context(
		_inspector_view_model.live_patch_revision(cell, _right_panel.current_tab()))
	if _country_panel != null and _country_panel.is_panel_open():
		_inspector_suppressed_for_country = true
		_right_panel.visible = false
		return
	if not _right_panel.visible:
		UIAnimation.fade_slide_in(_right_panel, Vector2(24.0, 0.0), UITokens.ANIM_MED)


func hide_cell_panel() -> void:
	_selected_cell = null
	_selection_context = ""
	_inspector_suppressed_for_country = false
	_invalidate_live_revision()
	_set_inspector_trace_cell(-1)
	if _right_panel != null:
		_right_panel.close_detail(false)
	if _right_panel != null:
		UIAnimation.fade_slide_out(_right_panel, Vector2(24.0, 0.0), UITokens.ANIM_FAST)


func refresh_selected_daily_lines(force: bool = false, day_idx: int = -1) -> Dictionary:
	var timing: Dictionary = {
		"ran": false,
		"tab": "",
		"live_patch_build_ms": 0.0,
		"live_patch_apply_ms": 0.0,
	}
	if _colonization_panel != null and _colonization_panel.visible:
		_colonization_panel.refresh_visible()
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
	var population_list := tab_id == "population"
	# 市场/建筑/地理的完整 category 仍按墙钟合并。人口列表改走无需求预览的
	# list snapshot，每个模拟日都能改人数，不再被 750ms 拖住。
	if not force and not population_list \
			and now_ms - _last_cached_panel_ms < INSPECTOR_FULL_PATCH_INTERVAL_MSEC:
		_refresh_object_detail(false)
		if _right_panel.detail_open():
			timing["ran"] = true
		return timing
	if not population_list:
		_last_cached_panel_ms = now_ms
	var revision: Dictionary = _inspector_view_model.live_patch_revision(
		_selected_cell, tab_id)
	var next_selection_context := _revision_selection_context(revision)
	if not _selection_context.is_empty() and next_selection_context != _selection_context:
		_selection_context = next_selection_context
		refresh_selected_panel()
		timing["ran"] = true
		return timing
	_selection_context = next_selection_context
	var build_started_usec := Time.get_ticks_usec()
	var patch := _inspector_view_model.build_live_patch(
		_selected_cell,
		tab_id,
		true,
		revision.get("population_summary", {}),
		not population_list
	)
	timing["live_patch_build_ms"] = (
		Time.get_ticks_usec() - build_started_usec) / 1000.0
	if population_list:
		var next_category_hash := 0
		if patch.has("category"):
			next_category_hash = hash(patch["category"])
		var same_target := _live_revision_valid \
			and _live_revision_cell == int(_selected_cell.index) \
			and _live_revision_tab == tab_id
		if same_target and next_category_hash == _live_category_hash:
			patch.erase("category")
		else:
			_live_category_hash = next_category_hash
		_live_revision_cell = int(_selected_cell.index)
		_live_revision_tab = tab_id
		_live_common_hash = int(revision.get("common_hash", 0))
		_live_category_generation = int(revision.get("category_generation", -1))
		_live_tax_policy_version = int(revision.get("tax_policy_version", -1))
		_live_revision_valid = true
	var apply_started_usec := Time.get_ticks_usec()
	_right_panel.apply_live_patch(patch)
	_refresh_object_detail(force or not population_list)
	timing["live_patch_apply_ms"] = (
		Time.get_ticks_usec() - apply_started_usec) / 1000.0
	timing["ran"] = true
	return timing


func refresh_selected_panel() -> void:
	if _selected_cell == null or _inspector_view_model == null or _right_panel == null:
		return
	_invalidate_live_revision()
	_right_panel.set_model_for_selection(_inspector_view_model.build(_selected_cell))
	_selection_context = _revision_selection_context(
		_inspector_view_model.live_patch_revision(
			_selected_cell, _right_panel.current_tab()))
	_refresh_object_detail(true)


func _revision_selection_context(revision: Dictionary) -> String:
	return "%s|%s" % [
		String(revision.get("selection_context", "")),
		String(revision.get("tabs_signature", "")),
	]


func _on_country_committed(_report: Dictionary) -> void:
	# 税务提交与日常经济提交都只更新当前页的稳定节点；领土/视野改变由各自的
	# 明确事件触发整块选择重建，不能在这里摧毁输入焦点和滚动状态。
	refresh_selected_daily_lines(true)
	_mark_country_panel_dirty(COUNTRY_DIRTY_ALL, "country_committed")
	_refresh_player_discovery_context()


func open_country_section(section_id: String) -> void:
	if _country_panel == null or _country_view_model == null:
		return
	_hide_inspector_for_country()
	_country_action_bar.set_active(section_id)
	_country_open_generation += 1
	var generation := _country_open_generation
	if not _country_ui_event_refresh_enabled:
		var started_usec := Time.get_ticks_usec()
		_country_panel.show_section(section_id, _country_view_model.build_legacy(section_id))
		_record_country_ui_perf("legacy_full_build", false,
			(Time.get_ticks_usec() - started_usec) / 1000.0,
			_country_section_mask(section_id))
		_country_dirty_domains &= ~_country_section_mask(section_id)
		return
	var cached := _country_view_model.cached_section(section_id)
	if not cached.is_empty():
		_country_panel.show_section(section_id, cached)
		_record_country_ui_perf("panel_open_cache", true, 0.0,
			_country_section_mask(section_id))
		_country_dirty_domains &= ~_country_section_mask(section_id)
		return
	_country_panel.show_section(section_id, {
		"available": false,
		"country_name": "国家事务",
		"reason": "正在载入已提交数据",
	})
	call_deferred("_load_country_section_deferred", section_id, generation)


func _load_country_section_deferred(section_id: String, generation: int) -> void:
	if generation != _country_open_generation or _country_panel == null \
			or not _country_panel.is_panel_open() \
			or _country_panel.current_section() != section_id:
		return
	var started_usec := Time.get_ticks_usec()
	_country_panel.refresh_summary(_country_view_model.build(section_id))
	_record_country_ui_perf("panel_open", false,
		(Time.get_ticks_usec() - started_usec) / 1000.0,
		_country_section_mask(section_id))
	_country_dirty_domains &= ~_country_section_mask(section_id)


func close_country_panel() -> void:
	_country_open_generation += 1
	if _country_panel != null and _country_panel.is_panel_open():
		_country_panel.close_panel()
	# A closed panel never needs a fresh Native query. Drop only dynamic section
	# models so the next open starts from a committed shell and loads details
	# through the deferred section path; the static catalog remains session-cached.
	if _country_view_model != null:
		_country_view_model.invalidate_cache()
	if _country_action_bar != null:
		_country_action_bar.set_active("")


func _hide_inspector_for_country() -> void:
	if _right_panel == null or not _right_panel.visible:
		return
	_inspector_suppressed_for_country = true
	_right_panel.visible = false


func _restore_inspector_after_country() -> void:
	if not _inspector_suppressed_for_country:
		return
	_inspector_suppressed_for_country = false
	if _selected_cell == null or _right_panel == null:
		return
	_right_panel.visible = true
	_right_panel.modulate.a = 1.0


func refresh_country_summary() -> Dictionary:
	var timing := {"ran": false, "elapsed_ms": 0.0}
	if _country_panel == null or not _country_panel.is_panel_open() \
			or _country_view_model == null:
		return timing
	var started_usec := Time.get_ticks_usec()
	var model := _country_view_model.build(_country_panel.current_section()) \
		if _country_ui_event_refresh_enabled else _country_view_model.build_legacy(
			_country_panel.current_section())
	_country_panel.refresh_summary(model)
	timing["ran"] = true
	timing["elapsed_ms"] = (Time.get_ticks_usec() - started_usec) / 1000.0
	_record_country_ui_perf(
		_country_refresh_reason if not _country_refresh_reason.is_empty() else "explicit",
		false, float(timing["elapsed_ms"]),
		_country_section_mask(_country_panel.current_section()))
	return timing


func _record_country_ui_perf(reason: String, cache_hit: bool,
		snapshot_ms: float, dirty_domains: int) -> void:
	_country_ui_perf_pending = {
		"country_ui_refresh_reason": reason,
		"country_ui_snapshot_ms": maxf(0.0, snapshot_ms),
		"country_ui_cache_hit": cache_hit,
		"country_ui_dirty_domains": dirty_domains,
		"country_ui_event_refresh_enabled": _country_ui_event_refresh_enabled,
	}


func consume_country_ui_perf_summary() -> Dictionary:
	var out := _country_ui_perf_pending.duplicate(false)
	_country_ui_perf_pending.clear()
	return out


func _on_inspector_tab_data_requested(tab_id: String) -> void:
	if _selected_cell == null or _inspector_view_model == null or _right_panel == null:
		return
	_invalidate_live_revision()
	_right_panel.set_tab_category(
		tab_id, _inspector_view_model.build_tab_category(_selected_cell, tab_id))


func _on_construction_page_requested(search: String, offset: int) -> void:
	if _selected_cell == null or _inspector_view_model == null or _right_panel == null:
		return
	_right_panel.set_construction_model(
		_inspector_view_model.build_construction_options(
			int(_selected_cell.index), search, offset))


func _on_construction_requested(request: Dictionary) -> void:
	if _selected_cell == null or _player_controller == null or _right_panel == null:
		return
	var result: Dictionary = _player_controller.request_command(
		&"construction.build", {"cell_idx": int(_selected_cell.index),
			"building_id": StringName(request.get("building_id", &"")),
			"ownership_policy": &"treasury_sponsored_private"})
	_right_panel.set_construction_feedback(
		String(result.get("message", result.get("reason", "修建命令未能提交。"))),
		bool(result.get("ok", false)))


func _open_colonization_target(target_cell: int, family_handle: int = 0,
		source_cell: int = -1) -> void:
	if _colonization_panel == null:
		return
	_close_object_detail_dialog()
	_colonization_panel.open_target(target_cell, family_handle, source_cell)


func _on_colonization_requested(request: Dictionary) -> void:
	_open_colonization_target(int(request.get("target_cell", -1)))


func _on_family_colonization_requested(family_handle: int,
		source_cell: int) -> void:
	_colonization_targeting = {
		"family_handle": family_handle,
		"source_cell": source_cell,
	}
	_close_object_detail_dialog()
	if _right_panel != null:
		_right_panel.hide()


func _on_colonization_start_requested(args: Dictionary) -> void:
	if _player_controller == null or _colonization_panel == null:
		return
	var result: Dictionary = _player_controller.request_command(
		&"family.colonization.start", args)
	_colonization_panel.set_command_result(result)
	if bool(result.get("ok", false)) and result.has("expedition_handle"):
		_on_expedition_selected(int(result.expedition_handle))


func _on_colonization_cancel_requested(expedition_handle: int) -> void:
	if _player_controller == null or _colonization_panel == null:
		return
	var result: Dictionary = _player_controller.request_command(
		&"family.colonization.cancel", {"expedition_handle": expedition_handle})
	_colonization_panel.set_command_result(result)
	if bool(result.get("ok", false)):
		_on_expedition_selected(expedition_handle)


func _on_expedition_selected(expedition_handle: int) -> void:
	if _player_controller == null or _colonization_route == null:
		return
	var snapshot: Dictionary = _player_controller.get_family_expedition_snapshot(
		expedition_handle)
	if bool(snapshot.get("ok", false)):
		_colonization_route.show_expedition(snapshot)


func _on_player_command_settled(id: StringName, result: Dictionary) -> void:
	if id == &"family.colonization.start" or \
			id == &"family.colonization.cancel":
		if _colonization_panel != null:
			if not result.has("message"):
				result["message"] = "开拓队状态已更新。"
			_colonization_panel.set_command_result(result)
			_colonization_panel.refresh_expeditions_if_visible()
		if _selected_cell != null and String(result.get("code", "")) == "CLAIMED":
			refresh_selected_panel()
		_mark_country_panel_dirty(COUNTRY_DIRTY_ECONOMY, "colonization_settled")
		return
	if id != &"construction.build" or _selected_cell == null or \
			int(result.get("cell_idx", -1)) != int(_selected_cell.index):
		return
	refresh_selected_panel()
	if _right_panel != null:
		_right_panel.set_construction_feedback(
			String(result.get("message", "修建命令已结算。")),
			bool(result.get("ok", false)))
	_mark_country_panel_dirty(COUNTRY_DIRTY_ECONOMY, "construction_settled")


func _invalidate_live_revision() -> void:
	_live_revision_cell = -1
	_live_revision_tab = ""
	_live_common_hash = 0
	_live_category_generation = -1
	_live_tax_policy_version = -1
	_live_category_hash = 0
	_live_revision_valid = false


func _on_object_details_requested(request: Dictionary) -> void:
	if _selected_cell == null or _inspector_view_model == null \
			or _right_panel == null:
		return
	var is_family := String(request.get("kind", "")) == "family"
	var payload := _inspector_view_model.build_family_detail(_selected_cell, request) \
		if is_family else _inspector_view_model.build_object_detail(_selected_cell, request)
	if payload.is_empty():
		return
	_object_detail_context = {
		"cell_idx": int(_selected_cell.index),
		"kind": "family" if is_family else String(payload.get("kind", "")),
		"item_id": String(payload.get("item_id", "")),
	}
	_object_detail_context["request"] = request.duplicate(true)
	if is_family:
		_right_panel.show_family_workspace(payload)
	else:
		_right_panel.show_object_detail(payload)


func _close_object_detail_dialog() -> void:
	_object_detail_context = {}
	if _right_panel != null:
		_right_panel.close_detail(false)


func _refresh_object_detail(force: bool = false) -> void:
	if _object_detail_context.is_empty() or _selected_cell == null \
			or _inspector_view_model == null or _right_panel == null \
			or not _right_panel.detail_open():
		return
	var now_ms := Time.get_ticks_msec()
	if not force and now_ms - _last_object_detail_ms < 200:
		return
	if int(_object_detail_context.get("cell_idx", -1)) != int(_selected_cell.index):
		_close_object_detail_dialog()
		return
	var request: Dictionary = _object_detail_context.get("request", {})
	var is_family := String(_object_detail_context.get("kind", "")) == "family"
	var payload := _inspector_view_model.build_family_detail(_selected_cell, request) \
		if is_family else _inspector_view_model.build_object_detail(_selected_cell, request)
	if payload.is_empty():
		_close_object_detail_dialog()
		return
	_last_object_detail_ms = now_ms
	if is_family:
		_right_panel.refresh_family_workspace(payload)
	else:
		_right_panel.refresh_object_detail(payload)


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
	if is_era_reward_modal_open():
		return true
	if not _colonization_targeting.is_empty():
		_cancel_colonization_targeting()
		return true
	if _colonization_panel != null and _colonization_panel.visible:
		_colonization_panel.close_panel()
		return true
	if _country_panel != null and _country_panel.is_panel_open():
		close_country_panel()
		return true
	if _gm_console != null and _gm_console.is_panel_open():
		_gm_console.close_panel()
		return true
	if _map_overlay_toolbar != null and _map_overlay_toolbar.dismiss_submenu():
		return true
	if _right_panel != null and _right_panel.visible:
		clear_selection_requested.emit()
		return true
	return false


func toggle_pause_menu() -> void:
	if _pause_menu != null and not is_era_reward_modal_open():
		_pause_menu.toggle()


func show_era_reward_offer(offer: Dictionary) -> void:
	if _era_reward_dialog != null:
		_era_reward_dialog.present_offer(offer)


func show_era_reward_error(message: String) -> void:
	if _era_reward_dialog != null:
		_era_reward_dialog.show_error(message)


func show_era_reward_pending() -> void:
	if _era_reward_dialog != null:
		_era_reward_dialog.show_pending()


func close_era_reward_offer() -> void:
	if _era_reward_dialog != null:
		_era_reward_dialog.close_offer()


func is_era_reward_modal_open() -> bool:
	return _era_reward_dialog != null and _era_reward_dialog.is_offer_open()


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


func _refresh_player_discovery_context() -> void:
	if _country_view_model == null:
		return
	var technology_ids: PackedStringArray = \
		_country_view_model.player_completed_technology_ids()
	if technology_ids.is_empty():
		return
	set_resource_discovery_context(technology_ids, true)


func set_player_controller(controller) -> void:
	if _player_controller != null and _player_controller.has_signal("country_committed"):
		var old_callback := Callable(self, "_on_country_committed")
		if _player_controller.country_committed.is_connected(old_callback):
			_player_controller.country_committed.disconnect(old_callback)
	if _player_controller != null and _player_controller.has_signal("command_settled"):
		var old_settled := Callable(self, "_on_player_command_settled")
		if _player_controller.command_settled.is_connected(old_settled):
			_player_controller.command_settled.disconnect(old_settled)
	_player_controller = controller
	if _country_panel != null and _country_panel.has_method("set_player_controller"):
		_country_panel.set_player_controller(controller)
	if _right_panel != null and _right_panel.has_method("set_player_controller"):
		_right_panel.set_player_controller(controller)
	if _colonization_panel != null:
		_colonization_panel.set_player_controller(controller)
	if _player_controller != null and _player_controller.has_signal("country_committed"):
		var callback := Callable(self, "_on_country_committed")
		if not _player_controller.country_committed.is_connected(callback):
			_player_controller.country_committed.connect(callback)
	if _player_controller != null and _player_controller.has_signal("command_settled"):
		var settled := Callable(self, "_on_player_command_settled")
		if not _player_controller.command_settled.is_connected(settled):
			_player_controller.command_settled.connect(settled)


func _bind_ui() -> void:
	_top_bar = get_node("UIRoot/HUDLayer/PlayerTopBar") as PlayerTopBar
	_top_bar.pause_toggled.connect(func(paused: bool) -> void: pause_toggled.emit(paused))
	_top_bar.speed_selected.connect(func(speed: float) -> void: speed_selected.emit(speed))
	_top_bar.day_night_toggled.connect(
		func(enabled: bool) -> void: day_night_toggled.emit(enabled))
	_top_bar.setup_requested.connect(func() -> void: setup_requested.emit())
	_top_bar.gm_requested.connect(toggle_gm_panel)
	_top_bar.set_gm_available(_gm_available)
	_layout_top_bar()

	_right_panel = get_node("UIRoot/PanelLayer/RightPanel") as InspectorPanel
	_right_panel.set_player_controller(_player_controller)
	_right_panel.close_requested.connect(func() -> void: clear_selection_requested.emit())
	_right_panel.tab_data_requested.connect(_on_inspector_tab_data_requested)
	_right_panel.visibility_changed.connect(_on_inspector_visibility_changed)
	_right_panel.object_details_requested.connect(_on_object_details_requested)
	_right_panel.detail_visibility_changed.connect(
		_on_inspector_detail_visibility_changed)
	_right_panel.family_colonization_requested.connect(
		_on_family_colonization_requested)
	_right_panel.construction_page_requested.connect(_on_construction_page_requested)
	_right_panel.construction_requested.connect(_on_construction_requested)
	_right_panel.colonization_requested.connect(_on_colonization_requested)
	_layout_right_panel()

	_colonization_panel = get_node(
		"UIRoot/ModalLayer/ColonizationPlannerPanel") as ColonizationPlannerPanel
	_colonization_panel.set_player_controller(_player_controller)
	_colonization_panel.route_requested.connect(func(detail: Dictionary) -> void:
		if _colonization_route != null:
			_colonization_route.show_quote(detail)
	)
	_colonization_panel.route_cleared.connect(func() -> void:
		if _colonization_route != null:
			_colonization_route.clear_route()
	)
	_colonization_panel.start_requested.connect(_on_colonization_start_requested)
	_colonization_panel.cancel_requested.connect(_on_colonization_cancel_requested)
	_colonization_panel.expedition_selected.connect(_on_expedition_selected)
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
	get_viewport().size_changed.connect(_layout_top_bar)
	get_viewport().size_changed.connect(_layout_right_panel)
	_layout_overlay_legend()
	_log_ui_layout_diagnostics("bind_ui")

	if _diagnostics_source != null:
		set_diagnostics_source(_diagnostics_source)

	_country_panel = get_node("UIRoot/PanelLayer/CountryPanel") as CountryPanel
	_country_panel.close_requested.connect(func() -> void:
		if _country_action_bar != null:
			_country_action_bar.set_active("")
		_restore_inspector_after_country()
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
	_era_reward_dialog = get_node(
		"UIRoot/ModalLayer/EraRewardDialog") as EraRewardDialog
	_era_reward_dialog.choice_requested.connect(
		func(generation: int, index: int) -> void:
			era_reward_choice_requested.emit(generation, index))


func _cancel_colonization_targeting() -> void:
	_colonization_targeting.clear()
	if _colonization_route != null:
		_colonization_route.clear_route()
	if _selected_cell != null and _right_panel != null:
		show_cell_panel(_selected_cell)


func _unhandled_input(event: InputEvent) -> void:
	if _colonization_targeting.is_empty():
		return
	if event is InputEventKey and event.pressed and not event.echo \
			and event.keycode == KEY_ESCAPE:
		_cancel_colonization_targeting()
		get_viewport().set_input_as_handled()
	elif event is InputEventMouseButton and event.pressed \
			and event.button_index == MOUSE_BUTTON_RIGHT:
		_cancel_colonization_targeting()
		get_viewport().set_input_as_handled()

func _on_map_overlay_requested(request: Dictionary) -> void:
	var mode := int(request.get("mode", OverlayMode.MODE.NONE))
	var title := ""
	var icon_key := ""
	var hint := ""
	var occupancy_bit := -1
	if mode == OverlayMode.MODE.RESOURCE_RESERVE:
		var resource_id := StringName(request.get("resource_id", &""))
		for profile in ResourceProfileRegistry.ordered():
			if profile != null and profile.id == resource_id:
				title = profile.display_name
				icon_key = ResourceProfileRegistry.icon_key(profile)
				break
		hint = "透明区域无可用储量"
	elif mode == OverlayMode.MODE.BIO_OCCUPANCY:
		var signal_id := StringName(request.get("signal_id", &""))
		for entry in ResearchSignalCatalog.occupancy_overlay_entries():
			if StringName(entry.get("id", &"")) == signal_id:
				title = String(entry.get("display_name", ""))
				icon_key = String(entry.get("icon_key", &"ecology.growth"))
				occupancy_bit = int(entry.get("occupancy_bit", -1))
				break
		hint = "透明区域当前没有该物种"
	if _map_overlay_legend != null:
		_map_overlay_legend.update_for_mode(mode, title, hint, icon_key, occupancy_bit)
		call_deferred("_layout_overlay_legend")
	map_overlay_requested.emit(request)


func _on_map_overlay_cleared() -> void:
	if _map_overlay_legend != null:
		_map_overlay_legend.update_for_mode(OverlayMode.MODE.NONE)
	map_overlay_cleared.emit()


func _on_inspector_visibility_changed() -> void:
	_layout_right_panel()
	_layout_overlay_legend()
	_layout_country_action_bar()
	_layout_gm_panel()


func _on_inspector_detail_visibility_changed(open: bool) -> void:
	if not open:
		_object_detail_context.clear()
	_layout_right_panel()
	_layout_overlay_legend()
	_layout_country_action_bar()
	_layout_gm_panel()
	var wide_threshold := FAMILY_WORKSPACE_BREAKPOINT \
		if _right_panel != null and _right_panel.family_workspace_open() \
		else DETAIL_LAYOUT_BREAKPOINT
	if open and get_viewport().get_visible_rect().size.x >= wide_threshold \
			and _player_controller != null and _player_controller.has_method(
			"ensure_selected_visible"):
		_player_controller.ensure_selected_visible()


func _layout_overlay_legend() -> void:
	if _map_overlay_legend == null:
		return
	var compact_detail := _right_panel != null and _right_panel.detail_open() \
		and get_viewport().get_visible_rect().size.x < (
			FAMILY_WORKSPACE_BREAKPOINT if _right_panel.family_workspace_open() \
			else DETAIL_LAYOUT_BREAKPOINT)
	_map_overlay_legend.modulate.a = 0.0 if compact_detail else 1.0
	_map_overlay_legend.mouse_filter = Control.MOUSE_FILTER_IGNORE \
		if compact_detail else Control.MOUSE_FILTER_PASS
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
	_country_action_bar.visible = true
	var viewport_width := get_viewport().get_visible_rect().size.x
	var safe := map_safe_area()
	var bar_width := 400.0
	var side_margin := maxf(safe.position.x + (safe.size.x - bar_width) * 0.5,
		UITokens.SPACE_SM)
	var right_margin := maxf(viewport_width - side_margin - bar_width,
		UITokens.SPACE_SM)
	_country_action_bar.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	_country_action_bar.offset_left = side_margin
	_country_action_bar.offset_right = -right_margin
	_country_action_bar.offset_top = -CountryActionBar.BAR_HEIGHT - UITokens.SPACE_SM
	_country_action_bar.offset_bottom = -UITokens.SPACE_SM
	var window_width := get_window().size.x if get_window() != null else int(viewport_width)
	_country_action_bar.set_compact(window_width < 720)


func _layout_gm_panel() -> void:
	if _gm_console == null:
		return
	var viewport_width := get_viewport().get_visible_rect().size.x
	var compact_detail := _right_panel != null and _right_panel.detail_open() \
		and viewport_width < (FAMILY_WORKSPACE_BREAKPOINT \
			if _right_panel.family_workspace_open() else DETAIL_LAYOUT_BREAKPOINT)
	_gm_console.modulate.a = 0.0 if compact_detail else 1.0
	_gm_console.mouse_filter = Control.MOUSE_FILTER_IGNORE \
		if compact_detail else Control.MOUSE_FILTER_PASS
	if compact_detail:
		return
	var panel_width_right := RIGHT_PANEL_WIDTH
	if _right_panel != null and _right_panel.visible:
		panel_width_right = _right_panel.size.x if _right_panel.size.x > 0.0 \
			else RIGHT_PANEL_WIDTH
	var available := viewport_width - panel_width_right - UITokens.SPACE_MD * 3.0
	var panel_width := clampf(available, GM_PANEL_MIN_WIDTH, GM_PANEL_TARGET_WIDTH)
	_gm_console.offset_left = UITokens.SPACE_SM
	_gm_console.offset_right = UITokens.SPACE_SM + panel_width
	_gm_console.offset_top = PlayerTopBar.BAR_HEIGHT + UITokens.SPACE_SM
	_gm_console.offset_bottom = -UITokens.SPACE_SM


# [web-layout-guard] PlayerTopBar / RightPanel 之前完全依赖 .tscn 里静态烘焙的
# anchor+offset（从未在运行时被脚本重新应用过）。CountryActionBar/OverlayLegend/
# GMPanel 三者虽然各自出于自己的动态需求（跟随姊妹面板可见性、紧凑模式阈值等）
# 早就在跑"取实时 viewport 尺寸 → set_anchors_preset → 写 offset"这条路径，
# 但客观上也顺带验证了这条路径在当前运行环境下是可靠的。这里让顶栏/详情面板走
# 同一条已验证路径兜底，不再单纯依赖引擎在 Web 上是否可靠地对声明式 anchor
# 做持续重新解算——即使原声明式 anchor 一直正常，这里重新套用同样的数值也是
# 幂等的，不会有副作用。
func _layout_top_bar() -> void:
	if _top_bar == null:
		return
	_top_bar.set_anchors_preset(Control.PRESET_TOP_WIDE)
	_top_bar.offset_left = 0.0
	_top_bar.offset_top = 0.0
	_top_bar.offset_right = 0.0
	_top_bar.offset_bottom = PlayerTopBar.BAR_HEIGHT
	UIAnimation.refresh_rest_position(_top_bar)


func _layout_right_panel() -> void:
	if _right_panel == null:
		return
	# PRESET_RIGHT_WIDE：anchor_left=anchor_right=1.0（贴右边）且 anchor_bottom=1.0
	# （随视口高度伸展），必须用这个而不是 PRESET_TOP_RIGHT，否则 offset_bottom
	# 会被解释成"相对顶部锚点"而不是"相对底部锚点"，面板会被压扁到顶部一小条。
	var viewport_width := get_viewport().get_visible_rect().size.x
	var detail_open := _right_panel.detail_open()
	var family_open := _right_panel.family_workspace_open()
	var layout := inspector_layout_for_width(viewport_width, detail_open, family_open)
	var compact := bool(layout.get("compact", false))
	_right_panel.set_compact_detail_mode(compact)
	var panel_width := float(layout.get("panel_width", RIGHT_PANEL_WIDTH))
	_right_panel.set_anchors_preset(Control.PRESET_RIGHT_WIDE)
	_right_panel.offset_left = -panel_width
	_right_panel.offset_top = 68.0  # 与 inspector_panel.tscn 原始烘焙值保持一致
	_right_panel.offset_right = 0.0
	_right_panel.offset_bottom = -12.0  # 与 inspector_panel.tscn 原始烘焙值保持一致
	_right_panel.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	_right_panel.grow_vertical = Control.GROW_DIRECTION_END
	_right_panel.custom_minimum_size.x = panel_width if detail_open else RIGHT_PANEL_WIDTH
	# 关键一步：UIAnimation.fade_slide_in/out 会把"第一次调用时的 control.position"
	# 永久缓存成 rest position。如果不在这里主动刷新，等玩家第一次点开地块面板时，
	# fade_slide_in 可能会缓存到一个还没被上面这套 offset 结算过的旧/零值，
	# 之后每次开合面板都会被带回那个错误坐标——这正是"详情框缩在左上角"的成因。
	UIAnimation.refresh_rest_position(_right_panel)


static func inspector_layout_for_width(viewport_width: float,
		detail_open: bool, family_open: bool = false) -> Dictionary:
	if detail_open and family_open:
		var family_compact := viewport_width < FAMILY_WORKSPACE_BREAKPOINT
		var family_width := viewport_width if family_compact else viewport_width * 0.5
		return {
			"compact": family_compact,
			"panel_width": family_width,
			"detail_width": family_width,
			"map_width": 0.0 if family_compact else viewport_width - family_width,
		}
	var compact := viewport_width < DETAIL_LAYOUT_BREAKPOINT
	var panel_width := RIGHT_PANEL_WIDTH
	if detail_open:
		if compact:
			panel_width = viewport_width
		else:
			panel_width = minf(DETAIL_PANEL_MAX_WIDTH,
				maxf(DETAIL_PANEL_MIN_WIDTH, viewport_width * 0.62))
			panel_width = minf(panel_width,
				maxf(RIGHT_PANEL_WIDTH,
					viewport_width - MAP_REMAINING_MIN_WIDTH))
	return {
		"compact": compact,
		"panel_width": panel_width,
		"detail_width": maxf(panel_width - RIGHT_PANEL_WIDTH, 0.0) \
			if detail_open and not compact else panel_width if detail_open else 0.0,
		"map_width": 0.0 if compact and detail_open \
			else maxf(viewport_width - panel_width, 0.0),
	}


# 排查 Web 构建"详情框/状态栏跑到左上角"问题用的一次性诊断输出；不影响任何
# 表现，纯打日志，方便下次直接从控制台里比对具体数值而不用再靠截图猜。
#
# 目前最大嫌疑：Windows 高 DPI 缩放下 Godot Web 默认 hidpi=true，canvas 像素
# 缓冲区尺寸会按 window.devicePixelRatio 放大，但引擎内部给 UI 锚点用的视口
# 逻辑尺寸未必跟着同步（godotengine/godot#93106 这一类已知问题）——地图相机
# 视图本身按视口自适应，看不出异常，锚定 UI 却会被挤压到左上角一小块。
# export_presets.cfg 的 html/head_include 已经在引擎脚本跑之前把
# window.devicePixelRatio 钉死成 1 来regress 这个根因；这里额外把浏览器端实测到
# 的 devicePixelRatio 打出来，用来确认那个钉子是否真的生效（预期看到 1.000）。
func _log_ui_layout_diagnostics(tag: String) -> void:
	var vp_rect := get_viewport().get_visible_rect()
	var win := get_window()
	var win_size := win.size if win != null else Vector2i.ZERO
	var scale_factor := win.content_scale_factor if win != null else -1.0
	var scale_mode := win.content_scale_mode if win != null else -1
	var top_bar_rect := _top_bar.get_rect() if _top_bar != null else Rect2()
	var right_panel_rect := _right_panel.get_rect() if _right_panel != null else Rect2()
	var country_bar_rect := _country_action_bar.get_rect() if _country_action_bar != null else Rect2()
	var device_pixel_ratio := -1.0
	if OS.has_feature("web") and Engine.has_singleton("JavaScriptBridge"):
		var js_result = JavaScriptBridge.eval("window.devicePixelRatio", true)
		if js_result != null:
			device_pixel_ratio = float(js_result)
	print(("[ui-layout-diag/%s] is_web=%s viewport_visible_rect=%s window_size=%s " +
		"content_scale_factor=%.3f content_scale_mode=%d device_pixel_ratio=%.3f " +
		"top_bar_rect=%s right_panel_rect=%s country_action_bar_rect=%s") % [
		tag, OS.has_feature("web"), vp_rect, win_size, scale_factor, scale_mode,
		device_pixel_ratio, top_bar_rect, right_panel_rect, country_bar_rect,
	])


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
