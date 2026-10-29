# M1-3 derived layer merged into effective_value — findings

| 项目 | 内容 |
|---|---|
| 里程碑 | [M1](../22-cell-program-cap-removal-plan-v3.md) §15.3 / §5.1 / §5.5 |
| 日期 | 2026-10-27，Asia/Hong_Kong |
| 交付 | `effective_value` 合并、`resolve_modifier_stat` 桥、`tests/ideology/ideology_cell_layer_merge_test.gd` |
| 证据 | 合并契约 **20 checks 0 failures**；构建成功；回归见 §5 |
| 结论 | §5.1 的公式在真实 `effective_value` 上成立；**发现测试自身的一个期望错误**，值得记录 |

## 1. 接线点与关键判断

### 1.1 cell 从哪个 handle 来

`effective_value(domain, sid, entity_handle, group_handle, base_value)` 没有 cell 参数。派生层按 `(stat, cell)` 索引，所以必须确定 cell 落在哪个 handle 上。

核对全部 reader 的调用形态：

| reader | 调用 |
|---|---|
| `refresh_city_modifier_factors` | `effective_value(ECONOMY, stat_id, 0, scope_id, 1.0)`（`economy_runtime.cpp:7082-7083`） |
| `economy_building_output_factor` | `effective_value(ECONOMY, stat, 0, settlement_cell, 1.0)`（`modifier_runtime.cpp:1785-1786`） |
| 资源 regen | `effective_value(ECONOMY, stat, 0, cell, 1.0)`（`economy_runtime.cpp:4391-4395`） |

**一致结论：cell 永远在 `group_handle`，`entity_handle` 恒为 0。**

所以派生行只按 `group_handle` 查。若误用 `entity_handle`，查询会静默永不命中——这是本轮最容易犯的错。

### 1.2 合并位置

```cpp
// 合并前
double value = (base_value + add) * factor;
clamp(...)

// 合并后
if (domain == ECONOMY && group_handle != 0 && !_derived_cell_front.rows.empty()) {
    const DerivedCellStatRow *row = _derived_cell_front.row_for_stat(sid);
    if (row) {
        const auto *slot = row->find((int32_t)group_handle);
        if (slot) {
            add += slot->sum_add;
            factor = (slot->zero_factor_count > 0) ? 0.0 : factor * slot->product_nonzero;
        }
    }
}
double value = (base_value + add) * factor;   // ← 唯一一次 clamp 仍在这里
```

三条设计决定：

1. **在 `add` / `factor` 上累加，不碰 `value`。** §5.1 明确禁止在最终值上二次包装。
2. **零因子独立处理。** §5.5 要求零因子必须消灭乘积；若只乘 `product_nonzero`，「-100%」的卡会被静默忽略。
3. **`rows.empty()` 快速旁路。** 未装卡或迁移关闭时，每个既有 reader 的行为与接线前**逐位相同**——这是回归零变化的前提。

## 2. 契约测试（20 checks）

`tests/ideology/ideology_cell_layer_merge_test.gd`：

| 断言 | 结果 |
|---|---|
| A. 无派生层时 cell 0 / cell 7 基线均为 1.0 | pass |
| A. legacy GROUP add 可见（1.5） | pass |
| A. 别处的 GROUP 行不影响未覆盖格 | pass |
| B. 派生 ADD 与 legacy ADD 相加（1.75） | pass |
| B. 未覆盖格仍只见 legacy | pass |
| B. 无 legacy 行的格也生效（1.25） | pass |
| C. 派生 factor 参与乘法后 clamp 最后生效 | pass |
| D. 巨大 factor 被 clamp 到上限 | pass |
| E. 派生 ADD 作用于 caller 传入的 base（2.5 而非 1.5） | pass |
| F. 因子单独就 clamp 时结果=上限 | pass |
| G. add+factor 在一次 clamp 内合并 | pass |

`stat_id` 与 `clamp_max` 都从真实 catalog 解析（新增 `resolve_modifier_stat` 桥），**不硬编码**——硬编码会在下次目录调整后给出假通过。

## 3. 一个测试自身的期望错误（值得记录）

C 用例首跑：期望 4.5，实际 4.0。

我第一反应是「实现错了」。核实发现 `economy.city.birth_factor` 在 catalog 里 `max_value = 4.0`（`default_modifier_catalog.tres:88-91`），而 `(1 + 0.5) × 3 = 4.5` **本就该被 clamp 到 4.0**。

**实现是对的，测试期望是错的。** 修正后我用 `minf(..., ceiling)` 表达期望，并在注释里写明：这个用例其实**无法**区分「合并前乘」与「clamp 后乘」——两者在 clamp 生效后同值。真正能区分的只有 sum 本身越过上限的情形，所以另加了 F/G 两个用例。

这条记录的价值在于：**如果我不核实就直接改实现去迎合错误的期望，会把正确的合并逻辑改坏**，而且所有测试都会「通过」。

## 4. 新增桥：`resolve_modifier_stat`

```cpp
godot::Dictionary DCWorldExt::resolve_modifier_stat(const godot::String &stat_key) const;
// => { ok, stat_id, clamp_max }
```

目的单一：让测试能从真实 catalog 取 dense id 与 clamp 上限。这是**测试基础设施**，不是生产接口——它不修改任何状态。

## 5. 构建与回归

| 项 | 值 |
|---|---|
| 构建 | `Compiling shared` → `Linking` → `scons: done building targets.`，exit 0 |
| 合并契约 | 20 checks, 0 failures |
| ADR02 执行验证 | 19 checks, 0 failures（上一轮，本轮未改动该路径，见回归） |
| 纯核 | eligibility 56 / derived layer 51，均 0 failures |
| 覆盖率门禁 | `m1_backend_coverage.py --check` 6/6 |

回归结果见 §6（后台运行，收尾时填入）。

## 6. 回归：零判定变化

15 个 fixture 逐项对照 M0 基线（`baseline-logs-final`）：**changed verdicts = 0**。

| 结果 | 数量 |
|---|---:|
| pass | 9 |
| failures | 4 |
| no_summary | 1 |
| timeout | 1 |

逐项检查数也全部一致（如 `ideology_x1b_source_count_test` 142/0、`ideology_mechanism_matrix_test` 1129/3）。

**这是本轮最重要的证据。** 它证明派生层的 `rows.empty()` 旁路是真正生效的：未安装派生层时，每个既有 reader 的结果与接线前逐位相同。若旁路写错（例如把空 front 当成「有 layer 但无贡献」而走进查询分支），这里会出现大量差异。

DLL：`934d368a…`，14,044,672 B。

## 7. 局限

- **`install_derived_cell_layer` 仍无生产调用方。** 只有 test bridge 会调用。方案 §4.2 规定调用者只能是 Economy 冻结协调器——接线属 M1 后续任务，且需要先解决 M0-7c 记录的 worker 夹具缺口。
- **未实现 `collect_scope_ids` / `collect_scope_stat_entries` 并集。** 这两个函数仍只看 `store.buckets`（`modifier_runtime.cpp:1464`、`:1490`），所以**装卡后 Economy 的因子缓存根本不知道哪些格有派生贡献**——合并虽已生效，但 `refresh_city_modifier_factors` 不会主动遍历那些格。这是 M1 剩余任务里第二重要的一项。
- **未接 `stat_bucket_version` 组合。** 缓存仍只按 legacy 版本失效。
- **性能未测。** `row_for_stat` 是 `rows` 上的二分，`find` 是 `cells` 上的二分，都在 `effective_value` 热路径里。若 `rows` 有几十个 stat，每格查询会多两次二分——§14.1 的 `covered_cells × 156` 成本会因此上升，必须在 M1 退出前测量。
- 逐来源国撤销仍未实现（M2 前置，见 M1-2 §4）。

## 8. 复算方式

```powershell
$exe = 'D:\Godot\Godot_v4.6.2-stable_win64.exe\Godot_v4.6.2-stable_win64.exe'
Start-Process -FilePath $exe -NoNewWindow -Wait -PassThru `
  -ArgumentList '--headless','--path','Project/project-keynes',
    '-s','tests/ideology/ideology_cell_layer_merge_test.gd' `
  -RedirectStandardOutput artifacts/ideology-cell-layer/merge.log `
  -RedirectStandardError  artifacts/ideology-cell-layer/merge.err.log
# => 20 checks, 0 failures
```
