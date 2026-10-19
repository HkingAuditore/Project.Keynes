class_name IdeologyEffectDefinition
extends Resource

## Authoring-only ideology effect program. Compiled into a shared
## EffectDefinition whose key is "ideology.effect.<definition_key>", so the card
## arena can reference the program by the definition_key it already stores.
##
## Unlike a flat ModifierDefinition this carries conditions, a target selector
## and a lifecycle, which is what turns "a card gives +4%" into
## "[condition] -> {target cells} -> {result}" and lets one card's result become
## another card's condition.

const Q16_ONE := 65536

enum TargetDomain {
	SETTLEMENT_CELL = 2,
	COUNTRY = 3,
	CLIMATE = 4,
	BUILDING_RESOURCE = 5,
}

enum Operation {
	ADD = 0,
	MULTIPLY = 1,
	OVERRIDE = 2,
	CONDITIONAL_OVERRIDE = 3,
	EVENT_COMMAND = 4,
}

enum Lifecycle {
	PERMANENT = 0,
	DURATION = 1,
	EVENT_ONCE = 2,
}

enum StackPolicy {
	REPLACE = 0,
	REFRESH = 1,
	ADD_STACK = 2,
	MAX = 3,
	MIN = 4,
}

enum TargetSelectorKind {
	OWNER = 0,
	SOURCE_CELL = 2,
	SOURCE_COUNTRY = 3,
	STATIC_HANDLE = 4,
	SELECTOR_ID = 5,
	NEIGHBORS_R1 = 6,
	NEIGHBORS_R2 = 7,
	## Connected component of cells sharing the anchor's terrain.
	SAME_TERRAIN_COMPONENT = 8,
	## Connected component of cells whose dominant extracted good matches.
	SAME_RESOURCE_COMPONENT = 9,
	## Whole-map scan filtered by a runtime predicate id.
	PREDICATE_ANY_CELL = 10,
	## Every cell within `param[0]` hex steps of the anchor.
	DISTANCE_N = 11,
}

## Hard cap mirrored from EffectRuntime::SELECTOR_MAX_CELLS.
const SELECTOR_MAX_CELLS := 32

## Matches an IdeologyCatalog card-effect `definition_key`.
@export var definition_key: StringName = &""
@export var target_domain: int = TargetDomain.COUNTRY
@export var operation: int = Operation.ADD
@export var lifecycle: int = Lifecycle.PERMANENT
@export var duration_days: int = -1
@export var stack_policy: int = StackPolicy.REPLACE
@export var stack_key: StringName = &""
@export_range(1, 256, 1) var max_stacks: int = 1
@export var priority: int = 0
@export var target_selector_kind: int = TargetSelectorKind.OWNER
@export var target_selector_id: StringName = &""
## [0] = cell cap (0 = runtime default, hard cap 32), [1] = terrain id /
## resource id / predicate id, depending on the selector.
@export var target_selector_param: PackedInt32Array = PackedInt32Array([0, 0])
@export_range(1, 3650, 1) var cadence_days: int = 1
@export var conditions: Array[Resource] = []
@export var instructions: Array[Resource] = []
@export var commands: Array[Resource] = []


func program_key() -> StringName:
	if definition_key == &"":
		return &""
	return StringName("ideology.effect.%s" % String(definition_key))


func to_effect_definition() -> Resource:
	var out: Resource = load("res://scripts/effect/effect_definition.gd").new()
	out.key = program_key()
	out.version = 1
	out.cadence_days = cadence_days if cadence_days > 0 else 1
	out.max_work = 128
	out.enabled = true
	out.conditions = conditions.duplicate()
	out.instructions = instructions.duplicate()
	out.commands = commands.duplicate()
	out.source_kind = 0
	out.target_domain = target_domain
	out.operation = operation
	out.lifecycle = lifecycle
	out.duration_days = duration_days
	out.stack_policy = stack_policy
	out.stack_key = stack_key
	out.max_stacks = max_stacks
	out.priority = priority
	out.target_selector_kind = target_selector_kind
	out.target_selector_id = target_selector_id
	out.target_selector_param = PackedInt32Array([
		int(target_selector_param[0]) if target_selector_param.size() > 0 else 0,
		int(target_selector_param[1]) if target_selector_param.size() > 1 else 0,
	])
	out.managed = true
	return out


func validate() -> String:
	if definition_key == &"" or program_key() == &"":
		return "ideology_effect_definition_key_missing"
	if target_domain not in [
			TargetDomain.SETTLEMENT_CELL, TargetDomain.COUNTRY,
			TargetDomain.CLIMATE, TargetDomain.BUILDING_RESOURCE]:
		return "ideology_effect_target_domain_invalid"
	if operation < 0 or operation > 4:
		return "ideology_effect_operation_invalid"
	if lifecycle < 0 or lifecycle > 2:
		return "ideology_effect_lifecycle_invalid"
	if lifecycle == Lifecycle.DURATION and duration_days < 1:
		return "ideology_effect_duration_invalid"
	if lifecycle != Lifecycle.DURATION and duration_days == 0:
		return "ideology_effect_duration_invalid"
	if stack_policy < 0 or stack_policy > 4:
		return "ideology_effect_stack_policy_invalid"
	if max_stacks < 1 or max_stacks > 256:
		return "ideology_effect_max_stacks_invalid"
	if target_selector_kind < 0 or target_selector_kind > TargetSelectorKind.DISTANCE_N:
		return "ideology_effect_selector_invalid"
	if target_selector_param.size() > 0 \
			and (int(target_selector_param[0]) < 0 \
			or int(target_selector_param[0]) > SELECTOR_MAX_CELLS):
		return "ideology_effect_selector_cap_invalid"
	if instructions.is_empty():
		return "ideology_effect_program_missing"
	if commands.is_empty():
		return "ideology_effect_commands_missing"
	return ""
