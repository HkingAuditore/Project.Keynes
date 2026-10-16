# 植物与动物形状设计指南

## 问题诊断

当前系统存在的核心问题：

### 植物问题
- **小麦、玉米、水稻、土豆**：全部渲染成相似的竖条形，几乎无法区分
- 缺乏**穗形**差异（紧凑穗 vs 松散穗 vs 弯垂穗）
- 缺乏**颗粒**和**密度**变化
- 叶子形状完全相同

### 动物问题
- **牛、羊、猪、马、骆驼**：全部渲染成相似的四脚形状
- 缺乏**体型**差异（瘦长 vs 矮胖 vs 中等）
- 缺乏**头部比例**和**角/耳朵**特征
- 缺乏**姿态**变化（直立 vs 低头 vs 转身）

### Shading问题
- 植物着色过于均一，没有**高光/阴影变化**
- 动物缺少**毛发方向感**和**肌肉线条**
- 整体显得"平坦""卡通化"而非"真实感"

---

## 解决方案架构

### 核心策略

1. **形状层级**：基础SDF + 变体编码（sub_style）
2. **贴花系统**：纹理pattern叠加（土壤/根系/毛发）
3. **Shading增强**：细节法线 + 多层材质响应
4. **颜色编码**：通过色相/饱和度快速识别

---

## 第一部分：植物形状系统

### 植物分类

```gdscript
# resource_visual_catalog.gd 中的 form 字段
# 0=麦类  1=玉米  2=水稻  3=叶菜  4=棉花  5=花卉  6=树木  7=芦苇

# 对应的 sub_style 含义
# 0=形态A  1=形态B  2=形态C  3=形态D  4=密度变体
```

### 1.1 谷物类（form 0/1/2）辨识系统

#### 形态A：小麦（form=0, sub_style=0）
**特征**：直立、穗紧凑、顶端尖锐
```
视觉轮廓：
  ▲    <- 尖端（45°）
 ▮▮▮   <- 穗（竖条形，从上到下逐渐宽）
  ▮    <- 茎
  
关键参数：
- 穗长度：整体高度 80%
- 穗宽度：最宽处 40% 高度
- 头部角度：尖锐（>30°）
- 穗密度：紧凑（单位宽度5-6条纹）
- 颜色：金黄色（HSV: 45°, 0.8, 0.85）
```

**Shader实现**：
```glsl
vec2 wheat_shape(vec2 uv, float seed) {
    // uv: 0-1 范围，(0,0) 在中心底部
    float stem_width = 0.08;
    
    // 主茎
    float stem = smoothstep(stem_width, 0.0, abs(uv.x));
    
    // 穗部分（y > 0.2）
    float spike_start = 0.2;
    if (uv.y > spike_start) {
        float spike_progress = (uv.y - spike_start) / (1.0 - spike_start);
        
        // 穗宽度从 stem_width 渐扩到 0.4
        float spike_width = mix(stem_width, 0.40, spike_progress);
        
        // 细条纹：每 0.12 单位一条
        float grain_lines = fract(uv.y * 8.0);  // 8 条纹
        float grain_detail = smoothstep(0.02, 0.0, abs(grain_lines - 0.5)) * 0.4;
        
        // 穗轮廓 + 细节
        float spike = smoothstep(spike_width * 0.5, 0.0, abs(uv.x));
        spike *= mix(0.6, 1.0, grain_detail);
        
        // 顶部尖端
        float tip_sharpness = smoothstep(0.95, 1.0, spike_progress) * 0.8;
        spike += tip_sharpness * smoothstep(0.1, 0.0, abs(uv.x) - spike_width * 0.3);
        
        return vec2(spike, spike);
    }
    
    return vec2(stem, stem);
}

// 小麦着色
vec3 wheat_shading(vec2 uv, vec3 base_color, float seed) {
    // 穗顶部高光
    float is_spike = uv.y > 0.2 ? 1.0 : 0.0;
    float spike_progress = (uv.y - 0.2) / 0.8;
    
    // 顶部更亮的金黄
    vec3 spike_color = mix(base_color, vec3(0.95, 0.88, 0.5), spike_progress * 0.3);
    
    // 细条纹阴影
    float grain_shadow = fract(uv.y * 8.0);
    grain_shadow = smoothstep(0.1, 0.4, grain_shadow) - smoothstep(0.6, 0.9, grain_shadow);
    spike_color *= mix(0.85, 1.0, grain_shadow);
    
    // 茎部阴影
    if (uv.y < 0.2) {
        // 茎左右深浅不同
        float stem_shadow = smoothstep(0.08, 0.0, abs(uv.x));
        spike_color = mix(base_color * 0.75, base_color, stem_shadow);
    }
    
    return spike_color;
}
```

#### 形态B：玉米（form=1, sub_style=0）
**特征**：穗较粗、顶端钝圆、有须状结构
```
视觉轮廓：
  ◯    <- 圆钝端
 ▮▮▮▮   <- 穗（粗矮，宽且密）
  ▮    <- 茎
  ~~~  <- 须根（可选）

关键参数：
- 穗长度：整体高度 60%
- 穗宽度：最宽处 50% 高度（比小麦粗）
- 头部角度：钝圆（曲率>0.3）
- 穗密度：超密集（单位宽度8-10条纹）
- 须根：有 2-3 条下垂的细须
- 颜色：更金黄（HSV: 45°, 0.9, 0.92）或偏橙（HSV: 35°, 0.8, 0.88）
```

**Shader实现**：
```glsl
vec2 corn_shape(vec2 uv, float seed) {
    float stem_width = 0.10;
    
    // 穗部分（y > 0.4）
    if (uv.y > 0.4) {
        float spike_progress = (uv.y - 0.4) / 0.6;
        
        // 穗宽度从 stem_width 快速扩到 0.5，顶部保持圆润
        float spike_width = 0.50 * smoothstep(0.0, 0.8, spike_progress);
        // 顶部圆润（不是尖的）
        spike_width *= mix(1.0, 0.95, smoothstep(0.85, 1.0, spike_progress));
        
        // 密集条纹（比小麦多）
        float grain_lines = fract(uv.y * 12.0);  // 12 条纹（vs 小麦 8）
        float grain_detail = 1.0 - abs(grain_lines - 0.5);  // 更清晰的条纹
        grain_detail = smoothstep(0.05, 0.0, grain_detail) * 0.5;
        
        float spike = smoothstep(spike_width * 0.5, 0.0, abs(uv.x));
        spike *= mix(0.7, 1.0, grain_detail);
        
        return vec2(spike, spike);
    }
    
    // 茎部
    float stem = smoothstep(stem_width * 0.5, 0.0, abs(uv.x));
    
    // 须根（y < 0.4 时）
    if (uv.y < 0.2) {
        // 2-3 条下垂的须
        for (int i = -1; i <= 1; i++) {
            float root_x = 0.12 + float(i) * 0.08;
            float root_offset = sin(uv.y * 5.0 + seed * 6.28 + float(i)) * 0.02;
            float root = smoothstep(0.02, 0.0, abs(uv.x - root_x + root_offset));
            root *= smoothstep(0.2, 0.0, uv.y);  // 向下淡出
            stem = max(stem, root * 0.6);
        }
    }
    
    return vec2(stem, stem);
}

vec3 corn_shading(vec2 uv, vec3 base_color, float seed) {
    // 穗顶部更亮（成熟的金黄）
    if (uv.y > 0.4) {
        float spike_progress = (uv.y - 0.4) / 0.6;
        vec3 spike_color = base_color;
        
        // 顶部最亮
        spike_color *= mix(0.9, 1.1, smoothstep(0.5, 1.0, spike_progress) * 0.3);
        
        // 条纹阴影很清晰
        float grain_shadow = fract(uv.y * 12.0);
        grain_shadow = grain_shadow < 0.4 ? 1.0 : 0.7;  // 高对比
        spike_color *= grain_shadow;
        
        return spike_color;
    }
    
    // 茎部：深绿
    return base_color * 0.7;
}
```

#### 形态C：水稻（form=2, sub_style=0）
**特征**：穗细长、弯垂、呈弧形
```
视觉轮廓：
     ╱ <- 弧形尖端
    ╱
   ╱   <- 穗（细、弯曲向下）
  ╱
 ╱     <- 下垂感
 ▮     <- 茎

关键参数：
- 穗长度：整体高度 85%（最长）
- 穗宽度：最宽处 25% 高度（最细）
- 弯曲：明显下垂弧度（20-30° 倾斜）
- 颜色：淡金或米白（HSV: 55°, 0.5, 0.88）或略带绿（HSV: 70°, 0.4, 0.85）
```

**Shader实现**：
```glsl
vec2 rice_shape(vec2 uv, float seed) {
    float stem_width = 0.06;
    
    // 穗部分（y > 0.15）
    if (uv.y > 0.15) {
        float spike_progress = (uv.y - 0.15) / 0.85;
        
        // 穗宽度很细
        float spike_width = 0.25 * sqrt(1.0 - spike_progress);  // 向上逐渐细
        
        // 下垂弧度：右倾（正常穗）或左倾（取决于种植密度）
        float bend = mix(-0.15, 0.15, hash(seed + 1.0));  // 随机弧度
        float x_offset = bend * spike_progress * spike_progress;  // 抛物线弯曲
        
        // 细密穗粒
        float grain_lines = fract(uv.y * 15.0);  // 更密集
        float grain_detail = grain_lines < 0.3 ? 1.0 : 0.5;  // 粒状纹理
        
        float spike = smoothstep(spike_width * 0.5, 0.0, abs(uv.x - x_offset));
        spike *= mix(0.6, 1.0, grain_detail);
        
        // 顶端芒状（细尖）
        float awn = max(0.0, 1.0 - length(vec2(uv.x - x_offset, uv.y - 0.98)) / 0.1);
        spike += awn * 0.4;
        
        return vec2(spike, spike);
    }
    
    // 茎部
    return vec2(smoothstep(stem_width * 0.5, 0.0, abs(uv.x)), 1.0);
}

vec3 rice_shading(vec2 uv, vec3 base_color, float seed) {
    if (uv.y > 0.15) {
        // 穗色从下到上变浅
        float spike_progress = (uv.y - 0.15) / 0.85;
        vec3 spike_color = mix(base_color * 0.95, base_color * 1.1, spike_progress);
        
        // 粒状阴影
        float grain_shadow = fract(uv.y * 15.0);
        spike_color *= mix(0.85, 1.0, smoothstep(0.3, 0.6, grain_shadow));
        
        return spike_color;
    }
    
    return base_color * 0.75;
}
```

#### 形态D：土豆（叶菜/根茎，form=3, sub_style=0）
**特征**：球形、矮胖、宽叶
```
视觉轮廓：
  ◉◉◉   <- 多个叶球（3-4 个）
  ◉◉    <- 彼此靠近
   ▮    <- 短茎

关键参数：
- 整体高度：最矮（35% 高度）
- 形状：圆形小叶 3-4 个簇聚
- 叶面：有明显褶皱/纹理
- 颜色：深绿或红紫（HSV: 130°/300°, 0.7, 0.6）
```

**Shader实现**：
```glsl
vec2 leafy_shape(vec2 uv, float seed) {
    // 多个球形叶丛
    vec2 result = vec2(0.0);
    
    // 叶球 1-3（y > 0.3）
    for (int i = 0; i < 3; i++) {
        vec2 leaf_center = vec2(sin(seed * 6.28 + float(i) * 2.09) * 0.12, 0.5 + float(i) * 0.15);
        float leaf_radius = 0.15;
        
        float dist = length(uv - leaf_center);
        float leaf = smoothstep(leaf_radius, 0.0, dist);
        leaf *= step(0.3, uv.y);  // 只在上部
        
        // 叶脉纹理
        float vein = sin(dist * 8.0) * 0.3 + 0.7;
        leaf *= vein;
        
        result.x = max(result.x, leaf);
    }
    
    // 短茎（y < 0.3）
    float stem = smoothstep(0.06, 0.0, abs(uv.x));
    stem *= step(0.0, uv.y) * step(uv.y, 0.3);
    
    return vec2(max(result.x, stem), 1.0);
}
```

### 1.2 贴花系统（Decal）

贴花叠加在形状底部，表现根系、土壤、掉落的花瓣等。

#### 贴花类型

```glsl
// form 决定贴花类型
// 0-2（谷物）-> 根须贴花
// 3（叶菜）-> 土壤暴露贴花
// 4（棉花）-> 棉絮散落贴花
// 5（花卉）-> 花瓣脱落贴花
// 6（树木）-> 落叶贴花
// 7（芦苇）-> 水草贴花

vec2 compute_decal_shape(int form, vec2 uv, float seed) {
    float decal = 0.0;
    
    if (form <= 2) {  // 谷物 -> 根须
        // 3-4 条根须从底部向外放射
        for (int i = 0; i < 4; i++) {
            float angle = seed * 6.28 + float(i) * 1.57;
            vec2 root_dir = vec2(cos(angle), sin(angle));
            
            // 从 uv.y=0 向外辐射
            float root_length = 0.3;
            float t = length(uv - root_dir * root_length * 0.5) / 0.02;
            
            // 根须沿方向逐渐细
            float along_root = max(0.0, dot(uv, root_dir)) / root_length;
            float root_width = 0.03 * (1.0 - along_root);
            
            float root = smoothstep(root_width, 0.0, t);
            root *= step(0.0, along_root) * step(along_root, 1.0);
            
            decal = max(decal, root);
        }
    }
    else if (form == 3) {  // 叶菜 -> 土壤暴露
        // 不规则的土壤贴花
        vec2 soil_uv = uv * 5.0;
        float soil = hash(floor(soil_uv)) * 0.4 + 0.2;
        soil *= smoothstep(0.25, 0.0, length(uv));  // 向外淡出
        decal = soil;
    }
    else if (form == 4) {  // 棉花 -> 棉絮
        // 小绒球散落
        float fluff = 0.0;
        for (int i = 0; i < 5; i++) {
            vec2 fluff_pos = vec2(
                sin(seed * 6.28 + float(i) * 1.257) * 0.3,
                cos(seed * 6.28 + float(i) * 1.257) * 0.2 - 0.1
            );
            float fluff_dist = length(uv - fluff_pos);
            fluff = max(fluff, smoothstep(0.08, 0.0, fluff_dist));
        }
        decal = fluff * 0.6;
    }
    
    return vec2(decal, decal);
}
```

#### 贴花着色

```glsl
vec3 decal_shading(float decal, int form, vec3 base_color, vec3 ground_color) {
    if (decal < 0.01) return vec3(0.0);
    
    vec3 decal_color = vec3(0.0);
    
    if (form <= 2) {  // 根须：褐色
        decal_color = mix(vec3(0.35, 0.25, 0.15), base_color * 0.6, 0.3);
    }
    else if (form == 3) {  // 土壤：棕色
        decal_color = mix(ground_color, vec3(0.4, 0.3, 0.2), 0.6);
    }
    else if (form == 4) {  // 棉絮：白色
        decal_color = vec3(0.9, 0.88, 0.85);
    }
    else if (form == 5) {  // 花瓣：淡彩
        decal_color = base_color * 0.7;
    }
    
    return decal_color * decal;
}
```

---

## 第二部分：动物形状系统

### 动物分类

```gdscript
# form 字段
# 8=马    9=绵羊  10=山羊  11=牛  12=猪  13=骆驼  14=牦牛

# sub_style 含义
# 0=直立  1=低头  2=转身  3=站姿变体
```

### 2.1 动物体型辨识

#### 马（form=8, sub_style=0）
**特征**：高长颈、细腿、听觉耳
```
视觉轮廓：
  △ ← 耳（竖立，尖锐）
 /|\  ← 颈（长且直）
 | |  ← 躯体（细长）
 | |  ← 腿（细长，4条明显分离）
 
关键参数：
- 颈长度：躯体高度 40%
- 耳长：颈部高度 20%
- 体型：细长（宽/高 = 0.35）
- 腿：明显分离，细
- 颜色：棕色/黑色（HSV: 30°/0°, 0.5/0.0, 0.6/0.3）
- 尾巴：长且蓬松
```

**Shader实现**：
```glsl
vec2 horse_shape(vec2 uv, float seed) {
    // 标准化坐标：(0,0) 在脚，(0,1) 在头顶
    float head = 0.0;
    float body = 0.0;
    
    // 头部（y > 0.85）
    if (uv.y > 0.85) {
        float head_progress = (uv.y - 0.85) / 0.15;
        vec2 head_pos = vec2(0.0, 0.92);
        float head_width = 0.08;
        
        head = smoothstep(head_width, 0.0, abs(uv.x));
        head *= smoothstep(0.92, 0.75, uv.y);  // 向上收窄到鼻子
        
        // 马的长脸：从下颌到鼻子逐渐细
        float face_taper = mix(0.08, 0.04, head_progress);
        head = max(head, smoothstep(face_taper, 0.0, abs(uv.x)));
        
        // 耳朵（y > 0.95）
        if (uv.y > 0.95) {
            float ear_angle = 15.0 * 3.14159 / 180.0;  // 15° 倾斜
            vec2 ear_dir = normalize(vec2(sin(ear_angle), cos(ear_angle)));
            
            // 左右两只耳
            for (int ear = -1; ear <= 1; ear += 2) {
                float ear_x = float(ear) * 0.06;
                vec2 ear_center = head_pos + vec2(ear_x, 0.0);
                
                float ear_dist = distance(uv, ear_center + ear_dir * 0.08);
                float ear = smoothstep(0.04, 0.0, ear_dist);
                head = max(head, ear * 0.8);
            }
        }
    }
    
    // 颈部（0.7 < y < 0.85）
    else if (uv.y > 0.7) {
        float neck_width = mix(0.08, 0.12, (0.85 - uv.y) / 0.15);  // 颈向下扩
        body = max(body, smoothstep(neck_width, 0.0, abs(uv.x)));
    }
    
    // 躯体（0.3 < y < 0.7）
    else if (uv.y > 0.3) {
        // 马的躯体较为细长
        float body_width = 0.12;
        body = smoothstep(body_width, 0.0, abs(uv.x));
        
        // 腹部略凹
        float belly_depth = 0.02;
        float belly_indent = sin(uv.y * 3.14159) * belly_depth;
        body *= smoothstep(body_width - belly_indent, belly_indent, abs(uv.x));
    }
    
    // 腿部（y < 0.3）
    else {
        // 4 条细腿
        float leg_positions[4] = float[](-0.08, -0.02, 0.02, 0.08);
        for (int i = 0; i < 4; i++) {
            float leg_x = leg_positions[i];
            float leg_width = 0.015;
            float leg = smoothstep(leg_width, 0.0, abs(uv.x - leg_x));
            body = max(body, leg);
        }
    }
    
    return vec2(max(head, body), max(head, body));
}

// 马的着色
vec3 horse_shading(vec2 uv, vec3 base_color, float seed) {
    // 颈部和头部更深色（毛发方向）
    if (uv.y > 0.7) {
        // 鬃毛阴影
        float mane_shadow = sin(uv.y * 5.0 + seed * 6.28) * 0.3;
        return base_color * (0.8 + mane_shadow * 0.2);
    }
    
    // 躯体：腹部更亮
    if (uv.y > 0.3) {
        float belly_factor = sin(length(vec2(uv.x, (uv.y - 0.5) * 0.5))) * 0.2;
        return base_color * (1.0 + belly_factor * 0.15);
    }
    
    // 腿部：略暗
    return base_color * 0.85;
}
```

#### 牛（form=11, sub_style=0）
**特征**：宽体、低颈、厚实、有角
```
视觉轮廓：
 >O< ← 角（横伸）
 /|\  ← 头宽，有角
 | |  ← 颈短粗
 | |  ← 躯体厚实（宽/高 = 0.55）
 | |  ← 腿粗短
 
关键参数：
- 颈长度：躯体高度 15%（很短）
- 角：水平伸展，20-30° 向上倾斜
- 体型：矮胖（宽/高 = 0.55）
- 头宽：明显大于马
- 腿：粗短
- 颜色：黑/棕/花纹（HSV: 40°, 0.4-0.8, 0.4-0.7）
- 标志：大尺寸，低沉
```

**Shader实现**：
```glsl
vec2 cattle_shape(vec2 uv, float seed) {
    float head = 0.0;
    float body = 0.0;
    
    // 头部（y > 0.80）
    if (uv.y > 0.80) {
        // 宽大的头
        float head_width = 0.14;
        head = smoothstep(head_width * 0.5, 0.0, abs(uv.x));
        
        // 鼻子（y > 0.95）
        if (uv.y > 0.95) {
            head = max(head, smoothstep(0.04, 0.0, abs(uv.x)));
        }
        
        // 角（y > 0.88）
        if (uv.y > 0.88) {
            // 左右两个角，向上向外伸展
            for (int horn = -1; horn <= 1; horn += 2) {
                float horn_x = float(horn) * 0.15;
                float horn_angle = 25.0 * 3.14159 / 180.0;  // 25° 向上
                
                // 角是向上向外的曲线
                float horn_t = (uv.y - 0.88) / 0.12;  // 0-1
                float horn_curve = horn_t * horn_t;  // 抛物线
                
                vec2 horn_tip = vec2(horn_x + sin(horn_angle) * horn_curve * 0.15,
                                     0.88 + cos(horn_angle) * horn_curve * 0.15);
                
                float horn_dist = distance(uv, horn_tip);
                float horn = smoothstep(0.02, 0.0, horn_dist);
                
                head = max(head, horn * 0.6);
            }
        }
    }
    
    // 颈部（y > 0.65）很短
    else if (uv.y > 0.65) {
        float neck_width = 0.14;  // 几乎和头一样宽
        body = smoothstep(neck_width * 0.5, 0.0, abs(uv.x));
    }
    
    // 躯体（0.2 < y < 0.65）很宽
    else if (uv.y > 0.2) {
        float body_width = 0.18;  // 比马宽很多
        body = smoothstep(body_width * 0.5, 0.0, abs(uv.x));
        
        // 背部有坡度（下凹）
        float back_slope = abs(uv.x) * 0.1;
        body *= smoothstep(body_width * 0.5 + back_slope, back_slope, abs(uv.x));
    }
    
    // 腿部（y < 0.2）粗短
    else {
        float leg_positions[4] = float[](-0.12, -0.04, 0.04, 0.12);
        for (int i = 0; i < 4; i++) {
            float leg_x = leg_positions[i];
            float leg_width = 0.025;  // 比马粗
            float leg = smoothstep(leg_width, 0.0, abs(uv.x - leg_x));
            body = max(body, leg);
        }
    }
    
    return vec2(max(head, body), max(head, body));
}

vec3 cattle_shading(vec2 uv, vec3 base_color, float seed) {
    // 头部：有角的深色阴影
    if (uv.y > 0.80) {
        vec3 head_color = base_color;
        
        // 鼻梁阴影
        float muzzle_shadow = smoothstep(0.05, 0.12, abs(uv.x));
        head_color *= mix(0.75, 1.0, muzzle_shadow);
        
        // 角的反光
        if (uv.y > 0.88 && abs(uv.x) > 0.12) {
            head_color += vec3(0.2, 0.2, 0.2) * 0.3;  // 角的高光
        }
        
        return head_color;
    }
    
    // 躯体：背部深、腹部浅
    if (uv.y > 0.2) {
        float back_highlight = 1.0 - abs(uv.x) / 0.18;  // 背部更高（在中间）
        return base_color * mix(0.85, 1.0, back_highlight * 0.2);
    }
    
    // 腿部
    return base_color * 0.8;
}
```

#### 绵羊（form=9, sub_style=0）
**特征**：球形体、短腿、蓬松、有冲天辫
```
视觉轮廓：
  ^  ← 头顶冲天（小尖角或卷毛）
 ( ) ← 头（圆）
 (o) ← 耳（小，圆）
 OOO ← 躯体（球形，超蓬松，宽/高 = 0.65）
 | | ← 腿（短，4条紧密）

关键参数：
- 整体高度：矮（最矮的动物）
- 体型：球形（宽/高 = 0.65）
- 毛发感：蓬松（边缘不规则）
- 颜色：白色/浅灰（HSV: 0°, 0.1, 0.9）或黑色（HSV: 0°, 0.1, 0.2）
- 标志：最胖的动物形状
```

**Shader实现**：
```glsl
vec2 sheep_shape(vec2 uv, float seed) {
    // 球形羊毛：使用 Voronoi + 圆形
    
    // 躯体球（0.2 < y < 0.75）
    float body = 0.0;
    if (uv.y > 0.2) {
        // 中心球形
        float center_sphere = smoothstep(0.20, 0.0, length(vec2(uv.x, (uv.y - 0.5) * 0.6 - 0.1)));
        
        // 蓬松边缘：Voronoi 式不规则
        vec2 wool_cell = floor(length(vec2(uv.x, uv.y)) * 8.0 + seed);
        float wool_noise = hash(wool_cell) * 0.08 - 0.04;
        
        body = smoothstep(0.22 + wool_noise, 0.0, length(vec2(uv.x, (uv.y - 0.5) * 0.6 - 0.1)));
    }
    
    // 头部（y > 0.75）
    float head = 0.0;
    if (uv.y > 0.75) {
        // 圆头
        float head_width = 0.10;
        head = smoothstep(head_width, 0.0, abs(uv.x));
        
        // 耳朵（小圆形）
        for (int ear = -1; ear <= 1; ear += 2) {
            float ear_x = float(ear) * 0.08;
            float ear_y = 0.88;
            float ear = smoothstep(0.04, 0.0, distance(uv, vec2(ear_x, ear_y)));
            head = max(head, ear);
        }
        
        // 头顶冲天卷毛
        if (uv.y > 0.92) {
            float topknot = smoothstep(0.08, 0.0, distance(uv, vec2(0.0, 0.98)));
            topknot *= sin((uv.x + uv.y) * 10.0 + seed * 6.28) * 0.5 + 0.5;  // 卷毛质感
            head = max(head, topknot * 0.6);
        }
    }
    
    // 腿部（y < 0.2）短粗
    else if (uv.y < 0.2) {
        // 4 条紧密的短腿
        float leg_positions[4] = float[](-0.08, -0.025, 0.025, 0.08);
        for (int i = 0; i < 4; i++) {
            float leg_x = leg_positions[i];
            float leg_width = 0.02;
            float leg = smoothstep(leg_width, 0.0, abs(uv.x - leg_x));
            head = max(head, leg);
        }
    }
    
    return vec2(max(head, body), max(head, body));
}

vec3 sheep_shading(vec2 uv, vec3 base_color, float seed) {
    // 羊毛：柔软高光
    if (uv.y > 0.2 && uv.y < 0.75) {
        // 高光斑点
        vec2 wool_cell = floor(length(vec2(uv.x, uv.y)) * 12.0);
        float highlight = step(0.85, hash(wool_cell + seed));
        
        return base_color * (0.9 + highlight * 0.3);
    }
    
    // 头部：光滑
    if (uv.y > 0.75) {
        // 鼻子黑点
        if (length(vec2(uv.x, uv.y - 0.80)) < 0.015) {
            return base_color * 0.3;
        }
        
        return base_color * 0.95;
    }
    
    // 腿部：略暗
    return base_color * 0.75;
}
```

#### 猪（form=12, sub_style=0）
**特征**：身体宽矮、头大、短嘴、短腿、卷尾
```
视觉轮廓：
   ~~~  ← 卷尾（后上方）
  (>o< ← 头（大且方）
  ~ ~  ← 鼻子（凸出，圆）
  ~~~  ← 躯体（宽矮，接近矩形，宽/高 = 0.70）
  | |  ← 腿（短粗）

关键参数：
- 整体高度：第二矮
- 体型：矩形（宽/高 = 0.70）
- 鼻子：明显凸出、圆形
- 尾巴：卷曲向上
- 颜色：粉色/黑色/棕色（HSV: 0°, 0.3, 0.8 或 0°, 0.0, 0.3）
- 标志：宽矮的身体 + 明显的鼻子
```

**Shader实现**：
```glsl
vec2 pig_shape(vec2 uv, float seed) {
    float head = 0.0;
    float body = 0.0;
    
    // 躯体（0.25 < y < 0.70）：宽矮矩形
    if (uv.y > 0.25) {
        float body_width = 0.20;  // 最宽的
        body = smoothstep(body_width * 0.5, 0.0, abs(uv.x));
        
        // 背部略弓形
        float back_arch = abs(uv.x) * 0.05;
        body *= smoothstep(body_width * 0.5 + back_arch, back_arch, abs(uv.x));
    }
    
    // 头部（y > 0.70）
    if (uv.y > 0.70) {
        float head_width = 0.16;
        head = smoothstep(head_width, 0.0, abs(uv.x));
        
        // 猪的方脸
        head *= step(0.70, uv.y);
        
        // 鼻子（y > 0.80，凸出）
        if (uv.y > 0.80) {
            float snout_x = 0.0;
            float snout_y = 0.86;
            float snout = smoothstep(0.06, 0.0, distance(uv, vec2(snout_x, snout_y)));
            snout *= step(0.80, uv.y);
            head = max(head, snout * 0.8);
            
            // 鼻孔（两个小点）
            for (int nostril = -1; nostril <= 1; nostril += 2) {
                float nostril_x = float(nostril) * 0.01;
                float nostril_y = snout_y + 0.01;
                float nostril_dot = smoothstep(0.008, 0.0, distance(uv, vec2(nostril_x, nostril_y)));
                head = max(head, nostril_dot * 0.4);
            }
        }
        
        // 耳朵（y > 0.88，三角形）
        if (uv.y > 0.88) {
            for (int ear = -1; ear <= 1; ear += 2) {
                float ear_x = float(ear) * 0.10;
                float ear_y = 0.92;
                
                // 三角形耳
                float ear_dist = length(vec2(uv.x - ear_x, (uv.y - ear_y) * 0.5));
                float ear = smoothstep(0.035, 0.0, ear_dist);
                head = max(head, ear);
            }
        }
    }
    
    // 腿部（y < 0.25）
    else {
        float leg_positions[4] = float[](-0.14, -0.05, 0.05, 0.14);
        for (int i = 0; i < 4; i++) {
            float leg_x = leg_positions[i];
            float leg_width = 0.025;
            float leg = smoothstep(leg_width, 0.0, abs(uv.x - leg_x));
            body = max(body, leg);
        }
    }
    
    // 尾巴（卷尾，可选）
    // 从后上方向上卷曲
    float tail_phase = seed * 6.28;
    for (float t = 0.0; t < 1.0; t += 0.1) {
        float tail_angle = tail_phase + t * 3.14159;
        vec2 tail_pos = vec2(0.12 + cos(tail_angle) * 0.04 * t,
                              0.65 + sin(tail_angle) * 0.04 * t);
        float tail = smoothstep(0.015, 0.0, distance(uv, tail_pos));
        head = max(head, tail * 0.5);
    }
    
    return vec2(max(head, body), max(head, body));
}

vec3 pig_shading(vec2 uv, vec3 base_color, float seed) {
    // 躯体：肉感（淡粉），有明暗
    if (uv.y > 0.25 && uv.y < 0.70) {
        // 腹部更浅
        float belly_shade = abs(uv.x) / 0.20;
        return base_color * mix(1.05, 0.90, belly_shade);
    }
    
    // 头部：整体略暗
    if (uv.y > 0.70) {
        // 鼻子：更深色
        if (uv.y > 0.80) {
            return base_color * 0.75;
        }
        
        return base_color * 0.85;
    }
    
    // 腿部：最暗
    return base_color * 0.70;
}
```

### 2.2 动物姿态与动作

每个动物有 4 个子姿态（sub_style）：
- 0: 直立（正常站立）
- 1: 低头（觅食或休息）
- 2: 转身（身体旋转 45°）
- 3: 坐姿/躺姿（可选）

```glsl
// vertex shader 中根据 sub_style 调整顶点

vec2 adjust_animal_pose(vec2 vertex, int sub_style, float time, float seed) {
    if (sub_style == 0) {  // 直立
        // 原始形状
        return vertex;
    }
    else if (sub_style == 1) {  // 低头
        // 整体向前倾 15°
        float angle = 15.0 * 3.14159 / 180.0;
        mat2 rotate = mat2(cos(angle), -sin(angle), sin(angle), cos(angle));
        vertex = rotate * vertex;
        // 头部额外下沉 20%
        if (vertex.y > 0.80) {
            vertex.y -= 0.15;
        }
        return vertex;
    }
    else if (sub_style == 2) {  // 转身
        // 绕垂直轴旋转 45°
        float angle = 45.0 * 3.14159 / 180.0;
        vertex.x *= cos(angle) + sin(angle) * 0.3;  // 透视缩小
        return vertex;
    }
    else if (sub_style == 3) {  // 坐/躺
        // 躯体压平 50%
        vertex.y *= 0.5;
        return vertex;
    }
    
    return vertex;
}
```

---

## 第三部分：Shading增强

### 3.1 表面法线增强

为植物和动物添加细节法线，使表面看起来不那么"平坦"。

```glsl
// 计算细节法线（基于 UV）
vec3 get_detail_normal(vec2 uv, int family, int form, float seed) {
    vec3 normal = vec3(0.0, 0.0, 1.0);  // 默认朝向摄像机
    
    if (family == 0) {  // 植物
        // 植物叶脉方向法线
        float vein_angle = seed * 6.28;
        vec3 vein_dir = vec3(cos(vein_angle), sin(vein_angle), 0.5);
        
        // 穗向纵向弯曲
        float ridge = sin(uv.y * 10.0) * 0.3;
        normal = normalize(vec3(ridge * sin(vein_angle), ridge * cos(vein_angle), 1.0));
    }
    else if (family == 1) {  // 动物
        // 毛发方向（沿身体轮廓）
        float hair_dir = atan(uv.y, uv.x);
        vec3 hair_normal = normalize(vec3(cos(hair_dir) * 0.3, sin(hair_dir) * 0.3, 1.0));
        
        // 肌肉线条（对于牛/马）
        if (form == 8 || form == 11) {  // 马或牛
            float muscle_ridge = sin(uv.x * 4.0) * 0.2;
            hair_normal.x += muscle_ridge;
        }
        
        normal = normalize(hair_normal);
    }
    
    return normal;
}
```

### 3.2 毛发/叶子高光

```glsl
// 毛发高光（各向异性 specular）
vec3 anisotropic_highlight(vec3 light_dir, vec3 view_dir, vec3 hair_normal, float seed) {
    // 沿毛发方向的高光
    float hair_angle = atan(hair_normal.y, hair_normal.x);
    
    // Kajiya-Kay 模型（简化）
    float hair_cos = dot(normalize(light_dir + view_dir), hair_normal);
    float hair_specular = pow(hair_cos, 16.0) * 0.6;
    
    // 毛发间隙高光（多重散射）
    float scatter_light = pow(1.0 - abs(dot(light_dir, hair_normal)), 2.0) * 0.3;
    
    return vec3(hair_specular + scatter_light);
}

// 叶子透光
vec3 leaf_translucency(vec3 light_dir, vec3 normal, vec3 base_color, float thickness) {
    // SSS（subsurface scattering）简化
    float backlit = smoothstep(-0.5, 0.0, -dot(light_dir, normal));
    vec3 transmit = base_color * backlit * thickness * 0.5;
    
    return transmit;
}
```

### 3.3 土壤/泥土Shading

```glsl
// 根部/贴花Shading
vec3 soil_shading(float decal_alpha, vec3 decal_color, vec3 ground_color, 
                   vec3 light_dir, vec3 normal) {
    if (decal_alpha < 0.01) return vec3(0.0);
    
    // 土壤缺乏镜面反射（粗糙）
    float ndotl = max(0.0, dot(normal, light_dir));
    vec3 soil = decal_color * ndotl;
    
    // 土壤阴影（微细结构）
    float soil_shadow = fract(length(normal.xy) * 5.0) * 0.3 + 0.7;
    soil *= soil_shadow;
    
    return soil * decal_alpha;
}
```

---

## 第四部分：集成方案

### 4.1 Catalog数据结构更新

```gdscript
# resource_visual_catalog.gd

const BIO := [
    # [id, family, form, color_hex, sub_style, specular, metallic, 
    #  shape_variant, decal_type, hair_direction_bias]
    
    # 植物
    ["bio.wheat", 0, 0, "cfae52", 0, 0.32, 0.0, 0, 1, 0.0],
    ["bio.maize", 0, 1, "7a9a40", 0, 0.24, 0.0, 0, 1, 0.1],
    ["bio.rice", 0, 2, "8fb356", 0, 0.34, 0.0, 0, 1, -0.15],
    ["bio.potato", 0, 3, "5f8445", 0, 0.22, 0.0, 1, 2, 0.0],
    
    # 动物
    ["bio.horse", 1, 8, "8a5a38", 0, 0.38, 0.0, 0, 3, 0.2],
    ["bio.sheep", 1, 9, "e4dcc6", 0, 0.14, 0.0, 0, 3, 0.3],
    ["bio.cattle", 1, 11, "d6cdb8", 0, 0.28, 0.0, 0, 3, 0.15],
    ["bio.pig", 1, 12, "cf9a8a", 0, 0.32, 0.0, 0, 3, 0.25],
]

# 说明
# shape_variant: 形态代码，用于决定具体 SDF 函数
# decal_type: 贴花类型（1=根须、2=土壤、3=毛发）
# hair_direction_bias: 毛发/叶脉方向偏移
```

### 4.2 Shader入口

```glsl
// resource_impostor.gdshader

// 接收的 instance data
varying flat int instance_form;
varying flat int instance_sub_style;
varying flat int instance_family;

void fragment() {
    // 1. 根据 form/sub_style 生成形状
    vec2 shape = vec2(0.0);
    if (instance_family == 0) {  // 植物
        if (instance_form == 0) shape = wheat_shape(UV, instance_seed);
        else if (instance_form == 1) shape = corn_shape(UV, instance_seed);
        else if (instance_form == 2) shape = rice_shape(UV, instance_seed);
        // ... 其他植物
    }
    else if (instance_family == 1) {  // 动物
        if (instance_form == 8) shape = horse_shape(UV, instance_seed);
        else if (instance_form == 9) shape = sheep_shape(UV, instance_seed);
        else if (instance_form == 11) shape = cattle_shape(UV, instance_seed);
        // ... 其他动物
    }
    
    // 2. Alpha mask
    ALPHA = shape.x;
    
    // 3. 计算贴花
    vec2 decal = compute_decal_shape(instance_form, UV, instance_seed);
    
    // 4. 基础着色
    vec3 base_color = get_resource_color(instance_form);
    
    // 5. 形状+贴花 Shading
    if (instance_family == 0) {  // 植物
        vec3 plant_shading = plant_shading_function(UV, base_color, instance_form, instance_seed);
        base_color = mix(base_color, plant_shading, shape.x);
    }
    else if (instance_family == 1) {  // 动物
        vec3 animal_shading = animal_shading_function(UV, base_color, instance_form, instance_seed);
        base_color = mix(base_color, animal_shading, shape.x);
    }
    
    // 6. 贴花叠加
    vec3 decal_color = decal_shading(decal.x, instance_form, base_color, ground_color);
    base_color = mix(base_color, decal_color, decal.x);
    
    // 7. 光照（现有逻辑）
    base_color *= compute_lighting(...);
    
    ALBEDO = base_color;
}
```

### 4.3 GDScript调用

```gdscript
# resource_visual_layer.gd prepare_frame()

func prepare_frame(world_time: float, sun_dir: Vector3, params: Dictionary) -> void:
    # ... 现有逻辑 ...
    
    # 传递 sub_style 数据
    if _material != null:
        # 从 catalog 读取 sub_style 配置
        for i in _styles.size():
            var style = _styles[i]
            var sub_style = style.get("sub_style", 0)
            var shape_variant = style.get("shape_variant", 0)
            var decal_type = style.get("decal_type", 0)
            
            # 通过 instance_custom_data 传递
            # instance_custom_data.w 原来存 kind（1/2/3/4）
            # 可扩展到：
            # custom.x = cell_index
            # custom.y = style_index
            # custom.z = seed
            # custom.w = kind + sub_style * 0.01
            
            # 或者使用新的 uniform array
            _material.set_shader_parameter("sub_styles_%d" % i, sub_style)
```

---

## 第五部分：视觉对比表

### 植物对比

| 特征 | 小麦 | 玉米 | 水稻 | 土豆 |
|------|------|------|------|------|
| **高度** | 高 | 中 | 高 | 矮 |
| **宽度** | 窄 | 中粗 | 窄 | 宽 |
| **头部** | 尖锐 | 圆钝 | 弯垂 | 球形 |
| **颜色** | 金黄 | 金橙 | 米白/绿 | 深绿 |
| **纹理** | 细条纹 | 粗条纹 | 密粒 | 褶皱 |
| **贴花** | 根须 | 根须 | 根须 | 土壤 |
| **shade** | 竖条阴影 | 粗纹阴影 | 粒状阴影 | 叶面阴影 |

### 动物对比

| 特征 | 马 | 牛 | 羊 | 猪 |
|------|------|------|------|------|
| **高度** | 高 | 中 | 矮 | 矮 |
| **宽度** | 窄 | 宽 | 超宽 | 超宽 |
| **头部** | 细长 | 方大 | 圆 | 大方 |
| **角** | 无 | 有（横伸） | 小螺旋 | 无 |
| **特征** | 竖耳 | 垂耳+鼻 | 冲天毛 | 鼻子+卷尾 |
| **颜色** | 棕/黑 | 黑/棕/花纹 | 白/灰/黑 | 粉/黑/棕 |
| **毛发** | 顺向 | 短毛 | 蓬松 | 光滑 |

---

## 第六部分：性能与集成

### 性能成本分析

| 组件 | ALU | 采样 | 耗时 |
|------|-----|------|------|
| 植物 SDF | +8 | 0 | +2% |
| 动物 SDF | +12 | 0 | +3% |
| 贴花生成 | +6 | 0 | +1% |
| 细节法线 | +4 | 0 | +1% |
| Shading 增强 | +10 | 0 | +2% |
| **总计** | **+40** | **0** | **+9%** |

**当前** resource shader 相对主地形为 30%
**优化后** resource shader 相对主地形为 33%

仍在预算内，不增加纹理采样。

### 集成顺序

1. **第1天**：实现 4 种植物 SDF（wheat/corn/rice/leafy）
2. **第2天**：实现 4 种动物 SDF（horse/cattle/sheep/pig）
3. **第3天**：贴花系统 + Shading
4. **第4天**：测试 + 优化性能
5. **第5天**：其他植物/动物（形态库扩展）

---

## 附录：参考美术

建议收集以下参考图片，确保形状设计的准确性：

### 植物参考
- 小麦：直立、紧凑穗、顶端尖
- 玉米：粗短穗、圆钝端、有须根
- 水稻：细长、弯垂、粒状穗
- 土豆：球形叶丛、低矮、有褶皱

### 动物参考
- 马：细长、竖耳、长脖子
- 牛：宽矮、有角、鼻子突出
- 羊：球形、蓬松、冲天毛
- 猪：矩形、鼻子明显、卷尾

### 着色参考
- 毛发流向（顺毛、逆毛）
- 肌肉线条
- 光泽分布
- 土壤/根系纹理
