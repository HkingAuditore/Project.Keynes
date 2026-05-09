# 需求文档 — 换季数值连续化（Seasonal Continuous Climate）

## 引言

当前游戏中的"季节"是离散驱动的：`WorldClock.season_changed` 信号只在 `season_index()` 整数变化时触发一次，`map_generator.refresh_seasonal()` 据此一次性把全图所有 cell 的 `current_state.temperature` / `current_state.moisture` / `snow_cover` 重算到"该季节中段"（`season + 0.5`）的固定值。结果是：

- 春末最后一日，玩家看到温度 = 春季中段值；
- 夏初第一日，温度突然跳到夏季中段值——出现一次明显的"数值阶跃"。

雪盖、湿度、降水估算同理，且在面板上表现为信息行的"突变"。视觉层（shader 端）已经用 `season_phase ∈ [0, 4)` 做了平滑过渡（`vegetation_seasonal_tint`、`hemi_phase`、`season_temp_offset`），但**玩法数值层与视觉层不同步**：玩家看到的画面颜色在过渡，但点开地块面板看到的数字却在硬切。这削弱了"渐进的季节流转"沉浸感，也让基于 `current_state` 的玩法系统（演替、霜冻、作物、虫害等未来扩展）无法获得连续输入。

本需求要求把"季节驱动的数值"从"按 `season_index()` 整数取样"升级为"按连续 `season_phase` 取样"，并把刷新触发点从 `season_changed`（一季一次）下沉到 `day_changed`（一日一次，必要时支持更细粒度），让玩家在面板上能逐日观察到温度 / 湿度 / 降水 / 雪盖的渐进变化，同时保持帧率与现有渲染管线的兼容性。

## 需求

### 需求 1 — 温度按季节相位连续插值

**用户故事：** 作为一名玩家，我希望地块的"当前温度"随着日期推进每日都有微小变化，而不是在换季那一天瞬间跳一大步，以便我可以感受到春去夏来的渐进升温。

#### 验收标准

1. WHEN `WorldClock.day_changed` 触发 THEN `map_generator` SHALL 用当前的连续 `season_phase ∈ [0, 4)`（而非 `season_index() + 0.5` 整数中段）重新计算每个 cell 的 `current_state.temperature` 并写回。
2. WHEN `season_phase` 在一季内从 `s + 0.0` 平滑增长到 `s + 1.0` THEN 同一 cell 的 `current_state.temperature` SHALL 沿着相同的余弦曲线连续变化，相邻两日差值应小于该 cell 季节温度振幅的 1/`days_per_season`。
3. WHEN 玩家正好处于季节边界那一天（例如夏初第 1 日）THEN 该日温度与前一日（春末最后一日）的差值 SHALL 不大于其它任意相邻两日的差值（即不存在"换季阶跃"）。
4. WHEN cell 位于南半球（`ny > 0.5`）THEN 半球反相规则 SHALL 与现有 shader `hemi_phase()` 完全一致，避免 GDScript 端与 shader 端温度走势分叉。

### 需求 2 — 湿度 / 降水按季节相位连续插值

**用户故事：** 作为一名玩家，我希望湿度和当季降水估算也能在面板上看到逐日变化，而不是每整季才跳一次。

#### 验收标准

1. WHEN `day_changed` 触发 THEN 系统 SHALL 用 `seasonal_moisture_scale` 的**两个相邻季节值**按 `season_phase` 的小数部分做线性插值，得到当日的连续 `moist_scale_now`，再乘以 `base_moisture` 得到当日基线湿度。
2. WHEN 当日基线湿度更新后 THEN 雨影 / 河岸生态 / 沿岸湿度补偿等已有 pass 的输入 SHALL 使用该连续值，而非整季快照值（保证下游决策也是连续的）。
3. WHEN 玩家在面板上查看"当前湿度"与"当季降水"两行 THEN 数值 SHALL 随日推进连续刷新，且换季当日不出现 ≥ 0.05 的瞬时阶跃（在默认 climate profile 下）。
4. IF 出于性能考虑实现选择不在每日重跑全图雨影 THEN 系统 SHALL 至少保证 `current_state.moisture` 是连续的（雨影偏置可保留为整季缓存，作为可接受的近似）。

### 需求 3 — 雪盖按温度连续衰减

**用户故事：** 作为一名玩家，我希望中纬度地区的积雪能够在春季逐日融化（而不是某一天集体消失），让地貌看起来更像真实的解冻过程。

#### 验收标准

1. WHEN `day_changed` 触发并且某个 land cell 的当日温度更新完成 THEN 该 cell 的 `current_state.snow_cover` SHALL 按照与 `refresh_seasonal` 中相同的温度阈值公式（`temp < 0.18` 与 `land_h > 0.45 且 temp < 0.30` 两段）重算，不再等到下一次换季。
2. WHEN 一个 cell 在冬末春初的连续若干日中温度从 0.10 缓慢回升到 0.25 THEN 其 `snow_cover` SHALL 单调递减到 0，而不是在某一天直接归零。
3. WHEN 永久 SNOW biome 或 GLACIER cover THEN snow_cover SHALL 仍保持原有上限（1.0 / 0.80），不被日级衰减影响。

### 需求 4 — 地形决策保持"低频"以避免地块抖动

**用户故事：** 作为一名玩家，我不希望地块的 biome（草原/森林/沙漠等）也跟着每日变化反复跳变，那样视觉上会非常凌乱；地形重决策、雨影、植被反馈应保持"每季一次"的节奏即可。

#### 验收标准

1. WHEN `day_changed` 触发 THEN 系统 SHALL 仅刷新 `current_state` 中的连续标量字段（`temperature` / `moisture` / `snow_cover`），**不**调用 `_decide_terrain` 重写 `cell.terrain`，**不**调用植被反馈 / shrubland / mangrove / glacier / swamp / sea_ice 等 pass。
2. WHEN `season_changed` 触发 THEN 现有的"重决策非永久 biome + 重烘焙 biome_tex"完整流程 SHALL 保留不变，作为离散的"季节大动作"。
3. IF 未来需要将某些 biome 决策也下沉到日级 THEN 该改动 SHALL 作为独立后续需求，不在本需求范围内。

### 需求 5 — 玩法面板逐日刷新连续值

**用户故事：** 作为一名玩家，我打开选中地块的信息面板时，希望"当前温度"、"当前湿度"、"当季降水"这三行随时间连续变化，给我"时间在流动"的反馈。

#### 验收标准

1. WHEN `_on_day_changed` 走完一日的逐日数值刷新 AND 当前有选中地块 THEN `main.gd` SHALL 重新刷新该地块面板上的温度行、湿度行、降水行（可复用现有 `_refresh_weather_line` 模式增加一行 `_refresh_climate_line`，避免重建整张面板防止抖动）。
2. WHEN 面板上显示的"当季降水"使用的 `seasonal_moisture_scale` 倍率 THEN 该倍率 SHALL 与逐日插值得到的连续 `moist_scale_now` 一致，不再用整数 season 取的"整季常量"，避免显示与实际数值脱节。
3. WHEN 玩家暂停游戏 THEN 面板数值 SHALL 停止变化并保持当前值，恢复后继续连续推进。

### 需求 6 — 与 shader 视觉保持同步

**用户故事：** 作为一名玩家，我希望地表颜色（植被季节染色、雪盖、温度色）与面板数字看起来"在同一时间点上"，不要出现画面已经入秋但面板还显示夏季温度的情况。

#### 验收标准

1. WHEN 同一帧 shader 收到 `set_season_phase(p)` 而 GDScript 端 `current_state.temperature` 用的也是 `p` THEN 二者计算公式（半球反相、温度振幅、`cos((phase-1)·π/2)·amp`）SHALL 保持完全一致（误差仅来源于浮点精度）。
2. WHEN `season_temp_amp` 在 climate_profile / shader uniform 中调整 THEN GDScript 端 `_season_temp_offset` 的 `amp` SHALL 同步读取同一来源（或保持当前 0.20 的硬编码并在文档中明确标注两端必须手动对齐）。
3. WHEN 调试开关下显示"当季温度偏移"的诊断值 THEN 该值 SHALL 等于 shader fragment 在该 cell 上计算的 `season_offset`（允许浮点 ε 容差）。

### 需求 7 — 性能与触发频率

**用户故事：** 作为一名玩家，我希望"逐日连续化"不会让游戏帧率下降或暂停时卡顿。

#### 验收标准

1. WHEN 在默认地图尺寸（约几千 cell）上每日触发逐日数值刷新 THEN 单次刷新耗时 SHALL 不超过现有 `refresh_seasonal` 的 1/4（因为不再做地形决策、不重烘焙 GPU tex）。
2. WHEN 逐日刷新执行 THEN 系统 SHALL 不调用 `_baker.rebake_*`（GPU tex 仅在 `season_changed` 重烘焙；视觉层连续过渡完全靠 shader 用 `season_phase` uniform 实时插值）。
3. IF 性能仍不达标 THEN 实现 SHALL 提供一个开关（默认开启），允许把逐日数值刷新降级为"每 N 日刷新一次"（N 可在 climate_profile 配置）。
4. WHEN `WorldClock.paused == true` THEN 逐日刷新 SHALL 完全不被触发（因为 `day_changed` 本身就不会发射）。

### 需求 8 — 边界与回退保障

**用户故事：** 作为一名开发者，我希望本次改动有清晰的兼容回退路径，万一逐日刷新有问题可以一键回到原"季首硬切"行为。

#### 验收标准

1. WHEN climate_profile 增加一个布尔开关 `daily_climate_interpolation`（默认 true）THEN 设为 false 时系统 SHALL 退回到现有"`refresh_seasonal` 一次性写整季常量"的旧行为。
2. WHEN 开关为 true 但底层数据缺失（`_last_cfg == null` 或 `current_state` 为空）THEN 逐日刷新函数 SHALL 安全直接 return，不抛异常、不污染 cell 状态。
3. WHEN 玩家载入旧存档（其中可能没有 `current_state.temperature` 字段）THEN 第一次 `day_changed` 触发时 SHALL 自动用当前 `season_phase` 重建该字段，无需额外迁移代码。
