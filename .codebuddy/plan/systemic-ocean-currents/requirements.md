# 需求文档：系统化洋流系统（Systemic Ocean Currents）

## 引言

当前项目已经具备**带物理语义的洋流向量场**：`MapBaker._bake_ocean_currents` 基于盛行风 + Ekman 偏转（±45°）+ 大陆反射 + 噪声扰动生成 per-pixel 流场，烘焙进 `WorldData.ocean_current_buffer`（RG8），并通过 `MapGenerator._compute_ocean_currents` 回填到 `HexCell.ocean_current`。`world_map.gdshader` 已消费该场，实现流纹动画、暖/寒流色偏、波浪对齐、河口 plume 等视觉表现。

但系统存在两个根本性缺陷：

1. **单向驱动**：洋流只被 bake-once 的夏季风场驱动；不吃温度/盐度/季节/天气；`refresh_seasonal` / `refresh_climate_daily` 不刷新洋流；
2. **下游零消费**：逻辑层除了把向量喂给 shader，没有任何系统（温度、湿度、降水、海冰、生物 cover、REEF/KELP）读取 `ocean_current`。

本次需求的目标是把洋流升级为**与气候系统双向耦合的活体子系统**：洋流接受「风场 + 热盐梯度 + 季节相位」作为输入；并把「热量输运 + 上升流营养」作为输出反馈给温度、海冰、海洋生物三条下游管线。保持现有 shader 视觉不破坏，仅扩展逻辑层与季节刷新路径。

**非目标**（明确划界）：
- 不做盐度的真实三维分层；只引入 per-cell 标量 `salinity ∈ [0, 1]` 作为热盐驱动项的近似。
- 不做全球经向翻转环流（AMOC）的垂向分量；只在 2D 水平场里加入"冷咸水汇点 / 暖淡水源点"的辐散-辐合标量。
- 不修改陆地气候主循环的整体结构；只在既有的 `refresh_seasonal` / `refresh_climate_daily` 里新增一个**洋流热输运 pass**。
- 不新建独立管理器类；复用 `MapGenerator` 与 `MapBaker` 的既有入口，遵循"逻辑层纯净、烘焙层只出数据"的项目架构约定。

## 需求

### 需求 1：洋流场季节化刷新

**用户故事：** 作为世界模拟系统的维护者，我希望洋流场随季节发生合理变化，以便玩家在冬/夏看到不同的暖流延伸边界，而不是一张全年不变的贴图。

#### 验收标准

1. WHEN `MapGenerator.refresh_seasonal` 被调用并传入 `season_idx` THEN 系统 SHALL 调用 `MapBaker.rebake_ocean_currents(world, season_idx)` 重新烘焙 `ocean_current_buffer`，使用当季合成的 wind_field（夏季基线 + 季风 offset，与 `weather_system` 融合规则一致）作为驱动风。
2. WHEN 季节刷新完成 THEN 系统 SHALL 同步调用 `_compute_ocean_currents` 把新场回填到所有 water `HexCell.ocean_current`，保证逻辑层与 GPU 缓冲一致。
3. IF 季节切换导致 `ocean_current_buffer` 变动 THEN `HexRenderer` SHALL 在下一帧收到该 buffer 的 set_shader_parameter 更新，shader 视觉流纹方向 SHALL 平滑过渡（通过 shader 内部对 ocean_current 的 FBM 相位衰减已天然做到，无需插值）。
4. WHEN `refresh_climate_daily` 被调用 THEN 系统 SHALL **不**重烘洋流（仅季节切换重烘，避免每日 GPU 回读开销），但 SHALL 允许 `season_phase ∈ [0, 4)` 连续相位参数影响洋流→温度输运强度的权重。

### 需求 2：热盐驱动项

**用户故事：** 作为玩法设计者，我希望洋流的流向不只由风决定，还体现"高纬冷水下沉、低纬暖水回补"的热盐环流趋势，以便经向（南北向）洋流分量在现实物理意义上合理。

#### 验收标准

1. WHEN `_bake_ocean_currents` 执行 THEN 系统 SHALL 采样同像素的温度场 `baked_temperature_buffer`，计算其南北方向梯度 `dT/dlat`，并在输出向量上叠加一个权重为 `THERMOHALINE_WEIGHT`（可配）的经向分量，方向从冷极推向暖赤道。
2. IF 该像素位于高纬（|lat| > 60°）且温度 < 冷水阈值 `COLD_SINK_TEMP` THEN 系统 SHALL 在该像素标记 `downwelling = true`（写入独立的 `ocean_upwelling_buffer`，R8 编码，0=无 / 128=下沉 / 255=上升）。
3. IF 该像素处于沿岸带且盛行风沿海岸线平行、科里奥利把表层水推离海岸 THEN 系统 SHALL 判定为上升流点，标记 `upwelling = true`。
4. WHEN 沿岸上升流点被识别 THEN 系统 SHALL 将其写入 `HexCell.upwelling_strength ∈ [0, 1]` 的新字段，供下游生物 pass 读取。

### 需求 3：洋流→温度反馈（热量输运）

**用户故事：** 作为玩家，我希望看到"被暖流经过的高纬沿岸地区"冬季气温明显高于同纬度内陆（类比西欧效应），而寒流经过的低纬西岸出现异常低温，以便世界地图呈现现实地理的气候多样性。

#### 验收标准

1. WHEN `refresh_climate_daily` 执行温度连续插值时 THEN 系统 SHALL 在 current_state 的温度写回前，执行一个新的 `_apply_ocean_heat_transport_pass` pass。
2. WHEN 该 pass 对每个 water cell 运行 THEN 系统 SHALL 沿 `-ocean_current` 方向回溯 1~N 个（N ≤ `OCEAN_HEAT_ADVECT_STEPS`，默认 3）cell，取上游 cell 的 base_temperature 作为"被输运来的温度"，按 `OCEAN_HEAT_MIX ∈ [0, 1]`（默认 0.25）与本 cell 的几何温度混合。
3. WHEN 陆地 cell 与水 cell 相邻 THEN 系统 SHALL 将相邻水 cell 的"洋流温度异常"（`current_state.temperature - base_temperature_latitudinal`）按 `COASTAL_HEAT_LEAK`（默认 0.35）加权传入陆地 cell 的 current_state.temperature。
4. IF 陆地 cell 与多个水 cell 相邻 THEN 系统 SHALL 对所有相邻水 cell 的温度异常求加权平均，权重为 `max(0, dot(相邻方向, 该水 cell 的 ocean_current))`，使"迎流海岸"获得更多热量交换。
5. WHEN `season_phase` 接近冬季（phase 靠近 2.0） THEN 系统 SHALL 将 `COASTAL_HEAT_LEAK` 的实际权重乘以 `1.5`，因为冬季海陆温差大、热量泄漏更明显。

### 需求 4：洋流→海冰耦合

**用户故事：** 作为玩法设计者，我希望暖流入侵的高纬海域（如北大西洋暖流末端）冬季不结冰或冰期缩短，以便沿岸港口具有战略价值差异。

#### 验收标准

1. WHEN `_apply_sea_ice_pass` 为某 water cell 判定海冰生成阈值时 THEN 系统 SHALL 把该 cell 当前温度加上 `OCEAN_CURRENT_ICE_DELAY * max(0, temperature_transport_anomaly)`（默认系数 1.0）作为有效温度，用于与结冰阈值比较。
2. IF 该 cell 的 `upwelling_strength > 0.3` 且上升流来自深冷水 THEN 系统 SHALL 反向降低该 cell 的有效温度 `0.5 * upwelling_strength` 个单位（模拟冷上升流抑制海冰融化）。
3. WHEN 海冰退缩判定在 `refresh_seasonal` 运行 THEN 该有效温度 SHALL 与现有 snow_cover、base_temperature 使用同一温度基，保证季节间连续。

### 需求 5：洋流→海洋生物耦合

**用户故事：** 作为世界地图可读性的把控者，我希望上升流富营养区生成更多 REEF/KELP，而远洋深水区保持贫营养，以便玩家在地图上一眼识别出"好渔场"。

#### 验收标准

1. WHEN `MapGenerator` 决策海洋 cover（REEF / KELP） THEN 系统 SHALL 在现有的温度带判定基础上，额外读取 `HexCell.upwelling_strength`。
2. IF `upwelling_strength > 0.4` 且水深为大陆架（shallow water） THEN REEF/KELP 的生成温度阈值窗口 SHALL 向两侧各放宽 `0.08`，允许在原本不达标的温度带生成。
3. IF `upwelling_strength > 0.6` 且水深为深海 THEN 系统 SHALL 允许标记该 cell 为 `PELAGIC_BLOOM` 特殊 cover（视觉：shader 的 deep_ocean_current_tint 额外叠加一层淡绿色 tint，权重由 upwelling 决定）。
4. WHEN 无上升流数据（例如跳过第 2 需求的早期迭代） THEN 系统 SHALL 回退到原有的纯温度判定，不得阻塞 cover 决策。

### 需求 6：天气事件对洋流的瞬时扰动（可选项）

**用户故事：** 作为玩法设计者，我希望飓风/台风经过海域时，局部洋流出现短暂涡旋扰动，增强天气事件的"世界感"。

#### 验收标准

1. WHEN `WeatherSystem` 触发一个 tropical_cyclone 事件 THEN 系统 SHALL 向一个 CPU 端的 `ocean_current_perturbation: Dictionary{cell_id: Vector2}` 注入旋转扰动向量，持续 `CYCLONE_WAKE_DAYS`（默认 3 天）后线性衰减至 0。
2. WHEN shader 采样 ocean_current THEN 系统 SHALL 允许通过一个额外的 overlay uniform（RG8 小 buffer，默认全 0）把扰动叠加到主流场上，避免重烘全图。
3. IF 项目排期紧张且本需求被延后 THEN 系统 SHALL 仍然允许需求 1~5 独立上线，不产生耦合依赖。

### 需求 7：调试与可视化

**用户故事：** 作为程序/策划，我希望能一眼看出"哪里是暖流、哪里是上升流、热输运把多少度送到了陆地"，以便快速调试参数。

#### 验收标准

1. WHEN 玩家按 F6（现有 ocean_current_debug 开关） THEN shader SHALL 额外叠加一层上升流点的彩色高亮（例：黄色=上升、紫色=下沉）。
2. WHEN 玩家开启新增的 `F7 = ocean_heat_debug` 开关 THEN 系统 SHALL 在陆地 cell 上以红-蓝渐变叠加 `temperature_transport_anomaly`（正值偏红，负值偏蓝），视觉幅度 ±5°C 映射满饱和。
3. WHEN 这两个调试开关关闭 THEN 系统 SHALL 保证 shader 主路径零额外开销（通过 `#ifdef`-style 分支 + uniform 常量折叠，或提前 return）。

### 需求 8：性能与回退

**用户故事：** 作为技术负责人，我希望新增的热输运 pass 与季节重烘不拖慢大地图刷新，以便 4096×2048 级别地图仍保持可玩刷新率。

#### 验收标准

1. WHEN 地图规模 ≤ 中等（≤ 约 4096×2048 像素）THEN 季节重烘洋流的耗时 SHALL ≤ 原 bake_world 总耗时的 15%。
2. WHEN `_apply_ocean_heat_transport_pass` 运行 THEN 其总耗时 SHALL ≤ `refresh_climate_daily` 当前总耗时的 30%（以现有的 `print("refresh_climate_daily #%d: %dms ...")` 打点为基准）。
3. IF 上述性能预算被突破 THEN 系统 SHALL 支持通过 `MapConfig.enable_ocean_heat_transport: bool` 一键关闭该 pass，回退到旧行为（仅视觉洋流、无反馈）。
4. WHEN `enable_ocean_heat_transport = false` THEN 需求 3、4、5 中涉及反馈项的逻辑 SHALL 全部跳过，保持与主分支一致的温度/海冰/生物结果（回归测试可对比快照）。

### 需求 9：数据与接口约定

**用户故事：** 作为未来扩展（鱼群 AI、航运 AI）的对接方，我希望有稳定可读的 per-cell 洋流与营养数据 API，以便无须重新理解 bake 细节即可消费。

#### 验收标准

1. WHEN 其他系统调用 `HexCell.ocean_current` THEN 字段 SHALL 保持 `Vector2`，模长表示强度 ∈ [0, 1]，方向表示水平流向（GDScript +x 向东、+y 向南，与现有约定一致）。
2. WHEN 其他系统调用新增的 `HexCell.upwelling_strength` THEN 字段 SHALL 为 `float ∈ [-1, 1]`，正值表示上升流强度，负值表示下沉流强度。
3. WHEN 其他系统调用新增的 `HexCell.temperature_transport_anomaly` THEN 字段 SHALL 为 `float`，单位与 `temperature` 一致，表示由洋流输运带来的温度偏差（相对于该 cell 纬度基线温度）。
4. WHEN `WorldData` 被外部序列化保存 THEN 新增的 `ocean_upwelling_buffer` SHALL 和 `ocean_current_buffer` 在同一保存槽内，保证 load 后场景可重建。
