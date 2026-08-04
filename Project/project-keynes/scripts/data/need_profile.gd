class_name NeedProfile
extends Resource

## Stable use/need identity. Tags are cold-path metadata; native behavior is
## entirely defined by compiled consumption plans.
@export var id: StringName = &""
@export var display_name: String = ""
@export var use_tags: PackedStringArray = PackedStringArray()
## Optional cold-path labels shared by configurable family selectors.
@export var semantic_tags: PackedStringArray = PackedStringArray()
## Q16 share of this need's reference basket counted toward living cost.
## Essential needs use 65536, partial consumer needs may use an intermediate
## value, and discretionary/luxury needs use 0.
@export_range(0, 65536, 1) var living_cost_weight_q16: int = 0

## Composite satisfaction tier. Drives which satisfaction dimension this need
## contributes to (0 subsistence, 1 basic, 2 comfort, 3 luxury). The value maps
## directly onto the native SAT_DIM_SUBSISTENCE..SAT_DIM_LUXURY enum, so a need
## may never be authored outside this range.
@export_enum("subsistence", "basic", "comfort", "luxury")
var satisfaction_tier: int = 1
## Q16 weight of this need inside its tier average. Needs a class cares about
## more strongly use a larger weight; 0 excludes the need from the tier without
## removing it from consumption.
@export_range(0, 65536, 1) var satisfaction_weight_q16: int = 65536
