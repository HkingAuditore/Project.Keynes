class_name EthnicityProfile
extends Resource

@export var id: StringName = &""
@export var display_name: String = ""
@export var icon: Texture2D = null
@export var culture_group_id: StringName = &"default"

## Optional signature modifiers. Q16_ONE means unchanged.
@export var birth_rate_factor_q16: int = 65536
@export var death_rate_factor_q16: int = 65536

## Sparse Market V2 quantity modifiers. Missing needs use Q16_ONE.
@export var need_modifier_ids: PackedStringArray = PackedStringArray()
@export var need_quantity_factors_q16: PackedInt32Array = PackedInt32Array()
