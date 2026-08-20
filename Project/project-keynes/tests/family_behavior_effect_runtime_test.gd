extends SceneTree

const EconomyCatalogScript = preload("res://scripts/economy/economy_catalog.gd")
const ModifierCatalogScript = preload("res://scripts/modifier/modifier_catalog.gd")
const FamilyTraitCatalogScript = preload("res://scripts/family/family_trait_catalog.gd")
const FamilyTraitDefinitionScript = preload("res://scripts/family/family_trait_definition.gd")
const FamilyBehaviorPreferenceScript = preload("res://scripts/family/family_behavior_preference.gd")
const EffectDomainCatalogScript = preload("res://scripts/effect/effect_domain_catalog.gd")
const EffectConditionScript = preload("res://scripts/effect/effect_condition.gd")
const TechnologyCatalogScript = preload("res://scripts/economy/technology_catalog.gd")
const LandformTypeScript = preload("res://scripts/geography/landform_type.gd")

const Q16_ONE := 65536
const METRIC_LANDFORM := 10
const OP_EQ := 4
const FLAG_STARTING := 4

var failures := 0


func _init() -> void:
	_run()
	print("=== family behavior/effect runtime %s ===" % [
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
	_test_catalog_compile()
	_test_behavior_conditions_and_score_terms()
	_test_trait_technology_gate()
	_test_conserved_family_commands()


func _test_catalog_compile() -> void:
	var compiled: Dictionary = EconomyCatalogScript.compile_native_catalog()
	_expect("economy catalog compiles with family behavior extensions",
		bool(compiled.get("ok", false)))
	if not bool(compiled.get("ok", false)):
		print("catalog failure=", compiled)
		return
	var axes: PackedInt32Array = compiled.get(
		"family_trait_behavior_axes", PackedInt32Array())
	var score_terms: PackedInt32Array = compiled.get(
		"family_trait_behavior_score_terms", PackedInt32Array())
	var condition_offsets: PackedInt32Array = compiled.get(
		"family_trait_behavior_condition_offsets", PackedInt32Array())
	var tech_offsets: PackedInt32Array = compiled.get(
		"family_trait_technology_prerequisite_offsets", PackedInt32Array())
	_expect("default trait catalog packs score_term and condition CSR columns",
		score_terms.size() == axes.size()
		and condition_offsets.size() == axes.size() + 1
		and tech_offsets.size() == (compiled.family_trait_ids as PackedStringArray).size() + 1)
	var domain: Resource = EffectDomainCatalogScript.build()
	_expect("effect domain catalog builds with appended family metrics", domain != null)
	if domain == null:
		return
	var domain_ir: Dictionary = domain.compile_native_catalog()
	_expect("effect domain catalog compiles trigger.economy family commands",
		bool(domain_ir.get("ok", false)))
	var metric_keys: PackedStringArray = domain_ir.get("metric_keys", PackedStringArray())
	_expect("family effect metrics 0-9 stay stable and 10-14 append at the end",
		metric_keys.size() >= 15
		and String(metric_keys[0]) == "family.magnitude_q16"
		and String(metric_keys[9]) == "cell.population"
		and String(metric_keys[10]) == "cell.landform"
		and String(metric_keys[11]) == "cell.essentials_shortage_q16"
		and String(metric_keys[12]) == "branch.is_local_prestige_max"
		and String(metric_keys[13]) == "cell.rain_event"
		and String(metric_keys[14]) == "cell.resource_abundance_q16")
	var effect_keys: PackedStringArray = domain_ir.get("effect_keys", PackedStringArray())
	_expect("trigger.economy family ledger programs are compiled",
		effect_keys.has("trigger.economy.family.free_building")
		and effect_keys.has("trigger.economy.family.population_reward")
		and effect_keys.has("trigger.economy.family.absorb_anonymous")
		and effect_keys.has("trigger.economy.family.purchase_discount"))
	var unknown_tech: Resource = _behavior_catalog(
		"stone_age_hunting_camp", [], PackedStringArray(["tech.does_not_exist"]))
	var unknown: Dictionary = EconomyCatalogScript.compile_native_catalog(null, unknown_tech)
	_expect("unknown trait technology prerequisite is rejected at the cold boundary",
		not bool(unknown.get("ok", true))
		and String(unknown.get("reason", "")) == "family_trait_technology_prerequisite_unknown")
	var missing_selector: Resource = FamilyTraitCatalogScript.new()
	missing_selector.version = 1
	missing_selector.core_trait_min = 1
	missing_selector.core_trait_max = 1
	var core := FamilyTraitDefinitionScript.new()
	core.key = &"core_plain"
	core.weight = 1
	core.core_eligible = true
	var weight := FamilyBehaviorPreferenceScript.new()
	weight.axis = FamilyBehaviorPreferenceScript.Axis.INVESTMENT_BUILDING
	weight.score_term = FamilyBehaviorPreferenceScript.ScoreTerm.CANDIDATE_WEIGHT
	weight.factor_q16 = Q16_ONE * 2
	core.behaviors = _resource_array([weight])
	missing_selector.traits = _resource_array([core])
	var missing: Dictionary = EconomyCatalogScript.compile_native_catalog(null, missing_selector)
	_expect("candidate-weight behavior still requires a selector",
		not bool(missing.get("ok", true))
		and String(missing.get("reason", "")) == "family_trait_behavior_selector_unknown")


func _test_behavior_conditions_and_score_terms() -> void:
	var trait_catalog: Resource = _behavior_catalog("stone_age_hunting_camp", [
		_landform_eq(LandformTypeScript.LF.MOUNTAIN)
	], PackedStringArray())
	var compiled: Dictionary = EconomyCatalogScript.compile_native_catalog(null, trait_catalog)
	_expect("conditional behavior catalog compiles", bool(compiled.get("ok", false)))
	if not bool(compiled.get("ok", false)):
		print("conditional catalog failure=", compiled)
		return
	var score_terms: PackedInt32Array = compiled.get(
		"family_trait_behavior_score_terms", PackedInt32Array())
	_expect("score_term packed column includes tax sensitivity and candidate weight",
		score_terms.has(FamilyBehaviorPreferenceScript.ScoreTerm.TAX_SENSITIVITY)
		and score_terms.has(FamilyBehaviorPreferenceScript.ScoreTerm.CANDIDATE_WEIGHT))
	var mountain := _boot_family(compiled, LandformTypeScript.LF.MOUNTAIN, 260821)
	var plain := _boot_family(compiled, LandformTypeScript.LF.PLAIN, 260822)
	if mountain.ext == null or plain.ext == null:
		return
	_grant_additional(mountain.ext, mountain.family_handle, compiled, [
		"mountain_folk", "tax_listener"])
	_grant_additional(plain.ext, plain.family_handle, compiled, [
		"mountain_folk", "tax_listener"])
	var mountain_day := _run_day(mountain.ext, 1)
	var plain_day := _run_day(plain.ext, 1)
	_expect("conditional behavior freeze conserves ledgers",
		bool(mountain_day.get("done", false)) and int(mountain_day.get("population_error", 1)) == 0
		and int(mountain_day.get("money_error", 1)) == 0
		and int(mountain_day.get("goods_error", 1)) == 0
		and bool(plain_day.get("done", false)) and int(plain_day.get("population_error", 1)) == 0)
	var mountain_rows := int(mountain_day.get("family_behavior_factor_row_count", 0))
	var plain_rows := int(plain_day.get("family_behavior_factor_row_count", 0))
	_expect("landform condition freezes the hunting edge only on mountain cells",
		mountain_rows == plain_rows + 1 and plain_rows >= 1)
	_expect("behavior CSR stays sparse and is visible in the economy report",
		mountain.ext.get_economy_report().has("family_behavior_factor_row_count")
		and int(mountain.ext.get_economy_report().get("family_behavior_factor_row_count", 0))
			== mountain_rows)


func _test_trait_technology_gate() -> void:
	var baseline: Dictionary = EconomyCatalogScript.compile_native_catalog()
	_expect("baseline catalog compiles for technology-gate fixture",
		bool(baseline.get("ok", false)))
	if not bool(baseline.get("ok", false)):
		return
	var locked := _locked_technology(baseline)
	_expect("catalog exposes a non-starting technology for the trait gate",
		not locked.is_empty())
	if locked.is_empty():
		return
	var gated: Resource = load("res://data/economy/default_family_traits.tres").duplicate(true)
	var traits: Array = gated.get("traits")
	for index in range(traits.size()):
		var trait_def: Resource = traits[index].duplicate(true)
		trait_def.prerequisite_technology_keys = PackedStringArray([locked])
		traits[index] = trait_def
	gated.set("traits", traits)
	var compiled: Dictionary = EconomyCatalogScript.compile_native_catalog(null, gated)
	_expect("gated trait catalog compiles", bool(compiled.get("ok", false)))
	if not bool(compiled.get("ok", false)):
		print("gated catalog failure=", compiled)
		return
	var starting := PackedStringArray()
	var flags: PackedInt32Array = compiled.get("technology_flags", PackedInt32Array())
	var ids: PackedStringArray = compiled.get("technology_ids", PackedStringArray())
	for index in range(mini(flags.size(), ids.size())):
		if (int(flags[index]) & FLAG_STARTING) != 0:
			starting.append(String(ids[index]))
	var ext := _new_ext(compiled, 0)
	_expect("technology-gate country bootstraps without the locked technology",
		_configure_country(ext, compiled, 260823, starting))
	var profile: Dictionary = _active_profile()
	_expect("technology-gate economy configures", bool(ext.configure_economy(
		compiled, profile, 1, 260823).get("ok", false)))
	if not _bootstrap_opening(ext, compiled):
		return
	var day0 := _run_day(ext, 0)
	_expect("gated core roll conserves population",
		bool(day0.get("done", false)) and int(day0.get("population_error", 1)) == 0)
	var page: Dictionary = ext.get_family_cell_snapshot(0, 0, 64)
	_expect("founder family still forms when core traits are technology-gated",
		bool(page.get("ok", false)) and int(page.get("total", 0)) == 1)
	if int(page.get("total", 0)) != 1:
		return
	var family_handle := int((page.family_handles as PackedInt64Array)[0])
	var initial: Dictionary = ext.get_family_traits(family_handle)
	var initial_keys: PackedStringArray = initial.get("trait_keys", PackedStringArray())
	_expect("core extraction skips traits whose technology is locked",
		initial_keys.is_empty())
	var grant_key := String((compiled.family_trait_ids as PackedStringArray)[0])
	var strengths: PackedInt32Array = compiled.family_trait_strength_min_q16
	var granted: Dictionary = ext.submit_family_trait_commands({
		"protocol_version": 1,
		"operations": PackedInt32Array([1]),
		"family_handles": PackedInt64Array([family_handle]),
		"trait_keys": PackedStringArray([grant_key]),
		"strength_q16": PackedInt32Array([int(strengths[0])]),
		"effective_days": PackedInt64Array([5]),
		"priorities": PackedInt32Array([100]),
		"sequences": PackedInt64Array([1]),
	})
	_expect("additional-trait command can still grant a technology-gated trait",
		bool(granted.get("ok", false)))
	var day1 := _run_day(ext, 1)
	var after: PackedStringArray = ext.get_family_traits(family_handle).get(
		"trait_keys", PackedStringArray())
	_expect("granted gated trait lands without breaking conservation",
		bool(day1.get("done", false)) and int(day1.get("population_error", 1)) == 0
		and after.has(grant_key))


func _test_conserved_family_commands() -> void:
	var compiled: Dictionary = EconomyCatalogScript.compile_native_catalog()
	_expect("conserved-command catalog compiles", bool(compiled.get("ok", false)))
	if not bool(compiled.get("ok", false)):
		return
	var catalog := compiled.duplicate(true)
	catalog.erase("ok")
	var building_ids: PackedStringArray = catalog.building_type_ids
	var reward_building_id := building_ids.find("method_gathering_ground_r1")
	var construction_days: PackedInt32Array = catalog.building_construction_days
	construction_days.fill(30)
	construction_days[reward_building_id] = 5
	catalog.building_construction_days = construction_days
	var construction_quantities: PackedInt64Array = catalog.building_construction_quantities
	var construction_offsets: PackedInt32Array = catalog.building_construction_offsets
	for type_id in range(building_ids.size()):
		if type_id == reward_building_id:
			continue
		for item in range(int(construction_offsets[type_id]), int(construction_offsets[type_id + 1])):
			construction_quantities[item] = 1000000000000
	catalog.building_construction_quantities = construction_quantities
	var ext := _new_ext(catalog, 0)
	_expect("conserved-command country bootstraps",
		_configure_country(ext, catalog, 260824))
	_expect("conserved-command economy configures", bool(ext.configure_economy(
		catalog, _active_profile(), 1, 260824).get("ok", false)))
	if not _bootstrap_opening(ext, catalog, 10, 8):
		return
	var day0 := _run_day(ext, 0)
	_expect("opening conserved-command day has zero ledger error",
		bool(day0.get("done", false)) and int(day0.get("population_error", 1)) == 0
		and int(day0.get("money_error", 1)) == 0 and int(day0.get("goods_error", 1)) == 0)
	var page: Dictionary = ext.get_family_cell_snapshot(0, 0, 64)
	_expect("opening family exists for conserved commands",
		bool(page.get("ok", false)) and int(page.get("total", 0)) == 1)
	if int(page.get("total", 0)) != 1:
		return
	var family_handle := int((page.family_handles as PackedInt64Array)[0])
	var branch_handle := 0
	var ready_day := 0
	for wait_day in range(0, 8):
		if wait_day > 0:
			var waited := _run_day(ext, wait_day)
			if not bool(waited.get("done", false)) or int(waited.get("population_error", 1)) != 0:
				_expect("waiting for family influence conserves population", false)
				return
		var branches: Dictionary = ext.get_family_branches(family_handle, 0, 64)
		var branch_handles: PackedInt64Array = branches.get("branch_handles", PackedInt64Array())
		if not branch_handles.is_empty() and int(branch_handles[0]) != 0:
			branch_handle = int(branch_handles[0])
			ready_day = wait_day
			break
		if wait_day == 7:
			print("branches=", branches)
	_expect("family branch handle is available", branch_handle != 0)
	if branch_handle == 0:
		return
	var command_day := (ready_day + 1) * 5
	var cell_before := int(ext.get_population_cell_snapshot(0).population)
	var family_before := int(ext.get_family_snapshot(family_handle).population)
	var absorb: Dictionary = ext.submit_economy_commands({
		"opcodes": PackedInt32Array([21]),
		"effective_days": PackedInt64Array([command_day]),
		"sequences": PackedInt64Array([10]),
		"target_handles": PackedInt64Array([branch_handle]),
		"i32_0": PackedInt32Array([0]),
		"i32_1": PackedInt32Array([-1]),
		"i64_0": PackedInt64Array([3]),
		"i64_1": PackedInt64Array([0]),
	})
	_expect("absorb-anonymous command is accepted", bool(absorb.get("ok", false)))
	if not bool(absorb.get("ok", false)):
		print("absorb=", absorb)
	var absorb_day := _run_day(ext, ready_day + 1)
	_expect("absorbing anonymous people keeps cell population and ledger totals unchanged",
		bool(absorb_day.get("done", false)) and int(absorb_day.get("population_error", 1)) == 0
		and int(absorb_day.get("money_error", 1)) == 0
		and int(absorb_day.get("goods_error", 1)) == 0
		and int(ext.get_population_cell_snapshot(0).population) == cell_before
		and int(ext.get_family_snapshot(family_handle).population) == family_before + 3)
	var building_before: Dictionary = ext.get_building_cell_snapshot(0)
	var counts_before: PackedInt64Array = building_before.get(
		"building_counts_by_type", PackedInt64Array())
	var payload_building: Dictionary = ext.submit_economy_commands({
		"opcodes": PackedInt32Array([14]),
		"effective_days": PackedInt64Array([command_day + 5]),
		"sequences": PackedInt64Array([20]),
		"target_handles": PackedInt64Array([branch_handle]),
		"i32_0": PackedInt32Array([0]),
		"i32_1": PackedInt32Array([-1]),
		"i64_0": PackedInt64Array([1]),
		"i64_1": PackedInt64Array([reward_building_id]),
	})
	_expect("free-building payload type_id is accepted when i32_1 is empty",
		bool(payload_building.get("ok", false)))
	var reward_day := _run_day(ext, ready_day + 2)
	var pending: PackedInt32Array = ext.get_building_cell_snapshot(0).get(
		"construction_type_ids", PackedInt32Array())
	_expect("payload-copied free building waits construction without materials",
		bool(reward_day.get("done", false)) and int(reward_day.get("rejected_commands", -1)) == 0
		and pending.has(reward_building_id)
		and int(reward_day.get("population_error", 1)) == 0)
	var complete_day := _run_day(ext, ready_day + 3)
	var counts_after: PackedInt64Array = ext.get_building_cell_snapshot(0).get(
		"building_counts_by_type", PackedInt64Array())
	_expect("payload-copied free building completes into the branch",
		bool(complete_day.get("done", false))
		and int(complete_day.get("population_error", 1)) == 0
		and int(counts_after[reward_building_id]) == int(counts_before[reward_building_id]) + 1)
	var discount: Dictionary = ext.submit_economy_commands({
		"opcodes": PackedInt32Array([22]),
		"effective_days": PackedInt64Array([command_day + 10]),
		"sequences": PackedInt64Array([30]),
		"target_handles": PackedInt64Array([branch_handle]),
		"i32_0": PackedInt32Array([0]),
		"i32_1": PackedInt32Array([-1]),
		"i64_0": PackedInt64Array([32768]),
		"i64_1": PackedInt64Array([0]),
	})
	_expect("purchase-discount command is accepted", bool(discount.get("ok", false)))
	var discount_day := _run_day(ext, ready_day + 4)
	_expect("buyer discount settles through subsidy/escrow without ledger error",
		bool(discount_day.get("done", false)) and not bool(discount_day.get("fatal", false))
		and int(discount_day.get("population_error", 1)) == 0
		and int(discount_day.get("money_error", 1)) == 0
		and int(discount_day.get("goods_error", 1)) == 0)
	var family_before_stash := int(ext.get_family_snapshot(family_handle).population)
	var stash: Dictionary = ext.submit_economy_commands({
		"opcodes": PackedInt32Array([15]),
		"effective_days": PackedInt64Array([command_day + 15]),
		"sequences": PackedInt64Array([40]),
		"target_handles": PackedInt64Array([branch_handle]),
		"i32_0": PackedInt32Array([-1]),
		"i32_1": PackedInt32Array([-1]),
		"i64_0": PackedInt64Array([4]),
		"i64_1": PackedInt64Array([0]),
	})
	_expect("colonization reward stash command is accepted", bool(stash.get("ok", false)))
	var stash_day := _run_day(ext, ready_day + 5)
	_expect("colonization reward stash does not mint people before settlement",
		bool(stash_day.get("done", false)) and int(stash_day.get("population_error", 1)) == 0
		and int(ext.get_family_snapshot(family_handle).population) == family_before_stash)


func _behavior_catalog(building_id: String, conditions: Array,
		tech_keys: PackedStringArray) -> Resource:
	var catalog := FamilyTraitCatalogScript.new()
	catalog.version = 1
	catalog.core_trait_min = 1
	catalog.core_trait_max = 1
	var core := FamilyTraitDefinitionScript.new()
	core.key = &"core_plain"
	core.display_name = "核心"
	core.weight = 1
	core.core_eligible = true
	var mountain := FamilyTraitDefinitionScript.new()
	mountain.key = &"mountain_folk"
	mountain.display_name = "山民"
	mountain.weight = 1
	mountain.core_eligible = false
	mountain.prerequisite_technology_keys = tech_keys
	var hunt := FamilyBehaviorPreferenceScript.new()
	hunt.axis = FamilyBehaviorPreferenceScript.Axis.INVESTMENT_BUILDING
	hunt.selector_kind = FamilyBehaviorPreferenceScript.SelectorKind.STABLE_ID
	hunt.selector_id = StringName(building_id)
	hunt.factor_q16 = Q16_ONE * 2
	hunt.score_term = FamilyBehaviorPreferenceScript.ScoreTerm.CANDIDATE_WEIGHT
	hunt.conditions = _resource_array(conditions)
	mountain.behaviors = _resource_array([hunt])
	var tax := FamilyTraitDefinitionScript.new()
	tax.key = &"tax_listener"
	tax.display_name = "听床师"
	tax.weight = 1
	tax.core_eligible = false
	var sensitivity := FamilyBehaviorPreferenceScript.new()
	sensitivity.axis = FamilyBehaviorPreferenceScript.Axis.INVESTMENT_BUILDING
	sensitivity.score_term = FamilyBehaviorPreferenceScript.ScoreTerm.TAX_SENSITIVITY
	sensitivity.factor_q16 = Q16_ONE * 2
	tax.behaviors = _resource_array([sensitivity])
	catalog.traits = _resource_array([core, mountain, tax])
	return catalog


func _resource_array(items: Array) -> Array[Resource]:
	var out: Array[Resource] = []
	for item in items:
		out.append(item)
	return out


func _landform_eq(landform: int) -> Resource:
	var condition := EffectConditionScript.new()
	condition.op = OP_EQ
	condition.arg0 = METRIC_LANDFORM
	condition.value_q16 = landform * Q16_ONE
	return condition


func _locked_technology(catalog: Dictionary) -> String:
	var flags: PackedInt32Array = catalog.get("technology_flags", PackedInt32Array())
	var ids: PackedStringArray = catalog.get("technology_ids", PackedStringArray())
	for index in range(mini(flags.size(), ids.size()) - 1, -1, -1):
		if (int(flags[index]) & FLAG_STARTING) == 0:
			return String(ids[index])
	return ""


func _boot_family(catalog: Dictionary, landform: int, seed: int) -> Dictionary:
	var ext := _new_ext(catalog, landform)
	if not _configure_country(ext, catalog, seed):
		_expect("behavior fixture country bootstraps", false)
		return {"ext": null, "family_handle": 0}
	if not bool(ext.configure_economy(catalog, _active_profile(), 1, seed).get("ok", false)):
		_expect("behavior fixture economy configures", false)
		return {"ext": null, "family_handle": 0}
	if not _bootstrap_opening(ext, catalog):
		return {"ext": null, "family_handle": 0}
	var day0 := _run_day(ext, 0)
	if not bool(day0.get("done", false)) or int(day0.get("population_error", 1)) != 0:
		_expect("behavior fixture day0 conserves population", false)
		print("behavior day0=", day0)
		return {"ext": null, "family_handle": 0}
	var page: Dictionary = ext.get_family_cell_snapshot(0, 0, 64)
	if int(page.get("total", 0)) != 1:
		_expect("behavior fixture forms one founder family", false)
		return {"ext": null, "family_handle": 0}
	return {"ext": ext, "family_handle": int((page.family_handles as PackedInt64Array)[0])}


func _grant_additional(ext: Object, family_handle: int, catalog: Dictionary,
		keys: PackedStringArray) -> void:
	var ids: PackedStringArray = catalog.family_trait_ids
	var mins: PackedInt32Array = catalog.family_trait_strength_min_q16
	var operations := PackedInt32Array()
	var handles := PackedInt64Array()
	var trait_keys := PackedStringArray()
	var strengths := PackedInt32Array()
	var days := PackedInt64Array()
	var priorities := PackedInt32Array()
	var sequences := PackedInt64Array()
	for index in range(keys.size()):
		var trait_id := ids.find(String(keys[index]))
		if trait_id < 0:
			continue
		operations.append(1)
		handles.append(family_handle)
		trait_keys.append(String(keys[index]))
		strengths.append(int(mins[trait_id]))
		days.append(5)
		priorities.append(100 + index)
		sequences.append(index + 1)
	if operations.is_empty():
		_expect("additional traits exist in the compiled catalog", false)
		return
	var submitted: Dictionary = ext.submit_family_trait_commands({
		"protocol_version": 1,
		"operations": operations,
		"family_handles": handles,
		"trait_keys": trait_keys,
		"strength_q16": strengths,
		"effective_days": days,
		"priorities": priorities,
		"sequences": sequences,
	})
	_expect("additional behavior traits are accepted", bool(submitted.get("ok", false)))


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


func _bootstrap_opening(ext: Object, catalog: Dictionary, operators: int = 2,
		anonymous: int = 18) -> bool:
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
		"population": PackedInt64Array([operators, anonymous]),
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


func _configure_country(ext: Object, catalog: Dictionary, seed: int,
		starting_technology_ids: PackedStringArray = PackedStringArray()) -> bool:
	var ids: PackedStringArray = starting_technology_ids
	if ids.is_empty():
		ids = catalog.technology_ids
	var technology_indices := PackedInt32Array()
	var catalog_ids: PackedStringArray = catalog.technology_ids
	for id in ids:
		var dense := catalog_ids.find(String(id))
		if dense >= 0:
			technology_indices.append(dense)
	var configured: Dictionary = ext.configure_country(catalog, {
		"country_runtime_mode": "ACTIVE",
		"starting_technology_ids": ids,
	}, 1, seed)
	if not bool(configured.get("ok", false)):
		return false
	return bool(ext.bootstrap_country({
		"country_ids": PackedStringArray(["country.family_behavior_test"]),
		"country_names": PackedStringArray(["家族行为测试国"]),
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
