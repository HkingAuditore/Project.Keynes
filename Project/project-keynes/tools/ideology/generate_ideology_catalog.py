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

ROOT = pathlib.Path(__file__).resolve().parents[2]
IDEOLOGY_PATH = ROOT / "data/ideologies/default_ideology_catalog.tres"
MODIFIER_PATH = ROOT / "data/modifiers/default_modifier_catalog.tres"
NETWORK_PATH = ROOT / "data/technology/technology_network.json"
SIGNAL_CATALOG_PATH = ROOT / "scripts/research/research_signal_catalog.gd"
MODIFIER_CATALOG_PATH = ROOT / "scripts/modifier/modifier_catalog.gd"
TERRAIN_PATH = ROOT / "scripts/geography/terrain_type.gd"
LANDFORM_PATH = ROOT / "scripts/geography/landform_type.gd"
BUILDINGS_DIR = ROOT / "data/economy/buildings"
GOODS_DIR = ROOT / "data/goods"
PROFESSIONS_DIR = ROOT / "data/economy/professions"
PRODUCTION_CLIMATES_DIR = ROOT / "data/economy/production_climates"

Q16 = 65536
LEVEL_THRESHOLDS = [0, 262144, 786432]          # 0 / 4.0 / 12.0 understanding
LEVEL_DAILY = [8192, 4096, 0]                   # 0.125 / 0.0625 / 0 per day
LEVEL_MAGNITUDES = [65536, 104858, 144179]      # 1.0x / 1.6x / 2.2x
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
}


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


def TAX(profession_id: str) -> str:
    """Income-tax rate of one profession."""
    return f"country.tax.income.{profession_id}.rate_bp"


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
     [(T("forest", "agriculture"), 1.08), (T("jungle", "agriculture"), 1.06),
      (RUSE(WILD_GAME), 1.05)]),
    ("hunting_tradition", "狩猎传统", "mobilization", 1, 0, "", "", [],
     "以围猎、陷阱与分工分配肉食，青壮年在协作中学会统一号令。",
     [(G("game_meat"), 1.08), (RUSE(WILD_GAME), 1.06)]),
    ("flint_knapping", "打制石器", "industry", 1, 0, "", "", [FLINT],
     "打击石核取刃，形状统一的石器让各项劳作都更省力。",
     [(G("chipped_stone_tools"), 1.10), (INPUT, 0.97), (RUSE(FLINT), 1.08)]),
    ("fire_keeping", "火种守护", "harmony", 1, 0, "", "", [],
     "专人看守长明火堆，寒夜的冻害与恐惧同时退去，柴薪消耗也随之上升。",
     [(COLD, 0.92), (T("tundra", "agriculture"), 1.05), (RUSE(TIMBER), 1.04)]),
    ("riverside_camp", "逐水而居", "harmony", 1, 0, "", "", [FRESHWATER_ACCESS],
     "营地紧贴河岸与湖湾，取水捕鱼极便，洪水却始终是威胁。",
     [(LF("delta", "agriculture"), 1.06), (T("floodplain", "agriculture"), 1.06),
      (FLOOD, 1.04)]),
    ("animist_ritual", "万物有灵", "learning", 1, 0, "", "", [],
     "把山川鸟兽都视作有意志的存在，解释世界的方式由此开始。",
     [(R_SOC, 1.05), (POINTS, 1.05), (R_SCI, 0.97)]),
    ("gift_exchange", "馈赠交换", "commerce", 1, 0, "", "", [],
     "以礼物与回礼代替买卖，熟人之间的物流从不间断，礼物本身却要耗料。",
     [(T_CAP, 1.05), (T_SPEED, 1.04), (INPUT, 1.02)]),
    ("pit_dwelling", "穴居聚落", "industry", 1, 0, "", "", [],
     "掘地为屋、聚族而居，御寒与省工两得，可耕的地面却让了出去。",
     [(COLD, 0.94), (B_COST, 0.95), (T("hill", "agriculture"), 0.98)]),

    # ── 农耕时代 ────────────────────────────────────────────────────────────
    ("collective_stewardship", "共同体治理", "agrarian", 1, 1, "economic_order", "", [],
     "以共同仓储、互助义务和长期土地责任组织生产，灵活交易被牺牲。",
     [(AGRI, 1.05), (T("plain", "agriculture"), 1.04), (DROUGHT, 0.95), (T_CAP, 0.97)]),
    ("terrace_farming", "梯田", "agrarian", 1, 1, "", "", [MOUNTAIN],
     "顺山势砌石成田，坡地上的每一寸土都被用上，工料耗费极大。",
     [(T("hill", "agriculture"), 1.10), (T("mountain", "agriculture"), 1.10),
      (INPUT, 1.03)]),
    ("paddy_cultivation", "稻作", "agrarian", 1, 1, "", "", [RICE],
     "筑埂蓄水、育秧移栽，水田的单产远高于旱地，却挤占麦作。",
     [(G("rice_grain"), 1.10), (T("swamp", "agriculture"), 1.08),
      (LF("delta", "agriculture"), 1.08), (G("wheat_grain"), 0.95)]),
    ("three_field_rotation", "三圃轮作", "agrarian", 2, 1, "land_order", "", [WHEAT],
     "把耕地分为三片轮换休耕，地力得以恢复，牧草地相应让出。",
     [(G("wheat_grain"), 1.08), (RREG(FERTILE), 1.10), (RUSE(FERTILE), 0.94),
      (T("grassland", "agriculture"), 0.97)]),
    ("free_exchange", "自由交换", "commerce", 1, 1, "economic_order", "", [],
     "以契约、流通和分散决策鼓励资源重新配置，家庭消费随之抬头。",
     [(T_CAP, 1.06), (T_SPEED, 1.04), (CONSUME, 1.02)]),
    ("scholar_office", "学识官署", "learning", 1, 1, "", "", [],
     "让记录、测量与专业知识成为公共决策的正式依据，行政耗费上升。",
     [(KNOW, 1.05), (R_SCI, 1.04), (INPUT, 1.02)]),
    ("standardization", "标准化", "industry", 1, 1, "", "", [],
     "统一度量、规格与零件，生产与建造都更省料，流通节奏却被规矩拖慢。",
     [(INPUT, 0.96), (B_COST, 0.96), (T_SPEED, 0.98)]),
    ("household_weaving", "家内纺织", "industry", 1, 1, "", "", [BAST_FIBER],
     "农妇在农隙纺麻织布，家庭收支多了一条底线，麻田与粮田开始争地。",
     [(G("cloth"), 1.08), (T("plain", "manufacturing"), 1.04),
      (T("plain", "agriculture"), 0.97)]),
    ("coppice_rotation", "轮伐", "harmony", 2, 1, "", "", [TIMBER],
     "分区伐取、留桩待萌，林木再生率大涨，短期木材产量却要退一步。",
     [(RREG(TIMBER), 1.20), (RUSE(TIMBER), 0.94), (G("logs"), 0.94)]),
    ("water_works", "治水营田", "harmony", 1, 1, "", "", [FLOODPLAIN],
     "修堤疏渠、引水灌田，把洪水变成可用的水利，工役耗费不轻。",
     [(FLOOD, 0.93), (T("floodplain", "agriculture"), 1.06), (B_COST, 1.03)]),
    ("seasonal_calendar", "寒暑历法", "harmony", 1, 1, "", "", [],
     "以节气指导农时与役使，寒暑异常的危害大为减轻，思辨的锐气稍减。",
     [(COLD, 0.94), (HEAT, 0.95), (PROFILE("dryland_crop", "drought"), 0.94),
      (POINTS, 0.97)]),

    # ── 王国时代 ────────────────────────────────────────────────────────────
    ("ever_normal_granary", "常平仓", "agrarian", 2, 2, "", "", [],
     "丰年籴入、歉年粜出，以官仓平抑粮价与饥荒，市面流通被官仓压住。",
     [(DEATH, 0.96), (T("plain", "agriculture"), 1.04), (DROUGHT, 0.95),
      (T_CAP, 0.97)]),
    ("settle_and_farm", "屯垦", "agrarian", 2, 2, "land_order", KINGDOM, [],
     "编户屯垦，把荒原与边地一并开成田，投入的农具与口粮同样惊人。",
     [(T("plain", "agriculture"), 1.06), (T("steppe", "agriculture"), 1.05),
      (INPUT, 1.03)]),
    ("open_ports", "市舶开港", "commerce", 1, 2, "", "", [COAST_LF],
     "设市舶司、开海口通商，货物周转加快，船料把林地消耗推高。",
     [(T_SPEED, 1.07), (T_CAP, 1.03), (RUSE(TIMBER), 1.03)]),
    ("guild_charters", "行会特许", "commerce", 2, 2, "labor_order", "", [],
     "以特许状给予行会定价与学徒制度，品质稳定而新建更贵。",
     [(MANU, 1.05), (T_CAP, 1.03), (B_COST, 1.03)]),
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
     [(GI("iron_ore"), 0.90), (G("tools"), 1.08), (RUSE(IRON), 1.06)]),
    ("postal_horse", "驿传", "mobilization", 2, 2, "", "", [HORSE],
     "沿官道设驿换马，政令与商旅同时提速，牧草挤掉了口粮田。",
     [(T_SPEED, 1.08), (G("horses"), 1.06), (G("wheat_grain"), 0.96)]),
    ("monsoon_farming", "汛期农法", "agrarian", 3, 2, "", "", [W_MONSOON],
     "按季风起落安排浸种与排水，水田的洪灾损失被压到最低，旱地却学不来。",
     [(PROFILE("paddy_crop", "flood"), 0.88), (LF("delta", "agriculture"), 1.06),
      (T("desert", "agriculture"), 0.95)]),
    ("river_transport", "漕运", "commerce", 2, 2, "", "", [RIVER_VALLEY],
     "沿河设闸、分段转运，粮货逆流而上，沿岸谷地的工坊随之兴旺，河工岁修是一笔长期账。",
     [(T_SPEED, 1.06), (T_CAP, 1.04), (T("floodplain", "manufacturing"), 1.05),
      (B_COST, 1.04)]),

    # ── 帝国时代 ────────────────────────────────────────────────────────────
    ("village_compact", "乡约自治", "agrarian", 3, 3, "", IMPERIAL, [],
     "以乡约、社仓与家族共治维系基层秩序，民心即是国本，流通却少了弹性。",
     [(AGRI, 1.05), (T("plain", "agriculture"), 1.04), (R_SOC, 1.04),
      (DEATH, 0.97), (T_CAP, 0.97)]),
    ("land_reclamation", "垦荒令", "agrarian", 2, 3, "land_order", "", [],
     "招民开垦河漫与绿洲，田亩既增，水土也开始吃紧。",
     [(T("floodplain", "agriculture"), 1.06), (T("oasis", "agriculture"), 1.05),
      (FLOOD, 1.03)]),
    ("granary_road", "漕运仓法", "commerce", 2, 3, "", "", [],
     "以运河与官仓串起粮道，丰歉在千里之间互相调剂，船料取于山林。",
     [(T_SPEED, 1.05), (T_CAP, 1.03), (DEATH, 0.98), (RUSE(TIMBER), 1.03)]),
    ("imperial_academy", "太学", "learning", 2, 3, "", "", [],
     "国家设学养士，注疏与考据成为可积累的公共知识，正统压住异说。",
     [(R_INST, 1.05), (R_COST, 0.97), (POINTS, 0.97)]),
    ("public_hygiene", "公共卫生", "mobilization", 2, 3, "", IMPERIAL, [],
     "清渠、隔离与种痘，把健康变成可以组织的公共事务，宅第造价随之上浮。",
     [(DEATH, 0.94), (PROFILE("dryland_crop", "heat_stress"), 0.96),
      (B_COST, 1.03)]),
    ("heaven_human", "天人相参", "harmony", 2, 3, "", IMPERIAL, [],
     "观天察地以定政令，对旱涝与农业规律的理解更加系统，实测精神被压制。",
     [(DROUGHT, 0.95), (FLOOD, 0.95), (R_AGRI, 1.05), (R_SCI, 0.97)]),
    ("salt_monopoly", "盐铁专营", "industry", 2, 3, "economic_order", "", [SALT],
     "国家专营盐池与铁冶，盐利充盈国库，私商与盐脉同受挤压。",
     [(G("salt"), 1.10), (RUSE(SALT), 1.08), (T_CAP, 0.97)]),
    ("sericulture", "蚕桑", "industry", 2, 3, "", "", [SILKWORM],
     "植桑养蚕、缫丝织锦，绢帛成了硬通货，桑田与粮田争地。",
     [(G("cloth"), 1.06), (G("fine_clothing"), 1.08),
      (T("plain", "agriculture"), 0.97)]),

    # ── 探索时代 ────────────────────────────────────────────────────────────
    ("ocean_company", "远洋公司", "commerce", 3, 4, "", GLOBAL, [],
     "以股份与特许组织远洋贸易，财富涌入也加速了船料与木林的消耗。",
     [(T_CAP, 1.07), (T_SPEED, 1.05), (RUSE(TIMBER), 1.04)]),
    ("chartered_route", "特许航路", "commerce", 2, 4, "economic_order", "", [C_MARITIME],
     "把航线、港口与补给点连成一张特许网络，香料与糖源源而来，盐业受挤。",
     [(G("spices"), 1.08), (T_CAP, 1.04), (G("salt"), 0.97)]),
    ("cartography", "舆图测绘", "learning", 2, 4, "", "", [COAST_LF],
     "以经纬、罗盘与实测修订海图，远航代价下降，测绘本身也是开销。",
     [(R_SCI, 1.04), (T_SPEED, 1.05), (B_COST, 1.02)]),
    ("colonial_plantation", "殖民种植园", "agrarian", 2, 4, "land_order", "", [MONSOON_BASIN],
     "以单一作物大规模开垦，产量惊人，地力与林地迅速被抽干。",
     [(T("jungle", "agriculture"), 1.10), (G("cotton_fiber"), 1.06),
      (RUSE(FERTILE), 1.08), (RREG(FERTILE), 0.92)]),
    ("silver_flow", "白银流入", "commerce", 3, 4, "economic_order", "", [SILVER],
     "海外白银持续涌入，物价与交易规模一起被推高，银矿被疯狂开采。",
     [(G("silver"), 1.08), (RUSE(SILVER), 1.10)]),
    ("natural_history", "博物志", "learning", 2, 4, "", "", [],
     "标本、分类与田野记录并行，农业与科学的边界开始相接，纯粹思辨退场。",
     [(R_SCI, 1.05), (R_AGRI, 1.04), (KNOW, 0.98)]),
    ("manufactory_regulation", "工场规程", "industry", 2, 4, "", "", [],
     "以工序章程约束手工工场，用料被重新安排，周转反被规矩拖慢。",
     [(G("metal_housewares"), 1.06), (INPUT, 0.97), (T_SPEED, 0.98)]),
    ("maritime_insurance", "海事保险", "commerce", 2, 4, "", "", [C_MARITIME],
     "分摊海难风险，远洋船队敢走更远的航线，保费最终摊到每一户的消费上。",
     [(T_CAP, 1.05), (CONSUME, 1.02)]),

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
     [(G("coal"), 1.10), (T("hill", "extractive"), 1.04), (RUSE(COAL), 1.06)]),
    ("cotton_gin", "轧棉", "industry", 2, 5, "", "", [COTTON],
     "以机械脱籽代替手工，棉花纤维的可用量大增，棉田挤占了粮田。",
     [(G("cotton_fiber"), 1.10), (T("plain", "manufacturing"), 1.04),
      (T("plain", "agriculture"), 0.97)]),
    ("enclosure", "圈地", "agrarian", 2, 5, "land_order", "", [],
     "以篱界并小块为牧场，畜产与牧草再生大增，小农与谷物让位。",
     [(T("grassland", "agriculture"), 1.08), (RREG(PASTURE_LAND), 1.10),
      (T("plain", "agriculture"), 0.96), (R_SOC, 0.97)]),
    ("learned_society", "学会", "learning", 2, 5, "", "", [],
     "以通信、期刊与同行评议组织学问，研究效率上升，会务与出版耗费不轻。",
     [(R_INST, 1.05), (POINTS, 1.05), (INPUT, 1.02)]),

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
     [(DEATH, 0.95), (PROFILE("dryland_crop", "flood"), 0.96), (B_COST, 1.03)]),
    ("steam_shipping", "汽船航运", "commerce", 2, 6, "", "", [],
     "定期汽船班轮取代风帆，贸易容量与速度同步上升，锅炉张着嘴烧煤。",
     [(T_CAP, 1.06), (T_SPEED, 1.04), (RUSE(COAL), 1.04)]),
    ("labour_legislation", "劳动立法", "mobilization", 2, 6, "labor_order", "", [],
     "限定工时、承认工会，工人税负与生活压力一并减轻，用工成本上升。",
     [(TAX("industrial_worker"), 0.95), (CONSUME, 1.02), (INPUT, 1.02)]),
    ("free_trade", "自由贸易", "commerce", 2, 6, "economic_order", "", [],
     "撤除关税壁垒，贸易容量大涨，本国制造在进口货面前没有遮拦。",
     [(T_CAP, 1.07), (T("plain", "manufacturing"), 0.97)]),
    ("agricultural_chemistry", "农业化学", "agrarian", 2, 6, "", "", [PHOSPHATE],
     "以磷矿与硝酸盐造肥，旱地单产大涨，矿源与水体同时承压。",
     [(T("plain", "agriculture"), 1.08), (G("fertilizer"), 1.06),
      (RUSE(PHOSPHATE), 1.08), (FLOOD, 1.02)]),
    ("telegraph", "电报", "learning", 2, 6, "", "", [],
     "以电线传递消息，商情与政令同时提速，线路维护是一笔常年开销。",
     [(T_SPEED, 1.05), (R_SOC, 1.03), (B_COST, 1.02)]),

    # ── 电气时代 ────────────────────────────────────────────────────────────
    ("assembly_line", "流水线", "industry", 3, 7, "", ELECTRIC, [],
     "以传送带与工序分解组织大规模生产，物料极省而原料吞吐陡增。",
     [(MANU, 1.07), (INPUT, 0.96), (RES_USE, 1.04)]),
    ("electrification", "电气化", "industry", 3, 7, "", "", [],
     "以电网覆盖城乡，动力可以远距离输送到每一台机器，发电仍靠烧煤。",
     [(G("electricity"), 1.10), (ENER, 1.05), (RUSE(COAL), 1.05)]),
    ("ecological_balance", "生态均衡", "harmony", 3, 7, "", ELECTRIC, [],
     "以循环与修复约束工业增长，资源与人口得到长期平衡，产能让步。",
     [(RES_USE, 0.94), (DEATH, 0.97), (MANU, 0.97)]),
    ("mass_media", "大众传媒", "learning", 2, 7, "", "", [],
     "报纸、广播与电影把同一套叙事送进每一个家庭，深度学问被稀释。",
     [(R_SOC, 1.05), (POINTS, 1.04), (KNOW, 0.98)]),
    ("chemical_industry", "化学工业", "industry", 2, 7, "", "", [SALT],
     "以电解与合成改写原料来源，盐卤变成化工之母，副产物污染水土。",
     [(G("industrial_chemicals"), 1.08), (GI("salt"), 0.94), (RUSE(SALT), 1.06)]),
    ("hydroelectric", "水电", "industry", 2, 7, "", "", [RIVER_VALLEY],
     "筑坝蓄水发电，谷地能源充沛，坝下平原的洪水风险反而上升。",
     [(ENER, 1.06), (LF("rift_valley", "energy"), 1.08), (FLOOD, 1.02)]),
    ("antitrust", "反垄断", "commerce", 2, 7, "economic_order", "", [],
     "拆分托拉斯、恢复竞争，物价与流通受益，规模效率被牺牲。",
     [(T_CAP, 1.04), (CONSUME, 0.98), (MANU, 0.97)]),

    # ── 原子时代 ────────────────────────────────────────────────────────────
    ("nuclear_power", "核电计划", "industry", 3, 8, "", "", [RARE_EARTH],
     "以核裂变集中供能，能源产出跃升，稀有矿料成为长期负担。",
     [(ENER, 1.08), (G("electricity"), 1.06), (RUSE(RARE_EARTH), 1.08)]),
    ("antibiotics", "抗生素", "harmony", 3, 8, "", "", [],
     "感染不再是绝症，人口的死亡水平被永久压低，医疗投入随之常态化。",
     [(DEATH, 0.92), (INPUT, 1.02)]),
    ("motorization", "汽车社会", "commerce", 2, 8, "", "", [],
     "公路与私家车重构了城市与市场的距离，燃油消耗同步飙升。",
     [(T_SPEED, 1.06), (G("automobiles"), 1.06), (RUSE(OIL), 1.06)]),
    ("green_revolution", "绿色革命", "agrarian", 3, 8, "", "", [GAS],
     "以合成氮肥、良种与灌溉把旱地单产推上台阶，天然气与磷矿被大量吃掉。",
     [(T("plain", "agriculture"), 1.10), (G("fertilizer"), 1.06),
      (RUSE(GAS), 1.08), (RUSE(PHOSPHATE), 1.06)]),
    ("petrochemical", "石化", "industry", 2, 8, "", "", [OIL],
     "以石油为原料生产塑料与合成纤维，原料端成本归零，油田压力加大。",
     [(G("plastics"), 1.08), (G("synthetic_fiber"), 1.06), (RUSE(OIL), 1.08)]),
    ("container_port", "集装箱港", "commerce", 2, 8, "", "", [COAST_LF],
     "标准箱与枢纽港把装卸成本压到接近为零，海岸带工厂直接贴上码头，深水泊位造价极高。",
     [(T_CAP, 1.08), (T_SPEED, 1.05), (T("coast", "manufacturing"), 1.05),
      (B_COST, 1.03)]),

    # ── 信息时代 ────────────────────────────────────────────────────────────
    ("computing_networks", "计算网络", "learning", 3, 9, "", "", [],
     "算力与网络成为公共基础设施，研究周期被整体压缩，机房耗电可观。",
     [(R_SCI, 1.06), (R_ENG, 1.05), (B_COST, 1.02)]),
    ("semiconductor", "半导体", "industry", 3, 9, "", "", [SILICA],
     "以高纯硅与精密光刻重塑制造业，硅砂被纯化成稀缺料。",
     [(G("semiconductors"), 1.10), (RUSE(SILICA), 1.08)]),
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

# school -> (tier-2 terms, tier-4 terms)
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

PROFILE = {
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
    # Upload of card effect rows routed through a declared ideology.effect.*
    # program, counted over the whole catalog (one per card level). 85 cards x 3
    # levels = 255, so the old 128 could never hold a program-backed catalog.
    # Live concurrency is bounded by slots x SELECTOR_MAX_CELLS instead.
    "max_effect_instances": 512,
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


def effect_block(res_id: str, definition_key: str, magnitude: int) -> str:
    return (f'[sub_resource type="Resource" id="{res_id}"]\n'
            'script = ExtResource("7_effect")\n'
            'action = 1\ndomain = 1\nopcode = 1\ntarget_resolver = 1\nvalue_mode = 0\n'
            f'value_q16 = {magnitude}\nduration_days = -1\n'
            'command_key = &"ideology.persistent"\n'
            f'definition_key = &"{definition_key}"\n')


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
)
_NEUTRAL_KEYS = (
    "country.tax.",                           # burden on one side, revenue on the other
)


def _is_cost_stat(stat: str) -> bool:
    return any(stat == key or key in stat for key in _COST_DIRECTION_KEYS)


def _is_neutral_slot(stat: str) -> bool:
    return any(key in stat for key in _NEUTRAL_KEYS)


def _is_downside(stat: str, value: float) -> bool:
    """True when this term is bad for the player, i.e. it pays a price."""
    if _is_neutral_slot(stat):
        return False
    return value > 1.0 if _is_cost_stat(stat) else value < 1.0


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


def build_ideology_catalog() -> str:
    blocks: list[str] = []
    profile_lines = ['[sub_resource type="Resource" id="Profile"]',
                     'script = ExtResource("2_profile")']
    for key, value in PROFILE.items():
        profile_lines.append(f"{key} = {value}")
    profile_lines.append("capacity_unlock_technology_keys = PackedStringArray(%s)" %
                         ", ".join(f'"{tech}"' for tech, _, _ in CAPACITY_UNLOCKS))
    profile_lines.append("capacity_unlock_ideology_deltas = PackedInt32Array(%s)" %
                         ", ".join(str(delta) for _, delta, _ in CAPACITY_UNLOCKS))
    profile_lines.append("capacity_unlock_spirit_deltas = PackedInt32Array(%s)" %
                         ", ".join(str(delta) for _, _, delta in CAPACITY_UNLOCKS))
    profile_lines.append('point_gain_stat_key = &"country.ideology.point_gain_factor"')
    blocks.append("\n".join(profile_lines) + "\n")
    definition_ids: list[str] = []
    for key, name, school, rarity, era, exclusion, tech, signals, detail, _terms in CARDS:
        base = camel(key)
        level_ids = []
        for level, magnitude in enumerate(LEVEL_MAGNITUDES):
            effect_id = f"Effect{base}L{level + 1}"
            blocks.append(effect_block(effect_id, f"ideology.{key}", magnitude))
            level_id = f"Level{base}L{level + 1}"
            blocks.append(
                f'[sub_resource type="Resource" id="{level_id}"]\n'
                'script = ExtResource("4_level")\n'
                f"understanding_threshold_q16 = {LEVEL_THRESHOLDS[level]}\n"
                f"daily_understanding_q16 = {LEVEL_DAILY[level]}\n"
                f'persistent_effects = Array[Resource]([SubResource("{effect_id}")])\n')
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
        blocks.append(
            f'[sub_resource type="Resource" id="{definition_id}"]\n'
            'script = ExtResource("3_definition")\n'
            f'id = &"idea.{key}"\n'
            f'icon_key = &"{SCHOOL_ICONS[school]}"\n'
            f'name_key = &"{name}"\n'
            f'detail_key = "{detail}"\n'
            f'school_id = &"{school}"\n'
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
    for school in SCHOOL_ORDER:
        cards = [card[0] for card in CARDS if card[2] == school]
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
    ]
    load_steps = len(ext) + len(blocks) + 1
    resource = (
        "[resource]\n"
        'script = ExtResource("1_catalog")\n'
        'profile = SubResource("Profile")\n'
        "definitions = Array[Resource]([%s])\n" % ", ".join(
            f'SubResource("{item}")' for item in definition_ids) +
        "synergies = Array[Resource]([%s])\n" % ", ".join(
            f'SubResource("{item}")' for item in synergy_ids))
    header = f'[gd_resource type="Resource" script_class="IdeologyCatalog" load_steps={load_steps} format=3]\n'
    return header + "\n" + "\n".join(ext) + "\n\n" + "\n".join(blocks) + "\n" + resource


def modifier_blocks() -> tuple[list[str], list[str]]:
    blocks: list[str] = []
    definition_ids: list[str] = []

    def add(def_id: str, key: str, name: str, description: str, terms) -> None:
        term_ids = []
        for index, (stat, value) in enumerate(terms):
            term_id = f"TermIdeology{def_id}{index}"
            term_ids.append(term_id)
            blocks.append(
                f'[sub_resource type="Resource" id="{term_id}"]\n'
                'script = ExtResource("4_term")\n'
                f'stat_key = &"{stat}"\noperation = 2\nvalue = {fmt_value(value)}\n')
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

    for key, name, _school, _rarity, _era, _exclusion, _tech, _signals, detail, terms in CARDS:
        add(camel(key), f"ideology.{key}", name, detail, terms)
    for key, name, _cards, terms in NAMED_SYNERGIES:
        add("Synergy" + camel(key), f"ideology.synergy.{key}", name, f"{name}联动修正。", terms)
    for school in SCHOOL_ORDER:
        for count, terms in zip((2, 4), RESONANCES[school]):
            add(f"Resonance{camel(school)}{count}", f"ideology.resonance.{school}.{count}",
                f"{SCHOOL_NAMES[school]}共鸣{count}",
                f"装备或晋升{count}张{SCHOOL_NAMES[school]}理念。", terms)
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
    for key, _name, school, rarity, era, _exclusion, tech, signals, _detail, terms in CARDS:
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
        if not terms:
            raise SystemExit("card %s has no modifier terms" % key)
        has_cost = False
        for stat, value in terms:
            if stat in DEAD_STAT_KEYS:
                raise SystemExit(
                    "card %s uses dead stat %r; nothing consumes it" % (key, stat))
            if stat not in allowed_stats:
                raise SystemExit(
                    "card %s uses stat %r that the modifier catalog never declares"
                    % (key, stat))
            # Cost stats invert: a bigger resource burn or hazard loss is bad,
            # so >1.0 is the downside there and <1.0 is the downside elsewhere.
            if _is_downside(stat, value):
                has_cost = True
        if not has_cost:
            raise SystemExit(
                "card %s has no downside term; a card with only buffs flattens the pool"
                % key)
    coverage: dict[str, int] = {}
    for row in CARDS:
        kinds = {object_kind(stat) for stat, _value in row[9]}
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


def main() -> None:
    validate_cards()
    IDEOLOGY_PATH.write_text(build_ideology_catalog(), encoding="utf-8", newline="\n")
    rewrite_modifier_catalog()
    print(f"named={len(NAMED_SYNERGIES)} resonances={len(RESONANCES) * 2}")


if __name__ == "__main__":
    main()
