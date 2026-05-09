# 实施计划

- [ ] 1. 声明新 uniform 与安全默认值
   - 在 `shaders/world_map.gdshader` 水体相关 uniform 区域（靠近 `water_cartoon_color_strength` / `ocean_current_strength`）新增：`deep_ocean_color_richness`（总强度 0..1，默认 ~0.85）、`deep_ocean_current_tint_strength`（0..1，默认 ~0.6）、`deep_ocean_latitude_tint_strength`（0..1，默认 ~0.7）、`deep_ocean_abyss_tint_strength`（0..1，默认 ~0.6）、`deep_ocean_patch_boost`（0..1，默认 ~0.5）
   - 所有 uniform 均采用 `hint_range`，不重命名或删除已有参数
   - _需求：6.1, 6.2, 6.3, 6.4, 6.5_

- [ ] 2. 扩展 `water_depth_gradient()` 的三段主色调色板
   - 在现有 `shelf_col / mid_col / basin_col / abyss_col` 基础上，调大各段之间的色相差与饱和度对比，使 basin → abyss 段在色相上呈"暖蓝 → 冷紫"走势，且整体仍收敛于 `color_deep_ocean` 基色族
   - 在函数返回前做一次软回拉 `mix(result, color_deep_ocean, ≤0.15)` 作为保险带（风险 R1 的缓解）
   - 当 `water_cartoon_color_strength` 接近 0 时走最朴素等高线路径
   - _需求：1.1, 1.2, 1.3, 4.1, 4.2, 4.5_

- [ ] 3. 新增辅助函数 `deep_ocean_current_tint(oc, lat_signed, flow_mag)`
   - 放在 `water_depth_gradient` 附近，输入洋流向量 / 纬度 / 流速，返回一个 `vec3` 乘性 tint
   - 核心判据：`sign(-oc.y * lat_signed)` 判断"从低纬流向高纬（暖）"还是"从高纬流向低纬（冷）"（注意 Godot UV y 向下 ↔ 纬度方向的符号，用 `lat_signed` 已包含的符号方向一致化）
   - 暖流向 `vec3(1.04, 1.02, 0.94)` 方向、冷流向 `vec3(0.94, 1.00, 1.08)` 方向偏移
   - 当 `flow_mag < ~0.05` 或 `ocean_current_enabled == false` 时直接返回 `vec3(1.0)`
   - 振幅乘以 `deep_ocean_current_tint_strength * deep_ocean_color_richness`，并封顶在约 ±15% 内
   - _需求：2.1, 2.2, 2.3, 2.4, 6.5_

- [ ] 4. 新增辅助函数 `deep_ocean_latitude_tint(lat_signed, current_temp)`
   - 基于 `|lat_signed|` 得到"热带—温带—极地"权重（smoothstep）
   - 热带权重推向宝石绿松石（如 `vec3(0.92, 1.08, 1.04)`），极地权重推向冷青偏白（如 `vec3(0.96, 1.02, 1.12)`），温带为 `vec3(1.0)`
   - 以 `current_temp` 做二阶微调：温度越高越偏暖色方向（约 ±3%），使季节自然传导到海色
   - 总振幅乘以 `deep_ocean_latitude_tint_strength * deep_ocean_color_richness`，保证极地不伪装成冰色
   - _需求：3.1, 3.2, 3.3, 3.4, 3.5_

- [ ] 5. 新增辅助函数 `deep_ocean_abyss_tint(offshore_depth)`
   - 基于 `smoothstep(0.72, 1.0, offshore_depth)` 的深渊权重 `abyss_w`
   - 返回一个压暗 + 微蓝紫的乘性 tint（如 `mix(vec3(1.0), vec3(0.82, 0.90, 1.08) * 0.90, abyss_w)`）
   - 振幅乘以 `deep_ocean_abyss_tint_strength * deep_ocean_color_richness`，并随 `deep_ocean_contrast` 略微缩放
   - 不修改深渊区的 hue 过多，保持可辨识蓝调
   - _需求：4.1, 4.2, 4.3, 4.5_

- [ ] 6. 在 `fragment()` 开放海洋分支整合三层色偏（关键整合点）
   - 在现有 "gyre patch" 与 "deep_ripple/cartoon_chroma" 色彩层之后、"LAKE/REEF/KELP/ICE" 特征叠加之前，调用 3、4、5 三个辅助函数
   - 乘法叠加到 `col`，并由 `open_ocean_w` 作为作用范围 mask（浅海 / 海岸 / 湖 / 礁 / 藻 / 冰的像素自然衰减到 0）
   - 叠加顺序：latitude → current → abyss（幽冷作为最后的氛围层）
   - 最后统一做一次 `col = mix(col, water_depth_gradient(offshore_depth, elev), 0.0 ~ 0.10 * (1.0 - deep_ocean_color_richness))` 作为总回拉，确保 `deep_ocean_color_richness == 0` 时完全还原旧表现
   - _需求：1.1, 1.2, 1.4, 5.1, 5.2, 5.3, 5.4, 6.2_

- [ ] 7. 增强既有 gyre patch 的色相/饱和度分层
   - 在现有 `cobalt_patch / teal_patch / violet_patch` 混合中引入 `deep_ocean_patch_boost` 作为振幅加成
   - 让 `gyre_mix` 驱动的色斑在保持原动画频率（`world_time * 0.012` 等）前提下放大色相差，形成"半封闭海域 vs 开放大洋腹地"可辨识差异
   - 不新增 fbm 调用，只在原有 `gyre_a / gyre_b` 结果上做色调重映射
   - _需求：1.2, 1.4, 7.1_

- [ ] 8. `visual_quality` 分级降级策略
   - `visual_quality == 0`：禁用 current_tint、禁用任何 `world_time` 驱动的色彩层（沿用原有 gyre 静态分支）；保留 latitude_tint（静态版：温度项改用常量或 `lat_signed` 单独输入）+ abyss_tint 的静态部分 + 深度渐变
   - `visual_quality == 1`：启用 current_tint + abyss_tint；gyre 色相增强保持现有低频动画
   - `visual_quality == 2`：启用全部子层，允许最柔和的时间漂移（量级不超过 `world_time * 0.01`）
   - 通过 `if (visual_quality >= N)` 分支包裹对应代码段
   - _需求：1.5, 5.5, 7.1, 7.2, 7.3, 7.4_

- [ ] 9. 安全回退与边界保护
   - 在 current_tint 分支先检查 `length(ocean_current_v) > 0.05` 再生效（风险 R2 的缓解）
   - 在所有新增 tint 叠加处用 `clamp` 保证 `col` 各通道 ∈ [0, 某合理上限]，避免过曝
   - 若任一新增 uniform 或依赖量缺失（默认 0），代码路径不得产生 NaN / 纯黑 / 纯紫
   - 最终 `open_ocean_w` 门限：当其 < 0.05 时完全跳过新增计算分支，保护海岸 / 湖 / 礁交界（风险 R1 + 需求 5.1 / 5.4）
   - _需求：2.2, 2.5, 5.1, 5.4, 6.5, 7.5_

- [ ] 10. 目视验证与对比
   - 以 `deep_ocean_color_richness = 0` 和默认值两档加载同一测试地图截图对比，确认：(a) 0 时与改造前视觉一致；(b) 默认值下能清晰看到纬度色温带 / 洋流暖冷流 / 深渊幽冷 / 海盆间色斑差异
   - 切换 `visual_quality` 0/1/2 三档，确认分级降级行为符合需求 7 的约束，且均无闪烁 / 过曝 / 硬色环
   - 检查湖泊 / 河流 / 礁石 / 海草 / 海冰 / 海岸像素表现与改造前完全一致
   - _需求：1.*, 5.*, 7.5, 9（requirements.md 附加约束）_
