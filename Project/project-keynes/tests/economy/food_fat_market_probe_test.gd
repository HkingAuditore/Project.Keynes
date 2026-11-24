extends SceneTree

## gs_11 · food_fat 最小市场（v2）：冻结投资 + 算术未满足率
##
## 目的：测「油断供之后，引擎多快把份额让出去」这条迟滞，不靠任何聚合指标。
##
## v1（gs_09）的两个毛病，这一版修掉：
##   1. 投资系统自己盖楼（第 60/65 天各 4 座，第 66 天油坊出油）→ 冻结投资，并在
##      第一次出现食用油库存时自动截断，把污染日打出来。
##   2. 拿 `basic` 当脂肪指标 → 错。`basic` 是 10 个 tier-1 需求的聚合，这一格最差的那条
##      是 produce（果蔬），不是 food_fat。本版一律用算术：未满足率 = 1 - 实际成交/理论需求。
##
## 算术（全部用引擎自己发布的数，不引入任何假设）：
##   理论需求 fat_need = 油分配量 + 畜牧分配量            （demand_per_capita_daily × 人口）
##   实际满足 fat_met  = min(油分配, 油成交) + min(畜牧分配, 畜牧成交)
##   未满足率 unmet    = 1 - fat_met / fat_need
##   —— 成交（realized_withdrawal_ema）包含商家补库，所以用 min() 夹到分配量上，不会虚高。
##
## 用法：
##   godot --headless --path <project> --script res://tests/economy/food_fat_market_probe_test.gd -- days=90 population=20000
##
## 判读：油断供后 unmet_rate 当天就抬 → 问题在聚合/显示层；跟油价一起慢慢抬 → 迟滞是机制本身的。

const EconomyCatalogScript = preload("res://scripts/economy/economy_catalog.gd")
const CountryTestHelper = preload("res://tests/country/country_test_helper.gd")

const CELL := 0
const POPULATION := 20000
const DAYS := 90
const SEED := 2201
# 库存单位与 demand_per_capita_daily 同为 GOODS_SCALE（1000 = 1 单位）。
const FILL_STOCK := 500000000
const LIVESTOCK_STOCK := 500000000
const FUNDS := 1000000000000000

var _failures := 0
var _rows: Array[Dictionary] = []
var _days := DAYS
var _population := POPULATION
var _contaminated_day := -1
var _investments_total := 0


func _init() -> void:
	var args := _arguments()
	_days = maxi(1, int(args.get("days", DAYS)))
	_population = maxi(1, int(args.get("population", POPULATION)))

	var compiled: Dictionary = EconomyCatalogScript.compile_native_catalog()
	if not bool(compiled.get("ok", false)):
		push_error("[fat-market] catalog compile failed: %s" % str(compiled.get("reason", "")))
		quit(1)
		return
	var catalog := compiled.duplicate(true)
	catalog.erase("ok")
	var goods: PackedStringArray = compiled.good_ids

	var ext: Object = _new_ext(1)
	if not CountryTestHelper.configure_all_technologies(ext, catalog, 1, SEED):
		push_error("[fat-market] configure_all_technologies failed")
		quit(1)
		return
	var profile := _native_profile()
	if not bool(ext.configure_economy(catalog, profile, 1, SEED).get("ok", false)):
		push_error("[fat-market] configure_economy failed")
		quit(1)
		return

	var signature_key := "agricultural_worker|default"
	var signature: int = (compiled.signature_keys as PackedStringArray).find(signature_key)
	if signature < 0:
		for key in ["household_farmer|default", "fisher|default", "artisan|default"]:
			signature = (compiled.signature_keys as PackedStringArray).find(key)
			if signature >= 0:
				signature_key = key
				break
	_expect("signature with a two-variant food_fat plan exists (%s)" % signature_key, signature >= 0)
	if signature < 0:
		_finish()
		return

	_expect("country boots", bool(ext.bootstrap_economy({
		"cell_indices": PackedInt32Array([CELL]),
		"signature_ids": PackedInt32Array([signature]),
		"population": PackedInt64Array([_population]),
		"funds": PackedInt64Array([FUNDS]),
	}, {}).get("ok", false)))

	# 除食用油外全部管够；食用油零库存；畜牧产品有货。
	var amounts := {}
	for good_id in goods:
		var stable := String(good_id)
		if stable == "edible_oil":
			continue
		amounts[stable] = LIVESTOCK_STOCK if stable == "livestock_products" else FILL_STOCK
	if not amounts.is_empty():
		ext.submit_economy_commands(_stock_commands(CELL, goods, amounts, 0))

	print("[fat-market/setup] population=%d days=%d signature=%s oil_stock=0 livestock_stock=%d investment=frozen" % [
		_population, _days, signature_key, LIVESTOCK_STOCK])
	var boot_report: Dictionary = ext.get_economy_report()
	print("[fat-market/buildings_at_start] group_count=%s buildings=%s" % [
		str(boot_report.get("building_group_count", "?")),
		str(boot_report.get("building_count", "?"))])
	print("[fat-market/head] day fat_need fat_met unmet_rate oil_alloc oil_sold oil_stock oil_price oil_short meat_alloc meat_sold meat_stock meat_price buildings_invested building_groups building_investments_total")

	for day in range(_days):
		var report := _run_day(ext, day)
		if bool(report.get("fatal", false)):
			push_error("[fat-market] fatal at day %d" % day)
			break
		var pop: Dictionary = ext.get_population_cell_snapshot(CELL)
		var market: Dictionary = ext.get_market_cell_snapshot(CELL)
		var oil_alloc := _demand_total(pop, "edible_oil")
		var meat_alloc := _demand_total(pop, "livestock_products")
		var oil_sold := _good_value(market, "realized_withdrawal_ema", "edible_oil")
		var meat_sold := _good_value(market, "realized_withdrawal_ema", "livestock_products")
		var fat_need := oil_alloc + meat_alloc
		var fat_met := mini(oil_alloc, maxi(0, oil_sold)) + mini(meat_alloc, maxi(0, meat_sold))
		var unmet := 1.0 - float(fat_met) / float(fat_need) if fat_need > 0 else -1.0
		var oil_stock := _good_value(market, "stock", "edible_oil")
		var invested := int(report.get("building_investments_started", -1))
		# 建筑组数是「投资噪声」的唯一证据列：基线组和对照组必须逐日可比，
		# 否则两次运行的差异分不清是评分改了还是楼多盖了。get_economy_report() 是 const，只读。
		var groups := int(ext.get_economy_report().get("building_group_count", -1))
		_investments_total += maxi(0, invested)
		var row := {
			"day": day, "fat_need": fat_need, "fat_met": fat_met, "unmet": unmet,
			"oil_alloc": oil_alloc, "oil_sold": oil_sold, "oil_stock": oil_stock,
			"oil_price": _good_value(market, "price", "edible_oil"),
			"oil_short": _good_value(market, "shortage_q16", "edible_oil"),
			"meat_alloc": meat_alloc, "meat_sold": meat_sold,
			"meat_stock": _good_value(market, "stock", "livestock_products"),
			"meat_price": _good_value(market, "price", "livestock_products"),
			"invested": invested, "groups": groups, "investments_total": _investments_total,
		}
		# 油一旦有库存，说明有产油建筑投产，条件被污染：记下来并停。
		if oil_stock > 0 and _contaminated_day < 0:
			_contaminated_day = day
			print("[fat-market/contamination] day=%d oil_stock=%d —— 产油建筑投产，干净窗口到此为止" % [
				day, oil_stock])
		if _contaminated_day >= 0:
			break
		_rows.append(row)
		print("[fat-market] day=%-3d fat_need=%-8d fat_met=%-8d unmet=%-6.3f oil_alloc=%-8d oil_sold=%-7d oil_stock=%-5d oil_price=%-7d oil_short=%-6d meat_alloc=%-8d meat_sold=%-8d meat_stock=%-10d meat_price=%-6d invested=%d groups=%d total_inv=%d" % [
			day, fat_need, fat_met, unmet, oil_alloc, oil_sold, oil_stock,
			row.oil_price, row.oil_short, meat_alloc, meat_sold, row.meat_stock, row.meat_price, invested,
			groups, _investments_total])

	_judge()
	_finish()


func _judge() -> void:
	if _rows.size() < 2:
		print("[fat-market/verdict] 数据不足，无法判读")
		return
	var first: Dictionary = _rows[0]
	var last: Dictionary = _rows[_rows.size() - 1]
	var day_below_10 := -1
	var day_below_05 := -1
	for row in _rows:
		if float(row.unmet) < 0.10 and day_below_10 < 0:
			day_below_10 = int(row.day)
		if float(row.unmet) < 0.05 and day_below_05 < 0:
			day_below_05 = int(row.day)
	var invested := 0
	for row in _rows:
		invested += maxi(0, int(row.invested))
	print("[fat-market/summary] days=%d unmet %.3f -> %.3f | oil_alloc %d -> %d | oil_price %d -> %d | oil_sold_total=%d | 首次 unmet<10%% 在天 %d，<5%% 在天 %d | 投资新建建筑总数=%d | 建筑组数 %d -> %d | 污染日=%d" % [
		_rows.size(), float(first.unmet), float(last.unmet),
		int(first.oil_alloc), int(last.oil_alloc),
		int(first.oil_price), int(last.oil_price), _sum_rows("oil_sold"),
		day_below_10, day_below_05, invested, int(first.get("groups", -1)), int(last.get("groups", -1)),
		_contaminated_day])
	var early := 0
	for row in _rows:
		if int(row.day) <= 7 and absf(float(row.unmet) - float(first.unmet)) > 0.02:
			early += 1
	if early == 0:
		print("[fat-market/verdict] 前 7 天未满足率几乎不动（仍 %.3f）→ 断供当天完全不扣权重，迟滞在机制里" % float(first.unmet))
	else:
		print("[fat-market/verdict] 前 7 天未满足率确实在动（%d 天变化 >0.02），但注意：短缺第 0 天就已满格 65535，未满足率每天下降是被油价每天上行推的，不是库存当场扣权重。真正的迟滞看两个阈值日：<10%% 第 %d 天、<5%% 第 %d 天" % [
			early, day_below_10, day_below_05])
	if day_below_10 > 0:
		print("[fat-market/verdict] 结论：油从第 0 天起就完全买不到（库存 0 / 成交 0 / 短缺满格），引擎仍把 %.1f%% 的脂肪分配给它；把未满足率压到 10%% 以下用了 %d 天（油价 %d -> %d）。这就是迟滞长度。" % [
			float(first.unmet) * 100.0, day_below_10, int(first.oil_price), int(last.oil_price)])


func _sum_rows(key: String) -> int:
	var total := 0
	for row in _rows:
		total += int(row[key])
	return total


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
	# 冻结投资：回收期压到 1 天、成长/补缺份额压到 0。
	# 注意 investment_max_growth_share_q16 的导出区间是 1..65536，但原生端有一个
	# `<= 0` 的分支（economy_runtime_building_investment_candidates.cpp:441）；
	# 这里直接写 0 绕过编辑器区间校验，实测能把「新类型播种」也关掉。
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


func _expect(label: String, condition: bool) -> void:
	if condition:
		print("  [PASS] " + label)
		return
	_failures += 1
	print("  [FAIL] " + label)


func _finish() -> void:
	print("=== food fat market probe v2 %s ===" % ("PASS" if _failures == 0 else "FAIL"))
	quit(0 if _failures == 0 else 1)
