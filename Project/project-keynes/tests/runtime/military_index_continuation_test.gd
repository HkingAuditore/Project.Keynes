extends SceneTree


func _init() -> void:
	_run.call_deferred()


func _run() -> void:
	var ext := DCWorldExt.new()
	var result: Dictionary = ext.runtime_military_self_test()
	print("MILITARY_INDEX_SELF_TEST=" + JSON.stringify(result))
	var reason := String(result.get("reason", ""))
	var ok := bool(result.get("ok", false)) \
		and reason.contains("index heads next inactive payload and free-slot order match field by field") \
		and reason.contains("PKMI v1 explicitly refused") \
		and reason.contains("cyclic index rejected without modifying live state")

	var catalog := {
		"units": [{"id": "militia", "militia": true, "attack": 0.5,
			"defense": 0.6, "speed": 1.0, "training_days": 0}],
		"state_buildings": [],
	}
	ok = bool(ext.configure_military(catalog, 20260727).get("ok", false)) and ok
	var progress := PackedInt64Array([1, 21, 1])
	ok = ext.restore_military_event_progress(progress) and ok
	ok = ext.capture_military_event_progress() == progress and ok
	ok = not ext.restore_military_event_progress(PackedInt64Array([-1, -1, 0])) and ok
	ok = ext.capture_military_event_progress() == progress and ok

	var facade := MilitaryFacade.new()
	facade._configured = true
	facade._world_ext = ext
	var adapter := preload("res://scripts/game/save_modules/country_state.gd").new()
	var bad: Dictionary = adapter._restore_military_provider(
		{"pkmi": PackedByteArray([1, 2, 3])}, {"military": facade})
	ok = not bool(bad.get("ok", true)) \
		and bad.get("code") == "pkmi_restore_failed" and ok
	var invalid_tail := PackedByteArray()
	invalid_tail.resize(28)
	invalid_tail.encode_u32(0, 0x314a444d)
	invalid_tail.encode_s64(4, -1)
	var invalid_archive: PackedByteArray = ext.encode_military_state()
	invalid_archive.append_array(invalid_tail)
	bad = adapter._restore_military_provider({"pkmi": invalid_archive}, {"military": facade})
	ok = not bool(bad.get("ok", true)) and bad.get("message") == "military_forwarder_invalid" \
		and ext.capture_military_event_progress() == progress and ok
	print("MILITARY_EVENT_CURSOR: native restore exact, invalid cursor and invalid MDJ1 rejected: " + str(ok))
	quit(0 if ok else 1)
