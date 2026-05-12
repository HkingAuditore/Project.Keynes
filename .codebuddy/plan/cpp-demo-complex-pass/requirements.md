# 需求文档 — C++/GDScript 通信契约·参考实现 Pass #3「复杂度上限探测器」

> **本计划是 `cpp-thermal-gradient-pass`（Pass #2 = `run_thermal_gradient_pass`）的内核升级。**
> Pass #2 已在 2026-05-12 跑通：60×40=2400 cells，C++ 15 µs / GDScript 359 µs，bit 一致；
> 真实地图温度场 + 海拔接入完成，Overlay 通道可见。
>
> Pass #3 的使命是在**完全保留** Pass #2 已搭建的全部基础设施（component / overlay mode /
> climate 开关 / baker / tick 调用点 / earth_like.tres 默认 true）之上，**仅替换内核算法**为
> 一个真正吃 CPU 的"迭代式各向异性扩散 + 多尺度风场近似"，让用户能用同一个 demo 通道
> **既看花纹、又压性能上限**。本计划完成后，团队就拥有了"通信链路 + 性能压测台"二合一
> 的完整工程基线，可以在此之上再次评估是否启动 climate Pass-A 修复。

---

## 引言

### 背景

Pass #1 + Pass #2 已经把"通信链路本身"打通到非常成熟的程度，但用户反馈了两个新的真实诉求：

1. **看不出花纹**：Pass #2 的算子是"4-邻一阶差分模长 × (1 + gain·elev)"，对于**连续光滑**的温度场（同一气候带相邻格几乎无温差），梯度几乎处处为低值，可视化结果"全图深蓝、零星亮点"——**这是物理真相，不是 bug**，但作为"展示通信跑通了"的视觉证据**说服力不够**。
2. **压不出上限**：Pass #2 在 60×40=2400 cells 下 C++ 端 15 µs，远未触及 cache / 分支预测 / 浮点流水线的真实上限；用户想要一个"**可调节复杂度旋钮**"来研究"在真实地图上跑到什么程度时 C++ 也会捉襟见肘"。

如果直接去做 climate Pass-A 修复，又会缺失"性能预算实测"这一前置数据。所以再做一个 Pass #3，**专门回应这两个诉求**。

### 标杆 Pass 的设计：把 `run_thermal_gradient_pass` 内核升级为"迭代式各向异性扩散 + 多尺度风场近似"

为每个 cell 计算一个**迭代演化**的派生量 `demo_thermal_gradient ∈ [0, 1]`，物理隐喻是
"**温度场在科氏偏向 + 地形阻尼下经过 N 步各向异性扩散后的稳态强度**" —— 视觉上会
出现卷动条带、山脉两侧温度分流、海陆边界锋面增强。

**伪代码（仍以 4-邻 grid 简化六边形拓扑作为参考实现，不追求物理严谨）**：

```
# 输入：CELL_TEMP[N], CELL_ELEVATION[N]
# 参数：iterations (默认 16, 范围 1..64)
#       kernel_radius (默认 2, 范围 1..5)
#       coriolis_strength (默认 0.5, 范围 -1..1)
#       terrain_drag (默认 0.6, 范围 0..1)
#       elevation_gain (沿用 Pass #2 既有参数, 默认 1.5)
#       normalize_k (沿用 Pass #2 既有参数, 默认 0.5)

# 工作缓冲：buf_a[N], buf_b[N]（两块乒乓 PackedFloat32Array，pass 内部分配/复用）
buf_a := CELL_TEMP[:]   # 初始化 = 输入温度场拷贝

for it in 0 .. iterations-1:
    src, dst := (buf_a, buf_b) if (it % 2 == 0) else (buf_b, buf_a)
    for each cell (x, y):
        # 1. (2*kernel_radius+1)² 邻居加权差分（高斯近似权重，clamp-to-edge）
        accum := 0
        weight_sum := 0
        for dy in -kernel_radius..kernel_radius:
          for dx in -kernel_radius..kernel_radius:
              nx := clamp(x+dx, 0, w-1)
              ny := clamp(y+dy, 0, h-1)
              w_ij := exp(-(dx*dx + dy*dy) * 0.5)   # 预计算表，inner loop 查表
              accum += src[ny*w + nx] * w_ij
              weight_sum += w_ij
        smooth := accum / weight_sum

        # 2. 各向异性梯度（Sobel 3×3，复用 src 已读邻居）
        gx := sobel_x(src, x, y, w, h)   # clamp-to-edge
        gy := sobel_y(src, x, y, w, h)

        # 3. 科氏偏向（绕中心轴扭转 gradient 向量 90°×coriolis_strength·sgn(y - h/2)）
        rot := coriolis_strength * sgn(y - h * 0.5)
        gx', gy' := rotate(gx, gy, rot)

        # 4. 地形阻尼（高地形阻尼大）
        elev := CELL_ELEVATION[y*w + x]
        damp := 1.0 - terrain_drag * elev

        # 5. 通量散度近似 = (gx' + gy')，以此驱动 src 演化
        flux := gx' + gy'
        next_val := smooth + flux * damp * 0.05    # 0.05 = 内置稳定步长

        dst[y*w + x] := next_val

# 末尾归一化到 [0, 1]，并按 Pass #2 的 (1 + elevation_gain·elev) * normalize_k 整形
last := buf_b if (iterations % 2 == 1) else buf_a
out_min, out_max := minmax(last)
denom := max(out_max - out_min, 1e-6)
for i in 0..N-1:
    norm := (last[i] - out_min) / denom
    elev := CELL_ELEVATION[i]
    CELL_DEMO_THERMAL_GRADIENT[i] := clamp(norm * (1 + elevation_gain * elev) * normalize_k, 0, 1)
```

**为什么选这个算法**：

| 性质 | Pass #2 (单步差分) | **Pass #3 (迭代扩散)** |
|---|---|---|
| 浮点运算量/cell | ~10 ops | (2r+1)² · iter 加权 + Sobel + 科氏 + 阻尼 ≈ **iter·(2r+1)²·6 ops** |
| 默认参数下/cell ops | ~10 | 16 · 25 · 6 ≈ **2400 ops** |
| 60×40 总 ops | 24 K | **5.76 M** |
| 算子是否依赖前 step | 否 | 是（前 step 输出 = 后 step 输入） |
| Cache 友好度 | 高（一次过） | 中（乒乓 buffer + 邻居 stencil） |
| 视觉花纹 | 低（梯度场低能） | 高（卷动 + 锋面增强） |
| 数值发散风险 | 零 | 低（步长 0.05 + clamp-to-edge + 末尾归一化兜底，但仍需 bit-equal 验证守住） |

**这个升级存在的全部目的**就是：在 Pass #2 已搭好的通信脚手架基础上，把内核算子放大到**两个数量级的 ops/cell**，用同一套 bit-equal bench 守住正确性，让用户能：

- 在 Inspector 里调 `iterations` / `kernel_radius` / `coriolis_strength` / `terrain_drag` 四个旋钮，**实时**观察 C++ 路径每帧耗时与花纹变化；
- 在 `tmp/bench_demo_complex.gd` 里跑 1024 / 4096 / 16384 三档网格 + 3 档迭代次数（4 / 16 / 64），看 C++ 与 GDScript 两条路径分别在哪里"撑不住"；
- 把"通信链路在真实业务复杂度下的 budget 表"沉淀进 §12.6 子模板，作为 climate Pass-A 修复决策的输入数据。

### 范围声明

#### 本计划**做什么**

- 在 C++ 侧 `DCWorldExt` 的现有 `run_thermal_gradient_pass(int grid_w, int grid_h, float elevation_gain, float normalize_k)` 内核**完全替换**为上述迭代式扩散算法；同时保留旧签名（保持 charter §12.6.2 引用不破，**旧两参数版本变成"快速路径，iterations=1, kernel_radius=1"内部转调**）
- 在 C++ 侧新增 `run_demo_complex_pass(int grid_w, int grid_h, int iterations, int kernel_radius, float coriolis_strength, float terrain_drag, float elevation_gain, float normalize_k)` 作为完整 8 参数入口
- 在 `ClimateProfile` 资源新增 4 个 `@export` 字段：`demo_complex_iterations: int`, `demo_complex_kernel_radius: int`, `demo_complex_coriolis_strength: float`, `demo_complex_terrain_drag: float`
- 在 GDScript 侧编写**对照实现** `demo_complex_pass_gdscript(...)` 与 C++ 版本逐位等价
- 在 `tmp/bench_demo_complex.gd` 新增 micro-bench：跑 (32×32, 64×64, 128×128) × (4, 16, 64) 共 9 组组合，每组打 C++ vs GDScript 耗时，并对最小一组（32×32 × 4 iter）做 bit-equal 验证
- 在 `scripts/main.gd` 的 `_run_demo_thermal_gradient_pass_if_enabled()` 调用点切换为新 8 参数入口；**每 tick 打印一次 C++ 路径耗时**（μs 级，沿用 `Time.get_ticks_usec()`），格式 `[demo_complex] tick=#N w=W h=H iter=I kr=R cpp=Tcpp µs out[min=mn max=mx mean=avg]`
- 在 `docs/performance-charter.md` §12.6 末尾追加 §12.6.6「内核升级到迭代扩散后的性能预算实测表」，把 bench 三档结果（数字）粘进来作为后续真实 pass 的预算参考

#### 本计划**不做什么**

- ❌ **不**新增 component（沿用 `CELL_DEMO_THERMAL_GRADIENT`）
- ❌ **不**新增 Overlay MODE（沿用 `MODE.DEMO_THERMAL_GRADIENT = 18`）
- ❌ **不**新增 baker / shader / legend 分支（视觉通道完全复用 Pass #2 已落地的）
- ❌ **不**新增 climate 开关（沿用 `demo_thermal_gradient_enabled`，新参数仅在该开关 ON 时生效）
- ❌ **不**触碰 climate Pass-A / weather / biome / 真实风场 / SLP / ψ
- ❌ **不**为 Pass #3 加 SIMD / 多线程（仍故意保持 scalar 单线程，只压"算法本身复杂度"，不压"硬件并行能力"）
- ❌ **不**改动 Pass #1 / Pass #2 已落地的 `run_temp_drift_pass` / `snapshot_f32` API
- ❌ **不**让升级后的算法影响任何真实游戏机制（仍然是 demo-only 字段）
- ❌ **不**升格 bench 工具为正式 helper 类（仍保留在 tmp/ 目录）

### 完成判据（"我做出了第三份最佳实践模板"的判定）

1. ✅ `run_demo_complex_pass` 在 C++ 端能正确读 `CELL_TEMP` 与 `CELL_ELEVATION`，按上述伪代码迭代 `iterations` 步，写 `CELL_DEMO_THERMAL_GRADIENT`
2. ✅ 旧的 `run_thermal_gradient_pass(w, h, gain, k)` 签名仍可用，**调用语义保持向后兼容**（行为退化为 iterations=1 + kernel_radius=1 的"轻量版"，且依然与 Pass #2 老 GDScript 对照实现 bit-equal——意味着 Pass #2 老 bench 仍 PASS）
3. ✅ 新 GDScript 对照 `demo_complex_pass_gdscript(...)` 与 C++ 路径在 32×32×4iter 输入下逐元素 bit-精确相等（或差异 ≤ 1e-6 兜底）
4. ✅ 在游戏里打开 main.tscn 运行游戏，每 tick 控制台打印 `[demo_complex] tick=#N ... cpp=... µs ...` 一行，且数值随 `iterations` / `kernel_radius` 调整呈预期单调变化
5. ✅ Overlay 通道选择"热梯度（demo）"时，**视觉花纹明显比 Pass #2 丰富**——肉眼可见卷动条带、山脉两侧分流、海陆锋面增强；放大 `iterations` 至 64 时花纹趋于稳态
6. ✅ `tmp/bench_demo_complex.gd` 跑通，在 (32×32, 64×64, 128×128) × (4, 16, 64) 九组组合下 C++ 路径全部 < 50 ms，且最小组 bit-equal 验证 PASS
7. ✅ `ClimateProfile.demo_thermal_gradient_enabled = false` 时，整条链路完全 no-op，不影响任何已有功能
8. ✅ `docs/performance-charter.md` §12.6.6 落地"九档实测表 + 单 tick 实测一行"
9. ✅ 整个迁移 + 验证 ≤ 4 小时完成（设计 2.5 小时，硬上限 4 小时）

---

## 需求

### 需求 1：C++ 端新增 `run_demo_complex_pass()` 入口 + 旧入口向后兼容

**用户故事**：作为引擎工程师，我希望有一个 8 参数的复杂迭代 pass 入口可以调，同时旧的 4 参数 `run_thermal_gradient_pass` 仍然能被 Pass #2 的老 bench 调用并 PASS，以便我能在不破坏既有验证的前提下，把通信链路压到接近真实业务复杂度的极限。

#### 验收标准

1. WHEN GDScript 端调用 `_ext.run_demo_complex_pass(w, h, iter, kr, coriolis, drag, gain, k)` THEN 系统 SHALL 在 C++ 内部读取 `CELL_TEMP` / `CELL_ELEVATION` 只读裸指针、`CELL_DEMO_THERMAL_GRADIENT` 写指针，按伪代码所述：(a) 分配 / 复用两块 `iter` 步乒乓缓冲；(b) 每步对每个 cell 做 (2kr+1)² 高斯加权 smooth + 3×3 Sobel 梯度 + 科氏旋转 + 地形阻尼 + 步长 0.05 演化；(c) 末尾按 (out − min) / (max − min) 归一化后乘 (1 + gain·elev) · k 并 clamp 到 [0,1]，整段写回输出 slot。
2. WHEN tight loop 内访问邻居 THEN 系统 SHALL 通过预先 `ptrw()`/`ptr()` 拿到的裸指针 + 整数索引 + clamp-to-edge，**禁止** Variant / set / get；高斯权重 SHALL 在外层一次性预计算成 `kernel[(2kr+1)²]` 表，inner loop 仅做查表乘加。
3. WHEN cell 处于 grid 边界 THEN 系统 SHALL 用 clamp-to-edge 处理（与 Pass #2 同语义），避免任何索引越界与"环绕"伪影。
4. WHEN `iterations < 1` 或 `iterations > 64` THEN 系统 SHALL 在入口处 clamp 到合法范围并 push_warning 一次（仅一次，不要每 tick 刷屏）；`kernel_radius < 1` / `> 5` 同样处理；`coriolis_strength` clamp 到 [-1, 1]，`terrain_drag` clamp 到 [0, 1]。
5. IF 任意必需 slot 未注册 / dtype 不对 / `w*h != arr.size()` THEN 系统 SHALL no-op 并 push_warning（沿用 Pass #2 既有诊断格式）。
6. WHEN 旧入口 `run_thermal_gradient_pass(w, h, gain, k)` 被调用 THEN 系统 SHALL 内部转调 `run_demo_complex_pass(w, h, /*iterations=*/1, /*kernel_radius=*/1, /*coriolis_strength=*/0.0, /*terrain_drag=*/0.0, gain, k)`；该 1-iter / kr=1 / coriolis=0 / drag=0 配置 SHALL 与 Pass #2 老算法**逐位等价**（即 Pass #2 老 bench 跑回去仍 PASS）。
7. WHEN 该方法在 `_bind_methods()` 中注册 THEN 系统 SHALL 通过 `ClassDB::bind_method` 暴露 `run_demo_complex_pass`，参数名为 `grid_w / grid_h / iterations / kernel_radius / coriolis_strength / terrain_drag / elevation_gain / normalize_k`。

---

### 需求 2：`ClimateProfile` 新增 4 个旋钮

**用户故事**：作为正在调试性能上限的玩家/开发者，我希望在 Inspector 里有 4 个可拖动的旋钮直接控制迭代步数 / 邻居半径 / 科氏强度 / 地形阻尼，并在运行时实时观察花纹与耗时变化，以便快速做"性能 vs 视觉"权衡。

#### 验收标准

1. WHEN `ClimateProfile` 资源被加载 THEN 它 SHALL 暴露：
   - `@export_range(1, 64, 1) var demo_complex_iterations: int = 16`
   - `@export_range(1, 5, 1) var demo_complex_kernel_radius: int = 2`
   - `@export_range(-1.0, 1.0, 0.05) var demo_complex_coriolis_strength: float = 0.5`
   - `@export_range(0.0, 1.0, 0.05) var demo_complex_terrain_drag: float = 0.6`
   - 4 个字段配套 doc-comment 简述物理隐喻与"调大 = 更慢但花纹更复杂"提示。
2. WHEN `ClimateProfile.demo_thermal_gradient_enabled = false` THEN 4 个新字段 SHALL 完全不生效（不读、不写、不调用 C++ pass）。
3. WHEN 4 个字段在运行时被外部脚本修改 THEN 下一次 tick SHALL 立即按新值跑（无需重启）。
4. WHEN `data/world/earth_like.tres` 被加载 THEN 它 SHALL **不**显式覆盖 4 个新字段（保持 ClimateProfile 默认值），从而首次启动直接跑默认参数。

---

### 需求 3：GDScript 对照实现 + bench 三档验证

**用户故事**：作为质量负责人，我希望能继续用 30 秒的 bench 一次性验证 Pass #3 的 C++ 实现与 GDScript 参考实现 bit 级一致，并同时拿到 9 组性能对照数字。

#### 验收标准

1. WHEN 运行 `tmp/bench_demo_complex.gd` THEN 系统 SHALL 执行以下流程：
   - 创建 DCWorldExt 实例并注册 `CELL_TEMP` / `CELL_ELEVATION` / `CELL_DEMO_THERMAL_GRADIENT` 三个 slot
   - 用与 Pass #2 bench 完全一致的输入构造（线性温度梯度 + 余弦扰动 + 确定性伪随机 elevation）
   - **bit-equal 验证组**：网格 32×32，iter=4，kr=2，coriolis=0.5，drag=0.6，gain=1.5，k=0.5；C++ 路径与 GDScript `demo_complex_pass_gdscript` 路径分别跑一次，逐元素比对，差异 > 1e-6 视为 FAIL（打印失败索引和双方值，但不崩溃）
   - **性能对照组**：网格 ∈ {32×32, 64×64, 128×128} × iter ∈ {4, 16, 64}，kr=2 固定，每组各跑 1 次 C++ + 1 次 GDScript，记录 `Time.get_ticks_usec()` 开销
2. WHEN bit-equal 验证通过 THEN 脚本 SHALL 在控制台打印 `[bench_demo_complex] BIT-EQUAL PASS — 32x32, iter=4, max_abs_diff=...`。
3. WHEN 9 组性能对照跑完 THEN 脚本 SHALL 打印一张 ASCII 表，列：`grid | iter | kr | C++ µs | GDScript µs | speedup`；并在表末追加一行 `→ projected at game-grid (60x40, iter=16, kr=2): C++ ~ X µs (interpolated)`。
4. WHEN 任意 C++ 组耗时 > 50 ms THEN 脚本 SHALL push_warning 但不中断（让用户看完所有 9 组数字）。
5. WHEN bench 脚本被定义 THEN 它 SHALL 完全不依赖游戏主流程，可在 Godot Editor 直接 `Run`。
6. WHEN bench 脚本结束 THEN 它 SHALL 末尾打印一行 `[bench_demo_complex] DONE — bit-equal=PASS|FAIL, 9 perf rows logged`。

---

### 需求 4：主流程接入 + 每 tick 耗时打印

**用户故事**：作为正在做性能上限研究的开发者，我希望每个游戏 tick 都跑一次新算法，且控制台每 tick 都吐一行包含 C++ 耗时 + 输出统计的紧凑诊断，以便我在玩游戏时实时感知"再加一层迭代是不是太重了"。

#### 验收标准

1. WHEN 主流程的每日 tick 在 climate pass 完成后调用 `_run_demo_thermal_gradient_pass_if_enabled()` THEN 该函数 SHALL 改为调用新 8 参数入口 `_ext.run_demo_complex_pass(w, h, iter, kr, coriolis, drag, gain, k)`，参数全部从 `ClimateProfile` 读取（开关关闭时 4 个新字段也读不到则使用 C++ 默认值）。
2. WHEN 该 pass 执行 THEN GDScript 侧 SHALL 在调用前后包 `Time.get_ticks_usec()` 并打印一行紧凑诊断：`[demo_complex] tick=#N w=W h=H iter=I kr=R coriolis=C drag=D cpp=Tcpp µs out[min=mn max=mx mean=avg]`，其中 tick=#N 沿用现有的 daily tick 计数（若不存在则用单调递增计数）。
3. WHEN 该开关 ON 但首个 tick 触发时 THEN 系统 SHALL 在第一行额外打印 `[demo_complex] first run OK — input temp[...] elevation[...]` 一次（沿用 Pass #2 既有 `_demo_tg_first_run_logged` 守门变量）。
4. WHEN 该开关 OFF THEN 系统 SHALL 完全跳过 pass、跳过打印（与 Pass #2 一致）。
5. IF C++ 路径单 tick 耗时 > 16 ms（即明显影响 60 FPS 帧预算） THEN 系统 SHALL 仅在第 1 次发生时 push_warning 一次提示"参数过激，建议下调 iterations"，**不**每 tick 刷屏。
6. WHEN 用户在运行时通过 Inspector 修改 4 个旋钮 THEN 下一 tick 的诊断行 SHALL 立即反映新参数与新耗时。

---

### 需求 5：`performance-charter.md` §12.6.6 实测表落地

**用户故事**：作为之后所有真实 pass 迁移的执行者，我希望有一份"在真实业务复杂度下，C++ 单线程能跑到多少"的实测预算表，作为 climate Pass-A 修复 / 真实风场 pass 设计的预算锚。

#### 验收标准

1. WHEN Pass #3 的 1~4 条需求全部完成 THEN `docs/performance-charter.md` §12.6 SHALL 新增 §12.6.6 子小节，标题为 "内核升级到迭代扩散后的性能预算实测（2026-05-12 修订）"。
2. WHEN 用户阅读 §12.6.6 THEN 该子小节 SHALL 包含：
   - §12.6.6.a 升级前后算子复杂度对比一句话表（Pass #2 ~10 ops/cell vs Pass #3 默认 ~2400 ops/cell）
   - §12.6.6.b bench 9 组实测表（直接从 `tmp/bench_demo_complex.gd` 输出粘贴，标注测试硬件 = 用户当前机器，禁止伪造数字）
   - §12.6.6.c 单 tick 游戏内实测一行（直接粘 `[demo_complex] tick=#1 ... cpp=... µs ...`）
   - §12.6.6.d "如何在真实 climate pass 设计时使用此表" 3 句话指导（按 ops/cell 估算 → 对照本表插值 → 留 2× 安全边）
3. WHEN §12.6.6 完成 THEN §12 入口索引 SHALL 增加一行链接，让读者能从 §12 入口直达 §12.6.6。
4. WHEN 表格写入 §12.6.6.b THEN 数字 SHALL 来自本计划实际产出的 bench（不是凭空构造的"应该这样"数字）；如果 bench 实测发现某档 > 50 ms，SHALL 如实记录并在第 4 列标注 `⚠ over budget`。

---

### 需求 6：完成判定与时间盒

**用户故事**：作为正在持续推进通信契约的开发者，我希望本计划有清晰的"做完了"信号和硬性时间上限。

#### 验收标准

1. WHEN 本计划全部完成 THEN 用户 SHALL 在游戏里就能调 4 个旋钮看到花纹与耗时实时变化，且 §12.6.6 实测表能直接用作 climate Pass-A 预算输入。
2. IF 本计划实际耗时超过 4 小时 THEN 计划 SHALL 立即停止，重新评估方向，**不**强行推进。
3. WHEN 本计划完成 THEN "完成判据"9 条铁标 SHALL 全部为 ✅。
4. WHEN 本计划完成 THEN 团队 SHALL **不**立即开始 climate Pass-A 修复——而是先让 Pass #1 / #2 / #3 三个模板"沉淀一晚"，第二天再启动新计划。

---

## 附录：与现有项目的衔接说明

- 本计划**完全不新增** component / Overlay MODE / climate 开关 / baker 分支 / shader 分支 / legend 分支 / map_data 字段 / world.gd bind 分支——所有这些都沿用 Pass #2 已落地的脚手架。这是有意为之的工程约束，目的是验证"通信链路一旦搭好，内核可以无痛升级 100×"。
- 本计划与 `physical-wind-ocean-circulation` plan 完全正交：那个 plan 的真实风场 pass 在 `cell.wind_*` 命名空间下，本计划仍在 `cell.demo.*` 命名空间，两者绝不冲突。
- 本计划完成后，**下一个计划**才是基于 §12.6.6 实测预算决策"是否启动 climate Pass-A 修复"——那是后续计划，不在本计划范围。
