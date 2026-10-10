# 家族人口、归属账与决策器

状态：已实现（`gdext/src/economy_runtime_family_demography.cpp` 及各调用点）。运行时契约摘要在
[显赫家族原生运行时](./notable-family-runtime.md)；本页记录公式、参数、调度与实现取舍。

## 1. 动机：旧实现的五个结构性缺陷

以下结论来自 `tests/family_economy_probe.gd` 对两个玩家存档的长程回放：

1. **家族人口只减不增。** `normalize_family_memberships()` 每日按
   `floor(当前 cohort 人口 × 上次份额)` 重算成员人数：cohort 减 1 人时家族必失 1 人，增 1 人时
   几乎从不得 1 人。某开局家族在其猎人 cohort 由 479 增至 517 人的同时由 46 人降到 0 并解散。
2. **出生从不进家族。** 新生儿全部进入无业匿名 cohort；「开枝散叶」只放大总出生数。
3. **吸收被半城上限卡死。** 格子到达 50% 上限后，余量被稳定 ID 靠前的家族先吸走。
4. **外流优先抽家族成员。** `move_family_membership()` 先扣家族边，导致成员职业剧烈跳动。
5. **所有权、经营与资金脱钩。** 家族持有 288 栋建筑但只占 1 个业主岗；含家族 cohort 的投资从不
   考虑匿名 sponsor；快照与分支的资产口径相差两个数量级。

## 2. 不变量

- **总量不变。** 出生总数、每个 cohort 的死亡总数、货币与商品总量由既有经济流水决定；家族层只
  决定“归属给谁”。效果铸造的人口仍走 `POPULATION_SOURCE`。
- **子集约束。** 每个 cohort：`Σ family.people ≤ population`、`Σ cash_claim ≤ funds`。
- **确定性。** Q16 整数；整数拆分用系统抽样：`mix64(seed, epoch, cohort…)` 给出一个 Q16 偏移，
  沿累计期望取整，每方得到期望的 floor 或 ceil 且均值恰为期望，`Σ = 目标`；钳位/截断修补从哈希
  旋转起点开始。不能用“各方独立掷签 + 从尾部削减、从头部补足”：匿名方总在末尾，单人事件里家族
  中签率会从 20% 偏到约 36%，长程把家族占比推过目标。不持久化余数，无随机数。
- **稀疏。** 只遍历成员边、分支、家族所在格的建筑组；没有 `cell × family` 或
  `building × family` 扫描。
- **工作线程边界。** 市场 worker 只把 `(slot, population_before, deaths)` 写进
  `MarketResult.family_demography`；成员边只在主线程提交阶段修改。
- **饥饿不变量。** 死亡总数仍只读生存满足度；家族层只重新分配“谁死”。

## 3. 人口

### 3.1 派生人口学行

`EPOCH_BEGIN`（`clear_epoch_metrics()` 之后）与存档恢复后调用
`rebuild_family_demography_weights()`，从持久化成员边派生 `_family_demography_rows`（按
`(cell, family_handle)` 排序，不持久化）：

```text
s  = 家族在该格的成员人数 / 该格与家族起源民族相同的人口
B  = clamp(分支 building_share / B_ref, 0, 1)
W  = clamp(log2(家族人均 claim / 同格同民族人均资金), -2, 2) / 2
E  = 家族成员就业率 * 2 - 1
H  = a_B·B + a_W·W + a_E·E
σ(x) = 1/2 + x / (2(1 + |x|))
s*_raw = S_min + (S_max − S_min)·σ(H) [+ 吸收加成 × 5%，≤ S_max]
D  = max(D_sub, ρ·D_cash)
     D_sub  = clamp((θ_sub − 成员加权生存满足度) / θ_sub, 0, 1)
     D_cash = clamp((r_cash − 人均 claim/同格人均资金) / r_cash, 0, 1)
s* = s*_raw·(1 − D)²
```

同格同民族各分支的 `Σ s*` 超过 `S_total` 时先求和、再统一按比例缩到 `S_total`。

偏离度与权重（相对匿名人口权重 1）：

```text
φ   = clamp((s* − s) / max(s*, s_ε), −1, 1)
w_b = clamp(1 + k_b·φ − μ·D, w_min, w_max) × 开枝散叶因子
w_d = clamp(1 − k_d·φ + λ·D, w_min, w_max)
```

`φ > 0` 且无困难时家族人均增长快于匿名，占比向 `s*` 上升；`D → 1` 时 `s* → 0`，家族逐步缩小。

### 3.2 出生与死亡归属

- **出生**：`STRUCTURAL_COMMIT` 每条出生命令调用 `apply_family_birth_attribution(slot, B)`。同格
  同民族各分支期望 `∝ s·w_b`，匿名 `∝ (1 − Σs)`；舍入后新生儿并入家族在该无业 cohort 的边，
  无边则新建（`funds_basis` 取同 cohort 兄弟边基数）。新生儿不带 claim。
- **死亡**：市场 worker 对可能含家族边的 cohort 发出 `family_demography`，否则仍发
  `person_demography`。主线程合并时 `apply_family_death_attribution()` 按
  `E_d(edge) ∝ n_f·w_d(f)`、匿名 `∝ n_anon` 分摊 `D_k`，上限为边人数；该边的重要人物按同一死亡
  人数确定性退役。

### 3.3 依附招募（慢通道，只增不减）

每个分支按 `mix64(stable_id, cell) % review_days` 错峰；评审日若 `s < s*`，
`want = min(S_total 余量, 同民族人口 × (s* − s) × 2%)`，从家族在该格已有边的 cohort 的匿名池
（每 cohort 留 1 人）由大到小吸收，资金按匿名人均随人进入 claim。`s > s*` 时不主动出走，只靠
死亡权重回落。

### 3.4 其他人口路径

- **外流按比例。** `move_cohort_population()` 先调用 `plan_family_membership_move()`：`m` 人按人数
  比例分到匿名与各家族边，`career_mobility` 作为家族边上限，职业偏好家族权重 ×2；投资转业与
  开拓包使用 strict 模式，先移 sponsor 方（`preferred == 0` 表示匿名）。**业主岗保护：**
  若源 cohort 是某家族持有组的业主 cohort，该家族边先扣出“自家业主岗数”（
  `_family_owner_seat_rows`，EPOCH_BEGIN 随人口学行重建，按 `(cohort_handle, family_handle)`
  排序二分查找；岗数 = 持有单元 × `owner_slots_per_building`）不参与抽样，只有其余人全部
  移完仍不够时才动用（strict 模式下的 preferred 家族不受保护）。保护人数计入
  `family_owner_seats_guarded`。资金随人移动：
  `Σ 被移动边人均 claim × 人数 + 匿名人均余额 × 匿名人数`；cohort 全部移出时资金全部移出。
- **每日比例重算已删除。** `normalize_family_memberships()` 只做向下兜底（`Σ people >
  population` 时按比例扣减，记 `family_reconcile_corrections`）。
- **持续吸收已删除。** 家庭规模吸收只对当日新立的家族执行；立族创始人数与吸收都受同格
  `S_total` 余量约束。

## 4. 归属账

不新增持久化字段：成员边的 `funds_basis` 即“上次结算后该 cohort 资金”，同一 cohort 的边共享
同一基数（读取取最大值），`population_basis` 只作信息。

`FAMILY_COMMIT` phase 0 `normalize_family_memberships(false, true)`：

1. `settle_family_claim_ledger()` 只遍历有家族的格子（`_family_cell_offsets` × `_building_cell_offsets`），
   计算家族持有建筑组的业主净收入
   `last_revenue − last_input_cost − last_wages_paid − last_maintenance_cost`，按家族实际占用的
   业主岗（无人在岗时按持有单元）分给对应成员边，并记入业主 cohort 的 business 合计。
2. 每个 cohort：`remainder = funds − basis − Σ business`；每条边
   `claim += business_share + remainder × people / population`，`claim ≥ 0`；`Σ claim > funds` 时按
   比例压缩（`family_ledger_clamps`）；然后 `basis = funds`。

结构性资金移动不应被当作收支，所以在发生处显式处理：

| 事件 | 处理 |
|------|------|
| 迁移/转业 `move_cohort_population` | 源 basis −资金，目标 basis +资金，claim 随计划移动 |
| 商人拆分 | 源 −份额，目标 +份额 |
| 开拓出发/回滚/抵达 | 出发 −载荷资金；回滚与抵达 +载荷资金 |
| 投资资本划拨、商人启动信贷 | `attribute_family_funds_delta(slot, sponsor, ±Δ)` |
| 施工支出（扣除资金缺口） | 同上，记到 sponsor 家族 |

`attribute_family_funds_delta` 同时平移该 cohort 所有边的 basis，并把 Δ 记到 sponsor 家族的 claim。

净资产 = `Σ claim + Σ 持有建筑的 building_reset_capital_value()`，快照与分支统一口径。

## 5. 产业、岗位与决策

- **决策走既有门槛路径，不新增意图队列。** 投资 sponsor 搜索在含家族的 cohort 中同时评估各家族
  （`claim − 30 日生活储备`）与匿名方（`funds − Σclaim − 储备`）；家族 sponsor 完工归家族，匿名
  sponsor 生成匿名建筑。sponsor 覆盖在 `commit_preflighted_build_command` 前后设置与清除。
- **业主岗归因。** 岗位总数仍由职业钳制决定；家族持有单元的业主岗先由同格同 signature 的本家族
  成员占用（≤ 持有单元岗位数）；剩余的已填业主岗按“未占自家岗”的人数比例分给家族与匿名。
- **自家补岗。** 就业阶段为家族持有组招业主、且落点正是该组业主 signature 时，若持有家族在
  失业池中有成员（`owning_family_for_owner_hire`，读 `_family_building_offsets` CSR 并校验
  building handle），以 strict 模式先移本家族成员，再按比例补匿名；仍受原有收入门槛与配额约束。
- **释放。** 分支评审到期时，若家族在某持有组的业主 cohort 中已无成员：
  1. 该组还有空业主岗、且家族在同格同民族失业池中有成员 → 本次不释放，留给下次招业主
     （`family_release_deferred`）；
  2. 否则分批释放，每次至多 `max(1, ceil(owned / 4))` 个单元（`FAMILY_RELEASE_STEP_DIVISOR`，
     `family_units_released`）。
  三项都只读持久化状态并在每日重建派生表，不保存跨日意图，因此无新增持久化字段，读档后与连续
  运行一致。

## 6. FamilyEffect 兼容

| 效果 | 语义 |
|------|------|
| 威望分档 Modifier / Trigger | 不变 |
| 「开枝散叶」`_family_birth_factor_q16` | 放大 cohort 出生率，同时乘进 `w_b` |
| `family.absorb_anonymous` 一次性吸收 | 保留为显式成员事件 |
| `family.absorb_anonymous` SET 加成 | 改为 `s*` 上调 `加成 × 5%` |
| `family.population_reward` | 保留，铸造后记入家族边（basis 取兄弟边） |
| 其余（折扣、免费建筑、投资因子、行为偏好） | 不变 |

FamilyEffect metric 仍为 0–36；占比/目标/困难度通过查询暴露
（`get_family_branches` 的 `demography_shares_q16` / `target_shares_q16` / `distress_q16`，
`get_family_branch_effects` 另附出生/死亡权重），未追加 metric 37–39。

## 7. 调度

```text
EPOCH_BEGIN        : clear_epoch_metrics → rebuild_family_demography_weights（含业主岗表）
HOUSEHOLD_MARKET   : worker 发出 family_demography 死亡事件；主线程合并时按 w_d 归属
STRUCTURAL_COMMIT  : 出生命令按 w_b 归属
BUILDING_*         : 投资/施工资金归属、业主岗归因、家族持有组业主招聘先取本家族
FAMILY_COMMIT
  phase 0 : 重建 CSR → 归属账结算与人数兜底 → 依附招募 → 当日新家族吸收 → 就业归因
  phase 1 : 里程碑评审与立族
  phase 2 : 新家族吸收、生命周期（含释放）、CSR 重建、影响力/威望
```

CSR 有效性：`_family_csr_edge_count ≤ family_memberships().size()`，下标 ≥ 该值的边为线性尾部；
`collect_family_edges_for_cohort` 同时覆盖 CSR 区间与尾部。

## 8. 存档

PKEC schema 不变：不新增字段，`funds_basis` 语义改为 cohort 账本基数，派生行在恢复后重建。
参数为编译期常量，不进入 family policy header。

## 9. 参数

| 参数 | 默认 | 常量 |
|------|------|------|
| `S_min` / `S_max` / `S_total` | 20% / 70% / 70% | `FAMILY_TARGET_SHARE_*_Q16` |
| `s_ε` | 1% | `FAMILY_TARGET_SHARE_EPSILON_Q16` |
| `a_B` / `a_W` / `a_E` | 1.5 / 1.0 / 0.5 | `FAMILY_HEALTH_*_WEIGHT_Q16` |
| `B_ref` | 25% | `FAMILY_HEALTH_BUILDING_REF_Q16` |
| `θ_sub` | 饥饿满足度阈值 | `_starvation_satisfaction_threshold_q16` |
| `r_cash` / `ρ` | 25% / 0.5 | `FAMILY_CASH_DISTRESS_*_Q16` |
| `k_b` / `k_d` / `μ` / `λ` | 1.0 / 0.5 / 0.5 / 1.0 | `FAMILY_BIRTH/DEATH_*SLOPE_Q16` |
| `w_min` / `w_max` | 0.25 / 3.0 | `FAMILY_WEIGHT_*_Q16` |
| 招募速率 | 每次评审 2% 差距 | `FAMILY_RECRUIT_RATE_Q16` |
| 吸收加成换算 | 5% | `FAMILY_ABSORB_TARGET_BONUS_Q16` |

## 10. 诊断

`family_births_attributed`、`family_deaths_attributed`、`family_reconcile_corrections`（应为 0）、
`family_ledger_clamps`、`family_people_recruited`、`family_units_released`、`family_release_deferred`、
`family_owner_seats_guarded`、`family_demography_rows`、
`family_demography_weights_ms`，均为每 epoch 计数。

## 11. 已知取舍

- 开拓载荷资金仍按 cohort 人均计算（保守，不按家族 claim）。
- 生产收入与成本的入账时点差异由 `remainder` 项按人数吸收，不逐项记账；税、消费、补贴同样按
  人数分摊。
- 成员“出走”不主动发生，超目标的家族只靠死亡权重回落。
