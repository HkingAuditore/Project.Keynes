# -*- coding: utf-8 -*-
"""v5 节点新增：先补 tools 主干（工具/机械/自动控制）的三处空洞。

背景：`backbone.tools_machinery` 只有 9 个节点，在 exploration 与 information
两代完全没有节点，而智能时代的主题就是自动化。本批插入：

  * tech.precision_measurement  精密测量   exploration  （填 exploration 空洞）
  * tech.servomechanism         伺服机构   electrical   （把"机器 + 控制"接回来）
  * tech.robotic_control        机器人控制 information  （让自动化拥有机器血统）

并把下游改接到它们：precision_engineering / electronic_control /
robotic_manufacturing / automated_agriculture。

只改 technology_network.json；幂等（节点已存在则跳过）。
"""
from __future__ import annotations

import argparse
import json
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
NETWORK = os.path.join(ROOT, "data", "technology", "technology_network.json")
ROOT_TECH_ID = "tech.early_knowledge_institution"

REVIEW_OK = {
    "status": "reviewed",
    "numeric_effect_policy": "explicit_only",
    "non_numeric_consumers_allowed": True,
}


def term(stat, value, subject_id, subject_name, effect_class, rationale):
    return {
        "stat": stat,
        "operation": 0.0,
        "value": value,
        "subject_kind": "country",
        "subject_id": subject_id,
        "subject_display_name": subject_name,
        "effect_class": effect_class,
        "effect_rationale": rationale,
        "implementation_status": "runtime_consumed",
        "runtime_consumer": "NativeEconomyRuntime::effective_building_output_quantity",
    }


NODES = [
    {
        "id": "tech.precision_measurement",
        "display_name": "精密测量",
        "era_id": "exploration",
        "domain_id": "engineering",
        "cost_points": 109000.0,
        "network_role": "backbone",
        "anchor_kind": "backbone",
        "node_role": "handling",
        "effect_profile": "tools",
        "secondary_route_tags": ["route.craft.precision"],
        "hard_prerequisite_ids": ["tech.mechanical_timekeeping",
                                  "tech.weights_and_measures"],
        "prerequisite_rationales": [
            "机械计时提供可复现的时间基准，是测量从定性走向定量的前提。",
            "度量衡给出单位与换算规则，没有统一单位就谈不上精密。",
        ],
        "reveal_condition": {
            "operator": 2.0,
            "children": [
                {"kind": 1.0, "id": "development.employment.manufacturing.50_180d", "value": 1.0},
                {"kind": 1.0, "id": "development.output.knowledge.1000_360d", "value": 1.0},
            ],
        },
        "reveal_category": "practice_diffusion",
        "reveal_summary": "精细制造作业扩大、或观测与知识生产成规模后，测量精度成为瓶颈，于是被揭示。",
        "modifier_terms": [
            term("country.output.family.metal_toolmaking_factor", 0.10,
                 "metal_toolmaking", "金属工具制造",
                 "工具产出",
                 "可复现的测量让零件第一次能按尺寸互换，工具与量具的成品率同步上升。"),
        ],
        "content_effects": [],
        "support_buildings": [],
        "opportunity_cost": "占用探索时代的通用研究预算，延后同代的航海与种植园锚点",
        "application_target_ids": [],
        "terminal_reason": "",
        "branch_family_id": "backbone.tools_machinery",
        "era_entry_milestone_id": "tech.imperial_integration",
        "branch_successor_ids": ["tech.precision_engineering"],
        "branch_successor_rationales": [
            "精密工程直接使用精密测量建立的尺寸与公差体系，是它在同一条主干的下一步。",
        ],
        "knowledge_basis": {
            "required_ids": ["tech.mechanical_timekeeping", "tech.weights_and_measures"],
            "alternative_groups": [["tech.scholastic_method"], ["tech.iron_smelting"]],
            "exemption_reason": "",
        },
        "topology_review": {
            "role": "continuation",
            "rationale": "补上工具主干在探索时代的空洞：钟表与度量衡正是该代唯一真实的精密机械知识。",
            "expected_hard_family_ids": ["backbone.tools_machinery"],
        },
        "building_unlock_review": {
            "policy": "support_only",
            "rationale": "本科技不直接呈现新建筑；它作为精密制造类建筑的知识与量具体系。",
        },
        "research_routes": [
            {
                "id": "research_route.precision_measurement.knowledge_integration",
                "display_name": "精密测量·专业知识整合",
                "route_type": "professional_knowledge",
                "description": "掌握经院研究法，并以“知识产业就业达到 250 人并持续 360 日”验证精密测量的理论整合；核心硬前置仍须全部完成。",
                "condition": {"operator": 1.0, "children": [
                    {"kind": 0.0, "id": "tech.scholastic_method", "value": 1.0},
                    {"kind": 1.0, "id": "development.employment.knowledge.250_360d", "value": 1.0},
                ]},
            },
            {
                "id": "research_route.precision_measurement.operating_practice",
                "display_name": "精密测量·生产经营实践",
                "route_type": "industrial_practice",
                "description": "掌握块炼铁，并以“制造业就业达到 250 人并持续 360 日”验证精密测量的制造实践；核心硬前置仍须全部完成。",
                "condition": {"operator": 1.0, "children": [
                    {"kind": 0.0, "id": "tech.iron_smelting", "value": 1.0},
                    {"kind": 1.0, "id": "development.employment.manufacturing.250_360d", "value": 1.0},
                ]},
            },
            {
                "id": "research_route.precision_measurement.institutional_scale",
                "display_name": "精密测量·制度组织能力",
                "route_type": "institutional_capacity",
                "description": "掌握行业组织，并以“8 座生产设施活跃经营 360 日”验证精密测量的组织条件；核心硬前置仍须全部完成。",
                "condition": {"operator": 1.0, "children": [
                    {"kind": 0.0, "id": "tech.guild_organization", "value": 1.0},
                    {"kind": 1.0, "id": "development.buildings.active_8_360d", "value": 1.0},
                ]},
            },
        ],
    },
    {
        "id": "tech.servomechanism",
        "display_name": "伺服机构",
        "era_id": "electrical",
        "domain_id": "engineering",
        "cost_points": 1230000.0,
        "network_role": "backbone",
        "anchor_kind": "backbone",
        "node_role": "power_scale",
        "effect_profile": "automation",
        "secondary_route_tags": ["route.craft.precision"],
        "hard_prerequisite_ids": ["tech.electric_motors",
                                  "tech.industrial_quality_control"],
        "prerequisite_rationales": [
            "伺服需要可反向控制的电动机：没有电机就没有被控的执行机构。",
            "伺服靠反馈纠偏，而反馈只有在质量可测、可判定的前提下才有意义。",
        ],
        "reveal_condition": {"kind": 1.0, "id": "breakthrough.motor_winding", "value": 1.0},
        "reveal_category": "practice_diffusion",
        "reveal_summary": "电机绕组与反馈控制的现场实践积累到一定程度后，伺服机构被揭示。",
        "modifier_terms": [
            term("country.output.family.metal_toolmaking_factor", 0.12,
                 "metal_toolmaking", "金属工具制造",
                 "工具产出",
                 "伺服让机床按指令自动进给，同一台设备能加工更复杂的形状。"),
        ],
        "content_effects": [],
        "support_buildings": [],
        "opportunity_cost": "占用电气时代的通用研究预算，延后同代的电气化与化工锚点",
        "application_target_ids": [],
        "terminal_reason": "",
        "branch_family_id": "backbone.tools_machinery",
        "era_entry_milestone_id": "tech.industrialization",
        "branch_successor_ids": ["tech.robotic_control"],
        "branch_successor_rationales": [
            "机器人控制把伺服从单轴执行扩展到多轴协同，是同一主干的下一步。",
        ],
        "knowledge_basis": {
            "required_ids": ["tech.electric_motors", "tech.industrial_quality_control"],
            "alternative_groups": [["tech.electrification"], ["tech.industrial_research"]],
            "exemption_reason": "",
        },
        "topology_review": {
            "role": "continuation",
            "rationale": "把“自动化 = 机器 + 控制”补回主干：此前工具主干在电气与信息两代完全没有节点。",
            "expected_hard_family_ids": ["backbone.tools_machinery"],
        },
        "building_unlock_review": {
            "policy": "support_only",
            "rationale": "本科技不直接呈现新建筑；它作为自动化产线与精密机床的控制基础。",
        },
        "research_routes": [
            {
                "id": "research_route.servomechanism.knowledge_integration",
                "display_name": "伺服机构·专业知识整合",
                "route_type": "professional_knowledge",
                "description": "掌握工业研究，并以“知识产业就业达到 1250 人并持续 720 日”验证伺服的理论整合；核心硬前置仍须全部完成。",
                "condition": {"operator": 1.0, "children": [
                    {"kind": 0.0, "id": "tech.industrial_research", "value": 1.0},
                    {"kind": 1.0, "id": "development.employment.knowledge.1250_720d", "value": 1.0},
                ]},
            },
            {
                "id": "research_route.servomechanism.operating_practice",
                "display_name": "伺服机构·生产经营实践",
                "route_type": "industrial_practice",
                "description": "掌握电气化，并以“制造业产出达到 10000 并持续 720 日”验证伺服的产线实践；核心硬前置仍须全部完成。",
                "condition": {"operator": 1.0, "children": [
                    {"kind": 0.0, "id": "tech.electrification", "value": 1.0},
                    {"kind": 1.0, "id": "development.output.manufacturing.10000_720d", "value": 1.0},
                ]},
            },
        ],
    },
    {
        "id": "tech.robotic_control",
        "display_name": "机器人控制",
        "era_id": "information",
        "domain_id": "engineering",
        "cost_points": 6120000.0,
        "network_role": "backbone",
        "anchor_kind": "backbone",
        "node_role": "handling",
        "effect_profile": "automation",
        "secondary_route_tags": ["route.craft.precision"],
        "hard_prerequisite_ids": ["tech.servomechanism", "tech.digital_control"],
        "prerequisite_rationales": [
            "机器人是多轴伺服的协同，没有伺服机构就没有可编程的执行端。",
            "数字控制提供把动作写成程序的能力，是柔性与刚性的分界。",
        ],
        "reveal_condition": {"kind": 1.0, "id": "breakthrough.automation", "value": 1.0},
        "reveal_category": "practice_diffusion",
        "reveal_summary": "自动化实践在产线上稳定运行后，可编程的整机控制被揭示。",
        "modifier_terms": [
            term("country.output.family.metal_toolmaking_factor", 0.15,
                 "metal_toolmaking", "金属工具制造",
                 "工具产出",
                 "可编程工装让小批量、多品种的生产第一次具备经济性。"),
        ],
        "content_effects": [],
        "support_buildings": [],
        "opportunity_cost": "占用信息时代的通用研究预算，延后同代的计算与传感锚点",
        "application_target_ids": [],
        "terminal_reason": "",
        "branch_family_id": "backbone.tools_machinery",
        "era_entry_milestone_id": "tech.atomic_modernity",
        "branch_successor_ids": [],
        "branch_successor_rationales": [],
        "knowledge_basis": {
            "required_ids": ["tech.servomechanism", "tech.digital_control"],
            "alternative_groups": [["tech.software_engineering"], ["tech.industrial_quality_control"]],
            "exemption_reason": "",
        },
        "topology_review": {
            "role": "convergence",
            "rationale": "机械（伺服）与控制（数字控制）在本节点合流，智能时代的自动化由此拥有完整的机器血统。",
            "expected_hard_family_ids": ["backbone.tools_machinery"],
        },
        "building_unlock_review": {
            "policy": "support_only",
            "rationale": "本科技不直接呈现新建筑；它是自动化产线与自主装备的控制层。",
        },
        "research_routes": [
            {
                "id": "research_route.robotic_control.knowledge_integration",
                "display_name": "机器人控制·专业知识整合",
                "route_type": "professional_knowledge",
                "description": "掌握软件工程，并以“知识产业就业达到 1250 人并持续 720 日”验证机器人控制的知识整合；核心硬前置仍须全部完成。",
                "condition": {"operator": 1.0, "children": [
                    {"kind": 0.0, "id": "tech.software_engineering", "value": 1.0},
                    {"kind": 1.0, "id": "development.employment.knowledge.1250_720d", "value": 1.0},
                ]},
            },
            {
                "id": "research_route.robotic_control.operating_practice",
                "display_name": "机器人控制·生产经营实践",
                "route_type": "industrial_practice",
                "description": "掌握工业质检，并以“制造业输出达到 100000 并持续 1095 日”验证机器人控制的产线实践；核心硬前置仍须全部完成。",
                "condition": {"operator": 1.0, "children": [
                    {"kind": 0.0, "id": "tech.industrial_quality_control", "value": 1.0},
                    {"kind": 1.0, "id": "development.output.manufacturing.100000_1095d", "value": 1.0},
                ]},
            },
        ],
    },
]

# (下游节点, 新前置, 理由)
EDGES = [
    ("tech.precision_engineering", "tech.precision_measurement",
     "精密工程建立在精密测量建立的尺寸与公差体系之上。"),
    ("tech.electronic_control", "tech.servomechanism",
     "电子控制的对象是伺服执行机构；没有伺服，“控制”没有可驱动的末端。"),
    ("tech.robotic_manufacturing", "tech.robotic_control",
     "机器人制造是机器人控制在生产线上的直接部署。"),
    ("tech.automated_agriculture", "tech.robotic_control",
     "自动化农业依赖可编程的整机控制来完成播种、除草与采收。"),
    ("tech.masonry", "tech.stone_quarrying",
     "砌体需要先有采石与琢石：没有石作环节，砌筑只能停留在土坯。"),
]

# ---------------------------------------------------------------- 第二批：支线续命
NODES_B = [
    {
        "id": "tech.stone_quarrying",
        "display_name": "采石与琢石",
        "era_id": "agrarian",
        "domain_id": "engineering",
        "cost_points": 8400.0,
        "network_role": "branch",
        "anchor_kind": "branch",
        "node_role": "production_system",
        "effect_profile": "construction",
        "secondary_route_tags": ["route.material.stone"],
        "hard_prerequisite_ids": ["tech.ground_stone_tools"],
        "prerequisite_rationales": [
            "琢石是把磨制石器的打击与研磨经验放大到建材尺度，工具知识是它的直接前身。",
        ],
        "reveal_condition": {
            "operator": 2.0,
            "children": [
                {"kind": 1.0, "id": "landform.mountain", "value": 1.0},
                {"kind": 1.0, "id": "resource.stone", "value": 1.0},
            ],
        },
        "reveal_category": "environment_observation",
        "reveal_summary": "在山地或石料露头附近反复取石、试砌之后，采石与琢石成为独立工序。",
        "modifier_terms": [
            term("country.output.family.construction_methods_factor", 0.10,
                 "construction_methods", "营造方法",
                 "营造产出",
                 "有稳定的石料供应与琢石工序，砌筑才不再受限于随手可捡的毛石。"),
        ],
        "content_effects": [],
        "support_buildings": [],
        "opportunity_cost": "占用农耕时代的通用研究预算，延后同代的作物与灌溉锚点",
        "application_target_ids": [],
        "terminal_reason": "",
        "branch_family_id": "branch.construction_materials",
        "era_entry_milestone_id": "tech.settled_knowledge",
        "branch_successor_ids": ["tech.masonry"],
        "branch_successor_rationales": [
            "砌体直接把采石与琢石的产品变成墙体，是同一建材支线的下一步。",
        ],
        "knowledge_basis": {
            "required_ids": ["tech.ground_stone_tools"],
            "alternative_groups": [["tech.earth_building"], ["tech.permanent_settlements"]],
            "exemption_reason": "",
        },
        "topology_review": {
            "role": "branch",
            "rationale": "补齐建材支线的采石环节：此前砌体的祖先里没有任何石作节点。",
            "expected_hard_family_ids": ["branch.construction_materials"],
        },
        "building_unlock_review": {
            "policy": "support_only",
            "rationale": "本科技不直接呈现新建筑；它是砌筑、城垣与石作类建筑的材料前身。",
        },
        "research_routes": [
            {
                "id": "research_route.stone_quarrying.operating_practice",
                "display_name": "采石与琢石·生产经营实践",
                "route_type": "industrial_practice",
                "description": "掌握土建筑，并以“采掘业就业达到 10 人并持续 90 日”验证采石的组织实践；核心硬前置仍须全部完成。",
                "condition": {"operator": 1.0, "children": [
                    {"kind": 0.0, "id": "tech.earth_building", "value": 1.0},
                    {"kind": 1.0, "id": "development.employment.extractive.10_90d", "value": 1.0},
                ]},
            },
            {
                "id": "research_route.stone_quarrying.institutional_scale",
                "display_name": "采石与琢石·制度组织能力",
                "route_type": "institutional_capacity",
                "description": "掌握永久聚落，并以“聚集落等级 1 持续 90 日”验证采石的常备劳力；核心硬前置仍须全部完成。",
                "condition": {"operator": 1.0, "children": [
                    {"kind": 0.0, "id": "tech.permanent_settlements", "value": 1.0},
                    {"kind": 1.0, "id": "development.settlement.tier_1_90d", "value": 1.0},
                ]},
            },
        ],
    },
    {
        "id": "tech.land_surveying",
        "display_name": "土地测量",
        "era_id": "exploration",
        "domain_id": "engineering",
        "cost_points": 109000.0,
        "network_role": "branch",
        "anchor_kind": "branch",
        "node_role": "institution",
        "effect_profile": "organization",
        "secondary_route_tags": ["route.institution.records"],
        "hard_prerequisite_ids": ["tech.cartography", "tech.weights_and_measures"],
        "prerequisite_rationales": [
            "测量要先把地物画到图上，地图学提供投影与记号的约定。",
            "没有统一单位，面积与距离无法被记录、比较与征收。",
        ],
        "reveal_condition": {"kind": 1.0, "id": "development.settlement.tier_2_180d", "value": 1.0},
        "reveal_category": "practice_diffusion",
        "reveal_summary": "聚落扩张到需要划界、分田与征税规模后，土地测量成为独立技艺。",
        "modifier_terms": [
            term("country.output.family.cadastral_institution_factor", 0.15,
                 "cadastral_institution", "地籍机构",
                 "制度产出",
                 "可复核的地籍让土地登记、买卖与征税第一次有共同依据。"),
        ],
        "content_effects": [],
        "support_buildings": [],
        "opportunity_cost": "占用帝国时代的通用研究预算，延后同代的官僚与军政锚点",
        "application_target_ids": [],
        "terminal_reason": "土地测量的知识由此转入地籍与产权制度（tech.property_cadastre），本线以制度化为终点。",
        "branch_family_id": "branch.measurement_instruments",
        "era_entry_milestone_id": "tech.imperial_integration",
        "branch_successor_ids": [],
        "branch_successor_rationales": [],
        "knowledge_basis": {
            "required_ids": ["tech.cartography", "tech.weights_and_measures"],
            "alternative_groups": [["tech.road_engineering"]],
            "exemption_reason": "",
        },
        "topology_review": {
            "role": "branch",
            "rationale": "把地图学与度量衡接成一条实际的测量技艺，补上测量支线在帝国代的空档。",
            "expected_hard_family_ids": ["branch.measurement_instruments"],
        },
        "building_unlock_review": {
            "policy": "support_only",
            "rationale": "本科技不直接呈现新建筑；它支撑地籍、税务与公共工程类建筑。",
        },
        "research_routes": [
            {
                "id": "research_route.land_surveying.knowledge_integration",
                "display_name": "土地测量·专业知识整合",
                "route_type": "professional_knowledge",
                "description": "掌握道路工程，并以“知识产业产出达到 100 并持续 180 日”验证测量的专业整合；核心硬前置仍须全部完成。",
                "condition": {"operator": 1.0, "children": [
                    {"kind": 0.0, "id": "tech.road_engineering", "value": 1.0},
                    {"kind": 1.0, "id": "development.output.knowledge.100_180d", "value": 1.0},
                ]},
            },
            {
                "id": "research_route.land_surveying.institutional_scale",
                "display_name": "土地测量·制度组织能力",
                "route_type": "institutional_capacity",
                "description": "掌握官僚行政，并以“2 座等级 2 聚落持续 180 日”验证测量的行政需求；核心硬前置仍须全部完成。",
                "condition": {"operator": 1.0, "children": [
                    {"kind": 0.0, "id": "tech.state_bureaucracy", "value": 1.0},
                    {"kind": 1.0, "id": "development.settlements.tier_2_count_2_180d", "value": 1.0},
                ]},
            },
        ],
    },
    {
        "id": "tech.mountain_irrigation",
        "display_name": "山地灌溉",
        "era_id": "empire",
        "domain_id": "agriculture",
        "cost_points": 46000.0,
        "network_role": "branch",
        "anchor_kind": "branch",
        "node_role": "production_system",
        "effect_profile": "hydraulic",
        "secondary_route_tags": ["route.ecology.highland"],
        "hard_prerequisite_ids": ["tech.highland_tuber_farming", "tech.canal_engineering"],
        "prerequisite_rationales": [
            "高山块茎体系的畦作与梯田经验，是山地引水的前身。",
            "渠道工程提供坡面输水、分水与溢流的工程方法。",
        ],
        "reveal_condition": {
            "operator": 1.0,
            "children": [
                {"kind": 1.0, "id": "breakthrough.terrace_maintenance", "value": 1.0},
                {"kind": 1.0, "id": "landform.high_plateau", "value": 1.0},
            ],
        },
        "reveal_category": "practice_diffusion",
        "reveal_summary": "梯田维护与高原水源的实际经验积累后，山地灌溉被揭示。",
        "modifier_terms": [
            term("country.output.terrain.mountain.agriculture_factor", 0.15,
                 "mountain", "山地",
                 "地理专长",
                 "把坡面径流引入梯田后，山地农业第一次摆脱看天吃饭。"),
        ],
        "content_effects": [],
        "support_buildings": [],
        "opportunity_cost": "占用帝国时代的通用研究预算，延后同代的水利与粮储锚点",
        "application_target_ids": [],
        "terminal_reason": "山地灌溉是该线的工程终点；更高海拔的生产方式由精准农业另行承接。",
        "branch_family_id": "branch.tuber_highland",
        "era_entry_milestone_id": "tech.kingdom_administration",
        "branch_successor_ids": [],
        "branch_successor_rationales": [],
        "knowledge_basis": {
            "required_ids": ["tech.highland_tuber_farming", "tech.canal_engineering"],
            "alternative_groups": [["tech.irrigation"]],
            "exemption_reason": "",
        },
        "topology_review": {
            "role": "continuation",
            "rationale": "块茎高地支线原本死在第 3 代，本节点把它延续到帝国代并给出工程形态。",
            "expected_hard_family_ids": ["branch.tuber_highland"],
        },
        "building_unlock_review": {
            "policy": "support_only",
            "rationale": "本科技不直接呈现新建筑；它是高地农作类建筑的灌溉前提。",
        },
        "research_routes": [
            {
                "id": "research_route.mountain_irrigation.operating_practice",
                "display_name": "山地灌溉·生产经营实践",
                "route_type": "industrial_practice",
                "description": "掌握灌溉，并以“农业产出达到 1000 并持续 360 日”验证山地的经营实践；核心硬前置仍须全部完成。",
                "condition": {"operator": 1.0, "children": [
                    {"kind": 0.0, "id": "tech.irrigation", "value": 1.0},
                    {"kind": 1.0, "id": "development.output.agriculture.1000_360d", "value": 1.0},
                ]},
            },
            {
                "id": "research_route.mountain_irrigation.institutional_scale",
                "display_name": "山地灌溉·制度组织能力",
                "route_type": "institutional_capacity",
                "description": "掌握共同田协调，并以“等级 3 聚落持续 360 日”验证山地的组织能力；核心硬前置仍须全部完成。",
                "condition": {"operator": 1.0, "children": [
                    {"kind": 0.0, "id": "tech.communal_field_coordination", "value": 1.0},
                    {"kind": 1.0, "id": "development.settlement.tier_3_360d", "value": 1.0},
                ]},
            },
        ],
    },
    {
        "id": "tech.mill_network",
        "display_name": "磨坊网络",
        "era_id": "empire",
        "domain_id": "engineering",
        "cost_points": 46000.0,
        "network_role": "branch",
        "anchor_kind": "branch",
        "node_role": "power_scale",
        "effect_profile": "power",
        "secondary_route_tags": ["route.energy.water"],
        "hard_prerequisite_ids": ["tech.water_power", "tech.wind_power"],
        "prerequisite_rationales": [
            "水磨提供全年稳定的回转动力，是磨坊网络的骨干。",
            "风磨补上枯水季与缺河地区的动力空档，两者共同构成网络。",
        ],
        "reveal_condition": {
            "operator": 2.0,
            "children": [
                {"kind": 1.0, "id": "landform.freshwater_access", "value": 1.0},
                {"kind": 1.0, "id": "landform.stable_wind_corridor", "value": 1.0},
            ],
        },
        "reveal_category": "environment_observation",
        "reveal_summary": "在河网与风道附近逐一建起磨坊之后，把单点动力连成网络成为可做的事。",
        "modifier_terms": [
            term("country.output.landform.plain.manufacturing_factor", 0.10,
                 "plain", "平原",
                 "地理专长",
                 "平原上成网的磨坊把谷物加工从家庭副业变成可计量的产业。"),
        ],
        "content_effects": [],
        "support_buildings": [],
        "opportunity_cost": "占用帝国时代的通用研究预算，延后同代的水利与筑城锚点",
        "application_target_ids": [],
        "terminal_reason": "",
        "branch_family_id": "branch.water_wind",
        "era_entry_milestone_id": "tech.kingdom_administration",
        "branch_successor_ids": ["tech.polder_engineering"],
        "branch_successor_rationales": [
            "圩田工程把磨坊网络积累的水工经验扩展到海岸与沼泽，是同一支线的下一步。",
        ],
        "knowledge_basis": {
            "required_ids": ["tech.water_power", "tech.wind_power"],
            "alternative_groups": [["tech.timber_sawing"]],
            "exemption_reason": "",
        },
        "topology_review": {
            "role": "convergence",
            "rationale": "水磨与风磨在本节点合流成网络；此前水风支线在帝国代之后直接终止。",
            "expected_hard_family_ids": ["branch.water_wind"],
        },
        "building_unlock_review": {
            "policy": "support_only",
            "rationale": "本科技不直接呈现新建筑；它是磨坊与水力加工类建筑的组网前提。",
        },
        "research_routes": [
            {
                "id": "research_route.mill_network.operating_practice",
                "display_name": "磨坊网络·生产经营实践",
                "route_type": "industrial_practice",
                "description": "掌握木材锯切，并以“制造业产出达到 100 并持续 180 日”验证磨坊的建设与运营；核心硬前置仍须全部完成。",
                "condition": {"operator": 1.0, "children": [
                    {"kind": 0.0, "id": "tech.timber_sawing", "value": 1.0},
                    {"kind": 1.0, "id": "development.output.manufacturing.100_180d", "value": 1.0},
                ]},
            },
            {
                "id": "research_route.mill_network.institutional_scale",
                "display_name": "磨坊网络·制度组织能力",
                "route_type": "institutional_capacity",
                "description": "掌握道路工程，并以“农业产出达到 1000 并持续 360 日”验证磨坊服务的腹地规模；核心硬前置仍须全部完成。",
                "condition": {"operator": 1.0, "children": [
                    {"kind": 0.0, "id": "tech.road_engineering", "value": 1.0},
                    {"kind": 1.0, "id": "development.output.agriculture.1000_360d", "value": 1.0},
                ]},
            },
        ],
    },
    {
        "id": "tech.polder_engineering",
        "display_name": "圩田与海岸工程",
        "era_id": "enlightenment",
        "domain_id": "engineering",
        "cost_points": 256000.0,
        "network_role": "branch",
        "anchor_kind": "branch",
        "node_role": "production_system",
        "effect_profile": "hydraulic",
        "secondary_route_tags": ["route.geography.coast"],
        "hard_prerequisite_ids": ["tech.mill_network", "tech.canal_engineering"],
        "prerequisite_rationales": [
            "圩田需要成网的排水动力，磨坊网络提供抽排与闸门的驱动经验。",
            "运河工程提供土方、堤线与水位的控制方法。",
        ],
        "reveal_condition": {
            "operator": 1.0,
            "children": [
                {"kind": 1.0, "id": "landform.coast", "value": 1.0},
                {"kind": 1.0, "id": "weather.major_flood", "value": 1.0},
            ],
        },
        "reveal_category": "environment_observation",
        "reveal_summary": "在海岸或沼泽反复遭遇潮水与洪水之后，筑堤排水成为可规划的事。",
        "modifier_terms": [
            term("country.output.terrain.swamp.agriculture_factor", 0.15,
                 "swamp", "沼泽",
                 "地理专长",
                 "筑堤排水之后，此前无法耕作的沼泽与滩涂变成可耕地。"),
        ],
        "content_effects": [],
        "support_buildings": [],
        "opportunity_cost": "占用启蒙时代的通用研究预算，延后同代的水利与农业改良锚点",
        "application_target_ids": [],
        "terminal_reason": "圩田工程以沿海与沼泽的土地改造为终点；更高强度的治水由现代水利工程承接。",
        "branch_family_id": "branch.water_wind",
        "era_entry_milestone_id": "tech.global_exchange",
        "branch_successor_ids": [],
        "branch_successor_rationales": [],
        "knowledge_basis": {
            "required_ids": ["tech.mill_network", "tech.canal_engineering"],
            "alternative_groups": [["tech.hydraulic_engineering"]],
            "exemption_reason": "",
        },
        "topology_review": {
            "role": "continuation",
            "rationale": "水风支线在帝国代之后本已终止，本节点把它延续到启蒙代并转向土地改造。",
            "expected_hard_family_ids": ["branch.water_wind"],
        },
        "building_unlock_review": {
            "policy": "support_only",
            "rationale": "本科技不直接呈现新建筑；它是沿海与沼泽农作建筑的排水前提。",
        },
        "research_routes": [
            {
                "id": "research_route.polder_engineering.operating_practice",
                "display_name": "圩田与海岸工程·生产经营实践",
                "route_type": "industrial_practice",
                "description": "掌握水利工程，并以“农业产出达到 10000 并持续 720 日”验证圩田的工程与农业实践；核心硬前置仍须全部完成。",
                "condition": {"operator": 1.0, "children": [
                    {"kind": 0.0, "id": "tech.hydraulic_engineering", "value": 1.0},
                    {"kind": 1.0, "id": "development.output.agriculture.10000_720d", "value": 1.0},
                ]},
            },
            {
                "id": "research_route.polder_engineering.institutional_scale",
                "display_name": "圩田与海岸工程·制度组织能力",
                "route_type": "institutional_capacity",
                "description": "掌握官僚行政，并以“8 座生产设施活跃经营 360 日”验证圩田的公共组织能力；核心硬前置仍须全部完成。",
                "condition": {"operator": 1.0, "children": [
                    {"kind": 0.0, "id": "tech.state_bureaucracy", "value": 1.0},
                    {"kind": 1.0, "id": "development.buildings.active_8_360d", "value": 1.0},
                ]},
            },
        ],
    },
]



# ---------------------------------------------------------------- 第三批：粮食与林产支线续命
NODES_C = [
    {
        "id": "tech.timber_chemical_industry",
        "display_name": "木材化学",
        "era_id": "enlightenment",
        "domain_id": "engineering",
        "cost_points": 256000.0,
        "network_role": "branch",
        "anchor_kind": "branch",
        "node_role": "production_system",
        "effect_profile": "chemistry",
        "secondary_route_tags": ["route.material.materials"],
        "hard_prerequisite_ids": ["tech.forest_management", "tech.charcoal_burning"],
        "prerequisite_rationales": [
            "森林管理提供可持续的木材与树皮供给，木材化学不能建立在掠夺式采伐上。",
            "炭化是木材热解的第一种工业形态，木材化学由它放大而来。",
        ],
        "reveal_condition": {"kind": 1.0, "id": "breakthrough.chemical_process_control", "value": 1.0},
        "reveal_category": "practice_diffusion",
        "reveal_summary": "炭窑与蒸馏实践稳定之后，把木材分解成焦油、沥青与溶剂成为可复现的工序。",
        "modifier_terms": [
            term("country.output.family.chemical_industry_factor", 0.15,
                 "chemical_industry", "化工",
                 "化工产出",
                 "木材热解给出有机碳源，让化工在煤与石油之外多了一条原料路线。"),
        ],
        "content_effects": [],
        "support_buildings": [],
        "opportunity_cost": "占用启蒙时代的通用研究预算，延后同代的农业改良与公共卫生活锚点",
        "application_target_ids": [],
        "terminal_reason": "",
        "branch_family_id": "branch.forest_biomass",
        "era_entry_milestone_id": "tech.global_exchange",
        "branch_successor_ids": ["tech.forest_products_industry"],
        "branch_successor_rationales": [
            "林产工业把木材化学的产品扩成板材、纸浆与树脂，是同一条支线的下一步。",
        ],
        "knowledge_basis": {
            "required_ids": ["tech.forest_management", "tech.charcoal_burning"],
            "alternative_groups": [["tech.kiln_firing"]],
            "exemption_reason": "",
        },
        "topology_review": {
            "role": "continuation",
            "rationale": "森林生物质支线原本死在蒸汽代，本节点把它延续到启蒙代并接上化工。",
            "expected_hard_family_ids": ["branch.forest_biomass"],
        },
        "building_unlock_review": {
            "policy": "support_only",
            "rationale": "本科技不直接呈现新建筑；它是林产化工类建筑的热解与蒸馏前提。",
        },
        "research_routes": [
            {
                "id": "research_route.timber_chemical_industry.operating_practice",
                "display_name": "木材化学·生产经营实践",
                "route_type": "industrial_practice",
                "description": "掌握工业化学，并以“制造业产出达到 10000 并持续 720 日”验证木材化学的产线实践；核心硬前置仍须全部完成。",
                "condition": {"operator": 1.0, "children": [
                    {"kind": 0.0, "id": "tech.kiln_firing", "value": 1.0},
                    {"kind": 1.0, "id": "development.output.manufacturing.10000_720d", "value": 1.0},
                ]},
            },
            {
                "id": "research_route.timber_chemical_industry.institutional_scale",
                "display_name": "木材化学·制度组织能力",
                "route_type": "institutional_capacity",
                "description": "掌握官僚行政，并以“等级 3 聚落持续 360 日”验证木材化学的林场组织能力；核心硬前置仍须全部完成。",
                "condition": {"operator": 1.0, "children": [
                    {"kind": 0.0, "id": "tech.state_bureaucracy", "value": 1.0},
                    {"kind": 1.0, "id": "development.settlement.tier_3_360d", "value": 1.0},
                ]},
            },
        ],
    },
    {
        "id": "tech.industrial_food_preservation",
        "display_name": "食品工业保存",
        "era_id": "steam",
        "domain_id": "agriculture",
        "cost_points": 538000.0,
        "network_role": "backbone",
        "anchor_kind": "backbone",
        "node_role": "production_system",
        "effect_profile": "food",
        "secondary_route_tags": ["route.craft.precision"],
        "hard_prerequisite_ids": ["tech.industrial_canning", "tech.industrial_chemistry"],
        "prerequisite_rationales": [
            "罐头工艺证明密封与灭菌可行，食品工业保存是它的规模化。",
            "防腐、酸度与杀菌需要工业化学给出的可控试剂与检测。",
        ],
        "reveal_condition": {"kind": 1.0, "id": "breakthrough.chemical_process_control", "value": 1.0},
        "reveal_category": "practice_diffusion",
        "reveal_summary": "灭菌与密封在工厂里稳定重复之后，食品的工业保存被揭示。",
        "modifier_terms": [
            term("country.output.terrain.floodplain.manufacturing_factor", 0.10,
                 "floodplain", "泛滥平原",
                 "地理专长",
                 "冲积平原产粮区就近建厂，把易腐粮食转成可长期储运的成品。"),
        ],
        "content_effects": [],
        "support_buildings": [],
        "opportunity_cost": "占用蒸汽时代的通用研究预算，延后同代的铁路与机械锚点",
        "application_target_ids": [],
        "terminal_reason": "",
        "branch_family_id": "backbone.food_storage",
        "era_entry_milestone_id": "tech.enlightenment_institutions",
        "branch_successor_ids": ["tech.cold_chain_industry"],
        "branch_successor_rationales": [
            "冷链把保存从灭菌推进到控温，是同一主干在电气代的下一步。",
        ],
        "knowledge_basis": {
            "required_ids": ["tech.industrial_canning", "tech.industrial_chemistry"],
            "alternative_groups": [["tech.reinforced_concrete"]],
            "exemption_reason": "",
        },
        "topology_review": {
            "role": "continuation",
            "rationale": "食物主干在原子与信息两代本来没有节点，本节点把蒸汽代与电气代接起来。",
            "expected_hard_family_ids": ["backbone.food_storage"],
        },
        "building_unlock_review": {
            "policy": "support_only",
            "rationale": "本科技不直接呈现新建筑；它是罐头、加工与储运类建筑的工艺前提。",
        },
        "research_routes": [
            {
                "id": "research_route.industrial_food_preservation.operating_practice",
                "display_name": "食品工业保存·生产经营实践",
                "route_type": "industrial_practice",
                "description": "掌握机械制冷的前身工艺，并以“制造业产出达到 10000 并持续 720 日”验证食品工业的产线实践；核心硬前置仍须全部完成。",
                "condition": {"operator": 1.0, "children": [
                    {"kind": 0.0, "id": "tech.reinforced_concrete", "value": 1.0},
                    {"kind": 1.0, "id": "development.output.manufacturing.10000_720d", "value": 1.0},
                ]},
            },
            {
                "id": "research_route.industrial_food_preservation.institutional_scale",
                "display_name": "食品工业保存·制度组织能力",
                "route_type": "institutional_capacity",
                "description": "掌握工业组织，并以“32 座生产设施活跃经营 720 日”验证食品工业的组织能力；核心硬前置仍须全部完成。",
                "condition": {"operator": 1.0, "children": [
                    {"kind": 0.0, "id": "tech.industrial_organization", "value": 1.0},
                    {"kind": 1.0, "id": "development.buildings.active_32_720d", "value": 1.0},
                ]},
            },
        ],
    },
    {
        "id": "tech.forest_products_industry",
        "display_name": "林产工业",
        "era_id": "electrical",
        "domain_id": "engineering",
        "cost_points": 1230000.0,
        "network_role": "branch",
        "anchor_kind": "branch",
        "node_role": "production_system",
        "effect_profile": "materials",
        "secondary_route_tags": ["route.material.materials"],
        "hard_prerequisite_ids": ["tech.steam_sawmilling", "tech.timber_chemical_industry"],
        "prerequisite_rationales": [
            "蒸汽锯木给出规模化制材的能力，是板材与纸浆工业的直接前身。",
            "木材化学提供树脂与胶黏剂，没有胶就没有人造板。",
        ],
        "reveal_condition": {"kind": 1.0, "id": "breakthrough.forest_management", "value": 1.0},
        "reveal_category": "practice_diffusion",
        "reveal_summary": "林场经营与制材实践长期稳定后，把木纤维拆解重组为板材与纸浆成为产业。",
        "modifier_terms": [
            term("country.output.family.paper_making_factor", 0.15,
                 "paper_making", "造纸",
                 "造纸产出",
                 "木浆取代破布与树皮成为造纸主原料，纸的供给量级随之改变。"),
        ],
        "content_effects": [],
        "support_buildings": [],
        "opportunity_cost": "占用电气时代的通用研究预算，延后同代的化工与电力锚点",
        "application_target_ids": [],
        "terminal_reason": "林产工业是森林生物质支线的产业落点；更高阶的生物质转化由循环材料承接。",
        "branch_family_id": "branch.forest_biomass",
        "era_entry_milestone_id": "tech.industrialization",
        "branch_successor_ids": [],
        "branch_successor_rationales": [],
        "knowledge_basis": {
            "required_ids": ["tech.steam_sawmilling", "tech.timber_chemical_industry"],
            "alternative_groups": [["tech.kiln_firing"], ["tech.industrial_statistics"]],
            "exemption_reason": "",
        },
        "topology_review": {
            "role": "continuation",
            "rationale": "森林支线在蒸汽代之后无节点，本节点把它推进到电气代并形成完整产业形态。",
            "expected_hard_family_ids": ["branch.forest_biomass"],
        },
        "building_unlock_review": {
            "policy": "support_only",
            "rationale": "本科技不直接呈现新建筑；它是制材、纸浆与人造板类建筑的前提。",
        },
        "research_routes": [
            {
                "id": "research_route.forest_products_industry.operating_practice",
                "display_name": "林产工业·生产经营实践",
                "route_type": "industrial_practice",
                "description": "掌握工业化学，并以“制造业产出达到 10000 并持续 720 日”验证林产工业的产线实践；核心硬前置仍须全部完成。",
                "condition": {"operator": 1.0, "children": [
                    {"kind": 0.0, "id": "tech.kiln_firing", "value": 1.0},
                    {"kind": 1.0, "id": "development.output.manufacturing.1000_360d", "value": 1.0},
                ]},
            },
            {
                "id": "research_route.forest_products_industry.institutional_scale",
                "display_name": "林产工业·制度组织能力",
                "route_type": "institutional_capacity",
                "description": "掌握工业统计，并以“16 座生产设施活跃经营 360 日”验证林产工业的组织能力；核心硬前置仍须全部完成。",
                "condition": {"operator": 1.0, "children": [
                    {"kind": 0.0, "id": "tech.industrial_statistics", "value": 1.0},
                    {"kind": 1.0, "id": "development.buildings.active_16_360d", "value": 1.0},
                ]},
            },
        ],
    },
    {
        "id": "tech.cold_chain_industry",
        "display_name": "冷链",
        "era_id": "electrical",
        "domain_id": "agriculture",
        "cost_points": 1230000.0,
        "network_role": "backbone",
        "anchor_kind": "backbone",
        "node_role": "production_system",
        "effect_profile": "food",
        "secondary_route_tags": ["route.craft.precision"],
        "hard_prerequisite_ids": ["tech.refrigeration", "tech.industrial_food_preservation"],
        "prerequisite_rationales": [
            "机械制冷提供可控低温，冷链只是把制冷机搬到仓储与运输上。",
            "食品工业保存给出灭菌与包装规范，控温与灭菌必须并存才成立。",
        ],
        "reveal_condition": {"kind": 1.0, "id": "development.trade.quantity_1000", "value": 1.0},
        "reveal_category": "practice_diffusion",
        "reveal_summary": "远距离食品贸易量达到规模后，全程控温成为必须解决的问题。",
        "modifier_terms": [
            term("country.output.good.fish_factor", 0.12,
                 "fish", "鱼类",
                 "商品产量",
                 "全程控温把易腐水产的可用比例大幅提高，等于增产。"),
        ],
        "content_effects": [],
        "support_buildings": [],
        "opportunity_cost": "占用电气时代的通用研究预算，延后同代的电网与化工锚点",
        "application_target_ids": [],
        "terminal_reason": "冷链是食物主干的电气代终点；更高阶的保存由食品工业另行推进。",
        "branch_family_id": "backbone.food_storage",
        "era_entry_milestone_id": "tech.industrialization",
        "branch_successor_ids": [],
        "branch_successor_rationales": [],
        "knowledge_basis": {
            "required_ids": ["tech.refrigeration", "tech.industrial_food_preservation"],
            "alternative_groups": [["tech.electrification"]],
            "exemption_reason": "",
        },
        "topology_review": {
            "role": "continuation",
            "rationale": "承接食品工业保存，把食物主干推进到电气代，避免主干在原子与信息两代空洞。",
            "expected_hard_family_ids": ["backbone.food_storage"],
        },
        "building_unlock_review": {
            "policy": "support_only",
            "rationale": "本科技不直接呈现新建筑；它是冷库、冷藏运输与冷链港口的前提。",
        },
        "research_routes": [
            {
                "id": "research_route.cold_chain_industry.operating_practice",
                "display_name": "冷链·生产经营实践",
                "route_type": "industrial_practice",
                "description": "掌握电气化，并以“贸易量达到 10000”验证冷链的实际周转规模；核心硬前置仍须全部完成。",
                "condition": {"operator": 1.0, "children": [
                    {"kind": 0.0, "id": "tech.electrification", "value": 1.0},
                    {"kind": 1.0, "id": "development.trade.quantity_10000", "value": 1.0},
                ]},
            },
            {
                "id": "research_route.cold_chain_industry.institutional_scale",
                "display_name": "冷链·制度组织能力",
                "route_type": "institutional_capacity",
                "description": "掌握公共卫生体系，并以“综合满意度 55% 持续 360 日”验证冷链带来的生活水平；核心硬前置仍须全部完成。",
                "condition": {"operator": 1.0, "children": [
                    {"kind": 0.0, "id": "tech.salt_preservation", "value": 1.0},
                    {"kind": 1.0, "id": "development.satisfaction.55_360d", "value": 1.0},
                ]},
            },
        ],
    },
]


# ---------------------------------------------------------------- 第四批：其余垂死支线的产业落点
NODES_D = [
    {
        "id": "tech.plantation_processing",
        "display_name": "种植园加工",
        "era_id": "exploration",
        "domain_id": "agriculture",
        "cost_points": 109000.0,
        "network_role": "branch",
        "anchor_kind": "branch",
        "node_role": "production_system",
        "effect_profile": "crop",
        "secondary_route_tags": ["route.crop.tropical"],
        "hard_prerequisite_ids": ["tech.estate_plantation_management"],
        "prerequisite_rationales": [
            "庄园化的种植园管理提供了稳定原料批量，加工才有意义。",
        ],
        "reveal_condition": {
            "operator": 1.0,
            "children": [
                {"kind": 1.0, "id": "landform.forest", "value": 1.0},
                {"kind": 1.0, "id": "development.output.agriculture.1000_360d", "value": 1.0},
            ],
        },
        "reveal_category": "practice_diffusion",
        "reveal_summary": "热带原料的产量稳定到需要就地初加工后，种植园加工被揭示。",
        "modifier_terms": [
            term("country.output.terrain.jungle.manufacturing_factor", 0.15,
                 "jungle", "热带雨林",
                 "地理专长",
                 "在产地就地初加工，让易腐的热带原料第一次能承受长途运输。"),
        ],
        "content_effects": [],
        "support_buildings": [],
        "opportunity_cost": "占用探索时代的通用研究预算，延后同代的航海与种植园扩张锚点",
        "application_target_ids": [],
        "terminal_reason": "",
        "branch_family_id": "branch.tropical_commodities",
        "era_entry_milestone_id": "tech.imperial_integration",
        "branch_successor_ids": ["tech.tropical_agroindustry"],
        "branch_successor_rationales": [
            "热带农产工业把初加工扩成糖、油与纤维的成品工业，是同一支线的下一步。",
        ],
        "knowledge_basis": {
            "required_ids": ["tech.estate_plantation_management"],
            "alternative_groups": [["tech.commodity_crop_management"]],
            "exemption_reason": "",
        },
        "topology_review": {
            "role": "continuation",
            "rationale": "热带商品支线原本停在探索代，本节点把它从原料推进到加工形态。",
            "expected_hard_family_ids": ["branch.tropical_commodities"],
        },
        "building_unlock_review": {
            "policy": "support_only",
            "rationale": "本科技不直接呈现新建筑；它是热带原料初加工类建筑的前提。",
        },
        "research_routes": [
            {
                "id": "research_route.plantation_processing.operating_practice",
                "display_name": "种植园加工·生产经营实践",
                "route_type": "industrial_practice",
                "description": "掌握商品作物管理，并以“农业产出达到 1000 并持续 360 日”验证种植园的经营实践；核心硬前置仍须全部完成。",
                "condition": {"operator": 1.0, "children": [
                    {"kind": 0.0, "id": "tech.commodity_crop_management", "value": 1.0},
                    {"kind": 1.0, "id": "development.output.agriculture.1000_360d", "value": 1.0},
                ]},
            },
            {
                "id": "research_route.plantation_processing.institutional_scale",
                "display_name": "种植园加工·制度组织能力",
                "route_type": "institutional_capacity",
                "description": "掌握商业租佃，并以“贸易量达到 1000”验证种植园的销售网络；核心硬前置仍须全部完成。",
                "condition": {"operator": 1.0, "children": [
                    {"kind": 0.0, "id": "tech.commercial_tenancy", "value": 1.0},
                    {"kind": 1.0, "id": "development.trade.quantity_1000", "value": 1.0},
                ]},
            },
        ],
    },
    {
        "id": "tech.tropical_agroindustry",
        "display_name": "热带农产工业",
        "era_id": "steam",
        "domain_id": "agriculture",
        "cost_points": 538000.0,
        "network_role": "branch",
        "anchor_kind": "branch",
        "node_role": "production_system",
        "effect_profile": "chemistry",
        "secondary_route_tags": ["route.crop.tropical"],
        "hard_prerequisite_ids": ["tech.plantation_processing", "tech.industrial_chemistry"],
        "prerequisite_rationales": [
            "初加工给出可运输的半成品，是成品工业的原料基础。",
            "制糖、榨油与漂白都依赖工业化学给出的试剂与工艺控制。",
        ],
        "reveal_condition": {"kind": 1.0, "id": "breakthrough.chemical_process_control", "value": 1.0},
        "reveal_category": "practice_diffusion",
        "reveal_summary": "热带原料的化学处理在工厂中稳定重复后，农产工业被揭示。",
        "modifier_terms": [
            term("country.output.family.chemical_industry_factor", 0.12,
                 "chemical_industry", "化工",
                 "化工产出",
                 "热带作物成为化工的有机原料来源，糖蜜、油脂与纤维都进入工业流程。"),
        ],
        "content_effects": [],
        "support_buildings": [],
        "opportunity_cost": "占用蒸汽时代的通用研究预算，延后同代的铁路与机械锚点",
        "application_target_ids": [],
        "terminal_reason": "热带农产工业是该支线的产业终点；进一步的精细化工由工业化学主线承接。",
        "branch_family_id": "branch.tropical_commodities",
        "era_entry_milestone_id": "tech.enlightenment_institutions",
        "branch_successor_ids": [],
        "branch_successor_rationales": [],
        "knowledge_basis": {
            "required_ids": ["tech.plantation_processing", "tech.industrial_chemistry"],
            "alternative_groups": [["tech.fertilizer_processing"]],
            "exemption_reason": "",
        },
        "topology_review": {
            "role": "continuation",
            "rationale": "把热带商品支线从探索代延续到蒸汽代，形成原料→加工的完整产业形态。",
            "expected_hard_family_ids": ["branch.tropical_commodities"],
        },
        "building_unlock_review": {
            "policy": "support_only",
            "rationale": "本科技不直接呈现新建筑；它是制糖、榨油与热带加工类建筑的工艺前提。",
        },
        "research_routes": [
            {
                "id": "research_route.tropical_agroindustry.operating_practice",
                "display_name": "热带农产工业·生产经营实践",
                "route_type": "industrial_practice",
                "description": "掌握肥料加工，并以“农业产出达到 10000 并持续 720 日”验证热带农产的工业实践；核心硬前置仍须全部完成。",
                "condition": {"operator": 1.0, "children": [
                    {"kind": 0.0, "id": "tech.fertilizer_processing", "value": 1.0},
                    {"kind": 1.0, "id": "development.output.agriculture.10000_720d", "value": 1.0},
                ]},
            },
            {
                "id": "research_route.tropical_agroindustry.institutional_scale",
                "display_name": "热带农产工业·制度组织能力",
                "route_type": "institutional_capacity",
                "description": "掌握工业组织，并以“16 座生产设施活跃经营 360 日”验证农产工业的组织能力；核心硬前置仍须全部完成。",
                "condition": {"operator": 1.0, "children": [
                    {"kind": 0.0, "id": "tech.industrial_organization", "value": 1.0},
                    {"kind": 1.0, "id": "development.buildings.active_16_360d", "value": 1.0},
                ]},
            },
        ],
    },
    {
        "id": "tech.land_reform",
        "display_name": "土地改革",
        "era_id": "steam",
        "domain_id": "society",
        "cost_points": 538000.0,
        "network_role": "branch",
        "anchor_kind": "branch",
        "node_role": "institution",
        "effect_profile": "organization",
        "secondary_route_tags": ["route.institution.records"],
        "hard_prerequisite_ids": ["tech.customary_tenancy", "tech.manorial_jurisdiction"],
        "prerequisite_rationales": [
            "习惯租佃界定了既有佃权，改革必须先知道自己要改什么。",
            "庄园司法提供了土地权利的可裁判形态，改革是把裁判权收归统一法。",
        ],
        "reveal_condition": {
            "operator": 2.0,
            "children": [
                {"kind": 1.0, "id": "development.population.12500_360d", "value": 1.0},
                {"kind": 1.0, "id": "development.settlement.tier_3_360d", "value": 1.0},
            ],
        },
        "reveal_category": "practice_diffusion",
        "reveal_summary": "人口与聚落规模把土地矛盾推到无法回避时，土地改革被揭示。",
        "modifier_terms": [
            term("country.output.family.cadastral_institution_factor", 0.15,
                 "cadastral_institution", "地籍机构",
                 "制度产出",
                 "统一登记与清丈让土地权利可查、可交易、可征税，地籍机构的能力被真正用上。"),
        ],
        "content_effects": [],
        "support_buildings": [],
        "opportunity_cost": "占用蒸汽时代的通用研究预算，延后同代的工业与铁路锚点",
        "application_target_ids": [],
        "terminal_reason": "土地改革以现代产权登记为终点；更进一步的集体化由集体农业另行承接。",
        "branch_family_id": "branch.land_institutions",
        "era_entry_milestone_id": "tech.enlightenment_institutions",
        "branch_successor_ids": [],
        "branch_successor_rationales": [],
        "knowledge_basis": {
            "required_ids": ["tech.customary_tenancy", "tech.manorial_jurisdiction"],
            "alternative_groups": [["tech.property_cadastre"]],
            "exemption_reason": "",
        },
        "topology_review": {
            "role": "continuation",
            "rationale": "土地制度支线原本停在启蒙代，本节点把它延续到蒸汽代并接到现代产权。",
            "expected_hard_family_ids": ["branch.land_institutions"],
        },
        "building_unlock_review": {
            "policy": "support_only",
            "rationale": "本科技不直接呈现新建筑；它是地籍、税务与农业组织类建筑的制度前提。",
        },
        "research_routes": [
            {
                "id": "research_route.land_reform.knowledge_integration",
                "display_name": "土地改革·专业知识整合",
                "route_type": "professional_knowledge",
                "description": "掌握地产测绘，并以“人口达到 12500 并持续 360 日”验证改革的现实压力；核心硬前置仍须全部完成。",
                "condition": {"operator": 1.0, "children": [
                    {"kind": 0.0, "id": "tech.property_cadastre", "value": 1.0},
                    {"kind": 1.0, "id": "development.population.12500_360d", "value": 1.0},
                ]},
            },
            {
                "id": "research_route.land_reform.institutional_scale",
                "display_name": "土地改革·制度组织能力",
                "route_type": "institutional_capacity",
                "description": "掌握官僚行政，并以“等级 3 聚落持续 360 日”验证改革的行政能力；核心硬前置仍须全部完成。",
                "condition": {"operator": 1.0, "children": [
                    {"kind": 0.0, "id": "tech.state_bureaucracy", "value": 1.0},
                    {"kind": 1.0, "id": "development.settlement.tier_3_360d", "value": 1.0},
                ]},
            },
        ],
    },
    {
        "id": "tech.prefabricated_construction",
        "display_name": "预制装配",
        "era_id": "electrical",
        "domain_id": "engineering",
        "cost_points": 1230000.0,
        "network_role": "branch",
        "anchor_kind": "branch",
        "node_role": "production_system",
        "effect_profile": "construction",
        "secondary_route_tags": ["route.material.materials"],
        "hard_prerequisite_ids": ["tech.reinforced_concrete", "tech.assembly_line"],
        "prerequisite_rationales": [
            "钢筋混凝土给出可标准化浇制的构件，是预制的前提。",
            "流水线组织提供把构件在工厂里成批生产、再运到现场装配的组织方法。",
        ],
        "reveal_condition": {"kind": 1.0, "id": "breakthrough.industrial_organization", "value": 1.0},
        "reveal_category": "practice_diffusion",
        "reveal_summary": "构件在工厂成批生产、现场只做装配的实践稳定后，预制装配被揭示。",
        "modifier_terms": [
            term("country.output.family.construction_methods_factor", 0.15,
                 "construction_methods", "营造方法",
                 "营造产出",
                 "把湿作业搬回工厂后，工期与质量不再被天气和现场手艺决定。"),
        ],
        "content_effects": [],
        "support_buildings": [],
        "opportunity_cost": "占用电气时代的通用研究预算，延后同代的电网与化工锚点",
        "application_target_ids": [],
        "terminal_reason": "预制装配是建材支线的施工终点；更进一步的模块化由循环材料承接。",
        "branch_family_id": "branch.construction_materials",
        "era_entry_milestone_id": "tech.industrialization",
        "branch_successor_ids": [],
        "branch_successor_rationales": [],
        "knowledge_basis": {
            "required_ids": ["tech.reinforced_concrete", "tech.assembly_line"],
            "alternative_groups": [["tech.standardization"]],
            "exemption_reason": "",
        },
        "topology_review": {
            "role": "continuation",
            "rationale": "建材支线原本停在蒸汽代，本节点把它推进到电气代的施工组织形态。",
            "expected_hard_family_ids": ["branch.construction_materials"],
        },
        "building_unlock_review": {
            "policy": "support_only",
            "rationale": "本科技不直接呈现新建筑；它是预制构件厂与装配式建筑的前提。",
        },
        "research_routes": [
            {
                "id": "research_route.prefabricated_construction.operating_practice",
                "display_name": "预制装配·生产经营实践",
                "route_type": "industrial_practice",
                "description": "掌握标准化，并以“制造业产出达到 10000 并持续 720 日”验证预制件的产线实践；核心硬前置仍须全部完成。",
                "condition": {"operator": 1.0, "children": [
                    {"kind": 0.0, "id": "tech.standardization", "value": 1.0},
                    {"kind": 1.0, "id": "development.output.manufacturing.10000_720d", "value": 1.0},
                ]},
            },
            {
                "id": "research_route.prefabricated_construction.institutional_scale",
                "display_name": "预制装配·制度组织能力",
                "route_type": "institutional_capacity",
                "description": "掌握工业统计，并以“32 座生产设施活跃经营 720 日”验证预制的组织能力；核心硬前置仍须全部完成。",
                "condition": {"operator": 1.0, "children": [
                    {"kind": 0.0, "id": "tech.industrial_statistics", "value": 1.0},
                    {"kind": 1.0, "id": "development.buildings.active_32_720d", "value": 1.0},
                ]},
            },
        ],
    },
    {
        "id": "tech.technical_textiles",
        "display_name": "技术纺织品",
        "era_id": "information",
        "domain_id": "engineering",
        "cost_points": 6120000.0,
        "network_role": "branch",
        "anchor_kind": "branch",
        "node_role": "production_system",
        "effect_profile": "manufacturing",
        "secondary_route_tags": ["route.material.materials"],
        "hard_prerequisite_ids": ["tech.synthetic_fiber_engineering", "tech.textile_machinery"],
        "prerequisite_rationales": [
            "合成纤维工程给出可按性能设计的纤维，是技术纺织品的前提。",
            "纺织机械提供高密度织造与非织造的能力。",
        ],
        "reveal_condition": {
            "operator": 2.0,
            "children": [
                {"kind": 1.0, "id": "development.output.manufacturing.10000_720d", "value": 1.0},
                {"kind": 1.0, "id": "landform.coast", "value": 1.0},
            ],
        },
        "reveal_category": "practice_diffusion",
        "reveal_summary": "工业与海洋工程对纤维提出强度、耐候与阻燃要求后，技术纺织品被揭示。",
        "modifier_terms": [
            term("country.output.good.clothing_factor", 0.15,
                 "clothing", "服装",
                 "商品产量",
                 "同一套纤维工程既做服装也做土工布、缆绳与过滤材料，服装产线的效率被摊薄。"),
        ],
        "content_effects": [],
        "support_buildings": [],
        "opportunity_cost": "占用信息时代的通用研究预算，延后同代的计算与传感锚点",
        "application_target_ids": [],
        "terminal_reason": "技术纺织品是纤维支线的产业终点；更进一步的智能材料由生物制造承接。",
        "branch_family_id": "branch.textile_fibers",
        "era_entry_milestone_id": "tech.atomic_modernity",
        "branch_successor_ids": [],
        "branch_successor_rationales": [],
        "knowledge_basis": {
            "required_ids": ["tech.synthetic_fiber_engineering", "tech.textile_machinery"],
            "alternative_groups": [["tech.industrial_chemistry"]],
            "exemption_reason": "",
        },
        "topology_review": {
            "role": "continuation",
            "rationale": "纤维支线原本停在原子代，本节点把它推进到信息代并转向工业用纺织品。",
            "expected_hard_family_ids": ["branch.textile_fibers"],
        },
        "building_unlock_review": {
            "policy": "support_only",
            "rationale": "本科技不直接呈现新建筑；它是工业织物与非织造类建筑的前提。",
        },
        "research_routes": [
            {
                "id": "research_route.technical_textiles.operating_practice",
                "display_name": "技术纺织品·生产经营实践",
                "route_type": "industrial_practice",
                "description": "掌握工业化学，并以“制造业产出达到 10000 并持续 720 日”验证技术织物的产线实践；核心硬前置仍须全部完成。",
                "condition": {"operator": 1.0, "children": [
                    {"kind": 0.0, "id": "tech.industrial_chemistry", "value": 1.0},
                    {"kind": 1.0, "id": "development.output.manufacturing.10000_720d", "value": 1.0},
                ]},
            },
            {
                "id": "research_route.technical_textiles.institutional_scale",
                "display_name": "技术纺织品·制度组织能力",
                "route_type": "institutional_capacity",
                "description": "掌握工业质检，并以“32 座生产设施活跃经营 720 日”验证技术织物的质量体系；核心硬前置仍须全部完成。",
                "condition": {"operator": 1.0, "children": [
                    {"kind": 0.0, "id": "tech.industrial_quality_control", "value": 1.0},
                    {"kind": 1.0, "id": "development.buildings.active_32_720d", "value": 1.0},
                ]},
            },
        ],
    },
]


# ---------------------------------------------------------------- 第五批：仍偏薄的四条支线
NODES_E = [
    {
        "id": "tech.polymer_composites",
        "display_name": "高分子复合材料",
        "era_id": "information",
        "domain_id": "engineering",
        "cost_points": 6120000.0,
        "network_role": "branch",
        "anchor_kind": "branch",
        "node_role": "production_system",
        "effect_profile": "chemistry",
        "secondary_route_tags": ["route.material.materials"],
        "hard_prerequisite_ids": ["tech.plastics_engineering"],
        "prerequisite_rationales": [
            "复合材料以聚合物基体为前提：没有可控的塑料，就没有可设计的基体。",
        ],
        "reveal_condition": {
            "operator": 2.0,
            "children": [
                {"kind": 1.0, "id": "development.output.manufacturing.10000_720d", "value": 1.0},
                {"kind": 1.0, "id": "resource.rare_earth", "value": 1.0},
            ],
        },
        "reveal_category": "practice_diffusion",
        "reveal_summary": "塑料产量与稀土供应同时达到规模后，把纤维与基体复合成为可设计的材料。",
        "modifier_terms": [
            term("country.output.family.chemical_industry_factor", 0.12,
                 "chemical_industry", "化工",
                 "化工产出",
                 "复合材料把低价树脂与增强纤维组合成高性能件，化工的产品结构被抬高。"),
        ],
        "content_effects": [],
        "support_buildings": [],
        "opportunity_cost": "占用信息时代的通用研究预算，延后同代的计算与传感锚点",
        "application_target_ids": [],
        "terminal_reason": "高分子复合材料是该支线的材料终点；更进一步的循环再生由循环材料承接。",
        "branch_family_id": "branch.petroleum_materials",
        "era_entry_milestone_id": "tech.atomic_modernity",
        "branch_successor_ids": [],
        "branch_successor_rationales": [],
        "knowledge_basis": {
            "required_ids": ["tech.plastics_engineering"],
            "alternative_groups": [["tech.synthetic_materials"]],
            "exemption_reason": "",
        },
        "topology_review": {
            "role": "continuation",
            "rationale": "石油材料支线只有电气与原子两代，本节点把它推进到信息代。",
            "expected_hard_family_ids": ["branch.petroleum_materials"],
        },
        "building_unlock_review": {
            "policy": "support_only",
            "rationale": "本科技不直接呈现新建筑；它是复合材料与工程塑料类建筑的前提。",
        },
        "research_routes": [
            {
                "id": "research_route.polymer_composites.operating_practice",
                "display_name": "高分子复合材料·生产经营实践",
                "route_type": "industrial_practice",
                "description": "掌握合成材料，并以“制造业产出达到 10000 并持续 720 日”验证复合材料的产线实践；核心硬前置仍须全部完成。",
                "condition": {"operator": 1.0, "children": [
                    {"kind": 0.0, "id": "tech.synthetic_materials", "value": 1.0},
                    {"kind": 1.0, "id": "development.output.manufacturing.10000_720d", "value": 1.0},
                ]},
            },
            {
                "id": "research_route.polymer_composites.institutional_scale",
                "display_name": "高分子复合材料·制度组织能力",
                "route_type": "institutional_capacity",
                "description": "掌握工业质检，并以“32 座生产设施活跃经营 720 日”验证复合材料的质量体系；核心硬前置仍须全部完成。",
                "condition": {"operator": 1.0, "children": [
                    {"kind": 0.0, "id": "tech.industrial_quality_control", "value": 1.0},
                    {"kind": 1.0, "id": "development.buildings.active_32_720d", "value": 1.0},
                ]},
            },
        ],
    },
    {
        "id": "tech.terrace_mechanization",
        "display_name": "梯田机械化",
        "era_id": "steam",
        "domain_id": "agriculture",
        "cost_points": 538000.0,
        "network_role": "branch",
        "anchor_kind": "branch",
        "node_role": "power_scale",
        "effect_profile": "crop",
        "secondary_route_tags": ["route.ecology.highland"],
        "hard_prerequisite_ids": ["tech.highland_tuber_farming", "tech.mechanized_agriculture"],
        "prerequisite_rationales": [
            "梯田的畦作与坡面经验是机械化改造的对象。",
            "机械化农业提供小型动力与机具，梯田的机械化只是把它缩尺适配坡地。",
        ],
        "reveal_condition": {"kind": 1.0, "id": "breakthrough.automation", "value": 1.0},
        "reveal_category": "practice_diffusion",
        "reveal_summary": "坡地上的机具改造反复试成之后，梯田机械化被揭示。",
        "modifier_terms": [
            term("country.output.landform.plateau.agriculture_factor", 0.20,
                 "plateau", "高原",
                 "地理专长",
                 "小型机具能上田，高原与山地梯田的耕作强度第一次被机械抬起。"),
        ],
        "content_effects": [],
        "support_buildings": [],
        "opportunity_cost": "占用蒸汽时代的通用研究预算，延后同代的工业与铁路锚点",
        "application_target_ids": [],
        "terminal_reason": "梯田机械化是高地块茎支线的动力终点；更高海拔的精准化由精准农业另行承接。",
        "branch_family_id": "branch.tuber_highland",
        "era_entry_milestone_id": "tech.enlightenment_institutions",
        "branch_successor_ids": [],
        "branch_successor_rationales": [],
        "knowledge_basis": {
            "required_ids": ["tech.highland_tuber_farming", "tech.mechanized_agriculture"],
            "alternative_groups": [["tech.mountain_irrigation"]],
            "exemption_reason": "",
        },
        "topology_review": {
            "role": "continuation",
            "rationale": "块茎高地支线在帝国代之后无节点，本节点把它推进到蒸汽代。",
            "expected_hard_family_ids": ["branch.tuber_highland"],
        },
        "building_unlock_review": {
            "policy": "support_only",
            "rationale": "本科技不直接呈现新建筑；它是坡地机具与梯田农作类建筑的动力前提。",
        },
        "research_routes": [
            {
                "id": "research_route.terrace_mechanization.operating_practice",
                "display_name": "梯田机械化·生产经营实践",
                "route_type": "industrial_practice",
                "description": "掌握山地灌溉，并以“农业产出达到 10000 并持续 720 日”验证坡地机械化的实践；核心硬前置仍须全部完成。",
                "condition": {"operator": 1.0, "children": [
                    {"kind": 0.0, "id": "tech.mountain_irrigation", "value": 1.0},
                    {"kind": 1.0, "id": "development.output.agriculture.10000_720d", "value": 1.0},
                ]},
            },
            {
                "id": "research_route.terrace_mechanization.institutional_scale",
                "display_name": "梯田机械化·制度组织能力",
                "route_type": "institutional_capacity",
                "description": "掌握农业合作社，并以“等级 3 聚落持续 360 日”验证坡地机械的共用组织；核心硬前置仍须全部完成。",
                "condition": {"operator": 1.0, "children": [
                    {"kind": 0.0, "id": "tech.agricultural_cooperatives", "value": 1.0},
                    {"kind": 1.0, "id": "development.settlement.tier_3_360d", "value": 1.0},
                ]},
            },
        ],
    },
    {
        "id": "tech.aquifer_management",
        "display_name": "含水层管理",
        "era_id": "information",
        "domain_id": "engineering",
        "cost_points": 6120000.0,
        "network_role": "branch",
        "anchor_kind": "branch",
        "node_role": "production_system",
        "effect_profile": "hydraulic",
        "secondary_route_tags": ["route.geography.coast"],
        "hard_prerequisite_ids": ["tech.hydraulic_engineering", "tech.precision_irrigation"],
        "prerequisite_rationales": [
            "水利工程给出流域尺度的取水与配水方法。",
            "精准灌溉提供可计量的用水数据，没有计量就谈不上管理含水层。",
        ],
        "reveal_condition": {"kind": 1.0, "id": "breakthrough.watershed_management", "value": 1.0},
        "reveal_category": "practice_diffusion",
        "reveal_summary": "流域治理与井灌计量同时成熟后，把地下水当作可管理的存量成为可能。",
        "modifier_terms": [
            term("country.climate.drought_loss_factor", 0.10,
                 "drought", "干旱",
                 "气候适应",
                 "可采补平衡的含水层让干旱年的产量损失显著下降。"),
        ],
        "content_effects": [],
        "support_buildings": [],
        "opportunity_cost": "占用信息时代的通用研究预算，延后同代的传感与计算锚点",
        "application_target_ids": [],
        "terminal_reason": "含水层管理是水风支线的现代终点；更高阶的水资源调配由自适应灌溉承接。",
        "branch_family_id": "branch.water_wind",
        "era_entry_milestone_id": "tech.atomic_modernity",
        "branch_successor_ids": [],
        "branch_successor_rationales": [],
        "knowledge_basis": {
            "required_ids": ["tech.hydraulic_engineering", "tech.precision_irrigation"],
            "alternative_groups": [["tech.precision_agriculture"]],
            "exemption_reason": "",
        },
        "topology_review": {
            "role": "continuation",
            "rationale": "水风支线原本停在启蒙代，本节点把它接到信息代的资源管理形态。",
            "expected_hard_family_ids": ["branch.water_wind"],
        },
        "building_unlock_review": {
            "policy": "support_only",
            "rationale": "本科技不直接呈现新建筑；它是井灌、蓄水与流域管理类建筑的前提。",
        },
        "research_routes": [
            {
                "id": "research_route.aquifer_management.operating_practice",
                "display_name": "含水层管理·生产经营实践",
                "route_type": "industrial_practice",
                "description": "掌握精准农业，并以“农业产出达到 100000 并持续 1095 日”验证流域用水的规模；核心硬前置仍须全部完成。",
                "condition": {"operator": 1.0, "children": [
                    {"kind": 0.0, "id": "tech.precision_agriculture", "value": 1.0},
                    {"kind": 1.0, "id": "development.output.agriculture.100000_1095d", "value": 1.0},
                ]},
            },
            {
                "id": "research_route.aquifer_management.institutional_scale",
                "display_name": "含水层管理·制度组织能力",
                "route_type": "institutional_capacity",
                "description": "掌握水文遥感，并以“等级 5 聚落持续 1095 日”验证流域管理的行政能力；核心硬前置仍须全部完成。",
                "condition": {"operator": 1.0, "children": [
                    {"kind": 0.0, "id": "tech.hydrological_remote_sensing", "value": 1.0},
                    {"kind": 1.0, "id": "development.settlement.tier_5_1095d", "value": 1.0},
                ]},
            },
        ],
    },
    {
        "id": "tech.rare_earth_processing",
        "display_name": "稀土分离",
        "era_id": "information",
        "domain_id": "engineering",
        "cost_points": 6120000.0,
        "network_role": "branch",
        "anchor_kind": "branch",
        "node_role": "production_system",
        "effect_profile": "metallurgy",
        "secondary_route_tags": ["route.material.materials"],
        "hard_prerequisite_ids": ["tech.deep_geophysics", "tech.industrial_chemistry"],
        "prerequisite_rationales": [
            "深层地球物理给出稀土矿体的定位能力，找不到矿就谈不上分离。",
            "分离依赖溶剂萃取与离子交换，二者都属于工业化学的方法谱系。",
        ],
        "reveal_condition": {"kind": 1.0, "id": "resource.rare_earth", "value": 1.0},
        "reveal_category": "environment_observation",
        "reveal_summary": "在独居石或离子吸附型矿体被实际发现并试分离后，稀土分离被揭示。",
        "modifier_terms": [
            term("country.resource.rare_earth.use_factor", 0.15,
                 "rare_earth", "稀土",
                 "资源利用",
                 "逐级萃取把混合稀土分成单一元素，同一吨矿的可用产出成倍提升。"),
        ],
        "content_effects": [],
        "support_buildings": [],
        "opportunity_cost": "占用信息时代的通用研究预算，延后同代的半导体与传感锚点",
        "application_target_ids": [],
        "terminal_reason": "稀土分离是有色金属支线的材料终点；更进一步的合金设计由先进冶金承接。",
        "branch_family_id": "branch.nonferrous_metals",
        "era_entry_milestone_id": "tech.atomic_modernity",
        "branch_successor_ids": [],
        "branch_successor_rationales": [],
        "knowledge_basis": {
            "required_ids": ["tech.deep_geophysics", "tech.industrial_chemistry"],
            "alternative_groups": [["tech.advanced_metallurgy"]],
            "exemption_reason": "",
        },
        "topology_review": {
            "role": "continuation",
            "rationale": "有色金属支线停在原子代，本节点把它推进到信息代的元素级分离。",
            "expected_hard_family_ids": ["branch.nonferrous_metals"],
        },
        "building_unlock_review": {
            "policy": "support_only",
            "rationale": "本科技不直接呈现新建筑；它是稀土分离与特种合金类建筑的前提。",
        },
        "research_routes": [
            {
                "id": "research_route.rare_earth_processing.operating_practice",
                "display_name": "稀土分离·生产经营实践",
                "route_type": "industrial_practice",
                "description": "掌握先进冶金，并以“采掘产出达到 10000 并持续 720 日”验证分离产线的规模；核心硬前置仍须全部完成。",
                "condition": {"operator": 1.0, "children": [
                    {"kind": 0.0, "id": "tech.advanced_metallurgy", "value": 1.0},
                    {"kind": 1.0, "id": "development.output.extractive.10000_720d", "value": 1.0},
                ]},
            },
            {
                "id": "research_route.rare_earth_processing.institutional_scale",
                "display_name": "稀土分离·制度组织能力",
                "route_type": "institutional_capacity",
                "description": "掌握国家实验室，并以“32 座生产设施活跃经营 720 日”验证分离体系的组织能力；核心硬前置仍须全部完成。",
                "condition": {"operator": 1.0, "children": [
                    {"kind": 0.0, "id": "tech.national_laboratories", "value": 1.0},
                    {"kind": 1.0, "id": "development.buildings.active_32_720d", "value": 1.0},
                ]},
            },
        ],
    },
]


GEO_CAP_PER_KEY = 0.35
FAMILY_CAP = 0.80


def cap_geo_and_family(data):
    """新增节点会把地理/家族键顶过预算；这里做最后一次收敛（与 apply_v5 同口径）。"""
    buckets = {}
    for node in data["nodes"]:
        for index, term in enumerate(node.get("modifier_terms") or []):
            stat = str(term.get("stat", ""))
            if stat.startswith("country.output.family."):
                buckets.setdefault(stat, (FAMILY_CAP, []) )[1].append((node, index))
            elif ".terrain." in stat or ".landform." in stat:
                buckets.setdefault(stat, (GEO_CAP_PER_KEY, []))[1].append((node, index))
    scaled = 0
    for stat, (cap, entries) in buckets.items():
        total = sum(abs(float(node["modifier_terms"][index].get("value") or 0.0))
                    for node, index in entries)
        if total <= cap or total <= 0:
            continue
        ratio = cap / total
        for node, index in entries:
            node["modifier_terms"][index]["value"] = round(
                float(node["modifier_terms"][index].get("value") or 0.0) * ratio, 3)
        scaled += 1
    return scaled


# ---------------------------------------------------------------- 第六批：水产养殖
NODES_F = [
    {
        "id": "tech.aquaculture",
        "display_name": "水产养殖",
        "era_id": "electrical",
        "domain_id": "agriculture",
        "cost_points": 1230000.0,
        "network_role": "branch",
        "anchor_kind": "branch",
        "node_role": "production_system",
        "effect_profile": "fishing",
        "secondary_route_tags": ["route.ecology.coast"],
        "hard_prerequisite_ids": ["tech.refrigeration", "tech.oceanic_ship_design"],
        "prerequisite_rationales": [
            "养殖要控温与保险，机械制冷提供鱼苗与成鱼运输的存活条件。",
            "远洋船设计给出网箱、浮架与系泊的工程经验，池塘与海上养殖都由它放大而来。",
        ],
        "reveal_condition": {
            "operator": 2.0,
            "children": [
                {"kind": 1.0, "id": "resource.marine_fish", "value": 1.0},
                {"kind": 1.0, "id": "development.output.agriculture.1000_360d", "value": 1.0},
            ],
        },
        "reveal_category": "practice_diffusion",
        "reveal_summary": "近海捕捞量长期下滑、而冷藏与饲料条件成熟后，把鱼养起来成为可做的事。",
        "modifier_terms": [
            term("country.output.family.maritime_operations_factor", 0.12,
                 "maritime_operations", "海运作业",
                 "产业产出",
                 "养殖把靠天吃饭的捕捞变成可计划的水产供给，海运作业家族的产品结构随之改变。"),
        ],
        "content_effects": [],
        "support_buildings": [],
        "opportunity_cost": "占用电气时代的通用研究预算，延后同代的电网与化工锚点",
        "application_target_ids": [],
        "terminal_reason": "水产养殖是海洋支线在电气代的产业落点；更进一步的离岸养殖由自主水产承接。",
        "branch_family_id": "branch.maritime_logistics",
        "era_entry_milestone_id": "tech.industrialization",
        "branch_successor_ids": [],
        "branch_successor_rationales": [],
        "knowledge_basis": {
            "required_ids": ["tech.refrigeration", "tech.oceanic_ship_design"],
            "alternative_groups": [["tech.electrification"]],
            "exemption_reason": "",
        },
        "topology_review": {
            "role": "branch",
            "rationale": "海洋支线此前只有捕捞与运输，缺「养殖」这一产业形态；它也给海岸/湖泊生态一条独占产业。",
            "expected_hard_family_ids": ["branch.maritime_logistics"],
        },
        "building_unlock_review": {
            "policy": "single",
            "rationale": "本科技直接解锁「养鱼场」，作为海岸与湖泊生态的水产生产方式。",
        },
        "research_routes": [
            {
                "id": "research_route.aquaculture.operating_practice",
                "display_name": "水产养殖·生产经营实践",
                "route_type": "industrial_practice",
                "description": "掌握电气化，并以“农业产出达到 10000 并持续 720 日”验证养殖场的经营实践；核心硬前置仍须全部完成。",
                "condition": {"operator": 1.0, "children": [
                    {"kind": 0.0, "id": "tech.electrification", "value": 1.0},
                    {"kind": 1.0, "id": "development.output.agriculture.10000_720d", "value": 1.0},
                ]},
            },
            {
                "id": "research_route.aquaculture.institutional_scale",
                "display_name": "水产养殖·制度组织能力",
                "route_type": "institutional_capacity",
                "description": "掌握远岸渔业管理，并以“16 座生产设施活跃经营 360 日”验证养殖的组织能力；核心硬前置仍须全部完成。",
                "condition": {"operator": 1.0, "children": [
                    {"kind": 0.0, "id": "tech.commodity_crop_management", "value": 1.0},
                    {"kind": 1.0, "id": "development.buildings.active_16_360d", "value": 1.0},
                ]},
            },
        ],
    },
]


def load():
    with open(NETWORK, encoding="utf-8") as handle:
        return json.load(handle)


def save(payload):
    temporary = NETWORK + ".v5tmp"
    with open(temporary, "w", encoding="utf-8", newline="\n") as handle:
        json.dump(payload, handle, ensure_ascii=False, indent="\t")
        handle.write("\n")
    os.replace(temporary, NETWORK)


def build_node(spec, layout_order):
    node = dict(spec)
    node["layout_order"] = layout_order
    node["is_milestone"] = False
    node["is_era_key"] = False
    node["is_starting"] = False
    node["is_starter_eligible"] = False
    node["starter_capability_tags"] = []
    node["expected_bindings"] = []
    node["effect_summary"] = ""
    node["branch_successor_rationales"] = node.get("branch_successor_rationales") or []
    node["application_target_rationales"] = []
    node["prerequisite_rationales"] = node.get("prerequisite_rationales") or []
    node["branch_successor_ids"] = node.get("branch_successor_ids") or []
    node["application_target_ids"] = node.get("application_target_ids") or []
    node["terminal_reason"] = node.get("terminal_reason", "")
    node["route_exemption_reason"] = node.get("route_exemption_reason", "")
    node["reveal_template_reason"] = node.get("reveal_template_reason",
        "按该科技的真实观察或产业问题设置揭示条件，不使用通用模板。")
    node["effect_design_review"] = dict(REVIEW_OK)
    return node


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--dry-run", action="store_true")
    arguments = parser.parse_args()
    data = load()
    nodes = data["nodes"]
    by_id = {node["id"]: node for node in nodes}
    eras = [era["id"] for era in data["eras"]]
    log = []
    added = 0
    for spec in NODES + NODES_B + NODES_C + NODES_D + NODES_E + NODES_F:
        if spec["id"] in by_id:
            log.append("SKIP 已存在 %s" % spec["id"])
            continue
        era_id = spec["era_id"]
        last_index = max(index for index, node in enumerate(nodes)
                         if node["era_id"] == era_id)
        layout = max(float(node.get("layout_order") or 0.0) for node in nodes
                     if node["era_id"] == era_id) + 0.5
        node = build_node(spec, layout)
        nodes.insert(last_index + 1, node)
        by_id[node["id"]] = node
        added += 1
        log.append("新增 %-32s era=%-12s cost=%.0f" % (node["id"], era_id,
                                                       node["cost_points"]))
    edges_added = 0
    for target_id, prerequisite_id, rationale in EDGES:
        node = by_id.get(target_id)
        if node is None:
            log.append("SKIP 下游不存在 %s" % target_id)
            continue
        hard = node.get("hard_prerequisite_ids") or []
        if prerequisite_id in hard:
            continue
        hard.append(prerequisite_id)
        node["hard_prerequisite_ids"] = hard
        node.setdefault("prerequisite_rationales", []).append(rationale)
        edges_added += 1
        log.append("加边 %s ⇠ %s" % (target_id, prerequisite_id))
    # 行序校验
    order = {node["id"]: index for index, node in enumerate(nodes)}
    for node in nodes:
        for prerequisite in node.get("hard_prerequisite_ids") or []:
            if order.get(prerequisite, 1 << 30) >= order[node["id"]]:
                raise SystemExit("row order violated: %s needs %s earlier"
                                 % (node["id"], prerequisite))
    for line in log:
        print(line)
    print("--- nodes +%d / edges +%d ---" % (added, edges_added))
    scaled = cap_geo_and_family(data)
    if scaled:
        print("地理/家族键预算收敛：%d 个键" % scaled)
    if arguments.dry_run:
        print("(dry-run：未写盘)")
        return 0
    save(data)
    print("written: %s" % NETWORK)
    return 0


if __name__ == "__main__":
    sys.exit(main())
