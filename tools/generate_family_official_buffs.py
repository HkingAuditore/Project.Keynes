#!/usr/bin/env python3
"""Compile family_official_buffs.json from the official Buff table.

Player-facing copy (preference placeholders and prestige-tier statements)
comes from family_official_buffs.md. Mechanical selectors stay in this
script. Preference 随机出现条件 is compiled into prerequisite_technology_keys.
Disjunctions (“A”或“B”) set prerequisite_technology_any. Resolves technology
display_name to stable technology ids.
"""
from __future__ import annotations

import json
import re
import sys
from pathlib import Path

Q16 = 65536
ROOT = Path(__file__).resolve().parents[1]
TECH_PATH = ROOT / "Project/project-keynes/data/technology/technology_network.json"
OUT_PATH = ROOT / "Project/project-keynes/data/economy/family_official_buffs.json"
DESIGN_PATH = ROOT / "Project/project-keynes/data/economy/family_official_buffs.md"
BUILDING_DIR = ROOT / "Project/project-keynes/data/economy/buildings"
GOOD_DIR = ROOT / "Project/project-keynes/data/goods"
PROFESSION_DIR = ROOT / "Project/project-keynes/data/economy/professions"
NEED_DIR = ROOT / "Project/project-keynes/data/economy/needs"
RESOURCE_DIR = ROOT / "Project/project-keynes/data/resources"

AXIS_INVEST = 0
AXIS_CAREER = 1
AXIS_NEED = 2
AXIS_GOOD = 3
SEL_STABLE = 0
SEL_SECTOR = 1
SEL_TAG = 4
SCORE_WEIGHT = 0
SCORE_TAX = 1
SCORE_ABUNDANCE = 2
SCORE_TIER = 3
SCORE_POPULAR = 4
SCORE_MOBILITY = 5
OP_GTE = 2
OP_LTE = 3
OP_EQ = 4
OP_AND = 6
LF_HILL = 6
LF_MOUNTAIN = 7
LF_PEAK = 8
LF_DELTA = 9
COLD_LINE = 22938  # ~0.35
GATE_WATER = 1
GATE_TAX = 2

MINERAL_IDENTIFICATION_TECHS = [
    "铁矿辨识", "自然铜辨识", "锡矿辨识", "砂金辨识", "地表银脉辨识", "露头煤辨识",
]
MINING_IDENTIFICATION_TECHS = MINERAL_IDENTIFICATION_TECHS + ["石油开采"]
TRADE_POOL_TECHS = ["早期贸易"]
INDUSTRY_POOL_TECHS = ["农耕时代"]
KNOWLEDGE_POOL_TECHS = ["文字"]
FISHERY_TECHS = ["淡水岸捕", "潮间带采集"]

SRC_POOL = 1
SRC_COUNTRY = 5
DOM_FAMILY = 0
DOM_CELL = 2
DOM_COUNTRY = 3
DOM_BUILDING = 5
OP_ADD = 0
OP_MUL = 1
OP_EVENT = 4
LIFE_PERM = 0
LIFE_DUR = 1
LIFE_ONCE = 2
STACK_REPLACE = 0
STACK_REFRESH = 1
STACK_ADD = 2
SEL_OWNER = 0
SEL_CELL = 2
SEL_COUNTRY = 3
SEL_ID = 5
SEL_R1 = 6
SEL_R2 = 7


PRESTIGE_LABELS = ("威望Ⅰ", "威望Ⅱ", "威望Ⅲ", "威望Ⅳ", "威望Ⅴ")
TRAIT_ID_RE = re.compile(r"^([cij]\d{3})_", re.IGNORECASE)


def q16(frac: float) -> int:
    return int(round(frac * Q16))


def _table_cells(line: str) -> list[str]:
    stripped = line.strip()
    if not stripped.startswith("|"):
        return []
    parts = [part.strip() for part in stripped.strip("|").split("|")]
    if not parts or all(set(part) <= {"-", ":"} for part in parts):
        return []
    return parts


def split_prestige_statements(full: str) -> list[str]:
    text = full.replace("<br>", "\n").replace("<br/>", "\n").replace("<br />", "\n")
    starts: list[int] = []
    for label in PRESTIGE_LABELS:
        index = text.find(label)
        if index < 0:
            raise SystemExit(f"prestige statement missing {label}: {full[:80]}")
        starts.append(index)
    statements: list[str] = []
    for i, start in enumerate(starts):
        end = starts[i + 1] if i + 1 < len(starts) else len(text)
        statements.append(text[start:end].strip())
    return statements


def load_design_copy(path: Path) -> tuple[dict[str, dict], dict[str, dict]]:
    if not path.is_file():
        raise SystemExit(f"missing design markdown: {path}")
    traits: dict[str, dict] = {}
    effects: dict[str, dict] = {}
    for raw_line in path.read_text(encoding="utf-8").splitlines():
        cells = _table_cells(raw_line)
        if len(cells) < 5:
            continue
        row_id = cells[0]
        if row_id in {"ID", "----"} or row_id.startswith("-"):
            continue
        name = cells[1]
        if re.fullmatch(r"[CIJ]\d{3}", row_id) and len(cells) >= 5:
            traits[row_id] = {
                "id": row_id,
                "display_name": name,
                "appearance_condition": cells[2],
                "description_template": cells[3],
                "range_text": cells[4],
            }
        elif re.fullmatch(r"E\d{3}", row_id) and len(cells) >= 10:
            full = cells[9]
            effects[name] = {
                "id": row_id,
                "display_name": name,
                "condition": cells[2],
                "target": cells[3],
                "prestige_results": cells[4:9],
                "prestige_descriptions": split_prestige_statements(full),
                "description": "\n".join(split_prestige_statements(full)),
            }
    if len(traits) != 98:
        raise SystemExit(f"design markdown expected 98 traits, got {len(traits)}")
    if len(effects) != 48:
        raise SystemExit(f"design markdown expected 48 effects, got {len(effects)}")
    return traits, effects


APPEARANCE_QUOTE_RE = re.compile(r"“([^”]+)”")
APPEARANCE_ERA_RE = re.compile(r"进入([^，。；、]+时代)")


def apply_appearance_techs(row: dict) -> None:
    """Compile preference 随机出现条件 into technology gates.

    Quoted unlock names and era entries replace any coarser techs= list so the
    design table stays the source of truth. A line with 或 and at least two
    quoted names becomes an ANY gate.
    """
    condition = str(row.get("appearance_condition", "")).strip()
    if not condition or condition in {"—", "-"}:
        return
    quotes = APPEARANCE_QUOTE_RE.findall(condition)
    if "或" in condition and len(quotes) >= 2:
        names: list[str] = []
        for name in quotes:
            if name and name not in names:
                names.append(name)
        row["tech_names"] = names
        row["tech_any"] = True
        return
    eras = APPEARANCE_ERA_RE.findall(condition)
    names: list[str] = []
    for name in quotes + eras:
        if name and name not in names:
            names.append(name)
    if names:
        row["tech_names"] = names


def apply_design_copy(traits: list[dict], effects: list[dict]) -> None:
    trait_copy, effect_copy = load_design_copy(DESIGN_PATH)
    for row in traits:
        key = str(row["key"])
        matched = TRAIT_ID_RE.match(key)
        if matched is None:
            raise SystemExit(f"trait key missing design id: {key}")
        design_id = matched.group(1).upper()
        design = trait_copy.get(design_id)
        if design is None:
            raise SystemExit(f"design markdown missing trait {design_id} for {key}")
        if design["display_name"] != row["display_name"]:
            raise SystemExit(
                f"trait {key} name {row['display_name']} != {design['display_name']}")
        template = design["description_template"]
        range_text = design["range_text"]
        row["description_template"] = template
        row["range_text"] = range_text
        row["appearance_condition"] = design["appearance_condition"]
        row["description"] = template
    for row in effects:
        name = str(row["display_name"])
        design = effect_copy.get(name)
        if design is None:
            raise SystemExit(f"design markdown missing effect {name}")
        row["description"] = design["description"]
        row["prestige_descriptions"] = design["prestige_descriptions"]
        row["appearance_condition"] = design["condition"]
        row["target_copy"] = design["target"]


def bonus_range(lo: float, hi: float) -> tuple[int, int, int, int]:
    """strength maps onto bonus fraction when preferred factor is 2*Q16."""
    lo_q = max(0, min(q16(lo), 4 * Q16))
    hi_q = max(lo_q, min(q16(hi), 4 * Q16))
    step = 4096
    if hi_q > lo_q and hi_q - lo_q < step:
        step = max(1, hi_q - lo_q)
    return lo_q, hi_q, step, 2 * Q16


def reduce_range(lo: float, hi: float) -> tuple[int, int, int, int]:
    lo_q = max(0, min(q16(lo), 4 * Q16))
    hi_q = max(lo_q, min(q16(hi), 4 * Q16))
    step = 4096 if hi_q - lo_q >= 4096 else max(1, hi_q - lo_q)
    return lo_q, hi_q, step, 0


def load_tech_map() -> dict[str, str]:
    data = json.loads(TECH_PATH.read_text(encoding="utf-8"))
    names: dict[str, str] = {}
    for era in data.get("eras", []):
        display = str(era.get("display_name", "")).strip()
        milestone = str(era.get("milestone_id", "")).strip()
        if display and milestone:
            names[display] = milestone
    for node in data.get("technologies", data.get("nodes", [])):
        if not isinstance(node, dict):
            continue
        display = str(node.get("display_name", "")).strip()
        node_id = str(node.get("id", "")).strip()
        if display and node_id and display not in names:
            names[display] = node_id
    # Flatten nested technology lists if schema uses "technologies" array of objects.
    def walk(obj):
        if isinstance(obj, dict):
            if "id" in obj and str(obj["id"]).startswith("tech.") and "display_name" in obj:
                display = str(obj["display_name"]).strip()
                node_id = str(obj["id"]).strip()
                if display and node_id and display not in names:
                    names[display] = node_id
            for value in obj.values():
                walk(value)
        elif isinstance(obj, list):
            for item in obj:
                walk(item)

    walk(data)
    return names


def catalog_ids(folder: Path) -> set[str]:
    found: set[str] = set()
    if not folder.is_dir():
        return found
    for path in folder.glob("*.tres"):
        for line in path.read_text(encoding="utf-8").splitlines():
            line = line.strip()
            if line.startswith("id = &\"") and line.endswith("\""):
                found.add(line[len("id = &\""):-1])
                break
    return found


def resolve_techs(tech_map: dict[str, str], names: list[str]) -> list[str]:
    out = []
    for name in names:
        if name.startswith("tech."):
            out.append(name)
            continue
        if name not in tech_map:
            raise SystemExit(f"unknown technology display_name: {name}")
        out.append(tech_map[name])
    return sorted(set(out))


def cond(op: int, arg0: int, value: int) -> dict:
    return {"op": op, "arg0": arg0, "value_q16": value}


def behavior(axis: int, selector_id: str, factor: int, kind: int = SEL_STABLE,
             score: int = SCORE_WEIGHT, conditions: list | None = None) -> dict:
    row = {
        "axis": axis,
        "selector_kind": kind,
        "selector_id": selector_id,
        "factor_q16": factor,
        "score_term": score,
    }
    if conditions:
        row["conditions"] = conditions
    return row


def trait(key: str, name: str, desc: str, behaviors: list, *,
          techs: list | None = None, exclusions: list | None = None,
          lo: float = 0.15, hi: float = 0.40, reduce: bool = False,
          weight: int = 100, landforms: list | None = None,
          water: bool = False, pop_max: int = 0, temp_max: int = -1,
          resources: list | None = None, tax: bool = False,
          tech_any: bool = False) -> dict:
    if reduce:
        smin, smax, step, factor = reduce_range(lo, hi)
    else:
        smin, smax, step, factor = bonus_range(lo, hi)
    for row in behaviors:
        if "factor_q16" not in row or row.get("factor_q16") is None:
            row["factor_q16"] = factor
        elif row["factor_q16"] < 0:
            row["factor_q16"] = factor
    return {
        "key": key,
        "display_name": name,
        "description": desc,
        "weight": weight,
        "core_eligible": True,
        "tech_names": techs or [],
        "tech_any": bool(tech_any),
        "exclusion_keys": exclusions or [],
        "strength_min_q16": smin,
        "strength_max_q16": smax,
        "strength_step_q16": step,
        "origin_landforms": landforms or [],
        "origin_adjacent_water": water,
        "origin_population_max": pop_max,
        "origin_temperature_max_q16": temp_max,
        "required_resource_ids": resources or [],
        "require_tax_or_subsidy": tax,
        "behaviors": behaviors,
    }


def mag_prestige(scale: float = 1.0) -> list[int]:
    steps = [0.70, 0.82, 0.94, 1.06, 1.18, 1.30]
    return [max(0, min(4 * Q16, q16(v * scale))) for v in steps]


def dummy_program() -> list[dict]:
    return [{"op": 1, "arg0": 0, "value_q16": Q16}, {"op": 12, "arg0": 0, "value_q16": 0}]


def mod_cmd(definition_key: str, domain: int = 2, duration: int = -1, stacks: int = 1) -> dict:
    return {
        "action": 1,
        "domain": domain,
        "opcode": 1,
        "target_resolver": 1,
        "command_key": definition_key,
        "definition_key": definition_key,
        "duration_days": duration,
        "stacks": stacks,
        "value_mode": 1,
    }


def econ_cmd(opcode: int, command_key: str, people: int = 8) -> dict:
    return {
        "action": 3,
        "domain": 2,
        "opcode": opcode,
        "target_resolver": 1,
        "command_key": command_key,
        "duration_days": -1,
        "stacks": 1,
        "value_mode": 0,
        "value_q16": people,
    }


def effect(key: str, name: str, desc: str, *,
           source: int = SRC_POOL, domain: int = DOM_CELL, operation: int = OP_MUL,
           lifecycle: int = LIFE_PERM, duration: int = -1, stack: int = STACK_REPLACE,
           selector: int = SEL_CELL, selector_id: str = "", max_stacks: int = 1,
           commands: list | None = None, exclusions: list | None = None,
           techs: list | None = None, conditions: list | None = None,
           triggers: list | None = None, reward: int = 0, weight: int = 100,
           cadence: int = 1, tech_any: bool = False) -> dict:
    row = {
        "key": key,
        "display_name": name,
        "description": desc,
        "weight": weight,
        "source_kind": source,
        "target_domain": domain,
        "operation": operation,
        "lifecycle": lifecycle,
        "duration_days": duration,
        "stack_policy": stack,
        "max_stacks": max_stacks,
        "target_selector_kind": selector,
        "target_selector_id": selector_id,
        "exclusion_keys": exclusions or [],
        "tech_names": techs or [],
        "tech_any": bool(tech_any),
        "magnitude_by_prestige_q16": mag_prestige(),
        "commands": commands or [],
        "instructions": dummy_program() if not commands else [
            {"op": 2, "arg0": 0, "value_q16": 0},
            {"op": 11, "arg0": 0, "value_q16": 0},
            {"op": 12, "arg0": 0, "value_q16": 0},
        ],
        "trigger_definition_keys_by_tier": triggers or [],
        "trigger_reward_target": reward,
        "cadence_days": cadence,
    }
    if conditions:
        row["conditions"] = conditions
    return row


def build_traits() -> list[dict]:
    hill = [LF_HILL, LF_MOUNTAIN, LF_PEAK]
    metals = ["iron_ore", "copper_ore", "tin_ore", "gold_ore", "silver_ore",
              "lead_ore", "zinc_ore", "bauxite", "manganese_ore", "coal", "oil"]
    fish = ["freshwater_fish", "marine_fish"]
    temp_cold = cond(OP_LTE, 5, COLD_LINE)
    land_hill = [cond(OP_GTE, 10, LF_HILL * Q16), cond(OP_LTE, 10, LF_PEAK * Q16),
                 cond(OP_AND, 0, 0)]
    pop_low = cond(OP_LTE, 9, 500 * Q16)
    prestige_max = cond(OP_EQ, 12, Q16)
    shortage = cond(OP_GTE, 11, q16(0.20))
    legal_ge3 = cond(OP_GTE, 30, 3 * Q16)
    vacant_ge3 = cond(OP_GTE, 31, 3 * Q16)
    delta = cond(OP_EQ, 10, LF_DELTA * Q16)
    small_farms = [
        "tenant_paddy", "sharecrop_paddy", "tenant_rainfed_maize_field",
        "tenant_rainfed_wheat_field", "rainfed_maize_field", "rainfed_wheat_plot",
        "swidden_maize_plot", "dryland_wheat_field", "floodplain_maize_plot",
        "floodplain_wheat_plot", "highland_tuber_plot", "bunded_rice_field",
    ]
    steam_ids = [
        "steam_engine_works", "steam_steel_works", "steam_rail_works",
        "steam_iron_mine", "steam_coal_mine", "method_steam_shipping",
        "method_steam_engine_works_r9",
    ]
    electric_ids = [
        "electricity_plant", "electrical_equipment_plant", "electric_motor_plant",
        "basic_electrical_equipment_works", "method_electric_motor_plant_r10",
    ]
    oil_ids = ["crude_oil", "refined_fuel"]  # buildings resolved by tag below
    nuclear_ids = ["nuclear_power_plant", "nuclear_fuel_plant", "nuclear_medicine_center",
                   "method_nuclear_fuel_plant_r10"]
    chip_ids = ["semiconductors_plant", "basic_semiconductor_fab", "advanced_chip_fab"]
    labor = ["forager", "hunter", "fisher", "pastoralist", "subsistence_farmer",
             "household_farmer", "tenant_farmer", "sharecropper", "agricultural_worker",
             "miner", "forestry_worker", "construction_worker", "industrial_worker",
             "worker", "corvee_worker", "indentured_laborer", "enslaved_laborer", "serf"]

    austere_needs = [
        "clothing", "communication", "durable_goods", "education_culture",
        "healthcare", "household_goods", "hygiene", "luxury", "recreation",
        "status_goods", "transport", "work_equipment",
    ]

    rows = []
    rows.append(trait("c001_gluttony", "暴食", "提高食品、蔬果与肉类消费份额。", [
        behavior(AXIS_NEED, "staple_food", -1),
        behavior(AXIS_NEED, "produce", -1),
        behavior(AXIS_NEED, "protein", -1),
    ], exclusions=["c019_austere"]))
    rows.append(trait("c002_carnivore", "肉食者", "提高肉类消费、降低蔬果消费。", [
        behavior(AXIS_NEED, "protein", -1),
        behavior(AXIS_NEED, "produce", Q16 // 2),
    ], exclusions=["c003_vegetarian"], lo=0.15, hi=0.40))
    rows.append(trait("c003_vegetarian", "菜食门风", "提高蔬果消费、降低肉类消费。", [
        behavior(AXIS_NEED, "produce", -1),
        behavior(AXIS_NEED, "protein", Q16 // 2),
    ], exclusions=["c002_carnivore"]))
    rows.append(trait("c004_clothing", "尚衣", "提高衣着消费份额。", [
        behavior(AXIS_NEED, "clothing", -1),
    ]))
    rows.append(trait("c005_communication", "好讯", "提高通信消费；需进入电气时代。", [
        behavior(AXIS_NEED, "communication", -1),
    ], techs=["电气时代"]))
    rows.append(trait("c006_durables", "恋器", "提高耐用品消费；需进入蒸汽时代。", [
        behavior(AXIS_NEED, "durable_goods", -1),
    ], techs=["蒸汽时代"]))
    rows.append(trait("c007_learning", "嗜学", "提高教育文化消费；需文字。", [
        behavior(AXIS_NEED, "education_culture", -1),
    ], techs=["文字"]))
    rows.append(trait("c008_medicine", "尚医", "提高医疗消费；需自然观察。", [
        behavior(AXIS_NEED, "healthcare", -1),
    ], techs=["自然观察"]))
    rows.append(trait("c009_cold_shy", "畏寒", "当地寒冷时提高家用能源消费。", [
        behavior(AXIS_NEED, "home_energy", -1, conditions=[temp_cold]),
    ], temp_max=COLD_LINE))
    rows.append(trait("c010_household", "爱家", "提高家庭用品消费。", [
        behavior(AXIS_NEED, "household_goods", -1),
    ]))
    rows.append(trait("c011_housing", "守宅", "提高居住消费。", [
        behavior(AXIS_NEED, "housing", -1),
    ]))
    rows.append(trait("c012_hygiene", "好洁", "提高卫生消费；需城市卫生。", [
        behavior(AXIS_NEED, "hygiene", -1),
    ], techs=["城市卫生"]))
    rows.append(trait("c013_luxury", "奢靡", "提高奢侈与身份消费。", [
        behavior(AXIS_NEED, "luxury", -1),
        behavior(AXIS_NEED, "status_goods", -1),
    ], exclusions=["c019_austere"]))
    rows.append(trait("c014_recreation", "爱游", "提高娱乐消费；需进入王国时代。", [
        behavior(AXIS_NEED, "recreation", -1),
    ], techs=["王国时代"]))
    rows.append(trait("c015_staple", "饱腹", "提高主食消费。", [
        behavior(AXIS_NEED, "staple_food", -1),
    ]))
    rows.append(trait("c016_status", "排场", "提高身份商品消费。", [
        behavior(AXIS_NEED, "status_goods", -1),
    ]))
    rows.append(trait("c017_transport", "好行", "提高交通消费；需进入探索时代。", [
        behavior(AXIS_NEED, "transport", -1),
    ], techs=["探索时代"]))
    rows.append(trait("c018_tools", "工具癖", "提高劳动工具消费。", [
        behavior(AXIS_NEED, "work_equipment", -1),
    ]))
    rows.append(trait("c019_austere", "节俭", "降低非生存需求消费，不减主食蔬果蛋白居住能源。", [
        behavior(AXIS_NEED, need, 0) for need in austere_needs
    ], exclusions=["c001_gluttony", "c013_luxury"], reduce=True, lo=0.10, hi=0.30))
    rows.append(trait("c020_highlander", "山民", "位于丘陵山地时提高居住与衣着消费。", [
        behavior(AXIS_NEED, "housing", -1, conditions=land_hill),
        behavior(AXIS_NEED, "clothing", -1, conditions=land_hill),
    ], landforms=hill))
    rows.append(trait("c021_drink", "酗酒", "提高酒饮消费；需发酵保存。", [
        behavior(AXIS_GOOD, "beverages", -1),
    ], techs=["发酵保存"]))
    rows.append(trait("c022_rice", "米食", "提高稻米消费。", [
        behavior(AXIS_GOOD, "rice_grain", -1),
    ]))
    rows.append(trait("c023_wheat", "麦食", "提高小麦消费。", [
        behavior(AXIS_GOOD, "wheat_grain", -1),
    ]))
    rows.append(trait("c024_corn", "玉米嗜好", "提高玉米消费。", [
        behavior(AXIS_GOOD, "corn_grain", -1),
    ]))
    rows.append(trait("c025_bread", "饼食", "提高面包等熟制主食消费。", [
        behavior(AXIS_GOOD, "bread", -1),
        behavior(AXIS_GOOD, "prepared_staples", -1),
    ]))
    rows.append(trait("c026_salt", "嗜盐", "提高食盐消费。", [
        behavior(AXIS_GOOD, "salt", -1),
    ]))
    rows.append(trait("c027_books", "书卷传家", "提高简册与纸张消费。", [
        behavior(AXIS_GOOD, "manuscripts", -1),
        behavior(AXIS_GOOD, "paper", -1),
        behavior(AXIS_GOOD, "printed_materials", -1),
    ], techs=["文字"]))
    rows.append(trait("c028_pottery", "爱陶", "提高陶器消费。", [
        behavior(AXIS_GOOD, "pottery", -1),
    ]))
    rows.append(trait("c029_spice", "香料嗜好", "提高香料消费。", [
        behavior(AXIS_GOOD, "spices", -1),
    ]))
    rows.append(trait("c030_fine_clothing", "锦衣", "提高华服消费。", [
        behavior(AXIS_GOOD, "fine_clothing", -1),
    ]))
    rows.append(trait("c031_jewelry", "珠玉", "提高珠宝消费。", [
        behavior(AXIS_GOOD, "jewelry", -1),
    ]))
    rows.append(trait("c032_medicine", "药石", "提高药草与药品消费。", [
        behavior(AXIS_GOOD, "medicinal_herbs", -1),
        behavior(AXIS_GOOD, "pharmaceuticals", -1),
    ]))
    rows.append(trait("c033_canned", "罐藏", "提高罐装与加工食品消费。", [
        behavior(AXIS_GOOD, "canned_fish", -1),
        behavior(AXIS_GOOD, "processed_food", -1),
    ]))
    rows.append(trait("c034_appliances", "家电生活", "提高家用电器消费。", [
        behavior(AXIS_GOOD, "household_appliances", -1),
    ], techs=["电气时代"]))
    rows.append(trait("c035_auto", "汽车生活", "提高汽车消费。", [
        behavior(AXIS_GOOD, "automobiles", -1),
    ], techs=["电气时代"]))
    rows.append(trait("c036_radio", "广播迷", "提高无线电设备消费。", [
        behavior(AXIS_GOOD, "radio_equipment", -1),
    ], techs=["电气时代"]))
    rows.append(trait("c037_digital", "数字生活", "提高计算机与通信设备消费。", [
        behavior(AXIS_GOOD, "computers", -1),
        behavior(AXIS_GOOD, "telecom_equipment", -1),
    ], techs=["电气时代"]))
    rows.append(trait("c038_autonomy", "智能依赖", "提高自主系统消费。", [
        behavior(AXIS_GOOD, "autonomous_systems", -1),
    ], techs=["电气时代"]))

    # Investment
    rows.append(trait("i001_agrarian", "重农", "提高农业部门投资权重。", [
        behavior(AXIS_INVEST, "agriculture", -1, SEL_SECTOR),
    ]))
    rows.append(trait("i002_extractive", "重矿", "提高采掘部门投资权重；起源需有矿产。", [
        behavior(AXIS_INVEST, "extractive", -1, SEL_SECTOR),
    ], resources=metals, techs=MINERAL_IDENTIFICATION_TECHS, tech_any=True))
    rows.append(trait("i003_manufacturing", "制造世家", "提高制造部门投资；需进入农耕时代。", [
        behavior(AXIS_INVEST, "manufacturing", -1, SEL_SECTOR),
    ], techs=["农耕时代"]))
    rows.append(trait("i004_energy", "能源财团", "提高能源部门投资；需发电机。", [
        behavior(AXIS_INVEST, "energy", -1, SEL_SECTOR),
    ], techs=["发电机"]))
    rows.append(trait("i005_knowledge", "学术赞助", "提高知识部门投资；需文字。", [
        behavior(AXIS_INVEST, "knowledge", -1, SEL_SECTOR),
    ], techs=["文字"]))
    rows.append(trait("i006_gathering", "采集传统", "提高采集建筑投资。", [
        behavior(AXIS_INVEST, "activity.gathering", -1, SEL_TAG),
        behavior(AXIS_CAREER, "forager", -1),
    ]))
    rows.append(trait("i007_hunting", "猎场世家", "提高狩猎建筑投资；起源需有野生动物。", [
        behavior(AXIS_INVEST, "activity.hunting", -1, SEL_TAG),
        behavior(AXIS_CAREER, "hunter", -1),
    ], resources=["wild_game"]))
    rows.append(trait("i008_fishing", "渔户水脉", "提高渔捞建筑投资；起源需有鱼群。", [
        behavior(AXIS_INVEST, "activity.fishing", -1, SEL_TAG),
        behavior(AXIS_CAREER, "fisher", -1),
    ], resources=fish, water=True))
    rows.append(trait("i009_pastoral", "牧场门第", "提高畜牧投资并降低其余农业权重。", [
        behavior(AXIS_INVEST, "activity.pastoral", -1, SEL_TAG),
        behavior(AXIS_INVEST, "agriculture", Q16 // 2, SEL_SECTOR),
        behavior(AXIS_CAREER, "pastoralist", -1),
    ], resources=["pasture"], lo=0.40, hi=1.20))
    rows.append(trait("i010_yeoman", "小农思想", "提高佃作与自给农舍投资。", [
        behavior(AXIS_INVEST, bid, -1) for bid in small_farms
    ]))
    rows.append(trait("i011_forestry", "林薮经营", "提高林业投资；起源需有木材。", [
        behavior(AXIS_INVEST, "timber_collector", -1),
        behavior(AXIS_INVEST, "deadwood_gathering_camp", -1),
        behavior(AXIS_CAREER, "forestry_worker", -1),
    ], resources=["timber"]))
    rows.append(trait("i012_mining", "矿业经营", "提高采矿投资；起源需有金属或燃料矿。", [
        behavior(AXIS_INVEST, "iron_ore_collector", -1),
        behavior(AXIS_INVEST, "coal_mine", -1),
        behavior(AXIS_INVEST, "early_iron_mine", -1),
        behavior(AXIS_CAREER, "miner", -1),
    ], resources=metals, techs=MINING_IDENTIFICATION_TECHS, tech_any=True))
    rows.append(trait("i013_salt", "盐灶门风", "提高制盐投资；起源需有盐。", [
        behavior(AXIS_INVEST, "salt_collector", -1),
        behavior(AXIS_INVEST, "solar_salt_pan", -1),
        behavior(AXIS_INVEST, "industrial_salt_mine", -1),
    ], resources=["salt"]))
    rows.append(trait("i014_textile", "机杼世家", "提高纺织投资。", [
        behavior(AXIS_INVEST, "industry.textile", -1, SEL_TAG),
    ], techs=["织造"]))
    rows.append(trait("i015_pottery", "陶火窑户", "提高陶器投资；起源需有黏土。", [
        behavior(AXIS_INVEST, "activity.pottery", -1, SEL_TAG),
    ], resources=["clay"]))
    rows.append(trait("i016_metalwork", "炉锤世业", "提高冶锻投资。", [
        behavior(AXIS_INVEST, "activity.metalworking", -1, SEL_TAG),
    ]))
    rows.append(trait("i017_construction", "营造世家", "提高建材与营造投资。", [
        behavior(AXIS_INVEST, "industry.construction", -1, SEL_TAG),
    ]))
    rows.append(trait("i018_food", "食业经营", "提高食品产业投资。", [
        behavior(AXIS_INVEST, "industry.food", -1, SEL_TAG),
    ]))
    rows.append(trait("i019_trade", "商路人脉", "提高贸易建筑投资。", [
        behavior(AXIS_INVEST, "activity.trade", -1, SEL_TAG),
        behavior(AXIS_CAREER, "merchant", -1),
    ]))
    rows.append(trait("i020_scribal", "简册门第", "提高知识产业投资。", [
        behavior(AXIS_INVEST, "industry.knowledge", -1, SEL_TAG),
    ], techs=["文字"]))
    rows.append(trait("i021_progress", "进步主义", "提高高阶升级建筑投资权重。", [
        behavior(AXIS_INVEST, "*", -1, score=SCORE_TIER),
    ], exclusions=["i022_conservative"]))
    rows.append(trait("i022_conservative", "守旧经营", "降低高阶升级建筑投资权重。", [
        behavior(AXIS_INVEST, "*", 0, score=SCORE_TIER),
    ], exclusions=["i021_progress"], reduce=True, lo=0.20, hi=0.50))
    rows.append(trait("i023_local_resource", "因地制宜", "按本地储量提高投资权重。", [
        behavior(AXIS_INVEST, "*", -1, score=SCORE_ABUNDANCE),
    ]))
    rows.append(trait("i024_trend", "弄潮儿", "本地可投资种类较多时追随热门。", [
        behavior(AXIS_INVEST, "*", -1, score=SCORE_POPULAR, conditions=[legal_ge3]),
    ]))
    rows.append(trait("i025_pioneer", "拓荒者", "当地人口较低时提高投资权重。", [
        behavior(AXIS_INVEST, "*", -1, conditions=[pop_low]),
    ], pop_max=500))
    rows.append(trait("i026_magnate", "家大业大", "本城威望最高时提高投资权重。", [
        behavior(AXIS_INVEST, "*", -1, conditions=[prestige_max]),
    ]))
    rows.append(trait("i027_tax", "听床师", "按税后利润敏感度调整投资；起源需有建筑税或补贴。", [
        behavior(AXIS_INVEST, "*", -1, score=SCORE_TAX),
    ], tax=True))
    rows.append(trait("i028_counter", "逆周期经营", "必需品短缺时提高投资权重。", [
        behavior(AXIS_INVEST, "*", -1, conditions=[shortage]),
    ]))
    rows.append(trait("i029_coastal", "沿海资本", "提高渔捞、贸易与船舶投资；起源需邻接水体。", [
        behavior(AXIS_INVEST, "activity.fishing", -1, SEL_TAG),
        behavior(AXIS_INVEST, "activity.trade", -1, SEL_TAG),
        behavior(AXIS_INVEST, "oceanic_shipyard", -1),
    ], water=True))
    rows.append(trait("i030_floodplain", "河谷经营", "洪泛地貌提高农业与营造投资。", [
        behavior(AXIS_INVEST, "agriculture", -1, SEL_SECTOR, conditions=[delta]),
        behavior(AXIS_INVEST, "industry.construction", -1, SEL_TAG, conditions=[delta]),
    ], landforms=[LF_DELTA]))
    rows.append(trait("i031_steam", "蒸汽资本", "提高蒸汽动力相关建筑投资。", [
        behavior(AXIS_INVEST, bid, -1) for bid in steam_ids
    ], techs=["蒸汽时代"]))
    rows.append(trait("i032_electric", "电气先锋", "提高发电与电气设备投资。", [
        behavior(AXIS_INVEST, bid, -1) for bid in electric_ids
    ], techs=["电气时代"]))
    rows.append(trait("i033_oil", "石油财团", "提高石油与石化投资。", [
        behavior(AXIS_INVEST, "oil_collector", -1),
        behavior(AXIS_INVEST, "early_oil_well", -1),
        behavior(AXIS_INVEST, "refined_fuel_plant", -1),
        behavior(AXIS_CAREER, "petroleum_worker", -1),
    ], techs=["电气时代"], resources=["oil"]))
    rows.append(trait("i034_nuclear", "核能押注", "提高核能相关建筑投资。", [
        behavior(AXIS_INVEST, bid, -1) for bid in nuclear_ids
    ], techs=["电气时代"]))
    rows.append(trait("i035_chips", "芯片代工", "提高半导体厂投资。", [
        behavior(AXIS_INVEST, bid, -1) for bid in chip_ids
    ], techs=["电气时代"]))
    rows.append(trait("i036_digital", "数字产业", "提高计算机与通信设备厂投资。", [
        behavior(AXIS_INVEST, "computers_plant", -1),
        behavior(AXIS_INVEST, "telecom_equipment_plant", -1),
        behavior(AXIS_INVEST, "electronic_components_plant", -1),
    ], techs=["电气时代"]))
    rows.append(trait("i037_precision_ag", "精准农业", "提高农机与精准农业投资。", [
        behavior(AXIS_INVEST, "precision_farm", -1),
        behavior(AXIS_INVEST, "automated_farm", -1),
    ], techs=["电气时代"]))
    rows.append(trait("i038_automation", "自动化资本", "提高自动化与自主系统投资。", [
        behavior(AXIS_INVEST, "automated_farm", -1),
        behavior(AXIS_INVEST, "method_automated_port", -1),
    ], techs=["电气时代"]))

    # Employment
    rows.append(trait("j001_wild", "山野生计", "提高采集、狩猎与渔捞就业。", [
        behavior(AXIS_CAREER, "forager", -1),
        behavior(AXIS_CAREER, "hunter", -1),
        behavior(AXIS_CAREER, "fisher", -1),
    ]))
    rows.append(trait("j002_farm_scholar", "耕读传家", "提高农民与书记学者就业。", [
        behavior(AXIS_CAREER, "household_farmer", -1),
        behavior(AXIS_CAREER, "subsistence_farmer", -1),
        behavior(AXIS_CAREER, "scribe", -1),
        behavior(AXIS_CAREER, "scholar", -1),
    ], techs=["文字"]))
    rows.append(trait("j003_forest_mine", "林矿世业", "提高林矿工人就业。", [
        behavior(AXIS_CAREER, "forestry_worker", -1),
        behavior(AXIS_CAREER, "miner", -1),
    ], resources=["timber"] + metals))
    rows.append(trait("j004_craft", "工匠世家", "提高学徒到行会师傅就业。", [
        behavior(AXIS_CAREER, "apprentice", -1),
        behavior(AXIS_CAREER, "artisan", -1),
        behavior(AXIS_CAREER, "journeyman", -1),
        behavior(AXIS_CAREER, "guild_master", -1),
    ]))
    rows.append(trait("j005_labor", "劳工门第", "提高工人与建筑工就业。", [
        behavior(AXIS_CAREER, "worker", -1),
        behavior(AXIS_CAREER, "industrial_worker", -1),
        behavior(AXIS_CAREER, "construction_worker", -1),
    ]))
    rows.append(trait("j006_electro", "机电世家", "提高机电工程职业就业。", [
        behavior(AXIS_CAREER, "machinist", -1),
        behavior(AXIS_CAREER, "electrician", -1),
        behavior(AXIS_CAREER, "technician", -1),
        behavior(AXIS_CAREER, "engineer", -1),
        behavior(AXIS_CAREER, "metallurgist", -1),
    ], techs=["蒸汽时代"]))
    rows.append(trait("j007_merchant", "商帮", "提高商人、运输与经理就业。", [
        behavior(AXIS_CAREER, "merchant", -1),
        behavior(AXIS_CAREER, "transport_worker", -1),
        behavior(AXIS_CAREER, "manager", -1),
    ]))
    rows.append(trait("j008_owners", "业主门第", "提高地主与工业家就业。", [
        behavior(AXIS_CAREER, "landlord", -1),
        behavior(AXIS_CAREER, "industrialist", -1),
    ]))
    rows.append(trait("j009_letters", "书香门第", "提高书记、守藏与学者就业。", [
        behavior(AXIS_CAREER, "lorekeeper", -1),
        behavior(AXIS_CAREER, "scribe", -1),
        behavior(AXIS_CAREER, "scholar", -1),
        behavior(AXIS_CAREER, "natural_philosopher", -1),
    ], techs=["文字"]))
    rows.append(trait("j010_science", "科研世家", "提高研究与科学职业就业。", [
        behavior(AXIS_CAREER, "chemist", -1),
        behavior(AXIS_CAREER, "researcher", -1),
        behavior(AXIS_CAREER, "research_scientist", -1),
        behavior(AXIS_CAREER, "scientist", -1),
    ], techs=["自然观察"]))
    rows.append(trait("j011_digital", "数字精英", "提高数据与人工智能研究就业。", [
        behavior(AXIS_CAREER, "data_scientist", -1),
        behavior(AXIS_CAREER, "ai_researcher", -1),
    ], techs=["电气时代"]))
    rows.append(trait("j012_coop", "合作传统", "提高合作社成员就业。", [
        behavior(AXIS_CAREER, "cooperative_member", -1),
    ], techs=["tech.cooperative_association"]))
    rows.append(trait("j013_corvee", "役户传统", "提高徭役与契约劳工就业。", [
        behavior(AXIS_CAREER, "corvee_worker", -1),
        behavior(AXIS_CAREER, "indentured_laborer", -1),
    ], techs=["tech.indentured_contracts"]))
    rows.append(trait("j014_serf", "隶农传统", "提高奴工与农奴就业。", [
        behavior(AXIS_CAREER, "enslaved_laborer", -1),
        behavior(AXIS_CAREER, "serf", -1),
    ], techs=["tech.serf_obligations"]))
    rows.append(trait("j015_delicate", "娇生惯养", "降低体力职业就业权重。", [
        behavior(AXIS_CAREER, pid, 0) for pid in labor
    ], reduce=True, lo=0.20, hi=0.45, exclusions=["j005_labor", "j001_wild"]))
    rows.append(trait("j016_shrewd", "精明", "提高职业流动。", [
        behavior(AXIS_CAREER, "*", -1, score=SCORE_MOBILITY),
    ], exclusions=["j017_loyal"]))
    rows.append(trait("j017_loyal", "老实", "降低职业流动。", [
        behavior(AXIS_CAREER, "*", 0, score=SCORE_MOBILITY),
    ], exclusions=["j016_shrewd"], reduce=True, lo=0.20, hi=0.50))
    rows.append(trait("j018_follow", "跟风", "空缺职业较多时追随本地热门。", [
        behavior(AXIS_CAREER, "*", -1, score=SCORE_POPULAR, conditions=[vacant_ge3]),
    ]))
    rows.append(trait("j019_industrious", "勤业", "降低失业职业权重。", [
        behavior(AXIS_CAREER, "unemployed", 0),
    ], reduce=True, lo=0.25, hi=0.60))
    rows.append(trait("j020_gentry", "士绅门第", "提高地主、书记、学者与经理，降低体力职业。", [
        behavior(AXIS_CAREER, "landlord", -1),
        behavior(AXIS_CAREER, "scribe", -1),
        behavior(AXIS_CAREER, "scholar", -1),
        behavior(AXIS_CAREER, "manager", -1),
    ] + [behavior(AXIS_CAREER, pid, 0) for pid in [
        "worker", "industrial_worker", "construction_worker", "miner", "forager"
    ]]))
    rows.append(trait("j021_oil", "石油工班", "提高石油工人与化工机电就业。", [
        behavior(AXIS_CAREER, "petroleum_worker", -1),
        behavior(AXIS_CAREER, "chemist", -1),
        behavior(AXIS_CAREER, "technician", -1),
        behavior(AXIS_CAREER, "engineer", -1),
    ], techs=["电气时代"]))
    rows.append(trait("j022_ai", "智能研发", "提高人工智能与数据研究就业。", [
        behavior(AXIS_CAREER, "ai_researcher", -1),
        behavior(AXIS_CAREER, "data_scientist", -1),
        behavior(AXIS_CAREER, "research_scientist", -1),
        behavior(AXIS_CAREER, "engineer", -1),
    ], techs=["电气时代"]))

    # Fix reduce behaviors that used factor 0 with bonus_range (c002 produce, i009 agri)
    for row in rows:
        if row["key"] == "j020_gentry":
            for b in row["behaviors"]:
                if b["selector_id"] in ("worker", "industrial_worker", "construction_worker",
                                        "miner", "forager"):
                    b["factor_q16"] = Q16 // 2
    return rows


def trigger_tiers(prefix: str) -> list[str]:
    return [f"{prefix}_t{i}" for i in range(6)]


def build_effects() -> list[dict]:
    rain = cond(OP_EQ, 13, Q16)
    hot = cond(OP_GTE, 5, q16(0.62))
    delta = cond(OP_EQ, 10, LF_DELTA * Q16)
    hill = [cond(OP_GTE, 10, LF_HILL * Q16), cond(OP_LTE, 10, LF_PEAK * Q16), cond(OP_AND, 0, 0)]
    extractive = cond(OP_EQ, 29, Q16)
    unemp = cond(OP_GTE, 22, q16(0.15))
    corn = cond(OP_EQ, 36, Q16)
    resource_n = cond(OP_GTE, 23, 3 * Q16)
    mfg_n = cond(OP_GTE, 24, 3 * Q16)
    sectors = cond(OP_GTE, 25, 3 * Q16)
    one_industry = cond(OP_GTE, 27, q16(0.70))
    chain = cond(OP_GTE, 28, 1 * Q16)
    know = cond(OP_GTE, 35, 1 * Q16)
    branches = cond(OP_GTE, 32, 2 * Q16)

    e011 = trigger_tiers("family.buff.trade_population")
    e022 = trigger_tiers("family.buff.market_window")
    e035 = trigger_tiers("family.buff.construction_gift")

    rows = []
    rows.append(effect("birth_plenty", "多子多福", "提高本城出生系数。",
        commands=[mod_cmd("family.city.birth_boost")],
        exclusions=["birth_decline", "wealthy_few_heirs"]))
    rows.append(effect("birth_decline", "少子化", "降低本城出生系数。",
        commands=[mod_cmd("family.city.birth_cut")],
        exclusions=["birth_plenty"]))
    rows.append(effect("production_boost", "鼓舞生产", "提高本城产出系数。",
        commands=[mod_cmd("family.city.production_boost")]))
    rows.append(effect("hedonism", "享乐主义", "提高消费并略降产出。",
        commands=[mod_cmd("family.city.hedonism")]))
    rows.append(effect("afforestation", "植树造林", "提高木材再生。",
        domain=DOM_BUILDING, selector=SEL_ID, selector_id="timber",
        commands=[mod_cmd("family.city.timber_regen_boost")],
        techs=["枯枝采集"]))
    rows.append(effect("corn_expert", "玉米专家", "当地可产玉米时提高玉米产出。",
        domain=DOM_BUILDING, selector=SEL_ID, selector_id="corn_grain",
        commands=[mod_cmd("family.city.good.corn_grain.output")],
        conditions=[corn], techs=["野生玉米采集"]))
    rows.append(effect("rain_prayer", "求雨", "降低本城经济成雨门槛。",
        commands=[], selector=SEL_CELL))
    rows.append(effect("cold_resist", "抗寒", "提高本城寒冷气候下的生产容量。",
        commands=[]))
    rows.append(effect("expansionism", "扩张主义", "开拓落户时追加人口奖励。",
        domain=DOM_FAMILY, selector=SEL_OWNER, commands=[]))
    rows.append(effect("hardship", "忧患意识", "必需品短缺时提高非生存消费并压低奢侈。",
        commands=[mod_cmd("family.city.austere_consumption")],
        conditions=[cond(OP_GTE, 11, q16(0.15))]))
    rows.append(effect("trade_zealot", "商业狂热者", "累计贸易后奖励人口；威望分档阈值。",
        domain=DOM_FAMILY, selector=SEL_OWNER, operation=OP_EVENT, lifecycle=LIFE_ONCE,
        commands=[econ_cmd(15, "family.population_reward")],
        triggers=e011, reward=1, techs=TRADE_POOL_TECHS))
    rows.append(effect("rain_farming", "雨水利用", "成雨当日提高农业产出。",
        lifecycle=LIFE_DUR, duration=1, stack=STACK_REFRESH,
        commands=[mod_cmd("family.city.agriculture_output_boost", duration=1)],
        conditions=[rain]))
    rows.append(effect("heat_stress", "燥热", "高温时降低出生系数。",
        commands=[mod_cmd("family.city.birth_cut")],
        conditions=[hot]))
    rows.append(effect("valley_farm", "河谷农法", "洪泛地貌提高农业产出。",
        commands=[mod_cmd("family.city.agriculture_output_boost")],
        conditions=[delta]))
    rows.append(effect("tide_living", "观潮生计", "海岸邻域提高渔获与贸易产出。",
        commands=[mod_cmd("family.city.trade_output_boost"),
                  mod_cmd("family.city.freshwater_fish_regen_boost")],
        techs=FISHERY_TECHS, tech_any=True))
    rows.append(effect("mountain_vein", "山地矿脉", "丘陵山地且有矿产时提高采掘产出。",
        commands=[mod_cmd("family.city.extractive_output_boost")],
        conditions=hill + [extractive, cond(OP_AND, 0, 0)],
        techs=MINERAL_IDENTIFICATION_TECHS, tech_any=True))
    rows.append(effect("drought_stores", "旱年储备", "连续干旱后降低主食消费。",
        commands=[],
        triggers=trigger_tiers("family.buff.drought_store")))
    rows.append(effect("many_resources", "百产之地", "资源种类较多时提高产出。",
        commands=[mod_cmd("family.city.production_boost")],
        conditions=[resource_n]))
    rows.append(effect("industry_cluster", "工业集群", "制造建筑较多时提高制造产出。",
        commands=[mod_cmd("family.city.manufacturing_output_boost")],
        conditions=[mfg_n], techs=INDUSTRY_POOL_TECHS))
    rows.append(effect("thrift_output", "物尽其用", "提高制造产出并略降资源耗用。",
        commands=[mod_cmd("family.city.manufacturing_output_boost")]))
    rows.append(effect("work_relief", "以工代赈", "失业较高时提高家族投资权重。",
        domain=DOM_FAMILY, selector=SEL_OWNER, commands=[],
        conditions=[unemp]))
    rows.append(effect("market_boom", "市集繁荣", "窗口期内贸易次数达标后提高贸易产出。",
        commands=[],
        triggers=e022, techs=TRADE_POOL_TECHS))
    rows.append(effect("city_founder", "城市奠基者", "聚落升档时一次性奖励人口。",
        domain=DOM_FAMILY, selector=SEL_OWNER, operation=OP_EVENT, lifecycle=LIFE_ONCE,
        commands=[econ_cmd(15, "family.population_reward", 40)]))
    rows.append(effect("ancestral_precept", "时代鼓舞", "国家进入新时代表扬本国家族产出。",
        source=SRC_COUNTRY, lifecycle=LIFE_DUR, duration=365, stack=STACK_REFRESH,
        commands=[mod_cmd("family.city.production_boost", duration=365)]))
    rows.append(effect("knowledge_spread", "知识扩散", "向邻格扩散知识产出。",
        selector=SEL_R1, commands=[mod_cmd("family.city.knowledge_output_boost")],
        conditions=[know], techs=KNOWLEDGE_POOL_TECHS))
    rows.append(effect("shared_water", "共用水利", "降雨时向邻格提供农业加成。",
        selector=SEL_R1, lifecycle=LIFE_DUR, duration=2, stack=STACK_REFRESH,
        commands=[mod_cmd("family.city.agriculture_output_boost", duration=2)],
        conditions=[rain]))
    rows.append(effect("branch_network", "分支商网", "分支数较多时提高各分支贸易产出。",
        commands=[mod_cmd("family.city.trade_output_boost")],
        conditions=[branches], techs=TRADE_POOL_TECHS))
    rows.append(effect("overfish", "涸泽而渔", "提高采掘产出并降低资源再生。",
        commands=[mod_cmd("family.city.extractive_output_boost"),
                  mod_cmd("family.city.resource_regen_cut")]))
    rows.append(effect("many_trades", "百业共荣", "全城部门多样时提高产出。",
        commands=[mod_cmd("family.city.production_boost")],
        conditions=[sectors], exclusions=["one_industry_city"],
        techs=INDUSTRY_POOL_TECHS))
    rows.append(effect("one_industry_city", "一业之城", "全城主导部门份额较高时强化该部门。",
        domain=DOM_FAMILY, selector=SEL_OWNER, commands=[],
        conditions=[one_industry], exclusions=["many_trades"],
        techs=INDUSTRY_POOL_TECHS))
    rows.append(effect("city_chain", "全链协作", "全城完成产业链时提高产出。",
        commands=[mod_cmd("family.city.production_boost")],
        conditions=[chain], techs=INDUSTRY_POOL_TECHS))
    rows.append(effect("trade_nation", "商贸立国", "提高国家贸易容量。",
        domain=DOM_COUNTRY, selector=SEL_COUNTRY,
        commands=[mod_cmd("family.country.trade_capacity", domain=1)],
        techs=TRADE_POOL_TECHS))

    rows.append(effect("branching_households", "开枝散叶", "按家族成员加权提高出生，不抬匿名人口。",
        domain=DOM_FAMILY, selector=SEL_OWNER, commands=[]))
    rows.append(effect("market_bully", "欺行霸市", "买方折扣并提高投资权重。",
        domain=DOM_FAMILY, selector=SEL_OWNER, commands=[]))
    rows.append(effect("lucky_pair", "好事成双", "累计建设后免费建成一座建筑。",
        domain=DOM_FAMILY, selector=SEL_OWNER, operation=OP_EVENT, lifecycle=LIFE_ONCE,
        commands=[econ_cmd(14, "family.free_building")],
        triggers=e035, reward=0))
    rows.append(effect("retain_lineage", "抱残守缺", "分裂时尽量保留原有特性。",
        domain=DOM_FAMILY, selector=SEL_OWNER, commands=[],
        exclusions=["absorb_all", "break_with_past"]))
    rows.append(effect("absorb_all", "兼收并蓄", "分裂时提高新特性权重。",
        domain=DOM_FAMILY, selector=SEL_OWNER, commands=[],
        exclusions=["retain_lineage", "break_with_past"]))
    rows.append(effect("specialized_industry", "一业传家", "家族自有建筑集中于单一部门时调整产出。",
        domain=DOM_FAMILY, selector=SEL_OWNER, commands=[],
        exclusions=["versatile_crafts"], techs=INDUSTRY_POOL_TECHS))
    rows.append(effect("versatile_crafts", "百工兴家", "家族自有建筑跨越多部门时提高产出。",
        domain=DOM_FAMILY, selector=SEL_OWNER, commands=[],
        exclusions=["specialized_industry"], techs=INDUSTRY_POOL_TECHS))
    rows.append(effect("complete_chain", "全链经营", "家族拥有完整升级链时提高该链产出。",
        domain=DOM_FAMILY, selector=SEL_OWNER, commands=[],
        techs=INDUSTRY_POOL_TECHS))
    rows.append(effect("local_monopoly", "垄断豪门", "本地产业链份额较高时提高该链产出。",
        domain=DOM_FAMILY, selector=SEL_OWNER, commands=[],
        techs=INDUSTRY_POOL_TECHS))
    rows.append(effect("remote_kin", "远方亲族", "异地分支提高投资权重。",
        domain=DOM_FAMILY, selector=SEL_OWNER, commands=[]))
    rows.append(effect("family_learning", "家学传承", "按威望冻结知识职业就业权重。",
        domain=DOM_FAMILY, selector=SEL_OWNER, commands=[],
        techs=KNOWLEDGE_POOL_TECHS))
    rows.append(effect("century_shop", "百年老店", "仍拥有该类建筑时按年期叠加产出。",
        lifecycle=LIFE_DUR, duration=3650, stack=STACK_ADD, max_stacks=6, cadence=3650,
        commands=[mod_cmd("family.city.owned_building_output", duration=3650, stacks=1)]))
    rows.append(effect("new_nobility", "新贵崛起", "威望升级时吸收匿名人口。",
        domain=DOM_FAMILY, selector=SEL_OWNER, operation=OP_EVENT, lifecycle=LIFE_ONCE,
        commands=[econ_cmd(21, "family.absorb_anonymous")]))
    rows.append(effect("split_dowry", "分家馈赠", "分裂时赠予建筑与人口。",
        domain=DOM_FAMILY, selector=SEL_OWNER, commands=[]))
    rows.append(effect("wealthy_few_heirs", "富室寡嗣", "人均财富高于当地时降低生育并提高投资。",
        domain=DOM_FAMILY, selector=SEL_OWNER, commands=[],
        exclusions=["birth_plenty"]))
    rows.append(effect("break_with_past", "破旧立新", "分裂时替换原有特性。",
        domain=DOM_FAMILY, selector=SEL_OWNER, commands=[],
        exclusions=["retain_lineage", "absorb_all"]))
    return rows


def main() -> int:
    tech_map = load_tech_map()
    traits = build_traits()
    effects = build_effects()
    if len(traits) != 98:
        raise SystemExit(f"expected 98 traits, got {len(traits)}")
    if len(effects) != 48:
        raise SystemExit(f"expected 48 effects, got {len(effects)}")
    keys = [t["key"] for t in traits]
    if len(keys) != len(set(keys)):
        raise SystemExit("duplicate trait keys")
    ekeys = [e["key"] for e in effects]
    if len(ekeys) != len(set(ekeys)):
        raise SystemExit("duplicate effect keys")
    trait_set = set(keys)
    effect_set = set(ekeys)
    buildings = catalog_ids(BUILDING_DIR)
    goods = catalog_ids(GOOD_DIR)
    professions = catalog_ids(PROFESSION_DIR)
    needs = catalog_ids(NEED_DIR)
    resources = catalog_ids(RESOURCE_DIR)
    apply_design_copy(traits, effects)
    for row in traits:
        apply_appearance_techs(row)
        row["prerequisite_technology_any"] = bool(row.pop("tech_any", False))
        row["prerequisite_technology_keys"] = resolve_techs(tech_map, row.pop("tech_names"))
        for ex in row["exclusion_keys"]:
            if ex not in trait_set:
                raise SystemExit(f"trait {row['key']} exclusion unknown: {ex}")
        kept = []
        for b in row["behaviors"]:
            b.pop("strength_note", None)
            selector = str(b["selector_id"])
            kind = int(b["selector_kind"])
            axis = int(b["axis"])
            if selector in ("*", "all") or kind in (SEL_SECTOR, SEL_TAG):
                kept.append(b)
                continue
            pool = {AXIS_INVEST: buildings, AXIS_CAREER: professions,
                    AXIS_NEED: needs, AXIS_GOOD: goods}.get(axis, set())
            if selector not in pool:
                raise SystemExit(
                    f"trait {row['key']} unknown selector {selector} axis={axis}")
            kept.append(b)
        if not kept:
            raise SystemExit(f"trait {row['key']} has no behaviors")
        row["behaviors"] = kept
        for resource_id in row["required_resource_ids"]:
            if resource_id not in resources:
                raise SystemExit(
                    f"trait {row['key']} unknown resource {resource_id}")
    for row in effects:
        row["prerequisite_technology_any"] = bool(row.pop("tech_any", False))
        row["prerequisite_technology_keys"] = resolve_techs(tech_map, row.pop("tech_names"))
        for ex in row["exclusion_keys"]:
            if ex not in effect_set:
                raise SystemExit(f"effect {row['key']} exclusion unknown: {ex}")
        if row["lifecycle"] != LIFE_DUR and row["duration_days"] != -1:
            raise SystemExit(f"effect {row['key']} duration mismatch")
        if row["source_kind"] == SRC_POOL:
            row["random_pool_eligible"] = True
        else:
            row["random_pool_eligible"] = False
        if row["operation"] == OP_EVENT and row["lifecycle"] != LIFE_ONCE:
            raise SystemExit(f"effect {row['key']} event lifecycle")
        if not row["commands"] and not row["instructions"]:
            raise SystemExit(f"effect {row['key']} empty program")
        if row["key"] == "corn_expert" and "tech.wild_maize_collection" not in row[
                "prerequisite_technology_keys"]:
            raise SystemExit("corn_expert must require wild maize collection")
    mineral_ids = {
        "tech.iron_ore_identification",
        "tech.natural_copper_identification",
        "tech.tin_identification",
        "tech.gold_placer_identification",
        "tech.silver_vein_identification",
        "tech.coal_outcrop_identification",
    }
    mining_ids = mineral_ids | {"tech.petroleum_extraction"}
    effect_pool_gates = {
        "corn_expert": (False, {"tech.wild_maize_collection"}),
        "afforestation": (False, {"tech.deadwood_collection"}),
        "tide_living": (True, {"tech.freshwater_fishing", "tech.coastal_fishing"}),
        "mountain_vein": (True, set(mineral_ids)),
        "trade_zealot": (False, {"tech.early_trade"}),
        "market_boom": (False, {"tech.early_trade"}),
        "branch_network": (False, {"tech.early_trade"}),
        "trade_nation": (False, {"tech.early_trade"}),
        "industry_cluster": (False, {"tech.agrarian_society"}),
        "many_trades": (False, {"tech.agrarian_society"}),
        "one_industry_city": (False, {"tech.agrarian_society"}),
        "city_chain": (False, {"tech.agrarian_society"}),
        "specialized_industry": (False, {"tech.agrarian_society"}),
        "versatile_crafts": (False, {"tech.agrarian_society"}),
        "complete_chain": (False, {"tech.agrarian_society"}),
        "local_monopoly": (False, {"tech.agrarian_society"}),
        "knowledge_spread": (False, {"tech.writing"}),
        "family_learning": (False, {"tech.writing"}),
    }
    for row in effects:
        expected = effect_pool_gates.get(row["key"])
        if expected is None:
            continue
        any_flag, keys = expected
        if bool(row.get("prerequisite_technology_any")) != any_flag:
            raise SystemExit(f"effect {row['key']} ANY flag mismatch")
        if set(row["prerequisite_technology_keys"]) != keys:
            raise SystemExit(f"effect {row['key']} pool gate mismatch")
    crop_gates = {
        "c022_rice": "tech.rice_paddy_cultivation",
        "c023_wheat": "tech.wild_wheat_collection",
        "c024_corn": "tech.wild_maize_collection",
    }
    for row in traits:
        expected = crop_gates.get(row["key"])
        if expected and expected not in row["prerequisite_technology_keys"]:
            raise SystemExit(f"{row['key']} must require {expected}")
        if row["key"] == "i002_extractive":
            if not row.get("prerequisite_technology_any"):
                raise SystemExit("i002_extractive must use ANY mineral identification")
            if not mineral_ids <= set(row["prerequisite_technology_keys"]):
                raise SystemExit("i002_extractive missing mineral identification techs")
        if row["key"] == "i012_mining":
            if not row.get("prerequisite_technology_any"):
                raise SystemExit("i012_mining must use ANY mineral identification")
            if not mining_ids <= set(row["prerequisite_technology_keys"]):
                raise SystemExit("i012_mining missing mineral identification techs")
        if row["key"] == "j003_forest_mine":
            for behavior_row in row["behaviors"]:
                if str(behavior_row.get("selector_id")) == "petroleum_worker":
                    raise SystemExit("j003_forest_mine must not employ petroleum_worker")
        condition = str(row.get("appearance_condition", ""))
        quotes = APPEARANCE_QUOTE_RE.findall(condition)
        eras = APPEARANCE_ERA_RE.findall(condition)
        if "或" in condition and len(quotes) >= 2:
            if not row.get("prerequisite_technology_any") \
                    or not row["prerequisite_technology_keys"]:
                raise SystemExit(
                    f"{row['key']} appearance {condition!r} must compile an ANY gate")
            continue
        if (quotes or eras) and not row["prerequisite_technology_keys"]:
            raise SystemExit(
                f"{row['key']} appearance {condition!r} has no technology gate")
    payload = {
        "version": 1,
        "core_trait_min": 2,
        "core_trait_max": 4,
        "traits": traits,
        "effects": effects,
    }
    OUT_PATH.parent.mkdir(parents=True, exist_ok=True)
    OUT_PATH.write_text(json.dumps(payload, ensure_ascii=False, indent=2) + "\n",
                        encoding="utf-8")
    print(f"wrote {OUT_PATH} traits={len(traits)} effects={len(effects)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
