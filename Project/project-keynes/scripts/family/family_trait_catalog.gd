class_name FamilyTraitCatalog
extends Resource

const DEFAULT_PATH := "res://data/economy/default_family_traits.tres"
const BehaviorScript = preload("res://scripts/family/family_behavior_preference.gd")
const ModifierEffectScript = preload("res://scripts/family/family_modifier_effect.gd")
const TriggerBindingScript = preload("res://scripts/family/family_trigger_binding.gd")
const TraitDefinitionScript = preload("res://scripts/family/family_trait_definition.gd")
const Q16_ONE := 65536

@export var version: int = 1
@export_range(0, 16, 1) var core_trait_min: int = 2
@export_range(0, 16, 1) var core_trait_max: int = 4
@export var traits: Array[Resource] = []


static func load_default() -> Resource:
	return ResourceLoader.load(DEFAULT_PATH, "Resource")


func compile_native_columns(economy_columns: Dictionary) -> Dictionary:
	if version <= 0 or core_trait_min < 0 or core_trait_max < core_trait_min:
		return {"ok": false, "reason": "family_trait_catalog_policy_invalid"}
	var ordered: Array[Resource] = traits.duplicate()
	ordered.sort_custom(func(a, b) -> bool:
		return String(a.key) < String(b.key))
	var ids := PackedStringArray()
	var versions := PackedInt32Array()
	var names := PackedStringArray()
	var weights := PackedInt32Array()
	var core_eligible := PackedByteArray()
	var strength_min := PackedInt32Array()
	var strength_max := PackedInt32Array()
	var strength_step := PackedInt32Array()
	var index := {}
	for definition in ordered:
		if definition == null or not definition is TraitDefinitionScript:
			return {"ok": false, "reason": "family_trait_resource_invalid"}
		var key := String(definition.key).strip_edges()
		if key == "" or index.has(key) or definition.version <= 0 or definition.weight <= 0 \
				or definition.strength_min_q16 < 0 \
				or definition.strength_max_q16 < definition.strength_min_q16 \
				or definition.strength_step_q16 <= 0:
			return {"ok": false, "reason": "family_trait_definition_invalid"}
		index[key] = ids.size()
		ids.append(key)
		versions.append(definition.version)
		names.append(definition.display_name if not definition.display_name.is_empty() else key)
		weights.append(definition.weight)
		core_eligible.append(1 if definition.core_eligible else 0)
		strength_min.append(definition.strength_min_q16)
		strength_max.append(definition.strength_max_q16)
		strength_step.append(definition.strength_step_q16)
	var core_eligible_count := 0
	for eligible in core_eligible:
		core_eligible_count += int(eligible != 0)
	if core_trait_max > core_eligible_count:
		return {"ok": false, "reason": "family_trait_core_count_exceeds_catalog"}

	var prerequisite_offsets := PackedInt32Array([0])
	var prerequisites := PackedInt32Array()
	var exclusion_offsets := PackedInt32Array([0])
	var exclusions := PackedInt32Array()
	var behavior_offsets := PackedInt32Array([0])
	var behavior_axes := PackedInt32Array()
	var behavior_selector_kinds := PackedInt32Array()
	var behavior_selector_ids := PackedInt32Array()
	var behavior_factors := PackedInt32Array()
	var modifier_offsets := PackedInt32Array([0])
	var modifier_keys := PackedStringArray()
	var modifier_targets := PackedInt32Array()
	var modifier_tier_magnitudes := PackedInt32Array()
	var trigger_offsets := PackedInt32Array([0])
	var trigger_definition_keys := PackedStringArray()
	var trigger_reward_targets := PackedInt32Array()

	var building_ids: PackedStringArray = economy_columns.get("building_type_ids", PackedStringArray())
	var profession_ids: PackedStringArray = economy_columns.get("profession_ids", PackedStringArray())
	var need_ids: PackedStringArray = economy_columns.get("need_ids", PackedStringArray())
	for definition in ordered:
		var trait_idx := int(index[String(definition.key)])
		for prerequisite in definition.prerequisite_keys:
			var prerequisite_key := String(prerequisite)
			if not index.has(prerequisite_key) or int(index[prerequisite_key]) == trait_idx:
				return {"ok": false, "reason": "family_trait_prerequisite_invalid"}
			prerequisites.append(int(index[prerequisite_key]))
		prerequisite_offsets.append(prerequisites.size())
		for exclusion in definition.exclusion_keys:
			var exclusion_key := String(exclusion)
			if not index.has(exclusion_key) or int(index[exclusion_key]) == trait_idx:
				return {"ok": false, "reason": "family_trait_exclusion_invalid"}
			exclusions.append(int(index[exclusion_key]))
		exclusion_offsets.append(exclusions.size())
		for behavior in definition.behaviors:
			if behavior == null or not behavior is BehaviorScript \
					or behavior.factor_q16 < 0 or behavior.factor_q16 > Q16_ONE * 4:
				return {"ok": false, "reason": "family_trait_behavior_invalid"}
			var selector := _resolve_selector(behavior, building_ids, profession_ids, need_ids)
			if selector < 0:
				return {"ok": false, "reason": "family_trait_behavior_selector_unknown"}
			behavior_axes.append(behavior.axis)
			behavior_selector_kinds.append(behavior.selector_kind)
			behavior_selector_ids.append(selector)
			behavior_factors.append(behavior.factor_q16)
		behavior_offsets.append(behavior_axes.size())
		for effect in definition.modifiers:
			if effect == null or not effect is ModifierEffectScript \
					or effect.definition_key == &"" or effect.tier_magnitude_q16.size() != 6:
				return {"ok": false, "reason": "family_trait_modifier_invalid"}
			modifier_keys.append(String(effect.definition_key))
			modifier_targets.append(effect.target)
			for magnitude in effect.tier_magnitude_q16:
				if magnitude < 0 or magnitude > Q16_ONE * 4:
					return {"ok": false, "reason": "family_trait_modifier_magnitude_invalid"}
				modifier_tier_magnitudes.append(magnitude)
		modifier_offsets.append(modifier_keys.size())
		for binding in definition.triggers:
			if binding == null or not binding is TriggerBindingScript \
					or binding.definition_keys_by_tier.size() != 6:
				return {"ok": false, "reason": "family_trait_trigger_invalid"}
			for definition_key in binding.definition_keys_by_tier:
				trigger_definition_keys.append(String(definition_key))
			trigger_reward_targets.append(binding.reward_target)
		trigger_offsets.append(trigger_reward_targets.size())

	var canonical := [version, core_trait_min, core_trait_max, ids, versions, weights,
		core_eligible, strength_min, strength_max, strength_step,
		prerequisite_offsets, prerequisites, exclusion_offsets, exclusions,
		behavior_offsets, behavior_axes, behavior_selector_kinds, behavior_selector_ids,
		behavior_factors, modifier_offsets, modifier_keys, modifier_targets,
		modifier_tier_magnitudes, trigger_offsets, trigger_definition_keys,
		trigger_reward_targets]
	var catalog_hash := hash(canonical)
	if catalog_hash == 0:
		catalog_hash = 1
	return {
		"ok": true,
		"family_trait_catalog_version": version,
		"family_trait_catalog_hash": catalog_hash,
		"family_core_trait_min": core_trait_min,
		"family_core_trait_max": core_trait_max,
		"family_trait_ids": ids,
		"family_trait_versions": versions,
		"family_trait_display_names": names,
		"family_trait_weights": weights,
		"family_trait_core_eligible": core_eligible,
		"family_trait_strength_min_q16": strength_min,
		"family_trait_strength_max_q16": strength_max,
		"family_trait_strength_step_q16": strength_step,
		"family_trait_prerequisite_offsets": prerequisite_offsets,
		"family_trait_prerequisites": prerequisites,
		"family_trait_exclusion_offsets": exclusion_offsets,
		"family_trait_exclusions": exclusions,
		"family_trait_behavior_offsets": behavior_offsets,
		"family_trait_behavior_axes": behavior_axes,
		"family_trait_behavior_selector_kinds": behavior_selector_kinds,
		"family_trait_behavior_selector_ids": behavior_selector_ids,
		"family_trait_behavior_factors_q16": behavior_factors,
		"family_trait_modifier_offsets": modifier_offsets,
		"family_trait_modifier_definition_keys": modifier_keys,
		"family_trait_modifier_targets": modifier_targets,
		"family_trait_modifier_tier_magnitudes_q16": modifier_tier_magnitudes,
		"family_trait_trigger_offsets": trigger_offsets,
		"family_trait_trigger_definition_keys_by_tier": trigger_definition_keys,
		"family_trait_trigger_reward_targets": trigger_reward_targets,
	}


func _resolve_selector(behavior: Resource, building_ids: PackedStringArray,
		profession_ids: PackedStringArray, need_ids: PackedStringArray) -> int:
	if behavior.selector_kind == BehaviorScript.SelectorKind.BUILDING_SECTOR:
		var sector_id := String(behavior.selector_id)
		if not sector_id.is_valid_int():
			return -1
		var sector := sector_id.to_int()
		return sector if sector >= 0 and sector <= 4 else -1
	var stable_id := String(behavior.selector_id)
	if behavior.axis == BehaviorScript.Axis.INVESTMENT_BUILDING:
		return building_ids.find(stable_id)
	if behavior.axis == BehaviorScript.Axis.CAREER_PROFESSION:
		return profession_ids.find(stable_id)
	if behavior.axis == BehaviorScript.Axis.CONSUMPTION_NEED:
		return need_ids.find(stable_id)
	return -1
