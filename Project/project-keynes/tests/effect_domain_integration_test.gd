extends SceneTree

const EffectDomainCatalogScript = preload("res://scripts/effect/effect_domain_catalog.gd")
const EffectFacadeScript = preload("res://scripts/effect/effect_facade.gd")
const ModifierFacadeScript = preload("res://scripts/modifier/modifier_facade.gd")
const CountryFacadeScript = preload("res://scripts/country/country_facade.gd")

const COUNTRY_DOMAIN := 1
var _failures := 0

func _init() -> void:
	if not ClassDB.class_exists("DCWorldExt"):
		print("effect_domain_integration_test: SKIP (DCWorldExt unavailable)")
		quit(0)
		return
	var ext: Object = ClassDB.instantiate("DCWorldExt")
	ext.create_entities(1)
	var modifier := ModifierFacadeScript.new()
	var modifier_config := modifier.configure(ext, 1)
	_assert_ok(modifier_config, "modifier configure")
	var effect := EffectFacadeScript.new()
	var effect_config := effect.configure(ext, null, EffectDomainCatalogScript.build())
	_assert_ok(effect_config, "effect configure")
	var country := CountryFacadeScript.new()
	var country_config := country.configure(ext, 1, 991)
	_assert_ok(country_config, "country configure")
	effect.register_domain_adapters(modifier, country, null)
	_assert_ok(country.bootstrap(PackedByteArray([0])), "country bootstrap")

	var handle := int(ext.get_country_cell_summary(0).get("country_handle", 0))
	_require(handle != 0, "country handle missing")
	var technology_ids: PackedStringArray = country.native_catalog().get(
		"technology_ids", PackedStringArray())
	var technology_index := technology_ids.find("tech.autonomous_systems")
	_require(technology_index >= 0, "integration technology missing")
	var modifier_keys: PackedStringArray = country.native_catalog().get(
		"technology_modifier_definition_keys", PackedStringArray())
	var modifier_key := String(modifier_keys[technology_index])
	_require(not modifier_key.is_empty(), "integration technology modifier missing")

	# Grant queues the technology. The country must remain pending until the
	# Effect transaction has reached Modifier Runtime and been acknowledged.
	_assert_ok(country.grant_technology(handle, &"tech.autonomous_systems", 0, 1),
		"grant technology command")
	var country_day0: Dictionary = ext.run_country_slice({"day_index": 0})
	_assert_ok(country_day0, "country day 0")
	var snapshot0: Dictionary = country.snapshot(handle)
	_require(not (snapshot0.get("technology_ids", PackedStringArray()) as PackedStringArray).has(
		"tech.autonomous_systems"), "technology exposed before effect ACK")

	_assert_ok(ext.run_effect_daily(0), "effect day 0")
	var modifier_dispatch: Dictionary = ext.dispatch_effect_native_modifier()
	_require(int(modifier_dispatch.get("submitted_transactions", 0)) == 1 and
		int(modifier_dispatch.get("submitted_commands", 0)) == 1,
		"technology Modifier command enters the native adapter")
	var gameplay_dispatch: Dictionary = ext.dispatch_effect_native_gameplay()
	_require(int(gameplay_dispatch.get("submitted_transactions", 0)) == 1 and
		int(gameplay_dispatch.get("submitted_commands", 0)) == 1,
		"technology.adopted enters the native event adapter")
	var fallback_dispatch := effect.dispatch_transactions()
	_assert_ok(fallback_dispatch, "effect fallback dispatch")
	_require(int(fallback_dispatch.get("dispatched", 0)) == 0 and
		int(fallback_dispatch.get("native_claimed_transactions", 0)) == 1,
		"native technology transaction stays out of GDScript fallback")
	var modifier_day0: Dictionary = ext.run_modifier_daily(0)
	_assert_ok(modifier_day0, "modifier day 0")
	var modifier_ack: Dictionary = ext.ack_effect_native_modifier()
	_require(int(modifier_ack.get("acknowledged", 0)) == 1,
		"Modifier safe boundary ACKs its technology command")
	_require(int(ext.get_effect_report().get("transactions_acked", 0)) == 0,
		"technology remains pending until adoption event commits")
	var gameplay_commit: Dictionary = ext.run_gameplay_effects(0)
	_require(bool(gameplay_commit.get("ok", false)) and
		int(gameplay_commit.get("committed", 0)) == 1,
		"technology.adopted publishes exactly once")
	var gameplay_ack: Dictionary = ext.ack_effect_native_gameplay()
	_require(int(gameplay_ack.get("acknowledged", 0)) == 1 and
		int(ext.get_effect_report().get("transactions_acked", 0)) == 1,
		"technology Effect ACKs only after all domains commit")
	var modifiers_after_commit := modifier.list_for_target(COUNTRY_DOMAIN, handle)
	var definitions_after_commit: PackedStringArray = modifiers_after_commit.get(
		"definition_keys", PackedStringArray())
	_require(definitions_after_commit.size() == 1,
		"technology modifier stacked more than once")

	# The next country boundary consumes the ACK and activates the technology.
	_assert_ok(ext.run_country_slice({"day_index": 1}), "country day 1")
	var snapshot1: Dictionary = country.snapshot(handle)
	_require((snapshot1.get("technology_ids", PackedStringArray()) as PackedStringArray).has(
		"tech.autonomous_systems"), "technology did not activate after ACK")

	# The instance cadence is preserved: the country retry must not reset it and
	# create a second Modifier stack on the following Effect evaluation.
	_assert_ok(ext.run_effect_daily(1), "effect day 1")
	var no_duplicate := effect.dispatch_transactions()
	_assert_ok(no_duplicate, "effect duplicate dispatch")
	_require(int(no_duplicate.get("dispatched", 0)) == 0,
		"technology effect fired a duplicate transaction")
	_require(int(ext.run_gameplay_effects(1).get("committed", 0)) == 0,
		"technology.adopted event is idempotent")
	print("effect_domain_integration_test: %s" % ("PASS" if _failures == 0 else "FAIL"))
	quit(0 if _failures == 0 else 1)

func _assert_ok(result: Dictionary, label: String) -> void:
	_require(bool(result.get("ok", false)), "%s: %s" % [label, str(result)])

func _require(condition: bool, label: String) -> void:
	if condition:
		return
	_failures += 1
	push_error("[FAIL] %s" % label)
