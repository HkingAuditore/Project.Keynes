class_name IdeologyProfile
extends Resource

@export_range(0, 64, 1) var ideology_capacity: int = 6
@export_range(0, 64, 1) var national_spirit_capacity: int = 3
## Base row count of a draw offer. The native array tops out at 5 and
## `country.ideology.offer_choice_bonus` supplies the difference, so this stays
## the floor a catalog authors rather than the only allowed value.
@export_range(1, 5, 1) var offer_choice_count: int = 3
@export_range(0, 2147483647, 1) var offer_cost_q16: int = 65536
@export_range(0, 2147483647, 1) var starting_points_q16: int = 0
@export_range(1, 1000000, 1) var max_commands_per_slice: int = 4096
@export_range(1, 4096, 1) var max_transition_commands: int = 256
## CATALOG DECLARATION BUDGET, not a concurrency budget.
##
## Counted once per card effect row routed through a declared
## `ideology.effect.*` program, over the WHOLE catalog: card x level x row.
## 85 cards x 3 levels = 255 covered the pre-v0.2 pool; the redesign targets 179
## cards, and two rows per level is already 1074, so 512 was too tight and is
## being retired in favour of 2048.
##
## Live per-country concurrency is a different number: it is
## (ideology_capacity + national_spirit_capacity) x SELECTOR_MAX_CELLS
## = 9 x 32 = 288 instances, separately capped by EffectRuntime's `max_instances`
## (4096). Per-cell fan-out is meant to be aggregated by cell, never sized as
## "one instance per (card, cell)" off this field.
@export_range(0, 8192, 1) var max_effect_instances: int = 2048
## CONCURRENCY BUDGET. The other half of the pair above, and a different
## quantity: how many Effect instances can be live at the same time in one
## country, which is what `EffectRuntime::_max_instances` actually refuses past.
##
## The compiler derives the worst case itself rather than trusting an estimate:
## it sums each card's widest level (every program row at that level times that
## program's target cap), takes the widest card, and multiplies by the number of
## slots that can hold one -- (ideology_capacity_max + national_spirit_capacity_max),
## i.e. the grown capacities, because a save that unlocked both is the state the
## budget has to survive.
##
## Kept >= 2048 rather than the 288 the current 9 x 32 numbers suggest: a slot
## count is not the only multiplicand once per-cell fan-out exists, and a budget
## that trips on a legitimate catalog is worse than a loose one. The point of the
## field is that the check names the number instead of silently relying on
## EffectRuntime's 4096 default.
@export_range(1, 16000000, 1) var max_concurrent_instances: int = 4096
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
## Optional ceiling per covered day. Zero disables the ceiling, not point income.
@export_range(0, 2147483647, 1) var point_gain_cap_q16: int = 0
@export var point_gain_stat_key: StringName = &"country.ideology.point_gain_factor"
## X6-a: per-term point multipliers. Empty means 1.0 for that term.
@export var point_population_factor_stat_key: StringName = &"country.ideology.point_population_factor"
@export var point_building_factor_stat_key: StringName = &"country.ideology.point_building_factor"
@export var point_trade_factor_stat_key: StringName = &"country.ideology.point_trade_factor"
## social_media: floor under the opinion factor. Empty means 0.5. This is an
## ADD-only point stat, so a card lowers it with a negative point offset.
@export var opinion_factor_floor_stat_key: StringName = &"country.ideology.opinion_factor_floor"
## Global per-school strength multipliers. The catalog also carries the school
## order and stat keys natively; these profile fields are the authoring surface
## for the same contract, so content and runtime resolve one table.
@export var school_strength_factor_stat_keys: PackedStringArray = PackedStringArray([
	"country.ideology.school_strength_factor.agrarian",
	"country.ideology.school_strength_factor.commerce",
	"country.ideology.school_strength_factor.learning",
	"country.ideology.school_strength_factor.mobilization",
	"country.ideology.school_strength_factor.industry",
	"country.ideology.school_strength_factor.harmony",
])
## Multiplies each level's static `daily_understanding_q16`. Empty = 1.0.
##
## Understanding accrual used to be the one number a card could not reach: it
## read the level row and nothing else, so "读书" cards had no lever at all.
## A country-wide factor is the coarsest useful lever and the cheapest to keep
## in sync between the main thread and the worker POD.
@export var understanding_gain_stat_key: StringName = &"country.ideology.understanding_gain_factor"
## Multiplies `reroll_cost_percent` for the country doing the reroll. Empty = 1.0.
##
## Applied to the reroll share only, never to the base offer cost: a card that
## makes rerolls cheaper must not also make the first draw cheaper, or it turns
## into a blanket discount on the whole draw economy.
@export var reroll_cost_stat_key: StringName = &"country.ideology.reroll_cost_factor"
## Floor under `era_decay_bp`, in basis points, read per country. Empty = 0.
##
## The table above ends in 0, and `draw_offer` only falls back to raw rarity
## weight when the WHOLE pool decays out. So one live new card is enough to
## retire every old one permanently. This is the lever a 史馆-type card pulls:
## 2500 keeps old ideas at a quarter weight instead of zero, without touching the
## global curve that every other card's retirement depends on.
@export var era_decay_floor_stat_key: StringName = &"country.ideology.era_decay_floor_bp"
## Extra rows in the draw offer, read per country and clamped to
## `OFFER_CHOICE_CAPACITY - OFFER_CHOICE_BASE` (2). Empty = 0.
##
## Additive on purpose: a multiplier here would have to be applied to 3, and
## "×1.33" is a worse thing to author than "+1 row".
@export var offer_choice_bonus_stat_key: StringName = &"country.ideology.offer_choice_bonus"
## 精进: weight of an owned-but-not-maxed card when it is offered again, on the
## same x10000 scale as rarity weight. 0 disables the mechanic, which keeps the
## pre-L4-11 behaviour for any catalog that predates it.
@export_range(0, 10000, 1) var refine_weight_bp: int = 4000
## Understanding granted when a 精进 row is picked, in Q16. 4.0 is about one
## level on the shipped curve, which is what the design note asks for.
@export_range(0, 1073741824, 1) var refine_understanding_q16: int = 262144
## Draw-weight decay indexed by (current_era - idea.era_index). Index 0 is the
## card's own era (10000 = full weight); the last entry is reused for anything
## older. 0 removes the card from the draw pool entirely, so the default table
## gives one to two eras of grace and retires the card in the third.
@export var era_decay_bp: PackedInt32Array = PackedInt32Array([10000, 6000, 2500, 0])
