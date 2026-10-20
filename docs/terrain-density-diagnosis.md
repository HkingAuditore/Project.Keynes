# 大地图生成机制诊断报告：河流与高原过度密集问题

> 诊断日期：2026-06-30
> 范围：仅诊断，未修改任何代码
> 涉及代码：`gdext/src/world_ext_generate.cpp`、`gdext/src/world_ext_bake.cpp`、`gdext/src/world_ext_internal.h`、`scripts/data/climate_profile.gd`、`scripts/geography/map_config.gd`、`scripts/main.gd`

---

## 0. 背景与关键事实确认

在进入根因之前，先确认几个影响判断的基础事实，它们决定了哪些机制在什么尺度下真正起作用。

### 0.1 实际运行参数（非 map_config 默认值）

| 参数 | map_config.gd 默认 | **实际运行值** | 来源 |
|------|-------------------|----------------|------|
| `sea_level` | 0.64 | **0.42** | `main.gd:116` → `cfg.sea_level = sea_level`（`main.gd:1954`），`world_setup.gd:22` UI 默认 0.42，`world_data.gd:79` 注释"与 cfg.sea_level 一致" |
| `num_continents` | 3 | **2** | `main.gd:114`，`world_setup.gd:23` |

**影响**：`sea_level=0.42` 意味着陆地范围 `E ∈ [0.42, 1.0]`，归一化陆地海拔 `land_h = (E-0.42)/0.58`。高原判定区间 `land_h ∈ [0.25, 0.90]` 对应 `E ∈ [0.565, 0.942]`——**覆盖了陆地海拔的绝大部分中高段**，这是高原候选范围偏大的基础。

### 0.2 地图尺寸与缩放基准的错配

UI 预设（`world_setup.gd:11-16`）：
- 小 40×28 = 1,120 cells
- 当前 60×40 = 2,400 cells
- 大 100×64 = **6,400 cells**
- 自定义上限 500×400 = 200,000 cells

河流缩放基准（`world_ext_generate.cpp:1544`）：
```cpp
constexpr double river_map_reference_cells = 15000.0;
constexpr double river_map_scale_exponent = 0.65;
const double river_map_scale = std::pow(
        std::max(1.0, double(n) / river_map_reference_cells),  // ← max(1.0, ...)
        river_map_scale_exponent);
```

**关键错配**：`max(1.0, n/15000)` 使得 **所有 N ≤ 15,000 的地图（即全部 UI 预设，包括"大 100×64"）`river_map_scale` 恒为 1.0**，缩放机制完全不起作用。只有自定义尺寸超过 150×100 基准（如 200×150=30,000、500×400=200,000）才会触发缩放。

因此诊断必须分两个尺度区间：
- **区间 A（N ≤ 15,000，全部预设）**：缩放失效，问题来自经验阈值本身与结构性缺失
- **区间 B（N > 15,000，自定义大地图）**：缩放生效但指数不足，是额外的放大因素

### 0.3 判定层级

| 地貌 | 判定层级 | 文件 | 是否受地图缩放 |
|------|----------|------|----------------|
| 河流 | Cell 级（post_base pass） | `world_ext_generate.cpp` | 仅 channel_init 按 N^0.65（且 N>15000 才生效） |
| 高原 | Cell 级（post_base pass） | `world_ext_generate.cpp` | **完全无缩放** |
| 像素侵蚀 | Pixel 级（bake pass） | `world_ext_bake.cpp` | droplet 数量固定，不随面积缩放 |

像素级侵蚀（`run_bake_erosion_pass`）**不回写 cell 高程 `E[]`**，只影响视觉渲染，不直接改变 landform 判定。

---

## 1. 河流过度密集：根因列表（按可能性从高到低）

### ★★★ 原因 1：channel_init 经验阈值在预设尺寸下本身就偏密，且缩放机制对预设尺寸完全失效

**位置**：`world_ext_generate.cpp:1541-1553`、`ClimateProfile:512`

**机制**：
- `river_channel_init_cells = 16`，注释（`ClimateProfile:509-510`）实测在 150×100 地图上"16→~300 格(适中)"。
- 但实际运行的全部 UI 预设（最大 100×64=6,400）都 **远小于 150×100 调参基准**，`max(1.0, n/15000)=1.0` 使 `river_map_scale` 恒为 1.0，`channel_init` 保持 16 不变。
- 在 6,400 cell 的地图上，若陆地占 ~60% ≈ 3,840 cell，"~300 格成河"意味着 **河流占陆地约 8%**——对一张 6400 格的图而言已相当密集。这个阈值是为 15,000 cell 调的，直接套用到更小地图上必然偏密。
- 更关键的是：缩放只做"向上"（N>15000 才放大阈值），**不会因为 N<15000 而缩小阈值**（开发者注释明说"keep small/normal maps unchanged"）。这意味着小/中地图没有获得更严格（更小 N 对应更大 channel_init/N 比例）的补偿。

**为何最可能**：这是在当前所有预设尺寸下都会触发的第一层原因，无需地图特别大即可观察到密集。任何使用预设尺寸的玩家都会命中。

---

### ★★★ 原因 2：自定义大地图（N>15,000）下，缩放指数 0.65 亚线性不足

**位置**：`world_ext_generate.cpp:1546`（`river_map_scale_exponent = 0.65`）、`world_ext_generate.cpp:2017-2032`（河道选择）

**机制**：
- 河道选择基于 `up_count >= channel_init`，其中 `up_count` 是上游汇水格数。
- `up_count` 随流域面积近似 **线性增长（~N^1.0）**，而 `channel_init` 按 **N^0.65** 缩放。
- 增长速率差：N^1.0 − N^0.65，随 N 增大而扩大 → 更多 cell 满足 `up_count >= channel_init` → 河流密度上升。

| N | 地图尺寸 | river_map_scale | channel_init | channel_init/N | 上游汇水典型值 |
|---|---------|-----------------|--------------|----------------|--------------|
| 15,000 | 150×100（基准） | 1.0 | 16 | 0.107% | ~基准 |
| 30,000 | 200×150 | ~1.57 | ~25 | 0.083% | ~2× |
| 60,000 | 300×200 | ~2.49 | ~40 | 0.067% | ~4× |
| 200,000 | 500×400 | ~7.03 | ~112 | 0.056% | ~13× |

- 要让相对密度恒定，指数应为 **1.0**；要让大地图更稀疏（视觉清晰），应 **>1.0**。当前 0.65 不充分。

**为何高可能**：仅当用户使用自定义大尺寸时触发，但一旦触发就是主导因素。

---

### ★★☆ 原因 3：headwater trace 用更低阈值主动补充支流

**位置**：`world_ext_generate.cpp:2033-2060`、`ClimateProfile:513`（`river_headwater_init_cells = 6`）

**机制**：
- 即使某 cell 未达 `channel_init`（16），只要 `up_count >= river_headwater_init`（6，同样按 N^0.65 缩放但仅在 N>15000 生效），就会沿父图向下游 trace，直到碰到已有河道或水体，路径上全部标为河流。
- 这相当于用 **1/2.67 的更低阈值**主动"接支流"，显著增加支流密度。
- `river_headwater_min_land_h = 0.30` 限制了只在较高海拔河源才 trace，但 0.30 的陆地海拔门槛很低，大量丘陵区都会触发。

---

### ★★☆ 原因 4：up_count 无 N 归一化，与同文件 SPL 侵蚀的 area 归一化不一致

**位置**：`world_ext_generate.cpp:2017-2032`（河道选择，无归一化）vs `world_ext_generate.cpp:868-885`（SPL 侵蚀，有归一化）

**机制**：
- SPL 侵蚀正确地做了归一化：
  ```cpp
  double area_mean = 0.0;
  for (int i = 0; i < n; ++i) area_mean += area[size_t(i)];
  const double inv_area_mean = 1.0 / std::max(1.0, area_mean / double(std::max(1, n)));
  const double C = spl_k * std::pow(area[size_t(i)] * inv_area_mean, spl_m);
  ```
- 但河道选择的 `up_count` 是**原始格数**，没有任何 `up_count / N` 归一化。这是同一文件内的设计不一致。
- 后果：大地图下下游 cell 的 `up_count` 数值天然更大，绝对阈值 `channel_init` 更容易被超过。

---

### ★★☆ 原因 5：最短河长剪枝阈值过低且缩放更弱

**位置**：`world_ext_generate.cpp:1553`、`ClimateProfile:520`（`hydro_river_min_length = 5`）

**机制**：
- 剪枝公式：`hydro_river_min_length = round(5 × pow(river_map_scale, 0.75))`，即 N^0.4875。
- 这是**比河道阈值更弱的缩放**（0.4875 < 0.65），意味着大地图下剪枝力度的增长比成河阈值的增长更慢 → 短支流更不容易被剪掉。
- 注释（`ClimateProfile:519`）："8→5。降低最短河长门槛，让中短支流也能绘出，水网更密"——这是 2026-06-19 为增加支流而主动降低的，本身就是"加密"方向的改动。

---

### ★☆☆ 原因 6：无间距/数量约束机制

**位置**：全文搜索确认

**机制**：
- 不存在 `river_spacing`、`max_rivers`、`max_branches` 等限制。
- 任何满足 `up_count >= channel_init` 的 cell 都会成为河流，唯一的后置约束是"孤立短段/不接触水体"剪枝（`world_ext_generate.cpp:2063-2101`），**不影响已连通河网密度**。
- 对比：PEAK 有 `land/120` 限量，RIFT 有 `land/140` 限量，河流无任何限量。

---

### ☆☆☆ 原因 7：视觉层放大——stamp 最小半径、warp 扰动、SDF 光晕

**位置**：`world_ext_bake.cpp:692,721`（stamp）、`world_ext_bake.cpp:598`（warp）、`world_ext_bake.cpp:551,910`（SDF）

**机制**（不增加河流数量，仅加剧视觉密集感）：
- stamp 宽度乘子 `0.40 + pow(wmax, 1.4) * 3.7`，**最小支流也有 0.40×base_radius_px 宽度**，不收成尖点。
- `warp_amp = hex_size * 0.30`，路径横向扰动 ±0.3 hex，相邻河流 warp 可视觉重叠。
- `sdf_max_dist_px`（默认 5.0）控制距离场衰减，值越大河流"光晕"越宽。
- `flow` 无 N 归一化（`world_ext_generate.cpp:1993-2010`），大地图 `max_river_flow` 更大，log 归一化后中下游河段更粗。

---

## 2. 高原过度密集：根因列表（按可能性从高到低）

### ★★★ 原因 1：PLATEAU 完全没有密度上限（结构性缺失）

**位置**：`world_ext_generate.cpp:2979-3025`（高原判定）vs `world_ext_generate.cpp:3105`（PEAK 限量）vs `world_ext_generate.cpp:3166`（RIFT 限量）

**机制**：
```cpp
// PEAK 稀疏化 — 有上限
const int peak_limit = std::max(1, int(land.size()) / peak_land_cells_per_peak);  // land/120

// RIFT_VALLEY 稀疏化 — 有上限
const int rift_limit = std::min(48, std::max(4, int(land.size()) / 140));  // land/140

// PLATEAU — 无任何上限，所有满足条件的连通分量（≥3 cell）全部标为 PLATEAU
```
- 所有满足 `land_h ∈ [0.25, 0.90]` 且 `relief ≤ 0.14` 的连通分量（≥ `plateau_min_cells=3`）**全部**标为 PLATEAU。
- 没有总面积占比上限、没有数量上限、没有间距约束。
- 这是与 PEAK/RIFT 形成对比的明显结构性缺失，是高原"铺满"的最直接原因。

---

### ★★★ 原因 2：高原阈值不随地图缩放，与河流的缩放设计形成对比

**位置**：`world_ext_generate.cpp:1533-1535`、`ClimateProfile:1256-1258`

**机制**：
- 河流阈值有 `river_map_scale`（尽管不充分），但高原三个阈值**完全没有缩放机制**：
  ```cpp
  const double plateau_min_land_h = getd(profile, "plateau_min_land_h", 0.25);    // 固定
  const double plateau_max_relief = std::max(0.0, getd(profile, "plateau_max_relief", 0.14)); // 固定
  const int plateau_min_cells = std::max(1, geti(profile, "plateau_min_cells", 3)); // 固定
  ```
- **大地图精细采样的副作用**：cell 越多，六邻域采样的高差 `max_e - min_e`（per-cell relief）自然变小（同样坡度被切分成更多 cell，相邻 cell 高差更小）→ 更多区域 `relief < 0.14` → 更多高原。
- `plateau_min_cells = 3` 在大地图上几乎不构成过滤（3 个 cell 在 200,000 cell 图上微不足道）。

---

### ★★★ 原因 3：噪声在归一化 [0,1] 空间采样，造山带特征数固定不随地图增长

**位置**：`world_ext_generate.cpp:654-660`（采样）、`world_ext_generate.cpp:345-375`（噪声参数，全部硬编码）

**机制**：
```cpp
const double ny = double(row) * inv_h;      // = row / height ∈ [0,1]
const double lon = double(col) / double(width); // ∈ [0,1)
// cyl_noise 第四参数是固定空间缩放（如 95.0、70.0），不随地图尺寸变化
const double macro = cyl_noise(height_noise.ptr(), ct, st, ny, 95.0, 701.0, -419.0, 0.0);
const double belt_n = cyl_noise(detail_noise.ptr(), ct, st, ny, 70.0, 137.0, -91.0, 0.0);
```
- 噪声频率 `0.014`（`height_noise`）、`0.040`（`detail_noise`）在归一化空间固定 → **造山带（orogeny belt）的数量是固定的**，不随地图变大而增多。
- 每条造山带过渡区在归一化坐标中的**宽度比例固定** → 大地图（更多 cell）下，每条过渡区覆盖**更多 cell** → 更多 cell 的 `land_h` 落入高原海拔区间 [0.25, 0.70]。
- 这些参数**全部硬编码在 C++ 中**，不从 knobs/ClimateProfile 传入，无法通过配置调整。

---

### ★★☆ 原因 4：高原海拔区间过宽，覆盖陆地大部分中高海拔

**位置**：`world_ext_internal.h:1104-1126`（landform 派生）、`world_ext_generate.cpp:2982-3000`（高原 override）

**机制**：
- `sea_level = 0.42`，`land_h = (E-0.42)/0.58`。
- 高原候选区间 `land_h ∈ [0.25, 0.90]` → `E ∈ [0.565, 0.942]`。
- 基础 landform 分段：`land_h > 0.70` 为 MOUNTAIN、`> 0.22` 为 HILL。高原 override 会把 HILL（0.22~0.70）和部分 MOUNTAIN 区都纳入候选。
- 结合 `plateau_max_relief = 0.14`（较宽松），大片中等海拔、起伏平缓的区域都会被标为高原。

---

### ★★☆ 原因 5：双峰地台模型产出大面积平坦中等海拔区

**位置**：`world_ext_internal.h:1316-1341`、`world_ext_generate.cpp:691-718`

**机制**：
```cpp
constexpr double PK_PLATFORM_H = 0.07;        // 大陆地台高出海平面的平坦基面
constexpr double PK_PLATFORM_UNDULATE = 0.03; // 地台大尺度起伏（很小）
constexpr double PK_OROGENY_AMP = 0.48;       // 造山带最大抬升
constexpr double PK_OROG_BELT_LO = 0.42;      // 造山带 belt 下阈
constexpr double PK_OROG_BELT_HI = 0.72;      // 造山带 belt 上阈
```
- 内陆高程合成：`e_out = sea_level + lt * (PK_PLATFORM_H + macro*PK_PLATFORM_UNDULATE + orogeny)`。
- 在造山带过渡区（`belt_n ∈ [0.42, 0.72]`），`orogeny` 取部分值（0.15~0.35）→ `land_h` 恰好落入 [0.25, 0.70]，且地台起伏极小（0.03×macro）→ `relief < 0.14` → 完美匹配高原条件。
- 地台本身的"平坦性"是设计意图（模拟大陆地盾/地台），但它与高原判定叠加后产生了大量高原。

---

### ★★☆ 原因 6：SPL 侵蚀 + 抬升回补维持分水岭平坦高海拔

**位置**：`world_ext_generate.cpp:817-891`、`ClimateProfile:1184-1187`

**机制**：
- `spl_iters = 14`（开启 SPL，跳过随机液滴）、`spl_uplift_rate = 0.10`。
- SPL 在河谷下切，但抬升回补 `U = uplift_rate × relief0` 维持分水岭高程不被侵平。
- 大地图下河网更发达（更多 cell → 更大汇水盆地 → 更长干流），但**分水岭间的区域保持平坦高海拔** → 这些区域正是高原候选。
- SPL 的 area 有归一化（见上文），但侵蚀主要作用于河谷，对高原判定是间接的"保留"作用而非"制造"。

---

### ★★☆ 原因 7：热力坍塌压平过渡区，使更多区域 relief 低于阈值

**位置**：`world_ext_generate.cpp:903-905, 948-966`、`ClimateProfile:1197-1199`

**机制**：
- `erosion_thermal_iters = 2`、`erosion_thermal_talus = 0.04`、`erosion_thermal_rate = 0.5`。
- 超过 talus 角（0.04）的邻格高差向最低邻居转移物质，**压平陡坡**。
- 大地图精细采样 → 每步高差更小 → 更多区域 `relief < 0.14`（高原阈值）和 `< 0.04`（热力 talus）→ 更多区域满足高原条件。

---

### ★☆☆ 原因 8：山地降级为高原

**位置**：`world_ext_generate.cpp:3027-3058`

**机制**：
- 高海拔但起伏不足的山地格（`mountain_min_relief = 0.115` 不满足）会被降级为 PLATEAU：
  ```cpp
  if (lh >= plateau_min_land_h && lh <= 0.90 && relief <= plateau_max_relief * 1.10) {
      LF[i] = 13;  // 降级为 PLATEAU
  }
  ```
- `plateau_max_relief * 1.10 = 0.154`，比高原主阈值更宽松，进一步扩大高原范围。

---

### ★☆☆ 原因 9（视觉层）：像素级侵蚀过稀疏，高原视觉更连续

**位置**：`world_ext_bake.cpp:933-1110`、`map_baker.gd:336-345`

**机制**（不影响 cell 级 landform，仅影响视觉）：
- `EROSION_DROPS = 6000` **固定**，不随像素面积缩放。
- 桌面端高度图长边固定 1024 像素，典型 ~70 万像素，覆盖率仅 **0.86%**。
- 大地图下河谷视觉切割更弱 → 高原看起来更连续、更密集。
- 注意：SPL 开启时（`spl_iters=14`）cell 级随机液滴 `erosion_droplets=0`，但像素级 bake 侵蚀仍用这 6000 滴。

---

## 3. 共性问题与配置陷阱

### 3.1 sea_level 默认值不一致（易误导调试）

- `map_config.gd:13` 写 `0.64`，`main.gd:116` / `world_setup.gd:22` / `world_data.gd:79` 实际 `0.42`。
- 运行时被 `main.gd:1954` 覆盖，不影响运行，但**若有人只读 map_config.gd 调参，会得到错误的 land_h 区间判断**。
- `sea_level=0.42` 使陆地范围偏大（E∈[0.42,1.0]），高原区间 `land_h∈[0.25,0.90]` 对应 `E∈[0.565,0.942]` 覆盖了陆地大部分。

### 3.2 噪声参数全部硬编码，不可配置

- `height_noise` 频率 0.014、octave 4、lacunarity 2.0、gain 0.5（`world_ext_generate.cpp:345-375`）
- `height_warp` 频率 0.025、`detail_noise` 频率 0.040
- 双峰地台常量 `PK_PLATFORM_H`、`PK_OROGENY_AMP` 等（`world_ext_internal.h:1316-1341`）
- **全部硬编码在 C++**，不从 knobs/ClimateProfile 传入。无法通过配置调整造山带数量/过渡区宽度来缓解高原密集。

### 3.3 海拔→湿度→河流的映射是间接的（非根因）

- 湿度 `M[]` → `base_rain = 0.4 + 1.2*M[i]` → `flow`（`world_ext_generate.cpp:1993-2010`）
- `orographic_boost = 1.2` 放大高地降雨 → flow
- 但 **flow 不影响"是否成河"**（河道选择基于 `up_count`），只影响河流宽度（`RFLOW_OUT`）和 `strong_river` 判定。
- 因此海拔/湿度映射不是河流**数量**密集的根因，但会加剧大地图下河流**视觉宽度**的密集感。

---

## 4. 根因总览（合并排序）

| 排序 | 问题域 | 根因 | 位置 | 适用尺度 |
|------|--------|------|------|---------|
| 1 | 高原 | PLATEAU 无密度上限（PEAK/RIFT 有） | `world_ext_generate.cpp:2979-3025` | 全部 |
| 2 | 河流 | channel_init=16 在预设尺寸（<15000）下本身偏密，缩放对预设失效 | `world_ext_generate.cpp:1541-1553` | N≤15000（全部预设） |
| 3 | 高原 | 高原阈值完全不随地图缩放 | `world_ext_generate.cpp:1533-1535` | 全部，大地图更严重 |
| 4 | 高原 | 噪声归一化采样，造山带特征数固定 | `world_ext_generate.cpp:654-660` | 全部，大地图更严重 |
| 5 | 河流 | N>15000 时指数 0.65 亚线性不足 | `world_ext_generate.cpp:1546` | N>15000 |
| 6 | 高原 | 高原海拔区间过宽（land_h∈[0.25,0.90]） | `world_ext_internal.h:1104-1126` + `world_ext_generate.cpp:2982` | 全部 |
| 7 | 河流 | headwater trace 低阈值补支流 | `world_ext_generate.cpp:2033-2060` | 全部 |
| 8 | 高原 | 双峰地台模型产出平坦中等海拔区 | `world_ext_internal.h:1316-1341` | 全部 |
| 9 | 河流 | up_count 无 N 归一化（与 SPL area 不一致） | `world_ext_generate.cpp:2017-2032` | 全部 |
| 10 | 河流 | hydro_river_min_length=5 + 缩放更弱(0.4875) | `world_ext_generate.cpp:1553` | 全部 |
| 11 | 高原 | SPL 抬升维持分水岭平坦高海拔 | `world_ext_generate.cpp:817-891` | 全部 |
| 12 | 高原 | 热力坍塌压平过渡区 | `world_ext_generate.cpp:948-966` | 全部，大地图更严重 |
| 13 | 高原 | 山地降级为高原 | `world_ext_generate.cpp:3027-3058` | 全部 |
| 14 | 河流 | 无间距/数量约束机制 | `world_ext_generate.cpp` 全文 | 全部 |
| 15 | 河流(视觉) | stamp 最小半径 0.40 + warp 0.30 + SDF 光晕 | `world_ext_bake.cpp:692,598,910` | 全部 |
| 16 | 高原(视觉) | 像素侵蚀 EROSION_DROPS=6000 不随面积缩放 | `world_ext_bake.cpp:933-1110` | 全部，大地图更严重 |

---

## 5. 验证建议（不改代码，利用现有输出字段确认）

`run_native_world_generate_post_base_pass` 返回值中可观测：
- `out["river_channel_init_effective"]`（`world_ext_generate.cpp:3390`）：实际 channel_init
- `out["river_map_scale"]`（`world_ext_generate.cpp:3387`）：N/15000 的 0.65 次幂
- `out["river_count"]`（`world_ext_generate.cpp:3275`）：河流 cell 总数
- `out["qa_metrics"]["river_ratio"]`（`world_ext_generate.cpp:3344`）：river_count / n
- `plateau_touched` / `mountain_to_plateau`（`world_ext_generate.cpp:3016,3052`）：高原 cell 数与山地降级数

**对照实验**：
1. 在不同 N（2400 / 6400 / 30000 / 60000）下对比 `river_ratio` 和 `plateau_touched/land_count`。若两者随 N 上升 → 确认缩放根因。
2. 在 N≤15000 预设下若 `river_ratio` 仍偏高 → 确认原因 1（经验阈值偏密）。
3. 对比 `plateau_touched` 与 `peak_count`（受 land/120 限量）：若高原远多于峰值 → 确认原因 1（高原无上限）。

---

*报告结束。本诊断未修改任何代码，所有结论基于源码静态分析。*
