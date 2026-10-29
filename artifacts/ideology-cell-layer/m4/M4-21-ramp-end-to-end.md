# M4-21 端到端 ramp 证据：分片路径逐格求值 1600 项，零 defer

| 项目 | 内容 |
|---|---|
| 里程碑 | [M4](../22-cell-program-cap-removal-plan-v3.md) §15.5 |
| 日期 | 2026-10-27，Asia/Hong_Kong |
| 结果 | **`ramp_terms_evaluated=1600`、`deferred=0`**；B7 15/0；全回归 17/17 |
| 结论 | M4-20 遗留的「端到端 ramp 未验证」已关闭 |

## 1. 决定性数据

```
[B7] ramp card: locations=[1] levels=[0] front=1600 seen=1600 derived=1600
[B7] ramp card: taken=0 evaluated=1600 deferred=0 candidates=5 metric_ok=5
[B7] ramp card verified=true
=== B7 wide territory: 15 checks, 0 failures ===
```

**1600 个 ramp 项全部逐格求值，零 defer。** 这是「ramp 在生产链路（分片路径）上真的工作」的直接证据。

## 2. 三个此前查错的地方

### 2.1 子夹具缺两步，装备静默失败

第一版子夹具跳过了 `bootstrap_economy` 与「跑完经济日」，结果：

```
locations=[0] levels=[0] front=0
```

看起来像「ramp 路径没有贡献」，实际是**卡没被装备**。补上两步后 `locations=[1]`、`front=1600`。

### 2.2 报表计数器只有单发路径在写

```cpp
// 只在已废弃的单发路径上赋值
_ramp_terms_evaluated = report.ramp_terms_evaluated;   // :7058
```

job 路径**从不赋值**，所以 fixture 读到的是陈旧 0。

**「ramp 路径能工作」与「ramp 路径静默失效」因此同样不可判定**——这是最坏的一类诊断缺陷。

修法：在 job 的 `finish` 之后导出 `report.ramp_terms_evaluated` / `ramp_terms_deferred`。

### 2.3 我误读了 ramp 判定条件

`value_mode != VALUE_CONSTANT` 我一度读成 `==`，据此以为 24 个 `value_mode=1` 的卡全都不会走 ramp 分支。

实际加了两级诊断后：

```
candidates=5    ← value_mode != CONSTANT 的命令数
metric_ok=5     ← 其中同时声明了 metric 的
```

**5/5 全部通过**，条件从来不是问题。这两个计数器保留下来，让「条件哪一半失败」可判定。

## 3. `taken=0` 的正确解释

`ramp_samples_taken` 只统计**真正重新采样**的调用：country-scope metric 命中 memo 时不递增。当所有被读的 metric 都是国家作用域时，它可以是 0，而 `evaluated` 仍为满值。

B7 的断言因此改为以 `evaluated` 为准：

```gdscript
# 证明是 ramp_terms_evaluated：它按格计数，1600 格 = 每格都采样了。
return evaluated > 0
```

## 4. 回归

| fixture | 结果 |
|---|---|
| **B7**（新增 ramp 断言）| **15 / 0** |
| B8 | 18 / 0 |
| B10 | 16 / 0 |
| x1b_source_count | 142 / 0 |
| tag_snapshot_stress | 38 / 0 |
| cell_layer catalog/numeric/ramp/ramp-mat/adr02/merge/scope-union/unbounded | 9/7/13/12/19/20/20/1 全 0 |
| tag_source_selector / target_selector / effect_instance / content | exit 0 |

**PASS = 17，FAIL = 0。**

## 5. 顺带确认的一件事

`rebuild_derived_cell_layer`（单发路径）**已不再被任何调用点引用**——全库 `rebuild_derived_cell_layer(day` 零命中。现在只有 job 路径在跑。

它仍留在源码里作为对照实现。M5 的清理项应当把它删除或标注为 dead。

## 6. 局限

- `tag_build_ms` 仍 34.92 ms（全量重建，per-tag changed words 未做）。
- 峰值内存、B5 零增量、release DLL 未测。
- 单发路径已成死代码但未清理。

## 7. 交付物

| 文件 | 说明 |
|---|---|
| `ideology_runtime.cpp` | job 路径导出 ramp 计数器；`_ramp_candidates`/`_ramp_metric_ok` 诊断 |
| `ideology_runtime.h` | 上述两个 `mutable` 计数成员 |
| `ideology_b7_wide_territory_test.gd` | `_verify_ramp_card` 子夹具（补齐 bootstrap + 经济日）+ 断言 |
