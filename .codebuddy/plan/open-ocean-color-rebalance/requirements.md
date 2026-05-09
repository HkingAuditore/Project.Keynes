# 外海视觉重平衡（Open Ocean Color Rebalance）需求文档

## 引言

当前游戏外海（远离海岸的开阔海域，对应 shader 中的 `open_ocean_w` 区域）存在以下视觉问题：

1. **整体色彩过蓝**：基础调色板 `color_deep_ocean = (0.055, 0.13, 0.30)` 以及 gyre patch（cobalt / teal / violet）和 abyss_tint 多层乘积叠加后，B 通道远高于 R/G，整张图给人"一片纯蓝"的压迫感。
2. **饱和度过高**：基础色与 patch 色在 HSV 空间饱和度普遍 ≥ 0.7，远高于真实卫星图与同类 4X 游戏（Civ VI / Old World）的外海观感（通常 0.45~0.60）。
3. **色彩均一、缺乏变化**：虽然现有 `deep_ocean_color_richness`（0.85）启用了纬度 / 洋流 / 深渊 / gyre patch 四层调制，但低频噪声幅度（patch fbm 频率 0.0056、calm_brightness ±8%、calm_tint ±3%）相对最终色乘积过小，肉眼难以分辨大块色斑变化。

本需求旨在：在**不破坏**现有海陆边界、深度梯度、洋流流纹、生物群系（lake / reef / kelp / ice）等已成型功能的前提下，仅通过调整外海调色板和已有调制层的强度，让外海呈现"更去饱和、更分层、更有云影感"的视觉效果。本需求不引入新功能模块、不增加新 uniform 数量级，只对现有参数做有据可依的重新配比。

> 注：本需求的范围是 **open ocean（开阔外海）**——即 shader 中 `open_ocean_w > 0` 的区域，包括 hypsometric 色阶里的 mid/basin/abyss 段。海岸/浅海（coast/shelf）色调一般已较舒服，需求 1 会确保浅海过渡不被恶化。Lake / Reef / Kelp / Sea Ice 不在本轮调整范围内。

---

## 需求

### 需求 1：降低外海整体饱和度

**用户故事：** 作为一名玩家，我希望外海看起来不像饱和度拉满的纯蓝塑料布，以便更接近真实海洋或同类策略游戏的观感。

#### 验收标准

1. WHEN 玩家观察远离海岸的开阔海域 THEN shader **SHALL** 输出在 HSV 空间饱和度（S）位于 [0.40, 0.62] 区间的颜色（当前峰值常见 ≥ 0.75）。
2. WHEN 调整生效后 THEN 画面中**最深处的外海像素**（offshore_depth ≥ 0.85） **SHALL NOT** 比当前再加蓝（B 通道不能进一步增大）。
3. IF `deep_ocean_color_richness = 0` 或 `water_cartoon_color_strength = 0`（旧视觉关闭路径） THEN 系统 **SHALL** 保持与当前完全相同的输出（向后兼容兜底）。
4. IF 海陆边界 ±2 个像素带（near_surface > 0.5 区域） THEN 系统 **SHALL NOT** 出现新的色阶断裂或额外饱和度跳变。

---

### 需求 2：增强外海大尺度色彩变化（去均一化）

**用户故事：** 作为一名玩家，我希望开阔海域不再"一抹蓝到底"，而是能看到淡淡的、像云影或洋流团块一样的大色块起伏，以便地图视觉信息更丰富。

#### 验收标准

1. WHEN 玩家观察至少 20×20 hex 范围的开阔外海 THEN 该区域 **SHALL** 至少呈现 2~3 个肉眼可辨的大色块差异（亮度 ΔL ≥ 0.05 或色相 Δhue ≥ 6°）。
2. WHEN `visual_quality >= 1` THEN 大尺度色块 **SHALL** 随 `world_time` 缓慢漂移（与现有 gyre fbm 的 `world_time * 0.012` 速率一致或更慢，不引入新的高频抖动）。
3. WHEN 玩家暂停游戏（world_time 不前进） THEN 大色块 **SHALL** 保持空间分布稳定，不出现因 fbm 频率过高产生的"麻点感"。
4. IF `visual_quality == 0`（低端机） THEN 系统 **SHALL** 至少保留静态空间色斑（来自 `gyre_a` 或同等低频 fbm），且每帧成本不超过当前低端档位。

---

### 需求 3：保留并增强冷暖色温分层

**用户故事：** 作为一名玩家，我希望热带海域偏向青绿、温带海域偏中性、极地海域偏冷青，且这种纬度色温差异要比当前更明显但不夸张，以便地图传达气候带信息。

#### 验收标准

1. WHEN 同一地图同时存在低纬（|lat| < 0.25）与高纬（|lat| > 0.7）外海 THEN 两区域颜色 **SHALL** 在色相上呈现可辨差异（Δhue ≥ 8°），当前默认配置下肉眼几乎看不出来。
2. WHEN 启用 `deep_ocean_latitude_tint_strength` 默认值 THEN 热带外海 **SHALL** 略偏青绿（G > B 在 tint 倍率上的相对差不缩减），极地外海 **SHALL** 略偏冷青（B 略提，但不增加饱和度）。
3. WHEN `deep_ocean_current_tint_strength > 0` 且洋流向量明显（flow_mag > 0.2） THEN 暖流 / 寒流 **SHALL** 仍保留现有暖偏 / 冷偏方向，不与需求 1 的全局去饱和冲突（即在去饱和后的 base 上再做 ±10% 的色温偏移）。
4. WHEN 季节切换 THEN 极地外海色温 **SHALL** 与季节温度 `current_temp` 协同（夏季略暖、冬季略冷），变化幅度不超过 ±5%。

---

### 需求 4：保持深度色阶可读性，弱化"过深处过黑"现象

**用户故事：** 作为一名玩家，我希望从海岸到外海的深度变化仍然清晰可读，但最深处（abyss）不要因为多层 tint 叠乘而显得灰蓝压抑。

#### 验收标准

1. WHEN 玩家观察从 coast → shelf → mid → basin → abyss 的连续渐变 THEN 五个色层 **SHALL** 在亮度上仍呈现单调递减（避免任何中间段比 abyss 还暗）。
2. WHEN `deep_ocean_abyss_tint_strength` 默认生效 THEN abyss 段亮度 **SHALL** 比当前略提升（不再被 `0.90 * (0.82, 0.90, 1.08)` 双重压暗），但仍保持 cool 偏移方向。
3. IF 玩家在调试控制台手动把 `deep_ocean_color_richness` 拉到 1.0 THEN 系统 **SHALL NOT** 出现因 tint 乘法叠加导致的局部色彩溢出（即任意通道不应 > 1.4 触发 clamp 上限）。
4. WHEN 接近海岸的"shallow_lift"区域 THEN 该区域 **SHALL** 仍保持当前的浅水回提逻辑，不被全局去饱和误伤。

---

### 需求 5：参数可调与回滚兜底

**用户故事：** 作为美术 / 策划，我希望本次外海调整全部体现为可调 export 参数或现有 uniform 默认值修改，以便后续微调或全部回滚到旧视觉，无需 git revert 大块代码。

#### 验收标准

1. WHEN 本次需求实现完成 THEN 所有视觉修改 **SHALL** 通过 `hex_renderer.gd` 已有的 `@export` 默认值或 `world_map.gdshader` 已有 uniform 默认值变更承载，**禁止**新增超过 2 个新 uniform。
2. IF 必须新增 uniform（如全局去饱和因子） THEN 该 uniform **SHALL** 在 0.0 等价于"完全保持旧视觉"，并在 `_apply_uniforms()` 与对应 setter 中正确推送。
3. WHEN 本需求实现后玩家把所有相关参数设为旧默认值 THEN 渲染输出 **SHALL** 与本次提交前的视觉完全一致（pixel-equivalent allowed tolerance ≤ 1/255 per channel due to float drift）。
4. WHEN 文档（如本文件或代码注释）提及参数调整 THEN **SHALL** 同时给出"旧值 / 新值 / 视觉影响一句话"三元组，方便后续回顾。

---

### 需求 6：性能保持

**用户故事：** 作为一名玩家，我希望外海视觉优化不引起任何可感知的帧率下降。

#### 验收标准

1. WHEN 在标准 60×40 地图、`visual_quality = 2` 下运行 30 秒 THEN HexRenderer 的 `PerfSampler` 输出的 avg / P95 **SHALL** 与本次提交前差异 ≤ ±5%。
2. WHEN `visual_quality = 0`（低端档位） THEN 本需求 **SHALL NOT** 引入任何新的 fbm 调用或 texture sample（只允许 vec3 系数级别的乘加变化）。
3. IF 本需求需要调整 fbm 八度数（octaves） THEN 在 `visual_quality == 0` 路径下八度数 **SHALL** 保持当前值或更低。

---

## 不在本需求范围内的事项

以下事项明确**不**在本轮需求中处理，避免范围蔓延：

- 海岸光晕（coast_halo）色彩与强度调整
- Lake / Reef / Kelp / Sea Ice 等特殊水体的调色
- 河流（river）色彩
- 洋流流纹（streak）的形状与速度
- 海冰、季节性冻结、洋流烘焙逻辑
- 天气 overlay（雨、云、雪）相关效果
- 地形（陆地）调色板
- 后期处理（如全屏 grading / bloom），目前项目未启用全屏后处理
