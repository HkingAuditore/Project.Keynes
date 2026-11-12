extends SceneTree

## Pure-logic compatibility checks for MilitaryRenderFeed M1 visual fields.
## Run:
##   godot --headless --path Project/project-keynes \
##     -s res://tests/military/military_formation_render_feed_test.gd

const FEED_SCRIPT := preload("res://scripts/rendering/military_render_feed.gd")

var _failures := PackedStringArray()


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	_test_missing_fields_old_dll()
	_test_legacy_owner_only_rows()
	_test_valid_fields_and_top3()
	_test_formation_fields_change_formation_signature()
	_test_handle_and_owner_identity_change_signatures()
	_test_unavailable_snapshot_fails_closed()
	_test_bad_offsets_are_rejected()
	_test_bad_scalar_lengths_fall_back_independently()
	_test_empty_snapshot_clears_optional_fields()
	_finish()


func _test_missing_fields_old_dll() -> void:
	var feed = FEED_SCRIPT.new()
	feed.apply_synthetic(_snapshot_with_two_armies(), -1)
	_expect(feed.army_count == 2, "old DLL rows still unpack")
	_expect(feed.army_composition_offsets.is_empty(), "missing offsets fall back empty")
	_expect(feed.army_composition_unit.is_empty(), "missing units fall back empty")
	_expect(feed.army_composition_weight.is_empty(), "missing weights fall back empty")
	_expect(feed.army_heading_q16.is_empty(), "missing heading falls back empty")
	_expect(feed.army_attack_seq.is_empty(), "missing attack cue falls back empty")
	_expect(feed.army_hit_seq.is_empty(), "missing hit cue falls back empty")
	_expect(feed.army_heading_for_row(0) == 0, "missing heading reads as east")
	_expect(feed.army_attack_seq_for_row(0) == 0, "missing attack cue reads as zero")
	_expect(feed.army_hit_seq_for_row(0) == 0, "missing hit cue reads as zero")
	_expect(feed.get_army_composition_range(0) == Vector2i.ZERO,
		"missing composition has an empty range")
	_expect(feed.get_army_top3_composition(0).is_empty(),
		"missing composition has no top3 entries")
	var repeat = FEED_SCRIPT.new()
	repeat.apply_synthetic(_snapshot_with_two_armies(), -1)
	_expect(feed.army_formation_signature == repeat.army_formation_signature,
		"legacy formation signature remains deterministic")
	_expect(feed.army_class == PackedByteArray([3, 7]),
		"optional visual parsing does not disturb legacy class rows")


func _test_legacy_owner_only_rows() -> void:
	var feed = FEED_SCRIPT.new()
	feed.apply_synthetic({
		"revision": 1,
		"armies": {
			"owner_slot": PackedInt32Array([3, 4]),
			"cell": PackedInt32Array([10, 20]),
			"prev_cell": PackedInt32Array([10, 20]),
			"unit_class": PackedByteArray([1, 2]),
			"headcount": PackedInt64Array([100, 200]),
			"flags": PackedInt32Array([0, 0]),
		},
	}, -1)
	_expect(feed.army_count == 2, "legacy owner-only snapshots unpack both rows")
	_expect(feed.army_handle == PackedInt64Array([0, 0]),
		"missing legacy handles default to zero")
	_expect(feed.army_owner == PackedInt32Array([3, 4]),
		"PackedInt32Array owners are preserved without handles")


func _test_valid_fields_and_top3() -> void:
	var feed = FEED_SCRIPT.new()
	var snap := _snapshot_with_two_armies()
	var armies := snap["armies"] as Dictionary
	armies["composition_offsets"] = PackedInt32Array([0, 3, 5])
	armies["composition_unit"] = PackedInt32Array([7, 2, 5, 1, 9])
	armies["composition_weight"] = PackedInt64Array([40, 40, 20, 9, 7])
	armies["heading_q16"] = PackedInt32Array([0, 32768])
	armies["attack_seq"] = PackedInt32Array([12, 18])
	armies["hit_seq"] = PackedInt32Array([1, 2])
	feed.apply_synthetic(snap, -1)

	_expect(feed.army_composition_offsets == PackedInt32Array([0, 3, 5]),
		"valid CSR offsets are exposed")
	_expect(feed.army_composition_unit == PackedInt32Array([7, 2, 5, 1, 9]),
		"valid CSR units are exposed")
	_expect(feed.army_composition_weight == PackedInt64Array([40, 40, 20, 9, 7]),
		"valid CSR weights are exposed")
	_expect(feed.get_army_composition_range(0) == Vector2i(0, 3),
		"row zero composition range is exposed")
	_expect(feed.get_army_composition_range(1) == Vector2i(3, 5),
		"row one composition range is exposed")

	var top0: Array[Dictionary] = feed.get_army_top3_composition(0)
	_expect(top0.size() == 3, "row zero returns three composition entries")
	_expect(_entry(top0, 0) == Vector2i(2, 40),
		"equal weights sort by dense unit id ascending")
	_expect(_entry(top0, 1) == Vector2i(7, 40),
		"second tied composition entry is preserved")
	_expect(_entry(top0, 2) == Vector2i(5, 20),
		"lowest composition entry is preserved")
	_expect(feed.get_army_top3_composition(1, 1).size() == 1,
		"top3 helper honors caller entry limit")

	_expect(feed.army_heading_for_row(0) == 0, "heading row zero is east")
	_expect(feed.army_heading_for_row(1) == 32768, "heading row one is exposed")
	_expect(feed.army_attack_seq_for_row(0) == 12, "attack cue row zero is exposed")
	_expect(feed.army_attack_seq_for_row(1) == 18, "attack cue row one is exposed")
	_expect(feed.army_hit_seq_for_row(0) == 1, "hit cue row zero is exposed")
	_expect(feed.army_hit_seq_for_row(1) == 2, "hit cue row one is exposed")


func _test_formation_fields_change_formation_signature() -> void:
	var feed = FEED_SCRIPT.new()
	var snap := _snapshot_with_two_armies()
	var armies := snap["armies"] as Dictionary
	armies["composition_offsets"] = PackedInt32Array([0, 1, 1])
	armies["composition_unit"] = PackedInt32Array([4])
	armies["composition_weight"] = PackedInt64Array([100])
	armies["heading_q16"] = PackedInt32Array([0, 0])
	armies["attack_seq"] = PackedInt32Array([0, 0])
	armies["hit_seq"] = PackedInt32Array([0, 0])
	feed.apply_synthetic(snap, -1)
	var base_army_signature: int = int(feed.army_signature)
	var base_formation_signature: int = int(feed.army_formation_signature)

	var composition_snap := snap.duplicate(true)
	var composition_armies := composition_snap["armies"] as Dictionary
	composition_armies["composition_weight"] = PackedInt64Array([101])
	composition_snap["revision"] = 2
	feed.apply_synthetic(composition_snap, 1)
	_expect(feed.army_signature == base_army_signature,
		"composition-only changes preserve the legacy paper signature")
	_expect(feed.army_formation_signature != base_formation_signature,
		"composition-only changes invalidate the formation signature")

	var heading_formation_signature: int = int(feed.army_formation_signature)
	var heading_snap := composition_snap.duplicate(true)
	var heading_armies := heading_snap["armies"] as Dictionary
	heading_armies["heading_q16"] = PackedInt32Array([0, 16384])
	heading_snap["revision"] = 3
	feed.apply_synthetic(heading_snap, 2)
	_expect(feed.army_formation_signature != heading_formation_signature,
		"heading-only changes invalidate the formation signature")

	var cue_formation_signature: int = int(feed.army_formation_signature)
	var cue_snap := heading_snap.duplicate(true)
	var cue_armies := cue_snap["armies"] as Dictionary
	cue_armies["attack_seq"] = PackedInt32Array([0, 1])
	cue_snap["revision"] = 4
	feed.apply_synthetic(cue_snap, 3)
	_expect(feed.army_formation_signature == cue_formation_signature,
		"cue-only changes avoid a formation layout rebuild")


func _test_handle_and_owner_identity_change_signatures() -> void:
	var feed = FEED_SCRIPT.new()
	var base := _snapshot_with_two_armies()
	var base_armies := base["armies"] as Dictionary
	base_armies["composition_offsets"] = PackedInt32Array([0, 1, 2])
	base_armies["composition_unit"] = PackedInt32Array([4, 5])
	base_armies["composition_weight"] = PackedInt64Array([100, 50])
	base_armies["heading_q16"] = PackedInt32Array([0, 0])
	feed.apply_synthetic(base, -1)
	var base_army_signature: int = int(feed.army_signature)
	var base_formation_signature: int = int(feed.army_formation_signature)

	var handle_snap := base.duplicate(true)
	var handle_armies := handle_snap["armies"] as Dictionary
	handle_armies["handle"] = PackedInt64Array([999, 102])
	handle_snap["revision"] = 2
	feed.apply_synthetic(handle_snap, 1)
	_expect(feed.army_signature != base_army_signature,
		"handle-only row replacement invalidates the paper signature")
	_expect(feed.army_formation_signature != base_formation_signature,
		"handle-only row replacement invalidates the formation signature")
	var handle_army_signature: int = int(feed.army_signature)
	var handle_formation_signature: int = int(feed.army_formation_signature)

	var owner_snap := handle_snap.duplicate(true)
	var owner_armies := owner_snap["armies"] as Dictionary
	owner_armies["owner_slot"] = PackedInt32Array([9, 2])
	owner_snap["revision"] = 3
	feed.apply_synthetic(owner_snap, 2)
	_expect(feed.army_signature != handle_army_signature,
		"owner-only changes invalidate the paper signature")
	_expect(feed.army_formation_signature != handle_formation_signature,
		"owner-only changes invalidate the formation signature")


func _test_unavailable_snapshot_fails_closed() -> void:
	var feed = FEED_SCRIPT.new()
	feed.apply_synthetic(_snapshot_with_two_armies(), -1)
	_expect(feed.ok, "valid snapshot marks the feed available")
	var accepted_revision: int = int(feed.revision)
	feed.apply_synthetic({"ok": false, "reason": "military_not_configured"}, -1)
	_expect(not feed.ok, "ok=false snapshot marks the feed unavailable")
	_expect(feed.revision == accepted_revision,
		"failed snapshot does not advance the accepted revision")
	feed.apply_synthetic({"ok": true, "available": false}, -1)
	_expect(not feed.ok, "available=false snapshot also fails closed")


func _test_bad_offsets_are_rejected() -> void:
	_expect_composition_rejected(
		PackedInt32Array([0]),
		PackedInt32Array([1]),
		PackedInt64Array([1]),
		"wrong offsets length"
	)
	_expect_composition_rejected(
		PackedInt32Array([1, 1, 1]),
		PackedInt32Array([1]),
		PackedInt64Array([1]),
		"offsets do not start at zero"
	)
	_expect_composition_rejected(
		PackedInt32Array([0, 2, 1]),
		PackedInt32Array([1, 2, 3]),
		PackedInt64Array([1, 2, 3]),
		"decreasing offsets"
	)
	_expect_composition_rejected(
		PackedInt32Array([0, 1]),
		PackedInt32Array([1, 2]),
		PackedInt64Array([1, 2]),
		"offsets do not end at unit count"
	)
	_expect_composition_rejected(
		PackedInt32Array([0, 2]),
		PackedInt32Array([1, 2]),
		PackedInt64Array([1]),
		"unit and weight lengths differ"
	)
	_expect_composition_rejected(
		PackedInt32Array([0, 0, 4]),
		PackedInt32Array([1, 2, 3, 4]),
		PackedInt64Array([1, 2, 3, 4]),
		"one army exceeds the three-unit contract"
	)


func _test_bad_scalar_lengths_fall_back_independently() -> void:
	var feed = FEED_SCRIPT.new()
	var snap := _snapshot_with_two_armies()
	var armies := snap["armies"] as Dictionary
	armies["composition_offsets"] = PackedInt32Array([0, 1, 2])
	armies["composition_unit"] = PackedInt32Array([4, 5])
	armies["composition_weight"] = PackedInt64Array([100, 50])
	armies["heading_q16"] = PackedInt32Array([123])
	armies["attack_seq"] = PackedInt32Array([7, 8])
	armies["hit_seq"] = PackedInt32Array([0])
	feed.apply_synthetic(snap, -1)

	_expect(feed.army_composition_offsets == PackedInt32Array([0, 1, 2]),
		"valid composition survives malformed scalar rows")
	_expect(feed.army_heading_q16.is_empty(), "short heading array falls back empty")
	_expect(feed.army_heading_for_row(0) == 0, "short heading array reads east")
	_expect(feed.army_attack_seq == PackedInt32Array([7, 8]),
		"valid attack cue is exposed")
	_expect(feed.army_hit_seq.is_empty(), "short hit cue array falls back empty")
	_expect(feed.army_hit_seq_for_row(1) == 0, "short hit cue reads zero")
	_expect(feed.get_army_top3_composition(-1).is_empty(),
		"negative army row returns no composition")
	_expect(feed.get_army_top3_composition(2).is_empty(),
		"out-of-range army row returns no composition")


func _test_empty_snapshot_clears_optional_fields() -> void:
	var feed = FEED_SCRIPT.new()
	var snap := _snapshot_with_two_armies()
	var armies := snap["armies"] as Dictionary
	armies["composition_offsets"] = PackedInt32Array([0, 1, 2])
	armies["composition_unit"] = PackedInt32Array([4, 5])
	armies["composition_weight"] = PackedInt64Array([100, 50])
	armies["heading_q16"] = PackedInt32Array([0, 1])
	armies["attack_seq"] = PackedInt32Array([2, 3])
	armies["hit_seq"] = PackedInt32Array([4, 5])
	feed.apply_synthetic(snap, -1)

	var empty_snap := {"revision": 2, "armies": {}}
	feed.apply_synthetic(empty_snap, 1)
	_expect(feed.army_count == 0, "empty army snapshot clears count")
	_expect(feed.army_composition_offsets.is_empty(), "empty snapshot clears CSR offsets")
	_expect(feed.army_composition_unit.is_empty(), "empty snapshot clears CSR units")
	_expect(feed.army_composition_weight.is_empty(), "empty snapshot clears CSR weights")
	_expect(feed.army_heading_q16.is_empty(), "empty snapshot clears headings")
	_expect(feed.army_attack_seq.is_empty(), "empty snapshot clears attack cues")
	_expect(feed.army_hit_seq.is_empty(), "empty snapshot clears hit cues")


func _expect_composition_rejected(offsets: PackedInt32Array,
		units: PackedInt32Array, weights: PackedInt64Array, label: String) -> void:
	var feed = FEED_SCRIPT.new()
	var snap := _snapshot_with_two_armies()
	var armies := snap["armies"] as Dictionary
	armies["composition_offsets"] = offsets
	armies["composition_unit"] = units
	armies["composition_weight"] = weights
	armies["heading_q16"] = PackedInt32Array([111, 222])
	armies["attack_seq"] = PackedInt32Array([4, 5])
	armies["hit_seq"] = PackedInt32Array([6, 7])
	feed.apply_synthetic(snap, -1)
	_expect(feed.army_composition_offsets.is_empty(), label + " rejects offsets")
	_expect(feed.army_composition_unit.is_empty(), label + " rejects units")
	_expect(feed.army_composition_weight.is_empty(), label + " rejects weights")
	_expect(feed.get_army_composition_range(0) == Vector2i.ZERO,
		label + " exposes no row range")
	_expect(feed.army_heading_for_row(0) == 111,
		label + " keeps independent heading rows")
	_expect(feed.army_attack_seq_for_row(1) == 5,
		label + " keeps independent attack rows")


func _snapshot_with_two_armies() -> Dictionary:
	return {
		"revision": 1,
		"armies": {
			"handle": PackedInt64Array([101, 102]),
			"owner_slot": PackedInt32Array([1, 2]),
			"cell": PackedInt32Array([10, 20]),
			"prev_cell": PackedInt32Array([10, 20]),
			"moved_day": PackedInt32Array([3, 4]),
			"unit_class": PackedByteArray([3, 7]),
			"headcount": PackedInt64Array([500, 900]),
			"flags": PackedInt32Array([0, 1]),
		},
	}


func _entry(entries: Array[Dictionary], index: int) -> Vector2i:
	if index < 0 or index >= entries.size():
		return Vector2i(-1, -1)
	return Vector2i(int(entries[index].get("unit", -1)),
		int(entries[index].get("weight", -1)))


func _expect(condition: bool, message: String) -> void:
	if condition:
		return
	_failures.append(message)
	push_error(message)


func _finish() -> void:
	print("=== military formation render feed test: %d failures ===" % _failures.size())
	for failure in _failures:
		print("  FAILED: " + failure)
	quit(0 if _failures.is_empty() else 1)
