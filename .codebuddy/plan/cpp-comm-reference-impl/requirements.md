# 需求文档 — C++/Godot 数值通信"参考实现"标杆

> **文档目的**：本计划的产物**不是**一个游戏 feature，而是**一份"活体最佳实践模板"**。  
> 它通过实施一个最小化、纯净的"hello world 级"C++ pass，把模式 B（Owned-by-C++） 的完整通信契约**跑通一次**。完成后，它将作为之后所有 hot-loop 迁移（climate / ocean / weather / economy / pop ...）的**复制-粘贴模板**。  
> **本计划完成 = ProjectKeynes 拥有了一份钉死的、不再含糊的 C++/GDScript 通信最佳实践。**

---

## 引言

### 背景

在 climate Pass-A 回退（"全蓝 bug"，2026-05-12）之后，团队识别到根本问题不是算法 bug，而是**架构层面的双源 storage 问题**——GDScript 端 `MapData.temp_arr` 和 C++ 端 `DCWorldExt._slots[temp].arr_f32` 在 GDExtension 的 COW 语义下**不可能保证 alias 共享**，任何依赖"两边自动同步"的代码都会在某个时点分裂成两块独立内存，造成数值不一致。

经过完整决策（见 [`docs/performance-charter.md`](../../../docs/performance-charter.md)），团队选择了 **"L0 数据归 C++ 独占 + GDScript 拉只读快照"** 的架构方向。在大规模迁移（剩余 6 个 climate pass + ocean + weather + 未来的 economy/pop）开始之前，必须先建立一份**钉死的、可复制的通信契约模板**。

### 为什么不直接迁移真实 pass？

之前讨论过用 `season_refresh_job` 作为标杆，但调查发现该 job 实际是 11-stage 异质分发器（涉及 biome 决策、植被回写、河流模拟），形状复杂度等同于 climate Pass-A，**作为标杆会重蹈覆辙**。

正确的做法是：**先建一个人造的、最小化的"hello world"级 pass，专门用来验证通信契约本身**。这个 pass 完成它的诊断使命后**会被保留为永久的"参考实现样板"**，新 pass 来了照着抄。

### 标杆 Pass 的设计

引入一个名为 **`temp_drift_pass`** 的人造 pass：

- **行为**：把所有 cell 的 `CELL_TEMP` 数组里每个元素 `+ drift_amount`。
- **输入**：`drift_amount: float`（标量参数）。
- **输出**：直接修改 `_slots[CELL_TEMP].arr_f32`（C++ 端写）。
- **数学性质**：加法可逆、可重复、与其他 pass 无任何耦合，便于精确比对验证。

它的存在意义**不是**为游戏增加 feature，而是：

1. 验证模式 B（Owned-by-C++）的所有契约点
2. 提供 `snapshot_f32(comp_id)` API 的首次落地
3. 提供 GDScript 端 `flush_to_mapdata()` 同步点的首次落地
4. 写入 `performance-charter.md` 的"标准模板代码块"，新 pass 直接复制

### 范围声明

#### 本计划**做什么**

- 在 `DCWorldExt` 中新增 `run_temp_drift_pass(drift_amount)` C++ 方法
- 在 `DCWorldExt` 中新增 `snapshot_f32(comp_id)` 通用快照 API
- 在 GDScript 端新增 `WorldExtFlush` 帮助函数 / 模式（把 snapshot 拉回 MapData）
- 编写一个 GDScript 端的对照实现 `temp_drift_pass_gdscript()` 用于精确数值对比
- 编写一个 micro-bench 脚本 `tmp/bench_temp_drift.gd` 验证通信契约
- 把这个完整流程**抽象成模板**写入 `docs/performance-charter.md` §12

#### 本计划**不做什么**

- ❌ **不**修复 climate Pass-A 全蓝 bug（那是后续计划的事，本计划完成后才有资格碰）
- ❌ **不**重构 `bind_map_data` 契约（标杆完成后再做）
- ❌ **不**迁移任何真实 hot-loop（season / ocean / weather 全部不动）
- ❌ **不**改动 SUS 调度器
- ❌ **不**为 temp_drift_pass 加 SIMD / 多线程（标杆故意保持 scalar，简单到不会出错）
- ❌ **不**修改 MapData 现有的 `temp_arr` 持有方式（仅追加新的 snapshot 路径，旧路径暂时保留）

### 完成判据（"我做出了一份最佳实践"的判定）

1. ✅ `temp_drift_pass` 在 C++ 端能正确把 `_slots[CELL_TEMP].arr_f32` 每个值 +drift_amount
2. ✅ GDScript 端通过 `_ext.snapshot_f32(CELL_TEMP)` 能拿到正确的新数组
3. ✅ GDScript 端调用 `flush_to_mapdata()` 后，`map.temp_arr` 与 C++ 内部 `_slots[CELL_TEMP]` 数值一致
4. ✅ GDScript fallback `temp_drift_pass_gdscript()` 与 C++ 路径产出**逐元素 bit-精确相等**（因为加法运算精确）
5. ✅ 通信契约模板写入 `performance-charter.md`，且模板代码可被人在 30 分钟内套用到一个新 pass
6. ✅ 整个迁移 + 验证 ≤ 2 小时完成

---

## 需求

### 需求 1：C++ 端新增 `run_temp_drift_pass()` 入口点

**用户故事**：作为引擎工程师，我希望有一个最小化、零数学风险的 C++ pass 入口，以便我能用它验证整个通信契约而不被算法 bug 干扰。

#### 验收标准

1. WHEN `DCWorldExt` 被实例化并完成 component 注册（含 `CELL_TEMP`） THEN 系统 SHALL 在 `world_ext.h` / `world_ext.cpp` 中暴露 `void run_temp_drift_pass(float drift_amount)` 方法。
2. WHEN GDScript 端调用 `_ext.run_temp_drift_pass(0.5)` THEN 系统 SHALL 把 `_slots[CELL_TEMP].arr_f32` 中每个元素的值增加 0.5（使用 `ptrw()` 拿裸指针、tight loop 内不出现任何 Variant 操作）。
3. WHEN `run_temp_drift_pass` 执行期间 THEN 系统 SHALL **不**触发任何 GDScript 端的 set/get 调用、**不**做任何 push-back / alias 推回操作。
4. IF `CELL_TEMP` 的 slot 尚未注册 THEN 系统 SHALL 安全 no-op 并返回（不崩溃、不抛异常）。
5. WHEN 该方法在 `_bind_methods()` 中注册 THEN 系统 SHALL 让 GDScript 端通过 `_ext.run_temp_drift_pass(amount)` 直接调用。

---

### 需求 2：C++ 端新增通用 `snapshot_f32(comp_id)` 快照 API

**用户故事**：作为 GDScript 端调用方，我希望能从 C++ 端拉取任意 component 的只读数据快照，以便用于 UI 渲染、Baker、调试，而不破坏 C++ 端数据所有权。

#### 验收标准

1. WHEN GDScript 端调用 `_ext.snapshot_f32(comp_id)` THEN 系统 SHALL 返回 `_slots[comp_id].arr_f32` 的值拷贝（GDExtension 自动 COW，不会泄漏 C++ 内部裸指针）。
2. WHEN 返回的 `PackedFloat32Array` 被 GDScript 端修改（`arr[i] = v`） THEN 系统 SHALL 保证这个修改**不**反向影响 C++ 内部的 `_slots[]`（即"快照"语义不被违反）。
3. IF `comp_id` 越界或对应 slot 不是 f32 类型 THEN 系统 SHALL 返回空数组 `PackedFloat32Array()`（不崩溃）。
4. WHEN 该 API 在 `_bind_methods()` 中注册 THEN 系统 SHALL 提供与 `view_f32` 并列的 GDScript-callable 入口（保留 `view_f32` 不动以兼容旧代码）。
5. WHEN 项目同时存在 `view_f32` 和 `snapshot_f32` 时 THEN 文档（头文件 doc-comment）SHALL 明确说明两者语义差异：`view_f32` 是"旧的、可能令人误解的命名"，`snapshot_f32` 是"模式 B 推荐 API"。

---

### 需求 3：GDScript 端新增 `temp_drift_pass_gdscript()` 对照实现

**用户故事**：作为验证者，我希望有一个 GDScript 实现的对照版本，以便能精确比对 C++ 路径和 GDScript 路径的数值结果。

#### 验收标准

1. WHEN GDScript 端在测试上下文中调用 `temp_drift_pass_gdscript(map, drift_amount)` THEN 系统 SHALL 把 `map.temp_arr` 中每个元素的值增加 `drift_amount`。
2. WHEN 该函数执行完成 THEN `map.temp_arr` 的内容 SHALL 与"C++ 路径执行 + flush 后的 `map.temp_arr`"**逐元素 bit 精确相等**（因为加法运算无精度差）。
3. WHEN 该函数被定义 THEN 它 SHALL 位于一个独立的测试/工具脚本（`tmp/bench_temp_drift.gd`），**不**侵入主游戏流程。

---

### 需求 4：GDScript 端 `flush_to_mapdata()` 同步点

**用户故事**：作为 GDScript 主流程开发者，我希望有一个明确命名的同步函数把 C++ 计算结果拉回 MapData，以便 UI 和 Baker 能读到最新数据，且这个同步点是显式可见的。

#### 验收标准

1. WHEN `flush_to_mapdata(ext, map)` 被调用 THEN 系统 SHALL 通过 `ext.snapshot_f32(CELL_TEMP)` 拉取最新数据，并赋值给 `map.temp_arr`。
2. WHEN 该函数被定义 THEN 它 SHALL 位于 `tmp/bench_temp_drift.gd` 作为标杆代码（后续可能升格为正式的 `WorldExtFlush` 帮助类，但本计划不做此升格）。
3. WHEN 文档展示该模式 THEN `performance-charter.md` SHALL 明确指出：**flush 是契约，不是优化**——任何模式 B 的 pass 都必须在产生新数据后显式 flush，禁止依赖 alias 自动同步。

---

### 需求 5：micro-bench 验证脚本

**用户故事**：作为质量负责人，我希望有一个可重复运行的 bench 脚本一键验证整个通信链路是否正确，以便每次架构变更后能快速回归。

#### 验收标准

1. WHEN 运行 `tmp/bench_temp_drift.gd` THEN 系统 SHALL 执行以下完整流程：
   - 创建 DCWorldExt 实例并注册 CELL_TEMP component
   - 把一个已知的初始数组（如 N 个 0.0）写入 `_slots[CELL_TEMP]`
   - 调用 `_ext.run_temp_drift_pass(0.5)` **3 次**（连续累加，验证多次调用无状态错误）
   - 通过 `snapshot_f32` 拉回结果
   - 验证每个元素 == 1.5（精确相等）
2. IF 任意元素 != 1.5 THEN 脚本 SHALL 在控制台打印失败位置和实际值（不崩溃）。
3. WHEN 验证通过 THEN 脚本 SHALL 在控制台输出 `[bench_temp_drift] PASS — N cells, 3 passes, all values match`。
4. WHEN 同一脚本同时运行 GDScript fallback 路径 THEN 系统 SHALL 验证两条路径产出 bit-精确相等。
5. WHEN 脚本执行完毕 THEN 它 SHALL 输出每条路径的耗时（μs），用于人工核实跨界开销 < 1 ms。

---

### 需求 6：把通信契约写入 `performance-charter.md` §12

**用户故事**：作为之后所有迁移工作的执行者（包括我自己未来），我希望有一份**钉死的、可复制粘贴的通信契约模板**，以便面对一个新 pass 时不需要重新思考，直接套模板。

#### 验收标准

1. WHEN 本计划的 1~5 条需求全部完成 THEN `docs/performance-charter.md` SHALL 新增 §12 章节，标题为 "C++/GDScript 通信参考实现（Reference Implementation）"。
2. WHEN 用户阅读 §12 THEN 该章节 SHALL 包含以下子小节：
   - §12.1 公理：GDExtension 没有零拷贝共享内存（升格为铁律 4）
   - §12.2 模式 B 通信契约的 4 个角色（C++ writer / GDScript reader / snapshot API / flush point）
   - §12.3 标杆 Pass 完整代码（C++ + GDScript 两端）作为可复制模板
   - §12.4 "用模板做下一个 pass"的 7 步操作清单
   - §12.5 反模式黑名单：循环内调 `view_f32`、依赖 alias、循环内 set / get
3. WHEN §12 完成 THEN 文档 SHALL 在文档头部"配套"区域加上一行链接，让读者能从 TL;DR 直达模板。
4. WHEN 模板代码块写入 §12.3 THEN 代码 SHALL 直接来自本计划实际产出的 `temp_drift_pass`（不是凭空写的"应该这样"代码），保证代码与文档不脱节。

---

### 需求 7：完成判定与时间盒

**用户故事**：作为正在被"卡死"困住的开发者，我希望本计划有一个清晰的"做完了"信号和硬性时间上限，以便不让标杆任务本身又变成新的工程债务。

#### 验收标准

1. WHEN 本计划全部完成 THEN 用户 SHALL 能在 30 分钟内基于 §12 模板独立做出第 2 个 pass（不需要再问 AI 或翻文档）。
2. IF 本计划实际耗时超过 4 小时（设计上是 2 小时，4 小时是硬上限） THEN 计划 SHALL 立即停止，重新评估方向，**不**强行推进。
3. WHEN 本计划完成 THEN 团队 SHALL **不**立即开始 climate Pass-A 修复或其他真实 pass 迁移——而是**先休息一下，再启动新计划**，避免把"标杆"和"真实迁移"挤在同一个心智会话里造成新的疲劳。
4. WHEN 完成判定的 6 条铁标（见"引言/完成判据"）SHALL 全部为 ✅ 时，本计划方可标记为完成。

---

## 附录：与现有项目的衔接说明

- 本计划新增的代码**全部位于附加路径**，不修改现有 `view_f32` / `bind_map_data` / `write_f32_indexed` 等已有 API。
- 本计划完成后，**下一个计划**的工作是：基于本标杆模板，正式重构 `bind_map_data` 契约，把 MapData 降级为只读 view，恢复 climate Pass-A。**那是后续计划，不在本计划范围**。
- 本计划与 `.codebuddy/plan/dots-roadmap-to-gdextension/` 系列计划**并列**，不是它的子任务——它是为那个系列**提供基础设施**的一个独立短计划。
