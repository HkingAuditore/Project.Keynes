extends Node
class_name PlayerController
const PlayerCommandValidation = preload("res://scripts/game/player_command_validation.gd")


## Formal player-session boundary. It translates Godot/UI intent into the
## existing runtime and country facades; it never owns simulation state.

const AnnualReportFlowScript = preload("res://scripts/annual/annual_report_flow.gd")
const MusicSituationAggregatorScript = preload("res://scripts/audio/music_situation_aggregator.gd")
const NarrativeEventServiceScript = preload("res://scripts/narrative/narrative_event_service.gd")
const NarrativeEventFlowScript = preload("res://scripts/narrative/narrative_event_flow.gd")
const NarrativeAiClientScript = preload("res://scripts/narrative/ai/narrative_ai_client.gd")
var _annual_report_flow = AnnualReportFlowScript.new()
var _music_situation = MusicSituationAggregatorScript.new()
var _narrative_service = NarrativeEventServiceScript.new()
var _narrative_flow = NarrativeEventFlowScript.new()
var _narrative_ai_client: Node = null
## GM 事件屏蔽覆盖所有会自动锁时钟的玩家提示（年报、叙事、时代奖励、
## 家族创立和理念抽取），避免只屏蔽两类弹窗后仍出现“随机暂停”。
var _popups_suppressed: bool = false
var _suppression_resume_running: bool = false

signal selection_changed(cell)
signal command_completed(id: StringName, result: Dictionary)
signal command_settled(id: StringName, result: Dictionary)
signal regeneration_requested()
signal country_committed(report: Dictionary)
signal era_reward_offer_changed(offer: Dictionary)
signal family_founding_offer_changed(offer: Dictionary)
signal narrative_event_offer_changed(offer: Dictionary)
signal narrative_event_resolved(record: Dictionary)
## Emitted once the native authority published a fresh three-card offer; the
## clock is already paused when this fires.
signal ideology_offer_ready(snapshot: Dictionary)
## phase is "", "offer", "choose" or "reroll"; "" means the flow released.
signal ideology_draw_state_changed(phase: String, detail: Dictionary)
## Era Advancement (docs/cpp-dots-runtime/era-advancement-runtime.md §5).
signal era_advancement_changed(snapshot: Dictionary)
signal era_advanced(old_index: int, new_index: int, buffs: PackedStringArray)

const EraAdvancementServiceScript = PlayerCommandValidation.EraAdvancementServiceScript
const TechnologyCatalogForPlayerScript = preload("res://scripts/economy/technology_catalog.gd")
var _era_advancement = EraAdvancementServiceScript.new()

const COMMAND_RESEARCH_SET_WEIGHTS = PlayerCommandValidation.COMMAND_RESEARCH_SET_WEIGHTS
const COMMAND_RESEARCH_SET_BUDGET = PlayerCommandValidation.COMMAND_RESEARCH_SET_BUDGET
const COMMAND_RESEARCH_ENQUEUE = PlayerCommandValidation.COMMAND_RESEARCH_ENQUEUE
const COMMAND_RESEARCH_REMOVE = PlayerCommandValidation.COMMAND_RESEARCH_REMOVE
const COMMAND_RESEARCH_MOVE = PlayerCommandValidation.COMMAND_RESEARCH_MOVE
const COMMAND_COUNTRY_TAX_SET_DEFAULT = PlayerCommandValidation.COMMAND_COUNTRY_TAX_SET_DEFAULT
const COMMAND_COUNTRY_TAX_SET_OVERRIDE = PlayerCommandValidation.COMMAND_COUNTRY_TAX_SET_OVERRIDE
const COMMAND_COUNTRY_TAX_CLEAR_OVERRIDE = PlayerCommandValidation.COMMAND_COUNTRY_TAX_CLEAR_OVERRIDE
const COMMAND_CELL_TAX_SET_DEFAULT = PlayerCommandValidation.COMMAND_CELL_TAX_SET_DEFAULT
const COMMAND_CELL_TAX_CLEAR_DEFAULT = PlayerCommandValidation.COMMAND_CELL_TAX_CLEAR_DEFAULT
const COMMAND_CELL_TAX_SET_OVERRIDE = PlayerCommandValidation.COMMAND_CELL_TAX_SET_OVERRIDE
const COMMAND_CELL_TAX_CLEAR_OVERRIDE = PlayerCommandValidation.COMMAND_CELL_TAX_CLEAR_OVERRIDE
const COMMAND_CELL_TAX_CLEAR_ALL = PlayerCommandValidation.COMMAND_CELL_TAX_CLEAR_ALL
const COMMAND_CONSTRUCTION_BUILD = PlayerCommandValidation.COMMAND_CONSTRUCTION_BUILD
const COMMAND_FAMILY_COLONIZATION_START = PlayerCommandValidation.COMMAND_FAMILY_COLONIZATION_START
const COMMAND_FAMILY_COLONIZATION_CANCEL = PlayerCommandValidation.COMMAND_FAMILY_COLONIZATION_CANCEL
const COMMAND_ERA_REWARD_CHOOSE = PlayerCommandValidation.COMMAND_ERA_REWARD_CHOOSE
const COMMAND_FAMILY_FOUNDING_CHOOSE = PlayerCommandValidation.COMMAND_FAMILY_FOUNDING_CHOOSE
const COMMAND_IDEOLOGY_OFFER = PlayerCommandValidation.COMMAND_IDEOLOGY_OFFER
const COMMAND_IDEOLOGY_CHOOSE = PlayerCommandValidation.COMMAND_IDEOLOGY_CHOOSE
const COMMAND_IDEOLOGY_EQUIP = PlayerCommandValidation.COMMAND_IDEOLOGY_EQUIP
const COMMAND_IDEOLOGY_UNEQUIP = PlayerCommandValidation.COMMAND_IDEOLOGY_UNEQUIP
const COMMAND_IDEOLOGY_PROMOTE = PlayerCommandValidation.COMMAND_IDEOLOGY_PROMOTE
const COMMAND_IDEOLOGY_REROLL = PlayerCommandValidation.COMMAND_IDEOLOGY_REROLL
const COMMAND_ERA_ADVANCE_START = PlayerCommandValidation.COMMAND_ERA_ADVANCE_START
const COMMAND_ERA_ADVANCE_PAUSE = PlayerCommandValidation.COMMAND_ERA_ADVANCE_PAUSE
const COMMAND_ERA_ADVANCE_RESUME = PlayerCommandValidation.COMMAND_ERA_ADVANCE_RESUME
const COMMAND_PROCUREMENT_SET_POLICY = PlayerCommandValidation.COMMAND_PROCUREMENT_SET_POLICY
const COMMAND_NARRATIVE_CHOOSE = PlayerCommandValidation.COMMAND_NARRATIVE_CHOOSE
## 军事（Military v1）。与契约 §2 的 op 字符串一一对应：面板只发语义命令，
## 控制器把它们翻译成军事 facade 的一行 batch 提交，生效日 D+1。
const COMMAND_MILITARY_FORCE_TARGET = PlayerCommandValidation.COMMAND_MILITARY_FORCE_TARGET
const COMMAND_MILITARY_CONFIG_SHARES = PlayerCommandValidation.COMMAND_MILITARY_CONFIG_SHARES
const COMMAND_MILITARY_QUALITY_POLICY = PlayerCommandValidation.COMMAND_MILITARY_QUALITY_POLICY
const COMMAND_MILITARY_AUTO_RETRAIN = PlayerCommandValidation.COMMAND_MILITARY_AUTO_RETRAIN
const COMMAND_MILITARY_LEVY = PlayerCommandValidation.COMMAND_MILITARY_LEVY
const COMMAND_MILITARY_AUTO_DISCHARGE = PlayerCommandValidation.COMMAND_MILITARY_AUTO_DISCHARGE
const COMMAND_MILITARY_BARRACKS = PlayerCommandValidation.COMMAND_MILITARY_BARRACKS
const COMMAND_MILITARY_TRAIN = PlayerCommandValidation.COMMAND_MILITARY_TRAIN
const COMMAND_MILITARY_STATE_BUILD = PlayerCommandValidation.COMMAND_MILITARY_STATE_BUILD
const COMMAND_MILITARY_STATE_DEMOLISH = PlayerCommandValidation.COMMAND_MILITARY_STATE_DEMOLISH
const COMMAND_MILITARY_WAGE = PlayerCommandValidation.COMMAND_MILITARY_WAGE
const COMMAND_MILITARY_PROCUREMENT = PlayerCommandValidation.COMMAND_MILITARY_PROCUREMENT
const COMMAND_MILITARY_BUDGET = PlayerCommandValidation.COMMAND_MILITARY_BUDGET
const COMMAND_MILITARY_ARMY_CREATE = PlayerCommandValidation.COMMAND_MILITARY_ARMY_CREATE
const COMMAND_MILITARY_ARMY_STATION = PlayerCommandValidation.COMMAND_MILITARY_ARMY_STATION
const COMMAND_MILITARY_ARMY_MOVE = PlayerCommandValidation.COMMAND_MILITARY_ARMY_MOVE
const COMMAND_MILITARY_AREA_CONTROL = PlayerCommandValidation.COMMAND_MILITARY_AREA_CONTROL
const COMMAND_MILITARY_ARMY_STOP = PlayerCommandValidation.COMMAND_MILITARY_ARMY_STOP
const COMMAND_MILITARY_ARMY_STANCE = PlayerCommandValidation.COMMAND_MILITARY_ARMY_STANCE
const COMMAND_MILITARY_ARMY_DISBAND = PlayerCommandValidation.COMMAND_MILITARY_ARMY_DISBAND
const COMMAND_MILITARY_WAR_DECLARE = PlayerCommandValidation.COMMAND_MILITARY_WAR_DECLARE
const COMMAND_MILITARY_PEACE_PROPOSE = PlayerCommandValidation.COMMAND_MILITARY_PEACE_PROPOSE
const COMMAND_MILITARY_PEACE_RESPOND = PlayerCommandValidation.COMMAND_MILITARY_PEACE_RESPOND
## A draw/choose/reroll that has not settled after this many simulated days
## releases the lock and restores the clock.
const IDEOLOGY_DRAW_TIMEOUT_DAYS := 3

const SUPPORTED_COMMANDS := {
	COMMAND_RESEARCH_SET_WEIGHTS: true,
	COMMAND_RESEARCH_SET_BUDGET: true,
	COMMAND_RESEARCH_ENQUEUE: true,
	COMMAND_RESEARCH_REMOVE: true,
	COMMAND_RESEARCH_MOVE: true,
	COMMAND_COUNTRY_TAX_SET_DEFAULT: true,
	COMMAND_COUNTRY_TAX_SET_OVERRIDE: true,
	COMMAND_COUNTRY_TAX_CLEAR_OVERRIDE: true,
	COMMAND_CELL_TAX_SET_DEFAULT: true,
	COMMAND_CELL_TAX_CLEAR_DEFAULT: true,
	COMMAND_CELL_TAX_SET_OVERRIDE: true,
	COMMAND_CELL_TAX_CLEAR_OVERRIDE: true,
	COMMAND_CELL_TAX_CLEAR_ALL: true,
	COMMAND_CONSTRUCTION_BUILD: true,
	COMMAND_FAMILY_COLONIZATION_START: true,
	COMMAND_FAMILY_COLONIZATION_CANCEL: true,
	COMMAND_ERA_REWARD_CHOOSE: true,
	COMMAND_FAMILY_FOUNDING_CHOOSE: true,
	COMMAND_IDEOLOGY_OFFER: true,
	COMMAND_IDEOLOGY_CHOOSE: true,
	COMMAND_IDEOLOGY_EQUIP: true,
	COMMAND_IDEOLOGY_UNEQUIP: true,
	COMMAND_IDEOLOGY_PROMOTE: true,
	COMMAND_IDEOLOGY_REROLL: true,
	COMMAND_ERA_ADVANCE_START: true,
	COMMAND_ERA_ADVANCE_PAUSE: true,
	COMMAND_ERA_ADVANCE_RESUME: true,
	COMMAND_PROCUREMENT_SET_POLICY: true,
	COMMAND_NARRATIVE_CHOOSE: true,
	COMMAND_MILITARY_FORCE_TARGET: true,
	COMMAND_MILITARY_CONFIG_SHARES: true,
	COMMAND_MILITARY_QUALITY_POLICY: true,
	COMMAND_MILITARY_AUTO_RETRAIN: true,
	COMMAND_MILITARY_LEVY: true,
	COMMAND_MILITARY_AUTO_DISCHARGE: true,
	COMMAND_MILITARY_BARRACKS: true,
	COMMAND_MILITARY_TRAIN: true,
	COMMAND_MILITARY_STATE_BUILD: true,
	COMMAND_MILITARY_STATE_DEMOLISH: true,
	COMMAND_MILITARY_WAGE: true,
	COMMAND_MILITARY_PROCUREMENT: true,
	COMMAND_MILITARY_ARMY_CREATE: true,
	COMMAND_MILITARY_ARMY_STATION: true,
	COMMAND_MILITARY_ARMY_MOVE: true,
	COMMAND_MILITARY_AREA_CONTROL: true,
	COMMAND_MILITARY_ARMY_STOP: true,
	COMMAND_MILITARY_ARMY_STANCE: true,
	COMMAND_MILITARY_ARMY_DISBAND: true,
	COMMAND_MILITARY_WAR_DECLARE: true,
	COMMAND_MILITARY_PEACE_PROPOSE: true,
	COMMAND_MILITARY_PEACE_RESPOND: true,
}

var _camera = null
var _highlight = null
var _cell_highlight_set = null
## Peace-window map overlays: candidates (muted outline) and the picked draft
## (vermilion fill). Two separate sets, because picking a cell must repaint the
## draft without touching the candidate outline behind it.
var _peace_candidate_set = null
var _peace_draft_set = null
var _runtime_host = null
var _world_clock = null
var _ui_manager = null
var _selected_cell = null
var _player_country_handle := 0
var _command_sequence := 1
var _pause_before_menu := false
var _country_facade = null
var _economy_facade = null
var _ideology_facade = null
var _era_reward_locked := false
var _era_reward_resume_running := false
var _era_reward_previous_speed := 1.0
var _era_reward_generation := 0
var _era_reward_last_status := "NONE"
var _era_reward_drain_active := false
var _family_founding_locked := false
var _family_founding_resume_running := false
var _family_founding_previous_speed := 1.0
var _family_founding_offer_id := 0
var _family_founding_generation := 0
# Ideology draw flow: pause + one-day steps until the native offer settles.
var _ideology_draw_phase := ""
var _ideology_draw_clock_saved := false
var _ideology_draw_resume_running := false
var _ideology_draw_previous_speed := 1.0
var _ideology_draw_baseline_generation := 0
var _ideology_draw_start_day := 0
var _ideology_draw_sequence := -1


func configure(
		camera,
		highlight,
		runtime_host,
		world_clock,
		ui_manager
) -> void:
	_camera = camera
	_highlight = highlight
	_runtime_host = runtime_host
	_world_clock = world_clock
	_ui_manager = ui_manager
	_apply_camera_view_scale_compensation()
	_connect_runtime()
	_connect_ui()
	_annual_report_flow.configure(self, _runtime_host, _world_clock, _ui_manager)
	_configure_narrative_runtime()
	set_process(true)
	sync_ui()


## [mobile-zoom-compensate 2026-11-03] 把移动端的「等效放大倍数」拉回桌面口径。
##
## 移动端 content_scale_mode = CANVAS_ITEMS（scripts/ui/mobile_ui_scaling.gd）之后，
## 1 world unit 在屏幕上占 zoom × total_scale 个物理像素；桌面只占 zoom。于是同一个
## zoom_max=6.0 在手机上等效桌面 6 × total_scale（440dpi 真机 ≈ 8.25），玩家能捏合到比
## 桌面更近，把每 hex 的 texel 拉到极限——这就是"放大后颗粒明显"的放大端根因。
## 这里把 MapCamera 的有效上限改成 zoom_max / total_scale，等效倍数回到桌面口径。
##
## 只在原生移动平台调用；桌面/Web 连 setter 都不碰，MapCamera 的补偿系数保持 1.0
## （见 MapCamera._maximum_zoom 的 `zoom_max / 1.0`，逐位等于原值）。
func _apply_camera_view_scale_compensation() -> void:
	if _camera == null or not _camera.has_method("set_view_scale_compensation"):
		return
	if not (OS.has_feature("mobile") or OS.has_feature("android") or OS.has_feature("ios")):
		return
	var settings := get_node_or_null("/root/GameSettings")
	if settings == null or not settings.has_method("ui_scaling"):
		return
	var scaling = settings.call("ui_scaling")
	if scaling == null or not scaling.has_method("total_scale"):
		return
	var total_scale := float(scaling.call("total_scale"))
	if total_scale <= 0.01:
		return
	_camera.set_view_scale_compensation(total_scale)


func _process(delta: float) -> void:
	if _popups_suppressed and _suppression_resume_running and _world_clock != null \
			and _world_clock.paused and not _world_clock.authority_fault_hold \
			and _is_suppressed_popup_pause_source(String(_world_clock.last_pause_source)):
		# 兜底处理竞态：事件可能在同步流程之后才到达，下一帧再申请暂停。
		# 只释放已知的 UI 自动暂停来源，保留手动暂停、存档暂停和故障保护。
		_world_clock.pause(false)
		_sync_clock_visual_state()
	if _music_situation == null:
		return
	var situation: Dictionary = _music_situation.process_audio_update(delta)
	if not bool(situation.get("tension_write_due", false)):
		return
	var audio := get_node_or_null("/root/GameAudio")
	if audio == null or not audio.has_method("set_active_suite_emotion"):
		return
	if bool(audio.set_active_suite_emotion(
			float(situation.get("tension", 0.0)), 0.0, 0.0, false)):
		_music_situation.consume_tension_write()


func music_situation_diagnostics() -> Dictionary:
	return _music_situation.diagnostics() if _music_situation != null else {}


func selected_cell():
	return _selected_cell


## The many-cell overlay that answers "where does this card act?". Injected
## separately from `configure` so every existing caller keeps working, and so a
## headless session (which builds no WorldRoot children) can simply not set it.
func set_cell_highlight_set(node) -> void:
	if _cell_highlight_set == node:
		return
	_cell_highlight_set = node
	clear_cell_highlights()


## Paint the cells a card's effect instances resolved to. Returns how many were
## actually painted, so the caller can tell "nothing to show" from "the map
## refused every index" without re-querying the map. An empty input clears.
## `frame` is false for live drafting (peace cession picks), where yanking the
## camera on every toggle would fight the player.
func highlight_cells(cells: PackedInt32Array, frame: bool = true) -> int:
	if _cell_highlight_set == null:
		return 0
	if cells.is_empty():
		_cell_highlight_set.clear()
		return 0
	var centers := _cell_centers(cells)
	_cell_highlight_set.set_cells(centers,
		_runtime_host.hex_size if _runtime_host != null else 22.0,
		_runtime_host.map_wrap_period_x() if _runtime_host != null else 0.0)
	if centers.is_empty():
		return 0
	# Frame the first hit, the way select_cell frames the cell the player picked.
	if frame and _camera != null and _ui_manager != null:
		_camera.ensure_point_visible(centers[0], _ui_manager.map_safe_area())
	return centers.size()


func clear_cell_highlights() -> void:
	if _cell_highlight_set != null:
		_cell_highlight_set.clear()


## ── peace window (MilitaryPeaceWindow) ───────────────────────────────────
## The window owns the draft; this side only paints it. Kept as three flat
## methods so the window can feature-detect them (`has_method`) in tests and in
## a session that has no WorldRoot children.
func set_peace_highlight_sets(candidate_set, draft_set) -> void:
	_peace_candidate_set = candidate_set
	_peace_draft_set = draft_set
	clear_peace_highlights()


func highlight_peace_candidates(cells: PackedInt32Array) -> void:
	_paint_peace_set(_peace_candidate_set, cells)


func highlight_peace_draft(cells: PackedInt32Array) -> void:
	_paint_peace_set(_peace_draft_set, cells)


func clear_peace_highlights() -> void:
	if _peace_candidate_set != null:
		_peace_candidate_set.clear()
	if _peace_draft_set != null:
		_peace_draft_set.clear()


func _paint_peace_set(node, cells: PackedInt32Array) -> void:
	if node == null:
		return
	if cells.is_empty():
		node.clear()
		return
	var centers := _cell_centers(cells)
	node.set_cells(centers,
		_runtime_host.hex_size if _runtime_host != null else 22.0,
		_runtime_host.map_wrap_period_x() if _runtime_host != null else 0.0)


func _cell_centers(cells: PackedInt32Array) -> PackedVector2Array:
	if _runtime_host == null or not _runtime_host.has_method("cell_display_centers"):
		return PackedVector2Array()
	var ref_x: float = _camera.position.x if _camera != null else 0.0
	return _runtime_host.cell_display_centers(cells, ref_x)


## Center the camera on a cell without selecting it (war-situation rows).
func focus_map_cell(cell_index: int) -> void:
	if _runtime_host == null or _runtime_host.current_map() == null or cell_index < 0:
		return
	var cell = _runtime_host.current_map().cell_at(cell_index)
	if cell == null:
		return
	if _camera != null and _ui_manager != null:
		_camera.ensure_point_visible(_cell_display_world(cell), _ui_manager.map_safe_area())


func ensure_selected_visible() -> void:
	if _selected_cell == null or _camera == null or _ui_manager == null:
		return
	_camera.ensure_point_visible(_cell_display_world(_selected_cell),
		_ui_manager.map_safe_area())


func select_cell(cell) -> void:
	# The peace window is a map-first editing surface: a click on a cession
	# candidate toggles the draft and must not clear the draft highlight or open
	# the cell panel. Checked before clear_cell_highlights() for exactly that
	# reason.
	if cell != null and _ui_manager != null \
			and _ui_manager.has_method("handle_peace_map_cell") \
			and bool(_ui_manager.call("handle_peace_map_cell", int(cell.index))):
		return
	# A pending army order (移动 / 军事控制) takes the next map click instead of
	# opening the cell panel; the order itself decides what the click means.
	if not _military_order_mode.is_empty() and cell != null \
			and military_arm_order_click(int(cell.index)):
		return
	# 选格是"新的地图焦点"：军务档案关闭，右侧回到地块档案。
	if _ui_manager != null and _ui_manager.has_method("close_military_dossier"):
		_ui_manager.call("close_military_dossier")
	# Picking a hex ends whatever card-level question the player was asking:
	# leaving a card's hit set on screen while a different hex is selected reads
	# as "this hex is one of them" and there is no way to tell otherwise.
	clear_cell_highlights()
	if cell == null:
		clear_selection()
		return
	_selected_cell = cell
	var display_world := _cell_display_world(cell)
	var wrap_period: float = _runtime_host.map_wrap_period_x() if _runtime_host != null else 0.0
	if _highlight != null:
		_highlight.set_cell_display(cell, _runtime_host.hex_size if _runtime_host != null else 22.0,
			display_world, wrap_period)
	if _ui_manager != null:
		_ui_manager.show_cell_panel(cell)
	if _camera != null and _ui_manager != null:
		_camera.ensure_point_visible(display_world, _ui_manager.map_safe_area())
	selection_changed.emit(cell)


func clear_selection() -> void:
	_selected_cell = null
	if _highlight != null:
		_highlight.clear()
	if _ui_manager != null:
		_ui_manager.hide_cell_panel()
	selection_changed.emit(null)


func sync_ui() -> void:
	_sync_clock_visual_state()
	_sync_time_ui()
	_annual_report_flow.try_present()
	_narrative_flow.try_present()


func refresh_country_binding() -> void:
	var generator: Variant = _runtime_host.generator() if _runtime_host != null else null
	var next = generator.get_country_facade() if generator != null and \
		generator.has_method("get_country_facade") else null
	if _country_facade != null and _country_facade.has_signal("country_committed"):
		var old_callback := Callable(self, "_on_country_committed")
		if _country_facade.country_committed.is_connected(old_callback):
			_country_facade.country_committed.disconnect(old_callback)
	if _economy_facade != null and _economy_facade.has_signal(
			"construction_command_settled"):
		var old_economy_callback := Callable(self, "_on_construction_command_settled")
		if _economy_facade.construction_command_settled.is_connected(
				old_economy_callback):
			_economy_facade.construction_command_settled.disconnect(
				old_economy_callback)
	if _economy_facade != null and _economy_facade.has_signal(
			"family_colonization_settled"):
		var old_colonization_callback := Callable(
			self, "_on_family_colonization_settled")
		if _economy_facade.family_colonization_settled.is_connected(
				old_colonization_callback):
			_economy_facade.family_colonization_settled.disconnect(
				old_colonization_callback)
	if _ideology_facade != null and _ideology_facade.has_signal("command_settled"):
		var old_ideology_callback := Callable(self, "_on_ideology_command_settled")
		if _ideology_facade.command_settled.is_connected(old_ideology_callback):
			_ideology_facade.command_settled.disconnect(old_ideology_callback)
	_country_facade = next
	_economy_facade = generator.get_economy_facade() if generator != null \
			and generator.has_method("get_economy_facade") else null
	_ideology_facade = generator.get_ideology_facade() if generator != null \
			and generator.has_method("get_ideology_facade") else null
	if _country_facade != null and _country_facade.has_signal("country_committed"):
		var callback := Callable(self, "_on_country_committed")
		if not _country_facade.country_committed.is_connected(callback):
			_country_facade.country_committed.connect(callback)
	if _economy_facade != null and _economy_facade.has_signal(
			"construction_command_settled"):
		var economy_callback := Callable(self, "_on_construction_command_settled")
		if not _economy_facade.construction_command_settled.is_connected(
				economy_callback):
			_economy_facade.construction_command_settled.connect(economy_callback)
	if _economy_facade != null and _economy_facade.has_signal(
			"family_colonization_settled"):
		var colonization_callback := Callable(
			self, "_on_family_colonization_settled")
		if not _economy_facade.family_colonization_settled.is_connected(
				colonization_callback):
			_economy_facade.family_colonization_settled.connect(
				colonization_callback)
	if _ideology_facade != null and _ideology_facade.has_signal("command_settled"):
		var ideology_callback := Callable(self, "_on_ideology_command_settled")
		if not _ideology_facade.command_settled.is_connected(ideology_callback):
			_ideology_facade.command_settled.connect(ideology_callback)
	if _country_facade != null:
		_resolve_player_country()
		_configure_music_situation()
		# 读档可能早于国家句柄解析：那时重推只会因为句柄为 0 而放弃，
		# 这里在绑定完成后补一次，避免预算控制静默失效。
		_repush_military_budget()
		_sync_era_reward_offer()
		_sync_era_music(true)
	_sync_family_founding_offer()
	_bind_era_advancement()
	_configure_narrative_runtime()


func _configure_music_situation() -> void:
	if _music_situation == null or _runtime_host == null:
		return
	var generator = _runtime_host.generator() if _runtime_host.has_method("generator") else null
	_music_situation.configure(_runtime_host, generator, self)
	_music_situation.refresh_global_from_commit()
	if _camera != null and _camera.has_method("current_world_view_rect"):
		_music_situation.refresh_local_from_view(
			_camera.current_world_view_rect(), music_camera_zoom_ratio())


func capture_view_state() -> Dictionary:
	return {
		"selected_cell": int(_selected_cell.index) if _selected_cell != null else -1,
		"camera_position": _camera.global_position if _camera != null else Vector2.ZERO,
		"camera_zoom": _camera.zoom if _camera != null else Vector2.ONE,
		"next_command_sequence": _command_sequence,
		"annual_report_view": _annual_report_flow.capture(),
		"era_reward_locked": _era_reward_locked,
		"era_reward_resume_running": _era_reward_resume_running,
		"era_reward_previous_speed": _era_reward_previous_speed,
		"era_reward_generation": _era_reward_generation,
		"family_founding_locked": _family_founding_locked,
		"family_founding_resume_running": _family_founding_resume_running,
		"family_founding_previous_speed": _family_founding_previous_speed,
		"ideology_draw_phase": _ideology_draw_phase,
		"ideology_draw_clock_saved": _ideology_draw_clock_saved,
		"ideology_draw_resume_running": _ideology_draw_resume_running,
		"ideology_draw_previous_speed": _ideology_draw_previous_speed,
		"ideology_draw_baseline_generation": _ideology_draw_baseline_generation,
		"ideology_draw_start_day": _ideology_draw_start_day,
		"ideology_draw_sequence": _ideology_draw_sequence,
		"era_advancement": _era_advancement.to_save(),
		"military_budget": _military_budget_state.duplicate(),
		"narrative_event_view": _narrative_flow.capture(),
	}


func restore_view_state(map, state: Dictionary) -> void:
	_annual_report_flow.restore(state.get("annual_report_view", {}))
	_narrative_flow.restore(state.get("narrative_event_view", {}))
	_command_sequence = maxi(1, int(state.get("next_command_sequence", 1)))
	_era_reward_resume_running = bool(state.get("era_reward_resume_running", false))
	_era_reward_previous_speed = float(state.get("era_reward_previous_speed", 1.0))
	_era_reward_generation = int(state.get("era_reward_generation", 0))
	_era_reward_locked = bool(state.get("era_reward_locked", false))
	# 读档恢复待领取提醒；已提交事务仍继续排空，未选择的旧弹窗不强制重开。
	if _era_reward_locked and _country_facade != null:
		var restored_offer: Dictionary = _country_facade.era_reward_offer()
		if bool(restored_offer.get("ok", false)) and String(restored_offer.get("status", "NONE")) in ["OPEN", "ERROR"]:
			_era_reward_locked = false
			if _ui_manager != null:
				_ui_manager.close_era_reward_offer()
			if _world_clock != null:
				_world_clock.set_speed(_era_reward_previous_speed)
				_world_clock.pause(not _era_reward_resume_running)
	_family_founding_resume_running = bool(state.get(
		"family_founding_resume_running", false))
	_family_founding_previous_speed = float(state.get(
		"family_founding_previous_speed", 1.0))
	_family_founding_locked = bool(state.get("family_founding_locked", false))
	_family_founding_offer_id = 0
	_family_founding_generation = 0
	_ideology_draw_phase = String(state.get("ideology_draw_phase", ""))
	if not ["", "offer", "presenting", "choose", "reroll"].has(_ideology_draw_phase):
		_ideology_draw_phase = ""
	_ideology_draw_clock_saved = bool(state.get("ideology_draw_clock_saved", false))
	_ideology_draw_resume_running = bool(state.get("ideology_draw_resume_running", false))
	_ideology_draw_previous_speed = float(state.get("ideology_draw_previous_speed", 1.0))
	_ideology_draw_baseline_generation = int(state.get(
		"ideology_draw_baseline_generation", 0))
	_ideology_draw_start_day = int(state.get("ideology_draw_start_day", 0))
	_ideology_draw_sequence = int(state.get("ideology_draw_sequence", -1))
	if _camera != null:
		var saved_position = state.get(
			"camera_position", _camera.global_position)
		if not (saved_position is Vector2):
			saved_position = _camera.global_position
		var saved_zoom = state.get("camera_zoom", _camera.zoom)
		if _camera.has_method("restore_view_state"):
			_camera.restore_view_state(saved_position, saved_zoom)
		else:
			# Compatibility for minimal camera stubs used by focused tests.
			_camera.global_position = saved_position
			_camera.zoom = saved_zoom
	if map != null:
		var selected := int(state.get("selected_cell", -1))
		if selected >= 0 and selected < map.cell_count():
			select_cell(map.cell_at(selected))
		else:
			clear_selection()
	_sync_era_reward_offer()
	_sync_family_founding_offer()
	_sync_ideology_draw()
	_sync_era_music(true)
	_restore_era_advancement(state.get("era_advancement", {}))
	_restore_military_budget(state.get("military_budget", {}))
	_annual_report_flow.try_present()
	_narrative_flow.try_present()


func request_command(id: StringName, args: Dictionary = {}) -> Dictionary:
	if _annual_report_flow.is_open():
		return _complete_command(id, _result(false, "annual_report_open", "请先合卷，再处理国家事务。"))
	if _era_reward_locked and id != COMMAND_ERA_REWARD_CHOOSE:
		return _complete_command(id, _result(false,
			"era_reward_choice_required", "必须先完成时代奖励选择。"))
	if ideology_draw_locked() and id != COMMAND_ERA_REWARD_CHOOSE:
		return _complete_command(id, _result(false,
			"ideology_draw_in_progress", "正在抽取。"))
	if _family_founding_locked and id != COMMAND_FAMILY_FOUNDING_CHOOSE \
			and id != COMMAND_ERA_REWARD_CHOOSE:
		return _complete_command(id, _result(false,
			"family_founding_choice_required", "必须先选择要扶持的家族。"))
	if _narrative_flow.is_locked() and id != COMMAND_NARRATIVE_CHOOSE \
			and id != COMMAND_ERA_REWARD_CHOOSE \
			and id != COMMAND_FAMILY_FOUNDING_CHOOSE:
		return _complete_command(id, _result(false,
			"narrative_choice_required", "请先处理当前事件。"))
	if not SUPPORTED_COMMANDS.has(id):
		return _complete_command(id, _result(false, "unsupported_command", "该正式玩家命令尚未开放。"))
	var ready := _resolve_player_country()
	if not bool(ready.get("ok", false)):
		return _complete_command(id, ready)
	var validation := _validate_command_args(id, args, ready.facade)
	if not bool(validation.get("ok", false)):
		return _complete_command(id, validation)
	var facade = ready.facade
	var effective_day := maxi(0, _world_clock.day_index()) \
		if id == COMMAND_FAMILY_COLONIZATION_START or \
		id == COMMAND_FAMILY_COLONIZATION_CANCEL or \
		id == COMMAND_ERA_REWARD_CHOOSE or \
		id == COMMAND_FAMILY_FOUNDING_CHOOSE else _next_effective_day()
	var sequence := _command_sequence
	_command_sequence += 1
	var result: Dictionary
	match id:
		COMMAND_RESEARCH_SET_WEIGHTS:
			var weights := args.get("weights_bp", PackedInt32Array()) as PackedInt32Array
			result = facade.set_research_weights(_player_country_handle, weights, effective_day, sequence)
		COMMAND_RESEARCH_SET_BUDGET:
			var limit := int(args.get("daily_cash_limit", -1))
			result = facade.set_research_budget(_player_country_handle,
				bool(args.get("enabled", false)), limit,
				effective_day, sequence)
		COMMAND_RESEARCH_ENQUEUE:
			result = _request_research_queue(facade, "enqueue", args, effective_day, sequence)
		COMMAND_RESEARCH_REMOVE:
			result = _request_research_queue(facade, "remove", args, effective_day, sequence)
		COMMAND_RESEARCH_MOVE:
			result = _request_research_queue(facade, "move", args, effective_day, sequence)
		COMMAND_COUNTRY_TAX_SET_DEFAULT:
			result = facade.set_tax_default_basis_points(_player_country_handle,
				int(args.kind), _tax_rate_basis_points(args), effective_day, sequence,
				_tax_assessment_mode(args))
		COMMAND_COUNTRY_TAX_SET_OVERRIDE:
			result = facade.set_tax_override_basis_points(_player_country_handle,
				int(args.kind), StringName(args.item_id), _tax_rate_basis_points(args),
				effective_day, sequence, _tax_assessment_mode(args))
		COMMAND_COUNTRY_TAX_CLEAR_OVERRIDE:
			result = facade.clear_tax_override(_player_country_handle,
				int(args.kind), StringName(args.item_id), effective_day, sequence)
		COMMAND_CELL_TAX_SET_DEFAULT:
			result = facade.set_cell_tax_default_basis_points(_player_country_handle,
				int(args.cell), int(args.kind), _tax_rate_basis_points(args),
				effective_day, sequence, _tax_assessment_mode(args))
		COMMAND_CELL_TAX_CLEAR_DEFAULT:
			result = facade.clear_cell_tax_default(_player_country_handle,
				int(args.cell), int(args.kind), effective_day, sequence)
		COMMAND_CELL_TAX_SET_OVERRIDE:
			result = facade.set_cell_tax_override_basis_points(_player_country_handle,
				int(args.cell), int(args.kind), StringName(args.item_id),
				_tax_rate_basis_points(args), effective_day, sequence,
				_tax_assessment_mode(args))
		COMMAND_CELL_TAX_CLEAR_OVERRIDE:
			result = facade.clear_cell_tax_override(_player_country_handle,
				int(args.cell), int(args.kind), StringName(args.item_id),
				effective_day, sequence)
		COMMAND_CELL_TAX_CLEAR_ALL:
			result = facade.clear_cell_tax_policy(_player_country_handle,
				int(args.cell), effective_day, sequence)
		COMMAND_CONSTRUCTION_BUILD:
			if _economy_facade == null or not _economy_facade.has_method(
					"treasury_sponsored_build"):
				result = _result(false, "runtime_unavailable", "经济系统尚未就绪，请稍后再试。")
			else:
				result = _economy_facade.treasury_sponsored_build(
					_player_country_handle, int(args.get("cell_idx", -1)),
					StringName(args.get("building_id", &"")), effective_day, sequence,
					StringName(args.get("ownership_policy", &"")))
		COMMAND_FAMILY_COLONIZATION_START:
			result = _economy_facade.start_family_colonization(
				_player_country_handle, int(args.get("family_handle", 0)),
				int(args.get("source_cell", -1)), int(args.get("target_cell", -1)),
				int(args.get("population", 0)), int(args.get("quote_token", 0)),
				effective_day, sequence)
		COMMAND_FAMILY_COLONIZATION_CANCEL:
			result = _economy_facade.cancel_family_colonization(
				_player_country_handle, int(args.get("expedition_handle", 0)),
				effective_day, sequence)
		COMMAND_ERA_REWARD_CHOOSE:
			result = facade.choose_era_reward(
				int(args.get("offer_generation", 0)),
				int(args.get("choice_index", -1)), effective_day)
			# The clock is still paused from OPEN; any caller (not just the
			# modal) must re-sync so a day-advance settlement can start.
			if bool(result.get("ok", false)):
				call_deferred("_sync_era_reward_offer")
		COMMAND_FAMILY_FOUNDING_CHOOSE:
			result = _economy_facade.submit_family_founding_choice(
				int(args.get("offer_id", 0)), int(args.get("generation", 0)),
				int(args.get("choice_index", -1)), effective_day)
			if not bool(result.get("ok", false)):
				result["code"] = String(result.get("reason", "command_rejected"))
				result["message"] = "家族扶持选择未被接受，请重试。"
			else:
				result["message"] = "已选定扶持家族，将在下一次经济结算时立族。"
		COMMAND_IDEOLOGY_OFFER:
			result = _ideology_facade.request_offer(
				_player_country_handle, effective_day, sequence)
			if bool(result.get("ok", false)):
				_begin_ideology_draw("offer", sequence)
		COMMAND_IDEOLOGY_CHOOSE:
			result = _ideology_facade.choose_offer(_player_country_handle,
				int(args.get("offer_generation", 0)),
				int(args.get("choice_index", -1)), effective_day, sequence)
			if bool(result.get("ok", false)):
				_begin_ideology_draw("choose", sequence)
		COMMAND_IDEOLOGY_REROLL:
			result = _ideology_facade.reroll_offer(_player_country_handle,
				int(args.get("offer_generation", 0)), effective_day, sequence)
			if bool(result.get("ok", false)):
				_begin_ideology_draw("reroll", sequence)
		COMMAND_IDEOLOGY_EQUIP:
			result = _ideology_facade.equip(_player_country_handle,
				int(args.get("ideology_id", -1)), effective_day, sequence)
		COMMAND_IDEOLOGY_UNEQUIP:
			result = _ideology_facade.unequip(_player_country_handle,
				int(args.get("ideology_id", -1)), effective_day, sequence)
		COMMAND_IDEOLOGY_PROMOTE:
			result = _ideology_facade.promote(_player_country_handle,
				int(args.get("ideology_id", -1)), effective_day, sequence)
		COMMAND_ERA_ADVANCE_START:
			result = _era_advancement.start(effective_day, sequence)
		COMMAND_ERA_ADVANCE_PAUSE:
			result = _era_advancement.pause(effective_day, sequence)
		COMMAND_ERA_ADVANCE_RESUME:
			result = _era_advancement.resume(effective_day, sequence)
		COMMAND_PROCUREMENT_SET_POLICY:
			result = _era_advancement.set_policy(int(args.get("treasury_share_bp", -1)),
				int(args.get("research_share_bp", -1)), effective_day, sequence,
				int(args.get("era_share_bp", EraAdvancementServiceScript.SHARE_UNSET)),
				int(args.get("colonization_share_bp",
					EraAdvancementServiceScript.SHARE_UNSET)))
		COMMAND_NARRATIVE_CHOOSE:
			result = _narrative_service.choose_option(
				int(args.get("offer_id", -1)),
				int(args.get("offer_generation", -1)),
				int(args.get("option_index", -1)),
				effective_day,
				Callable(self, "_allocate_command_sequence")
			)
		_:
			if id == COMMAND_MILITARY_STATE_BUILD:
				result = _submit_state_build_command(args, effective_day, sequence)
			elif id == COMMAND_MILITARY_STATE_DEMOLISH:
				result = _submit_state_demolish_command(args, effective_day, sequence)
			elif MILITARY_COMMANDS.has(id):
				result = _submit_military_command(id, args, effective_day, sequence)
			else:
				result = _result(false, "unsupported_command", "该正式玩家命令尚未开放。")
	if not result.has("ok"):
		result["ok"] = false
	if not result.has("code"):
		result["code"] = "command_rejected" if not bool(result.get("ok", false)) else "ok"
	if id == COMMAND_CONSTRUCTION_BUILD and bool(result.get("ok", false)):
		result["code"] = "queued"
		result["message"] = "修建命令已排队，将在下一个经济结算边界执行。"
	if (id == COMMAND_FAMILY_COLONIZATION_START or \
			id == COMMAND_FAMILY_COLONIZATION_CANCEL) \
			and bool(result.get("ok", false)):
		var queued_code := String(result.get("code", ""))
		if queued_code == "colonization_queued":
			result["message"] = "派遣已排队，将在经济结算完成后出发。"
		elif queued_code == "colonization_cancel_queued":
			result["message"] = "取消已排队，将在经济结算完成后执行。"
	if (id == COMMAND_FAMILY_COLONIZATION_START or \
			id == COMMAND_FAMILY_COLONIZATION_CANCEL) \
			and not bool(result.get("ok", false)):
		var colonize_code := String(result.get("code", ""))
		if colonize_code == "economy_busy_retry":
			result["message"] = "经济正在结算。可先排队，提交完成后会自动%s。" % \
				("派遣" if id == COMMAND_FAMILY_COLONIZATION_START else "取消")
		elif String(result.get("message", "")).strip_edges().is_empty():
			result["message"] = _colonization_command_message(colonize_code)
	if not result.has("message"):
		result["message"] = String(result.get("reason", ""))
	result["effective_day"] = effective_day
	result["sequence"] = sequence
	return _complete_command(id, result)


func get_family_colonization_quotes(target_cell: int, family_filter: int = 0,
		source_filter: int = -1, offset: int = 0, limit: int = 64) -> Dictionary:
	var ready := _resolve_player_country()
	if not bool(ready.get("ok", false)):
		return ready
	if _economy_facade == null:
		return _result(false, "runtime_unavailable", "经济系统尚未就绪，请稍后再试。")
	return _economy_facade.family_colonization_quotes(_player_country_handle,
		target_cell, family_filter, source_filter, offset, limit)


func get_family_colonization_quote_detail(quote_token: int,
		population: int = -1) -> Dictionary:
	var ready := _resolve_player_country()
	if not bool(ready.get("ok", false)):
		return ready
	var detail: Dictionary = _economy_facade.family_colonization_quote_detail(
		quote_token, population)
	if bool(detail.get("ok", false)) and int(detail.get(
			"country_handle", 0)) != _player_country_handle:
		return _result(false, "colonization_quote_forbidden", "报价不属于玩家国家。")
	return detail


func get_family_dispatch_candidates(source_cell: int, offset: int = 0,
		limit: int = 64) -> Dictionary:
	var ready := _resolve_player_country()
	if not bool(ready.get("ok", false)):
		return ready
	var owned := _validate_owned_cell(ready.facade, source_cell)
	if not bool(owned.get("ok", false)):
		return owned
	if _economy_facade == null:
		return _result(false, "runtime_unavailable", "经济系统尚未就绪，请稍后再试。")
	return _economy_facade.family_cell_snapshot(source_cell, offset, limit)


func get_family_dispatch_preview(family_handle: int, source_cell: int) -> Dictionary:
	var offset := 0
	var branch := {}
	while true:
		var page := get_family_dispatch_candidates(source_cell, offset, 256)
		if not bool(page.get("ok", false)):
			return page
		var handles: PackedInt64Array = page.get("family_handles", PackedInt64Array())
		var index := handles.find(family_handle)
		if index >= 0:
			for key in ["populations", "cash_claims", "owned_buildings", "prestige_levels", "family_names"]:
				var values: Variant = page.get(key, [])
				if index < values.size():
					branch[key] = values[index]
			break
		if not bool(page.get("has_more", false)) or handles.is_empty():
			return _result(false, "colonization_population_insufficient", "该城已没有此家族的分支。")
		offset += handles.size()
	var traits: Dictionary = _economy_facade.get_family_traits(family_handle)
	return {"ok": true, "branch": branch,
		"traits": traits,
		"behavior_rows": CellInspectorViewModel.family_behavior_rows_for_cell(
			traits, _economy_facade, source_cell),
		"effects": _economy_facade.get_family_branch_effects(family_handle, source_cell)}


func can_family_colonize_from(family_handle: int, source_cell: int) -> bool:
	# 只检查真实当地分支，路线和物资仍由选点后的原生报价决定。
	var offset := 0
	while true:
		var page := get_family_dispatch_candidates(source_cell, offset, 256)
		if not bool(page.get("ok", false)):
			return false
		var handles: PackedInt64Array = page.get("family_handles", PackedInt64Array())
		var people: PackedInt64Array = page.get("populations", PackedInt64Array())
		var index := handles.find(family_handle)
		if index >= 0:
			return index < people.size() and people[index] > 1
		if not bool(page.get("has_more", false)) or handles.is_empty():
			return false
		offset += handles.size()
	return false


func dispatch_cell_display_name(cell: int) -> String:
	if _economy_facade == null or cell < 0:
		return "待选择"
	if not is_player_owned_cell(cell):
		if _runtime_host == null or _runtime_host.current_map() == null \
				or VisionSolver.fog_state(_runtime_host.current_map(), cell) != VisionSolver.FOG_VISIBLE:
			return "待选择"
	return _economy_facade.settlement_display_name(cell)


func get_family_expeditions(offset: int = 0, limit: int = 64) -> Dictionary:
	var ready := _resolve_player_country()
	if not bool(ready.get("ok", false)):
		return ready
	return _economy_facade.family_expeditions(_player_country_handle,
		offset, limit)


func get_family_expedition_snapshot(expedition_handle: int) -> Dictionary:
	var ready := _resolve_player_country()
	if not bool(ready.get("ok", false)):
		return ready
	return _economy_facade.family_expedition_snapshot(_player_country_handle,
		expedition_handle)


func good_display_name(good_index: int) -> String:
	if _economy_facade != null and _economy_facade.has_method("good_display_name"):
		return String(_economy_facade.good_display_name(good_index))
	return "物资#%d" % good_index


func get_family_snapshot(family_handle: int) -> Dictionary:
	if _economy_facade == null:
		return _result(false, "runtime_unavailable", "经济系统尚未就绪，请稍后再试。")
	return _economy_facade.family_snapshot(family_handle)


func get_family_traits(family_handle: int) -> Dictionary:
	if _economy_facade == null:
		return _result(false, "runtime_unavailable", "经济系统尚未就绪，请稍后再试。")
	return _economy_facade.get_family_traits(family_handle)


func is_player_owned_cell(cell: int) -> bool:
	var ready := _resolve_player_country()
	return bool(ready.get("ok", false)) and bool(
		_validate_owned_cell(ready.facade, cell).get("ok", false))


## ─── 触屏 GM 手势：三指双击 ──────────────────────────────────────────
## 安卓没有 F1/` 键，GM 面板以前只能在桌面上开。这里用「三指同时按下再松开」当一次
## tap，两次 tap 间隔 ≤800ms、每次按住 ≤450ms 就切 GM。两指缩放/单指拖动都不会命中。
## 只在 debug 构建且 GM 可用时生效（release 包 is_gm_available() 为 false）。
const TOUCH_GM_TAP_MAX_MS := 450
const TOUCH_GM_DOUBLE_WINDOW_MS := 800
var _touch_gm_active: Dictionary = {}
var _touch_gm_armed_ms := 0
var _touch_gm_tap_times: PackedInt64Array = PackedInt64Array()


func _handle_touch_gm_gesture(event: InputEvent) -> bool:
	var touch := event as InputEventScreenTouch
	if touch == null:
		return false
	if touch.pressed:
		_touch_gm_active[touch.index] = true
		if _touch_gm_active.size() == 3 and _touch_gm_armed_ms == 0:
			_touch_gm_armed_ms = Time.get_ticks_msec()
		return false
	_touch_gm_active.erase(touch.index)
	if not _touch_gm_active.is_empty():
		return false
	if _touch_gm_armed_ms == 0:
		return false
	var duration := Time.get_ticks_msec() - _touch_gm_armed_ms
	_touch_gm_armed_ms = 0
	if duration > TOUCH_GM_TAP_MAX_MS:
		return false
	var now := Time.get_ticks_msec()
	var recent := PackedInt64Array()
	for stamp in _touch_gm_tap_times:
		if now - stamp <= TOUCH_GM_DOUBLE_WINDOW_MS:
			recent.append(stamp)
	recent.append(now)
	_touch_gm_tap_times = recent
	if _touch_gm_tap_times.size() < 2:
		return false
	_touch_gm_tap_times.clear()
	_toggle_gm_from_gesture()
	return true


func _toggle_gm_from_gesture() -> void:
	if _ui_manager == null:
		return
	if not _ui_manager.is_gm_available():
		print("[input] 三指双击：当前构建 GM 面板不可用（release 包）")
		return
	_ui_manager.toggle_gm_panel()
	print("[input] 三指双击 → GM 面板")


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_GO_BACK_REQUEST:
		if _annual_report_flow.is_open():
			if _ui_manager != null:
				_ui_manager.dismiss_overlay_menu()
			return
		if _ui_manager != null and not _ui_manager.dismiss_overlay_menu():
			_ui_manager.toggle_pause_menu()


func _unhandled_input(event: InputEvent) -> void:
	# GUI 已消费的事件不会到这里。文本框必须继续挡住地图手势；
	# 普通按钮焦点不得锁死选格/缩放/拖拽，否则左侧 overlay 点完就无法操作地图。
	if _is_text_editing():
		return
	if _handle_touch_gm_gesture(event):
		get_viewport().set_input_as_handled()
		return
	if _is_world_pointer_event(event):
		_release_ordinary_ui_focus()
	_dispatch_player_input(event)


func handle_input(event: InputEvent) -> void:
	# Direct dispatch from PlayerGame / tests / embedded tools. Ordinary Control
	# focus still blocks this path so UI cannot be bypassed by calling us.
	if _is_input_blocked_by_ui():
		return
	_dispatch_player_input(event)


func _dispatch_player_input(event: InputEvent) -> void:
	if not _military_order_mode.is_empty():
		var cancel_key := event is InputEventKey and event.is_pressed() \
			and not event.is_echo() and (event.is_action_pressed(&"player_cancel") \
			or event.is_action_pressed(&"ui_cancel"))
		var cancel_mouse: bool = event is InputEventMouseButton and event.is_pressed() \
			and event.button_index == MOUSE_BUTTON_RIGHT
		if cancel_key or cancel_mouse:
			cancel_military_arm_order()
			get_viewport().set_input_as_handled()
			return
	if _annual_report_flow.is_open():
		if event.is_action_pressed(&"player_cancel") or event.is_action_pressed(&"ui_cancel"):
			_ui_manager.dismiss_overlay_menu()
		get_viewport().set_input_as_handled()
		return
	if _camera != null and _camera.handle_player_input(event):
		get_viewport().set_input_as_handled()
		return
	if not (event is InputEventKey) or not event.pressed or event.echo:
		return
	var key := event as InputEventKey
	var debug_hotkeys_enabled := OS.is_debug_build()
	if key.is_action_pressed(&"player_pause"):
		if _annual_report_flow.is_open():
			get_viewport().set_input_as_handled()
		elif _family_founding_locked or _era_reward_locked:
			get_viewport().set_input_as_handled()
		elif ideology_draw_locked():
			get_viewport().set_input_as_handled()
		elif _world_clock != null:
			_world_clock.toggle_pause()
			sync_ui()
			get_viewport().set_input_as_handled()
	elif key.is_action_pressed(&"player_cancel"):
		if _ui_manager != null and not _ui_manager.dismiss_overlay_menu():
			_ui_manager.toggle_pause_menu()
		get_viewport().set_input_as_handled()
	elif key.is_action_pressed(&"player_fit_view"):
		if debug_hotkeys_enabled and _runtime_host != null and _ui_manager != null:
			_runtime_host.fit_camera(_ui_manager.map_safe_area())
			get_viewport().set_input_as_handled()
	elif key.is_action_pressed(&"player_regenerate"):
		# Regeneration remains a scene-lifecycle concern and is intentionally not
		# exposed through the formal player command surface.
		if debug_hotkeys_enabled:
			regeneration_requested.emit()
			get_viewport().set_input_as_handled()
	elif key.keycode == KEY_QUOTELEFT \
			or key.is_action_pressed(&"player_open_gm"):
		if debug_hotkeys_enabled and _ui_manager != null and _ui_manager.is_gm_available():
			_ui_manager.toggle_gm_panel()
			get_viewport().set_input_as_handled()
	elif key.is_action_pressed(&"player_perf_hud"):
		if debug_hotkeys_enabled and _ui_manager != null:
			_ui_manager.toggle_perf_hud()
			get_viewport().set_input_as_handled()
	elif key.keycode == KEY_Y and not (key.ctrl_pressed or key.alt_pressed or key.meta_pressed):
		# 资源透镜：把世界里的资源/物种实景切换为统一的识别徽章，便于一眼找到产区。
		var renderer: Node = _runtime_host.get_renderer() if _runtime_host != null else null
		if renderer != null and renderer.has_method("set_resource_visual_lens"):
			renderer.set_resource_visual_lens(not renderer.resource_visual_lens_enabled())
			get_viewport().set_input_as_handled()


func _connect_runtime() -> void:
	if _camera != null and not _camera.tile_tapped.is_connected(_on_tile_tapped):
		_camera.tile_tapped.connect(_on_tile_tapped)
	if _camera != null and _camera.has_signal("zoom_changed") \
			and not _camera.zoom_changed.is_connected(_on_camera_zoom_changed):
		_camera.zoom_changed.connect(_on_camera_zoom_changed)
	if _camera != null and _camera.has_signal("view_changed") \
			and not _camera.view_changed.is_connected(_on_camera_view_changed):
		_camera.view_changed.connect(_on_camera_view_changed)
	if _runtime_host != null and _runtime_host.has_signal("simulation_committed") \
			and not _runtime_host.simulation_committed.is_connected(_on_simulation_committed):
		_runtime_host.simulation_committed.connect(_on_simulation_committed)
	if _runtime_host != null and _runtime_host.has_signal("country_peer_serviced") \
			and not _runtime_host.country_peer_serviced.is_connected(_on_country_peer_serviced):
		_runtime_host.country_peer_serviced.connect(_on_country_peer_serviced)
	if _world_clock == null:
		return
	if not _world_clock.day_changed.is_connected(_on_day_changed):
		_world_clock.day_changed.connect(_on_day_changed)
	if not _world_clock.season_changed.is_connected(_on_season_changed):
		_world_clock.season_changed.connect(_on_season_changed)
	if not _world_clock.year_changed.is_connected(_on_year_changed):
		_world_clock.year_changed.connect(_on_year_changed)
	if not _world_clock.visual_day_phase_changed.is_connected(_on_visual_day_phase_changed):
		_world_clock.visual_day_phase_changed.connect(_on_visual_day_phase_changed)
	if not _world_clock.speed_changed.is_connected(_on_speed_changed):
		_world_clock.speed_changed.connect(_on_speed_changed)


func _on_simulation_committed(_from_day: int, to_day: int, _generation: int) -> void:
	# ACTIVE worker commits are display-only on the Godot side. The worker owns
	# the authoritative date; this callback refreshes only lightweight UI state.
	if _runtime_host == null or _world_clock == null:
		return
	_sync_time_ui()
	if _ui_manager != null and _selected_cell != null:
		_ui_manager.refresh_selected_daily_lines(false, to_day)
	if _ui_manager != null and _ui_manager.has_method("notify_committed_day"):
		_ui_manager.notify_committed_day()
	if _music_situation != null:
		_music_situation.refresh_global_from_commit()
	_sync_era_reward_offer()
	_sync_family_founding_offer()
	# ACTIVE worker days settle here before Godot's own day signal.
	_sync_ideology_draw()
	_sync_era_music()
	_sync_event_audio()
	_refresh_era_advancement()
	_step_narrative_daily(to_day)
	_annual_report_flow.try_present()
	_narrative_flow.try_present()


func _on_country_peer_serviced(report: Dictionary) -> void:
	# Era reward planning is completed while the host drains Country peer
	# intents, after the worker commit signal has already been published.
	# 里程碑通知可能单独送达，此时没有普通 peer intent 但仍须立即打开弹窗。
	if int(report.get("inspected", 0)) <= 0 and int(report.get("notified", 0)) <= 0:
		return
	_sync_era_reward_offer()
	_sync_family_founding_offer()


func _connect_ui() -> void:
	if _ui_manager == null:
		return
	if not _ui_manager.pause_toggled.is_connected(_on_pause_toggled):
		_ui_manager.pause_toggled.connect(_on_pause_toggled)
	if not _ui_manager.speed_selected.is_connected(_on_speed_selected):
		_ui_manager.speed_selected.connect(_on_speed_selected)
	if not _ui_manager.clear_selection_requested.is_connected(clear_selection):
		_ui_manager.clear_selection_requested.connect(clear_selection)
	if not _ui_manager.pause_menu_visibility_changed.is_connected(_on_pause_menu_visibility_changed):
		_ui_manager.pause_menu_visibility_changed.connect(_on_pause_menu_visibility_changed)
	if _ui_manager.has_signal("era_reward_choice_requested") and not \
			_ui_manager.era_reward_choice_requested.is_connected(
				_on_era_reward_choice_requested):
		_ui_manager.era_reward_choice_requested.connect(
			_on_era_reward_choice_requested)
	if not _ui_manager.era_reward_open_requested.is_connected(open_era_reward_offer):
		_ui_manager.era_reward_open_requested.connect(open_era_reward_offer)
	if not _ui_manager.era_reward_dismiss_requested.is_connected(dismiss_era_reward_offer):
		_ui_manager.era_reward_dismiss_requested.connect(dismiss_era_reward_offer)
	if _ui_manager.has_signal("family_founding_choice_requested") and not \
			_ui_manager.family_founding_choice_requested.is_connected(
				_on_family_founding_choice_requested):
		_ui_manager.family_founding_choice_requested.connect(
			_on_family_founding_choice_requested)
	_ui_manager.set_player_controller(self)
	refresh_country_binding()


func _on_tile_tapped(world_pos: Vector2) -> void:
	if _runtime_host == null or _runtime_host.current_map() == null:
		return
	var cell: Variant = HexUtils.world_to_wrapped_cell(_runtime_host.current_map(), world_pos,
		_runtime_host.hex_size)
	# 议和窗口开着时地图就是「交割选格」：部队/战线拾取必须让路，否则停在候选格上的
	# 部队棋子会先抢走这次点击。
	if cell != null and _peace_window_open():
		select_cell(cell)
		return
	# 部队指令模式下地图点击是目标格，保持旧语义；否则先给军务档案一次拾取机会。
	if _military_order_mode.is_empty() and cell != null and military_map_pick(world_pos):
		return
	if cell != null:
		select_cell(cell)


## True while the peace window owns map clicks (see select_cell / _on_tile_tapped).
func _peace_window_open() -> bool:
	return _ui_manager != null and _ui_manager.has_method("is_peace_window_open") \
		and bool(_ui_manager.call("is_peace_window_open"))


## 军务档案拾取入口：命中部队/战线时打开右栏档案并返回 true（本次点击不再选格）。
## 拾取本身在图层里完成（token / front 各自拥有几何），这里只转发与接线。
func military_map_pick(world: Vector2) -> bool:
	if _ui_manager == null or not _ui_manager.has_method("open_military_dossier"):
		return false
	var layers = _military_layers()
	if layers == null or not layers.has_method("pick_at_world"):
		return false
	var pick: Dictionary = layers.pick_at_world(world)
	match String(pick.get("kind", "")):
		"army":
			var handle := int(pick.get("handle", 0))
			if handle == 0:
				return false
			_apply_military_render_selection(handle)
			if layers.has_method("set_selected_cell"):
				layers.call("set_selected_cell", int(pick.get("cell", -1)))
			return bool(_ui_manager.call("open_military_dossier", "army", handle,
				int(pick.get("cell", -1))))
		"front":
			var edge := int(pick.get("edge", -1))
			if edge < 0:
				return false
			_apply_military_render_selection(0)
			if layers.has_method("set_selected_front_edge"):
				layers.call("set_selected_front_edge", edge)
			return bool(_ui_manager.call("open_military_dossier", "front", edge))
	return false


## 军务档案的战线扇区：几何与聚合都在图层侧，UI 只消费结果。
func military_front_sector(edge_key: int) -> Dictionary:
	var layers = _military_layers()
	if layers == null or not layers.has_method("front_sector"):
		return {}
	return layers.call("front_sector", int(edge_key))


## 同格部队（军务档案「同格部队」名录）。空数组 = 该格只有这一支或图层未就绪。
func military_armies_at_cell(cell: int) -> Array:
	var layers = _military_layers()
	if layers == null or not layers.has_method("armies_at_cell"):
		return []
	var rows = layers.call("armies_at_cell", int(cell))
	return rows if rows is Array else []


## 部队所在格（-1 = 未知）。换页时用来留住「同格部队」名录。
func military_army_cell(handle: int) -> int:
	var layers = _military_layers()
	if layers == null or not layers.has_method("army_cell"):
		return -1
	return int(layers.call("army_cell", int(handle)))


## 关掉档案时同时撤掉地图上的选中态（部队选中环 / 战线高亮 / 区域与路线层）。
func clear_military_map_selection() -> void:
	_apply_military_render_selection(0)
	var layers = _military_layers()
	if layers == null:
		return
	if layers.has_method("set_selected_front_edge"):
		layers.call("set_selected_front_edge", -1)
	if layers.has_method("set_selected_cell"):
		layers.call("set_selected_cell", -1)


## 把某一格移进地图安全区（不改变选中态）。军务档案打开后用它把实体带进视野。
func focus_cell(cell: int) -> void:
	if _runtime_host == null or _camera == null or _ui_manager == null or cell < 0:
		return
	var map = _runtime_host.current_map()
	if map == null:
		return
	var cell_obj = map.cell_at(int(cell))
	if cell_obj == null:
		return
	_camera.ensure_point_visible(_cell_display_world(cell_obj),
		_ui_manager.map_safe_area())


func get_country_facade():
	return _country_facade


func get_economy_facade():
	return _economy_facade


func get_player_country_handle() -> int:
	return _player_country_handle


func _on_country_committed(report: Dictionary) -> void:
	country_committed.emit(report)
	_sync_era_reward_offer()
	_sync_family_founding_offer()
	_sync_era_music()
	# Country ACK of advance_era raises current_era_index here.
	_refresh_era_advancement(true)


func _on_construction_command_settled(result: Dictionary) -> void:
	if int(result.get("country_handle", 0)) != _player_country_handle:
		return
	command_settled.emit(COMMAND_CONSTRUCTION_BUILD, result)


func _on_family_colonization_settled(result: Dictionary) -> void:
	if int(result.get("country_handle", 0)) != _player_country_handle:
		return
	var command_id := COMMAND_FAMILY_COLONIZATION_CANCEL \
		if String(result.get("code", "")) == "CANCELLED_RETURNING" \
		else COMMAND_FAMILY_COLONIZATION_START
	command_settled.emit(command_id, result)

func _on_ideology_command_settled(result: Dictionary) -> void:
	if int(result.get("country_handle", 0)) != _player_country_handle:
		return
	var command_id := {
		3: COMMAND_IDEOLOGY_OFFER,
		4: COMMAND_IDEOLOGY_CHOOSE,
		5: COMMAND_IDEOLOGY_EQUIP,
		6: COMMAND_IDEOLOGY_UNEQUIP,
		7: COMMAND_IDEOLOGY_PROMOTE,
		10: COMMAND_IDEOLOGY_REROLL,
	}.get(int(result.get("opcode", 0)), &"ideology.unknown") as StringName
	if ideology_draw_locked() and int(result.get("sequence", -2)) == _ideology_draw_sequence:
		if not bool(result.get("ok", false)):
			_finish_ideology_draw(String(result.get("reason", "ideology_command_rejected")))
		else:
			_sync_ideology_draw()
	command_settled.emit(command_id, result)



## 事件音效与交互式音乐用的增量状态
var _territory_snapshot := -1
var _last_music_pop_sample_ms := 0
var _camera_zoom_baseline := -1.0
var _camera_zoom_user_engaged := false
const MUSIC_POP_SAMPLE_INTERVAL_MS := 500

## 时代推进与国家人口驱动交互式配乐组曲（石器/农耕/王国/帝国）。
func _sync_era_music(force_population_sync: bool = false) -> void:
	if _player_country_handle == 0 or _country_facade == null:
		return
	if not _country_facade.has_method("current_era_index"):
		return
	var audio := get_node_or_null("/root/GameAudio")
	if audio == null or not audio.has_method("set_era"):
		return
	var prev_era: int = int(audio.era_index()) if audio.has_method("era_index") else -1
	var era_index: int = _country_facade.current_era_index(_player_country_handle)
	if era_index >= 0:
		audio.set_era(era_index)
	var era_changed := era_index >= 0 and era_index != prev_era
	if (force_population_sync or era_changed) and _camera != null:
		_sync_camera_zoom_audio(force_population_sync and prev_era < 0)
	if _economy_facade != null and _economy_facade.has_method("country_economy_overview") \
			and audio.has_method("update_active_suite_population_count"):
		var now_ms := Time.get_ticks_msec()
		if force_population_sync or era_changed \
				or _last_music_pop_sample_ms == 0 \
				or now_ms - _last_music_pop_sample_ms >= MUSIC_POP_SAMPLE_INTERVAL_MS:
			var summary: Dictionary = _economy_facade.country_economy_overview(
				_player_country_handle, "summary")
			if bool(summary.get("ok", false)):
				_last_music_pop_sample_ms = now_ms
				audio.update_active_suite_population_count(int(summary.get("population", 0)))


func _sync_camera_zoom_audio(reset_baseline: bool = false) -> void:
	if _camera == null:
		return
	var zoom_val: float = float(_camera.zoom.x) if "zoom" in _camera else 1.0
	if reset_baseline:
		_camera_zoom_baseline = zoom_val
		_camera_zoom_user_engaged = false
		var audio := get_node_or_null("/root/GameAudio")
		if audio != null and audio.has_method("set_active_suite_camera_zoom"):
			audio.set_active_suite_camera_zoom(0.5, true)
		return
	_on_camera_zoom_changed(zoom_val)


func _on_camera_zoom_changed(zoom_val: float) -> void:
	var audio := get_node_or_null("/root/GameAudio")
	if audio == null or not audio.has_method("set_active_suite_camera_zoom"):
		return
	if not _camera_zoom_user_engaged:
		if _camera_zoom_baseline < 0.0:
			_camera_zoom_baseline = zoom_val
		if absf(zoom_val - _camera_zoom_baseline) <= 0.02:
			return
		_camera_zoom_user_engaged = true
	var min_z := 0.55
	var max_z := 3.6
	if _camera != null:
		if _camera.has_method("_minimum_zoom"):
			min_z = clampf(float(_camera._minimum_zoom()), 0.25, 1.2)
		elif "zoom_min" in _camera:
			min_z = maxf(0.35, float(_camera.zoom_min))
		if "zoom_max" in _camera:
			max_z = maxf(min_z + 0.6, minf(float(_camera.zoom_max), 4.0))
	audio.set_active_suite_camera_zoom(
		camera_zoom_to_audio_ratio(zoom_val, min_z, max_z), false)
	if _music_situation != null and _camera != null and _camera.has_method("current_world_view_rect"):
		_music_situation.refresh_local_from_view(
			_camera.current_world_view_rect(),
			camera_zoom_to_audio_ratio(zoom_val, min_z, max_z))


func _on_camera_view_changed(world_rect: Rect2, _center: Vector2, zoom_value: float) -> void:
	if _music_situation == null:
		return
	var min_z := 0.55
	var max_z := 3.6
	if _camera != null:
		if _camera.has_method("_minimum_zoom"):
			min_z = clampf(float(_camera._minimum_zoom()), 0.25, 1.2)
		if "zoom_max" in _camera:
			max_z = maxf(min_z + 0.6, minf(float(_camera.zoom_max), 4.0))
	_music_situation.refresh_local_from_view(
		world_rect, camera_zoom_to_audio_ratio(zoom_value, min_z, max_z))


func music_camera_zoom_ratio() -> float:
	if _camera == null:
		return 0.5
	var min_z := 0.55
	var max_z := 3.6
	if _camera.has_method("_minimum_zoom"):
		min_z = clampf(float(_camera._minimum_zoom()), 0.25, 1.2)
	if "zoom_max" in _camera:
		max_z = maxf(min_z + 0.6, minf(float(_camera.zoom_max), 4.0))
	return camera_zoom_to_audio_ratio(float(_camera.zoom.x), min_z, max_z)


## 将 Camera2D 的缩放倍率（越大越近、越小越远）映射为 FMOD CameraZoom 参数（0.0=拉近近景 .. 1.0=拉远苍穹）。
static func camera_zoom_to_audio_ratio(zoom_val: float,
		min_zoom: float = 0.55, max_zoom: float = 3.6) -> float:
	var lo := maxf(0.1, min_zoom)
	var hi := maxf(lo + 0.2, max_zoom)
	var clamped := clampf(zoom_val, lo, hi)
	var t := inverse_lerp(log(lo), log(hi), log(clamped))
	return clampf(1.0 - t, 0.0, 1.0)



## 理念音效：抽（offer/choose/reroll）与用（equip/unequip/promote）分开。
## 只在成功时发声，被拒绝的命令不响。
## 日常游戏事件音效：经济 trace 流自带消费游标，不遍历全图。
##   贸易 / 人口 → 经济 trace 流；建筑由可见地图活动层播放。
##   科技/理念 → GameUIManager 的完成通知与命令回执，避免日切重复播放。
##   开拓      → diff territory_cells.size()
func _sync_event_audio() -> void:
	if _player_country_handle == 0:
		return
	var audio := get_node_or_null("/root/GameAudio")
	if audio == null or not audio.has_method("play_event_cue"):
		return

	# 贸易：经济事件流 kind 13 = TRADE_ARRIVED。
	# 建筑不走这里 —— map_activity_layer 的 build 活动已经带屏幕过滤，
	# 两处都接会在同一栋建筑落成时响两声。
	if _economy_facade != null and _economy_facade.has_method("poll_events"):
		var trade: Dictionary = _economy_facade.poll_events(&"pk_sfx_trade", 32, 13)
		if int(trade.get("count", 0)) > 0:
			audio.play_event_cue(&"trade")
		# 人口：原生市场级 births/deaths 事件（EVENT_POPULATION_CHANGED = 16）。
		# 逐格出生分摊在 market 结算内部，这里拿到市场级汇总，配 2.5s 冷却足够。
		var pop: Dictionary = _economy_facade.poll_events(&"pk_sfx_pop", 32, 16)
		if int(pop.get("count", 0)) > 0:
			audio.play_event_cue(&"population_grow")
	# _player_controller_build_removed

	# 开拓：领土格数变多
	if _country_facade != null and _country_facade.has_method("snapshot"):
		var snapshot: Dictionary = _country_facade.snapshot(_player_country_handle)
		var cells: PackedInt32Array = snapshot.get("territory_cells", PackedInt32Array())
		if not cells.is_empty():
			if _territory_snapshot >= 0 and cells.size() > _territory_snapshot:
				audio.play_event_cue(&"territory_expand")
			_territory_snapshot = cells.size()


func _on_day_changed(day_idx: int) -> void:
	if _runtime_host == null or _world_clock == null:
		return
	# WorldRuntimeHost owns the single OFF/SHADOW daily authority and receives
	# this clock signal before the controller. The controller only refreshes
	# presentation state; keeping simulation out of this callback prevents a
	# second SUS invocation when a worker commit is introduced.
	_sync_era_reward_offer()
	_sync_family_founding_offer()
	_sync_ideology_draw()
	_sync_era_music()
	_sync_event_audio()
	_refresh_era_advancement()
	_step_narrative_daily(day_idx)
	if _music_situation != null:
		_music_situation.refresh_global_from_commit()
	if _economy_facade != null and _player_country_handle != 0 and \
			_economy_facade.has_method("dispatch_family_colonization_receipts"):
		_economy_facade.dispatch_family_colonization_receipts(
			_player_country_handle)
	var ui_started_usec := Time.get_ticks_usec()
	var ui_breakdown: Dictionary = {}
	if _ui_manager != null:
		ui_breakdown = _ui_manager.refresh_selected_daily_lines(false, day_idx)
		if _ui_manager.has_method("notify_committed_day"):
			_ui_manager.notify_committed_day()
		# Country workspaces are event-driven. Daily ticks only patch the selected
		# cell and clock; country/economy/ideology commits invalidate their section.
		ui_breakdown["country_summary_ms"] = 0.0
		if _ui_manager.has_method("consume_country_ui_perf_summary"):
			var country_ui_perf: Dictionary = _ui_manager.consume_country_ui_perf_summary()
			for key in country_ui_perf:
				ui_breakdown[key] = country_ui_perf[key]
			if not country_ui_perf.is_empty():
				ui_breakdown["country_summary_ms"] = float(
					country_ui_perf.get("country_ui_snapshot_ms", 0.0))
		sync_ui()
	_runtime_host.finish_daily_tick((Time.get_ticks_usec() - ui_started_usec) / 1000.0, ui_breakdown)


func _on_season_changed(season_idx: int) -> void:
	if _runtime_host != null:
		_runtime_host.on_season_changed(season_idx)
	if _ui_manager != null:
		_ui_manager.refresh_selected_daily_lines(true)
	sync_ui()


func _on_year_changed(year_idx: int) -> void:
	if _runtime_host != null:
		_runtime_host.on_year_changed(year_idx)
	if _ui_manager != null:
		_ui_manager.refresh_selected_daily_lines(true)
	sync_ui()


func _on_visual_day_phase_changed(phase: float) -> void:
	if _runtime_host != null:
		_runtime_host.on_visual_day_phase_changed(phase)
	_sync_time_ui()


func _on_speed_changed(speed: float) -> void:
	if _runtime_host != null:
		_runtime_host.on_speed_changed(speed)
	_sync_time_ui()


func _on_pause_toggled(paused: bool) -> void:
	if _annual_report_flow.is_open():
		return
	if _era_reward_locked:
		sync_ui()
		return
	if _world_clock == null:
		return
	if _runtime_host != null and _runtime_host.has_method("is_runtime_fault_paused") \
			and _runtime_host.is_runtime_fault_paused() and not paused:
		sync_ui()
		return
	if _family_founding_locked and not paused:
		sync_ui()
		return
	if _narrative_flow.is_locked() and not paused:
		sync_ui()
		return
	if ideology_draw_locked():
		# The draw owns the clock until its one-day settlement lands.
		sync_ui()
		return
	if _ideology_draw_phase == "presenting" and not paused:
		# The player resumed manually; drop the saved clock instead of restoring it.
		_ideology_draw_clock_saved = false
		_finish_ideology_draw("")
	_world_clock.pause(paused)
	sync_ui()


func _on_speed_selected(speed: float) -> void:
	if _world_clock == null:
		return
	if _era_reward_locked:
		sync_ui()
		return
	speed = clampf(speed, 1.0, 10.0)
	if _runtime_host != null and _runtime_host.has_method("is_runtime_fault_paused") \
			and _runtime_host.is_runtime_fault_paused():
		sync_ui()
		return
	if _family_founding_locked:
		_family_founding_previous_speed = speed
		_family_founding_resume_running = true
		sync_ui()
		return
	if ideology_draw_locked() or _ideology_draw_phase == "presenting":
		_ideology_draw_previous_speed = speed
		_ideology_draw_resume_running = true
		if _ideology_draw_phase == "presenting":
			# Picking a speed while the offer is shown means "decide later".
			_finish_ideology_draw("")
		sync_ui()
		return
	_world_clock.set_speed(speed)
	_world_clock.pause(false)
	sync_ui()


func _on_pause_menu_visibility_changed(open: bool) -> void:
	if _world_clock == null:
		return
	if open:
		_pause_before_menu = _world_clock.paused
		_world_clock.pause(true)
	else:
		if _runtime_host != null and _runtime_host.has_method("is_runtime_fault_paused") \
				and _runtime_host.is_runtime_fault_paused():
			_world_clock.pause(true)
		else:
			_world_clock.pause(_pause_before_menu)
	sync_ui()


func _sync_clock_visual_state() -> void:
	if _runtime_host != null and _world_clock != null:
		_runtime_host.on_clock_running_changed(not _world_clock.paused)


func _sync_time_ui() -> void:
	if _ui_manager == null or _world_clock == null:
		return
	var calendar_date: Dictionary = _world_clock.calendar_date()
	_ui_manager.update_time_state(_world_clock.year_index(), int(calendar_date.month),
		int(calendar_date.day_of_month), _world_clock.paused, _world_clock.speed_multiplier)


func _resolve_player_country() -> Dictionary:
	if _runtime_host == null or _world_clock == null:
		return _result(false, "runtime_unavailable", "游戏尚未就绪，请稍后再试。")
	var generator: Variant = _runtime_host.generator()
	if generator == null or not generator.has_method("gameplay_start_report") \
			or not generator.has_method("get_country_facade"):
		return _result(false, "session_unavailable", "当前不是可操作的正式玩家会话。")
	var start: Dictionary = generator.gameplay_start_report()
	var facade = generator.get_country_facade()
	var cell_idx := int(start.get("cell", -1))
	if not bool(start.get("ok", false)) or facade == null or cell_idx < 0:
		return _result(false, "session_unavailable", "当前会话没有玩家国家。")
	var summary: Dictionary = facade.cell_summary(cell_idx)
	if not bool(summary.get("ok", false)) or not bool(summary.get("owned", false)):
		return _result(false, "player_country_unavailable", "玩家国家尚未可用。")
	_player_country_handle = int(summary.get("country_handle", 0))
	if _player_country_handle == 0:
		return _result(false, "player_country_unavailable", "玩家国家句柄无效。")
	var reward_binding: Dictionary = facade.bind_era_reward_player_country(
		_player_country_handle) if facade.has_method(
			"bind_era_reward_player_country") else {"ok": false,
				"reason": "era_reward_runtime_unavailable"}
	if not bool(reward_binding.get("ok", false)):
		return _result(false, String(reward_binding.get("reason",
			"era_reward_player_bind_failed")), "玩家时代奖励身份绑定失败。")
	return {"ok": true, "code": "ok", "message": "", "facade": facade}


func _request_research_queue(facade, operation: String, args: Dictionary,
		effective_day: int, sequence: int) -> Dictionary:
	var technology_id := StringName(args.get("technology_id", &""))
	if technology_id.is_empty():
		return _result(false, "invalid_args", "缺少科技标识。")
	match operation:
		"enqueue":
			var domain := int(args.get("domain", -1))
			if domain < 0 or domain >= 4:
				return _result(false, "invalid_args", "科技领域无效。")
			return facade.enqueue_research(_player_country_handle, technology_id, domain, -1,
				effective_day, sequence)
		"remove":
			return facade.remove_research(_player_country_handle, technology_id,
				effective_day, sequence)
		"move":
			var move_domain := int(args.get("domain", -1))
			var position := int(args.get("position", -1))
			if move_domain < 0 or move_domain >= 4 or position < 0:
				return _result(false, "invalid_args", "研究队列位置无效。")
			return facade.move_research(_player_country_handle, technology_id, move_domain,
				position, effective_day, sequence)
	return _result(false, "unsupported_command", "未知研究队列操作。")


func _validate_command_args(id: StringName, args: Dictionary, facade = null) -> Dictionary:
	return PlayerCommandValidation._validate_command_args(
		_economy_facade,
		_ideology_facade,
		_era_reward_generation,
		_family_founding_offer_id,
		_family_founding_generation,
		is_milestone_technology,
		_validate_owned_cell,
		ideology_offer_eligibility,
		_era_advancement_preview,
		_military_facade,
		_completed_technology_ids,
		_state_building_gate,
		_player_owns_military_cell,
		id,
		args,
		facade)


func _on_era_reward_choice_requested(generation: int, choice_index: int) -> void:
	request_command(COMMAND_ERA_REWARD_CHOOSE, {
		"offer_generation": generation,
		"choice_index": choice_index,
	})
	_sync_era_reward_offer()
	_drain_era_reward_until_settled()


func _drain_era_reward_until_settled() -> void:
	if _era_reward_drain_active:
		return
	_era_reward_drain_active = true
	while _era_reward_locked and _era_reward_last_status == "SELECTED_PENDING":
		var generator: Variant = _runtime_host.generator() \
			if _runtime_host != null else null
		if generator == null or not generator.has_method("advance_save_boundary"):
			break
		# 复用存档协调器的无日期推进安全边界排空链。
		generator.advance_save_boundary()
		await get_tree().process_frame
		_sync_era_reward_offer()
	_era_reward_drain_active = false


func open_era_reward_offer() -> void:
	# 点击纸徽才进入暂停选择；待领奖励本身不锁住会话。
	if _popups_suppressed or _country_facade == null or _ui_manager == null or _family_founding_locked \
			or ideology_draw_locked() or _annual_report_flow.is_open():
		return
	var offer: Dictionary = _country_facade.era_reward_offer()
	if not bool(offer.get("ok", false)) or String(offer.get("status", "NONE")) not in ["OPEN", "ERROR"]:
		return
	if not _era_reward_locked:
		_era_reward_resume_running = _world_clock != null and not _world_clock.paused
		_era_reward_previous_speed = _world_clock.speed_multiplier if _world_clock != null else 1.0
		_era_reward_locked = true
	if _world_clock != null:
		_world_clock.pause(true)
	_ui_manager.show_era_reward_offer(offer)
	_sync_era_reward_offer()
	sync_ui()


func dismiss_era_reward_offer() -> void:
	# 已提交的跨领域事务必须完成 ACK；尚未选择时可以稍后领取。
	if not _era_reward_locked or _era_reward_last_status == "SELECTED_PENDING":
		return
	if _ui_manager != null:
		_ui_manager.close_era_reward_offer()
	_era_reward_locked = false
	if _world_clock != null:
		_world_clock.set_speed(_era_reward_previous_speed)
		_world_clock.pause(not _era_reward_resume_running)
	sync_ui()


func _sync_era_reward_offer() -> void:
	if _country_facade == null or not _country_facade.has_method("era_reward_offer"):
		return
	var offer: Dictionary = _country_facade.era_reward_offer()
	if not bool(offer.get("ok", false)):
		return
	var status := String(offer.get("status", "NONE"))
	_era_reward_last_status = status
	if _popups_suppressed:
		if _era_reward_locked:
			_era_reward_locked = false
			if _world_clock != null:
				_world_clock.set_speed(_era_reward_previous_speed)
				_world_clock.pause(not _era_reward_resume_running)
			if _ui_manager != null and _ui_manager.has_method("close_era_reward_offer"):
				_ui_manager.close_era_reward_offer()
		return
	if _ui_manager != null:
		_ui_manager.notify_era_reward_offer(offer)
	if status in ["OPEN", "ERROR"] and not _era_reward_locked:
		_era_reward_generation = int(offer.get("offer_generation", 0))
		era_reward_offer_changed.emit(offer)
		# 晋升一成，三选一直接推到玩家面前，不要让人再去找按钮点一次。
		# 大典还在播时先让位，下一轮同步会重试。
		var ceremony: bool = _ui_manager != null and _ui_manager.has_method("is_era_ceremony_playing") \
			and _ui_manager.is_era_ceremony_playing()
		if not ceremony:
			open_era_reward_offer()
		return
	if status == "OPEN" or status == "SELECTED_PENDING" or status == "ERROR":
		if not _era_reward_locked:
			_era_reward_resume_running = _world_clock != null and not _world_clock.paused
			_era_reward_previous_speed = _world_clock.speed_multiplier \
				if _world_clock != null else 1.0
			_era_reward_locked = true
		if _world_clock != null:
			# Worker-owned Modifier commits only land on a simulated day; run
			# one-day steps until ACK while every other command stays locked.
			if status == "SELECTED_PENDING" and bool(offer.get("settles_on_day_advance", false)):
				_world_clock.set_speed(1.0)
				_world_clock.pause(false)
			else:
				_world_clock.pause(true)
		var changed := _era_reward_generation != int(offer.get("offer_generation", 0))
		_era_reward_generation = int(offer.get("offer_generation", 0))
		if _ui_manager != null:
			if changed or not _ui_manager.is_era_reward_modal_open():
				_ui_manager.show_era_reward_offer(offer)
			if status == "SELECTED_PENDING":
				_ui_manager.show_era_reward_pending()
			elif status == "ERROR":
				_ui_manager.show_era_reward_error(String(offer.get(
					"error", "未知事务错误")))
		era_reward_offer_changed.emit(offer)
		if status == "SELECTED_PENDING":
			_drain_era_reward_until_settled()
		return
	# NONE also releases a stale lock, e.g. restored player_view without an Offer.
	if _era_reward_locked:
		if _ui_manager != null:
			_ui_manager.close_era_reward_offer()
		if _world_clock != null:
			_world_clock.set_speed(_era_reward_previous_speed)
			_world_clock.pause(not _era_reward_resume_running)
		_era_reward_locked = false
		_era_reward_generation = 0
		sync_ui()
		era_reward_offer_changed.emit(offer)
		_sync_family_founding_offer()


func era_reward_locked() -> bool:
	return _era_reward_locked


# ─── Era Advancement (docs/cpp-dots-runtime/era-advancement-runtime.md) ─────

static var _milestone_technology_ids: Dictionary = {}
var _era_advancement_snapshot_hash := 0


## UI model of §5. Always the exact documented shape.
func get_era_advancement_snapshot() -> Dictionary:
	_bind_era_advancement()
	return _era_advancement.snapshot()


func get_procurement_policy() -> Dictionary:
	return _era_advancement.policy()


## Why a fully stocked purchase is still waiting ("" when not blocked).
func get_era_advancement_blocked_reason() -> String:
	return _era_advancement.blocked_reason()


static func is_milestone_technology(technology_id: StringName) -> bool:
	if _milestone_technology_ids.is_empty():
		var catalog: Dictionary = TechnologyCatalogForPlayerScript.compile_native_catalog()
		var ids: PackedStringArray = catalog.get("technology_ids", PackedStringArray())
		for index in catalog.get("technology_era_milestone_indices", PackedInt32Array()):
			if int(index) >= 0 and int(index) < ids.size():
				_milestone_technology_ids[StringName(ids[int(index)])] = true
	return _milestone_technology_ids.has(technology_id)


func _era_advancement_preview() -> Dictionary:
	# Read-only: validation must not submit anything or consume sequences.
	_bind_era_advancement()
	return _era_advancement.preview()


func _bind_era_advancement() -> void:
	if _era_advancement == null:
		return
	if not _era_advancement.changed.is_connected(_on_era_advancement_changed):
		_era_advancement.changed.connect(_on_era_advancement_changed)
	if not _era_advancement.era_advanced.is_connected(_on_era_advancement_advanced):
		_era_advancement.era_advanced.connect(_on_era_advancement_advanced)
	if _country_facade == null or _player_country_handle == 0:
		return
	var newly_bound: bool = _era_advancement.bind(_country_facade, _economy_facade,
		_player_country_handle, Callable(self, "_allocate_command_sequence"))
	if newly_bound:
		# Policy and era target are transient on the native side.
		_era_advancement.push_runtime_state(_next_effective_day())
		_refresh_era_advancement(true)


func _restore_era_advancement(state) -> void:
	_bind_era_advancement()
	_era_advancement.restore(state if state is Dictionary else {})
	if _era_advancement.is_bound():
		_era_advancement.push_runtime_state(_next_effective_day())
	_refresh_era_advancement(true)


func _refresh_era_advancement(force: bool = false) -> void:
	if _era_advancement == null or not _era_advancement.is_bound() or _world_clock == null:
		return
	_era_advancement.refresh(_world_clock.day_index(), force)


func _allocate_command_sequence() -> int:
	var sequence := _command_sequence
	_command_sequence += 1
	return sequence


func _on_era_advancement_changed(snapshot: Dictionary) -> void:
	var digest := snapshot.hash()
	if digest == _era_advancement_snapshot_hash:
		return
	_era_advancement_snapshot_hash = digest
	era_advancement_changed.emit(snapshot)


func _on_era_advancement_advanced(old_index: int, new_index: int,
		buffs: PackedStringArray) -> void:
	era_advanced.emit(old_index, new_index, buffs)


## True while a submitted draw/choose/reroll waits for its one-day settlement.
## The "presenting" phase (offer visible, clock paused) is not a lock: the
## player may close the offer and choose later.
func ideology_draw_locked() -> bool:
	return _ideology_draw_phase == "offer" or _ideology_draw_phase == "choose" \
		or _ideology_draw_phase == "reroll"


func ideology_draw_phase() -> String:
	return _ideology_draw_phase


func ideology_offer_eligibility() -> Dictionary:
	if _ideology_facade == null or _player_country_handle == 0 \
			or not _ideology_facade.has_method("preview_offer_eligibility"):
		return {"ok": false, "can_draw": false, "can_reroll": false,
			"reason": "ideology_runtime_unavailable"}
	return _ideology_facade.preview_offer_eligibility(_player_country_handle)


func _ideology_player_snapshot() -> Dictionary:
	if _ideology_facade == null or _player_country_handle == 0 \
			or not _ideology_facade.has_method("snapshot"):
		return {}
	var snapshot: Dictionary = _ideology_facade.snapshot(_player_country_handle)
	return snapshot if bool(snapshot.get("ok", false)) else {}


func _begin_ideology_draw(phase: String, sequence: int) -> void:
	if not _ideology_draw_clock_saved:
		_ideology_draw_resume_running = _world_clock != null and not _world_clock.paused
		_ideology_draw_previous_speed = _world_clock.speed_multiplier \
			if _world_clock != null else 1.0
		_ideology_draw_clock_saved = true
	var snapshot := _ideology_player_snapshot()
	_ideology_draw_baseline_generation = int(snapshot.get("offer_generation", 0))
	_ideology_draw_start_day = _world_clock.day_index() if _world_clock != null else 0
	_ideology_draw_sequence = sequence
	_ideology_draw_phase = phase
	# Commands are effective tomorrow: step the world at 1x until the native
	# authority publishes the settled offer (or the timeout fires).
	if _world_clock != null and not _era_reward_locked:
		_world_clock.set_speed(1.0)
		_world_clock.pause(false)
	ideology_draw_state_changed.emit(phase, {"sequence": sequence})
	sync_ui()


func _sync_ideology_draw() -> void:
	if _ideology_draw_phase.is_empty():
		return
	if _popups_suppressed:
		_finish_ideology_draw("popup_suppressed")
		return
	var snapshot := _ideology_player_snapshot()
	if _ideology_draw_phase == "presenting":
		# Offer resolved elsewhere (load, debug grant): release the saved clock.
		if not snapshot.is_empty() and not bool(snapshot.get("offer_active", false)):
			_finish_ideology_draw("")
		return
	if snapshot.is_empty():
		return
	var active := bool(snapshot.get("offer_active", false))
	var generation := int(snapshot.get("offer_generation", 0))
	if _ideology_draw_phase == "offer" or _ideology_draw_phase == "reroll":
		if active and generation > _ideology_draw_baseline_generation:
			_ideology_draw_phase = "presenting"
			if _world_clock != null and not _era_reward_locked:
				_world_clock.pause(true)
			sync_ui()
			ideology_draw_state_changed.emit("presenting", {"offer_generation": generation})
			ideology_offer_ready.emit(snapshot)
			return
	elif _ideology_draw_phase == "choose":
		if not active or generation != _ideology_draw_baseline_generation:
			_finish_ideology_draw("")
			return
	var today: int = _world_clock.day_index() if _world_clock != null else 0
	if today - _ideology_draw_start_day > IDEOLOGY_DRAW_TIMEOUT_DAYS:
		_finish_ideology_draw("ideology_draw_timeout")


func _finish_ideology_draw(failure_reason: String) -> void:
	var phase := _ideology_draw_phase
	_ideology_draw_phase = ""
	_ideology_draw_sequence = -1
	if _ideology_draw_clock_saved and _world_clock != null:
		if _era_reward_locked:
			# The era-reward lock owns the clock now; hand over the saved state.
			_era_reward_resume_running = _ideology_draw_resume_running
			_era_reward_previous_speed = _ideology_draw_previous_speed
		else:
			_world_clock.set_speed(_ideology_draw_previous_speed)
			_world_clock.pause(not _ideology_draw_resume_running)
	_ideology_draw_clock_saved = false
	sync_ui()
	ideology_draw_state_changed.emit("", {"previous_phase": phase,
		"reason": failure_reason,
		"message": _ideology_draw_failure_message(failure_reason)})


static func _ideology_draw_failure_message(reason: String) -> String:
	if reason.is_empty():
		return ""
	if reason == "ideology_draw_timeout":
		return "抽取超时，请重试。"
	return CountryViewModel.ideology_player_reason(reason)


## Close the visible offer without choosing; the offer stays pending natively.
func dismiss_ideology_offer() -> void:
	if _ideology_draw_phase == "presenting":
		_finish_ideology_draw("")


func family_founding_locked() -> bool:
	return _family_founding_locked


func _on_family_founding_choice_requested(offer_id: int, generation: int,
		choice_index: int) -> void:
	var result := request_command(COMMAND_FAMILY_FOUNDING_CHOOSE, {
		"offer_id": offer_id,
		"generation": generation,
		"choice_index": choice_index,
	})
	if not bool(result.get("ok", false)) and _ui_manager != null \
			and _ui_manager.has_method("show_family_founding_error"):
		_ui_manager.show_family_founding_error(String(result.get("message", "")))
	_sync_family_founding_offer()


## Player-owned milestone offers block the session one at a time. Era rewards
## take precedence: a founding pick waits (hidden) while an era reward is open.
func _sync_family_founding_offer() -> void:
	if _economy_facade == null or not _economy_facade.has_method(
			"family_founding_offers"):
		return
	var snapshot: Dictionary = _economy_facade.family_founding_offers(0, 64)
	if not bool(snapshot.get("ok", false)):
		return
	if _popups_suppressed:
		if _family_founding_locked:
			_family_founding_locked = false
			if _world_clock != null:
				_world_clock.set_speed(_family_founding_previous_speed)
				_world_clock.pause(not _family_founding_resume_running)
			if _ui_manager != null and _ui_manager.has_method("close_family_founding_offer"):
				_ui_manager.close_family_founding_offer()
		return
	var open_offers: Array = []
	for offer in snapshot.get("offers", []):
		if bool(offer.get("player_choice", false)) \
				and String(offer.get("status", "")) == "OPEN":
			open_offers.append(offer)
	if open_offers.is_empty():
		if _family_founding_locked:
			if _ui_manager != null and _ui_manager.has_method(
					"close_family_founding_offer"):
				_ui_manager.close_family_founding_offer()
			_family_founding_locked = false
			_family_founding_offer_id = 0
			_family_founding_generation = 0
			if _era_reward_locked:
				_era_reward_resume_running = _family_founding_resume_running
				_era_reward_previous_speed = _family_founding_previous_speed
			elif _world_clock != null:
				_world_clock.set_speed(_family_founding_previous_speed)
				_world_clock.pause(not _family_founding_resume_running)
			sync_ui()
			family_founding_offer_changed.emit({})
		return
	if not _family_founding_locked:
		if _era_reward_locked:
			_family_founding_resume_running = _era_reward_resume_running
			_family_founding_previous_speed = _era_reward_previous_speed
		else:
			_family_founding_resume_running = _world_clock != null and not _world_clock.paused
			_family_founding_previous_speed = _world_clock.speed_multiplier \
				if _world_clock != null else 1.0
		_family_founding_locked = true
	# The era-reward lock owns the clock while held, including its day-advance
	# settlement; the founding pause takes over once that lock releases.
	if _world_clock != null and not _era_reward_locked:
		_world_clock.pause(true)
	var current: Dictionary = open_offers[0]
	current["queue_remaining"] = open_offers.size() - 1
	var changed := int(current.get("offer_id", 0)) != _family_founding_offer_id
	_family_founding_offer_id = int(current.get("offer_id", 0))
	_family_founding_generation = int(current.get("generation", 0))
	if _ui_manager != null and _ui_manager.has_method("show_family_founding_offer"):
		if _era_reward_locked:
			if _ui_manager.is_family_founding_modal_open():
				_ui_manager.close_family_founding_offer()
		elif changed or not _ui_manager.is_family_founding_modal_open():
			focus_family_founding_cell(int(current.get("cell", -1)))
			_ui_manager.show_family_founding_offer(current)
	sync_ui()
	if changed:
		family_founding_offer_changed.emit(current)


func focus_family_founding_cell(cell_idx: int = -1) -> void:
	var map = _runtime_host.current_map() \
		if _runtime_host != null and _runtime_host.has_method("current_map") else null
	var resolved_idx := cell_idx
	if resolved_idx < 0 and _selected_cell != null:
		resolved_idx = int(_selected_cell.index)
	if map == null or resolved_idx < 0 or resolved_idx >= map.cell_count():
		return
	var target_cell = map.cell_at(resolved_idx)
	if target_cell == null:
		return
	select_cell(target_cell)
	if _highlight is CanvasItem:
		UIAnimation.pulse(_highlight as CanvasItem, UITokens.ANIM_SLOW)


func _tax_item_exists(facade, kind: int, item_id: StringName) -> bool:
	return PlayerCommandValidation._tax_item_exists(facade, kind, item_id)


func _tax_rate_basis_points(args: Dictionary) -> int:
	return PlayerCommandValidation._tax_rate_basis_points(args)


func _tax_assessment_mode(args: Dictionary) -> int:
	return PlayerCommandValidation._tax_assessment_mode(args)


func _validate_owned_cell(facade, cell: int) -> Dictionary:
	if facade == null or cell < 0:
		return _result(false, "invalid_cell", "地块无效。")
	var summary: Dictionary = facade.cell_summary(cell)
	if not bool(summary.get("ok", false)):
		return _result(false, "invalid_cell", "地块无效。")
	if not bool(summary.get("owned", false)) or \
			int(summary.get("country_handle", 0)) != _player_country_handle:
		return _result(false, "territory_not_owned", "只能修改玩家领土的地块税率。")
	return _result(true, "ok", "")


func _next_effective_day() -> int:
	return maxi(0, _world_clock.day_index() + 1) if _world_clock != null else 0


# ─── Military (design §14.3 / contract §2) ──────────────────────────────────

## 玩家军事命令 → 军事 facade 的 op 字符串。见 docs/plans/military-implementation-contract.md §2。
## 只登记面板真正会用到的子集；契约里其余 op（army.transfer/merge/split/rename 等）
## 属于地图交互或后续版本，未登记前一律 unsupported_command，不伪造成功。
const MILITARY_COMMANDS := {
	COMMAND_MILITARY_FORCE_TARGET: "force.set_target",
	COMMAND_MILITARY_CONFIG_SHARES: "config.set",
	COMMAND_MILITARY_QUALITY_POLICY: "config.set_quality_policy",
	COMMAND_MILITARY_AUTO_RETRAIN: "config.auto_retrain",
	COMMAND_MILITARY_LEVY: "force.set_levy",
	COMMAND_MILITARY_AUTO_DISCHARGE: "force.set_auto_discharge",
	COMMAND_MILITARY_BARRACKS: "barracks.pause",
	COMMAND_MILITARY_TRAIN: "train",
	COMMAND_MILITARY_STATE_BUILD: "state.build",
	COMMAND_MILITARY_STATE_DEMOLISH: "state.demolish",
	COMMAND_MILITARY_WAGE: "policy.set_wage",
	COMMAND_MILITARY_PROCUREMENT: "policy.set_procurement",
	COMMAND_MILITARY_BUDGET: "policy.set_budget",
	COMMAND_MILITARY_ARMY_CREATE: "army.create",
	COMMAND_MILITARY_ARMY_STATION: "army.station",
	COMMAND_MILITARY_ARMY_MOVE: "army.move",
	COMMAND_MILITARY_AREA_CONTROL: "army.area_control",
	COMMAND_MILITARY_ARMY_STOP: "army.stop",
	COMMAND_MILITARY_ARMY_STANCE: "army.stance",
	COMMAND_MILITARY_ARMY_DISBAND: "army.disband",
	COMMAND_MILITARY_WAR_DECLARE: "war.declare",
	COMMAND_MILITARY_PEACE_PROPOSE: "peace.propose",
	COMMAND_MILITARY_PEACE_RESPOND: "peace.respond",
}
## `military_facade.gd`（E 维护）的提交入口：契约 §2 的批量命令数组。
## 只认这一个方法名——facade 有 `submit(batch)` 的明确签名，用别的名字猜会
## 静默打空。缺它就回落成 runtime_unavailable，绝不伪造成功。
const MILITARY_FACADE_SUBMIT_METHOD := "submit"


## 军事 facade 由 MapGenerator（E 负责接线）持有；会话没有它就返回 null，
## 军事面板据此给出「军事机构尚未接通」，不会伪造成功。
##
## 必须经 `generator()` 取：WorldRuntimeHost 自己只是宿主，并没有同名访问器
## （它内部也是 `_generator.get_military_facade()`）。只问 host 会让每条玩家军事
## 命令都以 runtime_unavailable 被拒——面板照常读得到数据，按钮却毫无反应。
## 与 `refresh_country_binding()` 里 country / economy 的取法保持一致。
func _military_facade():
	var host = _runtime_host
	if host == null:
		return null
	if host.has_method("get_military_facade"):
		var direct = host.get_military_facade()
		if direct != null:
			return direct
	if not host.has_method("generator"):
		return null
	var generator = host.generator()
	if generator == null or not generator.has_method("get_military_facade"):
		return null
	return generator.get_military_facade()


func has_military_runtime() -> bool:
	var facade = _military_facade()
	return facade != null


## 官营建筑（兵营 / 城防 / 军校）的玩家侧闸门：科技必须已研究，且只能在本国、
## 未被占领的领土上营造。原生 `state.build` 对 AI 与自测保持宽松，所以玩家边界
## 在这里拦一次，避免旧 UI 缓存或脚本绕过科技门槛。
## `demolishing` 为真时跳过科技检查：占领来的高阶城防也得能拆。
func _state_building_gate(cell: int, building: int,
		demolishing: bool = false) -> Dictionary:
	var facade = _military_facade()
	if facade == null:
		return {"ok": false, "code": "runtime_unavailable", "message": "军事机构尚未接通。"}
	var catalog: Dictionary = facade.catalog() if facade.has_method("catalog") else {}
	var rows: Array = catalog.get("state_buildings", []) if catalog.get(
		"state_buildings", null) is Array else []
	if building < 0 or building >= rows.size() or not rows[building] is Dictionary:
		return {"ok": false, "code": "invalid_args", "message": "建筑不在军事目录里。"}
	var row: Dictionary = rows[building]
	var tech_id := String(row.get("unlock_tech_id", ""))
	if not demolishing and not tech_id.is_empty():
		var researched = _completed_technology_ids()
		if researched == null:
			return {"ok": false, "code": "technology_unknown",
				"message": "科技状态暂不可读，稍后再试。"}
		if not (researched as PackedStringArray).has(tech_id):
			return {"ok": false, "code": "technology_locked",
				"message": "尚未解锁这项科技。"}
	var country_facade = _country_facade
	if country_facade != null and country_facade.has_method("cell_summary"):
		var summary: Dictionary = country_facade.cell_summary(cell)
		if bool(summary.get("ok", false)):
			if not bool(summary.get("owned", false)) \
					or int(summary.get("country_handle", 0)) != _player_country_handle:
				return {"ok": false, "code": "not_own_territory",
					"message": "只能在自家领土上营造。"}
	return {"ok": true}


func _player_owns_military_cell(cell: int) -> Dictionary:
	var country_facade = _country_facade
	if country_facade == null or not country_facade.has_method("cell_summary"):
		return {"ok": false, "code": "country_unavailable", "message": "国家领土数据暂不可读。"}
	var summary: Dictionary = country_facade.cell_summary(cell)
	if not bool(summary.get("ok", false)) or not bool(summary.get("owned", false)) \
			or int(summary.get("country_handle", 0)) != _player_country_handle:
		return {"ok": false, "code": "not_own_territory", "message": "只能编成本国可控领土上的驻军。"}
	var military = _military_facade()
	if military == null or not military.has_method("cell_snapshot"):
		return {"ok": false, "code": "military_unavailable", "message": "军事数据暂不可读。"}
	var snapshot: Dictionary = military.cell_snapshot(cell, _player_country_handle)
	if not bool(snapshot.get("ok", false)) \
			or int(snapshot.get("controller_slot", -1)) != int(snapshot.get("owner_slot", -2)):
		return {"ok": false, "code": "cell_occupied", "message": "被占领的地块不能编成部队。"}
	return {"ok": true}


## 玩家已完成的科技稳定 id。读不到国家快照时返回 null（调用方据此拒绝而不是放行）。
func _completed_technology_ids():
	var country_facade = _country_facade
	if country_facade == null or not country_facade.has_method("snapshot"):
		return null
	if _player_country_handle <= 0:
		return null
	var country: Dictionary = country_facade.snapshot(_player_country_handle)
	if not bool(country.get("ok", false)):
		return null
	var ids = country.get("technology_ids", null)
	return ids if ids is PackedStringArray else PackedStringArray()


## 把面板参数翻译成契约 §2 的命令项。缺省字段留空，由 facade/原生侧给默认。
static func _military_command_entry(id: StringName, args: Dictionary) -> Dictionary:
	var entry := {"op": String(MILITARY_COMMANDS[id]), "country": 0}
	match id:
		COMMAND_MILITARY_FORCE_TARGET:
			entry["count"] = int(args.get("mode", 0))
			entry["value"] = int(args.get("value", 0))
		COMMAND_MILITARY_CONFIG_SHARES:
			var shares := {}
			shares[String(args.get("unit", ""))] = int(args.get("bp", 0))
			entry["shares"] = shares
		COMMAND_MILITARY_QUALITY_POLICY:
			entry["policy"] = int(args.get("policy", 0))
		COMMAND_MILITARY_AUTO_RETRAIN, COMMAND_MILITARY_LEVY, \
				COMMAND_MILITARY_AUTO_DISCHARGE:
			entry["count"] = 1 if bool(args.get("enabled", false)) else 0
		COMMAND_MILITARY_BARRACKS:
			entry["cell"] = int(args.get("cell", -1))
			entry["count"] = 1 if bool(args.get("paused", false)) else 0
		COMMAND_MILITARY_TRAIN:
			entry["cell"] = int(args.get("cell", -1))
			entry["unit_from"] = String(args.get("from", "militia"))
			entry["unit_to"] = String(args.get("to", ""))
			entry["count"] = int(args.get("count", 0))
		COMMAND_MILITARY_STATE_BUILD, COMMAND_MILITARY_STATE_DEMOLISH:
			entry["cell"] = int(args.get("cell", -1))
			entry["unit_to"] = int(args.get("building", -1))
		COMMAND_MILITARY_WAGE:
			entry["count"] = int(args.get("mode", 0))
			entry["value"] = int(args.get("value", 0))
		COMMAND_MILITARY_PROCUREMENT:
			entry["value"] = int(args.get("bp", 0))
		COMMAND_MILITARY_BUDGET:
			# -1 表示本项不改；原生按未传入项沿用当前值校验三项之和 <= 100%。
			entry["value"] = int(args.get("total_bp", 0))
			entry["int_pairs"] = PackedInt32Array([
				int(args.get("wage_bp", -1)),
				int(args.get("upkeep_bp", -1)),
				int(args.get("procurement_bp", -1)),
			])
		COMMAND_MILITARY_ARMY_CREATE:
			entry["cell"] = int(args.get("cell", -1))
			entry["units"] = args.get("units", {})
		COMMAND_MILITARY_ARMY_STATION, COMMAND_MILITARY_ARMY_STOP, \
				COMMAND_MILITARY_ARMY_DISBAND:
			entry["army"] = int(args.get("army", 0))
		COMMAND_MILITARY_ARMY_MOVE:
			entry["army"] = int(args.get("army", 0))
			entry["cell"] = int(args.get("cell", -1))
		COMMAND_MILITARY_AREA_CONTROL:
			entry["army"] = int(args.get("army", 0))
			entry["cells"] = args.get("cells", PackedInt32Array())
			entry["radius"] = int(args.get("radius", 0))
		COMMAND_MILITARY_ARMY_STANCE:
			entry["army"] = int(args.get("army", 0))
			entry["count"] = int(args.get("stance", 0))
		COMMAND_MILITARY_WAR_DECLARE:
			entry["other"] = int(args.get("target", 0))
		COMMAND_MILITARY_PEACE_PROPOSE, COMMAND_MILITARY_PEACE_RESPOND:
			entry["other"] = int(args.get("war_id", 0))
			entry["terms"] = args.get("terms", [])
			if id == COMMAND_MILITARY_PEACE_RESPOND:
				entry["count"] = 1 if bool(args.get("accept", false)) else 0
	return entry


## 官营建筑的营造先由经济侧按国库出资结算（国库物资优先、缺口按市价现购），
## 只有经济侧受理后才把排期命令交给军事侧记账。经济侧拒绝时一条军事命令都不发，
## 两本账因此不会各自为政：不会出现「经济没扣钱、军事却已动工」。
##
## `economy_building_id` 是军事目录里的经济建筑稠密索引，这里反查回稳定 id 再交给
## 经济外观层，因为它会在自己的目录里重新解析一次；稠密索引只是编译期坐标，
## 不能当身份跨运行时传递。
func _submit_state_build_command(args: Dictionary, effective_day: int,
		sequence: int) -> Dictionary:
	var facade = _military_facade()
	if facade == null:
		return _result(false, "runtime_unavailable", "军事机构尚未接通。")
	var building := int(args.get("building", -1))
	var cell := int(args.get("cell", -1))
	if not facade.has_method("state_building_economy_id"):
		return _result(false, "runtime_unavailable",
			"军事机构尚未接通：缺少官营建筑目录。")
	var economy_type := int(facade.state_building_economy_id(building))
	if economy_type < 0:
		return _result(false, "military_state_building_unmapped",
			"该项官营建筑尚未接入经济目录，暂时无法营造。")
	if _economy_facade == null or not _economy_facade.has_method(
			"treasury_sponsored_build"):
		return _result(false, "runtime_unavailable", "经济系统尚未就绪，请稍后再试。")
	var economy_ids := PackedStringArray()
	if _economy_facade.has_method("building_type_ids"):
		economy_ids = _economy_facade.building_type_ids()
	if economy_type >= economy_ids.size():
		return _result(false, "military_state_building_unmapped",
			"该项官营建筑与经济目录不一致，暂时无法营造。")
	var building_id := StringName(economy_ids[economy_type])
	var paid: Dictionary = _economy_facade.treasury_sponsored_build(
		_player_country_handle, cell, building_id, effective_day, sequence)
	if not bool(paid.get("ok", false)):
		var code := String(paid.get("code", paid.get("reason", "command_rejected")))
		var message := String(paid.get("message", ""))
		if message.is_empty() or message == code:
			message = "营造未能下单，请稍后重试。"
		return _result(false, code, message)
	var forwarded := _submit_military_command(COMMAND_MILITARY_STATE_BUILD,
		args, effective_day, sequence)
	if not bool(forwarded.get("ok", false)):
		# The economy already accepted (and will settle) the lot, so a military
		# bookkeeping failure must not read like "nothing happened": report the
		# economy code and say the schedule still lands.
		var forwarded_code := String(forwarded.get("code", "command_rejected"))
		var out := _result(false, forwarded_code,
			"营造已由国库出资排队，但军事排期未能登记。")
		out["economy_code"] = String(paid.get("code", "construction_queued"))
		return out
	var settled := _result(true, "construction_queued",
		"营造已由国库出资排队，将在下一个经济结算边界执行。")
	settled["building_id"] = String(building_id)
	settled["economy_sequence"] = sequence
	return settled


## 拆除是营造的镜像：先让经济账本把这座建筑减掉，再让军事侧记账。
## 顺序不能反——官营建筑组的座数是唯一账本，军事侧只是它的派生缓存，
## 若先发军事命令，军事侧会报出一座账本里已经不存在的建筑。
##
## 与营造一样，`economy_building_id` 只是编译期坐标，这里反查回稳定 id
## 再交给经济外观层重新解析。
func _submit_state_demolish_command(args: Dictionary, effective_day: int,
		sequence: int) -> Dictionary:
	var facade = _military_facade()
	if facade == null:
		return _result(false, "runtime_unavailable", "军事机构尚未接通。")
	var building := int(args.get("building", -1))
	var cell := int(args.get("cell", -1))
	if not facade.has_method("state_building_economy_id"):
		return _result(false, "runtime_unavailable",
			"军事机构尚未接通：缺少官营建筑目录。")
	var economy_type := int(facade.state_building_economy_id(building))
	if economy_type < 0:
		return _result(false, "military_state_building_unmapped",
			"该项官营建筑尚未接入经济目录，暂时无法拆除。")
	if _economy_facade == null or not _economy_facade.has_method(
			"treasury_sponsored_demolish"):
		return _result(false, "runtime_unavailable", "经济系统尚未就绪，请稍后再试。")
	var economy_ids := PackedStringArray()
	if _economy_facade.has_method("building_type_ids"):
		economy_ids = _economy_facade.building_type_ids()
	if economy_type >= economy_ids.size():
		return _result(false, "military_state_building_unmapped",
			"该项官营建筑与经济目录不一致，暂时无法拆除。")
	var building_id := StringName(economy_ids[economy_type])
	# 一次拆一座：行内拆除键的语义就是「减掉这一座」，批量拆除没有入口，
	# 也就不需要在这里替玩家猜一个数量。
	var removed: Dictionary = _economy_facade.treasury_sponsored_demolish(
		_player_country_handle, cell, building_id, 1, effective_day, sequence)
	if not bool(removed.get("ok", false)):
		var code := String(removed.get("code", removed.get("reason", "command_rejected")))
		var message := String(removed.get("message", ""))
		if message.is_empty() or message == code:
			message = "拆除未能下单，请稍后重试。"
		return _result(false, code, message)
	var forwarded := _submit_military_command(COMMAND_MILITARY_STATE_DEMOLISH,
		args, effective_day, sequence)
	if not bool(forwarded.get("ok", false)):
		# 经济侧已经受理（并会在下一个结算边界减掉座数），所以军事记账失败
		# 不能读成「什么都没发生」。
		var forwarded_code := String(forwarded.get("code", "command_rejected"))
		var out := _result(false, forwarded_code,
			"拆除已由经济账本受理，但军事侧记账未能登记。")
		out["economy_code"] = String(removed.get("code", "demolish_queued"))
		return out
	var settled := _result(true, "demolish_queued",
		"拆除已排队，将在下一个经济结算边界执行。")
	settled["building_id"] = String(building_id)
	settled["economy_sequence"] = sequence
	return settled


func _submit_military_command(id: StringName, args: Dictionary,
		effective_day: int, sequence: int) -> Dictionary:
	var facade = _military_facade()
	if facade == null:
		return _result(false, "runtime_unavailable", "军事机构尚未接通。")
	var entry := _military_command_entry(id, args)
	entry["country"] = _player_country_handle
	if not facade.has_method(MILITARY_FACADE_SUBMIT_METHOD):
		return _result(false, "runtime_unavailable",
			"军事机构尚未接通：缺少军事命令入口。")
	# 命令在下一游戏日生效由军事运行时自己排期；控制器只负责把玩家意图
	# 交出去、保留自己的 sequence 以便回执对齐，并把拒绝理由翻成玩家话。
	var raw = facade.call(MILITARY_FACADE_SUBMIT_METHOD, [entry])
	var result: Dictionary
	if raw is Dictionary:
		result = raw
	else:
		result = _result(false, "command_rejected", "军事命令未返回结果。")
	if bool(result.get("ok", false)):
		result["code"] = String(result.get("code", "queued"))
		if not result.has("message"):
			result["message"] = "军事命令已排队，将在下一游戏日生效。"
		_military_last_sequence = sequence
		if id == COMMAND_MILITARY_BUDGET:
			_remember_military_budget(args)
	return result


var _military_last_sequence := -1
## 玩家亲手设过的军事预算份额（任务 10 / 需求 9.3）。
##
## 原生侧这三个份额是 transient：不进 PKMI、不进 `state_hash`，读档后归零，
## 也就是退回「无信封、按现金与需求直接结算」的旧行为。不重推的话，玩家存档
## 里的预算控制会静默消失，面板显示的份额还会和原生真实政策对不上。
##
## 所以会话自己留一份，读档时原样重推一次。`-1` 表示该项从未被玩家碰过：
## 重推时原样传回，原生按未传入项沿用当前值，与当时的行为完全等价。
var _military_budget_state := {
	"total_bp": -1, "wage_bp": -1, "upkeep_bp": -1, "procurement_bp": -1,
}
var _military_budget_repushed := false
# Army order awaiting a map click (design §14.2). "move" previews the path on the
# first click and confirms on the second; "area" takes the first click as centre.
var _military_order_army := 0
var _military_order_mode := ""
var _military_order_radius := 0
var _military_order_target := -1
var _military_order_preview: Dictionary = {}
var _military_order_message := ""


func military_last_sequence() -> int:
	return _military_last_sequence


## 命令成功后记下玩家这次真正改动的项。`-1` 表示「本次不改」，绝不覆盖已有值，
## 否则拖一次军饷滑条就会把另外两个通道的既有份额清空。
func _remember_military_budget(args: Dictionary) -> void:
	var total := int(args.get("total_bp", 0))
	if total < 0:
		return
	_military_budget_state["total_bp"] = total
	for key in ["wage_bp", "upkeep_bp", "procurement_bp"]:
		if not args.has(key):
			continue
		var value := int(args[key])
		if value >= 0:
			_military_budget_state[key] = value


## 读档恢复：先接受存档里的份额，再尝试重推。重推失败不算错误——玩家国家句柄
## 或军事 facade 可能还没接上，`refresh_country_binding()` 会再试一次。
func _restore_military_budget(state) -> void:
	_military_budget_state = {
		"total_bp": -1, "wage_bp": -1, "upkeep_bp": -1, "procurement_bp": -1,
	}
	if state is Dictionary:
		var restored: Dictionary = state
		for key in ["total_bp", "wage_bp", "upkeep_bp", "procurement_bp"]:
			_military_budget_state[key] = int(restored.get(key, -1))
	_military_budget_repushed = false
	_repush_military_budget()


## 把会话里记住的份额原样推回原生。原生这三个字段是 transient（读档归零），
## 不重推就等于玩家读档后预算控制静默失效。
##
## 返回 true 表示「已推成功」或「本来就没有可推的」；false 表示环境还没就绪，
## 调用方（`refresh_country_binding`）应在绑定完成后重试。
func _repush_military_budget() -> bool:
	if _military_budget_repushed:
		return true
	if int(_military_budget_state.get("total_bp", -1)) < 0:
		# 玩家从未设过预算，原生保持无信封，这正是存档前的状态。
		_military_budget_repushed = true
		return true
	if _player_country_handle <= 0 or _military_facade() == null:
		return false
	var args := {"total_bp": int(_military_budget_state.get("total_bp", 0))}
	for key in ["wage_bp", "upkeep_bp", "procurement_bp"]:
		args[key] = int(_military_budget_state.get(key, -1))
	var result: Dictionary = _submit_military_command(COMMAND_MILITARY_BUDGET,
		args, _next_effective_day(), _allocate_command_sequence())
	if not bool(result.get("ok", false)):
		return false
	_military_budget_repushed = true
	return true


# ─── Military army orders on the map (design §14.2) ────────────────────────
# The workspace only asks for the mode; the targeting loop lives here because
# this is where a map click becomes a cell. 地图点击只预览，档案上的确认键提交。

## `mode` is "move" or "area". Returns the same result shape as request_command.
func begin_military_arm_order(army: int, mode: String, radius: int = 1) -> Dictionary:
	var facade = _military_facade()
	if facade == null:
		return _result(false, "runtime_unavailable", "军事机构尚未接通。")
	if not facade.has_method("preview_path"):
		return _result(false, "runtime_unavailable", "军事机构尚未接通：缺少路径预览入口。")
	if army <= 0:
		return _result(false, "invalid_args", "先选一支自己的部队。")
	if mode != "move" and mode != "area":
		return _result(false, "invalid_args", "未知的部队指令。")
	if mode == "area" and (radius < 1 or radius > 6):
		return _result(false, "invalid_args", "军事控制半径上限为 6 格。")
	var detail: Dictionary = facade.army(army)
	if not bool(detail.get("ok", false)) or int(detail.get("owner_slot", -1)) != \
			int(_player_country_handle & 0xFFFFFFFF):
		return _result(false, "not_owner", "只能指挥本国部队。")
	cancel_military_arm_order()
	_military_order_army = army
	_military_order_mode = mode
	_military_order_radius = radius
	_military_order_target = -1
	_military_order_message = "点击地图选择控制中心，再确认区域。" if mode == "area" \
		else "点击地图预览路线，再确认行军。"
	_apply_military_render_selection(army)
	_clear_military_path_preview()
	_notify_military_arm_order()
	var armed := _result(true, "ok", "在地图上点目标格。")
	armed["mode"] = mode
	armed["radius"] = radius
	return armed


func cancel_military_arm_order() -> void:
	if _military_order_mode == "area":
		clear_cell_highlights()
	_military_order_army = 0
	_military_order_mode = ""
	_military_order_radius = 0
	_military_order_target = -1
	_military_order_preview.clear()
	_military_order_message = ""
	_clear_military_path_preview()
	_notify_military_arm_order()


func military_arm_order() -> Dictionary:
	return {"army": _military_order_army, "mode": _military_order_mode,
		"radius": _military_order_radius, "target": _military_order_target,
		"ready": _military_order_target >= 0 and not _military_order_preview.is_empty(),
		"message": _military_order_message,
		"days": int(_military_order_preview.get("days", 0)),
		"cell_count": (_military_order_preview.get("area", PackedInt32Array()) as PackedInt32Array).size()}


func _notify_military_arm_order() -> void:
	if _ui_manager != null and _ui_manager.has_method("update_military_arm_order"):
		_ui_manager.call("update_military_arm_order", military_arm_order())


func set_military_arm_order_radius(radius: int) -> void:
	if _military_order_mode != "area":
		return
	_military_order_radius = clampi(radius, 1, 6)
	if _military_order_target >= 0:
		military_arm_order_click(_military_order_target)
	else:
		_notify_military_arm_order()


## 确认时重算路径；快进期间部队位置、领土和通行条件都可能改变。
func confirm_military_arm_order() -> Dictionary:
	if _military_order_target < 0 or _military_order_preview.is_empty():
		return _result(false, "target_required", "先在地图上选择可达的目标。")
	var target := _military_order_target
	military_arm_order_click(target)
	if _military_order_preview.is_empty():
		return _result(false, "target_unreachable", _military_order_message)
	var id := COMMAND_MILITARY_AREA_CONTROL if _military_order_mode == "area" \
		else COMMAND_MILITARY_ARMY_MOVE
	var args := {"army": _military_order_army, "cell": target}
	if _military_order_mode == "area":
		args["cells"] = _military_order_preview.get("area", PackedInt32Array())
		args["radius"] = _military_order_radius
	var sent := request_command(id, args)
	if bool(sent.get("ok", false)):
		cancel_military_arm_order()
	else:
		_military_order_message = String(sent.get("message", "命令未能下达，请重试。"))
		_notify_military_arm_order()
	return sent


## Map click while an order is pending. Returns true when the click belonged to
## the order (the caller must then not open the cell panel for it).
func military_arm_order_click(cell: int) -> bool:
	if _military_order_mode.is_empty() or cell < 0:
		return false
	var facade = _military_facade()
	var preview: Dictionary = facade.preview_path(_military_order_army, cell) \
		if facade != null and facade.has_method("preview_path") else {}
	_military_order_target = -1
	_military_order_preview.clear()
	_clear_military_path_preview()
	if _military_order_mode == "area":
		clear_cell_highlights()
	if not bool(preview.get("ok", false)):
		# Never send a move the pathfinder already refused to draw.
		_preview_failed(preview, cell)
		return true
	if not _show_military_path_preview(preview, cell):
		_military_order_message = "路线暂不可显示，请重新选择目标。"
		_notify_military_arm_order()
		return true
	_military_order_target = cell
	_military_order_preview = preview.duplicate()
	if _military_order_mode == "area":
		var cells := _military_area_cells(cell, _military_order_radius)
		_military_order_preview["area"] = cells
		highlight_cells(cells)
		if cells.is_empty():
			_military_order_target = -1
			_military_order_preview.clear()
		_military_order_message = "控制范围已标出，确认后部队将执行区域控制。"
	else:
		_military_order_message = "路线已标出；可改选目标，或确认行军。"
	_notify_military_arm_order()
	return true


func _preview_failed(preview: Dictionary, cell: int) -> void:
	var reason := String(preview.get("reason", ""))
	var text := "这段路走不通：目标格不可达。"
	if reason == "military_path_unreachable":
		text = "这段路走不通：与部队之间没有可通行的路线。"
	_military_order_message = text
	_notify_military_arm_order()
	if _ui_manager != null and _ui_manager.has_method("show_transient_message"):
		_ui_manager.call("show_transient_message", text)
	else:
		push_warning("military arm order: %s (cell %d)" % [reason, cell])


func _show_military_path_preview(preview: Dictionary, cell: int) -> bool:
	var layers = _military_layers()
	if layers == null or not layers.has_method("show_path_preview"):
		push_warning("military arm order: no map layers for the path preview")
		return false
	var cells = preview.get("cells", PackedInt32Array())
	var route := PackedInt32Array()
	for value in cells:
		route.append(int(value))
	var days := int(preview.get("days", 0))
	layers.call("show_path_preview", route, PackedInt32Array(), days)
	return true


func _clear_military_path_preview() -> void:
	var layers = _military_layers()
	if layers != null and layers.has_method("clear_route"):
		layers.call("clear_route")


## Centre + radius as cell indices (the same hex radius the core uses for
## army.area_control). Bounded to the command's 256-cell cap.
func _military_area_cells(centre: int, radius: int) -> PackedInt32Array:
	var cells := PackedInt32Array()
	var map = _runtime_host.current_map() if _runtime_host != null \
		and _runtime_host.has_method("current_map") else null
	if map == null or centre < 0:
		return cells
	var neighbours: PackedInt32Array = map.neighbor_indices_packed()
	var frontier := PackedInt32Array([centre])
	var seen := {}
	seen[centre] = true
	cells.append(centre)
	for _step in range(maxi(0, radius)):
		var next := PackedInt32Array()
		for cell in frontier:
			var base := int(cell) * 6
			if base + 6 > neighbours.size():
				continue
			for direction in range(6):
				var neighbour := int(neighbours[base + direction])
				if neighbour < 0 or seen.has(neighbour):
					continue
				seen[neighbour] = true
				next.append(neighbour)
				if cells.size() < 256:
					cells.append(neighbour)
		frontier = next
	return cells


func _apply_military_render_selection(army: int) -> void:
	var facade = _military_facade()
	if facade != null and facade.has_method("set_render_selection"):
		facade.call("set_render_selection", army)


func _military_layers():
	if _runtime_host != null and "military_map_layers" in _runtime_host:
		return _runtime_host.get("military_map_layers")
	return null


## Workspace selection: ask the native snapshot to expose this army's area and
## remaining path so the area/route layers follow the selection.
func set_military_render_selection(army_handle: int) -> Dictionary:
	var facade = _military_facade()
	if facade == null or not facade.has_method("set_render_selection"):
		return _result(false, "runtime_unavailable", "军事机构尚未接通。")
	var result: Dictionary = facade.call("set_render_selection", int(army_handle))
	return result if result is Dictionary else _result(false, "command_rejected", "")


## Same native preview used by the targeting draft, for other UI callers.
func preview_military_path(army_handle: int, cell: int) -> Dictionary:
	var facade = _military_facade()
	if facade == null or not facade.has_method("preview_path"):
		return {"ok": false, "reason": "runtime_unavailable"}
	var result = facade.call("preview_path", int(army_handle), int(cell))
	return result if result is Dictionary else {"ok": false, "reason": "command_rejected"}


## Front-edge probe for the war chapter: the render snapshot carries the per-edge
## progress byte but not the keys (they only feed MilitaryFrontLayer).
func military_front_probe() -> Dictionary:
	var facade = _military_facade()
	if facade == null or not facade.has_method("render_snapshot"):
		return {"ok": false, "keys": PackedInt32Array(), "progress": PackedByteArray()}
	var snapshot = facade.call("render_snapshot", 0)
	if not (snapshot is Dictionary):
		return {"ok": false, "keys": PackedInt32Array(), "progress": PackedByteArray()}
	return {"ok": true,
		"keys": (snapshot as Dictionary).get("front_edges", PackedInt32Array()),
		"progress": (snapshot as Dictionary).get("front_progress", PackedByteArray())}


## Latest military events for the battle log (same ring as the daily system's
## cursor; this read never advances it).
func military_events_probe(limit: int = 512) -> Array:
	var facade = _military_facade()
	if facade == null or not facade.has_method("poll_events"):
		return []
	var batch = facade.call("poll_events", 0, limit)
	return batch if batch is Array else []


## MilitaryBattleLogRow (the core's last 64 battles) has no bridge accessor yet,
## so there is nothing truthful to report here; the battle log falls back to the
## event ring. Report unavailable rather than invent a row.
func battle_log_probe() -> Dictionary:
	return {"available": false, "reason": "military_battle_log_api_missing"}


## Truce end day with a country slot, -1 when none. The bridge has no truce
## query; the war chapter shows "正在交战" without this and must not guess a date.
func military_truce_until(_slot: int) -> int:
	return -1


static func _colonization_command_message(code: String) -> String:
	return {
		"economy_busy_retry": "经济正在结算。可先排队，提交完成后会自动派遣。",
		"colonization_queued": "派遣已排队，将在经济结算完成后出发。",
		"colonization_cancel_queued": "取消已排队，将在经济结算完成后执行。",
		"economy_paused": "经济已因守恒失败暂停，无法派遣。",
		"economy_not_available": "经济系统尚未就绪，请稍后再试。",
		"colonization_requote_required": "地图、视野或领土已经变化，请重新确认报价。",
		"colonization_kit_requote_required": "目标资源或科技已经变化，请重新确认开工包。",
		"colonization_kit_materials_short": "源地市场库存不足，无法抽出开工包物资。",
		"colonization_preparing": "开拓队已开始筹备，人仍留在源地生产缺货物资。",
		"colonization_cancelled": "开拓筹备已取消，目标占用已释放。",
		"colonization_quote_expired": "报价已过期，请重新选择要派遣的家族。",
		"colonization_population_insufficient": "源分支人口不足，必须至少留下一人。",
		"colonization_duplicate_target": "本国已有一支开拓队前往该目标。",
		"colonization_family_cell_capacity": "目标地块的家族数量已达上限。",
		"colonization_expedition_invalid": "开拓队已结束或句柄已过期。",
		"colonization_command_invalid": "开拓命令参数不完整。",
		"colonization_country_snapshot_unavailable": "国家快照尚未就绪，请稍后再试。",
	}.get(code, "当前无法执行开拓。")


func _complete_command(id: StringName, result: Dictionary) -> Dictionary:
	if not result.has("effective_day"):
		result["effective_day"] = -1
	if not result.has("sequence"):
		result["sequence"] = -1
	command_completed.emit(id, result)
	return result


func _cell_display_world(cell) -> Vector2:
	var hex_size: float = _runtime_host.hex_size if _runtime_host != null else 22.0
	var canonical := HexUtils.cube_to_world(cell.q, cell.r, hex_size)
	var ref_x: float = _camera.position.x if _camera != null else canonical.x
	var wrap_period: float = _runtime_host.map_wrap_period_x() if _runtime_host != null else 0.0
	return HexUtils.nearest_display_world(canonical, ref_x, wrap_period)


func _is_text_editing() -> bool:
	var viewport := get_viewport()
	if viewport == null:
		return false
	var focus := viewport.gui_get_focus_owner()
	return focus is LineEdit or focus is TextEdit


func _is_input_blocked_by_ui() -> bool:
	# Direct-dispatch guard only. `_unhandled_input` already survived GUI
	# consumption and must not treat leftover HUD button focus as a map lock.
	var viewport := get_viewport()
	if viewport == null:
		return false
	var focus := viewport.gui_get_focus_owner()
	return focus is Control


func _is_world_pointer_event(event: InputEvent) -> bool:
	return event is InputEventMouseButton \
		or event is InputEventMouseMotion \
		or event is InputEventScreenTouch \
		or event is InputEventScreenDrag \
		or event is InputEventMagnifyGesture \
		or event is InputEventPanGesture


func _release_ordinary_ui_focus() -> void:
	var viewport := get_viewport()
	if viewport == null:
		return
	var focus := viewport.gui_get_focus_owner()
	if focus is Control and not (focus is LineEdit or focus is TextEdit):
		viewport.gui_release_focus()


static func _result(ok: bool, code: String, message: String) -> Dictionary:
	return PlayerCommandValidation._result(ok, code, message)


# ─── Narrative Event System Integration ─────────────────────────────────────

var _last_narrative_step_day: int = -1


func narrative_service():
	return _narrative_service


func narrative_flow():
	return _narrative_flow


func narrative_ai_client():
	return _narrative_ai_client


func narrative_event_locked() -> bool:
	return _narrative_flow != null and _narrative_flow.is_locked()

func set_popups_suppressed(enabled: bool) -> void:
	if enabled and not _popups_suppressed:
		_suppression_resume_running = _world_clock != null and not _world_clock.paused
	_popups_suppressed = enabled
	_annual_report_flow.set_popups_suppressed(enabled)
	_narrative_flow.set_popups_suppressed(enabled)
	if not enabled:
		return
	# 已经锁住时钟的提示在开关切换瞬间也必须释放；原生 offer 保留，
	# 之后可由玩家关闭屏蔽再正常领取。
	if _era_reward_locked:
		if _ui_manager != null and _ui_manager.has_method("close_era_reward_offer"):
			_ui_manager.close_era_reward_offer()
		_era_reward_locked = false
		if _world_clock != null:
			_world_clock.set_speed(_era_reward_previous_speed)
			_world_clock.pause(not _era_reward_resume_running)
	if _family_founding_locked:
		if _ui_manager != null and _ui_manager.has_method("close_family_founding_offer"):
			_ui_manager.close_family_founding_offer()
		_family_founding_locked = false
		if _world_clock != null:
			_world_clock.set_speed(_family_founding_previous_speed)
			_world_clock.pause(not _family_founding_resume_running)
	if not _ideology_draw_phase.is_empty():
		_finish_ideology_draw("popup_suppressed")


func _is_suppressed_popup_pause_source(source: String) -> bool:
	for marker in ["_pause_clock", "open_era_reward_offer", "_sync_era_reward_offer",
			"_sync_family_founding_offer", "_sync_ideology_draw", "_pause_clock_for_ceremony"]:
		if source.find(marker) >= 0:
			return true
	return false


func export_narrative_state() -> Dictionary:
	return _narrative_service.export_state() if _narrative_service != null else {}


func restore_narrative_state(state: Dictionary) -> Dictionary:
	if _narrative_service == null:
		return {"ok": true}
	var res := _narrative_service.restore_state(state)
	_last_narrative_step_day = -1
	return res


func open_narrative_chronicle(filter_cell: int = -1) -> void:
	if _ui_manager == null or _narrative_service == null:
		return
	if _ui_manager.has_method("show_narrative_chronicle"):
		_ui_manager.show_narrative_chronicle(
			_narrative_service.get_chronicle(0, 128, filter_cell)
		)


func _configure_narrative_runtime() -> void:
	if _narrative_service == null or _narrative_flow == null:
		return
	if _narrative_ai_client == null:
		_narrative_ai_client = NarrativeAiClientScript.new()
		_narrative_ai_client.name = "NarrativeAiClient"
		add_child(_narrative_ai_client)
	var generator = _runtime_host.generator() if _runtime_host != null and _runtime_host.has_method("generator") else null
	var map = _runtime_host.current_map() if _runtime_host != null and _runtime_host.has_method("current_map") else null
	var view_adapter = _runtime_host.view_adapter() if _runtime_host != null and _runtime_host.has_method("view_adapter") else null
	var seed_val := int(_runtime_host.last_seed()) if _runtime_host != null and _runtime_host.has_method("last_seed") else 1
	_narrative_service.configure(
		generator, map, view_adapter, _world_clock,
		_player_country_handle, maxi(1, seed_val)
	)
	_narrative_flow.configure(
		self, _runtime_host, _world_clock, _ui_manager,
		_narrative_service, _narrative_ai_client
	)
	if not _narrative_flow.offer_changed.is_connected(_on_narrative_offer_changed):
		_narrative_flow.offer_changed.connect(_on_narrative_offer_changed)
	if not _narrative_flow.event_resolved.is_connected(_on_narrative_event_resolved):
		_narrative_flow.event_resolved.connect(_on_narrative_event_resolved)
	if not _narrative_service.ai_generation_requested.is_connected(_on_narrative_ai_generation_requested):
		_narrative_service.ai_generation_requested.connect(_on_narrative_ai_generation_requested)
	if _ui_manager != null and _ui_manager.has_signal("narrative_chronicle_requested"):
		var cb_chron := Callable(self, "open_narrative_chronicle")
		if not _ui_manager.narrative_chronicle_requested.is_connected(cb_chron):
			_ui_manager.narrative_chronicle_requested.connect(cb_chron)


func _step_narrative_daily(day_idx: int) -> void:
	if _narrative_service == null or _player_country_handle <= 0:
		return
	if day_idx <= _last_narrative_step_day:
		return
	_last_narrative_step_day = day_idx
	_narrative_service.set_player_country_handle(_player_country_handle)
	var ai_enabled := false
	var settings := get_node_or_null("/root/GameSettings")
	if settings != null and settings.has_method("values"):
		ai_enabled = bool(settings.values().get("ai_narrative_enabled", false))
	_narrative_service.on_day_committed(day_idx, ai_enabled)
	_narrative_flow.try_present()


func _on_narrative_offer_changed(offer: Dictionary) -> void:
	narrative_event_offer_changed.emit(offer)


func _on_narrative_event_resolved(record: Dictionary) -> void:
	narrative_event_resolved.emit(record)


func _on_narrative_ai_generation_requested(request_spec: Dictionary) -> void:
	if _narrative_ai_client == null or _narrative_service == null:
		return
	_narrative_ai_client.request_event_generation(request_spec, func(res: Dictionary) -> void:
		if not bool(res.get("ok", false)):
			return
		var def = res.get("definition", null)
		if def == null:
			return
		var cell_idx := int(res.get("cell_idx", -1))
		var chain_id := StringName(res.get("chain_id", ""))
		var day: int = int(_world_clock.day_index()) if _world_clock != null else int(request_spec.get("day", 1))
		_narrative_service.enqueue_event_offer(def, cell_idx, day, chain_id)
		_narrative_flow.try_present()
	)
