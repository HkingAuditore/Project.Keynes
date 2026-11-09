# Technology Unlock Progression Audit

- Reviewed same-output technology edges: `59`
- Reviewed building pairs: `71`
- Identification nodes with direct building unlocks: `0`
- Non-increasing same-family upgrade pairs: `0`
- Result: `PASS`

## Reviewed Relations

| Source | Target | Classification | Shared output building pairs |
|---|---|---|---|
| 农业改良 (`tech.agricultural_improvement`) | 机械化农业 (`tech.mechanized_agriculture`) | `upgrade` | 改良小农场 -> 机械化农场 (grain, vegetables); 改良轮作马铃薯庄园 -> 机械化马铃薯农场 (potatoes) |
| 大气式蒸汽机 (`tech.atmospheric_engine`) | 蒸汽动力 (`tech.steam_power`) | `upgrade` | 大气式蒸汽机工坊 -> 蒸汽机工厂 (steam_engines) |
| 自动化物流 (`tech.automated_logistics`) | 自主物流 (`tech.autonomous_logistics`) | `upgrade` | 自动化港口船舶中心 -> 自主航运调度港 (oceanic_vessels) |
| 罐藏 (`tech.canning`) | 罐头工业化 (`tech.industrial_canning`) | `upgrade` | 罐头工坊 -> 鱼类罐头厂 (canned_fish) |
| 煤矿平硐 (`tech.coal_adit_mining`) | 煤矿开采 (`tech.coal_mining`) | `upgrade` | 煤层平硐 -> 煤矿 (coal) |
| 深层地球物理 (`tech.deep_geophysics`) | 矿物光谱遥感 (`tech.mineral_spectral_survey`) | `upgrade` | 铝土矿 -> 自动化铝土矿 (bauxite) |
| 数字计算 (`tech.digital_computing`) | 软件工程 (`tech.software_engineering`) | `upgrade` | 早期计算机工场 -> 计算机厂 (computers) |
| 数字控制 (`tech.digital_control`) | 机器人制造 (`tech.robotic_manufacturing`) | `upgrade` | 数控发射药厂 -> 智能发射药厂 (modern_propellant) |
| 早期知识机构 (`tech.early_knowledge_institution`) | 洪水历法实践 (`tech.flood_calendar_practice`) | `specialization` | 早期知识机构 -> 洪水历法祭所 (technology_points) |
| 早期知识机构 (`tech.early_knowledge_institution`) | 口述记忆实践 (`tech.oral_memory_practice`) | `specialization` | 早期知识机构 -> 口述记忆圈 (technology_points) |
| 早期知识机构 (`tech.early_knowledge_institution`) | 牧群路线记忆 (`tech.pastoral_route_memory`) | `specialization` | 早期知识机构 -> 牧群路线议事帐 (technology_points) |
| 早期知识机构 (`tech.early_knowledge_institution`) | 物候观察实践 (`tech.phenology_observation`) | `specialization` | 早期知识机构 -> 物候观察棚 (technology_points) |
| 早期知识机构 (`tech.early_knowledge_institution`) | 潮汐与航向记忆 (`tech.tide_observation`) | `specialization` | 早期知识机构 -> 潮汐观察屋 (technology_points) |
| 发电机 (`tech.electric_generation`) | 核能 (`tech.nuclear_energy`) | `specialization` | 燃煤发电厂 -> 核电站 (electricity); 河流水力发电站 -> 核电站 (electricity) |
| 纤维捻制 (`tech.fiber_twisting`) | 毛皮缝制 (`tech.fur_sewing`) | `specialization` | 韧皮裹衣棚 -> 毛皮缝制棚 (clothing) |
| 退水小麦地 (`tech.flood_recession_wheat`) | 旱作小麦田 (`tech.dryland_wheat_cultivation`) | `specialization` | 退水小麦地 -> 旱作保水小麦田 (wheat_grain) |
| 磨制石器 (`tech.ground_stone_tools`) | 砌体建筑 (`tech.masonry`) | `upgrade` | 毛石整理场 -> 采石场 (raw_stone) |
| 行会学徒制 (`tech.guild_apprenticeship`) | 手工工场 (`tech.manufactory_system`) | `upgrade` | 皮革制品小作坊 -> 皮革制品工场 (leather_goods) |
| 火药配制 (`tech.gunpowder_formulation`) | 粒状火药 (`tech.military.corned_powder`) | `upgrade` | 火药坊 -> 火药局 (black_powder) |
| 火药配制 (`tech.gunpowder_formulation`) | 硝田制硝 (`tech.military.nitre_beds`) | `specialization` | 硝石矿 -> 硝田 (saltpeter) |
| 手工纺纱 (`tech.hand_spinning`) | 织造 (`tech.weaving`) | `upgrade` | 家庭纺织坊 -> 家用织机 (cloth) |
| 生皮刮制 (`tech.hide_scraping`) | 毛皮缝制 (`tech.fur_sewing`) | `specialization` | 生皮刮制棚 -> 毛皮缝制棚 (clothing) |
| 狩猎 (`tech.hunting`) | 动物追踪 (`tech.animal_tracking`) | `specialization` | 狩猎营地 -> 小型陷阱线 (fur, game_meat, raw_hide) |
| 工业农学 (`tech.industrial_agronomy`) | 精准农业 (`tech.precision_agriculture`) | `upgrade` | 电气化集约农场 -> 精准农场 (grain, vegetables) |
| 工业化学 (`tech.industrial_chemistry`) | 电化学 (`tech.electrochemistry`) | `specialization` | 化学工场 -> 电化工厂 (industrial_chemicals) |
| 窑烧控制 (`tech.kiln_firing`) | 砌体建筑 (`tech.masonry`) | `upgrade` | 露天黏土坑 -> 黏土坑 (clay); 烧砖窑 -> 制砖厂 (bricks) |
| 玉米园圃 (`tech.maize_garden_horticulture`) | 刀耕火种玉米 (`tech.swidden_maize_cultivation`) | `specialization` | 家庭玉米园圃 -> 刀耕火种玉米地 (corn_grain) |
| 砌体建筑 (`tech.masonry`) | 运河工程 (`tech.canal_engineering`) | `upgrade` | 采石场 -> 石料场 (raw_stone) |
| 砌体建筑 (`tech.masonry`) | 城市水务 (`tech.urban_waterworks`) | `upgrade` | 采石场 -> 规模化采石场 (raw_stone) |
| 机械化采矿 (`tech.mechanized_mining`) | 自主采矿 (`tech.autonomous_mining`) | `upgrade` | 锰矿 -> 智能锰矿 (manganese_ore) |
| 粒状火药 (`tech.military.corned_powder`) | 机械制药 (`tech.military.powder_milling`) | `upgrade` | 火药局 -> 水力火药厂 (black_powder) |
| 无烟火药 (`tech.military.smokeless_powder`) | 连续硝化 (`tech.military.continuous_nitration`) | `upgrade` | 无烟火药厂 -> 连续硝化火药厂 (smokeless_powder) |
| 现代医学 (`tech.modern_medicine`) | 生物技术 (`tech.biotechnology`) | `specialization` | 受控环境药材农场 -> 精准药材农场 (medicinal_herbs) |
| 活字印刷 (`tech.movable_type_printing`) | 螺旋压印 (`tech.screw_press_printing`) | `upgrade` | 活字印刷坊 -> 印刷厂 (printed_materials) |
| 石油开采 (`tech.petroleum_extraction`) | 石油钻探 (`tech.petroleum_drilling`) | `upgrade` | 蒸汽钻井场 -> 油田 (crude_oil) |
| 植物纤维抄纸 (`tech.plant_fiber_papermaking`) | 破布纸 (`tech.rag_paper_making`) | `alternative_method` | 植物纤维抄纸坊 -> 碎布造纸工坊 (paper) |
| 块茎繁育 (`tech.potato_propagation`) | 垄作块茎 (`tech.ridge_tuber_cultivation`) | `specialization` | 家庭块茎试种圃 -> 垄作马铃薯田 (potatoes) |
| 精准农业 (`tech.precision_agriculture`) | 自动化农业 (`tech.automated_agriculture`) | `upgrade` | 精准小麦农场 -> 自动化小麦农场 (wheat_grain); 精准农场 -> 自动化农场 (grain, vegetables) |
| 精准灌溉 (`tech.precision_irrigation`) | 自适应灌溉 (`tech.adaptive_irrigation`) | `upgrade` | 精准稻作农场 -> 自动化稻作农场 (rice_grain) |
| 雨养玉米田 (`tech.rainfed_maize_cultivation`) | 退水玉米地 (`tech.flood_recession_maize`) | `specialization` | 雨养玉米田 -> 退水玉米地 (corn_grain) |
| 雨养小麦田 (`tech.rainfed_wheat_cultivation`) | 退水小麦地 (`tech.flood_recession_wheat`) | `specialization` | 雨养小麦地 -> 退水小麦地 (wheat_grain) |
| 垄作块茎 (`tech.ridge_tuber_cultivation`) | 高地块茎农业 (`tech.highland_tuber_farming`) | `specialization` | 垄作马铃薯田 -> 冷凉高地块茎田 (potatoes) |
| 盐渍保存 (`tech.salt_preservation`) | 太阳蒸发制盐 (`tech.solar_evaporation`) | `alternative_method` | 煮盐灶 -> 盐场 (salt); 煮盐灶 -> 日晒盐田 (salt) |
| 卫星观测 (`tech.satellite_observation`) | 自主林业经营 (`tech.autonomous_forestry_operations`) | `upgrade` | 森林遥感经营站 -> 自主林业经营站 (logs) |
| 学术机构 (`tech.scholarly_academies`) | 特许大学 (`tech.chartered_universities`) | `upgrade` | 古典学院 -> 特许大学 (technology_points); 古典学院 -> 印刷学社 (technology_points) |
| 遮阴香料园 (`tech.spice_shade_gardening`) | 香料栽培 (`tech.spice_cultivation`) | `upgrade` | 林下遮阴香料园 -> 商品香料园 (spices) |
| 地表煤采集 (`tech.surface_coal_collection`) | 煤矿平硐 (`tech.coal_adit_mining`) | `upgrade` | 露头煤采集场 -> 煤层平硐 (coal) |
| 刀耕火种玉米 (`tech.swidden_maize_cultivation`) | 雨养玉米田 (`tech.rainfed_maize_cultivation`) | `alternative_method` | 刀耕火种玉米地 -> 雨养玉米田 (corn_grain) |
| 佃作水田 (`tech.tenant_paddy_management`) | 庄园水田核算 (`tech.estate_paddy_management`) | `alternative_method` | 佃作稻庄 -> 庄园水田 (rice_grain); 稻作农场 -> 庄园水田 (rice_grain); 分成水田 -> 庄园水田 (rice_grain); 佃作水田 -> 庄园水田 (rice_grain) |
| 纺织机械 (`tech.textile_machinery`) | 合成纤维工程 (`tech.synthetic_fiber_engineering`) | `specialization` | 改良家用织机 -> 合成纤维织造厂 (cloth); 蒸汽纺织厂 -> 合成纤维织造厂 (cloth) |
| 手工锯木 (`tech.timber_sawing`) | 森林管理 (`tech.forest_management`) | `specialization` | 锯木场 -> 改良锯木场 (lumber); 伐木场 -> 商营伐木场 (logs) |
| 手工锯木 (`tech.timber_sawing`) | 蒸汽锯木 (`tech.steam_sawmilling`) | `upgrade` | 锯木场 -> 蒸汽锯木厂 (lumber) |
| 手工锯木 (`tech.timber_sawing`) | 水力机械 (`tech.water_power`) | `upgrade` | 锯木场 -> 水力锯木场 (lumber) |
| 旱稻繁育 (`tech.upland_rice_propagation`) | 湿地稻园 (`tech.wetland_rice_gardening`) | `specialization` | 旱稻田 -> 湿地稻园 (rice_grain) |
| 织造 (`tech.weaving`) | 纺织机械 (`tech.textile_machinery`) | `upgrade` | 家用织机 -> 改良家用织机 (cloth); 家用织机 -> 蒸汽纺织厂 (cloth) |
| 湿地稻园 (`tech.wetland_rice_gardening`) | 稻田水位控制 (`tech.rice_water_control`) | `upgrade` | 湿地稻园 -> 畦埂水稻田 (rice_grain) |
| 野生棉铃采集 (`tech.wild_cotton_collection`) | 棉花园圃 (`tech.cotton_gardening`) | `specialization` | 野生棉丛 -> 家庭棉花园圃 (seed_cotton) |
| 野生香料采集 (`tech.wild_spice_collection`) | 遮阴香料园 (`tech.spice_shade_gardening`) | `specialization` | 野生香料林 -> 林下遮阴香料园 (spices) |
| 木版印刷 (`tech.woodblock_printing`) | 活字印刷 (`tech.movable_type_printing`) | `upgrade` | 木版印刷坊 -> 活字印刷坊 (printed_materials) |

## Violations

- None.
