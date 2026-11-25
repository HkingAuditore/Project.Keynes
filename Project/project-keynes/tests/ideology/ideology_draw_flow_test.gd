extends "res://tests/support/runtime_narrative_scenario.gd"

const IDEOLOGY_STOP := "ideology_choice_required"
const FAMILY_STOP := "family_founding_choice_required"
const STOPPED_CONFIRMATION := "executor_stopped_before_player_confirmation_service"


class ReceiptSurface:
	var error := ""

	func show_era_reward_error(message: String) -> void:
		error = message

	func show_family_founding_error(message: String) -> void:
		error = message


var _settled: Array[Dictionary] = []
var _ideology: IdeologyFacade
var _offers_shown: Array[int] = []


func _run() -> void:
	if not await _start_story({"ai_enabled": false}, [&"evt.chain.ancient_foundry_legacy"]):
		_finish()
		return
	_expect("native ideology and shutdown receipt checks pass", story_ext.runtime_ideology_pod_self_test())
	story_controller.refresh_country_binding()
	story_controller.command_settled.connect(_record_receipt)
	story_controller.ideology_offer_ready.connect(func(snapshot: Dictionary) -> void:
		_offers_shown.append(int(snapshot.offer_generation)))
	var workspace := (load("res://scenes/ui/ideology_workspace.tscn") as PackedScene).instantiate() as IdeologyWorkspace
	root.add_child(workspace)
	workspace.set_player_controller(story_controller)
	_ideology = story_host.get_generator().get_ideology_facade()
	story_clock.set_speed(10.0)
	story_clock.pause(true)
	story_ext.set_runtime_clock(true, 10.0)

	await _test_ideology(workspace)
	workspace.free()
	await _close_story()

	var profile = load("res://data/economy/default_economy.tres")
	profile.family_min_founder_people = 1
	profile.family_household_people_per_owner_slot = 1
	profile.family_milestone_populations = PackedInt64Array([60])
	if await _start_story({"ai_enabled": false}, [&"evt.chain.ancient_foundry_legacy"]):
		_settled.clear()
		story_controller.refresh_country_binding()
		story_controller.command_settled.connect(_record_receipt)
		_ideology = story_host.get_generator().get_ideology_facade()
		story_clock.set_speed(10.0)
		story_clock.pause(false)
		story_ext.set_runtime_clock(false, 10.0)
		await _test_family()
		await _close_story()
	_finish()


func _test_ideology(workspace: IdeologyWorkspace) -> bool:
	var unavailable := story_controller.request_command(&"ideology.offer")
	_expect("a day-one draw goes to the executor", bool(unavailable.get("ok", false)))
	if not await _wait_for(1, ""):
		return false
	_expect("day one returns the missing opinion reason on its date",
		await _has_receipt(unavailable, "ideology_opinion_snapshot_missing"))

	var empty := story_controller.request_command(&"ideology.offer")
	_expect("points are checked by the executor", bool(empty.get("ok", false)))
	if not await _wait_for(2, ""):
		return false
	_expect("the dated draw receipt is available before the map shows day 2",
		int(_find_receipt(empty).get("settled_day", -1)) == 2 and story_host.presented_worker_day() < 2)
	_expect("insufficient points are rejected on the command date",
		await _has_receipt(empty, "ideology_points_insufficient"))
	_expect("the ideology panel shows the draw rejection",
		workspace._hint.text == CountryViewModel.ideology_player_reason("ideology_points_insufficient"))

	var free := _ideology.submit([{"opcode": IdeologyFacade.Opcode.GRANT_FREE_DRAW,
		"country_handle": story_player, "value_q16": 1, "effective_day": 3,
		"producer_id": 77, "source_priority": -1, "sequence": 1}])
	_expect("fixture grants a draw without adding reroll points", bool(free.get("ok", false)))
	var draw := story_controller.request_command(&"ideology.offer")
	_expect("paused draw is admitted for day 3", int(draw.get("effective_day", -1)) == 3)
	if not await _wait_for(3, IDEOLOGY_STOP):
		return false
	var generation := int(_ideology.snapshot(story_player).get("offer_generation", 0))
	_expect("candidate is presented from the stopped commit",
		_offers_shown == [generation] and generation > 0)
	_expect("paused draw keeps manual pause and speed", story_clock.paused and story_clock.speed_multiplier == 10.0)

	var reroll := story_controller.request_command(&"ideology.reroll", {"offer_generation": generation})
	_expect("reroll with no points is forwarded", bool(reroll.get("ok", false)))
	if not await _wait_for(4, IDEOLOGY_STOP):
		return false
	_expect("reroll rejection preserves the candidate and publishes the reason",
		await _has_receipt(reroll, "ideology_points_insufficient") and
		int(_ideology.snapshot(story_player).get("offer_generation", 0)) == generation)
	_expect("the ideology panel shows the reroll rejection",
		workspace._hint.text == CountryViewModel.ideology_player_reason("ideology_points_insufficient"))

	var grant := _ideology.submit([{"opcode": IdeologyFacade.Opcode.GRANT_IDEOLOGY_POINTS,
		"country_handle": story_player, "value_q16": 2000 * 65536, "effective_day": 5,
		"producer_id": 77, "source_priority": -1, "sequence": 2}])
	_expect("fixture supplies reroll points on day 5", bool(grant.get("ok", false)))
	var new_offer := story_controller.request_command(&"ideology.reroll", {"offer_generation": generation})
	_expect("reroll has an effective date", int(new_offer.get("effective_day", -1)) == 5)
	if not await _wait_for(5, IDEOLOGY_STOP):
		return false
	generation += 1
	_expect("reroll stops again on its new candidate",
		_offers_shown == [generation - 1, generation])

	var dismiss := story_controller.dismiss_ideology_offer(generation)
	_expect("close sends a native confirmation", bool(dismiss.get("ok", false)))
	if not await _wait_for(6, ""):
		return false
	_expect("close preserves the offer and manual pause",
		bool(_ideology.snapshot(story_player).get("offer_active", false)) and story_clock.paused)
	var pick := story_controller.request_command(&"ideology.choose", {
		"offer_generation": generation, "choice_index": 0})
	_expect("later choice is admitted with a date", int(pick.get("effective_day", -1)) == 7)
	story_clock.pause(false)
	story_ext.set_runtime_clock(false, 10.0)
	_publish_day(story_host, story_clock, 7)
	if not await _wait_for(7, ""):
		return false
	_expect("later choice consumes the same generation",
		not bool(_ideology.snapshot(story_player).get("offer_active", true)))

	var running_draw := story_controller.request_command(&"ideology.offer")
	_expect("10x draw is admitted for day 8", int(running_draw.get("effective_day", -1)) == 8)
	_expect("multiple admitted days stop at the draw commit", await _hold_at(8, IDEOLOGY_STOP, 10))
	generation = int(_ideology.snapshot(story_player).get("offer_generation", 0))
	_expect("10x draw never pauses the foreground clock", not story_clock.paused and story_clock.speed_multiplier == 10.0)
	story_controller.dismiss_ideology_offer(generation)
	if not await _wait_for(10, ""):
		return false
	_expect("running clock continues and the 10x candidate stays available",
		bool(_ideology.snapshot(story_player).get("offer_active", false)))
	var saved_confirmation := await _save_runtime_bundle(2401)
	_expect("dismissed candidate state is saved",
		bool(saved_confirmation.get("ready", false)) and int(saved_confirmation.get("committed_day", -1)) == 10
		and not PackedByteArray(
			saved_confirmation.get("bytes", PackedByteArray())).is_empty())
	var settled_before_stop := _settled.size()
	var stopping_dismiss := story_controller.dismiss_ideology_offer(generation)
	_expect("stop-race close is accepted before stopping",
		bool(stopping_dismiss.get("ok", false)) and bool(stopping_dismiss.get("pending", false)))
	story_ext.request_runtime_stop()
	var stop_deadline := Time.get_ticks_msec() + 3000
	while not story_ext.get_runtime_control_state().get("simulation_executor_exited", false) and \
			Time.get_ticks_msec() < stop_deadline:
		story_host._process(0.0)
		await process_frame
	story_host._process(0.0)
	var terminal := _dismissal_terminal_since(settled_before_stop)
	_expect("accepted close has a terminal result when the executor stops",
		terminal.size() > 0 and (bool(terminal.get("ok", false)) or
			String(terminal.get("reason", "")) == STOPPED_CONFIRMATION))
	var expected_code := "ok" if bool(terminal.get("ok", false)) else STOPPED_CONFIRMATION
	_expect("terminal close carries code %s: %s" % [expected_code, terminal],
		String(terminal.get("code", "")) == expected_code)
	_expect("worker exits before confirmation restore",
		bool(story_ext.get_runtime_control_state().get("simulation_executor_exited", false)))
	var restored_confirmation := story_ext.restore_runtime_bundle(
		PackedByteArray(saved_confirmation.get("bytes", PackedByteArray())))
	_expect("dismissed confirmation bundle restores", bool(restored_confirmation.get("ok", false)))
	var restored_country := story_ext.restore_country_runtime_checkpoint(
		PackedByteArray(saved_confirmation.get("country_pkcn", PackedByteArray())))
	_expect("dismissed confirmation country checkpoint restores",
		bool(restored_country.get("ok", false)))
	# Restoring the bundle clears the native world environment. Seed it as a normal load does.
	story_host._native_environment_active = false
	story_host._start_runtime_executor()
	_expect("restored worker starts with its world environment",
		story_host._web_worker_start_ok and story_host._native_environment_active)
	story_host._consume_runtime_commit_if_ready()
	_expect("restored candidate remains dismissed and available",
		bool(_ideology.snapshot(story_player).get("offer_active", false)) and
		int(story_ext.get_runtime_control_state().get("ideology_offer_generation", 0)) == generation and
		story_controller.player_confirmation_reason().is_empty())
	var next_day := int(saved_confirmation.get("committed_day", -1)) + 1
	story_clock._process(1.0 / story_clock.speed_multiplier)
	if not await _wait_for(next_day, ""):
		return false
	_expect("restored calendar displays the next day", story_clock.day_index() == next_day + 1)

	# Regression: submitting a draw/reroll while running and pausing immediately
	# before the target day commits must still admit that day and settle.
	var pause_race := story_controller.request_command(&"ideology.reroll", {
		"offer_generation": generation})
	_expect("running-then-paused reroll is admitted",
		bool(pause_race.get("ok", false)) and int(pause_race.get("effective_day", -1)) == next_day + 1)
	story_clock.pause(true)
	story_ext.set_runtime_clock(true, 10.0)
	if not await _wait_for(next_day + 1, IDEOLOGY_STOP):
		return false
	_expect("running-then-paused reroll settles and clears draw waiting",
		await _has_receipt(pause_race, "") and not workspace._draw_waiting())
	return true


func _test_family() -> void:
	var population := await _published_economy(story_ext.get_population_cell_snapshot.bind(story_cell, false))
	var cohorts := PackedInt64Array(population.get("handles", []))
	_expect("the starter has a population cohort", not cohorts.is_empty())
	if cohorts.is_empty():
		return
	var ids := PackedInt64Array()
	var opcodes := PackedInt32Array()
	var amounts := PackedInt64Array()
	for handle in cohorts:
		ids.append(9200 + ids.size())
		opcodes.append(EconomyFacade.Opcode.ADD_POPULATION)
		amounts.append(4000)
	var growth := story_ext.submit_economy_pod_commands({
		"request_ids": ids, "opcodes": opcodes, "target_cohorts": cohorts, "payload0s": amounts,
	})
	_expect("population increase is admitted", bool(growth.get("ok", false)))
	_publish_day(story_host, story_clock, 2)
	if not await _wait_for(2, ""):
		return
	_ideology.submit([{"opcode": IdeologyFacade.Opcode.GRANT_FREE_DRAW,
		"country_handle": story_player, "value_q16": 1, "effective_day": 3,
		"producer_id": 77, "source_priority": -1, "sequence": 1}])
	var draw := story_controller.request_command(&"ideology.offer")
	_expect("the draw is dated for the family candidate day", int(draw.get("effective_day", -1)) == 3)
	if not await _hold_at(3, FAMILY_STOP, 6):
		return
	_expect("family takes priority when both candidates publish",
		bool(_ideology.snapshot(story_player).get("offer_active", false)))
	var view := story_host.player_confirmation_view()
	var offer: Dictionary = view.get("family_offer", {})
	_expect("the family cards belong to the stopped day",
		int(offer.get("created_day", -1)) == 3 and int(offer.get("cell", -1)) == story_cell and not story_clock.paused)

	var invalid := story_controller.request_command(&"family.founding.choose", {
		"offer_id": int(offer.get("offer_id", 0)),
		"generation": int(offer.get("generation", 0)) + 1,
		"choice_index": 0})
	_expect("stale family selection reaches the executor",
		bool(invalid.get("ok", false)) and await _has_receipt(invalid, "family_founding_offer_stale"))
	var stale_era := story_controller.request_command(&"era_reward.choose", {
		"offer_generation": 99, "choice_index": 0})
	_expect("stale era selection reaches the executor",
		bool(stale_era.get("ok", false)) and await _has_receipt(stale_era, "era_reward_offer_generation_stale"))
	var blocked_draw := story_controller.request_command(&"ideology.offer")
	_expect("ideology draw while family stop is active is rejected with the blocking reason",
		bool(blocked_draw.get("ok", false)) and await _has_receipt(blocked_draw, FAMILY_STOP))

	var display := ReceiptSurface.new()
	story_controller._ui_manager = display
	story_controller._on_simulation_command_results([_find_receipt(invalid)])
	_expect("the family dialog receives the translated backend reason",
		display.error == PlayerController._confirmation_error_message("family_founding_offer_stale") and not display.error.is_empty())
	story_controller._on_simulation_command_results([_find_receipt(stale_era)])
	_expect("the era dialog receives the translated backend reason",
		display.error == PlayerController._confirmation_error_message("era_reward_offer_generation_stale") and not display.error.is_empty())
	story_controller._ui_manager = null
	_expect("invalid replies leave the original stop", int(story_ext.runtime_committed_day()) == 3)

	var hide := story_host.set_gm_toggle("ui.hide_all_except_gm", true)
	_expect("GM hide is an effective-day command", int(hide.get("effective_day", -1)) == 4)
	if not await _wait_for(3, IDEOLOGY_STOP):
		return
	_expect("GM policy has not taken effect while the next stop is in force",
		not bool(story_host.player_confirmation_view().get("hide_popups", true)))
	story_controller.dismiss_displayed_ideology_offer()
	if not await _wait_for(6, ""):
		return
	var saved_offer := await _get_family_offer()
	_expect("GM hiding advances past the same pending candidate",
		bool(story_host.player_confirmation_view().get("hide_popups", false)) and
		saved_offer.get("offer_id", 0) == offer.get("offer_id", -1) and saved_offer.get("status") == "OPEN")

	var chosen := story_controller.request_command(&"family.founding.choose", {
		"offer_id": int(offer.offer_id), "generation": int(offer.generation), "choice_index": 0})
	var day := int(chosen.get("effective_day", -1))
	_expect("hidden candidate remains selectable", day == 7)
	_publish_day(story_host, story_clock, 7)
	if await _wait_for(day, ""):
		_expect("family receives a successful terminal receipt", await _has_receipt(chosen, ""))
		var families := await _published_economy(
			story_ext.get_family_cell_snapshot.bind(story_cell, 0, 64), day)
		_expect("the chosen offered house appears",
			PackedInt64Array(families.get("stable_ids", [])).has(int(offer.candidates[0].stable_id)))


func _hold_at(day: int, reason: String, target: int) -> bool:
	_publish_day(story_host, story_clock, target)
	if story_host._native_daily_inline_active:
		return await _wait_for(day, reason)
	var frames := Engine.get_process_frames()
	var limit := Time.get_ticks_usec() + HOLD_WATCHDOG_USEC
	var report := story_ext.get_runtime_control_state()
	while report.get("simulation_host_state") not in ["FAULTED", "STOPPED"]:
		if report.get("simulation_host_state") == "PAUSED" and int(report.get("simulation_committed_day", 0)) >= day:
			break
		if Time.get_ticks_usec() >= limit:
			break
		OS.delay_usec(500)
		report = story_ext.get_runtime_control_state()
	_expect("waiting on %s required zero foreground frames" % reason,
		Engine.get_process_frames() == frames and report.get("player_block_reason") == reason
		and int(report.get("simulation_committed_day", -1)) == day)
	return await _wait_for(day, reason)


func _wait_for(day: int, reason: String) -> bool:
	var limit := Time.get_ticks_usec() + HOLD_WATCHDOG_USEC
	var report := {}
	while Time.get_ticks_usec() < limit:
		story_host._consume_runtime_commit_if_ready()
		report = story_ext.get_runtime_control_state()
		var committed := int(report.get("simulation_committed_day", -1))
		if committed > day or report.get("simulation_host_state") == "FAULTED":
			break
		if committed == day and story_host._runtime_commit_day == day and \
				story_controller.player_confirmation_reason() == reason:
			return true
		await process_frame
	_expect("day %d publishes %s (received day %d): %s" % [day, reason, story_host._runtime_commit_day, report], false)
	return false


func _get_family_offer() -> Dictionary:
	var page := await _published_economy(story_economy.family_founding_offers,
		int(story_ext.runtime_committed_day()))
	var rows: Array = page.get("offers", [])
	return {} if rows.is_empty() else rows[0]


func _record_receipt(id: StringName, result: Dictionary) -> void:
	var row := result.duplicate(false)
	row["command"] = id
	_settled.append(row)


func _find_receipt(command: Dictionary) -> Dictionary:
	for row in _settled:
		if row.get("sequence", -1) == command.get("sequence", -2):
			return row
	return {}


func _dismissal_terminal_since(first_index: int) -> Dictionary:
	for index in range(_settled.size() - 1, first_index - 1, -1):
		if String(_settled[index].get("command", "")) == "ideology.offer.dismiss":
			return _settled[index]
	return {}


func _has_receipt(command: Dictionary, reason: String) -> bool:
	var deadline := Time.get_ticks_usec() + HOLD_WATCHDOG_USEC
	var row := _find_receipt(command)
	while row.is_empty() and Time.get_ticks_usec() < deadline:
		await process_frame
		row = _find_receipt(command)
	return not row.is_empty() and bool(row.get("ok", false)) == reason.is_empty() and row.get("reason", "") == reason



func _save_runtime_bundle(request_id: int) -> Dictionary:
	var accepted: Dictionary = story_host._generator.request_runtime_save(request_id)
	if not bool(accepted.get("pending", false)):
		return accepted
	var deadline := Time.get_ticks_msec() + 5000
	var saved := {}
	while Time.get_ticks_msec() < deadline:
		saved = story_host._generator.poll_runtime_save(request_id)
		if bool(saved.get("ready", false)) or not bool(saved.get("ok", true)):
			return saved
		story_host._process(0.0)
		await process_frame
	return {"ok": false, "code": "ticket_save_not_ready"}
