# 家族人口、归属账与决策器重构设计

状态：设计已确认，未实现。实现完成的部分迁入
[显赫家族原生运行时](./notable-family-runtime.md)，本页随之删减对应章节。

## 1. 动机：现状的五个结构性缺陷

以下结论来自 `tests/family_economy_probe.gd` 对两个玩家存档的长程回放（第 367 天档跑
2000 天、第 13725 天档跑 1500 天，人口/货币/商品账本误差均为 0）：

1. **家族人口只减不增。** `normalize_family_memberships()` 每日按
   `floor(当前 cohort 人口 × 上次份额)` 重算成员人数。cohort 减 1 人时家族必失 1 人，增 1 人
   时几乎从不得 1 人。实测某开局家族在其猎人 cohort 由 479 增至 517 人的同时由 46 人降到 0
   并解散；cohort 减员的 39 天里家族有 38 天减员，cohort 增员的 44 天里家族仅 1 天增员。
2. **出生从不进家族。** 出生在 `(cell, ethnicity)` 汇总后全部进入无业 signature 的匿名 cohort；
   现有「开枝散叶」只放大总出生数，新生儿仍是匿名人口。
3. **吸收被半城上限卡死。** 同格全部家族人口不得超过当地人口一半；格子到达上限后，偶有的
   余量被稳定 ID 靠前的家族先吸走，衰减中的家族得不到补充。
4. **外流优先抽家族成员。** `move_family_membership()` 只在家族边之间扣人，家族边扣完前不动
   匿名人口，导致家族成员职业剧烈跳动（30 天内 9 名采集者 → 1 名采集者 + 8 名猎人）。
5. **所有权、经营与资金三者脱钩。** 家族持有 288 栋建筑但只占 1 个业主岗；含家族的 cohort
   投资从不考虑匿名 sponsor，用全 cohort 的钱却 100% 记给家族且不扣家族 claim；
   `get_family_snapshot` 的资产估值用单日流水，`get_family_branches` 用重置资本，同一家族两处
   相差可达两个数量级。

## 2. 目标与不变量

目标：家族成为有自己数据的对象（人口池、归属账、产业），以家族作为**决策器**发起行动；
人口、财产、产业只通过可追溯的事件变化，决策不直接改写家族的派生计算。

不变量（任何阶段都必须保持）：

- **总量不变。** 出生总数、每个 cohort 的死亡总数、货币与商品总量都由既有经济流水决定；家族
  层只决定“归属给谁”，不新增、不销毁任何人口、货币或商品。效果显式铸造的人口仍走
  `POPULATION_SOURCE` 账本事件。
- **子集约束。** 对每个 cohort：`Σ family.people ≤ cohort.population`，
  `Σ family.cash_claim ≤ cohort.funds`；重要人物仍是成员边的子集。
- **确定性。** 全部使用 Q16/Q32 整数；不使用随机数，期望值配余数累加器，余数持久化；并列按
  稳定 ID 排序。同一存档同一输入得到同一 state hash。
- **稀疏。** 只遍历成员边、分支、家族持有的建筑组；禁止 `cell × family`、`building × family`
  扫描。
- **工作线程边界。** 市场结算 worker 只把家族相关事实写进 `MarketResult`，家族权威只在
  `FAMILY_COMMIT` 修改。
- **饥饿不变量。** 饥饿死亡率仍只读生存满足度；家族层只重新分配“谁死”，不改变死亡总数。

## 3. 分层模型

```text
权威状态（PKEC 持久化）
  FamilyStore / 成员边(people, cash_claim, death_residual)
  分支(birth_residual, recruit_residual, 评审状态) / 所有权边(owned_count, release_streak)
        ▲ 只经由下列事件修改
事件归属层（FAMILY_COMMIT，确定性、守恒）
  出生归属 · 死亡归属 · 外流按比例分摊 · 收支记账 · 新建/拆除分配 · 效果奖励
        ▲ 行动结果以事件形式回流
决策器（分支评审相位）
  读取权威状态与特性 → 发出行动意图（投资、配岗、释放产业）
        ▼ 意图走既有命令路径与全部门槛
派生/展示层（不持久化）
  目标占比 s*、健康度分量、威望、净资产 = claim + 重置资本估值
```

## 4. 人口：目标占比与倾斜归属

### 4.1 占比与目标

占比的统计口径为分支 `(family, cell)`：

```text
s  = 家族在该格的成员人数 / 该格与家族起源民族相同的人口
```

健康度由三个与人口无关的分量组成（剔除人口项以避免“人多 → 威望高 → 生得多”的自增强）：

```text
B = clamp(分支建筑资产占比 / B_ref, 0, 1)                  建筑：重置资本口径
W = clamp(log2(家族人均 claim / 同格同民族人均资金) / 2, -1, 1)   财富：归属账的相对富裕度
E = 家族成员就业率 * 2 - 1                                  就业：业主+雇员 / 成员，映射到 [-1, 1]
H = a_B * B + a_W * W + a_E * E
```

困难度只读生存与现金，取较大者：

```text
D_sub  = clamp((θ_sub - 成员加权生存满足度) / θ_sub, 0, 1)
D_cash = clamp(1 - 家族人均 claim / (k_cash 日生活成本), 0, 1)
D      = max(D_sub, ρ * D_cash)
```

目标占比（20%–70% 为健康家族区间，困难把目标压向 0）：

```text
σ(x)    = 1/2 + x / (2 * (1 + |x|))            有理逻辑函数，整数可实现、单调
s*_raw  = S_min + (S_max - S_min) * σ(H)
s*      = s*_raw * (1 - D)^2
```

同格同民族所有家族的 `Σ s*` 超过 `S_total` 时按比例缩小到 `S_total`，保证匿名人口始终存在。

### 4.2 出生与死亡权重

偏离度 `φ = clamp((s* - s) / max(s*, s_ε), -1, 1)`；`s* = 0` 时 `φ = -1`。相对匿名人口（权重 1）：

```text
w_b = clamp(1 + k_b * φ - μ * D, w_min, w_max) * 开枝散叶因子
w_d = clamp(1 - k_d * φ + λ * D, w_min, w_max)
```

- **出生归属**：结构提交阶段为每个 `(cell, ethnicity)` 记录本期出生数 `B`。家族分支的期望领取量

  ```text
  E_b(f) = B * Σ_e(n_e r_e) w_b(f) / (Σ_全部 cohort(n r) + Σ_f Σ_e(n_e r_e)(w_b(f) - 1))
  ```

  其中 `n_e r_e` 是家族在各 cohort 的人数乘该 signature 出生率。期望值累加到分支
  `birth_residual_q32`，整数部分即领取人数；同格家族按最大余数法分配并保证 `Σ ≤ B`，余下的
  留给匿名。领取的新生儿记入家族在该格无业 cohort 的成员边。
- **死亡归属**：市场 worker 照常算出每个 cohort 的死亡数 `D_k`，并把 `(cohort, D_k)` 写进
  `MarketResult`。`FAMILY_COMMIT` 中每条成员边

  ```text
  E_d(edge) = D_k * n_f w_d(f) / (n_anon + Σ_f n_f w_d(f))
  ```

  累加到 `death_residual_q32`，整数部分为该边死亡人数，上限 `n_f`，同 cohort 按最大余数法保证
  `Σ ≤ D_k`。该边的重要人物按“死亡人数 / 边人数”的确定性规则同步死亡。

性质：`φ > 0` 且无困难时家族人均增长率高于匿名人口，占比向 `s*` 上升；`φ < 0` 时反向回落；
`D → 1` 时 `s* → 0`，家族逐步缩小直至人口归零而解散。总出生、总死亡不变。

### 4.3 依附与出走（可选慢通道）

出生和死亡在小格子里可能太慢。每次分支评审，若 `s < s*`，按
`recruit_rate * (s* - s) * N` 从同格家族已有 signature 的匿名人口吸收依附者；若 `s > s*`，按同一
速率让成员回归匿名。人数与人均资金一起移动，只改归属，累加到 `recruit_residual_q32`。
默认 `recruit_rate` 较小，调参时决定家族“几代人”达到目标的速度。

### 4.4 其他人口路径

- **外流按比例分摊。** 职业转换、迁移、投资转业时，从 cohort 移出的 `m` 人按人数比例在匿名与
  各家族边之间最大余数分配；职业偏好（`career_mobility`、`preferred_family`）只作为该比例上的
  有界倾斜，不再“家族优先抽空”。资金随人走：移出资金 = 被移动家族边的人均 claim 之和 + 匿名
  人均资金 × 匿名移出人数（需改 `move_cohort_population` 的资金计算）。
- **删除每日比例重算。** `normalize_family_memberships()` 不再缩放人数和 claim。保留一个只向下的
  兜底：若某 cohort 的家族人数之和超过人口，按比例扣减并记 `family_reconcile_corrections`
  诊断；正常情况下该计数应为 0。
- **删除持续吸收与半城上限。** 家庭规模吸收只在立族时执行一次；同格家族总量由 `S_total`
  约束。`family_household_*` 只影响创始人数。
- **立族、分家、开拓、消亡**：保持现有规则；分家时余数按人数比例分到子家族。

## 5. 财产：成员边归属账

`cash_claim` 改为可追溯的归属账，沿用重要人物 `reconcile_person_claims()` 的模式，粒度提升到
成员边。每次 `FAMILY_COMMIT` 对每条成员边：

```text
claim_next = claim
           + 自家建筑业主净收入 × owned_count / group_units      （记入业主 cohort 的边）
           + 雇员工资收入 × 家族雇员人数 / cohort 雇员人数
           + 转移与补贴 × 家族人数 / cohort 人数
           - 家庭消费 × 家族人数 × 家族消费权重 / cohort 加权人数
           - 本期所得税、消费税、经营税中归属本边的部分
           - 决策器投资划拨
```

- 匿名部分为余额：`anon = cohort.funds - Σ claim_next`。若为负（匿名人口花掉了家族的钱），按比例
  压缩家族 claim 直到匿名余额为 0，并记 `family_ledger_clamps`。
- 立族与吸收时按匿名人均资金取得初始 claim；外流时 claim 随人按边人均移动；开拓载荷沿用现有
  `cash_claim` 字段。
- 净资产 = `Σ claim + Σ 持有建筑的重置资本估值`。`get_family_snapshot` 与 `get_family_branches`
  统一使用 `building_reset_capital_value()`，UI 不再出现两套口径。
- 4.1 中的财富分量 `W` 因此成为独立信息，而不是“人口 × 人均”的同义反复。

## 6. 产业与岗位：分配法

- **增量分配。** 家族决策器发起的投资完工后归家族；匿名 sponsor 的投资归匿名；`family.free_building`
  归家族。拆除或清算 `k` 栋时按各家族与匿名持有量最大余数分配减少量。
- **匿名 sponsor 恢复。** `find_investment_sponsor` 对含家族的 cohort 同时考虑匿名方，匿名方只能
  动用匿名余额；家族方只能动用家族 claim 减去生活储备的部分。
- **业主岗优先级。** 家族持有单元的业主岗先由同格同 signature 的本家族成员填充，再由匿名人口
  填充；家族成员在自家岗位满后可填匿名岗位。`family_filled_owner` 不得超过家族持有份额对应的
  岗位数。
- **释放。** 分支评审时，若家族持有的业主岗连续 `release_reviews` 次多于本家族可用的同 signature
  成员，决策器把多余单元释放给匿名（第一版无补偿，不涉及资金）。
- **就业统计**：家族雇员人数 = cohort 雇员人数按（家族人数 − 家族业主人数）比例分摊。

## 7. 决策器

家族决策器只在分支评审相位运行（每 30 日按稳定分支 ID 错峰）。它读取权威状态和特性，输出意图，
意图在下一日的既有执行路径上运行并通过全部门槛，结果以第 5、6 节的事件回流：

| 意图 | 预算与门槛 | 结果事件 |
|------|------------|----------|
| `INVEST(cell, type, count)` | 家族 claim − 生活储备；科技、资本、建材、资源、岗位、盈利门槛不变；候选打分 × 行为偏好因子 × `_family_investment_factor_q16` | 资本划拨（账）、业主转业（按家族优先外流）、完工归家族（产业） |
| `STAFF(group)` | 本家族同格成员；转业门槛不变 | 外流事件 |
| `RELEASE(group, k)` | 持续无法自营的单元 | 所有权事件 |

消费与招工偏好不产生意图：消费偏好继续作用于家族在 cohort 内的需求份额（同时决定第 5 节的消费
权重）；招工偏好作为城市层加成，按家族在格内占比缩放后进入既有岗位分配，多家族取加权平均而
不是相加。决策器不直接修改人口、claim 或所有权。

## 8. 与 FamilyEffect 的兼容

| 现有效果 | 新语义 |
|----------|--------|
| 威望分档 Modifier / Trigger | 不变 |
| 「开枝散叶」`_family_birth_factor_q16` | 仍放大成员对出生池的贡献，同时乘进 `w_b`，多生的人归家族 |
| `family.absorb_anonymous`（opcode 21）一次性吸收 | 保留为显式成员事件 |
| `family.absorb_anonymous` 的 SET 家庭吸收加成 | 改为 `s*` 加成（目标占比上调） |
| `family.population_reward` / 开拓 `population_reward` | 保留，`POPULATION_SOURCE` 铸造后直接记入家族边 |
| `family.purchase_discount`（opcode 22） | 补贴流水不变；归属账中减少家族消费支出 |
| `family.free_building` | 增量分配给家族，不扣资金 |
| `_family_investment_factor_q16` | 决策器 `INVEST` 候选打分因子 |
| 行为偏好 CSR | 投资 → 决策器打分；招工 → 城市层加成；消费 → 家族需求份额 |

FamilyEffect metric 0–36 不变；只在末尾追加：37 `branch.share_q16`、38 `branch.target_share_q16`、
39 `branch.distress_q16`。

## 9. 调度

```text
MARKET (worker)      : 每 cohort 死亡数写入 MarketResult.family_death_events
STRUCTURAL_COMMIT    : 记录本期 (cell, ethnicity) 出生数（transient，日内消费）
BUILDING_COMMIT      : 执行上一日决策器意图（投资、配岗、释放）
FAMILY_COMMIT
  0 已选立族卡、效果事件
  1 出生/死亡归属，依附/出走
  2 归属账记账与钳位
  3 只向下的人数兜底
  4 立族（里程碑）
  5 生命周期、CSR 重建、影响力/威望、行为缓存
  6 评审相位分支运行决策器，意图入队
PERSON_COMMIT        : 不变
```

实现时需确认 `STRUCTURAL_COMMIT` 位于同日 `FAMILY_COMMIT` 之前，且存档只发生在完整日界之后，
否则出生记录需进入 PKEC。

## 10. 存档

升 `SCHEMA_VERSION`，旧存档按版本不符拒绝，不做迁移（已确认可接受）：

- 成员边：删除 `population_basis` / `funds_basis`，新增 `death_residual_q32`。
- 分支：新增 `birth_residual_q32`、`recruit_residual_q32`。
- 所有权边：新增 `release_streak`。
- family policy header：`S_min`、`S_max`、`S_total` 与全部权重参数进入 policy hash，改动即
  `save_family_policy_profile_mismatch`。
- 决策器待执行意图进入 PKEC（与待建队列同级）；目标占比、健康度、权重为派生值，不持久化。
- 以上字段全部进入 economy state hash。

## 11. 参数默认值

| 参数 | 默认 | 含义 |
|------|------|------|
| `S_min` / `S_max` | 20% / 70% | 健康家族目标占比区间 |
| `S_total` | 70% | 同格同民族家族目标合计上限 |
| `s_ε` | 1% | 偏离度分母下限 |
| `a_B` / `a_W` / `a_E` | 1.5 / 1.0 / 0.5 | 健康度权重 |
| `B_ref` | 25% | 建筑占比满分点 |
| `θ_sub` | 现行社会压力阈值 | 生存困难阈值 |
| `k_cash` / `ρ` | 30 日 / 0.5 | 现金困难尺度与权重 |
| `k_b` / `k_d` | 1.0 / 0.5 | 偏离度对出生、死亡权重的斜率 |
| `μ` / `λ` | 0.5 / 1.0 | 困难度对出生、死亡权重的斜率 |
| `w_min` / `w_max` | 0.25 / 3.0 | 权重夹取 |
| `recruit_rate` | 每次评审 2% | 依附/出走慢通道 |
| `release_reviews` | 3 | 无法自营多少次评审后释放 |

## 12. 验收

- 单元测试：出生领取 `Σ ≤ B`、死亡分担 `Σ ≤ D_k`；cohort 人口 ±1 振荡 1000 日家族人数不漂移；
  `s = s*` 时期望增量为 0；`D = 1` 时家族单调衰亡；外流按比例；归属账与 cohort 资金守恒；
  `family_filled_owner ≤` 持有岗位；PKEC round-trip hash 相等；旧版本拒绝。
- 探针回放（`PK_FAMILY_PROBE=1`，两份玩家存档）：健康家族占比收敛到 `s*` 附近；同格家族合计
  `≤ S_total`；`family_reconcile_corrections = 0`；无“有产业、有现金却因人数归零解散”；净资产
  单一口径；账本误差为 0。
- 性能：50 日生产路径 headless 记录，经济阶段 avg/p95 不超出现状噪声带（±15%）。

## 13. 分阶段实施

1. **人口**：出生/死亡归属、外流按比例、删除比例重算与持续吸收、`s*` 与 `S_total`、PKEC 升版。
   `W` 暂用现有 claim。
2. **归属账**：成员边记账、匿名余额钳位、资金随人移动、净资产统一口径。
3. **产业与决策器**：增量分配、匿名 sponsor 恢复、业主岗优先级、释放、`INVEST/STAFF/RELEASE`。
4. **效果与界面**：第 8 节兼容改造、追加 metric 37–39、UI 展示占比/目标/健康度分量，迁移本页
   内容到主文档并更新 Skill。

每阶段完成后用探针回放两份存档并与上一阶段对比。
