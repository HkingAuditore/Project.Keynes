extends SceneTree

const EconomyCatalogScript = preload("res://scripts/economy/economy_catalog.gd")
const CountryTestHelper = preload("res://tests/country_test_helper.gd")

var _failures := 0

func _init() -> void:
	_run()
	print("=== economy cadence runtime %s ===" % ("PASS" if _failures == 0 else "FAIL"))
	quit(0 if _failures == 0 else 1)

func _expect(label: String, condition: bool) -> void:
	print("  [%s] %s" % ["PASS" if condition else "FAIL", label])
	if not condition:
		_failures += 1

func _run() -> void:
	if not ClassDB.class_exists("DCWorldExt"):
		print("  [SKIP] DCWorldExt unavailable")
		return
	var compiled: Dictionary = EconomyCatalogScript.compile_native_catalog()
	_expect("catalog compiles", bool(compiled.get("ok", false)))
	if not bool(compiled.get("ok", false)):
		return
	_test_opening_daily(compiled)
	_test_injected_mid_and_wide(compiled)
	_test_mid_cycle_lock_holds(compiled)
	_test_no_missed_cells_on_n3(compiled)
	_test_sparse_live_workset(compiled)
	_test_save_restore_keeps_buckets(compiled)

func _test_opening_daily(compiled: Dictionary) -> void:
	var ext := _boot(compiled, 1, 0.01, 0.01, 11)
	var report := _run_day(ext, 0)
	var plan_days := int(report.get("locked_plan_cycle_days", 0))
	var invest_days := int(report.get("locked_investment_cycle_days", 0))
	_expect("opening one-cell world locks N=1, P near 5, and I > P",
		int(report.get("locked_market_cycle_days", 0)) == 1 and
		plan_days >= 5 and plan_days <= 10 and
		invest_days > plan_days and invest_days >= 10 and
		int(report.get("locked_slow_cycle_days", 0)) == plan_days and
		int(report.get("market_max_cycle_days", 0)) == 5)
	_expect("opening cell settles on sample day",
		bool(report.get("done", false)) and not bool(report.get("fatal", false)) and
		int(report.get("newest_state_day", -2)) == 0 and
		int(report.get("money_error", 1)) == 0 and int(report.get("goods_error", 1)) == 0)
	report = _run_day(ext, 1)
	_expect("second day still daily with injected fast timing",
		int(report.get("locked_market_cycle_days", 0)) == 1 and
		int(report.get("newest_state_day", -2)) == 1)
	var market_ms := float(report.get("cadence_market_ms_per_knife", 0.0))
	var last_market := float(report.get("last_completed_building_employment_ms", 0.0)) \
		+ float(report.get("last_completed_building_production_ms", 0.0)) \
		+ float(report.get("last_completed_household_market_prepare_ms", 0.0)) \
		+ float(report.get("last_completed_household_market_merge_ms", 0.0)) \
		+ float(report.get("last_completed_aggregate_publish_ms", 0.0))
	_expect("cadence knife ms stays on completed-COMMIT order of magnitude",
		market_ms <= 0.0 or last_market <= 0.0 or market_ms < maxf(8.0, last_market * 8.0))

func _test_injected_mid_and_wide(compiled: Dictionary) -> void:
	var mid := _boot(compiled, 64, 20.0, 20.0, 21)
	var mid_boot: Dictionary = mid.get_economy_report()
	_expect("injected medium timing lands in 2–4",
		int(mid_boot.get("locked_market_cycle_days", 0)) >= 2 and
		int(mid_boot.get("locked_market_cycle_days", 0)) <= 4)
	var wide := _boot(compiled, 64, 1000000.0, 1000000.0, 22, {
		"investment_cells_per_slice": 1,
		"building_plan_cells_per_slice": 1,
	})
	var wide_boot: Dictionary = wide.get_economy_report()
	print("  [info] heavy lock N=%s P=%s I=%s knives=%s plan_knives=%s invest_knives=%s" % [
		wide_boot.get("locked_market_cycle_days", -1),
		wide_boot.get("locked_plan_cycle_days", -1),
		wide_boot.get("locked_investment_cycle_days", -1),
		wide_boot.get("cadence_populated_knives", -1),
		wide_boot.get("cadence_plan_knives", -1),
		wide_boot.get("cadence_investment_knives", -1)])
	var plan_days := int(wide_boot.get("locked_plan_cycle_days", 0))
	var invest_days := int(wide_boot.get("locked_investment_cycle_days", 0))
	_expect("injected heavy timing locks N=5, I near 30, and I > P",
		int(wide_boot.get("locked_market_cycle_days", 0)) == 5 and
		plan_days >= 5 and plan_days <= 15 and
		invest_days > plan_days and invest_days >= 20)

func _test_mid_cycle_lock_holds(compiled: Dictionary) -> void:
	var ext := _boot(compiled, 10, 1000000.0, 1000000.0, 31)
	_expect("forced five-day lock at bootstrap",
		int(ext.get_economy_report().get("locked_market_cycle_days", 0)) == 5)
	var before_plan := int(ext.get_economy_report().get("locked_plan_cycle_days", 0))
	var before_invest := int(ext.get_economy_report().get("locked_investment_cycle_days", 0))
	ext.inject_economy_cadence_timing(0.01, 0.01)
	var day1 := _run_day(ext, 1)
	_expect("timing inject does not change N/P/I inside the cycle",
		int(day1.get("locked_market_cycle_days", 0)) == 5 and
		int(day1.get("market_cycle_start_day", -1)) == 0 and
		int(day1.get("locked_plan_cycle_days", 0)) == before_plan and
		int(day1.get("locked_investment_cycle_days", 0)) == before_invest)

func _test_no_missed_cells_on_n3(compiled: Dictionary) -> void:
	var ext := _boot(compiled, 9, 20.0, 20.0, 41)
	var n := int(ext.get_economy_report().get("locked_market_cycle_days", 0))
	_expect("nine-cell fixture uses a 2–4 day lock", n >= 2 and n <= 4)
	var seen := {}
	for day in range(n):
		var report := _run_day(ext, day)
		_expect("day %d conserves" % day,
			int(report.get("money_error", 1)) == 0 and
			int(report.get("goods_error", 1)) == 0 and
			not bool(report.get("fatal", false)))
		seen[day] = int(report.get("due_cells", 0))
	var total := 0
	for day in seen.keys():
		total += int(seen[day])
	_expect("one cycle covers every populated cell once", total == 9)
	var hash_a: int = ext.get_economy_state_hash()
	var twin := _boot(compiled, 9, 20.0, 20.0, 41)
	for day in range(n):
		_run_day(twin, day)
	_expect("injected timing makes N/P/I sequence repeatable",
		hash_a == twin.get_economy_state_hash())


func _test_sparse_live_workset(compiled: Dictionary) -> void:
	var ext := _boot_sparse(compiled, 12, [0, 4, 8], 0.01, 0.01, 71)
	var live: PackedInt32Array = ext.get_economy_live_cells()
	_expect("sparse fixture exposes three live cells", live.size() == 3)
	var n := int(ext.get_economy_report().get("locked_market_cycle_days", 0))
	_expect("sparse fixture still locks a 1-5 market cycle", n >= 1 and n <= 5)
	var total := 0
	for day in range(n):
		var report := _run_day(ext, day)
		_expect("sparse day %d conserves" % day,
			int(report.get("money_error", 1)) == 0 and
			int(report.get("goods_error", 1)) == 0 and
			not bool(report.get("fatal", false)))
		total += int(report.get("due_cells", -1))
		_expect("sparse due_cells stay inside the live set",
			int(report.get("due_cells", -1)) <= 3 and
			int(report.get("economy_live_cells", 0)) == 3)
	_expect("one market cycle due_cells sum equals live cells, not cell_count",
		total == 3)


func _test_save_restore_keeps_buckets(compiled: Dictionary) -> void:
	var ext := _boot(compiled, 10, 1000000.0, 1000000.0, 51)
	_run_day(ext, 0)
	_run_day(ext, 1)
	var before_n := int(ext.get_economy_report().get("locked_market_cycle_days", 0))
	var before_start := int(ext.get_economy_report().get("market_cycle_start_day", -1))
	var before_plan := int(ext.get_economy_report().get("locked_plan_cycle_days", 0))
	var before_plan_start := int(ext.get_economy_report().get("plan_cycle_start_day", -1))
	var before_invest := int(ext.get_economy_report().get("locked_investment_cycle_days", 0))
	var before_invest_start := int(ext.get_economy_report().get("investment_cycle_start_day", -1))
	var country_begin: Dictionary = ext.begin_country_save(4096)
	_expect("PKCN save begins", bool(country_begin.get("ok", false)))
	var country_chunks: Array[PackedByteArray] = []
	while true:
		var country_chunk: PackedByteArray = ext.read_country_save_chunk(4096)
		if country_chunk.is_empty():
			break
		country_chunks.append(country_chunk)
	_expect("PKCN save completes", bool(ext.end_country_save().get("ok", false)))
	var before_hash: int = ext.get_economy_state_hash()
	var begin: Dictionary = ext.begin_economy_save(65536)
	_expect("v41 save begins", bool(begin.get("ok", false)) and
		int(begin.get("schema_version", 0)) == 41)
	var chunks: Array[PackedByteArray] = []
	while true:
		var chunk: PackedByteArray = ext.read_economy_save_chunk(65536)
		if chunk.is_empty():
			break
		chunks.append(chunk)
	_expect("v41 save completes", bool(ext.end_economy_save().get("ok", false)))
	var restored := _new_ext(10)
	var catalog := compiled.duplicate(true)
	catalog.erase("ok")
	CountryTestHelper.configure_all_technologies(restored, catalog, 10, 51)
	_expect("PKCN restore matches", _restore_country(restored, country_chunks))
	restored.configure_economy(catalog, _profile(), 10, 51)
	restored.begin_economy_restore()
	for chunk in chunks:
		restored.feed_economy_restore_chunk(chunk)
	var end: Dictionary = restored.end_economy_restore()
	_expect("v41 restore keeps locked cadence",
		bool(end.get("ok", false)) and
		int(restored.get_economy_report().get("locked_market_cycle_days", 0)) == before_n and
		int(restored.get_economy_report().get("market_cycle_start_day", -2)) == before_start and
		int(restored.get_economy_report().get("locked_plan_cycle_days", 0)) == before_plan and
		int(restored.get_economy_report().get("plan_cycle_start_day", -2)) == before_plan_start and
		int(restored.get_economy_report().get("locked_investment_cycle_days", 0)) == before_invest and
		int(restored.get_economy_report().get("investment_cycle_start_day", -2)) == before_invest_start and
		restored.get_economy_state_hash() == before_hash)

func _restore_country(ext: Object, chunks: Array) -> bool:
	if not bool(ext.begin_country_restore().get("ok", false)):
		return false
	for value in chunks:
		if not bool(ext.feed_country_restore_chunk(
				value as PackedByteArray).get("ok", false)):
			return false
	return bool(ext.end_country_restore().get("ok", false))

func _boot(compiled: Dictionary, cells: int, market_ms: float, slow_ms: float,
		seed: int, extra: Dictionary = {}) -> Object:
	var ext := _new_ext(cells)
	var catalog := compiled.duplicate(true)
	catalog.erase("ok")
	var profile := _profile()
	for key in extra.keys():
		profile[key] = extra[key]
	_expect("cadence fixture country bootstraps",
		CountryTestHelper.configure_all_technologies(ext, catalog, cells, seed))
	_expect("cadence fixture configures",
		bool(ext.configure_economy(catalog, profile, cells, seed).get("ok", false)))
	ext.inject_economy_cadence_timing(market_ms, slow_ms)
	var signature: int = (compiled.signature_keys as PackedStringArray).find(
		"merchant|default")
	var cell_indices := PackedInt32Array()
	var signatures := PackedInt32Array()
	var populations := PackedInt64Array()
	var funds := PackedInt64Array()
	for cell in range(cells):
		cell_indices.append(cell)
		signatures.append(signature)
		populations.append(20)
		funds.append(100000000)
	var boot: Dictionary = ext.bootstrap_economy({
		"cell_indices": cell_indices,
		"signature_ids": signatures,
		"population": populations,
		"funds": funds,
	}, {})
	_expect("cadence fixture bootstraps", bool(boot.get("ok", false)))
	return ext


func _boot_sparse(compiled: Dictionary, cells: int, live_cells: Array, market_ms: float,
		slow_ms: float, seed: int) -> Object:
	var ext := _new_ext(cells)
	var catalog := compiled.duplicate(true)
	catalog.erase("ok")
	var profile := _profile()
	_expect("sparse cadence fixture country bootstraps",
		CountryTestHelper.configure_all_technologies(ext, catalog, cells, seed))
	_expect("sparse cadence fixture configures",
		bool(ext.configure_economy(catalog, profile, cells, seed).get("ok", false)))
	ext.inject_economy_cadence_timing(market_ms, slow_ms)
	var signature: int = (compiled.signature_keys as PackedStringArray).find(
		"merchant|default")
	var cell_indices := PackedInt32Array()
	var signatures := PackedInt32Array()
	var populations := PackedInt64Array()
	var funds := PackedInt64Array()
	for cell in live_cells:
		cell_indices.append(int(cell))
		signatures.append(signature)
		populations.append(20)
		funds.append(100000000)
	var boot: Dictionary = ext.bootstrap_economy({
		"cell_indices": cell_indices,
		"signature_ids": signatures,
		"population": populations,
		"funds": funds,
	}, {})
	_expect("sparse cadence fixture bootstraps", bool(boot.get("ok", false)))
	return ext


func _profile() -> Dictionary:
	var profile: Dictionary = load(
		"res://data/economy/default_economy.tres").to_native_profile()
	profile.market_runtime_mode = "ACTIVE"
	profile.market_cycle_days = 5
	profile.market_min_cycle_days = 1
	profile.market_max_cycle_days = 5
	profile.economy_cadence_target_ms = 8.0
	return profile

func _new_ext(cells: int) -> Object:
	var ext: Object = ClassDB.instantiate("DCWorldExt")
	ext.create_entities(cells)
	var climate := PackedFloat32Array()
	climate.resize(cells)
	climate.fill(0.5)
	for slot_name in [&"cell_temp", &"cell_temp_30d", &"cell_moisture",
			&"cell_plant_available_water", &"cell_weather_precip", &"cell_snow_cover",
			&"cell_weather_intensity", &"cell_elevation"]:
		var sid: int = ext.register_component(slot_name, 0, 1, false)
		ext.write_f32_range(sid, 0, climate)
	var zeros := PackedByteArray()
	zeros.resize(cells)
	zeros.fill(0)
	for slot_name in [&"cell_terrain", &"cell_landform", &"cell_vegetation",
			&"cell_is_water", &"cell_has_river"]:
		var sid: int = ext.register_component(slot_name, 2, 1, false)
		ext.write_u8_range(sid, 0, zeros)
	return ext

func _run_day(ext: Object, day: int) -> Dictionary:
	var report := {}
	for slice in range(256):
		report = ext.run_economy_slice({
			"day_index": day, "tick_index": day * 1000 + slice})
		if bool(report.get("done", false)) or bool(report.get("fatal", false)):
			return report
	return report
