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
from collections import defaultdict
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
NETWORK = ROOT / "data" / "technology" / "technology_network.json"


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
    referenced = set(FAMILY_OVERRIDES) | set(HARD_OVERRIDES) | set(RESEARCH_CONDITIONS)
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
        condition, summary = RESEARCH_CONDITIONS.get(node["id"], ({}, ""))
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

    steam_sawmilling = by_id["tech.steam_sawmilling"]
    binding = {"kind": 2, "id": "method_lumber_plant_r6"}
    if binding not in steam_sawmilling["expected_bindings"]:
        steam_sawmilling["expected_bindings"].append(binding)
    steam_sawmilling["content_effects"] = [effect for effect in steam_sawmilling["content_effects"]
        if str(effect.get("id", "")) != "method_lumber_plant_r6"]
    steam_sawmilling["content_effects"].append({
        "kind": "building", "id": "method_lumber_plant_r6", "binding_kind": 2,
        "subject": "building.method_lumber_plant_r6",
        "attribute": "construction_and_production_access", "operation": "unlock", "value": 1,
        "implementation": "BuildingProfile.technology_tags", "status": "new_content",
        "display_name": "蒸汽锯木厂",
    })
    steam_sawmilling["effect_summary"] = "解锁生产方法：蒸汽锯木厂"

    for node in nodes:
        alternatives = condition_technology_ids(node["research_condition"])
        overlap = alternatives.intersection(node["hard_prerequisite_ids"])
        if overlap:
            raise ValueError(f"{node['id']} repeats hard prerequisites as alternatives: {sorted(overlap)}")
        node["prerequisite_rationales"] = [rationale(by_id[source], node)
            for source in node["hard_prerequisite_ids"]]

    era_order = {era["id"]: int(era["sort_order"]) for era in payload["eras"]}
    for node in nodes:
        target_era = era_order[node["era_id"]]
        for prerequisite in node["hard_prerequisite_ids"]:
            if era_order[by_id[prerequisite]["era_id"]] > target_era:
                raise ValueError(f"future-era prerequisite: {prerequisite} -> {node['id']}")
        for target in node["branch_successor_ids"]:
            if by_id[target]["branch_family_id"] != node["branch_family_id"]:
                raise ValueError(f"cross-family branch successor must be application: {node['id']} -> {target}")

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
            consumer_text = "、".join(consumers) if consumers else "已声明的内容效果与数值消费者"
            node["terminal_reason"] = (
                f"{node['display_name']}是{family_names[node['branch_family_id']]}在当前目录中的应用端点，"
                f"其终值由{consumer_text}消费")

    payload["semantic_review"] = {
        "version": 1,
        "reviewed_node_count": len(payload["nodes"]),
        "relationship_policy": "explicit_authoring_only",
        "allowed_research_condition_ids": sorted(RESEARCH_CONDITIONS),
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
