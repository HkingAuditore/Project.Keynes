# 地形侵蚀 SPL 重构——实现契约（Agent Teams 内部规格，非最终文档）

> 配套：[terrain-erosion-spl-plan.md](terrain-erosion-spl-plan.md)（设计权威）
> 　　　[terrain-erosion-spl-checklist.md](terrain-erosion-spl-checklist.md)（进度权威）
> 本文件只解决「计划没说死的接口细节」，**与计划冲突时以计划为准**，但 §A 裁决除外。
> 所有参与者必须遵守：**只改自己名下的文件**（见 §0）；不改存档/运行期/`Project/perf-validation/**`。

---

## §0 文件所有权（写作用域，互不重叠）

| 所有者 | 文件 |
|---|---|
| `carve-refactor` | `gdext/src/bake_dem_landform.h` |
| `spl-core` | `gdext/src/bake_erosion_spl.h`（**新建**） |
| `bake-integration` | `gdext/src/world_ext_bake.cpp`、`gdext/src/world_ext.h`、`gdext/src/world_ext_bind_generation.cpp`、`Project/project-keynes/data/native_binding_manifest.json` |
| `gdscript-baker` | `Project/project-keynes/scripts/rendering/bakers/terrain_index_baker.gd`、`.../terrain_baker.gd` |
| `erosion-tests` | `Project/project-keynes/tests/world/erosion_spl_bake_test.gd`（**新建**） |
| `docs-sync`（第二轮） | `docs/plans/terrain-erosion-spl-plan.md`、`docs/terrain-generation-current.md`、`docs/architecture/feature-guides.md`、`docs/architecture/feature-status.md`、`docs/architecture/current-state.md` |
| root(lead) | 编译、跑测试、A/B、修订本契约、勾 checklist |

**禁止**：任何人 `git checkout`/`git reset`/批量格式化他人文件；任何人不改 `SConstruct`、不改 `godot-cpp`。

---

## §1 `bake_dem_landform.h`（carve-refactor）

### 1.1 新增类型

```cpp
namespace pk_dem {

// 填洼结果：填洼面 + 出栈序（下游先）。carve 与 SPL 的 spl+carve 分支共用。
struct FillResult {
    std::vector<double> z;      // 填洼后的高度面（size = C*R）
    std::vector<int32_t> order; // Priority-Flood 出栈序（下游 → 上游）
    int32_t pits = 0;           // 需要填高的像素数（z_filled > z_orig + eps）
};

struct CarveStats {
    double fill_ms = -1.0;
    double mfd_ms = -1.0;
    double wall_ms = -1.0;
    double total_ms = -1.0;
};
}
```

### 1.2 抽出的填洼（**当前 carve 第 1 步逐位等价**）

```cpp
// C/R：计算栅格宽高；wrap_cols>2 时前 wrap_cols 列周期；wet 非 0 = 出口。
// 与 carve_drainage_valleys 现有内联实现逐位一致：同一个 std::priority_queue<pair<double,int64_t>>
// 键、同一个 FILL_EPS=1e-7、同一套出口判定与邻接遍历顺序。
inline void fill_depressions(int C, int R, int wrap_cols,
        const double *z_in, const uint8_t *wet, FillResult &out);
```

- `out.z` 初始化为 `z_in` 的副本后原地填洼；`out.order` 与现有 `order` 同序。
- 具体做法：把 `carve_drainage_valleys` 第 1 步的代码**整段搬进** `fill_depressions`，
  然后在 carve 里改成 `FillResult fr; fill_depressions(C, R, P.wrap_cols, z.data(), wet.data(), fr);`
  之后 `const std::vector<double>& zf = fr.z;` 并把后续所有对 `z` 的引用改为 `zf`。
  `pits` 用 `zf[i] > z[i] + FILL_EPS*0.5` 计数（新增诊断，不影响行为）。
- **逐位等价是硬要求**：float→double 的转换、`std::greater<Node>`、`closed` 标记的置位时机、
  `z[n] = z[c] + FILL_EPS` 的写法，全部原样保留。禁止顺手换成 float key 或 FIFO。

### 1.3 carve 签名扩展（向后兼容：旧调用点行为不变）

```cpp
inline void carve_drainage_valleys(float *H, const float *relief, const uint8_t *water,
        const DrainageParams &P, CarveStats *stats = nullptr, const FillResult *reuse = nullptr);
```

- `stats != nullptr`：填 `fill_ms / mfd_ms / wall_ms / total_ms`（`std::chrono::steady_clock`）。
- `reuse != nullptr`：跳过内部填洼，改用 `reuse->z` / `reuse->order`（要求同一栅格几何：`C/R/wrap` 一致）。
  此时 `stats->fill_ms = 0.0`。
- `reuse == nullptr && stats == nullptr` 时**输出必须与改动前逐位相同**。

### 1.4 验收（自测）

用 `cl.exe` 或 `scons` 编过即可；由 root 用 A8 hash 门禁 + 回归测试最终确认。

---

## §2 `bake_erosion_spl.h`（spl-core，新建）

**约束**：header-only、仅 `inline`、只依赖 `<algorithm> <cmath> <cstdint> <vector> <queue> <utility> <limits>`，
**禁止** include 任何 Godot 头或 `bake_dem_landform.h`。所有函数为纯 C++，可单独编译。

### 2.1 类型（与计划 §4.9 一致，仅补细节）

```cpp
namespace pk_erosion {

struct Grid {
    int w = 0, h = 0;
    int wrap_cols = 0;          // >2 且 <= w：前 wrap_cols 列经线周期，其后列是 x-wrap_cols 的别名
    double sea_level = 0.0;
    double sea_eps = 5e-4;
    double hex_px = 1.0;        // 当前栅格上「一个 hex 跨度」的像素数（下采样后必须同步缩小）
    float *H = nullptr;         // 入口 = h_pre；核修改它
    const float *H_pre = nullptr; // 入口高度快照（delta / 沉积上限）
    const float *relief = nullptr;
    const uint8_t *wet = nullptr; // 1 = 水体或河心像素（出口，不参与下切/限坡）
};

struct Flow {
    std::vector<int32_t> order;      // 拓扑序：下游 → 上游（出口先出栈）
    std::vector<int32_t> rcv;        // 最陡下降受体下标；-1 = 无严格更低邻点 / 水体 / 出口
    std::vector<uint8_t> rcv_k;      // 受体方向索引 0..7（rcv<0 时无意义）
    std::vector<float> area_hex;     // 汇水面积，单位 hex^2（单像素初值 1/hex_px^2）
    std::vector<float> z_fill;       // 填洼面（供 spl+carve 复用；不要求时也填，成本可忽略）
};

struct SplParams { int iters = 6; double k_total = 0.50; double m = 0.45; double min_area_hex = 0.03; };  // k_total 已按 P2 标定 0.03 → 0.50（见 checklist §A4）
struct DepParams {
    bool enabled = false;
    double kc = 0.02, rate = 0.5, min_area_hex = 0.5;
    bool floor_widen = false;
    double floor_width_hex = 0.04, floor_slope = 0.002, floor_min_area_hex = 2.0;
};
struct LimParams { double per_relief = 5.0, relief_floor = 0.04, cap_per_relief = 1.4, crest_round = 0.0; };

struct Stats {
    double p99_drop = 0.0, max_drop = 0.0;
    double eroded_vol = 0.0, deposited_vol = 0.0;
    int64_t sea_clamped = 0, nan = 0;
    int32_t pits_in = -1, pits_out = -1;   // -1 = 未计算
    int iters_effective = 0;
};

// 方向表（与 carve 完全一致，保证 spl+carve 沿同一套邻接）
inline const int *dir_dx();   // 8 个方向
inline const int *dir_dy();
inline const double *dir_len(); // 1 或 sqrt(2)
}
```

方向表顺序**必须**与 `bake_dem_landform.h` 相同：
`DX={1,-1,0,0,1,1,-1,-1}`、`DY={0,0,1,-1,1,-1,1,-1}`、`DL={1,1,1,1,√2,√2,√2,√2}`。
倒角扫描的前向集 `{1,3,5,7}`、后向集 `{0,2,4,6}` 也保持一致。

### 2.2 函数语义

#### `build_flow(const Grid&, Flow&)`
1. **填洼**：Priority-Flood + ε，`float` key + FIFO 洼地队列（Barnes 2014 优化）。出口 = `wet` ∪ 地图南北边缘（`wrap_cols>0` 时东西向不设边缘出口，靠环绕）。
   - `FILL_EPS = 1e-7f`；`order` 对填洼面单调不减。
   - 记录 `z_fill`（float）；`pits_in` 不计在这里（见 `count_pits`）。
2. **受体**：对每个非 wet、`rcv` 未定的像素，取 `argmax_k (z[i]-z[nb_k])/DL[k]`，只接受 `z[nb_k] < z[i]` 严格更低的邻点；平局取 `k` 小者。无合格邻点 → `rcv=-1`。
3. **汇水面积**：`area_hex` 初值 `1.0/(hex_px*hex_px)`；沿 `order` **逆序**（上游→下游）`area_hex[rcv[i]] += area_hex[i]`；`wet` 像素跳过（不累加、不作为目标）。
4. 不变量：`rcv[i] >= 0` 时 `order` 中 `rcv[i]` 必须排在 `i` 之前（由「严格更低」保证，加一次 debug 断言）。

#### `precompute_coeff(const Grid&, const Flow&, const SplParams&, std::vector<float>& C)`
```
K_iter = k_total / max(1, iters)
for i:  C[i] = (wet || rcv<0 || area_hex < min_area_hex) ? 0
                : K_iter * pow(area_hex[i], m) / (dir_len(rcv_k[i]) / hex_px)
```
`pow` 每像素只算一次。`iters <= 0` → `iters` 视为 1。

#### `spl_incise(Grid&, const Flow&, const std::vector<float>& C, const SplParams&, Stats&)`
按 `order` **正序**（下游先）逐轮扫描 `iters` 轮：
```
if (wet || C[i] <= 0 || rcv<0) continue
h_new = (H[i] + C[i]*H[rcv]) / (1 + C[i])
floor_h = (H_pre[i] > sea_level) ? sea_level + sea_eps : -inf
if (h_new < floor_h) { h_new = floor_h; stats.sea_clamped++ }
H[i] = min(H[i], h_new)          // 只降，绝不上抬
```
- 每轮开始前 `H` 是上一轮结果；`H_pre` 始终是入口快照（不可写）。
- 结束后统计 `drop[i] = H_pre[i]-H[i]`（仅陆地非 wet），`max_drop`、`p99_drop`（直方图法，4096 桶，确定性）、
  `eroded_vol = Σ drop`（height·px）、`stats.nan`（`!isfinite` 计数）、`stats.iters_effective = iters`。

#### `deposit(Grid&, const Flow&, const DepParams&, const SplParams&, Stats&)`
仅在 `dp.enabled` 时调用。按 `order` **逆序**（上游先）：
```
Qs[i] 初值 0；min_child_h[i] 初值 +inf
for i in reversed(order):
    if (wet[i]) { continue; }                 // 出口：泥沙丢弃，不做三角洲
    Qs[i] += drop[i]
    r = rcv[i]; if (r < 0) continue
    S  = max(H[i]-H[r], 0) / (dir_len(rcv_k[i]) / hex_px)
    Qc = kc * pow(area_hex[i], m) * S
    if (Qs[i] > Qc && area_hex[i] >= dp.min_area_hex):
        room = min(H_pre[i]-H[i], min_child_h[i] - 1e-6 - H[i])
        D = clamp((Qs[i]-Qc)*dp.rate, 0.0, max(0.0, room))
        H[i] += D; Qs[i] -= D; deposited_vol += D
    // 子像素已 finalize，用它更新父的 min_child_h
    min_child_h[r] = min(min_child_h[r], H[i])
    Qs[r] += Qs[i]
```
- `min_child_h[r]` 用 `float`/`double` 的 `+inf` 初值；父像素处理时若仍为 `+inf`（无子），该项视为 `+inf`。
- **只升到 `h_pre`、只升到 `min_child_h - eps`**，因此不变量 1/4 成立。
- 写 `stats.deposited_vol`；重复统计 `max_drop` 等不必更新。

#### `slope_limit(Grid&, const LimParams&, Stats&)`
`wet` 像素**既是**「不改的目标」**也是**「不作为约束源」。两遍前向/后向倒角扫描（每遍各含正向与反向两次扫描，
共 2 passes，与 carve 第 4 步同构）：
```
s[i]   = per_relief * max(relief[i], relief_floor)             // height / hex
cap[i] = cap_per_relief * relief[i]                            // 单像素最大削减
relax(i, k): cand = L[m] + s[i]*(dir_len(k)/hex_px); 若 m<0 或 wet[m] 跳过
L[i] = max( min(L[i], min_k cand), H_pre[i]-?? )
```
更精确（照抄计划 §4.5）：
```
L 初值 = H（副本）
每遍：L[i] = max( min( L[i], min_m(L[m] + s[i]*dir_len(k)/hex_px) ), H[i] - cap[i] )
最后：land(i) 且 L[i] < sea_level+sea_eps → L[i] = sea_level+sea_eps, stats.sea_clamped++
写回 H[i] = L[i]（只降不升；因 H[i] >= sea+eps 且 floor <= H[i]，max 不会上抬）
```
`dem_crest_round > 0` 时，在限坡**之前**插一步「只取负值」的 Laplacian（4 邻域 + wrap）：
`H[i] += min(0.0, crest_round * laplacian(H[i]) * hex_px?)` —— 用**纯 Laplacian**（`Σ(h_nb)-4h`），
系数 `crest_round`，只取负值，天然只降。用双缓冲避免顺序依赖（确定性）。

#### 辅助

```cpp
// 填洼复核：需要填高的像素数（z_filled > z_orig + 0.5*FILL_EPS）。用与 build_flow 同一套 float+FIFO。
inline int32_t count_pits(const Grid&);
// 盒式下采样（wrap 感知，越界克隆边缘）。f>=1，f==1 时为直接拷贝。
inline void downsample_box_f32(const float *src, int w, int h, int f, float *dst);
inline void downsample_box_u8(const uint8_t *src, int w, int h, int f, uint8_t *dst);
// delta 双线性放大：dst_hi 尺寸 w_hi x h_hi，wrap 感知
inline void upsample_box_f32(const float *src, int w, int h, int f, float *dst, int w_hi, int h_hi);
```
`upsample` 语义：`dst(x,y) = bilinear(src, u, v)`，其中 `u = (x+0.5)/f - 0.5`、`v = (y+0.5)/f - 0.5`，
`u` 按 `w` 取模（wrap），`v` 夹紧到 `[0,h-1]`。**不得负值、不得 NaN**（`src` 全非负时输出全非负）。

### 2.3 数值纪律
- `H`/`area_hex` 用 `float` 存储、`double` 中间计算；`pow` 用 `double`。
- 所有循环串行（无 `parallel_for`），保证确定性（计划 §3.2-6）。
- 无全局状态、无 RNG、无时间依赖（计时只在调用方）。

### 2.4 自测（必须做，交付前）
写一个临时 `gdext/src/_spl_selftest_main.cpp`（**不提交**，验证后删除），用 `cl` 直接编译
`bake_erosion_spl.h` + main，跑：
1. 单锥坡 256×256：`drop` 与 `log(area_hex)` Pearson > 0.8；
2. `H <= H_pre` 全像素；无 NaN；陆地 ≥ sea+eps；
3. 确定性：两次 build_flow+incise 结果逐位相同；
4. `deposit` 后 `deposited <= eroded`、`h <= h_pre`、`count_pits` 不增加；
5. 512 vs 1024 栅格：`delta` 下采样相关 > 0.85。
把结果贴进交付报告（数字，不是「看起来对」）。

---

## §3 融合 pass 接线（bake-integration）

### 3.1 模式语义（**已裁决，见 checklist §A1**）

```cpp
const String mode = String(knobs.get("dem_erosion_mode", String("carve")));  // C++ 缺省恒 carve
if (mode == "carve") {
    carve_drainage_valleys(..., &carve_stats);          // 现状
    // ↓ 现状的 droplet 步骤照旧执行（守住 hash 门禁）
} else if (mode == "spl" || mode == "spl+carve") {
    // SPL 管线；不跑 carve（除 spl+carve 的浅刻谷）、不跑 droplet
} else if (mode == "droplet") {
    // 仅 run_bake_erosion_pass
}
```

**关键**：`carve` 分支必须让 `height_buffer` 与改动前**逐位相同**（含 `run_bake_erosion_pass`
的 droplet 结果）。实现上把现有「② erosion」段落改成：
```cpp
const bool run_droplet = (mode == "carve" || mode == "droplet");
if (run_droplet) { knobs["height_buffer"] = height_buf; ero = run_bake_erosion_pass(knobs); ... }
```
即：`carve` 里 droplet 必须执行；`spl*` 里跳过。别把 droplet 的 `height_final` 赋值顺序改坏。

### 3.2 文件内共享实现 `pk_run_erosion_spl_pipeline`

在 `world_ext_bake.cpp` 的匿名命名空间或 `static` 函数里实现一次，`run_bake_erosion_spl_pass`
与融合 pass 都调用它（**不复制代码**）：

```cpp
struct SplPipelineReport {
    bool ok = false;
    const char *reason = "";
    int factor = 1, w_lo = 0, h_lo = 0;
    double flow_ms = -1, spl_ms = -1, dep_ms = -1, limit_ms = -1, carve_ms = -1, upsample_ms = -1;
    pk_erosion::Stats stats;
};

// H：入口高度（就地改写成最终高度）；relief/wet：同尺寸；wrap_cols：0 或周期列数；
// hex_px_hi：基线栅格上每 hex 像素数；max_dim<=0 → 不下采样。
static SplPipelineReport pk_run_erosion_spl_pipeline(
    float *H, const float *relief, const uint8_t *wet, int w, int h, int wrap_cols,
    double hex_px_hi, double sea_level, int max_dim,
    const pk_erosion::SplParams &sp, const pk_erosion::DepParams &dp,
    const pk_erosion::LimParams &lp);
```
内部流程（计划 §4.1）：
1. `factor = max_dim > 0 && max(w,h) > max_dim ? (max(w,h)+max_dim-1)/max_dim : 1`
2. `ffactor == 1`：`Grid.H` 直接指向 `H`，`H_pre` 为快照；否则盒式下采样 `H/relief/wet` 到 `(w/f, h/f)`，
   `hex_px = hex_px_hi / factor`。
3. `build_flow` → `precompute_coeff` → `spl_incise` → [`dp.enabled`] `deposit` → [`dp.floor_widen`] `floor_widen`
   → `slope_limit`（顺序不可换）。
4. `factor > 1`：`delta_lo = max(0, H_pre_lo - H_lo)`；`upsample_box_f32` 到 hi；逐像素
   `h = H_pre_hi[i] - delta[i]`；`wet` 像素**原样保留**；`H_pre_hi > sea_level` 的像素
   `clamp(h, sea_level + 5e-4, H)`；其余 `clamp(h, -inf, H)`（只降）。
5. 填 `stats.pits_in`（`build_flow` 时顺带）；`stats.pits_out` 仅在 `dp.enabled || audit` 时用
   `count_pits` 计算，否则 `-1`。

### 3.3 `run_bake_erosion_spl_pass(Dictionary knobs)`（buffer-encoder 范式）

入参 knobs 键：
`width`、`height`、`height_buffer`(PackedFloat32Array, in)、`relief_buffer`(PackedFloat32Array)、
`wet_buffer`(PackedByteArray，1=水/河心)、`sea_level`、`hex_px`（缺省时用 `size_x`+`hex_size` 推）、
`wrap_cols`、以及全部 `dem_*` knob。`dem_erosion_mode` 恒按 `spl`（或 `spl+carve`）处理。

返回：`fallback=false`、`path="gdext"`、`height_out`(PackedFloat32Array)、`width/height`、
`erosion_mode`、`erosion_grid_w/h/factor`、全部分项 ms、全部 stats 键、`elapsed_ms`、`reason`。
失败（尺寸不符/缓冲缺失）→ `fallback=true` + `reason`，**不** `push_error`（供测试与融合 pass 判据）。
P0 阶段先只写「可编译 + 参数解析 + 调 pipeline」；pipeline 由 spl-core 提供。

### 3.4 report keys（计划 §4.11，**只增不改**）

`erosion_mode`、`erosion_grid_w`、`erosion_grid_h`、`erosion_grid_factor`、
`flow_ms`、`spl_ms`、`dep_ms`、`limit_ms`、`carve_ms`、`upsample_ms`、`fill_ms`、`mfd_ms`、`wall_ms`、
`spl_iters_effective`、`spl_p99_drop`、`spl_max_drop`、`eroded_vol`、`deposited_vol`、
`spl_sea_clamped`、`spl_nan`、`pits_in`、`pits_out`。
未执行的项填 `-1`。`erosion_ms`/`erosion_ok`/`valley_ms` 语义保留（`erosion_ms` = 整个侵蚀阶段）。

### 3.5 `world_ext.h` / bind / manifest
- `world_ext.h`：在 `run_bake_erosion_pass` 附近加声明 + 契约注释（中文，说明模式、单位、缺省 carve）。
- `world_ext_bind_generation.cpp`：`ClassDB::bind_method(D_METHOD("run_bake_erosion_spl_pass","knobs"), &DCWorldExt::run_bake_erosion_spl_pass);`
- manifest：`python tools/ci/world_ext_bindings.py --write-manifest`（在仓库根跑），只应出现该方法的 diff。

---

## §4 GDScript（gdscript-baker）

### 4.1 `terrain_index_baker.gd::DEM_DEFAULTS` 追加 19 项（计划 §4.10 原值）

```
dem_erosion_mode "carve"   dem_erosion_max_dim 1024  dem_spl_iters 6  dem_spl_k 0.03
dem_spl_m 0.45  dem_spl_min_area_hex 0.03
dem_slope_limit_per_relief 5.0  dem_slope_limit_relief_floor 0.04  dem_slope_limit_cap_per_relief 1.4
dem_crest_round 0.0
dem_dep_enabled false  dem_dep_kc 0.02  dem_dep_rate 0.5  dem_dep_min_area_hex 0.5
dem_floor_widen false  dem_floor_width_hex 0.04  dem_floor_slope 0.002  dem_floor_min_area_hex 2.0
dem_spl_carve_scale 0.40
```
外加测试/诊断用（缺省关，不写实现行为）：`dem_erosion_pit_audit`（false）→ 让合并 pipeline 算 `pits_out`。
- 加中文注释说明「参数以 hex 为单位」「迭代只按分辨率分档」「C++ 缺省永远 carve」。
- **不要改** `dem_landform_knobs()` 逻辑（它已遍历 DEM_DEFAULTS）。
- **不要动** 已有的 `dem_valley_*` 语义。

### 4.2 `terrain_baker.gd:615` 日志行

现有字段**全部保留**（可能有外部 grep），新增括号内字段：
```gdscript
print("    [fused] terrain=%.1fms valley=%.1fms erosion=%.1fms(ok=%s mode=%s grid=%dx%d flow=%.1fms spl=%.1fms x%d dep=%.1fms limit=%.1fms p99=%.6f) river=%.1fms(ok=%s) latitude=%.1fms coast_sdf=%.1fms(ok=%s)" % [...])
```
取值为 `-1` 时照常打印（用 `%d` 对 `erosion_grid_factor` 时先 `int()`）。

---

## §5 测试（erosion-tests，`tests/world/erosion_spl_bake_test.gd`）

- `extends SceneTree`，`_init()` 里 `ClassDB.instantiate("DCWorldExt")`，`quit(0/1)`，
  `_expect(cond,label)` 计数，末尾 `print("[erosion-spl] checks=%d failures=%d" % [_checks,_failures])`。
- 参考 `tests/world/mountain_relief_bake_test.gd` 的风格（无第三方断言库）。
- **A1–A11 每条一个 `_expect`**，标签以 `A1:`…`A11:` 开头，便于 root 逐项核对。
- 合成地形构造器：可解析锥体 + 噪声，`wet` 由高度阈值生成；`hex_px`、`sea_level` 显式给定。
- 若某条断言在当前实现下**必然暂时失败**（如 A8 hash 需要基线 DLL 才能比），
  用「跳过并打印 `A8: SKIP reason=...`」而不是假装通过，且在文件头注释写明原因。
- A8（carve 回退 hash）：用 `run_bake_geometry_fields_pass` 跑两次同 knobs，并用固定 seed 的
  MapBaker 路径不可行时，退化为「两次调用逐位相同 + `erosion_mode=="carve"` + `valley_ms>=0`
  且 `spl_p99_drop<0`」的结构性断言，并打印实际 sha256（用 `_hash32` FNV）供 root 与基线比对。
- 交付时**不要**自己跑（root 统一编译后跑）；但要把 `gdscript` 语法检查到 0 lint 错误。

---

## §6 编译与验证命令（root 执行）

```powershell
# 编译（约 3–10 min，只重编改动 TU）
cmd /c "`"%ProgramFiles%\Microsoft Visual Studio\2022\Professional\VC\Auxiliary\Build\vcvars64.bat`" >nul 2>&1 && scons platform=windows target=template_debug"   # workdir: gdext
# 测试
cd Project/project-keynes
& '<GODOT_BIN>' --headless -s res://tests/world/erosion_spl_bake_test.gd
```
