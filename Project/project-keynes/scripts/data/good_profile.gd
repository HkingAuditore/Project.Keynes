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
## Backward-compatible primary production-substitution role. This is not an
## industry or UI taxonomy; new content should also populate the multi-role
## substitution_category_ids below.
@export var category_id: StringName = &"misc"
## A good may fulfil several recipe roles. A building input_category_id selects
## exactly one role, so membership does not imply universal interchangeability.
## Exact inputs and explicit candidate lists remain available for narrower or
## efficiency-weighted recipe choices. Household substitution remains defined
## by NeedProfile variants.
@export var substitution_category_ids: PackedStringArray = PackedStringArray()
@export var technology_tags: PackedStringArray = PackedStringArray()
## Production recipes may accept a category instead of one exact good. The
## quality gate rejects obsolete substitutes; efficiency converts physical
## quantity into effective recipe quantity (Q16, 65536 = 100%).
@export_range(0, 1000, 1) var production_quality_level: int = 0
@export_range(1, 262144, 1) var production_efficiency_q16: int = 65536
@export_enum("stock", "cycle_flow") var storage_mode: String = "stock"
## Stock goods participate in domestic arbitrage by default. cycle_flow goods
## are always forced off by the native catalog compiler.
@export var trade_enabled: bool = true
## Q16 transport work required by one complete GOODS_SCALE unit per route-cost point.
@export_range(1, 2147483647, 1) var transport_load_per_unit_q16: int = 65536

## Money subunits issued per complete GOODS_SCALE unit when a merchant accepts
## producer output. Only gold and silver may configure a positive value.
@export_range(0, 1000000000000, 1) var monetary_issue_value: int = 0

# Native MarketStore fixed-point parameters. No per-cell component/schema
# reference is allowed: adding a good is a data-resource-only operation.
@export var default_price: int = 10000
@export var initial_stock: int = 0
@export var min_price: int = 1
@export var max_price: int = 100000000
@export var price_adjust_q16: int = 2048

## Market V2 demand and next-day price formation. Inventory targets multiply
## EconomyProfile's baseline days by this per-good Q16 ratio.
@export var demand_price_elasticity_q16: int = 65536
@export var demand_ema_alpha_q16: int = 16384
@export_range(0, 262144, 1) var inventory_target_ratio_q16: int = 65536
@export var inventory_weight_q16: int = 32768
@export var shortage_weight_q16: int = 65536
@export var excess_demand_weight_q16: int = 8192
@export var cost_anchor_weight_q16: int = 16384
@export var inactive_reversion_weight_q16: int = 8192
@export var business_demand_ema_alpha_q16: int = 8192
@export var supply_ema_alpha_q16: int = 8192
@export var cost_ema_alpha_q16: int = 4096
@export var max_price_rise_q16: int = 8192
@export var max_price_fall_q16: int = 4096

## Producer output is purchased by local merchants at retail price multiplied
## by this factor. 62259 is deterministic Q16 for the default 95% price.
@export_range(0, 65536, 1) var merchant_buy_price_factor_q16: int = 62259
