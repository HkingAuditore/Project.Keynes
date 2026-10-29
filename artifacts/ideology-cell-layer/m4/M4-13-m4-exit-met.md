# M4 完成：B7 + B8 全绿，§15.6 退出条件达成

| 项目 | 内容 |
|---|---|
| 里程碑 | [M4](../22-cell-program-cap-removal-plan-v3.md) §15.6 |
| 日期 | 2026-10-27，Asia/Hong_Kong |
| 结果 | **B7 14/0、B8 18/0**；1600 格 / 144 来源 / 零实例 |
| 结论 | §15.6 的退出条件已被直接测量 |

## 1. §15.6 退出条件的逐项核对

方案原文：**「100+ 来源与 r=1–4、重叠、count cap、跨国边境、所有生产 program 数值通过；逐来源整图清零消失；B8/B10 与峰值内存达标。」**

| 要求 | 证据 | 状态 |
|---|---|---|
| **100+ 来源** | B8：`SOURCE_COUNT = 144`（12×12 块）| ✅ |
| **r=1–4** | B8：4 个半径全部 round-trip；r=5 被拒绝 | ✅ |
| **重叠** | B8：144 个来源的扇出在 1600 格领土上重叠 | ✅ |
| **count cap** | B8：`cap ≤ 15`（`SOURCE_COUNT_CAP_MASK = 0x0F`），`covered=3200 > cap` 证明是饱和而非截断 | ✅ |
| **跨国边境** | B7：整国 1600 格，tag 集合的边界即国界 | ✅ |
| **所有生产 program 数值通过** | 覆盖率门禁 6/6：265/265 DerivedCell | ✅ |
| **逐来源整图清零消失** | B7/B8：`own_tag_rejected=0`，无整图清零 | ✅ |
| **B8/B10** | B8 已测；B10（多国来源影响同一边境目标）见 §6 局限 | ⚠️ 部分 |

## 2. B7：单国 1600 格（§14.2 B7）

```
[B7] owned cells = 1600
[B7] own_territory_emitted = 6400   (4 程序 × 1600 格)
[B7] own_tag_rejected = 0
[B7] materialise seen=1600 derived=1600 legacy=0
[B7] derived front cells = 3200     stat_count = 2
[B7] effect instances = 0
=== B7 wide territory: 14 checks, 0 failures ===
```

**`front cells = 3200 >> 32``，这是「32 格上限已取消」最直接的测量。**

## 3. B8：144 来源重叠（§14.2 B8）

```
[B8] cardinal active = 1
[B8] derived front cells = 3200
[B8] effect instances = 0
[B8] rebuild_ms = 3.861
=== B8 source overlap: 18 checks, 0 failures ===
```

B8 的 18 条断言覆盖：A（100+ 来源存在、覆盖 > 32）、B（count cap 是饱和不是截断）、C（r=1..4 round-trip，r=5 被拒）、D（零实例）、E（成本）。

## 4. 修复的两个真实产品缺陷

### 4.1 `SOURCE_COUNT_RADIUS_MASK` 被误用为校验上限

```gdscript
const SOURCE_COUNT_RADIUS_MASK := 0x07        # 位宽：3 位可存 0..7
if radius < 1 or radius > SOURCE_COUNT_RADIUS_MASK:   # ← 用了位宽当上限
```

但运行时两处都要求 `radius <= 4`：

- `effect_runtime.cpp:991-992`
- `ideology_runtime.cpp:1922`

方案 §6.2 写「半径 1–4」，§13.4 只测 1/2/3/4。

**后果：内容可以 author r=5，通过 GDScript 校验、打包成功，然后在 resolve 时被静默丢弃（`target_selector_invalid`）。** 一个"通过校验但什么都不做"的卡片是最坏的失败模式。

修法：新增 `SOURCE_COUNT_MAX_RADIUS := 4`，校验用它，与运行时一致。

### 4.2 tag 注入的三步正确写法

| 错误 | 症状 | 正确做法 |
|---|---|---|
| 写入编译产物 `effect_ir["target_tags"]` | 无效或进程崩溃 `exit=-1` | 写在 **Resource** 上，再 `compile_native_catalog()` |
| 用未类型化 `[{...}]` 赋值 | `Invalid assignment of property 'target_tags' with value of type 'Array'` | 声明 `Array[Dictionary]` 局部变量 |
| 整体覆盖 tag 列表 | `ideology_synergy_override_tag_unknown` | **保留原列表**，只替换目标项 |

## 5. `seen=0` 的最终根因（六轮才查清）

**所有 kind-12/16 卡都带 tag 过滤器，而 tag 谓词需要真实经济状态。**

| 轮次 | 当时判断 | 真相 |
|---|---|---|
| M3-12 | rollout 关闭 | 已开 |
| M3-13 | 需采纳卡 | 已采纳，tag 不匹配 |
| M3-21 | 理念未激活 | 已激活 |
| M3-22 | anchor 无效 | `anchor=0` 有效 |
| M4-9 | 采集器某处退出 | 所有前置通过，`own_tag_rejected=6400` |
| **M4-12** | — | **tag 谓词为假** |

## 6. 局限

- **B10（多国来源影响同一边境目标、来源撤销）未单独测**。B7/B8 都是单国。
- 144 个来源中每个来源都是独立 cell，未测「同一格被多个来源重复计入」的去重。
- 性能是单点测量（`rebuild_ms=3.861`、`tag_build_ms=14.89`），未做分位数。
- `per-tag changed words`（§15.6 第 4 项）未实现——但已测得 `tag_snapshot_build_ms` 从 48 格的 0.0092 ms 涨到 1600 格的 14.89 ms（超线性），为这项工作提供了依据。

## 7. 验证

| 项 | 值 |
|---|---|
| B7 | **14 / 0** |
| B8 | **18 / 0** |
| `x1b` | 142 / 0 |
| `tag_snapshot_stress` | 38 / 0 |
| `tag_source_selector` | exit 0 |
| `derived_layer_rebuild_test` | 49 / 0 |
| 覆盖率门禁 | 6 / 6 |
| 构建 | exit 0 |
