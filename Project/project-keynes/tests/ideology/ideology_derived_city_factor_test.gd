extends SceneTree
## Does a derived contribution actually reach `city_good_output_factor_q16`?
##
## WHY THIS EXISTS
##
## `ideology_cell_layer_shard_test` fails with `city_factor_shard_cursor=-1` where the
## fixture expected a cursor. That counter belongs to the per-cell CSR built by
## `refresh_city_output_modifier_factors`, and the OLD v1 plane was one of that CSR's
## producers -- a plane this migration deleted. So either the derived layer took over the
## job (fine) or the CSR now comes out empty and per-cell factors silently stop being
## per-cell (a real regression).
##
## "It should still work" is not evidence. This asks the reader directly: install a front
## that touches exactly one cell and see whether that one cell reads differently.
##
## Run:
##   <godot> --headless --path Project/project-keynes \
##     -s tests/ideology/ideology_derived_city_factor_test.gd

const CELLS := 16
const GOOD := 0
## The cell the front covers. Anything but 0, because 0 is also the "no group" sentinel
## in several readers.
const TOUCHED := 5
const UNTOUCHED := 6
const Q16_ONE := 65536

const CountryCatalogScript = preload("res://scripts/economy/economy_catalog.gd")
const EconomyCatalogScript = preload("res://scripts/economy/economy_catalog.gd")
const ModifierCatalogScript = preload("res://scripts/modifier/modifier_catalog.gd")

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
	var country_ir: Dictionary = CountryCatalogScript.compile_native_catalog()
	country_ir.erase("ok")
	var econ_catalog: Dictionary = EconomyCatalogScript.compile_native_catalog()
	var good_ids: PackedStringArray = econ_catalog.get("good_ids", PackedStringArray())
	if good_ids.is_empty():
		_expect("the economy catalog declares goods", false)
		_finish(1)
		return
	var mod_ir: Dictionary = ModifierCatalogScript.load_default().compile_native_catalog()
	mod_ir.erase("ok")

	var ext: Object = ClassDB.instantiate("DCWorldExt")
	ext.create_entities(CELLS)
	ext.configure_modifiers(mod_ir, CELLS)
	var stat_key := "economy.city.good.%s.output_factor" % String(good_ids[GOOD])
	var resolved: Dictionary = ext.resolve_modifier_stat(stat_key)
	var stat_id := int(resolved.get("stat_id", -1))
	_expect("the good output stat resolves", stat_id >= 0, str(resolved))
	if stat_id < 0:
		_finish(1)
		return
	print("[df] stat %s -> id=%d" % [stat_key, stat_id])

	# `get_city_output_factor_q16` walks the per-cell CSR, which only exists after an
	# economy epoch has been opened; that is `ideology_cell_layer_shard_test`'s job, not
	# this one's. What matters here is the MECHANISM the CSR is built on:
	# `refresh_city_output_modifier_factors` reads each cell through
	# `effective_value(ECONOMY, stat, 0, cell, 1.0)` (`economy_runtime.cpp:7327`), which
	# is the very call this front feeds. So if the value below moves for one cell and not
	# the other, the CSR sees it too -- by code identity, not by inference.
	var base_touched: Dictionary = ext.get_effective_stat_value(
		stat_key, TOUCHED, 0, 1.0)
	var base_untouched: Dictionary = ext.get_effective_stat_value(
		stat_key, UNTOUCHED, 0, 1.0)
	print("[df] baseline: touched=%s untouched=%s"
		% [str(base_touched.get("value", "?")), str(base_untouched.get("value", "?"))])
	var baseline := float(base_touched.get("value", -1.0))

	# A +25% additive delta on ONE cell only. Not 1.0: an identity would make "the
	# contribution landed" indistinguishable from "nothing happened".
	var installed: Dictionary = ext.install_derived_cell_layer_for_test({
		"stat_ids": PackedInt32Array([stat_id]),
		"cells": PackedInt32Array([TOUCHED]),
		"source_countries": PackedInt64Array([4294967296]),
		"adds": PackedFloat64Array([0.25]),
		"factors": PackedFloat64Array([1.0]),
		"world_identity": 1, "map_generation": 1, "sample_day": 1,
		"epoch_id": 1, "execution_contract_hash": 1, "expected_generation": 0,
	})
	_expect("the front installs", bool(installed.get("ok", false)), str(installed))

	# 1. The derived layer sees it.
	var probe: Dictionary = ext.get_effective_stat_value(stat_key, TOUCHED, 0, 1.0)
	print("[df] effective_value on the touched cell: %s" % str(probe))
	_expect("the touched cell carries a derived contribution",
		bool(probe.get("derived_present", false)), str(probe))

	# 2. THE QUESTION: does the per-cell read move for one cell and not the other?
	var touched: Dictionary = ext.get_effective_stat_value(stat_key, TOUCHED, 0, 1.0)
	var untouched: Dictionary = ext.get_effective_stat_value(stat_key, UNTOUCHED, 0, 1.0)
	print("[df] after install: touched=%s untouched=%s (baseline=%.6f)"
		% [str(touched.get("value", "?")), str(untouched.get("value", "?")), baseline])
	_expect("the touched cell moved away from its baseline",
		absf(float(touched.get("value", 0.0)) - baseline) > 1e-9,
		"touched=%s baseline=%.6f" % [str(touched.get("value", "?")), baseline])
	_expect("the untouched cell did NOT move",
		absf(float(untouched.get("value", 0.0)) - baseline) <= 1e-9,
		"untouched=%s baseline=%.6f" % [str(untouched.get("value", "?")), baseline])
	# A per-cell override only exists when the two differ; if they agreed, the CSR would
	# collapse them into the shared row and every cell would read the same.
	_expect("per-cell means the two cells read differently",
		absf(float(touched.get("value", 0.0)) -
			float(untouched.get("value", 0.0))) > 1e-9,
		"touched=%s untouched=%s" % [str(touched.get("value", "?")),
			str(untouched.get("value", "?"))])

	_finish(0 if _failures == 0 else 3)


func _finish(code: int) -> void:
	print("=== derived city factor: %d checks, %d failures ===" % [_checks, _failures])
	quit(code)
