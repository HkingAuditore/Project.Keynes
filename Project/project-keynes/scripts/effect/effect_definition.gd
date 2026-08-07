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
