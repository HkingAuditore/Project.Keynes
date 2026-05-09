# 实施计划：外海视觉重平衡（Open Ocean Color Rebalance）

> 说明：本计划全部为对现有 `world_map.gdshader` 与 `hex_renderer.gd` 中已有 uniform / 默认值 / 调色函数的**重新配比**，不引入新模块、不增加新 fbm 调用。每个任务都需对照 `requirements.md` 验收标准；最终需通过手动目视回归（截图对比）+ `PerfSampler` 数据对比验证。

---

- [ ] 1. 重新配比基础海洋调色板（hypsometric base palette）
   - 在 `shaders/world_map.gdshader` 中调整 4 个 hypsometric 海洋色 uniform 的默认值：`color_deep_ocean` / `color_mid_ocean` / `color_shallow` / `color_coast_water`，把 R/G 通道相对 B 通道适度抬升、整体降饱和（目标 HSV S ≈ 0.45~0.60），同时保持 5 层亮度单调递减；同步修改 `scripts/rendering/hex_renderer.gd` 中对应的 `@export var color_deep_ocean / color_mid_ocean / color_shallow / color_coast_water` 默认值，确保 `_apply_uniforms()` 推送的是新默认值
   - 在每个修改处写"旧值 / 新值 / 视觉影响"三元组注释
   - _需求：1.1, 1.2, 1.4, 5.1, 5.4_

- [ ] 2. 弱化 `water_depth_gradient` 中的过饱和倍率系数
   - 调整 `water_depth_gradient` 函数内 `mid_col / basin_col / abyss_warm / abyss_cool` 的 `* vec3(...)` 倍率，去掉过强的"加蓝压红"系数（如 `vec3(0.88, 1.05, 1.18)`、`vec3(0.46, 0.60, 1.18)` 等），保留方向但收敛幅度
   - 调低末尾 `blue_shift / violet_shift` 的乘加权重（当前 0.20 / 0.12），目标使 basin/abyss 不再压成纯蓝
   - 保持 `pullback` safety band 逻辑不变，确保在 `richness_t = 0` 时仍是无操作
   - _需求：1.1, 1.2, 4.1, 4.2, 5.3_

- [ ] 3. 修正 `deep_ocean_abyss_tint` 的双重压暗问题
   - 在 `world_map.gdshader` 的 `deep_ocean_abyss_tint` 函数中，调整 `base_abyss_tint = vec3(0.82, 0.90, 1.08) * 0.90`，去掉外层 `* 0.90` 或将其提升到 ≥ 0.95，避免 abyss 段被乘法叠加压成灰蓝
   - 验证：abyss 段亮度（HSV V）相对 basin 段下降幅度应在 8%~15%，而非当前肉眼可感的 ≥ 20%
   - _需求：4.1, 4.2, 4.3_

- [ ] 4. 提升外海大尺度色斑（gyre patch）的振幅与可读性
   - 调整 shader 内 open ocean 分支中 `cobalt_patch / teal_patch / violet_patch` 三组色（包括 `_boost` 变体）的饱和度，使其平均饱和度对齐任务 1 的 base palette（避免 patch 比 base 还鲜艳）
   - 微调 `patch_w = open_ocean_w * water_cartoon_color_strength * mix(0.34, 0.58, gyre_mix)` 中的 mix 区间到约 `mix(0.42, 0.66, gyre_mix)`，让大色块更明显
   - 保持 fbm 频率（0.0056 / 0.012）与时间速率不变，避免引入"麻点感"或新的高频抖动
   - _需求：2.1, 2.2, 2.3, 6.1, 6.2_

- [ ] 5. 抬升 `water_calm_brightness` / `water_calm_tint` 默认强度
   - 在 `hex_renderer.gd` 调整 `@export` 默认 `water_calm_noise_brightness`（当前 0.70）与 `water_calm_noise_tint_strength`（当前 0.70）；视任务 4 后的实际观感，将这两个值提高到 ~0.85~1.00 之一即可，目的是让 ±5%/±2% 的扰动在新去饱和 base 上更可辨
   - 同步更新 shader 内 uniform 默认值，确保不依赖 CPU push 也能生效
   - _需求：2.1, 2.2, 2.4, 5.1_

- [ ] 6. 校准 `deep_ocean_latitude_tint` 默认强度并防止溢出
   - 调整 `hex_renderer.gd` 中 `@export var deep_ocean_latitude_tint_strength` 默认值（当前 0.70），按需求 3.1 让低/高纬色相差 Δhue ≥ 8°
   - 检查 `deep_ocean_latitude_tint` 函数中 tropical / polar tint 的 vec3，确保新的 base palette 之上叠乘后仍落在饱和度 [0.40, 0.62] 区间
   - _需求：3.1, 3.2, 3.4, 1.1_

- [ ] 7. 复核 `deep_ocean_current_tint` 与全局去饱和的协同
   - 不修改 current tint 的 warm/cold 方向，仅校准默认 `deep_ocean_current_tint_strength`（当前 0.60），确保暖流/寒流仍可辨（±10% 量级）但不与全局去饱和冲突
   - 验证 `flow_mag > 0.2` 区域的输出仍属于需求 1 的饱和度区间
   - _需求：3.3, 1.1_

- [ ] 8. 同步 `hex_renderer.gd` 的 setter 与 `_apply_uniforms()`
   - 检查所有被任务 1~7 修改默认值的 `@export` 字段，确认 `_apply_uniforms()`（约第 844~863 行附近）有对应 `set_shader_parameter` 行；如无则补齐
   - 检查每个相关字段是否有独立 setter（如 `set_deep_ocean_contrast` 同款风格）；若有则保持其 clamp 区间不变
   - 验证：把所有相关 export 在 Inspector 改回旧默认值时，输出与本次提交前完全一致（满足需求 5.3）
   - _需求：5.1, 5.2, 5.3_

- [ ] 9. 视觉回归与性能验证
   - 在 `scenes/main.tscn` 标准地图上跑 60×40 世界，`visual_quality = 2`：截取调整前后同一相机机位的外海截图（建议覆盖 a) 大块开阔海腹地、b) 海岸过渡带、c) 高纬冰边缘、d) 暖流穿越带 四个位置），逐项核对需求 1.1 / 2.1 / 3.1 / 4.1
   - 用 HexRenderer 的 `PerfSampler` 各跑 30 秒，记录 avg / P95 帧时，确认与改动前差异 ≤ ±5%（需求 6.1）
   - 切换 `visual_quality = 0` 验证不引入新 fbm 调用、不出现退化路径异常（需求 6.2, 2.4）
   - 若任意需求验收不达标，回到任务 1~7 微调对应系数后重测
   - _需求：1.1, 2.1, 3.1, 4.1, 6.1, 6.2_
