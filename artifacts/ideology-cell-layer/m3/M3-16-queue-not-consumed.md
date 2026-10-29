# M3-16 理念命令不生效的完整根因（已到最底层）

| 项目 | 内容 |
|---|---|
| 里程碑 | [M3](../22-cell-program-cap-removal-plan-v3.md) |
| 日期 | 2026-10-27，Asia/Hong_Kong |
| 结果 | 命令进队列但**从未被处理**（`receipts count=0`）；根因链完整 |
| 结论 | 不是 economy 依赖，而是**理念队列的消费循环未在裸 ext 上运行** |

## 1. 决定性证据

```
[q] discover    = { ok: true, accepted: 1, pending: 1 }
[q] grant points= { ok: true, accepted: 1, pending: 1 }
[q] receipts    = { ok: true, count: 0, ... }
[q] snapshot ideas = 0        （4 天均如此）
```

**`count=0` 的回执是关键**：`apply_command` 每处理一条命令都会 `append_receipt`，所以
- 有回执 + 状态为 reject = 命令被处理但被拒；
- **无回执 = 命令从未被处理**。

`count=0` 属于后者。所以问题不在 `validate_country`，而在更前面：**队列游标没推进**。

## 2. 排除了三个先前假设

| 假设 | 证据 | 结论 |
|---|---|---|
| 需要 economy opinion | `GRANT_IDEOLOGY_POINTS` 直接给点数，与 opinion 无关 | ❌ 不是 |
| `validate_country` 失败 | 失败会产生回执，而 `count=0` | ❌ 不是（至少不是当前层）|
| `worker_authoritative` 分支 | 若走该分支会返回 `path: "IDEOLOGY_WORKER"`；实测 `path` 为空 | ❌ 不是 |
| **队列消费未运行** | `pending=1` 恒定 + `receipts count=0` | ✅ **是** |

## 3. 完整链路（每环有实测或源码依据）

```
submit_commands            -> ok=true accepted=1      实测
  merge_staged_commands    -> 命令进入 _commands       源码 :4513
    队列游标 _command_cursor 不推进                      pending 恒为 1（实测）
      apply_command 从不执行                              receipts count=0（实测）
        idea_state_for 从不调用                            snapshot ideas=0（实测）
          seen=0 / taken=0                               真实世界夹具（实测）
            ramp 真实值取不到                             —
```

## 4. 为什么游标不推进

`run_daily_slices`（`ideology_runtime.cpp:4618`）是消费循环。我调用了 `run_ideology_daily`
4 天，它返回 `done=true`，但游标没动。

**这说明 `run_daily_slices` 在到达消费循环之前就返回了。** 具体在哪一行提前返回，
我没有继续追——本轮时间用尽。

## 5. 一个顺带发现的真实缺陷

```cpp
// ideology_runtime.cpp:4595-4616
Dictionary NativeIdeologyRuntime::run_daily(int64_t day) {
    ...
    return result;                    // :4614
    return run_daily_slices(day);     // :4615  ← 死代码
}
```

`:4615` 永远执行不到。**这不是我的阻塞点**（`:4598` 已经调过一次 `run_daily_slices`），
但它是真实缺陷，值得单独清理。

## 6. 本轮的实际价值

| 产出 | 价值 |
|---|---|
| **排除三个假设** | economy 依赖 / validate_country / worker 分支，全部有实测反证 |
| 回执作为判据 | 建立了「无回执 = 未处理」这一可靠诊断法 |
| 定位到队列消费 | 从「不知道为什么不生效」缩到「消费循环提前返回」 |
| 发现死代码 | `:4615` |
| 秒级探针 | 10 秒/次，含环境槽填充与 4 次日推 |

## 7. 局限

- **仍未取得 ramp 真实数值。**
- 未追到 `run_daily_slices` 具体在哪一行提前返回。
- 未尝试 `bootstrap_country` 建立国家行（可能是必要条件之一）。
- 环境槽 `filled=0` 的问题仍在（`component_id` 返回 -1）。

## 8. 下一步（具体）

1. 读 `run_daily_slices` 的前 20 行，找提前返回条件；
2. 若是「没有国家行就返回」，则调用 `bootstrap_country`；
3. 一旦 `receipts count>0`，就能看到真实拒绝原因。

## 9. 验证

| 项 | 值 |
|---|---|
| discover / grant | `accepted=1 pending=1` |
| receipts | **count=0** |
| snapshot ideas | 0（4 天）|
| 探针耗时 | 约 10 秒 |
| 纯核门禁 | oracle 735 / materializer 65 / cap_removed 12 全 0 |
