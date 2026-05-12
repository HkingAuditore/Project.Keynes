# 实施计划

> 本计划目标是建立一份"活体最佳实践模板"——通过实施一个最小化的人造 pass `temp_drift_pass`，
> 把模式 B（C++ 独占 + GDScript 拉快照）的完整通信契约跑通一次，作为后续所有真实 pass 迁移的复制粘贴模板。
> 时间盒：设计 2 小时，硬上限 4 小时。
>
> 约束：所有新增代码位于附加路径，不修改现有 `view_f32` / `bind_map_data` / `write_f32_indexed` 等已有 API。

---

- [ ] 1. 在 C++ 侧 `world_ext.h` / `world_ext.cpp` 新增 `run_temp_drift_pass(float drift_amount)`
   - 在 `_bind_methods()` 中通过 `ClassDB::bind_method` 暴露给 GDScript
   - 实现使用 `ptrw()` 拿裸指针，tight loop 内禁止任何 Variant / set / get 调用
   - 处理 `CELL_TEMP` slot 未注册的安全 no-op 分支
   - _需求：1.1, 1.2, 1.3, 1.4, 1.5_

- [ ] 2. 在 C++ 侧新增通用 `snapshot_f32(int32_t comp_id) -> PackedFloat32Array`
   - 在 `_bind_methods()` 中注册，与 `view_f32` 并列暴露
   - 返回值拷贝（依赖 GDExtension PackedArray 的 COW 语义）
   - 在头文件 doc-comment 明确标注：`view_f32` 旧 API / `snapshot_f32` 模式 B 推荐 API 的语义差异
   - 处理越界 / 类型不匹配的安全返回（空数组）
   - _需求：2.1, 2.2, 2.3, 2.4, 2.5_

- [ ] 3. 在 `tmp/bench_temp_drift.gd` 新建测试脚本骨架
   - 创建 DCWorldExt 实例，注册 CELL_TEMP component（容量 N，建议 N=1024 用于快速验证）
   - 用已知初始数组（全 0.0）写入 `_slots[CELL_TEMP]`（通过现有 write API）
   - 提供 `_main()` 入口供 Godot Editor 直接运行
   - _需求：5.1（前置）_

- [ ] 4. 在 `tmp/bench_temp_drift.gd` 实现 GDScript 对照函数 `temp_drift_pass_gdscript(map, drift_amount)`
   - 直接遍历 `map.temp_arr` 做 `+= drift_amount`
   - 与后续 C++ 路径产出的结果做 bit-精确比对
   - _需求：3.1, 3.2, 3.3_

- [ ] 5. 在 `tmp/bench_temp_drift.gd` 实现 `flush_to_mapdata(ext, map)` 帮助函数
   - 调用 `ext.snapshot_f32(CELL_TEMP)` 拉取最新数据
   - 赋值给 `map.temp_arr`
   - 在函数 doc-comment 注明："flush 是契约，不是优化——禁止依赖 alias 自动同步"
   - _需求：4.1, 4.2, 4.3_

- [ ] 6. 在 `tmp/bench_temp_drift.gd` 实现完整验证流程
   - 连续调用 `_ext.run_temp_drift_pass(0.5)` 三次
   - 调用 `flush_to_mapdata` 拉回结果
   - 逐元素验证每个 cell == 1.5（精确相等）
   - 失败时打印失败索引和实际值，但不崩溃
   - 通过时打印 `[bench_temp_drift] PASS — N cells, 3 passes, all values match`
   - _需求：5.1, 5.2, 5.3_

- [ ] 7. 在 `tmp/bench_temp_drift.gd` 增加双路径耗时测量与一致性比对
   - 对 C++ 路径和 GDScript fallback 路径分别用 `Time.get_ticks_usec()` 计时并打印 μs
   - 对两条路径产出的最终数组做 bit-精确逐元素比对
   - 断言跨界开销 < 1 ms（仅打印警告，不中断）
   - _需求：5.4, 5.5_

- [ ] 8. 在 `docs/performance-charter.md` 新增 §12 "C++/GDScript 通信参考实现"
   - §12.1：升格"GDExtension 没有零拷贝共享内存"为铁律 4
   - §12.2：模式 B 的 4 个角色（C++ writer / snapshot API / GDScript reader / flush point）
   - §12.3：直接复制 `temp_drift_pass` C++ 与 GDScript 两端真实代码作为模板
   - §12.4："用模板做下一个 pass"的 7 步操作清单
   - §12.5：反模式黑名单（循环内 `view_f32` / 依赖 alias / 循环内 set/get）
   - 在文档头部 TL;DR 区域增加直达 §12 的链接
   - _需求：6.1, 6.2, 6.3, 6.4_

- [ ] 9. 端到端验证与完成判定
   - 在 Godot Editor 中运行 `tmp/bench_temp_drift.gd`，确认输出 PASS
   - 复盘"完成判据"6 条铁标全部 ✅
   - 自检：能否在 30 分钟内基于 §12 模板独立做出第 2 个 pass（思想实验，不实施）
   - 若总耗时已超 4 小时硬上限，停止并重新评估方向
   - _需求：7.1, 7.2, 7.3, 7.4_
