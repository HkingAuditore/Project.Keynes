# 如何新增一种天气（How to add a weather type）

重构后，新增一种天气只需 4 步、不需要改动 Shader 或 WeatherLayer 的任何分支逻辑。

## 步骤

### 1. 在 `WeatherType.WT` 枚举加一行

编辑 [weather_type.gd](../../Project/project-keynes/scripts/weather_type.gd)：

```gdscript
enum WT {
    CLEAR, RAIN, STORM, BLIZZARD, DROUGHT, FOG, HEATWAVE, MONSOON,
    SANDSTORM,  # ← 新增
}
```

### 2. 创建 `.tres` 资源文件

在 `Project/project-keynes/data/weather/` 下新建 `sandstorm.tres`（参考 [rain.tres](../../Project/project-keynes/data/weather/rain.tres) 格式）：

```tres
[gd_resource type="Resource" script_class="WeatherProfile" load_steps=3 format=3]

[ext_resource type="Script" path="res://scripts/data/weather_profile.gd" id="1"]
[ext_resource type="Texture2D" path="res://textures/weather/sand_grain.png" id="2"]

[resource]
script = ExtResource("1")
weather_type = 8                        ; 必须与枚举值对齐
display_name = "沙尘暴"
moisture_delta = -0.12                  ; 沙尘暴是干风
temp_delta = 0.04
can_form_snow = false
can_form_flood = false
has_particles = true
particle_texture = ExtResource("2")
particle_amount_min = 200
particle_amount_max = 800
particle_density_per_px2 = 0.00035
particle_lifetime = 2.2
particle_direction = Vector3(0.6, 0.3, 0)   ; 水平为主、略下沉
particle_spread = 18.0
particle_gravity = Vector3(0, 20, 0)
particle_velocity_min = 120.0
particle_velocity_max = 240.0
particle_angular_velocity_min = -40.0
particle_angular_velocity_max = 40.0
particle_scale_min = 0.6
particle_scale_max = 1.2
particle_base_color = Color(0.92, 0.78, 0.55, 0.90)   ; 沙黄
has_overlay = true
overlay_color = Color(0.85, 0.70, 0.45, 1)
overlay_base_alpha = 0.45
has_cloud_shadow = true
cloud_shadow_color = Color(0.52, 0.42, 0.28, 1)
cloud_shadow_alpha_scale = 0.50
enables_lightning = false
enables_snow_grain = false
enables_rain_streak = false
enables_fog_breathe = false
```

### 3. 在 `WeatherProfileRegistry` 注册路径

编辑 [weather_profile_registry.gd](../../Project/project-keynes/scripts/data/weather_profile_registry.gd)：

```gdscript
const _PROFILE_PATHS: Dictionary = {
    0: "res://data/weather/clear.tres",
    ...
    7: "res://data/weather/monsoon.tres",
    8: "res://data/weather/sandstorm.tres",  # ← 新增
}
```

同时把 `MAX_WEATHER_TYPES` 在 Shader 与 `_MAX_WEATHER_TYPES` 在 WeatherLayer 中同步到 `9`：
- `Project/project-keynes/shaders/weather_overlay.gdshader`：`const int MAX_WEATHER_TYPES = 9;`
- `Project/project-keynes/scripts/rendering/weather_layer.gd`：`const _MAX_WEATHER_TYPES := 9`

### 4. 重启 Godot 编辑器并运行

注册表是 lazy-load 的，但 Godot 的 `class_name` 缓存可能需要重启编辑器一次才能识别新枚举值。

## 字段语义速查

| 字段 | 含义 | 典型取值 |
|---|---|---|
| `particle_density_per_px2` | 每 px² 的粒子数。`amount = clamp(area * density, min, max)` | 雨类 0.0004；雪类 0.0003；沙尘 0.0003~0.0005 |
| `particle_amount_min / _max` | 粒子数量上下限，防止极小/极大 front 视觉崩坏 | 中等强度 120~800 |
| `overlay_base_alpha` | Shader 内覆盖层基础不透明度，最终 alpha = base_alpha × cloud_coverage × strength | 雨 0.32、雾 0.55、雷暴 0.50、雪暴 0.55 |
| `cloud_shadow_alpha_scale` | 云阴影最大 alpha；实际 alpha = intensity × scale × strength × night_factor | 一般 0.50~0.55 |
| `enables_lightning` | shader 在陆地上触发短暂闪电高光 | STORM/MONSOON 为 true |
| `enables_snow_grain` | shader 叠加高频白点颗粒感 | BLIZZARD 为 true |
| `enables_rain_streak` | shader 沿 (-0.45,1.0) 方向叠加雨纹 | RAIN/STORM/MONSOON 为 true |
| `enables_fog_breathe` | shader 让 alpha 随 `sin(t*0.6)` 轻微呼吸 | FOG 为 true |

## 如果要新增自定义特效（如沙尘扭曲）

`enables_*` 位最多 32 位（单个 int）。在 shader 中追加一个新的 `FLAG_SANDSTORM_DIST = 32` 常量与对应的 if 分支，在 `WeatherProfile` 里加 `@export var enables_sandstorm_distortion: bool`，在 `_push_weather_profile_uniforms_to_overlay` 里把它打进 flags bit 即可。
