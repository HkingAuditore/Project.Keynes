extends SceneTree

const PlayerControllerScript = preload("res://scripts/game/player_controller.gd")

class ColonizationQuoteStub:
	var quotes: Dictionary = {}
	var detail: Dictionary = {}
	var snapshot: Dictionary = {
		"ok": true,
		"population": 40,
		"surname": "王",
		"surname_disambiguator": 0,
		"family_name": "长安王氏",
	}
	var traits: Dictionary = {
		"ok": true,
		"display_names": PackedStringArray(["采集传统"]),
		"core": PackedByteArray([1]),
		"descriptions": PackedStringArray(["更倾向投资采集建筑，并随威望提高本城总体产出。"]),
		"behavior_selector_display_names": PackedStringArray(["采集营地"]),
	}

	func get_family_colonization_quotes(_target_cell: int = 0,
			_family_filter: int = 0, _source_filter: int = -1,
			_offset: int = 0, _limit: int = 64) -> Dictionary:
		return quotes

	func get_family_colonization_quote_detail(_token: int = 0,
			_population: int = -1) -> Dictionary:
		return detail

	func get_family_expeditions(_offset: int = 0, _limit: int = 64) -> Dictionary:
		return {
			"ok": true,
			"busy": bool(quotes.get("busy", false)),
			"expedition_handles": PackedInt64Array(),
			"family_handles": PackedInt64Array(),
			"source_cells": PackedInt32Array(),
			"target_cells": PackedInt32Array(),
			"populations": PackedInt64Array(),
			"departure_days": PackedInt64Array(),
			"due_days": PackedInt64Array(),
			"route_costs": PackedInt32Array(),
			"states": PackedInt32Array(),
			"total": 0,
		}

	func get_family_snapshot(_family_handle: int = 0) -> Dictionary:
		return snapshot

	func get_family_traits(_family_handle: int = 0) -> Dictionary:
		return traits


var _failures := 0


const EconomyFacadeScript = preload("res://scripts/economy/economy_facade.gd")


func _init() -> void:
	_expect("chinese origin family names use city plus surname plus suffix",
		EconomyFacadeScript.compose_family_display_name(
			"长安", "李", "CITY_SURNAME_SUFFIX", "-", "氏") == "长安李氏")
	_expect("separator culture groups use place hyphen surname",
		EconomyFacadeScript.compose_family_display_name(
			"Rome", "Smith", "CITY_SEPARATOR_SURNAME", "-", "") == "Rome-Smith")
	_expect("unnamed origin still keeps the chinese surname suffix",
		EconomyFacadeScript.compose_family_display_name(
			"", "王", "CITY_SURNAME_SUFFIX", "-", "氏") == "王氏")
	var controller = PlayerControllerScript.new()
	_expect("PlayerController has no frame polling", not controller.has_method("_process"))
	_expect("unknown player command is rejected", _code(controller.request_command(&"gm.teleport")) == "unsupported_command")
	_expect("known player command is session gated",
		_code(controller.request_command(PlayerControllerScript.COMMAND_RESEARCH_SET_BUDGET)) == "runtime_unavailable")
	_expect("construction command is session gated",
		_code(controller.request_command(PlayerControllerScript.COMMAND_CONSTRUCTION_BUILD, {
			"cell_idx": 0,
			"building_id": &"coal_mine",
			"ownership_policy": &"treasury_sponsored_private",
		})) == "runtime_unavailable")
	_expect("treasury-sponsored construction is a formal player command",
		PlayerControllerScript.SUPPORTED_COMMANDS.has(&"construction.build") and
		controller.has_signal(&"command_settled"))
	_expect("family colonization start and cancel are formal player commands",
		PlayerControllerScript.SUPPORTED_COMMANDS.has(&"family.colonization.start")
		and PlayerControllerScript.SUPPORTED_COMMANDS.has(&"family.colonization.cancel")
		and _code(controller.request_command(&"family.colonization.start", {
			"family_handle": 1, "source_cell": 0, "target_cell": 1,
			"population": 1, "quote_token": 1,
		})) == "runtime_unavailable")
	_expect("national and cell tax commands are formal player commands",
		PlayerControllerScript.SUPPORTED_COMMANDS.has(&"country.tax.set_default") and
		PlayerControllerScript.SUPPORTED_COMMANDS.has(&"country.tax.set_override") and
		PlayerControllerScript.SUPPORTED_COMMANDS.has(&"country.tax.clear_override") and
		PlayerControllerScript.SUPPORTED_COMMANDS.has(&"country.tax.cell.set_default") and
		PlayerControllerScript.SUPPORTED_COMMANDS.has(&"country.tax.cell.clear_default") and
		PlayerControllerScript.SUPPORTED_COMMANDS.has(&"country.tax.cell.set_override") and
		PlayerControllerScript.SUPPORTED_COMMANDS.has(&"country.tax.cell.clear_override") and
		PlayerControllerScript.SUPPORTED_COMMANDS.has(&"country.tax.cell.clear_all"))
	controller.restore_view_state(null, {"next_command_sequence": 41})
	_expect("player view round-trips the next unified command sequence",
		int(controller.capture_view_state().get("next_command_sequence", 0)) == 41)
	var canal_rejected: Dictionary = controller.request_command(
		&"infrastructure.canal.build", {"quote_token": 7})
	_expect("canal command remains API-only and unsupported by PlayerController",
		_code(canal_rejected) == "unsupported_command"
		and int(canal_rejected.get("effective_day", -2)) == -1
		and int(canal_rejected.get("sequence", -2)) == -1
		and not PlayerControllerScript.SUPPORTED_COMMANDS.has(
			&"infrastructure.canal.build"))
	_expect("rejected canal command does not consume unified sequence",
		int(controller.capture_view_state().get("next_command_sequence", 0)) == 41)
	_expect("player pause action is registered", InputMap.has_action(&"player_pause"))
	_expect("player cancel action is registered", InputMap.has_action(&"player_cancel"))
	_expect("player fit action is registered", InputMap.has_action(&"player_fit_view"))
	_expect("player zoom actions are registered",
		InputMap.has_action(&"player_zoom_in") and InputMap.has_action(&"player_zoom_out"))
	var overlay_button_scene := load("res://scenes/ui/map_overlay_icon_button.tscn") as PackedScene
	var overlay_button := overlay_button_scene.instantiate() as Button \
		if overlay_button_scene != null else null
	_expect("overlay icon buttons do not steal GUI focus",
		overlay_button != null and overlay_button.focus_mode == Control.FOCUS_NONE)
	if overlay_button != null:
		overlay_button.free()
	var packed := load("res://scenes/player_game.tscn") as PackedScene
	var scene := packed.instantiate() if packed != null else null
	var player = scene if scene != null else null
	_expect("player scene mounts the unified controller",
		player != null and player.get_node_or_null("PlayerController") != null)
	_expect("legacy controller nodes are absent",
		player != null and player.get_node_or_null("Controllers") == null)
	_expect("player scene mounts one shared colonization planner and Node2D route layer",
		player != null
		and player.get_node_or_null("UI/UIRoot/ModalLayer/ColonizationPlannerPanel") != null
		and player.get_node_or_null("WorldRoot/ColonizationRouteLayer") is Node2D)
	_run_colonization_planner_busy_display()
	_run_colonization_kit_error_copy()
	_run_colonization_planner_family_cards()
	_run_colonization_planner_effect_fallback()
	_run_colonization_planner_paused_display()
	_run_family_effect_display_rows()
	_expect("player scene mounts one full-screen era reward modal",
		player != null
		and player.get_node_or_null("UI/UIRoot/ModalLayer/EraRewardDialog") is EraRewardDialog)
	if scene != null:
		scene.free()
	print("=== player controller contract: %d failures ===" % _failures)
	quit(0 if _failures == 0 else 1)


func _run_colonization_planner_busy_display() -> void:
	var stub := ColonizationQuoteStub.new()
	stub.quotes = {
		"ok": true, "busy": true, "committed": false, "nonbinding": true,
		"kind": "colonize", "total": 1,
		"family_handles": PackedInt64Array([11]),
		"source_cells": PackedInt32Array([0]),
		"maximum_populations": PackedInt64Array([9]),
		"route_costs": PackedInt32Array([4]),
		"travel_days": PackedInt32Array([4]),
		"quote_tokens": PackedInt64Array([77]),
		"surnames": PackedStringArray(["王"]),
		"surname_disambiguators": PackedInt32Array([0]),
	}
	stub.detail = {
		"ok": true, "busy": true, "route_cost": 4, "travel_days": 4,
		"profession_display_names": PackedStringArray(["采集"]),
		"profession_populations": PackedInt64Array([9]),
	}
	var panel := _make_planner_panel()
	panel.set_player_controller(stub)
	panel.open_target(1585)
	_expect("busy colonization quotes still list a source branch",
		panel._has_quote_rows() and panel._status.visible
		and panel._start.text.find("排队") >= 0)
	panel._select_quote({
		"family_handle": 11, "source_cell": 0, "target_cell": 1585,
		"maximum_population": 9, "route_cost": 4, "travel_days": 4,
		"quote_token": 77, "surname": "王",
	})
	_expect("confirm stays clickable after selecting a busy quote",
		not panel._start.disabled and panel._start.text.find("排队") >= 0
		and panel._start.text.find("9") >= 0)
	panel.set_command_result({"ok": true, "code": "colonization_queued",
		"message": "派遣已排队，将在经济结算完成后出发。"})
	_expect("queued start feedback stays on the quote list",
		panel._has_quote_rows()
		and panel._feedback.text.find("排队") >= 0)
	panel.queue_free()
	var wait_stub := ColonizationQuoteStub.new()
	wait_stub.quotes = {"ok": false, "code": "economy_busy_retry", "busy": true}
	var wait_panel := _make_planner_panel()
	wait_panel.set_player_controller(wait_stub)
	wait_panel.open_target(1)
	var waiting := false
	for child in wait_panel._list.get_children():
		if child is Label and (String(child.text).find("等待") >= 0 \
				or String(child.text).find("结算") >= 0):
			waiting = true
	_expect("busy quote failures keep a waiting explanation instead of a blank error",
		waiting and wait_panel._status.visible and wait_panel._start.disabled)
	wait_panel.queue_free()
	var empty_stub := ColonizationQuoteStub.new()
	empty_stub.quotes = {
		"ok": true, "busy": true, "committed": false, "nonbinding": true,
		"kind": "colonize", "total": 0,
		"family_handles": PackedInt64Array(),
		"source_cells": PackedInt32Array(),
		"maximum_populations": PackedInt64Array(),
		"route_costs": PackedInt32Array(),
		"travel_days": PackedInt32Array(),
		"quote_tokens": PackedInt64Array(),
		"surnames": PackedStringArray(),
		"surname_disambiguators": PackedInt32Array(),
	}
	var empty_panel := _make_planner_panel()
	empty_panel.set_player_controller(empty_stub)
	empty_panel.open_target(2)
	var empty_waiting := false
	var false_empty := false
	for child in empty_panel._list.get_children():
		if child is Label:
			var text := String(child.text)
			if text.find("结算") >= 0:
				empty_waiting = true
			if text.find("没有满足") >= 0:
				false_empty = true
	_expect("busy empty quotes stay a waiting state instead of a false no-branch error",
		empty_waiting and not false_empty and empty_panel._status.visible)
	empty_panel.queue_free()


func _run_colonization_kit_error_copy() -> void:
	_expect("kit requote uses a specific Chinese explanation",
		ColonizationPlannerPanel._reason_text(
			"colonization_kit_requote_required").find("开工包") >= 0
		and ColonizationPlannerPanel._reason_text(
			"colonization_kit_materials_short").find("库存") >= 0)
	_expect("player start maps kit errors instead of the generic fallback",
		PlayerController._colonization_command_message(
			"colonization_kit_requote_required").find("开工包") >= 0
		and PlayerController._colonization_command_message(
			"colonization_kit_materials_short").find("库存") >= 0
		and PlayerController._colonization_command_message(
			"colonization_kit_requote_required").find("当前无法执行开拓") < 0)


func _run_colonization_planner_family_cards() -> void:
	var stub := ColonizationQuoteStub.new()
	stub.quotes = {
		"ok": true, "busy": false, "kind": "colonize", "total": 2,
		"family_handles": PackedInt64Array([11, 11]),
		"source_cells": PackedInt32Array([3, 8]),
		"maximum_populations": PackedInt64Array([5, 12]),
		"route_costs": PackedInt32Array([9, 4]),
		"travel_days": PackedInt32Array([9, 4]),
		"quote_tokens": PackedInt64Array([71, 72]),
		"surnames": PackedStringArray(["王", "王"]),
		"surname_disambiguators": PackedInt32Array([0, 0]),
	}
	stub.detail = {
		"ok": true, "route_cost": 4, "travel_days": 4,
		"profession_display_names": PackedStringArray(["采集"]),
		"profession_populations": PackedInt64Array([12]),
		"kit_building_ids": PackedInt32Array([1, 2]),
		"kit_building_counts": PackedInt64Array([1, 1]),
		"kit_building_stable_ids": PackedStringArray(["gathering_ground",
			"early_merchant_post"]),
		"kit_partial": false,
		"kit_place_buildings": true,
	}
	var panel := _make_planner_panel()
	panel.set_player_controller(stub)
	panel.open_target(22)
	var rows := []
	for child in panel._list.get_children():
		if child.has_method("display_name"):
			rows.append(child)
	var visible := _visible_text(panel._list)
	_expect("same family collapses to one dispatch card", rows.size() == 1)
	_expect("colonization planner reserves a readable archive workspace",
		panel.custom_minimum_size.x >= 680.0
		and panel.custom_minimum_size.y >= 640.0)
	_expect("dispatch card shows origin family name, people, and traits",
		rows.size() == 1 and String(rows[0].display_name()) == "长安王氏"
		and visible.find("40 人") >= 0 and visible.find("采集传统") >= 0
		and visible.find("偏好：采集营地") >= 0)
	if rows.size() == 1:
		var row := rows[0] as Control
		var effect := row.get_node("Margin/Line/Info/Effect") as Label
		var badges := row.get_node("Margin/Line/Info/Badges") as BadgeRow
		var population := row.get_node("Margin/Line/Population") as Label
		_expect("dispatch card provides enough height for wrapped traits and effects",
			row.custom_minimum_size.y >= 120.0
			and badges.max_badge_width >= 184.0
			and effect.autowrap_mode != TextServer.AUTOWRAP_OFF
			and effect.max_lines_visible >= 2)
		_expect("dispatch population is explicit and high contrast",
			population.text.ends_with(" 人")
			and population.get_theme_font_size("font_size") >= 20
			and population.get_theme_color("font_color") == UITokens.ARCHIVE_INK)
	_expect("dispatch trait chips carry Chinese descriptions as tooltips",
		rows.size() == 1 and _badge_tooltips(rows[0]).find(
			"更倾向投资采集建筑，并随威望提高本城总体产出。") >= 0)
	_expect("dispatch card hides source, cost, and travel debug fields",
		visible.find("源地") < 0 and visible.find("成本") < 0
		and visible.find("最多") < 0)
	panel._select_quote({
		"family_handle": 11, "source_cell": 8, "target_cell": 22,
		"quote_token": 72, "surname": "王",
	})
	_expect("missing maximum_population still selects a sendable default",
		int(panel._population.value) >= 1 and panel._selected_quote.get("family_handle", 0) == 11)
	panel._select_quote({
		"family_handle": 11, "source_cell": 8, "target_cell": 22,
		"maximum_population": 12, "route_cost": 4, "travel_days": 4,
		"quote_token": 72, "surname": "王",
	})
	_expect("dispatch defaults to the sendable maximum",
		int(panel._population.value) == 12 and not panel._start.disabled
		and panel._start.text.find("12") >= 0
		and panel._start.text.find("安家") >= 0)
	stub.detail["kit_partial"] = true
	stub.detail["kit_place_buildings"] = false
	stub.detail["kit_building_ids"] = PackedInt32Array()
	panel._select_quote({
		"family_handle": 11, "source_cell": 8, "target_cell": 22,
		"maximum_population": 12, "route_cost": 4, "travel_days": 4,
		"quote_token": 72, "surname": "王",
	})
	_expect("owned-cell partial kits keep a basic-supplies dispatch label",
		panel._start.text.find("12") >= 0
		and panel._start.text.find("安家") < 0
		and panel._start.text.find("筹备") < 0
		and (panel._start.tooltip_text.find("基础物资") >= 0
			or panel._feedback.text.find("基础物资") >= 0)
		and panel._start.tooltip_text.find("建材不足") < 0
		and panel._feedback.text.find("建材不足") < 0
		and not panel._start.disabled)
	stub.detail["kit_place_buildings"] = true
	panel._select_quote({
		"family_handle": 11, "source_cell": 8, "target_cell": 22,
		"maximum_population": 12, "route_cost": 4, "travel_days": 4,
		"quote_token": 72, "surname": "王",
	})
	_expect("incomplete greenfield kits offer preparation instead of locking",
		not panel._start.disabled
		and panel._start.text.find("筹备") >= 0
		and panel._start.text.find("12") >= 0)
	panel.set_command_result({
		"ok": false, "code": "colonization_kit_materials_short",
	})
	_expect("material-short failure no longer disables the confirm button",
		not panel._start.disabled
		and panel._start.text.find("等待材料") < 0)
	stub.detail["kit_partial"] = false
	stub.detail["kit_place_buildings"] = true
	stub.detail["kit_building_ids"] = PackedInt32Array([1, 2])
	var refreshed_tokens := PackedInt64Array([73, 74])
	stub.quotes["quote_tokens"] = refreshed_tokens
	panel.refresh_visible()
	_expect("a changed quote identity rechecks and re-enables dispatch",
		not panel._start.disabled and panel._start.text.find("安家") >= 0)
	panel.queue_free()


func _run_colonization_planner_paused_display() -> void:
	var stub := ColonizationQuoteStub.new()
	stub.quotes = {
		"ok": false, "busy": false, "fatal": true, "committed": false,
		"code": "economy_paused",
	}
	stub.detail = {
		"ok": false, "busy": false, "fatal": true, "code": "economy_paused",
	}
	var panel := _make_planner_panel()
	panel.set_player_controller(stub)
	panel.open_target(3)
	var paused := false
	for child in panel._list.get_children():
		if child is Label and String(child.text).find("暂停") >= 0:
			paused = true
	_expect("fatal economy quote failures show a paused explanation instead of stale cards",
		paused and not panel._has_quote_rows() and panel._start.disabled)
	panel._select_quote({"family_handle": 11, "quote_token": 9})
	_expect("selecting a quote without maximum_population does not keep confirm enabled after pause",
		panel._start.disabled or int(panel._population.value) >= 1)
	panel.queue_free()


func _run_colonization_planner_effect_fallback() -> void:
	var stub := ColonizationQuoteStub.new()
	stub.traits = {
		"ok": true,
		"display_names": PackedStringArray(["商路人脉"]),
		"core": PackedByteArray([1]),
		"descriptions": PackedStringArray(["随威望提高本城贸易产出；高威望时累计贸易活动可为本城增加公共人口。"]),
		"behavior_selector_display_names": PackedStringArray(),
		"effect_display_names": PackedStringArray(["贸易产出加成", "商路人口奖励"]),
	}
	stub.quotes = {
		"ok": true, "busy": false, "kind": "colonize", "total": 1,
		"family_handles": PackedInt64Array([11]),
		"source_cells": PackedInt32Array([8]),
		"maximum_populations": PackedInt64Array([12]),
		"route_costs": PackedInt32Array([4]),
		"travel_days": PackedInt32Array([4]),
		"quote_tokens": PackedInt64Array([72]),
		"surnames": PackedStringArray(["王"]),
		"surname_disambiguators": PackedInt32Array([0]),
	}
	var panel := _make_planner_panel()
	panel.set_player_controller(stub)
	panel.open_target(22)
	var visible := _visible_text(panel._list)
	_expect("dispatch cards without preferences show Chinese effect names",
		visible.find("商路人脉") >= 0
		and visible.find("效果：贸易产出加成") >= 0
		and visible.find("family.city.trade_output_boost") < 0)
	panel.queue_free()


func _run_family_effect_display_rows() -> void:
	var view_model := CellInspectorViewModel.new()
	var family_effect_rows: Array = view_model._family_bound_effect_rows({
		"cell_idx": 12,
		"effect_definition_keys": PackedStringArray(["family.effect.rain_prayer"]),
		"effect_display_names": PackedStringArray(["求雨"]),
		"effect_current_descriptions": PackedStringArray([
			"威望Ⅰ：该家族分支所在的本地块会持续获得以下效果：降雨触发下限降低2%。"]),
		"effect_descriptions": PackedStringArray([
			"威望Ⅰ：该家族分支所在的本地块会持续获得以下效果：降雨触发下限降低2%。\n威望Ⅴ：该家族分支所在的本地块会持续获得以下效果：降雨触发下限降低10%。"]),
	})
	_expect("family bound-effect rows use Chinese names and descriptions",
		family_effect_rows.size() == 1
		and String(family_effect_rows[0].get("name", "")).find("求雨") >= 0
		and String(family_effect_rows[0].get("name", "")).find("rain_prayer") < 0
		and String(family_effect_rows[0].get("value", "")).find("降雨触发下限降低2%") >= 0
		and String(family_effect_rows[0].get("detail", "")).find("降雨触发下限降低2%") >= 0
		and String(family_effect_rows[0].get("detail", "")).find("威望Ⅴ") < 0)
	var modifier_rows: Array = view_model._family_modifier_rows({
		"cell_idx": 12,
		"modifier_definition_keys": PackedStringArray([
			"family.city.extractive_output_boost"]),
		"modifier_display_names": PackedStringArray(["采掘产出加成"]),
		"modifier_descriptions": PackedStringArray(["提高本城采掘部门产出。"]),
		"modifier_magnitude_q16": PackedInt32Array([65536]),
	})
	var trigger_rows: Array = view_model._family_trigger_rows({
		"cell_idx": 12,
		"trigger_definition_keys": PackedStringArray(["family.trade_population_bonus"]),
		"trigger_display_names": PackedStringArray(["商路人口奖励"]),
		"trigger_descriptions": PackedStringArray(["累计足够贸易活动后，为本城公共人口提供奖励。"]),
		"trigger_progress": PackedInt64Array([0]),
		"trigger_thresholds": PackedInt64Array([20]),
		"trigger_completed": PackedInt32Array([0]),
		"trigger_reward_targets": PackedInt32Array([1]),
	})
	_expect("family modifier rows use Chinese display names instead of raw keys",
		modifier_rows.size() == 1
		and String(modifier_rows[0].get("name", "")).find("采掘产出加成") >= 0
		and String(modifier_rows[0].get("name", "")).find("extractive_output_boost") < 0
		and String(modifier_rows[0].get("detail", "")).find("采掘部门产出") >= 0)
	_expect("family trigger rows use Chinese display names instead of raw keys",
		trigger_rows.size() == 1
		and String(trigger_rows[0].get("name", "")).find("商路人口奖励") >= 0
		and String(trigger_rows[0].get("name", "")).find("trade_population_bonus") < 0
		and String(trigger_rows[0].get("detail", "")).find("公共人口") >= 0)


func _make_planner_panel() -> ColonizationPlannerPanel:
	var packed := load("res://scenes/ui/colonization_planner_panel.tscn") as PackedScene
	var panel := packed.instantiate() as ColonizationPlannerPanel
	root.add_child(panel)
	return panel


func _visible_text(node: Node) -> String:
	var parts := PackedStringArray()
	if node is Label:
		parts.append(String((node as Label).text))
	elif node is Button:
		parts.append(String((node as Button).text))
	for child in node.get_children():
		parts.append(_visible_text(child))
	return " ".join(parts)


func _badge_tooltips(row: Node) -> PackedStringArray:
	var tooltips := PackedStringArray()
	var badges := row.get_node_or_null("Margin/Line/Info/Badges")
	if badges == null:
		return tooltips
	for child in badges.get_children():
		if child is Label:
			tooltips.append(String((child as Label).tooltip_text))
	return tooltips


func _code(result: Dictionary) -> String:
	return String(result.get("code", ""))


func _expect(label: String, condition: bool) -> void:
	if condition:
		print("  [PASS] %s" % label)
	else:
		_failures += 1
		push_error("  [FAIL] %s" % label)
