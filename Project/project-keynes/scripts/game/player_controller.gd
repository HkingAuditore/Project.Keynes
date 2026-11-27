extends Node
class_name PlayerController

const NarrativeSession = preload("res://scripts/game/player_narrative_session.gd")

const AudioPresentation = preload("res://scripts/game/player_audio_presentation.gd")

const ClockPresentation = preload("res://scripts/game/player_clock_presentation.gd")

const CommittedPresentation = preload("res://scripts/game/player_committed_presentation.gd")

const WorldInput = preload("res://scripts/game/player_world_input.gd")

const ColonizationReads = preload("res://scripts/game/player_colonization_reads.gd")

const CommandDispatch = preload("res://scripts/game/player_command_dispatch.gd")

const SessionConnections = preload("res://scripts/game/player_session_connections.gd")

const CommandRoutes = preload("res://scripts/game/player_controller/command_routes.gd")
const PlayerCommandValidation = preload("res://scripts/game/player_command_validation.gd")


## Formal player-session boundary. It translates Godot/UI intent into the
## existing runtime and country facades; it never owns simulation state.

const AnnualReportFlowScript = preload("res://scripts/annual/annual_report_flow.gd")
const MusicSituationAggregatorScript = preload("res://scripts/audio/music_situation_aggregator.gd")
const MusicSituationPlaybackScript = preload("res://scripts/audio/music_situation_playback.gd")
const NarrativeEventServiceScript = preload("res://scripts/narrative/narrative_event_service.gd")
const NarrativeEventFlowScript = preload("res://scripts/narrative/narrative_event_flow.gd")
const NarrativeAiClientScript = preload("res://scripts/narrative/ai/narrative_ai_client.gd")
const PlayerControllerMilitaryScript = preload("res://scripts/game/player_controller/military.gd")
const PlayerControllerProgressionScript = preload("res://scripts/game/player_controller/progression.gd")
const PlayerControllerSelectionScript = preload("res://scripts/game/player_controller/selection.gd")
const PlayerControllerNarrativeScript = preload("res://scripts/game/player_controller/narrative.gd")
var _annual_report_flow = AnnualReportFlowScript.new()
var _music_situation = MusicSituationAggregatorScript.new()
var _music_playback: Node
var _narrative_service = NarrativeEventServiceScript.new()
var _narrative_flow = NarrativeEventFlowScript.new()
var _narrative_ai_client: Node = null
var _military_component = PlayerControllerMilitaryScript.new()
var _progression_component = PlayerControllerProgressionScript.new()
var _selection_component = PlayerControllerSelectionScript.new()
var _narrative_component = PlayerControllerNarrativeScript.new()
signal selection_changed(cell)
signal command_completed(id: StringName, result: Dictionary)
signal command_settled(id: StringName, result: Dictionary)
signal colonization_quotes_ready()
signal regeneration_requested()
signal country_committed(report: Dictionary)
signal era_reward_offer_changed(offer: Dictionary)
signal family_founding_offer_changed(offer: Dictionary)
signal narrative_event_offer_changed(offer: Dictionary)
signal narrative_event_resolved(record: Dictionary)
## A candidate is ready to display at the executor's stopped boundary.
signal ideology_offer_ready(snapshot: Dictionary)
## Era Advancement (docs/cpp-dots-runtime/era-advancement-runtime.md §5).
signal era_advancement_changed(snapshot: Dictionary)
signal era_advanced(old_index: int, new_index: int, buffs: PackedStringArray)

const EraAdvancementServiceScript = PlayerCommandValidation.EraAdvancementServiceScript
const TechnologyCatalogForPlayerScript = preload("res://scripts/economy/technology_catalog.gd")
var _era_advancement = EraAdvancementServiceScript.new()

const COMMAND_RESEARCH_SET_WEIGHTS = PlayerCommandValidation.COMMAND_RESEARCH_SET_WEIGHTS
const COMMAND_RESEARCH_ENQUEUE = PlayerCommandValidation.COMMAND_RESEARCH_ENQUEUE
const COMMAND_RESEARCH_REMOVE = PlayerCommandValidation.COMMAND_RESEARCH_REMOVE
const COMMAND_RESEARCH_MOVE = PlayerCommandValidation.COMMAND_RESEARCH_MOVE
const COMMAND_COUNTRY_TAX_SET_DEFAULT = PlayerCommandValidation.COMMAND_COUNTRY_TAX_SET_DEFAULT
const COMMAND_COUNTRY_TAX_SET_OVERRIDE = PlayerCommandValidation.COMMAND_COUNTRY_TAX_SET_OVERRIDE
const COMMAND_COUNTRY_TAX_SET_OVERRIDE_GROUP = PlayerCommandValidation.COMMAND_COUNTRY_TAX_SET_OVERRIDE_GROUP
const COMMAND_COUNTRY_TAX_CLEAR_OVERRIDE = PlayerCommandValidation.COMMAND_COUNTRY_TAX_CLEAR_OVERRIDE
const COMMAND_COUNTRY_TAX_CLEAR_OVERRIDE_GROUP = PlayerCommandValidation.COMMAND_COUNTRY_TAX_CLEAR_OVERRIDE_GROUP
const COMMAND_CELL_TAX_SET_DEFAULT = PlayerCommandValidation.COMMAND_CELL_TAX_SET_DEFAULT
const COMMAND_CELL_TAX_CLEAR_DEFAULT = PlayerCommandValidation.COMMAND_CELL_TAX_CLEAR_DEFAULT
const COMMAND_CELL_TAX_SET_OVERRIDE = PlayerCommandValidation.COMMAND_CELL_TAX_SET_OVERRIDE
const COMMAND_CELL_TAX_CLEAR_OVERRIDE = PlayerCommandValidation.COMMAND_CELL_TAX_CLEAR_OVERRIDE
const COMMAND_CELL_TAX_CLEAR_ALL = PlayerCommandValidation.COMMAND_CELL_TAX_CLEAR_ALL
const COMMAND_CONSTRUCTION_BUILD = PlayerCommandValidation.COMMAND_CONSTRUCTION_BUILD
const COMMAND_POLITICAL_REGIME_SET = PlayerCommandValidation.COMMAND_POLITICAL_REGIME_SET
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
## 控制器把它们翻译成军事 facade 的一行 batch 提交，由后台返回生效日。
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
const COMMAND_MILITARY_ARMY_EXPLORE = PlayerCommandValidation.COMMAND_MILITARY_ARMY_EXPLORE
const COMMAND_MILITARY_ARMY_STOP = PlayerCommandValidation.COMMAND_MILITARY_ARMY_STOP
const COMMAND_MILITARY_ARMY_STANCE = PlayerCommandValidation.COMMAND_MILITARY_ARMY_STANCE
const COMMAND_MILITARY_ARMY_DISBAND = PlayerCommandValidation.COMMAND_MILITARY_ARMY_DISBAND
const COMMAND_MILITARY_WAR_DECLARE = PlayerCommandValidation.COMMAND_MILITARY_WAR_DECLARE
const COMMAND_MILITARY_PEACE_PROPOSE = PlayerCommandValidation.COMMAND_MILITARY_PEACE_PROPOSE
const COMMAND_MILITARY_PEACE_RESPOND = PlayerCommandValidation.COMMAND_MILITARY_PEACE_RESPOND
const CLOCK_CALLBACKS := {
	&"day_changed": &"_on_day_changed", &"season_changed": &"_on_season_changed",
	&"year_changed": &"_on_year_changed", &"visual_day_phase_changed": &"_on_visual_day_phase_changed",
	&"speed_changed": &"_on_speed_changed", &"control_changed": &"_on_clock_control_changed",
}

const SUPPORTED_COMMANDS = CommandRoutes.SUPPORTED_COMMANDS

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
var _cell_situation_picker: Callable
var _player_country_handle := 0
var _command_sequence := 1
var _pause_before_menu := false
var _country_facade = null
var _economy_facade = null
var _ideology_facade = null
var _modifier_facade = null
# Regime effects: the last (country, regime) pair whose Modifier rows were
# reconciled. Empty means "not reconciled yet", so the first commit after a
var _era_reward_generation := 0
var _era_reward_last_status := "NONE"
var _era_reward_dismissed_generation := 0
var _family_founding_offer_id := 0
var _shown_ideology_generation := 0


func configure(
		camera,
		highlight,
		runtime_host,
		world_clock,
		ui_manager
) -> void:
	SessionConnections.configure(self, camera, highlight, runtime_host, world_clock, ui_manager)


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
func _on_clock_control_changed(_paused: bool, _speed: float) -> void:
	AudioPresentation._on_clock_control_changed(self, _paused, _speed)


func music_situation_diagnostics() -> Dictionary:
	return AudioPresentation.music_situation_diagnostics(self)


func selected_cell():
	return AudioPresentation.selected_cell(self)


func capture_view_state() -> Dictionary:
	return _progression_component.capture_view_state(self)


func restore_view_state(map, state: Dictionary) -> void:
	_progression_component.restore_view_state(self, map, state)


func request_command(id: StringName, args: Dictionary = {}) -> Dictionary:
	return CommandDispatch.request_command(self, id, args)


func get_family_colonization_quotes(target_cell: int, family_filter: int = 0,
		source_filter: int = -1, offset: int = 0, limit: int = 64) -> Dictionary:
	return ColonizationReads.get_family_colonization_quotes(self, target_cell, family_filter, source_filter, offset, limit)


func get_family_colonization_quote_detail(quote_token: int,
		population: int = -1) -> Dictionary:
	return ColonizationReads.get_family_colonization_quote_detail(self, quote_token, population)


func get_family_dispatch_candidates(source_cell: int, offset: int = 0,
		limit: int = 64) -> Dictionary:
	return ColonizationReads.get_family_dispatch_candidates(self, source_cell, offset, limit)


func get_family_dispatch_preview(family_handle: int, source_cell: int) -> Dictionary:
	return ColonizationReads.get_family_dispatch_preview(self, family_handle, source_cell)


func can_family_colonize_from(family_handle: int, source_cell: int) -> bool:
	return ColonizationReads.can_family_colonize_from(self, family_handle, source_cell)


func dispatch_cell_display_name(cell: int) -> String:
	return ColonizationReads.dispatch_cell_display_name(self, cell)


func get_family_expeditions(offset: int = 0, limit: int = 64) -> Dictionary:
	return ColonizationReads.get_family_expeditions(self, offset, limit)


func get_family_expedition_snapshot(expedition_handle: int) -> Dictionary:
	return ColonizationReads.get_family_expedition_snapshot(self, expedition_handle)


func good_display_name(good_index: int) -> String:
	return ColonizationReads.good_display_name(self, good_index)


func get_family_snapshot(family_handle: int) -> Dictionary:
	return ColonizationReads.get_family_snapshot(self, family_handle)


func get_family_traits(family_handle: int) -> Dictionary:
	return ColonizationReads.get_family_traits(self, family_handle)


func is_player_owned_cell(cell: int) -> bool:
	return ColonizationReads.is_player_owned_cell(self, cell)


## ─── 触屏 GM 手势：三指双击 ──────────────────────────────────────────
## 安卓没有 F1/` 键，GM 面板以前只能在桌面上开。这里用「三指同时按下再松开」当一次
## tap，两次 tap 间隔 ≤800ms、每次按住 ≤450ms 就切 GM。两指缩放/单指拖动都不会命中。
## 只在 debug 构建且 GM 可用时生效（release 包 is_gm_available() 为 false）。
const TOUCH_GM_TAP_MAX_MS := 450
const TOUCH_GM_DOUBLE_WINDOW_MS := 800
var _touch_gm_active: Dictionary = {}
var _touch_gm_armed_ms := 0
var _touch_gm_tap_times: PackedInt64Array = PackedInt64Array()


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
	if _selection_component._is_text_editing(self):
		return
	if WorldInput._handle_touch_gm_gesture(self, event):
		get_viewport().set_input_as_handled()
		return
	if _selection_component._is_world_pointer_event(self, event):
		_selection_component._release_ordinary_ui_focus(self)
	_dispatch_player_input(event)


func handle_input(event: InputEvent) -> void:
	# Direct dispatch from PlayerGame / tests / embedded tools. Ordinary Control
	# focus still blocks this path so UI cannot be bypassed by calling us.
	if _selection_component._is_input_blocked_by_ui(self):
		return
	_dispatch_player_input(event)


func _dispatch_player_input(event: InputEvent) -> void:
	WorldInput._dispatch_player_input(self, event)


func _connect_runtime() -> void:
	SessionConnections._connect_runtime(self)


func _on_simulation_view_updated(_from_day: int, to_day: int, _generation: int) -> void:
	CommittedPresentation._on_simulation_view_updated(self, _from_day, to_day, _generation)


func refresh_selected_map_view(day: int) -> void:
	CommittedPresentation.refresh_selected_map_view(self, day)


func _on_simulation_ui_updated(_from_day: int, _to_day: int, _generation: int) -> void:
	CommittedPresentation._on_simulation_ui_updated(self, _from_day, _to_day, _generation)


func _on_simulation_day_records(_records: Array) -> void:
	CommittedPresentation._on_simulation_day_records(self, _records)


func player_confirmation_reason() -> String:
	return CommittedPresentation.player_confirmation_reason(self)


func _on_player_confirmation_updated(view: Dictionary) -> void:
	CommittedPresentation._on_player_confirmation_updated(self, view)


func _on_simulation_command_results(results: Array) -> void:
	CommittedPresentation._on_simulation_command_results(self, results)


func _on_simulation_committed(_from_day: int, _to_day: int, _generation: int) -> void:
	CommittedPresentation._on_simulation_committed(self, _from_day, _to_day, _generation)


func set_cell_situation_picker(picker: Callable) -> void:
	_cell_situation_picker = picker


func _on_tile_tapped(world_pos: Vector2) -> void:
	WorldInput._on_tile_tapped(self, world_pos)


## 军务档案拾取入口：命中部队/战线时打开右栏档案并返回 true（本次点击不再选格）。
## 拾取本身在图层里完成（token / front 各自拥有几何），这里只转发与接线。
func get_country_facade():
	return _country_facade


func get_economy_facade():
	return _economy_facade


func get_player_country_handle() -> int:
	return _player_country_handle


func _on_country_committed(report: Dictionary) -> void:
	CommittedPresentation._on_country_committed(self, report)


func _on_construction_command_settled(result: Dictionary) -> void:
	CommittedPresentation._on_construction_command_settled(self, result)


func _on_family_colonization_settled(result: Dictionary) -> void:
	CommittedPresentation._on_family_colonization_settled(self, result)


func _on_ideology_command_settled(result: Dictionary) -> void:
	CommittedPresentation._on_ideology_command_settled(self, result)


## 事件音效与交互式音乐用的增量状态
var _territory_snapshot := -1
var _last_music_pop_sample_ms := 0
var _camera_zoom_baseline := -1.0
var _camera_zoom_user_engaged := false
const MUSIC_POP_SAMPLE_INTERVAL_MS := 500

## 时代推进与国家人口驱动交互式配乐组曲（石器/农耕/王国/帝国）。
func _on_camera_zoom_changed(zoom_val: float) -> void:
	AudioPresentation._on_camera_zoom_changed(self, zoom_val)


func _on_camera_view_changed(world_rect: Rect2, _center: Vector2, zoom_value: float) -> void:
	AudioPresentation._on_camera_view_changed(self, world_rect, _center, zoom_value)


func music_camera_zoom_ratio() -> float:
	return AudioPresentation.music_camera_zoom_ratio(self)


static func camera_zoom_to_audio_ratio(zoom_val: float,
		min_zoom: float = 0.55, max_zoom: float = 3.6) -> float:
	return AudioPresentation.camera_zoom_to_audio_ratio(zoom_val, min_zoom, max_zoom)


func _on_day_changed(day_idx: int) -> void:
	ClockPresentation._on_day_changed(self, day_idx)


func _on_season_changed(season_idx: int) -> void:
	ClockPresentation._on_season_changed(self, season_idx)


func _on_year_changed(year_idx: int) -> void:
	ClockPresentation._on_year_changed(self, year_idx)


func _on_visual_day_phase_changed(phase: float) -> void:
	ClockPresentation._on_visual_day_phase_changed(self, phase)


func _on_speed_changed(speed: float) -> void:
	ClockPresentation._on_speed_changed(self, speed)


func _on_pause_toggled(paused: bool) -> void:
	ClockPresentation._on_pause_toggled(self, paused)


func _on_speed_selected(speed: float) -> void:
	ClockPresentation._on_speed_selected(self, speed)


func _on_pause_menu_visibility_changed(open: bool) -> void:
	ClockPresentation._on_pause_menu_visibility_changed(self, open)


func _resolve_player_country() -> Dictionary:
	return _progression_component._resolve_player_country(self)


func _validate_command_args(id: StringName, args: Dictionary, facade = null) -> Dictionary:
	return _progression_component._validate_command_args(self, id, args, facade)


static var _milestone_technology_ids: Dictionary = {}
var _era_advancement_snapshot_hash := 0


## UI model of §5. Always the exact documented shape.
static func is_milestone_technology(technology_id: StringName) -> bool:
	if _milestone_technology_ids.is_empty():
		var catalog: Dictionary = TechnologyCatalogForPlayerScript.compile_native_catalog()
		var ids: PackedStringArray = catalog.get("technology_ids", PackedStringArray())
		for index in catalog.get("technology_era_milestone_indices", PackedInt32Array()):
			if int(index) >= 0 and int(index) < ids.size():
				_milestone_technology_ids[StringName(ids[int(index)])] = true
	return _milestone_technology_ids.has(technology_id)


static func _confirmation_error_message(reason: String) -> String:
	match reason:
		"era_reward_offer_generation_stale":
			return "这组时代奖励已过期，请查看当前候选。"
		"era_reward_choice_invalid":
			return "这个时代奖励选项无效。"
		"family_founding_offer_missing", "family_founding_offer_stale":
			return "这组家族候选已过期，请查看当前候选。"
		"family_founding_offer_already_chosen":
			return "这组家族候选已经选择。"
		"family_founding_offer_not_player":
			return "只能选择本国地块的家族候选。"
		"family_founding_choice_invalid":
			return "这个家族扶持选项无效。"
	return reason


func _tax_item_exists(facade, kind: int, item_id: StringName) -> bool:
	return PlayerCommandValidation._tax_item_exists(facade, kind, item_id)


func _tax_rate_basis_points(args: Dictionary) -> int:
	return PlayerCommandValidation._tax_rate_basis_points(args)


func _tax_assessment_mode(args: Dictionary) -> int:
	return PlayerCommandValidation._tax_assessment_mode(args)


const MILITARY_COMMANDS = CommandRoutes.MILITARY_COMMANDS
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
	return _military_component._military_facade(self)


static func _military_command_entry(id: StringName, args: Dictionary) -> Dictionary:
	return PlayerControllerMilitaryScript._military_command_entry(id, args, MILITARY_COMMANDS)


var _military_last_sequence := -1
# Army order awaiting a map click (design §14.2). "move" previews the path on the
# first click and confirms on the second; "area" takes the first click as centre.
var _military_order_army := 0
var _military_order_mode := ""
var _military_order_radius := 0
var _military_order_target := -1
var _military_order_preview: Dictionary = {}
var _military_order_message := ""


static func _colonization_command_message(code: String) -> String:
	return CommandDispatch._colonization_command_message(code)


func _complete_command(id: StringName, result: Dictionary) -> Dictionary:
	return CommandDispatch._complete_command(self, id, result)


static func _result(ok: bool, code: String, message: String) -> Dictionary:
	return PlayerCommandValidation._result(ok, code, message)


# ─── Narrative Event System Integration ─────────────────────────────────────




# G5 responsibility adapters. Mutable state remains in this host.
func military_map_pick(world: Vector2) -> bool:
	return _military_component.military_map_pick(self, world)

func military_front_sector(edge_key: int) -> Dictionary:
	return _military_component.military_front_sector(self, edge_key)

func military_armies_at_cell(cell: int) -> Array:
	return _military_component.military_armies_at_cell(self, cell)

func military_army_cell(handle: int) -> int:
	return _military_component.military_army_cell(self, handle)

func clear_military_map_selection() -> void:
	_military_component.clear_military_map_selection(self)

func has_military_runtime() -> bool:
	return _military_component.has_military_runtime(self)

func military_last_sequence() -> int:
	return _military_component.military_last_sequence(self)

func begin_military_arm_order(army: int, mode: String, radius: int = 1) -> Dictionary:
	return _military_component.begin_military_arm_order(self, army, mode, radius)

func cancel_military_arm_order() -> void:
	_military_component.cancel_military_arm_order(self)

func military_arm_order() -> Dictionary:
	return _military_component.military_arm_order(self)

func set_military_arm_order_radius(radius: int) -> void:
	_military_component.set_military_arm_order_radius(self, radius)

func confirm_military_arm_order() -> Dictionary:
	return _military_component.confirm_military_arm_order(self)

func military_arm_order_click(cell: int) -> bool:
	return _military_component.military_arm_order_click(self, cell)

## The controller resolves the map and area so subclasses can supply their own view.
func _military_layers():
	return _military_component._military_layers(self)

func _military_area_cells(centre: int, radius: int) -> PackedInt32Array:
	return _military_component._military_area_cells(self, centre, radius)

func set_military_render_selection(army_handle: int) -> Dictionary:
	return _military_component.set_military_render_selection(self, army_handle)

func preview_military_path(army_handle: int, cell: int) -> Dictionary:
	return _military_component.preview_military_path(self, army_handle, cell)

func military_front_probe() -> Dictionary:
	return _military_component.military_front_probe(self)

func military_events_probe(limit: int = 512) -> Array:
	return _military_component.military_events_probe(self, limit)

func battle_log_probe() -> Dictionary:
	return _military_component.battle_log_probe(self)

func military_truce_until(_slot: int) -> int:
	return _military_component.military_truce_until(self, _slot)

func _on_era_reward_choice_requested(generation: int, choice_index: int) -> void:
	_progression_component._on_era_reward_choice_requested(self, generation, choice_index)

func open_era_reward_offer() -> void:
	_progression_component.open_era_reward_offer(self)

func dismiss_era_reward_offer() -> void:
	_progression_component.dismiss_era_reward_offer(self)

func _sync_era_reward_offer() -> void:
	_progression_component._sync_era_reward_offer(self)

func era_reward_locked() -> bool:
	return _progression_component.era_reward_locked(self)

func get_era_advancement_snapshot() -> Dictionary:
	return _progression_component.get_era_advancement_snapshot(self)

func get_procurement_policy() -> Dictionary:
	return _progression_component.get_procurement_policy(self)

func get_era_advancement_blocked_reason() -> String:
	return _progression_component.get_era_advancement_blocked_reason(self)

func register_era_session(save_service: Node) -> Dictionary:
	var module := preload("res://scripts/game/runtime_session_module.gd").new()
	module.configure("era", ["restore"], ["world.era"],
		_progression_component.prepare_era_session.bind(self, save_service),
		func() -> void: pass, _era_advancement.release_world)
	return _runtime_host.register_session_module(module)

func _on_era_advancement_changed(snapshot: Dictionary) -> void:
	_progression_component._on_era_advancement_changed(self, snapshot)

func _on_era_advancement_advanced(old_index: int, new_index: int,
		buffs: PackedStringArray) -> void:
	_progression_component._on_era_advancement_advanced(self, old_index, new_index, buffs)

func ideology_draw_phase() -> String:
	return _progression_component.ideology_draw_phase(self)

func ideology_offer_eligibility() -> Dictionary:
	return _progression_component.ideology_offer_eligibility(self)

func dismiss_ideology_offer(generation: int) -> Dictionary:
	return _progression_component.dismiss_ideology_offer(self, generation)

func dismiss_displayed_ideology_offer() -> void:
	if player_confirmation_reason() == "ideology_choice_required":
		var view: Dictionary = _runtime_host.player_confirmation_view()
		dismiss_ideology_offer(int(view.get("ideology_generation", 0)))


func family_founding_locked() -> bool:
	return _progression_component.family_founding_locked(self)

func _on_family_founding_choice_requested(offer_id: int, generation: int,
		choice_index: int) -> void:
	_progression_component._on_family_founding_choice_requested(self, offer_id, generation, choice_index)

func _sync_family_founding_offer() -> void:
	_progression_component._sync_family_founding_offer(self)

func focus_family_founding_cell(cell_idx: int = -1) -> void:
	_progression_component.focus_family_founding_cell(self, cell_idx)

func set_cell_highlight_set(node) -> void:
	_selection_component.set_cell_highlight_set(self, node)

func highlight_cells(cells: PackedInt32Array, frame: bool = true) -> int:
	return _selection_component.highlight_cells(self, cells, frame)

func clear_cell_highlights() -> void:
	_selection_component.clear_cell_highlights(self)

func set_peace_highlight_sets(candidate_set, draft_set) -> void:
	_selection_component.set_peace_highlight_sets(self, candidate_set, draft_set)

func highlight_peace_candidates(cells: PackedInt32Array) -> void:
	_selection_component.highlight_peace_candidates(self, cells)

func highlight_peace_draft(cells: PackedInt32Array) -> void:
	_selection_component.highlight_peace_draft(self, cells)

func clear_peace_highlights() -> void:
	_selection_component.clear_peace_highlights(self)

func focus_map_cell(cell_index: int) -> void:
	_selection_component.focus_map_cell(self, cell_index)

func ensure_selected_visible() -> void:
	_selection_component.ensure_selected_visible(self)

func select_cell(cell) -> void:
	_selection_component.select_cell(self, cell)

func clear_selection() -> void:
	_selection_component.clear_selection(self)

func sync_ui() -> void:
	_selection_component.sync_ui(self)

func refresh_country_binding() -> void:
	_selection_component.refresh_country_binding(self)

func focus_cell(cell: int) -> void:
	_selection_component.focus_cell(self, cell)

func narrative_service():
	return _narrative_component.narrative_service(self)

func narrative_flow():
	return _narrative_component.narrative_flow(self)

func narrative_ai_client():
	return _narrative_component.narrative_ai_client(self)

func narrative_event_locked() -> bool:
	return _narrative_component.narrative_event_locked(self)

func recheck_narrative_popup() -> void:
	_narrative_component.recheck_narrative_popup(self)


func open_narrative_chronicle(filter_cell: int = -1) -> void:
	_narrative_component.open_narrative_chronicle(self, filter_cell)

func _configure_narrative_runtime() -> void:
	NarrativeSession._configure_narrative_runtime(self)


func _prepare_narrative_session() -> Dictionary:
	return NarrativeSession._prepare_narrative_session(self)


func _cancel_narrative_session() -> void:
	NarrativeSession._cancel_narrative_session(self)


func _on_event_pause_changed(mask: int) -> void:
	_narrative_service.update_event_pause_mask(mask)


func _on_narrative_settings_changed(enabled: bool) -> void:
	_narrative_service.set_ai_enabled(enabled)


func _on_narrative_offer_changed(offer: Dictionary) -> void:
	_narrative_component._on_narrative_offer_changed(self, offer)

func _on_narrative_event_resolved(record: Dictionary) -> void:
	_narrative_component._on_narrative_event_resolved(self, record)

func _on_narrative_ai_generation_requested(request_spec: Dictionary) -> void:
	if _narrative_ai_client == null or _narrative_service == null:
		return
	_narrative_ai_client.request_event_generation(request_spec, _narrative_service.ai_reply_handler(request_spec))
