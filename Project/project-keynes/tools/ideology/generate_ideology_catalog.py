"""Generate the default ideology catalog and its Modifier definitions.

Authoritative content table for the era-gated / 6-school ideology pool. Running
this script rewrites:
  * data/ideologies/default_ideology_catalog.tres (fully generated)
  * the ideology section of data/modifiers/default_modifier_catalog.tres
    (every sub_resource whose id starts with TermIdeology/DefIdeology)

Card grammar
------------
Every card is `[condition] -> {object} -> {result + cost}`, mirroring the family
effect grammar:

  * condition  hard draw gate. Two kinds are emitted, both already native:
                 - TECHNOLOGY      the era's entry milestone (see ERA_MILESTONE_TECH)
                 - RESEARCH_SIGNAL a discovered geography fact (resource.* /
                                   bio.* / landform.* / weather.* / contact.*)
               A card whose geography is absent is simply not drawable, which is
               how "ideas must match the map the player actually has" is enforced.
  * object     a real, consumed stat dimension: one terrain/landform x sector,
               one good's output/input/consumption, one natural resource's
               extraction or managed regrowth, one production climate profile's
               hazard loss, one profession's income tax, one building type, or a
               whole country sector.
  * result     modifier terms, scaled by understanding level (1.0x / 1.6x / 2.2x).
  * cost       every card carries at least one term that is worse than 1.0. A
               card with no cost is a bug: it makes the pool a flat power curve.

Every stat key this file can emit must appear in DEAD_STAT_KEYS (never) or in the
synthesised whitelist that validate_cards() builds from the live catalogs. That
check exists because `country.construction.time_factor` was previously emitted on
10 cards even though 375 of 400 buildings have `construction_days = 0` and finish
the same day, so the stat was dead on arrival.

Usage (from Project/project-keynes): python tools/ideology/generate_ideology_catalog.py
"""
from __future__ import annotations

import json
import os
import pathlib
import re
from dataclasses import dataclass

ROOT = pathlib.Path(__file__).resolve().parents[2]
IDEOLOGY_PATH = ROOT / "data/ideologies/default_ideology_catalog.tres"
EFFECTS_PATH = ROOT / "data/ideologies/default_ideology_effects.tres"
MODIFIER_PATH = ROOT / "data/modifiers/default_modifier_catalog.tres"
NETWORK_PATH = ROOT / "data/technology/technology_network.json"
SIGNAL_CATALOG_PATH = ROOT / "scripts/research/research_signal_catalog.gd"
MODIFIER_CATALOG_PATH = ROOT / "scripts/modifier/modifier_catalog.gd"
EFFECT_DOMAIN_CATALOG_PATH = ROOT / "scripts/effect/effect_domain_catalog.gd"
EFFECT_CATALOG_PATH = ROOT / "scripts/effect/effect_catalog.gd"


def pod_max_selector_kind() -> int:
    """`effect_catalog.gd`'s POD_MAX_SELECTOR_KIND -- the highest kind POD accepts.

    The generator must not write a selector the POD layer rejects: the card would
    parse in the .tres and then fail to compile, taking the whole catalog down.
    Reading the constant instead of hardcoding it means the ceiling moves the day
    R raises it.
    """
    text = EFFECT_CATALOG_PATH.read_text(encoding="utf-8")
    match = re.search(r"const POD_MAX_SELECTOR_KIND\s*:=\s*(\d+)", text)
    if not match:
        raise SystemExit(
            f"cannot find POD_MAX_SELECTOR_KIND in {EFFECT_CATALOG_PATH}")
    return int(match.group(1))
TARGET_TAG_DICTIONARY_PATH = ROOT / "scripts/effect/target_tag_dictionary.gd"
TERRAIN_PATH = ROOT / "scripts/geography/terrain_type.gd"
LANDFORM_PATH = ROOT / "scripts/geography/landform_type.gd"
BUILDINGS_DIR = ROOT / "data/economy/buildings"
GOODS_DIR = ROOT / "data/goods"
PROFESSIONS_DIR = ROOT / "data/economy/professions"
PRODUCTION_CLIMATES_DIR = ROOT / "data/economy/production_climates"
NEEDS_DIR = ROOT / "data/economy/needs"

Q16 = 65536
LEVEL_THRESHOLDS = [0, 262144, 786432]          # 0 / 4.0 / 12.0 understanding
LEVEL_DAILY = [8192, 4096, 0]                   # 0.125 / 0.0625 / 0 per day
LEVEL_MAGNITUDES = [65536, 104858, 144179]      # 1.0x / 1.6x / 2.2x
LEVEL_TITLES = ["初识", "通晓", "化育"]           # presentation only

# The nine cards the reachability matrix marks 可直接做 (`08-next-phase-plan.md`
# §3.5 C0). Listed in one place because several lints are scoped to "content this
# round authored" rather than to the whole pre-existing catalog.
C0_CARDS = frozenset({
    "terrace_farming", "water_works", "pit_dwelling", "hydroelectric",
    "forager_band", "riverside_camp", "seasonal_calendar", "land_tax_reform",
    "excise",
})

# ── capability gate (`requires=`) ───────────────────────────────────────────
# What the RUNTIME can actually do today, named with the same codenames Doc 02 §2
# and `audit_card_reachability.py` use, so all three can never disagree.
#
# A card that needs something outside this set is still validated in full (a typo
# must fail now, not when the capability lands) but is NOT written into the
# catalog: shipping it would put a card in the draw pool that silently does
# nothing, which is the exact failure mode §47 is about.
#
# Add a name here only when the C++ side is merged AND a test exercises it.
AVAILABLE_CAPABILITIES = frozenset({
    # Selector kinds 6..16 (OWN_TERRITORY / TAG_ANY_CELL / TAG_SOURCE_R1/R2 /
    # TAG_SOURCE_COUNT), the per-cell Effect instance path, tag predicates, metric
    # conditions, synergy magnitude overrides.
    "X1",
    # X1-b: selector kind 16 counts own-country tagged sources per target cell.
    # Step 6 releases every authored kind-16 card through `X1B_RELEASE`.
    "X1b",
    # Neighbour population column (metric 54). Doc 02: X2 partial.
    "X2",
    # Dominant profession id / share / count (metrics 51..53). Doc 02: X3 partial.
    "X3",
    # X3-b: per-cell profession-group population shares (metrics 96..98) and
    # committed worker-class satisfaction (metric 99).
    "X3b",
    # Per-country tag counts and per-good counts (metrics 56..67). Doc 02: X7 partial.
    "X7",
    # National mean income-tax burden (metric 55). Doc 02: X11 partial.
    "X11",
    # Pity / refine / ban / route tilt. Doc 02: X15 supported.
    "X15",
    # R-4: per-profession tax tolerance / satisfaction bias stats (47.3).
    # `economy.profession.<pid>.tax_tolerance_factor` (MULTIPLY, clamped 0.5..3.0)
    # and `.satisfaction_bp` (ADD, clamped -2500..2500). Frozen per epoch in
    # `capture_country_epoch`, read by `update_cohort_satisfaction`; the bias is
    # applied BEFORE the needs ceiling so it cannot make a starving city content.
    "X16",
    # R-4: `cell.net_tax_burden_q16` (47.9). Same arithmetic as the satisfaction
    # tax dimension, so a ramp on it moves the number the player feels.
    "metric68",
    # R-4: treasury reserve ratio = treasury cash / one year of national population
    # income, in 1% bands (47.4). Not a doc codename -- §47.4 redefined X11's
    # "国库比" into this, and several cards ramp on it, so it gets its own switch
    # name. v0 denominator is a 365-day extrapolation of the live income EMA.
    #
    # The METRIC ships (id 69, frozen in `capture_country_epoch`). R-7 authors the
    # country-scope carrier, but the switch stays OFF until
    # `ideology_country_ramp_worker_test` proves equip -> ramp -> unequip on the
    # worker path.
    "reserve_ratio",
    # X5: per-country selector/tag rewrites carried by hidden self-synergies.
    # The worker fixture proves equip -> rewritten selector -> unequip -> save/load.
    "X5",
    # X6-a: per-term point multipliers (population / building / trade), frozen
    # into the opinion snapshot at the country epoch.
    "X6a",
    # X6-c: slot-ordered copied programs. The worker fixture proves equip ->
    # copied managed activations -> source switch/unequip -> save/load.
    "X6c",
    # X6-b: free draws granted by on-enter card effects.
    "X6b",
    # X12: derived cell geography bits (metric 75) and same-country river/canal
    # component size (metric 76), plus the cell.river/coastal/canal/border tags.
    "X12",
    # X13a: annual temperature / dry streak / hazards and the climate tags.
    "X13a",
    # X14: committed country class opinion (metrics 77/78). Four political
    # classes exist, but the reserved range has two ids; 77 is the most-used
    # class and 78 is the country population-weighted value.
    "X14",
    # X9a: derived per-cell branch count / prestige / family asset share
    # (metrics 84..86) and the cell.clan / cell.eminent_clan tags.
    "X9a",
    # X9b: derived country family aggregates (metrics 90..93), rebuilt only
    # when the family/branch tables change.
    "X9b",
    # X10: derived country technology counts (metrics 79..83), frozen from the
    # Country economy snapshot and refreshed only when the bitset changes.
    "X10",
    # X8: generator-derived upstream-goods DNF tags feed the existing X1-b
    # kind-16 selector; metric 87 publishes distinct goods among neighbours.
    "X8",
    # X2 extension: per-cell count of neighbouring agriculture-pillar cells
    # (metric 94), used by terrace_farming's L3 condition.
    "metric94",
    # X1 plain: per-cell targeting with selectors that already ship. The shared
    # capability is on; release remains per card through X1_PLAIN_RELEASE.
    "X1_PLAIN_SWITCH",
    # NOT available, named so `requires=` can ask for them:
    #   X1b            per-source stacking + radius N (10-roadmap §4.2)
    #   X4 X6 X8 X9 X13
})

# Every capability name `requires=` may mention. A name outside this set is a
# typo and must fail, otherwise a misspelt requirement silently passes as
# "available" once someone adds the real capability.
#
# `X1_PLAIN_SWITCH` and `X1b` are SPLIT ON PURPOSE (C-d). Both mean "this card's
# per-cell rewrite", but they cost the engine very different things:
#
#   * `X1_PLAIN_SWITCH` -- per-cell targeting with selectors that ALREADY ship
#     (OWN_TERRITORY / TAG_ANY_CELL, kinds 12/13). No new C++ at all; those cards
#     are blocked only on deciding to release the authoring.
#   * `X1b` -- per-source COUNT stacking (kind 16). Needs R's C++ (09 §7).
#
# One shared switch would keep 16 cards that need nothing from the engine dark
# until the hardest piece lands.
X1_PLAIN_SWITCH = "X1_PLAIN_SWITCH"

# R-7 F: shared engine capability, per-card content release. A card absent here
# keeps its old national row; brand-new cards stay dark. PK_X1_FORCE_READY is a
# local candidate-generation hook and is never part of a committed release.
X1_PLAIN_RELEASE: frozenset[str] = frozenset({
    "agrarian_reform", "assembly_line", "automation_line", "carbon_market",
    "colonial_plantation", "financialization", "fire_keeping", "free_trade",
    "gene_editing", "heaven_human", "manufactory_regulation",
    "maritime_insurance", "nuclear_power", "ocean_company", "open_ports",
    "scholar_office",
    "arcology", "basic_income", "circular_economy", "department_store",
    "gig_economy", "offshore_drilling", "welfare_state",
})
_X1_FORCE_READY: frozenset[str] | None = None


def _x1_force_ready_cards() -> frozenset[str]:
    global _X1_FORCE_READY
    if _X1_FORCE_READY is not None:
        return _X1_FORCE_READY
    spec = os.environ.get("PK_X1_FORCE_READY", "").strip()
    if not spec:
        _X1_FORCE_READY = frozenset()
        return _X1_FORCE_READY
    authored = frozenset(X1_TARGETS) | frozenset(X1_NATIONAL_TERMS)
    if spec == "all":
        _X1_FORCE_READY = authored
        return _X1_FORCE_READY
    requested = frozenset(item.strip() for item in spec.split(",")
                          if item.strip())
    unknown = sorted(requested - authored)
    if unknown:
        raise SystemExit("PK_X1_FORCE_READY: unknown X1 card(s) "
                         + ", ".join(unknown))
    _X1_FORCE_READY = requested
    return _X1_FORCE_READY


def x1_card_ready_for_build(key: str) -> bool:
    if key in _x1_force_ready_cards():
        return True
    switch = x1_card_switch(key)
    if switch == X1_PLAIN_SWITCH and key not in X1_PLAIN_RELEASE:
        return False
    return x1_card_ready(key)


KNOWN_CAPABILITIES = AVAILABLE_CAPABILITIES | frozenset({
    X1_PLAIN_SWITCH, "X1b", "X16", "metric68", "reserve_ratio",
    "X4", "X5", "X6", "X6b", "X6c", "X8", "X9", "X9a", "X9b", "X10",
    "X13", "X14",
})

# card key -> capability names it needs. A card whose requirements are not all in
# `AVAILABLE_CAPABILITIES` is validated and then STAGED (held back from the
# catalog). `main()` prints the staged list with what each one waits for.
CARD_REQUIRES: dict[str, tuple[str, ...]] = {}

# Complete clauses that still need runtime support outside the capabilities
# above. This is a review aid, not a publish gate: the card's expressible rows
# keep shipping while the gap stays visible in the generator output.
NEEDS_RUNTIME: dict[str, str] = {
    "little_ice_age":
        "L3 8C cold threshold and doubled other cold-card effects",
    "air_conditioning":
        "cell heat-loss reduction and L3 hot-penalty immunity",
    "canal_corvee":
        "cell trade output has no reader; national canal trade stays omitted",
    "grand_canal":
        "continuous component-size ramp and L3 market-only sub-target need support",
    "irrigation_grid":
        "drought-loss reduction and radius-3 reach need runtime support",
    "shell_midden":
        "coast/lake split and adjacent same-fish output stacking need support",
    "cooperative":
        "neighbouring-cell agriculture +4% needs a metric-conditioned source/ring clause",
    "mechanized_farming":
        "inverse-baseline ramp (0.5 - farmer share) is not expressible by Ramp",
    "industrial_lab":
        "L3 radius-3 distance needs a radius-3 source selector",
}

# Cards that are mechanically incomplete enough that publishing their
# expressible subset would misrepresent the card. Unlike `NEEDS_RUNTIME`, this
# is a hard pool gate: the row is still validated, but none of its definitions
# or programs reach the generated catalogs. Remove an entry only after its
# missing mechanics land and an end-to-end card test covers them.
TEMPORARY_CARD_POOL_HOLDOUTS: dict[str, str] = {
    "little_ice_age":
        "missing cold-card doubling and the L3 8 C threshold",
    "air_conditioning":
        "missing cell heat-loss reduction and L3 hot-penalty immunity",
    "canal_corvee":
        "missing canal trade output and the national canal-trade clause",
    "grand_canal":
        "missing continuous size ramp and the L3 market-only sub-target",
    "irrigation_grid":
        "missing drought-loss reduction and radius-3 reach",
    "shell_midden":
        "missing coast/lake split and adjacent same-fish stacking",
    "cooperative":
        "missing the neighbourhood agriculture source/ring clause",
    "industrial_lab":
        "missing the L3 radius-3 source selector",
    "tax_farming":
        "missing market trade bonuses and the L3 adjacent-trade clause",
    "land_value":
        "missing metropolitan-ring agriculture and the L3 birth-rate clause",
    "light_levy":
        "missing metric-68 light-tax birth and agriculture clauses",
    "progressive_tax":
        "missing the metric-68 light-tax birth clause",
    "ancestral_hall":
        "missing surrounding branch-prestige growth",
    "clan_fields":
        "missing same-family building stacking and L3 prestige growth",
    "philanthropy":
        "missing high-cash family prestige growth",
    "merchant_houses":
        "family three-sector/market intersection is only approximated",
    "family_enterprise":
        "the single-sector clause is only approximated",
    "petition_box":
        "social research is authored as ADD 0.98, which is +98%",
    "tax_holiday":
        "all three benefit rows are empty",
    "mandate_of_heaven":
        "legacy worker failure has not been reproduced on the current binary",
    "sovereign_fund":
        "legacy worker failure has not been reproduced on the current binary",
}

# Design rows that are intentionally absent from CARDS: no exact runtime
# mechanic exists yet, so publishing a partial row would silently change the
# design. This is the skip audit for content-authoring lanes.
SKIPPED_DESIGN_CARDS: dict[str, str] = {
    "academic_disciplines":
        "dynamic argmin/argmax across completed-tech counts 80..83; "
        "condition DSL compares a metric only with a constant",
    "logistics_hub":
        "multi-tag source predicate (>=2 of market/canal/river/coastal) and "
        "per-source stacking over the union at radius 2",
    "watershed":
        "basin_id membership selector and per-basin water-infrastructure/canal "
        "count; L3 silt-layer cap stat is also absent",
    "national_park":
        "country count of tag intersection cell.abundant x "
        "(landform.mountain|landform.forest)",
    "planetary_survey":
        "country-scoped discovered landform.* research-signal count",
    "smart_grid":
        "country.energy_cell_count metric/slot",
    "weather_almanac":
        "country-scoped discovered weather.* research-signal count",
    "biotech":
        "country-scoped discovered bio.* research-signal count",
}

# X6-b: civil_examination is the card-tier free-draw fixture.
CARD_REQUIRES["civil_examination"] = ("X6b",)
CARD_REQUIRES["bronze_casting"] = ("X8",)

# Third slot of a term tuple: the operation it must be written with, and (for
# additive rows) whether it is a price. `ModifierRuntime::Operation`.
OP_MULTIPLY = 2
OP_ADD_DOWNSIDE = 0     # Add, and it is the card's price
OP_ADD_TRANSFER = 4     # Add, but neither buff nor price (see below)
RARITY_WEIGHTS = {1: 120, 2: 60, 3: 20}
ADOPT_THRESHOLD = {1: 4096, 2: 8192, 3: 12288}
PROMOTE_THRESHOLD = {1: 16384, 2: 20480, 3: 24576}
CLIMATE_HAZARDS = ["drought", "flood", "cold_stress", "heat_stress"]

# Class stance templates per school: class -> (adopt, repeal, promote).
SCHOOL_STANCES = {
    "agrarian": {"general": (16384, -8192, 16384), "farmer": (40960, -32768, 32768),
                 "technology": (-8192, 8192, 0)},
    "commerce": {"general": (16384, 0, 12288), "technology": (32768, -16384, 24576),
                 "farmer": (-16384, 16384, -8192)},
    "learning": {"general": (8192, 0, 12288), "technology": (49152, -32768, 40960)},
    "mobilization": {"general": (16384, -8192, 20480), "worker": (40960, -24576, 32768),
                     "farmer": (8192, 8192, 8192)},
    "industry": {"general": (8192, 0, 12288), "worker": (32768, -16384, 24576),
                 "farmer": (-16384, 16384, -8192)},
    "harmony": {"general": (16384, -8192, 16384), "farmer": (24576, -16384, 20480),
                "worker": (-8192, 8192, 0)},
}
# Critical-class floors per card: (card, class) -> {field: q16}. A class whose
# support falls below its floor vetoes the transition regardless of the total,
# so a few cards carry a hard political cost beyond their weighted stance.
CRITICAL_FLOORS = {
    ("free_exchange", "farmer"): {"adopt_min_support_q16": -8192},
    ("scholar_office", "technology"): {"promote_min_support_q16": 32768},
    ("labour_legislation", "worker"): {"adopt_min_support_q16": 0},
}
# The 动员 school is organised public action (public works, sanitation, schooling,
# labour law), not warfare: the project has no military simulation at all, so any
# war framing on a card is fiction. Its icon is the politics glyph accordingly.
SCHOOL_ICONS = {
    "agrarian": "economy.crop", "commerce": "economy.building.market",
    "learning": "metric.technology", "mobilization": "country.politics",
    "industry": "economy.building.factory", "harmony": "economy.resource",
}

# ── country-wide scalar stats ────────────────────────────────────────────────
AGRI = "country.output.agriculture_factor"
EXTR = "country.output.extractive_factor"
MANU = "country.output.manufacturing_factor"
ENER = "country.output.energy_factor"
KNOW = "country.output.knowledge_factor"
R_AGRI = "country.research.agriculture_efficiency"
R_ENG = "country.research.engineering_efficiency"
R_SCI = "country.research.science_efficiency"
R_SOC = "country.research.society_efficiency"
R_COST = "country.research.cost_factor"
R_INST = "country.research.institution_output_factor"
INPUT = "country.production.input_factor"
CONSUME = "country.household.consumption_factor"
RES_USE = "country.resource.use_factor"
DEATH = "country.population.death_factor"
B_COST = "country.construction.cost_factor"
T_CAP = "country.trade.capacity_factor"
T_SPEED = "country.trade.speed_factor"
# Hazard stat keys are inconsistent in the live catalog: drought and flood carry
# a `_loss_` infix, cold and heat do not. Keep them byte-exact; the lint rejects
# anything the modifier catalog does not declare.
DROUGHT = "country.climate.drought_loss_factor"
FLOOD = "country.climate.flood_loss_factor"
COLD = "country.climate.cold_stress_factor"
HEAT = "country.climate.heat_stress_factor"
POINTS = "country.ideology.point_gain_factor"
POINT_POPULATION = "country.ideology.point_population_factor"
POINT_BUILDING = "country.ideology.point_building_factor"
POINT_TRADE = "country.ideology.point_trade_factor"
OPINION_FLOOR = "country.ideology.opinion_factor_floor"
MANDATE_HARMONY = "country.ideology.school_strength_factor.harmony"

# Stats that resolve inside ModifierRuntime but nothing consumes. Emitting one
# silently does nothing, so the lint rejects them outright.
DEAD_STAT_KEYS = {
    # Only 25 of 400 buildings set construction_days; the other 375 complete the
    # same day, so a build-speed modifier has no effect on 94% of the build menu.
    # Build *cost* (country.construction.cost_factor) is live and stays in use.
    "country.construction.time_factor",
    # `economy.city.trade_output_factor` is declared in the modifier catalog but
    # has exactly zero readers: gdext reads city output through
    # `_building_output_stat_ids` (output + 5 sectors), good output through
    # `_city_good_output_stat_ids`, births/needs/resources through their own id
    # tables -- and trade nowhere. A card written on this key compiles, applies,
    # and changes nothing. Trade cards therefore stay national (capacity/speed)
    # until the cell-level trade path exists.
    "economy.city.trade_output_factor",
}

# ── cell-scoped modifier family (`ideology.city.*`) ──────────────────────────
# Cell-level ideology effects do not reuse `family.city.*`: those definitions are
# FAMILY-sourced and would collide with family traits in the same bucket. The
# family below is IDEO-sourced by construction (the Effect instance is the source
# id), domain 2, and every stat is one gdext actually reads per cell.
#
# Term shape: ADD with `value = 1.0`, so the *command magnitude* is the effect
# itself (+5% -> magnitude 0.05). One definition therefore serves every card and
# every level exactly, instead of forcing all cards to share one reference
# percentage. The `<key>.cut` twin is SUBTRACT, because magnitude is clamped to
# [0, 4] and can never carry a sign.
# Targets with NO per-cell reader in gdext today (census 2026-10-21: zero read
# sites for the stat id). A card aimed at one of these compiles, stores a
# Modifier row, and changes nothing visible. They are therefore NOT generated as
# card-targetable definitions; listing them here keeps the gap explicit instead
# of looking like an oversight. To use them, give them a reader first.
IDEOLOGY_CITY_DEAD_STATS = [
    ("output_factor", "economy.city.output_factor"),
    ("resource.regen_factor", "economy.city.resource.regen_factor"),
    ("resource.timber.regen_factor", "economy.city.resource.timber.regen_factor"),
    ("resource.pasture.regen_factor", "economy.city.resource.pasture.regen_factor"),
    ("resource.fertile_soil.regen_factor", "economy.city.resource.fertile_soil.regen_factor"),
    ("resource.wild_game.regen_factor", "economy.city.resource.wild_game.regen_factor"),
    ("resource.freshwater_fish.regen_factor",
     "economy.city.resource.freshwater_fish.regen_factor"),
]

IDEOLOGY_CITY_STATS = [
    ("output_factor", "economy.city.output_factor"),
    ("building.agriculture_output_factor", "economy.city.building.agriculture_output_factor"),
    ("building.extractive_output_factor", "economy.city.building.extractive_output_factor"),
    ("building.manufacturing_output_factor", "economy.city.building.manufacturing_output_factor"),
    ("building.energy_output_factor", "economy.city.building.energy_output_factor"),
    ("building.knowledge_output_factor", "economy.city.building.knowledge_output_factor"),
    ("birth_factor", "economy.city.birth_factor"),
    ("need.staple_food.consumption_factor", "economy.city.need.staple_food.consumption_factor"),
    ("need.housing.consumption_factor", "economy.city.need.housing.consumption_factor"),
    ("need.clothing.consumption_factor", "economy.city.need.clothing.consumption_factor"),
    ("need.household_goods.consumption_factor",
     "economy.city.need.household_goods.consumption_factor"),
    ("need.protein.consumption_factor", "economy.city.need.protein.consumption_factor"),
    ("need.home_energy.consumption_factor",
     "economy.city.need.home_energy.consumption_factor"),
    ("need.education_culture.consumption_factor",
     "economy.city.need.education_culture.consumption_factor"),
    ("need.luxury.consumption_factor",
     "economy.city.need.luxury.consumption_factor"),
    ("resource.regen_factor", "economy.city.resource.regen_factor"),
    ("resource.timber.regen_factor", "economy.city.resource.timber.regen_factor"),
    ("resource.pasture.regen_factor", "economy.city.resource.pasture.regen_factor"),
    ("resource.fertile_soil.regen_factor", "economy.city.resource.fertile_soil.regen_factor"),
    ("resource.wild_game.regen_factor", "economy.city.resource.wild_game.regen_factor"),
    ("resource.freshwater_fish.regen_factor", "economy.city.resource.freshwater_fish.regen_factor"),
    ("good.lumber.output_factor", "economy.city.good.lumber.output_factor"),
    ("good.crude_oil.output_factor", "economy.city.good.crude_oil.output_factor"),
    ("good.natural_gas.output_factor", "economy.city.good.natural_gas.output_factor"),
    ("good.rice_grain.output_factor", "economy.city.good.rice_grain.output_factor"),
    ("good.grain.output_factor", "economy.city.good.grain.output_factor"),
    ("good.cloth.output_factor", "economy.city.good.cloth.output_factor"),
    ("good.fine_clothing.output_factor", "economy.city.good.fine_clothing.output_factor"),
    ("good.fertilizer.output_factor", "economy.city.good.fertilizer.output_factor"),
    ("good.plastics.output_factor", "economy.city.good.plastics.output_factor"),
    ("good.synthetic_fiber.output_factor", "economy.city.good.synthetic_fiber.output_factor"),
    ("good.semiconductors.output_factor", "economy.city.good.semiconductors.output_factor"),
    ("good.game_meat.output_factor", "economy.city.good.game_meat.output_factor"),
    ("good.fish.output_factor", "economy.city.good.fish.output_factor"),
    ("good.meat.output_factor", "economy.city.good.meat.output_factor"),
    ("good.dairy_products.output_factor", "economy.city.good.dairy_products.output_factor"),
]
IDEOLOGY_CITY_KEY_PREFIX = "ideology.city."


_CITY_SUFFIX_TO_STAT = {suffix: stat for suffix, stat in IDEOLOGY_CITY_STATS}

# ── country-scoped program modifier family (`ideology.country.*`) ───────────
# A `RampTerm` is an Effect instruction sequence, so it cannot ride a plain
# Modifier definition. Country-domain program rows therefore need their own
# definitions, just as cell rows need `economy.city.*`.
#
# One MULTIPLY term per stat:
#   * `.cut`  factor 0.0 -> 1 - magnitude (a 6% ramp reads 0.94)
#   * `.gain` factor 2.0 -> 1 + magnitude (a 6% ramp reads 1.06)
#
# The command carries the magnitude. Keeping the direction in the definition is
# required because command magnitudes are non-negative.
IDEOLOGY_COUNTRY_STATS = [
    ("population.death_factor", DEATH, "cut"),
    ("construction.cost_factor", B_COST, "cut"),
    ("research.cost_factor", R_COST, "cut"),
    ("trade.capacity_factor", T_CAP, "gain"),
    ("output.agriculture_factor", AGRI, "gain"),
    ("output.extractive_factor", EXTR, "gain"),
    ("output.manufacturing_factor", MANU, "gain"),
    ("output.energy_factor", ENER, "gain"),
    ("output.knowledge_factor", KNOW, "gain"),
    ("ideology.point_gain_factor", POINTS, "gain"),
    ("ideology.point_population_factor", POINT_POPULATION, "gain"),
    ("ideology.point_building_factor", POINT_BUILDING, "gain"),
    ("ideology.point_trade_factor", POINT_TRADE, "gain"),
    ("ideology.school_strength_factor.harmony", MANDATE_HARMONY, "gain"),
]
IDEOLOGY_COUNTRY_KEY_PREFIX = "ideology.country."
_COUNTRY_SUFFIX_TO_STAT = {
    suffix: stat for suffix, stat, _direction in IDEOLOGY_COUNTRY_STATS
}
def country_stat_key(suffix: str, cut: bool = True,
                     gain: bool = False) -> str:
    """The definition a country program should name for `suffix`.

    `cut` is the default because every currently authored country ramp lowers
    its stat. Asking for neither direction is an authoring error: the runtime
    command magnitude is unsigned, so the definition has to carry the sign.
    """
    if suffix not in _COUNTRY_SUFFIX_TO_STAT:
        raise SystemExit(f"ideology.country: unknown suffix {suffix}")
    if cut and gain:
        raise SystemExit(f"ideology.country: {suffix} cannot be both cut and gain")
    if not cut and not gain:
        raise SystemExit(f"ideology.country: {suffix} needs cut or gain")
    return (f"{IDEOLOGY_COUNTRY_KEY_PREFIX}{suffix}"
            f"{'.cut' if cut else '.gain'}")


def city_stat_key(suffix: str, cut: bool = False) -> str:
    """The definition a cell command should name for `suffix` (and its `.cut` twin).

    Points at the *economy* stat, not `ideology.city.<suffix>`: the latter family
    is write-only -- gdext reads city output/consumption through its own id
    tables keyed on the economy stats, so a card naming an `ideology.city.*` key
    compiled, stored a row, and changed nothing. The economy names are also what
    the coefficient plane resolves against.
    """
    stat = _CITY_SUFFIX_TO_STAT.get(suffix)
    if stat is None:
        raise SystemExit(f"ideology.city: unknown suffix {suffix}")
    return f"{stat}{'.cut' if cut else ''}"


def city_modifier_key(suffix: str, value: float) -> str:
    """The definition a cell command should name for `value` on `suffix`.

    Positive values use the gain definition with magnitude = value; negative
    values use the `.cut` twin with magnitude = -value. Keeping the sign in the
    definition (not the magnitude) is forced by the runtime clamp.
    """
    return city_stat_key(suffix, cut=value < 0.0)


def B(building_id: str) -> str:
    """Country-wide output factor of one building type."""
    return f"country.output.building.{building_id}_factor"


def G(good_id: str) -> str:
    """Country-wide output factor of one good."""
    return f"country.output.good.{good_id}_factor"


def GI(good_id: str) -> str:
    """Country-wide input factor of one good (how expensive it is to use)."""
    return f"country.input.good.{good_id}_factor"


def GC(good_id: str) -> str:
    """Country-wide household consumption factor of one good."""
    return f"country.consumption.good.{good_id}_factor"


def FAM(family_id: str) -> str:
    """Output factor of a whole building upgrade family."""
    return f"country.output.family.{family_id}_factor"


def T(terrain_id: str, sector: str) -> str:
    """Output of one economic sector, but only on cells of one terrain.

    This is the geographic selector: production multiplies
    country x sector x terrain x landform, so a term here lands on cells that
    actually carry that terrain and nowhere else.
    """
    return f"country.output.terrain.{terrain_id}.{sector}_factor"


def LF(landform_id: str, sector: str) -> str:
    """Output of one economic sector, but only on cells of one landform."""
    return f"country.output.landform.{landform_id}.{sector}_factor"


def _bare_resource_id(resource_id: str) -> str:
    """Signal ids carry a `resource.` namespace; stat keys do not.

    `resource.iron_ore` is how a research signal is addressed, while
    `country.resource.iron_ore.use_factor` is how the modifier catalog addresses
    the same resource. Accepting either spelling here keeps the table readable
    and prevents the `resource.resource.x` double prefix.
    """
    return resource_id[len("resource."):] if resource_id.startswith("resource.") else resource_id


def RUSE(resource_id: str) -> str:
    """Extraction intensity of one natural resource. Higher burns the stock faster."""
    return f"country.resource.{_bare_resource_id(resource_id)}.use_factor"


def RREG(resource_id: str) -> str:
    """Managed natural regeneration of one resource (forestry, aquaculture, ...).

    This changes the stock's regrowth rate rather than a production number, so it
    trades short-term yield for a permanently larger resource base.
    """
    return f"country.resource.{_bare_resource_id(resource_id)}.managed_generation_factor"


def PROFILE(profile_id: str, hazard: str) -> str:
    """Hazard loss of one production climate profile, not of the whole country.

    Hits only productions that declare that profile (paddy_crop, pasture_livestock,
    plantation_crop, dryland_crop, foraging_plants, phenology_observation).
    """
    return f"country.climate.profile.{profile_id}.{hazard}_loss_factor"


# ── research signals used as hard draw gates ─────────────────────────────────
# 124 signals exist; these are the ones the card table conditions on. They are
# discovered per country from the map, so a card gated here only appears for a
# player whose territory actually provides it.
IRON = "resource.iron_ore"
COAL = "resource.coal"
SALT = "resource.salt"
TIMBER = "resource.timber"
STONE = "resource.stone"
COPPER = "resource.copper_ore"
SILVER = "resource.silver_ore"
OIL = "resource.oil"
GAS = "resource.natural_gas"
FLINT = "resource.flint"
CLAY = "resource.clay"
PHOSPHATE = "resource.phosphate_rock"
SILICA = "resource.silica_sand"
RARE_EARTH = "resource.rare_earth"
WILD_GAME = "resource.wild_game"
FRESHWATER_FISH = "resource.freshwater_fish"
FERTILE = "resource.fertile_soil"
PASTURE_LAND = "resource.pasture"

WHEAT = "bio.wheat"
RICE = "bio.rice"
MAIZE = "bio.maize"
POTATO = "bio.potato"
HORSE = "bio.horse"
CATTLE = "bio.cattle"
SILKWORM = "bio.silkworm"
COTTON = "bio.cotton"
BAST_FIBER = "bio.bast_fiber"
MEDICINAL_HERB = "bio.medicinal_herb"

MOUNTAIN = "landform.mountain"
PLATEAU = "landform.high_plateau"
FOREST_LF = "landform.forest"
GRASSLAND_LF = "landform.grassland"
COAST_LF = "landform.coast"
DELTA = "landform.delta"
FLOODPLAIN = "landform.floodplain"
RIVER_VALLEY = "landform.river_valley"
MONSOON_BASIN = "landform.monsoon_basin"
ARID_BASIN = "landform.arid_basin"
OASIS = "landform.oasis"
MARSH = "landform.marsh"
TUNDRA_LF = "landform.tundra"
VOLCANIC = "landform.volcanic"
STEEP_SLOPE = "landform.steep_slope"
FRESHWATER_ACCESS = "landform.freshwater_access"

W_DROUGHT = "weather.drought"
W_FLOOD = "weather.major_flood"
W_MONSOON = "weather.monsoon"
W_TYPHOON = "weather.typhoon"
W_FROST = "weather.frost"
W_CROP_FAILURE = "weather.repeated_crop_failure"

C_MARITIME = "contact.maritime_vessel"
C_POTATO = "contact.potato"
C_RUBBER = "contact.rubber"

KINGDOM = "tech.kingdom_administration"
IMPERIAL = "tech.imperial_integration"
GLOBAL = "tech.global_exchange"
ENLIGHT = "tech.enlightenment_institutions"
INDUSTRIAL = "tech.industrialization"
ELECTRIC = "tech.electrical_society"

# Era floor per card, indexed by era_index. Entry i is eras[i].milestone_id in
# data/technology/technology_network.json: the technology whose completion puts
# the player *into* era i (current_era is the highest era with its milestone
# done). A card of era i is therefore drawable exactly from era i on, which the
# existing Kind.TECHNOLOGY draw requirement expresses with no new native type.
# Era 0 needs no gate because current_era starts at 0.
ERA_MILESTONE_TECH = [
    "tech.settled_knowledge",
    "tech.agrarian_society",
    "tech.kingdom_administration",
    "tech.imperial_integration",
    "tech.global_exchange",
    "tech.enlightenment_institutions",
    "tech.industrialization",
    "tech.electrical_society",
    "tech.atomic_modernity",
    "tech.information_society",
    "tech.cognitive_automation",
]
ERA_NAMES = ["石器时代", "农耕时代", "王国时代", "帝国时代", "探索时代", "启蒙时代",
             "蒸汽时代", "电气时代", "原子时代", "信息时代", "智能时代"]

# (key, name, school, rarity, era, exclusion, tech, signals, detail, terms)
#
# `signals` is a list of research-signal ids that must all be discovered before
# the card can be drawn. `era` adds the era milestone as an extra technology
# requirement; `tech` is an explicit extra technology on top of that. Leave both
# empty when the era floor already says everything.
#
# Level-1 magnitudes stay inside 3%..10%; level 3 (2.2x) then tops out around 22%
# on the card's defining axis, which is where the build identity comes from.
CARDS = [
    # X11 fiscal cards. Numbers live in LEVEL_TERMS / LEVEL_ROWS.
    ("treasury_reserve", "太仓", "mobilization", 2, 4, "", "", [],
     "国库储备越厚，死亡率与建设成本越低；全国贸易容量为这套储备体系让路。", []),
    ("silver_standard", "银本位", "commerce", 2, 5, "", "", [],
     "以白银保证货币信用，国库储备直接扩张贸易容量；全国家庭消费承担银根成本。", []),
    ("subsidy_state", "补贴国家", "harmony", 3, 7, "", "", [],
     "轻税地块得到国家补贴，产出提高；全国建设成本随行政负担上升。", []),
    ("sovereign_fund", "主权基金", "commerce", 3, 10, "", "", [],
     "把国库储备投向长期产业，各部门产出随储备增厚；全国贸易容量为此让路。", []),

    # ── 石器时代 ────────────────────────────────────────────────────────────
    # X9a family cards. Numbers live in LEVEL_TERMS / LEVEL_ROWS.
    ("kin_hearth", "亲族火塘", "mobilization", 1, 0, "", "", [],
     "火塘边的人口与家产聚成宗族，最早的家族秩序由灶火维系。", []),
    ("forager_band", "采集游群", "agrarian", 1, 0, "", "", [],
     "按季节轮换营地，林下的坚果、块根与浆果养活了整个部族。",
     []),  # numbers live in LEVEL_TERMS
    ("hunting_tradition", "狩猎传统", "mobilization", 1, 0, "", "", [],
     "以围猎、陷阱与分工分配肉食，青壮年在协作中学会统一号令。",
     [(RUSE(WILD_GAME), 1.06)]),
    ("flint_knapping", "打制石器", "industry", 1, 0, "", "", [FLINT],
     "打击石核取刃，形状统一的石器让各项劳作都更省力。",
     [(RUSE(FLINT), 1.08)]),
    ("fire_keeping", "火种守护", "harmony", 1, 0, "", "", [],
     "专人看守长明火堆，寒夜的冻害与恐惧同时退去，柴薪消耗也随之上升。",
     [(COLD, 0.92), (T("tundra", "agriculture"), 1.05), (RUSE(TIMBER), 1.04)]),
    ("riverside_camp", "逐水而居", "harmony", 1, 0, "", "", [FRESHWATER_ACCESS],
     "营地紧贴河岸与湖湾，取水捕鱼极便，洪水却始终是威胁。",
     []),  # numbers live in LEVEL_TERMS
    ("animist_ritual", "万物有灵", "learning", 1, 0, "", "", [],
     "把山川鸟兽都视作有意志的存在，解释世界的方式由此开始。",
     [(R_SOC, 1.05), (POINTS, 1.05), (R_SCI, 0.97)]),
    ("gift_exchange", "馈赠交换", "commerce", 1, 0, "", "", [],
     "以礼物与回礼代替买卖，熟人之间的物流从不间断，礼物本身却要耗料。",
     [(T_CAP, 1.05), (T_SPEED, 1.04), (INPUT, 1.02)]),
    ("communal_feast", "共食", "mobilization", 1, 0, "", "", [],
     "猎物与采集物在火塘边均分，人人有份，野兽却被猎得更狠。",
     [(RUSE(WILD_GAME), 1.04)]),
    ("shell_midden", "贝丘", "harmony", 1, 0, "", "", [],
     "鱼骨与贝壳堆成营地，沿岸渔获更稳定，鱼群被持续采捕。", []),
    ("pit_dwelling", "穴居聚落", "industry", 1, 0, "", "", [],
     "掘地为屋、聚族而居，御寒与省工两得，可耕的地面却让了出去。",
     []),  # numbers live in LEVEL_TERMS

    # ── 农耕时代 ────────────────────────────────────────────────────────────
    ("collective_stewardship", "共同体治理", "agrarian", 1, 1, "economic_order", "", [],
     "以共同仓储、互助义务和长期土地责任组织生产，灵活交易被牺牲。",
     [(T_CAP, 0.97)]),
    ("terrace_farming", "梯田", "agrarian", 1, 1, "", "", [MOUNTAIN],
     "顺山势砌石成田，坡地上的每一寸土都被用上，工料耗费极大。",
     []),  # numbers live in LEVEL_TERMS
    ("paddy_cultivation", "稻作", "agrarian", 1, 1, "", "", [RICE],
     "筑埂蓄水、育秧移栽，水田的单产远高于旱地，却挤占麦作。",
     [(G("rice_grain"), 1.10), (T("swamp", "agriculture"), 1.08),
      (LF("delta", "agriculture"), 1.08), (G("wheat_grain"), 0.95)]),
    ("three_field_rotation", "三圃轮作", "agrarian", 2, 1, "land_order", "", [WHEAT],
     "把耕地分为三片轮换休耕，地力得以恢复，牧草地相应让出。",
     [(T("grassland", "agriculture"), 0.97)]),
    ("free_exchange", "自由交换", "commerce", 1, 1, "economic_order", "", [],
     "以契约、流通和分散决策鼓励资源重新配置，家庭消费随之抬头。",
     [(CONSUME, 1.02)]),
    ("scholar_office", "学识官署", "learning", 1, 1, "", "", [],
     "让记录、测量与专业知识成为公共决策的正式依据，行政耗费上升。",
     [(KNOW, 1.05), (R_SCI, 1.04), (INPUT, 1.02)]),
    ("standardization", "标准化", "industry", 1, 1, "", "", [],
     "统一度量、规格与零件，生产与建造都更省料，流通节奏却被规矩拖慢。",
     [(T_SPEED, 0.98)]),
    ("household_weaving", "家内纺织", "industry", 1, 1, "", "", [BAST_FIBER],
     "农妇在农隙纺麻织布，家庭收支多了一条底线，麻田与粮田开始争地。",
     [(T("plain", "agriculture"), 0.97)]),
    ("coppice_rotation", "轮伐", "harmony", 2, 1, "", "", [TIMBER],
     "分区伐取、留桩待萌，林木再生率大涨，短期木材产量却要退一步。",
     []),
    ("water_works", "治水营田", "harmony", 1, 1, "", "", [FLOODPLAIN],
     "修堤疏渠、引水灌田，把洪水变成可用的水利，工役耗费不轻。",
     []),  # numbers live in LEVEL_TERMS
    ("bronze_casting", "青铜铸造", "industry", 1, 1, "", "", [COPPER],
     "铜矿与锡矿在同一片工坊网络中汇合，青铜工具的成本由此下降。",
     [(RUSE(COPPER), 1.06)]),
    ("seasonal_calendar", "寒暑历法", "harmony", 1, 1, "", "", [],
     "以节气指导农时与役使，寒暑异常的危害大为减轻，思辨的锐气稍减。",
     []),  # numbers live in LEVEL_TERMS
    # §47.5 X16 cards. All STAGED (see CARD_REQUIRES); numbers live in LEVEL_TERMS.
    ("light_levy", "轻徭薄赋", "agrarian", 1, 1, "", "", [],
     "轻徭薄赋向来是立国之本，低税要真的少收钱才算数。", []),
    ("ancestral_hall", "宗祠", "harmony", 2, 1, "", "", [],
     "宗族以祠堂、义庄与族田联结子孙，兼并田产却苦了佃户。", []),
    ("clan_fields", "族田", "agrarian", 2, 2, "", "", [],
     "族田把家产与农庄系在一起，显赫宗族因此深耕乡土，异姓农户却受排挤。", []),

    # ── 王国时代 ────────────────────────────────────────────────────────────
    ("ever_normal_granary", "常平仓", "agrarian", 2, 2, "", "", [],
     "丰年籴入、歉年粜出，以官仓平抑粮价与饥荒，市面流通被官仓压住。",
     [(T_CAP, 0.97)]),
    ("tax_farming", "包税", "commerce", 2, 2, "", "", [],
     "包税商代征，商户不必直面官府，重税之下仍留一线。", []),
    ("petition_box", "登闻鼓", "harmony", 1, 2, "", "", [],
     "击鼓上闻、直达天听，怨气有处可去，吏员却多了一桩差事。", []),
    ("settle_and_farm", "屯垦", "agrarian", 2, 2, "land_order", KINGDOM, [],
     "编户屯垦，把荒原与边地一并开成田，投入的农具与口粮同样惊人。",
     [(INPUT, 1.03)]),
    ("open_ports", "市舶开港", "commerce", 1, 2, "", "", [COAST_LF],
     "设市舶司、开海口通商，货物周转加快，船料把林地消耗推高。",
     [(T_SPEED, 1.07), (T_CAP, 1.03), (RUSE(TIMBER), 1.03)]),
    ("guild_charters", "行会特许", "commerce", 2, 2, "labor_order", "", [],
     "以特许状给予行会定价与学徒制度，品质稳定而新建更贵。",
     [(B_COST, 1.03)]),
    ("double_entry", "复式簿记", "commerce", 2, 2, "", KINGDOM, [],
     "借贷必相等，账目透明让工坊与商号都能精打细算，算计压过了理想。",
     [(INPUT, 0.95), (T_CAP, 1.03), (POINTS, 0.97)]),
    ("academy_lectures", "书院讲学", "learning", 1, 2, "", "", [],
     "书院讲会、辞辩争鸣，民间对国家道路的理解更加深入，耗用于是增加。",
     [(R_SOC, 1.05), (KNOW, 1.03), (POINTS, 1.06), (INPUT, 1.02)]),
    ("civil_examination", "科举取士", "learning", 2, 2, "", KINGDOM, [],
     "以考试选拔官员，学风大盛，最好的头脑都去读经，工技反受冷落。",
     [(R_COST, 0.95), (R_SOC, 1.03), (T("plain", "manufacturing"), 0.98)]),
    ("iron_smelting", "冶铁", "industry", 2, 2, "", "", [IRON],
     "就地开炉鼓风，铁矿运距归零让铁料便宜，矿脉也消耗得飞快。",
     [(RUSE(IRON), 1.06)]),
    ("postal_horse", "驿传", "mobilization", 2, 2, "", "", [HORSE],
     "沿官道设驿换马，政令与商旅同时提速，牧草挤掉了口粮田。",
     [(T_SPEED, 1.08), (G("horses"), 1.06), (G("wheat_grain"), 0.96)]),
    ("monsoon_farming", "汛期农法", "agrarian", 3, 2, "", "", [W_MONSOON],
     "按季风起落安排浸种与排水，水田的洪灾损失被压到最低，旱地却学不来。",
     [(PROFILE("paddy_crop", "flood"), 0.88), (LF("delta", "agriculture"), 1.06),      (T("desert", "agriculture"), 0.95)]),
    ("river_transport", "漕运", "commerce", 2, 2, "", "", [RIVER_VALLEY],
     "沿河设闸、分段转运，粮货逆流而上，沿岸谷地的工坊随之兴旺，河工岁修是一笔长期账。",
     [(T_SPEED, 1.06), (T_CAP, 1.04), (T("floodplain", "manufacturing"), 1.05),
      (B_COST, 1.04)]),
    ("canal_corvee", "开渠", "mobilization", 2, 2, "", "", [],
     "征发民夫开凿运河，沿岸农业得以引水，渠工却压低了当地出生率。", []),

    # ── 帝国时代 ────────────────────────────────────────────────────────────
    ("village_compact", "乡约自治", "agrarian", 3, 3, "", IMPERIAL, [],
     "以乡约、社仓与家族共治维系基层秩序，民心即是国本，流通却少了弹性。",
     [(T_CAP, 0.97)]),
    # X9a. The branch-count bonus and luxury price ship here. The adjacent
    # clan-cell stacking clause has no selector for "same tag in R1" yet, so it
    # remains a NEEDS_RUNTIME gap instead of a second ring approximation.
    ("marriage_alliance", "联姻", "harmony", 2, 3, "", "", [],
     "以婚姻缔结同盟，多个宗族共处一地，奢侈品往来成为维系门第的代价。", []),
    ("land_reclamation", "垦荒令", "agrarian", 2, 3, "land_order", "", [],
     "招民开垦河漫与绿洲，田亩既增，水土也开始吃紧。",
     # §47.7: the only price used to be `FLOOD 1.03`, which is a V3 no-op (that
     # stat is clamped at 1.0), so the card was free. Build cost is charged.
     [(B_COST, 1.02)]),
    ("granary_road", "漕运仓法", "commerce", 2, 3, "", "", [],
     "以运河与官仓串起粮道，丰歉在千里之间互相调剂，船料取于山林。",
     [(T_SPEED, 1.05), (T_CAP, 1.03), (DEATH, 0.98), (RUSE(TIMBER), 1.03)]),
    ("imperial_academy", "太学", "learning", 2, 3, "", "", [],
     "国家设学养士，注疏与考据成为可积累的公共知识，正统压住异说。",
     [(R_INST, 1.05), (R_COST, 0.97), (POINTS, 0.97)]),
    ("public_hygiene", "公共卫生", "mobilization", 2, 3, "", IMPERIAL, [],
     "清渠、隔离与种痘，把健康变成可以组织的公共事务，宅第造价随之上浮。",
     [(B_COST, 1.03)]),
    # X13a. Neighbour spillover and drought-end birth are X4 timed clauses;
    # the drought-cell staple-demand relief is expressible as an exact mask.
    ("drought_relief", "赈旱", "mobilization", 2, 3, "", "", [],
     "赈粮直抵旱区，主食需求压力下降，全国调运余量却被摊薄。", []),
    ("heaven_human", "天人相参", "harmony", 2, 3, "", IMPERIAL, [],
     "观天察地以定政令，对旱涝与农业规律的理解更加系统，实测精神被压制。",
     [(DROUGHT, 0.95), (FLOOD, 0.95), (R_AGRI, 1.05), (R_SCI, 0.97)]),
    ("mandate_of_heaven", "天命", "harmony", 3, 3, "", "", [],
     "过去一年没有灾害的自有地块越多，调和理念越强；灾害遍及时则以赈济降低死亡。",
     []),  # numbers live in LEVEL_TERMS / LEVEL_ROWS
    ("salt_monopoly", "盐铁专营", "industry", 2, 3, "economic_order", "", [SALT],
     "国家专营盐池与铁冶，盐利充盈国库，私商与盐脉同受挤压。",
     [(RUSE(SALT), 1.08), (T_CAP, 0.97)]),
    ("sericulture", "蚕桑", "industry", 2, 3, "", "", [SILKWORM],
     "植桑养蚕、缫丝织锦，绢帛成了硬通货，桑田与粮田争地。",
     [(T("plain", "agriculture"), 0.97)]),
    ("grand_canal", "大运河", "commerce", 3, 3, "", "", [],
     "运河与河道连成贯通全国的漕渠，渠网内生产兴旺，维护工程耗费巨大。", []),

    # ── 探索时代 ────────────────────────────────────────────────────────────
    ("ocean_company", "远洋公司", "commerce", 3, 4, "", GLOBAL, [],
     "以股份与特许组织远洋贸易，财富涌入也加速了船料与木林的消耗。",
     [(T_CAP, 1.07), (T_SPEED, 1.05), (RUSE(TIMBER), 1.04)]),
    ("chartered_route", "特许航路", "commerce", 2, 4, "economic_order", "", [C_MARITIME],
     "把航线、港口与补给点连成一张特许网络，香料与糖源源而来，盐业受挤。",
     [(G("salt"), 0.97)]),
    ("cartography", "舆图测绘", "learning", 2, 4, "", "", [COAST_LF],
     "以经纬、罗盘与实测修订海图，远航代价下降，测绘本身也是开销。",
     [(R_SCI, 1.04), (T_SPEED, 1.05), (B_COST, 1.02)]),
    ("colonial_plantation", "殖民种植园", "agrarian", 2, 4, "land_order", "", [MONSOON_BASIN],
     "以单一作物大规模开垦，产量惊人，地力与林地迅速被抽干。",
     [(T("jungle", "agriculture"), 1.10), (G("cotton_fiber"), 1.06),
      (RUSE(FERTILE), 1.08), (RREG(FERTILE), 0.92)]),
    ("silver_flow", "白银流入", "commerce", 3, 4, "economic_order", "", [SILVER],
     "海外白银持续涌入，物价与交易规模一起被推高，银矿被疯狂开采。",
     [(RUSE(SILVER), 1.10)]),
    ("natural_history", "博物志", "learning", 2, 4, "", "", [],
     "标本、分类与田野记录并行，农业与科学的边界开始相接，纯粹思辨退场。",
     [(R_SCI, 1.05), (R_AGRI, 1.04), (KNOW, 0.98)]),
    ("manufactory_regulation", "工场规程", "industry", 2, 4, "", "", [],
     "以工序章程约束手工工场，用料被重新安排，周转反被规矩拖慢。",
     [(G("metal_housewares"), 1.06), (INPUT, 0.97), (T_SPEED, 0.98)]),
    ("maritime_insurance", "海事保险", "commerce", 2, 4, "", "", [C_MARITIME],
     "分摊海难风险，远洋船队敢走更远的航线，保费最终摊到每一户的消费上。",
     [(T_CAP, 1.05), (CONSUME, 1.02)]),
    ("merchant_houses", "商号", "commerce", 2, 4, "", "", [],
     "商号以宗族信用经营多处产业，家产铺得越广，投入品的议价越占优势。", []),

    ("gentry_patronage", "乡绅", "learning", 1, 4, "", "", [],
     "乡绅办学、修桥、赈济，乡土文教随之兴旺，佃户却更难自立。", []),
    # X12. The border clause is expressible with the new metric-75 tag; L3's
    # "also counts as frontier" OR needs a tag-set operator and is deferred.
    ("frontier_garrison", "戍边", "mobilization", 1, 2, "", "", [],
     "以军屯守边、就地开垦，边境的农事与人口都更稳定，商路却被拖慢。", []),

    # ── 启蒙时代 ────────────────────────────────────────────────────────────
    ("experimental_method", "实验之法", "learning", 2, 5, "", ENLIGHT, [],
     "以可重复的实验代替权威，工程与自然研究同步大进，经世之学受冷落。",
     [(R_SCI, 1.06), (R_ENG, 1.05), (R_SOC, 0.97)]),
    ("encyclopedia", "百科全书", "learning", 3, 5, "", ENLIGHT, [],
     "把天下之学编为一部可查可证的书，知识流通不可逆，编纂耗费巨大。",
     [(R_INST, 1.06), (KNOW, 1.05), (POINTS, 1.08), (B_COST, 1.03)]),
    ("national_education", "国民教育", "mobilization", 2, 5, "", ENLIGHT, [],
     "义务教育塑造统一语言与技艺，研究与理念同时受益，家计负担上升。",
     [(R_SOC, 1.05), (R_ENG, 1.03), (POINTS, 1.04), (CONSUME, 1.03)]),
    ("agrarian_reform", "农政改革", "agrarian", 2, 5, "land_order", "", [],
     "清丈田亩、整顿租佃，粮产与地权都更清楚，旧有乡约秩序被削弱。",
     [(G("wheat_grain"), 1.06), (T("plain", "agriculture"), 1.06), (R_SOC, 0.97)]),
    ("coal_basin", "煤田开发", "industry", 2, 5, "land_order", "", [COAL],
     "沿煤层开凿矿井与洗煤厂，能源充裕而矿脉消耗极快。",
     [(RUSE(COAL), 1.06)]),
    ("cotton_gin", "轧棉", "industry", 2, 5, "", "", [COTTON],
     "以机械脱籽代替手工，棉花纤维的可用量大增，棉田挤占了粮田。",
     [(T("plain", "agriculture"), 0.97)]),
    ("enclosure", "圈地", "agrarian", 2, 5, "land_order", "", [],
     "以篱界并小块为牧场，畜产与牧草再生大增，小农与谷物让位。",
     [(T("grassland", "agriculture"), 1.08), (RREG(PASTURE_LAND), 1.10),
      (T("plain", "agriculture"), 0.96), (R_SOC, 0.97)]),
    ("land_value", "地租论", "agrarian", 1, 5, "", "", [],
     "地价上涨，地主付得起地税，城郊农业也随大邑兴起。", []),
    ("family_enterprise", "家族企业", "industry", 2, 5, "", "", [],
     "家族把资本集中到工坊，家产占优的地块工业更盛，外来工坊却难与之争。", []),
    # X13a. The annual-temperature multiplier is available now. The cold-cell
    # doubling of other cards and the L3 8C threshold remain NEEDS_RUNTIME.
    ("little_ice_age", "小冰期", "harmony", 3, 4, "", "", [],
     "长年低温把寒地变成新的产粮核心，暑地农业却因积温不足而萎缩。", []),
    ("learned_society", "学会", "learning", 2, 5, "", "", [],
     "以通信、期刊与同行评议组织学问，研究效率上升，会务与出版耗费不轻。",
     [(R_INST, 1.05), (POINTS, 1.05), (INPUT, 1.02)]),
    # 摊丁入亩 (§47.5): the numbers are X16 stat rows, so they live in
    # `LEVEL_TERMS` below. The card is STAGED on X16 + metric68 -- see
    # `CARD_REQUIRES` -- because writing the old `TAX(...)` rates is exactly the
    # V1 defect §47 removed: one free tax click, worth nothing.
    ("land_tax_reform", "摊丁入亩", "agrarian", 2, 5, "land_order", ENLIGHT, [],
     "把丁银摊入田亩，无地者不再负担人头税，田多的地主税负随之加重。",
     []),
    # 消费税制 (§47.5): same story -- X16 tolerance instead of a consumption-tax
    # rate the player can set himself. Staged on X16.
    ("excise", "消费税制", "commerce", 1, 5, "", ENLIGHT, [],
     "对奢侈品开征消费税，国库得到稳定进项，这些货物的负担落到用得起的人身上。",
     []),

    # ── 蒸汽时代 ────────────────────────────────────────────────────────────
    ("steam_power", "蒸汽动力", "industry", 2, 6, "", INDUSTRIAL, [COAL],
     "以蒸汽机取代水力与畜力，能源与制造同时跃进，煤耗随之暴涨。",
     [(ENER, 1.06), (MANU, 1.03), (RUSE(COAL), 1.05)]),
    ("railway_network", "铁路网", "industry", 2, 6, "", "", [],
     "钢轨把内陆与港口缝在一起，货运速度从此改换量级，平原沿线的工坊先被点亮，路基造价高昂。",
     [(T_SPEED, 1.08), (T_CAP, 1.04), (T("plain", "manufacturing"), 1.05),
      (B_COST, 1.04)]),
    ("urban_sanitation", "城市卫生", "mobilization", 2, 6, "", "", [],
     "下水道、自来水与皂厂让拥挤的城市不再自我毒害，管网投资巨大。",
     [(B_COST, 1.03)]),
    ("steam_shipping", "汽船航运", "commerce", 2, 6, "", "", [],
     "定期汽船班轮取代风帆，贸易容量与速度同步上升，锅炉张着嘴烧煤。",
     [(T_CAP, 1.06), (T_SPEED, 1.04), (RUSE(COAL), 1.04)]),
    ("labour_legislation", "劳动立法", "mobilization", 2, 6, "labor_order", "", [],
     "限定工时、承认工会，工人生活压力减轻，用工成本上升。",
     []),  # numbers live in LEVEL_TERMS
    ("free_trade", "自由贸易", "commerce", 2, 6, "economic_order", "", [],
     "撤除关税壁垒，贸易容量大涨，本国制造在进口货面前没有遮拦。",
     [(T_CAP, 1.07), (T("plain", "manufacturing"), 0.97)]),
    ("agricultural_chemistry", "农业化学", "agrarian", 2, 6, "", "", [PHOSPHATE],
     "以磷矿与硝酸盐造肥，旱地单产大涨，矿源与水体同时承压。",
     # §47.7: `FLOOD 1.02` was a V3 no-op; the real price is the phosphate burn.
     [(RUSE(PHOSPHATE), 1.08)]),
    # X13a. Frost aftermath and L3 winter storage are X4 timed event stacks;
    # only the annual-climate clause is expressible in this round.
    ("frost_lore", "霜信", "harmony", 1, 1, "", "", [],
     "以霜期、土温和冬储经验安排农事，寒地农业更稳，暑地精耕受到拖累。", []),
    ("telegraph", "电报", "learning", 2, 6, "", "", [],
     "以电线传递消息，商情与政令同时提速，线路维护是一笔常年开销。",
     [(T_SPEED, 1.05), (R_SOC, 1.03), (B_COST, 1.02)]),
    ("trade_unions", "工会", "mobilization", 2, 6, "labor_order", "", [],
     "产业工人占比越高的地块越能从集体谈判中受益，全国生产投入却随工资压力上升。",
     [(INPUT, 1.03)]),

    # ── 电气时代 ────────────────────────────────────────────────────────────
    ("assembly_line", "流水线", "industry", 3, 7, "", ELECTRIC, [],
     "以传送带与工序分解组织大规模生产，物料极省而原料吞吐陡增。",
     [(MANU, 1.07), (INPUT, 0.96), (RES_USE, 1.04)]),
    ("electrification", "电气化", "industry", 3, 7, "", "", [],
     "以电网覆盖城乡，动力可以远距离输送到每一台机器，发电仍靠烧煤。",
     [(RUSE(COAL), 1.05)]),
    ("ecological_balance", "生态均衡", "harmony", 3, 7, "", ELECTRIC, [],
     "以循环与修复约束工业增长，资源与人口得到长期平衡，产能让步。",
     [(MANU, 0.97)]),
    ("mass_media", "大众传媒", "learning", 2, 7, "", "", [],
     "报纸、广播与电影把同一套叙事送进每一个家庭，深度学问被稀释。",
     [(R_SOC, 1.05), (POINTS, 1.04), (KNOW, 0.98)]),
    ("chemical_industry", "化学工业", "industry", 2, 7, "", "", [SALT],
     "以电解与合成改写原料来源，盐卤变成化工之母，副产物污染水土。",
     [(G("industrial_chemicals"), 1.08), (GI("salt"), 0.94), (RUSE(SALT), 1.06)]),
    ("hydroelectric", "水电", "industry", 2, 7, "", "", [RIVER_VALLEY],
     "筑坝蓄水发电，谷地能源充沛，坝下平原的洪水风险反而上升。",
     []),  # numbers live in LEVEL_TERMS
    ("irrigation_grid", "灌溉网", "agrarian", 2, 6, "", "", [],
     "沿河渠铺设灌区，周围农业得到稳定水源，全国渠系维护成本上升。", []),
    ("cooperative", "合作社", "agrarian", 2, 7, "", "", [],
     "合作社社员占比越高的地块农业越兴盛，全国贸易容量却要为内部调剂让路。",
     [(T_CAP, 0.98)]),
    ("industrial_lab", "工业实验室", "learning", 2, 7, "", ELECTRIC, [],
     "距知识支柱 2 格内的工业地块获得工业加成，并以已完成科学科技继续增强，研究成本上升。",
     [(R_COST, 1.02)]),
    ("antitrust", "反垄断", "commerce", 2, 7, "economic_order", "", [],
     "拆分托拉斯、恢复竞争，物价与流通受益，规模效率被牺牲。",
     [(MANU, 0.97)]),
    # X13a. The hot-cell fish/meat/dairy output and national heat-loss cut ship
    # here with the true home-energy cost. L3's hot-market R1 protein demand cut
    # uses the existing tag-source ring selector directly.
    ("refrigeration", "冷链", "commerce", 1, 7, "", "", [],
     "冷库与冷藏运输把暑地的鱼、肉和乳品从腐坏中救回，家用能源开支随之上升。",
     []),

    # X9a. Rich-family prestige growth is a Family-side write; the eminent-clan
    # shortage relief and national trade-capacity price are X9a-expressible.
    ("philanthropy", "慈善", "harmony", 1, 7, "", "", [],
     "名门在短缺时施粮济贫，社会因此安稳，全国调运余量却被摊薄。", []),

    ("progressive_tax", "累进税", "mobilization", 2, 7, "", "", [],
     "重税转福利：劳动者扛得住税，资本方对同样的税率更敏感。", []),

        ("department_store", "百货公司", "commerce", 1, 7, "", "", [],
     "橱窗把货架变成景观，购物变成消遣，家庭开支随之水涨。", []),
    ("offshore_drilling", "海上钻井", "industry", 1, 8, "", "", [OIL],
     "平台立在海面上，原油与天然气从浅海涌出，海岸却被工事占去。",
     [(RUSE(OIL), 1.06)]),
    ("supermarket", "超市", "commerce", 1, 8, "", "", [],
     "一站式自选让采购极省，街坊小店与近郊农事都被挤走。",
     [(CONSUME, 1.02)]),
# ── 原子时代 ────────────────────────────────────────────────────────────
    ("nuclear_power", "核电计划", "industry", 3, 8, "", "", [RARE_EARTH],
     "以核裂变集中供能，能源产出跃升，稀有矿料成为长期负担。",
     [(ENER, 1.08), (G("electricity"), 1.06), (RUSE(RARE_EARTH), 1.08)]),
    # X13a. Cell-level heat-loss semantics and L3's hot-penalty immunity are not
    # readable; do not silently broaden them to national heat loss.
    ("air_conditioning", "空调", "industry", 1, 8, "", "", [],
     "暑地大邑靠机械降温维持生产，凉爽换来更高的家用能源需求。", []),
    ("antibiotics", "抗生素", "harmony", 3, 8, "", "", [],
     "感染不再是绝症，人口的死亡水平被永久压低，医疗投入随之常态化。",
     [(DEATH, 0.92), (INPUT, 1.02)]),
    ("motorization", "汽车社会", "commerce", 2, 8, "", "", [],
     "公路与私家车重构了城市与市场的距离，燃油消耗同步飙升。",
     [(RUSE(OIL), 1.06)]),
    ("green_revolution", "绿色革命", "agrarian", 3, 8, "", "", [GAS],
     "以合成氮肥、良种与灌溉把旱地单产推上台阶，天然气与磷矿被大量吃掉。",
     [(T("plain", "agriculture"), 1.10), (G("fertilizer"), 1.06),
      (RUSE(GAS), 1.08), (RUSE(PHOSPHATE), 1.06)]),
    ("petrochemical", "石化", "industry", 2, 8, "", "", [OIL],
     "以石油为原料生产塑料与合成纤维，原料端成本归零，油田压力加大。",
     [(RUSE(OIL), 1.08)]),
    ("container_port", "集装箱港", "commerce", 2, 8, "", "", [COAST_LF],
     "标准箱与枢纽港把装卸成本压到接近为零，海岸带工厂直接贴上码头，深水泊位造价极高。",
     [(T_CAP, 1.08), (T_SPEED, 1.05), (T("coast", "manufacturing"), 1.05),
      (B_COST, 1.03)]),

    ("tax_holiday", "免税特区", "commerce", 2, 8, "", "", [],
     "指定地块免征营业税，以一块有税基的地换取工业与贸易的聚集。", []),

        ("welfare_state", "福利国家", "mobilization", 3, 8, "", "", [],
     "以社会保障网兜住短缺与失业，税负与行政随之沉重。",
     [(INPUT, 1.03)]),
    ("suburbanization", "郊区化", "commerce", 1, 8, "", "", [],
     "大邑向外摊开，环城地带住得宽，市中心却空了。", []),
    ("family_office", "家族办公室", "commerce", 2, 8, "", "", [],
     "把家族事务交给常设办公室，跨地分支的经验被折算成更便宜的研究，"
     "全国贸易运力却为其让路。", []),
    ("gig_economy", "零工经济", "commerce", 1, 9, "", "", [],
     "按单结算的零工把闲置劳动力接入流通，稳定收入由此消失。", []),
# ── 信息时代 ────────────────────────────────────────────────────────────
    ("computing_networks", "计算网络", "learning", 3, 9, "", "", [],
     "算力与网络成为公共基础设施，研究周期被整体压缩，机房耗电可观。",
     [(B_COST, 1.02)]),
    ("semiconductor", "半导体", "industry", 3, 9, "", "", [SILICA],
     "以高纯硅与精密光刻重塑制造业，硅砂被纯化成稀缺料。",
     [(RUSE(SILICA), 1.08)]),
    ("precision_agriculture", "精准农业", "agrarian", 2, 9, "", "", [],
     "遥感、滴灌与变量施肥让每一块田都按需供给，前期设备投入不小。",
     [(T("plain", "agriculture"), 1.08), (LF("plateau", "agriculture"), 1.06),
      (INPUT, 1.03)]),
    ("financialization", "金融化", "commerce", 3, 9, "economic_order", "", [],
     "以资本运作而非生产获取利润，融资成本极低，实业根基被抽薄。",
     [(T_CAP, 1.06), (R_COST, 0.96), (MANU, 0.96)]),
    ("automation_line", "自动化产线", "industry", 3, 9, "", "", [],
     "以程序控制代替人手，单位产出的物料大幅下降，设备投资却高得惊人。",
     [(INPUT, 0.94), (MANU, 1.06), (B_COST, 1.04)]),
    ("social_media", "社交媒体", "learning", 2, 9, "", "", [],
     "平台把表达与连接压进同一套推荐系统，人口增长带来的理念点被放大，"
     "民意低落时却更难形成共识。", []),

        ("arcology", "生态城", "harmony", 2, 10, "", "", [],
     "立体城把居住、生产与循环挤进一栋楼，造价与资源投入都极高。",
     [(B_COST, 1.04)]),
    ("basic_income", "基本收入", "mobilization", 2, 10, "", "", [],
     "无条件发给每个人一笔钱，短缺消失，财政负担随人口增长。",
     [(INPUT, 1.03)]),
    ("circular_economy", "循环经济", "harmony", 2, 10, "", "", [],
     "废料重新进入生产循环，资源消耗大降，工业产出相应让路。",
     [(MANU, 0.97)]),
# ── 智能时代 ────────────────────────────────────────────────────────────
    ("algorithmic_governance", "算法治理", "learning", 3, 10, "", "", [],
     "以模型分配资源与名额，效率极高，解释权集中，基础科学被挤压。",
     [(R_SOC, 1.06), (POINTS, 1.05), (R_SCI, 0.97)]),
    ("autonomous_logistics", "无人运输", "commerce", 3, 10, "", "", [],
     "无人车与自动调度把运力从人力约束中解放出来，车队与系统投资极高。",
     [(B_COST, 1.03)]),
    ("carbon_market", "碳市场", "harmony", 3, 10, "", "", [],
     "给排放定价，资源耗用被系统性压低，高耗能制造随之收缩。",
     [(RES_USE, 0.92), (MANU, 0.96)]),
    ("gene_editing", "基因编辑", "agrarian", 3, 10, "", "", [MAIZE],
     "定向改造作物性状，主粮单产再上台阶，伦理争议削弱社会共识。",
     [(T("plain", "agriculture"), 1.10), (DEATH, 0.98), (R_SOC, 0.97)]),
    ("vertical_farm", "垂直农场", "agrarian", 3, 10, "", "", [],
     "把农田摞进城市：大邑地块从此刻满足农业支柱条件，能源需求随之上抬。",
     []),
    ("space_mining", "太空采矿", "industry", 3, 10, "", "", [RARE_EARTH],
     "以轨道与机器人开采把矿石条件打通：任一矿石地块都满足其它矿种条件，稀土开采被推高。",
     [(RUSE(RARE_EARTH), 1.08)]),
    ("desalination", "海水淡化", "harmony", 3, 10, "", "", [COAST_LF],
     "以反渗透取得淡水，海岸带可以耕种，耗电与浓盐水排放是代价。",
     [(T("coast", "agriculture"), 1.06), (RREG(FRESHWATER_FISH), 1.06), (INPUT, 1.03)]),
]

# (key, name, [card keys], [(stat, value)])
# A named synergy is the Slay-the-Spire-style payoff: two cards that cover
# different halves of one real causal chain, so the pair is worth more than the
# sum of its parts. Card keys must exist; validate_cards() enforces that.
NAMED_SYNERGIES = [
    # Communal granaries plus a recording office: storage without records rots,
    # records without storage are just paper. Pairing them is what makes the
    # drought buffer real.
    ("granary_records", "仓廪簿籍", ["collective_stewardship", "scholar_office"],
     [(DROUGHT, 0.95), (T("plain", "agriculture"), 1.03)]),
    ("polder_farming", "圩田", ["paddy_cultivation", "water_works"],
     [(PROFILE("paddy_crop", "flood"), 0.92), (LF("delta", "agriculture"), 1.04)]),
    ("mixed_husbandry", "农牧轮转", ["three_field_rotation", "enclosure"],
     [(RREG(PASTURE_LAND), 1.08), (RUSE(FERTILE), 0.94)]),
    ("coal_iron_complex", "煤铁复合体", ["iron_smelting", "coal_basin"],
     [(ENER, 1.04), (GI("coal"), 0.94)]),
    ("postal_canal_grid", "驿漕并网", ["postal_horse", "river_transport"],
     [(T_SPEED, 1.06), (T_CAP, 1.03)]),
    ("joint_stock_accounting", "股份会计", ["double_entry", "ocean_company"],
     [(T_CAP, 1.05), (R_COST, 0.97)]),
    ("steam_rail_complex", "铁汽联动", ["steam_power", "railway_network"],
     [(MANU, 1.04), (T_SPEED, 1.04)]),
    ("chemical_agriculture", "化肥农业", ["agricultural_chemistry", "green_revolution"],
     [(T("plain", "agriculture"), 1.06), (G("fertilizer"), 1.04)]),
    ("electric_assembly", "电气流水线", ["electrification", "assembly_line"],
     [(MANU, 1.06), (ENER, 1.03)]),
    ("digital_automation", "数字自动化", ["computing_networks", "automation_line"],
     [(INPUT, 0.95), (MANU, 1.04)]),
    ("double_constraint", "双重约束", ["ecological_balance", "carbon_market"],
     [(RES_USE, 0.94), (MANU, 0.96)]),
    ("epidemic_defence", "防疫体系", ["public_hygiene", "urban_sanitation"],
     [(DEATH, 0.95), (PROFILE("dryland_crop", "flood"), 0.96)]),
    ("oceanic_finance", "远洋金融", ["maritime_insurance", "chartered_route"],
     [(T_CAP, 1.06), (T_SPEED, 1.04)]),
    ("silk_weaving_chain", "丝织体系", ["sericulture", "household_weaving"],
     [(G("cloth"), 1.05), (G("fine_clothing"), 1.06)]),
    ("experimental_natural_history", "实验博物", ["experimental_method", "natural_history"],
     [(R_SCI, 1.05), (R_AGRI, 1.04)]),
]

# ── build routes (体系) that route-tag bonds count ───────────────────────────
# Must match `IdeologyCatalog.ROUTE_DISPLAY_NAMES`: the ids are the contract, the
# display names are presentation.
ROUTE_TAGS = (
    "cropland", "granary", "mining", "workshop", "market", "thoroughfare",
    "learning", "labor", "livelihood", "clan", "era", "fiscal", "season", "terrain",
)

# school -> (tier-2 terms, tier-4 terms)

# ── 体系羁绊（route bonds）─────────────────────────────────────────────────
# Members are selected by `route_tag`, never enumerated: adding a card to a
# route joins every bond of that route automatically. Two tiers ("2 张" / "4 张")
# because the effect layer has gates, not linear ramps -- the design's
# "每装备 1 张 +X%" is approximated by tiers and both the card text and the doc
# say so.
#
# A tier-2 row may only exist when the route has at least four member cards;
# `IdeologyCatalog` rejects a tier taller than the roster, so the entry is None
# for the short routes instead of silently generating a bond that can never fire.
ROUTE_BONDS = {
    "granary": ("仓廪", [(DEATH, 0.98)], [(DEATH, 0.96), (AGRI, 1.02)]),
    "cropland": ("田垄", [(AGRI, 1.03)], [(AGRI, 1.05), (RUSE(FERTILE), 0.96)]),
    "mining": ("矿冶", [(ENER, 1.03)], [(ENER, 1.05), (RES_USE, 0.97)]),
    "workshop": ("工坊", [(MANU, 1.03)], [(MANU, 1.05), (B_COST, 0.97)]),
    "livelihood": ("生灵", [(RES_USE, 0.97)], [(RES_USE, 0.95), (DEATH, 0.98)]),
    "market": ("市易", [(T_SPEED, 1.03)], None),
    "learning": ("学识", [(R_SCI, 1.03)], None),
    "thoroughfare": ("通衢", [(T_SPEED, 1.02)], None),
}

RESONANCES = {
    "agrarian": ([(AGRI, 1.03)], [(AGRI, 1.04), (RUSE(FERTILE), 0.95)]),
    "commerce": ([(T_CAP, 1.03)], [(T_SPEED, 1.05), (T_CAP, 1.03)]),
    "learning": ([(R_SCI, 1.03), (R_SOC, 1.03)], [(R_COST, 0.95), (POINTS, 1.10)]),
    "mobilization": ([(B_COST, 0.97)], [(DEATH, 0.97), (R_SOC, 1.03)]),
    "industry": ([(MANU, 1.03)], [(INPUT, 0.96), (ENER, 1.03)]),
    "harmony": ([(RES_USE, 0.97)],
                [(DROUGHT, 0.96), (FLOOD, 0.96), (COLD, 0.96), (HEAT, 0.96)]),
}
SCHOOL_NAMES = {"agrarian": "农本", "commerce": "商贸", "learning": "学识",
                "mobilization": "动员", "industry": "工造", "harmony": "调和"}
SCHOOL_ORDER = list(SCHOOL_NAMES)

# Named `PROFILE_COLUMNS`, not `PROFILE`: the latter is the per-production-climate
# hazard stat-key builtin above, and shadowing it meant a card authored below this
# line calling `PROFILE(...)` silently got a dict instead of a stat key.
PROFILE_COLUMNS = {
    "ideology_capacity": 2,
    "national_spirit_capacity": 1,
    "ideology_capacity_max": 6,
    "national_spirit_capacity_max": 3,
    # Every draw is paid: 12 points first, then +20% (12, 14.4, 17.28...).
    # At the daily gain ceiling the first draw needs 24 covered days of growth.
    "offer_cost_q16": 786432,
    "offer_cost_growth_percent": 120,
    "offer_cost_max_q16": 2147483647,
    "reroll_cost_percent": 75,
    "starting_points_q16": 0,
    "max_transition_commands": 256,
    # Catalog declaration budget -- NOT a concurrency budget.
    #
    # Counted once per card effect row that routes through a declared
    # `ideology.effect.*` program, over the whole catalog (card x level x row).
    # The old 128 could not hold a program-backed catalog; 512 then looked
    # sufficient for 85 cards x 3 levels = 255, but the v0.2 target is 179 cards,
    # and two rows per level is already 1074. Live concurrency is a different
    # number entirely: it is bounded by
    #   (ideology_capacity + national_spirit_capacity) x SELECTOR_MAX_CELLS
    # = 9 x 32 = 288 instances, and by EffectRuntime's own `max_instances` (4096).
    # Per-cell fan-out is meant to be aggregated by cell, not by one instance per
    # (card, cell) pair, so this budget must not be used to size that product.
    "max_effect_instances": 2048,
    # About 0.005 point per new resident, 0.0625 per new installed building,
    # 0.0005 per money unit of trade base value, capped at 0.5 per covered day.
    "point_population_weight_q16": 328,
    "point_building_weight_q16": 4096,
    "point_trade_weight_q16": 33,
    "point_gain_cap_q16": 32768,
}
CAPACITY_UNLOCKS = [  # tech, +ideology, +spirit
    (KINGDOM, 1, 0),
    (IMPERIAL, 1, 1),
    (ENLIGHT, 1, 0),
    (INDUSTRIAL, 1, 0),
    (ELECTRIC, 0, 1),
]


def camel(key: str) -> str:
    return "".join(part.capitalize() for part in key.split("_"))


def fmt_value(value: float) -> str:
    text = f"{value:.4f}".rstrip("0")
    return text + "0" if text.endswith(".") else text


def program_row_block(res_id: str, program_key: str, stacks: int) -> str:
    """A card-effect row that routes to a managed program instead of a Modifier.

    `definition_key` MUST be the bare program key: the compiler prefixes it with
    `ideology.effect.` to decide whether the row is owned by the instance path.
    Writing the prefixed form here makes the row look like a legacy Modifier row,
    which silently resolves to an unknown definition at apply time.
    """
    return (f'[sub_resource type="Resource" id="{res_id}"]\n'
            'script = ExtResource("7_effect")\n'
            'action = 1\ndomain = 2\nopcode = 1\ntarget_resolver = 1\nvalue_mode = 1\n'
            'value_q16 = 65536\nduration_days = -1\n'
            f'stacks = {stacks}\n'
            'command_key = &"ideology.persistent"\n'
            f'definition_key = &"{program_key}"\n')


def effect_block(res_id: str, definition_key: str, magnitude: int) -> str:
    return (f'[sub_resource type="Resource" id="{res_id}"]\n'
            'script = ExtResource("7_effect")\n'
            'action = 1\ndomain = 1\nopcode = 1\ntarget_resolver = 1\nvalue_mode = 0\n'
            f'value_q16 = {magnitude}\nduration_days = -1\n'
            'command_key = &"ideology.persistent"\n'
            f'definition_key = &"{definition_key}"\n')


def on_enter_effect_block(res_id: str, row: dict) -> str:
    return (f'[sub_resource type="Resource" id="{res_id}"]\n'
            'script = ExtResource("7_effect")\n'
            f'action = {int(row["action"])}\n'
            f'domain = {int(row["domain"])}\n'
            f'opcode = {int(row["opcode"])}\n'
            f'target_resolver = {int(row["target_resolver"])}\n'
            f'value_mode = {int(row["value_mode"])}\n'
            f'value_q16 = {int(row["value_q16"])}\n'
            f'duration_days = {int(row["duration_days"])}\n'
            f'stacks = {int(row["stacks"])}\n'
            f'command_key = &"{row["command_key"]}"\n'
            f'definition_key = &"{row["definition_key"]}"\n')


# ── managed programs: authoring DSL ──────────────────────────────────────────
# A card level is a list of rows. One row is either the legacy national Modifier
# row (`LEGACY`) or a `Prog`, which the Effect runtime reconciles into one
# instance per resolved target cell and re-emits when the target set or the
# published metrics change.
LEGACY = "legacy"

# Condition ops, mirrored from EffectRuntime::ConditionOp. Kept as names so the
# table reads like the card text instead of like machine codes.
COND_TRUE = 1
COND_METRIC_GTE = 2
COND_METRIC_LTE = 3
COND_METRIC_EQ = 4
COND_STATE_GTE = 5
COND_AND = 6
COND_OR = 7
COND_NOT = 8

STATE_LEVEL = 0
STATE_FIRE_SEQUENCE = 1
STATE_INPUT_REVISION = 2
STATE_REMAINING_DAYS = 3
STATE_STACK_COUNT = 4
STATE_LATCHED = 5

# Selector kinds, mirrored from EffectRuntime::TargetSelectorKind.
SEL_OWNER = 0
SEL_SOURCE_CELL = 2
SEL_SOURCE_COUNTRY = 3
SEL_NEIGHBORS_R1 = 6
SEL_NEIGHBORS_R2 = 7
SEL_SAME_TERRAIN_COMPONENT = 8
SEL_SAME_RESOURCE_COMPONENT = 9
SEL_PREDICATE_ANY_CELL = 10
SEL_DISTANCE_N = 11
SEL_OWN_TERRITORY = 12
SEL_TAG_ANY_CELL = 13
## X1: per-source radial. `tags` selects the SOURCE cells among the country's
## own territory; each source contributes its R1/R2 neighbours and the union is
## capped. This is the only way to write "主产铁的地块 → 周围 1 格".
SEL_TAG_SOURCE_R1 = 14
SEL_TAG_SOURCE_R2 = 15
## X1-b: per-source COUNT, stacked. Same source-tag walk as 14/15, but instead of
## unioning one shared bonus each target cell gets `min(count, cap)` sources' worth.
## `converted to magnitude_scale_q16 = min(count, cap) / cap` with the program's
## `value_q16 = per_source × cap` (see 09-content-status.md §7.2 / §7.4).
##
## `param[0]` is BIT-PACKED because the POD carries exactly two int32 slots
## (`effect_runtime.h`: `int32_t target_selector_param[2]`):
##   bits 0-4  target cell cap (5 bits, 1..31, 0 = default 32)
##   bits 5-7  radius           (3 bits, 1..4)
##   bits 8-11 source count cap (4 bits, 1..15)
## `param[1]` is the source tag id (16 bits, 1-based), same slot as kinds 12/13/14/15.
SEL_TAG_SOURCE_COUNT = 16
## X9-b: resolve families with at least `param[1]` active branches to stable
## family handles. `param[0]` is the family cap; the command binds that stable
## handle as a Modifier ECONOMY ENTITY so only the family's owned buildings move.
SEL_FAMILY_OWNED = 17
SELECTOR_MAX_KIND = SEL_FAMILY_OWNED

# Bit layout constants (mirrored in `pack_source_count` and the C++ decoder).
SC_TARGET_CAP_BITS = 0x1F
SC_RADIUS_SHIFT = 5
SC_RADIUS_BITS = 0x07
SC_COUNT_CAP_SHIFT = 8
SC_COUNT_CAP_BITS = 0x0F
SC_TAG_MASK = 0xFFFF


def pack_source_count(target_cap: int, radius: int, count_cap: int,
                      tag_id: int) -> tuple[int, int]:
    """Pack kind 16's four parameters into the two POD int slots.

    `target_cap` is 5 bits, which cannot hold 32 -- and 32 is the value every
    programme inherits by default (`Prog.selector_cap = 32`). So the field stores
    the cap as-is only for 1..31, and **0 means "the default 32"**, exactly like
    `param[0]` already means "take the runtime default" for the other selectors.

    Values are NOT clamped: `validate_programs` rejects anything out of range so a
    bad card fails generation instead of losing its radius in a shifted bit field.
    """
    if not 0 <= target_cap <= SC_TARGET_CAP_BITS:
        raise ValueError(
            f"target_cap {target_cap} does not fit 5 bits (0 means default 32)")
    if not 1 <= radius <= SC_RADIUS_BITS:
        raise ValueError(f"radius {radius} does not fit 3 bits")
    if not 1 <= count_cap <= SC_COUNT_CAP_BITS:
        raise ValueError(f"count_cap {count_cap} does not fit 4 bits")
    if not 1 <= tag_id <= SC_TAG_MASK:
        raise ValueError(f"tag_id {tag_id} does not fit 16 bits")
    packed = ((target_cap & SC_TARGET_CAP_BITS)
              | ((radius & SC_RADIUS_BITS) << SC_RADIUS_SHIFT)
              | ((count_cap & SC_COUNT_CAP_BITS) << SC_COUNT_CAP_SHIFT))
    return packed, tag_id & SC_TAG_MASK


def unpack_source_count(packed: int, tag_slot: int) -> tuple[int, int, int, int]:
    """Inverse of `pack_source_count`; used by the T11 round-trip assertion."""
    target_cap = packed & SC_TARGET_CAP_BITS
    if target_cap == 0:
        target_cap = 32
    return (target_cap, (packed >> SC_RADIUS_SHIFT) & SC_RADIUS_BITS,
            (packed >> SC_COUNT_CAP_SHIFT) & SC_COUNT_CAP_BITS, tag_slot & SC_TAG_MASK)

STACK_REPLACE = 0
STACK_REFRESH = 1
STACK_ADD_STACK = 2

DOMAIN_CELL = 2
DOMAIN_COUNTRY = 3
DOMAIN_FAMILY = 0


@dataclass(frozen=True)
class Meta:
    """Per-card authoring metadata that is not part of the ten-tuple."""
    route: str = ""
    secondary: tuple[str, ...] = ()
    slot: int = 1
    spirit: int = 1


@dataclass(frozen=True)
class Cmd:
    """One modifier command a program emits per target.

    `value` is a signed fraction for card programs (+0.05 = +5%). Diagnostics
    that need an exact strength instead of a fraction pass `magnitude_q16`.
    """
    modifier: str                 # definition key, e.g. "ideology.city.birth_factor"
    value: float = 0.0
    duration_days: int = -1
    stacks: int = 1
    domain: int | None = None
    magnitude_q16: int | None = None


@dataclass(frozen=True)
class Cond:
    op: int
    arg0: int = 0
    value_q16: int = 0


@dataclass(frozen=True)
class Ramp:
    """Linear magnitude: `value = per * min(metric, cap)`.

    THE UNIT CONTRACT -- read this before authoring a ramp:

      * `per` is a FRACTION of gain per ONE unit of the metric, already in the
        "×1.06 means +6%" space. So "每 1 个百分点 +1%" is `per=0.01`, not 1.0,
        and "每 1 座建筑 +2%" is `per=0.02`.
      * `cap` is expressed in THE METRIC'S OWN UNIT -- it caps the metric reading,
        not the result. A metric that is itself a 0..1 ratio (`*_q16`) is capped
        with a value ≤ 1.0; a count metric is capped with a count.
      * the RESULT `per * cap` is a fraction too, and must stay ≤ 1.0 (+100%);
        anything larger cannot survive `MAX_MAGNITUDE_Q16` anyway.

    Getting these wrong is silent: `per=1.0, cap=15` on a 0..1 metric reads
    "every point of unemployment" as "every 100 points", which multiplies the card
    by 100 and then clamps. That is a unit bug, not a balance number, so
    `validate_ramp_units()` hard-fails it.

    The effect runtime already has the whole instruction set for this
    (READ_METRIC / MIN / MUL_Q16 / EMIT with VALUE_STACK_TOP), and
    `family_effect_metadata_pod` already unions READ_METRIC ids into the metric
    mask -- so "每有 1 个 X，+1%（上限 +N）" needs authorship, not engine work.
    """

    metric: str
    per: float = 0.01
    cap: float = 15.0


@dataclass(frozen=True)
class RampTerm:
    """A LEVEL_TERMS row whose magnitude is a ramp, not a constant.

    `stat` is the Modifier key the ramp drives; `ramp` says how. Kept as its own
    type rather than a `("RAMP", Ramp)` tuple so the lints can still see the stat
    key: a tuple would make `_is_downside` compare a `Ramp` against a float and
    crash, which is exactly what happened on the first attempt.

    Only meaningful for a card that also declares the ramped metric as a
    `requires=` capability -- the metric does not exist until that lands.
    """

    stat: str
    ramp: Ramp


@dataclass(frozen=True)
class Prog:
    """One managed effect program."""
    key: str
    summary: str
    tags: tuple[str, ...] = ()
    cmds: tuple[Cmd, ...] = ()
    conds: tuple[Cond, ...] = ()
    selector: int = SEL_OWN_TERRITORY
    selector_cap: int = 32
    selector_param1: int = 0
    stack_policy: int = STACK_REPLACE
    max_stacks: int = 1
    stacks: int = 1
    lifecycle: int = 0
    duration_days: int = -1
    target_domain: int = DOMAIN_CELL
    priority: int = 0
    ramp: Ramp | None = None
    # ── X1-b (kind 16) only; zero elsewhere ────────────────────────────────
    # `radius` = hex distance, `cap` = source-count ceiling, `per_source` = the
    # per-source fraction. See 09-content-status.md §7.6. `per_source × cap` is the
    # program's `value_q16`; the runtime scales each instance by
    # `min(count, cap) / cap`.
    radius: int = 0
    cap: int = 0
    per_source: float | None = None


def mod(modifier: str, value: float, **kwargs) -> Cmd:
    return Cmd(modifier=modifier, value=value, **kwargs)


def prog(key: str, summary: str, **kwargs) -> Prog:
    return Prog(key=key, summary=summary, **kwargs)


## X5 rewrite fields. Kept in one place so the generator lint and the emitter
## cannot disagree about which field a row targets.
REWRITE_SCALE = 4
REWRITE_TAG = 5
REWRITE_SELECTOR_KIND = 6
REWRITE_SELECTOR_CAP = 7
MATCH_PROGRAM = 0
MATCH_TAG = 1
MATCH_ROUTE = 2


@dataclass(frozen=True)
class Rewrite:
    """One X5 per-country program rewrite.

    Exactly one match selector is set. `value` is the rewrite value for
    SELECTOR_KIND / SELECTOR_CAP / MAGNITUDE_SCALE; `tag` is the replacement for
    a TAG rewrite (`a|b` means "a OR b").
    """

    match_program: str = ""
    match_tag: str = ""
    match_route: str = ""
    value: int = 0
    tag: str = ""
    field: int = 0

    def match_kind(self) -> int:
        set_matches = sum(bool(value) for value in (
            self.match_program, self.match_tag, self.match_route))
        if set_matches != 1:
            raise SystemExit(
                f"rewrite: exactly one match selector is required, got "
                f"{self.match_program!r}/{self.match_tag!r}/{self.match_route!r}")
        if self.match_program:
            return MATCH_PROGRAM
        if self.match_tag:
            return MATCH_TAG
        return MATCH_ROUTE

    def match_value(self) -> str:
        return self.match_program or self.match_tag or self.match_route


def rewrite_program(program: str, field: int, value: int = 0,
                    tag: str = "") -> Rewrite:
    return Rewrite(match_program=program, field=field, value=value, tag=tag)


def rewrite_tag(match_tag: str, tag: str) -> Rewrite:
    return Rewrite(match_tag=match_tag, field=REWRITE_TAG, tag=tag)


def rewrite_route(route: str, field: int, value: int = 0,
                  tag: str = "") -> Rewrite:
    return Rewrite(match_route=route, field=field, value=value, tag=tag)


def cell(pct: float) -> float:
    """Authoring sugar: `cell(5)` is +5%, `cell(-8)` is -8%."""
    return pct / 100.0


_METRIC_KEYS_CACHE: list[str] | None = None


def metric_keys() -> list[str]:
    """`effect_domain_catalog.gd`'s dense metric table, in id order.

    The Economy prefix is the literal array in `build`; ideology-local scalars
    are appended from `SCALAR_METRIC_KEYS`. Parse both so a generated program
    that references a scalar resolves the same id the native runtime publishes.
    """
    global _METRIC_KEYS_CACHE
    if _METRIC_KEYS_CACHE is None:
        text = EFFECT_DOMAIN_CATALOG_PATH.read_text(encoding="utf-8")
        body = text.split("catalog.metric_keys = PackedStringArray([", 1)[1]
        body = body.split("])", 1)[0]
        keys = []
        for line in body.splitlines():
            match = re.search(r'"([a-z0-9_.]+)"', line)
            if match:
                keys.append(match.group(1))
        scalar_body = text.split("const SCALAR_METRIC_KEYS := [", 1)[1]
        scalar_body = scalar_body.split("]", 1)[0]
        for line in scalar_body.splitlines():
            match = re.search(r'"([a-z0-9_.]+)"', line)
            if match:
                keys.append(match.group(1))
        _METRIC_KEYS_CACHE = keys
    return _METRIC_KEYS_CACHE


def metric_id(key: str) -> int:
    keys = metric_keys()
    if key not in keys:
        raise SystemExit(f"unknown metric key: {key}")
    return keys.index(key)


def metric_available(key: str) -> bool:
    """True when `effect_domain_catalog.gd` already declares this metric.

    Used only by cards that are STAGED on the metric existing (currently metric 68
    `cell.net_tax_burden_q16`, design doc §47.9, C++ owned by session R). A staged
    card's program may not be built before its metric id exists -- `metric_id()`
    would hard-fail generation -- so the row is authored behind this check and the
    card is held out of the catalog by `CARD_REQUIRES` in the meantime.
    """
    return key in metric_keys()


def cond_metric_gte(key: str, value_q16: int) -> Cond:
    return Cond(COND_METRIC_GTE, metric_id(key), value_q16)


def cond_metric_lte(key: str, value_q16: int) -> Cond:
    return Cond(COND_METRIC_LTE, metric_id(key), value_q16)


def cond_metric_eq(key: str, value_q16: int) -> Cond:
    return Cond(COND_METRIC_EQ, metric_id(key), value_q16)


def cond_state_gte(state: int, value_q16: int) -> Cond:
    return Cond(COND_STATE_GTE, state, value_q16)


def _pct(pct: float) -> int:
    return int(round(pct / 100.0 * Q16))


# ── diagnostics: the six mechanism probes ────────────────────────────────────
# These are not balance content. Each one exercises a different shape of the
# declarative program pipeline, and they stay in the catalog because
# `ideology_mechanism_matrix_test` pins them. They are now generated instead of
# hand-written, so the file the runtime reads has exactly one author.
DIAGNOSTIC_PROGRAMS = [
    prog("v1_granary_belt", "诊断：理解度二级时全国农业 +60%",
         target_domain=DOMAIN_COUNTRY, selector=SEL_OWNER,
         conds=(cond_state_gte(STATE_LEVEL, int(2.0 * Q16)),),
         cmds=(Cmd("ideology.agrarian_reform", magnitude_q16=104858, domain=1),)),
    prog("v2_forge_ring", "诊断：邻域 R1 制造业 +0%",
         selector=SEL_NEIGHBORS_R1, selector_cap=8,
         cmds=(Cmd("family.city.manufacturing_output_boost", magnitude_q16=Q16),)),
    prog("v3_vein_dominance", "诊断：矿业产出占比 ≥60% 时邻域制造业 +300%",
         selector=SEL_NEIGHBORS_R1, selector_cap=8,
         conds=(cond_metric_gte("cell.sector_output_share.extractive_q16", _pct(60)),),
         cmds=(Cmd("family.city.manufacturing_output_boost", magnitude_q16=262144),)),
    prog("v4_iron_throne", "诊断：资源专精地块 R2 内全城产出 +300%",
         selector=SEL_NEIGHBORS_R2, selector_cap=18,
         conds=(cond_metric_gte("cell.dominant_resource_stock_share_q16", _pct(50)),),
         cmds=(Cmd("family.city.production_boost", magnitude_q16=262144),)),
    prog("v5_stacked_workshop", "诊断：同地形连通块 8 格制造业 +300%",
         selector=SEL_SAME_TERRAIN_COMPONENT, selector_cap=8,
         stack_policy=STACK_ADD_STACK, max_stacks=5, stacks=3,
         conds=(cond_state_gte(STATE_STACK_COUNT, int(3.0 * Q16)),),
         cmds=(Cmd("family.city.manufacturing_output_boost", magnitude_q16=262144),)),
    prog("v6_guild_monopoly", "诊断：双条件 AND 时距离 3 的 8 格能源 +200%",
         selector=SEL_DISTANCE_N, selector_cap=8, selector_param1=3,
         stack_policy=STACK_ADD_STACK, max_stacks=4, stacks=2,
         conds=(cond_metric_gte("cell.dominant_sector_output_share_q16", _pct(50)),
                cond_state_gte(STATE_STACK_COUNT, int(2.0 * Q16))),
         cmds=(Cmd("family.city.energy_output_boost", magnitude_q16=196608),)),
    # X14 condition probe. Metric 77 is the most-used class (general), the only
    # class id that fits beside the weighted country value in 77..78.
    prog("v9_class_gate", "诊断：首都主导阶层民心 ≥50% 时农业 +1%",
         selector=SEL_OWNER, selector_cap=1,
         conds=(cond_metric_gte(
             "country.class_satisfaction_q16", int(0.5 * Q16)),),
         cmds=(mod(city_stat_key("building.agriculture_output_factor"), cell(1)),)),
    # X10 condition probe. A worker fixture arms the program after normal epoch
    # capture, so it observes the frozen country technology counts directly.
    prog("v10_technology_gate",
         "诊断：国家已完成科技 ≥1 时首都农业 +1%",
         selector=SEL_OWNER, selector_cap=1,
         conds=(cond_metric_gte(
             "country.completed_tech_count", int(1.0 * Q16)),),
         cmds=(mod(city_stat_key("building.agriculture_output_factor"), cell(1)),)),
]

# ── per-card authoring ───────────────────────────────────────────────────────
# Cards absent here keep the pre-existing national-Modifier path byte for byte.
CARD_META: dict[str, Meta] = {}

# card key -> exactly three levels; each level is an ordered list of rows.
# A row is a `Prog`; the card's own `terms` stay in CARDS and are emitted as ONE
# legacy cost row per level at magnitude 1.0 ("the price does not grow with the
# level; the benefit does").
LEVEL_ROWS: dict[str, list[list[Prog]]] = {}

# card key -> exactly three levels of X5 rewrites. A level emits one hidden
# self-synergy carrying that level's rows, so L3 activation also picks up L1/L2
# (the native conflict rule resolves per field by highest minimum level).
LEVEL_REWRITES: dict[str, list[list[Rewrite]]] = {}

# card key -> exactly three levels of *national* terms, in the legacy shape
# `[(stat_key, value), ...]`. Only for cards that are entirely national (no
# `Prog` rows): the design doc gives those cards different numbers per level
# (`L2：+15%`), and the old emitter could not express that -- it wrote ONE row at
# magnitude 1.0/1.6/2.2, so L2 was always "L1 x 1.6" rather than the authored
# value. A card listed here is emitted from this table instead of from `CARDS`;
# the `CARDS` term list stays the L1 fallback for the presenter and the lint.
LEVEL_TERMS: dict[str, list[list[tuple[str, float]]]] = {}

# Definition ids that exist ONLY to carry an `operation = Add` term. The family
# generator in `modifier_blocks` can only emit `Multiply` (`operation = 2`) rows
# in the `x` slot, which cannot express "税率 +3 个百分点" -- a multiplier of
# 1.03 on a 0.10 rate adds 0.3 percentage points, not 3.
ADD_TERMS: dict[str, list[tuple[str, float]]] = {}

# ── first gate: one real production card, end to end ────────────────────────
# 公共卫生 is the card §22 asks for: pure SELF shape (a tag on the cell the
# effect lands on), no X1 dependency, and two commands in one program so the
# per-command magnitude path is exercised. Its cost stays national (build cost),
# which is also what keeps a text line on the card for the legacy presenter.
CARD_META["public_hygiene"] = Meta(route="granary")
CARD_META["mandate_of_heaven"] = Meta(route="season")
CARD_REQUIRES["mandate_of_heaven"] = ("X13a", "X5")
LEVEL_ROWS["public_hygiene"] = [
    [prog("public_hygiene_l1",
          "聚落地块（最多 32 格）：出生率 +5%，住房需求 -8%",
          tags=("cell.settlement",),
          cmds=(mod(city_stat_key("birth_factor"), cell(5)),
                mod(city_stat_key("need.housing.consumption_factor"), cell(-8))))],
    [prog("public_hygiene_l2",
          "聚落地块（最多 32 格）：出生率 +8%，住房需求 -10%",
          tags=("cell.settlement",),
          cmds=(mod(city_stat_key("birth_factor"), cell(8)),
                mod(city_stat_key("need.housing.consumption_factor"), cell(-10))))],
    [prog("public_hygiene_l3",
          "聚落地块（最多 32 格）：出生率 +9%，住房需求 -11%",
          tags=("cell.settlement",),
          cmds=(mod(city_stat_key("birth_factor"), cell(9)),
                mod(city_stat_key("need.housing.consumption_factor"), cell(-11))))],
]

# ── cell-level cards expressible with the current selector + tag table ──────
# Every card here has a tag that names the population it affects, so the hit set
# is "the cells that match", not "the first 32 owned cells". Cards whose design
# needs "each source cell -> its neighbourhood" are absent on purpose: that is
# X1, and faking it with the anchor-only selector would silently apply the card
# to the country's first cell and nowhere else.
#
# The card's own `terms` keep only the price. The benefit lives in the program,
# so the same effect cannot be counted twice.

CARD_META["urban_sanitation"] = Meta(route="granary")
_sanitation = ["空气与水一起治理，拥挤不再自我毒害。"]
LEVEL_ROWS["urban_sanitation"] = [
    [prog("urban_sanitation_l1", "大邑地块（最多 32 格）：全部产出 +8%",
          tags=("cell.metropolis",),
          cmds=(mod(city_stat_key("output_factor"), cell(8)),))],
    [prog("urban_sanitation_l2", "大邑地块（最多 32 格）：全部产出 +12%",
          tags=("cell.metropolis",),
          cmds=(mod(city_stat_key("output_factor"), cell(12)),))],
    [prog("urban_sanitation_l3", "大邑地块（最多 32 格）：全部产出 +14%",
          tags=("cell.metropolis",),
          cmds=(mod(city_stat_key("output_factor"), cell(14)),))],
]

CARD_META["settle_and_farm"] = Meta(route="granary")
LEVEL_ROWS["settle_and_farm"] = [
    [prog("settle_and_farm_l1", "边地农业地块（最多 32 格）：农业 +15%，出生率 +8%",
          tags=("cell.frontier", "cell.sector.agriculture"),
          cmds=(mod(city_stat_key("building.agriculture_output_factor"), cell(15)),
                mod(city_stat_key("birth_factor"), cell(8))))],
    [prog("settle_and_farm_l2", "边地农业地块（最多 32 格）：农业 +20%，出生率 +10%",
          tags=("cell.frontier", "cell.sector.agriculture"),
          cmds=(mod(city_stat_key("building.agriculture_output_factor"), cell(20)),
                mod(city_stat_key("birth_factor"), cell(10))))],
    [prog("settle_and_farm_l3", "边地农业地块（最多 32 格）：农业 +22%，出生率 +11%",
          tags=("cell.frontier", "cell.sector.agriculture"),
          cmds=(mod(city_stat_key("building.agriculture_output_factor"), cell(22)),
                mod(city_stat_key("birth_factor"), cell(11))))],
]

CARD_META["three_field_rotation"] = Meta(route="cropland")
LEVEL_ROWS["three_field_rotation"] = [
    [prog("three_field_rotation_l1", "农业支柱地块（最多 32 格）：肥沃土壤再生 +20%",
          tags=("cell.sector.agriculture",),
          cmds=(mod(city_stat_key("resource.fertile_soil.regen_factor"), cell(20)),))],
    [prog("three_field_rotation_l2", "农业支柱地块（最多 32 格）：肥沃土壤再生 +30%",
          tags=("cell.sector.agriculture",),
          cmds=(mod(city_stat_key("resource.fertile_soil.regen_factor"), cell(30)),))],
    [prog("three_field_rotation_l3", "农业支柱地块（最多 32 格）：肥沃土壤再生 +35%",
          tags=("cell.sector.agriculture",),
          cmds=(mod(city_stat_key("resource.fertile_soil.regen_factor"), cell(35)),))],
]

CARD_META["coal_basin"] = Meta(route="mining")
LEVEL_ROWS["coal_basin"] = [
    [prog("coal_basin_l1", "矿业支柱地块（最多 32 格）：矿业产出 +20%",
          tags=("cell.sector.extractive",),
          cmds=(mod(city_stat_key("building.extractive_output_factor"), cell(20)),))],
    [prog("coal_basin_l2", "矿业支柱地块（最多 32 格）：矿业产出 +28%",
          tags=("cell.sector.extractive",),
          cmds=(mod(city_stat_key("building.extractive_output_factor"), cell(28)),))],
    [prog("coal_basin_l3", "矿业支柱地块（最多 32 格）：矿业产出 +32%",
          tags=("cell.sector.extractive",),
          cmds=(mod(city_stat_key("building.extractive_output_factor"), cell(32)),))],
]

CARD_META["standardization"] = Meta(route="workshop")
LEVEL_ROWS["standardization"] = [
    [prog("standardization_l1", "成链地块（最多 32 格）：工业产出 +8%",
          tags=("cell.chained",),
          cmds=(mod(city_stat_key("building.manufacturing_output_factor"), cell(8)),))],
    [prog("standardization_l2", "成链地块（最多 32 格）：工业产出 +12%",
          tags=("cell.chained",),
          cmds=(mod(city_stat_key("building.manufacturing_output_factor"), cell(12)),))],
    [prog("standardization_l3", "成链地块（最多 32 格）：工业产出 +16%",
          tags=("cell.chained",),
          cmds=(mod(city_stat_key("building.manufacturing_output_factor"), cell(16)),))],
]

CARD_META["free_exchange"] = Meta(route="market")
LEVEL_ROWS["free_exchange"] = [
    [prog("free_exchange_l1", "多元地块（最多 32 格）：全部产出 +6%",
          tags=("cell.diversified",),
          cmds=(mod(city_stat_key("output_factor"), cell(6)),))],
    [prog("free_exchange_l2", "多元地块（最多 32 格）：全部产出 +9%",
          tags=("cell.diversified",),
          cmds=(mod(city_stat_key("output_factor"), cell(9)),))],
    [prog("free_exchange_l3", "多元地块（最多 32 格）：全部产出 +12%",
          tags=("cell.diversified",),
          cmds=(mod(city_stat_key("output_factor"), cell(12)),))],
]

CARD_META["antitrust"] = Meta(route="market")
# Two programs on one level: the bonus and the penalty name different cell
# populations, and one program can only carry one selector.
LEVEL_ROWS["antitrust"] = [
    [prog("antitrust_l1_bonus", "多元地块（最多 32 格）：全部产出 +8%",
          tags=("cell.diversified",),
          cmds=(mod(city_stat_key("output_factor"), cell(8)),)),
     prog("antitrust_l1_penalty", "高度专精地块（最多 32 格）：全部产出 -5%",
          tags=("cell.specialized_high",),
          cmds=(mod(city_stat_key("output_factor"), cell(-5)),))],
    [prog("antitrust_l2_bonus", "多元地块（最多 32 格）：全部产出 +12%",
          tags=("cell.diversified",),
          cmds=(mod(city_stat_key("output_factor"), cell(12)),)),
     prog("antitrust_l2_penalty", "高度专精地块（最多 32 格）：全部产出 -5%",
          tags=("cell.specialized_high",),
          cmds=(mod(city_stat_key("output_factor"), cell(-5)),))],
    [prog("antitrust_l3_bonus", "多元地块（最多 32 格）：全部产出 +12%",
          tags=("cell.diversified",),
          cmds=(mod(city_stat_key("output_factor"), cell(12)),)),
     prog("antitrust_l3_penalty", "高度专精地块（最多 32 格）：全部产出 -3%",
          tags=("cell.specialized_high",),
          cmds=(mod(city_stat_key("output_factor"), cell(-3)),))],
]

CARD_META["coppice_rotation"] = Meta(route="livelihood")
# The whole price of this card is a cell-level cut, so it carries no cost term:
# `validate_cards` accepts that only when a program really has a negative row.
LEVEL_ROWS["coppice_rotation"] = [
    [prog("coppice_rotation_l1", "主产原木的地块（最多 32 格）：木材再生 +20%，原木产出 -6%",
          tags=("cell.produces.lumber",),
          cmds=(mod(city_stat_key("resource.timber.regen_factor"), cell(20)),
                mod(city_stat_key("good.lumber.output_factor"), cell(-6))))],
    [prog("coppice_rotation_l2", "主产原木的地块（最多 32 格）：木材再生 +30%，原木产出 -6%",
          tags=("cell.produces.lumber",),
          cmds=(mod(city_stat_key("resource.timber.regen_factor"), cell(30)),
                mod(city_stat_key("good.lumber.output_factor"), cell(-6))))],
    [prog("coppice_rotation_l3", "主产原木的地块（最多 32 格）：木材再生 +30%，原木产出 -3%",
          tags=("cell.produces.lumber",),
          cmds=(mod(city_stat_key("resource.timber.regen_factor"), cell(30)),
                mod(city_stat_key("good.lumber.output_factor"), cell(-3))))],
]

CARD_META["ecological_balance"] = Meta(route="livelihood")
LEVEL_ROWS["ecological_balance"] = [
    [prog("ecological_balance_l1_rich", "富饶地块（最多 32 格）：全部产出 +10%",
          tags=("cell.abundant",),
          cmds=(mod(city_stat_key("output_factor"), cell(10)),)),
     prog("ecological_balance_l1_dry", "枯竭地块（最多 32 格）：全部产出 -5%",
          tags=("cell.depleted",),
          cmds=(mod(city_stat_key("output_factor"), cell(-5)),))],
    [prog("ecological_balance_l2_rich", "富饶地块（最多 32 格）：全部产出 +14%",
          tags=("cell.abundant",),
          cmds=(mod(city_stat_key("output_factor"), cell(14)),)),
     prog("ecological_balance_l2_dry", "枯竭地块（最多 32 格）：全部产出 -5%",
          tags=("cell.depleted",),
          cmds=(mod(city_stat_key("output_factor"), cell(-5)),))],
    # L3 removes the penalty entirely: one program, not two.
    [prog("ecological_balance_l3_rich", "富饶地块（最多 32 格）：全部产出 +14%，枯竭惩罚取消",
          tags=("cell.abundant",),
          cmds=(mod(city_stat_key("output_factor"), cell(14)),))],
]

CARD_META["computing_networks"] = Meta(route="learning")
LEVEL_ROWS["computing_networks"] = [
    [prog("computing_networks_l1", "知识支柱地块（最多 32 格）：知识产出 +20%",
          tags=("cell.sector.knowledge",),
          cmds=(mod(city_stat_key("building.knowledge_output_factor"), cell(20)),))],
    [prog("computing_networks_l2", "知识支柱地块（最多 32 格）：知识产出 +25%",
          tags=("cell.sector.knowledge",),
          cmds=(mod(city_stat_key("building.knowledge_output_factor"), cell(25)),))],
    [prog("computing_networks_l3", "知识支柱地块（最多 32 格）：知识产出 +30%",
          tags=("cell.sector.knowledge",),
          cmds=(mod(city_stat_key("building.knowledge_output_factor"), cell(30)),))],
]

CARD_META["ever_normal_granary"] = Meta(route="granary")
LEVEL_ROWS["ever_normal_granary"] = [
    [prog("ever_normal_granary_l1", "短缺地块（最多 32 格）：主食需求 -15%",
          tags=("cell.shortage",),
          cmds=(mod(city_stat_key("need.staple_food.consumption_factor"), cell(-15)),))],
    [prog("ever_normal_granary_l2", "短缺地块（最多 32 格）：主食需求 -20%",
          tags=("cell.shortage",),
          cmds=(mod(city_stat_key("need.staple_food.consumption_factor"), cell(-20)),))],
    [prog("ever_normal_granary_l3", "短缺地块（最多 32 格）：主食需求 -22%",
          tags=("cell.shortage",),
          cmds=(mod(city_stat_key("need.staple_food.consumption_factor"), cell(-22)),))],
]

CARD_META["terrace_farming"] = Meta(route="cropland")
CARD_META["water_works"] = Meta(route="cropland", secondary=("thoroughfare",))
CARD_META["forager_band"] = Meta(route="livelihood")
CARD_META["riverside_camp"] = Meta(route="cropland")
CARD_META["seasonal_calendar"] = Meta(route="season")
CARD_META["pit_dwelling"] = Meta(route="granary")
CARD_META["hydroelectric"] = Meta(route="terrain")
CARD_META["land_tax_reform"] = Meta(route="fiscal")
CARD_META["excise"] = Meta(route="fiscal")
CARD_META["frontier_garrison"] = Meta(route="granary")
CARD_META["kin_hearth"] = Meta(route="clan")
CARD_META["clan_fields"] = Meta(route="clan")
CARD_META["merchant_houses"] = Meta(route="clan")
CARD_META["family_enterprise"] = Meta(route="clan")
CARD_META["marriage_alliance"] = Meta(route="clan")
CARD_META["philanthropy"] = Meta(route="clan")
CARD_META["frost_lore"] = Meta(route="season")
CARD_META["little_ice_age"] = Meta(route="season")
CARD_META["refrigeration"] = Meta(route="granary")
CARD_META["air_conditioning"] = Meta(route="season")
CARD_META["drought_relief"] = Meta(route="granary")

# ── X13a climate cards ──────────────────────────────────────────────────────
# These publish only the clauses expressible with annual-temperature tags,
# today's hazard mask, metric conditions, and existing selectors. Timed
# after-hazard buffs and event-count doubling remain staged on X4/X5.
CARD_REQUIRES["frost_lore"] = ("X13a",)
CARD_REQUIRES["little_ice_age"] = ("X13a",)
CARD_REQUIRES["refrigeration"] = ("X13a",)
CARD_REQUIRES["air_conditioning"] = ("X13a",)
CARD_REQUIRES["drought_relief"] = ("X13a",)

# ── X9a family cards ───────────────────────────────────────────────────────
# The published rows use only branch-count / branch-prestige metrics, the
# cell.clan / cell.eminent_clan tags, and existing metric conditions. Clauses
# that need neighbourhood counts, timed events, or Family-side writes are
# called out one line above the rows that stage them.
CARD_REQUIRES["kin_hearth"] = ("X9a",)
CARD_REQUIRES["clan_fields"] = ("X9a",)
CARD_REQUIRES["merchant_houses"] = ("X9a",)
CARD_REQUIRES["family_enterprise"] = ("X9a",)
LEVEL_ROWS["kin_hearth"] = [
    [prog("kin_hearth_l1",
          "宗族地块（最多 32 格）：出生率 +6%，住房需求 +5%",
          tags=("cell.clan",),
          cmds=(mod(city_stat_key("birth_factor"), cell(6)),
                mod(city_stat_key("need.housing.consumption_factor"), cell(5))))],
    [prog("kin_hearth_l2",
          "宗族地块（最多 32 格）：出生率 +9%，住房需求 +5%",
          tags=("cell.clan",),
          cmds=(mod(city_stat_key("birth_factor"), cell(9)),
                mod(city_stat_key("need.housing.consumption_factor"), cell(5))))],
    [prog("kin_hearth_l3",
          "宗族地块（最多 32 格）：出生率 +9%，住房需求 +5%",
          tags=("cell.clan",),
          cmds=(mod(city_stat_key("birth_factor"), cell(9)),
                mod(city_stat_key("need.housing.consumption_factor"), cell(5)))),
     prog("kin_hearth_l3_eminent",
          "名门地块（最多 32 格）：全部产出 +3%",
          tags=("cell.eminent_clan",),
          cmds=(mod(city_stat_key("output_factor"), cell(3)),))],
]

CARD_REQUIRES["clan_fields"] = ("X9a",)
# "Two family buildings on one cell" and the L3 prestige write need X9-b.
LEVEL_ROWS["clan_fields"] = [
    [prog("clan_fields_l1",
          "显赫宗族的农业地块（最多 32 格）：农业产出 +12%",
          tags=("cell.eminent_clan", "cell.sector.agriculture"),
          cmds=(mod(city_stat_key("building.agriculture_output_factor"),
                    cell(12)),)),
     prog("clan_fields_l1_penalty",
          "无家产农业地块（最多 32 格）：农业产出 -5%",
          tags=("cell.sector.agriculture",),
          conds=(cond_metric_eq("cell.family_asset_share_q16", 0),),
          cmds=(mod(city_stat_key("building.agriculture_output_factor"),
                    cell(-5)),))],
    [prog("clan_fields_l2",
          "显赫宗族的农业地块（最多 32 格）：农业产出 +16%",
          tags=("cell.eminent_clan", "cell.sector.agriculture"),
          cmds=(mod(city_stat_key("building.agriculture_output_factor"),
                    cell(16)),)),
     prog("clan_fields_l2_penalty",
          "无家产农业地块（最多 32 格）：农业产出 -5%",
          tags=("cell.sector.agriculture",),
          conds=(cond_metric_eq("cell.family_asset_share_q16", 0),),
          cmds=(mod(city_stat_key("building.agriculture_output_factor"),
                    cell(-5)),))],
    [prog("clan_fields_l3",
          "显赫宗族的农业地块（最多 32 格）：农业产出 +16%",
          tags=("cell.eminent_clan", "cell.sector.agriculture"),
          cmds=(mod(city_stat_key("building.agriculture_output_factor"),
                    cell(16)),)),
     prog("clan_fields_l3_penalty",
          "无家产农业地块（最多 32 格）：农业产出 -5%",
          tags=("cell.sector.agriculture",),
          conds=(cond_metric_eq("cell.family_asset_share_q16", 0),),
          cmds=(mod(city_stat_key("building.agriculture_output_factor"),
                    cell(-5)),))],
]

CARD_REQUIRES["merchant_houses"] = ("X9a",)
# The exact "family owns >=3 sectors" count and market-cell sub-target are X9-b.
# The published row uses the existing clan + diversified intersection.
LEVEL_ROWS["merchant_houses"] = [
    [prog("merchant_houses_l1",
          "宗族多元地块（最多 32 格）：全部产出 +10%",
          tags=("cell.clan", "cell.diversified"),
          cmds=(mod(city_stat_key("output_factor"), cell(10)),))],
    [prog("merchant_houses_l2",
          "宗族多元地块（最多 32 格）：全部产出 +14%",
          tags=("cell.clan", "cell.diversified"),
          cmds=(mod(city_stat_key("output_factor"), cell(14)),))],
    [prog("merchant_houses_l3",
          "宗族多元地块（最多 32 格）：全部产出 +19%",
          tags=("cell.clan", "cell.diversified"),
          cmds=(mod(city_stat_key("output_factor"), cell(19)),))],
]
LEVEL_TERMS["merchant_houses"] = [
    [(INPUT, 1.02)],
    [(INPUT, 1.02)],
    [(INPUT, 1.02)],
]

CARD_REQUIRES["family_enterprise"] = ("X9a",)
# The "family owns only one sector" clause is X9-b; L3 uses the existing
# distinct-sector metric as the published approximation.
LEVEL_ROWS["family_enterprise"] = [
    [prog("family_enterprise_l1",
          "家产过半的工业地块（最多 32 格）：工业产出 +12%",
          tags=("cell.clan", "cell.sector.manufacturing"),
          conds=(cond_metric_gte(
              "cell.family_asset_share_q16", Q16 // 2),),
          cmds=(mod(city_stat_key("building.manufacturing_output_factor"),
                    cell(12)),)),
     prog("family_enterprise_l1_penalty",
          "无家产工业地块（最多 32 格）：工业产出 -6%",
          tags=("cell.sector.manufacturing",),
          conds=(cond_metric_eq("cell.family_asset_share_q16", 0),),
          cmds=(mod(city_stat_key("building.manufacturing_output_factor"),
                    cell(-6)),))],
    [prog("family_enterprise_l2",
          "家产过半的工业地块（最多 32 格）：工业产出 +16%",
          tags=("cell.clan", "cell.sector.manufacturing"),
          conds=(cond_metric_gte(
              "cell.family_asset_share_q16", Q16 // 2),),
          cmds=(mod(city_stat_key("building.manufacturing_output_factor"),
                    cell(16)),)),
     prog("family_enterprise_l2_penalty",
          "无家产工业地块（最多 32 格）：工业产出 -6%",
          tags=("cell.sector.manufacturing",),
          conds=(cond_metric_eq("cell.family_asset_share_q16", 0),),
          cmds=(mod(city_stat_key("building.manufacturing_output_factor"),
                    cell(-6)),))],
    [prog("family_enterprise_l3",
          "家产过半的工业地块（最多 32 格）：工业产出 +16%",
          tags=("cell.clan", "cell.sector.manufacturing"),
          conds=(cond_metric_gte(
              "cell.family_asset_share_q16", Q16 // 2),),
          cmds=(mod(city_stat_key("building.manufacturing_output_factor"),
                    cell(16)),)),
     prog("family_enterprise_l3_single_sector",
          "家产过半且只涉一业的工业地块（最多 32 格）：工业产出 +6%",
          tags=("cell.clan", "cell.sector.manufacturing"),
          conds=(cond_metric_gte(
                     "cell.family_asset_share_q16", Q16 // 2),
                 cond_metric_eq("cell.distinct_sector_count", Q16)),
          cmds=(mod(city_stat_key("building.manufacturing_output_factor"),
                    cell(6)),)),
     prog("family_enterprise_l3_penalty",
          "无家产工业地块（最多 32 格）：工业产出 -6%",
          tags=("cell.sector.manufacturing",),
          conds=(cond_metric_eq("cell.family_asset_share_q16", 0),),
          cmds=(mod(city_stat_key("building.manufacturing_output_factor"),
                    cell(-6)),))],
]

CARD_REQUIRES["ancestral_hall"] = ("X16", "X9a")
# Surrounding-cell branch-prestige growth needs X4 timed/event support.
LEVEL_ROWS["ancestral_hall"] = [
    [prog("ancestral_hall_l1",
          "名门地块（最多 32 格）：全部产出 +6%",
          tags=("cell.eminent_clan",),
          cmds=(mod(city_stat_key("output_factor"), cell(6)),))],
    [prog("ancestral_hall_l2",
          "名门地块（最多 32 格）：全部产出 +9%",
          tags=("cell.eminent_clan",),
          cmds=(mod(city_stat_key("output_factor"), cell(9)),))],
    # L3 lowers the eminent-clan threshold from 50 to 40, so this row uses
    # cell.clan plus metric 85 >= 0.4 instead of the 0.5 tag.
    [prog("ancestral_hall_l3",
          "宗族且最高分支威望 ≥40% 的地块（最多 32 格）：全部产出 +9%",
          tags=("cell.clan",),
          conds=(cond_metric_gte(
              "cell.max_branch_prestige_q16", int(0.4 * Q16)),),
          cmds=(mod(city_stat_key("output_factor"), cell(9)),))],
]

CARD_REQUIRES["gentry_patronage"] = ("X16", "X9a")
LEVEL_ROWS["gentry_patronage"] = [
    [prog("gentry_patronage_l1",
          "名门地块（最多 32 格）：知识产出 +10%，教育文化需求 -8%",
          tags=("cell.eminent_clan",),
          cmds=(mod(city_stat_key("building.knowledge_output_factor"), cell(10)),
                mod(city_stat_key("need.education_culture.consumption_factor"),
                    cell(-8))))],
    [prog("gentry_patronage_l2",
          "名门地块（最多 32 格）：知识产出 +14%，教育文化需求 -8%",
          tags=("cell.eminent_clan",),
          cmds=(mod(city_stat_key("building.knowledge_output_factor"), cell(14)),
                mod(city_stat_key("need.education_culture.consumption_factor"),
                    cell(-8))))],
    [prog("gentry_patronage_l3",
          "名门地块（最多 32 格）：知识产出 +14%，教育文化需求 -8%",
          tags=("cell.eminent_clan",),
          cmds=(mod(city_stat_key("building.knowledge_output_factor"), cell(14)),
                mod(city_stat_key("need.education_culture.consumption_factor"),
                    cell(-8)))),
     prog("gentry_patronage_l3_ring",
          "名门地块周围 1 格（最多 32 格）：知识产出 +4%",
          selector=SEL_TAG_SOURCE_R1, tags=("cell.eminent_clan",),
          cmds=(mod(city_stat_key("building.knowledge_output_factor"), cell(4)),))],
]
CARD_REQUIRES["marriage_alliance"] = ("X9a",)
LEVEL_ROWS["marriage_alliance"] = [
    [prog("marriage_alliance_l1",
          "宗族数 ≥2 的地块（最多 32 格）：全部产出 +5%，奢侈品需求 +10%",
          tags=("cell.clan",),
          conds=(cond_metric_gte(
              "cell.family_branch_count", 2 * Q16),),
          cmds=(mod(city_stat_key("output_factor"), cell(5)),
                mod(city_stat_key("need.luxury.consumption_factor"), cell(10)))),
     prog("marriage_alliance_l1_adjacent_clan",
          "相邻宗族地块（每源 +1%，最多 6 源 = +6%）：全部产出 +6%",
          selector=SEL_TAG_SOURCE_COUNT, radius=1, cap=6,
          per_source=cell(1), tags=("cell.clan",),
          cmds=(mod(city_stat_key("output_factor"), 0.0),))],
    [prog("marriage_alliance_l2",
          "宗族数 ≥2 的地块（最多 32 格）：全部产出 +7%，奢侈品需求 +10%",
          tags=("cell.clan",),
          conds=(cond_metric_gte(
              "cell.family_branch_count", 2 * Q16),),
          cmds=(mod(city_stat_key("output_factor"), cell(7)),
                mod(city_stat_key("need.luxury.consumption_factor"), cell(10)))),
     prog("marriage_alliance_l2_adjacent_clan",
          "相邻宗族地块（每源 +1%，最多 6 源 = +6%）：全部产出 +6%",
          selector=SEL_TAG_SOURCE_COUNT, radius=1, cap=6,
          per_source=cell(1), tags=("cell.clan",),
          cmds=(mod(city_stat_key("output_factor"), 0.0),))],
    [prog("marriage_alliance_l3",
          "宗族数 ≥3 的地块（最多 32 格）：全部产出 +7.35%，奢侈品需求 +10%",
          tags=("cell.clan",),
          conds=(cond_metric_gte(
              "cell.family_branch_count", 3 * Q16),),
          cmds=(mod(city_stat_key("output_factor"), cell(7.35)),
                mod(city_stat_key("need.luxury.consumption_factor"), cell(10)))),
     prog("marriage_alliance_l3_adjacent_clan",
          "相邻宗族地块（每源 +1%，最多 6 源 = +6%）：全部产出 +6%",
          selector=SEL_TAG_SOURCE_COUNT, radius=1, cap=6,
          per_source=cell(1), tags=("cell.clan",),
          cmds=(mod(city_stat_key("output_factor"), 0.0),))],
]

CARD_REQUIRES["philanthropy"] = ("X9a",)
# Rich-family prestige growth and L3's surrounding-ring clause are staged on
# the Family-side write and X1b/X2 respectively.
LEVEL_ROWS["philanthropy"] = [
    [prog("philanthropy_l1",
          "名门短缺地块（最多 32 格）：主食需求 -12%",
          tags=("cell.eminent_clan", "cell.shortage"),
          cmds=(mod(city_stat_key("need.staple_food.consumption_factor"),
                    cell(-12)),))],
    [prog("philanthropy_l2",
          "名门短缺地块（最多 32 格）：主食需求 -16%",
          tags=("cell.eminent_clan", "cell.shortage"),
          cmds=(mod(city_stat_key("need.staple_food.consumption_factor"),
                    cell(-16)),))],
    [prog("philanthropy_l3",
          "名门短缺地块（最多 32 格）：主食需求 -16%",
          tags=("cell.eminent_clan", "cell.shortage"),
          cmds=(mod(city_stat_key("need.staple_food.consumption_factor"),
                    cell(-16)),)),
     prog("philanthropy_l3_ring",
          "名门短缺地块周围 1 格（最多 32 格）：主食需求 -16%",
          selector=SEL_TAG_SOURCE_R1,
          tags=("cell.eminent_clan", "cell.shortage"),
          cmds=(mod(city_stat_key("need.staple_food.consumption_factor"),
                    cell(-16)),))],
]
LEVEL_TERMS["philanthropy"] = [
    [(T_CAP, 0.98)],
    [(T_CAP, 0.98)],
    [(T_CAP, 0.98)],
]

# X9-b: each family with >=3 branches lowers national research cost. L3 also
# targets those families directly: only the family's owned buildings receive
# the +6% output row.
CARD_META["family_office"] = Meta(route="clan")
CARD_REQUIRES["family_office"] = ("X9b", "X7")


def _family_office_program(key: str, cap: float, summary: str) -> Prog:
    return prog(
        key, summary,
        target_domain=DOMAIN_COUNTRY, selector=SEL_OWNER,
        ramp=Ramp(metric="country.families_with_at_least_3_branches",
                  per=0.005, cap=cap),
        cmds=(mod(country_stat_key("research.cost_factor", cut=True),
                  0.0, domain=1),))


LEVEL_ROWS["family_office"] = [
    [_family_office_program(
        "family_office_l1", 16.0,
        "每个拥有 >=3 个分支的家族：全国研究成本 -0.5%（上限 -8%）")],
    [_family_office_program(
        "family_office_l2", 24.0,
        "每个拥有 >=3 个分支的家族：全国研究成本 -0.5%（上限 -12%）")],
    [_family_office_program(
        "family_office_l3", 24.0,
        "每个拥有 >=3 个分支的家族：全国研究成本 -0.5%（上限 -12%）"),
     prog(
        "family_office_l3_owned_output",
        "拥有 >=3 个分支的家族：家产建筑全部产出 +6%",
        target_domain=DOMAIN_FAMILY,
        selector=SEL_FAMILY_OWNED,
        selector_cap=32,
        selector_param1=3,
        cmds=(mod(city_stat_key("output_factor"), cell(6), domain=2),))],
]
LEVEL_TERMS["family_office"] = [
    [(T_CAP, 0.98)],
    [(T_CAP, 0.98)],
    [(T_CAP, 0.98)],
]
LEVEL_ROWS["frost_lore"] = [
    [prog("frost_lore_l1_cold",
          "寒地农业地块（最多 32 格）：农业产出 +5%",
          tags=("cell.climate.cold", "cell.sector.agriculture"),
          cmds=(mod(city_stat_key("building.agriculture_output_factor"), cell(5)),)),
     prog("frost_lore_l1_hot",
          "暑地农业地块（最多 32 格）：农业产出 -3%",
          tags=("cell.climate.hot", "cell.sector.agriculture"),
          cmds=(mod(city_stat_key("building.agriculture_output_factor"), cell(-3)),))],
    [prog("frost_lore_l2_cold",
          "寒地农业地块（最多 32 格）：农业产出 +7%",
          tags=("cell.climate.cold", "cell.sector.agriculture"),
          cmds=(mod(city_stat_key("building.agriculture_output_factor"), cell(7)),)),
     prog("frost_lore_l2_hot",
          "暑地农业地块（最多 32 格）：农业产出 -3%",
          tags=("cell.climate.hot", "cell.sector.agriculture"),
          cmds=(mod(city_stat_key("building.agriculture_output_factor"), cell(-3)),))],
    [prog("frost_lore_l3_cold",
          "寒地农业地块（最多 32 格）：农业产出 +7%",
          tags=("cell.climate.cold", "cell.sector.agriculture"),
          cmds=(mod(city_stat_key("building.agriculture_output_factor"), cell(7)),)),
     prog("frost_lore_l3_hot",
          "暑地农业地块（最多 32 格）：农业产出 -3%",
          tags=("cell.climate.hot", "cell.sector.agriculture"),
          cmds=(mod(city_stat_key("building.agriculture_output_factor"), cell(-3)),))],
]

LEVEL_ROWS["little_ice_age"] = [
    [prog("little_ice_age_l1_cold",
          "寒地地块（最多 32 格）：全部产出 +12%",
          tags=("cell.climate.cold",),
          cmds=(mod(city_stat_key("output_factor"), cell(12)),)),
     prog("little_ice_age_l1_hot",
          "暑地农业地块（最多 32 格）：农业产出 -6%",
          tags=("cell.climate.hot", "cell.sector.agriculture"),
          cmds=(mod(city_stat_key("building.agriculture_output_factor"), cell(-6)),))],
    [prog("little_ice_age_l2_cold",
          "寒地地块（最多 32 格）：全部产出 +15%",
          tags=("cell.climate.cold",),
          cmds=(mod(city_stat_key("output_factor"), cell(15)),)),
     prog("little_ice_age_l2_hot",
          "暑地农业地块（最多 32 格）：农业产出 -6%",
          tags=("cell.climate.hot", "cell.sector.agriculture"),
          cmds=(mod(city_stat_key("building.agriculture_output_factor"), cell(-6)),))],
    [prog("little_ice_age_l3_cold",
          "寒地地块（最多 32 格）：全部产出 +15%",
          tags=("cell.climate.cold",),
          cmds=(mod(city_stat_key("output_factor"), cell(15)),)),
     prog("little_ice_age_l3_hot",
          "暑地农业地块（最多 32 格）：农业产出 -6%",
          tags=("cell.climate.hot", "cell.sector.agriculture"),
          cmds=(mod(city_stat_key("building.agriculture_output_factor"), cell(-6)),))],
]

LEVEL_ROWS["refrigeration"] = [
    [prog("refrigeration_l1",
          "暑地地块（最多 32 格）：鱼产出、肉类产出、乳品产出 +10%，家用能源需求 +5%",
          tags=("cell.climate.hot",),
          cmds=(mod(city_stat_key("good.fish.output_factor"), cell(10)),
                mod(city_stat_key("good.meat.output_factor"), cell(10)),
                mod(city_stat_key("good.dairy_products.output_factor"), cell(10)),
                mod(city_stat_key("need.home_energy.consumption_factor"), cell(5))))],
    [prog("refrigeration_l2",
          "暑地地块（最多 32 格）：鱼产出、肉类产出、乳品产出 +14%，家用能源需求 +5%",
          tags=("cell.climate.hot",),
          cmds=(mod(city_stat_key("good.fish.output_factor"), cell(14)),
                mod(city_stat_key("good.meat.output_factor"), cell(14)),
                mod(city_stat_key("good.dairy_products.output_factor"), cell(14)),
                mod(city_stat_key("need.home_energy.consumption_factor"), cell(5))))],
    [prog("refrigeration_l3",
          "暑地地块（最多 32 格）：鱼产出、肉类产出、乳品产出 +14%，家用能源需求 +5%",
          tags=("cell.climate.hot",),
          cmds=(mod(city_stat_key("good.fish.output_factor"), cell(14)),
                mod(city_stat_key("good.meat.output_factor"), cell(14)),
                mod(city_stat_key("good.dairy_products.output_factor"), cell(14)),
                mod(city_stat_key("need.home_energy.consumption_factor"), cell(5)))),
     prog("refrigeration_l3_ring",
          "暑地繁市周围 1 格（最多 32 格）：蛋白质需求 -8%",
          tags=("cell.climate.hot", "cell.market"),
          selector=SEL_TAG_SOURCE_R1,
          cmds=(mod(city_stat_key("need.protein.consumption_factor"), cell(-8)),))],
]
LEVEL_TERMS["refrigeration"] = [
    [(HEAT, 0.85)],
    [(HEAT, 0.80)],
    [(HEAT, 0.80)],
]

LEVEL_ROWS["air_conditioning"] = [
    [prog("air_conditioning_l1",
          "暑地大邑（最多 32 格）：全部产出 +6%，家用能源需求 +10%",
          tags=("cell.climate.hot", "cell.metropolis"),
          cmds=(mod(city_stat_key("output_factor"), cell(6)),
                mod(city_stat_key("need.home_energy.consumption_factor"), cell(10))))],
    [prog("air_conditioning_l2",
          "暑地大邑（最多 32 格）：全部产出 +9%，家用能源需求 +10%",
          tags=("cell.climate.hot", "cell.metropolis"),
          cmds=(mod(city_stat_key("output_factor"), cell(9)),
                mod(city_stat_key("need.home_energy.consumption_factor"), cell(10))))],
    [prog("air_conditioning_l3",
          "暑地大邑（最多 32 格）：全部产出 +9%，家用能源需求 +10%",
          tags=("cell.climate.hot", "cell.metropolis"),
          cmds=(mod(city_stat_key("output_factor"), cell(9)),
                mod(city_stat_key("need.home_energy.consumption_factor"), cell(10))))],
]

# Exact equality deliberately excludes a cell with concurrent hazards: the
# public mask carries drought in bit 1, so 2 means "drought today and nothing
# else". Neighbour spillover and drought-end births are X4 timed clauses.
LEVEL_ROWS["drought_relief"] = [
    [prog("drought_relief_l1",
          "今日仅旱灾的地块（最多 32 格）：主食需求 -15%",
          conds=(cond_metric_eq("cell.hazard_today_mask", 2 * Q16),),
          cmds=(mod(city_stat_key("need.staple_food.consumption_factor"), cell(-15)),))],
    [prog("drought_relief_l2",
          "今日仅旱灾的地块（最多 32 格）：主食需求 -20%",
          conds=(cond_metric_eq("cell.hazard_today_mask", 2 * Q16),),
          cmds=(mod(city_stat_key("need.staple_food.consumption_factor"), cell(-20)),))],
    [prog("drought_relief_l3",
          "今日仅旱灾的地块（最多 32 格）：主食需求 -20%",
          conds=(cond_metric_eq("cell.hazard_today_mask", 2 * Q16),),
          cmds=(mod(city_stat_key("need.staple_food.consumption_factor"), cell(-20)),))],
]
LEVEL_TERMS["drought_relief"] = [
    [(T_CAP, 0.98)],
    [(T_CAP, 0.98)],
    [(T_CAP, 0.98)],
]

# ── national cards with per-level numbers (design doc §5 / §14) ─────────────
# The nine cards the reachability matrix marks 可直接做 are all national-only.
# Each level therefore gets exactly the numbers the design table gives it, in
# `(stat, value[, tag])` tuples:
#
#   * a 2-tuple is a MULTIPLY term, value = the multiplier (<1 = cut, >1 = buff,
#     and for hazard/loss/use stats >1 is the downside -- see `_is_downside`);
#   * a 3-tuple carries the last slot's meaning from `OP_*` above, used where the
#     design says "百分点" (an Add) or where a number is a political transfer
#     that is neither a buff for the player nor a price (land_tax_reform: the
#     landlord surcharge *funds* the peasant cut).
#
# The old emitter wrote one shared row at magnitude 1.0/1.6/2.2, so "L2：+15%"
# shipped as "+10% x 1.6 = +16%". These tables exist so the authored value and
# the compiled value are the same number.
LEVEL_TERMS["terrace_farming"] = [
    # L1: 丘陵、山地地块农业产出 +10%; 丘陵、山地地块矿业产出 -10%.
    [(T("hill", "agriculture"), 1.10), (T("mountain", "agriculture"), 1.10),
     (T("hill", "extractive"), 0.90), (T("mountain", "extractive"), 0.90)],
    # L2: +15% agriculture, same resource conflict (the price does not grow).
    [(T("hill", "agriculture"), 1.15), (T("mountain", "agriculture"), 1.15),
     (T("hill", "extractive"), 0.90), (T("mountain", "extractive"), 0.90)],
    # L3: +15%. The "相邻 >=2 个农业支柱的丘陵/山地 再 +6%" clause is a
    # separate cell program below, gated by metric 94.
    [(T("hill", "agriculture"), 1.15), (T("mountain", "agriculture"), 1.15),
     (T("hill", "extractive"), 0.90), (T("mountain", "extractive"), 0.90)],
]

LEVEL_ROWS["terrace_farming"] = [
    [], [],
    [prog("terrace_farming_l3",
          "相邻至少 2 个农业支柱地块的丘陵/山地（最多 32 格）：农业产出 +6%",
          tags=("cell.terrain.hill|cell.terrain.mountain",),
          conds=(cond_metric_gte(
              "cell.neighbor_agriculture_count", 2 * Q16),),
          cmds=(mod(city_stat_key("building.agriculture_output_factor"),
                    cell(6)),))],
]

LEVEL_TERMS["water_works"] = [
    # L1: 泛滥平原、三角洲地块农业 +8%；全国洪灾损失 -7%；建造成本 +3%.
    [(T("floodplain", "agriculture"), 1.08), (LF("delta", "agriculture"), 1.08),
     (FLOOD, 0.93), (B_COST, 1.03)],
    # L2: +12% / -10%.
    [(T("floodplain", "agriculture"), 1.12), (LF("delta", "agriculture"), 1.12),
     (FLOOD, 0.90), (B_COST, 1.03)],
    # L3: same numbers; the "让周围 1 格农业 +4%（多源取最大）" clause is a
    # spillover and ships as a program row (the design itself marks it B).
    [(T("floodplain", "agriculture"), 1.12), (LF("delta", "agriculture"), 1.12),
     (FLOOD, 0.90), (B_COST, 1.03)],
]

LEVEL_ROWS["water_works"] = [
    [], [],
    [prog("water_works_l3",
          "泛滥平原地块周围 1 格（每源 +4%，最多 3 源 = +12%）：农业产出 +12%",
          selector=SEL_TAG_SOURCE_COUNT, radius=1, cap=3, per_source=cell(4),
          tags=("cell.terrain.floodplain",),
          cmds=(mod(city_stat_key("building.agriculture_output_factor"), 0.0),))],
]

LEVEL_TERMS["forager_band"] = [
    # L1: 森林、雨林地块农业 +8%；野生动物开采 +5%.
    [(T("forest", "agriculture"), 1.08), (T("jungle", "agriculture"), 1.08),
     (RUSE(WILD_GAME), 1.05)],
    # L2: +12%.
    [(T("forest", "agriculture"), 1.12), (T("jungle", "agriculture"), 1.12),
     (RUSE(WILD_GAME), 1.05)],
    # L3: same; "每有 1 个相邻森林地块，野味再生 +5%" is a neighbour COUNT
    # (X2), so it cannot ship yet. The wild-game regen that *is* expressible
    # arrives as a national row rather than being faked.
    [(T("forest", "agriculture"), 1.12), (T("jungle", "agriculture"), 1.12),
     (RUSE(WILD_GAME), 1.05)],
]

LEVEL_TERMS["riverside_camp"] = [
    # L1: 三角洲、泛滥平原地块农业 +6%.
    #
    # The design's price is "全国洪灾损失 +4%" and it is DELIBERATELY ABSENT:
    # `country.climate.flood_loss_factor` is declared `[0.20, 1.0]` in
    # `modifier_catalog.gd`'s TECHNOLOGY_STATS, and
    # `ModifierRuntime::effective_value` clamps to the stat's bounds, so any
    # hazard-loss *increase* is a silent no-op. Authoring it would print a cost on
    # the card face that the runtime never charges. `validate_cards` rejects such
    # terms outright (`_clamped_noop_reason`).
    # The design's price is "全国洪灾损失 +4%", which the engine cannot charge
    # (see `_CLAMPED_AT_ONE`). Every card still needs a downside the runtime
    # actually applies, so the price is paid on the same axis the neighbouring
    # water cards already use: river engineering draws production inputs.
    [(LF("delta", "agriculture"), 1.06), (T("floodplain", "agriculture"), 1.06),
     (INPUT, 1.02)],
    # L2: +9%.
    [(LF("delta", "agriculture"), 1.09), (T("floodplain", "agriculture"), 1.09),
     (INPUT, 1.02)],
    # L3: same; "这些地块周围 1 格农业 +3%" is the spillover clause.
    [(LF("delta", "agriculture"), 1.09), (T("floodplain", "agriculture"), 1.09),
     (INPUT, 1.02)],
]

LEVEL_ROWS["riverside_camp"] = [
    [], [],
    [prog("riverside_camp_l3",
          "三角洲地块周围 1 格（每源 +3%，最多 3 源 = +9%）：农业产出 +9%",
          selector=SEL_TAG_SOURCE_COUNT, radius=1, cap=3, per_source=cell(3),
          tags=("cell.landform.delta",),
          cmds=(mod(city_stat_key("building.agriculture_output_factor"), 0.0),))],
]

LEVEL_TERMS["seasonal_calendar"] = [
    # L1: 全国冷害 -6%、热害 -5%，旱地作物旱灾损失 -6%；理念点获取 -3%.
    [(COLD, 0.94), (HEAT, 0.95), (PROFILE("dryland_crop", "drought"), 0.94),
     (POINTS, 0.97)],
    # L2: 效果 ×1.5 -> -9% / -7.5% / -9%. Written as the resulting multiplier so
    # the compiled number is the one in the table.
    [(COLD, 0.91), (HEAT, 0.925), (PROFILE("dryland_crop", "drought"), 0.91),
     (POINTS, 0.97)],
    # L3: same numbers; "降雨日农业支柱地块农业 +5%" is a metric condition
    # (`cell.rain` + `cell.sector.agriculture`), which is expressible as an
    # intersection tag, so it ships as a program row.
    [(COLD, 0.91), (HEAT, 0.925), (PROFILE("dryland_crop", "drought"), 0.91),
     (POINTS, 0.97)],
]

LEVEL_ROWS["seasonal_calendar"] = [
    [], [],
    [prog("seasonal_calendar_l3",
          "降雨日的农业支柱地块（最多 32 格）：农业产出 +5%",
          tags=("cell.rain", "cell.sector.agriculture"),
          cmds=(mod(city_stat_key("building.agriculture_output_factor"), cell(5)),))],
]

LEVEL_TERMS["pit_dwelling"] = [
    # L1: 全国冷害损失 -6%，建造成本 -5%；丘陵地块农业 -2%.
    [(COLD, 0.94), (B_COST, 0.95), (T("hill", "agriculture"), 0.98)],
    # L2: -9% / -7%.
    [(COLD, 0.91), (B_COST, 0.93), (T("hill", "agriculture"), 0.98)],
    # L3: same; "聚落地块出生率 +5%" ships as a cell program.
    [(COLD, 0.91), (B_COST, 0.93), (T("hill", "agriculture"), 0.98)],
]

LEVEL_ROWS["pit_dwelling"] = [
    [], [],
    [prog("pit_dwelling_l3",
          "聚落地块（最多 32 格）：出生率 +5%",
          tags=("cell.settlement",),
          cmds=(mod(city_stat_key("birth_factor"), cell(5)),))],
]

LEVEL_TERMS["hydroelectric"] = [
    # L1: 河谷、裂谷、峡谷地块能源产出 +12%.
    #
    # 「河谷」is a TERRAIN (`floodplain`), not a landform -- the two are separate
    # id spaces and `landform.river_valley` is a *research-signal* id that has no
    # matching `LF` enum member, so `LF("river_valley", ...)` is rejected by the
    # stat lint. 裂谷 / 峡谷 are landforms (`rift_valley` / `canyon`).
    #
    # The "全国洪灾损失 +2%" price is absent for the same reason as
    # `riverside_camp` (clamped stat). The dam is paid for in production inputs
    # and in the resources it displaces, which the runtime does charge.
    [(T("floodplain", "energy"), 1.12), (LF("rift_valley", "energy"), 1.12),
     (LF("canyon", "energy"), 1.12), (INPUT, 1.03)],
    # L2: +18%.
    [(T("floodplain", "energy"), 1.18), (LF("rift_valley", "energy"), 1.18),
     (LF("canyon", "energy"), 1.18), (INPUT, 1.03)],
    # L3: same; "这些地块成为能源支柱时，周围 1 格电力 +8%" is a spillover that
    # also needs a condition on the *source* cell (not expressible), so the
    # reachable half -- the source population -- ships alone.
    [(T("floodplain", "energy"), 1.18), (LF("rift_valley", "energy"), 1.18),
     (LF("canyon", "energy"), 1.18), (INPUT, 1.03)],
]

LEVEL_ROWS["hydroelectric"] = [
    [], [],
    [prog("hydroelectric_l3",
          "能源支柱地块周围 2 格（每源 +8%，最多 3 源 = +24%）：能源产出 +24%",
          selector=SEL_TAG_SOURCE_COUNT, radius=2, cap=3, per_source=cell(8),
          tags=("cell.sector.energy",),
          cmds=(mod(city_stat_key("building.energy_output_factor"), 0.0),))],
]

# X12 戍边. L3's "border also satisfies frontier" is an X5 tag rewrite.
LEVEL_ROWS["frontier_garrison"] = [
    [prog("frontier_garrison_l1",
          "边境地块（最多 32 格）：农业产出 +8%，出生率 +5%",
          tags=("cell.border",),
          cmds=(mod(city_stat_key("building.agriculture_output_factor"), cell(8)),
                mod(city_stat_key("birth_factor"), cell(5))))],
    [prog("frontier_garrison_l2",
          "边境地块（最多 32 格）：农业产出 +10%，出生率 +7%",
          tags=("cell.border",),
          cmds=(mod(city_stat_key("building.agriculture_output_factor"), cell(10)),
                mod(city_stat_key("birth_factor"), cell(7))))],
    [prog("frontier_garrison_l3",
          "边境或边地地块（最多 32 格）：农业产出 +10%，出生率 +7%",
          tags=("cell.border",),
          cmds=(mod(city_stat_key("building.agriculture_output_factor"), cell(10)),
                mod(city_stat_key("birth_factor"), cell(7))))],
]
LEVEL_TERMS["frontier_garrison"] = [
    [(T_SPEED, 0.98)],
    [(T_SPEED, 0.98)],
    [(T_SPEED, 0.98)],
]
CARD_REQUIRES["frontier_garrison"] = ("X12", "X5")
LEVEL_REWRITES["frontier_garrison"] = [
    [],
    [],
    [rewrite_tag("cell.border", "cell.border|cell.frontier")],
]

# X12 canal cards. Cell-level trade output is still dead, so the national
# trade clauses stay explicitly in NEEDS_RUNTIME instead of shipping no-ops.
CARD_META["canal_corvee"] = Meta(route="terrain", secondary=("thoroughfare",))
LEVEL_ROWS["canal_corvee"] = [
    [prog("canal_corvee_l1_agriculture",
          "运河地块周围 1 格：农业产出 +8%",
          selector=SEL_TAG_SOURCE_R1, tags=("cell.canal",),
          cmds=(mod(city_stat_key("building.agriculture_output_factor"), cell(8)),)),
     prog("canal_corvee_l1_birth",
          "运河地块：出生率 -3%",
          tags=("cell.canal",),
          cmds=(mod(city_stat_key("birth_factor"), cell(-3)),))],
    [prog("canal_corvee_l2_agriculture",
          "运河地块周围 1 格：农业产出 +10%",
          selector=SEL_TAG_SOURCE_R1, tags=("cell.canal",),
          cmds=(mod(city_stat_key("building.agriculture_output_factor"), cell(10)),)),
     prog("canal_corvee_l2_birth",
          "运河地块：出生率 -3%",
          tags=("cell.canal",),
          cmds=(mod(city_stat_key("birth_factor"), cell(-3)),))],
    [prog("canal_corvee_l3_agriculture",
          "运河或河畔地块周围 1 格：农业产出 +10%",
          selector=SEL_TAG_SOURCE_R1, tags=("cell.canal|cell.river",),
          cmds=(mod(city_stat_key("building.agriculture_output_factor"), cell(10)),)),
     prog("canal_corvee_l3_birth",
          "运河地块：出生率 -3%",
          tags=("cell.canal",),
          cmds=(mod(city_stat_key("birth_factor"), cell(-3)),))],
]
CARD_REQUIRES["canal_corvee"] = ("X12",)

CARD_META["grand_canal"] = Meta(route="thoroughfare")
LEVEL_ROWS["grand_canal"] = [
    [prog("grand_canal_l1_output",
          "水运河网 ≥8 格：网内全部产出 +10%",
          tags=("cell.canal|cell.river",),
          conds=(cond_metric_gte("cell.waterway_component_size", 8 * Q16),),
          cmds=(mod(city_stat_key("output_factor"), cell(10)),))],
    [prog("grand_canal_l2_output",
          "水运河网 ≥6 格：网内全部产出 +10%",
          tags=("cell.canal|cell.river",),
          conds=(cond_metric_gte("cell.waterway_component_size", 6 * Q16),),
          cmds=(mod(city_stat_key("output_factor"), cell(10)),))],
    [prog("grand_canal_l3_output",
          "水运河网 ≥6 格：网内全部产出 +10%",
          tags=("cell.canal|cell.river",),
          conds=(cond_metric_gte("cell.waterway_component_size", 6 * Q16),),
          cmds=(mod(city_stat_key("output_factor"), cell(10)),))],
]
LEVEL_TERMS["grand_canal"] = [
    [(B_COST, 1.04)],
    [(B_COST, 1.04)],
    [(B_COST, 1.04)],
]
CARD_REQUIRES["grand_canal"] = ("X12", "X2")

CARD_META["irrigation_grid"] = Meta(route="terrain", secondary=("cropland",))
LEVEL_ROWS["irrigation_grid"] = [
    [prog("irrigation_grid_l1",
          "河畔或运河地块周围 2 格：农业产出 +6%",
          selector=SEL_TAG_SOURCE_R2, tags=("cell.canal|cell.river",),
          cmds=(mod(city_stat_key("building.agriculture_output_factor"), cell(6)),))],
    [prog("irrigation_grid_l2",
          "河畔或运河地块周围 2 格：农业产出 +9%",
          selector=SEL_TAG_SOURCE_R2, tags=("cell.canal|cell.river",),
          cmds=(mod(city_stat_key("building.agriculture_output_factor"), cell(9)),))],
    [prog("irrigation_grid_l3",
          "河畔或运河地块周围 2 格：农业产出 +9%",
          selector=SEL_TAG_SOURCE_R2, tags=("cell.canal|cell.river",),
          cmds=(mod(city_stat_key("building.agriculture_output_factor"), cell(9)),))],
]
LEVEL_TERMS["irrigation_grid"] = [
    [(B_COST, 1.03)],
    [(B_COST, 1.03)],
    [(B_COST, 1.03)],
]
CARD_REQUIRES["irrigation_grid"] = ("X12",)

CARD_META["industrial_lab"] = Meta(route="learning", secondary=("workshop",))
LEVEL_ROWS["industrial_lab"] = [
    [prog("industrial_lab_l1_bonus",
          "知识支柱周围 2 格的工业地块：工业产出 +8%",
          selector=SEL_TAG_SOURCE_R2, tags=("cell.sector.knowledge",),
          conds=(cond_metric_gte(
              "cell.sector_output_share.manufacturing_q16", _pct(50)),),
          cmds=(mod(city_stat_key("building.manufacturing_output_factor"),
                    cell(8)),)),
     prog("industrial_lab_l1_science",
          "每完成 1 项科学科技：工业产出 +0.5%（上限 +10%）",
          selector=SEL_TAG_SOURCE_R2, tags=("cell.sector.knowledge",),
          conds=(cond_metric_gte(
              "cell.sector_output_share.manufacturing_q16", _pct(50)),),
          ramp=Ramp("country.completed_tech_count.science",
                    per=0.005, cap=20.0),
          cmds=(mod(city_stat_key("building.manufacturing_output_factor"),
                    cell(0.5)),))],
    [prog("industrial_lab_l2_bonus",
          "知识支柱周围 2 格的工业地块：工业产出 +12%",
          selector=SEL_TAG_SOURCE_R2, tags=("cell.sector.knowledge",),
          conds=(cond_metric_gte(
              "cell.sector_output_share.manufacturing_q16", _pct(50)),),
          cmds=(mod(city_stat_key("building.manufacturing_output_factor"),
                    cell(12)),)),
     prog("industrial_lab_l2_science",
          "每完成 1 项科学科技：工业产出 +0.5%（上限 +10%）",
          selector=SEL_TAG_SOURCE_R2, tags=("cell.sector.knowledge",),
          conds=(cond_metric_gte(
              "cell.sector_output_share.manufacturing_q16", _pct(50)),),
          ramp=Ramp("country.completed_tech_count.science",
                    per=0.005, cap=20.0),
          cmds=(mod(city_stat_key("building.manufacturing_output_factor"),
                    cell(0.5)),))],
    [prog("industrial_lab_l3_bonus",
          "知识支柱周围 2 格的工业地块：工业产出 +12%",
          selector=SEL_TAG_SOURCE_R2, tags=("cell.sector.knowledge",),
          conds=(cond_metric_gte(
              "cell.sector_output_share.manufacturing_q16", _pct(50)),),
          cmds=(mod(city_stat_key("building.manufacturing_output_factor"),
                    cell(12)),)),
     prog("industrial_lab_l3_science",
          "每完成 1 项科学科技：工业产出 +0.5%（上限 +10%）",
          selector=SEL_TAG_SOURCE_R2, tags=("cell.sector.knowledge",),
          conds=(cond_metric_gte(
              "cell.sector_output_share.manufacturing_q16", _pct(50)),),
          ramp=Ramp("country.completed_tech_count.science",
                    per=0.005, cap=20.0),
          cmds=(mod(city_stat_key("building.manufacturing_output_factor"),
                    cell(0.5)),))],
]
CARD_REQUIRES["industrial_lab"] = ("X10",)

CARD_META["shell_midden"] = Meta(route="livelihood")
LEVEL_ROWS["shell_midden"] = [
    [prog("shell_midden_l1",
          "主产鱼的地块：渔业再生 +15%",
          tags=("cell.produces.fish",),
          cmds=(mod(city_stat_key("resource.freshwater_fish.regen_factor"),
                    cell(15)),))],
    [prog("shell_midden_l2",
          "主产鱼的地块：渔业再生 +20%",
          tags=("cell.produces.fish",),
          cmds=(mod(city_stat_key("resource.freshwater_fish.regen_factor"),
                    cell(20)),))],
    [prog("shell_midden_l3",
          "主产鱼的地块：渔业再生 +20%",
          tags=("cell.produces.fish",),
          cmds=(mod(city_stat_key("resource.freshwater_fish.regen_factor"),
                    cell(20)),))],
]
LEVEL_TERMS["shell_midden"] = [
    [(RUSE(FRESHWATER_FISH), 1.05)],
    [(RUSE(FRESHWATER_FISH), 1.05)],
    [(RUSE(FRESHWATER_FISH), 1.05)],
]
CARD_REQUIRES["shell_midden"] = ("X2",)

# X6-c: the algorithm card copies the persistent program list of the card in
# the immediately-left ideology slot. It is the only copier in the catalog.
CARD_REQUIRES["algorithmic_governance"] = ("X6c",)

# ── X16: per-profession attitude stats (design doc §47.3) ───────────────────
# Two stat families, expanded per PROFESSION id (not per political class:
# `landlord` and most farmer professions land in `general`, so a class-scoped
# card would buff and tax the same bucket).
#
#   economy.profession.<pid>.tax_tolerance_factor  MULTIPLY  [0.5, 3.0]
#       satisfaction tax dimension is `1 - net_burden / tolerance`; a bigger
#       factor means the same net burden FEELS lighter.
#   economy.profession.<pid>.satisfaction_bp       ADD       [-2500, +2500]
#       "satisfaction -8" is -800 bp (full marks = 100 points).
#
# STAGED: X16 is C++ work owned by session R (`AVAILABLE_CAPABILITIES` does not
# list it). These rows are authored now so the numbers are reviewable and the
# lint still validates them; the cards are held out of the catalog by
# `CARD_REQUIRES` until the stats exist.
def PROF_TOLERANCE(profession_id: str) -> str:
    """How a profession reacts to a given net tax burden (X16)."""
    return f"economy.profession.{profession_id}.tax_tolerance_factor"


def PROF_SATISFACTION(profession_id: str) -> str:
    """Direct satisfaction bias for a profession, in basis points (X16)."""
    return f"economy.profession.{profession_id}.satisfaction_bp"


# Compile-time profession groups (design doc §47.3 point 5). Cards name the group;
# the generator expands it, so adding a profession to a group is one line.
PROFESSION_GROUPS = {
    "farm_workers": ("household_farmer", "subsistence_farmer", "tenant_farmer",
                     "sharecropper", "agricultural_worker", "serf"),
    "tenant_layer": ("tenant_farmer", "sharecropper", "serf"),
    "wage_workers": ("industrial_worker", "miner", "machinist",
                     "petroleum_worker", "transport_worker", "construction_worker",
                     "electrician", "worker"),
    "capital": ("industrialist", "landlord", "manager"),
    "merchants": ("merchant",),
}


def profession_group(group: str) -> tuple[str, ...]:
    """Profession ids of a named group; fails loudly on an unknown name."""
    ids = PROFESSION_GROUPS.get(group)
    if ids is None:
        raise SystemExit(
            f"profession group {group!r} is not declared; known: "
            + ", ".join(sorted(PROFESSION_GROUPS)))
    return ids


# 摊丁入亩 (§47.5, X16 rewrite).
#
# The old version multiplied `country.tax.income.*.rate_bp` -- one free tax click
# (V1). The new version changes how the same rates FEEL, which the player cannot
# click his way to:
#   L1 农耕劳动者税负容忍度 x1.30;  地主满意度 -8;  社会研究 -3%
#   L2 农耕劳动者税负容忍度 x1.45;  地主满意度 -10; 社会研究 -3%
#   L3 same, plus the original "轻税地块出生率 +8%" clause -- that one needs
#      metric 68 `cell.net_tax_burden_q16` (design doc §47.9) to know which cells
#      are actually lightly taxed, so it is a cell program gated on metric68.
LEVEL_TERMS["land_tax_reform"] = [
    [(PROF_TOLERANCE(pid), 1.30) for pid in profession_group("farm_workers")]
    + [(PROF_SATISFACTION("landlord"), -800.0, OP_ADD_DOWNSIDE), (R_SOC, 0.97)],
    [(PROF_TOLERANCE(pid), 1.45) for pid in profession_group("farm_workers")]
    + [(PROF_SATISFACTION("landlord"), -1000.0, OP_ADD_DOWNSIDE), (R_SOC, 0.97)],
    [(PROF_TOLERANCE(pid), 1.45) for pid in profession_group("farm_workers")]
    + [(PROF_SATISFACTION("landlord"), -1000.0, OP_ADD_DOWNSIDE), (R_SOC, 0.97)],
]

# 摊丁入亩 L3 clause: lightly-taxed agricultural cells breed faster. Needs metric
# 68 so "lightly taxed" means the MEASURED net burden (<= 8%), not "below the
# national default" -- the latter is a player-set number (V2).
if metric_available("cell.net_tax_burden_q16"):
    LEVEL_ROWS["land_tax_reform"] = [
        [], [],
        [prog("land_tax_reform_l3",
              "轻税的农业支柱地块（实测净税负 ≤ 8%，最多 32 格）：出生率 +8%",
              tags=("cell.sector.agriculture",),
              conds=(cond_metric_lte("cell.net_tax_burden_q16", int(0.08 * Q16)),),
              cmds=(mod(city_stat_key("birth_factor"), cell(8)),))],
    ]
else:
    # Metric 68 is C++-side work (design doc §47.9, session R). Authoring the row
    # before it exists would call `metric_id()` and hard-fail generation, so the
    # clause waits -- and the card is already staged on ("X16", "metric68"), so
    # nothing publishes a half-card in the meantime.
    LEVEL_ROWS["land_tax_reform"] = [[], [], []]

# 消费税制 (§47.5, X16 rewrite).
#
# The old version added 300 bp to the consumption tax of three goods -- again one
# free tax click (V1). The new version:
#   L1 全职业税负容忍度 x1.08;  珠宝/精致服装/饮料产出 -4%
#   L2 全职业税负容忍度 x1.12;  同上
#   L3 same, plus "国库储备率每档建造成本 -0.5%" -- that needs the treasury-reserve
#      ratio from §47.4, which is not published either, so L3 keeps L2's numbers.
_EXCISE_CUT_GOODS = ("jewelry", "fine_clothing", "beverages")


def _all_profession_ids() -> tuple[str, ...]:
    """Every profession id in the economy catalog, sorted for determinism."""
    return tuple(sorted(_read_res_dir_ids(PROFESSIONS_DIR)))


def _excise_terms(tolerance: float, ramp: Ramp | None = None) -> list:
    """One level of 消费税制: all-profession tolerance plus the output cut.

    L3's reserve-ratio ramp is a domain-3 program row (`LEVEL_ROWS["excise"]`),
    not a term: a plain Modifier definition cannot carry the Effect instruction
    sequence. L3 adds that ramp on top of the same tolerance/output numbers.

    `ramp` is accepted for old callers but unused; the explicit argument keeps
    any stale invocation from silently moving the ramp back into a Modifier.
    """
    if ramp is not None:
        raise SystemExit("excise: the L3 ramp must live in LEVEL_ROWS, not LEVEL_TERMS")
    rows = [(PROF_TOLERANCE(pid), tolerance) for pid in _all_profession_ids()]
    rows += [(G(good), 0.96) for good in _EXCISE_CUT_GOODS]
    return rows


# Filled by `_build_capability_dependent_tables()` during `main()`, not here: the
# term list enumerates every profession id, and the readers that discover those ids
# (`_read_res_dir_ids`) are defined further down the file. Evaluating at import
# time raised `NameError`.
LEVEL_TERMS["excise"] = []

# 摊丁入亩 waits on X16 + metric 68; 消费税制 on X16 + the treasury reserve ratio
# (§47.4), because its L3 ramps on that per-band value.
CARD_REQUIRES["land_tax_reform"] = ("X16", "metric68")
CARD_REQUIRES["excise"] = ("X16", "reserve_ratio")

LEVEL_ROWS["excise"] = [
    [],
    [],
    [prog("excise_l3_ramp",
          "国库储备率每档建造成本 -0.5%（上限 -4%）",
          target_domain=DOMAIN_COUNTRY, selector=SEL_OWNER,
          ramp=Ramp(metric="country.treasury_reserve_ratio_pct",
                    per=0.005, cap=8.0),
          cmds=(mod(country_stat_key("construction.cost_factor"),
                    0.0, domain=1),))],
]

# ── §47.5 的 8 张 X16 卡 ────────────────────────────────────────────────────
# 全部 STAGED 在 ("X16",) 或 ("X16", "metric68") 上：两族 stat 的 C++ 归 R。
# 数值严格照抄设计文档 §47.5 / §14 的原文；设计没写 cap 的按 §47 的反推规则，
# 反推值统一记进 09 的「待调数值」清单（§8）。
#
# 通用约定：
#   * 税负容忍度是 MULTIPLY（1.20 = 同样的税觉得轻 20%）。
#   * 满意度是 ADD，单位 bp，`-300` = 满意度 -3（满分 100 点）。
#   * 「轻税地块」一律走 metric 68 的**实测**净税负（≤8%），不与玩家自设的全国默认比较（V2）。
#
# 「名门地块」与「名门家族分支威望」需要 X9（家族影响力按格聚合），设计表把它们标成
# `C（X9 + X16）`。本轮只写 X16 能表达的那一半，X9 的一半**不写假 tag**，
# 在注释与 09 里记明缺口；卡片 `requires` 里加 X9，等 X9 落地时补齐。

CARD_REQUIRES["progressive_tax"] = ("X16", "reserve_ratio")
CARD_REQUIRES["labour_legislation"] = ("X16",)
LEVEL_TERMS["labour_legislation"] = [
    [(CONSUME, 0.98), (INPUT, 1.02)],
    [(CONSUME, 0.98), (INPUT, 1.02)],
    [(CONSUME, 0.98), (INPUT, 1.02),
     (PROF_SATISFACTION("industrial_worker"), 400.0),
     (PROF_SATISFACTION("miner"), 400.0)],
]
LEVEL_TERMS["progressive_tax"] = [
    # L1: 雇佣劳动者容忍度 x1.20；国库储备率每档死亡率 -1%（上限 -6%）
    #     资本方容忍度 x0.80（同样的税率他们更不满）
    [(PROF_TOLERANCE(pid), 1.20) for pid in profession_group("wage_workers")]
    + [(PROF_TOLERANCE(pid), 0.80) for pid in profession_group("capital")],
    # L2: x1.30，死亡率上限 -8%
    [(PROF_TOLERANCE(pid), 1.30) for pid in profession_group("wage_workers")]
    + [(PROF_TOLERANCE(pid), 0.80) for pid in profession_group("capital")],
    # L3: 同 L2，另加「轻税地块出生率 +6%」（metric 68 程序，见下）
    [(PROF_TOLERANCE(pid), 1.30) for pid in profession_group("wage_workers")]
    + [(PROF_TOLERANCE(pid), 0.80) for pid in profession_group("capital")],
]

LEVEL_ROWS["progressive_tax"] = [
    [prog("progressive_tax_l1_ramp",
          "国库储备率每档死亡率 -1%（上限 -6%）",
          target_domain=DOMAIN_COUNTRY, selector=SEL_OWNER,
          ramp=Ramp(metric="country.treasury_reserve_ratio_pct",
                    per=0.01, cap=6.0),
          cmds=(mod(country_stat_key("population.death_factor"),
                    0.0, domain=1),))],
    [prog("progressive_tax_l2_ramp",
          "国库储备率每档死亡率 -1%（上限 -8%）",
          target_domain=DOMAIN_COUNTRY, selector=SEL_OWNER,
          ramp=Ramp(metric="country.treasury_reserve_ratio_pct",
                    per=0.01, cap=8.0),
          cmds=(mod(country_stat_key("population.death_factor"),
                    0.0, domain=1),))],
    [prog("progressive_tax_l3_ramp",
          "国库储备率每档死亡率 -1%（上限 -8%）",
          target_domain=DOMAIN_COUNTRY, selector=SEL_OWNER,
          ramp=Ramp(metric="country.treasury_reserve_ratio_pct",
                    per=0.01, cap=8.0),
          cmds=(mod(country_stat_key("population.death_factor"),
                    0.0, domain=1),))],
]

# ── X11 fiscal cards (doc 14: treasury_reserve / silver_standard /
#    subsidize_state / sovereign_fund) ────────────────────────────────────────
#
# All four cards read metric 69, `country.treasury_reserve_ratio_pct`: the
# number of percentage points the treasury holds against one year of national
# population income (§47.4). A ramp term cannot ride a national Modifier row
# (see `add()`), so each effect is a DOMAIN_COUNTRY program. The card's price
# stays in the CARDS tuple, where the existing lints enforce "a real downside".
_RESERVE_METRIC = "country.treasury_reserve_ratio_pct"


def _reserve_program(key: str, level: int, summary: str, per: float,
                     cap: float, stat: str, cut: bool, gain: bool) -> Prog:
    return prog(
        key, summary,
        target_domain=DOMAIN_COUNTRY, selector=SEL_OWNER,
        ramp=Ramp(metric=_RESERVE_METRIC, per=per, cap=cap),
        cmds=(mod(country_stat_key(stat, cut=cut, gain=gain),
                  0.0, domain=1),))


# treasury_reserve: death and construction cost fall by one percentage point
# per reserve band; L3 adds ideology point gain. The trade-capacity price lives
# in the CARDS tuple (one flat 3% loss, not a ramp).
CARD_REQUIRES["treasury_reserve"] = ("reserve_ratio",)
LEVEL_ROWS["treasury_reserve"] = [
    [
        _reserve_program("treasury_reserve_l1_death", 1,
                         "国库储备率每档死亡率 -1%（上限 -5%）",
                         0.01, 5.0, "population.death_factor", True, False),
        _reserve_program("treasury_reserve_l1_build", 1,
                         "国库储备率每档建设成本 -1%（上限 -5%）",
                         0.01, 5.0, "construction.cost_factor", True, False),
    ],
    [
        _reserve_program("treasury_reserve_l2_death", 2,
                         "国库储备率每档死亡率 -1%（上限 -7%）",
                         0.01, 7.0, "population.death_factor", True, False),
        _reserve_program("treasury_reserve_l2_build", 2,
                         "国库储备率每档建设成本 -1%（上限 -7%）",
                         0.01, 7.0, "construction.cost_factor", True, False),
    ],
    [
        _reserve_program("treasury_reserve_l3_death", 3,
                         "国库储备率每档死亡率 -1%（上限 -7%）",
                         0.01, 7.0, "population.death_factor", True, False),
        _reserve_program("treasury_reserve_l3_build", 3,
                         "国库储备率每档建设成本 -1%（上限 -7%）",
                         0.01, 7.0, "construction.cost_factor", True, False),
        _reserve_program("treasury_reserve_l3_points", 3,
                         "国库储备率每档理念点获取 +1%（上限 +5%）",
                         0.01, 5.0, "ideology.point_gain_factor", False, True),
    ],
]
LEVEL_TERMS["treasury_reserve"] = [
    [(T_CAP, 0.97)],
    [(T_CAP, 0.97)],
    [(T_CAP, 0.97)],
]

# silver_standard: trade capacity grows with the reserve; households pay more.
CARD_REQUIRES["silver_standard"] = ("reserve_ratio",)
LEVEL_ROWS["silver_standard"] = [
    [_reserve_program("silver_standard_l1", 1,
                      "国库储备率每档贸易容量 +1%（上限 +12%）",
                      0.01, 12.0, "trade.capacity_factor", False, True)],
    [_reserve_program("silver_standard_l2", 2,
                      "国库储备率每档贸易容量 +1%（上限 +15%）",
                      0.01, 15.0, "trade.capacity_factor", False, True)],
    [_reserve_program("silver_standard_l3", 3,
                      "国库储备率每档贸易容量 +1%（上限 +15%）",
                      0.01, 15.0, "trade.capacity_factor", False, True)],
]
LEVEL_TERMS["silver_standard"] = [
    [(CONSUME, 1.02)],
    [(CONSUME, 1.02)],
    [(CONSUME, 1.02)],
]

# subsidize_state: lightly taxed cells get an output bonus. Metric 68 is measured
# net tax burden (not a player-set tax lever); L3 extends the gate to tax-free
# cells. The national construction cost is the real price.
CARD_REQUIRES["subsidy_state"] = ("metric68",)
_SUBSIDY_OUTPUT_STATS = (
    "building.agriculture_output_factor",
    "building.extractive_output_factor",
    "building.manufacturing_output_factor",
    "building.energy_output_factor",
    "building.knowledge_output_factor",
)


def _subsidy_output_cmds(value: float) -> tuple[Cmd, ...]:
    return tuple(mod(city_stat_key(stat), cell(value))
                 for stat in _SUBSIDY_OUTPUT_STATS)


LEVEL_ROWS["subsidy_state"] = [
    [prog("subsidy_state_l1",
          "轻税地块（实测净税负 ≤ 8%，最多 32 格）：农业、采掘、工业、能源、知识产出 +10%",
          conds=(cond_metric_lte(
              "cell.net_tax_burden_q16", int(0.08 * Q16)),),
          cmds=_subsidy_output_cmds(10))],
    [prog("subsidy_state_l2",
          "轻税地块（实测净税负 ≤ 12%，最多 32 格）：农业、采掘、工业、能源、知识产出 +14%",
          conds=(cond_metric_lte(
              "cell.net_tax_burden_q16", int(0.12 * Q16)),),
          cmds=_subsidy_output_cmds(14))],
    [
        prog("subsidy_state_l3",
             "轻税或免税地块（实测净税负 ≤ 12%，最多 32 格）：农业、采掘、工业、能源、知识产出 +14%",
             conds=(cond_metric_lte(
                 "cell.net_tax_burden_q16", int(0.12 * Q16)),),
             cmds=_subsidy_output_cmds(14)),
        prog("subsidy_state_l3_free",
             "免税地块（实测净税负 = 0，最多 32 格）：农业、采掘、工业、能源、知识产出再 +5%",
             conds=(cond_metric_lte("cell.net_tax_burden_q16", 0),),
             cmds=_subsidy_output_cmds(5)),
    ],
]
LEVEL_TERMS["subsidy_state"] = [
    [(B_COST, 1.04)],
    [(B_COST, 1.04)],
    [(B_COST, 1.04)],
]

# sovereign_fund: every sector gets a small output ramp; trade capacity pays.
CARD_REQUIRES["sovereign_fund"] = ("reserve_ratio",)
_SOVEREIGN_STATS = (
    ("agriculture", AGRI),
    ("extractive", EXTR),
    ("manufacturing", MANU),
    ("energy", ENER),
    ("knowledge", KNOW),
)
LEVEL_ROWS["sovereign_fund"] = []
for _level_index, (_threshold, _cap) in enumerate(((5.0, 10.0),
                                                   (4.0, 14.0),
                                                   (4.0, 14.0)), start=1):
    _level_rows = []
    for _suffix, _stat in _SOVEREIGN_STATS:
        _level_rows.append(_reserve_program(
            f"sovereign_fund_l{_level_index}_{_suffix}",
            _level_index,
            f"国库储备率每 {int(_threshold)} 档该部门产出 +2%（上限 +{int(_cap)}%）",
            0.02 / _threshold, _threshold * _cap / 2.0,
            f"output.{_suffix}_factor",
            False, True))
    LEVEL_ROWS["sovereign_fund"].append(_level_rows)
LEVEL_TERMS["sovereign_fund"] = [
    [(T_CAP, 0.97)],
    [(T_CAP, 0.97)],
    [(T_CAP, 0.97)],
]

CARD_REQUIRES["tax_farming"] = ("X16", "metric68")
LEVEL_TERMS["tax_farming"] = [
    # L1: 全国商人税负容忍度 x1.20；繁市地块贸易产出 +8%（SELF 程序，见 LEVEL_ROWS）
    [(PROF_TOLERANCE("merchant"), 1.20)],
    # L2: x1.30
    [(PROF_TOLERANCE("merchant"), 1.30)],
    # L3: 同 L2，另加「重税繁市（商人实测税负 ≥20%）周围 1 格贸易 +4%」
    [(PROF_TOLERANCE("merchant"), 1.30)],
]

LEVEL_ROWS["tax_farming"] = [
    [prog("tax_farming_l1",
          "繁市地块（最多 32 格）：出生率 -4%（重税的代价）",
          tags=("cell.market",),
          cmds=(mod(city_stat_key("birth_factor"), cell(-4)),))],
    [prog("tax_farming_l2",
          "繁市地块（最多 32 格）：出生率 -4%",
          tags=("cell.market",),
          cmds=(mod(city_stat_key("birth_factor"), cell(-4)),))],
    [prog("tax_farming_l3",
          "繁市地块（最多 32 格）：出生率 -4%",
          tags=("cell.market",),
          cmds=(mod(city_stat_key("birth_factor"), cell(-4)),))],
]

CARD_REQUIRES["land_value"] = ("X16",)
LEVEL_TERMS["land_value"] = [
    # L1: 全国地主税负容忍度 x1.15
    # L2: x1.20
    # L3: 大邑相邻农业支柱地块数 → 大邑出生率（每 1 个 +1%，上限 +6%），
    #     SELF 程序 + Ramp，不需要 X9。
    [(PROF_TOLERANCE("landlord"), 1.15)],
    [(PROF_TOLERANCE("landlord"), 1.20)],
    [(PROF_TOLERANCE("landlord"), 1.20)],
]

# social_media: national per-level rows. The population term is X6-a's
# country.ideology.point_population_factor; the downside lowers the opinion
# floor from 0.5 to 0.4 (ADD-only, so it is a point offset rather than a ratio).
CARD_REQUIRES["social_media"] = ("X6a",)
LEVEL_TERMS["social_media"] = [
    [(POINT_POPULATION, 1.4), (OPINION_FLOOR, -0.1, OP_ADD_DOWNSIDE)],
    [(POINT_POPULATION, 1.6), (OPINION_FLOOR, -0.1, OP_ADD_DOWNSIDE)],
    [(POINT_POPULATION, 1.6), (POINT_TRADE, 1.2),
     (OPINION_FLOOR, -0.1, OP_ADD_DOWNSIDE)],
]

# mandate_of_heaven: the high-hazard-free clause writes the harmony school factor
# from a country program. The low clause is a separate program so the two never
# feed back into the same magnitude they write.
CARD_REQUIRES["mandate_of_heaven"] = ("X13a", "X5")
LEVEL_TERMS["mandate_of_heaven"] = [
    [(POINTS, 0.95)],
    [(POINTS, 0.95)],
    [(POINTS, 0.95)],
]
LEVEL_ROWS["mandate_of_heaven"] = []
for _level, (_strength_threshold, _strength_bonus) in enumerate(
        ((0.80, 0.10), (0.80, 0.15), (0.70, 0.15)), start=1):
    LEVEL_ROWS["mandate_of_heaven"].append([
        prog(f"mandate_of_heaven_l{_level}_harmony_strength",
             f"无灾害地块占比 ≥{int(_strength_threshold * 100)}%："
             f"调和理念等级强度 +{int(_strength_bonus * 100)}%",
             target_domain=DOMAIN_COUNTRY, selector=SEL_OWNER,
             conds=(cond_metric_gte(
                 "country.hazard_free_cell_share_q16",
                 int(_strength_threshold * Q16)),),
             cmds=(mod(country_stat_key(
                 "ideology.school_strength_factor.harmony", cut=False,
                 gain=True), 0.0, domain=1,
                 magnitude_q16=int(_strength_bonus * Q16)),)),
        prog(f"mandate_of_heaven_l{_level}_famine_relief",
             "无灾害地块占比 <50%：全国死亡率 -5%",
             target_domain=DOMAIN_COUNTRY, selector=SEL_OWNER,
             conds=(cond_metric_lte(
                 "country.hazard_free_cell_share_q16", int(0.50 * Q16)),),
             cmds=(mod(country_stat_key("population.death_factor"), 0.0,
                       domain=1, magnitude_q16=int(0.05 * Q16)),)),
    ])

# X6-b: civil_examination reaches L3 by accumulating understanding after equip.
# Its third-level on-enter program grants one free draw. The player still opens
# the offer with OPEN_OFFER; free_draws is row state, not a new player opcode.
#
# ERA_CHANGED -> era_renewal L3 waits for X4 (lane E). Keep that grant in the
# effect content layer when X4 lands; this table is for card-tier grants only.
LEVEL_ON_ENTER_EFFECTS: dict[str, list[list[dict]]] = {
    "civil_examination": [
        [],
        [],
        [{
            "action": 6,
            "domain": 6,
            "opcode": 3,
            "target_resolver": 1,
            "value_mode": 0,
            "value_q16": 1,
            "duration_days": -1,
            "stacks": 1,
            "command_key": "ideology.free_draw",
            "definition_key": "ideology.civil_examination.l3.free_draw",
        }],
    ],
}

LEVEL_ROWS["land_value"] = [
    [prog("land_value_l1",
          "大邑地块（最多 32 格）：住房需求 +5%（地价推高居住成本）",
          tags=("cell.metropolis",),
          cmds=(mod(city_stat_key("need.housing.consumption_factor"), cell(5)),))],
    [prog("land_value_l2",
          "大邑地块（最多 32 格）：住房需求 +5%",
          tags=("cell.metropolis",),
          cmds=(mod(city_stat_key("need.housing.consumption_factor"), cell(5)),))],
    [prog("land_value_l3",
          "大邑地块（最多 32 格）：住房需求 +5%",
          tags=("cell.metropolis",),
          cmds=(mod(city_stat_key("need.housing.consumption_factor"), cell(5)),))],
]

# ── X5: per-country selector rewrites ────────────────────────────────────────
# These cards do not change a shared program template. While the card is
# equipped, the native runtime resolves a rewritten selector for the matching
# programs in that country only; unequipping restores the catalog selector.
#
# antibiotics makes every 大邑 program cover all settlements.
CARD_REQUIRES["antibiotics"] = ("X5",)
LEVEL_REWRITES["antibiotics"] = [
    [rewrite_tag("cell.metropolis", "cell.settlement")],
    [rewrite_tag("cell.metropolis", "cell.settlement")],
    [rewrite_tag("cell.metropolis", "cell.settlement")],
]

# vertical_farm: metropolis counts as an agriculture-pillar cell.
CARD_REQUIRES["vertical_farm"] = ("X5",)
LEVEL_REWRITES["vertical_farm"] = [
    [rewrite_tag("cell.sector.agriculture",
                 "cell.sector.agriculture|cell.metropolis")],
    [rewrite_tag("cell.sector.agriculture",
                 "cell.sector.agriculture|cell.metropolis")],
    [rewrite_tag("cell.sector.agriculture",
                 "cell.sector.agriculture|cell.metropolis")],
]
CARD_META["vertical_farm"] = Meta(route="cropland")
LEVEL_ROWS["vertical_farm"] = [
    [prog("vertical_farm_l1",
          "农业支柱地块（最多 32 格）：农业产出 +8%，全部产出 -2%",
          tags=("cell.sector.agriculture",),
          cmds=(mod(city_stat_key("building.agriculture_output_factor"), cell(8)),
                mod(city_stat_key("output_factor"), cell(-2))))],
    [prog("vertical_farm_l2",
          "农业支柱地块（最多 32 格）：农业产出 +12%，全部产出 -2%",
          tags=("cell.sector.agriculture",),
          cmds=(mod(city_stat_key("building.agriculture_output_factor"), cell(12)),
                mod(city_stat_key("output_factor"), cell(-2))))],
    [prog("vertical_farm_l3",
          "农业支柱地块（最多 32 格）：农业产出 +15%，全部产出 -2%",
          tags=("cell.sector.agriculture",),
          cmds=(mod(city_stat_key("building.agriculture_output_factor"), cell(15)),
                mod(city_stat_key("output_factor"), cell(-2))))],
]

# desalination: coast counts as delta and floodplain.
CARD_REQUIRES["desalination"] = ("X5",)
LEVEL_REWRITES["desalination"] = [
    [rewrite_tag("cell.landform.delta", "cell.landform.coast|cell.landform.delta"),
     rewrite_tag("cell.terrain.floodplain",
                 "cell.landform.coast|cell.terrain.floodplain")],
    [rewrite_tag("cell.landform.delta", "cell.landform.coast|cell.landform.delta"),
     rewrite_tag("cell.terrain.floodplain",
                 "cell.landform.coast|cell.terrain.floodplain")],
    [rewrite_tag("cell.landform.delta", "cell.landform.coast|cell.landform.delta"),
     rewrite_tag("cell.terrain.floodplain",
                 "cell.landform.coast|cell.terrain.floodplain")],
]

# space_mining: any ore-bearing cell counts as every ore condition. The rewrite
# matches the one published ore selector (iron_smelting), but its replacement is
# the full known-ore union, so non-iron sources satisfy that condition after X5.
CARD_REQUIRES["space_mining"] = ("X5",)
_ORE_TAGS = (
    "cell.produces.copper_ore", "cell.produces.iron_ore",
    "cell.produces.lead_ore", "cell.produces.tin_ore",
    "cell.produces.zinc_ore",
)
_ORE_UNION = "|".join(_ORE_TAGS)
LEVEL_REWRITES["space_mining"] = [
    [rewrite_tag("cell.produces.iron_ore", _ORE_UNION)],
    [rewrite_tag("cell.produces.iron_ore", _ORE_UNION)],
    [rewrite_tag("cell.produces.iron_ore", _ORE_UNION)],
]
CARD_META["space_mining"] = Meta(route="mining")
LEVEL_ROWS["space_mining"] = [
    [prog("space_mining_l1",
          "主产矿石的地块（最多 32 格）：矿业产出 +6%，资源消耗 +2%",
          tags=("cell.produces.iron_ore",),
          cmds=(mod(city_stat_key("building.extractive_output_factor"), cell(6)),))],
    [prog("space_mining_l2",
          "主产矿石的地块（最多 32 格）：矿业产出 +9%，资源消耗 +2%",
          tags=("cell.produces.iron_ore",),
          cmds=(mod(city_stat_key("building.extractive_output_factor"), cell(9)),))],
    [prog("space_mining_l3",
          "主产矿石的地块（最多 32 格）：矿业产出 +11%，资源消耗 +2%",
          tags=("cell.produces.iron_ore",),
          cmds=(mod(city_stat_key("building.extractive_output_factor"), cell(11)),))],
]

# autonomous_logistics: thoroughfare range +1. Its own cell program is the
# kind-14 source the route rewrite widens to kind 15; the national transport
# terms from CARDS remain the card's price/benefit.
CARD_REQUIRES["autonomous_logistics"] = ("X5",)
CARD_META["autonomous_logistics"] = Meta(route="thoroughfare")
LEVEL_REWRITES["autonomous_logistics"] = [
    [rewrite_route("thoroughfare", REWRITE_SELECTOR_KIND,
                   value=SEL_TAG_SOURCE_R2)],
    [rewrite_route("thoroughfare", REWRITE_SELECTOR_KIND,
                   value=SEL_TAG_SOURCE_R2)],
    [rewrite_route("thoroughfare", REWRITE_SELECTOR_KIND,
                   value=SEL_TAG_SOURCE_R2)],
]
LEVEL_ROWS["autonomous_logistics"] = [
    [prog("autonomous_logistics_l1",
          "通衢地块周围 1 格（最多 32 格）：全部产出 +2%",
          selector=SEL_TAG_SOURCE_R1, tags=("cell.market",),
          cmds=(mod(city_stat_key("output_factor"), cell(2)),))],
    [prog("autonomous_logistics_l2",
          "通衢地块周围 1 格（最多 32 格）：全部产出 +2%",
          selector=SEL_TAG_SOURCE_R1, tags=("cell.market",),
          cmds=(mod(city_stat_key("output_factor"), cell(2)),))],
    [prog("autonomous_logistics_l3",
          "通衢地块周围 1 格（最多 32 格）：全部产出 +2%",
          selector=SEL_TAG_SOURCE_R1, tags=("cell.market",),
          cmds=(mod(city_stat_key("output_factor"), cell(2)),))],
]

CARD_REQUIRES["petition_box"] = ("X16", "X14")
LEVEL_TERMS["petition_box"] = [
    # Satisfaction and the national rows are unconditional; the farmer-class
    # point-gain gate is a country-domain program below.
    [(PROF_SATISFACTION("agricultural_worker"), 400.0),
     (PROF_SATISFACTION("subsistence_farmer"), 400.0),
     (PROF_SATISFACTION("tenant_farmer"), 400.0),
     (PROF_SATISFACTION("sharecropper"), 400.0),
     (PROF_SATISFACTION("serf"), 400.0),
     (PROF_SATISFACTION("household_farmer"), 400.0),
     (DEATH, 0.97), (R_SOC, 0.98, OP_ADD_DOWNSIDE)],
    # L2: farm-worker satisfaction +6.
    [(PROF_SATISFACTION(pid), 600.0) for pid in profession_group("farm_workers")]
    + [(DEATH, 0.97), (R_SOC, 0.98, OP_ADD_DOWNSIDE)],
    # L3: farm workers +6, wage workers +4.
    [(PROF_SATISFACTION(pid), 600.0) for pid in profession_group("farm_workers")]
    + [(PROF_SATISFACTION(pid), 400.0) for pid in profession_group("wage_workers")]
    + [(DEATH, 0.97), (R_SOC, 0.98, OP_ADD_DOWNSIDE)],
]
LEVEL_ROWS["petition_box"] = [
    [prog("petition_box_l1_low_farmer_opinion",
          "农民阶层民意 <30%：理念点获取 +5%",
          target_domain=DOMAIN_COUNTRY, selector=SEL_OWNER,
          conds=(cond_metric_lte(
              "country.farmer_satisfaction_q16", int(0.3 * Q16)),),
          cmds=(mod(country_stat_key("ideology.point_gain_factor",
                                     cut=False, gain=True),
                    0.0, domain=1, magnitude_q16=int(0.05 * Q16)),))],
    [prog("petition_box_l2_low_farmer_opinion",
          "农民阶层民意 <30%：理念点获取 +5%",
          target_domain=DOMAIN_COUNTRY, selector=SEL_OWNER,
          conds=(cond_metric_lte(
              "country.farmer_satisfaction_q16", int(0.3 * Q16)),),
          cmds=(mod(country_stat_key("ideology.point_gain_factor",
                                     cut=False, gain=True),
                    0.0, domain=1, magnitude_q16=int(0.05 * Q16)),))],
    [prog("petition_box_l3_low_farmer_opinion",
          "农民阶层民意 <30%：理念点获取 +5%",
          target_domain=DOMAIN_COUNTRY, selector=SEL_OWNER,
          conds=(cond_metric_lte(
              "country.farmer_satisfaction_q16", int(0.3 * Q16)),),
          cmds=(mod(country_stat_key("ideology.point_gain_factor",
                                     cut=False, gain=True),
                    0.0, domain=1, magnitude_q16=int(0.05 * Q16)),))],
]

# The X9a rows above add the published programmes; their national tenant
# penalties stay here because this block is the first point where the X16
# helper functions exist.
LEVEL_TERMS["ancestral_hall"] = [
    [(PROF_SATISFACTION(pid), -300.0, OP_ADD_DOWNSIDE)
     for pid in profession_group("tenant_layer")],
    [(PROF_SATISFACTION(pid), -300.0, OP_ADD_DOWNSIDE)
     for pid in profession_group("tenant_layer")],
    [(PROF_SATISFACTION(pid), -300.0, OP_ADD_DOWNSIDE)
     for pid in profession_group("tenant_layer")],
]
LEVEL_TERMS["gentry_patronage"] = [
    [(PROF_SATISFACTION(pid), -200.0, OP_ADD_DOWNSIDE)
     for pid in profession_group("tenant_layer")],
    [(PROF_SATISFACTION(pid), -200.0, OP_ADD_DOWNSIDE)
     for pid in profession_group("tenant_layer")],
    [(PROF_SATISFACTION(pid), -200.0, OP_ADD_DOWNSIDE)
     for pid in profession_group("tenant_layer")],
]

CARD_REQUIRES["tax_holiday"] = ("X16",)
LEVEL_TERMS["tax_holiday"] = [
    # L1: 代价 = 全国商人满意度 -2。收益（免税地块及周围工业/贸易 +12%）需要
    #     地块税政策读取，属 X11 的 per-cell 版本，未写。
    [(PROF_SATISFACTION("merchant"), -200.0, OP_ADD_DOWNSIDE)],
    [(PROF_SATISFACTION("merchant"), -200.0, OP_ADD_DOWNSIDE)],
    [(PROF_SATISFACTION("merchant"), -200.0, OP_ADD_DOWNSIDE)],
]

CARD_REQUIRES["light_levy"] = ("X16", "metric68")
LEVEL_TERMS["light_levy"] = [
    # L1: 轻税农业支柱地块出生率 +6%、农业 +5%（metric 68 程序，见 LEVEL_ROWS）
    # L2: +8% / +7%
    # L3: 全国农耕劳动者满意度 +3
    [(B_COST, 1.03)],
    [(B_COST, 1.03)],
    [(PROF_SATISFACTION(pid), 300.0) for pid in profession_group("farm_workers")]
    + [(B_COST, 1.03)],
]



# ── X1 (v1) targets: the design's per-cell form of the 33 C-c cards ─────────
# `X1_TARGETS[card]` = three levels of programs, exactly like `LEVEL_ROWS`. Two
# cases, both handled by `_merge_x1_targets()` in `main()`:
#
#   1. card ALREADY publishes an old national effect (23 of them) -> the target is
#      merged over `LEVEL_ROWS` only when X1-b is available. Until then the old row
#      keeps publishing, so rewriting a card can never make it vanish.
#   2. card is brand new (10 of them) -> the target is the only definition; staging
#      on ("X1b",) keeps it out of the catalog until the engine can run it.
#
# Values: design doc §5 / §14 verbatim; per-source / radius / cap from
# 09-content-status.md §7.7.3 (反推值登记在 09 §8).
X1_TARGETS: dict[str, list[list[Prog]]] = {}

# Step 6 releases every card whose authored form uses kind 16. Keep the list
# explicit: a card can remain dark for a content decision, but it can no longer
# be silently omitted by turning on the runtime capability. `main()` checks this
# set against the authored programs in both `X1_TARGETS` and direct `LEVEL_ROWS`.
X1B_RELEASE = frozenset({
    "agricultural_chemistry",
    "chemical_industry",
    "collective_stewardship",
    "communal_feast",
    "container_port",
    "cotton_gin",
    "electrification",
    "enclosure",
    "experimental_method",
    "flint_knapping",
    "hydroelectric",
    "iron_smelting",
    "marriage_alliance",
    "motorization",
    "petrochemical",
    "postal_horse",
    "riverside_camp",
    "sericulture",
    "suburbanization",
    "supermarket",
    "telegraph",
    "water_works",
    "bronze_casting",
})


def _x1(key: str, levels: list[list[Prog]]) -> None:
    """Register a card's X1 form. `key` must already be in CARDS."""
    if len(levels) != 3:
        raise SystemExit(f"x1: {key} needs exactly 3 levels")
    X1_TARGETS[key] = levels


# Cards whose design is NATIONAL rather than per-cell cannot be programs: a card
# program may only write `ideology.city.*` stats. They still get their three
# design levels, expressed as national terms instead.
X1_NATIONAL_TERMS: dict[str, list] = {
    # 全国日贸易基础值每达到一档，生产投入下降（上限 -8% / -10% / -10%）。
    # 设计 L3 的「繁市地块投入再 -3%」是 per-cell，属 X1-b 的逐格形态，等它落地。
    "double_entry": [
        [(INPUT, 0.99), (POINTS, 0.97)],
        [(INPUT, 0.985), (POINTS, 0.97)],
        [(INPUT, 0.985), (POINTS, 0.97)],
    ],
}


def _merge_national_targets() -> None:
    """Merge `X1_NATIONAL_TERMS` the same way `merge_x1_targets` merges programs."""
    for key, levels in X1_NATIONAL_TERMS.items():
        if x1_card_ready_for_build(key) or key in X1_BRAND_NEW:
            LEVEL_TERMS[key] = levels
            # A card cannot carry both a per-level national table and a CARDS term
            # list for the same numbers (`§3.4` double-definition).
            for index, card in enumerate(CARDS):
                if card[0] == key:
                    CARDS[index] = card[:9] + ([],)


# ── 田垄 / 仓廪：粮作与专精 ────────────────────────────────────────────────
_x1("colonial_plantation", [
    [prog("colonial_plantation_l1",
          "高度专精的农业支柱地块（最多 32 格）：农业产出 +20%",
          tags=("cell.specialized_high", "cell.sector.agriculture"),
          cmds=(mod(city_stat_key("building.agriculture_output_factor"), cell(20)),))],
    [prog("colonial_plantation_l2",
          "高度专精的农业支柱地块（最多 32 格）：农业产出 +28%",
          tags=("cell.specialized_high", "cell.sector.agriculture"),
          cmds=(mod(city_stat_key("building.agriculture_output_factor"), cell(28)),))],
    [prog("colonial_plantation_l3",
          "高度专精的农业支柱地块（最多 32 格）：农业产出 +28%，产出 -0%",
          tags=("cell.specialized_high", "cell.sector.agriculture"),
          cmds=(mod(city_stat_key("building.agriculture_output_factor"), cell(28)),))],
])

_x1("agrarian_reform", [
    [prog("agrarian_reform_l1",
          "专精的粮作地块（最多 32 格）：农业产出 ×1.10",
          tags=("cell.grain", "cell.specialized"),
          cmds=(mod(city_stat_key("building.agriculture_output_factor"), cell(10)),))],
    [prog("agrarian_reform_l2",
          "专精的粮作地块（最多 32 格）：农业产出 ×1.14",
          tags=("cell.grain", "cell.specialized"),
          cmds=(mod(city_stat_key("building.agriculture_output_factor"), cell(14)),))],
    [prog("agrarian_reform_l3",
          "专精的粮作地块（最多 32 格）：农业产出 ×1.18",
          tags=("cell.grain", "cell.specialized"),
          cmds=(mod(city_stat_key("building.agriculture_output_factor"), cell(18)),))],
])

_x1("enclosure", [
    # §7.7.3: R1, +10% per source, cap 3 at every level. The previous L2/L3
    # values (+15%) were balance drift; step 6 copies the table verbatim.
    [prog("enclosure_l1",
          "主产畜产的地块周围 1 格（每源 +10%，最多 3 源 = +30%）：牧场再生 +30%",
          tags=("cell.produces.livestock_products",),
          selector=SEL_TAG_SOURCE_COUNT, radius=1, cap=3, per_source=cell(10),
          cmds=(mod(city_stat_key("resource.pasture.regen_factor"), 0.0),))],
    [prog("enclosure_l2",
          "主产畜产的地块周围 1 格（每源 +10%，最多 3 源 = +30%）：牧场再生 +30%",
          tags=("cell.produces.livestock_products",),
          selector=SEL_TAG_SOURCE_COUNT, radius=1, cap=3, per_source=cell(10),
          cmds=(mod(city_stat_key("resource.pasture.regen_factor"), 0.0),))],
    [prog("enclosure_l3",
          "主产畜产的地块周围 1 格（每源 +10%，最多 3 源 = +30%）：牧场再生 +30%",
          tags=("cell.produces.livestock_products",),
          selector=SEL_TAG_SOURCE_COUNT, radius=1, cap=3, per_source=cell(10),
          cmds=(mod(city_stat_key("resource.pasture.regen_factor"), 0.0),))],
])

_x1("gene_editing", [
    [prog("gene_editing_l1",
          "专精的粮作地块（最多 32 格）：农业产出 +12%",
          tags=("cell.grain", "cell.specialized"),
          cmds=(mod(city_stat_key("building.agriculture_output_factor"), cell(12)),))],
    [prog("gene_editing_l2",
          "专精的粮作地块（最多 32 格）：农业产出 +16%",
          tags=("cell.grain", "cell.specialized"),
          cmds=(mod(city_stat_key("building.agriculture_output_factor"), cell(16)),))],
    [prog("gene_editing_l3",
          "专精的粮作地块（最多 32 格）：农业产出 +20%",
          tags=("cell.grain", "cell.specialized"),
          cmds=(mod(city_stat_key("building.agriculture_output_factor"), cell(20)),))],
])

_x1("nuclear_power", [
    [prog("nuclear_power_l1",
          "能源支柱地块（最多 32 格）：全部产出 ×1.15",
          tags=("cell.sector.energy",),
          cmds=(mod(city_stat_key("output_factor"), cell(15)),))],
    [prog("nuclear_power_l2",
          "能源支柱地块（最多 32 格）：全部产出 ×1.20",
          tags=("cell.sector.energy",),
          cmds=(mod(city_stat_key("output_factor"), cell(20)),))],
    [prog("nuclear_power_l3",
          "能源支柱地块（最多 32 格）：全部产出 ×1.20",
          tags=("cell.sector.energy",),
          cmds=(mod(city_stat_key("output_factor"), cell(20)),))],
])

_x1("welfare_state", [
    [prog("welfare_state_l1",
          "无短缺的聚落地块（最多 32 格）：全部产出 ×1.10",
          tags=("cell.settlement",),
          conds=(cond_metric_lte("cell.essentials_shortage_q16", int(0.01 * Q16)),),
          cmds=(mod(city_stat_key("output_factor"), cell(10)),))],
    [prog("welfare_state_l2",
          "无短缺的聚落地块（最多 32 格）：全部产出 ×1.14",
          tags=("cell.settlement",),
          conds=(cond_metric_lte("cell.essentials_shortage_q16", int(0.01 * Q16)),),
          cmds=(mod(city_stat_key("output_factor"), cell(14)),))],
    [prog("welfare_state_l3",
          "无短缺的聚落地块（最多 32 格）：全部产出 ×1.14",
          tags=("cell.settlement",),
          conds=(cond_metric_lte("cell.essentials_shortage_q16", int(0.01 * Q16)),),
          cmds=(mod(city_stat_key("output_factor"), cell(14)),))],
])

_x1("suburbanization", [
    [prog("suburbanization_l1",
          "大邑周围 2 格（每源 +5%，最多 3 源 = +15%）：出生率 +15%",
          tags=("cell.metropolis",),
          selector=SEL_TAG_SOURCE_COUNT, radius=2, cap=3, per_source=cell(5),
          cmds=(mod(city_stat_key("birth_factor"), 0.0),)),
     prog("suburbanization_l1_cost",
          "大邑地块：出生率 -5%（市中心空心化）",
          tags=("cell.metropolis",),
          cmds=(mod(city_stat_key("birth_factor"), cell(-5)),))],
    [prog("suburbanization_l2",
          "大邑周围 2 格（每源 +5%，最多 3 源 = +15%）：出生率 +15%",
          tags=("cell.metropolis",),
          selector=SEL_TAG_SOURCE_COUNT, radius=2, cap=3, per_source=cell(5),
          cmds=(mod(city_stat_key("birth_factor"), 0.0),)),
     prog("suburbanization_l2_cost",
          "大邑地块：出生率 -5%",
          tags=("cell.metropolis",),
          cmds=(mod(city_stat_key("birth_factor"), cell(-5)),))],
    [prog("suburbanization_l3",
          "大邑周围 2 格（每源 +5%，最多 3 源 = +15%）：出生率 +15%",
          tags=("cell.metropolis",),
          selector=SEL_TAG_SOURCE_COUNT, radius=2, cap=3, per_source=cell(5),
          cmds=(mod(city_stat_key("birth_factor"), 0.0),)),
     prog("suburbanization_l3_cost",
          "大邑地块：出生率 -5%",
          tags=("cell.metropolis",),
          cmds=(mod(city_stat_key("birth_factor"), cell(-5)),))],
])

_x1("arcology", [
    [prog("arcology_l1",
          "富饶的大邑地块（最多 32 格）：全部产出 +12%，资源再生 +10%",
          tags=("cell.metropolis", "cell.abundant"),
          cmds=(mod(city_stat_key("output_factor"), cell(12)),
                mod(city_stat_key("resource.regen_factor"), cell(10))))],
    [prog("arcology_l2",
          "富饶的大邑地块（最多 32 格）：全部产出 +16%，资源再生 +10%",
          tags=("cell.metropolis", "cell.abundant"),
          cmds=(mod(city_stat_key("output_factor"), cell(16)),
                mod(city_stat_key("resource.regen_factor"), cell(10))))],
    [prog("arcology_l3",
          "富饶的大邑地块（最多 32 格）：全部产出 +16%，资源再生 +10%",
          tags=("cell.metropolis", "cell.abundant"),
          cmds=(mod(city_stat_key("output_factor"), cell(16)),
                mod(city_stat_key("resource.regen_factor"), cell(10))))],
])

_x1("basic_income", [
    [prog("basic_income_l1",
          "失业地块（最多 32 格）：失业率每点知识 +1%（上限 +15%）",
          tags=("cell.unemployed",),
          ramp=Ramp(metric="cell.unemployment_q16", per=1.0, cap=0.15),
          cmds=(mod(city_stat_key("building.knowledge_output_factor"), 0.0),))],
    [prog("basic_income_l2",
          "失业地块（最多 32 格）：失业率每点知识 +1.5%（上限 +15%）",
          tags=("cell.unemployed",),
          # cap = 15% ceiling / 1.5% per point = 10 percentage points.
          ramp=Ramp(metric="cell.unemployment_q16", per=1.5, cap=0.10),
          cmds=(mod(city_stat_key("building.knowledge_output_factor"), 0.0),))],
    [prog("basic_income_l3",
          "失业地块（最多 32 格）：失业率每点知识 +1.5%（上限 +15%）",
          tags=("cell.unemployed",),
          ramp=Ramp(metric="cell.unemployment_q16", per=1.5, cap=0.10),
          cmds=(mod(city_stat_key("building.knowledge_output_factor"), 0.0),)),
     # L3's extra clause is a SEPARATE program: a ramp program carries exactly one
     # command (the ramp), so the flat "出生率 +5%" cannot live in the same one.
     # Dropping it entirely -- which is what L3 did before -- made the level WEAKER
     # than L2, because it lost the knowledge ramp and gained only this.
     prog("basic_income_l3_birth",
          "失业地块（最多 32 格）：出生率 +5%",
          tags=("cell.unemployed",),
          cmds=(mod(city_stat_key("birth_factor"), cell(5)),))],
])

_x1("circular_economy", [
    # design: "成链地块：资源消耗 -15%" -- the stat this card can write is
    # `resource.regen_factor`, which raises REGENERATION. The description must say
    # regeneration, not consumption: on a cost stat -15% is a SAVING, on a regen
    # stat -15% would be a penalty, so the two are not interchangeable words.
    [prog("circular_economy_l1",
          "成链地块（最多 32 格）：资源再生 +15%",
          tags=("cell.chained",),
          cmds=(mod(city_stat_key("resource.regen_factor"), cell(15)),))],
    [prog("circular_economy_l2",
          "成链地块（最多 32 格）：资源再生 +20%",
          tags=("cell.chained",),
          cmds=(mod(city_stat_key("resource.regen_factor"), cell(20)),))],
    [prog("circular_economy_l3",
          "成链地块（最多 32 格）：资源再生 +20%",
          tags=("cell.chained",),
          cmds=(mod(city_stat_key("resource.regen_factor"), cell(20)),))],
])


# ── 矿冶 / 工坊 / 市易 / 通衢 / 学识 / 生灵：外溢与计数 ────────────────────
_x1("chemical_industry", [
    [prog("chemical_industry_l1",
          "主产盐的地块周围 2 格（每源 +15%，最多 3 源 = +45%）：化肥产出 +45%",
          tags=("cell.produces.salt",),
          selector=SEL_TAG_SOURCE_COUNT, radius=2, cap=3, per_source=cell(15),
          cmds=(mod(city_stat_key("good.fertilizer.output_factor"), 0.0),))],
    [prog("chemical_industry_l2",
          "主产盐的地块周围 2 格（每源 +15%，最多 3 源 = +45%）：化肥产出 +45%",
          tags=("cell.produces.salt",),
          selector=SEL_TAG_SOURCE_COUNT, radius=2, cap=3, per_source=cell(15),
          cmds=(mod(city_stat_key("good.fertilizer.output_factor"), 0.0),))],
    [prog("chemical_industry_l3",
          "主产盐的地块周围 2 格（每源 +15%，最多 3 源 = +45%）：化肥产出 +45%",
          tags=("cell.produces.salt",),
          selector=SEL_TAG_SOURCE_COUNT, radius=2, cap=3, per_source=cell(15),
          cmds=(mod(city_stat_key("good.fertilizer.output_factor"), 0.0),))],
])

_x1("manufactory_regulation", [
    [prog("manufactory_regulation_l1",
          "工业建筑 ≥2 座的地块（最多 32 格）：每座工业 +2%（上限 +16%）",
          tags=("cell.sector.manufacturing",),
          ramp=Ramp(metric="cell.manufacturing_building_count", per=0.02, cap=8.0),
          cmds=(mod(city_stat_key("building.manufacturing_output_factor"), 0.0),))],
    [prog("manufactory_regulation_l2",
          "工业建筑 ≥2 座的地块（最多 32 格）：每座工业 +3%（上限 +24%）",
          tags=("cell.sector.manufacturing",),
          ramp=Ramp(metric="cell.manufacturing_building_count", per=0.03, cap=8.0),
          cmds=(mod(city_stat_key("building.manufacturing_output_factor"), 0.0),))],
    [prog("manufactory_regulation_l3",
          "工业建筑 ≥2 座的地块（最多 32 格）：每座工业 +3%（上限 +30%）",
          tags=("cell.sector.manufacturing",),
          ramp=Ramp(metric="cell.manufacturing_building_count", per=0.03, cap=10.0),
          cmds=(mod(city_stat_key("building.manufacturing_output_factor"), 0.0),))],
])

_x1("assembly_line", [
    [prog("assembly_line_l1",
          "成链 ≥2 的地块（最多 32 格）：工业产出 ×1.15",
          tags=("cell.chained",),
          cmds=(mod(city_stat_key("building.manufacturing_output_factor"), cell(15)),))],
    [prog("assembly_line_l2",
          "成链 ≥2 的地块（最多 32 格）：工业产出 ×1.20",
          tags=("cell.chained",),
          cmds=(mod(city_stat_key("building.manufacturing_output_factor"), cell(20)),))],
    [prog("assembly_line_l3",
          "成链 ≥2 的地块（最多 32 格）：工业产出 ×1.20",
          tags=("cell.chained",),
          cmds=(mod(city_stat_key("building.manufacturing_output_factor"), cell(20)),))],
])

_x1("automation_line", [
    [prog("automation_line_l1",
          "工业支柱地块（最多 32 格）：失业率每点工业 +1%（上限 +15%）",
          tags=("cell.sector.manufacturing",),
          ramp=Ramp(metric="cell.unemployment_q16", per=1.0, cap=0.15),
          cmds=(mod(city_stat_key("building.manufacturing_output_factor"), 0.0),))],
    [prog("automation_line_l2",
          "工业支柱地块（最多 32 格）：失业率每点工业 +1.5%（上限 +20%）",
          tags=("cell.sector.manufacturing",),
          # cap = 20% ceiling / 1.5% per point = 13.33 percentage points.
          ramp=Ramp(metric="cell.unemployment_q16", per=1.5, cap=0.1333),
          cmds=(mod(city_stat_key("building.manufacturing_output_factor"), 0.0),))],
    [prog("automation_line_l3",
          "工业支柱地块（最多 32 格）：失业率每点工业 +1.5%（上限 +20%）",
          tags=("cell.sector.manufacturing",),
          ramp=Ramp(metric="cell.unemployment_q16", per=1.5, cap=0.1333),
          cmds=(mod(city_stat_key("building.manufacturing_output_factor"), 0.0),)),
     # Same reason as basic_income_l3: the level's extra clause needs its own
     # program, otherwise L3 silently LOSES the L2 production ramp.
     prog("automation_line_l3_knowledge",
          "工业支柱地块（最多 32 格）：知识产出 +8%",
          tags=("cell.sector.manufacturing",),
          cmds=(mod(city_stat_key("building.knowledge_output_factor"), cell(8)),))],
])

_x1("financialization", [
    [prog("financialization_l1",
          "繁市地块（最多 32 格）：全部产出 ×1.25",
          tags=("cell.market",),
          cmds=(mod(city_stat_key("output_factor"), cell(25)),))],
    [prog("financialization_l2",
          "繁市地块（最多 32 格）：全部产出 ×1.30",
          tags=("cell.market",),
          cmds=(mod(city_stat_key("output_factor"), cell(30)),))],
    [prog("financialization_l3",
          "繁市地块（最多 32 格）：全部产出 ×1.30",
          tags=("cell.market",),
          cmds=(mod(city_stat_key("output_factor"), cell(30)),))],
])

_x1("postal_horse", [
    [prog("postal_horse_l1",
          "主产马匹的地块周围 2 格（每源 +6%，最多 3 源）：全部产出 +18%",
          tags=("cell.produces.horses",),
          selector=SEL_TAG_SOURCE_COUNT, radius=2, cap=3, per_source=cell(6),
          cmds=(mod(city_stat_key("output_factor"), 0.0),))],
    [prog("postal_horse_l2",
          "主产马匹的地块周围 2 格（每源 +6%，最多 3 源）：全部产出 +18%",
          tags=("cell.produces.horses",),
          selector=SEL_TAG_SOURCE_COUNT, radius=2, cap=3, per_source=cell(6),
          cmds=(mod(city_stat_key("output_factor"), 0.0),))],
    [prog("postal_horse_l3",
          "主产马匹的地块周围 2 格（每源 +6%，最多 3 源）：全部产出 +18%",
          tags=("cell.produces.horses",),
          selector=SEL_TAG_SOURCE_COUNT, radius=2, cap=3, per_source=cell(6),
          cmds=(mod(city_stat_key("output_factor"), 0.0),))],
])

_x1("open_ports", [
    [prog("open_ports_l1",
          "海岸地块（最多 32 格）：全部产出 +15%",
          tags=("cell.terrain.coast",),
          cmds=(mod(city_stat_key("output_factor"), cell(15)),))],
    [prog("open_ports_l2",
          "海岸地块（最多 32 格）：全部产出 +22%",
          tags=("cell.terrain.coast",),
          cmds=(mod(city_stat_key("output_factor"), cell(22)),))],
    [prog("open_ports_l3",
          "海岸地块（最多 32 格）：全部产出 +22%",
          tags=("cell.terrain.coast",),
          cmds=(mod(city_stat_key("output_factor"), cell(22)),))],
])

_x1("ocean_company", [
    [prog("ocean_company_l1",
          "海岸繁市地块（最多 32 格）：全部产出 ×1.25",
          tags=("cell.terrain.coast", "cell.market"),
          cmds=(mod(city_stat_key("output_factor"), cell(25)),))],
    [prog("ocean_company_l2",
          "海岸繁市地块（最多 32 格）：全部产出 ×1.30",
          tags=("cell.terrain.coast", "cell.market"),
          cmds=(mod(city_stat_key("output_factor"), cell(30)),))],
    [prog("ocean_company_l3",
          "海岸繁市地块（最多 32 格）：全部产出 ×1.30",
          tags=("cell.terrain.coast", "cell.market"),
          cmds=(mod(city_stat_key("output_factor"), cell(30)),))],
])

_x1("maritime_insurance", [
    [prog("maritime_insurance_l1",
          "海岸地块（最多 32 格）：全部产出 +10%（持续 30 天，可刷新）",
          tags=("cell.terrain.coast",),
          duration_days=30, stack_policy=STACK_REFRESH,
          cmds=(mod(city_stat_key("output_factor"), cell(10)),))],
    [prog("maritime_insurance_l2",
          "海岸地块（最多 32 格）：全部产出 +15%（持续 30 天，可刷新）",
          tags=("cell.terrain.coast",),
          duration_days=30, stack_policy=STACK_REFRESH,
          cmds=(mod(city_stat_key("output_factor"), cell(15)),))],
    [prog("maritime_insurance_l3",
          # L3 keeps L2's output bonus AND adds the need cut. Dropping the bonus
          # made L3 strictly weaker than L2 -- the monotonic lint caught that when
          # the plain switch was simulated.
          "海岸地块（最多 32 格）：全部产出 +15%（持续 30 天，可刷新），"
          "主食需求 -10%",
          tags=("cell.terrain.coast",),
          duration_days=30, stack_policy=STACK_REFRESH,
          cmds=(mod(city_stat_key("output_factor"), cell(15)),
                mod(city_stat_key("need.staple_food.consumption_factor"),
                    cell(-10))))],
])

_x1("container_port", [
    [prog("container_port_l1",
          "海岸繁市地块周围 2 格（每源 +10%，最多 3 源 = +30%）：工业产出 +30%",
          tags=("cell.terrain.coast",),
          selector=SEL_TAG_SOURCE_COUNT, radius=2, cap=3, per_source=cell(10),
          cmds=(mod(city_stat_key("building.manufacturing_output_factor"), 0.0),))],
    [prog("container_port_l2",
          "海岸繁市地块周围 2 格（每源 +10%，最多 3 源 = +30%）：工业产出 +30%",
          tags=("cell.terrain.coast",),
          selector=SEL_TAG_SOURCE_COUNT, radius=2, cap=3, per_source=cell(10),
          cmds=(mod(city_stat_key("building.manufacturing_output_factor"), 0.0),))],
    [prog("container_port_l3",
          "海岸繁市地块周围 2 格（每源 +10%，最多 3 源 = +30%）：工业产出 +30%",
          tags=("cell.terrain.coast",),
          selector=SEL_TAG_SOURCE_COUNT, radius=2, cap=3, per_source=cell(10),
          cmds=(mod(city_stat_key("building.manufacturing_output_factor"), 0.0),))],
])

_x1("department_store", [
    [prog("department_store_l1",
          "大邑地块（最多 32 格）：全部产出 +10%",
          tags=("cell.metropolis",),
          cmds=(mod(city_stat_key("output_factor"), cell(10)),)),
     prog("department_store_l1_cost",
          "大邑地块：家用品、服装需求 +10%（橱窗刺激消费）",
          tags=("cell.metropolis",),
          cmds=(mod(city_stat_key("need.household_goods.consumption_factor"), cell(10)),
                mod(city_stat_key("need.clothing.consumption_factor"), cell(10))))],
    [prog("department_store_l2",
          "大邑地块（最多 32 格）：全部产出 +15%",
          tags=("cell.metropolis",),
          cmds=(mod(city_stat_key("output_factor"), cell(15)),)),
     prog("department_store_l2_cost",
          "大邑地块：家用品、服装需求 +10%",
          tags=("cell.metropolis",),
          cmds=(mod(city_stat_key("need.household_goods.consumption_factor"), cell(10)),
                mod(city_stat_key("need.clothing.consumption_factor"), cell(10))))],
    [prog("department_store_l3",
          "大邑地块（最多 32 格）：全部产出 +15%",
          tags=("cell.metropolis",),
          cmds=(mod(city_stat_key("output_factor"), cell(15)),)),
     prog("department_store_l3_cost",
          "大邑地块：家用品、服装需求 +10%",
          tags=("cell.metropolis",),
          cmds=(mod(city_stat_key("need.household_goods.consumption_factor"), cell(10)),
                mod(city_stat_key("need.clothing.consumption_factor"), cell(10))))],
])

_x1("supermarket", [
    [prog("supermarket_l1",
          "聚落地块周围 1 格（每源 +6%，最多 3 源 = +18%）：农业产出 +18%",
          tags=("cell.settlement",),
          selector=SEL_TAG_SOURCE_COUNT, radius=1, cap=3, per_source=cell(6),
          cmds=(mod(city_stat_key("building.agriculture_output_factor"), 0.0),))],
    [prog("supermarket_l2",
          "聚落地块周围 1 格（每源 +6%，最多 3 源 = +18%）：农业产出 +18%",
          tags=("cell.settlement",),
          selector=SEL_TAG_SOURCE_COUNT, radius=1, cap=3, per_source=cell(6),
          cmds=(mod(city_stat_key("building.agriculture_output_factor"), 0.0),))],
    [prog("supermarket_l3",
          "聚落地块周围 1 格（每源 +6%，最多 3 源 = +18%）：农业产出 +18%",
          tags=("cell.settlement",),
          selector=SEL_TAG_SOURCE_COUNT, radius=1, cap=3, per_source=cell(6),
          cmds=(mod(city_stat_key("building.agriculture_output_factor"), 0.0),))],
])

_x1("offshore_drilling", [
    [prog("offshore_drilling_l1",
          "海岸地块（最多 32 格）：原油、天然气产出 +15%",
          tags=("cell.terrain.coast",),
          cmds=(mod(city_stat_key("good.crude_oil.output_factor"), cell(15)),
                mod(city_stat_key("good.natural_gas.output_factor"), cell(15))))],
    [prog("offshore_drilling_l2",
          "海岸地块（最多 32 格）：原油、天然气产出 +20%",
          tags=("cell.terrain.coast",),
          cmds=(mod(city_stat_key("good.crude_oil.output_factor"), cell(20)),
                mod(city_stat_key("good.natural_gas.output_factor"), cell(20))))],
    [prog("offshore_drilling_l3",
          "海岸地块（最多 32 格）：原油、天然气产出 +20%",
          tags=("cell.terrain.coast",),
          cmds=(mod(city_stat_key("good.crude_oil.output_factor"), cell(20)),
                mod(city_stat_key("good.natural_gas.output_factor"), cell(20))))],
])

_x1("gig_economy", [
    [prog("gig_economy_l1",
          "失业地块（最多 32 格）：失业率每点全部产出 +1%（上限 +12%）",
          tags=("cell.unemployed",),
          ramp=Ramp(metric="cell.unemployment_q16", per=1.0, cap=0.12),
          cmds=(mod(city_stat_key("output_factor"), 0.0),)),
     prog("gig_economy_l1_cost",
          "失业地块：出生率 -3%（收入不稳）",
          tags=("cell.unemployed",),
          cmds=(mod(city_stat_key("birth_factor"), cell(-3)),))],
    [prog("gig_economy_l2",
          "失业地块（最多 32 格）：失业率每点全部产出 +1%（上限 +16%）",
          tags=("cell.unemployed",),
          ramp=Ramp(metric="cell.unemployment_q16", per=1.0, cap=0.16),
          cmds=(mod(city_stat_key("output_factor"), 0.0),)),
     prog("gig_economy_l2_cost",
          "失业地块：出生率 -3%",
          tags=("cell.unemployed",),
          cmds=(mod(city_stat_key("birth_factor"), cell(-3)),))],
    [prog("gig_economy_l3",
          "失业地块（最多 32 格）：失业率每点全部产出 +1%（上限 +16%）",
          tags=("cell.unemployed",),
          ramp=Ramp(metric="cell.unemployment_q16", per=1.0, cap=0.16),
          cmds=(mod(city_stat_key("output_factor"), 0.0),)),
     prog("gig_economy_l3_cost",
          "失业地块：出生率 -3%",
          tags=("cell.unemployed",),
          cmds=(mod(city_stat_key("birth_factor"), cell(-3)),))],
])

_x1("scholar_office", [
    [prog("scholar_office_l1",
          "知识建筑 ≥2 类的地块（最多 32 格）：知识产出 +10%",
          tags=("cell.sector.knowledge",),
          cmds=(mod(city_stat_key("building.knowledge_output_factor"), cell(10)),))],
    [prog("scholar_office_l2",
          "知识建筑 ≥2 类的地块（最多 32 格）：知识产出 +15%",
          tags=("cell.sector.knowledge",),
          cmds=(mod(city_stat_key("building.knowledge_output_factor"), cell(15)),))],
    [prog("scholar_office_l3",
          "知识建筑 ≥2 类的地块（最多 32 格）：知识产出 +15%",
          tags=("cell.sector.knowledge",),
          cmds=(mod(city_stat_key("building.knowledge_output_factor"), cell(15)),))],
])

_x1("experimental_method", [
    [prog("experimental_method_l1",
          "知识占比 ≥20% 的地块周围 2 格（每源 +6%，最多 3 源）：工业 +6%",
          tags=("cell.sector.knowledge",),
          selector=SEL_TAG_SOURCE_COUNT, radius=2, cap=3, per_source=cell(6),
          cmds=(mod(city_stat_key("building.manufacturing_output_factor"), 0.0),))],
    [prog("experimental_method_l2",
          "知识占比 ≥20% 的地块周围 2 格（每源 +9%，最多 3 源）：工业 +27%：工业 +9%",
          tags=("cell.sector.knowledge",),
          selector=SEL_TAG_SOURCE_COUNT, radius=2, cap=3, per_source=cell(9),
          cmds=(mod(city_stat_key("building.manufacturing_output_factor"), 0.0),))],
    [prog("experimental_method_l3",
          "知识占比 ≥20% 的地块周围 2 格（每源 +9%，最多 3 源）：工业 +27%",
          tags=("cell.sector.knowledge",),
          selector=SEL_TAG_SOURCE_COUNT, radius=2, cap=3, per_source=cell(9),
          cmds=(mod(city_stat_key("building.manufacturing_output_factor"), 0.0),))],
])

_x1("telegraph", [
    [prog("telegraph_l1",
          "知识支柱地块周围 2 格（每源 +6%，最多 3 源）：知识 +6%、贸易 +3%",
          tags=("cell.sector.knowledge",),
          selector=SEL_TAG_SOURCE_COUNT, radius=2, cap=3, per_source=cell(6),
          cmds=(mod(city_stat_key("building.knowledge_output_factor"), 0.0),))],
    [prog("telegraph_l2",
          "知识支柱地块周围 2 格（每源 +9%，最多 3 源）：知识 +9%",
          tags=("cell.sector.knowledge",),
          selector=SEL_TAG_SOURCE_COUNT, radius=2, cap=3, per_source=cell(9),
          cmds=(mod(city_stat_key("building.knowledge_output_factor"), 0.0),))],
    [prog("telegraph_l3",
          "知识支柱地块周围 3 格（每源 +9%，最多 3 源）",
          tags=("cell.sector.knowledge",),
          selector=SEL_TAG_SOURCE_COUNT, radius=3, cap=3, per_source=cell(9),
          cmds=(mod(city_stat_key("building.knowledge_output_factor"), 0.0),))],
])

_x1("fire_keeping", [
    [prog("fire_keeping_l1",
          "年均温 ≤0℃ 的地块（最多 32 格）：出生率 +5%",
          tags=("cell.terrain.tundra",),
          cmds=(mod(city_stat_key("birth_factor"), cell(5)),))],
    [prog("fire_keeping_l2",
          "年均温 ≤0℃ 的地块（最多 32 格）：出生率 +8%",
          tags=("cell.terrain.tundra",),
          cmds=(mod(city_stat_key("birth_factor"), cell(8)),))],
    [prog("fire_keeping_l3",
          "冻原地块（最多 32 格）：出生率 +8%、农业 +8%",
          tags=("cell.terrain.tundra",),
          cmds=(mod(city_stat_key("birth_factor"), cell(8)),
                mod(city_stat_key("building.agriculture_output_factor"), cell(8))))],
])

_x1("heaven_human", [
    [prog("heaven_human_l1",
          "农业支柱地块（最多 32 格）：降水充足时农业 +6%",
          tags=("cell.sector.agriculture",),
          conds=(cond_metric_gte("cell.precipitation_q16", int(0.5 * Q16)),),
          cmds=(mod(city_stat_key("building.agriculture_output_factor"), cell(6)),))],
    [prog("heaven_human_l2",
          "农业支柱地块（最多 32 格）：降水充足时农业 +9%",
          tags=("cell.sector.agriculture",),
          conds=(cond_metric_gte("cell.precipitation_q16", int(0.5 * Q16)),),
          cmds=(mod(city_stat_key("building.agriculture_output_factor"), cell(9)),))],
    [prog("heaven_human_l3",
          "农业支柱地块（最多 32 格）：降水充足时农业 +9%",
          tags=("cell.sector.agriculture",),
          conds=(cond_metric_gte("cell.precipitation_q16", int(0.5 * Q16)),),
          cmds=(mod(city_stat_key("building.agriculture_output_factor"), cell(9)),))],
])

_x1("carbon_market", [
    [prog("carbon_market_l1",
          "非工业支柱地块（最多 32 格）：全部产出 +6%",
          tags=("cell.diversified",),
          cmds=(mod(city_stat_key("output_factor"), cell(6)),))],
    [prog("carbon_market_l2",
          "非工业支柱地块（最多 32 格）：全部产出 +9%",
          tags=("cell.diversified",),
          cmds=(mod(city_stat_key("output_factor"), cell(9)),))],
    [prog("carbon_market_l3",
          "非工业支柱地块（最多 32 格）：全部产出 +9%",
          tags=("cell.diversified",),
          cmds=(mod(city_stat_key("output_factor"), cell(9)),))],
])

_x1("communal_feast", [
    [prog("communal_feast_l1",
          "主产野味/鱼/采集物的地块周围 1 格（每源 +3%，最多 3 源 = +9%）：出生率 +9%",
          tags=("cell.produces.game_meat",),
          selector=SEL_TAG_SOURCE_COUNT, radius=1, cap=3, per_source=cell(3),
          cmds=(mod(city_stat_key("birth_factor"), 0.0),))],
    [prog("communal_feast_l2",
          "主产野味的地块周围 1 格（每源 +3%，最多 3 源 = +9%）：出生率 +9%",
          tags=("cell.produces.game_meat",),
          selector=SEL_TAG_SOURCE_COUNT, radius=1, cap=3, per_source=cell(3),
          cmds=(mod(city_stat_key("birth_factor"), 0.0),))],
    [prog("communal_feast_l3",
          "主产野味的地块周围 1 格（每源 +3%，最多 3 源 = +9%）：出生率 +9%",
          tags=("cell.produces.game_meat",),
          selector=SEL_TAG_SOURCE_COUNT, radius=1, cap=3, per_source=cell(3),
          cmds=(mod(city_stat_key("birth_factor"), 0.0),))],
])


# ── 纯国家级 / 计数卡（不需要 kind 16，但仍属这 33 张的设计形态） ────────

_x1("free_trade", [
    [prog("free_trade_l1",
          "非多元的工业支柱地块（最多 32 格）：工业 -5%",
          tags=("cell.sector.manufacturing",),
          conds=(cond_metric_lte("cell.distinct_sector_count", int(2 * Q16)),),
          cmds=(mod(city_stat_key("building.manufacturing_output_factor"), cell(-5)),))],
    [prog("free_trade_l2",
          "非多元的工业支柱地块（最多 32 格）：工业 -5%",
          tags=("cell.sector.manufacturing",),
          conds=(cond_metric_lte("cell.distinct_sector_count", int(2 * Q16)),),
          cmds=(mod(city_stat_key("building.manufacturing_output_factor"), cell(-5)),))],
    [prog("free_trade_l3",
          "多元地块（最多 32 格）：全部产出 +10%",
          tags=("cell.diversified",),
          cmds=(mod(city_stat_key("output_factor"), cell(10)),))],
])

# ── X1 spillover cards: "each source cell -> its neighbourhood" ─────────────
# `SEL_TAG_SOURCE_R1/R2` walks the country's own cells for the tag, expands one
# ring per source, unions and caps. Before X1 these cards could only be anchored
# on the country's first owned cell, which silently buffed the capital's
# neighbourhood instead of every production site's.

CARD_META["iron_smelting"] = Meta(route="mining")
LEVEL_ROWS["iron_smelting"] = [
    [prog("iron_smelting_l1", "主产铁矿石的地块周围 1 格（最多 32 格）：工业产出 +10%",
          selector=SEL_TAG_SOURCE_R1, tags=("cell.produces.iron_ore",),
          cmds=(mod(city_stat_key("building.manufacturing_output_factor"), cell(10)),))],
    [prog("iron_smelting_l2", "主产铁矿石的地块周围 1 格（最多 32 格）：工业产出 +14%",
          selector=SEL_TAG_SOURCE_R1, tags=("cell.produces.iron_ore",),
          cmds=(mod(city_stat_key("building.manufacturing_output_factor"), cell(14)),))],
    [prog("iron_smelting_l3", "主产铁矿石的地块周围 1 格（最多 32 格）：工业产出 +18%",
          selector=SEL_TAG_SOURCE_R1, tags=("cell.produces.iron_ore",),
          cmds=(mod(city_stat_key("building.manufacturing_output_factor"), cell(18)),))],
]

# X1-b teaching card. Kind 16 supplies the per-source neighbourhood bonus; the
# L3 target filter is a separate selector-12 program over the target's dominant
# output good, expressed as one canonical OR tag.
_x1("iron_smelting", [
    [prog("iron_smelting_l1",
          "主产铁矿石的地块周围 1 格（每源 +10%，最多 3 源 = +30%）：工业产出 +30%",
          selector=SEL_TAG_SOURCE_COUNT, radius=1, cap=3, per_source=cell(10),
          tags=("cell.produces.iron_ore",),
          cmds=(mod(city_stat_key("building.manufacturing_output_factor"), 0.0),))],
    [prog("iron_smelting_l2",
          "主产铁矿石的地块周围 2 格（每源 +10%，最多 3 源 = +30%）：工业产出 +30%",
          selector=SEL_TAG_SOURCE_COUNT, radius=2, cap=3, per_source=cell(10),
          tags=("cell.produces.iron_ore",),
          cmds=(mod(city_stat_key("building.manufacturing_output_factor"), 0.0),))],
    [prog("iron_smelting_l3",
          "主产铁矿石的地块周围 1 格（每源 +10%，最多 3 源 = +30%）：工业产出 +30%",
          selector=SEL_TAG_SOURCE_COUNT, radius=1, cap=3, per_source=cell(10),
          tags=("cell.produces.iron_ore",),
          cmds=(mod(city_stat_key("building.manufacturing_output_factor"), 0.0),)),
     prog("iron_smelting_l3_target_output",
          "主产熟铁、钢或工具的地块（最多 32 格）：工业产出 +10%",
          selector=SEL_OWN_TERRITORY,
          tags=("cell.produces.steel|cell.produces.tools|cell.produces.wrought_iron",),
          cmds=(mod(city_stat_key("building.manufacturing_output_factor"), cell(10)),))],
])

CARD_META["flint_knapping"] = Meta(route="mining")
_x1("flint_knapping", [
    [prog("flint_knapping_l1",
          "主产燧石的地块周围 1 格（每源 +4%，最多 3 源 = +12%）：全部产出 +12%",
          tags=("cell.produces.flint",),
          selector=SEL_TAG_SOURCE_COUNT, radius=1, cap=3, per_source=cell(4),
          cmds=(mod(city_stat_key("output_factor"), 0.0),))],
    [prog("flint_knapping_l2",
          "主产燧石的地块周围 1 格（每源 +4%，最多 3 源 = +12%）：全部产出 +12%",
          tags=("cell.produces.flint",),
          selector=SEL_TAG_SOURCE_COUNT, radius=1, cap=3, per_source=cell(4),
          cmds=(mod(city_stat_key("output_factor"), 0.0),))],
    [prog("flint_knapping_l3",
          "主产燧石的地块周围 1 格（每源 +4%，最多 3 源 = +12%）：全部产出 +12%",
          tags=("cell.produces.flint",),
          selector=SEL_TAG_SOURCE_COUNT, radius=1, cap=3, per_source=cell(4),
          cmds=(mod(city_stat_key("output_factor"), 0.0),))],
])

CARD_META["sericulture"] = Meta(route="workshop")
_x1("sericulture", [
    [prog("sericulture_l1",
          "主产布的地块周围 1 格（每源 +12%，最多 3 源 = +36%）：精致服装产出 +36%",
          tags=("cell.produces.cloth",),
          selector=SEL_TAG_SOURCE_COUNT, radius=1, cap=3, per_source=cell(12),
          cmds=(mod(city_stat_key("good.fine_clothing.output_factor"), 0.0),))],
    [prog("sericulture_l2",
          "主产布的地块周围 1 格（每源 +12%，最多 3 源 = +36%）：精致服装产出 +36%",
          tags=("cell.produces.cloth",),
          selector=SEL_TAG_SOURCE_COUNT, radius=1, cap=3, per_source=cell(12),
          cmds=(mod(city_stat_key("good.fine_clothing.output_factor"), 0.0),))],
    [prog("sericulture_l3",
          "主产布的地块周围 1 格（每源 +12%，最多 3 源 = +36%）：精致服装产出 +36%",
          tags=("cell.produces.cloth",),
          selector=SEL_TAG_SOURCE_COUNT, radius=1, cap=3, per_source=cell(12),
          cmds=(mod(city_stat_key("good.fine_clothing.output_factor"), 0.0),))],
])

CARD_META["cotton_gin"] = Meta(route="workshop")
_x1("cotton_gin", [
    [prog("cotton_gin_l1",
          "主产棉纤维的地块周围 2 格（每源 +10%，最多 3 源 = +30%）：布产出 +30%",
          tags=("cell.produces.cotton_fiber",),
          selector=SEL_TAG_SOURCE_COUNT, radius=2, cap=3, per_source=cell(10),
          cmds=(mod(city_stat_key("good.cloth.output_factor"), 0.0),))],
    [prog("cotton_gin_l2",
          "主产棉纤维的地块周围 2 格（每源 +10%，最多 3 源 = +30%）：布产出 +30%",
          tags=("cell.produces.cotton_fiber",),
          selector=SEL_TAG_SOURCE_COUNT, radius=2, cap=3, per_source=cell(10),
          cmds=(mod(city_stat_key("good.cloth.output_factor"), 0.0),))],
    [prog("cotton_gin_l3",
          "主产棉纤维的地块周围 2 格（每源 +10%，最多 3 源 = +30%）：布产出 +30%",
          tags=("cell.produces.cotton_fiber",),
          selector=SEL_TAG_SOURCE_COUNT, radius=2, cap=3, per_source=cell(10),
          cmds=(mod(city_stat_key("good.cloth.output_factor"), 0.0),))],
])

CARD_META["agricultural_chemistry"] = Meta(route="cropland")
_x1("agricultural_chemistry", [
    [prog("agricultural_chemistry_l1",
          "主产化肥的地块周围 2 格（每源 +8%，最多 3 源 = +24%）：农业产出 +24%",
          tags=("cell.produces.fertilizer",),
          selector=SEL_TAG_SOURCE_COUNT, radius=2, cap=3, per_source=cell(8),
          cmds=(mod(city_stat_key("building.agriculture_output_factor"), 0.0),))],
    [prog("agricultural_chemistry_l2",
          "主产化肥的地块周围 2 格（每源 +8%，最多 3 源 = +24%）：农业产出 +24%",
          tags=("cell.produces.fertilizer",),
          selector=SEL_TAG_SOURCE_COUNT, radius=2, cap=3, per_source=cell(8),
          cmds=(mod(city_stat_key("building.agriculture_output_factor"), 0.0),))],
    [prog("agricultural_chemistry_l3",
          "主产化肥的地块周围 2 格（每源 +8%，最多 3 源 = +24%）：农业产出 +24%",
          tags=("cell.produces.fertilizer",),
          selector=SEL_TAG_SOURCE_COUNT, radius=2, cap=3, per_source=cell(8),
          cmds=(mod(city_stat_key("building.agriculture_output_factor"), 0.0),))],
])

CARD_META["petrochemical"] = Meta(route="workshop")
_x1("petrochemical", [
    [prog("petrochemical_l1_plastics",
          "主产原油的地块周围 2 格（每源 +12%，最多 3 源 = +36%）：塑料产出 +36%",
          tags=("cell.produces.crude_oil",),
          selector=SEL_TAG_SOURCE_COUNT, radius=2, cap=3, per_source=cell(12),
          cmds=(mod(city_stat_key("good.plastics.output_factor"), 0.0),)),
     prog("petrochemical_l1_synthetic_fiber",
          "主产原油的地块周围 2 格（每源 +12%，最多 3 源 = +36%）：合成纤维产出 +36%",
          tags=("cell.produces.crude_oil",),
          selector=SEL_TAG_SOURCE_COUNT, radius=2, cap=3, per_source=cell(12),
          cmds=(mod(city_stat_key("good.synthetic_fiber.output_factor"), 0.0),))],
    [prog("petrochemical_l2_plastics",
          "主产原油的地块周围 2 格（每源 +12%，最多 3 源 = +36%）：塑料产出 +36%",
          tags=("cell.produces.crude_oil",),
          selector=SEL_TAG_SOURCE_COUNT, radius=2, cap=3, per_source=cell(12),
          cmds=(mod(city_stat_key("good.plastics.output_factor"), 0.0),)),
     prog("petrochemical_l2_synthetic_fiber",
          "主产原油的地块周围 2 格（每源 +12%，最多 3 源 = +36%）：合成纤维产出 +36%",
          tags=("cell.produces.crude_oil",),
          selector=SEL_TAG_SOURCE_COUNT, radius=2, cap=3, per_source=cell(12),
          cmds=(mod(city_stat_key("good.synthetic_fiber.output_factor"), 0.0),))],
    [prog("petrochemical_l3_plastics",
          "主产原油的地块周围 2 格（每源 +12%，最多 3 源 = +36%）：塑料产出 +36%",
          tags=("cell.produces.crude_oil",),
          selector=SEL_TAG_SOURCE_COUNT, radius=2, cap=3, per_source=cell(12),
          cmds=(mod(city_stat_key("good.plastics.output_factor"), 0.0),)),
     prog("petrochemical_l3_synthetic_fiber",
          "主产原油的地块周围 2 格（每源 +12%，最多 3 源 = +36%）：合成纤维产出 +36%",
          tags=("cell.produces.crude_oil",),
          selector=SEL_TAG_SOURCE_COUNT, radius=2, cap=3, per_source=cell(12),
          cmds=(mod(city_stat_key("good.synthetic_fiber.output_factor"), 0.0),))],
])

CARD_META["collective_stewardship"] = Meta(route="cropland")
_x1("collective_stewardship", [
    [prog("collective_stewardship_l1",
          "农业支柱地块周围 1 格（每源 +3%，最多 3 源 = +9%）：全部产出 +9%",
          tags=("cell.sector.agriculture",),
          selector=SEL_TAG_SOURCE_COUNT, radius=1, cap=3, per_source=cell(3),
          cmds=(mod(city_stat_key("output_factor"), 0.0),))],
    [prog("collective_stewardship_l2",
          "农业支柱地块周围 1 格（每源 +3%，最多 3 源 = +9%）：全部产出 +9%",
          tags=("cell.sector.agriculture",),
          selector=SEL_TAG_SOURCE_COUNT, radius=1, cap=3, per_source=cell(3),
          cmds=(mod(city_stat_key("output_factor"), 0.0),))],
    [prog("collective_stewardship_l3",
          "农业支柱地块周围 1 格（每源 +3%，最多 3 源 = +9%）：全部产出 +9%",
          tags=("cell.sector.agriculture",),
          selector=SEL_TAG_SOURCE_COUNT, radius=1, cap=3, per_source=cell(3),
          cmds=(mod(city_stat_key("output_factor"), 0.0),))],
])

CARD_META["electrification"] = Meta(route="workshop")
_x1("electrification", [
    [prog("electrification_l1",
          "能源支柱地块周围 2 格（每源 +8%，最多 3 源 = +24%）：工业产出 +24%",
          tags=("cell.sector.energy",),
          selector=SEL_TAG_SOURCE_COUNT, radius=2, cap=3, per_source=cell(8),
          cmds=(mod(city_stat_key("building.manufacturing_output_factor"), 0.0),))],
    [prog("electrification_l2",
          "能源支柱地块周围 2 格（每源 +8%，最多 3 源 = +24%）：工业产出 +24%",
          tags=("cell.sector.energy",),
          selector=SEL_TAG_SOURCE_COUNT, radius=2, cap=3, per_source=cell(8),
          cmds=(mod(city_stat_key("building.manufacturing_output_factor"), 0.0),))],
    [prog("electrification_l3",
          "能源支柱地块周围 2 格（每源 +8%，最多 3 源 = +24%）：工业产出 +24%",
          tags=("cell.sector.energy",),
          selector=SEL_TAG_SOURCE_COUNT, radius=2, cap=3, per_source=cell(8),
          cmds=(mod(city_stat_key("building.manufacturing_output_factor"), 0.0),))],
])

CARD_META["motorization"] = Meta(route="thoroughfare")
_x1("motorization", [
    [prog("motorization_l1",
          "繁市地块周围 2 格（每源 +4%，最多 3 源 = +12%）：全部产出 +12%",
          tags=("cell.market",),
          selector=SEL_TAG_SOURCE_COUNT, radius=2, cap=3, per_source=cell(4),
          cmds=(mod(city_stat_key("output_factor"), 0.0),))],
    [prog("motorization_l2",
          "繁市地块周围 2 格（每源 +4%，最多 3 源 = +12%）：全部产出 +12%",
          tags=("cell.market",),
          selector=SEL_TAG_SOURCE_COUNT, radius=2, cap=3, per_source=cell(4),
          cmds=(mod(city_stat_key("output_factor"), 0.0),))],
    [prog("motorization_l3",
          "繁市地块周围 2 格（每源 +4%，最多 3 源 = +12%）：全部产出 +12%",
          tags=("cell.market",),
          selector=SEL_TAG_SOURCE_COUNT, radius=2, cap=3, per_source=cell(4),
          cmds=(mod(city_stat_key("output_factor"), 0.0),))],
])

# ── X3-b: profession-class threshold cards ──────────────────────────────────
# The share metrics are Q16 ratios over the cell's known-profession population.
# trade_unions uses mutually exclusive rows for the two opinion bands so the
# resulting magnitude is the authored total, not two factors multiplied.
CARD_REQUIRES["trade_unions"] = ("X3b", "X14")
CARD_META["trade_unions"] = Meta(route="labor")
LEVEL_ROWS["trade_unions"] = [
    [
        prog("trade_unions_l1",
             "工业职业占比 ≥25%、且工人阶层民意 <0.2 的地块：工业产出 +10%",
             tags=("cell.sector.manufacturing",),
             conds=(cond_metric_gte(
                        "cell.profession_share_industrial_q16", _pct(25)),
                    cond_metric_lte(
                        "country.worker_class_satisfaction_q16",
                        int(0.2 * Q16) - 1),),
             cmds=(mod(city_stat_key(
                 "building.manufacturing_output_factor"), cell(10)),)),
        prog("trade_unions_l1_worker_bonus",
             "工业职业占比 ≥25%、且工人阶层民意 ≥0.2 的地块：工业产出 +20%",
             tags=("cell.sector.manufacturing",),
             conds=(cond_metric_gte(
                        "cell.profession_share_industrial_q16", _pct(25)),
                    cond_metric_gte(
                        "country.worker_class_satisfaction_q16",
                        int(0.2 * Q16))),
             cmds=(mod(city_stat_key(
                 "building.manufacturing_output_factor"), cell(20)),)),
    ],
    [
        prog("trade_unions_l2",
             "工业职业占比 ≥25%、且工人阶层民意 <0.2 的地块：工业产出 +14%",
             tags=("cell.sector.manufacturing",),
             conds=(cond_metric_gte(
                        "cell.profession_share_industrial_q16", _pct(25)),
                    cond_metric_lte(
                        "country.worker_class_satisfaction_q16",
                        int(0.2 * Q16) - 1),),
             cmds=(mod(city_stat_key(
                 "building.manufacturing_output_factor"), cell(14)),)),
        prog("trade_unions_l2_worker_bonus",
             "工业职业占比 ≥25%、且工人阶层民意 ≥0.2 的地块：工业产出 +28%",
             tags=("cell.sector.manufacturing",),
             conds=(cond_metric_gte(
                        "cell.profession_share_industrial_q16", _pct(25)),
                    cond_metric_gte(
                        "country.worker_class_satisfaction_q16",
                        int(0.2 * Q16))),
             cmds=(mod(city_stat_key(
                 "building.manufacturing_output_factor"), cell(28)),)),
    ],
    [
        prog("trade_unions_l3",
             "工业职业占比 ≥20%、且工人阶层民意 <0.2 的地块：工业产出 +14%",
             tags=("cell.sector.manufacturing",),
             conds=(cond_metric_gte(
                        "cell.profession_share_industrial_q16", _pct(20)),
                    cond_metric_lte(
                        "country.worker_class_satisfaction_q16",
                        int(0.2 * Q16) - 1),),
             cmds=(mod(city_stat_key(
                 "building.manufacturing_output_factor"), cell(14)),)),
        prog("trade_unions_l3_worker_bonus",
             "工业职业占比 ≥20%、且工人阶层民意 ≥0.2 的地块：工业产出 +28%",
             tags=("cell.sector.manufacturing",),
             conds=(cond_metric_gte(
                        "cell.profession_share_industrial_q16", _pct(20)),
                    cond_metric_gte(
                        "country.worker_class_satisfaction_q16",
                        int(0.2 * Q16))),
             cmds=(mod(city_stat_key(
                 "building.manufacturing_output_factor"), cell(28)),)),
    ],
]

CARD_REQUIRES["cooperative"] = ("X3b",)
CARD_META["cooperative"] = Meta(route="cropland")
LEVEL_ROWS["cooperative"] = [
    [prog("cooperative_l1",
          "合作社职业占比 ≥20% 的地块：农业产出 +12%",
          tags=("cell.sector.agriculture",),
          conds=(cond_metric_gte(
              "cell.profession_share_cooperative_q16", _pct(20)),),
          cmds=(mod(city_stat_key("building.agriculture_output_factor"),
                    cell(12)),))],
    [prog("cooperative_l2",
          "合作社职业占比 ≥20% 的地块：农业产出 +16%",
          tags=("cell.sector.agriculture",),
          conds=(cond_metric_gte(
              "cell.profession_share_cooperative_q16", _pct(20)),),
          cmds=(mod(city_stat_key("building.agriculture_output_factor"),
                    cell(16)),))],
    [prog("cooperative_l3",
          "合作社职业占比 ≥15% 的地块：农业产出 +16%",
          tags=("cell.sector.agriculture",),
          conds=(cond_metric_gte(
              "cell.profession_share_cooperative_q16", _pct(15)),),
          cmds=(mod(city_stat_key("building.agriculture_output_factor"),
                    cell(16)),))],
]

# ── C 级：需要新指标的地块卡（X3 职业构成 / X2 邻域 / X11 税负）───────────
# These are the first production cards that use a metric **condition** at all.
# The tag picks the population, the condition narrows it further per target
# cell, and the effect lands on the cell itself.

CARD_META["hunting_tradition"] = Meta(route="livelihood")
LEVEL_ROWS["hunting_tradition"] = [
    [prog("hunting_tradition_l1", "主产野味、且单一职业占比 ≥60% 的地块：野味产出 +12%",
          tags=("cell.produces.game_meat",),
          conds=(cond_metric_gte("cell.dominant_profession_share_q16", _pct(60)),),
          cmds=(mod(city_stat_key("good.game_meat.output_factor"), cell(12)),))],
    [prog("hunting_tradition_l2", "主产野味、且单一职业占比 ≥60% 的地块：野味产出 +16%",
          tags=("cell.produces.game_meat",),
          conds=(cond_metric_gte("cell.dominant_profession_share_q16", _pct(60)),),
          cmds=(mod(city_stat_key("good.game_meat.output_factor"), cell(16)),))],
    [prog("hunting_tradition_l3", "主产野味、且单一职业占比 ≥60% 的地块：野味产出 +20%",
          tags=("cell.produces.game_meat",),
          conds=(cond_metric_gte("cell.dominant_profession_share_q16", _pct(60)),),
          cmds=(mod(city_stat_key("good.game_meat.output_factor"), cell(20)),))],
]

CARD_META["guild_charters"] = Meta(route="workshop")
LEVEL_ROWS["guild_charters"] = [
    [prog("guild_charters_l1", "工业支柱、且单一职业占比 ≥60% 的地块：工业产出 +10%",
          tags=("cell.sector.manufacturing",),
          conds=(cond_metric_gte("cell.dominant_profession_share_q16", _pct(60)),),
          cmds=(mod(city_stat_key("building.manufacturing_output_factor"), cell(10)),))],
    [prog("guild_charters_l2", "工业支柱、且单一职业占比 ≥60% 的地块：工业产出 +14%",
          tags=("cell.sector.manufacturing",),
          conds=(cond_metric_gte("cell.dominant_profession_share_q16", _pct(60)),),
          cmds=(mod(city_stat_key("building.manufacturing_output_factor"), cell(14)),))],
    [prog("guild_charters_l3", "工业支柱、且单一职业占比 ≥60% 的地块：工业产出 +18%",
          tags=("cell.sector.manufacturing",),
          conds=(cond_metric_gte("cell.dominant_profession_share_q16", _pct(60)),),
          cmds=(mod(city_stat_key("building.manufacturing_output_factor"), cell(18)),))],
]

CARD_META["household_weaving"] = Meta(route="workshop")
LEVEL_ROWS["household_weaving"] = [
    [prog("household_weaving_l1", "主产韧皮纤维、且职业 ≥2 种的地块：布产出 +12%",
          tags=("cell.produces.bast_fiber",),
          conds=(cond_metric_gte("cell.profession_count", 2 * Q16),),
          cmds=(mod(city_stat_key("good.cloth.output_factor"), cell(12)),))],
    [prog("household_weaving_l2", "主产韧皮纤维、且职业 ≥2 种的地块：布产出 +15%",
          tags=("cell.produces.bast_fiber",),
          conds=(cond_metric_gte("cell.profession_count", 2 * Q16),),
          cmds=(mod(city_stat_key("good.cloth.output_factor"), cell(15)),))],
    [prog("household_weaving_l3", "主产韧皮纤维、且职业 ≥2 种的地块：布产出 +18%",
          tags=("cell.produces.bast_fiber",),
          conds=(cond_metric_gte("cell.profession_count", 2 * Q16),),
          cmds=(mod(city_stat_key("good.cloth.output_factor"), cell(18)),))],
]

CARD_META["village_compact"] = Meta(route="clan")
LEVEL_ROWS["village_compact"] = [
    [prog("village_compact_l1", "农业支柱、且相邻人口 ≥800 的地块：农业产出 +8%",
          tags=("cell.sector.agriculture",),
          conds=(cond_metric_gte("cell.neighbor_population_q16", 800 * Q16),),
          cmds=(mod(city_stat_key("building.agriculture_output_factor"), cell(8)),))],
    [prog("village_compact_l2", "农业支柱、且相邻人口 ≥800 的地块：农业产出 +11%",
          tags=("cell.sector.agriculture",),
          conds=(cond_metric_gte("cell.neighbor_population_q16", 800 * Q16),),
          cmds=(mod(city_stat_key("building.agriculture_output_factor"), cell(11)),))],
    [prog("village_compact_l3", "农业支柱、且相邻人口 ≥800 的地块：农业产出 +14%",
          tags=("cell.sector.agriculture",),
          conds=(cond_metric_gte("cell.neighbor_population_q16", 800 * Q16),),
          cmds=(mod(city_stat_key("building.agriculture_output_factor"), cell(14)),))],
]

# ── X7: cards gated on how much of the country looks a certain way ──────────
# The count is a country scalar published on every cell, so the gate is a normal
# metric condition. The design's "每有 1 个 X，+1%" is a linear ramp, which the
# effect layer does not have (conditions are gates, not multipliers); these cards
# therefore step it by level and say so on the face.

# ── 线性幅度：每有 1 个单位就多一点 ────────────────────────────────────────
# `Ramp` emits READ_METRIC / MIN / MUL_Q16, so the magnitude really is
# `per * min(metric, cap)` -- no more ">= 4 cells then a flat +10%" stepping.
# Level progression moves `per`, not the gate.

CARD_META["salt_monopoly"] = Meta(route="mining")
LEVEL_ROWS["salt_monopoly"] = [
    [prog("salt_monopoly_l1", "每个矿业支柱地块使矿业支柱地块产出 +1%（上限 +15%）",
          tags=("cell.sector.extractive",),
          ramp=Ramp("country.extractive_cell_count", per=0.01, cap=15),
          cmds=(mod(city_stat_key("building.extractive_output_factor"), cell(1)),))],
    [prog("salt_monopoly_l2", "每个矿业支柱地块使矿业支柱地块产出 +1.5%（上限 +15%）",
          tags=("cell.sector.extractive",),
          ramp=Ramp("country.extractive_cell_count", per=0.015, cap=10),
          cmds=(mod(city_stat_key("building.extractive_output_factor"), cell(1.5)),))],
    [prog("salt_monopoly_l3", "每个矿业支柱地块使矿业支柱地块产出 +2%（上限 +15%）",
          tags=("cell.sector.extractive",),
          ramp=Ramp("country.extractive_cell_count", per=0.02, cap=7.5),
          cmds=(mod(city_stat_key("building.extractive_output_factor"), cell(2)),))],
]

CARD_META["semiconductor"] = Meta(route="learning")
LEVEL_ROWS["semiconductor"] = [
    [prog("semiconductor_l1", "每个成链地块使成链地块的半导体产出 +2%（上限 +40%）",
          tags=("cell.chained",),
          ramp=Ramp("country.chained_cell_count", per=0.02, cap=20),
          cmds=(mod(city_stat_key("good.semiconductors.output_factor"), cell(2)),))],
    [prog("semiconductor_l2", "每个成链地块使成链地块的半导体产出 +2.5%（上限 +40%）",
          tags=("cell.chained",),
          ramp=Ramp("country.chained_cell_count", per=0.025, cap=16),
          cmds=(mod(city_stat_key("good.semiconductors.output_factor"), cell(2.5)),))],
    [prog("semiconductor_l3", "每个成链地块使成链地块的半导体产出 +3%（上限 +40%）",
          tags=("cell.chained",),
          ramp=Ramp("country.chained_cell_count", per=0.03, cap=13.3334),
          cmds=(mod(city_stat_key("good.semiconductors.output_factor"), cell(3)),))],
]

CARD_META["silver_flow"] = Meta(route="market")
LEVEL_ROWS["silver_flow"] = [
    [prog("silver_flow_l1", "每个主产白银地块使白银地块全部产出 +3%（上限 +15%）",
          tags=("cell.produces.silver",),
          ramp=Ramp("country.silver_cell_count", per=0.03, cap=5),
          cmds=(mod(city_stat_key("output_factor"), cell(3)),))],
    [prog("silver_flow_l2", "每个主产白银地块使白银地块全部产出 +3%（上限 +21%）",
          tags=("cell.produces.silver",),
          ramp=Ramp("country.silver_cell_count", per=0.03, cap=7),
          cmds=(mod(city_stat_key("output_factor"), cell(3)),))],
    [prog("silver_flow_l3", "每个主产白银地块使白银地块全部产出 +3%（上限 +27%）",
          tags=("cell.produces.silver",),
          ramp=Ramp("country.silver_cell_count", per=0.03, cap=9),
          cmds=(mod(city_stat_key("output_factor"), cell(3)),))],
]

CARD_META["chartered_route"] = Meta(route="thoroughfare")
LEVEL_ROWS["chartered_route"] = [
    [prog("chartered_route_l1", "每种专精物资使繁市地块全部产出 +1%（上限 +15%）",
          tags=("cell.market",),
          ramp=Ramp("country.distinct_specialized_good_count", per=0.01, cap=15),
          cmds=(mod(city_stat_key("output_factor"), cell(1)),))],
    [prog("chartered_route_l2", "每种专精物资使繁市地块全部产出 +1.5%（上限 +15%）",
          tags=("cell.market",),
          ramp=Ramp("country.distinct_specialized_good_count", per=0.015, cap=10),
          cmds=(mod(city_stat_key("output_factor"), cell(1.5)),))],
    [prog("chartered_route_l3", "每种专精物资使繁市地块全部产出 +2%（上限 +15%）",
          tags=("cell.market",),
          ramp=Ramp("country.distinct_specialized_good_count", per=0.02, cap=7.5),
          cmds=(mod(city_stat_key("output_factor"), cell(2)),))],
]

CARD_META["land_reclamation"] = Meta(route="cropland")
LEVEL_ROWS["land_reclamation"] = [
    [prog("land_reclamation_l1", "边地农业、且相邻人口 ≤400 的地块：农业产出 +10%",
          tags=("cell.frontier", "cell.sector.agriculture"),
          conds=(cond_metric_lte("cell.neighbor_population_q16", 400 * Q16),),
          cmds=(mod(city_stat_key("building.agriculture_output_factor"), cell(10)),))],
    [prog("land_reclamation_l2", "边地农业、且相邻人口 ≤400 的地块：农业产出 +13%",
          tags=("cell.frontier", "cell.sector.agriculture"),
          conds=(cond_metric_lte("cell.neighbor_population_q16", 400 * Q16),),
          cmds=(mod(city_stat_key("building.agriculture_output_factor"), cell(13)),))],
    [prog("land_reclamation_l3", "边地农业、且相邻人口 ≤400 的地块：农业产出 +16%",
          tags=("cell.frontier", "cell.sector.agriculture"),
          conds=(cond_metric_lte("cell.neighbor_population_q16", 400 * Q16),),
          cmds=(mod(city_stat_key("building.agriculture_output_factor"), cell(16)),))],
]


# ── tag-name validation ──────────────────────────────────────────────────────
# Content references tags by name; the numeric id is resolved at compile time by
# EffectDomainCatalog. These checks exist so a typo fails here (one line, with
# the offending card) instead of failing the whole effect catalog later.
_TAG_ATOMS = {
    "cell.frontier", "cell.settlement", "cell.metropolis", "cell.market",
    "cell.specialized", "cell.specialized_high", "cell.grain",
    "cell.diversified", "cell.chained", "cell.unemployed", "cell.shortage",
    "cell.abundant", "cell.depleted", "cell.rain",
    "cell.river", "cell.coastal", "cell.canal", "cell.border",
    "cell.clan", "cell.eminent_clan",
    "cell.climate.cold", "cell.climate.hot", "cell.climate.dry_spell",
}
_SECTORS = ("agriculture", "extractive", "manufacturing", "energy", "knowledge")


def known_tag_names() -> set[str]:
    names = set(_TAG_ATOMS)
    for good in _read_res_dir_ids(GOODS_DIR):
        names.add(f"cell.produces.{good}")
    for sector in _SECTORS:
        names.add(f"cell.sector.{sector}")
    for resource in _read_resource_ids():
        names.add(f"cell.rich.{resource}")
    for landform in _read_enum_ids(LANDFORM_PATH, "LF"):
        names.add(f"cell.landform.{landform}")
    for terrain in _read_enum_ids(TERRAIN_PATH, "TERRAIN"):
        names.add(f"cell.terrain.{terrain}")
    return names


def canonical_tag_expression(tag: str) -> str:
    """Canonical `a|b` spelling, or the original single tag name."""
    members = [part.strip() for part in tag.split("|") if part.strip()]
    unique = sorted(set(members))
    return "|".join(unique) if len(unique) > 1 else (unique[0] if unique else "")


def is_synthetic_tag(tag: str) -> bool:
    return "|" in tag


def validate_tag_expression(tag: str, tag_names: set[str],
                            context: str) -> None:
    if not is_synthetic_tag(tag):
        if tag not in tag_names:
            raise SystemExit(f"{context} unknown tag {tag}")
        return
    members = [part.strip() for part in tag.split("|") if part.strip()]
    if len(members) < 2:
        raise SystemExit(f"{context} malformed tag union {tag}")
    if canonical_tag_expression(tag) != tag:
        raise SystemExit(
            f"{context} non-canonical tag union {tag!r}; "
            f"use {canonical_tag_expression(tag)!r}")
    for member in members:
        if member not in tag_names:
            raise SystemExit(f"{context} unknown tag union member {member}")


# ── .tres emitters for programs ──────────────────────────────────────────────
def _selector_param_line(item: Prog) -> str:
    """The `target_selector_param = ...` line for one program.

    Kind 16 bit-packs its three GEOMETRY parameters into `param[0]`; `param[1]` is
    the source tag id and is left 0 here on purpose.

    Why the generator cannot write the tag id: tag ids are array indices into a
    table that `TargetTagDictionary.build()` creates at COMPILE time from the live
    economy catalog (`_apply_selector_tags` -> `_write_selector_tag_id` sets
    `param[1]`). A number baked into the `.tres` would be wrong the moment a tag is
    appended above it -- silently retargeting the card. Kind 12/13/14/15 work the
    same way, so `param[1] = 0` here is the established contract, not a gap.

    Every other kind writes (cap, param1) literally as it always has.
    """
    if item.selector == SEL_TAG_SOURCE_COUNT:
        packed, _tag_slot = pack_source_count(
            item.selector_cap if item.selector_cap != 32 else 0,
            item.radius, item.cap, tag_id=1)
        return f"target_selector_param = PackedInt32Array({packed}, 0)\n"
    return (f"target_selector_param = PackedInt32Array("
            f"{item.selector_cap}, {item.selector_param1})\n")


def _program_blocks(item: Prog, blocks: list[str]) -> str:
    base = "Prog" + camel(item.key)
    cond_refs: list[str] = []
    for index, condition in enumerate(item.conds):
        cond_id = f"{base}Cond{index}"
        block = (f'[sub_resource type="Resource" id="{cond_id}"]\n'
                 'script = ExtResource("3_condition")\n'
                 f"op = {condition.op}\n")
        if condition.op in (COND_METRIC_GTE, COND_METRIC_LTE, COND_METRIC_EQ,
                            COND_STATE_GTE, COND_NOT):
            block += f"arg0 = {condition.arg0}\n"
        if condition.op in (COND_METRIC_GTE, COND_METRIC_LTE, COND_METRIC_EQ,
                            COND_STATE_GTE):
            block += f"value_q16 = {condition.value_q16}\n"
        blocks.append(block)
        cond_refs.append(cond_id)
    # Conditions are an RPN stack: two rows in a row leave only the last one on
    # the stack, so N rows need N-1 explicit ANDs. Doing it here once is why no
    # card can forget it.
    if len(cond_refs) > 1:
        for index in range(len(cond_refs) - 1):
            and_id = f"{base}CondAnd{index}"
            blocks.append(f'[sub_resource type="Resource" id="{and_id}"]\n'
                          'script = ExtResource("3_condition")\n'
                          f"op = {COND_AND}\n")
            cond_refs.append(and_id)
    instr_refs: list[str] = []
    commands: list[list] = []
    for index, command in enumerate(item.cmds):
        if command.magnitude_q16 is None:
            if item.selector == SEL_TAG_SOURCE_COUNT:
                # X1-b: the program's value is the FULL stack (every cap worth of
                # sources). The runtime scales each instance down by
                # `min(count, cap) / cap` through `magnitude_scale_q16`, so a cell
                # that sees `count` sources gets `per_source × count`.
                #
                # This is why `per_source` and not `value` is the authoring field:
                # the same program drives every target cell, and only the scale
                # differs per cell.
                stack = float(item.per_source) * float(item.cap)
                magnitude_q16 = max(1, min(4 * Q16, int(round(abs(stack) * Q16))))
            else:
                magnitude_q16 = max(1, min(4 * Q16, int(round(abs(command.value) * Q16))))
        else:
            magnitude_q16 = command.magnitude_q16
        if item.ramp is not None:
            # value = per * min(metric, cap). One command only: a ramp per command
            # would need its own value stack discipline, and no card wants two
            # differently-shaped ramps on one program yet.
            ramp = item.ramp
            metric_slot = metric_id(ramp.metric)
            per_q16 = max(1, int(round(ramp.per * Q16)))
            cap_q16 = max(1, int(round(ramp.cap * Q16)))
            steps = [
                ("1", f"value_q16 = {per_q16}\n"),          # CONST per
                ("2", f"arg0 = {metric_slot}\n"),              # READ_METRIC
                ("1", f"value_q16 = {cap_q16}\n"),          # CONST cap
                ("8", ""),                                    # MIN
                ("6", ""),                                    # MUL_Q16
            ]
            for step_index, (op, body) in enumerate(steps):
                step_id = f"{base}Ramp{step_index}"
                blocks.append(f'[sub_resource type="Resource" id="{step_id}"]\n'
                              'script = ExtResource("4_instruction")\n'
                              f"op = {op}\n" + body)
                instr_refs.append(step_id)
            emit_id = f"{base}Emit{index}"
            blocks.append(f'[sub_resource type="Resource" id="{emit_id}"]\n'
                          'script = ExtResource("4_instruction")\n'
                          f"op = 11\narg0 = {index}\n")
            instr_refs.append(emit_id)
        else:
            const_id = f"{base}Const{index}"
            emit_id = f"{base}Emit{index}"
            blocks.append(f'[sub_resource type="Resource" id="{const_id}"]\n'
                          'script = ExtResource("4_instruction")\n'
                          f"op = 1\nvalue_q16 = {magnitude_q16}\n")
            blocks.append(f'[sub_resource type="Resource" id="{emit_id}"]\n'
                          'script = ExtResource("4_instruction")\n'
                          f"op = 11\narg0 = {index}\n")
            instr_refs.extend([const_id, emit_id])
        modifier_key = command.modifier
        if command.value < 0.0 and not modifier_key.endswith(".cut"):
            modifier_key = modifier_key + ".cut"
        cmd_id = f"{base}Cmd{index}"
        command_domain = item.target_domain if command.domain is None else command.domain
        blocks.append(f'[sub_resource type="Resource" id="{cmd_id}"]\n'
                      'script = ExtResource("5_command")\n'
                      f"action = 1\ndomain = {command_domain}\nopcode = 1\n"
                      "target_resolver = 1\nvalue_mode = 1\n"
                      f"value_q16 = {magnitude_q16}\n"
                      f"duration_days = {command.duration_days}\n"
                      f"stacks = {command.stacks}\n"
                      'command_key = &"ideology.persistent"\n'
                      f'definition_key = &"{modifier_key}"\n')
        commands.append([cmd_id])
    tags = [tag for tag in item.tags if tag]
    tag_lines = ""
    if len(tags) == 1:
        tag_lines = f'target_selector_tag = &"{tags[0]}"\n'
    elif len(tags) > 1:
        tag_lines = "target_selector_tags = PackedStringArray(%s)\n" % ", ".join(
            f'"{tag}"' for tag in tags)
    blocks.append(
        f'[sub_resource type="Resource" id="{base}"]\n'
        'script = ExtResource("2_effect")\n'
        f'definition_key = &"{item.key}"\n'
        f'summary = "{item.summary.replace(chr(34), chr(92) + chr(34))}"\n'
        f"target_domain = {item.target_domain}\n"
        "operation = 1\n"
        f"lifecycle = {item.lifecycle}\n"
        f"duration_days = {item.duration_days}\n"
        f"stack_policy = {item.stack_policy}\n"
        f'stack_key = &"{item.key}"\n'
        f"max_stacks = {item.max_stacks}\n"
        f"priority = {item.priority}\n"
        f"target_selector_kind = {item.selector}\n"
        'target_selector_id = &""\n'
        + _selector_param_line(item) +
        f"cadence_days = 1\n"
        + tag_lines +
        "conditions = Array[Resource]([%s])\n" % ", ".join(
            f'SubResource("{ref}")' for ref in cond_refs) +
        "instructions = Array[Resource]([%s])\n" % ", ".join(
            f'SubResource("{ref}")' for ref in instr_refs) +
        "commands = Array[Resource]([%s])\n" % ", ".join(
            f'SubResource("{row[0]}")' for row in commands))
    return base


def build_effect_catalog() -> str:
    """Generate `default_ideology_effects.tres` (diagnostics + card programs)."""
    blocks: list[str] = []
    program_ids: list[str] = []
    for item in DIAGNOSTIC_PROGRAMS + all_card_programs():
        program_ids.append(_program_blocks(item, blocks))
    ext = [
        '[ext_resource type="Script" path="res://scripts/ideology/ideology_effect_catalog.gd" id="1_catalog"]',
        '[ext_resource type="Script" path="res://scripts/ideology/ideology_effect_definition.gd" id="2_effect"]',
        '[ext_resource type="Script" path="res://scripts/effect/effect_condition.gd" id="3_condition"]',
        '[ext_resource type="Script" path="res://scripts/effect/effect_instruction.gd" id="4_instruction"]',
        '[ext_resource type="Script" path="res://scripts/effect/effect_command.gd" id="5_command"]',
    ]
    load_steps = len(ext) + len(blocks) + 1
    resource = ("[resource]\n"
                'script = ExtResource("1_catalog")\n'
                "effects = Array[Resource]([%s])\n" % ", ".join(
                    f'SubResource("{item}")' for item in program_ids))
    header = (f'[gd_resource type="Resource" script_class="IdeologyEffectCatalog" '
              f'load_steps={load_steps} format=3]\n')
    return header + "\n" + "\n".join(ext) + "\n\n" + "\n".join(blocks) + "\n" + resource


# ── live catalog readers used by the lint ────────────────────────────────────
def _read_enum_ids(path: pathlib.Path, header: str) -> set[str]:
    """Lower-cased member names of the first `enum <header> {` block."""
    ids: set[str] = set()
    inside = False
    for line in path.read_text(encoding="utf-8").splitlines():
        if not inside:
            if line.strip().startswith(f"enum {header} {{"):
                inside = True
            continue
        if line.strip().startswith("}"):
            break
        match = re.match(r"\s+([A-Z_][A-Z0-9_]*)\s*,", line)
        if match:
            ids.add(match.group(1).lower())
    return ids


def _read_res_dir_ids(path: pathlib.Path) -> set[str]:
    return {p.stem for p in path.glob("*.tres")}


def _read_signal_ids() -> set[str]:
    text = SIGNAL_CATALOG_PATH.read_text(encoding="utf-8")
    return set(re.findall(r'\[\s*"([a-z][a-z_]*\.[a-z0-9_.]+)"\s*,', text))


def _read_resource_ids() -> set[str]:
    """Union of every building's natural-resource slot ids."""
    ids: set[str] = set()
    for path in BUILDINGS_DIR.glob("*.tres"):
        text = path.read_text(encoding="utf-8")
        for line in text.splitlines():
            if line.startswith("resource_ids = PackedStringArray("):
                body = line.split("(", 1)[1].rsplit(")", 1)[0]
                for item in body.split(","):
                    item = item.strip().strip('"')
                    if item:
                        ids.add(item)
    return ids


## X8 reads only the primary feedstock slot of a building recipe. The authored
## chain roots live in the generator because a good can be produced by many later
## recipes; choosing the first `.tres` alphabetically would turn a copper chain
## into the whole industrial tree. Goods and their producer recipes stay `.tres`.
X8_CHAIN_SEEDS = {
    "copper_ore": ("early_copper_mine",),
    "tin_ore": ("early_tin_mine",),
    "copper": ("early_copper_smelter",),
    "tin": ("early_tin_smelter",),
    "bronze_tools": ("bronze_tool_workshop",),
}
_BUILDING_RECIPES_CACHE: dict[str, dict[str, list[str]]] | None = None


def _parse_packed_strings(raw: str, keep_empty: bool = False) -> list[str]:
    marker = "PackedStringArray("
    start = raw.find(marker)
    if start < 0:
        return []
    tail = raw[start + len(marker):]
    body = tail[:tail.rfind(")")] if ")" in tail else ""
    if not body:
        return []
    items = [item.strip() for item in body.split(",")]
    if keep_empty:
        return [item.strip('"') for item in items]
    return [item.strip('"') for item in items if item.strip('"')]


def _building_tres_fields(building_id: str) -> dict[str, str]:
    path = BUILDINGS_DIR / f"{building_id}.tres"
    fields: dict[str, str] = {}
    if not path.exists():
        raise SystemExit(f"x8: missing building recipe {path.name}")
    for line in path.read_text(encoding="utf-8").splitlines():
        if " = " in line:
            key, value = line.split(" = ", 1)
            fields[key] = value
    return fields


def _read_building_recipes() -> dict[str, dict[str, list[str]]]:
    """Single-output recipes with an empty-category primary feedstock."""
    global _BUILDING_RECIPES_CACHE
    if _BUILDING_RECIPES_CACHE is not None:
        return _BUILDING_RECIPES_CACHE
    recipes: dict[str, dict[str, list[str]]] = {}
    for path in sorted(BUILDINGS_DIR.glob("*.tres")):
        fields: dict[str, str] = {}
        for line in path.read_text(encoding="utf-8").splitlines():
            if " = " in line:
                key, value = line.split(" = ", 1)
                fields[key] = value
        inputs = _parse_packed_strings(fields.get("input_good_ids", ""))
        categories = _parse_packed_strings(
            fields.get("input_category_ids", ""), keep_empty=True)
        resources = _parse_packed_strings(fields.get("resource_ids", ""))
        feedstocks = [
            good for index, good in enumerate(inputs)
            if (index >= len(categories) or not categories[index].strip())
            and good not in resources
        ]
        outputs = _parse_packed_strings(fields.get("output_good_ids", ""))
        if len(outputs) == 1 and (feedstocks or resources):
            recipes[path.stem] = {
                "inputs": feedstocks,
                "outputs": outputs,
                "access": resources,
            }
    _BUILDING_RECIPES_CACHE = recipes
    return recipes


def x8_upstream_goods(good: str, _seen: frozenset[str] = frozenset()) -> tuple[str, ...]:
    """Terminal upstream goods for one authored chain.

    Intermediate goods disappear when their own producer is in the chain. A
    workshop consuming bronze tools must stay attached to the mines, not to the
    smelters: removing a mine while leaving its smelter behind has to remove the
    workshop's upstream bonus.
    """
    recipes = _read_building_recipes()
    if good in _seen:
        raise SystemExit(f"x8: cycle in upstream chain at {good}")
    if len(_seen) >= 8:
        raise SystemExit(f"x8: upstream chain exceeds depth 8 at {good}")
    producer_ids = X8_CHAIN_SEEDS.get(good)
    if producer_ids is None:
        producers = [
            recipe for recipe in recipes.values()
            if recipe["inputs"] == [] and good in recipe["access"]
        ]
        if not producers:
            return ()
        return (good,)
    upstream: set[str] = set()
    for producer_id in producer_ids:
        recipe = recipes.get(producer_id)
        if recipe is None:
            raise SystemExit(f"x8: no single-output feedstock recipe {producer_id}")
        if not recipe["inputs"]:
            upstream.add(good)
            continue
        for feedstock in recipe["inputs"]:
            upstream.update(x8_upstream_goods(
                feedstock, _seen | frozenset({good})))
    return tuple(sorted(upstream))


def x8_upstream_tag(good: str) -> str:
    members = [f"cell.produces.{item}" for item in x8_upstream_goods(good)]
    if not members:
        raise SystemExit(f"x8: no upstream feedstock chain for {good}")
    return "|".join(sorted(members))


def _read_upgrade_family_ids() -> set[str]:
    ids: set[str] = set()
    for path in BUILDINGS_DIR.glob("*.tres"):
        for line in path.read_text(encoding="utf-8").splitlines():
            if line.startswith("upgrade_family_id"):
                value = line.split("=", 1)[1].strip().strip('"').lstrip("&").strip('"')
                if value:
                    ids.add(value)
    return ids


# ── term direction helpers ───────────────────────────────────────────────────
# Most stat keys are "bigger is better". The families below measure a drain on the
# player (resources burned, losses taken, cost paid, goods withdrawn by households),
# so a value above 1.0 is the downside there and below 1.0 is the downside elsewhere.
# Tax rates are genuinely two-sided -- a burden on the taxed side and revenue for
# the treasury -- so they are excluded from both directions and can never satisfy
# the cost lint on their own.
_COST_DIRECTION_KEYS = (
    ".use_factor",                            # natural resource extraction intensity
    "_loss_factor",                           # climate hazard loss
    "country.population.death_factor",        # mortality
    "country.production.input_factor",        # production input drawn
    "country.input.good.",                    # per-good input quantity required
    "country.construction.cost_factor",       # build cost paid
    "country.research.cost_factor",           # research cost paid
    "country.household.consumption_factor",   # goods withdrawn by households
    # Per-cell need demand (`economy.city.need.<need>.consumption_factor`): a
    # HIGHER factor means the cell's households must buy more of that need, so it
    # is a price on the same axis as the country-wide one above. Without this row
    # a card whose only cost is "these cells need +5% housing" looked free
    # (`land_value`), and the lint's message sent the reader to the wrong file.
    "economy.city.need.",
)
# V1 (design doc §47.2): a card may NOT write a value the player can set directly.
#
# Tax rates used to be "neutral" here -- neither a benefit nor a price -- and were
# allowed through. That was wrong for a different reason than direction: the whole
# tax bill is `effective = clamp(modifier(base), MIN, MAX)` where `base` is the
# player's own setting (`country_runtime.cpp` ~5140 and ~5355). So "this
# profession's income tax x0.9" is worth exactly one free tax-policy click, which
# the player already has. The card costs a slot and buys nothing.
#
# The real consequence of a tax lives in Economy's satisfaction mix, where the tax
# dimension is `1 - net_burden / tolerance`. Content therefore changes how people
# REACT to a given rate (X16), never the rate itself.
#
# Any term naming one of these prefixes fails generation outright.
_PLAYER_LEVER_PREFIXES = (
    "country.tax.",              # every tax rate the player/AI can set
    "country.subsidy.",          # subsidy rates are policy too
    "economy.city.tax.",         # per-cell tax overrides, same lever
)


def _player_lever_reason(stat: str) -> str:
    """V1 (design doc §47.2): why this stat is a player lever, or "" when it is not."""
    for prefix in _PLAYER_LEVER_PREFIXES:
        if stat.startswith(prefix):
            return (f"{stat} is a policy value the player sets directly "
                    f"({prefix}*); a card that moves it is worth one free policy "
                    "click. Change how people react to the rate (X16) instead "
                    "-- design doc §47.2 V1")
    return ""


def _is_cost_stat(stat: str) -> bool:
    return any(stat == key or key in stat for key in _COST_DIRECTION_KEYS)


def _is_downside(stat: str, value: float) -> bool:
    """True when this term is bad for the player, i.e. it pays a price.

    Player levers are rejected before this point (`_player_lever_reason`, V1), so
    there is no "neutral" branch here any more: every remaining stat has a
    direction.
    """
    return value > 1.0 if _is_cost_stat(stat) else value < 1.0


def _satisfies_downside(entry) -> bool:
    """`_is_downside` for every term shape.

    An additive row has no "direction" to invert (`value < 1.0` would call every
    positive point a buff), so it is annotated at the authoring site: the third
    slot of the tuple says whether the rows are a price or a deliberate political
    transfer. A `RampTerm` is a price by construction: a "per band, -X%" ramp only
    ever lowers the stat it names.
    """
    if isinstance(entry, RampTerm):
        return True
    if len(entry) > 2:
        return entry[2] == OP_ADD_DOWNSIDE
    return _is_downside(entry[0], entry[1])


def _term_stat(entry) -> str:
    """The Modifier key a term names, for every term shape."""
    return entry.stat if isinstance(entry, RampTerm) else entry[0]


# ── stat prefix -> operations the Modifier catalog allows ───────────────────
#
# Mirrors `modifier_catalog.gd`'s per-family `allowed_operations` bits. The catalog
# refuses a term whose operation the stat does not permit
# (`modifier_term_domain_or_operation_invalid`), and that rejection takes the WHOLE
# Modifier catalog down -- so a mismatch here is not a per-card problem, it breaks
# world generation.
#
# Measured failure this table exists to prevent: every `*.satisfaction_bp` term came
# out as MULTIPLY (2) because the author omitted the third tuple element, while the
# stat is declared ADD-only (bit 1). 32 such terms in one catalog, and every world
# failed to generate.
#
# Bit values = `1 << Operation`: ADD 0 -> 1, SUBTRACT 1 -> 2, MULTIPLY 2 -> 4,
# DIVIDE 3 -> 8.
OP_BIT_ADD = 1
OP_BIT_SUBTRACT = 2
OP_BIT_MULTIPLY = 4
OP_BIT_DIVIDE = 8

# Suffix/scheme rules: a stat is additive when its family is a POINT OFFSET rather
# than a ratio. `*_bp` is basis points, `*_q16` in this catalog is always a count of
# something (cell counts, band counts), and the explicit `satisfaction_*` family is a
# point value the player reads as "-3 满意度".
_ADDITIVE_STAT_SUFFIXES = ("_bp", "_q16")
_ADDITIVE_STAT_SUBSTRINGS = (".satisfaction_", "satisfaction_bp")

# Prefix rules for the families this generator is allowed to author. The ALLOWED set
# is what the failure check below consults; anything not listed keeps the historical
# default (any operation), so this only tightens the families known to be narrow.
_STAT_ALLOWED_OPERATIONS = {
    "economy.profession.": OP_BIT_ADD | OP_BIT_MULTIPLY,
}
# Narrower per-key overrides, applied after the prefix rule above.
_STAT_ALLOWED_OPERATIONS_BY_SUFFIX = {
    ".satisfaction_bp": OP_BIT_ADD,
    ".tax_tolerance_factor": OP_BIT_MULTIPLY,
}


def _is_additive_stat(stat: str) -> bool:
    """True when `stat` is a POINT OFFSET (never a ratio), so it must use ADD."""
    name = str(stat)
    if name == OPINION_FLOOR:
        return True
    if any(token in name for token in _ADDITIVE_STAT_SUBSTRINGS):
        return True
    return any(name.endswith(suffix) for suffix in _ADDITIVE_STAT_SUFFIXES)


def _allowed_operations_for(stat: str) -> int:
    """The operation bitmask `modifier_catalog.gd` declares for `stat`.

    Returns 15 (every operation) for families this file does not model, so an
    unlisted stat can never start failing because of a missing entry here.
    """
    name = str(stat)
    allowed = 15
    if name == OPINION_FLOOR:
        return OP_BIT_ADD
    for prefix, mask in _STAT_ALLOWED_OPERATIONS.items():
        if name.startswith(prefix):
            allowed = mask
            break
    for suffix, mask in _STAT_ALLOWED_OPERATIONS_BY_SUFFIX.items():
        if name.endswith(suffix):
            allowed = mask
            break
    return allowed


def _term_operation(entry) -> int:
    """The Modifier operation a term tuple must be written with.

    Three inputs decide it, in this order:

    1. An ADDITIVE stat (`_is_additive_stat`) is ALWAYS ADD, whatever the tuple looks
       like. A basis-point offset has no multiplicative meaning: writing
       `satisfaction_bp = 400` as MULTIPLY asks the runtime to scale 0 by 400, which is
       still 0, so the card silently does nothing. This shipped: `petition_box` and
       `light_levy` author their positive satisfaction bonuses WITHOUT a third tuple
       element, the old default made them MULTIPLY, and the resulting catalog carried
       32 `operation = 2` satisfaction terms against an ADD-only stat declaration.
    2. An explicit third element picks ADD for the two ADD markers.
    3. Everything else multiplies.
    """
    if isinstance(entry, RampTerm):
        return OP_MULTIPLY
    if entry and _is_additive_stat(entry[0]):
        return OP_ADD_DOWNSIDE
    if len(entry) > 2 and entry[2] in (OP_ADD_DOWNSIDE, OP_ADD_TRANSFER):
        return 0  # Operation::ADD
    return OP_MULTIPLY


# Stats whose declared `max_value` is 1.0, i.e. hazard-loss and other ratios the
# runtime clamps. `ModifierRuntime::effective_value` ends in
# `std::clamp(value, min_value, max_value)`, so a term that pushes such a stat
# ABOVE 1.0 evaluates to exactly 1.0 and the card charges nothing while its face
# still prints the cost. Rust-removed from the catalog after this was measured;
# the lint exists so the next author cannot reintroduce it.
_CLAMPED_AT_ONE = (
    "country.climate.drought_loss_factor",
    "country.climate.flood_loss_factor",
    "country.climate.cold_stress_factor",
    "country.climate.heat_stress_factor",
)


def _clamped_noop_reason(entry) -> str:
    """Why this term can never move its stat, or "" when it can."""
    if isinstance(entry, RampTerm):
        return ""  # a ramp's magnitude is authored, its direction is a price
    if len(entry) > 2:
        return ""  # additive rows carry their own semantics
    stat, value = entry[0], entry[1]
    if stat in _CLAMPED_AT_ONE and value > 1.0:
        return (f"{stat}={value} raises a stat declared max_value 1.0; "
                "effective_value clamps it back to 1.0 and the term is a no-op")
    return ""


def object_kind(stat: str) -> str:
    """Which kind of object a term targets, for coverage reporting."""
    if stat in {
            "country.output.agriculture_factor", "country.output.extractive_factor",
            "country.output.manufacturing_factor", "country.output.energy_factor",
            "country.output.knowledge_factor"}:
        return "sector"
    if ".terrain." in stat or ".landform." in stat:
        return "geography"
    if ".good." in stat:
        return "good"
    if ".resource." in stat:
        return "resource"
    if ".climate." in stat:
        return "climate"
    if ".tax." in stat:
        return "tax"
    if ".building." in stat or ".family." in stat:
        return "building"
    return "national"


def _read_scalar_stat_keys() -> set[str]:
    """The country-level scalar stat keys declared in ModifierCatalog.

    Line-scanned rather than bracket-split because every row ends in `],`, so the
    first `]` in the block belongs to the first row, not to the array.
    """
    keys: set[str] = set()
    inside = False
    for line in MODIFIER_CATALOG_PATH.read_text(encoding="utf-8").splitlines():
        if not inside:
            if "const TECHNOLOGY_STATS := [" in line:
                inside = True
            continue
        if line.strip() == "]":
            break
        match = re.search(r'\["([a-z][a-z_.0-9]+)"\s*,', line)
        if match:
            keys.add(match.group(1))
    return keys


def allowed_stat_keys() -> set[str]:
    """Every stat key the modifier catalog can address, synthesised from data."""
    allowed = _read_scalar_stat_keys()
    allowed |= {f"country.output.family.{fam}_factor"
                for fam in _read_upgrade_family_ids()}
    for good in _read_res_dir_ids(GOODS_DIR):
        allowed |= {f"country.output.good.{good}_factor",
                    f"country.input.good.{good}_factor",
                    f"country.consumption.good.{good}_factor"}
    for resource in _read_resource_ids():
        allowed |= {f"country.resource.{resource}.use_factor",
                    f"country.resource.{resource}.managed_generation_factor"}
    sectors = ["agriculture", "extractive", "manufacturing", "energy", "knowledge"]
    for terrain in _read_enum_ids(TERRAIN_PATH, "TERRAIN"):
        allowed |= {f"country.output.terrain.{terrain}.{sector}_factor"
                    for sector in sectors}
    for landform in _read_enum_ids(LANDFORM_PATH, "LF"):
        allowed |= {f"country.output.landform.{landform}.{sector}_factor"
                    for sector in sectors}
    allowed |= {f"country.output.building.{item}_factor"
                for item in _read_res_dir_ids(BUILDINGS_DIR)}
    for kind, ids in (
            ("income", _read_res_dir_ids(PROFESSIONS_DIR)),
            ("consumption", _read_res_dir_ids(GOODS_DIR)),
            ("business", _read_res_dir_ids(BUILDINGS_DIR)),
            ("import", _read_res_dir_ids(GOODS_DIR)),
            ("export", _read_res_dir_ids(GOODS_DIR))):
        allowed |= {f"country.tax.{kind}.{item}.rate_bp" for item in ids}
    # R-4 X16: per-profession tax tolerance (MULTIPLY, clamped 0.5..3.0) and
    # satisfaction bias (ADD, clamped -2500..2500 bp). Mirrors the loop that
    # `modifier_catalog.gd` now emits right after its `tax_stat_groups`.
    for profession in _read_res_dir_ids(PROFESSIONS_DIR):
        allowed |= {
            f"economy.profession.{profession}.tax_tolerance_factor",
            f"economy.profession.{profession}.satisfaction_bp",
        }
    for profile in _read_res_dir_ids(PRODUCTION_CLIMATES_DIR):
        allowed |= {f"country.climate.profile.{profile}.{hazard}_loss_factor"
                    for hazard in CLIMATE_HAZARDS}
    return allowed


def _terms_of(entry) -> list:
    """Card tuples end with their term list; synergy/resonance tuples use index 3."""
    return entry[-1]


def _all_terms(card_key: str) -> list:
    """Every national term a card emits, from whichever table authored it.

    `CARDS` keeps the L1 row (the presenter and the two lints read it), while a
    card that needs different numbers per level moves them into `LEVEL_TERMS`.
    Both are "the card's terms" for validation, so both are returned here.
    """
    levels = LEVEL_TERMS.get(card_key)
    if levels is None:
        entry = next(card for card in CARDS if card[0] == card_key)
        return list(_terms_of(entry))
    out: list = []
    for rows in levels:
        out.extend(rows)
    return out


def allowed_city_stat_keys() -> set[str]:
    """Every `economy.city.*` stat the cell-level ideology family may address.

    Mirrors `modifier_catalog.gd`'s generated city families plus the three
    literals. Kept separate from `allowed_stat_keys()` because those are the
    country-scope keys; a cell definition that names a country key would be
    rejected by the native domain check at apply time instead of here.
    """
    allowed = {
        "economy.city.output_factor",
        "economy.city.birth_factor",
        "economy.city.consumption_factor",
        "economy.city.resource.regen_factor",
    }
    for sector in ("agriculture", "extractive", "manufacturing", "energy", "knowledge"):
        allowed.add(f"economy.city.building.{sector}_output_factor")
    for need in _read_res_dir_ids(NEEDS_DIR):
        allowed.add(f"economy.city.need.{need}.consumption_factor")
    for good in _read_res_dir_ids(GOODS_DIR):
        allowed.add(f"economy.city.good.{good}.output_factor")
        allowed.add(f"economy.city.good.{good}.consumption_factor")
    for resource in _read_resource_ids():
        allowed.add(f"economy.city.resource.{resource}.regen_factor")
    return allowed


def validate_city_family() -> None:
    allowed = allowed_city_stat_keys()
    seen: set[str] = set()
    emitted_keys: set[str] = set()
    for suffix, stat in IDEOLOGY_CITY_STATS:
        if suffix in seen:
            raise SystemExit(f"ideology.city: duplicate suffix {suffix}")
        seen.add(suffix)
        if stat not in allowed:
            raise SystemExit(f"ideology.city: unknown cell stat {stat}")
        if stat in DEAD_STAT_KEYS:
            raise SystemExit(f"ideology.city: dead cell stat {stat}")
        # Two definitions with one key fail the WHOLE Modifier catalog
        # (`modifier_definition_invalid_or_duplicate`), so the de-duplication
        # against modifier_catalog.gd's own generated rows is asserted here rather
        # than trusted: a duplicate in the emitted list is the failure mode that
        # already happened once.
        for key in (city_stat_key(suffix), city_stat_key(suffix, cut=True)):
            if key in emitted_keys:
                raise SystemExit(f"ideology.city: duplicate definition key {key}")
            emitted_keys.add(key)


def validate_country_family() -> None:
    """Every backing stat exists and every generated key is unique."""
    allowed = _read_scalar_stat_keys()
    suffix_seen: set[str] = set()
    key_seen: set[str] = set()
    for suffix, stat, direction in IDEOLOGY_COUNTRY_STATS:
        if suffix in suffix_seen:
            raise SystemExit(f"ideology.country: duplicate suffix {suffix}")
        suffix_seen.add(suffix)
        if stat not in allowed:
            raise SystemExit(f"ideology.country: unknown country stat {stat}")
        if stat in DEAD_STAT_KEYS:
            raise SystemExit(f"ideology.country: dead country stat {stat}")
        if direction not in ("cut", "gain"):
            raise SystemExit(
                f"ideology.country: {suffix} has unknown direction {direction}")
        cut = direction == "cut"
        gain = direction == "gain"
        key = country_stat_key(suffix, cut=cut, gain=gain)
        if key in key_seen:
            raise SystemExit(
                f"ideology.country: duplicate definition key {key}")
        key_seen.add(key)


def build_ideology_catalog() -> str:
    blocks: list[str] = []
    profile_lines = ['[sub_resource type="Resource" id="Profile"]',
                     'script = ExtResource("2_profile")']
    for key, value in PROFILE_COLUMNS.items():
        profile_lines.append(f"{key} = {value}")
    profile_lines.append("capacity_unlock_technology_keys = PackedStringArray(%s)" %
                         ", ".join(f'"{tech}"' for tech, _, _ in CAPACITY_UNLOCKS))
    profile_lines.append("capacity_unlock_ideology_deltas = PackedInt32Array(%s)" %
                         ", ".join(str(delta) for _, delta, _ in CAPACITY_UNLOCKS))
    profile_lines.append("capacity_unlock_spirit_deltas = PackedInt32Array(%s)" %
                         ", ".join(str(delta) for _, _, delta in CAPACITY_UNLOCKS))
    profile_lines.append('point_gain_stat_key = &"country.ideology.point_gain_factor"')
    profile_lines.append(
        'point_population_factor_stat_key = &"country.ideology.point_population_factor"')
    profile_lines.append(
        'point_building_factor_stat_key = &"country.ideology.point_building_factor"')
    profile_lines.append(
        'point_trade_factor_stat_key = &"country.ideology.point_trade_factor"')
    profile_lines.append(
        'opinion_factor_floor_stat_key = &"country.ideology.opinion_factor_floor"')
    profile_lines.append(
        "school_strength_factor_stat_keys = PackedStringArray(%s)" %
        ", ".join(f'"country.ideology.school_strength_factor.{school}"'
                  for school in SCHOOL_ORDER))
    # Written explicitly rather than left to the script defaults: the .tres is a
    # generated artefact, and a field that only exists as a GDScript default is
    # invisible to anyone reading the data file to find out what a save depends on.
    profile_lines.append(
        'understanding_gain_stat_key = &"country.ideology.understanding_gain_factor"')
    profile_lines.append(
        'reroll_cost_stat_key = &"country.ideology.reroll_cost_factor"')
    blocks.append("\n".join(profile_lines) + "\n")
    definition_ids: list[str] = []
    for key, name, school, rarity, era, exclusion, tech, signals, detail, _terms in cards_to_emit():
        base = camel(key)
        level_ids = []
        rows_by_level = LEVEL_ROWS.get(key)
        terms_by_level = LEVEL_TERMS.get(key)
        for level in range(3):
            effect_ids: list[str] = []
            on_enter_ids: list[str] = []
            if terms_by_level is not None:
                # Per-level authored national numbers. Each level names its own
                # definition so the value is literally what the design doc says,
                # instead of the 1.0/1.6/2.2 curve applied to one shared row.
                #
                # ONE row per level, not one per term: the definition carries the
                # level's whole term list (`modifier_blocks` emits it that way),
                # and a row per term would name keys that do not exist -- the
                # presenter would then render an empty card face and nothing
                # would report why.
                if len(terms_by_level) != 3:
                    raise SystemExit(f"terms: {key} needs exactly 3 levels")
                effect_id = f"Effect{base}L{level + 1}"
                blocks.append(effect_block(
                    effect_id, f"ideology.{key}.l{level + 1}", Q16))
                effect_ids.append(effect_id)
            elif rows_by_level is None:
                effect_id = f"Effect{base}L{level + 1}"
                blocks.append(effect_block(
                    effect_id, f"ideology.{key}", LEVEL_MAGNITUDES[level]))
                effect_ids.append(effect_id)
            elif _terms:
                # A card that authors programs still keeps its *price* on the
                # legacy path, at magnitude 1.0 on every level: the price does
                # not grow with the level, the benefit does.
                cost_id = f"Effect{base}CostL{level + 1}"
                blocks.append(effect_block(cost_id, f"ideology.{key}", Q16))
                effect_ids.append(cost_id)
            authored_on_enter = LEVEL_ON_ENTER_EFFECTS.get(key, [[], [], []])[level]
            for row_index, row in enumerate(authored_on_enter):
                row_id = f"Effect{base}L{level + 1}OnEnter{row_index}"
                blocks.append(on_enter_effect_block(row_id, row))
                on_enter_ids.append(row_id)
            # Programs are independent of where the national rows came from: a
            # card may ship national numbers on L1/L2 and add a cell-level clause
            # on L3 (the design's "L3 追加一条子句"). `None` means "this level has
            # no program", which is the normal case for such a card.
            if rows_by_level is not None and rows_by_level[level]:
                for row_index, item in enumerate(rows_by_level[level]):
                    row_id = f"Effect{base}L{level + 1}R{row_index}"
                    blocks.append(program_row_block(row_id, item.key, item.stacks))
                    effect_ids.append(row_id)
            level_id = f"Level{base}L{level + 1}"
            blocks.append(
                f'[sub_resource type="Resource" id="{level_id}"]\n'
                'script = ExtResource("4_level")\n'
                f"understanding_threshold_q16 = {LEVEL_THRESHOLDS[level]}\n"
                f"daily_understanding_q16 = {LEVEL_DAILY[level]}\n"
                "persistent_effects = Array[Resource]([%s])\n" % ", ".join(
                    f'SubResource("{item}")' for item in effect_ids) +
                "on_enter_effects = Array[Resource]([%s])\n" % ", ".join(
                    f'SubResource("{item}")' for item in on_enter_ids))
            level_ids.append(level_id)
        stance_ids = []
        for class_id, (adopt, repeal, promote) in sorted(SCHOOL_STANCES[school].items()):
            stance_id = f"Stance{base}{camel(class_id)}"
            blocks.append(
                f'[sub_resource type="Resource" id="{stance_id}"]\n'
                'script = ExtResource("5_stance")\n'
                f'class_id = &"{class_id}"\n'
                f"adopt_stance_q16 = {adopt}\nrepeal_stance_q16 = {repeal}\n"
                f"promote_stance_q16 = {promote}\n"
                + "".join(f"{field} = {value}\n" for field, value in sorted(
                    CRITICAL_FLOORS.get((key, class_id), {}).items())))
            stance_ids.append(stance_id)
        # Technology gate first (era milestone + explicit tech), then the
        # geography gates. The native runtime ANDs every requirement, so a card
        # only enters the draw pool once the player owns its era AND its terrain
        # and resource facts.
        gate_techs: list[str] = []
        if era > 0:
            gate_techs.append(ERA_MILESTONE_TECH[era])
        if tech and tech not in gate_techs:
            gate_techs.append(tech)
        requirement_refs: list[str] = []
        for gate_index, gate_tech in enumerate(gate_techs):
            requirement_id = f"Require{base}G{gate_index}"
            blocks.append(
                f'[sub_resource type="Resource" id="{requirement_id}"]\n'
                'script = ExtResource("8_requirement")\n'
                f'kind = 1\nkey = &"{gate_tech}"\n')
            requirement_refs.append(requirement_id)
        for signal_index, signal in enumerate(signals):
            requirement_id = f"Require{base}S{signal_index}"
            blocks.append(
                f'[sub_resource type="Resource" id="{requirement_id}"]\n'
                'script = ExtResource("8_requirement")\n'
                f'kind = 2\nkey = &"{signal}"\n')
            requirement_refs.append(requirement_id)
        requirement_line = ""
        if requirement_refs:
            requirement_line = "draw_requirements = Array[Resource]([%s])\n" % ", ".join(
                f'SubResource("{item}")' for item in requirement_refs)
        definition_id = f"Idea{base}"
        definition_ids.append(definition_id)
        meta = CARD_META.get(key)
        route_line = ""
        if meta is not None and meta.route:
            route_line = f'route_tag = &"{meta.route}"\n'
            if meta.secondary:
                route_line += "secondary_route_tags = PackedStringArray(%s)\n" % (
                    ", ".join(f'"{tag}"' for tag in meta.secondary))
        blocks.append(
            f'[sub_resource type="Resource" id="{definition_id}"]\n'
            'script = ExtResource("3_definition")\n'
            f'id = &"idea.{key}"\n'
            f'icon_key = &"{SCHOOL_ICONS[school]}"\n'
            f'name_key = &"{name}"\n'
            f'detail_key = "{detail}"\n'
            f'school_id = &"{school}"\n'
            + route_line +
            f"rarity = {rarity}\n"
            f"era_index = {era}\n"
            f"rarity_weight = {RARITY_WEIGHTS[rarity]}\n"
            "national_spirit_min_level = 1\n"
            + requirement_line +
            "class_stances = Array[Resource]([%s])\n" % ", ".join(
                f'SubResource("{stance}")' for stance in stance_ids) +
            f"adopt_threshold_q16 = {ADOPT_THRESHOLD[rarity]}\n"
            "repeal_threshold_q16 = 0\n"
            f"promote_threshold_q16 = {PROMOTE_THRESHOLD[rarity]}\n"
            + (f'exclusion_group = &"{exclusion}"\n' if exclusion else "") +
            ("copy_left_programs = true\n" if key == "algorithmic_governance"
             else "") +
            ("copyable = false\n" if rarity == 3 else "") +
            "levels = Array[Resource]([%s])\n" % ", ".join(
                f'SubResource("{level}")' for level in level_ids))
    synergy_ids: list[str] = []
    # X5 hidden self-synergies: one per authored level, carrying that level's
    # rewrites. They compile into the native condition table for the equipped
    # card but are hidden from the resonance/card "联动" surfaces.
    for key, levels in LEVEL_REWRITES.items():
        definition = next((row for row in cards_to_emit() if row[0] == key), None)
        if definition is None:
            continue
        if any(name not in AVAILABLE_CAPABILITIES
               for name in CARD_REQUIRES.get(key, ())):
            continue
        base = camel(key)
        for level_index, rows in enumerate(levels):
            if not rows:
                continue
            override_ids: list[str] = []
            for row_index, row in enumerate(rows):
                override_id = f"Rewrite{base}L{level_index + 1}R{row_index}"
                blocks.append(
                    f'[sub_resource type="Resource" id="{override_id}"]\n'
                    'script = ExtResource("10_param")\n'
                    f"target_definition_key = &\"{row.match_program or row.match_route or row.match_tag}\"\n"
                    f"field = {row.field}\n"
                    f"value = {row.value}\n"
                    f"match_kind = {row.match_kind()}\n"
                    f'match_value = &"{row.match_value()}"\n'
                    + (f'tag_value = &"{row.tag}"\n' if row.tag else "") +
                    f'note = "X5 {key} L{level_index + 1}"\n')
                override_ids.append(override_id)
            synergy_id = f"SynergyRewrite{base}L{level_index + 1}"
            synergy_ids.append(synergy_id)
            blocks.append(
                f'[sub_resource type="Resource" id="{synergy_id}"]\n'
                'script = ExtResource("6_synergy")\n'
                f'id = &"rewrite.{key}.l{level_index + 1}"\n'
                f'display_name = "{key}·L{level_index + 1}"\n'
                f'required_ideology_ids = PackedStringArray("idea.{key}")\n'
                f"minimum_levels = PackedInt32Array({level_index})\n"
                "location_masks = PackedByteArray(2)\n"
                "min_count = 1\n"
                "hidden = true\n"
                "overrides = Array[Resource]([%s])\n" % ", ".join(
                    f'SubResource("{item}")' for item in override_ids))
    for key, name, cards, _terms in NAMED_SYNERGIES:
        base = camel(key)
        effect_id = f"EffectSynergy{base}"
        blocks.append(effect_block(effect_id, f"ideology.synergy.{key}", Q16))
        synergy_id = f"Synergy{base}"
        synergy_ids.append(synergy_id)
        blocks.append(
            f'[sub_resource type="Resource" id="{synergy_id}"]\n'
            'script = ExtResource("6_synergy")\n'
            f'id = &"synergy.{key}"\n'
            f'display_name = "{name}"\n'
            "required_ideology_ids = PackedStringArray(%s)\n" % ", ".join(
                f'"idea.{card}"' for card in cards) +
            "minimum_levels = PackedInt32Array(%s)\n" % ", ".join("0" for _ in cards) +
            "location_masks = PackedByteArray(%s)\n" % ", ".join("6" for _ in cards) +
            f'persistent_effects = Array[Resource]([SubResource("{effect_id}")])\n')
    for route, count, _terms in published_route_bonds():
        tier = 1 if count == 2 else 2
        display = ROUTE_BONDS[route][0]
        base = f"Route{camel(route)}{tier}"
        effect_id = f"Effect{base}"
        blocks.append(effect_block(
            effect_id, f"ideology.route.{route}.t{tier}", Q16))
        synergy_id = f"Synergy{base}"
        synergy_ids.append(synergy_id)
        blocks.append(
            f'[sub_resource type="Resource" id="{synergy_id}"]\n'
            'script = ExtResource("6_synergy")\n'
            f'id = &"route.{route}.{count}"\n'
            f'display_name = "{display}·{"一" if tier == 1 else "二"}"\n'
            'required_ideology_ids = PackedStringArray()\n'
            'minimum_levels = PackedInt32Array()\n'
            'location_masks = PackedByteArray()\n'
            f"min_count = {count}\n"
            f'route_tag = &"{route}"\n'
            "route_tag_min_level = 0\n"
            "route_tag_location_mask = 2\n"
            f'persistent_effects = Array[Resource]([SubResource("{effect_id}")])\n')
    for school in SCHOOL_ORDER:
        cards = [card[0] for card in cards_to_emit() if card[2] == school]
        for tier, count in ((1, 2), (2, 4)):
            if len(cards) < count:
                continue
            base = f"Resonance{camel(school)}{count}"
            effect_id = f"Effect{base}"
            blocks.append(effect_block(
                effect_id, f"ideology.resonance.{school}.{count}", Q16))
            synergy_id = f"Synergy{base}"
            synergy_ids.append(synergy_id)
            blocks.append(
                f'[sub_resource type="Resource" id="{synergy_id}"]\n'
                'script = ExtResource("6_synergy")\n'
                f'id = &"resonance.{school}.{count}"\n'
                f'display_name = "{SCHOOL_NAMES[school]}共鸣·{"一" if tier == 1 else "二"}"\n'
                "required_ideology_ids = PackedStringArray(%s)\n" % ", ".join(
                    f'"idea.{card}"' for card in cards) +
                "minimum_levels = PackedInt32Array(%s)\n" % ", ".join("0" for _ in cards) +
                "location_masks = PackedByteArray(%s)\n" % ", ".join("6" for _ in cards) +
                f"min_count = {count}\n"
                f'school_id = &"{school}"\n'
                f"resonance_tier = {tier}\n"
                f'persistent_effects = Array[Resource]([SubResource("{effect_id}")])\n')
    ext = [
        '[ext_resource type="Script" path="res://scripts/ideology/ideology_catalog.gd" id="1_catalog"]',
        '[ext_resource type="Script" path="res://scripts/ideology/ideology_profile.gd" id="2_profile"]',
        '[ext_resource type="Script" path="res://scripts/ideology/ideology_definition.gd" id="3_definition"]',
        '[ext_resource type="Script" path="res://scripts/ideology/ideology_level_definition.gd" id="4_level"]',
        '[ext_resource type="Script" path="res://scripts/ideology/ideology_class_stance.gd" id="5_stance"]',
        '[ext_resource type="Script" path="res://scripts/ideology/ideology_synergy_definition.gd" id="6_synergy"]',
        '[ext_resource type="Script" path="res://scripts/effect/effect_command.gd" id="7_effect"]',
        '[ext_resource type="Script" path="res://scripts/ideology/ideology_requirement.gd" id="8_requirement"]',
        '[ext_resource type="Resource" path="res://data/ideologies/default_ideology_effects.tres" id="9_programs"]',
        '[ext_resource type="Script" path="res://scripts/ideology/ideology_effect_parameter.gd" id="10_param"]',
    ]
    load_steps = len(ext) + len(blocks) + 1
    resource = (
        "[resource]\n"
        'script = ExtResource("1_catalog")\n'
        'profile = SubResource("Profile")\n'
        'effect_programs = ExtResource("9_programs")\n'
        "definitions = Array[Resource]([%s])\n" % ", ".join(
            f'SubResource("{item}")' for item in definition_ids) +
        "synergies = Array[Resource]([%s])\n" % ", ".join(
            f'SubResource("{item}")' for item in synergy_ids))
    header = f'[gd_resource type="Resource" script_class="IdeologyCatalog" load_steps={load_steps} format=3]\n'
    return header + "\n" + "\n".join(ext) + "\n\n" + "\n".join(blocks) + "\n" + resource


def _city_stat_label(suffix: str) -> str:
    """Human label for a cell stat, used only by the definition's display name."""
    sectors = {"agriculture": "农业", "extractive": "采掘", "manufacturing": "制造",
               "energy": "能源", "knowledge": "知识"}
    needs = {"staple_food": "主食", "housing": "住房", "clothing": "衣着",
             "household_goods": "家用品", "protein": "蛋白质",
             "home_energy": "家用能源"}
    resources = {"timber": "木材", "pasture": "牧草", "fertile_soil": "肥沃土壤",
                 "wild_game": "野味", "freshwater_fish": "淡水鱼"}
    goods = {"lumber": "原木", "crude_oil": "原油", "natural_gas": "天然气",
             "rice_grain": "稻米", "grain": "谷物", "cloth": "布",
             "fine_clothing": "精致服装", "fertilizer": "化肥", "plastics": "塑料",
             "game_meat": "野味", "fish": "鱼", "meat": "肉类",
             "dairy_products": "乳品"}
    if suffix == "output_factor":
        return "地块全部产出"
    if suffix == "birth_factor":
        return "地块出生率"
    parts = suffix.split(".")
    if parts[0] == "building" and len(parts) == 2:
        sector = parts[1].removesuffix("_output_factor")
        return f"地块{sectors.get(sector, sector)}产出"
    if parts[0] == "need" and len(parts) == 3:
        return f"地块{needs.get(parts[1], parts[1])}需求"
    if parts[0] == "resource" and len(parts) == 3:
        return f"地块{resources.get(parts[1], parts[1])}再生"
    if parts[0] == "good" and len(parts) == 3:
        return f"地块{goods.get(parts[1], parts[1])}产出"
    return suffix


def ideology_city_blocks() -> list[str]:
    """The cell-scoped ideology modifier family (gain + cut twins).

    The definition key is the *economy* stat, not `ideology.city.<suffix>`: gdext
    reads per-cell output through its own economy stat ids, so a definition
    keyed on `ideology.city.*` compiles, stores a row and changes nothing. That
    makes these keys collide with the ones `modifier_catalog.gd` generates in its
    own `card_target_stats` loop -- so a definition whose key is already produced
    by that loop is SKIPPED here. Emitting it twice fails the whole Modifier
    catalog with `modifier_definition_invalid_or_duplicate`, which takes every
    ideology card with it.

    `_city_generated_keys()` is the mirror of that loop: goods x output, building
    types x output, needs x consumption, plus the literal birth factor.
    """
    generated = _city_generated_keys()
    blocks: list[str] = []
    for suffix, stat in IDEOLOGY_CITY_STATS:
        label = _city_stat_label(suffix)
        for cut, operation in ((False, 0), (True, 1)):
            key = city_stat_key(suffix, cut)
            if key in generated:
                # modifier_catalog.gd already declares this one.
                continue
            base = "IdeologyCity" + camel(suffix.replace(".", "_")) + ("Cut" if cut else "")
            blocks.append(
                f'[sub_resource type="Resource" id="Term{base}"]\n'
                'script = ExtResource("4_term")\n'
                f'stat_key = &"{stat}"\noperation = {operation}\nvalue = 1.0\n')
            blocks.append(
                f'[sub_resource type="Resource" id="Def{base}"]\n'
                'script = ExtResource("3_definition")\n'
                f'key = &"{key}"\n'
                f'display_name = "{label}{"减益" if cut else "增益"}模板"\n'
                'description = "地块级理念模板：真实幅度由效果指令给出，不在此处写死。"\n'
                "domain = 2\nstack_policy = 1\ndefault_duration_days = -1\n"
                f'terms = Array[Resource]([SubResource("Term{base}")])\n')
    return blocks


def ideology_country_blocks() -> list[str]:
    """The country-scoped program modifier family, one definition per stat."""
    blocks: list[str] = []
    for suffix, stat, direction in IDEOLOGY_COUNTRY_STATS:
        label = {
            "population.death_factor": "人口死亡率",
            "construction.cost_factor": "建设成本",
            "trade.capacity_factor": "国内贸易容量",
            "output.agriculture_factor": "农业部门产出",
            "output.extractive_factor": "采掘部门产出",
            "output.manufacturing_factor": "制造部门产出",
            "output.energy_factor": "能源部门产出",
            "output.knowledge_factor": "知识部门产出",
            "ideology.point_gain_factor": "理念点获取",
            "ideology.point_population_factor": "人口增长理念点",
            "ideology.point_building_factor": "建筑增长理念点",
            "ideology.point_trade_factor": "贸易理念点",
            "ideology.school_strength_factor.harmony": "调和理念强度",
        }.get(suffix, suffix)
        cut = direction == "cut"
        key = country_stat_key(suffix, cut=cut, gain=not cut)
        base = "IdeologyCountry" + camel(suffix.replace(".", "_")) + \
            ("Cut" if cut else "Gain")
        factor = 0.0 if cut else 2.0
        blocks.append(
            f'[sub_resource type="Resource" id="Term{base}"]\n'
            'script = ExtResource("4_term")\n'
            f'stat_key = &"{stat}"\noperation = 2\nvalue = {factor}\n')
        blocks.append(
            f'[sub_resource type="Resource" id="Def{base}"]\n'
            'script = ExtResource("3_definition")\n'
            f'key = &"{key}"\n'
            f'display_name = "{label}{"减益" if cut else "增益"}模板"\n'
            'description = "国家级理念模板：真实幅度由效果指令给出，不在此处写死。"\n'
            "domain = 1\nstack_policy = 1\ndefault_duration_days = -1\n"
            f'terms = Array[Resource]([SubResource("Term{base}")])\n')
    return blocks


def _city_generated_keys() -> set[str]:
    """Definition keys `modifier_catalog.gd` already generates per cell.

    Mirrors `card_target_stats` in `modifier_catalog.gd` exactly: goods x output,
    building types x output, needs x consumption, plus the bare birth factor.
    Notably it does NOT generate the aggregate `economy.city.output_factor` or
    the resource-regen family, so those still have to be emitted here.
    """
    keys = {"economy.city.birth_factor", "economy.city.birth_factor.cut"}
    for good in _read_res_dir_ids(GOODS_DIR):
        keys.add(f"economy.city.good.{good}.output_factor")
        keys.add(f"economy.city.good.{good}.output_factor.cut")
    for building in _read_res_dir_ids(BUILDINGS_DIR):
        keys.add(f"economy.city.building.{building}_output_factor")
        keys.add(f"economy.city.building.{building}_output_factor.cut")
    for need in _read_res_dir_ids(NEEDS_DIR):
        keys.add(f"economy.city.need.{need}.consumption_factor")
        keys.add(f"economy.city.need.{need}.consumption_factor.cut")
    return keys


_CITY_EMITTED = [f'IdeologyCity{camel(s.replace(".", "_"))}{"Cut" if c else ""}'
                 for s, _ in IDEOLOGY_CITY_STATS for c in (False, True)
                 if city_stat_key(s, c) not in _city_generated_keys()]
MODIFIER_CITY_TERM_IDS = [f"Term{base}" for base in _CITY_EMITTED]
MODIFIER_CITY_DEFINITION_IDS = [f"Def{base}" for base in _CITY_EMITTED]
_COUNTRY_EMITTED = [
    f'IdeologyCountry{camel(s.replace(".", "_"))}'
    f'{"Cut" if direction == "cut" else "Gain"}'
    for s, _stat, direction in IDEOLOGY_COUNTRY_STATS
]
MODIFIER_COUNTRY_TERM_IDS = [f"Term{base}" for base in _COUNTRY_EMITTED]
MODIFIER_COUNTRY_DEFINITION_IDS = [f"Def{base}" for base in _COUNTRY_EMITTED]


def modifier_blocks() -> tuple[list[str], list[str]]:
    blocks: list[str] = []
    definition_ids: list[str] = []

    # `ModifierRuntime::INDEPENDENT` is policy 0. It means "no unique instance": every
    # application writes its own row and nothing dedupes or retires them, so an
    # ideology card that equips twice (level-up, relocation, re-equip) would stack
    # rows forever and the card's numbers would never come back down.
    #
    # The generator emits `stack_policy = 1` (UNIQUE_SOURCE) for every ideology
    # definition, so this is currently unreachable -- which is exactly why it is
    # asserted rather than assumed: the number is written twice (here and in
    # `modifier_runtime.h`), and a future edit that "simplifies" it to 0 would look
    # harmless and break every multi-level card silently.
    IDEOLOGY_MODIFIER_STACK_POLICY = 1
    if IDEOLOGY_MODIFIER_STACK_POLICY == 0:
        raise SystemExit(
            "ideology modifier: stack_policy 0 (POLICY_INDEPENDENT) is forbidden; "
            "ideology definitions must be UNIQUE_SOURCE (1) so re-equip and level-up "
            "replace the previous row instead of stacking it")

    def add(def_id: str, key: str, name: str, description: str, terms) -> None:
        term_ids = []
        for index, entry in enumerate(terms):
            # Two shapes: `(stat, value)` -- the historical multiplier row with
            # the operation implied -- and `(stat, value, tag)` for rows that
            # must ADD (tax points) rather than multiply.
            #
            # A `RampTerm` is SKIPPED here on purpose: a ramp is an Effect
            # instruction sequence (CONST per -> READ_METRIC -> CONST cap -> MIN ->
            # MUL_Q16 -> EMIT), which a plain Modifier definition cannot carry. It
            # has to be authored as a program row once its metric exists. Emitting a
            # constant instead would silently replace "every band -0.5%" with a flat
            # number, so leaving it out is the safer failure -- and `validate_cards`
            # refuses a RampTerm on any card that is not staged on `reserve_ratio`,
            # so it can never quietly vanish from a published card.
            if isinstance(entry, RampTerm):
                continue
            stat, value = entry[0], entry[1]
            operation = _term_operation(entry)
            term_id = f"TermIdeology{def_id}{index}"
            term_ids.append(term_id)
            blocks.append(
                f'[sub_resource type="Resource" id="{term_id}"]\n'
                'script = ExtResource("4_term")\n'
                f'stat_key = &"{stat}"\noperation = {operation}\n'
                f"value = {fmt_value(value)}\n")
        full_id = f"DefIdeology{def_id}"
        definition_ids.append(full_id)
        blocks.append(
            f'[sub_resource type="Resource" id="{full_id}"]\n'
            'script = ExtResource("3_definition")\n'
            f'key = &"{key}"\n'
            f'display_name = "{name}"\n'
            f'description = "{description}"\n'
            "domain = 1\nstack_policy = {policy}\ndefault_duration_days = -1\n".format(
                policy=IDEOLOGY_MODIFIER_STACK_POLICY) +
            "terms = Array[Resource]([%s])\n" % ", ".join(
                f'SubResource("{term}")' for term in term_ids))

    for key, name, _school, _rarity, _era, _exclusion, _tech, _signals, detail, terms in cards_to_emit():
        # A program card may carry no national terms at all (its whole price is a
        # cell-level cut). Emitting an empty definition would fail the Modifier
        # catalog with `modifier_definition_invalid_or_duplicate`.
        if not terms:
            continue
        add(camel(key), f"ideology.{key}", name, detail, terms)
    # Per-level national rows (see `LEVEL_TERMS`): the `x` slot can only emit
    # Multiply terms, so a level whose numbers are a mix of multipliers and
    # additive points lives entirely in its own definition with explicit
    # operations.
    # Only cards that will actually be published may emit Modifier definitions: a
    # staged card's stats may not exist yet (X16), and emitting a definition that
    # names an undeclared stat makes `compile_native_catalog()` return
    # `modifier_term_invalid` -- which takes the WHOLE Modifier catalog down, not
    # just that card.
    published = {card[0] for card in cards_to_emit()}
    for key, levels in LEVEL_TERMS.items():
        if key not in published:
            continue
        entry = next(card for card in CARDS if card[0] == key)
        name, detail = entry[1], entry[8]
        for level_index, rows in enumerate(levels):
            add(f"{camel(key)}L{level_index + 1}",
                f"ideology.{key}.l{level_index + 1}",
                f"{name}（{LEVEL_TITLES[level_index]}）", detail, rows)
    for route, count, terms in published_route_bonds():
        tier = 1 if count == 2 else 2
        display = ROUTE_BONDS[route][0]
        add(f"Route{camel(route)}{tier}",
            f"ideology.route.{route}.t{tier}",
            f"{display}·{'一' if tier == 1 else '二'}",
            f"{display}体系联动修正（{count} 张）。",
            terms)
    for key, name, _cards, terms in NAMED_SYNERGIES:
        add("Synergy" + camel(key), f"ideology.synergy.{key}", name, f"{name}联动修正。", terms)
    for school in SCHOOL_ORDER:
        school_card_count = sum(
            1 for card in cards_to_emit() if card[2] == school)
        for count, terms in zip((2, 4), RESONANCES[school]):
            if school_card_count < count:
                continue
            add(f"Resonance{camel(school)}{count}", f"ideology.resonance.{school}.{count}",
                f"{SCHOOL_NAMES[school]}共鸣{count}",
                f"装备或晋升{count}张{SCHOOL_NAMES[school]}理念。", terms)
    blocks.extend(ideology_city_blocks())
    definition_ids.extend(MODIFIER_CITY_DEFINITION_IDS)
    blocks.extend(ideology_country_blocks())
    definition_ids.extend(MODIFIER_COUNTRY_DEFINITION_IDS)
    return blocks, definition_ids


def rewrite_modifier_catalog() -> None:
    text = MODIFIER_PATH.read_text(encoding="utf-8")
    header, _, body = text.partition("\n")
    sections = re.split(r"\n(?=\[)", body)
    kept: list[str] = []
    resource_section = ""
    for section in sections:
        stripped = section.strip("\n")
        if not stripped:
            continue
        match = re.match(r'\[sub_resource type="Resource" id="([^"]+)"\]', stripped)
        if match and re.match(r"(TermIdeology|DefIdeology)", match.group(1)):
            continue
        if stripped.startswith("[resource]"):
            resource_section = stripped
            continue
        kept.append(stripped)
    blocks, definition_ids = modifier_blocks()
    kept.extend(block.strip("\n") for block in blocks)

    def fix_definitions(match: re.Match) -> str:
        items = [item.strip() for item in match.group(1).split(",") if item.strip()]
        items = [item for item in items if not re.search(r'"DefIdeology', item)]
        items.extend(f'SubResource("{item}")' for item in definition_ids)
        return "definitions = Array[Resource]([%s])" % ", ".join(items)

    resource_section = re.sub(r"definitions = Array\[Resource\]\(\[(.*)\]\)",
                              fix_definitions, resource_section)
    resource_count = sum(1 for section in kept if section.startswith(("[sub_resource", "[ext_resource")))
    header = re.sub(r"load_steps=\d+", f"load_steps={resource_count + 1}", header)
    ext_sections = [section for section in kept if section.startswith("[ext_resource")]
    sub_sections = [section for section in kept if not section.startswith("[ext_resource")]
    MODIFIER_PATH.write_text(header + "\n\n" + "\n".join(ext_sections) + "\n\n"
                             + "\n\n".join(sub_sections) + "\n\n" + resource_section + "\n",
                             encoding="utf-8", newline="\n")


def all_card_programs() -> list[Prog]:
    """Every authored card program, in catalog order."""
    out: list[Prog] = []
    for card in cards_to_emit():
        for level in LEVEL_ROWS.get(card[0], ()):
            out.extend(level)
    return out


def all_authored_card_programs() -> list[Prog]:
    """Every card program, including rows of cards currently staged."""
    out: list[Prog] = []
    for card in CARDS:
        for level in LEVEL_ROWS.get(card[0], ()):
            out.extend(level)
    return out


def _validate_source_count_program(item: Prog, tag_names: set[str]) -> None:
    """The nine §7.6 (T10) rejection rules for kind-16 programs.

    Every rule is a hard failure at generation time. The point is that a card can
    never ship with a parameter the runtime will read as something else: the four
    geometry parameters share one packed int, so a silent clamp would not fail, it
    would retarget the card.
    """
    is_src = item.selector == SEL_TAG_SOURCE_COUNT
    has_src_fields = (item.radius != 0 or item.cap != 0
                      or item.per_source is not None)
    if not is_src:
        # Rule 8: kind-16-only fields on a selector that never reads them.
        if has_src_fields:
            raise SystemExit(
                f"program: {item.key} sets radius/cap/per_source but selector is "
                f"{item.selector}, which does not read them")
        # Rule 9: kind 14/15 is union semantics; per_source would read as stacking.
        if item.selector in (SEL_TAG_SOURCE_R1, SEL_TAG_SOURCE_R2) and \
                item.per_source is not None:
            raise SystemExit(
                f"program: {item.key} uses kind {item.selector} (union) with "
                "per_source; union selectors do not stack")
        return

    # Rule 1: no strength.
    if item.per_source is None:
        raise SystemExit(
            f"program: {item.key} uses SEL_TAG_SOURCE_COUNT without per_source")
    # Rule 2: source tag is mandatory (0 = whole territory, must be explicit).
    if not item.tags:
        raise SystemExit(
            f"program: {item.key} uses SEL_TAG_SOURCE_COUNT without a source tag")
    # Rule 3: exactly one source tag (multi-tag needs DNF, which is X2).
    if len(item.tags) != 1:
        raise SystemExit(
            f"program: {item.key} names {len(item.tags)} source tags; kind 16 "
            "takes exactly one")
    # Rule 4: radius within the 3-bit field and the documented 1..4.
    if not 1 <= item.radius <= 4:
        raise SystemExit(
            f"program: {item.key} radius {item.radius} out of 1..4")
    # Rule 5: count cap within the 4-bit field.
    if not 1 <= item.cap <= SC_COUNT_CAP_BITS:
        raise SystemExit(
            f"program: {item.key} cap {item.cap} out of 1..{SC_COUNT_CAP_BITS}")
    # Rule 6: one command, one scale (same shape as `ramp`).
    if len(item.cmds) != 1:
        raise SystemExit(
            f"program: {item.key} has {len(item.cmds)} commands; a source-count "
            "scale applies to exactly one")
    # Rule 7: the full stack must fit MAX_MAGNITUDE_Q16 (4x).
    if abs(item.per_source) * item.cap > 4.0 + 1e-9:
        raise SystemExit(
            f"program: {item.key} per_source x cap = "
            f"{abs(item.per_source) * item.cap:.3f} exceeds the 4x magnitude ceiling")
    # Extra: the packed geometry must survive the round trip. `selector_cap == 32`
    # is the default and packs as 0 ("take the default"), which unpacks back to 32.
    packed, _ = pack_source_count(
        item.selector_cap if item.selector_cap != 32 else 0,
        item.radius, item.cap, 1)
    target_cap, radius, count_cap, _ = unpack_source_count(packed, 0)
    if (target_cap, radius, count_cap) != (
            item.selector_cap if item.selector_cap else 32, item.radius, item.cap):
        raise SystemExit(
            f"program: {item.key} does not round-trip through the packed layout")


def _is_ratio_metric(metric: str) -> bool:
    """True for metrics whose unit is a 0..1 ratio.

    `*_q16` is the naming convention for "the value is a Q16 fraction", so the
    metric reading is in [0, 1] and a cap above 1.0 caps nothing. Every other
    metric here is a COUNT (`cell.manufacturing_building_count`,
    `country.chained_cell_count`) or a percentage band (`*_pct`,
    `*_burden_bp`) whose natural cap is a plain number.
    """
    return metric.endswith("_q16")


def _is_count_metric(metric: str) -> bool:
    """True for metrics that count discrete things (buildings, cells, goods)."""
    return metric.endswith(("_count", "_id", "_class_count", "_cell_count",
                            "_building_count", "_profession_count"))


RAMP_LINT_ERRORS: list[str] = []


def ramp_unit_error(metric: str, per: float, cap: float) -> str:
    """Why this (metric, per, cap) triple violates the Ramp unit contract, or "".

    The three rules exist because every one of them has already shipped as a real
    bug that no other check caught:

    (a) a `*_q16` metric is a 0..1 ratio, so `cap > 1.0` caps nothing and the
        card silently runs at full strength -- `basic_income` had `cap=15.0` here.
    (b) `per * cap` is the ceiling as a fraction; above 1.0 the runtime clamps and
        the printed number is a lie.
    (c) a count metric needs a per-COUNT fraction; `per=2.0` reads "+200% per
        building" -- `manufactory_regulation` shipped exactly that.
    """
    if _is_ratio_metric(metric) and cap > 1.0 + 1e-9:
        return (f"metric {metric} is a 0..1 ratio but cap={cap}; "
                "cap must be <= 1.0 (rule a)")
    if abs(per) * cap > 1.0 + 1e-9:
        return (f"per={per} x cap={cap} = {abs(per) * cap:.4f} exceeds 1.0 (+100%); "
                "the runtime clamps it and the card face becomes a lie (rule b)")
    if _is_count_metric(metric) and abs(per) > 0.1 + 1e-9:
        return (f"metric {metric} counts discrete units but per={per}; a per-unit "
                "gain must be a fraction <= 0.1 (e.g. 0.02 for +2%) (rule c)")
    return ""


def validate_ramp_units() -> None:
    """Run `ramp_unit_error` over every ramp the generator knows about."""
    problems: list[str] = []
    for item in DIAGNOSTIC_PROGRAMS + all_authored_card_programs():
        if item.ramp is None:
            continue
        reason = ramp_unit_error(item.ramp.metric, item.ramp.per, item.ramp.cap)
        if reason:
            problems.append(f"program {item.key}: {reason}")
    for key, levels in LEVEL_TERMS.items():
        for level_index, rows in enumerate(levels):
            for entry in rows:
                if not isinstance(entry, RampTerm):
                    continue
                reason = ramp_unit_error(entry.ramp.metric, entry.ramp.per,
                                         entry.ramp.cap)
                if reason:
                    problems.append(f"{key} L{level_index + 1} ({entry.stat}): {reason}")
    if problems:
        raise SystemExit("ramp units:\n  " + "\n  ".join(problems))


def validate_country_cut_ramp_caps() -> None:
    """A `.cut` factor cannot lower a stat by a whole unit.

    Country cuts are MULTIPLY definitions with factor 0.0, so the effective
    factor is `1 - per * min(metric, cap)`. At `per * cap >= 1.0` the bucket
    reaches zero (or the runtime clamps it); both make the card face a lie.
    Equality is deliberately rejected, unlike the generic ramp ceiling lint.
    """
    country_cuts = {
        country_stat_key(suffix, cut=True)
        for suffix, _stat, direction in IDEOLOGY_COUNTRY_STATS
        if direction == "cut"
    }
    problems: list[str] = []
    for item in DIAGNOSTIC_PROGRAMS + all_authored_card_programs():
        if item.ramp is None:
            continue
        for command in item.cmds:
            key = command.modifier
            if command.value < 0.0 and not key.endswith((".cut", ".gain")):
                key += ".cut"
            if key not in country_cuts:
                continue
            ceiling = abs(item.ramp.per * item.ramp.cap)
            if ceiling >= 1.0 - 1e-9:
                problems.append(
                    f"{item.key}: {key} per x cap = {ceiling:.4f} >= 1.0")
    if problems:
        raise SystemExit(
            "country cut ramps:\n  " + "\n  ".join(problems))


def _program_levels_must_not_regress(key: str, levels) -> None:
    """L(n+1) must be at least as strong as L(n) -- no level may go backwards.

    Two symptoms this catches, both real:
      * a level that SWAPS one stat for another, dropping a benefit the player was
        already paying for (`basic_income_l3` briefly lost its knowledge ramp);
      * a level that keeps the benefit but shrinks it.

    Direction matters, and getting it wrong fires on a legitimate upgrade:
    `coppice_rotation` L3 halves its own PENALTY (原木产出 -6% -> -3%), which is
    stronger for the player, not weaker. So benefits must not shrink and prices must
    not grow; dropping a price entirely is always allowed.
    """
    def split_strength(rows):
        """(benefit stat -> multiplier, price stat -> multiplier) for one level."""
        benefits: dict[str, float] = {}
        prices: dict[str, float] = {}
        for item in rows:
            for command in item.cmds:
                if item.ramp is not None:
                    # A ramp's magnitude is `per * min(metric, cap)`, so its
                    # ceiling is `per * cap`, not `per` alone.
                    magnitude = abs(command.value) if command.value else abs(
                        item.ramp.per * item.ramp.cap)
                elif item.selector == SEL_TAG_SOURCE_COUNT:
                    # The authored command value is the runtime's per-source
                    # unit; the program itself carries `per_source * cap`.
                    magnitude = abs(item.per_source) * item.cap
                else:
                    magnitude = abs(command.value)
                is_price = _is_downside(command.modifier, 1.0 + command.value)
                target = prices if is_price else benefits
                target[command.modifier] = max(
                    target.get(command.modifier, 0.0), magnitude)
        return benefits, prices

    for level_index in range(len(levels) - 1):
        lower_b, lower_p = split_strength(levels[level_index])
        higher_b, higher_p = split_strength(levels[level_index + 1])
        for stat, strength in lower_b.items():
            if stat not in higher_b:
                raise SystemExit(
                    f"monotonic: {key} L{level_index + 2} drops {stat} that "
                    f"L{level_index + 1} already granted -- a level-up that takes "
                    "a benefit away is a downgrade")
            if higher_b[stat] + 1e-9 < strength:
                raise SystemExit(
                    f"monotonic: {key} L{level_index + 2} weakens {stat} "
                    f"({higher_b[stat]:.4f} < {strength:.4f})")
        # Prices: keeping one is fine, making it heavier is not; removing it is a
        # legitimate upgrade.
        for stat, strength in lower_p.items():
            if stat in higher_p and higher_p[stat] > strength + 1e-9:
                raise SystemExit(
                    f"monotonic: {key} L{level_index + 2} raises the price on "
                    f"{stat} ({higher_p[stat]:.4f} > {strength:.4f})")

    # Ramp per / ceiling must both be monotone (benefit direction only: a ramp that
    # lowers a PRICE is still an upgrade, but no ramp in the catalog prices).
    per_by_level: list[float] = []
    ceil_by_level: list[float] = []
    for rows in levels:
        per_max = 0.0
        ceil_max = 0.0
        for item in rows:
            if item.ramp is None:
                continue
            per_max = max(per_max, abs(item.ramp.per))
            ceil_max = max(ceil_max, abs(item.ramp.per * item.ramp.cap))
        per_by_level.append(per_max)
        ceil_by_level.append(ceil_max)
    for level_index in range(len(per_by_level) - 1):
        if per_by_level[level_index + 1] + 1e-9 < per_by_level[level_index]:
            raise SystemExit(
                f"monotonic: {key} L{level_index + 2} lowers ramp per "
                f"({per_by_level[level_index + 1]} < {per_by_level[level_index]})")
        if ceil_by_level[level_index + 1] + 1e-9 < ceil_by_level[level_index]:
            raise SystemExit(
                f"monotonic: {key} L{level_index + 2} lowers ramp ceiling "
                f"({ceil_by_level[level_index + 1]} < {ceil_by_level[level_index]})")


def validate_monotonic_levels() -> None:
    """Apply the no-downgrade rule to every card that has three levels."""
    for key, levels in LEVEL_ROWS.items():
        if len(levels) == 3 and any(levels):
            _program_levels_must_not_regress(key, levels)


# stat key (or a suffix of it) -> the Chinese word a card summary must use when it
# writes that stat. Deliberately small: this is a guard against "the card says 贸易
# but the stat is 全部产出", not a translation system.
STAT_WORD = {
    "output_factor": "全部产出",
    "building.agriculture_output_factor": "农业",
    "building.extractive_output_factor": "采掘",
    "building.manufacturing_output_factor": "工业",
    "building.energy_output_factor": "能源",
    "building.knowledge_output_factor": "知识",
    "birth_factor": "出生率",
    "need.staple_food.consumption_factor": "主食需求",
    "need.protein.consumption_factor": "蛋白质需求",
    "need.home_energy.consumption_factor": "家用能源需求",
    "need.housing.consumption_factor": "住房需求",
    "need.clothing.consumption_factor": "服装",
    "need.household_goods.consumption_factor": "家用品",
    "resource.regen_factor": "资源再生",
    "resource.timber.regen_factor": "木材再生",
    "resource.pasture.regen_factor": "牧场再生",
    "resource.fertile_soil.regen_factor": "土壤再生",
    "resource.wild_game.regen_factor": "野生动物再生",
    "resource.freshwater_fish.regen_factor": "渔业再生",
    "good.fertilizer.output_factor": "化肥产出",
    "good.lumber.output_factor": "原木产出",
    "good.cloth.output_factor": "布产出",
    "good.crude_oil.output_factor": "原油",
    "good.natural_gas.output_factor": "天然气",
    "good.fish.output_factor": "鱼产出",
    "good.meat.output_factor": "肉类产出",
    "good.dairy_products.output_factor": "乳品产出",
}

# Extra words a summary may use for a stat whose exact key IS in the table.
STAT_WORD_ALIASES = {
    # `output_factor` gets NO bare-`产出` alias: every summary ends with "产出 +N%", so a two-character alias matched everything and the rule became a no-op. The point is to force 全部产出 when the stat is all-output.
    # 矿业 is the player-facing word for the extractive sector; 采掘 is the
    # literal one. Both describe the same stat, so the alias is honest.
    "building.extractive_output_factor": ("采掘", "矿业"),
}


def summary_missing_stat_word(stat: str, summary: str) -> str:
    """The word this stat needs in a summary that lacks it, or "" when it is fine.

    A stat with no entry in `STAT_WORD` is not checked: inventing a word for
    `economy.profession.*.tax_tolerance_factor` would be worse than skipping it,
    and the point of the rule is the mismatch cases that already happened
    (`department_store` said 贸易 while writing 全部产出).
    """
    # The key prefix is `economy.city.`, NOT `ideology.city.`: `city_stat_key()`
    # builds into the ECONOMY modifier namespace. Getting that wrong made this
    # function return "" for every real stat -- the lint was silently checking
    # nothing at all, which is worse than not having it.
    for prefix in ("economy.city.", "ideology.city."):
        if stat.startswith(prefix):
            suffix = stat[len(prefix):]
            break
    else:
        suffix = stat
    word = STAT_WORD.get(suffix)
    if word is None:
        return ""
    allowed = (word,) + STAT_WORD_ALIASES.get(suffix, ())
    if any(candidate in summary for candidate in allowed):
        return ""
    return word


def validate_summary_matches_stats() -> None:
    """No card may describe a stat it does not write, or write one it never names."""
    problems: list[str] = []
    for card_key, levels in LEVEL_ROWS.items():
        for level_index, rows in enumerate(levels):
            for item in rows:
                for command in item.cmds:
                    word = summary_missing_stat_word(
                        command.modifier, item.summary)
                    if word:
                        problems.append(
                            f"{item.key} (L{level_index + 1}) writes "
                            f"{command.modifier} but its summary never says "
                            f"「{word}」: {item.summary!r}")
    if problems:
        raise SystemExit("summary/stat mismatch:\n  " + "\n  ".join(problems))


def validate_selector_kinds_emitted() -> None:
    """No emitted program may use a selector kind the POD layer cannot carry.

    This is the specific guard for kind 16: X1-b is not shipped, so a kind-16
    program reaching the effects catalog would fail at load time and take the whole
    catalog down with it. It inspects the DOCUMENT just written, not the authoring
    tables, which is what catches the whole class of "the switch leaked":

      * a staged card that was emitted anyway;
      * a target merged without flipping its switch;
      * an emitter path that forgot `cards_to_emit()`.
    """
    ceiling = pod_max_selector_kind()
    text = EFFECTS_PATH.read_text(encoding="utf-8")
    kinds = [int(value) for value in
             re.findall(r"target_selector_kind = (\d+)", text)]
    offenders = sorted({kind for kind in kinds if kind > ceiling})
    if not offenders:
        return
    if "X1b" in AVAILABLE_CAPABILITIES:
        # Expected during the switch simulation. Not an error: raising the POD
        # ceiling is R's work, and the simulation exists precisely to prove the
        # emit path works BEFORE that lands. Warn loudly so nobody mistakes these
        # artifacts for shippable.
        print(f"[warn] selector kinds {offenders} exceed POD_MAX_SELECTOR_KIND="
              f"{ceiling}; X1b is ON, so these artifacts need R to raise the "
              "runtime ceiling before they can ship.")
        return
    raise SystemExit(
        f"selector kinds: emitted {offenders} (ceiling {ceiling}) while X1b is "
        "NOT in AVAILABLE_CAPABILITIES -- a high-kind program leaked into "
        f"{EFFECTS_PATH.name}. The effects catalog would fail to compile.")


EXPECTATIONS_PATH = (
    ROOT / "tests/ideology/generated/card_expectations.json")


def _expectation_scope(item: Prog) -> dict:
    """Where the program's effect lands, in the terms a test needs."""
    if item.target_domain == DOMAIN_COUNTRY:
        return {"scope": "country"}
    if item.target_domain == DOMAIN_FAMILY:
        return {
            "scope": "family",
            "selector": int(item.selector),
            "cap": int(item.selector_cap),
            "min_branches": int(item.selector_param1),
        }
    return {
        "scope": "cell",
        "tags": list(item.tags),
        "selector": int(item.selector),
        "radius": int(item.radius) if item.selector == SEL_TAG_SOURCE_COUNT else 0,
        "cap": int(item.cap) if item.selector == SEL_TAG_SOURCE_COUNT else 0,
        "per_source": round(float(item.per_source), 6)
            if item.selector == SEL_TAG_SOURCE_COUNT else 0.0,
    }


def _expectation_value(item: Prog, command: Cmd) -> dict:
    """One row's expected effect: exact for constants, direction+ceiling for ramps.

    A ramp's real magnitude is `per * min(metric, cap)`, which depends on a live
    metric and cannot be asserted as a number. A conditional program is the same
    problem in a different shape: whether it fires is a world question. Both are
    reported as `dynamic` with a direction and the ceiling they must never exceed.
    """
    is_dynamic = item.ramp is not None or bool(item.conds)
    modifier = command.modifier
    if command.value < 0.0 and not modifier.endswith((".cut", ".gain")):
        modifier += ".cut"
    direction = "down" if (
        modifier.endswith(".cut")
        or _is_downside(modifier, 1.0 + command.value)) else "up"
    if is_dynamic:
        if item.ramp is not None:
            ceiling = abs(item.ramp.per * item.ramp.cap)
        else:
            ceiling = abs(command.value)
        return {"kind": "dynamic", "direction": direction,
                "max": round(ceiling, 6)}
    if item.selector == SEL_TAG_SOURCE_COUNT:
        # The program value is the FULL stack; the runtime scales per cell, so the
        # ceiling is what a test can assert on a cell with >= cap sources.
        value = abs(item.per_source) * item.cap
        return {"kind": "dynamic", "direction": direction,
                "max": round(value, 6)}
    return {"kind": "constant", "value": round(command.value, 6)}


def build_card_expectations() -> str:
    """The acceptance table, as canonical JSON (stable across runs)."""
    entries = []
    for card in cards_to_emit():
        key, name = card[0], card[1]
        levels = LEVEL_ROWS.get(key, ())
        terms = _all_terms(key)
        for level_index in range(3):
            rows: list[dict] = []
            for item in (levels[level_index] if level_index < len(levels) else ()):
                for command in item.cmds:
                    row = {"stat": command.modifier}
                    row.update(_expectation_scope(item))
                    row.update(_expectation_value(item, command))
                    rows.append(row)
            # National per-level terms (LEVEL_TERMS) apply at their own level only.
            level_terms = LEVEL_TERMS.get(key)
            if level_terms and level_index < len(level_terms):
                for entry in level_terms[level_index]:
                    if isinstance(entry, RampTerm):
                        rows.append({
                            "stat": entry.stat, "scope": "country",
                            "kind": "dynamic",
                            "direction": "down",
                            "max": round(abs(entry.ramp.per * entry.ramp.cap), 6),
                        })
                        continue
                    stat, value = entry[0], entry[1]
                    # The expectation table must agree with the EMITTED operation, not
                    # with the tuple's shape. `_term_operation` is the single source of
                    # truth: an additive stat family is ADD even without a third tuple
                    # element, so `len(entry) > 2` here would label `satisfaction_bp`
                    # "multiply" and the smoke test would read base 1.0 and expect 401
                    # where the design says 400.
                    additive = _term_operation(entry) == 0
                    expected_value = 0.5 + value if stat == OPINION_FLOOR else value
                    row = {
                        "stat": stat, "scope": "country",
                        "kind": "constant",
                        "value": round(expected_value, 6),
                        "operation": "add" if additive else "multiply",
                    }
                    if stat == OPINION_FLOOR:
                        row["base"] = 0.5
                    rows.append(row)
            # A card whose whole price is the flat `CARDS` tuple: the runtime emits
            # ONE definition and scales it by LEVEL_MAGNITUDES = 1.0 / 1.6 / 2.2
            # (Q16: 65536 / 104858 / 144179). Measured on `fire_keeping`: cold 0.92
            # -> 0.872 at L2 = 1-(1-0.92)*1.6. Reporting the L1 number at every level
            # (which this did at first) made the smoke test fail on 84 term cards.
            if not levels and not level_terms and terms:
                magnitude = LEVEL_MAGNITUDES[level_index] / Q16
                for entry in terms:
                    if isinstance(entry, RampTerm):
                        rows.append({
                            "stat": entry.stat, "scope": "country",
                            "kind": "dynamic", "direction": "down",
                            "max": round(abs(entry.ramp.per * entry.ramp.cap), 6),
                        })
                        continue
                    stat, value = entry[0], entry[1]
                    # Same rule as the per-level branch above: the emitted operation
                    # decides, not the tuple's length. An additive stat is scaled
                    # linearly (value x magnitude) and a ratio is scaled around 1.0.
                    additive = _term_operation(entry) == 0
                    if additive:
                        scaled = value * magnitude
                    else:
                        scaled = 1.0 + (value - 1.0) * magnitude
                    expected_value = 0.5 + scaled if stat == OPINION_FLOOR else scaled
                    row = {
                        "stat": stat, "scope": "country", "kind": "constant",
                        "value": round(expected_value, 6),
                        "operation": "add" if additive else "multiply",
                        "level_magnitude": round(magnitude, 6),
                    }
                    if stat == OPINION_FLOOR:
                        row["base"] = 0.5
                    rows.append(row)
            entries.append({
                "card": key, "name": name, "level": level_index + 1,
                "rows": sorted(rows, key=lambda r: (r["stat"], r["scope"])),
            })

    payload = {
        "schema": 1,
        "note": ("由 generate_ideology_catalog.py 生成，勿手改。"
                 "constant = 精确断言；dynamic = 只断言方向与上限。"),
        "cards": entries,
    }
    return json.dumps(payload, ensure_ascii=False, indent=1, sort_keys=True) + "\n"


def write_card_expectations() -> None:
    EXPECTATIONS_PATH.parent.mkdir(parents=True, exist_ok=True)
    EXPECTATIONS_PATH.write_text(
        build_card_expectations(), encoding="utf-8", newline="\n")


# Matches 上限 +15% / 上限 -6% / 上限 +0.5% in a program summary.
_CEILING_RE = re.compile(r"上限\s*([+-]?)\s*(\d+(?:\.\d+)?)\s*%")


def ramp_ceiling_error(item: Prog) -> str:
    """Why a ramp's stated ceiling disagrees with `per * cap`, or "".

    The summary is what the player reads; `per * cap` is what the runtime does.
    A mismatch means the card grants something other than it advertises, and the
    two drifted independently because neither number is derived from the other.

    Tolerance is 0.1 percentage point, which absorbs rounding in the authored
    numbers (0.1333 x 1.5 = 19.995% for a stated +20%) without letting a real
    error through (0.15 x 1.5 = 22.5% vs a stated +15%).
    """
    if item.ramp is None:
        return ""
    match = _CEILING_RE.search(item.summary)
    if match is None:
        return ""
    sign = -1.0 if match.group(1) == "-" else 1.0
    stated = sign * float(match.group(2)) / 100.0
    actual = item.ramp.per * item.ramp.cap
    if abs(abs(actual) - abs(stated)) > 0.001 + 1e-9:
        return (f"{item.key}: summary says 上限 {match.group(1)}{match.group(2)}% "
                f"({stated:+.4f}) but per x cap = {actual:+.4f} "
                f"(per={item.ramp.per}, cap={item.ramp.cap})")
    return ""


def validate_ramp_ceilings() -> None:
    """Every ramp that advertises a ceiling must actually reach that ceiling."""
    problems: list[str] = []
    for item in DIAGNOSTIC_PROGRAMS + all_authored_card_programs():
        reason = ramp_ceiling_error(item)
        if reason:
            problems.append(reason)
    if problems:
        raise SystemExit("ramp ceilings:\n  " + "\n  ".join(problems))


def validate_programs() -> None:
    """Fail the generation on anything that would compile and then do nothing."""
    # P1-E: `STACK_ADD_STACK` together with a finite duration only means
    # something if an event can add a stack while the other stacks are still
    # alive. X4 (the event ring) does not exist, so the only rows that could
    # ever drive it are diagnostics that set the stack count themselves. A
    # timed ADD_STACK card would therefore ship as "stacks once, expires, never
    # counts again" -- silently weaker than authored, and invisible in review.
    for program in DIAGNOSTIC_PROGRAMS + list(all_authored_card_programs()):
        policy = getattr(program, "stack_policy", STACK_ADD_STACK)
        duration = getattr(program, "duration_days", -1)
        if policy == STACK_ADD_STACK and duration >= 0:
            raise SystemExit(
                "program %r: ADD_STACK needs an event entry to add stacks, "
                "and X4 does not exist; a finite duration makes the stack "
                "unreachable (use duration -1 until X4 lands)" % (
                    getattr(program, "key", "?"),))
    card_keys = {card[0] for card in CARDS}
    city_keys: set[str] = set()
    for suffix, _stat in IDEOLOGY_CITY_STATS:
        city_keys.add(city_stat_key(suffix))
        city_keys.add(city_stat_key(suffix, cut=True))
    country_keys: set[str] = set()
    for suffix, _stat, direction in IDEOLOGY_COUNTRY_STATS:
        cut = direction == "cut"
        country_keys.add(country_stat_key(suffix, cut=cut, gain=not cut))
    tag_names = known_tag_names()

    for key, meta in CARD_META.items():
        if key not in card_keys:
            raise SystemExit(f"meta: unknown card {key}")
        if meta.route and meta.route not in ROUTE_TAGS:
            raise SystemExit(f"meta: unknown route {meta.route} on {key}")
        if len(meta.secondary) > 2:
            raise SystemExit(f"meta: too many secondary routes on {key}")
        for tag in meta.secondary:
            if tag not in ROUTE_TAGS or tag == meta.route:
                raise SystemExit(f"meta: bad secondary route {tag} on {key}")

    for card_key, levels in LEVEL_ROWS.items():
        if card_key not in card_keys:
            raise SystemExit(f"rows: unknown card {card_key}")
        if len(levels) != 3:
            raise SystemExit(f"rows: {card_key} needs exactly 3 levels")
        authored = _all_terms(card_key)
        # Same definition of "a price" as `program_has_cut` below: a cost-direction
        # stat (need / consumption / burn) IS a price when it goes UP, so a bare
        # `value < 0` test would call `department_store`'s "需求 +10%" free.
        has_cut = any(
            command.value < 0.0
            or _is_downside(command.modifier, 1.0 + command.value)
            for level in levels for item in level for command in item.cmds)
        if not authored and not has_cut:
            raise SystemExit(f"rows: {card_key} has no cost term and no cut")
        # "Benefits live in programs, prices live in terms." A card whose numbers
        # are per-level national rows (LEVEL_TERMS) is not a program card: its
        # terms ARE the benefit, so the rule only applies to the CARDS tuple that
        # a program card still uses as its price row.
        if card_key not in LEVEL_TERMS:
            terms = _terms_of(next(card for card in CARDS if card[0] == card_key))
            for entry in terms:
                if not _satisfies_downside(entry):
                    raise SystemExit(
                        f"rows: {card_key} keeps a benefit term {entry[0]}={entry[1]}; "
                        "program cards must author benefits as programs only")
        for level_index, rows in enumerate(levels):
            for item in rows:
                if not item.summary.strip():
                    raise SystemExit(f"program: {item.key} has no summary")
                expected = f"{card_key}_l{level_index + 1}"
                if not item.key.startswith(expected):
                    raise SystemExit(
                        f"program: {item.key} must start with {expected} "
                        "(one program per card level, or the second one is dropped)")
        # A level with NEITHER national rows NOR a program would ship as an
        # empty level: the card would render with no effect at all on that tier.
        if card_key in LEVEL_TERMS:
            for level_index, rows in enumerate(levels):
                if not rows and not LEVEL_TERMS[card_key][level_index]:
                    raise SystemExit(
                        f"rows: {card_key} level {level_index + 1} is empty on "
                        "both the national and the program path")

    seen: set[str] = set()
    for item in DIAGNOSTIC_PROGRAMS + all_authored_card_programs():
        if item.key in seen:
            raise SystemExit(f"program: duplicate key {item.key}")
        seen.add(item.key)
        if not item.cmds:
            raise SystemExit(f"program: {item.key} emits no command")
        if item.selector < 0 or item.selector > SELECTOR_MAX_KIND:
            raise SystemExit(f"program: {item.key} has selector {item.selector}")
        if item.selector_cap < 0 or item.selector_cap > 32:
            raise SystemExit(f"program: {item.key} cap {item.selector_cap} out of 0..32")
        if len(item.tags) > 4:
            raise SystemExit(f"program: {item.key} has more than 4 tags")
        if len(set(item.tags)) != len(item.tags):
            raise SystemExit(f"program: {item.key} repeats a tag")
        if item.ramp is not None and len(item.cmds) != 1:
            raise SystemExit(
                f"program: {item.key} has a ramp and {len(item.cmds)} commands; "
                "a ramp applies to exactly one command")
        _validate_source_count_program(item, tag_names)
        if item.tags and item.selector not in (
                SEL_OWN_TERRITORY, SEL_TAG_ANY_CELL,
                SEL_TAG_SOURCE_R1, SEL_TAG_SOURCE_R2, SEL_TAG_SOURCE_COUNT):
            raise SystemExit(
                f"program: {item.key} uses tags with selector {item.selector}; "
                "only 12/13/14/15/16 read a tag")
        for tag in item.tags:
            validate_tag_expression(tag, tag_names, f"program: {item.key}")
        if item.stacks < 1 or item.stacks > 64:
            raise SystemExit(f"program: {item.key} bad stacks {item.stacks}")
        if item.stack_policy == STACK_ADD_STACK and item.max_stacks > 6:
            raise SystemExit(f"program: {item.key} keeps more than 6 layers")
        is_diagnostic = item.key.startswith("v") and item.key[1:2].isdigit()
        for command in item.cmds:
            key = command.modifier
            if command.value < 0.0 and not key.endswith((".cut", ".gain")):
                key = key + ".cut"
            if is_diagnostic:
                continue
            if item.target_domain == DOMAIN_COUNTRY:
                if key.startswith(IDEOLOGY_CITY_KEY_PREFIX) or key not in country_keys:
                    raise SystemExit(
                        f"program: {item.key} names {key}; DOMAIN_COUNTRY programs "
                        "must use an ideology.country.* definition (and never "
                        "ideology.city.*)")
                if command.domain != 1:
                    raise SystemExit(
                        f"program: {item.key} command domain is {command.domain}; "
                        "DOMAIN_COUNTRY programs must explicitly target Modifier "
                        "COUNTRY (domain=1)")
                if item.ramp is not None and item.ramp.metric.startswith("cell."):
                    raise SystemExit(
                        f"program: {item.key} is DOMAIN_COUNTRY but ramps on "
                        f"cell metric {item.ramp.metric}; use a country.* metric")
            elif item.target_domain == DOMAIN_FAMILY:
                if item.selector != SEL_FAMILY_OWNED:
                    raise SystemExit(
                        f"program: {item.key} targets FAMILY with selector "
                        f"{item.selector}; X9-b requires {SEL_FAMILY_OWNED}")
                if item.tags:
                    raise SystemExit(
                        f"program: {item.key} FAMILY targets cannot carry tags")
                if not 1 <= item.selector_cap <= 32:
                    raise SystemExit(
                        f"program: {item.key} FAMILY cap "
                        f"{item.selector_cap} must be 1..32")
                if item.selector_param1 < 1:
                    raise SystemExit(
                        f"program: {item.key} FAMILY min_branches must be >= 1")
                if not key.startswith(f"{IDEOLOGY_CITY_KEY_PREFIX}"):
                    if not key.startswith("economy.city.") or key not in city_keys:
                        raise SystemExit(
                            f"program: {item.key} names {key}; FAMILY programs "
                            "must use an economy.city.* stat")
                if command.domain != 2:
                    raise SystemExit(
                        f"program: {item.key} command domain is {command.domain}; "
                        "FAMILY programs must explicitly target Modifier "
                        "ECONOMY (domain=2)")
            elif item.target_domain in (DOMAIN_CELL, 5):
                if key.startswith(IDEOLOGY_COUNTRY_KEY_PREFIX) or key not in city_keys:
                    raise SystemExit(
                        f"program: {item.key} names {key}; cell-domain card "
                        "programs must use an ideology.city.* / economy.city.* "
                        "definition (and never ideology.country.*)")
            else:
                raise SystemExit(
                    f"program: {item.key} targets unsupported domain "
                    f"{item.target_domain}")


def validate_cards() -> None:
    """Fail loudly instead of emitting content that silently never draws or,
    worse, silently never does anything."""
    network = json.loads(NETWORK_PATH.read_text(encoding="utf-8"))
    eras = sorted(network.get("eras", []), key=lambda row: row.get("sort_order", 0))
    if len(eras) != len(ERA_MILESTONE_TECH):
        raise SystemExit("era table has %d rows, generator assumes %d"
                         % (len(eras), len(ERA_MILESTONE_TECH)))
    for index, era in enumerate(eras):
        milestone = str(era.get("milestone_id", ""))
        if milestone != ERA_MILESTONE_TECH[index]:
            raise SystemExit("era %d milestone drift: json=%r generator=%r"
                             % (index, milestone, ERA_MILESTONE_TECH[index]))
    technology_ids = {str(node.get("id", "")) for node in network.get("nodes", [])}
    signal_ids = _read_signal_ids()
    allowed_stats = allowed_stat_keys()
    seen: dict[str, int] = {}
    per_era = {index: 0 for index in range(len(ERA_MILESTONE_TECH))}
    gated = 0
    for key, name, school, rarity, era, exclusion, tech, signals, detail, _terms in CARDS:
        if key in seen:
            raise SystemExit("duplicate card key: %s" % key)
        seen[key] = 1
        if school not in SCHOOL_NAMES:
            raise SystemExit("card %s has unknown school %r" % (key, school))
        if rarity not in RARITY_WEIGHTS:
            raise SystemExit("card %s has unknown rarity %r" % (key, rarity))
        if not 0 <= era < len(ERA_MILESTONE_TECH):
            raise SystemExit("card %s has era %r outside the era table" % (key, era))
        per_era[era] += 1
        if tech and tech not in technology_ids:
            raise SystemExit("card %s requires unknown technology %r" % (key, tech))
        if tech in ERA_MILESTONE_TECH and ERA_MILESTONE_TECH.index(tech) > era:
            raise SystemExit("card %s is era %d but gated on the later %r"
                             % (key, era, tech))
        for signal in signals:
            if signal not in signal_ids:
                raise SystemExit("card %s requires unknown signal %r" % (key, signal))
        if signals:
            gated += 1
        # A program card may express its whole price as a cell-level cut inside
        # the program (coppice_rotation's "原木产出 -6%"). In that case it needs
        # neither a modifier term nor a cost stat -- but it MUST actually carry a
        # price, otherwise the card is free.
        #
        # "A price" is not always `value < 0`: on a cost-direction stat (housing /
        # consumption demand, resource burn, hazard loss) the price is a POSITIVE
        # value. `land_value`'s "这些地块住房需求 +5%" is exactly that, so the test
        # goes through `_is_downside` rather than comparing the raw sign.
        program_rows = LEVEL_ROWS.get(key, ())
        program_has_cut = any(
            command.value < 0.0
            or _is_downside(command.modifier, 1.0 + command.value)
            for level in program_rows for item in level for command in item.cmds)
        if not _all_terms(key) and not program_has_cut:
            raise SystemExit("card %s has no modifier terms" % key)
        # Every term source has to clear the same two lints: the stat must be one
        # the Modifier catalog actually declares, and at least one source must be
        # a real downside. `_all_terms` is what makes the per-level table
        # (`LEVEL_TERMS`) subject to the identical rules as the CARDS tuple --
        # otherwise a card could move its numbers into the new table and skip the
        # only check that notices a dead stat key.
        all_terms = list(_all_terms(key))
        # A card STAGED on a missing capability may name stats that capability will
        # declare (X16's two families do not exist yet). Its terms are still checked
        # for V1 / dead keys / clamp-direction, but "the Modifier catalog does not
        # declare it" is expected and must not fail generation -- otherwise the
        # authoring cannot land before the C++ side does.
        staged_needs = tuple(n for n in CARD_REQUIRES.get(key, ())
                             if n not in AVAILABLE_CAPABILITIES)
        allow_undeclared = bool(staged_needs)
        has_cost = False
        for entry in all_terms:
            stat = _term_stat(entry)
            # V1 (§47.2): a player lever is never valid content, on any card.
            lever = _player_lever_reason(stat)
            if lever:
                raise SystemExit("card %s: %s" % (key, lever))
            # Operation must be one the Modifier catalog allows for this stat.
            #
            # `modifier_catalog.gd` declares a per-family `allowed_operations` mask and
            # rejects the whole catalog (`modifier_term_domain_or_operation_invalid`) on
            # one mismatch -- so a term the runtime will refuse must never be emitted.
            # This caught nothing in the past only because the generator and the catalog
            # agreed by accident; they did not for `satisfaction_bp` (ADD-only stat
            # authored as MULTIPLY), and the result was that NO world could generate.
            if not isinstance(entry, RampTerm):
                emitted_operation = _term_operation(entry)
                allowed_mask = _allowed_operations_for(stat)
                if (allowed_mask & (1 << emitted_operation)) == 0:
                    raise SystemExit(
                        "card %s: term %r would be emitted with operation %d, but that "
                        "stat only allows operations mask %d (ADD=1, SUB=2, MUL=4, "
                        "DIV=8). Fix the term's operation; emitting it would break the "
                        "whole Modifier catalog at compile time."
                        % (key, stat, emitted_operation, allowed_mask))
            # A `RampTerm` cannot ride a Modifier definition (see `add()`), so it
            # MUST belong to a card that is staged on the metric it ramps. Checking
            # that here is what stops a published card from silently losing its
            # third clause the moment someone adds a ramp to it.
            if isinstance(entry, RampTerm) and not allow_undeclared:
                raise SystemExit(
                    "card %s has a RampTerm on %r, but the card is published; a "
                    "ramp needs an Effect program row and the card must be staged "
                    "on the metric it reads (%s)" % (key, stat, entry.ramp.metric))
            if stat in DEAD_STAT_KEYS:
                raise SystemExit(
                    "card %s uses dead stat %r; nothing consumes it" % (key, stat))
            if stat not in allowed_stats and not allow_undeclared:
                raise SystemExit(
                    "card %s uses stat %r that the modifier catalog never declares"
                    % (key, stat))
            # Cost stats invert: a bigger resource burn or hazard loss is bad,
            # so >1.0 is the downside there and <1.0 is the downside elsewhere.
            if _satisfies_downside(entry):
                has_cost = True
            # V3 (§47.2): a term aimed at a stat the runtime clamps cannot move it,
            # so the card prints a price it never charges. This applies to EVERY
            # card -- the C0-only scope it had in the previous round let
            # `land_reclamation` and `agricultural_chemistry` ship a no-op price
            # (§47.7 fixed both).
            clamped = _clamped_noop_reason(entry)
            if clamped:
                raise SystemExit("card %s: %s" % (key, clamped))
        if not has_cost and not program_has_cut:
            raise SystemExit(
                "card %s has no downside term; a card with only buffs flattens the pool"
                % key)
    coverage: dict[str, int] = {}
    for unknown in sorted(set(LEVEL_TERMS) - set(seen)):
        raise SystemExit("terms: unknown card %s" % unknown)
    for key, levels in LEVEL_ON_ENTER_EFFECTS.items():
        if key not in seen:
            raise SystemExit("on-enter: unknown card %s" % key)
        if len(levels) != 3:
            raise SystemExit("on-enter: %s needs exactly 3 levels" % key)
        for level_index, rows in enumerate(levels):
            for row in rows:
                if key != "civil_examination" or level_index != 2:
                    raise SystemExit(
                        "on-enter: only civil_examination L3 is authorized")
                if row.get("action") != 6 or row.get("domain") != 6 \
                        or row.get("opcode") != 3:
                    raise SystemExit(
                        "on-enter: %s must use native free-draw adapter" % key)
                count = int(row.get("value_q16", 0))
                if count <= 0 or count > 65535:
                    raise SystemExit(
                        "on-enter: %s free-draw count out of range" % key)
                if not str(row.get("command_key", "")) \
                        or not str(row.get("definition_key", "")):
                    raise SystemExit(
                        "on-enter: %s needs command and definition keys" % key)
    # `ADD_TERMS` keys are authoring labels of the shape `<card>_l<level>` (a few
    # cards reuse one table), so they are not card ids and must not be validated
    # against `CARDS`. What must hold is that each one belongs to a card that
    # actually declares per-level terms -- an orphan table is dead authoring.
    for table_key in sorted(set(ADD_TERMS) - set(LEVEL_TERMS)):
        owner = table_key.rsplit("_l", 1)[0]
        if owner not in LEVEL_TERMS:
            raise SystemExit(
                "add-terms: %s belongs to no card with LEVEL_TERMS" % table_key)
    for key, levels in LEVEL_TERMS.items():
        if len(levels) != 3:
            raise SystemExit("terms: %s needs exactly 3 levels" % key)
        for level in levels:
            if not level:
                raise SystemExit("terms: %s has an empty level" % key)
        # A card whose numbers live here must ALSO carry an empty term list in
        # `CARDS`. The emitter builds one definition from the tuple ("the price,
        # at magnitude 1.0 on every level") and one per level from this table;
        # leaving the tuple populated emits a second definition over the same
        # stats, and the duplicate copy is a MULTIPLY where the level row is an
        # ADD (or the reverse), so the two silently disagree about the same stat.
        entry_terms = _terms_of(next(card for card in CARDS if card[0] == key))
        if entry_terms:
            raise SystemExit(
                "terms: %s authors LEVEL_TERMS but CARDS still has terms %r; "
                "move them into LEVEL_TERMS and leave the tuple empty"
                % (key, entry_terms))
    for row in CARDS:
        kinds = {object_kind(_term_stat(entry)) for entry in _all_terms(row[0])}
        for kind in kinds:
            coverage[kind] = coverage.get(kind, 0) + 1
    order = ["geography", "good", "resource", "climate", "tax", "building",
             "sector", "national"]
    label = {"geography": "地形地貌", "good": "物资", "resource": "资源存量",
             "climate": "气候", "tax": "税负", "building": "建筑",
             "sector": "部门", "national": "全国标量"}
    print("cards=%d  带地理信号门槛=%d" % (len(CARDS), gated))
    print("对象覆盖:", "  ".join("%s=%d" % (label[k], coverage.get(k, 0))
                                 for k in order))
    print("eras:", ", ".join(
        "%d:%s=%d" % (index, ERA_NAMES[index], per_era[index])
        for index in range(len(ERA_MILESTONE_TECH))))
    for synergy_key, _synergy_name, cards, terms in NAMED_SYNERGIES:
        if len(cards) < 2:
            raise SystemExit("synergy %s needs at least two cards" % synergy_key)
        for card_key in cards:
            if card_key not in seen:
                raise SystemExit("synergy %s references unknown card %r"
                                 % (synergy_key, card_key))
        if not terms:
            raise SystemExit("synergy %s has no modifier terms" % synergy_key)
    for entry in list(NAMED_SYNERGIES) + [
            (f"resonance.{school}.{count}", "", [], terms)
            for school in SCHOOL_ORDER
            for count, terms in zip((2, 4), RESONANCES[school])]:
        key, _name, _cards, terms = entry[0], entry[1], entry[2], entry[3]
        for stat, _value in terms:
            if stat in DEAD_STAT_KEYS:
                raise SystemExit("%s uses dead stat %r" % (key, stat))
            if stat not in allowed_stats:
                raise SystemExit("%s uses undeclared stat %r" % (key, stat))


def validate_requires() -> None:
    """Every `requires=` name must be known, and `CARD_REQUIRES` keys must be cards.

    A typo in a capability name would otherwise read as "not available" and stage
    the card silently, or as "available" once someone adds a similarly-named
    capability, and in both cases the card would ship without its engine support.
    """
    card_keys = {card[0] for card in CARDS}
    # Every card whose release is gated on an X1 switch gets that switch derived,
    # never authored. Two different switches, because they need different work:
    #
    #   * a kind-16 (per-source count) program  -> `X1b`         (needs new C++)
    #   * any other per-cell rewrite            -> `X1_PLAIN_SWITCH` (needs nothing)
    #
    # Deriving it means a card cannot forget its gate, and cannot declare a gate
    # without the programs that justify it.
    for key in card_keys:
        programs = [item for level in LEVEL_ROWS.get(key, ()) for item in level]
        # A kind-16 authoring error must fail here, before "no program uses the
        # selector" can silently omit the engine gate. `validate_programs` runs
        # after this function, so relying on it alone would leave a short window
        # where this derivation sees nothing to gate.
        for item in programs:
            if item.selector == SEL_TAG_SOURCE_COUNT:
                _validate_source_count_program(item, known_tag_names())
        target_programs = [item for level in X1_TARGETS.get(key, ())
                           for item in level]
        authored_programs = target_programs or programs
        if any(item.selector == SEL_TAG_SOURCE_COUNT
               for item in authored_programs):
            switch = "X1b"
        elif key in X1_TARGETS or key in X1_NATIONAL_TERMS:
            switch = X1_PLAIN_SWITCH
        else:
            continue
        if key in X1_BRAND_NEW:
            # A brand-new card has no old version to fall back on: its X1 form IS
            # the card. But it still needs the RIGHT switch -- a brand-new kind-16
            # card is gated on X1b, and a brand-new plain-card is gated on
            # X1_PLAIN_SWITCH. Skipping them would publish a card whose only
            # definition the engine cannot run.
            pass
        existing = CARD_REQUIRES.get(key, ())
        if switch not in existing:
            CARD_REQUIRES[key] = tuple(existing) + (switch,)
    for key, needs in CARD_REQUIRES.items():
        if key not in card_keys:
            raise SystemExit(f"requires: unknown card {key}")
        for name in needs:
            if name not in KNOWN_CAPABILITIES:
                raise SystemExit(
                    f"requires: card {key} names unknown capability {name!r}; "
                    "add it to KNOWN_CAPABILITIES (and AVAILABLE_CAPABILITIES "
                    "once the runtime supports it)")
    for key, reason in TEMPORARY_CARD_POOL_HOLDOUTS.items():
        if key not in card_keys:
            raise SystemExit(f"pool-holdout: unknown card {key}")
        if not reason.strip():
            raise SystemExit(f"pool-holdout: card {key} has no reason")


def validate_copy_flags() -> None:
    """X6-c content invariants for `copy_left_programs` / `copyable`."""
    if "X6c" not in CARD_REQUIRES.get("algorithmic_governance", ()):
        raise SystemExit(
            "copy flags: algorithmic_governance must require X6c")
    for key, _name, _school, rarity, _era, _exclusion, _tech, _signals, \
            _detail, _terms in CARDS:
        copyable = rarity != 3
        if rarity == 3 and copyable:
            raise SystemExit(f"copy flags: legendary card {key} must be noncopyable")
        if rarity != 3 and not copyable:
            raise SystemExit(f"copy flags: nonlegendary card {key} must be copyable")


def _card_has_existing_definition(key: str) -> bool:
    """True when this card already ships something, before any X1 target.

    "Ships something" means EITHER a per-level program table (`LEVEL_ROWS`) OR a
    non-empty national term list in the `CARDS` tuple. Both are real publication
    paths, and testing only `LEVEL_ROWS` is how the first attempt broke
    `colonial_plantation`: it publishes its benefit as CARDS terms, so it looked
    "new" and its target was merged -- which turned it into a program card and
    made its own benefit terms illegal.
    """
    if LEVEL_ROWS.get(key):
        return True
    return bool(_terms_of(next(card for card in CARDS if card[0] == key)))


# The 10 C-c cards that shipped no definition before this round, plus X8's new
# bronze_casting. They are listed explicitly rather than inferred: every one of
# them now carries a cost term in `CARDS`, so "has terms" can no longer tell a new
# card from an old one -- and getting that wrong either publishes a card the
# engine cannot run or silently drops one that was already live.
X1_BRAND_NEW = frozenset({
    "communal_feast", "department_store", "welfare_state", "suburbanization",
    "offshore_drilling", "supermarket", "gig_economy", "arcology", "basic_income",
    "circular_economy", "bronze_casting",
})

# Cards introduced by X5. They already carry a price term in `CARDS`, so the
# X1 brand-new heuristic above cannot distinguish them from cards whose old
# national row must keep shipping. Until X5 is available these two have no
# published definition at all; allowing their program rows through would ship a
# live card whose selector rewrite does not exist yet.
X5_BRAND_NEW = frozenset({"vertical_farm", "space_mining"})


def _switch_ready(switch: str) -> bool:
    return switch in AVAILABLE_CAPABILITIES


def x1_card_ready(key: str) -> bool:
    """Whether this card's authored X1 form may replace its old definition.

    `X1b` is a runtime capability, not a blanket content release. `X1B_RELEASE`
    is the explicit content allowlist; step 6 lists every authored kind-16 card.
    """
    switch = x1_card_switch(key)
    if switch == "X1b" and key not in X1B_RELEASE:
        return False
    if switch == X1_PLAIN_SWITCH and key not in X1_PLAIN_RELEASE:
        return False
    return _switch_ready(switch)


def authored_source_count_cards() -> set[str]:
    """Every card whose authored form contains a kind-16 program."""
    out: set[str] = set()
    for card in CARDS:
        key = card[0]
        programs = [item for level in X1_TARGETS.get(key, ()) for item in level]
        programs += [item for level in LEVEL_ROWS.get(key, ()) for item in level]
        if any(item.selector == SEL_TAG_SOURCE_COUNT for item in programs):
            out.add(key)
    return out


def validate_x1b_release() -> None:
    """The content allowlist must exactly match the authored kind-16 cards.

    A missing member silently leaves one card on its old row even though the
    shared X1b capability is on. An extra member is just as bad: it claims the
    release covers a card that has no kind-16 form, which makes the release
    report misleading and lets a later selector change slip through unnoticed.
    """
    authored = authored_source_count_cards()
    missing = sorted(authored - X1B_RELEASE)
    extra = sorted(X1B_RELEASE - authored)
    if missing or extra:
        details = []
        if missing:
            details.append("missing " + ", ".join(missing))
        if extra:
            details.append("extra " + ", ".join(extra))
        raise SystemExit("X1B_RELEASE mismatch: " + "; ".join(details))


def _published_match_tags() -> set[str]:
    """Single tag selectors of PUBLISHED target programs.

    The native TAG rewrite indexes one exact `target_selector_param[1]` id. A
    program whose selector is an AND (`target_selector_tags` has more than one
    name) has a synthetic id that no atom rewrite can name, so it must not make
    its member tags look matchable.
    """
    # `validate_rewrites()` runs before `main()` assigns `_PUBLISHED`, so
    # `cards_to_emit()` would still mean "all authored cards" here. Compute the
    # publication set the same way main() will, otherwise a rewrite whose only
    # match lives on a staged card passes validation.
    published_keys = {card[0] for card in published_cards()}
    tags: set[str] = set()
    for key in published_keys:
        for level in LEVEL_ROWS.get(key, ()):
            for item in level:
                if item.selector not in (
                        SEL_OWN_TERRITORY, SEL_TAG_ANY_CELL,
                        SEL_TAG_SOURCE_R1, SEL_TAG_SOURCE_R2,
                        SEL_TAG_SOURCE_COUNT):
                    continue
                if len(item.tags) == 1:
                    tags.add(item.tags[0])
    return tags


def _published_route_programs(route: str,
                              selector_kind: int | None = None) -> list[Prog]:
    """Published programs of `route` eligible for a PROGRAM expansion."""
    published_keys = {card[0] for card in published_cards()}
    out: list[Prog] = []
    for key in published_keys:
        meta = CARD_META.get(key)
        if meta is None or meta.route != route:
            continue
        for level in LEVEL_ROWS.get(key, ()):
            for item in level:
                if (selector_kind is None or item.selector == selector_kind) \
                        and len(item.tags) == 1:
                    out.append(item)
    return out


def _selector_tag_names(item: Prog) -> list[str]:
    if item.selector not in (
            SEL_OWN_TERRITORY, SEL_TAG_ANY_CELL,
            SEL_TAG_SOURCE_R1, SEL_TAG_SOURCE_R2,
            SEL_TAG_SOURCE_COUNT):
        return []
    return [tag for tag in item.tags if tag]


def validate_rewrites() -> None:
    """Hard-fail the X5 rows that would compile into a rule nothing can match."""
    known_tags = known_tag_names()
    card_keys = {card[0] for card in CARDS}
    published_tags = _published_match_tags()
    authored_programs = {item.key: item
                         for item in all_authored_card_programs()}
    published_programs = {
        item.key: item for item in all_card_programs()}
    for key in LEVEL_REWRITES:
        if key not in card_keys:
            raise SystemExit(f"rewrites: unknown card {key}")
        if len(LEVEL_REWRITES[key]) != 3:
            raise SystemExit(f"rewrites: {key} needs exactly 3 levels")
    for key, levels in LEVEL_REWRITES.items():
        for level_index, rows in enumerate(levels):
            for row in rows:
                if row.field not in (
                        REWRITE_SCALE, REWRITE_TAG,
                        REWRITE_SELECTOR_KIND, REWRITE_SELECTOR_CAP):
                    raise SystemExit(
                        f"rewrites: {key} L{level_index + 1} has field {row.field}")
                match_kind = row.match_kind()
                if match_kind == MATCH_TAG:
                    if is_synthetic_tag(row.match_tag):
                        validate_tag_expression(
                            row.match_tag, known_tags,
                            f"rewrites: {key} L{level_index + 1}")
                    elif row.match_tag not in known_tags:
                        raise SystemExit(
                            f"rewrites: {key} L{level_index + 1} matches unknown "
                            f"tag {row.match_tag!r}")
                    if row.match_tag not in published_tags:
                        raise SystemExit(
                            f"rewrites: {key} L{level_index + 1} matches "
                            f"{row.match_tag!r}, used only by staged/unemitted "
                            "programs")
                elif match_kind == MATCH_ROUTE:
                    if row.match_route not in ROUTE_TAGS:
                        raise SystemExit(
                            f"rewrites: {key} L{level_index + 1} names unknown "
                            f"route {row.match_route!r}")
                else:
                    if row.match_program not in {
                            item.key for item in all_authored_card_programs()}:
                        raise SystemExit(
                            f"rewrites: {key} L{level_index + 1} names unknown "
                            f"program {row.match_program!r}")
                    if row.field == REWRITE_TAG:
                        source = authored_programs.get(row.match_program)
                        names = _selector_tag_names(source) \
                            if source is not None else []
                        if len(names) != 1:
                            raise SystemExit(
                                f"rewrites: {key} L{level_index + 1} TAG rewrite "
                                f"targets {row.match_program!r}, which is not a "
                                "single-tag selector program")
                if row.field == REWRITE_TAG:
                    if not row.tag:
                        raise SystemExit(
                            f"rewrites: {key} L{level_index + 1} has an empty tag")
                    members = [name.strip() for name in row.tag.split("|")
                               if name.strip()]
                    if not members:
                        raise SystemExit(
                            f"rewrites: {key} L{level_index + 1} has an empty tag")
                    if len(set(members)) != len(members):
                        raise SystemExit(
                            f"rewrites: {key} L{level_index + 1} repeats a tag")
                    for member in members:
                        if member not in known_tags:
                            raise SystemExit(
                                f"rewrites: {key} L{level_index + 1} names unknown "
                                f"replacement tag {member!r}")
                    # A TAG rewrite only makes sense on a single-tag selector.
                    # MATCH_PROGRAM was checked above and MATCH_TAG's match set
                    # is single-tag by construction; a route expands to several
                    # programs, so every expansion must be safe too.
                    if match_kind == MATCH_ROUTE:
                        for item in _published_route_programs(
                                row.match_route):
                            if len(_selector_tag_names(item)) > 1:
                                raise SystemExit(
                                    f"rewrites: {key} L{level_index + 1} route "
                                    f"{row.match_route!r} expands to AND-selector "
                                    f"program {item.key!r}; TAG rewrites require "
                                    "one tag")
                else:
                    if row.tag:
                        raise SystemExit(
                            f"rewrites: {key} L{level_index + 1} sets tag on a "
                            "non-TAG rewrite")
                if row.field == REWRITE_SELECTOR_KIND:
                    if row.value not in (SEL_NEIGHBORS_R1, SEL_NEIGHBORS_R2,
                                         SEL_TAG_SOURCE_R1, SEL_TAG_SOURCE_R2):
                        raise SystemExit(
                            f"rewrites: {key} L{level_index + 1} selector kind "
                            f"{row.value} is outside the radial pairs")
                if row.field == REWRITE_SELECTOR_CAP:
                    if not 1 <= row.value <= 32:
                        raise SystemExit(
                            f"rewrites: {key} L{level_index + 1} cap {row.value} "
                            "is outside 1..32")
                if match_kind == MATCH_ROUTE and row.field == \
                        REWRITE_SELECTOR_KIND:
                    # Route rewrites only flip between the two source radii.
                    source_kind = SEL_TAG_SOURCE_R1 if row.value == \
                        SEL_TAG_SOURCE_R2 else SEL_TAG_SOURCE_R2
                    if not _published_route_programs(
                            row.match_route, source_kind):
                        raise SystemExit(
                            f"rewrites: {key} L{level_index + 1} route "
                            f"{row.match_route!r} has no published kind-"
                            f"{source_kind} program (X5 cannot fabricate one)")
def x1_card_switch(key: str) -> str:
    """Which X1 switch releases this card: `X1b` for kind-16, else plain.

    Reads `X1_TARGETS`, NOT `LEVEL_ROWS`: for a card whose rewrite has not been
    merged yet, `LEVEL_ROWS` still holds the OLD program row (which by definition
    has no kind 16), so looking there classified all 23 rewrites as "plain" and
    hid the six that actually need R's C++.
    """
    programs = []
    if key in X1_TARGETS:
        programs = [item for level in X1_TARGETS[key] for item in level]
    else:
        programs = [item for level in LEVEL_ROWS.get(key, ()) for item in level]
    if any(item.selector == SEL_TAG_SOURCE_COUNT for item in programs):
        return "X1b"
    return X1_PLAIN_SWITCH


def merge_x1_targets() -> None:
    """Decide, per card, whether the X1 (v1) form replaces the published row.

    The X1 rewrite ships through TWO independent switches (C-d):

      * `X1_PLAIN_SWITCH` -- per-cell targeting with selectors that already exist.
      * `X1b`             -- per-source COUNT stacking (kind 16), needs new C++.

    For each card, independently:

    1. **its switch and content allowlist are available** -> the target REPLACES
       `LEVEL_ROWS[card]`, and the card's `CARDS` benefit terms are dropped (a
       program card may only carry prices; `validate_cards` enforces it).
    2. **its switch is unavailable + card is brand new** -> the target still becomes
       `LEVEL_ROWS[card]`, so it is validated in full and picks up its derived
       switch requirement, which keeps it out of the catalog.
    3. **its switch is unavailable + card already ships something** -> LEAVE IT
       ALONE. The old version keeps publishing unchanged. Merging here would change
       the card's behaviour before the engine can run it, or turn a term-based card
       into a program card and make its own benefit terms illegal.
    """
    for key, levels in X1_TARGETS.items():
        if x1_card_ready_for_build(key) or key in X1_BRAND_NEW:
            LEVEL_ROWS[key] = levels
    for key in X1_BRAND_NEW:
        if key not in X1_TARGETS:
            raise SystemExit(f"x1: {key} is marked brand new but has no X1 target")
    _merge_national_targets()

    # Drop the national benefit terms only for the cards that actually switched.
    for index, card in enumerate(CARDS):
        key = card[0]
        if key not in X1_TARGETS:
            continue
        if key in X1_BRAND_NEW:
            continue  # no old national row to clean up
        if not x1_card_ready_for_build(key):
            continue  # card still publishes its old row; keep its terms
        kept = [t for t in card[9] if _satisfies_downside(t)]
        dropped = len(card[9]) - len(kept)
        if dropped:
            print(f"x1 切换 {key}: 移除 {dropped} 条国家级收益项，"
                  f"保留 {len(kept)} 条代价项")
        CARDS[index] = card[:9] + (kept,)


def validate_x1_targets() -> None:
    """Validate every X1 target even when it is not the row being emitted.

    A staged v1 form that is never exercised is exactly where a typo survives for
    months: the card publishes the OLD row, so nothing about the target reaches the
    catalog and no lint sees it. These checks are the only thing standing between
    "authored" and "authored correctly".

    Stat keys are validated at authoring time by `city_stat_key` itself (it hard-
    fails on an unknown suffix), so what is checked here is everything else.
    """
    card_keys = {card[0] for card in CARDS}
    tags = known_tag_names()
    for key, levels in X1_TARGETS.items():
        if key not in card_keys:
            raise SystemExit(f"x1: unknown card {key}")
        if len(levels) != 3:
            raise SystemExit(f"x1: {key} needs exactly 3 levels")
        for level_index, rows in enumerate(levels):
            if not rows:
                raise SystemExit(
                    f"x1: {key} level {level_index + 1} is empty; a level that "
                    "grants nothing is a level the player pays nothing for")
            for item in rows:
                if not item.summary.strip():
                    raise SystemExit(f"x1: {item.key} has no summary")
                expected = f"{key}_l{level_index + 1}"
                if not item.key.startswith(expected):
                    raise SystemExit(
                        f"x1: {item.key} must start with {expected}")
                if not item.cmds:
                    raise SystemExit(f"x1: {item.key} emits no command")
                _validate_source_count_program(item, tags)
                for tag in item.tags:
                    validate_tag_expression(tag, tags, f"x1: {item.key}")


def _publishes_old_definition(key: str) -> bool:
    """True when this card still ships content that is NOT its gated X1 rewrite.

    Order matters, and each step answers for a different group:

      1. `X1_BRAND_NEW` -- brand new this round; the X1 form is the whole card, so
         nothing ships until its switch is on. (Skipping this step is how
         `communal_feast` / `supermarket` briefly published their kind-16
         programs: they DO carry a CARDS cost term, so step 2 claimed them.)
      2. `CARDS` terms -- the old flat national row; it keeps shipping whether or
         not the rewrite switch is on. This is what keeps the 23 rewrites live.
      3. a country program with any `requires=` unavailable -- gated; nothing
         ships. Country ramps are complete Effect rows and must not publish
         without every capability they name.
      4. no `requires=` available -- gated; nothing ships. The existing X16 group.
      5. otherwise -- ships its `LEVEL_ROWS` / `LEVEL_TERMS` row (the older program
         cards such as `terrace_farming` and `water_works`).

    Earlier attempts asked "does this look like old content?" by SHAPE and each
    failed differently: two leaked `economy.profession.*` terms into the Modifier
    catalog (breaking it with `modifier_term_invalid`), one dropped 16 live
    rewrites, one published kind-16 programs. The order above has one right answer
    for every card in the catalog.
    """
    if key in X1_BRAND_NEW or key in X5_BRAND_NEW:
        return False
    # A `RampTerm` is an Effect instruction sequence and CANNOT ride a Modifier
    # definition: `modifier_blocks.add()` skips it. So a card whose level terms carry
    # a ramp and whose ONLY carrier would be that definition loses a whole clause --
    # it would publish as a half-card without anything failing.
    #
    # Measured on `progressive_tax` after `X16` landed: L1 emitted 11 tolerance terms
    # and silently dropped the 12th (the death-rate ramp), because the card reached the
    # `LEVEL_TERMS` branch below. The card is gated on `reserve_ratio` for exactly this
    # reason, so report it as gated rather than shipping the partial row.
    if any(isinstance(entry, RampTerm)
           for level in LEVEL_TERMS.get(key, []) for entry in level):
        return False
    requires = CARD_REQUIRES.get(key, ())
    country_programs = [
        item for level in LEVEL_ROWS.get(key, ()) for item in level
        if item.target_domain == DOMAIN_COUNTRY
    ]
    if country_programs and any(
            name not in AVAILABLE_CAPABILITIES for name in requires):
        return False
    if _terms_of(next(c for c in CARDS if c[0] == key)):
        return True
    if requires and not any(name in AVAILABLE_CAPABILITIES for name in requires):
        return False
    if LEVEL_TERMS.get(key):
        return True
    rows = LEVEL_ROWS.get(key)
    return bool(rows) and any(rows)


def staged_cards() -> list[tuple[str, tuple[str, ...]]]:
    """Cards held out of the catalog, with the capabilities they are waiting for.

    Returns the blockers only (the missing subset), not everything the card asked
    for, so the printed list says exactly what is holding each card back.

    A card that still publishes an OLD definition is NOT staged when only its X1
    REWRITE is switched off -- the old row keeps shipping, which is the whole point
    of splitting the switches. Those are reported by `pending_x1_rewrites()` so the
    state stays visible without claiming a live card is missing.
    """
    out: list[tuple[str, tuple[str, ...]]] = []
    for key, needs in sorted(CARD_REQUIRES.items()):
        if key in _x1_force_ready_cards():
            continue
        missing = tuple(n for n in needs if n not in AVAILABLE_CAPABILITIES)
        if not missing:
            continue
        if _publishes_old_definition(key):
            continue
        out.append((key, missing))
    return out


def pending_x1_rewrites() -> list[tuple[str, str]]:
    """(card, switch) for cards whose X1 rewrite is authored but switched off."""
    out: list[tuple[str, str]] = []
    for key in X1_TARGETS:
        if not x1_card_ready(key):
            out.append((key, x1_card_switch(key)))
    for key in X1_NATIONAL_TERMS:
        if X1_PLAIN_SWITCH not in AVAILABLE_CAPABILITIES:
            out.append((key, X1_PLAIN_SWITCH))
    return sorted(out)


def published_cards() -> list:
    """`CARDS` minus the staged ones -- what actually goes into the catalog."""
    staged = {key for key, _ in staged_cards()}
    # A brand-new kind-16 card whose row was merged for validation must not become
    # publishable merely because the runtime capability exists. Its content stays
    # dark until the step-6 release allowlist names it.
    unreleased = {
        key for key in X1_BRAND_NEW
        if not x1_card_ready_for_build(key)
    }
    held_out = set(TEMPORARY_CARD_POOL_HOLDOUTS)
    return [card for card in CARDS
            if card[0] not in staged and card[0] not in unreleased
            and card[0] not in held_out]


def published_route_member_counts() -> dict[str, int]:
    """Route memberships after every publication gate has been applied."""
    counts: dict[str, int] = {}
    for key, _name, _school, _rarity, _era, _exclusion, _tech, _signals, \
            _detail, _terms in cards_to_emit():
        meta = CARD_META.get(key)
        if meta is None:
            continue
        for route in (meta.route, *meta.secondary):
            if route:
                counts[route] = counts.get(route, 0) + 1
    return counts


def published_route_bonds() -> list[tuple[str, int, list]]:
    """Only route tiers that the published roster can actually reach."""
    counts = published_route_member_counts()
    out: list[tuple[str, int, list]] = []
    for route, (_display, tier1, tier2) in ROUTE_BONDS.items():
        for count, terms in ((2, tier1), (4, tier2)):
            if terms is not None and counts.get(route, 0) >= count:
                out.append((route, count, terms))
    return out


def validate_published_synergies() -> None:
    """Every emitted named synergy and route tier must be reachable."""
    published = {card[0] for card in cards_to_emit()}
    for key, _name, cards, _terms in NAMED_SYNERGIES:
        missing = [card for card in cards if card not in published]
        if missing:
            raise SystemExit(
                "published synergy %s references held-out cards %s"
                % (key, ", ".join(missing)))
    counts = published_route_member_counts()
    for route, (_display, tier1, tier2) in ROUTE_BONDS.items():
        members = counts.get(route, 0)
        for count, terms in ((2, tier1), (4, tier2)):
            if terms is not None and members < count:
                raise SystemExit(
                    "published route bond %s.%d needs %d members, found %d"
                    % (route, count, count, members))
    for school, tiers in RESONANCES.items():
        members = sum(1 for card in cards_to_emit() if card[2] == school)
        for count, terms in zip((2, 4), tiers):
            if terms is not None and members < count:
                raise SystemExit(
                    "published resonance %s.%d needs %d members, found %d"
                    % (school, count, count, members))


# Set by `main()` after validation, read by the three emitters. Module-level (and
# defaulting to "everything") so importing this file never hides cards from a
# caller that just wants the tables.
_PUBLISHED: list | None = None


def cards_to_emit() -> list:
    """The card rows the emitters may write: all of them unless `main()` staged some."""
    return CARDS if _PUBLISHED is None else _PUBLISHED


def _build_x8_tables() -> None:
    """Author X8 in the data-file pass: the chain reader follows this section."""
    CARD_META["bronze_casting"] = Meta(route="mining")
    _x1("bronze_casting", [
        [prog("bronze_casting_l1",
              "铜矿或锡矿周围 1 格（每源 +15%，最多 2 源 = +30%）：工业产出 +30%",
              selector=SEL_TAG_SOURCE_COUNT, radius=1, cap=2,
              per_source=cell(15),
              tags=(x8_upstream_tag("bronze_tools"),),
              cmds=(mod(city_stat_key("building.manufacturing_output_factor"),
                        0.0),))],
        [prog("bronze_casting_l2",
              "铜矿或锡矿周围 1 格（每源 +20%，最多 2 源 = +40%）：工业产出 +40%",
              selector=SEL_TAG_SOURCE_COUNT, radius=1, cap=2,
              per_source=cell(20),
              tags=(x8_upstream_tag("bronze_tools"),),
              cmds=(mod(city_stat_key("building.manufacturing_output_factor"),
                        0.0),))],
        [prog("bronze_casting_l3",
              "铜矿或锡矿周围 2 格（每源 +20%，最多 2 源 = +40%）：工业产出 +40%",
              selector=SEL_TAG_SOURCE_COUNT, radius=2, cap=2,
              per_source=cell(20),
              tags=(x8_upstream_tag("bronze_tools"),),
              cmds=(mod(city_stat_key("building.manufacturing_output_factor"),
                        0.0),))],
    ])


def build_capability_dependent_tables() -> None:
    """Fill the tables whose contents enumerate data files.

    `_read_res_dir_ids()` and `metric_keys()` are defined after the authoring
    section, so anything that expands a whole family has to run here rather than at
    import time. Called once from `main()` before validation.
    """
    _build_x8_tables()
    if not LEVEL_TERMS.get("excise"):
        # L1/L2/L3 tolerance and output terms only. L3's reserve-ratio ramp is
        # carried by `LEVEL_ROWS["excise"]`, because it is an Effect instruction
        # sequence and a Modifier definition cannot hold one.
        LEVEL_TERMS["excise"] = [
            _excise_terms(1.08),
            _excise_terms(1.12),
            _excise_terms(1.12),
        ]


def self_test_source_count_lint() -> None:
    """T10 + T11: the §7.6 rules and the packed round trip, as asserts.

    These are the lint's own tests. They run on every generation because the whole
    point of the packing is that a bad parameter is SILENT at runtime -- a shuffled
    bit field still parses, it just retargets the card. If a rule stops firing,
    generation must fail here rather than let content through.

    A counter-example is "a Prog that must be rejected".
    """
    tags = {"cell.produces.iron_ore"}
    good = dict(key="x_l1", summary="ok", tags=("cell.produces.iron_ore",),
                selector=SEL_TAG_SOURCE_COUNT, radius=1, cap=3, per_source=0.06,
                cmds=(mod("economy.city.output_factor", 0.0),))

    def rejected(label: str, **override) -> None:
        kwargs = dict(good)
        kwargs.update(override)
        program = Prog(**kwargs)
        try:
            _validate_source_count_program(program, tags)
        except SystemExit:
            return
        raise SystemExit(f"lint selftest: {label} was accepted but must be rejected")

    # The good shape must pass, or every counter-example below proves nothing.
    _validate_source_count_program(Prog(**good), tags)

    rejected("R1 no per_source", per_source=None, radius=1, cap=3)
    rejected("R2 no source tag", tags=())
    rejected("R3 two source tags", tags=("cell.produces.iron_ore",
                                         "cell.sector.energy"))
    rejected("R4 radius 0", radius=0)
    rejected("R4 radius 5", radius=5)
    rejected("R5 cap 0", cap=0)
    rejected("R5 cap 16", cap=16)
    rejected("R6 two commands",
             cmds=(mod("economy.city.output_factor", 0.0),
                   mod("economy.city.birth_factor", 0.0)))
    rejected("R7 stack over 4x", per_source=0.5, cap=9)
    rejected("R8 kind-16 fields on OWN_TERRITORY", selector=SEL_OWN_TERRITORY)
    rejected("R9 union selector with per_source", selector=SEL_TAG_SOURCE_R1)

    # T11: the packed layout must round-trip for every legal (radius, cap) pair and
    # every target cap that can be stored. The 5-bit field holds 1..31; 32 is the
    # default and is stored as 0, so the round trip maps 32 -> 0 -> 32 by design.
    for radius in range(1, 5):
        for count_cap in range(1, 16):
            for target_cap in (1, 16, 31, 32):
                stored = 0 if target_cap == 32 else target_cap
                packed, tag_slot = pack_source_count(
                    stored, radius, count_cap, 65535)
                got = unpack_source_count(packed, tag_slot)
                want = (target_cap, radius, count_cap, 65535)
                if got != want:
                    raise SystemExit(
                        f"pack round trip: {want} -> {got} (packed={packed})")

    # The emitted `target_selector_param` line must carry the packed value and leave
    # param[1] at 0 (the compiler fills the tag id from the tag NAME at load time).
    emitted = _selector_param_line(Prog(**dict(good, radius=2, cap=4)))
    expected_packed, _ = pack_source_count(0, 2, 4, 1)
    if f"PackedInt32Array({expected_packed}, 0)" not in emitted:
        raise SystemExit(
            f"selector param line: expected packed {expected_packed}, got {emitted!r}")

    # Kinds 14/15 must keep writing the literal (cap, param1) pair.
    union_line = _selector_param_line(Prog(
        key="u_l1", summary="ok", tags=("cell.sector.energy",),
        selector=SEL_TAG_SOURCE_R1, selector_cap=32, selector_param1=7,
        cmds=(mod("economy.city.output_factor", 0.0),)))
    if union_line != (
            "target_selector_param = PackedInt32Array(32, 7)\n"):
        raise SystemExit(f"union param line changed: {union_line!r}")


def self_test_ramp_lint() -> None:
    """One rejected counter-example per ramp unit rule (C-d item 1).

    Each case is a REAL bug that shipped in this repo before the rule existed, so
    the assertion documents the failure it prevents:
      (a) `basic_income`  had cap=15.0 on a 0..1 ratio metric
      (b) would clamp silently at 4x
      (c) `manufactory_regulation` had per=2.0 on a count metric
    """
    # (a) ratio metric with a cap above 1.0
    if not ramp_unit_error("cell.unemployment_q16", 1.0, 15.0):
        raise SystemExit("ramp lint selftest: (a) accepted cap=15 on a *_q16 metric")
    # (b) per * cap above 1.0
    if not ramp_unit_error("country.chained_cell_count", 0.2, 20.0):
        raise SystemExit("ramp lint selftest: (b) accepted 0.2 x 20 = 4.0")
    # (c) count metric with a per-unit gain above 0.1
    if not ramp_unit_error("cell.manufacturing_building_count", 2.0, 8.0):
        raise SystemExit("ramp lint selftest: (c) accepted per=2.0 on a count metric")

    # The fixed shapes must all pass, or the rules are over-tight and would force
    # the content back into a wrong unit.
    for metric, per, cap, label in (
            ("cell.unemployment_q16", 1.0, 0.15, "basic_income (fixed)"),
            ("cell.unemployment_q16", 1.5, 0.20, "automation_line L2 (fixed)"),
            ("cell.manufacturing_building_count", 0.02, 8.0, "manufactory L1 (fixed)"),
            ("cell.manufacturing_building_count", 0.03, 10.0, "manufactory L3 (fixed)"),
            ("country.chained_cell_count", 0.03, 20.0, "silver_flow L3"),
            ("country.treasury_reserve_ratio_pct", 0.01, 8.0, "progressive_tax")):
        reason = ramp_unit_error(metric, per, cap)
        if reason:
            raise SystemExit(f"ramp lint selftest: {label} wrongly rejected: {reason}")

    # ── ceiling rule: 上限 +N% in the summary must equal per * cap ─────────────
    # The counter-example is the bug fixed in C-e: `basic_income` said 上限 +15%
    # while per*cap gave 22.5%.
    bad = Prog(key="ceil_l1", summary="每点 +1.5%（上限 +15%）", tags=("x",),
               ramp=Ramp(metric="cell.unemployment_q16", per=1.5, cap=0.15),
               cmds=(mod("economy.city.output_factor", 0.0),))
    if not ramp_ceiling_error(bad):
        raise SystemExit(
            "ramp ceiling selftest: accepted 上限 +15% with per*cap = 22.5%")
    good = Prog(key="ceil_l2", summary="每点 +1.5%（上限 +15%）", tags=("x",),
                ramp=Ramp(metric="cell.unemployment_q16", per=1.5, cap=0.10),
                cmds=(mod("economy.city.output_factor", 0.0),))
    if ramp_ceiling_error(good):
        raise SystemExit(
            f"ramp ceiling selftest: wrongly rejected a correct card: "
            f"{ramp_ceiling_error(good)}")
    # A summary with no 上限 clause is not checked (not every ramp advertises one).
    silent = Prog(key="ceil_l3", summary="每点 +1%", tags=("x",),
                  ramp=Ramp(metric="cell.unemployment_q16", per=1.0, cap=0.05),
                  cmds=(mod("economy.city.output_factor", 0.0),))
    if ramp_ceiling_error(silent):
        raise SystemExit("ramp ceiling selftest: checked a summary with no ceiling")


def main() -> None:
    global _PUBLISHED
    self_test_source_count_lint()
    self_test_ramp_lint()
    build_capability_dependent_tables()
    # Before validation: `merge_x1_targets` decides which row each card emits, and
    # every validator below reads `LEVEL_ROWS`. Targets that are NOT merged (case 3
    # in `merge_x1_targets`) still get `validate_x1_targets` so a typo in a staged
    # v1 form cannot survive on the grounds that "the old row is what ships".
    merge_x1_targets()
    validate_x1b_release()
    validate_x1_targets()
    validate_rewrites()
    validate_cards()
    validate_city_family()
    validate_country_family()
    validate_programs()
    validate_ramp_units()
    validate_country_cut_ramp_caps()
    validate_ramp_ceilings()
    validate_monotonic_levels()
    validate_summary_matches_stats()
    validate_requires()
    validate_copy_flags()
    # Staged cards are validated in full by the calls above (their numbers, stats,
    # programs and duplicate keys all ran), and only then filtered out of every
    # emitted artifact. All three emitters read `cards_to_emit()`, so a staged card
    # leaves no orphan Effect or Modifier definition behind either.
    _PUBLISHED = published_cards()
    validate_published_synergies()
    IDEOLOGY_PATH.write_text(build_ideology_catalog(), encoding="utf-8", newline="\n")
    EFFECTS_PATH.write_text(build_effect_catalog(), encoding="utf-8", newline="\n")
    rewrite_modifier_catalog()
    validate_selector_kinds_emitted()
    write_card_expectations()
    print(f"named={len(NAMED_SYNERGIES)} resonances={len(RESONANCES) * 2}")
    print(f"city_definitions={len(MODIFIER_CITY_DEFINITION_IDS)}")
    print(f"country_definitions={len(MODIFIER_COUNTRY_DEFINITION_IDS)}")
    print(f"programs={len(DIAGNOSTIC_PROGRAMS) + len(all_card_programs())} "
          f"card_programs={len(all_card_programs())}")
    print(f"cards_published={len(cards_to_emit())} of {len(CARDS)}")
    if TEMPORARY_CARD_POOL_HOLDOUTS:
        print(f"temporary-pool-holdouts={len(TEMPORARY_CARD_POOL_HOLDOUTS)} 张"
              "（保留作者数据，不写入 catalog）：")
        for key, reason in sorted(TEMPORARY_CARD_POOL_HOLDOUTS.items()):
            print(f"  - {key}: {reason}")
    staged = staged_cards()
    if staged:
        print(f"已暂存 {len(staged)} 张（缺能力，未写入 catalog）：")
        for key, missing in staged:
            print(f"  - {key}: 缺 {', '.join(missing)}")
    if NEEDS_RUNTIME:
        print(f"needs-runtime {len(NEEDS_RUNTIME)} 张（可表达部分照常发布）：")
        for key, reason in sorted(NEEDS_RUNTIME.items()):
            print(f"  - {key}: {reason}")
    if SKIPPED_DESIGN_CARDS:
        print(f"skipped-design-cards {len(SKIPPED_DESIGN_CARDS)} 张（无精确机制，未写入）：")
        for key, reason in sorted(SKIPPED_DESIGN_CARDS.items()):
            print(f"  - {key}: {reason}")

    # The two X1 switches are reported separately: they need different work, so a
    # single merged list would hide that one group waits on C++ and the other waits
    # only on a release decision. Within each group, "rewritten" (the old version is
    # still live) is listed apart from "brand new" (waiting means not in the game).
    pending = pending_x1_rewrites()
    by_switch: dict[str, list[str]] = {}
    for key, switch in pending:
        by_switch.setdefault(switch, []).append(key)
    for switch, why in (
            ("X1b", "每源计数叠加，需 R 的 C++（09 §7）"),
            (X1_PLAIN_SWITCH, "逐格形态，用现成 selector，无需 C++")):
        keys = by_switch.get(switch, [])
        if not keys:
            continue
        rewrites = [k for k in keys if k not in X1_BRAND_NEW]
        fresh = [k for k in keys if k in X1_BRAND_NEW]
        print(f"X1 改写待开 {switch}（{len(keys)} 张：改写 {len(rewrites)} + 新卡 "
              f"{len(fresh)}；{why}）")
        if rewrites:
            print(f"  改写（旧版照常发布，{len(rewrites)} 张）：")
            for key in rewrites:
                print(f"    - {key}")
        if fresh:
            print(f"  新卡（开关未开则不入池，{len(fresh)} 张）：")
            for key in fresh:
                print(f"    - {key}")


if __name__ == "__main__":
    main()
