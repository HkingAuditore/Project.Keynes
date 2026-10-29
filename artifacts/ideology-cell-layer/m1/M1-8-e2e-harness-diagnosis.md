# M1-8 end-to-end harness diagnosis — findings

| 项目 | 内容 |
|---|---|
| 里程碑 | [M1](../22-cell-program-cap-removal-plan-v3.md) §13.1 第 4 层 / §15.3 |
| 日期 | 2026-10-27，Asia/Hong_Kong |
| 性质 | **诊断，不是交付**。目标是把「端到端验证为何连续三轮缺失」从「不清楚」变成「已知边界」 |
| 结论 | 裸 `SceneTree` + 手写 MapData stub **不可行**；唯一可行路径是 `host.generate_world()` 生成真实 MapData |

## 1. 为什么值得单独写这份报告

M1-6、M1-7 的分片正确性都来自状态机测试，不是真实 epoch。这是 §13.1 第 4 层（生产链路）的空缺，连续三轮被记为「结转」。

每轮尝试都死在不同阶段，而且**每次都是静默失败**——`ok=false` 但读错了键，或方法不存在却调用了。继续盲目重试只是在消耗轮次，所以本轮改为系统地走一遍并记录边界。

## 2. 已确认的诊断链（逐条实测）

| 阶段 | 结论 | 证据 |
|---|---|---|
| `configure_modifiers` / `configure_economy` / `bootstrap` | ✅ 全部可跑通 | `[probe] configure_modifiers true` / `configure_economy true` / `bootstrap ok` |
| generation 解析 | ✅ 需要**五个**字段：`epoch_id`、`map_generation`（或 `topology_generation`）、`building_generation`、`country_generation`、`resource_generation` | `world_ext_economy.cpp:166-186` |
| 空 Dictionary 传参 | ❌ 在**第一个**字段就失败，且 `reason` 为空（错误走 `fatal_reason`，早前夹具读的是 `reason`） | 实测：`input_epoch ok=false reason=""` |
| 补全 generation 后 | 前进到环境门：`economy_environment_snapshot_invalid` | 实测 `fatal_reason` |
| 9 个环境槽 | ✅ **可填充**，用 `component_id(name)` + `write_f32_range` / `write_u8_range` | 实测 `env slots filled 10 of 10` |
| `write_f32_dense` | ❌ **该方法不存在**。正确 API 是 `write_f32_range(comp_id, start, array)`（`world_ext.h:184-186`） | 调用后挂起 |
| 环境槽补齐后 | ❌ **崩溃** `0xC0000005`，位置在 `begin_or_reuse_economy_input_epoch` 更深处（`world_ext_economy.cpp:929-930` 的 `_map_data->call("neighbor_indices_packed")` 附近） | 实测 |

## 3. 根因：手写 MapData stub 不够

`world_ext_economy.cpp:929-930` 要求 MapData 提供 `neighbor_indices_packed()`，且返回值必须与 `cell_count × 6` 一致。stub 提供的尺寸与运行时期望不匹配时不是报错而是越界。

更深的问题：这条链还依赖 country 快照、tag 快照、building context，每一层都通过 `_map_data` 取数据。**手写 stub 需要精确复刻整张 MapData 契约**，那不是夹具，那是重写。

## 4. 唯一可行路径

对照基线里能跑通 worker 日的 fixture：

```
runtime_ideology_parity_test.gd:103    await host.generate_world(SEED)
ideology_cell_layer_m0_realworld_cost_test.gd  await _host.generate_world(SEED)
```

两者都用 **`WorldRuntimeHost.generate_world()`** 生成真实 MapData，而不是手写 stub。

M0-7c 已经证明这条路能跑经济日（`idle` 档拿到 0.003 ms 真实读数）。**分片验证也应该走同一条路**，而不是另造一个 stub 世界。

## 5. 为什么本轮没有直接改成 `generate_world`

`generate_world` 的代价与限制（M0-7c 已记录）：

- 需要 `await process_frame` 先进入场景树，单次运行 ~30 s 起；
- `runtime_authority_domain_mask` 必须拨掉 `MODIFIER`(0x040) 与 `ECONOMY`(0x100)，否则主线程注入的 Modifier 行只进队列、`epoch_begin_*` 全是陈旧值；
- 而 ECONOMY 拨到主线程后，经济在 **day 4** 以 `money_conservation_failed` 致命，只剩 3 天可取样。

**这三条限制的交集决定了：一个能同时验证分片与装在 Modifier 层上的派生贡献的夹具，需要 worker 协作脚手架，而不是一条更长的脚本。**

## 6. 对 M1 收口的建议

M1 目前的状态：

| 层 | 验证方式 | 强度 |
|---|---|---|
| 判定器（§4.4） | 56 checks 纯核 + 321 program 真实内容 | 强 |
| 派生层容器 / ADR02 | 51 checks 纯核 + 19 checks 执行（`clear_modifier_domain` 后存活） | 强 |
| 合并公式（§5.1） | 20 checks 执行（真实 `effective_value`） | 强 |
| 枚举并集 / 版本（§8.5-8.6） | 20 checks 执行 | 强 |
| **分片（§14.3）** | **56 checks 状态机，无真实 epoch** | **弱** |
| 性能（§14.1） | O2 微基准 + 真实世界 idle 读数 | 中 |

**除分片外，M1 的每一项都有真实执行证据。** 分片是唯一只靠状态机的一项。

建议：把「worker 协作夹具」单列为 M1 退出的必要条件，而不是继续在 M1 内部用零散轮次尝试。它与 M0-7c、M0-2 里两个卡住的 worker fixture 是**同一个缺口**，值得一次投入解决。

## 7. 本轮交付物

- 本报告（诊断与边界）
- 已删除的探针脚本（`_probe_epoch_chain.gd`、`_probe_chain2.gd`），因为它们要么调用不存在的 API，要么在 stub 上崩溃，留着会被误当作可用夹具
- **未修改任何产品代码**

## 8. 复算方式

诊断结论可由以下文件直接核对，无需运行：

| 结论 | 核对位置 |
|---|---|
| generation 需 5 字段 | `gdext/src/world_ext_economy.cpp:166-186` |
| 环境需 9 槽 | `gdext/src/world_ext_economy.cpp:803-812` |
| 正确写入 API | `gdext/src/world_ext.h:184-186` |
| stub 崩溃点 | `gdext/src/world_ext_economy.cpp:929-930` |
| 唯一可行路径 | `tests/runtime/runtime_ideology_parity_test.gd:103` |
