extends SceneTree

const Q16_ONE := 65536

func _require(value: bool, message: String) -> void:
	assert(value, message)

func _instruction(op: int, arg0: int = 0) -> Resource:
	var row := EffectInstruction.new()
	row.op = op
	row.arg0 = arg0
	return row

func _condition() -> Resource:
	var row := EffectCondition.new()
	row.op = 2 # METRIC_GTE
	row.arg0 = 0
	row.value_q16 = 1
	return row

func _definition(key: String, stack_key: String, stack_policy: int,
		max_stacks: int, priority: int = 0, lifecycle: int = 0,
		duration_days: int = -1) -> Resource:
	var command := EffectCommand.new()
	command.action = 1 # MODIFIER_COMMAND
	command.domain = 2 # ModifierRuntime::ECONOMY
	command.opcode = 1 # APPLY
	command.target_resolver = 1 # TARGET_INSTANCE
	command.value_mode = 1 # VALUE_STACK_TOP
	command.duration_days = duration_days
	command.stacks = 1
	command.command_key = &"family.effect.test"
	command.definition_key = StringName("test.%s" % key)
	var definition := EffectDefinition.new()
	definition.key = StringName("family.effect.%s" % key)
	definition.max_work = 4
	definition.conditions = [_condition()]
	definition.instructions = [_instruction(2), _instruction(11)]
	definition.commands = [command]
	definition.source_kind = 1 # RANDOM_POOL exercises non-Trait ingress.
	definition.target_domain = 2 # SETTLEMENT_CELL
	definition.operation = 0 # ADD
	definition.lifecycle = lifecycle
	definition.duration_days = duration_days
	definition.stack_policy = stack_policy
	definition.stack_key = StringName(stack_key)
	definition.max_stacks = max_stacks
	definition.priority = priority
	definition.target_selector_kind = 2 # SOURCE_CELL
	return definition

func _catalog(definitions: Array[Resource]) -> Resource:
	var catalog := EffectCatalog.new()
	catalog.metric_keys = PackedStringArray(["family.magnitude_q16"])
	catalog.max_work_per_slice = 256
	catalog.definitions = definitions
	return catalog

func _configure(definitions: Array[Resource]) -> Object:
	var ext: Object = ClassDB.instantiate("DCWorldExt")
	_require(ext != null, "DCWorldExt unavailable")
	var compiled: Dictionary = _catalog(definitions).compile_native_catalog()
	_require(bool(compiled.get("ok", false)), "catalog compile: %s" % str(compiled))
	var configured: Dictionary = ext.configure_effects(compiled)
	_require(bool(configured.get("ok", false)), "catalog configure: %s" % str(configured))
	return ext

func _submit(ext: Object, ids: PackedInt64Array, keys: PackedStringArray,
		stacks: PackedInt32Array = PackedInt32Array(),
		activations: PackedInt64Array = PackedInt64Array(), day: int = 0) -> void:
	var count := ids.size()
	var generations := PackedInt32Array()
	var source_types := PackedInt32Array()
	var source_kinds := PackedInt32Array()
	var source_handles := PackedInt64Array()
	var target_handles := PackedInt64Array()
	var target_generations := PackedInt32Array()
	var due_days := PackedInt64Array()
	generations.resize(count)
	source_types.resize(count)
	source_kinds.resize(count)
	source_handles.resize(count)
	target_handles.resize(count)
	target_generations.resize(count)
	due_days.resize(count)
	generations.fill(1)
	source_types.fill(0x46465854)
	source_kinds.fill(1)
	source_handles.fill(7)
	target_handles.fill(7)
	target_generations.fill(1)
	due_days.fill(day)
	var result: Dictionary = ext.submit_effect_instances({
		"instance_ids": ids,
		"program_keys": keys,
		"generations": generations,
		"source_types": source_types,
		"source_kinds": source_kinds,
		"source_ids": ids,
		"source_handles": source_handles,
		"target_handles": target_handles,
		"target_generations": target_generations,
		"stack_counts": stacks,
		"activation_sequences": activations,
		"next_due_days": due_days,
	})
	_require(bool(result.get("ok", false)) and int(result.get("accepted", 0)) == count,
		"instance submit: %s" % str(result))

func _snapshot(ext: Object, ids: PackedInt64Array,
		values: PackedInt64Array, revision: int) -> void:
	var offsets := PackedInt32Array([0])
	var metric_ids := PackedInt32Array()
	for _id in ids:
		offsets.append(offsets[-1] + 1)
		metric_ids.append(0)
	var revisions := PackedInt64Array()
	revisions.resize(ids.size())
	revisions.fill(revision)
	var result: Dictionary = ext.submit_effect_snapshots({
		"instance_ids": ids,
		"revisions": revisions,
		"metric_offsets": offsets,
		"metric_ids": metric_ids,
		"metric_values_q16": values,
	})
	_require(bool(result.get("ok", false)), "snapshot submit: %s" % str(result))

func _poll(ext: Object) -> Dictionary:
	return ext.poll_effect_transactions(0, 64)

func _ack_all(ext: Object, transactions: Dictionary) -> void:
	var ids: PackedInt64Array = transactions.get("transaction_ids", PackedInt64Array())
	var masks: PackedInt32Array = transactions.get("required_ack_masks", PackedInt32Array())
	if ids.is_empty():
		return
	var preflight: Dictionary = ext.preflight_effect_transactions({
		"transaction_ids": ids,
		"ack_masks": masks,
	})
	_require(bool(preflight.get("ok", false)), "preflight: %s" % str(preflight))
	var committed: Dictionary = ext.commit_effect_transactions({
		"transaction_ids": ids,
		"ack_masks": masks,
	})
	_require(bool(committed.get("ok", false)), "commit: %s" % str(committed))
	var acked: Dictionary = ext.ack_effect_transactions({
		"transaction_ids": ids,
		"ack_masks": masks,
	})
	_require(bool(acked.get("ok", false)), "ack: %s" % str(acked))

func _test_replace_and_condition_removal() -> void:
	var low := _definition("replace.low", "replace.shared", 0, 1, 10)
	var high := _definition("replace.high", "replace.shared", 0, 1, 20)
	var ext := _configure([low, high])
	_submit(ext, PackedInt64Array([101, 102]), PackedStringArray([
		"family.effect.replace.low", "family.effect.replace.high"]))
	_snapshot(ext, PackedInt64Array([101, 102]),
		PackedInt64Array([Q16_ONE, 2 * Q16_ONE]), 1)
	_require(bool(ext.run_effect_daily(0).get("ok", false)), "replace run")
	var first := _poll(ext)
	_require(int(first.get("count", 0)) == 1 and
		int(first.get("source_instance_ids", PackedInt64Array())[0]) == 102,
		"REPLACE winner: %s" % str(first))
	_ack_all(ext, first)
	_snapshot(ext, PackedInt64Array([102]), PackedInt64Array([0]), 2)
	_require(bool(ext.run_effect_daily(1).get("ok", false)), "replace handoff run")
	var handoff := _poll(ext)
	_require(int(handoff.get("count", 0)) == 2,
		"condition true->false must remove and hand off: %s" % str(handoff))
	var opcodes: PackedInt32Array = handoff.get("command_opcodes", PackedInt32Array())
	_require(opcodes.has(1) and opcodes.has(2), "handoff apply/remove: %s" % str(handoff))
	_ack_all(ext, handoff)

func _test_add_stack_and_idempotent_upsert() -> void:
	var add := _definition("stack.add", "stack.shared", 2, 4)
	var ext := _configure([add])
	_submit(ext, PackedInt64Array([201, 202]), PackedStringArray([
		"family.effect.stack.add", "family.effect.stack.add"]),
		PackedInt32Array([2, 3]))
	_snapshot(ext, PackedInt64Array([201, 202]),
		PackedInt64Array([Q16_ONE, Q16_ONE]), 1)
	_require(bool(ext.run_effect_daily(0).get("ok", false)), "ADD_STACK run")
	var planned := _poll(ext)
	_require(int(planned.get("count", 0)) == 2, "ADD_STACK sources: %s" % str(planned))
	var command_stacks: PackedInt32Array = planned.get("command_stacks", PackedInt32Array())
	var total := 0
	for value in command_stacks:
		total += value
	_require(total == 4, "ADD_STACK group cap: %s" % str(planned))
	_ack_all(ext, planned)
	_submit(ext, PackedInt64Array([201, 202]), PackedStringArray([
		"family.effect.stack.add", "family.effect.stack.add"]),
		PackedInt32Array([2, 3]), PackedInt64Array(), 1)
	_require(bool(ext.run_effect_daily(1).get("ok", false)), "repeated upsert run")
	_require(int(_poll(ext).get("count", 0)) == 0,
		"repeated structural upsert must not add stacks")
	var saved: PackedByteArray = ext.capture_effect_state()
	_require(not saved.is_empty(), "PKEF capture")
	var restored: Dictionary = ext.restore_effect_state(saved)
	_require(bool(restored.get("ok", false)), "PKEF restore: %s" % str(restored))
	var report: Dictionary = ext.get_effect_report()
	_require(int(report.get("family_effect_stack_groups", 0)) == 1 and
		int(report.get("family_effect_group_members", 0)) == 2,
		"derived stack index rebuild: %s" % str(report))

func _test_max_min_and_refresh() -> void:
	for policy in [3, 4]:
		var left := _definition("extreme.%d.left" % policy,
			"extreme.%d" % policy, policy, 1)
		var right := _definition("extreme.%d.right" % policy,
			"extreme.%d" % policy, policy, 1)
		var ext := _configure([left, right])
		_submit(ext, PackedInt64Array([301, 302]), PackedStringArray([
			"family.effect.extreme.%d.left" % policy,
			"family.effect.extreme.%d.right" % policy]))
		_snapshot(ext, PackedInt64Array([301, 302]),
			PackedInt64Array([Q16_ONE, 2 * Q16_ONE]), 1)
		_require(bool(ext.run_effect_daily(0).get("ok", false)), "extreme run")
		var planned := _poll(ext)
		var expected := 302 if policy == 3 else 301
		_require(int(planned.get("count", 0)) == 1 and
			int(planned.get("source_instance_ids", PackedInt64Array())[0]) == expected,
			"MAX/MIN winner: %s" % str(planned))

	var refresh := _definition("refresh", "refresh", 1, 1, 0, 1, 3)
	var refresh_ext := _configure([refresh])
	_submit(refresh_ext, PackedInt64Array([401]),
		PackedStringArray(["family.effect.refresh"]), PackedInt32Array([1]),
		PackedInt64Array([10]))
	var initial: Dictionary = refresh_ext.explain_effect(401)
	_require(int(initial.get("expires_day", -1)) == 3, str(initial))
	_submit(refresh_ext, PackedInt64Array([401]),
		PackedStringArray(["family.effect.refresh"]), PackedInt32Array([1]),
		PackedInt64Array([10]), 1)
	var unchanged: Dictionary = refresh_ext.explain_effect(401)
	_require(int(unchanged.get("expires_day", -1)) == 3,
		"same activation must not refresh duration: %s" % str(unchanged))
	_submit(refresh_ext, PackedInt64Array([401]),
		PackedStringArray(["family.effect.refresh"]), PackedInt32Array([1]),
		PackedInt64Array([11]), 1)
	var refreshed: Dictionary = refresh_ext.explain_effect(401)
	_require(int(refreshed.get("expires_day", -1)) == 4,
		"new activation refreshes duration: %s" % str(refreshed))

func _init() -> void:
	_test_replace_and_condition_removal()
	_test_add_stack_and_idempotent_upsert()
	_test_max_min_and_refresh()
	print("family_effect_stack_runtime_test: PASS")
	quit()
