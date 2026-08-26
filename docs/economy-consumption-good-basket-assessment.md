# 居民消费篮子物资适配评估

本文评估当前商品目录中一组原料、中间品、资本品和战略品是否适合作为居民的日常消费，以及适合进入哪个消费篮子。

这是内容设计评估与当前实现的对照。消费仍不是按商品类别自动推导，而是由
`Need -> variant -> component` 手工定义；`GoodProfile` 的生产替代类别不会自动变成家庭消费。
本轮已落地的内容包括：20 个 Need、11 个阶层计划、每个计划八项主食替代，以及
`food_fat`、`seasoning`、`domestic_wares`、住房低频维护和电力 utility 路径。

相关实现：

- 消费需求生成器：`tools/codegen/gen_modern_economy_content.ps1`
- 商品生产替代定义：`Project/project-keynes/scripts/data/good_profile.gd`
- 职业到家庭计划映射：`Project/project-keynes/scripts/data/profession_profile.gd`
- 居民需求累计：`gdext/src/economy_runtime_market.cpp`
- 建筑生产投入：`gdext/src/economy_runtime_building_production.cpp`

## 判定等级

| 等级 | 含义 |
|---|---|
| A | 适合直接进入居民日常消费 |
| A* | 适合，但必须走特殊路径或新增终端品 |
| B | 与家庭有关，但应作为住房维护、低频折算或条件消费 |
| C | 不应直接进入居民篮子，应由终端成品或企业投入体现 |
| S | 战略、国家、公用事业或基础设施投入 |

阶层简称：生存、农猎、采掘、产业、工匠、学术、技术、商人、业主。当前计划分别对应 `survival_household`、`agrarian_household`、`hunter_household`、`extractive_household`、`industrial_worker_household`、`artisan_household`、`scholarly_household`、`technical_household`、`merchant_household` 和 `owner_household`。

## 直接消费与住房维护

| 物资 | 结论 | 适用阶层 | 推荐篮子 | 处理意见 |
|---|---|---|---|---|
| `adobe_brick` 日晒土坯 | B | 生存、农猎，早期聚落 | `housing` | 低频住房维护，不做每日原料订单 |
| `bast_fiber` 韧皮纤维 | B | 生存、农猎、早期工匠 | `housing`，条件性 `clothing` | 可用于草屋、粗布、绳索；优先通过成品体现 |
| `bricks` 砖块 | B | 全体定居居民 | `housing` | 按住房寿命折算，不让居民每天直接买砖 |
| `cement` 水泥 | B | 产业、技术、商人、业主更高 | `housing` | 建筑维护材料 |
| `charcoal` 木炭 | A | 生存、农猎、采掘、产业；低电气化地区全体 | `home_energy` | 已与煤炭并列为燃料变体，使用商品财富弹性和阶层门槛 |
| `clay` 黏土 | B/C | 生存、农猎、早期工匠间接使用 | `housing`、`household_goods` | 通过陶器、砖块、土坯消费，不建议直接买原黏土 |
| `concrete` 混凝土 | B | 产业、技术、商人、业主；城市居民间接使用 | `housing` | 住房和公共设施维护，低频折算 |
| `edible_oil` 食用油 | A | 全体，尤其生存、农猎、产业阶层 | `food_fat` | 已作为独立 Need 终端消费，避免与 `processed_food` 上游用油重复计算 |
| `electricity` 电力 | A* | 电气化后的全体，优先产业、技术、商人、业主 | `home_energy` utility 路径 | 已接入 native cycle-flow 家庭结算；不进入跨周期库存，边界只清除剩余流量 |
| `glass` 玻璃 | B/C | 全体住房间接使用；高收入阶层可有玻璃器皿 | `housing`；`glassware` 终端 | 原玻璃仍是建筑投入，居民通过住房维护或玻璃器皿消费 |
| `livestock_products` 畜牧产品 | A*/B | 生存、农猎优先，其他阶层也可作为蛋白质 | `protein` | 只有把它定义成鲜奶、蛋、鲜肉等终端品时才应直接消费；当前更像肉类、乳制品和皮革的上游 |
| `lime` 石灰 | B/C | 全体住房间接使用 | `housing` | 通过水泥、灰浆、建筑维护体现 |
| `limestone` 石灰岩 | C/B | 无直接阶层 | 企业建筑投入 | 作为石灰、水泥原料，不直接进家庭篮子 |
| `lumber` 木材 | B | 全体住房间接使用 | `housing`、`household_goods` | 建筑、家具原料；不要与 `logs` 的家庭燃料语义混用 |
| `paper` 纸张 | B | 工匠、学术、技术、商人、业主 | `education_culture`、`communication` | 若要模拟书写纸，应新增终端 `writing_materials`，不要与印刷品原料重复 |
| `raw_stone` 原石 | B | 生存、农猎、早期聚落 | `housing` | 低频住房和道路材料 |
| `reed_bundle` 芦苇束 | B | 生存、农猎，早期聚落 | `housing` | 草屋、棚屋和早期建筑维护 |
| `salt` 食盐 | A | 全体 | `staple_food` | 低量但高覆盖的基本消费；不建议同时完整计入 `hygiene` |
| `steel` 钢材 | B/C | 全体间接使用，产业、技术、业主更高 | `housing`、`durable_goods` | 通过建筑构件、家电、交通工具等终端品体现 |
| `turf_block` 草皮块 | B | 生存、农猎，早期聚落 | `housing` | 原始住房维护材料，低频折算 |

当前 `housing` 使用八个低频维护组合（从芦苇/韧皮纤维到混凝土/钢/玻璃），并以日量摊销；
不把完整建筑 BOM 当作每日硬订单，因此不会让每个家庭重复购买全部建筑材料。

## 消费品的上游材料

| 物资 | 结论 | 适用阶层 | 推荐篮子或终端品 | 处理意见 |
|---|---|---|---|---|
| `advanced_chips` 先进芯片 | C | 技术、商人、业主间接受益 | `communication`、`education_culture`、`durable_goods` | 通过电脑、通信设备、自动化系统消费 |
| `aluminum` 铝 | C | 全体间接使用 | `household_goods`、`durable_goods`、`transport` | 炊具、家电、汽车用成品体现 |
| `batteries` 电池 | C | 技术、商人、业主间接使用 | `communication`、`durable_goods`、`transport` | 通过汽车、通信设备消费；如需便携电池，应新增终端品 |
| `copper` 铜 | C | 全体间接使用 | `household_goods`、`communication`、`durable_goods` | 电线、器具、设备的原料 |
| `cotton_fiber` 棉纤维 | C/B | 全体通过衣物间接使用；农猎和工匠可有早期自纺 | `clothing` | 家庭应买布料或衣物，不应普遍买原棉 |
| `electric_motor` 电动机 | C | 产业、技术、业主 | 企业设备、交通工具 | 生产资本，不是个人工具 |
| `electrical_equipment` 电气设备 | C | 技术、商人、业主间接使用 | `durable_goods` | 通过家电、机器消费 |
| `electronic_components` 电子元件 | C | 技术、商人、业主 | `communication`、`durable_goods` | 只作为设备上游投入 |
| `engines` 发动机 | C | 产业、业主、商人间接使用 | `transport`、企业投资 | 通过汽车、船舶、机械体现 |
| `flax_fiber` 亚麻纤维 | C/B | 全体间接使用；早期农猎、工匠可自纺 | `clothing` | 终端应是布料或衣物 |
| `insulated_cable` 绝缘电缆 | C | 技术、商人、业主 | `communication`、`durable_goods` | 通信和电力设备投入 |
| `latex` 天然乳胶 | C | 全体间接使用 | `clothing`、`transport` | 鞋履、轮胎等成品投入 |
| `lead` 铅 | C | 产业、技术间接使用 | 电池、电子设备 | 不直接作为家庭金属消费 |
| `leather` 皮革 | C/B | 全体通过鞋履、家具间接使用；工匠更高 | `clothing`、`household_goods` | 应消费鞋履、皮包、皮家具等成品，不是原皮革 |
| `natural_rubber` 天然橡胶 | C | 全体间接使用 | `clothing`、`transport` | 鞋履、轮胎和工业橡胶投入 |
| `plastics` 塑料 | C | 全体间接使用 | `household_goods`、`durable_goods` | 通过家电、包装、电子产品消费 |
| `scientific_instruments` 科学仪器 | B/C | 学术、技术 | `education_culture`、`work_equipment` | 目前更适合作为研究机构投入；只有模拟个人实验设备时才进入阶层消费 |
| `semiconductors` 半导体 | C | 技术、商人、业主 | `communication`、`education_culture`、`durable_goods` | 通过电脑、通信设备和家电消费 |
| `stainless_steel` 不锈钢 | C | 全体间接使用 | `household_goods`、`durable_goods`、`housing` | 炊具、设备和建筑构件的原料 |
| `synthetic_fiber` 合成纤维 | C/B | 产业、技术及所有现代居民间接使用 | `clothing` | 应消费布料、衣物，不消费原纤维 |
| `synthetic_rubber` 合成橡胶 | C | 全体间接使用 | `transport`、`clothing` | 轮胎、鞋底和工业制品投入 |
| `tin` 锡 | C | 全体间接使用 | `household_goods`、`communication` | 电子焊料、合金、包装材料投入 |
| `wire` 金属线材 | C | 技术、商人、业主间接使用 | `communication`、`durable_goods` | 通过电器和通信设备体现 |
| `wool` 羊毛 | C/B | 全体间接使用；农猎、工匠可早期自纺 | `clothing` | 终端应是布料、毛织衣物或毛毡 |
| `wrought_iron` 锻铁 | C/B | 生存、农猎、工匠早期间接使用 | `work_equipment`、`household_goods` | 通过工具、锅具、五金制品体现 |
| `zinc` 锌 | C | 产业、技术间接使用 | `durable_goods`、`communication` | 合金、电池、电子设备原料 |
| `gold` 黄金 | C/L | 商人、业主及高财富阶层 | `status_goods` | 应消费珠宝，不直接消费金锭；黄金货币发行是另一条路径 |
| `silver` 白银 | C/L | 商人、业主及高财富阶层 | `status_goods` | 可增加银饰终端品，但不应把白银库存当日常消费 |

## 企业、职业、基础设施和战略投入

| 物资 | 结论 | 主要使用者 | 推荐路径 | 处理意见 |
|---|---|---|---|---|
| `agricultural_machinery` 农业机械 | C | 农业企业、业主 | 企业投资 | 不是农民个人每日工具 |
| `bauxite` 铝土矿 | C | 铝冶炼企业 | 生产投入 | 不进家庭篮子 |
| `brine` 卤水 | C | 制盐企业 | 生产投入 | 盐的上游原料 |
| `coke` 焦炭 | C | 采掘、冶金、产业企业 | 企业能源/生产投入 | 不属于家庭燃料 |
| `copper_ore` 铜矿石 | C | 采掘、冶炼企业 | 生产投入 | 铜的上游原料 |
| `crude_oil` 原油 | C | 能源、化工企业 | 生产投入 | 居民应消费精炼燃料或塑料成品 |
| `explosives` 炸药 | C | 采掘、工程、军事部门 | 企业/国家投入 | 不属于居民消费 |
| `fertilizer` 肥料 | C | 农业企业、农场主 | 农业生产投入 | 农民通过粮食产出间接受益 |
| `industrial_chemicals` 工业化学品 | C | 产业、技术企业 | 企业投入 | 不应模拟化学家个人购买 |
| `industrial_machinery` 工业机械 | C | 产业企业、业主、技术人员 | 企业投资 | 生产资本，不是 `work_equipment` 日用品 |
| `iron_ore` 铁矿石 | C | 采掘、冶金企业 | 生产投入 | 钢材上游 |
| `lead_ore` 铅矿石 | C | 采掘、冶炼企业 | 生产投入 | 铅和电池上游 |
| `lubricants` 润滑剂 | C | 产业、技术、业主 | 企业生产投入 | 机器维护，不是居民个人消费 |
| `machine_parts` 机器零件 | C | 产业、技术、业主 | 企业维护/投资 | 不进家庭篮子 |
| `manganese_ore` 锰矿石 | C | 冶金企业 | 生产投入 | 钢材合金上游 |
| `nuclear_fuel` 核燃料 | S | 核电、医疗、国家部门 | 公用事业/国家采购 | 不进任何居民篮子 |
| `oceanic_vessels` 远洋船舶 | S/C | 商人、运输企业、国家 | 贸易和交通基础设施 | 不是个人 `transport` 消费 |
| `packaging` 包装材料 | C | 食品、零售、工业企业 | 企业投入 | 居民通过加工食品间接承担，不单独购买 |
| `petrochemicals` 石化产品 | C | 化工、能源、制造企业 | 生产投入 | 塑料、燃料、化学品上游 |
| `phosphate_rock` 磷矿石 | C | 化肥企业 | 生产投入 | 不进家庭篮子 |
| `railway_equipment` 铁路设备 | S/C | 采掘、产业、商人、国家 | 交通基础设施 | 不是个人交通消费 |
| `rare_earth_metals` 战略矿物材料 | C | 技术、产业、军工企业 | 电子和机械投入 | 不进家庭篮子 |
| `rare_earth_ore` 战略矿石 | C | 采掘、冶炼企业 | 生产投入 | 不进家庭篮子 |
| `raw_hide` 生皮 | C | 畜牧、制革企业 | 生产投入 | 皮革的上游原料 |
| `reactor_components` 反应堆部件 | S | 核电、核医疗、国家部门 | 公用事业/国家采购 | 不进居民篮子 |
| `saltpeter` 硝石 | C | 化工、肥料、炸药企业 | 生产投入 | 不进居民篮子 |
| `seed_cotton` 籽棉 | C | 农业企业 | 农业投入/种子 | 不是食物或衣物消费 |
| `silica_sand` 硅砂 | C | 玻璃、半导体企业 | 生产投入 | 不进居民篮子 |
| `steam_engines` 蒸汽机 | C | 产业、业主、运输企业 | 企业资本 | 不是个人交通或工具 |
| `sulfur` 硫磺 | C | 化工、肥料、炸药企业 | 生产投入 | 不进居民篮子 |
| `tin_ore` 锡矿石 | C | 采掘、冶炼企业 | 生产投入 | 锡的上游原料 |
| `zinc_ore` 锌矿石 | C | 采掘、冶炼企业 | 生产投入 | 锌的上游原料 |
| `flint` 燧石原料 | C/B | 生存、农猎、早期工匠 | `work_equipment` 的 `chipped_stone_tools` | 居民应买石器，不买燧石原料 |

## 优先级建议

1. **已加入居民消费**：`charcoal`、`edible_oil`、`salt`，以及八项主食替代。
2. **已实现特殊路径**：`electricity` 作为 `home_energy` 的 cycle-flow utility。
3. **已落地终端品**：`glassware`、`metal_housewares`、`leather_goods`、`writing_materials`、`portable_batteries`。
4. **仍不直接加入家庭篮子**：所有矿石、化工原料、机器、船舶、铁路设备、核燃料和反应堆部件。
5. **住房材料**通过低频维护组合和日量摊销进入 `housing`，不是每日完整建筑 BOM。

职业方面，当前 `ProfessionProfile` 只有 `default_consumption_plan_id`，没有职业专属耗材字段。因此化学品、电力、润滑剂、机器零件等应继续由建筑生产图采购，而不是让化学家、工程师、机械师个人购买。

消费内容必须通过 `gen_modern_economy_content.ps1 -Scope Consumption` 修改，并运行
`audit_economy_content.ps1` 与 catalog contract tests。新增家庭变体会改变 catalog hash，不能只在单个 `.tres` 文件中临时添加。
