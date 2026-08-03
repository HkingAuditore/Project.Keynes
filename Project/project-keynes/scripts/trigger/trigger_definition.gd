class_name TriggerDefinition
extends Resource

@export var key: StringName = &""
@export var version: int = 1
@export var source_id: int = 0
@export var event_type: int = 0
@export var payload_schema: int = 0
@export var aggregator: int = 1
@export var value_field: int = 0
@export var distinct_field: int = 1
@export var scope: int = 0
@export var target_resolver: int = 0
@export var static_target: int = 0
@export var threshold: int = 1
@export var mode: int = 1
@export var cooldown_days: int = 0
@export var window_days: int = 0
@export var enabled: bool = true
@export var dynamic_binding: bool = false
## Optional exact-match selector evaluated before aggregation. -1 disables it.
@export_range(-1, 7, 1) var selector_field: int = -1
## Stable keys compile through String.hash() into the signed 32-bit event ABI.
@export var selector_key: StringName = &""
@export var selector_value: int = 0
@export var selector_negated: bool = false
@export var condition_ops: PackedInt32Array = PackedInt32Array([1])
@export var effects: Array[Resource] = []
