# 原生阶层与本地市场运行时（Market V2）

实现入口为 `gdext/src/economy_runtime.{h,cpp}` 与
`gdext/src/world_ext_economy.cpp`。`DCWorldExt` 组合持有独立
`NativeEconomyRuntime`；动态人口和商品状态不进入 DataCore `_slots`，也不回填
`MapData.goods_*`。

> 2026-07-11 状态：冻结周期错峰版默认 `market_runtime_mode=ACTIVE`、结算周期 5 日。功能、守恒、
> worker/scalar 确定性、移动和 10M cohort 性能门槛均已通过。

## 权威边界

| 数据/行为 | 权威 | 契约 |
| --- | --- | --- |
| cohort、handle、人口、资金、收入/支出、满足度 | C++ `PopulationStore` | GDScript 无逐 cohort setter。 |
| 本地库存、价格、需求 EMA、短缺率 | C++ `MarketStore` | 无 per-cell goods component，无匿名市场现金。 |
| 需求、预算、bundle 清算、替代 fallback、商人结算、价格 | C++ Market V2 hot loop | 不访问 Godot Object/Callable/Dictionary。 |
| 周期环境快照 | DataCore 环境 slots → C++ Q16 snapshot | 周期 sample day 捕获 temp/moisture/snow/weather，周期内冻结。 |
| catalog 编译 | `EconomyCatalog`/`EconomyFacade` 冷路径 | stable ID 排序后一次性提交 PackedArrays。 |
| 调度和结算屏障 | `EconomyDailySystem`/`WorldClock` | 周期内正常跨日；仅截止日未完成时 same-day catchup。 |
| 查询与存档 I/O | GDScript 薄壳 | 只读 committed snapshot，4–16MB byte chunks。 |

不存在大规模 GDScript fallback。原生 ABI 不可用时经济显式 disabled；PROBE 模式
保留 catalog/bootstrap/查询和显式测试能力，但不进入生产 scheduler。

## PopulationCohort

同一 `(cell, profession, ethnicity)` 只保留一个聚合 cohort。每页 64 lane，字段采用
平行 SoA：`signature_id`、`generation`、`population`、`funds`、epoch income/expense、
income EMA、Q16 满足度、最差 need ID、flags 与预留 residual。外部 handle 是
`(generation << 32) | slot_index`；回收后 generation 加一。

每个人口非零地块必须有商人：

1. 若没有商人，从本地人口最多的非商人 cohort 转出 1 人。
2. 新商人继承民族，资金按人口比例转移。
3. 总人口、总资金不变；同签名自动合并。
4. 一个地块可有多个民族的商人 cohort，库存由它们共同持有。

成交收入按商人人口使用稳定前缀商分配，直接进入商人 cohort 资金与 epoch income；
不存在 `market_cash` 中间账户。商人自身也按其消费计划正常购买。

## MarketStore 与商品所有权

V2 固定一地块一市场，`market_count == cell_count` 且 `cell_to_market[cell] == cell`。
持久稠密矩阵为：

```text
stock[market, good]             i64  # 商人共同拥有
price[market, good]             i32
demand_ema[market, good]        i64
last_shortage_q16[market, good] i32
```

库存初始为零；本轮没有生产。开发/测试通过 `ADD_STOCK` 显式命令增加库存，且目标地块
必须有商人。人口归零的地块不得保留库存。

## Need、替代品与互补品

catalog 编译成 CSR：plan→needs、need→variants、variant→components。

- need：优先级、人均基础量、连续财富弹性/上下限、数量环境曲线。
- variant：偏好权重、价格弹性、偏好环境曲线。
- component：good 与每份 bundle 所需数量。
- 同一 need 的 variants 是替代方案；同一 variant 的 components 是必须按比例满足的
  互补 bundle。

每 cohort 每日按优先级重置预算和需求。财富是 `funds/population` 相对
`wealth_reference_per_capita` 的连续定点函数，不形成额外身份分桶。民族以稀疏 need
修正表参与数量计算；温度、湿度、积雪和天气强度通过 17 点 Q16 曲线影响数量或偏好。

## 周期清算顺序

每个本地市场独立执行，数量按冻结周期 N 日累计：

1. 冻结当日价格、环境和 cohort 视图。
2. 计算 need 数量与各 variant 的价格/环境加权份额。
3. 按 need 优先级约束 cohort 可支配资金。
4. 对 bundle 的每个 component 做稳定前缀库存分配，以最短 component 决定 bundle fill。
5. 首选 variant 未满足部分只进行一次同 tick 替代 fallback。
6. 扣买方资金和库存，按商人人口分配收入，发布 need 满足度/最差 need。
7. 以日均需求更新 EMA，用冻结压力的一阶 N 日积分更新下周期价格。

本轮不执行出生、死亡、迁移、就业、工资、税收、生产或贸易。人口命令仍是底层结构
ABI，但 household market 不改变人口。

## 并行与确定性

slice 按连续 market range 切分；每个 worker 只写自身市场行及其地块 cohort。worker
结果先写 `MarketResult`，主线程再按 market 索引归并指标。定点乘除使用 128 位中间
值与饱和计数；短缺、bundle 和商人收入都使用稳定前缀商，无逐单位余数循环。
focused test 必须验证 worker/scalar state hash 完全相同。

## 公共 API

`configure_economy`、`bootstrap_economy`、`submit_economy_commands`、
`economy_should_run`、`run_economy_slice`、`get_economy_report`、人口/市场 cell
snapshot、reset、分块 save/restore、固定数学 probe 与 state hash。跨边界写入均为平行
PackedArrays；UI 只查询选中地块。

人口 cell snapshot 在 committed boundary 额外返回 cohort-major CSR 预计需求：
`demand_good_offsets`、`demand_good_indices`、`demand_per_capita_daily` 和
`demand_good_stable_ids`。它复用正式清算的财富、环境、替代品与互补品定点内核，固定
`dt_days=1`，只计算预算/库存约束前的预计单位/人/日。当前地块环境由 `DCWorldExt`
直接读取 DataCore slots；查询只使用局部临时数组，不改变 state hash、report、存档或
持久内存布局。

世界生成页的“生成测试经济数据”默认关闭。显式启用后，先在可通行陆地创建确定性的
农场、纺织工坊、庄园和商铺 owner-lot，再从这些建筑编译后的 owner/employee 岗位容量
聚合出自耕农/工人/地主/商人 cohort，最后按实际人口填充 30 日测试库存。它是开发 fixture，
不是正式历史人口来源。

## 实测门槛

Windows / Godot 4.6.2 / template_release / 2026-07-11。下表是显式
`market_cycle_days=0` 的自动周期性能档，不代表默认 5 日档：

| 档位 | 样本 | avg | p95 | max | runtime memory | ACTIVE 结论 |
| --- | ---: | ---: | ---: | ---: | ---: | --- |
| 10k cells / 200k cohort / 100 goods / 16 needs / N=50 | 2500 | 1.002ms | 1.487ms | 2.042ms | 79.5MB | 通过 |
| 100k cells / 10m cohort / 200 goods / 16 needs / N=334 | 668 | 3.290ms | 3.987ms | 5.800ms | 1413.3MB | 通过 |

错峰把 10M p95 从约 89ms 降至约 4ms；惰性会计清零和按需 merchant rebuild 消除了
周期边界 90/30ms 尖峰。代价是可配置的结算延迟与 reference 误差，详见调度文档。
# Native Building / Employment Runtime（PKEC v3）

建筑、岗位与生产由 `NativeEconomyRuntime` 内独立的 `BUILDING_GRAPH` 管理，仍与
Market V2 共用冻结周期和原子发布边界，但不进入 `household_market` 热循环。建筑不进入
`MapData`/`HexCell`/DataCore schema；运行时以按 `(cell, building_type,
owner_signature)` 排序的稀疏 POD owner-lot 保存数量，并用 cell CSR 只遍历有建筑地块。

`BuildingProfile` 编译 owner/employee role、建造成本、输入/输出、自然资源消耗和 postfix
建造条件。人口仍保持唯一 `(cell, signature)` cohort；lane 新增 owner/employee employed
计数，失业为 population 减两者。临时工资策略为 `fixed`：按建筑类配置每名实际到岗
雇员每日工资，周期结算时由业主 cohort 支付；业主现金不足时按现金封顶并报告欠付金额。
工资使用稳定 prefix quotient 分给本地同职业的实际就业 cohort，不铸币且保持资金守恒。

生产在居民市场之后、周期截止日执行，因此产出下一周期才参与居民消费。业主按本地价购买
输入；商人按 good-specific `merchant_buy_price_factor_q16`（默认 95%）并按本地市场价从高
到低收购，现金耗尽后剩余产出丢弃。自然资源按 sample-day 定点快照限产，提交时把负 delta
写入对应 `extra_change` slot，由下一次 natural-resource pass 消费。

世界设置启用测试经济数据时，fixture 先生成农场、纺织工坊、庄园和商铺 owner-lot，随后
通过 `EconomyFacade.building_job_spec()` 读取 catalog 岗位列并派生 cohort。人口结构不再作为
建筑生成输入；建筑岗位配置变化会直接改变新地图的职业人口结构。

公共冷路径新增 `get_building_cell_snapshot`，命令流新增 BUILD/DEMOLISH。PKEC v3 保存就业
lane、建筑 owner-lot、岗位实到和在建记录；v2 可迁移为空建筑/零就业状态。
