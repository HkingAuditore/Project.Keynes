extends SceneTree

## Service-level coverage for the rebellion bridge without a full world:
## option resolution, concession payment, and the independence -> war sequence.

const ServiceScript = preload("res://tests/support/legacy_unrest_fixture.gd")
const ContentScript = preload("res://scripts/politics/stratum_rebellion_content.gd")
const NarrativeFixture = preload("res://tests/support/legacy_narrative_fixture.gd")
const NarrativeFlow = preload("res://scripts/narrative/narrative_event_flow.gd")
const GameplayEventBusScript = preload("res://scripts/data_core/gameplay_event_bus.gd")

var _checks := 0
var _failures := 0


class MockClock:
	var paused := true
	var speed_multiplier := 1.0
	func pause(value: bool) -> void: paused = value


class MockNarrativeUI:
	var shown := {}
	func show_narrative_event_offer(offer: Dictionary) -> void: shown = offer


class MockJournal:
	var batch := {}
	var requested_type := 0
	func get_gameplay_event_schema() -> Dictionary: return {}
	func get_gameplay_event_bus_report() -> Dictionary: return {}
	func poll_gameplay_events(opts: Dictionary) -> Dictionary:
		if opts.get("consumer_id") != &"stratum_unrest_service":
			return {}
		requested_type = int(opts.get("type", 0))
		return batch if int(opts.get("after_event_id", 0)) < 42 else {}


class MockGenerator:
	var bus = GameplayEventBusScript.new()
	func get_gameplay_event_bus(): return bus


class MockEconomy:
	var applied: Array = []
	var payments: Array = []
	var stage := 4
	func cell_mobilization_snapshot(_cell: int) -> Dictionary:
		return {"ok": true, "rows": [{"profession": 0, "stage": stage, "flags": 1}]}
	func is_configured() -> bool: return true
	func mobilization_odds(_cell: int, _prof: int, _action: int, _spend: int) -> Dictionary:
		return {"ok": true, "p_success_q16": 40000, "cost_bp": 50}
	func apply_mobilization_result(cell: int, prof: int, action: int, success: bool) -> bool:
		applied.append([cell, prof, action, success])
		if not success:
			stage = mini(4, stage + 1)
		return true
	func settlement_display_name(_cell: int) -> String: return "测试城"
	func profession_ids() -> PackedStringArray: return PackedStringArray(["merchant"])
	func population_cell_snapshot(_cell: int, _details: bool) -> Dictionary:
		return {"handles": PackedInt64Array([77]), "populations": PackedInt64Array([100])}
	func transfer_country_cash_to_cohort(_country: int, cohort: int, amount: int,
			_day: int, _seq: int) -> Dictionary:
		payments.append([cohort, amount])
		return {"ok": true}


class MockCountry:
	var handle := 1
	func cell_summary(_cell: int) -> Dictionary:
		return {"country_handle": handle, "country_slot": 0, "territory_count": 2}
	func snapshot(_handle: int) -> Dictionary:
		return {"ok": true, "cash": 100000, "territory_cells": PackedInt32Array([5])}
	func create_country(_stable_id: StringName, _name: String, _cell: int,
			_day: int, _seq: int) -> Dictionary:
		handle = 9
		return {"ok": true}


class MockMilitary:
	var wars: Array = []
	func cell_snapshot(_cell: int) -> Dictionary:
		return {"present": 0, "garrison": 0}
	func declare_war(country: int, target: int) -> Dictionary:
		wars.append([country, target])
		return {"ok": true}


func _init() -> void:
	call_deferred("_run_and_quit")


func _run_and_quit() -> void:
	_run()
	print("stratum unrest service: %d checks, %d failures" % [_checks, _failures])
	quit(0 if _failures == 0 else 1)


func _run() -> void:
	_test_player_delivery()
	_test_followup_delivery()
	var service = ServiceScript.new()
	var economy := MockEconomy.new()
	var country := MockCountry.new()
	var military := MockMilitary.new()
	service.configure(null, null, MockClock.new(), null, economy, country,
		military, 1, 12345)
	service.step_daily(9)
	var record := {
		"chosen_option_index": 0,
		"rolled_outcome_index": 0,
		"day": 9,
		"meta": {
			"kind": "rebellion", "cell": 5, "profession": 0, "stage": 4,
			"owner_handle": 1,
			"actions": [ContentScript.ACTION_ABANDON],
			"cost_bps": [0],
		},
	}
	service.on_offer_resolved(record)
	_expect("abandon applies as a successful action",
		economy.applied.size() == 1 and
		int(economy.applied[0][2]) == ContentScript.ACTION_ABANDON and
		bool(economy.applied[0][3]))
	_expect("abandon queues independence",
		service.export_state().get("pending_independence", []).size() == 1)
	service.step_daily(10)
	_expect("independence creates a country on the next day",
		country.handle == 9)
	service.step_daily(11)
	_expect("the old sovereign declares war once the split lands",
		military.wars.size() == 1 and int(military.wars[0][0]) == 1 and
		int(military.wars[0][1]) == 9)
	_expect("the independence queue drains after the war",
		service.export_state().get("pending_independence", []).is_empty())

	# A concession pays treasury cash to the local primary cohort.
	var paid := MockEconomy.new()
	var paid_service = ServiceScript.new()
	paid_service.configure(null, null, MockClock.new(), null, paid,
		MockCountry.new(), MockMilitary.new(), 1, 12345)
	paid_service.step_daily(1)
	paid_service.on_offer_resolved({
		"chosen_option_index": 0,
		"rolled_outcome_index": 0,
		"day": 1,
		"meta": {
			"kind": "rebellion", "cell": 5, "profession": 0, "stage": 1,
			"owner_handle": 1,
			"actions": [ContentScript.ACTION_CONCEDE],
			"cost_bps": [50],
		},
	})
	_expect("concession pays the primary cohort",
		paid.payments.size() == 1 and int(paid.payments[0][0]) == 77 and
		int(paid.payments[0][1]) == 500)
	_expect("concession still applies the native result",
		paid.applied.size() == 1 and
		int(paid.applied[0][2]) == ContentScript.ACTION_CONCEDE)


func _test_player_delivery() -> void:
	var generator := MockGenerator.new()
	generator.bus.bind_world_ext(MockJournal.new())
	var economy := MockEconomy.new()
	var clock := MockClock.new()
	clock.paused = false
	var ui := MockNarrativeUI.new()
	var service := NarrativeFixture.new()
	service.configure(generator, null, null, clock, 1, 12345)
	var unrest = ServiceScript.new()
	unrest.configure(generator, null, clock, service, economy, MockCountry.new(),
		MockMilitary.new(), 1, 12345)
	var flow := NarrativeFlow.new()
	flow.configure(null, null, clock, ui, service)
	unrest.step_daily(9)
	var offer: Dictionary = service.active_offer()
	_expect("existing merchant unrest is recovered at its current stage without a retained fact",
		offer.get("event_id") == "evt.rebellion.stage_4"
		and String(offer.get("body_text", "")).contains("测试城的商团"))
	_expect("the rebellion offer reaches the modal and pauses the clock",
		ui.shown.get("event_id") == "evt.rebellion.stage_4" and clock.paused)
	if not offer.is_empty():
		var actions: Array = offer.get("meta", {}).get("actions", [])
		var abandon_index := actions.find(ContentScript.ACTION_ABANDON)
		if abandon_index >= 0:
			service.choose_option(offer.offer_id, offer.offer_generation, abandon_index, 10)
	_expect("the narrative resolution reaches the unrest effect adapter",
		economy.applied.size() == 1)
	var saved := service.export_state()
	saved["stratum_unrest"] = unrest.export_state()
	_expect("pending independence is saved with narrative state",
		saved.get("stratum_unrest", {}).get("pending_independence", []).size() == 1)
	var restored: Dictionary = bytes_to_var(var_to_bytes(saved))
	_expect("pending independence survives restoring the narrative save",
		bool(service.restore_state(restored).get("ok", false))
		and bool(unrest.restore_state(restored.get("stratum_unrest", {})).get("ok", false))
		and unrest.export_state().get("pending_independence", []).size() == 1)


func _test_followup_delivery() -> void:
	var journal := MockJournal.new()
	var generator := MockGenerator.new()
	generator.bus.bind_world_ext(journal)
	var economy := MockEconomy.new()
	economy.stage = 0
	var service := NarrativeFixture.new()
	service.configure(generator, null, null, null, 1, 12345)
	var unrest = ServiceScript.new()
	unrest.configure(generator, null, null, service, economy, MockCountry.new(),
		MockMilitary.new(), 1, 12345)
	unrest.step_daily(8)
	economy.stage = 1
	journal.batch = {
		"count": 1, "event_id": PackedInt64Array([42]),
		"type": PackedInt32Array([GameplayEventBusScript.EVENT_STRATUM_MOBILIZATION]),
		"cell_idx": PackedInt32Array([5]), "flags": PackedInt32Array([1]),
		"payload_i0": PackedInt32Array([1]), "payload_i1": PackedInt32Array([0]),
		"payload_i2": PackedInt32Array([0]), "payload_i3": PackedInt32Array([0]),
	}
	unrest.step_daily(9)
	var offer: Dictionary = service.active_offer()
	_expect("the player commit consumes only mobilization facts and opens stage one",
		journal.requested_type == GameplayEventBusScript.EVENT_STRATUM_MOBILIZATION
		and offer.get("event_id") == "evt.rebellion.stage_1")
	if offer.get("event_id") == "evt.rebellion.stage_1":
		var actions: Array = offer.meta.actions
		service.choose_option(offer.offer_id, offer.offer_generation,
			actions.find(ContentScript.ACTION_IGNORE), 10)
	var saved := service.export_state()
	saved["stratum_unrest"] = unrest.export_state()
	var restored: Dictionary = bytes_to_var(var_to_bytes(saved))
	service.restore_state(restored)
	unrest.restore_state(restored["stratum_unrest"])
	unrest.step_daily(10)
	_expect("a failed response continues after reload even if its fact was lost",
		service.active_offer().get("event_id") == "evt.rebellion.stage_2")
	unrest.step_daily(11)
	_expect("the consumed fact and recovered stage are not queued again",
		service.ready_queue_size() == 0)


func _expect(label: String, condition: bool) -> void:
	_checks += 1
	if condition:
		print("  [OK] %s" % label)
	else:
		_failures += 1
		print("  [FAIL] %s" % label)
