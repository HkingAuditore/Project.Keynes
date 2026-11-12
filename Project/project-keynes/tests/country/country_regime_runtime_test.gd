extends SceneTree

const EconomyCatalogScript = preload("res://scripts/economy/economy_catalog.gd")

var _failures := 0

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	if not ClassDB.class_exists("DCWorldExt"):
		print("[SKIP] DCWorldExt unavailable")
		quit(0)
		return
	var catalog: Dictionary = EconomyCatalogScript.compile_native_catalog()
	_expect("economy catalog compiles", bool(catalog.get("ok", false)))
	if not bool(catalog.get("ok", false)):
		quit(1)
		return
	catalog = catalog.duplicate(true)
	catalog.erase("ok")
	catalog["political_regime_ids"] = PackedStringArray(["local_council", "early_clan"])
	catalog["political_regime_capability_bits"] = PackedInt32Array([0, 1])
	catalog["political_regime_catalog_hash"] = 99173
	var ext: Object = ClassDB.instantiate("DCWorldExt")
	ext.create_entities(2)
	var profile := {"country_runtime_mode": "ACTIVE"}
	_expect("country configures with regime catalog",
		bool(ext.configure_country(catalog, profile, 2, 41).get("ok", false)))
	var packet := {
		"country_ids": PackedStringArray(["country.regime"]),
		"country_names": PackedStringArray(["体制测试国"]),
		"regime_ids": PackedStringArray(["early_clan"]),
		"territory_offsets": PackedInt32Array([0, 1]),
		"territory_cells": PackedInt32Array([0]),
	}
	_expect("bootstrap accepts regime id",
		bool(ext.bootstrap_country(packet, PackedByteArray([0, 0])).get("ok", false)))
	var handle := int(ext.get_country_cell_summary(0).get("country_handle", 0))
	var initial: Dictionary = ext.get_country_political_regime_snapshot(handle)
	_expect("early clan exposes treasury construction",
		String(initial.get("regime_key", "")) == "early_clan"
		and (int(initial.get("capability_bits", 0)) & 1) != 0)
	var command := _command(28, handle, 1, "local_council")
	_expect("regime switch queues", bool(ext.submit_country_commands(command).get("ok", false)))
	_expect("regime switch commits at country boundary",
		bool(ext.run_country_slice({"day_index": 1}).get("ok", false)))
	var switched: Dictionary = ext.get_country_political_regime_snapshot(handle)
	_expect("local council removes treasury construction",
		String(switched.get("regime_key", "")) == "local_council"
		and int(switched.get("capability_bits", 0)) == 0)
	var invalid := _command(28, handle, 2, "unknown_regime")
	_expect("unknown regime is rejected", not bool(ext.submit_country_commands(invalid).get("ok", false)))
	print("country regime: %d failures" % _failures)
	quit(0 if _failures == 0 else 1)

func _command(opcode: int, handle: int, day: int, stable_id: String) -> Dictionary:
	return {
		"opcodes": PackedInt32Array([opcode]),
		"effective_days": PackedInt64Array([day]),
		"sequences": PackedInt64Array([day]),
		"target_handles": PackedInt64Array([handle]),
		"cell_indices": PackedInt32Array([-1]),
		"aux_i32": PackedInt32Array([-1]),
		"domain_i32": PackedInt32Array([-1]),
		"position_i32": PackedInt32Array([-1]),
		"weight0_bp": PackedInt32Array([0]), "weight1_bp": PackedInt32Array([0]),
		"weight2_bp": PackedInt32Array([0]), "weight3_bp": PackedInt32Array([0]),
		"value_i64": PackedInt64Array([0]),
		"tax_kinds": PackedInt32Array([-1]), "tax_item_indices": PackedInt32Array([-1]),
		"tax_rate_basis_points": PackedInt32Array([0]),
		"tax_assessment_modes": PackedInt32Array([0]),
		"stable_ids": PackedStringArray([stable_id]),
		"display_names": PackedStringArray([""]),
	}

func _expect(label: String, condition: bool) -> void:
	if not condition:
		_failures += 1
		push_error("[FAIL] %s" % label)
