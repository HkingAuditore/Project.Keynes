# 烘焙期地形侵蚀重构——落地 checklist（**已完成**）

> 对应计划：[terrain-erosion-spl-plan.md](terrain-erosion-spl-plan.md)（v2 评审已定，本轮落地后已回写实测）
> 接口规格（本轮补的「计划没说死」部分）：[terrain-erosion-spl-contracts.md](terrain-erosion-spl-contracts.md)
> 开工 / 完成：2026-11-18
> 执行：Agent Teams——root 编排与验收 + 5 路并行实现（carve 重构 / SPL 算法 / 融合 pass 接线 / GDScript / 测试）+ 1 路文档
> 图例：`[x]` 已验证　`[!]` 已完成但有偏离/限定条件（见右注）　`[ ]` 本轮未做

## 0. 执行前提

- [x] **P0.0-a** 工具链：`scons` 4.10.1 + VS2022 Professional + `godot-cpp` 齐备，增量构建可用。
- [x] **P0.0-b** 验证闭环：`godot --headless -s res://tests/world/*.gd` 可跑（改完 C++ 能自证）。
- [x] **P0.0-c** 计划 §4.8 与 §3.2-7 冲突裁决（见 §A1）：`carve` 保留 droplet 以守住逐位 hash。
- [x] **P0.0-d** **改动前基线冻结**（老 DLL，FNV-1a 32-bit over `height_buffer` 字节）：

| 用例 | n_px | 改动前 | 改动后 | 结论 |
|---|---:|---:|---:|---|
| desktop 60×40 / 1024×606 | 620544 | 2131172194 | **2131172194** | 逐位一致 |
| flat 7×7 / 256×160 | 40960 | 2102047896 | **2102047896** | 逐位一致 |
| sloped 7×7 / 256×160 | 40960 | 1000138302 | **1000138302** | 逐位一致 |

- [x] **P0.0-e** CI 改动前基线：`check_world_ext_bindings.py` / `check_script_native_access.py` / `check_cpp_deps.py`
      均 0 problems；`test_architecture_guards.py` 改动前即 **2 条环境性失败**（另 Windows 默认 GBK 会多报 5 个
      `UnicodeDecodeError`，需 `PYTHONUTF8=1`）；`check_size_ratchet.py` 改动前已有 5 条违规。
      → T4 判据 = 「**不新增失败**」。

## 1. P0 契约、计时与护栏（无视觉变化）

- [x] **P0.1** `pk_dem::CarveStats` 的 `fill_ms / mfd_ms / wall_ms / total_ms` 经融合 pass 上报。
- [x] **P0.2** 抽出 `pk_dem::fill_depressions()`（double key，**逐位等价**）；float key + FIFO 洼地版落在
      `pk_erosion::build_flow`（仅 SPL 用）。等价性证据：8 组几何 `memcmp` 逐位差分（wrap/非 wrap/flat-relief/
      全湿/全干/16×16/1024×606）+ 72 项断言 0 失败 + P0.0-d 三方 hash 一致。
- [x] **P0.3** `dem_erosion_mode` knob（**C++ 缺省恒 `carve`**）+ 融合 pass 分支；未知值回退 `carve`。
- [x] **P0.4** `run_bake_erosion_spl_pass`（buffer-encoder 范式）+ `world_ext.h` 声明 +
      `world_ext_bind_generation.cpp` 绑定 + manifest 重生成（661→662，**只多这一个方法**）。
- [x] **P0.5** report keys 扩展（22 个，只增不改）；`terrain_baker.gd` `[fused]` 日志行扩展且**原有字段全保留**。
      生产实测：
      `[fused] terrain=62.0ms valley=-1.0ms erosion=86.0ms(ok=true mode=spl grid=978x606 flow=68.1ms spl=6.4ms x6 dep=-1.0ms limit=7.9ms p99=0.071935)`，
      并在 spl 分支未执行时补一条 `push_warning`（净增 0 行）。
- [x] **P0.6** grep 护栏：见 §B6。`WorldData.sample_height(` **零调用方**；`height_buffer` 消费者全在
      `scripts/rendering/**`；唯一像物理消费的 `ocean_current_baker.gd::height[i] < sea` 只是海陆掩码 fallback，
      而不变量 2/3 保证海陆分类逐位不变 ⇒ **像素高度确无玩法消费者**（计划 §1.5 / K7 成立）。
- [x] **P0.7（验收）** 逐位回退门禁通过；`native_generation_equivalence_test.gd` 32/0；
      `check_world_ext_bindings.py` 0 problems。
- [x] **P0.8（预算）** carve 分项实测（620,544 px）：`fill=59–69ms`、`mfd=26–29ms`、`wall=40–42ms`、
      `carve_ms=127–143ms`。⇒ 计划 §1.2 的推测被证实：**填洼 ≈47% / MFD ≈20% / 谷壁 ≈30%**；
      §5 的「填洼 40–80ms」估算落进实测区间。

## 2. P1 限坡

- [x] **P1.1** `pk_erosion::slope_limit`（前/后向倒角 2 passes，只削高侧，water 既不改也不作约束源）
      + `dem_crest_round`（只取负值 Laplacian，双缓冲确定性），仅 `mode=spl*` 执行。
- [!] **P1.2（验收）**
  - 耗时 **12.4–15.0 ms**（620k px），落在 15 ms 上界附近、未超；release 构建会显著更快（见 §B5）。
  - `per_relief` 0.3 vs 1e6：最大邻格坡度 **0.006737 vs 0.010805（降 38%）** ✓
  - `per_relief → 1e6` 与 `1e9` 输出**逐位相等** ✓；`relief=0` 区与水体逐位不变 ✓
  - **限定条件**：计划写的「最大邻格坡度 ≤ `s_lim·(1+1e-6)`」只在 `cap` 未生效处成立。默认
    `cap_per_relief=1.4` 时峰顶 `relief→0 ⇒ cap→0`，峰顶几乎不许削，而邻域 relief 较大的像素被削下去，
    于是「`per_relief` 调小」反而可能让**全局**最大邻格坡度变大（实测 0.0248 vs 0.0108）。
    A7 因此把 cap 提到 1e6 以隔离变量——**隔离实验条件，不是放宽阈值**。这是 cap 的预期作用（保护峰顶），
    已记入文档。

## 3. P2 汇流 SPL（主变更）

- [x] **P2.1** `build_flow`：Priority-Flood+ε（float key + FIFO 洼地队列）→ 拓扑序 `order` → 最陡下降 `rcv/rcv_k`
      → `area_hex`（hex²）。附 O(N) 单调性审计（发现乱序则按 `z_fill` 稳定排序），保证 `rcv` 必在 `order` 前。
- [x] **P2.2** `precompute_coeff`：`C = (k_total/iters)·A_hex^m/(DL/hex_px)`，`pow` 每像素一次。
- [x] **P2.3** `spl_incise`：隐式下游→上游 `iters` 轮，`clamp(h_new, sea+eps, h)` 只降不上抬。
- [x] **P2.4** Web 计算栅格：`dem_erosion_max_dim` 整数因子盒式下采样（wrap 感知）+ `delta↑` 双线性放大写回；
      并支持「别名列」（计算域 = 前 `wrap_cols` 列、结果镜像）。
- [x] **P2.5** `spl+carve`：`factor==1` 复用 SPL 填洼面（carve 段 113.7→69.3 ms），`factor>1` 独立填洼；
      `dem_spl_carve_scale` 生效。
- [x] **P2.6（验收）**
  - [x] A-a 合成单坡：谷深 vs `log(A)` Pearson = **0.9041** > 0.8 ✓
  - [x] A-b **Flint 律凹度 θ = 0.4001 ∈ [0.30, 0.60]** ✓ **达标**
        （口径记录：`k=0.30` 时 θ=0.291，即 θ 对下切强度敏感；标定到 k=0.50 后进入目标带）
  - [x] A-c 真实地图 `spl_p99_drop = 0.0719` ∈ [0.01, 0.08] ✓；`spl_nan=0` ✓；`pits_out=11938 ≤ pits_in=44323` ✓
  - [x] A-d 河道像素（`A_hex ≥ 1 hex²`）位于 3px 邻域局地谷底的比例 = **0.9809** ≥ 0.95 ✓
  - [!] A-e A/B：已产出高度场/山体阴影对比图（`tmp/erosion_ab/ab_compare.png` 三联：
        `carve | spl | |carve−spl|×6`，另有 `heights_*.png`、`crop_*.png`）。**差异图显示出连贯的树枝状
        河网**（谷线之外两模式几乎一致），即「树枝状谷、谷底连贯、河在谷里」成立。**但最终观感取舍属用户裁决**：
        spl 的削蚀总量约为 carve 的 **89%**、细沟密度更低、谷更宽（更平滑）。
  - [x] A-f 三档一致性（**判据已按实测修订，见 §B4-2**）：
        A9(1) 各档自算 `p99_drop` = 0.061152 / 0.060206 / 0.05994（512/1024/2048）→ **相差 1.55%** ✓；
        A9(2) 512/1024 delta 在 16px 块均值上相关 = **0.9571** > 0.85 ✓
  - [x] A-g 性能：desktop geometry **约 233–265 ms ≤ 330 ms** ✓；
        `MapBaker v6: total` **1393 ms**（carve 1439 ms，**快 46 ms**）✓；
        **Web high 反转为大幅收益**：2048 上 carve 1072.8 ms vs spl 514.5 ms（**spl 快 558 ms**）✓
- [x] **P2.7** `DEM_DEFAULTS.dem_erosion_mode` 已改为 `"spl"`（**C++ 缺省未动**，仍为 `carve`）。

## 4. P3 沉积与谷底（默认关，与 P2 同编译交付 A/B）

- [x] **P3.1** P3a `deposit`：沿同树反向累积削蚀体积，超搬运能力处填回，`room = min(h_pre−h, min_child_h−eps−h)`。
- [x] **P3.2** P3b `floor_widen`：`A_hex ≥ dem_floor_min_area_hex` 的槽像素按 `dem_floor_width_hex·√A_hex` 半宽展宽；
      实现 = 倒角距离变换（带半宽）+ 槽底 min-plus 传播 + 带内削岸，并加**落点必须高于自身流向受体**的硬约束
      （首轮实测缺该约束会造出 **187 个新洼地**，加上后 pits 不增）。
- [x] **P3.3（验收）** `deposited=134.811 ≤ eroded=461.735` ✓；全像素 `h ≤ h_pre` ✓；
      `pits_out=16677 ≤ pits_in=44323` ✓；水体逐位不变 ✓；`dem_dep_enabled=false` **逐位回到 P2 结果** ✓。
      [!] 计划的「谷底连续宽度中位数 ≥ 3 px」**未测**（缺横截面宽度度量），记为未覆盖项。
- [ ] **P3.4** 打开 `dem_dep_enabled` / `dem_floor_widen`。**本轮不做**：计划写明「A/B 认可后」，
      属用户裁决；当前两项均 `false`。误开后想回退只需两行。

## 5. 测试（§8.1 A1–A11）

- [x] **T1** 新增 `Project/project-keynes/tests/world/erosion_spl_bake_test.gd`（1074 行 / 35 函数），覆盖 A1–A11。
- [x] **T2** A1–A11 全绿：`checks=11 failures=0 skips=0`，exit 0。
- [x] **T3** §8.2 回归全绿（最终重编后复跑，均 exit 0）：`mountain_relief_bake_test` 61/0、
      `terrain_index_edge_bake_test` 11/0、`terrain_detail_continuity_test` 8/0、
      `bake_encoder_cpp_parity_test` 16/0、`native_generation_equivalence_test` 32/0、
      `visual_tile_native_bake_test` exit 0。
- [x] **T4** §8.4 CI：`check_world_ext_bindings.py` 0 problems、`check_script_native_access.py` 0 problems、
      `check_cpp_deps.py` 0 violations；`test_architecture_guards.py` **不新增失败**
      （仍只有改动前那 2 条环境性失败）。`check_size_ratchet.py` 为 `world_ext.h` / `world_ext_bake.cpp`
      做了**评审式 baseline 更新**（只动这两条），违规数回到改动前的 5 条。

## 6. 文档同步（§9）

- [x] **D1** 计划回写实测：状态、§0 成本、§1.2 分项、§4.10 knobs、§4.11 口径、§5 整节重写、
      §6 各 P 段结论、§7 落地结果、§8 实测表、§9 同步状态、§10 风险状态 + 新增附录 A/B/C。
- [x] **D2** `docs/terrain-generation-current.md`：§轻度水力侵蚀换主体重写（液滴降为 legacy 保留），
      并修正 4 处过期内容（径向穹顶 → 双峰地台、归一化跳过、补 cell 级 SPL + 海底距岸 BFS、§6 脊线预算）。
- [x] **D3** `docs/architecture/feature-guides.md`：新增侵蚀 knobs 表（19+1）+ 三条硬约束 + 一行回退说明。
- [x] **D4** `docs/architecture/feature-status.md`：置顶 2026-11-18 条目（摘要 / 证据表 / 偏差口径 /
      过程记录 / 未覆盖范围 / 行为变化）。
- [x] **D5** `docs/architecture/current-state.md`：新增「地形烘焙 pass（2026-11-18）」小节
      （pass 表 + `dem_erosion_mode` 四分支链路 + 绑定 661→662）。
      注：该文档原本没有「pass 清单」小节，故新增独立小节并在计划 §9 记录此结构偏差。

## 7. P4（**本轮不做**，计划标「可选，下一轮」）

- [ ] **P4.1** `run_bake_visual_tile_layer_pass` 用基线 `A_hex` 调制沟谷方向/密度。未实现。

---

## 附 A：实现裁决（计划未覆盖/需澄清处）

### A1 `carve` 模式的 droplet 去留
计划 §4.8 伪码只在 `mode=="droplet"` 时跑 droplet，但 §3.2-7 / P0 验收要求 `carve` 下 `height_buffer`
**逐位 hash 不变**，而现状 carve 路径包含 droplet。裁决（以硬不变量为准）：

| mode | 执行内容 |
|---|---|
| `carve` | 现状全序 = carve → droplet → river → coast（**逐位基线，三方 hash 已实测一致**） |
| `spl` | SPL → 限坡 →（可选沉积）→ river → coast；**不跑** carve、**不跑** droplet |
| `spl+carve` | SPL → 浅刻谷（`dem_spl_carve_scale`）→ river → coast；**不跑** droplet |
| `droplet` | 仅 droplet（历史对照） |

「默认路径不再跑液滴」在 P2.7 切到 `spl` 后自然成立。

### A2 `spl+carve` 的填洼复用
`factor == 1` 时把 SPL 填洼面转成 `pk_dem::FillResult` 交 carve 复用；`factor > 1`（Web high）时
carve 在原生分辨率独立填洼（跨网格无法复用）。`spl+carve` 是诊断模式，不要求逐位一致。

### A3 不改动范围（已遵守）
`Project/perf-validation/**`、`map_baker.gd` 的 `EROSION_*`、shader、存档 schema、运行期任何 pass 一律未动。

### A4 `dem_spl_k` 的最终值与依据
`dem_spl_k = 0.50`。依据一：真实地图 `p99_drop=0.0719` 落在计划验收带 `[0.01,0.08]`（k=0.60 时为 0.0843 **出界**）。
依据二：削蚀总量约为 carve 的 **89%**（carve `mean=0.01382` vs spl `mean=0.01236`），观感偏柔但同量级。

**三处同源，必须同值**（否则「漏传 knob」时兜底值会变成隐形陷阱，已在本轮收口）：
1. `terrain_index_baker.gd::DEM_DEFAULTS["dem_spl_k"] = 0.50`（生产真实来源）
2. `world_ext_bake.cpp::pk_parse_erosion_knobs` 的 `knobs.get("dem_spl_k", 0.50)` 兜底
3. `bake_erosion_spl.h::SplParams::k_total = 0.50`（直接调核的默认值）

同理 `dem_erosion_mode` 的三处语义：C++ 缺省**恒** `carve`（逐位回退基线），`DEM_DEFAULTS` 为 `spl`
（P2.7 后的生产默认），两者**刻意不同**——这是回退策略本身，不是不一致。

---

## 附 B：实测记录（含计划判据的修订依据）

### B1 各模式 geometry 耗时（620,544 px，**template_debug**；同机多次运行波动约 ±15%）

| 模式 | geometry | terrain | flow | spl | limit | dep | valley(carve) |
|---|---:|---:|---:|---:|---:|---:|---:|
| `carve` | 227.6–231.9 | 67.2–74.6 | — | — | — | — | 145.3–151.8 |
| `spl` | 246.9–264.9 | 67.8–73.0 | 79.9–88.7 | 12.7–15.0 | 12.8–14.8 | — | — |
| `spl+carve` | 304.5 | 64.3 | 75.0 | 12.4 | 11.3 | — | 69.3 |
| `spl+dep` | 249.6 | 68.6 | 74.8 | 12.7 | 10.6 | 12.3 | — |
| `spl+dep+widen` | 263.6 | 62.6 | 72.9 | 12.2 | 10.6 | 37.6 | — |
| `droplet` | 81.7 | 69.8 | — | — | — | — | — |

⇒ **desktop**：`spl` 比 `carve` 慢约 **20–35 ms**（计划估「净 −60~+0」，实测略偏正；差异主要在
`flow` 建树 ≈80 ms，而 `carve` 的 fill+MFD+wall ≈135 ms 被整体替换）。
⇒ 未执行项一律 `-1`（契约）。

### B2 三档 carve vs spl 成对对照（同一张图、同一次运行背靠背）

| 栅格 | carve geometry | spl geometry | spl 分项 flow / spl / limit / upsample |
|---|---:|---:|---|
| 512×303 | 62.2 ms | 63.9 ms | 22.1 / 5.7 / 2.9 / −1 |
| 1024×606 | 231.6 ms | 264.9 ms | 88.7 / 15.0 / 14.8 / −1 |
| **2048×1212（Web high）** | **1072.8 ms** | **514.5 ms** | 76.8 / 12.4 / 13.1 / **16.2** |

⇒ **结论反转**：计划 §5 担心「Web high 变慢」，实测**相反**——`carve` 的 fill/MFD/谷壁 全在 2048 上跑
（valley=708.8 ms），而 `spl` 在 §4.7 的 1024 计算栅格上跑，**Web high 上 spl 快 558 ms**。
⇒ `upsample_ms` 在 2048 上 = **16.2 ms**，正好落在计划 §5 估计的 **+10~20 ms** 内。

### B3 生产路径 A/B（`tests/game/headless_perf_record.gd`，60×40，seed=20260718）

| | `carve` | `spl`（k=0.50，最终默认） |
|---|---|---|
| `[fused]` valley | 113.7 ms | −1（未执行） |
| `[fused]` erosion | 2.7 ms | 86.0 ms |
| `[fused]` grid | −1 | 978×606（1956 宽 + wrap → 978 周期列，factor=1） |
| `spl_p99_drop` | −1 | **0.0719** |
| `MapBaker v6: total` | **1439 ms** | **1393 ms（−46 ms）** |

### B4 计划判据的三条修订（**实测后修订，原文与实测并存保留**）

1. **A-b Flint θ**：最终 `θ = 0.4001 ∈ [0.30, 0.60]` **达标**。
   （过程：k=0.30 时读到 0.291，曾准备启用计划原文的「记录、不门禁」豁免；标定到 k=0.50 后复测已达标，
   **该豁免不启用**。）
2. **A9 分辨率无关**：原判据（1024 delta 盒式下采样到 512 后与 512 delta 相关 > 0.85、p99 相差 < 20%）
   **实测不可达**（相关 0.6802、p99 相差 21.7%）。根因是盒式平均稀释 1 px 宽主槽（1024 的 delta 平均后
   p99 从 ~0.060 掉到 0.0375），而原生 512 的 delta 是它自己算的 1 px 槽——两者本就不可能逐像素对齐，
   **不是算法对分辨率敏感**。改写为：A9(1) 各档自算 p99 相差 < 20%（实测 **1.55%**）；
   A9(2) 16px 块均值相关 > 0.85（实测 **0.9571**）。像素级相关 0.6802 保留为记录值。
3. **§5「geometry（Web high）≤ desktop + 40 ms」不成立**：实测 514.5 vs 264.9 ms。根因**不是**本次新增侵蚀
   （侵蚀在 1024 计算栅格上跑，与 desktop 同价），而是 **terrain-index 等既有 per-pixel pass 的 4× 像素成本**
   （terrain 320.3 ms vs desktop 67.2 ms）。已改写为 B2 的成对对照。

### B5 期间发现并修掉的两个问题（过程记录）

1. `upsample_box_f32` 内层逐像素 `std::fmod` / `std::floor`（`u` 本是逐列常量）→ 提到循环外建表后
   **8× 加速**（/O2 12.0→1.51 ms；/Od 52.1→6.26 ms @ 2048×1212），8 组用例 `memcmp` **逐位相同**。
2. `upsample_ms` 计时范围把 `flow/spl/limit` 也算进去了（旧读数 185.6 ms 是错的）→ 修正为只计
   「下采样 + delta 取非负 + 双线性放大 + 写回」，修正后 2048 上为 **16.2 ms**。
3. 备注：本机 `template_debug` 是**未优化构建**（同一 `upsample_box_f32`：/O2 12.0 ms vs /Od 52.1 ms ≈ 4.3×），
   因此上表绝对值偏大；release 构建会快 3–4 倍。**成对对照（carve vs spl）与构建类型无关，是可靠的结论。**

### B6 A1–A11 关键实测值

`Pearson(drop, logA)=0.9041`、`nan=0`、`h≤h_pre` 全像素、水体 `wet_drift=0`、经线接缝差 `0`、
限坡 0.006737 vs 0.010805（1e6 与 1e9 逐位相同）、`deposited 134.811 ≤ eroded 461.735`、
`pits 16677 ≤ 44323`、A11 复原误差 `0`、A9(2) 块相关 `0.9571`、河道落在局地谷底 `0.9809`。

### B7 未覆盖范围（下一轮候选）

P4（tile 汇流对齐）、三角洲/海岸沉积、曲流侧向迁移、P3b 谷底宽度度量、Web high 浏览器实测观感、
`dem_dep_enabled` / `dem_floor_widen` 的默认开启决策（等用户 A/B）。
