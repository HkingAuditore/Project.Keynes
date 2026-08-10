extends SceneTree

const EconomyCatalogScript = preload("res://scripts/economy/economy_catalog.gd")

var _failures := 0


func _init() -> void:
	var catalog: Dictionary = EconomyCatalogScript.compile_native_catalog()
	_expect("construction catalog compiles", bool(catalog.get("ok", false)))
	if bool(catalog.get("ok", false)):
		catalog.erase("ok")
		var profile: Dictionary = load(
			"res://data/economy/default_economy.tres").to_native_profile()
		profile.market_runtime_mode = "ACTIVE"
		profile.market_cycle_days = 5
		_test_market_funded_build(catalog, profile)
		_test_cash_failure_is_atomic(catalog, profile)
	print("=== treasury construction runtime: %d failures ===" % _failures)
	quit(0 if _failures == 0 else 1)


func _test_market_funded_build(catalog: Dictionary, profile: Dictionary) -> void:
	var ext := _fixture(catalog, profile, 1000000000000)
	_expect("funded fixture bootstraps", ext != null)
	if ext == null:
		return
	_expect("funded fixture publishes its initial resource snapshot",
		bool(_run_day(ext, 0).get("done", false)))
	var country: Dictionary = ext.get_country_cell_summary(0)
	var candidate := _eligible_candidate(ext, catalog, int(country.country_handle))
	_expect("at least one quoted building is eligible", candidate >= 0)
	if candidate < 0:
		return
	var submit := _submit(ext, int(country.country_handle), candidate, 701)
	_expect("treasury-sponsored build queues", bool(submit.get("ok", false)))
	var report := _run_day(ext, 1)
	var receipts: Array = ext.get_construction_command_receipts(0, 8).get(
		"receipts", [])
	var receipt: Dictionary = receipts[0] if not receipts.is_empty() else {}
	var buildings: Dictionary = ext.get_building_cell_snapshot(0)
	_expect("funded command settles successfully",
		bool(report.get("done", false)) and bool(receipt.get("ok", false)) and
		int(receipt.get("sequence", 0)) == 701 and
		int(receipt.get("cash_paid", 0)) > 0 and
		int(receipt.get("market_goods_used", 0)) > 0)
	_expect("successful command leaves one pending or completed building",
		_sum_i64(buildings.get("construction_counts", PackedInt64Array())) +
		_sum_i64(buildings.get("group_counts", PackedInt64Array())) == 1)
	_expect("funded construction preserves economy conservation",
		int(report.get("population_error", 1)) == 0 and
		int(report.get("money_error", 1)) == 0 and
		int(report.get("goods_error", 1)) == 0)


func _test_cash_failure_is_atomic(catalog: Dictionary, profile: Dictionary) -> void:
	var ext := _fixture(catalog, profile, 0)
	_expect("cashless fixture bootstraps", ext != null)
	if ext == null:
		return
	_expect("cashless fixture publishes its initial resource snapshot",
		bool(_run_day(ext, 0).get("done", false)))
	var country: Dictionary = ext.get_country_cell_summary(0)
	var candidate := _cash_blocked_candidate(ext, catalog, int(country.country_handle))
	_expect("quote exposes treasury cash insufficiency", candidate >= 0)
	if candidate < 0:
		return
	var treasury_before: Dictionary = ext.get_country_treasury_snapshot(
		int(country.country_handle))
	var submit := _submit(ext, int(country.country_handle), candidate, 702)
	_expect("cashless command still queues for boundary revalidation",
		bool(submit.get("ok", false)))
	var report := _run_day(ext, 1)
	var receipts: Array = ext.get_construction_command_receipts(0, 8).get(
		"receipts", [])
	var receipt: Dictionary = receipts[0] if not receipts.is_empty() else {}
	var treasury_after: Dictionary = ext.get_country_treasury_snapshot(
		int(country.country_handle))
	var buildings: Dictionary = ext.get_building_cell_snapshot(0)
	var goods_before: PackedInt64Array = treasury_before.get(
		"quantities", PackedInt64Array())
	var goods_after: PackedInt64Array = treasury_after.get(
		"quantities", PackedInt64Array())
	_expect("cashless command settles with stable failure code and zero spend",
		not bool(receipt.get("ok", true)) and
		String(receipt.get("code", "")) ==
			"construction_treasury_cash_insufficient" and
		int(receipt.get("cash_paid", -1)) == 0 and
		int(receipt.get("treasury_goods_used", -1)) == 0 and
		int(receipt.get("market_goods_used", -1)) == 0)
	_expect("failed command does not change treasury or start construction",
		int(treasury_after.get("cash", -1)) == int(treasury_before.get("cash", -2)) and
		goods_after == goods_before and
		_sum_i64(buildings.get("construction_counts", PackedInt64Array())) == 0)
	_expect("failed construction preserves economy conservation",
		int(report.get("population_error", 1)) == 0 and
		int(report.get("money_error", 1)) == 0 and
		int(report.get("goods_error", 1)) == 0)


func _fixture(catalog: Dictionary, profile: Dictionary, country_cash: int) -> Object:
	var ext := _new_ext(catalog)
	var technology_ids: PackedStringArray = catalog.technology_ids
	var technology_indices := PackedInt32Array()
	for technology_id in range(technology_ids.size()):
		technology_indices.append(technology_id)
	var configured: Dictionary = ext.configure_country(catalog, {
		"country_runtime_mode": "ACTIVE",
	}, 1, 914)
	if not bool(configured.get("ok", false)):
		return null
	var country_boot: Dictionary = ext.bootstrap_country({
		"country_ids": PackedStringArray(["country.player"]),
		"country_names": PackedStringArray(["Player"]),
		"country_cash": PackedInt64Array([country_cash]),
		"territory_offsets": PackedInt32Array([0, 1]),
		"territory_cells": PackedInt32Array([0]),
		"technology_offsets": PackedInt32Array([0, technology_indices.size()]),
		"technology_indices": technology_indices,
		"treasury_offsets": PackedInt32Array([0, 0]),
		"treasury_good_indices": PackedInt32Array(),
		"treasury_quantities": PackedInt64Array(),
	}, PackedByteArray([0]))
	if not bool(country_boot.get("ok", false)):
		return null
	if not bool(ext.configure_economy(catalog, profile, 1, 914).get("ok", false)):
		return null
	var merchant_signature := (catalog.signature_keys as PackedStringArray).find(
		"merchant|default")
	var stock := PackedInt64Array()
	stock.resize((catalog.good_ids as PackedStringArray).size())
	stock.fill(1000000000)
	var economy_boot: Dictionary = ext.bootstrap_economy({
		"cell_indices": PackedInt32Array([0]),
		"signature_ids": PackedInt32Array([merchant_signature]),
		"population": PackedInt64Array([10]),
		"funds": PackedInt64Array([100000000]),
	}, {"stock": stock})
	return ext if bool(economy_boot.get("ok", false)) else null


func _eligible_candidate(ext: Object, catalog: Dictionary, country_handle: int) -> int:
	var type_ids := PackedInt32Array()
	for type_id in range((catalog.building_type_ids as PackedStringArray).size()):
		type_ids.append(type_id)
	var quote: Dictionary = ext.get_treasury_construction_quotes(
		country_handle, 0, type_ids)
	var eligible: PackedByteArray = quote.get("eligible", PackedByteArray())
	var cash: PackedInt64Array = quote.get("cash_required", PackedInt64Array())
	for row in range(eligible.size()):
		if eligible[row] != 0 and cash[row] > 0:
			return int(type_ids[row])
	return -1


func _cash_blocked_candidate(ext: Object, catalog: Dictionary,
		country_handle: int) -> int:
	var type_ids := PackedInt32Array()
	for type_id in range((catalog.building_type_ids as PackedStringArray).size()):
		type_ids.append(type_id)
	var quote: Dictionary = ext.get_treasury_construction_quotes(
		country_handle, 0, type_ids)
	var reasons: PackedStringArray = quote.get("reason_codes", PackedStringArray())
	for row in range(reasons.size()):
		if reasons[row] == "construction_treasury_cash_insufficient":
			return int(type_ids[row])
	return -1


func _submit(ext: Object, country_handle: int, type_id: int,
		sequence: int) -> Dictionary:
	return ext.submit_economy_commands({
		"opcodes": PackedInt32Array([16]),
		"effective_days": PackedInt64Array([5]),
		"sequences": PackedInt64Array([sequence]),
		"target_handles": PackedInt64Array([country_handle]),
		"i32_0": PackedInt32Array([0]),
		"i32_1": PackedInt32Array([type_id]),
		"i64_0": PackedInt64Array([1]),
		"i64_1": PackedInt64Array([1]),
	})


func _run_day(ext: Object, day: int) -> Dictionary:
	var report := {}
	var simulation_day := day * 5
	for slice in range(256):
		report = ext.run_economy_slice({
			"day_index": simulation_day,
			"tick_index": simulation_day * 1000 + slice,
		})
		if bool(report.get("done", false)):
			return report
	return report


func _new_ext(catalog: Dictionary) -> Object:
	var ext: Object = ClassDB.instantiate("DCWorldExt")
	ext.create_entities(1)
	var scalar := PackedFloat32Array([0.5])
	for slot_name in [&"cell_temp", &"cell_temp_30d", &"cell_moisture",
			&"cell_plant_available_water", &"cell_snow_cover",
			&"cell_weather_intensity", &"cell_elevation"]:
		var slot_id: int = ext.register_component(slot_name, 0, 1, false)
		ext.write_f32_range(slot_id, 0, scalar)
	var zero := PackedByteArray([0])
	for slot_name in [&"cell_terrain", &"cell_landform", &"cell_vegetation",
			&"cell_is_water", &"cell_has_river"]:
		var slot_id: int = ext.register_component(slot_name, 2, 1, false)
		ext.write_u8_range(slot_id, 0, zero)
	var reserve_slots: PackedStringArray = catalog.building_resource_reserve_slots
	var extra_slots: PackedStringArray = catalog.building_resource_extra_slots
	for resource_id in range(
			(catalog.building_resource_ids as PackedStringArray).size()):
		var reserve_slot: int = ext.register_component(
			StringName(reserve_slots[resource_id]), 0, 1, false)
		var extra_slot: int = ext.register_component(
			StringName(extra_slots[resource_id]), 0, 1, false)
		ext.write_f32_range(reserve_slot, 0, PackedFloat32Array([1000000000.0]))
		ext.write_f32_range(extra_slot, 0, PackedFloat32Array([0.0]))
	return ext


func _sum_i64(values: PackedInt64Array) -> int:
	var total := 0
	for value in values:
		total += int(value)
	return total


func _expect(label: String, condition: bool) -> void:
	print("  [%s] %s" % ["PASS" if condition else "FAIL", label])
	if not condition:
		_failures += 1
