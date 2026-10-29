# M5-110 worker 泵**落地了** —— 62 夹具全绿，但「层是否真产出」仍未证明

| 项目 | 内容 |
|---|---|
| 结果 | **泵已进入生产路径**，全量 **VERIFY OK**（62 夹具）|
| 未证明 | 一个 `-s` 夹具**跑不了 host 的 tick**，所以泵在夹具里从未被调用 |
| 日期 | 2026-10-29，Asia/Hong_Kong |

## 1. 那个决定性的设计改动

前两次尝试把这个守卫放在 `step_derived_rebuild` 里：

```cpp
if (day == _derived_rebuild_done_day) return true;   // ← 错的位置
```

**错在两个地方**：

1. 需要**同一天多次**调用 `step_derived_rebuild` 的有两方：① 正常日循环与 `drain_derived_cell_layer`；② **在同一天内开始的新 epoch**。按 `day` 做键，**新 epoch 的重建被整个跳过** —— 这就是 `save_basis` 的 `tp5` 烧 4096 步、`complete=false` 的真因
2. **需要节流的只有泵**，因为只有泵每 tick 都被调用

**所以节流移到 `world_runtime_host.gd`，C++ 侧不再有任何按天记账。**

**结果：五个曾经失败的夹具全部通过** —— 包括两次尝试都失败的 `save_basis`。

## 2. 落地后证明了什么

```
VERIFY OK · 62 夹具 · 门禁 7/7 · 内核 103/0 · 计数审计 0 过时
```

**并且 §9.3 打点在 worker 模式下确实生效**：

| 量 | 启动前 | 现在 |
|---|---|---|
| worker leg 的 `confirmed_day` | **-1** | **10** |
| worker leg 的 `eligible_day` | **-1** | **11** |

**以前 worker 模式下资格门永久敞开（`eligible=-1` 等于永不接地），现在它被真实日期约束。** 这是这次落地的第二个独立收益。

## 3. 什么**没有**被证明

**worker 权威下派生层是否真的产出 —— 没有证明。**

```
[CAPTURE/K3-A] day=14 installed=false gen=0 cells=0 contributions=-1
                rebuild_visits=8   confirmed=10  eligible=11
```

**`rebuild_visits=8` 与修复前完全一样**，而泵一旦被调用过，这个数必然上涨。

**原因很明确**：泵挂在 **host 的 tick 路径**（`_step_ideology_instance_refresh_if_authoritative`）上，
而 `ideology_worker_authority_parity_test.gd` **手工驱动日子**，**host 的 tick 循环根本没跑**。

**所以夹具测不到这个修复。** 它不是「修复无效」，而是「夹具没走到那条路」。

## 4. 要证明它，需要一个什么样的夹具

泵的入口是**已绑定**的 `step_ideology_derived_rebuild(day)`，所以夹具可以直接调它。**但必须重试**：

- 落进 worker 当天执行窗口时返回 `code = economy_day_inflight`（**实测这是实时争用，不是失败**）
- 同步推日也能拿到锁，但**不是每次**（实测 25/48）
- 所以夹具必须**跨天重试**，不能假设一次成功

**三步**：① 建 worker 世界（mask `0xFFF`）；② 每天**循环调** `step_ideology_derived_rebuild(day)` 直到
`done=true` 或撞到重试上限；③ 断言 `installed=true`、`cell_count>0`、逐格 add 与主线程腿相等。

**这才是能证明「worker 权威下派生层产出」的夹具，而且它现在是可写的** —— 因为不再有会跳过新 epoch 的守卫。

## 5. 因此 §18 的这一项**仍然是「部分」**

原因从「门禁永久敞开 / 重建从不被 step」变成了：

> **修复已落地且全量绿，缺一个能驱动 host tick 或直接重试调用它的夹具。**

**这是「缺证据」，不是「缺实现」。** 区别很大，而我不把它算成完成。
