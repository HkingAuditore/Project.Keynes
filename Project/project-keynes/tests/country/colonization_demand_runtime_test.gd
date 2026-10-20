extends "res://tests/family/family_colonization_runtime_test.gd"

func _init() -> void:
	var compiled: Dictionary = EconomyCatalogScript.compile_native_catalog()
	_expect("economy catalog compiles", bool(compiled.get("ok", false)))
	if not bool(compiled.get("ok", false)):
		quit(1)
		return
	compiled.erase("ok")
	if OS.get_cmdline_user_args().has("--completion-only"):
		_completion_case(compiled)
		print("=== colonization demand completion: %d failures ===" % _failures)
		quit(0 if _failures == 0 else 1)
		return
	var reference := _demand_case(compiled.duplicate(true), false, 1000000000000)
	var funded := _demand_case(compiled.duplicate(true), true, 1000000000000)
	var poor := _demand_case(compiled.duplicate(true), true, 100)
	var empty := _demand_case(compiled.duplicate(true), true, 0)
	var multiple := _demand_case(compiled.duplicate(true), true, 100, true)
	var parallel := _demand_case(compiled.duplicate(true), true, 1000000000000, false, 4)
	var goods: PackedStringArray = compiled.good_ids
	var logs := goods.find("logs")
	_expect("zero-stock construction demand raises price pressure",
		_value(funded.market, "price_pressure_total_q16", logs) > _value(reference.market, "price_pressure_total_q16", logs))
	_expect("zero-stock construction demand raises merchant inventory target",
		_value(funded.market, "merchant_inventory_target", logs) > _value(reference.market, "merchant_inventory_target", logs))
	_expect("zero-stock construction demand creates an import target",
		_value(funded.market, "trade_import_fill_target", logs) > _value(reference.market, "trade_import_fill_target", logs))
	_expect("zero treasury does not create effective procurement demand",
		_sum_lane(empty.market, "colonization_pending_demand") == 0)
	# Prices can change after the frozen budget was quoted. The fixture records
	# the frozen opening price separately for an exact affordability check.
	_expect("national forecast shares one capped cash budget", int(poor.get("opening_cost", 101)) <= 100)
	_expect("multiple expeditions cannot duplicate their national cash budget",
		int(multiple.get("opening_cost", 101)) <= 100 and _sum_lane(multiple.market, "colonization_pending_demand") > 0)
	_expect("scalar and worker-task forecasts and state hashes agree",
		funded.market.colonization_pending_demand == parallel.market.colonization_pending_demand
		and int(funded.ext.get_economy_state_hash()) == int(parallel.ext.get_economy_state_hash()))
	print("[colonization-demand/parity] scalar=", funded.ext.get_economy_state_hash(),
		" worker=", parallel.ext.get_economy_state_hash(), " demand_equal=",
		funded.market.colonization_pending_demand == parallel.market.colonization_pending_demand)
	for key in funded.market:
		if funded.market[key] != parallel.market.get(key):
			print("[colonization-demand/market-diff] ", key)
	print("[colonization-demand/country-parity] ", funded.ext.get_country_state_hash(), " / ", parallel.ext.get_country_state_hash())
	var food_signals := 0
	for good in _food_good_indices(compiled):
		if _value(funded.market, "colonization_pending_demand", good) > 0:
			food_signals += 1
	_expect("food alternatives carry one shared requirement, not one per substitute", food_signals == 1)
	_expect("unfilled procurement does not invent realized withdrawals",
		_value(funded.market, "realized_withdrawal_ema", logs) == 0)
	_expect("funded shortage has a positive finite backlog",
		_sum_lane(funded.market, "colonization_pending_demand") > 0)
	_expect("backlog is normalized rather than repeated as daily flow",
		_sum_lane(funded.market, "colonization_demand_daily") > 0 and
		_sum_lane(funded.market, "colonization_demand_daily") < _sum_lane(funded.market, "colonization_pending_demand"))
	var ext: Object = funded.ext
	var country := int(funded.country)
	var cancelled: Dictionary = ext.cancel_family_colonization(country, int(funded.handle), 2, 281017)
	_expect("preparation cancellation is accepted", bool(cancelled.get("ok", false)))
	for day in range(2, 5):
		_run_day(ext, day)
	var after: Dictionary = ext.get_market_cell_snapshot(0)
	_expect("cancelled preparation leaves no phantom procurement demand",
		_sum_lane(after, "colonization_pending_demand") == 0)
	var report: Dictionary = ext.get_economy_report()
	_expect("forecast and cancellation preserve all ledgers", not bool(report.get("fatal", false))
		and int(report.get("population_error", -1)) == 0 and int(report.get("money_error", -1)) == 0
		and int(report.get("goods_error", -1)) == 0)
	_completion_case(compiled.duplicate(true))
	print("=== colonization demand runtime: %d failures ===" % _failures)
	quit(0 if _failures == 0 else 1)

func _completion_case(catalog: Dictionary) -> void:
	# Keep normal recipes and make the source's food output abundant. No stock
	# injection command: real production must replenish the market, then real
	# Country purchases must fill custody and retire the one-shot demand.
	var building := (catalog.building_type_ids as PackedStringArray).find("gathering_ground")
	var offsets: PackedInt32Array = catalog.building_output_offsets
	var quantities: PackedInt64Array = catalog.building_output_quantities
	for output in range(offsets[building], offsets[building + 1]):
		quantities[output] = 1000000
	catalog.building_output_quantities = quantities
	var no_food := {}
	for good in _food_good_indices(catalog):
		no_food[String((catalog.good_ids as PackedStringArray)[good])] = 0
	var fixture := _make_fixture(catalog, 271019, 1000000, no_food, PackedStringArray(), 1,
		1000000000000, {"market_cycle_days": 1})
	var ext: Object = fixture.ext
	var country := int(fixture.country_handle)
	var soil := (catalog.building_resource_ids as PackedStringArray).find("fertile_soil")
	var soil_slot := int(ext.component_id(StringName(
		(catalog.building_resource_reserve_slots as PackedStringArray)[soil])))
	ext.write_f32_range(soil_slot, 0, PackedFloat32Array([1000000000.0, 1000000000.0, 1000000000.0]))
	var families: Dictionary = ext.get_family_cell_snapshot(0, 0, 64)
	var family := int((families.family_handles as PackedInt64Array)[0])
	var quotes: Dictionary = ext.get_family_colonization_quotes(country, 2, family, 0, 0, 64)
	var started: Dictionary = ext.start_family_colonization(country, family, 0, 2, 3,
		int((quotes.quote_tokens as PackedInt64Array)[0]), 0, 271019)
	_expect("completion fixture begins with genuinely missing food",
		bool(started.get("ok", false)) and String(started.get("code", "")) == "colonization_preparing")
	_run_day(ext, 1)
	var waiting: Dictionary = ext.get_market_cell_snapshot(0)
	_expect("unbought food creates demand before the producer has supplied it",
		_sum_lane(waiting, "colonization_pending_demand") > 0)
	_expect("already purchased construction custody is not requested a second time",
		_value(waiting, "colonization_pending_demand", (catalog.good_ids as PackedStringArray).find("logs")) == 0)
	for day in range(2, 5):
		_run_day(ext, day)
	var snap: Dictionary = ext.get_family_expedition_snapshot(country, int(started.get("expedition_handle", 0)))
	if int(snap.get("state", 4)) == 4:
		print("[colonization-demand/completion] expedition=", snap)
		print("[colonization-demand/completion] building=", ext.get_building_cell_snapshot(0))
	_expect("real production and purchases let the preparing expedition depart",
		bool(snap.get("ok", false)) and int(snap.get("state", 4)) != 4
		and not (snap.get("cargo_good_ids", PackedInt32Array()) as PackedInt32Array).is_empty())
	_expect("completed procurement retires its demand instead of repeating the whole kit",
		_sum_lane(ext.get_market_cell_snapshot(0), "colonization_pending_demand") == 0)
	var report: Dictionary = ext.get_economy_report()
	_expect("production-funded departure conserves population, cash and goods",
		not bool(report.get("fatal", false)) and int(report.get("population_error", -1)) == 0
		and int(report.get("money_error", -1)) == 0 and int(report.get("goods_error", -1)) == 0)

func _demand_case(catalog: Dictionary, dispatch: bool, cash: int,
		second: bool = false, workers: int = 1) -> Dictionary:
	var fixture := _make_fixture(catalog, 271017, 0, {}, PackedStringArray(), 1, cash,
		{"market_cycle_days": 1, "worker_tasks_hint": workers})
	var ext: Object = fixture.ext
	var country := int(fixture.country_handle)
	var opening: Dictionary = ext.get_market_cell_snapshot(0)
	var handle := 0
	if dispatch:
		var families: Dictionary = ext.get_family_cell_snapshot(0, 0, 64)
		var family := int((families.family_handles as PackedInt64Array)[0])
		var quotes: Dictionary = ext.get_family_colonization_quotes(country, 2, family, 0, 0, 64)
		var token := int((quotes.quote_tokens as PackedInt64Array)[0])
		var started: Dictionary = ext.start_family_colonization(country, family, 0, 2, 3, token, 0, 271017)
		_expect("empty source starts as a preparing expedition", bool(started.get("ok", false))
			and String(started.get("code", "")) == "colonization_preparing")
		handle = int(started.get("expedition_handle", 0))
		if second:
			var second_quotes: Dictionary = ext.get_family_colonization_quotes(country, 1, family, 0, 0, 64)
			var second_token := int((second_quotes.quote_tokens as PackedInt64Array)[0])
			var second_start: Dictionary = ext.start_family_colonization(country, family, 0, 1, 3, second_token, 0, 271018)
			_expect("second expedition occupies a separate target", bool(second_start.get("ok", false)))
	_run_day(ext, 1)
	var market: Dictionary = ext.get_market_cell_snapshot(0)
	var cost := 0
	for good in range((catalog.good_ids as PackedStringArray).size()):
		cost += _value(market, "colonization_pending_demand", good) * _value(opening, "price", good) / 1000
	return {"fixture": fixture, "ext": ext, "country": country, "handle": handle, "market": market, "opening_cost": cost}

func _value(snap: Dictionary, key: String, good: int) -> int:
	var values = snap.get(key, PackedInt64Array())
	return int(values[good]) if good >= 0 and good < values.size() else 0

func _food_good_indices(catalog: Dictionary) -> PackedInt32Array:
	var result := PackedInt32Array()
	for need in ["staple_food", "protein", "produce"]:
		var stable := (catalog.need_ids as PackedStringArray).find(need)
		for good in EconomyCatalogScript._carrying_need_goods(stable, catalog):
			if not result.has(good):
				result.append(good)
	return result

func _sum_lane(snap: Dictionary, key: String) -> int:
	var total := 0
	for qty in snap.get(key, PackedInt64Array()):
		total += int(qty)
	return total
