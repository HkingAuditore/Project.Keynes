# 实施计划 — 天气系统数据驱动重构

本计划将 8 种硬编码天气迁移为 `WeatherProfile` Resource 驱动。按"自底向上"顺序推进：
先定义资源类 → 产出数据资产 → 改造消费端 → 最后验证。每一步完成后项目应保持可运行、视觉零回归。

---

- [ ] 1. **定义 `WeatherProfile` 资源类**
   - 在 `res://Project/project-keynes/scripts/data/weather_profile.gd` 创建 `class_name WeatherProfile extends Resource`
   - 完整声明 4 组 `@export` 字段：身份/数值、粒子表现、overlay/云层、特殊效果开关
   - 每个字段给出合理默认值（默认为 CLEAR 的等价：`has_particles=false`、`has_overlay=false`）
   - _需求：1.1、1.2、1.3、1.4、1.5_

- [ ] 2. **美术化粒子贴图为 `.png` 资产**
   - 编写一次性 `@tool` 脚本（或在编辑器内执行 EditorScript），把 `_build_rain_drop_texture()` / `_build_snow_flake_texture()` 的像素数据 `save_png` 到 `res://Project/project-keynes/textures/weather/rain_drop.png` 与 `snow_flake.png`
   - 贴图尺寸与原函数输出一致（4×16 / 8×8）；保证 alpha 差异 ≤ 1
   - 执行后删除该一次性脚本（或归档到 `tools/`）
   - _需求：3.1、3.2_

- [ ] 3. **创建 8 份 `.tres` Profile 资产**
   - 在 `res://Project/project-keynes/data/weather/` 目录下新建 `clear.tres`、`rain.tres`、`storm.tres`、`blizzard.tres`、`drought.tres`、`fog.tres`、`heatwave.tres`、`monsoon.tres`
   - 数值严格对照现有 `weather_type.gd` 字典 + `_make_rain_process_material` / `_make_snow_process_material` + `_sync_shadow_pool` 分支填入
   - RAIN/STORM/MONSOON 复用雨粒子参数；BLIZZARD 用雪参数；CLEAR/DROUGHT/HEATWAVE 关粒子与 overlay；FOG 关粒子开 overlay
   - `particle_texture` 引用任务 2 产出的 `.png`
   - _需求：2.1、2.2、2.3、2.4、2.5、2.6、2.7、2.8、2.9、3.3_

- [ ] 4. **实现 `WeatherProfileRegistry` 注册表**
   - 在 `res://Project/project-keynes/scripts/data/weather_profile_registry.gd` 定义 `class_name WeatherProfileRegistry`
   - 提供静态方法 `get_profile(wt: int) -> WeatherProfile`、`get_all_profiles() -> Array[WeatherProfile]`（按 `WT` 枚举顺序返回 8 个）
   - 首次访问时 lazy-load 8 个 `.tres`，缓存进 `Dictionary[int, WeatherProfile]`
   - 加载失败或 key 缺失时返回 CLEAR 兜底 Profile 并 `push_warning`
   - _需求：4.1、4.2、4.3、4.4_

- [ ] 5. **改造 `weather_type.gd` 为薄 Facade**
   - 保留 `enum WT` 与 8 个静态方法签名（`name_cn` / `moisture_delta` / `temp_delta` / `can_form_snow` / `can_form_flood`）
   - 删除 `_MOISTURE_DELTA` / `_TEMP_DELTA` / `_CAN_FORM_SNOW` / `_CAN_FORM_FLOOD` / `_NAME_CN` 五个字典
   - 所有静态方法内部改为 `WeatherProfileRegistry.get_profile(w).XXX` 转发
   - _需求：8.1、8.2、8.3、8.4、4.5_

- [ ] 6. **改造 `weather_layer.gd` 的粒子配置数据化**
   - 删除 `_make_rain_process_material()` / `_make_snow_process_material()` 及 `_rain_process_material` / `_snow_process_material` 字段
   - 新增 `_build_process_material_from_profile(profile) -> ParticleProcessMaterial`，读取 profile 的 direction/spread/gravity/velocity/angular_velocity/scale/color 生成材质
   - 新增 `Dictionary[int, ParticleProcessMaterial]` 缓存，按 weather_type 复用材质
   - `_configure_particles_for_type` 改为从 profile 读 `amount / lifetime / texture / process_material`，消除 `if wt == _WT_BLIZZARD` 分支
   - `_sync_particles_pool` 中 amount 计算、`modulate.base_col` 改为读 profile 字段
   - 保留现有 TOD 染色与 `_rain_density_boost_enabled` 语义
   - _需求：5.1、5.2、5.3、5.4、5.5、5.6、5.7、3.4、3.5_

- [ ] 7. **改造 `weather_layer.gd` 的云阴影配置数据化**
   - `_sync_shadow_pool` 中"是否出云阴影"改为 `profile.has_cloud_shadow`
   - `modulate_col` 从 `profile.cloud_shadow_color` 读，删除 BLIZZARD/其他的硬编码分支
   - `modulate.a = intensity * profile.cloud_shadow_alpha_scale * _strength * night_scale`
   - 保留 TOD `night_scale` 逻辑
   - _需求：6.1、6.2、6.3、6.4_

- [ ] 8. **改造 `weather_overlay.gdshader` 为 uniform 数组驱动**
   - 新增 uniform `vec4 weather_profile_colors[8]`（rgb=overlay_color, a=overlay_base_alpha）与 `int weather_profile_flags[8]`（位编码：bit0=has_overlay, bit1=enables_lightning, bit2=enables_snow_grain, bit3=enables_rain_streak, bit4=enables_fog_breathe）
   - 在 shader 内定义 `FLAG_*` 常量
   - `sample_weather_at` 根据 `best_type` 从数组取 color/alpha，删除 RAIN/STORM/BLIZZARD/FOG/MONSOON 的连续 if-else
   - fragment 内的闪电/雪粒/雨纹/雾呼吸触发条件改为位运算判断 flags
   - 保留 TOD 染色、STORM 压暗 0.7、BLIZZARD 夜晚极光等二级修饰
   - 在 `WeatherLayer.setup` 中一次性推入 8 个 profile 的 colors/flags 数组
   - _需求：7.1、7.2、7.3、7.4、7.5、7.6_

- [ ] 9. **视觉回归自测脚本**
   - 新增 `res://Project/project-keynes/tests/weather_profile_regression_test.gd`（或 gdUnit test）
   - 枚举 8 种 WT，断言：`WeatherType.moisture_delta(wt)` / `temp_delta(wt)` / `can_form_snow(wt)` / `can_form_flood(wt)` 等于重构前的已知基准值（基准值以常量数组内联在测试里）
   - 断言：`WeatherProfileRegistry.get_profile(wt)` 不为 null 且 `weather_type == wt`
   - 在 `main.gd` 启动日志或 `_ready` 里添加一次性开发期断言（可通过 feature flag 关掉），方便手工验证
   - _需求：9.1、9.2、9.3、9.4、9.5、9.6、2.9_

- [ ] 10. **撰写 "如何新增天气" 指南**
   - 在 `.codebuddy/plan/weather-data-driven-refactor/howto-add-weather.md` 撰写 ≤ 100 行的简短指南
   - 列出 4 步：新建 `.tres` → `WeatherType.WT` 加枚举值 → `WeatherProfileRegistry` 注册路径 → 重启游戏
   - 提供虚构 SANDSTORM 示例展示 `.tres` 典型字段
   - 解释 `particle_density_per_px2` 等语义不明显字段的含义与典型取值
   - _需求：10.1、10.2、10.3_
