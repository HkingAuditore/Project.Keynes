extends SceneTree

const EconomyCatalogScript = preload("res://scripts/economy/economy_catalog.gd")

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
	var profile = load("res://data/economy/default_economy.tres").to_native_profile()
	profile.market_cycle_days = 0 if "--auto" in args else 5
	profile.market_runtime_mode = "ACTIVE"
	profile.worker_enabled = not "--scalar" in args
	profile.worker_market_threshold = 64
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
		pop_cells.append(cell); signatures.append(employee_sig); populations.append(30); funds.append(1000000)
		building_cells.append(cell); building_types.append(estate_id if cell % 2 == 0 else mine_id)
		building_owners.append(owner_sig); building_counts.append(1)
	var boot: Dictionary = ext.bootstrap_economy({
		"cell_indices": pop_cells, "signature_ids": signatures,
		"population": populations, "funds": funds,
	}, {
		"building_cells": building_cells, "building_type_ids": building_types,
		"building_owner_signature_ids": building_owners, "building_counts": building_counts,
	})
	if not bool(boot.get("ok", false)):
		printerr(boot)
		quit(4)
		return
	if "--trace-cell" in args:
		ext.set_economy_trace_filter({"cells": PackedInt32Array([0])})
	if "--inspector-cell" in args:
		ext.set_economy_inspector_trace_cell(0)
	var building_ms := PackedFloat64Array()
	var all_ms := PackedFloat64Array()
	var report := {}
	var days := 25 if "--event-soak" in args else (
		int(boot.get("market_cycle_days", 5)) if "--auto" in args else 5)
	var barrier_slices := 0
	for day in range(days):
		report = ext.run_economy_slice({"day_index": day, "tick_index": day})
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
			all_ms.append(float(report.get("elapsed_ms", 0.0)))
			if bool(report.get("building_range_used", false)):
				building_ms.append(float(report.get("elapsed_ms", 0.0)))
	building_ms.sort()
	all_ms.sort()
	print("[building_bench] cells=%d groups=%d cohorts=%d building_slices=%d avg=%.3fms p95=%.3fms max=%.3fms all_max=%.3fms wage_plan=%.3fms labor_signal=%.3fms labor_edges=%d memory=%.1fMB hash=%d errors=%d/%d/%d discarded=%d unpaid=%d resource=%d/%d/%d extract_limited=%d capacity_checks=%d capacity_limited=%d" % [
		cells, int(report.get("building_group_count", 0)), int(report.get("cohort_count", 0)),
		building_ms.size(), _mean(building_ms), _p95(building_ms),
		building_ms[-1] if not building_ms.is_empty() else 0.0,
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
	print("[building_stage_bench] prepare=%.3fms audit=%.3fms watermark=%.3fms plan=%.3fms employment=%.3fms production=%.3fms production_merge=%.3fms production_tasks=%d investment=%.3fms formula=%.3fms clear=%.3fms price=%.3fms merchant=%.3fms trade_plan=%.3fms trade_dispatch=%.3fms publish=%.3fms processed_cells=%d processed_cohorts=%d groups=%d" % [
		float(report.get("prepare_ms", 0.0)), float(report.get("audit_ms", 0.0)),
		float(report.get("watermark_ms", 0.0)),
		float(report.get("building_plan_ms", 0.0)),
		float(report.get("building_employment_ms", 0.0)),
		float(report.get("building_production_ms", 0.0)),
		float(report.get("building_production_merge_ms", 0.0)),
		int(report.get("building_production_worker_tasks", 1)),
		float(report.get("building_investment_ms", 0.0)),
		float(report.get("formula_ms", 0.0)), float(report.get("clear_ms", 0.0)),
		float(report.get("price_ms", 0.0)), float(report.get("merchant_settle_ms", 0.0)),
		float(report.get("trade_plan_ms", 0.0)), float(report.get("trade_dispatch_ms", 0.0)),
		float(report.get("publish_ms", 0.0)), int(report.get("processed_cells", 0)),
		int(report.get("processed_cohorts", 0)), int(report.get("processed_building_groups", 0)),
	])
	quit(0 if int(report.get("population_error", 1)) == 0 and
		int(report.get("money_error", 1)) == 0 and int(report.get("goods_error", 1)) == 0 else 5)

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
