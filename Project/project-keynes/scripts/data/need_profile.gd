class_name NeedProfile
extends Resource

## Stable use/need identity. Tags are cold-path metadata; native behavior is
## entirely defined by compiled consumption plans.
@export var id: StringName = &""
@export var display_name: String = ""
@export var use_tags: PackedStringArray = PackedStringArray()
## Q16 share of this need's reference basket counted toward living cost.
## Essential needs use 65536, partial consumer needs may use an intermediate
## value, and discretionary/luxury needs use 0.
@export_range(0, 65536, 1) var living_cost_weight_q16: int = 0
