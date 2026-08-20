class_name FamilyTraitDefinition
extends Resource

@export var key: StringName = &""
@export var version: int = 1
@export var display_name: String = ""
@export_multiline var description: String = ""
@export_range(1, 1000000, 1) var weight: int = 1
@export var core_eligible: bool = true
@export var prerequisite_keys: PackedStringArray = PackedStringArray()
@export var prerequisite_technology_keys: PackedStringArray = PackedStringArray()
@export var exclusion_keys: PackedStringArray = PackedStringArray()
@export_range(0, 262144, 1) var strength_min_q16: int = 49152
@export_range(0, 262144, 1) var strength_max_q16: int = 81920
@export_range(1, 65536, 1) var strength_step_q16: int = 4096
@export var behaviors: Array[Resource] = []
@export var modifiers: Array[Resource] = []
@export var triggers: Array[Resource] = []
## Stable authoring IDs compiled into the shared Native Effect Runtime.
@export var effect_keys: PackedStringArray = PackedStringArray()
