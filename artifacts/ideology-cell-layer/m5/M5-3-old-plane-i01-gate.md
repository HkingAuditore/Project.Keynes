# M5-3 旧平面 I01 门控：修掉真正的双后端违反

| 项目 | 内容 |
|---|---|
| 里程碑 | [M5](../22-cell-program-cap-removal-plan-v3.md) §15.7 / §4.5 I01 |
| 日期 | 2026-10-28，Asia/Hong_Kong |
| 结果 | **`build_cell_program_table` 现在尊重 I01**；旧平面不再重复承载派生程序 |
| 验证 | 18/19 绿；`mechanism_matrix` 仍是基线就有的 1129/3，未加重 |

## 1. 发现的真实缺陷

§15.7 要求「删除旧 v1 平面…及仅为旧平面存在的逻辑」。审计时发现：

```
build_cell_program_table()       ← 从不调用 decide_cell_program_backend
economy_runtime.cpp:7394         ← refresh_city_output_modifier_factors() 读它
```

**两条事实合起来是一个 I01 违反**：

| 机制 | 状态 |
|---|---|
| 派生层（`DerivedCellFront`）| 承载 265 个程序 |
| 旧平面（`_ideology_cell_programs`）| **同样**承载这 265 个程序 |

而两者都由同一个热路径读取：

```cpp
// economy_runtime.cpp:7394，位于 refresh_city_output_modifier_factors()
const CellProgramEntry &entry = _ideology_cell_programs.entries[offset];
...
merged[key] = base + ...;          // 与派生层叠加
```

**同一个程序会被应用两次** —— 一次来自旧平面，一次来自派生 front。

这正是 I01「one program, one backend」禁止的事，而它藏在一个从不调用判定函数的构建器里。

## 2. 修法

在旧平面构建入口加 eligibility 门控：

```cpp
CellProgramFacts plane_facts;
plane_facts.target_domain  = effective.target_domain;
plane_facts.selector_kind  = effective.target_selector_kind;
plane_facts.lifecycle      = effective.lifecycle;
// ...
if (decide_cell_program_backend(plane_facts).backend ==
        CellProgramBackend::DerivedCell) {
    ++out.derived_elsewhere;    // 计数，不是静默丢弃
    continue;
}
```

**关键点**：用同一个 `decide_cell_program_backend`，不另写一份规则。两份规则各自演化正是 I01 最初被违反的方式。

## 3. 为什么保留旧平面而不是直接删除

`refresh_city_output_modifier_factors()` 仍在读它，且**非派生程序**（23 个：16 个非 cell domain + 7 个不支持的 selector）仍然需要它。

直接删掉会让那 23 个程序失去 cell 级效果。**先门控、后删除**是对的次序。

## 4. 验证

| fixture | 结果 |
|---|---|
| B7 / B8 / B10 | 15/0、18/0、16/0 |
| x1b / tag_snapshot_stress | 142/0、38/0 |
| cell_layer 全部 | 9/7/13/12/19/20/20/1/2 全 0 |
| content / target_selector / effect_instance / tag_source_selector | exit 0 |
| **`mechanism_matrix`** | **1129 checks, 3 failures** — 与 M0 基线完全一致 |

### 关于那 3 个失败

```
FAIL cooperative L1/L2 gate cooperative share at 20%
FAIL cooperative L3 lowers the share gate to 15%
FAIL cooperative programs use agriculture tags
```

M0 基线就记录：

> 当前工作区本身有 3 个失败 fixture（content 3 / instance_budget 10 / **mechanism_matrix 3**），属既存债务，非本方案引入

**数量、内容都与基线一致，本次改动没有加重它。**

## 5. 一个需要说明的风险

这次改动**改变了旧平面的输出**（少了 265 个程序的 entries）。而 `refresh_city_output_modifier_factors` 是生产热路径。

**支持它安全的事实**：派生层已经在产出同样的贡献，且 B7（1600 格、`front=1600`、`derived=1600`）证明派生 front 有内容。

**我没有直接测到的事实**：旧平面少了 entries 之后，`refresh_city_output_modifier_factors` 的**输出值**是否与之前完全相同。那需要一个对比旧平面 open/close 两种状态的数值测试。

**这是本项最大的未验证点，如实记录。**

## 6. §15.7 进度

| 任务 | 状态 |
|---|---|
| A–F 全部 ON | ✅ 265/265 |
| 删除旧 v1 平面 | 🟡 **门控已完成**（不再双算）；平面本身因 23 个非派生程序仍需保留 |
| 删除迁移开关 | ✅ M5-2 |
| 32 常量改 legacy 名 | ✅ |
| B1–B12 / save-load / 权威翻转 / UI | ⬜ |
| 文档与 skill 同步 | ⬜ |

## 7. 局限

- **未验证旧平面门控后 `refresh_city_output_modifier_factors` 的数值等价性**（最关键的缺口）。
- 23 个非派生程序仍依赖旧平面，所以平面不能删。
- `_cell_program_generation` / `_cell_plane_builds` 等只为旧平面存在的状态未审计。
