# Master 基线 — 2026-05-15 03:10:34

Block A 启动前的原点快照。后续每 PR 的 SAME_SOURCE 报告以此为对照。

## 运行环境

- **commit**: `560b6f2d4ce4248b9032b165f939125cbe63358a`
- **branch**: `master`
- **dylib mtime**: `May 15 02:55:40 2026`（最新增量编译产物）
- **Godot**: 4.6.2 stable
- **macOS**: 15.4.1（Apple Silicon arm64）
- **mode**: SAME_SOURCE，n_ticks=30，dc_on / dc_on
- **耗时**: 10.79s（A 5.4s + B 5.4s 估算）

## Verdict

**FAIL**（scalar 阈值超标，但其中包含 hash 假阳性）

| 指标 | 值 | 阈值 | 解读 |
|---|---|---|---|
| paired entries | 1496 | — | — |
| unpaired A / B | 308 / 264 | — | 第一/最后几 tick 字段在 A/B 不对齐，正常 |
| **scalar max** | **3.32e9** @ `world.sea_ice_fraction_buffer_hash` | 0.05 | 🔴 假阳性，hash 字段本身离散 |
| **long-term max** | **0.0** @ — | 0.01 | ✅ EMA 字段（temp_30d/365d/anomaly）完美 |
| skipped fields | 8 | — | hash 字段未被包含在 skip 列表，是 SoakABRunner 自身 bug |

## Top-15 漂移字段分类

### 类 1：假阳性（应 skip 而未 skip）

```
*** world.sea_ice_fraction_buffer_hash    3.32e9    （hash 离散值，应排除）
*** cell.climate_dirty_mask               1.000     （dirty mask 在两次跑之间不必一致）
```

→ 这两个字段拉爆了 verdict，但**不是 storage bug**。后续 PR 验收时如果**只剩这两个超阈**，可视作 PASS（或扩展 SoakAB skip 列表）。

### 类 2：CoW 漏写 / 双写裂缝（Block A 要消除的目标）

| 字段 | mean_diff | 关联 PR |
|---|---|---|
| `cell.cover` | 0.133 | PR-2.1.6（weather_system 反馈） |
| `cell.weather_type` | 0.099 | PR-2.1.6 |
| `cell.vegetation` | 0.097 | PR-2.1.2（climate Pass-B） |
| `cell.snow_cover` | 0.082 | PR-2.1.1（climate Pass-A） |
| `cell.moisture` | 0.040 | PR-2.1.2 |
| `cell.sea_ice_frac` | 0.029 | PR-2.1.4 |
| `cell.temp` | 0.021 | PR-2.1.1 |
| `cell.weather_instability` | 0.018 | PR-2.1.6 |
| `cell.weather_intensity` | 0.012 | PR-2.1.6 |
| `cell.weather_precip` | 0.011 | PR-2.1.6 |
| `cell.weather_vapor` | 0.011 | PR-2.1.6 |
| `cell.weather_cloud` | 0.0095 | PR-2.1.6 |

→ 这 12 个字段就是 Block A 要从 0.04 ~ 0.13 收敛到 < 1e-3 的目标。每个 PR 完成后，对应字段应**显著下降或归零**。

### 类 3：长期均值（最严红线 ≤ 0.005）

`temp_30d` / `temp_365d` / `temp_anomaly` 当前 **0.0**（已 PASS），PR-2.1.1 改造后必须维持 ≤ 0.005。

## 后续每 PR 的对照基线

每个 PR 的 `before-impl.txt` 应当与此报告**完全一致**（scalar / long-term / Top-15）。如果 before 已经偏离，先修偏离原因再继续。

PR 完成后的 `after-impl.txt` 关注：
- 该 PR 目标字段的 mean_diff 是否下降到 < 1e-3
- 其他字段是否被意外影响（如 PR-2.1.1 改 temp 影响到 weather）
- long-term 必须保持 ≤ 0.005（PR-2.1.1 之后这条最关键）

## 文件清单

- `same-source-30tick.txt` — 完整 SoakAB 报告
- `same_A_30tick.tsv` — phase A 原始 dump（137 KB / 30 tick × 字段）
- `same_B_30tick.tsv` — phase B 原始 dump（128 KB）

> 两份 TSV 大小不一致是因为 unpaired entries 略有差异（A=308 / B=264），属于 dump 时序常态。
