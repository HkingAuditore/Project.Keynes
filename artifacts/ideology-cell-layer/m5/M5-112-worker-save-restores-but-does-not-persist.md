# M5-112 §11.7 第 7 时点通过 —— **但 worker 权威下的载入不持久**

| 项目 | 内容 |
|---|---|
| 通过 | worker 权威下存档**能**恢复，且**逐格无损** |
| 新发现 | **恢复后一次 worker 回写就会覆盖它** —— 等于 worker 模式下读档不生效 |
| 日期 | 2026-10-29，Asia/Hong_Kong |

## 1. 通过的部分（7 次连跑一致）

```
[PARITY] cells compared=192  covered(captured)=1  covered(restored)=1
         presence_mismatch=0  add_mismatch=0
         max_abs_add_diff=0.00000000000000000  max_abs_value_diff=0.0000000000
         add_sum=0.0500030518 / 0.0500030518
front:   cell_count=2/2  contributions=2/2  generation=1/1  confirmed=7/7  eligible=8/8
```

- **跨世界**：捕获在 worker 世界 A，恢复到**新生成的** worker 世界 B
- 恢复后那格带的是**目录幅度** `3277/65536 = 0.0500030518`，不是零
- `PKID = 1265 字节`、`state_hash` 每次相同、**`worker_origin` 字节 = 1**（字节本身写着「worker 署名的」）
- 尾部走查**从末端按常量推导并走过变长 basis 块**，落在日期上；`confirmed=7 eligible=8` 与活报告一致

**四个负向对照全部拒绝且原因正确**，且**干净载荷随后仍能恢复**（拒绝不是半写）：

| 对照 | 拒绝原因 |
|---|---|
| 执行契约 u64 翻转 | `cell_program_execution_contract_mismatch` |
| basis `terms_digest` 翻转 | `ideology_save_applied_basis_mismatch` |
| basis `selector_kind := -1` | `ideology_save_applied_basis_invalid` |
| PKEF 截断到 4 字节 | `pkef_truncated` |

## 2. 【新缺陷】载入不持久

**夹具记录但刻意不断言**（7/7 次稳定）：

> 载入后，**一次 worker 回写**（`apply_runtime_ideology_snapshot`，host:1422，走 SUS tick 而非 `run_daily_tick` —— 所以光跑日子不会触发）应用 generation 1，并**用 worker 自己的空状态替换了恢复的行**：
>
> - `idea_rows [82, 1, 0, 0] → []`
> - 镜像的 §9.3 日期 `7/8 → 2/3`（**worker 的 committed day，不是载荷里的**）
> - **下一次泵把 front 清空**（`installed=false`、`cells=0`）

**机制**：这个构建里**没有任何东西把恢复的 PKID 推回给 worker** —— `capture`/`restore` 是**主线程 facade 的调用**（`world_ext_ideology.cpp:809-817`），而 worker 有自己的状态机。恢复只改了主线程那份镜像，worker 随后按自己的状态覆盖它。

**所以 worker 权威下读档表现为「恢复成功，然后被覆盖」** —— 不是恢复失败，是恢复**留不住**。

**这是一个能力缺口，不是本次改动的回归**：在泵修好之前，worker 模式下派生层本来什么都不产生，这个缺口**没有机会被看见**。

## 3. 第二个发现：PKEF 在 EFFECT worker 权威下无法往返

**用 `0xFFF`（EFFECT 也归 worker）捕获的 PKEF，被写出它的那个运行时自己拒绝**：`pkef_instance_identity_invalid`。

**从字节里读出的机制**：3 条实例行全部是 `effect_applied=0` 且 `applied_stack_count=1`，而这正是 `effect_runtime.cpp:7561-7562` 拒绝的那一对。

**PKID 不受影响**，因为 `worker_origin=true` 会让它短路所有 Effect 绑定/实例检查（`ideology_runtime.cpp:7367-7373`）。

**所以「PKEF 先于 PKID」这个顺序是被走到的，但它的结果必须记下来**：在那个权威配置下 PKEF 本身无法往返。

## 4. 它自己抓到的一个**假绿**

> 我第一个尾部常量**错了 4 个字节**（把 `basis_len` 断言在 `-36`）。于是走查从块的中间读出了 `basis_len=123254003`，而**那个损坏被静默接受了（`ok=true`）** —— **一个看起来绿色的负向对照**。

**正确值是 32**（`SAVE_END@4`、`contract@12`、`eligible@20`、`confirmed@28`、`basis_len@32`），已修正，并把这次 off-by-four 写进了夹具。

**这一条值得单独记**：负向对照**通过**可能是因为**它根本没有真的破坏数据**，而不是因为检查在起作用。

## 5. 另一个操作教训

> **GUI 子系统的 Godot 在 PowerShell 里不给 stdout 也不给 exit code。** 它改用 `Godot_v4.6.2-stable_win64_console.exe` 配绝对路径重定向。

**这正是我这一路反复遇到「日志 0 字节 / 没有汇总行」的根因** —— 以前我把它归因为「工作目录写错」，那只是部分原因。
