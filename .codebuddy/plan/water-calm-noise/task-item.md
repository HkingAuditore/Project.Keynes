# 实施计划 — 海面低对比度柔和噪声（Water Calm Noise）

> 基于 `.codebuddy/plan/water-calm-noise/requirements.md`。仅改动 `world_map.gdshader`、`hex_renderer.gd`、`main.gd` 三处文件；不触碰域扭曲、biome 软混合、波浪系统、菲涅尔、海岸浪花、焦散、洋流流纹等已有代码路径。

- [ ] 1. 新增 uniform 与 `@export` 参数桥接（骨架先行）
  - 在 `world_map.gdshader` 新增 uniform：`water_calm_noise_brightness : hint_range(0.0, 1.0) = 1.0`、`water_calm_noise_tint_strength : hint_range(0.0, 1.0) = 1.0`（两者分别控制亮度扰动层和色相扰动层的整体强度系数）
  - 保留既有 uniform `water_wave_line_strength`（语义改为"柔和噪声总开关/强度"，0 = 完全关闭，1 = 默认），在注释处明确新语义；粼光相关 uniform 无需新增（改参数即可）
  - 在 `hex_renderer.gd` 新增两个 `@export_range(0.0, 1.0, 0.01)` 字段与 setter，并在 `_sync_all_shader_params` / 初始化路径同步到 shader；`main.gd` 同步新增两个 `@export` 字段并在 `_apply_renderer_params` 里透传
  - _需求：4.1、4.2、4.3_

- [ ] 2. 替换 `water_shade_lines` 为大尺度柔和亮度噪声
  - 在 `world_map.gdshader` 中新增函数 `water_calm_brightness(vec2 wp, float t) -> float`：采样 `fbm(wp * 0.010 + vec2(t * 0.04, t * 0.02), 2)`，返回值域 `[-1, 1]`
  - 在原先调用 `water_shade_lines` 并按 `water_wave_line_strength` 混合到 `col` 的位置，改为：`col *= mix(1.0, 1.0 + calm * 0.08, water_wave_line_strength * water_calm_noise_brightness)`，保证总扰动上限 ±8%
  - 删除/旁路 `water_shade_lines` 旧的 3 层 sin 条纹叠加路径（函数本身可保留但不再被调用，避免破坏旧引用）
  - _需求：1.1、1.2、1.3、1.4、1.5_

- [ ] 3. 新增低对比度色相扰动层
  - 在 `world_map.gdshader` 中新增函数 `water_calm_tint(vec2 wp, float t) -> float`：采样 `fbm(wp * 0.006 + vec2(-t * 0.020, t * 0.025), 2)`，映射到 `[0, 1]` 作为 mix 因子
  - 定义两个常量 `const vec3 TINT_COLD = vec3(0.95, 0.98, 1.05)` 与 `const vec3 TINT_WARM = vec3(1.05, 1.02, 0.95)`，在亮度扰动叠加之后：`vec3 tint = mix(TINT_COLD, TINT_WARM, tint_mix); col *= mix(vec3(1.0), tint, 0.06 * water_calm_noise_tint_strength)`（±3% 上限）
  - 用 `if (visual_quality >= 1)` 包裹此段逻辑（低画质档直接跳过）；`visual_quality >= 2` 时将色相 fbm 的 octaves 参数提升到 3
  - _需求：2.1、2.2、2.3、2.4、2.5、4.4_

- [ ] 4. 降低高频粼光密度与强度
  - 修改 `world_map.gdshader` 粼光分支：`sparkle_freq` 从 `0.38` 改为 `0.18`；门槛 `smoothstep(0.70, 0.94, sparkle)` 改为 `smoothstep(0.82, 0.96, sparkle)`；`intensity` 从 `0.12` 改为 `0.06`
  - 保留 `water_sparkle_enabled` 开关契约不变（仍可完全关闭）
  - _需求：3.1、3.2、3.3_

- [ ] 5. 回归验证：不影响其它水体视觉要素
  - 手动检查改动 diff：确认 `water_biome_weights`、`water_domain_warp`、波浪 `wave_amp_scale` / `wave_freq_scale`、Blinn-Phong 菲涅尔、海岸浪花、珊瑚焦散、洋流流纹相关代码**完全未被触碰**
  - 在 Godot 编辑器打开场景，运行一次，确认海面呈现"淡淡的、大尺度、低对比度"噪声效果，无密集条纹与碎玻璃粼光；切换 `visual_quality = 0 / 1 / 2` 观察降级与增强档均正常
  - 切换 `water_wave_line_strength = 0` 与 `water_sparkle_enabled = false` 验证完整一键关
  - _需求：5.1、5.2、5.3、5.4、5.5、1.4、3.3_
