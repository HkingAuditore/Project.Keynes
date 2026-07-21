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
	var natural_demography_catalog := compiled.duplicate(true)
	var ext := _new_ext(compiled)
	var catalog := compiled.duplicate(true)
	catalog.erase("ok")
	var stable_birth_rates: PackedInt64Array = catalog.signature_birth_rate_q32
	var stable_death_rates: PackedInt64Array = catalog.signature_death_rate_q32
	stable_birth_rates.fill(0)
	stable_death_rates.fill(0)
	catalog.signature_birth_rate_q32 = stable_birth_rates
	catalog.signature_death_rate_q32 = stable_death_rates
	var mine_id := building_ids.find("coal_mine")
	var output_offsets: PackedInt32Array = catalog.building_output_offsets
	var output_quantities: PackedInt64Array = catalog.building_output_quantities
	output_quantities[int(output_offsets[mine_id])] = 100000
	catalog.building_output_quantities = output_quantities
	var profile = load("res://data/economy/default_economy.tres").to_native_profile()
	profile.market_cycle_days = 5
	profile.market_runtime_mode = "ACTIVE"
	_test_births_wait_for_next_employment(natural_demography_catalog, profile)
	_test_production_income_consumption_order(catalog, profile)
	_test_scarce_output_cost_floor(catalog, profile)
	_test_survival_retention_cap(catalog, profile)
	_test_hunter_subsistence_and_working_capital(catalog, profile)
	_test_shortage_recovery_uses_household_stock(catalog, profile)
	_test_business_demand_recovers_industrial_utilization(catalog, profile)
	_test_production_input_hard_reserve(catalog, profile)
	_test_production_input_soft_shortage(catalog, profile)
	_test_producer_support_issuance(catalog, profile)
	_test_cycle_flow_output_clears_before_discard(catalog, profile)
	_test_construction_shortage_feeds_procurement_signal(catalog, profile)
	_test_owner_fill_reconciles_after_population_loss(catalog, profile)
	_test_last_building_demolition_releases_profession_cohorts(catalog, profile)
	_test_non_due_construction_employment_metrics(catalog, profile)
	_test_active_owner_income_reallocation(catalog, profile)
	_test_same_profession_owner_income_reallocation(catalog, profile)
	_test_owner_income_reallocation_prefers_unemployed(catalog, profile)
	_test_endogenous_owner_investment(catalog, profile)
	_test_zero_construction_collector_investment(catalog, profile)
	_test_investment_capacity_is_not_gate(catalog, profile)
	_test_investment_requires_owner_livelihood(catalog, profile)
	_test_endogenous_investment_repairs_dead_merchant(catalog, profile)
	_test_building_plan_continuation(catalog, profile)
	_test_production_worker_scalar_equivalence(catalog, profile)
	# Keep the legacy insolvency fixture focused on payroll state transitions;
	# the 60-day default is covered by the market/schema tests.
	profile.merchant_market_making_days_q16 = 1966080
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
	# 采购闭环夹具必须从煤炭缺口开始；超出30天目标的库存本就不应强迫商人继续收购。
	stock[goods.find("coal")] = 0
	var boot: Dictionary = ext.bootstrap_economy({
		"cell_indices": PackedInt32Array([0, 0, 0, 0]),
		"signature_ids": PackedInt32Array([landlord_sig, worker_sig, manager_sig, merchant_sig]),
		"population": PackedInt64Array([5, 100, 10, 10]),
		"funds": PackedInt64Array([100000000, 1000000, 1000000, 10000000]),
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
	_expect("building snapshot reports five-day production period", int(buildings.get("period_days", 0)) == 5)
	_expect("owner job filled", int((buildings.filled_owner as PackedInt64Array)[0]) == 1)
	var planned_utilization := int((buildings.planned_utilization_q16 as PackedInt32Array)[0])
	var filled_by_role: PackedInt64Array = buildings.employee_filled
	var filled_jobs := int(filled_by_role[0]) + int(filled_by_role[1])
	_expect("active utilization remains bounded and keeps jobs",
		planned_utilization > 0 and planned_utilization <= 65536 and
		filled_jobs > 0 and filled_jobs <= 20)
	_expect("mine produces output", int((buildings.last_output as PackedInt64Array)[0]) > 0)
	_expect("merchant buys at least part of output", int((buildings.last_sold as PackedInt64Array)[0]) > 0)
	_expect("merchant procurement freezes a 12.5 percent reserve and stays in budget",
		int(day1.get("merchant_procurement_reserved", 0)) > 0 and
		int(day1.get("merchant_procurement_budget", 0)) >=
			int(day1.get("merchant_procurement_spent", -1)) and
		int(day1.get("merchant_procurement_budget", 0)) >=
			int(day1.get("merchant_procurement_reserved", 0)) * 6)
	var retained_output := int((buildings.last_retained as PackedInt64Array)[0])
	_expect("owner may retain produced coal for its own home-energy need",
		retained_output > 0 and
		int(day1.get("production_output_retained", 0)) >= retained_output and
		int(day1.get("owner_output_consumed", 0)) > 0)
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
		base_wages == (int(filled_by_role[0]) * int(contract_wages[0]) +
			int(filled_by_role[1]) * int(contract_wages[1])) * 5 and
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
		int((pop.epoch_income_by_cohort as PackedInt64Array)[worker_row]) >=
			int(base_paid_by_role[0]) + int(bonus_paid_by_role[0]) and
		int((pop.epoch_income_by_cohort as PackedInt64Array)[manager_row]) >=
			int(base_paid_by_role[1]) + int(bonus_paid_by_role[1]))
	_expect("owner expense includes base payroll and bonus", landlord_row >= 0 and
		int((pop.epoch_expense_by_cohort as PackedInt64Array)[landlord_row]) >= expected_wages)
	_expect("committed settlement cashflow detail is available",
		bool(pop.get("settlement_detail_available", false)) and
		int(pop.get("settlement_period_days", 0)) == 5)
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
	var supported_output := int(day1.get("production_output_supported", 0))
	var accepted_output := int((buildings.last_sold as PackedInt64Array)[0])
	var coal_market: Dictionary = ext.get_market_cell_snapshot(0)
	_expect("merchant cash purchase and bounded support stop at the inventory target",
		funded_output > 0 and int((buildings.last_sold as PackedInt64Array)[0]) > 0 and
		accepted_output > 0 and supported_output <= accepted_output and
		accepted_output <= funded_output and
		_good_value(coal_market, "stock", "coal") <=
			_good_value(coal_market, "merchant_inventory_target", "coal"))
	pop = ext.get_population_cell_snapshot(0)
	landlord_row = _row_for_signature(pop, landlord_sig)
	owner_handle = _handle_for_profession(pop, landlord_sig)
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
	_expect("producer-income inventory floor preserves the next active production plan",
		int((buildings.planned_utilization_q16 as PackedInt32Array)[0]) > 0 and
		int((buildings.planned_utilization_q16 as PackedInt32Array)[0]) <= 65536)
	_expect("zero owner input funds preserve intent but suppress funded production",
		constrained_intent > 0 and
		int((buildings.funded_capacity_q16 as PackedInt64Array)[0]) == 0 and
		int((buildings.last_output as PackedInt64Array)[0]) == 0 and funded_output > 0)
	_expect("final wage arrears flag matches post-sale payroll",
		(int((buildings.wage_suspended as PackedByteArray)[0]) != 0) ==
		(day2_paid_total < day2_due_total))
	_expect("insolvent wage cycle conserves money and goods",
		int(day2.get("money_error", 1)) == 0 and int(day2.get("goods_error", 1)) == 0)
	_expect("cash-drained cycle preserves the prior profitable settlement once",
		int((buildings.severe_loss_cycles as PackedInt32Array)[0]) == 0 and
		int((buildings.operating_state as PackedByteArray)[0]) == 0)
	var drained_pop: Dictionary = ext.get_population_cell_snapshot(0)
	_expect("treasury transfer is exposed as a settlement source",
		_cashflow_has_source(drained_pop,
			_row_for_signature(drained_pop, landlord_sig), "transfer", false))
	_run_day(ext, 3)
	var loss_two: Dictionary = ext.get_building_cell_snapshot(0)
	_expect("first settled severe-loss cycle remains active",
		int((loss_two.severe_loss_cycles as PackedInt32Array)[0]) == 1 and
		int((loss_two.operating_state as PackedByteArray)[0]) == 0)
	_run_day(ext, 4)
	var suspended: Dictionary = ext.get_building_cell_snapshot(0)
	_expect("second settled severe-loss cycle remains active",
		int((suspended.severe_loss_cycles as PackedInt32Array)[0]) == 2 and
		int((suspended.operating_state as PackedByteArray)[0]) == 0)
	_run_day(ext, 5)
	suspended = ext.get_building_cell_snapshot(0)
	_expect("third settled severe-loss cycle suspends the building",
		int((suspended.severe_loss_cycles as PackedInt32Array)[0]) == 3 and
		int((suspended.operating_state as PackedByteArray)[0]) == 1)
	_expect("loss-suspended building retains one recovery owner but no production intent",
		int((suspended.filled_owner as PackedInt64Array)[0]) == 1 and
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
	_expect("building v15 save begins", bool(save_begin.get("ok", false)) and int(save_begin.get("schema_version", 0)) == 15)
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
	var recovery_pop: Dictionary = ext.get_population_cell_snapshot(0)
	var recovery_owner_handle := _handle_for_profession(recovery_pop, landlord_sig)
	var recapitalize: Dictionary = ext.submit_economy_commands({
		"opcodes": PackedInt32Array([2]),
		"effective_days": PackedInt64Array([6]),
		"sequences": PackedInt64Array([3]),
		"target_handles": PackedInt64Array([recovery_owner_handle]),
		"i32_0": PackedInt32Array([0]),
		"i32_1": PackedInt32Array([0]),
		"i64_0": PackedInt64Array([1000000000]),
		"i64_1": PackedInt64Array([0]),
	})
	_expect("suspended owner recapitalization command accepted",
		recovery_owner_handle != 0 and bool(recapitalize.get("ok", false)))
	var recovery_one_report := _run_day(ext, 6)
	var recovery_one: Dictionary = ext.get_building_cell_snapshot(0)
	_expect("first solvent recovery cycle remains suspended",
		int((recovery_one.recovery_cycles as PackedInt32Array)[0]) == 0 and
		int((recovery_one.operating_state as PackedByteArray)[0]) == 1)
	_expect("first recovery cycle conserves all ledgers",
		int(recovery_one_report.get("population_error", 1)) == 0 and
		int(recovery_one_report.get("money_error", 1)) == 0 and
		int(recovery_one_report.get("goods_error", 1)) == 0)
	var restart_report := _run_day(ext, 7)
	var restarted: Dictionary = ext.get_building_cell_snapshot(0)
	_expect("profitable alternative keeps the loss building suspended",
		(restarted.group_type_ids as PackedInt32Array).size() > 1 and
		int((restarted.operating_state as PackedByteArray)[0]) == 1 and
		int((restarted.operating_state as PackedByteArray)[1]) == 0)
	_expect("restart cycle conserves all ledgers",
		int(restart_report.get("population_error", 1)) == 0 and
		int(restart_report.get("money_error", 1)) == 0 and
		int(restart_report.get("goods_error", 1)) == 0)
	var resumed_report := _run_day(ext, 8)
	var resumed: Dictionary = ext.get_building_cell_snapshot(0)
	_expect("suspended zero-income owner transfers through active-first hiring",
		int((resumed.operating_state as PackedByteArray)[0]) == 1 and
		int((resumed.filled_owner as PackedInt64Array)[0]) == 0 and
		int((resumed.filled_owner as PackedInt64Array)[1]) >
			int((restarted.filled_owner as PackedInt64Array)[1]) and
		int((resumed.last_output as PackedInt64Array)[0]) == 0)
	_expect("resumed production conserves all ledgers",
		int(resumed_report.get("population_error", 1)) == 0 and
		int(resumed_report.get("money_error", 1)) == 0 and
		int(resumed_report.get("goods_error", 1)) == 0)
	print("=== native building runtime %s ===" % ("PASS" if failures == 0 else "FAIL"))

func _test_births_wait_for_next_employment(source_catalog: Dictionary,
		source_profile: Dictionary) -> void:
	var catalog := source_catalog.duplicate(true)
	catalog.erase("ok")
	var profile := source_profile.duplicate(true)
	profile.starvation_death_rate_q32 = 0
	var signatures: PackedStringArray = catalog.signature_keys
	var artisan_sig := signatures.find("artisan|default")
	var unemployed_sig := signatures.find("unemployed|default")
	var merchant_sig := signatures.find("merchant|default")
	var birth_rates: PackedInt64Array = catalog.signature_birth_rate_q32
	var death_rates: PackedInt64Array = catalog.signature_death_rate_q32
	birth_rates.fill(0)
	death_rates.fill(0)
	# One artisan at full satisfaction contributes exactly one birth per five-day period.
	birth_rates[artisan_sig] = 858993460
	catalog.signature_birth_rate_q32 = birth_rates
	catalog.signature_death_rate_q32 = death_rates
	var ext := _new_ext(catalog)
	_expect("birth-employment country bootstraps",
		CountryTestHelper.configure_all_technologies(ext, catalog, 1, 2202))
	_expect("birth-employment runtime configures",
		bool(ext.configure_economy(catalog, profile, 1, 2202).get("ok", false)))
	var stock := PackedInt64Array()
	stock.resize((catalog.good_ids as PackedStringArray).size())
	stock.fill(1000000000000)
	var knapping_id := (catalog.building_type_ids as PackedStringArray).find(
		"knapping_workshop")
	var boot: Dictionary = ext.bootstrap_economy({
		"cell_indices": PackedInt32Array([0, 0]),
		"signature_ids": PackedInt32Array([artisan_sig, merchant_sig]),
		"population": PackedInt64Array([1, 1]),
		"funds": PackedInt64Array([1000000000000, 1000000000000]),
	}, {
		"stock": stock,
		"building_cells": PackedInt32Array([0]),
		"building_type_ids": PackedInt32Array([knapping_id]),
		"building_owner_signature_ids": PackedInt32Array([artisan_sig]),
		"building_counts": PackedInt64Array([2]),
	})
	_expect("birth-employment fixture bootstraps", bool(boot.get("ok", false)))
	var report := _run_day(ext, 0)
	var population: Dictionary = ext.get_population_cell_snapshot(0)
	var buildings: Dictionary = ext.get_building_cell_snapshot(0)
	var unemployed_row := _row_for_signature(population, unemployed_sig)
	_expect("birth structural commit creates one unemployed cohort member",
		int(report.get("births", 0)) == 1 and unemployed_row >= 0 and
		int((population.populations as PackedInt64Array)[unemployed_row]) == 1 and
		int((population.funds_by_cohort as PackedInt64Array)[unemployed_row]) == 0)
	_expect("newborn does not fill the active owner opening in the same period",
		_sum_i64(buildings.filled_owner as PackedInt64Array) == 1 and
		_sum_i64(buildings.owner_openings as PackedInt64Array) == 1 and
		int((population.owner_employed_by_cohort as PackedInt64Array)[unemployed_row]) == 0 and
		int(report.get("population_error", 1)) == 0)

func _test_owner_fill_reconciles_after_population_loss(catalog: Dictionary,
		profile: Dictionary) -> void:
	var ext := _new_ext(catalog)
	_expect("owner-reconcile country bootstraps",
		CountryTestHelper.configure_all_technologies(ext, catalog, 1, 183))
	_expect("owner-reconcile runtime configures",
		bool(ext.configure_economy(catalog, profile, 1, 183).get("ok", false)))
	var signatures: PackedStringArray = catalog.signature_keys
	var artisan_sig := signatures.find("artisan|default")
	var unemployed_sig := signatures.find("unemployed|default")
	var merchant_sig := signatures.find("merchant|default")
	var building_ids: PackedStringArray = catalog.building_type_ids
	var owner_types := PackedInt32Array([
		building_ids.find("household_weaving_shelter"),
		building_ids.find("knapping_workshop"),
		building_ids.find("lumber_plant"),
	])
	var stock := PackedInt64Array()
	stock.resize((catalog.good_ids as PackedStringArray).size())
	stock.fill(1000000)
	var boot: Dictionary = ext.bootstrap_economy({
		"cell_indices": PackedInt32Array([0, 0, 0]),
		"signature_ids": PackedInt32Array([artisan_sig, unemployed_sig, merchant_sig]),
		"population": PackedInt64Array([3, 1, 1]),
		"funds": PackedInt64Array([100000000, 1000000, 100000000]),
	}, {
		"stock": stock,
		"building_cells": PackedInt32Array([0, 0, 0]),
		"building_type_ids": owner_types,
		"building_owner_signature_ids": PackedInt32Array([
			artisan_sig, artisan_sig, artisan_sig]),
		"building_counts": PackedInt64Array([1, 1, 1]),
	})
	_expect("owner-reconcile fixture bootstraps", bool(boot.get("ok", false)))
	_run_day(ext, 0)
	var opening_pop: Dictionary = ext.get_population_cell_snapshot(0)
	var artisan_handle := _handle_for_profession(opening_pop, artisan_sig)
	_expect("owner-reconcile artisan handle exists", artisan_handle != 0)
	var remove_one: Dictionary = ext.submit_economy_commands({
		"opcodes": PackedInt32Array([6]),
		"effective_days": PackedInt64Array([1]),
		"sequences": PackedInt64Array([1]),
		"target_handles": PackedInt64Array([artisan_handle]),
		"i32_0": PackedInt32Array([0]),
		"i32_1": PackedInt32Array([0]),
		"i64_0": PackedInt64Array([-1]),
		"i64_1": PackedInt64Array([0]),
	})
	_expect("owner-reconcile population loss queues", bool(remove_one.get("ok", false)))
	var day1 := _run_day(ext, 1)
	var buildings: Dictionary = ext.get_building_cell_snapshot(0)
	var pop: Dictionary = ext.get_population_cell_snapshot(0)
	var filled_total := _sum_i64(buildings.filled_owner as PackedInt64Array)
	var required_total := _sum_i64(buildings.owner_required as PackedInt64Array)
	var cohort_owner_total := _sum_i64(pop.owner_employed_by_cohort as PackedInt64Array)
	var unemployed_row := _row_for_signature(pop, unemployed_sig)
	var unemployed_pool_population := int((pop.populations as PackedInt64Array)[unemployed_row]) \
		if unemployed_row >= 0 else 0
	_expect("owner snapshot separates capacity, planned jobs, and openings",
		(buildings.owner_capacity as PackedInt64Array).size() == 3 and
		(buildings.owner_required as PackedInt64Array).size() == 3 and
		(buildings.owner_openings as PackedInt64Array).size() == 3 and
		_sum_i64(buildings.owner_capacity as PackedInt64Array) >= required_total)
	_expect("shared owner signature fill reconciles to cohort employment",
		filled_total == required_total and filled_total == cohort_owner_total and
		_sum_i64(buildings.owner_openings as PackedInt64Array) == 0)
	_expect("released owner target hires from the unemployed pool",
		filled_total == required_total and filled_total == 3 and unemployed_pool_population == 0)
	_expect("owner reconciliation conserves every ledger",
		int(day1.get("population_error", 1)) == 0 and
		int(day1.get("money_error", 1)) == 0 and
		int(day1.get("goods_error", 1)) == 0)


func _test_last_building_demolition_releases_profession_cohorts(
		catalog: Dictionary, profile: Dictionary) -> void:
	var ext := _new_ext(catalog)
	_expect("last-demolition country bootstraps",
		CountryTestHelper.configure_all_technologies(ext, catalog, 1, 184))
	_expect("last-demolition runtime configures",
		bool(ext.configure_economy(catalog, profile, 1, 184).get("ok", false)))
	var signatures: PackedStringArray = catalog.signature_keys
	var owner_sig := signatures.find("industrialist|default")
	var worker_sig := signatures.find("miner|default")
	var manager_sig := signatures.find("manager|default")
	var unemployed_sig := signatures.find("unemployed|default")
	var merchant_sig := signatures.find("merchant|default")
	var mine_id := (catalog.building_type_ids as PackedStringArray).find("coal_mine")
	var goods: PackedStringArray = catalog.good_ids
	var stock := PackedInt64Array()
	stock.resize(goods.size())
	stock.fill(1000000)
	var boot: Dictionary = ext.bootstrap_economy({
		"cell_indices": PackedInt32Array([0, 0, 0, 0, 0]),
		"signature_ids": PackedInt32Array([
			owner_sig, worker_sig, manager_sig, unemployed_sig, merchant_sig]),
		"population": PackedInt64Array([1, 20, 4, 1, 1]),
		"funds": PackedInt64Array([
			100000000, 1000000, 1000000, 1000000, 100000000]),
	}, {
		"stock": stock,
		"building_cells": PackedInt32Array([0]),
		"building_type_ids": PackedInt32Array([mine_id]),
		"building_owner_signature_ids": PackedInt32Array([owner_sig]),
		"building_counts": PackedInt64Array([1]),
	})
	_expect("last-demolition fixture bootstraps", bool(boot.get("ok", false)))
	var opening_report := _run_day(ext, 0)
	var opening_pop: Dictionary = ext.get_population_cell_snapshot(0)
	var owner_handle := _handle_for_profession(opening_pop, owner_sig)
	var worker_row := _row_for_signature(opening_pop, worker_sig)
	var worker_employed := 0
	if worker_row >= 0:
		worker_employed = int((opening_pop.owner_employed_by_cohort as PackedInt64Array)[
			worker_row]) + int((opening_pop.employee_employed_by_cohort as PackedInt64Array)[
			worker_row])
	_expect("last-demolition mine initially employs miners",
		owner_handle != 0 and worker_employed > 0 and
		int(opening_report.get("population_error", 1)) == 0)
	var submit: Dictionary = ext.submit_economy_commands({
		"opcodes": PackedInt32Array([11]),
		"effective_days": PackedInt64Array([5]),
		"sequences": PackedInt64Array([301]),
		"target_handles": PackedInt64Array([owner_handle]),
		"i32_0": PackedInt32Array([0]),
		"i32_1": PackedInt32Array([mine_id]),
		"i64_0": PackedInt64Array([1]),
		"i64_1": PackedInt64Array([0]),
	})
	_expect("last-demolition command queues", bool(submit.get("ok", false)))
	var closing_report := _run_day(ext, 1)
	var closing_pop: Dictionary = ext.get_population_cell_snapshot(0)
	var closing_buildings: Dictionary = ext.get_building_cell_snapshot(0)
	var cohort_signatures: PackedInt32Array = closing_pop.signature_ids
	var populations: PackedInt64Array = closing_pop.populations
	var owner_employed: PackedInt64Array = closing_pop.owner_employed_by_cohort
	var employee_employed: PackedInt64Array = closing_pop.employee_employed_by_cohort
	var identity_valid := true
	for row in range(cohort_signatures.size()):
		var signature := int(cohort_signatures[row])
		if signature == merchant_sig or signature == unemployed_sig:
			continue
		identity_valid = identity_valid and int(populations[row]) == \
			int(owner_employed[row]) + int(employee_employed[row])
	var unemployed_row := _row_for_signature(closing_pop, unemployed_sig)
	var unemployed_population := int(populations[unemployed_row]) \
		if unemployed_row >= 0 else 0
	_expect("last demolition removes the final building group",
		int((closing_buildings.building_counts_by_type as PackedInt64Array)[mine_id]) == 0)
	_expect("idle professions migrate into the unemployed cohort",
		identity_valid and unemployed_population == 26)
	_expect("last-demolition reconciliation conserves every ledger",
		int(closing_report.get("population_error", 1)) == 0 and
		int(closing_report.get("money_error", 1)) == 0 and
		int(closing_report.get("goods_error", 1)) == 0)


func _test_non_due_construction_employment_metrics(
		catalog: Dictionary, source_profile: Dictionary) -> void:
	var profile := source_profile.duplicate(true)
	profile.starvation_death_rate_q32 = 0
	var ext := _new_ext(catalog, 2)
	_expect("non-due construction country bootstraps",
		CountryTestHelper.configure_all_technologies(ext, catalog, 2, 185))
	_expect("non-due construction runtime configures",
		bool(ext.configure_economy(catalog, profile, 2, 185).get("ok", false)))
	var signatures: PackedStringArray = catalog.signature_keys
	var artisan_sig := signatures.find("artisan|default")
	var unemployed_sig := signatures.find("unemployed|default")
	var merchant_sig := signatures.find("merchant|default")
	var knapping_id := (catalog.building_type_ids as PackedStringArray).find(
		"knapping_workshop")
	var goods: PackedStringArray = catalog.good_ids
	var stock := PackedInt64Array()
	stock.resize(goods.size() * 2)
	stock.fill(1000000)
	var boot: Dictionary = ext.bootstrap_economy({
		"cell_indices": PackedInt32Array([0, 1, 1, 1]),
		"signature_ids": PackedInt32Array([
			merchant_sig, artisan_sig, unemployed_sig, merchant_sig]),
		"population": PackedInt64Array([1, 1, 9, 1]),
		"funds": PackedInt64Array([100000000, 100000000, 9000000, 100000000]),
	}, {"stock": stock})
	_expect("non-due construction fixture bootstraps", bool(boot.get("ok", false)))
	var owner_snapshot: Dictionary = ext.get_population_cell_snapshot(1)
	var owner_handle := _handle_for_profession(owner_snapshot, artisan_sig)
	var submit: Dictionary = ext.submit_economy_commands({
		"opcodes": PackedInt32Array([10]),
		"effective_days": PackedInt64Array([0]),
		"sequences": PackedInt64Array([401]),
		"target_handles": PackedInt64Array([owner_handle]),
		"i32_0": PackedInt32Array([1]),
		"i32_1": PackedInt32Array([knapping_id]),
		"i64_0": PackedInt64Array([1]),
		"i64_1": PackedInt64Array([0]),
	})
	_expect("non-due construction command queues", bool(submit.get("ok", false)))
	# Simulation day 0 settles phase-0 markets. Cell 1 is counted only when the
	# immediate construction commit explicitly reconciles its employment.
	var report := _run_day(ext, 0)
	var closing: Dictionary = ext.get_population_cell_snapshot(1)
	var populations: PackedInt64Array = closing.populations
	var owners: PackedInt64Array = closing.owner_employed_by_cohort
	var employees: PackedInt64Array = closing.employee_employed_by_cohort
	var expected_unemployed := 0
	for row in range(populations.size()):
		expected_unemployed += maxi(0,
			int(populations[row]) - int(owners[row]) - int(employees[row]))
	_expect("non-due employment metrics atomically add the first cell contribution",
		int(report.get("unemployed_population", -1)) == expected_unemployed and
		int(report.get("unemployed_population", -1)) >= 0)
	_expect("non-due construction conserves every ledger",
		int(report.get("population_error", 1)) == 0 and
		int(report.get("money_error", 1)) == 0 and
		int(report.get("goods_error", 1)) == 0)


func _test_active_owner_income_reallocation(source_catalog: Dictionary,
		source_profile: Dictionary) -> void:
	var catalog := source_catalog.duplicate(true)
	var profile := source_profile.duplicate(true)
	profile.starvation_death_rate_q32 = 0
	profile.resource_safe_harvest_q16 = 0
	var signatures: PackedStringArray = catalog.signature_keys
	var forager_sig := signatures.find("forager|default")
	var artisan_sig := signatures.find("artisan|default")
	var merchant_sig := signatures.find("merchant|default")
	var building_ids: PackedStringArray = catalog.building_type_ids
	var flint_id := building_ids.find("flint_quarry")
	var knapping_id := building_ids.find("knapping_workshop")
	var goods: PackedStringArray = catalog.good_ids
	var tool_good := goods.find("chipped_stone_tools")
	var prices: PackedInt32Array = catalog.good_default_price.duplicate()
	var max_prices: PackedInt32Array = catalog.good_max_price.duplicate()
	prices[tool_good] = 1000000000
	max_prices[tool_good] = 1000000000
	catalog.good_default_price = prices
	catalog.good_max_price = max_prices
	var ext := _new_ext(catalog)
	_expect("owner-job mobility country bootstraps",
		CountryTestHelper.configure_all_technologies(ext, catalog, 1, 431))
	_expect("owner-job mobility runtime configures", bool(ext.configure_economy(
		catalog, profile, 1, 431).get("ok", false)))
	var stock := PackedInt64Array()
	stock.resize(goods.size())
	stock.fill(1000000)
	var source_funds := 1234567
	var boot: Dictionary = ext.bootstrap_economy({
		"cell_indices": PackedInt32Array([0, 0]),
		"signature_ids": PackedInt32Array([forager_sig, merchant_sig]),
		"population": PackedInt64Array([1, 1]),
		"funds": PackedInt64Array([source_funds, 1000000]),
	}, {
		"stock": stock,
		"price": prices,
		"building_cells": PackedInt32Array([0, 0]),
		"building_type_ids": PackedInt32Array([flint_id, knapping_id]),
		"building_owner_signature_ids": PackedInt32Array([forager_sig, artisan_sig]),
		"building_counts": PackedInt64Array([2, 1]),
	})
	_expect("owner-job mobility fixture bootstraps", bool(boot.get("ok", false)))
	if not bool(boot.get("ok", false)):
		print("  owner-job bootstrap error=", boot)
		return
	var report := _run_day(ext, 0)
	var buildings: Dictionary = ext.get_building_cell_snapshot(0)
	var flint_group := (buildings.group_type_ids as PackedInt32Array).find(flint_id)
	var knapping_group := (buildings.group_type_ids as PackedInt32Array).find(knapping_id)
	var population: Dictionary = ext.get_population_cell_snapshot(0)
	var forager_row := _row_for_signature(population, forager_sig)
	var artisan_row := _row_for_signature(population, artisan_sig)
	var forager_population := int((population.populations as PackedInt64Array)[forager_row]) \
		if forager_row >= 0 else 0
	var artisan_population := int((population.populations as PackedInt64Array)[artisan_row]) \
		if artisan_row >= 0 else 0
	var artisan_funds := int((population.funds_by_cohort as PackedInt64Array)[artisan_row]) \
		if artisan_row >= 0 else 0
	_expect("higher owner income attracts the final low-income ACTIVE owner",
		flint_group >= 0 and knapping_group >= 0 and
		int((buildings.owner_required as PackedInt64Array)[flint_group]) == 2 and
		int((buildings.projected_owner_income_per_day as PackedInt64Array)[knapping_group]) >
			int((buildings.projected_owner_income_per_day as PackedInt64Array)[flint_group]) and
		int((buildings.filled_owner as PackedInt64Array)[flint_group]) == 0 and
		int((buildings.filled_owner as PackedInt64Array)[knapping_group]) == 1 and
		int(report.get("building_owner_job_reallocations", 0)) == 1 and
		int(report.get("building_owner_job_profession_changes", 0)) == 1)
	_expect("cross-profession owner movement transfers population and funds proportionally",
		forager_population == 0 and artisan_population == 1 and artisan_funds > 0)
	_expect("income-driven owner movement restores target production",
		int((buildings.last_output as PackedInt64Array)[knapping_group]) > 0)
	_expect("owner-job mobility conserves every ledger",
		int(report.get("population_error", 1)) == 0 and
		int(report.get("money_error", 1)) == 0 and
		int(report.get("goods_error", 1)) == 0)


func _test_same_profession_owner_income_reallocation(source_catalog: Dictionary,
		source_profile: Dictionary) -> void:
	var catalog := source_catalog.duplicate(true)
	var profile := source_profile.duplicate(true)
	profile.starvation_death_rate_q32 = 0
	profile.resource_safe_harvest_q16 = 0
	var signatures: PackedStringArray = catalog.signature_keys
	var forager_sig := signatures.find("forager|default")
	var merchant_sig := signatures.find("merchant|default")
	var building_ids: PackedStringArray = catalog.building_type_ids
	var flint_id := building_ids.find("flint_quarry")
	var timber_id := building_ids.find("timber_collector")
	var goods: PackedStringArray = catalog.good_ids
	var tool_good := goods.find("chipped_stone_tools")
	var logs_good := goods.find("logs")
	var prices: PackedInt32Array = catalog.good_default_price.duplicate()
	var min_prices: PackedInt32Array = catalog.good_min_price
	var max_prices: PackedInt32Array = catalog.good_max_price.duplicate()
	prices[tool_good] = min_prices[tool_good]
	prices[logs_good] = 1000000000
	max_prices[logs_good] = 1000000000
	catalog.good_default_price = prices
	catalog.good_max_price = max_prices
	var ext := _new_ext(catalog)
	_expect("same-profession mobility country bootstraps",
		CountryTestHelper.configure_all_technologies(ext, catalog, 1, 433))
	_expect("same-profession mobility runtime configures", bool(ext.configure_economy(
		catalog, profile, 1, 433).get("ok", false)))
	var stock := PackedInt64Array()
	stock.resize(goods.size())
	stock.fill(1000000)
	var boot: Dictionary = ext.bootstrap_economy({
		"cell_indices": PackedInt32Array([0, 0]),
		"signature_ids": PackedInt32Array([forager_sig, merchant_sig]),
		"population": PackedInt64Array([1, 1]),
		"funds": PackedInt64Array([2000000, 1000000]),
	}, {
		"stock": stock,
		"price": prices,
		"building_cells": PackedInt32Array([0, 0]),
		"building_type_ids": PackedInt32Array([flint_id, timber_id]),
		"building_owner_signature_ids": PackedInt32Array([forager_sig, forager_sig]),
		"building_counts": PackedInt64Array([1, 1]),
	})
	_expect("same-profession mobility fixture bootstraps", bool(boot.get("ok", false)))
	if not bool(boot.get("ok", false)):
		return
	var report := _run_day(ext, 0)
	var buildings: Dictionary = ext.get_building_cell_snapshot(0)
	var flint_group := (buildings.group_type_ids as PackedInt32Array).find(flint_id)
	var timber_group := (buildings.group_type_ids as PackedInt32Array).find(timber_id)
	var population: Dictionary = ext.get_population_cell_snapshot(0)
	var forager_row := _row_for_signature(population, forager_sig)
	_expect("same-profession owner movement only reallocates group fill",
		flint_group >= 0 and timber_group >= 0 and forager_row >= 0 and
		int((buildings.filled_owner as PackedInt64Array)[flint_group]) == 0 and
		int((buildings.filled_owner as PackedInt64Array)[timber_group]) == 1 and
		int((population.populations as PackedInt64Array)[forager_row]) == 1 and
		int((population.owner_employed_by_cohort as PackedInt64Array)[forager_row]) == 1 and
		int(report.get("building_owner_job_reallocations", 0)) == 1 and
		int(report.get("building_owner_job_profession_changes", 0)) == 0)
	_expect("same-profession owner movement conserves every ledger",
		int(report.get("population_error", 1)) == 0 and
		int(report.get("money_error", 1)) == 0 and
		int(report.get("goods_error", 1)) == 0)

	var skip_catalog := source_catalog.duplicate(true)
	var skip_prices: PackedInt32Array = skip_catalog.good_default_price.duplicate()
	var skip_max_prices: PackedInt32Array = skip_catalog.good_max_price.duplicate()
	skip_prices[tool_good] = min_prices[tool_good]
	skip_prices[logs_good] = 3200
	skip_max_prices[logs_good] = 3200
	skip_catalog.good_default_price = skip_prices
	skip_catalog.good_max_price = skip_max_prices
	var skip_ext := _new_ext(skip_catalog)
	_expect("owner-job probability country bootstraps",
		CountryTestHelper.configure_all_technologies(skip_ext, skip_catalog, 1, 439))
	_expect("owner-job probability runtime configures", bool(skip_ext.configure_economy(
		skip_catalog, profile, 1, 439).get("ok", false)))
	var skip_boot: Dictionary = skip_ext.bootstrap_economy({
		"cell_indices": PackedInt32Array([0, 0]),
		"signature_ids": PackedInt32Array([forager_sig, merchant_sig]),
		"population": PackedInt64Array([1, 1]),
		"funds": PackedInt64Array([2000000, 1000000]),
	}, {
		"stock": stock,
		"price": skip_prices,
		"building_cells": PackedInt32Array([0, 0]),
		"building_type_ids": PackedInt32Array([flint_id, timber_id]),
		"building_owner_signature_ids": PackedInt32Array([forager_sig, forager_sig]),
		"building_counts": PackedInt64Array([1, 1]),
	})
	_expect("owner-job probability fixture bootstraps", bool(skip_boot.get("ok", false)))
	if not bool(skip_boot.get("ok", false)):
		return
	var skip_report := _run_day(skip_ext, 0)
	var skip_buildings: Dictionary = skip_ext.get_building_cell_snapshot(0)
	var skip_flint_group := (skip_buildings.group_type_ids as PackedInt32Array).find(
		flint_id)
	var skip_timber_group := (skip_buildings.group_type_ids as PackedInt32Array).find(
		timber_id)
	var skip_income: PackedInt64Array = skip_buildings.projected_owner_income_per_day
	print("  probability fixture=", skip_income, "/", skip_buildings.filled_owner,
		"/", skip_report.get("building_owner_job_reallocations", 0), "/",
		skip_report.get("building_owner_job_probability_skips", 0))
	_expect("fixed-seed marginal income gain deterministically skips movement",
		skip_flint_group >= 0 and skip_timber_group >= 0 and
		int(skip_income[skip_timber_group]) > int(skip_income[skip_flint_group]) and
		int((skip_buildings.filled_owner as PackedInt64Array)[skip_flint_group]) == 1 and
		int((skip_buildings.filled_owner as PackedInt64Array)[skip_timber_group]) == 0 and
		int(skip_report.get("building_owner_job_reallocations", 0)) == 0 and
		int(skip_report.get("building_owner_job_probability_skips", 0)) == 1)


func _test_owner_income_reallocation_prefers_unemployed(source_catalog: Dictionary,
		source_profile: Dictionary) -> void:
	var catalog := source_catalog.duplicate(true)
	var profile := source_profile.duplicate(true)
	profile.starvation_death_rate_q32 = 0
	profile.resource_safe_harvest_q16 = 0
	var signatures: PackedStringArray = catalog.signature_keys
	var forager_sig := signatures.find("forager|default")
	var artisan_sig := signatures.find("artisan|default")
	var unemployed_sig := signatures.find("unemployed|default")
	var merchant_sig := signatures.find("merchant|default")
	var building_ids: PackedStringArray = catalog.building_type_ids
	var flint_id := building_ids.find("flint_quarry")
	var knapping_id := building_ids.find("knapping_workshop")
	var goods: PackedStringArray = catalog.good_ids
	var tool_good := goods.find("chipped_stone_tools")
	var prices: PackedInt32Array = catalog.good_default_price.duplicate()
	var max_prices: PackedInt32Array = catalog.good_max_price.duplicate()
	prices[tool_good] = 1000000000
	max_prices[tool_good] = 1000000000
	catalog.good_default_price = prices
	catalog.good_max_price = max_prices
	var ext := _new_ext(catalog)
	_expect("unemployed-first mobility country bootstraps",
		CountryTestHelper.configure_all_technologies(ext, catalog, 1, 437))
	_expect("unemployed-first mobility runtime configures", bool(ext.configure_economy(
		catalog, profile, 1, 437).get("ok", false)))
	var stock := PackedInt64Array()
	stock.resize(goods.size())
	stock.fill(1000000)
	var boot: Dictionary = ext.bootstrap_economy({
		"cell_indices": PackedInt32Array([0, 0, 0]),
		"signature_ids": PackedInt32Array([forager_sig, unemployed_sig, merchant_sig]),
		"population": PackedInt64Array([1, 1, 1]),
		"funds": PackedInt64Array([2000000, 1000000, 1000000]),
	}, {
		"stock": stock,
		"price": prices,
		"building_cells": PackedInt32Array([0, 0]),
		"building_type_ids": PackedInt32Array([flint_id, knapping_id]),
		"building_owner_signature_ids": PackedInt32Array([forager_sig, artisan_sig]),
		"building_counts": PackedInt64Array([1, 1]),
	})
	_expect("unemployed-first mobility fixture bootstraps", bool(boot.get("ok", false)))
	if not bool(boot.get("ok", false)):
		return
	var report := _run_day(ext, 0)
	var buildings: Dictionary = ext.get_building_cell_snapshot(0)
	var flint_group := (buildings.group_type_ids as PackedInt32Array).find(flint_id)
	var knapping_group := (buildings.group_type_ids as PackedInt32Array).find(knapping_id)
	var population: Dictionary = ext.get_population_cell_snapshot(0)
	var forager_row := _row_for_signature(population, forager_sig)
	var artisan_row := _row_for_signature(population, artisan_sig)
	_expect("unemployed owner hiring precedes ACTIVE owner attraction",
		flint_group >= 0 and knapping_group >= 0 and
		int((buildings.filled_owner as PackedInt64Array)[flint_group]) == 1 and
		int((buildings.filled_owner as PackedInt64Array)[knapping_group]) == 1 and
		forager_row >= 0 and artisan_row >= 0 and
		int((population.populations as PackedInt64Array)[forager_row]) == 1 and
		int((population.populations as PackedInt64Array)[artisan_row]) == 1 and
		int(report.get("building_owner_job_reallocations", 0)) == 0)
	_expect("unemployed-first owner hiring conserves every ledger",
		int(report.get("population_error", 1)) == 0 and
		int(report.get("money_error", 1)) == 0 and
		int(report.get("goods_error", 1)) == 0)


func _test_endogenous_owner_investment(source_catalog: Dictionary,
		source_profile: Dictionary) -> void:
	var catalog := source_catalog.duplicate(true)
	var profile := source_profile.duplicate(true)
	profile.merchant_market_making_days_q16 = 1966080
	profile.resource_safe_harvest_q16 = 0
	profile.starvation_death_rate_q32 = 0
	var signatures: PackedStringArray = catalog.signature_keys
	var artisan_sig := signatures.find("artisan|default")
	var hunter_sig := signatures.find("hunter|default")
	var forager_sig := signatures.find("forager|default")
	var merchant_sig := signatures.find("merchant|default")
	var building_ids: PackedStringArray = catalog.building_type_ids
	var knapping_id := building_ids.find("knapping_workshop")
	var hunting_id := building_ids.find("stone_age_hunting_camp")
	var timber_id := building_ids.find("timber_collector")
	var goods: PackedStringArray = catalog.good_ids
	var tool_good := goods.find("chipped_stone_tools")
	_require_materials_for_primitive_collectors(catalog, tool_good)
	_minimize_household_good_demand(catalog, tool_good)
	# Keep this fixture's demand signal deterministic: the hunting camps consume
	# only chipped stone tools and require more than two workshops can supply.
	var input_offsets: PackedInt32Array = catalog.building_input_offsets
	var hunting_input := int(input_offsets[hunting_id])
	var input_quantities: PackedInt64Array = catalog.building_input_quantities
	input_quantities[hunting_input] = 1000
	catalog.building_input_quantities = input_quantities
	var candidate_offsets: PackedInt32Array = catalog.building_input_candidate_offsets
	var candidate_goods: PackedInt32Array = catalog.building_input_candidate_good_ids
	for candidate_idx in range(
			int(candidate_offsets[hunting_input]),
			int(candidate_offsets[hunting_input + 1])):
		candidate_goods[candidate_idx] = tool_good
	catalog.building_input_candidate_good_ids = candidate_goods
	var ext := _new_ext(catalog)
	_expect("owner-investment country bootstraps",
		CountryTestHelper.configure_all_technologies(ext, catalog, 1, 285))
	_expect("owner-investment runtime configures",
		bool(ext.configure_economy(catalog, profile, 1, 285).get("ok", false)))
	var resource_ids: PackedStringArray = catalog.building_resource_ids
	var wild_game_resource := resource_ids.find("wild_game")
	var reserve_slots: PackedStringArray = catalog.building_resource_reserve_slots
	var wild_game_reserve: int = int(ext.component_id(StringName(
		reserve_slots[wild_game_resource])))
	ext.write_f32_range(wild_game_reserve, 0, PackedFloat32Array([1000000000.0]))
	var stock := PackedInt64Array()
	stock.resize(goods.size())
	stock.fill(1000000)
	stock[tool_good] = 0
	var prices: PackedInt32Array = catalog.good_default_price.duplicate()
	prices[tool_good] = int((catalog.good_max_price as PackedInt32Array)[tool_good])
	var boot: Dictionary = ext.bootstrap_economy({
		"cell_indices": PackedInt32Array([0, 0, 0, 0]),
		"signature_ids": PackedInt32Array([
			artisan_sig, hunter_sig, forager_sig, merchant_sig]),
		"population": PackedInt64Array([1, 20, 3, 1]),
		"funds": PackedInt64Array([100000, 500000000, 30000000, 100000000]),
	}, {
		"stock": stock,
		"price": prices,
		"building_cells": PackedInt32Array([0, 0, 0]),
		"building_type_ids": PackedInt32Array([
			knapping_id, hunting_id, timber_id]),
		"building_owner_signature_ids": PackedInt32Array([
			artisan_sig, hunter_sig, forager_sig]),
		"building_counts": PackedInt64Array([2, 10, 3]),
	})
	_expect("owner-investment settlement bootstraps", bool(boot.get("ok", false)))
	var day0 := _run_day(ext, 0)
	var pop0: Dictionary = ext.get_population_cell_snapshot(0)
	var artisan_row0 := _row_for_signature(pop0, artisan_sig)
	var artisan_population0 := int((pop0.populations as PackedInt64Array)[artisan_row0]) \
		if artisan_row0 >= 0 else 0
	_expect("employment fills the existing profitable owner opening first",
		int(day0.get("building_investments_started", 0)) == 0 and
		int(day0.get("building_investment_candidates", 0)) == 0 and
		int(day0.get("building_owner_mobility", 0)) == 0 and
		int(day0.get("building_investment_capital_transferred", 0)) == 0 and
		artisan_population0 == 2)
	_expect("existing owner-opening employment conserves every ledger",
		int(day0.get("population_error", 1)) == 0 and
		int(day0.get("money_error", 1)) == 0 and
		int(day0.get("goods_error", 1)) == 0)
	_run_day(ext, 1)
	var investment_day := _run_day(ext, 2)
	var buildings: Dictionary = ext.get_building_cell_snapshot(0)
	var knapping_count := int((buildings.building_counts_by_type as PackedInt64Array)[
		knapping_id])
	_expect("profitable investment transitions its sponsor and starts construction",
		int(investment_day.get("building_investments_started", 0)) == 1 and
		int(investment_day.get("building_investment_candidates", 0)) == 1 and
		int(investment_day.get("building_owner_mobility", 0)) == 1 and
		int(investment_day.get("building_investment_capital_transferred", 0)) > 0 and
		String(investment_day.get("building_investment_model", "")) ==
			"endogenous_owner_investment_v5" and
		int(investment_day.get("construction_goods_consumed", 0)) == 1500 and
		knapping_count == 3)
	_expect("endogenous construction conserves every ledger",
		int(investment_day.get("population_error", 1)) == 0 and
		int(investment_day.get("money_error", 1)) == 0 and
		int(investment_day.get("goods_error", 1)) == 0)
	var day31 := _run_day(ext, 3)
	buildings = ext.get_building_cell_snapshot(0)
	knapping_count = int((buildings.building_counts_by_type as PackedInt64Array)[
		knapping_id])
	_expect("non-review day prevents repeat expansion",
		int(day31.get("building_investments_started", 0)) == 0 and
		knapping_count == 3)


func _test_zero_construction_collector_investment(source_catalog: Dictionary,
		source_profile: Dictionary) -> void:
	var catalog := source_catalog.duplicate(true)
	var profile := source_profile.duplicate(true)
	profile.starvation_death_rate_q32 = 0
	var signatures: PackedStringArray = catalog.signature_keys
	var artisan_sig := signatures.find("artisan|default")
	var merchant_sig := signatures.find("merchant|default")
	var goods: PackedStringArray = catalog.good_ids
	var prices: PackedInt32Array = catalog.good_max_price.duplicate()
	var stock := PackedInt64Array()
	stock.resize(goods.size())
	stock.fill(0)
	var ext := _new_ext(catalog)
	_expect("zero-construction collector country bootstraps",
		CountryTestHelper.configure_all_technologies(ext, catalog, 1, 9127))
	_expect("zero-construction collector runtime configures",
		bool(ext.configure_economy(catalog, profile, 1, 9127).get("ok", false)))
	var resource_slots: PackedStringArray = catalog.building_resource_reserve_slots
	for slot_name in resource_slots:
		var slot_id := int(ext.component_id(StringName(slot_name)))
		if slot_id >= 0:
			ext.write_f32_range(slot_id, 0, PackedFloat32Array([1000000000.0]))
	var boot: Dictionary = ext.bootstrap_economy({
		"cell_indices": PackedInt32Array([0, 0]),
		"signature_ids": PackedInt32Array([artisan_sig, merchant_sig]),
		"population": PackedInt64Array([8, 1]),
		"funds": PackedInt64Array([1000000000, 100000000]),
	}, {"stock": stock, "price": prices})
	_expect("zero-construction collector fixture bootstraps", bool(boot.get("ok", false)))
	_run_day(ext, 0)
	_run_day(ext, 1)
	var report := _run_day(ext, 2)
	var buildings: Dictionary = ext.get_building_cell_snapshot(0)
	var counts: PackedInt64Array = buildings.building_counts_by_type
	var kinds: PackedInt32Array = catalog.building_kinds
	var construction_offsets: PackedInt32Array = catalog.building_construction_offsets
	var primitive_count := 0
	for type_id in range(kinds.size()):
		if kinds[type_id] == 0 and construction_offsets[type_id] == \
				construction_offsets[type_id + 1]:
			primitive_count += int(counts[type_id])
	_expect("profitable zero-construction collector passes capital and resource gates",
		int(report.get("building_investments_started", 0)) == 1 and
		int(report.get("building_investment_candidates", 0)) == 1 and
		int(report.get("building_owner_mobility", 0)) == 1 and
		int(report.get("building_investment_capital_transferred", 0)) > 0 and
		int(report.get("construction_goods_consumed", -1)) == 0 and
		primitive_count == 1)
	_expect("zero-construction collector investment conserves every ledger",
		int(report.get("population_error", 1)) == 0 and
		int(report.get("money_error", 1)) == 0 and
		int(report.get("goods_error", 1)) == 0)


func _test_investment_capacity_is_not_gate(source_catalog: Dictionary,
		source_profile: Dictionary) -> void:
	var catalog := source_catalog.duplicate(true)
	var profile := source_profile.duplicate(true)
	profile.merchant_market_making_days_q16 = 1966080
	profile.resource_safe_harvest_q16 = 0
	profile.starvation_death_rate_q32 = 0
	var signatures: PackedStringArray = catalog.signature_keys
	var artisan_sig := signatures.find("artisan|default")
	var hunter_sig := signatures.find("hunter|default")
	var forager_sig := signatures.find("forager|default")
	var merchant_sig := signatures.find("merchant|default")
	var building_ids: PackedStringArray = catalog.building_type_ids
	var knapping_id := building_ids.find("knapping_workshop")
	var hunting_id := building_ids.find("stone_age_hunting_camp")
	var goods: PackedStringArray = catalog.good_ids
	var tool_good := goods.find("chipped_stone_tools")
	_require_materials_for_primitive_collectors(catalog, tool_good)
	_minimize_household_good_demand(catalog, tool_good)
	var input_offsets: PackedInt32Array = catalog.building_input_offsets
	var hunting_input := int(input_offsets[hunting_id])
	var input_quantities: PackedInt64Array = catalog.building_input_quantities
	input_quantities[hunting_input] = 1
	catalog.building_input_quantities = input_quantities
	var candidate_offsets: PackedInt32Array = catalog.building_input_candidate_offsets
	var candidate_goods: PackedInt32Array = catalog.building_input_candidate_good_ids
	for candidate_idx in range(
			int(candidate_offsets[hunting_input]),
			int(candidate_offsets[hunting_input + 1])):
		candidate_goods[candidate_idx] = tool_good
	catalog.building_input_candidate_good_ids = candidate_goods
	var ext := _new_ext(catalog)
	_expect("existing-market entry country bootstraps",
		CountryTestHelper.configure_all_technologies(ext, catalog, 1, 287))
	_expect("existing-market entry runtime configures",
		bool(ext.configure_economy(catalog, profile, 1, 287).get("ok", false)))
	var stock := PackedInt64Array()
	stock.resize(goods.size())
	stock.fill(1000000)
	stock[tool_good] = 0
	var prices: PackedInt32Array = catalog.good_default_price.duplicate()
	prices[tool_good] = int((catalog.good_max_price as PackedInt32Array)[tool_good])
	var boot: Dictionary = ext.bootstrap_economy({
		"cell_indices": PackedInt32Array([0, 0, 0, 0]),
		"signature_ids": PackedInt32Array([
			artisan_sig, hunter_sig, forager_sig, merchant_sig]),
		"population": PackedInt64Array([3, 3, 20, 1]),
		"funds": PackedInt64Array([300000000, 300000000, 900000000, 300000000]),
	}, {
		"stock": stock,
		"price": prices,
		"building_cells": PackedInt32Array([0, 0]),
		"building_type_ids": PackedInt32Array([knapping_id, hunting_id]),
		"building_owner_signature_ids": PackedInt32Array([artisan_sig, hunter_sig]),
		"building_counts": PackedInt64Array([3, 3]),
	})
	_expect("existing-market entry fixture bootstraps", bool(boot.get("ok", false)))
	var report := {}
	for day in range(3):
		report = _run_day(ext, day)
	var buildings: Dictionary = ext.get_building_cell_snapshot(0)
	var count := int((buildings.building_counts_by_type as PackedInt64Array)[knapping_id])
	var group := (buildings.group_type_ids as PackedInt32Array).find(knapping_id)
	var rejection := int((buildings.investment_rejection_reason as PackedInt32Array)[group]) \
		if group >= 0 else -1
	_expect("installed capacity no longer rejects an otherwise reviewed entry",
		count == 3 and int(report.get("building_investments_started", 0)) == 0 and
		rejection == 6)
	_expect("existing-market entry review conserves every ledger",
		int(report.get("population_error", 1)) == 0 and
		int(report.get("money_error", 1)) == 0 and
		int(report.get("goods_error", 1)) == 0)

	var coverage_catalog := catalog.duplicate(true)
	var construction_good_ids: PackedInt32Array = \
		coverage_catalog.building_construction_good_ids
	var construction_offsets: PackedInt32Array = \
		coverage_catalog.building_construction_offsets
	var logs_good := goods.find("logs")
	for item in range(int(construction_offsets[knapping_id]),
			int(construction_offsets[knapping_id + 1])):
		construction_good_ids[item] = logs_good
	coverage_catalog.building_construction_good_ids = construction_good_ids
	var flint_good := goods.find("flint")
	var coverage_stock := PackedInt64Array()
	coverage_stock.resize(goods.size())
	coverage_stock.fill(1000000)
	coverage_stock[tool_good] = 0
	coverage_stock[flint_good] = 0
	var coverage_ext := _new_ext(coverage_catalog)
	_expect("input-coverage country bootstraps",
		CountryTestHelper.configure_all_technologies(coverage_ext, coverage_catalog, 1, 289))
	_expect("input-coverage runtime configures", bool(coverage_ext.configure_economy(
		coverage_catalog, profile, 1, 289).get("ok", false)))
	var coverage_boot: Dictionary = coverage_ext.bootstrap_economy({
		"cell_indices": PackedInt32Array([0, 0, 0, 0]),
		"signature_ids": PackedInt32Array([
			artisan_sig, hunter_sig, forager_sig, merchant_sig]),
		"population": PackedInt64Array([3, 3, 20, 1]),
		"funds": PackedInt64Array([300000000, 300000000, 900000000, 300000000]),
	}, {
		"stock": coverage_stock,
		"price": prices,
		"building_cells": PackedInt32Array([0, 0]),
		"building_type_ids": PackedInt32Array([knapping_id, hunting_id]),
		"building_owner_signature_ids": PackedInt32Array([artisan_sig, hunter_sig]),
		"building_counts": PackedInt64Array([3, 3]),
	})
	_expect("input-coverage fixture bootstraps", bool(coverage_boot.get("ok", false)))
	var coverage_report := {}
	for day in range(3):
		coverage_report = _run_day(coverage_ext, day)
	var coverage_buildings: Dictionary = coverage_ext.get_building_cell_snapshot(0)
	var coverage_group := (coverage_buildings.group_type_ids as PackedInt32Array).find(knapping_id)
	_expect("zero hard-input coverage rejects entry as input-chain constrained",
		coverage_group >= 0 and int(coverage_report.get("building_investments_started", 0)) == 0 and
		int((coverage_buildings.investment_rejection_reason as PackedInt32Array)[coverage_group]) == 8)
	_expect("input-coverage review conserves every ledger",
		int(coverage_report.get("population_error", 1)) == 0 and
		int(coverage_report.get("money_error", 1)) == 0 and
		int(coverage_report.get("goods_error", 1)) == 0)


func _test_investment_requires_owner_livelihood(source_catalog: Dictionary,
		source_profile: Dictionary) -> void:
	var catalog := source_catalog.duplicate(true)
	var profile := source_profile.duplicate(true)
	profile.merchant_market_making_days_q16 = 1966080
	profile.resource_safe_harvest_q16 = 0
	profile.starvation_death_rate_q32 = 0
	var signatures: PackedStringArray = catalog.signature_keys
	var artisan_sig := signatures.find("artisan|default")
	var hunter_sig := signatures.find("hunter|default")
	var forager_sig := signatures.find("forager|default")
	var merchant_sig := signatures.find("merchant|default")
	var building_ids: PackedStringArray = catalog.building_type_ids
	var knapping_id := building_ids.find("knapping_workshop")
	var hunting_id := building_ids.find("stone_age_hunting_camp")
	var goods: PackedStringArray = catalog.good_ids
	var tool_good := goods.find("chipped_stone_tools")
	_require_materials_for_primitive_collectors(catalog, tool_good)
	_minimize_household_good_demand(catalog, tool_good)
	var max_prices: PackedInt32Array = catalog.good_max_price.duplicate()
	var default_prices: PackedInt32Array = catalog.good_default_price.duplicate()
	max_prices[tool_good] = 9000
	default_prices[tool_good] = 9000
	catalog.good_max_price = max_prices
	catalog.good_default_price = default_prices
	var input_offsets: PackedInt32Array = catalog.building_input_offsets
	var hunting_input := int(input_offsets[hunting_id])
	var input_quantities: PackedInt64Array = catalog.building_input_quantities
	input_quantities[hunting_input] = 2000
	catalog.building_input_quantities = input_quantities
	var candidate_offsets: PackedInt32Array = catalog.building_input_candidate_offsets
	var candidate_goods: PackedInt32Array = catalog.building_input_candidate_good_ids
	for candidate_idx in range(
			int(candidate_offsets[hunting_input]),
			int(candidate_offsets[hunting_input + 1])):
		candidate_goods[candidate_idx] = tool_good
	catalog.building_input_candidate_good_ids = candidate_goods
	var ext := _new_ext(catalog)
	_expect("owner-livelihood country bootstraps",
		CountryTestHelper.configure_all_technologies(ext, catalog, 1, 288))
	_expect("owner-livelihood runtime configures",
		bool(ext.configure_economy(catalog, profile, 1, 288).get("ok", false)))
	var stock := PackedInt64Array()
	stock.resize(goods.size())
	stock.fill(1000000)
	stock[tool_good] = 0
	var boot: Dictionary = ext.bootstrap_economy({
		"cell_indices": PackedInt32Array([0, 0, 0, 0]),
		"signature_ids": PackedInt32Array([
			artisan_sig, hunter_sig, forager_sig, merchant_sig]),
		"population": PackedInt64Array([1, 20, 20, 1]),
		"funds": PackedInt64Array([1000000, 500000000, 900000000, 300000000]),
	}, {
		"stock": stock,
		"price": default_prices,
		"building_cells": PackedInt32Array([0, 0]),
		"building_type_ids": PackedInt32Array([knapping_id, hunting_id]),
		"building_owner_signature_ids": PackedInt32Array([artisan_sig, hunter_sig]),
		"building_counts": PackedInt64Array([1, 10]),
	})
	_expect("owner-livelihood fixture bootstraps", bool(boot.get("ok", false)))
	var report := {}
	for day in range(3):
		report = _run_day(ext, day)
	var buildings: Dictionary = ext.get_building_cell_snapshot(0)
	var count := int((buildings.building_counts_by_type as PackedInt64Array)[knapping_id])
	var group := (buildings.group_type_ids as PackedInt32Array).find(knapping_id)
	var rejection := int((buildings.investment_rejection_reason as PackedInt32Array)[group]) \
		if group >= 0 else -1
	_expect("shortage cannot approve a workshop that misses owner livelihood",
		count == 1 and int(report.get("building_investments_started", 0)) == 0 and
		rejection == 5)
	_expect("realized workshop margin includes owner livelihood",
		group >= 0 and
		int((buildings.realized_profit_margin_q16 as PackedInt32Array)[group]) < 0)


func _test_endogenous_investment_repairs_dead_merchant(source_catalog: Dictionary,
		source_profile: Dictionary) -> void:
	var catalog := source_catalog.duplicate(true)
	var profile := source_profile.duplicate(true)
	profile.starvation_death_rate_q32 = 0
	var signatures: PackedStringArray = catalog.signature_keys
	var artisan_sig := signatures.find("artisan|default")
	var hunter_sig := signatures.find("hunter|default")
	var forager_sig := signatures.find("forager|default")
	var merchant_sig := signatures.find("merchant|default")
	var death_rates: PackedInt64Array = catalog.signature_death_rate_q32.duplicate()
	death_rates[merchant_sig] = 4294967296
	catalog.signature_death_rate_q32 = death_rates
	var building_ids: PackedStringArray = catalog.building_type_ids
	var knapping_id := building_ids.find("knapping_workshop")
	var hunting_id := building_ids.find("stone_age_hunting_camp")
	var timber_id := building_ids.find("timber_collector")
	var goods: PackedStringArray = catalog.good_ids
	var tool_good := goods.find("chipped_stone_tools")
	_minimize_household_good_demand(catalog, tool_good)
	var input_offsets: PackedInt32Array = catalog.building_input_offsets
	var hunting_input := int(input_offsets[hunting_id])
	var input_quantities: PackedInt64Array = catalog.building_input_quantities
	input_quantities[hunting_input] = 1000
	catalog.building_input_quantities = input_quantities
	var candidate_offsets: PackedInt32Array = catalog.building_input_candidate_offsets
	var candidate_goods: PackedInt32Array = catalog.building_input_candidate_good_ids
	for candidate_idx in range(
			int(candidate_offsets[hunting_input]),
			int(candidate_offsets[hunting_input + 1])):
		candidate_goods[candidate_idx] = tool_good
	catalog.building_input_candidate_good_ids = candidate_goods
	var ext := _new_ext(catalog)
	_expect("dead-merchant investment country bootstraps",
		CountryTestHelper.configure_all_technologies(ext, catalog, 1, 286))
	_expect("dead-merchant investment runtime configures",
		bool(ext.configure_economy(catalog, profile, 1, 286).get("ok", false)))
	var resource_ids: PackedStringArray = catalog.building_resource_ids
	var wild_game_resource := resource_ids.find("wild_game")
	var reserve_slots: PackedStringArray = catalog.building_resource_reserve_slots
	var wild_game_reserve: int = int(ext.component_id(StringName(
		reserve_slots[wild_game_resource])))
	ext.write_f32_range(wild_game_reserve, 0, PackedFloat32Array([1000000000.0]))
	var stock := PackedInt64Array()
	stock.resize(goods.size())
	stock.fill(1000000)
	stock[tool_good] = 0
	var prices: PackedInt32Array = catalog.good_default_price.duplicate()
	prices[tool_good] = int((catalog.good_max_price as PackedInt32Array)[tool_good])
	var boot: Dictionary = ext.bootstrap_economy({
		"cell_indices": PackedInt32Array([0, 0, 0, 0]),
		"signature_ids": PackedInt32Array([
			artisan_sig, hunter_sig, forager_sig, merchant_sig]),
		"population": PackedInt64Array([2, 20, 3, 1]),
		"funds": PackedInt64Array([100000, 500000000, 30000000, 100000000]),
	}, {
		"stock": stock,
		"price": prices,
		"building_cells": PackedInt32Array([0, 0, 0]),
		"building_type_ids": PackedInt32Array([
			knapping_id, hunting_id, timber_id]),
		"building_owner_signature_ids": PackedInt32Array([
			artisan_sig, hunter_sig, forager_sig]),
		"building_counts": PackedInt64Array([2, 10, 3]),
	})
	_expect("dead-merchant investment fixture bootstraps", bool(boot.get("ok", false)))
	var repair_report := _run_day(ext, 0)
	var pop: Dictionary = ext.get_population_cell_snapshot(0)
	_expect("structural commit repairs merchant before the capital review",
		bool(repair_report.get("done", false)) and
		not bool(repair_report.get("fatal", false)) and
		int(repair_report.get("merchant_repairs", 0)) > 0 and
		int(repair_report.get("building_investments_started", 0)) == 0 and
		_sum_u8(pop.merchant_flags as PackedByteArray) == 1)
	_run_day(ext, 1)
	var report := _run_day(ext, 2)
	_expect("repaired merchant supports the next endogenous construction review",
		int(report.get("building_investments_started", 0)) == 1)
	_expect("dead-merchant construction conserves every ledger",
		int(report.get("population_error", 1)) == 0 and
		int(report.get("money_error", 1)) == 0 and
		int(report.get("goods_error", 1)) == 0)


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
	_expect("scarce output remains below its target inventory",
		stock0 < target0)
	_expect("scarce output price rises to the rate-limited producer cost floor",
		price1 >= rate_limited_floor)

func _test_survival_retention_cap(catalog: Dictionary, source_profile: Dictionary) -> void:
	var profile := source_profile.duplicate(true)
	profile.starvation_death_rate_q32 = 0
	var ext := _new_ext(catalog)
	_expect("retention-cap country bootstraps",
		CountryTestHelper.configure_all_technologies(ext, catalog, 1, 179))
	_expect("retention-cap runtime configures",
		bool(ext.configure_economy(catalog, profile, 1, 179).get("ok", false)))
	var signatures: PackedStringArray = catalog.signature_keys
	var forager_sig := signatures.find("forager|default")
	var artisan_sig := signatures.find("artisan|default")
	var merchant_sig := signatures.find("merchant|default")
	var gathering_id := (catalog.building_type_ids as PackedStringArray).find("gathering_ground")
	var goods: PackedStringArray = catalog.good_ids
	var stock := PackedInt64Array()
	stock.resize(goods.size())
	stock.fill(0)
	var boot: Dictionary = ext.bootstrap_economy({
		"cell_indices": PackedInt32Array([0, 0]),
		"signature_ids": PackedInt32Array([forager_sig, merchant_sig]),
		"population": PackedInt64Array([1, 1]),
		"funds": PackedInt64Array([1000000, 100000000]),
	}, {
		"stock": stock,
		"building_cells": PackedInt32Array([0]),
		"building_type_ids": PackedInt32Array([gathering_id]),
		"building_owner_signature_ids": PackedInt32Array([forager_sig]),
		"building_counts": PackedInt64Array([1]),
	})
	_expect("retention-cap settlement bootstraps", bool(boot.get("ok", false)))
	var report := _run_day(ext, 0)
	var buildings: Dictionary = ext.get_building_cell_snapshot(0)
	var output := int((buildings.last_output as PackedInt64Array)[0])
	var retained := int((buildings.last_retained as PackedInt64Array)[0])
	var sold := int((buildings.last_sold as PackedInt64Array)[0])
	var discarded := int((buildings.last_discarded as PackedInt64Array)[0])
	_expect("survival retention is positive but capped below production",
		output > 0 and retained > 0 and retained < output and sold > 0)
	_expect("consumed retained output offsets livelihood without minting cash",
		int((buildings.owner_livelihood_in_kind_credit as PackedInt64Array)[0]) > 0 and
		int(report.get("money_error", 1)) == 0)
	_expect("retention-cap output reconciles sale, retention, and discard",
		output == retained + sold + discarded)
	_expect("retention-cap cycle conserves every ledger",
		int(report.get("population_error", 1)) == 0 and
		int(report.get("money_error", 1)) == 0 and
		int(report.get("goods_error", 1)) == 0)
	var next_report := _run_day(ext, 1)
	buildings = ext.get_building_cell_snapshot(0)
	_expect("survival-food production keeps the subsistence probe floor",
		int((buildings.planned_utilization_q16 as PackedInt32Array)[0]) > 0 and
		int((buildings.planned_utilization_q16 as PackedInt32Array)[0]) <= 65536 and
		int((buildings.planned_utilization_q16 as PackedInt32Array)[0]) >= 65536 / 6)
	_expect("rounding-tolerance cycle conserves every ledger",
		int(next_report.get("population_error", 1)) == 0 and
		int(next_report.get("money_error", 1)) == 0 and
		int(next_report.get("goods_error", 1)) == 0)

func _test_hunter_subsistence_and_working_capital(source_catalog: Dictionary,
		source_profile: Dictionary) -> void:
	var catalog := source_catalog.duplicate(true)
	var hunting_id := (catalog.building_type_ids as PackedStringArray).find(
		"stone_age_hunting_camp")
	var resource_offsets: PackedInt32Array = catalog.building_resource_offsets
	var resource_quantities: PackedInt64Array = catalog.building_production_resource_quantities
	resource_quantities[int(resource_offsets[hunting_id])] = 1
	catalog.building_production_resource_quantities = resource_quantities
	var profile := source_profile.duplicate(true)
	profile.market_cycle_days = 5
	var ext := _new_ext(catalog)
	_expect("hunter-subsistence country bootstraps",
		CountryTestHelper.configure_all_technologies(ext, catalog, 1, 181))
	_expect("hunter-subsistence runtime configures",
		bool(ext.configure_economy(catalog, profile, 1, 181).get("ok", false)))
	var signatures: PackedStringArray = catalog.signature_keys
	var hunter_sig := signatures.find("hunter|default")
	var merchant_sig := signatures.find("merchant|default")
	var goods: PackedStringArray = catalog.good_ids
	var stock := PackedInt64Array()
	stock.resize(goods.size())
	stock.fill(0)
	stock[goods.find("chipped_stone_tools")] = 1000000
	var boot: Dictionary = ext.bootstrap_economy({
		"cell_indices": PackedInt32Array([0, 0]),
		"signature_ids": PackedInt32Array([hunter_sig, merchant_sig]),
		"population": PackedInt64Array([48, 1]),
		"funds": PackedInt64Array([100000, 100000000]),
	}, {
		"stock": stock,
		"building_cells": PackedInt32Array([0]),
		"building_type_ids": PackedInt32Array([hunting_id]),
		"building_owner_signature_ids": PackedInt32Array([hunter_sig]),
		"building_counts": PackedInt64Array([24]),
	})
	_expect("hunter-subsistence settlement bootstraps", bool(boot.get("ok", false)))
	var report := {}
	var ledgers_ok := true
	var reserve_seen := false
	for day in range(120):
		report = _run_day(ext, day)
		ledgers_ok = ledgers_ok and int(report.get("population_error", 1)) == 0 and \
			int(report.get("money_error", 1)) == 0 and int(report.get("goods_error", 1)) == 0
		reserve_seen = reserve_seen or int(report.get("owner_working_capital_reserved", 0)) > 0
	var pop: Dictionary = ext.get_population_cell_snapshot(0)
	var hunter_row := _row_for_signature(pop, hunter_sig)
	var buildings: Dictionary = ext.get_building_cell_snapshot(0)
	_expect("forty-eight hunters finish 120 food-empty market days at healthy satisfaction",
		hunter_row >= 0 and int((pop.populations as PackedInt64Array)[hunter_row]) == 48 and
		int((pop.satisfaction_by_cohort_q16 as PackedInt32Array)[hunter_row]) >= 58982)
	_expect("hunter production stays above the fixed probe and protects next-period tool cash",
		int((buildings.last_output as PackedInt64Array)[0]) > 0 and
		int((buildings.planned_utilization_q16 as PackedInt32Array)[0]) > 65536 / 6 and
		int((buildings.funded_capacity_q16 as PackedInt64Array)[0]) ==
			int((buildings.purchase_intent_capacity_q16 as PackedInt64Array)[0]) and
		reserve_seen)
	_expect("hunter-subsistence cycles conserve every ledger", ledgers_ok)

func _test_shortage_recovery_uses_household_stock(source_catalog: Dictionary,
		source_profile: Dictionary) -> void:
	var catalog := source_catalog.duplicate(true)
	var profile := source_profile.duplicate(true)
	profile.market_cycle_days = 5
	profile.starvation_death_rate_q32 = 0
	var building_ids: PackedStringArray = catalog.building_type_ids
	var gathering_id := building_ids.find("gathering_ground")
	var hearth_id := building_ids.find("communal_hearth")
	var output_offsets: PackedInt32Array = catalog.building_output_offsets
	var output_quantities: PackedInt64Array = catalog.building_output_quantities
	output_quantities[int(output_offsets[gathering_id])] = 500
	catalog.building_output_quantities = output_quantities
	var ext := _new_ext(catalog)
	_expect("household-stock recovery country bootstraps",
		CountryTestHelper.configure_all_technologies(ext, catalog, 1, 183))
	_expect("household-stock recovery runtime configures",
		bool(ext.configure_economy(catalog, profile, 1, 183).get("ok", false)))
	var signatures: PackedStringArray = catalog.signature_keys
	var forager_sig := signatures.find("forager|default")
	var artisan_sig := signatures.find("artisan|default")
	var merchant_sig := signatures.find("merchant|default")
	var goods: PackedStringArray = catalog.good_ids
	var plant_id := goods.find("gathered_plants")
	var stock := PackedInt64Array()
	stock.resize(goods.size())
	stock[plant_id] = 1000000
	var boot: Dictionary = ext.bootstrap_economy({
		"cell_indices": PackedInt32Array([0, 0, 0]),
		"signature_ids": PackedInt32Array([forager_sig, artisan_sig, merchant_sig]),
		"population": PackedInt64Array([1, 1, 1]),
		"funds": PackedInt64Array([100000000, 100000000, 100000000]),
	}, {
		"stock": stock,
		"building_cells": PackedInt32Array([0, 0]),
		"building_type_ids": PackedInt32Array([gathering_id, hearth_id]),
		"building_owner_signature_ids": PackedInt32Array([forager_sig, artisan_sig]),
		"building_counts": PackedInt64Array([1, 1]),
	})
	_expect("household-stock recovery settlement bootstraps", bool(boot.get("ok", false)))
	_run_day(ext, 0)
	var priority_market: Dictionary = ext.get_market_cell_snapshot(0)
	_expect("non-survival hearth cannot reserve staple food ahead of households",
		_good_value(priority_market, "production_input_reserve", "gathered_plants") == 0)
	_run_day(ext, 1)
	var market0: Dictionary = ext.get_market_cell_snapshot(0)
	var removable := maxi(0, _good_value(market0, "stock", "gathered_plants") - 1)
	var remove_result: Dictionary = ext.submit_economy_commands({
		"opcodes": PackedInt32Array([5]),
		"effective_days": PackedInt64Array([2]),
		"sequences": PackedInt64Array([1]),
		"target_handles": PackedInt64Array([0]),
		"i32_0": PackedInt32Array([0]),
		"i32_1": PackedInt32Array([plant_id]),
		"i64_0": PackedInt64Array([removable]),
		"i64_1": PackedInt64Array([0]),
	})
	_expect("household-stock recovery drain queues", bool(remove_result.get("ok", false)))
	_run_day(ext, 2)
	var buildings1: Dictionary = ext.get_building_cell_snapshot(0)
	var row1 := (buildings1.group_type_ids as PackedInt32Array).find(gathering_id)
	var utilization1 := int((buildings1.planned_utilization_q16 as PackedInt32Array)[row1])
	var market1: Dictionary = ext.get_market_cell_snapshot(0)
	var household1 := _good_value(market1, "household_available_stock", "gathered_plants")
	_run_day(ext, 3)
	var buildings2: Dictionary = ext.get_building_cell_snapshot(0)
	var row2 := (buildings2.group_type_ids as PackedInt32Array).find(gathering_id)
	var utilization2 := int((buildings2.planned_utilization_q16 as PackedInt32Array)[row2])
	_expect("one-unit raw stock does not block shortage recovery",
		row1 >= 0 and row2 >= 0 and household1 <= 1 and
		utilization2 >= utilization1 and utilization2 > 0)

func _test_business_demand_recovers_industrial_utilization(
		source_catalog: Dictionary, source_profile: Dictionary) -> void:
	var catalog := source_catalog.duplicate(true)
	var profile := source_profile.duplicate(true)
	profile.starvation_death_rate_q32 = 0
	var building_ids: PackedStringArray = catalog.building_type_ids
	var knapping_id := building_ids.find("knapping_workshop")
	var timber_id := building_ids.find("timber_collector")
	var goods: PackedStringArray = catalog.good_ids
	var tool_good := goods.find("chipped_stone_tools")
	var logs_good := goods.find("logs")
	_minimize_household_good_demand(catalog, tool_good)
	_require_materials_for_primitive_collectors(catalog, tool_good)
	var input_offsets: PackedInt32Array = catalog.building_input_offsets
	var timber_input := int(input_offsets[timber_id])
	var candidate_offsets: PackedInt32Array = catalog.building_input_candidate_offsets
	var candidate_goods: PackedInt32Array = catalog.building_input_candidate_good_ids
	for candidate_idx in range(
			int(candidate_offsets[timber_input]),
			int(candidate_offsets[timber_input + 1])):
		candidate_goods[candidate_idx] = tool_good
	catalog.building_input_candidate_good_ids = candidate_goods
	var ext := _new_ext(catalog)
	_expect("business-demand recovery country bootstraps",
		CountryTestHelper.configure_all_technologies(ext, catalog, 1, 187))
	_expect("business-demand recovery runtime configures",
		bool(ext.configure_economy(catalog, profile, 1, 187).get("ok", false)))
	var signatures: PackedStringArray = catalog.signature_keys
	var artisan_sig := signatures.find("artisan|default")
	var forager_sig := signatures.find("forager|default")
	var merchant_sig := signatures.find("merchant|default")
	var stock := PackedInt64Array()
	stock.resize(goods.size())
	stock.fill(1000000)
	stock[tool_good] = 0
	stock[logs_good] = 0
	var boot: Dictionary = ext.bootstrap_economy({
		"cell_indices": PackedInt32Array([0, 0, 0]),
		"signature_ids": PackedInt32Array([artisan_sig, forager_sig, merchant_sig]),
		"population": PackedInt64Array([1, 3, 1]),
		"funds": PackedInt64Array([200000, 200000, 1000000000]),
	}, {
		"stock": stock,
		"building_cells": PackedInt32Array([0, 0]),
		"building_type_ids": PackedInt32Array([knapping_id, timber_id]),
		"building_owner_signature_ids": PackedInt32Array([artisan_sig, forager_sig]),
		"building_counts": PackedInt64Array([1, 3]),
	})
	_expect("business-demand recovery fixture bootstraps", bool(boot.get("ok", false)))
	var ledgers_ok := true
	for day in range(7):
		var report := _run_day(ext, day)
		ledgers_ok = ledgers_ok and int(report.get("population_error", 1)) == 0 and \
			int(report.get("money_error", 1)) == 0 and \
			int(report.get("goods_error", 1)) == 0
	var market: Dictionary = ext.get_market_cell_snapshot(0)
	var buildings: Dictionary = ext.get_building_cell_snapshot(0)
	var group := (buildings.group_type_ids as PackedInt32Array).find(knapping_id)
	var utilization := int((buildings.planned_utilization_q16 as PackedInt32Array)[group]) \
		if group >= 0 else 0
	_expect("business-only tool demand remains visible to production planning",
		_good_value(market, "business_demand_ema", "chipped_stone_tools") > 0 and
		_good_value(market, "demand_ema", "chipped_stone_tools") == 0)
	_expect("business shortage keeps knapping above the industrial probe floor",
		group >= 0 and utilization > 65536 / 32)
	_expect("business-demand recovery cycles conserve every ledger", ledgers_ok)

func _test_production_input_hard_reserve(source_catalog: Dictionary,
		source_profile: Dictionary) -> void:
	var catalog := source_catalog.duplicate(true)
	var profile := source_profile.duplicate(true)
	profile.starvation_death_rate_q32 = 0
	var building_ids: PackedStringArray = catalog.building_type_ids
	var knapping_id := building_ids.find("knapping_workshop")
	var hunting_id := building_ids.find("stone_age_hunting_camp")
	var output_offsets: PackedInt32Array = catalog.building_output_offsets
	var output_quantities: PackedInt64Array = catalog.building_output_quantities
	output_quantities[int(output_offsets[knapping_id])] = 12
	catalog.building_output_quantities = output_quantities
	var ext := _new_ext(catalog)
	_expect("input-reserve country bootstraps",
		CountryTestHelper.configure_all_technologies(ext, catalog, 1, 181))
	_expect("input-reserve runtime configures",
		bool(ext.configure_economy(catalog, profile, 1, 181).get("ok", false)))
	var signatures: PackedStringArray = catalog.signature_keys
	var artisan_sig := signatures.find("artisan|default")
	var hunter_sig := signatures.find("hunter|default")
	var merchant_sig := signatures.find("merchant|default")
	var goods: PackedStringArray = catalog.good_ids
	var tool_id := goods.find("chipped_stone_tools")
	var stock := PackedInt64Array()
	stock.resize(goods.size())
	stock.fill(0)
	stock[goods.find("flint")] = 1000000
	stock[tool_id] = 10
	var boot: Dictionary = ext.bootstrap_economy({
		"cell_indices": PackedInt32Array([0, 0, 0]),
		"signature_ids": PackedInt32Array([artisan_sig, hunter_sig, merchant_sig]),
		"population": PackedInt64Array([1, 2, 1]),
		"funds": PackedInt64Array([100000000, 100000000, 100000000]),
	}, {
		"stock": stock,
		"building_cells": PackedInt32Array([0, 0]),
		"building_type_ids": PackedInt32Array([knapping_id, hunting_id]),
		"building_owner_signature_ids": PackedInt32Array([artisan_sig, hunter_sig]),
		"building_counts": PackedInt64Array([1, 1]),
	})
	_expect("input-reserve settlement bootstraps", bool(boot.get("ok", false)))
	var day0 := _run_day(ext, 0)
	var market0: Dictionary = ext.get_market_cell_snapshot(0)
	var reserve0 := _good_value(market0, "production_input_reserve", "chipped_stone_tools")
	var stock0 := _good_value(market0, "stock", "chipped_stone_tools")
	var household0 := _good_value(market0, "household_available_stock", "chipped_stone_tools")
	_expect("tool stock protects the complete next-period hunting input",
		reserve0 > 0 and household0 == maxi(0, stock0 - reserve0) and
		int(day0.get("production_input_reserved", 0)) > 0 and
		int(day0.get("production_input_reserve_shortfall", -1)) >=
			maxi(0, reserve0 - stock0))
	var day1 := _run_day(ext, 1)
	var buildings: Dictionary = ext.get_building_cell_snapshot(0)
	var types: PackedInt32Array = buildings.group_type_ids
	var hunting_row := types.find(hunting_id)
	_expect("reserved tools start the next hunting period",
		hunting_row >= 0 and
		int((buildings.last_input as PackedInt64Array)[hunting_row]) > 0 and
		int((buildings.last_output as PackedInt64Array)[hunting_row]) > 0)
	_expect("input-reserve cycles conserve every ledger",
		int(day0.get("population_error", 1)) == 0 and
		int(day0.get("money_error", 1)) == 0 and
		int(day0.get("goods_error", 1)) == 0 and
		int(day1.get("population_error", 1)) == 0 and
		int(day1.get("money_error", 1)) == 0 and
		int(day1.get("goods_error", 1)) == 0)

func _test_production_input_soft_shortage(source_catalog: Dictionary,
		source_profile: Dictionary) -> void:
	var profile := source_profile.duplicate(true)
	profile.market_cycle_days = 5
	profile.starvation_death_rate_q32 = 0
	var no_tool := _run_hunting_soft_input_case(source_catalog, profile, 0, 184)
	var full_tool := _run_hunting_soft_input_case(source_catalog, profile, 1000000, 185)
	_expect("soft hunting input keeps partial output without tools",
		int(no_tool.get("output", 0)) > 0 and int(no_tool.get("input", -1)) == 0)
	_expect("soft hunting input still rewards available tools",
		int(full_tool.get("output", 0)) > int(no_tool.get("output", 0)) and
		int(full_tool.get("input", 0)) > 0)
	_expect("soft-input shortage cycles conserve every ledger",
		bool(no_tool.get("ledgers_ok", false)) and bool(full_tool.get("ledgers_ok", false)))

func _run_hunting_soft_input_case(catalog: Dictionary, profile: Dictionary,
		tool_stock: int, seed: int) -> Dictionary:
	var ext := _new_ext(catalog)
	_expect("soft-input country bootstraps %d" % seed,
		CountryTestHelper.configure_all_technologies(ext, catalog, 1, seed))
	_expect("soft-input runtime configures %d" % seed,
		bool(ext.configure_economy(catalog, profile, 1, seed).get("ok", false)))
	var signatures: PackedStringArray = catalog.signature_keys
	var hunter_sig := signatures.find("hunter|default")
	var merchant_sig := signatures.find("merchant|default")
	var hunting_id := (catalog.building_type_ids as PackedStringArray).find("stone_age_hunting_camp")
	var goods: PackedStringArray = catalog.good_ids
	var stock := PackedInt64Array()
	stock.resize(goods.size())
	stock.fill(0)
	stock[goods.find("chipped_stone_tools")] = tool_stock
	var boot: Dictionary = ext.bootstrap_economy({
		"cell_indices": PackedInt32Array([0, 0]),
		"signature_ids": PackedInt32Array([hunter_sig, merchant_sig]),
		"population": PackedInt64Array([2, 1]),
		"funds": PackedInt64Array([100000000, 100000000]),
	}, {
		"stock": stock,
		"building_cells": PackedInt32Array([0]),
		"building_type_ids": PackedInt32Array([hunting_id]),
		"building_owner_signature_ids": PackedInt32Array([hunter_sig]),
		"building_counts": PackedInt64Array([1]),
	})
	_expect("soft-input settlement bootstraps %d" % seed, bool(boot.get("ok", false)))
	var report := _run_day(ext, 0)
	var buildings: Dictionary = ext.get_building_cell_snapshot(0)
	return {
		"output": int((buildings.last_output as PackedInt64Array)[0]),
		"input": int((buildings.last_input as PackedInt64Array)[0]),
		"capacity_q16": int((buildings.capacity_q16 as PackedInt64Array)[0]),
		"ledgers_ok": int(report.get("population_error", 1)) == 0 and
			int(report.get("money_error", 1)) == 0 and
			int(report.get("goods_error", 1)) == 0,
	}

func _test_producer_support_issuance(source_catalog: Dictionary,
		source_profile: Dictionary) -> void:
	var catalog := source_catalog.duplicate(true)
	var profile := source_profile.duplicate(true)
	profile.starvation_death_rate_q32 = 0
	var ext := _new_ext(catalog)
	_expect("producer-support country bootstraps",
		CountryTestHelper.configure_all_technologies(ext, catalog, 1, 182))
	_expect("producer-support runtime configures",
		bool(ext.configure_economy(catalog, profile, 1, 182).get("ok", false)))
	var signatures: PackedStringArray = catalog.signature_keys
	var owner_sig := signatures.find("industrialist|default")
	var worker_sig := signatures.find("industrial_worker|default")
	var manager_sig := signatures.find("manager|default")
	var merchant_sig := signatures.find("merchant|default")
	var plant_id := (catalog.building_type_ids as PackedStringArray).find("staple_food_plant")
	var output_good := (catalog.good_ids as PackedStringArray).find("prepared_staples")
	var stock := PackedInt64Array()
	stock.resize((catalog.good_ids as PackedStringArray).size())
	stock.fill(1000000)
	stock[output_good] = 0
	var boot: Dictionary = ext.bootstrap_economy({
		"cell_indices": PackedInt32Array([0, 0, 0, 0]),
		"signature_ids": PackedInt32Array([
			owner_sig, worker_sig, manager_sig, merchant_sig]),
		"population": PackedInt64Array([5, 100, 10, 10]),
		"funds": PackedInt64Array([100000000, 0, 0, 0]),
	}, {
		"stock": stock,
		"building_cells": PackedInt32Array([0]),
		"building_type_ids": PackedInt32Array([plant_id]),
		"building_owner_signature_ids": PackedInt32Array([owner_sig]),
		"building_counts": PackedInt64Array([1]),
	})
	_expect("producer-support settlement bootstraps", bool(boot.get("ok", false)))
	_expect("producer-support trace target registers",
		bool(ext.set_economy_inspector_trace_cell(0).get("ok", false)))
	var opening_market: Dictionary = ext.get_market_cell_snapshot(0)
	var opening_price := int((opening_market.price as PackedInt32Array)[output_good])
	var report := _run_day(ext, 0)
	var supported := int(report.get("production_output_supported", 0))
	var issued := int(report.get("producer_support_money_issued", 0))
	var expected_issued := maxi(1, int((supported * opening_price) / 5000))
	var buildings: Dictionary = ext.get_building_cell_snapshot(0)
	var output := int((buildings.last_output as PackedInt64Array)[0])
	var retained := int((buildings.last_retained as PackedInt64Array)[0])
	var accepted := int((buildings.last_sold as PackedInt64Array)[0])
	_expect("zero-cash merchant spends nothing on producer output",
		int(report.get("merchant_procurement_spent", -1)) == 0)
	_expect("support accepts every storable remainder without discard",
		supported > 0 and accepted == supported and
		output == retained + accepted and
		int(report.get("production_output_discarded", -1)) == 0)
	_expect("support issuance uses exactly twenty percent of frozen retail value",
		issued == expected_issued and
		int(report.get("producer_support_price_numerator", 0)) == 1 and
		int(report.get("producer_support_price_denominator", 0)) == 5)
	var pop: Dictionary = ext.get_population_cell_snapshot(0)
	var owner_row := _row_for_signature(pop, owner_sig)
	_expect("support issuance is a distinct producer cashflow",
		_cashflow_has_source(pop, owner_row, "producer_support_issuance", true))
	_expect("support issuance is explicitly audited",
		int(report.get("approximation_version", 0)) == 15 and
		str(report.get("approximation_model", "")) ==
			"rolling_cell_settlement_v15" and
		int(report.get("population_error", 1)) == 0 and
		int(report.get("money_error", 1)) == 0 and
		int(report.get("goods_error", 1)) == 0)

func _test_cycle_flow_output_clears_before_discard(source_catalog: Dictionary,
		source_profile: Dictionary) -> void:
	var catalog := source_catalog.duplicate(true)
	var profile := source_profile.duplicate(true)
	profile.starvation_death_rate_q32 = 0
	var ext := _new_ext(catalog)
	_expect("cycle-flow clearing country bootstraps",
		CountryTestHelper.configure_all_technologies(ext, catalog, 1, 283))
	_expect("cycle-flow clearing runtime configures",
		bool(ext.configure_economy(catalog, profile, 1, 283).get("ok", false)))
	var signatures: PackedStringArray = catalog.signature_keys
	var owner_sig := signatures.find("industrialist|default")
	var worker_sig := signatures.find("industrial_worker|default")
	var electrician_sig := signatures.find("electrician|default")
	var technician_sig := signatures.find("technician|default")
	var manager_sig := signatures.find("manager|default")
	var merchant_sig := signatures.find("merchant|default")
	var plant_id := (catalog.building_type_ids as PackedStringArray).find("electricity_plant")
	var goods: PackedStringArray = catalog.good_ids
	var stock := PackedInt64Array()
	stock.resize(goods.size())
	stock.fill(0)
	stock[goods.find("coal")] = 100000000
	stock[goods.find("tools")] = 100000000
	var boot: Dictionary = ext.bootstrap_economy({
		"cell_indices": PackedInt32Array([0, 0, 0, 0, 0, 0]),
		"signature_ids": PackedInt32Array([
			owner_sig, worker_sig, electrician_sig, technician_sig,
			manager_sig, merchant_sig]),
		"population": PackedInt64Array([5, 100, 20, 20, 20, 10]),
		"funds": PackedInt64Array([100000000, 0, 0, 0, 0, 0]),
	}, {
		"stock": stock,
		"building_cells": PackedInt32Array([0]),
		"building_type_ids": PackedInt32Array([plant_id]),
		"building_owner_signature_ids": PackedInt32Array([owner_sig]),
		"building_counts": PackedInt64Array([1]),
	})
	_expect("cycle-flow clearing settlement bootstraps", bool(boot.get("ok", false)))
	var report := _run_day(ext, 0)
	var buildings: Dictionary = ext.get_building_cell_snapshot(0)
	var supported := int(report.get("production_output_supported", 0))
	var output := int((buildings.last_output as PackedInt64Array)[0])
	var accepted := int((buildings.last_sold as PackedInt64Array)[0])
	var discarded := int((buildings.last_discarded as PackedInt64Array)[0])
	_expect("cycle-flow output receives low-price clearing before discard",
		output > 0 and supported > 0 and accepted == output and discarded == 0 and
		int(report.get("production_output_discarded", -1)) == 0)
	_expect("cycle-flow clearing still discards transient stock at boundary",
		int(report.get("cycle_flow_discarded", 0)) >= supported and
		int(report.get("cycle_flow_produced", 0)) >= supported)
	_expect("cycle-flow support cycle conserves every ledger",
		int(report.get("population_error", 1)) == 0 and
		int(report.get("money_error", 1)) == 0 and
		int(report.get("goods_error", 1)) == 0)

func _test_construction_shortage_feeds_procurement_signal(source_catalog: Dictionary,
		source_profile: Dictionary) -> void:
	var catalog := source_catalog.duplicate(true)
	var profile := source_profile.duplicate(true)
	profile.starvation_death_rate_q32 = 0
	var building_ids: PackedStringArray = catalog.building_type_ids
	var mine_id := building_ids.find("coal_mine")
	var raw_stone_good := (catalog.good_ids as PackedStringArray).find("raw_stone")
	var offsets: PackedInt32Array = catalog.building_construction_offsets
	var old_good_ids: PackedInt32Array = catalog.building_construction_good_ids
	var old_quantities: PackedInt64Array = catalog.building_construction_quantities
	var insert_at := int(offsets[mine_id + 1])
	var new_good_ids := PackedInt32Array()
	var new_quantities := PackedInt64Array()
	for i in range(old_good_ids.size() + 1):
		if i == insert_at:
			new_good_ids.push_back(raw_stone_good)
			new_quantities.push_back(1000000)
		if i < old_good_ids.size():
			new_good_ids.push_back(int(old_good_ids[i]))
			new_quantities.push_back(int(old_quantities[i]))
	for i in range(mine_id + 1, offsets.size()):
		offsets[i] += 1
	catalog.building_construction_offsets = offsets
	catalog.building_construction_good_ids = new_good_ids
	catalog.building_construction_quantities = new_quantities
	var ext := _new_ext(catalog)
	_expect("construction-shortage country bootstraps",
		CountryTestHelper.configure_all_technologies(ext, catalog, 1, 284))
	_expect("construction-shortage runtime configures",
		bool(ext.configure_economy(catalog, profile, 1, 284).get("ok", false)))
	var signatures: PackedStringArray = catalog.signature_keys
	var owner_sig := signatures.find("industrialist|default")
	var worker_sig := signatures.find("miner|default")
	var manager_sig := signatures.find("manager|default")
	var merchant_sig := signatures.find("merchant|default")
	var goods: PackedStringArray = catalog.good_ids
	var stock := PackedInt64Array()
	stock.resize(goods.size())
	stock.fill(1000000)
	stock[raw_stone_good] = 0
	var boot: Dictionary = ext.bootstrap_economy({
		"cell_indices": PackedInt32Array([0, 0, 0, 0]),
		"signature_ids": PackedInt32Array([owner_sig, worker_sig, manager_sig, merchant_sig]),
		"population": PackedInt64Array([5, 100, 10, 10]),
		"funds": PackedInt64Array([100000000, 1000000, 1000000, 10000000]),
	}, {"stock": stock})
	_expect("construction-shortage settlement bootstraps", bool(boot.get("ok", false)))
	var pop: Dictionary = ext.get_population_cell_snapshot(0)
	var owner_handle := _handle_for_profession(pop, owner_sig)
	var submit: Dictionary = ext.submit_economy_commands({
		"opcodes": PackedInt32Array([10]),
		"effective_days": PackedInt64Array([0]),
		"sequences": PackedInt64Array([201]),
		"target_handles": PackedInt64Array([owner_handle]),
		"i32_0": PackedInt32Array([0]),
		"i32_1": PackedInt32Array([mine_id]),
		"i64_0": PackedInt64Array([1]),
		"i64_1": PackedInt64Array([0]),
	})
	_expect("construction-shortage build command queues", bool(submit.get("ok", false)))
	var report := _run_day(ext, 0)
	var market: Dictionary = ext.get_market_cell_snapshot(0)
	_expect("construction shortage rejects the build command",
		int(report.get("rejected_commands", 0)) > 0 and
		str(report.get("last_building_rejection_reason", "")) ==
			"building_construction_stock_insufficient")
	_expect("construction shortage is converted into demand",
		_good_value(market, "business_demand_ema", "raw_stone") > 0)
	_expect("construction shortage contributes to merchant target",
		_good_value(market, "merchant_inventory_target", "raw_stone") > 0 and
		int(report.get("population_error", 1)) == 0 and
		int(report.get("money_error", 1)) == 0 and
		int(report.get("goods_error", 1)) == 0)

func _test_building_plan_continuation(source_catalog: Dictionary,
		source_profile: Dictionary) -> void:
	const CELL_COUNT := 20
	var catalog := source_catalog.duplicate(true)
	var profile := source_profile.duplicate(true)
	profile.market_cycle_days = 5
	profile.auto_slice_by_scale = false
	profile.cells_per_slice = CELL_COUNT
	profile.building_cells_per_slice = 1
	var sliced := _new_ext(catalog, CELL_COUNT)
	_expect("continuation country bootstraps",
		CountryTestHelper.configure_all_technologies(sliced, catalog, CELL_COUNT, 991))
	_expect("continuation runtime configures",
		bool(sliced.configure_economy(catalog, profile, CELL_COUNT, 991).get("ok", false)))
	_expect("continuation fixture bootstraps",
		_bootstrap_continuation_fixture(sliced, catalog, CELL_COUNT))
	var report: Dictionary = sliced.run_economy_slice({"day_index": 0, "tick_index": 0})
	_expect("one-cell building budget enters bounded continuation",
		not bool(report.get("done", true)) and
		not bool(report.get("fatal", false)) and
		str(report.get("stage", "")) == "building_plan" and
		int(report.get("building_cells_per_slice", 0)) == 1)
	for slice in range(1, 256):
		report = sliced.run_economy_slice({"day_index": 0, "tick_index": slice})
		if bool(report.get("done", false)):
			break
	_expect("due rolling bucket completes through continuation slices",
		bool(report.get("done", false)) and
		not bool(report.get("fatal", false)) and
		int(report.get("deferred_cells", -1)) == 0 and
		int(report.get("continuation_slices", 0)) > 1)
	var save_attempt: Dictionary = sliced.begin_economy_save(65536)
	_expect("completed rolling transaction can save immediately",
		bool(save_attempt.get("ok", false)))
	if bool(save_attempt.get("ok", false)):
		while not sliced.read_economy_save_chunk(65536).is_empty():
			pass
		sliced.end_economy_save()
	_expect("sliced building plan commits with exact conservation",
		bool(report.get("done", false)) and not bool(report.get("fatal", false)) and
		int(report.get("population_error", 1)) == 0 and
		int(report.get("money_error", 1)) == 0 and
		int(report.get("goods_error", 1)) == 0)

	var reference_profile := profile.duplicate(true)
	reference_profile.building_cells_per_slice = CELL_COUNT
	var reference := _new_ext(catalog, CELL_COUNT)
	_expect("reference continuation country bootstraps",
		CountryTestHelper.configure_all_technologies(reference, catalog, CELL_COUNT, 991))
	_expect("reference continuation runtime configures",
		bool(reference.configure_economy(
			catalog, reference_profile, CELL_COUNT, 991).get("ok", false)))
	_expect("reference continuation fixture bootstraps",
		_bootstrap_continuation_fixture(reference, catalog, CELL_COUNT))
	var reference_report := _run_day(reference, 0)
	_expect("continuation slice budget preserves authoritative hash",
		bool(reference_report.get("done", false)) and
		sliced.get_economy_state_hash() == reference.get_economy_state_hash())

func _test_production_worker_scalar_equivalence(source_catalog: Dictionary,
		source_profile: Dictionary) -> void:
	const CELL_COUNT := 80
	var catalog := source_catalog.duplicate(true)
	var scalar_profile := source_profile.duplicate(true)
	scalar_profile.worker_enabled = false
	scalar_profile.worker_market_threshold = 1
	scalar_profile.building_cells_per_slice = CELL_COUNT
	scalar_profile.auto_slice_by_scale = false
	var worker_profile := scalar_profile.duplicate(true)
	worker_profile.worker_enabled = true
	worker_profile.worker_tasks_hint = 4
	var scalar := _new_ext(catalog, CELL_COUNT)
	var worker := _new_ext(catalog, CELL_COUNT)
	_expect("production scalar country bootstraps",
		CountryTestHelper.configure_all_technologies(scalar, catalog, CELL_COUNT, 997))
	_expect("production worker country bootstraps",
		CountryTestHelper.configure_all_technologies(worker, catalog, CELL_COUNT, 997))
	_expect("production scalar runtime configures", bool(scalar.configure_economy(
		catalog, scalar_profile, CELL_COUNT, 997).get("ok", false)))
	_expect("production worker runtime configures", bool(worker.configure_economy(
		catalog, worker_profile, CELL_COUNT, 997).get("ok", false)))
	_expect("production scalar fixture bootstraps",
		_bootstrap_continuation_fixture(scalar, catalog, CELL_COUNT))
	_expect("production worker fixture bootstraps",
		_bootstrap_continuation_fixture(worker, catalog, CELL_COUNT))
	var scalar_report := _run_day(scalar, 0)
	var worker_report := _run_day(worker, 0)
	_expect("building production dispatches multiple worker tasks",
		int(worker_report.get("building_production_worker_tasks", 1)) > 1)
	_expect("building production worker and scalar hashes match",
		scalar.get_economy_state_hash() == worker.get_economy_state_hash())
	_expect("building production worker and scalar event hashes match",
		int(scalar.get_economy_trace_report().get("stream_hash", 0)) ==
		int(worker.get_economy_trace_report().get("stream_hash", 1)))
	_expect("building production worker conserves all ledgers",
		int(worker_report.get("population_error", 1)) == 0 and
		int(worker_report.get("money_error", 1)) == 0 and
		int(worker_report.get("goods_error", 1)) == 0)

func _bootstrap_continuation_fixture(ext: Object, catalog: Dictionary,
		cell_count: int) -> bool:
	var signatures: PackedStringArray = catalog.signature_keys
	var owner_sig := signatures.find("industrialist|default")
	var worker_sig := signatures.find("miner|default")
	var manager_sig := signatures.find("manager|default")
	var merchant_sig := signatures.find("merchant|default")
	var mine_id := (catalog.building_type_ids as PackedStringArray).find("coal_mine")
	var cells := PackedInt32Array()
	var cohort_signatures := PackedInt32Array()
	var populations := PackedInt64Array()
	var funds := PackedInt64Array()
	var building_cells := PackedInt32Array()
	var building_types := PackedInt32Array()
	var building_owners := PackedInt32Array()
	var building_counts := PackedInt64Array()
	var fixture_signatures := [owner_sig, worker_sig, manager_sig, merchant_sig]
	var fixture_populations := [2, 20, 4, 4]
	var fixture_funds := [10000000, 1000000, 1000000, 5000000]
	for cell in range(cell_count):
		for index in range(fixture_signatures.size()):
			cells.push_back(cell)
			cohort_signatures.push_back(fixture_signatures[index])
			populations.push_back(fixture_populations[index])
			funds.push_back(fixture_funds[index])
		building_cells.push_back(cell)
		building_types.push_back(mine_id)
		building_owners.push_back(owner_sig)
		building_counts.push_back(1)
	var result: Dictionary = ext.bootstrap_economy({
		"cell_indices": cells,
		"signature_ids": cohort_signatures,
		"population": populations,
		"funds": funds,
	}, {
		"building_cells": building_cells,
		"building_type_ids": building_types,
		"building_owner_signature_ids": building_owners,
		"building_counts": building_counts,
	})
	return bool(result.get("ok", false))

func _new_ext(catalog: Dictionary, cell_count: int = 1) -> Object:
	var ext: Object = ClassDB.instantiate("DCWorldExt")
	ext.create_entities(cell_count)
	var scalar := PackedFloat32Array()
	scalar.resize(cell_count)
	scalar.fill(0.5)
	for slot_name in [&"cell_temp", &"cell_moisture", &"cell_snow_cover", &"cell_weather_intensity", &"cell_elevation"]:
		var sid: int = ext.register_component(slot_name, 0, 1, false)
		ext.write_f32_range(sid, 0, scalar)
	var zero_u8 := PackedByteArray()
	zero_u8.resize(cell_count)
	zero_u8.fill(0)
	for slot_name in [&"cell_terrain", &"cell_landform", &"cell_vegetation", &"cell_is_water", &"cell_has_river"]:
		var sid: int = ext.register_component(slot_name, 2, 1, false)
		ext.write_u8_range(sid, 0, zero_u8)
	var reserve_slots: PackedStringArray = catalog.building_resource_reserve_slots
	var extra_slots: PackedStringArray = catalog.building_resource_extra_slots
	var resource_ids: PackedStringArray = catalog.building_resource_ids
	for i in range(resource_ids.size()):
		var reserve_sid: int = ext.register_component(StringName(reserve_slots[i]), 0, 1, false)
		var extra_sid: int = ext.register_component(StringName(extra_slots[i]), 0, 1, false)
		var reserve := PackedFloat32Array()
		reserve.resize(cell_count)
		reserve.fill(1000.0)
		var extra := PackedFloat32Array()
		extra.resize(cell_count)
		extra.fill(0.0)
		ext.write_f32_range(reserve_sid, 0, reserve)
		ext.write_f32_range(extra_sid, 0, extra)
	return ext

func _run_day(ext: Object, day: int) -> Dictionary:
	var report := {}
	var simulation_day := day * 5
	for slice in range(256):
		report = ext.run_economy_slice({
			"day_index": simulation_day,
			"tick_index": simulation_day * 1000 + slice,
		})
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


func _sum_i64(values: PackedInt64Array) -> int:
	var total := 0
	for value in values:
		total += int(value)
	return total


func _sum_u8(values: PackedByteArray) -> int:
	var total := 0
	for value in values:
		total += int(value)
	return total


func _require_materials_for_primitive_collectors(
		catalog: Dictionary, blocking_good: int) -> void:
	var kinds: PackedInt32Array = catalog.building_kinds
	var old_offsets: PackedInt32Array = catalog.building_construction_offsets
	var old_goods: PackedInt32Array = catalog.building_construction_good_ids
	var old_quantities: PackedInt64Array = catalog.building_construction_quantities
	var offsets := PackedInt32Array([0])
	var goods := PackedInt32Array()
	var quantities := PackedInt64Array()
	for type_id in range(kinds.size()):
		for edge in range(int(old_offsets[type_id]), int(old_offsets[type_id + 1])):
			goods.append(old_goods[edge])
			quantities.append(old_quantities[edge])
		if kinds[type_id] == 0 and old_offsets[type_id] == old_offsets[type_id + 1]:
			goods.append(blocking_good)
			quantities.append(1000000000000)
		offsets.append(goods.size())
	catalog.building_construction_offsets = offsets
	catalog.building_construction_good_ids = goods
	catalog.building_construction_quantities = quantities


func _minimize_household_good_demand(catalog: Dictionary, good_id: int) -> void:
	var component_goods: PackedInt32Array = catalog.component_good_ids
	var component_quantities: PackedInt64Array = catalog.component_qty_per_need.duplicate()
	for component in range(component_goods.size()):
		if int(component_goods[component]) == good_id:
			component_quantities[component] = 1
	catalog.component_qty_per_need = component_quantities

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
