extends SceneTree

# M2b-5 gate: a technology Effect instance is an Effect instance like any other.
#
# NativeCountryRuntime::bootstrap installs one instance per (country, technology)
# that survived the restore, and the country peer adapter installs one when the
# adapter asks for ENSURE_TECHNOLOGY_EFFECT. Both used to call
# EffectRuntime::upsert_instance_pod directly -- the same mistake M2b-2 fixed for
# the family writes. Under F8 ACTIVE EffectRuntime is writeback-only, so the row
# landed in a mirror that the next worker snapshot erased; and even on the legacy
# authority the direct call skipped the forwarder's shadow mirror, so an
# authority flip lost every technology instance installed before it.
#
# The observable is the same one family_effect_worker_forward_test uses: which
# side's instance list grows.
#
#   * legacy  -> EffectRuntime owns it, get_effect_report().instances grows
#   * worker  -> EffectRuntime owns nothing, the row went to the pod transport
#
# `bootstrap_effect_rejected` is the second half: the pre-M2b code discarded the
# upsert result, so a technology whose Effect program does not resolve restored
# as "country knows the technology, Effect has nothing" with no trace at all.

const EconomyCatalogScript = preload("res://scripts/economy/economy_catalog.gd")
const ModifierCatalogScript = preload("res://scripts/modifier/modifier_catalog.gd")
const TechnologyCatalogScript = preload("res://scripts/economy/technology_catalog.gd")
const EffectDomainCatalogScript = preload("res://scripts/effect/effect_domain_catalog.gd")
const LandformTypeScript = preload("res://scripts/geography/landform_type.gd")

var _checks := 0
var _failures := 0


func _init() -> void:
	_run()
	print("=== technology effect worker forward: %d checks, %d failures ===" % [
		_checks, _failures])
	quit(0 if _failures == 0 else 1)


func _run() -> void:
	if not ClassDB.class_exists("DCWorldExt"):
		_fail("DCWorldExt unavailable")
		return
	var catalog: Dictionary = EconomyCatalogScript.compile_native_catalog()
	_expect("production economy catalog compiles", bool(catalog.get("ok", true)))
	var domain: Resource = EffectDomainCatalogScript.build()
	if domain == null:
		_fail("production effect domain catalog builds")
		return
	var effect_ir: Dictionary = domain.compile_native_catalog()
	_expect("production effect IR compiles", bool(effect_ir.get("ok", false)))
	if not bool(effect_ir.get("ok", false)):
		return
	effect_ir.erase("ok")

	var technology := _pick_technology(catalog)
	_expect("fixture finds a non-starting technology that carries a modifier",
		technology >= 0)
	if technology < 0:
		return
	var technology_key := "technology.%s" % String(
			(catalog.technology_ids as PackedStringArray)[technology])
	print("technology effect forward: probing %s (dense %d)" % [
		technology_key, technology])
	# Legacy keeps EffectRuntime as the writer of record, so the instance has to
	# be visible in its report.
	_bootstrap_telemetry(catalog, effect_ir, technology, 0, 1, "legacy")
	# Worker authority: the sync facade must stay empty. Before M2b-5 this read 1,
	# because the bootstrap write ignored the authority split entirely.
	_bootstrap_telemetry(catalog, effect_ir, technology, 1, 0, "worker")


## Bootstraps a one-cell country holding exactly one non-starting technology and
## returns what each authority recorded. `expected_instances` is the count the
## legacy EffectRuntime must report afterwards.
func _bootstrap_telemetry(catalog: Dictionary, effect_ir: Dictionary,
		technology: int, override_mode: int, expected_instances: int,
		label: String) -> Dictionary:
	var ext: Object = _new_ext(catalog)
	# Effect has to exist before the country bootstrap: bootstrap is what installs
	# the technology instances, so a null EffectRuntime would make the whole run
	# vacuous.
	var effects_configured: Dictionary = ext.configure_effects(effect_ir)
	_expect("%s: effect runtime configures" % label,
		bool(effects_configured.get("ok", false)))
	if not bool(effects_configured.get("ok", false)):
		return {}
	# The worker row is dropped by the transport unless the pod catalog compiled,
	# which would read as "rerouted correctly" for the wrong reason.
	_expect("%s: effect pod catalog compiles" % label,
		bool(effects_configured.get("effect_pod_ready", false)))
	var seam: Dictionary = ext.set_effect_forwarder_authority_for_test(override_mode)
	_expect("%s: seam reports the requested authority" % label,
		bool(seam.get("worker_authoritative", false)) == (override_mode != 0))
	# Empty starting set: the technology has to arrive through the bootstrap
	# packet, otherwise the profile would grant it and the packet would be inert.
	var configured: Dictionary = ext.configure_country(catalog, {
		"country_runtime_mode": "ACTIVE",
		"starting_technology_ids": PackedStringArray(),
	}, 1, 210821)
	_expect("%s: country configures" % label,
		bool(configured.get("ok", false)))
	if not bool(configured.get("ok", false)):
		return {}
	var boot: Dictionary = ext.bootstrap_country({
		"country_ids": PackedStringArray(["country.technology_forward_test"]),
		"country_names": PackedStringArray(["技术效果转测试国"]),
		"country_cash": PackedInt64Array([0]),
		"territory_offsets": PackedInt32Array([0, 1]),
		"territory_cells": PackedInt32Array([0]),
		"technology_offsets": PackedInt32Array([0, 1]),
		"technology_indices": PackedInt32Array([technology]),
		"treasury_offsets": PackedInt32Array([0, 0]),
		"treasury_good_indices": PackedInt32Array(),
		"treasury_quantities": PackedInt64Array(),
	}, PackedByteArray([0]))
	_expect("%s: country bootstraps" % label, bool(boot.get("ok", false)))
	if not bool(boot.get("ok", false)):
		return {}
	_expect("%s: bootstrap reports the effect install outcome" % label,
		boot.has("bootstrap_effect_rejected"))
	# A refusal here means the technology's Effect program did not resolve and the
	# country restored with a technology the Effect domain never learned about.
	_expect("%s: bootstrap installs the technology effect" % label,
		int(boot.get("bootstrap_effect_rejected", -1)) == 0)
	var report: Dictionary = ext.get_effect_report()
	_expect("%s: EffectRuntime holds %d instance(s)" % [label, expected_instances],
		int(report.get("instances", -1)) == expected_instances)
	print("  %s: instances=%d rejected=%d" % [
		label, int(report.get("instances", -1)),
		int(boot.get("bootstrap_effect_rejected", -1))])
	return boot


## First technology that is not a starting technology (those deliberately get no
## Effect program, see effect_domain_catalog.gd) and carries a modifier key (the
## country bootstrap skips technologies without one) -- and consequently resolves
## `technology.<id>` in the Effect catalog.
func _pick_technology(catalog: Dictionary) -> int:
	var technology_catalog: Dictionary = TechnologyCatalogScript.compile_native_catalog()
	if not bool(technology_catalog.get("ok", false)):
		return -1
	var ids: PackedStringArray = technology_catalog.technology_ids
	var modifiers: PackedStringArray = technology_catalog.get(
		"technology_modifier_definition_keys", PackedStringArray())
	var flags: PackedInt32Array = technology_catalog.get(
		"technology_flags", PackedInt32Array())
	var dense: PackedStringArray = catalog.get("technology_ids",
		PackedStringArray())
	for i in range(mini(ids.size(), modifiers.size())):
		if String(modifiers[i]).is_empty():
			continue
		if i < flags.size() and (int(flags[i]) &
				TechnologyCatalogScript.FLAG_STARTING) != 0:
			continue
		var index := dense.find(String(ids[i]))
		if index >= 0:
			return index
	return -1


## Minimal one-cell world: the country bootstrap only needs the landform and the
## is_water byte, and the effect install path does not touch economy state.
func _new_ext(catalog: Dictionary) -> Object:
	var ext: Object = ClassDB.instantiate("DCWorldExt")
	ext.create_entities(1)
	var modifier_catalog: Dictionary = ModifierCatalogScript.load_default().compile_native_catalog()
	modifier_catalog.erase("ok")
	ext.configure_modifiers(modifier_catalog, 1)
	for slot_name in [&"cell_temp", &"cell_temp_30d", &"cell_moisture",
			&"cell_plant_available_water", &"cell_weather_precip",
			&"cell_snow_cover", &"cell_weather_intensity", &"cell_elevation"]:
		var sid: int = ext.register_component(slot_name, 0, 1, false)
		ext.write_f32_range(sid, 0, PackedFloat32Array([0.5]))
	for slot_name in [&"cell_terrain", &"cell_landform", &"cell_vegetation",
			&"cell_is_water", &"cell_has_river"]:
		var sid: int = ext.register_component(slot_name, 2, 1, false)
		var value := 0
		if slot_name == &"cell_landform":
			value = LandformTypeScript.LF.PLAIN
		ext.write_u8_range(sid, 0, PackedByteArray([value]))
	for i in range((catalog.building_resource_ids as PackedStringArray).size()):
		var reserve_sid: int = ext.register_component(StringName(
			(catalog.building_resource_reserve_slots as PackedStringArray)[i]),
			0, 1, false)
		var extra_sid: int = ext.register_component(StringName(
			(catalog.building_resource_extra_slots as PackedStringArray)[i]),
			0, 1, false)
		ext.write_f32_range(reserve_sid, 0, PackedFloat32Array([1000000.0]))
		ext.write_f32_range(extra_sid, 0, PackedFloat32Array([0.0]))
	return ext


func _expect(label: String, ok: bool) -> void:
	_checks += 1
	if not ok:
		_failures += 1
		print("  [FAIL] %s" % label)


func _fail(label: String) -> void:
	_checks += 1
	_failures += 1
	print("  [FAIL] %s" % label)
