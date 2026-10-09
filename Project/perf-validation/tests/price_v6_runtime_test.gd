extends "res://tests/price_v5_runtime_test.gd"

func _run() -> void:
	print("=== Price V6 numeric-guard regression ===")
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
		_test_unbounded_rise(catalog, period, 1000000000000)
		_test_unbounded_rise(catalog, period, 0)
	_test_substitute_credit(catalog)
	_test_worker_scalar_parity(catalog)
	_finish()

func _guard_catalog(source: Dictionary) -> Dictionary:
	var catalog := source.duplicate(true)
	# Keep authored reference_max tiny so a rise past it proves the cap is non-binding.
	catalog.good_reference_max_price = (catalog.good_default_price as PackedInt32Array).duplicate()
	return catalog

func _guard_profile(period: int, workers: bool = false) -> Dictionary:
	var profile := _native_profile(workers, 1)
	profile.market_cycle_days = period
	profile.market_min_cycle_days = period
	profile.market_max_cycle_days = period
	profile.starvation_death_rate_q32 = 0
	profile.trade_runtime_mode = "OFF"
	return profile

func _guard_world(catalog: Dictionary, period: int, money: int, cells: int = 1, workers: bool = false) -> Object:
	var ext: Object = _new_ext(cells, 0.5)
	_expect("guard country configured", CountryTestHelper.configure_all_technologies(ext, catalog, cells, 4901))
	_expect("guard economy configured", bool(ext.configure_economy(catalog, _guard_profile(period, workers), cells, 4901).get("ok", false)))
	ext.inject_economy_cadence_timing(0.01, 0.01)
	var packet := {"cell_indices": PackedInt32Array(), "signature_ids": PackedInt32Array(),
		"population": PackedInt64Array(), "funds": PackedInt64Array()}
	for cell in range(cells):
		packet.cell_indices.append(cell)
		packet.signature_ids.append((catalog.signature_keys as PackedStringArray).find("worker|default"))
		packet.population.append(100)
		packet.funds.append(money)
	_expect("guard population bootstraps", bool(ext.bootstrap_economy(packet, {}).get("ok", false)))
	return ext

func _test_unbounded_rise(source: Dictionary, period: int, money: int) -> void:
	var catalog := _guard_catalog(source)
	var ext := _guard_world(catalog, period, money)
	var clean := true
	var rose_past_reference := false
	var max_confirm := 0
	var expanded := false
	var base_ok := true
	for day in range(41):
		var report := _run_price_day(ext, day)
		clean = clean and bool(report.get("done", false)) and not bool(report.get("fatal", true)) and int(report.get("money_error", 1)) == 0 and int(report.get("goods_error", 1)) == 0
		var snapshot: Dictionary = ext.get_market_cell_snapshot(0)
		var prices: PackedInt32Array = snapshot.price
		var refs: PackedInt32Array = snapshot.price_reference_ceiling
		var base: PackedInt32Array = snapshot.price_base_ceiling
		var target: PackedInt32Array = snapshot.price_target_ceiling
		var days: PackedInt32Array = snapshot.price_ceiling_confirmation_days
		for g in range(prices.size()):
			if base[g] != 2147483647:
				base_ok = false
			max_confirm = maxi(max_confirm, days[g])
			if target[g] > base[g]:
				expanded = true
			if money > 0 and prices[g] > refs[g]:
				rose_past_reference = true
	_expect("base ceiling is numeric guard only N=%d cash=%d" % [period, money], base_ok)
	_expect("settlement conserves ledgers N=%d cash=%d" % [period, money], clean)
	_expect("no sparse economic ceiling expansion N=%d cash=%d" % [period, money],
		max_confirm == 0 and not expanded)
	if money > 0:
		_expect("funded shortage can price above authored reference_max N=%d" % period, rose_past_reference)
		if period == 1:
			_test_save_roundtrip(ext, catalog)
	else:
		_expect("unfunded wishes do not invent ceiling state N=%d" % period, max_confirm == 0)

func _test_save_roundtrip(ext: Object, catalog: Dictionary) -> void:
	var country_chunks: Array[PackedByteArray] = []
	_expect("numeric-guard country save starts", bool(ext.begin_country_save(4096).get("ok", false)))
	while true:
		var chunk: PackedByteArray = ext.read_country_save_chunk(4096)
		if chunk.is_empty(): break
		country_chunks.append(chunk)
	ext.end_country_save()
	_expect("ECP2 capture API is bound",
		ext.has_method("capture_economy_ecp2") and ext.has_method("restore_economy_ecp2"))
	var ecp2_capture: Dictionary = ext.capture_economy_ecp2(0)
	_expect("ECP2 save captures OwnedState",
		bool(ecp2_capture.get("ok", false)) and
		str(ecp2_capture.get("format", "")) == "ECP2" and
		int(ecp2_capture.get("schema_version", 0)) == 53)
	var ecp2_bytes: PackedByteArray = ecp2_capture.get("bytes", PackedByteArray())
	_expect("ECP2 payload is non-empty", not ecp2_bytes.is_empty())
	var restored: Object = _new_ext(1, 0.5)
	_expect("restore country configures first",
		CountryTestHelper.configure_all_technologies(restored, catalog, 1, 4901))
	_expect("PKCN restore begins", bool(restored.begin_country_restore().get("ok", false)))
	for chunk in country_chunks:
		_expect("PKCN chunk accepted", bool(restored.feed_country_restore_chunk(chunk).get("ok", false)))
	_expect("PKCN restore completes", bool(restored.end_country_restore().get("ok", false)))
	_expect("restore economy configures",
		bool(restored.configure_economy(catalog, _guard_profile(1), 1, 4901).get("ok", false)))
	var ecp2_restore: Dictionary = restored.restore_economy_ecp2(ecp2_bytes)
	_expect("ECP2 restore completes", bool(ecp2_restore.get("ok", false)))
	if not bool(ecp2_restore.get("ok", false)):
		print("  ECP2 restore rejected=", ecp2_restore)
	_expect("state hash roundtrips exactly", ext.get_economy_state_hash() == restored.get_economy_state_hash())
	_expect("ceiling rows roundtrip",
		ext.get_market_cell_snapshot(0).price_target_ceiling == restored.get_market_cell_snapshot(0).price_target_ceiling)
	var legacy: Object = _new_ext(1, 0.5)
	CountryTestHelper.configure_all_technologies(legacy, catalog, 1, 4901)
	legacy.configure_economy(catalog, _guard_profile(1), 1, 4901)
	var pkec_rejection: Dictionary = legacy.restore_economy_ecp2(PackedByteArray([0x50, 0x4B, 0x45, 0x43, 0, 0, 0, 0]))
	_expect("bare PKEC payload is rejected",
		not bool(pkec_rejection.get("ok", true)) and
		str(pkec_rejection.get("reason", "")) == "restore_rejects_pkec")

func _test_worker_scalar_parity(source: Dictionary) -> void:
	var catalog := _guard_catalog(source)
	var scalar := _guard_world(catalog, 1, 1000000000000, 8, false)
	var workers := _guard_world(catalog, 1, 1000000000000, 8, true)
	for day in range(36):
		_run_price_day(scalar, day)
		_run_price_day(workers, day)
	_expect("worker/scalar authoritative hash identical",
		scalar.get_economy_state_hash() == workers.get_economy_state_hash())
	_expect("worker/scalar event hash identical",
		int(scalar.get_economy_trace_report().get("stream_hash", 0)) ==
		int(workers.get_economy_trace_report().get("stream_hash", 1)))

func _test_substitute_credit(source: Dictionary) -> void:
	var catalog := _guard_catalog(source)
	for column in ["good_inventory_weight_q16", "good_shortage_weight_q16", "good_excess_demand_weight_q16", "good_cost_anchor_weight_q16", "good_inactive_reversion_weight_q16"]:
		if catalog.has(column):
			var zeros: PackedInt32Array = catalog[column].duplicate()
			zeros.fill(0)
			catalog[column] = zeros
	var ext := _guard_world(catalog, 1, 1000000000000)
	var goods: PackedStringArray = catalog.good_ids
	var amounts := {}
	for good in range(goods.size()):
		if goods[good] != "game_meat" and int(catalog.good_storage_modes[good]) == 0:
			amounts[goods[good]] = 100000000000
	ext.submit_economy_commands(_stock_commands(0, goods, amounts, 0))
	for day in range(36): _run_price_day(ext, day)
	var snapshot: Dictionary = ext.get_market_cell_snapshot(0)
	_expect("fulfilled substitutes leave missing game meat without ceiling state",
		_good_value(snapshot, "price_ceiling_confirmation_days", "game_meat") == 0 and
		_good_value(snapshot, "price_target_ceiling", "game_meat") ==
		_good_value(snapshot, "price_base_ceiling", "game_meat"))
