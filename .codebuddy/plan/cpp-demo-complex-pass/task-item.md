# 实施计划

> Pass #3「复杂度上限探测器」是 Pass #2 通信契约模板的内核升级。
> 本计划目标是在**完全保留 Pass #2 全部基础设施**的前提下，仅替换 C++ 内核算法为
> 迭代式各向异性扩散 + 多尺度风场近似，新增 4 个 ClimateProfile 旋钮、新增 bench
> 跑 3 档网格 × 3 档迭代步数，并把每 tick 耗时打印到控制台，最终把性能预算实测
> 表沉淀为 `performance-charter.md` §12.6.6 子小节。
>
> 时间盒：设计 2.5 小时，硬上限 4 小时。
>
> 依赖：本计划假定 Pass #1 + Pass #2 已完成（`run_temp_drift_pass` /
> `run_thermal_gradient_pass` / `snapshot_f32` 已就绪，`CELL_DEMO_THERMAL_GRADIENT`
> component / `MODE.DEMO_THERMAL_GRADIENT` 已注册、可视化通道已贯通）。
>
> 约束：所有 demo-only 字段沿用 `cell.demo.*` 命名空间；不新增 component；不新增 Overlay MODE；
> 不新增 baker / shader / legend 分支；不让升级后的算法影响任何真实游戏机制。

---

- [ ] 1. 在 C++ 侧 `world_ext.h` / `world_ext.cpp` 新增 `run_demo_complex_pass(int grid_w, int grid_h, int iterations, int kernel_radius, float coriolis_strength, float terrain_drag, float elevation_gain, float normalize_k)`
   - 1.1 头文件 `world_ext.h` 在现有 `run_thermal_gradient_pass` 声明下方追加新方法声明，注释标记"Pass #3 / charter §12.6.6 内核"
   - 1.2 实现文件 `world_ext.cpp`：入口处 clamp `iterations ∈ [1, 64]` / `kernel_radius ∈ [1, 5]` / `coriolis_strength ∈ [-1, 1]` / `terrain_drag ∈ [0, 1]`，clamp 触发时通过 `static bool` 守门只 push_warning 一次
   - 1.3 复用 Pass #2 既有的 slot 校验流程（CELL_TEMP / CELL_ELEVATION / CELL_DEMO_THERMAL_GRADIENT 任一未注册 → push_warning + no-op return；w*h != arr.size() → 同等处理）
   - 1.4 算法主体：(a) 一次性预计算高斯权重表 `kernel[(2kr+1)²]`（栈数组，最大 11×11=121 项）；(b) 分配/复用两块 `LocalVector<float>` 乒乓 buffer（首步从 CELL_TEMP 拷贝初始化）；(c) iter 主循环每步对每个 cell 做"高斯加权 smooth + 3×3 Sobel 梯度 + 科氏旋转 + 地形阻尼 + 步长 0.05 演化"；(d) 末尾按 (out − min) / (max − min) 归一化后乘 (1 + gain·elev) · k 并 clamp 到 [0,1] 写入输出 slot
   - 1.5 边界统一 clamp-to-edge（与 Pass #2 同语义），inner loop 仅整数索引 + 裸指针 + 查表，**禁止** Variant / set / get
   - 1.6 在 `_bind_methods()` 通过 `ClassDB::bind_method` 暴露 `run_demo_complex_pass` 给 GDScript，参数名按需求 1.7 列出
   - _需求：1.1, 1.2, 1.3, 1.4, 1.5, 1.7_

- [ ] 2. 把旧入口 `run_thermal_gradient_pass(w, h, gain, k)` 改造为新入口的 thin-wrapper
   - 2.1 旧 `run_thermal_gradient_pass` 函数体清空，改为 `run_demo_complex_pass(grid_w, grid_h, /*iterations=*/1, /*kernel_radius=*/1, /*coriolis_strength=*/0.0f, /*terrain_drag=*/0.0f, elevation_gain, normalize_k)`
   - 2.2 在 `run_demo_complex_pass` 内部判断 `iterations == 1 && kernel_radius == 1 && coriolis_strength == 0 && terrain_drag == 0` 时走"快速路径"：直接复用 Pass #2 老算法（4-邻一阶差分 + (1+gain·elev)·k + clamp），保证与 Pass #2 老 GDScript 对照实现 bit-equal（即 Pass #2 老 bench 跑回去仍 PASS）
   - 2.3 在 `world_ext.cpp` 的 `_bind_methods` 中保留旧绑定（不改签名、不改方法名），charter §12.6.2 的代码引用不破
   - 2.4 在 `tmp/bench_thermal_gradient.gd`（Pass #2 老 bench）跑一遍，确认 `[bench_thermal_gradient] PASS` 仍然成立
   - _需求：1.6（向后兼容验证）, 完成判据 2_

- [ ] 3. 在 `ClimateProfile` 资源新增 4 个旋钮
   - 3.1 在 `scripts/data/climate_profile.gd` 现有 `demo_thermal_gradient_normalize_k` 字段下方追加 4 个 `@export` 字段，按需求 2.1 的范围与默认值
   - 3.2 4 个字段配套 doc-comment，注明物理隐喻（迭代步数 = 时间深度 / 邻居半径 = 空间影响域 / 科氏 = 半球偏向 / 阻尼 = 山地降速）与"调大 = 更慢但花纹更复杂"提示
   - 3.3 在 `data/world/earth_like.tres` 中**不**显式覆盖 4 个新字段（保持默认值），首次启动直接跑默认参数
   - _需求：2.1, 2.2, 2.3, 2.4_

- [ ] 4. 在 `scripts/main.gd` 的 `_run_demo_thermal_gradient_pass_if_enabled()` 切换为新 8 参数入口 + 每 tick 耗时打印
   - 4.1 函数体中现有 `ext.run_thermal_gradient_pass(w, h, gain, k)` 调用替换为 `ext.run_demo_complex_pass(w, h, iter, kr, coriolis, drag, gain, k)`，4 个新参数从 `ClimateProfile` 读取（沿用 Pass #2 既有的 `cp != null` 防御 + 默认值兜底）
   - 4.2 在调用前后各加一次 `Time.get_ticks_usec()`，每 tick 打印一行紧凑诊断 `[demo_complex] tick=#N w=W h=H iter=I kr=R coriolis=C drag=D cpp=Tcpp µs out[min=mn max=mx mean=avg]`；`tick=#N` 用一个本类内单调递增计数 `_demo_complex_tick_counter` 实现，避免依赖 daily tick 接口
   - 4.3 保留 Pass #2 既有的 `_demo_tg_first_run_logged` 守门变量与第一行额外打印 `[demo_complex] first run OK — input temp[...] elevation[...]`（重命名 print 前缀 demo_thermal_gradient → demo_complex 以与新内核语义对齐）
   - 4.4 增加"过预算守门"：若单 tick `Tcpp > 16000 µs`，仅在第 1 次发生时 push_warning 一次"参数过激，建议下调 iterations"，用 `static bool _demo_complex_over_budget_warned`（在脚本内 `var _demo_complex_over_budget_warned: bool = false` 实现）
   - 4.5 ClimateProfile 开关 OFF 时整段跳过（沿用 Pass #2 既有 `_is_demo_thermal_gradient_enabled()` 检查），不打印任何诊断
   - _需求：4.1, 4.2, 4.3, 4.4, 4.5, 4.6_

- [ ] 5. 编写 GDScript 对照实现 `demo_complex_pass_gdscript()`
   - 5.1 在 `tmp/bench_demo_complex.gd`（新文件）中实现 GDScript 版本，函数签名 `demo_complex_pass_gdscript(temp: PackedFloat32Array, elev: PackedFloat32Array, w: int, h: int, iterations: int, kernel_radius: int, coriolis: float, drag: float, gain: float, k: float) -> PackedFloat32Array`
   - 5.2 内部实现与 C++ 端逐行对应：高斯权重表 → iter 主循环 → 高斯 smooth → Sobel 梯度 → 科氏旋转 → 阻尼演化 → 末尾归一化 + (1+gain·elev)·k + clamp
   - 5.3 浮点运算顺序 SHALL 与 C++ 逐运算严格对齐（先乘后加 / 同类项分组方式都要一致），以保证 IEEE754 下 bit-equal 可达；如实测某些 op 顺序不可达，则降级为"误差 ≤ 1e-6"判定并在 bench 输出中明确说明
   - 5.4 不依赖 MapData / HexCell / DCWorld，可独立调用
   - _需求：3.1, 完成判据 3_

- [ ] 6. 编写 `tmp/bench_demo_complex.gd` 主入口 + 9 组性能对照表
   - 6.1 入口 `_main()`：构造与 Pass #2 bench 同样的输入（线性温度梯度 + 余弦扰动 + 确定性伪随机 elevation），用 RandomNumberGenerator 固定 seed 保证可重复
   - 6.2 **bit-equal 验证组**：网格 32×32，参数 iter=4, kr=2, coriolis=0.5, drag=0.6, gain=1.5, k=0.5；C++ 与 GDScript 各跑一次，逐元素比对，max_abs_diff > 1e-6 视为 FAIL（打印失败索引和双方值，但不崩溃）；通过则打印 `[bench_demo_complex] BIT-EQUAL PASS — 32x32, iter=4, max_abs_diff=...`
   - 6.3 **性能对照组**：网格 ∈ {32×32, 64×64, 128×128} × iter ∈ {4, 16, 64}，kr=2 固定；嵌套两层 for 跑 9 组，每组各 1 次 C++ + 1 次 GDScript，记录 `Time.get_ticks_usec()` 开销
   - 6.4 末尾打印一张 ASCII 表（建议格式 `| grid | iter | kr | C++ µs | GDScript µs | speedup |`），对齐输出；并在表末追加一行 `→ projected at game-grid (60x40, iter=16, kr=2): C++ ~ X µs (interpolated)`，X 用最接近的 64×64 iter=16 实测值线性外推
   - 6.5 任意 C++ 组耗时 > 50 ms 时 push_warning 但不中断
   - 6.6 末尾打印一行 `[bench_demo_complex] DONE — bit-equal=PASS|FAIL, 9 perf rows logged`
   - _需求：3.1, 3.2, 3.3, 3.4, 3.5, 3.6, 完成判据 6_

- [ ] 7. 端到端联调验证（在游戏内观察 Overlay + 控制台耗时）
   - 7.1 编译 C++ 端（gdext 重 build）→ 在 Godot Editor 打开 main.tscn → 运行游戏；确认 `[demo_complex] first run OK ...` 与 `[demo_complex] tick=#1 ...` 各打印一行
   - 7.2 切到"热梯度（demo）"Overlay，肉眼确认花纹比 Pass #2 丰富（有卷动条带 / 山脉两侧分流 / 海陆锋面增强）
   - 7.3 在 Inspector 把 `demo_complex_iterations` 调到 64，观察控制台单 tick `cpp=...` 数字明显上升、花纹趋稳；调到 1，观察数字回落、花纹退化为 Pass #2 风格
   - 7.4 把 `demo_thermal_gradient_enabled` 关掉，确认控制台不再打印 `[demo_complex]` 任何行，下拉菜单中该项消失，其他通道完全不受影响
   - 7.5 再开启 → 跑 `tmp/bench_thermal_gradient.gd`（Pass #2 老 bench）→ 确认 `[bench_thermal_gradient] PASS` 仍然成立（向后兼容守住）
   - 7.6 跑 `tmp/bench_demo_complex.gd`（Pass #3 新 bench）→ 确认 `[bench_demo_complex] BIT-EQUAL PASS` + 9 组性能数字全部输出 + `DONE` 行落地
   - _需求：完成判据 4, 5, 7；7.4_

- [ ] 8. 在 `docs/performance-charter.md` §12.6 末尾追加 §12.6.6 实测预算表
   - 8.1 §12.6.6.a：升级前后算子复杂度对比一句话表（Pass #2 ~10 ops/cell vs Pass #3 默认 ~2400 ops/cell）
   - 8.2 §12.6.6.b：bench 9 组实测表（直接从 `tmp/bench_demo_complex.gd` 输出粘贴，注明测试硬件 / 时间 / Godot 版本 / 编译模式 = Release-with-debug；禁止伪造数字）
   - 8.3 §12.6.6.c：单 tick 游戏内实测一行（直接粘 `[demo_complex] tick=#1 ... cpp=... µs ...`）
   - 8.4 §12.6.6.d："如何在真实 climate pass 设计时使用此表" 3 句话指导（按 ops/cell 估算 → 对照本表插值 → 留 2× 安全边）
   - 8.5 在文档头部 §12 入口索引 / TL;DR 追加直达 §12.6.6 的链接
   - _需求：5.1, 5.2, 5.3, 5.4, 完成判据 8_

- [ ] 9. 完成判定与时间盒复盘
   - 复盘"完成判据"9 条铁标全部 ✅
   - 思想实验：根据 §12.6.6 的 9 档实测，能否给 climate Pass-A 真实 PDE 迭代估出"在 60×40 / iter=16 下的 budget 上限"？（不实施，仅记录估算结果与置信度）
   - 若总耗时已超 4 小时硬上限：停止，记录卡点，重新评估方向；否则标记本计划完成并提醒用户"三份模板沉淀一晚再启动 climate Pass-A 决策"
   - _需求：6.1, 6.2, 6.3, 6.4_

... EOF no more lines ...
