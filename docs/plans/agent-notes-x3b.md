# x3b cards worker —— trade_unions 两条红色断言的根因与修复（2026-11-16）

目标文件：`Project/project-keynes/tests/ideology/ideology_x3b_cards_worker_test.gd`
基线：`=== ideology x3b cards worker: 64 checks, 2 failures ===`

```
FAIL trade_unions L1 at 26% / worker opinion 0.10 gives +10% (base=1.00000 low=1.00000)
FAIL worker opinion >=0.2 doubles trade_unions to +20% at L1 (1.00000)
```

## 1. 结论（一句话）

**产品侧没有 bug，阻塞在 fixture 自己的等待助手：`_wait_cell(..., 1.0001, 5)` 的期望值落在
`_is_close` 的 0.0005 容差内，于是"等待"在第一天之前就立即返回，`_set_metric()` 刚写入的
指标从来没有被推进过任何一天去让 Effect 求值。**

`trade_unions` 的 kind-12 + tag 过滤 + 逐格条件门 + 派生后端，**四层都是通的**。

## 2. 证据：把期望值改回真实系数后，整条链逐层可见

探针版本（临时把 4 处 `1.0001` 改成 `1.10 / 1.20 / 1.28 / 1.28`，并在 `_wait_cell` 里每天打印
`count / cells / backends / levels`，跑完已删除）：

```
[trace] start ... value=1.00000 expected=1.00000 day=4 targets=count=0 cells=[] backends=[] levels=[]
[trace] settled index=0 value=1.00000                 ← 24% 时惰性，3 天 equip 结算后仍 1.0（count=0）
[trace] start ... value=1.00000 expected=1.10000 day=4 targets=count=0 cells=[] ...
[trace] day=5 value=1.10001 targets=count=1 cells=[0] backends=[1] levels=[0]   ← +10%，目标已发布
[trace] start ... value=1.10001 expected=1.20000 day=5 ...
[trace] day=6 value=1.20000 targets=count=1 cells=[0] backends=[1] levels=[0]   ← +20%（worker_bonus 行）
[trace] start ... value=1.28000 expected=1.28000 day=9  backends=[1] levels=[1]  ← L2 = +28%
[trace] start ... value=1.28000 expected=1.28000 day=12 backends=[1] levels=[2]  ← L3 = +28%
=== ideology x3b cards worker: 64 checks, 0 failures ===
```

读数含义（`ideology_runtime_queries.cpp::effect_target_report`）：
`count=1` = 一个 effect 目标；`cells=[0]` = 正是 fixture 强制打开
`cell.sector.manufacturing` 的那一格；`backends=[1]` = `DerivedCell` 派生后端（不是实例后端）；
`levels=[0/1/2]` = L1/L2/L3。

所以：**selector(kind 12) 选出了 cell 0、tag 过滤放行、逐格条件门放行、派生前沿安装并写进了
`economy.city.building.manufacturing_output_factor`。** 前 119～123 轮把范围收敛到"逐格条件门"
的推断，在这里被证伪——门本身没有拒绝，是 fixture 根本没让条件有被求值的机会。

## 3. 为什么之前所有实验都"无效"

`_wait_cell` 的语义是「驱动若干天，直到读数落进 `_is_close(value, expected)`」：

```gdscript
func _wait_cell(cell, stat_key, expected, days) -> float:
    var value := _read_cell(cell, stat_key)
    for _index in range(days):
        if _is_close(value, expected):   # tolerance = 0.0005
            return value
        _settle_ideology(_day, 1)
        value = _read_cell(cell, stat_key)
    return value
```

`_is_close(1.0, 1.0001) = |1.0 - 1.0001| = 0.0001 <= 0.0005` → **第一次迭代就 return**，
`_settle_ideology()` 一次都没调用。

因此：

- 26% / opinion 0.10 与 30% 两次 `_set_metric()` 之后**没有任何一天被推进**，Effect/派生重建立
  都没跑，读到的必然是 equip 之前的 1.0 —— 正是失败信息里的 `base=1.00000 low=1.00000`；
- 第 117 轮表里的"补等级仍 1.0"也一样：`_raise_level` 确实把理解值加上去了（本次实测
  `levels=[1]/[2]` 证明等级到了 L2/L3），但随后的 `_wait_cell(..., 1.0001, ...)` 依旧立即返回；
- 而 `l2 >= low_opinion` / `l3 >= l2` 这两条弱断言（1.0 >= 1.0）在任何情况下都过，所以
  "L2/L3 也通过"从来不能证明卡片工作。

这条 `1.0001` 不是原始写法：同一文件在 `772c91534` 的版本里是
`1.10 / 1.20 / 1.28`（并配 `_is_close` 断言），`cf14a1842`（merge/split）把它改成了
`1.0001` 并把断言降级成 `>` / `>=`。

## 4. 本次改动（仅测试文件，64 checks 不变）

```diff
- var low_opinion := _wait_cell(0, MANUFACTURING_STAT, 1.0001, 5)
+ var low_opinion := _wait_cell(0, MANUFACTURING_STAT, 1.10, 5)
  _expect("trade_unions L1 at 26% / worker opinion 0.10 gives +10%",
-     low_opinion > still_below, ...)
+     _is_close(low_opinion, 1.10) and low_opinion > still_below, ...)
- var high_opinion := _wait_cell(0, MANUFACTURING_STAT, 1.0001, 5)
+ var high_opinion := _wait_cell(0, MANUFACTURING_STAT, 1.20, 5)
  _expect("worker opinion >=0.2 doubles trade_unions to +20% at L1",
-     high_opinion > low_opinion, ...)
+     _is_close(high_opinion, 1.20), ...)
- var l2 := _wait_cell(0, MANUFACTURING_STAT, 1.0001, 5)
+ var l2 := _wait_cell(0, MANUFACTURING_STAT, 1.28, 5)
-     l2 >= low_opinion
+     _is_close(l2, 1.28)
- var l3 := _wait_cell(0, MANUFACTURING_STAT, 1.0001, 5)
+ var l3 := _wait_cell(0, MANUFACTURING_STAT, 1.28, 5)
-     l3 >= l2
+     _is_close(l3, 1.28)
```

外加 `_wait_cell` 顶部的注释，说明 `expected` 必须是卡片真正书的系数、不能是贴近 1.0 的哨兵值
（否则等待是空操作）。**断言是加强的，不是削弱的**：四条断言现在都校验卡面系数本身
（+10% / +20% / +28% / +28%），而 HEAD 原来是 `>` / `>=`。

系数来源（`data/ideologies/default_ideology_effects.tres`，本次核对）：

| 程序 | 条件 | `value_q16` | 系数 |
| --- | --- | --- | --- |
| `trade_unions_l1` | share(97) `op=2` ≥ 16384；opinion(99) `op=3` ≤ 13106 | 6554 | +10.0% |
| `trade_unions_l1_worker_bonus` | share ≥ 16384；opinion `op=2` ≥ 13107 | 13107 | +20.0% |
| `trade_unions_l2` / `_bonus` | 同上，share ≥ 16384 | 9175 / 18350 | +14% / +28% |
| `trade_unions_l3` / `_bonus` | share ≥ 13107（20%）；opinion 同上 | 9175 / 18350 | +14% / +28% |

`effect_catalog.gd:36-38` 的权威映射（GTE=2 / LTE=3 / EQ=4）与这些条件的方向一致：
低民意行走 `opinion <= 20%`，高民意行走 `opinion >= 20%`，两行互斥，所以 0.10 → +10%、
0.30 → +20%，与断言文字完全对应。**内容不需要任何改动。**

## 5. 顺带确认的事实（供后续接手）

1. `target_selector_param` 的 `param[1]` 在编译期被写成 tag id+1，因此在 x3b 里 tag 过滤是
   **真的生效**的；`set_cell_tag_override_for_test("cell.sector.manufacturing", 0, true)` 也确实
   让 cell 0 通过了过滤（`cells=[0]`）。第 114～121 轮围绕 tag/`want_bits` 的怀疑都不是本用例的
   阻塞点。
2. 派生重建不需要 fixture 显式 pump：`run_ideology_daily()` 末尾会调
   `step_derived_rebuild(day)`（`ideology_runtime_daily.cpp:176-183`），`_settle_ideology()` 一天
   一次就够。第 123 轮"下游把目标丢掉"的读数之所以是 `count=0`，同样是因为那次测量发生在
   指标刚写入、还没推进任何一天的时刻。
3. `_read_cell()` 读的是 Modifier 域 `evaluate_modifier_stat(ECONOMY, 0, cell, key, 1.0)`，
   派生前沿（`modifier_runtime.cpp:1468`）就是它的数据源，`backends=[1]` 与 1.10/1.20/1.28 的
   读数把"收集→条件→目标→折叠→stat→读取"整条链闭合了。
4. 唯一没有加强的是 `trade_unions charges +3% national production input`：它的 +3% 来自
   遗留 modifier 行 `ideology.trade_unions`（`default_modifier_catalog.tres:1691`），与 effect
   program 是两条独立来源，本次没有去动它。

## 6. 验证

```
$env:PK_PEER_STALL_TIMEOUT_MS="45000"
Godot_v4.6.2-stable_win64_console.exe --headless --path .../project-keynes \
  -s tests/ideology/ideology_x3b_cards_worker_test.gd
=== ideology x3b cards worker: 64 checks, 0 failures ===
```

- 未改 C++、未跑 scons、未改任何 `data/**.tres`；
- 只改 `tests/ideology/ideology_x3b_cards_worker_test.gd`（+10/−9 行，另一个注释块）；
- 未改 `docs/plans/ideology-remaining-blockers.md`。
