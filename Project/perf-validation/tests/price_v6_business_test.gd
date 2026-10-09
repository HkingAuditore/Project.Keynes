extends "res://tests/building_runtime_test.gd"

func _run() -> void:
	print("=== Price V6 production funding regression ===")
	var source: Dictionary = EconomyCatalogScript.compile_native_catalog()
	_expect("production funding catalog compiles", bool(source.get("ok", false)))
	if not bool(source.get("ok", false)): return
	for scenario in ["funded", "cashless", "no_owner", "no_resource", "complement"]:
		_case(source, scenario)
	print("=== production funding %s failures=%d ===" % ["PASS" if failures == 0 else "FAIL", failures])

func _case(source: Dictionary, scenario: String) -> void:
	var catalog := source.duplicate(true)
	catalog.good_reference_max_price = (catalog.good_default_price as PackedInt32Array).duplicate()
	for column in ["good_inventory_weight_q16", "good_shortage_weight_q16", "good_excess_demand_weight_q16", "good_cost_anchor_weight_q16", "good_inactive_reversion_weight_q16"]:
		var values: PackedInt32Array = catalog[column].duplicate()
		values.fill(0)
		catalog[column] = values
	for column in ["signature_birth_rate_q32", "signature_death_rate_q32"]:
		var values: PackedInt64Array = catalog[column].duplicate()
		values.fill(0)
		catalog[column] = values
	var hunting := (catalog.building_type_ids as PackedStringArray).find("stone_age_hunting_camp")
	var ore := (catalog.good_ids as PackedStringArray).find("copper_ore")
	_ensure_building_input(catalog, hunting, ore, 10, 65536)
	var missing_ore := (catalog.good_ids as PackedStringArray).find("lead_ore")
	if scenario == "complement":
		_ensure_building_input(catalog, hunting, missing_ore, 10, 65536, true)
	_clear_building_climate(catalog, hunting)
	_set_building_first_output_quantity(catalog, hunting, 100000)
	var profile: Dictionary = load("res://data/economy/default_economy.tres").to_native_profile()
	profile.economy_cadence_force_market_days = 1
	profile.market_cycle_days = 1
	profile.market_min_cycle_days = 1
	profile.market_max_cycle_days = 1
	profile.starvation_death_rate_q32 = 0
	profile.employment_mobility_daily_q16 = 0
	profile.startup_demand_runtime_mode = "OFF"
	profile.family_runtime_mode = "OFF"
	profile.trade_runtime_mode = "OFF"
	var ext := _new_ext(catalog)
	_expect(scenario + " country bootstraps", CountryTestHelper.configure_all_technologies(ext, catalog, 1, 4911))
	_expect(scenario + " configures", bool(ext.configure_economy(catalog, profile, 1, 4911).get("ok", false)))
	_seed_resource_reserve(ext, catalog, "wild_game", 0.0 if scenario == "no_resource" else 1000000000.0)
	var sigs: PackedStringArray = catalog.signature_keys
	var hunter := sigs.find("hunter|default")
	var merchant := sigs.find("merchant|default")
	var packet := {"cell_indices": PackedInt32Array([0]), "signature_ids": PackedInt32Array([merchant]),
		"population": PackedInt64Array([1]), "funds": PackedInt64Array([0 if scenario == "cashless" else 1000000000000])}
	if scenario != "no_owner":
		packet.cell_indices.append(0)
		packet.signature_ids.append(hunter)
		packet.population.append(2)
		packet.funds.append(0 if scenario == "cashless" else 1000000000000)
	var stock := PackedInt64Array()
	stock.resize((catalog.good_ids as PackedStringArray).size())
	if scenario == "complement": stock[ore] = 1000000000
	_expect(scenario + " settlement bootstraps", bool(ext.bootstrap_economy(packet, {
		"stock": stock,
		"building_cells": PackedInt32Array([0]), "building_type_ids": PackedInt32Array([hunting]),
		"building_owner_signature_ids": PackedInt32Array([hunter]), "building_counts": PackedInt64Array([1]),
	}).get("ok", false)))
	var clean := true
	var max_desired_ore := 0
	var max_desired_missing := 0
	var base_ok := true
	for day in range(5):
		var report: Dictionary = {}
		for slice in range(65536):
			report = ext.run_economy_slice({"day_index": day, "tick_index": slice})
			if bool(report.get("done", false)) or bool(report.get("fatal", false)): break
		clean = clean and not bool(report.get("fatal", true)) and int(report.get("money_error", 1)) == 0 and int(report.get("goods_error", 1)) == 0
		var market: Dictionary = ext.get_market_cell_snapshot(0)
		if int(market.price_base_ceiling[ore]) != 2147483647:
			base_ok = false
		max_desired_ore = maxi(max_desired_ore, int(market.desired_business_demand[ore]))
		max_desired_missing = maxi(max_desired_missing, int(market.desired_business_demand[missing_ore]))
	_expect(scenario + " base ceiling stays numeric guard", base_ok)
	_expect(scenario + " conserves ledgers", clean)
	# Authored economic ceilings are gone; this suite checks numeric guards
	# under production, and that ownerless buildings emit no input desire.
	# Missing natural resources may still leave an input wish on the books.
	var expect_ore := scenario != "no_owner"
	_expect(scenario + " executable buildings emit ore desire correctly",
		max_desired_ore > 0 if expect_ore else max_desired_ore == 0)
	if scenario == "complement":
		_expect("complementary missing input still emits desire", max_desired_missing > 0)
