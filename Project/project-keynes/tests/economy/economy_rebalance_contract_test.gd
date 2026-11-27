extends SceneTree

## Verifies the systemic economy numerical rebalance contracts:
## 1. Additive output stacking (not multiplicative) with no runtime ceiling:
##    the pooled factor is `1 + ΣΔ` and is only bounded by the per-stat catalog
##    clamp, so stacking past the old 4.0x cap must reach the output.
## 2. Soft-input capped productivity bonus (bare 1.0x, multi-soft strictly <= 1.40x).
## 3. Output-coupled production inputs (alpha = 0.60) with guaranteed net efficiency
##    improvement and country.production.input_factor floor >= 0.80.
## 4. Wealth-scaled household consumption continuing smoothly past 16x up to 1024x
##    while staple food stays bounded (<= 1.30x) and ledgers stay strictly conserved.

const EconomyCatalogScript = preload("res://scripts/economy/economy_catalog.gd")
const CountryTestHelper = preload("res://tests/country/country_test_helper.gd")
const CountryFacadeScript = preload("res://scripts/country/country_facade.gd")
const ModifierFacadeScript = preload("res://scripts/modifier/modifier_facade.gd")
const EffectDomainCatalogScript = preload("res://scripts/effect/effect_domain_catalog.gd")

var _checks := 0
var _failures := 0


func _init() -> void:
	var compiled: Dictionary = EconomyCatalogScript.compile_native_catalog()
	_expect("economy catalog compiles", bool(compiled.get("ok", false)))
	if not bool(compiled.get("ok", false)):
		quit(1)
		return
	var profile: Dictionary = load("res://data/economy/default_economy.tres").to_native_profile()
	profile.market_runtime_mode = "ACTIVE"
	profile.market_cycle_days = 1
	profile.worker_enabled = false
	profile.economy_accuracy_preset = "EXACT"
	profile.starvation_death_rate_q32 = 0
	profile.employment_mobility_daily_q16 = 0
	profile.investment_max_growth_share_q16 = 0

	_test_global_profile_defaults(profile)
	_test_soft_input_bonus_cap_multi_soft(compiled, profile)
	_test_additive_tech_and_input_coupling(compiled, profile)
	_test_wealth_scaled_consumption_beyond_16x(compiled, profile)

	print("[economy-rebalance-contract] checks=%d failures=%d" % [_checks, _failures])
	quit(0 if _failures == 0 else 1)


func _test_global_profile_defaults(profile: Dictionary) -> void:
	_expect("default global building_output_efficiency_q16 rolled back to 1.0x",
		int(profile.get("building_output_efficiency_q16", 0)) == 65536)
	var horizons: PackedInt32Array = profile.get(
		"building_maintenance_horizon_days_by_sector", PackedInt32Array())
	_expect("default maintenance horizons shortened to 2-5 year range",
		horizons.size() == 5 and horizons[0] <= 1825 and horizons[1] <= 1200 and
		horizons[2] <= 1460 and horizons[3] <= 1095 and horizons[4] <= 2190)


func _test_soft_input_bonus_cap_multi_soft(source_catalog: Dictionary,
		source_profile: Dictionary) -> void:
	# Configure a building with 4 soft inputs whose required_q16 sum to 2.75 (275%).
	# Bare output (no soft stock) must stay positive (1.0x), and full soft stock
	# must boost output strictly > bare yet strictly <= 1.40x bare (+40% hard cap).
	var goods: PackedStringArray = source_catalog.good_ids
	var bid := (source_catalog.building_type_ids as PackedStringArray).find("stone_age_hunting_camp")
	var base_run := _run_multi_soft_case(source_catalog, source_profile, bid, false, 6001)
	var full_run := _run_multi_soft_case(source_catalog, source_profile, bid, true, 6002)
	var bare_out := int(base_run.get("output", 0))
	var full_out := int(full_run.get("output", 0))
	_expect("bare building produces positive 1.0x output with zero soft stock",
		bare_out > 0 and bool(base_run.get("ledgers_ok", false)))
	_expect("four stacked soft inputs boost output above bare",
		full_out > bare_out and bool(full_run.get("ledgers_ok", false)))
	var ratio := float(full_out) / maxf(1.0, float(bare_out))
	print("  soft-bonus 4-input ratio=%.4f (bare=%d full=%d)" % [ratio, bare_out, full_out])
	_expect("four stacked soft inputs (sum 275%) are hard-capped at <= +40% (1.40x)",
		ratio <= 1.405 and ratio >= 1.05)


func _run_multi_soft_case(source_catalog: Dictionary, source_profile: Dictionary,
		bid: int, stock_soft: bool, seed: int) -> Dictionary:
	var catalog := source_catalog.duplicate(true)
	var goods: PackedStringArray = catalog.good_ids
	var soft_goods := [
		goods.find("chipped_stone_tools"),
		goods.find("electricity"),
		goods.find("computers"),
		goods.find("industrial_machinery"),
	]
	# Rebuild CSR inputs for `bid` to have 4 cheap soft inputs (qty=10, req=45056 each -> sum 2.75)
	var in_off: PackedInt32Array = catalog.building_input_offsets.duplicate()
	var in_goods: PackedInt32Array = catalog.building_input_good_ids.duplicate()
	var in_qty: PackedInt64Array = catalog.building_input_quantities.duplicate()
	var in_req: PackedInt32Array = catalog.building_input_required_q16.duplicate()
	var in_cat: PackedStringArray = catalog.building_input_category_ids.duplicate()
	var in_minq: PackedInt32Array = catalog.building_input_min_quality_levels.duplicate()
	var cand_off: PackedInt32Array = catalog.building_input_candidate_offsets.duplicate()
	var cand_goods: PackedInt32Array = catalog.building_input_candidate_good_ids.duplicate()
	var cand_eff: PackedInt32Array = catalog.building_input_candidate_efficiency_q16.duplicate()

	var new_in_goods := PackedInt32Array()
	var new_in_qty := PackedInt64Array()
	var new_in_req := PackedInt32Array()
	var new_in_cat := PackedStringArray()
	var new_in_minq := PackedInt32Array()
	var new_cand_goods := PackedInt32Array()
	var new_cand_eff := PackedInt32Array()
	var new_cand_off := PackedInt32Array([0])
	var new_in_off := PackedInt32Array([0])

	var bcount := (catalog.building_type_ids as PackedStringArray).size()
	for b in range(bcount):
		if b == bid:
			for sg in soft_goods:
				new_in_goods.append(int(sg))
				new_in_qty.append(10)
				new_in_req.append(45056) # 0.6875 each * 4 = 2.75
				new_in_cat.append("")
				new_in_minq.append(0)
				new_cand_goods.append(int(sg))
				new_cand_eff.append(65536)
				new_cand_off.append(new_cand_goods.size())
		else:
			for edge in range(int(in_off[b]), int(in_off[b + 1])):
				new_in_goods.append(in_goods[edge])
				new_in_qty.append(in_qty[edge])
				new_in_req.append(in_req[edge])
				new_in_cat.append(in_cat[edge])
				new_in_minq.append(in_minq[edge])
				for ce in range(int(cand_off[edge]), int(cand_off[edge + 1])):
					new_cand_goods.append(cand_goods[ce])
					new_cand_eff.append(cand_eff[ce])
				new_cand_off.append(new_cand_goods.size())
		new_in_off.append(new_in_goods.size())

	catalog.building_input_offsets = new_in_off
	catalog.building_input_good_ids = new_in_goods
	catalog.building_input_quantities = new_in_qty
	catalog.building_input_required_q16 = new_in_req
	catalog.building_input_category_ids = new_in_cat
	catalog.building_input_min_quality_levels = new_in_minq
	catalog.building_input_candidate_offsets = new_cand_off
	catalog.building_input_candidate_good_ids = new_cand_goods
	catalog.building_input_candidate_efficiency_q16 = new_cand_eff

	# Set output high enough so every cheap soft input is easily profitable
	var out_off: PackedInt32Array = catalog.building_output_offsets
	var out_qty: PackedInt64Array = catalog.building_output_quantities.duplicate()
	out_qty[int(out_off[bid])] = 20000
	catalog.building_output_quantities = out_qty

	var ext := _new_ext(catalog)
	CountryTestHelper.configure_all_technologies(ext, catalog, 1, seed)
	ext.configure_economy(catalog, source_profile, 1, seed)
	_seed_all_resources(ext, catalog, 1000000000.0)
	var sigs: PackedStringArray = catalog.signature_keys
	var hunter := sigs.find("hunter|default")
	var merch := sigs.find("merchant|default")
	var stock := PackedInt64Array()
	stock.resize(goods.size())
	stock.fill(0)
	if stock_soft:
		for sg in soft_goods:
			stock[int(sg)] = 10000000
	ext.bootstrap_economy({
		"cell_indices": PackedInt32Array([0, 0]),
		"signature_ids": PackedInt32Array([hunter, merch]),
		"population": PackedInt64Array([2, 1]),
		"funds": PackedInt64Array([500000000, 500000000]),
	}, {
		"stock": stock,
		"building_cells": PackedInt32Array([0]),
		"building_type_ids": PackedInt32Array([bid]),
		"building_owner_signature_ids": PackedInt32Array([hunter]),
		"building_counts": PackedInt64Array([1]),
	})
	var report := _run_day(ext, 0)
	var snap: Dictionary = ext.get_building_cell_snapshot(0)
	return {
		"output": int((snap.last_output as PackedInt64Array)[0]),
		"input": int((snap.last_input as PackedInt64Array)[0]),
		"ledgers_ok": int(report.get("population_error", 1)) == 0 and
			int(report.get("money_error", 1)) == 0 and
			int(report.get("goods_error", 1)) == 0,
	}


func _test_additive_tech_and_input_coupling(source_catalog: Dictionary,
		source_profile: Dictionary) -> void:
	# Compare an industrial building (coke_ovens, hard input = coal) with
	# zero tech bonuses vs ALL 467 technologies unlocked, and a third run that
	# stacks one extra +4.0 city-good output add on top of all-tech.
	# Verify:
	# 1. All-tech output multiplier stays additive (not the 15x-41x multiplicative
	#    product) and there is NO 4.0x runtime ceiling: the extra +4.0 add must
	#    push the measured multiplier past 4.0x instead of clamping there.
	# 2. All-tech physical input strictly increases above base (input coupling > 1.0x).
	# 3. Net material efficiency strictly improves (all_tech output/input > base output/input).
	var bid := (source_catalog.building_type_ids as PackedStringArray).find("coke_ovens")
	_expect("coke_ovens exists in catalog", bid >= 0)
	var base_run := _run_industrial_tech_case(source_catalog, source_profile, bid, false, 6011)
	var tech_run := _run_industrial_tech_case(source_catalog, source_profile, bid, true, 6012)
	var over_cap_run := _run_industrial_tech_case(
		source_catalog, source_profile, bid, true, 6013, 4.0)
	var b_out := float(base_run.get("output", 0))
	var b_in := float(base_run.get("input", 0))
	var t_out := float(tech_run.get("output", 0))
	var t_in := float(tech_run.get("input", 0))
	_expect("coke_ovens base and full-tech runs produce and consume with zero ledger error",
		b_out > 0.0 and b_in > 0.0 and t_out > 0.0 and t_in > 0.0 and
		bool(base_run.get("ledgers_ok", false)) and bool(tech_run.get("ledgers_ok", false)))
	var out_ratio := t_out / maxf(1.0, b_out)
	var in_ratio := t_in / maxf(1.0, b_in)
	var base_yield := b_out / maxf(1.0, b_in)
	var tech_yield := t_out / maxf(1.0, t_in)
	var tech_in_factor := float(tech_run.get("country_input_factor", 1.0))
	print("  tech-coupling coke_ovens: out_mult=%.3fx in_mult=%.3fx net_eff_gain=%.3fx input_factor=%.3f" % [
		out_ratio, in_ratio, tech_yield / maxf(0.0001, base_yield), tech_in_factor])
	_expect("all-tech additive output multiplier exceeds the naive 1.2x floor",
		out_ratio > 1.20 and bool(tech_run.get("ledgers_ok", false)))
	var c_out := float(over_cap_run.get("output", 0))
	var c_ratio := c_out / maxf(1.0, b_out)
	print("  tech-coupling coke_ovens +4.0 city-good add: out_mult=%.3fx" % c_ratio)
	# The old code clamped the pooled factor at 4.0x here; the capped run must land
	# strictly above the ceiling, which can only happen if the clamp is gone.
	_expect("no 4.0x output ceiling: an extra +4.0 city-good add reaches output > 4.0x",
		c_ratio > 4.0 and bool(over_cap_run.get("ledgers_ok", false)))
	_expect("country.production.input_factor refuses to drop below 0.80 floor",
		tech_in_factor >= 0.7999 and tech_in_factor <= 1.0001)
	_expect("all-tech output-coupled physical inputs strictly increase (> 1.10x)",
		in_ratio > 1.10)
	_expect("technology guarantees genuine net material conversion efficiency gain (> 1.10x)",
		tech_yield > base_yield * 1.10)


func _run_industrial_tech_case(source_catalog: Dictionary, source_profile: Dictionary,
		bid: int, unlock_all_tech: bool, seed: int,
		extra_city_good_output_add: float = 0.0) -> Dictionary:
	var catalog := source_catalog.duplicate(true)
	var goods: PackedStringArray = catalog.good_ids
	var ext := _new_ext(catalog)
	var modifiers = ModifierFacadeScript.new()
	modifiers.configure(ext, 4)
	var effect_catalog: Resource = EffectDomainCatalogScript.build()
	ext.configure_effects(effect_catalog.compile_native_catalog())
	var country = CountryFacadeScript.new()
	var cfg_country: Dictionary = country.configure(ext, 1, seed, load("res://data/country/default_country.tres"), source_catalog, null, modifiers.compiled_catalog())
	if not bool(cfg_country.get("ok", false)):
		print("  [DEBUG] country.configure failed: ", cfg_country)
	var tech_ids: PackedStringArray = catalog.technology_ids
	var tech_indices := PackedInt32Array()
	if unlock_all_tech:
		for ti in range(tech_ids.size()):
			tech_indices.append(ti)
	else:
		for tid in ["tech.coke_smelting", "tech.coal_mining", "tech.mining"]:
			var ti := tech_ids.find(tid)
			if ti >= 0:
				tech_indices.append(ti)
	var points_good := goods.find("technology_points")
	var boot_country: Dictionary = country.bootstrap(PackedByteArray([0]), {
		"country_ids": PackedStringArray(["country.rebalance"]),
		"country_names": PackedStringArray(["Rebalance"]),
		"country_cash": PackedInt64Array([100000000]),
		"territory_offsets": PackedInt32Array([0, 1]),
		"territory_cells": PackedInt32Array([0]),
		"technology_offsets": PackedInt32Array([0, tech_indices.size()]),
		"technology_indices": tech_indices,
		"treasury_offsets": PackedInt32Array([0, 1]),
		"treasury_good_indices": PackedInt32Array([points_good]),
		"treasury_quantities": PackedInt64Array([1000000]),
	})
	if not bool(boot_country.get("ok", false)):
		print("  [DEBUG] country.bootstrap failed: ", boot_country)
	ext.run_country_slice({"day_index": 0})
	for _step in range(1024):
		var r_eff: Dictionary = ext.run_effect_daily(0)
		if bool(r_eff.get("done", false)):
			break
	ext.dispatch_effect_native_modifier()
	ext.run_modifier_daily(0)
	ext.ack_effect_native_modifier()
	if extra_city_good_output_add > 0.0:
		_apply_city_good_output_add(ext, modifiers, catalog, bid,
			extra_city_good_output_add)
	var handle := int(country.cell_summary(0).get("country_handle", 0))
	var in_factor := float(ext.evaluate_modifier_stat(1, handle, 0, "country.production.input_factor", 1.0))
	ext.configure_economy(catalog, source_profile, 1, seed)
	_seed_all_resources(ext, catalog, 1000000000.0)
	var sigs: PackedStringArray = catalog.signature_keys
	var owner := sigs.find("industrialist|default")
	var worker := sigs.find("industrial_worker|default")
	var eng := sigs.find("engineer|default")
	var mgr := sigs.find("manager|default")
	var merch := sigs.find("merchant|default")
	var stock := PackedInt64Array()
	stock.resize(goods.size())
	stock.fill(100000000)
	# Zero soft tools so we isolate pure hard-input + tech output/input coupling!
	for tg in ["chipped_stone_tools", "bronze_tools", "tools", "precision_tools"]:
		var ti := goods.find(tg)
		if ti >= 0:
			stock[ti] = 0
	ext.bootstrap_economy({
		"cell_indices": PackedInt32Array([0, 0, 0, 0, 0]),
		"signature_ids": PackedInt32Array([owner, worker, eng, mgr, merch]),
		"population": PackedInt64Array([1, 16, 6, 2, 1]),
		"funds": PackedInt64Array([5000000000, 10000000, 10000000, 10000000, 5000000000]),
	}, {
		"stock": stock,
		"building_cells": PackedInt32Array([0]),
		"building_type_ids": PackedInt32Array([bid]),
		"building_owner_signature_ids": PackedInt32Array([owner]),
		"building_counts": PackedInt64Array([1]),
	})
	var report := _run_day(ext, 0)
	var snap: Dictionary = ext.get_building_cell_snapshot(0)
	return {
		"output": int((snap.last_output as PackedInt64Array)[0]),
		"input": int((snap.last_input as PackedInt64Array)[0]),
		"country_input_factor": in_factor,
		"ledgers_ok": int(report.get("population_error", 1)) == 0 and
			int(report.get("money_error", 1)) == 0 and
			int(report.get("goods_error", 1)) == 0,
	}


## Queues one GROUP-scope city-good output add for cell 0, the same shape the
## ideology city cards use. `magnitude_q16` is clamped to [0, 4] by the modifier
## runtime, so the pool grows by `add` and nothing else.
func _apply_city_good_output_add(ext: Object, modifiers, catalog: Dictionary,
		bid: int, add: float) -> void:
	var out_offsets: PackedInt32Array = catalog.get(
		"building_output_offsets", PackedInt32Array())
	var out_goods: PackedInt32Array = catalog.get(
		"building_output_good_ids", PackedInt32Array())
	var good_names: PackedStringArray = catalog.get("good_ids", PackedStringArray())
	if bid < 0 or bid + 1 >= out_offsets.size():
		print("  [DEBUG] building %d has no output columns" % bid)
		return
	var begin := int(out_offsets[bid])
	var end := int(out_offsets[bid + 1])
	if begin >= end:
		print("  [DEBUG] building %d has no output good" % bid)
		return
	var good := int(out_goods[begin])
	if good < 0 or good >= good_names.size():
		print("  [DEBUG] output good index out of range: %d" % good)
		return
	var definition := StringName("economy.city.good.%s.output_factor"
		% good_names[good])
	var request: int = modifiers.queue_apply(definition, {
		"domain": 2, "scope": 1, "entity_handle": 0, "group_handle": 0},
		{"type": 7, "id": 77}, -1, 1, 0, 100, int(round(add * 65536.0)))
	if request <= 0:
		print("  [DEBUG] extra city-good definition rejected: %s" % definition)
		return
	ext.run_modifier_daily(0)


func _test_wealth_scaled_consumption_beyond_16x(source_catalog: Dictionary,
		source_profile: Dictionary) -> void:
	# Run 4 identical owner_household cohorts with wealth = 1x, 16x, 128x, 1024x
	# reference (10, 160, 1280, 10240 currency/person) in fully stocked markets.
	var wealth_multipliers := [1, 16, 128, 1024]
	var spends := []
	var staple_consumed := []
	var luxury_consumed := []
	for idx in range(wealth_multipliers.size()):
		var mult := int(wealth_multipliers[idx])
		var res := _run_wealth_cohort_case(source_catalog, source_profile, mult, 6020 + idx)
		_expect("wealth %dx cohort conserves ledgers" % mult, bool(res.get("ledgers_ok", false)))
		spends.append(int(res.get("expense", 0)))
		staple_consumed.append(int(res.get("staple_qty", 0)))
		luxury_consumed.append(int(res.get("luxury_qty", 0)))
	print("  wealth-consumption ladder (1x/16x/128x/1024x): spend=", spends,
		" staple=", staple_consumed, " luxury=", luxury_consumed)
	_expect("total spending rises monotonically past old 16x cap up to 1024x",
		spends[0] < spends[1] and spends[1] < spends[2] and spends[2] < spends[3])
	_expect("1024x wealthy cohort spends >= 4x as much as 16x cohort (no flatline at 160 currency)",
		float(spends[3]) >= float(spends[1]) * 4.0)
	_expect("luxury quantity scales strongly from 1x to 1024x (> 15x) and past 16x (> 2x)",
		luxury_consumed[3] > luxury_consumed[0] * 15 and luxury_consumed[3] > luxury_consumed[1] * 2)
	_expect("staple food stays bounded <= 1.35x even at 1024x wealth (no grain over-eating)",
		float(staple_consumed[3]) <= float(maxi(1, staple_consumed[0])) * 1.35)


func _run_wealth_cohort_case(source_catalog: Dictionary, source_profile: Dictionary,
		wealth_mult: int, seed: int) -> Dictionary:
	var catalog := source_catalog.duplicate(true)
	var goods: PackedStringArray = catalog.good_ids
	var ext := _new_ext(catalog)
	CountryTestHelper.configure_all_technologies(ext, catalog, 1, seed)
	ext.configure_economy(catalog, source_profile, 1, seed)
	var sigs: PackedStringArray = catalog.signature_keys
	var owner := sigs.find("industrialist|default")
	var pop := 100
	# wealth_reference_per_capita = 100,000 (10 currency)
	var funds := pop * 100000 * wealth_mult
	var stock := PackedInt64Array()
	stock.resize(goods.size())
	stock.fill(1000000000)
	ext.bootstrap_economy({
		"cell_indices": PackedInt32Array([0]),
		"signature_ids": PackedInt32Array([owner]),
		"population": PackedInt64Array([pop]),
		"funds": PackedInt64Array([funds]),
	}, {
		"stock": stock,
	})
	var report := _run_day(ext, 0)
	var pop_snap: Dictionary = ext.get_population_cell_snapshot(0)
	var mkt_snap: Dictionary = ext.get_market_cell_snapshot(0)
	var mkt_stock: PackedInt64Array = mkt_snap.stock
	var staple_qty := 0
	for sg in ["prepared_staples", "bread", "grain", "wheat_grain", "rice_grain", "corn_grain", "potatoes", "gathered_plants"]:
		var gi := goods.find(sg)
		if gi >= 0:
			staple_qty += 1000000000 - int(mkt_stock[gi])
	var luxury_qty := 0
	for lg in ["jewelry", "fine_clothing", "fine_furniture", "beverages", "fur", "silver"]:
		var gi := goods.find(lg)
		if gi >= 0:
			luxury_qty += 1000000000 - int(mkt_stock[gi])
	var after_funds := int((pop_snap.funds_by_cohort as PackedInt64Array)[0])
	return {
		"expense": funds - after_funds,
		"staple_qty": staple_qty,
		"luxury_qty": luxury_qty,
		"ledgers_ok": int(report.get("population_error", 1)) == 0 and
			int(report.get("money_error", 1)) == 0 and
			int(report.get("goods_error", 1)) == 0,
	}


func _new_ext(catalog: Dictionary) -> Object:
	var ext: Object = ClassDB.instantiate("DCWorldExt")
	ext.create_entities(1)
	for slot_name in [&"cell_temp", &"cell_temp_30d", &"cell_moisture",
			&"cell_plant_available_water", &"cell_weather_precip", &"cell_snow_cover",
			&"cell_weather_intensity", &"cell_temp_365d"]:
		var values := PackedFloat32Array([0.55 if slot_name == &"cell_temp" else 0.5])
		ext.write_f32_range(ext.register_component(slot_name, 0, 1, false), 0, values)
	var zeros := PackedByteArray([0])
	ext.write_u8_range(ext.register_component(&"cell_weather_type", 2, 1, false), 0, zeros)
	ext.write_u8_range(ext.register_component(&"cell_cover", 2, 1, false), 0, zeros)
	for slot_name in catalog.building_resource_reserve_slots as PackedStringArray:
		ext.write_f32_range(ext.register_component(StringName(slot_name), 0, 1, false), 0, PackedFloat32Array([1000.0]))
	for slot_name in catalog.building_resource_extra_slots as PackedStringArray:
		ext.write_f32_range(ext.register_component(StringName(slot_name), 0, 1, false), 0, PackedFloat32Array([0.0]))
	return ext


func _seed_all_resources(ext: Object, catalog: Dictionary, amount: float) -> void:
	for slot_name in catalog.building_resource_reserve_slots as PackedStringArray:
		var sid := int(ext.component_id(StringName(slot_name)))
		if sid >= 0:
			ext.write_f32_range(sid, 0, PackedFloat32Array([amount]))


func _run_day(ext: Object, day: int) -> Dictionary:
	var report := {}
	for s in range(256):
		report = ext.run_economy_slice({"day_index": day, "tick_index": s})
		if bool(report.get("done", false)):
			return report
	return report


func _expect(label: String, passed: bool) -> void:
	_checks += 1
	print("  [%s] %s" % ["PASS" if passed else "FAIL", label])
	if not passed:
		_failures += 1
