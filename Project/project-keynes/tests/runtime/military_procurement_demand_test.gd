extends "res://tests/runtime/fiscal_return_intent_test.gd"

func _init() -> void:
	_run()
	print("military procurement demand: %d failures" % failures)
	quit(0 if failures == 0 else 1)

func _run() -> void:
	var compiled: Dictionary = EconomyCatalogScript.compile_native_catalog()
	_expect("catalog compiles", bool(compiled.get("ok", false)))
	var catalog := compiled.duplicate(true)
	catalog.erase("ok")
	var profile: Dictionary = load("res://data/economy/default_economy.tres").to_native_profile()
	profile.market_runtime_mode = "ACTIVE"
	profile.trade_runtime_mode = "OFF"
	profile.economy_cadence_force_market_days = 1
	profile.economy_cadence_force_plan_days = 5
	profile.economy_cadence_force_investment_days = 10
	var ext: Object = _new_runtime(compiled, catalog, profile, 281108, false)
	_expect("fixed replay cadence", preload("res://tests/runtime/replay_cadence.gd").install(ext))
	var country := int(ext.get_country_cell_summary(0).country_handle)
	_expect("disable research for isolated military buyer", _disable_research(ext, country))
	var good := (compiled.good_ids as PackedStringArray).find("bows")
	_expect("fixture has a military equipment SKU", good >= 0)
	if good < 0: return
	var population: Dictionary = ext.get_population_cell_snapshot(0)
	_expect("treasury funding queues", _transfer_from_cohort(ext, population.handles[0], 500000, 0, 1))
	_finish_day(ext, 0)
	var opening: Dictionary = ext.get_market_cell_snapshot(0)
	_expect("equipment begins with zero supply", int(opening.stock[good]) == 0)
	_expect("military forecast queues", _demand(ext, country, good, 1000000, 2, 100))
	# Save the admitted D+1 request before it becomes due. Prime both worlds
	# through the same opening epoch, as the ECP2 cadence fixtures do.
	var saved: Dictionary = ext.capture_economy_ecp2(0)
	_expect("complete ECP2 captures standing demand", bool(saved.get("ok", false)))
	var restored: Object = _new_runtime(compiled, catalog, profile, 281108, false)
	_expect("fixed restored cadence", preload("res://tests/runtime/replay_cadence.gd").install(restored))
	_expect("prime restored research policy", _disable_research(restored, country))
	var restored_pop: Dictionary = restored.get_population_cell_snapshot(0)
	_expect("prime restored treasury", _transfer_from_cohort(restored, restored_pop.handles[0], 500000, 0, 1))
	_finish_day(restored, 0)
	_expect("checkpoint Country identity matches", restored.get_country_state_hash() == ext.get_country_state_hash())
	var loaded: Dictionary = restored.restore_economy_ecp2(saved.get("bytes", PackedByteArray()))
	_expect("standing demand restores", bool(loaded.get("ok", false)))
	_expect("restored state hash matches", ext.get_economy_state_hash() == restored.get_economy_state_hash())
	for day in range(1, 11):
		_finish_day(ext, day)
		_finish_day(restored, day)
		_expect("restored demand day %d" % day, _daily(ext, good) == _daily(restored, good))
		_expect("restored continuation day %d" % day, ext.get_economy_state_hash() == restored.get_economy_state_hash())
		if day == 1:
			_expect("D+1 demand cannot leak into an earlier epoch", _daily(ext, good) == 0)
		if day == 2:
			var market: Dictionary = ext.get_market_cell_snapshot(0)
			_expect("zero-stock equipment has funded military demand", _daily(ext, good) > 0)
			_expect("merchant target sees the military buyer", int(market.merchant_inventory_target[good]) > 0)
			_expect("forecast creates no goods", int(market.stock[good]) == 0)
			_expect("forecast leaves treasury funds intact", int(ext.get_country_treasury_snapshot(country).cash) == 500000)
	_expect("empty replacement queues", _demand(ext, country, good, 0, 11, 200))
	_finish_day(ext, 11)
	_expect("cancelled military demand retires at the next boundary", _daily(ext, good) == 0)
	_expect("duplicate snapshot queues", _demand(ext, country, good, 1000, 12, 300)
		and _demand(ext, country, good, 1000, 12, 300))
	_finish_day(ext, 12)
	_expect("repeated snapshot does not double demand", _daily(ext, good) == 100)
	_expect("smaller replacement queues", _demand(ext, country, good, 500, 13, 400))
	_finish_day(ext, 13)
	_expect("replacement supersedes previous demand", _daily(ext, good) == 50)
	var unfunded: Object = _new_runtime(compiled, catalog, profile, 281109, false)
	var unfunded_country := int(unfunded.get_country_cell_summary(0).country_handle)
	_expect("unfunded policy disables research", _disable_research(unfunded, unfunded_country))
	_expect("unfunded forecast queues", _demand(unfunded, unfunded_country, good, 1000, 0, 100))
	_finish_day(unfunded, 0)
	_expect("empty treasury cannot promise military purchasing power", _daily(unfunded, good) == 0)
	_test_production_response(compiled, catalog, profile, good)
	# Check the real military planner as well as the Economy consumer above.
	var native: Dictionary = ext.runtime_military_self_test()
	_expect("native zero-stock military planner and existing military regressions", bool(native.get("ok", false)))
	if not bool(native.get("ok", false)): print(native)

func _daily(ext: Object, good: int) -> int:
	return int(ext.get_market_cell_snapshot(0).military_demand_daily[good])

func _test_production_response(compiled: Dictionary, catalog: Dictionary, profile: Dictionary, good: int) -> void:
	var worlds: Array[Object] = []
	var totals := [0, 0]
	var signatures: PackedStringArray = catalog.signature_keys
	var hunter := signatures.find("hunter|default")
	var merchant := signatures.find("merchant|default")
	var building := (catalog.building_type_ids as PackedStringArray).find("bowyer_camp")
	for variant in range(2):
		var ext: Object = _new_ext(compiled)
		_expect("bowyer country configures", CountryTestHelper.configure_all_technologies(ext, catalog, CELL_COUNT, 281110))
		_expect("bowyer economy configures", bool(ext.configure_economy(catalog, profile, CELL_COUNT, 281110).get("ok", false)))
		_expect("bowyer cadence is fixed", preload("res://tests/runtime/replay_cadence.gd").install(ext))
		var stock := PackedInt64Array()
		var goods := (catalog.good_ids as PackedStringArray).size()
		stock.resize(CELL_COUNT * goods)
		stock.fill(100000000)
		for cell in range(CELL_COUNT): stock[cell * goods + good] = 0
		_expect("bowyer starts supplied with no bows", bool(ext.bootstrap_economy({
			"cell_indices": PackedInt32Array([0, 0]),
			"signature_ids": PackedInt32Array([hunter, merchant]),
			"population": PackedInt64Array([1, 1]),
			"funds": PackedInt64Array([1000000000, 10000000000]),
		}, {
			"stock": stock, "building_cells": PackedInt32Array([0]),
			"building_type_ids": PackedInt32Array([building]),
			"building_owner_signature_ids": PackedInt32Array([hunter]),
			"building_counts": PackedInt64Array([1]),
		}).get("ok", false)))
		var country := int(ext.get_country_cell_summary(0).country_handle)
		_expect("bowyer research is disabled", _disable_research(ext, country))
		var pop: Dictionary = ext.get_population_cell_snapshot(0)
		_expect("both bowyer fixtures fund identical treasuries", _transfer_from_cohort(ext, pop.handles[1], 500000000, 0, 1))
		if variant == 1:
			_expect("military order reaches bowyer market", _demand(ext, country, good, 1000000, 0, 100))
		worlds.append(ext)
	for day in range(5):
		for variant in range(2):
			_finish_day(worlds[variant], day)
			var snapshot: Dictionary = worlds[variant].get_building_cell_snapshot(0)
			var group := (snapshot.group_type_ids as PackedInt32Array).find(building)
			if group >= 0: totals[variant] += int(snapshot.last_output[group])
	print("MILITARY_PRODUCTION_OUTPUT=", totals)
	_expect("military demand raises actual bow production above identical control", totals[1] > totals[0] and totals[1] > 0)

func _demand(ext: Object, country: int, good: int, quantity: int, day: int, sequence: int) -> bool:
	var batch := {
		"opcodes": PackedInt32Array([36]), "effective_days": PackedInt64Array([day]),
		"sequences": PackedInt64Array([sequence]), "target_handles": PackedInt64Array([0]),
		"i32_0": PackedInt32Array([-1]), "i32_1": PackedInt32Array([-1]),
		"i64_0": PackedInt64Array([0]), "i64_1": PackedInt64Array([0]),
	}
	if quantity > 0:
		batch.opcodes.append(36)
		batch.effective_days.append(day)
		batch.sequences.append(sequence + 1)
		batch.target_handles.append(country)
		batch.i32_0.append(0)
		batch.i32_1.append(good)
		batch.i64_0.append(quantity)
		batch.i64_1.append(10)
	return bool(ext.submit_economy_commands(batch).get("ok", false))
