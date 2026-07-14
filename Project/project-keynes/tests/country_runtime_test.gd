extends SceneTree

const EconomyCatalogScript = preload("res://scripts/economy/economy_catalog.gd")

var _checks := 0
var _failures := 0

func _init() -> void:
	_run()
	print("country runtime: %d checks, %d failures" % [_checks, _failures])
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
	var technologies: PackedStringArray = compiled.technology_ids
	var goods: PackedStringArray = compiled.good_ids
	var grain := goods.find("grain")
	var hunting := technologies.find("tech.hunting")
	var autonomous_systems := technologies.find("tech.autonomous_systems")
	var profile := {"country_runtime_mode": "ACTIVE",
		"starting_technology_ids": PackedStringArray(["tech.hunting"])}
	var default_ext := _new_ext(3)
	_expect("default country configures", bool(default_ext.configure_country(catalog, profile, 3, 7).get("ok", false)))
	_expect("default country owns every land cell",
		bool(default_ext.bootstrap_country({}, PackedByteArray([0, 1, 0])).get("ok", false)) and
		String(default_ext.get_country_cell_summary(0).country_id) == "country.default" and
		int(default_ext.get_country_cell_summary(1).country_slot) == -1 and
		String(default_ext.get_country_cell_summary(2).country_id) == "country.default")
	var water_ext := _new_ext(2)
	water_ext.configure_country(catalog, profile, 2, 8)
	_expect("all-water default bootstrap is rejected precisely",
		String(water_ext.bootstrap_country({}, PackedByteArray([1, 1])).get("reason", "")) ==
		"country_bootstrap_no_land")
	var water := PackedByteArray([0, 0, 0, 1])
	var packet := {
		"country_ids": PackedStringArray(["country.alpha"]),
		"country_names": PackedStringArray(["阿尔法"]),
		"country_cash": PackedInt64Array([100000]),
		"territory_offsets": PackedInt32Array([0, 2]),
		"territory_cells": PackedInt32Array([0, 1]),
		"technology_offsets": PackedInt32Array([0, 1]),
		"technology_indices": PackedInt32Array([hunting]),
		"treasury_offsets": PackedInt32Array([0, 1]),
		"treasury_good_indices": PackedInt32Array([grain]),
		"treasury_quantities": PackedInt64Array([5000]),
	}
	var duplicate_packet := packet.duplicate(true)
	duplicate_packet.country_ids = PackedStringArray(["country.alpha", "country.beta"])
	duplicate_packet.country_names = PackedStringArray(["Alpha", "Beta"])
	duplicate_packet.country_cash = PackedInt64Array([0, 0])
	duplicate_packet.territory_offsets = PackedInt32Array([0, 1, 2])
	duplicate_packet.territory_cells = PackedInt32Array([0, 0])
	duplicate_packet.technology_offsets = PackedInt32Array([0, 0, 0])
	duplicate_packet.technology_indices = PackedInt32Array()
	duplicate_packet.treasury_offsets = PackedInt32Array([0, 0, 0])
	duplicate_packet.treasury_good_indices = PackedInt32Array()
	duplicate_packet.treasury_quantities = PackedInt64Array()
	var duplicate_ext := _new_ext(4)
	duplicate_ext.configure_country(catalog, profile, 4, 99)
	_expect("duplicate territory bootstrap is rejected precisely",
		String(duplicate_ext.bootstrap_country(duplicate_packet, water).get("reason", "")) ==
		"country_bootstrap_duplicate_territory")
	var water_packet := packet.duplicate(true)
	water_packet.territory_cells = PackedInt32Array([0, 3])
	var owned_water_ext := _new_ext(4)
	owned_water_ext.configure_country(catalog, profile, 4, 99)
	_expect("water territory bootstrap is rejected precisely",
		String(owned_water_ext.bootstrap_country(water_packet, water).get("reason", "")) ==
		"country_bootstrap_water_owned")
	var ext := _new_ext(4)
	_expect("country configures", bool(ext.configure_country(catalog, profile, 4, 99).get("ok", false)))
	_expect("explicit country bootstraps", bool(ext.bootstrap_country(packet, water).get("ok", false)))
	var alpha: Dictionary = ext.get_country_cell_summary(0)
	_expect("single owner and neutral land are represented",
		String(alpha.country_id) == "country.alpha" and
		int(ext.get_country_cell_summary(2).country_slot) == -1 and
		int(ext.get_country_cell_summary(3).country_slot) == -1)
	_expect("country treasury is sparse and scaled",
		int(ext.get_country_treasury_snapshot(alpha.country_handle).quantities[0]) == 5000)

	var create := _commands([{
		"opcode": 1, "day": 0, "sequence": 1, "handle": 0,
		"cell": 1, "aux": -1, "stable_id": "country.beta", "name": "贝塔",
	}])
	_expect("create command queues", bool(ext.submit_country_commands(create).get("ok", false)))
	var create_report: Dictionary = ext.run_country_slice({"day_index": 0})
	_expect("create atomically transfers first territory",
		bool(create_report.get("ok", false)) and int(create_report.changed_cells) == 1)
	var beta: Dictionary = ext.get_country_cell_summary(1)
	_expect("new country inherits source technology",
		(ext.get_country_snapshot(beta.country_handle).technology_ids as PackedStringArray).has("tech.hunting"))

	var last_land := _commands([{
		"opcode": 3, "day": 1, "sequence": 1, "handle": 0,
		"cell": 0, "aux": -1, "stable_id": "", "name": "",
	}])
	ext.submit_country_commands(last_land)
	var rejected: Dictionary = ext.run_country_slice({"day_index": 1})
	_expect("last territory is protected", not bool(rejected.get("ok", true)) and
		String(rejected.get("fatal_reason", "")) == "country_last_territory_protected")

	var rename_and_tech := _commands([
		{"opcode": 2, "day": 2, "sequence": 1, "handle": beta.country_handle,
			"cell": -1, "aux": -1, "stable_id": "", "name": "贝塔共和国"},
		{"opcode": 4, "day": 2, "sequence": 2, "handle": beta.country_handle,
			"cell": -1, "aux": autonomous_systems, "stable_id": "", "name": ""},
	])
	ext.submit_country_commands(rename_and_tech)
	_expect("rename and country technology commit", bool(ext.run_country_slice({"day_index": 2}).get("ok", false)))
	var beta_after: Dictionary = ext.get_country_snapshot(beta.country_handle)
	_expect("country-wide metadata query reflects commit",
		String(beta_after.country_name) == "贝塔共和国" and
		(beta_after.technology_ids as PackedStringArray).has("tech.autonomous_systems"))

	var continuation_profile := profile.duplicate(true)
	continuation_profile.country_max_commands_per_slice = 1
	var continuation_packet := packet.duplicate(true)
	continuation_packet.territory_offsets = PackedInt32Array([0, 4])
	continuation_packet.territory_cells = PackedInt32Array([0, 1, 2, 3])
	var continuation_ext := _new_ext(4)
	continuation_ext.configure_country(catalog, continuation_profile, 4, 123)
	continuation_ext.bootstrap_country(continuation_packet, PackedByteArray([0, 0, 0, 0]))
	var continuation_alpha: Dictionary = continuation_ext.get_country_cell_summary(0)
	continuation_ext.submit_country_commands(_commands([{
		"opcode": 1, "day": 0, "sequence": 1, "handle": 0,
		"cell": 3, "aux": -1, "stable_id": "country.beta", "name": "Beta",
	}]))
	continuation_ext.run_country_slice({"day_index": 0})
	var continuation_beta: Dictionary = continuation_ext.get_country_cell_summary(3)
	var hash_before_continuation := int(continuation_ext.get_country_state_hash())
	continuation_ext.submit_country_commands(_commands([
		{"opcode": 3, "day": 1, "sequence": 1, "handle": continuation_beta.country_handle,
			"cell": 0, "aux": -1, "stable_id": "", "name": ""},
		{"opcode": 3, "day": 1, "sequence": 2, "handle": continuation_beta.country_handle,
			"cell": 1, "aux": -1, "stable_id": "", "name": ""},
	]))
	var continuation_first: Dictionary = continuation_ext.run_country_slice({"day_index": 1})
	_expect("cross-slice country batch keeps committed state private",
		not bool(continuation_first.get("done", true)) and
		bool(continuation_first.get("country_day_barrier", false)) and
		int(continuation_ext.get_country_state_hash()) == hash_before_continuation and
		int(continuation_ext.get_country_cell_summary(0).country_handle) == int(continuation_alpha.country_handle))
	var continuation_second: Dictionary = continuation_ext.run_country_slice({"day_index": 1})
	_expect("cross-slice country batch publishes atomically on final slice",
		bool(continuation_second.get("done", false)) and
		int(continuation_ext.get_country_cell_summary(0).country_handle) == int(continuation_beta.country_handle) and
		int(continuation_ext.get_country_cell_summary(1).country_handle) == int(continuation_beta.country_handle))

	var save_begin: Dictionary = ext.begin_country_save(4096)
	_expect("PKCN v1 begins", bool(save_begin.get("ok", false)) and int(save_begin.schema_version) == 1)
	var chunks: Array[PackedByteArray] = []
	while true:
		var chunk: PackedByteArray = ext.read_country_save_chunk(4096)
		if chunk.is_empty(): break
		chunks.append(chunk)
	_expect("PKCN stream ends", bool(ext.end_country_save().get("ok", false)))
	var restored := _new_ext(4)
	restored.configure_country(catalog, profile, 4, 99)
	restored.bootstrap_country(packet, water)
	restored.begin_country_restore()
	for chunk in chunks: restored.feed_country_restore_chunk(chunk)
	_expect("PKCN round-trip hash exact", bool(restored.end_country_restore().get("ok", false)) and
		ext.get_country_state_hash() == restored.get_country_state_hash())
	if not chunks.is_empty():
		var truncated := _new_ext(4)
		truncated.configure_country(catalog, profile, 4, 99)
		truncated.bootstrap_country(packet, water)
		truncated.begin_country_restore()
		var partial: PackedByteArray = chunks[0].slice(0, maxi(1, chunks[0].size() / 2))
		truncated.feed_country_restore_chunk(partial)
		_expect("truncated PKCN stream is rejected",
			not bool(truncated.end_country_restore().get("ok", true)))
	var mismatched_catalog := catalog.duplicate(true)
	var reduced_technologies: PackedStringArray = mismatched_catalog.technology_ids
	reduced_technologies.remove_at(reduced_technologies.size() - 1)
	mismatched_catalog.technology_ids = reduced_technologies
	var mismatched := _new_ext(4)
	mismatched.configure_country(mismatched_catalog, profile, 4, 99)
	mismatched.bootstrap_country(packet, water)
	mismatched.begin_country_restore()
	for chunk in chunks: mismatched.feed_country_restore_chunk(chunk)
	_expect("PKCN catalog mismatch is rejected precisely",
		String(mismatched.end_country_restore().get("reason", "")) ==
		"country_save_catalog_or_shape_mismatch")

func _new_ext(cells: int) -> Object:
	var ext: Object = ClassDB.instantiate("DCWorldExt")
	ext.create_entities(cells)
	return ext

func _commands(rows: Array[Dictionary]) -> Dictionary:
	var out := {"opcodes": PackedInt32Array(), "effective_days": PackedInt64Array(),
		"sequences": PackedInt64Array(), "target_handles": PackedInt64Array(),
		"cell_indices": PackedInt32Array(), "aux_i32": PackedInt32Array(),
		"stable_ids": PackedStringArray(), "display_names": PackedStringArray()}
	for row in rows:
		out.opcodes.append(int(row.opcode))
		out.effective_days.append(int(row.day))
		out.sequences.append(int(row.sequence))
		out.target_handles.append(int(row.handle))
		out.cell_indices.append(int(row.cell))
		out.aux_i32.append(int(row.aux))
		out.stable_ids.append(String(row.stable_id))
		out.display_names.append(String(row.name))
	return out

func _expect(label: String, condition: bool) -> void:
	_checks += 1
	if condition:
		print("  [OK] %s" % label)
	else:
		_failures += 1
		push_error("[FAIL] %s" % label)
