"""Generate the default ideology catalog and its Modifier definitions.

Authoritative content table for the 30-card / 6-school ideology pool. Running
this script rewrites:
  * data/ideologies/default_ideology_catalog.tres (fully generated)
  * the ideology section of data/modifiers/default_modifier_catalog.tres
    (every sub_resource whose id starts with TermIdeology/DefIdeology)

Usage (from Project/project-keynes): python tools/ideology/generate_ideology_catalog.py
"""
from __future__ import annotations

import pathlib
import re

ROOT = pathlib.Path(__file__).resolve().parents[2]
IDEOLOGY_PATH = ROOT / "data/ideologies/default_ideology_catalog.tres"
MODIFIER_PATH = ROOT / "data/modifiers/default_modifier_catalog.tres"

Q16 = 65536
LEVEL_THRESHOLDS = [0, 262144, 786432]          # 0 / 4.0 / 12.0 understanding
LEVEL_DAILY = [8192, 4096, 0]                   # 0.125 / 0.0625 / 0 per day
LEVEL_MAGNITUDES = [65536, 104858, 144179]      # 1.0x / 1.6x / 2.2x
RARITY_WEIGHTS = {1: 120, 2: 60, 3: 20}
ADOPT_THRESHOLD = {1: 4096, 2: 8192, 3: 12288}
PROMOTE_THRESHOLD = {1: 16384, 2: 20480, 3: 24576}

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
    ("total_mobilization", "worker"): {"adopt_min_support_q16": 0},
}
SCHOOL_ICONS = {
    "agrarian": "country.economy", "commerce": "country.trade",
    "learning": "country.technology", "mobilization": "country.military",
    "industry": "country.industry", "harmony": "country.climate",
}

AGRI = "country.output.agriculture_factor"
EXTR = "country.output.extractive_factor"
MANU = "country.output.manufacturing_factor"
ENER = "country.output.energy_factor"
KNOW = "country.output.knowledge_factor"
ECON = "country.economy_output_factor"
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
B_TIME = "country.construction.time_factor"
T_CAP = "country.trade.capacity_factor"
T_SPEED = "country.trade.speed_factor"
DROUGHT = "country.climate.drought_loss_factor"
FLOOD = "country.climate.flood_loss_factor"
COLD = "country.climate.cold_stress_factor"
HEAT = "country.climate.heat_stress_factor"
POINTS = "country.ideology.point_gain_factor"

KINGDOM = "tech.kingdom_administration"
IMPERIAL = "tech.imperial_integration"
GLOBAL = "tech.global_exchange"
ENLIGHT = "tech.enlightenment_institutions"
INDUSTRIAL = "tech.industrialization"
ELECTRIC = "tech.electrical_society"

# (key, name, school, rarity, exclusion, tech, detail, [(stat, level-1 value)])
# Level-1 deltas stay within 3%..7% so level 3 (2.2x) stays within ~15%.
CARDS = [
    # 农本
    ("collective_stewardship", "共同体治理", "agrarian", 1, "economic_order", "",
     "以共同仓储、互助义务和长期土地责任组织生产。",
     [(AGRI, 1.05), (DROUGHT, 0.95)]),
    ("intensive_tillage", "精耕细作", "agrarian", 1, "land_order", "",
     "深耕、轮作与精细田管提高地力，但要投入更多耕作物资。",
     [(AGRI, 1.07), (INPUT, 1.02)]),
    ("ever_normal_granary", "常平仓", "agrarian", 2, "", "",
     "丰年籴入、歉年粜出，以官仓平抑粮价与饮荒。",
     [(DEATH, 0.96), (DROUGHT, 0.95), (FLOOD, 0.97)]),
    ("military_farming", "屯田", "agrarian", 2, "land_order", KINGDOM,
     "编户屯垦，兵农合一，边地与荒地都能迅速开发。",
     [(AGRI, 1.04), (B_TIME, 0.95), (CONSUME, 1.02)]),
    ("village_compact", "乡约自治", "agrarian", 3, "", IMPERIAL,
     "以乡约、社仓与家族共治维系基层秩序，民心即是国本。",
     [(AGRI, 1.05), (R_SOC, 1.05), (DEATH, 0.97), (POINTS, 1.05)]),
    # 商贸
    ("free_exchange", "自由交换", "commerce", 1, "economic_order", "",
     "以契约、流通和分散决策鼓励资源重新配置。",
     [(T_CAP, 1.06), (T_SPEED, 1.04)]),
    ("open_ports", "市舶开港", "commerce", 1, "", "",
     "设市舶司、开海口通商，货物周转加快，民间消费也随之抬头。",
     [(T_SPEED, 1.07), (T_CAP, 1.03), (CONSUME, 1.02)]),
    ("guild_charters", "行会特许", "commerce", 2, "labor_order", "",
     "以特许状给予行会定价与学徒制度，品质稳定而新建更贵。",
     [(MANU, 1.05), (T_CAP, 1.03), (B_COST, 1.03)]),
    ("double_entry", "复式簿记", "commerce", 2, "", KINGDOM,
     "借贷必相等，账目透明让工坊与商号都能精打细算。",
     [(INPUT, 0.96), (T_CAP, 1.03), (ECON, 1.02)]),
    ("ocean_company", "远洋公司", "commerce", 3, "", GLOBAL,
     "以股份与特许组织远洋贸易，财富涌入也加速资源耗用。",
     [(T_CAP, 1.07), (T_SPEED, 1.05), (ECON, 1.03), (RES_USE, 1.03)]),
    # 学识
    ("scholar_office", "学识官署", "learning", 1, "", "",
     "让记录、测量与专业知识成为公共决策的正式依据。",
     [(KNOW, 1.05), (R_SCI, 1.04)]),
    ("academy_lectures", "书院讲学", "learning", 1, "", "",
     "书院讲会，辞辩争鸣，民间对国家道路的理解更加深入。",
     [(R_SOC, 1.05), (KNOW, 1.03), (POINTS, 1.06)]),
    ("experimental_method", "实验之法", "learning", 2, "", ENLIGHT,
     "以可重复的实验代替权威，工程与自然研究同步大进。",
     [(R_SCI, 1.06), (R_ENG, 1.05)]),
    ("civil_examination", "科举取士", "learning", 2, "", KINGDOM,
     "以考试选拔官员，学风大盛，家庭也更愿意为教育花钱。",
     [(R_COST, 0.96), (R_SOC, 1.03), (CONSUME, 1.02)]),
    ("encyclopedia", "百科全书", "learning", 3, "", ENLIGHT,
     "把天下之学编为一部可查可证的书，知识的流通从此不可逆。",
     [(R_INST, 1.06), (KNOW, 1.05), (R_COST, 0.97), (POINTS, 1.08)]),
    # 动员
    ("civic_muster", "公民动员", "mobilization", 1, "labor_order", "",
     "以普遍义务和基层组织换取危机中的快速协同。",
     [(B_TIME, 0.95), (MANU, 1.03)]),
    ("corvee_law", "劳役法", "mobilization", 1, "labor_order", "",
     "以法定役期征发民力兴修工程，工程更省，民力却更疲。",
     [(B_COST, 0.94), (B_TIME, 0.97), (DEATH, 1.02)]),
    ("public_hygiene", "公共卫生", "mobilization", 2, "", IMPERIAL,
     "清渠、隔离与种痘，把健康变成可以组织的公共事务。",
     [(DEATH, 0.94), (HEAT, 0.96), (COLD, 0.97)]),
    ("national_education", "国民教育", "mobilization", 2, "", ENLIGHT,
     "义务教育塑造统一语言与技艺，工程与社会研究受益。",
     [(R_SOC, 1.05), (R_ENG, 1.03), (CONSUME, 1.02), (POINTS, 1.04)]),
    ("total_mobilization", "总体动员", "mobilization", 3, "", INDUSTRIAL,
     "把全部社会资源编入一张计划表，生产与建设都在口号声中提速。",
     [(MANU, 1.06), (B_TIME, 0.93), (CONSUME, 0.96), (DEATH, 1.02)]),
    # 工造
    ("workshop_system", "工场制度", "industry", 1, "", "",
     "把分散的手工业集中到工场，产量上升，物料消耗也更大。",
     [(MANU, 1.06), (INPUT, 1.02)]),
    ("standardization", "标准化", "industry", 1, "", "",
     "统一度量、规格与零件，生产与建造都更省料。",
     [(INPUT, 0.97), (B_COST, 0.97)]),
    ("mining_monopoly", "矿冶专营", "industry", 2, "economic_order", "",
     "国家专营盐铁矿冶，采掘大兴，山林矿藏也消耗更快。",
     [(EXTR, 1.07), (ECON, 1.02), (RES_USE, 1.03)]),
    ("steam_power", "蒸汽动力", "industry", 2, "", INDUSTRIAL,
     "以蒸汽机取代水力与畜力，能源与制造同时跃进。",
     [(ENER, 1.06), (MANU, 1.03), (RES_USE, 1.02)]),
    ("assembly_line", "流水线", "industry", 3, "", ELECTRIC,
     "以传送带与工序分解组织大规模生产，工业节奏从此改写。",
     [(MANU, 1.07), (B_TIME, 0.95), (INPUT, 0.97)]),
    # 调和
    ("forest_marsh_ban", "林泽禁令", "harmony", 1, "land_order", "",
     "按时入山林、禁竭泽而渔，资源得以休养，采掘稍受限制。",
     [(RES_USE, 0.95), (EXTR, 0.98)]),
    ("water_works", "治水营田", "harmony", 1, "", "",
     "修堤疏渠、引水灌田，把洪水变成可用的水利。",
     [(FLOOD, 0.94), (AGRI, 1.03)]),
    ("seasonal_calendar", "寒暑历法", "harmony", 2, "", "",
     "以节气指导农时与役使，寒暑异常的危害大大减轻。",
     [(COLD, 0.94), (HEAT, 0.95)]),
    ("heaven_human", "天人相参", "harmony", 2, "", IMPERIAL,
     "观天察地以定政令，对旱涝与农业规律的理解更加系统。",
     [(DROUGHT, 0.95), (FLOOD, 0.95), (R_AGRI, 1.05)]),
    ("ecological_balance", "生态均衡", "harmony", 3, "", ELECTRIC,
     "以循环与修复约束工业增长，资源、人口与能源得到长期平衡。",
     [(RES_USE, 0.94), (DEATH, 0.97), (ENER, 1.03), (DROUGHT, 0.96)]),
]

# (key, name, [card keys], [(stat, value)])
NAMED_SYNERGIES = [
    ("planned_granaries", "计划仓廩", ["collective_stewardship", "scholar_office"],
     [(DROUGHT, 0.95), (AGRI, 1.03)]),
    ("chartered_frontier", "特许开拓", ["free_exchange", "civic_muster"],
     [(T_CAP, 1.04), (B_TIME, 0.96)]),
    ("maritime_ledger", "海商账簿", ["ocean_company", "double_entry"],
     [(T_CAP, 1.05), (R_COST, 0.98)]),
    ("engineering_corps", "工役营造", ["standardization", "corvee_law"],
     [(B_COST, 0.95), (B_TIME, 0.97)]),
    ("industrial_science", "工业科学", ["experimental_method", "steam_power"],
     [(ENER, 1.04), (R_ENG, 1.04)]),
    ("river_commune", "河渠公社", ["water_works", "military_farming"],
     [(FLOOD, 0.95), (AGRI, 1.03)]),
]

# school -> (tier-2 terms, tier-4 terms)
RESONANCES = {
    "agrarian": ([(AGRI, 1.03)], [(AGRI, 1.04), (DEATH, 0.97)]),
    "commerce": ([(T_CAP, 1.03)], [(T_SPEED, 1.05), (ECON, 1.02)]),
    "learning": ([(R_SCI, 1.03), (R_SOC, 1.03)], [(R_COST, 0.95), (POINTS, 1.10)]),
    "mobilization": ([(B_TIME, 0.97)], [(B_COST, 0.95), (DEATH, 0.98)]),
    "industry": ([(MANU, 1.03)], [(INPUT, 0.96), (ENER, 1.03)]),
    "harmony": ([(RES_USE, 0.97)], [(DROUGHT, 0.96), (FLOOD, 0.96), (COLD, 0.96), (HEAT, 0.96)]),
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


def build_ideology_catalog() -> str:
    blocks: list[str] = []
    profile_lines = ['[sub_resource type="Resource" id="Profile"]', 'script = ExtResource("2_profile")']
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
    for key, name, school, rarity, exclusion, tech, detail, _terms in CARDS:
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
        requirement_line = ""
        if tech:
            requirement_id = f"Require{base}"
            blocks.append(
                f'[sub_resource type="Resource" id="{requirement_id}"]\n'
                'script = ExtResource("8_requirement")\n'
                f'kind = 1\nkey = &"{tech}"\n')
            requirement_line = f'draw_requirements = Array[Resource]([SubResource("{requirement_id}")])\n'
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

    for key, name, _school, _rarity, _exclusion, _tech, detail, terms in CARDS:
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


def main() -> None:
    IDEOLOGY_PATH.write_text(build_ideology_catalog(), encoding="utf-8", newline="\n")
    rewrite_modifier_catalog()
    print(f"cards={len(CARDS)} named={len(NAMED_SYNERGIES)} resonances={len(RESONANCES) * 2}")


if __name__ == "__main__":
    main()
