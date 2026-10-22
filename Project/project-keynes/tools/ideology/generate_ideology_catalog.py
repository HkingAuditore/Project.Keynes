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
    # Selector kinds 6..15 (OWN_TERRITORY / TAG_ANY_CELL / TAG_SOURCE_R1/R2), the
    # per-cell Effect instance path, tag predicates, metric conditions, synergy
    # magnitude overrides. Doc 02 calls the base form X1 (partial: no X1-b).
    "X1",
    # Neighbour population column (metric 54). Doc 02: X2 partial.
    "X2",
    # Dominant profession id / share / count (metrics 51..53). Doc 02: X3 partial.
    "X3",
    # Per-country tag counts and per-good counts (metrics 56..67). Doc 02: X7 partial.
    "X7",
    # National mean income-tax burden (metric 55). Doc 02: X11 partial.
    "X11",
    # Pity / refine / ban / route tilt. Doc 02: X15 supported.
    "X15",
    # NOT available, named so `requires=` can ask for them:
    #   X1b            per-source stacking + radius N (10-roadmap §4.2)
    #   X16            per-profession tax tolerance / satisfaction stat (47.3)
    #   metric68       cell.net_tax_burden_q16 (47.9)
    #   reserve_ratio  treasury reserve ratio = treasury cash / last year's national
    #                  population income, in 1% bands (47.4). Not a doc codename --
    #                  §47.4 redefined X11's "国库比" into this, and several cards
    #                  ramp on it, so it gets its own switch name.
    #   X4 X5 X6 X8 X9 X10 X12 X13 X14
})

# Every capability name `requires=` may mention. A name outside this set is a
# typo and must fail, otherwise a misspelt requirement silently passes as
# "available" once someone adds the real capability.
KNOWN_CAPABILITIES = AVAILABLE_CAPABILITIES | frozenset({
    "X1b", "X16", "metric68", "reserve_ratio", "X4", "X5", "X6", "X8", "X9",
    "X10", "X12", "X13", "X14",
})

# card key -> capability names it needs. A card whose requirements are not all in
# `AVAILABLE_CAPABILITIES` is validated and then STAGED (held back from the
# catalog). `main()` prints the staged list with what each one waits for.
CARD_REQUIRES: dict[str, tuple[str, ...]] = {}

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
]
IDEOLOGY_CITY_KEY_PREFIX = "ideology.city."


_CITY_SUFFIX_TO_STAT = {suffix: stat for suffix, stat in IDEOLOGY_CITY_STATS}


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
    # ── 石器时代 ────────────────────────────────────────────────────────────
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
    ("seasonal_calendar", "寒暑历法", "harmony", 1, 1, "", "", [],
     "以节气指导农时与役使，寒暑异常的危害大为减轻，思辨的锐气稍减。",
     []),  # numbers live in LEVEL_TERMS
    # §47.5 X16 cards. All STAGED (see CARD_REQUIRES); numbers live in LEVEL_TERMS.
    ("light_levy", "轻徭薄赋", "agrarian", 1, 1, "", "", [],
     "轻徭薄赋向来是立国之本，低税要真的少收钱才算数。", []),
    ("ancestral_hall", "宗祠", "harmony", 2, 1, "", "", [],
     "宗族以祠堂、义庄与族田联结子孙，兼并田产却苦了佃户。", []),

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

    # ── 帝国时代 ────────────────────────────────────────────────────────────
    ("village_compact", "乡约自治", "agrarian", 3, 3, "", IMPERIAL, [],
     "以乡约、社仓与家族共治维系基层秩序，民心即是国本，流通却少了弹性。",
     [(T_CAP, 0.97)]),
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
    ("heaven_human", "天人相参", "harmony", 2, 3, "", IMPERIAL, [],
     "观天察地以定政令，对旱涝与农业规律的理解更加系统，实测精神被压制。",
     [(DROUGHT, 0.95), (FLOOD, 0.95), (R_AGRI, 1.05), (R_SCI, 0.97)]),
    ("salt_monopoly", "盐铁专营", "industry", 2, 3, "economic_order", "", [SALT],
     "国家专营盐池与铁冶，盐利充盈国库，私商与盐脉同受挤压。",
     [(RUSE(SALT), 1.08), (T_CAP, 0.97)]),
    ("sericulture", "蚕桑", "industry", 2, 3, "", "", [SILKWORM],
     "植桑养蚕、缫丝织锦，绢帛成了硬通货，桑田与粮田争地。",
     [(T("plain", "agriculture"), 0.97)]),

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

    ("gentry_patronage", "乡绅", "learning", 1, 4, "", "", [],
     "乡绅办学、修桥、赈济，乡土文教随之兴旺，佃户却更难自立。", []),

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
     # TEMPORARY (v0). V1 (§47.2) forbids the old `TAX("industrial_worker") 0.95`:
     # one free tax-policy click, worth nothing. This row is the interim -- a real
     # household-cost cut with a reader -- and it is NOT the design.
     #
     # TARGET (v1, once X16 lands; see 09-content-status.md §6):
     #   L1/L2 stay as below,
     #   L3 adds `PROF_SATISFACTION("industrial_worker") +400` and
     #   `PROF_SATISFACTION("miner") +400` ("L3 产业工人、矿工满意度 +4"), and the
     #   card gains `CARD_REQUIRES["labour_legislation"] = ("X16",)`.
     # Flipping it then is a two-line change: replace this term list with
     # `LEVEL_TERMS["labour_legislation"]` (three levels, L3 carrying the two
     # satisfaction rows) and add the requires entry. Do not do it before X16 is in
     # AVAILABLE_CAPABILITIES, or the card ships with stats nothing reads.
     [(CONSUME, 0.98), (INPUT, 1.02)]),
    ("free_trade", "自由贸易", "commerce", 2, 6, "economic_order", "", [],
     "撤除关税壁垒，贸易容量大涨，本国制造在进口货面前没有遮拦。",
     [(T_CAP, 1.07), (T("plain", "manufacturing"), 0.97)]),
    ("agricultural_chemistry", "农业化学", "agrarian", 2, 6, "", "", [PHOSPHATE],
     "以磷矿与硝酸盐造肥，旱地单产大涨，矿源与水体同时承压。",
     # §47.7: `FLOOD 1.02` was a V3 no-op; the real price is the phosphate burn.
     [(RUSE(PHOSPHATE), 1.08)]),
    ("telegraph", "电报", "learning", 2, 6, "", "", [],
     "以电线传递消息，商情与政令同时提速，线路维护是一笔常年开销。",
     [(T_SPEED, 1.05), (R_SOC, 1.03), (B_COST, 1.02)]),

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
    ("antitrust", "反垄断", "commerce", 2, 7, "economic_order", "", [],
     "拆分托拉斯、恢复竞争，物价与流通受益，规模效率被牺牲。",
     [(MANU, 0.97)]),

    ("progressive_tax", "累进税", "mobilization", 2, 7, "", "", [],
     "重税转福利：劳动者扛得住税，资本方对同样的税率更敏感。", []),

    # ── 原子时代 ────────────────────────────────────────────────────────────
    ("nuclear_power", "核电计划", "industry", 3, 8, "", "", [RARE_EARTH],
     "以核裂变集中供能，能源产出跃升，稀有矿料成为长期负担。",
     [(ENER, 1.08), (G("electricity"), 1.06), (RUSE(RARE_EARTH), 1.08)]),
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

    # ── 智能时代 ────────────────────────────────────────────────────────────
    ("algorithmic_governance", "算法治理", "learning", 3, 10, "", "", [],
     "以模型分配资源与名额，效率极高，解释权集中，基础科学被挤压。",
     [(R_SOC, 1.06), (POINTS, 1.05), (R_SCI, 0.97)]),
    ("autonomous_logistics", "无人运输", "commerce", 3, 10, "", "", [],
     "无人车与自动调度把运力从人力约束中解放出来，车队与系统投资极高。",
     [(T_SPEED, 1.08), (T_CAP, 1.05), (B_COST, 1.03)]),
    ("carbon_market", "碳市场", "harmony", 3, 10, "", "", [],
     "给排放定价，资源耗用被系统性压低，高耗能制造随之收缩。",
     [(RES_USE, 0.92), (MANU, 0.96)]),
    ("gene_editing", "基因编辑", "agrarian", 3, 10, "", "", [MAIZE],
     "定向改造作物性状，主粮单产再上台阶，伦理争议削弱社会共识。",
     [(T("plain", "agriculture"), 1.10), (DEATH, 0.98), (R_SOC, 0.97)]),
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
    # Every draw is paid: 6.0 points first, then +20% per draw (6.0, 7.2, 8.64...).
    "offer_cost_q16": 393216,
    "offer_cost_growth_percent": 120,
    "offer_cost_max_q16": 2147483647,
    "reroll_cost_percent": 50,
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
    # 0.02 point per new resident, 0.25 point per new installed building,
    # 0.002 point per money unit of daily trade base value, capped at 2 per period.
    "point_population_weight_q16": 1311,
    "point_building_weight_q16": 16384,
    "point_trade_weight_q16": 131,
    "point_gain_cap_q16": 131072,
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

STACK_REPLACE = 0
STACK_REFRESH = 1
STACK_ADD_STACK = 2

DOMAIN_CELL = 2
DOMAIN_COUNTRY = 3


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
    """Linear magnitude: value = per * min(metric, cap).

    The effect runtime already has the whole instruction set for this
    (READ_METRIC / MIN / MUL_Q16 / EMIT with VALUE_STACK_TOP), and
    `family_effect_metadata_pod` already unions READ_METRIC ids into the metric
    mask -- so "每有 1 个 X，+1%（上限 +N）" needs authorship, not engine work.
    What was missing was a way to say it in the generator.
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


def mod(modifier: str, value: float, **kwargs) -> Cmd:
    return Cmd(modifier=modifier, value=value, **kwargs)


def prog(key: str, summary: str, **kwargs) -> Prog:
    return Prog(key=key, summary=summary, **kwargs)


def cell(pct: float) -> float:
    """Authoring sugar: `cell(5)` is +5%, `cell(-8)` is -8%."""
    return pct / 100.0


_METRIC_KEYS_CACHE: list[str] | None = None


def metric_keys() -> list[str]:
    """`effect_domain_catalog.gd`'s dense metric table, in id order."""
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
]

# ── per-card authoring ───────────────────────────────────────────────────────
# Cards absent here keep the pre-existing national-Modifier path byte for byte.
CARD_META: dict[str, Meta] = {}

# card key -> exactly three levels; each level is an ordered list of rows.
# A row is a `Prog`; the card's own `terms` stay in CARDS and are emitted as ONE
# legacy cost row per level at magnitude 1.0 ("the price does not grow with the
# level; the benefit does").
LEVEL_ROWS: dict[str, list[list[Prog]]] = {}

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
    # L3: +15%; the "相邻 ≥2 个农业支柱的丘陵/山地 再 +6%" clause needs X2
    # (a neighbour count as a number), so it stays a program row on L3 -- see
    # `LEVEL_ROWS["terrace_farming"]` below, which lands on the `cell.terrain.hill`
    # population as the closest tag-only approximation and says so on the card.
    [(T("hill", "agriculture"), 1.15), (T("mountain", "agriculture"), 1.15),
     (T("hill", "extractive"), 0.90), (T("mountain", "extractive"), 0.90)],
]

LEVEL_ROWS["terrace_farming"] = [
    [], [],
    [prog("terrace_farming_l3",
          "丘陵地块（最多 32 格）：农业产出 +6%（L3 子句；相邻计数需 X2，当前按丘陵地块计）",
          tags=("cell.terrain.hill",),
          cmds=(mod(city_stat_key("building.agriculture_output_factor"), cell(6)),))],
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
          "泛滥平原、三角洲地块周围 1 格（最多 32 格）：农业产出 +4%",
          selector=SEL_TAG_SOURCE_R1, tags=("cell.terrain.floodplain",),
          cmds=(mod(city_stat_key("building.agriculture_output_factor"), cell(4)),))],
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
          "三角洲、泛滥平原地块周围 1 格（最多 32 格）：农业产出 +3%",
          selector=SEL_TAG_SOURCE_R1, tags=("cell.landform.delta",),
          cmds=(mod(city_stat_key("building.agriculture_output_factor"), cell(3)),))],
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
          "能源支柱的河谷地块周围 1 格（最多 32 格）：能源产出 +8%",
          selector=SEL_TAG_SOURCE_R2, tags=("cell.sector.energy",),
          cmds=(mod(city_stat_key("building.energy_output_factor"), cell(8)),))],
]

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

    `ramp` is carried as a separate row so L3's third clause stays visible in the
    table instead of being folded into a bigger tolerance. L3 must NOT just repeat
    L2: a level the player pays understanding for and gets nothing from is the
    "L2 永远是 L1×1.6" bug (§3.4) in another form.
    """
    rows = [(PROF_TOLERANCE(pid), tolerance) for pid in _all_profession_ids()]
    rows += [(G(good), 0.96) for good in _EXCISE_CUT_GOODS]
    if ramp is not None:
        rows.append(RampTerm(stat=B_COST, ramp=ramp))
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
LEVEL_TERMS["progressive_tax"] = [
    # L1: 雇佣劳动者容忍度 x1.20；国库储备率每档死亡率 -1%（上限 -6%）
    #     资本方容忍度 x0.80（同样的税率他们更不满）
    [(PROF_TOLERANCE(pid), 1.20) for pid in profession_group("wage_workers")]
    + [(PROF_TOLERANCE(pid), 0.80) for pid in profession_group("capital")]
    + [RampTerm(stat=DEATH, ramp=Ramp(metric="country.treasury_reserve_ratio_pct",
                                      per=0.01, cap=6.0))],
    # L2: x1.30，死亡率上限 -8%
    [(PROF_TOLERANCE(pid), 1.30) for pid in profession_group("wage_workers")]
    + [(PROF_TOLERANCE(pid), 0.80) for pid in profession_group("capital")]
    + [RampTerm(stat=DEATH, ramp=Ramp(metric="country.treasury_reserve_ratio_pct",
                                      per=0.01, cap=8.0))],
    # L3: 同 L2，另加「轻税地块出生率 +6%」（metric 68 程序，见下）
    [(PROF_TOLERANCE(pid), 1.30) for pid in profession_group("wage_workers")]
    + [(PROF_TOLERANCE(pid), 0.80) for pid in profession_group("capital")]
    + [RampTerm(stat=DEATH, ramp=Ramp(metric="country.treasury_reserve_ratio_pct",
                                      per=0.01, cap=8.0))],
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

CARD_REQUIRES["petition_box"] = ("X16", "metric68")
LEVEL_TERMS["petition_box"] = [
    # L1: 农民阶层民意 <0 时农耕劳动者满意度 +4；全国死亡率 -3%
    #     民意 ≥0.3 时理念点 +5%
    # 民意是 X14（未实现），所以这张卡同时挂 X16 + metric68；民意条件写不了，
    # 本轮只写满意度与死亡率两项（它们无条件成立），民意档位等 X14。
    [(PROF_SATISFACTION("agricultural_worker"), 400.0),
     (PROF_SATISFACTION("subsistence_farmer"), 400.0),
     (PROF_SATISFACTION("tenant_farmer"), 400.0),
     (PROF_SATISFACTION("sharecropper"), 400.0),
     (PROF_SATISFACTION("serf"), 400.0),
     (PROF_SATISFACTION("household_farmer"), 400.0),
     (DEATH, 0.97), (R_SOC, 0.98, OP_ADD_DOWNSIDE)],
    # L2: 满意度 +6 / 理念点 +7%
    [(PROF_SATISFACTION(pid), 600.0) for pid in profession_group("farm_workers")]
    + [(DEATH, 0.97), (POINTS, 1.07), (R_SOC, 0.98, OP_ADD_DOWNSIDE)],
    # L3: 工人阶层同样适用（雇佣劳动者满意度 +4）
    [(PROF_SATISFACTION(pid), 600.0) for pid in profession_group("farm_workers")]
    + [(PROF_SATISFACTION(pid), 400.0) for pid in profession_group("wage_workers")]
    + [(DEATH, 0.97), (POINTS, 1.07), (R_SOC, 0.98, OP_ADD_DOWNSIDE)],
]

CARD_REQUIRES["ancestral_hall"] = ("X16", "X9")
LEVEL_TERMS["ancestral_hall"] = [
    # 代价：佃农层满意度 -3（宗族兼并田产）。名门地块 +6% 全产出属 X9，未写。
    [(PROF_SATISFACTION(pid), -300.0, OP_ADD_DOWNSIDE)
     for pid in profession_group("tenant_layer")],
    [(PROF_SATISFACTION(pid), -300.0, OP_ADD_DOWNSIDE)
     for pid in profession_group("tenant_layer")],
    [(PROF_SATISFACTION(pid), -300.0, OP_ADD_DOWNSIDE)
     for pid in profession_group("tenant_layer")],
]

CARD_REQUIRES["gentry_patronage"] = ("X16", "X9")
LEVEL_TERMS["gentry_patronage"] = [
    # 代价：佃农层满意度 -2。名门地块知识产出属 X9，未写。
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

CARD_META["flint_knapping"] = Meta(route="mining")
LEVEL_ROWS["flint_knapping"] = [
    [prog("flint_knapping_l1", "主产燧石的地块周围 1 格（最多 32 格）：全部产出 +4%",
          selector=SEL_TAG_SOURCE_R1, tags=("cell.produces.flint",),
          cmds=(mod(city_stat_key("output_factor"), cell(4)),))],
    [prog("flint_knapping_l2", "主产燧石的地块周围 1 格（最多 32 格）：全部产出 +6%",
          selector=SEL_TAG_SOURCE_R1, tags=("cell.produces.flint",),
          cmds=(mod(city_stat_key("output_factor"), cell(6)),))],
    [prog("flint_knapping_l3", "主产燧石的地块周围 1 格（最多 32 格）：全部产出 +8%",
          selector=SEL_TAG_SOURCE_R1, tags=("cell.produces.flint",),
          cmds=(mod(city_stat_key("output_factor"), cell(8)),))],
]

CARD_META["sericulture"] = Meta(route="workshop")
LEVEL_ROWS["sericulture"] = [
    [prog("sericulture_l1", "主产布的地块周围 1 格（最多 32 格）：精致服装产出 +12%",
          selector=SEL_TAG_SOURCE_R1, tags=("cell.produces.cloth",),
          cmds=(mod(city_stat_key("good.fine_clothing.output_factor"), cell(12)),))],
    [prog("sericulture_l2", "主产布的地块周围 1 格（最多 32 格）：精致服装产出 +16%",
          selector=SEL_TAG_SOURCE_R1, tags=("cell.produces.cloth",),
          cmds=(mod(city_stat_key("good.fine_clothing.output_factor"), cell(16)),))],
    [prog("sericulture_l3", "主产布的地块周围 1 格（最多 32 格）：精致服装产出 +20%",
          selector=SEL_TAG_SOURCE_R1, tags=("cell.produces.cloth",),
          cmds=(mod(city_stat_key("good.fine_clothing.output_factor"), cell(20)),))],
]

CARD_META["cotton_gin"] = Meta(route="workshop")
LEVEL_ROWS["cotton_gin"] = [
    [prog("cotton_gin_l1", "主产棉纤维的地块周围 2 格（最多 32 格）：布产出 +10%",
          selector=SEL_TAG_SOURCE_R2, tags=("cell.produces.cotton_fiber",),
          cmds=(mod(city_stat_key("good.cloth.output_factor"), cell(10)),))],
    [prog("cotton_gin_l2", "主产棉纤维的地块周围 2 格（最多 32 格）：布产出 +14%",
          selector=SEL_TAG_SOURCE_R2, tags=("cell.produces.cotton_fiber",),
          cmds=(mod(city_stat_key("good.cloth.output_factor"), cell(14)),))],
    [prog("cotton_gin_l3", "主产棉纤维的地块周围 2 格（最多 32 格）：布产出 +18%",
          selector=SEL_TAG_SOURCE_R2, tags=("cell.produces.cotton_fiber",),
          cmds=(mod(city_stat_key("good.cloth.output_factor"), cell(18)),))],
]

CARD_META["agricultural_chemistry"] = Meta(route="cropland")
LEVEL_ROWS["agricultural_chemistry"] = [
    [prog("agricultural_chemistry_l1", "主产化肥的地块周围 2 格（最多 32 格）：农业产出 +8%",
          selector=SEL_TAG_SOURCE_R2, tags=("cell.produces.fertilizer",),
          cmds=(mod(city_stat_key("building.agriculture_output_factor"), cell(8)),))],
    [prog("agricultural_chemistry_l2", "主产化肥的地块周围 2 格（最多 32 格）：农业产出 +11%",
          selector=SEL_TAG_SOURCE_R2, tags=("cell.produces.fertilizer",),
          cmds=(mod(city_stat_key("building.agriculture_output_factor"), cell(11)),))],
    [prog("agricultural_chemistry_l3", "主产化肥的地块周围 2 格（最多 32 格）：农业产出 +14%",
          selector=SEL_TAG_SOURCE_R2, tags=("cell.produces.fertilizer",),
          cmds=(mod(city_stat_key("building.agriculture_output_factor"), cell(14)),))],
]

CARD_META["petrochemical"] = Meta(route="workshop")
LEVEL_ROWS["petrochemical"] = [
    [prog("petrochemical_l1", "主产原油的地块周围 2 格（最多 32 格）：塑料、合成纤维产出 +12%",
          selector=SEL_TAG_SOURCE_R2, tags=("cell.produces.crude_oil",),
          cmds=(mod(city_stat_key("good.plastics.output_factor"), cell(12)),
                mod(city_stat_key("good.synthetic_fiber.output_factor"), cell(12))))],
    [prog("petrochemical_l2", "主产原油的地块周围 2 格（最多 32 格）：塑料、合成纤维产出 +16%",
          selector=SEL_TAG_SOURCE_R2, tags=("cell.produces.crude_oil",),
          cmds=(mod(city_stat_key("good.plastics.output_factor"), cell(16)),
                mod(city_stat_key("good.synthetic_fiber.output_factor"), cell(16))))],
    [prog("petrochemical_l3", "主产原油的地块周围 2 格（最多 32 格）：塑料、合成纤维产出 +20%",
          selector=SEL_TAG_SOURCE_R2, tags=("cell.produces.crude_oil",),
          cmds=(mod(city_stat_key("good.plastics.output_factor"), cell(20)),
                mod(city_stat_key("good.synthetic_fiber.output_factor"), cell(20))))],
]

CARD_META["collective_stewardship"] = Meta(route="cropland")
LEVEL_ROWS["collective_stewardship"] = [
    [prog("collective_stewardship_l1", "农业支柱地块周围 1 格（最多 32 格）：全部产出 +3%",
          selector=SEL_TAG_SOURCE_R1, tags=("cell.sector.agriculture",),
          cmds=(mod(city_stat_key("output_factor"), cell(3)),))],
    [prog("collective_stewardship_l2", "农业支柱地块周围 1 格（最多 32 格）：全部产出 +5%",
          selector=SEL_TAG_SOURCE_R1, tags=("cell.sector.agriculture",),
          cmds=(mod(city_stat_key("output_factor"), cell(5)),))],
    [prog("collective_stewardship_l3", "农业支柱地块周围 1 格（最多 32 格）：全部产出 +7%",
          selector=SEL_TAG_SOURCE_R1, tags=("cell.sector.agriculture",),
          cmds=(mod(city_stat_key("output_factor"), cell(7)),))],
]

CARD_META["electrification"] = Meta(route="workshop")
LEVEL_ROWS["electrification"] = [
    [prog("electrification_l1", "能源支柱地块周围 2 格（最多 32 格）：工业产出 +8%",
          selector=SEL_TAG_SOURCE_R2, tags=("cell.sector.energy",),
          cmds=(mod(city_stat_key("building.manufacturing_output_factor"), cell(8)),))],
    [prog("electrification_l2", "能源支柱地块周围 2 格（最多 32 格）：工业产出 +12%",
          selector=SEL_TAG_SOURCE_R2, tags=("cell.sector.energy",),
          cmds=(mod(city_stat_key("building.manufacturing_output_factor"), cell(12)),))],
    [prog("electrification_l3", "能源支柱地块周围 2 格（最多 32 格）：工业产出 +15%",
          selector=SEL_TAG_SOURCE_R2, tags=("cell.sector.energy",),
          cmds=(mod(city_stat_key("building.manufacturing_output_factor"), cell(15)),))],
]

CARD_META["motorization"] = Meta(route="thoroughfare")
LEVEL_ROWS["motorization"] = [
    [prog("motorization_l1", "繁市地块周围 2 格（最多 32 格）：全部产出 +4%",
          selector=SEL_TAG_SOURCE_R2, tags=("cell.market",),
          cmds=(mod(city_stat_key("output_factor"), cell(4)),))],
    [prog("motorization_l2", "繁市地块周围 2 格（最多 32 格）：全部产出 +6%",
          selector=SEL_TAG_SOURCE_R2, tags=("cell.market",),
          cmds=(mod(city_stat_key("output_factor"), cell(6)),))],
    [prog("motorization_l3", "繁市地块周围 2 格（最多 32 格）：全部产出 +8%",
          selector=SEL_TAG_SOURCE_R2, tags=("cell.market",),
          cmds=(mod(city_stat_key("output_factor"), cell(8)),))],
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
          ramp=Ramp("country.extractive_cell_count", per=0.015, cap=15),
          cmds=(mod(city_stat_key("building.extractive_output_factor"), cell(1.5)),))],
    [prog("salt_monopoly_l3", "每个矿业支柱地块使矿业支柱地块产出 +2%（上限 +15%）",
          tags=("cell.sector.extractive",),
          ramp=Ramp("country.extractive_cell_count", per=0.02, cap=15),
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
          ramp=Ramp("country.chained_cell_count", per=0.025, cap=20),
          cmds=(mod(city_stat_key("good.semiconductors.output_factor"), cell(2.5)),))],
    [prog("semiconductor_l3", "每个成链地块使成链地块的半导体产出 +3%（上限 +40%）",
          tags=("cell.chained",),
          ramp=Ramp("country.chained_cell_count", per=0.03, cap=20),
          cmds=(mod(city_stat_key("good.semiconductors.output_factor"), cell(3)),))],
]

CARD_META["silver_flow"] = Meta(route="market")
LEVEL_ROWS["silver_flow"] = [
    [prog("silver_flow_l1", "每个主产白银地块使白银地块产出 +3%（上限 +15%）",
          tags=("cell.produces.silver",),
          ramp=Ramp("country.silver_cell_count", per=0.03, cap=5),
          cmds=(mod(city_stat_key("output_factor"), cell(3)),))],
    [prog("silver_flow_l2", "每个主产白银地块使白银地块产出 +3%（上限 +21%）",
          tags=("cell.produces.silver",),
          ramp=Ramp("country.silver_cell_count", per=0.03, cap=7),
          cmds=(mod(city_stat_key("output_factor"), cell(3)),))],
    [prog("silver_flow_l3", "每个主产白银地块使白银地块产出 +3%（上限 +27%）",
          tags=("cell.produces.silver",),
          ramp=Ramp("country.silver_cell_count", per=0.03, cap=9),
          cmds=(mod(city_stat_key("output_factor"), cell(3)),))],
]

CARD_META["chartered_route"] = Meta(route="thoroughfare")
LEVEL_ROWS["chartered_route"] = [
    [prog("chartered_route_l1", "每种专精物资使繁市地块产出 +1%（上限 +15%）",
          tags=("cell.market",),
          ramp=Ramp("country.distinct_specialized_good_count", per=0.01, cap=15),
          cmds=(mod(city_stat_key("output_factor"), cell(1)),))],
    [prog("chartered_route_l2", "每种专精物资使繁市地块产出 +1.5%（上限 +15%）",
          tags=("cell.market",),
          ramp=Ramp("country.distinct_specialized_good_count", per=0.015, cap=15),
          cmds=(mod(city_stat_key("output_factor"), cell(1.5)),))],
    [prog("chartered_route_l3", "每种专精物资使繁市地块产出 +2%（上限 +15%）",
          tags=("cell.market",),
          ramp=Ramp("country.distinct_specialized_good_count", per=0.02, cap=15),
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


# ── .tres emitters for programs ──────────────────────────────────────────────
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
        f"target_selector_param = PackedInt32Array({item.selector_cap}, {item.selector_param1})\n"
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


def _term_operation(entry) -> int:
    """The Modifier operation a term tuple must be written with."""
    if isinstance(entry, RampTerm):
        return OP_MULTIPLY
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
                    f'SubResource("{item}")' for item in effect_ids))
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
            "levels = Array[Resource]([%s])\n" % ", ".join(
                f'SubResource("{level}")' for level in level_ids))
    synergy_ids: list[str] = []
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
    for route, (display, tier1, tier2) in ROUTE_BONDS.items():
        for tier, count, terms in ((1, 2, tier1), (2, 4, tier2)):
            if terms is None:
                continue
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
             "household_goods": "家用品", "protein": "蛋白质"}
    resources = {"timber": "木材", "pasture": "牧草", "fertile_soil": "肥沃土壤",
                 "wild_game": "野味", "freshwater_fish": "淡水鱼"}
    goods = {"lumber": "原木", "crude_oil": "原油", "natural_gas": "天然气",
             "rice_grain": "稻米", "grain": "谷物", "cloth": "布",
             "fine_clothing": "精致服装", "fertilizer": "化肥", "plastics": "塑料",
             "game_meat": "野味", "fish": "鱼"}
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


def modifier_blocks() -> tuple[list[str], list[str]]:
    blocks: list[str] = []
    definition_ids: list[str] = []

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
            "domain = 1\nstack_policy = 1\ndefault_duration_days = -1\n"
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
    for route, (display, tier1, tier2) in ROUTE_BONDS.items():
        for tier, terms in ((1, tier1), (2, tier2)):
            if terms is None:
                continue
            add(f"Route{camel(route)}{tier}",
                f"ideology.route.{route}.t{tier}",
                f"{display}·{'一' if tier == 1 else '二'}",
                f"{display}体系联动修正（{'2' if tier == 1 else '4'} 张）。",
                terms)
    for key, name, _cards, terms in NAMED_SYNERGIES:
        add("Synergy" + camel(key), f"ideology.synergy.{key}", name, f"{name}联动修正。", terms)
    for school in SCHOOL_ORDER:
        for count, terms in zip((2, 4), RESONANCES[school]):
            add(f"Resonance{camel(school)}{count}", f"ideology.resonance.{school}.{count}",
                f"{SCHOOL_NAMES[school]}共鸣{count}",
                f"装备或晋升{count}张{SCHOOL_NAMES[school]}理念。", terms)
    blocks.extend(ideology_city_blocks())
    definition_ids.extend(MODIFIER_CITY_DEFINITION_IDS)
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


def validate_programs() -> None:
    """Fail the generation on anything that would compile and then do nothing."""
    # P1-E: `STACK_ADD_STACK` together with a finite duration only means
    # something if an event can add a stack while the other stacks are still
    # alive. X4 (the event ring) does not exist, so the only rows that could
    # ever drive it are diagnostics that set the stack count themselves. A
    # timed ADD_STACK card would therefore ship as "stacks once, expires, never
    # counts again" -- silently weaker than authored, and invisible in review.
    for program in DIAGNOSTIC_PROGRAMS + list(all_card_programs()):
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
        has_cut = any(command.value < 0.0
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
    for item in DIAGNOSTIC_PROGRAMS + all_card_programs():
        if item.key in seen:
            raise SystemExit(f"program: duplicate key {item.key}")
        seen.add(item.key)
        if not item.cmds:
            raise SystemExit(f"program: {item.key} emits no command")
        if item.selector < 0 or item.selector > SEL_TAG_SOURCE_R2:
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
        if item.tags and item.selector not in (
                SEL_OWN_TERRITORY, SEL_TAG_ANY_CELL,
                SEL_TAG_SOURCE_R1, SEL_TAG_SOURCE_R2):
            raise SystemExit(
                f"program: {item.key} uses tags with selector {item.selector}; "
                "only 12/13/14/15 read a tag")
        for tag in item.tags:
            if tag not in tag_names:
                raise SystemExit(f"program: {item.key} unknown tag {tag}")
        if item.stacks < 1 or item.stacks > 64:
            raise SystemExit(f"program: {item.key} bad stacks {item.stacks}")
        if item.stack_policy == STACK_ADD_STACK and item.max_stacks > 6:
            raise SystemExit(f"program: {item.key} keeps more than 6 layers")
        is_diagnostic = item.key.startswith("v") and item.key[1:2].isdigit()
        for command in item.cmds:
            key = command.modifier
            if command.value < 0.0 and not key.endswith(".cut"):
                key = key + ".cut"
            if is_diagnostic:
                continue
            if key not in city_keys:
                raise SystemExit(
                    f"program: {item.key} names {key}; card programs must use "
                    "an ideology.city.* definition")


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
    for key, needs in CARD_REQUIRES.items():
        if key not in card_keys:
            raise SystemExit(f"requires: unknown card {key}")
        for name in needs:
            if name not in KNOWN_CAPABILITIES:
                raise SystemExit(
                    f"requires: card {key} names unknown capability {name!r}; "
                    "add it to KNOWN_CAPABILITIES (and AVAILABLE_CAPABILITIES "
                    "once the runtime supports it)")


def staged_cards() -> list[tuple[str, tuple[str, ...]]]:
    """Cards held out of the catalog, with the capabilities they are waiting for.

    Returns the blockers only (the missing subset), not everything the card asked
    for, so the printed list says exactly what is holding each card back.
    """
    out: list[tuple[str, tuple[str, ...]]] = []
    for key, needs in sorted(CARD_REQUIRES.items()):
        missing = tuple(n for n in needs if n not in AVAILABLE_CAPABILITIES)
        if missing:
            out.append((key, missing))
    return out


def published_cards() -> list:
    """`CARDS` minus the staged ones -- what actually goes into the catalog."""
    staged = {key for key, _ in staged_cards()}
    return [card for card in CARDS if card[0] not in staged]


# Set by `main()` after validation, read by the three emitters. Module-level (and
# defaulting to "everything") so importing this file never hides cards from a
# caller that just wants the tables.
_PUBLISHED: list | None = None


def cards_to_emit() -> list:
    """The card rows the emitters may write: all of them unless `main()` staged some."""
    return CARDS if _PUBLISHED is None else _PUBLISHED


def build_capability_dependent_tables() -> None:
    """Fill the tables whose contents enumerate data files.

    `_read_res_dir_ids()` and `metric_keys()` are defined after the authoring
    section, so anything that expands a whole family has to run here rather than at
    import time. Called once from `main()` before validation.
    """
    if not LEVEL_TERMS.get("excise"):
        # L1 tolerance, L2 tolerance, L3 tolerance + the reserve-ratio ramp. L3 gets
        # its own numbers on purpose: see `_excise_terms`.
        LEVEL_TERMS["excise"] = [
            _excise_terms(1.08),
            _excise_terms(1.12),
            _excise_terms(1.12,
                          Ramp(metric="country.treasury_reserve_ratio_pct",
                               per=0.005, cap=8.0)),
        ]


def main() -> None:
    global _PUBLISHED
    build_capability_dependent_tables()
    validate_cards()
    validate_city_family()
    validate_programs()
    validate_requires()
    # Staged cards are validated in full by the calls above (their numbers, stats,
    # programs and duplicate keys all ran), and only then filtered out of every
    # emitted artifact. All three emitters read `cards_to_emit()`, so a staged card
    # leaves no orphan Effect or Modifier definition behind either.
    _PUBLISHED = published_cards()
    IDEOLOGY_PATH.write_text(build_ideology_catalog(), encoding="utf-8", newline="\n")
    EFFECTS_PATH.write_text(build_effect_catalog(), encoding="utf-8", newline="\n")
    rewrite_modifier_catalog()
    print(f"named={len(NAMED_SYNERGIES)} resonances={len(RESONANCES) * 2}")
    print(f"city_definitions={len(MODIFIER_CITY_DEFINITION_IDS)}")
    print(f"programs={len(DIAGNOSTIC_PROGRAMS) + len(all_card_programs())} "
          f"card_programs={len(all_card_programs())}")
    print(f"cards_published={len(cards_to_emit())} of {len(CARDS)}")
    staged = staged_cards()
    if staged:
        print(f"已暂存 {len(staged)} 张（缺能力，未写入 catalog）：")
        for key, missing in staged:
            print(f"  - {key}: 缺 {', '.join(missing)}")


if __name__ == "__main__":
    main()
