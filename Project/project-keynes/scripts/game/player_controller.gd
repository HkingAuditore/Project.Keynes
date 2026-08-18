extends Node
class_name PlayerController

## Formal player-session boundary. It translates Godot/UI intent into the
## existing runtime and country facades; it never owns simulation state.

signal selection_changed(cell)
signal command_completed(id: StringName, result: Dictionary)
signal command_settled(id: StringName, result: Dictionary)
signal regeneration_requested()
signal country_committed(report: Dictionary)
signal era_reward_offer_changed(offer: Dictionary)

const COMMAND_RESEARCH_SET_WEIGHTS := &"research.set_weights"
const COMMAND_RESEARCH_SET_BUDGET := &"research.set_budget"
const COMMAND_RESEARCH_ENQUEUE := &"research.enqueue"
const COMMAND_RESEARCH_REMOVE := &"research.remove"
const COMMAND_RESEARCH_MOVE := &"research.move"
const COMMAND_COUNTRY_TAX_SET_DEFAULT := &"country.tax.set_default"
const COMMAND_COUNTRY_TAX_SET_OVERRIDE := &"country.tax.set_override"
const COMMAND_COUNTRY_TAX_CLEAR_OVERRIDE := &"country.tax.clear_override"
const COMMAND_CELL_TAX_SET_DEFAULT := &"country.tax.cell.set_default"
const COMMAND_CELL_TAX_CLEAR_DEFAULT := &"country.tax.cell.clear_default"
const COMMAND_CELL_TAX_SET_OVERRIDE := &"country.tax.cell.set_override"
const COMMAND_CELL_TAX_CLEAR_OVERRIDE := &"country.tax.cell.clear_override"
const COMMAND_CELL_TAX_CLEAR_ALL := &"country.tax.cell.clear_all"
const COMMAND_CONSTRUCTION_BUILD := &"construction.build"
const COMMAND_FAMILY_COLONIZATION_START := &"family.colonization.start"
const COMMAND_FAMILY_COLONIZATION_CANCEL := &"family.colonization.cancel"
const COMMAND_ERA_REWARD_CHOOSE := &"era_reward.choose"
const COMMAND_IDEOLOGY_OFFER := &"ideology.offer"
const COMMAND_IDEOLOGY_CHOOSE := &"ideology.choose"
const COMMAND_IDEOLOGY_EQUIP := &"ideology.equip"
const COMMAND_IDEOLOGY_UNEQUIP := &"ideology.unequip"
const COMMAND_IDEOLOGY_PROMOTE := &"ideology.promote"

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
	COMMAND_IDEOLOGY_OFFER: true,
	COMMAND_IDEOLOGY_CHOOSE: true,
	COMMAND_IDEOLOGY_EQUIP: true,
	COMMAND_IDEOLOGY_UNEQUIP: true,
	COMMAND_IDEOLOGY_PROMOTE: true,
}

var _camera = null
var _highlight = null
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
	_connect_runtime()
	_connect_ui()
	sync_ui()


func selected_cell():
	return _selected_cell


func ensure_selected_visible() -> void:
	if _selected_cell == null or _camera == null or _ui_manager == null:
		return
	_camera.ensure_point_visible(_cell_display_world(_selected_cell),
		_ui_manager.map_safe_area())


func select_cell(cell) -> void:
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
		_sync_era_reward_offer()


func capture_view_state() -> Dictionary:
	return {
		"selected_cell": int(_selected_cell.index) if _selected_cell != null else -1,
		"camera_position": _camera.global_position if _camera != null else Vector2.ZERO,
		"camera_zoom": _camera.zoom if _camera != null else Vector2.ONE,
		"next_command_sequence": _command_sequence,
		"era_reward_locked": _era_reward_locked,
		"era_reward_resume_running": _era_reward_resume_running,
		"era_reward_previous_speed": _era_reward_previous_speed,
		"era_reward_generation": _era_reward_generation,
	}


func restore_view_state(map, state: Dictionary) -> void:
	_command_sequence = maxi(1, int(state.get("next_command_sequence", 1)))
	_era_reward_resume_running = bool(state.get("era_reward_resume_running", false))
	_era_reward_previous_speed = float(state.get("era_reward_previous_speed", 1.0))
	_era_reward_generation = int(state.get("era_reward_generation", 0))
	_era_reward_locked = bool(state.get("era_reward_locked", false))
	if _camera != null:
		_camera.global_position = state.get("camera_position", _camera.global_position)
		_camera.zoom = state.get("camera_zoom", _camera.zoom)
	if map != null:
		var selected := int(state.get("selected_cell", -1))
		if selected >= 0 and selected < map.cell_count():
			select_cell(map.cell_at(selected))
		else:
			clear_selection()
	_sync_era_reward_offer()


func request_command(id: StringName, args: Dictionary = {}) -> Dictionary:
	if _era_reward_locked and id != COMMAND_ERA_REWARD_CHOOSE:
		return _complete_command(id, _result(false,
			"era_reward_choice_required", "必须先完成时代奖励选择。"))
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
		id == COMMAND_ERA_REWARD_CHOOSE else _next_effective_day()
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
			result = facade.set_tax_default(_player_country_handle,
				int(args.kind), int(args.rate_percent), effective_day, sequence)
		COMMAND_COUNTRY_TAX_SET_OVERRIDE:
			result = facade.set_tax_override(_player_country_handle,
				int(args.kind), StringName(args.item_id), int(args.rate_percent),
				effective_day, sequence)
		COMMAND_COUNTRY_TAX_CLEAR_OVERRIDE:
			result = facade.clear_tax_override(_player_country_handle,
				int(args.kind), StringName(args.item_id), effective_day, sequence)
		COMMAND_CELL_TAX_SET_DEFAULT:
			result = facade.set_cell_tax_default(_player_country_handle,
				int(args.cell), int(args.kind), int(args.rate_percent),
				effective_day, sequence)
		COMMAND_CELL_TAX_CLEAR_DEFAULT:
			result = facade.clear_cell_tax_default(_player_country_handle,
				int(args.cell), int(args.kind), effective_day, sequence)
		COMMAND_CELL_TAX_SET_OVERRIDE:
			result = facade.set_cell_tax_override(_player_country_handle,
				int(args.cell), int(args.kind), StringName(args.item_id),
				int(args.rate_percent), effective_day, sequence)
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
				result = _result(false, "runtime_unavailable", "经济运行时尚未就绪。")
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
		COMMAND_IDEOLOGY_OFFER:
			result = _ideology_facade.request_offer(
				_player_country_handle, effective_day, sequence)
		COMMAND_IDEOLOGY_CHOOSE:
			result = _ideology_facade.choose_offer(_player_country_handle,
				int(args.get("offer_generation", 0)),
				int(args.get("choice_index", -1)), effective_day, sequence)
		COMMAND_IDEOLOGY_EQUIP:
			result = _ideology_facade.equip(_player_country_handle,
				int(args.get("ideology_id", -1)), effective_day, sequence)
		COMMAND_IDEOLOGY_UNEQUIP:
			result = _ideology_facade.unequip(_player_country_handle,
				int(args.get("ideology_id", -1)), effective_day, sequence)
		COMMAND_IDEOLOGY_PROMOTE:
			result = _ideology_facade.promote(_player_country_handle,
				int(args.get("ideology_id", -1)), effective_day, sequence)
		_:
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
		return _result(false, "runtime_unavailable", "经济运行时尚未就绪。")
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


func get_family_snapshot(family_handle: int) -> Dictionary:
	if _economy_facade == null:
		return _result(false, "runtime_unavailable", "经济运行时尚未就绪。")
	return _economy_facade.family_snapshot(family_handle)


func get_family_traits(family_handle: int) -> Dictionary:
	if _economy_facade == null:
		return _result(false, "runtime_unavailable", "经济运行时尚未就绪。")
	return _economy_facade.get_family_traits(family_handle)


func is_player_owned_cell(cell: int) -> bool:
	var ready := _resolve_player_country()
	return bool(ready.get("ok", false)) and bool(
		_validate_owned_cell(ready.facade, cell).get("ok", false))


func _unhandled_input(event: InputEvent) -> void:
	# GUI 已消费的事件不会到这里。文本框必须继续挡住地图手势；
	# 普通按钮焦点不得锁死选格/缩放/拖拽，否则左侧 overlay 点完就无法操作地图。
	if _is_text_editing():
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
	if _camera != null and _camera.handle_player_input(event):
		get_viewport().set_input_as_handled()
		return
	if not (event is InputEventKey) or not event.pressed or event.echo:
		return
	var key := event as InputEventKey
	var debug_hotkeys_enabled := OS.is_debug_build()
	if key.is_action_pressed(&"player_pause"):
		if _world_clock != null:
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


func _connect_runtime() -> void:
	if _camera != null and not _camera.tile_tapped.is_connected(_on_tile_tapped):
		_camera.tile_tapped.connect(_on_tile_tapped)
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
	_ui_manager.set_player_controller(self)
	refresh_country_binding()


func _on_tile_tapped(world_pos: Vector2) -> void:
	if _runtime_host == null or _runtime_host.current_map() == null:
		return
	var cell: Variant = HexUtils.world_to_wrapped_cell(_runtime_host.current_map(), world_pos,
		_runtime_host.hex_size)
	if cell != null:
		select_cell(cell)


func _on_country_committed(report: Dictionary) -> void:
	country_committed.emit(report)
	_sync_era_reward_offer()


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
	}.get(int(result.get("opcode", 0)), &"ideology.unknown") as StringName
	command_settled.emit(command_id, result)


func _on_day_changed(day_idx: int) -> void:
	if _runtime_host == null or _world_clock == null:
		return
	var season_phase: float = _world_clock.season_phase_for_day(day_idx)
	_runtime_host.run_daily_tick(day_idx, season_phase)
	_sync_era_reward_offer()
	if _economy_facade != null and _player_country_handle != 0 and \
			_economy_facade.has_method("dispatch_family_colonization_receipts"):
		_economy_facade.dispatch_family_colonization_receipts(
			_player_country_handle)
	var ui_started_usec := Time.get_ticks_usec()
	var ui_breakdown: Dictionary = {}
	if _ui_manager != null:
		ui_breakdown = _ui_manager.refresh_selected_daily_lines(false, day_idx)
		var country_timing: Dictionary = _ui_manager.refresh_country_summary()
		ui_breakdown["country_summary_ms"] = float(country_timing.get("elapsed_ms", 0.0))
		sync_ui()
	_runtime_host.finish_daily_tick((Time.get_ticks_usec() - ui_started_usec) / 1000.0, ui_breakdown)


func _on_season_changed(season_idx: int) -> void:
	if _runtime_host != null:
		_runtime_host.on_season_changed(season_idx)
	if _ui_manager != null:
		_ui_manager.refresh_selected_daily_lines(true)
		_ui_manager.refresh_country_summary()
	sync_ui()


func _on_year_changed(year_idx: int) -> void:
	if _runtime_host != null:
		_runtime_host.on_year_changed(year_idx)
	if _ui_manager != null:
		_ui_manager.refresh_selected_daily_lines(true)
		_ui_manager.refresh_country_summary()
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
	if _world_clock != null:
		_world_clock.pause(paused)
		sync_ui()


func _on_speed_selected(speed: float) -> void:
	if _world_clock != null:
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
		return _result(false, "runtime_unavailable", "玩家运行时尚未就绪。")
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
	match id:
		COMMAND_RESEARCH_SET_WEIGHTS:
			var weights_value = args.get("weights_bp", null)
			if not weights_value is PackedInt32Array:
				return _result(false, "invalid_args", "研究权重参数类型无效。")
			var weights: PackedInt32Array = weights_value
			if weights.size() != 4:
				return _result(false, "invalid_args", "研究权重必须包含四个领域。")
			var total := 0
			for weight in weights:
				if weight < 0:
					return _result(false, "invalid_args", "研究权重不能为负。")
				total += weight
			if total != 10000:
				return _result(false, "invalid_args", "研究权重总和必须为 10000。")
		COMMAND_RESEARCH_SET_BUDGET:
			if not args.has("enabled") or not args.has("daily_cash_limit"):
				return _result(false, "invalid_args", "研究预算参数不完整。")
			if int(args.get("daily_cash_limit", -1)) < 0:
				return _result(false, "invalid_args", "研究预算不能为负。")
		COMMAND_RESEARCH_ENQUEUE, COMMAND_RESEARCH_REMOVE, COMMAND_RESEARCH_MOVE:
			var technology_id := StringName(args.get("technology_id", &""))
			if technology_id.is_empty():
				return _result(false, "invalid_args", "缺少科技标识。")
			if id == COMMAND_RESEARCH_ENQUEUE:
				var domain := int(args.get("domain", -1))
				if domain < 0 or domain >= 4:
					return _result(false, "invalid_args", "科技领域无效。")
			elif id == COMMAND_RESEARCH_MOVE:
				var move_domain := int(args.get("domain", -1))
				var position := int(args.get("position", -1))
				if move_domain < 0 or move_domain >= 4 or position < 0:
					return _result(false, "invalid_args", "研究队列位置无效。")
		COMMAND_COUNTRY_TAX_SET_DEFAULT, COMMAND_COUNTRY_TAX_SET_OVERRIDE, \
				COMMAND_COUNTRY_TAX_CLEAR_OVERRIDE, COMMAND_CELL_TAX_SET_DEFAULT, \
				COMMAND_CELL_TAX_CLEAR_DEFAULT, COMMAND_CELL_TAX_SET_OVERRIDE, \
				COMMAND_CELL_TAX_CLEAR_OVERRIDE:
			var kind := int(args.get("kind", -1))
			if kind < 0 or kind >= 5:
				return _result(false, "invalid_tax_kind", "税种无效。")
			if id == COMMAND_COUNTRY_TAX_SET_DEFAULT or \
					id == COMMAND_CELL_TAX_SET_DEFAULT or \
					id == COMMAND_CELL_TAX_SET_OVERRIDE or \
					id == COMMAND_COUNTRY_TAX_SET_OVERRIDE:
				var rate := int(args.get("rate_percent", 101))
				if rate < -100 or rate > 100:
					return _result(false, "invalid_tax_rate", "税率必须在 -100 到 100 之间。")
			if id == COMMAND_COUNTRY_TAX_SET_OVERRIDE or \
					id == COMMAND_COUNTRY_TAX_CLEAR_OVERRIDE or \
					id == COMMAND_CELL_TAX_SET_OVERRIDE or \
					id == COMMAND_CELL_TAX_CLEAR_OVERRIDE:
				var item_id := StringName(args.get("item_id", &""))
				if item_id.is_empty() or not _tax_item_exists(facade, kind, item_id):
					return _result(false, "invalid_tax_item", "税务细项目标无效。")
			if id == COMMAND_CELL_TAX_SET_DEFAULT or \
					id == COMMAND_CELL_TAX_CLEAR_DEFAULT or \
					id == COMMAND_CELL_TAX_SET_OVERRIDE or \
					id == COMMAND_CELL_TAX_CLEAR_OVERRIDE:
				var owned := _validate_owned_cell(facade, int(args.get("cell", -1)))
				if not bool(owned.ok):
					return owned
		COMMAND_CELL_TAX_CLEAR_ALL:
			var owned := _validate_owned_cell(facade, int(args.get("cell", -1)))
			if not bool(owned.ok):
				return owned
		COMMAND_CONSTRUCTION_BUILD:
			if StringName(args.get("building_id", &"")).is_empty():
				return _result(false, "invalid_args", "缺少建筑标识。")
			if StringName(args.get("ownership_policy", &"")) \
					!= &"treasury_sponsored_private":
				return _result(false, "unsupported_ownership_policy",
					"当前版本仅支持国库资助私人经营。")
			var owned := _validate_owned_cell(facade, int(args.get("cell_idx", -1)))
			if not bool(owned.ok):
				return _result(false, "construction_cell_not_owned",
					"只能在玩家领土内修建建筑。")
		COMMAND_FAMILY_COLONIZATION_START:
			if int(args.get("family_handle", 0)) == 0 or \
					int(args.get("source_cell", -1)) < 0 or \
					int(args.get("target_cell", -1)) < 0 or \
					int(args.get("population", 0)) < 1 or \
					int(args.get("quote_token", 0)) == 0:
				return _result(false, "invalid_args", "开拓命令参数不完整。")
		COMMAND_FAMILY_COLONIZATION_CANCEL:
			if int(args.get("expedition_handle", 0)) == 0:
				return _result(false, "invalid_args", "开拓队句柄无效。")
		COMMAND_ERA_REWARD_CHOOSE:
			var choice := int(args.get("choice_index", -1))
			var generation := int(args.get("offer_generation", 0))
			if choice < 0 or choice > 2 or generation <= 0 \
					or generation != _era_reward_generation:
				return _result(false, "era_reward_choice_invalid",
					"时代奖励代际或选项无效。")
		COMMAND_IDEOLOGY_OFFER:
			if _ideology_facade == null:
				return _result(false, "runtime_unavailable", "理念运行时尚未就绪。")
		COMMAND_IDEOLOGY_CHOOSE:
			if _ideology_facade == null:
				return _result(false, "runtime_unavailable", "理念运行时尚未就绪。")
			if int(args.get("offer_generation", 0)) <= 0 or \
					int(args.get("choice_index", -1)) < 0 or \
					int(args.get("choice_index", -1)) > 2:
				return _result(false, "invalid_args", "理念候选代际或选项无效。")
		COMMAND_IDEOLOGY_EQUIP, COMMAND_IDEOLOGY_UNEQUIP, \
				COMMAND_IDEOLOGY_PROMOTE:
			if _ideology_facade == null:
				return _result(false, "runtime_unavailable", "理念运行时尚未就绪。")
			if int(args.get("ideology_id", -1)) < 0:
				return _result(false, "invalid_args", "理念标识无效。")
	return _result(true, "ok", "")


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


func _sync_era_reward_offer() -> void:
	if _country_facade == null or not _country_facade.has_method("era_reward_offer"):
		return
	var offer: Dictionary = _country_facade.era_reward_offer()
	if not bool(offer.get("ok", false)):
		return
	var status := String(offer.get("status", "NONE"))
	_era_reward_last_status = status
	if status == "OPEN" or status == "SELECTED_PENDING" or status == "ERROR":
		if not _era_reward_locked:
			_era_reward_resume_running = _world_clock != null and not _world_clock.paused
			_era_reward_previous_speed = _world_clock.speed_multiplier \
				if _world_clock != null else 1.0
			_era_reward_locked = true
		if _world_clock != null:
			_world_clock.pause(true)
		_era_reward_generation = int(offer.get("offer_generation", 0))
		if _ui_manager != null:
			if not _ui_manager.is_era_reward_modal_open():
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
	if status == "RESOLVED" and _era_reward_locked:
		if _ui_manager != null:
			_ui_manager.close_era_reward_offer()
		if _world_clock != null:
			_world_clock.set_speed(_era_reward_previous_speed)
			_world_clock.pause(not _era_reward_resume_running)
		_era_reward_locked = false
		_era_reward_generation = 0
		sync_ui()
		era_reward_offer_changed.emit(offer)


func era_reward_locked() -> bool:
	return _era_reward_locked


func _tax_item_exists(facade, kind: int, item_id: StringName) -> bool:
	if facade == null or not facade.has_method("native_catalog"):
		return false
	var key := ""
	match kind:
		0: key = "profession_ids"
		1, 3, 4: key = "good_ids"
		2: key = "building_type_ids"
		_: return false
	var ids: PackedStringArray = facade.native_catalog().get(key, PackedStringArray())
	return ids.find(String(item_id)) >= 0


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


static func _colonization_command_message(code: String) -> String:
	return {
		"economy_busy_retry": "经济正在结算。可先排队，提交完成后会自动派遣。",
		"colonization_queued": "派遣已排队，将在经济结算完成后出发。",
		"colonization_cancel_queued": "取消已排队，将在经济结算完成后执行。",
		"economy_paused": "经济已因守恒失败暂停，无法派遣。",
		"economy_not_available": "经济运行时尚未就绪。",
		"colonization_requote_required": "地图、视野或领土已经变化，请重新确认报价。",
		"colonization_kit_requote_required": "目标资源或科技已经变化，请重新确认开工包。",
		"colonization_kit_materials_short": "源地市场库存不足，无法抽出开工包物资。",
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
	return {"ok": ok, "code": code, "message": message}
