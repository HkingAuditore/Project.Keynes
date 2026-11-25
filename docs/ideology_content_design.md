# 当前理念卡内容设计（生成器权威表）

当前生成器定义 105 张卡；运行时目录可能因能力开关暂存部分卡。等级：初识 / 通晓 / 化育；阈值：[0, 262144, 786432]；倍率：[65536, 104858, 144179]

## 采集游群 (`forager_band`)
- 学派：农本；时代：石器时代；稀有度：1
- 卡面描述：按季节轮换营地，林下的坚果、块根与浆果养活了整个部族。
- 等级项：`[[['country.output.terrain.forest.agriculture_factor', 1.08], ['country.output.terrain.jungle.agriculture_factor', 1.08], ['country.resource.wild_game.use_factor', 1.05]], [['country.output.terrain.forest.agriculture_factor', 1.12], ['country.output.terrain.jungle.agriculture_factor', 1.12], ['country.resource.wild_game.use_factor', 1.05]], [['country.output.terrain.forest.agriculture_factor', 1.12], ['country.output.terrain.jungle.agriculture_factor', 1.12], ['country.resource.wild_game.use_factor', 1.05]]]`

## 狩猎传统 (`hunting_tradition`)
- 学派：动员；时代：石器时代；稀有度：1
- 卡面描述：以围猎、陷阱与分工分配肉食，青壮年在协作中学会统一号令。
- 基础项：`[['country.resource.wild_game.use_factor', 1.06]]`
- 程序等级项：`[[{'key': 'hunting_tradition_l1', 'summary': '主产野味、且单一职业占比 ≥60% 的地块：野味产出 +12%', 'tags': ['cell.produces.game_meat'], 'cmds': [{'modifier': 'economy.city.good.game_meat.output_factor', 'value': 0.12, 'duration_days': -1, 'stacks': 1, 'domain': None, 'magnitude_q16': None}], 'conds': [{'op': 2, 'arg0': 52, 'value_q16': 39322}], 'selector': 12, 'selector_cap': 32, 'selector_param1': 0, 'stack_policy': 0, 'max_stacks': 1, 'stacks': 1, 'lifecycle': 0, 'duration_days': -1, 'target_domain': 2, 'priority': 0, 'ramp': None, 'radius': 0, 'cap': 0, 'per_source': None}], [{'key': 'hunting_tradition_l2', 'summary': '主产野味、且单一职业占比 ≥60% 的地块：野味产出 +16%', 'tags': ['cell.produces.game_meat'], 'cmds': [{'modifier': 'economy.city.good.game_meat.output_factor', 'value': 0.16, 'duration_days': -1, 'stacks': 1, 'domain': None, 'magnitude_q16': None}], 'conds': [{'op': 2, 'arg0': 52, 'value_q16': 39322}], 'selector': 12, 'selector_cap': 32, 'selector_param1': 0, 'stack_policy': 0, 'max_stacks': 1, 'stacks': 1, 'lifecycle': 0, 'duration_days': -1, 'target_domain': 2, 'priority': 0, 'ramp': None, 'radius': 0, 'cap': 0, 'per_source': None}], [{'key': 'hunting_tradition_l3', 'summary': '主产野味、且单一职业占比 ≥60% 的地块：野味产出 +20%', 'tags': ['cell.produces.game_meat'], 'cmds': [{'modifier': 'economy.city.good.game_meat.output_factor', 'value': 0.2, 'duration_days': -1, 'stacks': 1, 'domain': None, 'magnitude_q16': None}], 'conds': [{'op': 2, 'arg0': 52, 'value_q16': 39322}], 'selector': 12, 'selector_cap': 32, 'selector_param1': 0, 'stack_policy': 0, 'max_stacks': 1, 'stacks': 1, 'lifecycle': 0, 'duration_days': -1, 'target_domain': 2, 'priority': 0, 'ramp': None, 'radius': 0, 'cap': 0, 'per_source': None}]]`

## 打制石器 (`flint_knapping`)
- 学派：工造；时代：石器时代；稀有度：1
- 研究信号：resource.flint
- 卡面描述：打击石核取刃，形状统一的石器让各项劳作都更省力。
- 基础项：`[['country.resource.flint.use_factor', 1.08]]`
- 程序等级项：`[[{'key': 'flint_knapping_l1', 'summary': '主产燧石的地块周围 1 格（最多 32 格）：全部产出 +4%', 'tags': ['cell.produces.flint'], 'cmds': [{'modifier': 'economy.city.output_factor', 'value': 0.04, 'duration_days': -1, 'stacks': 1, 'domain': None, 'magnitude_q16': None}], 'conds': [], 'selector': 14, 'selector_cap': 32, 'selector_param1': 0, 'stack_policy': 0, 'max_stacks': 1, 'stacks': 1, 'lifecycle': 0, 'duration_days': -1, 'target_domain': 2, 'priority': 0, 'ramp': None, 'radius': 0, 'cap': 0, 'per_source': None}], [{'key': 'flint_knapping_l2', 'summary': '主产燧石的地块周围 1 格（最多 32 格）：全部产出 +6%', 'tags': ['cell.produces.flint'], 'cmds': [{'modifier': 'economy.city.output_factor', 'value': 0.06, 'duration_days': -1, 'stacks': 1, 'domain': None, 'magnitude_q16': None}], 'conds': [], 'selector': 14, 'selector_cap': 32, 'selector_param1': 0, 'stack_policy': 0, 'max_stacks': 1, 'stacks': 1, 'lifecycle': 0, 'duration_days': -1, 'target_domain': 2, 'priority': 0, 'ramp': None, 'radius': 0, 'cap': 0, 'per_source': None}], [{'key': 'flint_knapping_l3', 'summary': '主产燧石的地块周围 1 格（最多 32 格）：全部产出 +8%', 'tags': ['cell.produces.flint'], 'cmds': [{'modifier': 'economy.city.output_factor', 'value': 0.08, 'duration_days': -1, 'stacks': 1, 'domain': None, 'magnitude_q16': None}], 'conds': [], 'selector': 14, 'selector_cap': 32, 'selector_param1': 0, 'stack_policy': 0, 'max_stacks': 1, 'stacks': 1, 'lifecycle': 0, 'duration_days': -1, 'target_domain': 2, 'priority': 0, 'ramp': None, 'radius': 0, 'cap': 0, 'per_source': None}]]`

## 火种守护 (`fire_keeping`)
- 学派：调和；时代：石器时代；稀有度：1
- 卡面描述：专人看守长明火堆，寒夜的冻害与恐惧同时退去，柴薪消耗也随之上升。
- 基础项：`[['country.climate.cold_stress_factor', 0.92], ['country.output.terrain.tundra.agriculture_factor', 1.05], ['country.resource.timber.use_factor', 1.04]]`

## 逐水而居 (`riverside_camp`)
- 学派：调和；时代：石器时代；稀有度：1
- 研究信号：landform.freshwater_access
- 卡面描述：营地紧贴河岸与湖湾，取水捕鱼极便，洪水却始终是威胁。
- 等级项：`[[['country.output.landform.delta.agriculture_factor', 1.06], ['country.output.terrain.floodplain.agriculture_factor', 1.06], ['country.production.input_factor', 1.02]], [['country.output.landform.delta.agriculture_factor', 1.09], ['country.output.terrain.floodplain.agriculture_factor', 1.09], ['country.production.input_factor', 1.02]], [['country.output.landform.delta.agriculture_factor', 1.09], ['country.output.terrain.floodplain.agriculture_factor', 1.09], ['country.production.input_factor', 1.02]]]`
- 程序等级项：`[[], [], [{'key': 'riverside_camp_l3', 'summary': '三角洲、泛滥平原地块周围 1 格（最多 32 格）：农业产出 +3%', 'tags': ['cell.landform.delta'], 'cmds': [{'modifier': 'economy.city.building.agriculture_output_factor', 'value': 0.03, 'duration_days': -1, 'stacks': 1, 'domain': None, 'magnitude_q16': None}], 'conds': [], 'selector': 14, 'selector_cap': 32, 'selector_param1': 0, 'stack_policy': 0, 'max_stacks': 1, 'stacks': 1, 'lifecycle': 0, 'duration_days': -1, 'target_domain': 2, 'priority': 0, 'ramp': None, 'radius': 0, 'cap': 0, 'per_source': None}]]`

## 万物有灵 (`animist_ritual`)
- 学派：学识；时代：石器时代；稀有度：1
- 卡面描述：把山川鸟兽都视作有意志的存在，解释世界的方式由此开始。
- 基础项：`[['country.research.society_efficiency', 1.05], ['country.ideology.point_gain_factor', 1.05], ['country.research.science_efficiency', 0.97]]`

## 馈赠交换 (`gift_exchange`)
- 学派：商贸；时代：石器时代；稀有度：1
- 卡面描述：以礼物与回礼代替买卖，熟人之间的物流从不间断，礼物本身却要耗料。
- 基础项：`[['country.trade.capacity_factor', 1.05], ['country.trade.speed_factor', 1.04], ['country.production.input_factor', 1.02]]`

## 共食 (`communal_feast`)
- 学派：动员；时代：石器时代；稀有度：1
- 卡面描述：猎物与采集物在火塘边均分，人人有份，野兽却被猎得更狠。
- 基础项：`[['country.resource.wild_game.use_factor', 1.04]]`

## 穴居聚落 (`pit_dwelling`)
- 学派：工造；时代：石器时代；稀有度：1
- 卡面描述：掘地为屋、聚族而居，御寒与省工两得，可耕的地面却让了出去。
- 等级项：`[[['country.climate.cold_stress_factor', 0.94], ['country.construction.cost_factor', 0.95], ['country.output.terrain.hill.agriculture_factor', 0.98]], [['country.climate.cold_stress_factor', 0.91], ['country.construction.cost_factor', 0.93], ['country.output.terrain.hill.agriculture_factor', 0.98]], [['country.climate.cold_stress_factor', 0.91], ['country.construction.cost_factor', 0.93], ['country.output.terrain.hill.agriculture_factor', 0.98]]]`
- 程序等级项：`[[], [], [{'key': 'pit_dwelling_l3', 'summary': '聚落地块（最多 32 格）：出生率 +5%', 'tags': ['cell.settlement'], 'cmds': [{'modifier': 'economy.city.birth_factor', 'value': 0.05, 'duration_days': -1, 'stacks': 1, 'domain': None, 'magnitude_q16': None}], 'conds': [], 'selector': 12, 'selector_cap': 32, 'selector_param1': 0, 'stack_policy': 0, 'max_stacks': 1, 'stacks': 1, 'lifecycle': 0, 'duration_days': -1, 'target_domain': 2, 'priority': 0, 'ramp': None, 'radius': 0, 'cap': 0, 'per_source': None}]]`

## 共同体治理 (`collective_stewardship`)
- 学派：农本；时代：农耕时代；稀有度：1；排他组：economic_order
- 卡面描述：以共同仓储、互助义务和长期土地责任组织生产，灵活交易被牺牲。
- 基础项：`[['country.trade.capacity_factor', 0.97]]`
- 程序等级项：`[[{'key': 'collective_stewardship_l1', 'summary': '农业支柱地块周围 1 格（最多 32 格）：全部产出 +3%', 'tags': ['cell.sector.agriculture'], 'cmds': [{'modifier': 'economy.city.output_factor', 'value': 0.03, 'duration_days': -1, 'stacks': 1, 'domain': None, 'magnitude_q16': None}], 'conds': [], 'selector': 14, 'selector_cap': 32, 'selector_param1': 0, 'stack_policy': 0, 'max_stacks': 1, 'stacks': 1, 'lifecycle': 0, 'duration_days': -1, 'target_domain': 2, 'priority': 0, 'ramp': None, 'radius': 0, 'cap': 0, 'per_source': None}], [{'key': 'collective_stewardship_l2', 'summary': '农业支柱地块周围 1 格（最多 32 格）：全部产出 +5%', 'tags': ['cell.sector.agriculture'], 'cmds': [{'modifier': 'economy.city.output_factor', 'value': 0.05, 'duration_days': -1, 'stacks': 1, 'domain': None, 'magnitude_q16': None}], 'conds': [], 'selector': 14, 'selector_cap': 32, 'selector_param1': 0, 'stack_policy': 0, 'max_stacks': 1, 'stacks': 1, 'lifecycle': 0, 'duration_days': -1, 'target_domain': 2, 'priority': 0, 'ramp': None, 'radius': 0, 'cap': 0, 'per_source': None}], [{'key': 'collective_stewardship_l3', 'summary': '农业支柱地块周围 1 格（最多 32 格）：全部产出 +7%', 'tags': ['cell.sector.agriculture'], 'cmds': [{'modifier': 'economy.city.output_factor', 'value': 0.07, 'duration_days': -1, 'stacks': 1, 'domain': None, 'magnitude_q16': None}], 'conds': [], 'selector': 14, 'selector_cap': 32, 'selector_param1': 0, 'stack_policy': 0, 'max_stacks': 1, 'stacks': 1, 'lifecycle': 0, 'duration_days': -1, 'target_domain': 2, 'priority': 0, 'ramp': None, 'radius': 0, 'cap': 0, 'per_source': None}]]`

## 梯田 (`terrace_farming`)
- 学派：农本；时代：农耕时代；稀有度：1
- 研究信号：landform.mountain
- 卡面描述：顺山势砌石成田，坡地上的每一寸土都被用上，工料耗费极大。
- 等级项：`[[['country.output.terrain.hill.agriculture_factor', 1.1], ['country.output.terrain.mountain.agriculture_factor', 1.1], ['country.output.terrain.hill.extractive_factor', 0.9], ['country.output.terrain.mountain.extractive_factor', 0.9]], [['country.output.terrain.hill.agriculture_factor', 1.15], ['country.output.terrain.mountain.agriculture_factor', 1.15], ['country.output.terrain.hill.extractive_factor', 0.9], ['country.output.terrain.mountain.extractive_factor', 0.9]], [['country.output.terrain.hill.agriculture_factor', 1.15], ['country.output.terrain.mountain.agriculture_factor', 1.15], ['country.output.terrain.hill.extractive_factor', 0.9], ['country.output.terrain.mountain.extractive_factor', 0.9]]]`
- 程序等级项：`[[], [], [{'key': 'terrace_farming_l3', 'summary': '丘陵地块（最多 32 格）：农业产出 +6%（L3 子句；相邻计数需 X2，当前按丘陵地块计）', 'tags': ['cell.terrain.hill'], 'cmds': [{'modifier': 'economy.city.building.agriculture_output_factor', 'value': 0.06, 'duration_days': -1, 'stacks': 1, 'domain': None, 'magnitude_q16': None}], 'conds': [], 'selector': 12, 'selector_cap': 32, 'selector_param1': 0, 'stack_policy': 0, 'max_stacks': 1, 'stacks': 1, 'lifecycle': 0, 'duration_days': -1, 'target_domain': 2, 'priority': 0, 'ramp': None, 'radius': 0, 'cap': 0, 'per_source': None}]]`

## 稻作 (`paddy_cultivation`)
- 学派：农本；时代：农耕时代；稀有度：1
- 研究信号：bio.rice
- 卡面描述：筑埂蓄水、育秧移栽，水田的单产远高于旱地，却挤占麦作。
- 基础项：`[['country.output.good.rice_grain_factor', 1.1], ['country.output.terrain.swamp.agriculture_factor', 1.08], ['country.output.landform.delta.agriculture_factor', 1.08], ['country.output.good.wheat_grain_factor', 0.95]]`

## 三圃轮作 (`three_field_rotation`)
- 学派：农本；时代：农耕时代；稀有度：2；排他组：land_order
- 研究信号：bio.wheat
- 卡面描述：把耕地分为三片轮换休耕，地力得以恢复，牧草地相应让出。
- 基础项：`[['country.output.terrain.grassland.agriculture_factor', 0.97]]`
- 程序等级项：`[[{'key': 'three_field_rotation_l1', 'summary': '农业支柱地块（最多 32 格）：肥沃土壤再生 +20%', 'tags': ['cell.sector.agriculture'], 'cmds': [{'modifier': 'economy.city.resource.fertile_soil.regen_factor', 'value': 0.2, 'duration_days': -1, 'stacks': 1, 'domain': None, 'magnitude_q16': None}], 'conds': [], 'selector': 12, 'selector_cap': 32, 'selector_param1': 0, 'stack_policy': 0, 'max_stacks': 1, 'stacks': 1, 'lifecycle': 0, 'duration_days': -1, 'target_domain': 2, 'priority': 0, 'ramp': None, 'radius': 0, 'cap': 0, 'per_source': None}], [{'key': 'three_field_rotation_l2', 'summary': '农业支柱地块（最多 32 格）：肥沃土壤再生 +30%', 'tags': ['cell.sector.agriculture'], 'cmds': [{'modifier': 'economy.city.resource.fertile_soil.regen_factor', 'value': 0.3, 'duration_days': -1, 'stacks': 1, 'domain': None, 'magnitude_q16': None}], 'conds': [], 'selector': 12, 'selector_cap': 32, 'selector_param1': 0, 'stack_policy': 0, 'max_stacks': 1, 'stacks': 1, 'lifecycle': 0, 'duration_days': -1, 'target_domain': 2, 'priority': 0, 'ramp': None, 'radius': 0, 'cap': 0, 'per_source': None}], [{'key': 'three_field_rotation_l3', 'summary': '农业支柱地块（最多 32 格）：肥沃土壤再生 +35%', 'tags': ['cell.sector.agriculture'], 'cmds': [{'modifier': 'economy.city.resource.fertile_soil.regen_factor', 'value': 0.35, 'duration_days': -1, 'stacks': 1, 'domain': None, 'magnitude_q16': None}], 'conds': [], 'selector': 12, 'selector_cap': 32, 'selector_param1': 0, 'stack_policy': 0, 'max_stacks': 1, 'stacks': 1, 'lifecycle': 0, 'duration_days': -1, 'target_domain': 2, 'priority': 0, 'ramp': None, 'radius': 0, 'cap': 0, 'per_source': None}]]`

## 自由交换 (`free_exchange`)
- 学派：商贸；时代：农耕时代；稀有度：1；排他组：economic_order
- 卡面描述：以契约、流通和分散决策鼓励资源重新配置，家庭消费随之抬头。
- 基础项：`[['country.household.consumption_factor', 1.02]]`
- 程序等级项：`[[{'key': 'free_exchange_l1', 'summary': '多元地块（最多 32 格）：全部产出 +6%', 'tags': ['cell.diversified'], 'cmds': [{'modifier': 'economy.city.output_factor', 'value': 0.06, 'duration_days': -1, 'stacks': 1, 'domain': None, 'magnitude_q16': None}], 'conds': [], 'selector': 12, 'selector_cap': 32, 'selector_param1': 0, 'stack_policy': 0, 'max_stacks': 1, 'stacks': 1, 'lifecycle': 0, 'duration_days': -1, 'target_domain': 2, 'priority': 0, 'ramp': None, 'radius': 0, 'cap': 0, 'per_source': None}], [{'key': 'free_exchange_l2', 'summary': '多元地块（最多 32 格）：全部产出 +9%', 'tags': ['cell.diversified'], 'cmds': [{'modifier': 'economy.city.output_factor', 'value': 0.09, 'duration_days': -1, 'stacks': 1, 'domain': None, 'magnitude_q16': None}], 'conds': [], 'selector': 12, 'selector_cap': 32, 'selector_param1': 0, 'stack_policy': 0, 'max_stacks': 1, 'stacks': 1, 'lifecycle': 0, 'duration_days': -1, 'target_domain': 2, 'priority': 0, 'ramp': None, 'radius': 0, 'cap': 0, 'per_source': None}], [{'key': 'free_exchange_l3', 'summary': '多元地块（最多 32 格）：全部产出 +12%', 'tags': ['cell.diversified'], 'cmds': [{'modifier': 'economy.city.output_factor', 'value': 0.12, 'duration_days': -1, 'stacks': 1, 'domain': None, 'magnitude_q16': None}], 'conds': [], 'selector': 12, 'selector_cap': 32, 'selector_param1': 0, 'stack_policy': 0, 'max_stacks': 1, 'stacks': 1, 'lifecycle': 0, 'duration_days': -1, 'target_domain': 2, 'priority': 0, 'ramp': None, 'radius': 0, 'cap': 0, 'per_source': None}]]`

## 学识官署 (`scholar_office`)
- 学派：学识；时代：农耕时代；稀有度：1
- 卡面描述：让记录、测量与专业知识成为公共决策的正式依据，行政耗费上升。
- 基础项：`[['country.output.knowledge_factor', 1.05], ['country.research.science_efficiency', 1.04], ['country.production.input_factor', 1.02]]`

## 标准化 (`standardization`)
- 学派：工造；时代：农耕时代；稀有度：1
- 卡面描述：统一度量、规格与零件，生产与建造都更省料，流通节奏却被规矩拖慢。
- 基础项：`[['country.trade.speed_factor', 0.98]]`
- 程序等级项：`[[{'key': 'standardization_l1', 'summary': '成链地块（最多 32 格）：工业产出 +8%', 'tags': ['cell.chained'], 'cmds': [{'modifier': 'economy.city.building.manufacturing_output_factor', 'value': 0.08, 'duration_days': -1, 'stacks': 1, 'domain': None, 'magnitude_q16': None}], 'conds': [], 'selector': 12, 'selector_cap': 32, 'selector_param1': 0, 'stack_policy': 0, 'max_stacks': 1, 'stacks': 1, 'lifecycle': 0, 'duration_days': -1, 'target_domain': 2, 'priority': 0, 'ramp': None, 'radius': 0, 'cap': 0, 'per_source': None}], [{'key': 'standardization_l2', 'summary': '成链地块（最多 32 格）：工业产出 +12%', 'tags': ['cell.chained'], 'cmds': [{'modifier': 'economy.city.building.manufacturing_output_factor', 'value': 0.12, 'duration_days': -1, 'stacks': 1, 'domain': None, 'magnitude_q16': None}], 'conds': [], 'selector': 12, 'selector_cap': 32, 'selector_param1': 0, 'stack_policy': 0, 'max_stacks': 1, 'stacks': 1, 'lifecycle': 0, 'duration_days': -1, 'target_domain': 2, 'priority': 0, 'ramp': None, 'radius': 0, 'cap': 0, 'per_source': None}], [{'key': 'standardization_l3', 'summary': '成链地块（最多 32 格）：工业产出 +16%', 'tags': ['cell.chained'], 'cmds': [{'modifier': 'economy.city.building.manufacturing_output_factor', 'value': 0.16, 'duration_days': -1, 'stacks': 1, 'domain': None, 'magnitude_q16': None}], 'conds': [], 'selector': 12, 'selector_cap': 32, 'selector_param1': 0, 'stack_policy': 0, 'max_stacks': 1, 'stacks': 1, 'lifecycle': 0, 'duration_days': -1, 'target_domain': 2, 'priority': 0, 'ramp': None, 'radius': 0, 'cap': 0, 'per_source': None}]]`

## 家内纺织 (`household_weaving`)
- 学派：工造；时代：农耕时代；稀有度：1
- 研究信号：bio.bast_fiber
- 卡面描述：农妇在农隙纺麻织布，家庭收支多了一条底线，麻田与粮田开始争地。
- 基础项：`[['country.output.terrain.plain.agriculture_factor', 0.97]]`
- 程序等级项：`[[{'key': 'household_weaving_l1', 'summary': '主产韧皮纤维、且职业 ≥2 种的地块：布产出 +12%', 'tags': ['cell.produces.bast_fiber'], 'cmds': [{'modifier': 'economy.city.good.cloth.output_factor', 'value': 0.12, 'duration_days': -1, 'stacks': 1, 'domain': None, 'magnitude_q16': None}], 'conds': [{'op': 2, 'arg0': 53, 'value_q16': 131072}], 'selector': 12, 'selector_cap': 32, 'selector_param1': 0, 'stack_policy': 0, 'max_stacks': 1, 'stacks': 1, 'lifecycle': 0, 'duration_days': -1, 'target_domain': 2, 'priority': 0, 'ramp': None, 'radius': 0, 'cap': 0, 'per_source': None}], [{'key': 'household_weaving_l2', 'summary': '主产韧皮纤维、且职业 ≥2 种的地块：布产出 +15%', 'tags': ['cell.produces.bast_fiber'], 'cmds': [{'modifier': 'economy.city.good.cloth.output_factor', 'value': 0.15, 'duration_days': -1, 'stacks': 1, 'domain': None, 'magnitude_q16': None}], 'conds': [{'op': 2, 'arg0': 53, 'value_q16': 131072}], 'selector': 12, 'selector_cap': 32, 'selector_param1': 0, 'stack_policy': 0, 'max_stacks': 1, 'stacks': 1, 'lifecycle': 0, 'duration_days': -1, 'target_domain': 2, 'priority': 0, 'ramp': None, 'radius': 0, 'cap': 0, 'per_source': None}], [{'key': 'household_weaving_l3', 'summary': '主产韧皮纤维、且职业 ≥2 种的地块：布产出 +18%', 'tags': ['cell.produces.bast_fiber'], 'cmds': [{'modifier': 'economy.city.good.cloth.output_factor', 'value': 0.18, 'duration_days': -1, 'stacks': 1, 'domain': None, 'magnitude_q16': None}], 'conds': [{'op': 2, 'arg0': 53, 'value_q16': 131072}], 'selector': 12, 'selector_cap': 32, 'selector_param1': 0, 'stack_policy': 0, 'max_stacks': 1, 'stacks': 1, 'lifecycle': 0, 'duration_days': -1, 'target_domain': 2, 'priority': 0, 'ramp': None, 'radius': 0, 'cap': 0, 'per_source': None}]]`

## 轮伐 (`coppice_rotation`)
- 学派：调和；时代：农耕时代；稀有度：2
- 研究信号：resource.timber
- 卡面描述：分区伐取、留桩待萌，林木再生率大涨，短期木材产量却要退一步。
- 程序等级项：`[[{'key': 'coppice_rotation_l1', 'summary': '主产原木的地块（最多 32 格）：木材再生 +20%，原木产出 -6%', 'tags': ['cell.produces.lumber'], 'cmds': [{'modifier': 'economy.city.resource.timber.regen_factor', 'value': 0.2, 'duration_days': -1, 'stacks': 1, 'domain': None, 'magnitude_q16': None}, {'modifier': 'economy.city.good.lumber.output_factor', 'value': -0.06, 'duration_days': -1, 'stacks': 1, 'domain': None, 'magnitude_q16': None}], 'conds': [], 'selector': 12, 'selector_cap': 32, 'selector_param1': 0, 'stack_policy': 0, 'max_stacks': 1, 'stacks': 1, 'lifecycle': 0, 'duration_days': -1, 'target_domain': 2, 'priority': 0, 'ramp': None, 'radius': 0, 'cap': 0, 'per_source': None}], [{'key': 'coppice_rotation_l2', 'summary': '主产原木的地块（最多 32 格）：木材再生 +30%，原木产出 -6%', 'tags': ['cell.produces.lumber'], 'cmds': [{'modifier': 'economy.city.resource.timber.regen_factor', 'value': 0.3, 'duration_days': -1, 'stacks': 1, 'domain': None, 'magnitude_q16': None}, {'modifier': 'economy.city.good.lumber.output_factor', 'value': -0.06, 'duration_days': -1, 'stacks': 1, 'domain': None, 'magnitude_q16': None}], 'conds': [], 'selector': 12, 'selector_cap': 32, 'selector_param1': 0, 'stack_policy': 0, 'max_stacks': 1, 'stacks': 1, 'lifecycle': 0, 'duration_days': -1, 'target_domain': 2, 'priority': 0, 'ramp': None, 'radius': 0, 'cap': 0, 'per_source': None}], [{'key': 'coppice_rotation_l3', 'summary': '主产原木的地块（最多 32 格）：木材再生 +30%，原木产出 -3%', 'tags': ['cell.produces.lumber'], 'cmds': [{'modifier': 'economy.city.resource.timber.regen_factor', 'value': 0.3, 'duration_days': -1, 'stacks': 1, 'domain': None, 'magnitude_q16': None}, {'modifier': 'economy.city.good.lumber.output_factor', 'value': -0.03, 'duration_days': -1, 'stacks': 1, 'domain': None, 'magnitude_q16': None}], 'conds': [], 'selector': 12, 'selector_cap': 32, 'selector_param1': 0, 'stack_policy': 0, 'max_stacks': 1, 'stacks': 1, 'lifecycle': 0, 'duration_days': -1, 'target_domain': 2, 'priority': 0, 'ramp': None, 'radius': 0, 'cap': 0, 'per_source': None}]]`

## 治水营田 (`water_works`)
- 学派：调和；时代：农耕时代；稀有度：1
- 研究信号：landform.floodplain
- 卡面描述：修堤疏渠、引水灌田，把洪水变成可用的水利，工役耗费不轻。
- 等级项：`[[['country.output.terrain.floodplain.agriculture_factor', 1.08], ['country.output.landform.delta.agriculture_factor', 1.08], ['country.climate.flood_loss_factor', 0.93], ['country.construction.cost_factor', 1.03]], [['country.output.terrain.floodplain.agriculture_factor', 1.12], ['country.output.landform.delta.agriculture_factor', 1.12], ['country.climate.flood_loss_factor', 0.9], ['country.construction.cost_factor', 1.03]], [['country.output.terrain.floodplain.agriculture_factor', 1.12], ['country.output.landform.delta.agriculture_factor', 1.12], ['country.climate.flood_loss_factor', 0.9], ['country.construction.cost_factor', 1.03]]]`
- 程序等级项：`[[], [], [{'key': 'water_works_l3', 'summary': '泛滥平原、三角洲地块周围 1 格（最多 32 格）：农业产出 +4%', 'tags': ['cell.terrain.floodplain'], 'cmds': [{'modifier': 'economy.city.building.agriculture_output_factor', 'value': 0.04, 'duration_days': -1, 'stacks': 1, 'domain': None, 'magnitude_q16': None}], 'conds': [], 'selector': 14, 'selector_cap': 32, 'selector_param1': 0, 'stack_policy': 0, 'max_stacks': 1, 'stacks': 1, 'lifecycle': 0, 'duration_days': -1, 'target_domain': 2, 'priority': 0, 'ramp': None, 'radius': 0, 'cap': 0, 'per_source': None}]]`

## 寒暑历法 (`seasonal_calendar`)
- 学派：调和；时代：农耕时代；稀有度：1
- 卡面描述：以节气指导农时与役使，寒暑异常的危害大为减轻，思辨的锐气稍减。
- 等级项：`[[['country.climate.cold_stress_factor', 0.94], ['country.climate.heat_stress_factor', 0.95], ['country.climate.profile.dryland_crop.drought_loss_factor', 0.94], ['country.ideology.point_gain_factor', 0.97]], [['country.climate.cold_stress_factor', 0.91], ['country.climate.heat_stress_factor', 0.925], ['country.climate.profile.dryland_crop.drought_loss_factor', 0.91], ['country.ideology.point_gain_factor', 0.97]], [['country.climate.cold_stress_factor', 0.91], ['country.climate.heat_stress_factor', 0.925], ['country.climate.profile.dryland_crop.drought_loss_factor', 0.91], ['country.ideology.point_gain_factor', 0.97]]]`
- 程序等级项：`[[], [], [{'key': 'seasonal_calendar_l3', 'summary': '降雨日的农业支柱地块（最多 32 格）：农业产出 +5%', 'tags': ['cell.rain', 'cell.sector.agriculture'], 'cmds': [{'modifier': 'economy.city.building.agriculture_output_factor', 'value': 0.05, 'duration_days': -1, 'stacks': 1, 'domain': None, 'magnitude_q16': None}], 'conds': [], 'selector': 12, 'selector_cap': 32, 'selector_param1': 0, 'stack_policy': 0, 'max_stacks': 1, 'stacks': 1, 'lifecycle': 0, 'duration_days': -1, 'target_domain': 2, 'priority': 0, 'ramp': None, 'radius': 0, 'cap': 0, 'per_source': None}]]`

## 轻徭薄赋 (`light_levy`)
- 学派：农本；时代：农耕时代；稀有度：1
- 卡面描述：轻徭薄赋向来是立国之本，低税要真的少收钱才算数。
- 等级项：`[[['country.construction.cost_factor', 1.03]], [['country.construction.cost_factor', 1.03]], [['economy.profession.household_farmer.satisfaction_bp', 300.0], ['economy.profession.subsistence_farmer.satisfaction_bp', 300.0], ['economy.profession.tenant_farmer.satisfaction_bp', 300.0], ['economy.profession.sharecropper.satisfaction_bp', 300.0], ['economy.profession.agricultural_worker.satisfaction_bp', 300.0], ['economy.profession.serf.satisfaction_bp', 300.0], ['country.construction.cost_factor', 1.03]]]`

## 宗祠 (`ancestral_hall`)
- 学派：调和；时代：农耕时代；稀有度：2
- 卡面描述：宗族以祠堂、义庄与族田联结子孙，兼并田产却苦了佃户。
- 等级项：`[[['economy.profession.tenant_farmer.satisfaction_bp', -300.0, 0], ['economy.profession.sharecropper.satisfaction_bp', -300.0, 0], ['economy.profession.serf.satisfaction_bp', -300.0, 0]], [['economy.profession.tenant_farmer.satisfaction_bp', -300.0, 0], ['economy.profession.sharecropper.satisfaction_bp', -300.0, 0], ['economy.profession.serf.satisfaction_bp', -300.0, 0]], [['economy.profession.tenant_farmer.satisfaction_bp', -300.0, 0], ['economy.profession.sharecropper.satisfaction_bp', -300.0, 0], ['economy.profession.serf.satisfaction_bp', -300.0, 0]]]`

## 常平仓 (`ever_normal_granary`)
- 学派：农本；时代：王国时代；稀有度：2
- 卡面描述：丰年籴入、歉年粜出，以官仓平抑粮价与饥荒，市面流通被官仓压住。
- 基础项：`[['country.trade.capacity_factor', 0.97]]`
- 程序等级项：`[[{'key': 'ever_normal_granary_l1', 'summary': '短缺地块（最多 32 格）：主食需求 -15%', 'tags': ['cell.shortage'], 'cmds': [{'modifier': 'economy.city.need.staple_food.consumption_factor', 'value': -0.15, 'duration_days': -1, 'stacks': 1, 'domain': None, 'magnitude_q16': None}], 'conds': [], 'selector': 12, 'selector_cap': 32, 'selector_param1': 0, 'stack_policy': 0, 'max_stacks': 1, 'stacks': 1, 'lifecycle': 0, 'duration_days': -1, 'target_domain': 2, 'priority': 0, 'ramp': None, 'radius': 0, 'cap': 0, 'per_source': None}], [{'key': 'ever_normal_granary_l2', 'summary': '短缺地块（最多 32 格）：主食需求 -20%', 'tags': ['cell.shortage'], 'cmds': [{'modifier': 'economy.city.need.staple_food.consumption_factor', 'value': -0.2, 'duration_days': -1, 'stacks': 1, 'domain': None, 'magnitude_q16': None}], 'conds': [], 'selector': 12, 'selector_cap': 32, 'selector_param1': 0, 'stack_policy': 0, 'max_stacks': 1, 'stacks': 1, 'lifecycle': 0, 'duration_days': -1, 'target_domain': 2, 'priority': 0, 'ramp': None, 'radius': 0, 'cap': 0, 'per_source': None}], [{'key': 'ever_normal_granary_l3', 'summary': '短缺地块（最多 32 格）：主食需求 -22%', 'tags': ['cell.shortage'], 'cmds': [{'modifier': 'economy.city.need.staple_food.consumption_factor', 'value': -0.22, 'duration_days': -1, 'stacks': 1, 'domain': None, 'magnitude_q16': None}], 'conds': [], 'selector': 12, 'selector_cap': 32, 'selector_param1': 0, 'stack_policy': 0, 'max_stacks': 1, 'stacks': 1, 'lifecycle': 0, 'duration_days': -1, 'target_domain': 2, 'priority': 0, 'ramp': None, 'radius': 0, 'cap': 0, 'per_source': None}]]`

## 包税 (`tax_farming`)
- 学派：商贸；时代：王国时代；稀有度：2
- 卡面描述：包税商代征，商户不必直面官府，重税之下仍留一线。
- 等级项：`[[['economy.profession.merchant.tax_tolerance_factor', 1.2]], [['economy.profession.merchant.tax_tolerance_factor', 1.3]], [['economy.profession.merchant.tax_tolerance_factor', 1.3]]]`
- 程序等级项：`[[{'key': 'tax_farming_l1', 'summary': '繁市地块（最多 32 格）：出生率 -4%（重税的代价）', 'tags': ['cell.market'], 'cmds': [{'modifier': 'economy.city.birth_factor', 'value': -0.04, 'duration_days': -1, 'stacks': 1, 'domain': None, 'magnitude_q16': None}], 'conds': [], 'selector': 12, 'selector_cap': 32, 'selector_param1': 0, 'stack_policy': 0, 'max_stacks': 1, 'stacks': 1, 'lifecycle': 0, 'duration_days': -1, 'target_domain': 2, 'priority': 0, 'ramp': None, 'radius': 0, 'cap': 0, 'per_source': None}], [{'key': 'tax_farming_l2', 'summary': '繁市地块（最多 32 格）：出生率 -4%', 'tags': ['cell.market'], 'cmds': [{'modifier': 'economy.city.birth_factor', 'value': -0.04, 'duration_days': -1, 'stacks': 1, 'domain': None, 'magnitude_q16': None}], 'conds': [], 'selector': 12, 'selector_cap': 32, 'selector_param1': 0, 'stack_policy': 0, 'max_stacks': 1, 'stacks': 1, 'lifecycle': 0, 'duration_days': -1, 'target_domain': 2, 'priority': 0, 'ramp': None, 'radius': 0, 'cap': 0, 'per_source': None}], [{'key': 'tax_farming_l3', 'summary': '繁市地块（最多 32 格）：出生率 -4%', 'tags': ['cell.market'], 'cmds': [{'modifier': 'economy.city.birth_factor', 'value': -0.04, 'duration_days': -1, 'stacks': 1, 'domain': None, 'magnitude_q16': None}], 'conds': [], 'selector': 12, 'selector_cap': 32, 'selector_param1': 0, 'stack_policy': 0, 'max_stacks': 1, 'stacks': 1, 'lifecycle': 0, 'duration_days': -1, 'target_domain': 2, 'priority': 0, 'ramp': None, 'radius': 0, 'cap': 0, 'per_source': None}]]`

## 登闻鼓 (`petition_box`)
- 学派：调和；时代：王国时代；稀有度：1
- 卡面描述：击鼓上闻、直达天听，怨气有处可去，吏员却多了一桩差事。
- 等级项：`[[['economy.profession.agricultural_worker.satisfaction_bp', 400.0], ['economy.profession.subsistence_farmer.satisfaction_bp', 400.0], ['economy.profession.tenant_farmer.satisfaction_bp', 400.0], ['economy.profession.sharecropper.satisfaction_bp', 400.0], ['economy.profession.serf.satisfaction_bp', 400.0], ['economy.profession.household_farmer.satisfaction_bp', 400.0], ['country.population.death_factor', 0.97], ['country.research.society_efficiency', 0.98, 0]], [['economy.profession.household_farmer.satisfaction_bp', 600.0], ['economy.profession.subsistence_farmer.satisfaction_bp', 600.0], ['economy.profession.tenant_farmer.satisfaction_bp', 600.0], ['economy.profession.sharecropper.satisfaction_bp', 600.0], ['economy.profession.agricultural_worker.satisfaction_bp', 600.0], ['economy.profession.serf.satisfaction_bp', 600.0], ['country.population.death_factor', 0.97], ['country.ideology.point_gain_factor', 1.07], ['country.research.society_efficiency', 0.98, 0]], [['economy.profession.household_farmer.satisfaction_bp', 600.0], ['economy.profession.subsistence_farmer.satisfaction_bp', 600.0], ['economy.profession.tenant_farmer.satisfaction_bp', 600.0], ['economy.profession.sharecropper.satisfaction_bp', 600.0], ['economy.profession.agricultural_worker.satisfaction_bp', 600.0], ['economy.profession.serf.satisfaction_bp', 600.0], ['economy.profession.industrial_worker.satisfaction_bp', 400.0], ['economy.profession.miner.satisfaction_bp', 400.0], ['economy.profession.machinist.satisfaction_bp', 400.0], ['economy.profession.petroleum_worker.satisfaction_bp', 400.0], ['economy.profession.transport_worker.satisfaction_bp', 400.0], ['economy.profession.construction_worker.satisfaction_bp', 400.0], ['economy.profession.electrician.satisfaction_bp', 400.0], ['economy.profession.worker.satisfaction_bp', 400.0], ['country.population.death_factor', 0.97], ['country.ideology.point_gain_factor', 1.07], ['country.research.society_efficiency', 0.98, 0]]]`

## 屯垦 (`settle_and_farm`)
- 学派：农本；时代：王国时代；稀有度：2；排他组：land_order
- 额外科技：tech.kingdom_administration
- 卡面描述：编户屯垦，把荒原与边地一并开成田，投入的农具与口粮同样惊人。
- 基础项：`[['country.production.input_factor', 1.03]]`
- 程序等级项：`[[{'key': 'settle_and_farm_l1', 'summary': '边地农业地块（最多 32 格）：农业 +15%，出生率 +8%', 'tags': ['cell.frontier', 'cell.sector.agriculture'], 'cmds': [{'modifier': 'economy.city.building.agriculture_output_factor', 'value': 0.15, 'duration_days': -1, 'stacks': 1, 'domain': None, 'magnitude_q16': None}, {'modifier': 'economy.city.birth_factor', 'value': 0.08, 'duration_days': -1, 'stacks': 1, 'domain': None, 'magnitude_q16': None}], 'conds': [], 'selector': 12, 'selector_cap': 32, 'selector_param1': 0, 'stack_policy': 0, 'max_stacks': 1, 'stacks': 1, 'lifecycle': 0, 'duration_days': -1, 'target_domain': 2, 'priority': 0, 'ramp': None, 'radius': 0, 'cap': 0, 'per_source': None}], [{'key': 'settle_and_farm_l2', 'summary': '边地农业地块（最多 32 格）：农业 +20%，出生率 +10%', 'tags': ['cell.frontier', 'cell.sector.agriculture'], 'cmds': [{'modifier': 'economy.city.building.agriculture_output_factor', 'value': 0.2, 'duration_days': -1, 'stacks': 1, 'domain': None, 'magnitude_q16': None}, {'modifier': 'economy.city.birth_factor', 'value': 0.1, 'duration_days': -1, 'stacks': 1, 'domain': None, 'magnitude_q16': None}], 'conds': [], 'selector': 12, 'selector_cap': 32, 'selector_param1': 0, 'stack_policy': 0, 'max_stacks': 1, 'stacks': 1, 'lifecycle': 0, 'duration_days': -1, 'target_domain': 2, 'priority': 0, 'ramp': None, 'radius': 0, 'cap': 0, 'per_source': None}], [{'key': 'settle_and_farm_l3', 'summary': '边地农业地块（最多 32 格）：农业 +22%，出生率 +11%', 'tags': ['cell.frontier', 'cell.sector.agriculture'], 'cmds': [{'modifier': 'economy.city.building.agriculture_output_factor', 'value': 0.22, 'duration_days': -1, 'stacks': 1, 'domain': None, 'magnitude_q16': None}, {'modifier': 'economy.city.birth_factor', 'value': 0.11, 'duration_days': -1, 'stacks': 1, 'domain': None, 'magnitude_q16': None}], 'conds': [], 'selector': 12, 'selector_cap': 32, 'selector_param1': 0, 'stack_policy': 0, 'max_stacks': 1, 'stacks': 1, 'lifecycle': 0, 'duration_days': -1, 'target_domain': 2, 'priority': 0, 'ramp': None, 'radius': 0, 'cap': 0, 'per_source': None}]]`

## 市舶开港 (`open_ports`)
- 学派：商贸；时代：王国时代；稀有度：1
- 研究信号：landform.coast
- 卡面描述：设市舶司、开海口通商，货物周转加快，船料把林地消耗推高。
- 基础项：`[['country.trade.speed_factor', 1.07], ['country.trade.capacity_factor', 1.03], ['country.resource.timber.use_factor', 1.03]]`

## 行会特许 (`guild_charters`)
- 学派：商贸；时代：王国时代；稀有度：2；排他组：labor_order
- 卡面描述：以特许状给予行会定价与学徒制度，品质稳定而新建更贵。
- 基础项：`[['country.construction.cost_factor', 1.03]]`
- 程序等级项：`[[{'key': 'guild_charters_l1', 'summary': '工业支柱、且单一职业占比 ≥60% 的地块：工业产出 +10%', 'tags': ['cell.sector.manufacturing'], 'cmds': [{'modifier': 'economy.city.building.manufacturing_output_factor', 'value': 0.1, 'duration_days': -1, 'stacks': 1, 'domain': None, 'magnitude_q16': None}], 'conds': [{'op': 2, 'arg0': 52, 'value_q16': 39322}], 'selector': 12, 'selector_cap': 32, 'selector_param1': 0, 'stack_policy': 0, 'max_stacks': 1, 'stacks': 1, 'lifecycle': 0, 'duration_days': -1, 'target_domain': 2, 'priority': 0, 'ramp': None, 'radius': 0, 'cap': 0, 'per_source': None}], [{'key': 'guild_charters_l2', 'summary': '工业支柱、且单一职业占比 ≥60% 的地块：工业产出 +14%', 'tags': ['cell.sector.manufacturing'], 'cmds': [{'modifier': 'economy.city.building.manufacturing_output_factor', 'value': 0.14, 'duration_days': -1, 'stacks': 1, 'domain': None, 'magnitude_q16': None}], 'conds': [{'op': 2, 'arg0': 52, 'value_q16': 39322}], 'selector': 12, 'selector_cap': 32, 'selector_param1': 0, 'stack_policy': 0, 'max_stacks': 1, 'stacks': 1, 'lifecycle': 0, 'duration_days': -1, 'target_domain': 2, 'priority': 0, 'ramp': None, 'radius': 0, 'cap': 0, 'per_source': None}], [{'key': 'guild_charters_l3', 'summary': '工业支柱、且单一职业占比 ≥60% 的地块：工业产出 +18%', 'tags': ['cell.sector.manufacturing'], 'cmds': [{'modifier': 'economy.city.building.manufacturing_output_factor', 'value': 0.18, 'duration_days': -1, 'stacks': 1, 'domain': None, 'magnitude_q16': None}], 'conds': [{'op': 2, 'arg0': 52, 'value_q16': 39322}], 'selector': 12, 'selector_cap': 32, 'selector_param1': 0, 'stack_policy': 0, 'max_stacks': 1, 'stacks': 1, 'lifecycle': 0, 'duration_days': -1, 'target_domain': 2, 'priority': 0, 'ramp': None, 'radius': 0, 'cap': 0, 'per_source': None}]]`

## 复式簿记 (`double_entry`)
- 学派：商贸；时代：王国时代；稀有度：2
- 额外科技：tech.kingdom_administration
- 卡面描述：借贷必相等，账目透明让工坊与商号都能精打细算，算计压过了理想。
- 基础项：`[['country.production.input_factor', 0.95], ['country.trade.capacity_factor', 1.03], ['country.ideology.point_gain_factor', 0.97]]`

## 书院讲学 (`academy_lectures`)
- 学派：学识；时代：王国时代；稀有度：1
- 卡面描述：书院讲会、辞辩争鸣，民间对国家道路的理解更加深入，耗用于是增加。
- 基础项：`[['country.research.society_efficiency', 1.05], ['country.output.knowledge_factor', 1.03], ['country.ideology.point_gain_factor', 1.06], ['country.production.input_factor', 1.02]]`

## 科举取士 (`civil_examination`)
- 学派：学识；时代：王国时代；稀有度：2
- 额外科技：tech.kingdom_administration
- 卡面描述：以考试选拔官员，学风大盛，最好的头脑都去读经，工技反受冷落。
- 基础项：`[['country.research.cost_factor', 0.95], ['country.research.society_efficiency', 1.03], ['country.output.terrain.plain.manufacturing_factor', 0.98]]`

## 冶铁 (`iron_smelting`)
- 学派：工造；时代：王国时代；稀有度：2
- 研究信号：resource.iron_ore
- 卡面描述：就地开炉鼓风，铁矿运距归零让铁料便宜，矿脉也消耗得飞快。
- 基础项：`[['country.resource.iron_ore.use_factor', 1.06]]`
- 程序等级项：`[[{'key': 'iron_smelting_l1', 'summary': '主产铁矿石的地块周围 1 格（最多 32 格）：工业产出 +10%', 'tags': ['cell.produces.iron_ore'], 'cmds': [{'modifier': 'economy.city.building.manufacturing_output_factor', 'value': 0.1, 'duration_days': -1, 'stacks': 1, 'domain': None, 'magnitude_q16': None}], 'conds': [], 'selector': 14, 'selector_cap': 32, 'selector_param1': 0, 'stack_policy': 0, 'max_stacks': 1, 'stacks': 1, 'lifecycle': 0, 'duration_days': -1, 'target_domain': 2, 'priority': 0, 'ramp': None, 'radius': 0, 'cap': 0, 'per_source': None}], [{'key': 'iron_smelting_l2', 'summary': '主产铁矿石的地块周围 1 格（最多 32 格）：工业产出 +14%', 'tags': ['cell.produces.iron_ore'], 'cmds': [{'modifier': 'economy.city.building.manufacturing_output_factor', 'value': 0.14, 'duration_days': -1, 'stacks': 1, 'domain': None, 'magnitude_q16': None}], 'conds': [], 'selector': 14, 'selector_cap': 32, 'selector_param1': 0, 'stack_policy': 0, 'max_stacks': 1, 'stacks': 1, 'lifecycle': 0, 'duration_days': -1, 'target_domain': 2, 'priority': 0, 'ramp': None, 'radius': 0, 'cap': 0, 'per_source': None}], [{'key': 'iron_smelting_l3', 'summary': '主产铁矿石的地块周围 1 格（最多 32 格）：工业产出 +18%', 'tags': ['cell.produces.iron_ore'], 'cmds': [{'modifier': 'economy.city.building.manufacturing_output_factor', 'value': 0.18, 'duration_days': -1, 'stacks': 1, 'domain': None, 'magnitude_q16': None}], 'conds': [], 'selector': 14, 'selector_cap': 32, 'selector_param1': 0, 'stack_policy': 0, 'max_stacks': 1, 'stacks': 1, 'lifecycle': 0, 'duration_days': -1, 'target_domain': 2, 'priority': 0, 'ramp': None, 'radius': 0, 'cap': 0, 'per_source': None}]]`

## 驿传 (`postal_horse`)
- 学派：动员；时代：王国时代；稀有度：2
- 研究信号：bio.horse
- 卡面描述：沿官道设驿换马，政令与商旅同时提速，牧草挤掉了口粮田。
- 基础项：`[['country.trade.speed_factor', 1.08], ['country.output.good.horses_factor', 1.06], ['country.output.good.wheat_grain_factor', 0.96]]`

## 汛期农法 (`monsoon_farming`)
- 学派：农本；时代：王国时代；稀有度：3
- 研究信号：weather.monsoon
- 卡面描述：按季风起落安排浸种与排水，水田的洪灾损失被压到最低，旱地却学不来。
- 基础项：`[['country.climate.profile.paddy_crop.flood_loss_factor', 0.88], ['country.output.landform.delta.agriculture_factor', 1.06], ['country.output.terrain.desert.agriculture_factor', 0.95]]`

## 漕运 (`river_transport`)
- 学派：商贸；时代：王国时代；稀有度：2
- 研究信号：landform.river_valley
- 卡面描述：沿河设闸、分段转运，粮货逆流而上，沿岸谷地的工坊随之兴旺，河工岁修是一笔长期账。
- 基础项：`[['country.trade.speed_factor', 1.06], ['country.trade.capacity_factor', 1.04], ['country.output.terrain.floodplain.manufacturing_factor', 1.05], ['country.construction.cost_factor', 1.04]]`

## 乡约自治 (`village_compact`)
- 学派：农本；时代：帝国时代；稀有度：3
- 额外科技：tech.imperial_integration
- 卡面描述：以乡约、社仓与家族共治维系基层秩序，民心即是国本，流通却少了弹性。
- 基础项：`[['country.trade.capacity_factor', 0.97]]`
- 程序等级项：`[[{'key': 'village_compact_l1', 'summary': '农业支柱、且相邻人口 ≥800 的地块：农业产出 +8%', 'tags': ['cell.sector.agriculture'], 'cmds': [{'modifier': 'economy.city.building.agriculture_output_factor', 'value': 0.08, 'duration_days': -1, 'stacks': 1, 'domain': None, 'magnitude_q16': None}], 'conds': [{'op': 2, 'arg0': 54, 'value_q16': 52428800}], 'selector': 12, 'selector_cap': 32, 'selector_param1': 0, 'stack_policy': 0, 'max_stacks': 1, 'stacks': 1, 'lifecycle': 0, 'duration_days': -1, 'target_domain': 2, 'priority': 0, 'ramp': None, 'radius': 0, 'cap': 0, 'per_source': None}], [{'key': 'village_compact_l2', 'summary': '农业支柱、且相邻人口 ≥800 的地块：农业产出 +11%', 'tags': ['cell.sector.agriculture'], 'cmds': [{'modifier': 'economy.city.building.agriculture_output_factor', 'value': 0.11, 'duration_days': -1, 'stacks': 1, 'domain': None, 'magnitude_q16': None}], 'conds': [{'op': 2, 'arg0': 54, 'value_q16': 52428800}], 'selector': 12, 'selector_cap': 32, 'selector_param1': 0, 'stack_policy': 0, 'max_stacks': 1, 'stacks': 1, 'lifecycle': 0, 'duration_days': -1, 'target_domain': 2, 'priority': 0, 'ramp': None, 'radius': 0, 'cap': 0, 'per_source': None}], [{'key': 'village_compact_l3', 'summary': '农业支柱、且相邻人口 ≥800 的地块：农业产出 +14%', 'tags': ['cell.sector.agriculture'], 'cmds': [{'modifier': 'economy.city.building.agriculture_output_factor', 'value': 0.14, 'duration_days': -1, 'stacks': 1, 'domain': None, 'magnitude_q16': None}], 'conds': [{'op': 2, 'arg0': 54, 'value_q16': 52428800}], 'selector': 12, 'selector_cap': 32, 'selector_param1': 0, 'stack_policy': 0, 'max_stacks': 1, 'stacks': 1, 'lifecycle': 0, 'duration_days': -1, 'target_domain': 2, 'priority': 0, 'ramp': None, 'radius': 0, 'cap': 0, 'per_source': None}]]`

## 垦荒令 (`land_reclamation`)
- 学派：农本；时代：帝国时代；稀有度：2；排他组：land_order
- 卡面描述：招民开垦河漫与绿洲，田亩既增，水土也开始吃紧。
- 基础项：`[['country.construction.cost_factor', 1.02]]`
- 程序等级项：`[[{'key': 'land_reclamation_l1', 'summary': '边地农业、且相邻人口 ≤400 的地块：农业产出 +10%', 'tags': ['cell.frontier', 'cell.sector.agriculture'], 'cmds': [{'modifier': 'economy.city.building.agriculture_output_factor', 'value': 0.1, 'duration_days': -1, 'stacks': 1, 'domain': None, 'magnitude_q16': None}], 'conds': [{'op': 3, 'arg0': 54, 'value_q16': 26214400}], 'selector': 12, 'selector_cap': 32, 'selector_param1': 0, 'stack_policy': 0, 'max_stacks': 1, 'stacks': 1, 'lifecycle': 0, 'duration_days': -1, 'target_domain': 2, 'priority': 0, 'ramp': None, 'radius': 0, 'cap': 0, 'per_source': None}], [{'key': 'land_reclamation_l2', 'summary': '边地农业、且相邻人口 ≤400 的地块：农业产出 +13%', 'tags': ['cell.frontier', 'cell.sector.agriculture'], 'cmds': [{'modifier': 'economy.city.building.agriculture_output_factor', 'value': 0.13, 'duration_days': -1, 'stacks': 1, 'domain': None, 'magnitude_q16': None}], 'conds': [{'op': 3, 'arg0': 54, 'value_q16': 26214400}], 'selector': 12, 'selector_cap': 32, 'selector_param1': 0, 'stack_policy': 0, 'max_stacks': 1, 'stacks': 1, 'lifecycle': 0, 'duration_days': -1, 'target_domain': 2, 'priority': 0, 'ramp': None, 'radius': 0, 'cap': 0, 'per_source': None}], [{'key': 'land_reclamation_l3', 'summary': '边地农业、且相邻人口 ≤400 的地块：农业产出 +16%', 'tags': ['cell.frontier', 'cell.sector.agriculture'], 'cmds': [{'modifier': 'economy.city.building.agriculture_output_factor', 'value': 0.16, 'duration_days': -1, 'stacks': 1, 'domain': None, 'magnitude_q16': None}], 'conds': [{'op': 3, 'arg0': 54, 'value_q16': 26214400}], 'selector': 12, 'selector_cap': 32, 'selector_param1': 0, 'stack_policy': 0, 'max_stacks': 1, 'stacks': 1, 'lifecycle': 0, 'duration_days': -1, 'target_domain': 2, 'priority': 0, 'ramp': None, 'radius': 0, 'cap': 0, 'per_source': None}]]`

## 漕运仓法 (`granary_road`)
- 学派：商贸；时代：帝国时代；稀有度：2
- 卡面描述：以运河与官仓串起粮道，丰歉在千里之间互相调剂，船料取于山林。
- 基础项：`[['country.trade.speed_factor', 1.05], ['country.trade.capacity_factor', 1.03], ['country.population.death_factor', 0.98], ['country.resource.timber.use_factor', 1.03]]`

## 太学 (`imperial_academy`)
- 学派：学识；时代：帝国时代；稀有度：2
- 卡面描述：国家设学养士，注疏与考据成为可积累的公共知识，正统压住异说。
- 基础项：`[['country.research.institution_output_factor', 1.05], ['country.research.cost_factor', 0.97], ['country.ideology.point_gain_factor', 0.97]]`

## 公共卫生 (`public_hygiene`)
- 学派：动员；时代：帝国时代；稀有度：2
- 额外科技：tech.imperial_integration
- 卡面描述：清渠、隔离与种痘，把健康变成可以组织的公共事务，宅第造价随之上浮。
- 基础项：`[['country.construction.cost_factor', 1.03]]`
- 程序等级项：`[[{'key': 'public_hygiene_l1', 'summary': '聚落地块（最多 32 格）：出生率 +5%，住房需求 -8%', 'tags': ['cell.settlement'], 'cmds': [{'modifier': 'economy.city.birth_factor', 'value': 0.05, 'duration_days': -1, 'stacks': 1, 'domain': None, 'magnitude_q16': None}, {'modifier': 'economy.city.need.housing.consumption_factor', 'value': -0.08, 'duration_days': -1, 'stacks': 1, 'domain': None, 'magnitude_q16': None}], 'conds': [], 'selector': 12, 'selector_cap': 32, 'selector_param1': 0, 'stack_policy': 0, 'max_stacks': 1, 'stacks': 1, 'lifecycle': 0, 'duration_days': -1, 'target_domain': 2, 'priority': 0, 'ramp': None, 'radius': 0, 'cap': 0, 'per_source': None}], [{'key': 'public_hygiene_l2', 'summary': '聚落地块（最多 32 格）：出生率 +8%，住房需求 -10%', 'tags': ['cell.settlement'], 'cmds': [{'modifier': 'economy.city.birth_factor', 'value': 0.08, 'duration_days': -1, 'stacks': 1, 'domain': None, 'magnitude_q16': None}, {'modifier': 'economy.city.need.housing.consumption_factor', 'value': -0.1, 'duration_days': -1, 'stacks': 1, 'domain': None, 'magnitude_q16': None}], 'conds': [], 'selector': 12, 'selector_cap': 32, 'selector_param1': 0, 'stack_policy': 0, 'max_stacks': 1, 'stacks': 1, 'lifecycle': 0, 'duration_days': -1, 'target_domain': 2, 'priority': 0, 'ramp': None, 'radius': 0, 'cap': 0, 'per_source': None}], [{'key': 'public_hygiene_l3', 'summary': '聚落地块（最多 32 格）：出生率 +9%，住房需求 -11%', 'tags': ['cell.settlement'], 'cmds': [{'modifier': 'economy.city.birth_factor', 'value': 0.09, 'duration_days': -1, 'stacks': 1, 'domain': None, 'magnitude_q16': None}, {'modifier': 'economy.city.need.housing.consumption_factor', 'value': -0.11, 'duration_days': -1, 'stacks': 1, 'domain': None, 'magnitude_q16': None}], 'conds': [], 'selector': 12, 'selector_cap': 32, 'selector_param1': 0, 'stack_policy': 0, 'max_stacks': 1, 'stacks': 1, 'lifecycle': 0, 'duration_days': -1, 'target_domain': 2, 'priority': 0, 'ramp': None, 'radius': 0, 'cap': 0, 'per_source': None}]]`

## 天人相参 (`heaven_human`)
- 学派：调和；时代：帝国时代；稀有度：2
- 额外科技：tech.imperial_integration
- 卡面描述：观天察地以定政令，对旱涝与农业规律的理解更加系统，实测精神被压制。
- 基础项：`[['country.climate.drought_loss_factor', 0.95], ['country.climate.flood_loss_factor', 0.95], ['country.research.agriculture_efficiency', 1.05], ['country.research.science_efficiency', 0.97]]`

## 盐铁专营 (`salt_monopoly`)
- 学派：工造；时代：帝国时代；稀有度：2；排他组：economic_order
- 研究信号：resource.salt
- 卡面描述：国家专营盐池与铁冶，盐利充盈国库，私商与盐脉同受挤压。
- 基础项：`[['country.resource.salt.use_factor', 1.08], ['country.trade.capacity_factor', 0.97]]`
- 程序等级项：`[[{'key': 'salt_monopoly_l1', 'summary': '每个矿业支柱地块使矿业支柱地块产出 +1%（上限 +15%）', 'tags': ['cell.sector.extractive'], 'cmds': [{'modifier': 'economy.city.building.extractive_output_factor', 'value': 0.01, 'duration_days': -1, 'stacks': 1, 'domain': None, 'magnitude_q16': None}], 'conds': [], 'selector': 12, 'selector_cap': 32, 'selector_param1': 0, 'stack_policy': 0, 'max_stacks': 1, 'stacks': 1, 'lifecycle': 0, 'duration_days': -1, 'target_domain': 2, 'priority': 0, 'ramp': {'metric': 'country.extractive_cell_count', 'per': 0.01, 'cap': 15}, 'radius': 0, 'cap': 0, 'per_source': None}], [{'key': 'salt_monopoly_l2', 'summary': '每个矿业支柱地块使矿业支柱地块产出 +1.5%（上限 +15%）', 'tags': ['cell.sector.extractive'], 'cmds': [{'modifier': 'economy.city.building.extractive_output_factor', 'value': 0.015, 'duration_days': -1, 'stacks': 1, 'domain': None, 'magnitude_q16': None}], 'conds': [], 'selector': 12, 'selector_cap': 32, 'selector_param1': 0, 'stack_policy': 0, 'max_stacks': 1, 'stacks': 1, 'lifecycle': 0, 'duration_days': -1, 'target_domain': 2, 'priority': 0, 'ramp': {'metric': 'country.extractive_cell_count', 'per': 0.015, 'cap': 10}, 'radius': 0, 'cap': 0, 'per_source': None}], [{'key': 'salt_monopoly_l3', 'summary': '每个矿业支柱地块使矿业支柱地块产出 +2%（上限 +15%）', 'tags': ['cell.sector.extractive'], 'cmds': [{'modifier': 'economy.city.building.extractive_output_factor', 'value': 0.02, 'duration_days': -1, 'stacks': 1, 'domain': None, 'magnitude_q16': None}], 'conds': [], 'selector': 12, 'selector_cap': 32, 'selector_param1': 0, 'stack_policy': 0, 'max_stacks': 1, 'stacks': 1, 'lifecycle': 0, 'duration_days': -1, 'target_domain': 2, 'priority': 0, 'ramp': {'metric': 'country.extractive_cell_count', 'per': 0.02, 'cap': 7.5}, 'radius': 0, 'cap': 0, 'per_source': None}]]`

## 蚕桑 (`sericulture`)
- 学派：工造；时代：帝国时代；稀有度：2
- 研究信号：bio.silkworm
- 卡面描述：植桑养蚕、缫丝织锦，绢帛成了硬通货，桑田与粮田争地。
- 基础项：`[['country.output.terrain.plain.agriculture_factor', 0.97]]`
- 程序等级项：`[[{'key': 'sericulture_l1', 'summary': '主产布的地块周围 1 格（最多 32 格）：精致服装产出 +12%', 'tags': ['cell.produces.cloth'], 'cmds': [{'modifier': 'economy.city.good.fine_clothing.output_factor', 'value': 0.12, 'duration_days': -1, 'stacks': 1, 'domain': None, 'magnitude_q16': None}], 'conds': [], 'selector': 14, 'selector_cap': 32, 'selector_param1': 0, 'stack_policy': 0, 'max_stacks': 1, 'stacks': 1, 'lifecycle': 0, 'duration_days': -1, 'target_domain': 2, 'priority': 0, 'ramp': None, 'radius': 0, 'cap': 0, 'per_source': None}], [{'key': 'sericulture_l2', 'summary': '主产布的地块周围 1 格（最多 32 格）：精致服装产出 +16%', 'tags': ['cell.produces.cloth'], 'cmds': [{'modifier': 'economy.city.good.fine_clothing.output_factor', 'value': 0.16, 'duration_days': -1, 'stacks': 1, 'domain': None, 'magnitude_q16': None}], 'conds': [], 'selector': 14, 'selector_cap': 32, 'selector_param1': 0, 'stack_policy': 0, 'max_stacks': 1, 'stacks': 1, 'lifecycle': 0, 'duration_days': -1, 'target_domain': 2, 'priority': 0, 'ramp': None, 'radius': 0, 'cap': 0, 'per_source': None}], [{'key': 'sericulture_l3', 'summary': '主产布的地块周围 1 格（最多 32 格）：精致服装产出 +20%', 'tags': ['cell.produces.cloth'], 'cmds': [{'modifier': 'economy.city.good.fine_clothing.output_factor', 'value': 0.2, 'duration_days': -1, 'stacks': 1, 'domain': None, 'magnitude_q16': None}], 'conds': [], 'selector': 14, 'selector_cap': 32, 'selector_param1': 0, 'stack_policy': 0, 'max_stacks': 1, 'stacks': 1, 'lifecycle': 0, 'duration_days': -1, 'target_domain': 2, 'priority': 0, 'ramp': None, 'radius': 0, 'cap': 0, 'per_source': None}]]`

## 远洋公司 (`ocean_company`)
- 学派：商贸；时代：探索时代；稀有度：3
- 额外科技：tech.global_exchange
- 卡面描述：以股份与特许组织远洋贸易，财富涌入也加速了船料与木林的消耗。
- 基础项：`[['country.trade.capacity_factor', 1.07], ['country.trade.speed_factor', 1.05], ['country.resource.timber.use_factor', 1.04]]`

## 特许航路 (`chartered_route`)
- 学派：商贸；时代：探索时代；稀有度：2；排他组：economic_order
- 研究信号：contact.maritime_vessel
- 卡面描述：把航线、港口与补给点连成一张特许网络，香料与糖源源而来，盐业受挤。
- 基础项：`[['country.output.good.salt_factor', 0.97]]`
- 程序等级项：`[[{'key': 'chartered_route_l1', 'summary': '每种专精物资使繁市地块全部产出 +1%（上限 +15%）', 'tags': ['cell.market'], 'cmds': [{'modifier': 'economy.city.output_factor', 'value': 0.01, 'duration_days': -1, 'stacks': 1, 'domain': None, 'magnitude_q16': None}], 'conds': [], 'selector': 12, 'selector_cap': 32, 'selector_param1': 0, 'stack_policy': 0, 'max_stacks': 1, 'stacks': 1, 'lifecycle': 0, 'duration_days': -1, 'target_domain': 2, 'priority': 0, 'ramp': {'metric': 'country.distinct_specialized_good_count', 'per': 0.01, 'cap': 15}, 'radius': 0, 'cap': 0, 'per_source': None}], [{'key': 'chartered_route_l2', 'summary': '每种专精物资使繁市地块全部产出 +1.5%（上限 +15%）', 'tags': ['cell.market'], 'cmds': [{'modifier': 'economy.city.output_factor', 'value': 0.015, 'duration_days': -1, 'stacks': 1, 'domain': None, 'magnitude_q16': None}], 'conds': [], 'selector': 12, 'selector_cap': 32, 'selector_param1': 0, 'stack_policy': 0, 'max_stacks': 1, 'stacks': 1, 'lifecycle': 0, 'duration_days': -1, 'target_domain': 2, 'priority': 0, 'ramp': {'metric': 'country.distinct_specialized_good_count', 'per': 0.015, 'cap': 10}, 'radius': 0, 'cap': 0, 'per_source': None}], [{'key': 'chartered_route_l3', 'summary': '每种专精物资使繁市地块全部产出 +2%（上限 +15%）', 'tags': ['cell.market'], 'cmds': [{'modifier': 'economy.city.output_factor', 'value': 0.02, 'duration_days': -1, 'stacks': 1, 'domain': None, 'magnitude_q16': None}], 'conds': [], 'selector': 12, 'selector_cap': 32, 'selector_param1': 0, 'stack_policy': 0, 'max_stacks': 1, 'stacks': 1, 'lifecycle': 0, 'duration_days': -1, 'target_domain': 2, 'priority': 0, 'ramp': {'metric': 'country.distinct_specialized_good_count', 'per': 0.02, 'cap': 7.5}, 'radius': 0, 'cap': 0, 'per_source': None}]]`

## 舆图测绘 (`cartography`)
- 学派：学识；时代：探索时代；稀有度：2
- 研究信号：landform.coast
- 卡面描述：以经纬、罗盘与实测修订海图，远航代价下降，测绘本身也是开销。
- 基础项：`[['country.research.science_efficiency', 1.04], ['country.trade.speed_factor', 1.05], ['country.construction.cost_factor', 1.02]]`

## 殖民种植园 (`colonial_plantation`)
- 学派：农本；时代：探索时代；稀有度：2；排他组：land_order
- 研究信号：landform.monsoon_basin
- 卡面描述：以单一作物大规模开垦，产量惊人，地力与林地迅速被抽干。
- 基础项：`[['country.output.terrain.jungle.agriculture_factor', 1.1], ['country.output.good.cotton_fiber_factor', 1.06], ['country.resource.fertile_soil.use_factor', 1.08], ['country.resource.fertile_soil.managed_generation_factor', 0.92]]`

## 白银流入 (`silver_flow`)
- 学派：商贸；时代：探索时代；稀有度：3；排他组：economic_order
- 研究信号：resource.silver_ore
- 卡面描述：海外白银持续涌入，物价与交易规模一起被推高，银矿被疯狂开采。
- 基础项：`[['country.resource.silver_ore.use_factor', 1.1]]`
- 程序等级项：`[[{'key': 'silver_flow_l1', 'summary': '每个主产白银地块使白银地块全部产出 +3%（上限 +15%）', 'tags': ['cell.produces.silver'], 'cmds': [{'modifier': 'economy.city.output_factor', 'value': 0.03, 'duration_days': -1, 'stacks': 1, 'domain': None, 'magnitude_q16': None}], 'conds': [], 'selector': 12, 'selector_cap': 32, 'selector_param1': 0, 'stack_policy': 0, 'max_stacks': 1, 'stacks': 1, 'lifecycle': 0, 'duration_days': -1, 'target_domain': 2, 'priority': 0, 'ramp': {'metric': 'country.silver_cell_count', 'per': 0.03, 'cap': 5}, 'radius': 0, 'cap': 0, 'per_source': None}], [{'key': 'silver_flow_l2', 'summary': '每个主产白银地块使白银地块全部产出 +3%（上限 +21%）', 'tags': ['cell.produces.silver'], 'cmds': [{'modifier': 'economy.city.output_factor', 'value': 0.03, 'duration_days': -1, 'stacks': 1, 'domain': None, 'magnitude_q16': None}], 'conds': [], 'selector': 12, 'selector_cap': 32, 'selector_param1': 0, 'stack_policy': 0, 'max_stacks': 1, 'stacks': 1, 'lifecycle': 0, 'duration_days': -1, 'target_domain': 2, 'priority': 0, 'ramp': {'metric': 'country.silver_cell_count', 'per': 0.03, 'cap': 7}, 'radius': 0, 'cap': 0, 'per_source': None}], [{'key': 'silver_flow_l3', 'summary': '每个主产白银地块使白银地块全部产出 +3%（上限 +27%）', 'tags': ['cell.produces.silver'], 'cmds': [{'modifier': 'economy.city.output_factor', 'value': 0.03, 'duration_days': -1, 'stacks': 1, 'domain': None, 'magnitude_q16': None}], 'conds': [], 'selector': 12, 'selector_cap': 32, 'selector_param1': 0, 'stack_policy': 0, 'max_stacks': 1, 'stacks': 1, 'lifecycle': 0, 'duration_days': -1, 'target_domain': 2, 'priority': 0, 'ramp': {'metric': 'country.silver_cell_count', 'per': 0.03, 'cap': 9}, 'radius': 0, 'cap': 0, 'per_source': None}]]`

## 博物志 (`natural_history`)
- 学派：学识；时代：探索时代；稀有度：2
- 卡面描述：标本、分类与田野记录并行，农业与科学的边界开始相接，纯粹思辨退场。
- 基础项：`[['country.research.science_efficiency', 1.05], ['country.research.agriculture_efficiency', 1.04], ['country.output.knowledge_factor', 0.98]]`

## 工场规程 (`manufactory_regulation`)
- 学派：工造；时代：探索时代；稀有度：2
- 卡面描述：以工序章程约束手工工场，用料被重新安排，周转反被规矩拖慢。
- 基础项：`[['country.output.good.metal_housewares_factor', 1.06], ['country.production.input_factor', 0.97], ['country.trade.speed_factor', 0.98]]`

## 海事保险 (`maritime_insurance`)
- 学派：商贸；时代：探索时代；稀有度：2
- 研究信号：contact.maritime_vessel
- 卡面描述：分摊海难风险，远洋船队敢走更远的航线，保费最终摊到每一户的消费上。
- 基础项：`[['country.trade.capacity_factor', 1.05], ['country.household.consumption_factor', 1.02]]`

## 乡绅 (`gentry_patronage`)
- 学派：学识；时代：探索时代；稀有度：1
- 卡面描述：乡绅办学、修桥、赈济，乡土文教随之兴旺，佃户却更难自立。
- 等级项：`[[['economy.profession.tenant_farmer.satisfaction_bp', -200.0, 0], ['economy.profession.sharecropper.satisfaction_bp', -200.0, 0], ['economy.profession.serf.satisfaction_bp', -200.0, 0]], [['economy.profession.tenant_farmer.satisfaction_bp', -200.0, 0], ['economy.profession.sharecropper.satisfaction_bp', -200.0, 0], ['economy.profession.serf.satisfaction_bp', -200.0, 0]], [['economy.profession.tenant_farmer.satisfaction_bp', -200.0, 0], ['economy.profession.sharecropper.satisfaction_bp', -200.0, 0], ['economy.profession.serf.satisfaction_bp', -200.0, 0]]]`

## 实验之法 (`experimental_method`)
- 学派：学识；时代：启蒙时代；稀有度：2
- 额外科技：tech.enlightenment_institutions
- 卡面描述：以可重复的实验代替权威，工程与自然研究同步大进，经世之学受冷落。
- 基础项：`[['country.research.science_efficiency', 1.06], ['country.research.engineering_efficiency', 1.05], ['country.research.society_efficiency', 0.97]]`

## 百科全书 (`encyclopedia`)
- 学派：学识；时代：启蒙时代；稀有度：3
- 额外科技：tech.enlightenment_institutions
- 卡面描述：把天下之学编为一部可查可证的书，知识流通不可逆，编纂耗费巨大。
- 基础项：`[['country.research.institution_output_factor', 1.06], ['country.output.knowledge_factor', 1.05], ['country.ideology.point_gain_factor', 1.08], ['country.construction.cost_factor', 1.03]]`

## 国民教育 (`national_education`)
- 学派：动员；时代：启蒙时代；稀有度：2
- 额外科技：tech.enlightenment_institutions
- 卡面描述：义务教育塑造统一语言与技艺，研究与理念同时受益，家计负担上升。
- 基础项：`[['country.research.society_efficiency', 1.05], ['country.research.engineering_efficiency', 1.03], ['country.ideology.point_gain_factor', 1.04], ['country.household.consumption_factor', 1.03]]`

## 农政改革 (`agrarian_reform`)
- 学派：农本；时代：启蒙时代；稀有度：2；排他组：land_order
- 卡面描述：清丈田亩、整顿租佃，粮产与地权都更清楚，旧有乡约秩序被削弱。
- 基础项：`[['country.output.good.wheat_grain_factor', 1.06], ['country.output.terrain.plain.agriculture_factor', 1.06], ['country.research.society_efficiency', 0.97]]`

## 煤田开发 (`coal_basin`)
- 学派：工造；时代：启蒙时代；稀有度：2；排他组：land_order
- 研究信号：resource.coal
- 卡面描述：沿煤层开凿矿井与洗煤厂，能源充裕而矿脉消耗极快。
- 基础项：`[['country.resource.coal.use_factor', 1.06]]`
- 程序等级项：`[[{'key': 'coal_basin_l1', 'summary': '矿业支柱地块（最多 32 格）：矿业产出 +20%', 'tags': ['cell.sector.extractive'], 'cmds': [{'modifier': 'economy.city.building.extractive_output_factor', 'value': 0.2, 'duration_days': -1, 'stacks': 1, 'domain': None, 'magnitude_q16': None}], 'conds': [], 'selector': 12, 'selector_cap': 32, 'selector_param1': 0, 'stack_policy': 0, 'max_stacks': 1, 'stacks': 1, 'lifecycle': 0, 'duration_days': -1, 'target_domain': 2, 'priority': 0, 'ramp': None, 'radius': 0, 'cap': 0, 'per_source': None}], [{'key': 'coal_basin_l2', 'summary': '矿业支柱地块（最多 32 格）：矿业产出 +28%', 'tags': ['cell.sector.extractive'], 'cmds': [{'modifier': 'economy.city.building.extractive_output_factor', 'value': 0.28, 'duration_days': -1, 'stacks': 1, 'domain': None, 'magnitude_q16': None}], 'conds': [], 'selector': 12, 'selector_cap': 32, 'selector_param1': 0, 'stack_policy': 0, 'max_stacks': 1, 'stacks': 1, 'lifecycle': 0, 'duration_days': -1, 'target_domain': 2, 'priority': 0, 'ramp': None, 'radius': 0, 'cap': 0, 'per_source': None}], [{'key': 'coal_basin_l3', 'summary': '矿业支柱地块（最多 32 格）：矿业产出 +32%', 'tags': ['cell.sector.extractive'], 'cmds': [{'modifier': 'economy.city.building.extractive_output_factor', 'value': 0.32, 'duration_days': -1, 'stacks': 1, 'domain': None, 'magnitude_q16': None}], 'conds': [], 'selector': 12, 'selector_cap': 32, 'selector_param1': 0, 'stack_policy': 0, 'max_stacks': 1, 'stacks': 1, 'lifecycle': 0, 'duration_days': -1, 'target_domain': 2, 'priority': 0, 'ramp': None, 'radius': 0, 'cap': 0, 'per_source': None}]]`

## 轧棉 (`cotton_gin`)
- 学派：工造；时代：启蒙时代；稀有度：2
- 研究信号：bio.cotton
- 卡面描述：以机械脱籽代替手工，棉花纤维的可用量大增，棉田挤占了粮田。
- 基础项：`[['country.output.terrain.plain.agriculture_factor', 0.97]]`
- 程序等级项：`[[{'key': 'cotton_gin_l1', 'summary': '主产棉纤维的地块周围 2 格（最多 32 格）：布产出 +10%', 'tags': ['cell.produces.cotton_fiber'], 'cmds': [{'modifier': 'economy.city.good.cloth.output_factor', 'value': 0.1, 'duration_days': -1, 'stacks': 1, 'domain': None, 'magnitude_q16': None}], 'conds': [], 'selector': 15, 'selector_cap': 32, 'selector_param1': 0, 'stack_policy': 0, 'max_stacks': 1, 'stacks': 1, 'lifecycle': 0, 'duration_days': -1, 'target_domain': 2, 'priority': 0, 'ramp': None, 'radius': 0, 'cap': 0, 'per_source': None}], [{'key': 'cotton_gin_l2', 'summary': '主产棉纤维的地块周围 2 格（最多 32 格）：布产出 +14%', 'tags': ['cell.produces.cotton_fiber'], 'cmds': [{'modifier': 'economy.city.good.cloth.output_factor', 'value': 0.14, 'duration_days': -1, 'stacks': 1, 'domain': None, 'magnitude_q16': None}], 'conds': [], 'selector': 15, 'selector_cap': 32, 'selector_param1': 0, 'stack_policy': 0, 'max_stacks': 1, 'stacks': 1, 'lifecycle': 0, 'duration_days': -1, 'target_domain': 2, 'priority': 0, 'ramp': None, 'radius': 0, 'cap': 0, 'per_source': None}], [{'key': 'cotton_gin_l3', 'summary': '主产棉纤维的地块周围 2 格（最多 32 格）：布产出 +18%', 'tags': ['cell.produces.cotton_fiber'], 'cmds': [{'modifier': 'economy.city.good.cloth.output_factor', 'value': 0.18, 'duration_days': -1, 'stacks': 1, 'domain': None, 'magnitude_q16': None}], 'conds': [], 'selector': 15, 'selector_cap': 32, 'selector_param1': 0, 'stack_policy': 0, 'max_stacks': 1, 'stacks': 1, 'lifecycle': 0, 'duration_days': -1, 'target_domain': 2, 'priority': 0, 'ramp': None, 'radius': 0, 'cap': 0, 'per_source': None}]]`

## 圈地 (`enclosure`)
- 学派：农本；时代：启蒙时代；稀有度：2；排他组：land_order
- 卡面描述：以篱界并小块为牧场，畜产与牧草再生大增，小农与谷物让位。
- 基础项：`[['country.output.terrain.grassland.agriculture_factor', 1.08], ['country.resource.pasture.managed_generation_factor', 1.1], ['country.output.terrain.plain.agriculture_factor', 0.96], ['country.research.society_efficiency', 0.97]]`

## 地租论 (`land_value`)
- 学派：农本；时代：启蒙时代；稀有度：1
- 卡面描述：地价上涨，地主付得起地税，城郊农业也随大邑兴起。
- 等级项：`[[['economy.profession.landlord.tax_tolerance_factor', 1.15]], [['economy.profession.landlord.tax_tolerance_factor', 1.2]], [['economy.profession.landlord.tax_tolerance_factor', 1.2]]]`
- 程序等级项：`[[{'key': 'land_value_l1', 'summary': '大邑地块（最多 32 格）：住房需求 +5%（地价推高居住成本）', 'tags': ['cell.metropolis'], 'cmds': [{'modifier': 'economy.city.need.housing.consumption_factor', 'value': 0.05, 'duration_days': -1, 'stacks': 1, 'domain': None, 'magnitude_q16': None}], 'conds': [], 'selector': 12, 'selector_cap': 32, 'selector_param1': 0, 'stack_policy': 0, 'max_stacks': 1, 'stacks': 1, 'lifecycle': 0, 'duration_days': -1, 'target_domain': 2, 'priority': 0, 'ramp': None, 'radius': 0, 'cap': 0, 'per_source': None}], [{'key': 'land_value_l2', 'summary': '大邑地块（最多 32 格）：住房需求 +5%', 'tags': ['cell.metropolis'], 'cmds': [{'modifier': 'economy.city.need.housing.consumption_factor', 'value': 0.05, 'duration_days': -1, 'stacks': 1, 'domain': None, 'magnitude_q16': None}], 'conds': [], 'selector': 12, 'selector_cap': 32, 'selector_param1': 0, 'stack_policy': 0, 'max_stacks': 1, 'stacks': 1, 'lifecycle': 0, 'duration_days': -1, 'target_domain': 2, 'priority': 0, 'ramp': None, 'radius': 0, 'cap': 0, 'per_source': None}], [{'key': 'land_value_l3', 'summary': '大邑地块（最多 32 格）：住房需求 +5%', 'tags': ['cell.metropolis'], 'cmds': [{'modifier': 'economy.city.need.housing.consumption_factor', 'value': 0.05, 'duration_days': -1, 'stacks': 1, 'domain': None, 'magnitude_q16': None}], 'conds': [], 'selector': 12, 'selector_cap': 32, 'selector_param1': 0, 'stack_policy': 0, 'max_stacks': 1, 'stacks': 1, 'lifecycle': 0, 'duration_days': -1, 'target_domain': 2, 'priority': 0, 'ramp': None, 'radius': 0, 'cap': 0, 'per_source': None}]]`

## 学会 (`learned_society`)
- 学派：学识；时代：启蒙时代；稀有度：2
- 卡面描述：以通信、期刊与同行评议组织学问，研究效率上升，会务与出版耗费不轻。
- 基础项：`[['country.research.institution_output_factor', 1.05], ['country.ideology.point_gain_factor', 1.05], ['country.production.input_factor', 1.02]]`

## 摊丁入亩 (`land_tax_reform`)
- 学派：农本；时代：启蒙时代；稀有度：2；排他组：land_order
- 额外科技：tech.enlightenment_institutions
- 卡面描述：把丁银摊入田亩，无地者不再负担人头税，田多的地主税负随之加重。
- 等级项：`[[['economy.profession.household_farmer.tax_tolerance_factor', 1.3], ['economy.profession.subsistence_farmer.tax_tolerance_factor', 1.3], ['economy.profession.tenant_farmer.tax_tolerance_factor', 1.3], ['economy.profession.sharecropper.tax_tolerance_factor', 1.3], ['economy.profession.agricultural_worker.tax_tolerance_factor', 1.3], ['economy.profession.serf.tax_tolerance_factor', 1.3], ['economy.profession.landlord.satisfaction_bp', -800.0, 0], ['country.research.society_efficiency', 0.97]], [['economy.profession.household_farmer.tax_tolerance_factor', 1.45], ['economy.profession.subsistence_farmer.tax_tolerance_factor', 1.45], ['economy.profession.tenant_farmer.tax_tolerance_factor', 1.45], ['economy.profession.sharecropper.tax_tolerance_factor', 1.45], ['economy.profession.agricultural_worker.tax_tolerance_factor', 1.45], ['economy.profession.serf.tax_tolerance_factor', 1.45], ['economy.profession.landlord.satisfaction_bp', -1000.0, 0], ['country.research.society_efficiency', 0.97]], [['economy.profession.household_farmer.tax_tolerance_factor', 1.45], ['economy.profession.subsistence_farmer.tax_tolerance_factor', 1.45], ['economy.profession.tenant_farmer.tax_tolerance_factor', 1.45], ['economy.profession.sharecropper.tax_tolerance_factor', 1.45], ['economy.profession.agricultural_worker.tax_tolerance_factor', 1.45], ['economy.profession.serf.tax_tolerance_factor', 1.45], ['economy.profession.landlord.satisfaction_bp', -1000.0, 0], ['country.research.society_efficiency', 0.97]]]`
- 程序等级项：`[[], [], [{'key': 'land_tax_reform_l3', 'summary': '轻税的农业支柱地块（实测净税负 ≤ 8%，最多 32 格）：出生率 +8%', 'tags': ['cell.sector.agriculture'], 'cmds': [{'modifier': 'economy.city.birth_factor', 'value': 0.08, 'duration_days': -1, 'stacks': 1, 'domain': None, 'magnitude_q16': None}], 'conds': [{'op': 3, 'arg0': 68, 'value_q16': 5242}], 'selector': 12, 'selector_cap': 32, 'selector_param1': 0, 'stack_policy': 0, 'max_stacks': 1, 'stacks': 1, 'lifecycle': 0, 'duration_days': -1, 'target_domain': 2, 'priority': 0, 'ramp': None, 'radius': 0, 'cap': 0, 'per_source': None}]]`

## 消费税制 (`excise`)
- 学派：商贸；时代：启蒙时代；稀有度：1
- 额外科技：tech.enlightenment_institutions
- 卡面描述：对奢侈品开征消费税，国库得到稳定进项，这些货物的负担落到用得起的人身上。

## 蒸汽动力 (`steam_power`)
- 学派：工造；时代：蒸汽时代；稀有度：2
- 额外科技：tech.industrialization
- 研究信号：resource.coal
- 卡面描述：以蒸汽机取代水力与畜力，能源与制造同时跃进，煤耗随之暴涨。
- 基础项：`[['country.output.energy_factor', 1.06], ['country.output.manufacturing_factor', 1.03], ['country.resource.coal.use_factor', 1.05]]`

## 铁路网 (`railway_network`)
- 学派：工造；时代：蒸汽时代；稀有度：2
- 卡面描述：钢轨把内陆与港口缝在一起，货运速度从此改换量级，平原沿线的工坊先被点亮，路基造价高昂。
- 基础项：`[['country.trade.speed_factor', 1.08], ['country.trade.capacity_factor', 1.04], ['country.output.terrain.plain.manufacturing_factor', 1.05], ['country.construction.cost_factor', 1.04]]`

## 城市卫生 (`urban_sanitation`)
- 学派：动员；时代：蒸汽时代；稀有度：2
- 卡面描述：下水道、自来水与皂厂让拥挤的城市不再自我毒害，管网投资巨大。
- 基础项：`[['country.construction.cost_factor', 1.03]]`
- 程序等级项：`[[{'key': 'urban_sanitation_l1', 'summary': '大邑地块（最多 32 格）：全部产出 +8%', 'tags': ['cell.metropolis'], 'cmds': [{'modifier': 'economy.city.output_factor', 'value': 0.08, 'duration_days': -1, 'stacks': 1, 'domain': None, 'magnitude_q16': None}], 'conds': [], 'selector': 12, 'selector_cap': 32, 'selector_param1': 0, 'stack_policy': 0, 'max_stacks': 1, 'stacks': 1, 'lifecycle': 0, 'duration_days': -1, 'target_domain': 2, 'priority': 0, 'ramp': None, 'radius': 0, 'cap': 0, 'per_source': None}], [{'key': 'urban_sanitation_l2', 'summary': '大邑地块（最多 32 格）：全部产出 +12%', 'tags': ['cell.metropolis'], 'cmds': [{'modifier': 'economy.city.output_factor', 'value': 0.12, 'duration_days': -1, 'stacks': 1, 'domain': None, 'magnitude_q16': None}], 'conds': [], 'selector': 12, 'selector_cap': 32, 'selector_param1': 0, 'stack_policy': 0, 'max_stacks': 1, 'stacks': 1, 'lifecycle': 0, 'duration_days': -1, 'target_domain': 2, 'priority': 0, 'ramp': None, 'radius': 0, 'cap': 0, 'per_source': None}], [{'key': 'urban_sanitation_l3', 'summary': '大邑地块（最多 32 格）：全部产出 +14%', 'tags': ['cell.metropolis'], 'cmds': [{'modifier': 'economy.city.output_factor', 'value': 0.14, 'duration_days': -1, 'stacks': 1, 'domain': None, 'magnitude_q16': None}], 'conds': [], 'selector': 12, 'selector_cap': 32, 'selector_param1': 0, 'stack_policy': 0, 'max_stacks': 1, 'stacks': 1, 'lifecycle': 0, 'duration_days': -1, 'target_domain': 2, 'priority': 0, 'ramp': None, 'radius': 0, 'cap': 0, 'per_source': None}]]`

## 汽船航运 (`steam_shipping`)
- 学派：商贸；时代：蒸汽时代；稀有度：2
- 卡面描述：定期汽船班轮取代风帆，贸易容量与速度同步上升，锅炉张着嘴烧煤。
- 基础项：`[['country.trade.capacity_factor', 1.06], ['country.trade.speed_factor', 1.04], ['country.resource.coal.use_factor', 1.04]]`

## 劳动立法 (`labour_legislation`)
- 学派：动员；时代：蒸汽时代；稀有度：2；排他组：labor_order
- 卡面描述：限定工时、承认工会，工人生活压力减轻，用工成本上升。
- 基础项：`[['country.household.consumption_factor', 0.98], ['country.production.input_factor', 1.02]]`

## 自由贸易 (`free_trade`)
- 学派：商贸；时代：蒸汽时代；稀有度：2；排他组：economic_order
- 卡面描述：撤除关税壁垒，贸易容量大涨，本国制造在进口货面前没有遮拦。
- 基础项：`[['country.trade.capacity_factor', 1.07], ['country.output.terrain.plain.manufacturing_factor', 0.97]]`

## 农业化学 (`agricultural_chemistry`)
- 学派：农本；时代：蒸汽时代；稀有度：2
- 研究信号：resource.phosphate_rock
- 卡面描述：以磷矿与硝酸盐造肥，旱地单产大涨，矿源与水体同时承压。
- 基础项：`[['country.resource.phosphate_rock.use_factor', 1.08]]`
- 程序等级项：`[[{'key': 'agricultural_chemistry_l1', 'summary': '主产化肥的地块周围 2 格（最多 32 格）：农业产出 +8%', 'tags': ['cell.produces.fertilizer'], 'cmds': [{'modifier': 'economy.city.building.agriculture_output_factor', 'value': 0.08, 'duration_days': -1, 'stacks': 1, 'domain': None, 'magnitude_q16': None}], 'conds': [], 'selector': 15, 'selector_cap': 32, 'selector_param1': 0, 'stack_policy': 0, 'max_stacks': 1, 'stacks': 1, 'lifecycle': 0, 'duration_days': -1, 'target_domain': 2, 'priority': 0, 'ramp': None, 'radius': 0, 'cap': 0, 'per_source': None}], [{'key': 'agricultural_chemistry_l2', 'summary': '主产化肥的地块周围 2 格（最多 32 格）：农业产出 +11%', 'tags': ['cell.produces.fertilizer'], 'cmds': [{'modifier': 'economy.city.building.agriculture_output_factor', 'value': 0.11, 'duration_days': -1, 'stacks': 1, 'domain': None, 'magnitude_q16': None}], 'conds': [], 'selector': 15, 'selector_cap': 32, 'selector_param1': 0, 'stack_policy': 0, 'max_stacks': 1, 'stacks': 1, 'lifecycle': 0, 'duration_days': -1, 'target_domain': 2, 'priority': 0, 'ramp': None, 'radius': 0, 'cap': 0, 'per_source': None}], [{'key': 'agricultural_chemistry_l3', 'summary': '主产化肥的地块周围 2 格（最多 32 格）：农业产出 +14%', 'tags': ['cell.produces.fertilizer'], 'cmds': [{'modifier': 'economy.city.building.agriculture_output_factor', 'value': 0.14, 'duration_days': -1, 'stacks': 1, 'domain': None, 'magnitude_q16': None}], 'conds': [], 'selector': 15, 'selector_cap': 32, 'selector_param1': 0, 'stack_policy': 0, 'max_stacks': 1, 'stacks': 1, 'lifecycle': 0, 'duration_days': -1, 'target_domain': 2, 'priority': 0, 'ramp': None, 'radius': 0, 'cap': 0, 'per_source': None}]]`

## 电报 (`telegraph`)
- 学派：学识；时代：蒸汽时代；稀有度：2
- 卡面描述：以电线传递消息，商情与政令同时提速，线路维护是一笔常年开销。
- 基础项：`[['country.trade.speed_factor', 1.05], ['country.research.society_efficiency', 1.03], ['country.construction.cost_factor', 1.02]]`

## 流水线 (`assembly_line`)
- 学派：工造；时代：电气时代；稀有度：3
- 额外科技：tech.electrical_society
- 卡面描述：以传送带与工序分解组织大规模生产，物料极省而原料吞吐陡增。
- 基础项：`[['country.output.manufacturing_factor', 1.07], ['country.production.input_factor', 0.96], ['country.resource.use_factor', 1.04]]`

## 电气化 (`electrification`)
- 学派：工造；时代：电气时代；稀有度：3
- 卡面描述：以电网覆盖城乡，动力可以远距离输送到每一台机器，发电仍靠烧煤。
- 基础项：`[['country.resource.coal.use_factor', 1.05]]`
- 程序等级项：`[[{'key': 'electrification_l1', 'summary': '能源支柱地块周围 2 格（最多 32 格）：工业产出 +8%', 'tags': ['cell.sector.energy'], 'cmds': [{'modifier': 'economy.city.building.manufacturing_output_factor', 'value': 0.08, 'duration_days': -1, 'stacks': 1, 'domain': None, 'magnitude_q16': None}], 'conds': [], 'selector': 15, 'selector_cap': 32, 'selector_param1': 0, 'stack_policy': 0, 'max_stacks': 1, 'stacks': 1, 'lifecycle': 0, 'duration_days': -1, 'target_domain': 2, 'priority': 0, 'ramp': None, 'radius': 0, 'cap': 0, 'per_source': None}], [{'key': 'electrification_l2', 'summary': '能源支柱地块周围 2 格（最多 32 格）：工业产出 +12%', 'tags': ['cell.sector.energy'], 'cmds': [{'modifier': 'economy.city.building.manufacturing_output_factor', 'value': 0.12, 'duration_days': -1, 'stacks': 1, 'domain': None, 'magnitude_q16': None}], 'conds': [], 'selector': 15, 'selector_cap': 32, 'selector_param1': 0, 'stack_policy': 0, 'max_stacks': 1, 'stacks': 1, 'lifecycle': 0, 'duration_days': -1, 'target_domain': 2, 'priority': 0, 'ramp': None, 'radius': 0, 'cap': 0, 'per_source': None}], [{'key': 'electrification_l3', 'summary': '能源支柱地块周围 2 格（最多 32 格）：工业产出 +15%', 'tags': ['cell.sector.energy'], 'cmds': [{'modifier': 'economy.city.building.manufacturing_output_factor', 'value': 0.15, 'duration_days': -1, 'stacks': 1, 'domain': None, 'magnitude_q16': None}], 'conds': [], 'selector': 15, 'selector_cap': 32, 'selector_param1': 0, 'stack_policy': 0, 'max_stacks': 1, 'stacks': 1, 'lifecycle': 0, 'duration_days': -1, 'target_domain': 2, 'priority': 0, 'ramp': None, 'radius': 0, 'cap': 0, 'per_source': None}]]`

## 生态均衡 (`ecological_balance`)
- 学派：调和；时代：电气时代；稀有度：3
- 额外科技：tech.electrical_society
- 卡面描述：以循环与修复约束工业增长，资源与人口得到长期平衡，产能让步。
- 基础项：`[['country.output.manufacturing_factor', 0.97]]`
- 程序等级项：`[[{'key': 'ecological_balance_l1_rich', 'summary': '富饶地块（最多 32 格）：全部产出 +10%', 'tags': ['cell.abundant'], 'cmds': [{'modifier': 'economy.city.output_factor', 'value': 0.1, 'duration_days': -1, 'stacks': 1, 'domain': None, 'magnitude_q16': None}], 'conds': [], 'selector': 12, 'selector_cap': 32, 'selector_param1': 0, 'stack_policy': 0, 'max_stacks': 1, 'stacks': 1, 'lifecycle': 0, 'duration_days': -1, 'target_domain': 2, 'priority': 0, 'ramp': None, 'radius': 0, 'cap': 0, 'per_source': None}, {'key': 'ecological_balance_l1_dry', 'summary': '枯竭地块（最多 32 格）：全部产出 -5%', 'tags': ['cell.depleted'], 'cmds': [{'modifier': 'economy.city.output_factor', 'value': -0.05, 'duration_days': -1, 'stacks': 1, 'domain': None, 'magnitude_q16': None}], 'conds': [], 'selector': 12, 'selector_cap': 32, 'selector_param1': 0, 'stack_policy': 0, 'max_stacks': 1, 'stacks': 1, 'lifecycle': 0, 'duration_days': -1, 'target_domain': 2, 'priority': 0, 'ramp': None, 'radius': 0, 'cap': 0, 'per_source': None}], [{'key': 'ecological_balance_l2_rich', 'summary': '富饶地块（最多 32 格）：全部产出 +14%', 'tags': ['cell.abundant'], 'cmds': [{'modifier': 'economy.city.output_factor', 'value': 0.14, 'duration_days': -1, 'stacks': 1, 'domain': None, 'magnitude_q16': None}], 'conds': [], 'selector': 12, 'selector_cap': 32, 'selector_param1': 0, 'stack_policy': 0, 'max_stacks': 1, 'stacks': 1, 'lifecycle': 0, 'duration_days': -1, 'target_domain': 2, 'priority': 0, 'ramp': None, 'radius': 0, 'cap': 0, 'per_source': None}, {'key': 'ecological_balance_l2_dry', 'summary': '枯竭地块（最多 32 格）：全部产出 -5%', 'tags': ['cell.depleted'], 'cmds': [{'modifier': 'economy.city.output_factor', 'value': -0.05, 'duration_days': -1, 'stacks': 1, 'domain': None, 'magnitude_q16': None}], 'conds': [], 'selector': 12, 'selector_cap': 32, 'selector_param1': 0, 'stack_policy': 0, 'max_stacks': 1, 'stacks': 1, 'lifecycle': 0, 'duration_days': -1, 'target_domain': 2, 'priority': 0, 'ramp': None, 'radius': 0, 'cap': 0, 'per_source': None}], [{'key': 'ecological_balance_l3_rich', 'summary': '富饶地块（最多 32 格）：全部产出 +14%，枯竭惩罚取消', 'tags': ['cell.abundant'], 'cmds': [{'modifier': 'economy.city.output_factor', 'value': 0.14, 'duration_days': -1, 'stacks': 1, 'domain': None, 'magnitude_q16': None}], 'conds': [], 'selector': 12, 'selector_cap': 32, 'selector_param1': 0, 'stack_policy': 0, 'max_stacks': 1, 'stacks': 1, 'lifecycle': 0, 'duration_days': -1, 'target_domain': 2, 'priority': 0, 'ramp': None, 'radius': 0, 'cap': 0, 'per_source': None}]]`

## 大众传媒 (`mass_media`)
- 学派：学识；时代：电气时代；稀有度：2
- 卡面描述：报纸、广播与电影把同一套叙事送进每一个家庭，深度学问被稀释。
- 基础项：`[['country.research.society_efficiency', 1.05], ['country.ideology.point_gain_factor', 1.04], ['country.output.knowledge_factor', 0.98]]`

## 化学工业 (`chemical_industry`)
- 学派：工造；时代：电气时代；稀有度：2
- 研究信号：resource.salt
- 卡面描述：以电解与合成改写原料来源，盐卤变成化工之母，副产物污染水土。
- 基础项：`[['country.output.good.industrial_chemicals_factor', 1.08], ['country.input.good.salt_factor', 0.94], ['country.resource.salt.use_factor', 1.06]]`

## 水电 (`hydroelectric`)
- 学派：工造；时代：电气时代；稀有度：2
- 研究信号：landform.river_valley
- 卡面描述：筑坝蓄水发电，谷地能源充沛，坝下平原的洪水风险反而上升。
- 等级项：`[[['country.output.terrain.floodplain.energy_factor', 1.12], ['country.output.landform.rift_valley.energy_factor', 1.12], ['country.output.landform.canyon.energy_factor', 1.12], ['country.production.input_factor', 1.03]], [['country.output.terrain.floodplain.energy_factor', 1.18], ['country.output.landform.rift_valley.energy_factor', 1.18], ['country.output.landform.canyon.energy_factor', 1.18], ['country.production.input_factor', 1.03]], [['country.output.terrain.floodplain.energy_factor', 1.18], ['country.output.landform.rift_valley.energy_factor', 1.18], ['country.output.landform.canyon.energy_factor', 1.18], ['country.production.input_factor', 1.03]]]`
- 程序等级项：`[[], [], [{'key': 'hydroelectric_l3', 'summary': '能源支柱的河谷地块周围 1 格（最多 32 格）：能源产出 +8%', 'tags': ['cell.sector.energy'], 'cmds': [{'modifier': 'economy.city.building.energy_output_factor', 'value': 0.08, 'duration_days': -1, 'stacks': 1, 'domain': None, 'magnitude_q16': None}], 'conds': [], 'selector': 15, 'selector_cap': 32, 'selector_param1': 0, 'stack_policy': 0, 'max_stacks': 1, 'stacks': 1, 'lifecycle': 0, 'duration_days': -1, 'target_domain': 2, 'priority': 0, 'ramp': None, 'radius': 0, 'cap': 0, 'per_source': None}]]`

## 反垄断 (`antitrust`)
- 学派：商贸；时代：电气时代；稀有度：2；排他组：economic_order
- 卡面描述：拆分托拉斯、恢复竞争，物价与流通受益，规模效率被牺牲。
- 基础项：`[['country.output.manufacturing_factor', 0.97]]`
- 程序等级项：`[[{'key': 'antitrust_l1_bonus', 'summary': '多元地块（最多 32 格）：全部产出 +8%', 'tags': ['cell.diversified'], 'cmds': [{'modifier': 'economy.city.output_factor', 'value': 0.08, 'duration_days': -1, 'stacks': 1, 'domain': None, 'magnitude_q16': None}], 'conds': [], 'selector': 12, 'selector_cap': 32, 'selector_param1': 0, 'stack_policy': 0, 'max_stacks': 1, 'stacks': 1, 'lifecycle': 0, 'duration_days': -1, 'target_domain': 2, 'priority': 0, 'ramp': None, 'radius': 0, 'cap': 0, 'per_source': None}, {'key': 'antitrust_l1_penalty', 'summary': '高度专精地块（最多 32 格）：全部产出 -5%', 'tags': ['cell.specialized_high'], 'cmds': [{'modifier': 'economy.city.output_factor', 'value': -0.05, 'duration_days': -1, 'stacks': 1, 'domain': None, 'magnitude_q16': None}], 'conds': [], 'selector': 12, 'selector_cap': 32, 'selector_param1': 0, 'stack_policy': 0, 'max_stacks': 1, 'stacks': 1, 'lifecycle': 0, 'duration_days': -1, 'target_domain': 2, 'priority': 0, 'ramp': None, 'radius': 0, 'cap': 0, 'per_source': None}], [{'key': 'antitrust_l2_bonus', 'summary': '多元地块（最多 32 格）：全部产出 +12%', 'tags': ['cell.diversified'], 'cmds': [{'modifier': 'economy.city.output_factor', 'value': 0.12, 'duration_days': -1, 'stacks': 1, 'domain': None, 'magnitude_q16': None}], 'conds': [], 'selector': 12, 'selector_cap': 32, 'selector_param1': 0, 'stack_policy': 0, 'max_stacks': 1, 'stacks': 1, 'lifecycle': 0, 'duration_days': -1, 'target_domain': 2, 'priority': 0, 'ramp': None, 'radius': 0, 'cap': 0, 'per_source': None}, {'key': 'antitrust_l2_penalty', 'summary': '高度专精地块（最多 32 格）：全部产出 -5%', 'tags': ['cell.specialized_high'], 'cmds': [{'modifier': 'economy.city.output_factor', 'value': -0.05, 'duration_days': -1, 'stacks': 1, 'domain': None, 'magnitude_q16': None}], 'conds': [], 'selector': 12, 'selector_cap': 32, 'selector_param1': 0, 'stack_policy': 0, 'max_stacks': 1, 'stacks': 1, 'lifecycle': 0, 'duration_days': -1, 'target_domain': 2, 'priority': 0, 'ramp': None, 'radius': 0, 'cap': 0, 'per_source': None}], [{'key': 'antitrust_l3_bonus', 'summary': '多元地块（最多 32 格）：全部产出 +12%', 'tags': ['cell.diversified'], 'cmds': [{'modifier': 'economy.city.output_factor', 'value': 0.12, 'duration_days': -1, 'stacks': 1, 'domain': None, 'magnitude_q16': None}], 'conds': [], 'selector': 12, 'selector_cap': 32, 'selector_param1': 0, 'stack_policy': 0, 'max_stacks': 1, 'stacks': 1, 'lifecycle': 0, 'duration_days': -1, 'target_domain': 2, 'priority': 0, 'ramp': None, 'radius': 0, 'cap': 0, 'per_source': None}, {'key': 'antitrust_l3_penalty', 'summary': '高度专精地块（最多 32 格）：全部产出 -3%', 'tags': ['cell.specialized_high'], 'cmds': [{'modifier': 'economy.city.output_factor', 'value': -0.03, 'duration_days': -1, 'stacks': 1, 'domain': None, 'magnitude_q16': None}], 'conds': [], 'selector': 12, 'selector_cap': 32, 'selector_param1': 0, 'stack_policy': 0, 'max_stacks': 1, 'stacks': 1, 'lifecycle': 0, 'duration_days': -1, 'target_domain': 2, 'priority': 0, 'ramp': None, 'radius': 0, 'cap': 0, 'per_source': None}]]`

## 累进税 (`progressive_tax`)
- 学派：动员；时代：电气时代；稀有度：2
- 卡面描述：重税转福利：劳动者扛得住税，资本方对同样的税率更敏感。
- 等级项：`[[['economy.profession.industrial_worker.tax_tolerance_factor', 1.2], ['economy.profession.miner.tax_tolerance_factor', 1.2], ['economy.profession.machinist.tax_tolerance_factor', 1.2], ['economy.profession.petroleum_worker.tax_tolerance_factor', 1.2], ['economy.profession.transport_worker.tax_tolerance_factor', 1.2], ['economy.profession.construction_worker.tax_tolerance_factor', 1.2], ['economy.profession.electrician.tax_tolerance_factor', 1.2], ['economy.profession.worker.tax_tolerance_factor', 1.2], ['economy.profession.industrialist.tax_tolerance_factor', 0.8], ['economy.profession.landlord.tax_tolerance_factor', 0.8], ['economy.profession.manager.tax_tolerance_factor', 0.8], {'stat': 'country.population.death_factor', 'ramp': {'metric': 'country.treasury_reserve_ratio_pct', 'per': 0.01, 'cap': 6.0}}], [['economy.profession.industrial_worker.tax_tolerance_factor', 1.3], ['economy.profession.miner.tax_tolerance_factor', 1.3], ['economy.profession.machinist.tax_tolerance_factor', 1.3], ['economy.profession.petroleum_worker.tax_tolerance_factor', 1.3], ['economy.profession.transport_worker.tax_tolerance_factor', 1.3], ['economy.profession.construction_worker.tax_tolerance_factor', 1.3], ['economy.profession.electrician.tax_tolerance_factor', 1.3], ['economy.profession.worker.tax_tolerance_factor', 1.3], ['economy.profession.industrialist.tax_tolerance_factor', 0.8], ['economy.profession.landlord.tax_tolerance_factor', 0.8], ['economy.profession.manager.tax_tolerance_factor', 0.8], {'stat': 'country.population.death_factor', 'ramp': {'metric': 'country.treasury_reserve_ratio_pct', 'per': 0.01, 'cap': 8.0}}], [['economy.profession.industrial_worker.tax_tolerance_factor', 1.3], ['economy.profession.miner.tax_tolerance_factor', 1.3], ['economy.profession.machinist.tax_tolerance_factor', 1.3], ['economy.profession.petroleum_worker.tax_tolerance_factor', 1.3], ['economy.profession.transport_worker.tax_tolerance_factor', 1.3], ['economy.profession.construction_worker.tax_tolerance_factor', 1.3], ['economy.profession.electrician.tax_tolerance_factor', 1.3], ['economy.profession.worker.tax_tolerance_factor', 1.3], ['economy.profession.industrialist.tax_tolerance_factor', 0.8], ['economy.profession.landlord.tax_tolerance_factor', 0.8], ['economy.profession.manager.tax_tolerance_factor', 0.8], {'stat': 'country.population.death_factor', 'ramp': {'metric': 'country.treasury_reserve_ratio_pct', 'per': 0.01, 'cap': 8.0}}]]`

## 百货公司 (`department_store`)
- 学派：商贸；时代：电气时代；稀有度：1
- 卡面描述：橱窗把货架变成景观，购物变成消遣，家庭开支随之水涨。

## 海上钻井 (`offshore_drilling`)
- 学派：工造；时代：原子时代；稀有度：1
- 研究信号：resource.oil
- 卡面描述：平台立在海面上，原油与天然气从浅海涌出，海岸却被工事占去。
- 基础项：`[['country.resource.oil.use_factor', 1.06]]`

## 超市 (`supermarket`)
- 学派：商贸；时代：原子时代；稀有度：1
- 卡面描述：一站式自选让采购极省，街坊小店与近郊农事都被挤走。
- 基础项：`[['country.household.consumption_factor', 1.02]]`

## 核电计划 (`nuclear_power`)
- 学派：工造；时代：原子时代；稀有度：3
- 研究信号：resource.rare_earth
- 卡面描述：以核裂变集中供能，能源产出跃升，稀有矿料成为长期负担。
- 基础项：`[['country.output.energy_factor', 1.08], ['country.output.good.electricity_factor', 1.06], ['country.resource.rare_earth.use_factor', 1.08]]`

## 抗生素 (`antibiotics`)
- 学派：调和；时代：原子时代；稀有度：3
- 卡面描述：感染不再是绝症，人口的死亡水平被永久压低，医疗投入随之常态化。
- 基础项：`[['country.population.death_factor', 0.92], ['country.production.input_factor', 1.02]]`

## 汽车社会 (`motorization`)
- 学派：商贸；时代：原子时代；稀有度：2
- 卡面描述：公路与私家车重构了城市与市场的距离，燃油消耗同步飙升。
- 基础项：`[['country.resource.oil.use_factor', 1.06]]`
- 程序等级项：`[[{'key': 'motorization_l1', 'summary': '繁市地块周围 2 格（最多 32 格）：全部产出 +4%', 'tags': ['cell.market'], 'cmds': [{'modifier': 'economy.city.output_factor', 'value': 0.04, 'duration_days': -1, 'stacks': 1, 'domain': None, 'magnitude_q16': None}], 'conds': [], 'selector': 15, 'selector_cap': 32, 'selector_param1': 0, 'stack_policy': 0, 'max_stacks': 1, 'stacks': 1, 'lifecycle': 0, 'duration_days': -1, 'target_domain': 2, 'priority': 0, 'ramp': None, 'radius': 0, 'cap': 0, 'per_source': None}], [{'key': 'motorization_l2', 'summary': '繁市地块周围 2 格（最多 32 格）：全部产出 +6%', 'tags': ['cell.market'], 'cmds': [{'modifier': 'economy.city.output_factor', 'value': 0.06, 'duration_days': -1, 'stacks': 1, 'domain': None, 'magnitude_q16': None}], 'conds': [], 'selector': 15, 'selector_cap': 32, 'selector_param1': 0, 'stack_policy': 0, 'max_stacks': 1, 'stacks': 1, 'lifecycle': 0, 'duration_days': -1, 'target_domain': 2, 'priority': 0, 'ramp': None, 'radius': 0, 'cap': 0, 'per_source': None}], [{'key': 'motorization_l3', 'summary': '繁市地块周围 2 格（最多 32 格）：全部产出 +8%', 'tags': ['cell.market'], 'cmds': [{'modifier': 'economy.city.output_factor', 'value': 0.08, 'duration_days': -1, 'stacks': 1, 'domain': None, 'magnitude_q16': None}], 'conds': [], 'selector': 15, 'selector_cap': 32, 'selector_param1': 0, 'stack_policy': 0, 'max_stacks': 1, 'stacks': 1, 'lifecycle': 0, 'duration_days': -1, 'target_domain': 2, 'priority': 0, 'ramp': None, 'radius': 0, 'cap': 0, 'per_source': None}]]`

## 绿色革命 (`green_revolution`)
- 学派：农本；时代：原子时代；稀有度：3
- 研究信号：resource.natural_gas
- 卡面描述：以合成氮肥、良种与灌溉把旱地单产推上台阶，天然气与磷矿被大量吃掉。
- 基础项：`[['country.output.terrain.plain.agriculture_factor', 1.1], ['country.output.good.fertilizer_factor', 1.06], ['country.resource.natural_gas.use_factor', 1.08], ['country.resource.phosphate_rock.use_factor', 1.06]]`

## 石化 (`petrochemical`)
- 学派：工造；时代：原子时代；稀有度：2
- 研究信号：resource.oil
- 卡面描述：以石油为原料生产塑料与合成纤维，原料端成本归零，油田压力加大。
- 基础项：`[['country.resource.oil.use_factor', 1.08]]`
- 程序等级项：`[[{'key': 'petrochemical_l1', 'summary': '主产原油的地块周围 2 格（最多 32 格）：塑料、合成纤维产出 +12%', 'tags': ['cell.produces.crude_oil'], 'cmds': [{'modifier': 'economy.city.good.plastics.output_factor', 'value': 0.12, 'duration_days': -1, 'stacks': 1, 'domain': None, 'magnitude_q16': None}, {'modifier': 'economy.city.good.synthetic_fiber.output_factor', 'value': 0.12, 'duration_days': -1, 'stacks': 1, 'domain': None, 'magnitude_q16': None}], 'conds': [], 'selector': 15, 'selector_cap': 32, 'selector_param1': 0, 'stack_policy': 0, 'max_stacks': 1, 'stacks': 1, 'lifecycle': 0, 'duration_days': -1, 'target_domain': 2, 'priority': 0, 'ramp': None, 'radius': 0, 'cap': 0, 'per_source': None}], [{'key': 'petrochemical_l2', 'summary': '主产原油的地块周围 2 格（最多 32 格）：塑料、合成纤维产出 +16%', 'tags': ['cell.produces.crude_oil'], 'cmds': [{'modifier': 'economy.city.good.plastics.output_factor', 'value': 0.16, 'duration_days': -1, 'stacks': 1, 'domain': None, 'magnitude_q16': None}, {'modifier': 'economy.city.good.synthetic_fiber.output_factor', 'value': 0.16, 'duration_days': -1, 'stacks': 1, 'domain': None, 'magnitude_q16': None}], 'conds': [], 'selector': 15, 'selector_cap': 32, 'selector_param1': 0, 'stack_policy': 0, 'max_stacks': 1, 'stacks': 1, 'lifecycle': 0, 'duration_days': -1, 'target_domain': 2, 'priority': 0, 'ramp': None, 'radius': 0, 'cap': 0, 'per_source': None}], [{'key': 'petrochemical_l3', 'summary': '主产原油的地块周围 2 格（最多 32 格）：塑料、合成纤维产出 +20%', 'tags': ['cell.produces.crude_oil'], 'cmds': [{'modifier': 'economy.city.good.plastics.output_factor', 'value': 0.2, 'duration_days': -1, 'stacks': 1, 'domain': None, 'magnitude_q16': None}, {'modifier': 'economy.city.good.synthetic_fiber.output_factor', 'value': 0.2, 'duration_days': -1, 'stacks': 1, 'domain': None, 'magnitude_q16': None}], 'conds': [], 'selector': 15, 'selector_cap': 32, 'selector_param1': 0, 'stack_policy': 0, 'max_stacks': 1, 'stacks': 1, 'lifecycle': 0, 'duration_days': -1, 'target_domain': 2, 'priority': 0, 'ramp': None, 'radius': 0, 'cap': 0, 'per_source': None}]]`

## 集装箱港 (`container_port`)
- 学派：商贸；时代：原子时代；稀有度：2
- 研究信号：landform.coast
- 卡面描述：标准箱与枢纽港把装卸成本压到接近为零，海岸带工厂直接贴上码头，深水泊位造价极高。
- 基础项：`[['country.trade.capacity_factor', 1.08], ['country.trade.speed_factor', 1.05], ['country.output.terrain.coast.manufacturing_factor', 1.05], ['country.construction.cost_factor', 1.03]]`

## 免税特区 (`tax_holiday`)
- 学派：商贸；时代：原子时代；稀有度：2
- 卡面描述：指定地块免征营业税，以一块有税基的地换取工业与贸易的聚集。
- 等级项：`[[['economy.profession.merchant.satisfaction_bp', -200.0, 0]], [['economy.profession.merchant.satisfaction_bp', -200.0, 0]], [['economy.profession.merchant.satisfaction_bp', -200.0, 0]]]`

## 福利国家 (`welfare_state`)
- 学派：动员；时代：原子时代；稀有度：3
- 卡面描述：以社会保障网兜住短缺与失业，税负与行政随之沉重。
- 基础项：`[['country.production.input_factor', 1.03]]`

## 郊区化 (`suburbanization`)
- 学派：商贸；时代：原子时代；稀有度：1
- 卡面描述：大邑向外摊开，环城地带住得宽，市中心却空了。

## 零工经济 (`gig_economy`)
- 学派：商贸；时代：信息时代；稀有度：1
- 卡面描述：按单结算的零工把闲置劳动力接入流通，稳定收入由此消失。

## 计算网络 (`computing_networks`)
- 学派：学识；时代：信息时代；稀有度：3
- 卡面描述：算力与网络成为公共基础设施，研究周期被整体压缩，机房耗电可观。
- 基础项：`[['country.construction.cost_factor', 1.02]]`
- 程序等级项：`[[{'key': 'computing_networks_l1', 'summary': '知识支柱地块（最多 32 格）：知识产出 +20%', 'tags': ['cell.sector.knowledge'], 'cmds': [{'modifier': 'economy.city.building.knowledge_output_factor', 'value': 0.2, 'duration_days': -1, 'stacks': 1, 'domain': None, 'magnitude_q16': None}], 'conds': [], 'selector': 12, 'selector_cap': 32, 'selector_param1': 0, 'stack_policy': 0, 'max_stacks': 1, 'stacks': 1, 'lifecycle': 0, 'duration_days': -1, 'target_domain': 2, 'priority': 0, 'ramp': None, 'radius': 0, 'cap': 0, 'per_source': None}], [{'key': 'computing_networks_l2', 'summary': '知识支柱地块（最多 32 格）：知识产出 +25%', 'tags': ['cell.sector.knowledge'], 'cmds': [{'modifier': 'economy.city.building.knowledge_output_factor', 'value': 0.25, 'duration_days': -1, 'stacks': 1, 'domain': None, 'magnitude_q16': None}], 'conds': [], 'selector': 12, 'selector_cap': 32, 'selector_param1': 0, 'stack_policy': 0, 'max_stacks': 1, 'stacks': 1, 'lifecycle': 0, 'duration_days': -1, 'target_domain': 2, 'priority': 0, 'ramp': None, 'radius': 0, 'cap': 0, 'per_source': None}], [{'key': 'computing_networks_l3', 'summary': '知识支柱地块（最多 32 格）：知识产出 +30%', 'tags': ['cell.sector.knowledge'], 'cmds': [{'modifier': 'economy.city.building.knowledge_output_factor', 'value': 0.3, 'duration_days': -1, 'stacks': 1, 'domain': None, 'magnitude_q16': None}], 'conds': [], 'selector': 12, 'selector_cap': 32, 'selector_param1': 0, 'stack_policy': 0, 'max_stacks': 1, 'stacks': 1, 'lifecycle': 0, 'duration_days': -1, 'target_domain': 2, 'priority': 0, 'ramp': None, 'radius': 0, 'cap': 0, 'per_source': None}]]`

## 半导体 (`semiconductor`)
- 学派：工造；时代：信息时代；稀有度：3
- 研究信号：resource.silica_sand
- 卡面描述：以高纯硅与精密光刻重塑制造业，硅砂被纯化成稀缺料。
- 基础项：`[['country.resource.silica_sand.use_factor', 1.08]]`
- 程序等级项：`[[{'key': 'semiconductor_l1', 'summary': '每个成链地块使成链地块的半导体产出 +2%（上限 +40%）', 'tags': ['cell.chained'], 'cmds': [{'modifier': 'economy.city.good.semiconductors.output_factor', 'value': 0.02, 'duration_days': -1, 'stacks': 1, 'domain': None, 'magnitude_q16': None}], 'conds': [], 'selector': 12, 'selector_cap': 32, 'selector_param1': 0, 'stack_policy': 0, 'max_stacks': 1, 'stacks': 1, 'lifecycle': 0, 'duration_days': -1, 'target_domain': 2, 'priority': 0, 'ramp': {'metric': 'country.chained_cell_count', 'per': 0.02, 'cap': 20}, 'radius': 0, 'cap': 0, 'per_source': None}], [{'key': 'semiconductor_l2', 'summary': '每个成链地块使成链地块的半导体产出 +2.5%（上限 +40%）', 'tags': ['cell.chained'], 'cmds': [{'modifier': 'economy.city.good.semiconductors.output_factor', 'value': 0.025, 'duration_days': -1, 'stacks': 1, 'domain': None, 'magnitude_q16': None}], 'conds': [], 'selector': 12, 'selector_cap': 32, 'selector_param1': 0, 'stack_policy': 0, 'max_stacks': 1, 'stacks': 1, 'lifecycle': 0, 'duration_days': -1, 'target_domain': 2, 'priority': 0, 'ramp': {'metric': 'country.chained_cell_count', 'per': 0.025, 'cap': 16}, 'radius': 0, 'cap': 0, 'per_source': None}], [{'key': 'semiconductor_l3', 'summary': '每个成链地块使成链地块的半导体产出 +3%（上限 +40%）', 'tags': ['cell.chained'], 'cmds': [{'modifier': 'economy.city.good.semiconductors.output_factor', 'value': 0.03, 'duration_days': -1, 'stacks': 1, 'domain': None, 'magnitude_q16': None}], 'conds': [], 'selector': 12, 'selector_cap': 32, 'selector_param1': 0, 'stack_policy': 0, 'max_stacks': 1, 'stacks': 1, 'lifecycle': 0, 'duration_days': -1, 'target_domain': 2, 'priority': 0, 'ramp': {'metric': 'country.chained_cell_count', 'per': 0.03, 'cap': 13.3334}, 'radius': 0, 'cap': 0, 'per_source': None}]]`

## 精准农业 (`precision_agriculture`)
- 学派：农本；时代：信息时代；稀有度：2
- 卡面描述：遥感、滴灌与变量施肥让每一块田都按需供给，前期设备投入不小。
- 基础项：`[['country.output.terrain.plain.agriculture_factor', 1.08], ['country.output.landform.plateau.agriculture_factor', 1.06], ['country.production.input_factor', 1.03]]`

## 金融化 (`financialization`)
- 学派：商贸；时代：信息时代；稀有度：3；排他组：economic_order
- 卡面描述：以资本运作而非生产获取利润，融资成本极低，实业根基被抽薄。
- 基础项：`[['country.trade.capacity_factor', 1.06], ['country.research.cost_factor', 0.96], ['country.output.manufacturing_factor', 0.96]]`

## 自动化产线 (`automation_line`)
- 学派：工造；时代：信息时代；稀有度：3
- 卡面描述：以程序控制代替人手，单位产出的物料大幅下降，设备投资却高得惊人。
- 基础项：`[['country.production.input_factor', 0.94], ['country.output.manufacturing_factor', 1.06], ['country.construction.cost_factor', 1.04]]`

## 生态城 (`arcology`)
- 学派：调和；时代：智能时代；稀有度：2
- 卡面描述：立体城把居住、生产与循环挤进一栋楼，造价与资源投入都极高。
- 基础项：`[['country.construction.cost_factor', 1.04]]`

## 基本收入 (`basic_income`)
- 学派：动员；时代：智能时代；稀有度：2
- 卡面描述：无条件发给每个人一笔钱，短缺消失，财政负担随人口增长。
- 基础项：`[['country.production.input_factor', 1.03]]`

## 循环经济 (`circular_economy`)
- 学派：调和；时代：智能时代；稀有度：2
- 卡面描述：废料重新进入生产循环，资源消耗大降，工业产出相应让路。
- 基础项：`[['country.output.manufacturing_factor', 0.97]]`

## 算法治理 (`algorithmic_governance`)
- 学派：学识；时代：智能时代；稀有度：3
- 卡面描述：以模型分配资源与名额，效率极高，解释权集中，基础科学被挤压。
- 基础项：`[['country.research.society_efficiency', 1.06], ['country.ideology.point_gain_factor', 1.05], ['country.research.science_efficiency', 0.97]]`

## 无人运输 (`autonomous_logistics`)
- 学派：商贸；时代：智能时代；稀有度：3
- 卡面描述：无人车与自动调度把运力从人力约束中解放出来，车队与系统投资极高。
- 基础项：`[['country.trade.speed_factor', 1.08], ['country.trade.capacity_factor', 1.05], ['country.construction.cost_factor', 1.03]]`

## 碳市场 (`carbon_market`)
- 学派：调和；时代：智能时代；稀有度：3
- 卡面描述：给排放定价，资源耗用被系统性压低，高耗能制造随之收缩。
- 基础项：`[['country.resource.use_factor', 0.92], ['country.output.manufacturing_factor', 0.96]]`

## 基因编辑 (`gene_editing`)
- 学派：农本；时代：智能时代；稀有度：3
- 研究信号：bio.maize
- 卡面描述：定向改造作物性状，主粮单产再上台阶，伦理争议削弱社会共识。
- 基础项：`[['country.output.terrain.plain.agriculture_factor', 1.1], ['country.population.death_factor', 0.98], ['country.research.society_efficiency', 0.97]]`

## 海水淡化 (`desalination`)
- 学派：调和；时代：智能时代；稀有度：3
- 研究信号：landform.coast
- 卡面描述：以反渗透取得淡水，海岸带可以耕种，耗电与浓盐水排放是代价。
- 基础项：`[['country.output.terrain.coast.agriculture_factor', 1.06], ['country.resource.freshwater_fish.managed_generation_factor', 1.06], ['country.production.input_factor', 1.03]]`

# 命名协同（15）

- `granary_records` 仓廪簿籍：成员 collective_stewardship, scholar_office；效果 `[['country.climate.drought_loss_factor', 0.95], ['country.output.terrain.plain.agriculture_factor', 1.03]]`
- `polder_farming` 圩田：成员 paddy_cultivation, water_works；效果 `[['country.climate.profile.paddy_crop.flood_loss_factor', 0.92], ['country.output.landform.delta.agriculture_factor', 1.04]]`
- `mixed_husbandry` 农牧轮转：成员 three_field_rotation, enclosure；效果 `[['country.resource.pasture.managed_generation_factor', 1.08], ['country.resource.fertile_soil.use_factor', 0.94]]`
- `coal_iron_complex` 煤铁复合体：成员 iron_smelting, coal_basin；效果 `[['country.output.energy_factor', 1.04], ['country.input.good.coal_factor', 0.94]]`
- `postal_canal_grid` 驿漕并网：成员 postal_horse, river_transport；效果 `[['country.trade.speed_factor', 1.06], ['country.trade.capacity_factor', 1.03]]`
- `joint_stock_accounting` 股份会计：成员 double_entry, ocean_company；效果 `[['country.trade.capacity_factor', 1.05], ['country.research.cost_factor', 0.97]]`
- `steam_rail_complex` 铁汽联动：成员 steam_power, railway_network；效果 `[['country.output.manufacturing_factor', 1.04], ['country.trade.speed_factor', 1.04]]`
- `chemical_agriculture` 化肥农业：成员 agricultural_chemistry, green_revolution；效果 `[['country.output.terrain.plain.agriculture_factor', 1.06], ['country.output.good.fertilizer_factor', 1.04]]`
- `electric_assembly` 电气流水线：成员 electrification, assembly_line；效果 `[['country.output.manufacturing_factor', 1.06], ['country.output.energy_factor', 1.03]]`
- `digital_automation` 数字自动化：成员 computing_networks, automation_line；效果 `[['country.production.input_factor', 0.95], ['country.output.manufacturing_factor', 1.04]]`
- `double_constraint` 双重约束：成员 ecological_balance, carbon_market；效果 `[['country.resource.use_factor', 0.94], ['country.output.manufacturing_factor', 0.96]]`
- `epidemic_defence` 防疫体系：成员 public_hygiene, urban_sanitation；效果 `[['country.population.death_factor', 0.95], ['country.climate.profile.dryland_crop.flood_loss_factor', 0.96]]`
- `oceanic_finance` 远洋金融：成员 maritime_insurance, chartered_route；效果 `[['country.trade.capacity_factor', 1.06], ['country.trade.speed_factor', 1.04]]`
- `silk_weaving_chain` 丝织体系：成员 sericulture, household_weaving；效果 `[['country.output.good.cloth_factor', 1.05], ['country.output.good.fine_clothing_factor', 1.06]]`
- `experimental_natural_history` 实验博物：成员 experimental_method, natural_history；效果 `[['country.research.science_efficiency', 1.05], ['country.research.agriculture_efficiency', 1.04]]`

## 体系羁绊

- `granary` 仓廪：二卡 `[['country.population.death_factor', 0.98]]`；四卡 `[['country.population.death_factor', 0.96], ['country.output.agriculture_factor', 1.02]]`
- `cropland` 田垄：二卡 `[['country.output.agriculture_factor', 1.03]]`；四卡 `[['country.output.agriculture_factor', 1.05], ['country.resource.fertile_soil.use_factor', 0.96]]`
- `mining` 矿冶：二卡 `[['country.output.energy_factor', 1.03]]`；四卡 `[['country.output.energy_factor', 1.05], ['country.resource.use_factor', 0.97]]`
- `workshop` 工坊：二卡 `[['country.output.manufacturing_factor', 1.03]]`；四卡 `[['country.output.manufacturing_factor', 1.05], ['country.construction.cost_factor', 0.97]]`
- `livelihood` 生灵：二卡 `[['country.resource.use_factor', 0.97]]`；四卡 `[['country.resource.use_factor', 0.95], ['country.population.death_factor', 0.98]]`
- `market` 市易：二卡 `[['country.trade.speed_factor', 1.03]]`；四卡 `None`
- `learning` 学识：二卡 `[['country.research.science_efficiency', 1.03]]`；四卡 `None`
- `thoroughfare` 通衢：二卡 `[['country.trade.speed_factor', 1.02]]`；四卡 `None`

## 学派共鸣

- 农本：二卡 `[['country.output.agriculture_factor', 1.03]]`；四卡 `[['country.output.agriculture_factor', 1.04], ['country.resource.fertile_soil.use_factor', 0.95]]`
- 商贸：二卡 `[['country.trade.capacity_factor', 1.03]]`；四卡 `[['country.trade.speed_factor', 1.05], ['country.trade.capacity_factor', 1.03]]`
- 学识：二卡 `[['country.research.science_efficiency', 1.03], ['country.research.society_efficiency', 1.03]]`；四卡 `[['country.research.cost_factor', 0.95], ['country.ideology.point_gain_factor', 1.1]]`
- 动员：二卡 `[['country.construction.cost_factor', 0.97]]`；四卡 `[['country.population.death_factor', 0.97], ['country.research.society_efficiency', 1.03]]`
- 工造：二卡 `[['country.output.manufacturing_factor', 1.03]]`；四卡 `[['country.production.input_factor', 0.96], ['country.output.energy_factor', 1.03]]`
- 调和：二卡 `[['country.resource.use_factor', 0.97]]`；四卡 `[['country.climate.drought_loss_factor', 0.96], ['country.climate.flood_loss_factor', 0.96], ['country.climate.cold_stress_factor', 0.96], ['country.climate.heat_stress_factor', 0.96]]`