extends SceneTree

## A: metric 68 and 69 must follow the paged cohort store, not `cell * page_size`.
##
## The fixture gives cell 5 page 0 by bootstrapping two cohorts there, then moves
## one of them to cell 0 through the normal economy command path. Cell 0 therefore
## lands on page 1: its first slot is 64, not cell 0's id. A stale index-by-cell
## lookup reads page 0 and reports cell 5's cohorts for cell 0.

const CountryCatalogScript = preload("res://scripts/economy/economy_catalog.gd")
const Q16_ONE := 65536
const METRIC_NET_TAX_BURDEN := 68
const METRIC_TREASURY_RESERVE := 69
const CELL_COUNT := 6
const OWNER_CELL := 0
const FIRST_SETTLED_CELL := 5
const COHORT_PAGE_SIZE := 64
const COMMAND_MOVE_POPULATION := 7

var _checks := 0
var _failures := 0
var _sequence := 1


func _init() -> void:
	_run()
	print("ideology metric cohort paging: %d checks, %d failures"
		% [_checks, _failures])
	quit(0 if _failures == 0 else 1)


func _run() -> void:
	if not ClassDB.class_exists("DCWorldExt"):
		_expect("DCWorldExt is available", false)
		return
	var catalog: Dictionary = CountryCatalogScript.compile_native_catalog()
	if not _require("economy catalog compiles", bool(catalog.get("ok", false)),
			str(catalog.get("reason", ""))):
		return
	catalog.erase("ok")
	var ext: Object = _build_ext(catalog)
	if ext == null:
		return
	_expect("cell 0 is cohort-free before the move",
		_cohort_count(ext, OWNER_CELL) == 0)
	_expect("cohort-free cell 0 reads Q16_ONE for metric 68",
		_metric(ext, METRIC_NET_TAX_BURDEN, OWNER_CELL) == Q16_ONE)

	# Cell 5 owns page 0. Moving one of its cohorts to cell 0 makes the store
	# allocate page 1 for cell 0 while cell 5 stays populated on page 0.
	var source: Dictionary = ext.get_population_cell_snapshot(FIRST_SETTLED_CELL, false)
	var source_handles: PackedInt64Array = source.get("handles", PackedInt64Array())
	var source_professions: PackedInt32Array = source.get(
		"profession_ids", PackedInt32Array())
	var merchant_profession := _profession_id(catalog, "merchant")
	var source_index := source_professions.find(merchant_profession)
	if not _require("cell 5 exposes a merchant cohort", source_index >= 0,
			str(source)):
		return
	var moved: Dictionary = ext.submit_economy_commands({
		"opcodes": PackedInt32Array([COMMAND_MOVE_POPULATION]),
		"effective_days": PackedInt64Array([0]),
		"sequences": PackedInt64Array([_next_sequence()]),
		"target_handles": PackedInt64Array([source_handles[source_index]]),
		"i32_0": PackedInt32Array([OWNER_CELL]),
		"i32_1": PackedInt32Array([0]),
		"i64_0": PackedInt64Array([1]),
		"i64_1": PackedInt64Array([0]),
	})
	if not _require("the move command is accepted", bool(moved.get("ok", false)),
			str(moved)):
		return
	var remaining: Dictionary = ext.get_population_cell_snapshot(
		FIRST_SETTLED_CELL, false)
	var remaining_handles: PackedInt64Array = remaining.get(
		"handles", PackedInt64Array())
	var remaining_professions: PackedInt32Array = remaining.get(
		"profession_ids", PackedInt32Array())
	var landlord_profession := _profession_id(catalog, "landlord")
	var remaining_landlord := remaining_professions.find(landlord_profession)
	if not _require("cell 5 retains its landlord for country B",
			remaining_landlord >= 0, str(remaining)):
		return
	_expect("the landlord receives income while on cell 5",
		_grant_income(ext, remaining_handles[remaining_landlord], 5000000))
	# Country A levies an absolute income tax. It books tax for the moved cohort
	# without depending on household purchases, while country B books none.
	_expect("country A's absolute income tax commits",
		_set_absolute_income_tax(ext, OWNER_CELL, 1))
	_expect("country B's zero income tax commits",
		_set_absolute_income_tax(ext, FIRST_SETTLED_CELL, 0))
	var day_zero: Dictionary = _run_day(ext, 0)
	if not _require("day 0 reaches a commit", bool(day_zero.get("done", false)),
			str(day_zero)):
		return
	_expect("the moved cohort lands on cell 0", _cohort_count(ext, OWNER_CELL) > 0,
		str(ext.get_population_cell_snapshot(OWNER_CELL, false)))
	_expect("cell 5 remains populated after the move",
		_cohort_count(ext, FIRST_SETTLED_CELL) > 0,
		str(ext.get_population_cell_snapshot(FIRST_SETTLED_CELL, false)))
	var owner_population_snapshot: Dictionary = ext.get_population_cell_snapshot(
		OWNER_CELL, false)
	var owner_populations: PackedInt64Array = owner_population_snapshot.get(
		"populations", PackedInt64Array())
	_expect("the moved cohort still holds its landlord population",
		not owner_populations.is_empty() and owner_populations[0] > 0,
		str(owner_population_snapshot))

	# The moved merchant creates cell 0's page after cell 5 already owns page 0.
	# The page guard matters: if the allocator ever hands cell 0 its old page id,
	# this no longer tests paging.
	var owner_snapshot: Dictionary = ext.get_population_cell_snapshot(
		OWNER_CELL, false)
	var owner_handles: PackedInt64Array = owner_snapshot.get(
		"handles", PackedInt64Array())
	var owner_page := -1
	for handle in owner_handles:
		var page := int(handle) / COHORT_PAGE_SIZE
		if owner_page < 0 or page < owner_page:
			owner_page = page
	_expect("cell 0's first page is not page 0", owner_page != 0,
		"page=%d" % owner_page)

	var owner_tax := _metric(ext, METRIC_NET_TAX_BURDEN, OWNER_CELL)
	var other_tax := _metric(ext, METRIC_NET_TAX_BURDEN, FIRST_SETTLED_CELL)
	_expect("metric 68 reads cell 0's tax-paying cohort, not cell 5's page",
		owner_tax > 0 and other_tax == 0,
		"owner=%d other=%d" % [owner_tax, other_tax])
	# Day 0 updates the landlord's daily income EMA. Day 1's epoch capture freezes
	# metric 69 from that EMA and attributes it through `_epoch_cell_country`.
	var day_one: Dictionary = _run_day(ext, 1)
	if not _require("day 1 reaches its next commit",
			bool(day_one.get("done", false)), str(day_one)):
		return
	var owner_reserve := _metric(ext, METRIC_TREASURY_RESERVE, OWNER_CELL)
	var other_reserve := _metric(ext, METRIC_TREASURY_RESERVE, FIRST_SETTLED_CELL)
	_expect("metric 69 leaves country A without cell 5's income",
		owner_reserve == 0,
		"owner=%d other=%d" % [owner_reserve, other_reserve])
	_expect("metric 69 attributes cell 5 income to country B",
		other_reserve > 0,
		"owner=%d other=%d" % [owner_reserve, other_reserve])


func _build_ext(catalog: Dictionary) -> Object:
	var ext: Object = ClassDB.instantiate("DCWorldExt")
	ext.create_entities(CELL_COUNT)
	for slot_name in [&"cell_temp", &"cell_temp_30d", &"cell_moisture",
			&"cell_plant_available_water", &"cell_weather_precip",
			&"cell_snow_cover", &"cell_weather_intensity", &"cell_elevation", &"cell_temp_365d"]:
		var sid: int = ext.register_component(slot_name, 0, 1, false)
		ext.write_f32_range(sid, 0, _f32_fill(0.5))
	for slot_name in [&"cell_terrain", &"cell_landform", &"cell_vegetation",
			&"cell_is_water", &"cell_has_river", &"cell_weather_type", &"cell_cover"]:
		var sid: int = ext.register_component(slot_name, 2, 1, false)
		ext.write_u8_range(sid, 0, _u8_fill(0))
	for i in range((catalog.building_resource_ids as PackedStringArray).size()):
		var reserve_sid: int = ext.register_component(StringName(
			(catalog.building_resource_reserve_slots as PackedStringArray)[i]), 0, 1, false)
		var extra_sid: int = ext.register_component(StringName(
			(catalog.building_resource_extra_slots as PackedStringArray)[i]), 0, 1, false)
		ext.write_f32_range(reserve_sid, 0, _f32_fill(1000000.0))
		ext.write_f32_range(extra_sid, 0, _f32_fill(0.0))
	if not _require("country configures", bool(ext.configure_country(catalog, {
			"country_runtime_mode": "ACTIVE",
			"starting_technology_ids": PackedStringArray(["tech.hunting"]),
		}, CELL_COUNT, 97).get("ok", false))):
		return null
	var territory := PackedInt32Array([OWNER_CELL, FIRST_SETTLED_CELL])
	var country_outcome: Dictionary = ext.bootstrap_country({
		"country_ids": PackedStringArray(["country.paging_a", "country.paging_b"]),
		"country_names": PackedStringArray(["Paging A", "Paging B"]),
			"country_cash": PackedInt64Array([1000000000, 2000000000]),
		"territory_offsets": PackedInt32Array([0, 1, 2]),
		"territory_cells": territory,
		"technology_offsets": PackedInt32Array([0, 0, 0]),
		"technology_indices": PackedInt32Array(),
		"treasury_offsets": PackedInt32Array([0, 0, 0]),
		"treasury_good_indices": PackedInt32Array(),
		"treasury_quantities": PackedInt64Array(),
	}, _u8_fill(0))
	if not _require("two countries bootstrap", bool(country_outcome.get("ok", false)),
			str(country_outcome)):
		return null
	var economy: Dictionary = ext.configure_economy(catalog,
		_fixture_profile(),
		CELL_COUNT, 97)
	if not _require("economy configures", bool(economy.get("ok", false)), str(economy)):
		return null
	var owner_sig := (catalog.signature_keys as PackedStringArray).find("forager|default")
	var merchant_sig := (catalog.signature_keys as PackedStringArray).find("merchant|default")
	if not _require("fixture finds its cohort signatures",
			owner_sig >= 0 and merchant_sig >= 0):
		return null
	var stock := PackedInt64Array()
	stock.resize((catalog.good_ids as PackedStringArray).size() * CELL_COUNT)
	stock.fill(100000000)
	var prices := PackedInt32Array()
	prices.resize((catalog.good_ids as PackedStringArray).size() * CELL_COUNT)
	var good_count := (catalog.good_ids as PackedStringArray).size()
	var default_prices: PackedInt32Array = catalog.good_default_price
	for cell in range(CELL_COUNT):
		for good in range(default_prices.size()):
			prices[cell * good_count + good] = int(default_prices[good])
	# Two cohorts on cell 5 occupy page 0. Cell 0 is intentionally empty here;
	# the command below is the only thing that creates its later page.
	var landlord_sig := (catalog.signature_keys as PackedStringArray).find(
		"landlord|default")
	if not _require("fixture finds the landlord signature", landlord_sig >= 0):
		return null
	var boot: Dictionary = ext.bootstrap_economy({
		"cell_indices": PackedInt32Array([FIRST_SETTLED_CELL, FIRST_SETTLED_CELL]),
		"signature_ids": PackedInt32Array([landlord_sig, merchant_sig]),
		"population": PackedInt64Array([10, 1]),
		"funds": PackedInt64Array([1000000000000, 1000000000000]),
		"forced_named_cells": PackedInt32Array([FIRST_SETTLED_CELL]),
	}, {"stock": stock, "price": prices})
	if not _require("paged economy bootstraps", bool(boot.get("ok", false)), str(boot)):
		return null
	return ext


func _cohort_count(ext: Object, cell: int) -> int:
	return int(ext.get_population_cell_snapshot(cell, false).get("cohort_count", -1))


func _fixture_profile() -> Dictionary:
	var profile: Dictionary = load(
		"res://data/economy/default_economy.tres").to_native_profile()
	profile.market_cycle_days = 1
	profile.economy_cadence_force_market_days = 1
	profile.worker_enabled = false
	return profile


func _metric(ext: Object, metric: int, cell: int) -> int:
	var result: Dictionary = ext.sample_effect_metric_probe(metric, cell, 0)
	if not _require("metric %d probe succeeds on cell %d" % [metric, cell],
			bool(result.get("ok", false)), str(result)):
		return -1
	return int(result.get("value", -1))


func _grant_income(ext: Object, cohort_handle: int, amount: int) -> bool:
	var result: Dictionary = ext.submit_economy_commands({
		"opcodes": PackedInt32Array([2]),
		"effective_days": PackedInt64Array([0]),
		"sequences": PackedInt64Array([_next_sequence()]),
		"target_handles": PackedInt64Array([cohort_handle]),
		"i32_0": PackedInt32Array([0]),
		"i32_1": PackedInt32Array([0]),
		"i64_0": PackedInt64Array([amount]),
		"i64_1": PackedInt64Array([0]),
	})
	return bool(result.get("ok", false))


func _set_absolute_income_tax(ext: Object, cell: int, amount: int) -> bool:
	var country_handle := int(ext.get_country_cell_summary(cell).get(
		"country_handle", 0))
	if country_handle == 0:
		return false
	var submitted: Dictionary = ext.submit_country_commands({
		"opcodes": PackedInt32Array([11]),
		"effective_days": PackedInt64Array([0]),
		"sequences": PackedInt64Array([_next_sequence()]),
		"target_handles": PackedInt64Array([country_handle]),
		"cell_indices": PackedInt32Array([-1]),
		"aux_i32": PackedInt32Array([-1]),
		"domain_i32": PackedInt32Array([-1]),
		"position_i32": PackedInt32Array([-1]),
		"weight0_bp": PackedInt32Array([0]),
		"weight1_bp": PackedInt32Array([0]),
		"weight2_bp": PackedInt32Array([0]),
		"weight3_bp": PackedInt32Array([0]),
		"value_i64": PackedInt64Array([0]),
		"tax_kinds": PackedInt32Array([0]),
		"tax_item_indices": PackedInt32Array([-1]),
		"tax_rate_basis_points": PackedInt32Array([amount]),
		"tax_assessment_modes": PackedInt32Array([1]),
		"stable_ids": PackedStringArray([""]),
		"display_names": PackedStringArray([""]),
	})
	if not bool(submitted.get("ok", false)):
		return false
	return bool(ext.run_country_slice({"day_index": 0}).get("ok", false))


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


func _profession_id(catalog: Dictionary, profession: String) -> int:
	return (catalog.profession_ids as PackedStringArray).find(profession)


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
