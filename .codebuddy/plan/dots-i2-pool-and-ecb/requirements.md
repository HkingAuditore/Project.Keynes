# DOTS I2：多 Pool API + CommandBuffer 实战化

> 上游路线图：[`dots-roadmap-to-gdextension/`](../dots-roadmap-to-gdextension/)
> 解决问题：P1-③（DCWorld 单一扁平 entity 池） + P1-④（CommandBuffer 仅 API 就位）
> 不在范围：P2-⑤ archetype 物理重排、`temperature_transport_anomaly` SoA 化（详见上游 architecture.md §8 决策日志）
>
> **核心承诺**：本计划**不动任何 hot loop body**。只动 World API、初始化路径、
> spawn/destroy 路径。因此**不重蹈 P0-② 的 GDScript SoA 反优化覆辙**。
> 性能红线：完成后 SUS 既有数字 ±2%（持平）。

---

## 0. 上下文与基础事实

### 0.1 现状清单（侦察 2026-05-11）

| 项 | 现状 | 文件 |
|---|---|---|
| World 单一 `_entity_count` 扁平 ID 空间 | ✅ 已实现 | [`world.gd`](../../Project/project-keynes/scripts/data_core/world.gd) §Task 1 |
| Front 池"约定式"占用 `[cell_n, cell_n + MAX_FRONTS_DC)` | ⚠️ 隐式约定，无 API 保护 | [`weather_refresh_job.gd`](../../Project/project-keynes/scripts/simulation/sus/jobs/weather_refresh_job.gd) L113-176 |
| Archetype 标记位（`ARCH_CELL` / `ARCH_WEATHER_FRONT`）| ✅ 已注册并在用 | [`weather_refresh_job.gd`](../../Project/project-keynes/scripts/simulation/sus/jobs/weather_refresh_job.gd) L164 |
| `DCQuery.with_archetype(arch_id)` | ✅ 已使用（front pool 范围遍历）| [`weather_refresh_job.gd`](../../Project/project-keynes/scripts/simulation/sus/jobs/weather_refresh_job.gd) L607 |
| `DCCommandBuffer.create_entity / destroy_entity` API | ✅ 已实现（148 行 / 全链路）| [`command_buffer.gd`](../../Project/project-keynes/scripts/data_core/command_buffer.gd) |
| `world.flush_command_buffer()` | ✅ 已实现 | [`world.gd`](../../Project/project-keynes/scripts/data_core/world.gd) L616 |
| Weather front spawn/destroy **走 ECB** | ❌ 未走，直接 `_active_fronts.append` + `assign_archetype` | [`weather_system.gd`](../../Project/project-keynes/scripts/weather/weather_system.gd) L270-279 |
| `DCWorld.create_pool / pool_range / in_pool` | ❌ API 不存在 | — |

### 0.2 根本问题

**P1-③ 现象**：weather front 池的 idx 段是"约定式"的——`weather_refresh_job` 写死
`cell_n + MAX_FRONTS_DC`，没有 API 让其他子系统（未来的 unit / army / economy）
注册自己的 pool。如果将来要加第三个 pool，就必须再修 `weather_refresh_job` 的
初始化代码以协调 idx 偏移，**违反开闭原则**。

**P1-④ 现象**：`DCCommandBuffer` 全链路就位，但 `weather_system._spawn_random_front`
直接 `_active_fronts.append(WeatherFront.new())`，front 的"逻辑存在"与"World 中的
archetype 标记位"由 [`weather_refresh_job._sync_fronts_to_world`](../../Project/project-keynes/scripts/simulation/sus/jobs/weather_refresh_job.gd) 在每个
weather refresh 末做一次性同步。这个同步路径：
- 是 P0-② "AoS→SoA 单向镜像"的残留（B-full 已经把 hot loop 数据通道接通，但 spawn/destroy 路径没接通）
- 在 GDExtension I3 阶段会成为 PackedArray COW 分裂的隐患（C++ 端持有的 view_f32 指针在 sync 触发 resize 时失效）

### 0.3 终极目标对齐

I3 阶段 C++ 端 `DCWorldExt` 接管 World 后：
- `create_pool` 在 C++ 层是 `_pools.push_back({name, start, count})`，O(1)
- `pool_range(pool_id)` 返回 `Vector2i(start, start+count)`，hot loop 可以用 `for_each_index_in_pool` 直接拿到 idx 段
- ECB 在 C++ 层保留与 GDScript 端**同样的接口语义**（create/destroy/flush），但内部 flush 时直接 memmove + 一次 ptrw resize，性能跃迁

**因此 I2 的 GDScript 实现必须保证 API 形状与未来 C++ 实现 100% 同形**——
本计划 §2 EARS 的接口签名就是 [I3.A 阶段 C++ 端](../dots-roadmap-to-gdextension/architecture.md#4-dcworldext-类结构) 要镜像复刻的。

---

## 1. 迭代蓝图

### I2.A：多 Pool API（3 天）

**目标**：把"约定式 idx 段"升级为"显式 pool 注册"，所有子系统通过 pool_id 声明自己的范围。

| Story | 内容 | 工时 |
|---|---|---|
| I2.A.1 | World 增加 `create_pool / pool_range / pool_id / pool_count` API | 0.5 天 |
| I2.A.2 | DCQuery 增加 `in_pool(pool_id)` 链式过滤 | 0.5 天 |
| I2.A.3 | `weather_refresh_job` 改造为"先 create_pool('cells')、再 create_pool('weather_fronts')，所有遍历用 in_pool" | 1 天 |
| I2.A.4 | `bind_map_data` 内部自动注册 `cells` pool（默认行为，调用方零侵入）| 0.5 天 |
| I2.A.5 | 行为/性能回归 + 决策日志补一条 | 0.5 天 |

### I2.B：CommandBuffer 实战化（2 天）

**目标**：weather front spawn/destroy 全链路走 ECB，弃用 `_sync_fronts_to_world` 镜像。

| Story | 内容 | 工时 |
|---|---|---|
| I2.B.1 | weather_system `_spawn_*` 改走 `world.command_buffer().create_entity(ARCH_WEATHER_FRONT)` | 0.5 天 |
| I2.B.2 | weather_system 死亡回收改走 `world.command_buffer().destroy_entity(idx)` | 0.5 天 |
| I2.B.3 | SUS 调度器在 weather job 末统一 flush；`_sync_fronts_to_world` 退化为"只把 Vector2/intensity 等数据写入 SoA"（不再做 archetype 标记位）| 0.5 天 |
| I2.B.4 | 行为/性能回归 + 决策日志补一条 | 0.5 天 |

---

## 2. EARS 验收标准

### I2.A.1 — World Pool API

- WHEN 调用方调用 `world.create_pool(name: StringName, capacity: int) -> int` 时，THEN World SHALL 返回一个新的 pool_id；同名 pool 重复 create SHALL 返回已有 id（幂等）
- THE World SHALL 内部维护 `_pools: Array[Dictionary]`，每条记录 `{ name, start, count }`，且 `start` 严格按 create 顺序 = 前序所有 pool 的 `start + count` 之和
- THE `world.create_pool` 完成时 SHALL 自动把 `_entity_count` 拉伸到 `start + capacity`（等价于"一次性追加 capacity 个 entity 槽位"），并对所有已注册 component 同步 resize（external_ref 槽位除外）
- THE `world.pool_range(pool_id) -> Vector2i` SHALL 返回 `Vector2i(start, start + count)`；非法 pool_id SHALL 返回 `Vector2i(-1, -1)` 并 push_error
- THE `world.pool_id(name: StringName) -> int` SHALL 返回名称对应的 pool_id；不存在 SHALL 返回 -1
- THE `world.pool_count() -> int` SHALL 返回当前 pool 总数
- IF `bind_map_data` 已被调用过且某个 pool name == "cells"，THEN `create_pool` 重复调用 SHALL 不重新分配，只返回既有 pool_id（与 cells pool 一一对应）

### I2.A.2 — DCQuery in_pool

- WHEN 调用方调用 `query.in_pool(pool_id: int)` 时，THEN DCQuery SHALL 内部把遍历范围设为 `world.pool_range(pool_id)`（等价于 `with_range(begin, end)`）
- WHEN 同时调用 `with_archetype` + `in_pool` 时，THEN 遍历 SHALL **取交集**（pool 范围内 + archetype 匹配的 entity）
- WHEN `in_pool` 被传入非法 pool_id 时，THEN DCQuery SHALL 不触发任何遍历（返回值正常但 callback 一次都不被调用）+ debug 构建 push_warning
- THE `in_pool` SHALL 优先级高于 `with_range`（链式调用时 in_pool 覆盖 with_range，反之亦然 —— 后调用者覆盖前者）

### I2.A.3 — weather_refresh_job 迁移

- WHEN `weather_refresh_job._setup_world` 启动时，THEN SHALL 调用 `world.create_pool("cells", cell_n)` —— 但因为 `bind_map_data` 已自动建过同名 pool（见 I2.A.4），实际效果是幂等取既有 pool_id
- WHEN `weather_refresh_job._setup_world` 启动时，THEN SHALL 调用 `world.create_pool("weather_fronts", MAX_FRONTS_DC)`，取代当前的 "create_entities(cell_n + MAX_FRONTS_DC)" + 手算 base 的逻辑
- THE 现有 `_front_pool_base` 字段 SHALL 改为 `world.pool_range(_pool_id_fronts).x`（运行时查询，不再做手算）
- THE 现有 `q.with_range(_front_pool_base, _front_pool_base + MAX_FRONTS_DC)` SHALL 改为 `q.in_pool(_pool_id_fronts)`
- THE 改造后 SUS 既有日志 `weather_refresh ran=...` 数字 SHALL 与改造前 ±2% 持平

### I2.A.4 — bind_map_data 自动注册 cells pool

- WHEN `world.bind_map_data(map_data)` 被调用时，THEN 内部 SHALL 自动 `create_pool("cells", cell_count)`（如已存在则幂等返回）
- THE 这步 SHALL 在 `_entity_count = cell_count` 设置之**后**、内置 component 注册之**前**执行
- THE 现有 `weather_refresh_job._setup_world` 里 `world.create_entities(cell_n + MAX_FRONTS_DC)` SHALL 删除（因为 cells pool 由 bind_map_data 建好；fronts pool 由 create_pool 建）
- IF 调用方在 bind 之前手动 create_pool("cells", n)，THEN bind_map_data SHALL 校验 capacity == cell_count，不一致 SHALL push_error 并放弃 bind（防止池容量不一致引发越界）

### I2.A.5 — 行为零回归

- WHEN I2.A.1~A.4 全部完成，THEN climate / weather / ocean_currents 三大 SUS Job 30-tick 汇总 SHALL 与改造前数字一致（±2%）
- WHEN F11 / F9 / F12 三个 hot key 触发时，THEN SHALL 全部正常工作（path 标识不变、SnapshotProbe 输出不变）
- THE 改造后 [`dots-roadmap-to-gdextension/architecture.md`](../dots-roadmap-to-gdextension/architecture.md) §8 决策日志 SHALL 追加一条"I2.A 落地"记录

---

### I2.B.1 — Weather front spawn 走 ECB

- WHEN `weather_system._tick_active_fronts` 在 spawn 阶段命中"应该 spawn 一个 front"分支时，THEN SHALL 通过 `world.command_buffer().create_entity(_arch_weather_front)` 申请 idx，**不再** `_active_fronts.append(...)` 立刻入数组
- THE `world.command_buffer().create_entity` 返回的占位 idx SHALL 用于把 spawn 的初始数据（center / radius / intensity / kind）写入对应 SoA component（直接 view_f32[idx] = ...，因为 component 已在 fronts pool 范围内预分配）
- WHEN ECB flush 后（同 round 内的 weather job 末），THEN `_active_fronts` Array SHALL 由 `query.in_pool(_pool_id_fronts).with_archetype(_arch_weather_front)` 重建（仅作"快速 iter"缓存，不再是真值）
- IF `_pending_create_count + 当前活跃数 > MAX_FRONTS_DC`，THEN ECB.create_entity SHALL push_warning 并返回 -1（拒绝越池），调用方丢弃本次 spawn

### I2.B.2 — Weather front destroy 走 ECB

- WHEN `weather_system` 在 advance 阶段发现 front `is_alive() == false` 或飘出图边界时，THEN SHALL 调用 `world.command_buffer().destroy_entity(front_idx)`
- THE `destroy_entity` 在 ECB.flush 时 SHALL 把对应 idx 的 archetype 置为 `archetype_none()`，**不**触发 component 数据清零（容忍残留数据，因为 archetype 过滤会跳过该 idx）
- WHEN ECB.flush 完成时，THEN `_active_fronts` Array SHALL 重新从 World 重建（同 I2.B.1 末段）

### I2.B.3 — flush 时机与 _sync_fronts_to_world 退化

- WHEN weather_refresh_job 在一个 round 完成所有 weather sub-pass 后，THEN SHALL 调用 `world.flush_command_buffer()` 一次（在 `_apply_field_advection` / `commit` 都完成之后）
- THE 现有 [`weather_refresh_job._sync_fronts_to_world`](../../Project/project-keynes/scripts/simulation/sus/jobs/weather_refresh_job.gd) SHALL 移除"assign_archetype 标记位"代码（已由 ECB.create/destroy 接管），只保留"把每个活跃 front 的 center/radius/intensity 等 SoA 数据写入 World"的部分
- IF I2.B.3 完成后该函数体的"非 archetype"部分也已经过时（数据通道已在 spawn 时写入），THEN 整个 `_sync_fronts_to_world` SHALL 标记为 `@deprecated` 并在函数体改为空操作（保留 6 个月以兼容外部调用）
- THE flush 调用 SHALL 在 SUS 日志中以 `flush_ms=` 字段单独计时（独立于 sub-pass breakdown），用于观察 ECB 开销

### I2.B.4 — 行为零回归 + 决策日志

- WHEN I2.B.1~B.3 全部完成，THEN 30-day weather A/B 对照（启用 `--validate-weather` 模式）SHALL 与 I2.B 之前的行为完全一致：active_fronts 数量 / 平均寿命 / 平均强度的 30-day 直方图 SHALL 无统计性差异
- WHEN I2.B 完成，THEN SUS `weather_refresh` 30-tick 汇总数字 SHALL 与 I2.A 完成时 ±2% 持平
- THE 改造后 [`dots-roadmap-to-gdextension/architecture.md`](../dots-roadmap-to-gdextension/architecture.md) §8 决策日志 SHALL 追加一条"I2.B 落地"记录
- THE 本计划 SHALL 写一份 [`task-item.md`](task-item.md) 完工章节，记录两次 30-tick 实测窗口对比

---

## 3. 非功能需求

### 3.1 性能红线

| 阶段 | weather_refresh avg | climate_daily avg | 备注 |
|---|---|---|---|
| I2.A 完成 | ±2%（持平）| ±2%（持平）| 仅动初始化路径，不动 hot loop |
| I2.B 完成 | ±2%（持平）| ±2%（持平）| spawn/destroy 每天才几次，flush 开销 < 0.05ms |

### 3.2 兼容性

- THE I2.A 完成后，所有现有调用方（`map_generator` / `weather_refresh_job` / `climate_*_job`）SHALL 无需修改即可继续工作（`bind_map_data` 自动建 cells pool 是默认行为，对外透明）
- THE I2.B 完成后，`_sync_fronts_to_world` 函数体被掏空但**保留函数签名**，确保第三方插件（若有）调用不会报"未定义函数"

### 3.3 可观测性

- THE SUS 日志 SHALL 增加 `pools=N` 字段（出现在"world: bound=true entities=X components=Y"行末），暴露 pool 总数
- THE F12 SnapshotProbe 输出 SHALL 增加 `pool: cells=[0,2400) fronts=[2400,2416)` 行（便于 debug）
- THE ECB.flush 调用 SHALL 在 debug 构建打印 INFO `[DCCommandBuffer] flushed N cmds (created=M destroyed=K) in T.TTms`

### 3.4 风险

| 风险 | 缓解 |
|---|---|
| I2.A.4 自动建 cells pool 与现有 weather_refresh_job 顺序冲突 | I2.A.1 的 create_pool 严格幂等；I2.A.3 改造时手动验证调用顺序 |
| I2.B.1 的 ECB 占位 idx 在同 round 内被多次写入 SoA 后 flush 时数据错位 | ECB 设计上 create_entity 立即返回稳定 idx（≥ entity_count）；本计划 §2.A.4 + 现有 command_buffer.gd L57 已保证此性质 |
| 弃用 `_sync_fronts_to_world` 后渲染层数据缺失 | I2.B.3 分两步：先**保留**数据写入部分，仅移除 archetype 部分；I2.B.4 验证无回归后再考虑掏空 |

---

## 4. 不在范围（明确排除）

| 项 | 理由 |
|---|---|
| Pool 物理重排 / chunk 化 | P2-⑤ / I4.A 范围；GDScript 路径下无可观测收益 |
| ECB 多 buffer / 并发安全 | 当前 SUS 单线程，单 buffer 够用；I3.D 之后再说 |
| ECB add_component / remove_component 落实槽位变更 | 当前所有 component 全 entity_count 满分配，标记位即可；落实槽位是 GDExtension 之后的事 |
| `temperature_transport_anomaly` SoA 化 | 触碰 climate hot loop，会重蹈 P0-② 覆辙；归档给 climate 后续 plan 或 I3.B/C |

---

## 5. 验收门槛

完成本路线图需同时满足：

1. ✅ I2.A.1~A.5 全部通过（pool API + query in_pool + weather job 迁移 + bind 自动建池 + 性能持平）
2. ✅ I2.B.1~B.4 全部通过（spawn/destroy 走 ECB + flush 时机正确 + 行为零回归 + 性能持平）
3. ✅ [`dots-roadmap-to-gdextension/architecture.md`](../dots-roadmap-to-gdextension/architecture.md) §8 追加 I2.A / I2.B 各一条决策记录
4. ✅ [`task-item.md`](task-item.md) 完工章节填入 2 个 30-tick 实测窗口对比

---

## 6. 时间预估

| 迭代 | 预估 |
|---|---|
| I2.A.1~A.5 | 3 天 |
| I2.B.1~B.4 | 2 天 |
| **合计** | **5 天（~1 周）** |
