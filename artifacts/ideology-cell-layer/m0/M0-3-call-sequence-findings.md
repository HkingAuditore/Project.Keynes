# M0-3 main-thread / worker call sequence — findings

| 项目 | 内容 |
|---|---|
| 里程碑 | [M0](../22-cell-program-cap-removal-plan-v3.md) |
| 任务 | §15.2 M0 task 3 |
| 日期 | 2026-10-26，Asia/Hong_Kong |
| 方法 | `gdext/src` 静态阅读，行号相对 HEAD `f52c5b9` |
| 状态 | 主线程与 worker 的边界已定位；**但 EPOCH_BEGIN 的可续跑性结论是阻塞 M0-8 的关键事实** |

## 1. 经济冻结边界的真实顺序

`NativeEconomyRuntime::start_epoch()`（`economy_runtime_epoch.cpp:816`）是唯一的 epoch 开启入口，内部严格顺序为：

```
[816]  start_epoch(day_index)
  ├─ [819-823]   状态与日守卫（_bootstrapped / _fatal / _epoch_active / day<=last_committed）
  ├─ [825-847]   前置形状断言（market / environment / building / merchant）—— 全部在写状态前
  ├─ [848-891]   demand-basis cache 尺寸 + merchant 索引修复（可能 rebuild_merchant_ranges）
  ├─ [894]       clear_epoch_metrics()              ← 清空全部 _epoch_* 计数与容器
  ├─ [895]       rebuild_family_demography_weights()
  ├─ [905]       advance_climate_day_columns()      ← 气候列推进
  ├─ [906]       capture_country_epoch()            ← ★ 原始输入冻结 + 因子捕获混在一起
  ├─ [909]       rebuild_economy_live_cells()
  ├─ [910]       maybe_lock_cadence_cycles(day)
  ├─ [911-931]   市场 workset 构建（_epoch_market_ids / _epoch_settlement_cells）
  ├─ [933-947]   资源 lane 预留与准备
  ├─ [1005-1006] capture_cell_elapsed_days / refresh_cell_activity_tiers
  └─ ...         其余准备，最后置 _epoch_active
```

**方案 §9.4 的六阶段在这里的落点是：**

| §9.4 阶段 | 现实现位置 | 状态 |
|---|---|---|
| `RAW_INPUTS` | `capture_country_epoch` 前半（`5029` territory index、`5071` geo columns、`5072` tag snapshot） | 与 FACTOR_CAPTURE 混在同一函数 |
| `PROGRAM_BASIS` | **不存在** | 需新增 |
| `MATERIALIZE` | **不存在** | 需新增 |
| `PREFLIGHT` | 只有 `825-847` 的 shape 断言 | 需扩展 |
| `INSTALL` | **不存在** | 需新增 |
| `FACTOR_CAPTURE` | `capture_country_epoch` 尾部（`5530` refresh_city_modifier_factors、`5531` refresh_city_output_modifier_factors） | 与 RAW_INPUTS 混在同一函数 |
| `CONSUME` | `start_epoch` 之后的 Stage::LEDGER_APPLY 等 | 已存在 |

### 1.1 `capture_country_epoch` 内部（方案 §9.4 已点名的混合点）

```
[4967] bool NativeEconomyRuntime::capture_country_epoch(std::string &error)
  ├─ [4972-4990]  copy_economy_snapshot → _epoch_cell_country / _epoch_country_handles / 技术列
  ├─ [5029]       rebuild_country_territory_index()      ← RAW: 领土 CSR
  ├─ [5071]       rebuild_epoch_geo_columns()            ← RAW: 地理标志
  ├─ [5075-5076]  rebuild_epoch_family_cell_metrics / country_metrics  ← RAW: 家族指标
  ├─ [5172]       rebuild_epoch_tag_snapshot()           ← RAW: tag 快照
  ├─ [5530]       refresh_city_modifier_factors()        ← ★ FACTOR_CAPTURE
  └─ [5531]       refresh_city_output_modifier_factors() ← ★ FACTOR_CAPTURE
```

**方案要求的「拆清 RAW_INPUTS / FACTOR_CAPTURE」就是把 `5530-5531` 之后的所有因子捕获挪到 `INSTALL` 之后。** 这不是重构，是把两行调用移动位置——前提是派生 front 在 `5530` 之前已安装。

## 2. worker 边界锁的真实持锁窗口

`native_simulation_host.cpp` 的 worker 主循环：

```
[15608]  std::unique_lock<std::mutex> boundary_lock(_economy_authority_boundary_mutex);
[15611]  AtomicCounterScope day_scope(_worker_day_inflight);      ← 标记 in-flight
[15708]  build_day_plan(day, speed, env)
[15712]  execute_day_plan(...)                                    ← ★ 整个语义日在此
[15742]  if (preflight_ok || country_commands_terminal) { … }     ← 命令所有权转移
[15952]  if (continuation_pending == 0) { … }
[15969]  boundary_lock.unlock();                                  ← 仅在 incomplete 路径解锁
```

配套事实：

- `try_lock_economy_input_capture()`（`native_simulation_host.h:337-340`）是 `try_to_lock`，主线程拿不到就返回空 lock，**不阻塞**。
- 拿不到锁时走 request/complete 服务：`_main_boundary_service_requested` 是**按请求者计数的位集**（`h:1669-1673`），不是单个 bool——这批基础设施已经存在且被 ideolgy/trigger 两处使用。
- `[15969]` 的 unlock 只发生在**本日 incomplete** 的分支里。也就是说：**如果 `execute_day_plan` 内部某个阶段需要跨帧续跑，当前实现没有为它解锁。**

## 3. `start_epoch` 不可续跑（关键事实）

方案 §9.5 把「跨帧续跑」与「释放边界锁」并列为可选，但对 `start_epoch` 而言这两条的成本完全不同：

| 事实 | 证据 |
|---|---|
| `start_epoch` 是**一次性调用**，没有 resume 游标 | `economy_runtime_epoch.cpp:816` 单一函数，无 stage 字段 |
| 唯一的两个可续跑 continuation 都是**别的阶段** | `_fiscal_reservation_continuation`（`h:4899` 附近）、`_epoch_begin_post_fiscal_pending`（`h:4899`） |
| `start_epoch` 返回 false 只有两条出路：soft barrier 停 IDLE，或 `fail()` 致命 | `economy_runtime.cpp:15211-15233`、`epoch.cpp:1538-1548` |
| 调用点只有两处，都在日推进主循环 | `economy_runtime.cpp:15211`、`economy_runtime_epoch.cpp:1538` |

**所以「MATERIALIZE 跨帧续跑」如果发生在 `start_epoch` 内部，就必须把 `start_epoch` 改造成状态机**——而它已经是 30+ 个 cost 埋点覆盖的最热路径，且 `clear_epoch_metrics()`（`894`）已经把 `_epoch_*` 清空，任何半途退出都要保证下次进入不重复清空。

**我建议 M1/M2 走「释放边界锁 + INSTALL 重校验」**，理由：

1. 复用现成的 request/complete 服务（已支持多请求者计数）；
2. 不需要在 `start_epoch` 内部引入 stage 字段，避免污染已被性能埋点覆盖的函数；
3. `15969` 已经有「incomplete 时 unlock」的先例，扩展它比新增状态机风险低；
4. 方案 §9.6 的 `expected_basis` 重校验本来就要实现，两种方案都需要它。

代价：MATERIALIZE 必须持有**不可变输入副本**（不能持有可变领土 CSR 的裸指针跨锁）——方案 §9.5 已写明这条约束。

## 4. 主线程 vs worker 的四条路径

方案 §9.2 的四格表在当前代码里的落点：

| Ideology 权威 | Economy 执行者 | 已确认输入的取得方式 | 现成基础设施 |
|---|---|---|---|
| 主线程 | 主线程 | `NativeIdeologyRuntime` 直接读 | 已有（`collect_effect_activations`） |
| worker | worker | `RuntimeIdeologyPodAuthority::snapshot()`（`runtime_ideology_pod.h:668`） | 已有快照对象，**但缺 numeric 已确认投影** |
| 主线程 | worker | host 输入发布边界 | 需新增 |
| worker | 主线程 | `apply_pod_snapshot` 回写后的 `NativeIdeologyRuntime` | 已有，**但滞后**（`ideology_runtime.cpp:1165` 只 mark dirty） |

关键确认：**`RuntimeIdeologyPodAuthority` 暴露的是 `snapshot()` 整体对象，没有任何「已确认 vs 未确认」的区分**。方案 §10.1 要求的 `ConfirmedCountryProgramBasis` 是全新概念，pod 侧当前无对应字段。这是一项真实的新增工作，不是适配。

## 5. 快照替换对派生层的影响（与 M0-4 的接口）

`ModifierRuntime::apply_pod_snapshot()`（`modifier_runtime.cpp:420`）：

```
[459]  std::array<Store, DOMAIN_COUNT> next_stores{};      ← 全新构建
[557]  _stores = std::move(next_stores);                   ← 整体替换
[558]  _pending_commands.clear();                          ← 清空 legacy 队列
```

**派生层若挂在 `_stores` 内必然被抹掉。** 方案 ADR02「不混入实例 Store」在本文件里有直接证据。M0-4 的原型可以简化为：在 `ModifierRuntime` 上新增一个**独立成员**，在 `apply_pod_snapshot` 前后断言它不变。

同时注意 `[463-464]`：`structure_epoch = 旧值 + 1` 无条件递增。方案 §7.4 说「Modifier worker 快照本身可能推进旧 Store 的 structure_epoch」，指的就是这里——派生层的 `layer_stat_version` 必须与之独立，否则每天的空闲都会被快照误判成结构变化。

## 6. 四种 cadence 的实际采样边界

| 消费者 | 采样时机 | 代码 |
|---|---|---|
| 市场结算 | `start_epoch` 内 `maybe_lock_cadence_cycles` 后 | `epoch.cpp:910`；周期长度 `MARKET_CYCLE_MIN/MAX_DAYS=1..5`（`economy_runtime.h:246-247`） |
| 生产计划 | `Stage::BUILDING_PLAN` | `_locked_slow_cycle_days` |
| 投资 | 独立周期 | `_locked_investment_cycle_days` |
| 资源 | `advance_worker_resource_reserves`（worker） / `world_ext_resource`（主线程） | 两处各自 `effective_value` 逐格读 `regen_factor` |

**前三个都在 `start_epoch` 的同一次冻结里锁周期**，但**周期长度不同**。方案 §9.8 说「每个消费者沿用自己的采样边界」是对的，但要注意：它们共享同一个 `epoch_id`，只是 `_locked_*_cycle_days` 不同。派生层的 `epoch_id` 语义应绑在「这一次 `start_epoch`」，而不是绑在任何单一 cadence 上。

## 7. 资源 reader 的双路径（方案 §9.4 点名的审计点）

| 路径 | 读点 | 时机 |
|---|---|---|
| worker | `advance_worker_resource_reserves` → `economy_runtime.cpp:4388-4399` | worker 持有边界锁期间，逐格 `effective_value` |
| 主线程 | `world_ext_resource.cpp:170-173` → `stat_id_for_key(...regen_factor)` | 主线程按需 |

**这两条路径读同一个 stat，但发生在不同的锁状态下。** 方案 §9.4 要求「资源读取也必须遵循明确的同代冻结规则」。当前实现里主线程路径**没有** `epoch_id` 概念，只有 worker 路径有。这是 M2 必须解决的：派生层的 `layer_generation` 要能被主线程路径看到并校验。

## 8. 提交给 M1 的实现约束

1. **`INSTALL` 必须插在 `capture_country_epoch` 的 `5530` 之前**，否则 `refresh_city_modifier_factors()` 读到的是不含派生项的因子，而它已经把结果烘进 `_epoch_cell_*_factor_q16`，之后不会自动纠正。
2. **`MATERIALIZE` 不能放在 `start_epoch` 内部跨帧续跑**，除非同时把 `start_epoch` 状态机化；推荐释放边界锁 + `expected_basis` 重校验。
3. **`apply_pod_snapshot` 的 `structure_epoch` 无条件递增**（`463-464`）必须与派生层的版本分开，否则空闲检测失效。
4. **`RuntimeIdeologyPodAuthority` 没有已确认投影**，`ConfirmedCountryProgramBasis` 是净新增。
5. **主线程资源路径缺 `epoch_id`**，与 worker 路径不同代，M2 需统一。

## 9. 本报告的局限

- 全部来自静态阅读。**没有运行任何 worker 路径**，也没有验证锁的实际争用行为。
- `execute_day_plan` 内部（`10948`）只按经济切片入口（`2300-2500`）抽样，未逐阶段核对哪些 Stage 会再次进入 `start_epoch`。
- 未核对 `native_daily_day_barrier` 与 `bio_occupancy_day_barrier` 对经济冻结边界的交互；方案 §9.5 的「不得推进目标业务日」需要它们，但本报告未验证其当前行为。
