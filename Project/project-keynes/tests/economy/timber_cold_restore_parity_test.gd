extends SceneTree

const EconomyCatalogScript = preload("res://scripts/economy/economy_catalog.gd")
const CountryTestHelper = preload("res://tests/country/country_test_helper.gd")

const SEED := 20261128

var _checks := 0
var _failures := 0


func _init() -> void:
	_run()
	print("=== timber cold restore parity %s (%d checks, %d failures) ===" % [
		"PASS" if _failures == 0 else "FAIL", _checks, _failures])
	quit(0 if _failures == 0 else 1)


func _expect(label: String, condition: bool) -> void:
	_checks += 1
	print("  [%s] %s" % ["PASS" if condition else "FAIL", label])
	if not condition:
		_failures += 1


func _run() -> void:
	if not ClassDB.class_exists("DCWorldExt"):
		_expect("DCWorldExt is available", false)
		return
	var compiled: Dictionary = EconomyCatalogScript.compile_native_catalog()
	_expect("catalog compiles", bool(compiled.get("ok", false)))
	if not bool(compiled.get("ok", false)):
		return
	var catalog: Dictionary = compiled.duplicate(true)
	catalog.erase("ok")
	var timber_building_id := (catalog.building_type_ids as PackedStringArray).find("timber_collector")
	var logs_good_id := (catalog.good_ids as PackedStringArray).find("logs")
	var forager_sig := (catalog.signature_keys as PackedStringArray).find("forager|default")
	var timber_res_idx := (catalog.building_resource_ids as PackedStringArray).find("timber")
	_expect("catalog contains timber_collector, logs, forager, timber",
		timber_building_id >= 0 and logs_good_id >= 0 and forager_sig >= 0 and timber_res_idx >= 0)
	if timber_building_id < 0 or logs_good_id < 0 or forager_sig < 0 or timber_res_idx < 0:
		return

	print("\n--- Case 1: Save economy-only BEFORE map resource capture (day -1 -> run day 0, day 1) ---")
	_run_case_before_capture(catalog, timber_building_id, logs_good_id, forager_sig)

	print("\n--- Case 2: Save economy-only AFTER day 0 commit at density_q16 boundary (run day 1, day 2) ---")
	_run_case_after_day0_boundary(catalog, timber_building_id, logs_good_id, forager_sig)


func _run_case_before_capture(catalog: Dictionary, building_id: int, logs_good: int,
		forager_sig: int) -> void:
	var init_reserve := 6999207.0
	var base := _make_world(catalog, building_id, forager_sig, true, init_reserve)
	var pkec_src := _make_world(catalog, building_id, forager_sig, true, init_reserve)
	var ecp2_src := _make_world(catalog, building_id, forager_sig, true, init_reserve)

	# Save BEFORE any run_economy_slice / capture_building_context.
	var pkec_saved := _save_pkec(pkec_src.ext)
	var ecp2_saved: Dictionary = ecp2_src.ext.capture_economy_ecp2(0)
	var country_chunks := _save_country(pkec_src.ext)
	_expect("case1 PKEC save before capture succeeds", bool(pkec_saved.get("ok", false)))
	print("  [case1 ecp2_saved]=%s" % str({
		"ok": ecp2_saved.get("ok", false),
		"reason": ecp2_saved.get("reason", ""),
		"bytes": (ecp2_saved.get("bytes", PackedByteArray()) as PackedByteArray).size(),
	}))
	# ECP2 requires committed_day >= 0 (ledger_committed_day_negative before day 0).
	_expect("case1 ECP2 before day 0 commit reports ledger_committed_day_negative",
		not bool(ecp2_saved.get("ok", true))
		and String(ecp2_saved.get("reason", "")).find("ledger_committed_day_negative") >= 0)

	var pkec_cold := _make_world(catalog, building_id, forager_sig, false, init_reserve)
	_expect("case1 PKEC cold country restore succeeds", _restore_country(pkec_cold.ext, country_chunks))
	var pkec_res := _restore_pkec(pkec_cold.ext, pkec_saved.get("chunks", []))
	_expect("case1 PKEC cold economy restore succeeds", bool(pkec_res.get("ok", false)))

	for day in range(2):
		_run_day(base.ext, day)
		_run_day(pkec_cold.ext, day)
		var b := _probe(base, building_id, logs_good)
		var p := _probe(pkec_cold, building_id, logs_good)
		print("  [case1 day %d] base=%s" % [day, str(b)])
		print("  [case1 day %d] pkec=%s" % [day, str(p)])
		_expect("case1 day %d PKEC matches baseline (output %d vs %d, hash)" % [day, p.output, b.output],
			p.output == b.output and p.capacity_q16 == b.capacity_q16
			and p.extra_slot == b.extra_slot and p.env_hash == b.env_hash
			and p.state_hash == b.state_hash)


func _run_case_after_day0_boundary(catalog: Dictionary, building_id: int, logs_good: int,
		forager_sig: int) -> void:
	# timber ecology_capacity = 10,000,000.0 (10^10 in GOODS_SCALE).
	# 45870 * 10,000,000 / 65536 = 6,999,206.54296875 -> init_reserve = 6,999,207.0
	# Day 0 opens at density_q16 = 45870, consumes ~1642 timber, pushing MapData
	# reserve below 6,999,206.543 -> Day 1 baseline drops to density_q16 = 45869!
	var init_reserve := 6999207.0
	var base := _make_world(catalog, building_id, forager_sig, true, init_reserve)
	_run_day(base.ext, 0)
	var day0_base := _probe(base, building_id, logs_good)
	print("  [case2 day 0 source] base=%s" % str(day0_base))

	var pkec_saved := _save_pkec(base.ext)
	var ecp2_saved: Dictionary = base.ext.capture_economy_ecp2(0)
	var country_chunks := _save_country(base.ext)
	_expect("case2 PKEC save after day 0 succeeds", bool(pkec_saved.get("ok", false)))
	_expect("case2 ECP2 save after day 0 succeeds", bool(ecp2_saved.get("ok", false)))

	# (a) PKEC economy-only cold restore (fresh MapData)
	var pkec_cold := _make_world(catalog, building_id, forager_sig, false, init_reserve)
	# (b) ECP2 economy-only cold restore (fresh MapData, extra_change == 0)
	var ecp2_econ_only := _make_world(catalog, building_id, forager_sig, false, init_reserve)
	# (c) ECP2 cold restore WITH MapData extra_change copied (isolates _resource_stock_restored_pending_capture)
	var ecp2_with_map := _make_world(catalog, building_id, forager_sig, false, init_reserve)
	var day0_extra: float = base.ext.read_f32(int(base.slots["cell_res_timber_extra_change"]), 0)
	ecp2_with_map.ext.write_f32_range(
		int(ecp2_with_map.slots["cell_res_timber_extra_change"]), 0, PackedFloat32Array([day0_extra]))

	_restore_country(pkec_cold.ext, country_chunks)
	_restore_country(ecp2_econ_only.ext, country_chunks)
	_restore_country(ecp2_with_map.ext, country_chunks)
	_expect("case2 PKEC cold restore succeeds", bool(_restore_pkec(pkec_cold.ext, pkec_saved.get("chunks", [])).get("ok", false)))
	_expect("case2 ECP2(econ_only) cold restore succeeds",
		bool(ecp2_econ_only.ext.restore_economy_ecp2(ecp2_saved.get("bytes", PackedByteArray())).get("ok", false)))
	_expect("case2 ECP2(with_map) cold restore succeeds",
		bool(ecp2_with_map.ext.restore_economy_ecp2(ecp2_saved.get("bytes", PackedByteArray())).get("ok", false)))

	for day in [1, 2]:
		_run_day(base.ext, day)
		_run_day(pkec_cold.ext, day)
		_run_day(ecp2_econ_only.ext, day)
		_run_day(ecp2_with_map.ext, day)
		var b := _probe(base, building_id, logs_good)
		var p := _probe(pkec_cold, building_id, logs_good)
		var e := _probe(ecp2_econ_only, building_id, logs_good)
		var em := _probe(ecp2_with_map, building_id, logs_good)
		print("  [case2 day %d] base=          %s" % [day, str(b)])
		print("  [case2 day %d] pkec=          %s" % [day, str(p)])
		print("  [case2 day %d] ecp2_econ_only=%s" % [day, str(e)])
		print("  [case2 day %d] ecp2_with_map= %s" % [day, str(em)])
		_expect("case2 day %d PKEC matches baseline (output %d vs %d, cap %d vs %d)" % [
			day, p.output, b.output, p.capacity_q16, b.capacity_q16],
			p.output == b.output and p.capacity_q16 == b.capacity_q16 and p.state_hash == b.state_hash)
		_expect("case2 day %d ECP2(econ_only) matches baseline (output %d vs %d, cap %d vs %d)" % [
			day, e.output, b.output, e.capacity_q16, b.capacity_q16],
			e.output == b.output and e.capacity_q16 == b.capacity_q16 and e.state_hash == b.state_hash)
		_expect("case2 day %d ECP2(with_map) matches baseline (output %d vs %d, cap %d vs %d)" % [
			day, em.output, b.output, em.capacity_q16, b.capacity_q16],
			em.output == b.output and em.capacity_q16 == b.capacity_q16 and em.state_hash == b.state_hash)


func _make_world(catalog: Dictionary, building_id: int, forager_sig: int,
		do_bootstrap: bool, initial_timber: float) -> Dictionary:
	var ext: Object = ClassDB.instantiate("DCWorldExt")
	ext.create_entities(1)
	var slots := {}
	for slot_name in [&"cell_temp", &"cell_temp_30d", &"cell_moisture",
			&"cell_plant_available_water", &"cell_weather_precip", &"cell_snow_cover",
			&"cell_weather_intensity", &"cell_elevation", &"cell_temp_365d"]:
		var sid: int = ext.register_component(slot_name, 0, 1, false)
		var val := 0.5
		if slot_name == &"cell_moisture" or slot_name == &"cell_plant_available_water":
			val = 0.6
		elif slot_name == &"cell_weather_precip" or slot_name == &"cell_snow_cover" or slot_name == &"cell_weather_intensity":
			val = 0.0
		ext.write_f32_range(sid, 0, PackedFloat32Array([val]))
		slots[String(slot_name)] = sid
	for slot_name in [&"cell_terrain", &"cell_landform", &"cell_vegetation",
			&"cell_is_water", &"cell_has_river", &"cell_weather_type", &"cell_cover"]:
		var sid: int = ext.register_component(slot_name, 2, 1, false)
		ext.write_u8_range(sid, 0, PackedByteArray([0]))
		slots[String(slot_name)] = sid
	var reserve_slots: PackedStringArray = catalog.building_resource_reserve_slots
	var extra_slots: PackedStringArray = catalog.building_resource_extra_slots
	var res_ids: PackedStringArray = catalog.building_resource_ids
	for i in range(reserve_slots.size()):
		var r_sid: int = ext.register_component(StringName(reserve_slots[i]), 0, 1, false)
		var e_sid: int = ext.register_component(StringName(extra_slots[i]), 0, 1, false)
		var initial := initial_timber if String(res_ids[i]) == "timber" else 0.0
		ext.write_f32_range(r_sid, 0, PackedFloat32Array([initial]))
		ext.write_f32_range(e_sid, 0, PackedFloat32Array([0.0]))
		slots[String(reserve_slots[i])] = r_sid
		slots[String(extra_slots[i])] = e_sid

	CountryTestHelper.configure_all_technologies(ext, catalog, 1, SEED)

	var profile: Dictionary = load("res://data/economy/default_economy.tres").to_native_profile()
	profile.market_cycle_days = 1
	profile.market_min_cycle_days = 1
	profile.market_max_cycle_days = 1
	profile.economy_cadence_force_market_days = 1
	profile.market_runtime_mode = "ACTIVE"
	profile.trade_runtime_mode = "OFF"
	profile.resource_safe_harvest_q16 = 0
	ext.configure_economy(catalog, profile, 1, SEED)

	if do_bootstrap:
		var goods: PackedStringArray = catalog.good_ids
		var stock := PackedInt64Array()
		stock.resize(goods.size())
		stock.fill(1000000)
		stock[goods.find("logs")] = 0
		# Clear tools so timber_collector runs at base 6968 * density_q16 without soft-input boost.
		stock[goods.find("tools")] = 0
		var prices := PackedInt32Array()
		prices.resize(goods.size())
		var defaults: PackedInt32Array = catalog.good_default_price
		for g in range(goods.size()):
			prices[g] = defaults[g]
		var boot: Dictionary = ext.bootstrap_economy({
			"cell_indices": PackedInt32Array([0]),
			"signature_ids": PackedInt32Array([forager_sig]),
			"population": PackedInt64Array([20]),
			"funds": PackedInt64Array([500000]),
		}, {
			"stock": stock,
			"price": prices,
			"building_cells": PackedInt32Array([0]),
			"building_type_ids": PackedInt32Array([building_id]),
			"building_counts": PackedInt64Array([1]),
			"building_owner_signature_ids": PackedInt32Array([forager_sig]),
		})
		_expect("world bootstraps", bool(boot.get("ok", false)))
	return {"ext": ext, "slots": slots}


func _run_day(ext: Object, day: int) -> Dictionary:
	var report := {}
	for slice in range(512):
		report = ext.run_economy_slice({
			"day_index": day,
			"tick_index": day * 1000 + slice,
			"slice_budget_ms": 8.0,
		})
		if bool(report.get("done", false)) or bool(report.get("fatal", false)):
			return report
	return report


func _probe(world: Dictionary, building_id: int, logs_good: int) -> Dictionary:
	var ext: Object = world.ext
	var slots: Dictionary = world.slots
	var bsnap: Dictionary = ext.get_building_cell_snapshot(0)
	var idx: int = (bsnap.get("group_type_ids", PackedInt32Array()) as PackedInt32Array).find(building_id)
	var output := int((bsnap.get("last_output", PackedInt64Array()) as PackedInt64Array)[idx]) if idx >= 0 else -1
	var res_used := int((bsnap.get("last_resource", PackedInt64Array()) as PackedInt64Array)[idx]) if idx >= 0 else -1
	var cap_q16 := int((bsnap.get("capacity_q16", PackedInt64Array()) as PackedInt64Array)[idx]) if idx >= 0 else -1
	var msnap: Dictionary = ext.get_market_cell_snapshot(0)
	var stock_arr: PackedInt64Array = msnap.get("stock", PackedInt64Array())
	var logs_stock := int(stock_arr[logs_good]) if logs_good < stock_arr.size() else -1
	var rep: Dictionary = ext.get_economy_report()
	var reserve_val: float = ext.read_f32(int(slots["cell_res_timber_reserve"]), 0)
	var extra_val: float = ext.read_f32(int(slots["cell_res_timber_extra_change"]), 0)
	return {
		"output": output,
		"resource_used": res_used,
		"capacity_q16": cap_q16,
		"logs_stock": logs_stock,
		"reserve_slot": reserve_val,
		"extra_slot": extra_val,
		"env_day": int(rep.get("environment_day", -1)),
		"env_hash": int(rep.get("environment_hash", 0)),
		"state_hash": ext.get_economy_state_hash(),
	}


func _save_country(ext: Object) -> Array[PackedByteArray]:
	var chunks: Array[PackedByteArray] = []
	ext.begin_country_save(65536)
	while true:
		var chunk: PackedByteArray = ext.read_country_save_chunk(65536)
		if chunk.is_empty():
			break
		chunks.append(chunk)
	ext.end_country_save()
	return chunks


func _restore_country(ext: Object, chunks: Array[PackedByteArray]) -> bool:
	if not bool(ext.begin_country_restore().get("ok", false)):
		return false
	for chunk in chunks:
		if not bool(ext.feed_country_restore_chunk(chunk).get("ok", false)):
			return false
	return bool(ext.end_country_restore().get("ok", false))


func _save_pkec(ext: Object) -> Dictionary:
	var begin: Dictionary = ext.begin_economy_save(65536)
	if not bool(begin.get("ok", false)):
		return begin
	var chunks: Array[PackedByteArray] = []
	while true:
		var chunk: PackedByteArray = ext.read_economy_save_chunk(65536)
		if chunk.is_empty():
			break
		chunks.append(chunk)
	var ended: Dictionary = ext.end_economy_save()
	return {"ok": bool(ended.get("ok", false)), "chunks": chunks}


func _restore_pkec(ext: Object, chunks: Array) -> Dictionary:
	var begin: Dictionary = ext.begin_economy_restore()
	if not bool(begin.get("ok", false)):
		return begin
	for chunk in chunks:
		var fed: Dictionary = ext.feed_economy_restore_chunk(chunk as PackedByteArray)
		if not bool(fed.get("ok", false)):
			return fed
	return ext.end_economy_restore()
