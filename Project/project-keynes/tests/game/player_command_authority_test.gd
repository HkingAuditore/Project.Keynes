extends SceneTree

const PlayerScript = preload("res://scripts/game/player_controller.gd")
const Routes = preload("res://scripts/ui/game_ui/country_routes.gd")
const TaxEditor = preload("res://scenes/ui/object_tax_lane.tscn")
const Inspector = preload("res://scenes/ui/inspector_panel.tscn")
const Dossier = preload("res://scenes/ui/military_dossier.tscn")

var _host: WorldRuntimeHost
var _clock: WorldClock
var _player: Node
var _ext: Object
var _country
var _economy
var _military
var _building_view: Dictionary
var _receipts := {}
var _failures := 0
var _checks := 0
var _capital := -1
var _ours := 0
var _foreign_cell := -1
var _theirs := 0


func _init() -> void:
	await process_frame
	await _run()
	if is_instance_valid(_host):
		await _host.close_world()
	if is_instance_valid(_player):
		_player.free()
	if is_instance_valid(_host):
		_host.free()
	await process_frame
	if is_instance_valid(_clock):
		_clock.free()
	print("player command authority: %d checks, %d failures" % [_checks, _failures])
	quit(0 if _failures == 0 else 1)


func _run() -> void:
	_clock = WorldClock.new()
	_clock.auto_start = false
	root.add_child(_clock)
	_clock.set_process(false)
	_host = WorldRuntimeHost.new()
	root.add_child(_host)
	_host.configure(null, null, _clock)
	var config := NewGameConfig.create_default()
	config.base.initial_seed = 20260727
	config.base.map_width = 60
	config.base.map_height = 40
	config.country.foreign_count = 3
	config.research.starting_country_cash = 900000000
	_expect("configure formal four-country session",
		bool(_host.configure_session({"kind": "new_game", "config": config.to_dictionary()}).ok))
	await _host.generate_world()
	_expect("formal executor ready", _host.is_runtime_ready_for_ticks())
	if not _host.is_runtime_ready_for_ticks():
		return
	var generator := _host.get_generator()
	_ext = generator.get_data_core_world_ext()
	_country = generator.get_country_facade()
	_economy = generator.get_economy_facade()
	_military = generator.get_military_facade()
	_capital = int(generator.gameplay_start_report().get("cell", -1))
	_ours = int(_country.cell_summary(_capital).get("country_handle", 0))
	var map := _host.current_map()
	for cell in range(map.cell_count()):
		var owner := int(_country.cell_summary(cell).get("country_handle", 0))
		if owner != 0 and owner != _ours:
			_foreign_cell = cell
			_theirs = owner
			break
	_expect("fixture finds foreign and domestic territory",
		_ours > 0 and _capital >= 0 and _theirs > 0 and _foreign_cell >= 0)
	if _theirs == 0:
		return
	_player = PlayerScript.new()
	root.add_child(_player)
	_player.configure(null, null, _host, _clock, null)
	_player.refresh_country_binding()
	_player.command_settled.connect(func(id: StringName, result: Dictionary) -> void:
		_receipts[int(result.get("sequence", -1))] = {"id": id, "result": result.duplicate(true)})
	_ext.set_runtime_clock(false, 50.0)
	_economy.market_cell_snapshot(_capital)
	var overview: Dictionary = _economy.country_economy_overview(_ours, "summary")
	_expect("the idle economy panel only reads a published view",
		String(overview.get("read_view_source", "")) in ["pending", "committed_view"])
	var water := map.is_water_arr.find(1)
	var claims: Array[Dictionary] = []
	var capture_claim := func(_id: String, result: Dictionary) -> void: claims.append(result)
	_host.gm_action_completed.connect(capture_claim)
	_host._player_country_handle = _ours
	if water >= 0:
		_host._gm_claim_selected_cell(map.cell_at(water))
	_expect("GM forwards clicks over water through Country admission",
		claims.size() == 1 and claims[0].get("queued", false))
	var invalid_receipts: Array[Dictionary] = []
	var capture_invalid := func(result: Dictionary) -> void:
		if int(result.get("sequence", -1)) == 479:
			invalid_receipts.append(result)
	_economy.construction_command_settled.connect(capture_invalid)
	var invalid_country: Dictionary = _ext.queue_treasury_sponsored_build(987654, _capital, 1, 1, 479)
	_expect("the construction inbox does not check the country's current handle",
		invalid_country.get("admitted", false) and invalid_country.get("effective_day") == 1)

	var barracks := int(_military.state_building_ids().find("warrior_lodge"))
	var row: Dictionary = _military.catalog().state_buildings[barracks]
	var build_type := int(_military.state_building_economy_id(barracks))
	var building := StringName(_economy.building_type_ids()[build_type])
	var unlock := StringName(row.unlock_tech_id)
	var locked_unit: String = ""
	var tech_ids: PackedStringArray = _country.native_catalog().technology_ids
	for unit: Dictionary in _military.catalog().units:
		if not String(unit.get("tech", "")).is_empty() and not _country.has_completed_technology(
				_ours, tech_ids.find(String(unit.tech))):
			locked_unit = String(unit.id)
			break
	_expect("fixture has locked training technology", not locked_unit.is_empty())

	_expect("move opening treasury away for the unfunded case",
		_transfer_cash(_ours, _theirs, 1, 490))
	var foreign_tax: Array[Dictionary] = []
	var item := StringName(_country.native_catalog().profession_ids[0])
	for op: StringName in [&"set_default", &"clear_default", &"set_override",
			&"clear_override", &"clear_all"]:
		foreign_tax.append(_issue(StringName("country.tax.cell." + op),
			{"cell": _foreign_cell, "kind": 0, "rate_basis_points": 711, "item_id": item}))
	var own_tax := _issue(&"country.tax.cell.set_default",
		{"cell": _capital, "kind": 0, "rate_basis_points": 711})
	var foreign_build := _issue(&"construction.build", {"cell_idx": _foreign_cell,
		"building_id": building, "ownership_policy": &"treasury_sponsored_private"})
	var foreign_army := _issue(&"military.army.create",
		{"cell": _foreign_cell, "units": {0: 1}})
	var locked_build := _issue(&"military.state.build", {"cell": _capital, "building": barracks})
	var locked_train := _issue(&"military.train", {"cell": _capital, "to": locked_unit, "count": 1})
	var foreign_demolish := _issue(&"military.state.demolish",
		{"cell": _foreign_cell, "building": barracks})
	# An invalid published handle may still be forwarded as a draft.
	var armed: Dictionary = _player.begin_military_arm_order(4294968296, "explore")
	_expect("an unknown army can begin a nonbinding draft", armed.get("ok", false))
	_player.military_arm_order_click(_capital)
	var vanished: Dictionary = _player.confirm_military_arm_order()
	_expect("a stale draft is forwarded as a dated request",
		vanished.get("admitted") == true and vanished.get("effective_day") == own_tax.get("effective_day"))
	await _advance(int(own_tax.get("effective_day", 1)))
	for ticket in foreign_tax:
		_rejected(ticket, "country_cell_tax_territory_invalid")
	_expect("valid same-day tax still committed",
		int(_country.cell_tax_policy_snapshot(_capital).local_default_rates_basis_points[0]) == 711)
	_rejected(foreign_build, "construction_cell_not_owned")
	_rejected(foreign_army, "not_own_territory")
	_rejected(locked_build, "construction_technology_locked")
	_rejected(locked_train, "technology_locked")
	_rejected(foreign_demolish, "construction_cell_not_owned")
	_expect("the GM console gets the authoritative water rejection",
		claims.size() == 2 and not claims[1].get("ok", true)
		and claims[1].get("code") == "country_transfer_cell_invalid")
	_host.gm_action_completed.disconnect(capture_claim)
	_economy.construction_command_settled.disconnect(capture_invalid)
	_expect("the display batch delivers the rejection once on the settlement day",
		invalid_receipts.size() == 1 and invalid_receipts[0].get("code") == "construction_target_invalid"
		and invalid_receipts[0].get("admitted") == false
		and invalid_receipts[0].get("settled_day") == own_tax.effective_day)
	print("FOREGROUND_AUTHORITY gm=", claims, " construction=", invalid_receipts,
		" read_source=", overview.get("read_view_source"))
	_rejected(vanished, "command_unknown_army")
	_check_tax_feedback(foreign_tax[0])
	_check_construction_feedback(foreign_build, _foreign_cell,
		"目标地块已不属于玩家国家。")
	_check_military_feedback(foreign_army, "只能编成本国可控领土上的驻军。")
	_check_military_feedback(locked_train, "尚未解锁这项科技。")
	_check_military_feedback(locked_build, "建造所需科技尚未解锁。")
	_check_military_feedback(foreign_demolish, "目标地块已不属于玩家国家。")
	_check_military_dossier_feedback(vanished, "部队已不存在。")

	var grant: Dictionary = _country.grant_technology(_ours, unlock, _day() + 1, 500, true)
	_expect("grant barracks technology", bool(grant.get("ok", false)))
	_expect("supply local building materials", _seed_stock(row.material_goods))
	await _advance(int(grant.get("effective_day", _day() + 1)))
	var cash_before: Dictionary = _country.treasury_snapshot(_ours)
	var before := _construction_count(build_type)
	var slots := _schedules()
	var cashless := _issue(&"military.state.build", {"cell": _capital, "building": barracks})
	await _advance(int(cashless.get("effective_day", _day() + 1)))
	var failure := _rejected(cashless, "construction_treasury_cash_insufficient")
	_expect("cash rejection leaves all construction legs untouched",
		failure.get("step") == "economy" and failure.get("cash_paid") == 0
		and failure.get("treasury_goods_used") == 0 and failure.get("market_goods_used") == 0
		and _construction_count(build_type) == before and _schedules() == slots
		and _country.treasury_snapshot(_ours).get("quantities") == cash_before.get("quantities"))
	_check_military_feedback(cashless, "国库资金不足以购买缺少的建材。")
	_expect("return funds to the treasury for the schedule case",
		_transfer_cash(_theirs, _ours, _day() + 1, 520))
	await _advance(_day() + 1)
	var requests: Array[Dictionary] = []
	requests.append(_issue(&"military.state.build", {"cell": _capital, "building": barracks}))
	var first_day := int(requests[0].get("effective_day", -1))
	await _advance(first_day)
	var first_reply: Dictionary = _receipts.get(int(requests[0].sequence), {}).get("result", {})
	_expect("first schedule order settles", first_reply.get("ok") == true
		and int(first_reply.get("cash_paid", 0)) > 0)
	var first_done_days: PackedInt32Array = _military.cell_snapshot(_capital, _ours).construction_done_days
	var first_ready_day := first_done_days[0]
	var fill_day := mini(first_ready_day - 10, _day() + 1)
	await _advance(fill_day)
	for _i in range(slots.size() - 1):
		requests.append(_issue(&"military.state.build", {"cell": _capital, "building": barracks}))
	var fill_settle_day := int(requests.back().get("effective_day", -1))
	await _advance(fill_settle_day)
	var cash_paid := int(first_reply.get("cash_paid", 0))
	for index in range(1, requests.size()):
		var reply: Dictionary = _receipts.get(int(requests[index].sequence), {}).get("result", {})
		_expect("successful build %d pays and settles on the admitted day" % index,
			reply.get("ok") == true and reply.get("settled_day") == fill_settle_day
			and int(reply.get("cash_paid", 0)) > 0)
		cash_paid += int(reply.get("cash_paid", 0))
	var full_ticket := _issue(&"military.state.build", {"cell": _capital, "building": barracks})
	await _advance(int(full_ticket.get("effective_day", -1)))
	var full := _rejected(full_ticket, "military_construction_schedule_full")
	_expect("schedule rejection has no economy effects and preserves the earlier slots",
		full.get("step") == "military" and full.get("cash_paid") == 0
		and full.get("treasury_goods_used") == 0 and full.get("market_goods_used") == 0
		and cash_paid > 0 and _construction_count(build_type) == before + slots.size()
		and _schedules().count(barracks) == slots.size())
	_check_military_feedback(full_ticket, "当地官营建筑的营造排期已满。")
	var missing_demolish := _issue(&"military.state.demolish", {"cell": _capital, "building": barracks})
	await _advance(int(missing_demolish.effective_day))
	_rejected(missing_demolish, "demolish_state_building_absent")
	_expect("rejected demolition does not cancel active construction",
		_construction_count(build_type) == before + slots.size() and _schedules().count(barracks) == slots.size())
	var ready_days: PackedInt32Array = _military.cell_snapshot(_capital, _ours).construction_done_days
	var ready_day := ready_days[0]
	await _advance(ready_day)
	var built := _construction_count(build_type)
	var demolish := _issue(&"military.state.demolish", {"cell": _capital, "building": barracks})
	await _advance(int(demolish.effective_day))
	var removed: Dictionary = _receipts.get(int(demolish.sequence), {}).get("result", {})
	_expect("demolition removes exactly one completed lot",
		removed.get("ok", false) and removed.get("settled_day") == demolish.effective_day
		and built == before + slots.size() and _construction_count(build_type) == built - 1
		and _schedules().count(barracks) == 0)
	var overlap_first := _issue(&"military.state.build", {"cell": _capital, "building": barracks})
	var overlap_second := _issue(&"military.state.build", {"cell": _capital, "building": barracks})
	_expect("the first two overlap projects start together",
		overlap_first.get("effective_day") == overlap_second.get("effective_day"))
	await _advance(int(overlap_first.get("effective_day", -1)))
	await _advance(_day() + 1)
	var overlap_sibling := _issue(&"military.state.build", {"cell": _capital, "building": barracks})
	await _advance(int(overlap_sibling.get("effective_day", -1)))
	var first_days: PackedInt32Array = _military.cell_snapshot(_capital, _ours).construction_done_days
	var overlap_ready_day := first_days[0]
	var compatibility_building := int(_military.state_building_ids().find("palisade_barracks"))
	_expect("fixture has a distinct building for the compatibility command",
		compatibility_building >= 0 and compatibility_building != barracks)
	await _advance(overlap_ready_day - 1)
	var before_overlap: Dictionary = _military.cell_snapshot(_capital, _ours)
	var overlap_days: PackedInt32Array = before_overlap.construction_done_days
	_expect("every slot is occupied and exactly two builds complete the next day",
		before_overlap.construction_buildings.count(barracks) == slots.size()
		and overlap_days.count(overlap_ready_day) == 2 and overlap_days[-1] > overlap_ready_day + 1)
	var count_before_overlap := _construction_count(build_type)
	var compatibility_command := {"op": "state.build", "country": _ours,
		"cell": _capital, "unit_to": compatibility_building,
		"effective_day": overlap_ready_day}
	var compatibility: Dictionary = _military.submit([compatibility_command])
	_expect("compatibility build is queued for the completing day",
		bool(compatibility.get("ok", false)) and int(compatibility.get("accepted", 0)) == 1)
	var overlap := _issue(&"military.state.build", {"cell": _capital, "building": barracks})
	_expect("overlap build is due with the compatibility command and completion",
		int(overlap.get("effective_day", -1)) == overlap_ready_day)
	await _advance(overlap_ready_day)
	var overlap_reply: Dictionary = _receipts.get(int(overlap.sequence), {}).get("result", {})
	_expect("same-day completion frees capacity for the legal treasury build",
		overlap_reply.get("ok") == true and overlap_reply.get("settled_day") == overlap_ready_day
		and int(overlap_reply.get("cash_paid", 0)) > 0)
	var after_overlap: Dictionary = _military.cell_snapshot(_capital, _ours)
	var overlap_schedules: PackedInt32Array = after_overlap.construction_buildings
	_expect("the paid and compatibility builds both keep their military slots (%s)" % [overlap_schedules],
		overlap_schedules.count(barracks) == slots.size() - 1
		and overlap_schedules.count(compatibility_building) == 1
		and _construction_count(build_type) == count_before_overlap + 1)
	compatibility_command.effective_day = overlap_ready_day + 1
	var full_compatibility: Dictionary = _military.submit([compatibility_command])
	_expect("the compatibility command is queued while the schedule is full",
		bool(full_compatibility.get("ok", false)) and int(full_compatibility.get("accepted", 0)) == 1)
	await _advance(overlap_ready_day + 1)
	var full_overlap: Dictionary = _military.cell_snapshot(_capital, _ours)
	_expect("a compatibility command with no free slot preserves all current orders",
		full_overlap.construction_buildings == overlap_schedules
		and full_overlap.construction_done_days == after_overlap.construction_done_days)
	await _check_edit_and_identity()


func _check_edit_and_identity() -> void:
	var units: Array = _military.catalog().units
	var before: PackedInt32Array = _military.country_snapshot(_ours).config_share_bp
	var left := _issue(&"military.config.set", {"unit": units[0].id, "bp": 1400})
	var right := _issue(&"military.config.set", {"unit": units[1].id, "bp": 1600})
	await _advance(int(right.effective_day))
	var after: PackedInt32Array = _military.country_snapshot(_ours).config_share_bp
	_expect("same-day partial military edits retain both changes",
		left.effective_day == right.effective_day and after[0] == 1400 and after[1] == 1600
		and after.slice(2) == before.slice(2))
	var transfer: Dictionary = _country.transfer_territory(_capital, _theirs, _day() + 1, 540)
	_expect("fixture transfers the founding cell", bool(transfer.get("ok", false)))
	await _advance(int(transfer.effective_day))
	_expect("the founding cell changed owner", int(_country.cell_summary(_capital).country_handle) == _theirs)
	var tax := _issue(&"country.tax.cell.set_default", {"cell": _capital, "kind": 0, "rate_basis_points": 777})
	await _advance(int(tax.effective_day))
	_rejected(tax, "country_cell_tax_territory_invalid")
	_expect("commands retain the bound player country after the founding cell is ceded",
		_player.get_player_country_handle() == _ours)


func _day() -> int:
	return int(_ext.get_runtime_control_state().get("simulation_committed_day", -1))


func _advance(day: int) -> void:
	for _frame in range(600):
		_host._admit_runtime_calendar(day + 1)
		_host._process(0.0)
		if _host._runtime_commit_day == day:
			var view: Dictionary = _economy.building_cell_snapshot(_capital)
			if bool(view.get("ok", false)) and view.has("building_counts_by_type") \
					and int(view.get("read_view_day", day)) == day:
				_building_view = view
				return
		if _host.is_runtime_fault_paused():
			break
		await process_frame
	_expect("executor commits day %d: %s" % [day, str(_ext.get_runtime_control_state())], false)


func _issue(id: StringName, args: Dictionary) -> Dictionary:
	var receipt: Dictionary = _player.request_command(id, args)
	_expect("backend admits %s: %s" % [id, str(receipt)],
		bool(receipt.get("admitted", false)) and int(receipt.get("effective_day", -1)) > _day())
	return receipt


func _rejected(ticket: Dictionary, code: String) -> Dictionary:
	var row: Dictionary = _receipts.get(int(ticket.get("sequence", 0)), {})
	var result: Dictionary = row.get("result", {})
	_expect("terminal %s: %s" % [code, str(result)], not bool(result.get("ok", true))
		and not bool(result.get("admitted", true)) and not result.has("effective_day")
		and result.get("code") == code and not String(result.get("message", "")).is_empty())
	return result


func _check_tax_feedback(ticket: Dictionary) -> void:
	var panel := Inspector.instantiate() as InspectorPanel
	var editor := TaxEditor.instantiate() as TaxLaneEditor
	root.add_child(editor)
	panel._cell_index = _foreign_cell
	var key := "foreign-tax"
	panel._pending_tax[key] = {"sequence": int(ticket.sequence)}
	panel._tax_editors[key] = [editor]
	var result: Dictionary = _receipts.get(int(ticket.sequence), {}).get("result", {})
	var routes := Routes.new()
	routes._on_player_command_settled({"_right_panel": panel}, &"country.tax.cell.set_default", result)
	_expect("inspector displays the backend tax rejection and releases the editor",
		editor._note.text == "只能修改本国领土的地块税率。" and panel._pending_tax.is_empty())
	panel.free()
	editor.free()


func _check_construction_feedback(ticket: Dictionary, cell: int, message: String) -> void:
	var ui := GameUIManager.new()
	var panel := Inspector.instantiate() as InspectorPanel
	ui._right_panel = panel
	ui._selected_cell = _host.current_map().cell_at(cell)
	var row: Dictionary = _receipts.get(int(ticket.sequence), {})
	var routes := Routes.new()
	routes._on_player_command_settled(ui, row.id, row.result)
	_expect("construction inspector displays the backend reason", panel._construction_feedback == message
		and not panel._construction_ok)
	ui.free()
	panel.free()


func _check_military_feedback(ticket: Dictionary, message: String) -> void:
	var ui := GameUIManager.new()
	var panel := Inspector.instantiate() as InspectorPanel
	ui._right_panel = panel
	var ledger := InspectorPanel.MilitaryCellLedgerScene.instantiate()
	root.add_child(ledger)
	ledger.set_model({"buildings": [{"name": "兵营"}]})
	ledger._action_index = 0
	panel._military_ledger = ledger
	var row: Dictionary = _receipts.get(int(ticket.sequence), {})
	var routes := Routes.new()
	routes._on_player_command_settled(ui, row.id, row.result)
	var visible_message: String = ledger._army_feedback.text if row.id == &"military.army.create" \
		or row.id == &"military.train" else String(ledger.feedback_text())
	_expect("military ledger displays %s: %s" % [row.id, visible_message], visible_message == message)
	ledger.free()
	ui.free()
	panel.free()


func _check_military_dossier_feedback(ticket: Dictionary, message: String) -> void:
	var ui := GameUIManager.new()
	var panel := Inspector.instantiate() as InspectorPanel
	ui._right_panel = panel
	var dossier := Dossier.instantiate() as MilitaryDossier
	root.add_child(dossier)
	panel._military_dossier = dossier
	var row: Dictionary = _receipts.get(int(ticket.sequence), {})
	Routes.new()._on_player_command_settled(ui, row.id, row.result)
	var hint := dossier.get_node("%CommandHint") as Label
	_expect("the military dossier displays the backend map order rejection",
		hint.visible and hint.text == message)
	dossier.free()
	ui.free()
	panel.free()


func _construction_count(type_id: int) -> int:
	var count := int(_building_view.building_counts_by_type[type_id])
	for i in range(_building_view.construction_type_ids.size()):
		if int(_building_view.construction_type_ids[i]) == type_id:
			count += int(_building_view.construction_counts[i])
	return count


func _schedules() -> PackedInt32Array:
	return _military.cell_snapshot(_capital, _ours).construction_buildings


func _transfer_cash(from: int, to: int, day: int, sequence: int) -> bool:
	var batch: Array[Dictionary] = [{
		"opcode": _country.Opcode.TRANSFER_CASH_BETWEEN_COUNTRIES,
		"target_handle": from, "cell": to & 0xffffffff,
		"technology": to >> 32, "value": 900000000,
		"effective_day": day, "sequence": sequence,
	}]
	return bool(_country.submit(batch, true).get("ok", false))


func _seed_stock(goods: PackedInt32Array) -> bool:
	var market := int(_economy.market_cell_snapshot(_capital).get("market_id", -1))
	if market < 0 or goods.is_empty():
		return false
	for index in range(goods.size()):
		var result: Dictionary = _ext.submit_economy_pod_commands({
			"request_ids": PackedInt64Array([50000 + index]),
			"opcodes": PackedInt32Array([4]),
			"transaction_ids": PackedInt64Array([0]),
			"session_epochs": PackedInt64Array([0]),
			"economy_generations": PackedInt64Array([0]),
			"payload0s": PackedInt64Array([800000]),
			"payload1s": PackedInt64Array([0]),
			"payload2s": PackedInt64Array([0]),
			"target_cells": PackedInt32Array([market]),
			"target_countries": PackedInt64Array([goods[index]]),
			"target_cohorts": PackedInt64Array([0]),
			"target_buildings": PackedInt64Array([0]),
		})
		if not bool(result.get("ok", false)):
			return false
	return true


func _expect(label: String, passed: bool) -> void:
	_checks += 1
	if not passed:
		_failures += 1
	print("%s %s" % ["PASS" if passed else "FAIL", label])
