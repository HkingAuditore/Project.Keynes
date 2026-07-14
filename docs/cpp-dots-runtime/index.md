# C++/DOTS Runtime 开发文档索引

本目录记录 Project.Keynes 当前运行期 C++/DOTS 架构的真实状态，面向后续开发、排障和继续迁移。这里不是历史路线图，也不是一次性验收记录；历史文档仍保留原状，本目录负责把已经落到代码里的调度、数据通信、计算链路和性能诊断规则整理成可执行参考。

## 阅读顺序

1. [Architecture Overview](./architecture-overview.md)
   - 先读这一篇，建立 Godot/GDScript、DataCore、GDExtension、SUS/DCSystem、C++ schedule graph 之间的层次关系。
   - 重点关注“谁是权威数据源”和“哪些职责仍在 GDScript orchestration 层”。

2. [GDScript / C++ Data Bridge](./gdscript-cpp-data-bridge.md)
   - 解释 `DCWorld`、`DCWorldExt`、`MapData`、component schema、C++ slot/SoA 的通信契约。
   - 新增 C++ pass 或排查 `path=gdscript` / `published_to_slot=false` 前必须读。

3. [Runtime Authority Matrix](./runtime-authority-matrix.md)
   - 按系统列出 stage/cursor owner、slot writer、publish path、fallback owner、ACTIVE eligibility 和 blocker。
   - 用于判断一个路径到底是 C++ acceleration、partial ACTIVE 还是 DOTS authority。

4. [Runtime Deletion Inventory](./runtime-deletion-inventory.md)
   - 记录本轮删除、后续可删除对象、需要隔离的 probe/A-B helper，以及暂不可删的 Godot boundary。
   - 删除 runtime 旧路径前先更新这里。

5. [Scheduling and Job Graph](./scheduling-and-job-graph.md)
   - 解释 `MapGenerator._setup_sus()` 如何创建 runtime jobs，`DCSystemScheduler` 如何统一解释 profile budget/policy 并转接到 `SusSchedulerExt`，以及 legacy `SusScheduler` 如何作为 fallback。
   - 重点看 `frame_budget_ms`、`slice_budget_ms`、`must_run`、`depends_on`、`policy_gated`、`strict_budget_one_job` 和 `skipped[frame_budget_exhausted]`。

6. [Computation Pipelines](./computation-pipelines.md)
   - 按机制列出 climate、ocean、weather、sea ice、transpiration、atlas upload 等计算链路。
   - 每个机制都记录 GDScript wrapper、C++ kernel、输入输出、publish/flush、fallback 和性能风险。

7. [Performance Diagnostics Playbook](./performance-diagnostics-playbook.md)
   - 解释 `[SUS-cpp]`、`[fast tick WARN]`、`largest=... path=...`、`published=true`、`psi_path=gdscript`、`transp/native breakdown ...` 等日志。
   - 用于根据用户贴回的 runtime log 判断当前输出是否符合预期。

8. [Native Economy Runtime](./native-economy-runtime.md)
   - PopulationCohort chunk、MarketStore、handle、并行边界和公共 API。

9. [Domestic Trade Runtime](./domestic-trade-runtime.md)
   - 国内六邻接运输、稀疏贸易信号、有界寻路、贸易单托管结算、PKEC v11 与软切片契约。

10. [Native Country Runtime](./native-country-runtime.md)
   - CountryStore SoA、handle、领土 CSR、国家科技、现金/商品国库、命令与查询契约。

11. [Country / Economy Bridge](./country-economy-bridge.md)
    - 冻结国家 epoch、科技门控、国家资产转移、货币/商品联合守恒与 hash 边界。

12. [Country Scheduling / Save](./country-scheduling-save.md)
    - `country_daily`、命令屏障、PKCN v1 + PKEC v11 顺序与兼容性拒绝。

13. [Economy Fixed Point / Ledger / Formula](./economy-fixed-point-ledger-formulas.md)
   - 定点 ABI、守恒、命令和原生 batch 公式规范。

14. [Economy Graph / Scheduling](./economy-graph-scheduling.md)
    - 冻结周期、按 cohort 预算的地块错峰、wait-commit、截止日 catchup 与 reference 误差。

15. [Economy Save / Migration / SOP](./economy-save-migration-sop.md)
    - PKEC 流式存档、catalog migration 和新增内容流程。

16. [Cross-Era Industry Tech Tree](./cross-era-industry-tech-tree.md)
    - 经济目录的时代分层、科技标签、产业链深化、升级族和退役/合并规则。

## 可复用 Economy Skill

仓库内 Skill 位于
[`project-keynes-economy-runtime`](../../.codex/skills/project-keynes-economy-runtime/SKILL.md)，
将上述经济架构、数据结构、算法、调度、性能/误差契约和扩展验证流程组织为渐进披露的
Codex 工作流。修改经济运行时文档或默认机制时，必须同步更新该 Skill 的对应 reference，
再重新安装到 `$CODEX_HOME/skills/project-keynes-economy-runtime`。

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
| Native economy | `gdext/src/economy_runtime.cpp`, `Project/project-keynes/scripts/economy/*.gd` | 独立 `ECONOMY_GRAPH`、catalog/facade、committed gameplay/save 与 selected-cell live Inspector bridge。 |
| Native country | `gdext/src/country_runtime.cpp`, `gdext/src/world_ext_country.cpp`, `Project/project-keynes/scripts/country/*.gd` | 国家身份、领土、科技、国库、PKCN 与 `country_daily` 权威；只镜像 `cell.country_slot`。 |
| Rendering / physical ocean | `Project/project-keynes/scripts/rendering/map_baker.gd` | SLP/wind/PSI/upwelling/raster 等 ocean currents 物理链路。 |

## 维护规则

- 新增或迁移 C++ pass 时，同时更新 [Computation Pipelines](./computation-pipelines.md) 的状态表和对应机制小节。
- 修改 `DCWorld` / `DCWorldExt` 通信 API 时，同时更新 [GDScript / C++ Data Bridge](./gdscript-cpp-data-bridge.md)。
- 修改 scheduler 报告字段、skip 原因、budget 窗口或 job 注册顺序时，同时更新 [Scheduling and Job Graph](./scheduling-and-job-graph.md) 和 [Performance Diagnostics Playbook](./performance-diagnostics-playbook.md)。
- 文档里提到的符号必须能用 `rg` 在源码里找到；历史计划中的已废弃名字不要作为当前状态写入。
