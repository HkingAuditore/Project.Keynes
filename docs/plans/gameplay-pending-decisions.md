# 玩法待定项

这些测试失败都涉及玩法、内容或数值规则，需要负责人拍板，不计入 `execution-queue.md` 第 9 项的修复范围。定下来以后，按结论改代码或改测试，再把这条从本文删掉。

2026-11-14 上游已在 PR #6 对原 11 项给出结论，落实顺序见 `execution-queue.md` 第 14 项。已落实的第 1、3、5、6a、6b、7、8、9、10、11 节已删除；第 2、4、6c 节代码部分已落实、内容与数值部分暂缓，保留原节号。第 12 节是落实过程中新发现、需要上游再定的问题。

## 2. 开局人口增长太慢

- **测试**：`tests/world/map_activity_runtime_integration_test.gd`，失败 1 条：`ACTIVE native population commit starts visible growth effect`。
- **上游结论**：适当调快一点点，第 100 天内开局聚落至少播一次增长。
- **已落实**：表现层的两处压制已改（建筑与人口各自判断，增长被挡住时等表现结束补播）。
- **未落实**：实测开局聚落（40×28、种子 1）前 100 天人口 40 → 39，一次没涨。出生率在承载负荷超过软起点后向更替水平收敛（`economy_runtime_market.cpp` 的 `fertility_land_q16`），所以要看到增长得调数值。调快会影响以"第 100 天人口"为基准的平衡与测试，按维护者意见暂缓。

## 4. 军事装备解锁闭包不一致

- **测试**：`tests/military/military_unit_unlock_consistency_test.gd`。
- **上游结论**：核心槽在兵种解锁时必须有达标商品可生产；次要槽允许同类低品级替代，战力按实际发放的品级折算。
- **已落实（T2）**：目录 49 个装备槽标了 `core`；采购、交付、战力、AI 估价和 PKMI 存档都按核心/次要规则运行。测试改为这条契约，旧的 `hide_tanning`/`bows` 特例删除。
- **未落实（内容，暂缓）**：16 个槽在兵种解锁时没有可生产的商品，要补生产建筑或调科技前置：
  - 核心槽 7 个：`dragoons`、`line_infantry` 的火器（Q2），`riflemen` 的步枪（Q3），`combined_arms`、`tank_corps` 的现代坦克（Q2），`heavy_artillery` 的火炮（Q3），`missile_artillery` 的导弹发射器（Q5）。
  - 次要槽 9 个，同类里没有任何一种可生产：`bronze_spearmen`、`iron_infantry`、`shield_bearers` 的护具，`iron_infantry`、`shield_bearers` 的弓，`combined_arms`、`exo_infantry` 的弹药，`mechanized_infantry`、`sp_artillery` 的装甲车辆。

## 6c. 产业链的时代、产率与消费

- **测试**：`tests/technology/technology_industry_chain_balance_test.gd`，33 条；`tests/building/building_resource_chain_test.gd`，1 条。
- **上游结论**：升级后产量与效率必须更高；同一时代不得重复解锁雷同建筑；`natural_rubber` 不能跨两个时代才有消费，要补早期用途；民用消费（猎人用弓）要有数据位。
- **已落实**：
  - 26 条"商品没有消费者"已闭合：审计把军队装备槽、维修品和补给算作硬消费（T3）。
  - 升级检查从单位工人产出扩到三项，新增总产出和单位投入产出（投入按默认价计值）；开采效率仍由资源链测试查。
  - 同时代雷同建筑的判据写进同一测试：同一时代解锁，且产出集合、硬投入集合、地形依赖、资源、主人职业、雇员职业全部相同。
  - "猎人用弓"不需要新数据位：建筑的软投入（`input_required_q16` < 1）就是生产资料的承载字段，工具已经这样用。
- **未落实（都要改内容或数值，按维护者意见暂缓）**：
  - 23 条升级倒挂（后一级 ÷ 前一级）：
    - 单位工人产出 4 条：`bronze_armory → armory` 0.97、`automatic_arms_works → smart_arms_plant` 0.81、`howitzer_works → missile_systems_plant` 0.52、`munitions_plant → guided_munitions_plant` 0.17；
    - 总产出 3 条，是后三组；
    - 单位投入产出 16 条，例如 `salt_collector → industrial_salt_mine` 0.35、`method_forest_remote_sensing → method_autonomous_forestry` 0.38、`spear_knapper → bronze_armory` 0.52；
    - 另有资源链测试的 `copper_ore_collector → early_copper_mine` 开采效率下降。
  - 8 条建筑时代与语义不符，例如 `rainfed_maize_field`、`highland_tuber_plot` 在王国时代（测试认为应在农业时代），`pastoral_camp` 在农业时代（应在石器时代）。
  - 1 组同时代雷同建筑：帝国时代的 `method_stone_collector_r2` 与 `method_stone_collector_r4`。
  - `natural_rubber` 大航海时代能生产、蒸汽时代才有消费，要补早期用途（与 12a 同一条）。
  - 狩猎建筑加弓作软投入。

## 12. 落实第 14 项时新发现的待定项（2026-11-14）

### 12a. 14 种商品的需求比生产晚一个时代

- **测试**：`tests/economy/economy_goods_lifecycle_audit_test.gd`。审计修掉软投入误判后（172/469 → 0），剩这 14 条失败。
- **现状**：每种商品都有可达的生产者，但最早的消费者晚一个时代才出现：
  - black_powder 帝国→大航海、brine 石器→农业、cotton_fiber 农业→王国、fertilizer 王国→帝国；
  - flax_fiber 农业→王国、lead_ore 蒸汽→电气、natural_rubber 大航海→蒸汽（即 6c④）、packaging 大航海→启蒙；
  - phosphate_rock 蒸汽→电气、railway_equipment 蒸汽→电气、seed_cotton 石器→农业、steam_engines 启蒙→蒸汽；
  - zinc 电气→原子、zinc_ore 蒸汽→电气。
- **可选做法**：A. 推迟生产方的时代；B. 提前消费方的时代；C. 逐条判断。

### 12b. 43 个建造材料组只有一个候选

- **测试**：`tests/ui/modern_economy_catalog_test.gd` 的 `every construction material group offers a substitute`。
- **现状**：按 8⑤ 去掉编译期合并、各组独立选替代品后，43 个组只剩一个候选，单一材料为 wrought_iron、steel、cement、raw_hide、concrete、raw_stone、bricks、glass、turf_block、logs、lumber、military_electronics、adobe_brick、bronze_cannon、telecom_equipment。它们集中在 11-04 加入的军事、国家建筑和 `bowyer_camp`，原先靠合并成一组才有替代品；这些材料所在的类别大多只有一个成员。
- **影响兵营**：第一座兵营 `warrior_lodge` 的材料现在分成 logs、turf_block 两组。turf_block 只有 `turf_cutting_ground` 产，要 `tech.turf_cutting`（格内有牧场才显示），而解锁兵营的 `tech.military.war_bands` 前置里没有它。所以研究了战团组织也造不了兵营，没有牧场又买不到草皮的国家一直造不了，外国 AI 也一样。`pastoral_council_tent`、`highland_tuber_plot`、`terrace_farm` 情况相同；`earthen_rampart` 的前置含草皮切割，不受影响。`military_runtime_smoke_test` 在建兵营一步失败（`construction_materials_insufficient`）就是这个原因，`check_replay_matrix.py --military` 的 military20 原始模式也因此在"军队建立""找到宣战目标"两步失败。把配方临时换成合并前的等价组（logs 30000）后，这两个测试全程 0 失败（续跑一致性也通过），说明运行时没有问题。
- **可选做法**：A. 给这些组补同类替代材料（内容工作）；B. 把这 15 种材料加进测试的单一候选白名单。B 只让目录测试通过，造不了兵营的问题仍在；要解决它，需要 A，或者把 `tech.turf_cutting` 加进这几座建筑的前置。

### 12c. 11 种矿产没有可见的小型/微型矿层级

- **测试**：`tests/economy/natural_resource_distribution_capacity_test.gd` 的 `keeps a visible small/micro deposit tier`（bauxite、gold_ore、lead_ore、limestone、manganese_ore、phosphate_rock、rare_earth、silver_ore、sulfur、tin_ore、zinc_ore）。
- **现状**：T4 去掉重复缩放、数值持平后，目标储量 12 条已通过，这 11 条修前就失败。原因是微型矿下限被乘了两次 100，而核心矿下限只乘一次，所以微型矿下限是核心矿的 10 倍，与配置的 1:10 正好颠倒。
- **可选做法**：A. 核心矿下限 `init_min_reserve` 上调 100 倍（核心格数值会变）；B. 测试阈值按实际分布重算；C. 下调微型矿（数值改动）。

### 12d. 海洋鱼初始储量约为生态容量的 36 倍

T4 逐格对比时发现，与缩放修复无关，数值未动。要不要把初始储量压到容量以内，请定。

### 12e. 外国 AI 的科研速度与研究份额上下限

- T1 之后外国 AI 每天按研究份额下发采购政策，队列 14 项，预算大于 0，但 100 天内一项科技都研究不完：每国科技点供给约 8–10 点/日，石器时代科技要 2100–6800 点，进度还分散在 4 个领域。这是科技点供给与科技成本的平衡问题。
- AI 研究份额暂定上下限为每日可支配现金的 50/200 bp（`country_ai_catalog.gd` 的 `research_min_share_bp` / `research_max_share_bp`），没有调过，请按平衡目标定。
- 这也是正式对局里看不到水路商队的原因（第 i 项）：四项水运科技都不是开局科技，正式开局（40×28、种子 20260718）跑到第 365 天没有一个国家研究到。授予这四项后，第 54 天派出跨水订单、第 58 天到达，水路本身没有问题。

### 12f. 8④"开局全员失业"的解读

测试原来期望开局零就业，而上游 09-15 的开局流程会先安排业主在自家地块上工作。落实时按"没有雇工、业主在自家地块"理解，测试和界面说明都按这个改了。如果"全员失业"指业主也不工作，请指出。

### 12g. 目录测试剩下的 3 处内容问题

- **测试**：`tests/ui/modern_economy_catalog_test.gd`。T5 按现有目录改写后剩 18 条失败，除 12b 的 1 条外都在这里，都是数据问题，没有改数据。
- **蛋白质需求里罐头鱼出现两次**（12 个计划各 1 条，`plan variants are distinct and non-empty`）：原有的 `protein_11` 已是 `canned_fish`，`f4d833abb` 又加了 `protein_canned_fish`，罐头鱼在替代里占两份。建议删掉新增的那条。
- **4 个小产业有后期伪升级**（`negligible industry has no late pseudo-upgrade`）：`method_spice_plants_collector_r8`、`method_medicinal_herbs_collector_r8`、`method_cotton_collector_r8`、`method_rubber_tree_collector_r8`，08-26 起就在数据里。可选：A. 删掉这 4 个方法；B. 测试放行（橡胶与 6c④ 有关）。
- **战车坊的工具槽写死青铜工具**（`tool slot uses the tools category: chariot_wright[1]`）：其他建筑的工具槽都用 `tools` 类别，任何档位的工具都能用；`chariot_wright` 写的是精确商品 `bronze_tools`。可选：A. 改成类别；B. 作为特例写进测试。

### 12h. 科技内容绑定审计的 33 条断言

- **测试**：`tests/technology/technology_content_binding_audit_test.gd`。它用 `assert()` 报错，headless 下只打印 `SCRIPT ERROR`，退出码仍是 0，所以一直显示通过。上游 master（`e395588e4`）同样是这 33 条，逐条相同。
- **现状**：都是科技与建筑、生产方法的作者绑定问题，没有改数据：
  - 17 条"科技缺绑定"，例如 `tech.currency` 没绑 `jewelry_plant`、`tech.semiconductor_manufacturing` 没绑 `semiconductors_plant`；
  - 11 条"建筑缺科技前置"，例如 `early_iron_mine` 缺 `tech.iron_smelting`、`hydropower_station` 缺 `tech.electric_grid`；
  - 另有 `tech.animal_tracking` 的绑定与作者清单不符、`ammonia_plant` 多科技却没有应用科技、`tech.neural_networks` 只有 Modifier、`tech.reed_harvesting` 绕过 `tech.reed_identification`、`method_steam_shipping` 各 1 条。
- **可选做法**：A. 逐条补绑定或前置（内容工作）；B. 先把测试改成按失败计数退出，让 CI 能看到，内容另排。
