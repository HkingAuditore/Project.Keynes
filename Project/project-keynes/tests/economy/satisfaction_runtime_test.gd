extends SceneTree

## Composite satisfaction runtime coverage: the eight dimensions, the
## subsistence gate, class (profession) weight differentiation, the explain and
## attractiveness read APIs, and PKEC v56 round-trip plus state hash.

const EconomyCatalogScript = preload("res://scripts/economy/economy_catalog.gd")
const CountryTestHelper = preload("res://tests/country/country_test_helper.gd")

const SAT_DIM_SUBSISTENCE := 0
const SAT_DIM_BASIC := 1
const SAT_DIM_COMFORT := 2
const SAT_DIM_LUXURY := 3
const SAT_DIM_INCOME := 4
const SAT_DIM_SAVINGS := 5
const SAT_DIM_TAX := 6
const SAT_DIM_DEVELOPMENT := 7
const SAT_DIM_COUNT := 8
const Q16_ONE := 65536

var _checks := 0
var _failures := 0


func _init() -> void:
	_run()
	print("=== satisfaction runtime %s: checks=%d failures=%d ===" % [
		"PASS" if _failures == 0 else "FAIL", _checks, _failures])
	quit(0 if _failures == 0 else 1)


func _run() -> void:
	var compiled: Dictionary = EconomyCatalogScript.compile_native_catalog()
	_expect("satisfaction catalog compiles", bool(compiled.get("ok", false)))
	if not bool(compiled.get("ok", false)) or not ClassDB.class_exists("DCWorldExt"):
		return
	_test_catalog_columns(compiled)
	_test_dimensions_and_gate(compiled)
	_test_class_weight_differentiation(compiled)
	_test_realized_consumption(compiled)
	_test_explain_and_attractiveness(compiled)
	_test_save_round_trip(compiled)


func _test_catalog_columns(compiled: Dictionary) -> void:
	var need_ids: PackedStringArray = compiled.get("need_ids", PackedStringArray())
	var tiers: PackedInt32Array = compiled.get("need_satisfaction_tiers", PackedInt32Array())
	var need_weights: PackedInt32Array = compiled.get(
		"need_satisfaction_weights_q16", PackedInt32Array())
	_expect("every need carries a satisfaction tier and weight",
		tiers.size() == need_ids.size() and need_weights.size() == need_ids.size())
	var tier_in_range := true
	for tier in tiers:
		if int(tier) < 0 or int(tier) >= 4:
			tier_in_range = false
	_expect("need tiers stay inside the four need dimensions", tier_in_range)
	var signature_keys: PackedStringArray = compiled.get(
		"signature_keys", PackedStringArray())
	var dimension_weights: PackedInt32Array = compiled.get(
		"signature_satisfaction_dimension_weights_q16", PackedInt32Array())
	_expect("signature dimension weights are dense and eight wide",
		int(compiled.get("satisfaction_dimension_count", 0)) == SAT_DIM_COUNT and
		dimension_weights.size() == signature_keys.size() * SAT_DIM_COUNT)
	var farmer := signature_keys.find("subsistence_farmer|default")
	var merchant := signature_keys.find("merchant|default")
	if farmer < 0 or merchant < 0:
		_expect("authored professions are present in the signature table", false)
		return
	var farmer_luxury := int(dimension_weights[farmer * SAT_DIM_COUNT + SAT_DIM_LUXURY])
	var merchant_income := int(dimension_weights[merchant * SAT_DIM_COUNT + SAT_DIM_INCOME])
	var farmer_income := int(dimension_weights[farmer * SAT_DIM_COUNT + SAT_DIM_INCOME])
	_expect("authored class weights differ by profession",
		farmer_luxury == 0 and merchant_income > farmer_income)


func _test_dimensions_and_gate(compiled: Dictionary) -> void:
	# A fed, salaried, saving cohort in a stocked market scores broadly; the
	# same cohort with an empty market must collapse to the subsistence gate.
	var fed := _configured_world(compiled, 4001, true)
	var starving := _configured_world(compiled, 4001, false)
	if fed == null or starving == null:
		return
	for cycle in range(6):
		_run_cycle(fed, cycle)
		_run_cycle(starving, cycle)
	var fed_snapshot: Dictionary = fed.get_population_cell_snapshot(0)
	var starving_snapshot: Dictionary = starving.get_population_cell_snapshot(0)
	_expect("composite columns are published without a trace filter",
		int(fed_snapshot.get("satisfaction_dimension_count", 0)) == SAT_DIM_COUNT and
		(fed_snapshot.get("overall_satisfaction_by_cohort_q16",
			PackedInt32Array()) as PackedInt32Array).size() ==
			int(fed_snapshot.get("cohort_count", -1)))
	var fed_dims := _dims_for_cohort(fed_snapshot, 0)
	var starving_dims := _dims_for_cohort(starving_snapshot, 0)
	_expect("a stocked market feeds the subsistence dimension",
		fed_dims.size() == SAT_DIM_COUNT and
		int(fed_dims[SAT_DIM_SUBSISTENCE]) > Q16_ONE / 2)
	_expect("an empty market starves the subsistence dimension",
		starving_dims.size() == SAT_DIM_COUNT and
		int(starving_dims[SAT_DIM_SUBSISTENCE]) < Q16_ONE / 4)
	var starving_composite := _composite_for_cohort(starving_snapshot, 0)
	var subsistence := int(starving_dims[SAT_DIM_SUBSISTENCE])
	var slack := 6554
	var ceiling := subsistence + (Q16_ONE - 1 - subsistence) * slack / Q16_ONE
	_expect("the subsistence gate caps a starving cohort regardless of savings",
		starving_composite <= ceiling)
	var starving_professions: PackedStringArray = starving_snapshot.get(
		"profession_stable_ids", PackedStringArray())
	var starving_profession_indices: PackedInt32Array = starving_snapshot.get(
		"profession_ids", PackedInt32Array())
	var starving_worsts: PackedInt32Array = starving_snapshot.get(
		"worst_satisfaction_dimension_by_cohort", PackedInt32Array())
	var unemployed_worst := -1
	var unemployed_row := -1
	for row in range(starving_profession_indices.size()):
		var profession_index := int(starving_profession_indices[row])
		if profession_index < 0 or profession_index >= starving_professions.size():
			continue
		if String(starving_professions[profession_index]) != "unemployed":
			continue
		unemployed_row = row
		unemployed_worst = int(starving_worsts[row]) if row < starving_worsts.size() else -1
		break
	_expect("the worst dimension points at the binding constraint",
		unemployed_row >= 0 and unemployed_worst == SAT_DIM_SUBSISTENCE)
	var development := int(fed_dims[SAT_DIM_DEVELOPMENT])
	_expect("social development stays inside its normalized range",
		development >= 0 and development < Q16_ONE)
	_expect("an untaxed cohort scores full marks on tax burden",
		int(fed_dims[SAT_DIM_TAX]) == Q16_ONE - 1)


func _test_class_weight_differentiation(compiled: Dictionary) -> void:
	# Jobless households and merchants share a market but retain distinct
	# profession weights; zero luxury weight must not hide the diagnostic score.
	var ext := _configured_world(compiled, 4002, true, true)
	if ext == null:
		return
	for cycle in range(6):
		_run_cycle(ext, cycle)
	var snapshot: Dictionary = ext.get_population_cell_snapshot(0)
	var professions: PackedStringArray = snapshot.get(
		"profession_stable_ids", PackedStringArray())
	var profession_indices: PackedInt32Array = snapshot.get(
		"profession_ids", PackedInt32Array())
	var unemployed_row := -1
	var merchant_row := -1
	for row in range(profession_indices.size()):
		var index := int(profession_indices[row])
		if index < 0 or index >= professions.size():
			continue
		if String(professions[index]) == "unemployed":
			unemployed_row = row
		elif String(professions[index]) == "merchant":
			merchant_row = row
	if unemployed_row < 0 or merchant_row < 0:
		_expect("both authored classes survive the settlement", false)
		return
	var unemployed_dims := _dims_for_cohort(snapshot, unemployed_row)
	var merchant_dims := _dims_for_cohort(snapshot, merchant_row)
	var handles: PackedInt64Array = snapshot.handles
	var unemployed_explain: Dictionary = ext.explain_cohort_satisfaction(handles[unemployed_row])
	_expect("a class without luxury needs publishes N/A and no luxury weight",
		int((unemployed_explain.dim_weights_q16 as PackedInt32Array)[SAT_DIM_LUXURY]) == 0 and
		int(unemployed_dims[SAT_DIM_LUXURY]) == -1)

	_expect("two classes under one market reach different composites",
		_composite_for_cohort(snapshot, unemployed_row) !=
			_composite_for_cohort(snapshot, merchant_row))
	_expect("the basic tier is scored for both classes",
		int(unemployed_dims[SAT_DIM_BASIC]) >= 0 and
		int(merchant_dims[SAT_DIM_BASIC]) >= 0)


func _test_realized_consumption(compiled: Dictionary) -> void:
	var rich := _configured_world(compiled, 4010, true, false,
		{"funds": 20000000000, "fixed_demand": true})
	var scarce := _configured_world(compiled, 4010, true, false,
		{"funds": 20000000000, "fixed_demand": true, "block_comfort": true})
	for ext in [rich, scarce]:
		var report := _run_cycle(ext, 0)
		_expect("realized-consumption settlement conserves ledgers",
			bool(report.get("done", false)) and not bool(report.get("fatal", false)) and
			int(report.get("population_error", 1)) == 0 and
			int(report.get("money_error", 1)) == 0 and int(report.get("goods_error", 1)) == 0)
	var rich_snap: Dictionary = rich.get_population_cell_snapshot(0)
	var scarce_snap: Dictionary = scarce.get_population_cell_snapshot(0)
	var good: Dictionary = rich.explain_cohort_satisfaction(rich_snap.handles[0])
	var bad: Dictionary = scarce.explain_cohort_satisfaction(scarce_snap.handles[0])
	var gd: PackedInt32Array = good.dim_values_q16
	var bd: PackedInt32Array = bad.dim_values_q16
	_expect("abundant comfort goods satisfy the reference consumption target",
		gd[SAT_DIM_COMFORT] >= 65534)
	_expect("rich households with missing comfort goods have zero comfort",
		bd[SAT_DIM_COMFORT] == 0 and bd[SAT_DIM_SAVINGS] == 65535)
	_expect("absent luxury needs never show 100 percent",
		gd[SAT_DIM_LUXURY] == -1 and bd[SAT_DIM_LUXURY] == -1)
	_expect("stock shortages reduce satisfaction even while savings remain ample",
		int(bad.composite_q16) < int(good.composite_q16))
	_expect("adequate real living remains above the existing birth reference",
		int(good.composite_q16) >= 45875)
	_expect("cash alone cannot produce an extravagant living standard",
		int(bad.living_standard_level) <= 3)
	var weights: PackedInt32Array = good.dim_weights_q16
	_expect("missing luxury redistributes within consumption only",
		weights[0] + weights[1] + weights[2] + weights[3] == 45875 and
		weights[4] + weights[5] == 13107 and weights[6] == 3277 and weights[7] == 3277)
	var merchant := _configured_world(compiled, 4014, true, false,
		{"funds": 20000000000, "fixed_demand": true, "signature": "merchant|default", "block_luxury": true})
	_run_cycle(merchant, 0)
	var merchant_snap: Dictionary = merchant.get_population_cell_snapshot(0)
	var merchant_explain: Dictionary = merchant.explain_cohort_satisfaction(merchant_snap.handles[0])
	_expect("an applicable luxury tier stays at zero when a rich merchant cannot buy it",
		int(merchant_explain.dim_values_q16[SAT_DIM_LUXURY]) == 0 and
		int(merchant_explain.dim_values_q16[SAT_DIM_SAVINGS]) == 65535 and
		int(merchant_explain.dim_weights_q16[SAT_DIM_LUXURY]) > 0)
	var penniless := _configured_world(compiled, 4015, true, false,
		{"funds": 0, "fixed_demand": true})
	_run_cycle(penniless, 0)
	var penniless_dims := _dims_for_cohort(penniless.get_population_cell_snapshot(0), 0)
	_expect("unaffordable needs remain in the living-target denominator",
		penniless_dims[SAT_DIM_BASIC] == 0 and penniless_dims[SAT_DIM_COMFORT] == 0)

	var deficit := _configured_world(compiled, 4011, true, false,
		{"funds": 20000000000, "fixed_demand": true, "block_basic": true})
	_run_cycle(deficit, 0)
	var deficit_snap: Dictionary = deficit.get_population_cell_snapshot(0)
	var limited: Dictionary = deficit.explain_cohort_satisfaction(deficit_snap.handles[0])
	var basic := int(limited.dim_values_q16[SAT_DIM_BASIC])
	var basic_ceiling := basic + (65535 - basic) * 13107 / 65536
	_expect("basic living constrains composite independently of savings and comfort",
		basic < 65535 and int(limited.composite_q16) <= basic_ceiling)
	_expect("explain reproduces the weighted result and both gates exactly",
		int(limited.composite_q16) == mini(int(limited.raw_q16), int(limited.ceiling_q16)))

	var normal := _configured_world(compiled, 4012, true, false,
		{"funds": 20000000000, "fixed_demand": true, "price_elastic": true})
	var expensive := _configured_world(compiled, 4012, true, false,
		{"funds": 20000000000, "fixed_demand": true, "price_elastic": true, "price_multiplier": 10})
	_run_cycle(normal, 0)
	_run_cycle(expensive, 0)
	# Bootstrap may have a day-zero demand-basis cache from default prices.
	# Compare a fresh sampled cycle after the injected prices are observable.
	_run_cycle(normal, 1)
	_run_cycle(expensive, 1)
	var normal_dims := _dims_for_cohort(normal.get_population_cell_snapshot(0), 0)
	var expensive_dims := _dims_for_cohort(expensive.get_population_cell_snapshot(0), 0)
	_expect("price-elastic reduced purchases cannot retain full consumption satisfaction",
		expensive_dims[SAT_DIM_COMFORT] < normal_dims[SAT_DIM_COMFORT] and
		expensive_dims[SAT_DIM_COMFORT] < 65535)

	var worker := _configured_world(compiled, 4010, true, false,
		{"funds": 20000000000, "fixed_demand": true, "profile": {"worker_enabled": true}})
	_run_cycle(worker, 0)
	_expect("scalar and worker settlement preserve identical economy state hashes",
		int(rich.get_economy_state_hash()) == int(worker.get_economy_state_hash()))


func _test_explain_and_attractiveness(compiled: Dictionary) -> void:
	var ext := _configured_world(compiled, 4003, true)
	if ext == null:
		return
	for cycle in range(4):
		_run_cycle(ext, cycle)
	var snapshot: Dictionary = ext.get_population_cell_snapshot(0)
	var handles: PackedInt64Array = snapshot.get("handles", PackedInt64Array())
	if handles.is_empty():
		_expect("the settled cell keeps at least one cohort", false)
		return
	var explained: Dictionary = ext.explain_cohort_satisfaction(int(handles[0]))
	var values: PackedInt32Array = explained.get("dim_values_q16", PackedInt32Array())
	var weights: PackedInt32Array = explained.get("dim_weights_q16", PackedInt32Array())
	var contributions: PackedInt32Array = explained.get(
		"dim_contributions_q16", PackedInt32Array())
	_expect("explain returns one row per dimension",
		bool(explained.get("ok", false)) and values.size() == SAT_DIM_COUNT and
		weights.size() == SAT_DIM_COUNT and contributions.size() == SAT_DIM_COUNT)
	_expect("explain agrees with the published composite column",
		int(explained.get("composite_q16", -1)) ==
			_composite_for_cohort(snapshot, 0))
	_expect("explain reports the gate it applied",
		int(explained.get("composite_q16", -1)) <=
			int(explained.get("ceiling_q16", -1)) and
		int(explained.get("ceiling_q16", -1)) <= int(values[SAT_DIM_SUBSISTENCE]) +
			(65535 - int(values[SAT_DIM_SUBSISTENCE])) * 6554 / 65536)
	_expect("explain carries the raw dimension inputs",
		explained.has("income_baseline_ema") and explained.has("epoch_tax_paid") and
		explained.has("living_cost_per_capita") and explained.has("development_q16"))
	_expect("explain rejects a stale cohort handle",
		not bool(ext.explain_cohort_satisfaction(0).get("ok", true)))
	var attractiveness: Dictionary = ext.get_cell_satisfaction_attractiveness(0)
	_expect("cell attractiveness aggregates the same authoritative columns",
		bool(attractiveness.get("ok", false)) and
		(attractiveness.get("dim_values_q16", PackedInt32Array())
			as PackedInt32Array).size() == SAT_DIM_COUNT and
		int(attractiveness.get("population", 0)) > 0)
	var level := int(attractiveness.get("social_pressure_level", -1))
	_expect("the published pressure level stays inside its five bands",
		level >= 0 and level < 5 and
		int(attractiveness.get("published_pressure_level", -1)) >= 0)
	_expect("attractiveness rejects an out-of-range cell",
		not bool(ext.get_cell_satisfaction_attractiveness(99).get("ok", true)))


func _test_save_round_trip(compiled: Dictionary, check_full_replay_hash: bool = true) -> void:
	var source := _configured_world(compiled, 4004, true)
	if source == null:
		return
	for cycle in range(5):
		_run_cycle(source, cycle)
	var before: Dictionary = source.get_population_cell_snapshot(0)
	# Economy replay requires the matching Country technology/assets snapshot.
	var country_begin: Dictionary = source.begin_country_save(65536)
	_expect("the replay fixture saves its Country peer", bool(country_begin.get("ok", false)))
	var country_chunks: Array[PackedByteArray] = []
	while true:
		var chunk: PackedByteArray = source.read_country_save_chunk(65536)
		if chunk.is_empty():
			break
		country_chunks.append(chunk)
	_expect("Country peer save completes", bool(source.end_country_save().get("ok", false)))
	var saved := _save(source)
	_expect("PKEC v56 streams the satisfaction columns",
		bool(saved.get("ok", false)) and int(saved.get("schema", 0)) == 57)
	if not bool(saved.get("ok", false)):
		return
	var restored := _configured_world(compiled, 4004, true, false,
		{"country_chunks": country_chunks, "skip_bootstrap": true})
	if restored == null:
		return
	var restore_result := _restore(restored, saved.get("chunks", []))
	_expect("PKEC v56 restores the satisfaction columns",
		bool(restore_result.get("ok", false)))
	_expect("composite satisfaction enters the economy state hash",
		int(source.get_economy_state_hash()) ==
			int(restored.get_economy_state_hash()))
	var after: Dictionary = restored.get_population_cell_snapshot(0)
	_expect("restored dimensions match column for column",
		before.get("satisfaction_dims_by_cohort_q16", PackedInt32Array()) ==
			after.get("satisfaction_dims_by_cohort_q16", PackedInt32Array()) and
		before.get("overall_satisfaction_by_cohort_q16", PackedInt32Array()) ==
			after.get("overall_satisfaction_by_cohort_q16", PackedInt32Array()) and
		before.get("worst_satisfaction_dimension_by_cohort", PackedInt32Array()) ==
			after.get("worst_satisfaction_dimension_by_cohort", PackedInt32Array()))
	var source_next := _run_cycle(source, 5)
	var restored_next := _run_cycle(restored, 5)
	var source_dims: Dictionary = source.get_population_cell_snapshot(0)
	var restored_dims: Dictionary = restored.get_population_cell_snapshot(0)
	_expect("restored satisfaction scores replay the next settlement identically",
		source_dims.satisfaction_dims_by_cohort_q16 == restored_dims.satisfaction_dims_by_cohort_q16 and
		source_dims.overall_satisfaction_by_cohort_q16 == restored_dims.overall_satisfaction_by_cohort_q16)
	_expect("both replayed settlements conserve ledgers",
		int(source_next.get("population_error", 1)) == 0 and
		int(source_next.get("money_error", 1)) == 0 and int(source_next.get("goods_error", 1)) == 0 and
		int(restored_next.get("population_error", 1)) == 0 and
		int(restored_next.get("money_error", 1)) == 0 and int(restored_next.get("goods_error", 1)) == 0)
	if check_full_replay_hash:
		_expect("the restored runtime replays the next cycle identically",
			int(source.get_economy_state_hash()) == int(restored.get_economy_state_hash()))


func _configured_world(compiled: Dictionary, seed: int, stocked: bool,
		mixed_classes: bool = false, tuning: Dictionary = {}) -> Object:
	var ext := _new_ext(1)
	var catalog := compiled.duplicate(true)
	catalog.erase("ok")
	if bool(tuning.get("fixed_demand", false)):
		for key in ["need_wealth_min_q16", "need_wealth_max_q16"]:
			var values: PackedInt32Array = catalog[key].duplicate()
			values.fill(65536)
			catalog[key] = values
		for key in ["need_wealth_elasticity_q16", "variant_class_wealth_elasticity_delta_q16",
				"variant_class_savings_threshold_factor_q16", "good_household_wealth_elasticity_q16"]:
			var values: PackedInt32Array = catalog[key].duplicate()
			values.fill(0)
			catalog[key] = values
		if not bool(tuning.get("price_elastic", false)):
			var values: PackedInt32Array = catalog.need_price_quantity_elasticity_q16.duplicate()
			values.fill(0)
			catalog.need_price_quantity_elasticity_q16 = values

	if not CountryTestHelper.configure_all_technologies(ext, catalog, 1, seed):
		_expect("satisfaction test country configures", false)
		return null
	if tuning.has("country_chunks"):
		_expect("Country peer restore begins", bool(ext.begin_country_restore().get("ok", false)))
		for chunk in tuning.country_chunks:
			ext.feed_country_restore_chunk(chunk)
		_expect("Country peer restores before Economy", bool(ext.end_country_restore().get("ok", false)))
	var profile = load("res://data/economy/default_economy.tres").to_native_profile()
	profile.market_runtime_mode = "ACTIVE"
	profile.market_cycle_days = 5
	profile.worker_enabled = false
	# Keep numerical replay independent of transient approximation cooldowns.
	profile.economy_accuracy_preset = "EXACT"
	# Bound voluntary mobility; mandatory job loss may still create unemployed cohorts.
	profile.employment_mobility_daily_q16 = 0
	profile.merge(tuning.get("profile", {}), true)
	var births: PackedInt64Array = catalog.signature_birth_rate_q32
	var deaths: PackedInt64Array = catalog.signature_death_rate_q32
	births.fill(0)
	deaths.fill(0)
	catalog.signature_birth_rate_q32 = births
	catalog.signature_death_rate_q32 = deaths
	profile.carrying_k_habitat_ref = 100000
	profile.carrying_k_floor = 100000
	profile.carrying_surplus_elasticity_q16 = 0
	profile.carrying_sat_elasticity_q16 = 0
	var configured: Dictionary = ext.configure_economy(catalog, profile, 1, seed)
	if not bool(configured.get("ok", false)):
		print("satisfaction economy configuration: ", configured)
		_expect("satisfaction test economy configures", false)
		return null
	if bool(tuning.get("skip_bootstrap", false)):
		return ext
	var signature_keys: PackedStringArray = catalog.signature_keys
	var farmer := signature_keys.find(String(tuning.get("signature", "subsistence_farmer|default")))
	var merchant := signature_keys.find("merchant|default")
	var signature_ids := PackedInt32Array([farmer])
	var cell_indices := PackedInt32Array([0])
	var populations := PackedInt64Array([400])
	var funds := PackedInt64Array([int(tuning.get("funds", 200000000))])
	if mixed_classes:
		cell_indices.append(0)
		signature_ids.append(merchant)
		populations.append(80)
		funds.append(200000000)
	var stock := PackedInt64Array()
	stock.resize((catalog.good_ids as PackedStringArray).size())
	stock.fill(1000000000000 if stocked else 0)
	if bool(tuning.get("block_comfort", false)) or bool(tuning.get("block_basic", false)) or bool(tuning.get("block_luxury", false)):
		var blocked := {"spices": true, "salt": true, "furniture": true, "leather_goods": true,
			"pottery": true, "glassware": true, "metal_housewares": true,
			"horses": true, "automobiles": true, "beverages": true, "computers": true}
		if bool(tuning.get("block_basic", false)):
			blocked = {"soap": true, "detergent": true}
		if bool(tuning.get("block_luxury", false)):
			blocked = {"beverages": true, "fine_clothing": true, "fine_furniture": true, "jewelry": true, "fur": true}
		for g in range((catalog.good_ids as PackedStringArray).size()):
			if blocked.has(String(catalog.good_ids[g])):
				stock[g] = 0
	var prices: PackedInt32Array = catalog.good_default_price.duplicate()
	for good in range(prices.size()):
		prices[good] *= int(tuning.get("price_multiplier", 1))
	if not bool(ext.bootstrap_economy({
		"cell_indices": cell_indices,
		"signature_ids": signature_ids,
		"population": populations,
		"funds": funds,
	}, {"stock": stock, "price": prices}).get("ok", false)):
		_expect("satisfaction test population bootstraps", false)
		return null
	return ext


func _dims_for_cohort(snapshot: Dictionary, row: int) -> PackedInt32Array:
	var dims: PackedInt32Array = snapshot.get(
		"satisfaction_dims_by_cohort_q16", PackedInt32Array())
	var begin := row * SAT_DIM_COUNT
	if begin < 0 or begin + SAT_DIM_COUNT > dims.size():
		return PackedInt32Array()
	return dims.slice(begin, begin + SAT_DIM_COUNT)


func _composite_for_cohort(snapshot: Dictionary, row: int) -> int:
	var composites: PackedInt32Array = snapshot.get(
		"overall_satisfaction_by_cohort_q16", PackedInt32Array())
	return int(composites[row]) if row >= 0 and row < composites.size() else -1


func _new_ext(cells: int) -> Object:
	var ext: Object = ClassDB.instantiate("DCWorldExt")
	ext.create_entities(cells)
	for slot_name in [&"cell_temp", &"cell_temp_30d", &"cell_moisture",
			&"cell_plant_available_water", &"cell_weather_precip", &"cell_snow_cover",
			&"cell_weather_intensity", &"cell_temp_365d"]:
		var values := PackedFloat32Array()
		values.resize(cells)
		values.fill(1.0 if slot_name == &"cell_temp" else 0.0)
		var slot: int = ext.register_component(slot_name, 0, 1, false)
		ext.write_f32_range(slot, 0, values)
	var zeros := PackedByteArray()
	zeros.resize(cells)
	zeros.fill(0)
	ext.write_u8_range(ext.register_component(&"cell_weather_type", 2, 1, false), 0, zeros)
	ext.write_u8_range(ext.register_component(&"cell_cover", 2, 1, false), 0, zeros)
	return ext


func _run_cycle(ext: Object, cycle: int) -> Dictionary:
	var report: Dictionary = {}
	for slice in range(256):
		report = ext.run_economy_slice({
			"day_index": cycle * 5,
			"tick_index": slice,
		})
		if bool(report.get("done", false)):
			return report
	return report


func _save(ext: Object) -> Dictionary:
	var begin: Dictionary = ext.begin_economy_save(65536)
	if not bool(begin.get("ok", false)):
		return begin
	var chunks: Array[PackedByteArray] = []
	while true:
		var chunk: PackedByteArray = ext.read_economy_save_chunk(65536)
		if chunk.is_empty():
			break
		chunks.append(chunk)
	var ended: Dictionary = ext.end_economy_save()
	return {"ok": bool(ended.get("ok", false)),
		"schema": int(begin.get("schema_version", 0)), "chunks": chunks}


func _restore(ext: Object, chunks: Array) -> Dictionary:
	var begin: Dictionary = ext.begin_economy_restore()
	if not bool(begin.get("ok", false)):
		return begin
	for value in chunks:
		var fed: Dictionary = ext.feed_economy_restore_chunk(value as PackedByteArray)
		if not bool(fed.get("ok", false)):
			return fed
	return ext.end_economy_restore()


func _expect(label: String, condition: bool) -> void:
	_checks += 1
	print("  [%s] %s" % ["PASS" if condition else "FAIL", label])
	if not condition:
		_failures += 1
