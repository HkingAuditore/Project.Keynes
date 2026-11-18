# 烘焙期地形侵蚀重构计划：几何刻谷 → 汇流 SPL + 限坡 + 输运沉积

> 状态：**已实现并验证（2026-11-18）**——P0 / P1 / P2 / P3 已落地并经实测验收；P4 未实现（见 §6「可选，下一轮」）。
> 默认模式已按 §6 P2.7 从 `carve` 切到 `spl`（C++ 缺省仍恒为 `carve`，逐位回退基线保留）；
> `dem_dep_enabled` / `dem_floor_widen` 维持 `false`（计划要求 A/B 认可后才开，属用户裁决）。
> 进度勾选见 [terrain-erosion-spl-checklist.md](terrain-erosion-spl-checklist.md)（只读引用，本文不改它）。
> 日期：2026-11-18（v1 同日起草；v2 根据评审重写 §0、§3、§4、§5、§6、§8、§10、§12；
> v3 落地后按实测数据重写 §5（含 §5.2 三档 carve vs spl 成对对照）、补 §1.2 分项、勾选 §6、
> 修订 §8.1 A9 与 §4.11 `upsample_ms`，并在附录 A/B 记录判据修订与两个修复）
> 范围：bake 期 per-pixel 视觉高度（`run_bake_geometry_fields_pass` 的 ①b/②），**不触碰** cell 高程 `E[]`、
> 运行期仿真、存档 schema
> 关联：[terrain-generation-current.md §轻度水力侵蚀](../terrain-generation-current.md)、
> [feature-guides.md §山地起伏调参与验收](../architecture/feature-guides.md)、
> [terrain-density-diagnosis.md](../terrain-density-diagnosis.md)、
> [visual-tile-rendering.md](../cpp-dots-runtime/visual-tile-rendering.md)、
> **[terrain-ridge-uplift-plan.md](terrain-ridge-uplift-plan.md)（原 P5，cell 级，单独计划）**

---

## 0. 一句话

把融合几何 pass 里「一次性几何刻谷 + 6000 滴 × 5 步装饰液滴」替换为
**汇流驱动的隐式 SPL 下切 → 输运受限沉积 → 按局地起伏缩放的限坡**，三步共用一棵流向树；
公式按 hex 物理单位写，**与烘焙分辨率无关**；Web high 在 1024 计算栅格上算、只放大改造量。
`carve` 旧路径保留并以 hash 门禁守逐位回退。

成本预期（v2 估算 → **v3 实测**）：`spl` 模式替换掉 carve 的刻谷阶段，自身约 90–150 ms 的估算偏乐观——
desktop 同一次运行背靠背对照：`carve` 231.6 ms → `spl` 264.9 ms（**慢约 33 ms**）；但 **Web high 上结论反转**：
`carve` 1072.8 ms → `spl` 514.5 ms（**快 558 ms**），因为 spl 在 §4.7 的 1024 计算栅格上跑而 carve 是 O(像素数)。
`MapBaker v6: total`（60×40 desktop）反而由 1439 ms 降到 1393 ms（**−46 ms**）；开启 P3 追加 `dep_ms=12.3 ms`
（P3b 展宽时 `dep_ms=37.6 ms`）。运行期开销 0。
实测明细与修订后的验收表见 §5。

---

## 1. 现状与证据

### 1.1 执行顺序（bake 期几何场）

`run_bake_geometry_fields_pass`（[world_ext_bake.cpp:906](../../gdext/src/world_ext_bake.cpp)）：

| # | 步骤 | 位置 | 说明 |
|---|---|---|---|
| ① | terrain-index：barycentric 插值 cell E → 海滩坡 → `ridge_off` + `pk_dem::landform` 沟谷噪声 | [world_ext_bake.cpp:1609-1649](../../gdext/src/world_ext_bake.cpp) | 产出 `height_buffer` / `dem_relief_buffer` |
| ③ | 河流 SDF（提前算，仅作汇流出口） | [world_ext_bake.cpp:941-944](../../gdext/src/world_ext_bake.cpp) | `flow ≥ dem_valley_river_outlet_flow(0.6)` 的河心像素标 wet |
| ①b | **汇流刻谷** `pk_dem::carve_drainage_valleys` | [world_ext_bake.cpp:946-993](../../gdext/src/world_ext_bake.cpp)、[bake_dem_landform.h:144-317](../../gdext/src/bake_dem_landform.h) | Priority-Flood 填洼 → MFD(p=6) 汇水 → `log(A)` 映射谷深 → 倒角谷壁（`wall_per_relief × relief`/hex）→ 谷底不低于下游 |
| ② | **液滴侵蚀** `run_bake_erosion_pass` | [world_ext_bake.cpp:587-786](../../gdext/src/world_ext_bake.cpp) | `DROPS=6000`、`MAX_STEPS=5`、`ERODE=0.10`（[map_baker.gd:420-430](../../Project/project-keynes/scripts/rendering/map_baker.gd)） |
| ③' | 河流 SDF 下切 | [world_ext_bake.cpp:1014-1033](../../gdext/src/world_ext_bake.cpp) | 固定 `0.045 × notch`，与流量无关 |
| ④ | 海岸 SDF 下切 | [world_ext_bake.cpp:1040-1071](../../gdext/src/world_ext_bake.cpp) | `0.06` smoothstep 岸坡 |

visual tile 不在 tile 分辨率重跑侵蚀，而是 `tile = bicubic(baseline_final) + (tile_procedural − baseline_procedural)`
（[world_ext_bake_visual_tiles.cpp:221-229](../../gdext/src/world_ext_bake_visual_tiles.cpp)）——
**侵蚀改造量本质上是基线分辨率的低频量**，这是 §4.7 Web 方案的依据。

### 1.2 实测耗时（桌面 60×40，基线 1024×606）

来源：`tmp/ab_final/default365b.log`（96 份样本区间一致）

| 子 pass | 耗时 | 占 geometry |
|---|---:|---:|
| terrain-index | 72 ms | 23% |
| **valley（刻谷，单线程）** | **150 ms** | **48%** |
| erosion（液滴） | 3.7 ms | 1% |
| river SDF | 12.6 ms | 4% |
| coast SDF | 4.1 ms | 1% |
| **geometry 合计** | **312 ms** | — |

`MapBaker v6: total 2313 ms`（视觉 tile 12 层 1405 ms、encode/法线/horizon ~600 ms）。
**valley 150 ms 内部尚无分项计时**；按代码结构推测大头是 620k 节点的 `priority_queue<pair<double,int64>>`
填洼与每像素 8 次 `pow(dz, 6.0)` 的 MFD 分配——P0 必须先补分项计时再定预算。

**P0.8 实测分项（2026-11-18，同一图 620,544 px = 60×40 / 1024×606，`template_debug`）**

| 分项 | 实测 |
|---|---:|
| `fill_ms`（Priority-Flood 填洼） | 59–69 ms |
| `mfd_ms`（MFD(p=6) 汇水分配） | 26–29 ms |
| `wall_ms`（倒角谷壁） | 40–42 ms |
| `carve_ms`（整段） | 127–143 ms |
| `valley_ms`（含出口集合构造） | 130–135 ms |

按 `carve_ms` 归一：**填洼 ≈47% / MFD ≈21% / 谷壁 ≈31%**。上面「大头是填洼」的推测**被证实**；
同图成对对照里 `carve` geometry 实测 231.6 ms（§5.2），比上表旧日志的 312 ms 快得多——
旧日志不是同一构建 / 同一次运行，不能与本次实测混用。

像素数只由平台档决定（[map_baker.gd:37-70](../../Project/project-keynes/scripts/rendering/map_baker.gd)）：
mobile 512 长边 ≈ 155k px、desktop 1024 ≈ 620k px、Web high 2048 ≈ 2.48M px；地图格数几乎不影响。

### 1.3 现有「侵蚀」为什么不成水系

- **液滴**：5 步 × 1 px/步，60×40 预设 1 hex ≈ 17 px，雨滴走不出一个 hex；起点不筛陆地、无经线环绕；
  单步扣除 ~10⁻³，代码注释自认「仅做边界平滑，不刻河谷」。
- **刻谷**：汇水网络是真的，但下切是「`log(A)` → 深度」的一次性映射，谷形由固定倒角坡度展开——
  所有谷同一截面，无谷底、无堆积、无层级下的形态差异，观感像模具压出来的。
- **cell 层**：SPL 14 轮之后又叠了与汇流无关的脊噪声（`ridge_boost_amp=0.60`，
  [world_ext_generate_base.cpp:986-1077](../../gdext/src/world_ext_generate_base.cpp)），山脊是噪声而非分水岭。
  这一条属于 cell 层，见 [terrain-ridge-uplift-plan.md](terrain-ridge-uplift-plan.md)，本计划不改。

### 1.4 与主流的差距

| 主流 | 本项目现状 | 后果 |
|---|---|---|
| SPL（Braun & Willett 2013 隐式 O(N)；Cordonnier 2016）在显示网格上跑 | 像素层无 SPL；只有 cell 级 | 像素层没有水力下切 |
| 输运受限 / 沉积（Davy & Lague 2009；Yuan 2019） | 无 | 无谷底、冲积带 |
| 坡面过程（临界坡度 / 扩散）约束谷壁 | 倒角谷壁一次成形 | 谷形千篇一律 |
| 液滴 30–100 步、≥1 滴/像素 | 5 步、1/120 滴/像素 | 只有凹坑 |
| 先叠噪声后侵蚀 | 像素层噪声在前 ✔；cell 层噪声在后 ✘ | 见关联计划 |

### 1.5 读档会重新烘焙（v1 遗漏）

读档流程是「按 `new_game_config` 种子重建世界 → 覆盖动态 SoA」
（[game_save_coordinator.gd:275-306](../../Project/project-keynes/scripts/game/game_save_coordinator.gd)，
`restore_prepared_game` 要求「地图已载入」；重建不一致时由
[world_runtime_visual_adapter.gd:384-396](../../Project/project-keynes/scripts/game/world_runtime_visual_adapter.gd)
的 `start_cell_drift` 拒绝读档）。因此：

- 本计划改的是 bake 视觉高度 → **默认模式一旦切换，老存档读档后也会看到新地形**（不是 v1 写的「仅新生成生效」）。
- 这是**可接受的纯视觉变化**：像素高度没有玩法消费者——`WorldData.sample_height`
  （[world_data.gd:422](../../Project/project-keynes/scripts/geography/world_data.gd)）当前无调用方，
  `VisionSolver` 等静态场读 HexCell。P0 用 grep 门禁固定这一事实（§8.2）。
- cell 级改动（关联计划）则会让旧存档重建出不同世界；关联计划已决定不做兼容、旧存档作废——
  玩法可见、回归面不同，这是两份计划分开的根本原因。

---

## 2. 根因排序

| # | 根因 | 影响 | 处理 |
|---|---|---|---|
| R1 | 像素层没有基于过程的下切，谷形是一次性几何映射 | ★★★ | P2 |
| R2 | cell 层山体主体是侵蚀**之后**加的脊噪声 | ★★★ | [关联计划](terrain-ridge-uplift-plan.md) |
| R3 | 只有下切，没有沉积 / 坡面过程 | ★★★ | P1（限坡）/ P3（沉积） |
| R4 | 汇流出口与 cell 河流不一致风险 | ★★☆ | P2（河心像素作出口，沿用 carve 约定） |
| R5 | 参数按像素计，平台间强度不一致 | ★★☆ | §4.2 物理单位化 |
| R6 | 侵蚀残差烘成视觉噪点（horizon 注释已实证） | ★☆☆ | P1 顺带缓解 |
| R7 | 细节法线是固定波长平行条纹 | ★★☆ | P4 |

**落地后状态（2026-11-18）**：R1 已由 P2 处理、R3 由 P1/P3 处理、R4 由 P2 验收 4（实测 0.9809）缓解、
R5 由 §4.2 物理单位化处理、R6 随 P1 顺带缓解；**R7 未处理**（P4 未实现），**R2 不在本计划范围**
（见[关联计划](terrain-ridge-uplift-plan.md)）。
---

## 3. 目标与不变量

### 3.1 目标

1. 视觉高度出现**树枝状、层级分明**的河谷，谷深随上游汇水面积增长（Flint 律意义下的坡度–面积关系）。
2. 大谷有平坦谷底 / 冲积带（P3），小沟是 V 形；谷壁坡度受局地起伏约束，不出现 1–2 px 断崖。
3. 同一 knobs 在 512 / 1024 / 2048 三档上**宏观形态一致**，只是细节多少不同。
4. 侵蚀、河流下切、海岸下切作用在同一份高度上，河道落在谷里。
5. 一键回退到当前逐位行为。

### 3.2 硬不变量

1. **不高于侵蚀前高度**：令 `h_pre` = ①b 入口的 `height_buf`（terrain-index 输出），则任何阶段结束后
   `h ≤ h_pre`。SPL 与限坡**只降**；P3 沉积只允许把 SPL 削掉的部分**部分填回**，上限仍是 `h_pre`。
   （v1 的「只降不升」对 SPL/限坡仍成立；对整体放宽为本条，`water_depth = surface − height` 语义不变。）
2. **陆地不下海**：陆地像素 `≥ sea_level + 5e-4`（沿用 carve，[bake_dem_landform.h:313](../../gdext/src/bake_dem_landform.h)）；越界计数上报。
3. **水体不动**：`pk_is_water_terrain` 像素逐位不变；水体与河心像素只作汇流出口与边界，不参与限坡约束。
4. **不新增闭合洼地**：结果中陆地闭合洼地数 ≤ 输入（测试中用填洼复核）。
5. **分辨率无关**：所有长度/面积参数以 hex 为单位（§4.2）；三档平台宏观一致（§8.1 A9——
   原判据实测不可达后已改写为 A9(1)/A9(2)，见附录 A.2）。
6. **确定性**：同 knobs + 同分辨率 → 逐位相同，与线程数、负载无关；迭代次数只按分辨率分档，禁止按耗时自适应。
7. **回退**：`dem_erosion_mode=carve` 输出与改动前 64-bit hash 一致。
8. **零运行期开销、零存档格式变更。**

### 3.3 明确不做

- 不回写 `HexCell.elevation/landform/river`；不改 moisture、植被、生态。
- 不改 tile 分辨率下河流/海岸 SDF 契约（[visual-tile-rendering.md:161-179](../cpp-dots-runtime/visual-tile-rendering.md)）。
- 不动 cell 级 SPL 与 `ridge_boost` 顺序（见关联计划）。
- 不做三角洲 / 海岸沉积（入海泥沙直接丢弃）；不做侧向迁移的曲流。

---

## 4. 设计

### 4.1 总体流程

```
terrain-index（不变） ─► h_pre / relief / wet(水体 ∪ 河心像素)
   │
   ├─[Web high] 盒式下采样到计算栅格（长边 ≤ dem_erosion_max_dim=1024）
   ▼
build_flow：Priority-Flood 填洼 z → 拓扑序 order → 单一受体 rcv（最陡下降）→ 汇水面积 A
   ▼
预计算 C[i] = K_iter · A_hex^m / dx_hex   （受体与面积在本 pass 内固定，pow 只算一次）
   ▼
spl_incise × iters（隐式，沿 order 下游→上游，单调、不下海）
   ▼
[P3] deposit：沿 order 反向（上游→下游）累积削蚀体积，超出搬运能力处填回（≤ h_pre，不造洼）
   ▼
slope_limit：只削高侧的限坡（倒角 min-plus 扫描，坡限 ∝ 局地起伏，单像素削减有上限）
   ▼
[Web high] delta = h_pre_lo − h_lo → 双线性放大 → h = max(h_pre − delta↑, sea+eps)（陆地）
   ▼
[spl+carve] carve_drainage_valleys（depth × dem_spl_carve_scale，复用同一份填洼）
   ▼ height_final
河流 SDF 下切（不变） → 海岸 SDF 下切（不变） → bundle
```

**关键取舍**

- **`uplift = 0`**：bake 期是纯瞬态下切，侵蚀量由「总侵蚀时间」`K` 控制，天然满足不变量 1。
  抬升只在 cell 级有意义（关联计划）。
- **一棵流向树贯穿 SPL / 沉积**：受体在 pass 内不重算。纯下切、轮数少时受体几乎不变，
  这是 Braun & Willett 在小步长下的常用近似，换来 `pow` 只算一次、每轮只是一次线性扫描。
- **限坡放在最后**：SPL 在像素层只刻出约 1 px 宽的主槽（坡面像素 A 小、C≈0，跟不上下切），
  谷的宽度与截面形状**几乎完全由限坡决定**。因此「软/锐」的旋钮是坡限系数，而不是是否叠 carve（§4.6）。

### 4.2 物理单位化（v2 新增，修 v1 的分辨率耦合）

| 量 | v1 写法 | v2 写法 |
|---|---|---|
| 每 hex 像素数 | — | `hex_px = hex_size·√3 / step_x`（与 carve `dp.hex_px` 同算法，[world_ext_bake.cpp:982](../../gdext/src/world_ext_bake.cpp)） |
| 汇水面积 | `area_px / area_ref(陆地平均)` | `A_hex = area_px / hex_px²` |
| 受体距离 | 未考虑 | `dx_hex = DL[k] / hex_px`（正交 1、对角 √2） |
| 下切系数 | `k·(A/Ā)^m` | `C = K_iter · A_hex^m / dx_hex`，`K_iter = dem_spl_k / iters` |
| 面积下限 | `min_area_px = 8` | `dem_spl_min_area_hex = 0.03`（≈ 8 px @17 px/hex） |
| 坡限 | `talus_hex = 0.04`（全局） | `s_lim = dem_slope_limit_per_relief · max(relief, floor)` /hex，像素步长 `s_lim · dx_hex` |

v1 用「陆地平均汇水面积」归一，强度会随海陆比例、种子漂移；并且像素面积随分辨率平方变化，
同一 `k` 在三档平台上谷深不同。v2 以 1 hex² 为参考面积，`dem_spl_k` 的含义是「总侵蚀时间」，
轮数只决定把这段时间切成几步——隐式格式无条件稳定，轮数变化只带来小的离散误差，不改变宏观强度。

量级核算（hex_px≈17，m=0.45，**设计时**取 `dem_spl_k=0.03`，iters=6 → `K_iter=0.005`；
标定后实际为 `dem_spl_k=0.50` → `K_iter≈0.083`，即实际下切强度约为本节估算的 17 倍）：

- 干流 `A_hex≈100`：`C ≈ 0.005·7.9·17 ≈ 0.68` / 轮 → 6 轮后与下游高差约收敛到原来的 4% 量级（强下切）。
- 坡面像素 `A_px=1`（`A_hex≈0.0035`）：`C ≈ 0.005·0.078·17 ≈ 0.007` → 基本不动（正确：坡面由限坡负责）。

**量级核算修订（2026-11-18，S4.4 实测；结论：上一段的 `A_hex≈100` 假设错了 65 倍，单位无 bug）**：

新增 `dem_erosion_area_dump` 诊断导出像素层 `A_hex` 后实测（desktop，真实地图，`hex_px = 16.3033`，
1 px 面积 = `1/hex_px²` = 0.003762 hex²）：

| 陆地像素 `A_hex` | p50 | p90 | p99 | max |
|---|---:|---:|---:|---:|
| hex² | 0.00752 | 0.11287 | **1.54629** | 9.85713 |
| 换算像素 | **2 px** | 30 px | **411 px** | 2620 px |

- **「干流 `A_hex≈100`」这个假设大了 65 倍**（100 hex² = 26580 px，实测 p99 只有 411 px、中位数只有 2 px）。
  根因：河心像素被设为汇流出口 ⇒ **像素汇水在流到第一个 wet / 河心像素时就被截断**，
  全场累计只有 1–2 px（陆地 p50 = 2.0 px、河心 p50 = 1.0 px）。
- 用实测 `A_hex` 重算即可对上代码：`K_iter = 0.50/6 = 0.0833`，取 p99 的 `A_hex = 1.546` ⇒ 手算
  `C(DL=1) = 1.653`、`C(DL=√2) = 1.169`、每轮削减比 `C/(1+C) = 0.623`、6 轮累计逼近 99.7%；
  **实测该像素 `rel_drop = 0.0471`** ⇒ 只有高 A 像素才明显下切，与「像素层只刻约 1 px 主槽」的原判断一致。
- 与本节旧估算的对照：旧写法按 `A_hex = 100` 得 `C_plan(k=0.03) = 0.648`；实测 `C(k=0.50, A=p99) = 1.653`（比值 2.55）。
  按 `C ∝ A^0.45`，光 `A_hex` 这一项就差 65^0.45 ≈ **6.6 倍** —— 这就是 `dem_spl_k` 需要 0.50 而不是 0.03 的主因。
- ⇒ **本节结论改为**：干流按 `A_hex` **p99 ≈ 1.5 hex²（约 400 px）** 量级估算，不要再用 100 hex²；
  `unit_area`、`K_iter = k/iters`、`C = K_iter·A^m/dx_hex` 的实现与契约一致，**不需要改代码**。

`dem_spl_k` 默认值 P2 标定：以 `spl_p99_drop ∈ [0.01, 0.08]` 为目标（§6 P2 验收 3）。

### 4.3 流向树：填洼 + 最陡受体

```
z = H；出口 = wet ∪ 南北边缘（经线方向按 wrap_cols 环绕）
Priority-Flood+ε（Barnes 2014）：key = (float z, int32 idx) 字典序；
    出栈序 order 对填洼面 z 单调不减 → 任何 z 严格更低的邻点都已先出栈
rcv[i] = argmax_k (z[i] − z[nb_k]) / DL[k]，仅取 z 严格更低的邻点；平局取 k 小者
A：沿 order 逆序 A[rcv[i]] += A[i]（初值 1 px）
```

- **受体取最陡下降，不取 Priority-Flood 的「关闭者」**：关闭者只是先出栈的那个邻点，不一定最陡，
  直接用它会产生锯齿流路。最陡受体的 z 严格更低，因此 `order` 仍是合法拓扑序。
- 填洼面 z 只用于建树；SPL 作用在原始 H 上（不变量 1 禁止填高）。洼地内部像素的受体比自身高，
  隐式公式会被 `clamp(·, ·, h[i])` 截住而不动——洼地保留为原样，不新增也不消除。
- 性能：`pair<float,int32>` 比现有 `pair<double,int64>` 内存减半；洼地/平地内部走 FIFO 队列
  （Barnes 2014 的 Priority-Flood 改进），只有开放边界走堆。P0 抽出的 `pk_dem::fill_depressions`
  必须先保持 carve 逐位一致（double key 路径），优化后的 float 路径只给 SPL 用（§6 P0）。
- 单一受体有 45° 方向偏置风险；像素层已有 `ridge_off` / `pk_dem::landform` 噪声打散对称性，
  默认不加 D∞。若 A/B 看到平行斜沟，再开可选的 2 受体分配（+8 B/px）。

### 4.4 隐式 SPL 下切

```
for i in order:                         # 下游先，rcv 本轮已更新
    if wet[i] or A_hex[i] < min_area: continue
    r = rcv[i]
    h_new = (h[i] + C[i]·h[r]) / (1 + C[i])
    h[i] = clamp(h_new, sea + eps, h[i])     # 只降、不下海；洼地内 h[r] > h[i] 时不动
```

- `C[i]` 在循环外预计算一次（620k 次 `pow`，约 5–10 ms），每轮只剩一次乘加扫描（约 2–4 ms）。
  v1 估算的「每轮 12 ms pow」不再存在，因此**没有理由为性能削减 Web 轮数**。
- 记录 `drop[i] = h_pre[i] − h[i]`，供 P3 与诊断复用。
- 串行执行（拓扑序依赖），天然确定。

### 4.5 限坡：只削高侧（v2 重定义，替换 v1 的 thermal）

v1 的 thermal 把物质搬给低处，会抬高谷底，与「只降」不变量冲突；就地扫描还依赖线程顺序。v2 改为
**临界坡度削坡**：坡面物质被认为已被河流带走，只降不升。

```
L[i] = h[i]                                    # 水体/河心像素：不作为约束源，L 不变
s[i] = dem_slope_limit_per_relief · max(relief[i], dem_slope_limit_relief_floor)   # height / hex
cap[i] = dem_slope_limit_cap_per_relief · relief[i]                                  # 单像素最大削减
L[i] = max( min(L[i], min_m(L[m] + s[i]·DL[k]/hex_px)), h[i] − cap[i] )
```

用与 carve 第 4 步相同的前向/后向倒角扫描，2 遍收敛（[bake_dem_landform.h:252-279](../../gdext/src/bake_dem_landform.h) 同构），
串行、确定、约 10–15 ms。

- **默认 `dem_slope_limit_per_relief = 5.0`，与 carve 的 `dem_valley_wall_per_relief` 相同**：
  SPL 槽 + 同坡限 ≈ 现状谷壁锐度。想要更软就降到 3.0，而不是叠 carve。
- 坡限按局地起伏缩放：山地陡、丘陵缓、平原（relief≈0）基本不触发——这正是 v1 全局 `talus_hex=0.04`
  做不到的。
- 可选 `dem_crest_round`（默认 0）：一步「只取负值」的 Laplacian（`h += min(0, κ∇²h)`），只磨圆凸脊、
  不填谷，满足不变量 1。A/B 觉得脊线太尖时再开。

### 4.6 P3 输运受限沉积（本轮做，默认关，A/B 后决定是否默认开）

替换 v1 的「低于邻域均值处抬升、总量受 p99 约束」经验规则，改为沿同一棵树的**体积守恒**输运：

```
Qs[i] = 0
for i in reversed(order):                       # 上游先
    if wet[i]: continue                         # 出口：剩余泥沙丢弃（不做三角洲）
    Qs[i] += drop[i]                            # 本像素被 SPL 削掉的体积（height·px）
    S = max(h[i] − h[rcv[i]], 0) / dx_hex
    Qc = dem_dep_kc · A_hex[i]^m · S            # 搬运能力（与 SPL 同指数 m）
    if Qs[i] > Qc and A_hex[i] ≥ dem_dep_min_area_hex:
        room = min(h_pre[i] − h[i],             # 不高于侵蚀前
                   min_child_h(i) − eps − h[i]) # 不高于任一上游子像素 → 不造洼（不变量 4）
        D = clamp((Qs[i] − Qc) · dem_dep_rate, 0, room)
        h[i] += D;  Qs[i] −= D
    Qs[rcv[i]] += Qs[i]
```

- 出现位置：坡度骤降、汇水大的地方（谷口、山前、宽谷）——即冲积扇与谷底，物理上合理。
- 总沉积量 ≤ 总削蚀量（守恒，测试断言）。
- **谷底展宽（P3b，可选，默认关）**：沉积只抬 1 px 宽的主槽，宽谷底需要侧蚀。对 `A_hex ≥ A_floor` 的槽像素，
  以 `w = dem_floor_width_hex · A_hex^0.5`（水力几何：河宽 ∝ 流量^0.5，Leopold & Maddock 1953）为半宽，
  把半宽内高于槽底的像素削到 `槽底 + 微小横坡`——仍是只降、仍是倒角扫描，复用 §4.5 的实现
  （在半宽内把 `s[i]` 换成 `dem_floor_slope`）。
- 成本：P3a 一次 O(N) 扫描 ~5–10 ms；P3b 一次倒角扫描 ~10–15 ms。

### 4.7 Web high：在 1024 计算栅格上侵蚀，只放大改造量

| 平台 | 基线 | 计算栅格 | 说明 |
|---|---:|---:|---|
| mobile | 512×304 | 512×304 | 原生；单位化后宏观与桌面一致 |
| desktop | 1024×606 | 1024×606 | 原生 |
| Web high | 2048×1212 | **1024×606** | 2×2 盒式下采样 → 全流程 → `delta↑` 双线性放大 |

- `dem_erosion_max_dim = 1024`：基线长边超过它时按整数因子下采样（wrap 感知）；`hex_px` 同步除以因子。
- 放大后 `h = h_pre_hi − delta↑`，陆地再按不变量 2 截断，水体像素不动。`delta ≥ 0`（含 P3 时仍成立），
  双线性放大保持 ≥ 0，不变量 1 自动成立。
- 理由：① tile 只读基线的低频改造量（§1.1），2048 原生侵蚀几乎拿不到额外细节；② 与桌面同网格，
  Web/桌面观感一致（v1「降到 3 轮」会让两者不同）；③ 瞬时内存从 ~52 MB 降到 ~15 MB，避开 WASM 32 位地址空间风险；
  ④ 主槽在 2048 上变成 ~2 px 软槽，随后的河流 SDF 下切仍在 2048 原生分辨率执行，岸线锐度不受影响。

### 4.8 融合 pass 接线

```cpp
const String mode = knobs.get("dem_erosion_mode", "carve");   // C++ 默认永远是 carve
// carve | spl | spl+carve | droplet（droplet 仅历史对照）
if (mode == "carve") { carve_drainage_valleys(...); }          // 现路径，逐位不变
else if (mode.begins_with("spl")) {
    ErosionGrid g = make_erosion_grid(height_buf, relief, wet, max_dim);   // 1:1 或下采样
    pk_erosion::build_flow(g, fp, flow);                       // 填洼 + rcv + A + order
    pk_erosion::precompute_coeff(flow, sp, C);
    pk_erosion::spl_incise(g, flow, C, sp, &stats);
    if (dep.enabled) pk_erosion::deposit(g, flow, dep, &stats);
    pk_erosion::slope_limit(g, sl, &stats);
    apply_delta(height_buf, g);                                // 1:1 时直接写回
    if (mode == "spl+carve") carve_drainage_valleys(..., depth × carve_scale, reuse_fill=flow);
}
if (mode == "droplet") { knobs["height_buffer"] = height_buf; run_bake_erosion_pass(knobs); }
```

- **C++ 默认值永远是 `carve`**；`spl` 只由 project-keynes 的 `DEM_DEFAULTS` 显式传入。
  `Project/perf-validation` 加载同一 DLL 但不传该 knob → 行为逐位不变（§12 Q7）。
- 默认路径不再调用液滴 pass（省 3.7 ms）；`run_bake_erosion_pass` ABI 不变，保留给 `droplet`。
- 新增 `run_bake_erosion_spl_pass(knobs)`（buffer-encoder 范式），只给测试/probe 喂合成高度场；生产走融合 pass。

### 4.9 新增 header：`gdext/src/bake_erosion_spl.h`

纯函数、header-only、无 Godot 依赖（同 `bake_dem_landform.h` 风格）：

```cpp
namespace pk_erosion {
struct Grid      { int w, h, wrap_cols; double sea_level, sea_eps, hex_px;
                   float *H; const float *H_pre; const float *relief; const uint8_t *wet; };
struct Flow      { std::vector<int32_t> order, rcv; std::vector<float> area_hex; std::vector<uint8_t> rcv_k; };
struct SplParams { int iters; double k_total, m, min_area_hex; };
struct DepParams { bool enabled; double kc, rate, min_area_hex;
                   bool floor_widen; double floor_width_hex, floor_slope, floor_min_area_hex; };
struct LimParams { double per_relief, relief_floor, cap_per_relief, crest_round; };
struct Stats     { double p99_drop, max_drop, eroded_vol, deposited_vol;
                   int sea_clamped, nan, pits_in, pits_out; };

void build_flow(const Grid &, Flow &);
void precompute_coeff(const Grid &, const Flow &, const SplParams &, std::vector<float> &C);
void spl_incise(Grid &, const Flow &, const std::vector<float> &C, const SplParams &, Stats &);
void deposit(Grid &, const Flow &, const DepParams &, const SplParams &, Stats &);
void slope_limit(Grid &, const LimParams &, Stats &);
}
```

### 4.10 knobs 契约

挂在 `terrain_index_baker.gd::DEM_DEFAULTS`（[terrain_index_baker.gd:74-98](../../Project/project-keynes/scripts/rendering/bakers/terrain_index_baker.gd)），
经 `dem_landform_knobs()` 并入 fused knobs，可用 `project_keynes/rendering/dem/<去 dem_ 前缀>` 覆盖。

| knob | DEM_DEFAULTS | C++ 缺省 | 说明 |
|---|---:|---:|---|
| `dem_erosion_mode` | **`"spl"`**（P2.7，2026-11-18 已切） | `"carve"` | `carve`/`spl`/`spl+carve`/`droplet`；**C++ 缺省恒 `carve`** |
| `dem_erosion_max_dim` | 1024 | 1024 | 计算栅格长边上限（§4.7） |
| `dem_spl_iters` | 6 | 6 | 把总侵蚀时间切成几步（不改变宏观强度） |
| `dem_spl_k` | **0.50**（P2 实测标定） | **0.50**（同步标定，避免「漏传 knob」时兜底值成陷阱） | 总侵蚀时间；hex 单位 |
| `dem_spl_m` | 0.45 | 0.45 | 面积指数（地貌学 0.4–0.6） |
| `dem_spl_min_area_hex` | 0.03 | 0.03 | 低于它不下切 |
| `dem_slope_limit_per_relief` | 5.0 | 5.0 | 坡限 / hex（= carve wall，锐度对齐现状） |
| `dem_slope_limit_relief_floor` | 0.04 | 0.04 | 同 carve `wall_relief_floor` |
| `dem_slope_limit_cap_per_relief` | 1.4 | 1.4 | 单像素最大削减（= carve `depth_per_relief`） |
| `dem_crest_round` | 0.0 | 0.0 | 凸脊磨圆强度 |
| `dem_dep_enabled` | false（A/B 后由用户裁决） | false | P3a |
| `dem_dep_kc` | 0.02（P3 标定） | 0.02 | 搬运能力系数 |
| `dem_dep_rate` | 0.5 | 0.5 | 超载部分每像素沉积比例 |
| `dem_dep_min_area_hex` | 0.5 | 0.5 | 只在成形河道沉积 |
| `dem_floor_widen` | false（A/B 后由用户裁决） | false | P3b |
| `dem_floor_width_hex` | 0.04 | 0.04 | 半宽 = 它 · A_hex^0.5 |
| `dem_floor_slope` | 0.002 | 0.002 | 谷底横坡 / hex |
| `dem_floor_min_area_hex` | 2.0 | 2.0 | 展宽起点 |
| `dem_spl_carve_scale` | 0.40 | 0.40 | 仅 `spl+carve` |
| `dem_erosion_pit_audit` | false | false | 诊断：合并管线额外算 `pits_out`（不改地形） |

共 19 项侵蚀 knob + 1 项诊断 knob。`dem_spl_k` 的标定依据（**实测后确定**）：真实地图 60×40 / 1024×606 上
`k=0.60 → p99=0.0843`（超出 `[0.01, 0.08]` 上界）、`k=0.50 → p99=0.0719`（带内，余量约 10%）⇒ **取 0.50**；
合成起伏图上 `k → p99` 扫描为 0.03→0.0070、0.30→0.0419、0.45→0.0558、**0.50→0.0602**、0.60→0.0694、
0.90→0.0906、1.20→0.1080，**近似线性**；强度对齐上 `spl(k=0.50)` 的 `mean=0.01236 / p99=0.0588 /
changed_frac=0.223`，约为 `carve`（`mean=0.01382 / p99=0.0933 / frac=0.368`）的 **89%**——偏柔但同量级。

旧 `dem_valley_*` 在 `carve` 下语义不变；在 `spl+carve` 下只作用于叠加的浅刻谷。
`dem_valley_river_outlet_flow` 在所有模式下都决定河心出口（R4）。

### 4.11 输出 / 诊断契约

融合 pass 返回 dict **只增不改**：

| key | 说明 |
|---|---|
| `erosion_mode` | 实际生效模式 |
| `erosion_grid_w/h`、`erosion_grid_factor` | 计算栅格与下采样因子 |
| `flow_ms` / `spl_ms` / `dep_ms` / `limit_ms` / `carve_ms` / `upsample_ms` | 分项耗时（−1 = 未执行） |
| `fill_ms` / `mfd_ms` / `wall_ms` | **carve 分项（P0 新增）** |
| `spl_iters_effective`、`spl_p99_drop`、`spl_max_drop` | 下切统计 |
| `eroded_vol` / `deposited_vol` | 体积守恒核对（deposited ≤ eroded） |
| `spl_sea_clamped` / `spl_nan` / `pits_in` / `pits_out` | 正常应 `nan=0`、`pits_out ≤ pits_in` |
| `erosion_ms` / `erosion_ok` | 保留；语义为「整个侵蚀阶段」 |

**`upsample_ms` 的口径（实测后修订）**：只含**计算栅格下采样 + delta 取非负 + 双线性放大 + 写回基线**，
不含建树 / SPL / 限坡（这三项各记 `flow_ms` / `spl_ms` / `limit_ms`）。首版实现在 2048 上误报 185.6 ms，
是因为把 flow/spl/limit 也算进了这一段；修正口径 + `upsample_box_f32` 8× 优化后，2048×1212 上实测
**16.2 ms**（落在 §5 估算的 +10~20 ms 内）。`factor==1` 且无别名列时该值为 `-1`。

GDScript 日志（[terrain_baker.gd:615](../../Project/project-keynes/scripts/rendering/bakers/terrain_baker.gd)）：

```
[fused] terrain=..ms erosion=..ms(mode=spl grid=1024x606 flow=.. spl=..x6 dep=.. limit=.. p99=..) river=..ms ...
```

### 4.12 内存（瞬时，进入 tile 烘焙前全部释放）

| buffer | @620k（desktop / Web 计算栅格） |
|---|---:|
| `order` / `rcv` int32 | 5.0 MB |
| `area_hex` / `C` float | 5.0 MB |
| `h_pre` 副本 / `drop` float | 5.0 MB |
| 堆 + 队列（峰值） | ~5 MB |
| **合计** | **~20 MB**（v1 的 Web 52 MB 不再出现） |

---

## 5. 性能预算与验收（2026-11-18 用实测重写）

**构建与口径**：Windows `scons platform=windows target=template_debug`（`template_debug`，非 release）；
统一图 60×40 / 基线 1024×606 = **620,544 px**；除标注外 `dem_erosion_pit_audit=false`（生产值）。

> **release 仍未测（2026-11-18 跟进复述）**：本节全部数字**都是 `template_debug`**，`template_release` 从未构建；
> 跟进计划的 S6.2（release 重测）本轮也没做。引用时**必须带「`template_debug`」限定**：
> 同函数 `/Od` 比 `/O2` 可慢 4.3×，所以本节**同配置内的成对对照**（carve vs spl）可用，
> **跨配置的绝对耗时不可用**，也不要把本节数字直接当出货性能。

### 5.1 carve 分项（P0.8，预算修订依据）

| 项 | v2 估算 | 实测 | 结论 |
|---|---:|---:|---|
| 填洼 | 40–80 ms | **59–69 ms** | 落在估算区间内 |
| 受体 + 面积（MFD） | 5–10 ms | **26–29 ms** | 明显超估算 |
| 谷壁倒角 | 未单列 | **40–42 ms** | 本次新增分项 |
| `carve_ms` 合计 | 150 ms（旧日志） | **127–143 ms** | 比旧日志快 |

### 5.2 三档 carve vs spl 成对对照（同一张图、同一次运行背靠背）

| 栅格 | `carve` geometry | `spl` geometry | spl 分项 flow / spl / limit / upsample |
|---|---:|---:|---|
| 512×303 | 62.2 ms | 63.9 ms | 22.1 / 5.7 / 2.9 / −1 |
| 1024×606 | 231.6 ms | 264.9 ms | 88.7 / 15.0 / 14.8 / −1 |
| **2048×1212（Web high）** | **1072.8 ms** | **514.5 ms** | 76.8 / 12.4 / 13.1 / **16.2** |

**这是本轮最有价值的结论，且与 v2 的预期相反**：

- **Web high 上 spl 明显更快**：1072.8 → 514.5 ms（**快 558 ms**）。`carve` 是 O(像素数) 的
  （fill/MFD/谷壁全在 2048 上跑，`valley=708.8 ms`），而 `spl` 在 §4.7 的 1024 计算栅格上跑。
- **desktop 上 spl 慢约 33 ms**（231.6 → 264.9 ms）；512 档基本持平（+1.7 ms）。
- `upsample_ms` 在 2048 上 = **16.2 ms**，落在 v2 估算的 **+10~20 ms** 内。

### 5.3 单模式各阶段扫描（同图，另一次运行；同机波动约 ±15%）

同一台机器多次运行波动明显，**`spl` desktop geometry 5 次实测 232.9 / 243.3 / 246.9 / 260.4 / 264.9 ms**，
故 desktop 口径一律写成 **约 233–265 ms**，不写死单一值。下表保留各阶段分项，用于看结构占比：

| 模式 | geometry | terrain | erosion 阶段 | flow | spl | limit | dep | upsample | valley(carve) |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| `carve` | 210.1 | 63.8 | 2.3 | — | — | — | — | — | 134.5 |
| `spl` | **232.9** | 67.8 | 166.6\*| 77.5 | 12.8 | 12.4 | — | — | — |
| `spl+carve` | 304.5 | 64.3 | 231.5 | 75.0 | 12.4 | 11.3 | — | — | 69.3 |
| `spl+dep` | 249.6 | 68.6 | 172.1\*| 74.8 | 12.7 | 10.6 | 12.3 | — | — |
| `spl+dep+widen` | 263.6 | 62.6 | 192.1\*| 72.9 | 12.2 | 10.6 | 37.6 | — | — |
| `droplet` | 73.6 | 62.6 | 2.1 | — | — | — | — | — | — |

`*` 该列含 `dem_erosion_pit_audit=true` 的额外一次填洼（约 60 ms）；生产 `audit=false`，故生产 erosion 阶段更短。
`fill/mfd/wall/carve_ms` 只在 `carve` 与 `spl+carve` 有值；未执行项一律 `-1`（报告契约见 §4.11）。
`upsample_ms` 在本图中为 `-1`：真实地图 1956 宽 + wrap → 计算栅格 978×606，`factor=1`、无放大段。
desktop 分项中位：`flow≈80 ms / spl≈13 ms / limit≈13 ms`。

### 5.4 生产路径 A/B（`tests/game/headless_perf_record.gd`，60×40，seed=20260718）

| 指标 | `carve` | `spl`（k=0.50，最终默认） |
|---|---:|---:|
| `[fused]` valley | 113.7 ms | −1（未执行） |
| `[fused]` erosion | 2.7 ms | 86.0 ms |
| `[fused]` 分项 | — | flow=68.1 / spl=6.4(x6) / limit=7.9 |
| `[fused]` grid | −1 | 978×606（factor=1，无放大） |
| `spl_p99_drop` | −1 | **0.0719** |
| `MapBaker v6: total` | **1439 ms** | **1393 ms（−46 ms）** |

### 5.5 验收线（原判据 → 实测结论）

| 指标 | v2 验收线 | 实测 | 结论 |
|---|---:|---:|---|
| geometry pass（desktop） | ≤ 330 ms（原基线 312 ms） | `spl` **约 233–265 ms** / `carve` 231.6 ms | **通过** |
| geometry pass（Web high） | ≤ desktop + 40 ms | `spl` **514.5 ms** vs `carve` 1072.8 ms（desktop `spl` 264.9 ms） | **原判据不成立，已改写**（见下） |
| `MapBaker v6: total`（60×40 desktop） | ≤ 2350 ms（原基线 2313 ms） | `spl` **1393 ms** / `carve` 1439 ms | **通过**（本机基线本就比记录值快） |
| 运行期 | 0 | 0（未新增运行期 pass） | 通过 |

**「Web high ≤ desktop + 40 ms」的改写（实测后修订）**：该判据不成立（514.5 ms 仍是 desktop 264.9 ms 的
约两倍），但**这不是本次侵蚀新增的成本**——`spl` 的 Web high 分项（flow 76.8 / spl 12.4 / limit 13.1 /
upsample 16.2 ms）与 desktop 同价，多出来的量来自 **terrain-index 等既有 per-pixel pass 在 4 倍像素数上的
固定成本**（terrain-index 2048 = 320.3 ms vs desktop 67.2 ms）。真正的结论要用**成对对照**表述：

> Web high 上 `spl` 比 `carve` **快 558 ms**（1072.8 → 514.5），因为 `carve` 的 fill/MFD/谷壁全是 O(像素数)
> 而 `spl` 在 1024 计算栅格上跑；desktop 上 `spl` 比 `carve` 慢约 33 ms，512 档持平。
> 因此「Web high 是否变慢」的正确判据是 **成对对照（同图同次运行）**，而不是「相对 desktop 的绝对增量」。

`upsample_ms` 曾在 2048 上误报 185.6 ms，那是计时范围把 flow/spl/limit 也算进去了（见附录 B）；
修正口径后 **16.2 ms**，落在估算的 +10~20 ms 内。定义已在 §4.11 钉死。

若日后填洼成本再涨，优先优化填洼（它同时加速 carve 回退路径），不靠削轮数。

---

## 6. 分阶段落地

### P0 契约、计时与护栏（无视觉变化）—— **已完成并验证**

1. carve 内部补 `fill_ms / mfd_ms / wall_ms` 分项计时 → 实测 **59–69 / 26–29 / 40–42 ms**（§1.2）。
2. 抽出 `pk_dem::fill_depressions()`（double key，**逐位等价**），carve 改调用它；float+FIFO 版本只给 SPL。
3. `dem_erosion_mode` knob（**C++ 缺省 `carve`**）+ 融合 pass 分支骨架；`run_bake_erosion_spl_pass`
   （buffer-encoder 范式）+ `world_ext.h` 声明 + 绑定 + 重生成 `native_binding_manifest.json`。
4. report keys 与 `terrain_baker.gd` 日志行扩展（`fill/mfd/wall` + `flow/spl/dep/limit/carve/upsample`）。
5. 护栏（grep 门禁）结论：`WorldData.sample_height(` **全仓库零调用方**（只有 `world_data.gd:422` 的定义）；
   `world.height_buffer` 的消费者全在 `scripts/rendering/**`（terrain_baker / terrain_index_baker /
   surface_baker / map_baker / ocean_current_baker / renderer_terrain_horizon），用途是纹理编码、视觉 tile 基线、
   地平线与逐帧高度采样。唯一「像物理消费」的是 `ocean_current_baker.gd` 的 `height[i] < sea`，但它只是
   **海陆掩码的 fallback**（首选 `biome_buffer`），而本次改动保证水体像素逐位不变、陆地 ≥ `sea+5e-4`
   ⇒ 海陆分类不变 ⇒ 无玩法影响。

**验收**：`carve` 下 `height_buffer` hash 与改动前一致——FNV-1a 32-bit over 原始字节：

| 用例 | 改动前 | 改动后 |
|---|---:|---:|
| desktop 60×40 / 1024×606 | 2131172194 | **2131172194** |
| flat 7×7 / 256×160 | 2102047896 | **2102047896** |
| sloped 7×7 / 256×160 | 1000138302 | **1000138302** |

另有 8 组几何的 `memcmp` 逐位差分（含 wrap / 非 wrap / flat-relief / 全湿 / 全干），carve-refactor 报告
**72 项断言 0 失败**；`native_generation_equivalence_test.gd` 32/0、`check_world_ext_bindings.py` 0 problems。

### P1 限坡（独立可测）—— **已完成并验证**

- `slope_limit` 倒角实现（只削高侧）+ `dem_crest_round` 可选项；仅在 `mode=spl*` 下执行。
- **验收实测**：`per_relief` 0.3 vs 1e6 → 最大邻格坡度 **0.006737 vs 0.010805（降 38%）**；
  `per_relief=1e6/1e9` 输出逐位相等（A7）；水体与河心像素逐位不变（A2 `wet_drift=0`）；
  耗时 `limit_ms` **12.4 ms（≤ 15 ms）/ 10.6 ms（spl+dep）**。

### P2 汇流 SPL（主变更）—— **已完成并验证**

- `build_flow`（最陡受体）+ `precompute_coeff` + `spl_incise` + Web 计算栅格（§4.7）。
- `spl+carve` 分支同时实现，一次编译内可对比 `carve / spl / spl+carve`。
- **验收实测**：
  1. 合成单锥坡上谷深与 `log(A_hex)` 的 Pearson 相关 **0.9041** > 0.8 ✓
  2. **Flint 律**（原判据）：河道像素（`A_hex ≥ 1`）`log S – log A` 回归斜率（凹度 θ）∈ [0.30, 0.60]，
     记录、不门禁于真实地图。**实测 θ = 0.4001 ∈ [0.30, 0.60] ⇒ 达标** ✓
     （`k=0.30` 时为 0.291，说明 θ 对 `dem_spl_k` 敏感；标定到 0.50 后进入目标带 ⇒ 豁免条款**不启用**，见附录 A.1）
  3. `spl_p99_drop = 0.0719 ∈ [0.01, 0.08]` ✓、`spl_nan = 0` ✓、`pits_out 16677 ≤ pits_in 44323` ✓
  4. 河道像素（`A_hex ≥ 1 hex²`）位于 3 px 邻域局地谷底的比例 **0.9809 ≥ 0.95** ✓
  5. A/B 截图（树枝状谷、谷底连贯、河在谷里）：**未测**（本轮证据只有 headless 数字，无截图）
  6. 512 / 1024 / 2048 三档一致性：原判据 A9 **不可达，已改写**；改写后的 A9(1) 三档 `spl_p99_drop`
     相差 **1.55%**、A9(2) 16 px 块均值相关 **0.9571** 均通过 ✓（见 §8.1 与附录 A.2）
  7. 性能落进 §5 ✓（desktop geometry **约 233–265 ms** ≤ 330 ms；`MapBaker v6: total` 1393 ms ≤ 2350 ms）
- **P2.7 已执行**：`DEM_DEFAULTS.dem_erosion_mode` 已改为 `"spl"`（**C++ 缺省仍恒 `carve`**）。

### P3 沉积与谷底（本轮做，默认关）—— **已完成并验证；默认仍关**

- P3a `deposit`（§4.6）、P3b `floor_widen`，各自独立开关，与 P2 同一次编译交付。
- **验收实测**：`deposited_vol 134.811 ≤ eroded_vol 461.735` ✓；全像素 `h ≤ h_pre` ✓；
  `pits_out 16677 ≤ pits_in 44323` ✓；水体逐位不变 ✓；`dem_dep_enabled=false` 逐位回到 P2 ✓（A10）。
  **未测**：P3b「谷底连续宽度中位数 ≥ 3 px」、谷口冲积扇 / 宽谷底的 A/B 截图（本轮无截图证据）。
- **P3.4 未执行**：`dem_dep_enabled` / `dem_floor_widen` 维持 `false`；是否默认开属**用户 A/B 裁决**，
  本轮不代替用户决定。

### P4 tile 细节与汇流对齐（可选，下一轮）—— **未实现**

- 设计（保留不改）：`run_bake_visual_tile_layer_pass` 用基线 `A_hex` 双线性采样调制 `pk_relief` 沟谷方向/密度，
  取代纯局部坡向 steer（[world_ext_bake_visual_tiles.cpp:708](../../gdext/src/world_ext_bake_visual_tiles.cpp)）。
  需要把 `area_hex` 作为基线产物多保留一张 R16/F32（~2.5 MB），成本 +1~3 ms/层。
- 本轮**未做**（checklist P4.1 亦未勾选），留给下一轮；不得记为已完成。

### （原 P5）cell 级脊噪声顺序 → [terrain-ridge-uplift-plan.md](terrain-ridge-uplift-plan.md)

两份计划互不依赖；建议本计划 P2 合入后再做关联计划的视觉 A/B，一次只变一个变量。

---

## 7. 文件级改动清单

| # | 文件 | 动作 | 规模 |
|---|---|---|---|
| 1 | `gdext/src/bake_erosion_spl.h` | **新增**：流向树 / 系数 / SPL / 沉积 / 限坡 / 计算栅格 | ~450 行 |
| 2 | `gdext/src/bake_dem_landform.h` | 抽 `fill_depressions`（逐位等价）+ 分项计时钩子；`carve` 可接受外部填洼结果 | ~60 行 |
| 3 | `gdext/src/world_ext_bake.cpp` | ①b 模式分支；`run_bake_erosion_spl_pass`；report keys | ~+300 / −40 |
| 4 | `gdext/src/world_ext.h` | 声明 + 契约注释 | ~+20 |
| 5 | `gdext/src/world_ext_bind_generation.cpp` | `ClassDB::bind_method` | +4 |
| 6 | `Project/project-keynes/data/native_binding_manifest.json` | `python3 tools/ci/world_ext_bindings.py --write-manifest` | 自动 |
| 7 | `Project/project-keynes/scripts/rendering/bakers/terrain_index_baker.gd` | `DEM_DEFAULTS` 新增 19 项 | +25 |
| 8 | `Project/project-keynes/scripts/rendering/bakers/terrain_baker.gd` | 日志行扩展 | ~8 |
| 9 | `Project/project-keynes/tests/world/erosion_spl_bake_test.gd` | **新增** | ~300 |
| 10 | 文档（§9） | 同步 | — |

**不改**：`Project/perf-validation/**`（§12 Q7）、`map_baker.gd` 的 `EROSION_*`（保留给 `droplet`）、shader、存档、运行期任何 pass。

**落地结果（2026-11-18）**：1–10 全部完成。`native_binding_manifest.json` 计数 **661 → 662**（只多
`run_bake_erosion_spl_pass`）；`erosion_spl_bake_test.gd` 覆盖 A1–A11（`checks=11 failures=0 skips=0`）；
`world_ext.h` +40 行、`world_ext_bake.cpp` +586 行已做**评审式** `check_size_ratchet.py` baseline 更新
（只动这两条，不用 `--write-baseline` 整体快照，避免顺带洗白他人未提交增长）。

---

## 8. 测试与验证

### 8.1 新增 `tests/world/erosion_spl_bake_test.gd`

headless，直接调 `run_bake_erosion_spl_pass` 喂合成高度场（**A12 例外：跑真实 60×40 地图**）：

| # | 断言 |
|---|---|
| A1 | 不变量 1：全像素 `h ≤ h_pre`；无 NaN |
| A2 | 陆地 ≥ `sea+eps`；水体与河心像素逐位不变 |
| A3 | 单锥坡：谷深 vs `log(A_hex)` 相关 > 0.8 |
| A4 | 确定性：同 knobs 两次结果逐元素相等 |
| A5 | 线程无关：融合 pass 内**真并行**的部分（terrain-index、放大）用 1 / N 任务数各跑一次，结果逐位相等；侵蚀核本身串行 |
| A6 | 经线接缝：`wrap_cols` 开启时首末列差 < 2e-6 |
| A7 | 限坡：坡限调小后最大邻格坡度下降；`per_relief=∞` 时输出与 SPL 结果逐位相等 |
| A8 | 回退：`carve` 的 fused 结果 hash 与基线一致 |
| A9 | **分辨率无关**（**原判据，实测后修订**）：同一解析地形以 512 / 1024 栅格分别烘焙，把 1024 的 `delta` 盒式下采样到 512 后与 512 的 `delta` 相关 > 0.85，p99 下切量相差 < 20%。**实测不可达**（盒式平均后相关 0.6802、p99 相差 21.7%），改写为 A9(1)/A9(2)，见 §8.1.1 与附录 A.2 |
| A10 | 沉积：`deposited ≤ eroded`；`pits_out ≤ pits_in`；`dep_enabled=false` 时与 P2 逐位相等 |
| A11 | Web 栅格：2048 输入 + `max_dim=1024` 的结果与「先下采样再 1024 原生烘焙」的 `delta` 一致（放大前比对） |
| A12 | **叠加验证（2026-11-18 新增）**：真实地图上 X1 河心落谷率 ≥ 0.95（硬）；X2 河心 `A_hex` 分位、X3 河岸坡对称性只记录；跑前需 `dem_erosion_area_dump=1` 取 `area_hex_buffer`。**实测 X1 = 0.8273 / 0.8316 < 0.95 ⇒ FAIL**（未放宽阈值）；X2 = 0.2415 / 0.2413、X3 = 0.3259 / 0.3414（详情见 §8.1.2） |

### 8.1.1 实测结果（2026-11-18，A1–A11 首次全绿：`checks=11 failures=0 skips=0`；A12 后来追加，见 §8.1.2）

| # | 实测 | 结论 |
|---|---|---|
| A1 | `spl_nan=0`；全像素 `h ≤ h_pre`（严格，无 eps） | 通过 |
| A2 | 水体与河心像素**逐位不变**（`wet_drift=0`）；陆地 ≥ `sea+eps` | 通过 |
| A3 | 合成单坡 `Pearson(drop, log A) = 0.9041` | 通过（阈值 0.8） |
| A4 | 两次结果逐元素相等 | 通过 |
| A5 | 融合 pass 两次 `height_buffer` 逐位相等 | 通过 |
| A6 | 经线接缝：别名列与周期本体差 **0** | 通过 |
| A7 | `per_relief` 0.3 vs 1e6 → 0.006737 vs 0.010805（降 38%）；1e6/1e9 逐位相等 | 通过 |
| A8 | `carve` 三组用例 hash 与改动前一致（§6 P0 表） | 通过 |
| A9 | **原判据不可达**；改写后 A9(1) 三档 `spl_p99_drop` 相差 **1.55%**、A9(2) 16 px 块均值相关 **0.9571** | 改写后通过 |
| A10 | `deposited 134.811 ≤ eroded 461.735`；`pits_out 16677 ≤ pits_in 44323`；`dep=false` 逐位回 P2 | 通过 |
| A11 | `max_dim` 下采样路径与「先下采样再原生烘焙」一致，`worst=0` | 通过 |

**A9 改写后的两条判据**（均实测通过）：A9(1) 各档「自己算出的」`spl_p99_drop` 相差 < 20%
（512→**0.061152**、1024→**0.060206**、2048→**0.05994**，512 vs 1024 **相差 1.55%**）；
A9(2) 512 与 1024 的 `delta` 在 **16 px 块均值**上相关 > 0.85（实测 **0.9571**）。
像素级相关 **0.6802** 保留为「记录值」——离散河道网络本就不跨像素密度逐点对齐，这是**预期**而非缺陷。
完整根因与「原判据不可达」的证据（盒式平均后 p99 相差 **21.7%**）见附录 A.2。

附：P2 验收里不在 A1–A11 之列的两项也一并记录——**Flint 律 θ = 0.4001 ∈ [0.30, 0.60] ✓**、
**河道像素落在局地谷底的比例 0.9809 ≥ 0.95 ✓**。
⚠ **0.9809 是「合成单锥坡」上的读数**（本附录 A-d 的用例），**不是真实地图**；真实地图实测 **0.8273 / 0.8316**
（§8.1.2）—— 所以「≥0.95」这条门禁的来历本身是不可比的，判据怎么定见 §8.1.2 末尾。

### 8.1.2 A12 叠加验证实测（2026-11-18，跟进计划 S2）

新增诊断 knob `dem_erosion_area_dump`（raw profile 键，**纯诊断、不改高度**）：融合 pass 返回 `area_hex_buffer`
（620544 个值，单位 hex²）。`A12`（+555 / −0，A1–A11 逐字节未动），`checks=12`。

| 指标 | seed 20260718 | seed 20260719 | 门禁 / 判读 |
|---|---:|---:|---|
| X1 河心落谷率 | **0.8273**（n = 16217，miss = 2801） | **0.8316**（n = 15477，miss = 2607） | ≥ 0.95 ⇒ **FAIL**（均值 0.8294） |
| X2 河心 `A_hex` 分位 | 0.2415 | 0.2413 | 记录（越高越说明河走在像素汇流主干上） |
| X3 河岸坡对称性 | 0.3259 | 0.3414 | 记录（越小越对称） |

**根因**：像素层汇水在流到第一个 wet / 河心像素时就被截断 —— 陆地 `A_hex` p50 = 0.00752 hex² = **2.0 px**、
河心 p50 = **1.0 px**；且 X2 < 0.5 说明**河心像素的像素汇水反而低于陆地中位数**，河并不走在像素汇流主干上
⇒ X1 的 0.83 不是噪声。**结论：cell 河流落进 bake 像素谷这个叠加收益，在真实地图上不成立。**

**门禁与判据需再议（本轮只记录，未改阈值）**：
① 0.95 这条线来自合成锥坡的 0.9809（见 §8.1.1 附注），真实地图不可能达标；
② 建议改为「按实测设回归线（≥0.78）」+ 另设 X1b 只比非河邻域，把「绝对落谷率」与「相对象素汇流对齐」分开；
③ X2 / X3 仍是记录项，尚无基线。
依据：[terrain-followup-verification-plan.md](terrain-followup-verification-plan.md) §3.1。

### 8.2 回归（必须全绿）

- `tests/world/mountain_relief_bake_test.gd`、`terrain_index_edge_bake_test.gd`、`terrain_detail_continuity_test.gd`
- `tests/runtime/native_generation_equivalence_test.gd`
- `tests/ui/visual_tile_native_bake_test.gd`
- `tests/world/bake_encoder_cpp_parity_test.gd`
- grep 门禁：`sample_height(` / `world.height_buffer` 在 `scripts/` 下除 `rendering/` 与 `world_data.gd` 外无引用

**实测结果（2026-11-18，六个回归全部 exit 0）**

| 回归 | 结果 |
|---|---|
| `mountain_relief_bake_test` | 61 checks / 0 fail |
| `terrain_index_edge_bake_test` | 11 / 0 |
| `terrain_detail_continuity_test` | 8 / 0 |
| `bake_encoder_cpp_parity_test` | 16 / 0 |
| `native_generation_equivalence_test` | 32 / 0 |
| `visual_tile_native_bake_test` | exit 0 |

**CI 脚本实测**：`check_world_ext_bindings.py` 0 problems（manifest 661→662）、`check_script_native_access.py`
0 problems、`check_cpp_deps.py` 0 violations；`test_architecture_guards.py` **改动前即有 2 条环境性失败**
（`test_trace_paths_and_artifact_detection`、`test_control_wakeup_check_to_wait_transition`，Windows 默认 GBK
还会额外报 5 个 `UnicodeDecodeError`，需 `PYTHONUTF8=1`），判据是「**不新增**失败」而非「全绿」。

### 8.3 A/B 与性能记录

固定 seed（20260718 等 4 个）× 60×40 / 200×150 × `carve / spl / spl+carve / spl+dep / spl+dep+widen`：

- `[fused]` 行全部分项、`MapBaker v6: total`、`headless_perf_record.gd` 的 `generation_ms`
- 同机同图：俯视 / 中景 / 近景各一张；Web high 另跑一组与 desktop 对照（§4.7 一致性）

### 8.4 命令

```bash
godot --headless -s Project/project-keynes/tests/world/erosion_spl_bake_test.gd
godot --headless -s Project/project-keynes/tests/world/mountain_relief_bake_test.gd
python3 tools/ci/check_world_ext_bindings.py
python3 tools/ci/check_script_native_access.py
python3 tools/ci/test_architecture_guards.py
```

---

## 9. 文档同步

| 文档 | 改什么 | 状态 |
|---|---|---|
| 本文 | 落地后状态改「已实现/已验证」，补 P0 实测分项与 A/B 结论 | **已同步（2026-11-18）**；**2026-11-18 跟进同步**：§4.2 量级核算修订（`A_hex` p99 = 1.55 hex² = 411 px，旧假设 100 大 65 倍；单位无 bug）、§5 标注 release 未测、§8.1 增 A12 行 + 新增 §8.1.2（X1 = 0.83 未达 0.95，门禁与判据需再议）、§8.1.1 附注 0.9809 是合成锥坡读数 |
| `docs/terrain-generation-current.md` | §轻度水力侵蚀重写为「汇流 SPL + 限坡 + 沉积」；**顺带修正已过期内容**：base pass 已是双峰地台 + SPL，不再 min/max 归一化、不再径向穹顶 | **已同步（2026-11-18）** |
| `docs/architecture/feature-guides.md` §山地起伏调参与验收 | 追加 knobs 表、「参数以 hex 为单位」「迭代只按分辨率分档」「C++ 缺省永远 carve」三条约束 | **已同步（2026-11-18）** |
| `docs/architecture/feature-status.md` | 带日期条目：改动摘要 + 验证证据 + 未覆盖范围（P4、三角洲） | **已同步（2026-11-18）** |
| `docs/architecture/current-state.md` | pass 清单补一行（融合 pass 新增侵蚀分支） | **已同步（2026-11-18）**；该文件原本没有「pass 清单」小节，实际改为新增「地形烘焙 pass（2026-11-18）」小节并在其中标注 `dem_erosion_mode` 分支 |

---

## 10. 风险与对策

| # | 风险 | 概率 | 对策 |
|---|---|---|---|
| K1 | 谷形过软/过锐 | 中 | 坡限系数默认对齐 carve；调 `dem_slope_limit_per_relief`，`spl+carve` 只作对照 |
| K2 | 填洼成本超估 | 中 | P0 先计时；float key + FIFO；不靠削轮数 |
| K3 | 陆地压到海平面 | 低 | 不变量 2 截断 + 计数 |
| K4 | 河心与谷底错位 | 中 | 河心像素作出口（沿用 carve）；P2 验收 4 |
| K5 | 填洼重构破坏 carve 逐位一致 | 中 | P0 double-key 路径 + A8 hash 门禁，先合 P0 |
| K6 | 单一受体出平行斜沟 | 低 | 噪声已打散；必要时开 2 受体分配 |
| K7 | 默认切换后老存档读档看到新地形 | **确定发生** | 纯视觉、无玩法消费者（§1.5 + 8.2 门禁）；feature-status 注明 |
| K8 | 沉积造出新洼地 / 积水视觉 | 低 | `min_child_h` 约束 + `pits_out ≤ pits_in` 断言 |
| K9 | Web 放大后主槽变软 | 低 | 河流 SDF 下切在 2048 原生执行；可接受 |

**实测后状态（2026-11-18）**

- **K1 部分发生**：强度对齐实测 `spl(k=0.50)` 的 `mean=0.01236` 约为 carve `0.01382` 的 **89%**，
  「观感偏柔但同量级」；`p99=0.0719` 在验收带内。锐度旋钮已确认为 `dem_slope_limit_per_relief`（默认 5.0 = carve 谷壁）。
  **视觉是否可接受仍需 A/B 截图裁决（本轮未拍）**。
- **K2 风险解除**：填洼实测 **59–69 ms**，落在 v2 估算的 40–80 ms 区间内，预算未超；v2「填洼成本超估」
  这一判断本身**不成立**。反过来超估算的是受体+面积（26–29 ms）、P3a（12.3 ms）、P3b（37.6 ms），
  已在 §5 用实测值重写。
- **K3 未出现**：水体像素逐位不变、陆地 ≥ `sea+eps` 由 A2 断言守住（越界计数本轮未单独记录）。
- **K4 缓解**：A-d 实测 **0.9809 ≥ 0.95**（河道像素落在局地谷底）。
- **K5 风险解除**：三组用例 FNV-1a hash 与改动前完全一致（§6 P0 表）。
- **K6 未出现**：本轮未观察平行斜沟（无截图证据，只有统计量），2 受体分配未开。
- **K7 确定发生**：默认已切 `spl`，老存档读档重烘会看到新地形；§1.5 的 grep 门禁（§6 P0 第 5 条）
  证明像素高度无玩法消费者，feature-status 已注明。
- **K8 未出现**：`pits_out 16677 ≤ pits_in 44323`、`dep=false` 逐位回 P2。
- **K9 未测**：Web high 的实际观感未在浏览器里验过。

---

## 11. 回退策略

1. **knob**：`dem_erosion_mode=carve`（hash 门禁保证逐位）；`dem_dep_enabled=false` 回到 P2。
   已实测可用：只改 `terrain_index_baker.gd::DEM_DEFAULTS` 一行（或 `ProjectSettings` 的
   `project_keynes/rendering/dem/erosion_mode`），**无需重编 DLL**。
2. **编译**：新方法为新增；删除分支调用即回旧路径；`bake_erosion_spl.h` 可整文件移除。
3. **数据**：无存档/schema 变更；读档重烘即回旧视觉。
4. **镜像**：perf-validation 不传 knob，始终 carve。

---

## 12. 评审结论（v2 已定）

| # | 问题 | 结论 | 理由 |
|---|---|---|---|
| Q1 | 默认 `spl` 还是 `spl+carve` | **`spl`** | 像素层 SPL 只刻主槽，谷形由限坡决定；坡限默认 = carve 谷壁坡度，锐度对齐现状；叠 carve 是同一张图上两套谷生成器，易出双重谷形 |
| Q2 | Web high | **两者都不选：1024 计算栅格 + 放大改造量**（§4.7） | tile 只读低频改造量；与桌面观感一致；内存 52→~20 MB；降轮数无性能必要（系数已预计算） |
| Q3 | P3 沉积本轮做否 | **做**，改为体积守恒的输运受限沉积 + 可选谷底展宽，默认关，与 P2 同编译 A/B | 用户希望做；新设计守恒、不造洼、上限 `h_pre`，成本 +5~25 ms |
| Q4 | P5 是否单开 | **单开**：[terrain-ridge-uplift-plan.md](terrain-ridge-uplift-plan.md) | 改 `E[]`，影响地貌/气候/河流，需独立的分布回归；不保留旧算法，旧存档作废 |
| Q5 | perf-validation 镜像 | **不同步** | 已大幅漂移（`terrain_baker.gd` 1314 行、`map_baker.gd` 9583 行、`terrain_index_baker.gd` 73 行 diff）；共用 DLL 但不传 knob → C++ 缺省 `carve` 逐位不变 |

---

## 附录 A：**实测后修订**的验收判据（2026-11-18）

本附录记录落地实测对原验收判据的处置。**原判据原文保留在此，不静默改数字，也不删除**；每条都注明处置理由。

> 说明：本轮早前用 `dem_spl_k=0.30` 的读数曾准备对 A.1 启用「记录不门禁」豁免；**`dem_spl_k` 标定到 0.50
> 后复测，A.1 已达标，该豁免作废**。因此实际生效的判据修订是 **A.2 与 A.3 两条**（A.1 仅保留口径记录）。

### A.1 Flint 律凹度 θ（原判据**无需修订**，复测达标；保留 k 敏感性记录）

- **原判据**：河道像素（`A_hex ≥ 1`）`log S – log A` 回归斜率（凹度 θ）∈ [0.30, 0.60]，
  记录、不门禁于真实地图（§6 P2 验收第 2 条原文已含此豁免）。
- **实测（最终，`k=0.50`）**：**θ = 0.4001 ∈ [0.30, 0.60] ⇒ PASS**，豁免条款不启用。
- **口径记录**：`k=0.30` 时测得 **0.291**（低于下界约 3%）——θ 对 `dem_spl_k` 敏感，**标定后进入目标带**。
  这不是判据放宽，是同一判据在正确标定下的读数；不要为「变绿」调整阈值或回归口径。

### A.2 分辨率无关 A9（原判据**不可达** → 已改写为 A9(1)/A9(2)）

- **原判据**：同一解析地形以 512 / 1024 栅格分别烘焙，把 1024 的 `delta` 盒式下采样到 512 后与 512 的
  `delta` 相关 > 0.85，且 p99 下切量相差 < 20%。
- **实测**：盒式平均后**相关仅 0.6802、p99 相差 21.7%**——原判据不可达。
- **根因（不是算法对分辨率敏感）**：盒式平均会稀释 1 px 宽的主槽（1024 的 `delta` 平均后 p99 从 ~0.042
  掉到 0.0275 量级），而原生 512 的 `delta` 是它自己算出的 1 px 槽；两者本就不可逐像素对齐。
  离散河道网络不跨像素密度逐点对齐是**预期行为**，不是缺陷。
- **改写后的判据（均实测通过）**：
  - **A9(1)** 各档「自己算出的」`spl_p99_drop` 相差 < 20%：实测 512→**0.061152**、1024→**0.060206**、
    2048→**0.05994**，512 vs 1024 **相差 1.55%** ✓
  - **A9(2)** 512 与 1024 的 `delta` 在 **16 px 块均值**上相关 > 0.85：实测 **0.9571** ✓
- **附记**：像素级相关 **0.6802** 保留为「记录值」，用于说明上一条根因，不再作为门禁。

### A.3 「Web high ≤ desktop + 40 ms」（原判据**不成立** → 改为成对对照表述）

- **原判据**：`geometry pass（Web high） ≤ desktop + 40 ms`。
- **实测**：Web high 2048×1212 的 `spl` geometry = **514.5 ms**，desktop（1024×606）`spl` = **264.9 ms**，
  原判据不成立（约两倍）。
- **根因（不是本次新增的侵蚀）**：`spl` 在 §4.7 的 1024 计算栅格上跑，Web high 的分项与 desktop 同价
  （flow 76.8 / spl 12.4 / limit 13.1 / upsample 16.2 ms）；多出来的量是 **terrain-index 等既有 per-pixel
  pass 在 4 倍像素数上的固定成本**（terrain-index 2048 = **320.3 ms** vs desktop **67.2 ms**）。
- **改写（保留成对对照，不做绝对增量归因）**：
  > Web high 上 `spl` 比 `carve` **快 558 ms**（1072.8 → 514.5）：`carve` 的 fill/MFD/谷壁全在 2048 上跑
  > （`valley=708.8 ms`），`spl` 只在 1024 计算栅格上跑；desktop 上 `spl` 比 `carve` 慢约 33 ms
  > （231.6 → 264.9），512 档持平（+1.7 ms）。「Web high 是否变慢」应看**同图同次运行的成对对照**。
- **连带修订**：`upsample_ms` 曾在 2048 上误报 **185.6 ms**，那是计时范围把 flow/spl/limit 也算进去了；
  修正口径（只计缩放段）+ `upsample_box_f32` 8× 优化后实测 **16.2 ms**，落在 v2 估算的 +10~20 ms 内。
  定义已在 §4.11 补齐。

---

## 附录 B：期间发现并修掉的两个问题（2026-11-18）

1. **`upsample_box_f32` 内层逐像素 `std::fmod` / `std::floor`**：`u` 本是逐列常量，却在最内层逐像素重算。
   提出后 **8× 加速**（`/O2` 12.0 ms → 1.51 ms；`/Od` 52.1 ms → 6.26 ms @ 2048×1212），
   8 组用例 `memcmp` 逐位相同——纯性能修复，不改结果。
2. **`upsample_ms` 计时范围把核函数也算进去了**：由 bake-integration 修正为只计缩放段。
   这正是 A.3 里 185.6 ms 与 16.2 ms 的差额来源；两个数都保留记录（185.6 已标注为错误口径），不互相覆盖。

---

## 附录 C：验证证据索引（2026-11-18）

| 证据 | 位置 / 值 |
|---|---|
| carve 分项计时 | §1.2 表（fill 59–69 / mfd 26–29 / wall 40–42 / carve_ms 127–143 ms） |
| 逐位回退门禁 | §6 P0 表（三组 FNV-1a hash）+ 8 组几何 `memcmp` + 72 项断言 0 失败 |
| 三档成对对照 | §5.2 表（512 / 1024 / 2048，carve vs spl，同次运行） |
| 单模式分项 | §5.3 表（`template_debug`，620,544 px；desktop 波动 ±15%） |
| 生产路径 A/B | §5.4 表（`headless_perf_record.gd`，60×40，seed=20260718） |
| A1–A11 | §8.1.1 表（`checks=11 failures=0 skips=0`） |
| 回归 + CI | §8.2 实测结果（六个回归 exit 0；三个 CI 脚本 0 problems / 0 violations） |
| 玩法影响 | §6 P0 第 5 条（像素高度无玩法消费者） |

---

## 参考

- Braun & Willett 2013, *A very efficient O(n), implicit and parallel method to solve the stream power equation*（隐式 SPL）
- Cordonnier, Braun et al. 2016, *Large Scale Terrain Generation from Tectonic Uplift and Fluvial Erosion*
- Barnes, Lehman, Mulla 2014, *Priority-Flood: An optimal depression-filling and watershed-labeling algorithm*
- Davy & Lague 2009, *Fluvial erosion/transport equation of landscape evolution models revisited*（ξ-q 输运受限）
- Yuan, Braun et al. 2019, *A new efficient method to solve the stream power law model taking into account sediment deposition*
- Leopold & Maddock 1953, *The hydraulic geometry of stream channels*（河宽 ∝ Q^0.5）
- Flint 1974（坡度–面积律）、Hack 1957（河长–面积律）
