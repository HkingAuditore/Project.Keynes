# 需求文档 — Fast Tick 加速运行性能优化（A + C + D + E）

## 引言

当前游戏在 x5 / x20 加速倍率下卡顿明显。瓶颈分析（详见会话上下文）已确认 4 类主要开销：

1. **A. 天气/反馈链每日全图遍历**：`refresh_daily` 内部 `_apply_transpiration_pass` / `_apply_albedo_pass` / `_apply_vegetation_dynamics` / `_apply_weather_to_map_feedback_pass` + 增量重烘 GPU 纹理，加速档位下每帧叠加多次，单帧成本爆掉 16.6ms 帧预算。
2. **C. `cell.current_state` 字典写入热路径**：`refresh_climate_daily` Pass A/B 每个陆地 cell 写 ~10 个字典键，N=几千 cell 时累计 GDScript 字典查找/装箱/类型擦除开销显著。
3. **D. `day_phase` / `season_phase` 信号每帧发射**：`world_clock.gd._process` 默认 `day_phase_emit_step = 0.0` 表示逐帧 emit，加速档位下没必要这么高频，造成 `_recompute_and_push_tod` + shader uniform 写入的纯浪费。
4. **E. `_on_season_changed` 内 `_renderer.set_map(...)` 走全量重置路径**：x20 加速下每 1.5 现实秒一次，每次都重建/重传整套 renderer 资源，是肉眼可见的"季节切换抖动"。

本次优化范围：**仅做性能优化，不改变任何玩法逻辑/数值平衡/视觉效果**。所有修改必须保持气候/天气/演替/视觉的玩家可观测行为完全一致（同 seed 生成的世界、同档位运行 N 天后的快照应可逐字段对比一致，允许浮点 EMA 因解析公式批跳产生 ≤ 1e-4 的可忽略差异）。

显式排除项（用户已明确不做）：

- 方案 B「单帧多 day 合并」（fast tick 接受 days_advanced 参数批量推进）—— 工程量大，本轮不做。
- 任何对 weather front 寿命/位置批跳的解析公式改造。

---

## 需求

### 需求 1（方案 A·拆解）— 给 `refresh_daily` 加 stride 节流

**用户故事：** 作为玩家，我希望在 x5 / x20 加速档位下游戏不卡顿，以便长时间挂机推进游戏世界演化时仍能流畅观察。

#### 验收标准

1. WHEN `ClimateProfile` 增加新字段 `weather_refresh_stride: int`（默认 `1`，类型 int，范围 `[1, 8]`） THEN 系统 SHALL 在 `refresh_daily` 入口按 `(world_clock.day_index() % weather_refresh_stride) == 0` 决定是否执行内部的天气推进 + 反馈链 + 增量重烘焙。
2. WHEN `weather_refresh_stride > 1` 且当日**跳过**了天气推进 THEN 系统 SHALL 返回上一次的活跃 fronts 快照（保持 renderer 显示不抖动），且 SHALL NOT 调用 `_apply_transpiration_pass` / `_apply_albedo_pass` / `_apply_vegetation_dynamics` / `_apply_weather_to_map_feedback_pass` / `_baker.rebake_*`。
3. WHEN `weather_refresh_stride == 1` THEN 系统 SHALL 保持与现有逻辑完全一致的行为（默认配置下与优化前不可观测差异）。
4. WHEN `MapGenerator` 提供新方法 `set_weather_refresh_stride(s: int)` THEN `main.gd` SHALL 在 `_on_speed_changed`（或同等的速度变更入口）按速度档位自动调档：x1 → 1、x5 → 2、x20 → 4。
5. IF 当前不存在统一的"速度变更通知"入口 THEN 系统 SHALL 在 `world_clock.set_speed(s)` 末尾新增 `signal speed_changed(new_speed: float)`，并在 `main.gd._ready` 中订阅该信号驱动 stride 调档。
6. WHEN 跳过的当日 THEN 选中地块的 weather/vitality/climate/emergent 行 SHALL 不强制刷新（避免 UI 抖动），保留上次值直到真正 tick 的那一日再刷。

---

### 需求 2（方案 C）— 高频字段从 `current_state` 字典提升为 `HexCell` 强类型成员

**用户故事：** 作为开发者，我希望 fast tick 热路径中 cell 状态的读写不再走 GDScript 字典装箱，以便单帧 fast tick 耗时显著下降。

#### 验收标准

1. WHEN 重构 `HexCell` THEN 系统 SHALL 把以下 6 个高频读写字段提升为强类型成员变量（`@export` 不必要，普通 `var` 即可）：
   - `temperature: float`
   - `moisture: float`
   - `snow_cover: float`
   - `temp_baseline: float`（原 `_temp_baseline`，去掉前导下划线统一命名）
   - `temp_season_offset: float`（原 `_temp_season_offset`）
   - `temp_30d_mean: float`、`temp_365d_mean: float`、`temp_dev_from_annual: float`
2. WHEN 重构完成 THEN `current_state` 字典 SHALL 仅保留**真正离散/低频**的字段：`season: int`、`biome: int`、`landform: int`、`vegetation: int`、`cover: int`、`weather: int`、`weather_intensity: float`。
3. WHEN 任何外部消费者（`refresh_seasonal` / `weather_system.gd` / `_baker` / UI 面板 / shader 烘焙等）原本通过 `cell.current_state.get("temperature", ...)` 读取 THEN 该消费者 SHALL 改为直接读取 `cell.temperature`，且行为不变。
4. WHEN 旧存档加载时 `current_state` 中**仍带有**这些已迁移的键 THEN 系统 SHALL 在加载/迁移路径上一次性把它们搬到强类型成员，并从字典中移除（避免双写双读）。
5. WHEN 没有任何代码路径还在读写已迁移字段的字典键 THEN 该字段的字典版本 SHALL NOT 再被设置（确保不留双写）。
6. WHEN 重构完成后 THEN 同一 seed、同档位运行 365 日的 cell 状态快照 SHALL 与重构前**逐字段（除浮点末位）一致**。
7. IF 重构涉及 `temperature_breakdown`（已是字典调试结构） THEN 系统 SHALL 保留该字典不动（仅在选中 cell 时填充，已是冷路径）。

---

### 需求 3（方案 D）— `day_phase` / `season_phase` 信号在加速档自动节流

**用户故事：** 作为玩家，我希望加速档位下游戏不会因为 shader uniform 高频写入而浪费帧预算，以便加速运行更稳定。

#### 验收标准

1. WHEN 速度倍率发生变化（通过新增 `speed_changed` 信号或 `set_speed` 内部）THEN `world_clock` SHALL 自动按下表调整 `day_phase_emit_step`（**不**覆盖用户在 Inspector 里手动设置的非 0 值——见 AC 4）：
   - x1 → `0.0`（每帧发射，保留原行为）
   - x5 → `0.005`
   - x20 → `0.02`
2. WHEN `day_phase_emit_step` 变化时 THEN 系统 SHALL 同步重置 `_last_emit_day_phase = -1.0` 哨兵，确保下一帧必发一次保持视觉对齐。
3. WHEN `season_phase_changed` 在 `_process` 中发射 THEN 系统 SHALL 增加同样的节流逻辑：新增 `@export var season_phase_emit_step: float = 0.0`，加速档位下自动调成 x5 → 0.002、x20 → 0.01；x1 仍保持 0.0（每帧）。
4. IF 用户在 Inspector 中已经把 `day_phase_emit_step` 设置为非 0 值 THEN 系统 SHALL 视为"用户已显式指定节流"，不进行自动调档（用 `_user_overridden_phase_step: bool` 标志位记忆 `_ready` 时检测到的初始非 0 值）。
5. WHEN 视觉效果上观察 THEN 节流后 x5/x20 下 TOD 的色温过渡 SHALL 看不出阶梯感（节流步长在 1 现实秒推进的 day_phase 范围内变化 ≥ 1 步）。

---

### 需求 4（方案 E）— `_on_season_changed` 拆 `set_map(...)` 全量路径

**用户故事：** 作为玩家，我希望季节切换不再产生肉眼可见的卡顿/抖动，以便加速档位下季节过渡平滑。

#### 验收标准

1. WHEN `HexRenderer` 已有 `set_map(map, world_data)` THEN 系统 SHALL 新增 `set_biome_tex_only(world_data)` 方法，仅替换 shader 的 `biome_tex` uniform、不重建材质、不重新计算 `world_bounds`、不重新设置任何与 map geometry 相关的资源。
2. WHEN `main.gd._on_season_changed` 被触发 THEN 它 SHALL 改为调用 `_renderer.set_biome_tex_only(_world_data)` 而不是 `_renderer.set_map(_current_map, _world_data)`。
3. IF `refresh_seasonal` 同时改写了 cover_tex / vegetation_tex（语义上"季末重烘"）THEN `HexRenderer` SHALL 同样提供 `set_cover_tex_only` / `set_vegetation_tex_only`，由 `main.gd` 按需精确调用，**不**走 `set_map`。
4. WHEN `_renderer.set_map(...)` 仍由"地图重新生成 / 切换世界"路径调用 THEN 该路径行为 SHALL 与现有完全一致（不影响 `[R] regenerate` 流程）。
5. WHEN 季节切换时 THEN 控制台 `Season refresh %dms` 的耗时打点 SHALL 显著下降（具体阈值：x20 档位下从优化前 > 8ms 降到 < 3ms，本地用户机器为基准）。

---

### 需求 5（横切）— 不破坏现有打点与回归基线

**用户故事：** 作为开发者，我希望优化后仍能用现有的耗时打点（`fast tick #N: Xms`、`refresh_climate_daily #N: Xms`、`Season refresh Xms`、`Yearly refresh Xms`）做对比验证，以便证明优化有效且没有引入回归。

#### 验收标准

1. WHEN 本次优化任何代码改动落地 THEN 现有四类打点格式 SHALL 完全保留不变。
2. WHEN `weather_refresh_stride > 1` 且当日跳过 THEN `fast tick` 打点 SHALL 反映"跳过日"的真实低耗时（不要硬塞个假值），但 SHALL 在被跳过时跳过 `> 12ms budget` 警告判断（防止误报"低于预算"是不必要的）。
3. WHEN 重构 `HexCell` 字段后 THEN 系统 SHALL 在 `MapGenerator._ready` / 首次 `refresh_climate_daily` 入口处 print 一次 `[fastpath] HexCell typed fields active`，便于验证主路径切换成功。
4. WHEN 所有改动完成 THEN 同一 seed、x1 档位、365 日运行后的 `MapData` 状态快照 SHALL 与优化前**完全一致**（成员字段值相等；浮点 EMA 允许 ≤ 1e-4 误差）；x5/x20 档位下因 stride 不同允许有平台稳态差异，但**长期均值与气候耦合方向必须不变**。

---

### 需求 6（横切）— 性能验收门槛

**用户故事：** 作为玩家，我希望优化后能明显感觉到加速档位流畅，以便对优化效果有可量化的判断。

#### 验收标准

1. WHEN 在 256×256 地图、x20 加速、所有 `enable_local_climate_coupling` 等慢层耦合默认开启的配置下运行 THEN 平均帧时 SHALL 从优化前的"明显卡顿"降到 ≤ 22ms（约 45fps，给 UI/输入留余量）。
2. WHEN x5 档位下运行 THEN 平均帧时 SHALL ≤ 16.6ms（60fps）。
3. WHEN x1 档位下运行 THEN 平均帧时 SHALL 不出现回归（与优化前对比偏差 ≤ ±5%）。
4. WHEN 验证 SHALL 通过现有 console 打点 + Godot Profiler 双源采集，记录到 `perf-report.md`（与本仓库 `visual-presentation-overhaul/perf-report.md` 同风格），便于复盘。

---

## 边界情况与风险

- **存档兼容**：方案 C 改字典字段为强类型成员，必须在 `HexCell` 反序列化路径加迁移分支；旧存档不能崩。
- **EMA 跳跃**：方案 A 让 `refresh_climate_daily` 也跟着 stride 跳跃（沿用现有 `daily_climate_refresh_stride`）会让 EMA 推进步长不再恒为 1 日，但因为 `temp_30d_mean` / `temp_365d_mean` 的 α 是常量，stride > 1 时收敛会略慢。本轮**不强制**改 EMA 公式，作为可观测但合理的副作用记录在 `perf-report.md`。
- **天气视觉断帧**：方案 A 跳日时 fronts 显示用上一帧快照，最长断 4 日（x20 档），玩家肉眼几乎察觉不到（front 本就是慢漂移可视化）。但要在 `perf-report.md` 主观评估一段。
- **HexCell 强类型化的扩散面**：所有读 `current_state["temperature"]` 等键的位置都要改，初步盘点 `map_generator.gd` / `weather_system.gd` / `_baker` / `main.gd` UI 行刷新 4 个文件。要确保不漏改、也不留旧字典写入造成"双写不一致"。
- **Inspector 用户覆盖**：方案 D 自动调档与 Inspector 手动覆盖必须互斥，避免用户精心调过的节流被自动逻辑无情覆盖。
