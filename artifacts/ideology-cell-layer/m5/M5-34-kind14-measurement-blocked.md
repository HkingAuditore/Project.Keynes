# M5-34 尝试实测 kind 14 的源格上限：被原生 tag 阻塞

| 项目 | 内容 |
|---|---|
| 里程碑 | [M5-31](M5-31-source-count-still-32.md) 的量化尝试 |
| 日期 | 2026-10-28，Asia/Hong_Kong |
| 结果 | **测量未能完成**；定位到确切阻塞点，并排除了两个错误猜想 |

## 1. 想测什么

M5-31 确认：kinds 14/15 的**源格数**仍被钳在 `SELECTOR_MAX_CELLS = 32`，5 张已发布卡 author `param[0] = 32`。
那是**读代码**得到的结论。我想把它变成实测：造一个 tag 匹配 400 格的局面，看
`selector_truncations` 是否非零、`covered` 是否被限制在 32 个环之内。

## 2. 做法

用 `autonomous_logistics_l1`（kind 14、tag `cell.market`、`param (32, 0)`），
把 `cell.market` 的 tag 行改成像 `cell.population > 20` 这样每格都满足的谓词
（这招在 oracle / B5 / B7 的 ramp 夹具里用过，`front=1600` 是成功的）。

## 3. 结果：tag 一格都没匹配

```
[k14] truncations=4  matched_total=0  derived=0  cells=0
[k14] territory=400  matched=0  truncations=4  covered=0
FAIL the tag matches far more cells than the cap  matched=0
```

`matched=0`、`covered=0` —— **卡没有产生任何目标**。

## 4. 阻塞点：`cell.market` 是原生 tag

```
economy_runtime_family_buff.cpp:1133:  {"cell.market"},
```

它在**原生的 tag 列表**里——由市场/建筑状态计算，不是由 tag 行定义的谓词。
所以我替换 `domain.target_tags` 里那一项**不影响它**。

另外两张 kind-14 卡的 tag 同理：

| 卡 | tag | 性质 |
|---|---|---|
| `autonomous_logistics_l1/l2/l3` | `cell.market` | **原生**（`family_buff.cpp:1133`）|
| `gentry_patronage_l3_ring` | `cell.eminent_clan` | 原生（家族在场）|
| `refrigeration_l3_ring` | `cell.climate.hot` + `cell.market`（复数）| 前者是气候量，后者原生 |

**要让这些 tag 匹配，需要真实的市场/家族/气候状态**，不是合成夹具能便宜造出来的。

**所以 M5-31 的影响仍未量化。**（M5-31 报告里已经写明这一点，本轮只是把「为什么」钉死。）

## 5. 途中排除了两个错误猜想

### 猜想一：`refrigeration_l3_ring` 是死卡（永远不生效）

它**没有** `target_selector_tag`（单数），只有 `target_selector_tags`（复数，两个）。
而运行时是 `if (tag <= 0) return false;`。

若编译器只读单数，`param[1]` 会留 0 → 这张卡永不生效。

**猜想被推翻**：复数形式是被支持的——

```gdscript
# ideology_effect_definition.gd:387
if target_selector_tag != &"" and not target_selector_tags.is_empty():
    # 明确拒绝「两个都用」：one slot, one source of truth
# :392-395
if not target_selector_tags.is_empty(): tag_names = target_selector_tags
elif target_selector_tag != &"":       tag_names = PackedStringArray([target_selector_tag])
```

`effect_domain_catalog.gd:483-484` 也读复数。**卡片合法，不是死卡。**

### 猜想二：`truncations=4` 说明源格被截断了

`matched=0` 的情况下不可能「因为结果超上限而截断」。那 4 次截断来自**别的解析**
（这个世界里还有别的理念路径在跑），不能记在这张卡头上。

**我一开始想把它当作「上限确实生效」的证据——那是错的。**

## 6. 结论与后续

| 项 | 状态 |
|---|---|
| M5-31 的代码事实 | 成立（`std::min(authored_cap, 32)`，5 卡 author 32）|
| M5-31 的**影响量化** | **未完成**，被原生 tag 阻塞 |
| 要量化需要什么 | 真实市场 (`cell.market`) 或家族 (`cell.eminent_clan`) 状态；或给 tag 判定加一个测试专用覆盖钩子 |
| 我留下的东西 | **没有**（失败的夹具已删除；一个会失败又不测量任何东西的夹具比没有更糟）|

**如果要完成这项量化，最小代价是给 `cell.market` 一类原生 tag 加一个「测试覆盖」入口**，
而不是再造一个合成世界——那会改动生产代码，需要单独评估。

## 7. 本轮的价值

- 把 M5-31 的**阻塞原因钉死**（原生 tag），下次有人想量化时不必重走一遍；
- 排除了一个看似严重的「死卡」猜想，并留下了复数 tag 的支持证据；
- **没有**把 `truncations=4` 误当成上限生效的证据——那是我差点犯的错。
