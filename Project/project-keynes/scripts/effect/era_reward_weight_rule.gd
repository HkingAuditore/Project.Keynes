class_name EraRewardWeightRule
extends Resource

@export var condition_code: int = 0
@export var threshold: int = 0
@export_range(1, 262144, 1) var multiplier_q16: int = 65536
@export var reason: String = ""
@export var signal_id: StringName
@export var route_tag_prefix: StringName
