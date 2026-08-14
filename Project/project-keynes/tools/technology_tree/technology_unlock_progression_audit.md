# Technology Unlock Progression Audit

- Reviewed same-output technology edges: `38`
- Reviewed building pairs: `53`
- Identification nodes with direct building unlocks: `0`
- Non-increasing same-family upgrade pairs: `0`
- Result: `PASS`

## Reviewed Relations

| Source | Target | Classification | Shared output building pairs |
|---|---|---|---|
| 大气式蒸汽机 (`tech.atmospheric_engine`) | 蒸汽动力 (`tech.steam_power`) | `upgrade` | 大气式蒸汽机工坊 -> 自动化蒸汽机厂 (steam_engines); 大气式蒸汽机工坊 -> 蒸汽机工厂 (steam_engines) |
| 自动化物流 (`tech.automated_logistics`) | 自主物流 (`tech.autonomous_logistics`) | `upgrade` | 自动化港口船舶中心 -> 自主航运调度港 (oceanic_vessels) |
| 高炉冶炼 (`tech.blast_furnace`) | 焦炭冶炼 (`tech.coke_smelting`) | `upgrade` | 焦炭炼钢厂 -> 电弧炉炼钢厂 (steel) |
| 特许大学 (`tech.chartered_universities`) | 学术社团 (`tech.learned_societies`) | `specialization` | 特许大学 -> 博学学会 (technology_points); 印刷学社 -> 博学学会 (technology_points) |
| 商品作物管理 (`tech.commodity_crop_management`) | 种植园庄园管理 (`tech.estate_plantation_management`) | `upgrade` | 专用商品作物种植园 -> 香料种植园 (spices) |
| 深层地球物理 (`tech.deep_geophysics`) | 矿物光谱遥感 (`tech.mineral_spectral_survey`) | `upgrade` | 铝土矿 -> 自动化铝土矿 (bauxite) |
| 纤维捻制 (`tech.fiber_twisting`) | 织机织造 (`tech.loom_weaving`) | `upgrade` | 家庭织造棚 -> 行会织造坊 (cloth) |
| 纤维捻制 (`tech.fiber_twisting`) | 织造 (`tech.weaving`) | `alternative_method` | 家庭织造棚 -> 家用织机 (cloth) |
| 退水小麦地 (`tech.flood_recession_wheat`) | 旱作小麦田 (`tech.dryland_wheat_cultivation`) | `specialization` | 退水小麦地 -> 旱作保水小麦田 (wheat_grain) |
| 手制陶器 (`tech.hand_pottery`) | 陶器容器体系 (`tech.pottery`) | `upgrade` | 露天陶器烧造 -> 行会陶窑 (pottery) |
| 工业农学 (`tech.industrial_agronomy`) | 精准农业 (`tech.precision_agriculture`) | `upgrade` | 电气化集约农场 -> 精准农场 (grain, vegetables) |
| 工业化学 (`tech.industrial_chemistry`) | 电化学 (`tech.electrochemistry`) | `specialization` | 化学工场 -> 电化工厂 (industrial_chemicals) |
| 工业研究 (`tech.industrial_research`) | 工业质量控制 (`tech.industrial_quality_control`) | `specialization` | 智能仪器厂 -> 精密仪器厂 (scientific_instruments); 科学仪器工坊 -> 精密仪器厂 (scientific_instruments) |
| 窑烧控制 (`tech.kiln_firing`) | 陶器容器体系 (`tech.pottery`) | `alternative_method` | 升焰陶窑 -> 行会陶窑 (pottery) |
| 织机织造 (`tech.loom_weaving`) | 纺织机械 (`tech.textile_machinery`) | `upgrade` | 行会织造坊 -> 蒸汽纺织厂 (cloth) |
| 玉米园圃 (`tech.maize_garden_horticulture`) | 刀耕火种玉米 (`tech.swidden_maize_cultivation`) | `specialization` | 家庭玉米园圃 -> 刀耕火种玉米地 (corn_grain) |
| 机械化采矿 (`tech.mechanized_mining`) | 自主采矿 (`tech.autonomous_mining`) | `upgrade` | 现代硝石矿 -> 智能硝石矿 (saltpeter); 现代硫矿 -> 智能硫矿 (sulfur) |
| 矿物光谱遥感 (`tech.mineral_spectral_survey`) | 自主采矿 (`tech.autonomous_mining`) | `upgrade` | 战略矿山 -> 智能战略矿山 (rare_earth_ore) |
| 活字印刷 (`tech.movable_type_printing`) | 螺旋压印 (`tech.screw_press_printing`) | `upgrade` | 活字印刷坊 -> 印刷厂 (printed_materials) |
| 国家实验室 (`tech.national_laboratories`) | 机器学习 (`tech.machine_learning`) | `specialization` | 国家实验室 -> 智能研究院 (technology_points) |
| 自然铜冷锤 (`tech.natural_copper_working`) | 木炭坩埚炼铜 (`tech.copper_metallurgy`) | `upgrade` | 自然铜冷锤工坊 -> 土法炼铜炉 (copper) |
| 石油开采 (`tech.petroleum_extraction`) | 石油钻探 (`tech.petroleum_drilling`) | `upgrade` | 蒸汽钻井场 -> 油田 (crude_oil) |
| 植物纤维抄纸 (`tech.plant_fiber_papermaking`) | 破布纸 (`tech.rag_paper_making`) | `alternative_method` | 植物纤维抄纸坊 -> 碎布造纸工坊 (paper) |
| 精准农业 (`tech.precision_agriculture`) | 自动化农业 (`tech.automated_agriculture`) | `upgrade` | 精准农场 -> 自动化农场 (grain, vegetables) |
| 公共教育 (`tech.public_education`) | 国家实验室 (`tech.national_laboratories`) | `specialization` | 工业研究实验室 -> 国家实验室 (technology_points); 综合工学院 -> 国家实验室 (technology_points) |
| 雨养玉米田 (`tech.rainfed_maize_cultivation`) | 退水玉米地 (`tech.flood_recession_maize`) | `specialization` | 雨养玉米田 -> 退水玉米地 (corn_grain) |
| 雨养小麦田 (`tech.rainfed_wheat_cultivation`) | 退水小麦地 (`tech.flood_recession_wheat`) | `specialization` | 雨养小麦地 -> 退水小麦地 (wheat_grain); 小麦农场 -> 退水小麦地 (wheat_grain) |
| 遮阴香料园 (`tech.spice_shade_gardening`) | 商品作物管理 (`tech.commodity_crop_management`) | `upgrade` | 林下遮阴香料园 -> 专用商品作物种植园 (spices) |
| 地表煤采集 (`tech.surface_coal_collection`) | 煤矿平硐 (`tech.coal_adit_mining`) | `upgrade` | 露头煤采集场 -> 煤层平硐 (coal) |
| 地表煤采集 (`tech.surface_coal_collection`) | 煤矿开采 (`tech.coal_mining`) | `upgrade` | 露头煤采集场 -> 煤矿 (coal) |
| 刀耕火种玉米 (`tech.swidden_maize_cultivation`) | 雨养玉米田 (`tech.rainfed_maize_cultivation`) | `alternative_method` | 刀耕火种玉米地 -> 雨养玉米田 (corn_grain) |
| 佃作水田 (`tech.tenant_paddy_management`) | 庄园水田核算 (`tech.estate_paddy_management`) | `alternative_method` | 佃作稻庄 -> 庄园水田 (rice_grain); 佃作稻庄 -> 精耕稻庄 (rice_grain); 分成水田 -> 庄园水田 (rice_grain); 分成水田 -> 精耕稻庄 (rice_grain); 佃作水田 -> 庄园水田 (rice_grain); 佃作水田 -> 精耕稻庄 (rice_grain) |
| 纺织机械 (`tech.textile_machinery`) | 合成纤维工程 (`tech.synthetic_fiber_engineering`) | `specialization` | 蒸汽纺织厂 -> 合成纤维织造厂 (cloth) |
| 手工锯木 (`tech.timber_sawing`) | 蒸汽锯木 (`tech.steam_sawmilling`) | `upgrade` | 锯木场 -> 蒸汽锯木厂 (lumber); 改良锯木场 -> 蒸汽锯木厂 (lumber) |
| 旱稻繁育 (`tech.upland_rice_propagation`) | 湿地稻园 (`tech.wetland_rice_gardening`) | `specialization` | 旱稻田 -> 稻作农场 (rice_grain); 旱稻田 -> 湿地稻园 (rice_grain) |
| 湿地稻园 (`tech.wetland_rice_gardening`) | 稻田水位控制 (`tech.rice_water_control`) | `upgrade` | 稻作农场 -> 畦埂水稻田 (rice_grain); 湿地稻园 -> 畦埂水稻田 (rice_grain) |
| 野生玉米采集 (`tech.wild_maize_collection`) | 玉米园圃 (`tech.maize_garden_horticulture`) | `upgrade` | 野生玉米采集地 -> 家庭玉米园圃 (corn_grain) |
| 野生谷穗采集 (`tech.wild_wheat_collection`) | 雨养小麦田 (`tech.rainfed_wheat_cultivation`) | `upgrade` | 野生谷穗采集地 -> 雨养小麦地 (wheat_grain); 野生谷穗采集地 -> 小麦农场 (wheat_grain) |

## Violations

- None.
