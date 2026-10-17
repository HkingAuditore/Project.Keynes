class_name IdeologyProfile
extends Resource

@export_range(0, 64, 1) var ideology_capacity: int = 6
@export_range(0, 64, 1) var national_spirit_capacity: int = 3
@export_range(3, 3, 1) var offer_choice_count: int = 3
@export_range(0, 2147483647, 1) var offer_cost_q16: int = 65536
@export_range(0, 2147483647, 1) var starting_points_q16: int = 0
@export_range(1, 1000000, 1) var max_commands_per_slice: int = 4096
@export_range(1, 4096, 1) var max_transition_commands: int = 256
@export_range(1, 1000000, 1) var max_transition_polls_per_slice: int = 4096
@export_range(1, 1000000, 1) var max_active_visits_per_slice: int = 1024
@export_range(0, 64, 1) var opinion_owner_influence_weight: int = 2
@export_range(1, 2147483647, 1) var opinion_funds_per_influence: int = 1000000
## Slot growth: capacity starts at ideology_capacity/national_spirit_capacity and
## grows by the deltas below once the paired technology is owned.
@export_range(0, 64, 1) var ideology_capacity_max: int = 6
@export_range(0, 64, 1) var national_spirit_capacity_max: int = 3
@export var capacity_unlock_technology_keys: PackedStringArray = PackedStringArray()
@export var capacity_unlock_ideology_deltas: PackedInt32Array = PackedInt32Array()
@export var capacity_unlock_spirit_deltas: PackedInt32Array = PackedInt32Array()
## Every draw is paid; the next draw costs growth_percent of the previous one:
## cost(n) = round(offer_cost_q16 * (growth_percent / 100)^n), capped by offer_cost_max_q16.
@export_range(100, 400, 1) var offer_cost_growth_percent: int = 100
@export_range(0, 2147483647, 1) var offer_cost_max_q16: int = 0
@export_range(0, 1000, 1) var reroll_cost_percent: int = 50
## Increment-only point accrual weights (Q16 points per unit).
@export_range(0, 2147483647, 1) var point_population_weight_q16: int = 0
@export_range(0, 2147483647, 1) var point_building_weight_q16: int = 0
@export_range(0, 2147483647, 1) var point_trade_weight_q16: int = 0
@export_range(0, 2147483647, 1) var point_gain_cap_q16: int = 0
@export var point_gain_stat_key: StringName = &"country.ideology.point_gain_factor"
