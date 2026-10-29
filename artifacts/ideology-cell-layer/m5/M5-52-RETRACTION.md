# M5-52 撤回：我把它当成真实缺陷，是我的推断错了

| 项目 | 内容 |
|---|---|
| 状态 | **撤回**（原报告 `M5-52-claim-applies-but-territory-count-stale.md` 的缺陷结论不成立）|
| 日期 | 2026-10-28，Asia/Hong_Kong |
| 保留的事实 | claim 确实改变了格子归属；两个读函数确实不一致 |

## 1. 我原来断言了什么

我写过：「`COMMAND_CLAIM_UNOWNED_TERRITORY` 改了 `_cell_country_slot` 但没维护
`_countries.territory_count`，是真实缺陷。」并把它列为会影响存档、哈希、校验的缺陷。

## 2. 为什么这个结论不成立

我当时推断 `get_country_territory_counts()` 读 `_countries.territory_count`（`:4943`）。
**实际读的是经济运行时的快照**（`world_ext_country.cpp:978-992`）：

```cpp
if (_economy_runtime == nullptr) { ... }
const auto *economy = static_cast<const NativeEconomyRuntime *>(_economy_runtime);
// Country slots are dense in the epoch snapshot; walking them and asking the runtime
// for each count keeps the ownership question in one place ...
```

**它根本不读 `territory_count`**，所以「`territory_count` 漂移导致低报」这条因果链是我编出来的。

`:4943` 那段 `_countries.territory_count[slot]` 是 `NativeCountryRuntime::` 的另一个访问器，
不是这个 GDScript 接口走的路径。我把两处同名概念当成了同一处代码。

## 3. 我也没能把「是不是缺陷」定下来

我做了一个决定性实验：**claim 之后开一个新 epoch**，再读计数。

```
[claim] PRE slots:  HOME=0  ADJACENT=-1  FAR=-1
[claim] baseline:   widest=1 total=1
[claim] after (new epoch): widest=1 total=1
```

新 epoch 之后仍然是 1。所以：

- 不是「快照没刷新」这么简单；
- 但也不足以证明是缺陷——经济运行时的国家领土可能有**独立的捕获路径**
  （`sync_country_territory_to_map` 之类的显式同步），而我**没有调用它**。

**两种解释都成立，我没有区分开。** 所以正确说法是「未知」，不是「缺陷」。

## 4. 我做的代码改动：保留，但重新定性

我在 `rebuild_cell_csr()` 末尾加了一段：从刚算出的 CSR 偏移量重算 `_countries.territory_count`。

**它不是「缺陷修复」**（缺陷未证实）。它的作用是：

> `territory_count` 与 `_country_cell_offsets` 是同一事实的两份表示。
> 这份重算让它们在任何时候都相等，代价 O(国家数)。

这与本方案 ADR01/ADR02 对派生层的结论一致（派生量不维护两份）。
**它不能改变正确行为**：CSR 偏移量本来就由 `_cell_country_slot` 算出，
重算只是把同一个数字也写进另一个字段。

我保留它，并在此如实标注**它修的不是一个已证实的 bug**。

## 5. 仍然成立的事实（这些我核对过）

| 事实 | 依据 |
|---|---|
| claim 命令被接收并**应用了**：`FAR` 的 `country_slot` 从 **-1 → 0** | 夹具 PRE/POST 打印 |
| `get_country_cell_summary()` 的 `owned` 就是 `slot >= 0` | `country_runtime.cpp:4905-4912` |
| `NEUTRAL_SLOT == -1` | `country_runtime.h:40` |
| `bootstrap_country` 的显式分支只给 CSR 列出的格赋值 | `country_runtime.cpp:1175-1184` |
| `get_country_territory_counts()` 读经济运行时的快照，**不读** `territory_count` | `world_ext_country.cpp:978-992` |
| claim 之后两个读函数**不一致**（待解释） | 夹具输出 |

## 6. 这是第 6 次「第一遍读不完整」

| 次 | 错法 |
|---|---|
| 1 | 读**注释**（ramp「MIN 已界定」）|
| 2 | 读**数据文件**（term.value 0.97 → 实际 1.0）|
| 3 | 读**字符串匹配**（`cell.market` 以为是原生 tag）|
| 4 | 只看**命中行、不看资源块**（成本 key 以为是效果 key）|
| 5 | 没确认**快照何时构建**（tag override 时序）|
| 6 | **把同名概念当成同一处代码**（`territory_count` 的两个读者）|

第 6 次的教训最具体：**看到 `X` 被 `A` 写入，不等于 `B` 读的是 `A` 的那份 `X`。**
查一个「A 影响 B」的因果链时，**必须先确认 B 的读取路径**，而不是从 A 的写入路径反推。

## 7. 交付物

| 文件 | 说明 |
|---|---|
| `gdext/src/country_runtime.cpp` | `rebuild_cell_csr()` 末尾重算 `territory_count`（一致性改进，非缺陷修复）|
| `tests/ideology/ideology_d4_claim_condition_test.gd` | 最小复现：PRE/POST slots + 计数对比 |

## 8. 下一步（明确）

1. 查经济运行时的国家领土是**何时、从哪份数据**捕获的；
2. 若它需要显式同步（如 `sync_country_territory_to_map`），则 M5-50/M5-52 的现象都只是**少调一步**；
3. 若它应当自动跟随，那才是缺陷——**到那时再断言**。
