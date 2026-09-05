# C++/DOTS Runtime 开发文档索引

- [建筑视觉运行时](./building-visual-runtime.md)：科技时代驱动的 2.5D 建筑复合体、迷雾情报、天气、阴影、植被协调和性能闸门。

- [运河运行时](./canal-runtime.md)：API-ready 的权威边状态、经济施工、Effect 原子提交、
  贸易/殖民边成本、局地水文、Visual Tile 与 PKEC v41；PlayerController 尚未注册。

## Formal game flow and PKSV

- [Module Boundaries](../architecture/module-boundaries.md): source-file
  ownership, dependency direction, extraction thresholds, and verification gate.

- [科技树、科技值与科研经济运行时](./technology-tree-runtime.md)：180 项权威目录、环境/资源
  研究条件、实践突破、全内容绑定、科技值市场与国家采购、Effect/Modifier ACK，以及
  PKCN v11/PKEF v11/PKTR v6/PKID v3/PKEC v41 存档契约。

- [环境驱动的科技路线差异化](./technology-route-differentiation.md)：把地理、气候、植被、
  资源、社会发展、Trigger、Effect 和经济内容组织成可分化、可重放、可审计的科技路线。

- [Formal Game Flow, Player Start, and PKSV](./game-flow-start-save.md): 正式主菜单、
  `NewGameConfig v3`、确定性多国单格开局、每国 20 人聚落、PKSV 安全边界与恢复顺序。
- 修改启动场景、玩家出生、完整存档或退出流程前先读该文档。

- [PlayerController 玩家会话运行时](./player-controller-runtime.md)：正式玩家输入、

- [配置化时代三选一奖励](./era-reward-runtime.md)：里程碑 ACK 后的确定性三选一、
  冻结目标、Effect 事务、全屏暂停锁定与 PKCN/PKEF 交叉恢复审计。
  选中态、镜头/时间编排、研究命令白名单、UI intent 边界和 `player_view` 恢复顺序。
- 修改 `player_controller.gd`、玩家场景输入、技术工作台命令或玩家视图存档前先读该文档
  及仓库内 `project-keynes-player-controller` Skill。

当前性能缓存、认证近似、closing audit 与 native daily 紧凑边界见
[运行时性能优化契约（2026-07）](runtime-performance-optimization-2026-07.md)。

显赫家族的原生 SoA、特性、地块威望、成员/建筑稀疏边、守恒财产归属、FamilyEffect 与 PKEC v41
契约见[显赫家族原生运行时](./notable-family-runtime.md)。

家族重要人物的稀疏 SoA、姓名、岗位/建筑追溯、已实现收入与消费需求归因、生命周期及 PKEC v41
契约见[家族重要人物原生运行时](./notable-person-runtime.md)。

cohort 与家族分支的八维度综合满意度、阶层权重、生存闸门、玩法接管点、explain 溯源、
社会压力事件与自 v30 引入、当前保存在 PKEC v41 的 satisfaction 列见[综合满意度运行时](./satisfaction-runtime.md)。

本目录记录 Project.Keynes 当前运行期 C++/DOTS 架构的真实状态，面向后续开发、排障和继续迁移。这里不是历史路线图，也不是一次性验收记录；历史文档仍保留原状，本目录负责把已经落到代码里的调度、数据通信、计算链路和性能诊断规则整理成可执行参考。

## Native Modifier Runtime

- [NativeSimulationHost 线程边界](./native-simulation-host.md)：后台模拟 worker 的状态机、
  POD 命令/环境输入、三缓冲提交、非阻塞生命周期和当前 ACTIVE 门禁。

- [后台模拟与 UI 隔离状态](./background-simulation-ui-isolation-status.md)：本轮规划、已落地
  实现、当前门禁、验证证据和按阶段接手清单的完整状态记录。

- [Runtime Domain 字段映射](./runtime-domain-field-map.md)：输入冻结与 Climate POD SHADOW
  垂直切片的字段 owner、单位、hash/save/visual 边界和有效性约束。

- [Native Modifier Runtime](./native-modifier-runtime.md)：四域 ModifierStore、固定公式、
  generation handle、scope/bucket、daily freeze、气候/国家/经济/Gameplay 接入、
  PKCN v11/PKEC v41/Modifier schema v3/PKCM v1/PKGP v1 与验证状态。
- 修改 stat、definition、命令协议、调度依赖、领域公式或存档 schema 时，必须先读并同步
  这份主说明与 `project-keynes-modifier-runtime` Skill。

## Tax and fiscal runtime

- [税收与财政结算运行时](./tax-fiscal-runtime.md)：五类国家税务政策、职业/物资/建筑覆盖、
  国家级税率 Modifier、财政托管、应税事件、PKCN v11/PKEC v41 存档和国家经济 UI。

## Native Ideology Runtime

- [Native Ideology Runtime](./native-ideology-runtime.md)：国家范围理念收藏、槽位、三选一、
  理解度/等级、阶层民意门、互斥组、联动、ACK 门控 Effect/Modifier 事务与 PKID v3。
- 修改理念目录、命令、民意公式、联动、Effect 绑定、存档或理念面板时，必须先读并同步
  这份主说明与 `project-keynes-ideology-runtime` Skill。

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
   - 作者地图外部编译（PKAUTH → post_base → PKMAP 旁路）见 [Authored Map Pipeline](./authored-map-pipeline.md)。

7. [Performance Diagnostics Playbook](./performance-diagnostics-playbook.md)
   - 解释 `[SUS-cpp]`、`[fast tick WARN]`、`largest=... path=...`、`published=true`、`psi_path=gdscript`、`transp/native breakdown ...` 等日志。
   - 用于根据用户贴回的 runtime log 判断当前输出是否符合预期。

8. [Native Economy Runtime](./native-economy-runtime.md)
   - PopulationCohort chunk、MarketStore、handle、并行边界和公共 API。

8b. [综合满意度运行时](./satisfaction-runtime.md)
   - 八维度 composite、阶层数据驱动权重、生存闸门、出生率/就业/家族接管、
     explain 溯源、社会压力事件与当前 PKEC v41 列。

9. [Domestic Trade Runtime](./domestic-trade-runtime.md)
   - 国内六邻接运输、稀疏贸易信号、有界寻路、贸易单托管结算、PKEC v12 与软切片契约。

10. [Native Country Runtime](./native-country-runtime.md)
   - CountryStore SoA、handle、领土 CSR、国家科技、现金/商品国库、命令与查询契约。

11. [Country / Economy Bridge](./country-economy-bridge.md)
    - 冻结国家 epoch、科技门控、国家资产转移、货币/商品联合守恒与 hash 边界。

12. [Country Scheduling / Save](./country-scheduling-save.md)
   - `country_daily`、命令屏障、PKCN v11 + PKEF v11 + PKTR v6 + PKID v3 + PKEC v41 顺序与兼容性拒绝。

13. [Economy Fixed Point / Ledger / Formula](./economy-fixed-point-ledger-formulas.md)
   - 定点 ABI、守恒、命令和原生 batch 公式规范。

14. [Economy Graph / Scheduling](./economy-graph-scheduling.md)
    - 冻结周期、按 cohort 预算的地块错峰、wait-commit、截止日 catchup 与 reference 误差。

15. [Economy Save / Migration / SOP](./economy-save-migration-sop.md)
    - PKEC 流式存档、catalog migration 和新增内容流程。

16. [Cross-Era Industry Tech Tree](./cross-era-industry-tech-tree.md)
    - 经济目录的时代分层、科技标签、产业链深化、升级族和退役/合并规则。

17. [视野迷雾与国界线](./vision-fog-and-borders.md)
    - 三态视野语义、地形感知 Dijkstra 解算、`enum_lut.a` 知识度通道、渲染 z 序、
      国界 ribbon mesh、UI 门控与 PKFG 存档边界。

18. [地图视觉 Tile 渲染](./visual-tile-rendering.md)
    - 全局权威基线与视觉 `Texture2DArray` 的边界、预算 resolver、C++ 静态 bake、
      GPU hierarchical horizon、统一 shader 寻址、legacy/probe/tiled 回退与验收。

## 可复用 Economy / Family Skills

仓库内 Skill 位于
[`project-keynes-economy-runtime`](../../.codex/skills/project-keynes-economy-runtime/SKILL.md)，
将上述经济架构、数据结构、算法、调度、性能/误差契约和扩展验证流程组织为渐进披露的
Codex 工作流。修改经济运行时文档或默认机制时，必须同步更新该 Skill 的对应 reference，
再重新安装到 `$CODEX_HOME/skills/project-keynes-economy-runtime`。

显赫家族专项 Skill 位于
[`project-keynes-family-runtime`](../../.codex/skills/project-keynes-family-runtime/SKILL.md)，
约束 FamilyStore、NotablePersonStore、成员/产业稀疏边、业主岗位、守恒财产、人物经济归因、
生命周期、查询、PKEC v41 和性能验收。修改显赫家族/人物机制、姓名目录、UI 或存档时必须同时使用
并同步该 Skill。

理念专项 Skill 位于
[`project-keynes-ideology-runtime`](../../.codex/skills/project-keynes-ideology-runtime/SKILL.md)，
约束 `NativeIdeologyRuntime`、阶层民意快照、互斥/联动、Effect ACK、PKID v3 和理念面板。
修改理念内容、命令、民意门、联动、存档或 UI 时必须同时使用并同步该 Skill。

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
| Native economy | `gdext/src/economy_runtime*.cpp`, `Project/project-keynes/scripts/economy/*.gd` | 独立 `ECONOMY_GRAPH`；catalog、profile、configuration、domain、persistence、events 与 query translation units；root 仅保留 stage/worker/publish orchestration；committed gameplay/save 与 selected-cell live Inspector bridge 不变。 |
| Native country | `gdext/src/country_runtime.cpp`, `gdext/src/world_ext_country.cpp`, `Project/project-keynes/scripts/country/*.gd` | 国家身份、领土、科技、国库、PKCN 与 `country_daily` 权威；只镜像 `cell.country_slot`。 |
| Native modifier | `gdext/src/modifier_runtime.*`, `gdext/src/world_ext_modifier.cpp`, `Project/project-keynes/scripts/modifier/*.gd` | 四域独立 store、PackedArray command、explain/journal/save 与 `modifier_daily` 冻结发布。 |
| Native ideology | `gdext/src/ideology_runtime.*`, `gdext/src/world_ext_ideology.cpp`, `Project/project-keynes/scripts/ideology/*.gd` | 国家理念收藏/槽位/三选一/民意门/联动；只提交 Effect 原子批，不写 Modifier/Economy 存储。 |
| Rendering / physical ocean | `Project/project-keynes/scripts/rendering/map_baker.gd` | SLP/wind/PSI/upwelling/raster 等 ocean currents 物理链路。 |
| Visual tile rendering | `Project/project-keynes/scripts/rendering/visual_tile_layout.gd`, `visual_tile_set.gd`, `visual_tile_horizon_baker.gd` | 视觉预算、静态 array 生命周期与异步 horizon；不拥有生成或仿真状态。 |
| Vision / fog | `Project/project-keynes/scripts/geography/vision_solver.gd` | 静态视野场预烘、多源 Dijkstra 解算、`fog_k` 与三态 `fog_state`。 |
| Fog / border 渲染层 | `Project/project-keynes/scripts/rendering/fog_of_war_layer.gd`, `.../country_border_layer.gd` | 迷雾全图 quad（z=12）与国界 ribbon mesh（z=6）。 |
| 视野编排 | `Project/project-keynes/scripts/game/world_runtime_host.gd` | `fog_of_war_enabled` / `fog_early_out_enabled`、`refresh_country_visuals()`、订阅 `country_committed`。 |

## 维护规则

- 新增或迁移 C++ pass 时，同时更新 [Computation Pipelines](./computation-pipelines.md) 的状态表和对应机制小节。
- 修改 `DCWorld` / `DCWorldExt` 通信 API 时，同时更新 [GDScript / C++ Data Bridge](./gdscript-cpp-data-bridge.md)。
- 修改 scheduler 报告字段、skip 原因、budget 窗口或 job 注册顺序时，同时更新 [Scheduling and Job Graph](./scheduling-and-job-graph.md) 和 [Performance Diagnostics Playbook](./performance-diagnostics-playbook.md)。
- 修改 LUT 通道布局、迷雾/国界视觉、PKSV section 集合或渲染 z 序时，同时更新 [视野迷雾与国界线](./vision-fog-and-borders.md)、[Computation Pipelines](./computation-pipelines.md) 与 [Formal Game Flow, Player Start, and PKSV](./game-flow-start-save.md)。
- 文档里提到的符号必须能用 `rg` 在源码里找到；历史计划中的已废弃名字不要作为当前状态写入。
E9c economy publish split: `gdext/src/economy_runtime_publish.cpp` owns
publish-phase-local reset/cursors, closing conservation audits, watermark and
trade diagnostics, resource-delta readiness and ordered COMMIT. The root
`economy_runtime.cpp` remains the sole owner of aggregate-publish stage entry,
outer cursor/yield boundaries, stage order and next-stage selection.

E9d economy result-container split: `gdext/src/economy_runtime_results.cpp`
owns `MarketResult`/`ProductionResult` reset/capacity methods and worker
TLS sink definitions. Result aggregation, worker scheduling, stage boundaries
and conservation authority remain in `economy_runtime.cpp`.

E9e economy diagnostics split:
`gdext/src/economy_runtime_diagnostics.cpp` owns read-only progress, memory,
slice-breakdown and compact/full report formatting. Report keys and scheduler
semantics are unchanged; stage/cursor mutation and worker execution remain in
`economy_runtime.cpp`.

E9f economy settlement lifecycle split:
`gdext/src/economy_runtime_settlements.cpp` owns committed population totals,
prosperity hysteresis, stable settlement naming, settlement initialization and
changed-cell updates plus bounded settlement row construction. The native
`SettlementStore` owner, forced-name behavior, query fields and aggregate
publish/COMMIT ordering remain unchanged.

E9b2 economy epoch lifecycle: `gdext/src/economy_runtime_epoch.cpp` owns
epoch preflight, frozen country/workset preparation, transient vectors,
opening audit lanes and completed performance snapshots; stage order, outer
cursors and worker scheduling remain in `economy_runtime.cpp`.

