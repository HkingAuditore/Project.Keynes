# 需求文档 — Emergent Climate Coupling（气候系统涌现化重构）

## 引言

当前项目的气候系统虽然已实现"逐日连续温度/湿度/雪盖刷新"（见 `seasonal-continuous-climate`）以及"系统性洋流"（见 `systemic-ocean-currents`），但从玩家感知层面仍存在五个"不科学、不涌现"的核心问题：

1. **子系统间缺乏反馈回路**：`refresh_climate_daily` 只用"纬度 + 海拔 + 季节相位"这条开环公式推温度湿度，完全不读取当前格子的地貌（landform）、植被覆盖（vegetation/cover）、附近洋流（ocean_current / upwelling）、雪盖等状态。结果是"沙漠旁边长出森林，两者气候却完全一样"。
2. **海冰统一出现/消散**：`_apply_sea_ice_pass` 只在 `season_changed` 时用"季节中段温度 + 单一阈值（±hysteresis）"硬切，所有高纬海水会在同一日集体冻结或集体融化，不呈现"先从最冷的小片开始扩散、春天从边缘开始融化"的自然形态，也不受洋流输运/气候漂移/当日温度影响。
3. **硬编码换季**：四季是 `world_clock` 按"days_per_season × 4"计时器强行推进的整数事件，驱动 `refresh_seasonal` 一次性重写全图；温度、湿度、降水、洋流方向、季风等"季节性效应"是对这个硬切事件的被动响应，而不是"太阳辐照（日射角 × 日长）随时间连续变化时，由各个子系统自发涌现的结果"。
4. **天气每日跳变**：`WeatherSystem` 在 `refresh_daily` 内每日一次性 spawn / advect / despawn 气象锋面，当日锋面类型和位置决定于"全局气候异常 + 季节 + 随机数"，与"本地当日温度梯度、湿度梯度、地貌（山脉/海岸/盆地）"耦合很弱；日与日之间强度/类型频繁跳变，不像"持续数日的一场雨 / 一周的热浪"。
5. **快慢系统耦合在同一主循环里**：天气是"日级、事件化、即时影响"的快变量；地貌/biome/植被/海冰退缩/洋流烘焙是"季级或年级、缓慢演化"的慢变量。当前所有刷新（`refresh_climate_daily` / `refresh_daily` / `refresh_seasonal` / `refresh_yearly`）共享同一组 `cell.current_state` 字段，没有清晰的"读侧 / 写侧"分层；天气写完温度湿度立即被次日的气候 pass 读到，而气候 pass 又把基线推给下一日的天气，导致快慢量互相污染、计算开销也无法按尺度分摊。

本次重构的核心目标：**不重写、不替换已有子系统，而是把它们用"每日一次、物理因果链明确"的耦合 pass 串起来**，并**显式引入"快慢双时间尺度分层"的数据契约**，让温度、湿度、海冰、降水、洋流、天气都从"上一日的场 + 当日太阳辐照 + 本地状态"连续涌现。

设计原则（硬约束）：

- **不引入新主循环**：仍然由 `main._on_day_changed` 驱动，仅在 `refresh_climate_daily` 与 `refresh_daily` 之间插入新的耦合 pass。
- **不破坏 shader/可视表现**：所有写入仅限 `cell.current_state`（及 `snow_cover_fraction`、`sea_ice_fraction` 等新标量字段），`cell.base_*` 与 `world.*_buffer` 仍由 `refresh_seasonal / refresh_yearly` 周期重烘，shader uniform 接口不变。
- **性能预算**：新增每日 pass 总开销在 80×60 地图上 ≤ 8ms（与现有 `refresh_climate_daily` 同量级），80×60 地图 100 年加速回归不崩。
- **向后兼容**：所有新行为挂在 `ClimateProfile` / `MapConfig` 开关后（默认开启，可一键回退）。

---

## 需求

### 需求 1 — 太阳辐照驱动的连续换季（取代硬编码季节事件）

**用户故事：** 作为一名模拟爱好者，我希望"换季"不再是日历触发的离散事件，而是太阳辐照（日长 + 日射角）随 `season_phase` 连续变化后，温度、湿度、降水、洋流、季风等子系统自发涌现出的综合效果，这样玩家看到的"春天"是"白昼变长→冰层边缘后退→海面蒸发加强→海陆温差增大→季风反向"的因果链，而不是"系统在第 30 天突然宣布进入夏季"。

#### 验收标准

1. WHEN `WorldClock` 发射 `day_changed` THEN 系统 SHALL 基于当日 `season_phase ∈ [0, 4)` 计算**每格子的日射强度 `insolation(ny, season_phase)`**（纬度依赖 + 半球反相 + 连续日长衰减），作为温度/蒸发等后续 pass 的上游输入，而不再依赖整数 `season_index`。
2. WHEN 任何子系统需要"季节"语义（海冰、洋流季风分量、天气 spawn 概率）THEN 它 SHALL 读取 `insolation` 或 `season_phase` 浮点值，而不是读取 `season_index` 做分支。
3. IF `ClimateProfile.emergent_season_enabled == false` THEN 系统 SHALL 回退到现有 `refresh_seasonal` 硬切路径（兼容回退）。
4. WHEN 玩家在气候面板查看"当前季节"THEN 系统 SHALL 派生一个仅用于 UI 显示的名义季节标签（春/夏/秋/冬 + 过渡百分比），而不让该标签反向驱动物理 pass。
5. IF `refresh_seasonal` 仍被调用（用于 biome 重决策、雨影重算等缓变逻辑）THEN 它的调用频率 SHALL 从"每 30 天一次硬切"放宽为"`season_phase` 穿过整数边界时触发一次增量 refresh"，且 biome 决策读取的温度/湿度 SHALL 来自 `current_state`（连续值）而非重算。

---

### 需求 2 — 海冰的局部涌现（取代统一切换）

**用户故事：** 作为一名玩家，我希望秋冬季海冰从"最冷的高纬 + 最靠陆架 + 受冷洋流影响最强"的小片区先冻结，然后随着温度继续下降逐格向外扩张；春季则从"最靠赤道 + 最受暖流影响"的边缘先融化，从而呈现"海冰边界逐日推进"的自然形态，而不是所有符合阈值的海面在某日集体翻转。

#### 验收标准

1. WHEN `refresh_climate_daily` 完成当日温度写入 THEN 系统 SHALL 新增一个 `_apply_sea_ice_daily_pass`，每日推进每个水体 cell 的 `sea_ice_fraction ∈ [0, 1]`，该值 SHALL 通过以下公式增量更新：`Δfrac = k_freeze * max(0, T_form - T_eff) - k_melt * max(0, T_eff - T_melt)`，其中 `T_eff = current_state.temperature + ocean_current_heat_anomaly * OCEAN_CURRENT_ICE_DELAY`。
2. WHEN 某 cell 的 `sea_ice_fraction` 跨过 `ice_terrain_threshold`（例如 0.55）THEN 系统 SHALL 把 `cell.terrain` 翻转为 `SEA_ICE`；WHEN 跌回 `ice_terrain_threshold - hysteresis` THEN 翻回 `base_terrain`。
3. WHEN 相邻水体 cell 已有 `sea_ice_fraction ≥ 0.6` THEN 本 cell 的 `k_freeze` SHALL 获得 "邻居传染" 加成（模拟冰盖物理扩张），反之孤立开阔水域冻结更慢。
4. IF `MapConfig.enable_ocean_heat_transport == true` THEN 海冰的 `T_eff` SHALL 读取 `cell.ocean_current_temperature_anomaly`，暖流沿岸即使纬度够高也不易冻结（模拟北大西洋暖流使挪威海岸不冻）。
5. WHEN 玩家查看面板 THEN 海冰覆盖度 SHALL 显示为 `sea_ice_fraction` 百分比，而不是"有/无"二值。
6. WHEN 全图 `SEA_ICE` cell 在同一日变化数量 > 总水体数 3% THEN 系统 SHALL 视为回归异常（全图统一切换的旧行为），并在控制台输出 WARN（仅用于 QA，不阻塞流程）。

---

### 需求 3 — 温度/湿度/降水与地貌、生态、洋流的局部耦合

**用户故事：** 作为一名模拟爱好者，我希望每日刷新的温度和湿度不只是"纬度函数 + 季节曲线"，而是额外受到"本地海拔、植被覆盖、雪盖反照率、近邻海面温度、洋流热量泄漏"等因素的局部扰动，这样同纬度的沙漠和森林、背风坡和迎风坡、暖流沿岸和寒流沿岸能呈现出差异分明的微气候。

#### 验收标准

1. WHEN `refresh_climate_daily` 计算 `temp_now` THEN 系统 SHALL 在现有"年均温 + 季节余弦偏移"之上叠加以下 3 项局部扰动：
   1. **反照率扰动**：`-albedo_factor * snow_cover`（雪地更冷）、`-vegetation_cooling * foliage`（森林更凉）。
   2. **沿岸热泄漏**：若 cell 邻接水体且邻居 `ocean_current_temperature_anomaly > 0` THEN `+COASTAL_HEAT_LEAK * anomaly`；WHEN `season_phase` 处于冬季区间（|cos((phase-1)*π/2)| × sign < 0）THEN 泄漏系数 × 1.5（与现有 `OCEAN_HEAT_MIX` 同源常量）。
   3. **地形扰动**：山谷/盆地 landform 日间升温加速、夜间降温加速（幅度由 `season_phase` 连续调制，不改 `base_temperature`）。
2. WHEN `refresh_climate_daily` 计算 `moisture_now` THEN 系统 SHALL 在现有"连续季节倍率"之上叠加：
   1. **蒸发项**：`+evaporation_gain * max(0, T_eff - T_freeze) * water_neighbor_weight`，代表海洋/湖泊邻居在暖日蒸发补湿。
   2. **植被蒸腾项**：复用现有 `_apply_transpiration_pass` 的输出叠加到 `current_state.moisture`，但把其触发时机从"天气 tick 之后"前移到"climate_daily 之后、weather tick 之前"，形成"植被→湿度→天气"的单向因果。
   3. **雨影项**：背风坡（上风向海拔差 ≥ `rain_shadow_threshold`）当日 `moisture_now *= rain_shadow_factor`，但公式使用**当日风向**（从 `WindBelt.wind_at(ny, season_phase)` 连续插值）而非季节硬切风向。
3. IF 以上任一耦合项的开关（`enable_local_climate_coupling`，默认 true）被关闭 THEN 该 pass SHALL 退化为现行纯纬度/海拔/季节公式（回归测试路径）。
4. WHEN 玩家选中一个格子 THEN 面板 SHALL 能分项显示 "基线温度 / 季节偏移 / 反照率扰动 / 沿岸泄漏 / 地形扰动" 五行贡献，验证耦合链可见可解释。
5. WHEN 100 游戏年加速运行后 THEN 同纬度下"森林带平均温度 - 沙漠带平均温度"的差值 SHALL ≥ 0.03（归一化单位），证明局部耦合对长期气候产生了可观测的涌现差异。

---

### 需求 4 — 天气锋面的连续演化（取代每日跳变）

**用户故事：** 作为一名玩家，我希望一场雨能"连下三天、强度随温湿场自然衰减，并沿盛行风带漂移"，而不是今天有明天就消失；雷暴、寒潮、季风都应从"当日本地温湿梯度 + 地貌地形"涌现，而不是每日独立重掷。

#### 验收标准

1. WHEN `WeatherSystem` 在 `refresh_daily` 内推进已有 `WeatherFront` THEN 系统 SHALL 把 front 的**生存期（ttl_days）、强度衰减（decay_per_day）、位移速度（velocity）**与"当前 center 所在 cell 的本地状态"耦合：
   1. front 走到"温湿场与其类型不匹配"的区域（例如 STORM 走到干冷沙漠）THEN 额外衰减 × 1.5。
   2. front 走到"温湿场与其类型同向"的区域（例如 RAIN 走到暖湿海岸）THEN 衰减减速（可长寿命，模拟持续性降水）。
   3. front 的 `velocity` SHALL 从"当季风场常量"改为"沿途 `WindBelt.wind_at(ny, season_phase)` 的逐日采样"，从而出现"同一场雨前两天向东、第三天转向东南"的连续轨迹。
2. WHEN 某 front 本日移动路径经过山脉迎风坡 THEN 系统 SHALL 在该 cell 叠加额外降水强度；WHEN 经过背风坡 THEN 额外衰减（与需求 3 的雨影耦合共享参数）。
3. WHEN 当日新生成 front（spawn）THEN spawn 概率 SHALL 与**本地温湿梯度**（相邻 cell 温度差 / 湿度差的最大值）正相关，而非均匀随机；spawn 出的 front 类型 SHALL 由 "本地温度带 + 湿度带 + 季节相位" 三者联合决定（例如"暖湿 + 夏季 → STORM、寒冷 + 海面 → BLIZZARD、暖干陆地 + 夏季 → HEATWAVE"）。
4. WHEN 玩家连续观察 10 个游戏日 THEN 单个 front 的平均存活时间 SHALL ≥ 3 日，全图 front 类型分布在日间变化率 SHALL ≤ 40%（避免"每日全换一套"的跳变感）。
5. IF `ClimateProfile.emergent_weather_coupling == false` THEN 系统 SHALL 回退到现有的独立随机 spawn 路径（兼容回退）。

---

### 需求 5 — 快慢双时间尺度分层（地图驱动天气、天气缓慢回写地图）

**用户故事：** 作为一名模拟爱好者，我希望"天气"和"地貌/生态/气候基线"在系统设计上被显式分成两层：地图（地形、植被、洋流烘焙、海冰场、年均气候基线）是缓慢、长期演化的"慢量"，每季或每年才需要重算一次；天气（锋面、降水、阵风、热浪、寒潮）是从这个慢量场中**读取**当日局部条件后**自发产生**的快量，每日推进，且天气只能通过受限的"反馈通道"按权重缓慢回写地图层（湿度记忆、植被生长扰动、土壤水分等），而不是当天就重写慢量字段。这样"刮一阵风地形不会立刻变、但连下半年的雨会逐渐让一片地从草原变沼泽"才合乎直觉。

#### 验收标准

1. WHEN 系统启动 THEN 项目 SHALL 在 `HexCell.current_state` 之外**显式区分两类字段**并在注释/文档中标注其更新尺度：
   - **慢层（slow / map layer）**：`base_temperature`、`base_moisture`、`base_vegetation`、`elevation`、`landform`、`terrain`、`cover`、`snow_cover_fraction`（积雪长期累积量）、`soil_moisture`（新增，土壤湿度长期记忆）、洋流烘焙 buffer、`sea_ice_fraction`（半快半慢，由本需求归入慢层）。**只读侧**对天气可见，**写侧**只允许由 `refresh_seasonal` / `refresh_yearly` / 受限"反馈通道"修改。
   - **快层（fast / weather layer）**：`current_state.temperature`、`current_state.moisture`、`current_state.weather_*`（活跃锋面引用、当日降水强度、当日风向阵风等）。每日由 `refresh_climate_daily` + `WeatherSystem` 完整重算，**不持久写入慢层**。
2. WHEN `WeatherSystem` 在每日 tick 内需要决策（spawn / 演化 / 衰减 / 降水落点）THEN 它 SHALL 仅**读取**慢层字段（`base_*`、`landform`、`terrain`、`cover`、`ocean_current`、`sea_ice_fraction`、`elevation`）以及当日的快层 `current_state.temperature/moisture/wind`，**禁止**直接修改任何 `base_*` / `landform` / `terrain` / `cover` 字段。
3. WHEN 当日天气产生"应当回写慢层"的累积效应（例如长期降水增加土壤湿度、长期干旱降低基础植被、强风偶发倒木）THEN 这些回写 SHALL 经过一个统一的 `_apply_weather_to_map_feedback_pass`，该 pass：
   1. 仅在每日末尾运行一次。
   2. 把当日天气贡献以**很小的权重**（例如 `Δsoil_moisture = WEATHER_TO_SOIL_GAIN * daily_precip`，`WEATHER_TO_SOIL_GAIN ≤ 0.01`）累加到慢层"反馈缓冲字段"（如 `soil_moisture` / `vegetation_growth_pressure`）。
   3. 这些反馈缓冲字段 SHALL 仅在 `refresh_seasonal` / `refresh_yearly` 时被消费并衰减，从而保证"当天的雨不会当天改写 base_moisture，但连下三个月会缓慢改"。
4. WHEN 系统启动 THEN 项目 SHALL 在 `MapGenerator` 模块顶部以注释形式给出**调用顺序契约**，并由 `main._on_day_changed` 严格遵守：
   ```
   每日（fast tick）：
     1. refresh_climate_daily(map, season_phase)        — 读慢层 + 写快层（current_state.*）
     2. _apply_sea_ice_daily_pass                       — 读快层温度 + 读慢层洋流 → 写半慢层 sea_ice_fraction
     3. WeatherSystem.tick / refresh_daily              — 只读 + 产生当日 weather event（写 current_state.weather_*）
     4. _apply_weather_to_map_feedback_pass             — 把当日天气以小权重累加到慢层反馈缓冲（不直接改 base_*）
   每季（slow tick，仅 season_phase 跨整数边界）：
     5. refresh_seasonal                                — 消费反馈缓冲、做 biome 决策、重烘 GPU tex
   每年（slow tick）：
     6. refresh_yearly                                  — 长期植被演替、base_* 漂移
   ```
5. WHEN `WeatherSystem` 在某日想读取"当地是否有山脉/海岸/沙漠"以决定 spawn 类型 THEN 它 SHALL 通过 `MapData.sample_slow_layer(qr, fields)` 这种**只读访问器**获取，访问器 SHALL 在 debug 模式下检测对慢层的非法写入并 assert（开发期警报）。
6. WHEN `_apply_weather_to_map_feedback_pass` 累计的反馈缓冲在一个完整年内 SHALL 遵守"小权重 + 衰减"约束：单日累加的绝对值 ≤ 慢层基线对应字段的 0.5%；每季 `refresh_seasonal` 消费后该缓冲 SHALL 按 `feedback_decay`（默认 0.5）衰减以避免无限累积。
7. WHEN 玩家关闭 `ClimateProfile.fast_slow_layering_enabled`（默认 true）THEN 系统 SHALL 退回到现有"快慢混写到 current_state"的旧路径，作为兼容回退；此时 `_apply_weather_to_map_feedback_pass` 不运行，`base_*` 仍只由 `refresh_seasonal/yearly` 维护，不破坏旧存档。
8. WHEN 100 游戏年加速运行 THEN "每日 fast tick 总耗时（步骤 1-4）" 与 "每季 slow tick 单次耗时（步骤 5）" SHALL 通过既有打点单独可观测（分别打印），便于验证两层各自的性能预算并独立优化。

> **架构注记**：本需求不创建新管理器类，也不引入新主循环；它通过**字段分类 + 调用顺序契约 + 反馈缓冲字段 + 只读访问器**这四件事，把"快慢分层"做成一个**软分层**。这样既满足"天气快速、地图缓慢、双向但不对称耦合"的物理直觉，又保持与项目现有 `MapGenerator` / `WeatherSystem` / `WorldClock` 主循环结构兼容。

---

### 需求 6 — 诊断、调优与回归

**用户故事：** 作为开发者，我希望新耦合链可被一键开关、可在选中面板看到每项贡献、可在控制台打性能/异常日志，以便在重构后快速定位问题并保持与旧存档的兼容。

#### 验收标准

1. WHEN 游戏启动 THEN `ClimateProfile` SHALL 暴露以下开关（默认 true），且在 Inspector 可见：`emergent_season_enabled`、`enable_local_climate_coupling`、`emergent_weather_coupling`、`fast_slow_layering_enabled`；以及 `MapConfig.enable_ocean_heat_transport`（已存在，沿用）。
2. WHEN `refresh_climate_daily` + `_apply_sea_ice_daily_pass` + `refresh_daily` + `_apply_weather_to_map_feedback_pass` 合计耗时首次 > 12ms THEN 系统 SHALL 打印一次 WARN（含 cell 数、phase），后续按 365 帧节流。
3. WHEN 选中一个水体 cell THEN 面板 SHALL 新增一行 "海冰覆盖：XX.X%（冻结速率 X.XX / 融化速率 X.XX）"。
4. WHEN 选中一个陆地 cell THEN 面板 SHALL 新增一行 "温度分解：基线 X.XX + 季节 ±X.XX + 反照率 ±X.XX + 岸泄 ±X.XX + 地形 ±X.XX"，以及一行 "土壤湿度反馈缓冲：X.XXX（本季累计）"用于观测快慢反馈通道。
5. WHEN 任一新 pass 出现 `cell.current_state` 空字典/缺字段 THEN 它 SHALL 用 `get(key, fallback)` 安全读取并在一次 WARN 后静默继续，**不得抛异常中断主循环**。
6. WHEN 玩家关闭所有新开关 THEN 100 年加速跑下来的全图 `base_moisture / base_temperature` 平均值 SHALL 与旧版本（同种子）保持 ±1% 以内偏差（证明兼容回退路径未被污染）。

---

## 边界与非目标（out of scope）

- 不引入真正的流体 PDE 求解（NS / 浅水方程），所有耦合仍是"邻居 1 环加权 + 连续时间差分"的近似。
- 不改 `WorldData` 的 buffer 结构（`ocean_current_buffer / wind_field_buffer / baked_temperature_buffer` 的尺寸与编码保持不变）。
- 不新增 GPU texture；所有逐日变化通过 shader 既有 uniform（`season_phase`、`climate_anomaly`、`weather_front_*`）呈现。
- 不重做 biome 决策树；`_decide_terrain` 仍由"穿过 season_phase 整数边界"触发，维持现有"一季一次"频率。
- 不做淡水湖冰（`LAKE` 冻结）—— 留给后续 phase。
- 需求 5 的"软分层"不引入新管理器类、不拆出独立模块，慢层数据仍存在 `HexCell` 上，只通过字段分类 + 访问器 + 反馈缓冲实现"逻辑上的快慢解耦"；真正的"分模块计算"留给后续重构（如有必要）。
