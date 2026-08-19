extends SceneTree

## Composite satisfaction runtime coverage: the eight dimensions, the
## subsistence gate, class (profession) weight differentiation, the explain and
## attractiveness read APIs, and PKEC v30 round-trip plus state hash.

const EconomyCatalogScript = preload("res://scripts/economy/economy_catalog.gd")
const CountryTestHelper = preload("res://tests/country_test_helper.gd")

const SAT_DIM_SUBSISTENCE := 0
const SAT_DIM_BASIC := 1
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
		starving_composite <= ceiling and
		int(starving_dims[SAT_DIM_SAVINGS]) > starving_composite)
	var starving_professions: PackedStringArray = starving_snapshot.get(
		"profession_stable_ids", PackedStringArray())
	var starving_profession_indices: PackedInt32Array = starving_snapshot.get(
		"profession_ids", PackedInt32Array())
	var starving_worsts: PackedInt32Array = starving_snapshot.get(
		"worst_satisfaction_dimension_by_cohort", PackedInt32Array())
	var farmer_worst := -1
	var farmer_row := -1
	for row in range(starving_profession_indices.size()):
		var profession_index := int(starving_profession_indices[row])
		if profession_index < 0 or profession_index >= starving_professions.size():
			continue
		if String(starving_professions[profession_index]) != "subsistence_farmer":
			continue
		farmer_row = row
		farmer_worst = int(starving_worsts[row]) if row < starving_worsts.size() else -1
		break
	_expect("the worst dimension points at the binding constraint",
		farmer_row >= 0 and farmer_worst == SAT_DIM_SUBSISTENCE)
	var development := int(fed_dims[SAT_DIM_DEVELOPMENT])
	_expect("social development stays inside its normalized range",
		development >= 0 and development < Q16_ONE)
	_expect("an untaxed cohort scores full marks on tax burden",
		int(fed_dims[SAT_DIM_TAX]) == Q16_ONE - 1)


func _test_class_weight_differentiation(compiled: Dictionary) -> void:
	# Identical material conditions, different profession weights: the composite
	# must diverge, which is the whole point of data-driven class weights.
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
	var farmer_row := -1
	var merchant_row := -1
	for row in range(profession_indices.size()):
		var index := int(profession_indices[row])
		if index < 0 or index >= professions.size():
			continue
		if String(professions[index]) == "subsistence_farmer":
			farmer_row = row
		elif String(professions[index]) == "merchant":
			merchant_row = row
	if farmer_row < 0 or merchant_row < 0:
		_expect("both authored classes survive the settlement", false)
		return
	var farmer_dims := _dims_for_cohort(snapshot, farmer_row)
	var merchant_dims := _dims_for_cohort(snapshot, merchant_row)
	_expect("the luxury dimension is excluded from a plan without luxuries",
		int(farmer_dims[SAT_DIM_LUXURY]) == Q16_ONE - 1)
	_expect("two classes under one market reach different composites",
		_composite_for_cohort(snapshot, farmer_row) !=
			_composite_for_cohort(snapshot, merchant_row))
	_expect("the basic tier is scored for both classes",
		int(farmer_dims[SAT_DIM_BASIC]) >= 0 and
		int(merchant_dims[SAT_DIM_BASIC]) >= 0)


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
		int(explained.get("ceiling_q16", -1)) >= int(values[SAT_DIM_SUBSISTENCE]))
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


func _test_save_round_trip(compiled: Dictionary) -> void:
	var source := _configured_world(compiled, 4004, true)
	if source == null:
		return
	for cycle in range(5):
		_run_cycle(source, cycle)
	var before: Dictionary = source.get_population_cell_snapshot(0)
	var saved := _save(source)
	_expect("PKEC v37 streams the satisfaction columns",
		bool(saved.get("ok", false)) and int(saved.get("schema", 0)) == 39)
	if not bool(saved.get("ok", false)):
		return
	var restored := _configured_world(compiled, 4004, true)
	if restored == null:
		return
	var restore_result := _restore(restored, saved.get("chunks", []))
	_expect("PKEC v30 restores the satisfaction columns",
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
	_expect("the restored runtime replays the next cycle identically",
		int(source_next.get("population_error", 1)) == 0 and
		int(restored_next.get("population_error", 1)) == 0 and
		int(source.get_economy_state_hash()) ==
			int(restored.get_economy_state_hash()))


func _configured_world(compiled: Dictionary, seed: int, stocked: bool,
		mixed_classes: bool = false) -> Object:
	var ext := _new_ext(1)
	var catalog := compiled.duplicate(true)
	catalog.erase("ok")
	var profile = load("res://data/economy/default_economy.tres").to_native_profile()
	profile.market_runtime_mode = "ACTIVE"
	profile.market_cycle_days = 5
	profile.worker_enabled = false
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
	if not CountryTestHelper.configure_all_technologies(ext, catalog, 1, seed):
		_expect("satisfaction test country configures", false)
		return null
	if not bool(ext.configure_economy(catalog, profile, 1, seed).get("ok", false)):
		_expect("satisfaction test economy configures", false)
		return null
	var signature_keys: PackedStringArray = catalog.signature_keys
	var farmer := signature_keys.find("subsistence_farmer|default")
	var merchant := signature_keys.find("merchant|default")
	var signature_ids := PackedInt32Array([farmer])
	var cell_indices := PackedInt32Array([0])
	var populations := PackedInt64Array([400])
	var funds := PackedInt64Array([200000000])
	if mixed_classes:
		cell_indices.append(0)
		signature_ids.append(merchant)
		populations.append(80)
		funds.append(200000000)
	var stock := PackedInt64Array()
	stock.resize((catalog.good_ids as PackedStringArray).size())
	stock.fill(1000000000000 if stocked else 0)
	if not bool(ext.bootstrap_economy({
		"cell_indices": cell_indices,
		"signature_ids": signature_ids,
		"population": populations,
		"funds": funds,
	}, {"stock": stock}).get("ok", false)):
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
			&"cell_plant_available_water", &"cell_snow_cover", &"cell_weather_intensity"]:
		var values := PackedFloat32Array()
		values.resize(cells)
		values.fill(1.0 if slot_name == &"cell_temp" else 0.0)
		var slot: int = ext.register_component(slot_name, 0, 1, false)
		ext.write_f32_range(slot, 0, values)
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
