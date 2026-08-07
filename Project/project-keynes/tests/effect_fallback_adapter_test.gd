extends SceneTree

const EffectDomainCatalogScript = preload("res://scripts/effect/effect_domain_catalog.gd")
const EffectFacadeScript = preload("res://scripts/effect/effect_facade.gd")
const ModifierFacadeScript = preload("res://scripts/modifier/modifier_facade.gd")

const Q16_ONE := 65536


func _require(value: bool, message: String) -> void:
	assert(value, message)


func _command(definition_key: StringName, target: int, generation: int,
		idempotency_key: int, day: int, value_q16: int = Q16_ONE) -> Dictionary:
	return {
		"phase": &"commit",
		"definition_key": definition_key,
		"target_handle": target,
		"target_generation": generation,
		"value_q16": value_q16,
		"idempotency_key": idempotency_key,
		"transaction": {"effective_day": day, "source_instance_id": idempotency_key},
	}


func _preflight(command: Dictionary) -> Dictionary:
	var result := command.duplicate(true)
	result["phase"] = &"preflight"
	return result


func _init() -> void:
	var ext: Object = ClassDB.instantiate("DCWorldExt")
	_require(ext != null, "DCWorldExt unavailable")
	var modifier := ModifierFacadeScript.new()
	_require(bool(modifier.configure(ext, 1).get("ok", false)), "modifier configure")
	var effect := EffectFacadeScript.new()
	var catalog: Resource = EffectDomainCatalogScript.build()
	_require(catalog != null, "effect domain catalog")
	_require(bool(effect.configure(ext, null, catalog).get("ok", false)), "effect configure")
	effect.register_domain_adapters(modifier)

	var family_adapter: Callable = effect.call("_find_adapter", 1,
		ModifierFacadeScript.Domain.ECONOMY, &"family.modifier")
	var person_adapter: Callable = effect.call("_find_adapter", 1,
		ModifierFacadeScript.Domain.GAMEPLAY, &"person.modifier")
	_require(family_adapter.is_valid(), "family fallback adapter registered")
	_require(person_adapter.is_valid(), "person fallback adapter registered")

	var person_target := int(ext.register_gameplay_modifier_object("effect_fallback_person"))
	_require(person_target != 0, "gameplay target")
	var person_command := _command(&"gameplay.generic.bonus", person_target,
		int(person_target >> 32), 9001, 0)
	var person_preflight: Dictionary = person_adapter.call(_preflight(person_command))
	_require(bool(person_preflight.get("ok", false)) and
		int(person_preflight.get("ack_mask", 0)) == 1,
		str(person_preflight))
	var person_pending: Dictionary = person_adapter.call(person_command)
	_require(not bool(person_pending.get("ok", true)), str(person_pending))
	_require(bool(ext.run_modifier_daily(0).get("ok", false)), "person modifier boundary")
	var person_committed: Dictionary = person_adapter.call(person_command)
	_require(bool(person_committed.get("ok", false)) and
		int(person_committed.get("ack_mask", 0)) == 1,
		str(person_committed))
	var person_modifiers: Dictionary = modifier.list_for_target(
		ModifierFacadeScript.Domain.GAMEPLAY, person_target)
	_require((person_modifiers.get("definition_keys", PackedStringArray()) as PackedStringArray)
		.has("gameplay.generic.bonus"), str(person_modifiers))

	var family_command := _command(&"family.city.production_boost", 123, 0, 9002, 1)
	var family_preflight: Dictionary = family_adapter.call(_preflight(family_command))
	_require(bool(family_preflight.get("ok", false)) and
		int(family_preflight.get("ack_mask", 0)) == 1,
		str(family_preflight))
	var family_pending: Dictionary = family_adapter.call(family_command)
	_require(not bool(family_pending.get("ok", true)), str(family_pending))
	_require(bool(ext.run_modifier_daily(1).get("ok", false)), "family modifier boundary")
	var family_committed: Dictionary = family_adapter.call(family_command)
	_require(bool(family_committed.get("ok", false)) and
		int(family_committed.get("ack_mask", 0)) == 1,
		str(family_committed))
	var family_modifiers: Dictionary = modifier.list_for_target(ModifierFacadeScript.Domain.ECONOMY, 0)
	_require((family_modifiers.get("definition_keys", PackedStringArray()) as PackedStringArray)
		.has("family.city.production_boost"), str(family_modifiers))

	print("effect_fallback_adapter_test: PASS")
	quit()
