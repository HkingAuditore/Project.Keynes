extends SceneTree

## Focused PKCN v16 capital coverage: bootstrap, default fallback, invalid
## capital rejection, CREATE_COUNTRY, and save/restore.

const EconomyCatalogScript = preload("res://scripts/economy/economy_catalog.gd")

var _checks := 0
var _failures := 0


func _init() -> void:
	_run()
	print("country capital: %d checks, %d failures" % [_checks, _failures])
	quit(0 if _failures == 0 else 1)


func _run() -> void:
	if not ClassDB.class_exists("DCWorldExt"):
		print("[SKIP] DCWorldExt unavailable")
		return
	var compiled: Dictionary = EconomyCatalogScript.compile_native_catalog()
	_expect("catalog compiles", bool(compiled.get("ok", false)))
	if not bool(compiled.get("ok", false)):
		return
	var catalog := compiled.duplicate(true)
	catalog.erase("ok")
	var profile := {
		"country_runtime_mode": "ACTIVE",
		"starting_technology_ids": PackedStringArray(),
	}
	var water := PackedByteArray([0, 0, 0, 0])

	var ext := _new_ext(4)
	_expect("country configures", bool(ext.configure_country(
		catalog, profile, 4, 11).get("ok", false)))
	var packet := {
		"country_ids": PackedStringArray(["country.alpha", "country.beta"]),
		"country_names": PackedStringArray(["Alpha", "Beta"]),
		"country_cash": PackedInt64Array([0, 0]),
		"territory_offsets": PackedInt32Array([0, 2, 4]),
		"territory_cells": PackedInt32Array([0, 1, 2, 3]),
		"capital_cells": PackedInt32Array([1, 2]),
	}
	_expect("bootstrap with explicit capitals", bool(ext.bootstrap_country(
		packet, water).get("ok", false)))
	var alpha_handle := int(ext.get_country_cell_summary(1).get("country_handle", 0))
	var beta_handle := int(ext.get_country_cell_summary(2).get("country_handle", 0))
	_expect("alpha capital is its start cell",
		int((ext.get_country_snapshot(alpha_handle) as Dictionary).get(
			"capital_cell", -99)) == 1)
	_expect("beta capital is its start cell",
		int((ext.get_country_snapshot(beta_handle) as Dictionary).get(
			"capital_cell", -99)) == 2)

	# Omitted capital_cells falls back to each country's first territory cell.
	var fallback_ext := _new_ext(4)
	fallback_ext.configure_country(catalog, profile, 4, 12)
	var fallback_packet := packet.duplicate(true)
	fallback_packet.erase("capital_cells")
	_expect("bootstrap without capitals falls back", bool(
		fallback_ext.bootstrap_country(fallback_packet, water).get("ok", false)))
	var fallback_alpha := int(fallback_ext.get_country_cell_summary(1).get(
		"country_handle", 0))
	_expect("omitted capital defaults to the first territory cell",
		int((fallback_ext.get_country_snapshot(fallback_alpha) as Dictionary).get(
			"capital_cell", -99)) == 0)

	# A capital must be a land cell owned by that country at bootstrap time.
	var invalid_ext := _new_ext(4)
	invalid_ext.configure_country(catalog, profile, 4, 13)
	var invalid_packet := packet.duplicate(true)
	invalid_packet.capital_cells = PackedInt32Array([3, 2])
	_expect("capital outside the country's territory is rejected",
		String(invalid_ext.bootstrap_country(invalid_packet, water).get(
			"reason", "")) == "country_bootstrap_capital_invalid")

	# CREATE_COUNTRY sets the new country's capital to the seized cell.
	var create := _commands([{
		"opcode": 1, "day": 0, "sequence": 1, "handle": 0,
		"cell": 1, "aux": -1, "stable_id": "country.gamma", "name": "Gamma",
	}])
	_expect("create command queues", bool(ext.submit_country_commands(
		create).get("ok", false)))
	_expect("create command commits", bool(ext.run_country_slice(
		{"day_index": 0}).get("ok", false)))
	var gamma_handle := int(ext.get_country_cell_summary(1).get(
		"country_handle", 0))
	_expect("created country capital is the seized cell",
		int((ext.get_country_snapshot(gamma_handle) as Dictionary).get(
			"capital_cell", -99)) == 1)

	# PKCN round-trip preserves capitals and the state hash.
	_expect("PKCN save begins", bool(ext.begin_country_save(4096).get(
		"ok", false)))
	var chunks: Array[PackedByteArray] = []
	while true:
		var chunk: PackedByteArray = ext.read_country_save_chunk(4096)
		if chunk.is_empty():
			break
		chunks.append(chunk)
	_expect("PKCN save ends", bool(ext.end_country_save().get("ok", false)))
	var restored := _new_ext(4)
	restored.configure_country(catalog, profile, 4, 11)
	restored.bootstrap_country(packet, water)
	restored.begin_country_restore()
	for chunk in chunks:
		restored.feed_country_restore_chunk(chunk)
	_expect("PKCN restore succeeds", bool(restored.end_country_restore().get(
		"ok", false)))
	_expect("PKCN round-trip preserves the country state hash",
		int(ext.get_country_state_hash()) == int(restored.get_country_state_hash()))
	var restored_alpha := int(restored.get_country_cell_summary(0).get(
		"country_handle", 0))
	_expect("PKCN round-trip preserves capitals",
		int((restored.get_country_snapshot(restored_alpha) as Dictionary).get(
			"capital_cell", -99)) == 1)


func _new_ext(cells: int) -> Object:
	var ext: Object = ClassDB.instantiate("DCWorldExt")
	ext.create_entities(cells)
	return ext


func _commands(rows: Array[Dictionary]) -> Dictionary:
	var out := {"opcodes": PackedInt32Array(), "effective_days": PackedInt64Array(),
		"sequences": PackedInt64Array(), "target_handles": PackedInt64Array(),
		"cell_indices": PackedInt32Array(), "aux_i32": PackedInt32Array(),
		"domain_i32": PackedInt32Array(), "position_i32": PackedInt32Array(),
		"weight0_bp": PackedInt32Array(), "weight1_bp": PackedInt32Array(),
		"weight2_bp": PackedInt32Array(), "weight3_bp": PackedInt32Array(),
		"value_i64": PackedInt64Array(), "tax_kinds": PackedInt32Array(),
		"tax_item_indices": PackedInt32Array(),
		"tax_rate_basis_points": PackedInt32Array(),
		"tax_assessment_modes": PackedInt32Array(),
		"tax_rate_percent": PackedInt32Array(),
		"stable_ids": PackedStringArray(), "display_names": PackedStringArray()}
	for row in rows:
		out.opcodes.append(int(row.opcode))
		out.effective_days.append(int(row.day))
		out.sequences.append(int(row.sequence))
		out.target_handles.append(int(row.handle))
		out.cell_indices.append(int(row.cell))
		out.aux_i32.append(int(row.aux))
		out.domain_i32.append(int(row.get("domain", -1)))
		out.position_i32.append(int(row.get("position", -1)))
		out.weight0_bp.append(0)
		out.weight1_bp.append(0)
		out.weight2_bp.append(0)
		out.weight3_bp.append(0)
		out.value_i64.append(int(row.get("value", 0)))
		out.tax_kinds.append(-1)
		out.tax_item_indices.append(-1)
		out.tax_rate_basis_points.append(0)
		out.tax_assessment_modes.append(0)
		out.tax_rate_percent.append(0)
		out.stable_ids.append(String(row.get("stable_id", "")))
		out.display_names.append(String(row.get("name", "")))
	return out


func _expect(label: String, condition: bool) -> void:
	_checks += 1
	if condition:
		print("  [OK] %s" % label)
	else:
		_failures += 1
		print("  [FAIL] %s" % label)
