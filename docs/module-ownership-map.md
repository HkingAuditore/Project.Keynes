# Project.Keynes — Module Ownership Map（onboarding 必读）

> 本文档取代 [`DOTS review.md §1`](./DOTS%20review.md) 那张"当前架构"表，列出
> 框架硬化（dots-migration-roadmap §4 阶段 0+I）落地后**每个模块**的入口
> 文件、职责、reads/writes、所属 owner。
>
> 用途：
> - 新加入开发者快速知道"想动 X 应该改哪个文件"
> - PR reviewer 一眼看到"这个改动属于哪个模块、是否越界"
> - dot-graph / lint 工具的 ground truth
>
> 更新原则：任何模块边界改动（拆文件 / 改 owner / 加新 reads/writes）都必须
> 同步更新本文档。

---

## 1. 顶层架构图

```
┌──────────────────────── GDScript（res://scripts/...）─────────────────────────┐
│                                                                              │
│  main.gd ──┬──▶ DCDotsBootstrap (D.3 destination)                            │
│            ├──▶ DCSusSystemsBootstrap                                        │
│            ├──▶ DCDemoBootstrap                                              │
│            ├──▶ DCVisualBootstrap                                            │
│            └──▶ DCInfoPanelController (UI)                                   │
│                                                                              │
│       ┌──────────── 框架基础设施 (data_core/) ──────────────┐                │
│       │  DCComponentSchema (A1)        — 38 entries 单一源 │                │
│       │  DCWorld (registry / pool / archetype / ECB)        │                │
│       │  DCQuery (DSL)                                      │                │
│       │  DCViewAdapter (B2)            — Cell / World 双实现│                │
│       │  DCSystem (A2)                 — 基类               │                │
│       │  DCSystemScheduler (A3)        — SUS+DCEcs 合并    │                │
│       │  DCFeatureFlags (B1)           — 17 flags 集中      │                │
│       │  DCModuleManifest (B1)         — Resource 类        │                │
│       └──────────────────────────────────────────────────────┘                │
│                                                                              │
│       ┌──────────── 6 个生产 system (simulation/systems/) ──┐                │
│       │  EnumAtlasUploadSystem            (原生 DCSystem)    │                │
│       │  SeaIceAtlasUploadSystem          (原生 DCSystem)    │                │
│       │  SeasonRefreshSystem              (原生 DCSystem)    │                │
│       │  OceanCurrentsSystem              (wrapper)          │                │
│       │  ClimateDailySystem               (wrapper)          │                │
│       │  WeatherDCSystem                  (wrapper)          │                │
│       └──────────────────────────────────────────────────────┘                │
│                                                                              │
└──────────────────────────────────────────────────────┼───────────────────────┘
                                                       ▼
┌──────── C++ (gdext/src/) ──────────────────────────────────────────────────────┐
│  DCWorldExt — _slots[].arr_f32 数据主                                         │
│  component_bind_table.gen.h — autogen by tools/codegen/                        │
│  run_climate_pass_a / run_temp_drift / run_thermal_gradient / run_demo_complex│
│  + async_climate_* (D-async 实验)                                             │
└────────────────────────────────────────────────────────────────────────────────┘
```

---

## 2. 模块清单（按命名空间）

### 2.1 Data Core（infrastructure，常驻）

| 模块 | 入口文件 | 职责 | reads | writes | owner |
|---|---|---|---|---|---|
| ComponentSchema (A1) | [`scripts/data_core/component_schema.gd`](../Project/project-keynes/scripts/data_core/component_schema.gd) | 38 entries 单一源 | — | — | data_core |
| World registry | [`scripts/data_core/world.gd`](../Project/project-keynes/scripts/data_core/world.gd) | component / pool / archetype / ECB | — | — | data_core |
| Query DSL | [`scripts/data_core/query.gd`](../Project/project-keynes/scripts/data_core/query.gd) | with_dirty_mask / with_archetype / for_each_index | — | — | data_core |
| ViewAdapter (B2) | [`scripts/data_core/view_adapter.gd`](../Project/project-keynes/scripts/data_core/view_adapter.gd) | Cell / World 双实现 | 全 schema | — | data_core |
| DCSystem 基类 (A2) | [`scripts/data_core/dc_system.gd`](../Project/project-keynes/scripts/data_core/dc_system.gd) | 自动 cid cache + SusJob 兼容 | — | — | data_core |
| DCSystemScheduler (A3) | [`scripts/data_core/dc_system_scheduler.gd`](../Project/project-keynes/scripts/data_core/dc_system_scheduler.gd) | SUS+DCEcs 合并 + 拓扑校验 | — | — | data_core |
| FeatureFlagRegistry (B1) | [`scripts/data_core/feature_flags.gd`](../Project/project-keynes/scripts/data_core/feature_flags.gd) | 17 flags 集中索引 | — | — | data_core |
| Module Manifest (B1) | [`scripts/data_core/module_manifest.gd`](../Project/project-keynes/scripts/data_core/module_manifest.gd) | per-模块 declare 资源类 | — | — | data_core |

### 2.2 Climate（map_generator.gd 拆分目的地，D.2）

| 模块 | 入口文件 | reads | writes | owner |
|---|---|---|---|---|
| Pass-A | `scripts/simulation/climate/pass_a.gd` (skeleton) | cell.temp_baseline_year / lat_norm / elevation / temp + 12 个 | cell.temp / temp_30d / temp_365d / temp_anomaly / temp_season_offset / ema_initialized | climate.pass_a |
| Pass-B | `scripts/simulation/climate/pass_b.gd` (skeleton) | cell.temp / moisture / wind_x / wind_y / has_river + 7 个 | cell.moisture / air_mass_temp_anomaly | climate.pass_b |
| Ocean Water Pass | `scripts/simulation/ocean/water_pass.gd` (skeleton) | cell.temp / ocean_current_x / ocean_current_y + neighbors | cell.temp（仅水域） | ocean.heat_transport |
| Ocean Land Pass | `scripts/simulation/ocean/land_pass.gd` (skeleton) | cell.temperature_transport_anomaly + neighbors | cell.temp（陆地沿岸） | ocean.heat_transport |
| Sea Ice Daily Pass | `scripts/simulation/sea_ice/daily_pass.gd` (skeleton) | cell.sea_ice_frac / temp / is_water | cell.sea_ice_frac / terrain（罕触发） | climate.sea_ice |
| Transpiration Pass | `scripts/simulation/biology/transpiration_pass.gd` (skeleton) | cell.vegetation / moisture | cell.moisture（邻居 + 自身） | biology.transpiration |
| Diagnostics Bus | `scripts/geography/diagnostics_bus.gd` (skeleton) | — | — | data_core |

### 2.3 Map Generation（map_generator.gd 拆分，一次性烘焙）

| 模块 | 入口文件 | 职责 | owner |
|---|---|---|---|
| Terrain Generator | `scripts/geography/map_generation/terrain_gen.gd` (skeleton) | 大陆 / 高度 / 河流 / 湖泊 / 风场 / biome 一次性烘焙 | map_generation |

### 2.4 Weather（weather_system.gd 拆分目的地，D.1）

| 模块 | 入口文件 | reads | writes | owner |
|---|---|---|---|---|
| Field Solver | `scripts/weather/field_solver.gd` (skeleton) | cell.temp / moisture / wind_x / wind_y / weather_vapor / weather_convergence / has_river | cell.weather_vapor / convergence / instability / cloud / precip / intensity | weather.field_solver |
| Front Advect | `scripts/weather/front_advect.gd` (skeleton) | cell.wind_vector | front pool（待 DOTS 化） | weather.fronts |
| Front Spawn | `scripts/weather/front_spawn.gd` (skeleton) | cell.terrain / is_water / ocean_current_y | front pool | weather.fronts |
| Feedback | `scripts/weather/feedback.gd` (skeleton) | cell.weather_intensity / type | cell.cover / weather_intensity / weather_type | weather.feedback |
| Summary Builder | `scripts/weather/summary_builder.gd` (skeleton) | cell.weather_* | summary fronts（视觉用） | weather.summary |

### 2.5 Bakers（map_baker.gd 拆分目的地，B.2）

| 模块 | 入口文件 | 职责 | owner |
|---|---|---|---|
| Baker Context | `scripts/rendering/bakers/baker_context.gd` | 共享 ViewAdapter / dirty mask | rendering |
| Terrain Baker | `scripts/rendering/bakers/terrain_baker.gd` (skeleton) | terrain / landform / vegetation / cover atlas | rendering.terrain |
| Climate Baker | `scripts/rendering/bakers/climate_baker.gd` (skeleton) | temperature / moisture / snow_cover / sea_ice atlas | rendering.climate |
| Weather Baker | `scripts/rendering/bakers/weather_baker.gd` (skeleton) | weather field / fronts atlas | rendering.weather |
| Overlay Baker | `scripts/rendering/bakers/overlay_baker.gd` (skeleton) | overlay / debug 通道 | rendering.overlay |
| Atlas Encoders | `scripts/rendering/bakers/atlas_encoders.gd` (skeleton) | 6 个 _encode_*_tex helper | rendering.atlas |

### 2.6 6 生产 system（C.3 改写产物）

| System | 入口文件 | feature_flag | reads | writes |
|---|---|---|---|---|
| EnumAtlasUploadSystem | [`enum_atlas_upload_system.gd`](../Project/project-keynes/scripts/simulation/systems/enum_atlas_upload_system.gd) | (none) | cell.cover / vegetation | (GPU only) |
| SeaIceAtlasUploadSystem | [`sea_ice_atlas_upload_system.gd`](../Project/project-keynes/scripts/simulation/systems/sea_ice_atlas_upload_system.gd) | (none) | cell.sea_ice_frac | (GPU only) |
| SeasonRefreshSystem | [`season_refresh_system.gd`](../Project/project-keynes/scripts/simulation/systems/season_refresh_system.gd) | (none) | cell.base_moisture / lat_norm / elevation / landform / vegetation | cell.terrain / landform / vegetation / cover / moisture / base_moisture / weather_dirty_mask / snow_cover |
| OceanCurrentsSystem | [`ocean_currents_system.gd`](../Project/project-keynes/scripts/simulation/systems/ocean_currents_system.gd) | (none) | cell.elevation / is_water / terrain / lat_norm | cell.ocean_current_x / .ocean_current_y |
| ClimateDailySystem | [`climate_daily_system.gd`](../Project/project-keynes/scripts/simulation/systems/climate_daily_system.gd) | (none) | 25 climate components | 12 climate components |
| WeatherDCSystem | [`weather_system.gd`](../Project/project-keynes/scripts/simulation/systems/weather_system.gd) | (none) | 17 weather + climate + 慢层 components | 9 weather components |

### 2.7 Bootstrap（main.gd 拆分目的地，D.3）

| 模块 | 入口文件 | 职责 | owner |
|---|---|---|---|
| DOTS Bootstrap | `scripts/bootstrap/dots_bootstrap.gd` (skeleton) | DCWorld + ViewAdapter + Scheduler 注册 + DataCore CLI | data_core |
| SUS Systems Bootstrap | `scripts/bootstrap/sus_systems_bootstrap.gd` (skeleton) | 6 system 注册 + DCSystemScheduler 路径切换 | data_core |
| Demo Bootstrap | `scripts/bootstrap/demo_bootstrap.gd` (skeleton) | demo_thermal_gradient + DCEcsScheduler 路径 | demo |
| Visual Bootstrap | `scripts/bootstrap/visual_bootstrap.gd` (skeleton) | TOD / water shader uniform 推送 | rendering.visual |
| InfoPanel Controller | `scripts/ui/info_panel_controller.gd` (skeleton) | 右侧地块信息面板 | ui |

---

## 3. 命名空间约定

| 命名空间 | 含义 | 示例 |
|---|---|---|
| `cell.<field>` | cell-level component（每 cell 一个值，长度 = entity_count） | `cell.temp` / `cell.moisture` |
| `cell.demo.<field>` | demo-only cell component（不入存档） | `cell.demo.thermal_gradient` |
| `front.<field>` | front-level component（front 实体池） | `front.pos_x` / `front.kind` |
| `topology.<name>` | 拓扑 component（邻居索引等） | `topology.hex_neighbors` |
| `<module>.<field>` | 模块私有 component（未来 economy / unit 等加） | `economy.gdp` |

---

## 4. 状态标记

| 标记 | 含义 |
|---|---|
| ✅ | 完整迁移到位（原文件已无相应代码） |
| 🟡 | 骨架就位但实际函数仍在原文件（incremental migration target） |
| ⏳ | 计划中，尚未开始 |

骨架文件均带 `push_warning("not yet implemented")` 防止误调；运行期所有功能仍由原文件提供。

---

**END of module-ownership-map.md.**
