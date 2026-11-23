extends "res://tests/support/runtime_narrative_scenario.gd"

const COMMAND_ID := 550001


func _run() -> void:
	if await _start_story({"scheduled_events": [
		{"due_day": 2, "event_id": "evt.ages.first_seed", "chain_id": "first"},
		{"due_day": 2, "event_id": "evt.ages.first_grave", "chain_id": "second"},
	]}):
		await _check_handoff()
	await _close_story()
	print("player calendar handoff: %d checks, %d failures" % [_checks, _failures])
	quit(0 if _failures == 0 else 1)


func _check_handoff() -> void:
	var days: Array[int] = []
	var receipts: Array[int] = []
	story_host.simulation_day_records.connect(func(records: Array) -> void:
		for row: Dictionary in records:
			days.append(int(row.day))
			for receipt: Dictionary in row.receipts:
				if int(receipt.request_id) == COMMAND_ID:
					receipts.append(int(receipt.effective_day)))
	var admission: Dictionary = story_ext.submit_runtime_command({"request_id": COMMAND_ID,
		"producer_id": 2, "requested_day": 2, "domain": 1, "opcode": 1})
	_expect("a future command is admitted for day 2", admission.get("ok", false)
		and int(admission.get("effective_day", -1)) == 2)
	story_clock.set_speed(50.0)
	story_clock.pause(false)
	# The real bound calendar receives four additional days of elapsed time.
	# Only days 1 and 2 may commit before the first player choice.
	var through := story_clock._runtime_calendar_through + 4
	story_clock._process(0.08)
	_expect("50x releases the elapsed days", through > 2
		and story_host._calendar_admitted_through == through)
	if not await _settled_at(2):
		return
	_expect("days and command receipt arrive once and in order", days == [1, 2] and receipts == [2])
	_expect("the native player decision stops the day with calendar still running",
		_blocked_on_story(2) and not story_clock.paused)
	story_clock._process(0.02)
	OS.delay_msec(HOLD_MSEC)
	_expect("a later calendar request cannot bypass the decision", _blocked_on_story(2))
	if not await _answer_story("first", 3):
		return
	_expect("the next published choice keeps the worker stopped", _blocked_on_story(3))
	story_clock.pause(true)
	var halted := story_host._calendar_admitted_through
	story_clock._process(0.1)
	_expect("manual pause stops calendar admission", story_clock.paused
		and story_host._calendar_admitted_through == halted)
	if not await _answer_story("second", 4):
		return
	story_clock._process(0.1)
	OS.delay_msec(HOLD_MSEC)
	_expect("a valid response may settle, then manual pause still holds", story_clock.paused
		and story_ext.runtime_committed_day() == 4)
	story_clock.set_speed(1.0)
	story_clock.pause(false)
	story_clock._process(0.5)
	_expect("1x keeps fractional time until one full day", story_host._calendar_admitted_through == halted)
	story_clock._process(0.5)
	_expect("1x releases only the next day", story_host._calendar_admitted_through == 5)
	if await _settled_at(5):
		_expect("the display calendar follows the complete last committed day", story_clock.day_index() == 6)
		_expect("resume preserves all daily records and the original one-time receipt",
			days == [1, 2, 3, 4, 5] and receipts == [2])


func _settled_at(day: int) -> bool:
	var settled := await _wait_golden_read_boundary(story_host, story_economy, day)
	_expect("background and display both reach day %d" % day, settled)
	if settled:
		story_day = day
		story_service.consume_committed()
	return settled


func _blocked_on_story(day: int) -> bool:
	var state := story_host.get_generator().get_runtime_control_state()
	return state.get("simulation_host_state") == "PAUSED" \
		and int(state.get("simulation_committed_day", -1)) == day \
		and int(state.get("player_block_day", -1)) == day \
		and state.get("player_block_reason") == "narrative_choice_required"


func _answer_story(chain: String, day: int) -> bool:
	var offer := story_service.active_offer()
	var expected: bool = offer.get("chain_id") == chain
	_expect("the published offer is %s" % chain, expected)
	if not expected:
		return false
	var answer := _choose_story(0)
	if not answer.get("ok", false) or not await _settled_at(day):
		return false
	var chronicle := _story_records()
	_expect("the accepted %s choice takes effect on day %d" % [chain, day],
		not chronicle.is_empty() and chronicle[0].get("chain_id") == chain
		and int(chronicle[0].get("resolved_day", -1)) == day)
	return true
