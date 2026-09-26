extends SceneTree

# Focused regression for own-shelf shortage attribution.
const EconomyCatalogScript = preload("res://scripts/economy/economy_catalog.gd")
const CountryTestHelper = preload("res://tests/country_test_helper.gd")

var _checks := 0
var _failures := 0

func _init() -> void:
	print("=== complement shortage attribution test ===")
	if not ClassDB.class_exists("DCWorldExt"):
		print("  [SKIP] DCWorldExt unavailable")
		quit(1)
		return
	var catalog: Dictionary = EconomyCatalogScript.compile_native_catalog()
	_expect("catalog compiles", bool(catalog.get("ok", false)))
	if not bool(catalog.get("ok", false)):
		quit(1)
		return
	var stable := catalog.duplicate(true)
	var births: PackedInt64Array = stable.signature_birth_rate_q32
	var deaths: PackedInt64Array = stable.signature_death_rate_q32
	for i in range(births.size()):
		births[i] = 0
		deaths[i] = 0
	stable.signature_birth_rate_q32 = births
	stable.signature_death_rate_q32 = deaths
	_test_complement_shortage_stays_on_binding_good(stable)
	print("checks=%d failures=%d" % [_checks, _failures])
	quit(0 if _failures == 0 else 1)

func _test_complement_shortage_stays_on_binding_good(compiled: Dictionary) -> void:
	var goods: PackedStringArray = compiled.good_ids
	var survival := {
		"gathered_plants": 5000000,
		"game_meat": 5000000,
		"cloth": 2000000,
		"fur": 2000000,
		"logs": 2000000,
	}
	var abundant_lumber := survival.duplicate()
	abundant_lumber["lumber"] = 5000000
	for gid in ["turf_block", "reed_bundle", "bast_fiber", "adobe_brick", "bricks",
			"lime", "raw_stone", "cement", "glass", "steel", "concrete",
			"construction_components"]:
		abundant_lumber[gid] = 0
	var glut: Object = _configured_price_worker(compiled, 1911)
	glut.submit_economy_commands(_stock_commands(0, goods, abundant_lumber, 0))
	var glut_report: Dictionary = {}
	for day in range(25):
		glut_report = _run_price_day(glut, day)
	var glut_market: Dictionary = glut.get_market_cell_snapshot(0)
	var lumber_demand := _good_value(glut_market, "demand_ema", "lumber")
	var lumber_shortage := _good_value(glut_market, "shortage_q16", "lumber")
	var turf_demand := _good_value(glut_market, "demand_ema", "turf_block")
	var turf_shortage := _good_value(glut_market, "shortage_q16", "turf_block")
	print("  glut lumber dem=%d short=%d stock=%d | turf dem=%d short=%d" % [
		lumber_demand, lumber_shortage, _good_value(glut_market, "stock", "lumber"),
		turf_demand, turf_shortage])
	_expect("complement fixture conserves ledgers",
		int(glut_report.get("population_error", 1)) == 0 and
		int(glut_report.get("money_error", 1)) == 0 and
		int(glut_report.get("goods_error", 1)) == 0)
	_expect("housing still funds a lumber-bearing complement bundle",
		lumber_demand > 0)
	_expect("abundant lumber keeps own-shelf shortage at zero",
		lumber_shortage == 0)
	_expect("binding turf keeps high own-shelf shortage",
		turf_demand > 0 and turf_shortage >= 32768)
	_expect("abundant lumber stock remains available to households",
		_good_value(glut_market, "household_available_stock", "lumber") > 1000000)

	var scarce_lumber := survival.duplicate()
	scarce_lumber["lumber"] = 0
	scarce_lumber["turf_block"] = 5000000
	for gid in ["reed_bundle", "bast_fiber", "adobe_brick", "bricks", "lime",
			"raw_stone", "cement", "glass", "steel", "concrete",
			"construction_components"]:
		scarce_lumber[gid] = 0
	var bind: Object = _configured_price_worker(compiled, 1912)
	bind.submit_economy_commands(_stock_commands(0, goods, scarce_lumber, 0))
	var bind_report: Dictionary = {}
	for day in range(25):
		bind_report = _run_price_day(bind, day)
	var bind_market: Dictionary = bind.get_market_cell_snapshot(0)
	print("  bind lumber dem=%d short=%d | turf dem=%d short=%d stock=%d" % [
		_good_value(bind_market, "demand_ema", "lumber"),
		_good_value(bind_market, "shortage_q16", "lumber"),
		_good_value(bind_market, "demand_ema", "turf_block"),
		_good_value(bind_market, "shortage_q16", "turf_block"),
		_good_value(bind_market, "stock", "turf_block")])
	_expect("binding lumber fixture conserves ledgers",
		int(bind_report.get("population_error", 1)) == 0 and
		int(bind_report.get("money_error", 1)) == 0 and
		int(bind_report.get("goods_error", 1)) == 0)
	_expect("missing lumber reports own-shelf shortage",
		_good_value(bind_market, "demand_ema", "lumber") > 0 and
		_good_value(bind_market, "shortage_q16", "lumber") >= 32768)
	_expect("abundant turf does not inherit complement shortage",
		_good_value(bind_market, "shortage_q16", "turf_block") == 0)

func _configured_price_worker(compiled: Dictionary, seed: int) -> Object:
	var ext: Object = ClassDB.instantiate("DCWorldExt")
	ext.create_entities(1)
	var climate := PackedFloat32Array([0.5])
	var zero_f := PackedFloat32Array([0.0])
	for slot_name in [&"cell_temp", &"cell_temp_30d"]:
		var sid: int = ext.register_component(slot_name, 0, 1, false)
		ext.write_f32_range(sid, 0, climate)
	for slot_name in [&"cell_moisture", &"cell_plant_available_water", &"cell_weather_precip",
			&"cell_snow_cover", &"cell_weather_intensity", &"cell_elevation"]:
		var sid: int = ext.register_component(slot_name, 0, 1, false)
		ext.write_f32_range(sid, 0, zero_f)
	var terrain := PackedByteArray([2])
	var sid_t: int = ext.register_component(&"cell_terrain", 2, 1, false)
	ext.write_u8_range(sid_t, 0, terrain)
	var catalog := compiled.duplicate(true)
	catalog.erase("ok")
	_expect("price-response country bootstraps",
		CountryTestHelper.configure_all_technologies(ext, catalog, 1, seed))
	var profile = load("res://data/economy/default_economy.tres").to_native_profile()
	profile.worker_enabled = false
	profile.worker_market_threshold = 1
	profile.starvation_death_rate_q32 = 0
	profile.market_runtime_mode = "ACTIVE"
	profile.market_cycle_days = 5
	profile.market_min_cycle_days = 5
	profile.market_max_cycle_days = 5
	_expect("price-response economy configures",
		bool(ext.configure_economy(catalog, profile, 1, seed).get("ok", false)))
	ext.inject_economy_cadence_timing(1000000.0, 1000000.0)
	var signature: int = (compiled.signature_keys as PackedStringArray).find("worker|default")
	var boot: Dictionary = ext.bootstrap_economy({
		"cell_indices": PackedInt32Array([0]),
		"signature_ids": PackedInt32Array([signature]),
		"population": PackedInt64Array([100]),
		"funds": PackedInt64Array([100000000]),
	}, {})
	_expect("price-response population bootstraps", bool(boot.get("ok", false)))
	return ext

func _stock_commands(cell: int, goods: PackedStringArray, amounts: Dictionary,
		effective_day: int) -> Dictionary:
	var batch := {"opcodes": PackedInt32Array(), "effective_days": PackedInt64Array(),
		"sequences": PackedInt64Array(), "target_handles": PackedInt64Array(),
		"i32_0": PackedInt32Array(), "i32_1": PackedInt32Array(),
		"i64_0": PackedInt64Array(), "i64_1": PackedInt64Array()}
	var keys := amounts.keys()
	keys.sort()
	for i in range(keys.size()):
		var good_id: String = String(keys[i])
		batch.opcodes.append(4)
		batch.effective_days.append(effective_day)
		batch.sequences.append(i)
		batch.target_handles.append(0)
		batch.i32_0.append(cell)
		batch.i32_1.append(goods.find(good_id))
		batch.i64_0.append(int(amounts[good_id]))
		batch.i64_1.append(0)
	return batch

func _run_price_day(ext: Object, day: int) -> Dictionary:
	var report: Dictionary = {}
	for slice in range(65536):
		report = ext.run_economy_slice({"day_index": day, "tick_index": slice})
		if bool(report.get("done", false)) or bool(report.get("fatal", false)):
			return report
	return report

func _good_value(snapshot: Dictionary, column: String, good_id: String) -> int:
	var ids: PackedStringArray = snapshot.good_ids
	var idx: int = ids.find(good_id)
	var values = snapshot.get(column, [])
	return int(values[idx]) if idx >= 0 else -1

func _expect(label: String, ok: bool) -> void:
	_checks += 1
	if ok:
		print("  [PASS] ", label)
	else:
		_failures += 1
		print("  [FAIL] ", label)
