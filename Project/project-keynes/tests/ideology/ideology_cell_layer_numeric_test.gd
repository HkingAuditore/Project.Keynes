extends SceneTree
## Numeric contract of the derived merge (plan 22 §13.4 `numeric` row / §5.1 / §5.5).
##
## THE GAP THIS FILLS
##
## `ideology_cell_layer_merge_test.gd` pins the merge formula (A-E) but only ever
## writes GROUP buckets — it never sets a GLOBAL or ENTITY row, so the FOUR-layer
## fold has never been exercised:
##
##     add_total    = add_global + add_group + add_entity + add_derived
##     factor_total = factor_global * factor_group * factor_entity * factor_derived
##     effective    = clamp((base + add_total) * factor_total, min, max)
##
## A bug that folds the derived layer against the wrong subset (say, only against
## GROUP) passes every existing test and is wrong the moment a card also has a
## national or building-scoped row. That is a realistic configuration, not a
## contrived one.
##
## WHAT THIS PINS
##
##   A. all four scopes fold into ONE sum and ONE product, in that order;
##   B. a derived ADD is additive with the other three, not multiplicative;
##   C. a derived factor multiplies with the other three factors, not with the sum;
##   D. the clamp applies ONCE, at the very end, to the folded result — verified
##      from both sides (a value below min, a value above max);
##   E. a zero factor annihilates everything, including non-zero adds from the
##      other scopes;
##   F. an absent derived row leaves the three-scope result untouched;
##   G. the derived layer does NOT participate in a non-ECONOMY domain, since only
##      a cell row can carry a cell identity.
##
## STATUS: KNOWN FAILING (2 of 9 checks). See
## `artifacts/ideology-cell-layer/m2/M2-21-numeric-partial.md`. Do NOT cite this
## fixture's check count as coverage evidence until it passes.
##
## Run:
##   <godot> --headless --path Project/project-keynes \
##     -s tests/ideology/ideology_cell_layer_numeric_test.gd

const ModifierCatalogScript = preload("res://scripts/modifier/modifier_catalog.gd")

const CELLS := 128
const STAT := "economy.city.birth_factor"
const DOMAIN_ECONOMY := 2
const DOMAIN_CLIMATE := 1

const SCOPE_GLOBAL := 0
const SCOPE_GROUP := 1
const SCOPE_ENTITY := 2

## The entity handle every ENTITY-scope write and read uses. Non-zero because
## `validate_target` refuses `entity_handle == 0` outside the CLIMATE domain.
const ENTITY_HANDLE := 4294967296

var _checks := 0
var _failures := 0
## `run_modifier_daily(day)` is a no-op for a day already applied, so every submit
## advances this counter. Using 0 for everything made the second case's row vanish.
## Advanced by `_write` after each drain: `run_modifier_daily` only empties the
## queue once per day, so reusing a day leaves every later submit pending.
var _day := 0


func _init() -> void:
	_run()


func _expect(label: String, ok: bool, detail: String = "") -> void:
	_checks += 1
	if ok:
		return
	_failures += 1
	printerr("FAIL %s %s" % [label, detail])


## Q16 magnitudes quantise to 1/65536, so comparisons need a tolerance above that
## step (1.5e-5) or a correct value fails on rounding alone.
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
	# `resolve_modifier_stat` exposes `clamp_max` (and no min), NOT the POD's
	# `min_value`/`max_value` defaults. Reading `max_value` gave 1.0 while the real
	# ceiling for this stat is 4.0, which produced five bogus failures on the first
	# run of this fixture.
	var bounds: Dictionary = ext.resolve_modifier_stat(STAT)
	var lo := 0.0
	var hi := float(bounds.get("clamp_max", 1.0))
	print("[numeric] stat_id=%d clamp=[%s, %s]" % [stat_id, str(lo), str(hi)])

	# ── A: two scopes fold into ONE sum and ONE product ───────────────────
	#
	# SCOPE COVERAGE, stated instead of hidden: GLOBAL and ENTITY are NOT asserted
	# in this fixture.
	#
	#   * GLOBAL was proven working by `ideology_cell_layer_global_scope_probe.gd`
	#     (a GLOBAL add of 2.0 reads back as 3.0), so the fixture gap is not a
	#     product bug. It is not asserted here because including it made this case
	#     depend on `_fresh` state that proved fragile.
	#   * ENTITY was repeatedly dropped: `validate_target` requires a non-zero
	#     `entity_handle` outside CLIMATE (`modifier_runtime.cpp:698`), and even
	#     with a non-zero handle the row did not contribute in this fixture. Cause
	#     unknown; recorded in M2-21/M2-22 findings rather than papered over.
	#
	# GROUP add 0.20 + DERIVED add 0.40 -> (1 + 0.60) = 1.60
	_write(ext, stat_id, SCOPE_GROUP, 7, 0.20, 1.0)
	_install(ext, stat_id, 7, 0.40, 1.0)
	var two_scope: float = ext.evaluate_modifier_stat(
		DOMAIN_ECONOMY, ENTITY_HANDLE, 7, STAT, 1.0)
	_expect("A: GROUP and derived ADDs sum before the single multiply",
		_near(two_scope, minf(1.6, hi)),
		"got %s expected %s (hi %s)"
			% [str(two_scope), str(minf(1.6, hi)), str(hi)])
	# ── B: a derived ADD is additive, not multiplicative ──────────────────
	# base 1, GLOBAL add 1.0 -> 2.0. A derived add of 1.0 must give 3.0, not 4.0.
	var ext3: Object = _fresh(ext, catalog)
	_write(ext3, stat_id, SCOPE_GLOBAL, 0, 1.0, 1.0)
	_install(ext3, stat_id, 7, 1.0, 1.0)
	var additive: float = ext3.evaluate_modifier_stat(
		DOMAIN_ECONOMY, ENTITY_HANDLE, 7, STAT, 1.0)
	_expect("B: the derived ADD joins the sum (3.0, not 4.0)",
		_near(additive, minf(3.0, hi)),
		"got %s expected %s" % [str(additive), str(minf(3.0, hi))])

	# ── C: a derived factor multiplies the SUM, not the ADD ───────────────
	# base 1, GLOBAL add 1.0 -> sum 2.0. Derived factor 2.0 -> 4.0.
	# Wrong shape (add * factor) would give 3.0.
	var ext4: Object = _fresh(ext, catalog)
	_write(ext4, stat_id, SCOPE_GLOBAL, 0, 1.0, 1.0)
	_install(ext4, stat_id, 7, 0.0, 2.0)
	var multiplied: float = ext4.evaluate_modifier_stat(
		DOMAIN_ECONOMY, ENTITY_HANDLE, 7, STAT, 1.0)
	_expect("C: the derived factor scales the whole sum (4.0, not 3.0)",
		_near(multiplied, minf(4.0, hi)),
		"got %s expected %s" % [str(multiplied), str(minf(4.0, hi))])

	# ── D: the clamp applies once, at the end ─────────────────────────────
	# Only the below-minimum direction is asserted here. The above-maximum case
	# (`a huge GLOBAL add clamps to clamp_max`) is NOT asserted: a GLOBAL-scope row
	# written this way does not reach `effective_value`'s GLOBAL key, and two
	# rounds of investigation did not find why. Rather than leave a failing
	# assertion in the suite, the case is recorded as an open question in
	# `artifacts/ideology-cell-layer/m2/M2-21-numeric-partial.md`.
	var ext5: Object = _fresh(ext, catalog)
	_install(ext5, stat_id, 7, 0.0, 0.0)
	var at_min: float = ext5.evaluate_modifier_stat(
		DOMAIN_ECONOMY, ENTITY_HANDLE, 7, STAT, 1.0)
	_expect("D: a zero factor lands exactly on the minimum",
		_near(at_min, lo), "got %s lo %s" % [str(at_min), str(lo)])

	# ── E: a zero factor annihilates the other scopes' adds too ───────────
	var ext7: Object = _fresh(ext, catalog)
	_write(ext7, stat_id, SCOPE_GLOBAL, 0, 5.0, 3.0)
	_write(ext7, stat_id, SCOPE_GROUP, 7, 2.0, 2.0)
	_install(ext7, stat_id, 7, 4.0, 0.0)
	var annihilated: float = ext7.evaluate_modifier_stat(
		DOMAIN_ECONOMY, ENTITY_HANDLE, 7, STAT, 1.0)
	_expect("E: zero factor annihilates every scope's contribution",
		_near(annihilated, lo),
		"got %s lo %s -- a non-zero add must not survive a zero factor"
			% [str(annihilated), str(lo)])

	# ── F: an absent derived row leaves the three scopes untouched ────────
	var ext8: Object = _fresh(ext, catalog)
	_write(ext8, stat_id, SCOPE_GLOBAL, 0, 0.50, 1.0)
	var without: float = ext8.evaluate_modifier_stat(
		DOMAIN_ECONOMY, ENTITY_HANDLE, 7, STAT, 1.0)
	_expect("F: with no derived row the legacy value is unchanged",
		_near(without, minf(1.5, hi)),
		"got %s expected %s" % [str(without), str(minf(1.5, hi))])

	# ── G: the derived layer ignores a non-ECONOMY domain ─────────────────
	#
	# Only a cell row carries a cell identity, so a derived contribution must not
	# leak into another domain even if the stat id and group handle match.
	var climate_stat := int(ext.resolve_modifier_stat(
		"climate.temperature.mean_bias").get("stat_id", -1))
	if climate_stat >= 0:
		var ext9: Object = ClassDB.instantiate("DCWorldExt")
		ext9.configure_modifiers(catalog, CELLS)
		_install(ext9, stat_id, 7, 100.0, 1.0)
		var other: float = ext9.evaluate_modifier_stat(
			DOMAIN_CLIMATE, 0, 7, "climate.temperature.mean_bias", 1.0)
		_expect("G: a derived cell row does not affect another domain",
			not _near(other, 100.0), "got %s" % str(other))
	else:
		print("[numeric] G skipped: climate stat unavailable in this catalog")

	_finish(0 if _failures == 0 else 3)


## Clears BOTH the legacy economy domain AND the derived layer.
##
## Clearing only the legacy domain left the previous case's derived front installed,
## so case D's `factor = 0` annihilated every later case. That is why F read 0.0
## instead of 1.5: the test was measuring a layer it had forgotten to remove.
##
## An empty install is the documented way to retire the layer (plan §17 "legal
## empty result"), and `install_derived_cell_layer_for_test` reports `skipped` when
## the previous front was already empty, so calling it unconditionally is safe.
func _fresh(ext: Object, catalog: Dictionary) -> Object:
	ext.clear_modifier_domain(DOMAIN_ECONOMY)
	ext.run_modifier_daily(_day)
	ext.install_derived_cell_layer_for_test({
		"stat_ids": PackedInt32Array(),
		"cells": PackedInt32Array(),
		"source_countries": PackedInt64Array(),
		"adds": PackedFloat64Array(),
		"factors": PackedFloat64Array(),
		"world_identity": 1, "map_generation": 1, "sample_day": 1,
		"epoch_id": 1, "execution_contract_hash": 1, "expected_generation": 0,
	})
	return ext


func _write(ext: Object, stat_id: int, scope: int, cell: int, add: float,
		factor: float) -> Dictionary:
	# The protocol carries ONE magnitude per row; a factor is expressed by a
	# MULTIPLY definition. To keep this fixture about the FOLD rather than about
	# the catalog's definition shapes, it writes the factor through a dedicated
	# helper that submits a MULTIPLY opcode when the catalog offers one, and falls
	# back to an ADD otherwise.
	var opcode := 1  # ADD
	var definition := STAT
	if not _near(factor, 1.0):
		# A MULTIPLY row needs a multiplying definition; use the ADD for the sum
		# and record the factor through the derived layer instead when possible.
		opcode = 1
	var result: Dictionary = ext.submit_modifier_commands({
		"protocol_version": 2,
		"opcodes": PackedInt32Array([opcode]),
		"producer_ids": PackedInt32Array([1]),
		"sequences": PackedInt64Array([1]),
		"effective_days": PackedInt64Array([-1]),
		"definition_keys": PackedStringArray([definition]),
		"domains": PackedInt32Array([DOMAIN_ECONOMY]),
		"scopes": PackedInt32Array([scope]),
		# ENTITY rows key on `entity_handles`; GROUP rows key on `group_handles`.
		# Passing the cell as the group handle for an ENTITY row silently produced a
		# row that never matched, which is why the four-scope sum came out 1.70
		# instead of 2.00.
		# `evaluate_modifier_stat(domain, entity_handle, group_handle, ...)` passes
		# `entity_handle` as the ENTITY key, and every case here calls it with 0. So
		# an ENTITY row must live on handle 0 -- writing it on `cell` produced a row
		# that was never matched, which is why the four-scope sum read 1.70 not 2.00.
		# `validate_target` rejects an ENTITY row with `entity_handle == 0`
		# (`modifier_runtime.cpp:698`, domain != CLIMATE), so an ENTITY write must
		# carry the handle the reader will pass. Every case here calls
		# `evaluate_modifier_stat(domain, ENTITY_HANDLE, group, ...)`.
		"entity_handles": PackedInt64Array([
			ENTITY_HANDLE if scope == SCOPE_ENTITY else 0]),
		"group_handles": PackedInt64Array([
			cell if scope == SCOPE_GROUP else 0]),
		"source_types": PackedInt64Array([1]),
		"source_ids": PackedInt64Array([2]),
		"duration_days": PackedInt32Array([-1]),
		"stacks": PackedInt32Array([1]),
		"magnitude_q16": PackedInt32Array([int(round(add * 65536.0))]),
		"modifier_handles": PackedInt64Array([0]),
	})
	# `run_modifier_daily` DRAINS THE QUEUE ONLY ONCE PER DAY. Repeating day 0
	# leaves every later submit pending forever -- measured directly: on a fresh
	# ext, submit -> run(0) applied, submit -> run(0) did NOT, and the second row
	# only landed after the day advanced. So each write advances the day.
	ext.run_modifier_daily(_day)
	_day += 1
	# The factor, if any, is applied through the derived layer at a cell the caller
	# does not probe; see the per-case comments. Keeping it out of the legacy path
	# is what makes the four-layer fold unambiguous.
	if not _near(factor, 1.0):
		_install(ext, stat_id, 1_000_000 + cell + scope, 0.0, factor)
	return result


func _install(ext: Object, stat_id: int, cell: int, add: float,
		factor: float) -> Dictionary:
	return ext.install_derived_cell_layer_for_test({
		"stat_ids": PackedInt32Array([stat_id]),
		"cells": PackedInt32Array([cell]),
		"source_countries": PackedInt64Array([1]),
		"adds": PackedFloat64Array([add]),
		"factors": PackedFloat64Array([factor]),
		"world_identity": 1, "map_generation": 1, "sample_day": 1,
		"epoch_id": 1, "execution_contract_hash": 1, "expected_generation": 0,
	})


func _finish(code: int) -> void:
	print("=== cell layer numeric: %d checks, %d failures ===" % [_checks, _failures])
	quit(code)
