"""Wave B/C: polytech-grounded prerequisite surgery, family continuity and node set repair.

Every hard edge below answers "which mastered knowledge is irreplaceable for this
technology?".  Historical anchors come from secwind7/polytech-tree (year/prereqs),
e.g. reinforced concrete 1867 <- Portland cement; power loom <- flying shuttle;
numerical weather prediction 1950 <- electronic computer; smart grid 2005 <-
grid + microprocessor + internet.

The script also:
* prunes research-route atoms that duplicate a new hard prerequisite, drops routes
  that became implied by the core history, and repairs knowledge_basis;
* removes reveal atoms already implied by the new core history (Kingdom+);
* rewrites template rationales that exposed internal ``tech.*`` IDs;
* re-sorts nodes into an era-grouped topological order.

Usage: python wave_b_prerequisites.py [--apply]
"""
from __future__ import annotations

import copy
import re
import sys
from collections import defaultdict

from techtree_lib import ERA_IDS, ERA_INDEX, NETWORK_PATH, Model, dump_json, write_tres_array

# node -> [(prerequisite, rationale), ...]  (replaces the whole hard list)
EDITS: dict[str, list[tuple[str, str]]] = {
    # ---------------------------------------------------------------- agrarian
    # Either fishing tradition alone opens fishing boats (visible ANY_OF route).
    "tech.fishing_boats": [],
    # ---------------------------------------------------------------- kingdom
    "tech.urban_sanitation": [
        ("tech.permanent_settlements", "只有长期聚居的城镇才会面对集中排污与饮水污染问题。"),
        ("tech.masonry", "排水沟渠与暗渠依赖砌体结构（参照印度河流域城市排污与罗马大下水道）。"),
    ],
    "tech.river_transport": [
        ("tech.fishing_boats", "河运由渔舟造船经验放大为载货船只与航道组织。"),
    ],
    "tech.road_engineering": [
        ("tech.permanent_settlements", "道路网络连接长期聚落与市场。"),
        ("tech.masonry", "铺石路面、桥涵与路基需要砌筑技术。"),
    ],
    "tech.natural_philosophy": [
        ("tech.writing", "系统的自然哲学需要文字记录、传抄与辩论。"),
    ],
    "tech.surface_coal_use": [
        ("tech.surface_coal_collection", "先要能稳定拣采露头煤，才谈得上把煤用作燃料。"),
        ("tech.kiln_firing", "窑炉控温经验让煤的高温燃烧可控。"),
    ],
    "tech.parchment_making": [
        ("tech.writing", "皮纸是为书写而加工的载体。"),
        ("tech.hide_tanning", "皮纸制作沿用生皮去毛、浸灰与绷晾的鞣制工艺。"),
    ],
    "tech.customary_tenancy": [
        ("tech.household_landholding", "佃作以家庭占有与耕作土地的习惯权利为前提。"),
    ],
    "tech.sharecropping": [
        ("tech.customary_tenancy", "分成租佃是在习惯佃作上约定产量分配的租佃形式。"),
    ],
    "tech.tenant_cereal_farming": [
        ("tech.customary_tenancy", "佃作谷物依赖已成形的租佃关系。"),
        ("tech.rainfed_field_system", "佃户耕作的是成片雨养田。"),
    ],
    "tech.tenant_paddy_management": [
        ("tech.rice_paddy_cultivation", "佃作水田以成熟的水田稻作为耕作对象。"),
        ("tech.customary_tenancy", "水田的租佃分配依赖习惯佃作。"),
    ],
    "tech.iron_smelting": [
        ("tech.surface_iron_collection", "先能拣采地表铁矿才有块炼原料。"),
        ("tech.charcoal_burning", "块炼炉以木炭为燃料与还原剂。"),
    ],
    # ---------------------------------------------------------------- empire
    "tech.water_power": [
        ("tech.irrigation", "水车最早用于提水灌溉，随后才转为磨坊与鼓风动力。"),
    ],
    "tech.wind_power": [
        ("tech.water_power", "风车沿用水磨的齿轮传动与磨盘机构（风车晚于水车出现）。"),
    ],
    "tech.guild_organization": [
        ("tech.market_institutions", "行会是城市手工业者在市场制度中的自我组织。"),
    ],
    "tech.crucible_steel": [
        ("tech.iron_smelting", "坩埚钢以块炼铁为原料再行渗碳熔炼。"),
        ("tech.pottery", "耐高温的陶质坩埚来自成熟的陶器容器工艺。"),
    ],
    "tech.coal_mining": [
        ("tech.coal_adit_mining", "竖井煤矿是在平硐采煤之上向深处延伸。"),
    ],
    "tech.gunpowder_formulation": [
        ("tech.kiln_firing", "硝石提纯与加热配料依赖窑炉控温经验。"),
        ("tech.charcoal_burning", "木炭是火药三组分之一。"),
    ],
    "tech.scholastic_method": [
        ("tech.manuscript_culture", "经院研究法建立在手稿抄传与注疏传统之上。"),
    ],
    "tech.manorial_jurisdiction": [
        ("tech.estate_accounting", "庄园司法以庄园核算所确立的领主—佃户账目为依据。"),
    ],
    "tech.serf_obligations": [
        ("tech.manorial_jurisdiction", "农奴劳役由庄园司法强制执行。"),
    ],
    "tech.manorial_cereal_farming": [
        ("tech.serf_obligations", "庄园谷物经营依赖农奴的周工劳役。"),
        ("tech.intensive_crop_rotation", "庄园普遍采用三圃制集约轮作。"),
    ],
    "tech.guild_apprenticeship": [
        ("tech.guild_organization", "学徒制是行会传承技艺与限制入行的制度。"),
    ],
    "tech.movable_type_printing": [
        ("tech.pottery", "泥活字需要烧制稳定的陶字。"),
        ("tech.woodblock_printing", "活字印刷继承雕版的刷墨、覆纸与版面工艺（金属活字 ← 雕版印刷）。"),
    ],
    "tech.mine_timbering": [
        ("tech.coal_adit_mining", "木支护首先用于加固平硐巷道。"),
        ("tech.timber_sawing", "支护需要成批锯制的立柱与横梁。"),
    ],
    "tech.estate_cereal_management": [
        ("tech.estate_accounting", "庄园谷物核算把粮食产量纳入庄园账簿。"),
        ("tech.sharecropping", "玉米与小麦庄园以分成租佃组织劳动。"),
    ],
    "tech.estate_paddy_management": [
        ("tech.tenant_paddy_management", "庄园水田核算建立在佃作水田之上。"),
        ("tech.estate_accounting", "水田产量要纳入庄园账簿统一核算。"),
    ],
    "tech.forest_management": [
        ("tech.timber_sawing", "森林经营是为持续供应锯材而进行的轮伐与育林。"),
    ],
    "tech.pastoral_networks": [
        ("tech.pastoralism", "牧业网络把游牧放牧扩展为跨区域的转场体系。"),
        ("tech.estate_accounting", "庄园牧场需要以账簿管理畜群与草场。"),
    ],
    "tech.blast_furnace": [
        ("tech.iron_smelting", "高炉是块炼炉在炉高与温度上的放大。"),
        ("tech.water_power", "高炉持续高温依赖水力鼓风。"),
    ],
    # ---------------------------------------------------------------- exploration
    "tech.cartography": [
        ("tech.writing", "地图需要文字标注与抄绘传承。"),
        ("tech.weights_and_measures", "按比例绘图依赖统一的长度度量与测量。"),
    ],
    "tech.celestial_navigation": [
        ("tech.celestial_calendars", "天文导航沿用天文历法的星位观测。"),
        ("tech.magnetic_navigation", "远离海岸时需要罗盘与天测共同定向。"),
    ],
    "tech.oceanic_navigation": [
        ("tech.cartography", "远洋航行依赖航海图。"),
        ("tech.celestial_navigation", "远洋定位依赖天文导航。"),
    ],
    "tech.gunpowder_weapons": [
        ("tech.gunpowder_formulation", "火器以稳定配方的火药为推进剂。"),
        ("tech.bronze_casting", "早期火炮以青铜铸造炮管。"),
    ],
    "tech.double_entry_bookkeeping": [
        ("tech.bills_of_exchange", "意大利银行家为汇兑往来发展出复式账簿（复式记账 1300）。"),
    ],
    "tech.commercial_estates": [
        ("tech.double_entry_bookkeeping", "面向市场的农庄以复式账簿核算盈亏。"),
        ("tech.estate_cereal_management", "商业农庄由庄园谷物核算转向商品化经营。"),
    ],
    "tech.mercantile_networks": [
        ("tech.market_institutions", "商业网络连接各地市场。"),
        ("tech.currency", "跨区域结算依赖通用货币。"),
    ],
    "tech.mechanical_timekeeping": [
        ("tech.water_power", "机械钟沿用水力机械的齿轮系与擒纵思想。"),
        ("tech.celestial_calendars", "计时需要以天文历法校准。"),
    ],
    "tech.shaft_sinking": [
        ("tech.deep_mining", "井筒开掘是深井采矿的竖向通道工程。"),
    ],
    "tech.mine_drainage": [
        ("tech.deep_mining", "深井首先遇到地下水淹井问题。"),
        ("tech.water_power", "早期排水泵由水轮驱动。"),
    ],
    "tech.commercial_tenancy": [
        ("tech.double_entry_bookkeeping", "商业租佃以货币地租和账簿结算。"),
        ("tech.customary_tenancy", "商业租佃由习惯佃作契约化而来。"),
    ],
    "tech.chartered_companies": [
        ("tech.mercantile_networks", "特许商社经营既有的远程商业网络。"),
        ("tech.double_entry_bookkeeping", "股份商社需要复式账簿向股东核算（股份公司 ← 近代银行与保险）。"),
    ],
    "tech.commodity_crop_management": [
        ("tech.cotton_gardening", "棉花是最早规模化的商品作物之一。"),
        ("tech.mercantile_networks", "商品作物面向远程市场出售。"),
    ],
    "tech.oceanic_provisioning": [
        ("tech.oceanic_navigation", "远洋补给服务于长距离航行。"),
        ("tech.salt_preservation", "远洋补给以盐渍食物为主要储备。"),
    ],
    "tech.agronomic_exchange": [
        ("tech.intensive_crop_rotation", "农艺交换比较各地轮作与耕作经验。"),
        ("tech.interregional_botany", "跨区域植物学提供了作物与农艺的比较对象。"),
    ],
    "tech.indentured_contracts": [
        ("tech.commercial_tenancy", "契约劳工沿用商业租佃的书面契约形式。"),
        ("tech.commodity_crop_management", "契约劳工主要服务于商品作物种植。"),
    ],
    # ---------------------------------------------------------------- enlightenment
    "tech.scientific_classification": [
        ("tech.interregional_botany", "林奈分类建立在跨区域植物采集与比较之上。"),
    ],
    "tech.experimental_science": [
        ("tech.scholastic_method", "实验科学由经院研究法的论证传统发展而来。"),
        ("tech.screw_press_printing", "实验报告依靠印刷快速传播与复核。"),
    ],
    "tech.standardization": [
        ("tech.precision_engineering", "工业标准化以精密加工能达到的公差为基础（惠氏螺纹 ← 全金属螺纹车床）。"),
    ],
    "tech.public_health": [
        ("tech.urban_sanitation", "公共卫生由城市排污与供水治理发展而来。"),
        ("tech.experimental_science", "疫情调查与死亡统计依靠实验与观察方法。"),
    ],
    "tech.geological_prospecting": [
        ("tech.natural_philosophy", "地质勘探需要自然哲学的成因解释。"),
        ("tech.deep_mining", "深井揭露的岩层剖面是地层学的直接材料。"),
    ],
    "tech.learned_societies": [
        ("tech.experimental_science", "学术社团以交流与复核实验为核心活动。"),
    ],
    "tech.soil_experimentation": [
        ("tech.agronomic_exchange", "土壤实验比较不同农艺的产量差异。"),
        ("tech.experimental_science", "对照试验来自实验科学方法。"),
    ],
    "tech.livestock_breeding": [
        ("tech.pastoral_networks", "畜种改良需要成规模、可追踪系谱的畜群。"),
        ("tech.agronomic_exchange", "选育引入了跨区域交换的优良畜种与经验。"),
    ],
    "tech.wage_contracts": [
        ("tech.guild_apprenticeship", "工资契约取代学徒期满后的行会雇佣关系。"),
        ("tech.political_economy", "政治经济学把劳动作为按价格交易的生产要素。"),
    ],
    "tech.long_term_leases": [
        ("tech.commercial_tenancy", "长期租约是商业租佃在期限与改良投资上的延伸。"),
        ("tech.political_economy", "长期租约鼓励承租人改良土地的经济论证。"),
    ],
    "tech.crop_breeding": [
        ("tech.agricultural_improvement", "系统育种是农业改良运动的核心手段。"),
        ("tech.scientific_classification", "按性状系统选育需要物种与品种分类。"),
    ],
    "tech.cooperative_association": [
        ("tech.political_economy", "合作社以互助经营回应市场经济中的小生产者处境。"),
    ],
    "tech.agricultural_cooperatives": [
        ("tech.cooperative_association", "农业合作社是合作社组织在农村的应用。"),
        ("tech.agricultural_improvement", "合作社集中推广改良农法与共用设施。"),
    ],
    "tech.precision_instruments": [
        ("tech.oceanic_navigation", "六分仪与航海钟为远洋定位而改进。"),
        ("tech.precision_engineering", "精密仪器需要精密加工的刻度与齿轮。"),
    ],
    # Identification nodes must be revealed by the coal deposit itself, so the core
    # history stays outside the coal-identification chain.
    "tech.coal_geology": [
        ("tech.scientific_classification", "按化石与岩性分类地层（威廉·史密斯 1815 年地层图）是识别含煤层位的方法基础。"),
    ],
    "tech.steam_sealing": [
        ("tech.atmospheric_engine", "蒸汽密封要解决大气式蒸汽机汽缸漏气问题。"),
        ("tech.precision_engineering", "汽缸镗削与活塞配合依赖精密工程。"),
    ],
    "tech.canning": [
        ("tech.salt_preservation", "罐藏延续了隔绝腐败的食物保存思路。"),
        ("tech.experimental_science", "阿佩尔的加热密封法来自反复实验（罐头食品 1810）。"),
    ],
    # ---------------------------------------------------------------- steam
    "tech.industrial_coal_mining": [
        ("tech.coal_mining", "工业采煤是竖井煤矿的规模化。"),
        ("tech.steam_pumping", "深部工业煤矿依赖蒸汽抽水排水。"),
    ],
    "tech.coke_smelting": [
        ("tech.blast_furnace", "焦炭炼铁把高炉燃料由木炭改为焦炭（焦炭炼铁 ← 高炉、焦炭）。"),
        ("tech.coal_mining", "炼焦需要稳定供应的矿井煤。"),
    ],
    "tech.thermodynamics": [
        ("tech.experimental_science", "热力学定律来自量热与气体实验。"),
        ("tech.steam_power", "卡诺的热机理论直接分析蒸汽机效率。"),
    ],
    "tech.steam_power": [
        ("tech.atmospheric_engine", "蒸汽动力由大气式蒸汽机改进而来。"),
        ("tech.steam_sealing", "分离冷凝与高压运行都依赖可靠的蒸汽密封。"),
    ],
    "tech.mechanized_agriculture": [
        ("tech.agricultural_improvement", "机械化农业服务于改良后的规模化农场。"),
        ("tech.machine_tools", "农业机械的铁制零件由机床批量加工。"),
    ],
    "tech.industrial_organization": [
        ("tech.guild_organization", "工业组织由行会生产组织转变而来。"),
        ("tech.mechanical_workshops", "机械工坊把工序集中到同一厂房。"),
    ],
    "tech.steam_pumping": [
        ("tech.mine_drainage", "蒸汽抽水替代水轮承担矿井排水。"),
        ("tech.steam_power", "蒸汽抽水使用通用蒸汽动力机。"),
    ],
    "tech.textile_machinery": [
        ("tech.weaving", "纺织机械把手工纺纱与织造的动作机械化（动力织机 ← 飞梭）。"),
        ("tech.mechanical_workshops", "纺纱机与织机的齿轮、锭子由机械工坊制造。"),
    ],
    "tech.machine_tools": [
        ("tech.mechanical_workshops", "机床由机械工坊的车削与镗削工具发展而来（全金属螺纹车床 1800）。"),
    ],
    "tech.rail_logistics": [
        ("tech.steam_power", "蒸汽机车是铁路运输的牵引动力。"),
        ("tech.coke_smelting", "铁轨与车轮需要焦炭冶炼提供的大量钢铁。"),
    ],
    "tech.mechanical_threshing": [
        ("tech.mechanized_agriculture", "机械脱粒是农业机械化的一部分。"),
    ],
    "tech.factory_system": [
        ("tech.industrial_organization", "工厂制把工业组织固定为集中厂房与工时纪律。"),
        ("tech.textile_machinery", "最早的工厂是集中安装纺织机械的纺纱厂。"),
    ],
    "tech.mechanized_printing": [
        ("tech.screw_press_printing", "机械印刷由螺旋压印机发展而来。"),
        ("tech.steam_power", "滚筒印刷机由蒸汽动力驱动（1814 年蒸汽印刷机）。"),
    ],
    "tech.industrial_statistics": [
        ("tech.factory_system", "工业统计以工厂产量与工时记录为对象。"),
        ("tech.probability_statistics", "工业统计应用概率与统计方法。"),
    ],
    "tech.interchangeable_parts": [
        ("tech.machine_tools", "互换零件要求机床稳定加工同一公差（互换性零件 ← 全金属螺纹车床）。"),
    ],
    "tech.labor_organization": [
        ("tech.factory_system", "劳工组织在集中工厂中形成。"),
        ("tech.wage_contracts", "工会以集体谈判工资契约为核心诉求。"),
    ],
    "tech.assembly_line": [
        ("tech.interchangeable_parts", "流水线依赖可直接装配的互换零件。"),
        ("tech.factory_system", "流水线是工厂内部工序的重新排布。"),
    ],
    "tech.worker_cooperatives": [
        ("tech.cooperative_association", "工人合作工场沿用合作社的共有与分配规则。"),
        ("tech.factory_system", "工人合作工场以工厂生产为对象。"),
    ],
    # ---------------------------------------------------------------- electrical
    "tech.synthetic_fertilizer": [
        ("tech.fertilizer_processing", "合成肥料接续肥料加工的施肥体系。"),
        ("tech.industrial_chemistry", "合成氨需要高温高压的工业化学工艺（哈伯法 1909）。"),
    ],
    "tech.electrification": [
        ("tech.electric_generation", "电气化以发电机稳定供电为前提。"),
    ],
    "tech.public_education": [
        ("tech.mechanized_printing", "普及教育依赖廉价批量印刷的课本。"),
        ("tech.state_bureaucracy", "义务教育由国家行政统一推行。"),
    ],
    "tech.mass_production": [
        ("tech.assembly_line", "大规模生产以流水线组织为核心。"),
        ("tech.electric_motors", "单机电动机驱动使流水线可以灵活布置（流水线 ← 输送带、发电机）。"),
    ],
    "tech.petroleum_extraction": [
        ("tech.geological_prospecting", "找油依赖地质勘探。"),
        ("tech.steam_pumping", "早期油井用蒸汽机带动顿钻与抽油（德雷克油井 1859）。"),
    ],
    "tech.internal_combustion": [
        ("tech.petroleum_refining", "内燃机以石油炼制的轻质燃料为能源。"),
        ("tech.machine_tools", "汽缸、曲轴需要机床精密加工。"),
    ],
    "tech.modern_medicine": [
        ("tech.public_health", "现代医学在公共卫生的疫病调查基础上发展。"),
        ("tech.microbiology", "病菌学说是消毒、疫苗与抗菌治疗的理论基础。"),
    ],
    "tech.radio": [
        ("tech.electromagnetic_induction", "无线电基于电磁感应与电磁波理论。"),
        ("tech.electrification", "电子管与发射机需要稳定的电力供应（真空管 ← 白炽灯、发电机）。"),
    ],
    "tech.motorized_agriculture": [
        ("tech.mechanical_reaping", "机动农业把机械收割机改由拖拉机牵引。"),
        ("tech.internal_combustion", "拖拉机以内燃机为动力。"),
    ],
    "tech.corporate_management": [
        ("tech.managerial_hierarchy", "公司管理建立在职业经理层级之上。"),
        ("tech.industrial_statistics", "公司管理依靠产量与成本统计决策。"),
    ],
    "tech.cold_chain": [
        ("tech.refrigeration", "冷链以机械制冷为核心设备。"),
        ("tech.rail_logistics", "冷藏车厢把冷库连成运输链（冷链 ← 制冷技术、冷藏车厢）。"),
    ],
    # ---------------------------------------------------------------- atomic
    "tech.advanced_metallurgy": [
        ("tech.coke_smelting", "先进冶金建立在大规模钢铁冶炼之上。"),
        ("tech.electrochemistry", "电解精炼与合金成分控制来自电化学。"),
    ],
    "tech.nuclear_fission": [
        ("tech.industrial_research", "核裂变的发现来自工业研究体系支撑的原子物理实验。"),
        ("tech.electrochemistry", "铀的提纯与分离依赖电化学工艺。"),
    ],
    "tech.deep_geophysics": [
        ("tech.geological_prospecting", "深层地球物理延伸地质勘探的地下探测。"),
        ("tech.electromagnetic_induction", "电法与磁法勘探以电磁感应为原理。"),
    ],
    "tech.operations_research": [
        ("tech.industrial_quality_control", "运筹学由工业质量控制中的统计优化发展而来。"),
    ],
    "tech.petrochemical_industry": [
        ("tech.petroleum_refining", "石油化工以炼厂馏分为原料。"),
        ("tech.industrial_chemistry", "裂解、合成等单元操作来自工业化学。"),
    ],
    "tech.industrial_agronomy": [
        ("tech.motorized_agriculture", "工业农学以拖拉机化的农场为作业对象。"),
        ("tech.synthetic_fertilizer", "化肥投入是工业农学增产的核心。"),
        ("tech.crop_breeding", "高产品种来自系统育种（绿色革命 ← 矮秆品种、合成氨）。"),
    ],
    "tech.national_laboratories": [
        ("tech.industrial_research", "国家实验室把工业研究体系提升为国家级大科学。"),
        ("tech.nuclear_fission", "国家实验室最初围绕核物理与核工程建立。"),
    ],
    "tech.mechanized_mining": [
        ("tech.industrial_coal_mining", "机械化采矿承接工业采煤的深井体系。"),
        ("tech.electric_motors", "截煤机、电铲与运输机由电动机驱动。"),
    ],
    "tech.nuclear_energy": [
        ("tech.nuclear_fission", "核能利用可控链式裂变。"),
        ("tech.electric_generation", "核电站以汽轮发电机组输出电力。"),
    ],
    "tech.electronic_control": [
        ("tech.radio", "电子控制以电子管/晶体管放大与反馈电路为核心。"),
    ],
    "tech.global_logistics": [
        ("tech.rail_logistics", "全球物流把铁路与港口联运组织起来。"),
        ("tech.internal_combustion", "卡车与柴油船使集装箱联运成为可能（集装箱运输 1956）。"),
    ],
    "tech.state_enterprises": [
        ("tech.corporate_management", "国营企业沿用现代公司的管理结构。"),
        ("tech.state_bureaucracy", "国营企业由国家行政直接出资与任命。"),
    ],
    "tech.synthetic_fiber_engineering": [
        ("tech.synthetic_materials", "尼龙、涤纶是高分子合成材料（尼龙 1935）。"),
        ("tech.textile_machinery", "合成纤维沿用纺织机械纺丝织造。"),
    ],
    "tech.systems_engineering": [
        ("tech.operations_research", "系统工程由运筹学的整体优化方法发展而来。"),
        ("tech.electronic_control", "大型系统依赖电子控制与反馈。"),
    ],
    # ---------------------------------------------------------------- information
    "tech.information_theory": [
        ("tech.digital_computing", "信息论与数字计算共同奠定编码与处理基础。"),
        ("tech.telecommunications", "香农信息论直接研究电信信道容量。"),
    ],
    "tech.knowledge_economy": [
        ("tech.digital_computing", "知识经济以计算机处理信息为生产手段。"),
        ("tech.public_education", "知识经济依赖普及教育培养的知识劳动者。"),
    ],
    "tech.networked_computing": [
        ("tech.software_engineering", "网络协议与服务需要软件工程。"),
        ("tech.telecommunications", "计算机网络以电信线路为物理通道。"),
        ("tech.semiconductor_manufacturing", "路由与终端设备依赖半导体芯片。"),
    ],
    "tech.biotechnology": [
        ("tech.molecular_biology", "生物技术直接操作分子生物学揭示的基因。"),
        ("tech.modern_medicine", "早期生物技术产品首先是药物与疫苗。"),
    ],
    "tech.digital_marketplaces": [
        ("tech.networked_computing", "数字市场运行在计算机网络上。"),
        ("tech.consumer_credit", "网上购物依赖信用卡等消费信贷结算。"),
    ],
    "tech.numerical_weather_prediction": [
        ("tech.digital_computing", "数值天气预报需要电子计算机求解大气方程（1950 ← 电子计算机）。"),
        ("tech.probability_statistics", "观测资料同化与预报检验依赖统计方法。"),
    ],
    "tech.automated_logistics": [
        ("tech.global_logistics", "自动化物流升级既有的全球联运网络。"),
        ("tech.digital_control", "自动化港口与仓储依赖数字控制。"),
    ],
    "tech.precision_irrigation": [
        ("tech.hydraulic_engineering", "精准灌溉沿用水利工程的输配水系统。"),
        ("tech.sensor_networks", "按墒情精确配水依赖土壤传感器网络。"),
    ],
    "tech.geographic_information_systems": [
        ("tech.cartography", "地理信息系统把地图学的空间表达数字化。"),
        ("tech.digital_computing", "空间数据的存储与分析需要计算机（GIS 1963）。"),
    ],
    "tech.highland_precision_agriculture": [
        ("tech.precision_agriculture", "高地精准农业是精准农业在山地的专门化。"),
        ("tech.geographic_information_systems", "坡度、朝向与小气候制图依赖地理信息系统。"),
    ],
    "tech.satellite_observation": [
        ("tech.telecommunications", "卫星观测依赖星地无线电遥测链路。"),
        ("tech.digital_computing", "卫星轨道计算与图像处理需要计算机。"),
    ],
    "tech.mineral_spectral_survey": [
        ("tech.satellite_observation", "光谱遥感以卫星平台获取影像。"),
        ("tech.deep_geophysics", "矿物光谱判读需要地球物理的成矿认识。"),
    ],
    "tech.sensor_networks": [
        ("tech.electronic_control", "传感器网络由电子控制的测量回路组成。"),
        ("tech.semiconductor_manufacturing", "廉价传感节点依赖半导体芯片。"),
    ],
    # ---------------------------------------------------------------- intelligent
    "tech.machine_learning": [
        ("tech.networked_computing", "机器学习依赖网络汇聚的大数据与算力（深度学习 ← 大数据、GPU）。"),
        ("tech.information_theory", "学习算法以信息论与统计推断为理论基础。"),
    ],
    "tech.automated_agriculture": [
        ("tech.precision_agriculture", "自动化农业在精准农业的数据与作业体系上运行。"),
        ("tech.autonomous_systems", "无人农机依赖自主系统。"),
    ],
    "tech.robotic_manufacturing": [
        ("tech.digital_control", "工业机器人以数字控制为运动基础（工业机器人 ← 数值控制）。"),
        ("tech.human_machine_collaboration", "智能工厂中的机器人与工人协作作业。"),
    ],
    "tech.autonomous_mining": [
        ("tech.mechanized_mining", "自主采矿是机械化矿山的无人化。"),
        ("tech.autonomous_systems", "无人矿卡与钻机依赖自主系统。"),
    ],
    "tech.smart_grid": [
        ("tech.electric_grid", "智能电网改造既有输配电网（智能电网 ← 电网、微处理器、互联网）。"),
        ("tech.networked_computing", "分布式计量与调度依赖计算机网络。"),
    ],
    "tech.algorithmic_governance": [
        ("tech.machine_learning", "算法治理以机器学习模型辅助公共决策。"),
        ("tech.knowledge_economy", "算法治理面向知识经济下的公共服务。"),
    ],
    "tech.distributed_intelligence": [
        ("tech.networked_computing", "分布式智能运行在计算机网络上。"),
        ("tech.machine_learning", "各节点的智能来自机器学习模型。"),
    ],
    "tech.intelligent_breeding": [
        ("tech.bioinformatics", "智能育种依赖基因组数据分析。"),
        ("tech.machine_learning", "基因组选择模型来自机器学习。"),
    ],
    "tech.autonomous_logistics": [
        ("tech.automated_logistics", "自主物流在自动化物流上去掉人工调度。"),
        ("tech.autonomous_systems", "无人船舶与车辆依赖自主系统。"),
    ],
    "tech.scientific_agents": [
        ("tech.machine_learning", "智能科学代理以机器学习模型提出与筛选假设。"),
        ("tech.open_science_networks", "科学代理从开放科学网络获取数据与文献。"),
    ],
    "tech.autonomous_forestry_operations": [
        ("tech.autonomous_systems", "无人林业机械依赖自主系统。"),
        ("tech.satellite_observation", "林分监测与采伐规划依赖卫星观测。"),
    ],
    "tech.human_machine_cogovernance": [
        ("tech.knowledge_economy", "人机共治面向知识经济的组织形态。"),
        ("tech.machine_learning", "共治中的机器一方以机器学习模型参与决策。"),
    ],
    "tech.adaptive_irrigation": [
        ("tech.precision_irrigation", "自适应灌溉在精准灌溉上实现闭环自调。"),
        ("tech.autonomous_systems", "闭环配水依赖自主控制系统。"),
    ],
    "tech.autonomous_labor_coordination": [
        ("tech.algorithmic_management", "自主劳动协调由算法管理的派工系统发展而来。"),
        ("tech.autonomous_systems", "协调对象包括自主运行的机器。"),
    ],
}

REVEAL_RESTORE = {
    "tech.coal_geology": ({"kind": 1.0, "id": "resource.coal", "value": 1.0},
                          "煤层地质由国家有效观察范围内的煤揭示"),
}

FAMILY = {
    "tech.estate_cereal_management": "branch.land_institutions",
    "tech.refrigeration": "backbone.food_storage",
    "tech.cold_chain": "backbone.food_storage",
    "tech.hydraulic_engineering": "branch.construction_materials",
}

DELETED_NODES = {"tech.method.pastoral_council_tent": "tech.pastoral_route_memory"}
BUILDING_MOVES = {"pastoral_council_tent": "tech.pastoral_route_memory"}

NEW_NODES = [
    {
        "id": "tech.reinforced_concrete",
        "display_name": "钢筋混凝土",
        "era_id": "steam",
        "domain_id": "engineering",
        "branch_family_id": "branch.construction_materials",
        "node_role": "production_system",
        "effect_profile": "materials",
        "secondary_route_tags": ["route.material.stone", "route.material.iron"],
        "template": "tech.hydraulic_engineering",
        "prerequisites": [
            ("tech.hydraulic_engineering", "钢筋混凝土以水硬性水泥为胶结料（钢筋混凝土 1867 ← 波特兰水泥）。"),
            ("tech.coke_smelting", "受拉钢筋来自焦炭冶炼提供的廉价钢材。"),
        ],
        "buildings": ["concrete_plant"],
        "opportunity_cost": "占用工程研究预算，混凝土厂需要持续的水泥与钢筋投入。",
        "reveal_summary": "完成水利工程与焦炭冶炼后，工程界开始尝试把钢筋埋入水泥。",
    },
    {
        "id": "tech.industrial_canning",
        "display_name": "罐头工业化",
        "era_id": "steam",
        "domain_id": "engineering",
        "branch_family_id": "backbone.food_storage",
        "node_role": "production_system",
        "effect_profile": "food",
        "secondary_route_tags": ["route.craft.storage", "route.craft.steam"],
        "template": "tech.canning",
        "prerequisites": [
            ("tech.canning", "罐头工业化把罐藏工艺搬进工厂（罐头工业化 ← 罐头食品）。"),
            ("tech.steam_power", "蒸汽杀菌锅与制罐机由蒸汽动力驱动。"),
        ],
        "buildings": ["canned_fish_plant"],
        "opportunity_cost": "占用工程研究预算，罐头厂依赖稳定的渔获与包装材料供应。",
        "reveal_summary": "罐藏食品需求扩大后，作坊开始改用蒸汽杀菌与机械制罐。",
    },
    {
        "id": "tech.manufactory_system",
        "display_name": "手工工场",
        "era_id": "exploration",
        "domain_id": "society",
        "branch_family_id": "branch.labor_management",
        "node_role": "institution",
        "effect_profile": "institution",
        "secondary_route_tags": ["route.institution.guild", "route.craft.factory"],
        "template": "tech.guild_apprenticeship",
        "prerequisites": [
            ("tech.guild_apprenticeship", "工场集中雇用出师的行会工匠，按工序分工。"),
            ("tech.mercantile_networks", "商人资本为工场垫付原料并包销产品（分散/集中手工工场）。"),
        ],
        "buildings": [],
        "opportunity_cost": "占用社会研究预算，工场需要稳定的原料供应与商人资本。",
        "reveal_summary": "行会作坊接到远程商人的大宗订单后，开始把工匠集中到同一工场分工生产。",
    },
    # --- commerce & finance continuity (polytech: 纸币/汇票 → 保险 → 公司法 → 中央银行 → 信用卡)
    {
        "id": "tech.commodity_money", "display_name": "商品货币与集市", "era_id": "agrarian",
        "domain_id": "society", "branch_family_id": "branch.commerce_finance",
        "node_role": "institution", "effect_profile": "institution",
        "secondary_route_tags": ["route.institution.market", "route.trade.exchange"],
        "template": "tech.market_institutions",
        "prerequisites": [
            ("tech.early_trade", "集市把零散的以物易物固定为定期交易。"),
            ("tech.permanent_settlements", "定期集市依托长期聚落形成。"),
        ],
        "modifiers": [("country.trade.capacity_factor", 0.05, "国内贸易容量", "全社会贸易能力",
                       "谷物、贝币等商品货币降低了以物易物的撮合成本。")],
        "opportunity_cost": "占用社会研究预算，推迟专业生产路线。",
        "reveal_summary": "聚落之间的交换频繁后，人们开始约定集市日与通用交换物。",
    },
    {
        "id": "tech.bills_of_exchange", "display_name": "汇票与票据", "era_id": "empire",
        "domain_id": "society", "branch_family_id": "branch.commerce_finance",
        "node_role": "institution", "effect_profile": "institution",
        "secondary_route_tags": ["route.institution.market", "route.trade.exchange"],
        "template": "tech.market_institutions",
        "prerequisites": [
            ("tech.currency", "汇票以统一铸币计价兑付。"),
            ("tech.market_institutions", "票据在既有市场制度中流通与背书。"),
        ],
        "modifiers": [("country.trade.speed_factor", 0.05, "全社会贸易运输速度", "全社会贸易能力",
                       "远程结算不再需要押运现钱，商路周转加快（汇票与可转让票据 1200）。")],
        "opportunity_cost": "占用社会研究预算，推迟庄园与行会路线。",
        "reveal_summary": "远途商人厌倦押运铸币，开始用书面凭证在异地兑付。",
    },
    {
        "id": "tech.actuarial_insurance", "display_name": "保险与精算", "era_id": "enlightenment",
        "domain_id": "society", "branch_family_id": "branch.commerce_finance",
        "node_role": "institution", "effect_profile": "institution",
        "secondary_route_tags": ["route.institution.market", "route.trade.exchange"],
        "template": "tech.chartered_companies",
        "prerequisites": [
            ("tech.chartered_companies", "海运保险最早为特许商社的远洋货物承保。"),
            ("tech.probability_statistics", "精算以概率与死亡率统计定价风险（保险精算 1762）。"),
        ],
        "modifiers": [("country.trade.capacity_factor", 0.08, "国内贸易容量", "全社会贸易能力",
                       "风险可以定价与分摊后，商人愿意承运更多货物。")],
        "opportunity_cost": "占用社会研究预算，推迟工业路线。",
        "reveal_summary": "商社频繁遭遇海损后，开始按统计出的损失率集资互保。",
    },
    {
        "id": "tech.limited_liability", "display_name": "有限责任公司", "era_id": "steam",
        "domain_id": "society", "branch_family_id": "branch.commerce_finance",
        "node_role": "institution", "effect_profile": "institution",
        "secondary_route_tags": ["route.institution.market", "route.craft.factory"],
        "template": "tech.chartered_companies",
        "prerequisites": [
            ("tech.actuarial_insurance", "有限责任建立在可以量化与分摊的商业风险之上。"),
            ("tech.industrial_organization", "工业企业需要向众多股东募集长期资本（公司法与有限责任 1856）。"),
        ],
        "modifiers": [("country.trade.capacity_factor", 0.08, "国内贸易容量", "全社会贸易能力",
                       "股份募资扩大了商号与运输企业的资本规模。")],
        "opportunity_cost": "占用社会研究预算，推迟工业技术路线。",
        "reveal_summary": "工厂与铁路所需资本超出合伙人财力，立法开始限定股东责任。",
    },
    {
        "id": "tech.central_banking", "display_name": "中央银行体系", "era_id": "electrical",
        "domain_id": "society", "branch_family_id": "branch.commerce_finance",
        "node_role": "institution", "effect_profile": "institution",
        "secondary_route_tags": ["route.institution.market", "route.trade.exchange"],
        "template": "tech.corporate_management",
        "prerequisites": [
            ("tech.limited_liability", "中央银行监管的是由股份公司组成的银行体系。"),
            ("tech.corporate_management", "统一清算依赖现代公司的账务与报表制度（中央银行体系 1913）。"),
        ],
        "modifiers": [("country.trade.speed_factor", 0.06, "全社会贸易运输速度", "全社会贸易能力",
                       "统一清算与最后贷款人减少了结算延误与挤兑。")],
        "opportunity_cost": "占用社会研究预算，推迟电气工业路线。",
        "reveal_summary": "银行挤兑反复冲击市场后，国家开始设立统一发行与清算的银行。",
    },
    {
        "id": "tech.consumer_credit", "display_name": "消费信贷", "era_id": "atomic",
        "domain_id": "society", "branch_family_id": "branch.commerce_finance",
        "node_role": "institution", "effect_profile": "institution",
        "secondary_route_tags": ["route.institution.market", "route.trade.exchange"],
        "template": "tech.corporate_management",
        "prerequisites": [
            ("tech.central_banking", "消费信贷依托中央银行管理下的银行信用。"),
            ("tech.mass_production", "分期付款面向大规模生产的耐用消费品（信用卡 1950）。"),
        ],
        "modifiers": [("country.household.consumption_factor", 0.04, "居民消费", "居民消费",
                       "分期付款让家庭提前购买耐用消费品。")],
        "opportunity_cost": "占用社会研究预算，推迟原子工业路线。",
        "reveal_summary": "耐用消费品普及后，商店与银行开始向家庭提供分期付款。",
    },
    # --- natural history continuity (polytech: 病菌学说 1861 → 孟德尔再发现 1900 → DNA 1953)
    {
        "id": "tech.microbiology", "display_name": "微生物学", "era_id": "steam",
        "domain_id": "science", "branch_family_id": "branch.natural_history",
        "node_role": "handling", "effect_profile": "science",
        "secondary_route_tags": ["route.craft.experimental", "route.craft.storage"],
        "template": "tech.scientific_classification",
        "prerequisites": [
            ("tech.scientific_classification", "微生物学把分类方法延伸到显微镜下的生物。"),
            ("tech.experimental_science", "巴斯德的曲颈瓶实验否定了自然发生说（病菌学说 1861）。"),
        ],
        "modifiers": [("country.output.family.staple_preparation_factor", 0.12, "主粮加工", "生产家族产出",
                       "控制发酵与杀菌减少了主粮加工中的腐败损耗。", "building_family",
                       "staple_preparation")],
        "opportunity_cost": "占用科学研究预算，推迟蒸汽工业路线。",
        "reveal_summary": "酿造与食品反复腐坏后，学者开始用显微镜追查其中的微小生物。",
    },
    {
        "id": "tech.genetics", "display_name": "遗传学", "era_id": "electrical",
        "domain_id": "science", "branch_family_id": "branch.natural_history",
        "node_role": "handling", "effect_profile": "science",
        "secondary_route_tags": ["route.crop.general", "route.craft.experimental"],
        "template": "tech.crop_breeding",
        "prerequisites": [
            ("tech.microbiology", "遗传学沿用微生物学的显微与细胞观察方法。"),
            ("tech.crop_breeding", "孟德尔定律的再发现直接服务于系统育种（1900）。"),
        ],
        "modifiers": [("country.output.agriculture_factor", 0.06, "农业部门产出", "部门产出",
                       "按遗传规律选配亲本提高了作物与牲畜的产量。")],
        "opportunity_cost": "占用科学研究预算，推迟电气工业路线。",
        "reveal_summary": "育种者发现性状按固定比例分离，开始寻找背后的遗传规律。",
    },
    {
        "id": "tech.molecular_biology", "display_name": "分子生物学", "era_id": "atomic",
        "domain_id": "science", "branch_family_id": "branch.natural_history",
        "node_role": "handling", "effect_profile": "science",
        "secondary_route_tags": ["route.crop.biotechnology", "route.institution.laboratory"],
        "template": "tech.biotechnology",
        "prerequisites": [
            ("tech.genetics", "分子生物学寻找遗传因子的化学实体。"),
            ("tech.industrial_research", "X 射线衍射等大型实验依赖工业研究体系（DNA 双螺旋 1953）。"),
        ],
        "modifiers": [("country.research.agriculture_efficiency", 0.06, "农业领域研究效率", "研究效率",
                       "在分子层面理解遗传加快了农业与医药研究。")],
        "opportunity_cost": "占用科学研究预算，推迟原子工业路线。",
        "reveal_summary": "遗传学进入实验室后，研究者开始追问基因由什么分子构成。",
    },
]

TECH_ID_IN_TEXT = re.compile(r"tech\.[a-z0-9_.]+")


def humanize(text: str, model: Model) -> str:
    def repl(match):
        tech = match.group(0).rstrip(".")
        node = model.node.get(tech)
        return "「%s」" % node["display_name"] if node else match.group(0)
    return TECH_ID_IN_TEXT.sub(repl, text)


def collect_atoms(cond, techs: list, signals: list) -> None:
    if not cond:
        return
    if "kind" in cond:
        (techs if int(cond["kind"]) == 0 else signals).append(cond["id"])
        return
    for child in cond.get("children", []):
        collect_atoms(child, techs, signals)
    if "child" in cond:
        collect_atoms(cond["child"], techs, signals)


def prune_condition(cond, drop_tech: set, drop_signal: set):
    """Removes atoms; returns None when the condition collapses."""
    if not cond:
        return None
    if "kind" in cond:
        kind = int(cond["kind"])
        if (kind == 0 and cond["id"] in drop_tech) or (kind == 1 and cond["id"] in drop_signal):
            return None
        return cond
    operator = int(cond.get("operator", -1))
    children = [prune_condition(c, drop_tech, drop_signal) for c in cond.get("children", [])]
    children = [c for c in children if c is not None]
    if operator == 1:  # ALL_OF
        if not children:
            return None
        if len(children) == 1:
            return children[0]
        out = dict(cond)
        out["children"] = children
        return out
    if operator == 2:  # ANY_OF
        if len(children) != len(cond.get("children", [])):
            # an alternative disappeared because it is now implied; the whole ANY_OF is satisfied
            return {"__satisfied__": True}
        out = dict(cond)
        out["children"] = children
        return out
    return cond


def strip_satisfied(cond):
    if not cond or "kind" in cond:
        return cond
    if cond.get("__satisfied__"):
        return None
    children = [strip_satisfied(c) for c in cond.get("children", [])]
    children = [c for c in children if c is not None]
    if not children:
        return None
    if int(cond.get("operator", -1)) == 1 and len(children) == 1:
        return children[0]
    out = dict(cond)
    out["children"] = children
    return out


def ancestors(model: Model, tech: str) -> set:
    return set(model.closure(tech)) - {tech}


RUNTIME_CONSUMERS = {
    "country.trade.capacity_factor": "NativeEconomyRuntime::capture_country_epoch",
    "country.trade.speed_factor": "NativeEconomyRuntime::capture_country_epoch",
    "country.household.consumption_factor": "NativeEconomyRuntime::family_consumption_factor_q16",
    "country.output.agriculture_factor": "NativeEconomyRuntime::refresh_building_modifier_factors",
    "country.research.agriculture_efficiency": "NativeCountryRuntime::process_research_day",
}


def modifier_term(spec: tuple) -> dict:
    stat, value, subject_name, effect_class, rationale = spec[:5]
    subject_kind = spec[5] if len(spec) > 5 else ("country" if stat.startswith("country.output.")
                                                  else "society")
    subject_id = spec[6] if len(spec) > 6 else stat
    consumer = RUNTIME_CONSUMERS.get(stat, "NativeEconomyRuntime::refresh_building_modifier_factors")
    return {"stat": stat, "operation": 0.0, "value": value, "subject_kind": subject_kind,
            "subject_id": subject_id, "subject_display_name": subject_name,
            "effect_class": effect_class, "effect_rationale": rationale,
            "implementation_status": "runtime_consumed", "runtime_consumer": consumer}


def new_node(spec: dict, model: Model) -> dict:
    template = copy.deepcopy(model.node[spec["template"]])
    era = spec["era_id"]
    era_row = next(e for e in model.network["eras"] if e["id"] == era)
    era_costs = sorted(n["cost_points"] for n in model.nodes if n["era_id"] == era
                       and not n.get("is_milestone"))
    prereqs = [p for p, _ in spec["prerequisites"]]
    families = sorted({model.node[p]["branch_family_id"] for p in prereqs})
    node = {
        "id": spec["id"],
        "display_name": spec["display_name"],
        "era_id": era,
        "domain_id": spec["domain_id"],
        "cost_points": float(era_costs[len(era_costs) // 2]),
        "layout_order": max(float(model.node[p]["layout_order"]) for p in prereqs) + 0.5,
        "network_role": "branch",
        "anchor_kind": "branch",
        "node_role": spec["node_role"],
        "effect_profile": spec.get("effect_profile", template.get("effect_profile", "tools")),
        "secondary_route_tags": spec["secondary_route_tags"],
        "hard_prerequisite_ids": prereqs,
        "reveal_condition": {},
        "is_milestone": False,
        "is_era_key": False,
        "is_starting": False,
        "is_starter_eligible": False,
        "starter_capability_tags": [],
        "modifier_terms": [modifier_term(m) for m in spec.get("modifiers", [])],
        "expected_bindings": [],
        "content_effects": [],
        "effect_summary": "",
        "opportunity_cost": spec["opportunity_cost"],
        "application_target_ids": [],
        "terminal_reason": "",
        "branch_family_id": spec["branch_family_id"],
        "era_entry_milestone_id": era_row["entry_milestone_id"],
        "reveal_category": "composite_science",
        "reveal_summary": spec["reveal_summary"],
        "branch_successor_ids": [],
        "prerequisite_rationales": [r for _, r in spec["prerequisites"]],
        "branch_successor_rationales": [],
        "application_target_rationales": [],
        "effect_design_review": {"status": "reviewed", "numeric_effect_policy": "explicit_only",
                                 "non_numeric_consumers_allowed": True},
        "support_buildings": [],
        "research_routes": [],
        "route_exemption_reason": "不可替代知识已经由可见硬前置完整表达。",
        "reveal_template_reason": "",
        "topology_review": {"role": "convergence",
                            "rationale": "该节点汇合两条不可替代的知识链，并直接开放对应的生产设施。",
                            "expected_hard_family_ids": families},
        "building_unlock_review": {"policy": "single" if spec.get("buildings") else "support_only",
                                   "rationale": "本科技直接开放与其名称对应、完成即可建设的生产设施。"
                                   if spec.get("buildings") else
                                   "本科技不直接开放建筑，以制度或知识效果推动后续路线。"},
        "knowledge_basis": {"required_ids": prereqs, "alternative_groups": [], "exemption_reason": ""},
    }
    return node


def topo_sort(model: Model) -> list:
    by_era = defaultdict(list)
    for node in model.nodes:
        by_era[node["era_id"]].append(node)
    candidates = {}
    for era in model.network["eras"]:
        for candidate in era["milestone_candidate_ids"]:
            candidates[candidate] = era["milestone_id"]
    ordered = []
    for era in ERA_IDS:
        nodes = by_era[era]
        ids = {n["id"] for n in nodes}
        preds = defaultdict(set)
        soft = defaultdict(set)
        for node in nodes:
            deps = list(node["hard_prerequisite_ids"])
            if node.get("is_milestone"):
                deps += [c for c, m in candidates.items() if m == node["id"]]
            preds[node["id"]] = {d for d in deps if d in ids}
            for route in node.get("research_routes", []):
                techs: list = []
                collect_atoms(route["condition"], techs, [])
                soft[node["id"]] |= {t for t in techs if t in ids}
        position = {n["id"]: i for i, n in enumerate(nodes)}
        remaining = {n["id"]: n for n in nodes}
        milestones = [n["id"] for n in nodes if n.get("is_milestone")]
        placed: set = set()
        while remaining:
            ready = [i for i in remaining if preds[i] <= placed and soft[i] <= placed | set(
                x for x in soft[i] if x not in remaining) and i not in milestones]
            if not ready:
                ready = [i for i in remaining if preds[i] <= placed and i not in milestones]
            if not ready:
                ready = [i for i in remaining if preds[i] <= placed]
            if not ready:
                raise SystemExit("cycle inside era %s: %s" % (era, sorted(remaining)))
            ready.sort(key=lambda i: position[i])
            chosen = ready[0]
            ordered.append(remaining.pop(chosen))
            placed.add(chosen)
    return ordered


def _route_name_keys() -> tuple[set, set]:
    source = (NETWORK_PATH.parents[2] / "scripts" / "economy" / "technology_catalog.gd").read_text(
        encoding="utf-8")
    out = []
    for name in ("ROUTE_CATEGORY_NAMES_ZH", "ROUTE_VALUE_NAMES_ZH"):
        begin = source.index("const " + name)
        out.append(set(re.findall(r'"([a-z_]+)"\s*:', source[begin:source.index("}", begin)])))
    return out[0], out[1]


def validate(model: Model) -> list:
    errors = []
    model.invalidate()
    categories, values = _route_name_keys()
    for node in model.nodes:
        for tag in node.get("secondary_route_tags", []):
            parts = tag.split(".")
            if len(parts) != 3 or parts[1] not in categories or parts[2] not in values:
                errors.append("route tag without Chinese name %s %s" % (node["id"], tag))
    for node in model.nodes:
        nid = node["id"]
        era = ERA_INDEX[node["era_id"]]
        hard = node["hard_prerequisite_ids"]
        if len(hard) != len(node["prerequisite_rationales"]):
            errors.append("rationale count %s" % nid)
        for p in hard:
            if p not in model.node:
                errors.append("unknown prereq %s <- %s" % (nid, p))
                continue
            if ERA_INDEX[model.node[p]["era_id"]] > era:
                errors.append("future prereq %s <- %s" % (nid, p))
            if model.node[p].get("is_milestone"):
                errors.append("milestone prereq %s <- %s" % (nid, p))
            if model.order[p] >= model.order[nid]:
                errors.append("not topological %s <- %s" % (nid, p))
        history = ancestors(model, nid)
        implied_signals = set()
        for anc in history:
            s: list = []
            collect_atoms(model.node[anc].get("reveal_condition", {}), [], s)
            implied_signals |= set(s)
        own: list = []
        collect_atoms(node.get("reveal_condition", {}), [], own)
        if era >= 2 and set(own) & implied_signals:
            errors.append("reveal implied %s %s" % (nid, sorted(set(own) & implied_signals)))
        route_techs_all: list = []
        for route in node.get("research_routes", []):
            techs: list = []
            sigs: list = []
            collect_atoms(route["condition"], techs, sigs)
            route_techs_all += techs
            for t in techs:
                if t == nid or t in hard:
                    errors.append("route dup/self %s %s" % (route["id"], t))
                if t not in model.node:
                    errors.append("route unknown %s %s" % (route["id"], t))
                    continue
                if ERA_INDEX[model.node[t]["era_id"]] > era:
                    errors.append("route future %s %s" % (route["id"], t))
                if model.order[t] >= model.order[nid]:
                    errors.append("route order %s %s" % (route["id"], t))
            if not any(t not in history for t in techs) and not any(
                    s not in implied_signals for s in sigs):
                errors.append("route implied %s" % route["id"])
            if set(sigs) & set(own) and nid not in ("tech.coastal_fishing", "tech.freshwater_fishing"):
                errors.append("route reuses reveal %s" % route["id"])
        types = {r["route_type"] for r in node.get("research_routes", [])}
        if len(node.get("research_routes", [])) > 1 and len(types) < 2:
            errors.append("route types %s" % nid)
        kb = node["knowledge_basis"]
        for r in kb.get("required_ids", []):
            if r not in history:
                errors.append("kb required not ancestor %s %s" % (nid, r))
        for group in kb.get("alternative_groups", []):
            for alt in group:
                if alt not in route_techs_all:
                    errors.append("kb alternative not visible %s %s" % (nid, alt))
        if not kb.get("required_ids") and not kb.get("alternative_groups") and not kb.get(
                "exemption_reason"):
            errors.append("kb empty %s" % nid)
        if era >= 2 and not node.get("research_routes") and not node.get(
                "route_exemption_reason", "").strip():
            errors.append("route exemption missing %s" % nid)
        for s in node.get("branch_successor_ids", []):
            if s not in model.node:
                errors.append("successor unknown %s %s" % (nid, s))
            elif model.node[s]["branch_family_id"] != node["branch_family_id"]:
                errors.append("successor cross family %s %s" % (nid, s))
        for t in node.get("application_target_ids", []):
            if t not in model.node:
                errors.append("application unknown %s %s" % (nid, t))
    for era in model.network["eras"]:
        for c in era["milestone_candidate_ids"]:
            if c not in model.node or model.node[c]["era_id"] != era["id"]:
                errors.append("candidate invalid %s" % c)
    return errors


def apply_edits(model: Model, write_files: bool) -> dict:
    stats = defaultdict(int)

    def write_tres(path, key, values):
        if write_files:
            write_tres_array(path, key, values)

    # node set repair
    for building_id, tech in BUILDING_MOVES.items():
        path = model.building_paths[building_id]
        write_tres(path, "technology_tags", [tech])
        write_tres(path, "required_technology_tags", [])
        model.buildings[building_id]["technology_tags"] = [tech]
        model.buildings[building_id]["required_technology_tags"] = []
    for spec in NEW_NODES:
        if spec["id"] in model.node:
            model.node[spec["id"]]["secondary_route_tags"] = list(spec["secondary_route_tags"])
            continue
        node = new_node(spec, model)
        model.nodes.append(node)
        model.invalidate()
        for building_id in spec.get("buildings", []):
            path = model.building_paths[building_id]
            write_tres(path, "technology_tags", [spec["id"]])
            model.buildings[building_id]["technology_tags"] = [spec["id"]]
        stats["new_nodes"] += 1
    for deleted, heir in DELETED_NODES.items():
        if deleted not in model.node:
            continue
        model.nodes[:] = [n for n in model.nodes if n["id"] != deleted]
        for node in model.nodes:
            if deleted in node["hard_prerequisite_ids"]:
                raise SystemExit("deleted node still has hard successor: %s" % node["id"])
            for key in ("branch_successor_ids", "application_target_ids"):
                if deleted in node.get(key, []):
                    index = node[key].index(deleted)
                    node[key].pop(index)
                    rationale_key = key.replace("_ids", "_rationales")
                    node[rationale_key].pop(index)
        for good_id, row in model.goods.items():
            tags = row.get("technology_tags", [])
            if deleted in tags:
                row["technology_tags"] = [t for t in tags if t != deleted]
                if heir not in row["technology_tags"]:
                    row["technology_tags"].append(heir)
                write_tres(model.good_paths[good_id], "technology_tags", row["technology_tags"])
        model.invalidate()
        stats["deleted_nodes"] += 1
    # family continuity
    for tech, family in FAMILY.items():
        node = model.node[tech]
        if node["branch_family_id"] != family:
            node["branch_family_id"] = family
            node["branch_successor_ids"] = []
            node["branch_successor_rationales"] = []
            for other in model.nodes:
                if tech in other.get("branch_successor_ids", []):
                    index = other["branch_successor_ids"].index(tech)
                    other["branch_successor_ids"].pop(index)
                    other["branch_successor_rationales"].pop(index)
            stats["family_moves"] += 1
    # hard prerequisites
    for tech, edges in EDITS.items():
        node = model.node[tech]
        new_hard = [p for p, _ in edges]
        if node["hard_prerequisite_ids"] != new_hard:
            stats["edited_nodes"] += 1
        node["hard_prerequisite_ids"] = new_hard
        node["prerequisite_rationales"] = [r for _, r in edges]
    model.invalidate()
    for tech, (reveal, summary) in REVEAL_RESTORE.items():
        model.node[tech]["reveal_condition"] = reveal
        model.node[tech]["reveal_summary"] = summary
    # consistency repairs on every node
    for node in model.nodes:
        nid = node["id"]
        hard = set(node["hard_prerequisite_ids"])
        history = ancestors(model, nid)
        implied_signals = set()
        for anc in history:
            s: list = []
            collect_atoms(model.node[anc].get("reveal_condition", {}), [], s)
            implied_signals |= set(s)
        era = ERA_INDEX[node["era_id"]]
        # reveal atoms implied by the core history
        own: list = []
        collect_atoms(node.get("reveal_condition", {}), [], own)
        if era >= 2 and set(own) & implied_signals:
            pruned = prune_condition(node["reveal_condition"], set(), set(own) & implied_signals)
            pruned = strip_satisfied(pruned) if pruned else None
            node["reveal_condition"] = pruned or {}
            if not node["reveal_condition"]:
                node["reveal_summary"] = "核心前置完成后即进入可见研究前沿。"
            stats["reveal_pruned"] += 1
        # routes
        kept_routes = []
        for route in node.get("research_routes", []):
            cond = prune_condition(route["condition"], hard | {nid}, set())
            cond = strip_satisfied(cond) if cond else None
            if cond is None:
                stats["routes_dropped"] += 1
                continue
            techs: list = []
            sigs: list = []
            collect_atoms(cond, techs, sigs)
            if not any(t not in history for t in techs) and not any(
                    s not in implied_signals for s in sigs):
                stats["routes_dropped"] += 1
                continue
            if cond != route["condition"]:
                stats["routes_pruned"] += 1
            route["condition"] = cond
            kept_routes.append(route)
        # keep distinct route types when several routes remain
        if len(kept_routes) > 1 and len({r["route_type"] for r in kept_routes}) < 2:
            kept_routes = kept_routes[:1]
        node["research_routes"] = kept_routes
        if era >= 2 and not kept_routes and not node.get("route_exemption_reason", "").strip():
            node["route_exemption_reason"] = "不可替代知识已经由可见硬前置完整表达。"
        # knowledge basis
        route_techs: list = []
        for route in kept_routes:
            collect_atoms(route["condition"], route_techs, [])
        kb = node["knowledge_basis"]
        if not kb.get("exemption_reason"):
            kb["required_ids"] = [p for p in node["hard_prerequisite_ids"]]
            groups = []
            for group in kb.get("alternative_groups", []):
                group = [a for a in group if a in route_techs and a not in history]
                if group:
                    groups.append(group)
            kb["alternative_groups"] = groups
            if not kb["required_ids"] and not groups:
                if route_techs:
                    kb["alternative_groups"] = [sorted(set(route_techs), key=lambda t: model.order[t])]
        # rationale wording
        node["prerequisite_rationales"] = [humanize(r, model) for r in node["prerequisite_rationales"]]
        for key in ("terminal_reason", "branch_successor_rationales", "application_target_rationales"):
            value = node.get(key)
            if isinstance(value, str):
                node[key] = humanize(value, model)
            elif isinstance(value, list):
                node[key] = [humanize(v, model) for v in value]
    model.nodes[:] = topo_sort(model)
    model.invalidate()
    # route evidence must reference earlier-defined technologies
    for node in model.nodes:
        later = {t for t in model.node if model.order[t] >= model.order[node["id"]]}
        kept = []
        history = ancestors(model, node["id"])
        implied_signals = set()
        for anc in history:
            s: list = []
            collect_atoms(model.node[anc].get("reveal_condition", {}), [], s)
            implied_signals |= set(s)
        for route in node.get("research_routes", []):
            cond = remove_atoms(route["condition"], later)
            if cond is None:
                stats["routes_dropped_order"] += 1
                continue
            techs: list = []
            sigs: list = []
            collect_atoms(cond, techs, sigs)
            if not any(t not in history for t in techs) and not any(
                    s not in implied_signals for s in sigs):
                stats["routes_dropped_implied"] += 1
                continue
            if cond != route["condition"]:
                stats["routes_pruned_order"] += 1
            route["condition"] = cond
            kept.append(route)
        if len(kept) > 1 and len({r["route_type"] for r in kept}) < 2:
            kept = kept[:1]
        node["research_routes"] = kept
        route_techs: list = []
        for route in kept:
            collect_atoms(route["condition"], route_techs, [])
        kb = node["knowledge_basis"]
        kb["alternative_groups"] = [g for g in ([a for a in group if a in route_techs]
                                                for group in kb.get("alternative_groups", [])) if g]
        if ERA_INDEX[node["era_id"]] >= 2 and not kept and not node.get(
                "route_exemption_reason", "").strip():
            node["route_exemption_reason"] = "不可替代知识已经由可见硬前置完整表达。"
    return stats


def remove_atoms(cond, drop_tech: set):
    """Removes technology atoms without treating them as satisfied."""
    if not cond:
        return None
    if "kind" in cond:
        return None if int(cond["kind"]) == 0 and cond["id"] in drop_tech else cond
    children = [remove_atoms(c, drop_tech) for c in cond.get("children", [])]
    children = [c for c in children if c is not None]
    if not children:
        return None
    if len(children) == 1 and int(cond.get("operator", -1)) in (1, 2):
        return children[0]
    out = dict(cond)
    out["children"] = children
    if int(cond.get("operator", -1)) == 3 and int(out.get("value", 1)) > len(children):
        out["value"] = float(len(children))
    return out


def main() -> None:
    apply = "--apply" in sys.argv
    model = Model()
    stats = apply_edits(model, write_files=False)
    errors = validate(model)
    if apply and not errors:
        model = Model()
        stats = apply_edits(model, write_files=True)
        errors = validate(model)
    print(dict(stats))
    print("validation errors:", len(errors))
    for error in errors[:60]:
        print("  ", error)
    if apply and not errors:
        model.network["nodes"] = model.nodes
        dump_json(NETWORK_PATH, model.network)
        print("written", NETWORK_PATH)
    elif apply:
        print("not written: fix validation errors first")


if __name__ == "__main__":
    main()
