# 需求文档 — C++/GDScript 通信契约·参考实现 Pass #2「温度梯度热应力场」

> **本计划是 `cpp-comm-reference-impl`（pass #1 = `temp_drift_pass`）的直接延伸。**  
> Pass #1 已在 2026-05-12 跑通：1024 cells × 3 passes，C++ 22 µs / GDScript 222 µs，bit-精确一致。  
> Pass #1 验证的是"通信契约本身"（C++ 写一个 component + GDScript 拉 snapshot），**算法极致最小化**（只有 +drift）。  
>
> Pass #2 的使命是把通信契约**放大到接近真实业务的复杂度**，但**仍然保持算法稳定不发散**。本计划完成后，团队就拥有了"从温度场派生新场 → 写入新 component → 接入 Data Overlay 渲染"这条**第二条通信链路**的完整模板，可以放心去碰真实的 climate pass 重构。

---

## 引言

### 背景

Pass #1 标杆产物覆盖了"读 1 个 component → 修改自身 → 写回"的最简通信路径，但还有几个真实业务里**几乎每个 pass 都会遇到的**复杂度，Pass #1 没有覆盖：

1. **多输入 SoA**：真实 pass 一般要同时读 2~5 个 component（如温度 + 海拔 + 纬度 + is_water + 邻居拓扑）。
2. **二维空间访问**：真实 pass 经常要访问"邻居 cell"的数据（梯度、扩散、对流）——这是把 1D 数组当成 2D 网格用，需要 `_grid_w / _grid_h` 这一对元数据从 GDScript 端传到 C++ 端。
3. **写入新 component**：真实 pass 一般会**派生**一个新字段并写入，而不是覆盖输入字段。Pass #1 是 in-place 修改 `cell.temp`，没有验证"新增 component slot + 写入"路径。
4. **接入 Data Overlay**：真实 pass 跑完得能在游戏里看到。Pass #1 的 bench 只在控制台打印数字，没有走真实的 `data_overlay_baker.gd` → `data_overlay.gdshader` 渲染链路。

如果在跳过这 4 条直接去做 climate Pass-A 修复，又会重蹈覆辙。所以再做一个标杆 pass，**专门把这 4 条复杂度一次性吃掉**。

### 标杆 Pass 的设计：`thermal_gradient_pass`

为每个 cell 计算一个 demo-only 派生量 `demo_thermal_gradient ∈ [0, 1]`，其物理隐喻是
"**温度场的局部梯度模长，被海拔放大**" —— 视觉上山区/海陆边界/锋面会发亮。

**伪代码（六边形邻居简化为 4-邻 grid 差分作为参考实现，不追求物理严谨）**：

```
for each cell (x, y):
    T  = cell_temp[x, y]
    Tn = cell_temp[x, y-1]   if y>0    else T
    Ts = cell_temp[x, y+1]   if y<h-1  else T
    Tw = cell_temp[x-1, y]   if x>0    else T
    Te = cell_temp[x+1, y]   if x<w-1  else T

    grad_x = (Te - Tw) * 0.5
    grad_y = (Ts - Tn) * 0.5
    grad_mag = sqrt(grad_x*grad_x + grad_y*grad_y)

    elevation = cell_elevation[x, y]      // [0, 1]
    amp = 1.0 + ELEVATION_GAIN * elevation // 默认 ELEVATION_GAIN = 1.5

    demo_thermal_gradient[x, y] = clamp(grad_mag * amp * NORMALIZE_K, 0.0, 1.0)
```

**为什么选这个算法**：

| 性质 | Pass #1 (drift) | **Pass #2 (thermal_gradient)** | 真实 climate pass |
|---|---|---|---|
| 输入 component 数 | 1 | **2**（CELL_TEMP, CELL_ELEVATION） | 3~6 |
| 输出 component 数 | 0（in-place） | **1 新增**（CELL_DEMO_THERMAL_GRADIENT） | 1~3 新增 |
| 是否需要邻居访问 | 否 | **是**（4-邻差分） | 通常是 |
| 是否需要 grid 维度 | 否 | **是**（W, H） | 是 |
| 是否需要在 Overlay 看见 | 否 | **是**（新增 MODE 通道） | 是 |
| 数学是否有发散风险 | 否（加法） | **否**（一阶差分 + clamp） | 经常有（PDE 迭代） |
| 与现有真实数据是否冲突 | 否 | **否**（demo-only 字段，独立命名空间） | — |

**这个算法存在的全部目的**就是：在保持"零发散风险"的前提下，把通信链路的真实业务复杂度（多输入 SoA + 邻居访问 + 写入新 component + 接入 Overlay）**一次性全部覆盖**。它不是为游戏增加 feature，而是产出 **"模式 B 在真实业务复杂度下的可复制模板代码"**。

### 范围声明

#### 本计划**做什么**

- 在 C++ 侧 `DCWorldExt` 新增 `run_thermal_gradient_pass(int grid_w, int grid_h, float elevation_gain, float normalize_k)` 方法
- 在 `DCComponentIds` 新增 `CELL_DEMO_THERMAL_GRADIENT` 一个 demo-only F32 component
- 在 `OverlayMode.MODE` 末尾新增 `DEMO_THERMAL_GRADIENT` 通道，并在 baker / shader / legend 三处补齐采样、色带、图例分支
- 在 GDScript 侧编写对照实现 `thermal_gradient_pass_gdscript()`
- 在 `tmp/bench_thermal_gradient.gd` 新增 micro-bench 验证：(a) C++ 与 GDScript bit-精确一致 (b) C++ 路径耗时 < 1 ms（典型 60×40 = 2400 cells）
- 在主流程的"每日 tick 完成 climate pass 之后"挂一个调用点（默认禁用，由 `ClimateProfile.demo_thermal_gradient_enabled` 开关控制，避免污染默认游戏行为）
- 把"如何用 Pass #2 模板做下一个 pass"的 7 步操作清单更新到 `docs/performance-charter.md` §12 的 §12.6 子小节（不是新章节，是 §12 的扩展）

#### 本计划**不做什么**

- ❌ **不**触碰 `physical-wind-ocean-circulation` plan 的真实风/SLP/ψ 系统（那是另一个独立计划，本计划与它**完全不重叠**）
- ❌ **不**修复 climate Pass-A 全蓝 bug（仍然推后）
- ❌ **不**让 `demo_thermal_gradient` 反过来影响任何真实游戏机制（biome / vegetation / weather 全部不读它）
- ❌ **不**为 `thermal_gradient_pass` 加 SIMD / 多线程（标杆故意保持 scalar，只压"通信契约"，不压"算力"）
- ❌ **不**改动 Pass #1 已落地的 `run_temp_drift_pass` / `snapshot_f32` API
- ❌ **不**升格 `flush_to_mapdata()` 为正式 helper 类（仍保留在 bench 文件里）

### 完成判据（"我做出了第二份最佳实践模板"的判定）

1. ✅ `run_thermal_gradient_pass` 在 C++ 端能正确读 `CELL_TEMP` 与 `CELL_ELEVATION`，写 `CELL_DEMO_THERMAL_GRADIENT`
2. ✅ GDScript 对照路径与 C++ 路径产出**逐元素 bit-精确相等**（一阶差分都是有限步加减乘 + sqrt 在 IEEE754 下确定性，bit 一致是可达的；如果实测 sqrt 精度不可达，降级为"误差 ≤ 1e-6 的近似一致"）
3. ✅ 在游戏里打开调试控制台 → Overlay 通道选择"热梯度（demo）" → 能看到一张温度梯度热力图，山区与海陆边界明显高亮
4. ✅ Pass #2 整段执行（pass + flush + bake）在 60×40 = 2400 cells 下 ≤ 2 ms（含 overlay bake，不含渲染）
5. ✅ `ClimateProfile.demo_thermal_gradient_enabled = false` 时，整条链路完全 no-op，不影响任何已有功能（含 climate / weather / biome / overlay 默认通道）
6. ✅ `docs/performance-charter.md` §12.6 子小节落地"用 Pass #2 模板做带邻居访问的下一个 pass"7 步清单
7. ✅ 整个迁移 + 验证 ≤ 4 小时完成（设计 2.5 小时，硬上限 4 小时）

---

## 需求

### 需求 1：C++ 端新增 `run_thermal_gradient_pass()` 入口

**用户故事**：作为引擎工程师，我希望有一个最小化、零发散风险的"多输入 SoA + 邻居访问 + 写新 component"的 C++ pass 入口，以便我能用它验证 Pass #1 没覆盖的通信复杂度。

#### 验收标准

1. WHEN GDScript 端调用 `_ext.run_thermal_gradient_pass(w, h, elevation_gain, normalize_k)` THEN 系统 SHALL 在 C++ 内部读取 `_slots[CELL_TEMP].arr_f32` 与 `_slots[CELL_ELEVATION].arr_f32`，按 4-邻一阶差分公式计算每个 cell 的 `grad_mag * (1 + elevation_gain * elevation) * normalize_k` 并 clamp 到 [0, 1]，结果写入 `_slots[CELL_DEMO_THERMAL_GRADIENT].arr_f32`。
2. WHEN tight loop 内访问邻居 THEN 系统 SHALL 通过预先 `ptrw()`/`ptr()` 拿到的裸指针 + 整数索引访问，**禁止**任何 Variant / set / get 调用。
3. WHEN cell 处于 grid 边界（x=0/x=w-1/y=0/y=h-1） THEN 系统 SHALL 用"自身值替代越界邻居"的方式处理（即 Neumann 边界 / clamp-to-edge），避免任何索引越界。
4. IF `CELL_TEMP` / `CELL_ELEVATION` / `CELL_DEMO_THERMAL_GRADIENT` 中任意一个 slot 未注册 THEN 系统 SHALL 安全 no-op 并返回（不崩溃，不抛异常，但 SHALL 通过 `UtilityFunctions::push_warning` 打印一次清晰的诊断信息）。
5. IF `w * h != _slots[CELL_TEMP].arr_f32.size()` THEN 系统 SHALL no-op 并 push_warning（防止 grid 维度对不上时静默写脏数据）。
6. WHEN 该方法在 `_bind_methods()` 中注册 THEN 系统 SHALL 让 GDScript 端通过 `_ext.run_thermal_gradient_pass(w, h, gain, k)` 直接调用。

---

### 需求 2：新增 demo-only component `CELL_DEMO_THERMAL_GRADIENT`

**用户故事**：作为架构纪律的守护者，我希望 Pass #2 的输出字段使用独立的 demo-only 命名空间，以便它永远不会被真实游戏机制误用，也永远不会污染存档。

#### 验收标准

1. WHEN `DCComponentIds` 文件被读取 THEN 文件 SHALL 在末尾新增 `const CELL_DEMO_THERMAL_GRADIENT: StringName = &"cell.demo.thermal_gradient"`，且通过命名前缀 `cell.demo.*` 与所有真实 component（`cell.temp`, `cell.wind_x` 等）形成清晰的命名空间分割。
2. WHEN World/DCWorldExt 启动并 `bind_map_data` THEN 系统 SHALL 仅在 `ClimateProfile.demo_thermal_gradient_enabled == true` 时才注册并分配该 slot；为 false 时 SHALL 完全不分配（节省 N×4 字节内存，等价 60×40 = 9.6 KB）。
3. WHEN `MapData` 被 reset 或重新 generate THEN 该 component 的 slot 内容 SHALL 被清零（与其他 climate slot 一致的语义）。
4. WHEN 存档保存 / 读取 THEN 该 component **不需要**进入存档（demo-only 字段，运行时重新计算即可）；存档代码若按现有"扫描全部已注册 slot"的方式自动覆盖了这一字段，可暂不专门排除，但 SHALL 在 doc-comment 中注明"此字段不应进入永久存档"。
5. WHEN 文档更新 THEN `data/README.md` 或 `scripts/data_core/component_ids.gd` 的 doc-comment SHALL 注明：`cell.demo.*` 是参考实现专用命名空间，禁止真实游戏机制读取或依赖。

---

### 需求 3：GDScript 对照实现 + bench 验证

**用户故事**：作为质量负责人，我希望能在 30 秒内验证 Pass #2 的 C++ 实现与 GDScript 参考实现 bit-精确一致，且跨界开销在预算内。

#### 验收标准

1. WHEN 运行 `tmp/bench_thermal_gradient.gd` THEN 系统 SHALL 执行以下流程：
   - 创建 DCWorldExt 实例并注册 CELL_TEMP / CELL_ELEVATION / CELL_DEMO_THERMAL_GRADIENT 三个 slot（容量 N = w * h，建议 w=60, h=40 与游戏一致）
   - 用一个有意构造的输入填充 CELL_TEMP（例如水平方向线性温度 + 一个余弦扰动）和 CELL_ELEVATION（例如随机[0,1]）
   - 调用 `_ext.run_thermal_gradient_pass(60, 40, 1.5, 0.5)` 一次
   - 通过 `snapshot_f32(CELL_DEMO_THERMAL_GRADIENT)` 拉回结果
   - 同样的输入/参数下调用 GDScript 对照实现 `thermal_gradient_pass_gdscript(...)`
   - 逐元素比对两条路径的输出
2. IF 任意元素差异 > 1e-6 THEN 脚本 SHALL 在控制台打印失败位置、C++ 值、GDScript 值，但**不崩溃**（让人看完所有失败再判断）。
3. WHEN 验证通过 THEN 脚本 SHALL 在控制台打印 `[bench_thermal_gradient] PASS — 60x40 cells, max_abs_diff=...`。
4. WHEN 脚本完毕 THEN 它 SHALL 同时打印两条路径的耗时（μs），并断言 C++ 路径 < 2 ms（仅 push_warning，不中断）。
5. WHEN bench 脚本被定义 THEN 它 SHALL 完全不依赖游戏主流程（不需要打开 main.tscn），可在 Godot Editor 直接 `Run`。

---

### 需求 4：Data Overlay 新增 `DEMO_THERMAL_GRADIENT` 通道

**用户故事**：作为开发者，我希望能在游戏运行时通过调试控制台的 Overlay 下拉菜单切换到"热梯度（demo）"通道，看到逐 cell 的派生数据可视化，以便直观验证 C++ pass 在真实地图上跑出来的形状是否合理。

#### 验收标准

1. WHEN `OverlayMode.MODE` 枚举被定义 THEN 它 SHALL 在末尾新增 `DEMO_THERMAL_GRADIENT = 18`（紧接现有最末项 `OCEAN_PSI = 17`）。
2. WHEN 三处 dictionary 被定义 THEN `DISPLAY_NAME[MODE.DEMO_THERMAL_GRADIENT] = "热梯度（demo）"`、`RANGE_LABEL[...] = ["0.00", "1.00"]`、`CATEGORY[...] = CATEGORY_KIND.CONTINUOUS`、`ordered_modes()` 末尾追加该 mode。
3. WHEN `data_overlay_baker.gd` 被调用且 `mode == MODE.DEMO_THERMAL_GRADIENT` THEN baker SHALL 直接采样 `cell.demo_thermal_gradient` 字段（或对应的 SoA `view_f32(CELL_DEMO_THERMAL_GRADIENT)`）写入数据纹理 R 通道，无任何二次缩放（值已在 [0,1]）。
4. WHEN `data_overlay.gdshader` 处理该 mode THEN 它 SHALL 复用现有"温度色带"或一条新增的"梯度色带"（蓝→白→红 / 黑→黄→白皆可，由 §12.6 模板自由选择，不强制），且 fallback 到 ramp_continuous 即可，无需新增 hue/value 编码分支。
5. WHEN `overlay_legend.gd` 显示该 mode THEN 它 SHALL 显示标题"热梯度（demo）"，色带方向与温度通道一致，两端标签 "0.00" / "1.00"。
6. IF `ClimateProfile.demo_thermal_gradient_enabled == false` 且 `cell.demo_thermal_gradient` 字段未填充 THEN baker 在采样到全 0 时 SHALL 仍然正常画图（全图最小值色），**不**崩溃也**不**push_error；UI 端 SHALL 在该开关关闭时**显式不向下拉菜单注入**这一项（避免误导）。

---

### 需求 5：主流程接入与 ClimateProfile 开关

**用户故事**：作为游戏运行时的负责人，我希望 Pass #2 默认完全关闭，只有显式打开开关才会跑，以便它永远不会在生产路径上引入隐藏耗时或副作用。

#### 验收标准

1. WHEN `ClimateProfile` 资源被加载 THEN 它 SHALL 暴露 `@export var demo_thermal_gradient_enabled: bool = false`（默认 false，配套 doc-comment 说明它属于"参考实现 demo 通道，仅用于通信契约验证"）。
2. WHEN 主流程的每日 tick 在 climate pass 全部完成后 THEN 系统 SHALL 检查该开关；若开 SHALL 调用 C++ 路径 `_ext.run_thermal_gradient_pass(map.width, map.height, gain, k)`；若关 SHALL 跳过整个 pass。
3. WHEN 该开关从 false 切换到 true（运行时） THEN 系统 SHALL 在下一次 tick 自动开始计算并填充字段（无需重启）。
4. WHEN 该开关从 true 切换到 false THEN 已存在的 `cell.demo_thermal_gradient` 数据 SHALL 保持原值（不主动清零），但 Overlay 下拉菜单 SHALL 立即把该项隐藏。
5. WHEN 该开关与 Overlay 的当前选择冲突（开关关闭但用户曾选中该通道） THEN UI SHALL 自动回退到 `MODE.NONE` 并 push_warning 一行提示。

---

### 需求 6：`performance-charter.md` §12.6 模板扩展

**用户故事**：作为之后所有真实 pass 迁移的执行者，我希望有一份**带邻居访问的 pass 模板**作为复制粘贴起点，以便面对像 climate Pass-A 这种真实 PDE pass 时不需要从零思考。

#### 验收标准

1. WHEN Pass #2 的 1~5 条需求全部完成 THEN `docs/performance-charter.md` §12 SHALL 新增 §12.6 子小节，标题为 "模板 #2：带邻居访问 + 多输入 SoA + 写新 component（基于 `thermal_gradient_pass`）"。
2. WHEN 用户阅读 §12.6 THEN 该子小节 SHALL 包含：
   - §12.6.1 哪些复杂度由这个模板覆盖（多输入 / 邻居 / 新 component / Overlay 接入）
   - §12.6.2 完整 C++ 代码块（`run_thermal_gradient_pass` 的真实代码，不是伪代码）
   - §12.6.3 完整 GDScript 对照代码块
   - §12.6.4 "用此模板做下一个带邻居访问的真实 pass"7 步操作清单
   - §12.6.5 反模式黑名单（边界处理用 `% h` 而非 clamp / 在 inner loop 调 view_f32 / 把 grid_w 写死成常量 / 在边界做条件分支而非"自值替代"）
3. WHEN §12.6 完成 THEN §12.0 / TL;DR 的索引 SHALL 增加一行链接，让读者能从 §12 入口直达模板 #2。
4. WHEN 模板代码块写入 §12.6.2 / §12.6.3 THEN 代码 SHALL 直接来自本计划实际产出的 `thermal_gradient_pass`（不是凭空构造的"应该这样"代码）。

---

### 需求 7：完成判定与时间盒

**用户故事**：作为正在持续推进通信契约的开发者，我希望本计划有清晰的"做完了"信号和硬性时间上限，以便避免它本身又演变成新的工程债务。

#### 验收标准

1. WHEN 本计划全部完成 THEN 用户 SHALL 能在 30 分钟内基于 §12.6 模板独立做出第 3 个带邻居访问的 pass（不需要再问 AI，不需要翻文档）。
2. IF 本计划实际耗时超过 4 小时（设计 2.5 小时，4 小时是硬上限） THEN 计划 SHALL 立即停止，重新评估方向，**不**强行推进。
3. WHEN 本计划完成 THEN 团队 SHALL **不**立即开始 climate Pass-A 修复——而是先让 Pass #1 + Pass #2 两个模板"沉淀一晚"，第二天再启动新计划。
4. WHEN 本计划完成 THEN "完成判据"7 条铁标 SHALL 全部为 ✅。

---

## 附录：与现有项目的衔接说明

- 本计划新增的 `cell.demo.thermal_gradient` component 通过命名前缀 `cell.demo.*` 与真实 climate / weather / ocean 数据完全隔离，**任何真实游戏机制都不应读它**。这是一条**长期纪律**，未来所有"参考实现 demo only"字段都遵循 `cell.demo.*` 前缀。
- 本计划与 `physical-wind-ocean-circulation` plan 完全正交：那个 plan 在做真实物理风场（SLP / τ_curl / ψ），它的输出已有 Overlay 通道（MODE 15/16/17）；本计划的 demo 通道（MODE 18）在 demo-only 命名空间下，不会与之冲突。
- 本计划完成后，**下一个计划**才是基于 Pass #1 + Pass #2 双模板正式重构 `bind_map_data` 契约 + 恢复 climate Pass-A。**那是后续计划，不在本计划范围**。
