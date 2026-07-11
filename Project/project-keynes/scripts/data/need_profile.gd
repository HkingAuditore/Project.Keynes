class_name NeedProfile
extends Resource

## Stable use/need identity. Tags are cold-path metadata; native behavior is
## entirely defined by compiled consumption plans.
@export var id: StringName = &""
@export var display_name: String = ""
@export var use_tags: PackedStringArray = PackedStringArray()
