extends SceneTree

const EconomyCatalogScript = preload("res://scripts/economy/economy_catalog.gd")

var _checks := 0
var _failures := 0


func _init() -> void:
	_run()
	print("country reference trace: %d checks, %d failures" % [_checks, _failures])
	quit(0 if _failures == 0 else 1)


func _run() -> void:
	if not ClassDB.class_exists("DCWorldExt"):
		_fail("DCWorldExt unavailable")
		return
	var compiled: Dictionary = EconomyCatalogScript.compile_native_catalog()
	_expect("catalog compiles", bool(compiled.get("ok", false)))
	if not bool(compiled.get("ok", false)):
		return
	var catalog := compiled.duplicate(true)
	catalog.erase("ok")
	var first := _run_transcript(catalog)
	var second := _run_transcript(catalog)
	_expect("reference transcript completes", bool(first.get("ok", false))
		and bool(second.get("ok", false)))
	if not bool(first.get("ok", false)) or not bool(second.get("ok", false)):
		return
	var first_frames: Array = first.frames
	var second_frames: Array = second.frames
	_expect("bootstrap, command, and idle boundaries are captured",
		first_frames.size() == 3 and second_frames.size() == 3)
	if first_frames.size() != 3 or second_frames.size() != 3:
		return
	_expect("bootstrap frame is an explicit semantic commit",
		String(first_frames[0].stage) == "bootstrap"
		and bool(first_frames[0].semantic_commit)
		and int(first_frames[0].day) == -1)
	_expect("command boundary records the admitted command",
		String(first_frames[1].stage) == "aggregate_publish"
		and int(first_frames[1].command_count) == 1
		and int(first_frames[1].command_watermark) == 1
		and int(first_frames[1].command_hash) != 0)
	_expect("per-family hashes are populated",
		int(first_frames[1].identity_hash) != 0
		and int(first_frames[1].territory_hash) != 0
		and int(first_frames[1].treasury_hash) != 0
		and int(first_frames[1].technology_hash) != 0
		and int(first_frames[1].research_hash) != 0
		and int(first_frames[1].signal_hash) != 0
		and int(first_frames[1].tax_hash) != 0
		and int(first_frames[1].effect_hash) != 0)
	_expect("same input produces the same reference frames",
		_frame_signature(first_frames) == _frame_signature(second_frames))
	var checkpoint: Dictionary = first.checkpoint
	var bytes: PackedByteArray = checkpoint.get("bytes", PackedByteArray())
	_expect("reference checkpoint is canonical PKCN v13",
		bool(checkpoint.get("ok", false))
		and int(checkpoint.get("schema_version", 0)) == 13
		and bytes.size() > 32
		and bytes[0] == 0x50 and bytes[1] == 0x4b
		and bytes[2] == 0x43 and bytes[3] == 0x4e)
	_test_atomic_admission(catalog)


func _test_atomic_admission(catalog: Dictionary) -> void:
	var ext: Object = ClassDB.instantiate("DCWorldExt")
	ext.create_entities(2)
	var profile := {
		"country_runtime_mode": "ACTIVE",
		"starting_technology_ids": PackedStringArray(["tech.hunting"]),
	}
	ext.configure_country(catalog, profile, 2, 41)
	ext.configure_country_reference_trace(true, 8)
	ext.bootstrap_country({}, PackedByteArray([0, 0]))
	var country: Dictionary = ext.get_country_cell_summary(0)
	var rejected: Dictionary = ext.submit_country_commands(_commands([{
		"opcode": 2, "day": 0, "sequence": 1,
		"handle": int(country.country_handle), "cell": -1, "aux": -1,
		"stable_id": "", "name": "Must Not Commit",
	}, {
		"opcode": 99, "day": 0, "sequence": 2,
		"handle": int(country.country_handle), "cell": -1, "aux": -1,
		"stable_id": "", "name": "",
	}]))
	var report: Dictionary = ext.get_country_report()
	ext.run_country_slice({"day_index": 0})
	var after: Dictionary = ext.get_country_cell_summary(0)
	var trace: Dictionary = ext.poll_country_reference_trace(0, 8)
	var frames: Array = trace.get("frames", [])
	_expect("late invalid command rejects the whole admission batch",
		not bool(rejected.get("ok", true))
		and int(report.get("pending_commands", -1)) == 0
		and String(after.country_name) != "Must Not Commit"
		and frames.size() == 2
		and int(frames[1].command_watermark) == 0)


func _run_transcript(catalog: Dictionary) -> Dictionary:
	var ext: Object = ClassDB.instantiate("DCWorldExt")
	ext.create_entities(3)
	var profile := {
		"country_runtime_mode": "ACTIVE",
		"starting_technology_ids": PackedStringArray(["tech.hunting"]),
	}
	var configured: Dictionary = ext.configure_country(catalog, profile, 3, 20260908)
	if not bool(configured.get("ok", false)):
		return configured
	var trace_config: Dictionary = ext.configure_country_reference_trace(true, 8)
	if not bool(trace_config.get("ok", false)):
		return trace_config
	var boot: Dictionary = ext.bootstrap_country({}, PackedByteArray([0, 0, 0]))
	if not bool(boot.get("ok", false)):
		return boot
	var handle := int(ext.get_country_cell_summary(0).get("country_handle", 0))
	var submitted: Dictionary = ext.submit_country_commands(_commands([{
		"opcode": 2,
		"day": 0,
		"sequence": 7,
		"handle": handle,
		"cell": -1,
		"aux": -1,
		"stable_id": "",
		"name": "Reference Country",
	}]))
	if not bool(submitted.get("ok", false)):
		return submitted
	var committed: Dictionary = ext.run_country_slice({"day_index": 0})
	if not bool(committed.get("ok", false)):
		return committed
	var idle: Dictionary = ext.run_country_slice({"day_index": 1})
	if not bool(idle.get("ok", false)):
		return idle
	var trace: Dictionary = ext.poll_country_reference_trace(0, 16)
	trace["checkpoint"] = ext.capture_country_reference_checkpoint()
	return trace


func _frame_signature(frames: Array) -> Array:
	var signature: Array = []
	for frame: Dictionary in frames:
		signature.append([
			frame.get("day", -1), frame.get("stage", ""),
			frame.get("semantic_commit", false), frame.get("day_barrier", false),
			frame.get("command_watermark", 0), frame.get("command_hash", 0),
			frame.get("command_count", 0), frame.get("business_state_hash", 0),
			frame.get("identity_hash", 0), frame.get("territory_hash", 0),
			frame.get("treasury_hash", 0), frame.get("technology_hash", 0),
			frame.get("research_hash", 0), frame.get("signal_hash", 0),
			frame.get("tax_hash", 0), frame.get("effect_hash", 0),
			frame.get("generation", 0), frame.get("territory_generation", 0),
			frame.get("research_generation", 0), frame.get("tax_generation", 0),
			frame.get("visual_generation", 0), frame.get("first_event_id", 0),
			frame.get("last_event_id", 0),
		])
	return signature


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
		"tax_rate_percent": PackedInt32Array(),
		"stable_ids": PackedStringArray(), "display_names": PackedStringArray(),
	}
	for row: Dictionary in rows:
		out.opcodes.append(int(row.opcode))
		out.effective_days.append(int(row.day))
		out.sequences.append(int(row.sequence))
		out.target_handles.append(int(row.handle))
		out.cell_indices.append(int(row.cell))
		out.aux_i32.append(int(row.aux))
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
		out.tax_rate_percent.append(int(row.get("tax_rate", 0)))
		out.stable_ids.append(String(row.stable_id))
		out.display_names.append(String(row.name))
	return out


func _expect(label: String, condition: bool) -> void:
	_checks += 1
	if condition:
		print("  [OK] %s" % label)
	else:
		_fail(label)


func _fail(label: String) -> void:
	_failures += 1
	push_error("[FAIL] " + label)
