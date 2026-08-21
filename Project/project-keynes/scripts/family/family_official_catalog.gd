class_name FamilyOfficialCatalog
extends RefCounted

const JSON_PATH := "res://data/economy/family_official_buffs.json"
const TraitCatalogScript = preload("res://scripts/family/family_trait_catalog.gd")
const TraitDefinitionScript = preload("res://scripts/family/family_trait_definition.gd")
const BehaviorScript = preload("res://scripts/family/family_behavior_preference.gd")
const EffectCatalogScript = preload("res://scripts/family/family_effect_catalog.gd")
const EffectDefinitionScript = preload("res://scripts/family/family_effect_definition.gd")
const EffectCommandScript = preload("res://scripts/effect/effect_command.gd")
const EffectInstructionScript = preload("res://scripts/effect/effect_instruction.gd")
const EffectConditionScript = preload("res://scripts/effect/effect_condition.gd")

static func load_document() -> Dictionary:
	if not FileAccess.file_exists(JSON_PATH):
		return {}
	var file := FileAccess.open(JSON_PATH, FileAccess.READ)
	if file == null:
		return {}
	var parsed: Variant = JSON.parse_string(file.get_as_text())
	return parsed if parsed is Dictionary else {}


static func hydrate_trait_catalog(catalog: Resource) -> Resource:
	if catalog == null or not catalog is TraitCatalogScript:
		return catalog
	var document := load_document()
	var rows: Array = document.get("traits", [])
	if rows.is_empty():
		return catalog
	catalog.version = int(document.get("version", catalog.version))
	catalog.core_trait_min = int(document.get("core_trait_min", catalog.core_trait_min))
	catalog.core_trait_max = int(document.get("core_trait_max", catalog.core_trait_max))
	var traits: Array[Resource] = []
	for row in rows:
		if not row is Dictionary:
			continue
		traits.append(_trait_from_row(row))
	catalog.traits = traits
	return catalog


static func hydrate_effect_catalog(catalog: Resource) -> Resource:
	if catalog == null or not catalog is EffectCatalogScript:
		return catalog
	var document := load_document()
	var rows: Array = document.get("effects", [])
	if rows.is_empty():
		return catalog
	catalog.version = int(document.get("version", catalog.version))
	var effects: Array[Resource] = []
	for row in rows:
		if not row is Dictionary:
			continue
		effects.append(_effect_from_row(row))
	catalog.effects = effects
	return catalog


static func _trait_from_row(row: Dictionary) -> Resource:
	var definition: Resource = TraitDefinitionScript.new()
	definition.key = StringName(String(row.get("key", "")))
	definition.display_name = String(row.get("display_name", ""))
	definition.description = String(row.get("description", ""))
	definition.description_template = String(row.get("description_template", ""))
	definition.range_text = String(row.get("range_text", ""))
	definition.weight = int(row.get("weight", 1))
	definition.core_eligible = bool(row.get("core_eligible", true))
	definition.prerequisite_technology_keys = _string_array(
		row.get("prerequisite_technology_keys", []))
	definition.prerequisite_technology_any = bool(
		row.get("prerequisite_technology_any", false))
	definition.exclusion_keys = _string_array(row.get("exclusion_keys", []))
	definition.strength_min_q16 = int(row.get("strength_min_q16", 49152))
	definition.strength_max_q16 = int(row.get("strength_max_q16", 81920))
	definition.strength_step_q16 = int(row.get("strength_step_q16", 4096))
	definition.origin_landforms = _byte_array(row.get("origin_landforms", []))
	definition.origin_adjacent_water = bool(row.get("origin_adjacent_water", false))
	definition.origin_population_max = int(row.get("origin_population_max", 0))
	definition.origin_temperature_max_q16 = int(
		row.get("origin_temperature_max_q16", -1))
	definition.required_resource_ids = _string_array(
		row.get("required_resource_ids", []))
	definition.require_tax_or_subsidy = bool(row.get("require_tax_or_subsidy", false))
	var behaviors: Array[Resource] = []
	for behavior_row in row.get("behaviors", []):
		if not behavior_row is Dictionary:
			continue
		var preference: Resource = BehaviorScript.new()
		preference.axis = int(behavior_row.get("axis", 0))
		preference.selector_kind = int(behavior_row.get("selector_kind", 0))
		preference.selector_id = StringName(String(behavior_row.get("selector_id", "")))
		preference.factor_q16 = int(behavior_row.get("factor_q16", 65536))
		preference.score_term = int(behavior_row.get("score_term", 0))
		var conditions: Array[Resource] = []
		for condition_row in behavior_row.get("conditions", []):
			if not condition_row is Dictionary:
				continue
			conditions.append(_condition_from_row(condition_row))
		preference.conditions = conditions
		behaviors.append(preference)
	definition.behaviors = behaviors
	return definition


static func _effect_from_row(row: Dictionary) -> Resource:
	var definition: Resource = EffectDefinitionScript.new()
	definition.key = StringName(String(row.get("key", "")))
	definition.display_name = String(row.get("display_name", ""))
	definition.description = String(row.get("description", ""))
	definition.prestige_descriptions = _string_array(
		row.get("prestige_descriptions", []))
	definition.weight = int(row.get("weight", 1))
	definition.random_pool_eligible = bool(row.get("random_pool_eligible",
		int(row.get("source_kind", 1)) == 1))
	definition.prerequisite_technology_keys = _string_array(
		row.get("prerequisite_technology_keys", []))
	definition.prerequisite_technology_any = bool(
		row.get("prerequisite_technology_any", false))
	definition.source_kind = int(row.get("source_kind", 1))
	definition.target_domain = int(row.get("target_domain", 2))
	definition.operation = int(row.get("operation", 1))
	definition.lifecycle = int(row.get("lifecycle", 0))
	definition.duration_days = int(row.get("duration_days", -1))
	definition.stack_policy = int(row.get("stack_policy", 0))
	definition.max_stacks = int(row.get("max_stacks", 1))
	definition.target_selector_kind = int(row.get("target_selector_kind", 2))
	definition.target_selector_id = StringName(String(row.get("target_selector_id", "")))
	definition.exclusion_keys = _string_array(row.get("exclusion_keys", []))
	definition.magnitude_by_prestige_q16 = _int32_array(
		row.get("magnitude_by_prestige_q16", []))
	definition.trigger_definition_keys_by_tier = _string_array(
		row.get("trigger_definition_keys_by_tier", []))
	definition.trigger_reward_target = int(row.get("trigger_reward_target", 0))
	definition.cadence_days = int(row.get("cadence_days", 1))
	var conditions: Array[Resource] = []
	for condition_row in row.get("conditions", []):
		if condition_row is Dictionary:
			conditions.append(_condition_from_row(condition_row))
	definition.conditions = conditions
	var instructions: Array[Resource] = []
	for instruction_row in row.get("instructions", []):
		if not instruction_row is Dictionary:
			continue
		var instruction: Resource = EffectInstructionScript.new()
		instruction.op = int(instruction_row.get("op", 12))
		instruction.arg0 = int(instruction_row.get("arg0", 0))
		instruction.value_q16 = int(instruction_row.get("value_q16", 0))
		instructions.append(instruction)
	definition.instructions = instructions
	var commands: Array[Resource] = []
	for command_row in row.get("commands", []):
		if not command_row is Dictionary:
			continue
		var command: Resource = EffectCommandScript.new()
		command.action = int(command_row.get("action", 1))
		command.domain = int(command_row.get("domain", 2))
		command.opcode = int(command_row.get("opcode", 1))
		command.target_resolver = int(command_row.get("target_resolver", 1))
		command.value_mode = int(command_row.get("value_mode", 1))
		command.value_q16 = int(command_row.get("value_q16", 0))
		command.duration_days = int(command_row.get("duration_days",
			definition.duration_days))
		command.stacks = int(command_row.get("stacks", 1))
		var command_key := String(command_row.get("command_key", "")).strip_edges()
		var definition_key := String(command_row.get("definition_key", "")).strip_edges()
		if command_key.is_empty():
			command_key = definition_key
		command.command_key = StringName(command_key)
		command.definition_key = StringName(definition_key)
		command.payload_i0 = int(command_row.get("payload_i0", 0))
		command.payload_i1 = int(command_row.get("payload_i1", 0))
		command.payload_i2 = int(command_row.get("payload_i2", 0))
		command.payload_i3 = int(command_row.get("payload_i3", 0))
		commands.append(command)
	definition.commands = commands
	return definition


static func _condition_from_row(row: Dictionary) -> Resource:
	var condition: Resource = EffectConditionScript.new()
	condition.op = int(row.get("op", 1))
	condition.arg0 = int(row.get("arg0", 0))
	condition.value_q16 = int(row.get("value_q16", 0))
	return condition


static func _string_array(value: Variant) -> PackedStringArray:
	var out := PackedStringArray()
	if value is PackedStringArray:
		return value
	if value is Array:
		for item in value:
			out.append(String(item))
	return out


static func _int32_array(value: Variant) -> PackedInt32Array:
	var out := PackedInt32Array()
	if value is PackedInt32Array:
		return value
	if value is Array:
		for item in value:
			out.append(int(item))
	return out


static func _byte_array(value: Variant) -> PackedByteArray:
	var out := PackedByteArray()
	if value is PackedByteArray:
		return value
	if value is Array:
		for item in value:
			out.append(int(item) & 0xff)
	return out
