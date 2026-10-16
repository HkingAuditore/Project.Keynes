# 实施指南 - Shader 集成

## Step 1: 修改 resource_impostor.gdshader

### 在顶部添加 include（在第 85 行之后）

```glsl
// 在第 85 行 `#include "res://shaders/include/terrain_horizon.gdshaderinc"` 之后添加
#include "res://shaders/include/plant_animal_shapes.gdshaderinc"
```

### 修改 fragment() 中的形状生成部分（第 244-262 行）

**原代码：**
```glsl
RSurf s = rs_empty();
if (family == 3) {
    // ... fish code ...
} else {
    s = rt_resource(pf, form, family, sub_style, tint, seed, px, family == 1 ? motion * animal_motion : motion, lens < 0.5);
}
```

**新代码：**
```glsl
RSurf s = rs_empty();
if (family == 3) {
    // ... fish code (unchanged) ...
} else if ((family == 0 && form <= 3) || (family == 1 && (form == 8 || form == 9 || form == 11 || form == 12))) {
    // 新的植物和动物形状
    vec2 shape = get_plant_animal_shape(pf, form, family, sub_style, seed);
    vec2 decal = compute_decal_shape(form, pf, seed);
    
    float d_shape = shape.x > 0.001 ? -length(vec2(pf.x, pf.y * (1.0 - abs(pf.x)))) + 0.5 : 1.0;
    s.d = d_shape;
    s.albedo = tint;
    s.n = normalize(vec3(0.0, 0.0, 1.0));
    s.h = shape.x;  // Height for shading
    s.spec = v_style.r;
    s.metallic = v_style.g;
    
    // Apply decal
    if (decal.x > 0.01) {
        s.floor_a = decal.x;
        s.floor_col = mix(vec3(0.35, 0.25, 0.15), tint * 0.6, 0.3);
    }
} else {
    // 回退到原有系统
    s = rt_resource(pf, form, family, sub_style, tint, seed, px, family == 1 ? motion * animal_motion : motion, lens < 0.5);
}
```

## Step 2: 修改 resource_visual_catalog.gd

### 为植物和动物添加 sub_style 数据

```gdscript
# 在 resource_visual_catalog.gd 的 BIO 数组中

# 植物部分：
["bio.wheat", 0, 0, "cfae52", 0, 0.32, 0.0],         # wheat: 穗细，尖端
["bio.maize", 0, 1, "d4a540", 0, 0.24, 0.0],         # corn: 穗粗，须根  
["bio.rice", 0, 2, "8fb356", 0, 0.34, 0.0],          # rice: 下垂，细穗
["bio.potato", 0, 3, "5f8445", 0, 0.22, 0.0],        # leafy: 球形叶

# 动物部分：
["bio.horse", 1, 8, "8a5a38", 0, 0.38, 0.0],         # horse: 细长，长颈
["bio.sheep", 1, 9, "e4dcc6", 0, 0.14, 0.0],         # sheep: 球形，蓬松
["bio.cattle", 1, 11, "d6cdb8", 0, 0.28, 0.0],       # cattle: 宽矮，有角
["bio.pig", 1, 12, "cf9a8a", 0, 0.32, 0.0],          # pig: 矩形，鼻子
```

### 更新参数优化

```gdscript
# 编辑 data/visual/resource_default.tres

palette_saturation = 0.88        # 从 0.80 提升
luma_compress = 0.60             # 从 0.75 降低
contact_shadow = 0.68            # 从 0.45 加深
outline_strength = 0.15          # 从 0.0 添加
```

## Step 3: 测试

### 运行美术审查测试
```bash
godot --headless -s Project/project-keynes/tests/resource_visual_art_review.gd
# 查看 tmp/resource_visual_qa/art_review_45.png
```

### 在游戏中验证
```bash
godot Project/project-keynes/project.godot

# 检查：
# ✓ 小麦是否直立、细穗、尖头
# ✓ 玉米是否粗穗、圆头、有须根
# ✓ 水稻是否下垂、细穗
# ✓ 土豆是否球形、矮胖
# ✓ 马是否细长、长颈
# ✓ 牛是否有角、宽矮
# ✓ 羊是否球形、蓬松
# ✓ 猪是否鼻子凸、矩形
```

### 性能测试
```bash
godot -s Project/project-keynes/tests/resource_visual_perf_test.gd -- --large
# 检查 P95 帧时是否在预算内（桌面 4.5ms，移动 12.1ms）
```

## 常见问题

### Q: 形状显示为黑色或完全看不到
A: 检查 `s.d` 值计算。改用：
```glsl
s.d = shape.x > 0.5 ? 0.0 : 1.0;  // 简化版本先测试
```

### Q: 形状显示但没有阴影
A: 确保 `s.floor_a` 被设置：
```glsl
s.floor_a = shape.x * contact_shadow;
```

### Q: 贴花（decal）没有显示
A: 检查贴花混混合：
```glsl
if (decal.x > 0.01) {
    // 贴花颜色混合
}
```

## 下一步

完成以上步骤后：

1. ✅ 运行美术审查，验证形状是否可辨识
2. ✅ 在游戏中放大观察每种资源
3. ✅ 运行性能测试，确认在预算内
4. ✅ 如果满意，提交更改
5. ⚙️ 可选：添加 Shading 增强（细节法线、高光）
