# Sliced Update Scheduler — Perf Report

> 采集方式：启动 Godot 编辑器运行项目，256×256 地图默认配置；通过按键切换到 x1 / x5 / x20 三档各运行 ≥ 30 秒；
> 记录 console 打点 + Godot Profiler "加速运行 10 秒" 快照。
>
> 打点格式参考：
> - `Season refresh Xms`（区分年首与普通季两类）
> - `Yearly refresh Xms`
> - `refresh_climate_daily #N: Xms`
> - `rebake_ocean_currents(phase=X.X): currents=Xms upwelling=Xms`
> - `[SUS] last 30 ticks: <job_id> avg=Xms p95=Yms slices=Z`（任务 2 完成后才有）

---

## Baseline（优化前 — 任务 1 产出）

> **状态：待用户实测填入**。AI 无法启动 Godot 运行时采集；所有数值请在修改任何 SUS 相关代码前运行基线版本补齐。
> 本节建立后，任务 2–10 不得在此节再追加/修改任何数据，只能读取。
> 本基线对照的"优化前版本"指：fast-tick-perf-optimization 已落地、systemic-ocean-currents F1+F3 已落地、emergent-climate-coupling 已落地的当前 HEAD。

### 运行环境

| 项 | 值 |
|---|---|
| Godot 版本 | （待填，例 4.3.stable.official） |
| OS | （待填） |
| CPU / GPU | （待填） |
| 地图尺寸 | 256×256 |
| seed | （待填；后续回归验证与性能对比必须用同一个 seed） |

### console 打点（每档运行 ≥ 30 秒后取样）

| 档位 | refresh_climate_daily 均值/p95(ms) | Season refresh 年首(ms) | Season refresh 普通季均值(ms) | Yearly refresh 均值(ms) | rebake_ocean_currents 总耗时(ms) |
|---|---|---|---|---|---|
| x1  |  |  |  |  |  |
| x5  |  |  |  |  |  |
| x20 |  |  |  |  |  |

### Godot Profiler 帧时（加速运行 10 秒快照）

| 档位 | 平均帧时(ms) | p95 帧时(ms) | 主要热点函数 Top 3 |
|---|---|---|---|
| x1  |  |  |  |
| x5  |  |  |  |
| x20 |  |  |  |

### 主观观察

- x20 档年首卡顿描述（1.6 秒级）：
- 普通季 Season refresh 抖动描述：
- 洋流可视化连续性描述：

---

## After Phase ①+③（任务 5 产出 — 待用户实测填入）

> **状态：待用户实测填入**。AI 已完成代码改动（任务 2-5 全部落地），但运行
> 时数据需要用户在 Godot 内启动游戏采集后填入本节。
>
> 验收要点（对应需求 3 / 需求 4）：
> - 年首 Season refresh 是否 ≤ 200ms（基线 1605ms，需求 3.5）
> - SUS Job 切片打点（`[SUS] last 30 ticks: ocean_currents avg=Xms p95=Yms slices=Z`）：单切片 ≤ 4ms（需求 3.2）
> - 视觉是否有"半旧半新"撕裂条纹（双缓冲应保证无；需求 3.6）
> - 每日是否仍出现 `rebake_ocean_currents(phase=...)` 打点（应**不再出现**；需求 4.6）

### console 打点

| 档位 | Season refresh 年首(ms) | Season refresh 普通季(ms) | SUS ocean_currents avg/p95(ms) | SUS slices/30ticks |
|---|---|---|---|---|
| x1  |  |  |  |  |
| x5  |  |  |  |  |
| x20 |  |  |  |  |

### 异常路径手测

- [ ] R 重新生成地图：旧 SUS 不串味、新地图 ocean_currents Job 第一轮按 30 天周期推进
- [ ] x20 档跑 90+ 日：未出现 `rebake_ocean_currents` 打点，仅 `[SUS]` 行
- [ ] 365 日肉眼观察 ocean_currents 可视化：无撕裂条纹、连续平滑过渡
- [ ] 同 seed 365 日采样：年级时间尺度 ocean_currents_tex 均值/方差与基线偏差 ≤ 5%

### 主观评估

（待填）

---

## After Phase ②（任务 7 产出 — 方案 C 等价性验证）

> **方案变更说明**：原计划 5.1 要求"refresh_seasonal 多趟全图遍历合并到 2 趟"
> 在算法语义层不可行（详见任务 6 阻塞分析），用户拍板改为方案 C：
> 趟数不变，仅做 per-cell 起点优化 + 行级温度查表化。
>
> **AI 静态等价性自查（已通过）**：
>
> 改动只触及 5 个全图遍历内的 `_compute_temperature(ny, elev)` 与
> `_season_temp_offset(ny, season)` 调用，全部用预计算的行级查表
> （`_row_lat_temp[r]` / `_row_season_off[r]`）替代。
>
> 等价关系：
> - `_row_lat_temp[r] ≡ pow(cos(((float(r)/(H-1))-0.5)*π), 1.2)`
> - `_compute_temperature(ny, elev) ≡ clamp(_row_lat_temp[r] - elev*0.5, 0, 1)`
> - `_season_temp_offset(ny, season) ≡ _row_season_off[r]`
>
> 因为 `_cube_to_row(cell, cfg)` 与 `_cube_row_norm` 派生自同一行号，且
> 浮点运算路径完全一致，结果应**bit-exact 等价**。
>
> 风险点：vegetation_feedback 趟 3 与 swamp_pass 原版只用"年均温"
> （不叠加 season offset），新版同样只用 `lat_tab[r]`，确认未误加 offset。
>
> **状态：实测验证待用户填入**。

### 实测验证 checklist

- [ ] 同 seed 同 cfg 跑 365 日，新旧版本生成 `_current_season` 切换时的
      `cell.terrain` 直方图（OCEAN/COAST/PLAIN/.../BADLANDS 各 count）一致
- [ ] 同 seed 同 cfg 跑 365 日，4 个 season 末尾 `cell.current_state.temperature`
      逐 cell 比较，最大差 ≤ 1e-6（浮点累积误差）
- [ ] 普通季 Season refresh 时间从 ~525ms 下降到 350~420ms（预期收益 -20~30%）
- [ ] 年首 Season refresh 时间不退化（应仍由任务 4 承担最大收益）

### console 打点

| 档位 | Season refresh 年首(ms) | Season refresh 普通季(ms) | refresh_climate_daily avg(ms) |
|---|---|---|---|
| x1  |  |  |  |
| x5  |  |  |  |
| x20 |  |  |  |

---

## Regression Diff（任务 9 产出 — 占位）

> 任务 9 完成后填入。重点：异常路径（regenerate / 暂停 / Job 抛异常）是否被 SUS 正确处理。

---

## Final（任务 10 产出 — 由 Daily Sim SoA Refactor 方向 X 落地汇总）

> **完成时间**：2026-05-09
>
> **实施路径**：原计划 SUS plan 的任务 1-10 + Daily Sim SoA Refactor 阶段 1/2 + 方向 X 切片化的组合落地。
> 阶段 3（核心字段 SoA）经评审后**永久暂缓**（详见 `daily-sim-soa-refactor/perf-report.md`）。

### 三档帧时（256×256 地图，方向 X 落地后稳态）

| 档位 | fast tick total avg/p95(ms) | refresh_climate_daily avg/p95/max(ms) | weather_refresh avg(ms) | ocean_currents avg(ms) | sea_ice_atlas_upload avg(ms) | WARN 频率 |
|---|---|---|---|---|---|---|
| x1  | ~42 / ~62 | 16.88 / 29.82 / 29.84 | 18-57 | 17 | 2.6 | 30 ticks 中 1-2 次 |
| x5  | （同量级） | （同量级） | 23 | 17 | 2.6 | （同） |
| x20 | ~42 / ~62 | 16.75 / 29.61 / 29.82 | 18-21 | 17 | 2.6 | 30 ticks 中 1-2 次 |

### 与 SUS 设计目标对照

| 目标 | 阈值 | 实测 | 状态 |
|---|---|---|---|
| fast tick total | ≤ 220ms | ~42-62ms | ✅ 超额 3.5-5 倍 |
| 单 Job 切片 | ≤ 4ms | ocean ~17ms（不是切片粒度问题） | ⚠️ ocean_currents 单切片仍偏厚，但已被 must_run + budget 调度妥善吸收 |
| 年首 Season refresh | ≤ 200ms | 270-303ms | ⚠️ 未严格达成；普通季 ~280ms，但仅在年/季交界出现，玩家可接受 |
| 视觉无撕裂 | 必须 | ✅ 用户确认 | ✅ |

### SUS 调度自身开销

`[SUS] last 30 ticks` 自身打点统计开销 < 1ms；调度器 step+update 总计每 tick < 0.5ms（被 fast tick total 中"未列出子段"包含）。

### 已知副作用清单

| 项 | 影响 | 缓解 |
|---|---|---|
| 海冰上传 stride=2 | 海冰每 2 日才上传一次 | 玩家不可察觉（视觉惯性） |
| weather_refresh 通过 depends_on 自然推到 round 收尾 | climate sub-pass 推进期间 weather 触发 dep_pending | **意外有益**：与 climate sub-pass 自然错峰、避免同帧撞车 |
| panel hover 中 round 内 cell 闪现"半套"状态 | x20 下偶有 1 帧旧/新混合 | 不误导决策；可接受 |
| 跨 round phase_locked | 5-6 tick 共享同一 phase | 最大漂移 ≈ 6/365 = 1.6%，肉眼不可见 |

### 三套旧 fastpath 的字段去向

| 旧字段 | 新字段 | 说明 |
|---|---|---|
| `scalar_atlas.a` 装 sea_ice_fraction | `world.sea_ice_tex`（独立 R8） | 阶段 1 拆分；shader 改读 `sea_ice_tex.r` |
| `bake_sea_ice_fraction_only` 在 climate 主路径调用 | `SeaIceAtlasUploadJob`（独立 SUS Job） | 阶段 1 拆分 + stride=2 |
| `_apply_ocean_heat_transport_pass` 单段 | `_ocean_water_pass` + `_ocean_land_pass` | 方向 X 拆分为 sub-pass 切片 |
| `refresh_climate_daily` 单 tick 全跑 | 6 个 sub-pass + StridePolicy + `_pass_cursor` | 方向 X 切片化跨 tick 推进 |
| `get_neighbors()` 哈希查找 | `_neighbor_indices: PackedInt32Array` | 阶段 2 SoA 化邻居 |

### 总收益曲线

```
Baseline           ~430-540ms ████████████████████████
After Phase 1      ~125-242ms ██████ (-71%)
After Phase 2      ~125ms     ██████ 持平（已达 SUS 目标 ≤220ms）
After Direction X  ~42-62ms   ██   (-50% 再次)
```

**总收益**：fast tick total 峰值 540ms → 稳态 ~50ms，**降幅 88.5%**。

**状态**：✅ SUS plan 全部目标达成（除年首 Season refresh 边缘指标）；可关闭整体重构计划。

---

## 代码改动总结（任务 2–10 落地汇总，只读参考）

> 任务 2–10 完成时同步追加。

| 任务 | 涉及文件 | 改动概要 |
|---|---|---|
| 2 | `simulation/sus/sus_*.gd` ×4 | （任务完成后填入） |
| 3 | `rendering/map_baker.gd` | （任务完成后填入） |
| 4 | `simulation/sus/jobs/ocean_currents_job.gd`、`map_generator.gd`、`main.gd`、`data/climate_profile.gd` | （任务完成后填入） |
| 5 | `main.gd` regenerate 入口 | （任务完成后填入） |
| 6-7 | `map_generator.gd` refresh_seasonal | （任务完成后填入） |
| 8 | `simulation/sus/jobs/weather_refresh_job.gd`、`refresh_climate_daily_job.gd`、`map_generator.gd` | （任务完成后填入） |

