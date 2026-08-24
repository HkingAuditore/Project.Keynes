extends SceneTree

const EconomyCatalogScript = preload("res://scripts/economy/economy_catalog.gd")
const ModifierCatalogScript = preload("res://scripts/modifier/modifier_catalog.gd")
const FamilyTraitCatalogScript = preload("res://scripts/family/family_trait_catalog.gd")
const FamilyTraitDefinitionScript = preload("res://scripts/family/family_trait_definition.gd")
const FamilyBehaviorPreferenceScript = preload("res://scripts/family/family_behavior_preference.gd")
const FamilyEffectCatalogScript = preload("res://scripts/family/family_effect_catalog.gd")
const FamilyEffectDefinitionScript = preload("res://scripts/family/family_effect_definition.gd")
const EffectDomainCatalogScript = preload("res://scripts/effect/effect_domain_catalog.gd")
const EffectCatalogScript = preload("res://scripts/effect/effect_catalog.gd")
const EffectDefinitionScript = preload("res://scripts/effect/effect_definition.gd")
const EffectInstructionScript = preload("res://scripts/effect/effect_instruction.gd")
const EffectConditionScript = preload("res://scripts/effect/effect_condition.gd")
const LandformTypeScript = preload("res://scripts/geography/landform_type.gd")

const Q16_ONE := 65536
const OPCODE_SET_SPLIT_POLICY := 23
const FLAG_RETAIN_ONLY := 1
const FLAG_BONUS_WEIGHT := 2

var failures := 0


func _init() -> void:
	_run()
	print("=== family buff runtime foundation %s ===" % [
		"PASS" if failures == 0 else "FAIL"])
	quit(0 if failures == 0 else 1)


func _expect(label: String, condition: bool) -> void:
	print("  [%s] %s" % ["PASS" if condition else "FAIL", label])
	if not condition:
		failures += 1


func _run() -> void:
	if not ClassDB.class_exists("DCWorldExt"):
		print("[SKIP] DCWorldExt unavailable")
		return
	_test_catalog_foundation()
	_test_remaining_days_compiles()
	_test_runtime_channels()


func _test_catalog_foundation() -> void:
	var official_traits: Resource = FamilyTraitCatalogScript.load_default()
	var official_effects: Resource = FamilyEffectCatalogScript.load_default()
	_expect("load_default hydrates 98 official family traits",
		official_traits != null and official_traits.traits.size() == 98)
	_expect("load_default hydrates 48 official family effects",
		official_effects != null and official_effects.effects.size() == 48)
	if official_effects != null:
		var copy_ok: bool = official_effects.effects.size() == 48
		for definition in official_effects.effects:
			var display_name := String(definition.display_name).strip_edges()
			var description := String(definition.description).strip_edges()
			copy_ok = copy_ok and not display_name.is_empty() \
				and display_name.find(".") < 0 \
				and not description.is_empty()
		_expect("official family effects have Chinese names and descriptions",
			copy_ok)
		var design_ok: bool = true
		for definition in official_effects.effects:
			var description := String(definition.description)
			var statements: Variant = definition.prestige_descriptions
			design_ok = design_ok and description.find("威望Ⅰ") >= 0 \
				and description.find("威望Ⅴ") >= 0 \
				and statements.size() == 5 \
				and String(statements[0]).begins_with("威望Ⅰ") \
				and String(statements[4]).begins_with("威望Ⅴ")
		_expect("official family effects keep five prestige statements", design_ok)
		var placeholder_ok: bool = true
		for definition in official_traits.traits:
			placeholder_ok = placeholder_ok \
				and String(definition.description_template).find("X") >= 0 \
				and String(definition.range_text).find("X∈") >= 0 \
				and String(definition.description).find("X") >= 0
		_expect("official family traits keep placeholder ranges from the design table",
			placeholder_ok)
		var wheat_keys := PackedStringArray()
		var rice_keys := PackedStringArray()
		var corn_keys := PackedStringArray()
		var fishing_keys := PackedStringArray()
		var extractive_keys := PackedStringArray()
		var mining_keys := PackedStringArray()
		var fishing_any := false
		var extractive_any := false
		var mining_any := false
		var j003_has_oil := false
		var corn_effect_keys := PackedStringArray()
		var effect_gates := {}
		for definition in official_traits.traits:
			var key := String(definition.key)
			if key == "c023_wheat":
				wheat_keys = definition.prerequisite_technology_keys
			elif key == "c022_rice":
				rice_keys = definition.prerequisite_technology_keys
			elif key == "c024_corn":
				corn_keys = definition.prerequisite_technology_keys
			elif key == "i008_fishing":
				fishing_keys = definition.prerequisite_technology_keys
				fishing_any = bool(definition.prerequisite_technology_any)
			elif key == "i002_extractive":
				extractive_keys = definition.prerequisite_technology_keys
				extractive_any = bool(definition.prerequisite_technology_any)
			elif key == "i012_mining":
				mining_keys = definition.prerequisite_technology_keys
				mining_any = bool(definition.prerequisite_technology_any)
			elif key == "j003_forest_mine":
				for behavior in definition.behaviors:
					if String(behavior.selector_id) == "petroleum_worker":
						j003_has_oil = true
		for definition in official_effects.effects:
			var effect_key := String(definition.key)
			if effect_key == "corn_expert":
				corn_effect_keys = definition.prerequisite_technology_keys
			effect_gates[effect_key] = [
				bool(definition.prerequisite_technology_any),
				definition.prerequisite_technology_keys]
		_expect("麦食 cannot roll before wild wheat collection is unlocked",
			wheat_keys.has("tech.wild_wheat_collection"))
		_expect("米食 cannot roll before paddy rice cultivation is unlocked",
			rice_keys.has("tech.rice_paddy_cultivation"))
		_expect("玉米嗜好 cannot roll before wild maize collection is unlocked",
			corn_keys.has("tech.wild_maize_collection"))
		_expect("玉米专家 cannot enter the random pool before wild maize collection",
			corn_effect_keys.has("tech.wild_maize_collection"))
		_expect("渔户水脉 uses ANY freshwater or coastal fishing",
			fishing_any
			and fishing_keys.has("tech.freshwater_fishing")
			and fishing_keys.has("tech.coastal_fishing"))
		_expect("重矿 requires identified mineral technologies",
			extractive_any
			and extractive_keys.has("tech.iron_ore_identification")
			and extractive_keys.has("tech.natural_copper_identification")
			and extractive_keys.has("tech.tin_identification")
			and extractive_keys.has("tech.gold_placer_identification")
			and extractive_keys.has("tech.silver_vein_identification")
			and extractive_keys.has("tech.coal_outcrop_identification"))
		_expect("矿业经营 identification ANY includes petroleum extraction",
			mining_any
			and mining_keys.has("tech.iron_ore_identification")
			and mining_keys.has("tech.petroleum_extraction"))
		_expect("林矿世业 does not employ petroleum workers", not j003_has_oil)
		_expect("植树造林 cannot enter the pool before deadwood collection",
			not bool(effect_gates["afforestation"][0])
			and (effect_gates["afforestation"][1] as PackedStringArray).has(
				"tech.deadwood_collection"))
		_expect("观潮生计 uses ANY freshwater or coastal fishing",
			bool(effect_gates["tide_living"][0])
			and (effect_gates["tide_living"][1] as PackedStringArray).has(
				"tech.freshwater_fishing")
			and (effect_gates["tide_living"][1] as PackedStringArray).has(
				"tech.coastal_fishing"))
		_expect("山地矿脉 uses ANY mineral identification",
			bool(effect_gates["mountain_vein"][0])
			and (effect_gates["mountain_vein"][1] as PackedStringArray).has(
				"tech.iron_ore_identification"))
		_expect("trade pool effects require early trade",
			(effect_gates["trade_zealot"][1] as PackedStringArray).has("tech.early_trade")
			and (effect_gates["market_boom"][1] as PackedStringArray).has("tech.early_trade")
			and (effect_gates["branch_network"][1] as PackedStringArray).has("tech.early_trade")
			and (effect_gates["trade_nation"][1] as PackedStringArray).has("tech.early_trade"))
		_expect("industry pool effects require the agrarian milestone",
			(effect_gates["industry_cluster"][1] as PackedStringArray).has(
				"tech.agrarian_society")
			and (effect_gates["many_trades"][1] as PackedStringArray).has(
				"tech.agrarian_society")
			and (effect_gates["one_industry_city"][1] as PackedStringArray).has(
				"tech.agrarian_society")
			and (effect_gates["city_chain"][1] as PackedStringArray).has(
				"tech.agrarian_society")
			and (effect_gates["specialized_industry"][1] as PackedStringArray).has(
				"tech.agrarian_society")
			and (effect_gates["versatile_crafts"][1] as PackedStringArray).has(
				"tech.agrarian_society")
			and (effect_gates["complete_chain"][1] as PackedStringArray).has(
				"tech.agrarian_society")
			and (effect_gates["local_monopoly"][1] as PackedStringArray).has(
				"tech.agrarian_society"))
		_expect("knowledge pool effects require writing",
			(effect_gates["knowledge_spread"][1] as PackedStringArray).has("tech.writing")
			and (effect_gates["family_learning"][1] as PackedStringArray).has("tech.writing"))
	var compiled: Dictionary = EconomyCatalogScript.compile_native_catalog()
	var effect_keys: PackedStringArray = compiled.get(
		"family_effect_keys", PackedStringArray())
	var trait_ids: PackedStringArray = compiled.get(
		"family_trait_ids", PackedStringArray())
	var exclusions: PackedInt32Array = compiled.get(
		"family_effect_exclusions", PackedInt32Array())
	_expect("official family catalogs compile into economy IR",
		bool(compiled.get("ok", false))
		and int(compiled.get("family_effect_catalog_version", 0)) >= 1
		and trait_ids.size() == 98
		and effect_keys.size() == 48
		and effect_keys.has("family.effect.rain_prayer")
		and effect_keys.has("family.effect.branching_households")
		and effect_keys.has("family.effect.century_shop")
		and (compiled.get("family_effect_exclusion_offsets", PackedInt32Array()) as PackedInt32Array).size() == 49
		and exclusions.size() > 0
		and (compiled.get("family_effect_magnitude_by_prestige_q16", PackedInt32Array()) as PackedInt32Array).size() == 48 * 6)
	var trait_match: PackedByteArray = compiled.get(
		"family_trait_technology_match_any", PackedByteArray())
	var effect_match: PackedByteArray = compiled.get(
		"family_effect_technology_match_any", PackedByteArray())
	var fishing_id := trait_ids.find("i008_fishing")
	var extractive_id := trait_ids.find("i002_extractive")
	var tide_id := effect_keys.find("family.effect.tide_living")
	_expect("compiled catalogs pack ANY flags for fishing and mineral gates",
		trait_match.size() == 98
		and effect_match.size() == 48
		and fishing_id >= 0 and int(trait_match[fishing_id]) != 0
		and extractive_id >= 0 and int(trait_match[extractive_id]) != 0
		and tide_id >= 0 and int(effect_match[tide_id]) != 0)
	if not bool(compiled.get("ok", false)):
		print("official catalog=", compiled)
	var baseline_hash := int(compiled.get("family_effect_catalog_hash", 0))
	var mutated: Resource = official_effects.duplicate(false)
	var mutated_rows: Array[Resource] = []
	for definition in official_effects.effects:
		var copy: Resource = definition.duplicate(false)
		copy.display_name = "%sx" % String(copy.display_name)
		copy.description = "%s extra" % String(copy.description)
		mutated_rows.append(copy)
	mutated.effects = mutated_rows
	var mutated_result: Dictionary = EconomyCatalogScript.compile_native_catalog(mutated)
	_expect("family effect display copy does not change family_effect_catalog_hash",
		baseline_hash != 0
		and bool(mutated_result.get("ok", false))
		and int(mutated_result.get("family_effect_catalog_hash", 0)) == baseline_hash)
	var domain: Resource = EffectDomainCatalogScript.build()
	_expect("effect domain catalog builds with official family effects", domain != null)
	if domain == null:
		return
	var domain_ir: Dictionary = domain.compile_native_catalog()
	var metric_keys: PackedStringArray = domain_ir.get(
		"metric_keys", PackedStringArray())
	_expect("effect domain catalog compiles opcode 23 and metrics 22-36",
		bool(domain_ir.get("ok", false))
		and metric_keys.size() >= 37
		and String(metric_keys[15]) == "family.has_owned_manufacturing"
		and String(metric_keys[22]) == "cell.unemployment_q16"
		and String(metric_keys[36]) == "cell.can_produce_corn"
		and (domain_ir.get("effect_keys", PackedStringArray()) as PackedStringArray).has(
			"trigger.economy.family.set_split_policy"))
	var all_professions := FamilyTraitCatalogScript.new()
	all_professions.version = 1
	all_professions.core_trait_min = 1
	all_professions.core_trait_max = 1
	var core := FamilyTraitDefinitionScript.new()
	core.key = &"core_all_professions"
	core.weight = 1
	core.core_eligible = true
	var preference := FamilyBehaviorPreferenceScript.new()
	preference.axis = FamilyBehaviorPreferenceScript.Axis.CAREER_PROFESSION
	preference.score_term = FamilyBehaviorPreferenceScript.ScoreTerm.CANDIDATE_WEIGHT
	preference.selector_id = &"*"
	preference.factor_q16 = Q16_ONE * 2
	var behaviors: Array[Resource] = []
	behaviors.append(preference)
	core.behaviors = behaviors
	var traits: Array[Resource] = []
	traits.append(core)
	all_professions.traits = traits
	var expanded: Dictionary = EconomyCatalogScript.compile_native_catalog(null, all_professions)
	if not bool(expanded.get("ok", false)):
		print("selector * catalog=", expanded)
	var profession_count := (expanded.get("profession_ids", PackedStringArray()) as PackedStringArray).size()
	var selector_ids: PackedInt32Array = expanded.get(
		"family_trait_behavior_selector_ids", PackedInt32Array())
	_expect("behavior selector * expands every profession dense id",
		bool(expanded.get("ok", false)) and selector_ids.size() == profession_count)


func _test_remaining_days_compiles() -> void:
	var catalog := EffectCatalogScript.new()
	catalog.metric_keys = PackedStringArray(["family.magnitude_q16"])
	var definition := EffectDefinitionScript.new()
	definition.key = &"family.effect.remaining_probe"
	definition.source_kind = 5
	definition.lifecycle = 0
	definition.duration_days = -1
	var read_state := EffectInstructionScript.new()
	read_state.op = 3
	read_state.arg0 = 3
	var end := EffectInstructionScript.new()
	end.op = 12
	var instructions: Array[Resource] = []
	instructions.append(read_state)
	instructions.append(end)
	definition.instructions = instructions
	var condition := EffectConditionScript.new()
	condition.op = 2
	condition.arg0 = 0
	condition.value_q16 = 1
	var conditions: Array[Resource] = []
	conditions.append(condition)
	definition.conditions = conditions
	var definitions: Array[Resource] = []
	definitions.append(definition)
	catalog.definitions = definitions
	var compiled: Dictionary = catalog.compile_native_catalog()
	_expect("READ_STATE 3 remaining-days program compiles",
		bool(compiled.get("ok", false)))
	if not bool(compiled.get("ok", false)):
		print("remaining-days compile=", compiled)
		return
	var ext: Object = ClassDB.instantiate("DCWorldExt")
	var remaining_configured: Dictionary = ext.configure_effects(compiled)
	_expect("READ_STATE 3 remaining-days program configures",
		bool(remaining_configured.get("ok", false)))
	if not bool(remaining_configured.get("ok", false)):
		print("remaining-days configure=", remaining_configured)


func _pool_effect() -> Resource:
	var command := EffectCommand.new()
	command.action = 1
	command.domain = 2
	command.opcode = 1
	command.target_resolver = 1
	command.command_key = &"family.effect.pool.probe"
	command.definition_key = &"family.city.food_consumption_boost"
	var constant := EffectInstructionScript.new()
	constant.op = 1
	constant.value_q16 = Q16_ONE
	var emit := EffectInstructionScript.new()
	emit.op = 11
	var end := EffectInstructionScript.new()
	end.op = 12
	var instructions: Array[Resource] = []
	instructions.append(constant)
	instructions.append(emit)
	instructions.append(end)
	var commands: Array[Resource] = []
	commands.append(command)
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


func _test_runtime_channels() -> void:
	var family_effects := FamilyEffectCatalogScript.new()
	family_effects.version = 1
	var authored: Array[Resource] = []
	authored.append(_pool_effect())
	family_effects.effects = authored
	var catalog: Dictionary = EconomyCatalogScript.compile_native_catalog(family_effects)
	_expect("fixture family-effect catalog compiles", bool(catalog.get("ok", false)))
	if not bool(catalog.get("ok", false)):
		print("fixture catalog=", catalog)
		return
	_expect("fixture packs one random-pool family effect",
		(catalog.get("family_effect_keys", PackedStringArray()) as PackedStringArray).size() == 1
		and String((catalog.get("family_effect_keys", PackedStringArray()) as PackedStringArray)[0])
			== "family.effect.pool_probe")
	var domain: Resource = EffectDomainCatalogScript.build(family_effects)
	_expect("effect domain catalog accepts the fixture family effect", domain != null)
	if domain == null:
		return
	var ext := _new_ext(catalog, LandformTypeScript.LF.PLAIN)
	var native_economy := catalog.duplicate(true)
	native_economy.erase("ok")
	if not _configure_country(ext, catalog, 210821):
		_expect("buff fixture country bootstraps", false)
		return
	var effect_ir: Dictionary = domain.compile_native_catalog()
	_expect("fixture effect IR compiles", bool(effect_ir.get("ok", false)))
	if not bool(effect_ir.get("ok", false)):
		print("effect ir=", effect_ir)
		return
	effect_ir.erase("ok")
	var effects_configured: Dictionary = ext.configure_effects(effect_ir)
	_expect("effect runtime configures with fixture programs",
		bool(effects_configured.get("ok", false)))
	if not bool(effects_configured.get("ok", false)):
		print("fixture effect configure=", effects_configured)
	_expect("economy configures with fixture family effects",
		bool(ext.configure_economy(native_economy, _active_profile(), 1, 210821).get("ok", false)))
	if not _bootstrap_opening(ext, catalog):
		return
	var day0 := _run_day(ext, 0)
	_expect("opening day conserves ledgers",
		bool(day0.get("done", false)) and int(day0.get("population_error", 1)) == 0
		and int(day0.get("money_error", 1)) == 0 and int(day0.get("goods_error", 1)) == 0)
	var page: Dictionary = ext.get_family_cell_snapshot(0, 0, 64)
	if int(page.get("total", 0)) != 1:
		_expect("buff fixture forms one founder family", false)
		return
	var family_handle := int((page.family_handles as PackedInt64Array)[0])
	var effects0: Dictionary = ext.get_family_branch_effects(family_handle, 0)
	var keys0: PackedStringArray = effects0.get("effect_definition_keys", PackedStringArray())
	_expect("random-pool grant is exactly one independent effect",
		bool(effects0.get("ok", false)) and keys0.size() == 1)
	var day1 := _run_day(ext, 1)
	var effects1: Dictionary = ext.get_family_branch_effects(family_handle, 0)
	var keys1: PackedStringArray = effects1.get("effect_definition_keys", PackedStringArray())
	_expect("independent family effects survive a later reconcile",
		bool(day1.get("done", false)) and int(day1.get("population_error", 1)) == 0
		and keys1.size() == keys0.size())
	_expect("owned-output CSR stays empty without authored structure effects",
		int(day1.get("family_owned_output_row_count", -1)) == 0)
	var branch_handle := int(effects1.get("branch_handle", 0))
	var retain: Dictionary = ext.submit_economy_commands({
		"opcodes": PackedInt32Array([OPCODE_SET_SPLIT_POLICY]),
		"effective_days": PackedInt64Array([10]),
		"sequences": PackedInt64Array([1]),
		"target_handles": PackedInt64Array([branch_handle]),
		"i32_0": PackedInt32Array([FLAG_RETAIN_ONLY]),
		"i32_1": PackedInt32Array([0]),
		"i64_0": PackedInt64Array([0]),
		"i64_1": PackedInt64Array([0]),
	})
	_expect("family.set_split_policy retain-only is accepted", bool(retain.get("ok", false)))
	if not bool(retain.get("ok", false)):
		print("retain submit=", retain)
	var retain_day := _run_day(ext, 2)
	var snap: Dictionary = ext.get_family_snapshot(family_handle)
	_expect("retain-only split flags are written onto the family",
		bool(retain_day.get("done", false))
		and (int(snap.get("flags", 0)) & FLAG_RETAIN_ONLY) == FLAG_RETAIN_ONLY)
	var bonus: Dictionary = ext.submit_economy_commands({
		"opcodes": PackedInt32Array([OPCODE_SET_SPLIT_POLICY]),
		"effective_days": PackedInt64Array([15]),
		"sequences": PackedInt64Array([2]),
		"target_handles": PackedInt64Array([family_handle]),
		"i32_0": PackedInt32Array([FLAG_BONUS_WEIGHT]),
		"i32_1": PackedInt32Array([0]),
		"i64_0": PackedInt64Array([192]),
		"i64_1": PackedInt64Array([0]),
	})
	_expect("family.set_split_policy bonus-weight is accepted", bool(bonus.get("ok", false)))
	var bonus_day := _run_day(ext, 3)
	snap = ext.get_family_snapshot(family_handle)
	_expect("bonus-weight split flags replace retain-only and keep Q8 weight",
		bool(bonus_day.get("done", false))
		and (int(snap.get("flags", 0)) & FLAG_RETAIN_ONLY) == 0
		and (int(snap.get("flags", 0)) & FLAG_BONUS_WEIGHT) == FLAG_BONUS_WEIGHT
		and (int(snap.get("flags", 0)) >> 8) == 192)
	var rejected: Dictionary = ext.submit_economy_commands({
		"opcodes": PackedInt32Array([OPCODE_SET_SPLIT_POLICY]),
		"effective_days": PackedInt64Array([20]),
		"sequences": PackedInt64Array([3]),
		"target_handles": PackedInt64Array([family_handle]),
		"i32_0": PackedInt32Array([3]),
		"i32_1": PackedInt32Array([0]),
		"i64_0": PackedInt64Array([0]),
		"i64_1": PackedInt64Array([0]),
	})
	_expect("invalid split policy is rejected at submit",
		not bool(rejected.get("ok", true)))


func _active_profile() -> Dictionary:
	var profile: Dictionary = load(
		"res://data/economy/default_economy.tres").to_native_profile()
	profile.family_runtime_mode = "ACTIVE"
	profile.family_min_settlement_tier = 0
	profile.family_review_days = 1
	profile.family_min_population_per_active = 1
	profile.notable_person_runtime_mode = "ACTIVE"
	profile.starvation_death_rate_q32 = 0
	return profile


func _bootstrap_opening(ext: Object, catalog: Dictionary) -> bool:
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
	_expect("opening family bootstraps", bool(boot.get("ok", false)))
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
		"country_ids": PackedStringArray(["country.family_buff_test"]),
		"country_names": PackedStringArray(["家族基座测试国"]),
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
