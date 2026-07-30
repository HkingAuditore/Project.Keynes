extends SceneTree

const TriggerCatalogScript = preload("res://scripts/trigger/trigger_catalog.gd")
const TriggerDefinitionScript = preload("res://scripts/trigger/trigger_definition.gd")
const TriggerEffectScript = preload("res://scripts/trigger/trigger_effect.gd")
var _failures: Array[String] = []

func _init() -> void: call_deferred("_run")
func _expect(label: String, condition: bool) -> void:
	if not condition: _failures.append(label)

func _make_definition(key: String, event_type: int, threshold: int,
		mode: int, cooldown: int, ops: PackedInt32Array) -> Resource:
	var definition = TriggerDefinitionScript.new(); definition.key = StringName(key)
	definition.event_type = event_type; definition.threshold = threshold
	definition.mode = mode; definition.cooldown_days = cooldown; definition.condition_ops = ops
	var effect = TriggerEffectScript.new(); effect.action = 13; effect.opcode = 30
	definition.effects.append(effect)
	return definition

func _batch(ids: PackedInt64Array, days: PackedInt64Array,
		types: PackedInt32Array) -> Dictionary:
	var source := PackedInt32Array(); var schemas := PackedInt32Array(); var values := PackedInt64Array()
	for _i in ids.size(): source.append(0); schemas.append(0); values.append(1)
	return {"count": ids.size(), "event_ids": ids, "source_ids": source, "days": days,
		"event_types": types, "payload_schemas": schemas, "values": values}

func _run() -> void:
	if not ClassDB.class_exists("DCWorldExt"):
		print("[trigger-conditions] SKIP: DCWorldExt unavailable"); quit(0); return
	var ext: Object = ClassDB.instantiate("DCWorldExt")
	if not ext.has_method("configure_triggers"):
		print("[trigger-conditions] SKIP: Trigger API unavailable"); quit(0); return
	var catalog = TriggerCatalogScript.new(); catalog.source_count = 2; catalog.event_type_span = 16
	catalog.definitions.append(_make_definition("cooldown", 1, 2, 1, 2,
		PackedInt32Array([3, 5, 7])))
	catalog.definitions.append(_make_definition("one_shot", 2, 1, 2, 0,
		PackedInt32Array([2, 6, 7])))
	var compiled: Dictionary = catalog.compile_native_catalog(); compiled.erase("ok")
	_expect("condition catalog configures", bool(ext.configure_triggers(compiled).get("ok", false)))
	ext.submit_trigger_events(_batch(PackedInt64Array([1,2,3]), PackedInt64Array([0,0,0]),
		PackedInt32Array([1,1,2]))); ext.run_trigger_daily(0)
	ext.submit_trigger_events(_batch(PackedInt64Array([4,5,6]), PackedInt64Array([1,1,1]),
		PackedInt32Array([1,1,2]))); ext.run_trigger_daily(1)
	ext.submit_trigger_events(_batch(PackedInt64Array([7,8]), PackedInt64Array([2,2]),
		PackedInt32Array([1,1]))); ext.run_trigger_daily(2)
	_expect("cooldown and one-shot gate effects", int(ext.poll_trigger_effects(0, 16).get("count", 0)) == 3)
	var strict = TriggerCatalogScript.new(); strict.source_count = 1; strict.event_type_span = 4
	strict.strict_source_cursors = true
	strict.definitions.append(_make_definition("gap", 1, 1, 1, 0, PackedInt32Array([3])))
	var strict_compiled: Dictionary = strict.compile_native_catalog(); strict_compiled.erase("ok")
	ext.configure_triggers(strict_compiled)
	ext.submit_trigger_events(_batch(PackedInt64Array([1]), PackedInt64Array([0]), PackedInt32Array([1])))
	ext.submit_trigger_events(_batch(PackedInt64Array([3]), PackedInt64Array([0]), PackedInt32Array([1])))
	var report: Dictionary = ext.get_trigger_report()
	var gap_begin: PackedInt64Array = report.get("source_gap_begin", PackedInt64Array())
	var gap_end: PackedInt64Array = report.get("source_gap_end", PackedInt64Array())
	_expect("strict cursor records exact gap", int(report.get("gap_count", 0)) == 1 \
		and gap_begin.size() == 1 and gap_begin[0] == 2 and gap_end[0] == 3)
	_expect("resync clears source pause", bool(ext.resync_trigger_source({"source_id": 0,
		"cursor": 3, "trigger_ids": PackedInt32Array([0]), "target_handles": PackedInt64Array([0]),
		"values": PackedInt64Array([0])}).get("ok", false)))
	_finish()

func _finish() -> void:
	if _failures.is_empty(): print("[trigger-conditions] PASS"); quit(0); return
	for failure in _failures: push_error("[trigger-conditions] FAIL: %s" % failure)
	quit(1)
