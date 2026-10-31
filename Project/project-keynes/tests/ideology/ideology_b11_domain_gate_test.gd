extends SceneTree
## B11 -- the derived merge must be gated on the ECONOMY domain, nothing else.
##
## WHY THIS EXISTS
##
## `effective_value` merges the derived front under
##
##     if (domain == ECONOMY && !_derived_cell_front.rows.empty())
##
## and that guard used to ALSO say `group_handle != 0`, which I removed because cell 0 is
## a legitimate cell (measured: every card did nothing on its country's first cell).
## Removing a guard is exactly the kind of change that silently widens a condition, so
## the boundary needs its own test: the derived contribution must appear for ECONOMY and
## for NO other domain, even with an identical stat and an identical cell handle.
##
## This is the sharpest possible control -- the ONLY thing that differs between the two
## reads is `domain`.
##
## Run:
##   <godot> --headless --path Project/project-keynes \
##     -s tests/ideology/ideology_b11_domain_gate_test.gd

const CELLS := 8
const Q16_ONE := 65536
const DOMAIN_CLIMATE := 0
const DOMAIN_COUNTRY := 1
const DOMAIN_ECONOMY := 2
const DOMAIN_GAMEPLAY := 3
## The stat the front targets. 0 is NOT used: it is also the "no group" sentinel in
## several legacy readers, so testing only cell 0 would not exercise the normal path.
const TOUCHED := 5
const STAT_KEY := "economy.city.good.adobe_brick.output_factor"

const CountryCatalogScript = preload("res://scripts/economy/economy_catalog.gd")
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


func _read(ext: Object, domain: int, group: int) -> float:
	return float(ext.evaluate_modifier_stat(domain, 0, group, STAT_KEY, 1.0))


func _run() -> void:
	var ext: Object = ClassDB.instantiate("DCWorldExt")
	ext.create_entities(CELLS)
	var cat: Dictionary = ModifierCatalogScript.load_default().compile_native_catalog()
	cat.erase("ok")
	_expect("the modifier catalog configures",
		bool(ext.configure_modifiers(cat, CELLS).get("ok", false)))
	var resolved: Dictionary = ext.resolve_modifier_stat(STAT_KEY)
	var stat_id := int(resolved.get("stat_id", -1))
	_expect("the target stat resolves", stat_id >= 0, str(resolved))
	if stat_id < 0:
		_finish(1)
		return

	var domains := [DOMAIN_CLIMATE, DOMAIN_COUNTRY, DOMAIN_ECONOMY, DOMAIN_GAMEPLAY]
	var before := {}
	for d in domains:
		before[d] = _read(ext, d, TOUCHED)

	# A +25% additive delta on one cell.
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

	for d in domains:
		var after := _read(ext, d, TOUCHED)
		var moved := absf(after - float(before[d])) > 1e-9
		var domain_name: String = ["CLIMATE", "COUNTRY", "ECONOMY", "GAMEPLAY"][d]
		print("[B11] %-9s cell %d: %.8f -> %.8f  moved=%s"
			% [domain_name, TOUCHED, float(before[d]), after, str(moved)])
		if d == DOMAIN_ECONOMY:
			# The one domain that must see it.
			_expect("B11: ECONOMY sees the derived contribution", moved,
				"%.8f -> %.8f" % [float(before[d]), after])
			_expect("B11: ECONOMY moved by exactly the installed delta",
				absf(after - float(before[d]) - 0.25) <= 1e-6,
				"delta=%.8f" % (after - float(before[d])))
		else:
			# Same stat, same cell handle, different domain -> must be untouched.
			_expect("B11: %s does NOT see the cell contribution" % domain_name, not moved,
				"%.8f -> %.8f" % [float(before[d]), after])

	# And the "no group" read (group 0) must also be unaffected outside ECONOMY, which is
	# the shape the COUNTRY-domain bulk readers use.
	var bulk: float = _read(ext, DOMAIN_COUNTRY, 0)
	var bulk_before := float(before[DOMAIN_COUNTRY])
	print("[B11] COUNTRY group=0 (bulk shape): %.8f -> %.8f" % [bulk_before, bulk])
	_expect("B11: the COUNTRY bulk read is unaffected",
		absf(bulk - bulk_before) <= 1e-9, "%.8f -> %.8f" % [bulk_before, bulk])

	_finish(0 if _failures == 0 else 3)


func _finish(code: int) -> void:
	print("=== B11 domain gate: %d checks, %d failures ===" % [_checks, _failures])
	quit(code)
