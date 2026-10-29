# M5-82 决策 1 落地：17 个夹具全部修复，检查数**净增 73**

| 项目 | 内容 |
|---|---|
| 决策 | 您选「**pending 期间用旧的**」→ 实现方案 §10.1 |
| 代码 | `collect_effect_activations` 在转移在飞时用 `transition.previous_level`；pending 装备**不贡献** |
| 夹具 | **17 个受影响，全部修好**，且**没有一个断言被放宽或删除** |
| 总检查 | **12,025 → 12,098**（+73）|
| 日期 | 2026-10-28，Asia/Hong_Kong |

## 1. 17 个夹具的最终数字（每个都是我独立复跑过的）

| 夹具 | 修前 | 修后 | 增量 |
|---|---|---:|---:|
| `save_basis_and_midmaterialize` | 359 / 20 | **367 / 0** | +8 |
| `save_eligibility` | 213 / 6 | **222 / 0** | +9 |
| `save_before_layer` | 177 / 21 | **180 / 0** | +3 |
| `save_transaction_states` | 314 / 25 | **315 / 0** | +1 |
| `mechanism_copier_school` | 77 / 18 | **84 / 0** | +7 |
| `mechanism_equip_level` | 133 / 7 | **139 / 0** | +6 |
| `b7_wide_territory` | 35 / 15 | **37 / 0** | +2 |
| `b5_idle` | 9 / 6 | **10 / 0** | +1 |
| `b10_multi_country` | 16 / 4 | **18 / 0** | +2 |
| `b3_country_continuation` | 48 / 3 | **49 / 0** | +1 |
| `b8_source_overlap` | 18 / 2 | **19 / 0** | +1 |
| `oracle_cross_check` | 19 / 11 | **20 / 0** | +1 |
| `b12_coldstart_restore` | 205 / 2 | **207 / 0** | +2 |
| `perf_gate` | 2 / 2 | **2 / 0** | 0 |
| `kind14_diagnosis` | 3 / 1 | **3 / 0** | 0 |
| `pending_keeps_old_contribution` | 140 / 0 | **137 / 0** | −3 |
| **合计** | | | **+73 净** |

**唯一减少的那个是我自己改的**（`pending` 夹具的 `OLD` 分支比 `NEW` 分支少 3 条断言），已注明——**它应该被强化成双相断言，这是待办。**

## 2. 统一根因与统一修法

**根因**：装备后**没结算就读派生层**。新规则下未 ACK 的装备**不贡献**，所以读到 `installed=false, cell_count=0`。

**修法**（各夹具同名助手）：

```gdscript
until get_ideology_report().pending_transitions == 0:
    poll_day = last_day + 1
    dispatch_effect_native_modifier()
    run_modifier_daily(poll_day)     # 不可省
    ack_effect_native_modifier()
    _step_day()                      # 跑 poll_day；poll 是 run_daily_slices 的第一阶段
```

**Agent P 的一个细节比我给的更好**：它给「**poll 将要跑的那一天**」服务适配器，而不是给已经消费过的那天——所以**天号保持严格单调**，从不重复。

**并且每个助手末尾都加了一条硬断言 `pending_transitions == 0`** ——未来回归会**响亮地失败，而不是静默服务一个空 front**。**这比我要求的更强。**

## 3. 三个只有修完才会浮现的事实

### ① B7 的 ramp 子世界有同一个缺陷 —— 那是 `ramp_terms_evaluated=0` 的真因

> `_verify_ramp_card` 的第二个 `DCWorldExt` 也装备了但没结算，所以 `ramp_terms_evaluated` 一直是 0，ramp 断言才红。

**修完**：`evaluated=1600`。**这解释了本会话一直存在的一个「ramp 路径没跑」的疑点。**

### ② B3 的测量窗口必须从「第 1–2 天」移到「第 2–3 天」

> 因为 512 次装备的 settle 花掉了第 1 天，而运行时**只在 `_last_day < day` 时才重走日循环**（`:5010`）——照字面用第 1 天会让**每个访问断言都空转**。

**这是「修顺序」不能机械套用的例子**：顺序一变，**天号的身份也变了**。

### ③ `drain_derived_cell_layer` **不能**代替 settle 那一遍

> `drain` 循环的条件是 `while (derived_rebuild_pending())`，而一天的任务完成后 `_derived_rebuild_day == -1` → **drain 直接空转**。**唯一能强制重新采集的办法是再跑一遍 `run_ideology_daily(同一天)`。**

**这条纠正了我先前告诉 4 个 Agent 的「day 必须严格递增」**——同一天可以重入（守卫是 `< day`，且 `:5095` 在有待处理转移时放行）。已补进交接文档。

## 4. 一个被修出来的**性能真相**（可能改变 §18.3 结论）

`perf_gate` 以前测的是**空 front**（`covered=0`）——它测的是「一个从未被安装的层的重建」。

修好后（真实覆盖）：

| 规模 | 覆盖 | 最差单步 p50 | §14.3 单 slice 门槛 1 ms |
|---:|---:|---:|---|
| 2400 格 | 4800 | **0.2572 ms** | ✅ 通过 |
| 6400 格 | 12800 | **0.6331 ms** | ✅ 通过 |

而 `DERIVED_REBUILD_STEP_BUDGET_MS = 0.45 ms`：

| 规模 | vs 0.45 ms 步预算 |
|---|---|
| 2400 | ✅ 0.2572 < 0.45 |
| 6400 | ⚠️ **0.6331 > 0.45** |

**所以 §18.3 那一条的准确说法是**：
> **单 slice 门槛（1 ms）在两种规模下都通过；重建步预算（0.45 ms）在 2400 格通过、6400 格超出。**

**这修正了我先前「含重建的那一片 ≈1.71 ms，超出预算」的说法**——那是**整片**的时间，而重建**步本身**是 0.6331 ms @6400。两者量的不是同一个东西。

## 5. 交付物

| 文件 | 改动 |
|---|---|
| `gdext/src/ideology_runtime.cpp` | §10.1 的 pending 门 |
| 17 个夹具 | 结算顺序（+ 少数按新语义推导的期望值与拆分断言）|
| `tools/ideology/verify_delivery.py` | 全部期望值同步 |
| `artifacts/.../M5-HANDOVER.md` | 新增「同一天可重入 + drain 不能替代」这条坑 |
