# 地块资源与物种分布视觉优化方案

## 当前状况分析

基于代码审查（`resource_visual_layer.gd`, `resource_visual_catalog.gd`, `resource_impostor.gdshader`），当前系统已具备：

### 已有优势
- ✅ 完整的51种资源目录（20生物 + 31资源）
- ✅ 分批次MultiMesh渲染（植物/动物/矿物/水下/贴花）
- ✅ 地形光照集成（horizon/GI/bent normal）
- ✅ GPU动态动画（植物摆动、动物行走、呼吸）
- ✅ 资源透镜系统（筛选时自动切换到识别徽章）
- ✅ 气候响应（活力/积雪/湿度）

### 核心问题
1. **美术辨识度不足**：程序化形状过于抽象，远景难以区分资源类型
2. **视觉层次感弱**：资源点缀与地形融合度低，缺乏"生长在地表"的自然感
3. **光影表现单一**：虽接入GI，但材质响应不够丰富，缺乏质感对比

---

## 优化方案

### 一、美术设计：形态识别性提升

#### 1.1 引入形态子样式系统

**目标**：在不增加纹理采样的前提下，通过shader程序化生成更具辨识度的形状

**实施位置**：`shaders/resource_impostor.gdshader`

```glsl
// 在现有 form (cereal/maize/rock等) 基础上，添加 sub_style 变体
// catalog.gd 的 sub_style 字段现在控制以下变体：

// 矿物形态变体（form=16 rock, 17 vein, 18 crystal）
vec3 mineral_shape(int form, int sub_style, vec2 uv, float seed) {
    if (form == 16) { // rock
        // sub_style: 0=块状 1=棱角 2=圆润 3=层状 4=碎裂
        float blockiness = mix(0.3, 0.9, float(sub_style) / 4.0);
        // 使用 Voronoi 边界 + 分形噪声模拟不同矿石纹理
    } else if (form == 17) { // vein 矿脉
        // 拉长的晶体簇或条带状结构
        float elongation = 2.0 + float(sub_style) * 0.5;
    } else if (form == 18) { // crystal 结晶
        // 明确的晶体几何（四面体/六面体/菱形）
        int crystal_faces = 4 + sub_style;
    }
}

// 植物形态变体（form=0-7）
vec3 plant_silhouette(int form, int sub_style, vec2 uv, float seed) {
    if (form == 0 || form == 1 || form == 2) { // 谷物类
        // sub_style: 0=紧凑穗 1=松散穗 2=弯垂穗
        float droop = float(sub_style) * 0.3;
        float density = 1.0 - float(sub_style) * 0.15;
    } else if (form == 6) { // tree 树木（橡胶树等经济树种）
        // 树冠形状：0=圆形 1=卵形 2=不规则
    }
}

// 动物剪影变体（form=8-14）
vec3 animal_pose(int form, int sub_style, vec2 uv, float time, float seed) {
    // sub_style 控制朝向、头部抬起角度、尾部位置
    float heading = seed * TAU;
    float head_lift = 0.2 + float(sub_style) * 0.15;
}
```

**数据层调整**：`resource_visual_catalog.gd`

```gdscript
# 为重要矿物分配不同 sub_style
["copper_ore", 2, 17, "4aa585", 1, 0.84, 0.78],  # 绿色氧化条带
["iron_ore", 2, 17, "a05a3c", 2, 0.78, 0.75],    # 赤铁矿块状
["gold_ore", 2, 17, "e0b840", 3, 0.96, 0.94],    # 金色晶簇
["coal", 2, 17, "25282b", 0, 0.88, 0.35],        # 黑色层状
```

#### 1.2 色彩对比度优化

**当前问题**：`palette_saturation = 0.80` 和 `luma_compress = 0.75` 压低了资源视觉存在感

**解决方案**：
```gdscript
# resource_visual_profile.gd 参数调整建议
@export_range(0.2, 1.0) var palette_saturation := 0.88  # 0.80 → 0.88 提升饱和度
@export_range(0.0, 1.0) var luma_compress := 0.60      # 0.75 → 0.60 保留更多明暗对比
@export var luma_range := Vector2(0.28, 0.72)           # 扩大 (0.24,0.64)→(0.28,0.72)
```

**配合 shader 端色调映射**：
```glsl
// resource_impostor.gdshader 中调整
// 为不同资源类别应用差异化的饱和度策略

vec3 apply_palette(vec3 base_color, int family, float palette_sat) {
    float sat_mul = 1.0;
    
    // 矿物：保持高饱和度突出特征色（铜绿、金黄、铁红）
    if (family == 2) {  
        sat_mul = 1.15;
    }
    // 植物：稍降饱和融入地表植被
    else if (family == 0) {
        sat_mul = 0.92;
    }
    // 动物：中性饱和，避免过于鲜艳
    else if (family == 1) {
        sat_mul = 0.85;
    }
    
    float luma = dot(base_color, vec3(0.2126, 0.7152, 0.0722));
    vec3 adjusted = mix(vec3(luma), base_color, palette_sat * sat_mul);
    return adjusted;
}
```

---

### 二、辨识度：视觉层次与空间感

#### 2.1 增强接地阴影与环境遮蔽

**当前状态**：`contact_shadow = 0.45`, `cast_shadow = 0.0` — 没有投影

**优化建议**：

```gdscript
# resource_visual_profile.gd
@export_range(0.0, 1.0) var contact_shadow := 0.68      # 0.45 → 0.68 加深接地暗部
@export_range(0.0, 1.0) var cast_shadow := 0.35        # 0.0 → 0.35 添加轻微投影
@export_range(0.0, 2.0) var shadow_softness := 0.75    # 新增：控制阴影边缘柔和度
```

**shader 实现**（基于现有 terrain_horizon 数据）：

```glsl
// resource_impostor.gdshader fragment()
// 已有 bent_normal 和 horizon 数据，复用计算软投影

// 1. 接地阴影（AO风格）
float ground_contact = smoothstep(0.0, 0.15, frag_height_local);  // 靠近地面时加深
float ao_term = mix(0.4, 1.0, ground_contact);

// 2. 定向软阴影（利用 sun_visibility）
float sun_vis = texture(gi_horizon_lut, horizon_uv).r;  // 太阳可见度
float shadow_term = mix(0.65, 1.0, sun_vis);  // 被山体遮蔽时压暗

// 3. 自身结构阴影（程序化）
float self_shadow = 1.0;
if (kind == KIND_PROP) {  // 立体主体才计算
    vec3 light_dir = normalize(sun_direction);
    float ndotl = dot(surface_normal, light_dir);
    // 背光面压暗，保留天空光
    self_shadow = mix(0.5, 1.0, ndotl * 0.5 + 0.5);
}

// 综合
vec3 shadowed = albedo * ao_term * shadow_term * self_shadow;
```

#### 2.2 边缘高光与质感对比

**问题**：所有资源的 specular/metallic 在 shader 中响应不足

**解决方案**：

```glsl
// 为不同材质类型实现差异化的光照响应

// 金属矿物（gold/silver/copper）
if (metallic > 0.6) {
    // 强反射，窄高光
    float roughness = 0.2;
    vec3 spec = pbr_specular(view_dir, sun_dir, surface_normal, roughness);
    albedo += spec * sun_color * specular * 1.5;
}

// 晶体/盐/硝石（高 specular，低 metallic）
else if (specular > 0.7 && metallic < 0.3) {
    // 边缘透光效果
    float rim = pow(1.0 - max(0.0, dot(view_dir, surface_normal)), 2.0);
    albedo += rim * sun_color * 0.4;
    // 表面闪烁（晶面）
    float sparkle = hash(floor(uv * 20.0 + time * 0.1));
    albedo += sparkle * 0.15 * step(0.95, sparkle);
}

// 植物/动物（低光泽）
else {
    // 柔和漫反射，保持材质柔软感
    float ndotl = max(0.0, dot(surface_normal, sun_dir));
    albedo *= mix(ambient_color, sun_color, ndotl * 0.6);
}
```

#### 2.3 轮廓强化（可选）

**适用场景**：高缩放级别或资源透镜模式

```gdscript
# resource_visual_profile.gd
@export_range(0.0, 1.0) var outline_strength := 0.25  # 0.0 → 0.25 添加轻微描边
@export_range(0.5, 3.0) var outline_width := 1.2      # 新增：描边宽度（像素）
@export var outline_color := Color(0.12, 0.10, 0.08, 0.6)  # 深棕半透明
```

```glsl
// shader 中使用 SDF 边界实现描边
float sdf = compute_shape_sdf(uv, form, sub_style);
float outline_mask = smoothstep(0.0, outline_width / screen_size.y, abs(sdf - 0.5));
vec3 outline = mix(albedo, outline_color.rgb, outline_mask * outline_strength);
```

---

### 三、光影表现：动态与氛围

#### 3.1 昼夜变化响应

**当前问题**：资源层接收 TOD 参数但响应较弱

**增强方案**：

```gdscript
# resource_visual_layer.gd prepare_frame() 中
# 已有 tod_sun_color, tod_ambient_color, tod_night_factor

# 传递更丰富的时段信息给 shader
_material.set_shader_parameter("is_golden_hour", 
    _day_phase > 0.15 and _day_phase < 0.25 or _day_phase > 0.75 and _day_phase < 0.85)
_material.set_shader_parameter("moon_phase", fmod(_season_phase * 12.0, 1.0))  # 月相
```

```glsl
// shader 中根据时段调整
uniform bool is_golden_hour;
uniform float moon_phase;

// 黄昏/黎明：金色调强化矿物反光
if (is_golden_hour && specular > 0.5) {
    albedo = mix(albedo, albedo * vec3(1.2, 1.05, 0.85), 0.3);
}

// 夜晚：月光下的银色高光（金属/晶体）
if (night_factor > 0.5 && metallic > 0.4) {
    float moon_brightness = 0.3 + moon_phase * 0.2;
    vec3 moon_highlight = vec3(0.8, 0.85, 1.0) * moon_brightness;
    albedo += moon_highlight * fresnel * night_factor;
}
```

#### 3.2 天气响应强化

**已有**：积雪、湿度响应
**增强**：

```glsl
// 雨天：植物/地力贴花变深，矿物表面反光增强
float wetness = clamp(climate.g - 0.5, 0.0, 0.5) * 2.0;  // 湿度 > 0.5 时

if (family == 0 || form == 22) {  // 植物/土壤
    // 湿润变暗
    albedo *= mix(1.0, 0.75, wetness);
} else if (family == 2 && specular > 0.5) {  // 矿物
    // 湿润时镜面反射增强
    specular *= 1.0 + wetness * 0.5;
}

// 积雪：保留现有逻辑，添加冰霜效果
if (climate.b > 0.3) {  // 有积雪
    float frost = (climate.b - 0.3) * 1.4;
    // 边缘冰晶
    float rim_frost = pow(1.0 - ndotv, 3.0) * frost;
    albedo = mix(albedo, vec3(0.95, 0.96, 1.0), rim_frost * 0.4);
}
```

#### 3.3 动态细节增强

**植物摆动**（已有基础，优化细节）：

```glsl
// 现有 wind_dir 和 weather_wind_boost
// 增加多频率叠加，避免"整体晃动"的僵硬感

float wind_phase = time * 2.0 + seed * TAU;
float wind_main = sin(wind_phase) * 0.5 + 0.5;  // 主频
float wind_gust = sin(wind_phase * 2.7 + 1.3) * 0.3;  // 阵风
float wind_detail = sin(wind_phase * 5.1 + 2.7) * 0.15;  // 细节抖动

float wind_total = (wind_main + wind_gust + wind_detail) * wind_strength * (1.0 + weather_wind_boost);

// 植物不同部位响应不同
if (form >= 0 && form <= 7) {  // 植物
    // 顶部摆动幅度大
    float height_factor = smoothstep(0.0, 1.0, uv.y);
    offset.x += wind_total * wind_dir.x * height_factor * 0.12;
}
```

**动物动作**（已有，增加变化）：

```glsl
// 添加"觅食"动作：头部低头-抬起循环
float feed_cycle = sin(time * 1.5 + seed * TAU) * 0.5 + 0.5;
float head_y_offset = mix(0.0, -0.08, feed_cycle * step(0.6, fract(seed * 7.13)));  // 60%时间在觅食

// 耳朵/尾巴独立抽动
float ear_twitch = step(0.98, fract(time * 3.0 + seed * 11.37));
```

---

### 四、实施优先级与验证

#### Phase 1: 立即改善（1-2天）
**无需 shader 改动，仅调参数**

1. **profile 参数调整**：
   ```gdscript
   palette_saturation: 0.80 → 0.88
   luma_compress: 0.75 → 0.60
   contact_shadow: 0.45 → 0.68
   outline_strength: 0.0 → 0.15  # 轻微描边
   ```

2. **catalog 色彩微调**：
   - 提高重要矿物的饱和度（铜绿、金黄）
   - 动物颜色加深 5-10%（提升对比度）

3. **验证**：运行 `resource_visual_render_regression.gd` 确保无退化

#### Phase 2: 形态识别增强（3-5天）
**需要 shader 改动**

1. 实现 `mineral_shape()` 函数族（矿物形态变体）
2. 实现 `plant_silhouette()` 函数（植物轮廓变体）
3. 更新 catalog 的 sub_style 值分配策略

**验证**：
```gdscript
# 新增测试：tests/resource_visual_form_variety_test.gd
# 渲染同类资源的所有 sub_style 变体，确认视觉差异 > 30%
```

#### Phase 3: 光照质感提升（3-4天）
**shader 核心改动**

1. 实现差异化 PBR 响应（金属/晶体/植物）
2. 增强接地阴影与自阴影
3. 添加边缘高光与透光效果

**验证**：
- 对比日出/正午/黄昏/夜晚四个时段截图
- 检查金矿在阳光下是否有明显反光
- 植物在雨天是否变暗

#### Phase 4: 动态细节优化（2-3天）
**可选，锦上添花**

1. 多频率风场叠加
2. 动物动作变体
3. 天气特效强化

---

### 五、性能考量

所有优化基于现有渲染架构，**不增加 draw call 或纹理采样**：

- ✅ 形态变体：纯程序化，通过 `sub_style` 整数控制
- ✅ 光照增强：复用现有 horizon/GI 数据
- ✅ 动态效果：在现有 GPU 动画基础上细化

**预期性能影响**：
- shader 复杂度增加约 15-20%
- 仍远低于地形 shader 的复杂度
- 移动端保持 LOW tier 的简化路径

**预算验证**：
```bash
# 运行性能测试
godot --headless -s Project/project-keynes/tests/resource_visual_perf_test.gd -- --large

# 对比优化前后的 P95 帧时：
# 目标：< 0.5ms 增量（当前 Xiaomi 15 预算 4ms，资源层应 < 10%）
```

---

### 六、配置文件示例

#### 优化后的 `resource_default.tres`

```gdscript
[resource]
script = ExtResource("1")
enabled = true
density_scale = 1.0

# 实例预算（保持现有）
desktop_instance_caps = PackedInt32Array([6000, 12000, 20000])
mobile_instance_caps = PackedInt32Array([1000, 2000, 4000])

# 视觉参数（优化）
palette_saturation = 0.88          # ↑ 从 0.80
luma_compress = 0.60               # ↓ 从 0.75
luma_range = Vector2(0.28, 0.72)   # 扩大范围
contact_shadow = 0.68              # ↑ 从 0.45
cast_shadow = 0.35                 # ↑ 从 0.0
outline_strength = 0.15            # ↑ 从 0.0

# 气候/动态（强化）
climate_response = 0.85            # ↑ 从 0.7
wind_strength = 0.45               # ↑ 从 0.35
animal_motion = 0.70               # ↑ 从 0.55

# 其他保持不变
```

---

### 七、预期效果对比

#### 优化前
- ❌ 矿物颗粒模糊，远景难辨认
- ❌ 动物/植物与地表"贴纸感"
- ❌ 缺乏日夜/天气带来的氛围变化
- ❌ 所有资源"扁平"，无质感差异

#### 优化后
- ✅ 铜矿有绿色条纹，金矿有金色反光，煤块有层状结构
- ✅ 动物有明确的接地阴影和轻微投影，"站在地上"
- ✅ 植物在风中有多层次摆动，雨天变暗
- ✅ 晶体在阳光下闪烁，夜晚有月光高光
- ✅ 远景仍可通过形状和光泽区分资源类别

---

## 附录：快速验证清单

优化后运行以下测试确认效果：

```bash
# 1. 形态一致性
godot -s tests/resource_visual_layer_test.gd

# 2. 渲染回归（17项GPU检查）
godot -s tests/resource_visual_render_regression.gd

# 3. 美术审查（导出所有资源造型）
godot -s tests/resource_visual_art_review.gd

# 4. 完整世界场景
godot -s tests/resource_visual_world_qa.gd

# 5. 性能验证
godot -s tests/resource_visual_perf_test.gd -- --large
```

检查输出图像：
- `tmp/resource_visual_qa/art_review_45.png` — 所有资源3×/6×/14×对照
- `tmp/resource_visual_qa/integration/*.png` — 17项渲染特性验证
- 对比优化前后，确认辨识度提升 > 40%
