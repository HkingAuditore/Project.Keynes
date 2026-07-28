extends SceneTree

# Opt-in Market V2 benchmark:
#   godot --headless --path . --script res://tests/economy_runtime_bench.gd
#   godot --headless --path . --script res://tests/economy_runtime_bench.gd -- --desktop
#   godot --headless --path . --script res://tests/economy_runtime_bench.gd -- --fixed5

func _init() -> void:
	var args := OS.get_cmdline_user_args()
	var snapshot_only := "--snapshot" in args
	var desktop := "--desktop" in args
	var fixed_five := "--fixed5" in args
	var trade_active := "--trade-active" in args
	var csv_record := "--csv-record" in args
	var csv_shape := csv_record or "--csv-shape" in args
	var cells := 1120 if csv_shape else (1 if snapshot_only else (100000 if desktop else 10000))
	var cohorts_per_cell := 4 if csv_shape else (100 if snapshot_only or desktop else 20)
	var goods := 124 if csv_shape else (200 if snapshot_only or desktop else 100)
	var epochs := 30 if csv_shape else (0 if snapshot_only else (2 if desktop else (70 if trade_active else 50)))
	var ext: Object = _new_ext(cells)
	var catalog := _synthetic_catalog(goods, cohorts_per_cell)
	var profile := {
		"money_scale": 10000, "goods_scale": 1000, "ratio_scale": 65536,
		"rate_scale": 4294967296, "cells_per_slice": 5000,
		"commands_per_slice": 16384, "max_rules_per_plan": 32,
		"market_cycle_days": 5 if fixed_five else 0, "market_max_cycle_days": 365,
		"market_target_cohorts_per_slice": 30000 if desktop else 4000,
		"worker_enabled": true, "worker_market_threshold": 64,
		"worker_tasks_hint": 8 if "--tasks8" in args else 0,
		"merchant_market_making_days_q16": 3932160,
		"merchant_profession_id": "merchant", "wealth_reference_per_capita": 100000,
		"living_cost_base_plan_id": "plan",
		"market_runtime_mode": "ACTIVE",
		# Baseline benchmark exercises the legacy-equivalent OFF gate; opt-in trade
		# runs use the production deterministic work-unit defaults.
		"trade_runtime_mode": "ACTIVE" if trade_active else "OFF",
		"trade_capacity_per_merchant_q16": 4194304,
		"trade_speed_cost_per_day": 4,
		"trade_min_margin_q16": 0,
		"trade_target_count": 4,
		"trade_signal_pairs_per_slice": 16384,
		"trade_route_searches_per_slice": 2,
		"trade_max_route_expansions": 8192,
		"trade_route_cache_entries": 16384,
		"trade_max_signals": 32768,
		"trade_max_candidates": 8192,
		"trade_max_orders": 4096,
		"economy_trace_mode": "OFF" if "--trace-off" in args else "SELECTIVE",
	}
	if trade_active:
		var country_setup := _setup_trade_country(ext, catalog, cells, 20260711)
		if not bool(country_setup.get("ok", false)):
			printerr(country_setup)
			quit(8)
			return
	var configured: Dictionary = ext.configure_economy(catalog, profile, cells, 20260711)
	if not bool(configured.get("ok", false)):
		printerr(configured)
		quit(3)
		return
	if trade_active:
		var topology := _capture_trade_line_topology(ext, cells)
		if not bool(topology.get("ok", false)):
			printerr(topology)
			quit(9)
			return
	var stock := PackedInt64Array()
	stock.resize(cells * goods)
	stock.fill(0 if trade_active else 1000000000)
	var market_packet := {"stock": stock}
	if trade_active:
		var prices := PackedInt32Array()
		prices.resize(cells * goods)
		var defaults := catalog.good_default_price as PackedInt32Array
		var minimums := catalog.good_min_price as PackedInt32Array
		var maximums := catalog.good_max_price as PackedInt32Array
		for cell in range(cells):
			var source := (cell & 1) == 0
			var base := cell * goods
			for good in range(goods):
				stock[base + good] = 1000000000 if source else 0
				prices[base + good] = minimums[good] if source else maximums[good]
		market_packet.price = prices
	var boot: Dictionary = ext.bootstrap_economy(
		_population_packet(cells, cohorts_per_cell), market_packet)
	if not bool(boot.get("ok", false)):
		printerr(boot)
		quit(4)
		return
	var csv_paths := {}
	if csv_record:
		var q := PackedInt32Array()
		var r := PackedInt32Array()
		var s := PackedInt32Array()
		q.resize(cells); r.resize(cells); s.resize(cells)
		for cell in range(cells):
			q[cell] = cell
			r[cell] = 0
			s[cell] = -cell
		var csv_dir := ProjectSettings.globalize_path("user://economy_csv_bench")
		DirAccess.make_dir_recursive_absolute(csv_dir)
		for dim in ["summary", "cohorts", "buildings", "resources", "market"]:
			csv_paths[dim] = csv_dir.path_join("bench_v2_%s.csv" % dim)
		var csv_start: Dictionary = ext.start_economy_csv_recording({
			"record_summary": true, "record_cohorts": true,
			"record_buildings": true, "record_resources": true,
			"record_market": true, "cell_stride": 1, "max_rows": 5_000_000,
			"q_arr": q, "r_arr": r, "s_arr": s,
			"resource_slot_ids": PackedInt32Array(),
			"resource_ids": PackedStringArray(), "paths": csv_paths,
		})
		if not bool(csv_start.get("ok", false)):
			printerr("CSV benchmark start failed: ", csv_start)
			quit(10)
			return
	if "--trace-cell" in args:
		ext.set_economy_trace_filter({"cells": PackedInt32Array([0])})
	if snapshot_only:
		var hash_before: int = ext.get_economy_state_hash()
		var samples := PackedFloat64Array()
		for warmup in range(20):
			ext.get_population_cell_snapshot(0)
		for sample in range(500):
			var t0 := Time.get_ticks_usec()
			var snapshot: Dictionary = ext.get_population_cell_snapshot(0)
			samples.append(float(Time.get_ticks_usec() - t0) / 1000.0)
			if (snapshot.get("demand_good_offsets", PackedInt32Array()) as PackedInt32Array).size() != cohorts_per_cell + 1:
				printerr("snapshot CSR mismatch")
				quit(6)
				return
		samples.sort()
		var p95 := samples[clampi(int(ceil(samples.size() * 0.95)) - 1, 0, samples.size() - 1)]
		print("[economy_snapshot_bench] cohorts=%d goods=%d samples=%d avg=%.3fms p95=%.3fms max=%.3fms hash_unchanged=%s" % [
			cohorts_per_cell, goods, samples.size(), _mean(samples), p95,
			samples[samples.size() - 1], str(hash_before == ext.get_economy_state_hash())])
		quit(0 if p95 <= 1.0 and hash_before == ext.get_economy_state_hash() else 7)
		return
	var cycle_days := int(boot.get("market_cycle_days", boot.get("epoch_days", 1)))
	var slice_ms := PackedFloat64Array()
	var call_wall_ms := PackedFloat64Array()
	var trade_slice_ms := PackedFloat64Array()
	var trade_core_ms := PackedFloat64Array()
	var day := 0
	for epoch in range(epochs):
		_set_environment(ext, cells, 0.25 + float(epoch & 1) * 0.5)
		for cycle_day in range(cycle_days):
			var call_started := Time.get_ticks_usec()
			var result: Dictionary = ext.run_economy_slice({"day_index": day, "tick_index": day})
			call_wall_ms.append(float(Time.get_ticks_usec() - call_started) / 1000.0)
			var trade_delta := float(result.get("trade_plan_ms", 0.0))
			if trade_delta > 0.0:
				trade_slice_ms.append(float(result.get("elapsed_ms", 0.0)))
				trade_core_ms.append(trade_delta)
			if bool(result.get("cell_range_used", false)):
				slice_ms.append(float(result.get("elapsed_ms", 0.0)))
				if float(result.get("elapsed_ms", 0.0)) > 10.0:
					print("[market_v2_spike] day=%d ms=%.3f cursor=%d..%d workers=%d" % [day,
						float(result.get("elapsed_ms", 0.0)), int(result.get("cursor_start", 0)),
						int(result.get("cursor_end", 0)), int(result.get("worker_tasks", 1))])
			var catchup := 0
			while not bool(result.get("done", false)) and bool(result.get("commit_due", false)):
				catchup += 1
				call_started = Time.get_ticks_usec()
				result = ext.run_economy_slice({"day_index": day, "tick_index": day * 1024 + catchup})
				call_wall_ms.append(float(Time.get_ticks_usec() - call_started) / 1000.0)
				trade_delta = float(result.get("trade_plan_ms", 0.0))
				if trade_delta > 0.0:
					trade_slice_ms.append(float(result.get("elapsed_ms", 0.0)))
					trade_core_ms.append(trade_delta)
				if bool(result.get("cell_range_used", false)):
					slice_ms.append(float(result.get("elapsed_ms", 0.0)))
					if float(result.get("elapsed_ms", 0.0)) > 10.0:
						print("[market_v2_spike] day=%d catchup=%d ms=%.3f cursor=%d..%d workers=%d" % [
							day, catchup, float(result.get("elapsed_ms", 0.0)),
							int(result.get("cursor_start", 0)), int(result.get("cursor_end", 0)),
							int(result.get("worker_tasks", 1))])
				if catchup > cycle_days + 64:
					printerr("cycle catchup did not converge: ", result)
					quit(5)
					return
			day += 1
			if csv_record:
				# 100x-equivalent pacing gives the writer realistic time between
				# five-day commits while still stressing sustained throughput.
				OS.delay_msec(10)
	slice_ms.sort()
	call_wall_ms.sort()
	var p95_idx := clampi(int(ceil(float(slice_ms.size()) * 0.95)) - 1, 0, slice_ms.size() - 1)
	var wall_p95_idx := clampi(int(ceil(float(call_wall_ms.size()) * 0.95)) - 1, 0,
		call_wall_ms.size() - 1)
	var report: Dictionary = ext.get_economy_report()
	print("[market_v2_bench] profile=%s cells=%d cohorts=%d goods=%d components=16 cycle_days=%d samples=%d avg=%.3fms p95=%.3fms max=%.3fms worker_tasks=%d memory=%.1fMB hash=%d" % [
		"desktop" if desktop else "mobile", cells, cells * cohorts_per_cell, goods,
		cycle_days, slice_ms.size(), _mean(slice_ms), slice_ms[p95_idx], slice_ms[slice_ms.size() - 1],
		int(report.get("worker_tasks", 1)), float(report.get("memory_bytes", 0)) / 1048576.0,
		ext.get_economy_state_hash(),
	])
	print("[market_v2_wall] samples=%d avg=%.3fms p95=%.3fms max=%.3fms" % [
		call_wall_ms.size(), _mean(call_wall_ms), call_wall_ms[wall_p95_idx], call_wall_ms[-1],
	])
	print("[market_v2_stages] demand=%.3fms clear=%.3fms fallback=%.3fms merchant=%.3fms price=%.3fms" % [
		float(report.get("formula_ms", 0.0)), float(report.get("clear_ms", 0.0)),
		float(report.get("fallback_ms", 0.0)), float(report.get("merchant_settle_ms", 0.0)),
		float(report.get("price_ms", 0.0)),
	])
	print("[market_v2_events] mode=%s summary=%.3fms detail=%.3fms publish=%.3fms memory=%.1fMB events=%d" % [
		"OFF" if "--trace-off" in args else "SELECTIVE",
		float(report.get("event_summary_ms", 0.0)), float(report.get("event_detail_ms", 0.0)),
		float(report.get("event_publish_ms", 0.0)),
		float(report.get("economy_trace_memory_bytes", 0)) / 1048576.0,
		int(report.get("economy_event_last_batch_count", 0)),
	])
	if trade_active:
		trade_slice_ms.sort()
		trade_core_ms.sort()
		var trade_p95 := 0.0 if trade_slice_ms.is_empty() else trade_slice_ms[
			clampi(int(ceil(float(trade_slice_ms.size()) * 0.95)) - 1, 0,
				trade_slice_ms.size() - 1)]
		var trade_max := 0.0 if trade_slice_ms.is_empty() else trade_slice_ms[-1]
		var core_p95 := 0.0 if trade_core_ms.is_empty() else trade_core_ms[
			clampi(int(ceil(float(trade_core_ms.size()) * 0.95)) - 1, 0,
				trade_core_ms.size() - 1)]
		var core_max := 0.0 if trade_core_ms.is_empty() else trade_core_ms[-1]
		print("[trade_v1_bench] cells=%d goods=%d samples=%d slice_avg=%.3fms slice_p95=%.3fms slice_max=%.3fms core_avg=%.3fms core_p95=%.3fms core_max=%.3fms expansions=%d cache=%d/%d signals=%d/%d candidates=%d accepted=%d orders=%d memory=%.1fMB" % [
			cells, goods, trade_slice_ms.size(), _mean(trade_slice_ms), trade_p95,
			trade_max, _mean(trade_core_ms), core_p95, core_max,
			int(report.get("trade_route_expansions", 0)),
			int(report.get("trade_route_cache_hits", 0)),
			int(report.get("trade_route_cache_misses", 0)),
			int(report.get("trade_source_signals", 0)),
			int(report.get("trade_destination_signals", 0)),
			int(report.get("trade_candidates_generated", 0)),
			int(report.get("trade_candidates_accepted", 0)),
			int(report.get("trade_orders_in_flight", 0)),
			float(report.get("memory_bytes", 0)) / 1048576.0,
		])
	if csv_record:
		ext.request_stop_economy_csv_recording()
		var csv_status: Dictionary = ext.get_economy_csv_recording_status()
		var csv_deadline := Time.get_ticks_msec() + 30000
		while str(csv_status.get("state", "")) == "draining" and Time.get_ticks_msec() < csv_deadline:
			OS.delay_msec(1)
			csv_status = ext.get_economy_csv_recording_status()
		print("[economy_csv_bench] cells=%d cohorts=%d goods=%d captured=%d written=%d rows=%d bytes=%.1fMB buffers=%.1fMB capture_last=%.3fms capture_p95=%.3fms capture_max=%.3fms encode_last=%.3fms write_last=%.3fms state=%s error=%s" % [
			cells, cells * cohorts_per_cell, goods,
			int(csv_status.get("captured_epochs", 0)), int(csv_status.get("written_epochs", 0)),
			int(csv_status.get("written_rows", 0)), float(csv_status.get("bytes_written", 0)) / 1048576.0,
			float(csv_status.get("buffer_memory_bytes", 0)) / 1048576.0,
			float(csv_status.get("capture_ms_last", 0.0)), float(csv_status.get("capture_ms_p95", 0.0)),
			float(csv_status.get("capture_ms_max", 0.0)),
			float(csv_status.get("worker_encode_ms_last", 0.0)),
			float(csv_status.get("worker_write_ms_last", 0.0)), str(csv_status.get("state", "")),
			str(csv_status.get("error_code", "")),
		])
		for path in csv_paths.values():
			DirAccess.remove_absolute(str(path))
	quit(0)

func _setup_trade_country(ext: Object, catalog: Dictionary, cells: int, seed: int) -> Dictionary:
	var configured: Dictionary = ext.configure_country(catalog, {
		"country_runtime_mode": "ACTIVE",
		"starting_technology_ids": PackedStringArray(),
	}, cells, seed)
	if not bool(configured.get("ok", false)):
		return configured
	var territory := PackedInt32Array()
	territory.resize(cells)
	for cell in range(cells):
		territory[cell] = cell
	var water := PackedByteArray()
	water.resize(cells)
	water.fill(0)
	return ext.bootstrap_country({
		"country_ids": PackedStringArray(["country.benchmark"]),
		"country_names": PackedStringArray(["Benchmark"]),
		"country_cash": PackedInt64Array([0]),
		"territory_offsets": PackedInt32Array([0, cells]),
		"territory_cells": territory,
		"technology_offsets": PackedInt32Array([0, 0]),
		"technology_indices": PackedInt32Array(),
		"treasury_offsets": PackedInt32Array([0, 0]),
		"treasury_good_indices": PackedInt32Array(),
		"treasury_quantities": PackedInt64Array(),
	}, water)

func _capture_trade_line_topology(ext: Object, cells: int) -> Dictionary:
	var neighbors := PackedInt32Array()
	neighbors.resize(cells * 6)
	neighbors.fill(-1)
	for cell in range(cells - 1):
		neighbors[cell * 6] = cell + 1
		neighbors[(cell + 1) * 6 + 3] = cell
	var terrain := PackedByteArray()
	terrain.resize(cells)
	terrain.fill(2)
	var passable := PackedByteArray()
	var costs := PackedInt32Array()
	passable.resize(256)
	costs.resize(256)
	passable[2] = 1
	costs[2] = 1
	return ext.capture_economy_trade_topology(neighbors, terrain, passable, costs, 1)

func _new_ext(cells: int) -> Object:
	var ext: Object = ClassDB.instantiate("DCWorldExt")
	ext.create_entities(cells)
	for name in [&"cell_temp", &"cell_temp_30d", &"cell_moisture",
			&"cell_plant_available_water", &"cell_snow_cover", &"cell_weather_intensity"]:
		ext.register_component(name, 0, 1, false)
	_set_environment(ext, cells, 0.5)
	return ext

func _set_environment(ext: Object, cells: int, value: float) -> void:
	var values := PackedFloat32Array()
	values.resize(cells)
	values.fill(value)
	for name in [&"cell_temp", &"cell_temp_30d", &"cell_moisture",
			&"cell_plant_available_water", &"cell_snow_cover", &"cell_weather_intensity"]:
		ext.write_f32_range(ext.component_id(name), 0, values)

func _synthetic_catalog(good_count: int, signatures: int) -> Dictionary:
	var profession_ids := PackedStringArray(["merchant"])
	for i in range(1, signatures):
		profession_ids.append("profession_%03d" % i)
	profession_ids.sort()
	var good_ids := PackedStringArray()
	var default_price := PackedInt32Array()
	var initial_stock := PackedInt64Array()
	var min_price := PackedInt32Array()
	var max_price := PackedInt32Array()
	var adjust := PackedInt32Array()
	var elasticity := PackedInt32Array()
	var ema := PackedInt32Array()
	var inventory_target_ratios := PackedInt32Array()
	var inventory_weight := PackedInt32Array()
	var shortage_weight := PackedInt32Array()
	var rise := PackedInt32Array()
	var fall := PackedInt32Array()
	var categories := PackedStringArray()
	var storage_modes := PackedInt32Array()
	var issue_values := PackedInt64Array()
	var technology_tag_offsets := PackedInt32Array([0])
	for good in range(good_count):
		good_ids.append("good_%03d" % good)
		default_price.append(10000 + good)
		initial_stock.append(0)
		min_price.append(1000)
		max_price.append(1000000)
		adjust.append(2048)
		elasticity.append(65536)
		ema.append(16384)
		inventory_target_ratios.append(65536)
		inventory_weight.append(32768)
		shortage_weight.append(65536)
		rise.append(8192)
		fall.append(4096)
		categories.append("bench")
		storage_modes.append(0)
		issue_values.append(0)
		technology_tag_offsets.append(0)
	var need_ids := PackedStringArray()
	var need_stable := PackedInt32Array()
	var priorities := PackedInt32Array()
	var base_qty := PackedInt64Array()
	var wealth_elasticity := PackedInt32Array()
	var wealth_min := PackedInt32Array()
	var wealth_max := PackedInt32Array()
	var price_quantity_elasticity := PackedInt32Array()
	var price_quantity_floor := PackedInt32Array()
	var need_env := PackedInt32Array()
	var need_variant_offsets := PackedInt32Array([0])
	var variant_preference := PackedInt32Array()
	var variant_elasticity := PackedInt32Array()
	var variant_env := PackedInt32Array()
	var variant_component_offsets := PackedInt32Array([0])
	var component_goods := PackedInt32Array()
	var component_qty := PackedInt64Array()
	var benchmark_need_ids := PackedStringArray([
		"clothing", "produce", "protein", "staple_food",
		"z_need_04", "z_need_05", "z_need_06", "z_need_07",
		"z_need_08", "z_need_09", "z_need_10", "z_need_11",
		"z_need_12", "z_need_13", "z_need_14", "z_need_15",
	])
	for need in range(16):
		need_ids.append(benchmark_need_ids[need])
		need_stable.append(need)
		priorities.append(need >> 2)
		base_qty.append(25 + need)
		wealth_elasticity.append(16384)
		wealth_min.append(32768)
		wealth_max.append(131072)
		price_quantity_elasticity.append(65536)
		price_quantity_floor.append(0)
		need_env.append(-1)
		need_variant_offsets.append(need + 1)
		variant_preference.append(65536)
		variant_elasticity.append(65536)
		variant_env.append(-1)
		variant_component_offsets.append(need + 1)
		component_goods.append(need % good_count)
		component_qty.append(1000)
	var sig_prof := PackedInt32Array()
	var sig_eth := PackedInt32Array()
	var sig_plan := PackedInt32Array()
	var birth := PackedInt64Array()
	var death := PackedInt64Array()
	var need_living_cost_weights := PackedInt32Array()
	need_living_cost_weights.resize(need_ids.size())
	need_living_cost_weights.fill(65536)
	var profession_technology_offsets := PackedInt32Array()
	profession_technology_offsets.resize(signatures + 1)
	profession_technology_offsets.fill(0)
	for i in range(signatures):
		sig_prof.append(i)
		sig_eth.append(0)
		sig_plan.append(0)
		birth.append(0)
		death.append(0)
	return {
		"profession_ids": profession_ids, "ethnicity_ids": PackedStringArray(["default"]),
		"technology_ids": PackedStringArray(),
		"profession_technology_tag_offsets": profession_technology_offsets,
		"profession_technology_tags": PackedStringArray(),
		"building_technology_tag_offsets": PackedInt32Array([0]),
		"building_technology_tags": PackedStringArray(),
		"good_ids": good_ids, "need_ids": need_ids, "plan_ids": PackedStringArray(["plan"]),
		"good_default_price": default_price, "good_initial_stock": initial_stock,
		"good_min_price": min_price, "good_max_price": max_price,
		"good_price_adjust_q16": adjust, "good_demand_price_elasticity_q16": elasticity,
		"good_demand_ema_alpha_q16": ema,
		"good_inventory_target_ratios_q16": inventory_target_ratios,
		"good_inventory_weight_q16": inventory_weight, "good_shortage_weight_q16": shortage_weight,
		"good_max_price_rise_q16": rise, "good_max_price_fall_q16": fall,
		"good_category_ids": categories, "good_storage_modes": storage_modes,
		"good_monetary_issue_values": issue_values,
		"good_technology_tag_offsets": technology_tag_offsets,
		"good_technology_tags": PackedStringArray(),
		"environment_curve_ids": PackedStringArray(), "environment_curve_signal_ids": PackedInt32Array(),
		"environment_curve_values_q16": PackedInt32Array(), "plan_need_offsets": PackedInt32Array([0, 16]),
		"need_stable_ids": need_stable, "need_priorities": priorities,
		"need_living_cost_weights_q16": need_living_cost_weights,
		"need_base_qty_per_person": base_qty, "need_wealth_elasticity_q16": wealth_elasticity,
		"need_wealth_min_q16": wealth_min, "need_wealth_max_q16": wealth_max,
		"need_price_quantity_elasticity_q16": price_quantity_elasticity,
		"need_price_quantity_floor_q16": price_quantity_floor,
		"need_quantity_env_curve_ids": need_env, "need_variant_offsets": need_variant_offsets,
		"variant_preference_q16": variant_preference, "variant_price_elasticity_q16": variant_elasticity,
		"variant_preference_env_curve_ids": variant_env, "variant_component_offsets": variant_component_offsets,
		"component_good_ids": component_goods, "component_qty_per_need": component_qty,
		"ethnicity_need_factor_q16": PackedInt32Array([65536,65536,65536,65536,65536,65536,65536,65536,65536,65536,65536,65536,65536,65536,65536,65536]),
		"signature_profession_ids": sig_prof, "signature_ethnicity_ids": sig_eth,
		"signature_plan_ids": sig_plan, "signature_birth_rate_q32": birth,
		"signature_death_rate_q32": death,
		"signature_satisfaction_birth_weight_q16": PackedInt64Array(),
		"catalog_hash": 2026071101 + good_count * 1000 + signatures,
	}

func _population_packet(cells: int, signatures: int) -> Dictionary:
	var count := cells * signatures
	var cell_indices := PackedInt32Array()
	var signature_ids := PackedInt32Array()
	var populations := PackedInt64Array()
	var funds := PackedInt64Array()
	cell_indices.resize(count)
	signature_ids.resize(count)
	populations.resize(count)
	funds.resize(count)
	var cursor := 0
	for cell in range(cells):
		for signature in range(signatures):
			cell_indices[cursor] = cell
			signature_ids[cursor] = signature
			populations[cursor] = 10
			funds[cursor] = 1000000
			cursor += 1
	return {"cell_indices": cell_indices, "signature_ids": signature_ids,
		"population": populations, "funds": funds}

func _mean(values: PackedFloat64Array) -> float:
	var total := 0.0
	for value in values:
		total += value
	return total / maxf(1.0, float(values.size()))
