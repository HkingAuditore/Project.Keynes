extends SceneTree

# Historical CI file name retained. This is the focused Market V2 test suite.

const EconomyCatalogScript = preload("res://scripts/economy/economy_catalog.gd")
const CountryTestHelper = preload("res://tests/country_test_helper.gd")

var _checks := 0
var _failures := 0

func _init() -> void:
	_run()
	quit(0 if _failures == 0 else 1)

func _run() -> void:
	print("=== native market v2 runtime test ===")
	var default_profile: Dictionary = load(
		"res://data/economy/default_economy.tres").to_native_profile()
	_expect("default profile raises building goods output without changing recipe costs",
		int(default_profile.get("building_output_efficiency_q16", 0)) == 131072)
	var catalog: Dictionary = EconomyCatalogScript.compile_native_catalog()
	_expect("catalog compiles", bool(catalog.get("ok", false)))
	if not bool(catalog.get("ok", false)):
		print(catalog)
		_finish()
		return
	_expect("modern goods catalog is sorted and retains legacy stable ids",
		(catalog.good_ids as PackedStringArray).size() >= 120 and
		(catalog.good_ids as PackedStringArray).has("cloth") and
		(catalog.good_ids as PackedStringArray).has("coal") and
		(catalog.good_ids as PackedStringArray).has("fur") and
		(catalog.good_ids as PackedStringArray).has("grain") and
		(catalog.good_ids as PackedStringArray).has("meat"))
	_expect("merchant profession compiles", (catalog.profession_ids as PackedStringArray).has("merchant"))
	_expect("modern household needs compile", (catalog.need_ids as PackedStringArray).size() == 20 and
		(catalog.need_ids as PackedStringArray).has("staple_food") and
		(catalog.need_ids as PackedStringArray).has("healthcare") and
		(catalog.need_ids as PackedStringArray).has("work_equipment") and
		(catalog.need_ids as PackedStringArray).has("status_goods"))
	var carrying_ids: PackedStringArray = catalog.get("carrying_family_ids", PackedStringArray())
	_expect("carrying catalog compiles twenty-one need and producer families",
		carrying_ids.size() == 21 and carrying_ids[0] == "staple" and
		carrying_ids[16] == "status" and carrying_ids[17] == "construction" and
		(catalog.carrying_family_good_offsets as PackedInt32Array).size() == 22 and
		(catalog.carrying_support_resource_ids as PackedInt32Array).size() == 7)
	var living_weights: PackedInt32Array = catalog.need_living_cost_weights_q16
	var need_ids: PackedStringArray = catalog.need_ids
	_expect("living cost weights classify essential consumer and luxury needs",
		int(living_weights[need_ids.find("staple_food")]) == 65536 and
		int(living_weights[need_ids.find("communication")]) == 32768 and
		int(living_weights[need_ids.find("luxury")]) == 0)
	var good_ids: PackedStringArray = catalog.good_ids
	var inventory_ratios: PackedInt32Array = catalog.good_inventory_target_ratios_q16
	_expect("inventory ratios prioritize essentials over ordinary and luxury goods",
		int(inventory_ratios[good_ids.find("prepared_staples")]) == 98304 and
		int(inventory_ratios[good_ids.find("pharmaceuticals")]) == 81920 and
		int(inventory_ratios[good_ids.find("tools")]) == 65536 and
		int(inventory_ratios[good_ids.find("jewelry")]) == 43691 and
		int(inventory_ratios[good_ids.find("electricity")]) == 0)
	_expect("stone food keeps explicit merchant inventory horizons",
		int(inventory_ratios[good_ids.find("gathered_plants")]) == 65536 and
		int(inventory_ratios[good_ids.find("game_meat")]) == 98304 and
		int(inventory_ratios[good_ids.find("processed_food")]) == 43691 and
		int(inventory_ratios[good_ids.find("fish")]) == 98304)
	_expect("need catalog compiles total quantity price response",
		(catalog.need_price_quantity_elasticity_q16 as PackedInt32Array).size() ==
		(catalog.need_stable_ids as PackedInt32Array).size() and
		(catalog.need_price_quantity_floor_q16 as PackedInt32Array).size() ==
		(catalog.need_stable_ids as PackedInt32Array).size())
	_expect("old fur slot removed", DCComponentSchema.find_by_name(&"cell.goods_fur_qty").is_empty())
	var birth_rates: PackedInt64Array = catalog.signature_birth_rate_q32
	var death_rates: PackedInt64Array = catalog.signature_death_rate_q32
	var birth_weights: PackedInt64Array = catalog.signature_satisfaction_birth_weight_q16
	_expect("profession defaults compile calibrated natural demography",
		birth_rates.size() > 0 and birth_rates[0] == 2353407 and
		death_rates.size() == birth_rates.size() and death_rates[0] == 294176 and
		birth_weights.size() == birth_rates.size() and birth_weights[0] == 65536)
	if not ClassDB.class_exists("DCWorldExt"):
		print("  [SKIP] DCWorldExt unavailable")
		_finish()
		return
	var stable_catalog := _without_natural_demography(catalog)
	_test_default_active_gate(stable_catalog)
	_test_merchant_trade_and_save(stable_catalog)
	_test_economy_event_trace(stable_catalog)
	_test_environment_substitution(stable_catalog)
	_test_price_quantity_response(stable_catalog)
	_test_price_v3_numeric_guards_and_horizons(stable_catalog)
	_test_price_rise_fade_and_soft_ceiling(stable_catalog)
	_test_survival_labor_and_mortality(stable_catalog)
	_test_demand_preview_query(stable_catalog)
	_test_cycle_approximation(stable_catalog)
	_test_cycle_deadline_catchup(stable_catalog)
	_test_worker_scalar_equivalence(catalog)
	_test_satisfaction_driven_births(catalog)
	_finish()

func _without_natural_demography(compiled: Dictionary) -> Dictionary:
	var result := compiled.duplicate(true)
	var births: PackedInt64Array = result.signature_birth_rate_q32
	var deaths: PackedInt64Array = result.signature_death_rate_q32
	births.fill(0)
	deaths.fill(0)
	result.signature_birth_rate_q32 = births
	result.signature_death_rate_q32 = deaths
	return result

func _test_satisfaction_driven_births(compiled: Dictionary) -> void:
	const POPULATION := 1000000
	var healthy := _new_ext(1, 0.5)
	var deprived := _new_ext(1, 0.5)
	var catalog := compiled.duplicate(true)
	catalog.erase("ok")
	var profile := _native_profile(false, 1)
	profile.starvation_death_rate_q32 = 0
	profile.carrying_k_habitat_ref = 2000000
	profile.carrying_k_floor = 2000000
	profile.carrying_surplus_elasticity_q16 = 0
	profile.carrying_sat_elasticity_q16 = 0
	for ext in [healthy, deprived]:
		_expect("birth fixture country bootstraps",
			CountryTestHelper.configure_all_technologies(ext, catalog, 1, 2201))
		_expect("birth fixture runtime configures",
			bool(ext.configure_economy(catalog, profile, 1, 2201).get("ok", false)))
	var worker_sig: int = (compiled.signature_keys as PackedStringArray).find("worker|default")
	var unemployed_sig: int = (compiled.signature_keys as PackedStringArray).find("unemployed|default")
	var stock := PackedInt64Array()
	stock.resize((compiled.good_ids as PackedStringArray).size())
	stock.fill(1000000000000)
	var population_packet := {
		"cell_indices": PackedInt32Array([0]),
		"signature_ids": PackedInt32Array([worker_sig]),
		"population": PackedInt64Array([POPULATION]),
		"funds": PackedInt64Array([1000000000000000]),
	}
	_expect("healthy birth fixture bootstraps", bool(healthy.bootstrap_economy(
		population_packet, {"stock": stock,
			"price": compiled.good_default_price}).get("ok", false)))
	var deprived_packet := population_packet.duplicate(true)
	deprived_packet.funds = PackedInt64Array([0])
	_expect("deprived birth fixture bootstraps",
		bool(deprived.bootstrap_economy(deprived_packet, {}).get("ok", false)))
	var healthy_report := _run_day(healthy, 0)
	var deprived_report := _run_day(deprived, 0)
	_expect("healthy satisfaction produces births above natural deaths",
		int(healthy_report.get("births", 0)) > int(healthy_report.get("deaths", 0)) and
		int(healthy_report.get("population_error", 1)) == 0)
	_expect("deprivation does not zero births via uninvented needs",
		int(deprived_report.get("births", 0)) >= 0 and
		int(healthy_report.get("births", 0)) >= int(deprived_report.get("births", 0)) and
		int(deprived_report.get("population_error", 1)) == 0)
	var healthy_pop: Dictionary = healthy.get_population_cell_snapshot(0)
	var signatures: PackedInt32Array = healthy_pop.signature_ids
	var newborn_row := signatures.find(unemployed_sig)
	_expect("births aggregate into a zero-fund same-ethnicity unemployed cohort",
		newborn_row >= 0 and
		int((healthy_pop.populations as PackedInt64Array)[newborn_row]) ==
			int(healthy_report.get("births", 0)) and
		int((healthy_pop.funds_by_cohort as PackedInt64Array)[newborn_row]) == 0 and
		int((healthy_pop.owner_employed_by_cohort as PackedInt64Array)[newborn_row]) == 0 and
		int((healthy_pop.employee_employed_by_cohort as PackedInt64Array)[newborn_row]) == 0)

func _test_default_active_gate(compiled: Dictionary) -> void:
	var ext: Object = _new_ext(1, 0.5)
	var catalog := compiled.duplicate(true)
	catalog.erase("ok")
	var profile = load("res://data/economy/default_economy.tres")
	_expect("default profile configures as ACTIVE", bool(ext.configure_economy(
		catalog, profile.to_native_profile(), 1, 1).get("ok", false)))
	var boot: Dictionary = ext.bootstrap_economy({}, {})
	_expect("empty ACTIVE bootstrap succeeds", bool(boot.get("ok", false)))
	_expect("default domestic trade mode is ACTIVE",
		String(ext.get_economy_report().get("trade_runtime_mode", "")) == "ACTIVE")
	_expect("small empty world locks daily market cadence",
		int(boot.get("market_cycle_days", 0)) == 1 and
		int(boot.get("locked_market_cycle_days", 0)) == 1 and
		int(boot.get("locked_slow_cycle_days", 0)) >= 5 and
		int(boot.get("locked_slow_cycle_days", 0)) <= 30)
	_expect("profile market cycle is the 1–5 cap, not a forced five-day lock",
		int(boot.get("market_configured_cycle_days", -1)) == 5 and
		int(boot.get("market_min_cycle_days", 0)) == 1 and
		int(boot.get("market_max_cycle_days", 0)) == 5 and
		bool(boot.get("workload_deadline_feasible", false)))
	var scaled_ext: Object = _new_ext(1200, 0.5)
	_expect("scaled auto profile configures", bool(scaled_ext.configure_economy(
		catalog, profile.to_native_profile(), 1200, 2).get("ok", false)))
	var scaled_boot: Dictionary = scaled_ext.bootstrap_economy({}, {})
	_expect("empty large maps still lock daily because only populated work counts",
		int(scaled_boot.get("market_cycle_days", 0)) == 1 and
		int(scaled_boot.get("settlement_phase_count", 0)) == 1 and
		int(scaled_boot.get("market_max_cycle_days", 0)) == 5 and
		bool(scaled_boot.get("workload_deadline_feasible", false)))
	_expect("default merchant inventory baseline is sixty days",
		int(ext.get_economy_report().get("merchant_market_making_days_q16", 0)) == 3932160)
	_expect("ACTIVE enters production scheduler", bool(ext.economy_should_run(0)) and
		String(ext.get_economy_report().get("market_runtime_mode", "")) == "ACTIVE")

func _test_survival_labor_and_mortality(compiled: Dictionary) -> void:
	var goods: PackedStringArray = compiled.good_ids
	var staple_stock := {
		"prepared_staples": 1000000, "bread": 1000000, "grain": 1000000,
		"gathered_plants": 1000000, "potatoes": 1000000,
	}
	var hot := _new_ext(1, 1.0)
	var catalog := compiled.duplicate(true)
	catalog.erase("ok")
	var hot_profile := _native_profile(false, 1)
	hot_profile.starvation_death_rate_q32 = 429496730
	_expect("hot survival test country bootstraps",
		CountryTestHelper.configure_all_technologies(hot, catalog, 1, 141))
	_expect("hot survival runtime configures",
		bool(hot.configure_economy(catalog, hot_profile, 1, 141).get("ok", false)))
	var worker_sig: int = (compiled.signature_keys as PackedStringArray).find("worker|default")
	var unemployed_sig: int = (compiled.signature_keys as PackedStringArray).find("unemployed|default")
	hot.bootstrap_economy({
		"cell_indices": PackedInt32Array([0]),
		"signature_ids": PackedInt32Array([worker_sig]),
		"population": PackedInt64Array([100]),
		"funds": PackedInt64Array([100000000]),
	}, {})
	hot.submit_economy_commands(_stock_commands(0, goods, staple_stock, 0))
	var hot_report := _run_day(hot, 0)
	var hot_pop: Dictionary = hot.get_population_cell_snapshot(0)
	var hot_satisfaction: PackedInt32Array = hot_pop.satisfaction_by_cohort_q16
	var hot_survives := true
	for value in hot_satisfaction:
		hot_survives = hot_survives and int(value) >= 32768
	_expect("staples alone prevent starvation and heat waives clothing",
		hot_survives and int(hot_report.get("deaths", -1)) == 0 and
		int(hot_report.get("population_error", 1)) == 0 and
		_good_value(hot.get_market_cell_snapshot(0), "stock", "fish") == 0)

	# Every terminal household food is a complete substitute inside one food
	# sub-basket. Pin the full catalog so later content edits cannot silently make
	# fish, wild game, dairy, tubers, or another valid food starvation-irrelevant.
	var survival_food_ids := PackedStringArray([
		"prepared_staples", "bread", "grain", "gathered_plants", "potatoes",
		"game_meat", "meat", "fish", "canned_fish", "dairy_products",
		"vegetables", "processed_food",
	])
	for food_index in range(survival_food_ids.size()):
		var food_id := String(survival_food_ids[food_index])
		var food_only := _new_ext(1, 1.0)
		var food_seed := 144 + food_index
		_expect("%s survival test country bootstraps" % food_id,
			CountryTestHelper.configure_all_technologies(food_only, catalog, 1, food_seed))
		_expect("%s survival runtime configures" % food_id,
			bool(food_only.configure_economy(
				catalog, hot_profile, 1, food_seed).get("ok", false)))
		food_only.bootstrap_economy({
			"cell_indices": PackedInt32Array([0]),
			"signature_ids": PackedInt32Array([unemployed_sig]),
			"population": PackedInt64Array([100]),
			"funds": PackedInt64Array([100000000]),
		}, {})
		food_only.submit_economy_commands(
			_stock_commands(0, goods, {food_id: 1000000}, 0))
		var food_report := _run_day(food_only, 0)
		var food_satisfaction: PackedInt32Array = food_only.get_population_cell_snapshot(
			0).satisfaction_by_cohort_q16
		var food_survives := true
		for value in food_satisfaction:
			food_survives = food_survives and int(value) >= 32768
		_expect("a complete %s food basket prevents starvation" % food_id,
			food_survives and int(food_report.get("deaths", -1)) == 0 and
			int(food_report.get("population_error", 1)) == 0)

	var cold := _new_ext(1, 0.0)
	var cold_profile := _native_profile(false, 1)
	cold_profile.starvation_death_rate_q32 = 429496730
	_expect("cold starvation test country bootstraps",
		CountryTestHelper.configure_all_technologies(cold, catalog, 1, 142))
	_expect("cold starvation runtime configures",
		bool(cold.configure_economy(catalog, cold_profile, 1, 142).get("ok", false)))
	cold.bootstrap_economy({
		"cell_indices": PackedInt32Array([0]),
		"signature_ids": PackedInt32Array([worker_sig]),
		"population": PackedInt64Array([100]),
		"funds": PackedInt64Array([100000000]),
	}, {})
	cold.submit_economy_commands(_stock_commands(0, goods, {
		"cloth": 1000000, "fur": 1000000, "clothing": 1000000,
		"footwear": 1000000,
	}, 0))
	var cold_report := _run_day(cold, 0)
	_expect("food deprivation causes deterministic audited deaths",
		int(cold_report.get("deaths", 0)) > 0 and
		int(cold_report.get("population_error", 1)) == 0 and
		int(cold.get_population_cell_summary(0).population) < 100)

	var exposed := _new_ext(1, 0.0)
	var exposed_profile := _native_profile(false, 1)
	exposed_profile.starvation_death_rate_q32 = 429496730
	_expect("cold exposure test country bootstraps",
		CountryTestHelper.configure_all_technologies(exposed, catalog, 1, 143))
	_expect("cold exposure runtime configures",
		bool(exposed.configure_economy(catalog, exposed_profile, 1, 143).get("ok", false)))
	exposed.bootstrap_economy({
		"cell_indices": PackedInt32Array([0]),
		"signature_ids": PackedInt32Array([worker_sig]),
		"population": PackedInt64Array([100]),
		"funds": PackedInt64Array([100000000]),
	}, {})
	exposed.submit_economy_commands(_stock_commands(0, goods, staple_stock, 0))
	var exposed_report := _run_day(exposed, 0)
	_expect("missing clothing adds mortality only in severe cold",
		int(exposed_report.get("deaths", 0)) > 0 and
		int(exposed_report.get("population_error", 1)) == 0)

func _test_merchant_trade_and_save(compiled: Dictionary) -> void:
	var ext: Object = _new_ext(1, 0.1)
	var catalog := compiled.duplicate(true)
	catalog.erase("ok")
	var profile := _native_profile(true, 1)
	_expect("all-technology market test country bootstraps",
		CountryTestHelper.configure_all_technologies(ext, catalog, 1, 42))
	var configured: Dictionary = ext.configure_economy(catalog, profile, 1, 42)
	_expect("configure market v2", bool(configured.get("ok", false)))
	var worker_sig: int = (compiled.signature_keys as PackedStringArray).find("worker|default")
	var boot: Dictionary = ext.bootstrap_economy({
		"cell_indices": PackedInt32Array([0]),
		"signature_ids": PackedInt32Array([worker_sig]),
		"population": PackedInt64Array([100]),
		"funds": PackedInt64Array([10000000]),
	}, {})
	_expect("bootstrap inserts merchant", bool(boot.get("ok", false)) and int(boot.merchant_repairs) == 1)
	var before_pop: Dictionary = ext.get_population_cell_snapshot(0)
	_expect("population conserved while merchant created", int(before_pop.population) == 100)
	_expect("merchant and worker cohorts exist", int(before_pop.cohort_count) == 2)
	var merchant_flags: PackedByteArray = before_pop.merchant_flags
	_expect("exactly one merchant cohort", _sum_u8(merchant_flags) == 1)
	var before_total_funds := _sum_i64(before_pop.funds_by_cohort)
	var merchant_before := _merchant_funds(before_pop)

	var goods: PackedStringArray = compiled.good_ids
	var commands := _stock_commands(0, goods, {
		"grain": 1000000,
		"meat": 500000,
		"cloth": 250000,
		"fur": 250000,
	}, 0)
	var submitted: Dictionary = ext.submit_economy_commands(commands)
	_expect("explicit stock mint command accepted", bool(submitted.get("ok", false)))
	var before_market: Dictionary = ext.get_market_cell_snapshot(0)
	var report := _run_day(ext, 0)
	_expect("daily market commits", bool(report.get("done", false)) and not bool(report.get("fatal", false)))
	print("  [household-workload] needs=%d variants=%d components=%d" % [
		int(report.get("processed_needs", -1)), int(report.get("processed_variants", -1)),
		int(report.get("processed_components", -1))])
	# Daily N=1 on a one-cell opening world does not take the 5-day shortage
	# fallback path; that path adds extra component visits when N>1.
	_expect("worker and merchant process the bounded catalog shape",
		int(report.get("processed_needs", -1)) == 12 \
		and int(report.get("processed_variants", -1)) == 54 \
		and int(report.get("processed_components", -1)) == 47)
	_expect("market population conservation exact", int(report.get("population_error", 1)) == 0)
	_expect("market money conservation exact", int(report.get("money_error", 1)) == 0)
	_expect("market goods conservation exact", int(report.get("goods_error", 1)) == 0)
	var after_pop: Dictionary = ext.get_population_cell_snapshot(0)
	var after_market: Dictionary = ext.get_market_cell_snapshot(0)
	_expect("buyers transfer money without mint", _sum_i64(after_pop.funds_by_cohort) == before_total_funds)
	_expect("merchant receives sales income", _merchant_funds(after_pop) > merchant_before)
	_expect("grain stock consumed", _good_value(after_market, "stock", "grain") < _good_value(before_market, "stock", "grain") + 1000000)
	_expect("demand ema published", _good_value(after_market, "demand_ema", "grain") > 0)
	_expect("next-day price differs", _good_value(after_market, "price", "grain") != _good_value(before_market, "price", "grain"))
	_expect("market has no anonymous cash", not after_market.has("market_cash"))

	var country: Dictionary = ext.get_country_cell_summary(0)
	var cohort_handle := int((after_pop.handles as PackedInt64Array)[0])
	var grain_idx := goods.find("grain")
	ext.submit_economy_commands(_single_command(9, 1, cohort_handle, 0, 0, 10000,
		int(country.country_handle)))
	var cash_in_report := _run_day(ext, 1)
	_expect("cohort cash transfers into its country treasury",
		int(ext.get_country_cell_summary(0).cash) == 10000 and
		int(cash_in_report.get("money_error", 1)) == 0)
	ext.submit_economy_commands(_single_command(1, 2, cohort_handle, 0, 0, 4000,
		int(country.country_handle)))
	var cash_out_report := _run_day(ext, 2)
	_expect("country cash transfer is capped and conservative",
		int(ext.get_country_cell_summary(0).cash) == 6000 and
		int(cash_out_report.get("money_error", 1)) == 0)
	ext.submit_economy_commands(_single_command(13, 3, int(country.country_handle), 0,
		grain_idx, 1000, 0))
	var goods_in_report := _run_day(ext, 3)
	if bool(goods_in_report.get("fatal", false)):
		print("  goods-in fatal report=", goods_in_report)
	_expect("market goods transfer into country treasury conserves goods",
		_good_value(ext.get_country_treasury_snapshot(country.country_handle), "quantities", "grain") == 1000 and
		int(goods_in_report.get("goods_error", 1)) == 0)
	ext.submit_economy_commands(_single_command(12, 4, int(country.country_handle), 0,
		grain_idx, 400, 0))
	var goods_out_report := _run_day(ext, 4)
	if bool(goods_out_report.get("fatal", false)):
		print("  goods-out fatal report=", goods_out_report)
	_expect("country goods transfer back to market conserves goods",
		_good_value(ext.get_country_treasury_snapshot(country.country_handle), "quantities", "grain") == 600 and
		int(goods_out_report.get("goods_error", 1)) == 0)

	var country_save_begin: Dictionary = ext.begin_country_save(4096)
	if not bool(country_save_begin.get("ok", false)):
		print("  PKCN begin failed=", country_save_begin)
	_expect("matching PKCN save begins", bool(country_save_begin.get("ok", false)))
	var country_chunks: Array[PackedByteArray] = []
	while true:
		var country_chunk: PackedByteArray = ext.read_country_save_chunk(4096)
		if country_chunk.is_empty():
			break
		country_chunks.append(country_chunk)
	_expect("matching PKCN save completes", bool(ext.end_country_save().get("ok", false)))

	var save_begin: Dictionary = ext.begin_economy_save(65536)
	if not bool(save_begin.get("ok", false)):
		print("  PKEC begin failed=", save_begin)
	_expect("v49 save begins at committed boundary", bool(save_begin.get("ok", false)) and int(save_begin.schema_version) == 49)
	var chunks: Array[PackedByteArray] = []
	while true:
		var chunk: PackedByteArray = ext.read_economy_save_chunk(65536)
		if chunk.is_empty():
			break
		chunks.append(chunk)
	_expect("v49 save emits chunks", chunks.size() >= 12)
	_expect("v49 save completes", bool(ext.end_economy_save().get("ok", false)))
	var legacy_target: Object = _new_ext(1, 0.1)
	legacy_target.configure_economy(catalog, profile, 1, 42)
	legacy_target.begin_economy_restore()
	var legacy_header: PackedByteArray = chunks[0].duplicate()
	legacy_header[4] = 29
	legacy_header[5] = 0
	var legacy_result: Dictionary = legacy_target.feed_economy_restore_chunk(legacy_header)
	_expect("PKEC v29 is rejected precisely",
		not bool(legacy_result.get("ok", true)) and
		String(legacy_result.get("reason", "")) == "economy_save_price_v6_requires_new_game")
	var mismatch_target: Object = _new_ext(1, 0.1)
	var mismatch_catalog := catalog.duplicate(true)
	mismatch_catalog["catalog_hash"] = int(catalog.catalog_hash) + 1
	_expect("changed consumption catalog configures as a distinct catalog",
		bool(mismatch_target.configure_economy(mismatch_catalog, profile, 1, 42).get("ok", false)))
	mismatch_target.begin_economy_restore()
	var mismatch_result: Dictionary = mismatch_target.feed_economy_restore_chunk(chunks[0])
	_expect("old catalog hash save is rejected precisely",
		not bool(mismatch_result.get("ok", true)) and
		String(mismatch_result.get("reason", "")) == "save_catalog_scale_or_capacity_mismatch")
	var restored: Object = _new_ext(1, 0.1)
	_expect("restore target configures", bool(restored.configure_economy(catalog, profile, 1, 42).get("ok", false)))
	_expect("PKCN restore begins before PKEC", bool(restored.begin_country_restore().get("ok", false)))
	for chunk in country_chunks:
		_expect("PKCN restore chunk accepted", bool(restored.feed_country_restore_chunk(chunk).get("ok", false)))
	_expect("matching PKCN restores first", bool(restored.end_country_restore().get("ok", false)))
	_expect("restore begins", bool(restored.begin_economy_restore().get("ok", false)))
	for chunk in chunks:
		_expect("restore chunk accepted", bool(restored.feed_economy_restore_chunk(chunk).get("ok", false)))
	_expect("restore completes", bool(restored.end_economy_restore().get("ok", false)))
	var source_hash: int = ext.get_economy_state_hash()
	var restored_hash: int = restored.get_economy_state_hash()
	_expect("v29 stream restore hash exact", source_hash == restored_hash)

func _test_economy_event_trace(compiled: Dictionary) -> void:
	var ext: Object = _new_ext(1, 0.2)
	var catalog := compiled.duplicate(true)
	catalog.erase("ok")
	var profile := _native_profile(false, 64)
	_expect("event trace configures", bool(ext.configure_economy(catalog, profile, 1, 4242).get("ok", false)))
	var worker_sig: int = (compiled.signature_keys as PackedStringArray).find("worker|default")
	_expect("event trace bootstraps", bool(ext.bootstrap_economy({
		"cell_indices": PackedInt32Array([0]),
		"signature_ids": PackedInt32Array([worker_sig]),
		"population": PackedInt64Array([20]),
		"funds": PackedInt64Array([2000000]),
	}, {}).get("ok", false)))
	_expect("trace filter accepted", bool(ext.set_economy_trace_filter({
		"cells": PackedInt32Array([0])}).get("ok", false)))
	_expect("inspector welfare trace accepted", bool(
		ext.set_economy_inspector_trace_cell(0).get("ok", false)))
	var schema: Dictionary = ext.get_economy_event_schema()
	var kinds: Dictionary = schema.get("kinds", {})
	var cashflow_sources: Dictionary = schema.get("cashflow_sources", {})
	_expect("economy event schema exposes support issuance and settlement kinds",
		int(schema.get("version", 0)) == 5 and
		int(kinds.get("MARKET_SETTLED", 0)) > 0 and
		int(kinds.get("EPOCH_COMMITTED", 0)) > 0 and
		int(kinds.get("POPULATION_SOURCE", 0)) > 0 and
		int(cashflow_sources.get("PRODUCER_SUPPORT_ISSUANCE", 0)) > 0)
	var goods: PackedStringArray = compiled.good_ids
	ext.submit_economy_commands(_stock_commands(0, goods, {
		"grain": 100000, "meat": 50000, "cloth": 50000, "fur": 50000}, 0))
	_expect("in-flight event journal remains private", int(ext.poll_economy_events({
		"consumer_id": &"trace_test", "max_events": 128}).get("count", -1)) == 0)
	var report := _run_day(ext, 0)
	_expect("event epoch commits without changing audits", bool(report.get("done", false)) and
		int(report.get("population_error", 1)) == 0 and int(report.get("money_error", 1)) == 0 and
		int(report.get("goods_error", 1)) == 0)
	var batch: Dictionary = ext.poll_economy_events({
		"consumer_id": &"trace_test", "max_events": 128})
	var state_after_commit: int = ext.get_economy_state_hash()
	var event_kinds: PackedInt32Array = batch.get("kind", PackedInt32Array())
	_expect("committed batch contains command market and epoch events",
		event_kinds.has(int(kinds.get("COMMAND_SETTLED", -1))) and
		event_kinds.has(int(kinds.get("MARKET_SETTLED", -1))) and
		event_kinds.has(int(kinds.get("EPOCH_COMMITTED", -1))))
	_expect("selected cell emits exact delta legs",
		(batch.get("leg_field", PackedInt32Array()) as PackedInt32Array).size() > 0)
	var welfare: Dictionary = ext.get_population_cell_snapshot(0)
	var cohort_count := int(welfare.get("cohort_count", 0))
	var good_count := int(welfare.get("demand_attribution_good_count", 0))
	_expect("selected cell publishes bounded need satisfaction and living standards",
		bool(welfare.get("welfare_detail_available", false)) and
		(welfare.get("overall_satisfaction_by_cohort_q16", PackedInt32Array()) as PackedInt32Array).size() == cohort_count and
		(welfare.get("living_standard_level_by_cohort", PackedInt32Array()) as PackedInt32Array).size() == cohort_count and
		(welfare.get("welfare_need_offsets", PackedInt32Array()) as PackedInt32Array).size() == cohort_count + 1)
	_expect("selected cell demand attribution aligns with cohort and good columns",
		good_count == (compiled.good_ids as PackedStringArray).size() and
		(welfare.get("demand_wealth_delta_per_capita_daily", PackedInt64Array()) as PackedInt64Array).size() == cohort_count * good_count and
		(welfare.get("demand_price_delta_per_capita_daily", PackedInt64Array()) as PackedInt64Array).size() == cohort_count * good_count)
	var last_event: int = int(batch.get("last_event_id", 0))
	ext.ack_economy_events(&"trace_test", last_event)
	_expect("consumer ack advances independently", int(ext.poll_economy_events({
		"consumer_id": &"trace_test", "max_events": 128}).get("count", -1)) == 0)
	var trace_report: Dictionary = ext.get_economy_trace_report()
	_expect("trace report is bounded and untruncated", int(trace_report.get("memory_bytes", 0)) <=
		int(trace_report.get("memory_budget_bytes", 0)) and
		int(trace_report.get("detail_truncated_count", 1)) == 0 and
		int(trace_report.get("stream_hash", 0)) != 0)
	var archive_begin: Dictionary = ext.begin_economy_event_archive(65536)
	var archive_chunks := 0
	if bool(archive_begin.get("ok", false)):
		while true:
			var archive_chunk: PackedByteArray = ext.read_economy_event_archive_chunk(65536)
			if archive_chunk.is_empty():
				break
			archive_chunks += 1
	_expect("PKEJ archive streams header events and end", bool(archive_begin.get("ok", false)) and
		archive_chunks >= 3 and bool(ext.end_economy_event_archive().get("ok", false)))
	_expect("event queries do not mutate economy state", state_after_commit != 0 and
		ext.get_economy_state_hash() == state_after_commit)

func _test_environment_substitution(compiled: Dictionary) -> void:
	var cold: Object = _configured_single_worker(compiled, 0.0, 77)
	var warm: Object = _configured_single_worker(compiled, 1.0, 77)
	var goods: PackedStringArray = compiled.good_ids
	var stock := {"grain": 1000000, "meat": 1000000, "cloth": 1000000, "fur": 1000000}
	_expect("cold stock accepted", bool(cold.submit_economy_commands(_stock_commands(0, goods, stock, 0)).get("ok", false)))
	_expect("warm stock accepted", bool(warm.submit_economy_commands(_stock_commands(0, goods, stock, 0)).get("ok", false)))
	_run_day(cold, 0)
	_run_day(warm, 0)
	var cold_market: Dictionary = cold.get_market_cell_snapshot(0)
	var warm_market: Dictionary = warm.get_market_cell_snapshot(0)
	var cold_fur_used: int = 1000000 - _good_value(cold_market, "stock", "fur")
	var warm_fur_used: int = 1000000 - _good_value(warm_market, "stock", "fur")
	print("  fur substitution cold_used=%d warm_used=%d" % [cold_fur_used, warm_fur_used])
	_expect("cold environment increases fur demand", cold_fur_used > warm_fur_used)
	_expect("environment snapshot day published", int(cold.get_economy_report().environment_day) == 0)

func _test_price_quantity_response(compiled: Dictionary) -> void:
	var baseline := _configured_price_worker(compiled, 1801)
	var expensive := _configured_price_worker(compiled, 1802)
	var goods: PackedStringArray = compiled.good_ids
	var staple_ids := ["prepared_staples", "bread", "grain", "gathered_plants", "potatoes"]
	var protein_ids := ["game_meat", "meat", "fish", "canned_fish", "dairy_products"]
	var clothing_ids := ["cloth", "fur", "clothing", "footwear"]
	var basket := {}
	for good_id in staple_ids + protein_ids + clothing_ids:
		basket[good_id] = 2000000
	baseline.submit_economy_commands(_stock_commands(0, goods, basket, 0))
	_run_day(baseline, 0)
	var baseline_market: Dictionary = baseline.get_market_cell_snapshot(0)
	# Lock N=5 so this is one missed settlement period, then buy on the next
	# due bucket for cell 0 (day 5). Eight daily N=1 misses create catch-up
	# demand larger than the price effect.
	for day in range(5):
		_run_day(expensive, day)
	var expensive_before: Dictionary = expensive.get_market_cell_snapshot(0)
	expensive.submit_economy_commands(_stock_commands(0, goods, basket, 5))
	_run_day(expensive, 5)
	var expensive_market: Dictionary = expensive.get_market_cell_snapshot(0)
	var baseline_protein := _basket_consumed(baseline_market, protein_ids, 2000000)
	var expensive_protein := _basket_consumed(expensive_market, protein_ids, 2000000)
	var baseline_staple := _basket_consumed(baseline_market, staple_ids, 2000000)
	var expensive_staple := _basket_consumed(expensive_market, staple_ids, 2000000)
	var baseline_clothing := _basket_consumed(baseline_market, clothing_ids, 2000000)
	var expensive_clothing := _basket_consumed(expensive_market, clothing_ids, 2000000)
	_expect("shortage raises wild-game price before residents buy it",
		_good_value(expensive_before, "price", "game_meat") >
		_good_value(baseline_market, "price", "game_meat"))
	_expect("expensive protein basket sharply reduces purchased quantity",
		baseline_protein > 0 and expensive_protein * 2 < baseline_protein)
	_expect("staple and clothing remain necessities but still scale down with price",
		baseline_staple > 0 and baseline_clothing > 0 and
		expensive_staple > 0 and expensive_staple < baseline_staple and
		expensive_clothing > 0 and expensive_clothing < baseline_clothing)
	_expect("staples are less price elastic than protein",
		expensive_staple * baseline_protein > expensive_protein * baseline_staple)

func _test_price_v3_numeric_guards_and_horizons(compiled: Dictionary) -> void:
	var goods: PackedStringArray = compiled.good_ids
	var old_min_prices: PackedInt32Array = compiled.good_default_price
	for g in range(old_min_prices.size()): old_min_prices[g] = maxi(1, old_min_prices[g] / 10)
	var old_max_prices: PackedInt32Array = compiled.good_reference_max_price

	var shortage := _configured_price_worker(compiled, 1811)
	var shortage_report: Dictionary = {}
	for day in range(61):
		shortage_report = _run_price_day(shortage, day)
	var shortage_market: Dictionary = shortage.get_market_cell_snapshot(0)
	var game_meat := goods.find("game_meat")
	_expect("sustained shortage remains within the catalog maximum price",
		_good_value(shortage_market, "price", "game_meat") <=
		int(old_max_prices[game_meat]))
	var price_target := _good_value(
		shortage_market, "price_inventory_target", "game_meat")
	var daily_demand := _good_value(shortage_market, "demand_ema", "game_meat") + \
		_good_value(shortage_market, "business_demand_ema", "game_meat")
	var merchant_target := _good_value(
		shortage_market, "merchant_inventory_target", "game_meat")
	_expect("price inventory pressure uses only one settlement period",
		daily_demand > 0 and price_target == daily_demand * 5)
	_expect("merchant procurement retains its longer inventory horizon",
		merchant_target > price_target)

	var oversupply := _configured_price_worker(compiled, 1812)
	oversupply.submit_economy_commands(_stock_commands(
		0, goods, {"raw_hide": 100000000}, 0))
	var oversupply_report: Dictionary = {}
	var raw_hide := goods.find("raw_hide")
	var previous_price := _good_value(
		oversupply.get_market_cell_snapshot(0), "price", "raw_hide")
	var directional_fall_limited := true
	var max_fall_q16 := int(
		(compiled.good_max_price_fall_q16 as PackedInt32Array)[raw_hide]) * 5
	for day in range(360):
		oversupply_report = _run_price_day(oversupply, day)
		var cycle_price := _good_value(
			oversupply.get_market_cell_snapshot(0), "price", "raw_hide")
		var minimum_price := maxi(
			1, previous_price - int(previous_price * max_fall_q16 / 65536))
		directional_fall_limited = directional_fall_limited and \
			cycle_price >= maxi(1, minimum_price - 1)
		previous_price = cycle_price
	var oversupply_market: Dictionary = oversupply.get_market_cell_snapshot(0)
	_expect("persistent oversupply falls below the retired catalog floor",
		_good_value(oversupply_market, "price", "raw_hide") <
		int(old_min_prices[raw_hide]))
	_expect("oversupply markdown uses the current-price fall limit",
		directional_fall_limited)
	_expect("numeric price guards preserve positive prices and exact ledgers",
		_good_value(oversupply_market, "price", "raw_hide") >= 1 and
		String(oversupply.get_economy_report().get("price_runtime_bounds", "")) ==
			"numeric_min_dynamic_ceiling" and
		int(oversupply.get_economy_report().get("price_numeric_guard_min", 0)) == 1 and
		int(shortage_report.get("population_error", 1)) == 0 and
		int(shortage_report.get("money_error", 1)) == 0 and
		int(shortage_report.get("goods_error", 1)) == 0 and
		int(oversupply_report.get("population_error", 1)) == 0 and
		int(oversupply_report.get("money_error", 1)) == 0 and
		int(oversupply_report.get("goods_error", 1)) == 0)

func _test_price_rise_fade_and_soft_ceiling(compiled: Dictionary) -> void:
	var shortage := _configured_price_worker(compiled, 1811)
	for day in range(120):
		_run_price_day(shortage, day)
	var market: Dictionary = shortage.get_market_cell_snapshot(0)
	var price := _good_value(market, "price", "game_meat")
	_expect("shortage price is positive and bounded by the effective ceiling",
		price > 0 and price <= _good_value(market, "price_effective_ceiling", "game_meat"))
	_expect("obsolete quadratic rise fade is inactive",
		int(shortage.get_economy_report().get("price_rise_fade_hits", -1)) == 0)
	var hash_before: int = shortage.get_economy_state_hash()
	shortage.get_market_cell_snapshot(0)
	_expect("ceiling queries do not advance confirmation state",
		shortage.get_economy_state_hash() == hash_before)

func _run_price_day(ext: Object, day: int) -> Dictionary:
	var report: Dictionary = {}
	for slice in range(65536):
		report = ext.run_economy_slice({"day_index": day, "tick_index": slice})
		if bool(report.get("done", false)) or bool(report.get("fatal", false)):
			return report
	return report

func _test_demand_preview_query(compiled: Dictionary) -> void:
	var cold: Object = _configured_single_worker(compiled, 0.0, 1701)
	var warm: Object = _configured_single_worker(compiled, 1.0, 1701)
	var hash_before: int = cold.get_economy_state_hash()
	var cold_snapshot: Dictionary = cold.get_population_cell_snapshot(0)
	var hash_after: int = cold.get_economy_state_hash()
	var warm_snapshot: Dictionary = warm.get_population_cell_snapshot(0)
	var offsets: PackedInt32Array = cold_snapshot.get("demand_good_offsets", PackedInt32Array())
	var indices: PackedInt32Array = cold_snapshot.get("demand_good_indices", PackedInt32Array())
	var quantities: PackedInt64Array = cold_snapshot.get("demand_per_capita_daily", PackedInt64Array())
	var need_offsets: PackedInt32Array = cold_snapshot.get("demand_need_offsets", PackedInt32Array())
	var need_indices: PackedInt32Array = cold_snapshot.get("demand_need_indices", PackedInt32Array())
	var need_variant_offsets: PackedInt32Array = cold_snapshot.get(
		"demand_need_variant_offsets", PackedInt32Array())
	var variant_component_offsets: PackedInt32Array = cold_snapshot.get(
		"demand_variant_component_offsets", PackedInt32Array())
	var component_indices: PackedInt32Array = cold_snapshot.get(
		"demand_component_good_indices", PackedInt32Array())
	var component_quantities: PackedInt64Array = cold_snapshot.get(
		"demand_component_per_capita_daily", PackedInt64Array())
	_expect("demand preview CSR aligns with cohort handles", offsets.size() == int(cold_snapshot.cohort_count) + 1 and offsets[0] == 0 and offsets[-1] == indices.size())
	_expect("demand preview columns align", indices.size() == quantities.size() and not quantities.is_empty())
	_expect("grouped demand preview need CSR aligns", need_offsets.size() == int(cold_snapshot.cohort_count) + 1 and need_offsets[0] == 0 and need_offsets[-1] == need_indices.size() and need_variant_offsets.size() == need_indices.size() + 1)
	_expect("grouped demand preview variant CSR aligns", not variant_component_offsets.is_empty() and variant_component_offsets[-1] == component_indices.size() and component_indices.size() == component_quantities.size())
	_expect("demand preview uses current environment slots", bool(cold_snapshot.get("demand_preview_environment_ready", false)))
	_expect("demand preview is read-only", hash_before == hash_after)
	print("  fur preview cold=%d warm=%d" % [
		_preview_good_total(cold_snapshot, "fur"),
		_preview_good_total(warm_snapshot, "fur")])
	_expect("cold preview increases fur demand", _preview_good_total(cold_snapshot, "fur") > _preview_good_total(warm_snapshot, "fur"))

func _test_cycle_approximation(compiled: Dictionary) -> void:
	const DAYS := 10
	var reference := _configured_cycle_worker(compiled, 1, 301)
	var approximate := _configured_cycle_worker(compiled, DAYS, 301)
	var goods: PackedStringArray = compiled.good_ids
	var stock := {"grain": 10000000, "meat": 10000000,
		"cloth": 10000000, "fur": 10000000}
	reference.submit_economy_commands(_stock_commands(0, goods, stock, 0))
	approximate.submit_economy_commands(_stock_commands(0, goods, stock, 0))
	var hashes_match := true
	var approx_report: Dictionary = {}
	for day in range(DAYS):
		_run_day(reference, day)
		approx_report = _run_day(approximate, day)
		hashes_match = hashes_match and \
			reference.get_economy_state_hash() == approximate.get_economy_state_hash()
	_expect("profile max does not force a five-day lock on a one-cell world",
		int(reference.get_economy_report().get("market_cycle_days", 0)) == 1 and
		int(approximate.get_economy_report().get("market_cycle_days", 0)) == 1)
	_expect("same injected cadence keeps worker hashes identical", hashes_match)
	_expect("locked-cycle settlement conserves money and goods",
		int(approx_report.money_error) == 0 and int(approx_report.goods_error) == 0)

func _measure_cycle_error(compiled: Dictionary, days: int) -> Dictionary:
	var reference := _configured_cycle_worker(compiled, 1, 700 + days)
	var approximate := _configured_cycle_worker(compiled, days, 700 + days)
	var goods: PackedStringArray = compiled.good_ids
	var stock := {"grain": 100000000, "meat": 100000000,
		"cloth": 100000000, "fur": 100000000}
	reference.submit_economy_commands(_stock_commands(0, goods, stock, 0))
	approximate.submit_economy_commands(_stock_commands(0, goods, stock, 0))
	var reference_spend := 0
	for day in range(days):
		_run_day(reference, day)
		reference_spend += _sum_i64(reference.get_population_cell_snapshot(0).epoch_expense_by_cohort)
		approximate.run_economy_slice({"day_index": day, "tick_index": day})
	var ref_market: Dictionary = reference.get_market_cell_snapshot(0)
	var approx_market: Dictionary = approximate.get_market_cell_snapshot(0)
	var initial_total := 0
	for amount in stock.values():
		initial_total += int(amount)
	var ref_consumed := initial_total - _sum_i64(ref_market.stock)
	var approx_consumed := initial_total - _sum_i64(approx_market.stock)
	var approx_spend := _sum_i64(approximate.get_population_cell_snapshot(0).epoch_expense_by_cohort)
	return {"consumption_error_q16": _relative_error_q16(approx_consumed, ref_consumed),
		"spending_error_q16": _relative_error_q16(approx_spend, reference_spend)}

func _configured_cycle_worker(compiled: Dictionary, cycle_days: int, seed: int) -> Object:
	var ext: Object = _new_ext(1, 0.25)
	var catalog := compiled.duplicate(true)
	catalog.erase("ok")
	var profile := _native_profile(false, 1)
	profile.auto_slice_by_scale = false
	profile.cells_per_slice = 1
	profile.market_cycle_days = 5
	profile.market_min_cycle_days = 1
	profile.market_max_cycle_days = 5
	ext.configure_economy(catalog, profile, 1, seed)
	ext.inject_economy_cadence_timing(0.01, 0.01)
	var signature: int = (compiled.signature_keys as PackedStringArray).find("worker|default")
	ext.bootstrap_economy({"cell_indices": PackedInt32Array([0]),
		"signature_ids": PackedInt32Array([signature]), "population": PackedInt64Array([100]),
		"funds": PackedInt64Array([100000000])}, {})
	return ext

func _test_cycle_deadline_catchup(compiled: Dictionary) -> void:
	var ext: Object = _new_ext(10, 0.5)
	var catalog := compiled.duplicate(true)
	catalog.erase("ok")
	var profile := _native_profile(false, 1)
	profile.auto_slice_by_scale = false
	profile.cells_per_slice = 1
	profile.market_cycle_days = 5
	profile.market_max_cycle_days = 5
	ext.configure_economy(catalog, profile, 10, 901)
	ext.inject_economy_cadence_timing(1000000.0, 1000000.0)
	var signature: int = (compiled.signature_keys as PackedStringArray).find("worker|default")
	var cells := PackedInt32Array()
	var signatures := PackedInt32Array()
	var populations := PackedInt64Array()
	var funds := PackedInt64Array()
	for cell in range(10):
		cells.append(cell)
		signatures.append(signature)
		populations.append(10)
		funds.append(1000000)
	ext.bootstrap_economy({"cell_indices": cells, "signature_ids": signatures,
		"population": populations, "funds": funds}, {})
	var day0: Dictionary = ext.run_economy_slice({"day_index": 0, "tick_index": 0})
	_expect("day zero phase enters bounded catchup without a fatal barrier",
		not bool(day0.done) and bool(day0.commit_due) and not bool(day0.fatal) and
		int(day0.due_cells) == 2)
	for slice in range(1, 128):
		day0 = ext.run_economy_slice({"day_index": 0, "tick_index": slice})
		if bool(day0.done):
			break
	_expect("day zero phase completes through continuation",
		bool(day0.done) and not bool(day0.commit_due) and
		int(day0.due_cells) == 2 and int(day0.processed_due_cells) == 2 and
		int(day0.deferred_cells) == 0)
	var day1: Dictionary = ext.run_economy_slice({"day_index": 1, "tick_index": 1})
	for slice in range(2, 128):
		if bool(day1.done):
			break
		day1 = ext.run_economy_slice({"day_index": 1, "tick_index": slice})
	_expect("next daily phase also completes through continuation",
		bool(day1.done) and not bool(day1.commit_due) and
		int(day1.due_cells) == 2 and int(day1.processed_due_cells) == 2 and
		int(day1.deferred_cells) == 0 and int(day1.max_state_age_days) <= 4)

func _test_worker_scalar_equivalence(compiled: Dictionary) -> void:
	var scalar: Object = _configured_many_workers(compiled, false, 96)
	var worker: Object = _configured_many_workers(compiled, true, 96)
	var goods: PackedStringArray = compiled.good_ids
	var stock := {"grain": 1000000, "meat": 1000000, "cloth": 1000000, "fur": 1000000}
	for cell in range(96):
		scalar.submit_economy_commands(_stock_commands(cell, goods, stock, 0, cell * 10))
		worker.submit_economy_commands(_stock_commands(cell, goods, stock, 0, cell * 10))
	var scalar_report := _run_day(scalar, 0)
	var worker_report := _run_day(worker, 0)
	print("  worker_tasks=%d last_completed_max=%d market_max=%d fatal=%s reason=%s" % [
		int(worker_report.get("worker_tasks", -1)),
		int(worker_report.get("last_completed_market_worker_tasks_max", -1)),
		int(worker_report.get("market_worker_tasks_max", -1)),
		str(worker_report.get("fatal", false)),
		str(worker_report.get("fatal_reason", ""))])
	_expect("worker path dispatches multiple tasks",
		_worker_tasks_dispatched(worker_report))
	_expect("worker and scalar market v2 hashes match", scalar.get_economy_state_hash() == worker.get_economy_state_hash())
	_expect("worker and scalar economy event hashes match",
		int(scalar.get_economy_trace_report().get("stream_hash", 0)) ==
		int(worker.get_economy_trace_report().get("stream_hash", 1)))

func _configured_single_worker(compiled: Dictionary, temperature: float, seed: int) -> Object:
	var ext: Object = _new_ext(1, temperature)
	var catalog := compiled.duplicate(true)
	catalog.erase("ok")
	_expect("environment fixture country bootstraps",
		CountryTestHelper.configure_all_technologies(ext, catalog, 1, seed))
	_expect("environment fixture economy configures",
		bool(ext.configure_economy(catalog, _native_profile(true, 1), 1, seed).get("ok", false)))
	var signature: int = (compiled.signature_keys as PackedStringArray).find("worker|default")
	ext.bootstrap_economy({
		"cell_indices": PackedInt32Array([0]),
		"signature_ids": PackedInt32Array([signature]),
		"population": PackedInt64Array([100]),
		"funds": PackedInt64Array([10000000]),
	}, {})
	return ext

func _configured_price_worker(compiled: Dictionary, seed: int) -> Object:
	var ext: Object = _new_ext(1, 0.5)
	var catalog := compiled.duplicate(true)
	catalog.erase("ok")
	_expect("price-response country bootstraps",
		CountryTestHelper.configure_all_technologies(ext, catalog, 1, seed))
	var profile := _native_profile(false, 1)
	profile.starvation_death_rate_q32 = 0
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

func _configured_many_workers(compiled: Dictionary, workers: bool, cells: int) -> Object:
	var ext: Object = _new_ext(cells, 0.25)
	var catalog := compiled.duplicate(true)
	catalog.erase("ok")
	ext.configure_economy(catalog, _native_profile(workers, 1), cells, 91)
	ext.inject_economy_cadence_timing(0.01, 0.01)
	var signature: int = (compiled.signature_keys as PackedStringArray).find("worker|default")
	var cell_indices := PackedInt32Array()
	var signatures := PackedInt32Array()
	var populations := PackedInt64Array()
	var funds := PackedInt64Array()
	for cell in range(cells):
		cell_indices.append(cell)
		signatures.append(signature)
		populations.append(10)
		funds.append(1000000)
	ext.bootstrap_economy({"cell_indices": cell_indices, "signature_ids": signatures,
		"population": populations, "funds": funds}, {})
	return ext

func _new_ext(cells: int, temperature: float) -> Object:
	var ext: Object = ClassDB.instantiate("DCWorldExt")
	ext.create_entities(cells)
	var climate := PackedFloat32Array()
	climate.resize(cells)
	climate.fill(temperature)
	var zero_f := PackedFloat32Array()
	zero_f.resize(cells)
	zero_f.fill(0.0)
	for slot_name in [&"cell_temp", &"cell_temp_30d"]:
		var sid: int = ext.register_component(slot_name, 0, 1, false)
		ext.write_f32_range(sid, 0, climate)
	for slot_name in [&"cell_moisture", &"cell_plant_available_water", &"cell_weather_precip",
			&"cell_snow_cover", &"cell_weather_intensity", &"cell_elevation"]:
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
	return ext

func _worker_tasks_dispatched(report: Dictionary) -> bool:
	return int(report.get("worker_tasks", 1)) > 1 \
		or int(report.get("last_completed_market_worker_tasks_max", 1)) > 1 \
		or int(report.get("market_worker_tasks_max", 1)) > 1

func _native_profile(workers: bool, threshold: int) -> Dictionary:
	var profile = load("res://data/economy/default_economy.tres")
	var out: Dictionary = profile.to_native_profile()
	out.worker_enabled = workers
	out.worker_market_threshold = threshold
	out.worker_tasks_hint = 4 if workers else 0
	out.market_runtime_mode = "ACTIVE"
	out.market_cycle_days = 5
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

func _single_command(opcode: int, day: int, target_handle: int, i32_0: int,
		i32_1: int, i64_0: int, i64_1: int) -> Dictionary:
	return {
		"opcodes": PackedInt32Array([opcode]),
		"effective_days": PackedInt64Array([day]),
		"sequences": PackedInt64Array([1]),
		"target_handles": PackedInt64Array([target_handle]),
		"i32_0": PackedInt32Array([i32_0]),
		"i32_1": PackedInt32Array([i32_1]),
		"i64_0": PackedInt64Array([i64_0]),
		"i64_1": PackedInt64Array([i64_1]),
	}

func _run_day(ext: Object, day: int) -> Dictionary:
	var report: Dictionary = {}
	var simulation_day := day * 5
	for slice in range(128):
		report = ext.run_economy_slice({"day_index": simulation_day, "tick_index": slice})
		if bool(report.get("done", false)):
			return report
	return report

func _good_value(snapshot: Dictionary, column: String, good_id: String) -> int:
	var ids: PackedStringArray = snapshot.good_ids
	var idx: int = ids.find(good_id)
	var values = snapshot.get(column, [])
	return int(values[idx]) if idx >= 0 else -1

func _preview_good_total(snapshot: Dictionary, good_id: String) -> int:
	var good_ids: PackedStringArray = snapshot.get("demand_good_stable_ids", PackedStringArray())
	var target := good_ids.find(good_id)
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

func _basket_consumed(snapshot: Dictionary, good_ids: Array, added_per_good: int) -> int:
	var total := 0
	for good_id in good_ids:
		total += maxi(0, added_per_good - _good_value(snapshot, "stock", String(good_id)))
	return total

func _merchant_funds(snapshot: Dictionary) -> int:
	var flags: PackedByteArray = snapshot.merchant_flags
	var funds: PackedInt64Array = snapshot.funds_by_cohort
	var total := 0
	for i in range(flags.size()):
		if flags[i] != 0:
			total += funds[i]
	return total

func _sum_i64(values: PackedInt64Array) -> int:
	var total := 0
	for value in values:
		total += value
	return total

func _sum_u8(values: PackedByteArray) -> int:
	var total := 0
	for value in values:
		total += value
	return total

func _relative_error_q16(value: int, reference: int) -> int:
	return int(abs(value - reference) * 65536 / maxi(1, abs(reference)))

func _expect(label: String, condition: bool) -> void:
	_checks += 1
	if condition:
		print("  [PASS] ", label)
	else:
		_failures += 1
		printerr("  [FAIL] ", label)

func _finish() -> void:
	print("  -> checks=%d failures=%d" % [_checks, _failures])
	print("=== native market v2 runtime %s ===" % ("PASS" if _failures == 0 else "FAIL"))
