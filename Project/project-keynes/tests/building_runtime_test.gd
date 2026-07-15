extends SceneTree

const EconomyCatalogScript = preload("res://scripts/economy/economy_catalog.gd")
const CountryTestHelper = preload("res://tests/country_test_helper.gd")

var failures := 0

func _init() -> void:
	_run()
	quit(0 if failures == 0 else 1)

func _expect(label: String, condition: bool) -> void:
	print("  [%s] %s" % ["PASS" if condition else "FAIL", label])
	if not condition:
		failures += 1

func _run() -> void:
	print("=== native building runtime test ===")
	var compiled := EconomyCatalogScript.compile_native_catalog()
	_expect("building catalog compiles", bool(compiled.get("ok", false)))
	if not bool(compiled.get("ok", false)):
		print(compiled)
		return
	var building_ids: PackedStringArray = compiled.building_type_ids
	_expect("coal mine type exists", building_ids.has("coal_mine"))
	var ext := _new_ext(compiled)
	var catalog := compiled.duplicate(true)
	catalog.erase("ok")
	var mine_id := building_ids.find("coal_mine")
	var output_offsets: PackedInt32Array = catalog.building_output_offsets
	var output_quantities: PackedInt64Array = catalog.building_output_quantities
	output_quantities[int(output_offsets[mine_id])] = 100000
	catalog.building_output_quantities = output_quantities
	var profile = load("res://data/economy/default_economy.tres").to_native_profile()
	profile.market_cycle_days = 1
	profile.market_runtime_mode = "ACTIVE"
	_test_production_income_consumption_order(catalog, profile)
	_test_scarce_output_cost_floor(catalog, profile)
	_expect("all-technology test country bootstraps",
		CountryTestHelper.configure_all_technologies(ext, catalog, 1, 77))
	_expect("building runtime configures", bool(ext.configure_economy(catalog, profile, 1, 77).get("ok", false)))
	var landlord_sig: int = (compiled.signature_keys as PackedStringArray).find("industrialist|default")
	var worker_sig: int = (compiled.signature_keys as PackedStringArray).find("miner|default")
	var manager_sig: int = (compiled.signature_keys as PackedStringArray).find("manager|default")
	var merchant_sig: int = (compiled.signature_keys as PackedStringArray).find("merchant|default")
	var goods: PackedStringArray = compiled.good_ids
	var stock := PackedInt64Array()
	stock.resize(goods.size())
	stock.fill(100000)
	var boot: Dictionary = ext.bootstrap_economy({
		"cell_indices": PackedInt32Array([0, 0, 0, 0]),
		"signature_ids": PackedInt32Array([landlord_sig, worker_sig, manager_sig, merchant_sig]),
		"population": PackedInt64Array([5, 100, 10, 10]),
		"funds": PackedInt64Array([10000000, 1000000, 1000000, 10000000]),
	}, {"stock": stock})
	_expect("building population bootstraps", bool(boot.get("ok", false)))
	var untracked_pop: Dictionary = ext.get_population_cell_snapshot(0)
	_expect("untracked settlement detail is unavailable",
		not bool(untracked_pop.get("settlement_detail_available", false)))
	_expect("inspector trace target registers", bool(
		ext.set_economy_inspector_trace_cell(0).get("ok", false)))
	var pending_pop: Dictionary = ext.get_population_cell_snapshot(0)
	_expect("new inspector trace reports pending until commit",
		bool(pending_pop.get("settlement_detail_pending", false)))
	var pop: Dictionary = ext.get_population_cell_snapshot(0)
	var owner_handle := _handle_for_profession(pop, landlord_sig)
	_expect("industrialist owner handle exists", owner_handle != 0)
	var submit: Dictionary = ext.submit_economy_commands({
		"opcodes": PackedInt32Array([10]),
		"effective_days": PackedInt64Array([0]),
		"sequences": PackedInt64Array([1]),
		"target_handles": PackedInt64Array([owner_handle]),
		"i32_0": PackedInt32Array([0]),
		"i32_1": PackedInt32Array([mine_id]),
		"i64_0": PackedInt64Array([1]),
		"i64_1": PackedInt64Array([0]),
	})
	_expect("build command accepted", bool(submit.get("ok", false)))
	var day0 := _run_day(ext, 0)
	_expect("construction cycle commits", bool(day0.get("done", false)) and not bool(day0.get("fatal", false)))
	var buildings: Dictionary = ext.get_building_cell_snapshot(0)
	_expect("mine completes at cycle boundary", int((buildings.building_counts_by_type as PackedInt64Array)[mine_id]) == 1)
	var day1 := _run_day(ext, 1)
	_expect("production cycle conserves population", int(day1.get("population_error", 1)) == 0)
	_expect("production cycle conserves money", int(day1.get("money_error", 1)) == 0)
	_expect("production cycle conserves market goods", int(day1.get("goods_error", 1)) == 0)
	buildings = ext.get_building_cell_snapshot(0)
	_expect("building snapshot reports one-day production period", int(buildings.get("period_days", 0)) == 1)
	_expect("owner job filled", int((buildings.filled_owner as PackedInt64Array)[0]) == 1)
	var planned_utilization := int((buildings.planned_utilization_q16 as PackedInt32Array)[0])
	var filled_by_role: PackedInt64Array = buildings.employee_filled
	var filled_jobs := int(filled_by_role[0]) + int(filled_by_role[1])
	_expect("losses no longer reduce planned utilization",
		planned_utilization == 65536 and filled_jobs > 0 and filled_jobs <= 20)
	_expect("mine produces output", int((buildings.last_output as PackedInt64Array)[0]) > 0)
	_expect("merchant buys at least part of output", int((buildings.last_sold as PackedInt64Array)[0]) > 0)
	_expect("merchant procurement freezes a 25 percent reserve and stays in budget",
		int(day1.get("merchant_procurement_reserved", 0)) > 0 and
		int(day1.get("merchant_procurement_budget", 0)) >=
			int(day1.get("merchant_procurement_spent", -1)) and
		int(day1.get("merchant_procurement_budget", 0)) >=
			int(day1.get("merchant_procurement_reserved", 0)) * 2)
	var retained_output := int((buildings.last_retained as PackedInt64Array)[0])
	_expect("owner consumes retained output before the remainder reaches merchants",
		retained_output > 0 and
		int(day1.get("production_output_retained", 0)) == retained_output and
		int(day1.get("owner_output_consumed", 0)) == retained_output)
	_expect("building output reconciles sale, owner retention, and discard",
		int((buildings.last_output as PackedInt64Array)[0]) ==
			int((buildings.last_sold as PackedInt64Array)[0]) + retained_output +
			int((buildings.last_discarded as PackedInt64Array)[0]))
	var contract_wages: PackedInt64Array = buildings.employee_contract_wages_per_day
	var base_living: PackedInt64Array = buildings.employee_base_living_cost_per_day
	var role_living: PackedInt64Array = buildings.employee_role_living_cost_per_day
	var base_paid_by_role: PackedInt64Array = buildings.employee_base_wage_paid
	var bonus_paid_by_role: PackedInt64Array = buildings.employee_bonus_paid
	var bonus_due_by_role: PackedInt64Array = buildings.employee_bonus_due
	var base_wages := int(base_paid_by_role[0]) + int(base_paid_by_role[1])
	var bonus_paid := int(bonus_paid_by_role[0]) + int(bonus_paid_by_role[1])
	var bonus_due := int(bonus_due_by_role[0]) + int(bonus_due_by_role[1])
	_expect("adaptive contract wages respect each role living floor",
		int(contract_wages[0]) >= maxi(int(base_living[0]), int(role_living[0])) and
		int(contract_wages[1]) >= maxi(int(base_living[1]), int(role_living[1])) and
		int(contract_wages[0]) > 0 and int(contract_wages[1]) > 0)
	_expect("building snapshot separates base wage and bonus",
		base_wages == int(filled_by_role[0]) * int(contract_wages[0]) +
			int(filled_by_role[1]) * int(contract_wages[1]) and
		int((buildings.last_wages_paid as PackedInt64Array)[0]) == base_wages + bonus_paid)
	var base_operating_cost := int((buildings.last_input_cost as PackedInt64Array)[0]) + base_wages
	var target_profit := int((base_operating_cost * 6554) / 65536)
	var excess_profit := maxi(0,
		int((buildings.last_revenue as PackedInt64Array)[0]) - base_operating_cost - target_profit)
	var expected_bonus := int((excess_profit * 16384) / 65536)
	var payroll_suspended := int((buildings.wage_suspended as PackedByteArray)[0]) != 0
	_expect("owner-lot bonus is exact after fully funded base payroll",
		bonus_due == (0 if payroll_suspended else expected_bonus) and bonus_paid == bonus_due)
	_expect("building snapshot reports priced tool input cost",
		int((buildings.last_input as PackedInt64Array)[0]) > 0 and
		int((buildings.last_input_cost as PackedInt64Array)[0]) > 0)
	pop = ext.get_population_cell_snapshot(0)
	var worker_row := _row_for_signature(pop, worker_sig)
	var manager_row := _row_for_signature(pop, manager_sig)
	var landlord_row := _row_for_signature(pop, landlord_sig)
	var merchant_row := _row_for_signature(pop, merchant_sig)
	_expect("worker cohort has real employee count", worker_row >= 0 and
		int((pop.employee_employed_by_cohort as PackedInt64Array)[worker_row]) > 0)
	var expected_wages := base_wages + bonus_paid
	_expect("adaptive wages reach worker and manager cohorts", worker_row >= 0 and manager_row >= 0 and
		int((pop.epoch_income_by_cohort as PackedInt64Array)[worker_row]) ==
			int(base_paid_by_role[0]) + int(bonus_paid_by_role[0]) and
		int((pop.epoch_income_by_cohort as PackedInt64Array)[manager_row]) ==
			int(base_paid_by_role[1]) + int(bonus_paid_by_role[1]))
	_expect("owner expense includes base payroll and bonus", landlord_row >= 0 and
		int((pop.epoch_expense_by_cohort as PackedInt64Array)[landlord_row]) >= expected_wages)
	_expect("committed settlement cashflow detail is available",
		bool(pop.get("settlement_detail_available", false)) and
		int(pop.get("settlement_period_days", 0)) == 1)
	_expect("worker cashflow sources reconcile to epoch ledger",
		_cashflow_total_for_row(pop, worker_row, true) ==
		int((pop.epoch_income_by_cohort as PackedInt64Array)[worker_row]) and
		_cashflow_total_for_row(pop, worker_row, false) ==
		int((pop.epoch_expense_by_cohort as PackedInt64Array)[worker_row]))
	_expect("manager cashflow sources reconcile to epoch ledger",
		_cashflow_total_for_row(pop, manager_row, true) ==
		int((pop.epoch_income_by_cohort as PackedInt64Array)[manager_row]) and
		_cashflow_total_for_row(pop, manager_row, false) ==
		int((pop.epoch_expense_by_cohort as PackedInt64Array)[manager_row]))
	_expect("owner cashflow sources reconcile to epoch ledger",
		_cashflow_total_for_row(pop, landlord_row, true) ==
		int((pop.epoch_income_by_cohort as PackedInt64Array)[landlord_row]) and
		_cashflow_total_for_row(pop, landlord_row, false) ==
		int((pop.epoch_expense_by_cohort as PackedInt64Array)[landlord_row]))
	_expect("settlement classifies wages and owner operations",
		_cashflow_has_source(pop, worker_row, "wages", true) and
		_cashflow_has_source(pop, manager_row, "wages", true) and
		_cashflow_has_source(pop, landlord_row, "owner_operations", true) and
		_cashflow_has_source(pop, landlord_row, "owner_wages", false))
	var merchant_household := _cashflow_has_source(pop, merchant_row, "merchant_household_sales", true)
	var merchant_procurement := _cashflow_has_source(pop, merchant_row, "merchant_procurement", false)
	_expect("settlement classifies merchant household and procurement flows",
		merchant_household and merchant_procurement)
	_expect("wage report is exact and fully funded",
		int(day1.get("building_wages_paid", -1)) == expected_wages and
		int(day1.get("building_wages_unpaid", -1)) == 0)
	var market: Dictionary = ext.get_market_cell_snapshot(0)
	_expect("sold coal enters local stock", _good_value(market, "stock", "coal") > 0)
	_expect("price v3 publishes sparse coal supply and cost anchor",
		_good_value(market, "offered_supply_ema", "coal") > 0 and
		_good_i32_value(market, "cost_anchor_price", "coal") > 0)
	_expect("market publishes realized withdrawals and merchant inventory targets",
		(market.realized_withdrawal_ema as PackedInt64Array).size() ==
			(market.good_ids as PackedStringArray).size() and
		_good_value(market, "merchant_inventory_target", "coal") > 0 and
		_has_positive(market.realized_withdrawal_ema as PackedInt64Array))
	_expect("building snapshot publishes economic cost diagnostics",
		int((buildings.last_wages_due as PackedInt64Array)[0]) >= base_wages and
		int((buildings.last_operating_cost as PackedInt64Array)[0]) >= expected_wages and
		int((buildings.last_expected_revenue as PackedInt64Array)[0]) > 0)
	var resource_extra_slots: PackedStringArray = compiled.building_resource_extra_slots
	var coal_resource: int = (compiled.building_resource_ids as PackedStringArray).find("coal")
	var extra_sid: int = ext.component_id(StringName(resource_extra_slots[coal_resource]))
	var extra_values: PackedFloat32Array = ext.snapshot_f32(extra_sid)
	_expect("resource extraction publishes negative extra delta", extra_values.size() == 1 and extra_values[0] < 0.0)
	_expect("extractive building reports no generated resource",
		int((buildings.last_resource_generated as PackedInt64Array)[0]) == 0)
	_expect("building snapshot exposes current and effective resource reserves",
		(buildings.building_resource_current_reserve as PackedInt64Array).size() ==
		(compiled.building_resource_ids as PackedStringArray).size() and
		(buildings.building_resource_effective_reserve as PackedInt64Array).size() ==
		(compiled.building_resource_ids as PackedStringArray).size())
	_expect("building snapshot stays committed", bool(buildings.get("committed", false)))
	var funded_output := int((buildings.last_output as PackedInt64Array)[0])
	var discarded_output := int((buildings.last_discarded as PackedInt64Array)[0])
	pop = ext.get_population_cell_snapshot(0)
	landlord_row = _row_for_signature(pop, landlord_sig)
	var owner_funds := int((pop.funds_by_cohort as PackedInt64Array)[landlord_row])
	var drain: Dictionary = ext.submit_economy_commands({
		"opcodes": PackedInt32Array([9]),
		"effective_days": PackedInt64Array([2]),
		"sequences": PackedInt64Array([2]),
		"target_handles": PackedInt64Array([owner_handle]),
		"i32_0": PackedInt32Array([0]),
		"i32_1": PackedInt32Array([0]),
		"i64_0": PackedInt64Array([owner_funds]),
		"i64_1": PackedInt64Array([0]),
	})
	_expect("owner cash drain command accepted", bool(drain.get("ok", false)))
	var day2 := _run_day(ext, 2)
	buildings = ext.get_building_cell_snapshot(0)
	var day2_base_paid: PackedInt64Array = buildings.employee_base_wage_paid
	var day2_base_due: PackedInt64Array = buildings.employee_base_wage_due
	var day2_paid_total := 0
	var day2_due_total := 0
	for value in day2_base_paid:
		day2_paid_total += int(value)
	for value in day2_base_due:
		day2_due_total += int(value)
	_expect("zero owner cash cannot fund payroll",
		day2_paid_total == 0 and day2_due_total > 0)
	var constrained_intent := int(
		(buildings.purchase_intent_capacity_q16 as PackedInt64Array)[0])
	_expect("unsold output lowers the next active production plan",
		discarded_output > 0 and
		int((buildings.planned_utilization_q16 as PackedInt32Array)[0]) < 65536)
	_expect("zero owner input funds suppress intent and production",
		constrained_intent == 0 and
		int((buildings.last_output as PackedInt64Array)[0]) == 0 and funded_output > 0)
	_expect("final wage arrears flag matches post-sale payroll",
		(int((buildings.wage_suspended as PackedByteArray)[0]) != 0) ==
		(day2_paid_total < day2_due_total))
	_expect("insolvent wage cycle conserves money and goods",
		int(day2.get("money_error", 1)) == 0 and int(day2.get("goods_error", 1)) == 0)
	var drained_pop: Dictionary = ext.get_population_cell_snapshot(0)
	_expect("treasury transfer is exposed as a settlement source",
		_cashflow_has_source(drained_pop,
			_row_for_signature(drained_pop, landlord_sig), "transfer", false))
	_run_day(ext, 3)
	var loss_two: Dictionary = ext.get_building_cell_snapshot(0)
	_expect("second severe-loss cycle remains active",
		int((loss_two.severe_loss_cycles as PackedInt32Array)[0]) == 2 and
		int((loss_two.operating_state as PackedByteArray)[0]) == 0)
	_run_day(ext, 4)
	var suspended: Dictionary = ext.get_building_cell_snapshot(0)
	_expect("third severe-loss cycle suspends the building",
		int((suspended.severe_loss_cycles as PackedInt32Array)[0]) == 3 and
		int((suspended.operating_state as PackedByteArray)[0]) == 1)
	_expect("loss-suspended building has no jobs intent or output",
		int((suspended.filled_owner as PackedInt64Array)[0]) == 0 and
		int((suspended.purchase_intent_capacity_q16 as PackedInt64Array)[0]) == 0 and
		int((suspended.last_output as PackedInt64Array)[0]) == 0)
	var country_chunks: Array[PackedByteArray] = []
	var country_save_begin: Dictionary = ext.begin_country_save(4096)
	_expect("building PKCN save begins", bool(country_save_begin.get("ok", false)))
	while true:
		var country_chunk: PackedByteArray = ext.read_country_save_chunk(4096)
		if country_chunk.is_empty(): break
		country_chunks.append(country_chunk)
	_expect("building PKCN save completes", bool(ext.end_country_save().get("ok", false)))
	var chunks: Array[PackedByteArray] = []
	var save_begin: Dictionary = ext.begin_economy_save(65536)
	_expect("building v12 save begins", bool(save_begin.get("ok", false)) and int(save_begin.get("schema_version", 0)) == 12)
	while true:
		var chunk: PackedByteArray = ext.read_economy_save_chunk(65536)
		if chunk.is_empty(): break
		chunks.append(chunk)
	_expect("building save completes", bool(ext.end_economy_save().get("ok", false)))
	var restored := _new_ext(compiled)
	_expect("building restore country configures first",
		CountryTestHelper.configure_all_technologies(restored, catalog, 1, 77))
	_expect("building PKCN restore begins", bool(restored.begin_country_restore().get("ok", false)))
	for chunk in country_chunks:
		_expect("building PKCN chunk accepted", bool(restored.feed_country_restore_chunk(chunk).get("ok", false)))
	_expect("building PKCN restore completes", bool(restored.end_country_restore().get("ok", false)))
	_expect("building restore target configures", bool(restored.configure_economy(
		catalog, profile, 1, 77).get("ok", false)))
	_expect("building restore begins", bool(restored.begin_economy_restore().get("ok", false)))
	for chunk in chunks:
		_expect("building restore chunk accepted", bool(restored.feed_economy_restore_chunk(chunk).get("ok", false)))
	_expect("building restore completes", bool(restored.end_economy_restore().get("ok", false)))
	var source_hash: int = ext.get_economy_state_hash()
	var restored_hash: int = restored.get_economy_state_hash()
	if source_hash != restored_hash:
		print("  source hash=%d restored hash=%d" % [source_hash, restored_hash])
		print("  source wage snapshot=", ext.get_building_cell_snapshot(0))
		print("  restored wage snapshot=", restored.get_building_cell_snapshot(0))
	_expect("building save hash round-trips", restored_hash == source_hash)
	var restored_buildings: Dictionary = restored.get_building_cell_snapshot(0)
	_expect("restored mine preserves loss suspension and zero jobs",
		int((restored_buildings.building_counts_by_type as PackedInt64Array)[mine_id]) == 1 and
		int((restored_buildings.operating_state as PackedByteArray)[0]) == 1 and
		int((restored_buildings.employee_filled as PackedInt64Array)[0]) == 0 and
		int((restored_buildings.employee_filled as PackedInt64Array)[1]) == 0)
	print("=== native building runtime %s ===" % ("PASS" if failures == 0 else "FAIL"))

func _test_production_income_consumption_order(catalog: Dictionary, profile: Dictionary) -> void:
	var ext := _new_ext(catalog)
	_expect("phase-order country bootstraps",
		CountryTestHelper.configure_all_technologies(ext, catalog, 1, 177))
	_expect("phase-order runtime configures",
		bool(ext.configure_economy(catalog, profile, 1, 177).get("ok", false)))
	var signatures: PackedStringArray = catalog.signature_keys
	var owner_sig := signatures.find("industrialist|default")
	var worker_sig := signatures.find("industrial_worker|default")
	var manager_sig := signatures.find("manager|default")
	var merchant_sig := signatures.find("merchant|default")
	var plant_id := (catalog.building_type_ids as PackedStringArray).find("staple_food_plant")
	var prepared_good := (catalog.good_ids as PackedStringArray).find("prepared_staples")
	var stock := PackedInt64Array()
	stock.resize((catalog.good_ids as PackedStringArray).size())
	stock.fill(100000)
	stock[prepared_good] = 0
	var boot: Dictionary = ext.bootstrap_economy({
		"cell_indices": PackedInt32Array([0, 0, 0, 0]),
		"signature_ids": PackedInt32Array([owner_sig, worker_sig, manager_sig, merchant_sig]),
		"population": PackedInt64Array([5, 100, 10, 10]),
		"funds": PackedInt64Array([10000000, 0, 0, 10000000]),
	}, {
		"stock": stock,
		"building_cells": PackedInt32Array([0]),
		"building_type_ids": PackedInt32Array([plant_id]),
		"building_owner_signature_ids": PackedInt32Array([owner_sig]),
		"building_counts": PackedInt64Array([1]),
	})
	_expect("phase-order population and plant bootstrap", bool(boot.get("ok", false)))
	var report := _run_day(ext, 0)
	_expect("phase-order cycle conserves all ledgers",
		bool(report.get("done", false)) and not bool(report.get("fatal", false)) and
		int(report.get("population_error", 1)) == 0 and
		int(report.get("money_error", 1)) == 0 and
		int(report.get("goods_error", 1)) == 0)
	var pop: Dictionary = ext.get_population_cell_snapshot(0)
	var worker_row := _row_for_signature(pop, worker_sig)
	var manager_row := _row_for_signature(pop, manager_sig)
	var incomes: PackedInt64Array = pop.epoch_income_by_cohort
	var expenses: PackedInt64Array = pop.epoch_expense_by_cohort
	_expect("zero-cash employees spend same-cycle wage income",
		worker_row >= 0 and manager_row >= 0 and
		int(incomes[worker_row]) > 0 and int(expenses[worker_row]) > 0 and
		int(incomes[manager_row]) > 0 and int(expenses[manager_row]) > 0)
	var buildings: Dictionary = ext.get_building_cell_snapshot(0)
	var sold := int((buildings.last_sold as PackedInt64Array)[0])
	var market: Dictionary = ext.get_market_cell_snapshot(0)
	var closing_prepared := _good_value(market, "stock", "prepared_staples")
	_expect("same-cycle produced food is sold before household clearing",
		sold > 0 and closing_prepared >= 0 and closing_prepared < sold)

func _test_scarce_output_cost_floor(source_catalog: Dictionary, profile: Dictionary) -> void:
	var catalog := source_catalog.duplicate(true)
	var plant_id := (catalog.building_type_ids as PackedStringArray).find("staple_food_plant")
	var output_offsets: PackedInt32Array = catalog.building_output_offsets
	var output_quantities: PackedInt64Array = catalog.building_output_quantities
	output_quantities[int(output_offsets[plant_id])] = 1000
	catalog.building_output_quantities = output_quantities
	var ext := _new_ext(catalog)
	_expect("cost-floor country bootstraps",
		CountryTestHelper.configure_all_technologies(ext, catalog, 1, 178))
	_expect("cost-floor runtime configures",
		bool(ext.configure_economy(catalog, profile, 1, 178).get("ok", false)))
	var signatures: PackedStringArray = catalog.signature_keys
	var owner_sig := signatures.find("industrialist|default")
	var worker_sig := signatures.find("industrial_worker|default")
	var manager_sig := signatures.find("manager|default")
	var merchant_sig := signatures.find("merchant|default")
	var stock := PackedInt64Array()
	stock.resize((catalog.good_ids as PackedStringArray).size())
	stock.fill(1000000)
	stock[(catalog.good_ids as PackedStringArray).find("prepared_staples")] = 0
	var boot: Dictionary = ext.bootstrap_economy({
		"cell_indices": PackedInt32Array([0, 0, 0, 0]),
		"signature_ids": PackedInt32Array([owner_sig, worker_sig, manager_sig, merchant_sig]),
		"population": PackedInt64Array([5, 100, 10, 10]),
		"funds": PackedInt64Array([100000000, 1000000, 1000000, 100000000]),
	}, {
		"stock": stock,
		"building_cells": PackedInt32Array([0]),
		"building_type_ids": PackedInt32Array([plant_id]),
		"building_owner_signature_ids": PackedInt32Array([owner_sig]),
		"building_counts": PackedInt64Array([1]),
	})
	_expect("cost-floor plant bootstraps", bool(boot.get("ok", false)))
	_run_day(ext, 0)
	var market0: Dictionary = ext.get_market_cell_snapshot(0)
	var price0 := _good_i32_value(market0, "price", "prepared_staples")
	var anchor0 := _good_i32_value(market0, "cost_anchor_price", "prepared_staples")
	var target0 := _good_value(market0, "merchant_inventory_target", "prepared_staples")
	var stock0 := _good_value(market0, "stock", "prepared_staples")
	_run_day(ext, 1)
	var market1: Dictionary = ext.get_market_cell_snapshot(0)
	var price1 := _good_i32_value(market1, "price", "prepared_staples")
	var rate_limited_floor := mini(anchor0, price0 + int(price0 * 8192 / 65536))
	_expect("scarce output publishes a cost anchor above its market price",
		anchor0 > price0 and stock0 < target0)
	_expect("scarce output price rises to the rate-limited producer cost floor",
		price1 >= rate_limited_floor)

func _new_ext(catalog: Dictionary) -> Object:
	var ext: Object = ClassDB.instantiate("DCWorldExt")
	ext.create_entities(1)
	var scalar := PackedFloat32Array([0.5])
	for slot_name in [&"cell_temp", &"cell_moisture", &"cell_snow_cover", &"cell_weather_intensity", &"cell_elevation"]:
		var sid: int = ext.register_component(slot_name, 0, 1, false)
		ext.write_f32_range(sid, 0, scalar)
	var zero_u8 := PackedByteArray([0])
	for slot_name in [&"cell_terrain", &"cell_landform", &"cell_vegetation", &"cell_is_water", &"cell_has_river"]:
		var sid: int = ext.register_component(slot_name, 2, 1, false)
		ext.write_u8_range(sid, 0, zero_u8)
	var reserve_slots: PackedStringArray = catalog.building_resource_reserve_slots
	var extra_slots: PackedStringArray = catalog.building_resource_extra_slots
	var resource_ids: PackedStringArray = catalog.building_resource_ids
	for i in range(resource_ids.size()):
		var reserve_sid: int = ext.register_component(StringName(reserve_slots[i]), 0, 1, false)
		var extra_sid: int = ext.register_component(StringName(extra_slots[i]), 0, 1, false)
		var reserve := PackedFloat32Array([1000.0 if resource_ids[i] == "coal" else 0.0])
		ext.write_f32_range(reserve_sid, 0, reserve)
		ext.write_f32_range(extra_sid, 0, PackedFloat32Array([0.0]))
	return ext

func _run_day(ext: Object, day: int) -> Dictionary:
	var report := {}
	for slice in range(256):
		report = ext.run_economy_slice({"day_index": day, "tick_index": day * 1000 + slice})
		if bool(report.get("done", false)):
			return report
	return report

func _row_for_signature(snapshot: Dictionary, signature: int) -> int:
	return (snapshot.signature_ids as PackedInt32Array).find(signature)

func _handle_for_profession(snapshot: Dictionary, signature: int) -> int:
	var row := _row_for_signature(snapshot, signature)
	return int((snapshot.handles as PackedInt64Array)[row]) if row >= 0 else 0

func _good_value(snapshot: Dictionary, column: String, good_id: String) -> int:
	var index := (snapshot.good_ids as PackedStringArray).find(good_id)
	return int((snapshot[column] as PackedInt64Array)[index]) if index >= 0 else 0

func _good_i32_value(snapshot: Dictionary, column: String, good_id: String) -> int:
	var index := (snapshot.good_ids as PackedStringArray).find(good_id)
	return int((snapshot[column] as PackedInt32Array)[index]) if index >= 0 else 0

func _has_positive(values: PackedInt64Array) -> bool:
	for value in values:
		if int(value) > 0:
			return true
	return false

func _cashflow_total_for_row(snapshot: Dictionary, row: int, income: bool) -> int:
	if row < 0:
		return -1
	var offsets: PackedInt32Array = snapshot.settlement_cashflow_offsets
	var values: PackedInt64Array = snapshot.settlement_cashflow_income if income else snapshot.settlement_cashflow_expense
	var total := 0
	for cursor in range(offsets[row], offsets[row + 1]):
		total += int(values[cursor])
	return total

func _cashflow_has_source(snapshot: Dictionary, row: int, stable_id: String, income: bool) -> bool:
	if row < 0:
		return false
	var source_ids: PackedStringArray = snapshot.settlement_cashflow_source_stable_ids
	var target := source_ids.find(stable_id)
	var offsets: PackedInt32Array = snapshot.settlement_cashflow_offsets
	var sources: PackedInt32Array = snapshot.settlement_cashflow_source_indices
	var values: PackedInt64Array = snapshot.settlement_cashflow_income if income else snapshot.settlement_cashflow_expense
	for cursor in range(offsets[row], offsets[row + 1]):
		if int(sources[cursor]) == target and int(values[cursor]) > 0:
			return true
	return false
