# M1-9 production materializer & rollout gate — findings

| 项目 | 内容 |
|---|---|
| 里程碑 | [M1](../22-cell-program-cap-removal-plan-v3.md) §4.2 / §4.5 / §8.1 / §15 |
| 日期 | 2026-10-27，Asia/Hong_Kong |
| 交付 | `derived_cell_materializer.{h,cpp}`、生产接线、`CellProgramRollout` 里程碑闸门 |
| 证据 | 物化器 **53 checks 0 failures**；判定器 56；分片 56；派生层 51；回归 **零判定变化** |
| 结论 | 物化链已打通；**发现一个方案级的里程碑顺序冲突并修复** |

## 1. 本轮解决的问题

到 M1-8，所有零件都在但**没有一个生产调用方**：

| 零件 | 状态 |
|---|---|
| `decide_cell_program_backend` | 有，测试 56 checks |
| `DerivedCellFrontBuilder` | 有，测试 51 checks |
| `install_derived_cell_layer` | 有，ADR02 执行验证 19 checks |
| **把它们串起来的人** | **没有** |

所以运行时**32 格限制从未被取消**——没有任何代码把已装备的卡变成派生行。本轮补的就是这个中间层。

## 2. `derived_cell_materializer`

`build_derived_cell_front` 接收「已解析的 program 事实 + 已解析的目标格 + 已解析的 term」，输出 front。

它**不读** `NativeIdeologyRuntime` / `EffectRuntime` / `NativeEconomyRuntime` 状态，也不决定策略——这样它能用纯数据测试（§13.1 第 1 层），且资格判定保持单源（§4.5）。

### 测试覆盖（53 checks）

| 断言组 | 内容 |
|---|---|
| A | **33 格全部成为行，`truncated == 0`**（32 正是旧上限） |
| A | **6400 格全国覆盖，每格都有行** |
| B | EffectInstance program 不产生任何行（I01） |
| C | ADD 求和、factor 连乘、零因子单独计数 |
| D | 多命令 program 的 term 全部折叠 |
| E | **两个来源国影响同一格时相乘**（not 相加） |
| F | 相同内容跳过（I13）；内容变化不跳过 |
| G | 空结果是合法 front（§17） |
| H | 格升序，保证二分查找有效 |
| I | 负 stat 计数不落行；负格丢弃 |

## 3. 发现并修复：里程碑顺序冲突

生产接线后回归**出现新失败**：

```
ideology_x1b_source_count_test   M0=pass/142/0  →  142/5
```

5 条失败全是实例断言（T1/T2/T3/T8），根因是**实例数为 0**——因为 kind 16（`TAG_SOURCE_COUNT`）被判定器判为 DerivedCell，不再创建实例。

**这不是 bug，是我的接线提前了一个里程碑。** 方案 §15 的分批是：

| 里程碑 | 内容 |
|---|---|
| M2 | A/B，`OWN_TERRITORY` 常数 |
| M3 | C/D，`OWN_TERRITORY` 连续/条件 |
| **M4** | **E/F，来源计数与来源环** |

而我的判定器在 M1 就把 kind 16 启用，等于跳过了 M4 的内容批次。

### 修法：能力判定与 rollout 分离

新增 `CellProgramRollout` 枚举 + `cell_program_rollout_enabled()`：

- `decide_cell_program_backend` 只回答「**能否**派生」——这是 program 与 backend 的属性，不应随里程碑变化；
- rollout 闸门由**调用方**施加，`kCellProgramRollout = Off` 时生产路径一行不动。

**中间我犯过一次错，值得记录：** 首版把 rollout 检查塞进判定器内部，结果 `Off` 一设置，**56 条判定器测试全挂**（19 failures）。那暴露出把「能力」与「是否启用」混在一起会让能力列不可测——正是方案 §4.5 要求单一判定列时要避免的耦合。

## 4. 生产接线

`collect_effect_activations` 增加可选 `out_derived`；`reconcile_effect_activations` 传入真实容器并调用物化器 → `install_derived_cell_layer`。

**一个必须修的安全缺陷：** 首版 `out_derived->push_back` 在 `out_derived == nullptr` 时会崩，而所有既有调用点都不传它。加了 `out_derived != nullptr` 前置守卫——**没传容器的调用方必须保持旧行为，而不是丢失派生贡献**。

新增成员：
- `_execution_contract_hash`（§11.5 要求独立于 Modifier catalog hash）
- `_last_derived_materialize`（§12.4 诊断，含 `truncated`）

## 5. 当前状态：链路通，但默认关闭

| 环节 | 状态 |
|---|---|
| 判定 → 贡献收集 → 物化 → 安装 | ✅ 全链路已接通 |
| `kCellProgramRollout` | **`Off`** |
| 生产行为 | **与 M0 基线逐位一致** |

`Off` 是刻意的。方案 §15.4 要求「可在满足发布条件后**单独评审本批 ON**」——开关是一次可评审的常量变更，不是接线的一部分。保持 `Off` 让 M0 基线在层还在验证时保持逐位一致。

## 6. 构建与回归

| 项 | 值 |
|---|---|
| 构建 | `scons: done building targets.`，exit 0 |
| 新 DLL | `8563834a…`，14,076,416 B |
| 回归 | **changed verdicts = 0**（15 fixture 逐项与 M0 基线一致） |
| 门禁 | materializer 53 / eligibility 56 / shard 56 / derived layer 51，全 0 failures |

## 7. 局限

- **`rollout = Off` 意味着本轮没有改变任何玩家可见行为。** 这是设计，但也意味着「取消 32 格限制」在运行时仍未发生——它现在只是**一次常量变更即可发生**。
- **物化器每个 program 独立 fold，跨 program 的来源国被合并成一行**（`source_country = 0`）。§8.1 的逐来源撤销仍需 M2。
- **`cell_program_facts_for` 的 `row.value_mode = 1` 是硬编码**，因为内容里城市命令一律用栈顶。若将来出现 `VALUE_CONSTANT` 命令，这里需要读真实字段而不是假定。
- **`_execution_contract_hash` 目前只写入 front，未参与存档版本检查**（§11.5 的完整体现在 M2）。
- 物化器未测性能。它在 reconcile 路径上，每次装卡变化触发一次；`content_digest` 与 fold 都是 O(行数)，M1-5 已记录该项未测。

## 8. 复算方式

```powershell
cd gdext
$vcvars = 'C:\Program Files\Microsoft Visual Studio\2022\Professional\VC\Auxiliary\Build\vcvars64.bat'
cmd /c "call `"$vcvars`" >nul 2>&1 && cl /std:c++17 /O2 /EHsc /W4 /I src tests\derived_cell_materializer_test.cpp src\derived_cell_materializer.cpp /Fe:..\.codex-tmp\materializer_test.exe /Fo:..\.codex-tmp\"
& ..\.codex-tmp\materializer_test.exe    # => 53 checks, 0 failures
```
