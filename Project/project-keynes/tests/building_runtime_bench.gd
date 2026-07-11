extends SceneTree

const EconomyCatalogScript = preload("res://scripts/economy/economy_catalog.gd")

func _init() -> void:
	var cells := 10000
	var catalog: Dictionary = EconomyCatalogScript.compile_native_catalog()
	if not bool(catalog.get("ok", false)):
		printerr(catalog)
		quit(2)
		return
	var ext := _new_ext(cells, catalog)
	var native_catalog := catalog.duplicate(true)
	native_catalog.erase("ok")
	var profile = load("res://data/economy/default_economy.tres").to_native_profile()
	profile.market_cycle_days = 5
	profile.market_runtime_mode = "ACTIVE"
	profile.worker_enabled = true
	profile.worker_market_threshold = 64
	if not bool(ext.configure_economy(native_catalog, profile, cells, 20260711).get("ok", false)):
		printerr("configure failed")
		quit(3)
		return
	var landlord_sig := (catalog.signature_keys as PackedStringArray).find("landlord|default")
	var worker_sig := (catalog.signature_keys as PackedStringArray).find("worker|default")
	var mine_id := (catalog.building_type_ids as PackedStringArray).find("coal_mine")
	var pop_cells := PackedInt32Array()
	var signatures := PackedInt32Array()
	var populations := PackedInt64Array()
	var funds := PackedInt64Array()
	var building_cells := PackedInt32Array()
	var building_types := PackedInt32Array()
	var building_owners := PackedInt32Array()
	var building_counts := PackedInt64Array()
	for cell in range(cells):
		pop_cells.append(cell); signatures.append(landlord_sig); populations.append(2); funds.append(1000000)
		pop_cells.append(cell); signatures.append(worker_sig); populations.append(30); funds.append(1000000)
		building_cells.append(cell); building_types.append(mine_id)
		building_owners.append(landlord_sig); building_counts.append(1)
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
	var building_ms := PackedFloat64Array()
	var all_ms := PackedFloat64Array()
	var report := {}
	for day in range(5):
		report = ext.run_economy_slice({"day_index": day, "tick_index": day})
		all_ms.append(float(report.get("elapsed_ms", 0.0)))
		if bool(report.get("building_range_used", false)):
			building_ms.append(float(report.get("elapsed_ms", 0.0)))
		var catchup := 0
		while not bool(report.get("done", false)) and bool(report.get("commit_due", false)):
			catchup += 1
			report = ext.run_economy_slice({"day_index": day, "tick_index": day * 1000 + catchup})
			all_ms.append(float(report.get("elapsed_ms", 0.0)))
			if bool(report.get("building_range_used", false)):
				building_ms.append(float(report.get("elapsed_ms", 0.0)))
	building_ms.sort()
	all_ms.sort()
	print("[building_bench] cells=%d groups=%d cohorts=%d building_slices=%d avg=%.3fms p95=%.3fms max=%.3fms all_max=%.3fms memory=%.1fMB hash=%d errors=%d/%d/%d discarded=%d" % [
		cells, int(report.get("building_group_count", 0)), int(report.get("cohort_count", 0)),
		building_ms.size(), _mean(building_ms), _p95(building_ms),
		building_ms[-1] if not building_ms.is_empty() else 0.0,
		all_ms[-1] if not all_ms.is_empty() else 0.0,
		float(report.get("memory_bytes", 0)) / 1048576.0, ext.get_economy_state_hash(),
		int(report.get("population_error", 1)), int(report.get("money_error", 1)),
		int(report.get("goods_error", 1)), int(report.get("production_output_discarded", 0)),
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

