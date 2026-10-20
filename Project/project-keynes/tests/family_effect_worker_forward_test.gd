extends SceneTree

# M2b-2 gate: the Economy family path must write Effect instances through
# EffectInstanceForwarder, not straight into EffectRuntime, once EFFECT belongs
# to the worker.
#
# The family path creates instances from five different places (reconcile, the
# founding random-pool grant, the ancestral precept, the event-once fire, and
# person registration) and retires them from branch clear. All of them now share
# effect_pod_upsert / effect_pod_metric / effect_pod_retire, and this test pins
# the branch that actually reaches a fresh headless fixture: the founding
# random-pool grant (grant_family_effect_to_branches).
#
# Why the seam instead of real ACTIVE authority: a fresh ACTIVE start only earns
# its EFFECT grant after the worker commits one fully committed day, and a
# headless catalog fixture has no Climate trace, so that day never completes.
# set_effect_forwarder_authority_for_test() changes only what the forwarder
# believes; the family path keeps reconciling on the main thread either way,
# which is the production situation this step was written for.
#
# The observable is get_family_branch_effects().effect_present, which reports
# EffectRuntime::has_instance_pod for each held ref:
#
#   legacy override -> the ref points at an instance EffectRuntime owns   (1)
#   worker override -> the ref was queued to the worker transport and
#                      EffectRuntime never saw it                         (0)
#
# Same fixture, same founding roll, same instance identity. Only the writer
# differs, which is exactly the claim M2b-2 makes.

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
	print("=== family effect worker forward: %d checks, %d failures ===" % [
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
	var keys: PackedStringArray = catalog.get("family_effect_keys",
		PackedStringArray())
	_expect("fixture packs one random-pool family effect",
		keys.size() == 1 and String(keys[0]) == FAMILY_EFFECT_KEY)
	var domain: Resource = EffectDomainCatalogScript.build(family_effects)
	_expect("effect domain catalog accepts the fixture family effect", domain != null)
	if domain == null:
		return
	var effect_ir: Dictionary = domain.compile_native_catalog()
	_expect("fixture effect IR compiles", bool(effect_ir.get("ok", false)))
	if not bool(effect_ir.get("ok", false)):
		return
	effect_ir.erase("ok")

	var legacy: Dictionary = _founding_effect(catalog, effect_ir, 0, 1, "legacy")
	var worker: Dictionary = _founding_effect(catalog, effect_ir, 1, 0, "worker")
	if legacy.is_empty() or worker.is_empty():
		return
	# Same founding roll, same identity: the only difference is who received it.
	_expect("both authorities hold the same instance identity",
		worker.get("effect_instance_ids", PackedInt64Array()) ==
		legacy.get("effect_instance_ids", PackedInt64Array()))
	_expect("both authorities record the same target",
		worker.get("effect_target_handles", PackedInt64Array()) ==
		legacy.get("effect_target_handles", PackedInt64Array()))
	_expect("both authorities record the same target generation",
		worker.get("effect_target_generations", PackedInt32Array()) ==
		legacy.get("effect_target_generations", PackedInt32Array()))


## Runs one opening day and returns the branch effect report after the founding
## random-pool grant. `expected_present` is the EffectRuntime ownership bit the
## chosen authority must produce.
func _founding_effect(catalog: Dictionary, effect_ir: Dictionary,
		override_mode: int, expected_present: int, label: String) -> Dictionary:
	var ext: Object = _new_ext(catalog, LandformTypeScript.LF.PLAIN)
	var native_economy := catalog.duplicate(true)
	native_economy.erase("ok")
	_expect("%s: buff fixture country bootstraps" % label,
		_configure_country(ext, catalog, 210821))
	var effects_configured: Dictionary = ext.configure_effects(effect_ir)
	_expect("%s: effect runtime configures" % label,
		bool(effects_configured.get("ok", false)))
	# Without a compiled pod catalog the worker branch cannot even be selected:
	# queue_effect_pod_instance would reject every row and the reroute evidence
	# below would read as a drop instead of a handoff.
	_expect("%s: effect pod catalog compiles" % label,
		bool(effects_configured.get("effect_pod_ready", false)))
	var seam: Dictionary = ext.set_effect_forwarder_authority_for_test(override_mode)
	_expect("%s: seam reports the requested authority" % label,
		bool(seam.get("worker_authoritative", false)) == (override_mode != 0))
	_expect("%s: economy configures" % label,
		bool(ext.configure_economy(native_economy, _active_profile(), 1,
			210821).get("ok", false)))
	if not _bootstrap_opening(ext, catalog, label):
		return {}
	var day0: Dictionary = _run_day(ext, 0)
	_expect("%s: opening day completes" % label,
		bool(day0.get("done", false)))
	var page: Dictionary = ext.get_family_cell_snapshot(0, 0, 64)
	if int(page.get("total", 0)) != 1:
		_fail("%s: fixture forms one founder family" % label)
		return {}
	var family_handle := int((page.family_handles as PackedInt64Array)[0])
	var report: Dictionary = ext.get_family_branch_effects(family_handle, 0)
	var effect_keys: PackedStringArray = report.get("effect_definition_keys",
		PackedStringArray())
	# A silently dropped write would leave zero bindings, so this is the guard
	# that separates "handed to the worker" from "never created".
	_expect("%s: founding grant holds exactly one family effect" % label,
		bool(report.get("ok", false)) and effect_keys.size() == 1 and
		String(effect_keys[0]) == FAMILY_EFFECT_KEY)
	if effect_keys.size() != 1:
		return {}
	var present: PackedByteArray = report.get("effect_present", PackedByteArray())
	_expect("%s: ownership bit is %d" % [label, expected_present],
		present.size() == 1 and int(present[0]) == expected_present)
	return report


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
		"country_ids": PackedStringArray(["country.family_effect_forward_test"]),
		"country_names": PackedStringArray(["家族效果转测试国"]),
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
