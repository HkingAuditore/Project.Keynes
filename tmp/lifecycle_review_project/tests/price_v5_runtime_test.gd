extends "res://tests/goods_storage_schema_test.gd"

func _run() -> void:
	print("=== Price V5 runtime regression ===")
	var compiled: Dictionary = EconomyCatalogScript.compile_native_catalog()
	_expect("catalog compiles without a minimum-price column",
		bool(compiled.get("ok", false)) and not compiled.has("good_min_price"))
	if not bool(compiled.get("ok", false)):
		_finish()
		return
	var catalog := _without_natural_demography(compiled)
	_test_obsolete_floor(catalog)
	for money in [0, 1, 2, 10, 10000]:
		_test_low_price_budget(catalog, money)
		_test_low_price_budget(catalog, money, true)
		_test_low_price_budget(catalog, money, true, true)
	_test_price_v3_numeric_guards_and_horizons(catalog)
	_test_worker_scalar_equivalence(catalog)
	_finish()

func _test_obsolete_floor(catalog: Dictionary) -> void:
	var profile = load("res://scripts/data/good_profile.gd").new()
	profile.set("min_price", 9000)
	_expect("obsolete resource floor is detected", profile.has_meta(&"obsolete_min_price"))
	var ext: Object = _new_ext(1, 0.5)
	var invalid := catalog.duplicate(true)
	invalid.good_min_price = PackedInt32Array([9000])
	var result: Dictionary = ext.configure_economy(invalid, _native_profile(false, 1), 1, 481)
	_expect("native catalog rejects obsolete price floor explicitly",
		not bool(result.get("ok", true)) and
		String(result.get("reason", "")) == "obsolete_good_min_price_price_v5")

func _test_mixed_tax_policy(ext: Object, catalog: Dictionary, subsidized: bool) -> void:
	var technologies := PackedInt32Array()
	for i in range(catalog.technology_ids.size()):
		technologies.append(i)
	_expect("funded fiscal fixture bootstraps", bool(ext.bootstrap_country({
		"country_ids": PackedStringArray(["price_v5.fiscal"]),
		"country_names": PackedStringArray(["Price V5 fiscal"]),
		"country_cash": PackedInt64Array([1000000000]),
		"territory_offsets": PackedInt32Array([0, 1]), "territory_cells": PackedInt32Array([0]),
		"technology_offsets": PackedInt32Array([0, technologies.size()]),
		"technology_indices": technologies, "treasury_offsets": PackedInt32Array([0, 0]),
		"treasury_good_indices": PackedInt32Array(), "treasury_quantities": PackedInt64Array(),
	}, PackedByteArray([0])).get("ok", false)))
	var count: int = catalog.good_ids.size()
	var indices := PackedInt32Array()
	var rates := PackedInt32Array()
	var sequences := PackedInt64Array()
	for i in range(count):
		indices.append(i)
		rates.append(([0, -50, -100] if subsidized else [0, 33, 75])[i % 3])
		sequences.append(i + 1)
	var overrides := PackedInt32Array()
	overrides.resize(count); overrides.fill(12)
	var kinds := PackedInt32Array()
	kinds.resize(count); kinds.fill(1)
	var handles := PackedInt64Array()
	handles.resize(count); handles.fill(int(ext.get_country_cell_summary(0).country_handle))
	var minus_one := PackedInt32Array()
	minus_one.resize(count); minus_one.fill(-1)
	var zeros := PackedInt32Array()
	zeros.resize(count)
	var zeros64 := PackedInt64Array()
	zeros64.resize(count)
	var strings := PackedStringArray()
	strings.resize(count)
	var result: Dictionary = ext.submit_country_commands({
		"opcodes": overrides, "effective_days": zeros64, "sequences": sequences,
		"target_handles": handles, "cell_indices": minus_one, "aux_i32": minus_one,
		"domain_i32": minus_one, "position_i32": minus_one,
		"weight0_bp": zeros, "weight1_bp": zeros, "weight2_bp": zeros, "weight3_bp": zeros,
		"value_i64": zeros64, "tax_kinds": kinds, "tax_item_indices": indices,
		"tax_rate_percent": rates, "stable_ids": strings, "display_names": strings,
	})
	_expect("mixed tax policies submitted", bool(result.get("ok", false)))
	_expect("mixed tax policies committed", bool(ext.run_country_slice({"day_index": 0}).get("ok", false)))

func _test_low_price_budget(catalog: Dictionary, money: int, taxed: bool = false,
		subsidized: bool = false) -> void:
	var ext: Object = _new_ext(1, 0.5)
	_expect("low-price country configured", CountryTestHelper.configure_all_technologies(ext, catalog, 1, 482))
	if taxed:
		_test_mixed_tax_policy(ext, catalog, subsidized)
	var profile := _native_profile(false, 1)
	profile.starvation_death_rate_q32 = 0
	profile.trade_runtime_mode = "OFF"
	var result: Dictionary = ext.configure_economy(catalog, profile, 1, 482)
	_expect("low-price economy configured", bool(result.get("ok", false)))
	ext.inject_economy_cadence_timing(0.01, 0.01)
	var goods: PackedStringArray = catalog.good_ids
	var signatures: PackedStringArray = catalog.signature_keys
	var price := PackedInt32Array()
	var stock := PackedInt64Array()
	price.resize(goods.size()); price.fill(1)
	stock.resize(goods.size()); stock.fill(1000000)
	for i in range(goods.size()):
		if int((catalog.good_storage_modes as PackedInt32Array)[i]) != 0:
			stock[i] = 0
	result = ext.bootstrap_economy({
		"cell_indices": PackedInt32Array([0, 0]),
		"signature_ids": PackedInt32Array([signatures.find("worker|default"), signatures.find("merchant|default")]),
		"population": PackedInt64Array([1, 1]),
		"funds": PackedInt64Array([money, 0]),
	}, {"price": price, "stock": stock})
	_expect("low-price market bootstraps", bool(result.get("ok", false)))
	result = _run_day(ext, 0)
	_expect("low-price settlement conserves all ledgers, budget=%d" % money,
		not bool(result.get("fatal", false)) and int(result.get("money_error", 1)) == 0 and
		int(result.get("goods_error", 1)) == 0 and int(result.get("population_error", 1)) == 0)
	var population: Dictionary = ext.get_population_cell_snapshot(0)
	var expense := _sum_i64(population.epoch_expense_by_cohort)
	var market: Dictionary = ext.get_market_cell_snapshot(0)
	var consumed := _sum_i64(stock) - _sum_i64(market.stock)
	_expect("no overspending at one-tick prices, budget=%d" % money, expense <= money)
	if not subsidized:
		_expect("positive delivery has a paid invoice, budget=%d" % money,
			consumed == 0 or expense > 0)
	if money == 0 and not subsidized:
		_expect("empty wallets cannot consume free inventory", consumed == 0)
	elif not taxed or money >= 10:
		_expect("small positive wallets can buy essentials", consumed > 0 and expense > 0)
