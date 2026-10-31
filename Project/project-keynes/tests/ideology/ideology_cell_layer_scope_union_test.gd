extends SceneTree
## Scope enumeration union (plan 22 §8.5).
##
## `refresh_city_modifier_factors` and `refresh_city_output_modifier_factors`
## build their work sets from `collect_scope_ids` / `collect_scope_stat_entries`.
## If those functions only enumerate `Store.buckets`, then a cell whose ONLY
## contribution is derived is never visited -- and the merge in `effective_value`
## computes a correct value for a cell nobody asks about.
##
## That is the single most dangerous failure mode of this migration: the layer
## installs cleanly, the merge is arithmetically right, and nothing changes.
##
## So the assertions here are deliberately shaped around "derived-only":
##
##   A. a derived-only cell APPEARS in collect_scope_ids;
##   B. it appears in collect_scope_stat_entries as (cell, stat);
##   C. a stat that is not requested is not enumerated;
##   D. legacy-only enumeration is unchanged (no spurious entries);
##   E. the union is sorted and de-duplicated;
##   F. a legacy row and a derived row on the SAME cell collapse to one id.
##
## Run:
##   <godot> --headless --path Project/project-keynes \
##     -s tests/ideology/ideology_cell_layer_scope_union_test.gd

const ModifierCatalogScript = preload("res://scripts/modifier/modifier_catalog.gd")

const CELLS := 128
const STAT_A := "economy.city.birth_factor"
const STAT_B := "economy.city.good.cloth.output_factor"
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

	var stat_a := int(ext.resolve_modifier_stat(STAT_A).get("stat_id", -1))
	var stat_b := int(ext.resolve_modifier_stat(STAT_B).get("stat_id", -1))
	if stat_a < 0 or stat_b < 0:
		_expect("both stat keys resolve", false, "a=%d b=%d" % [stat_a, stat_b])
		_finish(4)
		return

	# ── baseline: nothing installed ────────────────────────────────────────
	var base_ids: Dictionary = ext.collect_modifier_scope_ids(
		DOMAIN_ECONOMY, 1, PackedInt32Array([stat_a]))  # scope 1 = GROUP
	_expect("baseline: enumeration is empty with no layer and no rows",
		(base_ids.get("scope_ids", PackedInt64Array()) as PackedInt64Array).is_empty(),
		str(base_ids))

	# ── A/B: derived-only cells must be enumerated ─────────────────────────
	var derived_cells := [11, 22, 33]
	var installed := _install(ext, derived_cells, stat_a, 0.25, 1.0)
	_expect("A: derived front installs", bool(installed.get("installed", false)),
		str(installed))

	var after_ids: Dictionary = ext.collect_modifier_scope_ids(
		DOMAIN_ECONOMY, 1, PackedInt32Array([stat_a]))
	var ids: PackedInt64Array = after_ids.get("scope_ids", PackedInt64Array())
	_expect("A: derived-only cells appear in collect_scope_ids",
		ids.size() == derived_cells.size(),
		"got %s" % str(ids))
	for cell in derived_cells:
		_expect("A: cell %d is present" % cell, ids.has(cell), str(ids))

	var entries: Dictionary = ext.collect_modifier_scope_stat_entries(
		DOMAIN_ECONOMY, 1, PackedInt32Array([stat_a]))
	var e_cells: PackedInt64Array = entries.get("scope_ids", PackedInt64Array())
	var e_stats: PackedInt32Array = entries.get("stat_ids", PackedInt32Array())
	_expect("B: stat entries carry the same cells",
		e_cells.size() == derived_cells.size(), "got %s" % str(e_cells))
	_expect("B: stat entries carry the requested stat",
		e_stats.size() == e_cells.size(), str(e_stats))
	var all_a := true
	for value in e_stats:
		if int(value) != stat_a:
			all_a = false
	_expect("B: every entry names the requested stat", all_a, str(e_stats))

	# ── C: an unrequested stat is not enumerated ───────────────────────────
	var other: Dictionary = ext.collect_modifier_scope_ids(
		DOMAIN_ECONOMY, 1, PackedInt32Array([stat_b]))
	_expect("C: an unrequested stat enumerates nothing",
		(other.get("scope_ids", PackedInt64Array()) as PackedInt64Array).is_empty(),
		str(other))

	# ── D: legacy-only rows still enumerate, and nothing extra appears ─────
	var legacy_cells := [77, 88]
	for cell in legacy_cells:
		_submit_group_add(ext, cell, 0.5, STAT_A)
	var mixed: Dictionary = ext.collect_modifier_scope_ids(
		DOMAIN_ECONOMY, 1, PackedInt32Array([stat_a]))
	var mixed_ids: PackedInt64Array = mixed.get("scope_ids", PackedInt64Array())
	_expect("D: legacy cells are enumerated alongside derived ones",
		mixed_ids.size() == derived_cells.size() + legacy_cells.size(),
		"got %s" % str(mixed_ids))
	for cell in legacy_cells:
		_expect("D: legacy cell %d is present" % cell, mixed_ids.has(cell),
			str(mixed_ids))

	# ── E: sorted and de-duplicated ────────────────────────────────────────
	var sorted_ok := true
	for i in range(1, mixed_ids.size()):
		if mixed_ids[i] <= mixed_ids[i - 1]:
			sorted_ok = false
	_expect("E: union is strictly ascending (sorted and de-duplicated)",
		sorted_ok, str(mixed_ids))

	# ── F: a cell carrying BOTH collapses to one id ────────────────────────
	var shared_cell := 11
	_submit_group_add(ext, shared_cell, 0.5, STAT_A)
	var shared: Dictionary = ext.collect_modifier_scope_ids(
		DOMAIN_ECONOMY, 1, PackedInt32Array([stat_a]))
	var shared_ids: PackedInt64Array = shared.get("scope_ids", PackedInt64Array())
	var occurrences := 0
	for value in shared_ids:
		if int(value) == shared_cell:
			occurrences += 1
	_expect("F: a cell with both legacy and derived rows appears exactly once",
		occurrences == 1, "occurrences=%d in %s" % [occurrences, str(shared_ids)])
	_expect("F: the union did not grow when the cell was already present",
		shared_ids.size() == mixed_ids.size(), str(shared_ids))

	# ── G/H: version combination (plan §8.6) ──────────────────────────────
	# The union above proves the collector can SEE derived cells. It does not
	# prove the reader ever runs: `refresh_city_modifier_factors` returns early
	# when its version token is unchanged (`economy_runtime.cpp:7016-7018`), so a
	# derived install that does not move the version leaves the reader asleep and
	# the whole path inert. These two cases pin that.
	var version_before: int = ext.modifier_stat_bucket_version(
		DOMAIN_ECONOMY, PackedInt32Array([stat_a]))
	var install_new: Dictionary = _install(ext, [55], stat_a, 0.75, 1.0)
	_expect("G: a new derived front installs",
		bool(install_new.get("installed", false)), str(install_new))
	var version_after: int = ext.modifier_stat_bucket_version(
		DOMAIN_ECONOMY, PackedInt32Array([stat_a]))
	_expect("G: a derived install MOVES the version token",
		version_after != version_before,
		"before=%d after=%d -- if equal, the reader short-circuits and never sees the layer"
			% [version_before, version_after])

	# Idempotence: reinstalling identical content must NOT move the version, or an
	# idle day would invalidate every cache (plan §7.4).
	var version_idle_before: int = ext.modifier_stat_bucket_version(
		DOMAIN_ECONOMY, PackedInt32Array([stat_a]))
	var repeat: Dictionary = _install(ext, [55], stat_a, 0.75, 1.0)
	_expect("H: identical re-install is skipped",
		bool(repeat.get("skipped", false)) or not bool(repeat.get("installed", true)),
		str(repeat))
	var version_idle_after: int = ext.modifier_stat_bucket_version(
		DOMAIN_ECONOMY, PackedInt32Array([stat_a]))
	_expect("H: an identical re-install does NOT move the version (idle stays idle)",
		version_idle_after == version_idle_before,
		"before=%d after=%d" % [version_idle_before, version_idle_after])

	_finish(0 if _failures == 0 else 3)


func _install(ext: Object, cells: Array, stat_id: int, add: float,
		factor: float) -> Dictionary:
	var out_cells := PackedInt32Array()
	var out_sources := PackedInt64Array()
	var out_adds := PackedFloat64Array()
	var out_factors := PackedFloat64Array()
	var out_stats := PackedInt32Array()
	for cell in cells:
		out_cells.append(int(cell))
		out_sources.append(1)
		out_adds.append(add)
		out_factors.append(factor)
		out_stats.append(stat_id)
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


func _submit_group_add(ext: Object, cell: int, add: float, stat_key: String) -> void:
	ext.submit_modifier_commands({
		"protocol_version": 2,
		"opcodes": PackedInt32Array([1]),
		"producer_ids": PackedInt32Array([1]),
		"sequences": PackedInt64Array([1]),
		"effective_days": PackedInt64Array([-1]),
		"definition_keys": PackedStringArray([stat_key]),
		"domains": PackedInt32Array([DOMAIN_ECONOMY]),
		"scopes": PackedInt32Array([1]),
		"entity_handles": PackedInt64Array([0]),
		"group_handles": PackedInt64Array([cell]),
		"source_types": PackedInt64Array([1]),
		"source_ids": PackedInt64Array([2]),
		"duration_days": PackedInt32Array([-1]),
		"stacks": PackedInt32Array([1]),
		"magnitude_q16": PackedInt32Array([int(round(add * 65536.0))]),
		"modifier_handles": PackedInt64Array([0]),
	})
	ext.run_modifier_daily(0)


func _finish(code: int) -> void:
	print("=== cell layer scope union: %d checks, %d failures ==="
		% [_checks, _failures])
	quit(code)
