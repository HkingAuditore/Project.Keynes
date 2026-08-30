extends "res://tests/goods_storage_schema_test.gd"

func _run() -> void:
	var cells := 64
	var days := 180
	var period := 1
	var scenario := "glut"
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("cells="): cells = int(arg.get_slice("=", 1))
		if arg.begins_with("days="): days = int(arg.get_slice("=", 1))
		if arg.begins_with("period="): period = int(arg.get_slice("=", 1))
		if arg.begins_with("scenario="): scenario = arg.get_slice("=", 1)
	var catalog := _without_natural_demography(EconomyCatalogScript.compile_native_catalog())
	var cap_key := "good_reference_max_price" if catalog.has("good_reference_max_price") else "good_max_price"
	if scenario == "active":
		catalog[cap_key] = (catalog.good_default_price as PackedInt32Array).duplicate()
	var ext: Object = _new_ext(cells, 0.5)
	if not CountryTestHelper.configure_all_technologies(ext, catalog, cells, 4801):
		_failures += 1
		return
	var profile := _native_profile(true, 8)
	profile.market_min_cycle_days = period
	profile.market_max_cycle_days = period
	profile.market_cycle_days = period
	profile.starvation_death_rate_q32 = 0
	profile.trade_runtime_mode = "OFF"
	profile.economy_trace_mode = "OFF"
	var result: Dictionary = ext.configure_economy(catalog, profile, cells, 4801)
	if not bool(result.get("ok", false)):
		_failures += 1
		printerr(result)
		return
	ext.inject_economy_cadence_timing(0.01, 0.01)
	var goods: PackedStringArray = catalog.good_ids
	var sigs: PackedStringArray = catalog.signature_keys
	var packet := {"cell_indices": PackedInt32Array(), "signature_ids": PackedInt32Array(),
		"population": PackedInt64Array(), "funds": PackedInt64Array()}
	var prices := PackedInt32Array()
	var stock := PackedInt64Array()
	prices.resize(cells * goods.size()); stock.resize(prices.size())
	for cell in range(cells):
		for job in ["worker|default", "merchant|default"]:
			packet.cell_indices.append(cell)
			packet.signature_ids.append(sigs.find(job))
			packet.population.append(10 if scenario == "low" else 100)
			packet.funds.append(1000 if scenario == "low" else 1000000000)
		for g in range(goods.size()):
			prices[cell * goods.size() + g] = 1 if scenario == "low" else int(catalog.good_default_price[g])
			if scenario == "near_cap": prices[cell * goods.size() + g] = int(catalog[cap_key][g]) * 9 / 10
			stock[cell * goods.size() + g] = 0 if int(catalog.good_storage_modes[g]) != 0 else (0 if scenario in ["near_cap", "active"] else (10000 if scenario == "scarce" else 100000000))
	result = ext.bootstrap_economy(packet, {"stock": stock, "price": prices})
	if not bool(result.get("ok", false)):
		_failures += 1
		printerr(result)
		return
	var wall := PackedFloat64Array()
	var price_cpu := PackedFloat64Array()
	var market_cpu := PackedFloat64Array()
	var processed_components := 0
	var total_consumed := 0
	var sat_sum := 0
	var last_epoch := -1
	for day in range(days):
		var started := Time.get_ticks_usec()
		result = _run_day(ext, day)
		var elapsed := float(Time.get_ticks_usec() - started) / 1000.0
		if not bool(result.get("done", false)) or bool(result.get("fatal", false)) or int(result.get("money_error", 1)) != 0 or int(result.get("goods_error", 1)) != 0:
			_failures += 1
			printerr(result)
			return
		if day >= 20:
			wall.append(elapsed)
			var epoch := int(result.get("last_completed_epoch_id", -1))
			if epoch != last_epoch:
				price_cpu.append(float(result.get("price_ms", 0)))
				market_cpu.append(float(result.get("last_completed_household_market_worker_ms", 0)))
				processed_components += int(result.get("processed_components", 0))
				last_epoch = epoch
	var final_prices := PackedInt32Array()
	var final_stock := PackedInt64Array()
	for cell in range(cells):
		var market: Dictionary = ext.get_market_cell_snapshot(cell)
		final_prices.append_array(market.price)
		final_stock.append_array(market.stock)
		var population: Dictionary = ext.get_population_cell_snapshot(cell)
		sat_sum += int(population.get("satisfaction_q16", 0))
	total_consumed = _sum_i64(stock) - _sum_i64(final_stock)
	var result_packet := {"cells": cells, "days": days, "scenario": scenario,
		"requested_period": period, "actual_period": result.get("locked_market_cycle_days", 0),
		"wall_ms": _stats(wall), "price_ms": _stats(price_cpu), "market_ms": _stats(market_cpu),
		"components": processed_components, "consumed": total_consumed,
		"satisfaction_sum": sat_sum, "memory_bytes": result.get("memory_bytes", 0),
		"prices": Array(final_prices.slice(0, goods.size())),
		"goods": Array(goods), "hash": str(ext.get_economy_state_hash()),
		"ceiling_states": result.get("price_ceiling_active_states", 0),
		"ceiling_state_bytes": result.get("price_ceiling_state_bytes", 0),
		"money_error": result.get("money_error"), "goods_error": result.get("goods_error")}
	print("PRICE_BENCH " + JSON.stringify(result_packet))

# The inherited regression helper advances five calendar days per call. A daily
# benchmark must visit every day and must complete all continuations before
# recording it; otherwise N=1/3/5 and large worlds are not comparable.
func _run_day(ext: Object, day: int) -> Dictionary:
	var report: Dictionary = {}
	for slice in range(65536):
		report = ext.run_economy_slice({"day_index": day, "tick_index": slice})
		if bool(report.get("done", false)) or bool(report.get("fatal", false)):
			return report
	return report

func _stats(values: PackedFloat64Array) -> Dictionary:
	if values.is_empty(): return {"avg": 0, "p95": 0, "max": 0, "n": 0}
	values.sort()
	var total := 0.0
	for value in values: total += value
	return {"avg": total / values.size(), "p95": values[clampi(int(ceil(values.size() * 0.95)) - 1, 0, values.size() - 1)],
		"max": values[-1], "n": values.size()}
