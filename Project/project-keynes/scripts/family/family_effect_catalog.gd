class_name FamilyEffectCatalog
extends Resource

const DEFAULT_PATH := "res://data/economy/default_family_effects.tres"
const OfficialCatalogScript = preload("res://scripts/family/family_official_catalog.gd")
const DefinitionScript = preload("res://scripts/family/family_effect_definition.gd")
const EffectDefinitionScript = preload("res://scripts/effect/effect_definition.gd")

@export var version: int = 1
@export var effects: Array[Resource] = []

static func load_default() -> Resource:
	var loaded = ResourceLoader.load(DEFAULT_PATH, "Resource")
	return OfficialCatalogScript.hydrate_effect_catalog(loaded)

func compile_native_catalog(technology_ids: PackedStringArray = PackedStringArray()) -> Dictionary:
	if version <= 0:
		return {"ok": false, "reason": "family_effect_catalog_version_invalid"}
	var ordered: Array[Resource] = effects.duplicate()
	ordered.sort_custom(func(a, b) -> bool: return String(a.key) < String(b.key))
	var definitions: Array[Resource] = []
	var keys := PackedStringArray()
	var source_kinds := PackedInt32Array()
	var target_domains := PackedInt32Array()
	var operations := PackedInt32Array()
	var lifecycles := PackedInt32Array()
	var duration_days := PackedInt32Array()
	var stack_policies := PackedInt32Array()
	var stack_keys := PackedStringArray()
	var max_stacks := PackedInt32Array()
	var priorities := PackedInt32Array()
	var selector_kinds := PackedInt32Array()
	var selector_ids := PackedStringArray()
	var weights := PackedInt32Array()
	var random_pool_eligible := PackedByteArray()
	var exclusion_offsets := PackedInt32Array([0])
	var exclusions := PackedInt32Array()
	var magnitude_by_prestige := PackedInt32Array()
	var trigger_definition_keys_by_tier := PackedStringArray()
	var trigger_reward_targets := PackedInt32Array()
	var prerequisite_offsets := PackedInt32Array([0])
	var prerequisite_technology_indices := PackedInt32Array()
	var technology_match_any := PackedByteArray()
	var technology_index := {}
	for i in range(technology_ids.size()):
		technology_index[String(technology_ids[i])] = i
	var seen := {}
	var stack_contracts := {}
	for authored in ordered:
		if authored == null or not authored is DefinitionScript:
			return {"ok": false, "reason": "family_effect_resource_invalid"}
		var key := String(authored.key).strip_edges()
		if key.is_empty() or seen.has(key) or authored.version <= 0 \
				or authored.weight <= 0 or authored.max_stacks <= 0 \
				or authored.duration_days == 0:
			return {"ok": false, "reason": "family_effect_definition_invalid"}
		if authored.source_kind < 0 or authored.source_kind > DefinitionScript.SourceKind.COUNTRY_STATE \
				or authored.target_domain < 0 or authored.target_domain > DefinitionScript.TargetDomain.BUILDING_RESOURCE \
				or authored.operation < 0 or authored.operation > DefinitionScript.Operation.EVENT_COMMAND \
				or authored.lifecycle < 0 or authored.lifecycle > DefinitionScript.Lifecycle.EVENT_ONCE \
				or authored.stack_policy < 0 or authored.stack_policy > DefinitionScript.StackPolicy.MIN \
				or authored.target_selector_kind < 0 or authored.target_selector_kind > DefinitionScript.TargetSelectorKind.NEIGHBORS_R2:
			return {"ok": false, "reason": "family_effect_enum_invalid"}
		if authored.lifecycle == DefinitionScript.Lifecycle.DURATION and authored.duration_days < 1:
			return {"ok": false, "reason": "family_effect_duration_invalid"}
		if authored.lifecycle != DefinitionScript.Lifecycle.DURATION \
				and authored.duration_days != -1:
			return {"ok": false, "reason": "family_effect_non_duration_days_invalid"}
		if authored.random_pool_eligible != \
				(authored.source_kind == DefinitionScript.SourceKind.RANDOM_POOL):
			return {"ok": false, "reason": "family_effect_random_pool_source_mismatch"}
		if authored.lifecycle == DefinitionScript.Lifecycle.EVENT_ONCE \
				and authored.operation != DefinitionScript.Operation.EVENT_COMMAND:
			return {"ok": false, "reason": "family_effect_event_lifecycle_invalid"}
		if authored.operation == DefinitionScript.Operation.EVENT_COMMAND \
				and authored.lifecycle != DefinitionScript.Lifecycle.EVENT_ONCE:
			return {"ok": false, "reason": "family_effect_event_operation_invalid"}
		if authored.operation == DefinitionScript.Operation.CONDITIONAL_OVERRIDE \
				and authored.conditions.is_empty():
			return {"ok": false, "reason": "family_effect_conditional_override_requires_condition"}
		if authored.stack_policy == DefinitionScript.StackPolicy.REFRESH \
				and authored.lifecycle != DefinitionScript.Lifecycle.DURATION:
			return {"ok": false, "reason": "family_effect_refresh_requires_duration"}
		if authored.stack_policy == DefinitionScript.StackPolicy.ADD_STACK:
			if authored.max_stacks <= 1:
				return {"ok": false, "reason": "family_effect_add_stack_cap_invalid"}
		elif authored.max_stacks != 1:
			return {"ok": false, "reason": "family_effect_single_winner_stack_cap_invalid"}
		if authored.operation in [DefinitionScript.Operation.OVERRIDE,
				DefinitionScript.Operation.CONDITIONAL_OVERRIDE] \
				and authored.stack_policy not in [DefinitionScript.StackPolicy.REPLACE,
					DefinitionScript.StackPolicy.MAX, DefinitionScript.StackPolicy.MIN]:
			return {"ok": false, "reason": "family_effect_override_stack_policy_invalid"}
		if authored.target_selector_kind in [
				DefinitionScript.TargetSelectorKind.NEIGHBORS_R1,
				DefinitionScript.TargetSelectorKind.NEIGHBORS_R2] \
				and authored.target_domain != DefinitionScript.TargetDomain.SETTLEMENT_CELL:
			return {"ok": false, "reason": "family_effect_neighbor_domain_invalid"}
		if authored.target_selector_kind in [
				DefinitionScript.TargetSelectorKind.STATIC_HANDLE,
				DefinitionScript.TargetSelectorKind.SELECTOR_ID] \
				and String(authored.target_selector_id).strip_edges().is_empty():
			return {"ok": false, "reason": "family_effect_target_selector_missing"}
		if authored.target_selector_kind == DefinitionScript.TargetSelectorKind.STATIC_HANDLE:
			var static_handle := String(authored.target_selector_id).strip_edges()
			if not static_handle.is_valid_int() or int(static_handle) <= 0:
				return {"ok": false, "reason": "family_effect_static_handle_invalid"}
		if authored.target_selector_kind == DefinitionScript.TargetSelectorKind.SELECTOR_ID \
				and authored.target_domain != DefinitionScript.TargetDomain.BUILDING_RESOURCE:
			return {"ok": false, "reason": "family_effect_selector_domain_invalid"}
		if not authored.trigger_definition_keys_by_tier.is_empty() \
				and authored.trigger_definition_keys_by_tier.size() != 6:
			return {"ok": false, "reason": "family_effect_trigger_tier_shape_invalid"}
		if not authored.magnitude_by_prestige_q16.is_empty() \
				and authored.magnitude_by_prestige_q16.size() != 6:
			return {"ok": false, "reason": "family_effect_prestige_magnitude_shape_invalid"}
		for magnitude in authored.magnitude_by_prestige_q16:
			if int(magnitude) < 0 or int(magnitude) > 65536 * 4:
				return {"ok": false, "reason": "family_effect_prestige_magnitude_invalid"}
		var expected_modifier_domain := 1 if authored.target_domain == DefinitionScript.TargetDomain.COUNTRY \
			else (0 if authored.target_domain == DefinitionScript.TargetDomain.CLIMATE else 2)
		var has_event_command := false
		var command_contracts: Array = []
		for command in authored.commands:
			if command == null:
				return {"ok": false, "reason": "family_effect_command_invalid"}
			if int(command.target_resolver) != 1:
				return {"ok": false, "reason": "family_effect_command_target_resolver_invalid"}
			if authored.operation == DefinitionScript.Operation.EVENT_COMMAND:
				if int(command.action) == 1:
					return {"ok": false, "reason": "family_effect_event_modifier_invalid"}
				has_event_command = true
			elif int(command.action) != 1 or int(command.opcode) != 1 \
					or int(command.domain) != expected_modifier_domain \
					or String(command.definition_key).strip_edges().is_empty():
				return {"ok": false, "reason": "family_effect_target_adapter_mismatch"}
			if authored.operation != DefinitionScript.Operation.EVENT_COMMAND \
					and (int(command.stacks) != 1 or
						int(command.duration_days) != authored.duration_days):
				return {"ok": false, "reason": "family_effect_command_lifecycle_mismatch"}
			command_contracts.append([int(command.action), int(command.domain),
				int(command.opcode), int(command.target_resolver), int(command.static_target),
				int(command.duration_days), int(command.stacks)])
		if authored.operation == DefinitionScript.Operation.EVENT_COMMAND and not has_event_command:
			return {"ok": false, "reason": "family_effect_event_command_missing"}
		if authored.stack_policy in [DefinitionScript.StackPolicy.MAX,
				DefinitionScript.StackPolicy.MIN] and authored.commands.size() != 1:
			return {"ok": false, "reason": "family_effect_extreme_command_count_invalid"}
		var resolved_stack_key := String(authored.stack_key).strip_edges()
		if resolved_stack_key.is_empty():
			resolved_stack_key = "family.effect.%s" % key
		var stack_contract := [authored.target_domain, authored.operation,
			authored.lifecycle, authored.duration_days, authored.stack_policy,
			authored.max_stacks, authored.target_selector_kind,
			String(authored.target_selector_id), command_contracts]
		if stack_contracts.has(resolved_stack_key) \
				and stack_contracts[resolved_stack_key] != stack_contract:
			return {"ok": false, "reason": "family_effect_stack_contract_mismatch"}
		stack_contracts[resolved_stack_key] = stack_contract
		var prerequisite_keys: Array[String] = []
		for technology in authored.prerequisite_technology_keys:
			prerequisite_keys.append(String(technology).strip_edges())
		prerequisite_keys.sort()
		var prerequisite_seen := {}
		for technology_key in prerequisite_keys:
			if technology_key.is_empty() or prerequisite_seen.has(technology_key):
				return {"ok": false, "reason": "family_effect_technology_prerequisite_duplicate"}
			prerequisite_seen[technology_key] = true
			if not technology_ids.is_empty() and not technology_index.has(technology_key):
				return {"ok": false, "reason": "family_effect_technology_prerequisite_unknown"}
			if technology_index.has(technology_key):
				prerequisite_technology_indices.append(int(technology_index[technology_key]))
		prerequisite_offsets.append(prerequisite_technology_indices.size())
		technology_match_any.append(1 if authored.prerequisite_technology_any else 0)
		seen[key] = true
		var definition: Resource = authored.to_effect_definition()
		if definition.instructions.is_empty() and definition.commands.is_empty():
			return {"ok": false, "reason": "family_effect_program_empty"}
		definitions.append(definition)
		keys.append("family.effect.%s" % key)
		source_kinds.append(authored.source_kind)
		target_domains.append(authored.target_domain)
		operations.append(authored.operation)
		lifecycles.append(authored.lifecycle)
		duration_days.append(authored.duration_days)
		stack_policies.append(authored.stack_policy)
		stack_keys.append(resolved_stack_key)
		max_stacks.append(authored.max_stacks)
		priorities.append(authored.priority)
		selector_kinds.append(authored.target_selector_kind)
		selector_ids.append(String(authored.target_selector_id))
		weights.append(authored.weight)
		random_pool_eligible.append(1 if authored.random_pool_eligible else 0)
		var prestige := PackedInt32Array(authored.magnitude_by_prestige_q16)
		if prestige.is_empty():
			prestige = PackedInt32Array([65536, 65536, 65536, 65536, 65536, 65536])
		for tier in range(6):
			magnitude_by_prestige.append(int(prestige[tier]))
		var authored_triggers: PackedStringArray = authored.trigger_definition_keys_by_tier
		for tier in range(6):
			if tier < authored_triggers.size():
				trigger_definition_keys_by_tier.append(String(authored_triggers[tier]).strip_edges())
			else:
				trigger_definition_keys_by_tier.append("")
		trigger_reward_targets.append(int(authored.trigger_reward_target))
	var key_index := {}
	for effect_index in range(keys.size()):
		key_index[String(keys[effect_index])] = effect_index
		var short_key := String(keys[effect_index])
		if short_key.begins_with("family.effect."):
			key_index[short_key.substr("family.effect.".length())] = effect_index
	for authored in ordered:
		var self_key := "family.effect.%s" % String(authored.key).strip_edges()
		var seen_exclusion := {}
		for exclusion in authored.exclusion_keys:
			var exclusion_key := String(exclusion).strip_edges()
			if exclusion_key.is_empty() or seen_exclusion.has(exclusion_key):
				return {"ok": false, "reason": "family_effect_exclusion_invalid"}
			seen_exclusion[exclusion_key] = true
			if not key_index.has(exclusion_key):
				return {"ok": false, "reason": "family_effect_exclusion_unknown"}
			var resolved := int(key_index[exclusion_key])
			if String(keys[resolved]) == self_key:
				return {"ok": false, "reason": "family_effect_exclusion_self"}
			exclusions.append(resolved)
		exclusion_offsets.append(exclusions.size())
	var canonical := [version, keys, source_kinds, target_domains, operations,
		lifecycles, duration_days, stack_policies, stack_keys, max_stacks,
		priorities, selector_kinds, selector_ids,
		weights, random_pool_eligible, prerequisite_offsets,
		prerequisite_technology_indices, technology_match_any, exclusion_offsets, exclusions,
		magnitude_by_prestige, trigger_definition_keys_by_tier,
		trigger_reward_targets]
	var hash_value := hash(canonical)
	if hash_value == 0: hash_value = 1
	return {"ok": true, "definitions": definitions,
		"family_effect_catalog_version": version,
		"family_effect_catalog_hash": hash_value,
		"family_effect_keys": keys,
		"family_effect_source_kinds": source_kinds,
		"family_effect_target_domains": target_domains,
		"family_effect_operations": operations,
		"family_effect_lifecycles": lifecycles,
		"family_effect_duration_days": duration_days,
		"family_effect_stack_policies": stack_policies,
		"family_effect_stack_keys": stack_keys,
		"family_effect_max_stacks": max_stacks,
		"family_effect_priorities": priorities,
		"family_effect_target_selector_kinds": selector_kinds,
		"family_effect_target_selector_ids": selector_ids,
		"family_effect_weights": weights,
		"family_effect_random_pool_eligible": random_pool_eligible,
		"family_effect_prerequisite_offsets": prerequisite_offsets,
		"family_effect_prerequisite_technology_indices": prerequisite_technology_indices,
		"family_effect_technology_match_any": technology_match_any,
		"family_effect_exclusion_offsets": exclusion_offsets,
		"family_effect_exclusions": exclusions,
		"family_effect_magnitude_by_prestige_q16": magnitude_by_prestige,
		"family_effect_trigger_definition_keys_by_tier": trigger_definition_keys_by_tier,
		"family_effect_trigger_reward_targets": trigger_reward_targets}

## Cross-catalog checks run after Economy and Modifier have compiled their
## stable IDs. Keeping this separate avoids a compile-time dependency cycle:
## Economy includes the FamilyEffect semantic hash, while EffectDomain owns
## the final adapter binding validation.
func validate_domain_bindings(economy_columns: Dictionary,
		modifier_columns: Dictionary) -> Dictionary:
	if not bool(economy_columns.get("ok", false)) \
			or not bool(modifier_columns.get("ok", false)):
		return {"ok": false, "reason": "family_effect_domain_catalog_unavailable"}
	var building_selectors := {}
	for stable_id in economy_columns.get("building_type_ids", PackedStringArray()):
		building_selectors[String(stable_id)] = true
	var resource_selectors := {}
	for column in ["resource_ids", "building_resource_ids"]:
		for stable_id in economy_columns.get(column, PackedStringArray()):
			resource_selectors[String(stable_id)] = true
	var good_selectors := {}
	for stable_id in economy_columns.get("good_ids", PackedStringArray()):
		good_selectors[String(stable_id)] = true
	var definition_ids := {}
	var definition_keys: PackedStringArray = modifier_columns.get(
		"definition_keys", PackedStringArray())
	for index in range(definition_keys.size()):
		definition_ids[String(definition_keys[index])] = index
	var definition_domains: PackedInt32Array = modifier_columns.get(
		"definition_domains", PackedInt32Array())
	var definition_policies: PackedInt32Array = modifier_columns.get(
		"definition_policies", PackedInt32Array())
	var definition_max_stacks: PackedInt32Array = modifier_columns.get(
		"definition_max_stacks", PackedInt32Array())
	var term_offsets: PackedInt32Array = modifier_columns.get(
		"definition_term_offsets", PackedInt32Array())
	var stat_keys: PackedStringArray = modifier_columns.get(
		"stat_keys", PackedStringArray())
	var term_stat_ids: PackedInt32Array = modifier_columns.get(
		"term_stat_ids", PackedInt32Array())
	var term_operations: PackedInt32Array = modifier_columns.get(
		"term_operations", PackedInt32Array())
	if definition_domains.size() != definition_keys.size() \
			or definition_policies.size() != definition_keys.size() \
			or definition_max_stacks.size() != definition_keys.size() \
			or term_offsets.size() != definition_keys.size() + 1 \
			or term_stat_ids.size() != term_operations.size():
		return {"ok": false, "reason": "family_effect_modifier_catalog_shape_invalid"}
	var ordered: Array[Resource] = effects.duplicate()
	ordered.sort_custom(func(a, b) -> bool: return String(a.key) < String(b.key))
	for authored in ordered:
		var selector_id := String(authored.target_selector_id)
		if authored.target_selector_kind == DefinitionScript.TargetSelectorKind.SELECTOR_ID:
			if not building_selectors.has(selector_id) \
					and not resource_selectors.has(selector_id) \
					and not good_selectors.has(selector_id):
				return {"ok": false, "reason": "family_effect_target_selector_unknown"}
		if authored.operation == DefinitionScript.Operation.EVENT_COMMAND:
			continue
		var expected_domain := 1 if authored.target_domain == DefinitionScript.TargetDomain.COUNTRY \
			else (0 if authored.target_domain == DefinitionScript.TargetDomain.CLIMATE else 2)
		for command in authored.commands:
			var definition_key := String(command.definition_key)
			if not definition_ids.has(definition_key):
				return {"ok": false, "reason": "family_effect_modifier_definition_unknown"}
			var definition_index := int(definition_ids[definition_key])
			# Effect updates carry an exact source identity and stack count. The
			# Modifier row must replace that source in place; INDEPENDENT and
			# STACK_REFRESH would duplicate a reconciliation update.
			if int(definition_domains[definition_index]) != expected_domain \
					or int(definition_policies[definition_index]) != 1 \
					or int(definition_max_stacks[definition_index]) < authored.max_stacks:
				return {"ok": false, "reason": "family_effect_modifier_contract_mismatch"}
			for term_index in range(term_offsets[definition_index],
					term_offsets[definition_index + 1]):
				var stat_id := int(term_stat_ids[term_index])
				if stat_id < 0 or stat_id >= stat_keys.size():
					return {"ok": false, "reason": "family_effect_modifier_stat_invalid"}
				if authored.target_selector_kind == DefinitionScript.TargetSelectorKind.SELECTOR_ID:
					var stat_key := String(stat_keys[stat_id])
					var selector_matches := \
						(good_selectors.has(selector_id) and stat_key ==
							"economy.city.good.%s.output_factor" % selector_id) \
						or (building_selectors.has(selector_id) and stat_key ==
							"economy.city.building.%s.output_factor" % selector_id) \
						or (resource_selectors.has(selector_id) and stat_key ==
							"economy.city.resource.%s.regen_factor" % selector_id)
					if not selector_matches:
						return {"ok": false,
							"reason": "family_effect_selector_modifier_stat_mismatch"}
				var term_operation := int(term_operations[term_index])
				if authored.operation == DefinitionScript.Operation.ADD \
						and term_operation not in [0, 1]:
					return {"ok": false, "reason": "family_effect_add_term_mismatch"}
				if authored.operation == DefinitionScript.Operation.MULTIPLY \
						and term_operation not in [2, 3]:
					return {"ok": false, "reason": "family_effect_multiply_term_mismatch"}
	return {"ok": true}
