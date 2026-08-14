#!/usr/bin/env python3
"""Apply the explicit schema-v2 semantic topology review.

This is a one-shot authoring migration.  It never runs from the catalog build and
does not infer relationships from identifier keywords, legacy lanes, array order,
or family adjacency.  The resulting technology_network.json remains the sole
authority consumed by the game.
"""

from __future__ import annotations

import hashlib
import json
import re
from collections import defaultdict
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
NETWORK = ROOT / "data" / "technology" / "technology_network.json"
BUILDINGS_DIR = ROOT / "data" / "economy" / "buildings"


GOOD_NAMES = {
    "grain": "谷物",
    "wheat_grain": "小麦",
    "rice_grain": "稻米",
    "corn_grain": "玉米",
    "potatoes": "马铃薯",
}


def good_output_terms(good_ids: list[str], value: float,
                      group_display_name: str = "") -> list[dict]:
    """Author exact output-good modifiers without leaking into building families."""
    return [{
        "stat": f"country.output.good.{good_id}_factor",
        "operation": 0.0,
        "value": value,
        "subject_kind": "good",
        "subject_id": good_id,
        "subject_display_name": group_display_name or GOOD_NAMES[good_id],
    } for good_id in good_ids]


GOOD_NAMES.update({
    "logs": "原木", "lumber": "木材", "coal": "煤", "tools": "工具",
    "iron_ore": "铁矿石", "copper_ore": "铜矿石", "silver_ore": "银矿石",
    "gold_ore": "金矿石", "fish": "鱼", "meat": "肉类",
    "processed_food": "加工食品", "cloth": "布匹", "electricity": "电力",
    "petrochemicals": "石化产品", "plastics": "塑料", "crude_oil": "原油",
    "synthetic_fiber": "合成纤维", "printed_materials": "印刷品",
    "semiconductors": "半导体", "computers": "计算机", "copper": "铜",
})


def authored_modifier_term(stat: str, value: float, rationale_text: str) -> dict:
    """Build an explicitly reviewed term and name its real runtime consumer."""
    subject_kind, subject_id, subject_name = "society", stat, "全社会"
    effect_class = "全社会或部门影响"
    consumer = "NativeEconomyRuntime::refresh_building_modifier_factors"
    patterns = (
        ("country.output.building.", "_factor", "building", "精确生产方式产出",
         "NativeEconomyRuntime::refresh_building_modifier_factors"),
        ("country.output.family.", "_factor", "building_family", "生产家族产出",
         "NativeEconomyRuntime::refresh_building_modifier_factors"),
        ("country.output.good.", "_factor", "good", "商品产出",
         "NativeEconomyRuntime::effective_building_output_quantity"),
        ("country.input.good.", "_factor", "good", "生产投入",
         "NativeEconomyRuntime::effective_production_input_quantity"),
        ("country.consumption.good.", "_factor", "good", "家庭消费",
         "NativeEconomyRuntime::effective_household_good_quantity"),
        ("country.resource.", ".use_factor", "resource", "自然资源利用",
         "NativeEconomyRuntime::effective_resource_use_quantity"),
        ("country.resource.", ".managed_generation_factor", "resource", "自然资源再生",
         "NativeEconomyRuntime::effective_managed_resource_generation"),
    )
    for prefix, suffix, kind, klass, runtime_consumer in patterns:
        if stat.startswith(prefix) and stat.endswith(suffix):
            subject_id = stat[len(prefix):-len(suffix)]
            subject_kind, effect_class, consumer = kind, klass, runtime_consumer
            subject_name = GOOD_NAMES.get(subject_id, subject_id)
            break
    if stat.startswith("country.output.terrain.") or stat.startswith("country.output.landform."):
        subject_kind = "geography"
        subject_id = stat.removeprefix("country.output.").removesuffix("_factor")
        subject_name, effect_class = subject_id, "地理生产适应"
    elif stat == "country.production.input_factor":
        subject_name, effect_class = "全社会生产投入", "全社会生产投入"
        consumer = "NativeEconomyRuntime::effective_production_input_quantity"
    elif stat == "country.household.consumption_factor":
        subject_name, effect_class = "全社会家庭消费", "全社会家庭消费"
        consumer = "NativeEconomyRuntime::family_consumption_factor_q16"
    elif stat == "country.resource.use_factor":
        subject_name, effect_class = "全社会自然资源耗用", "全社会自然资源利用"
        consumer = "NativeEconomyRuntime::effective_resource_use_quantity"
    elif stat == "country.economy_output_factor":
        subject_name = "全社会经济产出"
    elif stat == "country.trade.speed_factor":
        subject_name, effect_class = "全社会贸易运输速度", "全社会贸易能力"
        consumer = "NativeEconomyRuntime::capture_country_epoch"
    elif stat == "country.trade.capacity_factor":
        subject_name, effect_class = "国内贸易容量", "全社会贸易能力"
        consumer = "NativeEconomyRuntime::capture_country_epoch"
    elif stat.startswith("country.research."):
        research_names = {
            "country.research.agriculture_efficiency": "农业领域研究效率",
            "country.research.engineering_efficiency": "工程领域研究效率",
            "country.research.science_efficiency": "科学领域研究效率",
            "country.research.society_efficiency": "社会领域研究效率",
            "country.research.institution_output_factor": "科研机构产出",
        }
        subject_name = research_names.get(stat, stat)
        effect_class = "研究效率"
        consumer = "NativeCountryRuntime::process_research_day"
    if stat.startswith("country.output.family."):
        family_names = {
            "staple_preparation": "主粮加工",
            "subsistence_food": "生计食物",
            "paper_making": "造纸",
            "salt_extraction": "制盐",
            "research_institution": "研究机构",
            "metal_toolmaking": "金属工具制造",
            "construction_methods": "营造方法",
            "chemical_industry": "化学工业",
            "copper_extraction": "铜矿采掘",
            "silver_extraction": "银矿采掘",
            "tin_extraction": "锡矿采掘",
            "gold_extraction": "金矿采掘",
            "steelmaking": "炼钢",
            "livestock_husbandry": "畜牧业",
            "oil_extraction": "石油开采",
            "cadastral_institution": "地籍机构",
            "maritime_operations": "航运作业",
            "cloth_weaving": "布匹织造",
            "specialty_commodity_crops": "专用商品作物",
            "renewable_power_generation": "可再生动力",
        }
        subject_id = stat[len("country.output.family."):-len("_factor")]
        subject_kind = "building_family"
        subject_name = family_names.get(subject_id, subject_id)
        effect_class = "生产家族产出"
        consumer = "NativeEconomyRuntime::refresh_building_modifier_factors"
    return {
        "stat": stat, "operation": 0.0, "value": value,
        "subject_kind": subject_kind, "subject_id": subject_id,
        "subject_display_name": subject_name, "effect_class": effect_class,
        "effect_rationale": rationale_text,
        "implementation_status": "runtime_consumed", "runtime_consumer": consumer,
    }


def collect_support_buildings() -> dict[str, list[dict]]:
    """Read the authoritative ALL support tags for presentation only."""
    result: dict[str, list[dict]] = defaultdict(list)
    pattern = re.compile(r'required_technology_tags\s*=\s*PackedStringArray\((.*?)\)', re.S)
    item_pattern = re.compile(r'"([^"]+)"')
    for path in sorted(BUILDINGS_DIR.glob("*.tres")):
        text = path.read_text(encoding="utf-8")
        match = pattern.search(text)
        if not match:
            continue
        building_id = path.stem
        display_match = re.search(r'display_name\s*=\s*"([^"]+)"', text)
        display_name = display_match.group(1) if display_match else building_id.replace("_", " ")
        for technology_id in item_pattern.findall(match.group(1)):
            result[technology_id].append({"id": building_id, "name": display_name})
    return result


def collect_direct_buildings() -> dict[str, list[dict]]:
    """Read direct BuildingProfile technology tags for catalog binding output."""
    result: dict[str, list[dict]] = defaultdict(list)
    pattern = re.compile(r'technology_tags\s*=\s*PackedStringArray\((.*?)\)', re.S)
    item_pattern = re.compile(r'"([^"]+)"')
    for path in sorted(BUILDINGS_DIR.glob("*.tres")):
        text = path.read_text(encoding="utf-8")
        match = pattern.search(text)
        if not match:
            continue
        building_id = path.stem
        display_match = re.search(r'display_name\s*=\s*"([^"]+)"', text)
        display_name = display_match.group(1) if display_match else building_id.replace("_", " ")
        for technology_id in item_pattern.findall(match.group(1)):
            if technology_id.startswith("tech."):
                result[technology_id].append({"id": building_id, "name": display_name})
    return result


def rebuild_building_bindings(nodes: list[dict], direct_buildings: dict[str, list[dict]]) -> None:
    """Synchronize authoring projections with authoritative BuildingProfile tags."""
    for node in nodes:
        node["expected_bindings"] = [binding for binding in node.get("expected_bindings", [])
            if int(binding.get("kind", 0)) != 2]
        node["content_effects"] = [effect for effect in node.get("content_effects", [])
            if effect.get("kind") != "building"]
        for building in direct_buildings.get(node["id"], []):
            node["expected_bindings"].append({"kind": 2, "id": building["id"]})
            node["content_effects"].append({
                "kind": "building", "id": building["id"], "binding_kind": 2,
                "subject": f"building.{building['id']}",
                "attribute": "construction_and_production_access",
                "operation": "unlock", "value": 1,
                "implementation": "BuildingProfile.technology_tags",
                "status": "existing_binding", "display_name": building["name"],
            })
        kind_order = {"good": 0, "building": 1, "resource": 2}
        node["content_effects"] = sorted(
            enumerate(node.get("content_effects", [])),
            key=lambda item: (kind_order.get(str(item[1].get("kind", "")), 99), item[0]))
        node["content_effects"] = [item[1] for item in node["content_effects"]]


def effect_summary(node: dict) -> str:
    parts: list[str] = []
    kind_order = {"good": 0, "building": 1, "resource": 2}
    content_effects = sorted(
        enumerate(node.get("content_effects", [])),
        key=lambda item: (kind_order.get(str(item[1].get("kind", "")), 99), item[0]))
    content_effects = [item[1] for item in content_effects]
    for effect in content_effects:
        if effect.get("operation") != "unlock":
            continue
        kind = {"building": "解锁建筑", "good": "解锁物资", "resource": "可利用资源"}.get(effect.get("kind"))
        if kind:
            parts.append(f"{kind}：{effect.get('display_name', effect.get('id', ''))}")
    for term in node.get("modifier_terms", []):
        value = float(term.get("value", 0.0))
        operation = int(term.get("operation", 0))
        if operation == 0:
            delta = value
        elif operation == 1:
            delta = -value
        elif operation == 2:
            delta = value - 1.0
        else:
            delta = 1.0 / value - 1.0 if value else 0.0
        subject = term.get("subject_display_name") or term.get("stat", "")
        stat = str(term.get("stat", ""))
        if stat.startswith(("country.output.building.", "country.output.family.",
                            "country.output.good.", "country.output.terrain.",
                            "country.output.landform.")):
            subject += "产出"
        parts.append(f"{subject} {'+' if delta >= 0 else '-'}{abs(delta) * 100:g}%")
    support = node.get("support_buildings", [])
    if support:
        names = "、".join(str(item.get("name", item.get("id", ""))) for item in support)
        parts.append(f"作为必要支撑：{names}")
    if parts:
        return "；".join(dict.fromkeys(parts))
    return "完成时代里程碑并开放下一时代" if node.get("is_milestone") else ""


# Explicit per-technology review. Ordinary societal spillovers are <=5%; large
# bonuses are narrow goods, resources or geography effects with real tradeoffs.
EFFECT_SPECS = [
    ("tech.composite_tools", "country.economy_output_factor", .03, "复合工具提高跨行业劳动效率。"),
    ("tech.writing", "country.economy_output_factor", .03, "书写减少组织的信息损失。"),
    ("tech.weights_and_measures", "country.economy_output_factor", .03, "统一度量降低交换和核验成本。"),
    ("tech.public_health", "country.economy_output_factor", .03, "疾病预防减少误工和照护损失。"),
    ("tech.public_education", "country.economy_output_factor", .04, "普及教育提高跨行业技能迁移。"),
    ("tech.corporate_management", "country.economy_output_factor", .03, "预算和责任中心改善跨厂协调。"),
    ("tech.software_engineering", "country.economy_output_factor", .03, "可靠软件降低数字流程故障成本。"),
    ("tech.networked_computing", "country.economy_output_factor", .04, "联网扩大知识和服务复用。"),
    ("tech.machine_learning", "country.economy_output_factor", .05, "预测与分类改善跨行业配置。"),
    ("tech.autonomous_systems", "country.economy_output_factor", .06, "关键节点扩大连续生产能力。"),
    ("tech.crop_domestication", "country.output.agriculture_factor", .04, "驯化知识提高全社会农业劳动的可预测性。"),
    ("tech.permanent_settlements", "country.economy_output_factor", .02, "常住聚落降低跨行业设施与劳作协调成本。"),
    ("tech.road_engineering", "country.trade.speed_factor", .04, "道路标准改善全社会陆路周转。"),
    ("tech.state_bureaucracy", "country.economy_output_factor", .02, "稳定行政记录减少征调与组织摩擦。"),
    ("tech.movable_type_printing", "country.output.knowledge_factor", .06, "活字印刷扩大知识复制与传播。"),
    ("tech.double_entry_bookkeeping", "country.production.input_factor", -.02, "复式记账揭示跨行业库存、损耗与成本浪费。"),
    ("tech.experimental_science", "country.output.knowledge_factor", .06, "可复现实验提高全社会知识生产效率。"),
    ("tech.cooperative_association", "country.economy_output_factor", .02, "合作组织降低小生产者共享资本与风险的成本。"),
    ("tech.industrial_statistics", "country.production.input_factor", -.03, "工业统计减少跨厂物料计划偏差。"),
    ("tech.factory_system", "country.output.manufacturing_factor", .06, "工厂制度提高制造流程的专业化与连续性。"),
    ("tech.mechanized_agriculture", "country.output.agriculture_factor", .06, "机械化提高全社会农业作业时效。"),
    ("tech.modern_medicine", "country.economy_output_factor", .03, "现代医学减少全社会疾病导致的劳动损失。"),
    ("tech.electrification", "country.economy_output_factor", .03, "电气化向各行业提供可分配动力。"),
    ("tech.industrial_research", "country.output.knowledge_factor", .06, "企业实验室把生产问题转化为系统知识。"),
    ("tech.national_laboratories", "country.output.knowledge_factor", .07, "国家实验机构汇集长期仪器与研究资本。"),
    ("tech.digital_computing", "country.output.knowledge_factor", .06, "数字计算提高全社会模型、记录与分析能力。"),
    ("tech.semiconductor_manufacturing", "country.output.manufacturing_factor", .05, "洁净制造与过程控制向高级制造扩散。"),
    ("tech.knowledge_economy", "country.economy_output_factor", .04, "知识服务与无形资本提高跨行业配置效率。"),
    ("tech.open_science_networks", "country.output.knowledge_factor", .06, "开放科研网络减少重复实验并扩大资料复用。"),
    ("tech.precision_agriculture", "country.output.agriculture_factor", .08, "田块级测量改善全社会农业投入配置。"),
    ("tech.climate_modeling", "country.output.agriculture_factor", .04, "气候预测减少农业时机与灾害暴露误差。"),
    ("tech.human_machine_cogovernance", "country.economy_output_factor", .03, "人机协同提高复杂社会决策的响应速度。"),
    ("tech.algorithmic_governance", "country.production.input_factor", -.03, "算法治理减少跨部门配置与采购浪费。"),
    ("tech.robotic_manufacturing", "country.output.manufacturing_factor", .08, "机器人提高制造连续性与一致性。"),
    ("tech.standardization", "country.production.input_factor", -.04, "统一规格减少返工和材料浪费。"),
    ("tech.interchangeable_parts", "country.production.input_factor", -.05, "互换件降低修配和备件投入。"),
    ("tech.industrial_quality_control", "country.production.input_factor", -.04, "过程检验减少废品。"),
    ("tech.systems_engineering", "country.production.input_factor", -.03, "接口管理减少复杂工程浪费。"),
    ("tech.industrial_ecology", "country.resource.use_factor", -.08, "闭环利用降低原生资源耗用。"),
    ("tech.mass_production", "country.output.manufacturing_factor", .12, "大批量专用流程提高制造吞吐。"),
    ("tech.mass_production", "country.household.consumption_factor", .03, "廉价标准品诱发消费反弹。"),
    ("tech.industrial_ecology", "country.output.manufacturing_factor", -.03, "闭环改造初期牺牲制造吞吐。"),

    ("tech.grain_threshing", "country.output.good.grain_factor", .18, "脱粒提高通用谷物可收获量。"),
    ("tech.grain_threshing", "country.output.good.wheat_grain_factor", .18, "脱粒减少小麦落粒损失。"),
    ("tech.grain_threshing", "country.output.good.rice_grain_factor", .18, "脱粒减少稻谷损失。"),
    ("tech.grain_threshing", "country.output.good.corn_grain_factor", .18, "脱粒式处理减少玉米籽粒损失。"),
    ("tech.wild_maize_collection", "country.output.terrain.jungle.agriculture_factor", .08, "识别野生禾本科生境，提高雨林边缘的采集与试种效率。"),
    ("tech.maize_seed_saving", "country.output.good.corn_grain_factor", .12, "留种稳定玉米收成。"),
    ("tech.maize_selection", "country.output.good.corn_grain_factor", .18, "定向选择提高玉米品系产量。"),
    ("tech.wheat_seed_saving", "country.output.good.wheat_grain_factor", .12, "留种稳定小麦收成。"),
    ("tech.rice_seed_saving", "country.output.good.rice_grain_factor", .12, "留种稳定水稻收成。"),
    ("tech.plough_agriculture", "country.output.good.grain_factor", .18, "犁耕扩大谷物有效耕作层。"),
    ("tech.plough_agriculture", "country.output.good.wheat_grain_factor", .18, "犁耕改善小麦整地。"),
    ("tech.plough_agriculture", "country.output.good.corn_grain_factor", .12, "犁耕改善玉米田整地。"),
    ("tech.crop_rotation", "country.output.good.grain_factor", .18, "轮作维持谷物地力。"),
    ("tech.intensive_crop_rotation", "country.output.good.grain_factor", .22, "密集轮作提高谷物年产出。"),
    ("tech.rice_water_control", "country.output.good.rice_grain_factor", .22, "水位控制改善稻作产量。"),
    ("tech.mechanical_reaping", "country.output.good.wheat_grain_factor", .22, "机械收割降低小麦时效损失。"),
    ("tech.mechanical_threshing", "country.output.good.wheat_grain_factor", .20, "机械脱粒提高小麦处理吞吐。"),
    ("tech.mechanical_threshing", "country.input.good.coal_factor", .04, "早期动力脱粒增加煤耗。"),
    ("tech.crop_breeding", "country.output.good.grain_factor", .12, "育种提高通用谷物潜力。"),
    ("tech.crop_breeding", "country.output.good.wheat_grain_factor", .12, "育种提高小麦潜力。"),
    ("tech.crop_breeding", "country.output.good.rice_grain_factor", .12, "育种提高水稻潜力。"),
    ("tech.crop_breeding", "country.output.good.corn_grain_factor", .12, "育种提高玉米潜力。"),
    ("tech.refrigeration", "country.consumption.good.meat_factor", -.08, "冷藏减少家庭肉类腐败。"),
    ("tech.cold_chain", "country.consumption.good.fish_factor", -.10, "冷链减少鱼类运输和家庭损耗。"),
    ("tech.cold_chain", "country.consumption.good.meat_factor", -.10, "冷链减少肉类运输和家庭损耗。"),
    ("tech.canning", "country.consumption.good.processed_food_factor", -.08, "罐藏延长加工食品保存期。"),

    ("tech.wild_wheat_collection", "country.output.terrain.steppe.agriculture_factor", .12,
     "野生小麦采集经验提高草原边缘的谷物辨识与采收效率。"),
    ("tech.wild_rice_collection", "country.output.landform.lowland.agriculture_factor", .12,
     "野生稻采集经验提高低地湿润环境中的稻作适应。"),
    ("tech.potato_propagation", "country.output.landform.plateau.agriculture_factor", .12,
     "块茎繁育方法提高高原环境中的马铃薯种植效率。"),
    ("tech.maize_garden_horticulture", "country.output.terrain.jungle.agriculture_factor", .12,
     "玉米园圃体系提高雨林边缘复合园艺的农业产出。"),
    ("tech.rainfed_wheat_cultivation", "country.output.terrain.steppe.agriculture_factor", .12,
     "雨养小麦体系提高草原气候中的农业产出。"),
    ("tech.wetland_rice_gardening", "country.output.terrain.floodplain.agriculture_factor", .12,
     "湿地稻作提高洪泛平原农业产出。"),

    ("tech.seasonal_foraging", "country.output.family.subsistence_food_factor", .12,
     "季节性采集历法提高生计食物获取效率。"),
    ("tech.automated_agriculture", "country.output.agriculture_factor", .22,
     "自动化农业提高全社会农业作业的连续性。"),
    ("tech.charcoal_burning", "country.resource.timber.use_factor", -.08,
     "炭窑控制提高木材转化效率并减少原料耗用。"),
    ("tech.bark_paper_making", "country.output.family.paper_making_factor", .12,
     "树皮纤维处理提高造纸生产方式产出。"),
    ("tech.brine_collection", "country.output.family.salt_extraction_factor", .12,
     "卤水采集提高盐业生产方式产出。"),
    ("tech.salt_preservation", "country.consumption.good.processed_food_factor", -.08,
     "盐藏减少加工食品的腐败损失。"),
    ("tech.gold_placer_identification", "country.output.family.gold_extraction_factor", .12,
     "砂金辨识提高采金生产方式产出。"),
    ("tech.silver_vein_identification", "country.output.family.silver_extraction_factor", .12,
     "银脉辨识提高采银生产方式产出。"),
    ("tech.tin_identification", "country.output.family.tin_extraction_factor", .12,
     "锡矿辨识提高采锡生产方式产出。"),
    ("tech.crucible_steel", "country.output.family.steelmaking_factor", .12,
     "坩埚控温提高炼钢生产方式产出。"),
    ("tech.coke_smelting", "country.output.family.steelmaking_factor", .12,
     "焦炭冶炼提高炼钢生产方式产出。"),
    ("tech.specialty_alloys", "country.output.family.steelmaking_factor", .28,
     "专用合金知识强化高端炼钢生产方式产出。"),
    ("tech.plant_fiber_papermaking", "country.output.family.paper_making_factor", .12,
     "植物纤维制浆提高造纸生产方式产出。"),
    ("tech.rag_paper_making", "country.output.family.paper_making_factor", .12,
     "破布回收制浆提高造纸生产方式产出。"),
    ("tech.estate_cereal_management", "country.output.good.wheat_grain_factor", .12,
     "庄园谷物核算与田间组织提高小麦产出。"),
    ("tech.reed_identification", "country.output.terrain.floodplain.agriculture_factor", .12,
     "芦苇生境辨识提高洪泛平原农业适应。"),
    ("tech.irrigation", "country.output.good.rice_grain_factor", .12,
     "基础灌溉提高稻米产出。"),
    ("tech.irrigation_surveying", "country.output.family.construction_methods_factor", .12,
     "坡降与水准测量提高水工营造产出。"),
    ("tech.canal_engineering", "country.output.family.construction_methods_factor", .12,
     "渠道、闸门与堤岸工程提高水工营造产出。"),
    ("tech.urban_waterworks", "country.output.family.construction_methods_factor", .25,
     "城市供排水体系强化大型营造方法产出。"),

    ("tech.surface_coal_use", "country.output.extractive_factor", .12,
     "露头煤利用经验提高采掘部门产出。"),
    ("tech.coal_outcrop_identification", "country.output.extractive_factor", .12,
     "煤层露头辨识提高采掘选址效率。"),
    ("tech.surface_coal_collection", "country.output.extractive_factor", .12,
     "地表煤采集提高采掘部门产出。"),
    ("tech.coal_mining", "country.resource.coal.use_factor", -.08,
     "系统采煤减少煤层损失。"),
    ("tech.mine_timbering", "country.output.extractive_factor", .12,
     "矿井木支护提高采掘作业稳定性。"),
    ("tech.mine_ventilation", "country.output.extractive_factor", .12,
     "矿井通风延长安全作业时间。"),
    ("tech.shaft_sinking", "country.output.extractive_factor", .12,
     "井筒开掘扩大可达矿体范围。"),
    ("tech.mine_drainage", "country.output.extractive_factor", .12,
     "矿井排水提高采掘作业连续性。"),
    ("tech.atmospheric_engine", "country.output.extractive_factor", .12,
     "大气式蒸汽机为矿井抽排提供连续动力。"),
    ("tech.coal_geology", "country.resource.coal.use_factor", -.08,
     "煤田地质调查减少无效掘进与煤层损失。"),
    ("tech.steam_power", "country.output.manufacturing_factor", .12,
     "通用蒸汽动力提高制造部门产出。"),
    ("tech.steam_pumping", "country.output.extractive_factor", .12,
     "蒸汽泵提高深部采掘连续性。"),
    ("tech.corporate_mining", "country.output.extractive_factor", .28,
     "公司化矿山组织强化采掘部门产出。"),
    ("tech.advanced_metallurgy", "country.output.family.steelmaking_factor", .12,
     "先进冶金提高炼钢生产方式产出。"),

    ("tech.timber_sawing", "country.resource.timber.use_factor", -.10, "锯切提高原木得材率。"),
    ("tech.steam_sawmilling", "country.resource.timber.use_factor", -.08, "动力锯切减少锯路损耗。"),
    ("tech.steam_sawmilling", "country.input.good.coal_factor", .05, "蒸汽锯木以煤耗换取吞吐。"),
    ("tech.forest_management", "country.resource.timber.managed_generation_factor", .28, "轮伐补植提高林木恢复。"),
    ("tech.controlled_burning", "country.resource.timber.managed_generation_factor", -.08, "控制燃烧短期损失木本存量。"),
    ("tech.coal_adit_mining", "country.resource.coal.use_factor", -.08, "平硐提高煤层回收率。"),
    ("tech.industrial_coal_mining", "country.resource.coal.use_factor", -.12, "工业矿井降低煤层损失。"),
    ("tech.industrial_coal_mining", "country.input.good.tools_factor", .05, "工业矿井增加工具维护负担。"),
    ("tech.deep_mining", "country.resource.iron_ore.use_factor", -.08, "深井开拓提高铁矿回采率。"),
    ("tech.mechanized_mining", "country.resource.iron_ore.use_factor", -.10, "机械采矿提高铁矿回采。"),
    ("tech.mechanized_mining", "country.resource.coal.use_factor", -.10, "机械采矿提高煤层回采。"),
    ("tech.autonomous_mining", "country.resource.iron_ore.use_factor", -.12, "传感调度减少贫化遗漏。"),
    ("tech.autonomous_mining", "country.output.extractive_factor", .15, "自主采矿提高连续作业。"),
    ("tech.copper_ore_roasting", "country.resource.copper_ore.use_factor", -.08, "焙烧改善铜回收率。"),
    ("tech.petroleum_drilling", "country.resource.oil.use_factor", -.10, "井控提高可采原油比例。"),

    ("tech.dryland_farming", "country.output.terrain.desert.agriculture_factor", .28, "旱作改善沙漠边缘农业。"),
    ("tech.dryland_farming", "country.output.terrain.cold_desert.agriculture_factor", .24, "保墒适应寒漠农业。"),
    ("tech.dryland_water_retention", "country.output.terrain.steppe.agriculture_factor", .22, "集水覆盖改善草原旱作。"),
    ("tech.terrace_farming", "country.output.landform.hill.agriculture_factor", .28, "梯田把坡地转为耕作面。"),
    ("tech.highland_tuber_farming", "country.output.landform.plateau.agriculture_factor", .32, "块茎体系适应高原短季。"),
    ("tech.highland_tuber_farming", "country.output.landform.mountain.agriculture_factor", .24, "畦作稳定山地农业。"),
    ("tech.flood_recession_wheat", "country.output.terrain.floodplain.agriculture_factor", .25, "退水播种利用洪泛沉积。"),
    ("tech.flood_recession_maize", "country.output.terrain.floodplain.agriculture_factor", .25, "退水玉米利用洪泛水肥。"),
    ("tech.paddy_bunding", "country.output.landform.lowland.agriculture_factor", .22, "田埂蓄水改善低地稻作。"),
    ("tech.rice_paddy_cultivation", "country.output.terrain.floodplain.agriculture_factor", .25, "水田利用洪泛水文。"),
    ("tech.spice_shade_gardening", "country.output.terrain.jungle.agriculture_factor", .24, "遮阴园艺适应雨林微气候。"),
    ("tech.forest_management", "country.output.terrain.forest.extractive_factor", .22, "轮伐调查提高森林采集。"),
    ("tech.coal_adit_mining", "country.output.landform.hill.extractive_factor", .20, "平硐利用丘陵露头。"),
    ("tech.deep_mining", "country.output.landform.mountain.extractive_factor", .24, "支护通风适应山地深矿。"),
    ("tech.geological_prospecting", "country.output.terrain.badlands.extractive_factor", .18, "踏勘提高裸岩地区找矿。"),
    ("tech.geological_prospecting", "country.output.landform.plateau.extractive_factor", .18, "构造测绘改善高原找矿。"),
    ("tech.mineral_spectral_survey", "country.output.terrain.desert.extractive_factor", .25, "光谱遥感提高沙漠找矿。"),
    ("tech.wind_power", "country.output.terrain.steppe.energy_factor", .24, "开阔风场提高风能产出。"),
    ("tech.wind_power", "country.output.landform.plateau.energy_factor", .22, "高原风场提高利用率。"),
    ("tech.water_power", "country.output.landform.rift_valley.energy_factor", .20, "高差和集中水流改善水力利用。"),
    ("tech.hydraulic_engineering", "country.output.landform.delta.agriculture_factor", .18, "堤渠分洪改善三角洲农业。"),
    ("tech.hydraulic_engineering", "country.output.landform.delta.manufacturing_factor", -.05, "大型水工维护占用制造能力。"),

    ("tech.steam_sealing", "country.input.good.coal_factor", -.08, "密封减少蒸汽系统煤耗。"),
    ("tech.thermodynamics", "country.input.good.coal_factor", -.08, "热力学减少动力煤耗。"),
    ("tech.electric_motors", "country.input.good.coal_factor", -.04, "电传动替代分散蒸汽煤耗。"),
    ("tech.electrification", "country.input.good.copper_factor", .05, "电气化扩大铜线需求。"),
    ("tech.electric_grid", "country.output.good.electricity_factor", .18, "联网调度提高电力输出。"),
    ("tech.smart_grid", "country.output.good.electricity_factor", .22, "智能调度降低电网拥塞。"),
    ("tech.petrochemical_cracking", "country.output.good.petrochemicals_factor", .22, "裂解扩大石化品收率。"),
    ("tech.petrochemical_cracking", "country.input.good.crude_oil_factor", .06, "高吞吐裂解扩大原油需求。"),
    ("tech.textile_machinery", "country.output.good.cloth_factor", .20, "机械纺织提高布匹产量。"),
    ("tech.textile_machinery", "country.input.good.coal_factor", .04, "早期纺机增加煤动力需求。"),
    ("tech.mechanized_printing", "country.output.good.printed_materials_factor", .22, "机械印刷提高印刷品吞吐。"),
]


# Explicit completion pass for every paid, non-milestone technology that does
# not already have a reviewed numeric package above. Membership is authored;
# no keyword, lane adjacency, or array-position inference is used. The terminal
# value is selected only after explicit topology has been resolved.
EFFECT_COMPLETION_GROUPS = [
    (["tech.seasonal_foraging", "tech.food_storage", "tech.hearth_preservation",
      "tech.seed_selection", "tech.rainfed_field_system", "tech.public_storehouses",
      "tech.fermentation", "tech.tenant_cereal_farming", "tech.urban_food_supply",
      "tech.regional_granaries", "tech.oceanic_provisioning", "tech.agronomic_exchange",
      "tech.automated_agriculture"],
     "country.output.family.staple_preparation_factor", .12, .25,
     "储藏、加工与供给组织减少主粮处理损失。"),
    (["tech.communal_specialization", "tech.household_production", "tech.record_keeping",
      "tech.chartered_universities", "tech.indentured_contracts", "tech.political_economy",
      "tech.operations_research"],
     "country.research.society_efficiency", .08, .20,
     "制度记录与组织经验提高社会领域研究效率。"),
    (["tech.oral_tradition", "tech.scholarly_academies", "tech.manuscript_culture",
      "tech.woodblock_printing", "tech.scholastic_method", "tech.screw_press_printing"],
     "country.output.family.research_institution_factor", .12, .25,
     "知识保存与复制提高研究机构的有效产出。"),
    (["tech.precision_engineering", "tech.mechanical_workshops", "tech.machine_tools",
      "tech.electronic_control"],
     "country.output.family.metal_toolmaking_factor", .12, .25,
     "工具、机床与控制能力提高金属工具制造产出。"),
    (["tech.market_institutions", "tech.currency", "tech.commercial_estates",
      "tech.mercantile_networks", "tech.chartered_companies", "tech.digital_marketplaces"],
     "country.trade.capacity_factor", .08, .20,
     "市场组织与结算网络扩大国内贸易容量。"),
    (["tech.radio", "tech.telecommunications", "tech.information_theory", "tech.digital_control",
      "tech.sensor_networks", "tech.neural_networks", "tech.distributed_intelligence",
      "tech.scientific_agents"],
     "country.research.science_efficiency", .08, .22,
     "通信、计算与控制方法提高科学研究效率。"),
    (["tech.clay_identification", "tech.ground_stone_tools", "tech.flint_identification",
      "tech.clay_preparation", "tech.hand_pottery", "tech.kiln_firing", "tech.pottery",
      "tech.adobe_making", "tech.early_glassmaking", "tech.masonry"],
     "country.output.family.construction_methods_factor", .12, .25,
     "材料识别与成形工艺提高建材和营造方法产出。"),
    (["tech.electromagnetic_induction", "tech.electric_generation", "tech.nuclear_fission",
      "tech.nuclear_energy", "tech.nuclear_fuel_cycle"],
     "country.output.energy_factor", .10, .24,
     "发电与燃料循环知识提高能源部门产出。"),
    (["tech.charcoal_burning", "tech.bark_paper_making"],
     "country.output.good.logs_factor", .12, .25,
     "木本原料处理提高可用原木与纤维材料产出。"),
    (["tech.cartography", "tech.deep_geophysics", "tech.satellite_observation",
      "tech.numerical_weather_prediction", "tech.crop_remote_sensing",
      "tech.hydrological_remote_sensing", "tech.geographic_information_systems"],
     "country.output.family.geospatial_analysis_institution_factor", .12, .28,
     "测绘、遥感与地理分析提高地理空间机构产出。"),
    (["tech.surface_coal_use", "tech.iron_ore_identification", "tech.surface_iron_collection",
      "tech.iron_smelting", "tech.coal_outcrop_identification", "tech.surface_coal_collection",
      "tech.blast_furnace", "tech.coal_mining", "tech.mine_timbering", "tech.mine_ventilation",
      "tech.shaft_sinking", "tech.mine_drainage", "tech.atmospheric_engine", "tech.coal_geology",
      "tech.steam_power", "tech.steam_pumping", "tech.corporate_mining",
      "tech.advanced_metallurgy"],
     "country.output.family.iron_extraction_factor", .12, .28,
     "矿井、冶炼与动力体系提高铁矿采掘链产出。"),
    (["tech.brine_collection", "tech.salt_preservation", "tech.gunpowder_formulation",
      "tech.gunpowder_weapons", "tech.industrial_chemistry", "tech.fertilizer_processing",
      "tech.electrochemistry"],
     "country.output.family.chemical_industry_factor", .12, .25,
     "配方、反应与过程控制提高化学工业产出。"),
    (["tech.guild_organization", "tech.guild_apprenticeship", "tech.wage_contracts",
      "tech.industrial_organization", "tech.labor_organization", "tech.managerial_hierarchy",
      "tech.assembly_line", "tech.worker_cooperatives", "tech.state_enterprises",
      "tech.platform_coordination", "tech.human_machine_collaboration",
      "tech.algorithmic_management", "tech.knowledge_cooperatives",
      "tech.autonomous_labor_coordination"],
     "country.output.manufacturing_factor", .08, .22,
     "劳动分工与管理协调提高制造部门产出。"),
    (["tech.household_landholding", "tech.communal_field_coordination", "tech.customary_tenancy",
      "tech.sharecropping", "tech.estate_accounting", "tech.manorial_jurisdiction",
      "tech.serf_obligations", "tech.manorial_cereal_farming", "tech.commercial_tenancy",
      "tech.long_term_leases", "tech.property_cadastre"],
     "country.output.family.cadastral_institution_factor", .12, .25,
     "地权、租佃与核算制度提高土地登记和经营协调产出。"),
    (["tech.maize_identification", "tech.maize_propagation", "tech.maize_garden_horticulture",
      "tech.swidden_maize_cultivation", "tech.rainfed_maize_cultivation",
      "tech.synthetic_fertilizer", "tech.industrial_agronomy"],
     "country.output.good.corn_grain_factor", .12, .25,
     "辨识、繁育与田间体系提高玉米产出。"),
    (["tech.fishing_boats", "tech.river_transport", "tech.magnetic_navigation",
      "tech.celestial_navigation", "tech.oceanic_navigation", "tech.oceanic_ship_design",
      "tech.coastal_shipyards", "tech.rail_logistics", "tech.global_logistics",
      "tech.automated_logistics", "tech.autonomous_logistics"],
     "country.output.family.maritime_operations_factor", .12, .28,
     "导航、船舶与物流组织提高运输生产方式产出。"),
    (["tech.seasonal_calendar", "tech.celestial_calendars", "tech.mechanical_timekeeping",
      "tech.probability_statistics", "tech.precision_instruments"],
     "country.research.engineering_efficiency", .08, .20,
     "计时、测量与统计提高工程研究效率。"),
    (["tech.natural_observation", "tech.natural_philosophy", "tech.interregional_botany",
      "tech.crop_transplantation", "tech.crop_acclimatization", "tech.scientific_classification",
      "tech.learned_societies", "tech.soil_experimentation", "tech.biotechnology",
      "tech.bioinformatics", "tech.computational_biology", "tech.intelligent_breeding"],
     "country.research.agriculture_efficiency", .08, .22,
     "自然观察、生物分类与育种方法提高农业研究效率。"),
    (["tech.natural_copper_identification", "tech.natural_copper_working", "tech.copper_annealing",
      "tech.tin_identification", "tech.gold_placer_identification", "tech.silver_vein_identification",
      "tech.copper_metallurgy", "tech.bronze_casting", "tech.crucible_steel",
      "tech.coke_smelting", "tech.specialty_alloys"],
     "country.output.family.copper_extraction_factor", .12, .28,
     "有色矿物辨识与冶金工艺提高铜及合金原料链产出。"),
    (["tech.animal_husbandry", "tech.animal_tracking", "tech.herd_management", "tech.pastoralism",
      "tech.horse_domestication", "tech.animal_traction", "tech.dairy_processing",
      "tech.hide_tanning", "tech.wool_husbandry", "tech.meat_processing",
      "tech.parchment_making", "tech.pastoral_networks", "tech.livestock_breeding",
      "tech.modern_husbandry", "tech.corporate_agribusiness"],
     "country.output.family.livestock_husbandry_factor", .12, .28,
     "畜群管理、繁育与加工体系提高畜牧业产出。"),
    (["tech.petroleum_extraction", "tech.petroleum_refining", "tech.internal_combustion",
      "tech.petrochemical_industry", "tech.synthetic_materials", "tech.plastics_engineering"],
     "country.output.family.oil_extraction_factor", .12, .28,
     "石油开采、炼制与材料应用提高石油产业链产出。"),
    (["tech.urban_sanitation", "tech.public_health_systems"],
     "country.output.good.pharmaceuticals_factor", .12, .25,
     "卫生组织与防疫体系提高药品有效供给。"),
    (["tech.rice_identification", "tech.wild_rice_collection", "tech.upland_rice_propagation",
      "tech.wetland_rice_gardening", "tech.tenant_paddy_management",
      "tech.estate_paddy_management", "tech.agricultural_cooperatives",
      "tech.precision_irrigation", "tech.adaptive_irrigation"],
     "country.output.good.rice_grain_factor", .12, .28,
     "稻类辨识、水田组织与灌溉控制提高稻米产出。"),
    (["tech.fiber_twisting", "tech.flax_identification", "tech.weaving", "tech.loom_weaving",
      "tech.flax_retting", "tech.hand_spinning", "tech.cotton_ginning",
      "tech.plant_fiber_papermaking", "tech.rag_paper_making",
      "tech.synthetic_fiber_engineering"],
     "country.output.family.cloth_weaving_factor", .12, .25,
     "纤维处理、纺纱与织造方法提高布匹生产链产出。"),
    (["tech.cotton_identification", "tech.wild_cotton_collection", "tech.spice_identification",
      "tech.wild_spice_collection", "tech.rubber_identification", "tech.wild_latex_tapping",
      "tech.spice_cultivation", "tech.rubber_working", "tech.cotton_gardening",
      "tech.latex_smoke_coagulation", "tech.commodity_crop_management",
      "tech.estate_plantation_management"],
     "country.output.family.specialty_commodity_crops_factor", .12, .28,
     "热带作物辨识、栽培与商品化提高专用经济作物产出。"),
    (["tech.potato_identification", "tech.tuber_storage", "tech.potato_propagation",
      "tech.ridge_tuber_cultivation", "tech.frost_protected_storage",
      "tech.estate_cereal_management"],
     "country.output.good.potatoes_factor", .12, .25,
     "块茎辨识、保存与高地栽培提高马铃薯产出。"),
    (["tech.reed_identification", "tech.irrigation", "tech.irrigation_surveying",
      "tech.canal_engineering", "tech.urban_waterworks"],
     "country.output.family.renewable_power_generation_factor", .12, .25,
     "水文识别、测量与水工建设提高可再生动力设施产出。"),
    (["tech.wheat_identification", "tech.wild_wheat_collection", "tech.wheat_propagation",
      "tech.rainfed_wheat_cultivation", "tech.dryland_wheat_cultivation", "tech.grain_baking",
      "tech.agricultural_improvement", "tech.motorized_agriculture",
      "tech.collective_agriculture"],
     "country.output.good.wheat_grain_factor", .12, .28,
     "小麦辨识、繁育与旱作体系提高小麦产出。"),
]


FAMILY_OVERRIDES = {
    "tech.fire_control": "branch.industrial_chemistry",
    "tech.controlled_burning": "branch.forest_biomass",
    "tech.freshwater_fishing": "branch.maritime_logistics",
    "tech.gold_placer_identification": "branch.nonferrous_metals",
    "tech.gold_panning": "branch.nonferrous_metals",
    "tech.silver_vein_identification": "branch.nonferrous_metals",
    "tech.surface_silver_collection": "branch.nonferrous_metals",
    "tech.wild_latex_tapping": "branch.tropical_commodities",
    "tech.rubber_working": "branch.tropical_commodities",
    "tech.pottery": "branch.construction_materials",
    "tech.kiln_firing": "branch.construction_materials",
    "tech.animal_traction": "branch.pastoral_livestock",
    "tech.natural_philosophy": "branch.natural_history",
    "tech.surface_coal_use": "branch.heavy_industry",
    "tech.wind_power": "branch.water_wind",
    "tech.coal_mining": "branch.heavy_industry",
    "tech.urban_waterworks": "branch.water_wind",
    "tech.screw_press_printing": "backbone.knowledge_computation",
    "tech.celestial_navigation": "branch.maritime_logistics",
    "tech.coastal_shipyards": "branch.maritime_logistics",
    "tech.shaft_sinking": "branch.heavy_industry",
    "tech.mine_drainage": "branch.heavy_industry",
    "tech.chartered_companies": "branch.commerce_finance",
    "tech.commodity_crop_management": "branch.tropical_commodities",
    "tech.agronomic_exchange": "backbone.food_storage",
    "tech.crop_transplantation": "branch.natural_history",
    "tech.learned_societies": "branch.natural_history",
    "tech.soil_experimentation": "branch.natural_history",
    "tech.livestock_breeding": "branch.pastoral_livestock",
    "tech.precision_instruments": "branch.measurement_instruments",
    "tech.coal_geology": "branch.heavy_industry",
    "tech.steam_sealing": "branch.heavy_industry",
    "tech.steam_power": "branch.heavy_industry",
    "tech.steam_pumping": "branch.heavy_industry",
    "tech.mechanized_agriculture": "backbone.tools_machinery",
    "tech.fertilizer_processing": "branch.industrial_chemistry",
    "tech.mechanized_printing": "backbone.knowledge_computation",
    "tech.mechanical_reaping": "branch.wheat_rainfed",
    "tech.assembly_line": "branch.labor_management",
    "tech.electrification": "branch.electric_intelligent_energy",
    "tech.electrochemistry": "branch.industrial_chemistry",
    "tech.radio": "branch.computation_control",
    "tech.mass_production": "branch.labor_management",
    "tech.telecommunications": "branch.computation_control",
    "tech.electromagnetic_induction": "branch.electric_intelligent_energy",
    "tech.electric_generation": "branch.electric_intelligent_energy",
    "tech.electric_motors": "branch.electric_intelligent_energy",
    "tech.petroleum_drilling": "branch.petroleum_materials",
    "tech.national_laboratories": "backbone.knowledge_computation",
    "tech.advanced_metallurgy": "branch.heavy_industry",
    "tech.synthetic_materials": "branch.petroleum_materials",
    "tech.petrochemical_cracking": "branch.petroleum_materials",
    "tech.plastics_engineering": "branch.petroleum_materials",
    "tech.state_enterprises": "branch.labor_management",
    "tech.industrial_ecology": "branch.industrial_chemistry",
    "tech.systems_engineering": "branch.computation_control",
    "tech.platform_coordination": "branch.labor_management",
    "tech.robotic_manufacturing": "branch.heavy_industry",
    "tech.autonomous_mining": "branch.heavy_industry",
    "tech.algorithmic_governance": "branch.labor_management",
    "tech.human_machine_cogovernance": "branch.labor_management",
    "tech.knowledge_cooperatives": "branch.labor_management",
}


# Every entry is an authored direct knowledge dependency.  These overrides cover
# the routes found semantically inconsistent during the 361-node review.
HARD_OVERRIDES = {
    "tech.pottery": ["tech.hand_pottery", "tech.kiln_firing"],
    "tech.irrigation": ["tech.permanent_settlements", "tech.flood_calendar_practice", "tech.ground_stone_tools"],
    "tech.terrace_farming": ["tech.tuber_storage", "tech.ground_stone_tools"],
    "tech.spice_cultivation": ["tech.wild_spice_collection", "tech.seed_selection"],
    "tech.weaving": ["tech.fiber_twisting"],
    "tech.paddy_bunding": ["tech.wild_rice_collection", "tech.earth_building"],
    "tech.surface_silver_collection": ["tech.silver_vein_identification"],
    "tech.kiln_firing": ["tech.fire_control", "tech.clay_preparation"],
    "tech.animal_traction": ["tech.animal_husbandry", "tech.plough_agriculture"],
    "tech.iron_smelting": ["tech.surface_iron_collection", "tech.charcoal_burning", "tech.kiln_firing"],
    "tech.market_institutions": ["tech.early_trade", "tech.record_keeping"],
    "tech.natural_philosophy": ["tech.natural_observation", "tech.writing", "tech.scholarly_academies"],
    "tech.coal_mining": ["tech.surface_coal_collection", "tech.iron_smelting"],
    "tech.gunpowder_formulation": ["tech.kiln_firing", "tech.weights_and_measures", "tech.brine_collection"],
    "tech.coastal_shipyards": ["tech.oceanic_ship_design", "tech.timber_sawing", "tech.guild_organization"],
    "tech.screw_press_printing": ["tech.movable_type_printing", "tech.timber_sawing"],
    "tech.oceanic_navigation": ["tech.cartography", "tech.river_transport"],
    "tech.deep_mining": ["tech.shaft_sinking", "tech.mine_ventilation", "tech.blast_furnace"],
    "tech.interregional_botany": ["tech.natural_philosophy", "tech.agronomic_exchange", "tech.oceanic_navigation"],
    "tech.crop_acclimatization": ["tech.interregional_botany", "tech.crop_transplantation"],
    "tech.mercantile_networks": ["tech.market_institutions", "tech.oceanic_navigation", "tech.double_entry_bookkeeping"],
    "tech.mine_drainage": ["tech.water_power", "tech.shaft_sinking"],
    "tech.chartered_companies": ["tech.mercantile_networks", "tech.double_entry_bookkeeping", "tech.state_bureaucracy"],
    "tech.estate_plantation_management": ["tech.commercial_tenancy", "tech.commodity_crop_management", "tech.estate_accounting"],
    "tech.commodity_crop_management": ["tech.cotton_gardening", "tech.spice_shade_gardening", "tech.estate_accounting"],
    "tech.oceanic_provisioning": ["tech.oceanic_navigation", "tech.salt_preservation", "tech.regional_granaries"],
    "tech.scientific_classification": ["tech.natural_philosophy"],
    "tech.crop_breeding": ["tech.seed_selection", "tech.scientific_classification"],
    "tech.public_health": ["tech.urban_sanitation", "tech.experimental_science"],
    "tech.hydraulic_engineering": ["tech.canal_engineering", "tech.irrigation_surveying", "tech.standardization"],
    "tech.geological_prospecting": ["tech.natural_philosophy", "tech.cartography", "tech.shaft_sinking"],
    "tech.learned_societies": ["tech.scholastic_method", "tech.chartered_universities", "tech.screw_press_printing"],
    "tech.steam_sealing": ["tech.precision_engineering", "tech.mechanical_workshops"],
    "tech.canning": ["tech.salt_preservation", "tech.precision_engineering"],
    "tech.industrial_coal_mining": ["tech.coal_mining", "tech.mine_timbering", "tech.atmospheric_engine"],
    "tech.coke_smelting": ["tech.blast_furnace", "tech.industrial_coal_mining"],
    "tech.steam_power": ["tech.atmospheric_engine", "tech.steam_sealing", "tech.machine_tools"],
    "tech.industrial_organization": ["tech.guild_organization", "tech.double_entry_bookkeeping"],
    "tech.steam_pumping": ["tech.mine_drainage", "tech.steam_power", "tech.machine_tools"],
    "tech.textile_machinery": ["tech.loom_weaving", "tech.machine_tools", "tech.factory_system"],
    "tech.rail_logistics": ["tech.steam_power", "tech.road_engineering", "tech.precision_instruments"],
    "tech.industrial_chemistry": ["tech.experimental_science", "tech.standardization", "tech.gunpowder_formulation"],
    "tech.fertilizer_processing": ["tech.soil_experimentation", "tech.geological_prospecting", "tech.industrial_chemistry"],
    "tech.mechanized_printing": ["tech.screw_press_printing", "tech.steam_power", "tech.machine_tools"],
    "tech.labor_organization": ["tech.factory_system", "tech.wage_contracts", "tech.industrial_organization"],
    "tech.mechanical_reaping": ["tech.machine_tools", "tech.mechanized_agriculture"],
    "tech.mechanical_threshing": ["tech.machine_tools", "tech.mechanized_agriculture"],
    "tech.managerial_hierarchy": ["tech.industrial_organization", "tech.factory_system", "tech.double_entry_bookkeeping"],
    "tech.interchangeable_parts": ["tech.standardization", "tech.machine_tools"],
    "tech.assembly_line": ["tech.interchangeable_parts", "tech.factory_system", "tech.industrial_organization"],
    "tech.steam_sawmilling": ["tech.timber_sawing", "tech.steam_power", "tech.machine_tools"],
    "tech.synthetic_fertilizer": ["tech.fertilizer_processing"],
    "tech.electrochemistry": ["tech.experimental_science", "tech.electromagnetic_induction", "tech.industrial_chemistry"],
    "tech.radio": ["tech.electromagnetic_induction", "tech.experimental_science"],
    "tech.petroleum_extraction": ["tech.geological_prospecting", "tech.steam_power"],
    "tech.electric_grid": ["tech.electric_generation", "tech.electrification", "tech.standardization"],
    "tech.refrigeration": ["tech.thermodynamics", "tech.machine_tools"],
    "tech.cold_chain": ["tech.refrigeration", "tech.rail_logistics"],
    "tech.modern_medicine": ["tech.public_health", "tech.industrial_chemistry", "tech.experimental_science"],
    "tech.telecommunications": ["tech.radio", "tech.electric_grid"],
    "tech.electromagnetic_induction": ["tech.experimental_science", "tech.precision_instruments"],
    "tech.electric_generation": ["tech.electromagnetic_induction", "tech.steam_power"],
    "tech.electric_motors": ["tech.electromagnetic_induction", "tech.machine_tools", "tech.electric_generation"],
    "tech.modern_husbandry": ["tech.animal_husbandry"],
    "tech.corporate_management": ["tech.managerial_hierarchy", "tech.double_entry_bookkeeping", "tech.industrial_statistics"],
    "tech.petroleum_drilling": ["tech.petroleum_extraction", "tech.machine_tools"],
    "tech.industrial_quality_control": ["tech.standardization", "tech.industrial_statistics", "tech.industrial_research"],
    "tech.advanced_metallurgy": ["tech.blast_furnace", "tech.industrial_chemistry"],
    "tech.nuclear_fission": ["tech.experimental_science", "tech.electromagnetic_induction", "tech.industrial_research"],
    "tech.national_laboratories": ["tech.industrial_research", "tech.public_education", "tech.state_bureaucracy"],
    "tech.synthetic_materials": ["tech.industrial_chemistry", "tech.petrochemical_industry", "tech.rubber_working"],
    "tech.mechanized_mining": ["tech.industrial_coal_mining", "tech.machine_tools", "tech.internal_combustion"],
    "tech.global_logistics": ["tech.mercantile_networks"],
    "tech.specialty_alloys": ["tech.advanced_metallurgy", "tech.industrial_quality_control"],
    "tech.petrochemical_cracking": ["tech.petrochemical_industry", "tech.industrial_chemistry", "tech.thermodynamics"],
    "tech.plastics_engineering": ["tech.petrochemical_industry", "tech.industrial_chemistry"],
    "tech.corporate_agribusiness": ["tech.corporate_management", "tech.industrial_agronomy", "tech.global_logistics"],
    "tech.collective_agriculture": ["tech.state_enterprises", "tech.industrial_agronomy"],
    "tech.state_enterprises": ["tech.state_bureaucracy", "tech.factory_system", "tech.cooperative_association"],
    "tech.synthetic_fiber_engineering": ["tech.industrial_chemistry", "tech.petrochemical_industry", "tech.textile_machinery"],
    "tech.industrial_ecology": ["tech.industrial_chemistry", "tech.public_health_systems", "tech.industrial_statistics"],
    "tech.systems_engineering": ["tech.operations_research", "tech.electronic_control", "tech.industrial_statistics"],
    "tech.information_theory": ["tech.digital_computing", "tech.probability_statistics", "tech.telecommunications"],
    "tech.software_engineering": ["tech.digital_computing", "tech.information_theory"],
    "tech.networked_computing": ["tech.software_engineering", "tech.telecommunications", "tech.digital_computing"],
    "tech.satellite_observation": ["tech.telecommunications", "tech.electronic_control", "tech.precision_instruments", "tech.deep_geophysics"],
    "tech.biotechnology": ["tech.scientific_classification", "tech.modern_medicine", "tech.industrial_research"],
    "tech.mineral_spectral_survey": ["tech.satellite_observation", "tech.deep_geophysics", "tech.precision_instruments"],
    "tech.numerical_weather_prediction": ["tech.probability_statistics", "tech.digital_computing", "tech.satellite_observation"],
    "tech.crop_remote_sensing": ["tech.satellite_observation", "tech.precision_agriculture"],
    "tech.hydrological_remote_sensing": ["tech.satellite_observation", "tech.deep_geophysics"],
    "tech.open_science_networks": ["tech.networked_computing", "tech.public_education", "tech.learned_societies"],
    "tech.platform_coordination": ["tech.networked_computing", "tech.operations_research", "tech.corporate_management"],
    "tech.precision_irrigation": ["tech.hydraulic_engineering", "tech.digital_control", "tech.geographic_information_systems"],
    "tech.digital_marketplaces": ["tech.networked_computing", "tech.market_institutions", "tech.global_logistics"],
    "tech.geographic_information_systems": ["tech.cartography", "tech.digital_computing", "tech.probability_statistics"],
    "tech.sensor_networks": ["tech.electronic_control", "tech.telecommunications", "tech.semiconductor_manufacturing"],
    "tech.bioinformatics": ["tech.biotechnology", "tech.digital_computing", "tech.scientific_classification"],
    "tech.machine_learning": ["tech.digital_computing", "tech.national_laboratories"],
    "tech.neural_networks": ["tech.machine_learning", "tech.software_engineering"],
    "tech.human_machine_collaboration": ["tech.labor_organization", "tech.platform_coordination", "tech.machine_learning"],
    "tech.algorithmic_governance": ["tech.digital_computing", "tech.operations_research", "tech.platform_coordination"],
    "tech.distributed_intelligence": ["tech.networked_computing", "tech.semiconductor_manufacturing", "tech.sensor_networks"],
    "tech.intelligent_breeding": ["tech.crop_breeding", "tech.bioinformatics", "tech.machine_learning"],
    "tech.scientific_agents": ["tech.machine_learning", "tech.open_science_networks", "tech.software_engineering"],
    "tech.human_machine_cogovernance": ["tech.knowledge_economy", "tech.digital_control"],
    "tech.algorithmic_management": ["tech.corporate_management", "tech.operations_research", "tech.networked_computing", "tech.machine_learning"],
    "tech.knowledge_cooperatives": ["tech.open_science_networks", "tech.cooperative_association", "tech.knowledge_economy"],
    "tech.autonomous_labor_coordination": ["tech.algorithmic_management", "tech.sensor_networks", "tech.autonomous_systems"],
}


def tech_atom(technology_id: str) -> dict:
    return {"kind": 0, "id": technology_id, "value": 1}


RESEARCH_CONDITIONS = {
    "tech.scientific_classification": ({"operator": 3, "required_count": 2, "children": [tech_atom(x) for x in (
        "tech.experimental_science", "tech.interregional_botany", "tech.learned_societies")]},
        "实验科学、跨区域植物学与学术社团三项知识来源中至少具备两项"),
    "tech.crop_breeding": ({"operator": 3, "required_count": 2, "children": [tech_atom(x) for x in (
        "tech.soil_experimentation", "tech.interregional_botany", "tech.agricultural_improvement")]},
        "土壤实验、跨区域植物学与农业改良实践中至少具备两项"),
    "tech.oceanic_navigation": ({"operator": 2, "children": [tech_atom("tech.magnetic_navigation"), tech_atom("tech.celestial_navigation")]},
        "磁针导航或天文导航任一路径均可提供远洋定位方法"),
    "tech.synthetic_fertilizer": ({"operator": 2, "children": [tech_atom("tech.industrial_chemistry"), tech_atom("tech.electrochemistry")]},
        "工业化学或电化学任一路线均可完成合成肥料反应体系"),
    "tech.modern_husbandry": ({"operator": 2, "children": [tech_atom("tech.livestock_breeding"), tech_atom("tech.public_health")]},
        "畜种育种或公共卫生任一路线均可建立现代畜群管理依据"),
    "tech.advanced_metallurgy": ({"operator": 3, "required_count": 2, "children": [tech_atom(x) for x in (
        "tech.coke_smelting", "tech.electromagnetic_induction", "tech.industrial_quality_control")]},
        "焦炭冶炼、电磁感应与工业质量控制中至少具备两项"),
    "tech.global_logistics": ({"operator": 3, "required_count": 2, "children": [tech_atom(x) for x in (
        "tech.rail_logistics", "tech.telecommunications", "tech.oceanic_navigation")]},
        "铁路物流、电信与远洋航海体系中至少具备两项"),
    "tech.geographic_information_systems": ({"operator": 2, "children": [tech_atom(x) for x in (
        "tech.satellite_observation", "tech.hydrological_remote_sensing", "tech.mineral_spectral_survey")]},
        "卫星观测、水文遥感或矿物光谱调查任一应用入口均可推动 GIS"),
}


def signal_atom(signal_id: str) -> dict:
    return {"kind": 1, "id": signal_id, "value": 1}


# Three explicit research-route gates per specialist family.  The first two are
# knowledge alternatives; the third admits either a knowledge route or direct
# practical evidence.  These are authored IDs, not family-order inference.
FAMILY_ROUTE_SPECS = {
    "branch.commerce_finance": [
        ("tech.currency", ["tech.early_trade", "tech.record_keeping"], ""),
        ("tech.mercantile_networks", ["tech.chartered_universities", "tech.commercial_estates"], ""),
        ("tech.digital_marketplaces", ["tech.corporate_management", "tech.telecommunications"], "breakthrough.automation"),
    ],
    "branch.computation_control": [
        ("tech.information_theory", ["tech.radio", "tech.industrial_statistics"], ""),
        ("tech.neural_networks", ["tech.systems_engineering", "tech.bioinformatics"], ""),
        ("tech.distributed_intelligence", ["tech.neural_networks", "tech.autonomous_systems"], "breakthrough.automation"),
    ],
    "branch.construction_materials": [
        ("tech.kiln_firing", ["tech.controlled_burning", "tech.hand_pottery"], ""),
        ("tech.masonry", ["tech.earth_building", "tech.early_glassmaking"], ""),
        ("tech.interchangeable_parts", ["tech.precision_engineering", "tech.mechanical_workshops"], "breakthrough.metalworking"),
    ],
    "branch.electric_intelligent_energy": [
        ("tech.electric_generation", ["tech.water_power", "tech.atmospheric_engine"], ""),
        ("tech.nuclear_energy", ["tech.corporate_management", "tech.state_enterprises"], ""),
        ("tech.smart_grid", ["tech.systems_engineering", "tech.distributed_intelligence"], "breakthrough.energy_control"),
    ],
    "branch.forest_biomass": [
        ("tech.charcoal_burning", ["tech.controlled_burning", "tech.fire_control"], ""),
        ("tech.forest_management", ["tech.guild_organization", "tech.regional_granaries"], ""),
        ("tech.steam_sawmilling", ["tech.industrial_coal_mining", "tech.precision_engineering"], "breakthrough.forest_management"),
    ],
    "branch.geoscience_gis": [
        ("tech.geological_prospecting", ["tech.mine_drainage", "tech.scientific_classification"], ""),
        ("tech.satellite_observation", ["tech.radio", "tech.cartography"], ""),
        ("tech.climate_modeling", ["tech.mineral_spectral_survey", "tech.hydrological_remote_sensing"], "breakthrough.climate_modeling"),
    ],
    "branch.heavy_industry": [
        ("tech.blast_furnace", ["tech.copper_metallurgy", "tech.guild_organization"], ""),
        ("tech.steam_power", ["tech.water_power", "tech.wind_power"], ""),
        ("tech.autonomous_mining", ["tech.robotic_manufacturing", "tech.machine_learning"], "breakthrough.mine_support"),
    ],
    "branch.industrial_chemistry": [
        ("tech.gunpowder_formulation", ["tech.salt_preservation", "tech.copper_ore_roasting"], ""),
        ("tech.electrochemistry", ["tech.standardization", "tech.fertilizer_processing"], ""),
        ("tech.industrial_ecology", ["tech.public_health", "tech.systems_engineering"], "breakthrough.chemical_process_control"),
    ],
    "branch.labor_management": [
        ("tech.industrial_organization", ["tech.wage_contracts", "tech.commercial_estates"], ""),
        ("tech.corporate_management", ["tech.mass_production", "tech.worker_cooperatives"], ""),
        ("tech.algorithmic_management", ["tech.human_machine_collaboration", "tech.algorithmic_governance"], "breakthrough.automation"),
    ],
    "branch.land_institutions": [
        ("tech.sharecropping", ["tech.customary_tenancy", "tech.household_landholding"], ""),
        ("tech.commercial_tenancy", ["tech.currency", "tech.estate_accounting"], ""),
        ("tech.property_cadastre", ["tech.standardization", "tech.state_bureaucracy"], "breakthrough.rainfed_adaptation"),
    ],
    "branch.maize_horticulture": [
        ("tech.maize_selection", ["tech.phenology_observation", "tech.seed_selection"], ""),
        ("tech.synthetic_fertilizer", ["tech.soil_experimentation", "tech.electrochemistry"], ""),
        ("tech.rainfed_maize_cultivation", ["tech.dryland_farming", "tech.flood_recession_maize"], "breakthrough.maize_selection"),
    ],
    "branch.maritime_logistics": [
        ("tech.oceanic_navigation", ["tech.magnetic_navigation", "tech.celestial_navigation"], ""),
        ("tech.global_logistics", ["tech.rail_logistics", "tech.telecommunications"], ""),
        ("tech.autonomous_logistics", ["tech.platform_coordination", "tech.distributed_intelligence"], "breakthrough.maritime_operations"),
    ],
    "branch.measurement_instruments": [
        ("tech.probability_statistics", ["tech.celestial_calendars", "tech.double_entry_bookkeeping"], ""),
        ("tech.precision_instruments", ["tech.weights_and_measures", "tech.mechanical_timekeeping"], ""),
        ("tech.industrial_quality_control", ["tech.corporate_management", "tech.precision_instruments"], "breakthrough.print_calibration"),
    ],
    "branch.natural_history": [
        ("tech.scientific_classification", ["tech.experimental_science", "tech.interregional_botany", "tech.learned_societies"], ""),
        ("tech.crop_breeding", ["tech.soil_experimentation", "tech.interregional_botany", "tech.agricultural_improvement"], ""),
        ("tech.bioinformatics", ["tech.software_engineering", "tech.open_science_networks"], "bio.wheat"),
    ],
    "branch.nonferrous_metals": [
        ("tech.bronze_casting", ["tech.kiln_firing", "tech.record_keeping"], ""),
        ("tech.coke_smelting", ["tech.industrial_chemistry", "tech.mine_ventilation"], ""),
        ("tech.specialty_alloys", ["tech.electrochemistry", "tech.nuclear_fuel_cycle"], "breakthrough.metalworking"),
    ],
    "branch.pastoral_livestock": [
        ("tech.pastoralism", ["tech.animal_traction", "tech.hide_tanning"], ""),
        ("tech.modern_husbandry", ["tech.livestock_breeding", "tech.public_health"], ""),
        ("tech.corporate_agribusiness", ["tech.modern_husbandry", "tech.cold_chain"], "bio.cattle"),
    ],
    "branch.petroleum_materials": [
        ("tech.petroleum_refining", ["tech.industrial_chemistry", "tech.steam_power"], ""),
        ("tech.petrochemical_industry", ["tech.fertilizer_processing", "tech.thermodynamics"], ""),
        ("tech.plastics_engineering", ["tech.synthetic_materials", "tech.industrial_quality_control"], "breakthrough.chemical_process_control"),
    ],
    "branch.public_health": [
        ("tech.public_health", ["tech.scientific_classification", "tech.state_bureaucracy"], ""),
        ("tech.modern_medicine", ["tech.refrigeration", "tech.scientific_classification"], ""),
        ("tech.public_health_systems", ["tech.state_enterprises", "tech.cold_chain"], "breakthrough.chemical_process_control"),
    ],
    "branch.rice_irrigation": [
        ("tech.rice_water_control", ["tech.irrigation", "tech.paddy_bunding"], ""),
        ("tech.estate_paddy_management", ["tech.manorial_jurisdiction", "tech.irrigation_surveying"], ""),
        ("tech.adaptive_irrigation", ["tech.sensor_networks", "tech.crop_remote_sensing"], "breakthrough.paddy_control"),
    ],
    "branch.textile_fibers": [
        ("tech.weaving", ["tech.fur_sewing", "tech.felt_making"], ""),
        ("tech.textile_machinery", ["tech.steam_power", "tech.standardization"], ""),
        ("tech.synthetic_fiber_engineering", ["tech.plastics_engineering", "tech.rubber_working"], "breakthrough.chemical_process_control"),
    ],
    "branch.tropical_commodities": [
        ("tech.spice_cultivation", ["tech.irrigation", "tech.record_keeping"], ""),
        ("tech.rubber_working", ["tech.kiln_firing", "tech.copper_annealing"], ""),
        ("tech.estate_plantation_management", ["tech.chartered_companies", "tech.crop_acclimatization"], "bio.spice"),
    ],
    "branch.tuber_highland": [
        ("tech.terrace_farming", ["tech.irrigation", "tech.earth_building"], ""),
        ("tech.highland_tuber_farming", ["tech.terrace_farming", "tech.frost_protected_storage"], ""),
        ("tech.estate_cereal_management", ["tech.estate_accounting", "tech.manorial_cereal_farming"], "breakthrough.terrace_maintenance"),
    ],
    "branch.water_wind": [
        ("tech.irrigation", ["tech.earth_building", "tech.seed_selection"], ""),
        ("tech.water_power", ["tech.irrigation_surveying", "tech.timber_sawing"], ""),
        ("tech.hydraulic_engineering", ["tech.urban_waterworks", "tech.property_cadastre"], "breakthrough.watershed_management"),
    ],
    "branch.wheat_rainfed": [
        ("tech.grain_threshing", ["tech.animal_traction", "tech.hand_pottery"], ""),
        ("tech.mechanical_reaping", ["tech.crop_rotation", "tech.tenant_cereal_farming"], ""),
        ("tech.collective_agriculture", ["tech.internal_combustion", "tech.electric_motors"], "breakthrough.rainfed_adaptation"),
    ],
}


BRANCH_SUCCESSORS = {
    "tech.learned_societies": (["tech.scientific_classification"], ["学术社团提供分类学所需的标本交流、同行讨论与知识编目网络"]),
    "tech.steam_power": (["tech.steam_pumping"], ["稳定蒸汽动力使矿井抽水从试验机械转为可持续生产系统"]),
    "tech.textile_machinery": (["tech.synthetic_fiber_engineering"], ["纺织机械给合成纤维提供可规模化纺丝、牵伸与织造的设备基础"]),
    "tech.managerial_hierarchy": (["tech.corporate_management"], ["管理层级发展为跨厂区的公司预算、统计与责任中心体系"]),
    "tech.industrial_chemistry": (["tech.electrochemistry"], ["工业化学的反应控制与纯度标准可扩展到电解反应体系"]),
    "tech.software_engineering": (["tech.networked_computing"], ["可靠的软件模块、接口和测试方法是网络化计算服务的同主题后继"]),
    "tech.corporate_management": (["tech.algorithmic_management"], ["公司管理形成的指标、责任与资源配置体系可进一步算法化"]),
}


APPLICATIONS = {
    "tech.learned_societies": {
        "tech.experimental_science": "学术社团为可重复实验提供交流、评议与结果传播机构",
        "tech.industrial_research": "工业研究机构沿用学术社团形成的同行评议和知识传播规范",
    },
    "tech.steam_power": {
        "tech.rail_logistics": "铁路牵引把稳定蒸汽动力应用于陆上大宗运输",
        "tech.mechanized_printing": "机械印刷把蒸汽动力应用于连续压印与纸张输送",
    },
    "tech.hydraulic_engineering": {
        "tech.electric_generation": "水利工程为水轮发电提供流量控制、坝体与引水设施",
        "tech.precision_irrigation": "精准灌溉把水利工程的输配水体系接入数字控制",
    },
    "tech.industrial_chemistry": {
        "tech.petrochemical_industry": "石油化工直接采用工业化学的反应器、分离和纯度控制",
        "tech.modern_medicine": "现代药品与消毒品生产采用工业化学的标准反应与质量控制",
        "tech.synthetic_fertilizer": "合成肥料可沿工业化学反应工程路线实现",
    },
    "tech.electrochemistry": {
        "tech.synthetic_fertilizer": "电化学提供另一条合成肥料反应与原料转化路线",
        "tech.petrochemical_industry": "电解与电化学分离用于石化原料和添加剂生产",
    },
    "tech.corporate_management": {
        "tech.operations_research": "公司预算和部门统计为运筹模型提供可度量的决策对象",
    },
    "tech.software_engineering": {
        "tech.digital_control": "数字控制需要经过测试的软件模块承载控制逻辑",
        "tech.platform_coordination": "平台协调依赖可维护的软件服务、接口与数据契约",
    },
    "tech.geographic_information_systems": {
        "tech.precision_agriculture": "GIS 把地块、作物与传感数据转化为差异化农艺决策",
        "tech.precision_irrigation": "GIS 为分区供水和管网调度提供空间数据模型",
        "tech.autonomous_mining": "GIS 为矿区设备路径、矿体边界和作业区约束提供空间底图",
    },
    "tech.satellite_observation": {
        "tech.climate_modeling": "卫星观测为气候模型提供连续的大尺度边界与校验数据",
    },
    "tech.global_logistics": {
        "tech.digital_marketplaces": "全球物流网络为数字市场的跨区域履约提供实体运输能力",
    },
}


EDGE_RATIONALE_OVERRIDES = {
    ("tech.digital_computing", "tech.software_engineering"): "数字计算提供可编程处理器、存储与执行模型，软件工程必须以此作为实现对象",
    ("tech.information_theory", "tech.software_engineering"): "信息论提供编码、复杂度与可靠传输的形式化基础，使软件接口和数据处理可以被系统设计",
    ("tech.managerial_hierarchy", "tech.corporate_management"): "管理层级建立跨部门授权与责任链，是公司级治理不可替代的组织基础",
    ("tech.double_entry_bookkeeping", "tech.corporate_management"): "复式记账提供资产、负债、成本和利润的统一核算，使公司能够跨业务配置资本",
    ("tech.industrial_statistics", "tech.corporate_management"): "工业统计提供跨工厂绩效比较和计划控制所需的量化资料",
    ("tech.industrial_chemistry", "tech.synthetic_fiber_engineering"): "工业化学提供聚合、溶剂、温度和纯度控制，是合成纤维成形的反应基础",
    ("tech.petrochemical_industry", "tech.synthetic_fiber_engineering"): "石油化工稳定供应合成纤维所需单体与中间体",
    ("tech.textile_machinery", "tech.synthetic_fiber_engineering"): "纺织机械提供纺丝后的牵伸、卷绕和织造设备，使材料能够进入规模化纺织生产",
    ("tech.timber_sawing", "tech.steam_sawmilling"): "手工锯木确立锯切、定尺和木料分级工艺，蒸汽锯木是在该工艺上的动力升级",
    ("tech.steam_power", "tech.steam_sawmilling"): "蒸汽动力提供连续旋转机械功，直接驱动锯框、进料与传动机构",
    ("tech.machine_tools", "tech.steam_sawmilling"): "机床提供耐用、可互换的轴承、锯架与传动零件，使高速锯切设备可制造和维护",
    ("tech.mine_drainage", "tech.steam_pumping"): "矿井排水定义扬程、井下积水和连续排放需求，是蒸汽抽水的直接应用问题",
    ("tech.steam_power", "tech.steam_pumping"): "蒸汽动力提供不依赖河流的连续泵送功率",
    ("tech.machine_tools", "tech.steam_pumping"): "机床保证泵缸、活塞、阀门与连杆的精度和可维修性",
    ("tech.canal_engineering", "tech.hydraulic_engineering"): "运河工程提供大尺度渠道、闸门和水位调度经验",
    ("tech.irrigation_surveying", "tech.hydraulic_engineering"): "灌溉测量提供坡降、流量和高程测定方法",
    ("tech.standardization", "tech.hydraulic_engineering"): "标准化统一管径、构件和测量基准，使跨区域水利设施能够协同建设",
    ("tech.scholastic_method", "tech.learned_societies"): "经院研究法提供论证、注释和公开争辩的学术规范",
    ("tech.chartered_universities", "tech.learned_societies"): "特许大学提供稳定的学者共同体、章程和人才来源",
    ("tech.screw_press_printing", "tech.learned_societies"): "螺旋压印使论文、目录与通信材料能够低成本复制和跨地传播",
    ("tech.atmospheric_engine", "tech.steam_power"): "大气式蒸汽机证明蒸汽驱动活塞做功的可行结构，是通用蒸汽动力的工程原型",
    ("tech.steam_sealing", "tech.steam_power"): "蒸汽密封降低汽缸、阀门和管路泄漏，使压力和效率可稳定维持",
    ("tech.machine_tools", "tech.steam_power"): "机床提供精密汽缸、活塞、阀门和传动件的批量制造能力",
}


FAMILY_CAPABILITY = {
    "backbone.food_storage": "粮食处理、保存与农艺组织能力",
    "backbone.tools_machinery": "工具制造、机械加工与设备控制能力",
    "backbone.knowledge_computation": "记录、验证、计算与知识传播方法",
    "backbone.institutions_exchange": "制度协调、公共组织与交换规则",
    "branch.maize_horticulture": "玉米栽培、选育与田间管理经验",
    "branch.wheat_rainfed": "谷物旱作、轮作与收获工艺",
    "branch.rice_irrigation": "水田整备、水位控制与稻作管理方法",
    "branch.tuber_highland": "块茎繁育、坡地耕作与低温保存经验",
    "branch.pastoral_livestock": "畜群驯养、育种与畜产品处理能力",
    "branch.tropical_commodities": "热带作物栽培、采收与商品化处理能力",
    "branch.forest_biomass": "林木管理、木材加工与生物质利用工艺",
    "branch.maritime_logistics": "船舶、导航、港口与运输组织能力",
    "branch.textile_fibers": "纤维处理、纺纱、织造与服装生产工艺",
    "branch.construction_materials": "土石、陶瓷、玻璃和工程构件制造能力",
    "branch.nonferrous_metals": "矿物识别、有色冶炼与合金配制能力",
    "branch.heavy_industry": "矿井、钢铁、蒸汽机械与重型设备能力",
    "branch.industrial_chemistry": "反应控制、配方、分离与化工质量标准",
    "branch.petroleum_materials": "油气开采、炼制与高分子原料能力",
    "branch.water_wind": "水流、风力、输配水和流域工程能力",
    "branch.electric_intelligent_energy": "发电、电机、电网与能源控制能力",
    "branch.land_institutions": "地权、租佃、登记与乡村治理制度",
    "branch.commerce_finance": "市场、会计、金融与商业网络组织能力",
    "branch.labor_management": "岗位分工、工厂组织与管理决策能力",
    "branch.measurement_instruments": "测量基准、统计方法与精密仪器能力",
    "branch.natural_history": "观察、分类、实验与生物育种知识",
    "branch.public_health": "卫生、疾病控制与医疗组织能力",
    "branch.geoscience_gis": "制图、地质、遥感与空间分析能力",
    "branch.computation_control": "数字计算、软件、网络与自动控制能力",
}


def rationale(source: dict, target: dict) -> str:
    explicit = EDGE_RATIONALE_OVERRIDES.get((source["id"], target["id"]))
    if explicit:
        return explicit
    capability = FAMILY_CAPABILITY[source["branch_family_id"]]
    role = {
        "identification": "识别与证据标准",
        "handling": "操作与材料处理方法",
        "method": "可复用的方法体系",
        "institution": "稳定的组织与制度载体",
        "production_system": "成套生产流程",
        "power_scale": "动力与规模化能力",
        "milestone": "跨领域整合能力",
    }.get(source.get("node_role", ""), "专门知识")
    return f"{source['display_name']}提供{capability}中的{role}，{target['display_name']}直接使用这一能力完成其工艺或组织设计"


def condition_technology_ids(spec: dict) -> set[str]:
    if not spec:
        return set()
    if "kind" in spec:
        return {str(spec.get("id", ""))} if int(spec.get("kind", -1)) == 0 else set()
    found: set[str] = set()
    for child in spec.get("children", []):
        if isinstance(child, dict):
            found.update(condition_technology_ids(child))
    return found


def stable_topological_order(nodes: list[dict], era_order: dict[str, int]) -> list[dict]:
    by_id = {node["id"]: node for node in nodes}
    original = {node["id"]: index for index, node in enumerate(nodes)}
    outgoing: dict[str, list[str]] = defaultdict(list)
    indegree = {node["id"]: 0 for node in nodes}
    for node in nodes:
        for prerequisite in node.get("hard_prerequisite_ids", []):
            outgoing[prerequisite].append(node["id"])
            indegree[node["id"]] += 1
    ready = [node["id"] for node in nodes if indegree[node["id"]] == 0]
    result: list[dict] = []
    while ready:
        ready.sort(key=lambda technology_id: (
            era_order[by_id[technology_id]["era_id"]],
            float(by_id[technology_id].get("layout_order", 0)),
            original[technology_id], technology_id))
        technology_id = ready.pop(0)
        result.append(by_id[technology_id])
        for target in outgoing[technology_id]:
            indegree[target] -= 1
            if indegree[target] == 0:
                ready.append(target)
    if len(result) != len(nodes):
        blocked = sorted(technology_id for technology_id, degree in indegree.items() if degree)
        raise ValueError(f"semantic review introduced a hard-prerequisite cycle: {blocked}")
    return result


def rebuild_visual_edges(payload: dict) -> None:
    edges: list[dict] = []
    seen: set[tuple[str, str, str]] = set()

    def add(source: str, target: str, kind: str) -> None:
        key = source, target, kind
        if source and target and source != target and key not in seen:
            seen.add(key)
            edges.append({"from": source, "to": target, "kind": kind})

    for node in payload["nodes"]:
        for prerequisite in node["hard_prerequisite_ids"]:
            add(prerequisite, node["id"], "hard")
        for alternative in condition_technology_ids(node["research_condition"]):
            add(alternative, node["id"], "alternative")
        for target in node["application_target_ids"]:
            add(node["id"], target, "application")
    for era in payload["eras"]:
        for candidate in era["milestone_candidate_ids"]:
            add(candidate, era["milestone_id"], "milestone_candidate")
    index = {node["id"]: cursor for cursor, node in enumerate(payload["nodes"])}
    edges.sort(key=lambda edge: (index[edge["from"]], index[edge["to"]], edge["kind"]))
    payload["visual_edges"] = edges


def main() -> int:
    payload = json.loads(NETWORK.read_text(encoding="utf-8"))
    if int(payload.get("schema_version", 0)) != 2:
        raise ValueError("semantic review requires schema v2 authoring")
    nodes = payload["nodes"]
    if len(nodes) != 361:
        raise ValueError(f"expected the 361 stable legacy IDs, found {len(nodes)}")
    by_id = {node["id"]: node for node in nodes}
    support_buildings = collect_support_buildings()
    direct_buildings = collect_direct_buildings()
    authored_conditions = dict(RESEARCH_CONDITIONS)
    for family_id, route_specs in FAMILY_ROUTE_SPECS.items():
        for target_id, technology_choices, signal_id in route_specs:
            children = [tech_atom(choice) for choice in technology_choices]
            if signal_id:
                children.append(signal_atom(signal_id))
            if target_id not in authored_conditions or signal_id:
                authored_conditions[target_id] = ({"operator": 2, "children": children}, "")
    referenced = set(FAMILY_OVERRIDES) | set(HARD_OVERRIDES) | set(authored_conditions)
    for route_specs in FAMILY_ROUTE_SPECS.values():
        for target_id, technology_choices, _signal_id in route_specs:
            referenced.add(target_id)
            referenced.update(technology_choices)
    referenced.update(BRANCH_SUCCESSORS)
    referenced.update(APPLICATIONS)
    for targets in HARD_OVERRIDES.values():
        referenced.update(targets)
    for technology_id, (targets, _) in BRANCH_SUCCESSORS.items():
        referenced.add(technology_id)
        referenced.update(targets)
    for technology_id, targets in APPLICATIONS.items():
        referenced.add(technology_id)
        referenced.update(targets)
    missing = sorted(referenced - set(by_id))
    if missing:
        raise ValueError(f"semantic review references missing technology IDs: {missing}")

    for technology_id, family_id in FAMILY_OVERRIDES.items():
        node = by_id[technology_id]
        node["branch_family_id"] = family_id
        node["network_role"] = "backbone" if family_id.startswith("backbone.") else "branch"

    for technology_id, prerequisites in HARD_OVERRIDES.items():
        by_id[technology_id]["hard_prerequisite_ids"] = list(prerequisites)

    for node in nodes:
        condition, summary = authored_conditions.get(node["id"], ({}, ""))
        if condition and not summary:
            tech_names = [by_id[technology_id]["display_name"]
                for technology_id in sorted(condition_technology_ids(condition))]
            has_signal = any(isinstance(child, dict) and int(child.get("kind", -1)) == 1
                for child in condition.get("children", []))
            summary = "、".join(tech_names) + (
                "任一路线或对应生产实践证据均可提供研究入口"
                if has_signal else "中的任一路线均可提供替代知识基础")
        node["research_condition"] = condition
        node["research_condition_summary"] = summary
        branch_targets, branch_reasons = BRANCH_SUCCESSORS.get(node["id"], ([], []))
        node["branch_successor_ids"] = list(branch_targets)
        node["branch_successor_rationales"] = list(branch_reasons)
        applications = APPLICATIONS.get(node["id"], {})
        node["application_target_ids"] = list(applications)
        node["application_target_rationales"] = list(applications.values())

    # Effects corrected during this review: these technologies are knowledge or
    # direct-unlock nodes, not broad production multipliers.
    for technology_id in (
        "tech.software_engineering", "tech.information_theory",
        "tech.synthetic_fiber_engineering", "tech.steam_sawmilling",
        "tech.steam_power", "tech.industrial_organization",
    ):
        by_id[technology_id]["modifier_terms"] = []

    # The old field_crop_farming target is an upgrade family containing broad
    # mixed-output farms, not a crop or cereal category. Remove every inherited
    # use, then author product-specific effects. Identification and general
    # knowledge nodes intentionally retain no automatic production bonus.
    for node in nodes:
        node["modifier_terms"] = [term for term in node.get("modifier_terms", [])
            if term.get("stat") != "country.output.family.field_crop_farming_factor"]

    crop_good_effects = {
        "tech.maize_seed_saving": (["corn_grain"], 0.18),
        "tech.maize_propagation": (["corn_grain"], 0.18),
        "tech.maize_selection": (["corn_grain"], 0.18),
        "tech.wheat_seed_saving": (["wheat_grain"], 0.18),
        "tech.wheat_propagation": (["wheat_grain"], 0.18),
        "tech.rice_seed_saving": (["rice_grain"], 0.18),
        "tech.paddy_bunding": (["rice_grain"], 0.18),
        "tech.plough_agriculture": (["grain", "wheat_grain", "corn_grain"], 0.25),
        "tech.dryland_farming": (["grain", "wheat_grain", "corn_grain"], 0.18),
        "tech.rainfed_field_system": (["grain", "wheat_grain", "corn_grain"], 0.18),
        "tech.frost_protected_storage": (["potatoes"], 0.18),
    }
    for technology_id, (good_ids, value) in crop_good_effects.items():
        by_id[technology_id]["modifier_terms"].extend(
            good_output_terms(good_ids, value))

    cereal_goods = ["grain", "wheat_grain", "rice_grain", "corn_grain"]
    by_id["tech.grain_threshing"]["modifier_terms"].extend(
        good_output_terms(cereal_goods, 0.18, "全部谷物"))

    # Final explicit effect pass supersedes every legacy/generated term above.
    # A reviewed node may intentionally remain modifier-free when its consumer
    # is an unlock, method, prerequisite, institution or alternative route.
    for node in nodes:
        node["modifier_terms"] = []
        node["effect_design_review"] = {
            "status": "reviewed",
            "numeric_effect_policy": "explicit_only",
            "non_numeric_consumers_allowed": True,
        }
    for technology_id, stat, value, effect_rationale in EFFECT_SPECS:
        if technology_id not in by_id:
            raise ValueError(f"effect review references missing technology: {technology_id}")
        by_id[technology_id]["modifier_terms"].append(
            authored_modifier_term(stat, value, effect_rationale))

    # Complete every paid non-milestone node that still has no numeric effect.
    # The groups above are an authored table: membership and target Stat are
    # reviewed explicitly, while the terminal multiplier only reflects whether
    # this node has any authored downstream edge in the current topology.
    hard_successors_for_effects: dict[str, list[str]] = defaultdict(list)
    for node in nodes:
        for prerequisite in node.get("hard_prerequisite_ids", []):
            hard_successors_for_effects[prerequisite].append(node["id"])
    for group_ids, stat, ordinary_value, terminal_value, group_rationale in EFFECT_COMPLETION_GROUPS:
        for technology_id in group_ids:
            if technology_id not in by_id:
                raise ValueError(f"effect completion references missing technology: {technology_id}")
            node = by_id[technology_id]
            if node.get("modifier_terms"):
                continue
            if node.get("is_milestone") or node.get("is_starting") or node.get("is_starter_eligible"):
                continue
            is_terminal = not (
                hard_successors_for_effects[technology_id]
                or node.get("branch_successor_ids")
                or node.get("application_target_ids"))
            value = terminal_value if is_terminal else ordinary_value
            node["modifier_terms"] = [authored_modifier_term(stat, value, group_rationale)]

    for node in nodes:
        terms = node.get("modifier_terms", [])
        if node.get("is_milestone") or node.get("is_starting") or node.get("is_starter_eligible"):
            continue
        if not terms:
            raise ValueError(f"formal technology has no reviewed Modifier effect: {node['id']}")
        if len(terms) > 6:
            raise ValueError(f"technology exceeds six Modifier terms: {node['id']}")
    for term in by_id["tech.grain_threshing"]["modifier_terms"]:
        term["subject_display_name"] = "全部谷物"

    rebuild_building_bindings(nodes, direct_buildings)

    era_order = {era["id"]: int(era["sort_order"]) for era in payload["eras"]}
    for node in nodes:
        alternatives = condition_technology_ids(node["research_condition"])
        overlap = alternatives.intersection(node["hard_prerequisite_ids"])
        if overlap:
            raise ValueError(f"{node['id']} repeats hard prerequisites as alternatives: {sorted(overlap)}")
        future_alternatives = sorted(technology_id for technology_id in alternatives
            if era_order[by_id[technology_id]["era_id"]] > era_order[node["era_id"]])
        if future_alternatives:
            raise ValueError(f"{node['id']} has future-era alternatives: {future_alternatives}")
        node["prerequisite_rationales"] = [rationale(by_id[source], node)
            for source in node["hard_prerequisite_ids"]]

    for family_id, route_specs in FAMILY_ROUTE_SPECS.items():
        targets = [target_id for target_id, _choices, _signal in route_specs]
        if len(set(targets)) != 3:
            raise ValueError(f"{family_id} must author three distinct route targets")
        if any(by_id[target_id]["branch_family_id"] != family_id for target_id in targets):
            raise ValueError(f"{family_id} route target assigned to another family")
        mixed_count = sum(1 for _target, _choices, signal_id in route_specs if signal_id)
        knowledge_count = sum(1 for _target, choices, _signal in route_specs
            if len(choices) >= 2)
        if mixed_count < 1 or knowledge_count < 2:
            raise ValueError(f"{family_id} lacks authored knowledge/evidence alternatives")

    for node in nodes:
        target_era = era_order[node["era_id"]]
        for prerequisite in node["hard_prerequisite_ids"]:
            if era_order[by_id[prerequisite]["era_id"]] > target_era:
                raise ValueError(f"future-era prerequisite: {prerequisite} -> {node['id']}")
        for target in node["branch_successor_ids"]:
            if by_id[target]["branch_family_id"] != node["branch_family_id"]:
                raise ValueError(f"cross-family branch successor must be application: {node['id']} -> {target}")

    for node in nodes:
        node["support_buildings"] = support_buildings.get(node["id"], [])
        node["effect_summary"] = effect_summary(node)

    payload["nodes"] = stable_topological_order(nodes, era_order)
    by_id = {node["id"]: node for node in payload["nodes"]}
    hard_successors: dict[str, list[str]] = defaultdict(list)
    for node in payload["nodes"]:
        for prerequisite in node["hard_prerequisite_ids"]:
            hard_successors[prerequisite].append(node["id"])
    family_names = {row["id"]: row["display_name"] for row in payload["branch_families"]}
    family_names.update({row["id"]: row["display_name"] for row in payload["backbones"]})
    for node in payload["nodes"]:
        if hard_successors[node["id"]] or node["branch_successor_ids"] or node["application_target_ids"]:
            node["terminal_reason"] = ""
        elif node.get("is_milestone"):
            node["terminal_reason"] = f"{node['display_name']}是该时代的全局入口里程碑，不作为节点级知识前置"
        else:
            consumers = [str(binding.get("id", "")) for binding in node.get("expected_bindings", [])]
            effect_text = "、".join(
                f"{term.get('subject_display_name', term.get('stat', ''))}{float(term.get('value', 0.0)) * 100:g}%"
                for term in node.get("modifier_terms", []))
            support_text = "、".join(str(item.get("name", item.get("id", "")))
                for item in node.get("support_buildings", []))
            consumer_text = "、".join(consumers or ([support_text] if support_text else [])
                or ([effect_text] if effect_text else [])) or "当前目录终点效果"
            node["terminal_reason"] = (
                f"{node['display_name']}是{family_names[node['branch_family_id']]}在当前目录中的应用端点，"
                f"其终点效果由{consumer_text}消费")

    payload["semantic_review"] = {
        "version": 1,
        "reviewed_node_count": len(payload["nodes"]),
        "relationship_policy": "explicit_authoring_only",
        "allowed_research_condition_ids": sorted(authored_conditions),
        "legacy_keyword_family_inference": False,
        "legacy_adjacent_successor_inference": False,
        "legacy_automatic_alternatives": False,
    }
    rebuild_visual_edges(payload)
    rendered = json.dumps(payload, ensure_ascii=False, indent="\t") + "\n"
    NETWORK.write_text(rendered, encoding="utf-8")
    digest = hashlib.sha256(rendered.encode("utf-8")).hexdigest()
    print(f"[PASS] explicit semantic review wrote {len(payload['nodes'])} nodes sha256={digest}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
