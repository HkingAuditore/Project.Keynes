extends "res://tests/support/runtime_narrative_scenario.gd"

const Rebellion = preload("res://scripts/politics/stratum_rebellion_content.gd")
const Events = preload("res://scripts/data_core/gameplay_event_bus.gd")
const REBEL_CELL := 4644
const OLD_OWNER := 4294967296


func _run() -> void:
	_expect("stage one can be ignored",
		Rebellion.actions_for_stage(1).has(Rebellion.ACTION_IGNORE))
	_expect("stage four offers abandonment",
		Rebellion.actions_for_stage(4).has(Rebellion.ACTION_ABANDON))
	if await _start_story({}):
		await _check_independence()
	await _close_story()
	if await _start_story({}):
		await _check_independence()
	await _close_story()
	print("stratum unrest executor: %d checks, %d failures" % [_checks, _failures])
	call_deferred("quit", 0 if _failures == 0 else 1)


func _check_independence() -> void:
	_expect("fixture owns the original country", story_player == OLD_OWNER)
	var country = story_host.get_generator().get_country_facade()
	var claim: Dictionary = country.transfer_territory(REBEL_CELL, story_player, 2, 994644, true)
	_expect("the future rebel cell is claimed on day 2",
		bool(claim.get("ok", false)) and int(claim.get("effective_day", -1)) == 2)
	if not await _advance_story(2):
		return
	var bus := story_host.get_generator().get_gameplay_event_bus()
	var fact: Dictionary = bus.publish_event(Events.EVENT_STRATUM_MOBILIZATION, REBEL_CELL, 4,
		0, Events.SOURCE_GDSCRIPT, 8, Events.PAYLOAD_STRATUM_MOBILIZATION_V1,
		4, 3, story_economy.profession_ids().find("unemployed"), 0)
	_expect("the independent-cell fact is admitted", int(fact.get("published", 0)) == 1)
	if not await _advance_story(5):
		return
	var state := story_ext.capture_gameplay_narrative()
	var pending: Array = state.get("stratum_unrest", {}).get("pending_independence", [])
	_expect("the executor sends the creation request exactly once",
		pending.size() == 1 and bool(pending[0].get("submitted", false)))
	_expect("the old owner still holds the cell before the request settles",
		int(country.cell_summary(REBEL_CELL).get("country_handle", 0)) == story_player)
	if not await _advance_story(6):
		return
	var rebel: Dictionary = country.cell_summary(REBEL_CELL)
	_expect("the territory changes on day 6 and has a stable rebel identity",
		int(rebel.get("country_handle", 0)) > story_player
		and country.snapshot(int(rebel.get("country_handle", 0))).get("country_id") == "rebel.%d.4" % REBEL_CELL)
	state = story_ext.capture_gameplay_narrative()
	_expect("the executor removes the settled independence request",
		state.get("stratum_unrest", {}).get("pending_independence", []).is_empty())
	if not await _advance_story(8):
		return
	var war: Dictionary = story_ext.poll_gameplay_events({"type": 40})
	var military = story_host.get_generator().get_military_facade()
	var report: Dictionary = military.country_snapshot(story_player)
	_expect("the old sovereign declares war and the facts carry day 7",
		war.get("tick") == PackedInt64Array([7])
		and int(report.get("wars_active", 0)) == 1)
	_expect("the independence notification does not stop by default",
		not story_service.has_active_offer())
