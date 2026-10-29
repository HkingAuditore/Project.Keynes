# M5-9 修复 cell 0 缺陷：每张卡在首个格上都曾失效

| 项目 | 内容 |
|---|---|
| 里程碑 | [M5](../22-cell-program-cap-removal-plan-v3.md) 正确性缺陷 |
| 日期 | 2026-10-28，Asia/Hong_Kong |
| 结果 | **cell 0 现在与其它格一致**（1.0500030517）；B7 18 → **20 checks** |
| 验证 | 22 个 fixture：**21 通过**；`mechanism_matrix` 仍是基线 1129/3 |

## 1. 缺陷

```cpp
// modifier_runtime.cpp:1443（修复前）
if (domain == ECONOMY && group_handle != 0 &&
        !_derived_cell_front.rows.empty()) {
```

`group_handle` 就是 cell —— 同一段代码上方 `:1434-1438` 的注释明确写着
「every shipped reader passes the settlement cell as group_handle」。

**而 `group_handle != 0` 把 cell 0 排除了。**

### 实测对比

| cell | `derived_present` | `derived_add` | `value`（修复前）| `value`（修复后）|
|---|---|---|---|---|
| 0 | **true** | 0.05 | **1.0** ← 没生效 | **1.0500030517** |
| 1 | true | 0.05 | 1.0500030517 | 1.0500030517 |

同一张卡、同一份贡献，**cell 0 拿不到**。派生行确实存在于 front 里（桥能直接查到），只是合并时被守卫跳过。

**后果：每张卡在其所属国家的第一个格上都没有效果。**

## 2. 为什么这个缺陷之前查不出来

M5-8 之前，派生层**只暴露计数**（`cell_count` / `stat_count`）。计数显示 6400 行、覆盖 1600 格，
看不出「其中一格的贡献被丢掉了」。

**是 M5-8 新增的 `get_effective_stat_value` 桥让它现形** —— 这个桥的价值在这次修复中被证实。

## 3. 安全性论证（移除守卫前做的）

| 关注点 | 结论 |
|---|---|
| ECONOMY 域有没有调用方把 group 0 当「无 group」？ | **没有**。全部传 `entity 0, group = cell`（`economy_runtime.cpp:4391,4394`、`economy_runtime_family_buff.cpp:7127`）|
| COUNTRY 域调用方传 group 0 表示「无 group」 | 是（`country_runtime.cpp:2433`、`economy_runtime.cpp:5621,5631,...` 共 60 处），**但派生分支以 `domain == ECONOMY` 为门，它们进不来** |
| 批量读者 `effective_values`（`:1480` 硬编码 group 0）| 它的 **3 个调用者全用 COUNTRY 域**（`economy_runtime.cpp:5579/5932/5982`），同样不受影响 |

**结论：`group_handle != 0` 与 `domain == ECONOMY` 是冗余的，移除安全。**

## 4. 修复

```cpp
if (domain == ECONOMY && !_derived_cell_front.rows.empty()) {
```

代码里写入了完整的推理与实测数据，避免后人重新加回这个守卫。

## 5. 验证

### 5.1 缺陷已修

```
[B7] cell0: derived_present=true value=1.05000305175781 add=0.05000305175781
```

新增 2 条断言（B7 18 → **20 checks**）：

| 断言 | 内容 |
|---|---|
| `cell 0 receives its derived contribution too` | cell 0 的值离开基准 |
| `cell 0 and cell 1 get the SAME derived delta` | 两格贡献一致 |

### 5.2 无回归（重点看 COUNTRY 域读者）

| fixture | 结果 |
|---|---|
| B7 / B8 / B10 | 20/0、18/0、16/0 |
| x1b / tag_snapshot_stress | 142/0、38/0 |
| cell_layer 全部 | 9/7/13/12/19/20/20/1/2 全 0 |
| content / target_selector / effect_instance / tag_source_selector | exit 0 |
| **progression / runtime / effect_metric_publish** | **exit 0** ← 含 COUNTRY 域读者 |
| **mechanism_matrix** | **1129 checks, 3 failures** ← 与基线完全一致 |

`mechanism_matrix` 的 3 个失败仍是那三个 cooperative 断言，与守卫移除无关。

## 6. 交付物

| 文件 | 说明 |
|---|---|
| `modifier_runtime.cpp` | 移除 `group_handle != 0`，写入完整推理与实测 |
| `ideology_b7_wide_territory_test.gd` | 2 条 cell 0 断言 |

## 7. 局限

- 只验证了 cell 0（唯一被守卫排除的值）；其它格未逐一验证，但守卫只排除 0。
- 未在真实生成世界、release DLL 上验证。
- 旧平面仍未删除（M5-8 已为其准备好可观测性，迁移未做）。
