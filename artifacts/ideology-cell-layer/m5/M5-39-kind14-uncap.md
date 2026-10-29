# M5-39 按决策取消 kinds 14/15 的源格 32 上限

| 项目 | 内容 |
|---|---|
| 决策 | 用户 2026-10-28：「5 张 kind 14/15 卡 也取消32上限」|
| 里程碑 | 本目标核心 + §15.7 |
| 结果 | **代码 + 内容两侧都改了**；新增内容门禁；**负向对照暴露了门禁的空转 bug 并修好** |

## 1. 代码改动

```cpp
// 之前
const int32_t cap = authored_cap > 0
    ? std::min(authored_cap, EffectRuntime::SELECTOR_MAX_CELLS)   // <= 32
    : EffectRuntime::SELECTOR_MAX_CELLS;                          // = 32

// 现在
const int32_t cap = authored_cap > 0
    ? authored_cap                    // 作者写的值，原样尊重
    : pk::kSelectorNoCellCap;         // 0 = 该 kind 的默认 = 无上限
```

`ring_cap` 同时从 `std::min(cap, SELECTOR_MAX_CELLS)` 改为
`pk::selector_cell_ceiling(ring_kind)`（R1=6 / R2=18 的**几何**上限）——
原来的 32 是第二道冗余上限，从不生效，而且让「这条路没有策略上限」这个意图读不出来。

**为什么这样改是对的**：`selector_cell_cap.h` 早就把 kinds 14/15 归类为
`kSelectorNoCellCap`（无上限）。运行时的 32 与那个分类**自相矛盾**。

## 2. 内容改动

5 张卡的 `target_selector_param` 从 `(32, 0)` 改为 `(0, 0)`：

`autonomous_logistics_l1/l2/l3`、`gentry_patronage_l3_ring`、`refrigeration_l3_ring`

**两侧都必须改**：只改代码的话，内容里的 32 仍会被原样尊重；只改内容的话，运行时的
`min(32, ...)` 仍会把 0 变成 32。

## 3. 顺带确认：没有别的卡还在 author 32 限制目标格

全表扫描后，除这 5 张外还有 15 处 `PackedInt32Array(32, 0)`，**全部是 kind 0**
（`SELECTOR_OWNER`，anchor-only），在那里 `param[0]` 不是格上限。

**没有 kind 12 卡 author 32** —— 目标格的无上限是完整的。

## 4. 新增内容门禁（7/7）

`m1_backend_coverage.py` 增加第 7 条：

```
[ok] no kind 14/15 card authors a source cap            actual=0 expected=0
```

它按块解析 `target_selector_param`，掩掉 bit 12..13 的归属位之后检查 `param[0] == 0`。

## 5. 负向对照暴露了门禁的空转 bug

第一次做对照（把一张卡改回 32）：

```
[ok  ] no kind 14/15 card authors a source cap        actual=0 expected=0
NEGATIVE CONTROL FAILED -- the gate did not notice
```

**门禁没有抓到。**

根因：我用了现成的 `_str()` 助手读字段，而它的匹配式是
`^key = &?"([^"]*)"` —— **要求引号**。`PackedInt32Array(32, 0)` 没有引号，
于是它返回 `""`，`param0` 恒为 0，**门禁永远空转**。

改成专用正则后：

```
[FAIL] no kind 14/15 card authors a source cap        actual=1 expected=0
NEGATIVE CONTROL PASSED -- the gate noticed
```

**这条门禁从「永远通过」变成「真的会失败」，靠的就是那次对照。**
如果我只看「7/7 通过」就收工，会交付一条装饰性的门禁。

## 6. 回归

| 夹具 | 结果 |
|---|---|
| `content_test` | **67/0**（catalog 仍能编译，`param0 = 0` 通过校验）|
| `x1b` / B7 / B8 / B10 / B5 | 142/0、27/0、18/0、16/0、9/0 |
| `effect_instance` | 51/0 |
| 覆盖率门禁 | **7/7** |

## 7. 成本：**未测**，原因与本轮前的 M5-34 相同

去掉源上限后，覆盖规模随「该国带该 tag 的格数」增长：1600 格的国家从 32 个源变成最多 1600 个源，
每个源再走一次 R1/R2 环。

**这个成本没有测到**，因为 5 张卡的 tag（`cell.market` / `cell.eminent_clan` /
`cell.climate.hot`）是**原生 tag**，由市场/家族/气候状态计算，合成夹具造不出来
（M5-34 已钉死这一点）。

**我可以说的是**：机制上界从 `32 × 环形` 变成 `领土格数 × 环形`；
**我不能说的是**：一次 resolve 的实际耗时增加了多少。

**这条必须写进发布说明**，因为它直接影响「靠边境/大量同 tag 地块的国家」的性能。

## 8. 当前身份

| DLL | SHA256 前 16 |
|---|---|
| debug | **`708bd0f23856a7e3`** |
| release | **`b0db19ed81452ce3`** |

## 9. 交付物

| 文件 | 说明 |
|---|---|
| `gdext/src/ideology_runtime.cpp` | 去掉 32 钳制；`ring_cap` 改用几何上限 |
| `Project/project-keynes/data/ideologies/default_ideology_effects.tres` | 5 张卡 `param0: 32 → 0` |
| `Project/project-keynes/tools/ideology/m1_backend_coverage.py` | 第 7 条门禁 + param0 解析修复 |
