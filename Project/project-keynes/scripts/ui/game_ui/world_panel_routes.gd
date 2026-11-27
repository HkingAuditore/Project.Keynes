extends CanvasLayer

## Owns HUD view references and routes published map, country, and inspector updates.

const PublicationViews := preload("res://scripts/game/world_runtime_presentation.gd")
const MilitaryActions = preload("res://scripts/ui/game_ui/military_actions.gd")
const TouchMetrics = preload("res://scripts/ui/game_ui/touch_metrics.gd")
const GameHudLayout = preload("res://scripts/ui/game_hud_layout.gd")
const GameUICountryRoutesScript = preload("res://scripts/ui/game_ui/country_routes.gd")
const GameUIEraProgressionScript = preload("res://scripts/ui/game_ui/era_progression.gd")
const GameUIOverlaysScript = preload("res://scripts/ui/game_ui/overlays.gd")
const MobilizationCategoryModelScript = preload("res://scripts/ui/mobilization_category_model.gd")

var _country_component = GameUICountryRoutesScript.new()
var _era_component = GameUIEraProgressionScript.new()
var _overlay_component = GameUIOverlaysScript.new()
var _hud_layout_component = GameHudLayout.new()

signal pause_toggled(paused: bool)
signal speed_selected(speed: float)
signal day_night_toggled(enabled: bool)
signal fit_requested()
signal setup_requested()
signal regenerate_requested()
signal clear_selection_requested()
signal population_discontent_changed(cell_index: int, discontent: Dictionary)
signal map_overlay_requested(request: Dictionary)
signal map_overlay_cleared()
signal pause_menu_visibility_changed(open: bool)
signal return_main_menu_requested()
signal exit_game_requested()
signal era_reward_choice_requested(offer_generation: int, choice_index: int)
signal era_reward_open_requested()
signal era_reward_dismiss_requested()
signal family_founding_choice_requested(offer_id: int, generation: int, choice_index: int)
signal annual_history_requested()
signal annual_report_closed(report_id: int)
signal annual_report_selected(report_id: int)
signal annual_history_page_requested(offset: int)
signal annual_report_workspace_available()
signal narrative_event_option_selected(offer_id: int, offer_generation: int, option_index: int)
signal narrative_event_outcome_acknowledged()
signal narrative_chronicle_requested()

const AnnualReportWorkspaceScene = preload("res://scenes/ui/annual_report_workspace.tscn")
const NarrativeEventDialogScript = preload("res://scripts/ui/components/narrative_event_dialog.gd")
const NarrativeChroniclePanelScript = preload("res://scripts/ui/components/narrative_chronicle_panel.gd")
const TouchUI = GameHudLayout.TouchUI

var _annual_report_workspace: Control
var _narrative_event_dialog: Control
var _narrative_chronicle_panel: Control

const RIGHT_PANEL_WIDTH = GameHudLayout.RIGHT_PANEL_WIDTH
const DETAIL_LAYOUT_BREAKPOINT = GameHudLayout.DETAIL_LAYOUT_BREAKPOINT
const FAMILY_DETAIL_MIN_WIDTH = GameHudLayout.FAMILY_DETAIL_MIN_WIDTH
const FAMILY_DETAIL_MAX_WIDTH = GameHudLayout.FAMILY_DETAIL_MAX_WIDTH
const DETAIL_PANEL_MIN_WIDTH = GameHudLayout.DETAIL_PANEL_MIN_WIDTH
const DETAIL_PANEL_MAX_WIDTH = GameHudLayout.DETAIL_PANEL_MAX_WIDTH
const MAP_REMAINING_MIN_WIDTH = GameHudLayout.MAP_REMAINING_MIN_WIDTH
const OVERLAY_LEGEND_WIDTH = GameHudLayout.OVERLAY_LEGEND_WIDTH

# 左侧地图图层工具条与顶栏之间的垂直间距（= .tscn 里 92 - 80 的净空）。
const OVERLAY_TOOLBAR_TOP_GAP = GameHudLayout.OVERLAY_TOOLBAR_TOP_GAP
const GM_PANEL_TARGET_WIDTH = GameHudLayout.GM_PANEL_TARGET_WIDTH
const GM_PANEL_MIN_WIDTH = GameHudLayout.GM_PANEL_MIN_WIDTH
const INSPECTOR_FULL_PATCH_INTERVAL_MSEC := 750

## 军务档案（右栏部队/战线页）的每日刷新窗口。它只改值、不建节点，
## 所以可以比地块档案更密；仍然合并，避免 50× 时每个已提交日都重建一次模型。
const MILITARY_DOSSIER_REFRESH_INTERVAL_MSEC := 200

## 营造窗口打开时的报价刷新节流：报价只读已提交日快照，1 秒足够跟上国库与市场。
const BUILDING_WORKSPACE_REFRESH_MSEC := 1000

# Country economy/treasury snapshots include the native trade summary and can
# be materially more expensive than applying the already-built panel model.
# Economy commits may arrive several times per rendered frame at high speed;
# coalesce those notifications and refresh the open panel at a bounded cadence.
# Technology section uses a tighter window so research/queue/owned stay close to
# the worker replica at 50x. Native state is still committed every sim day.
const COUNTRY_UI_REFRESH_INTERVAL_MSEC := 250
const COUNTRY_UI_TECH_REFRESH_INTERVAL_MSEC := 50

# Soft country commits arrive every simulated day; research toast only needs
# wall-clock sampling so 50x does not snapshot the tech plane each day.
const RESEARCH_TOAST_POLL_INTERVAL_MSEC := 100

# Open technology archive progress bars; keep this slower than a double-click.
const RESEARCH_PANEL_PROGRESS_INTERVAL_MSEC := 750
const TECH_ECONOMY_REFRESH_INTERVAL_MSEC := 500

## 顶栏纸签悬浮卡：延迟出卡/收卡，以及悬停期间的读数节流。
const STATUS_CARD_SHOW_DELAY := 0.14
const STATUS_CARD_HIDE_DELAY := 0.12
const STATUS_CARD_REFRESH_MSEC := 1000

var _next_tech_economy_refresh_ms := 0
var _top_bar: PlayerTopBar
var _right_panel: InspectorPanel
var _loading_overlay: WorldLoadingOverlay
var _colonization_panel: ColonizationPlannerPanel
var _colonization_route: ColonizationRouteLayer
var _colonization_targeting: Dictionary = {}

## Peace-negotiation window (MilitaryPeaceWindow). Same map-first contract as the
## colonization planner, but it owns cession picking instead of a route target.
var _peace_window = null
var _dispatch_previous_inspector_visible := false
var _dispatch_previous_toolbar_visible := false
var _dispatch_ui_suppressed := false
var _object_detail_context: Dictionary = {}
var _military_dossier_context: Dictionary = {}
var _last_military_dossier_ms: int = 0
var _military_dossier_pending := false
var _military_dossier_timer_active := false
var _last_construction_refresh_ms: int = 0
var _pending_inspector_tab := ""
var _pending_object_request: Dictionary = {}
var _inspector_retry_generation := 0
var _inspector_retry_queued := false
var _inspector_view_model: CellInspectorViewModel
var _map: MapData
var _world_clock: WorldClock

## 年度累计产值账本：国家卷宗与地块档案共用同一份，随已提交经济日推进。
var _gdp_ledger := EconomyGdpLedger.new()
var _selected_cell: HexCell
var _cell_panel := preload("res://scripts/ui/game_ui/selected_cell.gd").new()
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
var _gm_sun_camera: MapCamera
var _gm_sun_handle: Button
var _gm_sun_dragging := false
var _perf_hud: PerfMiniHUD
var _diagnostics_source: Node = null
var _map_overlay_toolbar: MapOverlayToolbar
var _military_map_toolbar: MilitaryMapToolbar
var _map_overlay_legend: OverlayLegend
var _pause_menu
var _era_reward_dialog: EraRewardDialog
var _status_card: HudStatusCard
var _status_card_kind := ""
var _status_card_generation := 0
var _status_card_next_refresh_ms := 0
var _era_indicator: EraIndicator
var _era_indicator_view_model: EraIndicatorViewModel
var _era_offer: Dictionary = {}
var _era_refresh_queued := false
var _era_flight: Control
var _era_transfer_name := ""

## 时代晋升面板（纸徽点击打开）与晋升大典。纸徽本身只是 HUD：它和日期栏同级、挂在 HUDLayer 末位，
## 任何面板/卷宗/模态窗都能压住它。纸笺与晋升光带挂 EraOverlayLayer（面板层之上、模态层之下），
## 大典挂 ModalLayer 且排在暂停菜单之前：压住卷宗/奖励弹窗，但暂停菜单仍在最上。
var _era_panel: EraAdvancementPanel
var _era_ceremony: EraAscensionCeremony
var _era_ceremony_parent: Control
var _era_ceremony_index := -1
var _era_ceremony_landed_name := ""
var _era_celebrated_index := -1
var _era_advancement_snapshot: Dictionary = {}
var _family_founding_dialog: FamilyFoundingDialog
var _gm_available := false
var _era_ceremony_suppressed := false
var _gm_all_ui_suppressed := false
var _gm_saved_ui_visibility: Dictionary = {}
var _debug_layer: Control
var _inspector_suppressed_for_country := false
var _country_runtime_facade = null
var _economy_runtime_facade = null
var _ideology_runtime_facade = null
var _country_refresh_queued := false
var publication_views: PublicationViews
var _country_refresh_timer_active := false
var _country_next_refresh_ms := 0
var _country_open_generation := 0
var _country_dirty_domains := 0
var _country_refresh_reason := ""
var _country_ui_event_refresh_enabled := true
var _country_ui_perf_pending: Dictionary = {}

const COUNTRY_DIRTY_TECHNOLOGY := 1
const COUNTRY_DIRTY_ECONOMY := 2
const COUNTRY_DIRTY_POLITICS := 4
const COUNTRY_DIRTY_IDEOLOGY := COUNTRY_DIRTY_POLITICS

## 军事：自己的 facade，不参与国家 ui_snapshot 分段，但仍然共用同一个脏位管道。
const COUNTRY_DIRTY_MILITARY := 8

## 外交：读的是领土镜像 + 军事快照 + 视野，没有自己的原生分片，同样只借脏位管道。
const COUNTRY_DIRTY_DIPLOMACY := 16
const COUNTRY_DIRTY_ALL := COUNTRY_DIRTY_TECHNOLOGY | COUNTRY_DIRTY_ECONOMY \
	| COUNTRY_DIRTY_POLITICS | COUNTRY_DIRTY_MILITARY | COUNTRY_DIRTY_DIPLOMACY

# Native RUNTIME_DIRTY_COUNTRY_* bits from runtime_pod_protocol.h.
const NATIVE_DIRTY_COUNTRY_STATE := 1 << 1
const NATIVE_DIRTY_COUNTRY_TERRITORY := 1 << 2
const NATIVE_DIRTY_COUNTRY_VISUAL_ERA := 1 << 3
const ResearchToastScene = preload("res://scenes/ui/research_toast.tscn")
const EraAdvancementPanelScene = preload("res://scenes/ui/era_advancement_panel.tscn")
const CellHoverCardScene = preload("res://scenes/ui/cell_hover_card.tscn")
const TechnologyCatalogScript = preload("res://scripts/economy/technology_catalog.gd")

## 军事官营建筑入口要发正式命令，命令 id 只从 PlayerController 取，不在这里抄字符串。
const PlayerControllerScript = preload("res://scripts/game/player_controller.gd")

var _research_toast: ResearchToast
var _cell_hover_card: CellHoverCard
var _cell_hover_view_model: CellHoverViewModel
var _player_camera: MapCamera
var _hover_hex_size: float = 22.0
var _last_research_toast_states := PackedInt32Array()
var _research_toast_bootstrapped := false
var _next_research_toast_poll_ms := 0
var _next_tech_panel_progress_ms := 0
var _last_discovery_tech_ids := PackedStringArray()
var _discovery_tech_ids_ready := false


func set_world_context(
		map: MapData,
		generator: MapGenerator,
		view_adapter: DCViewAdapter,
		world_clock: WorldClock,
		sea_level: float,
		hex_size: float
) -> void:
	_country_component.set_world_context(self, map, generator, view_adapter, world_clock, sea_level, hex_size)


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
	_country_refresh_timer_active = false
	_country_next_refresh_ms = 0


func _on_country_research_signal_discovered(_event: Dictionary) -> void:
	_country_component.apply_country_research_signal(self, _event)


func _on_economy_event_batch_available(_meta: Dictionary) -> void:
	_country_component.apply_economy_event_batch(self, _meta)


func notify_committed_day() -> void:
	_country_component.notify_committed_day(self)


func _on_ideology_runtime_settled(_result: Dictionary) -> void:
	_country_component.apply_ideology_settled(self, _result)


func _on_military_command_settled(_id: StringName, _result: Dictionary) -> void:
	MilitaryActions.apply_military_command_settled(self, _id, _result)


func show_transient_message(text: String) -> void:
	_country_component.show_transient_message(self, text)


func _on_military_state_building_requested(request: Dictionary) -> void:
	MilitaryActions._on_military_state_building_requested(self, request)


## 地块军事台账把该格本国驻军整编为一支部队；兵种模板直接取自驻军 lots。
func _on_military_army_create_requested(request: Dictionary) -> void:
	MilitaryActions._on_military_army_create_requested(self, request)


func _country_section_mask(section_id: String) -> int:
	return _country_component._country_section_mask(self, section_id)


func _mark_country_panel_dirty(domains: int, reason: String) -> void:
	_country_dirty_domains |= domains
	_country_refresh_reason = reason
	if _country_view_model != null:
		_country_view_model.invalidate_cache(domains)
	if _country_panel == null or not _country_panel.is_panel_open() \
			or _country_refresh_queued:
		return
	_country_refresh_queued = true
	if _country_ui_event_refresh_enabled:
		call_deferred("_flush_country_panel_refresh")
	else:
		_flush_country_panel_refresh()


func _flush_country_panel_refresh() -> void:
	if _country_panel == null or not _country_panel.is_panel_open():
		_country_refresh_queued = false
		_country_refresh_timer_active = false
		return
	var section_mask := _country_section_mask(_country_panel.current_section())
	if publication_views != null and publication_views.defer_ui_refresh(_flush_country_panel_refresh):
		_country_refresh_queued = false
		return
	if not _country_ui_event_refresh_enabled:
		_country_refresh_queued = false
		refresh_country_summary()
		_country_dirty_domains &= ~section_mask
		return
	if (_country_dirty_domains & section_mask) == 0:
		_country_refresh_queued = false
		_country_refresh_timer_active = false
		return
	# High-speed economy commits can arrive more often than a player can read
	# the panel. Keep the first refresh immediate, then coalesce later commits
	# behind a short wall-clock window. Leave the queued bit armed while waiting
	# so additional events do not create one timer per commit.
	var now_ms := Time.get_ticks_msec()
	var wait_ms := _country_next_refresh_ms - now_ms
	if wait_ms > 0:
		if not _country_refresh_timer_active:
			_country_refresh_timer_active = true
			get_tree().create_timer(float(wait_ms) / 1000.0).timeout.connect(
				_on_country_refresh_timer, CONNECT_ONE_SHOT)
		return
	_country_refresh_queued = false
	_country_refresh_timer_active = false
	refresh_country_summary()
	_country_dirty_domains &= ~section_mask
	_country_refresh_reason = ""
	var interval := COUNTRY_UI_TECH_REFRESH_INTERVAL_MSEC \
		if section_mask == COUNTRY_DIRTY_TECHNOLOGY \
		else COUNTRY_UI_REFRESH_INTERVAL_MSEC
	_country_next_refresh_ms = now_ms + interval


# SceneTreeTimer advances on frame delta, which can land a millisecond before
# the wall-clock deadline. Disarm first so the flush can re-arm instead of
# leaving the queued bit set with no timer behind it.
func _on_country_refresh_timer() -> void:
	_country_refresh_timer_active = false
	_flush_country_panel_refresh()


func _sync_military_map_toolbar() -> void:
	_country_component._sync_military_map_toolbar(self)


func show_cell_panel(cell: HexCell) -> void:
	_cell_panel.show_cell_panel(self, cell)


func hide_cell_panel() -> void:
	_cell_panel.hide_cell_panel(self)


## Web：把检查器日刷的耗时打进事件流（只在 >200ms 时），用来定位"整帧不返回"。
func _report_inspector_daily_timing(timing: Dictionary, started_usec: int) -> void:
	_country_component._report_inspector_daily_timing(self, timing, started_usec)


func refresh_selected_daily_lines(force: bool = false, day_idx: int = -1) -> Dictionary:
	return _cell_panel.refresh_selected_daily_lines(self, force, day_idx)


func refresh_selected_panel() -> void:
	if VisionSolver.displayed_fields_current(_map):
		_country_component.refresh_selected_panel(self)


func _revision_selection_context(revision: Dictionary) -> String:
	return _country_component._revision_selection_context(self, revision)


func _on_country_committed(report: Dictionary) -> void:
	_country_component.apply_country_commit(self, report)


func open_military_dossier(kind: String, id: int, cell: int = -1) -> bool:
	return _country_component.open_military_dossier(self, kind, id, cell)


func close_military_dossier() -> void:
	_country_component.close_military_dossier(self)


func military_dossier_open() -> bool:
	return _country_component.military_dossier_open(self)


func _military_dossier_payload(kind: String, id: int, cell: int = -1) -> Dictionary:
	return _country_component._military_dossier_payload(self, kind, id, cell)


func _military_view_model() -> MilitaryViewModel:
	return _country_component._military_view_model(self)


func _refresh_military_dossier(force: bool = false) -> void:
	_country_component._refresh_military_dossier(self, force)


func _arm_military_dossier_timer() -> void:
	if _military_dossier_timer_active:
		return
	_military_dossier_timer_active = true
	get_tree().create_timer(
		float(MILITARY_DOSSIER_REFRESH_INTERVAL_MSEC) / 1000.0).timeout.connect(
			_on_military_dossier_timer, CONNECT_ONE_SHOT)


func _on_military_dossier_timer() -> void:
	_military_dossier_timer_active = false
	if _military_dossier_pending:
		_refresh_military_dossier(true)


func _on_military_dossier_action_requested(action: StringName, payload: Dictionary) -> void:
	MilitaryActions._on_military_dossier_action_requested(self, action, payload)


func update_military_arm_order(state: Dictionary) -> void:
	if _right_panel != null:
		_right_panel.update_military_arm_order(state)


func _on_military_dossier_army_selected(handle: int) -> void:
	if handle <= 0:
		return
	open_military_dossier("army", handle)


## 地块军事页里点了一支部队：用它所在格（就是当前选中的格）打开军务档案，
## 于是「同格部队」名录能把这一格的其它部队也列出来。
func _on_military_army_selected(handle: int) -> void:
	if handle <= 0:
		return
	open_military_dossier("army", handle,
		int(_selected_cell.index) if _selected_cell != null else -1)


func _set_inspector_trace_cell(cell_idx: int) -> void:
	_country_component._set_inspector_trace_cell(self, cell_idx)


func set_resource_discovery_context(
	technology_ids: PackedStringArray,
	enforce_discovery: bool = false
) -> void:
	_country_component.set_resource_discovery_context(self, technology_ids, enforce_discovery)


func _refresh_player_discovery_context() -> void:
	_country_component._refresh_player_discovery_context(self)


## 悬停卡的抑制策略集中在这里：任何"地图不该被打扰"的状态都返回 true。
func _hover_blocked() -> bool:
	return _country_component._hover_blocked(self)


func _locate_cell_from_family_founding(cell_index: int) -> void:
	_country_component._locate_cell_from_family_founding(self, cell_index)


func _on_founding_collapsed_changed(collapsed: bool) -> void:
	_country_component._on_founding_collapsed_changed(self, collapsed)


func _cancel_colonization_targeting() -> void:
	_country_component._cancel_colonization_targeting(self)


func _on_colonization_planning_context(context: Dictionary) -> void:
	_country_component._on_colonization_planning_context(self, context)


func _ensure_research_toast() -> void:
	_country_component._ensure_research_toast(self)


func _poll_research_completion_toasts() -> Dictionary:
	return _country_component._poll_research_completion_toasts(self)


func open_country_section(section_id: String, economy_chapter: String = "") -> void:
	_country_component.open_country_section(self, section_id, economy_chapter)


func _load_country_section_deferred(section_id: String, generation: int) -> void:
	_country_component._load_country_section_deferred(self, section_id, generation)


func _locate_cell_from_country_panel(cell_index: int) -> void:
	_country_component._locate_cell_from_country_panel(self, cell_index)


func _on_target_cells_from_country_panel(cells: PackedInt32Array) -> void:
	_country_component._on_target_cells_from_country_panel(self, cells)


func _on_trade_orders_page_requested(offset: int) -> void:
	_country_component._on_trade_orders_page_requested(self, offset)


func _on_trade_order_locate_requested(cell_index: int) -> void:
	_country_component._on_trade_order_locate_requested(self, cell_index)


func close_country_panel() -> void:
	_country_component.close_country_panel(self)


func _hide_inspector_for_country() -> void:
	_country_component._hide_inspector_for_country(self)


func _restore_inspector_after_country() -> void:
	_country_component._restore_inspector_after_country(self)


func refresh_country_summary() -> Dictionary:
	return _country_component.refresh_country_summary(self)


func _record_country_ui_perf(reason: String, cache_hit: bool,
		snapshot_ms: float, dirty_domains: int) -> void:
	_country_component._record_country_ui_perf(self, reason, cache_hit, snapshot_ms, dirty_domains)


func consume_country_ui_perf_summary() -> Dictionary:
	return _country_component.consume_country_ui_perf_summary(self)


func _on_inspector_tab_data_requested(tab_id: String) -> void:
	if not VisionSolver.displayed_fields_current(_map):
		_pending_inspector_tab = tab_id
		_pending_object_request.clear()
		return
	_country_component._on_inspector_tab_data_requested(self, tab_id)


func _cancel_inspector_retry() -> void:
	_country_component._cancel_inspector_retry(self)


func _schedule_inspector_retry() -> void:
	if _inspector_retry_queued or not is_inside_tree():
		return
	_inspector_retry_queued = true
	get_tree().create_timer(0.15).timeout.connect(
		_retry_inspector_reads.bind(_inspector_retry_generation), CONNECT_ONE_SHOT)


func _retry_inspector_reads(generation: int) -> void:
	if generation == _inspector_retry_generation and not VisionSolver.displayed_fields_current(_map):
		_inspector_retry_queued = false
		return
	_country_component._retry_inspector_reads(self, generation)


func _on_construction_page_requested(sector: String, search: String,
		sort_id: String, offset: int) -> void:
	_country_component._on_construction_page_requested(self, sector, search, sort_id, offset)


func _refresh_building_workspace(force: bool = false) -> void:
	_country_component._refresh_building_workspace(self, force)


func _on_construction_requested(request: Dictionary) -> void:
	_country_component._on_construction_requested(self, request)


func _on_construction_fold_action_requested(action: Dictionary) -> void:
	_country_component._on_construction_fold_action_requested(self, action)


func _open_colonization_target(target_cell: int, family_handle: int = 0,
		source_cell: int = -1) -> void:
	_country_component._open_colonization_target(self, target_cell, family_handle, source_cell)


func _open_dispatch_progress() -> void:
	_country_component._open_dispatch_progress(self)


func _refresh_dispatch_status() -> void:
	_country_component._refresh_dispatch_status(self)


func _on_colonization_requested(request: Dictionary) -> void:
	_country_component._on_colonization_requested(self, request)


func _on_family_colonization_requested(family_handle: int,
		source_cell: int) -> void:
	_country_component._on_family_colonization_requested(self, family_handle, source_cell)


func _suppress_ui_for_dispatch() -> void:
	_country_component._suppress_ui_for_dispatch(self)


func _on_dispatch_closed() -> void:
	_country_component._on_dispatch_closed(self)


func open_military_peace(war_id: int) -> void:
	_country_component.open_military_peace(self, war_id)


func close_military_peace() -> void:
	_country_component.close_military_peace(self)


func is_peace_window_open() -> bool:
	return _country_component.is_peace_window_open(self)


func handle_peace_map_cell(cell: int) -> bool:
	return _country_component.handle_peace_map_cell(self, cell)


func _peace_focus_cell() -> int:
	return _country_component._peace_focus_cell(self)


func _on_peace_window_closed() -> void:
	_country_component._on_peace_window_closed(self)


func _on_peace_submit_requested(payload: Dictionary) -> void:
	_country_component._on_peace_submit_requested(self, payload)


func _on_peace_locate_requested(cell: int) -> void:
	_country_component._on_peace_locate_requested(self, cell)


func _refresh_peace_window() -> void:
	_country_component._refresh_peace_window(self)


func _on_colonization_start_requested(args: Dictionary) -> void:
	_country_component._on_colonization_start_requested(self, args)


func _on_colonization_cancel_requested(expedition_handle: int) -> void:
	_country_component._on_colonization_cancel_requested(self, expedition_handle)


func _on_expedition_selected(expedition_handle: int) -> void:
	_country_component._on_expedition_selected(self, expedition_handle)


func _play_progression_cue(cue: StringName) -> void:
	_country_component._play_progression_cue(self, cue)


func _on_player_command_completed_audio(id: StringName, result: Dictionary) -> void:
	_country_component._on_player_command_completed_audio(self, id, result)


func _on_player_command_settled(id: StringName, result: Dictionary) -> void:
	_country_component._on_player_command_settled(self, id, result)


func _invalidate_live_revision() -> void:
	_country_component._invalidate_live_revision(self)


func _on_object_details_requested(request: Dictionary) -> void:
	if not VisionSolver.displayed_fields_current(_map):
		_pending_object_request = request.duplicate(true)
		return
	_country_component._on_object_details_requested(self, request)


func _close_object_detail_dialog() -> void:
	_country_component._close_object_detail_dialog(self)


func _refresh_object_detail(force: bool = false) -> void:
	if VisionSolver.displayed_fields_current(_map):
		_country_component._refresh_object_detail(self, force)
