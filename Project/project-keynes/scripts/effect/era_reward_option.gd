class_name EraRewardOption
extends Resource

@export var stable_id: StringName
@export var title: String
@export_multiline var description: String
@export var icon_id: StringName
@export_range(1, 1000000, 1) var base_weight: int = 100
@export var fallback: bool = false
@export var eligibility_code: int = 0
@export var eligibility_threshold: int = 0
@export var weight_rules: Array[Resource] = []
@export var commands: Array[Resource] = []
