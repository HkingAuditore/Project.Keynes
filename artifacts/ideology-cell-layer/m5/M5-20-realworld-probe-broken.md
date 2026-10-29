# M5-20 真实世界 >32 样例：夹具是坏的，而且真实世界每国只有 1 格

| 项目 | 内容 |
|---|---|
| 里程碑 | [§18.4](22-cell-program-cap-removal-plan-v3.md)「首个正确 >32 生产样例」|
| 日期 | 2026-10-28，Asia/Hong_Kong |
| 结果 | **未能取得**。两个独立原因，都已定位 |

## 1. 原因一：夹具本身是坏的，而且会挂住

`tests/ideology/ideology_cell_layer_e2e_realworld_test.gd` 存在（206 行，M3 时代写的），
断言「真实国家领土格数 > 32」。但**它从未产出过结果**：

```
SCRIPT ERROR: Invalid type in function 'run_economy_slice' in base 'DCWorldExt'.
Cannot convert argument 1 from int to Dictionary.
   at: _run (res://tests/ideology/ideology_cell_layer_e2e_realworld_test.gd:156)
```

- 第 156 行写的是 `ext.run_economy_slice(64)` —— 桥现在要 Dictionary，**API 漂移**。
- 更糟的是**它挂住了**：脚本报错后没有走到 `quit()`，进程留在那里，我观察到它停了 10 分钟以上
  且 CPU 仍在走。**一个报错又挂住的夹具，等于不存在。**

已修复（改为 `{"day_index":…, "tick_index":…}` 的循环形式）。

## 2. 原因二（更根本）：真实生成世界的国家只有 1 格

修复前的第一次运行打出了真实世界的统计：

```
[e2e] countries=3 widest=1 above_old_cap=0 total_cells=3
```

| 指标 | 值 |
|---|---|
| 国家数 | 3 |
| **最宽领土格数** | **1** |
| **超过旧 32 上限的国家数** | **0** |
| 领土总格数 | 3 |

**三个国家，各占 1 格。**

于是夹具自己的断言必然失败：

```
widest_cells > 32,
"widest=%d above_cap=%d -- with no territory above the old cap this
 migration has no production case"
```

那句提示是对的：**「没有超过旧上限的领土，这次迁移就没有生产用例」。**

## 3. 这意味着什么

「取消 32 格限制」的**价值前提是存在 >32 格的国家**。而一个刚生成的世界里：

- 国家以 1 格起步（`StarterSettlementBootstrap` 的单格建国）；
- 要长到 >32 格需要**领土扩张玩法**，那是独立于本次迁移的系统；
- 因此**「>32 的生产样例」不能从 `generate_world` 直接得到**，必须先扩张领土。

这与我早前记录的开放项 **D4（领土扩张玩法）** 是同一件事。

**这不是本次迁移的缺陷**——机制在 400/1600/6400 格的夹具上全部正确。
但方案 §18.4 要求「首个正确 >32 生产样例」，而**当前的游戏内容无法提供这个样例**。

## 4. 我做了什么、没做什么

| 做 | 没做 |
|---|---|
| 修好夹具的 API 漂移（现在能跑到 `quit()`）| **没有**伪造一个 >32 的真实世界 |
| 记录真实世界的实测统计 | **没有**把 `widest > 32` 的断言改弱来「通过」|
| 指出这与 D4 是同一件事 | **没有**声称 §18.4 这一项已完成 |

**我特意没有把断言改宽**：那会让夹具变绿，同时消灭掉它唯一的用途。

## 5. 顺带说明：为什么这个夹具从没被发现是坏的

它不在我这一路维护的 22 个 fixture 里——**因为它从来没跑过，我也没把它放进回归集**。

一个「存在但从不运行」的测试，和不存在没有区别；它甚至更糟，因为它在清单上看起来有覆盖。

**教训：交付报告里的每一项夹具都必须在最近一次回归里真实跑过并报出检查数。**

## 5.1 修复后的实跑结果（确认）

修好 API 漂移后，夹具**第一次跑到了结尾**：

```
[e2e] countries=3 widest=1 above_old_cap=0 total_cells=3
[e2e] before: taken=0 memoised=0 evaluated=0 deferred=0
[e2e] economy slice=n/a
[e2e] after:  taken=0 memoised=0 evaluated=0 deferred=0
[e2e] report={ "ok": true, "programs_seen": 0, ..., "rows_emitted": 0 }
=== cell layer e2e realworld: 10 checks, 1 failures ===
FAIL B: at least one country owns more than 32 cells widest=1 above_cap=0 --
        with no territory above the old cap this migration has no production case
```

| 观察 | 含义 |
|---|---|
| **10 checks / 1 failure** | 夹具现在能跑完并报数了（此前从不产出结果）|
| 世界生成、国家、领土、报告结构等 **9 项通过** | 真实路径本身是通的 |
| **唯一失败就是 `widest > 32`** | 与第 2 节一致，且是真实状态 |
| `programs_seen: 0`、`rows_emitted: 0` | 1 格国家 + 未装卡，没有可派生的东西 |
| `economy slice=n/a` | 我用的 `has_method("run_economy_slice")` 仍是 false，桥名不对；**这一处还没修** |

**`widest=1` 在两次独立运行里一致**，不是偶然。

## 6. 后续

| # | 动作 |
|---|---|
| 1 | ~~确认 `widest=1` 稳定~~ **已做**：两次独立运行一致 |
| 2 | 若要满足 §18.4，需要：先在真实世界扩张某国到 >32 格（或提供合法的扩张 API 供夹具调用），再验证装卡后的逐格值 |
| 3 | 把修好的夹具**加入回归集**，避免再次「存在但从不运行」|
| 4 | 修 `run_economy_slice` 的桥名（`has_method` 为 false，`slice=n/a`）|

## 7. 交付物

| 文件 | 说明 |
|---|---|
| `tests/ideology/ideology_cell_layer_e2e_realworld_test.gd` | 修复 API 漂移；**仍会在 `widest > 32` 上失败**，且这是真实的 |
