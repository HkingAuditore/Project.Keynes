class_name ConsumptionPlanProfile
extends Resource

## Market V2 compiles needs -> substitute variants -> complement components.
## Offsets are CSR boundaries and all stable IDs are resolved at bootstrap.
@export var id: StringName = &""
@export var display_name: String = ""
@export var need_ids: PackedStringArray = PackedStringArray()
@export var priorities: PackedInt32Array = PackedInt32Array()
@export var base_qty_per_person: PackedInt64Array = PackedInt64Array()
@export var wealth_elasticity_q16: PackedInt32Array = PackedInt32Array()
@export var wealth_min_q16: PackedInt32Array = PackedInt32Array()
@export var wealth_max_q16: PackedInt32Array = PackedInt32Array()
## Variant elasticity chooses among substitutes. These columns separately scale
## the total need when every available substitute is expensive. The floor keeps
## necessities inelastic without making them immune to price and household wealth.
@export var price_quantity_elasticity_q16: PackedInt32Array = PackedInt32Array()
@export var price_quantity_floor_q16: PackedInt32Array = PackedInt32Array()
@export var quantity_env_curve_ids: PackedStringArray = PackedStringArray()
@export var need_variant_offsets: PackedInt32Array = PackedInt32Array([0])

@export var variant_ids: PackedStringArray = PackedStringArray()
@export var variant_preference_q16: PackedInt32Array = PackedInt32Array()
@export var variant_price_elasticity_q16: PackedInt32Array = PackedInt32Array()
@export var variant_preference_env_curve_ids: PackedStringArray = PackedStringArray()
@export var variant_component_offsets: PackedInt32Array = PackedInt32Array([0])

@export var component_good_ids: PackedStringArray = PackedStringArray()
@export var component_qty_per_need: PackedInt64Array = PackedInt64Array()
