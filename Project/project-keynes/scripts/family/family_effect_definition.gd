class_name FamilyEffectDefinition
extends Resource

## Authoring-only family effect resource. It is compiled into the shared
## EffectDefinition IR before the world starts; native code never evaluates
## this Resource directly.
enum SourceKind {
	TRAIT = 0,
	RANDOM_POOL = 1,
	EVENT = 2,
	PLAYER_COMMAND = 3,
	TECHNOLOGY = 4,
	COUNTRY_STATE = 5,
}

enum TargetDomain {
	FAMILY = 0,
	BRANCH = 1,
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
	SOURCE_BRANCH = 1,
	SOURCE_CELL = 2,
	SOURCE_COUNTRY = 3,
	STATIC_HANDLE = 4,
	SELECTOR_ID = 5,
	NEIGHBORS_R1 = 6,
	NEIGHBORS_R2 = 7,
}

@export var key: StringName = &""
@export var version: int = 1
@export var display_name: String = ""
@export_multiline var description: String = ""
@export var prestige_descriptions: PackedStringArray = PackedStringArray()
@export_range(1, 1000000, 1) var weight: int = 1
@export var random_pool_eligible: bool = false
@export var prerequisite_technology_keys: PackedStringArray = PackedStringArray()
@export var prerequisite_technology_any: bool = false
@export var source_kind: int = SourceKind.TRAIT
@export var target_domain: int = TargetDomain.FAMILY
@export var operation: int = Operation.ADD
@export var lifecycle: int = Lifecycle.PERMANENT
@export var duration_days: int = -1
@export var stack_policy: int = StackPolicy.REPLACE
@export var stack_key: StringName = &""
@export_range(1, 65536, 1) var max_stacks: int = 1
@export var priority: int = 0
@export var target_selector_kind: int = TargetSelectorKind.OWNER
@export var target_selector_id: StringName = &""
@export var exclusion_keys: PackedStringArray = PackedStringArray()
@export var magnitude_by_prestige_q16: PackedInt32Array = PackedInt32Array()
@export var conditions: Array[Resource] = []
@export var instructions: Array[Resource] = []
@export var commands: Array[Resource] = []
@export var trigger_definition_keys_by_tier: PackedStringArray = PackedStringArray()
@export var trigger_reward_target: int = 0
@export var cadence_days: int = 1

func to_effect_definition() -> Resource:
	var definition: Resource = load("res://scripts/effect/effect_definition.gd").new()
	definition.key = StringName("family.effect.%s" % String(key).strip_edges())
	definition.version = version
	definition.cadence_days = cadence_days if cadence_days > 0 else 1
	definition.max_work = 128
	definition.enabled = true
	definition.conditions = conditions.duplicate()
	definition.instructions = instructions.duplicate()
	definition.commands = commands.duplicate()
	definition.source_kind = source_kind
	definition.target_domain = target_domain
	definition.operation = operation
	definition.lifecycle = lifecycle
	definition.duration_days = duration_days
	definition.stack_policy = stack_policy
	definition.stack_key = stack_key
	definition.max_stacks = max_stacks
	definition.priority = priority
	definition.target_selector_kind = target_selector_kind
	definition.target_selector_id = target_selector_id
	definition.magnitude_by_prestige_q16 = magnitude_by_prestige_q16.duplicate()
	return definition


func program_key() -> String:
	var raw := String(key).strip_edges()
	if raw.is_empty() or raw.begins_with("family.effect."):
		return raw
	return "family.effect.%s" % raw
