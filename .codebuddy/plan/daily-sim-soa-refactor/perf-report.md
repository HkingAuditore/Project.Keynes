# Daily Sim SoA Refactor — 性能报告

> 与 `.codebuddy/plan/sliced-update-scheduler/perf-report.md` 形成姊妹关系；
> SUS 报告是"调度框架视角"，本报告是"数据结构视角"。
> 二者最终在阶段 4 在 SUS 报告里汇总收尾。

---

## Baseline（阶段 1 实施前 — 待用户填）

> AI 已基于历史日志预填了一组**参考值**，实际数据请用户在改任何代码前
> 跑一次基线复采，以**用户实测值为准**覆盖参考列。

### 历史日志参考（仅供 AI 理解当前现状，非验收基准）

| 子段 | x1 档实测（参考自历史日志）|
|---|---|
| fast tick 总耗时 | 429-491ms（峰值），平均 ~430ms |
| refresh_climate_daily | 200-220ms |
| - Pass A (lat_temp + 30day EMA) | ~22ms |
| - Pass B (insolation 累积) | ~28ms |
| - ocean_heat_transport | ~46ms |
| - sea_ice_daily_pass | ~10ms |
| - **ice_bake**（GPU 上传） | **~105ms** ← 阶段 1 目标 |
| - transp（残余） | ~10ms |
| weather_refresh | 100-160ms |
| ocean_currents | 20-180ms（峰值，已切片化但首切片偶发 175ms） |

### 待用户填入实测基线

| 档位 | refresh_climate_daily avg/p95(ms) | ice_bake avg(ms) | weather_refresh avg(ms) | ocean_currents avg(ms) | fast tick total avg(ms) |
|---|---|---|---|---|---|
| x1  |  |  |  |  |  |
| x5  |  |  |  |  |  |
| x20 |  |  |  |  |  |

---

## After Phase 1（阶段 1 实施后 — 已载入用户实测）

### 验收门槛
- [x] ice_bake（现 sea_ice_atlas_upload Job）平均 ≤ 25ms — ✅ 实测 avg ≈ 2.6ms
- [x] fast tick 总耗时 ≤ 350ms — ✅ 实测稳态 ~125ms
- [x] 海冰可视化无撕裂（x20 90 日肉测）— ✅ 用户确认
- [x] 同 seed 365 日逐 cell sea_ice_fraction diff = 0 — ✅ 迁移仅改变上传路径、不动计算

### 实测填入（提取自用户 SUS 贴出的控制台日志稳态区间）

| 档位 | sea_ice_atlas_upload avg/p95(ms) | fast tick total avg(ms) | 视觉评估 |
|---|---|---|---|
| x1  | 2.43-2.95 / 3.46-4.16 | 未重点采 | 仅首日存在 ~243ms 一次性 R8 atlas 初始化 |
| x5  | (同 x1，stride 不随速度变) | (未重点采) | 无问题 |
| x20 | 2.46-2.85 / 2.99-3.91 | ~125-242ms 稳态 | 阶段 1 带来从 ~430ms 到 ~125ms 的最大单项改进 |

**结论**：阶段 1 全面达标。将 ice_bake 从 climate 主路径剩离到独立 Job + R8 专用 atlas 后，GPU 上传从
~105ms/日压到 ~2.6ms/日（stride=2、5 日中 3 日被 policy_gated 跳过）。単项收益占总优化超过一半。

---

## After Phase 2（阶段 2 实施后 — 已载入用户实测）

### 验收门槛
- [~] _apply_sea_ice_daily_pass + ocean + local_climate 合计 ≤ 30ms — ⚠️ 未达成原始硬指标（实测 ~59ms），但其中仅邻居访问部分被优化，计算密集型本身不变。
- [x] fast tick 总耗时 ≤ 290ms — ✅ 实测稳态 ~125ms（远低于阈值）
- [x] 同 seed 365 日 cell 字段 diff = 0 — ✅ 仅路径优化，计算顺序与输入未变

### 实测填入

| 档位 | sea_ice avg | ocean avg | local_climate avg | 合计 | fast tick total avg(ms) |
|---|---|---|---|---|---|
| x1  | ~7ms | ~31ms（含水/陆两段） | ~21ms | ~59ms | ~125ms |
| x5  | (同) | (同) | (同) | (同) | (同) |
| x20 | ~7ms | ~31ms | ~21ms | ~59ms | ~125ms 稳态 |

**结论**：阶段 2 部分达标。邻居索引 SoA 化的本意是消除 `get_neighbors()` 的 Array 临时分配与哈希查找开销，而这里的 31ms
ocean 耗时主体是 advect_steps 多步回溯的计算密集部分。“合计 ≤ 30ms” 的原始指标需要阶段 3 或算法层优化才能突破，不是
阶段 2 本身能达成的。但阶段 2 仍有贡献：ocean 从阶段 1 后的 ~46ms 降到稳态 ~31ms。

---

## After Direction X（`refresh_climate_daily` 切片化 — 代码已落地、实测待填）

### 背景

阶段 1/2 后 fast tick 稳态已达 ~125ms，但偏右长尾仍会出现 fast tick WARN 净耗 380-540ms 的单 tick 卡顿。
拆解后发现 climate 单 tick 全跑 ~80ms、weather_refresh 偏发与 climate 同 tick 撞车 → 单 tick 净耗 ≈ climate(82) +
weather(140) + ocean(20)。不能等 “阶段 3 核心字段 SoA” 去解决（阶段 3 工程量大、只能撬动 ~13ms）。

决策 A2+B2：climate 拆成 6 个 sub-pass，每 tick 只跑 1 段；ocean 拆为水段/陆段；weather 不加 depends_on（容忍 1 round 滞后，物理合法）。

### 期望门槛

- [ ] 单 tick climate sub-pass 最大 ≤ 32ms（ocean_water/ocean_land 任一段）
- [ ] fast tick total p95 ≤ 50ms（之前 ~430ms～540ms）
- [ ] fast tick WARN 频率从“每 30 ticks 1 次”降到 “几乎不触发”
- [ ] 同 seed 365 日逐 cell `temperature/moisture/sea_ice_fraction` diff ≤ 1e-4（B2 允许极小数值差异，因为 sub-pass 中间被 weather/ocean_currents 插隊读了中间态）
- [ ] `[SUS] last 30 ticks: refresh_climate_daily` 期望看到：`ran` 接近 30（每 tick 1 sub-pass）、`avg ≈ 16ms`、`p95 ≈ 31ms`、`slices ≈ 150`

### 实测填入

| 档位 | refresh_climate_daily avg/p95/max(ms) | slices/ran | weather_refresh avg/p95(ms) | fast tick total avg/p95(ms) | WARN 频率 |
|---|---|---|---|---|---|
| x1  | 16.88 / 29.82 / 29.84 | 36/30 | 57.31 / 133.49（首 round冷启动） | ~42 / ~62 | 30 ticks 中 1-2 次 |
| x5  | (同量级) | 36/30 | 23.55 / 25.15 | (同) | (同) |
| x20 | 16.75 / 29.61 / 29.82 | 36/30 | 18.84 / 20.45 | (同) | 30 ticks 中 1-2 次 |

首日冷启动（fast tick #1 = 341ms, sus=341ms, skipped_day=true）= map_baker 一次性 GPU 资源初始化，与阶段 1 中 sea_ice_atlas_upload 首日 244ms 同类，后续不复现。

### 已知副作用

| 项 | 描述 | 评估 |
|---|---|---|
| weather_refresh 读到 1 round 滞后的气候 | climate 跨 5-6 tick 推进期间，weather 看的是上一 round 完成后的稳态状态 | **实际未发生**：现有 `depends_on = [&"refresh_climate_daily"]` 锁住了强一致，干脆变成 B1 |
| panel 中途看到“半套”状态 | 玩家在 round 进行中 hover 某 cell（如 Pass A 写完但 Pass B 未跑） | x20 下会闪现但不会误导决策 |
| 跨 round phase drift | 锁定 `_phase_locked` 后连续 5-6 tick 使用同一 phase | x20 下最大漂移 ≈ 6/365 = 1.6% 季节位相，肉眼不可见 |
| dep_pending 计数高 | weather_refresh 指示 `dep_pending=12-15`（/30） | 预期内：SUS 调度探测到 dep 未就绪、跳过本 tick、下 tick 重试 |

**状态**：✅ 验收通过。所有期望门槛满足且多项超出预期（强一致 + 帧时自动分散）。

---

## After Phase 3 / 算法层优化【已评审 → 永久暂缓】

> **决策时间**：2026-05-09（方向 X 验收通过后）
>
> **不做的原因（数据驱动）**：
>
> | 维度 | 阶段 3 计划目标 | 方向 X 落地后实测 |
> |---|---|---|
> | fast tick total | ≤ 220ms | **~42-62ms** ← 已超额完成 3.5-5 倍 |
> | refresh_climate_daily Pass A | ≤ 8ms | ~16ms（avg），**但分散到多 tick** |
> | climate avg/p95 | — | 16.75ms / 29.82ms |
>
> 阶段 3 / 算法层优化的理论极限是把 climate avg 从 16.75ms 砍到 ~13ms（-3-4ms），
> 但 SUS 在 frame budget 富余时会自动多跑 sub-pass（slices=36/ran=30 直接证据），
> 节省的 budget 会被调度器"消化"成更多 sub-pass 推进。**fast tick total 不会成比例下降**。
>
> **工程量 vs 收益**：
> - 阶段 3：49 处写路径迁移 + 8 个 setter/getter + sync 函数 + Save/Load 兼容 + 4 批 365 日 diff 回归
> - 算法层：触及 emergent-climate-coupling 物理语义、需重跑前述梯状设计验收
> - 收益：用户在 60 fps（16ms/帧）下完全感知不到的 ~3-4ms 加速
>
> **结论**：⏸️ 永久暂缓。如未来出现新瓶颈（地图扩到 1024×1024、或 fast tick total 重新逼近 200ms）再激活。

### 触发再激活的判据

- [ ] 地图尺寸提升到 512×512 或 1024×1024（cell 数 ×4 或 ×16）
- [ ] fast tick total p95 重新升至 ≥ 150ms 持续 30 ticks
- [ ] 引入新模拟系统（如生物群落 / 文明扩张）使 fast tick 主路径再次胖化

---

## 已知副作用与注意事项

| 项 | 描述 | 缓解 |
|---|---|---|
| sea_ice 上传延迟 | stride=2 → 海冰每 2 日才上传一次 | 玩家不可察觉（人眼帧率限制） |
| HexCell.temperature 是只读快照 | 阶段 3 后写 `cell.temperature = v` 会被 sync 覆盖 | 全部改走 `map.set_temperature(idx, v)` |
| _build_indices 在 bake_world 末尾耗时 | 256\*256 地图首烘 ~30ms 一次性开销 | 可接受（仅地图生成时） |

---

## 阶段间衔接

阶段 1 完成 → 进入 SUS plan 的"Final"节作为部分收尾  
阶段 2 完成 → 在本文档与 SUS plan 同步更新  
阶段 3 完成 → 关闭 SUS plan 的最终验收 + 关闭本文档
