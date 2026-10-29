# M5-60 子 Agent 协同：B1 / B4 / §11.7 时点 1 三项证据 + 两处既有缺陷

| 项目 | 内容 |
|---|---|
| 方式 | 4 个子 Agent 并行（各写一个纯 GDScript 夹具，不改 C++、不重建、不换 DLL）|
| 日期 | 2026-10-28，Asia/Hong_Kong |
| 结果 | 三项新证据落地；顺带发现并修掉两处既有缺陷；另有三条跨项发现 |

## 0. 我做了什么核验

**我不采信子 Agent 的「通过了」。** 每个夹具都由我在自己的终端重跑一遍，只认检查数、失败数和实测数字。

| 夹具 | 子 Agent 报 | **我独立复跑** |
|---|---|---|
| B1 | 39 / 0 | ✅ **39 / 0**，`worst_step_ms=2.572`、`slices_max_ms=3.603` |
| B4 | 31 / 0 | ✅ **31 / 0** |
| 存档时点 1 | 177 / 0 | ✅ **exit=0**，`fingerprint=b80012bf…` 在 continuous 与 reload-A/B 三条分支上一致 |
| （B3）| 仍在跑 | — |

**DLL 身份全程未变**（每次核验前检查 `35bc333c3cceb1f4`），确认 Agent 没有偷偷重建。

---

## 1. B1：64 国 × 12 卡主线程

`tests/ideology/ideology_b1_many_countries_test.gd` — **39 checks / 0**

| 量 | 值 |
|---|---|
| 国家 / 格 / 卡 | **64 / 512 / 768**（每国 8 格、12 卡，`commands_rejected=0`）|
| front | 12 stats × 512 格 = **6144 行 / 6144 contribution / 271,008 字节** |
| `cell_layer_rows_emitted` / `commands_folded` | 6144 / 7680 |
| **`instances`（64 个 handle 求和）** | **0** ← I01 在规模上成立 |
| `truncated` / `missing_stat` / `last_error` | 0 / 0 / 空 |
| **最差 fold 步 / 最差 slice** | **2.572 ms / 3.603 ms** |

### 这条是 §14.3 的一个真实数据点

`DERIVED_REBUILD_STEP_BUDGET_MS = 0.45 ms`，而 64 国 × 12 卡时**单步 2.572 ms**。
**这是继「超大国家 kind 14/15」之后的第二个超标场景**，且成因不同（这次是**卡数**，不是格数）。

我把它记为已知超标，**没有写成「达标」**。

## 2. B4：每日 1% tag 翻转

`tests/ideology/ideology_b4_tag_flip_volume_test.gd` — **31 checks / 0**

| 量 | 值 |
|---|---|
| 格 / 天 | 400（4 国 × 100）/ 20 |
| 翻转 | **72**（上 64、下 8），期望 80 → 在 2 倍带内 |
| `tag_changes` | **72** 格·天；**单日最多 4 格 = 1.00%** |
| `tag_snapshot_builds` / skips / misses | 22 / 0 / 0 |
| 成本 min/median/max | 日步 **6.404 / 7.165 / 9.217 ms**；翻转批 0.039 ms；**tag 重建 0.052 ms** |

### 关键发现：采集成本与 churn **无关**

| 日 | 重建耗时 |
|---|---|
| 0 翻转 | **0.054 ms** |
| 4 翻转（1%）| **0.051 ms** |
| 36 翻转（9%，探针日）| **0.0535 ms** |

**三者相同。** 所以：**脏范围 = 1% 的格，采集成本 = 100% 的格，每天如此。**

### 它同时指出一个报告缺口

经济报告**没有任何「改变了多少格的 tag 位」字段**——`tag_snapshot_*` 只有成本与节奏（builds/skips/misses/loads/build_ms/concurrent_writes）。夹具把「这个字段不存在」本身写成了一条断言。

脏范围是用两条独立路径从已发布的 `TagSnapshot` 反推的（按国枚举 + metric 62 计数），两者都给 56，且每天与模型逐位一致。

## 3. §11.7 时点 1：建层之前的新局／读档

`tests/ideology/ideology_save_before_layer_test.gd` — **177 checks / 0**

### 存档 API 是真实路径，不是测试钩子

| 调用 | 定义 | 生产使用 |
|---|---|---|
| `capture_ideology_state()` → PKID | `world_ext_ideology.cpp:753` | `game_save_coordinator.gd:967-972` 写 PKSV 的 `pkid` 段 |
| `restore_ideology_state(bytes)` | `:758` | `:1148-1156` 读回 |
| `clear_ideology_state()` | `:763` | 空载荷的迁移路径 |

**关键结构事实**：PKID **不携带派生地块层**（`ideology_runtime.cpp:6387-6501` 只写国家行、点、offer、想法、绑定、待处理命令）。所以「建层前读档」之后，层**必须从恢复的行重建**——这正是本时点要测的。

### 结果

```
[sv1/SAVE-A] layer installed=false cells=0 epoch_active=false     ← 时点前置条件成立
[sv1/continuous] layer cells=84 contributions=84 stats=2
[sv1/continuous] business hash=6933546975327703413 instances=0 pending=0
[sv1/continuous] audit pop_err=0 money_err=0 goods_err=0
[sv1/continuous] per-cell fingerprint=b80012bf59ac2a4305fc133160127aec9649653116549a8b88eda9894210475b
[sv1/reload-A]   … 与 continuous 逐行相同（含 fingerprint）
[sv1/reload-B]   … 与 continuous 逐行相同（含 fingerprint）
```

| 对比维度 | 结果 |
|---|---|
| 64 格 × 2 stat × 2 存档点：presence / add / **有效值** | **全部精确相等** |
| 业务状态哈希与分区 {points, baseline, history, draw, bits, offer, ideas} | 相等 |
| 一次性实例数 / pending 命令 | 0 / 0（两侧）|
| 安装日与安装次数 | 相同 |
| 经济守恒（pop/money/goods）| 两侧均 0 误差 |

**42 个有主格读到 1.05000305（base 1.0 + 卡幅度），22 个无主格读到精确 1.0 且 `derived_present=false`** ——层在空间上是正确的，不是被均匀填满。

### 负向对照：这个对比能失败

把 reload-B 的载荷换成 SAVE-A（读错档）：**177 checks / 23 failures**，例如

```
FAIL reload-B: the reloaded/built runtime HAS a derived cell layer installed=false cells=0
FAIL SAVE-B: ... derived presence matches on every one of 64 cells  mismatches=42
FAIL SAVE-B: ... derived add matches EXACTLY  max_abs_diff=0.050003051758
```

**所以「通过」意味着真的做了一次存档/读档对比。**

---

## 4. 顺带修掉两处既有缺陷

### 4.1 `tag_snapshot_stress_test.gd` 自称 6 国，实际 1 国

```gdscript
var booted := _ext.bootstrap_country({}, is_water)        // 空 packet
for country in range(COUNTRY_COUNT):                       // COUNTRY_COUNT = 6
    var handle := ... get_country_cell_summary(country) ...  // 传的是格号
```

- 空 `country_ids` → 运行时走 `ids.empty()` 分支 → **一国占全部陆格**
- `get_country_cell_summary(x)` 的参数是**格号**，不是国槽 → 6 次拿到**同一个** handle

**净效果：夹具声称「6 国 × 6 格」，实际是「1 国 × 36 格」**，任何按国的量都是同一个国数了六遍。

已修为**显式 6 国 CSR** + **唯一 handle 守卫**（重复即失败）。修后仍 **38 / 0**——断言数不变，只是现在是真的。

### 4.2 `cell_layer_contribs_passed` 是死计数器

`_derived_contribs_passed` 只有报告那一处引用，**自一次性重建被删后从未被写**。B10 只是打印它，**谁都不该拿它做断言**。

替代：`commands_folded`、front 的 `contribution_count`。

---

## 5. 三条跨项发现（会影响后续工作）

### 5.1 装备事务在无头环境下**永不自行结算**

`poll_pending_transition` 等 `transaction_status_pod == ACKED`，而没有 worker/peer 就没人 ack。
实测：`pending_transitions=64` 卡了 512 个 slice，每国只能装 1 张卡（其余被 `ideology_country_transition_pending` 拒绝，因为目录里有 synergy）。

**解法（B1 采用）**：夹具自己驱动公开的 peer 生命周期
`preflight_effect_transactions → commit → ack`（同 `tests/effect/effect_runtime_test.gd:130-151`），704 个事务 ack、0 失败。

**这很可能就是 M4-14 里 B10「settle blocks headless」的同一堵墙。**

### 5.2 kind 16 在**无建筑**经济里解析出 0 个目标

3 张 kind-16 卡实测 `targets_collected_empty=3072`，front 里只有 9/12 stat。换成 kind-12 后 `collected_empty=0`、12/12。

**这条直接解释了 M5-47/M5-48 里 kind 14/15 端到端夹具为何一直走不通**：那类卡需要 tag 源格，而合成世界没有建筑/贸易事件去满足 tag。

### 5.3 出厂理念容量是 2（+5 解锁科技，上限 6）

「每国 12 张卡」**无法从现有内容装配出来**。B1 是在**内存里**把目录资源的 `ideology_capacity/_max` 提到 12（**没有改数据文件**）。

**如果方案期望生产里 12 个槽位，这是一条内容缺口。**

---

## 6. 交付物

| 文件 | 说明 |
|---|---|
| `tests/ideology/ideology_b1_many_countries_test.gd` | **39 / 0** |
| `tests/ideology/ideology_b4_tag_flip_volume_test.gd` | **31 / 0** |
| `tests/ideology/ideology_save_before_layer_test.gd` | **177 / 0**，含负向对照 |
| `tests/ideology/ideology_tag_snapshot_stress_test.gd` | 修为显式 6 国 + 唯一 handle 守卫，仍 **38 / 0** |
| `tools/ideology/verify_delivery.py` | 三个新夹具进期望表（39 / 31 / 177）|

## 7. 未完成

- **B3（512 国续跑）**：子 Agent 仍在跑。
- **§11.7 其余 6 个时点**：本次只做了时点 1。夹具里可复用的两块是 `_new_world()`（确定性 64 格世界 + 散落 42 格领土）与 `_capture_state()` / `_compare()`（逐格 presence/add/value + 业务哈希 + 安装次数 + 一次性计数 + 已提交审计）。时点 2（epoch 在飞）需要在 `run_economy_slice` 的**循环中间**存档。
- **升级传播未被覆盖**：`ADD_UNDERSTANDING` 只**发起**跨域事务，而该事务在没有 dispatch/ack 时永不结算（同上 5.1）。所以本次证明的是「从恢复状态重建等价」，**不是变更传播**。
- **§14.3 在两个规模上都超标**：64 国 × 12 卡单步 **2.572 ms**；超大国家 kind 14/15 **≈2.19 ms**（后者结构性原因已修但缺实测）。
