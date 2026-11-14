extends Node
class_name PlayerController
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
const COMMAND_MILITARY_ARMY_EXPLORE = PlayerCommandValidation.COMMAND_MILITARY_ARMY_EXPLORE
const COMMAND_MILITARY_ARMY_STOP = PlayerCommandValidation.COMMAND_MILITARY_ARMY_STOP
const COMMAND_MILITARY_ARMY_STANCE = PlayerCommandValidation.COMMAND_MILITARY_ARMY_STANCE
const COMMAND_MILITARY_ARMY_DISBAND = PlayerCommandValidation.COMMAND_MILITARY_ARMY_DISBAND
const COMMAND_MILITARY_WAR_DECLARE = PlayerCommandValidation.COMMAND_MILITARY_WAR_DECLARE
const COMMAND_MILITARY_PEACE_PROPOSE = PlayerCommandValidation.COMMAND_MILITARY_PEACE_PROPOSE
const COMMAND_MILITARY_PEACE_RESPOND = PlayerCommandValidation.COMMAND_MILITARY_PEACE_RESPOND
## A draw/choose/reroll that has not settled after this many simulated days
## releases the lock and restores the clock.
const IDEOLOGY_DRAW_TIMEOUT_DAYS := 3

const CLOCK_CALLBACKS := {
	&"day_changed": &"_on_day_changed", &"season_changed": &"_on_season_changed",
	&"year_changed": &"_on_year_changed", &"visual_day_phase_changed": &"_on_visual_day_phase_changed",
	&"speed_changed": &"_on_speed_changed", &"control_changed": &"_on_clock_control_changed",
}

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
	COMMAND_POLITICAL_REGIME_SET: true,
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
	COMMAND_MILITARY_ARMY_EXPLORE: true,
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
	if is_instance_valid(_world_clock):
		for signal_name in CLOCK_CALLBACKS:
			var callback := Callable(self, CLOCK_CALLBACKS[signal_name])
			if _world_clock.is_connected(signal_name, callback):
				_world_clock.disconnect(signal_name, callback)
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
	if _music_playback == null:
		_music_playback = MusicSituationPlaybackScript.new()
		_music_playback.situation = _music_situation
		add_child(_music_playback)
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


func _on_clock_control_changed(_paused: bool, _speed: float) -> void:
	if _popups_suppressed and _suppression_resume_running and _world_clock != null \
			and _world_clock.paused and not _world_clock.authority_fault_hold \
			and _is_suppressed_popup_pause_source(String(_world_clock.last_pause_source)):
		# 等这次时钟通知完成后释放被屏蔽提示申请的暂停。
		# 只释放已知的 UI 自动暂停来源，保留手动暂停、存档暂停和故障保护。
		_world_clock.pause(false)
		_sync_clock_visual_state()


func music_situation_diagnostics() -> Dictionary:
	return _music_situation.diagnostics() if _music_situation != null else {}


func selected_cell():
	return _selected_cell


## The many-cell overlay that answers "where does this card act?". Injected
## separately from `configure` so every existing caller keeps working, and so a
## headless session (which builds no WorldRoot children) can simply not set it.
func _configure_music_situation() -> void:
	_narrative_component._configure_music_situation(self)


func capture_view_state() -> Dictionary:
	return _progression_component.capture_view_state(self)


func restore_view_state(map, state: Dictionary) -> void:
	_progression_component.restore_view_state(self, map, state)


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
		COMMAND_POLITICAL_REGIME_SET:
			result = facade.set_political_regime(_player_country_handle,
				StringName(args.get("regime_id", &"")), effective_day, sequence) \
				if facade.has_method("set_political_regime") else _result(false,
				"runtime_unavailable", "体制系统尚未就绪，请稍后再试。")
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
	if id == COMMAND_POLITICAL_REGIME_SET and bool(result.get("ok", false)):
		result["code"] = String(result.get("code", "queued"))
		result["message"] = "体制调整已排队，将在下一次国家结算后生效。"
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
	if _economy_facade == null or not _economy_facade.has_method("family_expeditions"):
		return _result(false, "runtime_unavailable", "经济系统尚未就绪，请稍后再试。")
	return _economy_facade.family_expeditions(_player_country_handle,
		offset, limit)


func get_family_expedition_snapshot(expedition_handle: int) -> Dictionary:
	var ready := _resolve_player_country()
	if not bool(ready.get("ok", false)):
		return ready
	if _economy_facade == null or not _economy_facade.has_method("family_expedition_snapshot"):
		return _result(false, "runtime_unavailable", "经济系统尚未就绪，请稍后再试。")
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
	for signal_name in CLOCK_CALLBACKS:
		var callback := Callable(self, CLOCK_CALLBACKS[signal_name])
		if not _world_clock.is_connected(signal_name, callback):
			_world_clock.connect(signal_name, callback,
				CONNECT_DEFERRED if signal_name == &"control_changed" else 0)


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
	_narrative_component._sync_era_music(self, force_population_sync)


func _sync_camera_zoom_audio(reset_baseline: bool = false) -> void:
	_narrative_component._sync_camera_zoom_audio(self, reset_baseline)


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
	return _narrative_component.music_camera_zoom_ratio(self)


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
	_narrative_component._sync_event_audio(self)


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
	return _progression_component._resolve_player_country(self)


func _request_research_queue(facade, operation: String, args: Dictionary,
		effective_day: int, sequence: int) -> Dictionary:
	return _progression_component._request_research_queue(self, facade, operation, args, effective_day, sequence)


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


static func _ideology_draw_failure_message(reason: String) -> String:
	if reason.is_empty():
		return ""
	if reason == "ideology_draw_timeout":
		return "抽取超时，请重试。"
	return CountryViewModel.ideology_player_reason(reason)


## Close the visible offer without choosing; the offer stays pending natively.
func _tax_item_exists(facade, kind: int, item_id: StringName) -> bool:
	return PlayerCommandValidation._tax_item_exists(facade, kind, item_id)


func _tax_rate_basis_points(args: Dictionary) -> int:
	return PlayerCommandValidation._tax_rate_basis_points(args)


func _tax_assessment_mode(args: Dictionary) -> int:
	return PlayerCommandValidation._tax_assessment_mode(args)


func _validate_owned_cell(facade, cell: int) -> Dictionary:
	return _progression_component._validate_owned_cell(self, facade, cell)


func _next_effective_day() -> int:
	return _progression_component._next_effective_day(self)


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
	COMMAND_MILITARY_ARMY_EXPLORE: "army.explore",
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
	return _military_component._military_facade(self)


static func _military_command_entry(id: StringName, args: Dictionary) -> Dictionary:
	return PlayerControllerMilitaryScript._military_command_entry(id, args, MILITARY_COMMANDS)


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
	return _selection_component._cell_display_world(self, cell)


func _is_text_editing() -> bool:
	return _selection_component._is_text_editing(self)


func _is_input_blocked_by_ui() -> bool:
	return _selection_component._is_input_blocked_by_ui(self)


func _is_world_pointer_event(event: InputEvent) -> bool:
	return _selection_component._is_world_pointer_event(self, event)


func _release_ordinary_ui_focus() -> void:
	_selection_component._release_ordinary_ui_focus(self)


static func _result(ok: bool, code: String, message: String) -> Dictionary:
	return PlayerCommandValidation._result(ok, code, message)


# ─── Narrative Event System Integration ─────────────────────────────────────

var _last_narrative_step_day: int = -1



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

func _state_building_gate(cell: int, building: int,
		demolishing: bool = false) -> Dictionary:
	return _military_component._state_building_gate(self, cell, building, demolishing)

func _player_owns_military_cell(cell: int) -> Dictionary:
	return _military_component._player_owns_military_cell(self, cell)

func _completed_technology_ids():
	return _military_component._completed_technology_ids(self)

func _submit_state_build_command(args: Dictionary, effective_day: int,
		sequence: int) -> Dictionary:
	return _military_component._submit_state_build_command(self, args, effective_day, sequence)

func _submit_state_demolish_command(args: Dictionary, effective_day: int,
		sequence: int) -> Dictionary:
	return _military_component._submit_state_demolish_command(self, args, effective_day, sequence)

func _submit_military_command(id: StringName, args: Dictionary,
		effective_day: int, sequence: int) -> Dictionary:
	return _military_component._submit_military_command(self, id, args, effective_day, sequence)

func military_last_sequence() -> int:
	return _military_component.military_last_sequence(self)

func _remember_military_budget(args: Dictionary) -> void:
	_military_component._remember_military_budget(self, args)

func _restore_military_budget(state) -> void:
	_military_component._restore_military_budget(self, state)

func _repush_military_budget() -> bool:
	return _military_component._repush_military_budget(self)

func begin_military_arm_order(army: int, mode: String, radius: int = 1) -> Dictionary:
	return _military_component.begin_military_arm_order(self, army, mode, radius)

func cancel_military_arm_order() -> void:
	_military_component.cancel_military_arm_order(self)

func military_arm_order() -> Dictionary:
	return _military_component.military_arm_order(self)

func _notify_military_arm_order() -> void:
	_military_component._notify_military_arm_order(self)

func set_military_arm_order_radius(radius: int) -> void:
	_military_component.set_military_arm_order_radius(self, radius)

func confirm_military_arm_order() -> Dictionary:
	return _military_component.confirm_military_arm_order(self)

func military_arm_order_click(cell: int) -> bool:
	return _military_component.military_arm_order_click(self, cell)

func _preview_failed(preview: Dictionary, cell: int) -> void:
	_military_component._preview_failed(self, preview, cell)

func _show_military_path_preview(preview: Dictionary, cell: int) -> bool:
	return _military_component._show_military_path_preview(self, preview, cell)

func _clear_military_path_preview() -> void:
	_military_component._clear_military_path_preview(self)

func _military_area_cells(centre: int, radius: int) -> PackedInt32Array:
	return _military_component._military_area_cells(self, centre, radius)

func _apply_military_render_selection(army: int) -> void:
	_military_component._apply_military_render_selection(self, army)

func _military_layers():
	return _military_component._military_layers(self)

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

func _era_advancement_preview() -> Dictionary:
	return _progression_component._era_advancement_preview(self)

func _bind_era_advancement() -> void:
	_progression_component._bind_era_advancement(self)

func _restore_era_advancement(state) -> void:
	_progression_component._restore_era_advancement(self, state)

func _refresh_era_advancement(force: bool = false) -> void:
	_progression_component._refresh_era_advancement(self, force)

func _allocate_command_sequence() -> int:
	return _progression_component._allocate_command_sequence(self)

func _on_era_advancement_changed(snapshot: Dictionary) -> void:
	_progression_component._on_era_advancement_changed(self, snapshot)

func _on_era_advancement_advanced(old_index: int, new_index: int,
		buffs: PackedStringArray) -> void:
	_progression_component._on_era_advancement_advanced(self, old_index, new_index, buffs)

func ideology_draw_locked() -> bool:
	return _progression_component.ideology_draw_locked(self)

func ideology_draw_phase() -> String:
	return _progression_component.ideology_draw_phase(self)

func ideology_offer_eligibility() -> Dictionary:
	return _progression_component.ideology_offer_eligibility(self)

func _ideology_player_snapshot() -> Dictionary:
	return _progression_component._ideology_player_snapshot(self)

func _begin_ideology_draw(phase: String, sequence: int) -> void:
	_progression_component._begin_ideology_draw(self, phase, sequence)

func _sync_ideology_draw() -> void:
	_progression_component._sync_ideology_draw(self)

func _finish_ideology_draw(failure_reason: String) -> void:
	_progression_component._finish_ideology_draw(self, failure_reason)

func dismiss_ideology_offer() -> void:
	_progression_component.dismiss_ideology_offer(self)

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

func _paint_peace_set(node, cells: PackedInt32Array) -> void:
	_selection_component._paint_peace_set(self, node, cells)

func _cell_centers(cells: PackedInt32Array) -> PackedVector2Array:
	return _selection_component._cell_centers(self, cells)

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

func set_popups_suppressed(enabled: bool) -> void:
	_narrative_component.set_popups_suppressed(self, enabled)

func _is_suppressed_popup_pause_source(source: String) -> bool:
	return _narrative_component._is_suppressed_popup_pause_source(self, source)

func export_narrative_state() -> Dictionary:
	return _narrative_component.export_narrative_state(self)

func restore_narrative_state(state: Dictionary) -> Dictionary:
	return _narrative_component.restore_narrative_state(self, state)

func open_narrative_chronicle(filter_cell: int = -1) -> void:
	_narrative_component.open_narrative_chronicle(self, filter_cell)

func _configure_narrative_runtime() -> void:
	_narrative_component._configure_narrative_runtime(self)

func _step_narrative_daily(day_idx: int) -> void:
	_narrative_component._step_narrative_daily(self, day_idx)

func _on_narrative_offer_changed(offer: Dictionary) -> void:
	_narrative_component._on_narrative_offer_changed(self, offer)

func _on_narrative_event_resolved(record: Dictionary) -> void:
	_narrative_component._on_narrative_event_resolved(self, record)

func _on_narrative_ai_generation_requested(request_spec: Dictionary) -> void:
	if _narrative_ai_client == null or _narrative_service == null:
		return
	_narrative_ai_client.request_event_generation(request_spec, func(res: Dictionary) -> void:
		if _narrative_service == null:
			return
		# 回执的落地判定（时效、归属、节奏）归服务层：控制器只转发传输结果。
		var arrival_day: int = int(_world_clock.day_index()) if _world_clock != null else -1
		_narrative_service.accept_ai_generation(res, arrival_day)
		_narrative_flow.try_present()
	)
