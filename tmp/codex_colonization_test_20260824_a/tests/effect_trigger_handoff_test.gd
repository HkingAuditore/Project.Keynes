extends SceneTree

const EffectDomainCatalogScript = preload("res://scripts/effect/effect_domain_catalog.gd")
const TriggerCatalogScript = preload("res://scripts/trigger/trigger_catalog.gd")
const TriggerDefinitionScript = preload("res://scripts/trigger/trigger_definition.gd")
const TriggerEffectScript = preload("res://scripts/trigger/trigger_effect.gd")
const ModifierFacadeScript = preload("res://scripts/modifier/modifier_facade.gd")

const Q16_ONE := 65536
const TARGET_ENTITY := 2
const SCOPE_ENTITY := 2
const MODIFIER_APPLY := 1
const AGG_COUNT := 1
const VALUE_ONE := 0
const MODE_REPEAT := 1
const TARGET_EVENT_ENTITY := 2

func _require(value: bool, message: String) -> void:
	assert(value, message)

func _init() -> void:
	var ext: Object = ClassDB.instantiate("DCWorldExt")
	_require(ext != null, "DCWorldExt unavailable")

	var modifier := ModifierFacadeScript.new()
	_require(bool(modifier.configure(ext, 1).get("ok", false)), "modifier configure")
	var effect_catalog: Resource = EffectDomainCatalogScript.build()
	_require(effect_catalog != null, "effect domain catalog")
	_require(bool(ext.configure_effects(effect_catalog.compile_native_catalog()).get("ok", false)),
		"effect configure")

	var trigger_catalog := TriggerCatalogScript.new()
	var trigger := TriggerDefinitionScript.new()
	trigger.key = &"test.native_modifier_trigger"
	trigger.source_id = 0
	trigger.event_type = 17
	trigger.aggregator = AGG_COUNT
	trigger.value_field = VALUE_ONE
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
	reward.value_mode = 0
	reward.value = Q16_ONE
	reward.command_key = &"trigger.modifier"
	reward.definition_key = &"gameplay.generic.bonus"
	trigger.effects = [reward]
	trigger_catalog.definitions = [trigger]
	_require(bool(ext.configure_triggers(trigger_catalog.compile_native_catalog()).get("ok", false)),
		"trigger configure")

	var target := int(ext.register_gameplay_modifier_object("trigger_handoff_test"))
	_require(target != 0, "gameplay target handle")
	var submitted: Dictionary = ext.submit_trigger_events({
		"event_ids": PackedInt64Array([1]),
		"source_ids": PackedInt32Array([0]),
		"days": PackedInt64Array([0]),
		"event_types": PackedInt32Array([17]),
		"payload_schemas": PackedInt32Array([0]),
		"entity_handles": PackedInt64Array([target]),
		"group_handles": PackedInt64Array([0]),
		"values": PackedInt64Array([1]),
		"payload_i0": PackedInt64Array([0]), "payload_i1": PackedInt64Array([0]),
		"payload_i2": PackedInt64Array([0]), "payload_i3": PackedInt64Array([0]),
	})
	_require(bool(submitted.get("ok", false)), "trigger event submit")
	_require(bool(ext.run_trigger_daily(0).get("ok", false)), "trigger daily")
	var handoff: Dictionary = ext.handoff_trigger_effects(8)
	_require(bool(handoff.get("ok", false)), str(handoff))
	_require(bool(handoff.get("native_supported", false)), str(handoff))
	_require(int(handoff.get("handed_off", 0)) == 1, str(handoff))
	_require(int(ext.poll_trigger_effects(0, 8).get("count", 0)) == 0,
		"trigger effect was not ACKed at handoff")

	var dispatch: Dictionary = ext.dispatch_effect_native_modifier()
	_require(bool(dispatch.get("ok", false)), str(dispatch))
	_require(int(dispatch.get("submitted_transactions", 0)) == 1, str(dispatch))
	_require(bool(ext.run_modifier_daily(1).get("ok", false)), "modifier daily")
	var native_ack: Dictionary = ext.ack_effect_native_modifier()
	_require(bool(native_ack.get("ok", false)), str(native_ack))
	_require(int(native_ack.get("acknowledged", 0)) == 1, str(native_ack))
	var modifiers := modifier.list_for_target(3, target)
	var definitions: PackedStringArray = modifiers.get("definition_keys", PackedStringArray())
	_require(definitions.has("gameplay.generic.bonus"), str(modifiers))

	print("effect_trigger_handoff_test: PASS")
	quit()
