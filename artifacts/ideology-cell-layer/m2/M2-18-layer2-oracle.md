# M2-18 §13.1 第 2 层：同输入逐格对照 — 735 checks

| 项目 | 内容 |
|---|---|
| 里程碑 | [M2](../22-cell-program-cap-removal-plan-v3.md) §13.1 第 2 层 / §13.2 |
| 日期 | 2026-10-27，Asia/Hong_Kong |
| 交付 | `gdext/tests/derived_layer_oracle_test.cpp` |
| 结果 | **735 checks, 0 failures** |
| 结论 | 补齐了方案要求但从未实现的第二层验证 |

## 1. 缺口是什么

§13.1 要求四层验证，其中第 2 层是：

> **同输入对照**：冻结完全相同的 ProgramSet 与 raw input，将旧 evaluator／adapter 与新贡献 sink **逐格比较**。

而 §13.2 补充了 oracle 规则：

> 31/32 格用旧实例路径作金标准；**33/200/1000+ 格不能只比较两个已经产生不同经济反馈的世界**。使用同一份冻结输入和测试专用参考 evaluator，遍历完整候选，不创建正式运行时实例。分别验证：旧 cap 子集在新集合中、子集数值一致、新增目标数值符合独立期望。

**此前没有任何测试做这件事。** `ideology_cell_layer_merge_test.gd` 验证的是合并公式（A–E），但只在少数点上，没有遍历完整候选集。

## 2. 实现方式

测试内部构造**三个独立来源**，比较它们：

| 侧 | 构造方式 |
|---|---|
| **LEGACY** | `min(cells, 32)` 逐 program 截断，再折叠 |
| **DERIVED** | `build_derived_cell_front` 真实实现 |
| **REFERENCE** | 测试内独立折叠，**不读实现的结果** |

REFERENCE 是关键：它直接从贡献列表累加 add、连乘 factor，所以 builder 的折叠若有 bug，会表现为**不匹配**，而不是被镜像。

## 3. 七组断言

| 组 | 内容 | 断言数 |
|---|---|---:|
| **A** | 旧 cap 以下的 31 格，两侧数值**完全一致** | 32 |
| **B** | 32–199 共 **168 个新增格**逐一与 REFERENCE 相符，且 LEGACY 侧确无该格 | 506 |
| **C** | 集合包含性：1000 格时旧子集**全部存活**，无截断 | 3 |
| **D** | 31 / 32 / 33 边界：派生侧精确保持 n 格，旧侧从 33 起才截断 | 9 |
| **E** | 两来源同格相乘，且与 REFERENCE 一致 | 3 |
| **F** | 零因子两侧同归于 0，未受影响格保持原值 | 8 |
| **G** | 空候选两侧都为空，且不算截断 | 3 |

合计 **735**（B 组因逐格双向断言而最多）。

## 4. 为什么 B 组最重要

`admitted == 168`（200 − 32）这条断言直接回答方案的核心问题：

> **取消 32 上限后，第 33 到第 200 格是不是真的正确？**

它同时验证了三件事：
1. 这些格**存在**于派生集合；
2. 它们的值**等于独立计算的期望**；
3. 旧侧**确实没有**这些格（所以是「新增」而非「移动」）。

## 5. 与 §13.2 的对应

| §13.2 要求 | 本测试 |
|---|---|
| 31/32 格用旧实例路径作金标准 | A 组 |
| 33/200/1000+ 用参考 evaluator | B / C 组 |
| 旧 cap 子集在新集合中 | C 组（1000 格） |
| 子集数值一致 | A 组 |
| 新增目标数值符合独立期望 | B 组 |
| 不创建正式运行时实例 | 纯核，无 runtime |

## 6. 验证

| 项 | 值 |
|---|---|
| 检查数 | **735** |
| 失败 | **0** |
| 编译 | `cl` exit 0（`/W4` 无警告） |
| 依赖 | 纯核（`derived_cell_materializer.cpp` + 头文件），无 Godot |

## 7. 局限

- **REFERENCE 与 DERIVED 共享 `DerivedProgramContribution::Term` 结构**，所以若该结构本身的语义错了（例如 add 与 factor 的约定反了），两者会一起错。真正的独立性止于「折叠逻辑」，不包括「数据契约」。
- 未覆盖 `ramp` / `stacked` 等非派生路径（本测试只喂 DerivedCell 程序）。
- 未覆盖负值 base、极端 magnitude（已由 `materializer_test` 部分覆盖）。
- 未覆盖多 stat 交织。

## 8. 复算方式

```powershell
cd gdext
$vcvars = 'C:\Program Files\Microsoft Visual Studio\2022\Professional\VC\Auxiliary\Build\vcvars64.bat'
cmd /c "call `"$vcvars`" >nul 2>&1 && cl /std:c++17 /O2 /EHsc /W4 /I src tests\derived_layer_oracle_test.cpp src\derived_cell_materializer.cpp /Fe:..\.codex-tmp\oracle_test.exe /Fo:..\.codex-tmp\"
cd ..
& .\.codex-tmp\oracle_test.exe    # => 735 checks, 0 failures
```
