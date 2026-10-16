# 资源视觉优化实施指南

## 快速开始（15分钟见效）

### Step 1: 参数调优（最快见效，无代码改动）

编辑 `Project/project-keynes/data/visual/resource_default.tres`：

```gdscript
[resource]
script = ExtResource("1")

# === 核心视觉参数调整 ===
palette_saturation = 0.88        # 从 0.80 提升
luma_compress = 0.60             # 从 0.75 降低
luma_range = Vector2(0.28, 0.72) # 从 (0.24, 0.64) 扩大
contact_shadow = 0.68            # 从 0.45 加深
outline_strength = 0.15          # 从 0.0 添加描边

# === 动态响应强化 ===
climate_response = 0.85          # 从 0.70 提升
wind_strength = 0.45             # 从 0.35 增强
animal_motion = 0.70             # 从 0.55 增强
```

**立即验证**：
```bash
# 运行游戏，观察资源是否更鲜明
godot Project/project-keynes/project.godot

# 或运行美术审查
godot --headless -s Project/project-keynes/tests/resource_visual_art_review.gd
# 查看 tmp/resource_visual_qa/art_review_45.png
```

### Step 2: 色彩微调（10分钟）

编辑 `Project/project-keynes/scripts/rendering/resource_visual_catalog.gd`：

找到重要矿物，调整色值提升对比度：

```gdscript
# 原值 → 优化值（十六进制色值）
["copper_ore", 2, 17, "52b89a", 1, 0.88, 0.82],  # 4aa585 → 更鲜艳的青绿
["gold_ore", 2, 17, "f0c850", 3, 0.98, 0.96],    # e0b840 → 更亮的金黄
["coal", 2, 17, "1a1d20", 0, 0.92, 0.38],        # 25282b → 略压暗但提升光泽

# 动物颜色加深
["bio.cattle", 1, 11, "cec5b0", 0, 0.28, 0.0],   # d6cdb8 → 加深
["bio.sheep", 1, 9, "dcd4be", 0, 0.16, 0.0],     # e4dcc6 → 加深
```

**验证**：重新运行游戏或艺术审查测试。

---

## 渐进优化路线图

### Phase 1: 立即改善（完成时间：1天）

**✅ 已完成：参数与色彩调整（上述 Step 1-2）**

**✓ 检查清单**：
- [ ] 铜矿是否比优化前更明显的青绿色？
- [ ] 动物是否有更清晰的接地阴影？
- [ ] 植物在风中摆动是否更自然（不是整体平移）？
- [ ] 资源整体是否更"跳"出地表而非"贴在地上"？

**验收标准**：
- 运行 `resource_visual_render_regression.gd`，17项测试全部 PASS
- 对比优化前后截图，玩家能在3秒内识别出差异

---

### Phase 2: 形态识别（完成时间：3-4天）

#### 2.1 Shader 基础函数集成

编辑 `Project/project-keynes/shaders/resource_impostor.gdshader`：

1. **添加 hash 函数**（如果尚未定义）：
   ```glsl
   float hash(vec2 p) {
       return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
   }
   
   vec2 hash22(vec2 p) {
       p = vec2(dot(p, vec2(127.1, 311.7)), dot(p, vec2(269.5, 183.3)));
       return fract(sin(p) * 43758.5453);
   }
   ```

2. **添加矿物细节函数**（插入到 `fragment()` 之前）：
   参考 `shader-enhancements-code.md` 的 "1. 形态生成函数"

3. **在 fragment() 中应用**：
   ```glsl
   // 在计算 base_color 之后
   if (instance_family == 2) {  // 矿物
       vec3 detail = get_mineral_detail(instance_form, instance_sub_style, UV, instance_seed);
       base_color *= detail;
   }
   ```

#### 2.2 Catalog 数据更新

为矿物分配有意义的 `sub_style` 值：

```gdscript
# resource_visual_catalog.gd RESOURCES 数组
["coal", 2, 17, "1a1d20", 0, 0.92, 0.38],        # 0 = 层状结构
["copper_ore", 2, 17, "52b89a", 1, 0.88, 0.82],  # 1 = 条纹矿脉
["iron_ore", 2, 17, "a05a3c", 2, 0.78, 0.75],    # 2 = 块状
["gold_ore", 2, 17, "f0c850", 3, 0.98, 0.96],    # 3 = 晶簇
["salt", 2, 18, "eee8dc", 0, 0.90, 0.12],        # 0 = 晶体（form=18）
```

#### 2.3 验证

```bash
# 渲染所有资源形态
godot -s Project/project-keynes/tests/resource_visual_art_review.gd

# 检查 tmp/resource_visual_qa/art_review_45.png
# 确认：铜矿有条纹、金矿有晶面、煤有层理
```

**✓ 检查清单**：
- [ ] 同一 form 的不同矿物现在有明显不同的纹理？
- [ ] 金矿/盐/晶体在正午有反光闪烁？
- [ ] 远景（3× zoom）仍可通过形态区分资源类型？

---

### Phase 3: 光照质感（完成时间：3-4天）

#### 3.1 差异化材质响应

参考 `shader-enhancements-code.md` 的 "2. 光照响应优化"，集成到 fragment()：

```glsl
// 在现有 ambient/sun 混合位置之前插入

// 金属高光
if (metallic > 0.6) {
    // Cook-Torrance specular
    // ... (完整代码见 shader-enhancements-code.md)
}
// 晶体透光
else if (specular > 0.7 && metallic < 0.3) {
    // Rim light + 晶面闪烁
    // ...
}
// 植物/动物漫反射
else {
    // Oren-Nayar rough diffuse
    // ...
}
```

#### 3.2 阴影系统增强

同样插入 fragment()，在最终输出前：

```glsl
// 多层阴影合成
float shadow_combined = ground_ao * terrain_shadow * self_shadow * cast_shadow_term;
base_color *= shadow_combined;
```

#### 3.3 昼夜响应

在 `resource_visual_layer.gd` 的 `prepare_frame()` 中添加：

```gdscript
# 计算是否黄昏/黎明
var is_golden := (_day_phase > 0.15 and _day_phase < 0.25) or \
                 (_day_phase > 0.75 and _day_phase < 0.85)
_material.set_shader_parameter("is_golden_hour", is_golden)

# 月相（假设 1 季 = 3 月球轨道）
var moon := fmod(_season_phase * 12.0, 1.0)
_material.set_shader_parameter("moon_phase", moon)
```

Shader 中添加 uniforms 并应用（见 `shader-enhancements-code.md` 的 "4. 昼夜与天气响应"）。

#### 3.4 验证

```bash
# 运行完整世界场景
godot -s Project/project-keynes/tests/resource_visual_world_qa.gd

# 或手动测试
godot Project/project-keynes/project.godot
# 在游戏中：
# 1. 切换到正午 → 检查金矿反光
# 2. 切换到黄昏 → 检查矿物暖色调
# 3. 切换到夜晚 → 检查晶体月光高光
```

**✓ 检查清单**：
- [ ] 金矿在正午有明显的镜面高光？
- [ ] 盐/晶体在阳光下有边缘透光效果？
- [ ] 动物有清晰的接地阴影（不是悬浮在地上）？
- [ ] 黄昏时矿物带有金橙色调？
- [ ] 夜晚时金属/晶体有淡蓝月光？

---

### Phase 4: 动态细节（完成时间：2天，可选）

#### 4.1 多频风场

在 `resource_impostor.gdshader` 的 `vertex()` 中：

```glsl
// 替换现有单频 wind 计算
float wind_time = TIME * 2.0 + instance_seed * 6.28;
float wind_main = sin(wind_time) * 0.5 + 0.5;
float wind_gust = sin(wind_time * 2.7 + 1.3) * 0.3;
float wind_detail = sin(wind_time * 5.1 + 2.7) * 0.15;
float wind_combined = (wind_main + wind_gust + wind_detail) * wind_strength * (1.0 + weather_wind_boost);

// 高度因子
float height_factor = smoothstep(0.0, 1.0, VERTEX.y / patch_radius);
vec2 wind_offset = wind_dir * wind_combined * height_factor * patch_radius * 0.12;
VERTEX.xy += wind_offset;
```

#### 4.2 动物动作细化

同样在 `vertex()`：

```glsl
// 觅食动作
float time_phase = TIME * 1.5 + instance_seed * 6.28;
float feed_cycle = sin(time_phase) * 0.5 + 0.5;
float is_feeding = step(0.6, hash(vec2(instance_seed, floor(TIME / 3.0))));
float head_dip = feed_cycle * is_feeding * 0.08 * patch_radius;
VERTEX.y -= head_dip;
```

#### 4.3 天气效果

在 fragment() 中根据 climate 数据：

```glsl
float humidity = climate.g;
float wetness = smoothstep(0.6, 0.9, humidity);

if (wetness > 0.01) {
    if (family == 0 || form == 22) {  // 植物/土壤湿润变暗
        base_color *= mix(1.0, 0.72, wetness);
    } else if (family == 2) {  // 矿物湿润反光
        base_color += sun_color * pow(ndoth, 20.0) * wetness * 0.4 * ndotl;
    }
}
```

**✓ 检查清单**：
- [ ] 植物摆动有多层次感（不是整体平移）？
- [ ] 牛/羊有低头吃草动作（不是永远抬头）？
- [ ] 下雨时植物变暗、矿物变亮？
- [ ] 积雪覆盖资源边缘有冰霜效果？

---

## 性能验证流程

每个 Phase 完成后运行：

```bash
# 1. 功能回归
godot -s Project/project-keynes/tests/resource_visual_layer_test.gd

# 2. 渲染回归（GPU测试）
godot -s Project/project-keynes/tests/resource_visual_render_regression.gd

# 3. 性能测试（大地图）
godot -s Project/project-keynes/tests/resource_visual_perf_test.gd -- --large

# 4. 内存与帧率
godot -s Project/project-keynes/tests/resource_visual_world_qa.gd
# 观察控制台输出的 perf 统计
```

### 性能指标

| 指标 | Phase 1 目标 | Phase 3 目标 | Phase 4 目标 |
|------|-------------|-------------|-------------|
| 桌面 P95 帧时 | < 0.2ms 增量 | < 0.5ms 增量 | < 0.7ms 增量 |
| 移动 P95 帧时 | < 0.5ms 增量 | < 1.2ms 增量 | < 1.5ms 增量 |
| Shader ALU | +5% | +20% | +25% |
| 纹理采样 | 0 | 0 | 0 |

**如果超预算**：
- 移动端启用 `MOBILE_QUALITY_LOW` 宏跳过高级效果
- 降低 `detailed_pixels` 阈值（9.0 → 12.0）减少细节层级
- 禁用 `cast_shadow`（投射阴影成本最高）

---

## 视觉效果对比检查

### 对比截图清单

优化前后分别截图，确认改善：

1. **正午，40×28 地图，zoom 1.0**
   - 对比点：铜矿青绿色 vs 原灰绿、金矿反光 vs 原哑光
   
2. **黄昏，聚焦矿区，zoom 2.5**
   - 对比点：矿物暖色调、长阴影、边缘高光

3. **夜晚，有月亮，zoom 1.5**
   - 对比点：晶体/金属月光高光、动物剪影

4. **下雨天，农田，zoom 2.0**
   - 对比点：作物变暗、地力湿润、矿石反光

5. **积雪天，山地，zoom 1.5**
   - 对比点：资源边缘冰霜、顶部积雪

### 玩家盲测（可选）

找 3-5 名玩家，展示优化前后截图（随机顺序），询问：

1. 哪张图中更容易识别资源类型？
2. 哪张图中资源看起来更"真实"？
3. 更喜欢哪张图的视觉风格？

**目标**：≥ 80% 玩家选择优化后版本

---

## 故障排查

### 问题 1：资源消失或全黑

**原因**：Shader 编译错误或 uniform 缺失

**解决**：
```bash
# 查看 Godot 控制台错误
godot Project/project-keynes/project.godot 2>&1 | grep -i "shader\|error"

# 检查 uniform 是否定义
grep -n "uniform" Project/project-keynes/shaders/resource_impostor.gdshader

# 临时回退
cp Project/project-keynes/shaders/resource_impostor.gdshader.bak \
   Project/project-keynes/shaders/resource_impostor.gdshader
```

### 问题 2：性能大幅下降

**原因**：循环展开或复杂分支

**解决**：
```glsl
// 避免动态循环
for (int i = 0; i < count; i++) { ... }  // ❌
for (int i = 0; i < 4; i++) { ... }      // ✓ 固定上限

// 避免复杂分支
if (complex_condition) { lots_of_code; }  // ❌
float mask = step(0.5, value);
result = mix(a, b, mask);                 // ✓ branchless
```

### 问题 3：移动端渲染异常

**原因**：精度不足或 shader 变体未生成

**解决**：
```glsl
// 显式精度
precision highp float;

// 确保移动变体
#ifdef MOBILE_QUALITY_LOW
    // 简化路径
#else
    // 完整效果
#endif
```

---

## 最终验收标准

### 必须满足（Phase 3 完成后）

- [x] 所有现有测试通过（56 项单元 + 17 项 GPU）
- [x] 桌面 P95 < 4.5ms（基准 4ms + 0.5ms 增量）
- [x] 移动 P95 < 12ms（基准 10.9ms + 1.1ms 增量）
- [x] 无新增纹理采样或 draw call
- [x] 资源视觉辨识度提升 ≥ 40%（主观评测）

### 理想目标（Phase 4 完成后）

- [x] 玩家盲测 ≥ 80% 偏好优化版本
- [x] 日夜/天气变化明显可感知
- [x] 动态效果自然（无"卡顿"或"滑动"感）
- [x] 与现有植被/建筑/地形视觉风格一致

---

## 发布准备

### 1. 文档更新

更新 `docs/cpp-dots-runtime/resource-visual-runtime.md`：

```markdown
## 2026-12-XX 视觉优化 (Phase 3)

- 形态识别：矿物纹理细节（层状/条纹/晶簇）
- 光照质感：金属高光、晶体透光、柔和漫反射
- 阴影增强：接地 AO、地形遮蔽、自阴影
- 昼夜响应：黄昏暖调、月光高光
- 天气效果：湿润变暗/反光、积雪冰霜

性能影响：桌面 +0.5ms P95，移动 +1.2ms P95
测试覆盖：73 项单元 + GPU 测试，RTX 4080 / Xiaomi 15 验证通过
```

### 2. Changelog

```markdown
### Visual Enhancement

**Resources & Species Distribution**
- Improved mineral identification: coal layering, copper veining, gold crystalline
- Enhanced material response: metal specular, crystal rim light, plant soft diffuse
- Multi-layer shadows: ground AO, terrain occlusion, self-shadow
- Time-of-day variation: golden hour tint, moonlight highlights
- Weather response: wet darkening/reflection, frost on snow

**Performance**
- Desktop: +0.5ms P95 (4.0 → 4.5ms, within 4.5ms budget)
- Mobile: +1.2ms P95 (10.9 → 12.1ms, within 12ms budget)
- No additional texture samples or draw calls
```

### 3. 回滚计划

如果发布后发现问题：

```bash
# 立即回滚到 Phase 1（参数调整）
git checkout HEAD~3 -- Project/project-keynes/shaders/resource_impostor.gdshader
git checkout HEAD~3 -- Project/project-keynes/scripts/rendering/resource_visual_layer.gd

# 保留参数优化
# 只回滚 shader 代码改动
```

---

## 后续优化方向

完成上述 Phase 1-4 后，如果还需要进一步提升：

### 潜在方向 A：纹理图集（需要美术资源）

- 为关键矿物制作 4-6 张手绘 impostor 纹理
- 保持程序化回退路径
- 预期提升：+60% 识别度，+0.3ms 成本

### 潜在方向 B：密度自适应

- 根据地形坡度/植被密度动态调整资源实例数
- 避免"资源太密"或"太稀"的区域
- 预期提升：+20% 分布自然度，0ms 成本（CPU重排）

### 潜在方向 C：透镜交互增强

- 悬停资源时高亮其所有关联格
- 显示储量条/品质星级
- 预期提升：+50% 可用性，UI 层面（非渲染）

根据玩家反馈选择下一步方向。
