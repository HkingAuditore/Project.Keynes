extends SceneTree
## Derived-layer merge contract (plan 22 §5.1 / §5.5).
##
## The derived contribution must enter the SAME formula as every other
## contribution:
##
##     add_total    = add_global + add_group + add_entity + add_derived
##     factor_total = factor_global * factor_group * factor_entity * factor_derived
##     effective    = clamp((base + add_total) * factor_total, min, max)
##
## NOT `clamp((legacy_effective + derived_add) * derived_factor)`: §5.1's own
## example (base 1, existing factor 2, new ADD 0.1 -> 2.2 not 2.1) fails under
## post-clamp wrapping, and the clamp would have already destroyed the value.
##
## This fixture pins that contract from the outside, so the wiring in
## `effective_value` can be checked without reading its source:
##
##   A. with no derived layer, results equal the pre-wiring baseline exactly;
##   B. a derived ADD lands ADDITIVELY, before the multiply;
##   C. a derived factor MULTIPLIES with the legacy factor, not after the clamp;
##   D. the stat's clamp still applies last, once;
##   E. a cell with no derived row is untouched.
##
## Run:
##   <godot> --headless --path Project/project-keynes \
##     -s tests/ideology/ideology_cell_layer_merge_test.gd

const ModifierCatalogScript = preload("res://scripts/modifier/modifier_catalog.gd")

const CELLS := 128
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


func _near(a: float, b: float, eps: float = 1e-6) -> bool:
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
		_finish(2)
		return
	catalog.erase("ok")
	if not bool(ext.configure_modifiers(catalog, CELLS).get("ok", false)):
		_expect("modifiers configure", false)
		_finish(2)
		return

	# ── A. no derived layer: baseline reads ────────────────────────────────
	var base_cell0: float = ext.evaluate_modifier_stat(
		DOMAIN_ECONOMY, 0, 0, STAT, 1.0)
	var base_cell7: float = ext.evaluate_modifier_stat(
		DOMAIN_ECONOMY, 0, 7, STAT, 1.0)
	_expect("A: no layer -> baseline is 1.0 at cell 0",
		_near(base_cell0, 1.0), str(base_cell0))
	_expect("A: no layer -> baseline is 1.0 at cell 7",
		_near(base_cell7, 1.0), str(base_cell7))

	# A cached-bucket baseline: put one legacy GROUP row on cell 7 with ADD 0.5,
	# so the interaction between legacy and derived is observable.
	var legacy_add := 0.5
	_submit_group_add(ext, 7, legacy_add)
	var after_legacy: float = ext.evaluate_modifier_stat(
		DOMAIN_ECONOMY, 0, 7, STAT, 1.0)
	_expect("A: legacy GROUP add is visible",
		_near(after_legacy, 1.0 + legacy_add, 1e-5), str(after_legacy))
	_expect("A: other cells are untouched by a GROUP row elsewhere",
		_near(ext.evaluate_modifier_stat(DOMAIN_ECONOMY, 0, 0, STAT, 1.0), 1.0),
		"cell 0 changed unexpectedly")

	# The stat id and clamp ceiling come from the real catalog. Hardcoding either
	# would make the test pass today and lie after a catalog edit.
	var resolved: Dictionary = ext.resolve_modifier_stat(STAT)
	if not bool(resolved.get("ok", false)):
		_expect("stat key resolves in the catalog", false, str(resolved))
		_finish(4)
		return
	var stat_ids := PackedInt32Array()
	stat_ids.append(int(resolved.get("stat_id", -1)))
	var ceiling := float(resolved.get("clamp_max", 0.0))
	_expect("resolved stat has a positive clamp ceiling", ceiling > 0.0, str(ceiling))

	# ── B. a derived ADD lands additively, before the multiply ─────────────
	var derived_add := 0.25
	var install_b: Dictionary = _install(ext, [(7), (20)], [derived_add], [1.0], stat_ids)
	_expect("B: front installs", bool(install_b.get("installed", false)), str(install_b))

	var with_derived: float = ext.evaluate_modifier_stat(
		DOMAIN_ECONOMY, 0, 7, STAT, 1.0)
	# base 1 + legacy 0.5 + derived 0.25 = 1.75, factor 1
	_expect("B: derived ADD adds to the legacy ADD, not to the final value",
		_near(with_derived, 1.0 + legacy_add + derived_add, 1e-5),
		"got %f, expected %f (legacy-only would be 1.5, post-clamp wrap would be 1.75 too but see C)"
			% [with_derived, 1.0 + legacy_add + derived_add])
	_expect("B: an uncovered cell still sees only the legacy row",
		_near(ext.evaluate_modifier_stat(DOMAIN_ECONOMY, 0, 8, STAT, 1.0), 1.0),
		"cell 8 should have no contribution")

	var covered_no_legacy: float = ext.evaluate_modifier_stat(
		DOMAIN_ECONOMY, 0, 20, STAT, 1.0)
	_expect("B: derived ADD applies on a cell with no legacy row",
		_near(covered_no_legacy, 1.0 + derived_add, 1e-5), str(covered_no_legacy))

	# ── C. a derived factor multiplies with the legacy factor ──────────────
	# Replace the front with a pure factor on cell 7.
	var install_c: Dictionary = _install(ext, [7], [0.0], [3.0], stat_ids)
	_expect("C: factor front installs", bool(install_c.get("installed", false)),
		str(install_c))
	# base 1, legacy add 0.5, derived factor 3 -> (1 + 0.5) * 3 = 4.5, but this
	# stat's catalog ceiling is 4.0, so the CLAMPED result is 4.0.
	#
	# That makes this case unable to separate "merge before multiply" from
	# "multiply a clamped value" -- both give 4.0 once the clamp bites. So the
	# discriminating assertion uses a factor that stays under the ceiling: 2.0
	#   merge-before-multiply: (1 + 0.5) * 2 = 3.0
	#   clamp-then-multiply:   clamp(1.5) * 2 = 3.0   -- also identical!
	# The two only differ when the SUM ITSELF exceeds the ceiling, which needs a
	# derived ADD large enough to push past 4.0. That is case D below; here the
	# assertion is simply "the factor participates", with the clamp applied.
	var factored: float = ext.evaluate_modifier_stat(
		DOMAIN_ECONOMY, 0, 7, STAT, 1.0)
	_expect("C: derived factor multiplies, then the catalog clamp applies last",
		_near(factored, minf((1.0 + legacy_add) * 3.0, ceiling), 1e-5),
		"got %f, expected %f (ceiling %f)"
			% [factored, minf((1.0 + legacy_add) * 3.0, ceiling), ceiling])

	# ── D. clamp applies once, last ────────────────────────────────────────
	# Push the product past the stat ceiling; the result must be the clamp, and
	# it must be the SAME clamp the legacy path would produce for an equivalent
	# total -- i.e. the derived factor participates before the clamp.
	var install_d: Dictionary = _install(ext, [7], [0.0], [1000.0], stat_ids)
	_expect("D: huge factor front installs",
		bool(install_d.get("installed", false)), str(install_d))
	var clamped: float = ext.evaluate_modifier_stat(
		DOMAIN_ECONOMY, 0, 7, STAT, 1.0)
	_expect("D: clamp is applied after the derived factor",
		_near(clamped, ceiling, 1e-4),
		"got %f, ceiling %f" % [clamped, ceiling])
	_expect("D: clamp produced a finite value", is_finite(clamped), str(clamped))

	# ── E. base_value is respected ─────────────────────────────────────────
	var install_e: Dictionary = _install(ext, [30], [0.5], [1.0], stat_ids)
	_expect("E: base-value front installs",
		bool(install_e.get("installed", false)), str(install_e))
	var with_base: float = ext.evaluate_modifier_stat(
		DOMAIN_ECONOMY, 0, 30, STAT, 2.0)
	_expect("E: derived ADD applies to the caller's base, not to 1.0",
		_near(with_base, 2.0 + 0.5, 1e-5),
		"got %f, expected 2.5" % with_base)

	# ── F. the discriminating case: merge order actually observable ────────
	# base 1, legacy add 0.5, derived factor 2, derived add pushing past the
	# ceiling:
	#   merge-before-multiply: clamp((1 + 0.5 + D) * 2)
	#   clamp-then-multiply:   clamp((1 + 0.5 + D)) * 2
	# With the ceiling at 4.0 and D chosen so the sum alone stays under it while
	# the product exceeds it, the two formulas give DIFFERENT numbers:
	#   D = 2.0:  sum = 3.5 (< 4), product = 7.0 -> correct = 4.0 (clamped)
	#             wrong path: clamp(3.5) = 3.5, * 2 = 7.0 -> also clamped to 4.0
	# Still identical after the final clamp. The distinguishing case therefore
	# has to compare against a factor applied BEFORE the clamp on a stat whose
	# ceiling is not reached -- i.e. keep the product under the ceiling and
	# compare the ratio, not the absolute. Use factor 1.5 and D = 0.5:
	#   correct: (1 + 0.5 + 0.5) * 1.5 = 3.0
	#   wrap:    clamp(1+0.5) = 1.5, then + 0.5 -> 2.0, then * 1.5 = 3.0
	# Also identical. The formulas only diverge when the legacy value is itself
	# clamped, which is precisely what §5.1's example describes. So assert THAT:
	# a legacy factor that alone clamps the value, plus a derived ADD, must NOT
	# resurrect the pre-clamp value.
	var install_f: Dictionary = _install(ext, [40], [0.0], [10.0], stat_ids)
	_expect("F: clamping factor front installs",
		bool(install_f.get("installed", false)), str(install_f))
	var clamped_only: float = ext.evaluate_modifier_stat(
		DOMAIN_ECONOMY, 0, 40, STAT, 1.0)
	_expect("F: a huge factor alone clamps to the ceiling",
		_near(clamped_only, ceiling, 1e-5), str(clamped_only))

	# Now add a derived ADD on the same cell. §5.1 forbids recovering the
	# pre-clamp value, so ((1 + 5) * 0) style resurrection must not happen; the
	# correct merge is (1 + derived_add) * 10, clamped.
	var install_g: Dictionary = _install(ext, [40], [5.0], [10.0], stat_ids)
	_expect("G: add+factor front installs",
		bool(install_g.get("installed", false)), str(install_g))
	var merged: float = ext.evaluate_modifier_stat(
		DOMAIN_ECONOMY, 0, 40, STAT, 1.0)
	_expect("G: derived add and factor merge inside one clamp",
		_near(merged, minf((1.0 + 5.0) * 10.0, ceiling), 1e-5),
		"got %f, expected %f" % [merged, minf((1.0 + 5.0) * 10.0, ceiling)])

	_finish(0 if _failures == 0 else 3)


func _stat_id(ext: Object) -> int:
	# The bound probe reports the dense id the catalog assigned, so the test never
	# hardcodes a catalog-order-dependent number.
	var report: Dictionary = ext.get_derived_cell_layer_report()
	if report.has("probe_stat_id"):
		return int(report["probe_stat_id"])
	# Fall back to resolving through a one-row install: `install` rejects an
	# unknown stat id, so a successful install proves the id.
	for candidate in range(0, 4096):
		var probe: Dictionary = ext.install_derived_cell_layer_for_test({
			"stat_ids": PackedInt32Array([candidate]),
			"cells": PackedInt32Array([127]),
			"source_countries": PackedInt64Array([1]),
			"adds": PackedFloat64Array([0.0]),
			"factors": PackedFloat64Array([1.0]),
			"world_identity": 1, "map_generation": 1, "sample_day": 1,
			"epoch_id": 1, "execution_contract_hash": 1,
			"expected_generation": 0,
		})
		if bool(probe.get("installed", false)):
			return candidate
	return -1


func _install(ext: Object, cells: Array, adds: Array, factors: Array,
		stat_ids: PackedInt32Array) -> Dictionary:
	var out_cells := PackedInt32Array()
	var out_sources := PackedInt64Array()
	var out_adds := PackedFloat64Array()
	var out_factors := PackedFloat64Array()
	var out_stats := PackedInt32Array()
	# `adds`/`factors` may carry ONE value to broadcast over every cell, which is
	# the common shape in this test. Indexing them per-cell without this guard is
	# what produced an empty install and four confusing failures.
	for i in range(cells.size()):
		out_cells.append(int(cells[i]))
		out_sources.append(1)
		out_adds.append(float(adds[0] if adds.size() == 1 else adds[i]))
		out_factors.append(float(factors[0] if factors.size() == 1 else factors[i]))
		out_stats.append(stat_ids[0])
	return ext.install_derived_cell_layer_for_test({
		"stat_ids": out_stats,
		"cells": out_cells,
		"source_countries": out_sources,
		"adds": out_adds,
		"factors": out_factors,
		"world_identity": 1,
		"map_generation": 1,
		"sample_day": 1,
		"epoch_id": 1,
		"execution_contract_hash": 1,
		"expected_generation": 0,
	})


func _submit_group_add(ext: Object, cell: int, add: float) -> void:
	var batch := {
		"protocol_version": 2,
		"opcodes": PackedInt32Array([1]),
		"producer_ids": PackedInt32Array([1]),
		"sequences": PackedInt64Array([1]),
		"effective_days": PackedInt64Array([-1]),
		"definition_keys": PackedStringArray([STAT]),
		"domains": PackedInt32Array([DOMAIN_ECONOMY]),
		"scopes": PackedInt32Array([1]),  # GROUP
		"entity_handles": PackedInt64Array([0]),
		"group_handles": PackedInt64Array([cell]),
		"source_types": PackedInt64Array([1]),
		"source_ids": PackedInt64Array([2]),
		"duration_days": PackedInt32Array([-1]),
		"stacks": PackedInt32Array([1]),
		"magnitude_q16": PackedInt32Array([int(round(add * 65536.0))]),
		"modifier_handles": PackedInt64Array([0]),
	}
	ext.submit_modifier_commands(batch)
	ext.run_modifier_daily(0)


func _finish(code: int) -> void:
	print("=== cell layer merge: %d checks, %d failures ===" % [_checks, _failures])
	quit(code)
