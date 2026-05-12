# 实施计划

> Pass #2「温度梯度热应力场」是 Pass #1 通信契约模板的直接扩展。
> 本计划目标是把"多输入 SoA + 邻居访问 + 写新 component + 接入 Overlay"四条真实业务复杂度
> 一次性吃掉，并把成果沉淀为 `performance-charter.md` §12.6 子模板。
> 时间盒：设计 2.5 小时，硬上限 4 小时。
>
> 依赖：本计划假定 Pass #1 已完成（`run_temp_drift_pass` / `snapshot_f32` 已就绪）。
> 约束：所有 demo-only 字段使用 `cell.demo.*` 命名空间，不污染任何真实游戏机制。

---

- [ ] 1. 在 `scripts/data_core/component_ids.gd` 末尾新增 `CELL_DEMO_THERMAL_GRADIENT` 常量
   - StringName 字面量为 `&"cell.demo.thermal_gradient"`，使用 `cell.demo.*` 前缀建立 demo-only 命名空间
   - 在文件头部 / 该常量上方补 doc-comment：明确"`cell.demo.*` 是参考实现专用命名空间，禁止真实游戏机制读取或依赖"，并附"此字段不应进入永久存档"提示
   - _需求：2.1, 2.5_

- [ ] 2. 在 `ClimateProfile` 资源新增 `demo_thermal_gradient_enabled` 开关
   - 添加 `@export var demo_thermal_gradient_enabled: bool = false`，配套 doc-comment 说明"参考实现 demo 通道，仅用于通信契约验证"
   - 同步追加 `demo_thermal_gradient_elevation_gain: float = 1.5` 与 `demo_thermal_gradient_normalize_k: float = 0.5` 两个标量参数（避免后续 hard-code 在 main.gd）
   - _需求：5.1_

- [ ] 3. 在 C++ 侧 `world_ext.h` / `world_ext.cpp` 新增 `run_thermal_gradient_pass(int grid_w, int grid_h, float elevation_gain, float normalize_k)`
   - 在 `_bind_methods()` 通过 `ClassDB::bind_method` 暴露给 GDScript（与 Pass #1 的 `run_temp_drift_pass` 并列）
   - 实现：预先 `ptr()` 拿 CELL_TEMP / CELL_ELEVATION 只读裸指针，`ptrw()` 拿 CELL_DEMO_THERMAL_GRADIENT 写指针；tight loop 内仅整数索引 + 4-邻 clamp-to-edge 边界处理；公式 `clamp(grad_mag * (1 + gain * elev) * k, 0, 1)`
   - 安全分支：若任一 slot 未注册 / 维度不匹配（`w*h != arr.size()`） → push_warning + no-op return
   - _需求：1.1, 1.2, 1.3, 1.4, 1.5, 1.6_

- [ ] 4. 在 `data_core/world.gd` 的 `bind_map_data` 阶段按开关注册 `CELL_DEMO_THERMAL_GRADIENT` slot
   - 仅在 `ClimateProfile.demo_thermal_gradient_enabled == true` 时调用 `_bind_register_and_attach(CELL_DEMO_THERMAL_GRADIENT, F32, false, ...)`，绑定到 MapData 上一个新增的 `demo_thermal_gradient_arr: PackedFloat32Array` 字段
   - 在 `MapData` 增加 `demo_thermal_gradient_arr` 字段定义、reset/resize 时清零（与其他 climate slot 同语义）
   - _需求：2.2, 2.3, 2.4_

- [ ] 5. 新建 `tmp/bench_thermal_gradient.gd` 包含完整对照实现 + 验证流程
   - 5.1 GDScript 对照函数 `thermal_gradient_pass_gdscript(temp, elev, w, h, gain, k) -> PackedFloat32Array`：与需求中伪代码逐行同语义实现，不依赖 MapData/HexCell
   - 5.2 主入口 `_main()`：构造 60×40 的 CELL_TEMP（线性梯度 + 余弦扰动）和 CELL_ELEVATION（确定性伪随机），分别通过 C++ `run_thermal_gradient_pass` + `snapshot_f32` 与 GDScript 对照路径计算两份结果
   - 5.3 逐元素比对，统计 `max_abs_diff`；> 1e-6 视为失败，打印失败索引 + 双方值但不崩溃；通过则打印 `[bench_thermal_gradient] PASS — 60x40 cells, max_abs_diff=...`
   - 5.4 用 `Time.get_ticks_usec()` 记录两条路径耗时并打印；C++ 路径 > 2 ms 时仅 push_warning，不中断
   - _需求：1.1（验证）, 3.1, 3.2, 3.3, 3.4, 3.5_

- [ ] 6. 在 `OverlayMode` / baker / shader / legend 四处补齐 `DEMO_THERMAL_GRADIENT` 通道
   - 6.1 `overlay_mode.gd`：枚举末尾新增 `DEMO_THERMAL_GRADIENT = 18`，并在 `DISPLAY_NAME`（"热梯度（demo）"）/ `RANGE_LABEL`（["0.00","1.00"]）/ `CATEGORY`（CONTINUOUS）/ `ordered_modes()` 末尾同步追加
   - 6.2 `data_overlay_baker.gd`：新增分支按 `view_f32(CELL_DEMO_THERMAL_GRADIENT)`（或同等只读访问）采样写入数据纹理 R 通道，无二次缩放
   - 6.3 `shaders/data_overlay.gdshader`：增加 mode==18 分支，复用现有连续色带（首选与 TEMPERATURE 同色带）经 `ramp_continuous` 输出
   - 6.4 `ui/overlay_legend.gd`：补齐标题"热梯度（demo）"与两端标签的渲染分支
   - _需求：4.1, 4.2, 4.3, 4.4, 4.5_

- [ ] 7. 在主流程每日 tick 末尾接入 `run_thermal_gradient_pass` 调用 + 下拉菜单可见性
   - 7.1 在 `scripts/main.gd`（climate pass 链路完成的位置）按 `cp.demo_thermal_gradient_enabled` 调用 `_ext.run_thermal_gradient_pass(map.width, map.height, cp.demo_thermal_gradient_elevation_gain, cp.demo_thermal_gradient_normalize_k)`；调用后通过 `snapshot_f32` 把结果 flush 到 `map.demo_thermal_gradient_arr`，触发既有的 baker 重 bake 路径
   - 7.2 在调试控制台 / Overlay 下拉菜单生成处，按 `cp.demo_thermal_gradient_enabled` 决定是否注入 `MODE.DEMO_THERMAL_GRADIENT`；当前选中该 mode 而开关切到 false 时，回退到 `MODE.NONE` 并 `push_warning` 一行提示
   - _需求：4.6, 5.2, 5.3, 5.4, 5.5_

- [ ] 8. 端到端联调验证（在游戏内观察 Overlay）
   - 在 Godot Editor 打开 main.tscn 运行游戏，临时把 `ClimateProfile.demo_thermal_gradient_enabled` 设为 true，调试控制台切换到"热梯度（demo）"，确认山区 / 海陆交界 / 锋面位置高亮符合直觉
   - 关闭开关后确认下拉菜单中该项消失、当前选中项自动回退到 NONE、其他既有通道完全不受影响
   - 同步运行 `tmp/bench_thermal_gradient.gd` 确认 PASS 与耗时 < 2 ms
   - _需求：完成判据 3, 4, 5；7.4_

- [ ] 9. 在 `docs/performance-charter.md` §12 新增 §12.6 子小节并更新顶部索引
   - 9.1 §12.6.1 概述：列出本模板覆盖的 4 条复杂度（多输入 / 邻居 / 新 component / Overlay 接入）
   - 9.2 §12.6.2 / §12.6.3：直接粘贴 `run_thermal_gradient_pass` C++ 实现 + GDScript 对照实现的真实代码（来自步骤 3 与 5.1，不写伪代码）
   - 9.3 §12.6.4：列出"用此模板做下一个带邻居访问的真实 pass"7 步清单（建 component → 加开关 → 写 C++ pass → 写 GDScript 对照 → 写 bench → 接 Overlay → 接主流程）
   - 9.4 §12.6.5：反模式黑名单（边界用 `% h` 而非 clamp-to-edge / inner loop 调 `view_f32` / hard-code grid_w / 边界用条件分支而非"自值替代"）
   - 9.5 在文档头部 TL;DR / §12 入口索引追加直达 §12.6 的链接
   - _需求：6.1, 6.2, 6.3, 6.4_

- [ ] 10. 完成判定与时间盒复盘
   - 复盘"完成判据"7 条铁标全部 ✅
   - 思想实验：能否在 30 分钟内基于 §12.6 模板独立做出第 3 个带邻居访问的 pass（不实施）
   - 若总耗时已超 4 小时硬上限：停止，记录卡点，重新评估方向；否则标记本计划完成并提醒用户"两份模板沉淀一晚再启动 climate Pass-A 修复"
   - _需求：7.1, 7.2, 7.3, 7.4_
