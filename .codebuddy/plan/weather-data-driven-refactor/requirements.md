# 需求文档 — 天气系统数据驱动重构（WeatherProfile）

## 引言

当前 Project Keynes 的天气系统（[weather_type.gd](d:\Godot\ProjectKeynes\Project.Keynes\Project\project-keynes\scripts\weather_type.gd)、[weather_layer.gd](d:\Godot\ProjectKeynes\Project.Keynes\Project\project-keynes\scripts\rendering\weather_layer.gd)、[weather_overlay.gdshader](d:\Godot\ProjectKeynes\Project.Keynes\Project\project-keynes\shaders\weather_overlay.gdshader)）存在严重的**硬编码技术债**：

- 天气数值（湿度/温度扰动、是否结雪/结洪）作为 `const Dictionary` 写在 `weather_type.gd`
- 粒子参数（方向、重力、速度、颜色）通过 `_make_rain_process_material()` / `_make_snow_process_material()` 两个函数硬编码
- 粒子贴图（雨滴、雪花）通过 `_build_rain_drop_texture()` / `_build_snow_flake_texture()` 在运行时 `for` 循环逐像素生成
- overlay shader 内 `if (type == WT_RAIN) ...` 分支堆叠，云色、云透明度、闪电颜色等全部写死
- 云阴影配色（`modulate_col = Color(0.18, 0.20, 0.26)` 等）散落在 `_sync_shadow_pool` 中

**结果**：新增一种天气类型（如 "沙尘暴 SANDSTORM"）需要同时修改 3 个文件 + 写 shader 分支；美术 / 策划无法离开程序独立调整视觉与数值；也无法实现"热带雨 vs 寒带雨"这类地域差异化表现。

本次重构目标：引入 `WeatherProfile`（Resource 资源）作为单一数据源（Single Source of Truth），将上述所有硬编码参数抽离到 `.tres` 文件中，使得：

- 新增天气 = 新建一个 `.tres` 文件 + 在 `WeatherType.WT` 枚举加一行
- 美术 / 策划可在 Inspector 里直接调整所有视觉参数和数值
- 粒子贴图成为真正的 `.png` 美术资产而非运行时生成
- overlay shader 的天气分支收敛为"由 uniform 数组驱动的单一算法"，消除大段 `if-else`

**非目标**（本次不做）：
- 不改变天气玩法逻辑（锋面生成、漂移、合并、cell 扰动规则）
- 不切换 2D → 3D 渲染管线（保持现有 CanvasItem + GPUParticles2D）
- 不新增天气类型（仅完成对现有 8 种的等价迁移）
- 不修改 TOD（昼夜）/ weather_strength / `set_day_phase` 等已有对外接口签名
- 不改变 `WeatherFront` 数据结构（只读消费端，不动产生端）

**兼容性约束**：重构后所有 8 种现有天气（CLEAR / RAIN / STORM / BLIZZARD / DROUGHT / FOG / HEATWAVE / MONSOON）的视觉表现必须与当前版本**肉眼等价**（数值可有 ±2% 浮动），云阴影颜色、粒子密度上下限、闪电节拍等行为保持一致，以便在不影响玩家观感的前提下完成底层架构切换。

---

## 需求

### 需求 1 — WeatherProfile 资源定义

**用户故事：** 作为一名策划 / 美术，我希望每种天气的全部可调参数都由一个 `.tres` 资源文件描述，以便在 Godot Inspector 中直接编辑而无需改代码。

#### 验收标准

1. WHEN 工程中不存在 `WeatherProfile` 类 THEN 系统 SHALL 在 `res://scripts/data/weather_profile.gd` 创建一个 `class_name WeatherProfile extends Resource` 的新资源类。
2. WHEN `WeatherProfile` 被定义 THEN 系统 SHALL 提供以下 **身份与数值** 字段（`@export`）：`weather_type: int`（对应 `WeatherType.WT`）、`display_name: String`、`moisture_delta: float`、`temp_delta: float`、`can_form_snow: bool`、`can_form_flood: bool`。
3. WHEN `WeatherProfile` 被定义 THEN 系统 SHALL 提供以下 **粒子表现** 字段：`has_particles: bool`、`particle_texture: Texture2D`、`particle_amount_min: int`、`particle_amount_max: int`、`particle_density_per_px2: float`、`particle_lifetime: float`、`particle_direction: Vector3`、`particle_spread: float`、`particle_gravity: Vector3`、`particle_velocity_min: float`、`particle_velocity_max: float`、`particle_angular_velocity_min: float`、`particle_angular_velocity_max: float`、`particle_scale_min: float`、`particle_scale_max: float`、`particle_base_color: Color`。
4. WHEN `WeatherProfile` 被定义 THEN 系统 SHALL 提供以下 **overlay / 云层** 字段：`has_overlay: bool`、`overlay_color: Color`、`overlay_base_alpha: float`、`has_cloud_shadow: bool`、`cloud_shadow_color: Color`、`cloud_shadow_alpha_scale: float`（默认 0.55）。
5. WHEN `WeatherProfile` 被定义 THEN 系统 SHALL 提供以下 **特殊效果开关** 字段：`enables_lightning: bool`（STORM/MONSOON 打开）、`enables_snow_grain: bool`（BLIZZARD 打开）、`enables_rain_streak: bool`（RAIN/STORM/MONSOON 打开）、`enables_fog_breathe: bool`（FOG 打开）。
6. IF 用户在 Inspector 中修改某字段 THEN 该修改 SHALL 通过 `@export` 自动保存到 `.tres` 并被 Git 以文本 diff 形式记录。

### 需求 2 — 现有 8 种天气的 Profile 数据迁移

**用户故事：** 作为一名开发者，我希望现有 8 种天气的所有硬编码数值被原样迁移到独立的 `.tres` 文件中，以便在不改变玩家观感的前提下完成架构切换。

#### 验收标准

1. WHEN 需求 1 完成 THEN 系统 SHALL 在 `res://data/weather/` 目录下创建 8 个 Profile 资源文件：`clear.tres`、`rain.tres`、`storm.tres`、`blizzard.tres`、`drought.tres`、`fog.tres`、`heatwave.tres`、`monsoon.tres`。
2. WHEN 迁移 `rain.tres` THEN 系统 SHALL 按现有 `_make_rain_process_material()` 中的值填入：direction=(0.18, 1.0, 0)、gravity=(0, 280, 0)、velocity 220~320、color=(0.78, 0.86, 0.95, 0.85)、density_per_px2=0.00040、amount 180~900（boost 后）。
3. WHEN 迁移 `blizzard.tres` THEN 系统 SHALL 按现有 `_make_snow_process_material()` 中的值填入：direction=(0, 1, 0)、gravity=(0, 36, 0)、velocity 18~48、angular_velocity ±90、color=(0.96, 0.97, 1.0, 0.95)、density_per_px2=0.00030、amount 120~720（boost 后）。
4. WHEN 迁移 `storm.tres` / `monsoon.tres` THEN 系统 SHALL 复用与 rain 相同的粒子参数（这是现有行为），但 overlay_color / base_alpha 分别设为 `(0.22, 0.28, 0.40, 0.50)` 和 `(0.18, 0.24, 0.36, 0.58)`，并打开 `enables_lightning`。
5. WHEN 迁移 `clear.tres` / `drought.tres` / `heatwave.tres` THEN 系统 SHALL 将 `has_particles` 与 `has_overlay` 设为 false（行为等价于现有"不出粒子、不画 overlay"）。
6. WHEN 迁移 `fog.tres` THEN 系统 SHALL 设置 `has_particles=false`、`has_overlay=true`、`overlay_color=(0.82, 0.84, 0.88, 0.55)`、`enables_fog_breathe=true`、`has_cloud_shadow=false`。
7. WHEN 迁移 `blizzard.tres` / `rain.tres` / `storm.tres` / `monsoon.tres` THEN 系统 SHALL 设置 `has_cloud_shadow=true`，其中 BLIZZARD 的 `cloud_shadow_color=(0.88, 0.92, 0.96)`，其他三者 `cloud_shadow_color=(0.18, 0.20, 0.26)`（与现有 `_sync_shadow_pool` 分支一致）。
8. WHEN 迁移 `drought.tres` / `heatwave.tres` THEN 系统 SHALL 设置 `has_overlay=false`（因其视觉由 world_map.gdshader 的 multiplicative 调色负责，不经 overlay 层），但保留数值字段（moisture_delta、temp_delta）用于 cell 扰动。
9. WHEN 所有 8 份 `.tres` 创建完成 THEN 其数值 SHALL 与迁移前 `weather_type.gd` 的 `_MOISTURE_DELTA` / `_TEMP_DELTA` / `_CAN_FORM_SNOW` / `_CAN_FORM_FLOOD` 字典完全一致。

### 需求 3 — 粒子贴图美术化（脱离代码生成）

**用户故事：** 作为一名美术，我希望粒子贴图是真正的 `.png` 文件，以便我能直接用图像工具编辑而无需修改代码。

#### 验收标准

1. WHEN 进行贴图美术化 THEN 系统 SHALL 在 `res://textures/weather/` 目录下创建两个 `.png` 文件：`rain_drop.png`（4×16，替代 `_build_rain_drop_texture` 输出）、`snow_flake.png`（8×8，替代 `_build_snow_flake_texture` 输出）。
2. WHEN 生成 `rain_drop.png` 与 `snow_flake.png` THEN 两张贴图 SHALL 在像素级上与原代码生成结果等价（±1 alpha 误差可接受），以保证视觉零回归。
3. WHEN `WeatherProfile` 加载 THEN `particle_texture` 字段 SHALL 直接引用上述 `.png`，并通过 `@export var particle_texture: Texture2D` 在 Inspector 中可替换。
4. WHEN 迁移完成 THEN 系统 SHALL 从 [weather_layer.gd](d:\Godot\ProjectKeynes\Project.Keynes\Project\project-keynes\scripts\rendering\weather_layer.gd) 中移除 `_build_rain_drop_texture()` 与 `_build_snow_flake_texture()` 两个函数。
5. IF 某个 `WeatherProfile.particle_texture` 为 null 但 `has_particles=true` THEN 系统 SHALL 使用一个内置的 1×1 白色贴图作为兜底（避免空引用崩溃）。

### 需求 4 — WeatherProfileRegistry 注册表

**用户故事：** 作为一名开发者，我希望通过 `WeatherType.WT` 枚举值就能 O(1) 取到对应的 `WeatherProfile`，以便天气系统的消费端（WeatherLayer / WeatherSystem）无需关心资源路径。

#### 验收标准

1. WHEN 注册表被创建 THEN 系统 SHALL 在 `res://scripts/data/weather_profile_registry.gd` 定义一个 `class_name WeatherProfileRegistry` 的静态工具类。
2. WHEN 注册表首次被访问 THEN 系统 SHALL 通过 `ResourceLoader.load` 一次性加载 8 个 `.tres` 文件并缓存于 `Dictionary[int, WeatherProfile]`（key = `WeatherType.WT`）。
3. WHEN 调用 `WeatherProfileRegistry.get_profile(wt: int) -> WeatherProfile` THEN 系统 SHALL 返回对应 Profile；IF 未找到 THEN 系统 SHALL 返回 `CLEAR` 的 Profile 作为兜底并 `push_warning`。
4. WHEN 注册表初始化失败（某个 `.tres` 文件缺失或类型不符）THEN 系统 SHALL 保持游戏可运行（用兜底 Profile），并在 Output 打印清晰的错误信息。
5. WHEN `weather_type.gd` 的 `moisture_delta()` / `temp_delta()` / `can_form_snow()` / `can_form_flood()` 四个静态方法被调用 THEN 其内部实现 SHALL 改为通过 `WeatherProfileRegistry.get_profile(w).moisture_delta` 取值（保持方法签名不变，实现对调用方透明）。

### 需求 5 — WeatherLayer 粒子配置数据化

**用户故事：** 作为一名开发者，我希望 `weather_layer.gd` 的粒子配置逻辑由 `WeatherProfile` 驱动，以便新增天气类型时不需要新增 `_make_xxx_process_material` 函数。

#### 验收标准

1. WHEN `weather_layer.gd` 被改造 THEN 系统 SHALL 删除 `_make_rain_process_material()` 与 `_make_snow_process_material()` 两个函数，以及 `_rain_process_material` / `_snow_process_material` 两个字段。
2. WHEN `_sync_particles_pool` 判断某 front 需要出粒子 THEN 系统 SHALL 从 `WeatherProfileRegistry.get_profile(front.type)` 取参数并调用 `_build_process_material_from_profile(profile)` 生成 `ParticleProcessMaterial`。
3. WHEN 多个 slot 使用相同类型的天气 THEN 系统 SHALL 通过内部缓存 `Dictionary[int, ParticleProcessMaterial]`（key = weather_type）复用同一份 `ParticleProcessMaterial`（保持现有"避免 16 次 shader 编译"的性能优化）。
4. WHEN `_configure_particles_for_type` 被改造 THEN 系统 SHALL 从 profile 读取 `amount / lifetime / texture / process_material` 四者并赋给节点，不再出现 `if wt == _WT_BLIZZARD` 分支。
5. WHEN `_sync_particles_pool` 计算粒子数量 THEN 系统 SHALL 使用 `profile.particle_density_per_px2` 与 `profile.particle_amount_min / _max` 取代硬编码常量 `_RAIN_DENSITY_PER_PX2` 等（这些常量可保留作为全局兜底，但不再直接参与计算）。
6. WHEN `_sync_particles_pool` 计算 `modulate` 的 `base_col` THEN 系统 SHALL 使用 `profile.particle_base_color` 取代硬编码的 `Color(0.85, 0.88, 0.96)` / `Color(0.96, 0.97, 1.00)`。
7. WHEN 粒子数据化完成 THEN 现有 TOD 染色逻辑（`tod_sun_color * (1 - 0.5*night_factor)`）SHALL 保持不变（作用在 `profile.particle_base_color` 上）。

### 需求 6 — WeatherLayer 云阴影配置数据化

**用户故事：** 作为一名美术，我希望云阴影的颜色、透明度缩放全部来自 `WeatherProfile`，以便我能在 Inspector 里独立调整每种天气的阴影外观。

#### 验收标准

1. WHEN `_sync_shadow_pool` 判断某 front 是否出云阴影 THEN 系统 SHALL 使用 `profile.has_cloud_shadow` 取代现有 `wt == _WT_DROUGHT or wt == _WT_HEATWAVE or wt == _WT_FOG or wt == _WT_CLEAR` 的硬编码排除。
2. WHEN `_sync_shadow_pool` 计算 `modulate_col` THEN 系统 SHALL 使用 `profile.cloud_shadow_color` 取代 `if wt == _WT_BLIZZARD ... else ...` 的硬编码分支。
3. WHEN `_sync_shadow_pool` 计算 `modulate.a` THEN 系统 SHALL 使用 `f.intensity * profile.cloud_shadow_alpha_scale * _strength * night_scale`，其中 `cloud_shadow_alpha_scale` 默认 0.55（保持与现有数值一致）。
4. WHEN 云阴影数据化完成 THEN 现有 TOD `night_scale = 1 - 0.8 * _tod_night_factor` 逻辑 SHALL 保持不变。

### 需求 7 — Overlay Shader 天气分支数据化（uniform 数组）

**用户故事：** 作为一名开发者，我希望 overlay shader 里 `if (type == WT_RAIN) ... else if (type == WT_STORM) ...` 的分支堆叠被替换为由 CPU 侧推入的 uniform 数组驱动，以便新增天气时不需要改 shader 源码。

#### 验收标准

1. WHEN overlay shader 被改造 THEN 系统 SHALL 新增两个 uniform 数组：`weather_profile_colors[MAX_WEATHER_TYPES]`（vec4，rgb=overlay_color + a=overlay_base_alpha）和 `weather_profile_flags[MAX_WEATHER_TYPES]`（int，按位编码 enables_lightning / enables_snow_grain / enables_rain_streak / enables_fog_breathe / has_overlay 五个标志），其中 `MAX_WEATHER_TYPES = 8`。
2. WHEN `WeatherLayer.setup` 或 profile 加载完成时 THEN 系统 SHALL 从 `WeatherProfileRegistry` 读取 8 个 profile 并一次性推入上述两个 uniform 数组（每局游戏只需推一次）。
3. WHEN shader 的 `sample_weather_at` 需要确定云颜色 THEN 它 SHALL 通过 `weather_profile_colors[best_type]` 取值，取代现有的 `if (best_type == WT_RAIN) col = vec3(0.45, 0.55, 0.70) ...` 的连续 if 分支。
4. WHEN shader 的 fragment 判断是否启用闪电 / 雪粒 / 雨纹 / 雾呼吸 THEN 它 SHALL 通过 `(weather_profile_flags[w.type] & FLAG_XXX) != 0` 位运算判断，取代硬编码的 `w.type == WT_STORM || w.type == WT_MONSOON`。
5. WHEN shader 数据化完成 THEN 现有 TOD 染色（`col * tod_sun_color * (1 - 0.6*night_factor) + tod_ambient_color * 0.3`）、STORM 压暗 0.7、BLIZZARD 夜晚极光提示等"二级修饰"逻辑 SHALL 保持不变（仍写在 shader 内，只不过其"触发条件"改由 flags 驱动）。
6. IF profile uniform 数组未被推入（如开发期 hot-reload 异常）THEN shader SHALL 回退到使用一个"不可见"的默认值（alpha=0）而非崩溃或花屏。

### 需求 8 — weather_type.gd 瘦身与向后兼容

**用户故事：** 作为一名开发者，我希望 `weather_type.gd` 在重构后成为一个薄的 Facade，只保留枚举与对 Registry 的转发，以便将来进一步简化。

#### 验收标准

1. WHEN `weather_type.gd` 被改造 THEN 系统 SHALL 保留 `enum WT` 不变（含 8 个枚举值和顺序）。
2. WHEN `weather_type.gd` 被改造 THEN 系统 SHALL 删除 `_MOISTURE_DELTA` / `_TEMP_DELTA` / `_CAN_FORM_SNOW` / `_CAN_FORM_FLOOD` / `_NAME_CN` 五个常量字典（数据源迁移到 Profile）。
3. WHEN `weather_type.gd` 被改造 THEN 系统 SHALL 保留 `name_cn()` / `moisture_delta()` / `temp_delta()` / `can_form_snow()` / `can_form_flood()` 五个静态方法的签名，但其实现改为转发到 `WeatherProfileRegistry.get_profile(w)` 的对应字段。
4. WHEN 其他脚本（如 WeatherSystem、UI 面板）调用 `WeatherType.moisture_delta(wt)` 等方法 THEN 其行为 SHALL 与重构前完全一致（无需修改调用方代码）。

### 需求 9 — 视觉回归验证

**用户故事：** 作为一名玩家 / QA，我希望重构前后在同一张地图、同一套天气锋面下，视觉效果看起来完全一致，以确保重构未引入回归 bug。

#### 验收标准

1. WHEN 重构完成后运行游戏 THEN 同时刻同位置的 RAIN / STORM / BLIZZARD / MONSOON / FOG 云层颜色 SHALL 与重构前肉眼无差异（截图叠加 `difference` 模式后整体亮度差异 < 3%）。
2. WHEN 重构完成后运行游戏 THEN 粒子数量、运动方向、颜色、生命周期 SHALL 与重构前完全一致（同类型 front 相同 radius 下 amount 差异 ≤ 1）。
3. WHEN 重构完成后运行游戏 THEN STORM 闪电节拍（频率 < 1Hz、持续 80~120ms）SHALL 与重构前完全一致。
4. WHEN 重构完成后运行游戏 THEN 云阴影的颜色、alpha、形状 SHALL 与重构前完全一致。
5. WHEN 重构完成后运行游戏 THEN TOD（昼夜）染色在云层 / 粒子 / 阴影三处的表现 SHALL 与重构前完全一致。
6. WHEN 执行 `weather_system.gd` 的现有单元测试（若存在） THEN 测试 SHALL 全部通过；IF 现有测试覆盖不足 THEN 系统 SHALL 至少补充一个简单的自测脚本，打印 8 种天气在同一 cell 的 moisture_delta / temp_delta，与重构前的基准值对比。

### 需求 10 — 文档与示例

**用户故事：** 作为一名团队新成员，我希望看到一份清晰的"如何新增一种天气"文档，以便我能在不阅读所有源码的情况下独立完成。

#### 验收标准

1. WHEN 重构完成 THEN 系统 SHALL 在 `res://data/weather/README.md`（或 `.codebuddy/plan/weather-data-driven-refactor/howto-add-weather.md`）提供一份不超过 100 行的简短指南，描述"新增一种天气类型"的完整步骤：新建 `.tres` → 在 `WeatherType.WT` 枚举加值 → 在 `WeatherProfileRegistry` 注册路径 → 重启游戏。
2. WHEN 新增天气指南被撰写 THEN 其 SHALL 包含一个完整的示例（例如虚构的 "SANDSTORM 沙尘暴"），展示 `.tres` 的典型字段填写。
3. IF 某字段的语义不明显（如 `particle_density_per_px2`） THEN 指南 SHALL 提供一句话解释其含义与典型取值。

---

能否进入任务规划阶段？
