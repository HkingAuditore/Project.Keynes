# Project.Keynes — DCSystem + DCSystemScheduler 设计文档（A2 / A3）

> 本文档配套实现：
> - DCSystem 基类 → [`scripts/data_core/dc_system.gd`](../Project/project-keynes/scripts/data_core/dc_system.gd)
> - DCSystemScheduler → [`scripts/data_core/dc_system_scheduler.gd`](../Project/project-keynes/scripts/data_core/dc_system_scheduler.gd)
> - DCWorld debug hook → [`scripts/data_core/world.gd`](../Project/project-keynes/scripts/data_core/world.gd) `_debug_begin_pass / _debug_end_pass / _debug_check_write`
> - 单测 → [`tests/dc_system_test.gd`](../Project/project-keynes/tests/dc_system_test.gd)
> - 6 个生产 system 改写 → [`scripts/simulation/systems/`](../Project/project-keynes/scripts/simulation/systems/)
>
> 配套阅读：
> - 设计动因 → [`dots-migration-roadmap.md §3 A2/A3`](./dots-migration-roadmap.md)
> - 历史对照 → [`dots-experiment-report.md §3 / §3.6`](./dots-experiment-report.md)（A2 沙盒实验 + RealJobs J=8 +5.08% overhead 实测）
> - 单模块迁移流程 → [`dots-migration-roadmap.md §5`](./dots-migration-roadmap.md)（DCSystem 是该流程的 Step 3 关键产物）
> - 性能契约 → [`performance-charter.md §10`](./performance-charter.md)

---

## 1. 这是什么 / 解决什么问题

### 1.1 问题（A2/A3 改造前的状态）

每个 system（job）独立维护：

```gdscript
# refresh_climate_daily_job.gd（改造前 419 行）
var _comp_cell_temp: int = -1
var _comp_cell_temp_baseline: int = -1
var _comp_cell_temp_30d: int = -1
# ... 25 行重复模板 ...

func _on_world_bound() -> void:
    _comp_cell_temp = _world.component_id(DCComponentIds.CELL_TEMP)
    _comp_cell_temp_baseline = _world.component_id(DCComponentIds.CELL_TEMP_BASELINE)
    # ... 25 行手写 ...
```

3 个问题：

1. **不可重复**：每个新 system 都要拷一份 25 行模板
2. **失同步**：改 component 名时容易漏改某个 cache 字段
3. **无校验**：system 写到 `cell.weather_intensity` 但没声明 → 没人检查

### 1.2 解法（A2 + A3）

**A2: DCSystem 基类**

```gdscript
class_name DCSystem extends RefCounted

func declare_reads() -> Array[StringName]: return []
func declare_writes() -> Array[StringName]: return []
func declare_pools() -> Array[StringName]: return []
func declare_archetypes() -> Array[StringName]: return []
func feature_flag() -> StringName: return &""
func setup(world) -> void: ...        # 自动 cache 25 个 cid 到 _cid 字典
func tick(ctx) -> Dictionary: return {"done": true}
```

子类只需声明 reads/writes，基类自动把所有 component_id 解析到 `_cid` 字典。

**A3: DCSystemScheduler**

合并 [`SlicedUpdateScheduler`](../Project/project-keynes/scripts/simulation/sus/sus_scheduler.gd) 与 [`DCEcsScheduler`](../Project/project-keynes/scripts/ecs/dc_ecs_scheduler.gd) 的能力：

| 维度 | 现 SUS | 现 DCEcs | DCSystemScheduler |
|---|---|---|---|
| 触发模型 | tick + policy | one-shot | tick + policy（保留）|
| 依赖描述 | depends_on (StringName) | reads/writes (comp_id) | **两者都接受** |
| 切片预算 | frame_budget_ms | 无 | 保留 |
| reads/writes 校验 | 无 | 无 | 🆕 debug 构建 `_world._debug_begin_pass` 包裹 system tick |
| 拓扑排序 | 无 | Kahn O(J²) | 保留 |
| starvation 防护 | 有 | 无 | 保留 |

实现策略：内部持一个 `SlicedUpdateScheduler` 实例做实际 tick，自己负责拓扑排序 + reads/writes 校验包裹。这样最大复用既有的所有 starvation / fast-tick WARN / breakdown 机制。

---

## 2. DCSystem 基类详解

### 2.1 字段（与 SusJob 兼容）

| 字段 | 类型 | 说明 |
|---|---|---|
| `id` | `StringName` | system 唯一 id（如 `&"climate_daily"`）|
| `policy` | `SusPolicy` | 调度策略（`AlwaysPolicy / StridePolicy / ContinuousSlicedPolicy`）|
| `priority` | `int` | 默认 100；DCSystemScheduler 会按拓扑序重写 |
| `depends_on` | `Array[StringName]` | 业务硬序依赖（同 tick 内 A 必须早于 B 完成）|
| `slice_budget_ms` | `float` | 单 slice 软预算 |
| `must_run` | `bool` | 是否绕过 frame_budget |
| `starvation_threshold` | `int` | 饥饿防护阈值 |

### 2.2 declare_* 系列

| 方法 | 返回 | 用途 |
|---|---|---|
| `declare_reads()` | `Array[StringName]` | 调度器拓扑边 + debug 校验 |
| `declare_writes()` | `Array[StringName]` | 同上 + 自动 swap_double_buffer 候选 |
| `declare_pools()` | `Array[StringName]` | 启动期 sanity check：所有声明 pool 都已 create_pool |
| `declare_archetypes()` | `Array[StringName]` | 同上：所有声明 archetype 都已 create_archetype |
| `feature_flag()` | `StringName` | 关联 DCFeatureFlags.FLAGS；register_system 时 gating |

### 2.3 自动 cache

基类 `setup(world)` 默认实现：

```gdscript
func setup(w) -> void:
    _cid.clear()
    for comp_name in declare_reads():
        _cid[comp_name] = int(w.component_id(comp_name))
    for comp_name in declare_writes():
        if not _cid.has(comp_name):
            _cid[comp_name] = int(w.component_id(comp_name))
```

子类 tick 直接：

```gdscript
func tick(ctx) -> Dictionary:
    var temp: PackedFloat32Array = _world.view_f32(_cid[DCComponentIds.CELL_TEMP])
    # 不需要手写 _comp_cell_temp 字段，不需要在 _on_world_bound 里手动 cache
```

### 2.4 与 SusJob 的兼容性

DCSystem 的字段和方法签名与 [`SusJob`](../Project/project-keynes/scripts/simulation/sus/sus_job.gd) 完全对齐：

```
SusJob.id ↔ DCSystem.id
SusJob.policy ↔ DCSystem.policy
SusJob.priority ↔ DCSystem.priority
SusJob.depends_on ↔ DCSystem.depends_on
SusJob.run_slice(ctx) ↔ DCSystem.run_slice(ctx) → tick(ctx)
SusJob.should_run(ctx) ↔ DCSystem.should_run(ctx)
SusJob.reset_progress() ↔ DCSystem.reset_progress()
SusJob.bind_world(w) ↔ DCSystem.bind_world(w)
```

这意味着 **DCSystem 实例可被现有 `SlicedUpdateScheduler.register_job` 直接接受**，不必等 DCSystemScheduler 全面接入。这是 C.3 选择 wrapper-first 路线的物理基础——6 个 system 已立刻可被两个调度器消费。

---

## 3. DCSystemScheduler 详解

### 3.1 注册与拓扑构造

```gdscript
var dcs := DCSystemScheduler.new()
dcs.bind_world(world)  # 注入 DCWorld

# Register systems (顺序无关；拓扑排序会自动派生执行序)
dcs.register_system(EnumAtlasUploadSystem.new(...), cp)  # cp=ClimateProfile（feature_flag 校验用）
dcs.register_system(SeaIceAtlasUploadSystem.new(...), cp)
dcs.register_system(SeasonRefreshSystem.new(...), cp)
dcs.register_system(OceanCurrentsSystem.new(...), cp)
dcs.register_system(ClimateDailySystem.new(...), cp)
dcs.register_system(WeatherDCSystem.new(), cp)

# 关键：必须显式 build_topology() —— 让 caller 控制时机
if not dcs.build_topology():
    push_error("scheduler: cycle in reads/writes graph")
    return

# 跑 tick
dcs.tick(ctx)
```

### 3.2 拓扑算法

与 [`DCEcsScheduler.topo_sort`](../Project/project-keynes/scripts/ecs/dc_ecs_scheduler.gd) 同算法（Kahn O(J²) + 环检测），仅把 comp_id (int) 替换为 StringName 比较：

- writer system 必须早于 reader system（RAW 边）
- writer 之间按注册顺序排序（WAW 边，避免不确定性）
- 环检测：`order.size() != n` 时 push_error 中止 build_topology()

J=8 实测 +5.08% 调度器开销（[`dots-experiment-report §3.6`](./dots-experiment-report.md)），远低于 25% 红线。

### 3.3 reads/writes 自动校验

debug 构建下，DCSystemScheduler.tick() 包裹一对 `_world._debug_begin_pass / _debug_end_pass`：

```gdscript
func tick(ctx) -> void:
    if OS.is_debug_build():
        _world._debug_begin_pass(all_writes_union, all_reads_union, &"dc_system_scheduler.tick")
    _sus.tick(ctx)
    if OS.is_debug_build():
        _world._debug_end_pass(...)
```

future iteration：在 `world.write_f32 / write_i32 / write_u8` 等写入 API 内部插入 `_debug_check_write(comp_id)` 调用——任何写到非声明 component 的代码立即 push_error。当前已暴露 hook（`_debug_check_write`），算法验证完整即可启用。

### 3.4 feature_flag gating

```gdscript
func register_system(system, cp = null) -> void:
    var ff: StringName = system.feature_flag()
    if ff != &"" and cp != null:
        if not DCFeatureFlags.is_on(ff, cp):
            return  # silently skip
    _systems.append(system)
```

让"模块 A 走 dots_cpp、模块 B 仍 legacy"成为单 flag toggle（与 dots-migration-roadmap §5 SOP Step 4 一致）。

---

## 4. 6 个 system 改写 case study（C.3）

| Job | 行数 | 改写产物 | 策略 | 备注 |
|---|---|---|---|---|
| `EnumAtlasUploadJob` | 68 | [`enum_atlas_upload_system.gd`](../Project/project-keynes/scripts/simulation/systems/enum_atlas_upload_system.gd) | **原生 DCSystem** | declare_reads = [cover, vegetation]；行为 1:1 复刻 |
| `SeaIceAtlasUploadJob` | 69 | [`sea_ice_atlas_upload_system.gd`](../Project/project-keynes/scripts/simulation/systems/sea_ice_atlas_upload_system.gd) | **原生 DCSystem** | declare_reads = [sea_ice_frac]；行为 1:1 复刻 |
| `SeasonRefreshJob` | 70 | [`season_refresh_system.gd`](../Project/project-keynes/scripts/simulation/systems/season_refresh_system.gd) | **原生 DCSystem** | 11-stage round 切片仍委派给 generator |
| `OceanCurrentsJob` | 181 | [`ocean_currents_system.gd`](../Project/project-keynes/scripts/simulation/systems/ocean_currents_system.gd) | **wrapper** | 内部持 OceanCurrentsJob 实例；181 行物理化求解逻辑零改动 |
| `RefreshClimateDailyJob` | 419 | [`climate_daily_system.gd`](../Project/project-keynes/scripts/simulation/systems/climate_daily_system.gd) | **wrapper** | 同上；25 行手写 _comp_cell_* 在内部 SusJob 里仍存在（双重 cache，可在后续 PR 删除） |
| `WeatherRefreshJob` | 585 | [`weather_system.gd`](../Project/project-keynes/scripts/simulation/systems/weather_system.gd)（class `WeatherDCSystem`）| **wrapper** | 类名不叫 WeatherSystem，避免与 `weather/weather_system.gd::WeatherSystem` 业务类冲突 |

**为什么用 wrapper-first 策略？**

3 个大型 job（181/419/585 行）的内部状态机非常复杂（dirty mask 钩子 / round 切片 / ECB pool sync / dirty short-circuit / DataCore mirror toggle 等等）。一次性原生改写风险高、回归代价大；wrapper 模式让 declare_* 与调度框架立刻可用，业务逻辑慢慢搬迁。

**后续清理路径**：

1. ClimateDailySystem 内部的 `_inner._on_world_bound` 中 25 行 `_comp_cell_*` cache 可以删除——基类 setup() 已自动 cache 到 `_cid`；改用 `_cid[CELL_TEMP]` 替代 `_comp_cell_temp`
2. WeatherRefreshJob 同理（17 个 cache 字段）
3. OceanCurrentsJob 体量较小，可以做完整原生 rewrite

---

## 5. 加新 system 的 SOP（与 dots-migration-roadmap §5 配合）

### Step 1 — extends DCSystem

```gdscript
class_name MyEconomySystem extends DCSystem
```

### Step 2 — 重写 declare_*

```gdscript
func declare_reads() -> Array[StringName]:
    return [&"cell.population", &"cell.tax_base"]
func declare_writes() -> Array[StringName]:
    return [&"cell.gdp", &"cell.unemployment"]
func declare_pools() -> Array[StringName]: return [&"cells"]
func feature_flag() -> StringName: return &"use_dots_economy"
```

### Step 3 — 实现 tick

```gdscript
func tick(ctx) -> Dictionary:
    var pop = _world.view_f32(_cid[&"cell.population"])  # 基类已自动 cache
    var gdp = _world.view_f32(_cid[&"cell.gdp"])
    # 算法主体—只能读 declare_reads / 写 declare_writes 内的 component
    return {"done": true, "elapsed_ms": elapsed, "progress_ratio": 1.0}
```

### Step 4 — 注册

```gdscript
# bootstrap
if DCFeatureFlags.is_on(&"use_dc_system_scheduler", cp):
    var dcs = DCSystemScheduler.new()
    dcs.bind_world(world)
    dcs.register_system(MyEconomySystem.new(), cp)  # 自动按 feature_flag gating
    dcs.build_topology()
    # ... use dcs.tick(ctx)
else:
    var sus = SlicedUpdateScheduler.new()
    sus.register_job(MyEconomySystem.new())  # 同样可工作（DCSystem 兼容 SusJob）
    # ... use sus.tick(ctx)
```

---

## 6. 反模式黑名单

| ❌ 反模式 | 后果 | 正确做法 |
|---|---|---|
| 子类手写 `_comp_cell_xxx: int = -1` 字段 | 与基类 `_cid` 字典重复，且每加新字段两处维护 | 用 `_cid[DCComponentIds.CELL_XXX]` |
| 子类手写 `_on_world_bound` 里 25 行 `component_id(...)` cache | 基类 setup() 已自动做了 | 删除手写 cache；如有非 schema 的 prefetch 才重写 `_on_world_bound` |
| 写到非 declare_writes 的 component | debug 构建会 push_error；release 静默成 bug | 准确声明 declare_writes（首次违约时根据 error log 补上） |
| 注册后忘了 `build_topology()` | tick() 时 push_error 中止 | 注册全部 system 后必须显式调一次 |
| 同 component 读+写交叉的两个 system 没声明 reads/writes | 拓扑排序得到任意序，每次启动可能不同 | 严格声明，让拓扑算法决定执行序 |
| feature_flag 名 typo（不在 FLAGS 表） | DCFeatureFlags.is_on 默认 false，system 永远不挂载 | DCFeatureFlags 启动期 sanity check 会报警 |

---

## 7. 当前限制 / Future iteration

1. **per-system reads/writes 校验**：当前是 whole-tick 维度（`_debug_begin/end_pass` 包整个 tick）。per-system 维度需要在 SUS 内部加 hook，让每个 system 的 tick 前后单独校验。
2. **自动 swap_double_buffer**：调度器还没在 system tick 后自动调 `world.swap_double_buffer(declare_writes())`——目前业务侧仍手动 swap。
3. **拓扑 cache**：build_topology() 每次都从头算；jobs 不变时可以 cache。当前 J ≤ 8 算一次几 µs，未优化也可。
4. **wrapper 删除**：3 个大型 system 的 wrapper 模式让代码量略增（每 wrapper +100 行 declare_* + forward）；后续把内部 SusJob 字段 inline 进 wrapper 后能省 ~300 行。

---

**END of dots-system-design.md.**
