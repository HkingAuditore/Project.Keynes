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
const TouchUI = preload("res://scripts/ui/touch_ui.gd")
var _annual_report_workspace: Control
var _narrative_event_dialog: Control
var _narrative_chronicle_panel: Control

const RIGHT_PANEL_WIDTH := 460.0
const DETAIL_LAYOUT_BREAKPOINT := UITokens.DETAIL_BREAKPOINT_COMPACT + UITokens.ARCHIVE_EDGE_INSET * 2.0
const FAMILY_DETAIL_MIN_WIDTH := 620.0
const FAMILY_DETAIL_MAX_WIDTH := 900.0
const DETAIL_PANEL_MIN_WIDTH := 860.0
const DETAIL_PANEL_MAX_WIDTH := 1040.0
const MAP_REMAINING_MIN_WIDTH := 320.0
const OVERLAY_LEGEND_WIDTH := 198.0
# 左侧地图图层工具条与顶栏之间的垂直间距（= .tscn 里 92 - 80 的净空）。
const OVERLAY_TOOLBAR_TOP_GAP := UITokens.SPACE_MD
const GM_PANEL_TARGET_WIDTH := 560.0
const GM_PANEL_MIN_WIDTH := 300.0
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
const COUNTRY_DIRTY_IDEOLOGY := 4
## 军事：自己的 facade，不参与国家 ui_snapshot 分段，但仍然共用同一个脏位管道。
const COUNTRY_DIRTY_MILITARY := 8
## 外交：读的是领土镜像 + 军事快照 + 视野，没有自己的原生分片，同样只借脏位管道。
const COUNTRY_DIRTY_DIPLOMACY := 16
const COUNTRY_DIRTY_ALL := COUNTRY_DIRTY_TECHNOLOGY | COUNTRY_DIRTY_ECONOMY \
	| COUNTRY_DIRTY_IDEOLOGY | COUNTRY_DIRTY_MILITARY | COUNTRY_DIRTY_DIPLOMACY
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
	if _inspector_view_model == null:
		_inspector_view_model = CellInspectorViewModel.new()
	_cancel_inspector_retry()
	_map = map
	_world_clock = world_clock
	_gdp_ledger.configure(generator, world_clock, map)
	if _colonization_route != null:
		var wrap_period := float(_diagnostics_source.map_wrap_period_x()) \
			if _diagnostics_source != null and _diagnostics_source.has_method(
				"map_wrap_period_x") else 0.0
		_colonization_route.set_context(map, world_clock, hex_size, wrap_period)
	_inspector_view_model.set_context(map, generator, view_adapter, world_clock, sea_level, hex_size)
	_inspector_view_model.set_gdp_ledger(_gdp_ledger)
	_hover_hex_size = hex_size
	if _cell_hover_view_model == null:
		_cell_hover_view_model = CellHoverViewModel.new()
	_cell_hover_view_model.set_context(map, generator, _inspector_view_model, world_clock)
	if _cell_hover_card != null:
		_cell_hover_card.reset_for_world()
		_configure_cell_hover_card()
	_object_detail_context.clear()
	_selection_context = ""
	_invalidate_live_revision()
	if _country_view_model == null:
		_country_view_model = CountryViewModel.new()
	# 地图必须一起交出去：军事/外交视图模型要读领土镜像、邻接与视野，而 MapGenerator
	# 没有公开的 map getter（它的 `current_map()` 只在截图 fixture 里存在）。
	_country_view_model.set_context(generator, map)
	_country_view_model.set_gdp_ledger(_gdp_ledger)
	_bind_country_runtime_events(generator)
	if _era_reward_dialog != null:
		_era_reward_dialog.close_offer()
		_era_reward_dialog.close_overview(true)
	if _era_indicator != null:
		_era_indicator.reset_for_world()
		# refresh_country_binding 已同步新世界候选；重置动画后保留待领提示。
		_era_indicator.set_offer_available(String(_era_offer.get("status", "NONE")) in ["OPEN", "ERROR"])
	if _era_flight != null:
		_era_flight.cancel()
	_era_transfer_name = ""
	# 新世界/读档：撤掉进行中的大典（不补发落地，不恢复旧世界的时钟），只建立显示基线。
	_abort_era_ceremony()
	_era_celebrated_index = -1
	_era_advancement_snapshot = {}
	if _era_panel != null:
		_era_panel.close(true)
	_refresh_era_indicator()
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
	_country_refresh_timer_active = false
	_country_next_refresh_ms = 0


func _on_country_research_signal_discovered(_event: Dictionary) -> void:
	_mark_country_panel_dirty(COUNTRY_DIRTY_TECHNOLOGY, "research_signal")


func _on_economy_event_batch_available(_meta: Dictionary) -> void:
	_queue_era_indicator_refresh()
	if _country_view_model != null:
		_country_view_model.sample_economy_history()
	var domains := COUNTRY_DIRTY_ECONOMY
	# Treasury cash and development objectives on the research page are fed by
	# economy commits even on days when no country commit arrives.
	if _country_panel != null and _country_panel.is_panel_open() \
			and _country_panel.current_section() == "technology":
		var now := Time.get_ticks_msec()
		if now >= _next_tech_economy_refresh_ms:
			_next_tech_economy_refresh_ms = now + TECH_ECONOMY_REFRESH_INTERVAL_MSEC
			domains |= COUNTRY_DIRTY_TECHNOLOGY
	_mark_country_panel_dirty(domains, "economy_commit")


## 经济事件批次只在有事件的日子发布，开局常连续数日没有；经济卷宗打开时
## 每个已提交日都要推进一次，否则数据停在打开那天。刷新仍走墙钟节流。
func notify_committed_day() -> void:
	_queue_era_indicator_refresh()
	# 年度产值账本必须在面板关闭时也继续累计，否则中途打开会缺少年初到此刻的流量。
	# sample() 自带 sample_day 去重与墙钟合流，重复调用无额外开销。
	_gdp_ledger.sample(int(_world_clock.day_index()) if _world_clock != null else -1)
	# 国库收支序列与产值账本同一节拍：面板关闭时也要连续，否则中途打开只有一点。
	if _country_view_model != null:
		_country_view_model.sample_fiscal_history()
	if _country_panel != null and _country_panel.is_panel_open() \
			and _country_panel.current_section() == "economy":
		_mark_country_panel_dirty(COUNTRY_DIRTY_ECONOMY, "economy_day")
	# Ideology points accrue daily and, under worker authority, arrive through
	# snapshot write-back without a command receipt. Invalidate the cached
	# section every day so reopening never shows a stale point scroll.
	elif _country_panel != null and _country_panel.is_panel_open() \
			and _country_panel.current_section() == "ideology":
		_mark_country_panel_dirty(COUNTRY_DIRTY_IDEOLOGY, "ideology_day")
	# 军事快照每日变化（兵力、士气、补给天数、战争分），打开时同样每个已提交日
	# 推进一次；节流仍由 _flush_country_panel_refresh 的墙钟窗口负责。
	elif _country_panel != null and _country_panel.is_panel_open() \
			and _country_panel.current_section() == "military":
		_mark_country_panel_dirty(COUNTRY_DIRTY_MILITARY, "military_day")
	# 外交读的是战争与领地，两者每天都可能变；同样每个已提交日推进一次。
	elif _country_panel != null and _country_panel.is_panel_open() \
			and _country_panel.current_section() == "diplomacy":
		_mark_country_panel_dirty(COUNTRY_DIRTY_DIPLOMACY, "diplomacy_day")
	elif _country_view_model != null:
		_country_view_model.invalidate_cache(COUNTRY_DIRTY_IDEOLOGY)
	# 军务档案也随已提交日推进；合并窗口由 _refresh_military_dossier 负责。
	_refresh_military_dossier()
	# 营造窗口开着时，国库现金、市场库存与仓库每天都会变；节流由这里负责。
	_refresh_building_workspace()
	# 议和窗口开着时，战争分/占领格/对方意愿每天都会变，跟着已提交日重建一次。
	_refresh_peace_window()


func _on_ideology_runtime_settled(_result: Dictionary) -> void:
	_mark_country_panel_dirty(COUNTRY_DIRTY_IDEOLOGY, "ideology_commit")


## 军事命令的下一个游戏日才生效，所以只在日推进时刷新；这里额外在玩家刚下达
## 命令后请求一次，让「已排队」的反馈和面板数值同步。
func _on_military_command_settled(_id: StringName, _result: Dictionary) -> void:
	_mark_country_panel_dirty(COUNTRY_DIRTY_MILITARY, "military_commit")
	# 宣战/议和在军事运行时里落地，外交页的战事与关系必须在同一天跟上。
	_mark_country_panel_dirty(COUNTRY_DIRTY_DIPLOMACY, "military_commit")
	_refresh_peace_window()


## Inspector 军事页签的官营建筑入口：翻成正式命令交给 PlayerController。
## 请求里的 `building` 已经是军事目录里的 dense 建筑序（由视图模型按科技闸门解析），
## 所以这里原样透传，不再把角色名当建筑名送过去。
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
	match section_id:
		"economy":
			return COUNTRY_DIRTY_ECONOMY
		"ideology":
			return COUNTRY_DIRTY_IDEOLOGY
		"military":
			return COUNTRY_DIRTY_MILITARY
		"diplomacy":
			return COUNTRY_DIRTY_DIPLOMACY
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


func set_colonization_route_layer(layer: ColonizationRouteLayer) -> void:
	_colonization_route = layer


func bind_gm_sun_camera(camera: MapCamera) -> void:
	if _gm_sun_camera != null and _gm_sun_camera.view_changed.is_connected(_on_gm_sun_camera_moved):
		_gm_sun_camera.view_changed.disconnect(_on_gm_sun_camera_moved)
	_gm_sun_camera = camera
	if _gm_sun_camera != null and not _gm_sun_camera.view_changed.is_connected(_on_gm_sun_camera_moved):
		_gm_sun_camera.view_changed.connect(_on_gm_sun_camera_moved)


## 悬停卡需要读玩家相机的屏幕→世界换算与平移/缩放状态。
## PlayerGame 在建图前就会调用，所以这里必须容忍 _map 尚未就绪。
func bind_player_camera(camera: MapCamera) -> void:
	_player_camera = camera
	_configure_cell_hover_card()


func _configure_cell_hover_card() -> void:
	if _cell_hover_card == null or _map == null or _cell_hover_view_model == null:
		return
	_cell_hover_card.configure(_map, _player_camera, _hover_hex_size,
		_cell_hover_view_model, _hover_blocked, map_safe_area)


func _on_gm_sun_camera_moved(_world_rect: Rect2, _center: Vector2, _zoom_value: float) -> void:
	_position_gm_sun_handle()


func _ensure_gm_sun_handle() -> void:
	if _gm_sun_handle != null and is_instance_valid(_gm_sun_handle):
		return
	_gm_sun_handle = Button.new()
	_gm_sun_handle.name = "GMTODSunHandle"
	_gm_sun_handle.text = "☀"
	_gm_sun_handle.tooltip_text = "拖动太阳位置"
	_gm_sun_handle.custom_minimum_size = Vector2(38.0, 38.0)
	_gm_sun_handle.size = Vector2(38.0, 38.0)
	_gm_sun_handle.focus_mode = Control.FOCUS_NONE
	_gm_sun_handle.mouse_filter = Control.MOUSE_FILTER_STOP
	_gm_sun_handle.visible = false
	_gm_sun_handle.z_index = 20
	_gm_sun_handle.gui_input.connect(_on_gm_sun_handle_input)
	add_child(_gm_sun_handle)


func _on_gm_tod_preview_changed(_active: bool) -> void:
	_sync_gm_sun_handle()


func _sync_gm_sun_handle() -> void:
	var preview := false
	if _diagnostics_source != null and _diagnostics_source.has_method("get_gm_tod_sun_preview"):
		var state: Variant = _diagnostics_source.call("get_gm_tod_sun_preview")
		if state is Dictionary:
			preview = bool(state.get("preview", false))
	_ensure_gm_sun_handle()
	_gm_sun_handle.visible = preview
	if _gm_sun_handle.visible and not _gm_sun_dragging:
		_position_gm_sun_handle()


func _position_gm_sun_handle() -> void:
	if _gm_sun_handle == null or not _gm_sun_handle.visible:
		return
	if _diagnostics_source == null or not _diagnostics_source.has_method("gm_tod_sun_screen_position"):
		return
	var screen: Vector2 = _diagnostics_source.call("gm_tod_sun_screen_position")
	if not is_finite(screen.x) or not is_finite(screen.y):
		return
	_gm_sun_handle.position = screen - _gm_sun_handle.size * 0.5


func _on_gm_sun_handle_input(event: InputEvent) -> void:
	if _diagnostics_source == null or not _diagnostics_source.has_method("set_gm_tod_sun_preview"):
		return
	if event is InputEventMouseButton:
		var button := event as InputEventMouseButton
		if button.button_index != MOUSE_BUTTON_LEFT:
			return
		_gm_sun_dragging = button.pressed
		if button.pressed:
			_apply_gm_sun_drag(get_viewport().get_mouse_position())
		else:
			_sync_gm_sun_handle()
		_gm_sun_handle.accept_event()
	elif event is InputEventMouseMotion and _gm_sun_dragging:
		_apply_gm_sun_drag(get_viewport().get_mouse_position())
		_gm_sun_handle.accept_event()
	elif event is InputEventScreenTouch:
		var touch := event as InputEventScreenTouch
		_gm_sun_dragging = touch.pressed
		if touch.pressed:
			_apply_gm_sun_drag(touch.position)
		else:
			_sync_gm_sun_handle()
		_gm_sun_handle.accept_event()
	elif event is InputEventScreenDrag and _gm_sun_dragging:
		_apply_gm_sun_drag((event as InputEventScreenDrag).position)
		_gm_sun_handle.accept_event()


func _apply_gm_sun_drag(screen_pos: Vector2) -> void:
	var height := 1.0
	var uv := Vector2(0.25, 0.5)
	if _diagnostics_source.has_method("get_gm_tod_sun_preview"):
		var state: Variant = _diagnostics_source.call("get_gm_tod_sun_preview")
		if state is Dictionary:
			height = float(state.get("height_scale", 1.0))
			var current: Variant = state.get("uv", uv)
			if current is Vector2:
				uv = current
	if _diagnostics_source.has_method("gm_tod_screen_to_sun_uv"):
		uv = _diagnostics_source.call("gm_tod_screen_to_sun_uv", screen_pos)
	_diagnostics_source.call("set_gm_tod_sun_preview", true, uv, height)
	if _gm_sun_handle != null:
		_gm_sun_handle.position = screen_pos - _gm_sun_handle.size * 0.5


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
	if not WebTelemetry.enabled():
		return
	var total := float(Time.get_ticks_usec() - started_usec) / 1000.0
	if total < 200.0:
		return
	WebTelemetry.emit("inspector_daily", {
		"dur": int(total),
		"ran": bool(timing.get("ran", false)),
		"tab": String(timing.get("tab", "")),
		"build_ms": int(float(timing.get("live_patch_build_ms", 0.0))),
		"apply_ms": int(float(timing.get("live_patch_apply_ms", 0.0))),
	})


func refresh_selected_daily_lines(force: bool = false, day_idx: int = -1) -> Dictionary:
	var _t_all := Time.get_ticks_usec()
	var timing: Dictionary = {
		"ran": false,
		"tab": "",
		"live_patch_build_ms": 0.0,
		"live_patch_apply_ms": 0.0,
	}
	if _colonization_panel != null and _colonization_panel.visible:
		_colonization_panel.refresh_visible()
	if _selected_cell == null or _inspector_view_model == null or _right_panel == null:
		_report_inspector_daily_timing(timing, _t_all)
		return timing
	# 视野状态变了意味着页签集合变了，打补丁改不动页签栏，必须整块重建。
	var fog := VisionSolver.fog_state(_map, int(_selected_cell.index))
	if fog != _selected_fog_state:
		_selected_fog_state = fog
		_set_inspector_trace_cell(int(_selected_cell.index) \
			if fog == VisionSolver.FOG_VISIBLE else -1)
		refresh_selected_panel()
		timing["ran"] = true
		_report_inspector_daily_timing(timing, _t_all)
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
		_report_inspector_daily_timing(timing, _t_all)
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
		_report_inspector_daily_timing(timing, _t_all)
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
	_report_inspector_daily_timing(timing, _t_all)
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


func _on_country_committed(report: Dictionary) -> void:
	_queue_era_indicator_refresh()
	# 税务/国库 soft-commit 每天都会推 generation，但通常 0 格领土变更。
	# 以前这里无条件 COUNTRY_DIRTY_ALL + 全量科技定义重建，把 50x 主线程打到 ~90ms。
	var territory_changed := int(report.get("changed_cells", 0)) > 0
	var dirty_families := int(report.get("dirty_families", 0))
	var state_dirty := (dirty_families & NATIVE_DIRTY_COUNTRY_STATE) != 0 \
		or int(report.get("research_watermark", 0)) > 0 \
		or int(report.get("tax_watermark", 0)) > 0
	# 领土变更会改 fog_state，必须强制重建 Inspector；软提交走既有墙钟节流。
	refresh_selected_daily_lines(territory_changed)
	if territory_changed and _selected_cell != null:
		refresh_selected_panel()
	var domains := 0
	if territory_changed or state_dirty \
			or (dirty_families & NATIVE_DIRTY_COUNTRY_TERRITORY) != 0:
		domains |= COUNTRY_DIRTY_ECONOMY
	# 归属变了，「已发现国家」清单、接壤面数与占领格都会变；外交页必须同一瞬间重算，
	# 否则名录会停在上一张地图上。
	if territory_changed or (dirty_families & NATIVE_DIRTY_COUNTRY_TERRITORY) != 0:
		domains |= COUNTRY_DIRTY_DIPLOMACY
	# A worker country commit can advance the published country generation while
	# leaving the legacy dirty-family bits empty.  The technology archive reads
	# that committed research snapshot, so while it is open it must observe every
	# committed country boundary; otherwise the old cached model survives until a
	# technology click forces a direct live snapshot.  Closed or other sections
	# only invalidate the cached technology model (no build), so reopening never
	# presents a model from before the panel was closed.
	var research_committed := int(report.get("generation", report.get("country_generation", 0))) > 0 \
			or int(report.get("changed_countries", 0)) > 0 \
			or state_dirty
	if research_committed:
		domains |= COUNTRY_DIRTY_TECHNOLOGY
	var research_poll := {"states_changed": false, "completed": false}
	if research_committed:
		var now_ms := Time.get_ticks_msec()
		if now_ms >= _next_research_toast_poll_ms:
			_next_research_toast_poll_ms = now_ms + RESEARCH_TOAST_POLL_INTERVAL_MSEC
			research_poll = _poll_research_completion_toasts()
	if bool(research_poll.get("states_changed", false)):
		domains |= COUNTRY_DIRTY_TECHNOLOGY
	elif state_dirty and _country_panel != null and _country_panel.is_panel_open() \
			and String(_country_panel.current_section()) == "technology" \
			and not Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT):
		# Progress-only refresh while the archive is open. Never rebuild during
		# an active click — 50x soft-commits were eating double-click enqueue.
		var progress_now_ms := Time.get_ticks_msec()
		if progress_now_ms >= _next_tech_panel_progress_ms:
			_next_tech_panel_progress_ms = progress_now_ms + \
				RESEARCH_PANEL_PROGRESS_INTERVAL_MSEC
			domains |= COUNTRY_DIRTY_TECHNOLOGY
	if (dirty_families & NATIVE_DIRTY_COUNTRY_VISUAL_ERA) != 0:
		domains |= COUNTRY_DIRTY_IDEOLOGY
	if domains == 0:
		domains = COUNTRY_DIRTY_ECONOMY
	_mark_country_panel_dirty(domains, "country_committed")
	if bool(research_poll.get("completed", false)):
		_refresh_player_discovery_context()


## economy_chapter 非空时直接落到经济卷宗的指定章节（总览 / 阶层民生），
## 顶栏纸签点击走这条路；其它调用方保持原来的「记住上次章节」行为。
func open_country_section(section_id: String, economy_chapter: String = "") -> void:
	if _player_controller != null:
		_player_controller.cancel_military_arm_order()
	if section_id == "annual":
		close_country_panel()
		annual_history_requested.emit()
		return
	# 卷宗一打开就收起时代纸笺：纸笺在面板层之上，留着会浮在压暗的国家卷宗上。
	if _era_panel != null and _era_panel.is_open():
		_close_era_panel()
	if _country_panel == null or _country_view_model == null:
		return
	# 打开国家面板时纸签悬浮卡必须退场：它盖在面板边缘，也没必要再读旧值。
	_status_card_generation += 1
	_status_card_kind = ""
	if _status_card != null:
		_status_card.hide_card(true)
	# Opening a section is an explicit player action and should never inherit a
	# throttle window left by a previously visible section.
	_country_refresh_queued = false
	_country_next_refresh_ms = 0
	_country_refresh_timer_active = false
	_hide_inspector_for_country()
	_country_action_bar.set_active(section_id)
	if section_id == "economy" and not economy_chapter.is_empty() \
			and _country_panel.has_method("focus_economy_chapter"):
		_country_panel.focus_economy_chapter(economy_chapter)
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
	var open_mask := _country_section_mask(section_id)
	var open_interval := COUNTRY_UI_TECH_REFRESH_INTERVAL_MSEC \
		if open_mask == COUNTRY_DIRTY_TECHNOLOGY \
		else COUNTRY_UI_REFRESH_INTERVAL_MSEC
	_country_next_refresh_ms = Time.get_ticks_msec() + open_interval


func _locate_cell_from_country_panel(cell_index: int) -> void:
	close_country_panel()
	if _player_controller == null or _map == null:
		return
	var cell := _map.cell_at(cell_index)
	if cell != null:
		_player_controller.select_cell(cell)


## "A card acts here." Same shape as the single-cell locate above — close the
## panel first, because it is full-bleed and would cover the very hexes we are
## about to paint — but the map side receives a set instead of a selection.
func _on_target_cells_from_country_panel(cells: PackedInt32Array) -> void:
	if _player_controller == null:
		return
	# Dock the shell beside the map instead of closing it. Closing was the old
	# behaviour and it threw away the card the player was reading at the exact
	# moment they asked "where does this act?" — the highlight outlived the
	# panel, but so did the question of which card had painted it.
	if _country_panel != null and _country_panel.is_panel_open():
		_country_panel.set_docked(true)
	_player_controller.highlight_cells(cells)


## 物资详情逐单商路翻页：只更新请求 offset，再走既有对象详情 payload 通道重建。
## ViewModel 按 committed generation 缓存，翻页也是一次有界页查询。
func _on_trade_orders_page_requested(offset: int) -> void:
	if _object_detail_context.is_empty() \
			or String(_object_detail_context.get("kind", "")) != "good":
		return
	var request: Dictionary = _object_detail_context.get("request", {})
	request["orders_offset"] = maxi(0, offset)
	_object_detail_context["request"] = request
	_refresh_object_detail(true)


## 点击逐单行的可见对端：关闭当前详情并选中该地块（与 country panel 定位语义一致）。
func _on_trade_order_locate_requested(cell_index: int) -> void:
	if _player_controller == null or _map == null:
		return
	var cell := _map.cell_at(cell_index)
	if cell == null:
		return
	_close_object_detail_dialog()
	_player_controller.select_cell(cell)


func close_country_panel() -> void:
	_country_open_generation += 1
	_country_refresh_queued = false
	_country_refresh_timer_active = false
	_country_next_refresh_ms = 0
	if _country_panel != null and _country_panel.is_panel_open():
		# Undock before closing: the next open is a full-bleed screen again, and
		# a dock left set would silently shrink it with no way to tell why.
		_country_panel.set_docked(false)
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
	_pending_object_request.clear()
	var category := _inspector_view_model.build_tab_category(_selected_cell, tab_id)
	_right_panel.set_tab_category(tab_id, category)
	_pending_inspector_tab = tab_id if bool(category.get("data_pending", false)) else ""
	if not _pending_inspector_tab.is_empty():
		_schedule_inspector_retry()


func _cancel_inspector_retry() -> void:
	_inspector_retry_generation += 1
	_inspector_retry_queued = false
	_pending_inspector_tab = ""
	_pending_object_request.clear()


func _schedule_inspector_retry() -> void:
	if _inspector_retry_queued or not is_inside_tree():
		return
	_inspector_retry_queued = true
	get_tree().create_timer(0.15).timeout.connect(
		_retry_inspector_reads.bind(_inspector_retry_generation), CONNECT_ONE_SHOT)


func _retry_inspector_reads(generation: int) -> void:
	if generation != _inspector_retry_generation:
		return
	_inspector_retry_queued = false
	if _selected_cell == null or _right_panel == null or not _right_panel.visible:
		_cancel_inspector_retry()
		return
	if not _pending_inspector_tab.is_empty():
		var tab_id := _pending_inspector_tab
		if tab_id == _right_panel.current_tab():
			var category := _inspector_view_model.build_tab_category(_selected_cell, tab_id)
			_right_panel.apply_live_patch({"tab_id": tab_id, "category": category})
			if not bool(category.get("data_pending", false)):
				_pending_inspector_tab = ""
		else:
			_pending_inspector_tab = ""
	if not _pending_object_request.is_empty():
		_on_object_details_requested(_pending_object_request)
	if not _pending_inspector_tab.is_empty() or not _pending_object_request.is_empty():
		_schedule_inspector_retry()


## 营造窗口的一次目录页请求：部门 + 搜索词 + 排序档 + 偏移由窗口自己记，这里只
## 负责让 view model 组一整页模型（整部门报价后排序、再切一页）并推回窗口。
func _on_construction_page_requested(sector: String, search: String,
		sort_id: String, offset: int) -> void:
	if _selected_cell == null or _inspector_view_model == null or _right_panel == null:
		return
	_last_construction_refresh_ms = Time.get_ticks_msec()
	_right_panel.set_construction_model(
		_inspector_view_model.build_construction_model(
			int(_selected_cell.index), sector, search, sort_id, offset))


## 次日结算会改变国库、市场与仓库；只在窗口打开时按墙钟节流重发同一页。
func _refresh_building_workspace(force: bool = false) -> void:
	if _right_panel == null or not _right_panel.building_workspace_open():
		return
	if not force and Time.get_ticks_msec() - _last_construction_refresh_ms \
			< BUILDING_WORKSPACE_REFRESH_MSEC:
		return
	_right_panel.request_construction_refresh()


func _on_construction_requested(request: Dictionary) -> void:
	if _selected_cell == null or _player_controller == null or _right_panel == null:
		push_warning("[construction] click dropped: selected_cell=%s controller=%s right_panel=%s" % [
			str(_selected_cell != null), str(_player_controller != null),
			str(_right_panel != null)])
		return
	# 军事部门的条目带 `military_index`：它是军事目录里的 dense 序，必须走
	# `state.build`（原生 MCMD_STATE_BUILD）。送进经济侧的 construction.build
	# 会因为经济目录里没有这座建筑而被拒。
	if request.has("military_index"):
		_on_military_state_building_requested({
			"cell": int(_selected_cell.index),
			"op": String(request.get("op", "state.build")),
			"building": int(request.get("military_index", -1)),
		})
		return
	var result: Dictionary = _player_controller.request_command(
		&"construction.build", {"cell_idx": int(_selected_cell.index),
			"building_id": StringName(request.get("building_id", &"")),
			"ownership_policy": &"treasury_sponsored_private"})
	print("[construction] click cell=%d id=%s -> ok=%s code=%s message=%s" % [
		int(_selected_cell.index), String(request.get("building_id", &"")),
		str(result.get("ok", false)), str(result.get("code", "")),
		String(result.get("message", result.get("reason", "")))])
	_right_panel.set_construction_feedback(
		String(result.get("message", result.get("reason", "修建命令未能提交。"))),
		bool(result.get("ok", false)))


func _open_colonization_target(target_cell: int, family_handle: int = 0,
		source_cell: int = -1) -> void:
	if _colonization_panel == null:
		return
	_close_object_detail_dialog()
	_suppress_ui_for_dispatch()
	_colonization_panel.open_target(target_cell, family_handle, source_cell)
	if _player_controller != null and _player_controller.has_method("ensure_selected_visible"):
		_player_controller.ensure_selected_visible()


func _on_colonization_requested(request: Dictionary) -> void:
	_open_colonization_target(int(request.get("target_cell", -1)))


func _on_family_colonization_requested(family_handle: int,
		source_cell: int) -> void:
	if _colonization_panel == null:
		return
	_close_object_detail_dialog()
	_suppress_ui_for_dispatch()
	_colonization_panel.open_source(source_cell, family_handle)
	if _player_controller != null and _player_controller.has_method("ensure_selected_visible"):
		_player_controller.ensure_selected_visible()


func _suppress_ui_for_dispatch() -> void:
	if _dispatch_ui_suppressed:
		return
	_dispatch_ui_suppressed = true
	_dispatch_previous_inspector_visible = _right_panel != null and _right_panel.visible
	_dispatch_previous_toolbar_visible = _map_overlay_toolbar != null and _map_overlay_toolbar.visible
	if _right_panel != null:
		_right_panel.hide()
	if _map_overlay_toolbar != null:
		_map_overlay_toolbar.hide()


func _on_dispatch_closed() -> void:
	_colonization_targeting.clear()
	if not _dispatch_ui_suppressed:
		return
	_dispatch_ui_suppressed = false
	if _right_panel != null:
		_right_panel.visible = _dispatch_previous_inspector_visible
	if _map_overlay_toolbar != null:
		_map_overlay_toolbar.visible = _dispatch_previous_toolbar_visible
	if _dispatch_previous_inspector_visible and _player_controller != null \
			and _player_controller.has_method("selected_cell"):
		var cell = _player_controller.selected_cell()
		if cell != null:
			show_cell_panel(cell)


# ── peace window (MilitaryPeaceWindow) ──────────────────────────────────

## Open the dedicated peace window for one war. The country shell is full-bleed,
## so it has to close first — the whole point of this window is the map behind it.
func open_military_peace(war_id: int) -> void:
	if _peace_window == null or _country_view_model == null:
		return
	if int(war_id) <= 0:
		return
	if _country_panel != null and _country_panel.is_panel_open():
		close_country_panel()
	if _colonization_panel != null and _colonization_panel.visible:
		_colonization_panel.close_panel()
	_colonization_targeting.clear()
	_suppress_ui_for_dispatch()
	# The window is the only consumer here, so one fresh military model is enough.
	_country_view_model.invalidate_cache(COUNTRY_DIRTY_MILITARY)
	_peace_window.set_player_controller(_player_controller)
	_peace_window.open(int(war_id), _country_view_model.build("military"))
	var focus_cell := _peace_focus_cell()
	if focus_cell >= 0 and _player_controller != null \
			and _player_controller.has_method("focus_map_cell"):
		_player_controller.call("focus_map_cell", focus_cell)


func close_military_peace() -> void:
	if _peace_window != null:
		_peace_window.close_panel()


func is_peace_window_open() -> bool:
	return _peace_window != null and bool(_peace_window.is_open())


## Map click entry: true means the window consumed it (a cession toggle or a
## "you cannot cede this" note), false only when no window is open.
func handle_peace_map_cell(cell: int) -> bool:
	if not is_peace_window_open():
		return false
	return bool(_peace_window.handle_map_cell(int(cell)))


func _peace_focus_cell() -> int:
	if _peace_window == null:
		return -1
	var candidates: PackedInt32Array = _peace_window.candidate_cells()
	return int(candidates[0]) if not candidates.is_empty() else -1


func _on_peace_window_closed() -> void:
	# No clear_selection_requested() here: the window never moved the selection
	# (it eats map clicks), so closing it must hand the inspector back exactly as
	# the player left it.
	_on_dispatch_closed()


func _on_peace_submit_requested(payload: Dictionary) -> void:
	if _player_controller == null or _peace_window == null:
		return
	var result: Dictionary = _player_controller.request_command(
		PlayerControllerScript.COMMAND_MILITARY_PEACE_PROPOSE, {
			"war_id": int(payload.get("war_id", 0)),
			"terms": payload.get("terms", []),
		})
	_peace_window.set_command_result(result)


func _on_peace_locate_requested(cell: int) -> void:
	if _player_controller != null and _player_controller.has_method("focus_map_cell"):
		_player_controller.call("focus_map_cell", int(cell))


func _refresh_peace_window() -> void:
	if not is_peace_window_open() or _country_view_model == null or _peace_window == null:
		return
	_country_view_model.invalidate_cache(COUNTRY_DIRTY_MILITARY)
	_peace_window.refresh_model(_country_view_model.build("military"))


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


func _play_progression_cue(cue: StringName) -> void:
	var audio := get_node_or_null("/root/GameAudio")
	if audio != null:
		audio.play_event_cue(cue)


func _on_player_command_completed_audio(id: StringName, result: Dictionary) -> void:
	if not bool(result.get("ok", false)):
		return
	# 入队与抽牌先反馈已接受的操作，装备/晋升则等待权威结算成功。
	var cues := {&"research.enqueue": &"tech_start", &"research.remove": &"tech_cancel",
		&"ideology.offer": &"ideology_draw", &"ideology.reroll": &"ideology_reroll",
		&"ideology.choose": &"ideology_choose"}
	if cues.has(id):
		_play_progression_cue(cues[id])


func _on_player_command_settled(id: StringName, result: Dictionary) -> void:
	if bool(result.get("ok", false)):
		var cues := {&"ideology.equip": &"ideology_use",
			&"ideology.unequip": &"ideology_unequip", &"ideology.promote": &"ideology_promote"}
		if cues.has(id):
			_play_progression_cue(cues[id])
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
	# 结算花掉了国库物资/现金，窗口里的报价与按钮态必须立刻跟着变。
	_refresh_building_workspace(true)
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
	if bool(payload.get("data_pending", false)):
		_pending_object_request = request.duplicate(true)
		_schedule_inspector_retry()
		return
	_pending_object_request = {}
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
	call_deferred("_layout_right_panel")


func _close_object_detail_dialog() -> void:
	_pending_object_request.clear()
	_object_detail_context = {}
	if _right_panel != null:
		_right_panel.close_detail(false)
		call_deferred("_layout_right_panel")


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
	_last_object_detail_ms = now_ms
	if bool(payload.get("data_pending", false)):
		return
	if payload.is_empty():
		_close_object_detail_dialog()
		return
	if is_family:
		_right_panel.refresh_family_workspace(payload)
	else:
		_right_panel.refresh_object_detail(payload)


## ── 军务档案（右栏部队 / 战线页）──────────────────────────────────────────
## 拾取在地图层、格式在 MilitaryViewModel；这里只负责开合、定位、动作转发与
## 每日合并刷新。它和对象详情共用 DetailShell，所以面板变宽/目录列都由既有的
## _layout_right_panel() 与 InspectorPanel._sync_split_layout() 决定。

func open_military_dossier(kind: String, id: int, cell: int = -1) -> bool:
	if _right_panel == null or _player_controller == null or kind.is_empty() or id == 0:
		return false
	if kind == "army" and cell < 0 and _player_controller.has_method("military_army_cell"):
		cell = int(_player_controller.call("military_army_cell", id))
	var payload := _military_dossier_payload(kind, id, cell)
	if payload.is_empty():
		return false
	# 重选同一支部队保留档案、滚动位置和选点草稿；关闭交给 × / Esc。
	if _right_panel.military_dossier_open() \
			and _right_panel.military_dossier_identity() == String(payload.get("identity", "")):
		if kind != "army":
			close_military_dossier()
		return true
	_player_controller.cancel_military_arm_order()
	var was_visible := _right_panel.visible
	UIAnimation.cancel(_right_panel)
	_military_dossier_context = {"kind": kind, "id": id, "cell": cell}
	_last_military_dossier_ms = Time.get_ticks_msec()
	_military_dossier_pending = false
	_right_panel.set_directory_available(kind != "army" and _selected_cell != null)
	# 只开军务档案、没有地块档案时，面板本身也要出现。
	if not _right_panel.visible:
		_right_panel.visible = true
	_right_panel.show_military_dossier(payload)
	_layout_right_panel()
	UIAnimation.refresh_rest_position(_right_panel)
	if not was_visible:
		UIAnimation.fade_slide_in(_right_panel, Vector2(24.0, 0.0), UITokens.ANIM_MED)
	update_military_arm_order(_player_controller.military_arm_order())
	var focus := int(payload.get("focus_cell", -1))
	if focus >= 0 and _player_controller.has_method("focus_cell"):
		_player_controller.call("focus_cell", focus)
	return true


func close_military_dossier() -> void:
	var was_open := _right_panel != null and _right_panel.military_dossier_open()
	# 每次点格都会走到这里：什么都没开时直接返回，别为一次选格多付一次原生调用。
	if not was_open and _military_dossier_context.is_empty():
		return
	if _player_controller != null:
		_player_controller.cancel_military_arm_order()
	_military_dossier_context.clear()
	_military_dossier_pending = false
	if _right_panel != null:
		_right_panel.set_directory_available(true)
		if was_open:
			_right_panel.close_detail(false)
	if _player_controller != null \
			and _player_controller.has_method("clear_military_map_selection"):
		_player_controller.call("clear_military_map_selection")
	# 没有地块档案可回落时，面板本身也该收起。
	if was_open and _selected_cell == null:
		hide_cell_panel()


func military_dossier_open() -> bool:
	return _right_panel != null and _right_panel.military_dossier_open()


func _military_dossier_payload(kind: String, id: int, cell: int = -1) -> Dictionary:
	var vm := _military_view_model()
	if vm == null:
		return {}
	if kind == "army":
		var same_cell: Array = []
		# 行军后同格名录跟随部队当前位置，不继续展示开页时的旧驻地。
		if _player_controller.has_method("military_army_cell"):
			var current_cell := int(_player_controller.call("military_army_cell", id))
			if current_cell >= 0:
				cell = current_cell
		if cell >= 0 and _player_controller != null \
				and _player_controller.has_method("military_armies_at_cell"):
			same_cell = _player_controller.call("military_armies_at_cell", cell)
		return vm.army_dossier(id, same_cell)
	if kind == "front":
		if _player_controller == null \
				or not _player_controller.has_method("military_front_sector"):
			return {}
		var sector: Dictionary = _player_controller.call("military_front_sector", id)
		if sector.is_empty():
			return {}
		return vm.front_dossier(sector)
	return {}


## 每次开页/刷新建一个 view model：configure 只拷字典，真正的查询在
## build_military_model（O(armies)，走 200ms 合并窗口）与 facade.army（单支部队）。
func _military_view_model() -> MilitaryViewModel:
	if _country_view_model == null or _player_controller == null:
		return null
	var handle := int(_player_controller.get_player_country_handle())
	if handle == 0:
		return null
	var context: Dictionary = _country_view_model.military_dossier_context(handle)
	context["current_day"] = int(_world_clock.day_index()) if _world_clock != null else -1
	context["player_controller"] = _player_controller
	var vm := MilitaryViewModel.new()
	vm.configure(context)
	if not vm.available():
		return null
	return vm


func _refresh_military_dossier(force: bool = false) -> void:
	if _military_dossier_context.is_empty() or _right_panel == null \
			or not _right_panel.military_dossier_open():
		return
	var now := Time.get_ticks_msec()
	if not force and now - _last_military_dossier_ms < MILITARY_DOSSIER_REFRESH_INTERVAL_MSEC:
		_military_dossier_pending = true
		_arm_military_dossier_timer()
		return
	_last_military_dossier_ms = now
	_military_dossier_pending = false
	var payload := _military_dossier_payload(
		String(_military_dossier_context.get("kind", "")),
		int(_military_dossier_context.get("id", 0)),
		int(_military_dossier_context.get("cell", -1)))
	if payload.is_empty():
		close_military_dossier()
		return
	_right_panel.refresh_military_dossier(payload)


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
		&"move", &"area":
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
	if action != &"move" and action != &"area" or not bool(result.get("ok", false)):
		_right_panel.set_military_dossier_feedback(
			String(result.get("message", "命令已下达，等待执行。")), bool(result.get("ok", false)))


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
	var safe := _base_map_safe_area()
	if _peace_window != null and _peace_window.visible:
		# The peace window docks left, so the camera may not frame a target under it.
		var peace_edge: float = _peace_window.get_global_rect().end.x + UITokens.SPACE_MD
		var peace_inset: float = clampf(peace_edge - safe.position.x, 0.0,
			maxf(safe.size.x - 1.0, 0.0))
		safe.position.x += peace_inset
		safe.size.x -= peace_inset
	if _colonization_panel != null and _colonization_panel.visible:
		var edge := _colonization_panel.get_global_rect().end.x + UITokens.SPACE_MD
		var inset := clampf(edge - safe.position.x, 0.0, maxf(safe.size.x - 1.0, 0.0))
		safe.position.x += inset
		safe.size.x -= inset
	if _family_founding_dialog != null:
		var occupied_edge := _family_founding_dialog.map_reserved_right_edge()
		if occupied_edge > safe.position.x:
			var inset := minf(occupied_edge + UITokens.SPACE_MD - safe.position.x,
				maxf(safe.size.x - 1.0, 0.0))
			safe.position.x += inset
			safe.size.x -= inset
	return safe


## 刘海/挖孔/圆角：把整棵 UI（UIRoot 及其下 HUDLayer/PanelLayer/ModalLayer）整体内缩。
## 安全区来自 DisplayServer.get_display_safe_area()，MobileUIScaling 已换算成设计像素；
## 桌面/Web 上恒为 0，因此这里对桌面是完全的 no-op。地图（Node2D）不内缩——
## 让地图继续铺满全屏、只把可点控件避让开，是廉价且不会出现黑边的做法。
func _apply_ui_safe_area() -> void:
	var ui_root := get_node_or_null("UIRoot") as Control
	if ui_root == null:
		return
	var insets := {"left": 0.0, "top": 0.0, "right": 0.0, "bottom": 0.0}
	var settings := get_node_or_null("/root/GameSettings")
	if settings != null and settings.has_method("ui_scaling"):
		var scaling = settings.call("ui_scaling")
		if scaling != null:
			insets = scaling.call("safe_insets")
	ui_root.offset_left = float(insets.get("left", 0.0))
	ui_root.offset_top = float(insets.get("top", 0.0))
	ui_root.offset_right = -float(insets.get("right", 0.0))
	ui_root.offset_bottom = -float(insets.get("bottom", 0.0))


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
	var viewport_size := get_viewport().get_visible_rect().size
	var top_height := PlayerTopBar.BAR_HEIGHT + 4.0
	if _top_bar != null and _top_bar.size.y > 0.0:
		top_height = _top_bar.size.y + 4.0
	var right_width := 0.0
	if _right_panel != null and _right_panel.visible:
		right_width = (_right_panel.size.x if _right_panel.size.x > 0.0 else RIGHT_PANEL_WIDTH) \
			+ UITokens.ARCHIVE_EDGE_INSET + UITokens.SPACE_MD
	var left_width := _map_overlay_toolbar.primary_safe_width() \
		if _map_overlay_toolbar != null else 0.0
	var bottom_height := CountryActionBar.BAR_HEIGHT + UITokens.ARCHIVE_EDGE_INSET
	return Rect2(
		Vector2(left_width, top_height),
		Vector2(
			maxf(viewport_size.x - right_width - left_width, 1.0),
			maxf(viewport_size.y - top_height - bottom_height, 1.0)
		)
	)


func dismiss_overlay_menu() -> bool:
	if _player_controller != null and not String(
			_player_controller.military_arm_order().get("mode", "")).is_empty():
		_player_controller.cancel_military_arm_order()
		return true
	if _status_card != null and _status_card.is_open():
		_status_card_generation += 1
		_status_card_kind = ""
		_status_card.hide_card(true)
		return true
	if is_era_ceremony_playing():
		_era_ceremony.skip()
		return true
	if is_annual_report_open():
		_annual_report_workspace.call("_close")
		return true
	if _era_reward_dialog != null and _era_reward_dialog.visible:
		_on_era_popup_dismissed()
		return true
	if _era_panel != null and _era_panel.is_open():
		_close_era_panel()
		return true
	if is_family_founding_modal_open():
		if _right_panel != null and _right_panel.detail_open():
			_right_panel.close_detail()
			return true
		if _family_founding_dialog != null:
			_family_founding_dialog.toggle_collapsed()
		return true
	if _colonization_panel != null and (_colonization_panel.is_source_picking() \
			or _colonization_panel.is_target_picking()):
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
		if _right_panel.detail_open():
			_right_panel.close_detail()
			return true
		clear_selection_requested.emit()
		return true
	return false


func toggle_pause_menu() -> void:
	if _player_controller != null:
		_player_controller.cancel_military_arm_order()
	if _pause_menu != null and not is_era_reward_modal_open() \
			and not is_family_founding_modal_open():
		_pause_menu.toggle()


func show_era_reward_offer(offer: Dictionary) -> void:
	if _era_reward_dialog != null:
		if _era_panel != null and _era_panel.visible:
			_era_panel.close(true)
		if not _era_reward_dialog.visible:
			_era_reward_dialog.open_overview(_build_era_overview())
		_era_reward_dialog.present_offer(offer)
		if _era_indicator != null:
			_era_indicator.set_expanded(true)


func _build_era_overview() -> Dictionary:
	if _player_controller == null:
		return {}
	if _era_indicator_view_model == null:
		_era_indicator_view_model = EraIndicatorViewModel.new()
	return _era_indicator_view_model.build_overview(
		_player_controller.get_country_facade(), _player_controller.get_economy_facade(),
		int(_player_controller.get_player_country_handle()), _gdp_ledger)


## 纸徽点击：打开「国家概况 + 时代晋升」合并速览（一张纸笺、无页签、无滚动）。
## 待领时代奖励时，速览左栏出现「领取时代奖励」按钮；三张奖励纸片仍走 EraRewardDialog 原流程。
## 奖励弹窗已展开时，点击维持原有的开关语义。
func _on_era_indicator_pressed() -> void:
	if is_annual_report_open() or is_family_founding_modal_open() or is_era_ceremony_playing():
		return
	if _era_reward_dialog != null and _era_reward_dialog.visible:
		_on_era_popup_dismissed()
		return
	_ensure_era_panel()
	if _era_panel == null:
		return
	if _era_panel.is_open():
		_close_era_panel()
		return
	_era_panel.set_reward_available(String(_era_offer.get("status", "NONE")) in ["OPEN", "ERROR"])
	_era_panel.open(_era_advancement_model(), _build_era_overview())
	if _era_indicator != null:
		_era_indicator.set_expanded(_era_panel.wants_expanded_badge())


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


func _bind_era_panel() -> void:
	_era_panel.close_requested.connect(_close_era_panel)
	_era_panel.command_requested.connect(_on_era_panel_command)
	_era_panel.treasury_requested.connect(func() -> void:
		_close_era_panel()
		open_country_section("economy", "overview"))
	_era_panel.reward_requested.connect(func() -> void:
		era_reward_open_requested.emit())


func _close_era_panel() -> void:
	if _era_panel != null:
		_era_panel.close()
	if _era_indicator != null and (_era_reward_dialog == null or not _era_reward_dialog.visible):
		_era_indicator.set_expanded(false)


func is_era_panel_open() -> bool:
	return _era_panel != null and _era_panel.is_open()


func _on_era_panel_command(command: StringName) -> void:
	var result: Dictionary = {"ok": false, "code": "controller_unavailable",
		"message": "玩家会话尚未就绪"}
	if _player_controller != null and _player_controller.has_method("request_command"):
		result = _player_controller.request_command(command, {})
	if _era_panel != null:
		_era_panel.show_command_result(result)
	_apply_era_advancement(_era_advancement_model(true))


## 快照只来自 PlayerController（§5）；控制器尚未提供时返回 ok=false，面板显示不可用。
func _era_advancement_model(fresh: bool = false) -> Dictionary:
	if (fresh or _era_advancement_snapshot.is_empty()) and _player_controller != null \
			and _player_controller.has_method("get_era_advancement_snapshot"):
		var snapshot = _player_controller.get_era_advancement_snapshot()
		if snapshot is Dictionary:
			_era_advancement_snapshot = snapshot
	return _era_advancement_snapshot


func _on_era_advancement_changed(snapshot: Dictionary) -> void:
	_era_advancement_snapshot = snapshot
	_apply_era_advancement(snapshot)


func _apply_era_advancement(snapshot: Dictionary) -> void:
	if snapshot.is_empty():
		return
	if _era_indicator != null:
		_era_indicator.set_advancement(String(snapshot.get("status", "")) \
			if bool(snapshot.get("ok", false)) else "", float(snapshot.get("progress", 0.0)))
	if _era_panel != null and _era_panel.visible:
		_era_panel.set_snapshot(snapshot)


func _on_era_popup_dismissed() -> void:
	if _era_reward_dialog.is_offer_open():
		era_reward_dismiss_requested.emit()
		# 已提交事务的控制器拒绝关闭，继续等待 ACK。
		if _era_reward_dialog.is_offer_open():
			return
	_era_reward_dialog.close_overview()
	if _era_indicator != null:
		_era_indicator.set_expanded(false)


# Availability never opens a modal; the native offer remains the sole authority.
func notify_era_reward_offer(offer: Dictionary) -> void:
	_era_offer = offer
	if _era_indicator != null:
		_era_indicator.set_offer_available(String(offer.get("status", "NONE")) in ["OPEN", "ERROR"])
	if _era_panel != null:
		_era_panel.set_reward_available(String(offer.get("status", "NONE")) in ["OPEN", "ERROR"])
	_queue_era_indicator_refresh()


func _queue_era_indicator_refresh() -> void:
	if _era_refresh_queued or not is_inside_tree():
		return
	_era_refresh_queued = true
	get_tree().create_timer(0.10).timeout.connect(func() -> void:
		_era_refresh_queued = false
		_refresh_era_indicator())


func _refresh_era_indicator() -> void:
	if _era_indicator == null or _player_controller == null:
		return
	var facade = _player_controller.get_country_facade()
	var handle := int(_player_controller.get_player_country_handle())
	if facade == null or handle == 0:
		if _top_bar != null:
			_top_bar.set_country_status(0.0, false, 0, false)
		return
	_refresh_player_country_status(facade, _player_controller.get_economy_facade(), handle)
	if _era_indicator_view_model == null:
		_era_indicator_view_model = EraIndicatorViewModel.new()
	var model := _era_indicator_view_model.build(facade.research_snapshot(handle))
	if not model.is_empty() and _era_celebrated_index < 0:
		# 读档/新世界后的第一份模型只建立基线，任何时候都不重播旧的晋升。
		_era_celebrated_index = int(model.era_index)
	_era_indicator.set_model(model)
	if not model.is_empty() and _era_transfer_name.is_empty() and _top_bar != null \
			and not _era_indicator.has_pending_era():
		_top_bar.set_era_name(String(model.era_name))
	_apply_era_advancement(_era_advancement_model(true))
	if _era_panel != null and _era_panel.visible:
		_era_panel.set_overview(_build_era_overview())
	if _era_reward_dialog != null and _era_reward_dialog.visible:
		_era_reward_dialog.refresh_overview(_build_era_overview())


func _refresh_player_country_status(country_facade, economy_facade, handle: int) -> void:
	if _top_bar == null:
		return
	var treasury: Dictionary = country_facade.treasury_snapshot(handle) \
		if country_facade != null and country_facade.has_method("treasury_snapshot") else {}
	var economy: Dictionary = economy_facade.country_economy_overview(handle, "summary") \
		if economy_facade != null and economy_facade.has_method("country_economy_overview") else {}
	var cash_valid := bool(treasury.get("ok", false)) and treasury.has("cash")
	var population_valid := bool(economy.get("ok", false)) and economy.has("population")
	_top_bar.set_country_status(
		float(treasury.get("cash", 0)), cash_valid,
		int(economy.get("population", 0)), population_valid)
	_refresh_status_card()


# ── 顶栏纸签悬浮卡：国库看当日收支，人口看阶层构成 ──────────────────────
## hover 先延迟再查询：指针扫过顶栏时不会连发原生 professions 查询；
## 移开时同样延迟收卡，避免纸签之间来回移动导致卡片闪烁。
## 点击纸签直接进入对应章节，卡片立即收掉。
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
	if TouchUI.is_touch() and _status_card != null and _top_bar != null:
		if not _status_card.is_open() or _status_card_kind != kind:
			var model := _build_status_card_model(kind)
			if not model.is_empty():
				_status_card_generation += 1
				_status_card_kind = kind
				_status_card_next_refresh_ms = Time.get_ticks_msec() + STATUS_CARD_REFRESH_MSEC
				_status_card.show_card(model, _top_bar.status_anchor(kind))
				return
	_status_card_generation += 1
	_status_card_kind = ""
	if _status_card != null:
		_status_card.hide_card(true)
	open_country_section("economy", "overview" if kind == "treasury" else "strata")


## 悬浮期间读数会随日结算变化：只在卡还开着时按节流重填，不重播入场。
func _refresh_status_card() -> void:
	if _status_card == null or _status_card_kind.is_empty() or not _status_card.is_open():
		return
	var now := Time.get_ticks_msec()
	if now < _status_card_next_refresh_ms:
		return
	_status_card_next_refresh_ms = now + STATUS_CARD_REFRESH_MSEC
	_status_card.refresh_card(_build_status_card_model(_status_card_kind))


func _build_status_card_model(kind: String) -> Dictionary:
	if _player_controller == null:
		return {}
	var handle := int(_player_controller.get_player_country_handle())
	if handle == 0:
		return {}
	var country_facade = _player_controller.get_country_facade()
	var economy_facade = _player_controller.get_economy_facade()
	if kind == "treasury":
		var treasury: Dictionary = country_facade.treasury_snapshot(handle) \
			if country_facade != null and country_facade.has_method("treasury_snapshot") else {}
		var fiscal: Dictionary = country_facade.fiscal_snapshot(handle) \
			if country_facade != null and country_facade.has_method("fiscal_snapshot") else {}
		var cash_valid := bool(treasury.get("ok", false)) and treasury.has("cash")
		return HudStatusViewModel.build_treasury(
			cash_valid, int(treasury.get("cash", 0)), fiscal)
	if economy_facade == null or not economy_facade.has_method("country_economy_overview"):
		return HudStatusViewModel.build_population({}, {})
	var professions: Dictionary = economy_facade.country_economy_overview(
		handle, "professions")
	var summary: Dictionary = economy_facade.country_economy_overview(handle, "summary")
	return HudStatusViewModel.build_population(professions, summary)


## 纸徽检测到会话内时代上升（已提交快照，读档首帧只建立基线不会走到这里）。
## 由大典接管：纸徽保留旧图标，大典的新徽记飞回后才换图、闪光并把光点送到日历。
func _on_era_indicator_advanced(model: Dictionary) -> void:
	var new_index := int(model.get("era_index", -1))
	if new_index > _era_celebrated_index:
		var old_index := _era_celebrated_index if _era_celebrated_index >= 0 else new_index - 1
		_start_era_ceremony(old_index, new_index, _ceremony_buffs_from_snapshot(new_index))
		return
	# 大典已由 PlayerController.era_advanced 先行开播：等它落地再换图；已经落地则只补换图。
	if not is_era_ceremony_playing() and _era_indicator != null:
		_era_indicator.reveal_pending_era(false)


## PlayerController.era_advanced（玩家晋升服务观察到时代 ACK）：携带权威加成文案。
func _on_player_era_advanced(old_index: int, new_index: int, buffs: PackedStringArray) -> void:
	if new_index <= _era_celebrated_index:
		if is_era_ceremony_playing() and _era_ceremony_index == new_index and not buffs.is_empty():
			_era_ceremony.set_buffs(buffs)
		return
	if _era_celebrated_index < 0:
		# 尚未建立基线（会话刚绑定）：视为恢复，不演出。
		_era_celebrated_index = new_index
		return
	_start_era_ceremony(maxi(old_index, _era_celebrated_index), new_index, buffs)


func _ceremony_buffs_from_snapshot(new_index: int) -> PackedStringArray:
	# 晋升前最后一份快照的 buffs_preview 正是这次获得的加成。
	var snapshot := _era_advancement_snapshot
	if int(snapshot.get("next_era_index", -2)) == new_index:
		return PackedStringArray(snapshot.get("buffs_preview", PackedStringArray()))
	return PackedStringArray()


func is_era_ceremony_playing() -> bool:
	return _era_ceremony != null and is_instance_valid(_era_ceremony) and _era_ceremony.is_playing()


func _start_era_ceremony(old_index: int, new_index: int, buffs: PackedStringArray) -> void:
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


func _on_era_ceremony_landed(new_index: int) -> void:
	if new_index != _era_ceremony_index:
		return
	_land_era_on_badge(_era_ceremony_landed_name)


## 新徽记落到纸徽：换图 + 金环礼花，光点飞向日历换字，并补一条晋升纸贴。
func _land_era_on_badge(era_name: String) -> void:
	if _era_indicator != null:
		# 纸徽未被大典接管（无 defer）时它已自行放过礼花，这里不再重放。
		_era_indicator.reveal_pending_era(_era_indicator.has_pending_era() \
			or _era_indicator.defer_celebration)
	if not era_name.is_empty():
		_era_transfer_name = era_name
	if _era_flight != null and _top_bar != null and _era_indicator != null:
		_era_flight.play(_era_indicator.icon_origin(), _top_bar.era_name_target())
	elif _top_bar != null and not _era_transfer_name.is_empty():
		_on_era_flight_landed()
	if _era_indicator_view_model == null:
		_era_indicator_view_model = EraIndicatorViewModel.new()
	_notify_era_promoted({"era_id": _era_indicator_view_model.era_id_for(_era_celebrated_index),
		"era_name": era_name})


func _on_era_ceremony_finished() -> void:
	# 兜底：跳过 / 中断 / landed 索引不匹配时，也要把纸徽对齐到当前时代。
	if _era_indicator != null:
		_era_indicator.reveal_pending_era(false)
	_era_ceremony = null
	_era_ceremony_index = -1
	_restore_clock_after_ceremony()


func _abort_era_ceremony() -> void:
	if _era_ceremony != null and is_instance_valid(_era_ceremony):
		_era_ceremony.abort()
	_era_ceremony = null
	_era_ceremony_index = -1
	# 世界已切换：不恢复旧世界的时钟状态。
	_era_ceremony_resume_clock = false


## 大典期间暂停时钟（同时代奖励/家族创立的做法），只在由大典暂停时才恢复。
func _pause_clock_for_ceremony() -> void:
	if _world_clock == null or _era_ceremony_resume_clock:
		return
	if _world_clock.paused:
		return
	_era_ceremony_resume_clock = true
	_world_clock.pause(true)
	if _player_controller != null and _player_controller.has_method("sync_ui"):
		_player_controller.sync_ui()


func _restore_clock_after_ceremony() -> void:
	if not _era_ceremony_resume_clock:
		return
	_era_ceremony_resume_clock = false
	if _world_clock == null or not _world_clock.paused:
		return
	# 演出期间若有其他流程接管时钟（时代奖励选择、暂停菜单），交还给它们。
	if _pause_menu != null and _pause_menu.visible:
		return
	if is_era_reward_modal_open() or is_family_founding_modal_open() or is_annual_report_open():
		return
	if _player_controller != null and _player_controller.has_method("era_reward_locked") \
			and bool(_player_controller.era_reward_locked()):
		return
	if _player_controller != null and _player_controller.has_method("ideology_draw_locked") \
			and bool(_player_controller.ideology_draw_locked()):
		return
	_world_clock.pause(false)
	if _player_controller != null and _player_controller.has_method("sync_ui"):
		_player_controller.sync_ui()


## 时代晋升是必须被看见的一刻：徽记特效、顶栏日历换字和纸贴提醒三件事同时发生。
## 玩家通常正泡在科技面板里等里程碑完成，所以纸贴和徽记都走面板遮罩之上。
func _notify_era_promoted(model: Dictionary) -> void:
	var era_id := String(model.get("era_id", ""))
	if era_id.is_empty():
		return
	_ensure_research_toast()
	if _research_toast == null:
		return
	_research_toast.show_era_promoted(era_id, String(model.get("era_name", "")),
		String(_era_offer.get("status", "NONE")) in ["OPEN", "ERROR"])


func _on_era_flight_landed() -> void:
	if _top_bar != null and not _era_transfer_name.is_empty():
		_top_bar.set_era_name(_era_transfer_name, true)
	_era_transfer_name = ""


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


func show_family_founding_offer(offer: Dictionary) -> void:
	if _country_panel != null and _country_panel.is_panel_open():
		close_country_panel()
	if _colonization_panel != null and _colonization_panel.visible:
		_colonization_panel.close_panel()
	if _family_founding_dialog != null:
		_layout_family_founding_dialog()
		_family_founding_dialog.present_offer(offer)
		_layout_family_founding_dialog()
		if _player_controller != null:
			_player_controller.ensure_selected_visible()


func show_family_founding_error(message: String) -> void:
	if _family_founding_dialog != null and _family_founding_dialog.is_offer_open():
		_family_founding_dialog.show_error(message)


func close_family_founding_offer() -> void:
	if _family_founding_dialog != null:
		_family_founding_dialog.close_offer()


func is_family_founding_modal_open() -> bool:
	return _family_founding_dialog != null and _family_founding_dialog.is_offer_open()


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
	if _discovery_tech_ids_ready and technology_ids == _last_discovery_tech_ids:
		return
	_last_discovery_tech_ids = technology_ids.duplicate()
	_discovery_tech_ids_ready = true
	set_resource_discovery_context(technology_ids, true)


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
	if _cell_hover_card != null:
		return
	var hud := get_node_or_null("UIRoot/HUDLayer") as Control
	if hud == null:
		return
	var card := CellHoverCardScene.instantiate() as CellHoverCard
	if card == null:
		return
	card.name = "CellHoverCard"
	card.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hud.add_child(card)
	_cell_hover_card = card
	_configure_cell_hover_card()


## 悬停卡的抑制策略集中在这里：任何"地图不该被打扰"的状态都返回 true。
func _hover_blocked() -> bool:
	var situations := get_node_or_null("UIRoot/HUDLayer/CellSituationLayer")
	if situations != null and situations.is_icon_hovered():
		return true
	if _map == null or _inspector_view_model == null or _player_camera == null:
		return true
	if _loading_overlay != null and _loading_overlay.visible:
		return true
	if _right_panel != null and _right_panel.visible:
		return true
	if _country_panel != null and _country_panel.is_panel_open():
		return true
	if _pause_menu != null and _pause_menu.visible:
		return true
	if is_era_reward_modal_open() or is_family_founding_modal_open() or is_narrative_event_modal_open():
		return true
	if is_era_panel_open() or is_era_ceremony_playing():
		return true
	if _colonization_panel != null and _colonization_panel.visible:
		return true
	if bool(_colonization_targeting.get("active", false)):
		return true
	if is_peace_window_open():
		return true
	if _gm_console != null and _gm_console.is_panel_open():
		return true
	return false


func _locate_cell_from_family_founding(cell_index: int) -> void:
	if _country_panel != null and _country_panel.is_panel_open():
		close_country_panel()
	if _player_controller != null and _player_controller.has_method(
			"focus_family_founding_cell"):
		_player_controller.focus_family_founding_cell(cell_index)
	elif _player_controller != null and _map != null and cell_index >= 0:
		var cell := _map.cell_at(cell_index)
		if cell != null:
			_player_controller.select_cell(cell)
	_layout_family_founding_dialog()


func _layout_family_founding_dialog() -> void:
	if _family_founding_dialog == null:
		return
	_family_founding_dialog.set_inspector_obscures(
		_right_panel != null and _right_panel.visible and _right_panel.detail_open())
	# The dossier is placed against HUD bounds; camera bounds additionally exclude it.
	_family_founding_dialog.set_safe_area(_base_map_safe_area())


func _on_founding_collapsed_changed(collapsed: bool) -> void:
	_layout_country_action_bar()
	if not collapsed and _player_controller != null:
		_player_controller.ensure_selected_visible()


func _cancel_colonization_targeting() -> void:
	_colonization_targeting.clear()
	if _colonization_panel == null:
		return
	if _colonization_panel.is_source_picking():
		_colonization_panel.cancel_source_selection()
	else:
		_colonization_panel.cancel_target_selection()


func _on_colonization_planning_context(context: Dictionary) -> void:
	if _colonization_route == null:
		return
	if context.is_empty():
		_colonization_route.clear_planning_context()
		return
	var sources: PackedInt32Array = context.get("sources", PackedInt32Array())
	_colonization_route.set_planning_context(sources,
		int(context.get("selected_source", -1)),
		int(context.get("target_cell", -1)))


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
	elif mode == OverlayMode.MODE.BIO_OCCUPANCY:
		var signal_id := StringName(request.get("signal_id", &""))
		for entry in ResearchSignalCatalog.occupancy_overlay_entries():
			if StringName(entry.get("id", &"")) == signal_id:
				title = String(entry.get("display_name", ""))
				icon_key = String(entry.get("icon_key", &"ecology.growth"))
				occupancy_bit = int(entry.get("occupancy_bit", -1))
				break
	if _map_overlay_legend != null:
		_map_overlay_legend.update_for_mode(mode, title, hint, icon_key, occupancy_bit)
		call_deferred("_layout_overlay_legend")
	map_overlay_requested.emit(request)


func _on_map_overlay_cleared() -> void:
	if _map_overlay_legend != null:
		_map_overlay_legend.update_for_mode(OverlayMode.MODE.NONE)
	map_overlay_cleared.emit()


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
	if _map_overlay_legend == null:
		return
	var compact_detail := _right_panel != null and _right_panel.detail_open() \
		and _base_map_safe_area().size.x < OVERLAY_LEGEND_WIDTH + UITokens.SPACE_MD * 2.0
	_map_overlay_legend.modulate.a = 0.0 if compact_detail else 1.0
	_map_overlay_legend.mouse_filter = Control.MOUSE_FILTER_IGNORE \
		if compact_detail else Control.MOUSE_FILTER_PASS
	var right_inset := UITokens.ARCHIVE_EDGE_INSET
	if _right_panel != null and _right_panel.visible:
		var panel_width := _right_panel.size.x
		if panel_width <= 0.0:
			panel_width = RIGHT_PANEL_WIDTH
		right_inset += panel_width + UITokens.SPACE_MD + UITokens.ARCHIVE_EDGE_INSET
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
	var ui_root := get_node_or_null("UIRoot") as Control
	var viewport_width := ui_root.size.x if ui_root != null and ui_root.size.x > 0.0 \
		else get_viewport().get_visible_rect().size.x
	var safe := _base_map_safe_area()
	var bar_width := 412.0
	_country_action_bar.visible = not (_right_panel != null \
		and _right_panel.family_workspace_open() \
		and safe.size.x < bar_width + UITokens.ARCHIVE_EDGE_INSET * 2.0)
	var side_margin := maxf(safe.position.x + (safe.size.x - bar_width) * 0.5,
		UITokens.ARCHIVE_EDGE_INSET)
	var right_margin := maxf(viewport_width - side_margin - bar_width,
		UITokens.ARCHIVE_EDGE_INSET)
	_country_action_bar.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	_country_action_bar.offset_left = side_margin
	_country_action_bar.offset_right = -right_margin
	_country_action_bar.offset_top = -CountryActionBar.BAR_HEIGHT - UITokens.ARCHIVE_EDGE_INSET
	_country_action_bar.offset_bottom = -UITokens.ARCHIVE_EDGE_INSET
	var window_width := get_window().size.x if get_window() != null else int(viewport_width)
	_country_action_bar.set_compact(window_width < 720 or TouchUI.is_short_viewport())
	_layout_research_toast()


func _ensure_research_toast() -> void:
	if _research_toast != null:
		return
	var hud := get_node_or_null("UIRoot/HUDLayer") as Control
	if hud == null:
		return
	_research_toast = ResearchToastScene.instantiate() as ResearchToast
	_research_toast.name = "ResearchToast"
	_research_toast.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hud.add_child(_research_toast)
	_layout_research_toast()


func _layout_research_toast() -> void:
	if _research_toast == null:
		return
	_research_toast.set_anchors_preset(Control.PRESET_TOP_WIDE)
	_research_toast.offset_left = 24.0
	_research_toast.offset_right = -24.0
	_research_toast.offset_top = PlayerTopBar.BAR_HEIGHT + UITokens.SPACE_SM
	_research_toast.offset_bottom = _research_toast.offset_top + 96.0
	_research_toast.z_index = 40


func _poll_research_completion_toasts() -> Dictionary:
	var result := {"states_changed": false, "completed": false}
	if _country_view_model == null:
		return result
	_ensure_research_toast()
	if _research_toast == null:
		return result
	var states: PackedInt32Array = _country_view_model.player_research_states()
	if states.is_empty():
		return result
	if not _research_toast_bootstrapped:
		_last_research_toast_states = states.duplicate()
		_research_toast_bootstrapped = true
		return result
	var previous := _last_research_toast_states
	if previous == states:
		return result
	result["states_changed"] = true
	var definitions: Array = TechnologyCatalogScript.public_definitions()
	var limit := mini(states.size(), definitions.size())
	for index in range(limit):
		var next_state := int(states[index])
		var prev_state := int(previous[index]) if index < previous.size() else 0
		# State 4 = research complete, pending Effect activation ("明日生效").
		# State 5 = already owned. Toast on the pending edge so the copy matches.
		if prev_state >= 4 or next_state < 4:
			continue
		var definition: Dictionary = definitions[index]
		if bool(definition.get("is_application", false)) \
				or String(definition.get("id", "")).begins_with("app."):
			continue
		_research_toast.show_research_completed(String(definition.get(
			"display_name", definition.get("id", ""))))
		result["completed"] = true
	_last_research_toast_states = states.duplicate()
	if bool(result["completed"]):
		_play_progression_cue(&"tech_research")
	return result


func _layout_gm_panel() -> void:
	if _gm_console == null:
		return
	var viewport_width := get_viewport().get_visible_rect().size.x
	var compact_detail := _right_panel != null and _right_panel.detail_open() \
		and _base_map_safe_area().size.x < GM_PANEL_MIN_WIDTH + UITokens.SPACE_MD * 2.0
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
	# 顶栏高度一变，左侧图层工具条的安全起点也跟着变，永远不许压到日历纸框。
	_layout_map_overlay_toolbar()


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
	if _map_overlay_toolbar == null:
		return
	var top_bar_height := PlayerTopBar.BAR_HEIGHT
	if _top_bar != null and _top_bar.size.y > 0.0:
		top_bar_height = maxf(_top_bar.size.y, PlayerTopBar.BAR_HEIGHT)
	_map_overlay_toolbar.set_anchors_preset(Control.PRESET_FULL_RECT)
	_map_overlay_toolbar.offset_left = UITokens.ARCHIVE_EDGE_INSET
	_map_overlay_toolbar.offset_top = top_bar_height + OVERLAY_TOOLBAR_TOP_GAP
	_map_overlay_toolbar.offset_right = -UITokens.ARCHIVE_EDGE_INSET
	_map_overlay_toolbar.offset_bottom = -UITokens.ARCHIVE_EDGE_INSET


var _panel_diag_printed: bool = false
var _panel_right_limit: float = 0.0


## 当前是否触摸档（手机/平板）。桌面返回 false，所有触摸专用版面改动都是 no-op。
func touch_layout_enabled() -> bool:
	var settings := get_node_or_null("/root/GameSettings")
	if settings == null or not settings.has_method("ui_scaling"):
		return false
	var scaling = settings.call("ui_scaling")
	return scaling != null and bool(scaling.call("is_touch_profile"))


## 递归打印子控件 rect（只在 panel-diag 触发一次）。
func _dump_panel_children(node: Node, depth: int) -> void:
	if depth > 5:
		return
	for child in node.get_children():
		var control := child as Control
		if control == null:
			continue
		var right_edge := control.global_position.x + control.size.x
		print("[panel-diag/%d] %s(%s) pos=%s size=%s min=%s right_edge=%.1f%s" % [
			depth, String(control.name), control.get_class(), str(control.global_position),
			str(control.size), str(control.get_combined_minimum_size()), right_edge,
			"  <-- OVERFLOW" if right_edge > _panel_right_limit + 0.5 else ""])
		_dump_panel_children(control, depth + 1)


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
	# 部队指挥常驻地图旁；单页不携带地块目录，也不占用整幅地图。
	var army_open := _right_panel.military_dossier_open() and \
		String(_military_dossier_context.get("kind", "")) == "army"
	if army_open:
		layout["panel_width"] = minf(520.0, viewport_width - UITokens.ARCHIVE_EDGE_INSET * 2.0)
		layout["compact"] = true
		_right_panel.custom_minimum_size.x = 0.0
	var compact := bool(layout.get("compact", false))
	_right_panel.set_compact_detail_mode(compact)
	var panel_width := float(layout.get("panel_width", RIGHT_PANEL_WIDTH))
	# [panel-fit 2026-11-02] 触摸档把页签抬到 44dp 之后，面板内容的最小宽度会超过
	# RIGHT_PANEL_WIDTH（真机 2670x1200@520dpi 实测：右侧详情面板的页签行被挤出屏幕，
	# 关闭按钮直接看不见）。这里让面板按"内容最小宽度"兜底，并限制在视口 55% 以内，
	# 保证永远贴右且完整可见。
	var content_min_width := 0.0
	var min_size := _right_panel.get_combined_minimum_size()
	if min_size != null:
		content_min_width = float(min_size.x)
	if content_min_width > panel_width:
		panel_width = minf(content_min_width, maxf(viewport_width * 0.55, RIGHT_PANEL_WIDTH))
	# [panel-width-touch 2026-11-02] 触摸档的页签/KPI 行比桌面宽（页签 44dp 起），
	# 460 装不下：真机 2670x1200@520dpi 上右侧面板的"市场"页签与"就业率"读数会被
	# 屏幕右缘切掉。这里在触摸档给面板加宽 72 设计像素（视口 2053 宽，完全放得下）。
	if touch_layout_enabled():
		panel_width = maxf(panel_width, RIGHT_PANEL_WIDTH + 72.0)
		panel_width = minf(panel_width, maxf(viewport_width * 0.55, RIGHT_PANEL_WIDTH + 72.0))
	_right_panel.set_anchors_preset(Control.PRESET_RIGHT_WIDE)
	_right_panel.offset_left = -panel_width - UITokens.ARCHIVE_EDGE_INSET
	var top_bar_height := _top_bar.size.y if _top_bar != null and _top_bar.size.y > 0.0 \
		else PlayerTopBar.BAR_HEIGHT
	_right_panel.offset_top = top_bar_height + UITokens.SPACE_MD
	_right_panel.offset_right = -UITokens.ARCHIVE_EDGE_INSET
	_right_panel.offset_bottom = -UITokens.ARCHIVE_EDGE_INSET
	_right_panel.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	_right_panel.grow_vertical = Control.GROW_DIRECTION_END
	_right_panel.custom_minimum_size.x = panel_width
	# [panel-diag 2026-11-02] 真机上右侧面板内容被屏幕右缘切掉。这一行把
	# 视口/根节点/父层/面板的坐标系一次性打出来，直接判断是"锚点算错"还是
	# "父层尺寸是物理像素而面板是逻辑像素"。
	if detail_open and not _panel_diag_printed:
		_panel_diag_printed = true
		var root := get_tree().root
		var ui_root := get_node_or_null("UIRoot") as Control
		var panel_layer := _right_panel.get_parent() as Control
		print("[panel-diag] viewport=%s root=%s ui_root=%s layer=%s panel_pos=%s panel_size=%s panel_min=%s panel_width=%.1f inset=%.1f"
			% [
				str(get_viewport().get_visible_rect().size),
				str(root.size if root != null else Vector2.ZERO),
				str(ui_root.size if ui_root != null else Vector2.ZERO),
				str(panel_layer.size if panel_layer != null else Vector2.ZERO),
				str(_right_panel.global_position), str(_right_panel.size),
				str(_right_panel.get_combined_minimum_size()), panel_width,
				UITokens.ARCHIVE_EDGE_INSET])
		# 面板自身尺寸是对的（右缘 = viewport - inset），所以溢出的必然是某个子控件。
		# 把两层子节点的 rect 打出来，直接定位谁比面板宽。
		_panel_right_limit = _right_panel.global_position.x + _right_panel.size.x
		_dump_panel_children(_right_panel, 0)
	# 关键一步：UIAnimation.fade_slide_in/out 会把"第一次调用时的 control.position"
	# 永久缓存成 rest position。如果不在这里主动刷新，等玩家第一次点开地块面板时，
	# fade_slide_in 可能会缓存到一个还没被上面这套 offset 结算过的旧/零值，
	# 之后每次开合面板都会被带回那个错误坐标——这正是"详情框缩在左上角"的成因。
	UIAnimation.refresh_rest_position(_right_panel)


static func inspector_layout_for_width(viewport_width: float,
		detail_open: bool, family_open: bool = false) -> Dictionary:
	var available_width := maxf(viewport_width - UITokens.ARCHIVE_EDGE_INSET * 2.0, 1.0)
	if detail_open and family_open:
		# 地块栏的 460 已含外框与分栏间距；窄窗先让地图，再压缩家族正文。
		var family_width := clampf(available_width - RIGHT_PANEL_WIDTH \
			- MAP_REMAINING_MIN_WIDTH, FAMILY_DETAIL_MIN_WIDTH, FAMILY_DETAIL_MAX_WIDTH)
		family_width = minf(family_width, maxf(available_width - RIGHT_PANEL_WIDTH, 1.0))
		var panel_width := RIGHT_PANEL_WIDTH + family_width
		return {
			"compact": false,
			"panel_width": panel_width,
			"detail_width": family_width,
			"map_width": maxf(available_width - panel_width, 0.0),
		}
	var compact := viewport_width < DETAIL_LAYOUT_BREAKPOINT or TouchUI.is_short_viewport()
	var panel_width := RIGHT_PANEL_WIDTH
	if detail_open:
		if compact:
			panel_width = available_width
		else:
			panel_width = minf(DETAIL_PANEL_MAX_WIDTH,
				maxf(DETAIL_PANEL_MIN_WIDTH, viewport_width * 0.62))
			panel_width = minf(panel_width,
				maxf(RIGHT_PANEL_WIDTH,
					available_width - MAP_REMAINING_MIN_WIDTH))
	return {
		"compact": compact,
		"panel_width": panel_width,
		"detail_width": maxf(panel_width - RIGHT_PANEL_WIDTH, 0.0) \
			if detail_open and not compact else panel_width if detail_open else 0.0,
		"map_width": 0.0 if compact and detail_open \
			else maxf(available_width - panel_width, 0.0),
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


func show_annual_report(model: Dictionary, ceremonial: bool) -> void:
	if _annual_report_workspace != null:
		_annual_report_workspace.present(model, ceremonial)


func set_annual_history(rows: Array, offset: int, has_more: bool) -> void:
	if _annual_report_workspace != null:
		_annual_report_workspace.set_history(rows, offset, has_more)


func is_annual_report_open() -> bool:
	return _annual_report_workspace != null and _annual_report_workspace.visible


func annual_other_modal_open() -> bool:
	return is_era_reward_modal_open() or is_family_founding_modal_open() \
		or is_narrative_event_modal_open() \
		or (_pause_menu != null and _pause_menu.visible)


func show_narrative_event_offer(offer: Dictionary) -> void:
	_ensure_narrative_ui()
	if _country_panel != null and _country_panel.is_panel_open():
		close_country_panel()
	if _colonization_panel != null and _colonization_panel.visible:
		_colonization_panel.close_panel()
	if _narrative_event_dialog != null and _narrative_event_dialog.has_method("present_offer"):
		_narrative_event_dialog.present_offer(offer)


func show_narrative_event_outcome(resolution: Dictionary) -> void:
	_ensure_narrative_ui()
	if _narrative_event_dialog != null and _narrative_event_dialog.has_method("show_outcome"):
		_narrative_event_dialog.show_outcome(resolution)


func show_narrative_event_error(message: String) -> void:
	if _narrative_event_dialog != null and _narrative_event_dialog.has_method("show_error"):
		_narrative_event_dialog.show_error(message)


func set_narrative_event_illustration(tex: Texture2D) -> void:
	if _narrative_event_dialog != null and _narrative_event_dialog.has_method("set_illustration_texture"):
		_narrative_event_dialog.set_illustration_texture(tex)


func close_narrative_event_offer() -> void:
	if _narrative_event_dialog != null and _narrative_event_dialog.has_method("close_offer"):
		_narrative_event_dialog.close_offer()


func is_narrative_event_modal_open() -> bool:
	return _narrative_event_dialog != null and _narrative_event_dialog.has_method("is_offer_open") \
		and bool(_narrative_event_dialog.is_offer_open())


func show_narrative_chronicle(records: Array) -> void:
	_ensure_narrative_ui()
	if _narrative_chronicle_panel != null and _narrative_chronicle_panel.has_method("open_panel"):
		_narrative_chronicle_panel.open_panel(records)


func close_narrative_chronicle() -> void:
	if _narrative_chronicle_panel != null and _narrative_chronicle_panel.has_method("close_panel"):
		_narrative_chronicle_panel.close_panel()


func is_narrative_chronicle_open() -> bool:
	return _narrative_chronicle_panel != null and _narrative_chronicle_panel.visible
