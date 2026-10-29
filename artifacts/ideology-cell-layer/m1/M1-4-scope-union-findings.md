# M1-4 scope enumeration union & version combination — findings

| 项目 | 内容 |
|---|---|
| 里程碑 | [M1](../22-cell-program-cap-removal-plan-v3.md) §8.5 / §8.6 |
| 日期 | 2026-10-27，Asia/Hong_Kong |
| 交付 | `collect_scope_ids` / `collect_scope_stat_entries` 并集、`stat_bucket_version` 版本组合、两个只读桥、`tests/ideology/ideology_cell_layer_scope_union_test.gd` |
| 证据 | **20 checks 0 failures**；构建成功 |
| 结论 | 「派生层装了但不生效」这一最危险失效模式已被两道门同时打开并各有断言 |

## 1. 本轮解决的问题：为什么「合并对了却什么都没变」

M1-3 把派生贡献正确并入了 `effective_value`，但那条路径当时是**不可达**的。原因是两个独立的门都锁着：

| 门 | 位置 | 锁住时的后果 |
|---|---|---|
| 枚举门 | `collect_scope_ids` / `collect_scope_stat_entries` 只扫 `store.buckets` | 只有派生贡献的格**根本不进读者的工作集** |
| 版本门 | `refresh_city_modifier_factors` 的早退（`economy_runtime.cpp:7016-7018`） | 版本没变就直接 return，连枚举都不会调用 |

任一扇门锁着，派生层都会「装好、算对、什么也不改」。这是本迁移最难察觉的失效形态——没有报错，没有数值异常，只有功能静默不生效。

## 2. 枚举门

`collect_scope_ids`（`modifier_runtime.cpp:1487`）与 `collect_scope_stat_entries`（`:1511`）各加一段并集：

```cpp
if (domain == ECONOMY && scope == GROUP) {
    for (const DerivedCellStatRow &row : _derived_cell_front.rows) {
        if (!std::binary_search(wanted.begin(), wanted.end(), row.stat_id))
            continue;
        for (const int32_t cell : row.cells) {
            if (cell < 0) continue;
            out_scope_ids.push_back(static_cast<uint64_t>(cell));
        }
    }
}
// 之后统一 sort + unique，所以并集顺序与去重语义不变
```

两个约束：

- **只有 ECONOMY + GROUP 可能有派生存。** GLOBAL/ENTITY 没有 cell 身份可查，加进去只会制造假命中。
- **必须仍然 sort + unique。** 既有调用方（`refresh_city_modifier_factors:7079`、`refresh_city_output_modifier_factors:7212`）依赖升序且无重复；派生行与 legacy 行落在同一格时必须折叠成一个。

## 3. 版本门

`stat_bucket_version` 现在把派生层的版本折进同一个 hash：

```cpp
if (domain == ECONOMY && !_derived_cell_front.rows.empty()) {
    hash = (hash ^ _derived_cell_front.generation) * 1099511628211ULL;
    for (each sid) hash = (hash ^ layer_version[sid]) * ...;
}
```

设计理由：派生层有自己的 `stat_versions`（**刻意**独立，因为 `apply_pod_snapshot` 无条件 bump `Store::stat_versions`，`modifier_runtime.cpp:463-464`，共用会让每天的空闲都被当成内容变化）。

但**要求调用方同时比较两个版本号是错的**——忘记组合正是本轮 bug 的成因。所以组合放在这个既有函数里，所有既有缓存不用改动就自动获得正确失效。

副作用可控：只在 `domain == ECONOMY && rows 非空` 时参与，其他域与其他域的 hash **逐位不变**。

## 4. 契约测试（20 checks）

| 断言 | 结果 |
|---|---|
| 基线：无层无行时枚举为空 | pass |
| **A. 只含派生贡献的格出现在 `collect_scope_ids`** | pass |
| A. 三个派生格逐一存在 | pass |
| **B. `collect_scope_stat_entries` 给出对应 `(cell, stat)`** | pass |
| B. 每条 entry 的 stat 都是被请求的那个 | pass |
| C. 未请求的 stat 枚举为空 | pass |
| D. legacy 行与派生行同时被枚举 | pass |
| **E. 并集严格升序（排序 + 去重）** | pass |
| **F. 同一格同时有 legacy 与派生存时只出现一次** | pass |
| **G. 派生安装会移动版本 token** | pass |
| **H. 相同内容重复安装不移动版本（空闲保持空闲）** | pass |

A/B/F 是枚举门的证据，G/H 是版本门的证据。**H 与 G 必须同时成立**：只有 G 会让空闲日每天失效一次缓存（违反 §7.4），只有 H 则派生层永远不可见。

## 5. 两个只读桥

| 桥 | 语义 |
|---|---|
| `collect_modifier_scope_ids(domain, scope, stat_ids)` | 返回 `{ok, scope_ids}` |
| `collect_modifier_scope_stat_entries(domain, scope, stat_ids)` | 返回 `{ok, scope_ids, stat_ids}` |
| `modifier_stat_bucket_version(domain, stat_ids)` | 返回组合后的版本号 |

三个都是**纯读**：不改变状态、不 bump 版本、不留副作用。它们的存在只为让测试能直接断言第 2/3 节的行为，而不是从下游数值反推。

## 6. 构建与回归

| 项 | 值 |
|---|---|
| 构建 | `Compiling shared` → `Linking` → `scons: done building targets.`，exit 0 |
| scope union 测试 | 20 checks, 0 failures |
| merge 测试（M1-3） | 20 checks, 0 failures |
| ADR02 测试（M1-2） | 19 checks, 0 failures |
| 纯核 | eligibility 56 / derived layer 51 |
| 覆盖率门禁 | 6/6 |

回归见 §7。

## 7. 回归：零判定变化

15 个 fixture 逐项对照 M0 基线：**changed verdicts = 0**（9 pass / 4 failures / 1 no_summary / 1 timeout，逐项检查数亦一致）。

这一条本轮的价值比 M1-3 更高：版本组合改的是**所有既有缓存共用的失效令牌**。如果组合写错（例如无条件参与、或把 `structure_epoch` 也折进去），大量 fixture 会因缓存过度失效而改变行为——虽然多数是性能而非正确性问题，但 `runtime_ideology_parity_test` 这类对时序敏感的 fixture 会先爆。

零变化说明：`domain == ECONOMY && rows 非空` 这个守卫是必要的——未安装派生层时 hash 逐位不变。

DLL：`a7c3ae89…`，14,059,008 B（较上一轮 +14 KB，来自新增桥与并集代码）。

## 8. 局限

- **`install_derived_cell_layer` 仍无生产调用方。** 只有 test bridge 调用。方案 §4.2 规定调用者只能是 Economy 冻结协调器——那是 M2 的接线工作，且需要先有 worker 夹具。
- **未测性能。** 本轮给 `effective_value` 加了两次二分，给两个 `collect_scope_*` 加了按 stat 的线性扫描，给 `stat_bucket_version` 加了逐 stat 查找。§14.1 的 `covered_cells × 156` 成本必然上升，**M1 退出前必须测量**，否则接线到生产时会直接撞上性能墙。
- **`collect_scope_*` 的并集仍是 O(派生行)**。当派生行数达到几万（64 国 × 6400 格 × 多 stat），每次调用都会遍历整个层。方案 §8.5 要求「按需去重排序」而不是「每次查询扫描全部」——这一点在本实现里只是部分满足（按 stat 二分收窄，但 stat 命中后仍遍历该 stat 的所有格）。M1 退出前应根据实测决定是否需要 per-stat CSR。
- **逐来源国撤销仍未实现**（M2 前置，见 M1-2 §4）。

## 9. 复算方式

```powershell
$exe = 'D:\Godot\Godot_v4.6.2-stable_win64.exe\Godot_v4.6.2-stable_win64.exe'
Start-Process -FilePath $exe -NoNewWindow -Wait -PassThru `
  -ArgumentList '--headless','--path','Project/project-keynes',
    '-s','tests/ideology/ideology_cell_layer_scope_union_test.gd' `
  -RedirectStandardOutput artifacts/ideology-cell-layer/scope_union.log `
  -RedirectStandardError  artifacts/ideology-cell-layer/scope_union.err.log
# => 20 checks, 0 failures
```
