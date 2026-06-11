# C++/DOTS Runtime 开发文档索引

本目录记录 Project.Keynes 当前运行期 C++/DOTS 架构的真实状态，面向后续开发、排障和继续迁移。这里不是历史路线图，也不是一次性验收记录；历史文档仍保留原状，本目录负责把已经落到代码里的调度、数据通信、计算链路和性能诊断规则整理成可执行参考。

## 阅读顺序

1. [Architecture Overview](./architecture-overview.md)
   - 先读这一篇，建立 Godot/GDScript、DataCore、GDExtension、SUS/DCSystem、C++ schedule graph 之间的层次关系。
   - 重点关注“谁是权威数据源”和“哪些职责仍在 GDScript orchestration 层”。

2. [GDScript / C++ Data Bridge](./gdscript-cpp-data-bridge.md)
   - 解释 `DCWorld`、`DCWorldExt`、`MapData`、component schema、C++ slot/SoA 的通信契约。
   - 新增 C++ pass 或排查 `path=gdscript` / `published_to_slot=false` 前必须读。

3. [Scheduling and Job Graph](./scheduling-and-job-graph.md)
   - 解释 `MapGenerator._setup_sus()` 如何注册 runtime jobs，`DCSystemScheduler` 如何转接到 `SusSchedulerExt`，以及 legacy `SusScheduler` 如何作为 fallback。
   - 重点看 `frame_budget_ms`、`slice_budget_ms`、`must_run`、`depends_on`、`progress_ratio` 和 `skipped[frame_budget_exhausted]`。

4. [Computation Pipelines](./computation-pipelines.md)
   - 按机制列出 climate、ocean、weather、sea ice、transpiration、atlas upload 等计算链路。
   - 每个机制都记录 GDScript wrapper、C++ kernel、输入输出、publish/flush、fallback 和性能风险。

5. [Performance Diagnostics Playbook](./performance-diagnostics-playbook.md)
   - 解释 `[SUS-cpp]`、`[fast tick WARN]`、`largest=... path=...`、`published=true`、`psi_path=gdscript`、`transp gdext wall/native/...` 等日志。
   - 用于根据用户贴回的 runtime log 判断当前输出是否符合预期。

## 与现有文档的关系

| 文档 | 本目录如何使用 |
| --- | --- |
| [`../dots-master-execution-handbook.md`](../dots-master-execution-handbook.md) | 主路线和阶段性执行方案。这里引用它的原则，但不重复历史计划。 |
| [`../performance-charter.md`](../performance-charter.md) | 性能铁律和 C++/GDScript 通信公理。这里把它们映射到当前真实代码路径。 |
| [`../dots-component-schema.md`](../dots-component-schema.md) | component schema 单一源说明。这里记录 schema 在 runtime bridge 中的实际使用方式。 |
| [`../dots-f1-validation.md`](../dots-f1-validation.md) 到 [`../dots-f6-validation.md`](../dots-f6-validation.md) | 单个阶段的验收 SOP。这里只保留已经合并后的当前状态和排障结论。 |
| [`../plans/dots-total-cpp/`](../plans/dots-total-cpp/) | Total-C++ 计划和验收矩阵。这里补运行时工程细节。 |

## 当前源码入口

| 层 | 主要文件 | 说明 |
| --- | --- | --- |
| DataCore GDScript world | `Project/project-keynes/scripts/data_core/world.gd` | `DCWorld`，GDScript 侧 component slot、dirty mask、write API、`bind_map_data()`。 |
| Component schema | `Project/project-keynes/scripts/data_core/component_schema.gd` | GDScript 单一源，派生 C++ `component_bind_table.gen.h`。 |
| C++ world | `gdext/src/world_ext.cpp`, `gdext/src/world_ext.h` | `DCWorldExt`，C++ slot/SoA、pass kernels、GDExtension binding。 |
| Scheduler wrapper | `Project/project-keynes/scripts/data_core/dc_system_scheduler.gd` | `DCSystemScheduler`，DCSystem 到 SUS/C++ scheduler 的桥。 |
| C++ scheduler | `gdext/src/sus_scheduler_ext.cpp`, `gdext/src/sus_scheduler_ext.h` | `SusSchedulerExt`，frame budget、depends、skip、统计窗口。 |
| Legacy scheduler | `Project/project-keynes/scripts/simulation/sus/sus_scheduler.gd` | 旧 GDScript SUS fallback，语义与 C++ scheduler 对齐。 |
| System wrappers | `Project/project-keynes/scripts/simulation/systems/*.gd` | DataCore/DCSystem 版 runtime jobs。 |
| Legacy jobs | `Project/project-keynes/scripts/simulation/sus/jobs/*.gd` | 兼容 jobs，部分仍被 wrapper 委托。 |
| Runtime orchestration | `Project/project-keynes/scripts/geography/map_generator.gd` | `_setup_sus()` 注册系统，调度 climate/ocean/weather pass。 |
| Rendering / physical ocean | `Project/project-keynes/scripts/rendering/map_baker.gd` | SLP/wind/PSI/upwelling/raster 等 ocean currents 物理链路。 |

## 维护规则

- 新增或迁移 C++ pass 时，同时更新 [Computation Pipelines](./computation-pipelines.md) 的状态表和对应机制小节。
- 修改 `DCWorld` / `DCWorldExt` 通信 API 时，同时更新 [GDScript / C++ Data Bridge](./gdscript-cpp-data-bridge.md)。
- 修改 scheduler 报告字段、skip 原因、budget 窗口或 job 注册顺序时，同时更新 [Scheduling and Job Graph](./scheduling-and-job-graph.md) 和 [Performance Diagnostics Playbook](./performance-diagnostics-playbook.md)。
- 文档里提到的符号必须能用 `rg` 在源码里找到；历史计划中的已废弃名字不要作为当前状态写入。
