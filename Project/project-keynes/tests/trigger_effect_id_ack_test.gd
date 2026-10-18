extends SceneTree

# Delivery ACKs must address the exact effect ids the handoff returned. Effect
# ids are allocated at ingress, but handoff order is canonical
# (effective_day, source_priority, trigger_id, target_handle, fire_sequence), so
# the numeric high-water cursor can delete an effect that was never delivered.
#
# This regression forces the two orders apart:
#   trigger 0 (business first)  emits effect id 2
#   trigger 1 (business second) emits effect id 1
# and then hands off a single-effect prefix, asserting id 1 stays pending.
# The same scenario is replayed through a PKTR capture/restore round trip.

const EffectDomainCatalogScript = preload("res://scripts/effect/effect_domain_catalog.gd")
const TriggerCatalogScript = preload("res://scripts/trigger/trigger_catalog.gd")
const TriggerDefinitionScript = preload("res://scripts/trigger/trigger_definition.gd")
const TriggerEffectScript = preload("res://scripts/trigger/trigger_effect.gd")
const ModifierFacadeScript = preload("res://scripts/modifier/modifier_facade.gd")

const MODIFIER_APPLY := 1
const AGG_COUNT := 1
const SCOPE_ENTITY := 2
const TARGET_EVENT_ENTITY := 2
const MODE_REPEAT := 1
const VALUE_CONSTANT := 0
const EVENT_TYPE_FIRST := 17
const EVENT_TYPE_SECOND := 18
const Q16_ONE := 65536

var _failures := 0

func _require(value: bool, message: String) -> void:
	if not value:
		_failures += 1
		push_error(message)

func _build_trigger_catalog() -> Dictionary:
	var trigger_catalog := TriggerCatalogScript.new()
	var first := _make_trigger(&"test.delivery.first", EVENT_TYPE_FIRST)
	var second := _make_trigger(&"test.delivery.second", EVENT_TYPE_SECOND)
	trigger_catalog.definitions = [first, second]
	var compiled: Dictionary = trigger_catalog.compile_native_catalog()
	_require(bool(compiled.get("ok", false)), "trigger catalog compile: %s" % str(compiled))
	return compiled

func _make_trigger(key: StringName, event_type: int) -> Resource:
	var trigger := TriggerDefinitionScript.new()
	trigger.key = key
	trigger.source_id = 0
	trigger.event_type = event_type
	trigger.aggregator = AGG_COUNT
	trigger.value_field = 1
	trigger.scope = SCOPE_ENTITY
	trigger.target_resolver = TARGET_EVENT_ENTITY
	trigger.threshold = 1
	trigger.mode = MODE_REPEAT
	trigger.condition_ops = PackedInt32Array([1]) # PUSH_TRUE
	var reward := TriggerEffectScript.new()
	reward.action = MODIFIER_APPLY
	reward.domain = 3
	reward.opcode = 1
	reward.target_resolver = TARGET_EVENT_ENTITY
	reward.value_mode = VALUE_CONSTANT
	reward.value = Q16_ONE
	reward.command_key = &"trigger.modifier"
	reward.definition_key = &"gameplay.generic.bonus"
	trigger.effects = [reward]
	return trigger

func _make_ext(ext: Object, compiled_triggers: Dictionary, effect_catalog: Resource) -> int:
	var modifier := ModifierFacadeScript.new()
	_require(bool(modifier.configure(ext, 1).get("ok", false)), "modifier configure")
	_require(bool(ext.configure_effects(effect_catalog.compile_native_catalog()).get("ok", false)),
		"effect configure")
	_require(bool(ext.configure_triggers(compiled_triggers).get("ok", false)),
		"trigger configure")
	var target := int(ext.register_gameplay_modifier_object("trigger_id_ack_test"))
	_require(target != 0, "gameplay target handle")
	return target

func _submit_out_of_order(ext: Object, target: int) -> void:
	# Event order drives id allocation: second trigger first -> id 1, then first
	# trigger -> id 2. Business order sorts trigger 0 ahead of trigger 1.
	var submitted: Dictionary = ext.submit_trigger_events({
		"event_ids": PackedInt64Array([1, 2]),
		"source_ids": PackedInt32Array([0, 0]),
		"days": PackedInt64Array([0, 0]),
		"event_types": PackedInt32Array([EVENT_TYPE_SECOND, EVENT_TYPE_FIRST]),
		"payload_schemas": PackedInt32Array([0, 0]),
		"entity_handles": PackedInt64Array([target, target]),
		"group_handles": PackedInt64Array([0, 0]),
		"values": PackedInt64Array([1, 1]),
		"payload_i0": PackedInt64Array([0, 0]), "payload_i1": PackedInt64Array([0, 0]),
		"payload_i2": PackedInt64Array([0, 0]), "payload_i3": PackedInt64Array([0, 0]),
	})
	_require(bool(submitted.get("ok", false)), "trigger event submit: %s" % str(submitted))
	_require(bool(ext.run_trigger_daily(0).get("ok", false)), "trigger daily")

func _pending_ids(ext: Object) -> PackedInt64Array:
	var batch: Dictionary = ext.poll_trigger_effects(0, 8)
	return batch.get("effect_ids", PackedInt64Array())

func _init() -> void:
	var compiled_triggers := _build_trigger_catalog()
	var effect_catalog: Resource = EffectDomainCatalogScript.build()
	_require(effect_catalog != null, "effect domain catalog")

	# --- live path: canonical order differs from id order -------------------
	var ext: Object = ClassDB.instantiate("DCWorldExt")
	_require(ext != null, "DCWorldExt unavailable")
	var target := _make_ext(ext, compiled_triggers, effect_catalog)
	_submit_out_of_order(ext, target)
	var pending: PackedInt64Array = _pending_ids(ext)
	_require(pending.size() == 2 and int(pending[0]) == 2 and int(pending[1]) == 1,
		"canonical pending order must be id 2 then id 1, got %s" % str(pending))

	var capture: PackedByteArray = ext.capture_trigger_state()

	var first_handoff: Dictionary = ext.handoff_trigger_effects(1)
	_require(int(first_handoff.get("handed_off", 0)) == 1, str(first_handoff))
	var handed_ids: PackedInt64Array = first_handoff.get("effect_ids", PackedInt64Array())
	_require(handed_ids.size() == 1 and int(handed_ids[0]) == 2,
		"handoff must report the delivered id 2, got %s" % str(handed_ids))
	pending = _pending_ids(ext)
	_require(pending.size() == 1 and int(pending[0]) == 1,
		"undelivered id 1 must stay pending after acking id 2, got %s" % str(pending))
	_require(int(first_handoff.get("acked_effect_id", -1)) == 0,
		"numeric cursor must not advance past the id-1 hole, got %s"
		% str(first_handoff.get("acked_effect_id", -1)))

	# Explicitly re-ack the same id set: idempotent, still only id 1 pending.
	var reack: Dictionary = ext.ack_trigger_effect_ids(handed_ids)
	_require(bool(reack.get("ok", false)), str(reack))
	pending = _pending_ids(ext)
	_require(pending.size() == 1 and int(pending[0]) == 1,
		"repeated id ack must not delete the undelivered id 1, got %s" % str(pending))

	var second_handoff: Dictionary = ext.handoff_trigger_effects(1)
	_require(int(second_handoff.get("handed_off", 0)) == 1, str(second_handoff))
	pending = _pending_ids(ext)
	_require(pending.is_empty(), "all delivered effects must be gone, got %s" % str(pending))

	# --- PKTR round trip: restore then ack the same way ---------------------
	var restored: Object = ClassDB.instantiate("DCWorldExt")
	_require(restored != null, "DCWorldExt unavailable")
	_make_ext(restored, compiled_triggers, effect_catalog)
	var restore_result: Dictionary = restored.restore_trigger_state(capture)
	_require(bool(restore_result.get("ok", false)),
		"PKTR restore: %s" % str(restore_result))
	pending = _pending_ids(restored)
	_require(pending.size() == 2 and int(pending[0]) == 2 and int(pending[1]) == 1,
		"restored pending order must be id 2 then id 1, got %s" % str(pending))
	var restored_handoff: Dictionary = restored.handoff_trigger_effects(1)
	_require(int(restored_handoff.get("handed_off", 0)) == 1, str(restored_handoff))
	pending = _pending_ids(restored)
	_require(pending.size() == 1 and int(pending[0]) == 1,
		"restored undelivered id 1 must stay pending, got %s" % str(pending))
	var restored_ack: Dictionary = restored.ack_trigger_effect_ids(
		restored_handoff.get("effect_ids", PackedInt64Array()))
	_require(bool(restored_ack.get("ok", false)), str(restored_ack))
	_require(_pending_ids(restored).size() == 1,
		"restored id ack must not delete the undelivered id 1")

	print("trigger_effect_id_ack_test: %s" % ("PASS" if _failures == 0 else "FAIL"))
	quit(0 if _failures == 0 else 1)
