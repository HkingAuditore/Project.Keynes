# 石器时代地块经济模拟审计

## 1. 审计对象

- 记录前缀：`economy_record_20260720_210749_v8_cell1520_q8_r25`
- 指定地块：`cell=1520`，坐标 `(q=8, r=25, s=-33)`
- 时间范围：第 1 天至第 1135 天，约 3.11 年
- 市场周期：默认固定 5 日周期
- 全局数据：`summary.csv`
- 指定地块数据：`buildings.csv`、`cohorts.csv`、`market.csv`、`resources.csv`

需要注意：全局 summary 每天记录滚动相位，可按日汇总；指定地块的 cohort、building、market 状态每 5 天提交一次，中间 4 天重复最近一次快照。地块收入、支出、产出和工资等流量必须按 5 日提交边界去重，不能逐日重复累加。资源储量由自然资源日更新推进，不按同样方式去重。

数值缩放：

- 货币：10,000 子单位 = 1 货币单位
- 商品及人工资源变化：1,000 子单位 = 1 商品/资源单位
- 比率：Q16，65,536 = 1.0

## 2. 总体结论

这套经济在会计守恒层面正确，但在行为平衡层面不健康。

主要问题不是自然资源不足，而是：

1. 石器生产链在中期彻底断裂，继而造成伐木停产和其他产业受限。
2. 商人采购预算增长，但实际采购转化持续下降，大量产品被弃置。
3. 企业连续亏损暂停后，恢复条件可能不可达。
4. 自动投资确实运行，但曾持续扩建后来完全停产的石器工坊。
5. 公共火塘利润过高，其他多数生产阶层接近零储蓄或负储蓄。
6. 价格机制能够识别短缺，但价格达到上下限后无法修复实体供给。
7. 贸易结算和路线机制正常运行，但没有救济该地块的长期短缺。
8. 财富高度集中于采集者和商人，渔民、猎人几乎没有现金储备。

## 3. 守恒与数据可靠性

全程审计结果：

- `population_error = 0`
- `money_error = 0`
- `goods_error = 0`
- 资源记录器恒等式最大浮点残差约 0.025，属于记录精度范围
- 建筑工资支付率为 100%，没有未付工资

因此没有发现人口、货币或商品凭空产生/消失的问题。

但存在两个诊断异常：

- `unemployed_population` 从第 96 天开始出现负数，最低为 -98，共有 1014 天为负。该字段不能用于评估全局失业率，可能是就业重算计数器问题。
- `trade_first_dispatch_delay_max_days` 曾达到 1132 天，但 `trade_response_deadline_misses` 仍为 0。这可能是真实的极端响应延迟，也可能是首次发现/首次派单时钟的诊断口径不一致。

## 4. 全局经济趋势

| 指标 | 第一年 | 第二年 | 第三年 | 最后 180 天 |
|---|---:|---:|---:|---:|
| 每日生产投入 | 15,458.6 | 12,100.2 | 11,398.0 | 11,286.8 |
| 每日入库产出 | 77,078.4 | 57,426.0 | 55,883.0 | 55,913.9 |
| 产出弃置率 | 21.2% | 23.9% | 23.3% | 23.3% |
| 商业需求资金覆盖率 | 90.5% | 84.9% | 77.2% | 76.3% |
| 商人采购支出/预算 | 52.8% | 32.8% | 29.1% | 28.7% |
| 每日生产者名义收入 | 272,385.9 | 289,927.9 | 308,547.0 | 307,431.3 |
| 每日自动投资启动数 | 20.76 | 8.15 | 0.65 | 0.25 |

第一年至第三年：

- 实物投入下降约 26.3%。
- 入库产出下降约 27.5%。
- 名义生产者收入反而上升约 13.3%。
- 商业需求资金覆盖和采购执行率持续恶化。

这表现为实物经济收缩、价格及名义收入上升的供给瓶颈，不是健康增长。

## 5. 自然资源

### 5.1 主要资源结果

| 资源 | 初始储量 | 最终储量 | 主要判断 |
|---|---:|---:|---|
| 海鱼 | 300,000 | 500,888 | 快速恢复后接近动态平衡 |
| 野生动物 | 24,001 | 39,086 | 明显低捕捞，资源持续恢复 |
| 林木 | 7,102,680 | 7,199,337 | 后期零开采，仍持续增长 |
| 燧石 | 60,555 | 60,533 | 几乎未消耗，后期完全停采 |
| 金矿 | 4,147 | 4,094 | 三年仅下降约 1.27% |
| 肥沃土壤 | 350,000 | 350,094 | 基本稳定 |

最后 180 天：

- 海鱼自然净增约 2.40/日，捕捞约 2.19/日，替代率约 1.10，接近健康动态平衡。
- 野生动物自然净增约 17.77/日，开采约 2.62/日，替代率约 6.78，明显处于低捕捞状态。
- 林木自然净增约 103.94/日，人工开采为 0。
- 金矿开采约 0.05/日，名义寿命约 81,889 天，即约 224 年。
- 燧石配置开采寿命约 308,843 天，即约 846 年，但后期实际开采为 0。

资源安全产量使用率很低：野生动物约使用 23%，海鱼约使用 0.35%。资源侧整体偏宽松，而不是经济瓶颈。

资源 CSV 只提供 `natural_net_change`，即自然生成减自然消退的净值，无法分别验证 gross generation 和 gross decay。若要独立调校生成量与自然消退，应扩展记录字段。

## 6. 建筑投入、产出与经营

以下流量按最后 180 天的 5 日提交边界去重并折算为日均。

### 公共火塘

- 产出约 11.50/日。
- 售出率 99.6%，弃置率仅 0.4%。
- 收入约 178.73/日，投入成本约 40.87/日，所有者生活成本约 1.49/日。
- 可行性盈余约 +136.38/日，远高于约 10% 的目标利润。

公共火塘是本地最严重的超额利润源。一个采集者所有者获得了过高的加工租金，是财富集中的主要原因。

### 采集营地

- 共 18 组，平均利用率约 38.6%。
- 产出约 48.60/日。
- 售出 50.1%，自留 16.6%，弃置 33.3%。
- 现金收入约 47.87/日，所有者生活成本约 48.71/日。

现金上接近盈亏平衡，但弃置过高，数量偏多；采集者还能依靠自留食物维持生活。

### 家庭织造棚

- 从 1 组自动扩张到 2 组。
- 产出约 0.074/日。
- 售出 65.1%，弃置 34.9%。
- 每日可行性缺口约 -1.56。
- 第 1075 天后工匠群体消失，织造完全停产。

该建筑现金经济不可持续，扩张缺乏合理性。

### 石器工坊

- 从 3 组自动扩张到 12 组。
- 第 550 天左右曾将约 7.95 单位石器全部弃置，没有获得收入。
- 连续三次严重亏损后，于第 565 天进入暂停状态。
- 第 600 天起石器库存长期为 0，但工坊始终没有恢复。
- 第 600 天后 `chipped_stone_tools` 价格长期达到 10 倍上限。

即使石器价格达到上限，单工坊预期收入仍不足以覆盖所有者生活成本、燧石成本和目标利润，因此恢复利润门槛事实上不可达。这是关键的数值/机制失衡。

### 燧石采掘场

- 第 604 天后停止生产。
- 燧石储量充足，停产原因不是资源枯竭，而是所有者岗位没有填充。

### 伐木场

- 共 3 组，所有者仍在岗。
- 第 604 天后完全停产。
- 森林资源充足，计划利用率为 100%，但资金支持后的实际利用率为 0。
- 原因是工具输入完全断供。

### 沿岸渔场

- 共 24 组，产出约 17.92/日。
- 售出 29.1%，自留 55.2%，弃置 15.7%。
- 现金收入约 21.20/日，所有者生活成本约 41.93/日。

渔民依靠自留鱼维持实物消费，但现金流没有储蓄空间，弃置率也偏高。

### 狩猎营地

- 共 12 组，产出约 13.57/日。
- 售出 25.7%，自留 72.9%，弃置仅 1.4%。
- 现金可行性缺口约 -4.47/日。

实物利用效率较好，但猎人没有现金缓冲，并受到石器短缺限制。

### 河滩淘金场

- 产出约 0.10 金/日，全部售出。
- 收入约 8.00/日，工资约 4.85/日，所有者生活成本约 2.15/日。
- 工资支付率 100%，现金利润约 14%，接近合理区间。

这是本地经营结构最合理的生产建筑。

### 商栈

商栈是市场服务和商人所有权锚点，没有普通商品产出。其可行性缺口不应按普通企业解释，商人收入来自市场周转与贸易。

## 7. 关键生产链断裂

观察到的主要因果链：

```text
燧石采掘失去所有者
  -> 石器工坊经历库存过剩和全部弃置
  -> 连续亏损暂停且恢复利润不可达
  -> 石器库存长期为零
  -> 伐木场无法取得工具
  -> 木材长期短缺
  -> 狩猎、建筑投资和其他早期产业受到进一步限制
```

这说明自然资源、价格、劳动力分配、商人采购和停产恢复机制之间没有形成稳定闭环。

## 8. 阶层消费、收入、储蓄和满意度

最后 180 天的人均日收支：

| 阶层 | 收入 | 支出 | 净储蓄 | 储蓄率 | 人口加权满意度 |
|---|---:|---:|---:|---:|---:|
| 工匠 | 2.16 | 4.39 | -2.23 | -103.6% | 0.91 |
| 渔民 | 0.88 | 0.88 | 0.00 | 0% | 0.65 |
| 采集者 | 6.18 | 5.78 | +0.40 | +6.4% | 1.00 |
| 猎人 | 1.40 | 1.44 | -0.03 | -2.4% | 0.72 |
| 矿工 | 7.41 | 8.16 | -0.75 | -10.1% | 0.99 |
| 商人 | 147.51 | 147.41 | +0.10 | +0.1% | 1.00 |

商人的收入和支出包含市场周转，不能直接和普通家庭的消费预算比较。

阶层判断：

- 工匠长期负储蓄并最终消失，主要短缺集中在衣着、蛋白质和家庭能源。
- 渔民完全没有现金储蓄，满意度只有约 0.65，主要缺主食、其他食品和家庭能源。
- 猎人接近收支平衡但略为负储蓄，主要缺其他食品、家庭能源和主食。
- 矿工工资全额支付，但工资水平仍不足以覆盖消费，最后 180 天储蓄率约 -10.1%。
- 采集者满意度接近满值，并积累了绝大多数本地财富。
- 商人消费满足，但其高收支主要是市场结算周转，不代表同等水平的家庭福利。

地块人口由 97 降至 89，约 3.11 年下降 8.2%。如果出生不是刻意关闭，这一人口趋势不健康。全局 summary 共记录 0 出生和 12,996 死亡，但缺少可信的全局总人口与失业字段，因此只能确认指定地块的人口下降。

## 9. 财富分配

最终地块总资金约为 21,902，初始约为 8,829，名义财富增长约 148%。但增长高度集中：

| 阶层 | 最终人口 | 最终资金 | 人均资金 | 资金占比 |
|---|---:|---:|---:|---:|
| 采集者 | 38 | 20,298 | 534.17 | 92.7% |
| 商人 | 2 | 1,557 | 778.54 | 7.1% |
| 矿工 | 1 | 45 | 45.29 | 0.2% |
| 猎人 | 24 | 1.2 | 0.05 | 接近 0% |
| 渔民 | 24 | 0 | 0 | 0% |

按个人加权的地块财富基尼系数约为 0.559。

采集者和商人合计不到一半人口，却持有约 99.8% 的现金；渔民和猎人合计占 54% 人口，几乎没有现金。这种分布对任何价格冲击、资源冲击或贸易中断都非常脆弱。

## 10. 市场自我调节

对活跃商品，价格压力与下一次 5 日提交价格变动方向的符合率约为：

- 石器：78.2%
- 布匹：59.5%
- 鱼：83.1%
- 燧石：93.3%
- 毛皮：84.4%
- 猎物肉：62.1%
- 采集植物：82.3%
- 黄金：100%
- 木材：80.6%
- 加工食品：85.7%
- 原皮：100%

因此价格反馈算法确实生效。

但多个商品长期达到绝对价格上限：

- `processed_food`
- `game_meat`
- `logs`
- `chipped_stone_tools`
- `cloth`

原皮和燧石则接近价格下限。市场能够识别短缺和过剩，但价格上限不能修复以下实体约束：

- 上游建筑停产
- 所有者/劳动力缺失
- 商人采购现金转化不足
- 企业亏损暂停后的恢复门槛
- 自动投资对短缺信号的错误响应

## 11. 自动投资

全局三年共记录：

- 投资候选：130,427
- 投资启动：10,795
- 所有者职业流动：119,632
- 材料阻塞：17,126
- 发起人资本阻塞：25,608
- 资金阻塞：0
- 资源阻塞：0

自动投资明确存在，但质量不健康：

- 本地石器工坊从 3 组增加到 12 组，随后全部停产。
- 本地织造棚从 1 组增加到 2 组，最终失去全部工匠。
- 全局每日投资启动从第一年的 20.76 降至第三年的 0.65，最后 180 天仅 0.25。
- 最后 180 天每天仍有约 174 个候选，但实际启动几乎停止。

投资评分对短缺和账面回收期响应明显，但没有充分惩罚：

- 已暂停建筑
- 低售出率和高弃置率
- 不足的所有者/劳动力供给
- 不可达的重启利润条件
- 上游投入链已经断裂

## 12. 贸易健康

贸易机制的会计和运输部分表现正常：

- 拓扑始终可用且 generation 稳定。
- 没有路线拒绝。
- 没有无人认领订单。
- 到货量与派单量长期约为 99%。
- 没有商品或货币守恒误差。

但经济效果不足：

- 全局每日派单从第一年的约 39.8 降至第三年的约 19.6。
- 贸易容量利用率从 29.4% 降至 18.1%。
- 指定地块最后 180 天所有商品的实际进出口均为 0。
- 木材、石器和加工食品存在长期短缺，但贸易没有提供救济。
- 首次派单最大延迟达到 1132 天。

结论是：贸易管线在工作，但贸易没有完成短缺缓解和区域专业化的经济目标。

## 13. 建议优先级

应按因果顺序处理，而不是先增加资源或贸易补贴。

### P0：修复诊断与可验证性

1. 修复负数 `unemployed_population`。
2. 核对首次派单延迟与 deadline miss 的时钟语义。
3. 为资源记录增加自然 gross generation 和 gross decay。

### P1：修复石器产业闭环

1. 使石器工坊在石器价格上限下能够覆盖单位投入、所有者生活成本和目标利润。
2. 检查连续亏损暂停后的恢复判定，避免库存从过剩转为短缺后仍永久停产。
3. 检查商人采购现金和库存目标，避免短暂库存过剩导致整批工具弃置。
4. 保证燧石采掘岗位不会被其他采集建筑永久挤出。

### P2：修复建筑经营分化

1. 降低公共火塘的超额加工利润，或增加合理的劳动/所有权分摊。
2. 降低采集营地、织造棚和渔场的高弃置率。
3. 让矿工工资覆盖正常消费并形成少量正储蓄。
4. 保留渔业和狩猎的实物自留机制，但提高现金韧性。

### P3：修复自动投资

1. 对暂停、连续弃置、缺劳动力和缺关键投入的建筑施加投资否决或大幅惩罚。
2. 投资评分同时使用实际售出率、采购兑现、现金利润和可达重启条件。
3. 防止同一短缺链在没有上游修复时重复增加下游容量。

### P4：最后调整贸易

在本地生产、采购和投资闭环修复后，再检查：

1. 为什么该地块的长期短缺没有形成进口。
2. 贸易信号是否因库存目标、商人现金、来源库存或路线利润门槛被过滤。
3. 是否需要调整响应期和运输容量，而不是直接补贴价格或库存。

## 14. 当前结论的限制

- 数据只覆盖约 3.11 年，足以判断启动期和两年以上趋势，但不足以证明十年或完整时代稳定。
- cohort、building、market 只记录指定地块，不能据此计算全局财富分配。
- summary 没有可信的全局总人口和总货币存量，无法完整判断货币发行相对经济规模。
- 没有按 need 拆分的消费金额，只能使用总支出、满意度和最差需求判断消费结构。
- 自然资源只有自然净变化，不能分别验证自然生成和自然消退。
- 本报告为数据与当前运行时机制审计，没有修改代码、配置、目录、API、存档格式或默认五日周期。

## 15. 详细整改方案总览

本节把前面的审计结论转换为可执行的工程方案。以下数值均为待验证假设，不应一次性全部落地。每一阶段必须使用相同 seed、地块、人口、气候、科技、初始建筑、市场周期和 catalog，保留上一阶段的对照结果，确认上游问题修复后才能进入下一阶段。

### 15.1 目标运行区间

| 领域 | 目标区间或硬约束 |
|---|---|
| 会计守恒 | `population_error = money_error = goods_error = 0`，无 fatal、非有限值或饱和溢出 |
| 默认周期 | 保持固定 5 日，不以自动长周期掩盖行为问题 |
| 可再生资源 | 正常负载下 `harvest_pressure = 人工开采 / 自然净增长` 优先落在 0.7–0.95；接近 1.0 时必须有十年压力证据 |
| 非再生资源 | 不追求自然增长，明确正常/峰值开采寿命；石器时代关键矿物不能在启动期耗尽，也不能因经济断链永久零开采 |
| 普通建筑 | 工资支付率 100%；所有者生活成本覆盖；经营利润通常 5%–15%，必需品可取 3%–10%，高风险活动可取 10%–25% |
| 利用率 | 成熟建筑长期大致 40%–85%；不应长期满负载，也不应大批建成后停产 |
| 售出和弃置 | 普通耐储商品弃置率低于 5%；短期启动波动可高于 5%，但不得连续半年超过 10% |
| 家庭预算 | 正常就业阶层经常性收入至少覆盖经常性支出；目标储蓄率 2%–10%，不得长期依靠耗尽现金维持满意度 |
| 满意度 | 生存型阶层人口加权满意度不低于 0.75，且不能连续一年下降；最差需求应对应真实短缺 |
| 财富分配 | 不要求平均主义，但任何普通生产职业不应长期占有超过 85% 的地块现金；目标使现金 Gini 低于 0.50，并消除人口过半但现金接近零的状态 |
| 市场 | 价格不应长期钉死绝对上下限；库存覆盖至少跨过一个生产周期和合理运输期 |
| 贸易 | 持续短缺信号在默认 15 日响应期内首次派单；派单与到货守恒；不以提高总贸易量为目标 |

### 15.2 权威边界和改动位置

| 改动 | 权威层 | 主要文件/函数 | 状态或 schema 影响 |
|---|---|---|---|
| 就业汇总修复 | 原生派生统计 | `gdext/src/economy_runtime.{h,cpp}`；`reconcile_building_employment_after_population_change()`、`run_building_employment_cell()` | 增加可重建的每地块派生汇总；不进存档、不进状态哈希，不需要 PKEC 升级 |
| 投资可行性和容量判定 | 原生公式/热循环 | `gdext/src/economy_runtime.cpp`；`run_endogenous_building_investment()` | 只改公式和临时聚合；不改存档布局和 5 日周期 |
| 停产恢复测试及必要修复 | 原生建筑计划 | `gdext/src/economy_runtime.cpp` 约 `building epoch planning` 的暂停/恢复分支 | 优先不增状态；若增加恢复诊断，保持派生、无 schema 变化 |
| 石器价格 | catalog 内容 | `tools/codegen/economy_content/goods/chipped_stone_tools.tres`，再运行 `tools/codegen/gen_modern_economy_content.ps1` | 内容/catalog hash 改变；不改 C++ schema |
| 加工食品库存和成本锚 | codegen 规则 | `tools/codegen/gen_modern_economy_content.ps1` 的 `Inventory-Target-Ratio-For-Good()` 及 good 模板参数 | 应做单商品显式覆盖，不能手改生成后的 `data/goods/processed_food.tres` |
| 自然资源 gross 诊断 | DataCore 原生资源 pass + CSV 冷路径 | `gdext/src/world_ext_resource.cpp`、`economy_csv_recorder.{h,cpp}`、必要的桥接报告 | 仅选中地块诊断，不增加全局持久矩阵，不进 save/hash |
| 贸易响应诊断 | 原生贸易计划 | `gdext/src/economy_runtime.{h,cpp}`、`economy_csv_recorder.{h,cpp}` | 诊断自加载后累计；除非要求跨存档连续统计，否则不升级 schema |
| 测试 | Godot headless | `tests/building_runtime_test.gd`、`tests/economy_trade_runtime_test.gd`、`tests/goods_storage_schema_test.gd` | 新增回归场景，不改生产权威 |

明确不做：不新增 GDScript 经济模拟、不把商品/建筑/群体写入 `MapData`、不改变一个地块一个本地市场、不新增每建筑现金缓冲、不先加贸易补贴、不把地质矿藏伪装成可再生资源。

## 16. 阶段 A：先修诊断与计数器

### 16.1 修复负数失业人口

当前可疑路径是：全局就业汇总在活动工作集开始时清零或重新累计，而 `reconcile_building_employment_after_population_change()` 又按地块现有 cohort 状态减去 `owner_before`、`employee_before`、`unemployed_before`，随后调用 `run_building_employment_cell()` 重新增加。如果该地块旧贡献尚未进入本轮全局汇总，减法会把 `_unemployed_population` 推到负数。

建议实现每地块缓存的派生贡献：

```text
cell_owner_jobs[cell]
cell_employee_jobs[cell]
cell_unemployed_population[cell]
```

更新规则必须是原子替换：

```text
global -= cached_cell_contribution
new_cell_contribution = recompute_employment(cell)
cached_cell_contribution = new_cell_contribution
global += new_cell_contribution
```

实现要求：

1. 在 configure/bootstrap/reset 后将三个数组按 `cell_count` 初始化为 0。
2. 正常 `run_building_employment_cell()` 完成后写入该地块缓存，不允许另一路直接重复增加全局值。
3. `reconcile_building_employment_after_population_change()` 只减缓存旧值，不能从当前 cohort lane 临时推断“已经计入的旧值”。
4. 缓存是派生数据，不进入 PKEC save 和 deterministic state hash；restore 后从 cohort/building 权威状态重建。
5. publish 前增加断言：三个全局汇总均非负，且抽样/测试模式下等于所有地块缓存之和。

新增测试 `building_runtime_test.gd`：在同一结算中同时触发 owner 职业流动、自动投资、建筑完工和结构命令，连续运行至少 60 天。每个提交边界验证：

```text
unemployed_population >= 0
filled_owner_jobs >= 0
filled_employee_jobs >= 0
unemployed_population == Σ max(0, cohort.population - owner_employed - employee_employed)
population_error == 0
```

### 16.2 拆分自然生成和自然消退

当前 CSV 用 `closing - opening - artificial_change_applied` 反推 `natural_net_change`，只能证明自然净变化，不能回答“生成过高”和“消退过高是否互相抵消”。

建议在 `world_ext_resource.cpp` 的资源日更新中，仅对 recorder 指定的有限地块记录：

```text
natural_gross_generation
natural_gross_decay
ecology_immigration_or_reseed
acute_stress_decay
artificial_change_applied
closing_reserve
```

记录必须来自实际积分分支，而不是 CSV 端重算近似值。对于密度依赖生态资源，应将 logistic growth/immigration 归入 generation，将显式 stress mortality 归入 decay；对于普通 IMEX 资源分别记录正生成项与衰减项。CSV 增加以下恒等式检查：

```text
closing = opening
        + natural_gross_generation
        - natural_gross_decay
        + artificial_change_applied
```

允许误差只来自现有 float32 储量精度，并记录 `resource_identity_error`。不得为此新增 `resource_count × cell_count` 的永久诊断矩阵；只保留 recorder 选中地块或选中资源的有界 trace。

### 16.3 修正贸易响应指标语义

现有 `trade_response_deadline_misses` 在短缺信号被扫描且仍未派单时递增，可能对同一信号重复计数，也可能因计划 reset/筛选而漏记。应拆为：

- `trade_unresolved_deadline_misses_current`：当前仍未派单且年龄超过 15 日的信号数。
- `trade_signals_exceeded_deadline_cumulative`：自本次运行/加载以来，首次超过 15 日的唯一信号累计数。
- `trade_first_dispatch_delay_max_days`：已经成功首次派单的信号最大等待天数。
- 选中地块每商品：`last_trade_attempt_day`、`last_trade_rejection_reason`、`trade_signal_age_days`。

同一信号跨越 deadline 只能给 cumulative 增加一次。拒绝原因至少区分：无价差、利润不足、商人现金不足、来源安全库存不足、国家容量不足、无路线、订单上限、未进入候选池。

阶段 A 通过条件：失业汇总连续两年无负值；资源 gross 恒等式可核对；1132 日派单延迟若再次出现，必须能在 CSV 中看到它在哪一天、因何原因未派单。

## 17. 阶段 B：重写自动投资的可行性和容量判定

### 17.1 当前公式的具体问题

`run_endogenous_building_investment()` 当前存在四个关键偏差：

1. `daily_operating_cost` 只含投入和工资，不含 owner livelihood，因此可能批准“企业账面盈利、所有者无法生活”的建筑。
2. 当前 `margin_q16 = profit / revenue`，而建筑正常计划使用的是 `revenue >= operating_cost × (1 + target_margin)`；两个 margin 口径不一致。
3. `output_deficit / output.quantity` 只以单栋产出为分母，没有把已安装建筑数量和暂停容量作为容量决策的一部分。
4. vacancy 以全部 owner slots 判断，并且 `_investment_existing_by_cell_type` 只保存一个 group，不能正确表达同一地块/类型的多个 owner signature、暂停数量、在岗数量和计划利用率。

这四点足以解释石器工坊从 3 扩到 12 后集体停产。

### 17.2 新的 cell/type 聚合

把 `InvestmentExistingType` 从“一个 group + 一个 vacancy 布尔值”改为当前投资切片内的临时聚合：

```text
installed_count
active_count
suspended_count
filled_owner
planned_owner_required
installed_output_per_good
weighted_sell_through_q16
weighted_discard_q16
weighted_realized_margin_q16
groups[] 或代表性 group 索引
```

该结构只服务本次投资评审，不进入 save/hash。`planned_owner_required` 建议按可运营容量计算：暂停建筑 owner 需求为 0；活动建筑至少保留一名 owner，并按 planned utilization 计算其余 owner slot。不能因为一批已暂停建筑存在空 owner slot，就优先把劳动力不断迁入一个不可恢复的行业。

### 17.3 先再激活、后建设

每个 `(cell, type)` 必须按以下顺序决策：

1. 若存在 owner vacancy 且建筑活动、投入链可用、预期可覆盖 owner livelihood，则只补 owner，不建设。
2. 若存在暂停容量，则先评估正常恢复条件；暂停容量未恢复前，禁止新建同类型建筑。
3. 若活动建筑的已安装容量足以覆盖需求，则拒绝建设。
4. 只有持续需求超过已安装容量、售出良好、投入链可用、owner 可生活、资本可回收时，才允许新建。

容量建议公式：

```text
installed_capacity[g] = Σ(output_quantity_per_building[g] × installed_count)
capacity_pressure[g]  = normalized_daily_demand[g] / max(installed_capacity[g], epsilon)
```

普通商品新建门槛建议为 `capacity_pressure > 1.10`，并连续 3 次投资评审成立；生存必需品可放宽到 `> 1.05`。石器案例中三座工坊容量约 0.66/日，本地需求约 0.63–0.66/日，不应因为一次短缺或 supply EMA 滞后扩到 12 座。

### 17.4 统一投资可行性公式

可行性应移到 `target_signature` 循环内部，因为不同 ethnicity/signature 的生活成本可能不同。

```text
variable_cost = (daily_input_cost + daily_employee_wages) × planned_utilization
owner_cost    = owner_living_cost(target_signature) × owner_slots_per_building
operating_cost = variable_cost + owner_cost
required_revenue = operating_cost × (1 + target_operating_margin)
viable = expected_revenue >= required_revenue
profit = expected_revenue - operating_cost
payback_days = required_capital / max(profit, epsilon)
```

owner livelihood 是固定再生产成本，不应随低利用率一起缩到接近零。`projected_owner_income` 应使用扣除投入、工资和 owner livelihood 后的可分配利润；若该值小于 0，则不能用它吸引 entrepreneur 转职。

资本需求保持现有施工成本、若干经营周期投入和 30 日生活准备金，但必须避免重复计算：owner livelihood 已进入日常可行性，30 日 reserve 只用于启动资本，不再作为利润。

### 17.5 售出和上游约束

新建还应满足：

- 最近 3 个已结算周期 `sell_through >= 0.80`，或商品处于明确的零库存持续短缺恢复状态。
- 最近 3 个周期 `discard_rate <= 0.10`；若高于 10%，不能仅凭价格短缺信号扩产。
- 所有必需投入候选存在，且本地生产/库存/贸易至少能覆盖一个完整生产周期。
- 对因关键投入断供而停产的下游建筑，记录 `INPUT_CHAIN_UNAVAILABLE`，不能继续扩大下游容量。

建议明确 rejection code：

```text
0 NONE
1 PENDING_CONSTRUCTION
2 SUSPENDED_CAPACITY_EXISTS
3 ACTIVE_OWNER_VACANCY
4 INSTALLED_CAPACITY_SUFFICIENT
5 OWNER_LIVELIHOOD_UNCOVERED
6 SELL_THROUGH_TOO_LOW
7 DISCARD_TOO_HIGH
8 INPUT_CHAIN_UNAVAILABLE
9 TARGET_MARGIN_UNMET
10 PAYBACK_TOO_LONG
11 SPONSOR_CAPITAL_UNAVAILABLE
12 MATERIALS_UNAVAILABLE
13 RESOURCE_UNSAFE
```

现有 `_building_investment_rejection` 应真正写入这些原因，并在 summary 中增加按原因计数。否则“候选很多、启动很少”仍然无法诊断。

### 17.6 阶段 B 测试

在 `building_runtime_test.gd` 增加四个确定性测试：

1. 三座工坊容量 0.66/日、需求 0.63/日，连续 120 天不得新建第四座。
2. 已有暂停工坊且商品短缺时，不新建；价格恢复可行后原工坊先重启。
3. 账面投入/工资有利润但无法覆盖 owner livelihood 的建筑被拒绝，原因是 `OWNER_LIVELIHOOD_UNCOVERED`。
4. 同一 cell/type 有多个 owner signature 时，聚合 installed count、vacancy 和 suspended count 正确，scalar/worker state hash 完全一致。

阶段 B 通过条件：石器工坊不再从 3 无限制扩张；自动投资启动率下降必须对应明确拒绝原因，而不是候选静默消失；投资后失业、人口、货币、商品守恒继续为零。

## 18. 阶段 C：修复石器产业闭环

### 18.1 不先改物理产量

当前 `knapping_workshop` 每座每日投入 0.1 燧石、产出 0.22 石器。三座总产能 0.66/日，与本地狩猎和伐木需求约 0.63–0.66/日接近。问题不是石器物理产量太低，而是价格尺度、采购和暂停恢复共同造成现金不可行。因此第一轮保持：

```text
input flint = 0.10/day
output chipped_stone_tools = 0.22/day
merchant buy factor = 0.95
```

### 18.2 价格 A/B 矩阵

当前石器价格是默认 0.9、最低 0.09、最高 9.0。即使达到 9.0 上限，观察到的恢复 margin 仍为负。建议修改 curated 源 `tools/codegen/economy_content/goods/chipped_stone_tools.tres`，按以下三组同种子测试，不能直接认定其中一组为最终值：

| 变体 | default_price | min_price | max_price | 目的 |
|---|---:|---:|---:|---|
| C1 | 6.0 | 0.6 | 18.0 | 最小幅度提高，观察是否仍长期触顶 |
| C2 | 7.5 | 0.75 | 21.0 | 中档价格尺度 |
| C3 | 9.0 | 0.9 | 24.0 | 给 owner livelihood 和 10%–15% margin 更大空间 |

文件中的整数分别是货币单位乘 10,000，例如 C2 为 `75000/7500/210000`。生成后必须运行 codegen `-Check`，不能只改运行目录里的生成文件。

选择规则：选能满足以下条件的最低价格组，而不是利润最高的组：

- 三座工坊可在 60 日内恢复并持续运营。
- 石器价格最后一年不超过 80% 时间停在 max price。
- 工坊包含 owner livelihood 后利润率位于 10%–20%。
- 石器售出率至少 85%，弃置低于 5%。
- 石器库存覆盖 5–20 日需求，不长期为 0，也不重新出现整批弃置。
- 伐木和狩猎取得工具后恢复生产，且其投入成本没有把自身利润推成长期负值。

如果 C3 仍不能恢复，不应继续无限抬价。先检查 owner living cost、merchant effective buy factor、恢复使用的 settlement price 是否与实际采购价一致；只有公式一致后，才测试小幅提高物理产出，例如 0.22 → 0.25，而不是成倍提高。

### 18.3 完整暂停到恢复测试

当前只有“连续亏损后暂停”覆盖，不足以证明恢复闭环。新增测试：

1. 启动一座石器工坊并制造临时高库存。
2. 连续 3 个结算周期产生低于 -25% 的严重亏损，确认 `operating_state = suspended`。
3. 清空石器库存并制造持续工具需求。
4. 让价格只通过正常 shortage/price feedback 上升，不直接写价格。
5. 确认预期经营 margin 连续 2 个周期达到至少 +10%。
6. 确认工坊重启、owner 重新填充、产出恢复、石器入库和销售发生。
7. 全程验证三类 audit 为零。

若价格和投入均可行但 owner profession cohort 已消失，才增加有界恢复路径：从同 ethnicity、拥有 30 日 reserve 且转职后收入提高的 entrepreneur cohort 中迁移 1 人。该路径只能用于再激活既有暂停容量，不能顺带新建建筑。

## 19. 阶段 D：修复采购、库存与公共火塘超额利润

### 19.1 先处理 processed food 的价格-库存反馈

公共火塘的高利润与 `processed_food` 长期处于 10 倍价格上限直接相关。当前商品配置为：30 日基线乘库存比例、成本锚权重 0.25、merchant buy factor 0.95。不要先改火塘 recipe，因为这可能掩盖库存目标和价格锚的问题。

按以下顺序做单变量 A/B：

| 实验 | 库存覆盖 | `inventory_target_ratio_q16` | `cost_anchor_weight_q16` |
|---|---:|---:|---:|
| D0 | 当前值 | 当前生成值 | 16384（0.25） |
| D1 | 30 日 | 65536 | 32768（0.50） |
| D2 | 20 日 | 43691 | 32768（0.50） |
| D3 | 15 日 | 32768 | 32768（0.50） |

注意：当前 codegen 的 essential good 规则可能统一处理多种食品。应在 `Inventory-Target-Ratio-For-Good()` 中为 `processed_food` 加显式 override，避免为了一个商品改变所有食品。成本锚也应增加按 good 的显式函数/表，而不是在模板中把全部商品从 0.25 改成 0.50。

每次只更改一个维度：先 D1 只增强成本锚；若仍长期触顶，再测试 D2、D3 的库存覆盖。通过条件：

- `processed_food` 价格不再超过 80% 时间钉在上限。
- 公共火塘包含 owner livelihood 后现金 margin 为 10%–25%。
- 公共火塘售出率大于 90%，弃置低于 5%。
- 加工食品短缺周期少于 10%。
- 商人采购支出/预算不低于 60%，不能因目标下降而让生产者现金转换崩溃。
- 采集者现金占比明显下降，但不是通过摧毁采集者收入实现。

若 D3 后火塘仍有超过 25% 的利润，再做 recipe 小步测试，候选只允许单变量：产出 `12.628 → 11.5 → 10.5`，或提高必要投入，不得同时改价格、库存和 recipe。选择保持供应满足且 margin 最接近目标的最小改动。

### 19.2 其他高弃置商品分开处理

鱼、采集植物、布匹和其他商品不能共享一刀切库存目标。对每个商品分别测试 30、20、15 日覆盖，并观察：

```text
producer revenue
merchant procurement spent / budget
sell_through
discard_rate
stockout frequency
household satisfaction
price cap hit rate
```

任何降低库存目标的变体，只要使生产者收入下降超过 15%、满意度下降超过 0.05，或 stockout 周期超过 20%，就回滚。鱼和猎物的 owner retained consumption 应保留，因为它是石器时代自给经济的重要实物收入，不应为了提高现金交易率而删除。

### 19.3 全局采购健康门槛

本次基线最后 180 日 merchant procurement spent/budget 只有 28.7%。阶段 D 目标不是立即达到 100%，而是：

- 两年内恢复到至少 60%，且第二年不低于第一年。
- 商业需求资金覆盖率至少 90%。
- 全局普通商品弃置率降至 10% 以下；关键地块耐储商品低于 5%。
- producer nominal revenue 的增长必须伴随实物产出稳定或增长，不能继续出现“实物下降、名义收入上升”。

## 20. 阶段 E：工资、家庭预算和财富分配

这一阶段只能在石器、采购和火塘修复后进行。否则调工资会把上游亏损转嫁给建筑 owner，调需求会掩盖缺货。

### 20.1 逐职业预算闭环

对工匠、渔民、猎人、矿工、采集者分别计算滚动 180 日：

```text
expense_coverage = recurring_income / recurring_expense
savings_rate = (income - expense) / income
cash_buffer_days = funds / recurring_expense_per_day
satisfaction and worst_need
```

验收目标：

- 工匠、渔民、猎人、矿工 `expense_coverage >= 1.02`。
- 正常就业职业储蓄率 2%–10%。
- 至少拥有 15 日必要消费现金缓冲；渔民和猎人的实物自留可单独计入福利，但不能替代所有现金韧性。
- 不允许某职业连续 180 日人口大于 0、资金却恒为 0。

### 20.2 工资调整顺序

1. 先确认建筑实际售出、采购现金和 owner margin。
2. 再确认 adaptive wage 的 living-cost anchor 和 local-wage anchor 是否正确。
3. 只有 owner margin 在支付更高工资后仍至少 5%，才提高 reference wage。
4. 每轮工资只调 5%–10%，不得一次性补齐全部历史缺口。

矿工当前工资支付率虽为 100%，储蓄率仍约 -10.1%。应重点检查 `flint_quarry.tres`、`placer_gold_working.tres` 等石器时代矿业角色配置和 adaptive contract wage，而不是全局提高所有矿工工资。河滩淘金场当前约 14% margin，是合理参照：工资提高后 owner margin 仍应保持 5%–15%。

### 20.3 财富分配的处理原则

不建议直接加入财富税或强制转移来修复本案例。先消除公共火塘垄断利润和其他职业的负现金流。两年后重新评估：

- 地块现金 Gini 目标低于 0.50。
- 最大普通职业现金占比低于 65%；硬上限 85%。
- 人口占比超过 20% 的职业，现金占比不应长期低于 2%，除非其消费几乎完全由明确记录的实物自留满足。
- 采集者财富下降必须来自加工利润正常化和其他职业形成正储蓄，不得通过货币销毁或无记录转移实现。

若实体闭环修复后 Gini 仍高于 0.55，再单独设计税收/公共分配系统；这属于新的国家财政机制，不在本轮经济平衡补丁范围内。

## 21. 阶段 F：最后处理贸易

当前全局贸易容量利用率约 18%，因此第一步绝对不是增加容量。先用阶段 A 的拒绝原因回答 cell 1520 为什么在石器、木材和加工食品短缺时没有进口。

逐商品诊断顺序：

1. destination signal 是否生成，目标库存和本地库存差额是多少。
2. 信号是否进入每 country/good 保留的前 8 个 destination。
3. 是否存在同 country/component 内可出口来源。
4. 来源 stock 是否高于 export safety floor。
5. 价差扣除路线成本后是否满足利润和 margin 门槛。
6. 目的地 merchant 是否有采购现金。
7. route、capacity、order cap 是否拒绝。
8. 派单后是否按时到货并被本地市场使用。

只有证据显示大量健康候选都被容量拒绝，且国家容量连续一年利用率超过 80%，才提高贸易容量。否则按具体原因调整：

- `NO_SPREAD/MARGIN`：检查目标地价格、来源价格和运输成本，不直接补贴。
- `SOURCE_STOCK`：来源也短缺，贸易不能创造供给，应回到本地/区域生产。
- `DESTINATION_CASH`：先修商人采购和家庭现金流。
- `NOT_SELECTED`：检查 per-country/good 的 top-8 destination 截断是否长期饿死老信号，可按 age 提高优先级。
- `ROUTE`：再检查 topology/component，不先改经济参数。

贸易通过条件：

- 持续短缺信号首次派单延迟 `<= 15` 日，超过 deadline 的唯一信号累计为 0，或每个例外有明确无来源/无盈利原因。
- cell 1520 在本地石器链尚未完全恢复的冲击测试中能收到工具或木材进口；正常稳定态可因本地产能充足而回到低贸易量。
- dispatched quantity 与 arrived quantity 长期核对，未认领订单为 0，钱和商品 audit 为 0。
- 不以“贸易量持续上升”为健康指标，以短缺缓解、价格差收敛和区域专业化为准。

## 22. 推荐补丁序列

### Patch 1：诊断可信度

改就业派生汇总、资源 gross trace、贸易 deadline 口径和拒绝原因。只改变诊断和派生计数，不改变经济行为。先跑两年基线，确认原有经济走势基本一致，守恒和 hash 不变。

### Patch 2：投资公式

改 `InvestmentExistingType` 临时聚合、owner livelihood、margin 口径、已安装容量、暂停优先和 rejection code。保持所有内容数值不变，验证石器工坊不会继续错误扩张。

### Patch 3：石器价格与恢复

加入 C1/C2/C3 A/B 配置和完整暂停恢复测试。选择最低可行价格带，保持 0.22/日产量不变。

### Patch 4：processed food 与采购

先调成本锚，再调单商品库存天数，最后才允许小步 recipe 调整。同步观察公共火塘利润、采集者财富、全局采购执行和弃置。

### Patch 5：工资与家庭预算

仅对仍然负储蓄且其雇主可承受的职业做 5%–10% 小步调整。不得全局统一加薪。

### Patch 6：贸易响应

依据拒绝原因修复信号选择、现金、来源库存或利润阈值。没有容量证据时不扩容。

任何 patch 如果同时跨越两个以上因果层，例如同时改石器价格、工坊产量、owner 生活需求和贸易补贴，应拆分，否则无法判断有效原因。

## 23. 验证矩阵

| 场景 | 时长 | 主要目的 | 必看指标 |
|---|---:|---|---|
| 公式单测 | 3–20 周期 | 投资 margin、owner livelihood、暂停/恢复、就业缓存 | rejection code、operating state、就业总和、三类 audit |
| 短期同种子 | 180 日 | 启动瞬态、采购现金、价格响应 | 售出/弃置、price cap hits、procurement spent/budget、owner margin |
| 一年 | 365 日 | 自动投资和生产链稳定 | 建筑数量、暂停数量、石器/木材库存、职业储蓄 |
| 两年主验收 | 730 日 | 季节性和同比方向 | 年 1/年 2 实物产出、价格、财富 Gini、满意度、贸易响应 |
| 十年长期 | 3650 日 | 慢性漂移、资源和财富集中 | 年度资源流、建筑进入/退出、库存、Gini、人口、贸易依赖 |
| 资源压力 | 10 年 | 双倍建筑或边缘生态 | harvest pressure、安全储量、恢复时间、projected life |
| 贸易中断 | 1–2 年 | 本地链韧性 | 本地替代、库存覆盖、满意度、恢复后派单 |
| 商人现金冲击 | 180 日 | 采购反馈 | funded business demand、discard、producer revenue、恢复时间 |

每个 A/B 报告至少输出：

```text
固定条件：seed/cell/population/catalog/climate/technology/cadence
资源：opening/generation/decay/extraction/closing/pressure
建筑：count/utilization/input/output/sold/discard/revenue/cost/wage/owner livelihood/margin
群体：population/income/expense/savings/funds/satisfaction/worst need
市场：stock/price/demand/business demand/procurement/shortage/cap hits
投资：candidate/start/rejection reason/payback/reactivation
贸易：signal age/rejection/dispatch/arrival/import/export
守恒：population/money/goods/resource identity/saturation/fatal
性能：default five-day avg/p95/max 和内存，仅在原生热循环改动时要求
```

两年主验收的硬门槛：

1. 三类 audit 始终为 0；失业人口从不为负。
2. 石器链连续运行，或在正常价格反馈后可自动暂停和恢复；石器不长期零库存且价格不长期触顶。
3. 工坊数量与需求相称，本场景不再出现 3 → 12 → 全停产。
4. 全局实物产出第二年不低于第一年 95%，producer nominal revenue 不得在实物继续收缩时单独上涨。
5. merchant procurement spent/budget 至少 60%，商业需求资金覆盖至少 90%。
6. 关键耐储商品弃置低于 5%，全局普通商品弃置低于 10%。
7. 所有主要就业职业经常性收支覆盖不低于 1.02，满意度不单调崩溃。
8. cell 1520 现金 Gini 低于 0.50，且渔民/猎人不再合计人口过半但现金接近零。
9. 持续贸易短缺在 15 日内派单，或有可解释的无来源/无利润拒绝。

十年验收必须额外证明：

- 海鱼和野生动物没有加速性耗竭；正常捕捞压力进入设计区间，而不是靠产业停摆形成“资源健康”。
- 林木、燧石等资源有实际经济使用；非再生矿寿命符合时代进程。
- 建筑数量、价格、库存和财富集中度没有单向发散。
- 不出现职业消失后关键生产链永久无法恢复。

## 24. 回滚条件

出现以下任一情况，回滚当前阶段并保留上一阶段结果：

- 任一人口、货币或商品 audit 非 0。
- scalar/worker deterministic state hash 不一致。
- 默认 5 日周期的 release p95 增加超过 10%，且没有明确收益或优化方案。
- 石器价格变体使狩猎/伐木投入成本导致其 owner margin 连续半年低于 0。
- 降低库存目标后 producer revenue 下降超过 15%、满意度下降超过 0.05 或 stockout 超过 20% 周期。
- 公共火塘利润下降是通过加工食品长期缺货或采购崩溃实现。
- 工资提高后工资支付率低于 100% 或 owner 无法融资下一个周期。
- 贸易调整提高了流量，但 shortage、价格差或到货利用没有改善。
- 十年运行中资源、财富、价格或建筑数量出现比基线更快的单向发散。

## 25. 最终交付物

完成全部整改后，应产生：

1. 每个 patch 的相同种子 A/B CSV 和一页差异报告。
2. 新增的就业、投资、暂停恢复、贸易响应回归测试。
3. 两年和十年验证表，包含首年/末年及首尾 180 日窗口。
4. 若修改原生公式，同步更新 `docs/cpp-dots-runtime/economy-fixed-point-ledger-formulas.md`、`native-economy-runtime.md` 和相关调度/诊断文档。
5. 若修改 codegen，运行正常生成和 `-Check`，确认 curated 源、生成资源和 catalog hash 同步。
6. C++ 改动后完成 debug/release GDExtension 构建、focused headless tests、默认五日 release avg/p95/max、save round-trip 和 scalar/worker hash 验证。

本详细方案仍然是实施设计，没有在本次审计中修改运行时代码或经济内容。建议严格按 Patch 1 到 Patch 6 执行，避免用下游价格、工资或贸易参数掩盖上游物理生产和投资公式错误。
