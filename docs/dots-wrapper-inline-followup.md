# Phase 1.5 — Wrapper System Inline 化 Follow-up

> 状态：1/3 完成（ClimateDailySystem ✅）；OceanCurrentsSystem / WeatherDCSystem 待 inline。
> 关联：[`完全 DOTS 化路线规划`](../.cursor/plans) / [`dots-system-design.md`](./dots-system-design.md) §4
> 创建：2026-05-14

---

## 1. 现状速览

3 个 daily-tick 业务 system 中：

| System | 状态 | 说明 |
|---|---|---|
| [`ClimateDailySystem`](../Project/project-keynes/scripts/simulation/systems/climate_daily_system.gd) | ✅ **已 inline** | extends DCSystem 直接持有 419 行 6-stage round 逻辑；25 个 _comp_cell_* 已通过基类 `setup()` 自动 cache 到 `_cid` 字典 |
| [`OceanCurrentsSystem`](../Project/project-keynes/scripts/simulation/systems/ocean_currents_system.gd) | ⏳ wrapper | 持有 `_inner: OceanCurrentsJob`，`tick()` forward 到 `_inner.run_slice()` |
| [`WeatherDCSystem`](../Project/project-keynes/scripts/simulation/systems/weather_system.gd) | ⏳ wrapper | 持有 `_inner: WeatherRefreshJob`，`tick()` forward 到 `_inner.run_slice()` |

剩余 inline 工作量约 800+ 行代码搬迁，分两个独立 PR 实施，不阻塞后续 phase（Phase 2 / 3 / 4 都不依赖 inline 完成）。

---

## 2. PR-1.5.b — OceanCurrentsSystem inline 化

**文件**：[`ocean_currents_system.gd`](../Project/project-keynes/scripts/simulation/systems/ocean_currents_system.gd)
**源文件**：[`ocean_currents_job.gd`](../Project/project-keynes/scripts/simulation/sus/jobs/ocean_currents_job.gd) (~181 行)

### 步骤

1. **复制成员字段**（参照 ClimateDailySystem line 71-103 模板）：
   ```gdscript
   var generator = null
   var baker: MapBaker = null
   var map: MapData = null
   var world: WorldData = null
   var cfg: MapConfig = null
   var hex_size: float = 16.0
   var period_ticks: int = 30
   var slice_count: int = 10
   var on_commit: Callable = Callable()
   var season_phase_getter: Callable = Callable()
   var _ocean_phase_locked: float = 0.0
   var _slice_cursor: int = 0
   var _round_active: bool = false
   ```

2. **搬迁 `run_slice(ctx)` 主体**（OceanCurrentsJob.run_slice 全部内容，~100 行）。

3. **删除 `_inner: OceanCurrentsJob`** + 相关 forward 方法（`tick` / `set_on_commit` / `set_season_phase_getter` / `get_inner`）。

4. **`_init` 重构**：直接初始化字段，不再 `_inner = OceanCurrentsJob.new(...)`。
   ```gdscript
   func _init(p_baker, p_map, p_world, p_cfg, p_hex_size, p_period_ticks, p_slice_count) -> void:
       id = &"ocean_currents"
       priority = 200
       slice_budget_ms = 6.0
       must_run = true
       baker = p_baker
       map = p_map
       world = p_world
       cfg = p_cfg
       hex_size = p_hex_size
       period_ticks = max(1, p_period_ticks)
       slice_count = max(1, p_slice_count)
       policy = SusPolicyScript.PeriodicPolicy.new(period_ticks, 0)
   ```

5. **`map_generator.gd` 调用 site 更新**（line ~952-958）：
   ```gdscript
   if _use_dc_system_scheduler:
       var ocean_sys = OceanCurrentsSystemScript.new(_baker, map, world, cfg, hex_size, period_ticks, slice_count)
       _ocean_currents_job = ocean_sys  # 不再 .get_inner()
       _ocean_currents_job.depends_on.append(&"season_refresh")
       _ocean_currents_job.on_commit = func():
           _compute_ocean_currents(map, world, hex_size)
       if _world_clock_ref != null:
           _ocean_currents_job.season_phase_getter = Callable(_world_clock_ref, "season_phase")
       _sus.register_system(ocean_sys)
   ```

### 验收（charter §12.4 七步 SOP）

- 跑 SUS 30-tick 日志，OceanCurrents 段 avg / p95 与 wrapper 路径 ±3%
- 洋流贴图截图像素 diff < 0.1%（第 1 / 10 / 30 tick）
- `rg "_inner" -t gd` 在 ocean_currents_system.gd 内 = 0

---

## 3. PR-1.5.c — WeatherDCSystem inline 化

**文件**：[`weather_system.gd` (DCSystem)](../Project/project-keynes/scripts/simulation/systems/weather_system.gd)
**源文件**：[`weather_refresh_job.gd`](../Project/project-keynes/scripts/simulation/sus/jobs/weather_refresh_job.gd) (~585 行)

### 注意点

WeatherRefreshJob 是 3 个里最复杂的：
- 包含 field solver 三段式（pre / solve / commit）
- ECB drain（front pool create/destroy via DCWorld CommandBuffer）
- climate_anomaly_getter / season_index_getter / season_phase_getter 三个 callable
- DCWorld pool_create_in_pool 集成

### 步骤

1. **复制 ~30 个成员字段**（参照 weather_refresh_job.gd top）。

2. **搬迁 `run_slice(ctx)` + 内部 `_run_field_solver_*` 系列方法**（~250 行）。

3. **删除 `_inner: WeatherRefreshJob`** + 相关 forward 方法（`tick` / `get_inner`）。

4. **删除 13+6 个 _comp_cell_* cache**（_on_world_bound 中手写）——基类 DCSystem.setup() 已通过 declare_reads() 自动 cache 到 _cid。

5. **`map_generator.gd` 调用 site 更新**（line ~1040-1049）：
   ```gdscript
   if _use_dc_system_scheduler:
       var weather_dc_system = WeatherDCSystemScript.new(self, map, world, ...)
       _weather_refresh_job = weather_dc_system  # 不再 .get_inner()
       _weather_refresh_job.depends_on.append(&"refresh_climate_daily")
       _sus.register_system(weather_dc_system)
   ```

### 验收

- SUS 30-tick log，advance_ms / spawn_ms / distribute_ms / cyclone_ms 与 wrapper 路径 ±3%
- weather front 数 / 类型分布、视觉无 diff（30 days soak）
- `rg "_inner" -t gd` 在 weather_system.gd (DCSystem) 内 = 0

### 不需要改

Phase 1.3 F.6 fast-path 在 [`weather/weather_system.gd::tick_one_day`](../Project/project-keynes/scripts/weather/weather_system.gd) 内（**业务 WeatherSystem，不是 DCSystem 调度入口**）。inline 化只动 [`simulation/systems/weather_system.gd`](../Project/project-keynes/scripts/simulation/systems/weather_system.gd)（DCSystem wrapper）；F.6 的 batch 提取 + C++ 调度逻辑不动。

---

## 4. 解锁的好处

inline 化完成后：

1. **删除 ~25 行 _comp_cell_* 冗余 cache**（charter 反模式），全部由基类 `_cid` 字典统一管理；
2. **删除 ~50 行 wrapper forward 代码**（_init mirror + tick forward + 各 callable forward）；
3. **简化调用栈**：`scheduler.tick → wrapper.tick → _inner.run_slice` 变成 `scheduler.tick → system.run_slice` 一层；
4. **统一 system 模板**：3 个 daily system 全部 IS-A SusJob 直接，便于 Phase 3 拆分时按统一模式抽组件。

---

## 5. 风险

| 风险 | 缓解 |
|---|---|
| weather_refresh_job 585 行内部状态 inline 时漏字段 | 单独 PR + bit-equal 30-day soak；先跑原 wrapper baseline，再跑 inline 路径，二者 SUS 日志逐字段比对 |
| ocean_currents on_commit / season_phase_getter callable 注入时机变了 | inline 化后字段命名保持完全一致；map_generator 调用 site 仅去掉 `.get_inner()` 一处 |
| DCWorld pool ECB 集成在 inline 时容易破 | weather inline 时整段 `_drain_ecb_*` / `pool_create_in_pool` 代码块完整搬迁，不切片 |

---

## 6. 时间线

- **PR-1.5.b OceanCurrentsSystem inline**：~1 天（181 行，模板已就位）
- **PR-1.5.c WeatherDCSystem inline**：~3 天（585 行，含 bit-equal 验收）

总计 ~1 周（与 plan §1 §1.5 W5-W6 对齐）。

---

**END.**
