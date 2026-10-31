extends SceneTree
## ADR02 executed proof (plan 22 §15.3 / M0-4 carried item).
##
## M0-4 could only prove ADR02 from source: `apply_pod_snapshot` rebuilds
## `_stores` from a fresh array (`modifier_runtime.cpp:459-557`) and clears
## `_pending_commands` (`:558`), so a derived row housed in a Store would be
## wiped. Reaching that path needs ACTIVE worker authority plus a committed
## semantic day, which M0-4 could not drive.
##
## M1 removes that obstacle: the derived layer is now a sibling member
## (`_derived_cell_front`), and `install_derived_cell_layer` / the report accessor
## are bound, so this fixture can install a front and then force whatever store
## churn is reachable from GDScript -- proving the layer survives it.
##
## What this does NOT prove: that the layer survives a full worker day commit.
## That still needs the worker harness (M1 precondition), so the assertion here
## is scoped to the store-rebuild path that ADR02 actually names.
##
## Run:
##   <godot> --headless --path Project/project-keynes \
##     -s tests/ideology/ideology_cell_layer_adr02_test.gd

const ModifierCatalogScript = preload("res://scripts/modifier/modifier_catalog.gd")
const CountryCatalogScript = preload("res://scripts/economy/economy_catalog.gd")

const CELLS := 256

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
	var configured: Dictionary = ext.configure_modifiers(catalog, CELLS)
	if not bool(configured.get("ok", false)):
		_expect("modifiers configure", false, str(configured))
		_finish(2)
		return

	# A stat the layer will carry. `economy.city.birth_factor` exists in the
	# catalog and is one of the reader family's keys.
	var stat_id := 0
	var report_before: Dictionary = ext.get_derived_cell_layer_report()
	_expect("layer reports before install", bool(report_before.get("ok", false)),
		str(report_before))
	_expect("layer starts empty",
		not bool(report_before.get("installed", true)), str(report_before))

	# Install a small front: 4 cells on one stat.
	var stat_ids := PackedInt32Array()
	var cells := PackedInt32Array()
	var sources := PackedInt64Array()
	var adds := PackedFloat64Array()
	var factors := PackedFloat64Array()
	for cell in [3, 17, 42, 200]:
		stat_ids.append(stat_id)
		cells.append(cell)
		sources.append(0xA00000001)
		adds.append(0.25)
		factors.append(1.0)

	var install: Dictionary = ext.install_derived_cell_layer_for_test({
		"stat_ids": stat_ids,
		"cells": cells,
		"source_countries": sources,
		"adds": adds,
		"factors": factors,
		"world_identity": 7,
		"map_generation": 11,
		"sample_day": 33,
		"epoch_id": 5,
		"execution_contract_hash": 99,
		"expected_generation": 0,
	})
	_expect("front installs", bool(install.get("installed", false)), str(install))
	var generation_after_install := int(install.get("layer_generation", -1))
	_expect("install bumps the layer generation", generation_after_install > 0,
		str(generation_after_install))

	var report_after: Dictionary = ext.get_derived_cell_layer_report()
	_expect("layer reports installed", bool(report_after.get("installed", false)),
		str(report_after))
	_expect("layer carries 4 cells", int(report_after.get("cell_count", 0)) == 4,
		str(report_after))
	_expect("layer carries 1 stat", int(report_after.get("stat_count", 0)) == 1,
		str(report_after))
	_expect("layer carries the sample day",
		int(report_after.get("sample_day", -1)) == 33, str(report_after))

	# ── The ADR02 assertion ────────────────────────────────────────────────
	# Force whatever store churn is reachable. `clear_modifier_domain` goes
	# through `clear_domain`, which resizes and resets every Store column -- the
	# same destructive shape `apply_pod_snapshot` performs wholesale.
	var cleared: Dictionary = ext.clear_modifier_domain(2)  # ECONOMY
	_expect("economy modifier domain clears", bool(cleared.get("ok", false)),
		str(cleared))

	var report_after_clear: Dictionary = ext.get_derived_cell_layer_report()
	_expect("ADR02: derived layer SURVIVES a store rebuild",
		bool(report_after_clear.get("installed", false)),
		"layer was wiped by clear_modifier_domain: %s" % str(report_after_clear))
	_expect("ADR02: derived cell count is unchanged after the rebuild",
		int(report_after_clear.get("cell_count", -1)) == 4,
		str(report_after_clear))
	_expect("ADR02: layer generation does not move on a store rebuild",
		int(report_after_clear.get("layer_generation", -2)) == generation_after_install,
		str(report_after_clear))

	# Idempotence (plan I13): installing the identical front again is a no-op and
	# must not bump the generation.
	var repeat: Dictionary = ext.install_derived_cell_layer_for_test({
		"stat_ids": stat_ids,
		"cells": cells,
		"source_countries": sources,
		"adds": adds,
		"factors": factors,
		"world_identity": 7,
		"map_generation": 11,
		"sample_day": 33,
		"epoch_id": 5,
		"execution_contract_hash": 99,
		"expected_generation": generation_after_install,
	})
	_expect("identical re-install is accepted", bool(repeat.get("ok", false)),
		str(repeat))
	_expect("I13: identical re-install does not bump the generation",
		int(repeat.get("layer_generation", -2)) == generation_after_install,
		str(repeat))

	# §9.6: a candidate built against an older front must be refused.
	var stale: Dictionary = ext.install_derived_cell_layer_for_test({
		"stat_ids": PackedInt32Array([stat_id]),
		"cells": PackedInt32Array([5]),
		"source_countries": PackedInt64Array([1]),
		"adds": PackedFloat64Array([0.5]),
		"factors": PackedFloat64Array([1.0]),
		"world_identity": 7,
		"map_generation": 11,
		"sample_day": 33,
		"epoch_id": 5,
		"execution_contract_hash": 99,
		"expected_generation": generation_after_install + 99,
	})
	_expect("§9.6: stale generation is rejected",
		not bool(stale.get("installed", true)), str(stale))
	_expect("§9.6: rejection names the stale generation",
		String(stale.get("reason", "")) == "derived_cell_layer_stale_generation",
		str(stale))

	# §9.6: a mismatched world identity must be refused.
	var wrong_world: Dictionary = ext.install_derived_cell_layer_for_test({
		"stat_ids": PackedInt32Array([stat_id]),
		"cells": PackedInt32Array([6]),
		"source_countries": PackedInt64Array([1]),
		"adds": PackedFloat64Array([0.5]),
		"factors": PackedFloat64Array([1.0]),
		"world_identity": 999,
		"map_generation": 11,
		"sample_day": 33,
		"epoch_id": 5,
		"execution_contract_hash": 99,
		"expected_generation": 0,
	})
	_expect("§9.6: foreign world identity is rejected",
		not bool(wrong_world.get("installed", true)), str(wrong_world))
	_expect("§9.6: rejection names the identity mismatch",
		String(wrong_world.get("reason", "")) == "derived_cell_layer_identity_mismatch",
		str(wrong_world))

	# The rejected candidates must not have disturbed the live front.
	var final_report: Dictionary = ext.get_derived_cell_layer_report()
	_expect("a rejected candidate leaves the live front intact",
		int(final_report.get("cell_count", -1)) == 4, str(final_report))

	_finish(0 if _failures == 0 else 3)


func _finish(code: int) -> void:
	print("=== cell layer adr02: %d checks, %d failures ===" % [_checks, _failures])
	quit(code)
