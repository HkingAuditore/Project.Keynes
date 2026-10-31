extends SceneTree
## Slice-budget probe (plan 22 §14.3 "main-thread derived native slice <= 1 ms").
##
## M1-5's micro-benchmark produced per-covered-cell constants, but a constant is
## not a budget: the question is whether the READER can stay inside one slice.
## Reading the source answers it structurally -- `refresh_city_modifier_factors`
## returns `void` and runs to completion inside `capture_country_epoch`
## (`economy_runtime.cpp:5530`), which runs inside `start_epoch`
## (`economy_runtime.cpp:15211`), i.e. inside ONE `run_economy_slice` call. There
## is no resume cursor anywhere on that path.
##
## So this fixture measures the thing the plan's gate actually names: how many
## milliseconds does one epoch-open slice spend in the two city-factor readers,
## with a realistic derived coverage?
##
## It cannot reach the derived layer's own cost (that needs the production
## installer, still unwired), so what it measures is the LEGACY baseline. That is
## still the right denominator: the derived cost lands on top of it inside the
## same indivisible slice, and if the baseline alone is already near 1 ms there is
## no room at all.
##
## Run:
##   <godot> --headless --path Project/project-keynes \
##     -s tests/ideology/ideology_cell_layer_slice_budget_test.gd

const ModifierCatalogScript = preload("res://scripts/modifier/modifier_catalog.gd")
const CountryCatalogScript = preload("res://scripts/economy/economy_catalog.gd")

## Plan §14.3: main-thread single derived native slice target.
const SLICE_BUDGET_MS := 1.0

var _checks := 0
var _failures := 0
var _country_ir: Dictionary = {}


func _init() -> void:
	_run()


func _expect(label: String, ok: bool, detail: String = "") -> void:
	_checks += 1
	if ok:
		return
	_failures += 1
	printerr("FAIL %s %s" % [label, detail])


func _run() -> void:
	_country_ir = CountryCatalogScript.compile_native_catalog()
	if not bool(_country_ir.get("ok", false)):
		_expect("country catalog compiles", false, str(_country_ir))
		_finish(1)
		return
	_country_ir.erase("ok")

	# Map sizes spanning the plan's scenarios: 2400 is the production default,
	# 6400 is the "single country whole territory" upper bound from §14.2 B7.
	for map_cells in [2400, 6400]:
		var samples := _sample(map_cells)
		if samples.is_empty():
			_expect("map %d produced samples" % map_cells, false)
			continue
		var sorted := samples.duplicate()
		sorted.sort()
		var p50: float = sorted[sorted.size() / 2]
		var worst: float = sorted[-1]
		print("[slice-budget] map=%d n=%d p50=%.3f max=%.3f ms  raw=%s"
			% [map_cells, sorted.size(), p50, worst, str(samples)])

		_expect("map %d: epoch-open city-factor cost measured" % map_cells,
			p50 >= 0.0, str(p50))

		# The gate is on the WHOLE slice, and the city-factor readers are only one
		# part of `capture_country_epoch`. So the assertion is deliberately
		# one-sided: when the baseline alone already exceeds the budget, the
		# derived layer has no room and the plan's sharding requirement is proven
		# necessary rather than assumed.
		if p50 > SLICE_BUDGET_MS:
			print("[slice-budget] map=%d: baseline %.3f ms ALREADY exceeds the "
				% [map_cells, p50] + "%.1f ms slice budget",
				SLICE_BUDGET_MS)
			print("[slice-budget] => the derived layer cannot fit without sharding "
				+ "this reader; §15.3's 'sharded materialise' is mandatory, not optional.")
		else:
			# Headroom left for derived work inside the same slice.
			var headroom := SLICE_BUDGET_MS - p50
			print("[slice-budget] map=%d: baseline %.3f ms leaves %.3f ms headroom"
				% [map_cells, p50, headroom])
			# M1-5 measured 6.0 us per covered cell at B7 scale.
			var cells_that_fit := headroom * 1000.0 / 6.0
			print("[slice-budget] at 6.0 us/covered-cell that is ~%.0f cells per slice"
				% cells_that_fit)

	_finish(0 if _failures == 0 else 3)


func _sample(map_cells: int) -> Array:
	var samples: Array = []
	for rep in range(3):
		var ext: Object = ClassDB.instantiate("DCWorldExt")
		if ext == null:
			return samples
		var catalog: Dictionary = ModifierCatalogScript.load_default().compile_native_catalog()
		if not bool(catalog.get("ok", false)):
			return samples
		catalog.erase("ok")
		if not bool(ext.configure_modifiers(catalog, map_cells).get("ok", false)):
			return samples
		var profile: Dictionary = load("res://data/economy/default_economy.tres").to_native_profile()
		if not bool(ext.configure_economy(
				_country_ir, profile, map_cells, 20261027).get("ok", false)):
			return samples
		if not _bootstrap(ext, map_cells):
			return samples

		# One economy day: the first slice for a fresh day reaches start_epoch ->
		# capture_country_epoch -> both city-factor readers.
		var result: Dictionary = ext.run_economy_slice(
			{"day_index": 0, "tick_index": 0})
		var guard := 0
		while not bool(result.get("done", false)) and guard < 64:
			guard += 1
			result = ext.run_economy_slice({"day_index": 0, "tick_index": guard})
		var report: Dictionary = ext.get_economy_report()
		if bool(report.get("fatal", false)):
			print("[slice-budget] map=%d rep=%d: economy went fatal, skipping"
				% [map_cells, rep])
			continue
		samples.append(float(report.get("epoch_begin_city_factor_ms", -1.0)))
	return samples


func _bootstrap(ext: Object, map_cells: int) -> bool:
	var building_id := (_country_ir.building_type_ids as PackedStringArray).find(
		"gathering_ground")
	var owner_sig := (_country_ir.signature_keys as PackedStringArray).find(
		"forager|default")
	if building_id < 0 or owner_sig < 0:
		return false
	var goods: int = (_country_ir.good_ids as PackedStringArray).size()
	var stock := PackedInt64Array()
	stock.resize(goods * map_cells)
	stock.fill(100000000)
	var prices := PackedInt32Array()
	prices.resize(goods * map_cells)
	prices.fill(1000)
	var cells := PackedInt32Array()
	var sigs := PackedInt32Array()
	var pops := PackedInt64Array()
	var funds := PackedInt64Array()
	var buildings := PackedInt32Array()
	var owners := PackedInt32Array()
	var counts := PackedInt64Array()
	for cell in range(map_cells):
		cells.append(cell)
		sigs.append(owner_sig)
		pops.append(1000)
		funds.append(1000000000000000)
		buildings.append(building_id)
		owners.append(owner_sig)
		counts.append(1)
	var result: Dictionary = ext.bootstrap_economy({
		"cell_indices": cells, "signature_ids": sigs, "population": pops,
		"funds": funds, "forced_named_cells": cells, "founder_family_cells": cells,
		"founder_family_building_type_ids": buildings,
		"founder_family_owner_signature_ids": owners,
	}, {
		"stock": stock, "price": prices, "building_cells": cells,
		"building_type_ids": buildings,
		"building_owner_signature_ids": owners, "building_counts": counts,
	})
	return bool(result.get("ok", false))


func _finish(code: int) -> void:
	print("=== cell layer slice budget: %d checks, %d failures ==="
		% [_checks, _failures])
	quit(code)
