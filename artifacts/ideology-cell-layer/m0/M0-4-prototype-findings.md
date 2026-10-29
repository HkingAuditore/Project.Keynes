# M0-4 boundary prototype — findings

| 项目 | 内容 |
|---|---|
| 里程碑 | [M0](../22-cell-program-cap-removal-plan-v3.md) |
| 任务 | §15.2 M0 task 4 / ADR02 |
| 日期 | 2026-10-26，Asia/Hong_Kong |
| 测试 | `Project/project-keynes/tests/ideology/ideology_cell_layer_m0_prototype_test.gd` |
| 结果 | **10 checks, 0 failures** |
| 日志 | `m0_prototype.log` / `m0_prototype.stderr.log` |
| 结论 | ADR02 的前提在源码层面成立；**但「快照会抹掉 Store 行」这一点本原型未能执行验证**，原因见 §3 |

## 1. 已执行的验证

| 断言 | 结果 |
|---|---|
| DCWorldExt 可实例化、modifier catalog 可编译配置 | pass |
| 基线（无任何行时）`evaluate_modifier_stat` 返回 1.0 | pass |
| `submit_modifier_commands` 接受 GROUP scope 行（需 `protocol_version: 2`） | pass |
| 行提交后该格读出非 1.0（行确实生效） | pass |
| 无提交日时 `apply_runtime_modifier_snapshot` 不被应用 | pass |
| 其原因是 `modifier_not_worker_authoritative`（而非其他 bug） | pass |
| 64 个格连续调用 `evaluate_modifier_stat` 全部完成 | pass |
| `effective_value` 无需显式 view 对象即可调用 | pass |

## 2. 三个实现事实（供 M1 使用）

### 2.1 `submit_modifier_commands` 必须带 `protocol_version: 2`

缺这个字段时运行期返回 `modifier_protocol_unsupported` 并**静默丢弃整批行**（`ok=false`，不抛错）。M1 若用 `submit_modifier_commands` 做任何派生层投递（本方案 ADR02 明确不走这条路），漏掉该字段会表现为「命令提交成功但效果不存在」。

### 2.2 `apply_runtime_modifier_snapshot` 的前置条件是「已提交过语义日」

`world_ext_modifier.cpp:482` 先判 `domain_is_worker_authoritative(MODIFIER)`，而该位只在

```
native_simulation_host.cpp:16077
  if (wanted != 0u && (day_commit.completed_domain_mask & wanted) == wanted)
      _authoritative_domain_mask.store(wanted, ...);
```

之后才置位——即**必须先有一个完整提交的原生日**。仅调用 `start_runtime_worker()` 不够。

`SHADOW` 模式永远拿不到该位（`runtime_modifier_pod_test.gd:60-63` 就是断言这一点）。所以任何想验证快照行为的 fixture 都必须 ACTIVE + 真跑一天。

### 2.3 热读循环没有每格同步

`evaluate_modifier_stat` → `ModifierRuntime::effective_value`（`modifier_runtime.cpp:1405`）是 `const`，内部只做三次 `unordered_map::find` + 算术，**没有锁、没有 `atomic_load shared_ptr`**。64 格连查在原型里直接通过。

这满足了方案 §8.4 的一半要求（「不在每个格查询时 atomic_load shared_ptr，也不为每个查询加锁」），但目前**没有** `ModifierReadView` 这层抽象——M1 需要新增它并让六类 reader 传参，而不是证明现有 API 已够用。

## 3. 未能执行的验证（必须如实记录）

**「Store 内的行会被 POD 快照抹掉」这一点，本原型没有执行验证。**

原因：要触发 `apply_pod_snapshot`，需要 worker 权威 + 一个已提交语义日。在 fixture 里驱动完整原生日（climate frame → country commit → economy capture）属于 M0-2/B1 harness 的工作量，不是边界原型的范围。

源码头证明仍然成立且确定性：

```
modifier_runtime.cpp:459   std::array<Store, DOMAIN_COUNT> next_stores{};   // 全新构建
modifier_runtime.cpp:557   _stores = std::move(next_stores);                // 整体替换
modifier_runtime.cpp:558   _pending_commands.clear();                       // 清空 legacy 队列
```

`_stores` 是 `std::array<Store, 4>`，`Store` 内含 `buckets` / `unique_instances` / 全部 SoA 列。整体 move 之后旧内容无任何引用留存。任何住在 `Store` 里的派生行都会被清除——这是**代码结构事实**，不是需要实测的经验结论。

但方案 §13.1 第 4 层要求「生产链路」验证，而 §13.2 明确警告「不能只断言实现返回自己计算的期望值」。所以：

- **M0 的结论**：ADR02 的前提在源码层面成立，原型证明可行性与 API 形态；
- **M1 的退出条件必须包含一条执行过的断言**：派生 front 在 `apply_pod_snapshot` 前后逐值不变。届时 M0-2 的 B1 harness 已存在，可以直接复用。

我把这条写进 checklist 的 M1 退出项，避免它被「M0 已经验证过」掩盖。

## 4. 副产物：两个测试基础设施事实

1. **Godot 的 stdout 无法被 PowerShell 管道捕获**。`& $exe ... 2>&1 | Select-Object` 返回 0 行，但 `Start-Process -RedirectStandardOutput` 同一命令返回 87 行。所有测试运行器必须用 `Start-Process` + 文件重定向，否则会得到「0 checks」并误判为干净基线。已写入 `run_m0_baseline_tests.ps1` 的注释。
2. **`D:\Godot\Godot_v4.6.2-stable_win64.exe` 是个 1 字节占位文件**，真正的二进制在**同名目录内**：`D:\Godot\Godot_v4.6.2-stable_win64.exe\Godot_v4.6.2-stable_win64.exe`（172 MB）。任何 `Test-Path` 检查都会通过并选中这个不能执行的占位符。

这两条都不是本方案的问题，但会稳定地毁掉任何自动化基线，因此记录在案。

## 5. 复算方式

```powershell
$exe = 'D:\Godot\Godot_v4.6.2-stable_win64.exe\Godot_v4.6.2-stable_win64.exe'
Start-Process -FilePath $exe -NoNewWindow -Wait -PassThru `
  -ArgumentList '--headless','--path','Project/project-keynes',
    '-s','tests/ideology/ideology_cell_layer_m0_prototype_test.gd' `
  -RedirectStandardOutput artifacts/ideology-cell-layer/m0/m0_prototype.log `
  -RedirectStandardError  artifacts/ideology-cell-layer/m0/m0_prototype.stderr.log
```

## 6. 局限

- 只验证了 ECONOMY 域的 GROUP scope；未覆盖 GLOBAL、ENTITY 与其余三个域。
- 「热读无锁」是从 `const` + 无锁成员读出的结论，**不是**并发实测。真正的并发正确性要等 M1 的 worker 测试。
- 未测 `structure_epoch` 在快照替换后的具体递增值（需要触发快照才行），仅从源码读出它无条件 `+1`（`modifier_runtime.cpp:463-464`）。
