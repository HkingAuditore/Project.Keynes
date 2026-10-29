# M5-33 家族目标数的「静默钳」改为编译期拒绝

| 项目 | 内容 |
|---|---|
| 里程碑 | [§13 正确性门禁](22-cell-program-cap-removal-plan-v3.md) / M5-32 遗留的口径瑕疵 |
| 日期 | 2026-10-28，Asia/Hong_Kong |
| 结果 | 校验器显式限界；**零内容影响**；相关夹具全通过 |

## 1. 原来的问题

`FAMILY_OWNED`（kind 17）选的是**家族 handle，不是格**。它的消费者：

```cpp
// ideology_runtime.cpp:1905
const int32_t cap = std::clamp(
    effective.target_selector_param[0], 1,
    static_cast<int32_t>(EffectRuntime::SELECTOR_MAX_CELLS));   // <= 32
```

而编译期校验器对 kind 17 **只检查 `param[0] >= 1`**，没有上界。

**后果：一张 author 40 个家族的卡会静默变成 32，作者永远不会知道。**
静默钳正是校验器存在的意义所在。

## 2. 我没有改 `selector_cell_ceiling`

我一度想把它从「无上限」改成 32，但那是错的：

`selector_cell_ceiling()` 的契约是「**几何可达格数**」。`FAMILY_OWNED` **确实不产格**，
所以它返回 `kSelectorNoCellCap` 是**正确的**。把两件不同的事（格上限 / 家族数上限）
塞进同一个函数会让这个函数以后更难读。

## 3. 改在校验器里

```cpp
(definition.target_selector_kind == SELECTOR_FAMILY_OWNED &&
    (definition.target_domain != 0 ||
        definition.target_selector_param[0] < 1 ||
        definition.target_selector_param[0] > LEGACY_INSTANCE_MAX_CELLS ||  // 新增
        definition.target_selector_param[1] < 1)) ||
```

并在 `:1905` 的 clamp 上加了注释，说明**它现在是防御性的**（针对早于该校验的序列化定义），
而不是主要防线。

## 4. 内容影响：零

内容里**只有 1 张** `FAMILY_OWNED` 卡：

| 卡 | `param` |
|---|---|
| `family_office_l3_owned_output` | `(32, 3)` |

`32 > 32` 为假 → **仍然被接受**。将来若有卡 author 33 以上，会得到
`effect_family_metadata_invalid` 而不是静默变小。

## 5. 验证

| 夹具 | 结果 | 说明 |
|---|---|---|
| `ideology_content_test` | **67 / 0** | **整个 catalog 仍能编译** |
| `ideology_x1b_source_count_test` | 142 / 0 | 源数选择器 |
| `ideology_b7_wide_territory_test` | 23 / 0 | 派生层主夹具 |
| `ideology_effect_instance_test` | 51 / 0 | 实例路径 |
| **`ideology_x9b_family_target_worker_test`** | **22 / 0** | **家族目标路径仍正常** |

最后一条是关键：它是唯一直接跑家族目标收集的夹具。**校验器加界没有让它失败。**

## 6. 局限

- 没有为「author 33 会被拒」写专门的负向夹具。构造它需要一份改过的 catalog，
  而 `content_test` 用的是出厂内容。**所以「会拒绝」这一半是按代码推的，不是测的。**
- 同理，「原来会静默钳」也只在代码层确认过，没有实测一张 40 家族的卡。

**这两条我写出来，而不是让「零内容影响」听起来像「行为已验证」。**

## 7. 交付物

| 文件 | 说明 |
|---|---|
| `gdext/src/effect_runtime.cpp` | 校验器增加 `param[0] > LEGACY_INSTANCE_MAX_CELLS` 上界 |
| `gdext/src/ideology_runtime.cpp` | 注释说明 `:1905` 的 clamp 现为防御性 |
