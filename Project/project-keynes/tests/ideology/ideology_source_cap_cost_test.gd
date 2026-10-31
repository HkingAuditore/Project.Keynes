extends SceneTree
## What does removing the source cap COST, measured at the collector?
##
## WHY THIS SHAPE
##
## Measuring it through a kind-14 card failed twice (M5-34, M5-40): the card path needs a
## tag to match, and the fixture kept failing somewhere between equip and POD resolution.
##
## But the cost of the uncap is not in the card machinery -- it is in
## `collect_effect_target_cells(anchor, OWN_TERRITORY, cap, tag, sources, ...)`, the call
## that builds the SOURCE set. That call is reachable directly through the
## `probe_fan_out_ownership` bridge added in M5-6, so the measurement does not need a card
## at all:
##
##   * `param0 = 32` reproduces the OLD behaviour (32 sources),
##   * `param0 = 0` is the NEW behaviour (the whole territory).
##
## `param1 = 0` means "no tag filter", which is the larger of the two cases and therefore
## the right one for a cost bound.
##
## WHAT IT REPORTS
##
## Source count and collection time for both caps, plus the implied ring-walk multiplier
## (one ring walk happens per source). The time is REPORTED, not asserted: a wall-clock
## threshold here would be a machine-speed claim rather than a correctness one.
##
## Run:
##   <godot> --headless --path Project/project-keynes \
##     -s tests/ideology/ideology_source_cap_cost_test.gd
##
## The grid is 6400 cells so the number lines up with the largest fixture the rest of the
## plan uses; the 1600-cell result is recorded in M5-41.

const WIDTH := 80
const HEIGHT := 80
const CELLS: int = WIDTH * HEIGHT
const Q16_ONE := 65536
const SELECTOR_OWN_TERRITORY := 12
## Enough repetitions that a single scheduler hiccup cannot decide the number.
const REPEATS := 5

const CountryCatalogScript = preload("res://scripts/economy/economy_catalog.gd")
const EconomyCatalogScript = preload("res://scripts/economy/economy_catalog.gd")
const IdeologyCatalogScript = preload("res://scripts/ideology/ideology_catalog.gd")
const EffectDomainCatalogScript = preload("res://scripts/effect/effect_domain_catalog.gd")
const ModifierCatalogScript = preload("res://scripts/modifier/modifier_catalog.gd")
const IdeologyEffectCatalogScript = preload(
	"res://scripts/ideology/ideology_effect_catalog.gd")

class MapStub extends RefCounted:
	var _packed := PackedInt32Array()

	func _init(cells: int) -> void:
		_packed.resize(cells * 6)
		_packed.fill(-1)
		for cell in range(cells):
			if cell + 1 < cells:
				_packed[cell * 6] = cell + 1
			if cell - 1 >= 0:
				_packed[cell * 6 + 1] = cell - 1

	func neighbor_indices_packed() -> PackedInt32Array:
		return _packed

	func economy_trade_passable_lut() -> PackedByteArray:
		var out := PackedByteArray()
		out.resize(_packed.size() / 6)
		out.fill(1)
		return out

	func economy_trade_move_cost_lut() -> PackedInt32Array:
		var out := PackedInt32Array()
		out.resize(_packed.size() / 6)
		out.fill(1)
		return out


var _checks := 0
var _failures := 0
var _seq := 0


func _init() -> void:
	_run()


func _expect(label: String, ok: bool, detail: String = "") -> void:
	_checks += 1
	if ok:
		return
	_failures += 1
	printerr("FAIL %s %s" % [label, detail])


func _median(values: Array) -> float:
	var sorted := values.duplicate()
	sorted.sort()
	if sorted.is_empty():
		return 0.0
	return float(sorted[sorted.size() / 2])


func _run() -> void:
	var country_ir: Dictionary = CountryCatalogScript.compile_native_catalog()
	country_ir.erase("ok")
	var econ_catalog: Dictionary = EconomyCatalogScript.compile_native_catalog()
	var profile: Dictionary = load(
		"res://data/economy/default_economy.tres").to_native_profile()
	profile["market_cycle_days"] = 1
	profile["market_runtime_mode"] = "ACTIVE"
	var domain: Resource = EffectDomainCatalogScript.build(
		null, IdeologyEffectCatalogScript.load_default())
	var effect_ir: Dictionary = domain.compile_native_catalog()
	effect_ir.erase("ok")
	var mod_ir: Dictionary = ModifierCatalogScript.load_default().compile_native_catalog()
	mod_ir.erase("ok")
	var native_ideology: Dictionary = IdeologyCatalogScript.load_default() \
		.compile_native_catalog(country_ir, country_ir)
	native_ideology.erase("ok")

	var ext: Object = ClassDB.instantiate("DCWorldExt")
	ext.create_entities(CELLS)
	_fill_environment(ext)
	if not bool(ext.configure_economy(country_ir, profile, CELLS, 101).get("ok", false)):
		_expect("economy configures", false)
		_finish(1)
		return
	ext.configure_effects(effect_ir)
	ext.configure_modifiers(mod_ir, CELLS)
	ext.configure_country(country_ir, {
		"country_runtime_mode": "ACTIVE",
		"starting_technology_ids": PackedStringArray(["tech.hunting"]),
	}, CELLS, 101)
	var territory := PackedInt32Array()
	for c in range(CELLS):
		territory.append(c)
	ext.bootstrap_country({
		"country_ids": PackedStringArray(["country.cost"]),
		"country_names": PackedStringArray(["Cost"]),
		"country_cash": PackedInt64Array([0]),
		"territory_offsets": PackedInt32Array([0, CELLS]),
		"territory_cells": territory,
		"technology_offsets": PackedInt32Array([0, 0]),
		"technology_indices": PackedInt32Array(),
		"treasury_offsets": PackedInt32Array([0, 0]),
		"treasury_good_indices": PackedInt32Array(),
		"treasury_quantities": PackedInt64Array(),
	}, _u8_zero(CELLS))
	# `dilate_cell_set` returns nothing without a neighbour table, and the table is
	# captured from MapData when the epoch opens.
	ext.bind_map_data(MapStub.new(CELLS))
	ext.configure_ideologies(native_ideology)
	ext.begin_or_reuse_economy_input_epoch(0, _epoch(1, 0))
	var sig_keys: PackedStringArray = econ_catalog.get("signature_keys", PackedStringArray())
	var farmer: int = sig_keys.find("subsistence_farmer|default")
	var goods: int = (econ_catalog.get("good_ids", PackedStringArray())).size()
	if farmer >= 0:
		var stock := PackedInt64Array()
		stock.resize(CELLS * goods)
		stock.fill(0)
		var ci := PackedInt32Array()
		var si := PackedInt32Array()
		var pp := PackedInt64Array()
		var ff := PackedInt64Array()
		for c in range(CELLS):
			ci.append(c)
			si.append(farmer)
			pp.append(30)
			ff.append(10000000)
		ext.bootstrap_economy({
			"cell_indices": ci, "signature_ids": si, "population": pp, "funds": ff,
		}, {
			"stock": stock,
			"building_cells": PackedInt32Array(),
			"building_type_ids": PackedInt32Array(),
			"building_owner_signatures": PackedInt32Array(),
			"building_counts": PackedInt64Array(),
		})
		for s in range(512):
			if bool(ext.run_economy_slice({"day_index": 0, "tick_index": s}).get("done", false)):
				break

	var handle := int(ext.get_country_cell_summary(0).get("country_handle", 0))
	_expect("the country resolves", handle != 0, str(handle))
	if handle == 0:
		_finish(1)
		return

	# WARM UP: the first call pays page faults and branch-cache misses. Measuring without
	# a warm-up is how earlier rounds produced spreads above 2x.
	ext.probe_fan_out_ownership(handle, 0, SELECTOR_OWN_TERRITORY, 32, 0)
	ext.probe_fan_out_ownership(handle, 0, SELECTOR_OWN_TERRITORY, 0, 0)

	var capped := _sample(ext, handle, 32)
	var uncapped := _sample(ext, handle, 0)

	print("[cost] territory=%d cells, %d repeats, median" % [CELLS, REPEATS])
	print("[cost] cap=32 : sources=%-6d collect_ms=%.4f"
		% [int(capped["count"]), float(capped["ms"])])
	print("[cost] no cap : sources=%-6d collect_ms=%.4f"
		% [int(uncapped["count"]), float(uncapped["ms"])])
	var ratio := 0.0
	if float(capped["ms"]) > 0.0:
		ratio = float(uncapped["ms"]) / float(capped["ms"])
	print("[cost] time ratio = %.2fx   source ratio = %.1fx"
		% [ratio, float(uncapped["count"]) / float(max(1, int(capped["count"])))])
	print("[cost] ring walks per resolve: %d -> %d (one per source)"
		% [int(capped["count"]), int(uncapped["count"])])

	# The BATCH dilation is NOT measured here. This fixture's MapData stub leaves
	# `_building_neighbors` sized but every entry -1 (`valid_neighbors: 0`), so a dilation
	# legitimately produces nothing. Its correctness AND its timing are pinned in
	# `economy_runtime_effect_selector_tests.cpp`, which owns a real hex neighbour table:
	#
	#   [dilate] 30 sources on a 30-cell grid: per-source loop 6.64 us, batch 0.47 us (14.10x)
	#   dilate_matches_per_source_union -- PASS
	#
	# Keeping a measurement here that cannot run would be worse than not having it.

	# ── B6: class-opinion read at 6400 cells ──────────────────────────────
	#
	# The plan asks whether the EXISTING class-opinion read still works at 6400 cells or
	# silently degrades. Print the whole payload first: the field names are the evidence.
	var opinion: Dictionary = ext.get_country_class_opinion_snapshot()
	print("[cost] B6 class_opinion keys=%s" % str(opinion.keys()))
	print("[cost] B6 class_opinion=%s" % str(opinion))
	_expect("B6: the class-opinion read returns ok at 6400 cells",
		bool(opinion.get("ok", false)), str(opinion.get("reason", "")))
	# `cells_scanned` and the population total are what distinguish "this ran over every
	# cell" from "it returned a plausible-looking degraded snapshot". 6400 cells x 30
	# bootstrapped population = 192000, so a partial scan cannot accidentally match.
	var scanned := int(opinion.get("cells_scanned", -1))
	var zero_rows := int(opinion.get("zero_population_rows", -1))
	var pops: Array = opinion.get("population", [])
	var pop_total := 0
	for v in pops:
		pop_total += int(v)
	print("[cost] B6 scanned=%d zero_rows=%d pop_total=%d (expected %d)"
		% [scanned, zero_rows, pop_total, CELLS * 30])
	_expect("B6: the read scanned every cell, not a subset", scanned == CELLS,
		"%d vs %d" % [scanned, CELLS])
	_expect("B6: the population total matches what was bootstrapped",
		pop_total == CELLS * 30, "%d vs %d" % [pop_total, CELLS * 30])

	# 1. The cap must still be respected when explicitly authored.
	_expect("an authored cap of 32 still yields 32 sources",
		int(capped["count"]) == 32, str(capped["count"]))
	# 2. And with no cap the whole territory is used -- that is the change.
	_expect("no cap yields the whole territory as sources",
		int(uncapped["count"]) == CELLS, str(uncapped["count"]))
	# 3. The reported cost must be finite and the uncapped path must not be absurd.
	_expect("the uncapped collection stays under 10 ms for %d cells" % CELLS,
		float(uncapped["ms"]) < 10.0, "%.4f ms" % float(uncapped["ms"]))
	# 4. Reported, not asserted: the multiplier the ring walk now pays.
	print("[cost] RESULT sources_x%.1f  collect_ms %.4f -> %.4f  (%.2fx)"
		% [float(uncapped["count"]) / float(max(1, int(capped["count"]))),
			float(capped["ms"]), float(uncapped["ms"]), ratio])

	_finish(0 if _failures == 0 else 3)


func _sample_dilated(ext: Object, handle: int) -> Dictionary:
	var times: Array = []
	var count := 0
	for _i in range(REPEATS):
		var started := Time.get_ticks_usec()
		var out: Dictionary = ext.probe_fan_out_ownership(
			handle, 0, SELECTOR_OWN_TERRITORY, 0, 0, 1)
		times.append(float(Time.get_ticks_usec() - started) / 1000.0)
		count = int(out.get("dilated_count", 0))
		if _i == 0:
			print("[cost] dilation probe: %s" % str(out.get("building_context", "?")))
	return {"count": count, "ms": _median(times)}


func _sample(ext: Object, handle: int, param0: int) -> Dictionary:
	var times: Array = []
	var count := 0
	for _i in range(REPEATS):
		var started := Time.get_ticks_usec()
		var out: Dictionary = ext.probe_fan_out_ownership(
			handle, 0, SELECTOR_OWN_TERRITORY, param0, 0)
		times.append(float(Time.get_ticks_usec() - started) / 1000.0)
		count = int(out.get("raw_count", 0))
	return {"count": count, "ms": _median(times)}


func _epoch(epoch: int, sample_day: int) -> Dictionary:
	return {
		"sample_day": sample_day, "epoch_id": epoch, "map_generation": 1,
		"building_generation": 1, "country_generation": 1, "resource_generation": 1}


func _fill_environment(ext: Object) -> void:
	var f32_slots := ["cell_temp", "cell_temp_30d", "cell_moisture",
		"cell_plant_available_water", "cell_weather_precip", "cell_snow_cover",
		"cell_weather_intensity", "cell_temp_365d"]
	# The building-context capture reads these per-cell columns; without them
	# `capture_building_context` gets nullptrs and the neighbour table stays empty
	# (`valid_neighbors: 0`), which is why `dilate_cell_set` used to return nothing.
	var u8_slots := ["cell_weather_type", "cell_cover", "cell_terrain", "cell_landform",
		"cell_vegetation", "cell_is_water", "cell_has_river"]
	var f32_extra := ["cell_elevation"]
	var zf := PackedFloat32Array()
	zf.resize(CELLS)
	var zu := PackedByteArray()
	zu.resize(CELLS)
	for n in f32_slots:
		var sid := int(ext.component_id(n))
		if sid < 0:
			sid = int(ext.register_component(n, 0, 1, false))
		if sid >= 0:
			ext.write_f32_range(sid, 0, zf)
	for n in f32_extra:
		var sid := int(ext.component_id(n))
		if sid < 0:
			sid = int(ext.register_component(n, 0, 1, false))
		if sid >= 0:
			ext.write_f32_range(sid, 0, zf)
	for n in u8_slots:
		var sid := int(ext.component_id(n))
		if sid < 0:
			sid = int(ext.register_component(n, 2, 1, false))
		if sid >= 0:
			ext.write_u8_range(sid, 0, zu)


func _u8_zero(n: int) -> PackedByteArray:
	var out := PackedByteArray()
	out.resize(n)
	return out


func _finish(code: int) -> void:
	print("=== source cap cost: %d checks, %d failures ===" % [_checks, _failures])
	quit(code)
