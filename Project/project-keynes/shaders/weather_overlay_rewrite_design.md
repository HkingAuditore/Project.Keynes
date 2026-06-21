# weather_overlay.gdshader 重写设计文档

> 状态：**已实施（2026-06-19）** — shader 重写完成，原文件备份为 `weather_overlay.gdshader.bak`
> 目标读者：维护者本人
> 关联文件：`shaders/weather_overlay.gdshader`（1220 → 656 行）、`scripts/rendering/weather_layer.gd`
>
> ## ⚠ 实施时的重大更正（务必先读）
> 设计阶段 §11 推测“field 是主力、fronts 冗余”，**实际恰好相反**：
> `main.gd` 已停用 `weather_field_tex`（每次天气更新 `set_weather_field_texture(null)`），
> shader 里 `weather_field_enabled` 默认 false，`sample_weather_field`（220 行）+ merge 全是**死代码**；
> 当前所有云 **100% 来自 fronts 通路**。
> 因此最终实施为：**删 field 死通路、保留并精简 fronts 通路**（决策对象与初稿相反）。
> 其余按用户确认执行：删纹理噪声 / `noise_tex`、雨雪闪电改 `cloud_fbm`、删 debug、4 层云→3 层、双光照→单光照。

---

## 0. 一句话目标

把现在 1220 行、两套噪声、两条天气通路、四层云互相纠缠的 shader，
重写成 **~400–450 行、单噪声系统、单数据通路、固定合成顺序、参数可独立调** 的版本，
在 **沿用现有 `weather_field_tex`（nearest）** 的前提下消除块状 / 接缝 / 内部高对比。

保留：雨幕雪粒、雷暴闪电、高层卷云、低层山雾、昼夜光照（TOD）、移动端质量档。
移除：debug 可视化、纹理噪声系统、front 第二通路（**待你拍板**，见 §11）、`apply_cloud_tod` 重复光照、已删的 ambient shadow。

---

## 1. 现状为什么不可维护（诊断回顾）

| 根源 | 现状证据 | 后果 |
|---|---|---|
| 两套噪声并存 | 旧纹理 `value_noise`/`fbm`/`blue_jitter`(81–141) + 新解析 `cloud_*`(159–249) | 云生成两种方式、效果不一致；cell 通路用 `fbm` 出马赛克（作者注释 698–700 自认） |
| 两条天气通路 | `sample_weather_field`(526–746, **220行**) + `sample_front_field` fronts 循环(748–875) + merge(850–874) | 同一件事两种实现，merge 处反复硬边（851–857 补丁） |
| hex 离散硬抹平 | `mountain_w` 6 邻域(980–1021)、field 6 邻域(593–651) | `filter_nearest` 整数纹理渲染连续云的根本矛盾，邻域采样既贵又抹不干净 |
| 参数连乘耦合 | `cloud = density*envelope*type_bias*mix(...)`(812) 等 | 一个视觉量 7–8 个因子连乘，改一个全乱 |

文件里 **30+ 处 `N8/N10/N11/N12/N13/回滚/perf` 日期补丁注释** = 增量打补丁到失控的直接证据。

---

## 2. 输入契约（沿用现有，不改 CPU 端）

重写后只消费以下输入，其余 uniform 全部移除。

### 2.1 纹理

| uniform | 过滤 | 编码 | 用途 |
|---|---|---|---|
| `weather_field_tex` | `filter_nearest` | **R**=天气类型×255，**G**=intensity[0,1]，**B**=cloud_amount[0,1]，**A**=precip[0,1] | 唯一天气数据源 |
| `map_index_atlas` | `filter_nearest` | **R**=biome id×255 | `is_water`、山地权重（低雾） |
| `noise_tex` | linear+mipmap | RGBA 预烘 fbm | **云形不再使用**；仅雨雪/闪电高频条纹按需保留（见 §5） |

> `weather_field_tex` 由 `field_solver.gd` → `DCWorldExt.run_weather_field_solve_pass`（C++）生成，
> 经 `weather_layer.set_weather_field_texture()` 推入。重写**不改**这条生产链。

### 2.2 标量 / 数组 uniform（保留）

- 世界：`world_origin`、`world_size`、`world_time`、`hex_world_diameter`
- TOD：`tod_sun_dir`、`tod_sun_color`、`tod_ambient_color`、`tod_night_factor`、`tod_exposure`、`day_night_enabled`、`cloud_tod_tint_enabled`
- 全局：`weather_strength`、`weather_overlay_quality`、`storm_flash`
- 天气表：`weather_profile_colors[8]`、`weather_profile_flags[8]`
- 常量：`WT_*`(0–7)、`FLAG_*`、`B_*`(biome)

### 2.3 移除的 uniform

- `debug_uv_mode`（连同 fragment 4 个分支）
- `weather_front_centers/shapes/visuals/types[]` + `weather_front_count`（若删 fronts 通路，§11）
- `heatwave_distortion`、`extreme_weather_ground_effect_enabled`、`day_phase`（当前未实质使用 / 可并入）
- `ambient_*`（已删）、`vector_atlas`（已退役）

---

## 3. 目标架构（数据流）

```
fragment():
  wp = v_world ;  uv = (wp - world_origin)/world_size

  ┌─ 1. 采样天气场（唯一通路） ───────────────────────────────
  │   FieldSample f = sample_field(uv, wp)
  │     · 4~5 点 golden-angle 邻域，只平滑 cloud_amount / intensity / precip
  │     · color/alpha = 按平滑 cloud_amount 加权混合 profile_colors
  │     · wt = 主像素类型（离散，仅用于分支与 flags）
  └──────────────────────────────────────────────────────────
  ┌─ 2. 地形权重 ─────────────────────────────────────────────
  │   biome = map_index_atlas.r   →  is_water,  mountain_w（低雾用，4点平滑）
  └──────────────────────────────────────────────────────────
  ┌─ 3. 云生成（全解析噪声） ────────────────────────────────
  │   coverage = f.cloud_amount
  │   main  = cloud_density_soft(advect(wp, f.axis), coverage, seed)   // 主云
  │   cirrus= sample_high_cloud(wp, cirrus_axis, cirrus_cov)           // q>=1
  │   fog   = sample_low_fog(wp, f.axis, fog_int, mountain_w)          // 可选
  └──────────────────────────────────────────────────────────
  ┌─ 4. 早退 ────────────────────────────────────────────────
  │   if (main+cirrus+fog 全 < eps) { COLOR=vec4(0); return区 }
  └──────────────────────────────────────────────────────────
  ┌─ 5. 着色 + 固定顺序合成 ─────────────────────────────────
  │   col,alpha = fog 层
  │   over main 层 ( compute_cloud_lighting )  + 地面投影阴影 f.shadow
  │   over rain / snow ( flags )
  │   over cirrus 层
  │   over lightning ( flags & !is_water )
  └──────────────────────────────────────────────────────────
  COLOR = vec4(col, alpha)
```

**核心原则**：`cloud_amount` 只用来**调阈值**（threshold modulator），绝不做乘性 mask。
云形状 100% 来自解析噪声过阈值，这样 hex 离散只影响"哪一带有多少云"，不影响云的轮廓 → 从机制上免疫六边形锯齿。（这一点现有代码 §710–717 的思路是对的，重写保留并贯彻到所有层。）

---

## 4. 单一噪声系统

**保留（解析，无纹理网格）**

| 函数 | 现行号 | 作用 |
|---|---|---|
| `cloud_hash22` / `cloud_grad_noise` | 159–187 | Perlin 梯度噪声，quintic 插值 |
| `cloud_fbm` | 183 | 旋转去相关 FBM |
| `cloud_fbm_evolve` | 200 | 带时间演化 FBM（云内部翻腾） |
| `cloud_ridged_evolve` | 218 | ridged 鼓包（蓬松感，**低权重**） |
| `cloud_domain_warp` | 237 | IQ 域扭曲 |
| `cloud_erode` | 243 | 边缘侵蚀 |
| `cloud_density_soft` | 251 | **主云密度**（云体核心，复用） |

**删除（纹理噪声）**：`value_noise`(81)、`fbm`(90)、`hash21`(115)、`hash_signed`(125)、`blue_jitter`(129)、`noise_tex` 的云用途。

**雨雪/闪电的 `fbm` 调用**（895/896/905/917/918/1207）：
这些是高频条纹/颗粒，纹理 fbm 视觉可接受。两个选项：
- **A（推荐，彻底单一化）**：改用 `cloud_fbm`，可整条删除纹理噪声与 `noise_tex` 依赖。
- B（省事）：保留一个轻量纹理 `fbm` 仅供雨雪闪电，云形用解析。
> 推荐 A——少一个采样器、少一套频谱，雨雪条纹用 `cloud_fbm` 视觉无损。

---

## 5. 单一数据通路 + 最小 hex 平滑

现状把 **6 个量**（cloud/intensity/precip/type_bias/color/alpha）全做 6 邻域加权（593–651），这是最大的复杂度与开销来源。

**重写方案 `sample_field(uv, wp)`：**

1. 主采样 `weather_field_tex(uv)` → 拿到 `wt`（离散，用于分支/flags/profile 索引）。
2. **只对 `cloud_amount / intensity / precip` 做一次邻域平滑**：4~5 点 golden-angle，偏移按 `hex_world_diameter` 物理换算（沿用现有 ring step 思路，但点数减半）。
3. `color/alpha`：用平滑后的 `cloud_amount` 作权重混合 `weather_profile_colors[wt]`（不再单独 6 邻域累加颜色——用主像素 wt 的颜色 × 平滑 coverage 已足够，过渡靠 coverage 连续性）。
4. `axis`：用一个全局缓变风向（`normalize(vec2(1.0, 0.22))` 之类）或从 intensity 派生，不再做 per-cell 风场（现有 `sample_wind` 已是空 stub，return 0）。

> **为什么还要平滑**：你选择保留 `weather_field_tex` 的 `filter_nearest`，cell 边界天然阶跃，必须在 shader 里平滑一次 coverage。
> **可选的彻底解法（标注，非本次范围）**：CPU 端把天气场以**低分辨率 + `filter_linear`** 烘成纹理，shader 直接双线性采样，可**整段删除邻域平滑**（更省更干净）。若日后愿意改一行 `ImageTexture` 过滤设置 + 让 solver 输出小图，这是最优解。

---

## 6. 云层（4 层 → 3 层）

| 层 | 函数（复用） | 质量门 | 说明 |
|---|---|---|---|
| 主云 cumulus | `cloud_density_soft` + `sample_cumulus_layer`(429) | 全档 | 视觉主角 |
| 高云 cirrus | `sample_high_cloud`(387) | q≥1 | 各向异性拉丝薄纱 |
| 低雾 fog | `sample_low_fog`(412) | q≥1 | 贴地，`mountain_w` 调制 |

**删除 `front_layer`（第四层）**：现有 fragment 1114 的 `front_layer` 实际是"复用 cumulus 形状 + front 颜色/阴影"（代码注释 1112–1113 自述"避免重影"）。重写后主云直接吃 `f.color/f.shadow`，`front_layer` 这一层取消。

---

## 7. 光照（2 套 → 1 套）

- **保留 `compute_cloud_lighting`**(343)：当前版本已做过对比柔化（密度连续着色 + `light_grad` 迎背光 + 银边 + 暗部下限抬高），是好的基础。
- **删除 `apply_cloud_tod`**(923)：与 `compute_cloud_lighting` 功能重叠，二选一。
- **`light_grad` 探针**（1080–1090）：保留 1 次太阳方向密度探针；q0 档关闭（省 1 次 `cloud_density_soft`）。
- `apply_cloud_layer`(371) 保留作为统一的 over 混合器。

---

## 8. 固定合成顺序

```
col, alpha ← 透明
fog    →  apply_cloud_layer(...)                         // 底
main   →  compute_cloud_lighting + 地面阴影 f.shadow      // 主体
rain   →  if flags&RAIN_STREAK  : mix + 压暗地面          // 降水
snow   →  if flags&SNOW_GRAIN   : mix
cirrus →  apply_cloud_layer(...)                         // 高空薄纱
bolt   →  if flags&LIGHTNING && !is_water : 叠加白闪
COLOR = vec4(clamp(col), clamp(alpha))
```

雨/雪/闪电函数 `rain_field`(886)、`snow_field`(912) 基本保留（按 §4 决定噪声来源），闪电逻辑保留（1203–1213）。

---

## 9. 质量档预算（`weather_overlay_quality` + MOBILE 宏）

| 档 | base_oct | ridge_oct | cirrus | fog | light 探针 | 目标设备 |
|---|---|---|---|---|---|---|
| q0 LOW | 3 | 0 | 关 | 关 | 关 | 移动低端 |
| q1 MID | 4 | 1 | 开 | 开 | 开 | 移动中端 / 低端 PC |
| q2 HIGH | 5 | 2 | 开 | 开 | 开 | PC |

`effective_weather_quality()`(136) 保留，`MOBILE_QUALITY_LOW/MID` 宏钳制逻辑保留。

---

## 10. 移除清单（明确可勾选）

- [ ] `debug_uv_mode` uniform + fragment 4 分支(947–958)
- [ ] 纹理噪声：`value_noise` / `fbm` / `hash21` / `hash_signed` / `blue_jitter`
- [ ] `noise_tex` 的云形用途（若 §4 选 A，连采样器一起删）
- [ ] `apply_cloud_tod`(923)
- [ ] `front_layer` 第四层(1114–1134)
- [ ] `mountain_w` / field 的 6 邻域 → 降为 4~5 点单次平滑
- [ ] fronts 通路（§11，**待确认**）
- [ ] 30+ 处历史补丁注释（N8/N10.../回滚/perf）

---

## 11. ⚠ 待你拍板的关键决策

### 决策 A：fronts 第二通路 删 or 留？（影响最大）

- **现状**：`weather_front_*[]` 16 个椭圆，提供"局部强对流团块"，与 field 大尺度云带 merge。
- **疑问**：`weather_field_tex` 已**逐 cell** 含 `intensity/precip/cloud_amount`，理论上已能表达局部强对流（高 intensity 的 cell 簇）。若如此，fronts 是历史冗余，删掉可省 §2.3 一组数组 uniform + 整个 fronts 循环 + merge（约 250 行）。
- **风险**：若 fronts 承载了 field 纹理**没有**的信息（如亚 cell 精度的平滑团块运动、CPU 端 front 物理），删除会丢表现。
- **建议**：实施前我去查 `field_solver` / `weather_system` 确认 field 是否已含强对流；**倾向删 fronts、走纯 field**。← 需你同意我去查并据此决定。

### 决策 B：是否接受"CPU 出 linear 小图"的彻底解法？

- 你已选"沿用 nearest + shader 内最小平滑"，本设计据此。
- 但若愿意改 solver 输出（低分辨率 linear 纹理），可**整段删除邻域平滑**，更省更干净。作为可选升级记录在此。

### 决策 C：雨雪闪电噪声 → §4 的 A（改解析）还是 B（保留轻量纹理 fbm）？

---

## 12. 预计产出

- 行数：**~400–450**（现 1220）
- 函数数：~40 → **~18**
- uniform 数：~30 → **~20**
- 每像素纹理采样：显著下降（删 6 邻域 ×2、删 noise_tex 云用途、删 light 多探针的可选关闭）

## 13. 实施步骤（决定动手后）

1. 备份现 shader 为 `weather_overlay_legacy.gdshader`。
2. 按 §2 写 uniform 子集 + 常量。
3. 移植解析噪声块（§4 保留项，原样搬）。
4. 写 `sample_field`（§5）。
5. 云生成 3 层 + `compute_cloud_lighting` + 合成（§3/§6/§7/§8）。
6. 雨雪闪电（§8，噪声按决策 C）。
7. 质量档分支（§9）。
8. 同步 `weather_layer.gd`：删 fronts / debug 推送（按决策 A）。
9. 验证：各天气类型、质量档、移动宏、性能对比。

---

*本文档仅为设计，未改动任何 `.gdshader` / `.gd` 代码。确认 §11 三个决策后即可进入实施。*
