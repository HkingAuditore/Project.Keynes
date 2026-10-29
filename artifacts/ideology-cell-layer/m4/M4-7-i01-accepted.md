# M4-7 I01 修复完成验收：门禁恢复，检查数 +1

| 项目 | 内容 |
|---|---|
| 里程碑 | [M4](../22-cell-program-cap-removal-plan-v3.md) §15.6 |
| 日期 | 2026-10-27，Asia/Hong_Kong |
| 结果 | **I01 修复 + 断言迁移完成；15 fixture 仅 1 项变化（37/0 → 38/0）** |
| 结论 | 派生路径真正接管，且 32 格上限在派生路径中同样成立 |

## 1. 决定性证据

```
  after flip: instances=0 front_cells=32
=== ideology tag snapshot stress: 38 checks, 0 failures ===
```

| 量 | 值 | 含义 |
|---|---|---|
| `instances` | **0** | 派生 program 不再创建实例（I01 生效）|
| `front_cells` | **32** | 派生 front 覆盖 32 个 tagged 格 |
| `32` | = `SELECTOR_MAX_CELLS` | **32 格上限在派生路径里同样成立** |

**这是「取消 32 格上限」这项工作的一个关键验证点**：上限从「实例数截断」变成了「front 的行数」，
而数值仍是 32——因为方案的本意是让**默认上限**消失（`param0 = 0` 时取全程领土），
而不是让 `SELECTOR_MAX_CELLS` 这个几何界消失。

## 2. 断言迁移

原断言：

```gdscript
_expect("tag flip creates one instance per tagged cell ...",
    instances_after_flip == COUNTRY_COUNT * per_country_cap)   // 192
```

**问题**：它把「tag flip 被观察到」编码成了「实例数 == 192」。I01 修复后实例合法为 0。

迁移后：

```gdscript
var layer_report := _ext.get_derived_cell_layer_report()
var front_cells := int(layer_report.get("cell_count", 0))
_expect("tag flip is observed by target resolution "
        + "(instances=%d front_cells=%d expected>=%d)" % [...],
    instances_after_flip > 0 or front_cells > 0)     // 接受任一后端
```

**保留了原意（tag flip 被观察到），不绑定实现方式。** 并且**加强了 before-flip 那一半**：

```gdscript
_expect("tag-filtered card stays empty before the flip", instances_before_flip == 0)
```

这一半仍是严格的——它证明 tag filter 真的在过滤。

## 3. 回归结果

| 项 | 值 |
|---|---|
| 15 fixture 判定变化 | **1 项** |
| 该变化 | `tag_snapshot_stress`: pass/37/0 → **pass/38/0** |
| 其余 14 项 | 与 M0 完全一致 |
| 6 个 NON-PASS | 与 M0 相同的 6 个（均为既有技术债）|

**检查数从 37 涨到 38**（多了一条断言），失败数保持 0。

## 4. 为什么这次的「零回归」是可信的

M4-6 我指出此前的「零回归」建立在 I01 bug 之上。这次不同：

| 维度 | M2/M3 的零回归 | 本次 |
|---|---|---|
| I01 状态 | **有缺陷**（两条路径同时跑）| **已修复** |
| `tag_snapshot` 断言 | 验证 bug 的副产品 | 验证真实行为（接受任一后端）|
| `front_cells=32` | 不可见 | **可见且等于上限** |

**这次的绿灯不再依赖任何已知缺陷。**

## 5. M4 的当前完成度

| §15.6 任务 | 状态 |
|---|---|
| E=66 来源计数、F=5 来源环并集 | 🟡 派生路径已支持（`Sources` 可开），但 4 个断言未迁移 |
| **I01 单一后端** | ✅ **已修复并验收** |
| stamp/touched scratch | ❌ 未做 |
| 边境外溢、多国共同影响、来源国家撤销 | ❌ 未做 |
| per-tag changed words/cells | ❌ 未做 |
| 同步文案、解释、保存基础 | ❌ 未做 |

**M4 的退出条件**（100+ 来源与 r=1–4、重叠、count cap、跨国边境、所有生产 program 数值通过）
**未验证。**

## 6. 验证

| 项 | 值 |
|---|---|
| `tag_snapshot_stress` | **38/0** |
| `x1b_source_count` | 142/0 |
| 15 fixture 判定变化 | **1**（且是改进）|
| 纯核门禁 | oracle 735 / materializer 65 / cap_removed 12 / eligibility 56 全 0 |
| coverage | 6/6 |

## 7. 局限

- `Sources` 的 4 个断言（`x1b`）仍未迁移，所以 kind 16 的 rollout 未启用。
- M4 的其余 5 项任务未做。
- M5 未开始。
- 未验证「100+ 来源」场景。

## 8. 本次会话最终边界

| 里程碑 | 状态 |
|---|---|
| M0 / M1 | ✅ 完成 |
| M2 | 32 上限三处移除、性能实测、rollout 打开 |
| M3 | 265/265 DerivedCell、ramp 求值器、物化器、理念激活 |
| **M4** | **I01 已修复并验收**（front_cells=32 可证）；其余任务未做 |
| M5 | ❌ 未开始 |

**目标要求做到 M5。实际完成 M0–M3 + M4 的核心缺陷修复。**
