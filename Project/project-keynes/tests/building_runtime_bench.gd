extends SceneTree

const EconomyCatalogScript = preload("res://scripts/economy/economy_catalog.gd")
const CountryTestHelper = preload("res://tests/country_test_helper.gd")

func _init() -> void:
	var args := OS.get_cmdline_user_args()
	var cells := 10000
	for arg in args:
		if arg.begins_with("--cells="):
			cells = clampi(int(arg.trim_prefix("--cells=")), 1, 1000000)
	var catalog: Dictionary = EconomyCatalogScript.compile_native_catalog()
	if not bool(catalog.get("ok", false)):
		printerr(catalog)
		quit(2)
		return
	var ext := _new_ext(cells, catalog)
	var native_catalog := catalog.duplicate(true)
	native_catalog.erase("ok")
	if "--topology-rebuild" in args and not CountryTestHelper.configure_all_technologies(
			ext, native_catalog, cells, 20260711):
		printerr("country configure failed")
		quit(7)
		return
	var profile = load("res://data/economy/default_economy.tres").to_native_profile()
	profile.market_cycle_days = 0 if "--auto" in args else 5
	profile.market_runtime_mode = "ACTIVE"
	profile.worker_enabled = not "--scalar" in args
	profile.worker_market_threshold = 64
	if "--legacy-grain" in args:
		profile.building_plan_cells_per_slice = 256
		profile.household_post_building_cells_per_slice = 256
		profile.investment_cells_per_slice = 64
		profile.building_finalize_cells_per_slice = 64
	if "--no-investment" in args:
		profile.investment_review_days = 3650
	profile.economy_trace_mode = "OFF" if "--trace-off" in args else "SELECTIVE"
	if not bool(ext.configure_economy(native_catalog, profile, cells, 20260711).get("ok", false)):
		printerr("configure failed")
		quit(3)
		return
	var landlord_sig := (catalog.signature_keys as PackedStringArray).find("landlord|default")
	var worker_sig := (catalog.signature_keys as PackedStringArray).find("worker|default")
	var industrialist_sig := (catalog.signature_keys as PackedStringArray).find("industrialist|default")
	var miner_sig := (catalog.signature_keys as PackedStringArray).find("miner|default")
	var mine_id := (catalog.building_type_ids as PackedStringArray).find("coal_mine")
	var estate_id := (catalog.building_type_ids as PackedStringArray).find("landed_estate")
	var topology_rebuild := "--topology-rebuild" in args
	var pop_cells := PackedInt32Array()
	var signatures := PackedInt32Array()
	var populations := PackedInt64Array()
	var funds := PackedInt64Array()
	var building_cells := PackedInt32Array()
	var building_types := PackedInt32Array()
	var building_owners := PackedInt32Array()
	var building_counts := PackedInt64Array()
	for cell in range(cells):
		var owner_sig := landlord_sig if cell % 2 == 0 else industrialist_sig
		var employee_sig := worker_sig if cell % 2 == 0 else miner_sig
		pop_cells.append(cell); signatures.append(owner_sig); populations.append(2); funds.append(1000000)
		if topology_rebuild:
			pop_cells.append(cell)
			signatures.append(industrialist_sig if cell % 2 == 0 else landlord_sig)
			populations.append(2)
			funds.append(1000000000)
		pop_cells.append(cell); signatures.append(employee_sig); populations.append(30); funds.append(1000000)
		building_cells.append(cell); building_types.append(estate_id if cell % 2 == 0 else mine_id)
		building_owners.append(owner_sig); building_counts.append(1)
	var market_packet := {
		"building_cells": building_cells, "building_type_ids": building_types,
		"building_owner_signature_ids": building_owners, "building_counts": building_counts,
	}
	if topology_rebuild:
		var topology_stock := PackedInt64Array()
		topology_stock.resize(cells * (catalog.good_ids as PackedStringArray).size())
		topology_stock.fill(100000000)
		market_packet["stock"] = topology_stock
	var boot: Dictionary = ext.bootstrap_economy({
		"cell_indices": pop_cells, "signature_ids": signatures,
		"population": populations, "funds": funds,
	}, market_packet)
	if not bool(boot.get("ok", false)):
		printerr(boot)
		quit(4)
		return
	if topology_rebuild:
		var opcodes := PackedInt32Array()
		var effective_days := PackedInt64Array()
		var sequences := PackedInt64Array()
		var target_handles := PackedInt64Array()
		var command_cells := PackedInt32Array()
		var command_types := PackedInt32Array()
		var command_counts := PackedInt64Array()
		var command_unused := PackedInt64Array()
		for cell in range(cells):
			var target_signature := industrialist_sig if cell % 2 == 0 else landlord_sig
			var target_type := mine_id if cell % 2 == 0 else estate_id
			var snapshot: Dictionary = ext.get_population_cell_snapshot(cell)
			var owner_row := (snapshot.signature_ids as PackedInt32Array).find(
				target_signature)
			if owner_row < 0:
				continue
			opcodes.append(10)
			effective_days.append(0)
			sequences.append(cell + 1)
			target_handles.append(int((snapshot.handles as PackedInt64Array)[owner_row]))
			command_cells.append(cell)
			command_types.append(target_type)
			command_counts.append(1)
			command_unused.append(0)
		var submitted: Dictionary = ext.submit_economy_commands({
			"opcodes": opcodes,
			"effective_days": effective_days,
			"sequences": sequences,
			"target_handles": target_handles,
			"i32_0": command_cells,
			"i32_1": command_types,
			"i64_0": command_counts,
			"i64_1": command_unused,
		})
		if not bool(submitted.get("ok", false)):
			printerr(submitted)
			quit(6)
			return
	if "--trace-cell" in args:
		ext.set_economy_trace_filter({"cells": PackedInt32Array([0])})
	if "--inspector-cell" in args:
		ext.set_economy_inspector_trace_cell(0)
	var building_ms := PackedFloat64Array()
	var all_ms := PackedFloat64Array()
	var stage_wall_ms: Dictionary = {}
	var stage_max_ms: Dictionary = {}
	var substage_wall_ms: Dictionary = {}
	var substage_max_ms: Dictionary = {}
	var investment_slices: Array[Dictionary] = []
	var structure_peak: Dictionary = {}
	var report := {}
	var days := 25 if "--event-soak" in args else (
		int(boot.get("market_cycle_days", 5)) if "--auto" in args else 5)
	var barrier_slices := 0
	for day in range(days):
		report = ext.run_economy_slice({"day_index": day, "tick_index": day})
		_accumulate_stage_timing(report, stage_wall_ms, stage_max_ms,
			substage_wall_ms, substage_max_ms)
		_capture_investment_slice(day, report, investment_slices)
		_capture_structure_peak(report, structure_peak)
		all_ms.append(float(report.get("elapsed_ms", 0.0)))
		if bool(report.get("building_range_used", false)):
			building_ms.append(float(report.get("elapsed_ms", 0.0)))
		var catchup := 0
		while not bool(report.get("done", false)) and (
				bool(report.get("commit_due", false)) or
				bool(report.get("boundary_continuation_required", false))):
			catchup += 1
			barrier_slices += 1
			report = ext.run_economy_slice({"day_index": day, "tick_index": day * 1000 + catchup})
			_accumulate_stage_timing(report, stage_wall_ms, stage_max_ms,
				substage_wall_ms, substage_max_ms)
			_capture_investment_slice(day, report, investment_slices)
			_capture_structure_peak(report, structure_peak)
			all_ms.append(float(report.get("elapsed_ms", 0.0)))
			if bool(report.get("building_range_used", false)):
				building_ms.append(float(report.get("elapsed_ms", 0.0)))
	building_ms.sort()
	all_ms.sort()
	print("[building_bench] cells=%d groups=%d cohorts=%d building_slices=%d avg=%.3fms p95=%.3fms max=%.3fms all_p95=%.3fms all_max=%.3fms wage_plan=%.3fms labor_signal=%.3fms labor_edges=%d memory=%.1fMB hash=%d errors=%d/%d/%d discarded=%d unpaid=%d resource=%d/%d/%d extract_limited=%d capacity_checks=%d capacity_limited=%d" % [
		cells, int(report.get("building_group_count", 0)), int(report.get("cohort_count", 0)),
		building_ms.size(), _mean(building_ms), _p95(building_ms),
		building_ms[-1] if not building_ms.is_empty() else 0.0,
		_p95(all_ms),
		all_ms[-1] if not all_ms.is_empty() else 0.0,
		float(report.get("wage_plan_ms", 0.0)),
		float(report.get("labor_signal_ms", 0.0)),
		int(report.get("labor_signal_edges", 0)),
		float(report.get("memory_bytes", 0)) / 1048576.0, ext.get_economy_state_hash(),
		int(report.get("population_error", 1)), int(report.get("money_error", 1)),
		int(report.get("goods_error", 1)), int(report.get("production_output_discarded", 0)),
		int(report.get("building_wages_unpaid", 0)),
		int(report.get("building_resource_generated", 0)),
		int(report.get("building_resource_consumed", 0)),
		int(report.get("building_resource_net_delta", 0)),
		int(report.get("building_resource_limited_groups", 0)),
		int(report.get("building_resource_capacity_checks", 0)),
		int(report.get("building_resource_capacity_limited_groups", 0)),
	])
	print("[building_event_bench] mode=%s summary=%.3fms detail=%.3fms publish=%.3fms trace_memory=%.1fMB events=%d" % [
		"OFF" if "--trace-off" in args else "SELECTIVE",
		float(report.get("event_summary_ms", 0.0)), float(report.get("event_detail_ms", 0.0)),
		float(report.get("event_publish_ms", 0.0)),
		float(report.get("economy_trace_memory_bytes", 0)) / 1048576.0,
		int(report.get("economy_event_last_batch_count", 0)),
	])
	print("[building_cadence_bench] configured=%d effective=%d estimated=%d market=%d building=%d feasible=%s clamped=%s barrier_slices=%d" % [
		int(report.get("market_configured_cycle_days", -1)),
		int(report.get("market_cycle_days", -1)),
		int(report.get("estimated_total_slices_per_epoch", -1)),
		int(report.get("estimated_market_slices_per_epoch", -1)),
		int(report.get("estimated_building_slices_per_epoch", -1)),
		str(report.get("workload_deadline_feasible", false)),
		str(report.get("workload_cycle_clamped", false)), barrier_slices,
	])
	print("[building_stage_bench] epoch_begin=%.3fms preflight=%.3fms prepare=%.3fms audit=%.3fms watermark=%.3fms plan=%.3fms plan_evaluate=%.3fms plan_reserve=%.3fms employment=%.3fms production=%.3fms production_worker=%.3fms production_merge=%.3fms production_tasks=%d/%d investment=%.3fms signal_insert=%.3fms signal_flush=%.3fms signal_insert_count=%d formula=%.3fms clear=%.3fms price=%.3fms merchant=%.3fms market_worker=%.3fms market_tasks=%d market_merge=%.3fms market_aggregate=%.3fms market_trade=%.3fms market_allocation_growth=%d/%dB production_allocation_growth=%d/%dB trade_plan=%.3fms trade_dispatch=%.3fms publish=%.3fms signal_lookup=%s signal_entries=%d pending_index=%d processed_cells=%d processed_cohorts=%d groups=%d" % [
		float(report.get("epoch_begin_ms", 0.0)),
		float(report.get("epoch_preflight_ms", 0.0)),
		float(report.get("prepare_ms", 0.0)), float(report.get("audit_ms", 0.0)),
		float(report.get("watermark_ms", 0.0)),
		float(report.get("building_plan_ms", 0.0)),
		float(report.get("building_plan_evaluate_ms", 0.0)),
		float(report.get("building_plan_reserve_ms", 0.0)),
		float(report.get("building_employment_ms", 0.0)),
		float(report.get("building_production_ms", 0.0)),
		float(report.get("building_production_worker_ms", 0.0)),
		float(report.get("building_production_merge_ms", 0.0)),
		int(report.get("building_production_worker_tasks", 1)),
		int(report.get("building_production_worker_tasks_max", 1)),
		float(report.get("building_investment_ms", 0.0)),
		float(report.get("market_signal_insert_ms", 0.0)),
		float(report.get("market_signal_flush_ms", 0.0)),
		int(report.get("market_signal_insert_count", 0)),
		float(report.get("formula_ms", 0.0)), float(report.get("clear_ms", 0.0)),
		float(report.get("price_ms", 0.0)), float(report.get("merchant_settle_ms", 0.0)),
		float(report.get("household_market_worker_ms", 0.0)),
		int(report.get("market_worker_tasks_max", 1)),
		float(report.get("household_market_merge_ms", 0.0)),
		float(report.get("household_market_merge_aggregate_ms", 0.0)),
		float(report.get("household_market_merge_trade_ms", 0.0)),
		int(report.get("market_result_allocation_growth_count", 0)),
		int(report.get("market_result_allocation_growth_bytes", 0)),
		int(report.get("production_result_allocation_growth_count", 0)),
		int(report.get("production_result_allocation_growth_bytes", 0)),
		float(report.get("trade_plan_ms", 0.0)), float(report.get("trade_dispatch_ms", 0.0)),
		float(report.get("publish_ms", 0.0)), String(report.get("market_signal_lookup_mode", "csr")),
		int(report.get("market_signal_lookup_entries", 0)),
		int(report.get("pending_construction_index_entries", 0)),
		int(report.get("processed_cells", 0)),
		int(report.get("processed_cohorts", 0)), int(report.get("processed_building_groups", 0)),
	])
	print("[building_structure_bench] count_only=%d new=%d removed=%d topology_rebuilds=%d role_span_reuses=%d role_span_appends=%d group_merge=%.3fms market_cache=%.3fms labor_cache=%.3fms last_rejection=%s" % [
		int(structure_peak.get("building_structure_count_only_updates", 0)),
		int(structure_peak.get("building_structure_new_groups", 0)),
		int(structure_peak.get("building_structure_removed_groups", 0)),
		int(structure_peak.get("building_structure_topology_rebuilds", 0)),
		int(structure_peak.get("building_structure_role_span_reuses", 0)),
		int(structure_peak.get("building_structure_role_span_appends", 0)),
		float(structure_peak.get("building_structure_group_merge_ms", 0.0)),
		float(structure_peak.get("building_structure_market_cache_ms", 0.0)),
		float(structure_peak.get("building_structure_labor_cache_ms", 0.0)),
		String(structure_peak.get("last_building_rejection_reason", "")),
	])
	print("[building_slice_stages] wall=%s max=%s substage_wall=%s substage_max=%s" % [
		JSON.stringify(stage_wall_ms), JSON.stringify(stage_max_ms),
		JSON.stringify(substage_wall_ms), JSON.stringify(substage_max_ms)])
	investment_slices.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return float(a.elapsed_ms) > float(b.elapsed_ms))
	print("[building_investment_slices] %s" % JSON.stringify(
		investment_slices.slice(0, mini(12, investment_slices.size()))))
	quit(0 if int(report.get("population_error", 1)) == 0 and
		int(report.get("money_error", 1)) == 0 and int(report.get("goods_error", 1)) == 0 else 5)


func _accumulate_stage_timing(report: Dictionary, stage_wall: Dictionary,
		stage_max: Dictionary, substage_wall: Dictionary,
		substage_max: Dictionary) -> void:
	var elapsed := float(report.get("elapsed_ms", 0.0))
	var stage := String(report.get("executed_stage", ""))
	if not stage.is_empty():
		stage_wall[stage] = float(stage_wall.get(stage, 0.0)) + elapsed
		stage_max[stage] = maxf(float(stage_max.get(stage, 0.0)), elapsed)
	var substage := String(report.get("executed_substage", ""))
	if not stage.is_empty() and not substage.is_empty():
		var key := "%s.%s" % [stage, substage]
		substage_wall[key] = float(substage_wall.get(key, 0.0)) + elapsed
		substage_max[key] = maxf(float(substage_max.get(key, 0.0)), elapsed)

func _capture_investment_slice(day: int, report: Dictionary,
		out: Array[Dictionary]) -> void:
	if String(report.get("executed_stage", "")) != "building_commit" or \
			String(report.get("executed_substage", "")) != "investment":
		return
	out.append({
		"day": day,
		"elapsed_ms": float(report.get("elapsed_ms", 0.0)),
		"cursor_start": int(report.get("cursor_start", -1)),
		"cursor_end": int(report.get("cursor_end", -1)),
		"work_done": int(report.get("work_done", 0)),
	})

func _capture_structure_peak(report: Dictionary, peak: Dictionary) -> void:
	for key in [
		"building_structure_count_only_updates",
		"building_structure_new_groups",
		"building_structure_removed_groups",
		"building_structure_topology_rebuilds",
		"building_structure_role_span_reuses",
		"building_structure_role_span_appends",
		"building_structure_group_merge_ms",
		"building_structure_market_cache_ms",
		"building_structure_labor_cache_ms",
	]:
		peak[key] = maxf(float(peak.get(key, 0.0)), float(report.get(key, 0.0)))
	var rejection := String(report.get("last_building_rejection_reason", ""))
	if not rejection.is_empty():
		peak["last_building_rejection_reason"] = rejection

func _new_ext(cells: int, catalog: Dictionary) -> Object:
	var ext: Object = ClassDB.instantiate("DCWorldExt")
	ext.create_entities(cells)
	var values := PackedFloat32Array(); values.resize(cells); values.fill(0.5)
	for slot_name in [&"cell_temp", &"cell_moisture", &"cell_snow_cover", &"cell_weather_intensity", &"cell_elevation"]:
		var sid: int = ext.register_component(slot_name, 0, 1, false)
		ext.write_f32_range(sid, 0, values)
	var bytes := PackedByteArray(); bytes.resize(cells); bytes.fill(0)
	for slot_name in [&"cell_terrain", &"cell_landform", &"cell_vegetation", &"cell_is_water", &"cell_has_river"]:
		var sid: int = ext.register_component(slot_name, 2, 1, false)
		ext.write_u8_range(sid, 0, bytes)
	for i in range((catalog.building_resource_ids as PackedStringArray).size()):
		var reserve_sid: int = ext.register_component(StringName(catalog.building_resource_reserve_slots[i]), 0, 1, false)
		var extra_sid: int = ext.register_component(StringName(catalog.building_resource_extra_slots[i]), 0, 1, false)
		var reserve := PackedFloat32Array(); reserve.resize(cells); reserve.fill(1000.0)
		var extra := PackedFloat32Array(); extra.resize(cells); extra.fill(0.0)
		ext.write_f32_range(reserve_sid, 0, reserve)
		ext.write_f32_range(extra_sid, 0, extra)
	return ext

func _mean(values: PackedFloat64Array) -> float:
	if values.is_empty(): return 0.0
	var total := 0.0
	for value in values: total += value
	return total / values.size()

func _p95(values: PackedFloat64Array) -> float:
	if values.is_empty(): return 0.0
	return values[clampi(int(ceil(values.size() * 0.95)) - 1, 0, values.size() - 1)]
