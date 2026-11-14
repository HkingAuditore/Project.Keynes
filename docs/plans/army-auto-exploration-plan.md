# 部队自动探路（Army Auto-Exploration）实施方案

状态：**已实施并通过原生、GDScript 集成、视野、存档与渲染夹具验收**。
最后更新：2026-11-10。
权威：`MilitaryCore` 拥有任务与行军；Host/Vision 拥有 `explored_arr / visible_arr / fog_k_arr`；
UI 只提交 `army.explore` 并读取快照。

## 0. 结论：现在能否完全当甩手掌柜

**不能。** 本轮补齐的是“自动探路”，不是“自动战争”。

- 区域控制任务约每 5 天评估一次，只选择战争中的敌方控制格；不处理中立格。
- 部队进入敌控格会开启交战并停在边界；结算可能改变控制，但没有独立的“战后自动推进、
  自动占地、自动宣战”循环。
- 因此玩家可以让部队自动探索并自动返程，但不能完全放手让它连续征服地图。
- 本方案不改变上述自动战斗节奏，也不把“探路”伪装成“占领”。

## 1. 目标

- 玩家在部队档案中选择中心、半径与选格，提交 `army.explore`。
- 原生 `MilitaryCore` 在既有军事日内规划观察点、移动、暂停/恢复、返程和完成。
- 探路只产生探索与行军，不宣战、不占中立格、不改变区域控制评估。
- 探路部队**绝不主动进入他国控制格**，即使处于战争状态。
- 每进入一格都产生 explored-only trail；`visible/fog` 仍只由现有 Vision 管线写。
- 全部任务状态进入 PKMI/MILB v4 section 23；旧 v3 明确拒绝。
- 无探路工作时所有新路径 early-out，不复制地图、不跑 A*、不额外跑 vision pass。

## 2. 非目标

- 不自动宣战、不自动占领、不自动接管中立格。
- 不改变战斗公式、区域控制 5 日评估、战争分、外交或 AI 军事议程。
- 不新增第二个军事 tick、第二个视野算法、事件类型或美术资产。
- 不把 256 格选点数组塞进每日 UI 快照。
- 不为旧 PKMI/MILB v3 写迁移器；按当前开发期策略明确拒绝。
- 不宣称 100k/2048 全军事日基线已达到 2 ms；本轮只保证探路新增成本有界。

## 3. 原生契约

### 3.1 命令与枚举

```cpp
MCMD_ARMY_EXPLORE = 33;
MILITARY_MISSION_EXPLORE = 3;

constexpr int32_t MILITARY_MAX_EXPLORATION_TASKS = 256;
constexpr int32_t MILITARY_MAX_EXPLORATION_CELLS = 256;
constexpr int32_t MILITARY_EXPLORATION_PLANS_PER_DAY = 8;
constexpr int32_t MILITARY_EXPLORATION_PATH_REQUESTS_PER_COUNTRY_DAY = 16;
constexpr int32_t MILITARY_EXPLORATION_OBSERVERS = 3;
constexpr int32_t MILITARY_EXPLORATION_OBSERVER_RADIUS = 2;
```

阶段：

```text
ACTIVE -> RETURNING -> COMPLETE
       \-> PAUSED_BATTLE -> ACTIVE/RETURNING
RETURNING -> FAILED_NO_RETURN
```

结果：

```text
NONE / ALL_SEEN / SEEN_WITH_UNOBSERVABLE / FAILED_NO_RETURN / CANCELLED
```

路径结果必须区分：

```text
OK / UNREACHABLE / DAILY_BUDGET_EXHAUSTED / INVALID
```

`DAILY_BUDGET_EXHAUSTED` 绝不能当作永久 `blocked`。

### 3.2 任务存储

`MilitaryExplorationTask` 是固定布局行，不向 `MilitaryArmyStore` 增加探路列：

- 身份：`row_index / army_handle / owner_slot / owner_handle`
- 范围：`origin_cell / return_cell / anchor_cell / radius`
- 选点：`selected_count` + 升序去重 `selected_cells[256]`
- 位图：`seen_mask[4] / visited_mask[4] / blocked_mask[4]`，按选点序号索引
- 状态：`phase / pause_reason / result / resume_phase`
- 观察点：`focus_index / current_observation_cell / observer_tries /
  reached_observer_cells[3] / tried_observer_mask`
- 日期：`started_day / last_progress_day / last_plan_day / complete_day`
- 返程：`return_fallback`

`_exploration_by_army` 大小为 `MILITARY_MAX_ARMIES`，是派生索引，不入档。
一军一任务；新 `explore` 验证通过后替换本军旧任务；表满只复用最早的终态行，
绝不驱逐 `ACTIVE / RETURNING / PAUSED_BATTLE`。

### 3.3 玩家专属门禁

- `MCMD_ARMY_EXPLORE` 执行时要求 `army.owner_slot == command.country`。
- `command.country` 还必须等于 Host 安装的 `_exploration_observer_slot`。
- 外军即使能构造结构合法的命令，也不能创建任务。
- `has_exploration_work()` 覆盖非终态任务、pending trail、尚未应用的 pending
  `army.explore`，保证命令第一天就能取得冻结 explored 视图。

## 4. 每日状态机

`step_day()` 顺序：

1. `apply_due_commands()` 应用当天命令。
2. `prepare_exploration_day(view)`。
3. `run_movement(view)`。
4. `run_engagements()` / `run_wars()`。
5. `settle_exploration_day()`。

`prepare_exploration_day()`：

1. 用冻结 explored 更新 `seen`；若目标已探索，清 `blocked`。
2. 若到达当前观察点，记录该观察点；连续 3 个观察点仍未看见则标记 `blocked`。
3. 所有目标均被 `seen | visited | blocked` 覆盖时：
   - 有 `blocked`：结果 `SEEN_WITH_UNOBSERVABLE`；
   - 无 `blocked`：结果 `ALL_SEEN`；
   - 清空路线，进入 `RETURNING`。
4. 有交战则进入 `PAUSED_BATTLE`，清路线，不重新规划。
5. 用 `(到部队距离, cell_id)` 选最近未解决目标。
6. 在目标半径 0..2 的候选格中，跳过已到达/已尝试候选；按
   `(到部队距离, cell_id)` 选最近可用观察点。
7. 路径成功则安装路线，保持 `mission=EXPLORE`。
8. 只有所有合法候选都不可达/无候选才 permanent block。

部队实际进入选点格时立即记 `visited`；次日 explored 再升级为 `seen`。

### 4.1 返程

- 优先返回 `origin_cell`。
- 若 origin 已不再由本国控制或不可达，使用 `nearest_friendly_cell()`。
- 返回目标与整条路径都使用探路 passability。
- 到达后 `COMPLETE`，清 path/mission/target/area。
- 无安全返程路径则 `FAILED_NO_RETURN`，原地待命，不冒险穿越他国。

### 4.2 战斗暂停与恢复

- `run_movement()` 准备进入他国控制格时开启 engagement。
- 若该军有活动探路任务：
  - 保存 `resume_phase`；
  - 进入 `PAUSED_BATTLE`；
  - 清路线和 move points；
  - 保留 `mission=EXPLORE`，不改成 `NONE`。
- `settle_exploration_day()` 在 engagement 关闭后恢复原阶段；战斗造成的 `RETREAT`
  在无玩家姿态命令时回到 `HOLD`，`EMBARKED` 则继续等待上岸。
- 玩家显式改变姿态属于取消矩阵，会终止探路。

## 5. 探路寻路与性能预算

新增独立策略 `exploration_passable_for()`：

- 陆地只允许无主、本国所有或本国控制格。
- 其他控制者一律拒绝，即使 `at_war()` 为真。
- 源格例外由 A* 不复查起点自然实现；后续每一步都复查。
- 水域继续遵守现有海运科技与连续水格限制。
- 普通 `find_path()` 完全保留原语义。

A*：

- 每任务每日最多 2 次 A*。
- 每国每日最多 8 个任务规划槽位、16 次探路 A*。
- 共享全局每国 32 次路径请求，其中至少 16 次为区域控制保留。
- 任务按 `(last_plan_day, row_index)` 排序；只有真正获得槽位并执行 A* 才更新
  `last_plan_day`，预算耗尽任务次日优先重试。
- 扩展上限命中返回 `DAILY_BUDGET_EXHAUSTED`，不标记 blocked。
- 已有有效路线不消耗新 A*，直到到达或路线被控制变化判失效。
- 热路径无 `Dictionary / Variant / String`；候选、排序、mask 和 stamp 使用固定数组或
  `thread_local` scratch。

## 6. 视野接线

### 6.1 trail

`run_movement()` 只对玩家 observer 国家的部队，在**实际进入**每一格后调用
`record_exploration_trail()`。

- dense `uint32_t` stamp 按格去重，不使用 hash。
- trail 不保存、不参与 state hash、不写 visible/fog。
- 多格日行军会记录全部实际进入格；最终落点仍作为普通
  `military_source_cells` 低预算视野源。
- 清 trail 时推进 generation，避免清空后重新分配大数组。

### 6.2 Host 日边界

`WorldRuntimeHost._prepare_military_exploration_day(day)`：

1. 无任务、无 trail、无 pending explore 时 early-out。
2. 设置 observer。
3. 刷新已提交部队位置源。
4. 取 trail 并逐格合并进 `MapData.explored_arr`。
5. 成功合并后清 native trail；失败保留 trail 并返回诊断。
6. 若新增 explored、地图未解算或国家视觉待刷新，调用一次既有 `_refresh_vision()`。
7. 复制冻结 explored，调用 `set_military_exploration_view()`。

`_refresh_vision()` 仍是 `visible_arr / fog_k_arr / fog dirty / LUT` 的唯一入口。

三个日入口都必须调用 hook：

- `_run_native_daily_inline_day()` 在 `ext.run_native_daily_inline_day()` 前。
- `_on_clock_day_changed()` 在 legacy SUS tick 前。
- whole-graph catch-up 在**每个补跑日的 `facade.run_daily(day)` 前**，不是整个 batch 前一次。

### 6.3 保存前 flush

`GameSaveCoordinator._save()` 在安全边界成功后、采集 provider 前调用：

```text
host.flush_military_exploration_trail_for_save()
```

trail 合并/清空失败则拒绝保存，绝不写出丢失 explored 的 PKFG。

## 7. 取消矩阵

以下命令取消受影响部队的探路，结果写 `CANCELLED`，清派生索引和路线：

- 新 `explore`：替换本军旧任务；先验证容量、归属、交战状态，失败不得破坏旧任务。
- `move / area_control / stop / stance / station / disband`。
- `merge` 的 source、`split` 的 source、`transfer` 的 source。
- `destroy_army()`，包括战斗歼灭、归并、退役等内部路径。

终态行可保留到容量复用，但 `has_work=false`；`destroy_army()` 额外将行
`active=false`，避免 PKMI 引用已不存在的 handle。

## 8. 存档：PKMI v4 / MILB v4

- `PKMI_VERSION = 4`。
- MILB wrapper version = 4；v3 明确拒绝。
- 新 section 23 `kSection_Exploration`；空表也写 `count=0`。
- 仅保存任务持久字段；不保存 trail、explored view、fog、派生索引、path scratch。
- 恢复顺序：解码临时 core -> 严格校验 -> 重建 `_exploration_by_army` -> 原子换入。

关键校验：

- 任务数 ≤256；row 唯一；army 可解析且 owner 一致；一军一任务。
- selected count 1..256、范围合法、严格升序、无重复。
- mask 不允许越出 selected_count；`seen/visited/blocked` 同一目标互斥。
- phase/result/pause/resume 组合合法。
- 日期有序，观察点不重复且在候选集合内。
- 活动 path 的最后格与 observation/return 目标一致。
- 明确错误如 `pkmi_version_mismatch_expected_4`、
  `pkmi_wrapper_version_mismatch_expected_4`、`pkmi_exploration_section_missing`、
  `pkmi_exploration_duplicate_army`、`pkmi_exploration_bad_cells`、
  `pkmi_exploration_bad_masks`、`pkmi_exploration_bad_phase`、
  `pkmi_exploration_army_missing`。

空任务表跳过 state hash mixing，保证无探路世界与迁移前 hash 一致；非空表按
持久字段和行序完整混合。`tools/ci/cpp_save_section_contracts.json` 的 PKMI 版本为 4；
GDScript provider `PKMI_SCHEMA` 保持 1，不误改 manifest 版本。

## 9. UI / UX

部队命令区顺序：

```text
定位 / 行军 / 区域控制 / 探路 / 停止任务
```

- 复用 `IconButton.apply_with_text` 和 `map.expedition` 图标。
- 44dp 最小热区；HFlow 自动换行。
- 焦点链 `Locate ↔ Move ↔ Area ↔ Explore ↔ Stop`。
- 快捷键：`E` 打开探路草稿，`Enter` 确认，`Esc`/右键取消。
- 外军隐藏探路；本国交战中禁用并显示原因。

草稿：

- 半径标签“探查半径（格）”，1..6。
- 中心 + 半径生成最多 256 格高亮与提交数组。
- **不调用 `preview_path()`**；中心不可直达仍可提交。
- 确认文案：

```text
确认探查范围
范围 N 格 · 完成后返回出发点
不会主动进入他国控制格
```

- 不显示 ETA、预计天数或伪造路线。

状态文案：

```text
探路 12/31
探路 12/31 · 返程中
探路暂停 · 交战中
探路完成 · 已返回
探查结束 · 3 格无法探明 · 已返回
探路完成 · 无法返回 · 原地待命
```

已取消的历史行显示“待命”，不能伪装成活动任务；无探路任务不渲染空区块。

## 10. 实现文件地图

| 层 | 文件 | 实现 |
| --- | --- | --- |
| 原生头 | `gdext/src/military_core.h` | 命令、枚举、任务结构、窄接口、派生索引 |
| 原生状态机 | `gdext/src/military_core_explore.cpp` | 创建、prepare/settle、观察点、返程、暂停、取消、trail |
| 原生寻路 | `gdext/src/military_core_path.cpp` | 探路 passability、四态 A*、逐格 trail 记录 |
| 原生编排 | `gdext/src/military_core.cpp` | opcode 33、取消矩阵、日顺序、玩家门禁、state hash |
| 原生存档 | `gdext/src/military_core_save.cpp` | PKMI v4、section 23、严格校验、索引重建 |
| 原生自测 | `gdext/src/military_core_selftest.cpp` | 任务、路径、预算、返程、取消、存档、续跑 |
| 桥 | `gdext/src/world_ext_military.cpp`、`world_ext_bind_methods.cpp`、`world_ext.h` | `army.explore`、observer/view/trail/work、快照 |
| Facade | `scripts/military/military_facade.gd` | 命令白名单与五个窄方法 |
| Host | `scripts/game/world_runtime_host.gd` | trail 合并、vision 复用、冻结 explored、save flush |
| 日入口 | `world_runtime_daily_adapter_part1.gd` / `part3.gd` | inline、legacy、逐补跑日 hook |
| Save | `scripts/game/game_save_coordinator.gd` | 安全边界后 flush，失败拒存 |
| 输入 | `scripts/game/player_controller.gd` | 命令常量、草稿、无 preview、参数校验、dispatch |
| View model | `scripts/ui/military_view_model.gd` | mission 3、exploration note、explore action |
| Dossier | `scenes/ui/military_dossier.tscn`、`scripts/ui/components/military/military_dossier.gd` | 按钮、半径、焦点、快捷键、可见性 |
| UI 路由 | `scripts/ui/game_ui_manager.gd` | `explore` action |
| 契约 | `tools/ci/cpp_save_section_contracts.json` | PKMI 4 |

## 11. Checklist

### 文档与边界

- [x] 创建并重写本计划，记录目标、现状、契约、状态机、预算、视野时序、存档、UI 与证据。
- [x] 标记非目标：不自动宣战、不自动占中立格、不改变区域控制 5 日评估、不新增事件/视野算法。
- [x] 阅读并更新 `docs/architecture/design.md`、`development-guide.md`、`current-state.md` 的军事/视野/存档说明。
- [x] 更新 `project-keynes-military-runtime` skill：PKMI v4、自动探路契约、trail/Host hook、save flush、
  取消矩阵、测试入口与已知性能/smoke 缺口。

### 原生任务与命令

- [x] `military_core.h` 增加枚举、常量、任务结构与窄接口。
- [x] 新建 `military_core_explore.cpp`，实现规划、观察点、返程、暂停、取消和 trail。
- [x] `military_core_path.cpp` 增加四态路径结果与独立探路 passability。
- [x] `military_core.cpp` 接入 opcode 33 与 prepare/settle 日顺序。
- [x] move/area/stop/stance/station/disband/merge/split/transfer/destroy 全接取消矩阵。
- [x] `run_movement()` 逐格记录 trail；意外交战时暂停探路并保留 mission。
- [x] `armies_moving` 统计带活动路线的探路部队。
- [x] 原生玩家专属门禁拒绝外军探路。
- [x] `exploration_is_live_for_army()` 阻止取消/终态任务继续驱动移动、trail 或暂停。
- [x] `world_ext_military.cpp` / `MilitaryFacade` 接入命令、observer、view、trail、work。

### 视野与日边界

- [x] `WorldRuntimeHost._prepare_military_exploration_day()` 完成 trail、explored、vision、view 顺序。
- [x] inline、legacy SUS、whole-graph 每个补跑日均调用 hook。
- [x] trail 只写 explored；visible/fog 仍由 `_refresh_vision()` 唯一生成。
- [x] 多格日行军记录每个实际进入格，最终落点仍作为普通视野源。
- [x] `GameSaveCoordinator` 保存前 flush trail，失败拒绝保存。
- [x] 无探路工作时 early-out，不复制地图、不额外跑 vision。

### 存档

- [x] PKMI v4 / MILB v4，section 23 空表也写 count=0。
- [x] 任务行 encode/decode、row index、派生索引重建。
- [x] 严格校验 duplicate army、bad cells、bad masks、bad phase、missing army 等。
- [x] 空表跳过 hash mixing；非空完整混入；旧 v3 明确拒绝。
- [x] `tools/ci/cpp_save_section_contracts.json` 更新为 4。
- [x] `PKMI_SCHEMA` 保持 1。

### UI

- [x] 档案加入 ExploreButton、半径行、44dp 热区、焦点链、`E/Enter/Esc/右键`。
- [x] `PlayerController` 接入命令、参数校验、explore 草稿、无 preview 选点与确认。
- [x] `GameUIManager` 接入 `explore` action。
- [x] `MilitaryViewModel` 接入 mission 3、状态 note、终态/取消文案。
- [x] 草稿不调用 `preview_path()`；中心不可直达仍允许提交。
- [x] 1280、1920、520px 窄栏、21:9 渲染夹具与焦点/热区/无 ETA 检查。

### 验证

- [x] 原生 selftest 覆盖创建、mission 保持、已探索、战争禁入、3 观察点、预算、返程、无返程、取消、销毁、存档与 8 日续跑。
- [x] GDScript binding/auto-exploration 覆盖参数、facade、快照、外军拒绝、trail、catch-up、保存 flush。
- [x] 存档 round-trip、空表、active/returning/paused/completed、v3 拒绝、malformed、hash。
- [x] 档案/Dossier 与 VisionSolver 测试。
- [x] 真实渲染截图覆盖草稿、active、paused、completed、blocked 与四种布局。
- [x] headless editor import 无 Parse/Script Error。
- [ ] **未达标**：100k/2048 大基准 p95 仍高于既有 2 ms 预算。
- [ ] **未归因于本功能**：`military_runtime_smoke_test.gd` 的征兵 fixture 仍假设存在
  “tech-free barracks”，当前目录所有兵营均有科技门槛，导致 8 个下游断言失败。

## 12. 测试证据

环境：Windows Godot 4.6.2，D3D12 Forward Mobile，v14 debug/release DLL。

| 检查 | 结果 | 日志 |
| --- | --- | --- |
| 原生 selftest | 全部 pass；含 exploration 与 8 日 continuation | `.codex-temp/army_explore_v14_native_binding.log` |
| 自动探路集成 | `=== military auto exploration: 0 failures ===` | `.codex-temp/army_explore_v14_auto_exploration.log` |
| 军务档案 | `=== military dossier test: 0 failures ===` | `.codex-temp/army_explore_v14_dossier.log` |
| 视野 | `vision solver: 53 checks, 0 failures` | `.codex-temp/army_explore_v14_vision_solver.log` |
| 索引续跑 | native index continuation 全部 pass | `.codex-temp/army_explore_v14_index_continuation.log` |
| 存档契约 | `2 script owners + 12 C++ domains, 0 violations` | `.codex-temp/army_explore_v14_save_contracts.log` |
| 渲染 QA | `=== military dossier screenshot qa: 0 failures ===`，本次生成 28 PNG | `.codex-temp/army_explore_v14_dossier_screenshot_qa.log` |
| 编辑器导入 | 无 Parse/Script Error | `.codex-temp/army_explore_v14_editor_import.log` |

截图目录：`Project/project-keynes/tmp/military_dossier_qa/`。

### 12.1 性能

v14 `military_native_binding_test`：

- 2400 格 / 400 部队 / 64 交战 / 60 日：avg `0.2198 ms`，p95 `0.3053 ms`，
  max `0.9676 ms`，通过 0.5 ms 预算。
- 100000 格 / 2048 部队 / 4096 交战 / 30 日：avg `8.6256 ms`，p95 `20.1618 ms`，
  max `34.1501 ms`，**未通过** 2 ms 预算。
- 该大基准是既有 100k/2048 全军事日基线缺口，不能归因于探路，也不能宣称全绿。
  本方案保证的是无任务零额外成本、有任务预算有界，不承诺整体 100k 军事日达标。

### 12.2 已知失败

`military_runtime_smoke_test.gd` 当前 8 个失败：

- `catalog has a tech-free barracks`
- `barracks completed (posts > 0)`
- `soldiers > 0 after recruitment`
- `army.create accepted`
- `player army exists after army.create`
- 3 个军饷/财政断言

探路段的 PKMI encode/restore/state hash、无脚本错误与后续 120 日推进仍通过。
失败根因是 smoke fixture 与当前军事目录的兵营科技门槛不一致；本轮未以改断言或
改目录来掩盖，也没有把该失败算作探路验收通过。

## 13. 验收场景

### Native

- [x] D+1 创建任务；`mission` 不被 `assign_path()` 改成 MOVE。
- [x] 已探索目标无需移动即可解决。
- [x] 战争状态仍不进入敌控格，不打开 engagement。
- [x] 控制变化导致意外交战时暂停，战斗结束后恢复原阶段。
- [x] 前两个观察点不可见时继续第三个；第三个仍不可见才 block。
- [x] 预算耗尽保持 ACTIVE，次日重试；不误标 blocked。
- [x] origin 返回、friendly fallback、无安全返程。
- [x] 全取消矩阵与 `destroy_army()` 无悬空任务/索引。
- [x] 外军合法命令被 observer 门禁拒绝。

### Host / Vision / Save

- [x] trail 只写 explored，不写 visible/fog。
- [x] 多格日行军逐格去重进入 trail。
- [x] 4 日 catch-up 每日执行 pre-day hook。
- [x] 无新增 explored 且地图已解算时不额外跑 vision。
- [x] save flush 后 explored 包含 trail；clear 失败保留 trail。
- [x] 空表 section 23、所有阶段 round-trip、v3 拒绝、malformed、8 日续跑、hash。

### UI

- [x] 草稿不调用 `preview_path()`，中心不可直达仍可确认。
- [x] 选点 ≤256，参数 `army / cell / cells / radius`。
- [x] 外军隐藏、交战中禁用并给原因。
- [x] `E/Enter/Esc/右键`、焦点链、44dp 热区。
- [x] 不显示 ETA/空态占位；同身份刷新节点数稳定。
- [x] 1280/1920/520/21:9 无裁切，人工复核截图。

## 14. 后续工作

1. 若要实现“甩手征服”，需另外设计自动战争/自动占领状态机：
   宣战授权、目标选择、战后连续推进、中立格占领规则与外交约束都必须显式配置，
   不能复用探路的 passability。
2. 100k 全军事日 p95 需要独立性能立项，优先拆解 `consumption`、采购冷启动、
   engagements/wars 与缓存热态；不要把探路预算当成整体性能修复。
3. 修正 smoke fixture 的兵营科技前提，并纳入默认回归；这与探路功能解耦。
4. 若未来支持多 observer 或 AI 探路，必须扩展视图所有权与存档段；
   当前 `army.explore` 明确为玩家专属。
