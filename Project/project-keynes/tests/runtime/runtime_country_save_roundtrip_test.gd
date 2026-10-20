extends SceneTree

# Country CPD2/PKCN save contract at the real NativeSimulationHost boundary.
# This intentionally uses a tiny direct DCWorldExt setup so the test isolates
# Country persistence from map generation and Economy bootstrap variability.

const EconomyCatalogScript = preload("res://scripts/economy/economy_catalog.gd")
const Header = preload("res://scripts/game/pksr_bundle_header.gd")

const SAVE_POLL_TIMEOUT_MSEC := 5000
const WORKER_STOP_TIMEOUT_MSEC := 5000
const POLL_MSEC := 2

var _checks := 0
var _failures := 0


func _init() -> void:
	var code := await _run()
	print("runtime country save roundtrip: %d checks, %d failures" % [
		_checks, _failures])
	quit(code if code != 0 else (0 if _failures == 0 else 1))


func _run() -> int:
	if not ClassDB.class_exists("DCWorldExt"):
		_expect("DCWorldExt is available", false)
		return 3
	var compiled: Dictionary = EconomyCatalogScript.compile_native_catalog()
	_expect("catalog compiles", bool(compiled.get("ok", false)))
	if not bool(compiled.get("ok", false)):
		return 4
	var catalog := compiled.duplicate(true)
	catalog.erase("ok")

	var ext := DCWorldExt.new()
	ext.create_entities(3)
	var profile := {
		"country_runtime_mode": "ACTIVE",
		"starting_technology_ids": PackedStringArray(["tech.hunting"]),
	}
	_expect("country configures", bool(ext.configure_country(
		catalog, profile, 3, 20260908).get("ok", false)))
	_expect("country bootstraps", bool(ext.bootstrap_country(
		{}, PackedByteArray([0, 0, 0])).get("ok", false)))
	if _failures > 0:
		return 5

	var handle := int(ext.get_country_cell_summary(0).get("country_handle", 0))
	_expect("bootstrap exposes a country handle", handle != 0)
	_expect("saved rename queues", bool(ext.submit_country_commands(_commands([{
		"opcode": 2, "day": 0, "sequence": 1, "handle": handle,
		"name": "Saved Country",
	}])).get("ok", false)))
	_expect("saved rename commits", bool(ext.run_country_slice(
		{"day_index": 0}).get("ok", false)))
	_expect("future rename queues before capture", bool(
		ext.submit_country_commands(_commands([{
			"opcode": 2, "day": 5, "sequence": 2, "handle": handle,
			"name": "Future Country",
		}])).get("ok", false)))

	var expected_checkpoint: Dictionary = ext.capture_country_reference_checkpoint()
	var expected_pkcn: PackedByteArray = expected_checkpoint.get(
		"bytes", PackedByteArray())
	var saved_hash := int(ext.get_country_state_hash())
	var saved_report: Dictionary = ext.get_country_report()
	var saved_generation := int(saved_report.get("generation", -1))
	var saved_day := int(saved_report.get("last_committed_day", -2))
	_expect("direct checkpoint is canonical PKCN v13",
		bool(expected_checkpoint.get("ok", false))
		and int(expected_checkpoint.get("schema_version", 0)) == 13
		and _ascii_magic(expected_pkcn) == "PKCN")

	var started: Dictionary = ext.start_runtime_worker({
		"simulation_thread_mode": "SHADOW",
		"graph_coverage_complete": true,
		"day": saved_day,
		"speed_days_per_second": 1.0,
		"paused": true,
	})
	_expect("SHADOW worker starts for save", bool(started.get("ok", false)))
	if not bool(started.get("ok", false)):
		return 6

	var saved := _capture_bundle(ext, 1)
	_expect("runtime save becomes ready (%s)" % String(
		saved.get("code", "timeout")), bool(saved.get("ready", false)))
	if not bool(saved.get("ready", false)):
		ext.request_runtime_stop()
		return 7
	var bundle: PackedByteArray = saved.get("bytes", PackedByteArray())
	var provider_pkcn: PackedByteArray = saved.get(
		"country_pkcn", PackedByteArray())
	_check_bundle(bundle, saved, provider_pkcn, expected_pkcn)

	ext.request_runtime_stop()
	_expect("worker stops before restore", _await_stopped(ext))

	# Diverge the live synchronous store after capture. A rejected restore must
	# leave this exact state intact; the valid restore must replace it atomically.
	_expect("post-save mutation queues", bool(ext.submit_country_commands(
		_commands([{
			"opcode": 2, "day": 1, "sequence": 3, "handle": handle,
			"name": "Mutated Country",
		}])).get("ok", false)))
	_expect("post-save mutation commits", bool(ext.run_country_slice(
		{"day_index": 1}).get("ok", false)))
	var mutated_hash := int(ext.get_country_state_hash())
	_expect("post-save mutation changes the state hash", mutated_hash != saved_hash)

	var pending: Dictionary = ext.restore_runtime_bundle(bundle)
	_expect("PKSR restore prepares the Country checkpoint (%s)" % String(
		pending.get("code", "unknown")), bool(pending.get("ok", false)))
	if not bool(pending.get("ok", false)):
		return 8

	var wrong_pkcn := provider_pkcn.duplicate()
	if wrong_pkcn.size() > 40:
		wrong_pkcn[40] = (wrong_pkcn[40] + 1) & 0xFF
	var rejected: Dictionary = ext.restore_country_runtime_checkpoint(wrong_pkcn)
	_expect("mismatched PKCN is rejected precisely",
		not bool(rejected.get("ok", true))
		and bool(rejected.get("available", false))
		and String(rejected.get("code", "")) ==
			"country_checkpoint_pkcn_mismatch")
	_expect("rejected restore leaves the live Country unchanged",
		int(ext.get_country_state_hash()) == mutated_hash
		and String(ext.get_country_cell_summary(0).get("country_name", "")) ==
			"Mutated Country")

	var restored: Dictionary = ext.restore_country_runtime_checkpoint(provider_pkcn)
	_expect("matching CPD2/PKCN restores atomically (%s)" % String(
		restored.get("code", "unknown")), bool(restored.get("ok", false)))
	if not bool(restored.get("ok", false)):
		return 9
	var restored_report: Dictionary = ext.get_country_report()
	_expect("Country business hash round-trips exactly",
		int(ext.get_country_state_hash()) == saved_hash
		and int(restored.get("business_state_hash", 0)) == saved_hash)
	_expect("Country generation and day round-trip exactly",
		int(restored_report.get("generation", -1)) == saved_generation
		and int(restored_report.get("last_committed_day", -2)) == saved_day)
	_expect("saved identity is restored",
		String(ext.get_country_cell_summary(0).get("country_name", "")) ==
			"Saved Country")
	var restored_events: Dictionary = ext.poll_country_events(0, 32)
	_expect("pre-save events are not replayed during restore",
		(restored_events.get("event_ids", PackedInt64Array()) as PackedInt64Array).is_empty())

	# Starting consumes the pending PKSR envelope. Re-saving before any Country
	# boundary must preserve the canonical PKCN even though session_epoch changes.
	var restarted: Dictionary = ext.start_runtime_worker({
		"simulation_thread_mode": "SHADOW",
		"graph_coverage_complete": true,
		"day": saved_day,
		"speed_days_per_second": 1.0,
		"paused": true,
	})
	_expect("worker restarts on the restored bundle", bool(
		restarted.get("ok", false)))
	if bool(restarted.get("ok", false)):
		var resaved := _capture_bundle(ext, 2)
		_expect("restored Country can be saved again", bool(
			resaved.get("ready", false)))
		if bool(resaved.get("ready", false)):
			var resaved_pkcn: PackedByteArray = resaved.get(
				"country_pkcn", PackedByteArray())
			_expect("save -> restore -> save keeps canonical PKCN unchanged",
				resaved_pkcn == provider_pkcn)
			_expect("re-saved CPD2 embeds the same canonical PKCN",
				_embedded_pkcn(_country_section(resaved.get(
					"bytes", PackedByteArray()))) == provider_pkcn)
		ext.request_runtime_stop()
		_expect("restarted worker stops", _await_stopped(ext))

	var future_commit: Dictionary = ext.run_country_slice({"day_index": 5})
	_expect("restored future command commits", bool(future_commit.get("ok", false))
		and String(ext.get_country_cell_summary(0).get("country_name", "")) ==
			"Future Country")
	var events: Dictionary = ext.poll_country_events(0, 32)
	var event_ids: PackedInt64Array = events.get(
		"event_ids", PackedInt64Array())
	var display_names: PackedStringArray = events.get(
		"display_names", PackedStringArray())
	_expect("event cursor resumes without replaying the saved rename",
		event_ids.size() == 1 and display_names.size() == 1
		and int(event_ids[0]) >= 2
		and String(display_names[0]) == "Future Country")
	return 0


func _check_bundle(bundle: PackedByteArray, saved: Dictionary,
		provider_pkcn: PackedByteArray, expected_pkcn: PackedByteArray) -> void:
	_expect("PKSR v2 header accepts the Country bundle", Header.valid(bundle, saved))
	_expect("Country section bit 0x8 is present",
		Header.has_country_section(bundle))
	_expect("Country section payload is non-empty",
		int(saved.get("country_bytes", 0)) > 0)
	_expect("Country provider returns PKCN v13",
		provider_pkcn.size() > 32 and _ascii_magic(provider_pkcn) == "PKCN"
		and int(provider_pkcn.decode_u32(4)) == 13)
	_expect("save provider reuses the exact canonical PKCN capture",
		provider_pkcn == expected_pkcn)
	var cpd2 := _country_section(bundle)
	_expect("CPD2 section is locatable and uses ABI v2",
		cpd2.size() >= 104 and _ascii_magic(cpd2) == "CPD2"
		and int(cpd2.decode_u32(4)) == 2
		and int(cpd2.decode_u32(8)) == 13)
	_expect("CPD2 embeds the same canonical PKCN",
		_embedded_pkcn(cpd2) == provider_pkcn)


func _capture_bundle(ext, request_id: int) -> Dictionary:
	var requested: Dictionary = ext.request_runtime_save(request_id)
	if not bool(requested.get("ok", false)):
		return {"ready": false, "code": requested.get("code", "request_failed")}
	var deadline := Time.get_ticks_msec() + SAVE_POLL_TIMEOUT_MSEC
	while Time.get_ticks_msec() < deadline:
		var polled: Dictionary = ext.poll_runtime_save(request_id)
		if bool(polled.get("ready", false)):
			return polled
		if not bool(polled.get("ok", true)):
			return {"ready": false, "code": polled.get("code", "poll_failed")}
		OS.delay_msec(POLL_MSEC)
	return {"ready": false, "code": "save_poll_timeout"}


func _await_stopped(ext) -> bool:
	var deadline := Time.get_ticks_msec() + WORKER_STOP_TIMEOUT_MSEC
	while Time.get_ticks_msec() < deadline:
		if String(ext.get_runtime_thread_report().get(
				"simulation_host_state", "")) == "STOPPED":
			return true
		OS.delay_msec(POLL_MSEC)
	return false


func _country_section(bundle: PackedByteArray) -> PackedByteArray:
	const marker := 0x32445043 # "CPD2" little-endian.
	var cursor := Header.OFFSET_SECTION_MASK + 4
	while cursor + 24 <= bundle.size():
		if int(bundle.decode_u32(cursor)) == marker:
			var size := int(bundle.decode_u32(cursor + 4))
			var payload := cursor + 8
			if size >= 104 and payload + size + 16 <= bundle.size() \
					and int(bundle.decode_u32(payload)) == marker:
				return bundle.slice(payload, payload + size)
		cursor += 1
	return PackedByteArray()


func _embedded_pkcn(cpd2: PackedByteArray) -> PackedByteArray:
	const payload_size_offset := 80
	const payload_offset := 92
	if cpd2.size() < payload_offset:
		return PackedByteArray()
	var size := int(cpd2.decode_u32(payload_size_offset))
	if size <= 0 or payload_offset + size + 8 > cpd2.size():
		return PackedByteArray()
	return cpd2.slice(payload_offset, payload_offset + size)


func _ascii_magic(bytes: PackedByteArray) -> String:
	return bytes.slice(0, mini(4, bytes.size())).get_string_from_ascii()


func _commands(rows: Array[Dictionary]) -> Dictionary:
	var out := {
		"opcodes": PackedInt32Array(), "effective_days": PackedInt64Array(),
		"sequences": PackedInt64Array(), "target_handles": PackedInt64Array(),
		"cell_indices": PackedInt32Array(), "aux_i32": PackedInt32Array(),
		"domain_i32": PackedInt32Array(), "position_i32": PackedInt32Array(),
		"weight0_bp": PackedInt32Array(), "weight1_bp": PackedInt32Array(),
		"weight2_bp": PackedInt32Array(), "weight3_bp": PackedInt32Array(),
		"value_i64": PackedInt64Array(), "tax_kinds": PackedInt32Array(),
		"tax_item_indices": PackedInt32Array(),
		"tax_rate_basis_points": PackedInt32Array(),
		"tax_assessment_modes": PackedInt32Array(),
		"stable_ids": PackedStringArray(), "display_names": PackedStringArray(),
	}
	for row: Dictionary in rows:
		out.opcodes.append(int(row.get("opcode", 0)))
		out.effective_days.append(int(row.get("day", 0)))
		out.sequences.append(int(row.get("sequence", 0)))
		out.target_handles.append(int(row.get("handle", 0)))
		out.cell_indices.append(int(row.get("cell", -1)))
		out.aux_i32.append(int(row.get("aux", -1)))
		out.domain_i32.append(int(row.get("domain", -1)))
		out.position_i32.append(int(row.get("position", -1)))
		var weights: PackedInt32Array = row.get(
			"weights", PackedInt32Array([0, 0, 0, 0]))
		out.weight0_bp.append(weights[0])
		out.weight1_bp.append(weights[1])
		out.weight2_bp.append(weights[2])
		out.weight3_bp.append(weights[3])
		out.value_i64.append(int(row.get("value", 0)))
		out.tax_kinds.append(int(row.get("tax_kind", -1)))
		out.tax_item_indices.append(int(row.get("tax_item", -1)))
		out.tax_rate_basis_points.append(int(row.get("tax_rate_bp", 0)))
		out.tax_assessment_modes.append(int(row.get("tax_mode", 0)))
		out.stable_ids.append(String(row.get("stable_id", "")))
		out.display_names.append(String(row.get("name", "")))
	return out


func _expect(label: String, condition: bool) -> void:
	_checks += 1
	if condition:
		print("  [OK] %s" % label)
	else:
		_failures += 1
		push_error("[FAIL] " + label)
