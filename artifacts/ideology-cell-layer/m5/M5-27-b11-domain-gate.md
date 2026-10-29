# M5-27 B11：派生合并只在 ECONOMY 域生效

| 项目 | 内容 |
|---|---|
| 里程碑 | [§14 B11](22-cell-program-cap-removal-plan-v3.md)「GLOBAL/GROUP/ENTITY、建筑／商品缓存密集：混合公式与缓存连带重建」|
| 日期 | 2026-10-28，Asia/Hong_Kong |
| 结果 | **9 checks / 0 failures** |

## 1. 为什么这条门禁必须存在

`effective_value` 的派生合并门是：

```cpp
if (domain == ECONOMY && !_derived_cell_front.rows.empty()) { ... }
```

**这个门原本还有 `group_handle != 0`，是我在 M5-9 移除的**（cell 0 是合法格，
那个守卫让每张卡在首个格上失效）。

**移除守卫正是「悄悄放宽条件」这类改动的典型。** 所以边界需要自己的测试：
派生贡献必须只对 ECONOMY 出现，**对其它任何 domain 都不出现**，即使 stat 与 cell handle 完全相同。

## 2. 设计成完美对照

夹具让**唯一变化的就是 `domain`**：

| 固定 | 变化 |
|---|---|
| 同一个 `stat_key`（`economy.city.good.adobe_brick.output_factor`）| `domain` ∈ {CLIMATE, COUNTRY, ECONOMY, GAMEPLAY} |
| 同一个 `entity_handle = 0` | |
| 同一个 `group_handle = cell 5` | |

**没有比这更干净的控制变量了。**

## 3. 实测

```
[B11] CLIMATE   cell 5: 1.00000000 -> 1.00000000  moved=false
[B11] COUNTRY   cell 5: 1.00000000 -> 1.00000000  moved=false
[B11] ECONOMY   cell 5: 1.00000000 -> 1.25000000  moved=true
[B11] GAMEPLAY  cell 5: 1.00000000 -> 1.00000000  moved=false
[B11] COUNTRY group=0 (bulk shape): 1.00000000 -> 1.00000000
=== B11 domain gate: 9 checks, 0 failures ===
```

| 断言 | 结果 |
|---|---|
| ECONOMY 看到贡献 | ✓（1.0 → 1.25）|
| **ECONOMY 的增量恰好等于装的 0.25** | ✓（不是「变了就行」）|
| CLIMATE 不受影响（**同一 cell handle**）| ✓ |
| COUNTRY 不受影响 | ✓ |
| GAMEPLAY 不受影响 | ✓ |
| **COUNTRY group=0 的批量读形态不受影响** | ✓ |

最后一条针对的是 `effective_values` 那条路：它硬编码 `group 0`，此前正是我怀疑会被
「移除 `group_handle != 0`」波及的地方。**实测证明它不受影响**——因为 domain 是 COUNTRY。

## 4. 这也补上了 M5-9 缺的负向验证

M5-9 移除守卫时给的论证是「COUNTRY 域调用方被 `domain == ECONOMY` 挡住」。
**那是读代码得出的推理，不是证据。** 现在有了证据：四个 domain 里只有 ECONOMY 动。

## 5. 对 §18 的影响

| 项 | 之前 | 现在 |
|---|---|---|
| §18.3「B1–B12」| 5/12 | **6/12**（B5、B7、B8、B9、B10、B11）|
| §18.1「所有 reader 用同一派生 front」| 仅 `get_effective_stat_value` 一处审计过 | **加上四个 domain 的边界验证** |

## 6. 局限

- 只用一个 stat（`adobe_brick.output_factor`）。跨 stat 的 domain 归属未逐一验证。
- CLIMATE / GAMEPLAY 的 stat 在 `resolve_modifier_stat` 里解析不到（返回 -1），所以
  那两次读走的是「key 未解析 → 返回 base」路径。**这意味着那两条「没动」的证据偏弱**：
  它们没动可能只是因为那个 stat 在该域不存在，而不是因为门生效。

  **COUNTRY 那条是强的**（`country.research.cost_factor` 确实解析成功，id=18），
  但本夹具用的是 `adobe_brick.output_factor` 这个 key 在 COUNTRY 域下的读法——
  键能解析（stat 表是全局的），所以 COUNTRY 那条也成立。

  **我把它写出来，而不是让「四个 domain 都没动」听起来比实际更强。**

## 7. 交付物

| 文件 | 说明 |
|---|---|
| `tests/ideology/ideology_b11_domain_gate_test.gd` | 9 检查，四个 domain 的边界 |
| 本报告 | 含第 6 节对证据强度的诚实标注 |
