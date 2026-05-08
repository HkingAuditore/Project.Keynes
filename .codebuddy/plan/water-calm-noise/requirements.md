# 需求文档：海面低对比度柔和噪声（Water Calm Noise）

## 引言

当前水体渲染（由上一轮 ShaderToy 启发改造引入）在海面上叠加了两层高频视觉元素：
1. `water_shade_lines`：由三个方向正弦带叠加提取的"横向波痕条纹"（`water_wave_line_strength = 0.35`）。
2. `water_sparkle`：基于 `fbm(wp * 0.38 + world_time * 0.85, 2)` 的高频粼光。

两者共同作用下，海面布满密集、规整、细碎的亮点与条纹，视觉上非常刺眼（见用户截图：黑色海面被"点阵纸"覆盖）。用户要求将这些**高频密集纹理**替换为**大尺度、低对比度的柔和颜色噪声**，让海面在保留动态感的同时回到沉稳、耐看的风格。

本需求的目标不是"推倒重来"，而是在现有水体着色管线（软混合 + 统一波浪 + 光照 + 条纹 + 粼光 + 焦散）里**替换**其中的"条纹 / 粼光"两层为一层**柔和噪声**，并保持其它视觉要素（离岸梯度、Blinn-Phong 菲涅尔、海岸浪花、珊瑚焦散、洋流流纹、biome 软混合）不变。

## 需求

### 需求 1：替换高频条纹为大尺度柔和噪声

**用户故事：** 作为玩家，我希望海面不再布满密集刺眼的横向条纹，而是呈现淡淡的、像云影一样缓慢起伏的明暗变化，以便长时间观察地图时眼睛不会疲劳。

#### 验收标准

1. WHEN `water_shade_lines` 当前的 3 层 sin band 叠加被执行时 THEN shader SHALL 默认将其旁路（不再叠加到水面颜色上），由新的"柔和噪声层"取代。
2. WHEN 新的柔和噪声层被计算时 THEN shader SHALL 使用 **大尺度 fbm**（频率缩放 `0.006 ~ 0.015`，约为原条纹频率 `0.75 / 1.35 / 2.10` 的 1/100 量级），使单个"亮/暗斑块"覆盖至少 30~80 hex 的空间跨度。
3. WHEN 柔和噪声层叠加到颜色上时 THEN shader SHALL 仅以"亮度倍率"形式扰动 `col`，振幅范围 SHALL `[0.92, 1.08]`（即 ±8% 以内），不得产生高对比亮线或暗边。
4. WHEN 用户在 Inspector 调节 `water_wave_line_strength = 0` 时 THEN shader SHALL 完全关闭柔和噪声层，恢复到"无条纹、无噪声"的纯净海面。
5. IF `water_wave_line_strength` 仍被赋值 `> 0` THEN shader SHALL 将其作为柔和噪声层的整体强度系数（0 = 关闭，1 = 最强 ±8%）。

### 需求 2：水面颜色低对比度色相扰动

**用户故事：** 作为玩家，我希望海洋不再是一整片近乎单色的深蓝色（或上轮过渡后的离岸梯度），而是能看到极其微妙的冷暖/青蓝起伏，像真实海洋从不同角度反射天空时那种细腻变化。

#### 验收标准

1. WHEN 水面最终颜色 `col` 计算完成后 THEN shader SHALL 叠加一层**色相偏移**，该偏移基于与亮度噪声**不同频率、不同相位**的第二层 fbm，以避免亮暗和色相完全同步。
2. WHEN 色相偏移被应用时 THEN shader SHALL 在两个预设颜色之间做 mix：`cold_tint = vec3(0.95, 0.98, 1.05)`（偏冷蓝）与 `warm_tint = vec3(1.05, 1.02, 0.95)`（偏暖绿/青），mix 因子 ∈ `[0, 1]`。
3. WHEN 该色相偏移以倍率形式乘到 `col` 上时 THEN 其整体强度 SHALL 被限制为**最大 ±3%**（即 `col *= mix(vec3(1.0), tint, 0.06)` 或等价写法），保证"低对比度"。
4. IF `visual_quality == 0` THEN 色相偏移层 SHALL 被跳过，只保留亮度噪声层，保证低画质档性能与现状一致。
5. WHEN 色相偏移的 fbm 采样坐标带有 `world_time` 项时 THEN 其推进速度 SHALL **低于亮度噪声**（建议 `0.015 ~ 0.03`，约为亮度噪声速度的一半），让色相变化比亮度变化更缓慢，营造"呼吸感"。

### 需求 3：降低/移除水面高频粼光密度

**用户故事：** 作为玩家，我希望即便在白天、高画质下，海面粼光也不再像撒满碎玻璃那样密集刺眼。

#### 验收标准

1. WHEN `water_sparkle_enabled == true` 且 `visual_quality >= 1` 时 THEN shader SHALL 将粼光采样频率从 `0.38` 降到 **`≤ 0.18`**（约 1/2），使单颗粼光覆盖更大区域。
2. WHEN 粼光亮度扰动被叠加到 `col` 时 THEN 其整体 `intensity` SHALL 从当前 `0.12` 降低到 **`≤ 0.06`**（即 ±6% 上限），并且门槛 `smoothstep(0.70, 0.94, sparkle)` SHALL 收紧为 `smoothstep(0.82, 0.96, sparkle)`，减少"点阵感"。
3. IF 用户希望完全关闭粼光 THEN 已有的 `water_sparkle_enabled = false` 开关 SHALL 继续生效，不得改变其行为契约。

### 需求 4：参数可调与向后兼容

**用户故事：** 作为开发者，我希望新噪声层的"亮度幅度"与"色相幅度"在 Inspector 中独立可调，以便根据后续视觉反馈快速迭代，且旧场景文件不因字段删除而报错。

#### 验收标准

1. WHEN 新增两个 uniform `water_calm_noise_brightness` 与 `water_calm_noise_tint_strength` 时 THEN `HexRenderer` / `main.gd` SHALL 同步新增两个 `@export_range` 字段与对应 setter。
2. WHEN 旧的 `water_wave_line_strength` 字段已存在 THEN 本次 SHALL 保留该 uniform（重用为"柔和噪声总开关 / 强度"），**不得**直接删除 — 以免现有 .tscn 反序列化警告；其语义从"横向条纹强度"改为"柔和噪声强度"，并在注释与 Inspector tooltip 中注明。
3. WHEN 代码 lint 后 THEN shader / `hex_renderer.gd` / `main.gd` 三个文件 SHALL 无任何编译或类型错误。
4. IF 玩家在运行时切换 `visual_quality` THEN 对应的降级路径 SHALL 保持有效：`visual_quality == 0` 跳过色相层、`visual_quality >= 1` 启用亮度层、`visual_quality >= 2` 同时启用色相层更高精度 fbm（octaves 2 → 3）。

### 需求 5：不影响其它水体视觉要素

**用户故事：** 作为开发者，我希望本次修改仅针对"密集条纹"与"高频粼光"两层，不得影响离岸梯度、biome 软混合、Blinn-Phong 菲涅尔高光、海岸浪花、珊瑚焦散、洋流流纹等已在本周迭代中落地的特性。

#### 验收标准

1. WHEN `water_biome_blend_radius > 0` 时 THEN biome 软混合逻辑 SHALL 保持原样，本次修改不得涉及 `water_biome_weights` 函数。
2. WHEN `water_domain_warp_strength > 0` 时 THEN 域扭曲 `water_domain_warp` 函数 SHALL 保持原样。
3. WHEN 水面波浪（顶点位移 / 法线 / 菲涅尔）计算时 THEN `wave_amp_scale` / `wave_freq_scale` / Blinn-Phong 相关代码 SHALL 保持原样，不得调整振幅或频率参数。
4. WHEN 海岸白浪（foam）计算时 THEN 其代码 SHALL 保持原样。
5. WHEN 洋流流纹（`ocean_current_strength`）计算时 THEN 其代码 SHALL 保持原样。
