# good_profile.gd
# Data-driven definition of one tradable/storable good type.
#
# Goods are economy storage units, not naturally spawned terrain resources.
# They intentionally use the `goods` namespace to avoid Godot Material clashes.

class_name GoodProfile
extends Resource

@export var id: StringName = &""
@export var display_name: String = ""
@export var icon: Texture2D = null

# DataCore component names for per-cell quantity and price F32 slots.
@export var quantity_component: StringName = &""
@export var price_component: StringName = &""

@export var default_price: float = 1.0
