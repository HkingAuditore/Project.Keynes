# 执行队列

记录日期：2026-11-12。本页只排顺序和状态；每项的做法见各自的计划文档。做完一项就更新状态，直接开始下一项。

## 规则

- 仓库里同一时间只有一个写任务。
- 做轻不做重。能删就不加：不为一次重构新增测试、护栏、兼容层或文档页；修 bug 用最小改动，不顺手扩范围。
- 验收和风险成比例：机械搬移只跑受影响的测试和一次改前/改后对比；只有改了行为或存档的批次才跑完整矩阵和只读审查。
- 每个实现批次的流程：实现（架构设计类自己做，其余可外包）→ 读 diff → 宿主机跑验收 → 写进度，并顺手改掉 `module-map.md` 里因本批而失效的路径。
- 重构用临时的改前/改后对比验证，不提交基线。
- 全部拆完后一起提交；提交和推送都等用户开口。
- 只在三种情况停下来问：玩法取舍、提交或推送、不可逆或对外的操作。
- 修 bug 先写根因证据再动手；外包提示词的同类要求见 `AGENTS.md`。

## 队列

| 序号 | 事项 | 计划文档 | 状态 |
|---|---|---|---|
| 1 | 存档续跑修复收尾 | `docs/architecture/feature-status.md` | 完成（2026-11-12）；遗留三项转入第 9 项 |
| 2 | 回归测试瘦身：默认 5 分钟内，另设 `--full` 档 | — | 完成（2026-11-12）：两次实测 3 分 50 秒 |
| 3 | G1 第 2a 批：删除 `map_generator.gd` 的 GDScript 计算回退 | — | 完成（2026-11-12）：减 2063 行 |
| 4 | G1 第 2b 批：剩余原生分发移入协作者 | — | 完成（2026-11-12）：再减 1321 行，到 18489 行 |
| 5 | G1 第 3–6 批 | — | 完成（2026-11-12）：`map_generator.gd` 22331 → 11865 行 |
| 6 | 第一波其余：C1、G2；绑定拆分阶段 2 第 3–5 步（越界 526 → 209） | `world-ext-binding-split.md` | 完成 |
| 7 | 大文件第二波、第三波 | — | 完成（2026-11-13）：C8 按需，改到哪个拆哪个 |
| 8 | 绑定拆分阶段 3：C++ 按模块拆类（bake 编码器 → 军事/年度 → modifier/trigger/effect/ideology → economy/country/runtime/climate） | `world-ext-binding-split.md` | 暂缓（2026-11-13）：立项条件未满足，评估见计划文档阶段 3 |
| 9 | 推送前修复已知失败（见下） | — | 待做 |
| 9b | worker 环境帧按日交接重设计（见下） | — | 完成（2026-11-14） |
| 9c | 测试推进一天的统一接口（见下） | — | 完成（2026-11-14） |
| 9d | 域输入未齐时立即报错，去掉软完成（见下） | — | 完成（2026-11-14） |
| 9e | ideology 效果只留一个后端（见下） | — | 完成（2026-11-14）：实例路径保留给派生层表达不了的程序，测试和 UI 改用不区分后端的目标报告 |
| 10 | 文档对齐：按拆分后的实际结构更新 `module-map.md`、`development-guide.md`、`AGENTS.md` 和各模块 skill 里的文件路径与入口；已完成的计划文档改成结果记录或删除 | `docs/architecture/` | 完成（2026-11-14）：skill 与文档里的测试路径改到新子目录；`large-file-split.md` 删除，规则并入开发指南，结果记入 feature-status；上游文档引用的未提交测试（经济平衡 soak、军事采购/配置测试）未动 |
| 11 | 汇报，等提交指令 | — | 完成（2026-11-14）：按用户指示合并上游后提交并更新 PR；第 9 项清单未清，已在 PR 说明中列出 |
| 12 | 智能体开发框架的下一轮优化（见下） | — | 待做 |
| 13 | 单一时间线迁移（见下） | `docs/architecture/design.md` 单一时间线 | 进行中（2026-11-14） |
| 14 | 落实上游在 PR #6 的玩法决策并回应审查（见下） | `gameplay-pending-decisions.md` | 代码部分完成（2026-11-14）：全量回归只剩 military20 原始模式（12b）；内容与数值等上游定，见待定文档 |

第 2 项排在拆分之前，是因为后面每一批都要跑回归，先缩短它最划算。

## 第 9 项的清单

- `cooperative_world_generation_test`
- `native_daily_active_bootstrap_test`（1 条）、`native_daily_graph_order_test`（2 条）
- 上游带来的：`player_controller_contract`、`building_visual_catalog`、`ui_scene_structure`、`goods_storage_schema`
- loading-cache 是否重新烘焙
- `generation_preflight` 的 missing_methods
- `ideology_save_worker_authority_test` 在并行回归里偶发失败（两次中一次），单独跑通过；它在等待期间观察 worker 写回，依赖真实时间
- 不在默认回归里的 5 个气候测试长期失败（`native_daily_shadow_runtime_test`、`season_refresh_schedule_test`、`vegetation_climate_loop_formula_test`、`sea_ice_solar_gate_formula_test`、`runtime_climate_save_roundtrip_test` 超时；删 GDScript 回退前后失败内容相同），决定修还是删
- `visual_tile_horizon_smoke_test`（base level 未上传）、`visual_tile_layout_test`（mobile 三档布局变化）、`menu_atlas_visual_qa`（300 秒超时）：G2 前后表现相同
- `effect_domain_integration_test`（technology modifier 缺失等 4 条）、`stat_key_family_test`（上游新增的 6 个 `military.cell.*` 键未归入 family）、`effect_native_modifier_bridge_test`（3 条断言后不退出，300 秒超时）：C3 前后相同
- `natural_resource_init_deposit_test`（4 条）、`natural_resource_pass_test`（2 条）
- `ideology_cell_layer_shard_test` 崩溃已于 2026-11-14 修复：测试把临时 `RefCounted` MapStub 交给只持弱引用的 `bind_map_data`，下一次采集读取了已释放对象；改为测试成员持有至所有切片结束。经济性能改造前二进制复现同一 signal 11；同一修复脚本在改前、改后二进制均为 6 checks / 0 failures（`/tmp/keynes-perf-redesign-20261114/{before/shard-repro,after/focused}/ideology_cell_layer_shard_lifetime_fix.log`），未放宽断言。
- 不在默认回归里：`ideology_x6a_worker_test`（factor 2.0 leaves building term unchanged）；2026-11-14 去掉经济输入预采集前后相同
- `golden_day_hash_test` 偶发退出时 `ObjectDB instances leaked`（一次，重跑两次通过）；2026-11-14 annual 365 的 original 段在 3 路并发下也出现一次，所有检查通过、无数据差异，带 `--verbose` 并发 4 次未复现
- 默认回归并行跑时偶发：`ideology_save_worker_authority_test`（DUR[3/4] worker 写回未发生）、`runtime_loading_exit_test`（frame 5 未释放加载世界）；C4 后各出现一次，单独连跑两次通过
- `economy_dossier_view_model_test`（4 个职业 agronomist、aquaculturist、dyer、ship_officer 未映射阶层；投资区块跨章节导航）、`player_ui_view_model_test`（调用不存在的 `_decorate_construction_item`）：G3a 前后相同，与拆分无关
- 高负载（load ~28）下第 1 天 ECONOMY/IDEOLOGY 哈希分叉，金样报 "Ideology commits after a prior opinion exists on day 1"；空闲时通过，拆分前同样如此。疑为续跑矩阵与年度自动存档 replay 分叉的根因
- `player_country_ui_smoke_test`（wide country dossier 书签栏 1 条）受本机 `settings.cfg` UI 缩放 125% 影响，测试未隔离用户设置
- `runtime_economy_worker_restart_test` 偶发崩溃（exit -10/-11）
- 拆分 C7 时的聚焦测试，改前改后同样失败：`colonization_starter_regression_test`、`colonization_workbench_ui_test`、`country_border_mesh_test`、`country_late_command_reschedule_test`、`country_reference_trace_test`、`settlement_runtime_test`、`economy_building_job_restore_test`
- 拆分 G5、第二/三波时发现：`player_map_overlay_smoke_test`（未识别矿产/木材 1 条）、`income_tax_player_regression`（`GameFlow` 标识符缺失，编译不过）、terrain shader 测试 17 条、ideology card-face semantics 11 条、technology authoring editor smoke 2 条、modern economy catalog 内容失败
- 续跑矩阵：第 1 天存档的首日视野顺序（见 `feature-status.md`）；multicountry5 checkpoint EFFECT 与 military20 resume COUNTRY 分叉 2026-11-14 已修
- `ideology_cell_layer_e2e_realworld_test` 的 B 项：开局是一格国家，没有国家超过 32 格，测试前提不成立（与理念代码无关）
- ~~golden 主路径偶发 COUNTRY 分叉~~（2026-11-14 已修）：提交者是 Trigger 效果经 Effect 镜像出的 Country 命令，不是视野观测批。封口日改为日尾完成日 + 2，日尾标记前交接 Trigger 效果，见 `feature-status.md`

### 玩法待定

各条的测试、2026-11-14 重跑结果、代码位置和可选做法见 `gameplay-pending-decisions.md`。这些测试保持失败，不计入第 9 项的修复范围。

### 运行时待修（非玩法，B/D/E 组定位到根因但未修）

- 已修（2026-11-14）：环满时气候输入采集失败，主线程下一拍跳到 D+1，worker 停在 D 等不到对应的环境帧，5 秒后报 `day_wait_peer_stall_timeout`，看起来像 Country peer 卡死。当时在 `mapgen_native_daily_runtime.gd` 给 SUS_TICK 输入日加了钳位，第 9b 项改成 C++ 游标后钳位已删除。lifecycle 连跑 4 次 0 次卡死（修前约每 2 次 1 次）。x5、x6b 的每日等待去掉 120 秒下限、基线改在推进当天之前读取，从 300 秒超时变为约 30 秒跑完。外包的 E2 补丁没有修掉问题，还放宽了断言，没有采用。
- 已修（2026-11-14，第 9e 项）：ideology worker 测试剩余失败。lifecycle、x6c、country_ramp、x5、x6b、scalar、x12、x9b、restart_mask、cell_card、derived_pump 全过，根因见第 9e 项。剩 x6a 一条：夹具假设经济静止（见第 9c 项），断言没改。
- 已修（2026-11-15）：Country 财政请求在 Economy 主线程路径中先确认消费、后落国家账，导致回执提前删除。现按既有执行边界先应用国家账并发布读视图，再确认；加强后的 `economy_fiscal_reservation_continuation_test` 为 57/57，旧二进制仍失败同 2 条。
- `trade_activity_runtime_integration_test` 访问 nil 的 `visual_tiles` 后一直等待。
- `military_runtime_smoke_test`：2026-11-14 换成合并前的等价兵营配方后 0 失败，原先登船少 1 名士兵的那条没有复现；真实数据下卡在建兵营（待定 12b）。
- `technology_refresh_latency_test` 剩 1 条：面板关闭的 6 天里研究进度没变，疑似排队的 3 项科技在测量阶段已研究完，未证实（2026-11-14 从玩法待定移来，原来的延迟问题已通过）。
- `runtime_country_parity_test`：第 2 天起 `research_deferred_points` 在 Country POD 与主线程科研队列之间不一致，之后屏障超时。2026-11-14 复跑剩 2 条（生产调度没有封住每个推进日；D11 soak 没有产出可比的 Country 帧）。
- 性能门槛（2026-11-15 更新）：军事大场景为 99,974 地块、2,048 部队、4,096 初始交战边，并非 10 万部队；第二轮 p95 三次中位降至 3.174 ms，仍高于 2 ms，继续优化重复准备。资源视觉的第一轮仍超过 1 ms，且 8,000 格固定帧数内完工量不足，不能计作等量性能提升，第二轮仍在验证。加载已完成冷热、两种地图的 24 次对照，改后 12 次均通过原 p95 ≤33 / max ≤100 ms 门槛，冷大图最长帧中位 2.489 s →86.5 ms；暖缓存总时间没有改善。见 `feature-status.md`。

## 第 9b 项：worker 环境帧按日交接

现状：Web 端由游标式预发布器（`ENV_CALLSITE_PREFETCH`，`world_runtime_daily_adapter_part1.gd`）独占发布，游标只在发送成功后前进，不会跳日。桌面端预发布关闭（`runtime_environment_prefetch_days = 0`），由 SUS_TICK、HOST_DAY_CHANGED、INLINE_DAY 三个调用点各自推算输入日。

原计划第 1 条（桌面端也改由预发布器独占发布）没有做：预发布让帧的采集时刻提前到日历之前，主线程持有的 lane 最多旧 K 天，且采集时刻随帧节奏变化，会改变桌面端结果并可能破坏确定性。问题的根源是"每个调用点自己推算输入日"，所以改成共用一个 C++ 游标，发布者不变。

实际做法（2026-11-14）：
1. C++ 记录最后发布的帧日，`runtime_next_environment_day()` = 该日 + 1。Climate 由 worker 权威时，`publish_environment` 只收这一天，其余返回 `runtime_input_day_not_next`，失败结果带 `day` 和 `expected_day`。跳日的帧进不了环，worker 端不再可能等一个永远不来的日子。
2. GDScript 只有一个入口 `publish_environment_through(last_day, phase, callsite)`：从 C++ 游标开始按顺序补发到 `last_day`，中间日取下一天的日历相位（与日切换约定一致），`last_day` 用调用方给的相位；已发过则返回缓存。SUS_TICK、HOST_DAY_CHANGED、INLINE_DAY、预发布器、年报边界全部改走它，调用点不再推算输入日。
3. 删掉 `_runtime_last_capture_day`、SUS_TICK 的止血钳位、预发布器自己的游标（`_environment_publish_next_day_cursor` 及其读写函数）。`_climate_authority_grant_pending` 改读报告里的 `simulation_environment_day`。`_drain_climate_writeback_for_season_refresh` 只会以 `allow_blocking=false` 被调用、实际什么都不做，整段删除。
4. 发布权（`set_worker_environment_publisher`）保留不动：Web 上它决定哪些调用点会在日切换时阻塞等待，与输入日无关。

已知未统一：Web 预发布器给第 N 帧用第 N 天的相位，桌面三个调用点用第 N+1 天的相位，两端同一天的输入相位差一天。改它会改变 Web 端结果，这里没有动。

验收：golden 主路径加 external-only；做一次改前/改后的性能记录对比；跑 lifecycle、x5、x6b、country_ramp。

验收结果（2026-11-14）：golden 主路径和 external-only 各 2 次，与改前基线一致。性能记录（50 天，60×40，seed 20260718）权威吞吐 25.65 → 28.69 天/秒，run_ms 2199 → 1952，守恒误差全 0；吞吐门槛（50 天/秒）改前改后都不过，不是这次引入的。23 个相关测试里 stall 和 `runtime_input_day_not_next` 都是 0；lifecycle、x5、country_ramp、x6b、财政续跑的失败条目与改前同类，`country_late_command_reschedule` 由失败转为通过。两个测试按新约束改了：`runtime_opinion_input_lifecycle_test` 改为从 `runtime_next_environment_day()` 补发到目标日，原来重复发布第 1 天；`runtime_climate_save_roundtrip_test` 删掉重启后再采集第 1 天的一段，`start()` 已经重新放入第 1 天的帧并保留轨迹，重复的第 1 天让 worker 停在 `climate_trace_reference_pending`。

## 第 9c 项：测试推进一天的统一接口

现状：十几个 ideology worker 测试各自复制 `_drive_days`、`_wait_pod_day`、`_request_save`，超时从 2 秒到 120 秒不等，基线读取时机、是否服务 Country peer 各不相同。x5、x6b 超时和 scalar 存档挂起都出在这层。

原计划把接口放在 C++，实际（2026-11-14）放在 GDScript 的 `tests/ideology/ideology_worker_wait_helper.gd`：推进一天必须走生产的帧服务（`host._process` 消费 Modifier/Effect 快照、发布民意输入），C++ 单独推进时这些消费者不运行，测试看到的状态与正式运行不同。

接口：
- `drive_worker_day(s)`：按生产顺序设时钟、`run_daily_tick`/`finish_daily_tick`、`host._process(0.0)`、发布民意输入，暂停时钟后等 worker 提交前一天（锁步约定：跑完第 T 天的 tick，worker 提交 T-1）并等日屏障。每天 10 秒无进展即返回错误码，不再整段挂到 300 秒。
- `wait_committed(day)`、`request_worker_save`：返回提交回执或带诊断的错误码。
- `wait_for`/`wait_until`：带推进回调的通用等待。

迁移了 22 个测试（ideology worker 测试 20 个，加 `economy_worker_restart_day_test`、`runtime/worker_restart_boundary.gd`），删掉各自的 `_drive_days`/`_wait_pod_day`/`_request_save` 副本。没迁的：直接操作裸 ext 的运行时存档测试、parity/军事/性能驱动器、derived_pump 自带的双路推进。

迁移中发现的问题：
- 各测试里的 `has_method("has_hard_barrier")` 循环全是死代码：WorldClock 没有这个方法，真正的接口是 `_day_advance_blocked_by_barrier()`。
- GDScript lambda 按值捕获外层局部变量，在 lambda 里给外层变量赋值不会传出。x5、x6a、x6b、x9b、country_ramp、等待辅助本身、`inspector_tax_interaction_test` 都有这种写法，等待结束后读到的是旧值。改为等待后重新读取，或用数组承载。
- x6a 读 Modifier 快照环判断因子是否生效，但环是读一次即释放：生产帧服务（`apply_runtime_modifier_snapshot`）应用后把槽位放回 FREE，测试再读为空。改读主线程镜像 `list_modifiers`。
- `ideology_worker_layer_gap_diagnosis.gd` 是测量缺口的诊断，缺口已由派生前沿修掉，删除；authority_parity 的 B2 由"测到缺口"翻为"前沿已安装并覆盖格子"。

结果（改前 → 改后失败条数）：boundary_lock、card_content（71 秒 → 10 秒）、social_media、split、x10、x16、save_worker_authority、effect_save_pkef、economy_worker_restart_day、authority_parity、inspector_tax 均为 0；x1b 1 → 0；cell_card 4 → 1（三条 peer stall 超时消失，剩装备失败，与改前同）；restart_mask 2、x12 2、x6c 6、x9b 2、lifecycle 1、x5 3、x6b 1、country_ramp 2 与改前同。scalar 改前在第 38 项检查前挂住，改后跑完，剩 1 条（public_hygiene 卸下后 `transition_pending` 不落定）；x6a 改前第 7 项就停（没有自有人口群），改后 53 项剩 1 条（夹具假设经济静止，第 10 天世界里建成建筑使建筑项 0 → 8200，与因子无关，未改断言）。derived_pump 无改前基线，剩 8 条（W 路 `installed=false`），只删了死代码。所有测试都不再整段超时。

## 第 9d 项：域输入未齐时立即报错

现状：ideology 阶段在缺民意快照、日期不单调时软完成（标记完成但什么都没做），停驻原因残留；worker 缺环境帧要等 5 秒才以 peer 超时报出。测试因此只会挂住不会失败，排查要靠采样堆栈。

实际做法（2026-11-14）：`execute_ideology_worker_stage` 改为返回枚举 `IdeologyStageOutcome`，阶段按枚举分支，删掉按错误字符串判断软完成的 `ideology_soft`：
- `COMMITTED` / `ALREADY_COMMITTED`：后者是别的域停驻导致同一天重跑、POD 已提交过，直接完成。
- `AWAITING_OPINION`：缺民意快照。Ideology 排在 Economy 之前，Economy 首次提交前必然没有，所以跳过当天并计入报告的 `ideology_opinion_wait_days`，不拖住其他域。
- `FAULT`：`ideology_pod_not_configured`、`ideology_country_snapshot_missing`、`ideology_day_not_monotonic`（日期倒退）立即 fault，错误码即原因。
- `PARKED`：计划/提交失败等可重试情况，照旧停驻。

worker 缺环境帧的另一半已由第 9b 项消除：跳日的帧进不了环，不会再等一个永远不来的日子。`resolve_apply_contracts.json` 删掉 ideology 的 `retained_soft_paths` 一行，护栏的变异测试改到 trigger 路径。原来软完成时调用的 `note_day_park` 只写报告里的诊断字段，去掉不影响调度。

验收结果（2026-11-14）：
- 裸 ext 授予 IDEOLOGY、不做配置：270 毫秒内 FAULTED，`fault_code=ideology_pod_not_configured`（改前软完成，测试只会挂住）。
- golden 主路径和 external-only 各 2 次与改前基线一致；日志里没有 ideology FAULT，第 1 天等民意计 1 天。
- 默认回归 4.4 分钟。查出两个第 9c 项引入的解析错误：`runtime_economy_worker_restart_test`、`cell_situation_worker_test` 继承了迁移过的测试，仍在用被删的 `_wait_pod_day`/`POD_WAIT_MS`/`_worker_fault`，已改，单独跑都通过。其余失败是第 9 项清单里的已知项：`player_controller_contract`、`ui_scene_structure`、`player_country_ui_smoke`（UI 缩放）、`military_index_continuation`（army pay 自测）、`ideology_save_worker_authority`（并行偶发，单独跑通过）、续跑矩阵 multicountry5。
- multicountry5 单独再跑 2 次，1 次分叉。EFFECT 哈希只在两个固定值（`17395818638376662095`、`2294542502567318451`）之间切换，而且原始跑本身就会取到任一个值，说明是 Effect 域里某个结果早一天或晚一天生效的竞争，不是续跑造成的。归入第 12 项"确定性规则"的第一批修复对象。

## 第 9e 项：ideology 效果只留一个后端

现状：DerivedCell 后端已全量启用（`cell_program_rollout_enabled` 恒真），旧实例路径和实例报告接口仍在。lifecycle、x6c、country_ramp、x5 按实例路径断言而失败。

做法：先确认是否还有选择器种类必须走实例路径。没有就删掉实例路径及其报告接口；有就提供不区分后端的"卡实际作用到哪些格"查询，测试和 UI 改用它。四个测试的夹具迁到这个查询（`ideology_x1b_source_count_test` 的 `_target_count` 是先例）。

验收：四个测试的目标查找不再依赖实例；golden 主路径加 external-only；存档段若变化按"存档尽力兼容"处理。

实际做法（2026-11-14）：
- 实例路径不能删。资格判定（`cell_program_eligibility.h`）把非格域目标、有时限的生命周期、叠层、读 STATE 锁存的条件、派生层表达不了的选择器和非常量取值留给实例路径。所以保留实例路径，另加不区分后端的 `get_ideology_effect_target_report(handle)`：列名与实例报告相同（`idea_ids`、`idea_levels`、`program_hashes`、`target_handles`、`target_domains`），外加前沿已安装时的派生行，以及 `backends` 列。理念面板（`ideology_effect_report.gd`、`ideology_facade.gd`）和测试改读它；改前派生卡在面板上没有作用格。
- 运行时修了两处，正式游玩可见：
  - 派生层冻结：worker 模式下派生重建按切片推进，作业按日键控，新的一天会丢弃半成品，而宿主每个日边界只调一次泵。日推进和帧一样快时，重建一次都完不成，前沿停在最后一次安装（x5、x6c、country_ramp、derived_pump W 路）。另外每片各自拿锁，一次折叠可能读到两个经济 epoch。改为在 `step_ideology_derived_rebuild` 的一次持锁内做完。
  - 条件被跳过：派生收集器不评估程序级条件，41 个带条件的 OWN_TERRITORY 程序（village_compact、subsidy_state 等）对所有候选格无条件生效。改为对每个目标格，用实例路径的同一份指标板（经济采样加理念标量）评估条件（`evaluate_program_conditions_for_metrics`）；读 STATE 的条件判为 StateDependent，留在实例路径。指标板起初只有经济部分，读理念标量的条件会被误判（正式目录没有这类条件），第 10 项跑 `check_cpp_deps.py` 时发现并补齐。
- "转换不落定"在运行时里不存在，失败都是夹具问题：
  - x6b 把 0 基的快照等级当 1 基比较（L2 应为 1）。scalar、x12 随派生层修复通过。
  - 抽卡门竞争（restart_mask、derived_pump、cell_card）：授予门槛科技是排队的 Country 命令，worker 下晚一天以上才落地；在这之前提交的 DISCOVER 被拒（回执 `ideology_discovery_not_allowed`），卡进不了收藏，之后报 `ideology_unknown` 或装备失败。`ideology_draw_gate_helper.gd` 加 `draw_gates_landed`，夹具等门槛落地再抽卡。
  - derived_pump 的 W 路从不跑生产帧：快照写回由生产帧每帧重试，`run_daily_tick` 里的那次总落在 worker 的日事务中（`economy_day_inflight`），所以镜像一次都没收到。补一次 `host._process(0.0)`，耗时从 155 秒降到 64 秒。
  - x9b：family revision 哈希的是目标资格输入（家族、分支、建筑所有权、测试覆写的分支下限），与卡是否应用无关。基线原来在覆写生效之后才读，改到覆写之前读。空闲五天里，格 58 的家族在第 19 天买下第二栋建筑，digest 前进是对的，断言改为家族行不变时 revision 必须不变。
  - country_ramp：门槛科技自己的 Modifier 行落在同一 stat（贸易容量）上，改为只累计理念行；progressive_tax、sovereign_fund 不在正式目录里（09-content-status 的保留项），删掉这两段。
  - cell_card、lifecycle、x5、x6c 改读目标报告。

结果（2026-11-14，串行逐个跑）：x5、x6b、x6c、scalar、x12、x9b、lifecycle、country_ramp、x1b、x1b_source_count、restart_mask、derived_pump、cell_card（agrarian_reform），以及 cell_layer 的 catalog、ramp、ramp_materialize、e2e、realworld_over32、numeric、unbounded，加上 authority_parity、save_worker_authority、boundary_lock、card_content、social_media，全部 0 失败。剩 x6a 1 条（经济静止假设，第 9c 项）和 e2e_realworld 的 B 项（一格开局，记入第 9 项清单）。golden external-only 2/2 与基线一致；主路径 4 次中 3 次一致，1 次第 4 天 COUNTRY 分叉，原因与本项无关（见第 9 项清单）。size ratchet 0 违规。没有改存档段。

## 第 13 项：单一时间线迁移

接续以 [后台分工目标](../architecture/design.md#单一时间线与前后台分工) 和
[运行现状](../architecture/current-state.md#前台尚存的模拟工作) 为准。下表保留前一轮的迁移记录。

根因（2026-11-14 核对代码）：不一致和偶发失败来自线程分工，不在 DOTS 数据布局。

1. 两个日历：命令生效日取提交瞬间 worker 的已提交日（`submit_runtime_command`、`enqueue_country_host_command_batch`），晚到的命令被 worker 改期到当天（Country 阶段）。
2. 双持状态：worker POD 与主线程镜像靠快照和 peer intent 互相同步，一天中途要等主线程回执，因此有停等位、250 ms 轮询和 5 秒超时。
3. 运行中切换权威：镜像齐了才把域交给 worker，切换日取决于时序。
4. 表外推进者（军事、视野、资源恢复）每帧在主线程追赶 worker 已提交日。

性能另算：早期瀑布曾测得 worker 每天 20.4 ms，其中经济公式 16.6 ms；这些阶段计时不能证明其中 21% 来自堆分配。2026-11-15 同机交替对照确认完整建筑链指标在每格重复整理固定目录是主要成本；改为配置时整理一次后，标签阶段三轮均值的中位从 14.824 降至 0.756 ms。完整经济对照与吞吐门槛的未达项见下表。

步骤（每步独立交付，删的比加的多）：

| 步 | 内容 | 状态 |
|---|---|---|
| 0 | 命令按日封口：生效日 = max(请求日, 主线程封口日 + 1)，删 worker 端改期；worker 先取第 D 天环境帧再收命令 | 完成（2026-11-14）：golden 空闲 4/4、负载约 26 下 6/6 一致；military20/multicountry5 第 13 天 EFFECT 分叉定位到科技效果跨线程回执，归第 2 步。之后加压又查出 Effect 镜像回 Country 的命令沿用 Effect 自己的生效日，可能落在已封口的一天，审查又查出事件和 Modifier 也不取封口日，于是封口统一放在命令环入口 `enqueue_batch`（调用方都在主线程）。Ideology 队列（worker 上的 Trigger 也写它，不能在命令环入口统一取）和 Economy POD 命令（`RuntimeEconomyPodCommand` 没有日期字段）当时没封口。golden 之后又分叉一次，原因是封口日取环境帧水位，而水位跟着帧时序跑在前面：有日尾闸门时封口日改为日尾完成日 + 2，Trigger 队列和 Ideology 队列的主线程入口也取封口日（worker 端写入不经过入口），日尾标记前交接 Trigger 效果，worker 启动时日尾完成日取起始已提交日（见 `feature-status.md`）。剩 Economy POD 命令没封口：默认整图加日尾闸门时它在第 D 天日尾提交、D+1 开头取走，次序固定；部分权威模式下仍依赖时序 |
| 1 | 世界创建即 worker 权威：删运行中切换、SHADOW、对拍 | 部分完成（2026-11-14）：删了主线程那条与 worker 抢着把经济切到 POD_ACTIVE 的路径，只留 worker 在两天之间自己切（第 1 天提交后，镜像齐了就切，日期固定）；`runtime_economy_auto_pod_active` 默认打开，测试与正式会话同一条权威路径。SHADOW、对拍按 design.md 黄金回放一节"覆盖充分前保留"，没删；新世界仍要等首日提交才授权。授权前那段窗口里，主线程原来照常跑 Country、Effect、Modifier 等已请求的域，会往 Effect POD 排科技实例、往命令环镜像 Country AI 决策，进多少取决于 worker 首日何时提交；现在主线程从请求起就停推这些域（`domain_main_thread_suppressed`，见 `feature-status.md`） |
| 2 | 去掉一天中途的跨线程请求（科技效果、经济输入采集、财政资产），每去一个删一种停等原因 | 部分完成（2026-11-14）：科技效果 ENSURE 在 worker 上解决；military20 主线程意图泵 0 次收到排队意图，剩下的国家停等（第 2、13、14 天）是 worker 内部等自己的 Effect 阶段回执。经济输入仍由 worker 在当天中途请求主线程从 MapData 采集：有了第 3 步的日尾闸门，采集读到的是第 D 天日尾之后的稳定状态，矩阵与加压 golden 一致；改成 worker 自取需要气候写回带温度历史（30 日、365 日）并把雾的可见格做成已提交视图，未做。财政资产停等在矩阵里 0 次出现 |
| 3 | 表外推进者并入每日表，军事最后，边界改动先与上游商量 | 完成（2026-11-14，闸门方式）：worker 等主线程报告第 D 天日尾（军事、自然资源）做完才开始 D+1（`mark_runtime_day_tail_done`），Climate 授权前不等；当时军事仍在主线程跑。后续在整日模式迁入军务、物理视野与资源恢复的计算，主线程仍承担部分交接。删了外围同日对齐实验。试过在日尾顺手采集 D+1 的经济输入：checkpoint 与 resume 采集时机不同，military20 第 21 天 COUNTRY/ECONOMY 分叉，已撤回，归第 2 步 |
| 4 | 各域快照合成每日一帧，界面改读帧，删主线程镜像 | 待做，已评估（2026-11-14）：Trigger、Ideology、Modifier、Effect、Country、Economy 六个域约 20 个 C++ 文件在主线程保留完整运行时，由 worker 快照重建（`apply_runtime_*_snapshot`、`mirror_*`），界面和 GDScript 直接读它们。要先给每个域定只读帧接口，再逐域把读方改过去，才能删镜像，单独立项 |
| 5 | 测试改用同步推进 | 待做，已评估（2026-11-14）：21 个测试用第 9c 项的 `drive_worker_day` / `wait_committed` 等 worker，10 个测试已引用内联模式（`native_daily_inline`）。迁移是把前者逐个改成内联单步，单独立项 |
| 经济 | 按实际消费者采样指标、复用固定目录与未变化的国家输入 | 经济重设计与三轮对照完成（2026-11-15）：固定目录改为配置时整理一次，国家输入按精确变化重建，地理标签仍覆盖空地。CORE 中位 28.707→51.749 天/秒（+80.3%），但仅 2/3 次达到 50；DETAIL 27.934→48.271（+72.8%），标签阶段均值的三轮中位 14.824→0.756 ms。黄金/表外/意图逐字段一致；第一轮仅收窄指标的收益在噪声内，不能归功于它。线程完成通知与库存命令的独立缺陷已完成定向验证；合并版补测 CORE 为 48.934/48.410/48.791 天/秒（均未达 50），不另宣称这些修复带来吞吐收益。最终军事/视觉版本尚待全整合验收。 |

验收：每步跑 golden 确定性检查（空闲与并行加压各若干次）和受影响测试。

## 第 14 项：PR #6 上游决策落地

2026-11-14 上游在 PR #6 对 `gameplay-pending-decisions.md` 逐条定了结论，另提 6 条审查意见、3 项要补的信息。按下表顺序做，小而独立的先做，合并任务不拆开。做完一条就把它从 `gameplay-pending-decisions.md` 删掉。

| 步 | 内容（括号里是待定文档的节号） | 结论要点 | 状态 |
|---|---|---|---|
| R | 审查意见 1–6 | 删无人引用的 Windows 二进制；行数基线逐条说明并收紧；列出 17 个消失的绑定名；黄金基线、性能门槛、AGENTS.md 破例给结论 | 完成（2026-11-14）：Windows 产物已移出并加进 .gitignore；行数基线 14 条余量收紧、21 条调高逐条说明；17 个绑定 7 个改内部、10 个删除；性能门槛经同机 A/B 确认是测量门槛，不是回归 |
| I | 补信息：结构效率公式（8⑤）、5 条打不开的科技路线归因（6a）、可达性审计抽样 20 条（8③） | 只读调查，写进回复 | 完成（2026-11-14）：结构效率原是按组折算；5 条路线都是测试过时；172/469 是审计把软投入当硬门槛，抽样 20 条全是误判 |
| a | 6b `composite_tools` | 去掉 `support_only` 并改 rationale；断言失败立即退出（优先）；policy 与 expected_bindings 一致改为目录编译期校验 | 完成（2026-11-14）：policy 改为 single 并改 rationale；断言失败立即退出；policy 与 expected_bindings 不一致时目录编译失败，这条校验又查出 16 个同类节点，一并改了 policy |
| b | 5 时代奖励 | 直接弹出；按新契约重写 7 条断言，延后路径的用例删掉；覆盖"大典播放时让位、下一轮重试"和 `SELECTED_PENDING` 单步推进 | 完成（2026-11-14）：测试按直接弹出重写，延后路径用例已删，覆盖大典让位重试和 `SELECTED_PENDING` 单步推进 |
| c | 6a 王国资格 | 不需要农业里程碑；先归因（条件 IR 里另有门 / 该节点本身是里程碑 / 断言过时）；加护栏：普通节点的研究条件不得引用里程碑节点；里程碑字段不删 | 完成（2026-11-14）：测试夹具过时，代码无门；目录编译期禁止普通节点的硬前置和路线条件引用里程碑 |
| d | 8② 作物 | 高原块茎田归 `highland_crop` 独立一档；土豆只要 `arable_land`；药草用 `plantation_land` + `fertile_soil` | 完成（2026-11-14）：作物数据与测试表按结论改，`crop_technology_parity_test` 通过 |
| e | 8④ 开局经济 | 开局全员失业是预期状态；一包过渡库存可接受；UI 给一句说明 | 完成 3/4（2026-11-14）：开局零雇工按预期断言，界面加一句说明；"全员失业"的解读待上游确认（待定文档 12f）。剩检视面板 1 条：夹具不建国家，`TECHNOLOGY_IDS` 无人授予，中立格没有科技，上游同样失败，属夹具缺口 |
| f | 8① 殖民包 | 工具未解锁就不放进殖民包（改 kit 数据） | 完成（2026-11-14）：工具未解锁时不进殖民包；根因是采购先因工具被拒（162），再因商品 122 现金不足 |
| g | 8⑤ 国库建造 | 各组独立选替代品、各自计量；先给出结构效率公式 | 完成（2026-11-14）：去掉编译期合并，各组按自己的效率折算；`building_runtime_test` 0 失败。目录测试新增 43 个单候选组，待上游定（待定文档 12b） |
| T4 | 10 + 11 资源链与储量 | 只保留一处缩放，标定参数上调 100 倍使储量持平；11 种矿产和海洋鱼逐格对比；量级断言 ±10%；资源链测试改成同族单调加跨字段校验，渔业两条随储量转绿 | 完成（2026-11-14）：缩放只在解析处定义一次；逐格对比 30/31 种资源一致，硫磺 9 格差 ≤1.1e-7（float32 舍入）；目标储量 12 条通过；渔业两条通过（根因是生态密度，不是 ×100）。剩 11 条微型矿层级（修前就失败）和铜矿升级效率倒挂，分别见待定文档 12c 与 6c |
| T1 | 1 + 9 非玩家国家的采购政策 | AI 调 `set_country_procurement_policy`，预算先算、队再排；未下发 policy 的国家给默认份额并 clamp，任何路径不再读 1000 万绝对值；验证 `available()` 有内容 | 完成（2026-11-14）：AI 按份额（暂定 50–200 bp）下发采购政策，读档与切模式时重推；绝对预算全部删除，未下发政策的国家按默认 200/5000 bp；科研底线只在有研究需求时扣；补贴实测发放。AI 殖民意图在冻结前计入殖民需求。科技点供给太低导致 100 天内研究不完，见待定文档 12e |
| h | 2 开局人口增长 | 第 100 天内开局聚落至少播一次增长；先改 `observe_development` 的 elif 与 `play_activity()` 的占位拒绝，再略调快；列出受影响测试并重跑 | 代码部分完成（2026-11-14）：建筑与人口各自判断，增长被占位或冷却挡住时保留旧基线、表现结束后补播。实测开局聚落 100 天内人口 40 → 39，一次没涨，所以集成测试仍失败；调快增长是数值改动，暂缓（待定文档第 2 节） |
| i | 3 水路贸易 | 按 bug 查：真实地图输出港口/连通数、跨水订单数、货流、画面商队；补真实对局回归 | 完成（2026-11-14）：水路内核没问题，正式对局看不到商队是因为开局没有水运科技、365 天内也研究不到（待定文档 12e）。真实地图授予水运科技后：402 个港口、46244 条连线，第 54 天派出跨水订单，在途货物和货款冻结可见，第 58 天到达，画面层有水路路线，三项账本误差为 0；已加真实对局回归 `water_trade_real_map_test.gd`。合成夹具的问题是库存下标只写到第 0 个市场、对岸没有需求，按结论 B 在对岸加居民需求造出缺口 |
| T2 | 4 + 6c 军事—经济目录对账 | 核心槽硬门槛、次要槽同类低品级替代（运行时行为）；战力按实际发放品级；升级后产量与效率必须更高（4 条按 bug 修，写进护栏）；同时代不得重复解锁雷同建筑（机械判据）；`natural_rubber` 分三段；民用消费要有数据位 | 代码完成（2026-11-14），内容暂缓：目录 49 个装备槽标 `core`，采购、交付、战力、AI 估价和 PKMI v7 存档按核心/次要规则运行；升级检查扩到三项，雷同建筑判据写进产业链测试（59 → 33）；民用消费用建筑软投入承载，不加数据位。剩 16 个装备槽无可生产商品、23 条升级倒挂、8 条时代不符、1 组雷同建筑、橡胶早期用途，都要改内容或数值，见待定文档第 4、6c 节。活世界烟测造不了兵营是 12b 的后果，不是 T2 运行时问题 |
| T3 | 8③ + 6c 的 26 条 + 7 的消费者 可达性审计 | 先查审计是否系统性跳过采集/自营建筑（`wild_wheat_stand` 一例），解释清楚再谈其余 | 完成（2026-11-14）：审计跳过软投入作门槛（469 → 0、172 → 0），军队装备槽、维修品、补给接进审计作硬消费，26 条军械闭合。剩 14 条需求晚一个时代（待定文档 12a）；民用消费（猎人用弓）不缺数据位，建筑软投入就是承载字段，补内容归 T2 |
| T5 | 7 + 10 的数值断言 测试口径 | 结构型保留并防空转；数值型改为反读目录加同族单调或区间，钉死数字的删掉；保留跨字段交叉校验；民用电不做，写进文档；账本不守恒与电力同周期供电单独修 | 完成（2026-11-14）。运行时测试 117 通过、0 失败：科技 id 和升级档位改为从目录反读；授予科技要满足建筑的三道门（标签、必需科技、依赖组），带 Modifier 的科技要配 Modifier 运行时；顺带修了 `configure_economy` 兜底建国时没挂 Modifier 运行时、这类科技永远停在待生效的问题（`world_ext_economy.cpp`）。原先的"账本不守恒"和"电力同周期供电"两条，根因都是夹具缺 3 个环境槽，补齐后通过；共享池那条对应的机制已退役，删除。目录测试 5301 通过、18 失败：军事 `state` 类建筑、消费计划、构建分组、气候档案等过时断言按现状改写，钉死的内容清单改成结构检查；剩下 18 条是数据问题，见待定 12b、12g。民用电核实：`home_energy` 本来就有 `electricity` 变体，家庭市场按 cycle-flow 结算，文档按事实写。 |

## 第 12 项：智能体开发框架

整条线的起点是让智能体能局部修改、并行工作、依赖稳定接口。拆分做完后回到这个目标，用实际任务检验，而不是再加规则：

- 挑两三个小的真实任务（各落在一个模块内），交给便宜的模型从零开始做，记录它在哪里找不到入口、读了多余的文件、踩了别的模块。
- 按记录修：补 `module-map.md` 缺的入口，删掉 skill 和指南里过时或重复的内容，护栏只留真正拦住过问题的。
- 之后的日常维护：改了模块边界、入口或存档段，就在同一次改动里更新 `module-map.md` 和对应 skill。

### 确定性规则

起因：同一种子在机器空闲时可复现，负载高时第 1 天哈希就分叉（见第 9 项）。说明结果依赖线程快慢，可复现目前靠运气而不是靠规则。规则如下，任何模拟系统（C++ 或 GDScript）都适用：

1. **异步结果按固定步取回。** 后台任务的结果只能在调度图里规定的那一步生效；到那一步还没算完就等，不许"算完了就用"或跳过到下一帧。
2. **并行汇总用固定顺序。** 多个线程算出的部分结果，按任务编号等固定顺序合并，不按完成先后；需要累加的优先用定点数或整数。每个任务只写自己的那份输出，不往共享结果里直接累加。
3. **不按时间做决定。** 不用耗时预算、帧时间、重试次数决定处理多少、处理谁；分批处理按固定数量切。耗时类数据只进诊断，不进模拟状态和哈希。
4. **随机数和遍历顺序可复现。** 随机数从种子和实体编号派生，不用全局共享的随机源；不依赖哈希表、指针地址或线程编号的遍历顺序。

做法（保持轻量，不为此新增护栏）：

- 先按第 9 项定位这次高负载分叉的来源，按上面的规则修掉，作为规则的第一个实例。
- 顺带扫一遍现有异步和并行点（气候异步、每日调度图里的并行任务、经济/家族的并行阶段），记下哪些违反了规则；只修确有分叉风险的，其余记入清单按需修。
- 验证方法：在人为加压（并行跑一组压力进程）的情况下跑 golden 确定性检查，与空闲时的结果对比。写进 `development-guide.md` 的"确定性与重构对照"一节，改调度、加并行或异步时照做。
- 规则正文验证有效后移入 `development-guide.md` 同一节，本节改为指向那里。

### 性能：先量再改

现状（2026-11-13 静态统计，未剖析）：气候、洋流、天气、生物、烘焙按格子并行；经济的建筑/就业/市场/投资阶段和家族、理念、效果、触发器、国家基本单线程；C++ 与 GDScript 交界处大量使用 `Dictionary`/`Variant`。

- 用现有的无界面性能记录跑一次（如 50 天），列出每日耗时最高的几个阶段，以及交界处转换的占比。
- 只对确实最慢的动手，按原因选做法：交界处转换慢就改接口（批量、紧凑数组），不加并行；计算慢且能拆成"先算计划、再按固定顺序提交"的才并行，并遵守上面的确定性规则。
- 不慢的不动；不为并行而并行，不手写 SIMD。
- 每次改动用同一份性能记录做改前/改后对比，并在加压下跑 golden 确定性检查。

### GDScript 里与 C++ 重复的部分逐步删除

`scripts/simulation` 约 2.4 万行，其中一部分是 C++ 已经实现的计算（回退路径、SHADOW 对照、同一公式的脚本版）。后期逐步删，不集中做一轮：

- 改到哪个模块，就顺手删掉该模块里 C++ 已是权威、脚本版不再被正式路径调用的计算；GDScript 只留调度、转发和界面。
- 删之前确认没有正式路径依赖它；只被测试引用的，连同那条测试一起删或改成测 C++ 路径。
- 删除属于改行为的风险级别：跑受影响的测试和一次 golden 对比。
- 不新增兼容层或开关来保留旧脚本路径。

## 队列之后

外部推进器的日期对齐、Web 回退第 2 步、R5 多种子与战争覆盖。这三项不阻塞提交，队列走完后再排。


### 2026-11-15 本轮性能收尾更新

经济、军事、资源显示及加载的重设计已接入共同上游 `c7db86b75`。按用户要求减少验证并先汇报：双配置构建和13组关键检查通过，军事150天/1747操作/3份存档对照相同；仅做一对受外部负载影响的经济、军事与资源显示计时。军事本次仍未达2ms，加载本轮未重测，修后完整回归及多轮性能验收未完成。此前各轮数字是阶段历史，不代表当前最终验收。真实结果与剩余事项见 `feature-status.md` 文末；用户选择沿用上游新存档格式。
