# M0-1 program inventory — findings

| 项目 | 内容 |
|---|---|
| 里程碑 | [M0](../22-cell-program-cap-removal-plan-v3.md) |
| 任务 | §15.2 M0 task 1 |
| 日期 | 2026-10-26，Asia/Hong_Kong |
| 工具 | `Project/project-keynes/tools/ideology/m0_program_inventory.py --check` |
| 产物 | `program_inventory.csv`（265 迁移 program）、`program_inventory_terms.csv`（325 term 行）、`program_inventory_report.txt` |
| 结论 | 方案 §2 的全部数字成立；但发现 2 处方案未覆盖的事实，见 §3 |

## 1. 断言结果

`--check` 内置 16 条基线断言，全部通过：

| 断言 | 值 |
|---|---|
| all programs | 288 |
| cell-domain programs | 272 |
| migration scope (A–F) | 265 |
| A / B / C / D | 129 / 12 / 12 / 41 |
| E / F | 66 / 5 |
| G / H | 2 / 5 |
| A+B+C+D | 194 |
| command references | 325 |
| selector 12 / 16 / 14 | 194 / 66 / 5 |

与方案 §2.2、§2.3、附录 B 完全一致。

## 2. 补充基线（方案未给出，本表作为 M1 输入）

### 2.1 ramp 分层的准确归属

| 类别 | metric | program 数 |
|---|---|---|
| C（逐格连续） | `cell.unemployment_q16` (22) | 9 |
| C（逐格连续） | `cell.manufacturing_building_count` (24) | 3 |
| B（国家标量） | `country.extractive_cell_count` (57) | 3 |
| B（国家标量） | `country.chained_cell_count` (59) | 3 |
| B（国家标量） | `country.silver_cell_count` (63) | 3 |
| B（国家标量） | `country.distinct_specialized_good_count` (67) | 3 |

合计 24 个 READ_METRIC 程序 = 12 B + 12 C。与 §2.2 一致。

### 2.2 TAG_SOURCE_COUNT 的实际参数分布

方案只给了 E=66。实际解码后：

| 维度 | 分布 |
|---|---|
| radius | 1→27 个，2→38 个，3→1 个 |
| source_cap | 2→3 个，3→60 个，6→3 个 |
| target_cap bit | **全部 66 个都是 0** |

最后一项很重要：**当前 66 个 E 类 program 没有一个使用了 legacy target cap 位**，全部依赖 `decode_source_count_selector` 的「0 == 默认 32」。所以 §6.3「忽略旧 target cap 位」在现有内容上不改变任何位模式，风险低于方案估计。

### 2.3 §4.4 资格阻断项

对 265 个迁移 program 逐条检查 `lifecycle`、`READ_STATE`、`stack_policy`、`value_mode`、命令 stacks：

| 阻断项 | 命中数 |
|---|---|
| `READ_STATE`（历史依赖） | 0 |
| `value_mode != 1` | 0 |
| 命令 stacks != 1 | 0 |
| `lifecycle != 0` | 0 |
| `stack_policy != 0`（REPLACE） | **3** |

唯一的阻断项就是 `maritime_insurance_l1/l2/l3` 的 `stack_policy=1`（REFRESH），而这 3 个 program 同时是 §3.1 的死字段案例。

**这意味着：只要把 §4.4 的措辞从「无 duration」改成「`lifecycle==PERMANENT`」，265 个 program 全部满足资格条件，无第二条例外。** 这是本里程碑最有价值的结论。

### 2.4 reader manifest

325 条命令引用全部解析到已知 reader 族，无 UNKNOWN：

| 族 | 引用数 | scope key | 失效来源 |
|---|---|---|---|
| `economy.city.building.<sector>_output_factor` | 130 | group | `building_output_stat_version` |
| `economy.city.output_factor` | 79 | group | `building_output_stat_version` |
| `economy.city.good.<good>.output_factor` | 42 | group | `collect_scope_stat_entries` + `stat_bucket_version` |
| `economy.city.birth_factor` | 30 | group | `collect_scope_ids` + `stat_bucket_version` |
| `economy.city.need.<need>.consumption_factor` | 29 | group | `collect_scope_ids` + `stat_bucket_version` |
| `economy.city.resource.<resource>.regen_factor` | 9 | group | inline `effective_value` per cell |
| `economy.city.resource.regen_factor` | 6 | group | inline `effective_value` per cell |

**全部 7 个族都是 `GROUP` scope，`group_handle` = settlement cell。** 方案 §8.1 说「按来源国家保留贡献」，这层与 group 维度正交，M1 的索引必须按 `(stat, group_cell)` 建 key，不能只按 `(stat, country)`。

## 3. 方案未覆盖的两处事实

### 3.1 G8：101 条（31%）definition 不在 `.tres` 里

方案 §2.3 把 325 条命令引用按 stat 族分类，隐含假设每个 `definition_key` 都能在 `default_modifier_catalog.tres` 里找到 term 展开。**实际不是。**

`modifier_catalog.gd:262-273` 在 `compile_native_catalog()` 里合成 5 组 stat：

```
economy.city.need.<need>.consumption_factor      (needs × 1)
economy.city.good.<good>.consumption_factor      (goods × 1)
economy.city.good.<good>.output_factor           (goods × 1)
economy.city.building.<type>.output_factor       (building_types × 1)
economy.city.resource.<resource>.regen_factor    (resources × 1)
```

`modifier_catalog.gd:503-554` 再为每个 card-targetable stat 合成**两个** definition：正体（ADD 1.0）与 `.cut` 孪生（SUBTRACT 1.0），两者 `policy=UNIQUE_SOURCE`、`max_stacks=1`、`default_duration=-1`。

本 inventory 的 term 来源统计：

| 来源 | 命令引用数 | 占比 |
|---|---|---|
| `.tres` 有显式 definition | 224 | 69% |
| GDScript 合成 definition | **101** | **31%** |
| 无法解析 | 0 | 0% |

**为什么这会影响方案：**

- 方案 §4.3 的 `CompiledCellProgram` 要求 `output_commands`「各自解析 definition 与 term」；
- 方案 §4.4 资格条件 3 要求「所有输出 stat 为 SUM，definition／term 已解析」；
- 方案 §4.5 要求「先解析统一 numeric 目录及 reader capability manifest」。

如果 M1 的编译器只读 `.tres`，这 101 条会在资格判定里被判为「definition 未解析」而 fail-closed，导致 **A–F 里至少 131 条命令引用无法迁移**（79 output + 42 good-output + 30 birth + 29 need 里的一部分），C 类 12 个 program 全部落空。

**处置：** 编译器的 definition 解析必须走 `compile_native_catalog()` 的输出（`definition_keys` / `term_stat_ids` / `term_operations` / `term_values`），而不是直接读 `.tres`。已登记为 checklist M0-9 G8。

另外注意 `.cut` 语义：ADD 1.0 vs SUBTRACT 1.0 的差异不是装饰。方案 §5.4 的 `scaled_add = term.add × stacks × magnitude`，在 `.cut` 上是 `1.0 × 1 × 0.05` 收进 `sum_add` 的负侧——**符号由 term operation 决定，不由 command magnitude 的符号决定**（command magnitude 被 clamp 在 [0,4]）。这是 M1 数值核必须先钉住的一条。

### 3.2 G9：一处源码注释与实现矛盾

`modifier_catalog.gd:497-502` 的注释：

> Which city stats a CARD may target. The criterion is "does gdext read this
> stat per cell", not "is it registered": `_city_resource_regen_stat_ids` and
> the aggregate `economy.city.output_factor` have zero read sites, so a card
> aimed at them would compile, store a row, and change nothing.

但实际有读点：

| stat | 真实读点 | 证据 |
|---|---|---|
| `economy.city.output_factor` | `economy_building_output_factor`，`effective_value(ECONOMY, _building_output_stat_ids[1], 0, settlement_cell, 1.0)` | `modifier_runtime.cpp:1785-1786`；由 `economy_runtime.cpp:11135`、`11309`、`world_ext_modifier.cpp:573` 调用 |
| `economy.city.resource.regen_factor` | `advance_worker_resource_reserves` 逐格 `effective_value(ECONOMY, generic_stat, 0, cell, 1.0)` | `economy_runtime.cpp:4391-4392` |
| `economy.city.resource.<resource>.regen_factor` | 同上 | `economy_runtime.cpp:4394-4395` |

`grep _city_resource_regen_stat_ids` 在 `gdext/src` 下**零命中**，说明注释引用的那个符号已经不存在——这是一条过期注释，不是实现缺陷。

**为什么重要：** 方案 §2.3 把这 79 + 15 条引用的读者标为 `economy_building_output_factor` 与「资源恢复；含 worker 消费」，与实现一致。**方案是对的，注释是错的。** 但如果 M1 的实现者按注释判断「这些 stat 是死的、不必接入」，会有 94 条命令引用的派生贡献被静默丢弃——恰好落在 §7.4「空闲」与 §8.5 的接入面清单盲区。

**处置：** 修正该注释；并把「stat 是否有读点」做成编译期断言（M1），禁止再用注释维护这个事实。已登记为 M0-9 G9。

## 4. 对方案 §14.1 的补充确认

`refresh_city_modifier_factors` 的每格成本为：

```
1 (birth) + 1 (general consumption) + need_count (20) + good_count (134) = 156
```

其中 need/good 计数来自 `Project/project-keynes/data/economy/needs/` (20 个 `.tres`) 与 `Project/project-keynes/data/goods/` (134 个 `.tres`)。
`refresh_city_output_modifier_factors` 另有每格 `good_count` (134) 次 `effective_value`。

这两个数与 M0-7 的性能预算绑定，已登记为 G2。

## 5. 复算方式

```powershell
python Project/project-keynes/tools/ideology/m0_program_inventory.py --check `
    --csv artifacts/ideology-cell-layer/m0/program_inventory.csv
```

脚本只读，不修改仓库任何内容。`--check` 在任意断言失败时返回非零，可作为后续 CI 夹具。

## 6. 本报告未做的事

- 未运行 Godot、未编译 GDExtension、未跑基准。所有 reader 结论来自 `gdext/src` 静态阅读。
- 未验证 `compile_native_catalog()` 的合成 definition 在运行时的实际 ID 与 term 顺序；M1 需要用真实 catalog 输出对齐本报告 §3.1 的 101 条。
- 未核对 `.cut` 定义在 265 个 program 上的具体分布（哪些 program 用 `.cut`、叠加多少），该数据在 `program_inventory_terms.csv` 的 `operation` 列可按需过滤。
