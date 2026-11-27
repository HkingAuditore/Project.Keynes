# Stable dense order of built-in technology and military stats.
extends RefCounted

const TECHNOLOGY_STATS := [
	["country.research.agriculture_efficiency", 0.0, 6.0],
	["country.research.engineering_efficiency", 0.0, 6.0],
	["country.research.science_efficiency", 0.0, 6.0],
	["country.research.society_efficiency", 0.0, 6.0],
	["country.research.cost_factor", 0.65, 4.0],
	["country.research.institution_output_factor", 0.0, 8.0],
	["country.output.agriculture_factor", 0.0, 8.0],
	["country.output.extractive_factor", 0.0, 8.0],
	["country.output.manufacturing_factor", 0.0, 8.0],
	["country.output.energy_factor", 0.0, 8.0],
	["country.output.knowledge_factor", 0.0, 8.0],
	["country.production.input_factor", 0.80, 4.0],
	["country.household.consumption_factor", 0.40, 4.0],
	["country.resource.use_factor", 0.40, 4.0],
	["country.population.death_factor", 0.3333, 4.0],
	["country.construction.cost_factor", 0.40, 4.0],
	["country.construction.time_factor", 0.40, 4.0],
	["country.trade.capacity_factor", 0.0, 8.0],
	["country.trade.speed_factor", 0.0, 8.0],
	["country.climate.drought_loss_factor", 0.20, 1.0],
	["country.climate.flood_loss_factor", 0.20, 1.0],
	["country.climate.cold_stress_factor", 0.20, 1.0],
	["country.climate.heat_stress_factor", 0.20, 1.0],
	# Frozen by the Country epoch snapshot; ideology accrual reads it read-only.
	["country.ideology.point_gain_factor", 0.0, 4.0],
	# Same freeze path, different consumption points. Appended rather than
	# grouped with the line above so the dense stat ids of everything already
	# declared do not move: ids are assigned in this order at every compile, and
	# a shipped save's modifier rows are keyed by definition, not by stat id, but
	# keeping the existing ids stable makes any diff of a compiled catalog readable.
	["country.ideology.understanding_gain_factor", 0.0, 4.0],
	["country.ideology.reroll_cost_factor", 0.0, 4.0],
	# X6-a: per-term point multipliers. Same epoch freeze path as point_gain,
	# but each applies to exactly one ledger term and clamps to [0.5, 3.0].
	["country.ideology.point_population_factor", 0.5, 3.0],
	["country.ideology.point_building_factor", 0.5, 3.0],
	["country.ideology.point_trade_factor", 0.5, 3.0],
	# social_media: base floor under the opinion factor. ADD-only, so the card's
	# -0.1 is a point offset instead of a multiplier on 0.5.
	["country.ideology.opinion_factor_floor", 0.3, 0.5],
	# Global school-strength multipliers frozen into the Ideology POD. One
	# explicit stat per school keeps Modifier POD buckets keyed by stat id
	# instead of introducing a sub-key dimension no consumer reads today.
	["country.ideology.school_strength_factor.agrarian", 0.5, 2.0],
	["country.ideology.school_strength_factor.commerce", 0.5, 2.0],
	["country.ideology.school_strength_factor.learning", 0.5, 2.0],
	["country.ideology.school_strength_factor.mobilization", 0.5, 2.0],
	["country.ideology.school_strength_factor.industry", 0.5, 2.0],
	["country.ideology.school_strength_factor.harmony", 0.5, 2.0],
	# Draw-side, and the only two ideology stats that are ADDITIVE rather than
	# multiplicative. `era_decay_floor_bp` is a floor under the era decay curve
	# (0 = no floor, 10000 = no decay at all); `offer_choice_bonus` adds rows to
	# the draw offer (0..2, because the native array caps at 5). Both read 0 when
	# absent, which is why they are ranged from 0 rather than from 1.
	["country.ideology.era_decay_floor_bp", 0.0, 10000.0],
	["country.ideology.offer_choice_bonus", 0.0, 2.0],
	# Military (docs/plans/military-system-design.md §16.1). Appended last on
	# purpose: every dense stat id already shipped in the loading snapshots and
	# in saves must keep its position.
	["country.military.attack_factor", 0.0, 4.0],
	["country.military.defense_factor", 0.0, 4.0],
	["country.military.speed_factor", 0.0, 4.0],
	["country.military.logistics_move_factor", 0.0, 4.0],
	["country.military.supply_transport_factor", 0.0, 8.0],
	["country.military.supply_consumption_factor", 0.0, 4.0],
	["country.military.barracks_capacity_factor", 0.0, 4.0],
	["country.military.levy_rate", 0.0, 4.0],
	["country.military.wage_factor", 0.0, 4.0],
	["country.military.training_time_factor", 0.1, 4.0],
	["country.military.desertion_factor", 0.0, 4.0],
	["country.military.casualty_factor", 0.0, 4.0],
	["country.military.attrition_factor", 0.0, 4.0],
	["country.military.organization_recovery_factor", 0.0, 4.0],
	["country.military.morale_add", -1.0, 1.0],
	["country.military.fortification_factor", 0.0, 4.0],
	["country.military.frontage_factor", 0.0, 4.0],
	["country.military.militia_factor", 0.5, 4.0],
	["country.military.occupation_tax_efficiency", 0.0, 4.0],
	["country.military.naval_transport_factor", 0.0, 8.0],
	["country.military.vision_add", -64.0, 64.0],
	["country.military.convoy_escort_factor", 0.25, 8.0],
	# Rule parameters (§17.2 channel B). ADD-only; 0 means the rule is inactive.
	["country.military.rule.mutual_support", 0.0, 4.0],
	["country.military.rule.last_stand", 0.0, 4.0],
	["country.military.rule.blitz", 0.0, 4.0],
	["country.military.rule.hold_the_line", 0.0, 4.0],
	["country.military.rule.encirclement", 0.0, 4.0],
	["country.military.rule.home_ground", 0.0, 4.0],
	# Per-good trade factors (tech tree stage 4, "A 组"). Same clamp envelope and
	# the same two consumption points as `country.trade.{capacity,speed}_factor`
	# above, but keyed by good so a card can say "this good trades more/faster".
	#
	# Appended at the tail for the usual reason: every dense stat id already
	# shipped must keep its position. These ten keys are registered here and
	# ONLY here -- the authored `default_modifier_catalog.tres` deliberately does
	# not repeat them, because the resource catalog compiles first and a second
	# definition would both shift every id after it and turn this row into a
	# dead duplicate (see the skip in modifier_catalog.gd's TECHNOLOGY_STATS
	# loop). Key spelling is the frozen CSV's: `country.trade.good.<good>.<dim>_factor`.
	["country.trade.good.wool.capacity_factor", 0.0, 8.0],
	["country.trade.good.wool.speed_factor", 0.0, 8.0],
	["country.trade.good.horses.capacity_factor", 0.0, 8.0],
	["country.trade.good.horses.speed_factor", 0.0, 8.0],
	["country.trade.good.spices.capacity_factor", 0.0, 8.0],
	["country.trade.good.spices.speed_factor", 0.0, 8.0],
	["country.trade.good.iron_ore.capacity_factor", 0.0, 8.0],
	["country.trade.good.salt.speed_factor", 0.0, 8.0],
	["country.trade.good.cloth.capacity_factor", 0.0, 8.0],
	["country.trade.good.glassware.capacity_factor", 0.0, 8.0],
]

## Cell-level military stats (design §16.1 DerivedCellFront, `group_handle = cell`).
##
## These are ECONOMY-domain stats so a card writes them through the SAME derived
## cell layer the land cards use: the program's target selector picks cells and
## the Modifier row lands on `(stat, cell)`. Military reads them back per cell
## (`get_military_cell_stat_q16`), rather than each consumer growing its own
## table.
##
## Range note: these are FACTORS, and the channel-A cards author "+X%" on them,
## so the ceiling is the same 4.0 the country-level factors use rather than 0..1
## -- a 0..1 clamp would silently swallow any card above +100%, which is exactly
## the "validates and then does nothing" failure the modifier skill forbids.
const MILITARY_CELL_STATS := [
	["military.cell.attack_factor", 0.0, 4.0],
	["military.cell.defense_factor", 0.0, 4.0],
	["military.cell.organization_recovery_factor", 0.0, 4.0],
	["military.cell.supply_consumption_factor", 0.0, 4.0],
	["military.cell.barracks_capacity_factor", 0.0, 4.0],
	["military.cell.training_speed_factor", 0.0, 4.0],
]
