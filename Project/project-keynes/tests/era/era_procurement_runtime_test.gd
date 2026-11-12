extends SceneTree

## Era advancement native contract (docs/cpp-dots-runtime/era-advancement-runtime.md §2):
##  A. CONSUME_TREASURY_GOODS(21) + GRANT_TECHNOLOGY(4) commit atomically;
##     an insufficient consume rejects the whole batch (no era token).
##  B. National procurement policy + era target buy market stock into the
##     treasury through GOOD_FROM_MARKET, paying local merchants, booked as the
##     `era_procurement` non-tax outflow, with money/goods conservation.
##  C. A treasury consume landing inside a frozen economy epoch is a goods sink
##     (goods_error stays 0).

const EconomyCatalogScript = preload("res://scripts/economy/economy_catalog.gd")
const CountryFacadeScript = preload("res://scripts/country/country_facade.gd")
const EconomyFacadeScript = preload("res://scripts/economy/economy_facade.gd")

var _failures := 0

func _init() -> void:
	if not ClassDB.class_exists("DCWorldExt"):
		print("[SKIP] DCWorldExt unavailable")
		quit()
		return
	var compiled: Dictionary = EconomyCatalogScript.compile_native_catalog()
	_expect("catalog compiles", bool(compiled.get("ok", false)))
	_good_ids = compiled.good_ids
	_test_consume_atomicity(compiled)
	_test_era_procurement(compiled)
	print("era procurement runtime: %s" % ("PASS" if _failures == 0 else "FAIL"))
	quit(0 if _failures == 0 else 1)


func _test_consume_atomicity(compiled: Dictionary) -> void:
	var goods: PackedStringArray = compiled.good_ids
	var grain := goods.find("grain")
	var ext: Object = ClassDB.instantiate("DCWorldExt")
	ext.create_entities(1)
	var country = CountryFacadeScript.new()
	_expect("A: country configures", bool(country.configure(ext, 1, 7101,
		load("res://data/country/default_country.tres"), compiled).get("ok", false)))
	_expect("A: country bootstraps", bool(country.bootstrap(PackedByteArray([0]), {
		"country_ids": PackedStringArray(["country.era"]),
		"country_names": PackedStringArray(["Era"]),
		"country_cash": PackedInt64Array([1000000]),
		"territory_offsets": PackedInt32Array([0, 1]),
		"territory_cells": PackedInt32Array([0]),
		"technology_offsets": PackedInt32Array([0, 0]),
		"technology_indices": PackedInt32Array(),
		"treasury_offsets": PackedInt32Array([0, 1]),
		"treasury_good_indices": PackedInt32Array([grain]),
		"treasury_quantities": PackedInt64Array([5000]),
	}).get("ok", false)))
	var handle := int(country.cell_summary(0).country_handle)
	var milestones := CountryFacadeScript.era_milestone_indices()
	_expect("A: era milestone tokens exist", milestones.size() >= 2)
	if milestones.size() < 2:
		return
	var token := int(milestones[1])
	var token_id := StringName((compiled.technology_ids as PackedStringArray)[token])
	# Insufficient stock: the whole batch, including the era token, is rejected.
	_expect("A: oversized advance_era queues", bool(country.advance_era(handle, token_id,
		PackedInt32Array([grain]), PackedInt64Array([9000]), 1, 1).get("ok", false)))
	var rejected: Dictionary = ext.run_country_slice({"day_index": 1})
	var after_reject: Dictionary = ext.get_country_treasury_snapshot(handle)
	var research: Dictionary = country.research_snapshot(handle)
	_expect("A: insufficient treasury rejects the whole batch",
		not bool(rejected.get("ok", true))
		and String(rejected.get("fatal_reason", rejected.get("reason", ""))).contains(
			"country_treasury_goods_insufficient"))
	_expect("A: rejected batch leaves treasury and era token untouched",
		_treasury_quantity(after_reject, grain) == 5000
		and int((research.technology_states as PackedInt32Array)[token]) < 4)
	# Two consume lines on the same good are validated cumulatively.
	_expect("A: cumulative over-consume queues", bool(country.submit([
		{"opcode": CountryFacadeScript.Opcode.CONSUME_TREASURY_GOODS,
			"target_handle": handle, "technology": grain, "value": 3000,
			"effective_day": 2, "sequence": 1},
		{"opcode": CountryFacadeScript.Opcode.CONSUME_TREASURY_GOODS,
			"target_handle": handle, "technology": grain, "value": 3000,
			"effective_day": 2, "sequence": 1},
	]).get("ok", false)))
	var cumulative: Dictionary = ext.run_country_slice({"day_index": 2})
	_expect("A: staged batch deducts earlier consumes before validating later ones",
		not bool(cumulative.get("ok", true))
		and _treasury_quantity(ext.get_country_treasury_snapshot(handle), grain) == 5000)
	# Sufficient stock: goods leave the treasury and the token is granted together.
	_expect("A: valid advance_era queues", bool(country.advance_era(handle, token_id,
		PackedInt32Array([grain]), PackedInt64Array([3000]), 3, 1).get("ok", false)))
	var accepted: Dictionary = ext.run_country_slice({"day_index": 3})
	var after_accept: Dictionary = ext.get_country_treasury_snapshot(handle)
	research = country.research_snapshot(handle)
	_expect("A: consume + grant commit atomically",
		bool(accepted.get("ok", false))
		and _treasury_quantity(after_accept, grain) == 2000
		and int((research.technology_states as PackedInt32Array)[token]) >= 4)
	_expect("A: invalid good is rejected at admission", not bool(country.submit([
		{"opcode": CountryFacadeScript.Opcode.CONSUME_TREASURY_GOODS,
			"target_handle": handle, "technology": goods.size() + 5, "value": 1,
			"effective_day": 4, "sequence": 1}]).get("ok", true)))


func _test_era_procurement(compiled: Dictionary) -> void:
	var goods: PackedStringArray = compiled.good_ids
	var grain := goods.find("grain")
	var ext: Object = ClassDB.instantiate("DCWorldExt")
	ext.create_entities(1)
	_register_environment(ext)
	var country = CountryFacadeScript.new()
	_expect("B: country configures", bool(country.configure(ext, 1, 7102,
		load("res://data/country/default_country.tres"), compiled).get("ok", false)))
	_expect("B: country bootstraps", bool(country.bootstrap(PackedByteArray([0]), {
		"country_ids": PackedStringArray(["country.era_buyer"]),
		"country_names": PackedStringArray(["EraBuyer"]),
		"country_cash": PackedInt64Array([100000000]),
		"territory_offsets": PackedInt32Array([0, 1]),
		"territory_cells": PackedInt32Array([0]),
		"technology_offsets": PackedInt32Array([0, 0]),
		"technology_indices": PackedInt32Array(),
	}).get("ok", false)))
	var handle := int(country.cell_summary(0).country_handle)
	var native_catalog := compiled.duplicate(false)
	native_catalog.erase("ok")
	var profile: Dictionary = load("res://data/economy/default_economy.tres").to_native_profile()
	profile.market_cycle_days = 1
	profile.market_runtime_mode = "ACTIVE"
	_expect("B: economy configures", bool(ext.configure_economy(
		native_catalog, profile, 1, 7102).get("ok", false)))
	var economy = EconomyFacadeScript.new()
	economy._world_ext = ext
	economy._configured = true
	var merchant := (compiled.signature_keys as PackedStringArray).find("merchant|default")
	var stock := PackedInt64Array()
	stock.resize(goods.size())
	stock.fill(0)
	stock[grain] = 50000
	_expect("B: merchant market bootstraps", bool(ext.bootstrap_economy({
		"cell_indices": PackedInt32Array([0]),
		"signature_ids": PackedInt32Array([merchant]),
		"population": PackedInt64Array([10]),
		"funds": PackedInt64Array([0]),
	}, {"stock": stock}).get("ok", false)))
	_expect("B: policy queues", bool(economy.set_country_procurement_policy(
		handle, true, 5000, 0, 0, 1).get("ok", false)))
	_expect("B: era target queues", bool(economy.set_era_procurement_target(
		handle, true, PackedInt32Array([grain]), PackedInt64Array([4000]), 0, 2).get("ok", false)))
	var pending: Dictionary = economy.country_procurement_snapshot(handle)
	_expect("B: snapshot shows requested policy before the epoch applies it",
		bool(pending.get("ok", false)) and bool(pending.get("policy_enabled", false))
		and int(pending.get("treasury_share_bp", 0)) == 5000
		and bool(pending.get("era_active", false))
		and (pending.get("era_goods", []) as Array).size() == 1)
	var before_cash := int(country.snapshot(handle).cash)
	var merchant_income_before := _merchant_epoch_income(ext)
	var report := _run_day(ext, 0)
	var after_cash := int(country.snapshot(handle).cash)
	var bought := _treasury_quantity(ext.get_country_treasury_snapshot(handle), grain)
	var snapshot: Dictionary = economy.country_procurement_snapshot(handle)
	if bought <= 0:
		print("  era procurement diagnostic=", {"report_stage": report.get("stage"),
			"fatal": report.get("fatal"), "reason": report.get("fatal_reason"),
			"snapshot": snapshot})
	_expect("B: day completes without fatal",
		bool(report.get("done", false)) and not bool(report.get("fatal", false)))
	_expect("B: era procurement buys market stock into the treasury",
		bought > 0 and bought <= 4000 and after_cash < before_cash)
	_expect("B: conservation holds",
		int(report.get("money_error", 1)) == 0 and int(report.get("goods_error", 1)) == 0
		and int(report.get("population_error", 1)) == 0)
	var spent := before_cash - after_cash
	_expect("B: treasury cash reaches local merchants",
		_merchant_epoch_income(ext) - merchant_income_before >= spent)
	var lines: Array = snapshot.get("era_goods", [])
	_expect("B: snapshot reports budget split and progress",
		bool(snapshot.get("ok", false))
		and int(snapshot.get("national_daily_budget", 0)) == before_cash / 2
		and int(snapshot.get("research_daily_budget", -1)) == 0
		and int(snapshot.get("era_daily_budget", 0)) == int(snapshot.get("other_daily_budget", -1))
		and int(snapshot.get("era_cash_spent_total", 0)) == spent
		and lines.size() == 1
		and int((lines[0] as Dictionary).get("treasury_stock", -1)) == bought
		and int((lines[0] as Dictionary).get("purchased_total", -1)) == bought
		and snapshot.has("trade_orders_total"))
	var fiscal: Dictionary = country.fiscal_snapshot(handle)
	var kinds: PackedStringArray = fiscal.get("non_tax_outflow_kinds", PackedStringArray())
	var values: PackedInt64Array = fiscal.get("non_tax_outflow", PackedInt64Array())
	var era_slot := kinds.find("era_procurement")
	_expect("B: fiscal batch books era procurement as a non-tax outflow",
		era_slot == 4 and era_slot < values.size() and int(values[era_slot]) == spent)
	# C. Treasury consume inside a frozen epoch is a goods sink.
	var in_flight: Dictionary = ext.run_economy_slice({"day_index": 1, "tick_index": 1000})
	var mid_epoch := not bool(in_flight.get("done", false))
	_expect("C: era consume queues", bool(country.submit([
		{"opcode": CountryFacadeScript.Opcode.CONSUME_TREASURY_GOODS,
			"target_handle": handle, "technology": grain, "value": mini(bought, 1000),
			"effective_day": 1, "sequence": 1}]).get("ok", false)) and bought > 0)
	_expect("C: era consume commits", bool(ext.run_country_slice(
		{"day_index": 1}).get("ok", false)))
	var closing := _run_day(ext, 1)
	if not mid_epoch:
		print("  [NOTE] C: economy day closed in one slice; sink checked at the next epoch")
		closing = _run_day(ext, 2)
	_expect("C: consumed treasury goods are an audited sink",
		bool(closing.get("done", false)) and not bool(closing.get("fatal", false))
		and int(closing.get("goods_error", 1)) == 0
		and int(closing.get("money_error", 1)) == 0)
	# Pause clears the target; already purchased goods stay in the treasury.
	_expect("B: pause queues", bool(economy.set_era_procurement_target(
		handle, false, PackedInt32Array(), PackedInt64Array(), 3, 3).get("ok", false)))
	var stock_before_pause := _treasury_quantity(ext.get_country_treasury_snapshot(handle), grain)
	var paused := _run_day(ext, 3)
	_expect("B: paused target buys nothing and refunds nothing",
		bool(paused.get("done", false))
		and _treasury_quantity(ext.get_country_treasury_snapshot(handle), grain) == stock_before_pause
		and not bool(economy.country_procurement_snapshot(handle).get("era_active", true)))


var _good_ids := PackedStringArray()

func _treasury_quantity(snapshot: Dictionary, good: int) -> int:
	var ids: PackedStringArray = snapshot.get("good_ids", PackedStringArray())
	var quantities: PackedInt64Array = snapshot.get("quantities", PackedInt64Array())
	var wanted := String(_good_ids[good]) if good >= 0 and good < _good_ids.size() else ""
	for i in range(mini(ids.size(), quantities.size())):
		if String(ids[i]) == wanted:
			return int(quantities[i])
	return 0


func _merchant_epoch_income(ext: Object) -> int:
	var snapshot: Dictionary = ext.get_population_cell_snapshot(0)
	var flags: PackedByteArray = snapshot.get("merchant_flags", PackedByteArray())
	var incomes: PackedInt64Array = snapshot.get("epoch_income_by_cohort", PackedInt64Array())
	var total := 0
	for index in range(mini(flags.size(), incomes.size())):
		if int(flags[index]) != 0:
			total += int(incomes[index])
	return total


func _run_day(ext: Object, day: int) -> Dictionary:
	var report := {}
	for slice in range(512):
		report = ext.run_economy_slice({"day_index": day, "tick_index": day * 1000 + slice})
		if bool(report.get("done", false)) or bool(report.get("fatal", false)):
			return report
	return report


func _register_environment(ext: Object) -> void:
	for slot_name in [&"cell_temp", &"cell_temp_30d", &"cell_moisture",
			&"cell_plant_available_water", &"cell_weather_precip", &"cell_snow_cover",
			&"cell_weather_intensity", &"cell_elevation", &"cell_temp_365d"]:
		var sid := int(ext.register_component(slot_name, 0, 1, false))
		ext.write_f32_range(sid, 0, PackedFloat32Array([0.5]))
	for slot_name in [&"cell_terrain", &"cell_landform", &"cell_vegetation",
			&"cell_is_water", &"cell_has_river", &"cell_weather_type", &"cell_cover"]:
		var sid := int(ext.register_component(slot_name, 2, 1, false))
		ext.write_u8_range(sid, 0, PackedByteArray([0]))


func _expect(label: String, condition: bool) -> void:
	if condition:
		print("  [PASS] %s" % label)
	else:
		_failures += 1
		push_error("[FAIL] %s" % label)
