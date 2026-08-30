extends "res://tests/price_v5_runtime_test.gd"

func _run() -> void:
	print("=== Price V6 dynamic ceiling regression ===")
	var compiled: Dictionary = EconomyCatalogScript.compile_native_catalog()
	_expect("V6 catalog compiles", bool(compiled.get("ok", false)))
	if not bool(compiled.get("ok", false)):
		_finish()
		return
	var catalog := _without_natural_demography(compiled)
	_test_obsolete_floor(catalog)
	var obsolete := catalog.duplicate(true)
	obsolete.good_max_price = obsolete.good_reference_max_price
	obsolete.erase("good_reference_max_price")
	var invalid: Object = _new_ext(1, 0.5)
	var rejected: Dictionary = invalid.configure_economy(obsolete, _native_profile(false, 1), 1, 4901)
	_expect("obsolete maximum column explicitly rejected",
		not bool(rejected.get("ok", true)) and rejected.get("reason", "") == "obsolete_good_max_price_price_v6")
	var legacy_profile = load("res://scripts/data/good_profile.gd").new()
	legacy_profile.set("max_price", 100)
	_expect("obsolete resource maximum detected", legacy_profile.has_meta(&"obsolete_max_price"))
	for period in [1, 3, 5]:
		_test_ceiling_clock(catalog, period, 1000000000000)
		_test_ceiling_clock(catalog, period, 0)
	_test_substitute_credit(catalog)
	_test_active_ceiling_workers(catalog)
	_finish()

func _ceiling_catalog(source: Dictionary) -> Dictionary:
	var catalog := source.duplicate(true)
	catalog.good_reference_max_price = (catalog.good_default_price as PackedInt32Array).duplicate()
	return catalog

func _ceiling_profile(period: int, workers: bool = false) -> Dictionary:
	var profile := _native_profile(workers, 1)
	profile.market_cycle_days = period
	profile.market_min_cycle_days = period
	profile.market_max_cycle_days = period
	profile.starvation_death_rate_q32 = 0
	profile.trade_runtime_mode = "OFF"
	return profile

func _ceiling_world(catalog: Dictionary, period: int, money: int, cells: int = 1, workers: bool = false) -> Object:
	var ext: Object = _new_ext(cells, 0.5)
	_expect("ceiling country configured", CountryTestHelper.configure_all_technologies(ext, catalog, cells, 4901))
	_expect("ceiling economy configured", bool(ext.configure_economy(catalog, _ceiling_profile(period, workers), cells, 4901).get("ok", false)))
	ext.inject_economy_cadence_timing(0.01, 0.01)
	var packet := {"cell_indices": PackedInt32Array(), "signature_ids": PackedInt32Array(),
		"population": PackedInt64Array(), "funds": PackedInt64Array()}
	for cell in range(cells):
		packet.cell_indices.append(cell)
		packet.signature_ids.append((catalog.signature_keys as PackedStringArray).find("worker|default"))
		packet.population.append(100)
		packet.funds.append(money)
	_expect("ceiling population bootstraps", bool(ext.bootstrap_economy(packet, {}).get("ok", false)))
	return ext

func _test_ceiling_clock(source: Dictionary, period: int, money: int) -> void:
	var catalog := _ceiling_catalog(source)
	var ext := _ceiling_world(catalog, period, money)
	var max_days := 0
	var expanded := false
	var clean := true
	for day in range(41):
		var report := _run_price_day(ext, day)
		clean = clean and bool(report.get("done", false)) and not bool(report.get("fatal", true)) and int(report.get("money_error", 1)) == 0 and int(report.get("goods_error", 1)) == 0
		var snapshot: Dictionary = ext.get_market_cell_snapshot(0)
		var days: PackedInt32Array = snapshot.price_ceiling_confirmation_days
		var base: PackedInt32Array = snapshot.price_base_ceiling
		var target: PackedInt32Array = snapshot.price_target_ceiling
		for g in range(days.size()):
			max_days = maxi(max_days, days[g])
			if target[g] > base[g]: expanded = true
		if day == 28:
			_expect("no premature expansion before 30 actual days N=%d cash=%d" % [period, money], not expanded and max_days <= 29)
	_expect("ceiling daily settlement conserves ledgers N=%d cash=%d" % [period, money], clean)
	if money == 0:
		_expect("unfunded wishes never confirm or expand N=%d" % period, max_days == 0 and not expanded)
	else:
		_expect("funded persistent shortage confirms and expands N=%d" % period, max_days == 30 and expanded)
		if period == 1: _test_ceiling_save(ext, catalog)

func _test_ceiling_save(ext: Object, catalog: Dictionary) -> void:
	var chunks: Array[PackedByteArray] = []
	var country_chunks: Array[PackedByteArray] = []
	_expect("active ceiling country save starts", bool(ext.begin_country_save(4096).get("ok", false)))
	while true:
		var chunk: PackedByteArray = ext.read_country_save_chunk(4096)
		if chunk.is_empty(): break
		country_chunks.append(chunk)
	ext.end_country_save()
	_expect("active ceiling PKEC49 save starts", int(ext.begin_economy_save(4096).get("schema_version", 0)) == 49)
	while true:
		var chunk: PackedByteArray = ext.read_economy_save_chunk(4096)
		if chunk.is_empty(): break
		chunks.append(chunk)
	ext.end_economy_save()
	var restored: Object = _new_ext(1, 0.5)
	restored.configure_economy(catalog, _ceiling_profile(1), 1, 4901)
	restored.begin_country_restore()
	for chunk in country_chunks: restored.feed_country_restore_chunk(chunk)
	restored.end_country_restore()
	restored.begin_economy_restore()
	var accepted := true
	for chunk in chunks:
		var result: Dictionary = restored.feed_economy_restore_chunk(chunk)
		accepted = accepted and bool(result.get("ok", false))
		if not bool(result.get("ok", false)): print(result)
	var ended: Dictionary = restored.end_economy_restore()
	_expect("active sparse ceiling stream restores", accepted and bool(ended.get("ok", false)))
	_expect("active ceiling state hash roundtrips exactly", ext.get_economy_state_hash() == restored.get_economy_state_hash())
	_expect("active ceiling rows roundtrip", ext.get_market_cell_snapshot(0).price_target_ceiling == restored.get_market_cell_snapshot(0).price_target_ceiling)
	var legacy: Object = _new_ext(1, 0.5)
	legacy.configure_economy(catalog, _ceiling_profile(1), 1, 4901)
	legacy.begin_economy_restore()
	var header := chunks[0].duplicate()
	header[4] = 48
	var rejection: Dictionary = legacy.feed_economy_restore_chunk(header)
	_expect("PKEC48 requires a new game", rejection.get("reason", "") == "economy_save_price_v6_requires_new_game")

func _test_active_ceiling_workers(source: Dictionary) -> void:
	var catalog := _ceiling_catalog(source)
	var scalar := _ceiling_world(catalog, 1, 1000000000000, 8, false)
	var workers := _ceiling_world(catalog, 1, 1000000000000, 8, true)
	for day in range(36):
		_run_price_day(scalar, day)
		_run_price_day(workers, day)
	_expect("active ceiling worker/scalar authoritative hash identical",
		scalar.get_economy_state_hash() == workers.get_economy_state_hash())
	_expect("active ceiling worker/scalar event hash identical",
		int(scalar.get_economy_trace_report().get("stream_hash", 0)) ==
		int(workers.get_economy_trace_report().get("stream_hash", 1)))

func _test_substitute_credit(source: Dictionary) -> void:
	var catalog := _ceiling_catalog(source)
	for column in ["good_inventory_weight_q16", "good_shortage_weight_q16", "good_excess_demand_weight_q16", "good_cost_anchor_weight_q16", "good_inactive_reversion_weight_q16"]:
		if catalog.has(column):
			var zeros: PackedInt32Array = catalog[column].duplicate()
			zeros.fill(0)
			catalog[column] = zeros
	var ext := _ceiling_world(catalog, 1, 1000000000000)
	var goods: PackedStringArray = catalog.good_ids
	var amounts := {}
	for good in range(goods.size()):
		if goods[good] != "game_meat" and int(catalog.good_storage_modes[good]) == 0:
			amounts[goods[good]] = 100000000000
	ext.submit_economy_commands(_stock_commands(0, goods, amounts, 0))
	for day in range(36): _run_price_day(ext, day)
	var snapshot: Dictionary = ext.get_market_cell_snapshot(0)
	_expect("fulfilled substitutes do not expand missing game meat ceiling",
		_good_value(snapshot, "price", "game_meat") == _good_value(snapshot, "price_base_ceiling", "game_meat") and
		_good_value(snapshot, "price_target_ceiling", "game_meat") ==
		_good_value(snapshot, "price_base_ceiling", "game_meat") and
		_good_value(snapshot, "price_ceiling_confirmation_days", "game_meat") == 0)
