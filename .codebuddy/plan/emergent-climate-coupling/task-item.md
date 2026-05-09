# 实施计划 — Emergent Climate Coupling

> 基于 `requirements.md` 的 6 条需求，规划为 10 个连续可落地的编码任务。所有任务都在现有 `MapGenerator` / `WeatherSystem` / `WorldClock` / `main.gd` 主循环里增量改造，不引入新管理器类。

- [ ] 1. 在 `ClimateProfile` / `MapConfig` 增加涌现耦合开关与字段底座
   - 在 `climate_profile.gd` 新增导出布尔：`emergent_season_enabled`、`enable_local_climate_coupling`、`emergent_weather_coupling`、`fast_slow_layering_enabled`（默认全部 true）；沿用既有 `MapConfig.enable_ocean_heat_transport`。
   - 在 `hex_cell.gd` 新增字段：`sea_ice_fraction: float = 0.0`、`soil_moisture: float = 0.0`、`vegetation_growth_pressure: float = 0.0`、`temperature_breakdown: Dictionary = {}`（仅调试用）。
   - 在 `map_generator.gd` 模块顶部添加"快层 / 慢层 / 反馈缓冲"字段分类注释 + 每日/每季/每年调用顺序契约注释。
   - _需求：6.1, 5.1, 5.4_

- [ ] 2. 实现太阳辐照函数与连续季节驱动
   - 在 `map_generator.gd` 新增 `_compute_insolation(ny: float, season_phase: float) -> float`（纬度 × 半球反相 × 连续日长衰减）。
   - 让 `refresh_climate_daily` 内部温度/湿度公式改用 `insolation` 作为上游输入；保留 `season_phase` 仍可被读取，但禁止再读取 `season_index` 做整数分支。
   - 把 `refresh_seasonal` 的触发从"每 30 天硬切"改为"`season_phase` 跨整数边界增量 refresh"（在 `main.gd` 的 `_on_day_changed` 内增加一个 `_last_season_idx` 比较即可），其内部 biome 决策读取 `current_state` 连续值。
   - 在 UI 派生一个仅显示用的"名义季节标签 + 过渡百分比"。
   - 当 `emergent_season_enabled == false` 时回退到旧硬切路径。
   - _需求：1.1, 1.2, 1.3, 1.4, 1.5_

- [ ] 3. 在 `refresh_climate_daily` 内叠加温度的三项局部扰动
   - 在现有"年均温 + 季节余弦"基础上叠加：① 反照率扰动（`-albedo_factor*snow_cover`、`-vegetation_cooling*foliage`）；② 沿岸热泄漏（读取相邻水体 `ocean_current_temperature_anomaly`，冬季 ×1.5）；③ landform 地形扰动（山谷/盆地连续相位调制）。
   - 把每项贡献分别累计到 `cell.temperature_breakdown` 字典（基线/季节/反照率/岸泄/地形），仅当某调试开关开启时写入，避免热路径常态开销。
   - 受 `enable_local_climate_coupling` 总开关控制，关闭时回退到纯纬度/海拔/季节公式。
   - _需求：3.1, 3.3, 3.4_

- [ ] 4. 在 `refresh_climate_daily` 内叠加湿度三项耦合 + 调整 transpiration 时序
   - 叠加：① 蒸发项（邻接水体在 `T_eff > T_freeze` 时按 `evaporation_gain` 补湿）；② 雨影项使用 `WindBelt.wind_at(ny, season_phase)` 的当日连续风向；③ 把 `_apply_transpiration_pass` 触发点前移到"climate_daily 之后、weather tick 之前"。
   - 受 `enable_local_climate_coupling` 控制；关闭时所有湿度耦合项跳过。
   - _需求：3.2, 3.3_

- [ ] 5. 实现 `_apply_sea_ice_daily_pass`，替代统一切换的海冰逻辑
   - 新增逐日 pass：对每个水体 cell 用 `Δfrac = k_freeze*max(0, T_form-T_eff) - k_melt*max(0, T_eff-T_melt)` 增量更新 `sea_ice_fraction`，其中 `T_eff` 叠加 `ocean_current_heat_anomaly * OCEAN_CURRENT_ICE_DELAY`。
   - 加入"邻居传染"加成：若 1 环邻居中已存在 `sea_ice_fraction ≥ 0.6` 的水体，本 cell `k_freeze` 获得加权增益。
   - 当 `sea_ice_fraction` 跨过 `ice_terrain_threshold` (0.55) / `ice_terrain_threshold - hysteresis` 时翻转 `cell.terrain` 与 `base_terrain` 之间的关系。
   - 把 `main._on_day_changed` 中调用顺序改为 `refresh_climate_daily → _apply_sea_ice_daily_pass → refresh_daily`，并废弃/弱化原 `_apply_sea_ice_pass` 在 `refresh_seasonal` 中的"统一切换"逻辑。
   - 添加"日切变 > 总水体 3%" 的 QA WARN。
   - _需求：2.1, 2.2, 2.3, 2.4, 2.6_

- [ ] 6. 让 `WeatherSystem` 的锋面演化与本地状态耦合
   - 修改 front 推进（advect）：`velocity` 改读 `WindBelt.wind_at(ny, season_phase)` 逐日采样；衰减系数按"front 类型 vs 当前 cell 温湿带"的匹配/不匹配分别 ×0.7 / ×1.5。
   - 路径经过迎风坡 → 该 cell 叠加额外降水强度；路径经过背风坡 → 额外衰减（与雨影共享 `rain_shadow_*` 参数）。
   - 修改 `spawn`：spawn 概率与"本地 1 环温湿梯度最大值"正相关；front 类型由"本地温度带 + 湿度带 + season_phase"联合决定（如 暖湿+夏 → STORM、寒+海 → BLIZZARD、暖干陆+夏 → HEATWAVE）。
   - 受 `emergent_weather_coupling` 控制，关闭时回退到旧均匀随机 spawn 路径。
   - _需求：4.1, 4.2, 4.3, 4.5_

- [ ] 7. 引入慢层只读访问器与调用顺序契约执行
   - 在 `MapData`（或 `map_generator.gd` 内的等价结构）新增 `sample_slow_layer(qr: Vector2i, fields: Array) -> Dictionary` 只读访问器；debug 模式下检测对慢层字段的非法写入并 assert。
   - 把 `WeatherSystem` 内部所有读取 `base_*` / `landform` / `terrain` / `cover` / `ocean_current` / `sea_ice_fraction` / `elevation` 的位置统一改为通过该访问器；移除 `WeatherSystem` 中任何对慢层字段的直接写入。
   - 在 `main._on_day_changed` 内严格按"climate_daily → sea_ice → weather → feedback"四步执行；在每季边界触发 `refresh_seasonal`、每年触发 `refresh_yearly`，并使两类 tick 各自单独打点。
   - _需求：5.2, 5.4, 5.5, 5.8_

- [ ] 8. 实现 `_apply_weather_to_map_feedback_pass`（天气→慢层的小权重反馈）
   - 在 `map_generator.gd` 新增该 pass：每日末尾运行一次，把 `current_state.weather_*` 的当日累积量（如降水、风速、热浪天数）以 `WEATHER_TO_SOIL_GAIN ≤ 0.01` 的小权重累加到 `cell.soil_moisture` 与 `cell.vegetation_growth_pressure`；硬约束单日 |Δ| ≤ 慢层对应基线 0.5%。
   - 在 `refresh_seasonal` 末尾消费这两个反馈缓冲（影响下一季 `base_moisture` 微漂、biome 决策时的湿度修正），并在消费后乘以 `feedback_decay = 0.5` 衰减。
   - 受 `fast_slow_layering_enabled` 控制：关闭时该 pass 不运行、缓冲字段被忽略，回退到旧路径，不污染 `base_*`。
   - _需求：5.3, 5.6, 5.7_

- [ ] 9. 选中地块面板：新增温度分解 / 海冰覆盖度 / 反馈缓冲三行
   - 在 `main.gd` 选中地块信息面板增加 `_refresh_emergent_lines` 函数，逐日刷新：
     - 陆地 cell："温度分解：基线 X + 季节 ±X + 反照率 ±X + 岸泄 ±X + 地形 ±X"。
     - 陆地 cell："土壤湿度反馈缓冲：X.XXX（本季累计）"。
     - 水体 cell："海冰覆盖：XX.X%（冻结率 X / 融化率 X）"。
     - 顶部"当前季节"行改为"名义季节标签 + 过渡百分比"。
   - 所有读取走 `get(key, fallback)`；缺字段时一次性 WARN 后静默。
   - _需求：1.4, 2.5, 3.4, 6.3, 6.4, 6.5_

- [ ] 10. 性能打点、节流 WARN 与回退回归测试钩子
   - 在 `main._on_day_changed` 给"fast tick 合计耗时"与"slow tick 单次耗时"分别打点；fast 合计首次超 12ms 触发 WARN，并按 365 帧节流。
   - 在 `_apply_sea_ice_daily_pass` 内统计当日 `SEA_ICE` 翻转 cell 数，超过总水体 3% 时 WARN（QA 用，不阻塞）。
   - 提供一个调试入口（控制台命令或 `ClimateProfile` 一键开关组）：把 4 个新开关全部置 false 进入"纯回退模式"；编写一个简短的回归校验脚本/函数（同种子 100 年加速跑），断言全图 `base_moisture / base_temperature` 平均值与基线 ±1% 偏差。
   - _需求：2.6, 6.1, 6.2, 6.6_
