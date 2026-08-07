extends SceneTree

const EffectDomainCatalogScript = preload("res://scripts/effect/effect_domain_catalog.gd")
const ModifierFacadeScript = preload("res://scripts/modifier/modifier_facade.gd")
const CountryFacadeScript = preload("res://scripts/country/country_facade.gd")

func _require(condition: bool, message: String) -> void:
	assert(condition, message)

func _init() -> void:
	var ext: Object = ClassDB.instantiate("DCWorldExt")
	_require(ext != null, "DCWorldExt unavailable")
	ext.create_entities(1)
	var modifier := ModifierFacadeScript.new()
	_require(bool(modifier.configure(ext, 1).get("ok", false)), "modifier configure")
	var effect_catalog: Resource = EffectDomainCatalogScript.build()
	_require(effect_catalog != null, "effect domain catalog")
	_require(bool(ext.configure_effects(effect_catalog.compile_native_catalog()).get("ok", false)),
		"effect configure")
	var country := CountryFacadeScript.new()
	_require(bool(country.configure(ext, 1, 991).get("ok", false)), "country configure")
	_require(bool(country.bootstrap(PackedByteArray([0])).get("ok", false)), "country bootstrap")

	var handle := int(ext.get_country_cell_summary(0).get("country_handle", 0))
	var technology_ids: PackedStringArray = country.native_catalog().get(
		"technology_ids", PackedStringArray())
	var technology_index := technology_ids.find("tech.autonomous_systems")
	_require(handle != 0 and technology_index >= 0, "technology test setup")
	_require(bool(country.grant_technology(handle, &"tech.autonomous_systems", 0, 1).get("ok", false)),
		"grant technology")
	_require(bool(ext.run_country_slice({"day_index": 0}).get("ok", false)), "country day 0")
	_require(bool(ext.run_effect_daily(0).get("ok", false)), "effect day 0")

	var native_submit: Dictionary = ext.dispatch_effect_native_modifier()
	_require(bool(native_submit.get("ok", false)), "native Effect -> Modifier submit")
	_require(int(native_submit.get("submitted_transactions", 0)) == 1, str(native_submit))
	# The native-bound transaction is intentionally hidden from the GDScript
	# adapter transport, preventing a second Modifier enqueue.
	_require(int(ext.poll_effect_transactions(0, 8).get("count", 0)) == 0,
		"native transaction leaked to fallback adapter")
	# Native request IDs are process-local. PKEF therefore serializes a
	# native-bound PREFLIGHTED transaction as PLANNED, so restore can replay the
	# idempotent Modifier command rather than leaving it permanently unbound.
	var pending_save: PackedByteArray = ext.capture_effect_state()
	_require(not pending_save.is_empty(), "capture native-bound effect state")
	_require(bool(ext.restore_effect_state(pending_save).get("ok", false)),
		"restore native-bound effect state")
	var restored_pending: Dictionary = ext.poll_effect_transactions(0, 8)
	_require(int(restored_pending.get("count", 0)) == 1, str(restored_pending))
	_require(int(restored_pending.statuses[0]) == 1, str(restored_pending)) # PLANNED
	var replay_submit: Dictionary = ext.dispatch_effect_native_modifier()
	_require(bool(replay_submit.get("ok", false)), str(replay_submit))
	_require(int(replay_submit.get("submitted_transactions", 0)) == 1, str(replay_submit))
	_require(bool(ext.run_modifier_daily(0).get("ok", false)), "modifier safe boundary")
	var native_ack: Dictionary = ext.ack_effect_native_modifier()
	_require(bool(native_ack.get("ok", false)) and int(native_ack.get("acknowledged", 0)) == 1,
		"native Effect ACK")
	_require(bool(ext.run_country_slice({"day_index": 1}).get("ok", false)), "country day 1")
	var snapshot: Dictionary = country.snapshot(handle)
	_require((snapshot.get("technology_ids", PackedStringArray()) as PackedStringArray).has(
		"tech.autonomous_systems"), "technology activation after native ACK")

	print("effect_native_modifier_bridge_test: PASS")
	quit()
