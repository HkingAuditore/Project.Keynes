# M1-1 backend decision column — findings

| 项目 | 内容 |
|---|---|
| 里程碑 | [M1](../22-cell-program-cap-removal-plan-v3.md) §15.3 task 1 / §4.3–§4.5 |
| 日期 | 2026-10-27，Asia/Hong_Kong |
| 交付 | `gdext/src/cell_program_eligibility.h`、`gdext/tests/cell_program_eligibility_test.cpp`、`Project/project-keynes/tools/ideology/m1_backend_coverage.py` |
| 证据 | 纯核 **56 checks 0 failures**；真实内容 **6/6 门禁通过**；GDExtension 构建成功；回归 **82 checks 0 failures** |
| 结论 | §4.5「单一判定列」已落地并可用真实内容验证；发现 4 处原方案未明确的语义 |

## 1. 交付内容

### 1.1 `cell_program_eligibility.h`（纯核，无 Godot 依赖）

方案 §4.5 的硬要求是「一个**无运行时状态依赖**的原生编译／资格入口」。v1 的 `build_cell_program_table` 做不到：它在遍历活国家状态时才判定，需要 `_configured`、国家槽、已装备的 `IdeaState` 和一个能回答 `family_effect_metadata_pod` 的 `EffectRuntime`。

新头文件只吃**数据**：

```cpp
struct CellProgramFacts { target_domain, lifecycle, duration_days,
                          stack_policy, max_stacks, selector_kind,
                          reads_state, commands[] };
CellProgramDecision decide_cell_program_backend(const CellProgramFacts &);
```

返回 `backend`（`EffectInstance` / `DerivedCell`）+ `reason` + `detail`。纯函数，可被编译期 pass 与测试同时消费，不产生第二套算法。

### 1.2 纯核自测（§13.1 第 1 层）

`gdext/tests/cell_program_eligibility_test.cpp`，14 个用例 / **56 checks**，用手写事实表覆盖每条分支：

- 基线 program 判为 DerivedCell
- 死 `duration_days` 字段不阻断但被标记
- DURATION / EVENT_ONCE 被拒
- 非地块域被拒
- READ_STATE 被拒
- 四种 A–F selector 全部通过；七种其他 selector 全部拒绝
- 未解析 definition 被拒，且合成 definition 的失败信息点明陷阱
- 非 SUM term 被拒
- 多命令 program 要求全部合格（I01）
- 每个枚举值都有名字（缺失返回 `nullptr`）

编译：`cl /std:c++17 /W4` 零警告。

### 1.3 真实内容覆盖（`m1_backend_coverage.py`）

把 288 个 program 全部跑过判定器，输出 backend 列与理由分布。

## 2. 真实内容结果

```
programs: 288
  DerivedCell   : 241
  EffectInstance:  47
```

| 理由 | 数量 | 归属 |
|---|---:|---|
| `ramp_not_yet_supported` | 24 | **M3**（B/C 类，READ_METRIC） |
| `not_cell_domain` | 16 | 正常排除（国家/家族/建筑域） |
| `unsupported_selector` | 5 | H 类诊断探针 + G 类 anchor |
| `stacked` | 2 | 真正的多层实例 |

M2 范围（A–F 减 ramp）= **241，全部 DerivedCell**。

## 3. 四处原方案未明确的语义（本轮发现）

### 3.1 `value_mode = 1` 不等于「非常数」

首版判定器把 `value_mode != VALUE_CONSTANT` 当作「幅度不是常数」，结果 **262/288 program 被拒**。

真相：`vm_value_for`（`effect_runtime.cpp:3055`）把 `VALUE_STACK_TOP` 解析为 `stack[sp-1]`，而内容的城市命令一律是

```
CONST(6554) → EMIT(0)     // 压栈一个常数
command value_mode = 1    // 取栈顶
```

所以幅度**确实是编译期常数**，只是经由 VM 栈传递。判定器新增 `stack_top_is_constant`（产生栈顶的指令是否为 `CONST`），并区分：

- `VALUE_STACK_TOP` + CONST 产生 → 常数，通过；
- `VALUE_STACK_TOP` + READ_METRIC 产生 → 动态，归 `RampNotYetSupported`；
- 其他非恒定来源 → `NonConstantValueMode`（永久排除）。

**这条如果不发现，M2 会把 241 个 A/B/D program 全部误判。**

### 3.2 READ_METRIC ramp 是「延后」，不是「排除」

24 个 B/C program 的幅度是 `CONST → READ_METRIC → CONST → MIN → MUL_Q16 → EMIT`，依赖活指标。

方案 §1.2 要求**全部 265 个** A–F 最终进入派生路径，所以把它们记成「非常数、永久排除」会让覆盖报告少 24 个在范围内的 program。新增 `RampNotYetSupported` 理由，detail 直接写明「需要 M3 连续输入（§6.6）」。

### 3.3 `REFRESH` 不是 stacked

`maritime_insurance_l1/l2/l3` 有 `stack_policy = 1`（REFRESH），首版被拒。

但 `ideology_runtime.cpp:2139-2141` 只在 `stack_policy == 2`（ADD_STACK）时分层：

```cpp
const bool layered = metadata.stack_policy == 2;
const int32_t layers = layered ? clamp(templ.stacks, 1, max_stacks) : 1;
```

`REFRESH` + `max_stacks == 1` 恒为一个实例。判定条件改为 `stack_policy == 2 || max_stacks > 1` 后，这 3 个 program 正确进入 DerivedCell，同时**保留**了死字段标记（它们的 `duration_days = 30` 在 `lifecycle = 0` 下确实无效）。

### 3.4 合成 definition 的判定必须让 `.tres` 优先

`economy.city.birth_factor` 与 `economy.city.output_factor` **同时**拥有 `.tres` 定义和合成模式。首版只按模式匹配，把合成数报成 **110**；改为「先查 `.tres`，不存在才判合成」后回到 **101**，与 M0-1 完全一致。

这条不修，覆盖报告会声称「有定义缺失」，而那些定义其实存在。

## 4. 门禁结果

```
[ok] A-F count == 265                   actual=265
[ok] M2 scope all DerivedCell           actual=241
[ok] ramp deferred == 24 (plan B+C)     actual=24
[ok] no unexplained legacy              actual=0
[ok] no unresolved command refs         actual=0
[ok] synthesis used (101 refs)          actual=101
```

第六条同时验证了 M0-1 的合成结论在 M1 的实现里仍然成立。

**关于第二批判据**：初版把「A–F 全部 DerivedCell」当 M1 退出条件，实测必然 241≠265 而永远失败。方案 §15 把常数族放 M2、ramp 放 M3，所以 M1 该证明的是「**没有 program 因未解释的理由落回实例后端**」，而不是「全部派生」——后者是 M5 的判据。已按此修正。

## 5. 构建与回归证据

| 项 | 值 |
|---|---|
| 构建命令 | `scons platform=windows target=template_debug dev_build=no -j8` |
| 构建输出 | `Compiling shared src\world_ext.cpp` → `Linking Shared Library` → `scons: done building targets.` |
| 退出码 | 0 |
| 新 DLL SHA-256 | `73bd1a3626ad63bf8db3da09b6bb70255e034ea7eefb9e4b5acfca3ed176460e` |
| 旧 DLL SHA-256 | `1d0eba7ae4c4b2b0bf6094db4a865ee846bff5b0f6e1ff3901c8fbec56ddf559` |
| 新 DLL mtime (UTC) | 2026-10-26T16:46:01Z |
| 尺寸 | 14,013,952 B（与旧一致，符合纯头文件新增的预期） |
| 回归 | `ideology_runtime_test`: **82 checks, 0 failures** |

方案 §14.4 明确「改动前后的 DLL 必然不同，不能要求同一 DLL 二进制」——这里是同一份源码加一个未使用的头文件 include，尺寸未变，行为未变，回归通过。

## 6. 局限

- **判定器尚未被生产路径调用。** 目前只有 `world_ext.cpp` 的一行 `#include`；`build_cell_program_table` 仍走旧的 inline 判定。接线属于 M1 的后续任务（backend 列必须驱动实例收集与预算），本轮只交付并验证了判定本身。
- `all_terms_sum` 在 Python 侧恒为 `true`，依据是 `modifier_catalog.gd:448-457` 对 `city.` / `economy.city.` 前缀强制 SUM。**未逐 stat 核对 `.tres` 的 aggregate_policy**。
- 42 个 good/need 类的 term 解析依赖合成规则，`--check` 只验证了「无未解析引用」，未验证 term 的具体 stat_id 与运行时 dense id 一致——那需要真实 catalog 输出，属于 M1 后续。
- 未测 `unentered_level_mask` / copier 相关的 program 变体：判定器只看 program 元数据，不看 copier 复制来源。方案 §4.4 要求「copier 以被复制 program 的已编译能力为基础」，这一条尚未实现。

## 7. 复算方式

```powershell
# 纯核自测
cd gdext
cl /nologo /std:c++17 /EHsc /W4 /I src tests\cell_program_eligibility_test.cpp `
   /Fe:..\.codex-tmp\eligibility_test.exe /Fo:..\.codex-tmp\
& ..\.codex-tmp\eligibility_test.exe      # => 56 checks, 0 failures

# 真实内容覆盖
python Project/project-keynes/tools/ideology/m1_backend_coverage.py --check
```
