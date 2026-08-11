extends SceneTree

const TriggerCatalogScript = preload("res://scripts/trigger/trigger_catalog.gd")
const TriggerDefinitionScript = preload("res://scripts/trigger/trigger_definition.gd")
const TriggerEffectScript = preload("res://scripts/trigger/trigger_effect.gd")

var _failures: Array[String] = []


func _init() -> void:
	call_deferred("_run")


func _expect(label: String, condition: bool) -> void:
	if not condition:
		_failures.append(label)


func _catalog() -> Dictionary:
	var catalog = TriggerCatalogScript.new()
	catalog.source_count = 2
	catalog.event_type_span = 16
	var definition = TriggerDefinitionScript.new()
	definition.key = &"test.branch"
	definition.source_id = 1
	definition.event_type = 6
	definition.payload_schema = 3
	definition.aggregator = 2
	definition.value_field = 1
	definition.threshold = 3
	definition.dynamic_binding = true
	definition.selector_field = 2
	definition.selector_value = 11
	definition.condition_ops = PackedInt32Array([2])
	var effect = TriggerEffectScript.new()
	effect.action = 11
	effect.command_key = &"test.reward"
	effect.value_mode = 1
	definition.effects.append(effect)
	catalog.definitions.append(definition)
	var compiled: Dictionary = catalog.compile_native_catalog()
	compiled.erase("ok")
	return compiled


func _bindings(branches: PackedInt64Array, cells: PackedInt32Array,
		enabled: PackedByteArray) -> Dictionary:
	var keys := PackedStringArray()
	var rewards := PackedInt32Array()
	for i in branches.size():
		keys.append("test.branch")
		rewards.append(i % 2)
	return {"trigger_keys": keys, "branch_handles": branches,
		"cells": cells, "reward_targets": rewards, "enabled": enabled}


func _events(ids: PackedInt64Array, days: PackedInt64Array,
		cells: PackedInt64Array, values: PackedInt64Array,
		selectors: PackedInt64Array) -> Dictionary:
	var sources := PackedInt32Array()
	var types := PackedInt32Array()
	var schemas := PackedInt32Array()
	var zeros := PackedInt64Array()
	for _i in ids.size():
		sources.append(1)
		types.append(6)
		schemas.append(3)
		zeros.append(0)
	return {"count": ids.size(), "event_ids": ids, "source_ids": sources,
		"days": days, "event_types": types, "payload_schemas": schemas,
		"entity_handles": zeros, "group_handles": cells, "values": values,
		"payload_i0": selectors, "payload_i1": zeros,
		"payload_i2": zeros, "payload_i3": zeros}


func _run() -> void:
	if not ClassDB.class_exists("DCWorldExt"):
		print("[trigger-family-branch] SKIP: DCWorldExt unavailable")
		quit(0)
		return
	var ext: Object = ClassDB.instantiate("DCWorldExt")
	var compiled := _catalog()
	_expect("v2 catalog configures", bool(ext.configure_triggers(compiled).get("ok", false)))
	var branch_a := int((1 << 32) | 101)
	var branch_b := int((1 << 32) | 202)
	var branches := PackedInt64Array([branch_a, branch_b])
	var cells := PackedInt32Array([3, 4])
	_expect("two branch bindings reconcile", int(ext.reconcile_trigger_branch_bindings(
		_bindings(branches, cells, PackedByteArray([1, 1]))).get("binding_count", 0)) == 2)
	ext.submit_trigger_events(_events(
		PackedInt64Array([1, 2, 3]), PackedInt64Array([0, 0, 0]),
		PackedInt64Array([3, 4, 3]), PackedInt64Array([2, 1, 100]),
		PackedInt64Array([11, 11, 99])))
	ext.run_trigger_daily(0)
	var a0: Dictionary = ext.get_trigger_branch_progress(branch_a)
	var b0: Dictionary = ext.get_trigger_branch_progress(branch_b)
	_expect("cell A accumulates matching quantity", int(a0.trigger_progress[0]) == 2)
	_expect("cell B accumulates independently", int(b0.trigger_progress[0]) == 1)
	_expect("selector rejects unrelated building", int(a0.trigger_progress[0]) != 102)
	ext.submit_trigger_events(_events(
		PackedInt64Array([4]), PackedInt64Array([1]), PackedInt64Array([3]),
		PackedInt64Array([1]), PackedInt64Array([11])))
	ext.run_trigger_daily(1)
	var effects: Dictionary = ext.poll_trigger_effects(0, 16)
	_expect("only A crossing emits", int(effects.get("count", 0)) == 1 \
		and int(effects.target_handles[0]) == branch_a)
	_expect("binding reward target reaches effect", int(effects.payload_i0[0]) == 0)
	_expect("unbind clears state", bool(ext.reconcile_trigger_branch_bindings(
		_bindings(PackedInt64Array([branch_a]), PackedInt32Array([3]),
			PackedByteArray([0]))).get("ok", false)) \
		and ext.get_trigger_branch_progress(branch_a).trigger_progress.is_empty())
	_expect("rebind starts empty", bool(ext.reconcile_trigger_branch_bindings(
		_bindings(PackedInt64Array([branch_a]), PackedInt32Array([3]),
			PackedByteArray([1]))).get("ok", false)) \
		and int(ext.get_trigger_branch_progress(branch_a).trigger_progress[0]) == 0)
	ext.submit_trigger_events(_events(
		PackedInt64Array([5]), PackedInt64Array([2]), PackedInt64Array([3]),
		PackedInt64Array([2]), PackedInt64Array([11])))
	ext.run_trigger_daily(2)
	var saved: PackedByteArray = ext.capture_trigger_state()
	var restored: Object = ClassDB.instantiate("DCWorldExt")
	restored.configure_triggers(compiled)
	restored.reconcile_trigger_branch_bindings(_bindings(
		PackedInt64Array([branch_a]), PackedInt32Array([3]), PackedByteArray([1])))
	_expect("PKTR v4 restores", bool(restored.restore_trigger_state(saved).get("ok", false)))
	_expect("derived binding sees restored progress",
		int(restored.get_trigger_branch_progress(branch_a).trigger_progress[0]) == 2)
	_finish()


func _finish() -> void:
	if _failures.is_empty():
		print("[trigger-family-branch] PASS")
		quit(0)
		return
	for failure in _failures:
		push_error("[trigger-family-branch] FAIL: %s" % failure)
	quit(1)
