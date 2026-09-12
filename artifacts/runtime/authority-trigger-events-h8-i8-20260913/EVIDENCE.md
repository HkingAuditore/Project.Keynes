# Trigger H7/H8 + Events I8 ACTIVE 放行证据

日期：2026-09-13
状态：**验证闭环 PASS**（RuntimeTests 25/25 + ACTIVE 12 日 serial soak）

## 掩码算术

| 项 | 值 | 说明 |
| --- | --- | --- |
| 变更前 `implemented` / 生产 request | `0x876` | CLIMATE\|COUNTRY\|IDEOLOGY\|EFFECT\|MODIFIER\|COMMIT |
| 新增 `TRIGGER_INPUT` | `0x008` | domain id 4 |
| 新增 `EVENTS` | `0x200` | domain id 10 |
| 变更后 `implemented` / 生产 request | `0xA7E` | `0x876 \| 0x008 \| 0x200` = **2686** |
| 整图 `required` | `0xFFF` | 十二域 |
| `missing_domain_mask` | `0x581` | `0xFFF ^ 0xA7E` = INPUT_CAPTURE\|ECONOMY\|GAMEPLAY_EFFECT\|VISUAL |

阶段顺序未变：`… COUNTRY → TRIGGER_INPUT → IDEOLOGY → EFFECT → … → EVENTS → … → COMMIT`。

生产入口仍是同一个开关 `runtime_climate_authority_enabled`：为真时
`world_runtime_host.gd` 请求 `authoritative_domain_mask = 0xA7E`；为假时整体退回 SHADOW。

## soft-complete 行为（G8 教训）

Trigger 与 Events 的输入未就绪都 **soft-complete**：把自己的位或进
`completed_domain_mask`，但不置 `*_pod_ready`，并把原因写进 `*_pod_fallback_reason`。
这样 Climate\|Country\|Effect\|Modifier 的 grant 不会被这两个新域扣住。

- Trigger soft 集合：`trigger_pod_not_configured`、`trigger_pod_not_bootstrapped`、
  `ack_barrier_incomplete`、`ack_retry`、`stale_generation`、`ack_rejected`。
  其中 `ack_barrier_incomplete` 是**触发日第一次访问的正常结果**（Trigger 排在 Effect
  之前），下一次访问重放同一批 intent id 后提交。硬 kernel / command 失败仍隔离。
- Events 无条件 soft-complete（空日、被拒批次都算完成），因为它是镜像。

## 验证结果

### RuntimeTests（`Invoke-RuntimeTests.ps1`）

- 路径：`tests-run/`
- 结果：**25/25 PASS**（含 `runtime_effect_pod_test` 在更新
  `effect_pod_host_stage_self_test` mask pin 为 `0xA7E` 之后）
- 重点：`runtime_trigger_parity_test`、`runtime_events_pod_test`、
  `runtime_protocol_guard_test`、`runtime_climate_authority_test`、
  `dots_completion_gate` 全部绿

### ACTIVE 12 日 serial soak

- 路径：`active-12-serial/soak.json` + `soak.log`
- 参数：`authority=1` `drive=serial` `40x30` `days=12` `seed=20260913` `speed=50`
- `first_bad_tick=-1`，`writeback_drop_count=0`，`worker_fault_count=0`
- 终态报告（`[soak/effect-report]`）：

| 字段 | 值 |
| --- | --- |
| `authoritative_domain_mask` / `requested_authority_mask` | **2686** (`0xA7E`) |
| `trigger_worker_authoritative` / `trigger_pod_ready` | true / true |
| `events_worker_authoritative` / `events_pod_ready` | true / true |
| `effect_worker_authoritative` / `ideology_worker_authoritative` / `modifier_worker_authoritative` | true |
| `main_wait_on_sim_us` | **0** |
| `simulation_thread_mode` | ACTIVE |

## 顺手修复

- `effect_pod_host_stage_self_test` 仍 pin 旧 mask `0x876`，导致
  `runtime_effect_pod_test` 报 `effect_host_stage_mask_changed`；已对齐
  `implemented_domain_mask()`（含 TRIGGER\|EVENTS）。
- soak probe 终态报告扩展 trigger/events 字段（`climate_authority_soak_probe.gd`）。

## 已知遗留（不挡本轮放行）

1. **Events 消费者未迁移**。I8 只授予 worker 侧镜像 + stage 位。legacy
   `GameplayEventBus` journal 仍是生产消费源；主线程 append/ACK 未抑制，
   POD snapshot 不回灌 GameplayEventBus。`events_worker_authoritative == true`
   **不**表示 journal 已搬到 worker。
2. **Trigger→Effect ACK 是协议 ACK**，与 G8 Ideology 同形；真实应用仍走主线程
   `handoff_trigger_effects`。
3. **ACTIVE 下不再有 Trigger parity 参考帧**（`run_trigger_daily` 被抑制）。
4. Economy（阶段 J）仍是下一主线；UniqueSource Modifier template replay 缺口未变。
