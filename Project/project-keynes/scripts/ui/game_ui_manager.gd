extends CanvasLayer
class_name GameUIManager

const GameHudLayout = preload("res://scripts/ui/game_hud_layout.gd")
const GameUICountryRoutesScript = preload("res://scripts/ui/game_ui/country_routes.gd")
const GameUIEraProgressionScript = preload("res://scripts/ui/game_ui/era_progression.gd")
const GameUIOverlaysScript = preload("res://scripts/ui/game_ui/overlays.gd")
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
var _era_ceremony_resume_clock := false
var _era_advancement_snapshot: Dictionary = {}
var _family_founding_dialog: FamilyFoundingDialog
var _gm_available := false
var _gm_popups_suppressed := false
var _gm_all_ui_suppressed := false
var _gm_saved_ui_visibility: Dictionary = {}
var _debug_layer: Control
var _inspector_suppressed_for_country := false
var _country_runtime_facade = null
var _economy_runtime_facade = null
var _ideology_runtime_facade = null
var _country_refresh_queued := false
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
const EraAscensionCeremonyScene = preload("res://scenes/ui/era_ascension_ceremony.tscn")
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


func _ready() -> void:
	layer = 20
	# [qa-ui-hide 2026-11-02] 二分"渲染线程崩溃是否由 UI 绘制引起"：
	# PK_UI_HIDE_ALL=1（桌面）或 pk_debug.cfg 的 `[ui] hide_all=true`（安卓）时
	# 整层 UI 隐藏（世界照常渲染）。正式包不设这些开关。
	var hide_all := OS.get_environment("PK_UI_HIDE_ALL") == "1"
	if not hide_all:
		var qa_cfg := ConfigFile.new()
		if qa_cfg.load("user://pk_debug.cfg") == OK:
			hide_all = bool(qa_cfg.get_value("ui", "hide_all", false))
	if hide_all:
		visible = false
		print("[ui] QA: HUD hidden")
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
	_country_component.apply_military_command_settled(self, _id, _result)


func show_transient_message(text: String) -> void:
	_country_component.show_transient_message(self, text)


func _on_military_state_building_requested(request: Dictionary) -> void:
	if _player_controller == null:
		return
	var op := String(request.get("op", "state.build"))
	var command_id: StringName = PlayerControllerScript.COMMAND_MILITARY_STATE_BUILD \
		if op == "state.build" else PlayerControllerScript.COMMAND_MILITARY_STATE_DEMOLISH
	var result: Dictionary = _player_controller.request_command(command_id, {
		"cell": int(request.get("cell", -1)),
		"building": int(request.get("building", -1)),
	})
	var ok := bool(result.get("ok", false))
	var message := String(result.get("message", ""))
	# 被拒时立刻解锁动作键，不然要等到下一次日推进才恢复——玩家会以为按钮坏了。
	if not ok and _right_panel != null \
			and _right_panel.has_method("release_military_ledger_busy"):
		_right_panel.release_military_ledger_busy()
	# 回执先写在地块档案那一行上（成功=已排队，失败=被拒的理由）；营造反馈条
	# 只在营造窗口打开时可见，不能当作这一页的回音。
	if _right_panel != null and _right_panel.has_method("set_military_ledger_feedback"):
		_right_panel.set_military_ledger_feedback(message, ok)
	if _right_panel != null and _right_panel.has_method("set_construction_feedback"):
		_right_panel.set_construction_feedback(message, ok)


## 地块军事台账把该格本国驻军整编为一支部队；兵种模板直接取自驻军 lots。
func _on_military_army_create_requested(request: Dictionary) -> void:
	if _player_controller == null:
		if _right_panel != null:
			_right_panel.set_military_army_feedback("玩家控制器尚未就绪。", false)
			_right_panel.release_military_ledger_busy()
		return
	var result: Dictionary = _player_controller.request_command(
		PlayerControllerScript.COMMAND_MILITARY_ARMY_CREATE, {
			"cell": int(request.get("cell", -1)),
			"units": request.get("units", {}),
		})
	var ok := bool(result.get("ok", false))
	var message := String(result.get("message", ""))
	if message.is_empty():
		message = "编成命令已排队，将在下一游戏日生效。" if ok else "部队编成未能排队。"
	if not ok and _right_panel != null \
			and _right_panel.has_method("release_military_ledger_busy"):
		_right_panel.release_military_ledger_busy()
	if _right_panel != null and _right_panel.has_method("set_military_army_feedback"):
		_right_panel.set_military_army_feedback(message, ok)
	if ok:
		_mark_country_panel_dirty(COUNTRY_DIRTY_MILITARY, "army_create")


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
	if not _country_ui_event_refresh_enabled:
		refresh_country_summary()
		_country_dirty_domains &= ~_country_section_mask(
			_country_panel.current_section())
		return
	_country_refresh_queued = true
	call_deferred("_flush_country_panel_refresh")


func _flush_country_panel_refresh() -> void:
	if _country_panel == null or not _country_panel.is_panel_open():
		_country_refresh_queued = false
		_country_refresh_timer_active = false
		return
	var section_mask := _country_section_mask(_country_panel.current_section())
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


func set_diagnostics_source(source: Node) -> void:
	if _diagnostics_source != null and _diagnostics_source.has_signal("gm_toggle_changed"):
		var old_callback := Callable(self, "_on_runtime_gm_toggle_changed")
		if _diagnostics_source.is_connected("gm_toggle_changed", old_callback):
			_diagnostics_source.disconnect("gm_toggle_changed", old_callback)
	if _diagnostics_source != null and _diagnostics_source.has_signal("gm_tod_preview_changed"):
		var old_sun_callback := Callable(self, "_on_gm_tod_preview_changed")
		if _diagnostics_source.is_connected("gm_tod_preview_changed", old_sun_callback):
			_diagnostics_source.disconnect("gm_tod_preview_changed", old_sun_callback)
	_diagnostics_source = source
	if source != null and source.has_signal("gm_toggle_changed"):
		var callback := Callable(self, "_on_runtime_gm_toggle_changed")
		if not source.is_connected("gm_toggle_changed", callback):
			source.connect("gm_toggle_changed", callback)
	if source != null and source.has_signal("gm_tod_preview_changed"):
		var sun_callback := Callable(self, "_on_gm_tod_preview_changed")
		if not source.is_connected("gm_tod_preview_changed", sun_callback):
			source.connect("gm_tod_preview_changed", sun_callback)
	if _gm_console != null:
		_gm_console.set_main(source)
	if _perf_hud != null:
		_perf_hud.set_main(source)
	_sync_military_map_toolbar()


func _sync_military_map_toolbar() -> void:
	_country_component._sync_military_map_toolbar(self)


func _on_military_layer_toggled(layer_id: StringName, enabled: bool) -> void:
	_overlay_component._on_military_layer_toggled(self, layer_id, enabled)


func set_colonization_route_layer(layer: ColonizationRouteLayer) -> void:
	_overlay_component.set_colonization_route_layer(self, layer)


func _configure_cell_hover_card() -> void:
	_overlay_component._configure_cell_hover_card(self)


func toggle_gm_panel() -> void:
	_overlay_component.toggle_gm_panel(self)


func is_gm_available() -> bool:
	return _overlay_component.is_gm_available(self)


func set_popups_suppressed(enabled: bool) -> void:
	_overlay_component.set_popups_suppressed(self, enabled)


func set_all_ui_suppressed(enabled: bool) -> void:
	_overlay_component.set_all_ui_suppressed(self, enabled)


func toggle_perf_hud() -> void:
	_overlay_component.toggle_perf_hud(self)


func show_cell_panel(cell: HexCell) -> void:
	# 议和窗口开着时地图是交割选格面（PlayerController.select_cell 已经拦过一次，
	# 这里是第二次兜底：任何把点击送到地块档案的路径都不能把窗口顶掉）。
	if is_peace_window_open():
		if cell != null:
			_peace_window.handle_map_cell(int(cell.index))
		return
	if _colonization_panel != null and _colonization_panel.visible:
		# 派发界面开着时，地图左键一律交给它：先出发城、后目的地，
		# 不再需要玩家先按面板上的“选点”按钮进入模式。
		if cell != null:
			_colonization_panel.handle_map_cell(int(cell.index))
		_colonization_targeting.clear()
		return
	_cancel_inspector_retry()
	# 地块档案一开，悬停卡就是纯噪音。这里确定性收起，不依赖 visibility_changed：
	# 面板已可见时再选另一格不会发出该信号。
	if _cell_hover_card != null:
		_cell_hover_card.dismiss(true)
	if _right_panel != null:
		_right_panel.close_detail(false)
	_object_detail_context.clear()
	_military_dossier_context.clear()
	_military_dossier_pending = false
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
	# [relayout-on-open 2026-11-02] 面板宽度是按 detail_open() 算的，但以前只在
	# viewport 尺寸变化时重算；地块档案/家族页打开后内容变宽，宽度还停在关闭档
	# （460），于是页签与 KPI 行被屏幕右缘切掉（真机 2670x1200 实测）。
	# 这里在模型换好之后补一次布局。
	call_deferred("_layout_right_panel")
	_selection_context = _revision_selection_context(
		_inspector_view_model.live_patch_revision(cell, _right_panel.current_tab()))
	if _country_panel != null and _country_panel.is_panel_open():
		_inspector_suppressed_for_country = true
		_right_panel.visible = false
		return
	if not _right_panel.visible or _right_panel.has_meta("_ui_active_tween"):
		UIAnimation.fade_slide_in(_right_panel, Vector2(24.0, 0.0), UITokens.ANIM_MED)


func hide_cell_panel() -> void:
	_cancel_inspector_retry()
	_selected_cell = null
	_selection_context = ""
	_inspector_suppressed_for_country = false
	_military_dossier_context.clear()
	_military_dossier_pending = false
	if _right_panel != null:
		_right_panel.set_directory_available(true)
	_invalidate_live_revision()
	_set_inspector_trace_cell(-1)
	if _right_panel != null:
		_right_panel.close_detail(false)
		call_deferred("_layout_right_panel")
	if _right_panel != null:
		UIAnimation.fade_slide_out(_right_panel, Vector2(24.0, 0.0), UITokens.ANIM_FAST)


## Web：把检查器日刷的耗时打进事件流（只在 >200ms 时），用来定位"整帧不返回"。
func _report_inspector_daily_timing(timing: Dictionary, started_usec: int) -> void:
	_country_component._report_inspector_daily_timing(self, timing, started_usec)


func refresh_selected_daily_lines(force: bool = false, day_idx: int = -1) -> Dictionary:
	return _country_component.refresh_selected_daily_lines(self, force, day_idx)


func refresh_selected_panel() -> void:
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
	if _player_controller == null:
		return
	if action == &"locate" or action == &"locate_cell":
		var cell := int(payload.get("cell", -1))
		if cell < 0:
			cell = int(payload.get("focus_cell", -1))
		if cell >= 0 and _player_controller.has_method("focus_cell"):
			_player_controller.call("focus_cell", cell)
		return
	var handle := int(payload.get("handle", 0))
	if handle <= 0:
		return
	var result: Dictionary = {}
	match action:
		&"move", &"area", &"explore":
			result = _player_controller.begin_military_arm_order(handle, String(action), 1)
		&"cancel_order":
			_player_controller.cancel_military_arm_order()
			return
		&"confirm_order":
			result = _player_controller.confirm_military_arm_order()
		&"radius":
			_player_controller.set_military_arm_order_radius(int(payload.get("radius", 1)))
			return
		&"stop", &"stance":
			_player_controller.cancel_military_arm_order()
			var command := &"military.army.stop" if action == &"stop" else &"military.army.stance"
			result = _player_controller.request_command(command,
				{"army": handle, "stance": int(payload.get("stance", 0))})
		_:
			return
	# 行军 / 区域控制成功也要给回执：否则确认键按下后档案毫无变化，玩家以为按钮坏了。
	var accepted := bool(result.get("ok", false))
	var fallback := "命令已下达，次日生效。" if accepted else "命令未生效：原因未返回，请重试。"
	_right_panel.set_military_dossier_feedback(
		String(result.get("message", fallback)), accepted)


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


func update_time_state(
		year_idx: int,
		month: int,
		day_of_month: int,
		paused: bool,
		speed: float
) -> void:
	_overlay_component.update_time_state(self, year_idx, month, day_of_month, paused, speed)


func set_world_summary(width: int, height: int, cells: int, seed: int) -> void:
	_overlay_component.set_world_summary(self, width, height, cells, seed)


func set_day_night_enabled(enabled: bool) -> void:
	_overlay_component.set_day_night_enabled(self, enabled)


func show_loading(message: String) -> void:
	_overlay_component.show_loading(self, message)


func set_generation_progress(stage: String, fraction: float) -> void:
	_overlay_component.set_generation_progress(self, stage, fraction)


func hide_loading() -> void:
	_overlay_component.hide_loading(self)


func map_safe_area() -> Rect2:
	return _hud_layout().map_safe_area()


## 刘海/挖孔/圆角：把整棵 UI（UIRoot 及其下 HUDLayer/PanelLayer/ModalLayer）整体内缩。
## 安全区来自 DisplayServer.get_display_safe_area()，MobileUIScaling 已换算成设计像素；
## 桌面/Web 上恒为 0，因此这里对桌面是完全的 no-op。地图（Node2D）不内缩——
## 让地图继续铺满全屏、只把可点控件避让开，是廉价且不会出现黑边的做法。
func _apply_ui_safe_area() -> void:
	_hud_layout()._apply_ui_safe_area()


## 常驻 HUD 栏内按钮的最小高度（设计像素）。按当前移动档位换算：
## 52 × 0.5dp/单位 ≈ 26dp（440dpi + 总缩放 1.375）。这里刻意不追到 44dp——
## 两条栏的高度是 anchor+offset 写死的（80 / 86），按钮再高就会溢出栏外；
## 真要抬到 44dp 必须同时改 PlayerTopBar.BAR_HEIGHT、CountryActionBar.BAR_HEIGHT
## 和 _base_map_safe_area()，属于 HUD 另一条线的工作。面板类控件统一走 TouchUI。
const TOUCH_MIN_HEIGHT := 52.0


## 手机横屏：顶栏的日期块/资源块原本只有 48 设计像素高（≈40dp），主操作栏 66（≈59dp）已经够。
## 只抬这两条常驻栏；面板内部密集的按钮在 ScrollContainer 里，改了反而容易撑破卡片。
func _apply_touch_hud_metrics() -> void:
	var settings := get_node_or_null("/root/GameSettings")
	if settings == null or not settings.has_method("ui_scaling"):
		return
	var scaling = settings.call("ui_scaling")
	if scaling == null or not bool(scaling.call("is_touch_profile")):
		return
	for path in ["UIRoot/HUDLayer/PlayerTopBar", "UIRoot/HUDLayer/CountryActionBar"]:
		var bar := get_node_or_null(path)
		if bar != null and bar.has_method("apply_touch_metrics"):
			bar.call("apply_touch_metrics", TOUCH_MIN_HEIGHT)
	# 面板层：经济卷宗/科技/家族/理念/国家面板/暂停菜单/GM 控制台/殖民规划/年报/store
	# 全部挂在这三层的下面。这里一次性 watch 三层，靠 child_entered_tree 覆盖
	# 「之后才实例化/换页/重建列表」的控件——不用在几十个 .tscn 里各写一遍。
	_watch_touch_panels()


## 面板层触摸命中区。桌面档 TouchUI 内部直接 return，等于 no-op。
## 顶栏 / 主操作栏已经由上面的 apply_touch_metrics(TOUCH_MIN_HEIGHT) 处理：
## 它们的高度是 anchor+offset 写死的 80 / 86 设计像素，内部按钮若抬到 88 会溢出栏外，
## 所以用 skip_names 跳过（要抬到 44dp 必须同步改 BAR_HEIGHT 与地图安全区）。
func _watch_touch_panels() -> void:
	var options := {"skip_names": ["PlayerTopBar", "CountryActionBar"]}
	for path in ["UIRoot/HUDLayer", "UIRoot/PanelLayer", "UIRoot/ModalLayer", "UIRoot/DebugLayer"]:
		var layer := get_node_or_null(path)
		if layer != null:
			TouchUI.watch(layer, options)
	if _right_panel != null:
		TouchUI.watch(_right_panel)


func _base_map_safe_area() -> Rect2:
	return _hud_layout()._base_map_safe_area()


func dismiss_overlay_menu() -> bool:
	return _overlay_component.dismiss_overlay_menu(self)


func toggle_pause_menu() -> void:
	_overlay_component.toggle_pause_menu(self)


func _ensure_era_panel() -> void:
	if _era_panel != null and is_instance_valid(_era_panel):
		return
	var host := get_node_or_null("UIRoot/EraOverlayLayer") as Control
	if host == null:
		return
	_era_panel = EraAdvancementPanelScene.instantiate() as EraAdvancementPanel
	_era_panel.name = "EraAdvancementPanel"
	host.add_child(_era_panel)
	# 纸笺垫底、晋升光带压在上面。纸徽已归 HUDLayer（面板之下），这里不再需要把它排在纸徽之前。
	host.move_child(_era_panel, 0)
	_bind_era_panel()


func _start_era_ceremony(old_index: int, new_index: int, buffs: PackedStringArray) -> void:
	if _gm_popups_suppressed:
		# GM 屏蔽事件时只同步时代基线，不创建会暂停时钟的大典。
		_era_celebrated_index = new_index
		_era_ceremony_index = -1
		return
	if is_era_ceremony_playing():
		_era_ceremony.finish_now()
	_era_celebrated_index = new_index
	_era_ceremony_index = new_index
	if _era_indicator_view_model == null:
		_era_indicator_view_model = EraIndicatorViewModel.new()
	var new_id := _era_indicator_view_model.era_id_for(new_index)
	var new_name := _era_indicator_view_model.era_name_for(new_index)
	_era_ceremony_landed_name = new_name
	# 日历时代名在徽记飞回之前保持旧字。
	_era_transfer_name = new_name
	if _era_panel != null and _era_panel.visible:
		_era_panel.close(true)
	if _era_reward_dialog != null and _era_reward_dialog.visible \
			and not _era_reward_dialog.is_offer_open():
		_era_reward_dialog.close_overview(true)
	if _era_indicator != null:
		_era_indicator.set_expanded(false)
	if _cell_hover_card != null:
		_cell_hover_card.dismiss(true)
	var host := get_node_or_null("UIRoot/ModalLayer") as Control
	if host == null:
		_land_era_on_badge(new_name)
		return
	_era_ceremony = EraAscensionCeremonyScene.instantiate() as EraAscensionCeremony
	_era_ceremony.name = "EraAscensionCeremony"
	host.add_child(_era_ceremony)
	# 压住卷宗、奖励弹窗与加载层，但暂停菜单始终在最上。
	if _pause_menu != null and _pause_menu.get_parent() == host:
		host.move_child(_era_ceremony, _pause_menu.get_index())
	_era_ceremony.emblem_landed.connect(_on_era_ceremony_landed.bind(new_index))
	_era_ceremony.finished.connect(_on_era_ceremony_finished)
	_pause_clock_for_ceremony()
	_era_ceremony.play({
		"old_era_id": _era_indicator_view_model.era_id_for(old_index),
		"new_era_id": new_id, "new_era_name": new_name,
		"subtitle": EraIndicatorViewModel.era_flavor(new_id),
		"buffs": buffs,
		"target": _era_indicator.icon_origin() if _era_indicator != null else null,
	})


func show_exit_save_failure(action: String, result: Dictionary) -> void:
	_overlay_component.show_exit_save_failure(self, action, result)


func set_resource_discovery_context(
	technology_ids: PackedStringArray,
	enforce_discovery: bool = false
) -> void:
	_country_component.set_resource_discovery_context(self, technology_ids, enforce_discovery)


func _refresh_player_discovery_context() -> void:
	_country_component._refresh_player_discovery_context(self)


func set_player_controller(controller) -> void:
	if _player_controller != null and _player_controller.has_signal("command_completed"):
		var old_audio := Callable(self, "_on_player_command_completed_audio")
		if _player_controller.command_completed.is_connected(old_audio):
			_player_controller.command_completed.disconnect(old_audio)
	if _player_controller != null and _player_controller.has_signal("country_committed"):
		var old_callback := Callable(self, "_on_country_committed")
		if _player_controller.country_committed.is_connected(old_callback):
			_player_controller.country_committed.disconnect(old_callback)
	if _player_controller != null and _player_controller.has_signal("command_settled"):
		var old_settled := Callable(self, "_on_player_command_settled")
		if _player_controller.command_settled.is_connected(old_settled):
			_player_controller.command_settled.disconnect(old_settled)
	_disconnect_era_advancement_signals()
	_player_controller = controller
	_connect_era_advancement_signals()
	if _player_controller != null and _player_controller.has_signal("command_completed"):
		var audio_callback := Callable(self, "_on_player_command_completed_audio")
		if not _player_controller.command_completed.is_connected(audio_callback):
			_player_controller.command_completed.connect(audio_callback)
	if _country_panel != null and _country_panel.has_method("set_player_controller"):
		_country_panel.set_player_controller(controller)
	if _right_panel != null and _right_panel.has_method("set_player_controller"):
		_right_panel.set_player_controller(controller)
	if _colonization_panel != null:
		_colonization_panel.set_player_controller(controller)
	_refresh_dispatch_status()
	if _player_controller != null and _player_controller.has_signal("country_committed"):
		var callback := Callable(self, "_on_country_committed")
		if not _player_controller.country_committed.is_connected(callback):
			_player_controller.country_committed.connect(callback)
	if _player_controller != null and _player_controller.has_signal("command_settled"):
		var settled := Callable(self, "_on_player_command_settled")
		if not _player_controller.command_settled.is_connected(settled):
			_player_controller.command_settled.connect(settled)


func _connect_era_advancement_signals() -> void:
	if _player_controller == null:
		return
	if _player_controller.has_signal("era_advancement_changed"):
		var changed := Callable(self, "_on_era_advancement_changed")
		if not _player_controller.era_advancement_changed.is_connected(changed):
			_player_controller.era_advancement_changed.connect(changed)
	if _player_controller.has_signal("era_advanced"):
		var advanced := Callable(self, "_on_player_era_advanced")
		if not _player_controller.era_advanced.is_connected(advanced):
			_player_controller.era_advanced.connect(advanced)


func _disconnect_era_advancement_signals() -> void:
	if _player_controller == null:
		return
	if _player_controller.has_signal("era_advancement_changed"):
		var changed := Callable(self, "_on_era_advancement_changed")
		if _player_controller.era_advancement_changed.is_connected(changed):
			_player_controller.era_advancement_changed.disconnect(changed)
	if _player_controller.has_signal("era_advanced"):
		var advanced := Callable(self, "_on_player_era_advanced")
		if _player_controller.era_advanced.is_connected(advanced):
			_player_controller.era_advanced.disconnect(advanced)


func _bind_ui() -> void:
	_top_bar = get_node("UIRoot/HUDLayer/PlayerTopBar") as PlayerTopBar
	_top_bar.pause_toggled.connect(func(paused: bool) -> void: pause_toggled.emit(paused))
	_top_bar.speed_selected.connect(func(speed: float) -> void: speed_selected.emit(speed))
	_top_bar.day_night_toggled.connect(
		func(enabled: bool) -> void: day_night_toggled.emit(enabled))
	_top_bar.setup_requested.connect(toggle_pause_menu)
	_top_bar.gm_requested.connect(toggle_gm_panel)
	_top_bar.annual_history_requested.connect(func() -> void: annual_history_requested.emit())
	_top_bar.dispatch_requested.connect(_open_dispatch_progress)
	_top_bar.set_gm_available(false)
	_layout_top_bar()
	_status_card = get_node_or_null("UIRoot/HUDLayer/HudStatusCard") as HudStatusCard
	if _status_card != null:
		_top_bar.status_hovered.connect(_on_top_bar_status_hovered)
		_top_bar.status_pressed.connect(_on_top_bar_status_pressed)

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
	_right_panel.trade_orders_page_requested.connect(
		_on_trade_orders_page_requested)
	_right_panel.trade_order_locate_requested.connect(
		_on_trade_order_locate_requested)
	_right_panel.military_state_building_requested.connect(
		_on_military_state_building_requested)
	_right_panel.military_army_create_requested.connect(
		_on_military_army_create_requested)
	_right_panel.military_army_selected.connect(
		_on_military_army_selected)
	_right_panel.military_dossier_action_requested.connect(
		_on_military_dossier_action_requested)
	_right_panel.military_dossier_army_selected.connect(
		_on_military_dossier_army_selected)
	_layout_right_panel()

	_colonization_panel = get_node(
		"UIRoot/ModalLayer/ColonizationPlannerPanel") as ColonizationPlannerPanel
	_colonization_panel.set_player_controller(_player_controller)
	_colonization_panel.closed.connect(_on_dispatch_closed)
	_colonization_panel.target_selection_requested.connect(func() -> void:
		_colonization_targeting = {"active": true})
	_colonization_panel.source_selection_requested.connect(func() -> void:
		_colonization_targeting = {"active": true})
	_colonization_panel.planning_context_changed.connect(_on_colonization_planning_context)
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
	_refresh_dispatch_status()
	# 议和窗口：与开拓面板同一条「地图作业面」通道，但它的草案是交割地块。
	_peace_window = get_node_or_null("UIRoot/ModalLayer/MilitaryPeaceWindow")
	if _peace_window != null:
		_peace_window.closed.connect(_on_peace_window_closed)
		_peace_window.submit_requested.connect(_on_peace_submit_requested)
		_peace_window.locate_cell_requested.connect(_on_peace_locate_requested)
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
		_gm_console.visibility_changed.connect(_sync_gm_sun_handle)
		_layout_gm_panel()

	_perf_hud = get_node("UIRoot/HUDLayer/PerfMiniHUD") as PerfMiniHUD

	_map_overlay_toolbar = get_node("UIRoot/HUDLayer/MapOverlayToolbar") as MapOverlayToolbar
	_map_overlay_toolbar.overlay_requested.connect(_on_map_overlay_requested)
	_map_overlay_toolbar.overlay_cleared.connect(_on_map_overlay_cleared)
	_layout_map_overlay_toolbar()
	_military_map_toolbar = get_node_or_null("UIRoot/HUDLayer/MilitaryMapToolbar") as MilitaryMapToolbar
	if _military_map_toolbar != null:
		_military_map_toolbar.layer_toggled.connect(_on_military_layer_toggled)

	_country_action_bar = get_node("UIRoot/HUDLayer/CountryActionBar") as CountryActionBar
	_country_action_bar.section_selected.connect(open_country_section)
	_layout_country_action_bar()
	_ensure_research_toast()

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
	get_viewport().size_changed.connect(_layout_family_founding_dialog)
	get_viewport().size_changed.connect(_apply_ui_safe_area)
	get_viewport().size_changed.connect(_apply_touch_hud_metrics)
	_apply_ui_safe_area()
	_apply_touch_hud_metrics()
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
	_country_panel.section_selected.connect(open_country_section)
	_country_panel.locate_cell_requested.connect(_locate_cell_from_country_panel)
	_country_panel.target_cells_requested.connect(_on_target_cells_from_country_panel)
	if _country_panel.has_signal("peace_negotiation_requested"):
		_country_panel.peace_negotiation_requested.connect(open_military_peace)
	if _country_panel.has_signal("military_dossier_requested"):
		_country_panel.military_dossier_requested.connect(open_military_dossier)

	_loading_overlay = get_node("UIRoot/ModalLayer/WorldLoadingOverlay") as WorldLoadingOverlay

	_annual_report_workspace = AnnualReportWorkspaceScene.instantiate()
	get_node("UIRoot/ModalLayer").add_child(_annual_report_workspace)
	_annual_report_workspace.closed.connect(func(id: int) -> void: annual_report_closed.emit(id))
	_annual_report_workspace.report_selected.connect(func(id: int) -> void: annual_report_selected.emit(id))
	_annual_report_workspace.history_page_requested.connect(func(offset: int) -> void: annual_history_page_requested.emit(offset))
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
	_era_reward_dialog.dismiss_requested.connect(_on_era_popup_dismissed)
	# 时代徽记只是 HUD：挂在 HUDLayer 末位，画在日期栏之上、所有面板之下——
	# 国家卷宗的压暗遮罩、右侧检视面板与全部模态窗都能照常盖住它。
	# 晋升光带与纸笺仍在 EraOverlayLayer（PanelLayer 之上、ModalLayer 之下），
	# 让「徽记飞回日历」这类一次性演出在打开的卷宗之上仍然看得见。
	_era_indicator = get_node("UIRoot/HUDLayer/EraIndicator") as EraIndicator
	_era_flight = get_node("UIRoot/EraOverlayLayer/EraTransitionFlight") as Control
	_era_indicator.era_advanced.connect(_on_era_indicator_advanced)
	# defer 只在大典播放期间为真：大典结束后纸徽必须自己跟上模型，
	# 否则一旦接管的 landed 路径没走到，图标会永远停在旧时代。
	_era_indicator.defer_celebration = false
	_era_flight.landed.connect(_on_era_flight_landed)
	_era_indicator.pressed.connect(_on_era_indicator_pressed)
	_ensure_era_panel()
	_family_founding_dialog = get_node_or_null(
		"UIRoot/ModalLayer/FamilyFoundingDialog") as FamilyFoundingDialog
	if _family_founding_dialog != null:
		_family_founding_dialog.choice_requested.connect(
			func(offer_id: int, generation: int, index: int) -> void:
				family_founding_choice_requested.emit(offer_id, generation, index))
		_family_founding_dialog.locate_cell_requested.connect(
			_locate_cell_from_family_founding)
		_family_founding_dialog.inspector_close_requested.connect(func() -> void:
			if _right_panel != null:
				_right_panel.close_detail())
		_family_founding_dialog.collapsed_changed.connect(_on_founding_collapsed_changed)
		_layout_family_founding_dialog()
	_ensure_cell_hover_card()
	_ensure_narrative_ui()


func _ensure_narrative_ui() -> void:
	var modal_layer := get_node_or_null("UIRoot/ModalLayer") as Control
	if modal_layer == null:
		return
	if _narrative_event_dialog == null:
		_narrative_event_dialog = NarrativeEventDialogScript.new()
		_narrative_event_dialog.name = "NarrativeEventDialog"
		modal_layer.add_child(_narrative_event_dialog)
		_narrative_event_dialog.option_selected.connect(
			func(offer_id: int, generation: int, idx: int) -> void:
				narrative_event_option_selected.emit(offer_id, generation, idx)
		)
		_narrative_event_dialog.outcome_acknowledged.connect(
			func() -> void:
				narrative_event_outcome_acknowledged.emit()
		)
		_narrative_event_dialog.locate_cell_requested.connect(
			_locate_cell_from_family_founding
		)
		_narrative_event_dialog.chronicle_requested.connect(
			func() -> void:
				narrative_chronicle_requested.emit()
		)
	if _narrative_chronicle_panel == null:
		_narrative_chronicle_panel = NarrativeChroniclePanelScript.new()
		_narrative_chronicle_panel.name = "NarrativeChroniclePanel"
		modal_layer.add_child(_narrative_chronicle_panel)
		_narrative_chronicle_panel.locate_cell_requested.connect(
			func(cell_idx: int) -> void:
				_narrative_chronicle_panel.close_panel()
				_locate_cell_from_family_founding(cell_idx)
		)
	if _pause_menu != null and _pause_menu.get_parent() == modal_layer:
		modal_layer.move_child(_pause_menu, modal_layer.get_child_count() - 1)


func _ensure_cell_hover_card() -> void:
	_overlay_component._ensure_cell_hover_card(self)


## 悬停卡的抑制策略集中在这里：任何"地图不该被打扰"的状态都返回 true。
func _hover_blocked() -> bool:
	return _country_component._hover_blocked(self)


func _locate_cell_from_family_founding(cell_index: int) -> void:
	_country_component._locate_cell_from_family_founding(self, cell_index)


func _layout_family_founding_dialog() -> void:
	_hud_layout()._layout_family_founding_dialog()


func _on_founding_collapsed_changed(collapsed: bool) -> void:
	_country_component._on_founding_collapsed_changed(self, collapsed)


func _cancel_colonization_targeting() -> void:
	_country_component._cancel_colonization_targeting(self)


func _on_colonization_planning_context(context: Dictionary) -> void:
	_country_component._on_colonization_planning_context(self, context)


func _unhandled_input(event: InputEvent) -> void:
	# 议和窗口没有独立的「选点模式」——窗口开着时任何左键都算交割，所以 Esc 直接关窗。
	if is_peace_window_open() and event is InputEventKey and event.pressed \
			and not event.echo and event.keycode == KEY_ESCAPE:
		close_military_peace()
		get_viewport().set_input_as_handled()
		return
	if _status_card != null and _status_card.is_open() and TouchUI.is_touch():
		if (event is InputEventMouseButton and event.pressed) or (event is InputEventScreenTouch and event.pressed):
			_status_card_generation += 1
			_status_card_kind = ""
			_status_card.hide_card(true)
	if _colonization_panel == null or not (_colonization_panel.is_source_picking() \
			or _colonization_panel.is_target_picking()):
		return
	# 只有 Esc 退出显式选点。右键是地图平移键，吃掉它等于废掉拖动视角。
	if event is InputEventKey and event.pressed and not event.echo \
			and event.keycode == KEY_ESCAPE:
		_cancel_colonization_targeting()
		get_viewport().set_input_as_handled()

func _on_map_overlay_requested(request: Dictionary) -> void:
	_overlay_component._on_map_overlay_requested(self, request)


func _on_map_overlay_cleared() -> void:
	_overlay_component._on_map_overlay_cleared(self)


func _on_inspector_visibility_changed() -> void:
	if _right_panel != null and not _right_panel.visible and _player_controller != null:
		_player_controller.cancel_military_arm_order()
	# 地块档案一开，悬停卡就是纯噪音；确定性关掉，不等下一帧轮询。
	if _right_panel != null and _right_panel.visible and _cell_hover_card != null:
		_cell_hover_card.dismiss(true)
	_layout_right_panel()
	_layout_overlay_legend()
	_layout_country_action_bar()
	_layout_gm_panel()
	_layout_family_founding_dialog()


func _on_inspector_detail_visibility_changed(open: bool) -> void:
	if not open:
		if _player_controller != null:
			_player_controller.cancel_military_arm_order()
			if not _military_dossier_context.is_empty():
				_player_controller.clear_military_map_selection()
		if _right_panel != null:
			_right_panel.set_directory_available(true)
		_object_detail_context.clear()
		_pending_object_request.clear()
		_military_dossier_context.clear()
		_military_dossier_pending = false
	_layout_right_panel()
	_layout_overlay_legend()
	_layout_country_action_bar()
	_layout_gm_panel()
	_layout_family_founding_dialog()
	if open and _base_map_safe_area().size.x >= MAP_REMAINING_MIN_WIDTH \
			and _player_controller != null and _player_controller.has_method(
			"ensure_selected_visible"):
		_player_controller.ensure_selected_visible()


func _layout_overlay_legend() -> void:
	_hud_layout()._layout_overlay_legend()


func _layout_country_action_bar() -> void:
	_hud_layout()._layout_country_action_bar()


func _ensure_research_toast() -> void:
	_country_component._ensure_research_toast(self)


func _layout_research_toast() -> void:
	_hud_layout()._layout_research_toast()


func _poll_research_completion_toasts() -> Dictionary:
	return _country_component._poll_research_completion_toasts(self)


func _layout_gm_panel() -> void:
	_hud_layout()._layout_gm_panel()


# [web-layout-guard] PlayerTopBar / RightPanel 之前完全依赖 .tscn 里静态烘焙的
# anchor+offset（从未在运行时被脚本重新应用过）。CountryActionBar/OverlayLegend/
# GMPanel 三者虽然各自出于自己的动态需求（跟随姊妹面板可见性、紧凑模式阈值等）
# 早就在跑"取实时 viewport 尺寸 → set_anchors_preset → 写 offset"这条路径，
# 但客观上也顺带验证了这条路径在当前运行环境下是可靠的。这里让顶栏/详情面板走
# 同一条已验证路径兜底，不再单纯依赖引擎在 Web 上是否可靠地对声明式 anchor
# 做持续重新解算——即使原声明式 anchor 一直正常，这里重新套用同样的数值也是
# 幂等的，不会有副作用。
func _layout_top_bar() -> void:
	_hud_layout()._layout_top_bar()


## [web-layout-guard] 左侧地图图层工具条（MapOverlayToolbar）是这套静态布局里
## 最后一个只靠 .tscn 烘焙 anchor+offset、却没有任何运行期重新结算的 HUD 节点。
## Web 上已经证明这类节点拿不到声明式布局：PlayerTopBar / RightPanel 之前就是同一
## 症状，后来靠运行期兜底修好；工具条漏在外面，于是它的 rect 落成默认的 (0,0)，
## PrimaryPanel 被摆到屏幕左上角，正好盖住顶栏左侧的日历图标和"第N年"纸框
## （截图里的"图标和日历重合"）。
##
## 这里和顶栏/详情面板走完全相同的路径：取实时值 → set_anchors_preset → 写
## offset。数值与 .tscn 里的声明保持一致（左 16 / 顶 顶栏高度+12 / 右 -16 /
## 底 -16），所以在桌面端是幂等的；顶栏高度用实时 size 而不是常量，是为了让
## 后续顶栏变高时工具条自动让位。
func _layout_map_overlay_toolbar() -> void:
	_hud_layout()._layout_map_overlay_toolbar()




## 当前是否触摸档（手机/平板）。桌面返回 false，所有触摸专用版面改动都是 no-op。
func touch_layout_enabled() -> bool:
	return _overlay_component.touch_layout_enabled(self)


func _dump_panel_children(node: Node, depth: int) -> void:
	_hud_layout()._dump_panel_children(node, depth)


func _layout_right_panel() -> void:
	_hud_layout()._layout_right_panel()


static func panel_content_min_width(panel: Control) -> float:
	return GameHudLayout.panel_content_min_width(panel)


static func resolve_panel_content_width(viewport_width: float,
		requested_width: float, content_min_width: float) -> float:
	return GameHudLayout.resolve_panel_content_width(
		viewport_width, requested_width, content_min_width)


static func inspector_layout_for_width(viewport_width: float,
		detail_open: bool, family_open: bool = false) -> Dictionary:
	return GameHudLayout.inspector_layout_for_width(viewport_width, detail_open, family_open)


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
	_hud_layout()._log_ui_layout_diagnostics(tag)


func _hud_layout():
	return _overlay_component._hud_layout(self)


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
	_country_component._retry_inspector_reads(self, generation)

func _on_construction_page_requested(sector: String, search: String,
		sort_id: String, offset: int) -> void:
	_country_component._on_construction_page_requested(self, sector, search, sort_id, offset)

func _refresh_building_workspace(force: bool = false) -> void:
	_country_component._refresh_building_workspace(self, force)

func _on_construction_requested(request: Dictionary) -> void:
	_country_component._on_construction_requested(self, request)

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
	_country_component._on_object_details_requested(self, request)

func _close_object_detail_dialog() -> void:
	_country_component._close_object_detail_dialog(self)

func _refresh_object_detail(force: bool = false) -> void:
	_country_component._refresh_object_detail(self, force)

func show_era_reward_offer(offer: Dictionary) -> void:
	_era_component.show_era_reward_offer(self, offer)

func _build_era_overview() -> Dictionary:
	return _era_component._build_era_overview(self)

func _on_era_indicator_pressed() -> void:
	_era_component._on_era_indicator_pressed(self)

func _bind_era_panel() -> void:
	_era_panel.close_requested.connect(_close_era_panel)
	_era_panel.command_requested.connect(_on_era_panel_command)
	_era_panel.treasury_requested.connect(func() -> void:
		_close_era_panel()
		open_country_section("economy", "overview"))
	_era_panel.reward_requested.connect(func() -> void:
		era_reward_open_requested.emit())

func _close_era_panel() -> void:
	_era_component._close_era_panel(self)

func is_era_panel_open() -> bool:
	return _era_component.is_era_panel_open(self)

func _on_era_panel_command(command: StringName) -> void:
	_era_component._on_era_panel_command(self, command)

func _era_advancement_model(fresh: bool = false) -> Dictionary:
	return _era_component._era_advancement_model(self, fresh)

func _on_era_advancement_changed(snapshot: Dictionary) -> void:
	_era_component._on_era_advancement_changed(self, snapshot)

func _apply_era_advancement(snapshot: Dictionary) -> void:
	_era_component._apply_era_advancement(self, snapshot)

func _on_era_popup_dismissed() -> void:
	_era_component._on_era_popup_dismissed(self)

func notify_era_reward_offer(offer: Dictionary) -> void:
	_era_component.notify_era_reward_offer(self, offer)

func _queue_era_indicator_refresh() -> void:
	if _era_refresh_queued or not is_inside_tree():
		return
	_era_refresh_queued = true
	get_tree().create_timer(0.10).timeout.connect(func() -> void:
		_era_refresh_queued = false
		_refresh_era_indicator())

func _refresh_era_indicator() -> void:
	_era_component._refresh_era_indicator(self)

func _refresh_player_country_status(country_facade, economy_facade, handle: int) -> void:
	_era_component._refresh_player_country_status(self, country_facade, economy_facade, handle)

func _on_top_bar_status_hovered(kind: String, entered: bool) -> void:
	if _status_card == null or not is_inside_tree() or _top_bar == null:
		return
	if TouchUI.is_touch():
		return
	_status_card_generation += 1
	var generation := _status_card_generation
	if not entered:
		await get_tree().create_timer(STATUS_CARD_HIDE_DELAY).timeout
		if generation == _status_card_generation and _status_card != null:
			_status_card.hide_card()
			_status_card_kind = ""
		return
	await get_tree().create_timer(STATUS_CARD_SHOW_DELAY).timeout
	if generation != _status_card_generation or _status_card == null:
		return
	var model := _build_status_card_model(kind)
	if model.is_empty():
		return
	_status_card_kind = kind
	_status_card_next_refresh_ms = Time.get_ticks_msec() + STATUS_CARD_REFRESH_MSEC
	_status_card.show_card(model, _top_bar.status_anchor(kind))

func _on_top_bar_status_pressed(kind: String) -> void:
	_era_component._on_top_bar_status_pressed(self, kind)

func _refresh_status_card() -> void:
	_era_component._refresh_status_card(self)

func _build_status_card_model(kind: String) -> Dictionary:
	return _era_component._build_status_card_model(self, kind)

func _on_era_indicator_advanced(model: Dictionary) -> void:
	_era_component._on_era_indicator_advanced(self, model)

func _on_player_era_advanced(old_index: int, new_index: int, buffs: PackedStringArray) -> void:
	_era_component._on_player_era_advanced(self, old_index, new_index, buffs)

func _ceremony_buffs_from_snapshot(new_index: int) -> PackedStringArray:
	return _era_component._ceremony_buffs_from_snapshot(self, new_index)

func is_era_ceremony_playing() -> bool:
	return _era_component.is_era_ceremony_playing(self)

func _on_era_ceremony_landed(new_index: int) -> void:
	_era_component._on_era_ceremony_landed(self, new_index)

func _land_era_on_badge(era_name: String) -> void:
	_era_component._land_era_on_badge(self, era_name)

func _on_era_ceremony_finished() -> void:
	_era_component._on_era_ceremony_finished(self)

func _abort_era_ceremony() -> void:
	_era_component._abort_era_ceremony(self)

func _pause_clock_for_ceremony() -> void:
	_era_component._pause_clock_for_ceremony(self)

func _restore_clock_after_ceremony() -> void:
	_era_component._restore_clock_after_ceremony(self)

func _notify_era_promoted(model: Dictionary) -> void:
	_era_component._notify_era_promoted(self, model)

func _on_era_flight_landed() -> void:
	_era_component._on_era_flight_landed(self)

func show_era_reward_error(message: String) -> void:
	_era_component.show_era_reward_error(self, message)

func show_era_reward_pending() -> void:
	_era_component.show_era_reward_pending(self)

func close_era_reward_offer() -> void:
	_era_component.close_era_reward_offer(self)

func is_era_reward_modal_open() -> bool:
	return _era_component.is_era_reward_modal_open(self)

func show_family_founding_offer(offer: Dictionary) -> void:
	_era_component.show_family_founding_offer(self, offer)

func show_family_founding_error(message: String) -> void:
	_era_component.show_family_founding_error(self, message)

func close_family_founding_offer() -> void:
	_era_component.close_family_founding_offer(self)

func is_family_founding_modal_open() -> bool:
	return _era_component.is_family_founding_modal_open(self)

func bind_gm_sun_camera(camera: MapCamera) -> void:
	_overlay_component.bind_gm_sun_camera(self, camera)

func bind_player_camera(camera: MapCamera) -> void:
	_overlay_component.bind_player_camera(self, camera)

func _ensure_gm_sun_handle() -> void:
	_overlay_component._ensure_gm_sun_handle(self)

func _on_gm_sun_camera_moved(_world_rect: Rect2, _center: Vector2, _zoom_value: float) -> void:
	_overlay_component._on_gm_sun_camera_moved(self, _world_rect, _center, _zoom_value)

func _on_gm_tod_preview_changed(_active: bool) -> void:
	_overlay_component._on_gm_tod_preview_changed(self, _active)

func _sync_gm_sun_handle() -> void:
	_overlay_component._sync_gm_sun_handle(self)

func _position_gm_sun_handle() -> void:
	_overlay_component._position_gm_sun_handle(self)

func _on_gm_sun_handle_input(event: InputEvent) -> void:
	_overlay_component._on_gm_sun_handle_input(self, event)

func _apply_gm_sun_drag(screen_pos: Vector2) -> void:
	_overlay_component._apply_gm_sun_drag(self, screen_pos)

func _get_local_gm_toggle_state(toggle_id: String) -> Dictionary:
	return _overlay_component._get_local_gm_toggle_state(self, toggle_id)

func _set_local_gm_toggle(toggle_id: String, enabled: bool) -> Dictionary:
	return _overlay_component._set_local_gm_toggle(self, toggle_id, enabled)

func _on_runtime_gm_toggle_changed(toggle_id: String, enabled: bool) -> void:
	_overlay_component._on_runtime_gm_toggle_changed(self, toggle_id, enabled)

func show_annual_report(model: Dictionary, ceremonial: bool) -> void:
	_overlay_component.show_annual_report(self, model, ceremonial)

func set_annual_history(rows: Array, offset: int, has_more: bool) -> void:
	_overlay_component.set_annual_history(self, rows, offset, has_more)

func is_annual_report_open() -> bool:
	return _overlay_component.is_annual_report_open(self)

func close_annual_report() -> void:
	_overlay_component.close_annual_report(self)

func annual_other_modal_open() -> bool:
	return _overlay_component.annual_other_modal_open(self)

func show_narrative_event_offer(offer: Dictionary) -> void:
	_overlay_component.show_narrative_event_offer(self, offer)

func show_narrative_event_outcome(resolution: Dictionary) -> void:
	_overlay_component.show_narrative_event_outcome(self, resolution)

func show_narrative_event_error(message: String) -> void:
	_overlay_component.show_narrative_event_error(self, message)

func set_narrative_event_illustration(tex: Texture2D) -> void:
	_overlay_component.set_narrative_event_illustration(self, tex)

func close_narrative_event_offer() -> void:
	_overlay_component.close_narrative_event_offer(self)

func is_narrative_event_modal_open() -> bool:
	return _overlay_component.is_narrative_event_modal_open(self)

func show_narrative_chronicle(records: Array) -> void:
	_overlay_component.show_narrative_chronicle(self, records)

func close_narrative_chronicle() -> void:
	_overlay_component.close_narrative_chronicle(self)

func is_narrative_chronicle_open() -> bool:
	return _overlay_component.is_narrative_chronicle_open(self)
