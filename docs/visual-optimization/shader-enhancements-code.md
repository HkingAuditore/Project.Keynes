# Resource Impostor Shader 优化代码片段

本文档包含可直接集成到 `resource_impostor.gdshader` 的代码片段。

## 1. 形态生成函数（插入到 fragment() 之前）

```glsl
// ===== 矿物形态变体 =====
// 基于 sub_style 生成不同的矿物纹理和形状
vec3 get_mineral_detail(int form, int sub_style, vec2 uv, float seed) {
    vec3 detail = vec3(1.0);
    
    if (form == 17) {  // vein 矿脉
        // 条带状纹理
        float vein_freq = 8.0 + float(sub_style) * 4.0;
        float vein_pattern = sin(uv.x * vein_freq + seed * 6.28) * 0.5 + 0.5;
        // 添加次级条纹
        float detail_pattern = sin(uv.x * vein_freq * 2.3 + uv.y * 5.7) * 0.3 + 0.7;
        detail = vec3(vein_pattern * detail_pattern);
        
    } else if (form == 18) {  // crystal 晶体
        // 晶面反射效果
        vec2 crystal_uv = fract(uv * (3.0 + float(sub_style)));
        float facet = step(0.5, crystal_uv.x) + step(0.5, crystal_uv.y);
        facet = clamp(facet, 0.0, 1.0);
        // 晶体边缘高光
        float edge = 1.0 - smoothstep(0.45, 0.55, length(crystal_uv - 0.5));
        detail = vec3(0.8 + facet * 0.2 + edge * 0.3);
        
    } else if (form == 16) {  // rock 岩石
        // Voronoi 噪声模拟矿石纹理
        vec2 cell = floor(uv * 10.0);
        vec2 local = fract(uv * 10.0);
        float min_dist = 1.0;
        for (int y = -1; y <= 1; y++) {
            for (int x = -1; x <= 1; x++) {
                vec2 neighbor = vec2(float(x), float(y));
                vec2 point = hash22(cell + neighbor);
                float dist = length(neighbor + point - local);
                min_dist = min(min_dist, dist);
            }
        }
        // sub_style 控制颗粒大小
        float grain_size = mix(0.8, 0.3, float(sub_style) / 4.0);
        detail = vec3(smoothstep(grain_size, grain_size + 0.2, min_dist));
    }
    
    return detail;
}

// ===== 植物轮廓增强 =====
float get_plant_density_modifier(int form, int sub_style, vec2 uv, float seed) {
    if (form >= 0 && form <= 2) {  // 谷物类
        // sub_style 控制穗密度
        float density_base = 0.7 + float(sub_style) * 0.1;
        // 添加不规则度
        float noise = hash(vec2(seed, uv.x * 10.0)) * 0.2;
        return density_base + noise;
    }
    return 1.0;
}

// ===== 动物姿态变体 =====
vec2 get_animal_offset(int form, int sub_style, float time, float seed) {
    // sub_style 影响朝向和动作幅度
    float heading = seed * 6.28;
    float motion_scale = 0.8 + float(sub_style) * 0.1;
    
    // 行走周期
    float walk_cycle = fract(time * 0.5 + seed) < 0.4 ? 1.0 : 0.0;  // 40%时间在走
    float walk_phase = time * 2.0 + seed * 6.28;
    
    vec2 offset = vec2(0.0);
    if (walk_cycle > 0.5) {
        offset.x = sin(walk_phase) * 0.03 * motion_scale;
        // 头部点动
        offset.y = abs(sin(walk_phase * 2.0)) * 0.02;
    }
    
    return offset;
}
```

## 2. 光照响应优化（在 fragment() 主体中）

```glsl
// ===== 差异化材质光照 =====
// 插入到现有 albedo 计算之后，ambient/sun 混合之前

// 1. 基础参数
float ndotl = max(0.0, dot(surface_normal, sun_direction));
float ndotv = max(0.0, dot(surface_normal, view_direction));
vec3 half_vec = normalize(sun_direction + view_direction);
float ndoth = max(0.0, dot(surface_normal, half_vec));

// 2. 金属矿物高光（gold/silver/copper: metallic > 0.6）
if (metallic > 0.6) {
    float roughness = 0.25;  // 较光滑
    // Cook-Torrance 镜面反射
    float D = pow(ndoth, 2.0 / (roughness * roughness + 0.01));  // GGX简化
    float G = ndotl * ndotv;  // 几何项简化
    vec3 F = mix(vec3(0.04), base_color, metallic);  // Fresnel
    
    vec3 specular = (D * G * F) / max(4.0 * ndotl * ndotv, 0.001);
    base_color += specular * sun_color * ndotl * 1.2;
}

// 3. 晶体/盐类边缘透光（specular > 0.7, metallic < 0.3）
else if (specular > 0.7 && metallic < 0.3) {
    // Rim lighting
    float rim = pow(1.0 - ndotv, 2.5);
    base_color += rim * sun_color * 0.35 * ndotl;
    
    // 晶面闪烁（仅在阳光直射时）
    if (ndotl > 0.5) {
        vec2 sparkle_uv = floor(FRAGCOORD.xy / 4.0);  // 每4像素一个晶面
        float sparkle = hash(sparkle_uv + vec2(TIME * 0.1, seed));
        if (sparkle > 0.92) {
            base_color += sun_color * (sparkle - 0.92) * 10.0;  // 强烈但稀疏
        }
    }
}

// 4. 植物/动物柔和漫反射
else {
    // Oren-Nayar 粗糙漫反射（简化版）
    float rough = 0.6;
    float VdotN = ndotv;
    float LdotN = ndotl;
    float cos_i = LdotN;
    float cos_o = VdotN;
    float rough_sq = rough * rough;
    
    float A = 1.0 - 0.5 * rough_sq / (rough_sq + 0.33);
    float B = 0.45 * rough_sq / (rough_sq + 0.09);
    
    vec3 diffuse = base_color * (A + B * max(0.0, cos_i) * sin(max(acos(cos_o), acos(cos_i))));
    base_color = mix(base_color, diffuse, 0.4);  // 混合以保持原色
}
```

## 3. 阴影增强（在光照计算之后）

```glsl
// ===== 多层次阴影 =====

// 1. 接地环境遮蔽（基于高度）
float height_factor = smoothstep(0.0, 0.15, frag_height_local);
float ground_ao = mix(0.5, 1.0, height_factor);

// 2. 地形遮蔽（复用现有 sun_visibility）
float terrain_shadow = mix(0.65, 1.0, sun_visibility);

// 3. 自阴影（仅立体主体）
float self_shadow = 1.0;
if (instance_kind == KIND_PROP || instance_kind == KIND_SUBMERGED) {
    // 背光面变暗，但保留天空光
    self_shadow = mix(0.6, 1.0, ndotl * 0.4 + 0.6);
}

// 4. 投射阴影（可选，基于 cast_shadow 参数）
float cast_shadow_term = 1.0;
if (cast_shadow > 0.01) {
    // 简化投影：基于 sun_direction 和物体高度
    vec2 shadow_offset = -sun_direction.xz * frag_height_local * 2.0;
    // 采样地形高度判断阴影（需要 height_tex）
    // 此处简化为距离衰减
    float shadow_dist = length(shadow_offset) / patch_radius;
    cast_shadow_term = mix(0.7, 1.0, smoothstep(0.0, 1.0, shadow_dist));
}

// 综合所有阴影项
float shadow_combined = ground_ao * terrain_shadow * self_shadow * 
                        mix(1.0, cast_shadow_term, cast_shadow * contact_shadow);
base_color *= shadow_combined;
```

## 4. 昼夜与天气响应（在最终输出前）

```glsl
// ===== 时段调整 =====
uniform bool is_golden_hour;
uniform float moon_phase;

// 黄昏/黎明：暖色调增强
if (is_golden_hour && dot(base_color, vec3(1.0)) > 0.3) {  // 非暗物体
    vec3 golden_tint = vec3(1.15, 1.03, 0.88);
    base_color *= mix(vec3(1.0), golden_tint, 0.25 * (1.0 - night_factor));
}

// 夜晚月光（金属/晶体）
if (night_factor > 0.5 && (metallic > 0.5 || specular > 0.7)) {
    float moon_brightness = 0.25 + moon_phase * 0.15;
    vec3 moon_color = vec3(0.75, 0.80, 1.0);
    float moon_highlight = pow(1.0 - ndotv, 3.0) * night_factor;
    base_color += moon_color * moon_highlight * moon_brightness;
}

// ===== 天气效果 =====
float humidity = climate.g;  // 湿度通道
float snow_cover = climate.b;  // 积雪通道

// 湿润效果
float wetness = smoothstep(0.6, 0.9, humidity);
if (wetness > 0.01) {
    if (family == 0 || form == 22) {  // 植物/土壤
        // 湿润变暗
        base_color *= mix(1.0, 0.72, wetness);
    } else if (family == 2) {  // 矿物
        // 增加镜面反射
        float wet_specular = wetness * 0.4;
        base_color += sun_color * pow(ndoth, 20.0) * wet_specular * ndotl;
    }
}

// 冰霜效果（积雪 > 0.3）
if (snow_cover > 0.3) {
    float frost_amount = (snow_cover - 0.3) * 1.4;
    // 边缘冰晶
    float rim_frost = pow(1.0 - ndotv, 3.5) * frost_amount;
    vec3 ice_color = vec3(0.92, 0.94, 1.0);
    base_color = mix(base_color, ice_color, rim_frost * 0.5);
    
    // 表面积雪（顶部）
    float top_snow = smoothstep(0.5, 1.0, UV.y) * frost_amount;
    base_color = mix(base_color, vec3(0.96), top_snow * 0.6);
}
```

## 5. 动态优化（vertex shader）

```glsl
// ===== 多频风场 =====
uniform vec2 wind_dir;
uniform float wind_strength;
uniform float weather_wind_boost;

// 在现有 wind 计算基础上增加多层频率
if (instance_family == 0 && (instance_form >= 0 && instance_form <= 7)) {  // 植物
    float wind_time = TIME * 2.0 + instance_seed * 6.28;
    
    // 主频：整体摇摆
    float wind_main = sin(wind_time) * 0.5 + 0.5;
    // 阵风：快速变化
    float wind_gust = sin(wind_time * 2.7 + 1.3) * 0.3;
    // 细节：局部抖动
    float wind_detail = sin(wind_time * 5.1 + 2.7) * 0.15;
    
    float wind_combined = (wind_main + wind_gust + wind_detail) * wind_strength * (1.0 + weather_wind_boost);
    
    // 高度因子：顶部摆幅大
    float height_factor = smoothstep(0.0, 1.0, VERTEX.y / patch_radius);
    vec2 wind_offset = wind_dir * wind_combined * height_factor * patch_radius * 0.12;
    
    VERTEX.xy += wind_offset;
}

// ===== 动物动作细化 =====
else if (instance_family == 1) {  // 动物
    float time_phase = TIME * 1.5 + instance_seed * 6.28;
    
    // 觅食动作：头部周期性低头
    float feed_cycle = sin(time_phase) * 0.5 + 0.5;
    float is_feeding = step(0.6, hash(vec2(instance_seed, floor(TIME / 3.0))));  // 随机觅食
    float head_dip = feed_cycle * is_feeding * 0.08 * patch_radius;
    VERTEX.y -= head_dip;
    
    // 耳朵抽动（高频小幅）
    float ear_twitch = step(0.95, hash(vec2(TIME * 5.0, instance_seed * 7.13)));
    VERTEX.y += ear_twitch * 0.02 * patch_radius;
}
```

## 6. 辅助函数（shader 顶部）

```glsl
// hash 函数（如果尚未定义）
float hash(vec2 p) {
    return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
}

vec2 hash22(vec2 p) {
    p = vec2(dot(p, vec2(127.1, 311.7)), dot(p, vec2(269.5, 183.3)));
    return fract(sin(p) * 43758.5453);
}

// Fresnel 近似
float fresnel_schlick(float cosTheta, float F0) {
    return F0 + (1.0 - F0) * pow(1.0 - cosTheta, 5.0);
}
```

---

## 集成步骤

1. **备份原 shader**：`cp resource_impostor.gdshader resource_impostor.gdshader.bak`

2. **添加 uniforms**（shader 顶部）：
   ```glsl
   uniform bool is_golden_hour = false;
   uniform float moon_phase = 0.0;
   ```

3. **插入函数**：将"1. 形态生成函数"和"6. 辅助函数"插入到 `fragment()` 之前

4. **修改 fragment()**：
   - 在 albedo 基础计算后插入 mineral_detail 调用
   - 在光照计算位置插入"2. 光照响应优化"
   - 在最终输出前插入"3. 阴影增强"和"4. 昼夜天气"

5. **修改 vertex()**：替换现有 wind 计算为"5. 动态优化"

6. **GDScript 配合**（resource_visual_layer.gd prepare_frame()）：
   ```gdscript
   var is_golden = (_day_phase > 0.15 and _day_phase < 0.25) or (_day_phase > 0.75 and _day_phase < 0.85)
   _material.set_shader_parameter("is_golden_hour", is_golden)
   _material.set_shader_parameter("moon_phase", fmod(_season_phase * 12.0, 1.0))
   ```

7. **验证**：运行 `resource_visual_render_regression.gd`

---

## 性能影响预估

| 优化项 | ALU增加 | Texture采样 | 预期GPU耗时增量 |
|--------|---------|-------------|----------------|
| 形态细节 | +8 | 0 | +5% |
| 光照响应 | +15 | 0 | +8% |
| 阴影增强 | +6 | 0 | +3% |
| 天气效果 | +10 | 0 | +4% |
| **总计** | **+39** | **0** | **+18~22%** |

**基准**：当前 resource shader 约为主地形 shader 的 30% 复杂度
**优化后**：仍为主地形的 35~40%，远低于预算限制

移动端 LOW tier 可通过 `#ifdef MOBILE_QUALITY_LOW` 禁用部分效果保持性能。
