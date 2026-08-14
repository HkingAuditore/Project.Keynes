extends SceneTree

var _failures: Array[String] = []

func _init() -> void:
	call_deferred("_run")

func _expect(label: String, condition: bool) -> void:
	if not condition: _failures.append(label)

func _run() -> void:
	if not ClassDB.class_exists("DCWorldExt"):
		print("[trigger-runtime] SKIP: DCWorldExt unavailable"); quit(0); return
	var ext: Object = ClassDB.instantiate("DCWorldExt")
	if not ext.has_method("configure_triggers"):
		print("[trigger-runtime] SKIP: Trigger API unavailable"); quit(0); return
	var catalog := {
		"protocol_version": 3, "source_count": 4, "event_type_span": 32,
		"max_state_instances": 64, "max_pending_events": 64, "distinct_capacity": 8,
		"trigger_keys": PackedStringArray(["test.count"]), "versions": PackedInt32Array([1]),
		"source_ids": PackedInt32Array([1]), "event_types": PackedInt32Array([7]),
		"payload_schemas": PackedInt32Array([0]), "aggregators": PackedInt32Array([1]),
		"value_fields": PackedInt32Array([0]), "distinct_fields": PackedInt32Array([1]),
		"scopes": PackedInt32Array([0]), "target_resolvers": PackedInt32Array([0]),
		"static_targets": PackedInt64Array([0]), "thresholds": PackedInt64Array([2]),
		"modes": PackedInt32Array([1]), "cooldown_days": PackedInt32Array([0]),
		"window_days": PackedInt32Array([0]), "enabled": PackedByteArray([1]),
		"qualifier_thresholds": PackedInt64Array([0]),
		"duration_fields": PackedInt32Array([0]),
		"development_metric_ids": PackedInt32Array([-1]),
		"development_era_indices": PackedInt32Array([-1]),
		"dynamic_bindings": PackedByteArray([0]),
		"selector_fields": PackedInt32Array([-1]),
		"selector_values": PackedInt64Array([0]),
		"selector_negated": PackedByteArray([0]),
		"condition_offsets": PackedInt32Array([0, 1]), "condition_ops": PackedInt32Array([2]),
		"effect_offsets": PackedInt32Array([0, 1]), "effect_actions": PackedInt32Array([13]),
		"effect_domains": PackedInt32Array([3]), "effect_source_priorities": PackedInt32Array([0]),
		"effect_opcodes": PackedInt32Array([0]),
		"effect_target_resolvers": PackedInt32Array([0]), "effect_static_targets": PackedInt64Array([0]),
		"effect_value_modes": PackedInt32Array([1]), "effect_values": PackedInt64Array([0]),
		"effect_duration_days": PackedInt32Array([-1]), "effect_stacks": PackedInt32Array([1]),
		"effect_command_keys": PackedStringArray(["test.publish"]),
		"effect_definition_keys": PackedStringArray([""]),
		"effect_payload_i0": PackedInt64Array([0]), "effect_payload_i1": PackedInt64Array([0]),
		"effect_payload_i2": PackedInt64Array([0]), "effect_payload_i3": PackedInt64Array([0]),
	}
	var configured: Dictionary = ext.configure_triggers(catalog)
	_expect("catalog configures", bool(configured.get("ok", false)))
	if not bool(configured.get("ok", false)): _finish(); return
	var events := {"count": 2, "event_ids": PackedInt64Array([1, 2]),
		"source_ids": PackedInt32Array([1, 1]), "days": PackedInt64Array([0, 0]),
		"event_types": PackedInt32Array([7, 7]), "payload_schemas": PackedInt32Array([0, 0]),
		"entity_handles": PackedInt64Array([0, 0]), "group_handles": PackedInt64Array([0, 0]),
		"values": PackedInt64Array([1, 1]), "payload_i0": PackedInt64Array([0, 0]),
		"payload_i1": PackedInt64Array([0, 0]), "payload_i2": PackedInt64Array([0, 0]),
		"payload_i3": PackedInt64Array([0, 0])}
	var accepted: Dictionary = ext.submit_trigger_events(events)
	_expect("events accepted", int(accepted.get("accepted", 0)) == 2)
	_expect("duplicate ignored", int(ext.submit_trigger_events(events).get("deduplicated", 0)) == 2)
	var daily: Dictionary = ext.run_trigger_daily(0)
	_expect("daily evaluates", bool(daily.get("ok", false)))
	var effects: Dictionary = ext.poll_trigger_effects(0, 16)
	_expect("threshold emits one effect", int(effects.get("count", 0)) == 1)
	var saved: PackedByteArray = ext.capture_trigger_state()
	_expect("PKTR captures", not saved.is_empty())
	_expect("PKTR v5 header", saved.size() >= 8 and saved.decode_s32(4) == 5)
	var restored: Object = ClassDB.instantiate("DCWorldExt")
	_expect("restore configures", bool(restored.configure_triggers(catalog).get("ok", false)))
	_expect("PKTR restores", bool(restored.restore_trigger_state(saved).get("ok", false)))
	var legacy := saved.duplicate()
	legacy[4] = 2
	legacy[5] = 0
	legacy[6] = 0
	legacy[7] = 0
	_expect("legacy PKTR reports catalog mismatch",
		String(restored.restore_trigger_state(legacy).get("reason", "")) ==
			"catalog_hash_mismatch")
	_finish()

func _finish() -> void:
	if _failures.is_empty(): print("[trigger-runtime] PASS"); quit(0); return
	for failure in _failures: push_error("[trigger-runtime] FAIL: %s" % failure)
	quit(1)
