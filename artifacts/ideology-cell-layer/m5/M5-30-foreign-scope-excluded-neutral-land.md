# M5-30 修复：「仅他国」把中立地也算成他国

| 项目 | 内容 |
|---|---|
| 里程碑 | 用户新增目标项「周围地块归属筛选」|
| 日期 | 2026-10-28，Asia/Hong_Kong |
| 结果 | **真实语义缺陷，已修**；内核 93 → **103 checks / 0** |
| 验证 | 11/12 fixture 通过（`mechanism_matrix` 仍基线 1129/3）|

## 1. 缺陷

归属谓词只有**两态**：

```cpp
inline constexpr bool ownership_accepts(int32_t scope, bool is_own) {
    case OWNERSHIP_OWN:     return is_own;
    case OWNERSHIP_FOREIGN: return !is_own;     // ← 问题在这里
```

而**无归属格是负 slot**（`economy_runtime_family_buff.cpp:953`：
"Unowned cells are represented as negative slots"）。

于是对中立地：

| scope | `is_own` | 结果 |
|---|---|---|
| `OWN` | `false`（`-1 != 0`）| 丢弃 ✓ |
| **`FOREIGN`** | `false` | **保留 ← 错** |

**「仅他国」会作用到不属于任何国家的中立地。** 中立地不是「另一个国家」。

## 2. 为什么现在修

- 我是这个功能（用户新增目标项）的作者，语义是我定的；
- 目前**没有任何已发布的卡用 `FOREIGN`**（74 张全是默认 `OWN`），所以改动零风险；
- 若留到第一张「伤害邻国」的卡上线，那会是内容侧发现的、更难定位的 bug。

## 3. 修法：三态关系

```cpp
enum OwnershipRelation {
    OWNERSHIP_RELATION_OWN = 0,           // 与来源同国
    OWNERSHIP_RELATION_OTHER_COUNTRY = 1, // 另一个真实国家（slot >= 0 且不同）
    OWNERSHIP_RELATION_UNOWNED = 2,       // 无归属（负 slot）
};
inline constexpr OwnershipRelation ownership_relation(source_slot, target_slot);
inline constexpr bool ownership_accepts(int32_t scope, OwnershipRelation);

| scope | OWN | OTHER_COUNTRY | UNOWNED |
|---|---|---|---|
| `OWN` | ✓ | ✗ | ✗ |
| `FOREIGN` | ✗ | ✓ | **✗（修）** |
| `ANY` | ✓ | ✓ | ✓ |
```

**保留了 `ownership_accepts(scope, bool is_own)` 重载**，给两态调用方与纯逻辑测试用——
它**故意无法表达 UNOWNED**：分不清「无归属」的调用方就不该在这上面过滤。

两处过滤点都改为 `ownership_relation(source_slot, cell_country_slot(target))`：
- `apply_fan_out_ownership_filter`（kind 14/15 的扇出）
- kind 16 的逐格出口

## 4. 途中我自己搞坏过一处

用正则批量替换第二处时匹配错位，留下悬空的 `is_own`（编译报 C2065）。
**这是自动化编辑的典型风险**：正则只看到「形状相似」就替换，没确认上下文。
已手工修正为 `!pk::ownership_accepts(selector.ownership_scope, relation)`。

## 5. 新增断言（内核 93 → 103）

| 断言 | 内容 |
|---|---|
| `M3: same slot is OWN` | 关系判定 |
| `M3: a different real slot is OTHER_COUNTRY` | |
| `M3: a negative slot is UNOWNED` | |
| `M3: relation is target-relative` | 来源本身无归属时，关系仍按目标算 |
| `M3: OWN rejects unowned land` | |
| **`M3: FOREIGN rejects unowned land (the fix)`** | **核心** |
| `M3: ANY accepts unowned land` | |
| `M3: no unowned cell is taken by OWN or FOREIGN` | 扫 -3..9，无归属格无一被 OWN/FOREIGN 取走 |
| `M3: the sweep really contains unowned slots` | 扫到的确实是 3 个（防止断言空转）|
| `M3: OWN + FOREIGN + unowned == ANY` | **三态划分**，而不是两态和 |

**最后两条是关键**：前者防止「扫描里其实没有无归属格」导致断言恒真，
后者把划分性质从两态升级为三态。

## 6. 回归

| fixture | 结果 |
|---|---|
| B11 / oracle / B7 / x1b / B8 / B10 | 9/0、19/0、23/0、142/0、18/0、16/0 |
| B5 / derived_city_factor / stress / merge / publish | 9/0、6/0、38/0、20/0、268/0 |
| **mechanism_matrix** | **1129/3**，与基线一致 |
| 内核 | **103 / 0** |

## 7. 局限

- 只在**内核谓词**与**代码路径**上验证；没有真实世界里用 `FOREIGN` 卡的端到端夹具
  （没有已发布卡用这个 scope，所以也没有现成夹具可借）。
- 中立地的定义依赖「负 slot」这一约定；若将来改成别的哨兵，这里要同步。

## 8. 交付物

| 文件 | 说明 |
|---|---|
| `gdext/src/selector_ownership.h` | 三态 `OwnershipRelation` + 关系版谓词 + 保留两态重载 |
| `gdext/src/ideology_runtime.cpp` | 两处过滤点改用 relation |
| `gdext/tests/derived_layer_rebuild_test.cpp` | +10 条 M3 断言 |
