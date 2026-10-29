# M0-8 eligibility day & epoch adoption semantics — findings

| 项目 | 内容 |
|---|---|
| 里程碑 | [M0](../22-cell-program-cap-removal-plan-v3.md) |
| 任务 | §15.2 M0 task 8 / §9.3 |
| 日期 | 2026-10-26，Asia/Hong_Kong |
| 结论 | §9.3 的 `eligible_from_day` 语义**可实施**，且能落在现有 ACK 状态机上；**但方案对「已确认」的定义与现有代码不一致，需先统一口径** |

## 1. 现有 ACK 状态机的真实语义

`NativeIdeologyRuntime::poll_pending_transition`（`ideology_runtime.cpp:3270-3353`）是唯一的转换结算点：

```
[3282-3291]  遍历 transition.transaction_ids，读 transaction_status_pod
             - 全部 ACKED 且至少一条非 ACKED  → pending=true, 继续等
             - 任一 REJECTED / RESYNC_REQUIRED / 0 → failed=true
[3292]       if (pending && !failed) return true;      ← 还不到结算点
[3293-3320]  failed 分支：回滚 level / entered_levels / generation / location /
             slot_index / binding_*，重新 sync_external_binding，mark dirty
[3321-3339]  成功分支：entered_levels |= entered_on_success，retire 旧 binding，
             必要时清 binding，mark dirty
[3340-3342]  pending_transition_count--；state.transition = {}
[3343-3351]  仅成功时调 reconcile_effect_activations(country, state, day, ...)
```

**关键事实：结算发生在 `day` 这个形参上**，而这个 `day` 由调用 `poll_pending_transition` 的那次日程推进传入——即**结算日 = ACK 被观察到的那一天**，不是请求日。

这与方案 §9.3 的定义「该确认投影的 `eligible_from_day = D+1`」兼容：只要把 `poll_pending_transition` 观察到全 ACK 的那一天记为 D。

## 2. 方案 §9.3 可直接实施的部分

```text
设结构变化在业务日 D 收到所需真实 ACK 并确认
  → eligible_from_day = D+1
  → 在 sample_day=S 的新经济冻结边界，只能选 eligible_from_day <= S 的最新已确认投影
```

推导用的两个量都能从现有状态取：

| 量 | 来源 | 状态 |
|---|---|---|
| `D`（确认日） | `poll_pending_transition(ref, day)` 的 `day` 形参，在 `[3322-3338]` 成功分支里可见 | 需新增一行写入 `confirmed_day` |
| 每次冻结的 `S` | `start_epoch(day_index)` 的 `day_index`（`economy_runtime_epoch.cpp:816`） | 已有 |
| 「最新已确认投影」 | 需要按 `(revision, eligible_from_day)` 选出的是新概念 | 需新增 |

**所以 §9.3 的语义本身不需要改造现有代码，只需要在 `[3339]` 之后加一次「发布已确认投影」的调用。** 这是 M2 的最小改动面。

## 3. 与现有代码不一致的一处：「已确认」的定义

方案 §10.1 说：

> 拟新增的 `ConfirmedCountryProgramBasis` 表示已经确认、可用于后续冻结的执行基础。它不等同于 UI 上的意图状态。

但现有代码里，**「已确认」就是「Effect 事务全 ACKED」**（`[3284]`）。问题在于：ACK 的对象是**Effect/Modifier 事务**，而派生层需要的是**理念侧的 program 集合**。这两者当前只有下面这条间接联系：

```
[3343-3351]  成功 → reconcile_effect_activations(country, state, day, ...)
                        ↓
            收集该 country/state 当前的 program 列表并提交 Effect 实例
```

也就是说：**「program 集合」在 ACK 成功之后才被重建，且重建结果没有独立身份。** `reconcile_effect_activations` 返回 bool，不返回集合摘要。

方案要求 `ConfirmedCountryProgramBasis` 能带 `confirmed_revision` / `confirmed_digest`（§7.1），这意味着 M2 必须：

1. 在 `[3339]` 之后计算一次 program 集合的摘要；
2. 把 `(summary, confirmed_day=D)` 发布成一个不可变对象；
3. 让派生层按 `eligible_from_day = D+1` 选择。

**这三步都是净新增，且必须落在 `poll_pending_transition` 的成功分支里**——放在别处会与 ACK 竞争。

## 4. 一个时间线样例（可直接当黄金用例）

复用 §9.3 的例子，落到具体调用：

| 业务日 | 发生什么 | 派生层状态 |
|---|---|---|
| D=10 | `poll_pending_transition(ref, 10)` 观察到全 ACKED → 成功分支 → 发布 basis{rev=N, confirmed_day=10} | 未采纳（`eligible_from_day=11 > 10`） |
| 11 | 若 11 是冻结边界：`start_epoch(11)` → 选 `eligible_from_day<=11` 的最新 → basis{rev=N} | **采纳**，`layer_generation++` |
| 11 | 若 10–12 是当前冻结周期：11 不开启新 epoch | 不采纳 |
| 13 | 下一冻结边界 `start_epoch(13)` → 选 `eligible_from_day<=13` → basis{rev=N} | 采纳 |

方案 §9.3 说「若 10–12 是当前冻结周期、下一周期 sample_day=13，则旧周期保持原值，13 日采纳新值」——与上表一致。

**这个用例可以写成 GDScript 测试**：构造一个 5 天周期的经济配置，在第 10 天提交装卡，断言第 11/12 天派生层未变、第 13 天变化、且第 13 天的新值与「直接在第 13 天建层」逐位一致。这是 M2 的 `ideology_cell_layer_timing_test.gd`。

## 5. 待采纳投影的保留（§10.5）

方案 §10.5 要求：

> 不能只保留「最新到达投影」：D1、D3 两次确认后，sample_day=D3 可能需要 D1 的已具备资格版本，D3 版本要到下一天才具备资格。

场景：D=1 确认 rev=A（eligible 2），D=3 确认 rev=B（eligible 4）。在 sample_day=3 的冻结边界，应选 A 而不是 B。

**这要求保留一个「已确认但未到期」的小队列**，而不是单个 `latest`。队列长度上界 = 「确认后到下一个冻结边界之间最多能确认几次」。因为 `eligible_from_day = D+1` 而冻结边界最长 5 天（`MARKET_CYCLE_MAX_DAYS`），最坏情况是 5 个待采纳版本。

**建议 M2 用一个环形缓冲容量 8（5 + 余量）**，并在 §12.4 增加计数器 `pending_basis_count`（方案已有 `entries`，但语义不同）。

## 6. 需要用户/方案决策的一项（D1）

§9.5 把「MATERIALIZE 跨帧续跑」与「释放边界锁」并列为可选。M0-3 §3 已确认 `start_epoch` 不可续跑。

**这仍然是一个未决决策**，我建议：

| 选项 | 改动面 | 风险 |
|---|---|---|
| **(a) 释放边界锁 + INSTALL 重校验**（推荐） | 复用 `try_lock_economy_input_capture` + request/complete 服务；`INSTALL` 时验证 `expected_basis` | 中：需保证 MATERIALIZE 持有不可变输入副本 |
| (b) 把 `start_epoch` 状态机化 | 在 `economy_runtime_epoch.cpp:816` 内引入 stage 字段；`clear_epoch_metrics()`（`894`）要保证不重复清空 | 高：污染已被 30+ cost 埋点覆盖的最热路径 |

**在用户确认前，M1 只做 (a) 相关的接口，不碰 `start_epoch` 内部结构。** 这样即使最终选 (b)，(a) 的 `expected_basis` 校验也是共同的。

## 7. 提交 M2 的四条时序约束

1. **发布点必须在 `poll_pending_transition` 的 `[3339]` 之后**，与 ACK 同一次调用内完成，否则产生「已 ACK 但无 basis」的窗口。
2. **`eligible_from_day = confirmed_day + 1`**，不是 `>= confirmed_day`。方案 §9.3 明确。
3. **待采纳队列容量 ≥ 5**（最长冻结周期），否则 §10.5 的 D1/D3 场景会丢版本。
4. **采纳只发生在 `start_epoch` 内部**，且必须在 `capture_country_epoch` 的因子捕获（`economy_runtime.cpp:5530`）之前——见 M0-3 §8 第 1 条。

## 8. 局限

- **未实现任何代码**，也**未运行**时序测试。上面的用例是设计，不是验证结果。
- 未核对 `poll_pending_transition` 在 worker 权威下的调用时机——`RuntimeIdeologyPodAuthority` 有自己的 `apply_ack`（`runtime_ideology_pod.h:737`），语义可能与主线程版本不同。**这是 M2 必须补的一项审计**，本报告只覆盖了主线程路径。
- 未评估「确认投影摘要」的计算成本。若它需要重算全部 program，会与 `reconcile_effect_activations` 重复；M2 应在 reconcile 内部顺带产出摘要，而不是独立再算一遍。
