extends SceneTree

## gs_13 自检 · 家户缺油时，引擎自带的那条「按库存替代」回退到底有没有生效？
##
## 背景：economy_runtime_market.cpp:1924-1988 有一段 fallback：
##   主篮子清不掉（!primary_inventory_abundant）时，把未满足量按「有库存的变体」重分配。
## 如果它生效，那 `food_fat_market_probe_test.gd` 量到的「未满足率 0.636」就只是
## **主篮子分配比例**，不是家户真的没吃到脂肪。
##
## 做法：同样的 fixture 跑两遍，只差食用油库存
##   A: oil_stock = 0      → 主篮子会失败，应当触发回退
##   B: oil_stock = 5 亿   → 主篮子成功，不触发回退
## 若两边的满足度维度**相同** → 回退把缺口补上了，之前的未满足率是测量假象；
## 若 A 明显低于 B → 回退没补上，未满足率是真的。
##
## 用法：
##   godot --headless --path <project> --script res://tests/economy/food_fat_fallback_check_test.gd -- days=6

const EconomyCatalogScript = preload("res://scripts/economy/economy_catalog.gd")
const CountryTestHelper = preload("res://tests/country/country_test_helper.gd")

const CELL := 0
const POPULATION := 20000
const DAYS := 6
const SEED := 2201
const FILL_STOCK := 500000000
const FUNDS := 1000000000000000

var _days := DAYS


func _init() -> void:
	var args := _arguments()
	_days = maxi(1, int(args.get("days", DAYS)))
	print("[fallback-check] days=%d population=%d seed=%d" % [_days, POPULATION, SEED])
	for scenario in [
		{"tag": "A_oil0", "oil": 0, "meat": FILL_STOCK},
		{"tag": "B_oil_full", "oil": FILL_STOCK, "meat": FILL_STOCK},
		{"tag": "C_neither", "oil": 0, "meat": 0},
	]:
		_run(String(scenario.tag), int(scenario.oil), int(scenario.meat))
	quit(0)


func _run(tag: String, oil_stock: int, meat_stock: int) -> void:
	var compiled: Dictionary = EconomyCatalogScript.compile_native_catalog()
	if not bool(compiled.get("ok", false)):
		push_error("[fallback-check] catalog compile failed")
		return
	var catalog := compiled.duplicate(true)
	catalog.erase("ok")
	var goods: PackedStringArray = compiled.good_ids
	var ext: Object = _new_ext(1)
	if not CountryTestHelper.configure_all_technologies(ext, catalog, 1, SEED):
		push_error("[fallback-check] configure_all_technologies failed")
		return
	if not bool(ext.configure_economy(catalog, _native_profile(), 1, SEED).get("ok", false)):
		push_error("[fallback-check] configure_economy failed")
		return
	var signature_key := "agricultural_worker|default"
	var signature: int = (compiled.signature_keys as PackedStringArray).find(signature_key)
	if signature < 0:
		push_error("[fallback-check] signature missing")
		return
	if not bool(ext.bootstrap_economy({
		"cell_indices": PackedInt32Array([CELL]),
		"signature_ids": PackedInt32Array([signature]),
		"population": PackedInt64Array([POPULATION]),
		"funds": PackedInt64Array([FUNDS]),
	}, {}).get("ok", false)):
		push_error("[fallback-check] bootstrap failed")
		return

	var amounts := {}
	for good_id in goods:
		var stable := String(good_id)
		if stable == "edible_oil":
			amounts[stable] = oil_stock
		elif stable == "livestock_products":
			amounts[stable] = meat_stock
		else:
			amounts[stable] = FILL_STOCK
	if not amounts.is_empty():
		ext.submit_economy_commands(_stock_commands(CELL, goods, amounts, 0))

	print("[fallback-check] === scenario %s (oil_stock=%d meat_stock=%d) ===" % [tag, oil_stock, meat_stock])
	print("[fallback-check/head] day | oil_alloc meat_alloc oil_sold meat_sold oil_price | composite worst_dim worst_need | dims[0..7]")
	for day in range(_days):
		var report := _run_day(ext, day)
		if bool(report.get("fatal", false)):
			print("[fallback-check] fatal at day %d" % day)
			break
		var pop: Dictionary = ext.get_population_cell_snapshot(CELL)
		var market: Dictionary = ext.get_market_cell_snapshot(CELL)
		var oil_alloc := _demand_total(pop, "edible_oil")
		var meat_alloc := _demand_total(pop, "livestock_products")
		var oil_sold := _good_value(market, "realized_withdrawal_ema", "edible_oil")
		var meat_sold := _good_value(market, "realized_withdrawal_ema", "livestock_products")
		var oil_price := _good_value(market, "price", "edible_oil")
		var oil_stock_now := _good_value(market, "stock", "edible_oil")
		var oil_short := _good_value(market, "shortage_q16", "edible_oil")
		var meat_stock_now := _good_value(market, "stock", "livestock_products")
		var meat_short := _good_value(market, "shortage_q16", "livestock_products")
		var dims := PackedInt32Array()
		var composite := -1
		var worst_dim := -1
		var worst_need := -1
		var handles: PackedInt64Array = pop.get("handles", PackedInt64Array())
		if handles.size() > 0:
			var explained: Dictionary = ext.explain_cohort_satisfaction(int(handles[0]))
			if bool(explained.get("ok", false)):
				dims = explained.get("dim_values_q16", PackedInt32Array())
				composite = int(explained.get("composite_q16", -1))
				worst_dim = int(explained.get("worst_dimension_id", -1))
				worst_need = int(explained.get("worst_need_id", -1))
		var dim_text := ""
		for i in range(dims.size()):
			dim_text += "%d " % int(dims[i])
		print("[fallback-check] day=%-2d oil_alloc=%-8d meat_alloc=%-8d oil_sold=%-7d meat_sold=%-8d oil_price=%-7d oil_stock=%-10d oil_short=%-6d meat_stock=%-10d meat_short=%-6d composite=%-6d worst_dim=%-2d worst_need=%-3d dims=[%s]" % [
			day, oil_alloc, meat_alloc, oil_sold, meat_sold, oil_price,
			oil_stock_now, oil_short, meat_stock_now, meat_short, composite,
			worst_dim, worst_need, dim_text.strip_edges()])


func _demand_total(snapshot: Dictionary, good_id: String) -> int:
	var ids: PackedStringArray = snapshot.get("demand_good_stable_ids", PackedStringArray())
	var target := ids.find(good_id)
	if target < 0:
		return 0
	var offsets: PackedInt32Array = snapshot.get("demand_good_offsets", PackedInt32Array())
	var indices: PackedInt32Array = snapshot.get("demand_good_indices", PackedInt32Array())
	var quantities: PackedInt64Array = snapshot.get("demand_per_capita_daily", PackedInt64Array())
	var populations: PackedInt64Array = snapshot.get("populations", PackedInt64Array())
	var total := 0
	for cohort in range(populations.size()):
		if cohort + 1 >= offsets.size():
			break
		for cursor in range(int(offsets[cohort]), int(offsets[cohort + 1])):
			if cursor < indices.size() and cursor < quantities.size() and indices[cursor] == target:
				total += int(quantities[cursor]) * int(populations[cohort])
	return total


func _good_value(snapshot: Dictionary, column: String, good_id: String) -> int:
	var ids: PackedStringArray = snapshot.get("good_ids", PackedStringArray())
	var idx: int = ids.find(good_id)
	var values = snapshot.get(column, [])
	return int(values[idx]) if idx >= 0 and idx < values.size() else -1


func _run_day(ext: Object, day: int) -> Dictionary:
	var report: Dictionary = {}
	for slice in range(128):
		report = ext.run_economy_slice({"day_index": day, "tick_index": slice})
		if bool(report.get("done", false)):
			return report
	return report


func _arguments() -> Dictionary:
	var out := {}
	for raw in OS.get_cmdline_user_args():
		var item := str(raw)
		var split := item.find("=")
		if split > 0:
			out[item.substr(0, split)] = item.substr(split + 1)
	return out


func _native_profile() -> Dictionary:
	var profile = load("res://data/economy/default_economy.tres")
	var out: Dictionary = profile.to_native_profile()
	out.worker_enabled = false
	out.worker_market_threshold = 1
	out.worker_tasks_hint = 0
	out.market_runtime_mode = "ACTIVE"
	out.market_cycle_days = 1
	out.trade_runtime_mode = "OFF"
	out.investment_max_payback_days = 1
	out.investment_operating_cycles = 1
	out.investment_max_growth_share_q16 = 0
	out.investment_gap_fill_share_q16 = 0
	out.investment_new_type_seed_buildings = 1
	out.investment_displacement_min_advantage_q16 = 65536
	out.investment_merchant_transition_min_improvement_q16 = 65536
	return out


func _stock_commands(cell: int, goods: PackedStringArray, amounts: Dictionary,
		effective_day: int, sequence_base: int = 0) -> Dictionary:
	var count := amounts.size()
	var batch := {"opcodes": PackedInt32Array(), "effective_days": PackedInt64Array(),
		"sequences": PackedInt64Array(), "target_handles": PackedInt64Array(),
		"i32_0": PackedInt32Array(), "i32_1": PackedInt32Array(),
		"i64_0": PackedInt64Array(), "i64_1": PackedInt64Array()}
	var keys := amounts.keys()
	keys.sort()
	for i in range(count):
		var good_id: String = String(keys[i])
		batch.opcodes.append(4)
		batch.effective_days.append(effective_day)
		batch.sequences.append(sequence_base + i)
		batch.target_handles.append(0)
		batch.i32_0.append(cell)
		batch.i32_1.append(goods.find(good_id))
		batch.i64_0.append(int(amounts[good_id]))
		batch.i64_1.append(0)
	return batch


func _new_ext(cells: int) -> Object:
	var ext: Object = ClassDB.instantiate("DCWorldExt")
	ext.create_entities(cells)
	var temperate := PackedFloat32Array()
	temperate.resize(cells)
	temperate.fill(1.0)
	var zero_f := PackedFloat32Array()
	zero_f.resize(cells)
	zero_f.fill(0.0)
	for slot_name in [&"cell_temp", &"cell_temp_30d"]:
		var sid: int = ext.register_component(slot_name, 0, 1, false)
		ext.write_f32_range(sid, 0, temperate)
	for slot_name in [&"cell_moisture", &"cell_plant_available_water", &"cell_weather_precip",
			&"cell_snow_cover", &"cell_weather_intensity", &"cell_elevation", &"cell_temp_365d"]:
		var sid: int = ext.register_component(slot_name, 0, 1, false)
		ext.write_f32_range(sid, 0, zero_f)
	var terrain := PackedByteArray()
	terrain.resize(cells)
	terrain.fill(2)
	var landform := PackedByteArray()
	landform.resize(cells)
	landform.fill(LandformType.LF.PLAIN)
	var vegetation := PackedByteArray()
	vegetation.resize(cells)
	vegetation.fill(VegetationType.VEG.TEMPERATE_GRASSLAND)
	var zeros_u8 := PackedByteArray()
	zeros_u8.resize(cells)
	zeros_u8.fill(0)
	ext.write_u8_range(ext.register_component(&"cell_terrain", 2, 1, false), 0, terrain)
	ext.write_u8_range(ext.register_component(&"cell_landform", 2, 1, false), 0, landform)
	ext.write_u8_range(ext.register_component(&"cell_vegetation", 2, 1, false), 0, vegetation)
	ext.write_u8_range(ext.register_component(&"cell_is_water", 2, 1, false), 0, zeros_u8)
	ext.write_u8_range(ext.register_component(&"cell_has_river", 2, 1, false), 0, zeros_u8)
	ext.write_u8_range(ext.register_component(&"cell_weather_type", 2, 1, false), 0, zeros_u8)
	ext.write_u8_range(ext.register_component(&"cell_cover", 2, 1, false), 0, zeros_u8)
	return ext
