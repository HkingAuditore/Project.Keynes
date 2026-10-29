# M2-19 §13.4 验收审计 + catalog 测试

| 项目 | 内容 |
|---|---|
| 里程碑 | [M2](../22-cell-program-cap-removal-plan-v3.md) §13.4 |
| 日期 | 2026-10-27，Asia/Hong_Kong |
| 交付 | `ideology_cell_layer_catalog_test.gd`（9 checks）+ 两个只读 bridge |
| 审计结果 | **§13.4 列出的 11 个测试，此前一个都不存在** |
| 结论 | 补了 1 个，**10 个仍未实现**——这是 M2 最大的一段验收缺口 |

## 1. 审计：方案的 11 个测试 vs 实际

| 拟新增测试（§13.4） | 状态 |
|---|---|
| `ideology_cell_layer_catalog_test.gd` | ✅ **本轮新建** |
| `ideology_cell_layer_numeric_test.gd` | ❌ 缺失 |
| `ideology_cell_layer_unbounded_test.gd` | ❌ 缺失 |
| `ideology_cell_layer_invalidation_test.gd` | ❌ 缺失 |
| `ideology_cell_layer_worker_test.gd` | ❌ 缺失 |
| `ideology_cell_layer_timing_test.gd` | ❌ 缺失 |
| `ideology_cell_layer_ack_test.gd` | ❌ 缺失 |
| `ideology_cell_layer_save_golden_test.gd` | ❌ 缺失 |
| `ideology_cell_layer_idle_test.gd` | ❌ 缺失 |
| `ideology_cell_layer_explain_test.gd` | ❌ 缺失 |
| `ideology_cell_layer_budget_test.gd` | ❌ 缺失 |

实际存在的 9 个 `ideology_cell_layer_*` 测试覆盖的是**另一些维度**（合并公式、枚举并集、分片、ADR02、e2e、M0 探针），与方案列出的清单**几乎不重叠**。

**这是本轮最重要的发现，也是最需要如实报告的差距。**

## 2. 为什么先做 catalog

在 11 个里，`catalog` 对应的是 **I01「一个 program 一个 backend」**——方案 §4.5 定为硬不变量，而**运行时从未断言过**。

这个不变量被破坏的形态极其隐蔽：若一个 program 同时走实例与派生，效果会被应用**两次**，数字看起来合理，没有任何报错。

## 3. 实现方式

新增两个**只读** bridge：

| Bridge | 作用 |
|---|---|
| `probe_cell_program_backend(facts)` | 对一组事实调用真实的 `decide_cell_program_backend`，返回 backend/reason/detail |
| `get_cell_program_rollout()` | 报告当前里程碑启用的 selector 种类 |

测试的四组断言：

| 组 | 断言 |
|---|---|
| **A** | 合格的永久领土程序 → `DerivedCell`，且无 legacy reason |
| **A1** | 同一组事实两次 → 同一结论（否则 I01 不可观测） |
| **A2** | **改一个事实（永久 → 持续 30 天）→ 结论翻转为 `EffectInstance`** |
| **C** | 未知 selector kind 被**拒绝**，不默认为某个 backend |
| **D** | 能力与 rollout 分开：rollout 全关（`enabled_kinds=[]`）时能力仍是 `DerivedCell` |

**A2 是关键**：没有它，「合格程序 → DerivedCell」可能只是常量断言。

## 4. 一处必须放弃的设计

原计划要实现 `describe_cell_program_backends`（遍历编译后的 catalog，统计 DerivedCell / EffectInstance，断言两者之和等于总数且无交集）。

**它需要三个不存在的 EffectRuntime 访问器**：`program_count_for_backend_report`、`program_key_at`、`program_describe_backend_probe`。

我选择**不做**，并在头文件与测试里都写明原因。代价是：

> **「运行时 catalog 的 backend 分布与静态工具一致」这条断言仍然缺失。**

静态工具 `m1_backend_coverage.py --check` 仍覆盖内容侧的 241/47 分类，但**没有任何测试证明运行中的构建与该分类一致**。

## 5. 过程中修掉的两个自己的错误

| 错误 | 修正 |
|---|---|
| 断言 `reason == "none"` | 实际是**空字符串**（`cell_program_eligibility.h:349`），是我误读 |
| 对 `cell_program_legacy_reason_name()` 的返回值调用 `.c_str()` | 它已返回 `const char*` |

## 6. 验证

| 项 | 值 |
|---|---|
| catalog 测试 | **9 checks, 0 failures** |
| 纯核门禁 | oracle 735 / cap_removed 12 / eligibility 56 / cost_model 28 / materializer 65 / shard 56 / ceiling 35 |
| 覆盖率门禁 | 6/6 |
| 构建 | exit 0 |

## 7. 我建议的后续优先级

按「不变量重要性 × 当前缺口」排序：

| 优先级 | 缺失测试 | 为什么优先 |
|---|---|---|
| 1 | `unbounded_test` | 31/32/33/200/1000+ **真实命中且零实例**——这是方案的核心承诺，目前只有纯核证据 |
| 2 | `numeric_test` | VM/adapter/term、混合 scope、Q16 与 clamp——数值正确性的最后一道 |
| 3 | `invalidation_test` | 精确/保守失效、false→true——失效错了会静默用旧值 |
| 4 | `worker_test` | 四种权威组合——需要 worker 夹具（已知阻塞） |
| 5+ | 其余 | 保存恢复、explain、budget、idle、ack、timing |

**注意 `worker_test` 依赖那个反复出现的夹具缺口**，短期无法完成；其余可以在裸 `SceneTree` 里做。

## 8. 局限

- 只补了 1/11。
- 放弃的 `describe` 桥意味着「运行时与静态工具一致」无断言。
- `probe_cell_program_backend` 只接受单个 command，无法表达「多命令程序」的判定。
- 未验证 `enabled_kinds` 在 rollout 开启后是否真的列出 12——因为开启会影响 e2e，本轮没做。

## 9. 复算方式

```powershell
$exe = 'D:\Godot\Godot_v4.6.2-stable_win64.exe\Godot_v4.6.2-stable_win64.exe'
Start-Process -FilePath $exe -NoNewWindow -Wait -PassThru `
  -ArgumentList '--headless','--path','Project/project-keynes',
    '-s','tests/ideology/ideology_cell_layer_catalog_test.gd'
# => 9 checks, 0 failures; rollout=0 enabled_kinds=[]
```
