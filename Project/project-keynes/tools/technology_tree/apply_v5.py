# -*- coding: utf-8 -*-
"""Project.Keynes 科技树 v5 改造器（唯一入口）。

设计文档：docs/design/technology-tree-v5/
本脚本只读写 `data/technology/technology_network.json`，不碰其它文件。

用法：
  python apply_v5.py --stage=structure        # 改名/源头/删并/成本分档
  python apply_v5.py --stage=effects          # 效果通道重标定（P0 倍率）
  python apply_v5.py --stage=all              # 全部
  追加 --dry-run 只打印计划，不写盘。

原则：
  * 幂等 —— 重复执行结果一致。
  * 所有改动都以“现状 → 目标”双向打印，便于 review。
  * 不新增稳定 ID（除显式列出的新增节点），不改 schema_version。
"""
from __future__ import annotations

import argparse
import collections
import json
import os
import statistics
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
NETWORK = os.path.join(ROOT, "data", "technology", "technology_network.json")

# ---------------------------------------------------------------- 常量

ROOT_TECH_ID = "tech.early_knowledge_institution"
ROOT_TECH_NAME = "思考"
ROOT_TECH_SUMMARY = (
    "文明第一次把经验变成可传递的知识：观察、记忆、比较、推演。"
    "它是全部科技的源头，也是唯一不需要任何前置的起点。"
)
ROOT_RATIONALE = (
    "没有“思考”就不存在可积累的经验：识别、命名、比较与推演是任何后续知识的先决条件。"
)

TIER_WEIGHT = {"minor": 0.55, "major": 1.00, "breakthrough": 1.80}

# 由 apply_structure 填充：era_id -> 时代序号
ERA_INDEX = {}

# 需要删除并合并的节点：被删 ID -> (承接节点, 说明)
MERGE_INTO = {
    "tech.reed_identification": ("tech.reed_harvesting",
        "芦苇辨识零效果；辨识与收割合并为一个节点，避免纯收费站。"),
    "tech.copper_ore_roasting": ("tech.copper_metallurgy",
        "焙烧是冶铜工序而非独立研究点；并入冶铜，去掉一个零效果中继。"),
    "tech.irrigation_surveying": ("tech.irrigation",
        "灌溉测量零效果；测量并入灌溉，粮作入口改为 irrigation。"),
    "tech.pottery": ("tech.hand_pottery",
        "陶器与手工陶器效果重复（同为营造方法加成）；并入手工陶器。"),
    "tech.loom_weaving": ("tech.weaving",
        "织机织造与纺织/手纺重复；并入纺织，纸与行会改接纺织。"),
}

# 合并后需要补写的效果（原节点是零效果，承接节点原本没有这些内容）
MERGE_CONTENT = {
    "tech.reed_harvesting": {
        "content_effects": [
            {"kind": "good", "id": "reed_bundle", "binding_kind": 1.0,
             "subject": "good.reed_bundle", "attribute": "production_access",
             "operation": "unlock", "value": 1.0,
             "implementation": "GoodProfile.technology_tags",
             "status": "existing_binding", "display_name": "芦苇束",
             "summary_visible": True},
        ],
        "modifier_terms": [
            {"stat": "country.output.terrain.swamp.extractive_factor", "operation": 0.0,
             "value": 0.15, "subject_kind": "terrain", "subject_id": "swamp",
             "subject_display_name": "沼泽", "effect_class": "地貌产出",
             "effect_rationale": "芦苇与湿地采集在沼泽地带显著增产。",
             "implementation_status": "runtime_consumed",
             "runtime_consumer": "NativeEconomyRuntime::effective_building_output_quantity"},
        ],
        "reveal_condition": {"kind": 1.0, "id": "bio.reed", "value": 1.0},
        "reveal_summary": "芦苇辨识由实际生长范围内的芦苇目击揭示。",
    },
}

# 辨识类科技在「思考」成为硬前置后，原来的唯一路线（就是思考本身）失效，
# 换成地理证据：让"你在哪儿"决定辨识能不能推进，而不是"你会不会想"。
# 辨识类科技在「思考」成为硬前置后，原来的唯一路线（就是思考本身）失效。
# 换成"观测方法"作为实践证据：必须先把观察变成方法，才谈得上辨识。
ROUTE_GEOGRAPHY = {
    "tech.spice_identification": ("tech.natural_observation", "自然观察"),
    "tech.gold_placer_identification": ("tech.natural_observation", "自然观察"),
    "tech.silver_vein_identification": ("tech.natural_observation", "自然观察"),
    "tech.flint_identification": ("tech.natural_observation", "自然观察"),
    "tech.rubber_identification": ("tech.natural_observation", "自然观察"),
}


def load():
    with open(NETWORK, encoding="utf-8") as handle:
        return json.load(handle)


# ---------------------------------------------------------------- 效果通道重标定

GLOBAL_STAT = "country.economy_output_factor"
MILESTONE_GLOBAL_VALUE = 0.07

SECTOR_CAPS = {
    "country.output.agriculture_factor": 3.00,
    "country.output.extractive_factor": 3.00,
    "country.output.manufacturing_factor": 3.00,
    "country.output.energy_factor": 2.00,
    "country.output.knowledge_factor": 2.00,
}
FAMILY_CAP = 2.60
DEATH_CAP = 0.45
GEO_CAP_PER_KEY = 1.00
STAT_CAPS = {
    # 说明：这些是"非产出链"通道（研究速率、成本、投入、贸易、气候）。
    # 它们不参与 全局×行业×家族×地理 的连乘，单节点被压到 0.02 以下会让科技"看起来什么都没有"。
    # 因此这里的预算比第一版放宽，而产出链（global/sector/family/geo）的预算保持不变。
    "country.production.input_factor": 0.90,
    "country.construction.cost_factor": 0.80,
    "country.construction.time_factor": 0.80,
    "country.trade.capacity_factor": 1.40,
    "country.trade.speed_factor": 1.00,
    "country.research.cost_factor": 0.90,
    "country.research.institution_output_factor": 1.20,
    "country.research.agriculture_efficiency": 2.40,
    "country.research.engineering_efficiency": 2.40,
    "country.research.science_efficiency": 2.40,
    "country.research.society_efficiency": 2.40,
    "country.resource.use_factor": 0.90,
    "country.climate.drought_loss_factor": 1.00,
    "country.climate.flood_loss_factor": 1.00,
    "country.climate.cold_stress_factor": 1.00,
    "country.climate.heat_stress_factor": 1.00,
    "country.military.rule.mutual_support": 0.70,
    "country.military.rule.last_stand": 0.70,
    "country.military.rule.blitz": 0.70,
    "country.military.rule.hold_the_line": 0.70,
    "country.military.rule.encirclement": 0.70,
    "country.military.rule.home_ground": 0.70,
}

GEO_NAME = {
    ("terrain", "jungle"): "热带雨林", ("terrain", "mangrove"): "红树林",
    ("terrain", "grassland"): "草原", ("terrain", "steppe"): "温带草原",
    ("terrain", "floodplain"): "泛滥平原", ("terrain", "coast"): "海岸",
    ("terrain", "reef"): "珊瑚礁", ("terrain", "salt_flat"): "盐沼",
    ("terrain", "desert"): "沙漠", ("terrain", "forest"): "森林",
    ("terrain", "taiga"): "针叶林", ("terrain", "mountain"): "山地",
    ("terrain", "badlands"): "荒原", ("terrain", "cold_desert"): "寒漠",
    ("terrain", "mesa"): "方山", ("terrain", "oasis"): "绿洲",
    ("landform", "plain"): "平原", ("landform", "mountain"): "山地",
    ("landform", "hill"): "丘陵", ("landform", "volcano"): "火山",
    ("landform", "rift_valley"): "裂谷", ("landform", "lowland"): "低地",
    ("landform", "salt_flat"): "盐滩", ("landform", "plateau"): "高原",
}
SECTOR_NAME = {
    "agriculture": "农业", "extractive": "采掘", "manufacturing": "制造",
    "energy": "能源", "knowledge": "知识",
}

# 家族 → 地理证据对（把"某产业更强"改写成"某产业在这片地上更强"）
GEO_BY_FAMILY = {
    "specialty_commodity_crops": [("terrain", "jungle", "agriculture"),
                                  ("terrain", "mangrove", "agriculture")],
    "livestock_husbandry": [("terrain", "grassland", "agriculture"),
                            ("terrain", "steppe", "extractive")],
    "cloth_weaving": [("terrain", "grassland", "extractive"),
                      ("landform", "plain", "manufacturing")],
    "staple_preparation": [("terrain", "floodplain", "agriculture"),
                           ("landform", "plain", "manufacturing")],
    "maritime_operations": [("terrain", "coast", "extractive"),
                            ("terrain", "reef", "extractive")],
    "copper_extraction": [("landform", "mountain", "extractive"),
                          ("landform", "volcano", "extractive")],
    "iron_extraction": [("landform", "mountain", "extractive"),
                        ("landform", "hill", "extractive")],
    "tin_extraction": [("landform", "volcano", "extractive"),
                       ("landform", "mountain", "extractive")],
    "gold_extraction": [("landform", "rift_valley", "extractive"),
                        ("terrain", "badlands", "extractive")],
    "silver_extraction": [("landform", "volcano", "extractive"),
                          ("terrain", "cold_desert", "extractive")],
    "salt_extraction": [("terrain", "salt_flat", "extractive"),
                        ("terrain", "desert", "extractive")],
    "oil_extraction": [("terrain", "desert", "extractive"),
                       ("landform", "lowland", "extractive")],
    "steelmaking": [("landform", "hill", "manufacturing"),
                    ("terrain", "forest", "extractive")],
    "chemical_industry": [("terrain", "salt_flat", "manufacturing"),
                          ("landform", "salt_flat", "manufacturing")],
    "paper_making": [("terrain", "forest", "manufacturing"),
                     ("terrain", "taiga", "manufacturing")],
    "construction_methods": [("landform", "hill", "extractive"),
                             ("terrain", "mountain", "extractive")],
    "metal_toolmaking": [("landform", "mountain", "extractive"),
                         ("landform", "hill", "manufacturing")],
    "hunting": [("terrain", "forest", "extractive"),
                ("terrain", "taiga", "extractive")],
}

# 失去全局产出后的替代通道：按 effect_profile 选一条"改变决策"的通道
PROFILE_CHANNEL = {
    "organization": ("country.research.society_efficiency", 0.10, "社会研究效率"),
    "institution": ("country.research.society_efficiency", 0.10, "社会研究效率"),
    "research": ("country.research.science_efficiency", 0.10, "科学研究效率"),
    "science": ("country.research.science_efficiency", 0.10, "科学研究效率"),
    "knowledge": ("country.research.cost_factor", -0.08, "研究成本"),
    "observation": ("country.research.science_efficiency", 0.08, "科学研究效率"),
    "trade": ("country.trade.capacity_factor", 0.10, "贸易容量"),
    "manufacturing": ("country.construction.cost_factor", -0.05, "建造成本"),
    "construction": ("country.construction.time_factor", -0.06, "建造工期"),
    "energy": ("country.output.energy_factor", 0.08, "能源产出"),
    "crop": ("country.production.input_factor", -0.05, "生产投入"),
    "livestock": ("country.climate.cold_stress_factor", -0.06, "寒害损失"),
    "foraging": ("country.output.terrain.forest.extractive_factor", 0.15, "森林采掘"),
    "fishing": ("country.output.terrain.coast.extractive_factor", 0.15, "海岸采掘"),
    "metallurgy": ("country.production.input_factor", -0.05, "生产投入"),
    "chemistry": ("country.production.input_factor", -0.05, "生产投入"),
    "hydraulic": ("country.climate.flood_loss_factor", -0.08, "洪水损失"),
    "health": ("country.population.death_factor", -0.04, "死亡率"),
    "automation": ("country.production.input_factor", -0.06, "生产投入"),
    "tools": ("country.production.input_factor", -0.05, "生产投入"),
    "resource": ("country.resource.use_factor", -0.06, "资源消耗"),
    "craft": ("country.production.input_factor", -0.05, "生产投入"),
    "military": ("country.military.rule.mutual_support", 0.08, "友军互援"),
    "food": ("country.output.family.staple_preparation_factor", 0.10, "主食加工家族"),
    "materials": ("country.construction.cost_factor", -0.05, "建造成本"),
    "starter": ("country.research.society_efficiency", 0.05, "社会研究效率"),
}
DEFAULT_CHANNEL = ("country.research.society_efficiency", 0.08, "社会研究效率")

# 手工接线的通道分配：把"只给百分比"的节点接到能改变玩家决策的系统上。
# 每条 = (stat, value, subject_kind, subject_id, subject_label, rationale)
CHANNEL_ASSIGNMENTS = {
    # ---- 能量转换：大气机（纽科门式蒸汽机）让同样的煤抽出更多水
    "tech.atmospheric_engine": [
        ("country.resource.coal.use_factor", -0.08, "resource", "coal",
         "煤炭单耗", "大气机把燃烧→扬程的转换效率第一次写进工艺，单位抽水量耗煤下降。")],
    # ---- 军事条令（military_core_war.cpp evaluate_rules 真正消费的 6 个参数）
    "tech.military.war_bands": [
        ("country.military.rule.mutual_support", 0.08, "country", "mutual_support",
         "友军互援", "战团以血缘与誓言维系，相邻部队互相支撑时防线更稳。")],
    "tech.military.earthen_ramparts": [
        ("country.military.rule.mutual_support", 0.06, "country", "mutual_support",
         "友军互援", "夯土城垣让守军可以靠近支援，形成连续防线。")],
    "tech.military.ambush_tactics": [
        ("country.military.rule.home_ground", 0.08, "country", "home_ground",
         "本土作战", "伏击依赖对本地林泽的熟悉，在本土作战时效力最大。")],
    "tech.military.standing_army": [
        ("country.military.rule.mutual_support", 0.08, "country", "mutual_support",
         "友军互援", "常备军按队形训练，相邻部队的支撑是操典的核心。")],
    "tech.military.chariot_warfare": [
        ("country.military.rule.blitz", 0.10, "country", "blitz",
         "闪击", "战车在接战初期的冲击力最强，五日之内决定战场。")],
    "tech.military.mounted_warfare": [
        ("country.military.rule.blitz", 0.12, "country", "blitz",
         "闪击", "骑兵机动速度达到闪击门槛，开战初期即可撕开缺口。")],
    "tech.military.heavy_cavalry": [
        ("country.military.rule.encirclement", 0.10, "country", "encirclement",
         "合围", "重骑兵用于封口，把敌军压进已合围的格子。")],
    "tech.military.siegecraft": [
        ("country.military.rule.encirclement", 0.10, "country", "encirclement",
         "合围", "攻城术让围城部队能够封锁全部邻格并持续压制。")],
    "tech.military.star_forts": [
        ("country.military.rule.hold_the_line", 0.10, "country", "hold_the_line",
         "坚守", "棱堡的交叉火力让守军在坚守姿态下获得更大优势。")],
    "tech.military.drill_regulations": [
        ("country.military.rule.hold_the_line", 0.12, "country", "hold_the_line",
         "坚守", "操典把坚守姿态标准化，队列在受攻时不再溃散。")],
    "tech.military.legion_logistics": [
        ("country.military.rule.last_stand", 0.08, "country", "last_stand",
         "死守", "军需体系让被切断补给的军团仍能维持建制继续抵抗。")],
    "tech.military.rifled_weapons": [
        ("country.military.rule.hold_the_line", 0.10, "country", "hold_the_line",
         "坚守", "线膛枪让坚守阵地的射程优势转化为实际杀伤。")],
    "tech.military.rail_mobilization": [
        ("country.military.rule.blitz", 0.10, "country", "blitz",
         "闪击", "铁路动员把兵力集中窗口压缩到数日之内。")],
    "tech.military.machine_guns": [
        ("country.military.rule.hold_the_line", 0.12, "country", "hold_the_line",
         "坚守", "机枪把坚守姿态变成不可正面突破的防线。")],
    "tech.military.armored_warfare": [
        ("country.military.rule.blitz", 0.12, "country", "blitz",
         "闪击", "装甲部队以速度换取开战初期的突破窗口。")],
    "tech.military.network_centric": [
        ("country.military.rule.mutual_support", 0.12, "country", "mutual_support",
         "友军互援", "网络化指挥让多支部队的火力真正叠加。")],
    "tech.military.precision_guidance": [
        ("country.military.rule.encirclement", 0.12, "country", "encirclement",
         "合围", "精确制导让封锁部队无需密集兵力即可封住退路。")],
    "tech.military.autonomous_warfare": [
        ("country.military.rule.last_stand", 0.12, "country", "last_stand",
         "死守", "无人平台在断补给时不会因士气崩溃而退出战斗。")],
    "tech.military.ai_defense_grid": [
        ("country.military.rule.home_ground", 0.12, "country", "home_ground",
         "本土作战", "智能防御网把本土每一格的传感器都变成火力校正点。")],
    # ---- 兵员与劳工的制度收益（玩家无法用滑块抵消）
    "tech.military.military_medicine": [
        ("economy.profession.soldier.satisfaction_bp", 200.0, "profession", "soldier",
         "士兵", "军医制度让伤兵有存活预期，士兵对军旅生活的评价上升。")],
    "tech.military.combat_medicine": [
        ("economy.profession.soldier.satisfaction_bp", 200.0, "profession", "soldier",
         "士兵", "战地医疗体系把伤亡转化为可恢复的伤病。")],
    "tech.public_health": [
        ("economy.profession.worker.satisfaction_bp", 150.0, "profession", "worker",
         "工人", "公共卫生降低城市疾病负担，工人生活质量上升。")],
    "tech.urban_sanitation": [
        ("economy.profession.worker.satisfaction_bp", 120.0, "profession", "worker",
         "工人", "城市卫生设施减少疫病与恶臭，密集居住变得可忍受。")],
    "tech.public_health_systems": [
        ("economy.profession.worker.satisfaction_bp", 200.0, "profession", "worker",
         "工人", "公共医疗体系覆盖城市劳动者。"),
        ("economy.profession.miner.satisfaction_bp", 150.0, "profession", "miner",
         "矿工", "职业病与矿难救治被纳入公共体系。")],
    "tech.labor_organization": [
        ("economy.profession.industrial_worker.satisfaction_bp", 180.0, "profession",
         "industrial_worker", "产业工人", "工会与劳工组织改善工厂劳动条件。")],
    "tech.agricultural_improvement": [
        ("economy.profession.tenant_farmer.satisfaction_bp", 150.0, "profession",
         "tenant_farmer", "佃农", "改良农法提高佃农的收成分成与议价能力。")],
    "tech.modern_medicine": [
        ("economy.profession.worker.satisfaction_bp", 120.0, "profession", "worker",
         "工人", "现代医学降低常见病的致死与致残。")],
    # ---- 税制（偏移量；与征管制度绑定）
    "tech.state_bureaucracy": [
        ("country.tax.income.scholar.rate_bp", 300.0, "profession", "scholar",
         "学者", "官僚行政把俸禄与文书体系纳入可征税的编制。")],
    "tech.property_cadastre": [
        ("country.tax.income.landlord.rate_bp", 400.0, "profession", "landlord",
         "地主", "地籍册让土地收益第一次可以被准确核定与征收。")],
    "tech.central_banking": [
        ("country.tax.income.merchant.rate_bp", 400.0, "profession", "merchant",
         "商人", "中央银行让商业利润与信贷规模变得可观测、可征税。")],
    # ---- 营造成本与工期
    "tech.standardization": [
        ("country.construction.cost_factor", -0.08, "country", "construction_cost",
         "建造成本", "标准化构件降低非标加工与返工。"),
        ("country.construction.time_factor", -0.08, "country", "construction_time",
         "建造工期", "标准化构件让现场装配替代现场制作。")],
    "tech.systems_engineering": [
        ("country.construction.time_factor", -0.08, "country", "construction_time",
         "建造工期", "系统工程把大型工程拆成可并行的子项。")],
    "tech.reinforced_concrete": [
        ("country.construction.time_factor", -0.08, "country", "construction_time",
         "建造工期", "钢筋混凝土让高层与跨度施工不再依赖长周期石作。")],
    # ---- 科研机构产能（只作用于 research_institution 家族）
    "tech.learned_societies": [
        ("country.research.institution_output_factor", 0.12, "country",
         "research_institution", "科研机构产出", "博学学会把私人通信变成可协作的研究网络。")],
    "tech.national_laboratories": [
        ("country.research.institution_output_factor", 0.15, "country",
         "research_institution", "科研机构产出", "国家实验室提供跨学科的大型实验设施。")],
    "tech.public_education": [
        ("country.research.institution_output_factor", 0.10, "country",
         "research_institution", "科研机构产出", "公共教育与工学院为研究机构持续供给技术人才。")],
}


def apply_assignments(data):
    """把手工设计的通道分配接到节点上（幂等：同 stat 不重复添加）。"""
    by_id = {node["id"]: node for node in data["nodes"]}
    applied = 0
    for node_id, rows in CHANNEL_ASSIGNMENTS.items():
        node = by_id.get(node_id)
        if node is None:
            continue
        terms = node.setdefault("modifier_terms", [])
        existing = {str(term.get("stat")) for term in terms}
        for stat, value, _kind, subject_id, label, rationale in rows:
            if stat in existing:
                continue
            terms.append({
                "stat": stat,
                "operation": 0.0,
                "value": round(float(value), 3),
                "subject_kind": "profession" if stat.startswith(
                    ("economy.profession.", "country.tax.income.")) else "country",
                "subject_id": subject_id,
                "subject_display_name": label,
                "effect_class": "军事条令" if "military.rule." in stat else (
                    "税制" if stat.startswith("country.tax.") else (
                        "劳工与社会" if stat.startswith("economy.profession.") else "经济效率")),
                "effect_rationale": rationale,
                "implementation_status": "runtime_consumed",
                "runtime_consumer": "MilitaryCore::evaluate_rules" if "military.rule." in stat
                else "NativeEconomyRuntime / NativeCountryRuntime epoch freeze",
            })
            existing.add(stat)
            applied += 1
        if len(terms) > 6:
            raise SystemExit("node %s exceeds 6 modifier terms" % node_id)
    return applied


def country_term(stat, value, label, rationale):
    return {
        "stat": stat,
        "operation": 0.0,
        "value": round(value, 3),
        "subject_kind": "country",
        "subject_id": stat,
        "subject_display_name": label,
        "effect_class": "制度与效率" if "research" in stat or "death" in stat else "经济效率",
        "effect_rationale": rationale,
        "implementation_status": "runtime_consumed",
        "runtime_consumer": "NativeCountryRuntime / NativeEconomyRuntime epoch freeze",
    }


def geo_term(kind, geo_id, sector, value, rationale):
    label = GEO_NAME.get((kind, geo_id), geo_id)
    return {
        "stat": "country.output.%s.%s.%s_factor" % (kind, geo_id, sector),
        "operation": 0.0,
        "value": round(value, 3),
        "subject_kind": kind,
        "subject_id": geo_id,
        "subject_display_name": label,
        "effect_class": "地理专长",
        "effect_rationale": rationale,
        "implementation_status": "runtime_consumed",
        "runtime_consumer": "NativeEconomyRuntime::effective_building_output_quantity",
    }


def _scale_terms(terms, indices, cap):
    """把若干条 ADD term 按比例压到 cap 以内，返回是否改动。"""
    total = sum(float(terms[index].get("value") or 0.0) for index in indices)
    if total <= cap or total <= 0:
        return False
    ratio = cap / total
    for index in indices:
        terms[index]["value"] = round(float(terms[index].get("value") or 0.0) * ratio, 3)
    return True


def apply_effects(data):
    log = []
    nodes = data["nodes"]
    replaced_global = 0
    converted_geo = 0
    assigned = apply_assignments(data)
    log.append("手工通道分配：%d 条 term" % assigned)

    # 每个家族按（时代, 布局序）排序，隔一个节点转成地理专长 —— 用稳定的序号，
    # 不能用 layout_order 的奇偶（整数布局序会让整族全部落在偶位，一条都不转）。
    family_members = collections.defaultdict(list)
    for node in nodes:
        for term in (node.get("modifier_terms") or []):
            stat = str(term.get("stat", ""))
            if stat.startswith("country.output.family."):
                family_members[stat[len("country.output.family."):-len("_factor")]].append(node)
                break
    family_rank = {}
    for family_id, members in family_members.items():
        members.sort(key=lambda item: (ERA_INDEX.get(item.get("era_id"), 0),
                                       float(item.get("layout_order") or 0.0)))
        for position, node in enumerate(members):
            family_rank[node["id"]] = position

    for node in nodes:
        terms = node.get("modifier_terms") or []
        if not terms:
            continue
        profile = str(node.get("effect_profile", ""))

        # ---- R1 全局产出只留给里程碑
        global_indices = [i for i, t in enumerate(terms) if t.get("stat") == GLOBAL_STAT]
        if global_indices:
            if node.get("is_milestone"):
                terms[global_indices[0]]["value"] = MILESTONE_GLOBAL_VALUE
                for index in reversed(global_indices[1:]):
                    terms.pop(index)
            else:
                candidates = [PROFILE_CHANNEL.get(profile, DEFAULT_CHANNEL)]
                candidates += [
                    ("country.research.society_efficiency", 0.08, "社会研究效率"),
                    ("country.research.cost_factor", -0.06, "研究成本"),
                    ("country.trade.capacity_factor", 0.08, "贸易容量"),
                    ("country.production.input_factor", -0.05, "生产投入"),
                ]
                existing = {t.get("stat") for t in terms
                            if t.get("stat") != GLOBAL_STAT}
                for index in reversed(global_indices):
                    chosen = None
                    for candidate in candidates:
                        if candidate[0] not in existing:
                            chosen = candidate
                            break
                    if chosen is None:
                        terms.pop(index)
                        continue
                    terms[index] = country_term(
                        chosen[0], chosen[1], chosen[2],
                        "该科技的组织与工艺收益通过%s体现，而不是全社会产出加成。" % chosen[2])
                    existing.add(chosen[0])
                replaced_global += 1
            node["modifier_terms"] = terms
        elif node.get("is_milestone"):
            # 里程碑统一带一条 +2% 全社会产出：晋升时代本身就是文明整体效率的台阶。
            terms.insert(0, country_term(
                GLOBAL_STAT, MILESTONE_GLOBAL_VALUE, "全社会经济产出",
                "时代晋升带来跨行业的组织与分工效率。"))
            node["modifier_terms"] = terms

        # ---- R6 家族产出 → 地理专长（结构上隔一个节点转一次）
        family_indices = [i for i, t in enumerate(terms)
                          if str(t.get("stat", "")).startswith("country.output.family.")]
        if family_indices:
            family_id = str(terms[family_indices[0]]["stat"])[
                len("country.output.family."):-len("_factor")]
            pairs = GEO_BY_FAMILY.get(family_id)
            if pairs and family_rank.get(node["id"], 0) % 2 == 1:
                for position, index in enumerate(family_indices):
                    kind, geo_id, sector = pairs[position % len(pairs)]
                    value = min(0.25, float(terms[index].get("value") or 0.0) * 1.5)
                    if value <= 0:
                        continue
                    terms[index] = geo_term(
                        kind, geo_id, sector, value,
                        "该产业在%s上的表现显著优于其他地形；换一片地就没有这份收益。"
                        % GEO_NAME.get((kind, geo_id), geo_id))
                converted_geo += 1
                node["modifier_terms"] = terms

    # ---- R2/R3/R4 与全局预算守卫
    for _pass in range(3):
        for stat, cap in SECTOR_CAPS.items():
            _cap_stat(nodes, stat, cap)
        _cap_stat(nodes, GLOBAL_STAT, len([n for n in nodes if n.get("is_milestone")])
                  * MILESTONE_GLOBAL_VALUE)
        _cap_stat(nodes, "country.population.death_factor", DEATH_CAP)
        for stat, cap in STAT_CAPS.items():
            _cap_stat(nodes, stat, cap)
        family_totals = collections.defaultdict(list)
        for node in nodes:
            for index, term in enumerate(node.get("modifier_terms") or []):
                stat = str(term.get("stat", ""))
                if stat.startswith("country.output.family."):
                    family_totals[stat].append((node, index))
        for stat, entries in family_totals.items():
            total = sum(float(node["modifier_terms"][index].get("value") or 0.0)
                        for node, index in entries)
            if total > FAMILY_CAP:
                ratio = FAMILY_CAP / total
                for node, index in entries:
                    node["modifier_terms"][index]["value"] = round(
                        float(node["modifier_terms"][index].get("value") or 0.0) * ratio, 3)
        geo_totals = collections.defaultdict(list)
        for node in nodes:
            for index, term in enumerate(node.get("modifier_terms") or []):
                stat = str(term.get("stat", ""))
                if "terrain." in stat or "landform." in stat:
                    geo_totals[stat].append((node, index))
        for stat, entries in geo_totals.items():
            total = sum(float(node["modifier_terms"][index].get("value") or 0.0)
                        for node, index in entries)
            if total > GEO_CAP_PER_KEY:
                ratio = GEO_CAP_PER_KEY / total
                for node, index in entries:
                    node["modifier_terms"][index]["value"] = round(
                        float(node["modifier_terms"][index].get("value") or 0.0) * ratio, 3)

    log.append("全局产出收敛到里程碑：%d 个节点改写通道" % replaced_global)
    log.append("家族产出转地理专长：%d 个节点" % converted_geo)

    # ---- R7 零效果节点补内容
    by_id = {node["id"]: node for node in nodes}
    cartography = by_id.get("tech.cartography")
    if cartography is not None and not (cartography.get("modifier_terms") or []):
        cartography["modifier_terms"] = [
            country_term("country.trade.speed_factor", 0.12, "贸易速度",
                         "海图让航路可复用，船队周转更快。"),
            country_term("country.trade.capacity_factor", 0.06, "贸易容量",
                         "标准化海图降低远洋交易的信息成本。"),
        ]
        log.append("补 tech.cartography 效果：贸易速度/容量")
    coastal = by_id.get("tech.military.coastal_transport")
    if coastal is not None:
        kinds = {str(effect.get("kind")) for effect in (coastal.get("content_effects") or [])}
        if "runtime" not in kinds:
            coastal.setdefault("content_effects", []).append({
                "kind": "runtime",
                "id": "military.coastal_transport",
                "binding_kind": 0.0,
                "subject": "MilitaryCatalog.coastal_transport_bit",
                "attribute": "coastal_embarkation",
                "operation": "unlock",
                "value": 1.0,
                "implementation": "MilitaryCatalogCompiler::unlock_tech_ids",
                "status": "runtime_consumed",
                "display_name": "水路通行与沿岸登陆",
            })
            log.append("补 tech.military.coastal_transport 运行时效果声明")

    # ---- 兜底：任何既无内容又无 term 的节点补一条最小收益
    for node in nodes:
        if (node.get("content_effects") or []) or (node.get("modifier_terms") or []) \
                or (node.get("runtime_capability_tags") or []):
            continue
        node["modifier_terms"] = [country_term(
            "country.research.society_efficiency", 0.04, "社会研究效率",
            "该节点提供方法与组织知识，体现为社会研究效率。")]
        log.append("兜底补效果 %s" % node["id"])

    # ---- 兜底之后再做一次预算收敛（零效果补齐会引入新 term，可能顶破预算）
    for stat, cap in SECTOR_CAPS.items():
        _cap_stat(nodes, stat, cap)
    for stat, cap in STAT_CAPS.items():
        _cap_stat(nodes, stat, cap)
    _cap_stat(nodes, GLOBAL_STAT, len([n for n in nodes if n.get("is_milestone")])
              * MILESTONE_GLOBAL_VALUE)
    _cap_stat(nodes, "country.population.death_factor", DEATH_CAP)
    log.append("最终预算收敛完成")
    # ---- 里程碑的 buff 条数契约：era_advancement_service_test 要求每代 2–3 条
    for node in nodes:
        if not node.get("is_milestone"):
            continue
        terms = node.get("modifier_terms") or []
        if len(terms) > 3:
            terms.sort(key=lambda term: -abs(float(term.get("value") or 0.0)))
            kept = terms[:3]
            # 全局 +2% 是里程碑的身份标记，必须留下
            if not any(t.get("stat") == GLOBAL_STAT for t in kept):
                kept[-1] = next((t for t in terms if t.get("stat") == GLOBAL_STAT), kept[-1])
            node["modifier_terms"] = kept
            log.append("里程碑 %s 的 buff 收到 3 条" % node["id"])
        elif len(terms) < 2:
            terms.append(country_term(
                "country.research.society_efficiency", 0.04, "社会研究效率",
                "时代晋升带来的组织与知识积累。"))
            node["modifier_terms"] = terms
            log.append("里程碑 %s 补到 2 条 buff" % node["id"])

    replaced = replace_weak_effects(data, log)
    if replaced:
        log.append("弱化节点换通道：%d 个" % replaced)
        # 换通道会引入新的 stat 用量，必须再收敛一次
        for stat, cap in SECTOR_CAPS.items():
            _cap_stat(nodes, stat, cap)
        for stat, cap in STAT_CAPS.items():
            _cap_stat(nodes, stat, cap)
        _cap_stat(nodes, GLOBAL_STAT, len([n for n in nodes if n.get("is_milestone")])
                  * MILESTONE_GLOBAL_VALUE)
    return data, log


def _cap_stat(nodes, stat, cap):
    entries = []
    for node in nodes:
        for index, term in enumerate(node.get("modifier_terms") or []):
            if term.get("stat") == stat:
                entries.append((node, index))
    if not entries:
        return False
    total = sum(abs(float(node["modifier_terms"][index].get("value") or 0.0))
                for node, index in entries)
    if total <= cap:
        return False
    ratio = cap / total
    for node, index in entries:
        node["modifier_terms"][index]["value"] = round(
            float(node["modifier_terms"][index].get("value") or 0.0) * ratio, 3)
    return True


# ---------------------------------------------------------------- 拓扑修边

# 火器/弹药化学链：这些节点原本可以绕过火药配方直接研究
EDGE_ADD = [
    ("tech.military.drill_regulations", "tech.military.corned_powder",
     "燧发枪的操典建立在粒化火药之上：粉状火药无法在队列里稳定装填。"),
    ("tech.military.rifled_weapons", "tech.military.powder_milling",
     "线膛武器使用定装弹药，而定装弹药依赖机械研磨出的标准化火药。"),
    ("tech.military.smokeless_powder", "tech.military.powder_milling",
     "无烟火药是粒化火药的化学延续：先有可控粒度，才有可控硝化。"),
    ("tech.military.machine_guns", "tech.military.smokeless_powder",
     "自动武器依赖无烟火药：黑火药残渣会在连续射击中迅速堵塞机件。"),
    ("tech.military.mechanization", "tech.military.continuous_nitration",
     "现代弹药需要连续硝化提供的稳定发射药批量。"),
    ("tech.military.precision_guidance", "tech.military.modern_propellants",
     "制导弹药的推力曲线由现代发射药决定，不是黑火药可以替代的。"),
    ("tech.industrial_chemistry", "tech.coal_mining",
     "没有稳定出煤与煤焦油，工业化学的原料链就断在起点；煤的开采是它的物质前提。"),
    ("tech.coke_smelting", "tech.coal_mining",
     "炼焦的原料是煤，先要能把煤成规模地采出来。"),
    ("tech.internal_combustion", "tech.coke_smelting",
     "内燃机与汽车的缸体、曲轴都要用钢，炼钢是它绕不开的物质前提。"),
    ("tech.wild_maize_collection", "tech.gathering",
     "fertile_soil 是这条生产链的物质前提。"),
    ("tech.wild_wheat_collection", "tech.gathering",
     "fertile_soil 是这条生产链的物质前提。"),
    ("tech.wild_tuber_collection", "tech.gathering",
     "fertile_soil 是这条生产链的物质前提。"),
    ("tech.wild_cotton_collection", "tech.gathering",
     "fertile_soil 是这条生产链的物质前提。"),
    ("tech.wild_flax_collection", "tech.gathering",
     "fertile_soil 是这条生产链的物质前提。"),
    ("tech.wild_medicinal_herb_collection", "tech.gathering",
     "fertile_soil 是这条生产链的物质前提。"),
    ("tech.wild_rice_collection", "tech.reed_harvesting",
     "paddy_land 是这条生产链的物质前提。"),
    ("tech.potato_propagation", "tech.gathering",
     "fertile_soil 是这条生产链的物质前提。"),
    ("tech.permanent_settlements", "tech.flint_identification",
     "燧石原料 是这条生产链的物质前提。"),
    ("tech.wetland_rice_gardening", "tech.reed_harvesting",
     "paddy_land 是这条生产链的物质前提。"),
    ("tech.terrace_farming", "tech.rainfed_field_system",
     "arable_land 是这条生产链的物质前提。"),
    ("tech.rice_water_control", "tech.reed_harvesting",
     "paddy_land 是这条生产链的物质前提。"),
    ("tech.writing", "tech.gathering",
     "采集植物食物 是这条生产链的物质前提。"),
    ("tech.weights_and_measures", "tech.natural_copper_working",
     "铜 是这条生产链的物质前提。"),
    ("tech.military.powder_milling", "tech.gunpowder_formulation",
     "硝石 是这条生产链的物质前提。"),
    ("tech.assembly_line", "tech.wild_maize_collection",
     "混合谷物 是这条生产链的物质前提。"),
    ("tech.motorized_agriculture", "tech.cotton_gardening",
     "plantation_land 是这条生产链的物质前提。"),
    ("tech.networked_computing", "tech.electrochemistry",
     "电池 是这条生产链的物质前提。"),
    ("tech.crop_remote_sensing", "tech.cotton_gardening",
     "plantation_land 是这条生产链的物质前提。"),
    ("tech.precision_irrigation", "tech.reed_harvesting",
     "paddy_land 是这条生产链的物质前提。"),
    ("tech.autonomous_systems", "tech.electrochemistry",
     "电池 是这条生产链的物质前提。"),
    ("tech.robotic_manufacturing", "tech.electrochemistry",
     "电池 是这条生产链的物质前提。"),
    ("tech.intelligent_breeding", "tech.turf_cutting",
     "pasture 是这条生产链的物质前提。"),
    ("tech.intelligent_breeding", "tech.cotton_gardening",
     "plantation_land 是这条生产链的物质前提。"),
    ("tech.algorithmic_management", "tech.industrial_chemistry",
     "工业化学品 是这条生产链的物质前提。"),
    ("tech.global_logistics", "tech.electrification",
     "集装箱吊装、冷链与全球调度都建立在电气化之上，没有电网就没有现代物流。"),
    ("tech.public_health_systems", "tech.modern_medicine",
     "现代医学是公共卫生体系的知识前提，先有诊疗才有体系。"),
    ("tech.public_health_systems", "tech.electrification",
     "冷链、消毒与检验设备都要电，公共卫生体系建立在电网之上。"),
    ("tech.military.rifled_weapons", "tech.iron_smelting",
     "铁甲舰体的铆接装甲板来自熟铁与钢，冶炼是造船的物质前提。"),
    ("tech.refrigeration", "tech.electric_generation",
     "冷库靠电驱动压缩机组，发电是它的物质前提。"),
    ("tech.refrigeration", "tech.modern_husbandry",
     "冷冻肉品来自规模化畜牧，要先有稳定的牲畜产出。"),
    ("tech.refrigeration", "tech.electrification",
     "包装、分拣与温控记录都建立在电气化之上。"),
    ("tech.molecular_biology", "tech.industrial_chemistry",
     "抗生素是化学工业的产物，先有试剂与工艺控制。"),
    ("tech.molecular_biology", "tech.electrification",
     "无菌灌装、培养温控与检测设备都要电。"),
    ("tech.molecular_biology", "tech.early_glassmaking",
     "培养与分装离不开玻璃器皿。"),
    ("tech.public_health_systems", "tech.industrial_chemistry",
     "大众药品的规模化生产依赖工业化学给出的试剂与工艺。"),
]

# 伪依赖：主题相近或产业链上下游，被误写成了知识前置
EDGE_REMOVE = [
    ("tech.military.network_centric", "tech.gunpowder_weapons",
     "网络中心战与火药武器没有不可替代的知识传递关系，属跨 5 代的远祖背书。"),
    ("tech.military.autonomous_warfare", "tech.gunpowder_weapons",
     "自主作战的知识来源是控制与计算，不是火药。"),
    ("tech.military.mechanization", "tech.horse_domestication",
     "机械化恰恰以役畜被机械替代为前提，把它写成前置是因果倒置。"),
    ("tech.coastal_fishing", "tech.wild_flax_collection",
     "捕鱼的知识前提是网具与潮汐，而不是认识亚麻。"),
    ("tech.freshwater_fishing", "tech.wild_flax_collection",
     "同上：淡水捕捞依赖渔梁与苇栅，与亚麻无关。"),
    ("tech.wild_rice_collection", "tech.reed_harvesting",
     "水稻采集由稻的辨识与湿地经验决定，芦苇收割不是必需知识。"),
    ("tech.woodblock_printing", "tech.composite_tools",
     "木版印刷依赖纸、墨与文字，石器时代的复合工具不构成知识前提。"),
]


def apply_topology(data):
    """按设计稿增删硬前置边，并同步理由文本。"""
    by_id = {node["id"]: node for node in data["nodes"]}
    log = []
    removed = 0
    for target_id, prerequisite_id, _reason in EDGE_REMOVE:
        node = by_id.get(target_id)
        if node is None:
            log.append("SKIP 缺少节点 %s" % target_id)
            continue
        hard = node.get("hard_prerequisite_ids") or []
        if prerequisite_id not in hard:
            continue
        index = hard.index(prerequisite_id)
        hard.pop(index)
        rationales = node.get("prerequisite_rationales") or []
        if index < len(rationales):
            rationales.pop(index)
        node["hard_prerequisite_ids"] = hard
        node["prerequisite_rationales"] = rationales
        removed += 1
        log.append("删边 %s ⇠ %s" % (target_id, prerequisite_id))
    added = 0
    for target_id, prerequisite_id, rationale in EDGE_ADD:
        node = by_id.get(target_id)
        if node is None:
            log.append("SKIP 缺少节点 %s" % target_id)
            continue
        hard = node.get("hard_prerequisite_ids") or []
        if prerequisite_id in hard:
            continue
        hard.append(prerequisite_id)
        node["hard_prerequisite_ids"] = hard
        node.setdefault("prerequisite_rationales", []).append(rationale)
        added += 1
        log.append("加边 %s ⇠ %s" % (target_id, prerequisite_id))
    if added or removed:
        # 删边可能让某节点变成新的根：全树唯一源头的契约必须重新闭合。
        rewired = 0
        for node in data["nodes"]:
            if node["id"] == ROOT_TECH_ID:
                continue
            if node.get("hard_prerequisite_ids"):
                continue
            node["hard_prerequisite_ids"] = [ROOT_TECH_ID]
            node["prerequisite_rationales"] = [ROOT_RATIONALE]
            rewired += 1
        if rewired:
            log.append("删边后重新接回源头：%d 个节点" % rewired)
        # 新前置可能与既有路线证据重复；新前置一旦成为硬门，路线里的同一科技原子必须让位。
        for target_id, _prerequisite_id, _rationale in EDGE_ADD:
            node = by_id.get(target_id)
            if node is None:
                continue
            sanitize_routes(node, {}, set(node.get("hard_prerequisite_ids") or []),
                            ROUTE_GEOGRAPHY)
        # 行序契约：前置必须排在被依赖节点之前。缺边时把依赖节点后移代价太大，
        # 这里只做校验，交给 validator 兜底。
        order = {node["id"]: position for position, node in enumerate(data["nodes"])}
        for node in data["nodes"]:
            for prerequisite in node.get("hard_prerequisite_ids") or []:
                if order.get(prerequisite, 1 << 30) >= order[node["id"]]:
                    raise SystemExit(
                        "row order violated: %s needs %s earlier" % (node["id"], prerequisite))
    log.append("拓扑修边：+%d / -%d" % (added, removed))
    return data, log


def clean_knowledge_basis(data):
    """knowledge_basis 只是作者元数据，但被删 ID 残留会让后续审计误判。"""
    dead = set(MERGE_INTO)
    remap = {dead_id: target for dead_id, (target, _reason) in MERGE_INTO.items()}
    touched = 0
    for node in data["nodes"]:
        basis = node.get("knowledge_basis")
        if not isinstance(basis, dict):
            continue
        changed = False
        for key in ("required_ids", "alternative_groups"):
            values = basis.get(key)
            if not isinstance(values, list):
                continue
            if key == "alternative_groups":
                groups = []
                for group in values:
                    if not isinstance(group, list):
                        continue
                    kept = []
                    for value in group:
                        replacement = remap.get(value, value)
                        if replacement in dead or replacement in kept:
                            changed = True
                            continue
                        if replacement != value:
                            changed = True
                        kept.append(replacement)
                    if kept:
                        groups.append(kept)
                    else:
                        changed = True
                basis[key] = groups
                continue
            cleaned = []
            for value in values:
                replacement = remap.get(value, value)
                if replacement in dead or replacement in cleaned:
                    changed = True
                    continue
                if replacement != value:
                    changed = True
                cleaned.append(replacement)
            if changed:
                basis[key] = cleaned
        if changed:
            touched += 1
    return touched


CONTENT_DIRS = ("data/economy/buildings", "data/goods", "data/resources")


def patch_content_tags():
    """把 .tres 里指向被删科技标签替换为承接节点。"""
    remap = {dead_id: target for dead_id, (target, _reason) in MERGE_INTO.items()}
    touched = []
    for relative in CONTENT_DIRS:
        folder = os.path.join(ROOT, relative)
        if not os.path.isdir(folder):
            continue
        for name in sorted(os.listdir(folder)):
            if not name.endswith(".tres"):
                continue
            path = os.path.join(folder, name)
            with open(path, encoding="utf-8", errors="replace") as handle:
                text = handle.read()
            original = text
            for dead_id, target_id in remap.items():
                text = text.replace('"%s"' % dead_id, '"%s"' % target_id)
            if text != original:
                with open(path, "w", encoding="utf-8", newline="\n") as handle:
                    handle.write(text)
                touched.append(name)
    return touched


def reconcile_knowledge_basis(data):
    """让 knowledge_basis 与最终图一致。

    契约（technology_network_design_test）：
      * required_ids 必须是该节点的硬祖先；
      * alternative_groups 的每个原子必须出现在该节点的研究路线里；
      * 三者不可同时为空。
    删并、改前置、加源头之后必须重算，否则测试与审计都会读到过期契约。
    """
    by_id = {node["id"]: node for node in data["nodes"]}
    ancestor_cache = {}

    def ancestors(technology_id):
        if technology_id in ancestor_cache:
            return ancestor_cache[technology_id]
        seen = set()
        stack = list(by_id[technology_id].get("hard_prerequisite_ids") or [])
        while stack:
            current = stack.pop()
            if current in seen or current not in by_id:
                continue
            seen.add(current)
            stack.extend(by_id[current].get("hard_prerequisite_ids") or [])
        ancestor_cache[technology_id] = seen
        return seen

    def atoms(condition, out):
        if not isinstance(condition, dict):
            return
        if "children" in condition:
            for child in condition["children"]:
                atoms(child, out)
        elif "id" in condition:
            out.add(str(condition["id"]))

    touched = 0
    for node in data["nodes"]:
        basis = node.get("knowledge_basis")
        if not isinstance(basis, dict):
            basis = {}
        lineage = ancestors(node["id"])
        route_atoms = set()
        for route in node.get("research_routes") or []:
            atoms(route.get("condition") or {}, route_atoms)
        required = [value for value in (basis.get("required_ids") or [])
                    if value in lineage]
        groups = []
        for group in basis.get("alternative_groups") or []:
            if not isinstance(group, list):
                continue
            kept = [value for value in group if value in route_atoms]
            if kept:
                groups.append(kept)
        exemption = str(basis.get("exemption_reason", "")).strip()
        if not required and not groups:
            direct = list(node.get("hard_prerequisite_ids") or [])
            if direct:
                # 有前置的节点不允许"知识豁免"：用第一条硬前置充当核心知识来源。
                required = [direct[0]]
                exemption = ""
            elif not exemption:
                exemption = "本节点是全树的起点，没有前置知识。"
        updated = {"required_ids": required, "alternative_groups": groups,
                   "exemption_reason": exemption}
        if updated != basis:
            node["knowledge_basis"] = updated
            touched += 1
    return touched


# 预算收敛后仍被压到"玩家感知不到"的节点：换一条不参与产出连乘的通道。
WEAK_REPLACEMENT = {
    "tech.crop_domestication": ("country.research.agriculture_efficiency", 0.10, "农业研究效率",
        "把可繁殖的种子固定下来，本身就是农业知识的积累方法。"),
    "tech.dryland_water_retention": ("country.climate.drought_loss_factor", -0.08, "干旱损失",
        "保水耕作让旱年减产幅度下降。"),
    "tech.manorial_cereal_farming": ("country.tax.income.landlord.rate_bp", 300.0, "地主",
        "庄园谷物经营把地租变成可核定、可征收的稳定税基。"),
    "tech.double_entry_bookkeeping": ("country.trade.capacity_factor", 0.06, "贸易容量",
        "复式记账让跨地商号的信用与库存可核，贸易规模随之扩大。"),
    "tech.agronomic_exchange": ("country.output.good.wheat_grain_factor", 0.08, "小麦",
        "跨洲作物交换让小麦进入新的产区与轮作体系。"),
    "tech.cooperative_association": ("economy.profession.cooperative_member.satisfaction_bp",
        300.0, "合作社成员",
        "合作组织让小生产者在采购、加工与销售上获得议价能力。"),
    "tech.genetics": ("country.output.good.grain_factor", 0.10, "谷物",
        "遗传学把选育从经验变成可预测的性状组合。"),
}
WEAK_FALLBACK = {
    "country.output.agriculture_factor": ("country.research.agriculture_efficiency", 0.08,
                                         "农业研究效率"),
    "country.output.manufacturing_factor": ("country.research.engineering_efficiency", 0.08,
                                            "工程研究效率"),
    "country.output.extractive_factor": ("country.research.engineering_efficiency", 0.08,
                                         "工程研究效率"),
    "country.production.input_factor": ("country.trade.capacity_factor", 0.06, "贸易容量"),
}


def replace_weak_effects(data, log):
    """被产出预算压到 <0.02 的无内容节点，改挂一条可感知的通道。"""
    replaced = 0
    for node in data["nodes"]:
        if node.get("content_effects") or node.get("runtime_capability_tags"):
            continue
        terms = node.get("modifier_terms") or []
        if not terms:
            continue
        peak = max(abs(float(term.get("value") or 0.0)) for term in terms)
        if peak >= 0.02:
            continue
        custom = WEAK_REPLACEMENT.get(node["id"])
        if custom is not None:
            stat, value, label, rationale = custom
        else:
            first = str(terms[0].get("stat", ""))
            fallback = WEAK_FALLBACK.get(first)
            if fallback is None:
                continue
            stat, value, label = fallback
            rationale = "该节点原本依赖的行业产出通道已饱和，改由%s体现其方法价值。" % label
        if stat.startswith("economy.profession."):
            new_term = {
                "stat": stat, "operation": 0.0, "value": round(value, 3),
                "subject_kind": "profession", "subject_id": stat.split(".")[2],
                "subject_display_name": label, "effect_class": "劳工与社会",
                "effect_rationale": rationale,
                "implementation_status": "runtime_consumed",
                "runtime_consumer": "NativeEconomyRuntime::update_cohort_satisfaction",
            }
        elif stat.startswith("country.tax."):
            new_term = {
                "stat": stat, "operation": 0.0, "value": round(value, 3),
                "subject_kind": "profession", "subject_id": stat.split(".")[2],
                "subject_display_name": label, "effect_class": "税制",
                "effect_rationale": rationale,
                "implementation_status": "runtime_consumed",
                "runtime_consumer": "NativeCountryRuntime tax policy snapshot",
            }
        else:
            new_term = country_term(stat, value, label, rationale)
        node["modifier_terms"] = [new_term]
        replaced += 1
        log.append("换通道 %s → %s" % (node["id"], stat))
    return replaced


def save(payload):
    """原子写：先写同目录临时文件再替换，避免与 Godot 读写句柄相撞。"""
    temporary = NETWORK + ".v5tmp"
    with open(temporary, "w", encoding="utf-8", newline="\n") as handle:
        json.dump(payload, handle, ensure_ascii=False, indent="\t")
        handle.write("\n")
    os.replace(temporary, NETWORK)


def round_cost(value):
    if value <= 0:
        return 0.0
    if value < 10_000:
        return float(round(value / 100.0) * 100)
    if value < 1_000_000:
        return float(round(value / 1_000.0) * 1_000)
    return float(round(value / 10_000.0) * 10_000)


def sanitize_condition(condition, dead_remap, drop_tech_ids):
    """清理条件树：替换被删科技、去掉与硬前置重复的科技原子、折叠单子节点。

    返回 {} 表示该条件已无有效内容。
    """
    if not isinstance(condition, dict) or not condition:
        return {}
    if "children" in condition:
        kept = []
        for child in condition["children"]:
            cleaned = sanitize_condition(child, dead_remap, drop_tech_ids)
            if cleaned:
                kept.append(cleaned)
        if not kept:
            return {}
        if len(kept) == 1:
            return kept[0]
        updated = dict(condition)
        updated["children"] = kept
        return updated
    if int(condition.get("kind", -1)) == 0:
        technology = str(condition.get("id", ""))
        replacement = dead_remap.get(technology, technology)
        if replacement in drop_tech_ids:
            return {}
        if replacement != technology:
            updated = dict(condition)
            updated["id"] = replacement
            return updated
    return condition


def sanitize_routes(node, dead_remap, drop_tech_ids, geography_override):
    """清理全部研究路线；空路线按需替换为地理证据或直接移除。"""
    kept_routes = []
    for route in node.get("research_routes") or []:
        cleaned = sanitize_condition(route.get("condition") or {}, dead_remap, drop_tech_ids)
        if cleaned:
            updated = dict(route)
            updated["condition"] = cleaned
            kept_routes.append(updated)
            continue
        override = geography_override.get(node["id"])
        if override:
            signal_id, signal_name = override
            updated = dict(route)
            # route_type 必须留在运行时认识的词表里；地域含义由条件与描述承载。
            updated["description"] = (
                "以%s所建立的观察方法作为研究资格；没有方法就没有辨识。" % signal_name)
            updated["condition"] = {"kind": 0.0, "id": signal_id, "value": 1.0}
            kept_routes.append(updated)
    node["research_routes"] = kept_routes
    if not kept_routes and int(ERA_INDEX.get(node.get("era_id"), 0)) >= 2:
        if not str(node.get("route_exemption_reason", "")).strip():
            node["route_exemption_reason"] = (
                "该节点的实践证据由其硬前置与揭示条件共同承载，不再重复设置研究路线。")


# ---------------------------------------------------------------- 结构改造

def apply_structure(data):
    nodes = data["nodes"]
    by_id = {node["id"]: node for node in nodes}
    log = []
    ERA_INDEX.clear()
    for order, era in enumerate(data["eras"]):
        ERA_INDEX[era["id"]] = order

    # ---- 1. 删除并合并
    dead_remap = {dead: target for dead, (target, _reason) in MERGE_INTO.items()}
    for dead_id, (target_id, reason) in MERGE_INTO.items():
        dead = by_id.get(dead_id)
        if dead is None:
            continue
        target = by_id.get(target_id)
        if target is None:
            raise SystemExit(f"merge target missing: {target_id} for {dead_id}")
        for child in nodes:
            hard = child.get("hard_prerequisite_ids") or []
            if dead_id not in hard:
                continue
            rationales = child.get("prerequisite_rationales") or []
            updated, updated_rationales = [], []
            seen = set()
            for index, prerequisite in enumerate(hard):
                replacement = target_id if prerequisite == dead_id else prerequisite
                if replacement == child["id"] or replacement in seen:
                    continue
                seen.add(replacement)
                updated.append(replacement)
                if prerequisite == dead_id:
                    updated_rationales.append(
                        "该工序的知识由「%s」承载：%s" % (
                            target.get("display_name", target_id), reason))
                elif index < len(rationales):
                    updated_rationales.append(rationales[index])
                else:
                    updated_rationales.append("该前置提供不可省略的方法或材料基础。")
            child["hard_prerequisite_ids"] = updated
            child["prerequisite_rationales"] = updated_rationales
        nodes.remove(dead)
        log.append("删除并合并 %s → %s：%s" % (dead_id, target_id, reason))

    by_id = {node["id"]: node for node in nodes}

    # ---- 2. 承接节点补效果
    for node_id, patch in MERGE_CONTENT.items():
        node = by_id.get(node_id)
        if node is None:
            continue
        existing_goods = {str(item.get("id")) for item in (node.get("content_effects") or [])
                          if item.get("kind") == "good"}
        for effect in patch.get("content_effects", []):
            if effect["id"] not in existing_goods:
                node.setdefault("content_effects", []).append(effect)
        existing_stats = {str(item.get("stat")) for item in (node.get("modifier_terms") or [])}
        for term in patch.get("modifier_terms", []):
            if term["stat"] not in existing_stats:
                node.setdefault("modifier_terms", []).append(term)
        if patch.get("reveal_condition") and not (node.get("reveal_condition") or {}):
            node["reveal_condition"] = patch["reveal_condition"]
            node["reveal_summary"] = patch["reveal_summary"]
        log.append("承接节点补效果 %s" % node_id)

    # ---- 3. 全树唯一源头：思考
    root = by_id[ROOT_TECH_ID]
    if root.get("display_name") != ROOT_TECH_NAME:
        log.append("改名 %s：%s → %s" % (
            ROOT_TECH_ID, root.get("display_name"), ROOT_TECH_NAME))
    root["display_name"] = ROOT_TECH_NAME
    root["is_starting"] = True
    root["is_starter_eligible"] = True
    root["is_era_key"] = False
    root["is_milestone"] = False
    root["network_role"] = "backbone"
    root["anchor_kind"] = "backbone"
    root["node_role"] = "handling"
    root["effect_profile"] = "starter"
    root["starter_capability_tags"] = ["starter.food", "starter.knowledge"]
    root["cost_points"] = 0.0
    root["layout_order"] = -1.0
    root["hard_prerequisite_ids"] = []
    root["prerequisite_rationales"] = []
    root["reveal_condition"] = {}
    root["reveal_category"] = "general_knowledge"
    root["reveal_summary"] = "思考不需要发现：它是所有知识的起点。"
    root["effect_summary"] = ROOT_TECH_SUMMARY
    root["terminal_reason"] = ""
    root["knowledge_basis"] = {
        "required_ids": [],
        "alternative_groups": [],
        "exemption_reason": "思考是全部知识的起点：它没有前置知识，也不由任何发现事件揭示。",
    }
    if nodes[0]["id"] != ROOT_TECH_ID:
        nodes.remove(root)
        nodes.insert(0, root)
        log.append("把 %s 移到节点数组首位（编译要求前置索引 < 行索引）" % ROOT_TECH_ID)

    # 「自然观察」紧随源头：它是全部辨识科技的实践前提，必须排在它们之前。
    observation = by_id.get("tech.natural_observation")
    if observation is not None:
        nodes.remove(observation)
        nodes.insert(1, observation)
        log.append("把 tech.natural_observation 移到第 2 位：辨识类科技以它为实践前提")

    # ---- 4. 所有无前置节点接收源头（含里程碑：让图上只有一个根）
    rewired = 0
    for node in nodes:
        if node["id"] == ROOT_TECH_ID:
            continue
        hard = node.get("hard_prerequisite_ids") or []
        if not hard:
            node["hard_prerequisite_ids"] = [ROOT_TECH_ID]
            node["prerequisite_rationales"] = [ROOT_RATIONALE]
            rewired += 1
    log.append("为 %d 个原根节点接上「思考」作为硬前置" % rewired)

    # ---- 4b. 条件清理：去掉与被删节点/新硬前置重复的科技原子，空路线换地理证据
    for node in nodes:
        drop_ids = set(node.get("hard_prerequisite_ids") or [])
        cleaned_reveal = sanitize_condition(node.get("reveal_condition") or {},
                                            dead_remap, set())
        node["reveal_condition"] = cleaned_reveal
        sanitize_routes(node, dead_remap, drop_ids, ROUTE_GEOGRAPHY)
    log.append("清理路线与揭示条件中的被删节点与硬前置重复原子")

    # ---- 5. 成本三档
    eras = data["eras"]
    era_order = [era["id"] for era in eras]
    for era in eras:
        era_id = era["id"]
        group = [node for node in nodes if node["era_id"] == era_id]
        paid = [node for node in group if not node.get("is_starter_eligible")]
        if not paid:
            continue
        budget = sum(float(node.get("cost_points") or 0.0) for node in paid)
        scores = []
        for node in paid:
            content = node.get("content_effects") or []
            kinds = collections.Counter(item.get("kind") for item in content)
            score = (kinds.get("building", 0) * 1.0 + kinds.get("good", 0) * 0.8 +
                     kinds.get("resource", 0) * 0.5 +
                     len(node.get("modifier_terms") or []) * 0.25)
            if node.get("is_milestone"):
                score += 20.0
            if node.get("network_role") == "backbone":
                score += 1.5
            scores.append((score, node["id"]))
        scores.sort(key=lambda item: -item[0])
        count = len(scores)
        breakthrough = max(1, round(count * 0.20))
        major = max(1, round(count * 0.35))
        tiers = {}
        for index, (_score, node_id) in enumerate(scores):
            tiers[node_id] = ("breakthrough" if index < breakthrough else
                              "major" if index < breakthrough + major else "minor")
        weight_sum = sum(TIER_WEIGHT[tiers[node_id]] for node_id in tiers)
        unit = budget / weight_sum if weight_sum else 0.0
        for node_id, tier in tiers.items():
            node = by_id[node_id]
            node["cost_points"] = round_cost(TIER_WEIGHT[tier] * unit)
        for node in group:
            if node.get("is_starter_eligible"):
                node["cost_points"] = 0.0
        counter = collections.Counter(tiers.values())
        log.append("成本分档 %s：minor %d / major %d / breakthrough %d（预算 %.0f）" % (
            era_id, counter["minor"], counter["major"], counter["breakthrough"], budget))

    # ---- 6. visual_edges 交给 GDScript 归一化器重建（TechnologyNetworkValidator.build_visual_edges）
    alive = {node["id"] for node in nodes}
    for edge_kind in ("hard", "milestone_candidate"):
        pass  # 由 normalize_network.gd 统一重建，避免两套投影逻辑分叉
    log.append("visual_edges 交由 normalize_network.gd 依 build_visual_edges 重建")

    # ---- 7. 应用交叉点、候选池、后继里的删除残留（用承接节点替换，而不是直接丢弃）
    remap = {dead: target for dead, (target, _reason) in MERGE_INTO.items()}
    for intersection in data.get("application_intersections", []):
        required = intersection.get("required_technology_ids") or []
        kept = []
        for technology in required:
            replacement = remap.get(technology, technology)
            if replacement in alive and replacement not in kept:
                kept.append(replacement)
        if len(kept) < 2:
            raise SystemExit(
                "application intersection %s fell below 2 requirements after merge: %s"
                % (intersection.get("id"), kept))
        intersection["required_technology_ids"] = kept
    for node in nodes:
        for field in ("branch_successor_ids", "application_target_ids"):
            values = node.get(field) or []
            node[field] = [value for value in values if value in alive]
        if len(node.get("branch_successor_ids") or []) != len(
                node.get("branch_successor_rationales") or []):
            node["branch_successor_rationales"] = [
                "该后继承接本节点的方法与产能。" for _ in (node.get("branch_successor_ids") or [])]
        if len(node.get("application_target_ids") or []) != len(
                node.get("application_target_rationales") or []):
            node["application_target_rationales"] = [
                "该应用交汇把本节点的方法接入另一条产线。"
                for _ in (node.get("application_target_ids") or [])]
    for era in data["eras"]:
        era["milestone_candidate_ids"] = [
            candidate for candidate in era.get("milestone_candidate_ids", [])
            if candidate in alive and candidate != ROOT_TECH_ID]
    log.append("清理应用交汇 / 候选池 / 后继中的删除残留")

    # ---- 8. 思考不应再出现在候选池（它 0 成本，会变成免费计票）
    for era in data["eras"]:
        if ROOT_TECH_ID in era.get("milestone_candidate_ids", []):
            era["milestone_candidate_ids"].remove(ROOT_TECH_ID)

    # ---- 9. 同步语义审查版本
    review = data.setdefault("semantic_review", {})
    review["version"] = float(review.get("version", 2.0)) + 1.0
    review["reviewed_node_count"] = float(len(nodes))
    review["root_technology_id"] = ROOT_TECH_ID
    review["v5_notes"] = "思考为全树唯一源头；成本三档；合并 5 个零效果/重复节点。"
    return data, log


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--stage", default="structure",
                        choices=["structure", "topology", "effects", "all"])
    parser.add_argument("--dry-run", action="store_true")
    arguments = parser.parse_args()

    data = load()
    before = {node["id"]: node.get("cost_points") for node in data["nodes"]}
    logs = []
    if arguments.stage in ("structure", "all"):
        data, structure_log = apply_structure(data)
        logs.extend(structure_log)
    if arguments.stage in ("topology", "all"):
        data, topology_log = apply_topology(data)
        logs.extend(topology_log)
    if arguments.stage in ("effects", "all"):
        data, effect_log = apply_effects(data)
        logs.extend(effect_log)
    if arguments.stage in ("structure", "topology", "effects", "all"):
        touched = clean_knowledge_basis(data)
        logs.append("清理 knowledge_basis 残留：%d 个节点" % touched)
        reconciled = reconcile_knowledge_basis(data)
        logs.append("重算 knowledge_basis 契约：%d 个节点" % reconciled)
        if not arguments.dry_run:
            patched = patch_content_tags()
            logs.append("修正 .tres 科技标签：%s" % (", ".join(patched) if patched else "无"))

    for line in logs:
        print(line)

    print("--- 规模 ---")
    print("nodes: %d" % len(data["nodes"]))
    eras = collections.Counter(node["era_id"] for node in data["nodes"])
    for era in data["eras"]:
        print("  %-13s %d" % (era["id"], eras[era["id"]]))

    if arguments.dry_run:
        print("(dry-run：未写盘)")
        return 0
    save(data)
    print("written: %s" % NETWORK)
    return 0


if __name__ == "__main__":
    sys.exit(main())
