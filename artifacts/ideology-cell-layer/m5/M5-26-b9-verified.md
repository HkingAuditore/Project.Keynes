# M5-26 B9：400 格逐格 ramp 的阈值与连续性

| 项目 | 内容 |
|---|---|
| 里程碑 | [§14 B9](22-cell-program-cap-removal-plan-v3.md)「200+ 条件格及逐格 ramp：阈值不变、连续值变化和 false→true」|
| 日期 | 2026-10-28，Asia/Hong_Kong |
| 结果 | **19 checks / 0 failures**（oracle 从 12 增到 19）|

## 1. B9 要求什么

> 200+ 条件格及逐格 ramp：**阈值不变**、**连续值变化**、**false→true**

三件事，分别对应：

| 要求 | 我测的是什么 |
|---|---|
| 阈值不变 | metric 为 0 时**没有一格**有贡献；metric 过阈值后**每一格**都有 |
| 连续值变化 | 同一个 metric 下 400 格的贡献值**只有 1 个不同值**，且该值随 metric 变化（已由 M5-14 的三点绝对值对照覆盖）|
| false→true | `0/400 → 400/400` 这个跳变本身就是 false→true，且**贡献格数单调不减** |

## 2. 实测

复用 oracle 夹具（真实 ramp 卡 `salt_monopoly_l1`，400 格单国），在原有 3 点绝对值对照之后加一轮**全域扫描**：

```
[B9] below the ramp (metric=0.000):    contributing=0/400    distinct_values=0
[B9] mid ramp (metric=5.000):          contributing=400/400  distinct_values=1
[B9] past the clamp (metric=120.000):  contributing=400/400  distinct_values=1
=== oracle cross-check: 19 checks, 0 failures ===
```

| 断言 | 结果 |
|---|---|
| metric=0 时**零格**贡献 | ✓（阈值被尊重，不是「接近零」）|
| metric=5 时**每一格**都贡献 | ✓（400/400，不是「大部分」）|
| metric=120 时**每一格**都贡献 | ✓ |
| 同一 metric 下贡献值**只有 1 个不同值** | ✓（`distinct=1`）|
| 贡献格数随 metric 上升**不减少** | ✓ |

**「每一格都贡献」这条是关键**：扇出如果丢掉部分格，`nonzero` 会小于 400。
它和 B7 的 `front cells=3200`（1600 格 × 2 stat）一起，把「覆盖完整」这件事钉在了两个不同的量上。

## 3. 一个必须说明的局限

**这个夹具的 metric 是全局覆盖的（uniform per cell）**，所以这里的「逐格」是
「**每一格都被独立求值**」，不是「不同的格看到不同的 metric」。

真正的「逐格变化」需要格子有各自的建筑/经济状态，本夹具不建。

**我把这一点写进注释和本报告，而不是让它隐含在「B9 通过」里。**

B9 原文的「连续值变化」如果指的是「不同格有不同值」，那这一条**尚未覆盖**；
如果指的是「同一个格的值随 metric 连续变化」，那已由 M5-14 的三点 `delta = 0` 覆盖。

## 4. 对 §18 的影响

| 项 | 之前 | 现在 |
|---|---|---|
| §18.3「B1–B12 有前后可复算数据」| 4/12 | **5/12**（B5、B7、B8、B9、B10）|

## 5. 交付物

| 文件 | 说明 |
|---|---|
| `tests/ideology/ideology_oracle_cross_check_test.gd` | 新增 B9 全域扫描，**19 checks / 0** |
| 本报告 | 实测数据与**明确写出的局限** |
