extends "res://tests/runtime/background_daily_self_sufficiency_test.gd"

const Service = preload("res://scripts/era/era_advancement_service.gd")
const Rules = preload("res://scripts/era/era_advancement_catalog.gd")
const START_DAY := 25
const EXECUTION_DAY := 27
const PURCHASE_DAY := 29
const PROMOTION_DAY := 31
const REWARD_DAY := 33

var _advance := Service.new()
var _sequence := 980000
var _terminals := {}


func _run() -> void:
	_check_catalog()
	await _run_world(false)
	_finish()


func _create_host() -> WorldRuntimeHost:
	var host := WorldRuntimeHost.new()
	var module := preload("res://scripts/game/runtime_session_module.gd").new()
	module.configure("era_test", ["restore"], ["world.era"], _prepare_era.bind(host),
		func() -> void: pass, _advance.release_world)
	_expect("register era initialization before executor startup",
		bool(host.register_session_module(module).get("ok", false)))
	return host


func _prepare_era(host: WorldRuntimeHost) -> Dictionary:
	var generator := host.get_generator()
	var country = generator.get_country_facade()
	var handle := int(country.cell_summary(int(generator.gameplay_start_report().cell)).country_handle)
	var reward: Dictionary = country.bind_era_reward_player_country(handle)
	_expect("the native reward planner binds the player before startup", bool(reward.get("ok", false)))
	var bound: bool = _advance.bind(country, generator.get_economy_facade(), handle)
	_expect("advancement binds the executor session before startup", bound)
	return {"ok": bound and bool(reward.get("ok", false))}


func _sample_world(host: WorldRuntimeHost, clock: WorldClock, _stall: bool) -> Dictionary:
	var generator := host.get_generator()
	var economy = generator.get_economy_facade()
	var country = generator.get_country_facade()
	var ext: Object = economy.world_ext()
	var cell := int(generator.gameplay_start_report().get("cell", -1))
	var handle := int(country.cell_summary(cell).get("country_handle", 0))
	_expect("rebinding the same session retains state", not _advance.bind(country, economy, handle))
	_expect("live reward rebinding cannot touch the executing session",
		country.bind_era_reward_player_country(handle).get("reason") == "era_session_setup_requires_stopped_executor")
	var opening := _advance.preview()
	_check_model(opening)
	_expect("the opening settlement cannot advance", opening.get("status") == "locked")
	var family_policy := host.set_gm_toggle("ui.hide_all_except_gm", true)
	_expect("the procurement fixture keeps unrelated family offers open without stopping",
		family_policy.get("effective_day", -1) == 1)
	host.simulation_command_results.connect(func(rows: Array) -> void:
		for row: Dictionary in rows:
			_terminals[int(row.get("sequence", -1))] = row)
	var ineligible_start := _queue_advancement("start", 2)
	var invalid_policy := _next_sequence()
	_advance.set_policy(10001, 0, 2, invalid_policy)
	var starts: Array[int] = []
	var resumes: Array[int] = []
	var opening_budget: Dictionary = opening.budget
	var advances: Array = []
	_advance.era_advanced.connect(func(old: int, next: int, _buffs: PackedStringArray): advances.append([old, next]))
	var market := -1
	var frozen := PackedInt64Array()
	var good_ids: PackedStringArray = economy.good_ids()
	for day in range(1, REWARD_DAY + 2):
		_publish_day(host, clock, day)
		var settled := await _wait_golden_read_boundary(host, economy, day)
		_expect("the advancement fixture settles day %d" % day, settled)
		if not settled:
			break
		var model := _advance.refresh(day)
		_expect("snapshot is side-effect free on day %d" % day, model == _advance.preview())
		match day:
			1:
				_expect("stone prelude is granted", bool(country.grant_technology(handle,
					Rules.milestone_id(0), 3, _next_sequence(), true).get("ok", false)))
				for index in _advance._era_technologies(0):
					_expect("grant the researched stone technology", bool(country.grant_technology(handle,
						StringName(_advance._catalog().technology_ids[index]), 3, _next_sequence(), true).get("ok", false)))
				var pop := await _published_economy(economy.population_cell_snapshot.bind(cell), day)
				var cohorts: PackedInt64Array = pop.get("handles", PackedInt64Array())
				_expect("the starting settlement has a cohort", not cohorts.is_empty())
				if cohorts.is_empty():
					break
				_stock(ext, EconomyFacade.Opcode.ADD_POPULATION, cell, 0, cohorts[0], 520)
				var market_row := await _published_economy(economy.market_cell_snapshot.bind(cell), day)
				market = int(market_row.get("market_id", -1))
				_expect("the opening market was published", market >= 0)
				for good in ["logs", "gathered_plants", "game_meat", "clothing"]:
					_stock(ext, EconomyFacade.Opcode.ADD_STOCK, market, good_ids.find(good), 0, 5000000)
			2:
				_check_advancement(ineligible_start, day, false, "era_advance_conditions_unmet")
				_check_advancement(invalid_policy, day, false, "procurement_share_invalid")
			4:
				for i in range(470):
					_expect("sponsor a real commercial building", bool(economy.treasury_sponsored_build(
						handle, cell, &"early_merchant_post", 6, _next_sequence()).get("ok", false)))
			24:
				for good in ["logs", "gathered_plants", "game_meat"]:
					_stock(ext, EconomyFacade.Opcode.ADD_STOCK, market, good_ids.find(good), 0, 25000000)
			START_DAY:
				_expect("only settled research and two economy gates permit starting",
					bool(model.can_start) and bool(model.conditions[0].mandatory) and bool(model.conditions[0].met)
					and int(model.conditions_met) >= Rules.CONDITIONS_REQUIRED)
				opening_budget = model.budget
				var policy := _advance.set_policy(10000, 0, EXECUTION_DAY, _next_sequence())
				_expect("policy is admitted for D+2", bool(policy.ok) and int(policy.effective_day) == EXECUTION_DAY)
				for action: String in ["start", "start", "pause", "pause", "resume", "resume", "pause"]:
					starts.append(_queue_advancement(action, EXECUTION_DAY))
			START_DAY + 1:
				print("REVIEW_ERA_EARLY day=", day, " phase=", _advance.capture().get("phase"))
				_expect("the dated D+2 requests leave D+1 idle", model.status == "ready"
					and _advance.capture().required_quantities.is_empty()
					and model.budget.treasury_share_bp == opening_budget.treasury_share_bp
					and not _terminals.has(starts[0]))
			EXECUTION_DAY:
				_check_advancement(starts[0], day, true, "era_advance_started")
				_check_advancement(starts[1], day, false, "era_advance_in_progress")
				_check_advancement(starts[2], day, true, "era_advance_paused")
				_check_advancement(starts[3], day, false, "era_advance_not_purchasing")
				_check_advancement(starts[4], day, true, "era_advance_resumed")
				_check_advancement(starts[5], day, false, "era_advance_not_paused")
				_check_advancement(starts[6], day, true, "era_advance_paused")
				var paused := _advance.capture()
				for row in Rules.procurement_goods(1):
					frozen.append(Rules.required_quantity(row, paused.frozen_territory))
				_expect("the authored requirements freeze on the accepted start day and remain through pause",
					paused.required_quantities == frozen and String(paused.phase) == "paused")
				_expect("restoring an executing world is rejected before touching it",
					_advance.stage_restore(paused).get("code") == "era_session_setup_requires_stopped_executor")
				var stopped := await host._stop_previous_runtime_worker()
				_expect("the executor stopped at the committed day", stopped.get("ok") == true)
				_expect("the saved purchase is staged while the executor is stopped",
					_advance.stage_restore(paused).get("ok") == true)
				host._start_runtime_executor()
				_expect("reading the restored player section keeps the order", _advance.preview().status == "paused"
					and _advance.to_save().required_quantities == frozen)
				resumes.append(_queue_advancement("resume", PURCHASE_DAY))
				resumes.append(_queue_advancement("resume", PURCHASE_DAY))
			PURCHASE_DAY - 1:
				_expect("the restored plan stays paused until the dated resume",
					model.status == "paused" and _advance.to_save().required_quantities == frozen
					and not _terminals.has(resumes[0]))
			PURCHASE_DAY:
				_check_advancement(resumes[0], day, true, "era_advance_resumed")
				_check_advancement(resumes[1], day, false, "era_advance_not_paused")
				_expect("the resume keeps the frozen quantities",
					_advance.to_save().required_quantities == frozen)
				var stock := await _published_economy(economy.country_procurement_snapshot.bind(handle), day)
				_expect("goods from the market complete procurement on the resume day", int(stock.get("era_cash_spent_total", 0)) > 0
					and model.status == "completing" and int(_advance.to_save().completion_day) == day)
				for row in model.costs:
					_expect("the completed purchase has exact required stock", int(row.in_treasury) == int(row.required))
				_expect("reading the view never repeats or advances the completion",
					_advance.refresh(day, true) == model and _advance.refresh(day, true) == model)
			PROMOTION_DAY - 1:
				_expect("the pending batch does not advance before the milestone day", int(model.current_era_index) == 0
					and model.status == "completing" and advances.is_empty())
			PROMOTION_DAY:
				_expect("the acknowledged milestone clears the order and announces once",
					advances == [[0, 1]] and _advance.to_save().phase == "" and int(model.current_era_index) == 1)
				_expect("advancement resets trade and frozen requirements for the next era",
					int(model.next_era_index) == 2 and int(model.conditions[3].current) == 0
					and int(model.frozen_territory_count) == 0)
			REWARD_DAY:
				_expect("reward is resolved on its modifier day", country.era_reward_offer().get("status") == "RESOLVED")
				_expect("the displayed promotion is still announced once", advances == [[0, 1]])
		var offer: Dictionary = country.era_reward_offer()
		if offer.get("status") == "OPEN":
			_expect("the reward opens on its milestone day", day in [3, PROMOTION_DAY])
			var choice: Dictionary = country.choose_era_reward(int(offer.offer_generation), 0, day + 2)
			_expect("the choice keeps the exact sealed day", bool(choice.ok) and int(choice.effective_day) == day + 2)
	return {}


func _queue_advancement(action: String, day: int) -> int:
	var sequence := _next_sequence()
	var admission: Dictionary = _advance.call(action, day, sequence)
	_expect("%s enters the inbox with its date" % action,
		admission.get("admitted") == true and admission.get("effective_day") == day)
	return sequence


func _check_advancement(sequence: int, day: int, ok: bool, code: String) -> void:
	var result: Dictionary = _terminals.get(sequence, {})
	_expect("day %d produces %s (%s)" % [day, code, result], result.get("ok") == ok
		and result.get("code") == code and result.get("settled_day") == day
		and (result.has("effective_day") if ok else not result.has("effective_day")))


func _stock(ext: Object, op: int, cell: int, good: int, cohort: int, value: int) -> void:
	var reply: Dictionary = ext.submit_economy_pod_commands({
		"request_ids": PackedInt64Array([_next_sequence()]),
		"opcodes": PackedInt32Array([op]), "target_cells": PackedInt32Array([cell]),
		"target_countries": PackedInt64Array([good]), "target_cohorts": PackedInt64Array([cohort]),
		"payload0s": PackedInt64Array([value]),
	})
	_expect("native settlement fixture command accepted", bool(reply.get("ok", false)))


func _next_sequence() -> int:
	_sequence += 1
	return _sequence


func _check_catalog() -> void:
	for target in range(1, 11):
		_expect("the reviewed gates rise with territory for era %d" % target,
			Rules.population_threshold(target, 2) > Rules.population_threshold(target, 1)
			and Rules.building_threshold(target, 2) > Rules.building_threshold(target, 1)
			and Rules.trade_order_threshold(target, 2) > Rules.trade_order_threshold(target, 1))
		for good in Rules.procurement_goods(target):
			_expect("each additional cell raises the basket",
				Rules.required_quantity(good, 2) > Rules.required_quantity(good, 1))


func _check_model(model: Dictionary) -> void:
	_expect("the published model contains the four ordered eligibility gates",
		model.get("conditions", []).size() == 4 and model.conditions[0].key == "tech"
		and model.conditions[3].key == "trade")
