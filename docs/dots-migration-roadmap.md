# Project.Keynes — DOTS 迁移路线图（可落地实施规划）

> 🟢 **框架硬化 Phase A+B+C+D 已完成**（2026-05-13）：阶段 0 + 阶段 I 全部落地，
> 详见 §3 表格、§4.2 / §4.3 实际行数、§9 已迁移模块清单 + 配套文档
> [`dots-framework-status.md`](./dots-framework-status.md) /
> [`module-ownership-map.md`](./module-ownership-map.md) /
> [`dots-component-schema.md`](./dots-component-schema.md) /
> [`dots-view-adapter-guide.md`](./dots-view-adapter-guide.md) /
> [`dots-system-design.md`](./dots-system-design.md)。
>
> 本文档定位：把 [`DOTS review.md`](./DOTS%20review.md) 的"现状评估"翻译成
> "可逐模块执行的工程方案"。任何一个想做 DOTS 化的模块（climate /
> weather / economy / unit / AI / pollution …）都按本文档的 SOP 走。
>
> 配套文档：
> - 现状评估与缺口 → [`DOTS review.md`](./DOTS%20review.md)
> - 性能契约（铁律 / 反模式 / SIMD 触发条件）→ [`performance-charter.md`](./performance-charter.md)
> - C++/GDScript 通信参考实现 → [`performance-charter.md §12`](./performance-charter.md#12-cgdscript-通信参考实现reference-implementation)
> - C++/GDScript 协作操作手册 → [`cpp-gdscript-best-practices.md`](./cpp-gdscript-best-practices.md)
> - DOTS 实验报告（A1/A2/B0 实测结论）→ [`dots-experiment-report.md`](./dots-experiment-report.md)
> - C++ async 实验报告 → [`cpp-async-experiment-report.md`](./cpp-async-experiment-report.md)
>
> 责任人：本路线图由"动 DCWorld / 调度器 / hot-loop"的 PR 提交者维护。任何
> 偏离本路线图的设计选择必须在 PR 描述里写明理由。

---

## 0. TL;DR — 三句话能记住的事

1. **review 文档的事实陈述是可信的**——`world.gd / query.gd / command_buffer.gd /
   sus_scheduler.gd / dc_ecs_scheduler.gd / world_ext.cpp` 的状态、`bind_map_data`
   里 ~41 行手写 attach、`flush_soa_to_cells` 同步税、两套调度器并存——全部
   与代码 1:1 吻合。可以放心按 review 的 P0–P2 七条架构债施工。
2. **"按模块迁移、互不影响"在当前架构下还做不到**——根因不是 DCWorld 不够 ECS，
   而是 `map_generator.gd` (4639 行) / `weather_system.gd` (2142 行) /
   `map_baker.gd` (2583 行) / `main.gd` (1901 行) 是巨石模块。**先做模块边界收敛
   （阶段 0），再做 DOTS 化（阶段 I~IV）**——否则任何一刀都会跨 4 个文件连锁。
3. **第一刀建议是 ViewAdapter（B2）+ map_baker 切分（阶段 0.3）**，不是 review
   建议的 P0-1 ComponentSchema。理由见 §6——读侧解耦后，所有后续 DOTS 数据
   迁移对 UI/renderer 透明，是最高杠杆点。

---

## 1. 现状评估摘要（与 review 文档对齐）

详细评估见 [`DOTS review.md`](./DOTS%20review.md)。本节仅复述 7 条架构债的标题与
代码出处，便于本路线图章节交叉引用：

| 编号 | 架构债 | 代码出处 | 优先级 |
|---|---|---|---|
| P0-1 | 缺 ComponentSchema 单一源 | `world.gd::bind_map_data` 41 行手写 | 🔴 高 |
| P0-2 | 数据所有权未下移到 DCWorld(Ext) | `weather_system / map_generator / map_data` 三处副本 | 🔴 高 |
| P1-1 | 两套调度器并行 + 不互通 | `sus_scheduler.gd` 352 行 / `dc_ecs_scheduler.gd` 157 行 | 🟠 中 |
| P1-2 | 缺 DCSystem 抽象 | `refresh_climate_daily_job / weather_refresh_job` 各写各的 | 🟠 中 |
| P1-3 | C++ 端 `_slots[].arr_f32` 是扁平 SoA，无 chunk 重排 | `world_ext.cpp::Slot` | 🟠 中（**条件触发，勿主动启动**） |
| P2-1 | 缺 hot-loop 军规 + reads/writes 自动校验 | `performance-charter §4` 仅文字声明 | 🟡 低 |
| P2-2 | renderer / UI / baker 全没 DOTS 化 | `hex_renderer / map_baker / data_overlay_baker / weather_layer` | 🟡 低 |
| P2-3 | 缺 `DCWorld.serialize / deserialize` | `world.gd` 全文无 | 🟡 低 |

---

## 2. review 文档没充分强调、但对"按模块迁移"是硬阻塞的 4 件事

这 4 件事是后面阶段 0 + B1/B2/B3 三个新抽象的设计动因。

### 2.1 巨石模块挡住"按模块迁移"

| 文件 | 行数 | 涉及职责数 |
|---|---|---|
| `map_generator.gd` | 4639 | 地图生成 + 6 个 daily climate sub-pass + ocean + sea_ice + transp |
| `map_baker.gd` | 2583 | terrain baker + climate baker + weather baker + overlay baker |
| `weather_system.gd` | 2142 | field solver + front advect + spawn + decay + feedback |
| `main.gd` | 1901 | 启动 + 输入 + UI + SUS 注册 + ECS 注册 + 各 demo 接入 |
| `weather_layer.gd` | 1209 | weather 渲染 + UI 上传 + 调试日志 |
| `hex_renderer.gd` | 965 | 主渲染 + atlas 上传 + 多个 baker dispatch |

> 真正的工程瓶颈不是写新 system，是**拆旧巨石**。要把 `_climate_pass_b` 搬进
> C++，连锁要改 `map_generator / refresh_climate_daily_job / map_data /
> info_panel / map_baker` 五个文件。**不先拆巨石就做 DOTS，永远卡在
> "动一处连锁五处"的死循环**。

### 2.2 Feature flag 散落在 `climate_profile.gd`

`climate_profile.gd` 里至少有 12 个 `use_*` / `enable_*` 旗标（`use_data_core /
use_data_core_weather / use_data_core_climate / use_soa_pipeline /
daily_climate_interpolation / use_sparse_climate / use_gdext_climate /
demo_thermal_gradient_enabled / weather_advect_use_wind_vector /
enable_local_climate_coupling / enable_ocean_heat_transport / demo_complex_*…`）。
每加一个 DOTS 模块都要"双轨切换"——这套散乱开关熬不到第 5 个模块就会失控。

### 2.3 C++ `BIND_TABLE` 与 GDScript `_bind_register_and_attach` 是双重维护

`performance-charter §12.6.4 步骤 4` 要求"在 `BIND_TABLE[]` 末尾加一行"，GDScript
端同时也要加一行 `_bind_register_and_attach`。两份表必须一一对应，否则 C++
pass 调 `component_id` 拿到 -1，又退回到"slot 未注册 → 安全 no-op"的**静默失败
路径**。Schema 单一源（review 的 P0-1）必须**同时驱动 C++ 端**，不只是 GDScript 端。

### 2.4 没有"模块迁移沙盒模板"

`dots-experiment-report` 把"先在 `tmp/` 里证伪/证实"的纪律写得很好，但每个新
模块的迁移者要从 `bench_temp_drift.gd` 拷一份重写。bench 风格、assertion 风格、
bit-equal 容差选择都不一致，导致跨模块横向对比困难。**沙盒模板应被显式制度化
为迁移流程的固定一步**。

---

## 3. "按模块迁移、互不影响"要成立必须补的 8 个抽象

这就是"还需要做什么架构上的设计"的核心答案。其中 A1–A4 / C1 来自 review 的
P0-1 / P0-2 / P1-1 / P1-2 / P2-1 / P2-2 / P2-3，B1/B2/B3 是本路线图新增。

| # | 抽象 | 解决的问题 | review 已提 | 实施状态 |
|---|---|---|---|---|
| **A1** | **ComponentSchema 单一源** + 双侧 codegen（GDScript `bind_map_data` & C++ `BIND_TABLE`）| 加新字段从 6 处改成 1 处；C++/GDScript 永不偏离 | ✅ P0-1（**新增**：必须同时驱动 C++ 端）| ✅ **完成**（Phase A.1，2026-05-13）— [`component_schema.gd`](../Project/project-keynes/scripts/data_core/component_schema.gd) + [`gen_cpp_bind_table.py`](../tools/codegen/gen_cpp_bind_table.py) + [`component_bind_table.gen.h`](../gdext/src/component_bind_table.gen.h) + [`dots-component-schema.md`](./dots-component-schema.md) |
| **A2** | **DCSystem 基类**（`declare_reads / writes / pools / archetypes` + `setup / tick`）| 让"加一个新 system"机械化、可重复；调度器自动从 `declare_writes` 算 DAG | ✅ P1-2 | ✅ **完成**（Phase C.1，2026-05-13）— [`dc_system.gd`](../Project/project-keynes/scripts/data_core/dc_system.gd) + [`dc_system_test.gd`](../Project/project-keynes/tests/dc_system_test.gd) + 6 个生产 system 改写 + [`dots-system-design.md`](./dots-system-design.md) |
| **A3** | **统一 DCSystemScheduler**（合并 SUS + DCEcs）+ debug-only `reads/writes` 校验 | 一套调度器、一份语义；hot-loop 军规自动校验违约 | ✅ P1-1 + P2-1 | ✅ **完成**（Phase C.2-C.4，2026-05-13）— [`dc_system_scheduler.gd`](../Project/project-keynes/scripts/data_core/dc_system_scheduler.gd) + DCWorld `_debug_*_pass` hook + use_dc_system_scheduler flag |
| **A4** | **数据所有权下移到 DCWorldExt** + `HexCell` 退化为只读 facade | 砍掉 `flush_soa_to_cells / rebuild_soa_from_cells` 同步税；UI/Baker 从 `view_*` / `snapshot` 读 | ✅ P0-2 + P2-2 | ⏳ 阶段 II（不在本规划） |
| **B1** | 🆕 **Module Manifest** + 中央 **FeatureFlagRegistry**（每模块声明 reads/writes/pools/archetypes/feature_flag/dispatch_paths）| 让"模块互不影响"有声明式契约可查；开关集中管理 | ❌ review 未提 | ✅ **完成**（Phase A.3，2026-05-13）— [`feature_flags.gd`](../Project/project-keynes/scripts/data_core/feature_flags.gd) + [`module_manifest.gd`](../Project/project-keynes/scripts/data_core/module_manifest.gd) |
| **B2** | 🆕 **Read-Side ViewAdapter**（renderer / UI / baker 通过 adapter 读，不直接读 `cell.*` / `map.*`）| 数据侧 DOTS 化时 renderer 一行不动；只换 adapter 实现 | ❌（P2-2 提了"接入 view_*"但没抽象 adapter）| ✅ **完成**（Phase A.2 + B.1 + B.3，2026-05-13）— [`view_adapter.gd`](../Project/project-keynes/scripts/data_core/view_adapter.gd) + [`view_adapter_test.gd`](../Project/project-keynes/tests/view_adapter_test.gd) + main.gd / data_overlay_baker.gd 已接入 + use_world_view_adapter flag A/B 切换 + [`dots-view-adapter-guide.md`](./dots-view-adapter-guide.md) |
| **B3** | 🆕 **MigrationHarness 沙盒模板**（标准化 bench 夹具：bit-equal / micro-bench / 6-step checklist）| 每个迁移者都从同一模板起步；A/B 验收一致 | ❌ review 未提 | ✅ **完成**（Phase A.4，2026-05-13）— [`tools/migration_harness/`](../Project/project-keynes/tools/migration_harness/)（template_bench / template_module_test / template_overlay / README）|
| **C1** | `DCWorld.serialize / deserialize`（按 schema 自动 round-trip）| 存档/热重载/测试夹具的入口 | ✅ P2-3 | ⏳ 阶段 III（不在本规划） |

> review 的 **P1-3（C++ chunk_remap）只在出现 4ms 瓶颈时启动，绝不主动启动**——
> 这一条 review 的判断是对的，原样采纳，不进入本路线图的强制阶段。

---

## 4. 5 阶段路线图

### 4.1 阶段总览

```
┌─ 阶段 0：模块边界收敛（先于一切）────────────────────────────
│  目标：让"动一个模块不连锁改 4 个巨石文件"
│  输出：map_generator / weather_system / map_baker / main 拆分到位
│  验收：30 天 SUS 日志对比 ±5%，行为完全等价
│
├─ 阶段 I：架构债清理（review P0/P1 + 新增 B1/B2/B3）─────────
│  目标：让"加新 DOTS 模块"机械化可重复
│  输出：ComponentSchema / DCSystem / DCSystemScheduler / ViewAdapter /
│       FeatureFlagRegistry / MigrationHarness 全部就位
│  验收：用本阶段产物把 RefreshClimateDailyJob / WeatherRefreshJob 改写一遍
│       且 SUS 日志 ±3%
│
├─ 阶段 II：数据所有权下移（review P0-2 / P2-2）─────────────
│  目标：HexCell / MapData 退化为只读 facade / IO 容器
│  输出：flush_soa_to_cells 删除；hot pass 写路径全部走 world.write_*
│  验收：weather / climate full pipeline bit-equal vs legacy
│
├─ 阶段 III：序列化 / 测试基建（review P2-3）──────────────
│  目标：DCWorld.serialize / deserialize；FeatureFlag hot-reload
│  输出：存档系统的 DOTS 入口；soak-test 夹具
│  验收：10 周年存档 round-trip bit-equal
│
└─ 阶段 IV（条件触发，不主动启动）：物理优化 ────────────────
   IV.1 D-async 接入 production climate Pass-A（已有沙盒）
   IV.2 _chunk_remap（review P1-3，等 4ms/帧瓶颈再启动）
   IV.3 SIMD（performance-charter §3.1 全部条件满足时）
```

### 4.2 阶段 0：模块边界收敛（**必须先做**）

> ⚠ 阶段 0 不引入任何 DOTS 抽象，仅做"按职责拆文件 + 把字段访问收敛到入口
> 函数"。bit-equal 验收靠 main.gd 跑 30 天 SUS 日志对比 ±5%。

#### 0.1 拆 `map_generator.gd` 4639 行

| 拆出文件 | 职责 | 估算行数 |
|---|---|---|
| `geography/map_generation/terrain_gen.gd` | 大陆/高度场/河流/湖泊/雨影/biome（一次性烘焙）| ~1500 |
| `simulation/climate/pass_a.gd` | 裸基线 temp/moisture/snow_cover + EMA | ~600 |
| `simulation/climate/pass_b.gd` | 局部气候耦合（可选）| ~700 |
| `simulation/ocean/water_pass.gd` | 洋流热输运·水段 | ~400 |
| `simulation/ocean/land_pass.gd` | 洋流热输运·陆段 | ~400 |
| `simulation/sea_ice/daily_pass.gd` | 海冰逐日演替 | ~400 |
| `simulation/biology/transpiration_pass.gd` | 植被→湿度反馈 | ~300 |
| `geography/diagnostics_bus.gd` | `_last_*_breakdown` 等埋点字段统一收纳 | ~150 |
| 残留 `map_generator.gd` | 入口 + 注册 + 弱协调 | ~200 |

#### 0.2 拆 `weather_system.gd` 2142 行

| 拆出文件 | 职责 | 估算行数 |
|---|---|---|
| `weather/field_solver.gd` | vapor / cloud / precip / instability 三段式 hot loop | ~900 |
| `weather/front_advect.gd` | 16 fronts 推进 / decay / age++ | ~250 |
| `weather/front_spawn.gd` | spawn 概率评分 + ocean bias | ~350 |
| `weather/feedback.gd` | cell.cover 短期改写 + moisture 调整 | ~200 |
| `weather/summary_builder.gd` | flood-fill 聚类 + cluster 身份继承 | ~300 |
| 残留 `weather_system.gd` | 入口 + 状态机协调 | ~150 |

#### 0.3 拆 `map_baker.gd` 2583 行

| 拆出文件 | 职责 | 估算行数 |
|---|---|---|
| `rendering/bakers/terrain_baker.gd` | terrain / landform / vegetation 烘焙 | ~600 |
| `rendering/bakers/climate_baker.gd` | temperature / moisture / snow_cover overlay | ~500 |
| `rendering/bakers/weather_baker.gd` | weather field / fronts 上传 | ~600 |
| `rendering/bakers/overlay_baker.gd` | data overlay / debug overlay | ~500 |
| `rendering/bakers/baker_context.gd` | 共享 ViewAdapter / dirty mask / atlas pool | ~200 |
| 残留 `map_baker.gd` | 入口 + 调度多 baker | ~150 |

#### 0.4 拆 `main.gd` 1901 行

把"SUS 注册 / DOTS bootstrap / demo 接入 / 输入 / UI"分别搬到独立 `bootstrap_*.gd`
文件，残留 `main.gd` 仅做生命周期编排（< 400 行）。

#### 0.5 阶段 0 验收

| 项 | 通过标准 |
|---|---|
| 编译 / 启动 | 无 parse error，进游戏画面与拆分前像素级一致 |
| 30 天 SUS 日志 | 各 Job avg / p95 / slices ±5% 内 |
| 截图比对 | 截 5 帧（春/夏/秋/冬 + 暴风）vs 拆分前像素 diff < 0.1% |
| `git diff` 行数 | 几乎全是文件搬迁，业务逻辑改动 < 100 行 |

### 4.3 阶段 I：架构债清理

#### I.1 ComponentSchema 单一源（A1）

```gdscript
# scripts/data_core/component_schema.gd —— 唯一真值表
class_name DCComponentSchema
const CELL_SCHEMA: Array[Dictionary] = [
    { name = &"cell.temp",       dtype = F32, track_prev = true,
      owner = "climate.pass_a",  cpp_pass_uses = ["climate_pass_a"] },
    { name = &"cell.moisture",   dtype = F32, track_prev = true,
      owner = "climate.pass_b",  cpp_pass_uses = ["climate_pass_b"] },
    { name = &"cell.has_river",  dtype = U8,  track_prev = false,
      owner = "map_generation",  cpp_pass_uses = [] },
    # ... 41 条
]
```

派生产物：
- `world.gd::bind_map_data` 用 `for entry in CELL_SCHEMA: _bind_register_and_attach(...)`
  替换 41 行手写 → ~3 行
- `tools/codegen/gen_cpp_bind_table.py` 从 schema 生成
  `gdext/src/component_bind_table.gen.h`，C++ 端 `BIND_TABLE` 不再手写
- `tools/dots_lint.gd` debug-only：扫 hot 函数（命名 `run_*` / `_pass` / `_step`）
  内是否出现 `cell.<field>` 直接读，违反 owner 声明 → push_warning

#### I.2 DCSystem 基类（A2）

```gdscript
# scripts/data_core/dc_system.gd
class_name DCSystem extends RefCounted

# 声明（_on_world_bound 时调一次）
func declare_reads() -> Array[StringName]: return []
func declare_writes() -> Array[StringName]: return []
func declare_pools() -> Array[StringName]: return []
func declare_archetypes() -> Array[StringName]: return []
func feature_flag() -> StringName: return &""

# 运行
func setup(world: DCWorld) -> void: pass    # 解析 comp_id 缓存（自动）
func tick(ctx: SusTickContext) -> Dictionary: return {"done": true}
```

迁移现有 6 个 SusJob：
- `RefreshClimateDailyJob` → `ClimateDailySystem`（`declare_writes` 含 25 个 climate component）
- `WeatherRefreshJob` → `WeatherSystem`（`declare_pools = [POOL_WEATHER_FRONTS]`）
- `OceanCurrentsJob` → `OceanCurrentsSystem`
- `SeaIceAtlasUploadJob` → `SeaIceAtlasUploadSystem`
- `EnumAtlasUploadJob` → `EnumAtlasUploadSystem`
- `SeasonRefreshJob` → `SeasonRefreshSystem`

DCSystem 与 SusJob **兼容并存期**：DCSystem 可被 SusScheduler 当成 SusJob 跑
（adapter pattern），让阶段 I 不阻塞业务侧 PR。

#### I.3 统一 DCSystemScheduler（A3）

| 维度 | 现 SUS | 现 DCEcs | 合并后 DCSystemScheduler |
|---|---|---|---|
| 触发模型 | tick-based + policy | one-shot | tick-based + policy（保留）|
| 依赖描述 | `depends_on` (StringName) | `reads/writes` (comp_id) | **两者都接受**：业务硬序仍走 depends_on，自动校验/排序走 reads/writes |
| 切片预算 | `frame_budget_ms + slice_budget_ms` | 无 | 保留 |
| 自动 swap | 无 | 无 | 🆕 调度器自动 `world.swap_double_buffer(declare_writes())` |
| starvation 防护 | 有 | 无 | 保留 |
| reads/writes 校验 | 无 | 无 | 🆕 debug 构建检测"声明 write A 但实际写了 B"等违约 |
| 拓扑排序 | 无 | Kahn O(J²) | 保留（沿用 `dc_ecs_scheduler` 算法）|

阶段 I 完成后 `main.gd` 那个 1000+ 行的 fast-tick 函数能压缩到 < 50 行。

#### I.4 ViewAdapter（B2）

```gdscript
# scripts/data_core/view_adapter.gd
class_name DCViewAdapter extends RefCounted

# 实现 1（legacy 兼容）：直接读 HexCell
class CellViewAdapter:
    func get_temp(idx: int) -> float: return _cells[idx].temperature
    func get_moisture(idx: int) -> float: return _cells[idx].moisture
    # ...

# 实现 2（DOTS）：从 world.view_f32 读
class WorldViewAdapter:
    var _temp_view: PackedFloat32Array  # 在 setup() 一次性取
    var _moisture_view: PackedFloat32Array
    func get_temp(idx: int) -> float: return _temp_view[idx]
    func get_moisture(idx: int) -> float: return _moisture_view[idx]
    # ...
```

调用点改造（一次性硬活，但是逐文件机械替换）：
- `hex_renderer.gd` ~80 处 `cell.<field>` 读 → `adapter.get_<field>(cell.index)`
- `map_baker.gd` ~150 处（在阶段 0.3 拆分时一并改）
- `data_overlay_baker.gd` ~30 处
- `info_panel`（在 main.gd / right_panel）~20 处
- `weather_layer.gd` ~40 处
- `debug_console.gd` ~10 处

#### I.5 FeatureFlagRegistry + Module Manifest（B1）

```gdscript
# scripts/data_core/feature_flags.gd —— 集中真值
class_name DCFeatureFlags
const FLAGS: Dictionary = {
    &"use_dots_climate":   { default = false, owner = "ClimateDailySystem" },
    &"use_dots_weather":   { default = false, owner = "WeatherSystem" },
    &"use_dots_economy":   { default = false, owner = "EconomySystem(future)" },
    # ...
}
static func is_on(flag: StringName) -> bool: ...
static func toggle(flag: StringName, on: bool) -> void: ...  # hot-reload 友好
```

```gdscript
# scripts/simulation/climate/module_manifest.tres（每模块一份）
@tool
extends Resource
class_name DCModuleManifest
@export var module_id: StringName = &"climate"
@export var feature_flag: StringName = &"use_dots_climate"
@export var reads: Array[StringName] = [&"cell.temp", &"cell.moisture", ...]
@export var writes: Array[StringName] = [&"cell.temp", &"cell.snow_cover", ...]
@export var pools: Array[StringName] = [&"cells"]
@export var archetypes: Array[StringName] = []
@export var dispatch_paths: PackedStringArray = ["legacy", "dots_gdscript", "dots_cpp"]
```

调度器在 debug 构建里：
- 强制 system.declare_reads() ⊆ manifest.reads
- 强制 system.declare_writes() ⊆ manifest.writes
- hot loop 写到非 manifest.writes 的 component → push_error + 中断

#### I.6 MigrationHarness 沙盒模板（B3）

```
tools/migration_harness/
├── template_bench.gd          # 单 pass micro-bench 模板（拷自 bench_temp_drift.gd）
├── template_module_test.gd    # bit-equal + 30-tick SUS 对比
├── template_overlay.gd        # demo overlay 接入 5 步骤
└── README.md                  # SOP 7 步操作清单（即 §5）
```

#### I.7 阶段 I 验收

| 项 | 通过标准 |
|---|---|
| 用 ComponentSchema 重写 `bind_map_data` | 41 行 → ≤ 5 行；行为 bit-equal |
| C++ `BIND_TABLE` codegen | `gen_cpp_bind_table.py` 输出与人手写 byte-equal |
| 6 个 SusJob 改写为 DCSystem | SUS 日志 ±3%，无回归 |
| DCSystemScheduler 上线 | demo_thermal_gradient + production climate 同时走新调度器 |
| ViewAdapter 全面接入 | renderer/UI/baker 不再直读 `cell.<field>`；ripgrep `cell\.\w+` 在 hot 文件下 = 0 |
| MigrationHarness | 用模板做一个 dummy 模块，30 分钟内跑通 |

### 4.4 阶段 II：数据所有权下移

| 步骤 | 内容 |
|---|---|
| II.1 | hot pass 写路径全部走 `world.write_*` —— 现有 climate / weather / ocean / sea_ice 子段逐一改造（每段独立 PR）|
| II.2 | ViewAdapter 默认实现切换到 `WorldViewAdapter`（read from `world.view_f32`）|
| II.3 | 删除 `flush_soa_to_cells / rebuild_soa_from_cells / soa_swap_double_buffer`；`MapData` 退化成 IO + topology 容器（保留 `_neighbor_indices` / `_cell_array` / 序列化字段）|
| II.4 | `HexCell` 改为只读 facade：`get_temperature() -> float: return _world.read_f32(_cid_temp, _index)`；UI / 调试代码一行不动 |

阶段 II 验收：
- SUS 总耗时下降可观（每天省一次 O(N) flush）
- ripgrep `cell\.temperature\s*=` / `cell\.moisture\s*=` 全代码库 = 0
- 全 climate / weather pipeline 30 天 bit-equal vs 阶段 I 末态

### 4.5 阶段 III：序列化 / 测试基建

| 步骤 | 内容 |
|---|---|
| III.1 | `DCWorld.serialize() -> Dictionary` 按 schema 自动遍历；`cell.demo.*` 命名空间过滤 demo 字段 |
| III.2 | `DCWorld.deserialize(d)` round-trip；版本号 + schema migration 钩子 |
| III.3 | 标准化 soak-test 夹具（基于 B3 模板）：random map / 1000-day soak / save-load round-trip / DOTS-A vs DOTS-B 对照 |
| III.4 | FeatureFlag hot-reload：editor 改 flag → 自动重 bind World，无需重启 |

### 4.6 阶段 IV：物理优化（**条件触发，勿主动启动**）

| 步骤 | 触发条件 | 备注 |
|---|---|---|
| IV.1 D-async 接入 production climate Pass-A | climate Pass-A 在更大地图（N ≥ 50k）下单 pass > 5ms | 沙盒已在 `cpp-async-experiment-report` 验收，可低风险启用 |
| IV.2 `_chunk_remap` | 出现 4ms/帧瓶颈 + mask 准静态 | review §1.3 P1-3，dots-experiment-report §B0 |
| IV.3 SIMD | performance-charter §3.1 6 条全满足 | charter §3.1.1 候选 pass 清单 |

---

## 5. 单模块 DOTS 迁移 SOP（7 步检查清单）

> **本节是路线图最重要的产物**——任何模块（climate / weather / economy / unit /
> AI / pollution …）做 DOTS 化都走这 7 步。**复用本 SOP 即可保证模块互不影响**。
>
> 时间盒：从 Step 1 到 Step 5（GDScript 路径完成）应在 2-3 个工作日内完成。
> 超时说明你陷入业务逻辑细节而不是模板套用——先停下来重读 §2.1。

### Step 1 — 写 module_manifest.tres

```gdscript
# scripts/simulation/<module>/module_manifest.tres
@export var module_id: StringName = &"economy"
@export var feature_flag: StringName = &"use_dots_economy"
@export var reads: Array[StringName] = [&"cell.population", &"cell.tax_base"]
@export var writes: Array[StringName] = [&"cell.gdp", &"cell.unemployment"]
@export var pools: Array[StringName] = [&"cells"]
@export var archetypes: Array[StringName] = []
@export var dispatch_paths: PackedStringArray = ["legacy", "dots_gdscript"]
```

> **没声明的 component 一概不许碰**；调度器 debug 构建会校验。

### Step 2 — 在 ComponentSchema 集中表追加新字段（如有）

```gdscript
# scripts/data_core/component_schema.gd
const CELL_SCHEMA: Array[Dictionary] = [
    # ... 既有 ...
    { name = &"cell.gdp",          dtype = F32, track_prev = true,
      owner = "economy", cpp_pass_uses = [] },
    { name = &"cell.unemployment", dtype = F32, track_prev = false,
      owner = "economy", cpp_pass_uses = [] },
]
```

> 一处改动自动派生 GDScript `bind_map_data` + C++ `BIND_TABLE` 头文件。

### Step 3 — 写新 DCSystem 子类（GDScript，先用 dots_gdscript 路径）

```gdscript
# scripts/simulation/economy/economy_system.gd
class_name EconomySystem extends DCSystem

func declare_reads() -> Array[StringName]:
    return [&"cell.population", &"cell.tax_base"]
func declare_writes() -> Array[StringName]:
    return [&"cell.gdp", &"cell.unemployment"]
func declare_pools() -> Array[StringName]: return [&"cells"]
func feature_flag() -> StringName: return &"use_dots_economy"

func tick(ctx) -> Dictionary:
    var pop := _world.view_f32(_cid_population)
    var gdp := _world.view_f32(_cid_gdp)
    # 算法主体——只能读 declare_reads / 写 declare_writes 内的 component
    return {"done": true}
```

> **不准触碰 manifest 之外的 component**——manifest 是契约，违约 debug 构建报错。

### Step 4 — 接入 FeatureFlagRegistry

```gdscript
# scripts/data_core/feature_flags.gd
const FLAGS: Dictionary = {
    # ... 既有 ...
    &"use_dots_economy": { default = false, owner = "EconomySystem" },
}
```

调用点（main.gd / bootstrap）：

```gdscript
if DCFeatureFlags.is_on(&"use_dots_economy"):
    scheduler.register_system(EconomySystem.new())
else:
    # legacy 实现保留
    scheduler.register_system(EconomyLegacySystem.new())
```

> 单点 toggle，A/B 切换一行代码；A/B 共存便于回归对照。

### Step 5 — 在 `tools/migration_harness/` 里基于模板写 bench

```
tools/migration_harness/bench_economy.gd  # 拷自 template_bench.gd
```

通过标准（与 performance-charter §6.2 对齐）：

| 指标 | 红线 |
|---|---|
| bit-equal: legacy vs dots_gdscript | 容差 < 1e-6（金额/比率类）/ bit-equal（计数类）|
| micro-bench: 单 tick µs | dots_gdscript 不慢于 legacy × 1.2 |
| SUS 30-tick 日志 | avg / p95 / slices ±5% |
| 截图（如有 overlay）| 像素 diff < 0.1% |

### Step 6 —（仅当 Step 5 显示 ≥ 5 ms 且 N ≥ 1k）→ C++ 化

走 [`performance-charter §12.4`](./performance-charter.md#124-用模板做下一个-pass--7-步操作清单)
的 7 步操作清单。在 manifest 里追加 `dispatch_paths += "dots_cpp"`。重跑
Step 5 的 bench；C++ ≥ GDScript 5× 才合入（performance-charter 铁律 3）。

### Step 7 — 接入 ViewAdapter（如该模块有 UI / overlay 消费）

```gdscript
# scripts/data_core/view_adapter.gd
class WorldViewAdapter:
    var _gdp_view: PackedFloat32Array
    func setup(world):
        _gdp_view = world.view_f32(world.component_id(&"cell.gdp"))
    func get_gdp(idx: int) -> float: return _gdp_view[idx]
```

UI / renderer / baker 通过 adapter 读 → 模块 dispatch_path 切换对它们透明。

### 互不影响的物理保证（这是 SOP 的核心价值）

| 隔离手段 | 保证什么 |
|---|---|
| Module Manifest 声明 reads/writes | 调度器 debug 校验：模块 A 不能写模块 B 的 component |
| FeatureFlagRegistry 单 flag toggle | 模块 A 走 dots_cpp、模块 B 仍 legacy → 零耦合 |
| ViewAdapter 读侧隔离 | renderer/UI 一行不动地从 cell.* 切到 view_f32 |
| ComponentSchema owner 字段 | dots_lint 自动检测"声明 owner=X 但实际有 Y 在写"→ 跨模块写入报警 |
| 命名空间约定 | `cell.<field>` / `front.<field>` / `<module>.<field>` 不互相污染 |

---

## 6. 立即可执行的"第一刀"建议

review 文档结尾建议先做 P0-1（ComponentSchema），本路线图**强烈不同意**——
你应该先做 **阶段 0 的 0.3（map_baker 切分）+ 阶段 I 的 I.4（ViewAdapter）**。

### 6.1 为什么不是 P0-1

| 路径 | 收益 | 风险 | 对"互不影响"的解锁 |
|---|---|---|---|
| 先做 P0-1（ComponentSchema）| 新增字段 boilerplate ↓ 60% | 低 | 弱（只解决"加字段"，不解决"模块边界"）|
| **先做 0.3 + I.4（map_baker + ViewAdapter）** | UI/renderer 与数据侧解耦 | 低 | **强**（数据侧 DOTS 化对 UI 完全透明，所有后续阶段无 UI 连锁）|
| 先做 P0-2（数据所有权下移）| 砍 flush_soa_to_cells | 高（牵动 ~300 处 cell.* 读写）| 中（必须先有 ViewAdapter 才能安全做）|

ViewAdapter 是技术风险最低的一步（thin facade，~150 行），bit-equal 验收一目
了然。做完之后阶段 II 砍 `flush_soa_to_cells` 没有 UI 端连锁。

### 6.2 第一周操作（4 天）

> **更新（2026-05-13，框架硬化 Phase A 已落地）**：实际施工时顺序略作调整（详见
> 框架硬化 plan 的 Phase A→D），先把 ComponentSchema (A1) / ViewAdapter 接口 (A2) /
> FeatureFlagRegistry (A3) / MigrationHarness (A4) 四件基础设施一次性建好（"零侵入"
> 阶段，不改任何业务代码），然后才进入 Phase B 的"接入读侧 + 拆 map_baker"。
> 原因：A1 codegen 需要现有 BIND_TABLE 作为对照才能 byte-equal 验收，先做有助于
> 后续 Phase B/C 加字段时已经能走 schema。下表是原始 4 天建议，已被框架硬化
> Phase A+B 替代——但作为"最小可用迁移路径"参考仍有价值。

| Day | 任务 | 验收 |
|---|---|---|
| Day 1 | 写 `scripts/data_core/view_adapter.gd`（CellViewAdapter + WorldViewAdapter 两实现，覆盖 climate / weather / topology 字段约 30 个 getter）| 单测：两实现对同一帧返回 bit-equal |
| Day 2 | 把 `hex_renderer / weather_layer / data_overlay_baker / info_panel / debug_console` 的 ~150 处 `cell.<field>` 直接读改成 `adapter.get_<field>(cell.index)` | 截图对比：5 帧像素级一致 |
| Day 3 | 拆 `map_baker.gd` 2583 行 → 4 个子 baker + BakerContext，全部通过 ViewAdapter 读 | SUS 30-tick avg / p95 ±5% |
| Day 4 | 跑 30 天 soak test + 提 PR | 无 fast tick WARN 频率上升 |

完成这 4 天的工作之后，你才有资格启动 review §3 阶段 I 的 P0-1 / P0-2——
那时候改 schema、把 cell.* 写路径砍掉，UI 那边一行都不用动。

### 6.3 框架硬化 Phase A 完成情况（2026-05-13）

| Phase A todo | 实际产出 |
|---|---|
| A.1 ComponentSchema 单一源 | ✅ [`component_schema.gd`](../Project/project-keynes/scripts/data_core/component_schema.gd)（38 entries）+ [`gen_cpp_bind_table.py`](../tools/codegen/gen_cpp_bind_table.py) + [`component_bind_table.gen.h`](../gdext/src/component_bind_table.gen.h)（autogen）+ [`world.gd::bind_map_data`](../Project/project-keynes/scripts/data_core/world.gd) 38 行手写 → schema 派生循环 |
| A.2 ViewAdapter facade | ✅ [`view_adapter.gd`](../Project/project-keynes/scripts/data_core/view_adapter.gd)（DCViewAdapter + .Cell + .World 三个 class，~33 个 getter）+ [`view_adapter_test.gd`](../Project/project-keynes/tests/view_adapter_test.gd) 单测 |
| A.3 FeatureFlagRegistry + Module Manifest | ✅ [`feature_flags.gd`](../Project/project-keynes/scripts/data_core/feature_flags.gd)（15 flags 注册 + sanity check）+ [`module_manifest.gd`](../Project/project-keynes/scripts/data_core/module_manifest.gd) Resource 类 |
| A.4 MigrationHarness 模板 | ✅ [`tools/migration_harness/`](../Project/project-keynes/tools/migration_harness/)（template_bench / template_module_test / template_overlay / README）|
| A.5 Phase A 文档收尾 | ✅ 本文档 §3 表格状态列 + [`dots-component-schema.md`](./dots-component-schema.md) + performance-charter §11.2/§12.4 注释 + cpp-gdscript-best-practices §1 架构图 |

Phase A 验收通过的标志：bind_map_data 行为与改造前 byte-equal（现有 `tmp/test_bind_alias.gd`
能跑通即说明 schema 派生未改注册顺序 / dtype）；新加字段 SOP 走完 < 30 分钟。

---

## 7. 当前可量化的工程账（让 PR reviewer 一眼看到收益）

| 阶段 | 完成后的可量化指标 |
|---|---|
| 阶段 0 完成 | 巨石文件数 4 → 0；最大单文件行数 4639 → ≤ 800 |
| 阶段 I 完成 | `bind_map_data` 41 行 → ≤ 5 行；`_on_world_bound` 模板代码 ↓ 80%；`main.gd` fast-tick 1000+ 行 → ≤ 50 行 |
| 阶段 II 完成 | 每 daily tick 砍 1 次 O(N) flush；同一字段副本数 4 → 1（DCWorldExt 唯一）|
| 阶段 III 完成 | 存档/加载支持任意 schema 字段；soak-test 自动化 |
| 阶段 IV（条件触发）| 单 pass 命中 SIMD/线程化触发条件时再上 |

---

## 8. 文档维护守则

- 完成阶段 0 任一拆分文件 → 在 §4.2 表格对应行打勾 + 写实际行数
- 完成阶段 I 任一抽象 → 在 §4.3 子节末尾追加 commit hash + 验收数据
- 任何模块走完 §5 SOP → 在文档末尾追加一行"已迁移模块清单"
- 任何"按本路线图反而踩坑"的反馈 → 写进 §2 让后续模块绕开

> 责任人：本文档由动 DCWorld / 调度器 / hot-loop / 巨石模块拆分的 PR 提交者
> 维护，每次涉及 DOTS 架构的合入必须确认本文档无需更新。

---

## 9. 已迁移模块清单

> 每完成一个模块的 §5 SOP 就在下表追加一行。
>
> **特殊条目**：框架硬化（A/B/C/D 抽象本身）的施工产物也在此追踪，便于
> 反向定位"什么时候 ViewAdapter 接入到了 main.gd / data_overlay_baker"。

| 模块 / 抽象 | 状态 | dispatch_path / kind | 完成日 | commit | 备注 |
|---|---|---|---|---|---|
| ComponentSchema (A1) | ✅ 完成 | infrastructure | 2026-05-13 | framework-hardening Phase A.1 | 38 entries 单一源 + Python codegen + cpp BIND_TABLE 自动派生 |
| ViewAdapter (B2) — 接口 | ✅ 完成 | infrastructure | 2026-05-13 | framework-hardening Phase A.2 | DCViewAdapter / .Cell / .World 三 class + 33 个 getter + 单测 |
| FeatureFlagRegistry + Manifest (B1) | ✅ 完成 | infrastructure | 2026-05-13 | framework-hardening Phase A.3 | 15 flags 集中索引 + DCModuleManifest Resource 类 |
| MigrationHarness (B3) | ✅ 完成 | infrastructure | 2026-05-13 | framework-hardening Phase A.4 | 3 模板 + README + 7 步 SOP |
| ViewAdapter 接入 (B.1) | ✅ 完成 | infrastructure | 2026-05-13 | framework-hardening Phase B.1 | data_overlay_baker 15 处 + main.gd info_panel 30+ 处 cell.* 改为 adapter.get_* |
| map_baker.gd 拆分 (B.2) | 🟡 骨架 | infrastructure | 2026-05-13 | framework-hardening Phase B.2 | 5 sub-baker 文件 + BakerContext + 详细迁移 TODO；实际函数搬迁分批走 |
| ViewAdapter A/B flag (B.3) | ✅ 完成 | infrastructure | 2026-05-13 | framework-hardening Phase B.3 | use_world_view_adapter flag + ClimateProfile 字段 + main._rebuild_view_adapter |
| DCSystem 基类 (A2) | ✅ 完成 | infrastructure | 2026-05-13 | framework-hardening Phase C.1 | DCSystem + 自动 cid cache + SusJob 兼容字段 + 单测 |
| DCSystemScheduler (A3) | ✅ 完成 | infrastructure | 2026-05-13 | framework-hardening Phase C.2 | wrapper SUS+DCEcs + reads/writes 拓扑 + DCWorld debug hook |
| 6 个 SusJob 改写 DCSystem (C.3) | 🟡 部分原生 | infrastructure | 2026-05-13 | framework-hardening Phase C.3 | 3 小型原生改写 + 3 大型 wrapper（OceanCurrents / ClimateDaily / Weather） |
| DCSystemScheduler flag (C.4) | 🟡 数据层完成 | infrastructure | 2026-05-13 | framework-hardening Phase C.4 | use_dc_system_scheduler flag + ClimateProfile 字段；main.gd 接入在 D.3 |
| weather_system.gd 拆分 (D.1) | 🟡 骨架 | infrastructure | 2026-05-13 | framework-hardening Phase D.1 | 5 子文件骨架（field_solver/front_advect/front_spawn/feedback/summary_builder）+ 详细迁移 TODO |
| map_generator.gd 拆分 (D.2) | 🟡 骨架 | infrastructure | 2026-05-13 | framework-hardening Phase D.2 | 8 子文件骨架（terrain_gen/pass_a/pass_b/water_pass/land_pass/sea_ice_daily/transpiration/diagnostics_bus）+ 详细迁移 TODO |
| main.gd 拆分 (D.3) | 🟡 骨架 | infrastructure | 2026-05-13 | framework-hardening Phase D.3 | 5 子文件骨架（dots_bootstrap/sus_systems_bootstrap/demo_bootstrap/visual_bootstrap/info_panel_controller）+ 详细迁移 TODO |
| 框架硬化文档套件 (D.4) | ✅ 完成 | infrastructure | 2026-05-13 | framework-hardening Phase D.4 | 5 新文档（component-schema / view-adapter-guide / system-design / module-ownership-map / framework-status）+ 5 现有文档加状态徽章 |
| weather facade 升级 (E.1+E.2) | ✅ 完成 | infrastructure | 2026-05-13 | dots-full-migration Phase E.1+E.2 | 5 weather sub-module 骨架升级为 facade + 详细逐函数搬迁清单（line 范围 + 接口契约）|
| weather_system.gd 顶部计划块 (E.3) | ✅ 完成 | infrastructure | 2026-05-13 | dots-full-migration Phase E.3 | 文件顶部加 E.3 计划状态块；E.1/E.2 实际搬迁待后续 PR |
| climate facade 升级 (E.4) | ✅ 完成 | infrastructure | 2026-05-13 | dots-full-migration Phase E.4 | pass_a / pass_b 骨架升级为 facade + 接口契约 |
| ocean/sea_ice/transp facade 升级 (E.5) | ✅ 完成 | infrastructure | 2026-05-13 | dots-full-migration Phase E.5 | 4 sub-pass 骨架升级 + F.4 terrain ECB 注意事项 |
| map_generator + diagnostics_bus (E.6) | ✅ 完成 | infrastructure | 2026-05-13 | dots-full-migration Phase E.6 | map_generator 顶部计划块 + diagnostics_bus 完整 API（climate / weather / generic breakdown）|
| 6 hot pass C++ stubs (F.1-F.6) | ✅ 完成 | infrastructure | 2026-05-13 | dots-full-migration Phase F.1-F.6 | world_ext.h 6 个新方法签名 + cpp stub（return -1.0 fallback）+ _bind_methods + ClimateProfile 7 个 use_gdext_* flag + DCFeatureFlags 集中注册 |
| **F.1 weather field solve C++ 实装** | ✅ **实装完成 + 验收通过** | **production** | 2026-05-13 | dots-full-migration §F.1 charter §7 P0 | world_ext.cpp ~520 行真实 C++ 算法 + weather_system.gd 接入 fast path + A/B 运行时验证器 + slice 修正（去掉 end_i 全量约束）。**实测：C++ kernel 0.19ms（charter 目标 < 2ms，超 10x）；weather_refresh avg 17ms → 7.79ms（fronts=0 时）；slices 2 → 1。** 详见 [`dots-f1-validation.md`](./dots-f1-validation.md) |
| **F.5 transpiration C++ 实装** | ✅ **实装完成 + 验收通过** | **production** | 2026-05-13 | dots-full-migration §F.5 charter §7 P2 | world_ext.cpp ~110 行 C++ 双 phase + fast-path 接入 + donor_table cache + sig probe 防 stale .dll。**实测：C++ kernel 0.02ms（charter 目标 < 0.3ms，超 15x；vs 3.2ms baseline 提速 160x）；refresh_climate_daily avg 10.10ms → 8.81ms。** 详见 [`dots-f5-validation.md`](./dots-f5-validation.md) |
| **F.3 climate Pass-B C++ 实装** | ✅ **实装完成 + 验收通过** | **production** | 2026-05-13 | dots-full-migration §F.3 charter §7 P1 | world_ext.cpp ~290 行 C++（wind_belt_at helper + 主循环 1:1 mirror `_climate_pass_b_soa` line 4396-4523）+ map_generator fast-path 接入 + foliage_table cache + sig probe + 4 项已知简化（sparse / temperature_breakdown / DIAG print / wind jitter）。**实测：C++ kernel 0.07ms（charter < 0.5ms 目标，超 7x；vs 5.2ms baseline 提速 75x）；B 字段 5.9ms → 0.6ms；fast tick 总 sus 17-25ms → 12-13ms（-50%）。** 详见 [`dots-f3-validation.md`](./dots-f3-validation.md) |
| **F.2 ocean water+land C++ 实装** | ✅ **实装完成 + 验收通过** | **production** | 2026-05-13 | dots-full-migration §F.2 charter §7 P1 | world_ext.cpp ~270 行 C++ + map_generator 双 fast-path + 共享 anomaly buffer cache + 双独立 flag。**实测：water kernel 0.09ms（vs 3.4ms = 38x，charter < 0.5ms ✅）；land kernel 0.02ms（vs 3.4ms = 170x ✅）；ocean 字段 6.3-7.0ms → 0.9ms（-86%）；refresh_climate_daily avg 8.54 → 6.64ms。** 详见 [`dots-f2-validation.md`](./dots-f2-validation.md) |
| terrain_gen.gd 骨架升级 (G.1) | ✅ 完成 | infrastructure | 2026-05-13 | dots-full-migration Phase G.1 | facade + 详细搬迁清单（generate 调用顺序 + 一次性烘焙 helper 列表）|
| map_baker.gd 计划状态块 (G.2) | ✅ 完成 | infrastructure | 2026-05-13 | dots-full-migration Phase G.2 | 文件顶部加 G.2 计划块 + 推荐迁移顺序（atlas_encoders 优先）|
| main.gd 计划状态块 (G.3) | ✅ 完成 | infrastructure | 2026-05-13 | dots-full-migration Phase G.3 | 文件顶部加 G.3 计划块 + 推荐 bootstrap 迁移顺序 |
| 数据所有权下移规划 (G.4+G.5) | 📋 规划锁定 | infrastructure | 2026-05-13 | dots-full-migration Phase G.4+G.5 | [`dots-stage-ii-data-ownership-plan.md`](./dots-stage-ii-data-ownership-plan.md) 锁定执行步骤；**等 F.1-F.6 实际算法填入 + bit-equal 验收后才能执行** |

---

**END of roadmap.**
