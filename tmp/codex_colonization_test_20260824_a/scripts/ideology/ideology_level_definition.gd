class_name IdeologyLevelDefinition
extends Resource

## All progression numbers are Q16 before they reach the native runtime.
@export_range(0, 2147483647, 1) var understanding_threshold_q16: int = 0
@export_range(0, 2147483647, 1) var daily_understanding_q16: int = 0
@export var persistent_effects: Array[Resource] = []
@export var on_enter_effects: Array[Resource] = []
