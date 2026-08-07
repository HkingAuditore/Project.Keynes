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
	_require(int(ext.dispatch_effect_native_modifier().get("submitted_transactions", 0)) == 1,
		"retirement remove submit")
	_require(bool(ext.run_modifier_daily(1).get("ok", false)), "retirement modifier boundary")
	_require(int(ext.ack_effect_native_modifier().get("acknowledged", 0)) == 1,
		"retirement native ACK")
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

	print("effect_lifecycle_test: PASS")
	quit()
