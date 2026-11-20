extends SceneTree

## Service-level coverage for the rebellion bridge without a full world:
## option resolution, concession payment, and the independence -> war sequence.

const ServiceScript = preload("res://scripts/politics/stratum_unrest_service.gd")
const Rng = preload("res://scripts/narrative/narrative_rng.gd")
const ContentScript = preload("res://scripts/politics/stratum_rebellion_content.gd")
const PlayerControllerScript = preload("res://scripts/game/player_controller.gd")
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


class MockRuntimeHost:
	var source := MockGenerator.new()
	func generator(): return source


class MockEconomy:
	var applied: Array = []
	var payments: Array = []
	var stage := 4
	var reject_choice := false
	var population_busy := false
	func cell_mobilization_snapshot(_cell: int) -> Dictionary:
		return {"ok": true, "rows": [{"profession": 0, "stage": stage, "flags": 1}]}
	func is_configured() -> bool: return true
	func mobilization_odds(_cell: int, _prof: int, _action: int, spend: int) -> Dictionary:
		return {"ok": true, "p_success_q16": 13107 if spend == 50 else 3277,
			"cost_bp": 50, "stage": stage}
	func apply_mobilization_result(cell: int, prof: int, action: int, success: bool) -> bool:
		applied.append([cell, prof, action, success])
		if not success:
			stage = mini(4, stage + 1)
		return true
	func resolve_player_mobilization(choice: Dictionary) -> Dictionary:
		if reject_choice:
			return {"ok": false, "code": "economy_busy_retry"}
		apply_mobilization_result(choice.cell, choice.profession, choice.action, choice.success)
		if int(choice.cash) > 0:
			payments.append([choice.cohort_handle, choice.cash, choice.effective_day, choice.sequence])
		return {"ok": true, "queued_cash": choice.cash, "stage": stage}
	func settlement_display_name(_cell: int) -> String: return "测试城"
	func profession_ids() -> PackedStringArray: return PackedStringArray(["merchant"])
	func population_cell_snapshot(_cell: int, _details: bool) -> Dictionary:
		if population_busy:
			return {"busy": true}
		return {"handles": PackedInt64Array([77]), "populations": PackedInt64Array([100])}


class MockCountry:
	var handle := 1
	var treasury_cash := 100000
	func cell_summary(_cell: int) -> Dictionary:
		return {"country_handle": handle, "country_slot": 0, "territory_count": 2}
	func snapshot(_handle: int) -> Dictionary:
		return {"ok": true, "cash": treasury_cash, "territory_count": 2, "territory_cells": PackedInt32Array([5])}
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
	_test_paid_choice_preview_and_roll()
	var service = ServiceScript.new()
	var economy := MockEconomy.new()
	var country := MockCountry.new()
	var military := MockMilitary.new()
	service.configure(null, null, MockClock.new(), null, economy, country,
		military, 1, 12345)
	service.step_daily(9)
	var offer := {
		"options": [{}],
		"meta": {
			"kind": "rebellion", "cell": 5, "profession": 0, "stage": 4,
			"owner_handle": 1, "actions": [ContentScript.ACTION_ABANDON],
		},
	}
	service.resolve_player_choice(offer, 0, {"rebellion_success": true,
		"probability_q16": 65536}, 9, Callable())
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


func _test_player_delivery() -> void:
	var runtime := MockRuntimeHost.new()
	var journal := MockJournal.new()
	runtime.source.bus.bind_world_ext(journal)
	var economy := MockEconomy.new()
	var controller = PlayerControllerScript.new()
	root.add_child(controller)
	var clock := MockClock.new()
	clock.paused = false
	var ui := MockNarrativeUI.new()
	controller._world_clock = clock
	controller._ui_manager = ui
	controller._runtime_host = runtime
	controller._player_country_handle = 1
	controller._economy_facade = economy
	controller._country_facade = MockCountry.new()
	controller._configure_narrative_runtime()
	controller._step_narrative_daily(9)
	var service = controller.narrative_service()
	var offer: Dictionary = service.active_offer()
	_expect("existing merchant unrest is recovered at its current stage without a retained fact",
		offer.get("event_id") == "evt.rebellion.stage_4"
		and String(offer.get("body_text", "")).contains("测试城的商团"))
	_expect("the rebellion offer reaches the modal and pauses the clock",
		ui.shown.get("event_id") == "evt.rebellion.stage_4" and clock.paused)
	if not offer.is_empty():
		var actions: Array = offer.get("meta", {}).get("actions", [])
		_expect("stage four labels match the underlying amnesty, suppression, and secession actions",
			offer.options[actions.find(ContentScript.ACTION_AMNESTY)].text == "开城招安"
			and offer.options[actions.find(ContentScript.ACTION_REPRESS)].text == "调兵镇压"
			and offer.options[actions.find(ContentScript.ACTION_ABANDON)].text == "带兵退出此城")
		var abandon_index := actions.find(ContentScript.ACTION_ABANDON)
		if abandon_index >= 0:
			var branches: Array = offer.options[abandon_index].outcomes
			_expect("abandon shows one certain independence outcome", branches.size() == 1
				and branches[0].probability_q16 == 65536
				and "独立" in " ".join(branches[0].effect_summaries))
			service.choose_option(offer.offer_id, offer.offer_generation, abandon_index, 10)
	_expect("the formal narrative service routes a choice back to the unrest service",
		economy.applied.size() == 1)
	var saved: Dictionary = controller.export_narrative_state()
	_expect("pending independence is saved with narrative state",
		saved.get("stratum_unrest", {}).get("pending_independence", []).size() == 1)
	_expect("pending independence survives restoring the narrative save",
		bool(controller.restore_narrative_state(bytes_to_var(var_to_bytes(saved))).get("ok", false))
		and controller.export_narrative_state().get("stratum_unrest", {})
			.get("pending_independence", []).size() == 1)
	controller.free()


func _test_followup_delivery() -> void:
	var runtime := MockRuntimeHost.new()
	var journal := MockJournal.new()
	runtime.source.bus.bind_world_ext(journal)
	var economy := MockEconomy.new()
	economy.stage = 0
	var controller = PlayerControllerScript.new()
	root.add_child(controller)
	controller._runtime_host = runtime
	controller._player_country_handle = 1
	controller._economy_facade = economy
	controller._country_facade = MockCountry.new()
	controller._configure_narrative_runtime()
	controller._step_narrative_daily(8)
	economy.stage = 1
	journal.batch = {
		"count": 1, "event_id": PackedInt64Array([42]),
		"type": PackedInt32Array([GameplayEventBusScript.EVENT_STRATUM_MOBILIZATION]),
		"cell_idx": PackedInt32Array([5]), "flags": PackedInt32Array([1]),
		"payload_i0": PackedInt32Array([1]), "payload_i1": PackedInt32Array([0]),
		"payload_i2": PackedInt32Array([0]), "payload_i3": PackedInt32Array([0]),
	}
	controller._step_narrative_daily(9)
	var service = controller.narrative_service()
	var offer: Dictionary = service.active_offer()
	_expect("the player commit consumes only mobilization facts and opens stage one",
		journal.requested_type == GameplayEventBusScript.EVENT_STRATUM_MOBILIZATION
		and offer.get("event_id") == "evt.rebellion.stage_1")
	if offer.get("event_id") == "evt.rebellion.stage_1":
		var actions: Array = offer.meta.actions
		service.choose_option(offer.offer_id, offer.offer_generation,
			actions.find(ContentScript.ACTION_IGNORE), 10)
	var saved: Dictionary = controller.export_narrative_state()
	controller.restore_narrative_state(bytes_to_var(var_to_bytes(saved)))
	controller._step_narrative_daily(10)
	_expect("a failed response continues after reload even if its fact was lost",
		service.active_offer().get("event_id") == "evt.rebellion.stage_2")
	controller._step_narrative_daily(11)
	_expect("the consumed fact and recovered stage are not queued again",
		service.ready_queue_size() == 0)
	controller.free()


func _test_paid_choice_preview_and_roll() -> void:
	var economy := MockEconomy.new()
	economy.stage = 1
	var controller = PlayerControllerScript.new()
	root.add_child(controller)
	controller._runtime_host = MockRuntimeHost.new()
	controller._player_country_handle = 1
	controller._economy_facade = economy
	var country := MockCountry.new()
	controller._country_facade = country
	controller._configure_narrative_runtime()
	controller._step_narrative_daily(9)
	var narrative = controller.narrative_service()
	var offer: Dictionary = narrative.active_offer()
	var option: Dictionary = offer.get("options", [])[0]
	var branches: Array = option.get("outcomes", [])
	_expect("paid concession uses the funded odds in the visible offer",
		int(branches[0].probability_q16) == 13107)
	_expect("concession previews organization and its cost in both branches",
		"组织度" in " ".join(branches[0].effect_summaries)
		and "国库" in " ".join(branches[0].effect_summaries)
		and "国库" in " ".join(branches[1].effect_summaries))
	var bribery: Dictionary = offer.options[1]
	_expect("bribery previews the same cash obligation and funded odds",
		bribery.rebellion_cash == option.rebellion_cash
		and bribery.outcomes[0].probability_q16 == branches[0].probability_q16)
	var effective_day := 10
	var salt := int(offer.chain_salt) * 131 + 7
	for day in range(10, 100):
		var roll := Rng.hash64(1, day, 1, 5, salt) % 65536
		if roll >= 3277 and roll < 13107:
			effective_day = day
			break
	var legacy: Dictionary = narrative.export_state()
	legacy.active_offer.erase("stratum_choices_prepared")
	legacy.active_offer.options[0].outcomes[0].probability_q16 = 3277
	legacy.active_offer.options[0].outcomes[0].effect_summaries = []
	legacy.active_offer.options[0].text = "旧选项"
	narrative.restore_state(bytes_to_var(var_to_bytes(legacy)))
	economy.population_busy = true
	_expect("temporarily unavailable population data defers the quote",
		narrative.active_offer().is_empty() and narrative.has_active_offer())
	economy.population_busy = false
	_expect("an already-open offer from an old save gets the updated effects and odds",
		narrative.active_offer().options[0].outcomes[0] == branches[0]
		and narrative.active_offer().options[0].text == option.text)
	economy.reject_choice = true
	var rejected: Dictionary = narrative.choose_option(offer.offer_id, offer.offer_generation, 0, effective_day)
	_expect("a rejected choice neither changes the state nor consumes the offer",
		not rejected.get("ok", true) and narrative.has_active_offer()
		and economy.applied.is_empty() and economy.payments.is_empty())
	economy.reject_choice = false
	var result: Dictionary = narrative.choose_option(offer.offer_id, offer.offer_generation, 0, effective_day)
	_expect("a roll between the unfunded and funded odds succeeds",
		result.get("outcome_index", -1) == 0 and economy.applied.size() == 1 and economy.applied[0][3])
	_expect("concession queues the quoted payment to the primary cohort on the effective day",
		economy.payments.size() == 1 and economy.payments[0].slice(0, 3) == [77, 500, effective_day])
	_expect("the chronicle includes the applied organization effects",
		"组织度" in " ".join(result.get("record", {}).get("applied_effects_summary", [])))
	country.treasury_cash = 0
	narrative.restore_state(bytes_to_var(var_to_bytes(legacy)))
	var unfunded: Dictionary = narrative.active_offer().options[0]
	_expect("an empty treasury keeps the unfunded odds and shows no fictitious payment",
		unfunded.rebellion_cash == 0 and unfunded.outcomes[0].probability_q16 == 3277
		and not "国库" in " ".join(unfunded.outcomes[0].effect_summaries))
	controller.free()


func _expect(label: String, condition: bool) -> void:
	_checks += 1
	if condition:
		print("  [OK] %s" % label)
	else:
		_failures += 1
		print("  [FAIL] %s" % label)
