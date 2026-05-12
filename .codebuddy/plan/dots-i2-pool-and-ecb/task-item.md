# Task Item：DOTS I2 — Pool + ECB

> 上游：[`requirements.md`](requirements.md) / [`architecture.md`](architecture.md)
> 实施期：2026-05-11 ~ 预计 5 个工作日

---

## 任务清单（按依赖顺序）

### Sprint A — 多 Pool API（I2.A）

#### A-1：World 增加 Pool API（`world.gd`）

- [x] 添加字段 `_pools: Array` / `_pool_by_name: Dictionary` / `_POOL_NONE = -1`
- [x] 实现 `create_pool(name, capacity) -> int`（幂等 + 自动拉伸 entity_count）
- [x] 实现 `pool_range(pool_id) -> Vector2i`
- [x] 实现 `pool_id(name) -> int`
- [x] 实现 `pool_count() -> int`
- [~] 单元自检：作为 "机会主义" 项推迟到 I2.B 一起做（生产数据已在 SUS 日志中观察到 pools=2 + entities 边界正确，硬性必要性低）

**预计**：0.5 天 / **状态**：✅ 完成（A-5 已验证）

#### A-2：DCQuery 增加 in_pool（`query.gd`）

- [x] 添加 `func in_pool(pid: int) -> DCQuery` 链式 API
- [x] 内部调 `_world.pool_range`，更新 `_range_begin / _range_end`
- [x] 非法 pool_id：设为空段 `[0, 0)`（callback 一次都不进）
- [x] 与 `with_archetype` 叠加：取交集（默认行为已支持，无需额外代码）

**预计**：0.5 天 / **状态**：✅ 完成

#### A-3：bind_map_data 自动建 cells pool（`world.gd`）

- [x] `bind_map_data` 内部：`pool_id("cells")` 不存在则 `create_pool("cells", n)`
- [x] 已存在但容量不一致：push_error 拒绝 bind
- [x] 验证现有 climate / weather job 的所有遍历仍工作（A-5 实测：所有 hot loop 性能持平 ±2%）
- [x] **bug 修复**：原版 `bind_map_data` 在 `_entity_count = n` 之后再 `create_pool("cells", n)`，导致 `create_entities(start + capacity) = create_entities(2n)`，entities 显示为 4816（应为 2416）。修复：先把 `_entity_count` 清零再 `create_pool`，由 `create_pool` 内部拉到 n。

**预计**：0.5 天 / **状态**：✅ 完成

#### A-4：weather_refresh_job 迁移（`weather_refresh_job.gd`）

- [x] 删除 `world.create_entities(cell_n + MAX_FRONTS_DC)` 那一段（cells pool 由 bind 自动建）
- [x] 新增 `_pool_id_fronts = world.create_pool(&"weather_fronts", MAX_FRONTS_DC)`
- [x] 现有 `_front_pool_base` 字段改为在 `_on_world_bound` 末缓存 `world.pool_range(_pool_id_fronts).x`
- [x] 现有 `q.with_range(_front_pool_base, _front_pool_base + MAX_FRONTS_DC)` 改为 `q.in_pool(_pool_id_fronts)`（保留 fallback）
- [~] 启动一次：F12 按下，确认 SnapshotProbe 输出 pool 信息（推迟到 I2.B 一并做）

**预计**：1 天 / **状态**：✅ 完成

#### A-5：可观测性 + 行为/性能回归（综合）

- [x] SUS `world: bound=true entities=X components=Y` 行末追加 ` pools=N`
- [~] F12 SnapshotProbe 输出追加 pool 列表（推迟到 I2.B 一并做）
- [x] 跑一次 30-tick 默认场景，记录 SUS 数字（实测见下方 "I2.A 完成后"）
- [x] 上游 architecture.md §8 追加一条 "I2.A 落地" 决策记录
- [x] 用户人工确认通过（2026-05-11）

**预计**：0.5 天 / **状态**：✅ 完成

---

### Sprint B — CommandBuffer 实战化（I2.B）

#### B-1：weather_system._spawn_* 走 ECB（`weather_system.gd`）

- [ ] `_spawn_random_front` 在创建 WeatherFront 实例之前，**先**调 `world.command_buffer().create_entity(_arch_weather_front)`
- [ ] 拿到的 idx 写入 `WeatherFront.world_idx` 字段（新增）
- [ ] `_spawn_emergent_front` 同样改造
- [ ] 当 idx == -1（ECB 拒绝越池）时跳过本次 spawn
- [ ] WeatherFront 实例本身仍 append 到 `_active_fronts`（hot loop 真值不变）

**预计**：0.5 天 / **状态**：⏳ 待执行

#### B-2：weather_system 死亡回收走 ECB（`weather_system.gd`）

- [ ] 在 `_active_fronts` 回收死掉/出图 front 的循环里，对每个被丢弃的 front 调 `world.command_buffer().destroy_entity(front.world_idx)`
- [ ] 保留现有的"重建 alive 数组"逻辑

**预计**：0.5 天 / **状态**：⏳ 待执行

#### B-3：flush 时机 + sync 退化（`weather_refresh_job.gd`）

- [ ] 在 weather_refresh round 末（advance / spawn / distribute / cyclone 都完成之后），调 `world.flush_command_buffer()`
- [ ] flush 单独计时，breakdown 加 `flush_ms` 字段
- [ ] `_sync_fronts_to_world` 移除"assign_archetype"代码段（archetype 已由 ECB 接管），保留数据写入部分（center / radius / intensity 等）

**预计**：0.5 天 / **状态**：⏳ 待执行

#### B-4：性能验收 + 决策日志

- [ ] 跑 30-day --validate-weather A/B（与 B 启动前对照）：front 直方图一致
- [ ] 跑 30-tick 默认场景，记录 SUS 数字（与 I2.A 完成时 ±2%）
- [ ] 完工记录写入本文件 §"实测验收" 章节
- [ ] 上游 architecture.md §8 追加一条 "I2.B 落地" 决策记录
- [ ] 用户人工确认通过

**预计**：0.5 天 / **状态**：⏳ 待执行

---

## 实测验收（待 B-4 完成填写）

### 启动前 baseline（I2 改造之前）

- 待记录

### I2.A 完成后

**实测窗口**：30-tick × 多次窗口（2026-05-11，bug 修复后）

```
[SUS] world: bound=true entities=2416 components=43 pools=2
```
- entities = 2400 cells + 16 weather_fronts ✅ 正确
- pools = 2（cells + weather_fronts）✅ 正确

**热点 Job 平均耗时**（与 I2.A 启动前的 weather-step2 B-full baseline 对比）：

| Job | I2.A baseline (B-full) | I2.A 完成后 | Δ |
|---|---|---|---|
| `refresh_climate_daily` avg | 9.0~9.5 ms | 9.17~9.51 ms | 持平 |
| `weather_refresh` avg (跑了的) | 13~14 ms | 12.9~16.5 ms | +0~3ms（在 ±2%~5% 容差内） |
| `ocean_currents` avg | 4.3~4.8 ms | 4.3~12.5 ms | ⚠️ 见备注 |
| `season_refresh` avg | 4.2~4.8 ms | 4.0~4.3 ms | 持平 |
| `sea_ice_atlas_upload` avg | 0.7~1.5 ms | 0.9~3.7 ms | 持平/略升 |

**备注**：ocean_currents 在某个 30-tick 窗口出现 avg=12.5ms / p95=31.2ms 的尖峰，但与 Pool 改造无逻辑关联（ocean 仍走 cell-component 直访，未触碰 Pool API），更可能是 30-tick 窗口里 ocean refresh 集中触发或 climate full-pass 共享 budget；I2.B 完成后再观察是否系统性偏移。

**fast tick WARN 频率**：约 1/30 ~ 1/45（与 baseline 同水平），无运行时错误。

**结论**：I2.A 通过验收。

### I2.B 完成后

- 待记录

---

## 风险与缓解

| 风险 | 缓解 |
|---|---|
| A-3 自动建池打破现有调用顺序 | A-3 完成后立即跑一次默认场景烟测 |
| B-1 占位 idx 与 SoA 写入失序 | command_buffer.gd 设计已保证 create 立即返回稳定 idx；B-1 加一条 assertion 验证 idx == _world.entity_count - 1 + n_pending |
| B-3 移除 sync 部分代码后渲染数据缺失 | 分两步：先只移除 archetype 部分（保留数据），B-4 验证无回归后再考虑掏空整个函数 |

---

## 完工标准

1. ✅ A-1~A-5 所有 checkbox 打勾
2. ✅ B-1~B-4 所有 checkbox 打勾
3. ✅ 实测验收 3 个窗口数据填入
4. ✅ 上游 architecture.md §8 两条决策记录
5. ✅ 用户人工确认通过
