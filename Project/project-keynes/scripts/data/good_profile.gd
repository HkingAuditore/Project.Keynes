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

# Native MarketStore fixed-point parameters. No per-cell component/schema
# reference is allowed: adding a good is a data-resource-only operation.
@export var default_price: int = 10000
@export var initial_stock: int = 0
@export var min_price: int = 1
@export var max_price: int = 100000000
@export var price_adjust_q16: int = 2048

## Market V2 demand and next-day price formation. All values are Q16 except
## target_inventory_days_q16, which is also Q16 days.
@export var demand_price_elasticity_q16: int = 65536
@export var demand_ema_alpha_q16: int = 16384
@export var target_inventory_days_q16: int = 196608
@export var inventory_weight_q16: int = 32768
@export var shortage_weight_q16: int = 65536
@export var max_price_rise_q16: int = 8192
@export var max_price_fall_q16: int = 4096

## Producer output is purchased by local merchants at retail price multiplied
## by this factor. 62259 is deterministic Q16 for the default 95% price.
@export_range(0, 65536, 1) var merchant_buy_price_factor_q16: int = 62259
