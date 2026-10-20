extends SceneTree

# M2b-4 gate: rebuilding the family effect bindings after a save restore must not
# depend on which side owns EFFECT.
#
# reconcile_family_branch_effects(branch, submit_changes = false) is the restore
# entry: Economy persists family influence rows but not the Effect bindings, so
# after deserialize it walks the desired set and re-adds a binding only for the
# instances that are still alive. It asks
# `_effect_runtime->has_instance_pod(...)` -- a query that only answers for the
# legacy authority. This test pins the observable either way:
#
#   * same-ext restore  -> the loaded EffectRuntime already holds the instances,
#                          so the binding must come back with present == 1
#   * fresh-ext restore -> PKEF is applied before ECP2 (see the provider order in
#                          game_save_coordinator.gd), so it must also come back
#
# If a future change moves the Effect restore to the worker only, the fresh-ext
# case is what will break first; that is why the assertion is "binding exists",
# not "binding exists because has_instance_pod happened to be true".
#
# Everything else (catalogs, fixture, profile) mirrors
# family_effect_worker_forward_test.gd on purpose: the two gates then differ only
# in what they assert.

const EconomyCatalogScript = preload("res://scripts/economy/economy_catalog.gd")
const ModifierCatalogScript = preload("res://scripts/modifier/modifier_catalog.gd")
const FamilyEffectCatalogScript = preload("res://scripts/family/family_effect_catalog.gd")
const FamilyEffectDefinitionScript = preload("res://scripts/family/family_effect_definition.gd")
const EffectDomainCatalogScript = preload("res://scripts/effect/effect_domain_catalog.gd")
const LandformTypeScript = preload("res://scripts/geography/landform_type.gd")

const Q16_ONE := 65536
const FAMILY_EFFECT_KEY := "family.effect.pool_probe"

var _checks := 0
var _failures := 0


func _init() -> void:
	_run()
	print("=== family effect restore forward: %d checks, %d failures ===" % [
		_checks, _failures])
	quit(0 if _failures == 0 else 1)


func _run() -> void:
	if not ClassDB.class_exists("DCWorldExt"):
		_fail("DCWorldExt unavailable")
		return
	var family_effects := FamilyEffectCatalogScript.new()
	family_effects.version = 1
	var authored: Array[Resource] = [_pool_effect()]
	family_effects.effects = authored
	var catalog: Dictionary = EconomyCatalogScript.compile_native_catalog(family_effects)
	_expect("fixture family-effect catalog compiles", bool(catalog.get("ok", false)))
	if not bool(catalog.get("ok", false)):
		return
	var domain: Resource = EffectDomainCatalogScript.build(family_effects)
	_expect("effect domain catalog accepts the fixture family effect", domain != null)
	if domain == null:
		return
	var effect_ir: Dictionary = domain.compile_native_catalog()
	_expect("fixture effect IR compiles", bool(effect_ir.get("ok", false)))
	if not bool(effect_ir.get("ok", false)):
		return
	effect_ir.erase("ok")
	_restore_in_place(catalog, effect_ir, "legacy")
	_restore_fresh(catalog, effect_ir, "legacy")
	_restore_fresh(catalog, effect_ir, "worker")


## Same-ext restore, the shape family_colony_birth_runtime_test already uses:
## Economy clears its bindings and reconciles against the live EffectRuntime.
func _restore_in_place(catalog: Dictionary, effect_ir: Dictionary,
		label: String) -> void:
	var ext: Object = _open(catalog, effect_ir, 0, label)
	if ext == null:
		return
	var family_handle := _family_handle(ext, label)
	if family_handle == 0:
		return
	var before := _effect_keys(ext, family_handle, label + "/in-place")
	var economy: Dictionary = ext.capture_economy_ecp2(0)
	_expect("%s/in-place: ECP2 captures" % label, bool(economy.get("ok", false)))
	if not bool(economy.get("ok", false)):
		return
	var restored: Dictionary = ext.restore_economy_ecp2(economy.bytes)
	_expect("%s/in-place: ECP2 restores" % label, bool(restored.get("ok", false)))
	if not bool(restored.get("ok", false)):
		return
	var after := _effect_keys(ext, family_handle, label + "/in-place")
	if after.size() != before.size() or after.size() != 1:
		print("%s/in-place before=" % label, before,
			" after=", after,
			" report=", ext.get_family_branch_effects(family_handle, 0),
			" families=", ext.get_family_cell_snapshot(0, 0, 64))
	_expect("%s/in-place: binding survives restore" % label,
		after.size() == before.size() and after.size() == 1)
	_expect("%s/in-place: ownership bit stays 1" % label,
		_present_at(ext, family_handle) == 1)


## Fresh-ext restore, the path game_save_coordinator actually runs: PKEF lands on
## the new EffectRuntime first, then ECP2 reconciles Economy against it.
func _restore_fresh(catalog: Dictionary, effect_ir: Dictionary,
		label: String) -> void:
	var source: Object = _open(catalog, effect_ir, 0, label)
	if source == null:
		return
	var family_handle := _family_handle(source, label)
	if family_handle == 0:
		return
	var before := _effect_keys(source, family_handle, label + "/fresh")
	var effect_bytes: PackedByteArray = source.capture_effect_state()
	_expect("%s/fresh: PKEF captures bytes" % label, effect_bytes.size() > 0)
	var economy: Dictionary = source.capture_economy_ecp2(0)
	_expect("%s/fresh: ECP2 captures" % label, bool(economy.get("ok", false)))
	if effect_bytes.is_empty() or not bool(economy.get("ok", false)):
		return
	var target: Object = _configure_only(catalog, effect_ir, 0, label)
	if target == null:
		return
	var effect_restore: Dictionary = target.restore_effect_state(effect_bytes)
	_expect("%s/fresh: PKEF restores" % label,
		bool(effect_restore.get("ok", false)))
	if not bool(effect_restore.get("ok", false)):
		print("%s PKEF restore=" % label, effect_restore)
		return
	var economy_restore: Dictionary = target.restore_economy_ecp2(economy.bytes)
	_expect("%s/fresh: ECP2 restores" % label,
		bool(economy_restore.get("ok", false)))
	if not bool(economy_restore.get("ok", false)):
		print("%s ECP2 restore=" % label, economy_restore)
		return
	var after := _effect_keys(target, family_handle, label + "/fresh")
	_expect("%s/fresh: binding survives restore" % label,
		after.size() == before.size() and after.size() == 1)
	_expect("%s/fresh: instance identity is unchanged" % label,
		_instance_ids(target, family_handle) ==
		_instance_ids(source, family_handle))


func _effect_keys(ext: Object, family_handle: int, label: String) -> PackedStringArray:
	var report: Dictionary = ext.get_family_branch_effects(family_handle, 0)
	_expect("%s: branch effect report is ok" % label, bool(report.get("ok", false)))
	return report.get("effect_definition_keys", PackedStringArray())


func _instance_ids(ext: Object, family_handle: int) -> PackedInt64Array:
	return ext.get_family_branch_effects(family_handle, 0).get(
		"effect_instance_ids", PackedInt64Array())


func _present_at(ext: Object, family_handle: int) -> int:
	var present: PackedByteArray = ext.get_family_branch_effects(
		family_handle, 0).get("effect_present", PackedByteArray())
	return int(present[0]) if present.size() > 0 else -1


func _family_handle(ext: Object, label: String) -> int:
	var page: Dictionary = ext.get_family_cell_snapshot(0, 0, 64)
	if int(page.get("total", 0)) != 1:
		_fail("%s: fixture forms one founder family" % label)
		return 0
	return int((page.family_handles as PackedInt64Array)[0])


## Configures everything and runs the opening day, so the founding random-pool
## grant has produced one family effect instance.
func _open(catalog: Dictionary, effect_ir: Dictionary, override_mode: int,
		label: String) -> Object:
	var ext: Object = _configure_only(catalog, effect_ir, override_mode, label)
	if ext == null:
		return null
	if not _bootstrap_opening(ext, catalog, label):
		return null
	var day0: Dictionary = _run_day(ext, 0)
	_expect("%s: opening day completes" % label, bool(day0.get("done", false)))
	return ext


## Configures the world but stops before bootstrap: the fresh-ext restore target
## has to receive its state from the save, not from a local opening.
func _configure_only(catalog: Dictionary, effect_ir: Dictionary,
		override_mode: int, label: String) -> Object:
	var ext: Object = _new_ext(catalog, LandformTypeScript.LF.PLAIN)
	var native_economy := catalog.duplicate(true)
	native_economy.erase("ok")
	_expect("%s: country bootstraps" % label,
		_configure_country(ext, catalog, 210821))
	var effects_configured: Dictionary = ext.configure_effects(effect_ir)
	_expect("%s: effect runtime configures" % label,
		bool(effects_configured.get("ok", false)))
	ext.set_effect_forwarder_authority_for_test(override_mode)
	_expect("%s: economy configures" % label,
		bool(ext.configure_economy(native_economy, _active_profile(), 1,
			210821).get("ok", false)))
	return ext


func _pool_effect() -> Resource:
	var command := EffectCommand.new()
	command.action = 1
	command.domain = 2
	command.opcode = 1
	command.target_resolver = 1
	command.command_key = &"family.effect.pool.probe"
	command.definition_key = &"family.city.food_consumption_boost"
	var constant := EffectInstruction.new()
	constant.op = 1
	constant.value_q16 = Q16_ONE
	var emit := EffectInstruction.new()
	emit.op = 11
	var end := EffectInstruction.new()
	end.op = 12
	var instructions: Array[Resource] = [constant, emit, end]
	var commands: Array[Resource] = [command]
	var effect := FamilyEffectDefinitionScript.new()
	effect.key = &"pool_probe"
	effect.source_kind = FamilyEffectDefinitionScript.SourceKind.RANDOM_POOL
	effect.random_pool_eligible = true
	effect.operation = FamilyEffectDefinitionScript.Operation.MULTIPLY
	effect.target_domain = FamilyEffectDefinitionScript.TargetDomain.FAMILY
	effect.instructions = instructions
	effect.commands = commands
	effect.magnitude_by_prestige_q16 = PackedInt32Array([
		Q16_ONE, Q16_ONE, Q16_ONE, Q16_ONE, Q16_ONE, Q16_ONE])
	return effect


func _active_profile() -> Dictionary:
	var profile: Dictionary = load(
		"res://data/economy/default_economy.tres").to_native_profile()
	profile.family_runtime_mode = "ACTIVE"
	profile.family_review_days = 1
	profile.family_milestone_populations = PackedInt64Array([1, 2, 3, 4, 5, 6, 7, 8])
	profile.family_min_founder_people = 20
	profile.family_founding_choice_mode = "AUTO"
	profile.notable_person_runtime_mode = "ACTIVE"
	profile.starvation_death_rate_q32 = 0
	return profile


func _bootstrap_opening(ext: Object, catalog: Dictionary, label: String) -> bool:
	var building_id := (catalog.building_type_ids as PackedStringArray).find(
		"gathering_ground")
	var owner_sig := (catalog.signature_keys as PackedStringArray).find(
		"forager|default")
	var unemployed_sig := (catalog.signature_keys as PackedStringArray).find(
		"unemployed|default")
	var stock := PackedInt64Array()
	stock.resize((catalog.good_ids as PackedStringArray).size())
	stock.fill(100000000)
	var boot: Dictionary = ext.bootstrap_economy({
		"cell_indices": PackedInt32Array([0, 0]),
		"signature_ids": PackedInt32Array([owner_sig, unemployed_sig]),
		"population": PackedInt64Array([2, 18]),
		"funds": PackedInt64Array([1000000000000000, 1000000000000000]),
		"forced_named_cells": PackedInt32Array([0]),
		"founder_family_cells": PackedInt32Array([0]),
		"founder_family_building_type_ids": PackedInt32Array([building_id]),
		"founder_family_owner_signature_ids": PackedInt32Array([owner_sig]),
	}, {
		"stock": stock,
		"building_cells": PackedInt32Array([0]),
		"building_type_ids": PackedInt32Array([building_id]),
		"building_owner_signature_ids": PackedInt32Array([owner_sig]),
		"building_counts": PackedInt64Array([1]),
	})
	_expect("%s: opening family bootstraps" % label, bool(boot.get("ok", false)))
	return bool(boot.get("ok", false))


func _new_ext(catalog: Dictionary, landform: int) -> Object:
	var ext: Object = ClassDB.instantiate("DCWorldExt")
	ext.create_entities(1)
	var modifier_catalog: Dictionary = ModifierCatalogScript.load_default().compile_native_catalog()
	modifier_catalog.erase("ok")
	ext.configure_modifiers(modifier_catalog, 1)
	for slot_name in [&"cell_temp", &"cell_temp_30d", &"cell_moisture",
			&"cell_plant_available_water", &"cell_weather_precip", &"cell_snow_cover",
			&"cell_weather_intensity", &"cell_elevation"]:
		var sid: int = ext.register_component(slot_name, 0, 1, false)
		ext.write_f32_range(sid, 0, PackedFloat32Array([0.5]))
	for slot_name in [&"cell_terrain", &"cell_landform", &"cell_vegetation",
			&"cell_is_water", &"cell_has_river"]:
		var sid: int = ext.register_component(slot_name, 2, 1, false)
		var value := landform if slot_name == &"cell_landform" else 0
		ext.write_u8_range(sid, 0, PackedByteArray([value]))
	for i in range((catalog.building_resource_ids as PackedStringArray).size()):
		var reserve_sid: int = ext.register_component(StringName(
			(catalog.building_resource_reserve_slots as PackedStringArray)[i]), 0, 1, false)
		var extra_sid: int = ext.register_component(StringName(
			(catalog.building_resource_extra_slots as PackedStringArray)[i]), 0, 1, false)
		ext.write_f32_range(reserve_sid, 0, PackedFloat32Array([1000000.0]))
		ext.write_f32_range(extra_sid, 0, PackedFloat32Array([0.0]))
	return ext


func _configure_country(ext: Object, catalog: Dictionary, seed: int) -> bool:
	var ids: PackedStringArray = catalog.technology_ids
	var technology_indices := PackedInt32Array()
	for id in ids:
		var dense := ids.find(String(id))
		if dense >= 0:
			technology_indices.append(dense)
	var configured: Dictionary = ext.configure_country(catalog, {
		"country_runtime_mode": "ACTIVE",
		"starting_technology_ids": ids,
	}, 1, seed)
	if not bool(configured.get("ok", false)):
		return false
	return bool(ext.bootstrap_country({
		"country_ids": PackedStringArray(["country.family_effect_restore_test"]),
		"country_names": PackedStringArray(["家族效果恢复测试国"]),
		"country_cash": PackedInt64Array([0]),
		"territory_offsets": PackedInt32Array([0, 1]),
		"territory_cells": PackedInt32Array([0]),
		"technology_offsets": PackedInt32Array([0, technology_indices.size()]),
		"technology_indices": technology_indices,
		"treasury_offsets": PackedInt32Array([0, 0]),
		"treasury_good_indices": PackedInt32Array(),
		"treasury_quantities": PackedInt64Array(),
	}, PackedByteArray([0])).get("ok", false))


func _run_day(ext: Object, day: int) -> Dictionary:
	var report := {}
	var simulation_day := day * 5
	for slice in 512:
		report = ext.run_economy_slice({
			"day_index": simulation_day,
			"tick_index": simulation_day * 1000 + slice,
		})
		if bool(report.get("done", false)):
			return report
	return report


func _expect(label: String, ok: bool) -> void:
	_checks += 1
	if not ok:
		_fail(label)


func _fail(label: String) -> void:
	_failures += 1
	push_error("[FAIL] %s" % label)
