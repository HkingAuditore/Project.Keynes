# Phase C.4：Total-CPP 顶层验收

> plan：`docs/plans/dots-total-cpp/`（plan_create artifact）
> 入口：`main.start_soak_ab_phase_c4_acceptance_debug()`
> 涵盖：A.2 mega-tick / B.1 front_pool / B.3 SIMD 三 flag / C.1 system_schedule / C.3 thread fallback

## 总体目标

| 指标 | 现状（基线） | C.4 目标 |
|---|---|---|
| fast_ms p95 | 9 ms | **≤ 1.5 ms** |
| sus_sim p95 | 10 ms | **≤ 2 ms** |
| sus_sim max | 193 ms | **< 30 ms** |
| fronts_12 单帧 | 1.6-2.5 ms | **< 0.2 ms** |
| season_refresh 尖峰 | 50-190 ms | **< 30 ms** |

每项必须满足：1000-tick A/B diff epsilon 1e-5、72h soak 无 crash/NaN/atlas 错位。

## 串行批跑矩阵

`start_soak_ab_phase_c4_acceptance_debug` 内部按以下顺序串行启动 4 个 batch；
任一 batch 失败不阻塞后续 batch 启动。

| # | batch | flag A | flag B | 30-tick + 1000-tick | 验收门槛 |
|---|---|---|---|---|---|
| 1 | unified_fast_tick | `use_gdext_unified_fast_tick=false` | `=true` | 是 | fronts 字段 epsilon ≤ 1e-5；fast_ms 不退化 > 2% |
| 2 | system_schedule | `use_gdext_system_schedule=false` | `=true` | 是 | breakdown 全 ms 字段 epsilon ≤ 1e-5；succession 完全相等 |
| 3 | thread | `use_gdext_thread_fallback=false` | `=true` | 是 | breakdown 全 ms 字段 epsilon ≤ 1e-5；succession 完全相等；sea_ice/veg_dyn/pass_b ms 不退化 |
| 4 | season_round | `use_gdext_season_round=false` | `=true` | 是 | season stage 1-12 各自 ms 字段 epsilon ≤ 1e-5；fast_ms p95 ↓ |

总耗时 ≈ 4 batch × 2 profiles(A/B) × (30 + 1000) tick = **8240 sim-tick**；
按 x20 速度 ≈ **800 s** 实墙时（建议离开 ~15 min 自动跑完）。

## 跑法

1. 启动游戏（建议 release build；debug 也可，但 elapsed_ms 不可作绝对参考）
2. 等首屏世界生成完成（fast tick 已稳定）
3. 速度档调到 **x20**
4. Console / Debug Console 调用 `start_soak_ab_phase_c4_acceptance_debug()`
5. 等到日志出现 `[main] === Phase C.4 acceptance: all batches complete ===`
6. 最新 batch 报告位于 `user://soak/last_report.txt`；全链路历史追加在 `user://soak/report_history.txt`

中途取消：按 `Alt+F3` 或调用 `cancel_soak_debug()` 会立刻 cancel 当前 A/B runner，
并清空 `_c4_acceptance_queue` / 断开链式 `completed` 监听。

## 顶层 perf verdict

跑完 C.4 后，调用 `request_dots_final_push_perf_verdict()` 拿到 fast_ms / sus_sim
的 p50/p95/max 三档，与上表的 C.4 目标对照。任一项未达 → 列入回归列表，**不
要直接关 flag**：先通过 single-batch（如 thread 单独 off）二分定位是哪一段引入
退化。

## 已知不在本期范围

- **C.2 SoA chunk 重组**：已 cancel，等 C.4 验收后若 fast_ms p95 仍 > 1.5 ms 再重启
- **B.4 enum_atlas pack GDScript fallback 退役**：必须 72h soak 0 触发后才能下手；
  本期完成 acceptance 后开 72h soak 计时

## 实测数据（待填）

### 30-tick 烟测汇总

| batch | A p50 fast_ms | B p50 fast_ms | 任一 ms 字段 max diff | 判定 |
|---|---|---|---|---|
| unified_fast_tick | TBD | TBD | TBD | TBD |
| system_schedule | TBD | TBD | TBD | TBD |
| thread | TBD | TBD | TBD | TBD |
| season_round | TBD | TBD | TBD | TBD |

### 1000-tick 验收汇总（release build）

| batch | A p50 fast_ms | B p50 fast_ms | A p95 fast_ms | B p95 fast_ms | sus_sim max | 判定 |
|---|---|---|---|---|---|---|
| unified_fast_tick | TBD | TBD | TBD | TBD | TBD | TBD |
| system_schedule | TBD | TBD | TBD | TBD | TBD | TBD |
| thread | TBD | TBD | TBD | TBD | TBD | TBD |
| season_round | TBD | TBD | TBD | TBD | TBD | TBD |

### 顶层 perf verdict（全 flag B 状态，即所有 use_gdext_* = true）

| 指标 | 实测 | 目标 | 判定 |
|---|---|---|---|
| fast_ms p50 | TBD | < 1.0 ms | TBD |
| fast_ms p95 | TBD | ≤ 1.5 ms | TBD |
| sus_sim p50 | TBD | < 1.5 ms | TBD |
| sus_sim p95 | TBD | ≤ 2 ms | TBD |
| sus_sim max | TBD | < 30 ms | TBD |
| fronts_12 单帧 | TBD | < 0.2 ms | TBD |
| season_refresh 尖峰 | TBD | < 30 ms | TBD |

## 状态

- [x] C.3 job graph + thread batch + main.gd 顶层入口
- [x] 文档骨架：phase-c-job-graph.md + phase-c4-acceptance.md
- [ ] 30-tick 烟测（填本文档实测数据）
- [ ] 1000-tick 验收（填本文档实测数据）
- [ ] 72h soak 启动 → 通过后 enum_atlas pack 退役（B.4）
