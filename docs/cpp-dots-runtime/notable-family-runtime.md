# 显赫家族原生运行时

## 目标与边界

家族系统只模拟对城市经济有可见影响的“显赫家族”，不为全部人口创建对象。未加入家族的人口仍
留在原有 `PopulationCohort` 中，称为匿名人口。`NativeEconomyRuntime` 是家族、成员关系和
建筑所有权的唯一可变权威；GDScript 只编译姓氏目录与策略、提交经济 bootstrap，并执行只读查询。

家族层包含形成、分支迁移、产业扩张、衰退和消亡；家族内部的重要人物稀疏层见
[家族重要人物原生运行时](./notable-person-runtime.md)。系统仍不包含谱系树、婚姻、继承份额、家族合并、
经理代理或跨国汇款。跨国影响只能通过现有人口迁移和本地投资产生；收入、消费和企业税仍按交易
发生地与 cohort/building 所属地的冻结国家映射结算。

## 权威数据模型

`FamilyStore` 是 generation-safe SoA：

- `stable_id`：存档和确定性身份；运行时引用使用 `(generation,index)` 句柄。
- `surname_id + surname_disambiguator`：指向稳定排序的姓氏包，不把显示文本作为身份。
- `founded_day`、`home_cell`、`origin_ethnicity`、`decline_reviews`、`flags`。

关系使用两个稀疏边表：

- `FamilyMembershipEdge(family_handle, cohort_handle, people, cash_claim, ...)`。
- `FamilyBuildingOwnership(family_handle, building_handle, owned_count, filled_owner)`。

成员边只表示 cohort 的一个子集，因此对每个 cohort 恒有：

```text
sum(family.people) <= cohort.population
sum(family.cash_claim) <= cohort.funds
```

`cash_claim` 是 cohort 资金中的守恒归属，不是第二个钱包。生产收入、工资、税、消费、补贴和迁移
仍只改原有 cohort/merchant/country 账本；家族提交阶段按人口与资金基数重新归一化 claim。因此
家族财产查询不会重复计入 money audit，也不会绕过税务。

建筑组仍按 `(cell, building_type, owner_signature)` 聚合。家族所有权是附着于稳定
`BuildingIdentityStore` handle 的 `owned_count`，不会把 `family_id` 放入建筑组 key，从而避免
家族数量放大生产热循环、市场信号和建筑 CSR。

## 形成与消亡

默认策略只在乡村及以上、人口至少 100 的地块评审，每格最多 64 家族；评审以 cell/day 相位
错开。候选建筑必须同时满足：

1. 正常营业，存在稳定 building identity；
2. 至少一栋尚属匿名所有，且一栋所需业主岗位已实际填满；
3. 实际利润率达到建筑目标；
4. 预计每名业主日收入高于当地同 signature 生活成本；
5. 匿名业主人口拥有至少 30 天的创始人生计现金储备。

候选按利润率、收入、建筑类型和业主 signature 确定性择优。创始人口等于一栋建筑的实际业主
槽位；初始 cash claim 按其在 cohort 中的人口比例取得；首栋建筑的 `owned_count=1`。

正式新游戏是唯一显式例外：`StarterSettlementBootstrap v3` 为每个首都声明一栋采集营地，原生
bootstrap 将其两个实际采集者业主直接建立为一个创始家族，并立即重建全部家族 CSR。该操作不
降低全局形成门槛，不增加人口、资金、商品或建筑数量；测试夹具和普通经济 bootstrap 未提供声明时
仍从空家族状态开始。

为防止长驻编辑器仍发出 v2 packet，原生 bootstrap 还会从“`forced_named_cells` 中的首都 +
该地块真实存在的 `gathering_ground`”派生同一声明。仅强制命名、但没有采集营地的测试/普通
bootstrap 不触发。若旧会话已在无家族状态下运行，日常 `FAMILY_COMMIT` 会在第 0..30 天检查
上述权威不变量，并在 owner 岗确已占满时补建一次；权威 membership 边防止同批次重复创建。

每个家族按 `stable_id % family_review_days` 分摊生命周期复核。人口归零立即消亡；无产业且人口
低于活跃阈值连续达到 `family_decline_reviews` 次后消亡。home cell 取成员最多的分支，同人口时取
较小 cell。空槽采用最低 index 确定性复用，并递增 generation，旧句柄不能指向新家族。

## 业主岗位与职业统计

家族拥有某建筑不等于自动填满业主岗。每轮 `building_employment` 在原有岗位分配后执行约束：

- 家族所属建筑的业主岗，只能由同一地块、同一 owner signature 的该家族成员填充；
- 匿名建筑只能使用该 cohort 中未归属任何家族的人口；
- 任一成员不能同时填多个业主岗；缺少合格成员的岗位保持空缺并自然降低产能/收益；
- 第一版没有经理或代理经营的替代通道。

`FAMILY_COMMIT` 将建筑 `filled_owner` 回写到成员边，并按剩余成员容量确定性分摊 employee
employment。因此 `get_family_snapshot()` 可按 profession 汇总家族人口、业主就业和雇员就业；
这些是 cohort 与建筑岗位的派生归因，不是独立劳动力账本。

## 迁移、投资与经济结算

人口换职业、换 signature 或迁移时，`move_cohort_population()` 同步按实际移动人口和资金比例移动
成员边；由此自然形成家族分支。家族成员作为内生投资 sponsor 完工时，新增建筑所有权归给该
家族。非家族 sponsor 仍生成匿名建筑。

所有生产、销售、工资、消费和税务事件继续走原经济流水：

```text
building/market transaction
  -> cohort or merchant funds
  -> source-local tax withholding / fiscal escrow
  -> country treasury commit
  -> FAMILY_COMMIT normalizes cash_claim and employment attribution
```

家族总财产为成员 `cash_claim` 加其拥有建筑的只读资产估值；资产估值不参与守恒账本。不存在
家族钱包向 cohort 注资、跨境汇回或二次征税。

## 调度与性能

经济图在 `BUILDING_COMMIT` 后依次执行 `FAMILY_COMMIT=16`、`PERSON_COMMIT=17`，再进入
`AGGREGATE_PUBLISH`。家族阶段：

1. 归一化成员人口/现金 claim，并更新职业就业归因；
2. 按确定 cell work budget 评审形成；
3. 复核衰退/消亡，压缩边表并重建索引。

热循环只遍历当前建筑格和稀疏关系边。提交后重建以下 transient CSR：family→cohort、
cohort→membership、family→building、building→ownership、cell→family。CSR 不进入存档或状态哈希，
恢复后确定性重建。`family_cells_per_slice` 控制形成扫描的 continuation 工作上限；成员与产业边受
`family_max_per_cell` 的稀疏上限约束，在冷路径提交点统一归一化和重建 CSR。
`OFF` 且无历史家族时为常数时间跳过。

玩家接口完全只读：

- `get_family_cell_snapshot(cell, offset, limit)`：地块家族分页摘要；
- `get_family_snapshot(handle)`：身份、人口、财产和职业统计；
- `get_family_branches(handle, offset, limit)`：地理分支；
- `get_family_industries(handle, offset, limit)`：产业与业主占岗；
- `get_building_cell_snapshot(cell)`：附带所有权 CSR。

查询只允许在 native slice 间读取，不复制全图、不产生命令、不进入 state hash。

## PKEC v26 / v27

PKEC v26 首次加入家族权威状态；当前 writer 为 PKEC v27。家族 header 继续记录独立
`family_catalog_hash` 以及会改变模拟语义的 mode、形成门槛、评审周期、
每格上限与衰退次数；纯 continuation slice budget 不保存。历史 section 0–14 后追加：

- section 15：FamilyStore records（包含 inactive tombstone generation）；
- section 16：membership edges；
- section 17：building ownership edges；
- PKEC v26 section 18：end；PKEC v27 section 18–19 为人物 records/needs，section 20 为 end。

恢复校验 generation handle、cohort/building 引用、非负数量、每 cohort 人口/资金子集约束和每建筑
家族 `owned_count <= group.count`，随后重建全部 CSR。PKEC v25 显式迁移为“空家族权威状态”；
PKEC v26 恢复为“空重要人物状态”，更早版本沿用既有兼容策略。姓氏稳定 ID 或权重改变会改变
family catalog hash，不能静默重映射。

## 验证要求

最低验收包括：家族形成门槛、实际业主占岗、职业统计、所有权 CSR、人口/货币/商品守恒、PKEC
v27 hash round-trip、v26 空人物迁移、v25 空家族迁移、generation 旧句柄拒绝，以及家族/人物关闭与
开启的目标规模性能对比。

## 维护入口

- 后续开发先加载仓库 Skill：
  [project-keynes-family-runtime](../../.codex/skills/project-keynes-family-runtime/SKILL.md)。
- 家族行为、重要人物、守恒、职业统计、所有权 CSR 与 PKEC v27 的最小回归入口是
  `Project/project-keynes/tests/family_runtime_test.gd`。
- 影响通用经济、税务、国家或调度时，同时加载相应 Economy、Tax、Country 与 Runtime
  Architecture Skill；本页仍是家族模型的项目文档单一事实源。
