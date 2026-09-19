extends SceneTree

const EffectDomainCatalogScript = preload("res://scripts/effect/effect_domain_catalog.gd")
const ModifierFacadeScript = preload("res://scripts/modifier/modifier_facade.gd")

const PERSON_PROGRAM := "person.modifier.gameplay.generic.bonus"
const GAMEPLAY_DOMAIN := 3

func _require(value: bool, message: String) -> void:
	assert(value, message)

func _submit(ext: Object, instance_id: int, target: int) -> Dictionary:
	return ext.submit_effect_instances({
		"instance_ids": PackedInt64Array([instance_id]),
		"program_keys": PackedStringArray([PERSON_PROGRAM]),
		"generations": PackedInt32Array([1]),
		"source_types": PackedInt32Array([0x50455253]),
		"source_ids": PackedInt64Array([instance_id]),
		"source_handles": PackedInt64Array([target]),
		"target_handles": PackedInt64Array([target]),
		"target_generations": PackedInt32Array([int(target >> 32)]),
		"next_due_days": PackedInt64Array([0]),
	})

func _event_once_catalog() -> Resource:
	var command := EffectCommand.new()
	command.action = 1 # MODIFIER_COMMAND
	command.domain = GAMEPLAY_DOMAIN
	command.opcode = 1 # APPLY
	command.target_resolver = 1 # TARGET_INSTANCE
	command.value_mode = 1 # VALUE_STACK_TOP
	command.command_key = &"test.event_once.modifier"
	command.definition_key = &"gameplay.generic.bonus"
	var constant := EffectInstruction.new()
	constant.op = 1 # CONST
	constant.value_q16 = 65536
	var emit := EffectInstruction.new()
	emit.op = 11 # EMIT_COMMAND
	emit.arg0 = 0
	var definition := EffectDefinition.new()
	definition.key = &"test.event_once.retry"
	definition.max_work = 2
	definition.instructions = [constant, emit]
	definition.commands = [command]
	definition.lifecycle = 2 # EVENT_ONCE
	definition.operation = 4 # EVENT_COMMAND metadata
	var catalog := EffectCatalog.new()
	catalog.definitions = [definition]
	return catalog

func _submit_event_once(ext: Object, target: int, day: int) -> Dictionary:
	return ext.submit_effect_instances({
		"instance_ids": PackedInt64Array([9101]),
		"program_keys": PackedStringArray(["test.event_once.retry"]),
		"generations": PackedInt32Array([1]),
		"source_types": PackedInt32Array([0x45564e54]),
		"source_ids": PackedInt64Array([9101]),
		"source_handles": PackedInt64Array([target]),
		"target_handles": PackedInt64Array([target]),
		"target_generations": PackedInt32Array([int(target >> 32)]),
		"next_due_days": PackedInt64Array([day]),
	})

func _test_event_once_rejection_retry() -> void:
	var ext: Object = ClassDB.instantiate("DCWorldExt")
	var modifier := ModifierFacadeScript.new()
	_require(bool(modifier.configure(ext, 1).get("ok", false)),
		"event-once modifier configure")
	var compiled: Dictionary = _event_once_catalog().compile_native_catalog()
	_require(bool(compiled.get("ok", false)), "event-once catalog compile")
	_require(bool(ext.configure_effects(compiled).get("ok", false)),
		"event-once effect configure")
	var stale_target := int(ext.register_gameplay_modifier_object(
		"event_once_stale_target"))
	_require(stale_target != 0, "event-once stale target allocated")
	_require(bool(_submit_event_once(ext, stale_target, 0).get("ok", false)),
		"event-once initial submit")
	_require(bool(ext.run_effect_daily(0).get("ok", false)),
		"event-once initial evaluate")
	_require(int(ext.dispatch_effect_native_modifier().get(
		"submitted_transactions", 0)) == 1, "event-once initial dispatch")
	_require(bool(ext.unregister_gameplay_modifier_object(stale_target, 0).get(
		"ok", false)), "event-once target retired before commit")
	_require(bool(ext.run_modifier_daily(0).get("ok", false)),
		"event-once rejected modifier boundary")
	var rejected: Dictionary = ext.ack_effect_native_modifier()
	_require(int(rejected.get("rejected", 0)) == 1 and
		not bool(rejected.get("ok", true)),
		"event-once rejection reaches Effect Runtime: %s" % str(rejected))
	var pending: Dictionary = ext.explain_effect(9101)
	_require(bool(pending.get("ok", false)) and
		int(pending.get("next_due_day", -1)) == 1,
		"event-once rejection remains retryable: %s" % str(pending))

	var live_target := int(ext.register_gameplay_modifier_object(
		"event_once_live_target"))
	_require(live_target != 0 and live_target != stale_target,
		"event-once replacement target allocated")
	_require(bool(_submit_event_once(ext, live_target, 1).get("ok", false)),
		"event-once retry target submit")
	_require(bool(ext.run_effect_daily(1).get("ok", false)),
		"event-once retry evaluate")
	_require(int(ext.dispatch_effect_native_modifier().get(
		"submitted_transactions", 0)) == 1, "event-once retry dispatch")
	_require(bool(ext.run_modifier_daily(1).get("ok", false)),
		"event-once retry modifier boundary")
	var acked: Dictionary = ext.ack_effect_native_modifier()
	_require(int(acked.get("acknowledged", 0)) == 1 and
		bool(acked.get("ok", false)), "event-once retry ACK: %s" % str(acked))
	var report: Dictionary = ext.get_effect_report()
	_require(int(report.get("instances", -1)) == 0 and
		int(report.get("free_instance_slots", 0)) == 1,
		"event-once retires only after ACK: %s" % str(report))

func _init() -> void:
	var ext: Object = ClassDB.instantiate("DCWorldExt")
	_require(ext != null, "DCWorldExt unavailable")
	var modifier := ModifierFacadeScript.new()
	_require(bool(modifier.configure(ext, 1).get("ok", false)), "modifier configure")
	var catalog: Resource = EffectDomainCatalogScript.build()
	_require(catalog != null, "effect domain catalog")
	_require(bool(ext.configure_effects(catalog.compile_native_catalog()).get("ok", false)),
		"effect configure")
	var target := int(ext.register_gameplay_modifier_object("effect_lifecycle_test"))
	_require(target != 0, "gameplay target")

	_require(bool(_submit(ext, 9001, target).get("ok", false)), "initial person instance")
	_require(bool(ext.run_effect_daily(0).get("ok", false)), "initial effect evaluation")
	_require(int(ext.dispatch_effect_native_modifier().get("submitted_transactions", 0)) == 1,
		"initial native Modifier submit")
	_require(bool(ext.run_modifier_daily(0).get("ok", false)), "initial modifier boundary")
	_require(int(ext.ack_effect_native_modifier().get("acknowledged", 0)) == 1,
		"initial native ACK")
	var applied: PackedStringArray = modifier.list_for_target(
		GAMEPLAY_DOMAIN, target).get("definition_keys", PackedStringArray())
	_require(applied.has("gameplay.generic.bonus"), "person effect modifier applied")

	_require(bool(ext.retire_effect_instance(9001, 1, 1).get("ok", false)),
		"retire effect instance")
	var retirement_dispatch: Dictionary = ext.dispatch_effect_native_modifier()
	_require(int(retirement_dispatch.get("submitted_transactions", 0)) == 1,
		"retirement remove submit: %s" % str(retirement_dispatch))
	_require(bool(ext.run_modifier_daily(1).get("ok", false)), "retirement modifier boundary")
	var retirement_ack: Dictionary = ext.ack_effect_native_modifier()
	_require(int(retirement_ack.get("acknowledged", 0)) == 1,
		"retirement native ACK: %s" % str(retirement_ack))
	var removed: PackedStringArray = modifier.list_for_target(
		GAMEPLAY_DOMAIN, target).get("definition_keys", PackedStringArray())
	_require(not removed.has("gameplay.generic.bonus"), str(removed))
	var reclaimed: Dictionary = ext.get_effect_report()
	_require(int(reclaimed.get("instances", -1)) == 0 and
		int(reclaimed.get("free_instance_slots", 0)) == 1, str(reclaimed))

	# Tombstones round-trip and the next instance reuses the existing metric slab
	# slot rather than consuming configured instance capacity.
	var saved: PackedByteArray = ext.capture_effect_state()
	var restored: Dictionary = ext.restore_effect_state(saved)
	_require(bool(restored.get("ok", false)), "tombstone restore: %s" % str(restored))
	_require(bool(_submit(ext, 9002, target).get("ok", false)), "reused instance slot")
	var reused: Dictionary = ext.get_effect_report()
	_require(int(reused.get("instances", -1)) == 1 and
		int(reused.get("instance_storage_slots", -1)) == 1 and
		int(reused.get("free_instance_slots", -1)) == 0, str(reused))

	_test_event_once_rejection_retry()

	print("effect_lifecycle_test: PASS")
	quit()
