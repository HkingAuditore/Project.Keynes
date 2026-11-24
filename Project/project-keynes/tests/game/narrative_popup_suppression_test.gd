extends "res://tests/support/runtime_narrative_scenario.gd"

const Categories = preload("res://scripts/narrative/narrative_pause_categories.gd")
const Options = preload("res://scripts/ui/components/event_pause_options.gd")


class StoryDialog extends RefCounted:
	var offer := {}
	var outcome := {}

	func show_narrative_event_offer(value: Dictionary) -> void:
		offer = value

	func close_narrative_event_offer() -> void:
		offer = {}

	func is_narrative_event_modal_open() -> bool:
		return not offer.is_empty() or not outcome.is_empty()

	func show_narrative_event_outcome(value: Dictionary) -> void:
		outcome = value.get("record", {})


func _run() -> void:
	var options := Options.new()
	root.add_child(options)
	_expect("the eight groups carry sixteen independent settings", Categories.NAMES.size() == 8)
	for mask in [0, 255, 65535, 0x5aa5]:
		options.configure(mask)
		_expect("settings keep all sixteen choices for %d" % mask, options.value() == mask)
	options.free()
	if await _start_story({"scheduled_events": [
		{"due_day": 2, "event_id": "evt.ages.first_seed"},
		{"due_day": 4, "event_id": "evt.chain.ancient_foundry_legacy"},
		{"due_day": 6, "event_id": "evt.climate.severe_drought"},
	]}):
		await _check_policy()
	await _close_story()
	if await _start_story({"scheduled_events": [{"due_day": 2, "event_id": "evt.ages.first_seed"}]}):
		await _check_choice_while_paused()
	await _close_story()
	if await _start_story({"scheduled_events": [
		{"due_day": 2, "event_id": "evt.ages.first_seed"},
		{"due_day": 7, "event_id": "evt.climate.severe_drought"},
	]}, [], null, 4):
		await _check_gm_popup_policy()
	await _close_story()
	print("narrative event pause: %d checks, %d failures" % [_checks, _failures])
	call_deferred("quit", 0 if _failures == 0 else 1)


func _check_policy() -> void:
	if not await _advance_story(2):
		return
	_expect("choices are stopped by default", story_service.event_pause_mask() == 255
		and story_service.active_offer().get("event_id") == "evt.ages.first_seed")
	story_clock.pause(true)
	story_host._sync_runtime_worker_clock()
	var category := Categories.category("evt.ages.first_seed")
	var mask := 255 ^ (1 << category)
	var change := story_service.update_event_pause_mask(mask)
	var admitted := bool(change.get("ok", false)) and int(change.get("effective_day", -1)) == 3
	_expect("the category change is admitted for day 3", admitted)
	var before := story_ext.capture_gameplay_narrative()
	# Admission queues the request. Only the worker can install it, even while
	# player time is paused. Observe that boundary before releasing day 3.
	if admitted:
		for _slice in range(MAX_SLICES_PER_DAY):
			if before.get("pending_event_pause_masks") == [[3, mask]]:
				break
			await process_frame
			before = story_ext.capture_gameplay_narrative()
	print("EVENT_PAUSE_BOUNDARY receipt=", change, " stored=", before.get("event_pause_mask"),
		" pending=", before.get("pending_event_pause_masks"))
	_expect("the worker queues the change while the world stays on day 2",
		story_ext.runtime_committed_day() == 2
		and int(before.get("event_pause_mask", -1)) == 255
		and before.get("pending_event_pause_masks") == [[3, mask]])
	_expect("accepting a policy does not release the player's pause", story_clock.paused)
	story_clock.pause(false)
	story_host._sync_runtime_worker_clock()
	if not await _advance_story(3):
		return
	var records := _story_records()
	_expect("the choice is made by the executor on the policy day",
		records.size() == 1 and bool(records[0].get("automatically_chosen", false))
		and records[0].get("resolved_day") == 3 and records[0].get("chosen_option_index") == 0)
	_expect("the policy is stored only after it takes effect",
		story_ext.capture_gameplay_narrative().get("event_pause_mask") == mask)
	if not await _advance_story(4):
		return
	var foundry: Dictionary = story_ext.capture_gameplay_narrative().get("pending_choice", {})
	_expect("the one-option foundry is a default non-stopping notice",
		int(foundry.get("effective_day", -1)) == 5 and not story_service.has_active_offer())
	if not await _advance_story(5):
		return
	records = _story_records()
	_expect("the foundry notice resolves with its actual option on day 5",
		records.size() == 2 and records[0].get("event_id") == "evt.chain.ancient_foundry_legacy"
		and records[0].get("resolved_day") == 5)
	story_clock.pause(true)
	var saved_speed := story_clock.speed_multiplier
	# Leave notices running so the scheduled choice owns the next stop.
	var restored_policy := story_service.update_event_pause_mask(255)
	_expect("an event setting preserves the player's explicit pause and speed",
		restored_policy.get("ok", false) and restored_policy.get("effective_day") == 6
		and story_clock.paused and story_clock.speed_multiplier == saved_speed)
	story_clock.pause(false)
	if not await _advance_story(6):
		return
	_expect("the next choice is actively waiting for a player",
		story_service.active_offer().get("event_id") == "evt.climate.severe_drought")
	_publish_day(story_host, story_clock, 7)
	var frame := Engine.get_process_frames()
	OS.delay_msec(HOLD_MSEC)
	_expect("the native stop survives without a foreground frame",
		story_host._calendar_admitted_through >= 7 and story_ext.runtime_committed_day() == 6
		and Engine.get_process_frames() == frame
		and story_host.get_generator().get_runtime_control_state().get("simulation_host_state") == "PAUSED")


func _check_choice_while_paused() -> void:
	var dialog := StoryDialog.new()
	var flow = story_controller.narrative_flow()
	flow.configure(story_controller, story_host, story_clock, dialog, story_service)
	if not await _advance_story(2):
		return
	_expect("the calendar had admitted day 2 before the player pauses",
		story_host._calendar_admitted_through == 2)
	story_clock.pause(true)
	story_host._sync_runtime_worker_clock()
	_expect("manual pause suspends calendar admission", story_host._calendar_admitted_through == -1)
	var offer := story_service.active_offer()
	_expect("a real offer is shown before the player responds", dialog.is_narrative_event_modal_open())
	var receipt: Dictionary = flow.on_option_chosen(int(offer.offer_id), int(offer.offer_generation), 0)
	_expect("the accepted choice leaves the player able to resume the paused clock",
		bool(receipt.get("ok", false)) and receipt.get("effective_day") == 3
		and story_clock.paused and story_host._calendar_admitted_through == -1
		and not dialog.is_narrative_event_modal_open())
	story_clock.pause(false)
	if not await _advance_story(3):
		return
	_expect("the dialog shows the outcome from the committed choice",
		dialog.outcome.get("offer_id") == offer.offer_id and dialog.outcome.get("resolved_day") == 3)

func _check_gm_popup_policy() -> void:
	if not await _advance_story(2):
		return
	_expect("the story is waiting for a player before GM changes the policy",
		story_host.player_confirmation_view().get("reason") == "narrative_choice_required")
	story_clock.pause(true)
	story_host._sync_runtime_worker_clock()
	var speed := story_clock.speed_multiplier
	var enabled := story_host.set_gm_toggle("ui.suppress_popups", true)
	_expect("GM waits for the committed policy day",
		enabled.get("effective_day") == 3
		and story_host.get_gm_toggle_state("ui.suppress_popups").get("enabled") == false)
	_expect("the request leaves the player paused and the offer unanswered",
		story_clock.paused and story_clock.speed_multiplier == speed
		and story_ext.runtime_committed_day() == 2 and _story_records().is_empty())
	story_clock.pause(false)
	story_host._sync_runtime_worker_clock()
	if not await _advance_story(3):
		return
	var records := _story_records()
	_expect("only the executor selects the eligible default on the effective day",
		records.size() == 1 and records[0].get("automatically_chosen") == true
		and records[0].get("chosen_option_index") == 0 and records[0].get("resolved_day") == 3)
	_expect("the committed GM setting is independent of the normal story and HUD settings",
		story_host.get_gm_toggle_state("ui.suppress_popups").get("enabled") == true
		and story_host.get_gm_toggle_state("ui.hide_all_except_gm").get("enabled") == false
		and story_service.event_pause_mask() == 255)
	if not await _advance_story(5, false):
		return
	var report := story_host.annual_report_snapshot(1)
	_expect("the executor skips the ready annual prompt and keeps its settled reward and history",
		report.get("complete") == true and report.get("reward_settled") == true
		and story_host.annual_report_status().get("ready_report_id") == 0
		and String(story_host.player_confirmation_view().get("reason", "")) != "annual_report_confirmation_required")
	var disabled := story_host.set_gm_toggle("ui.suppress_popups", false)
	_expect("GM disable is also dated by the executor", disabled.get("effective_day") == 6)
	if not await _advance_story(7, false):
		return
	_expect("normal story choices wait for input again after disabling suppression",
		story_host.get_gm_toggle_state("ui.suppress_popups").get("enabled") == false
		and story_host.player_confirmation_view().get("reason") == "narrative_choice_required"
		and _story_records().size() == 1)
