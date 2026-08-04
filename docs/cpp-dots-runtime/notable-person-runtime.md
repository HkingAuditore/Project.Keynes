# 家族重要人物原生运行时

## 目标与模型边界

重要人物是显赫家族内部的稀疏叙事层，不是全人口微观模拟。一个人物始终从既有
`FamilyMembershipEdge` 的一名成员中晋升，继续属于同一个 `PopulationCohort`。人物不会增加总人口，
也没有独立于 cohort 的钱包、库存、市场订单或税务主体。

当前版本支持姓名、家族与 cohort 归属、职业、岗位、所在聚合建筑组、现金财产归属、家族产业权益
估值、实际收入/消费/税款归因、逐需求满足度、死亡和随 cohort 迁移。不支持年龄、出生日期、亲缘树、
婚姻、继承、人物间转账、独立选购或人物级库存；增加这些机制前必须先设计权威账本和 PKEC 迁移。

## 权威数据与不变量

`NotablePersonStore` 是 `NativeEconomyRuntime` 内的 generation-safe SoA，主要列为：

- 身份：`stable_id`、`family_handle`、`cohort_handle`、`given_name_id`、
  `name_disambiguator`、`notable_since_day`；
- 财产归因：`cash_claim`、`family_equity_share_q32`；
- 已结算流量：`epoch_job_income`、`epoch_business_result`、
  `epoch_consumption_expense`、`epoch_tax`、`income_ema`；
- 福利：`needs_satisfaction`、`worst_need_id` 与稀疏 `PersonNeedState`。人物层保持生存口径，
  不复制 cohort 的八维度 composite；综合满意度只在 cohort 与家族分支两级存在，
  见[综合满意度运行时](./satisfaction-runtime.md)；
- 岗位：`building_handle`、`job_kind`、`employee_role_index`、`job_since_day`。

核心约束：

```text
person ∈ family membership ∈ cohort
sum(person.cash_claim in membership) <= membership.cash_claim
sum(membership.cash_claim in cohort) <= cohort.funds
person count does not change cohort.population
person attribution does not change money/goods/population ledgers
```

人物资产查询为 `cash_claim + family_equity_share × family building estimate`。建筑估值只读，不进入
货币守恒。人物 `epoch_tax` 是实际消费支出中税款部分的归因字段；由于
`epoch_consumption_expense` 已包含实际买方净流出，现金 claim 结转不会再次扣除该税款。

## 姓名与确定性身份

GDScript 的 `PersonGivenNamePackProfile` 编译稳定排序的名 ID、显示文本与权重；C++ 只保存名索引。
完整显示名由家族姓氏、人物名和同家族重名序号组合。姓名目录语义变化进入独立
`person_catalog_hash`，恢复时必须精确匹配，不能按显示文本猜测重映射。

人物 stable ID 由世界 seed、家族 stable ID、晋升日和槽位确定性生成；槽位采用最低 tombstone
复用并递增 generation。旧 handle 永远不能解析为复用后的新人物。

## 晋升、岗位与建筑追溯

人物只在 `notable_person_runtime_mode=ACTIVE` 时晋升。每个家族的目标人物数受以下条件共同限制：

- `notable_person_max_per_family`；
- 家族实际人口；
- 家族成员中已归因的业主或雇员人数；
- `notable_person_max_per_cell` 与全局 `notable_person_max_total`。

人物从业主就业、雇员就业和人口规模最强的 membership 确定性选择。首人标记为家族代表。
正式开局的创始家族在同一次原生 bootstrap 中立即晋升一名代表；其资格仍来自已经提交的两个
采集营地业主占岗，姓名、claim、岗位和 building handle 与日常 `PERSON_COMMIT` 使用相同 SoA、
句柄和稀疏索引。开局尚未发生消费，因此逐需求已实现归因会从第一个市场结算周期开始出现。
如果早期正式会话由 `FAMILY_COMMIT` 的首都自修复补建家族，人物不在修复函数内建立，而由紧随其后的
正常 `PERSON_COMMIT` 晋升并绑定岗位，从而保持单一人物生命周期与预算上限路径。

岗位绑定不创建个人岗位：

- 业主人物必须属于该家族、该建筑所有权边，并来自精确 owner-signature cohort；
- 雇员人物必须与建筑已填充 employee role 的职业完全相同；
- 绑定数量不得超过聚合建筑已经提交的 `filled_owner` 或 role fill；
- `building_handle` 指向现有聚合建筑 identity，粒度为 `(cell,type,owner_signature)`；
- 岗位未变化时保留 `job_since_day`，岗位或建筑变化才重新计时。

因此人物可以从建筑反查，也可以从人物追溯到职业、role 和聚合建筑，但不会把建筑组拆成实体建筑。

## 经济与需求归因

人物采用“已实现结果归因”，不独立参与市场清算：

1. household market 仍按 cohort 生成需求并结算唯一真实订单；
2. 对该 cohort 的少量重要人物，以一人和人物期初 cash claim 调用同一需求函数；
3. 人物继承 cohort 对应需求的实际满足率；
4. cohort 的实际需求支出按人物需求权重做稳定前缀分摊，匿名人口保留未归因余额；
5. cohort 的实际消费税按人物已归因支出比例分配为 `epoch_tax`；
6. worker 只写 `MarketResult`，主线程确定性 merge 到人物 SoA；
7. `PERSON_COMMIT` 依据期初 claim、已实现岗位/产业收入和实际消费流出更新人物 claim，最后以
   membership claim 为硬上限归一化。

`PersonNeedState` 保存 stable need ID、人物期望周期数量、满足度和实际支出归因。它是 UI/叙事所需的
稀疏结果，不会反向改变 cohort 的订单、价格或生存结算。

## 生命周期、迁移与死亡

cohort 迁移或换 signature 时，人物随实际移动的人数做确定性无放回选择，并改绑 destination cohort；
没有复制人物。自然死亡同样按 cohort 实际死亡数确定性选择人物并释放 handle，不额外减少人口。
家族消亡、membership 消失或引用失效会退休人物。当前没有继承：退休人物的 claim 仍留在原
membership/cohort 的守恒资金中，下一次归一化只调整剩余人物的归属，不生成或销毁钱。

## 调度与性能

原生图顺序为：

```text
BUILDING_COMMIT -> FAMILY_COMMIT -> PERSON_COMMIT -> AGGREGATE_PUBLISH
```

市场 worker 通过冻结的 cohort→person CSR 只处理本格人物，不能直接改人物权威状态。
`PERSON_COMMIT` 执行引用清理、CSR 重建、岗位绑定、claim/权益结算和晋升。派生 CSR 包括
family→person、cohort→person、cell→person、building→person、person→needs，均不进入存档或 hash。

默认硬上限为每家族 4 人、每格 128 人、全局 65,536 人；人物需求边最多为人物数乘每计划 16 个需求。
`notable_person_records_per_slice`（默认 4096）约束引用清理与家族晋升扫描的 continuation 范围；
人物热增量与重要人物数和本地建筑/需求边成正比，而不是与总人口成正比。查询全部分页，GDScript
不缓存全图人物对象。`OFF` 且无历史人物时常数时间跳过。

性能验收至少记录 `notable_person_count`、`person_need_edge_count`、`person_jobs_bound`、
`person_need_edges_processed`、economy avg/p95/max 与三账本错误；目标规模验证必须使用生产路径。

## 查询接口

- `get_family_notable_people(family, offset, limit)`：家族人物分页；
- `get_notable_person_snapshot(person)`：姓名、职业、建筑、岗位、财产、收入、消费和福利；
- `get_notable_person_needs(person, offset, limit)`：逐需求归因；
- `get_building_notable_people(building, offset, limit)`：建筑反向岗位人物；
- `EconomyFacade` 在冷边界补全完整姓名、职业/建筑/需求稳定 ID 与显示名。

这些接口只读且只能在 native slice 间调用。UI 不持有可变人物状态，也不能直接改 claim 或岗位。

## PKEC v27

PKEC v27 保留 v26 家族 section，并在 header 追加人物目录 hash、语义策略、人物槽位数和需求边数：

- section 15–17：家族 records、membership、building ownership；
- section 18：人物 SoA records，包含 inactive tombstone generation；
- section 19：人物需求边；
- section 20：END。

恢复校验人物身份/姓名唯一性、family/cohort/membership/building/role 引用、claim 子集、需求范围与排序，
通过后重建全部人物 CSR。v26 明确迁移为 `v26_empty_notable_person_bootstrap`；v25 仍先执行空家族迁移。
人物所有权威列和需求边进入状态 hash，姓名显示文本、CSR、分页和临时 worker 结果不进入 hash。

## 验证入口

`Project/project-keynes/tests/family_runtime_test.gd` 覆盖人物晋升、姓名、业主岗位与建筑反查、需求/消费
归因、三账本守恒、PKEC v30 完整恢复和 state-hash round trip。修改市场/税/迁移/存档时还必须运行
受影响的 economy、tax、settlement 与 trade 回归，并按需运行 50 日 headless 性能记录。
