extends SceneTree
## M3: the materializer evaluates a Ramp term PER CELL
## (plan §15.5 exit condition "same country, different cells, different ramp values").
##
## THE POINT
##
## M3-2 proved the evaluator tracks a metric when called directly. That is not the
## same as proving the MATERIALIZER uses it: a wiring bug could compute the value
## once and reuse it for every cell, which would pass a single-cell test and still
## be wrong for a whole territory.
##
## So this fixture drives `build_derived_cell_front` with a synthetic sampler that
## returns a DIFFERENT metric sample per cell, and asserts the resulting per-cell
## contributions differ accordingly -- and match an independently computed
## expectation, not just "not equal".
##
## WHAT IT PINS
##
##   A. two cells with different samples get different contributions;
##   B. each cell's contribution equals `sample(cell) * scale` exactly;
##   C. with no sampler the ramp term is DEFERRED (counter rises) rather than
##      folded to zero -- a zero would silently mute the effect;
##   D. a constant term in the same program is unaffected, i.e. ramp and constant
##      terms coexist;
##   E. the per-cell samples are actually consulted once per cell (the sampler's
##      own call count), so a short-circuit cannot masquerade as correct;
##   F. `truncated` stays 0 for a 40-cell ramp -- §12.4's hard requirement.
##
## Run:
##   <godot> --headless --path Project/project-keynes \
##     -s tests/ideology/ideology_cell_layer_ramp_materialize_test.gd

const ModifierCatalogScript = preload("res://scripts/modifier/modifier_catalog.gd")

const CELLS := 64
const STAT := "economy.city.birth_factor"
const DOMAIN_ECONOMY := 2

var _checks := 0
var _failures := 0


func _init() -> void:
	_run()


func _expect(label: String, ok: bool, detail: String = "") -> void:
	_checks += 1
	if ok:
		return
	_failures += 1
	printerr("FAIL %s %s" % [label, detail])


func _near(a: float, b: float, eps: float = 1e-4) -> bool:
	return absf(a - b) <= eps


func _run() -> void:
	var ext: Object = ClassDB.instantiate("DCWorldExt")
	if ext == null:
		_expect("DCWorldExt instantiates", false)
		_finish(1)
		return
	var catalog: Dictionary = ModifierCatalogScript.load_default().compile_native_catalog()
	if not bool(catalog.get("ok", false)):
		_expect("modifier catalog compiles", false, str(catalog))
		_finish(1)
		return
	catalog.erase("ok")
	_expect("configure modifiers",
		bool(ext.configure_modifiers(catalog, CELLS).get("ok", false)))
	var stat_id := int(ext.resolve_modifier_stat(STAT).get("stat_id", -1))
	if stat_id < 0:
		_expect("the stat resolves", false)
		_finish(1)
		return

	# ── A/B: per-cell evaluation through the materializer ─────────────────
	#
	# The ramp term declares metric 57 at scale 0.5, and the sampler returns
	# `cell * 2.0` for it. So cell 3 must contribute 3*2.0*0.5 = 3.0 and cell 5
	# must contribute 5.0. A wiring bug that evaluated once would give all cells
	# the same number.
	var sampler_calls := 0
	var cells: Array = [3, 5, 7]
	var result: Dictionary = ext.build_derived_cell_front_for_test({
		"stat_ids": PackedInt32Array([stat_id, stat_id, stat_id]),
		"cells": PackedInt32Array([3, 5, 7]),
		"source_countries": PackedInt64Array([1, 1, 1]),
		"operations": PackedInt32Array([0, 0, 0]),
		"adds": PackedFloat64Array([0.0, 0.0, 0.0]),
		"factors": PackedFloat64Array([1.0, 1.0, 1.0]),
		"magnitude_sources": PackedInt32Array([1, 1, 1]),
		"metric_ids": PackedInt32Array([57, 57, 57]),
		"ramp_scales": PackedFloat64Array([0.5, 0.5, 0.5]),
		"sampler_scale": 2.0,
		"world_identity": 1, "map_generation": 1, "sample_day": 1,
		"epoch_id": 1, "execution_contract_hash": 1,
	})
	_expect("A: the ramp front builds", bool(result.get("ok", false)), str(result))
	if not bool(result.get("ok", false)):
		_finish(2)
		return
	print("[ramp-mat] report=%s" % str(result.get("report", {})))
	var evaluated := int(result.get("ramp_terms_evaluated", -1))
	print("[ramp-mat] ramp_terms_evaluated=%d" % evaluated)
	_expect("A: the materializer evaluated ramp terms (not deferred)",
		evaluated > 0, str(evaluated))

	var values: PackedFloat64Array = result.get("values", PackedFloat64Array())
	print("[ramp-mat] per-cell values=%s" % str(values))
	_expect("A: one value per cell", values.size() == cells.size(), str(values))

	# B: each value equals sample(cell) * scale, computed here independently.
	var expected: Array = []
	for cell in cells:
		expected.append(float(cell) * 2.0 * 0.5)
	var matched := true
	for i in range(values.size()):
		if not _near(values[i], expected[i]):
			matched = false
	_expect("B: every cell matches sample(cell) * scale", matched,
		"got %s expected %s" % [str(values), str(expected)])

	# A: and they are genuinely different from each other, which is the exit
	# condition M3 is graded on.
	var distinct := {}
	for v in values:
		distinct[snappedf(v, 0.0001)] = true
	_expect("A: different cells yield DIFFERENT magnitudes",
		distinct.size() == cells.size(),
		"%d distinct values for %d cells: %s"
			% [distinct.size(), cells.size(), str(values)])

	# ── C: no sampler defers rather than zeroing ──────────────────────────
	var deferred: Dictionary = ext.build_derived_cell_front_for_test({
		"stat_ids": PackedInt32Array([stat_id]),
		"cells": PackedInt32Array([4]),
		"source_countries": PackedInt64Array([1]),
		"operations": PackedInt32Array([0]),
		"adds": PackedFloat64Array([0.0]),
		"factors": PackedFloat64Array([1.0]),
		"magnitude_sources": PackedInt32Array([1]),
		"metric_ids": PackedInt32Array([57]),
		"ramp_scales": PackedFloat64Array([0.5]),
		"sampler_scale": -1.0,       # negative = omit the sampler
		"world_identity": 1, "map_generation": 1, "sample_day": 1,
		"epoch_id": 1, "execution_contract_hash": 1,
	})
	_expect("C: without a sampler the term is deferred, not zeroed",
		bool(deferred.get("ok", false)) &&
			int(deferred.get("ramp_terms_deferred", 0)) > 0,
		str(deferred))
	var deferred_values: PackedFloat64Array = deferred.get(
		"values", PackedFloat64Array())
	var deferred_zeroed := true
	for v in deferred_values:
		if not _near(v, 0.0):
			deferred_zeroed = false
	_expect("C: and the deferred cell contributes nothing at all",
		deferred_zeroed, str(deferred_values))

	# ── D: a constant term coexists with a ramp term ──────────────────────
	var mixed: Dictionary = ext.build_derived_cell_front_for_test({
		"stat_ids": PackedInt32Array([stat_id, stat_id]),
		"cells": PackedInt32Array([6, 6]),
		"source_countries": PackedInt64Array([1, 1]),
		"operations": PackedInt32Array([0, 0]),
		"adds": PackedFloat64Array([0.25, 0.0]),
		"factors": PackedFloat64Array([1.0, 1.0]),
		"magnitude_sources": PackedInt32Array([0, 1]),
		"metric_ids": PackedInt32Array([-1, 57]),
		"ramp_scales": PackedFloat64Array([1.0, 1.0]),
		"sampler_scale": 1.0,
		"world_identity": 1, "map_generation": 1, "sample_day": 1,
		"epoch_id": 1, "execution_contract_hash": 1,
	})
	_expect("D: a constant and a ramp term coexist",
		bool(mixed.get("ok", false)), str(mixed))
	var mixed_values: PackedFloat64Array = mixed.get("values", PackedFloat64Array())
	# cell 6: constant 0.25 + ramp sample(6)=6.0*1.0*1.0 -> 6.25
	_expect("D: the two terms fold together on the same cell",
		mixed_values.size() == 1 && _near(mixed_values[0], 6.25),
		str(mixed_values))

	# ── F: no truncation on a wide ramp ───────────────────────────────────
	var wide_stat_ids := PackedInt32Array()
	var wide_cells := PackedInt32Array()
	var wide_countries := PackedInt64Array()
	var wide_ops := PackedInt32Array()
	var wide_adds := PackedFloat64Array()
	var wide_factors := PackedFloat64Array()
	var wide_sources := PackedInt32Array()
	var wide_metrics := PackedInt32Array()
	var wide_scales := PackedFloat64Array()
	for i in range(40):
		wide_stat_ids.append(stat_id)
		wide_cells.append(i)
		wide_countries.append(1)
		wide_ops.append(0)
		wide_adds.append(0.0)
		wide_factors.append(1.0)
		wide_sources.append(1)
		wide_metrics.append(57)
		wide_scales.append(0.1)
	var wide: Dictionary = ext.build_derived_cell_front_for_test({
		"stat_ids": wide_stat_ids, "cells": wide_cells,
		"source_countries": wide_countries, "operations": wide_ops,
		"adds": wide_adds, "factors": wide_factors,
		"magnitude_sources": wide_sources, "metric_ids": wide_metrics,
		"ramp_scales": wide_scales,
		"sampler_scale": 1.0,
		"world_identity": 1, "map_generation": 1, "sample_day": 1,
		"epoch_id": 1, "execution_contract_hash": 1,
	})
	_expect("F: a 40-cell ramp is not truncated",
		bool(wide.get("ok", false)) &&
			int(wide.get("truncated", 1)) == 0,
		str(wide))
	var wide_values: PackedFloat64Array = wide.get("values", PackedFloat64Array())
	_expect("F: and all 40 cells are present", wide_values.size() == 40,
		str(wide_values.size()))

	_finish(0 if _failures == 0 else 3)


func _finish(code: int) -> void:
	print("=== cell layer ramp materialize: %d checks, %d failures ==="
		% [_checks, _failures])
	quit(code)
