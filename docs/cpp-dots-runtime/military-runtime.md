# Military Runtime（v1，PKMI v1）

本文描述**当前代码**中的军事运行时。设计依据 `docs/plans/military-system-design.md` v1.3，
跨模块接口冻结于 `docs/plans/military-implementation-contract.md`。两者与代码不一致时以代码为准，
差异在 §12「已知缺口」显式列出。仓库 Skill：`.dsh/skills/project-keynes-military-runtime/`。

## 1. 文件地图

| 层 | 文件 | 职责 |
| --- | --- | --- |
| 冻结 POD | `gdext/src/military_bridge.h` | `MilitaryTerrainInput`、`MilitaryWorldDigest`（D 日已提交视图）、`MilitaryIntent`（D+1 意图）、`MilitaryEvent`（40–47）、`MilitaryIntentReceipt` |
| 核心状态 | `gdext/src/military_core.h` | `MilitaryCore` SoA store、命令 opcode、阶段函数签名、`MilitaryReport` |
| 私有 helper | `gdext/src/military_core_internal.h` | `mul_div`（128 位中间量）、`rng(seed,key,day)`（SplitMix64）、Modifier stat 读取、unlock 位、民兵时代系数 |
| 核心实现 | `military_core.cpp` | 生命周期、命令、招募/训练/补员、士气组织、军饷/维护、`step_day` 编排、`state_hash` |
| | `military_core_path.cpp` | 地形步进成本、A\*、有界 Dijkstra、移动/ZOC/环境损耗、格→部队索引 |
| | `military_core_logistics.cpp` | 3 格采购（§9.3）、威胁/护卫场、车队与拦截、消耗、征发、物资账本 |
| | `military_core_war.cpp` | 战争、交战段（plan→replay）、会战、夺格/撤退/歼灭、战争分、区域任务、和议/赔款/吞并、增量战线、controller |
| | `military_core_ai.cpp` | AI 军事议程（每国错峰 30 日主决策） |
| | `military_core_save.cpp` | PKMI v1 编解码（事务式 restore） |
| | `military_core_selftest.cpp` | `MilitaryCore::self_test` / `bench`（A3 负责；见 §12） |
| Godot 桥 | `gdext/src/world_ext_military.cpp` | 目录解析、digest 采集、意图→Country/Economy 命令翻译、回执、查询、渲染快照、PKMI 外层包装 |
| | `gdext/src/world_ext_economy_military.cpp` | `set_military_ration_satisfaction`（口粮满足率推给 Economy）、`collect_military_economy_receipts`（Economy 结算 trace → 回执） |
| GDScript | `scripts/military/military_facade.gd` | 冷路径 facade，全部 `has_method` 守卫（旧 DLL 零成本降级） |
| | `scripts/military/military_catalog_compiler.gd` | `data/military/military_catalog.json` → dense id 字典；口粮候选来自 `soldier_household` |
| | `scripts/simulation/systems/military_daily_system.gd` | DCSystem `military_daily`，事件转发到 `GameplayEventBus` |
| 接线 | `map_generator.gd`（`_configure_military_runtime` / `_maybe_register_military_system` / `refresh_military_terrain`）、`world_runtime_host.gd`（整图补跑、季节地形、图层节点）、`game_save_coordinator.gd`（`pkmi` provider）、`player_controller.gd`（`military.*` 命令白名单） | |
| 渲染 | `scripts/rendering/military_*.gd`、`shaders/military_*.gdshader` | §9 |
| UI | `scripts/ui/military_view_model.gd`、`scripts/ui/components/military_workspace.gd` + `components/military/*` | 只读快照 + 语义命令 |

## 2. 权威边界

| 状态 | 权威 | 其他域如何影响 |
| --- | --- | --- |
| 兵员登记批次（lots）、训练订单、部队、路径、模板、区域任务 | `MilitaryCore` | 仅 `submit_military_commands`（玩家/AI） |
| 交战段、战争、停战、赔款、会战日志 | `MilitaryCore` | 同上 |
| 控制权 `_cell_controller`（-1 = 由 owner 控制） | `MilitaryCore`，PKMI 保存 | 只读：`get_military_control_snapshot()` / 渲染快照。**Economy 占领税/补贴归属 v1 未切换** |
| 军需库存（驻军格 / 部队）、在途车队、物资账本 | `MilitaryCore` | — |
| 官营建筑（兵营 / 城防 / 军校）的座数与档位 | `NativeEconomyRuntime` 的 kind 3 建筑组 | Military 每日从 digest 的 `state_*` 通道重建成派生缓存（§6.2），自己既不累加也不递减 |
| 领土、国库现金/物资、国家句柄 | `NativeCountryRuntime` | Military 只发 D+1 Country 命令（§5） |
| 人口、士兵 cohort、市场库存、商人 | `NativeEconomyRuntime` | Military 只发 D+1 Economy 命令（§5） |

不变量：

- Military **读 D 日已提交**的 Country/Economy（`capture_military_digest`：`copy_economy_snapshot`、
  `cash_for_slot`、`military_read_cell_view`、`military_read_market`、`military_read_state_buildings`、
  `has_technology`、Modifier `effective_value`），**只写自己的 store**，产出生效于 D+1 的意图。
- 不新增 `RuntimeDomainId`；Military 不是 worker domain，永远在主线程同步执行。
- 所有权变化（割地、吞并）只走 Country 命令，照常触发 `country_committed`。
- 状态全整数（q16 / MONEY_SCALE=10000 / GOODS_SCALE=1000），RNG 只由 `(seed, key, day)` 派生。
- 人员模型（`military_core.cpp` 头注释）：士兵始终是**家乡格**的 Economy soldier cohort；army 中的 lot
  只是账面视图，行军不移动 cohort，军饷/伤亡都落家乡格。

## 3. 日模型与 `step_day` 阶段顺序

`DCWorldExt::run_military_daily(ctx)`：

1. `day <= _military_last_step_day` → `skipped=true, reason=military_day_already_stepped`（防止 D+1 意图双发）。
2. `capture_military_digest` 采集 D 日视图（同时为每个活跃国家 `ensure_country_slot`）。
3. `apply_military_deferred_cash` 执行前一日的 `SPEND_CASH`（D+1 财政托管扣款）；
   `collect_military_receipts` 折叠所有已到终态的待回执行（Country 回执游标 + Economy 结算事件，§5.1）。
4. `MilitaryCore::step_day(day, digest, receipts, intents)`。
5. `publish_military_ration_satisfaction` → Economy（真实驻军口粮满足率，§5.2）。
6. 意图翻译为 Country / Economy 命令批，`effective_day = day + 1`，经 `submit_country_commands` /
   `submit_economy_commands` 提交；新行**追加**到跨日的 `_military_pending_intents`，直到发出回执才移除。
7. 返回 report（§10）+ `intents_submitted / country_ops / economy_ops / capture_ms / state_hash`。

`MilitaryCore::step_day`（`military_core.cpp:2484`）固定顺序：

| # | 阶段 | 说明 |
| --- | --- | --- |
| 0 | `normalize_digest`、scratch 扩容、`_last_digest` 镜像、`refresh_state_building_cache` | 每日重置路径请求预算；官营建筑缓存最先重建，排在一切读者之前（§6.2） |
| 1 | `apply_due_commands` | 到期命令按 sequence 应用（含战争/和议命令） |
| 2 | 过期本地施工位 | 只清 `construction_building` / `construction_done_day`，**不写**兵营/城防/军校计数：账本在 Economy（§5.3、§6.2） |
| 3 | `reconcile_receipts` | ENLIST/LEVY → 驻军 lot；DISCHARGE → 扣 lot |
| 4 | `update_force_targets` | 目标兵力（人数/预算模式） |
| 5 | (无) | ~~`build_supply_fields`~~ 已删除：市场索引由采购/征发按需构建（`MarketDayScope`），无每日供应场阶段 |
| 6 | `build_threat_fields` | 威胁/护卫场 |
| 7 | `run_recruitment` | 每 5 日采样：配额、入伍、缺员征召（事件 47）、自动退伍、欠饷逃兵 |
| 8 | `run_training` / `run_reinforcement` | |
| 9 | `run_movement` | 行军、ZOC、遇敌开交战段、环境损耗（CASUALTY 意图） |
| 10 | 排空 attrition 意图 / 官营营造请求 | 建造（kind 15）与拆除（kind 16）由桥侧分别转成 `queue_treasury_sponsored_build` / `queue_treasury_sponsored_demolish`，见 §5.3 |
| 11 | `run_area_missions` | 每日最多 32 次区域评估 |
| 12 | `run_engagements` | plan → 按边键升序 replay → 夺格 |
| 13 | `run_wars` | 冲刷和约意图批、战争分、全境沦陷跟踪、战线清理、过期停战 |
| 14 | `run_procurement` / `run_convoys` / `run_consumption` / `run_requisition` | |
| 15 | `update_morale_org` / `run_wages_and_upkeep` / `run_reparations` | |
| 16 | `run_country_ai`（`ai_decision_due` 时） | AI 命令走 `submit()`，D+1 生效 |
| 17 | 汇总 report、`reconcile_ledger`、`idle` 判定 | |

`should_run(day)`（`military_core.cpp:2615`）：存在待发命令、活跃部队/交战/战争/车队/训练/赔款/兵员、
目标兵力>0、招募采样日、维护日或 AI 到期日时为 true；和平空世界返回 false（零 slice）。
桥侧 `military_should_run` 另外拒绝 `day <= _military_last_step_day`；`submit_military_commands` 接受命令后
记录 `_military_forced_run_day`，该日（及之后首个未步进日）强制返回 true，保证排队命令一定被应用。
国家 slot 在 `configure_military`、`set_military_ai_player_handles` 与提交命令时（发令国未开 slot 且
Country 认可该句柄）通过 `ensure_military_country_slots` 打开，不再只依赖首个已步进日的 digest。

## 4. 调度

- **注册位置**：`map_generator.gd::_setup_sus()` 在 `natural_resource_daily` / `bio_occupancy_daily` 之后、
  `_try_register_native_daily_sim_job` 的 native/legacy 分叉**之前**调用 `_maybe_register_military_system()`
  （`map_generator.gd:4595`），因此 native daily ACTIVE 的 early-return 不会漏掉它。读档路径在
  `finalize` 中再调一次（`map_generator.gd:3389`）。facade 由 `_setup_economy_runtime` 在
  Country/Economy bootstrap 成功后配置（`map_generator.gd:1969`）；未配置时不注册。
- **DCSystem 描述**：id `military_daily`、priority 270（Country 255、Economy 260 之后）、`must_run=false`、
  `max_slices_per_tick=1`、`use_job_should_run=true`、`use_job_deadline_critical=true`、starvation 2、
  `slice_budget_ms=0.8`、`AlwaysPolicy`；`declare_reads/writes` 为空（不写 DataCore cell component）。
- **非整图路径**：`should_run` → `facade.should_run(day)`；`tick` 调 `facade.run_daily(day)`，随后
  `forward_military_events()`。
- **整图 ACTIVE**：`MilitaryDailySystem.should_run` 恒 false（`generator.runtime_graph_active()`）。
  `WorldRuntimeHost._consume_runtime_commit_if_ready` 每观察到一个已提交日调用
  `_queue_runtime_military_commit(day)`，同帧 `_drain_runtime_military_commits()` 每帧最多补跑
  `RUNTIME_MILITARY_CATCHUP_DAYS_PER_FRAME = 4` 日：`facade.should_run(day)` 为真则 `facade.run_daily(day)`，
  否则只推进游标；每日后调用 job 的 `forward_military_events()`。首次观察只回补最近 4 日。
  worker **从不**推进 Military；`facade.catch_up` / `run_military_catch_up` 只是带同一防重入守卫的主线程
  `run_military_daily` 别名。
  耗时记入 `_dcp_military_ms`（日成本键 `mil`）。
- **季节地形**：`refresh_military_terrain` 在季节刷新后重推 cover（facade 按 `hash(cover)` 跳过未变化）；
  整图 ACTIVE 由 host 的 `_refresh_military_terrain_on_season_edge` 检测季节边。

## 5. 意图 → 命令映射

| Intent（`military_bridge.h`） | 目标 | Opcode | 编码 |
| --- | --- | --- | --- |
| 1 `ENLIST` / 2 `LEVY` | Economy | 8 `CHANGE_SIGNATURE` | target = 该格 unemployed cohort，`i32_0` = soldier 职业，`i32_1` = cell，`i64_0` = 人数；无 unemployed cohort 时记为失败行 |
| 3 `DISCHARGE` | Economy | 8 `CHANGE_SIGNATURE` | soldier cohort → unemployed |
| 4 `CASUALTY` | Economy | 6 `ADD_POPULATION` | soldier cohort，`i64_0 = -heads` |
| 5 `PAY_WAGES` | Economy | 1 `TRANSFER_TO_COHORT` | soldier cohort，`i64_0` = 金额，`i64_1` = 国家句柄 |
| 6 `PROCURE_GOOD` | Economy | 13 `MARKET_GOOD_TO_COUNTRY` | target = 国家句柄，`i32_0` = 市场格，`i32_1` = good，`i64_0` = 数量 |
| 7 `CONSUME_TREASURY_GOOD` | Country | 21 `CONSUME_TREASURY_GOODS` | `aux` = good，`value` = 数量 |
| 8 `REQUISITION` | Economy | 5 `REMOVE_STOCK` | `i32_0` = 格，`i32_1` = good，无付款 |
| 9 `SPEND_CASH` | 桥侧 D+1（authority 3） | 无 opcode（Country 无扣现金命令） | 次日 `apply_military_deferred_cash` 调 `military_collect_cash` 走财政托管；回执 `committed_amount` = 实收额，0 → 失败回执。维护费是终端现金 sink，实收额登记为 Economy 的 `explicit_money_burn`；官营建造已改走经济侧结算（§5.3） |
| 15 `STATE_BUILD` | 桥侧同步（无 pending 行） | `queue_treasury_sponsored_build` | 军事建筑索引经 `economy_building_id` 翻成经济类型；经济受理后回送 `MCMD_STATE_BUILD` 仅记排期，`economy_building_id < 0` 或经济拒绝则该 lot 不建 |
| 16 `STATE_DEMOLISH` | 桥侧同步（无 pending 行） | `queue_treasury_sponsored_demolish`（economy opcode 35） | 15 的镜像：`cell` + `count` = 军事建筑索引，`country_a` = 属主国句柄。经济侧先减座数，受理后才回送 `MCMD_STATE_DEMOLISH`；该命令在核心里是 no-op（§6.2） |
| 20 `TRANSFER_TERRITORY` | Country | 3 | target = 接收国，`cell` |
| 21 `TRANSFER_CASH` | Country | 23 `TRANSFER_CASH_BETWEEN_COUNTRIES` | target = 付款国，`cell`/`aux` = 收款国 slot/generation，`value` = 金额 |
| 22 `TRANSFER_GOODS` | Country | 24 `TRANSFER_GOODS_BETWEEN_COUNTRIES` | 同上，`domain` = good |
| 23 `ANNEX_COUNTRY` | Country | 27 `ANNEX_COUNTRY` | target = 受害国，`cell`/`aux` = 吞并国 slot/generation |

### 5.1 回执

`_military_pending_intents` 是跨日集合，行状态 `receipt_pending`：1 等待、2 成功待发、3 失败待发
（提交即失败的行——无 unemployed cohort、批被拒——也以失败回执上报而非丢弃）。每日
`collect_military_receipts` 按序发出 2/3 行并移除；`effective_day + 8` 日仍无终态的行按失败超时。

- **Country（authority 1）**：worker 下按 `poll_country_command_receipts` 游标 + `try_country_command_terminal`
  点查（COMMITTED / REJECTED_AT_EXECUTION）；无 worker 时以 `last_committed_day >= effective_day` 视为提交。
- **Economy（authority 2）**：Economy 没有逐命令回执，`collect_military_economy_receipts`
  （`world_ext_economy_military.cpp`）在 worker 读边界内经 `poll_events` 折叠已提交 trace：
  `EVENT_COMMAND_SETTLED` 以 `(sequence, opcode, i32_1, i64_0[, i64_1])` 匹配行，`value0` 即实际量
  （PAY_WAGES 现金、PROCURE/REQUISITION 实际货量、CASUALTY 实际人口减量）；CHANGE_SIGNATURE（ENLIST/LEVY/
  DISCHARGE）的实际人数取同 epoch 的 `EVENT_STRUCTURAL_CHANGE`（源 cohort 句柄 + 目标 signature，
  `value0` = 迁移人数），该 epoch 无结构变化则失败；`EVENT_EPOCH_COMMITTED` 覆盖到 effective_day 仍未结算
  的行判为开 epoch 时被拒。`economy_trace_mode = OFF` 时无事件流，近似为 `last_committed_day` 到达即按请求量成功。
- `committed_count` 是实际应用量，因此 `reconcile_receipts` 只为真正转职的人数建驻军 lot、扣 `pending_enlist`。

### 5.2 口粮满足率

`publish_military_ration_satisfaction` 每日按驻军格计算：
`min(1, (当日该驻军 CONSUME_TREASURY_GOOD 消耗的口粮 + 剩余口粮库存) × yield / (人数 × ration_need_per_head))`，
只用 `MilitaryCore` 公开 const 访问器；驻军消失的格回写 1.0。地形/消耗倍率同时作用于需求与消耗，此处略去。

Country 22/25/26 保留不用。玩家/AI 军事命令字符串（`force.* / config.* / barracks.pause / train /
state.* / policy.* / army.* / war.declare / peace.*`）由 `kMilitaryOps` 映射到 `MilitaryCommandOp`，
提交即校验，`effective_day = _military_last_step_day + 1`。

### 5.3 官营建筑的营造结算

官营建筑（`building_kind = "state"`，经济侧 `kind` 数值 3）的座数由 **Economy 的建筑组**持有，
Military 只读（§6.2）。军事侧不再按建材估价折现金自己扣款。

- **建造**：`MCMD_STATE_BUILD` 写本地施工位（`construction_building` / `construction_done_day`），
  真正的付款由桥侧在做意图翻译时完成：`queue_treasury_sponsored_build(country, cell, economy_type,
  count, effective_day, sequence)` 优先扣 `NativeCountryRuntime` 国库物资，缺口按本地市场价从商人现货
  买入并付现金，支出记入 `NON_TAX_CONSTRUCTION`。经济侧受理后回送 `MCMD_STATE_BUILD`（§5 的 15），
  拒绝则发失败回执。建材不足 → `construction_materials_insufficient`；国库现金不足 →
  `construction_treasury_cash_insufficient`，两种情况都不留部分扣减。
- **拆除**：镜像入口 `queue_treasury_sponsored_demolish`，对应 economy opcode
  `COMMAND_TREASURY_SPONSORED_DEMOLISH = 35`。参数形状与 opcode 16 一致
  （`i32_0` = cell、`i32_1` = 经济建筑类型、`i64_0` = 座数、`i64_1` = `OWNERSHIP_TREASURY_SPONSORED_PRIVATE`、
  `target_handle` = 国家句柄）。**为什么不能复用普通 `COMMAND_DEMOLISH`(11)**：
  `apply_demolish_command` 要求 `population_store().valid_handle(cmd.target_handle, slot)` 并用该 cohort 的
  `signature_id` 去 `find_building_group`，而 state 建筑组的属主是保留签名 `_state_owner_signature`
  （第一个 `state_service_only` 职业 × 第一个有签名的族群，该职业不会被活着的 cohort 占据），
  没有任何 cohort 能命中它。拒因码：`demolish_target_invalid` / `demolish_not_state_owned` /
  `demolish_state_owner_unresolved` / `demolish_state_building_absent` / `demolish_owned_count_insufficient`。
- **两侧都不许二次记账**：竣工入账只清本地施工位、不改缓存（经济侧还要乘国家建造时间因子，
  军事侧那份完成日只是它的缓存）；`MCMD_STATE_DEMOLISH` 在核心里是 no-op。两侧各改一次会让同一座
  建筑被算两遍，并让 §6.2 的漂移探针每天误报一次。

### 5.4 维护与失修

官营建筑只有一张账单：**现金维护在 Military，物资维护不存在**。

| 环节 | 归属 | 行为 |
| --- | --- | --- |
| 维护物资 | Economy | 17 份档案的 `maintenance_good_ids` 全为空；`resolve_building_maintenance_csr` 也不会为 `kind == 3` 从建造 BOM 推导日耗，所以 `maintenance_count == 0`，经济侧维护循环直接跳过该组 |
| 现金维护 | Military | `run_wages_and_upkeep` 每 `kUpkeepPeriod = 5` 日按 `barracks_count[tier] × upkeep_per_day × 5`（兵营）与单座 `upkeep`（城防 / 军校）汇总每国账单，经 `MILITARY_INTENT_SPEND_CASH` 走 D+1 财政托管 |
| 岗位工资 | Economy | `state_payroll_group = (type.kind == 3)` 时 `wage_due = wage_paid = 0`，不产生欠薪、不停发工资、不抽业主现金；士兵的饷银由 Military 经 `COMMAND_TRANSFER_TO_COHORT` 直接转入 soldier cohort |
| 失修标记 | Military 唯一产者 | `afford * 2 < upkeep` 时置位。**只写在本次结算所属国自己拥有的格上**：账单按 `digest.cell_owner_slot[cell] == s` 汇总，写入也必须按同一条边界过滤，否则 A 国的欠费会盖到 B 国的格上（并让 `state_hash` 变化）。无账单的分支同样按国家清除自己的标记 |
| `operating_state` | Economy | `kind == 3` 在 `build_economic_plan` 里于 9636 行提前 `continue`，绝不会进入私营亏损 / 停业 / 清算状态机；`operating_state` 恒 0 |

失修的**作用范围严格限定**为两处：`cell_training_speed_q16`（军校训练速度减半，即 `MILITARY_Q16 + (speed - MILITARY_Q16) / 2`）与
`fort_q16`（工事加成减半 `best /= 2`）。它**不影响**兵额 `posts_for_cell`、不影响招募判定
（`run_recruitment` 只看 `paused`、兵额、在场与待征），也不改变士兵 cohort 的 `state_service_only` 语义：
该职业不服兵役时回流失业池、不主动转职、不参与普通劳动报价，经济侧的就业恒等式审计对它直接放行。

## 6. 数据结构

- **Lot**（`MilitaryLotStore`，SoA + free list）：`(location_kind 驻军格/部队, location, country_slot,
  unit_type, equip_quality_q8, condition_q16) → count`。
- **Army**（`MilitaryArmyStore`，SoA，上限 `MILITARY_MAX_ARMIES=2048`）：句柄 `generation<<32 | slot`；
  路径存于共享 arena `_path_cells`（offset/len/cursor），模板存于 `_template_rows`；
  `next_in_cell/prev_in_cell` 为派生侵入链。
- **国家**：只存句柄（`_policy_handle`），slot 由 `ensure_country_slot` 打开；`MilitaryCountryPolicy` 按 slot。
- **稀疏表**：`_cell_states`（按 cell 排序 + 派生 `_cell_state_index`）、`_stocks`、`_shipments`、
  `_engagements`（边 `cell_a<cell_b`）、`_wars`、`_truces`、`_reparations`、`_areas`、`_battle_log`（64）。
- **事件 ring**：容量 4096；同日同 `(type, cell, i0, i1)` 合并累加 `value`。
- **目录**：`MilitaryCatalog`（units 按 stable id 排序，恰好一个民兵兵种；装备类别；官营建筑；
  6 类补给候选与 `supply_yield_q16`）；`catalog.hash` 进入 PKMI 头。

### 6.1 格军事快照 `get_military_cell_snapshot(cell, observer)`

地块档案「军事」页只读这一个查询（不进存档、不进 hash）：

| 字段 | 含义 |
| --- | --- |
| `post_count` / `present` | 兵额（逐档兵营容量之和）/ 在驻（驻军 lot + 在场部队） |
| `pending_enlist` / `quota` / `paused` / `disrepair` | 征召中人数 / 本期配额 / 兵营暂停 / 欠饷失修 |
| `owner_slot` / `controller_slot` | 归属国 slot / 控制国 slot（不相等 = 被占领） |
| `fort_tier` / `college_tier` | 现存城防档 / 军校档（-1 = 无） |
| `barracks_tiers` | `PackedInt32Array(8)`，逐档兵营座数；拆除据此定位档位 |
| `construction_buildings` / `construction_done_days` | 3 个施工位：目录下标 / 完工绝对日（-1 = 空） |
| `garrison_lots` / `armies` / `training` | 驻军编成 / 同格部队（handle、headcount、foreign）/ 训练订单 |

档位 8 的兵营在目录编译期被 `clampi(..., 0, 7)` 压到 7，所以 `barracks_tiers[7]` 同时代表
tier 7 与 tier 8 两行；UI 显示取该档容量较大者，拆除只看 `role+tier`，任一同档下标等价。
`fort_tier` / `college_tier` / `barracks_tiers` 都是 §6.2 的派生缓存，本查询只读它们。

### 6.2 官营建筑缓存（派生，非权威）

`MilitaryCellState::barracks_count[8]` / `fort_tier` / `college_tier` **不是权威状态**，只是可重建缓存，
权威是 Economy 的 kind 3 建筑组（§5.3）。

| 环节 | 行为 |
| --- | --- |
| 采集 | `capture_military_digest` 调 `NativeEconomyRuntime::military_read_state_buildings`，把 `(cell, type_id, state_role, units)` 四条稀疏通道写进 `MilitaryWorldDigest` |
| 重建 | `step_day` 阶段 0 在 `_last_digest` 镜像之后立刻 `refresh_state_building_cache(view)`，早于兵额、工事系数、训练速度、部队支付与 AI 兵营规划的任何读者 |
| 写回 | 清零全部格的三个字段后按行重建：`barracks_count[tier] += units`、`fort_tier / college_tier = max(现有, tier)` |

契约要点：

- 读视图返回 `bool`。`false` 表示「账本没回答」（运行时未 bootstrap，或正在 save/restore），此时 out 向量
  已清空，但军事侧必须**保留存档恢复的缓存**，不能读成「所有官营建筑都没了」。
- `state_lanes_present` 区分「账本回答了但是空的」与「生产方没有这套通道」（早于本契约编译的桥）。
  只有前者（`true` 且 `state_lane_rows == 0`）才允许清零；后者必须原样留缓存。
- 档位来自军事目录 `state_buildings[].role/tier`。`state_state_role` 是经济侧 `STATE_ROLE_*`（1..3），
  比军事侧 `MILITARY_STATE_*`（0..2）大 1，重建时按 `role + 1` 比对，不一致记 `state_role_mismatch`。
  经济类型在军事目录里找不到的记 `state_ledger_unmapped`，这些行不产生兵额 / 工事 / 训练加成。
- `parsed` 强制按 `(cell, role, tier)` 稳定排序：漂移探针与昨日快照都依赖 cell 顺序，生产方改序不能静默比错格。
- **漂移探针**：`_state_ledger_prev`（昨日账本按军事目录解析出的 `(cell, role, tier, units)`，派生、
  不存不哈希）与当下缓存做归并比较，只有「缓存不符合昨天账本的要求」才 `state_cache_repairs += 1`。
  这样正常竣工 / 拆除不算漂移，真有别的代码写这三个字段才会暴露。`restore` 后
  `_state_ledger_prev_valid = false`，读档首日不会把整张地图报成漂移。
- 三个诊断计数在 `MilitaryReport` 里，随每日 report 重置，不存档、不进 hash，经
  `get_military_report` 以 `state_cache_repairs` / `state_ledger_unmapped` / `state_role_mismatch` 导出。

## 7. 性能设计

| 机制 | 实现 |
| --- | --- |
| 格→部队索引 | `_cell_head[cell]` + 侵入链，O(1) 插删；当日有移动时 `rebuild_cell_index()` |
| A\* | wrap 感知 hex 距离启发、二叉堆 + generation stamp，`kMaxPathNodes=4096` 扩展上限；每国每日 ≤ 32 次请求（超出顺延） |
| 有界 Dijkstra | `bounded_dijkstra`（默认 512 扩展，stamp 复用）；预览路径为 BFS 冷路径 |
| 3 格采购（§9.3） | `MarketDayScope`：拓扑变化时 `build_rings()`（每格 19 格环、BFS 顺序），当日首次需要时才 `build_market_csr()`（O(市场行)），作用域结束时丢弃。需求者只查自己的环；**无全国最近市场场**（已删除 `build_supply_fields` / `_near_market` / `_near_cost` / `_supply_dirty_country` / `FieldIndex` / 回退扫描） |
| 采购需求者 | 驻军格（`_lot_cell_head` 非空）、部队、训练订单各检查一次；只有**低于再订货点**（库存 < 5 天，目标 10 天）的持有者参与，库存经 `military_stock_row` 索引查询，不走全表 |
| 采购撮合 | 每个需求按环内市场行的（每需求单位价格, 行号）排序；按"第 k 便宜"轮转买入，单市场 ≤ 当日可售 50%，单一需求 ≤ 8 个市场；同格当日入库，其余生成路程=环距离的车队；环内无货 → `unmet_procurement_*` 计数（无全局回退） |
| 供应连通 | `military_supply_connected`：环内是否存在本国拥有且控制的市场格，O(19)；`military_connectivity_connected`：仅在需要时（征发 / last_stand）按国做一次控制格 BFS |
| 批发索引 | `sum_lot_value` / `army_fort_ignore_q16` / `garrison_heads_at` / 批量转移 / 采购买方全部走侵入链（`military_for_each_lot`），不再全表扫描 lot |
| 威胁/护卫场 | 每日 O(部队 × 7)，`_threat_stamp` 免清零；拦截概率 = threat/(threat+guard+escort) × cap |
| 交战 plan-then-replay | Plan 阶段纯读、按边键排序；Replay 按升序串行改状态，夺格在全部 replay 后统一处理。当前 Plan 循环**单线程**（并行化未接） |
| 增量战线 | `update_front_cells` 只重算受影响格的 6 条边，`_front_edge_set` + `_front_edges`，变化时 bump `front_revision` |
| 事件合并表 | `EventDayIndex`：每日开放寻址表，容量 ≥ live×4+64，`insert` 带探测上限；环形缓冲满时重建（旧实现表内残留已删除行，会导致 `insert` 无限探测——100k 基准卡死的根因） |
| 热循环 | 无 Dictionary/Variant/String；scratch 为 `thread_local` 复用 |
| 零工作 | `should_run=false` → DCSystem 零 slice |

预算目标（合同 §5）：标准图 400 部队 p95 ≤ 0.5 ms；合成 100k 格/2048 部队/4096 交战段 ≤ 2 ms。

实测（本机 `/O2` 独立 exe）：

| 基准 | 改前 | 改后 |
| --- | --- | --- |
| 2400 格 / 400 部队 / 64 交战 / 60 日 | p95 2.82 ms（采购 1.87 ms） | **p95 0.27 ms**（采购 0.043 ms），avg 0.23 ms |
| 100000 格 / 2048 / 4096 | 每日 ~700 ms，且第 1 日**无法结束**（事件表死循环） | 可跑完；前 5 日均值 12.4 ms（第 1 日 ~24 ms 为冷启动），30 日 **7.6 ms**，p95 随时间下降 |

100k 尚未达到 2 ms：剩余大头是 `consumption`（~2.1 ms，每持有者 × 每兵种 × 6 类的需求/消耗计算）、采购第 1 日的 ~23 ms（`build_market_csr` + 首次接触全量数组的冷缓存，之后每日约 1 ms）、以及缓存未热时的 `engagements` / `wars`。

## 8. 存档：PKMI v1

外层（桥）`MILB` 包装：`u32 magic 0x4d494c42, u32 version 2, u32 core_size, core bytes,
u64 sequence, u64 last_step_day, u64 receipt_cursor, u32 n, n × pending intent 行`；v2 行尾追加
`u64 target_handle, u32 target_signature, u32 opcode`（Economy 回执匹配用）。v1 仍可读（无 opcode 的 Economy 行
靠超时失败）。Economy 事件游标、强制步进日、渲染选择不保存，恢复后重置。

核心 PKMI（`military_core_save.cpp`）：小端定宽字段；头 `magic "PKMI", version 1, catalog_hash, seed,
cell_count, width, height, last_day`；随后 `(u16 id, u32 len)` 分段：Counters 1、Pending 2、Lots 3、
Training 4、Armies 5、PathArena 6（压缩）、Templates 7、Stocks 8、Shipments 9、Engagements 10、Wars 11、
Truces 12、Reparations 13、BattleLog 14、Areas 15、Policies 16、CellStates 17、Controller 18（稀疏）、
Ledger 19、Events 20、Ai 21、End 0xFFFF。未知段跳过。

Restore 先解到临时实例并校验（catalog hash、地形尺寸、lot/army 引用），全部通过才交换；派生结构
（格索引、威胁场、市场场、cell_state 索引、free list、army cache）在恢复后重建。

Catalog identity 与官营建筑桥接：`MilitaryCore::catalog_hash()`（`military_core.cpp`）把
`state_buildings[]` 的 `id / economy_building_id / role / tier / unlock_bit / capacity /
fort_bonus / training_speed / upkeep / build_days / materials` 全部混入，因此军事目录指向的
经济建筑类型（稠密 `building_type_ids` 索引）参与存档身份：`encode()` 把头部的
`_catalog.hash` 写入 PKMI，`restore()` 在分配任何内存之前先比对
`saved_hash != _catalog.hash`，不一致直接 `pkmi_catalog_mismatch`。GDScript 侧
`MilitaryCatalogCompiler._catalog_hash()` 是另一份摘要，同样混入该列，但
`configure_military` 的返回值以原生重算的 hash 为准：前者只做内容变更播报，
后者才是读档闸门。两侧目录由同一份内容编译时 `economy_building_id` 稳定；
任一侧新增/重命名建筑以致稠密顺序变化都会改变原生 hash，从而让旧档以
`pkmi_catalog_mismatch` 被拒绝，而不是静默错配。

Provider 顺序（`game_save_coordinator.gd`）：`dynamic_world → environment → pkcm → world_clock →
simulation_runtime → pkcn → **pkmi** → pkef → ecp2 → pkgp → pkfg → pkai → journal → pktr → pkid → pkar →
pknr → player_session`。`pkmi` 在 `REQUIRED_SECTIONS` 与 `OPTIONAL_PROVIDER_SECTIONS` 中都有：
旧存档缺失时 `pkmi_absent_migration` 以空军事状态继续；存档含 PKMI 而运行时无 Military API 时以
`pkmi_runtime_unavailable` 拒绝；schema 只接受 1。恢复成功后重新 `arm_ai`。读档时 Military 先由
`map_generator.prepare_economy_save_restore_runtime()` 在 PKCN 恢复、Economy
目录配置完成后配置军事系统并推地形，随后 provider 恢复 PKMI（仍在 ECP2 之前）。
`finalize_save_restore_runtime()` 在 ECP2 恢复后更新聚落地形，通过 facade 的 PKMI
保留/恢复路径保存军队和命令；此时不能再次 configure，否则会抹掉刚恢复的状态。
该顺序由完整存读档测试覆盖。

## 9. 渲染契约

`get_military_render_snapshot(after_revision)`：`revision / control_revision / front_revision` 都未变时返回
`unchanged=true`。否则返回 SoA：

- `armies{handle, owner_slot, cell, prev_cell, moved_day, unit_class(主导兵种类), headcount, flags,
  composition_offsets, composition_unit, composition_weight, heading_q16, attack_seq, hit_seq}`，
  flags：bit0 低补给(<0.5)、bit1 缺粮(<0.25)、bit2 欠饷(<0.6)、bit3 低士气(<0.4)、bit4 交战、bit5 撤退；
  `composition_offsets` 长度为 `army_count+1`，每军最多三项，按聚合人数权重降序、同权重 dense unit id
  升序；`heading_q16` 当前恒 0（东），`attack_seq/hit_seq` 当前恒 0，仅作为 M3 视觉 cue 入口；
- `engagements{cell_a, cell_b, progress_q16, attacker_slot, battle}`；
- `convoys{current_cell, dest_cell(仅驻军目的地), country_slot, risk_q16}`；
- `controller_cells / controller_slots`（稀疏）、`front_edges`（key = cell*6+dir）、`front_progress`
  （该边有活跃交战时为 `progress_q16` 映射到 0..254，否则 255）、
  `selected_army`、`selected_area_cells`（所选部队区域任务格）、`selected_path_cells`（剩余行军路径）。
  选择由 `set_military_render_selection(army)`（facade `set_render_selection`）设置，0 = 无，变化时 bump revision。

成功推进一个新游戏日后，桥层无条件 bump `render_revision`。不能只在
`report.idle == 0` 或当日有 intent 时推进：命令应用、部队合并/拆分、补给、士气、训练和兵种配比都可能静默改变，
而 `unchanged` 早退会让地图长期停留旧值。同一日内的重复查询仍按 revision 早退。

`MilitaryRenderFeed` 每帧最多一次轮询（由 `WorldRuntimeHost` 的 `military_map_layers.poll_snapshot()` 驱动），
按三个 revision 瀑布决定重建；每次 poll 还会重新解析玩家国家 slot，以支持初始 `-1` 后的晚绑定。
`{ok:false}` 或 `{available:false}` 快照按 fail-closed 处理：不推进 accepted revision，清空残留
token/区域/战线/交战/车队/占领/路线几何，并隐藏全部军事层。
`MilitaryMapLayers` 由 host 在 renderer bind 后创建（headless/mobile 不创建），
`PlayerGame` 在 world_ready 时 `configure()`。

| z | 层 | shader |
| --- | --- | --- |
| 5 | `MilitaryOccupationLayer` 占领斜纹 | `military_occupation_hatch` |
| 6 | `MilitaryAreaLayer` 区域虚线 | `military_area_dash` |
| 8 | `MilitaryFrontLayer` 战线 | `military_front_ribbon` |
| 9 | `MilitaryBattleLayer` 交战环 | `military_battle_ring` |
| 9 | `MilitaryConvoyLayer` 车队 | `military_convoy` |
| 10 | `MilitaryArmyTokenLayer` 部队棋子（纸片 + formation） | `military_paper_sticker` / `military_formation_sprite` |
| 11 | `MilitaryRouteLayer` 行军路线（`_draw` 折线） | — |

视觉契约详见 `docs/plans/military-formation-visual.md`。M0 harness
`tests/military/military_formation_visual_harness.tscn` 验证四动作原型、1–5 成员和三级 LOD；
M2 harness `tests/military/military_formation_token_harness.tscn` 直接驱动生产 token layer，
覆盖四原型、1–5 成员、三级 LOD、攻击/受击 cue 和纸片 fallback。
M1 在 `get_military_render_snapshot()` 增加只读配比/朝向/cue 字段；M2 在
`MilitaryArmyTokenLayer` 内增加 formation MultiMesh backend。zoom <0.35 保留纸片按格聚合，
0.35–0.70 为单代表 sprite，>0.70 为 1–5 成员；阈值使用 0.33/0.37/0.68/0.72 滞回。
纸片与 formation 共享 2,048 实例上限，未知 dense unit、非法 CSR、旧 DLL、缺 atlas/shader、
迷雾内可见外国部队、未绑定玩家 slot（`-1`）和预算不足都整军回退纸片，绝不画半编队。
独立视觉 fixture 需要全行展示时必须显式启用 test-only allow-all 开关。formation 锚点复用原纸片的位置插值；
composition/heading 使用独立 `army_formation_signature`；纸片与 formation 签名都包含 handle/owner，
避免 native 压缩行后复用旧部队身份。聚合缓存签名包含完整 headcount、owner、flags 和 handle。
cue 只增量更新成员 custom data；handle 变化会清除旧的一次性动作和位置插值。
渲染层不得估计编成、写回军事状态或把 native `unit_class` 当成视觉原型。

当前工作区的 debug GDExtension 二进制尚未批准重建，因此生产实机在替换 DLL 前仍只观察到旧字段并
安全回退纸片。M2 源码和合成 feed 测试已覆盖新字段消费。

全部低于 `FogOfWarLayer` z12。迷雾门控：`MapData.visible_arr` 非空且 host `is_fog_of_war_enabled()` 时，
外国部队、交战标记、车队只在可见格显示；己方部队总显示。占领/战线不做迷雾过滤（战线位置视为公开）。

### 9.1 地图拾取与军务档案（右栏部队页 / 战线页）

地图点击的语义：`MapCamera.tile_tapped` → `PlayerController._on_tile_tapped`。部队指令模式
（`_military_order_mode`）仍然吃掉点击；否则先给拾取一次机会，未命中才 `select_cell()`。

拾取由图层自己完成（几何归图层，UI 只消费结果）：

| 层 | 入口 | 规则 |
| --- | --- | --- |
| `MilitaryArmyTokenLayer` | `pick_army_at(world, radius)` | 半径默认 `token_world_size×0.62`；聚合 LOD 退化为「该格兵力最多的一支」；同格重叠时取兵力大者；`_vis=0` 不参与 |
| `MilitaryFrontLayer` | `pick_edge_at(world, tolerance)` | 候选是本格+6 邻格的 42 条边，容差 `0.42×hex`（远小于半格）；key 规范化为 `min(cell,neighbor)*6+dir` |
| `MilitaryMapLayers` | `pick_at_world(world)` | 优先级部队 → 战线 → 空；`feed.ok=false` 时一律不拾取 |

选中态：部队 → `token_layer.set_selected_cell(cell)` + `facade.set_render_selection(handle)`
（区域 z6 / 路线 z11）；战线 → `front_layer.set_selected_edge(key)`。战线选中只换颜色不换宽度：
ribbon 的线宽是 shader uniform，per-edge 加宽会被裁掉。

`front_sector(edge_key, 96)` 从被点的边沿共享格 BFS 展开一段连续战线（≤96 边 / ≤128 格），
返回交战段、交战方（扇区格归属）、双方在场兵力与每侧的部队句柄（≤24/侧，供对阵表汇总
攻防/士气/补给），以及锚点格；`cell → 边` 的集合按 `front_snapshot_revision` 缓存，
只在档案打开且前线变化时重建（>6 ms 时降级为单格）。

右栏军务档案：在 `InspectorPanel` 的 `DetailShell` 里新增一块与对象详情同级的内容页
（`scenes/ui/military_dossier.tscn`），因此自动继承面板变宽、地块目录列、开合动效与 ESC。
模型由 `CountryViewModel.military_dossier_context()` + `MilitaryViewModel.army_dossier()` /
`front_dossier()` 生成；`GameUIManager` 只负责开合、定位与动作转发，并在 `notify_committed_day`
里以 200 ms 合并窗口刷新。**不新增原生查询**：拾取读已缓存的 `MilitaryRenderFeed`，
数据只走 `facade.army()`（单支部队）与既有的目录缓存。

契约与页面规格见 `docs/ui/military-dossier.md`；验证脚本
`tests/military/military_map_pick_test.gd`、`tests/military/military_dossier_test.gd`、
`tests/qa/military_dossier_screenshot_qa.gd`。

### 9.2 议和窗口（`MilitaryPeaceWindow`）

议和不再是国家卷宗里的内联卡，而是一块**独立的左停靠非模态窗口**：不暂停、不压暗，地图保持可见，
窗口开着时地图左键就是「交割选格」。规格见 `docs/ui/military-peace-window.md`。

```text
战争页/总览「议和」，或外交章（战事档案 / 交战国档案）的「议和」
  → CountryPanel.peace_negotiation_requested（军事章与外交章共用同一个出口）
  → GameUIManager.open_military_peace(war_id)
      ├ close_country_panel() + _suppress_ui_for_dispatch()（隐藏右栏与悬浮工具条）
      ├ CountryViewModel.build("military") → MilitaryPeaceViewModel.peace_model(war_id, draft)
      └ MilitaryPeaceWindow.open()：候选描边 + 镜头对准第一块候选
地图左键 → PlayerController.select_cell()
      ├ 议和窗口开着 → GameUIManager.handle_peace_map_cell(cell)（清高亮之前拦截）
      └ 否则照旧（先军务档案拾取，再开地块档案）
递交 → PlayerController.request_command("military.peace.propose")
      → GameUIManager._on_peace_submit_requested → 回执喂 set_command_result()
```

要点：

- 条款编码只有一处：`MilitaryPeaceViewModel.peace_terms()` → `white` / 每格一条 `cede` / `annex` /
  `lump_sum` / `installments`（`n` 夹 2..12），金额是游戏货币单位，由桥侧 `money_from_units` 换算。
- 价格与接受倾向只认原生 `evaluate_military_peace`（`price / willing / gap / band`）；没有评估器时
  退化为「至少 2 分/格」的本地估价并标注为估算。
- 候选格 = 控制快照里控制者是我方、所有权属敌国的格（`MilitaryViewModel.ceded_cells()` 同一条规则）；
  没勾选的占领格会随和约自动交还（原生 `execute_treaty` 语义），窗口把它写在条款区底部。
- 地图点击在 `select_cell()` 里、`clear_cell_highlights()` **之前**被拦截，否则每次点选都会把草案高亮
  擦掉；窗口开着时 `_on_tile_tapped` 跳过 `military_map_pick()`，避免部队棋子抢走交割点击。
- 两层高亮：`WorldRoot/PeaceCandidateSet`（低饱和候选描边）与 `WorldRoot/PeaceDraftSet`（朱红草稿），
  由 `PlayerController.highlight_peace_candidates/draft()` 驱动，窗口关闭时一起清空。
- 日刷新与命令回执都经 `_refresh_peace_window()`（`invalidate_cache(COUNTRY_DIRTY_MILITARY)` → 重建模型 →
  `refresh_model`），窗口内部 200 ms 合并且只写值、不重建节点。
- 已知缺口：原生快照不导出 `score_parts`（四项拆解有则显示）与 `last_rejected_offer_day`
  （30 日冷却目前按会话内「递交日 + 30」推算）；`peace.respond` 仍无 pending offer 状态。

验证：`tests/military/military_peace_window_test.gd`（视图模型 + 窗口 + 启动卡 + 控制器高亮契约）、
`tests/qa/military_peace_window_screenshot_qa.gd`（1280/1920 两种 UI 宽 × 白和平/已点选）。

## 10. 事件 40–47 与 report 计数

| type | 名称 | payload schema | 字段（当前代码） |
| --- | --- | --- | --- |
| 40 | WAR_DECLARED | 20 | i0 攻方 slot，i1 守方 slot，i2 war_id |
| 41 | WAR_ENDED | 20 | i0 1=和约 / 2=吞并，i1 割地格数，i2 war_id，value 赔款 |
| 42 | BATTLE_RESOLVED | 21 | cell 边中点，i0 胜方，i1 负方，i2 progress_q16，value 负方损失；每日 ≤ 64 |
| 43 | CELL_CONTROL_CHANGED | 22 | i0 新 controller，i1 旧 controller，i2 owner，i3 聚落等级；每日 ≤ 128 |
| 44 | ARMY_DESTROYED | 21 | i0 胜方，i1 被歼方，value 人数 |
| 45 | COUNTRY_ANNEXED | 23 | i0 受害国**句柄**，i1 吞并国**句柄**，i2 格数 |
| 46 | CONVOY_INTERCEPTED | 24 | i0 截获方，i1 被截方，i2 shipment id，value 货值 |
| 47 | LEVY_APPLIED | 25 | cell，i0 国家 slot，i1 国家句柄，value 人数 |

`MilitaryDailySystem.forward_military_events()` 以游标轮询 `poll_military_events` 并按
`GameplayEventBus.publish_events_batch` 的 SoA 布局转发（source = `SOURCE_MILITARY` = 5，与
`TriggerCatalog.SOURCE_MILITARY` 一致；1 NATIVE / 2 GDSCRIPT / 3 DEBUG / 4 EFFECT 已占用。TriggerRuntime
按 source 维护独立游标，source_count 64；entity_id = i0）。

Report（`get_military_report` / `run_military_daily`）：`military_day_ms(day_ms)`、`armies_active`、
`armies_moving`、`engagements_active`、`wars_active`、`soldiers_total`、`astar_expansions`、`area_evals`、
`threat_field_cells`、`convoys_due`、`convoy_hops`、`front_edges_touched`、`vision_patch_cells`（恒 0）、
`event_coalesced`、`reconcile_delta`、`intents_emitted`、`idle`、`state_cache_repairs`、
`state_ledger_unmapped`、`state_role_mismatch`；`get_military_report` 另含 ledger、
`pending_intents`、`sequence_cursor`、`render_revision`、`state_hash`。核心另计 `cells_captured`、
`armies_retreated`、`casualties_annihilation`、`battles_fought`（未导出到字典）。
后三个 `state_*` 是 §6.2 的缓存诊断：`state_cache_repairs` 只在缓存与昨日账本不符时增加，
因此一个正常推进的日子应当恒为 0。

## 11. 验证

```text
godot --headless --path Project/project-keynes -s res://tests/military/military_native_binding_test.gd
```

- `runtime_military_self_test()`：`MilitaryCore::self_test` + 桥侧目录缩放、op 表、和议条款编码。
- `run_military_bench({cells, armies, engagements, days})` → `avg_ms / p95_ms / max_ms`；测试断言
  2400 格/400 部队 p95 ≤ 0.5 ms、100k/2048/4096 p95 ≤ 2 ms。
- 改 C++ 后需重建 GDExtension；shader 改动 headless 无法验证。
- 目前 `tests/military/` 只有上面一个文件；设计稿 §24 的 `tests/military_runtime_bench.gd`、守恒/吞并/AI soak
  测试尚不存在。

## 12. 已知缺口 / v1 简化

1. **`military_core_selftest.cpp` 尚未落地**（A3 编写中）：`self_test` / `bench` 在 `military_core.h:554-556`
   声明、`world_ext_military.cpp:2550/2617` 调用，提交前必须存在，否则链接失败。
2. ~~Economy 回执不回流~~（已修复，§5.1）。剩余近似：trace OFF 时按请求量视为成功；trace 被驱逐/读边界长期
   繁忙时行靠 8 日超时失败（可能低估入伍）。
3. ~~`SPEND_CASH` 同步收取~~（已改为 D+1，§5）；仍是桥侧财政托管调用而非 Country 命令（Country 无扣现金
   opcode）。~~state build 材料按每单位 1 money 估价~~ 已移除：官营建造的建材与现金由
   `COMMAND_TREASURY_SPONSORED_BUILD` 真实结算（§5.3），军事侧只保留完成日排期。
4. ~~口粮恒满额~~（已修复，§5.2）；部队（army lot）口粮不回写 Economy，因 cohort 留在家乡格。
5. ~~选择/战线进度恒空~~（已修复，§9）；`risk_q16` 仍是路线成本代理而非拦截概率。`MilitaryAreaLayer` 需由
   UI 调 `set_render_selection` 才显示。
6. 恢复后 `_front_edges` 清空，直到下一次控制/交战变化才逐格重建（`military_core_save.cpp:1462`）。
7. 交战 Plan 阶段未并行；部队视野补丁未实现（`vision_patch_cells` 恒 0，部队不是视野源）。
8. `get_military_cell_snapshot` 的 `observer` 被忽略（未按迷雾过滤）；统帅恒为空位。
9. 占领不切换 Economy 税收/补贴归属；controller 只在 Military。
10. 人员模型：士兵不随部队移动，无随军/客籍消费、无 `ArmyPersonnelStore`（设计 §5.7、PKEC v59 未实现）。
11. 海运只有 `EMBARKED` stance 的损耗豁免，无运兵科技门控与航行逻辑。
12. ~~注释漂移（worker 推进 military）~~：已更正为主线程 `run_military_daily` + host 整图补跑。
13. ~~`GameplayEventBus` payload 注释不一致~~：已按 §10 原生字段更正。LEVY 原生事件未填
    `payload_schema`（=0），由 `GameplayEventBus.military_payload_schema()` 回填 25。
14. 设计稿 §22 写 PKCN v14 承载 `cell_controller` 与 PKEC v59；当前 controller 在 PKMI，PKCN/PKEC 未为军事升版。
15. 部队编队视觉 M1/M2 源码已接入：快照提供前三兵种 CSR、`heading_q16`、`attack_seq/hit_seq`，
    `MilitaryArmyTokenLayer` 已支持纸片/formation 双 backend、1–5 成员和三档 LOD。当前明确缺口是：
    工作区 DLL 尚未重建、M2 尚未做真实世界视口裁剪/长时间 soak、cue 生产者仍未实现（M3）。
16. 官营建筑已收敛到 Economy 单一账本（§5.3、§6.2）。剩余缺口：`MILITARY_INTENT_STATE_DEMOLISH` 目前
    只有消费者没有生产者——`MilitaryCore` 没有拆除请求队列，玩家拆除走「Economy facade 直接 queue →
    军事 submit `MCMD_STATE_DEMOLISH`」的直连路径，AI 也还不会主动拆官营建筑。若 AI 需要拆，要补
    `_demolish_requests` 与 `step_day` 里的 drain。
17. opcode 35 只走专用 `queue_treasury_sponsored_demolish` 入口，**不在** `submit_commands` 的批量白名单里
    （白名单上界仍是 `COMMAND_TREASURY_SPONSORED_BUILD`，与 opcode 16 同构地走专用入口）。
    `submit_commands` 若收到 35 会被拒为 `unsupported_opcode`，这是刻意的：拆除必须先在经济侧落实。
