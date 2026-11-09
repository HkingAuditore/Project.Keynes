# 当前运行状态

核查日期：2026-11-05。本页只写今天源码里是什么样，以及有哪些运行证据；目标方向见 [design.md](design.md)，迁移进度和待办见 [migration.md](migration.md)。代码与本页不符时以代码和可复现的运行结果为准。

范围：正式玩家会话请求 ACTIVE、十二域掩码 `0xFFF`。“请求 ACTIVE”“实际授权”“POD_ACTIVE”是三件不同的事。

2026-11-08 经济平衡：C++仍为唯一结算权威，生存/生活需求评分寄生于既有市场循环。
基本生活采用75%需求均值与25%最弱项；适用且职业正权重的舒适/奢侈需求分别提供
70%→100%与90%→100%的综合分上限。环境需求恰为零时不制造最小需求。
正式失业计划补齐12类生活需求；开局规划已接入真实全局倍率并纠正软投入语义。
没有新增保存列、调度阶段、跨模块写边或第二套评分。数值、运行证据及尚未覆盖的全时代
校准范围见 [经济平衡记录](../cpp-dots-runtime/economy-balance-2026-11-08.md)。

## 十二域

每日表在 `native_simulation_host.cpp` 的 modules 表，域内函数在 `native_simulation_stage_<domain>.cpp`。表顺序与 `runtime_domain_stage_order()` 由 `static_assert` 核对。

| 域 | 真正写入者与边界 | 对拍情况 |
| --- | --- | --- |
| INPUT_CAPTURE | Host 冻结输入清单与哈希 | 无双算 |
| CLIMATE | RuntimeClimateAuthority；plan/commit 在模块循环**之前**完成，表内只登记结果 | ACTIVE 关闭完整输出哈希 |
| COUNTRY | RuntimeCountryPodAuthority；`NativeCountryRuntime` 保留初始化、查询和适配 | parity 钩子仍被调用；缺同日参考时报 uncompared |
| TRIGGER_INPUT | Trigger POD；ACK 等待等列出的原因可软完成 | ACTIVE 抑制旧 run_daily |
| IDEOLOGY | Ideology POD；首次快照未发布等列出的原因可软完成 | parity 默认关闭 |
| EFFECT | Effect POD 与 intent/ACK；同日重访幂等 | 影子推进只在 SHADOW 分支 |
| MODIFIER | Modifier POD；部分授权时仍可内嵌 Effect | 不走 SHADOW 管线 |
| GAMEPLAY_EFFECT | Host 解码、去重，排入 Events/Ideology 命令 | 无双算 |
| ECONOMY | StageOps 调度 `NativeEconomyRuntime` 的真实计算；POD_ACTIVE 时绑定 OwnedState | 默认 ACTIVE_ONLY；显式 ACTIVE_WITH_PARITY 才跑影子 |
| EVENTS | RuntimeEventsAuthority 写事件日志与消费者游标 | 沿用 `events_probe_enabled`，名称含 probe 但用于生产 |
| VISUAL | Host 产生刷新意图，`publish_day` 排序去重；实际显示归 Godot | 无双算 |
| COMMIT | 记完成位，检查请求域全部完成，由外层发布 | 无双算 |

非直观的地方：

- 默认请求 `0xFFF` 来自 `world_runtime_host.gd`；Host 的 auto POD 默认 false，正式 PlayerGame 明确设为 true，镜像完整且空闲边界满足后才切换。经济是“原计算实现 + 可切换的数据承载”，不是两份公式二选一。
- 模块表之前有气候实际提交，之后有 Events 补调用、覆盖检查和日故障点。这不是全域原子提交，COMMIT 完成位也不证明每个域都推进了业务状态。
- Ideology 的日内续跑门闩由 `DCWorldExt.ideology_needs_daily_continuation(day)` 提供；`map_generator.gd` 和 `IdeologyRuntimeSystem` 在旧版扩展缺少该绑定时探测回退，分别使用 runtime graph 的硬 pending 和当前 slice 的 `done`，避免保存边界因 DLL 与脚本不同步而中止。

## 十二域以外的推进

登记在 `tools/ci/runtime_advancers.json`（生成 `runtime_external_advancers.h`），登记不拥有调度权。

| 推进者 | 线程 | 读写与交接 |
| --- | --- | --- |
| military | 主线程 | 每帧追赶已提交日期，`facade.run_daily` 同步运行；读 Country/Economy 已提交数据，写军事实体，后续意图走 D+1 |
| natural_resource_recovery | 主线程 | 追赶已提交日期，写资源 slot 与 MapData；与经济自身消耗资源是两个入口 |
| family / person | 执行线程 | 在经济 FAMILY_COMMIT / PERSON_COMMIT 内运行，没有独立日域 |
| vision | 主线程 | 读地形/领地/研究信号，写可见性，并提交 Country 观察意图 |
| visual_delivery | 主线程 | 消费已发布的脏类别补丁，写显示与 MapData |
| climate_writeback | 主线程 | 只消费已提交的 Climate 快照写回 slot/MapData |

这些推进者与日表“同日对齐”的实验开关 `PK_EXPERIMENT_EXTERNAL_DAY_ALIGNMENT` 只供测试子类读取；产品默认未切换，见 [migration.md](migration.md) 的推迟项。

## 跨模块交接

- **已提交视图（9 条，`check_committed_views.py`）**：Economy←Climate、Trigger←Events、Ideology←Modifier、Modifier←Effect、Ideology←Economy 意见、年报←Ideology、Country AI←Economy、年报←Country、Family 指标←Economy 意见。所有者复制已提交数据，带 generation/day，消费处检查游标单调。
- **只读查询**：Economy 读 Country 的 27 种查询经 `CountryReadView`（借用所有者的只读函数表，不保证多次查询共享同一快照）。税率、科技、领土仍在 `capture_country_epoch` 用 `copy_economy_snapshot` 冻结。
- **写入请求**：Economy→Country 的写全部走所有者端口（财政返还/预留/征收、采购、现金与物资转移、科研、国库支出）；`country_writes` 预算为 0，直接调用、别名、成员指针都不能重新引入。
- **请求队列**：Host 通用命令、Country 命令、Economy 命令（含军事 24/30–34）、Trigger 命令共享 `runtime_resolve_contract.h` 的入队与顺序键；Effect→Modifier/Events、Ideology→Modifier 和同步 Effect 批次仍用各自既有协议。请求与保存位置的对照见 [module-boundaries.md](module-boundaries.md#请求与提交)。
- **冻结输入**：`runtime_freeze_contract.h` 的 `RuntimeFrozenInputVersion` 登记 session、day、generation、命令水位和 committed/in-flight；Climate、Country、Economy 已登记。Climate 仍在 day plan 之前完成输入捕获和提交。
- **未迁移的读边**：Ideology←Country（同一指针可发布 plan 预览）、Country←Effect 身份/完成查询（含已接受未安装的 upsert）、Economy/Family←Effect/Modifier、Military←Country/Economy（主线程 digest 与即时财政 helper 并存）、Climate←Modifier/Economy。30 个域对的逐项处置在 `tools/ci/cross_domain_inventory.json`。

## 软完成（仍保留的兼容债）

| 路径 | 现状 |
| --- | --- |
| Ideology 首个意见/国家快照未发布、未配置 | 保留首次装配兼容；不发伪 ACK，ready=false |
| Trigger ACK barrier / retry / stale / rejected、未配置/未启动 | 保留列出的原策略，不制造新 ACK |
| Effect 同日已提交重访 | 幂等重访；遇 drain/catchup 错误停车，不再宣布完成 |
| Country/Economy peer 等待 | stall、continuation_pending 与超时故障保留；部分旧注释仍称 soft，实际已不完成 |
| Modifier 上游未授权、SHADOW/OFF、Web 回退 | 按原授权策略保留 |

Ideology 的 invalid/shape invalid 与任意 opinion 前缀已不再软完成。保留原因清单由 `check_resolve_apply.py` 核对，新增原因不能静默加入。

## 存档

完整存档 PKSV 由 `game_save_coordinator.gd` 统一等待安全边界后保存；脚本侧 provider 登记在 `world_state_modules.gd`，C++ 段契约在 `tools/ci/cpp_save_section_contracts.json`。开发期不兼容旧档：旧版本明确拒绝，不静默填默认值。

| 域 | 段 / 版本 | provider | 恢复依赖 |
| --- | --- | --- | --- |
| climate | CLM2 v9 | environment | — |
| country | PKCN v14 | country | environment |
| military | PKMI v2 | country | country |
| effect | PKEF v14 | rules | military |
| economy | ECP2 schema 60 | economy | country、effect |
| family | 在 ECP2 内 | economy | economy |
| technology | 在 PKCN 内 | country | country |
| modifier | PKMD v3 | rules | effect |
| trigger | PKTR v6 | history | economy |
| ideology | PKID v14 | rules | trigger、modifier、economy |
| host | PKSR v5 | simulation_runtime | environment、country、economy |
| annual | PKAR v1 | history | ideology |

provider 的 manifest 版本、段内字节版本、内容身份是三层不同的数，不能互相比较。

继续态里容易漏的字段（每项都曾造成读档后分叉，已修复）：

- ECP2：职业移动冷却、经济发布记忆与上一日意见快照（OSOA 块 8）、资源小数余量与逐格日期（块 9）、生产周期 EMA/累计耗时（块 11）、实物收入累计列 `epoch_in_kind_income`（块 12）、Track-B 分摊投资审查的待续格子表 `_track_b_investment_cells_pending`（CADENCE_STATE 段尾，上游合并后补）。
- PKMI2：lot 原始链、槽位 payload、free-list 与 generation，包括仍挂链的 inactive 行。`military_for_each_lot_ordered` 不能全局过滤 inactive 行，变更型查找依赖原链复用槽位。
- PKSR5：已接纳未执行的 Economy POD 命令与回执（EQC1）、Trigger 传输请求/ACK/发布游标与 Host 请求编号（TCQ1）、军事事件转发进度（MDJ1）。
- CLM2 v9：权威 extras 与天气初始化状态。

## 哈希与验证范围

- `simulation_state_hash` 每天只把日期混入前值，不是业务状态摘要；`runtime_day_waterfall.h` 记耗时与完成掩码，也不是状态链。气候 ACTIVE 的 `compute_hashes=false`。
- 整体经济哈希还读同步国家对象与 Modifier 的 ECONOMY 序列；`get_country_state_hash` 取同步对象，`get_country_report` 取 worker 快照副本，二者不是同一提交边界。
- 黄金五链（`tests/runtime/golden_*`，`check_golden_determinism.py`）：v1 开局账目、v2 整体经济、v3 七个 worker 域投影、v4 Country 追加链、v5 表外推进者（军事政策与资源恢复）。末日 domains 摘要 `ccccb169…2291`。这是投影，不是完整十二域状态。2026-11-06 合并上游 c849f255（军事、建造/投资/采购/仓储改动）后重录 v2–v5：v1 账目链 `2242b251` 不变；改变的是 v2 整体经济哈希、v3 中 EVENTS/MODIFIER/TRIGGER_INPUT 三域、v4 COUNTRY、v5 MILITARY；CLIMATE/IDEOLOGY/EFFECT/ECONOMY 和 v5 其余域不变。旧值见合并提交的第一父提交。
- 保存续跑（`check_committed_replay.py --checkpoint --trace`、`check_replay_matrix.py`）：不中断、重放、保存不中断、另进程读档四条轨迹逐日比较，读档后至少八日。默认矩阵 4 个场景：save1、calendar5、multicountry5、military20；`--military-annual` 单跑 military365（真实年度自动存档，受时序影响不稳定，见 migration 已知问题）；`--full` 另加 save2/5/9 与 mixed5；`--annual` 保存第 365 日；`--annual-neighbors` 保存 364/366（手动档）。
- 未覆盖：其他种子与平台、实际占领与战斗（测试地图路径不可达，只有合成占领自测）、任意 worker 日内命令位置、真实浏览器 Web 导出、图形长跑。

## 规模（2026-11-05）

- 护栏扫描 942 个源码文件；C++ 依赖 522 引用键（399 债务键），`header_exposed=519`、`total=2181`；域对 30。
- `world_runtime_host.gd` 2955 行；`map_generator.gd` 22547 行（超限债务，未拆）。
- `economy_runtime.cpp` 1975 行、`economy_runtime.h` 2359 行（内部头另 5 个，均 ≤2000）；`native_simulation_host.h` 2154 行、`.cpp` 480 行；`country_runtime.cpp` 11463 行（超限债务，未拆）。

## 部队指挥 UI（2026-11-08）

已接入固定指挥区、路径/区域草稿、显式确认/取消、停止任务与姿态。部队页为 520 设计像素单页，军事权威与存档不变。输入/接线检查及 1280×720、1920×1080 渲染夹具已验证，未完成实战长时间与触摸/手柄验收；扩展检查的失败与具体契约见 [部队指挥交互](../ui/military-army-controls.md)。

## 军需需求接入市场（2026-11-08）

已接通零库存军需报价、受资金约束的未满足采购预测、D+1 替换命令和 Economy 通用采购需求汇总；商人补货目标、生产规划与投资共享该汇总。预测只传递购买意愿，实际货物/现金仍由原采购结算处理。装备成交桥改传真实商品编号。继续态复用现有命令队列，没有新增存档字段。定向回归覆盖提前生效、撤销/重复/替换、零国库、未来需求 ECP2 保存及十日逐日完整经济哈希一致，并运行原生军事自测。

验证证据：Debug/Release GDExtension 均构建成功；军需定向用例（含完整原生军事自测）与整图 ACTIVE POD 用例通过。相同弓箭营地开局五日累计产量：无军需 12,745，有军需 15,895（GOODS_SCALE）。模块 API、C++ 依赖及 Resolve/Apply 检查均为 0 violations。本轮未跑全量性能/长年测试；行数护栏仍有 14 个未触及的既有脚本超限。殖民与科研采购的旧基线字节断言仍失败，但修复前 `dots_ext_equip_v1` DLL 与本次 DLL 的两份测试输出逐字段完全一致，未更新基线。
