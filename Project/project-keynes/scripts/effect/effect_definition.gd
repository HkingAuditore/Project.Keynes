class_name EffectDefinition
extends Resource

@export var key: StringName = &""
@export var version: int = 1
@export_range(1, 3650, 1) var cadence_days: int = 1
@export_range(1, 1000000, 1) var max_work: int = 1024
@export var enabled: bool = true
@export var behavior_id: StringName = &""
@export var conditions: Array[Resource] = []
@export var instructions: Array[Resource] = []
@export var commands: Array[Resource] = []

## Optional declarative metadata. Existing technology/trigger/person
## definitions keep the neutral defaults; family effects use these columns to
## declare ownership, target domain and lifecycle without adding a script
## callback to the native evaluation loop.
@export var source_kind: int = 0
@export var target_domain: int = 0
@export var operation: int = 0
@export var lifecycle: int = 0
@export var duration_days: int = -1
@export var stack_policy: int = 0
@export var stack_key: StringName = &""
@export_range(1, 65536, 1) var max_stacks: int = 1
@export var priority: int = 0
@export var target_selector_kind: int = 0
@export var target_selector_id: StringName = &""
