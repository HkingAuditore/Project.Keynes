# Technology Gate Semantics Audit

Generated from `data/technology/technology_network.json` (schema 2).

## Summary

- Nodes: 361
- Nodes with reveal conditions: 306
- Nodes with research conditions: 74
- Research conditions fully implied by hard-prerequisite history: 17
- Reveal conditions fully implied by hard-prerequisite history: 137
- Nodes reusing the same signal atom in reveal and research: 9
- Nodes whose reveal shares signal atoms with a hard-prerequisite ancestor: 185
- Repeated reveal-formula groups: 65 groups / 233 nodes

The first three categories are deterministic semantic failures or direct gate absorption. The ancestor-atom and repeated-template categories are high-risk content findings: they require design review because contact paths and starter grants can prevent strict logical implication while leaving the gate narratively redundant.

## Fully Implied Research Conditions

These research conditions cannot block a country after all hard prerequisites have been completed.

- `tech.rice_water_control` - 稻田水位控制 (agrarian)
- `tech.probability_statistics` - 概率与统计 (enlightenment)
- `tech.public_health` - 公共卫生 (enlightenment)
- `tech.property_cadastre` - 地产测绘 (enlightenment)
- `tech.steam_power` - 蒸汽动力 (steam)
- `tech.mechanical_reaping` - 机械收割 (steam)
- `tech.textile_machinery` - 纺织机械 (steam)
- `tech.steam_sawmilling` - 蒸汽锯木 (steam)
- `tech.synthetic_fertilizer` - 合成肥料 (electrical)
- `tech.petroleum_refining` - 石油炼制 (electrical)
- `tech.electrochemistry` - 电化学 (electrical)
- `tech.electric_generation` - 发电机 (electrical)
- `tech.industrial_ecology` - 工业生态 (atomic)
- `tech.information_theory` - 信息论 (information)
- `tech.satellite_observation` - 卫星观测 (information)
- `tech.digital_marketplaces` - 数字市场 (information)
- `tech.autonomous_mining` - 自主采矿 (intelligent)

## Reveal And Research Signal Reuse

### 种植园庄园管理 (`tech.estate_plantation_management`)

- Reveal: `ANY_OF(SIGNAL(bio.spice), SIGNAL(bio.cotton))`
- Research: `ANY_OF(TECH(tech.chartered_companies), TECH(tech.crop_acclimatization), SIGNAL(bio.spice))`
- Reused: `SIGNAL(bio.spice)`

### 特种合金 (`tech.specialty_alloys`)

- Reveal: `ANY_OF(SIGNAL(resource.iron_ore), SIGNAL(resource.copper_ore), SIGNAL(breakthrough.metalworking))`
- Research: `ANY_OF(TECH(tech.electrochemistry), TECH(tech.nuclear_fuel_cycle), SIGNAL(breakthrough.metalworking))`
- Reused: `SIGNAL(breakthrough.metalworking)`

### 合成纤维工程 (`tech.synthetic_fiber_engineering`)

- Reveal: `ANY_OF(SIGNAL(resource.oil), SIGNAL(breakthrough.chemical_process_control))`
- Research: `ANY_OF(TECH(tech.plastics_engineering), TECH(tech.rubber_working), SIGNAL(breakthrough.chemical_process_control))`
- Reused: `SIGNAL(breakthrough.chemical_process_control)`

### 工业生态 (`tech.industrial_ecology`)

- Reveal: `ANY_OF(SIGNAL(breakthrough.industrial_organization), SIGNAL(breakthrough.chemical_process_control))`
- Research: `ANY_OF(TECH(tech.public_health), TECH(tech.systems_engineering), SIGNAL(breakthrough.chemical_process_control))`
- Reused: `SIGNAL(breakthrough.chemical_process_control)`

### 数字市场 (`tech.digital_marketplaces`)

- Reveal: `ANY_OF(SIGNAL(breakthrough.digital_control), SIGNAL(breakthrough.automation))`
- Research: `ANY_OF(TECH(tech.corporate_management), TECH(tech.telecommunications), SIGNAL(breakthrough.automation))`
- Reused: `SIGNAL(breakthrough.automation)`

### 自主采矿 (`tech.autonomous_mining`)

- Reveal: `ANY_OF(SIGNAL(breakthrough.mine_support), SIGNAL(breakthrough.automation))`
- Research: `ANY_OF(TECH(tech.robotic_manufacturing), TECH(tech.machine_learning), SIGNAL(breakthrough.mine_support))`
- Reused: `SIGNAL(breakthrough.mine_support)`

### 气候建模 (`tech.climate_modeling`)

- Reveal: `ANY_OF(SIGNAL(breakthrough.digital_control), SIGNAL(breakthrough.climate_modeling))`
- Research: `ANY_OF(TECH(tech.mineral_spectral_survey), TECH(tech.hydrological_remote_sensing), SIGNAL(breakthrough.climate_modeling))`
- Reused: `SIGNAL(breakthrough.climate_modeling)`

### 智能电网 (`tech.smart_grid`)

- Reveal: `ANY_OF(SIGNAL(breakthrough.energy_control), SIGNAL(breakthrough.digital_control))`
- Research: `ANY_OF(TECH(tech.systems_engineering), TECH(tech.distributed_intelligence), SIGNAL(breakthrough.energy_control))`
- Reused: `SIGNAL(breakthrough.energy_control)`

### 分布式智能 (`tech.distributed_intelligence`)

- Reveal: `ANY_OF(SIGNAL(breakthrough.digital_control), SIGNAL(breakthrough.automation))`
- Research: `ANY_OF(TECH(tech.neural_networks), TECH(tech.autonomous_systems), SIGNAL(breakthrough.automation))`
- Reused: `SIGNAL(breakthrough.automation)`

## Fully Implied Reveal Conditions

Completing the hard-prerequisite history already proves these reveal formulas. The reveal gate therefore cannot create a distinct discovery moment on the normal research path.

- `tech.seasonal_foraging` - 季节性采集 (stone)
- `tech.natural_copper_working` - 自然铜冷锤 (stone)
- `tech.copper_annealing` - 铜退火 (stone)
- `tech.animal_husbandry` - 畜牧驯养 (stone)
- `tech.animal_tracking` - 动物追踪 (stone)
- `tech.ground_stone_tools` - 磨制石器 (stone)
- `tech.seasonal_calendar` - 季节历 (stone)
- `tech.hearth_preservation` - 炉火保存 (stone)
- `tech.wild_maize_collection` - 野生玉米采集 (stone)
- `tech.maize_seed_saving` - 玉米留种 (stone)
- `tech.maize_propagation` - 玉米繁育 (stone)
- `tech.wild_wheat_collection` - 野生谷穗采集 (stone)
- `tech.wheat_seed_saving` - 小麦留种 (stone)
- `tech.wheat_propagation` - 小麦繁育 (stone)
- `tech.wild_rice_collection` - 野生稻采集 (stone)
- `tech.rice_seed_saving` - 稻种留存 (stone)
- `tech.tuber_storage` - 块茎保存 (stone)
- `tech.potato_propagation` - 块茎繁育 (stone)
- `tech.wild_cotton_collection` - 野生棉铃采集 (stone)
- `tech.wild_spice_collection` - 野生香料采集 (stone)
- `tech.wild_latex_tapping` - 野生割胶 (stone)
- `tech.surface_silver_collection` - 地表银矿拣采 (stone)
- `tech.clay_preparation` - 黏土调制 (stone)
- `tech.hand_pottery` - 手制陶器 (stone)
- `tech.pastoralism` - 游牧放牧 (agrarian)
- `tech.maize_selection` - 玉米选育 (agrarian)
- `tech.spice_cultivation` - 香料栽培 (agrarian)
- `tech.rubber_working` - 天然橡胶加工 (agrarian)
- `tech.weaving` - 织造 (agrarian)
- `tech.copper_metallurgy` - 木炭坩埚炼铜 (agrarian)
- `tech.bronze_casting` - 铜锡配比与铸造 (agrarian)
- `tech.irrigation_surveying` - 灌溉测量 (agrarian)
- `tech.kiln_firing` - 窑烧控制 (agrarian)
- `tech.pottery` - 陶器容器体系 (agrarian)
- `tech.loom_weaving` - 织机织造 (agrarian)
- `tech.communal_field_coordination` - 共同田协调 (agrarian)
- `tech.maize_garden_horticulture` - 玉米园圃 (agrarian)
- `tech.swidden_maize_cultivation` - 刀耕火种玉米 (agrarian)
- `tech.rainfed_maize_cultivation` - 雨养玉米田 (agrarian)
- `tech.flood_recession_maize` - 退水玉米地 (agrarian)
- `tech.rainfed_wheat_cultivation` - 雨养小麦田 (agrarian)
- `tech.flood_recession_wheat` - 退水小麦地 (agrarian)
- `tech.dryland_wheat_cultivation` - 旱作小麦田 (agrarian)
- `tech.upland_rice_propagation` - 旱稻繁育 (agrarian)
- `tech.wetland_rice_gardening` - 湿地稻园 (agrarian)
- `tech.rice_paddy_cultivation` - 水田稻作 (agrarian)
- `tech.ridge_tuber_cultivation` - 垄作块茎 (agrarian)
- `tech.frost_protected_storage` - 防霜窖藏 (agrarian)
- `tech.highland_tuber_farming` - 高地块茎农业 (agrarian)
- `tech.flax_retting` - 沤麻 (agrarian)
- `tech.cotton_ginning` - 棉花去籽 (agrarian)
- `tech.cotton_gardening` - 棉花园圃 (agrarian)
- `tech.spice_shade_gardening` - 遮阴香料园 (agrarian)
- `tech.latex_smoke_coagulation` - 乳胶烟熏凝固 (agrarian)
- `tech.salt_preservation` - 盐渍保存 (agrarian)
- `tech.grain_baking` - 谷物烘焙 (agrarian)
- `tech.masonry` - 砌体建筑 (kingdom)
- `tech.market_institutions` - 市场制度 (kingdom)
- `tech.canal_engineering` - 运河工程 (kingdom)
- `tech.urban_sanitation` - 城市卫生 (kingdom)
- `tech.plant_fiber_papermaking` - 植物纤维抄纸 (kingdom)
- `tech.bark_paper_making` - 树皮纸 (kingdom)
- `tech.surface_iron_collection` - 地表铁矿采集 (kingdom)
- `tech.iron_smelting` - 块炼铁 (kingdom)
- `tech.surface_coal_collection` - 地表煤采集 (kingdom)
- `tech.forest_management` - 森林管理 (empire)
- `tech.pastoral_networks` - 牧业网络 (empire)
- `tech.water_power` - 水力机械 (empire)
- `tech.blast_furnace` - 高炉冶炼 (empire)
- `tech.coal_mining` - 煤矿开采 (empire)
- `tech.coal_adit_mining` - 煤矿平硐 (empire)
- `tech.estate_paddy_management` - 庄园水田核算 (empire)
- `tech.oceanic_ship_design` - 远洋船舶设计 (exploration)
- `tech.coastal_shipyards` - 海岸船厂 (exploration)
- `tech.screw_press_printing` - 螺旋压印 (exploration)
- `tech.gunpowder_weapons` - 火药武器 (exploration)
- `tech.deep_mining` - 深井采矿 (exploration)
- `tech.mine_drainage` - 矿井排水 (exploration)
- `tech.chartered_companies` - 特许商社 (exploration)
- `tech.oceanic_provisioning` - 远洋补给 (exploration)
- `tech.hydraulic_engineering` - 水利工程 (enlightenment)
- `tech.geological_prospecting` - 地质勘探 (enlightenment)
- `tech.learned_societies` - 学术社团 (enlightenment)
- `tech.livestock_breeding` - 畜种改良 (enlightenment)
- `tech.property_cadastre` - 地产测绘 (enlightenment)
- `tech.industrial_coal_mining` - 工业采煤 (steam)
- `tech.coke_smelting` - 焦炭冶炼 (steam)
- `tech.industrial_chemistry` - 工业化学 (steam)
- `tech.fertilizer_processing` - 肥料加工 (steam)
- `tech.labor_organization` - 劳工组织 (steam)
- `tech.managerial_hierarchy` - 管理层级 (steam)
- `tech.steam_sawmilling` - 蒸汽锯木 (steam)
- `tech.corporate_mining` - 公司矿山 (steam)
- `tech.worker_cooperatives` - 工人合作工场 (steam)
- `tech.synthetic_fertilizer` - 合成肥料 (electrical)
- `tech.petroleum_refining` - 石油炼制 (electrical)
- `tech.internal_combustion` - 内燃机 (electrical)
- `tech.electrochemistry` - 电化学 (electrical)
- `tech.radio` - 无线电 (electrical)
- `tech.electric_generation` - 发电机 (electrical)
- `tech.electric_grid` - 电网 (electrical)
- `tech.telecommunications` - 电信 (electrical)
- `tech.electric_motors` - 电动机 (electrical)
- `tech.petroleum_drilling` - 石油钻探 (electrical)
- `tech.advanced_metallurgy` - 先进冶金 (atomic)
- `tech.nuclear_fission` - 核裂变 (atomic)
- `tech.petrochemical_industry` - 石油化工 (atomic)
- `tech.synthetic_materials` - 合成材料 (atomic)
- `tech.mechanized_mining` - 机械化采矿 (atomic)
- `tech.nuclear_energy` - 核能 (atomic)
- `tech.specialty_alloys` - 特种合金 (atomic)
- `tech.petrochemical_cracking` - 石化裂解 (atomic)
- `tech.plastics_engineering` - 塑料工程 (atomic)
- `tech.corporate_agribusiness` - 公司农业 (atomic)
- `tech.software_engineering` - 软件工程 (information)
- `tech.networked_computing` - 网络计算 (information)
- `tech.mineral_spectral_survey` - 矿物光谱遥感 (information)
- `tech.numerical_weather_prediction` - 数值天气预报 (information)
- `tech.crop_remote_sensing` - 作物遥感 (information)
- `tech.hydrological_remote_sensing` - 水文遥感 (information)
- `tech.platform_coordination` - 平台协调 (information)
- `tech.digital_marketplaces` - 数字市场 (information)
- `tech.precision_irrigation` - 精准灌溉 (information)
- `tech.sensor_networks` - 传感器网络 (information)
- `tech.bioinformatics` - 生物信息学 (information)
- `tech.neural_networks` - 神经网络 (intelligent)
- `tech.human_machine_collaboration` - 人机协作 (intelligent)
- `tech.autonomous_mining` - 自主采矿 (intelligent)
- `tech.computational_biology` - 计算生物学 (intelligent)
- `tech.climate_modeling` - 气候建模 (intelligent)
- `tech.algorithmic_governance` - 算法治理 (intelligent)
- `tech.distributed_intelligence` - 分布式智能 (intelligent)
- `tech.autonomous_logistics` - 自主物流 (intelligent)
- `tech.scientific_agents` - 智能科学代理 (intelligent)
- `tech.adaptive_irrigation` - 自适应灌溉 (intelligent)
- `tech.knowledge_cooperatives` - 知识合作社 (intelligent)
- `tech.autonomous_labor_coordination` - 自主劳动协调 (intelligent)

## Reveal Signal Reused From Ancestors

### 季节性采集 (`tech.seasonal_foraging`)

- 采集 (`tech.gathering`): `SIGNAL(resource.fertile_soil)`

### 自然铜冷锤 (`tech.natural_copper_working`)

- 自然铜辨识 (`tech.natural_copper_identification`): `SIGNAL(resource.copper_ore)`

### 铜退火 (`tech.copper_annealing`)

- 自然铜冷锤 (`tech.natural_copper_working`): `SIGNAL(resource.copper_ore)`
- 自然铜辨识 (`tech.natural_copper_identification`): `SIGNAL(resource.copper_ore)`

### 畜牧驯养 (`tech.animal_husbandry`)

- 狩猎 (`tech.hunting`): `SIGNAL(resource.wild_game)`

### 动物追踪 (`tech.animal_tracking`)

- 畜牧驯养 (`tech.animal_husbandry`): `SIGNAL(resource.wild_game)`
- 狩猎 (`tech.hunting`): `SIGNAL(resource.wild_game)`

### 磨制石器 (`tech.ground_stone_tools`)

- 打制石器 (`tech.stone_knapping`): `SIGNAL(resource.stone)`, `SIGNAL(resource.flint)`

### 季节历 (`tech.seasonal_calendar`)

- 口述传统 (`tech.oral_tradition`): `SIGNAL(weather.monsoon)`, `SIGNAL(weather.frost)`, `SIGNAL(landform.river_valley)`

### 炉火保存 (`tech.hearth_preservation`)

- 食物储藏 (`tech.food_storage`): `SIGNAL(breakthrough.seed_saving)`, `SIGNAL(resource.fertile_soil)`, `SIGNAL(weather.repeated_crop_failure)`

### 野生玉米采集 (`tech.wild_maize_collection`)

- 玉米辨识 (`tech.maize_identification`): `SIGNAL(bio.maize)`, `SIGNAL(contact.maize)`

### 玉米留种 (`tech.maize_seed_saving`)

- 野生玉米采集 (`tech.wild_maize_collection`): `SIGNAL(bio.maize)`, `SIGNAL(contact.maize)`
- 玉米辨识 (`tech.maize_identification`): `SIGNAL(bio.maize)`, `SIGNAL(contact.maize)`

### 玉米繁育 (`tech.maize_propagation`)

- 玉米留种 (`tech.maize_seed_saving`): `SIGNAL(bio.maize)`, `SIGNAL(contact.maize)`
- 野生玉米采集 (`tech.wild_maize_collection`): `SIGNAL(bio.maize)`, `SIGNAL(contact.maize)`
- 玉米辨识 (`tech.maize_identification`): `SIGNAL(bio.maize)`, `SIGNAL(contact.maize)`

### 野生谷穗采集 (`tech.wild_wheat_collection`)

- 小麦辨识 (`tech.wheat_identification`): `SIGNAL(bio.wheat)`, `SIGNAL(contact.wheat)`

### 小麦留种 (`tech.wheat_seed_saving`)

- 野生谷穗采集 (`tech.wild_wheat_collection`): `SIGNAL(bio.wheat)`, `SIGNAL(contact.wheat)`
- 小麦辨识 (`tech.wheat_identification`): `SIGNAL(bio.wheat)`, `SIGNAL(contact.wheat)`

### 小麦繁育 (`tech.wheat_propagation`)

- 小麦留种 (`tech.wheat_seed_saving`): `SIGNAL(bio.wheat)`, `SIGNAL(contact.wheat)`
- 野生谷穗采集 (`tech.wild_wheat_collection`): `SIGNAL(bio.wheat)`, `SIGNAL(contact.wheat)`
- 小麦辨识 (`tech.wheat_identification`): `SIGNAL(bio.wheat)`, `SIGNAL(contact.wheat)`

### 野生稻采集 (`tech.wild_rice_collection`)

- 稻类辨识 (`tech.rice_identification`): `SIGNAL(bio.rice)`, `SIGNAL(contact.rice)`

### 稻种留存 (`tech.rice_seed_saving`)

- 野生稻采集 (`tech.wild_rice_collection`): `SIGNAL(bio.rice)`, `SIGNAL(contact.rice)`
- 稻类辨识 (`tech.rice_identification`): `SIGNAL(bio.rice)`, `SIGNAL(contact.rice)`

### 块茎保存 (`tech.tuber_storage`)

- 块茎辨识 (`tech.potato_identification`): `SIGNAL(bio.potato)`, `SIGNAL(contact.potato)`

### 块茎繁育 (`tech.potato_propagation`)

- 块茎保存 (`tech.tuber_storage`): `SIGNAL(bio.potato)`, `SIGNAL(contact.potato)`
- 块茎辨识 (`tech.potato_identification`): `SIGNAL(bio.potato)`, `SIGNAL(contact.potato)`

### 野生棉铃采集 (`tech.wild_cotton_collection`)

- 棉花辨识 (`tech.cotton_identification`): `SIGNAL(bio.cotton)`, `SIGNAL(contact.cotton)`

### 野生香料采集 (`tech.wild_spice_collection`)

- 香料植物辨识 (`tech.spice_identification`): `SIGNAL(bio.spice)`, `SIGNAL(contact.spice)`

### 野生割胶 (`tech.wild_latex_tapping`)

- 橡胶树辨识 (`tech.rubber_identification`): `SIGNAL(bio.rubber)`, `SIGNAL(contact.rubber)`

### 地表银矿拣采 (`tech.surface_silver_collection`)

- 地表银脉辨识 (`tech.silver_vein_identification`): `SIGNAL(resource.silver_ore)`

### 铜矿焙烧 (`tech.copper_ore_roasting`)

- 铜退火 (`tech.copper_annealing`): `SIGNAL(resource.copper_ore)`, `SIGNAL(breakthrough.metalworking)`
- 自然铜冷锤 (`tech.natural_copper_working`): `SIGNAL(resource.copper_ore)`
- 自然铜辨识 (`tech.natural_copper_identification`): `SIGNAL(resource.copper_ore)`

### 黏土调制 (`tech.clay_preparation`)

- 黏土辨识 (`tech.clay_identification`): `SIGNAL(resource.clay)`

### 手制陶器 (`tech.hand_pottery`)

- 黏土调制 (`tech.clay_preparation`): `SIGNAL(resource.clay)`
- 黏土辨识 (`tech.clay_identification`): `SIGNAL(resource.clay)`

### 灌溉 (`tech.irrigation`)

- 洪水历法实践 (`tech.flood_calendar_practice`): `SIGNAL(landform.river_valley)`

### 游牧放牧 (`tech.pastoralism`)

- 畜群管理 (`tech.herd_management`): `SIGNAL(bio.sheep)`, `SIGNAL(bio.horse)`, `SIGNAL(bio.cattle)`

### 马匹驯化 (`tech.horse_domestication`)

- 畜群管理 (`tech.herd_management`): `SIGNAL(bio.horse)`

### 玉米选育 (`tech.maize_selection`)

- 野生玉米采集 (`tech.wild_maize_collection`): `SIGNAL(bio.maize)`, `SIGNAL(contact.maize)`
- 玉米辨识 (`tech.maize_identification`): `SIGNAL(bio.maize)`, `SIGNAL(contact.maize)`

### 香料栽培 (`tech.spice_cultivation`)

- 野生香料采集 (`tech.wild_spice_collection`): `SIGNAL(bio.spice)`, `SIGNAL(contact.spice)`
- 香料植物辨识 (`tech.spice_identification`): `SIGNAL(bio.spice)`, `SIGNAL(contact.spice)`

### 天然橡胶加工 (`tech.rubber_working`)

- 野生割胶 (`tech.wild_latex_tapping`): `SIGNAL(bio.rubber)`, `SIGNAL(contact.rubber)`
- 橡胶树辨识 (`tech.rubber_identification`): `SIGNAL(bio.rubber)`, `SIGNAL(contact.rubber)`

### 织造 (`tech.weaving`)

- 纤维捻制 (`tech.fiber_twisting`): `SIGNAL(bio.flax)`, `SIGNAL(bio.cotton)`, `SIGNAL(bio.bast_fiber)`

### 木炭坩埚炼铜 (`tech.copper_metallurgy`)

- 自然铜冷锤 (`tech.natural_copper_working`): `SIGNAL(resource.copper_ore)`
- 自然铜辨识 (`tech.natural_copper_identification`): `SIGNAL(resource.copper_ore)`

### 铜锡配比与铸造 (`tech.bronze_casting`)

- 自然铜冷锤 (`tech.natural_copper_working`): `SIGNAL(resource.copper_ore)`
- 自然铜辨识 (`tech.natural_copper_identification`): `SIGNAL(resource.copper_ore)`

### 旱作保水 (`tech.dryland_water_retention`)

- 旱作农业 (`tech.dryland_farming`): `SIGNAL(resource.arable_land)`, `SIGNAL(weather.drought)`

### 灌溉测量 (`tech.irrigation_surveying`)

- 灌溉 (`tech.irrigation`): `SIGNAL(landform.freshwater_access)`, `SIGNAL(landform.river_valley)`, `SIGNAL(breakthrough.hydraulic_engineering)`
- 洪水历法实践 (`tech.flood_calendar_practice`): `SIGNAL(landform.river_valley)`

### 窑烧控制 (`tech.kiln_firing`)

- 黏土调制 (`tech.clay_preparation`): `SIGNAL(resource.clay)`
- 黏土辨识 (`tech.clay_identification`): `SIGNAL(resource.clay)`

### 陶器容器体系 (`tech.pottery`)

- 窑烧控制 (`tech.kiln_firing`): `SIGNAL(resource.clay)`, `SIGNAL(breakthrough.kiln_temperature)`
- 黏土调制 (`tech.clay_preparation`): `SIGNAL(resource.clay)`
- 黏土辨识 (`tech.clay_identification`): `SIGNAL(resource.clay)`
- 手制陶器 (`tech.hand_pottery`): `SIGNAL(resource.clay)`

### 织机织造 (`tech.loom_weaving`)

- 纤维捻制 (`tech.fiber_twisting`): `SIGNAL(bio.flax)`, `SIGNAL(bio.cotton)`, `SIGNAL(bio.bast_fiber)`

### 畜力牵引 (`tech.animal_traction`)

- 畜牧驯养 (`tech.animal_husbandry`): `SIGNAL(bio.horse)`, `SIGNAL(bio.cattle)`

### 家庭土地占有 (`tech.household_landholding`)

- 记事制度 (`tech.record_keeping`): `SIGNAL(breakthrough.seed_saving)`

### 共同田协调 (`tech.communal_field_coordination`)

- 家庭土地占有 (`tech.household_landholding`): `SIGNAL(resource.fertile_soil)`, `SIGNAL(landform.river_valley)`, `SIGNAL(breakthrough.seed_saving)`
- 记事制度 (`tech.record_keeping`): `SIGNAL(breakthrough.seed_saving)`

### 玉米园圃 (`tech.maize_garden_horticulture`)

- 野生玉米采集 (`tech.wild_maize_collection`): `SIGNAL(bio.maize)`, `SIGNAL(contact.maize)`
- 玉米辨识 (`tech.maize_identification`): `SIGNAL(bio.maize)`, `SIGNAL(contact.maize)`

### 刀耕火种玉米 (`tech.swidden_maize_cultivation`)

- 玉米园圃 (`tech.maize_garden_horticulture`): `SIGNAL(bio.maize)`, `SIGNAL(contact.maize)`
- 野生玉米采集 (`tech.wild_maize_collection`): `SIGNAL(bio.maize)`, `SIGNAL(contact.maize)`
- 玉米辨识 (`tech.maize_identification`): `SIGNAL(bio.maize)`, `SIGNAL(contact.maize)`

### 雨养玉米田 (`tech.rainfed_maize_cultivation`)

- 刀耕火种玉米 (`tech.swidden_maize_cultivation`): `SIGNAL(bio.maize)`, `SIGNAL(contact.maize)`
- 玉米园圃 (`tech.maize_garden_horticulture`): `SIGNAL(bio.maize)`, `SIGNAL(contact.maize)`
- 野生玉米采集 (`tech.wild_maize_collection`): `SIGNAL(bio.maize)`, `SIGNAL(contact.maize)`
- 玉米辨识 (`tech.maize_identification`): `SIGNAL(bio.maize)`, `SIGNAL(contact.maize)`

### 退水玉米地 (`tech.flood_recession_maize`)

- 雨养玉米田 (`tech.rainfed_maize_cultivation`): `SIGNAL(bio.maize)`, `SIGNAL(contact.maize)`
- 刀耕火种玉米 (`tech.swidden_maize_cultivation`): `SIGNAL(bio.maize)`, `SIGNAL(contact.maize)`
- 玉米园圃 (`tech.maize_garden_horticulture`): `SIGNAL(bio.maize)`, `SIGNAL(contact.maize)`
- 野生玉米采集 (`tech.wild_maize_collection`): `SIGNAL(bio.maize)`, `SIGNAL(contact.maize)`
- 玉米辨识 (`tech.maize_identification`): `SIGNAL(bio.maize)`, `SIGNAL(contact.maize)`

### 谷物脱粒 (`tech.grain_threshing`)

- 野生谷穗采集 (`tech.wild_wheat_collection`): `SIGNAL(bio.wheat)`
- 小麦辨识 (`tech.wheat_identification`): `SIGNAL(bio.wheat)`

### 雨养小麦田 (`tech.rainfed_wheat_cultivation`)

- 野生谷穗采集 (`tech.wild_wheat_collection`): `SIGNAL(bio.wheat)`, `SIGNAL(contact.wheat)`
- 小麦辨识 (`tech.wheat_identification`): `SIGNAL(bio.wheat)`, `SIGNAL(contact.wheat)`

### 退水小麦地 (`tech.flood_recession_wheat`)

- 雨养小麦田 (`tech.rainfed_wheat_cultivation`): `SIGNAL(bio.wheat)`, `SIGNAL(contact.wheat)`
- 野生谷穗采集 (`tech.wild_wheat_collection`): `SIGNAL(bio.wheat)`, `SIGNAL(contact.wheat)`
- 小麦辨识 (`tech.wheat_identification`): `SIGNAL(bio.wheat)`, `SIGNAL(contact.wheat)`

### 旱作小麦田 (`tech.dryland_wheat_cultivation`)

- 退水小麦地 (`tech.flood_recession_wheat`): `SIGNAL(bio.wheat)`, `SIGNAL(contact.wheat)`
- 雨养小麦田 (`tech.rainfed_wheat_cultivation`): `SIGNAL(bio.wheat)`, `SIGNAL(contact.wheat)`
- 野生谷穗采集 (`tech.wild_wheat_collection`): `SIGNAL(bio.wheat)`, `SIGNAL(contact.wheat)`
- 小麦辨识 (`tech.wheat_identification`): `SIGNAL(bio.wheat)`, `SIGNAL(contact.wheat)`

### 旱稻繁育 (`tech.upland_rice_propagation`)

- 野生稻采集 (`tech.wild_rice_collection`): `SIGNAL(bio.rice)`, `SIGNAL(contact.rice)`
- 稻类辨识 (`tech.rice_identification`): `SIGNAL(bio.rice)`, `SIGNAL(contact.rice)`

### 湿地稻园 (`tech.wetland_rice_gardening`)

- 旱稻繁育 (`tech.upland_rice_propagation`): `SIGNAL(bio.rice)`, `SIGNAL(contact.rice)`
- 野生稻采集 (`tech.wild_rice_collection`): `SIGNAL(bio.rice)`, `SIGNAL(contact.rice)`
- 稻类辨识 (`tech.rice_identification`): `SIGNAL(bio.rice)`, `SIGNAL(contact.rice)`

### 稻田水位控制 (`tech.rice_water_control`)

- 水田畦埂 (`tech.paddy_bunding`): `SIGNAL(resource.paddy_land)`, `SIGNAL(breakthrough.paddy_control)`

### 水田稻作 (`tech.rice_paddy_cultivation`)

- 野生稻采集 (`tech.wild_rice_collection`): `SIGNAL(bio.rice)`, `SIGNAL(contact.rice)`
- 稻类辨识 (`tech.rice_identification`): `SIGNAL(bio.rice)`, `SIGNAL(contact.rice)`

### 垄作块茎 (`tech.ridge_tuber_cultivation`)

- 块茎保存 (`tech.tuber_storage`): `SIGNAL(bio.potato)`, `SIGNAL(contact.potato)`
- 块茎辨识 (`tech.potato_identification`): `SIGNAL(bio.potato)`, `SIGNAL(contact.potato)`

### 防霜窖藏 (`tech.frost_protected_storage`)

- 垄作块茎 (`tech.ridge_tuber_cultivation`): `SIGNAL(bio.potato)`, `SIGNAL(contact.potato)`
- 块茎保存 (`tech.tuber_storage`): `SIGNAL(bio.potato)`, `SIGNAL(contact.potato)`
- 块茎辨识 (`tech.potato_identification`): `SIGNAL(bio.potato)`, `SIGNAL(contact.potato)`

### 高地块茎农业 (`tech.highland_tuber_farming`)

- 块茎保存 (`tech.tuber_storage`): `SIGNAL(bio.potato)`, `SIGNAL(contact.potato)`
- 块茎辨识 (`tech.potato_identification`): `SIGNAL(bio.potato)`, `SIGNAL(contact.potato)`

### 沤麻 (`tech.flax_retting`)

- 亚麻与韧皮辨识 (`tech.flax_identification`): `SIGNAL(bio.flax)`, `SIGNAL(bio.bast_fiber)`, `SIGNAL(contact.flax)`

### 手工纺纱 (`tech.hand_spinning`)

- 沤麻 (`tech.flax_retting`): `SIGNAL(bio.flax)`, `SIGNAL(bio.bast_fiber)`
- 亚麻与韧皮辨识 (`tech.flax_identification`): `SIGNAL(bio.flax)`, `SIGNAL(bio.bast_fiber)`

### 棉花去籽 (`tech.cotton_ginning`)

- 野生棉铃采集 (`tech.wild_cotton_collection`): `SIGNAL(bio.cotton)`, `SIGNAL(contact.cotton)`
- 棉花辨识 (`tech.cotton_identification`): `SIGNAL(bio.cotton)`, `SIGNAL(contact.cotton)`

### 棉花园圃 (`tech.cotton_gardening`)

- 野生棉铃采集 (`tech.wild_cotton_collection`): `SIGNAL(bio.cotton)`, `SIGNAL(contact.cotton)`
- 棉花辨识 (`tech.cotton_identification`): `SIGNAL(bio.cotton)`, `SIGNAL(contact.cotton)`

### 遮阴香料园 (`tech.spice_shade_gardening`)

- 野生香料采集 (`tech.wild_spice_collection`): `SIGNAL(bio.spice)`, `SIGNAL(contact.spice)`
- 香料植物辨识 (`tech.spice_identification`): `SIGNAL(bio.spice)`, `SIGNAL(contact.spice)`

### 乳胶烟熏凝固 (`tech.latex_smoke_coagulation`)

- 天然橡胶加工 (`tech.rubber_working`): `SIGNAL(bio.rubber)`, `SIGNAL(contact.rubber)`
- 野生割胶 (`tech.wild_latex_tapping`): `SIGNAL(bio.rubber)`, `SIGNAL(contact.rubber)`
- 橡胶树辨识 (`tech.rubber_identification`): `SIGNAL(bio.rubber)`, `SIGNAL(contact.rubber)`

### 乳品加工 (`tech.dairy_processing`)

- 畜群管理 (`tech.herd_management`): `SIGNAL(bio.cattle)`

### 皮革鞣制 (`tech.hide_tanning`)

- 畜群管理 (`tech.herd_management`): `SIGNAL(bio.sheep)`

### 毛用畜牧 (`tech.wool_husbandry`)

- 畜群管理 (`tech.herd_management`): `SIGNAL(bio.sheep)`

### 屠宰分割 (`tech.meat_processing`)

- 畜群管理 (`tech.herd_management`): `SIGNAL(bio.cattle)`, `SIGNAL(bio.sheep)`

### 盐渍保存 (`tech.salt_preservation`)

- 卤水采集 (`tech.brine_collection`): `SIGNAL(resource.salt)`, `SIGNAL(resource.sulfur)`

### 谷物烘焙 (`tech.grain_baking`)

- 旱作小麦田 (`tech.dryland_wheat_cultivation`): `SIGNAL(bio.wheat)`, `SIGNAL(contact.wheat)`
- 退水小麦地 (`tech.flood_recession_wheat`): `SIGNAL(bio.wheat)`, `SIGNAL(contact.wheat)`
- 雨养小麦田 (`tech.rainfed_wheat_cultivation`): `SIGNAL(bio.wheat)`, `SIGNAL(contact.wheat)`
- 野生谷穗采集 (`tech.wild_wheat_collection`): `SIGNAL(bio.wheat)`, `SIGNAL(contact.wheat)`
- 小麦辨识 (`tech.wheat_identification`): `SIGNAL(bio.wheat)`, `SIGNAL(contact.wheat)`

### 早期玻璃烧制 (`tech.early_glassmaking`)

- 窑烧控制 (`tech.kiln_firing`): `SIGNAL(resource.silica_sand)`, `SIGNAL(breakthrough.kiln_temperature)`

### 砌体建筑 (`tech.masonry`)

- 日晒土坯 (`tech.adobe_making`): `SIGNAL(resource.clay)`

### 市场制度 (`tech.market_institutions`)

- 早期贸易 (`tech.early_trade`): `SIGNAL(resource.gold_ore)`, `SIGNAL(resource.silver_ore)`

### 运河工程 (`tech.canal_engineering`)

- 灌溉 (`tech.irrigation`): `SIGNAL(landform.freshwater_access)`, `SIGNAL(landform.river_valley)`, `SIGNAL(breakthrough.hydraulic_engineering)`
- 洪水历法实践 (`tech.flood_calendar_practice`): `SIGNAL(landform.river_valley)`

### 城市卫生 (`tech.urban_sanitation`)

- 盐渍保存 (`tech.salt_preservation`): `SIGNAL(resource.salt)`, `SIGNAL(resource.sulfur)`
- 卤水采集 (`tech.brine_collection`): `SIGNAL(resource.salt)`, `SIGNAL(resource.sulfur)`

### 植物纤维抄纸 (`tech.plant_fiber_papermaking`)

- 织机织造 (`tech.loom_weaving`): `SIGNAL(bio.flax)`, `SIGNAL(bio.cotton)`, `SIGNAL(bio.bast_fiber)`
- 纤维捻制 (`tech.fiber_twisting`): `SIGNAL(bio.flax)`, `SIGNAL(bio.cotton)`, `SIGNAL(bio.bast_fiber)`

### 树皮纸 (`tech.bark_paper_making`)

- 手工锯木 (`tech.timber_sawing`): `SIGNAL(resource.timber)`

### 皮纸制作 (`tech.parchment_making`)

- 畜群管理 (`tech.herd_management`): `SIGNAL(bio.sheep)`

### 手稿文化 (`tech.manuscript_culture`)

- 学术机构 (`tech.scholarly_academies`): `SIGNAL(resource.timber)`

### 地表铁矿采集 (`tech.surface_iron_collection`)

- 铁矿辨识 (`tech.iron_ore_identification`): `SIGNAL(resource.iron_ore)`

### 块炼铁 (`tech.iron_smelting`)

- 地表铁矿采集 (`tech.surface_iron_collection`): `SIGNAL(resource.iron_ore)`
- 铁矿辨识 (`tech.iron_ore_identification`): `SIGNAL(resource.iron_ore)`

### 地表煤采集 (`tech.surface_coal_collection`)

- 露头煤辨识 (`tech.coal_outcrop_identification`): `SIGNAL(resource.coal)`

### 森林管理 (`tech.forest_management`)

- 树皮纸 (`tech.bark_paper_making`): `SIGNAL(resource.timber)`
- 手工锯木 (`tech.timber_sawing`): `SIGNAL(resource.timber)`

### 牧业网络 (`tech.pastoral_networks`)

- 皮纸制作 (`tech.parchment_making`): `SIGNAL(bio.sheep)`
- 马匹驯化 (`tech.horse_domestication`): `SIGNAL(bio.horse)`
- 畜群管理 (`tech.herd_management`): `SIGNAL(bio.sheep)`, `SIGNAL(bio.horse)`, `SIGNAL(bio.cattle)`

### 水力机械 (`tech.water_power`)

- 运河工程 (`tech.canal_engineering`): `SIGNAL(landform.freshwater_access)`, `SIGNAL(landform.river_valley)`, `SIGNAL(breakthrough.hydraulic_engineering)`
- 灌溉 (`tech.irrigation`): `SIGNAL(landform.freshwater_access)`, `SIGNAL(landform.river_valley)`, `SIGNAL(breakthrough.hydraulic_engineering)`
- 洪水历法实践 (`tech.flood_calendar_practice`): `SIGNAL(landform.river_valley)`

### 高炉冶炼 (`tech.blast_furnace`)

- 块炼铁 (`tech.iron_smelting`): `SIGNAL(resource.iron_ore)`, `SIGNAL(resource.coal)`
- 地表铁矿采集 (`tech.surface_iron_collection`): `SIGNAL(resource.iron_ore)`
- 铁矿辨识 (`tech.iron_ore_identification`): `SIGNAL(resource.iron_ore)`

### 煤矿开采 (`tech.coal_mining`)

- 块炼铁 (`tech.iron_smelting`): `SIGNAL(resource.coal)`
- 地表煤采集 (`tech.surface_coal_collection`): `SIGNAL(resource.coal)`
- 露头煤辨识 (`tech.coal_outcrop_identification`): `SIGNAL(resource.coal)`

### 火药配制 (`tech.gunpowder_formulation`)

- 卤水采集 (`tech.brine_collection`): `SIGNAL(resource.sulfur)`

### 庄园谷物经营 (`tech.manorial_cereal_farming`)

- 玉米园圃 (`tech.maize_garden_horticulture`): `SIGNAL(bio.maize)`
- 野生玉米采集 (`tech.wild_maize_collection`): `SIGNAL(bio.maize)`
- 玉米辨识 (`tech.maize_identification`): `SIGNAL(bio.maize)`

### 煤矿平硐 (`tech.coal_adit_mining`)

- 地表煤采集 (`tech.surface_coal_collection`): `SIGNAL(resource.coal)`
- 露头煤辨识 (`tech.coal_outcrop_identification`): `SIGNAL(resource.coal)`

### 矿井通风 (`tech.mine_ventilation`)

- 矿井木支护 (`tech.mine_timbering`): `SIGNAL(breakthrough.mine_support)`

### 庄园水田核算 (`tech.estate_paddy_management`)

- 佃作水田 (`tech.tenant_paddy_management`): `SIGNAL(resource.paddy_land)`, `SIGNAL(landform.floodplain)`, `SIGNAL(breakthrough.paddy_control)`

### 远洋船舶设计 (`tech.oceanic_ship_design`)

- 远洋航海 (`tech.oceanic_navigation`): `SIGNAL(landform.coast)`, `SIGNAL(landform.coastal_estuary)`, `SIGNAL(contact.maritime_vessel)`, `SIGNAL(breakthrough.maritime_operations)`

### 海岸船厂 (`tech.coastal_shipyards`)

- 远洋船舶设计 (`tech.oceanic_ship_design`): `SIGNAL(landform.coast)`, `SIGNAL(landform.coastal_estuary)`, `SIGNAL(contact.maritime_vessel)`, `SIGNAL(breakthrough.maritime_operations)`
- 远洋航海 (`tech.oceanic_navigation`): `SIGNAL(landform.coast)`, `SIGNAL(landform.coastal_estuary)`, `SIGNAL(contact.maritime_vessel)`, `SIGNAL(breakthrough.maritime_operations)`

### 螺旋压印 (`tech.screw_press_printing`)

- 手工锯木 (`tech.timber_sawing`): `SIGNAL(resource.timber)`

### 火药武器 (`tech.gunpowder_weapons`)

- 火药配制 (`tech.gunpowder_formulation`): `SIGNAL(resource.sulfur)`, `SIGNAL(resource.phosphate_rock)`, `SIGNAL(resource.saltpeter)`
- 卤水采集 (`tech.brine_collection`): `SIGNAL(resource.sulfur)`

### 商业网络 (`tech.mercantile_networks`)

- 远洋航海 (`tech.oceanic_navigation`): `SIGNAL(landform.coast)`, `SIGNAL(breakthrough.maritime_operations)`

### 深井采矿 (`tech.deep_mining`)

- 矿井通风 (`tech.mine_ventilation`): `SIGNAL(breakthrough.mine_support)`
- 矿井木支护 (`tech.mine_timbering`): `SIGNAL(breakthrough.mine_support)`
- 井筒开掘 (`tech.shaft_sinking`): `SIGNAL(breakthrough.mine_support)`

### 矿井排水 (`tech.mine_drainage`)

- 井筒开掘 (`tech.shaft_sinking`): `SIGNAL(breakthrough.mine_support)`
- 水力机械 (`tech.water_power`): `SIGNAL(landform.freshwater_access)`
- 运河工程 (`tech.canal_engineering`): `SIGNAL(landform.freshwater_access)`
- 灌溉 (`tech.irrigation`): `SIGNAL(landform.freshwater_access)`

### 特许商社 (`tech.chartered_companies`)

- 商业网络 (`tech.mercantile_networks`): `SIGNAL(landform.coast)`, `SIGNAL(breakthrough.maritime_operations)`, `SIGNAL(breakthrough.printing)`
- 远洋航海 (`tech.oceanic_navigation`): `SIGNAL(landform.coast)`, `SIGNAL(breakthrough.maritime_operations)`

### 商品作物管理 (`tech.commodity_crop_management`)

- 棉花园圃 (`tech.cotton_gardening`): `SIGNAL(bio.cotton)`
- 野生棉铃采集 (`tech.wild_cotton_collection`): `SIGNAL(bio.cotton)`
- 棉花辨识 (`tech.cotton_identification`): `SIGNAL(bio.cotton)`

### 种植园庄园管理 (`tech.estate_plantation_management`)

- 商品作物管理 (`tech.commodity_crop_management`): `SIGNAL(bio.cotton)`
- 遮阴香料园 (`tech.spice_shade_gardening`): `SIGNAL(bio.spice)`
- 野生香料采集 (`tech.wild_spice_collection`): `SIGNAL(bio.spice)`
- 香料植物辨识 (`tech.spice_identification`): `SIGNAL(bio.spice)`
- 棉花园圃 (`tech.cotton_gardening`): `SIGNAL(bio.cotton)`
- 野生棉铃采集 (`tech.wild_cotton_collection`): `SIGNAL(bio.cotton)`
- 棉花辨识 (`tech.cotton_identification`): `SIGNAL(bio.cotton)`

### 远洋补给 (`tech.oceanic_provisioning`)

- 远洋航海 (`tech.oceanic_navigation`): `SIGNAL(landform.coast)`, `SIGNAL(landform.coastal_estuary)`, `SIGNAL(contact.maritime_vessel)`, `SIGNAL(breakthrough.maritime_operations)`

### 作物驯化移植 (`tech.crop_acclimatization`)

- 跨区域植物学 (`tech.interregional_botany`): `SIGNAL(bio.potato)`

### 公共卫生 (`tech.public_health`)

- 城市卫生 (`tech.urban_sanitation`): `SIGNAL(resource.sulfur)`
- 盐渍保存 (`tech.salt_preservation`): `SIGNAL(resource.saltpeter)`, `SIGNAL(resource.sulfur)`
- 卤水采集 (`tech.brine_collection`): `SIGNAL(resource.sulfur)`

### 水利工程 (`tech.hydraulic_engineering`)

- 灌溉测量 (`tech.irrigation_surveying`): `SIGNAL(landform.freshwater_access)`, `SIGNAL(landform.river_valley)`, `SIGNAL(breakthrough.hydraulic_engineering)`
- 灌溉 (`tech.irrigation`): `SIGNAL(landform.freshwater_access)`, `SIGNAL(landform.river_valley)`, `SIGNAL(breakthrough.hydraulic_engineering)`
- 洪水历法实践 (`tech.flood_calendar_practice`): `SIGNAL(landform.river_valley)`
- 运河工程 (`tech.canal_engineering`): `SIGNAL(landform.freshwater_access)`, `SIGNAL(landform.river_valley)`, `SIGNAL(breakthrough.hydraulic_engineering)`

### 地质勘探 (`tech.geological_prospecting`)

- 铜锡配比与铸造 (`tech.bronze_casting`): `SIGNAL(resource.copper_ore)`, `SIGNAL(resource.tin_ore)`
- 自然铜冷锤 (`tech.natural_copper_working`): `SIGNAL(resource.copper_ore)`
- 自然铜辨识 (`tech.natural_copper_identification`): `SIGNAL(resource.copper_ore)`

### 大气式蒸汽机 (`tech.atmospheric_engine`)

- 矿井排水 (`tech.mine_drainage`): `SIGNAL(landform.freshwater_access)`
- 水力机械 (`tech.water_power`): `SIGNAL(landform.freshwater_access)`, `SIGNAL(breakthrough.hydraulic_engineering)`
- 运河工程 (`tech.canal_engineering`): `SIGNAL(landform.freshwater_access)`, `SIGNAL(breakthrough.hydraulic_engineering)`
- 灌溉 (`tech.irrigation`): `SIGNAL(landform.freshwater_access)`, `SIGNAL(breakthrough.hydraulic_engineering)`

### 学术社团 (`tech.learned_societies`)

- 螺旋压印 (`tech.screw_press_printing`): `SIGNAL(breakthrough.printing)`, `SIGNAL(breakthrough.print_calibration)`
- 特许大学 (`tech.chartered_universities`): `SIGNAL(breakthrough.printing)`, `SIGNAL(breakthrough.print_calibration)`

### 畜种改良 (`tech.livestock_breeding`)

- 牧业网络 (`tech.pastoral_networks`): `SIGNAL(bio.sheep)`, `SIGNAL(bio.horse)`, `SIGNAL(bio.cattle)`
- 皮纸制作 (`tech.parchment_making`): `SIGNAL(bio.sheep)`
- 马匹驯化 (`tech.horse_domestication`): `SIGNAL(bio.horse)`
- 畜群管理 (`tech.herd_management`): `SIGNAL(bio.sheep)`, `SIGNAL(bio.horse)`, `SIGNAL(bio.cattle)`

### 长期租约 (`tech.long_term_leases`)

- 政治经济学 (`tech.political_economy`): `SIGNAL(breakthrough.printing)`

### 精密仪器 (`tech.precision_instruments`)

- 陶器容器体系 (`tech.pottery`): `SIGNAL(breakthrough.kiln_temperature)`
- 窑烧控制 (`tech.kiln_firing`): `SIGNAL(breakthrough.kiln_temperature)`

### 地产测绘 (`tech.property_cadastre`)

- 长期租约 (`tech.long_term_leases`): `SIGNAL(breakthrough.printing)`, `SIGNAL(resource.arable_land)`
- 政治经济学 (`tech.political_economy`): `SIGNAL(breakthrough.printing)`

### 工业采煤 (`tech.industrial_coal_mining`)

- 高炉冶炼 (`tech.blast_furnace`): `SIGNAL(resource.coal)`
- 块炼铁 (`tech.iron_smelting`): `SIGNAL(resource.coal)`
- 坩埚钢 (`tech.crucible_steel`): `SIGNAL(resource.coal)`
- 煤矿平硐 (`tech.coal_adit_mining`): `SIGNAL(resource.coal)`
- 地表煤采集 (`tech.surface_coal_collection`): `SIGNAL(resource.coal)`
- 露头煤辨识 (`tech.coal_outcrop_identification`): `SIGNAL(resource.coal)`
- 煤矿开采 (`tech.coal_mining`): `SIGNAL(resource.coal)`

### 焦炭冶炼 (`tech.coke_smelting`)

- 工业采煤 (`tech.industrial_coal_mining`): `SIGNAL(resource.coal)`
- 高炉冶炼 (`tech.blast_furnace`): `SIGNAL(resource.iron_ore)`, `SIGNAL(resource.coal)`, `SIGNAL(breakthrough.metalworking)`
- 块炼铁 (`tech.iron_smelting`): `SIGNAL(resource.iron_ore)`, `SIGNAL(resource.coal)`
- 地表铁矿采集 (`tech.surface_iron_collection`): `SIGNAL(resource.iron_ore)`
- 铁矿辨识 (`tech.iron_ore_identification`): `SIGNAL(resource.iron_ore)`
- 机械工坊 (`tech.mechanical_workshops`): `SIGNAL(resource.iron_ore)`, `SIGNAL(breakthrough.metalworking)`
- 坩埚钢 (`tech.crucible_steel`): `SIGNAL(resource.iron_ore)`, `SIGNAL(resource.coal)`
- 煤矿平硐 (`tech.coal_adit_mining`): `SIGNAL(resource.coal)`
- 地表煤采集 (`tech.surface_coal_collection`): `SIGNAL(resource.coal)`
- 露头煤辨识 (`tech.coal_outcrop_identification`): `SIGNAL(resource.coal)`
- 煤矿开采 (`tech.coal_mining`): `SIGNAL(resource.coal)`

### 蒸汽抽水 (`tech.steam_pumping`)

- 蒸汽密封 (`tech.steam_sealing`): `SIGNAL(landform.freshwater_access)`
- 大气式蒸汽机 (`tech.atmospheric_engine`): `SIGNAL(landform.freshwater_access)`
- 矿井排水 (`tech.mine_drainage`): `SIGNAL(landform.freshwater_access)`
- 水力机械 (`tech.water_power`): `SIGNAL(landform.freshwater_access)`, `SIGNAL(landform.river_valley)`
- 运河工程 (`tech.canal_engineering`): `SIGNAL(landform.freshwater_access)`, `SIGNAL(landform.river_valley)`
- 灌溉 (`tech.irrigation`): `SIGNAL(landform.freshwater_access)`, `SIGNAL(landform.river_valley)`
- 洪水历法实践 (`tech.flood_calendar_practice`): `SIGNAL(landform.river_valley)`

### 铁路物流 (`tech.rail_logistics`)

- 蒸汽动力 (`tech.steam_power`): `SIGNAL(breakthrough.steam_power)`

### 工业化学 (`tech.industrial_chemistry`)

- 火药配制 (`tech.gunpowder_formulation`): `SIGNAL(resource.sulfur)`, `SIGNAL(resource.phosphate_rock)`, `SIGNAL(resource.saltpeter)`
- 卤水采集 (`tech.brine_collection`): `SIGNAL(resource.sulfur)`

### 肥料加工 (`tech.fertilizer_processing`)

- 工业化学 (`tech.industrial_chemistry`): `SIGNAL(resource.sulfur)`, `SIGNAL(resource.phosphate_rock)`, `SIGNAL(resource.saltpeter)`
- 火药配制 (`tech.gunpowder_formulation`): `SIGNAL(resource.sulfur)`, `SIGNAL(resource.phosphate_rock)`, `SIGNAL(resource.saltpeter)`
- 卤水采集 (`tech.brine_collection`): `SIGNAL(resource.sulfur)`

### 机械印刷 (`tech.mechanized_printing`)

- 蒸汽动力 (`tech.steam_power`): `SIGNAL(breakthrough.steam_power)`
- 螺旋压印 (`tech.screw_press_printing`): `SIGNAL(breakthrough.printing)`, `SIGNAL(breakthrough.print_calibration)`

### 纺织机械 (`tech.textile_machinery`)

- 织机织造 (`tech.loom_weaving`): `SIGNAL(bio.cotton)`, `SIGNAL(bio.flax)`
- 纤维捻制 (`tech.fiber_twisting`): `SIGNAL(bio.cotton)`, `SIGNAL(bio.flax)`

### 劳工组织 (`tech.labor_organization`)

- 工业组织 (`tech.industrial_organization`): `SIGNAL(breakthrough.industrial_organization)`, `SIGNAL(breakthrough.assembly_line)`, `SIGNAL(breakthrough.steam_power)`

### 管理层级 (`tech.managerial_hierarchy`)

- 工业组织 (`tech.industrial_organization`): `SIGNAL(breakthrough.industrial_organization)`, `SIGNAL(breakthrough.assembly_line)`, `SIGNAL(breakthrough.steam_power)`

### 流水线组织 (`tech.assembly_line`)

- 工业组织 (`tech.industrial_organization`): `SIGNAL(breakthrough.assembly_line)`, `SIGNAL(breakthrough.industrial_organization)`

### 蒸汽锯木 (`tech.steam_sawmilling`)

- 蒸汽动力 (`tech.steam_power`): `SIGNAL(breakthrough.steam_power)`
- 火种控制 (`tech.fire_control`): `SIGNAL(resource.timber)`
- 木炭烧制 (`tech.charcoal_burning`): `SIGNAL(resource.timber)`
- 手工锯木 (`tech.timber_sawing`): `SIGNAL(resource.timber)`

### 公司矿山 (`tech.corporate_mining`)

- 矿井排水 (`tech.mine_drainage`): `SIGNAL(breakthrough.mine_support)`
- 井筒开掘 (`tech.shaft_sinking`): `SIGNAL(breakthrough.mine_support)`
- 矿井木支护 (`tech.mine_timbering`): `SIGNAL(breakthrough.mine_support)`

### 工人合作工场 (`tech.worker_cooperatives`)

- 工业统计 (`tech.industrial_statistics`): `SIGNAL(breakthrough.industrial_organization)`, `SIGNAL(breakthrough.steam_power)`

### 合成肥料 (`tech.synthetic_fertilizer`)

- 肥料加工 (`tech.fertilizer_processing`): `SIGNAL(resource.sulfur)`, `SIGNAL(resource.phosphate_rock)`, `SIGNAL(resource.saltpeter)`
- 工业化学 (`tech.industrial_chemistry`): `SIGNAL(resource.sulfur)`, `SIGNAL(resource.phosphate_rock)`, `SIGNAL(resource.saltpeter)`
- 火药配制 (`tech.gunpowder_formulation`): `SIGNAL(resource.sulfur)`, `SIGNAL(resource.phosphate_rock)`, `SIGNAL(resource.saltpeter)`
- 卤水采集 (`tech.brine_collection`): `SIGNAL(resource.sulfur)`

### 石油开采 (`tech.petroleum_extraction`)

- 高炉冶炼 (`tech.blast_furnace`): `SIGNAL(resource.coal)`
- 块炼铁 (`tech.iron_smelting`): `SIGNAL(resource.coal)`
- 坩埚钢 (`tech.crucible_steel`): `SIGNAL(resource.coal)`

### 石油炼制 (`tech.petroleum_refining`)

- 石油开采 (`tech.petroleum_extraction`): `SIGNAL(resource.oil)`, `SIGNAL(resource.natural_gas)`, `SIGNAL(resource.coal)`
- 高炉冶炼 (`tech.blast_furnace`): `SIGNAL(resource.coal)`
- 块炼铁 (`tech.iron_smelting`): `SIGNAL(resource.coal)`
- 坩埚钢 (`tech.crucible_steel`): `SIGNAL(resource.coal)`

### 内燃机 (`tech.internal_combustion`)

- 石油炼制 (`tech.petroleum_refining`): `SIGNAL(resource.oil)`, `SIGNAL(resource.natural_gas)`, `SIGNAL(resource.coal)`
- 石油开采 (`tech.petroleum_extraction`): `SIGNAL(resource.oil)`, `SIGNAL(resource.natural_gas)`, `SIGNAL(resource.coal)`
- 高炉冶炼 (`tech.blast_furnace`): `SIGNAL(resource.coal)`
- 块炼铁 (`tech.iron_smelting`): `SIGNAL(resource.coal)`
- 坩埚钢 (`tech.crucible_steel`): `SIGNAL(resource.coal)`

### 现代医学 (`tech.modern_medicine`)

- 工业化学 (`tech.industrial_chemistry`): `SIGNAL(resource.phosphate_rock)`
- 火药配制 (`tech.gunpowder_formulation`): `SIGNAL(resource.phosphate_rock)`

### 电化学 (`tech.electrochemistry`)

- 工业化学 (`tech.industrial_chemistry`): `SIGNAL(resource.sulfur)`
- 火药配制 (`tech.gunpowder_formulation`): `SIGNAL(resource.sulfur)`
- 卤水采集 (`tech.brine_collection`): `SIGNAL(resource.sulfur)`
- 电磁感应 (`tech.electromagnetic_induction`): `SIGNAL(breakthrough.electrification)`

### 无线电 (`tech.radio`)

- 电磁感应 (`tech.electromagnetic_induction`): `SIGNAL(breakthrough.electrification)`

### 发电机 (`tech.electric_generation`)

- 蒸汽动力 (`tech.steam_power`): `SIGNAL(breakthrough.steam_power)`
- 电磁感应 (`tech.electromagnetic_induction`): `SIGNAL(breakthrough.electrification)`

### 电网 (`tech.electric_grid`)

- 发电机 (`tech.electric_generation`): `SIGNAL(breakthrough.electrification)`
- 高炉冶炼 (`tech.blast_furnace`): `SIGNAL(resource.coal)`
- 块炼铁 (`tech.iron_smelting`): `SIGNAL(resource.coal)`
- 坩埚钢 (`tech.crucible_steel`): `SIGNAL(resource.coal)`
- 电磁感应 (`tech.electromagnetic_induction`): `SIGNAL(breakthrough.electrification)`

### 电信 (`tech.telecommunications`)

- 电网 (`tech.electric_grid`): `SIGNAL(breakthrough.electrification)`
- 发电机 (`tech.electric_generation`): `SIGNAL(breakthrough.electrification)`
- 电磁感应 (`tech.electromagnetic_induction`): `SIGNAL(breakthrough.electrification)`
- 无线电 (`tech.radio`): `SIGNAL(breakthrough.electrification)`

### 电动机 (`tech.electric_motors`)

- 发电机 (`tech.electric_generation`): `SIGNAL(breakthrough.electrification)`
- 电磁感应 (`tech.electromagnetic_induction`): `SIGNAL(breakthrough.electrification)`

### 现代畜牧 (`tech.modern_husbandry`)

- 畜牧驯养 (`tech.animal_husbandry`): `SIGNAL(bio.sheep)`, `SIGNAL(bio.horse)`, `SIGNAL(bio.cattle)`

### 公司管理 (`tech.corporate_management`)

- 工业统计 (`tech.industrial_statistics`): `SIGNAL(breakthrough.industrial_organization)`
- 管理层级 (`tech.managerial_hierarchy`): `SIGNAL(breakthrough.industrial_organization)`, `SIGNAL(breakthrough.assembly_line)`
- 工业组织 (`tech.industrial_organization`): `SIGNAL(breakthrough.industrial_organization)`, `SIGNAL(breakthrough.assembly_line)`

### 石油钻探 (`tech.petroleum_drilling`)

- 石油开采 (`tech.petroleum_extraction`): `SIGNAL(resource.oil)`, `SIGNAL(resource.natural_gas)`, `SIGNAL(resource.coal)`
- 高炉冶炼 (`tech.blast_furnace`): `SIGNAL(resource.coal)`
- 块炼铁 (`tech.iron_smelting`): `SIGNAL(resource.coal)`
- 坩埚钢 (`tech.crucible_steel`): `SIGNAL(resource.coal)`

### 工业质量控制 (`tech.industrial_quality_control`)

- 工业统计 (`tech.industrial_statistics`): `SIGNAL(breakthrough.industrial_organization)`

### 先进冶金 (`tech.advanced_metallurgy`)

- 度量衡 (`tech.weights_and_measures`): `SIGNAL(breakthrough.metalworking)`
- 高炉冶炼 (`tech.blast_furnace`): `SIGNAL(resource.iron_ore)`, `SIGNAL(breakthrough.metalworking)`
- 块炼铁 (`tech.iron_smelting`): `SIGNAL(resource.iron_ore)`
- 地表铁矿采集 (`tech.surface_iron_collection`): `SIGNAL(resource.iron_ore)`
- 铁矿辨识 (`tech.iron_ore_identification`): `SIGNAL(resource.iron_ore)`

### 核裂变 (`tech.nuclear_fission`)

- 电磁感应 (`tech.electromagnetic_induction`): `SIGNAL(breakthrough.electrification)`

### 深层地球物理 (`tech.deep_geophysics`)

- 矿井排水 (`tech.mine_drainage`): `SIGNAL(landform.freshwater_access)`
- 水力机械 (`tech.water_power`): `SIGNAL(landform.freshwater_access)`, `SIGNAL(landform.river_valley)`
- 运河工程 (`tech.canal_engineering`): `SIGNAL(landform.freshwater_access)`, `SIGNAL(landform.river_valley)`
- 灌溉 (`tech.irrigation`): `SIGNAL(landform.freshwater_access)`, `SIGNAL(landform.river_valley)`
- 洪水历法实践 (`tech.flood_calendar_practice`): `SIGNAL(landform.river_valley)`
- 河运 (`tech.river_transport`): `SIGNAL(landform.freshwater_access)`, `SIGNAL(landform.river_valley)`

### 运筹学 (`tech.operations_research`)

- 工业组织 (`tech.industrial_organization`): `SIGNAL(breakthrough.industrial_organization)`, `SIGNAL(breakthrough.assembly_line)`
- 工业统计 (`tech.industrial_statistics`): `SIGNAL(breakthrough.industrial_organization)`

### 石油化工 (`tech.petrochemical_industry`)

- 电化学 (`tech.electrochemistry`): `SIGNAL(breakthrough.chemical_process_control)`, `SIGNAL(breakthrough.electrification)`
- 电磁感应 (`tech.electromagnetic_induction`): `SIGNAL(breakthrough.electrification)`
- 石油炼制 (`tech.petroleum_refining`): `SIGNAL(resource.oil)`
- 石油开采 (`tech.petroleum_extraction`): `SIGNAL(resource.oil)`

### 合成材料 (`tech.synthetic_materials`)

- 石油化工 (`tech.petrochemical_industry`): `SIGNAL(resource.oil)`
- 石油炼制 (`tech.petroleum_refining`): `SIGNAL(resource.oil)`, `SIGNAL(resource.natural_gas)`, `SIGNAL(resource.coal)`
- 石油开采 (`tech.petroleum_extraction`): `SIGNAL(resource.oil)`, `SIGNAL(resource.natural_gas)`, `SIGNAL(resource.coal)`
- 高炉冶炼 (`tech.blast_furnace`): `SIGNAL(resource.coal)`
- 块炼铁 (`tech.iron_smelting`): `SIGNAL(resource.coal)`
- 坩埚钢 (`tech.crucible_steel`): `SIGNAL(resource.coal)`

### 机械化采矿 (`tech.mechanized_mining`)

- 矿井排水 (`tech.mine_drainage`): `SIGNAL(breakthrough.mine_support)`
- 井筒开掘 (`tech.shaft_sinking`): `SIGNAL(breakthrough.mine_support)`
- 矿井木支护 (`tech.mine_timbering`): `SIGNAL(breakthrough.mine_support)`

### 核能 (`tech.nuclear_energy`)

- 电网 (`tech.electric_grid`): `SIGNAL(breakthrough.electrification)`
- 发电机 (`tech.electric_generation`): `SIGNAL(breakthrough.electrification)`
- 电磁感应 (`tech.electromagnetic_induction`): `SIGNAL(breakthrough.electrification)`
- 核裂变 (`tech.nuclear_fission`): `SIGNAL(breakthrough.electrification)`, `SIGNAL(breakthrough.chemical_process_control)`

### 特种合金 (`tech.specialty_alloys`)

- 先进冶金 (`tech.advanced_metallurgy`): `SIGNAL(resource.iron_ore)`, `SIGNAL(resource.copper_ore)`, `SIGNAL(breakthrough.metalworking)`
- 度量衡 (`tech.weights_and_measures`): `SIGNAL(breakthrough.metalworking)`
- 高炉冶炼 (`tech.blast_furnace`): `SIGNAL(resource.iron_ore)`, `SIGNAL(breakthrough.metalworking)`
- 块炼铁 (`tech.iron_smelting`): `SIGNAL(resource.iron_ore)`
- 地表铁矿采集 (`tech.surface_iron_collection`): `SIGNAL(resource.iron_ore)`
- 铁矿辨识 (`tech.iron_ore_identification`): `SIGNAL(resource.iron_ore)`

### 石化裂解 (`tech.petrochemical_cracking`)

- 工业化学 (`tech.industrial_chemistry`): `SIGNAL(resource.phosphate_rock)`
- 火药配制 (`tech.gunpowder_formulation`): `SIGNAL(resource.phosphate_rock)`
- 石油化工 (`tech.petrochemical_industry`): `SIGNAL(breakthrough.chemical_process_control)`, `SIGNAL(breakthrough.electrification)`
- 电化学 (`tech.electrochemistry`): `SIGNAL(breakthrough.chemical_process_control)`, `SIGNAL(breakthrough.electrification)`
- 电磁感应 (`tech.electromagnetic_induction`): `SIGNAL(breakthrough.electrification)`

### 塑料工程 (`tech.plastics_engineering`)

- 石油化工 (`tech.petrochemical_industry`): `SIGNAL(resource.oil)`
- 石油炼制 (`tech.petroleum_refining`): `SIGNAL(resource.oil)`, `SIGNAL(resource.natural_gas)`, `SIGNAL(resource.coal)`
- 石油开采 (`tech.petroleum_extraction`): `SIGNAL(resource.oil)`, `SIGNAL(resource.natural_gas)`, `SIGNAL(resource.coal)`
- 高炉冶炼 (`tech.blast_furnace`): `SIGNAL(resource.coal)`
- 块炼铁 (`tech.iron_smelting`): `SIGNAL(resource.coal)`
- 坩埚钢 (`tech.crucible_steel`): `SIGNAL(resource.coal)`

### 公司农业 (`tech.corporate_agribusiness`)

- 全球物流 (`tech.global_logistics`): `SIGNAL(breakthrough.industrial_organization)`, `SIGNAL(breakthrough.assembly_line)`
- 公司管理 (`tech.corporate_management`): `SIGNAL(breakthrough.electrification)`, `SIGNAL(breakthrough.industrial_organization)`, `SIGNAL(breakthrough.assembly_line)`
- 工业统计 (`tech.industrial_statistics`): `SIGNAL(breakthrough.industrial_organization)`
- 管理层级 (`tech.managerial_hierarchy`): `SIGNAL(breakthrough.industrial_organization)`, `SIGNAL(breakthrough.assembly_line)`
- 工业组织 (`tech.industrial_organization`): `SIGNAL(breakthrough.industrial_organization)`, `SIGNAL(breakthrough.assembly_line)`

### 核燃料循环 (`tech.nuclear_fuel_cycle`)

- 高炉冶炼 (`tech.blast_furnace`): `SIGNAL(resource.coal)`
- 块炼铁 (`tech.iron_smelting`): `SIGNAL(resource.coal)`
- 电网 (`tech.electric_grid`): `SIGNAL(resource.coal)`
- 坩埚钢 (`tech.crucible_steel`): `SIGNAL(resource.coal)`

### 合成纤维工程 (`tech.synthetic_fiber_engineering`)

- 石油化工 (`tech.petrochemical_industry`): `SIGNAL(resource.oil)`, `SIGNAL(breakthrough.chemical_process_control)`
- 电化学 (`tech.electrochemistry`): `SIGNAL(breakthrough.chemical_process_control)`
- 石油炼制 (`tech.petroleum_refining`): `SIGNAL(resource.oil)`
- 石油开采 (`tech.petroleum_extraction`): `SIGNAL(resource.oil)`

### 工业生态 (`tech.industrial_ecology`)

- 工业统计 (`tech.industrial_statistics`): `SIGNAL(breakthrough.industrial_organization)`
- 现代医学 (`tech.modern_medicine`): `SIGNAL(breakthrough.chemical_process_control)`

### 系统工程 (`tech.systems_engineering`)

- 工业统计 (`tech.industrial_statistics`): `SIGNAL(breakthrough.industrial_organization)`
- 运筹学 (`tech.operations_research`): `SIGNAL(breakthrough.industrial_organization)`
- 工业组织 (`tech.industrial_organization`): `SIGNAL(breakthrough.industrial_organization)`

### 软件工程 (`tech.software_engineering`)

- 信息论 (`tech.information_theory`): `SIGNAL(breakthrough.digital_control)`, `SIGNAL(breakthrough.automation)`

### 网络计算 (`tech.networked_computing`)

- 软件工程 (`tech.software_engineering`): `SIGNAL(breakthrough.digital_control)`, `SIGNAL(breakthrough.automation)`
- 信息论 (`tech.information_theory`): `SIGNAL(breakthrough.digital_control)`, `SIGNAL(breakthrough.automation)`

### 生物技术 (`tech.biotechnology`)

- 现代医学 (`tech.modern_medicine`): `SIGNAL(breakthrough.chemical_process_control)`

### 矿物光谱遥感 (`tech.mineral_spectral_survey`)

- 矿井排水 (`tech.mine_drainage`): `SIGNAL(breakthrough.mine_support)`
- 井筒开掘 (`tech.shaft_sinking`): `SIGNAL(breakthrough.mine_support)`
- 坩埚钢 (`tech.crucible_steel`): `SIGNAL(resource.iron_ore)`, `SIGNAL(resource.coal)`
- 电网 (`tech.electric_grid`): `SIGNAL(resource.coal)`
- 机械工坊 (`tech.mechanical_workshops`): `SIGNAL(resource.iron_ore)`
- 精密工程 (`tech.precision_engineering`): `SIGNAL(resource.iron_ore)`
- 高炉冶炼 (`tech.blast_furnace`): `SIGNAL(resource.iron_ore)`, `SIGNAL(resource.coal)`
- 块炼铁 (`tech.iron_smelting`): `SIGNAL(resource.iron_ore)`, `SIGNAL(resource.coal)`
- 地表铁矿采集 (`tech.surface_iron_collection`): `SIGNAL(resource.iron_ore)`
- 铁矿辨识 (`tech.iron_ore_identification`): `SIGNAL(resource.iron_ore)`

### 数值天气预报 (`tech.numerical_weather_prediction`)

- 卫星观测 (`tech.satellite_observation`): `SIGNAL(breakthrough.digital_control)`, `SIGNAL(breakthrough.climate_modeling)`

### 作物遥感 (`tech.crop_remote_sensing`)

- 卫星观测 (`tech.satellite_observation`): `SIGNAL(breakthrough.digital_control)`, `SIGNAL(breakthrough.climate_modeling)`

### 水文遥感 (`tech.hydrological_remote_sensing`)

- 深层地球物理 (`tech.deep_geophysics`): `SIGNAL(landform.freshwater_access)`, `SIGNAL(landform.river_valley)`
- 矿井排水 (`tech.mine_drainage`): `SIGNAL(landform.freshwater_access)`
- 水力机械 (`tech.water_power`): `SIGNAL(landform.freshwater_access)`, `SIGNAL(landform.river_valley)`, `SIGNAL(breakthrough.hydraulic_engineering)`
- 运河工程 (`tech.canal_engineering`): `SIGNAL(landform.freshwater_access)`, `SIGNAL(landform.river_valley)`, `SIGNAL(breakthrough.hydraulic_engineering)`
- 灌溉 (`tech.irrigation`): `SIGNAL(landform.freshwater_access)`, `SIGNAL(landform.river_valley)`, `SIGNAL(breakthrough.hydraulic_engineering)`
- 洪水历法实践 (`tech.flood_calendar_practice`): `SIGNAL(landform.river_valley)`
- 河运 (`tech.river_transport`): `SIGNAL(landform.freshwater_access)`, `SIGNAL(landform.river_valley)`
- 蒸汽密封 (`tech.steam_sealing`): `SIGNAL(landform.freshwater_access)`, `SIGNAL(breakthrough.hydraulic_engineering)`
- 大气式蒸汽机 (`tech.atmospheric_engine`): `SIGNAL(landform.freshwater_access)`, `SIGNAL(breakthrough.hydraulic_engineering)`

### 开放科学网络 (`tech.open_science_networks`)

- 学术社团 (`tech.learned_societies`): `SIGNAL(breakthrough.printing)`
- 螺旋压印 (`tech.screw_press_printing`): `SIGNAL(breakthrough.printing)`
- 特许大学 (`tech.chartered_universities`): `SIGNAL(breakthrough.printing)`
- 网络计算 (`tech.networked_computing`): `SIGNAL(breakthrough.digital_control)`
- 软件工程 (`tech.software_engineering`): `SIGNAL(breakthrough.digital_control)`
- 信息论 (`tech.information_theory`): `SIGNAL(breakthrough.digital_control)`
- 概率与统计 (`tech.probability_statistics`): `SIGNAL(breakthrough.printing)`

### 平台协调 (`tech.platform_coordination`)

- 网络计算 (`tech.networked_computing`): `SIGNAL(breakthrough.digital_control)`, `SIGNAL(breakthrough.automation)`
- 软件工程 (`tech.software_engineering`): `SIGNAL(breakthrough.digital_control)`, `SIGNAL(breakthrough.automation)`
- 信息论 (`tech.information_theory`): `SIGNAL(breakthrough.digital_control)`, `SIGNAL(breakthrough.automation)`

### 数字市场 (`tech.digital_marketplaces`)

- 网络计算 (`tech.networked_computing`): `SIGNAL(breakthrough.digital_control)`, `SIGNAL(breakthrough.automation)`
- 软件工程 (`tech.software_engineering`): `SIGNAL(breakthrough.digital_control)`, `SIGNAL(breakthrough.automation)`
- 信息论 (`tech.information_theory`): `SIGNAL(breakthrough.digital_control)`, `SIGNAL(breakthrough.automation)`

### 精准灌溉 (`tech.precision_irrigation`)

- 水利工程 (`tech.hydraulic_engineering`): `SIGNAL(landform.freshwater_access)`, `SIGNAL(landform.river_valley)`, `SIGNAL(breakthrough.hydraulic_engineering)`
- 灌溉测量 (`tech.irrigation_surveying`): `SIGNAL(landform.freshwater_access)`, `SIGNAL(landform.river_valley)`, `SIGNAL(breakthrough.hydraulic_engineering)`
- 灌溉 (`tech.irrigation`): `SIGNAL(landform.freshwater_access)`, `SIGNAL(landform.river_valley)`, `SIGNAL(breakthrough.hydraulic_engineering)`
- 洪水历法实践 (`tech.flood_calendar_practice`): `SIGNAL(landform.river_valley)`
- 运河工程 (`tech.canal_engineering`): `SIGNAL(landform.freshwater_access)`, `SIGNAL(landform.river_valley)`, `SIGNAL(breakthrough.hydraulic_engineering)`

### 传感器网络 (`tech.sensor_networks`)

- 半导体制造 (`tech.semiconductor_manufacturing`): `SIGNAL(breakthrough.digital_control)`
- 电磁感应 (`tech.electromagnetic_induction`): `SIGNAL(breakthrough.electrification)`
- 电信 (`tech.telecommunications`): `SIGNAL(breakthrough.electrification)`
- 电网 (`tech.electric_grid`): `SIGNAL(breakthrough.electrification)`
- 发电机 (`tech.electric_generation`): `SIGNAL(breakthrough.electrification)`
- 无线电 (`tech.radio`): `SIGNAL(breakthrough.electrification)`

### 生物信息学 (`tech.bioinformatics`)

- 生物技术 (`tech.biotechnology`): `SIGNAL(breakthrough.digital_control)`, `SIGNAL(breakthrough.chemical_process_control)`
- 现代医学 (`tech.modern_medicine`): `SIGNAL(breakthrough.chemical_process_control)`

### 神经网络 (`tech.neural_networks`)

- 软件工程 (`tech.software_engineering`): `SIGNAL(breakthrough.digital_control)`, `SIGNAL(breakthrough.automation)`
- 信息论 (`tech.information_theory`): `SIGNAL(breakthrough.digital_control)`, `SIGNAL(breakthrough.automation)`

### 人机协作 (`tech.human_machine_collaboration`)

- 平台协调 (`tech.platform_coordination`): `SIGNAL(breakthrough.digital_control)`, `SIGNAL(breakthrough.automation)`
- 网络计算 (`tech.networked_computing`): `SIGNAL(breakthrough.digital_control)`, `SIGNAL(breakthrough.automation)`
- 软件工程 (`tech.software_engineering`): `SIGNAL(breakthrough.digital_control)`, `SIGNAL(breakthrough.automation)`
- 信息论 (`tech.information_theory`): `SIGNAL(breakthrough.digital_control)`, `SIGNAL(breakthrough.automation)`

### 自主采矿 (`tech.autonomous_mining`)

- 矿井排水 (`tech.mine_drainage`): `SIGNAL(breakthrough.mine_support)`
- 井筒开掘 (`tech.shaft_sinking`): `SIGNAL(breakthrough.mine_support)`
- 矿物光谱遥感 (`tech.mineral_spectral_survey`): `SIGNAL(breakthrough.mine_support)`
- 机械化采矿 (`tech.mechanized_mining`): `SIGNAL(breakthrough.mine_support)`
- 矿井木支护 (`tech.mine_timbering`): `SIGNAL(breakthrough.mine_support)`

### 计算生物学 (`tech.computational_biology`)

- 生物信息学 (`tech.bioinformatics`): `SIGNAL(breakthrough.digital_control)`, `SIGNAL(breakthrough.chemical_process_control)`
- 生物技术 (`tech.biotechnology`): `SIGNAL(breakthrough.digital_control)`, `SIGNAL(breakthrough.chemical_process_control)`
- 现代医学 (`tech.modern_medicine`): `SIGNAL(breakthrough.chemical_process_control)`

### 气候建模 (`tech.climate_modeling`)

- 作物遥感 (`tech.crop_remote_sensing`): `SIGNAL(breakthrough.digital_control)`, `SIGNAL(breakthrough.climate_modeling)`
- 卫星观测 (`tech.satellite_observation`): `SIGNAL(breakthrough.digital_control)`, `SIGNAL(breakthrough.climate_modeling)`
- 数值天气预报 (`tech.numerical_weather_prediction`): `SIGNAL(breakthrough.digital_control)`, `SIGNAL(breakthrough.climate_modeling)`

### 智能电网 (`tech.smart_grid`)

- 平台协调 (`tech.platform_coordination`): `SIGNAL(breakthrough.digital_control)`
- 网络计算 (`tech.networked_computing`): `SIGNAL(breakthrough.digital_control)`
- 软件工程 (`tech.software_engineering`): `SIGNAL(breakthrough.digital_control)`
- 信息论 (`tech.information_theory`): `SIGNAL(breakthrough.digital_control)`
- 传感器网络 (`tech.sensor_networks`): `SIGNAL(breakthrough.digital_control)`
- 半导体制造 (`tech.semiconductor_manufacturing`): `SIGNAL(breakthrough.energy_control)`, `SIGNAL(breakthrough.digital_control)`

### 算法治理 (`tech.algorithmic_governance`)

- 平台协调 (`tech.platform_coordination`): `SIGNAL(breakthrough.digital_control)`, `SIGNAL(breakthrough.automation)`
- 网络计算 (`tech.networked_computing`): `SIGNAL(breakthrough.digital_control)`, `SIGNAL(breakthrough.automation)`
- 软件工程 (`tech.software_engineering`): `SIGNAL(breakthrough.digital_control)`, `SIGNAL(breakthrough.automation)`
- 信息论 (`tech.information_theory`): `SIGNAL(breakthrough.digital_control)`, `SIGNAL(breakthrough.automation)`

### 分布式智能 (`tech.distributed_intelligence`)

- 传感器网络 (`tech.sensor_networks`): `SIGNAL(breakthrough.digital_control)`
- 半导体制造 (`tech.semiconductor_manufacturing`): `SIGNAL(breakthrough.digital_control)`
- 网络计算 (`tech.networked_computing`): `SIGNAL(breakthrough.digital_control)`, `SIGNAL(breakthrough.automation)`
- 软件工程 (`tech.software_engineering`): `SIGNAL(breakthrough.digital_control)`, `SIGNAL(breakthrough.automation)`
- 信息论 (`tech.information_theory`): `SIGNAL(breakthrough.digital_control)`, `SIGNAL(breakthrough.automation)`

### 智能育种 (`tech.intelligent_breeding`)

- 生物信息学 (`tech.bioinformatics`): `SIGNAL(breakthrough.digital_control)`
- 生物技术 (`tech.biotechnology`): `SIGNAL(breakthrough.digital_control)`

### 自主物流 (`tech.autonomous_logistics`)

- 自动化物流 (`tech.automated_logistics`): `SIGNAL(breakthrough.automation)`, `SIGNAL(breakthrough.digital_control)`

### 智能科学代理 (`tech.scientific_agents`)

- 软件工程 (`tech.software_engineering`): `SIGNAL(breakthrough.digital_control)`, `SIGNAL(breakthrough.automation)`
- 信息论 (`tech.information_theory`): `SIGNAL(breakthrough.digital_control)`, `SIGNAL(breakthrough.automation)`
- 开放科学网络 (`tech.open_science_networks`): `SIGNAL(breakthrough.digital_control)`
- 网络计算 (`tech.networked_computing`): `SIGNAL(breakthrough.digital_control)`, `SIGNAL(breakthrough.automation)`

### 算法管理 (`tech.algorithmic_management`)

- 网络计算 (`tech.networked_computing`): `SIGNAL(breakthrough.digital_control)`
- 电信 (`tech.telecommunications`): `SIGNAL(breakthrough.industrial_organization)`
- 软件工程 (`tech.software_engineering`): `SIGNAL(breakthrough.digital_control)`
- 信息论 (`tech.information_theory`): `SIGNAL(breakthrough.digital_control)`
- 运筹学 (`tech.operations_research`): `SIGNAL(breakthrough.industrial_organization)`
- 工业组织 (`tech.industrial_organization`): `SIGNAL(breakthrough.industrial_organization)`
- 工业统计 (`tech.industrial_statistics`): `SIGNAL(breakthrough.industrial_organization)`
- 公司管理 (`tech.corporate_management`): `SIGNAL(breakthrough.industrial_organization)`
- 管理层级 (`tech.managerial_hierarchy`): `SIGNAL(breakthrough.industrial_organization)`

### 自适应灌溉 (`tech.adaptive_irrigation`)

- 精准灌溉 (`tech.precision_irrigation`): `SIGNAL(landform.freshwater_access)`, `SIGNAL(landform.river_valley)`, `SIGNAL(breakthrough.hydraulic_engineering)`
- 水利工程 (`tech.hydraulic_engineering`): `SIGNAL(landform.freshwater_access)`, `SIGNAL(landform.river_valley)`, `SIGNAL(breakthrough.hydraulic_engineering)`
- 灌溉测量 (`tech.irrigation_surveying`): `SIGNAL(landform.freshwater_access)`, `SIGNAL(landform.river_valley)`, `SIGNAL(breakthrough.hydraulic_engineering)`
- 灌溉 (`tech.irrigation`): `SIGNAL(landform.freshwater_access)`, `SIGNAL(landform.river_valley)`, `SIGNAL(breakthrough.hydraulic_engineering)`
- 洪水历法实践 (`tech.flood_calendar_practice`): `SIGNAL(landform.river_valley)`
- 运河工程 (`tech.canal_engineering`): `SIGNAL(landform.freshwater_access)`, `SIGNAL(landform.river_valley)`, `SIGNAL(breakthrough.hydraulic_engineering)`

### 知识合作社 (`tech.knowledge_cooperatives`)

- 开放科学网络 (`tech.open_science_networks`): `SIGNAL(breakthrough.digital_control)`
- 网络计算 (`tech.networked_computing`): `SIGNAL(breakthrough.digital_control)`, `SIGNAL(breakthrough.automation)`
- 软件工程 (`tech.software_engineering`): `SIGNAL(breakthrough.digital_control)`, `SIGNAL(breakthrough.automation)`
- 信息论 (`tech.information_theory`): `SIGNAL(breakthrough.digital_control)`, `SIGNAL(breakthrough.automation)`

### 自主劳动协调 (`tech.autonomous_labor_coordination`)

- 传感器网络 (`tech.sensor_networks`): `SIGNAL(breakthrough.digital_control)`
- 半导体制造 (`tech.semiconductor_manufacturing`): `SIGNAL(breakthrough.digital_control)`
- 工业质量控制 (`tech.industrial_quality_control`): `SIGNAL(breakthrough.industrial_organization)`
- 工业统计 (`tech.industrial_statistics`): `SIGNAL(breakthrough.industrial_organization)`
- 电信 (`tech.telecommunications`): `SIGNAL(breakthrough.industrial_organization)`
- 算法管理 (`tech.algorithmic_management`): `SIGNAL(breakthrough.digital_control)`, `SIGNAL(breakthrough.industrial_organization)`
- 网络计算 (`tech.networked_computing`): `SIGNAL(breakthrough.digital_control)`
- 软件工程 (`tech.software_engineering`): `SIGNAL(breakthrough.digital_control)`
- 信息论 (`tech.information_theory`): `SIGNAL(breakthrough.digital_control)`
- 运筹学 (`tech.operations_research`): `SIGNAL(breakthrough.industrial_organization)`
- 工业组织 (`tech.industrial_organization`): `SIGNAL(breakthrough.industrial_organization)`
- 公司管理 (`tech.corporate_management`): `SIGNAL(breakthrough.industrial_organization)`
- 管理层级 (`tech.managerial_hierarchy`): `SIGNAL(breakthrough.industrial_organization)`

## Repeated Reveal Templates

### 12 nodes: `ANY_OF(SIGNAL(breakthrough.digital_control), SIGNAL(breakthrough.automation))`

- `tech.information_theory` - 信息论 (information)
- `tech.software_engineering` - 软件工程 (information)
- `tech.networked_computing` - 网络计算 (information)
- `tech.platform_coordination` - 平台协调 (information)
- `tech.digital_marketplaces` - 数字市场 (information)
- `tech.geographic_information_systems` - 地理信息系统 (information)
- `tech.neural_networks` - 神经网络 (intelligent)
- `tech.human_machine_collaboration` - 人机协作 (intelligent)
- `tech.algorithmic_governance` - 算法治理 (intelligent)
- `tech.distributed_intelligence` - 分布式智能 (intelligent)
- `tech.scientific_agents` - 智能科学代理 (intelligent)
- `tech.knowledge_cooperatives` - 知识合作社 (intelligent)

### 9 nodes: `ANY_OF(SIGNAL(landform.freshwater_access), SIGNAL(landform.river_valley), SIGNAL(breakthrough.hydraulic_engineering))`

- `tech.irrigation` - 灌溉 (agrarian)
- `tech.irrigation_surveying` - 灌溉测量 (agrarian)
- `tech.canal_engineering` - 运河工程 (kingdom)
- `tech.water_power` - 水力机械 (empire)
- `tech.urban_waterworks` - 城市水务 (empire)
- `tech.hydraulic_engineering` - 水利工程 (enlightenment)
- `tech.hydrological_remote_sensing` - 水文遥感 (information)
- `tech.precision_irrigation` - 精准灌溉 (information)
- `tech.adaptive_irrigation` - 自适应灌溉 (intelligent)

### 8 nodes: `ANY_OF(SIGNAL(bio.maize), SIGNAL(contact.maize))`

- `tech.maize_identification` - 玉米辨识 (stone)
- `tech.wild_maize_collection` - 野生玉米采集 (stone)
- `tech.maize_seed_saving` - 玉米留种 (stone)
- `tech.maize_propagation` - 玉米繁育 (stone)
- `tech.maize_garden_horticulture` - 玉米园圃 (agrarian)
- `tech.swidden_maize_cultivation` - 刀耕火种玉米 (agrarian)
- `tech.rainfed_maize_cultivation` - 雨养玉米田 (agrarian)
- `tech.flood_recession_maize` - 退水玉米地 (agrarian)

### 8 nodes: `ANY_OF(SIGNAL(bio.wheat), SIGNAL(contact.wheat))`

- `tech.wheat_identification` - 小麦辨识 (stone)
- `tech.wild_wheat_collection` - 野生谷穗采集 (stone)
- `tech.wheat_seed_saving` - 小麦留种 (stone)
- `tech.wheat_propagation` - 小麦繁育 (stone)
- `tech.rainfed_wheat_cultivation` - 雨养小麦田 (agrarian)
- `tech.flood_recession_wheat` - 退水小麦地 (agrarian)
- `tech.dryland_wheat_cultivation` - 旱作小麦田 (agrarian)
- `tech.grain_baking` - 谷物烘焙 (agrarian)

### 7 nodes: `ANY_OF(SIGNAL(bio.potato), SIGNAL(contact.potato))`

- `tech.potato_identification` - 块茎辨识 (stone)
- `tech.wild_tuber_collection` - 野生块茎挖掘 (stone)
- `tech.tuber_storage` - 块茎保存 (stone)
- `tech.potato_propagation` - 块茎繁育 (stone)
- `tech.ridge_tuber_cultivation` - 垄作块茎 (agrarian)
- `tech.frost_protected_storage` - 防霜窖藏 (agrarian)
- `tech.highland_tuber_farming` - 高地块茎农业 (agrarian)

### 7 nodes: `SIGNAL(resource.coal)`

- `tech.surface_coal_use` - 地表煤利用 (kingdom)
- `tech.coal_outcrop_identification` - 露头煤辨识 (kingdom)
- `tech.surface_coal_collection` - 地表煤采集 (kingdom)
- `tech.coal_mining` - 煤矿开采 (empire)
- `tech.coal_adit_mining` - 煤矿平硐 (empire)
- `tech.coal_geology` - 煤层地质 (enlightenment)
- `tech.industrial_coal_mining` - 工业采煤 (steam)

### 7 nodes: `ANY_OF(SIGNAL(breakthrough.printing), SIGNAL(breakthrough.print_calibration))`

- `tech.chartered_universities` - 特许大学 (empire)
- `tech.indentured_contracts` - 契约劳工制度 (exploration)
- `tech.scientific_classification` - 科学分类 (enlightenment)
- `tech.political_economy` - 政治经济学 (enlightenment)
- `tech.probability_statistics` - 概率与统计 (enlightenment)
- `tech.learned_societies` - 学术社团 (enlightenment)
- `tech.wage_contracts` - 工资契约 (enlightenment)

### 7 nodes: `ANY_OF(SIGNAL(resource.oil), SIGNAL(resource.natural_gas), SIGNAL(resource.coal))`

- `tech.petroleum_extraction` - 石油开采 (electrical)
- `tech.petroleum_refining` - 石油炼制 (electrical)
- `tech.internal_combustion` - 内燃机 (electrical)
- `tech.petroleum_drilling` - 石油钻探 (electrical)
- `tech.synthetic_materials` - 合成材料 (atomic)
- `tech.plastics_engineering` - 塑料工程 (atomic)
- `tech.nuclear_fuel_cycle` - 核燃料循环 (atomic)

### 6 nodes: `ANY_OF(SIGNAL(breakthrough.seed_saving), SIGNAL(resource.fertile_soil), SIGNAL(weather.repeated_crop_failure))`

- `tech.seasonal_foraging` - 季节性采集 (stone)
- `tech.food_storage` - 食物储藏 (stone)
- `tech.hearth_preservation` - 炉火保存 (stone)
- `tech.fermentation` - 发酵保存 (agrarian)
- `tech.canning` - 罐藏 (enlightenment)
- `tech.mass_production` - 大规模生产 (electrical)

### 6 nodes: `ANY_OF(SIGNAL(bio.rice), SIGNAL(contact.rice))`

- `tech.rice_identification` - 稻类辨识 (stone)
- `tech.wild_rice_collection` - 野生稻采集 (stone)
- `tech.rice_seed_saving` - 稻种留存 (stone)
- `tech.upland_rice_propagation` - 旱稻繁育 (agrarian)
- `tech.wetland_rice_gardening` - 湿地稻园 (agrarian)
- `tech.rice_paddy_cultivation` - 水田稻作 (agrarian)

### 5 nodes: `SIGNAL(resource.timber)`

- `tech.fire_control` - 火种控制 (stone)
- `tech.deadwood_collection` - 枯枝采集 (stone)
- `tech.charcoal_burning` - 木炭烧制 (stone)
- `tech.timber_sawing` - 手工锯木 (agrarian)
- `tech.bark_paper_making` - 树皮纸 (kingdom)

### 5 nodes: `SIGNAL(resource.clay)`

- `tech.clay_identification` - 黏土辨识 (stone)
- `tech.earth_building` - 土建筑 (stone)
- `tech.clay_preparation` - 黏土调制 (stone)
- `tech.hand_pottery` - 手制陶器 (stone)
- `tech.adobe_making` - 日晒土坯 (agrarian)

### 5 nodes: `ANY_OF(SIGNAL(bio.flax), SIGNAL(bio.cotton), SIGNAL(bio.bast_fiber))`

- `tech.fiber_twisting` - 纤维捻制 (stone)
- `tech.weaving` - 织造 (agrarian)
- `tech.loom_weaving` - 织机织造 (agrarian)
- `tech.hand_spinning` - 手工纺纱 (agrarian)
- `tech.plant_fiber_papermaking` - 植物纤维抄纸 (kingdom)

### 5 nodes: `ANY_OF(SIGNAL(bio.sheep), SIGNAL(bio.horse), SIGNAL(bio.cattle))`

- `tech.herd_management` - 畜群管理 (stone)
- `tech.pastoralism` - 游牧放牧 (agrarian)
- `tech.pastoral_networks` - 牧业网络 (empire)
- `tech.livestock_breeding` - 畜种改良 (enlightenment)
- `tech.modern_husbandry` - 现代畜牧 (electrical)

### 5 nodes: `ANY_OF(SIGNAL(resource.sulfur), SIGNAL(resource.phosphate_rock), SIGNAL(resource.saltpeter))`

- `tech.gunpowder_formulation` - 火药配制 (empire)
- `tech.gunpowder_weapons` - 火药武器 (exploration)
- `tech.industrial_chemistry` - 工业化学 (steam)
- `tech.fertilizer_processing` - 肥料加工 (steam)
- `tech.synthetic_fertilizer` - 合成肥料 (electrical)

### 5 nodes: `ANY_OF(SIGNAL(landform.coast), SIGNAL(landform.coastal_estuary), SIGNAL(contact.maritime_vessel), SIGNAL(breakthrough.maritime_operations))`

- `tech.magnetic_navigation` - 磁针导航 (empire)
- `tech.oceanic_navigation` - 远洋航海 (exploration)
- `tech.oceanic_ship_design` - 远洋船舶设计 (exploration)
- `tech.coastal_shipyards` - 海岸船厂 (exploration)
- `tech.oceanic_provisioning` - 远洋补给 (exploration)

### 4 nodes: `SIGNAL(resource.wild_game)`

- `tech.hunting` - 狩猎 (stone)
- `tech.animal_tracking` - 动物追踪 (stone)
- `tech.hide_scraping` - 生皮刮制 (stone)
- `tech.fur_sewing` - 毛皮缝制 (stone)

### 4 nodes: `ANY_OF(SIGNAL(resource.fertile_soil), SIGNAL(landform.river_valley), SIGNAL(breakthrough.seed_saving))`

- `tech.household_production` - 家庭生产 (stone)
- `tech.household_landholding` - 家庭土地占有 (agrarian)
- `tech.communal_field_coordination` - 共同田协调 (agrarian)
- `tech.public_storehouses` - 公共仓储 (agrarian)

### 4 nodes: `ANY_OF(SIGNAL(bio.cotton), SIGNAL(contact.cotton))`

- `tech.cotton_identification` - 棉花辨识 (stone)
- `tech.wild_cotton_collection` - 野生棉铃采集 (stone)
- `tech.cotton_ginning` - 棉花去籽 (agrarian)
- `tech.cotton_gardening` - 棉花园圃 (agrarian)

### 4 nodes: `ANY_OF(SIGNAL(bio.spice), SIGNAL(contact.spice))`

- `tech.spice_identification` - 香料植物辨识 (stone)
- `tech.wild_spice_collection` - 野生香料采集 (stone)
- `tech.spice_cultivation` - 香料栽培 (agrarian)
- `tech.spice_shade_gardening` - 遮阴香料园 (agrarian)

### 4 nodes: `ANY_OF(SIGNAL(bio.rubber), SIGNAL(contact.rubber))`

- `tech.rubber_identification` - 橡胶树辨识 (stone)
- `tech.wild_latex_tapping` - 野生割胶 (stone)
- `tech.rubber_working` - 天然橡胶加工 (agrarian)
- `tech.latex_smoke_coagulation` - 乳胶烟熏凝固 (agrarian)

### 4 nodes: `ANY_OF(SIGNAL(bio.wheat), SIGNAL(bio.maize), SIGNAL(bio.rice))`

- `tech.grain_threshing` - 谷物脱粒 (agrarian)
- `tech.tenant_cereal_farming` - 佃作谷物 (kingdom)
- `tech.manorial_cereal_farming` - 庄园谷物经营 (empire)
- `tech.estate_cereal_management` - 庄园谷物核算 (empire)

### 4 nodes: `ANY_OF(SIGNAL(resource.arable_land), SIGNAL(resource.fertile_soil), SIGNAL(breakthrough.seed_saving))`

- `tech.customary_tenancy` - 习惯佃作 (kingdom)
- `tech.sharecropping` - 分成租佃 (kingdom)
- `tech.manorial_jurisdiction` - 庄园司法 (empire)
- `tech.commercial_estates` - 商业农庄 (exploration)

### 4 nodes: `SIGNAL(breakthrough.mine_support)`

- `tech.mine_ventilation` - 矿井通风 (empire)
- `tech.shaft_sinking` - 井筒开掘 (exploration)
- `tech.deep_mining` - 深井采矿 (exploration)
- `tech.corporate_mining` - 公司矿山 (steam)

### 4 nodes: `ANY_OF(SIGNAL(breakthrough.industrial_organization), SIGNAL(breakthrough.assembly_line), SIGNAL(breakthrough.steam_power))`

- `tech.industrial_organization` - 工业组织 (steam)
- `tech.labor_organization` - 劳工组织 (steam)
- `tech.managerial_hierarchy` - 管理层级 (steam)
- `tech.worker_cooperatives` - 工人合作工场 (steam)

### 4 nodes: `ANY_OF(SIGNAL(breakthrough.electrification), SIGNAL(breakthrough.industrial_organization), SIGNAL(breakthrough.assembly_line))`

- `tech.telecommunications` - 电信 (electrical)
- `tech.corporate_management` - 公司管理 (electrical)
- `tech.corporate_agribusiness` - 公司农业 (atomic)
- `tech.collective_agriculture` - 集体农业 (atomic)

### 4 nodes: `ANY_OF(SIGNAL(breakthrough.digital_control), SIGNAL(breakthrough.climate_modeling))`

- `tech.satellite_observation` - 卫星观测 (information)
- `tech.numerical_weather_prediction` - 数值天气预报 (information)
- `tech.crop_remote_sensing` - 作物遥感 (information)
- `tech.climate_modeling` - 气候建模 (intelligent)

### 3 nodes: `ANY_OF(SIGNAL(resource.gold_ore), SIGNAL(resource.silver_ore))`

- `tech.early_trade` - 早期贸易 (stone)
- `tech.market_institutions` - 市场制度 (kingdom)
- `tech.currency` - 货币 (kingdom)

### 3 nodes: `ANY_OF(SIGNAL(bio.flax), SIGNAL(bio.bast_fiber), SIGNAL(contact.flax))`

- `tech.flax_identification` - 亚麻与韧皮辨识 (stone)
- `tech.wild_flax_collection` - 野生韧皮采集 (stone)
- `tech.flax_retting` - 沤麻 (agrarian)

### 3 nodes: `ANY_OF(SIGNAL(resource.paddy_land), SIGNAL(landform.floodplain), SIGNAL(breakthrough.paddy_control))`

- `tech.paddy_bunding` - 水田畦埂 (agrarian)
- `tech.tenant_paddy_management` - 佃作水田 (kingdom)
- `tech.estate_paddy_management` - 庄园水田核算 (empire)

### 3 nodes: `ANY_OF(SIGNAL(bio.potato), SIGNAL(contact.potato), SIGNAL(breakthrough.terrace_maintenance))`

- `tech.crop_acclimatization` - 作物驯化移植 (exploration)
- `tech.crop_breeding` - 系统育种 (enlightenment)
- `tech.cold_chain` - 冷链 (electrical)

### 3 nodes: `SIGNAL(breakthrough.electrification)`

- `tech.electromagnetic_induction` - 电磁感应 (electrical)
- `tech.radio` - 无线电 (electrical)
- `tech.refrigeration` - 机械制冷 (electrical)

### 3 nodes: `ANY_OF(SIGNAL(breakthrough.digital_control), SIGNAL(breakthrough.chemical_process_control))`

- `tech.biotechnology` - 生物技术 (information)
- `tech.bioinformatics` - 生物信息学 (information)
- `tech.computational_biology` - 计算生物学 (intelligent)

### 2 nodes: `ANY_OF(SIGNAL(weather.monsoon), SIGNAL(weather.frost), SIGNAL(landform.river_valley))`

- `tech.oral_tradition` - 口述传统 (stone)
- `tech.seasonal_calendar` - 季节历 (stone)

### 2 nodes: `SIGNAL(resource.copper_ore)`

- `tech.natural_copper_identification` - 自然铜辨识 (stone)
- `tech.natural_copper_working` - 自然铜冷锤 (stone)

### 2 nodes: `ANY_OF(SIGNAL(resource.copper_ore), SIGNAL(breakthrough.metalworking))`

- `tech.copper_annealing` - 铜退火 (stone)
- `tech.copper_metallurgy` - 木炭坩埚炼铜 (agrarian)

### 2 nodes: `ANY_OF(SIGNAL(resource.stone), SIGNAL(resource.flint), SIGNAL(resource.clay))`

- `tech.ground_stone_tools` - 磨制石器 (stone)
- `tech.masonry` - 砌体建筑 (kingdom)

### 2 nodes: `SIGNAL(resource.silver_ore)`

- `tech.silver_vein_identification` - 地表银脉辨识 (stone)
- `tech.surface_silver_collection` - 地表银矿拣采 (stone)

### 2 nodes: `ANY_OF(SIGNAL(bio.reed), SIGNAL(landform.marsh), SIGNAL(landform.freshwater_access))`

- `tech.reed_identification` - 芦苇辨识 (stone)
- `tech.reed_harvesting` - 芦苇收割 (stone)

### 2 nodes: `SIGNAL(resource.pasture)`

- `tech.turf_cutting` - 草皮切割 (stone)
- `tech.pastoral_route_memory` - 牧群路线记忆 (stone)

### 2 nodes: `SIGNAL(bio.sheep)`

- `tech.felt_making` - 羊毛毡制 (stone)
- `tech.wool_husbandry` - 毛用畜牧 (agrarian)

### 2 nodes: `ANY_OF(SIGNAL(resource.arable_land), SIGNAL(weather.drought), SIGNAL(breakthrough.rainfed_adaptation))`

- `tech.rainfed_field_system` - 雨养田体系 (agrarian)
- `tech.dryland_water_retention` - 旱作保水 (agrarian)

### 2 nodes: `ANY_OF(SIGNAL(resource.wild_game), SIGNAL(bio.sheep))`

- `tech.hide_tanning` - 皮革鞣制 (agrarian)
- `tech.parchment_making` - 皮纸制作 (kingdom)

### 2 nodes: `ANY_OF(SIGNAL(resource.clay), SIGNAL(resource.timber))`

- `tech.scholarly_academies` - 学术机构 (kingdom)
- `tech.estate_accounting` - 庄园核算 (kingdom)

### 2 nodes: `SIGNAL(resource.iron_ore)`

- `tech.iron_ore_identification` - 铁矿辨识 (kingdom)
- `tech.surface_iron_collection` - 地表铁矿采集 (kingdom)

### 2 nodes: `ANY_OF(SIGNAL(resource.iron_ore), SIGNAL(resource.coal))`

- `tech.iron_smelting` - 块炼铁 (kingdom)
- `tech.crucible_steel` - 坩埚钢 (empire)

### 2 nodes: `ANY_OF(SIGNAL(resource.fertile_soil), SIGNAL(breakthrough.seed_saving), SIGNAL(weather.repeated_crop_failure))`

- `tech.urban_food_supply` - 城市食物供应 (kingdom)
- `tech.regional_granaries` - 区域粮仓 (empire)

### 2 nodes: `ANY_OF(SIGNAL(resource.iron_ore), SIGNAL(resource.coal), SIGNAL(breakthrough.metalworking))`

- `tech.blast_furnace` - 高炉冶炼 (empire)
- `tech.coke_smelting` - 焦炭冶炼 (steam)

### 2 nodes: `ANY_OF(SIGNAL(breakthrough.printing), SIGNAL(resource.timber))`

- `tech.rag_paper_making` - 破布纸 (empire)
- `tech.woodblock_printing` - 木版印刷 (empire)

### 2 nodes: `ANY_OF(SIGNAL(breakthrough.metalworking), SIGNAL(breakthrough.kiln_temperature))`

- `tech.guild_apprenticeship` - 行会学徒制 (empire)
- `tech.precision_instruments` - 精密仪器 (enlightenment)

### 2 nodes: `ANY_OF(SIGNAL(landform.coast), SIGNAL(breakthrough.maritime_operations), SIGNAL(breakthrough.printing))`

- `tech.mercantile_networks` - 商业网络 (exploration)
- `tech.chartered_companies` - 特许商社 (exploration)

### 2 nodes: `ANY_OF(SIGNAL(bio.wheat), SIGNAL(contact.wheat), SIGNAL(breakthrough.rainfed_adaptation))`

- `tech.crop_transplantation` - 作物移植适应 (exploration)
- `tech.mechanical_threshing` - 机械脱粒 (steam)

### 2 nodes: `ANY_OF(SIGNAL(breakthrough.metalworking), SIGNAL(breakthrough.kiln_temperature), SIGNAL(resource.iron_ore))`

- `tech.precision_engineering` - 精密工程 (enlightenment)
- `tech.mechanical_workshops` - 机械工坊 (enlightenment)

### 2 nodes: `ANY_OF(SIGNAL(landform.freshwater_access), SIGNAL(landform.stable_wind_corridor), SIGNAL(breakthrough.hydraulic_engineering))`

- `tech.atmospheric_engine` - 大气式蒸汽机 (enlightenment)
- `tech.steam_sealing` - 蒸汽密封 (enlightenment)

### 2 nodes: `ANY_OF(SIGNAL(resource.fertile_soil), SIGNAL(breakthrough.seed_saving), SIGNAL(breakthrough.rainfed_adaptation))`

- `tech.soil_experimentation` - 土壤实验 (enlightenment)
- `tech.agricultural_cooperatives` - 农业合作社 (enlightenment)

### 2 nodes: `ANY_OF(SIGNAL(breakthrough.printing), SIGNAL(resource.arable_land))`

- `tech.long_term_leases` - 长期租约 (enlightenment)
- `tech.property_cadastre` - 地产测绘 (enlightenment)

### 2 nodes: `ANY_OF(SIGNAL(landform.freshwater_access), SIGNAL(landform.river_valley), SIGNAL(breakthrough.watershed_management))`

- `tech.steam_pumping` - 蒸汽抽水 (steam)
- `tech.deep_geophysics` - 深层地球物理 (atomic)

### 2 nodes: `ANY_OF(SIGNAL(breakthrough.steam_power), SIGNAL(breakthrough.industrial_organization))`

- `tech.rail_logistics` - 铁路物流 (steam)
- `tech.industrial_statistics` - 工业统计 (steam)

### 2 nodes: `ANY_OF(SIGNAL(breakthrough.assembly_line), SIGNAL(breakthrough.industrial_organization))`

- `tech.assembly_line` - 流水线组织 (steam)
- `tech.industrial_quality_control` - 工业质量控制 (electrical)

### 2 nodes: `ANY_OF(SIGNAL(breakthrough.chemical_process_control), SIGNAL(breakthrough.electrification), SIGNAL(resource.phosphate_rock))`

- `tech.modern_medicine` - 现代医学 (electrical)
- `tech.petrochemical_cracking` - 石化裂解 (atomic)

### 2 nodes: `ANY_OF(SIGNAL(resource.iron_ore), SIGNAL(resource.copper_ore), SIGNAL(breakthrough.metalworking))`

- `tech.advanced_metallurgy` - 先进冶金 (atomic)
- `tech.specialty_alloys` - 特种合金 (atomic)

### 2 nodes: `ANY_OF(SIGNAL(breakthrough.electrification), SIGNAL(breakthrough.chemical_process_control))`

- `tech.nuclear_fission` - 核裂变 (atomic)
- `tech.nuclear_energy` - 核能 (atomic)

### 2 nodes: `ANY_OF(SIGNAL(breakthrough.industrial_organization), SIGNAL(breakthrough.assembly_line))`

- `tech.operations_research` - 运筹学 (atomic)
- `tech.global_logistics` - 全球物流 (atomic)

### 2 nodes: `ANY_OF(SIGNAL(breakthrough.automation), SIGNAL(breakthrough.digital_control))`

- `tech.automated_logistics` - 自动化物流 (information)
- `tech.autonomous_logistics` - 自主物流 (intelligent)

### 2 nodes: `ANY_OF(SIGNAL(breakthrough.digital_control), SIGNAL(breakthrough.industrial_organization))`

- `tech.algorithmic_management` - 算法管理 (intelligent)
- `tech.autonomous_labor_coordination` - 自主劳动协调 (intelligent)

## Audit Boundary

- This audit does not judge historical plausibility from names alone.
- It treats completed hard-prerequisite technologies and their persistent reveal/research evidence as historical facts.
- It does not assume transient non-persistent facts, unsupported predicate kinds, or future diplomacy/trade behavior.
- It does not modify the catalog or propose replacement conditions.

