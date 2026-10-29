# M5-23 定性：平面删除没有让城市因子 CSR 失去来源

| 项目 | 内容 |
|---|---|
| 里程碑 | [M5-22](M5-22-full-fixture-audit.md) 的「待定性」项 |
| 日期 | 2026-10-28，Asia/Hong_Kong |
| 结论 | **不是回归。CSR 与派生层用的是同一个调用。** |
| 验证 | 新夹具 **6 checks / 0 failures** |

## 1. 问题是什么

M5-22 审计里 `ideology_cell_layer_shard_test` 报：

```
FAIL B: a yield leaves a cursor pointing into the work set cursor=-1 work=256
```

`city_factor_shard_cursor` 属于 `refresh_city_output_modifier_factors` 构建的**逐格 CSR**，
而**被删除的旧 v1 平面正是那个 CSR 的一个生产者**。

所以有两种可能，必须区分：

| 可能 | 含义 |
|---|---|
| A | 派生层没接管 → **真实回归**，逐格因子静默退化 |
| B | 该夹具的分片没启动 → 既有问题 |

**「按机制推理应该没问题」不是证据。** 我去问了代码。

## 2. 决定性证据：CSR 与派生层是同一个调用

`economy_runtime.cpp:7327-7330`（CSR 的逐格取值）：

```cpp
factor_q16 = modifier_factor_q16(
    _modifier_runtime->effective_value(
        ModifierRuntime::ECONOMY,
        _city_good_output_stat_ids[good], 0,
        scope, 1.0));          // <- entity 0, group = cell
if (factor_q16 == _city_output_shared_goods_q16[good])
    continue;                  // 与 shared 相同则不记 override
```

`effective_value` **就是** M5-9 修好 cell 0 之后派生层合并进去的那个函数，参数形状
（`entity 0, group = cell`）也与派生层的键完全一致。

**所以 override 的生产者是 `effective_value`，不是旧平面。** 平面当年是另一条把值写进 CSR 的路，
删掉它只是去掉了一条冗余来源。

## 3. 端到端确认：一个新夹具

`tests/ideology/ideology_derived_city_factor_test.gd`：

1. 解析 `economy.city.good.adobe_brick.output_factor` → stat id 230
2. 装一个**只覆盖 cell 5** 的 front（`adds = 0.25`，其余为 0）
3. 读 cell 5 与 cell 6

```
[df] baseline: touched=1.0 untouched=1.0
[df] effective_value on the touched cell: { "value": 1.25, "derived_add": 0.25,
      "derived_contributors": 1, "derived_present": true }
[df] after install: touched=1.25  untouched=1.0  (baseline=1.000000)
=== derived city factor: 6 checks, 0 failures ===
```

| 断言 | 结果 |
|---|---|
| 被覆盖格有派生贡献 | ✓ |
| 被覆盖格离开基准（1.0 → 1.25）| ✓ |
| **未被覆盖格不动（仍是 1.0）** | ✓ |
| 两格读数不同 → CSR 会为它记一条 override | ✓ |

**最后一条是关键**：第 7331 行的 `if (factor_q16 == shared) continue;` 只在两格相同时跳过。
两格不同 → 一定记 override → 分片有工作。

## 4. 那 `cursor=-1` 是什么

`CITY_FACTOR_SHARD_CELLS = 64`，夹具 512 格，本应分片约 8 次。
但它在**首次读取时** `cursor` 就是 `-1`（`economy_runtime.cpp:7345` 的正常完成态）。

**这说明该夹具的分片根本没启动**——不是分片算错了，而是它读到的是「从未开始」的状态。

这与我的删除无关：CSR 的输入路径在第 2 节已证明是完好的。

**仍待查**：为什么在 512 格世界里打开 epoch 后分片没有开始。可能是
① 该夹具的覆盖集为 0（`scope` 循环没有迭代）② epoch 打开不再急切构建 CSR 而是改为惰性
（那样首个读者才会触发）。

**我没有把「应该是 ②」写成结论**，因为那需要另一轮验证。

## 5. 一处夹具的自我修正

我第一版测试用了 `"sources"` / `"adders"` 两个键，桥里实际是
`"source_countries"`（Int64）/ `"adds"`。报的是 `derived_cell_layer_column_shape_invalid` ——
**桥的报错很准确，是我猜错了名字。**

同时第一版还断言了 `get_city_output_factor_q16`，那个读者需要经济 epoch，本夹具故意不建。
已改为断言 CSA 依赖的**机制**，并在注释里写明「由代码同一性保证，不是推理」。

## 6. 交付物

| 文件 | 说明 |
|---|---|
| `tests/ideology/ideology_derived_city_factor_test.gd` | 6 检查，锁定「逐格因子只动被覆盖格」|
| 本报告 | 定性结论与剩余问题的精确边界 |
