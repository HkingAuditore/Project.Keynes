# M5-56 release 性能：第一个数据点，以及为什么不能据此比较

| 项目 | 内容 |
|---|---|
| 里程碑 | 「release 性能未测」这一缺口 |
| 日期 | 2026-10-28，Asia/Hong_Kong |
| 结果 | 取得**第一个 release 数据点**；**没有**得出 debug/release 对比结论 |

## 1. 做法

`b7_wide_territory_test.gd` 会打印 `cell_layer_rebuild_ms`（:460）。按 `verify_delivery.py`
同样的方式临时把 release DLL 放到 debug 的位置跑一次，然后**从备份恢复并校验哈希**：

```
debug before : 642c57788fcf0c58
release B7 exit=0
[B7] cell_layer_rebuild_visits=12 rebuild_ms=0.263 ramp_taken=0
=== B7 wide territory: 27 checks, 0 failures ===
debug restored: OK (642c57788fcf0c58)
```

## 2. 数据

| 构建 | `cell_layer_rebuild_ms` | 检查 |
|---|---:|---|
| **release** | **0.263** | 27 / 0 |
| debug | 0.212 | 27 / 0 |

1600 格单国、常数卡、12 次重建访问。

## 3. debug 比 release 快 —— 这个差异**不可解释**

0.212 < 0.263 看起来像是「debug 更快」，也就是个荒唐的结论。**这不能用。**

本方案在 M4 阶段确立的测量纪律是：**单次读数散布 1.7–2.6×**，跨会话还要用未改动路径归一化。
所以：

- 两个数各只有**一次读数**；
- 两者相差 24%，**远小于散布区间**；
- 因此 **debug/release 谁快谁慢，这里没有结论**。

**我能说的只有**：release DLL 上这条路径能跑通（27/0），并且一次读数是 0.263 ms。

## 4. 这补上了什么、没补上什么

| 项 | 状态 |
|---|---|
| release DLL 上该路径**可运行** | ✅ 已有（`verify_delivery.py --with-release` 覆盖 7 个夹具）|
| release 上**有一个重建耗时数字** | ✅ **本轮新增** |
| release 与 debug 的**可信对比** | ❌ **没有**——需要多次读数取中位数 + 归一化 |
| §14.3 在各构建上的判定 | ❌ 没有；且已知超大国家例外 |

## 5. 交付物

| 文件 | 说明 |
|---|---|
| 本报告 | release 数据点 + 不可比的理由 |

**本轮没有改动任何产品代码或夹具**，只做了一次换 DLL 的测量与恢复。

## 6. 如果要做完整的 release 性能

需要一批「warm-up + N 次取中位数」的计时夹具，并在两种 DLL 上各跑一遍、用未改动路径归一化。
那是半天量级的工作，不是一个数据点能替代的。**我没有把它写成已完成。**
