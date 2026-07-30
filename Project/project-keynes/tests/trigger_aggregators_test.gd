extends SceneTree

const TriggerCatalogScript = preload("res://scripts/trigger/trigger_catalog.gd")
const TriggerDefinitionScript = preload("res://scripts/trigger/trigger_definition.gd")
const TriggerEffectScript = preload("res://scripts/trigger/trigger_effect.gd")
var _failures: Array[String] = []

func _init() -> void: call_deferred("_run")
func _expect(label: String, condition: bool) -> void:
	if not condition: _failures.append(label)

func _definition(key: String, event_type: int, aggregator: int, threshold: int,
		value_field: int = 1, condition_op: int = 3, window_days: int = 0,
		distinct_field: int = 2) -> Resource:
	var definition = TriggerDefinitionScript.new()
	definition.key = StringName(key); definition.event_type = event_type
	definition.aggregator = aggregator; definition.threshold = threshold
	definition.value_field = value_field; definition.distinct_field = distinct_field
	definition.window_days = window_days; definition.condition_ops = PackedInt32Array([condition_op])
	var effect = TriggerEffectScript.new(); effect.action = 13; effect.opcode = 31
	effect.command_key = StringName(key); effect.value_mode = 1
	definition.effects.append(effect)
	return definition

func _events(ids: PackedInt64Array, days: PackedInt64Array, types: PackedInt32Array,
		values: PackedInt64Array, payload0: PackedInt64Array = PackedInt64Array()) -> Dictionary:
	var n := ids.size(); var zeros32 := PackedInt32Array(); var zeros64 := PackedInt64Array()
	for _i in n: zeros32.append(0); zeros64.append(0)
	return {"count": n, "event_ids": ids, "source_ids": zeros32, "days": days,
		"event_types": types, "payload_schemas": zeros32, "entity_handles": zeros64,
		"group_handles": zeros64, "values": values,
		"payload_i0": payload0 if payload0.size() == n else zeros64,
		"payload_i1": zeros64, "payload_i2": zeros64, "payload_i3": zeros64}

func _run() -> void:
	if not ClassDB.class_exists("DCWorldExt"):
		print("[trigger-aggregators] SKIP: DCWorldExt unavailable"); quit(0); return
	var ext: Object = ClassDB.instantiate("DCWorldExt")
	if not ext.has_method("configure_triggers"):
		print("[trigger-aggregators] SKIP: Trigger API unavailable"); quit(0); return
	var catalog = TriggerCatalogScript.new()
	catalog.source_count = 2; catalog.event_type_span = 32
	var definitions := [
		_definition("count", 1, 1, 2, 0), _definition("sum", 2, 2, 5),
		_definition("max", 3, 4, 10), _definition("min", 4, 3, 4, 1, 4),
		_definition("level", 5, 5, 10, 1, 4),
		_definition("window", 6, 6, 2, 0, 3, 2),
		_definition("distinct", 7, 8, 2, 1, 3, 0, 2),
		_definition("diff", 8, 9, 5),
	]
	for definition in definitions: catalog.definitions.append(definition)
	var compiled: Dictionary = catalog.compile_native_catalog(); compiled.erase("ok")
	_expect("aggregator catalog configures", bool(ext.configure_triggers(compiled).get("ok", false)))
	var batch := _events(PackedInt64Array([1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16]),
		PackedInt64Array([0,0,0,0,0,0,0,0,0,0,0,0,0,3,3,3]),
		PackedInt32Array([1,1,2,2,3,3,4,4,5,5,5,6,6,6,6,7]),
		PackedInt64Array([1,1,2,3,5,12,9,3,5,15,8,1,1,1,1,1]),
		PackedInt64Array([0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,1]))
	_expect("aggregate events accepted", int(ext.submit_trigger_events(batch).get("accepted", 0)) == 16)
	# Capture before evaluation to verify pending ingress is part of PKTR.
	var pending_save: PackedByteArray = ext.capture_trigger_state()
	var restored: Object = ClassDB.instantiate("DCWorldExt")
	restored.configure_triggers(compiled)
	_expect("pending PKTR restores", bool(restored.restore_trigger_state(pending_save).get("ok", false)))
	restored.run_trigger_daily(0); restored.run_trigger_daily(3)
	var distinct_tail := _events(PackedInt64Array([17,18]), PackedInt64Array([3,3]),
		PackedInt32Array([7,7]), PackedInt64Array([1,1]), PackedInt64Array([1,2]))
	restored.submit_trigger_events(distinct_tail)
	var snapshots := _events(PackedInt64Array([19,20]), PackedInt64Array([3,3]),
		PackedInt32Array([8,8]), PackedInt64Array([100,105]))
	restored.submit_trigger_snapshots(snapshots); restored.run_trigger_daily(3)
	var effects: Dictionary = restored.poll_trigger_effects(0, 64)
	_expect("all aggregator transitions emit", int(effects.get("count", 0)) == 11)
	_finish()

func _finish() -> void:
	if _failures.is_empty(): print("[trigger-aggregators] PASS"); quit(0); return
	for failure in _failures: push_error("[trigger-aggregators] FAIL: %s" % failure)
	quit(1)
