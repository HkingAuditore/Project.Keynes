class_name FamilyTraitCatalog
extends Resource

const DEFAULT_PATH := "res://data/economy/default_family_traits.tres"
const OfficialCatalogScript = preload("res://scripts/family/family_official_catalog.gd")
const BehaviorScript = preload("res://scripts/family/family_behavior_preference.gd")
const ModifierEffectScript = preload("res://scripts/family/family_modifier_effect.gd")
const TriggerBindingScript = preload("res://scripts/family/family_trigger_binding.gd")
const TraitDefinitionScript = preload("res://scripts/family/family_trait_definition.gd")
const EffectConditionScript = preload("res://scripts/effect/effect_condition.gd")
const Q16_ONE := 65536
const DEFAULT_TRIGGER_CATALOG_PATH := "res://data/triggers/default_trigger_catalog.tres"

@export var version: int = 1
@export_range(0, 16, 1) var core_trait_min: int = 2
@export_range(0, 16, 1) var core_trait_max: int = 4
@export var traits: Array[Resource] = []


static func load_default() -> Resource:
	var loaded = ResourceLoader.load(DEFAULT_PATH, "Resource")
	return OfficialCatalogScript.hydrate_trait_catalog(loaded)

func compile_native_columns(economy_columns: Dictionary,
		known_family_effect_keys: PackedStringArray = PackedStringArray(),
		known_family_effect_source_kinds: PackedInt32Array = PackedInt32Array()) -> Dictionary:
	if version <= 0 or core_trait_min < 0 or core_trait_max < core_trait_min:
		return {"ok": false, "reason": "family_trait_catalog_policy_invalid"}
	var ordered: Array[Resource] = traits.duplicate()
	var known_effects := {}
	if not known_family_effect_source_kinds.is_empty() \
			and known_family_effect_source_kinds.size() != known_family_effect_keys.size():
		return {"ok": false, "reason": "family_trait_effect_catalog_shape_invalid"}
	for effect_index in range(known_family_effect_keys.size()):
		var effect_key := known_family_effect_keys[effect_index]
		var stable_key := String(effect_key).strip_edges()
		if stable_key.is_empty() or known_effects.has(stable_key):
			return {"ok": false, "reason": "family_trait_effect_catalog_key_invalid"}
		known_effects[stable_key] = int(known_family_effect_source_kinds[effect_index]) \
			if not known_family_effect_source_kinds.is_empty() else 0
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
	var technology_prerequisite_offsets := PackedInt32Array([0])
	var technology_prerequisites := PackedInt32Array()
	var technology_match_any := PackedByteArray()
	var behavior_offsets := PackedInt32Array([0])
	var behavior_axes := PackedInt32Array()
	var behavior_selector_kinds := PackedInt32Array()
	var behavior_selector_ids := PackedInt32Array()
	var behavior_factors := PackedInt32Array()
	var behavior_score_terms := PackedInt32Array()
	var behavior_condition_offsets := PackedInt32Array([0])
	var behavior_condition_ops := PackedInt32Array()
	var behavior_condition_arg0 := PackedInt32Array()
	var behavior_condition_values := PackedInt64Array()
	var technology_ids: PackedStringArray = economy_columns.get(
		"technology_ids", PackedStringArray())
	var technology_index := {}
	for technology_dense_id in range(technology_ids.size()):
		technology_index[String(technology_ids[technology_dense_id])] = technology_dense_id
	var modifier_offsets := PackedInt32Array([0])
	var modifier_keys := PackedStringArray()
	var modifier_targets := PackedInt32Array()
	var modifier_tier_magnitudes := PackedInt32Array()
	var trigger_offsets := PackedInt32Array([0])
	var trigger_definition_keys := PackedStringArray()
	var trigger_reward_targets := PackedInt32Array()
	var effect_offsets := PackedInt32Array([0])
	var effect_keys := PackedStringArray()
	var origin_landform_offsets := PackedInt32Array([0])
	var origin_landforms := PackedByteArray()
	var origin_adjacent_water := PackedByteArray()
	var origin_population_max := PackedInt32Array()
	var origin_temperature_max_q16 := PackedInt32Array()
	var required_resource_offsets := PackedInt32Array([0])
	var required_resource_ids := PackedInt32Array()
	var require_tax_or_subsidy := PackedByteArray()
	var resource_ids: PackedStringArray = economy_columns.get(
		"resource_ids", PackedStringArray())
	if resource_ids.is_empty():
		resource_ids = economy_columns.get("building_resource_ids", PackedStringArray())
	var resource_index := {}
	for resource_dense_id in range(resource_ids.size()):
		resource_index[String(resource_ids[resource_dense_id])] = resource_dense_id
	var dynamic_trigger_keys := {}
	var trigger_reward_by_key := {}
	var trigger_catalog = ResourceLoader.load(DEFAULT_TRIGGER_CATALOG_PATH, "Resource")
	if trigger_catalog == null:
		return {"ok": false, "reason": "family_trait_trigger_catalog_unavailable"}
	var trigger_definitions: Variant = trigger_catalog.get("definitions")
	if not trigger_definitions is Array:
		return {"ok": false, "reason": "family_trait_trigger_catalog_unavailable"}
	for trigger_definition in trigger_definitions:
		if trigger_definition != null and bool(trigger_definition.dynamic_binding):
			dynamic_trigger_keys[String(trigger_definition.key)] = true

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
		var authored_technology_keys: Array[String] = []
		for technology in definition.prerequisite_technology_keys:
			authored_technology_keys.append(String(technology).strip_edges())
		authored_technology_keys.sort()
		var technology_seen := {}
		for technology_key in authored_technology_keys:
			if technology_key.is_empty() or technology_seen.has(technology_key):
				return {"ok": false, "reason": "family_trait_technology_prerequisite_duplicate"}
			technology_seen[technology_key] = true
			if not technology_ids.is_empty() and not technology_index.has(technology_key):
				return {"ok": false, "reason": "family_trait_technology_prerequisite_unknown"}
			if technology_index.has(technology_key):
				technology_prerequisites.append(int(technology_index[technology_key]))
		technology_prerequisite_offsets.append(technology_prerequisites.size())
		technology_match_any.append(1 if definition.prerequisite_technology_any else 0)
		for behavior in definition.behaviors:
			if behavior == null or not behavior is BehaviorScript \
					or behavior.factor_q16 < 0 or behavior.factor_q16 > Q16_ONE * 4 \
					or int(behavior.score_term) < 0 \
					or int(behavior.score_term) > BehaviorScript.ScoreTerm.CAREER_MOBILITY:
				return {"ok": false, "reason": "family_trait_behavior_invalid"}
			var compiled_conditions: Array[Resource] = []
			for condition in behavior.conditions:
				if condition == null or not condition is EffectConditionScript:
					return {"ok": false, "reason": "family_trait_behavior_condition_invalid"}
				if int(condition.op) < 1 or int(condition.op) > 8:
					return {"ok": false, "reason": "family_trait_behavior_condition_opcode_invalid"}
				compiled_conditions.append(condition)
			var selectors := PackedInt32Array()
			if String(behavior.selector_id).strip_edges().is_empty():
				if int(behavior.score_term) == BehaviorScript.ScoreTerm.CANDIDATE_WEIGHT:
					return {"ok": false, "reason": "family_trait_behavior_selector_unknown"}
				selectors.append(-1)
			else:
				selectors = _resolve_selectors(behavior, economy_columns)
				if selectors.is_empty():
					return {"ok": false, "reason": "family_trait_behavior_selector_unknown"}
			for selector in selectors:
				behavior_axes.append(behavior.axis)
				# Every cold selector is expanded to exact dense IDs. The native
				# runtime therefore has one branch-local CSR lookup shape.
				behavior_selector_kinds.append(BehaviorScript.SelectorKind.STABLE_ID)
				behavior_selector_ids.append(selector)
				behavior_factors.append(behavior.factor_q16)
				behavior_score_terms.append(int(behavior.score_term))
				for condition in compiled_conditions:
					behavior_condition_ops.append(int(condition.op))
					behavior_condition_arg0.append(int(condition.arg0))
					behavior_condition_values.append(int(condition.value_q16))
				behavior_condition_offsets.append(behavior_condition_ops.size())
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
				var trigger_key := String(definition_key)
				if not trigger_key.is_empty() and not dynamic_trigger_keys.has(trigger_key):
					return {"ok": false, "reason": "family_trait_trigger_definition_unknown"}
				if not trigger_key.is_empty() and trigger_reward_by_key.has(trigger_key) \
						and int(trigger_reward_by_key[trigger_key]) != int(binding.reward_target):
					return {"ok": false, "reason": "family_trait_trigger_reward_conflict"}
				if not trigger_key.is_empty():
					trigger_reward_by_key[trigger_key] = int(binding.reward_target)
				trigger_definition_keys.append(trigger_key)
			trigger_reward_targets.append(binding.reward_target)
		trigger_offsets.append(trigger_reward_targets.size())
		var seen_effect_keys := {}
		for authored_effect_key in definition.effect_keys:
			var effect_key := String(authored_effect_key).strip_edges()
			if effect_key.is_empty() or seen_effect_keys.has(effect_key):
				return {"ok": false, "reason": "family_trait_effect_key_invalid"}
			if not known_effects.is_empty() \
					and not known_effects.has("family.effect.%s" % effect_key):
				return {"ok": false, "reason": "family_trait_effect_unknown"}
			if known_effects.has("family.effect.%s" % effect_key) \
					and int(known_effects["family.effect.%s" % effect_key]) != 0:
				return {"ok": false, "reason": "family_trait_effect_source_invalid"}
			seen_effect_keys[effect_key] = true
			effect_keys.append("family.effect.%s" % effect_key)
		effect_offsets.append(effect_keys.size())
		var landform_seen := {}
		for landform in definition.origin_landforms:
			var landform_id := int(landform) & 0xff
			if landform_seen.has(landform_id):
				return {"ok": false, "reason": "family_trait_origin_landform_duplicate"}
			landform_seen[landform_id] = true
			origin_landforms.append(landform_id)
		origin_landform_offsets.append(origin_landforms.size())
		origin_adjacent_water.append(1 if definition.origin_adjacent_water else 0)
		origin_population_max.append(maxi(0, int(definition.origin_population_max)))
		origin_temperature_max_q16.append(int(definition.origin_temperature_max_q16))
		var resource_seen := {}
		var authored_resources: Array[String] = []
		for resource_id in definition.required_resource_ids:
			authored_resources.append(String(resource_id).strip_edges())
		authored_resources.sort()
		for resource_key in authored_resources:
			if resource_key.is_empty() or resource_seen.has(resource_key):
				return {"ok": false, "reason": "family_trait_required_resource_invalid"}
			resource_seen[resource_key] = true
			if not resource_ids.is_empty() and not resource_index.has(resource_key):
				return {"ok": false, "reason": "family_trait_required_resource_unknown"}
			if resource_index.has(resource_key):
				required_resource_ids.append(int(resource_index[resource_key]))
		required_resource_offsets.append(required_resource_ids.size())
		require_tax_or_subsidy.append(1 if definition.require_tax_or_subsidy else 0)

	var canonical := [version, core_trait_min, core_trait_max, ids, versions, weights,
		core_eligible, strength_min, strength_max, strength_step,
		prerequisite_offsets, prerequisites, exclusion_offsets, exclusions,
		technology_prerequisite_offsets, technology_prerequisites, technology_match_any,
		behavior_offsets, behavior_axes, behavior_selector_kinds, behavior_selector_ids,
		behavior_factors, behavior_score_terms, behavior_condition_offsets,
		behavior_condition_ops, behavior_condition_arg0, behavior_condition_values,
		modifier_offsets, modifier_keys, modifier_targets,
		modifier_tier_magnitudes, trigger_offsets, trigger_definition_keys,
		trigger_reward_targets, effect_offsets, effect_keys,
		origin_landform_offsets, origin_landforms, origin_adjacent_water,
		origin_population_max, origin_temperature_max_q16,
		required_resource_offsets, required_resource_ids, require_tax_or_subsidy]
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
		"family_trait_technology_prerequisite_offsets": technology_prerequisite_offsets,
		"family_trait_technology_prerequisites": technology_prerequisites,
		"family_trait_technology_match_any": technology_match_any,
		"family_trait_behavior_offsets": behavior_offsets,
		"family_trait_behavior_axes": behavior_axes,
		"family_trait_behavior_selector_kinds": behavior_selector_kinds,
		"family_trait_behavior_selector_ids": behavior_selector_ids,
		"family_trait_behavior_factors_q16": behavior_factors,
		"family_trait_behavior_score_terms": behavior_score_terms,
		"family_trait_behavior_condition_offsets": behavior_condition_offsets,
		"family_trait_behavior_condition_ops": behavior_condition_ops,
		"family_trait_behavior_condition_arg0": behavior_condition_arg0,
		"family_trait_behavior_condition_values": behavior_condition_values,
		"family_trait_modifier_offsets": modifier_offsets,
		"family_trait_modifier_definition_keys": modifier_keys,
		"family_trait_modifier_targets": modifier_targets,
		"family_trait_modifier_tier_magnitudes_q16": modifier_tier_magnitudes,
		"family_trait_trigger_offsets": trigger_offsets,
		"family_trait_trigger_definition_keys_by_tier": trigger_definition_keys,
		"family_trait_trigger_reward_targets": trigger_reward_targets,
		"family_trait_effect_offsets": effect_offsets,
		"family_trait_effect_keys": effect_keys,
		"family_trait_origin_landform_offsets": origin_landform_offsets,
		"family_trait_origin_landforms": origin_landforms,
		"family_trait_origin_adjacent_water": origin_adjacent_water,
		"family_trait_origin_population_max": origin_population_max,
		"family_trait_origin_temperature_max_q16": origin_temperature_max_q16,
		"family_trait_required_resource_offsets": required_resource_offsets,
		"family_trait_required_resource_ids": required_resource_ids,
		"family_trait_require_tax_or_subsidy": require_tax_or_subsidy,
	}


func _resolve_selectors(behavior: Resource,
		economy_columns: Dictionary) -> PackedInt32Array:
	var selector_id := String(behavior.selector_id).strip_edges()
	if selector_id.is_empty():
		return PackedInt32Array()
	var stable_ids := PackedStringArray()
	match behavior.axis:
		BehaviorScript.Axis.INVESTMENT_BUILDING:
			stable_ids = economy_columns.get("building_type_ids", PackedStringArray())
		BehaviorScript.Axis.CAREER_PROFESSION:
			stable_ids = economy_columns.get("profession_ids", PackedStringArray())
		BehaviorScript.Axis.CONSUMPTION_NEED:
			stable_ids = economy_columns.get("need_ids", PackedStringArray())
		BehaviorScript.Axis.CONSUMPTION_GOOD:
			stable_ids = economy_columns.get("good_ids", PackedStringArray())
		_:
			return PackedInt32Array()
	if selector_id == "*" or selector_id == "all":
		var expanded := PackedInt32Array()
		expanded.resize(stable_ids.size())
		for index in range(stable_ids.size()):
			expanded[index] = index
		return expanded
	if behavior.selector_kind == BehaviorScript.SelectorKind.STABLE_ID:
		var dense_id := stable_ids.find(selector_id)
		return PackedInt32Array([dense_id]) if dense_id >= 0 else PackedInt32Array()
	if behavior.selector_kind == BehaviorScript.SelectorKind.BUILDING_SECTOR:
		if behavior.axis != BehaviorScript.Axis.INVESTMENT_BUILDING:
			return PackedInt32Array()
		var sector_map := {"agriculture": 0, "extractive": 1,
			"manufacturing": 2, "energy": 3, "knowledge": 4}
		var sector := int(sector_map.get(selector_id, selector_id.to_int() \
			if selector_id.is_valid_int() else -1))
		return _matching_scalar_ids(economy_columns.get(
			"building_economic_sectors", PackedInt32Array()), sector)
	if behavior.selector_kind == BehaviorScript.SelectorKind.CATEGORY:
		match behavior.axis:
			BehaviorScript.Axis.INVESTMENT_BUILDING:
				var kind_map := {"collector": 0, "industrial": 1, "service": 2}
				var kind := int(kind_map.get(selector_id, selector_id.to_int() \
					if selector_id.is_valid_int() else -1))
				return _matching_scalar_ids(economy_columns.get(
					"building_kinds", PackedInt32Array()), kind)
			BehaviorScript.Axis.CAREER_PROFESSION:
				return _matching_string_ids(economy_columns.get(
					"profession_class_ids", PackedStringArray()), selector_id)
			BehaviorScript.Axis.CONSUMPTION_GOOD:
				return _matching_string_ids(economy_columns.get(
					"good_category_ids", PackedStringArray()), selector_id)
		return PackedInt32Array()
	if behavior.selector_kind == BehaviorScript.SelectorKind.SUBSTITUTION_CATEGORY:
		if behavior.axis != BehaviorScript.Axis.CONSUMPTION_GOOD:
			return PackedInt32Array()
		return _matching_csr_ids(economy_columns.get(
			"good_substitution_category_offsets", PackedInt32Array()),
			economy_columns.get("good_substitution_category_ids", PackedStringArray()),
			selector_id, stable_ids.size())
	if behavior.selector_kind == BehaviorScript.SelectorKind.SEMANTIC_TAG:
		var prefix: String = {BehaviorScript.Axis.INVESTMENT_BUILDING: "building",
			BehaviorScript.Axis.CAREER_PROFESSION: "profession",
			BehaviorScript.Axis.CONSUMPTION_NEED: "need",
			BehaviorScript.Axis.CONSUMPTION_GOOD: "good"}.get(behavior.axis, "")
		if prefix.is_empty():
			return PackedInt32Array()
		return _matching_csr_ids(economy_columns.get(
			"%s_semantic_tag_offsets" % prefix, PackedInt32Array()),
			economy_columns.get("%s_semantic_tags" % prefix, PackedStringArray()),
			selector_id, stable_ids.size())
	return PackedInt32Array()


static func _matching_scalar_ids(values: PackedInt32Array,
		target: int) -> PackedInt32Array:
	var out := PackedInt32Array()
	if target < 0:
		return out
	for index in range(values.size()):
		if int(values[index]) == target:
			out.append(index)
	return out


static func _matching_string_ids(values: PackedStringArray,
		target: String) -> PackedInt32Array:
	var out := PackedInt32Array()
	for index in range(values.size()):
		if String(values[index]) == target:
			out.append(index)
	return out


static func _matching_csr_ids(offsets: PackedInt32Array,
		values: PackedStringArray, target: String, row_count: int) -> PackedInt32Array:
	var out := PackedInt32Array()
	if offsets.size() != row_count + 1 or offsets.is_empty() \
			or offsets[0] != 0 or offsets[-1] != values.size():
		return out
	for row in range(row_count):
		var begin := int(offsets[row])
		var end := int(offsets[row + 1])
		if begin < 0 or end < begin or end > values.size():
			return PackedInt32Array()
		for edge in range(begin, end):
			if String(values[edge]) == target:
				out.append(row)
				break
	return out
