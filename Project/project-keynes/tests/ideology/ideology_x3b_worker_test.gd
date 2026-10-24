extends SceneTree

## X3-b: profession-share metrics must walk the paged cohort store.
##
## The fixture gives cell 5 page 0 first, then moves one cohort to cell 0, so
## cell 0's first slot is not cell 0's id. Metrics 96..98 are computed from the
## actual cohort rows, and metric 99 is the committed `worker` class row.

const CountryCatalogScript = preload(
	"res://scripts/economy/economy_catalog.gd")
const Q16_ONE := 65536
const CELL_COUNT := 6
const TARGET_CELL := 0
const FIRST_SETTLED_CELL := 5
const COHORT_PAGE_SIZE := 64
const COMMAND_MOVE_POPULATION := 7
const COMMAND_CHANGE_SIGNATURE := 8

const METRIC_DOMINANT_PROFESSION_ID := 51
const METRIC_DOMINANT_PROFESSION_SHARE := 52
const METRIC_PROFESSION_COUNT := 53
const METRIC_FARMER_SHARE := 96
const METRIC_INDUSTRIAL_SHARE := 97
const METRIC_COOPERATIVE_SHARE := 98
const METRIC_WORKER_CLASS_SATISFACTION := 99

const FARMER_PROFESSIONS := [
	"household_farmer",
	"subsistence_farmer",
	"tenant_farmer",
	"sharecropper",
	"agricultural_worker",
	"serf",
]

var _checks := 0
var _failures := 0
var _sequence := 1


func _init() -> void:
	_run()
	print("=== ideology x3b worker: %d checks, %d failures ==="
		% [_checks, _failures])
	quit(0 if _failures == 0 else 1)


func _run() -> void:
	if not ClassDB.class_exists("DCWorldExt"):
		_expect("DCWorldExt is available", false)
		return
	var catalog: Dictionary = CountryCatalogScript.compile_native_catalog()
	if not _require("economy catalog compiles",
			bool(catalog.get("ok", false)), str(catalog.get("reason", ""))):
		return
	var ext: Object = _build_ext(catalog)
	if ext == null:
		return
	var target_snapshot: Dictionary = ext.get_population_cell_snapshot(
		TARGET_CELL, false)
	var target_handles: PackedInt64Array = target_snapshot.get(
		"handles", PackedInt64Array())
	var first_page := -1
	for handle in target_handles:
		var page := int(handle) / COHORT_PAGE_SIZE
		if first_page < 0 or page < first_page:
			first_page = page
	_expect("the target cell's first page is not its cell id",
		first_page != 0, "first_page=%d" % first_page)

	var target: Dictionary = ext.get_population_cell_snapshot(
		TARGET_CELL, false)
	var professions: PackedInt32Array = target.get(
		"profession_ids", PackedInt32Array())
	var populations: PackedInt64Array = target.get(
		"populations", PackedInt64Array())
	if not _require("the target snapshot has aligned profession columns",
			professions.size() == populations.size(), str(target)):
		return
	var expected := _expected_shares(catalog, professions, populations)
	var total_known_population := int(expected.get("total", 0))
	_expect("the fixture has known-profession cohorts",
		total_known_population > 0, str(expected))
	_expect("the target has a farmer cohort",
		int(expected.get("farmer", 0)) > 0, str(expected))
	_expect("the target has an industrial cohort",
		int(expected.get("industrial", 0)) > 0, str(expected))
	_expect("the target has a cooperative cohort",
		int(expected.get("cooperative", 0)) > 0, str(expected))
	if total_known_population <= 0:
		return
	var farmer_share := _metric(ext, METRIC_FARMER_SHARE, TARGET_CELL)
	var industrial_share := _metric(ext, METRIC_INDUSTRIAL_SHARE, TARGET_CELL)
	var cooperative_share := _metric(ext, METRIC_COOPERATIVE_SHARE, TARGET_CELL)
	_expect("metric 96 is the pinned farmer share",
		farmer_share == _share_q16(int(expected.get("farmer", 0)),
			total_known_population),
		"metric=%d expected=%d rows=%s" % [farmer_share,
			_share_q16(int(expected.get("farmer", 0)), total_known_population),
			str(expected)])
	_expect("metric 97 is the pinned industrial share",
		industrial_share == _share_q16(int(expected.get("industrial", 0)),
			total_known_population),
		"metric=%d expected=%d rows=%s" % [industrial_share,
			_share_q16(int(expected.get("industrial", 0)), total_known_population),
			str(expected)])
	_expect("metric 98 is the pinned cooperative share",
		cooperative_share == _share_q16(int(expected.get("cooperative", 0)),
			total_known_population),
		"metric=%d expected=%d rows=%s" % [cooperative_share,
			_share_q16(int(expected.get("cooperative", 0)), total_known_population),
			str(expected)])
	_expect("farmer and industrial shares are not the stale page-0 values",
		farmer_share != _metric(ext, METRIC_FARMER_SHARE, FIRST_SETTLED_CELL),
		"target=%d source=%d" % [farmer_share,
			_metric(ext, METRIC_FARMER_SHARE, FIRST_SETTLED_CELL)])
	# This fixture's cohorts are deliberately unemployed so all three groups
	# contribute to the new shares; 51..53 keep their historical employed-only
	# denominator and therefore read their empty-cell values here.
	_expect("dominant profession keeps its employed-only semantics",
		_metric(ext, METRIC_DOMINANT_PROFESSION_ID, TARGET_CELL) == -Q16_ONE)
	_expect("dominant profession share is zero without employed cohorts",
		_metric(ext, METRIC_DOMINANT_PROFESSION_SHARE, TARGET_CELL) == 0)
	_expect("profession count is zero without employed cohorts",
		_metric(ext, METRIC_PROFESSION_COUNT, TARGET_CELL) == 0)
	var day_zero: Dictionary = _run_day(ext, 0)
	if not _require("day 0 reaches its commit", bool(day_zero.get("done", false)),
			str(day_zero)):
		return
	var source_snapshot: Dictionary = ext.get_class_metric_source_for_test()
	var class_ids: PackedStringArray = source_snapshot.get(
		"snapshot_class_ids", PackedStringArray())
	var worker_class := class_ids.find("worker")
	if not _require("the committed class snapshot has a worker row",
			worker_class >= 0, str(class_ids)):
		return
	var country_index := _snapshot_country_index(ext)
	if not _require("the committed class snapshot has the fixture country",
			country_index >= 0, str(ext.get_country_class_opinion_snapshot().get(
				"country_handles", PackedInt64Array()))):
		return
	var class_count := int(source_snapshot.get("snapshot_class_count", 0))
	var row := country_index * class_count + worker_class
	var satisfaction: PackedInt32Array = source_snapshot.get(
		"snapshot_satisfaction_q16", PackedInt32Array())
	if not _require("the worker class row is inside the committed snapshot",
			row >= 0 and row < satisfaction.size(), "row=%d size=%d" % [
				row, satisfaction.size()]):
		return
	var override_satisfaction := satisfaction.duplicate()
	var override_population: PackedInt64Array = source_snapshot.get(
		"snapshot_population", PackedInt64Array())
	var override_weighted: PackedInt64Array = source_snapshot.get(
		"snapshot_satisfaction_weighted", PackedInt64Array())
	if not _require("the committed class rows are aligned",
			override_population.size() == override_satisfaction.size()
				and override_weighted.size() == override_satisfaction.size(),
			str(source_snapshot)):
		return
	override_satisfaction[row] = int(round(0.23 * Q16_ONE))
	override_weighted[row] = (
		int(override_satisfaction[row]) * maxi(0, int(override_population[row])))
	var override: Dictionary = ext.set_class_opinion_source_override_for_test(
		override_population, override_satisfaction, override_weighted)
	if not _require("the worker-class source override applies",
			bool(override.get("ok", false)), str(override)):
		return
	var captured: Dictionary = ext.capture_class_metric_source_for_test()
	if not _require("the worker-class source recaptures",
			bool(captured.get("ok", false)), str(captured)):
		return
	var copied_worker: PackedInt64Array = captured.get(
		"copied_worker_class_satisfaction_q16", PackedInt64Array())
	_expect("the copied worker vector carries the override",
		country_index < copied_worker.size()
			and int(copied_worker[country_index])
				== int(override_satisfaction[row]),
		str(copied_worker))
	_expect("metric 99 samples the committed worker row",
		_metric(ext, METRIC_WORKER_CLASS_SATISFACTION, TARGET_CELL)
			== int(override_satisfaction[row]),
		"metric=%d expected=%d source=%s" % [
			_metric(ext, METRIC_WORKER_CLASS_SATISFACTION, TARGET_CELL),
			int(override_satisfaction[row]), str(captured)])


func _build_ext(catalog: Dictionary) -> Object:
	var ext: Object = ClassDB.instantiate("DCWorldExt")
	ext.create_entities(CELL_COUNT)
	for slot_name in [&"cell_temp", &"cell_temp_30d", &"cell_moisture",
			&"cell_plant_available_water", &"cell_weather_precip",
			&"cell_snow_cover", &"cell_weather_intensity", &"cell_elevation",
			&"cell_temp_365d"]:
		var sid: int = ext.register_component(slot_name, 0, 1, false)
		ext.write_f32_range(sid, 0, _f32_fill(0.5))
	for slot_name in [&"cell_terrain", &"cell_landform", &"cell_vegetation",
			&"cell_is_water", &"cell_has_river", &"cell_weather_type", &"cell_cover"]:
		var sid: int = ext.register_component(slot_name, 2, 1, false)
		ext.write_u8_range(sid, 0, _u8_fill(0))
	for i in range((catalog.building_resource_ids as PackedStringArray).size()):
		var reserve_sid: int = ext.register_component(StringName(
			(catalog.building_resource_reserve_slots as PackedStringArray)[i]),
			0, 1, false)
		var extra_sid: int = ext.register_component(StringName(
			(catalog.building_resource_extra_slots as PackedStringArray)[i]),
			0, 1, false)
		ext.write_f32_range(reserve_sid, 0, _f32_fill(1000000.0))
		ext.write_f32_range(extra_sid, 0, _f32_fill(0.0))
	if not _require("country configures", bool(ext.configure_country(catalog, {
			"country_runtime_mode": "ACTIVE",
			"starting_technology_ids": PackedStringArray(["tech.hunting"]),
		}, CELL_COUNT, 97).get("ok", false))):
		return null
	var territory := PackedInt32Array([TARGET_CELL, FIRST_SETTLED_CELL])
	var country_outcome: Dictionary = ext.bootstrap_country({
		"country_ids": PackedStringArray(["country.x3b_a", "country.x3b_b"]),
		"country_names": PackedStringArray(["X3B A", "X3B B"]),
		"country_cash": PackedInt64Array([1000000000, 2000000000]),
		"territory_offsets": PackedInt32Array([0, 1, 2]),
		"territory_cells": territory,
		"technology_offsets": PackedInt32Array([0, 0, 0]),
		"technology_indices": PackedInt32Array(),
		"treasury_offsets": PackedInt32Array([0, 0, 0]),
		"treasury_good_indices": PackedInt32Array(),
		"treasury_quantities": PackedInt64Array(),
	}, _u8_fill(0))
	if not _require("two countries bootstrap",
			bool(country_outcome.get("ok", false)), str(country_outcome)):
		return null
	var economy: Dictionary = ext.configure_economy(catalog,
		_fixture_profile(), CELL_COUNT, 97)
	if not _require("economy configures", bool(economy.get("ok", false)),
			str(economy)):
		return null
	var merchant_sig := (catalog.signature_keys as PackedStringArray).find(
		"merchant|default")
	var farmer_sig := _signature_for_profession(catalog, "household_farmer")
	var industrial_sig := _signature_for_profession(catalog, "industrial_worker")
	var cooperative_sig := _signature_for_profession(catalog, "cooperative_member")
	var merchant_post := (catalog.building_type_ids as PackedStringArray).find(
		"merchant_post")
	if not _require("fixture finds its cohort signatures",
			merchant_sig >= 0 and farmer_sig >= 0
				and industrial_sig >= 0 and cooperative_sig >= 0):
		return null
	if not _require("fixture finds the merchant post", merchant_post >= 0):
		return null
	var goods := (catalog.good_ids as PackedStringArray).size()
	var stock := PackedInt64Array()
	stock.resize(goods * CELL_COUNT)
	stock.fill(100000000)
	var prices := PackedInt32Array()
	prices.resize(goods * CELL_COUNT)
	var default_prices: PackedInt32Array = catalog.good_default_price
	for cell in range(CELL_COUNT):
		for good in range(default_prices.size()):
			prices[cell * goods + good] = int(default_prices[good])
	var boot: Dictionary = ext.bootstrap_economy({
		"cell_indices": PackedInt32Array([FIRST_SETTLED_CELL,
			TARGET_CELL, TARGET_CELL, TARGET_CELL]),
		"signature_ids": PackedInt32Array([merchant_sig, farmer_sig,
			industrial_sig, cooperative_sig]),
		"population": PackedInt64Array([160, 120, 120, 120]),
		"funds": PackedInt64Array([1000000000000, 1000000000000,
			1000000000000, 1000000000000]),
		"forced_named_cells": PackedInt32Array([FIRST_SETTLED_CELL]),
	}, {
		"stock": stock,
		"price": prices,
		"building_cells": PackedInt32Array([FIRST_SETTLED_CELL]),
		"building_type_ids": PackedInt32Array([merchant_post]),
		"building_owner_signature_ids": PackedInt32Array([merchant_sig]),
		"building_counts": PackedInt64Array([1]),
	})
	if not _require("paged economy bootstraps", bool(boot.get("ok", false)),
			str(boot)):
		return null
	return ext



func _find_employed_profession(catalog: Dictionary,
		professions: PackedInt32Array, owner_employed: PackedInt64Array,
		employee_employed: PackedInt64Array, profession_id: String) -> int:
	var wanted := (catalog.profession_ids as PackedStringArray).find(
		profession_id)
	for index in range(professions.size()):
		if int(professions[index]) != wanted:
			continue
		if int(owner_employed[index]) + int(employee_employed[index]) > 0:
			return index
	return -1


func _signature_for_profession(catalog: Dictionary, profession: String) -> int:
	var profession_id := (catalog.profession_ids as PackedStringArray).find(
		profession)
	if profession_id < 0:
		return -1
	var signatures: PackedInt32Array = catalog.signature_profession_ids
	for index in range(signatures.size()):
		if int(signatures[index]) == profession_id:
			return index
	return -1


func _expected_shares(catalog: Dictionary, professions: PackedInt32Array,
		populations: PackedInt64Array) -> Dictionary:
	var profession_ids: PackedStringArray = catalog.profession_ids
	var farmer_ids := {}
	for profession_id in FARMER_PROFESSIONS:
		farmer_ids[profession_ids.find(profession_id)] = true
	var industrial_id := profession_ids.find("industrial_worker")
	var cooperative_id := profession_ids.find("cooperative_member")
	var total := 0
	var farmer := 0
	var industrial := 0
	var cooperative := 0
	for index in range(professions.size()):
		var profession := int(professions[index])
		var people := maxi(0, int(populations[index]))
		if profession < 0 or profession >= profession_ids.size() or people <= 0:
			continue
		total += people
		if farmer_ids.has(profession):
			farmer += people
		if profession == industrial_id:
			industrial += people
		if profession == cooperative_id:
			cooperative += people
	return {"total": total, "farmer": farmer,
		"industrial": industrial, "cooperative": cooperative}


func _share_q16(part: int, total: int) -> int:
	return clampi(part * Q16_ONE / total, 0, Q16_ONE) if total > 0 else 0


func _run_day(ext: Object, day: int) -> Dictionary:
	for slice in range(64):
		var report: Dictionary = ext.run_economy_slice({
			"day_index": day,
			"tick_index": day * 1000 + slice,
		})
		if not bool(report.get("ok", true)) or bool(report.get("fatal", false)):
			_expect("economy day %d slice %d succeeds" % [day, slice], false,
				str(report.get("fatal_reason", report)))
			return report
		if bool(report.get("done", false)):
			return report
	_expect("economy day %d commits" % day, false, "64 slices")
	return {}


func _cohort_count(ext: Object, cell: int) -> int:
	return int(ext.get_population_cell_snapshot(cell, false).get(
		"cohort_count", -1))


func _metric(ext: Object, metric: int, cell: int) -> int:
	var result: Dictionary = ext.sample_effect_metric_probe(metric, cell, 0)
	if not _require("metric %d probe succeeds on cell %d" % [metric, cell],
			bool(result.get("ok", false)), str(result)):
		return -1
	return int(result.get("value", -1))


func _snapshot_country_index(ext: Object) -> int:
	var handles: PackedInt64Array = ext.get_country_class_opinion_snapshot().get(
		"country_handles", PackedInt64Array())
	var summary: Dictionary = ext.get_country_cell_summary(TARGET_CELL)
	var handle := int(summary.get("country_handle", 0))
	return handles.find(handle)


func _fixture_profile() -> Dictionary:
	var profile: Dictionary = load(
		"res://data/economy/default_economy.tres").to_native_profile()
	profile.market_cycle_days = 1
	profile.economy_cadence_force_market_days = 1
	profile.worker_enabled = false
	return profile


func _f32_fill(value: float) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	out.resize(CELL_COUNT)
	out.fill(value)
	return out


func _u8_fill(value: int) -> PackedByteArray:
	var out := PackedByteArray()
	out.resize(CELL_COUNT)
	out.fill(value)
	return out


func _next_sequence() -> int:
	_sequence += 1
	return _sequence


func _expect(label: String, condition: bool, detail: String = "") -> void:
	_checks += 1
	if condition:
		return
	_failures += 1
	printerr("ERROR: [FAIL] %s%s" % [label,
		(" (%s)" % detail) if not detail.is_empty() else ""])


func _require(label: String, condition: bool, detail: String = "") -> bool:
	_expect(label, condition, detail)
	return condition
