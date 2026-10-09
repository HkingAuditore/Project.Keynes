class_name ModifierDefinition
extends Resource

@export var key: StringName
@export var version: int = 1
@export var display_name: String = ""
@export_multiline var description: String = ""
@export_enum("Climate", "Country", "Economy", "Gameplay") var domain: int = 0
@export_enum("Independent", "UniqueSource", "StackRefresh") var stack_policy: int = 0
@export_range(1, 1024, 1) var max_stacks: int = 1
@export var default_duration_days: int = -1
@export var terms: Array[Resource] = []
