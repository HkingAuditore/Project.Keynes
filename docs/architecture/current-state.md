# 当前运行状态

本页只写运行架构的现状。单个功能的现状与验证记录见 [feature-status.md](feature-status.md)。

## 十二域

经济上游冷启动仍在 `NativeEconomyRuntime` 内实现：多层派生投入进入同一格的
确定性队列，访问标记阻止循环回边；取样时由企业需求 EMA 重建空货架替代品的
冻结种子，并按真实投入槽活动约束数量。没有增加脚本模拟、持久列、API 或调度阶段。
定向回归覆盖零工坊/零采掘场、多层需求、首座实际产出、三账守恒及 scalar/worker
逐日全哈希。运行证据与完整回归限制见
[上游冷启动验证](../cpp-dots-runtime/upstream-demand-cold-start-2026-11-10.md)。

每日表在 `native_simulation_host.cpp` 的 modules 表，域内函数在 `native_simulation_stage_<domain>.cpp`。表顺序与 `runtime_domain_stage_order()` 由 `static_assert` 核对。

| 域 | 真正写入者与边界 | 对拍情况 |
| --- | --- | --- |
| INPUT_CAPTURE | Host 冻结输入清单与哈希 | 无双算 |
| CLIMATE | RuntimeClimateAuthority；plan/commit 在模块循环**之前**完成，表内只登记结果 | ACTIVE 关闭完整输出哈希 |
| COUNTRY | RuntimeCountryPodAuthority；`NativeCountryRuntime` 保留初始化、查询和适配，国家 dense 状态包含政治体制与能力位 | parity 钩子仍被调用；缺同日参考时报 uncompared |
| TRIGGER_INPUT | Trigger POD；ACK 等待等列出的原因可软完成 | ACTIVE 抑制旧 run_daily |
| IDEOLOGY | Ideology POD；首次快照未发布等列出的原因可软完成 | parity 默认关闭 |
| EFFECT | Effect POD 与 intent/ACK；同日重访幂等 | 影子推进只在 SHADOW 分支 |
| MODIFIER | Modifier POD；部分授权时仍可内嵌 Effect | 不走 SHADOW 管线 |
| GAMEPLAY_EFFECT | Host 解码、去重，排入 Events/Ideology 命令 | 无双算 |
| ECONOMY | StageOps 调度 `NativeEconomyRuntime` 的真实计算；POD_ACTIVE 时绑定 OwnedState | 默认 ACTIVE_ONLY；显式 ACTIVE_WITH_PARITY 才跑影子 |
| EVENTS | RuntimeEventsAuthority 写事件日志与消费者游标 | 沿用 `events_probe_enabled`，名称含 probe 但用于生产 |
| VISUAL | Host 产生刷新意图，`publish_day` 排序去重；实际显示归 Godot | 无双算 |
| COMMIT | 记完成位，检查请求域全部完成，由外层发布 | 无双算 |

政治体制不增加新的每日域。`NativeCountryRuntime` 保存 `regime_id` 与
`capability_bits`，`CountryReadView` 将能力位冻结进 Economy epoch；政治页面只聚合
Country 体制快照与现有 Ideology 快照。`treasury_construction` 在报价和结算两处均由
Economy 原生门控，UI 隐藏入口只负责展示体验。

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
| vision | 主线程 | 读地形/领地/研究信号与已提交的玩家部队位置，写可见性，并提交 Country 观察意图；部队使用低于城市的移动视野预算 |
| visual_delivery | 主线程 | 消费已发布的脏类别补丁，写显示与 MapData |
| climate_writeback | 主线程 | 只消费已提交的 Climate 快照写回 slot/MapData |

这些推进者与日表“同日对齐”的实验开关 `PK_EXPERIMENT_EXTERNAL_DAY_ALIGNMENT` 只供测试子类读取；产品默认未切换，见 [migration.md](migration.md) 的推迟项。

## 跨模块交接

- **已提交视图（9 条，`check_committed_views.py`）**：Economy←Climate、Trigger←Events、Ideology←Modifier、Modifier←Effect、Ideology←Economy 意见、年报←Ideology、Country AI←Economy、年报←Country、Family 指标←Economy 意见。所有者复制已提交数据，带 generation/day，消费处检查游标单调。
- **经济意见到思想系统**：后台与原生 inline 在每日执行边界直接复制经济最后提交的意见，并按目标日固定到已有意见缓存；同日继续计算不能换成之后发布的意见。首份意见尚未提交时仍保留未就绪状态，现有测试专用输入也经过同一按日固定。主线程发布延迟不再决定思想点数，SHADOW 仍使用其成对的参考输入。完整读档安装成功时清除旧日期缓存及按发布编号查询的输入接收记录，同一世界执行器重启保留未完成日输入。诊断中的意见日期与版本来自同一条实际接收记录。
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

后台与原生 inline 共用 `native_simulation_host_executor_boundary.cpp` 的保存服务：冻结已接收的命令，丢弃可重新生成的未来环境帧，构建 PKSR，并明确发布成功或失败。保存、停止和时钟控制通过 `runtime_control_wakeup.h` 在后台等待所用的锁内发布条件，防止检查条件与进入等待之间漏收通知。后台在日循环的空闲边界保存；inline 在 request/poll 时尝试取得同一把日边界锁，并安装相同的执行上下文。inline 的未完成日标记跨调用保留，整日提交后才清除，因此不能在两次续算调用之间捕获半完成状态。

`_executor_pending_commands` 与未完成日的 `_executor_day_environment` 属于世界，由当前执行器独占访问。后台和 inline 共用待执行列表及冻结输入；停止不销毁它们。`native_simulation_host_lifecycle.cpp` 负责执行器启动：同一世界保持 ACTIVE 且授权范围不变时，只更换执行器，保留业务状态、日期、编号、确认结果、发布游标和日内继续位置；不重新初始化已提交的域。未完成日标记也随后台/inline 交接，不能在替换执行器后保存半日状态。

新世界与重启分开：已启动过的 `DCWorldExt` 再 `configure_country` 时，先要求执行器确实退出，并在私有候选对象中验证配置；失败保留旧世界。成功后解除经济对旧 OwnedState 的借用，替换 Host 并重新连接适配层，Country 对象地址保持稳定，区分新旧世界的 session epoch 继续递增，新的 Host 回复协议编号也从旧值继续增加；同一世界重启则保持编号。`make_new_world_host` 在替换前重新验证并安装已配置的 Modifier、Effect、Trigger、Ideology 规则定义，以及 Modifier 稳定键到内部编号的映射；不复制旧实例、命令、确认记录、输入、意见、快照或读取进度。主线程的规则对象也清理旧实例和读取进度，使新世界从较小编号发布的结果可立即接收；同一世界重启不执行这项清理。Effect 与 Modifier 的状态清理分别集中在 `effect_runtime_lifecycle.cpp` 和 `modifier_runtime_lifecycle.cpp`。旧世界日期及授权证明不会进入新世界。读档则安装存档中的世界状态。未来命令及需要重试的命令不重新挤入实时入口。保存格式仍为 PKSR v5；待执行命令超过原有 4096 条容量时明确拒绝保存并保留现场全部命令。

同一世界重新捕获 Country 输入时，已由原生运行时接管的国家状态取自最近一次已提交副本，不覆盖成冻结的旧同步副本；重复发布同一内容身份的目录不清除请求及确认记录。新的国家配置会经过上述新世界入口。CLOCK_WAIT 在等待锁内复查停止、保存、暂停和速度变化；通知早于实际等待也不会遗失。

正式保存入口按 `worker_day_inflight` 和 `inline_day_pending` 判断 inline 的真实日边界，不能把无后台线程更新的 RUNNING 状态当成仍在计算。inline 返回前同步首次提交授予的归属，关闭 Country/Economy 的旧同步写入口。正式策略重启由 `world_runtime_lifecycle.gd` 等待 `simulation_executor_exited` 后再捕获并启动，失败会传回设置入口。`get_runtime_thread_report` 提供 `executor_serial_only` 检查调用线程的并行配置。重复启动及 inline+SHADOW 冲突在修改执行方式、并行设置、绑定或消耗待恢复存档之前拒绝。

复用对象读档时，已经验证的 PKSR 且旧执行器退出后，地图输入按待恢复存档的日期检查，独立暂存新输入；旧世界的日期与满队列不阻止这一步。启动用暂存输入重新建立队列，不读取旧队列的未来帧。没有待恢复存档或执行器仍运行时，原日期、递增编号和容量检查继续生效。

| 域 | 段 / 版本 | provider | 恢复依赖 |
| --- | --- | --- | --- |
| climate | CLM2 v9 | environment | — |
| country | PKCN v15 | country | environment |
| military | PKMI v6 | country | country |
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

- ECP2：职业移动冷却、经济发布记忆与上一日意见快照（OSOA 块 8）、资源小数余量与逐格日期（块 9）、生产周期 EMA/累计耗时（块 11）、实物收入累计列 `epoch_in_kind_income`（块 12）、采样降雨边沿与冻结门槛（OSOA4 块 13）、Track-B 分摊投资审查的待续格子表 `_track_b_investment_cells_pending`（CADENCE_STATE 段尾，上游合并后补）。
- PKMI4：lot 原始链、槽位 payload、free-list 与 generation，包括仍挂链的 inactive 行；
  section 23 保存玩家自动探路任务（任务行、选点、seen/visited/blocked、观察点、日期、返程）。
  trail、冻结 explored、fog 和派生索引不入档，恢复时重建。`military_for_each_lot_ordered`
  不能全局过滤 inactive 行，变更型查找依赖原链复用槽位。
- PKSR5：已接纳未执行的 Economy POD 命令与回执（EQC1）、Trigger 传输请求/ACK/发布游标与 Host 请求编号（TCQ1）、军事事件转发进度（MDJ1）。
- CLM2 v9：权威 extras 与天气初始化状态。

## 哈希与验证范围

- `simulation_state_hash` 每天只把日期混入前值，不是业务状态摘要；`runtime_day_waterfall.h` 记耗时与完成掩码，也不是状态链。气候 ACTIVE 的 `compute_hashes=false`。
- 整体经济哈希还读同步国家对象与 Modifier 的 ECONOMY 序列；`get_country_state_hash` 取同步对象，`get_country_report` 取 worker 快照副本，二者不是同一提交边界。
- 黄金场景（`tests/runtime/golden_*`，`check_golden_determinism.py`）覆盖开局账目、整体经济、七个 worker 域投影、Country 追加链及表外推进者（军事、资源恢复、家族、人物、视野）。这是投影，不是完整十二域状态。
- 2026-11-11 起按用户快速调参的决定，撤掉提交的黄金和七份 intent 基线；同一个二进制重复运行逐字段一致，不改行为的重构则用仓库外临时候选做改前/改后对照。场景内的守恒、存读档和同日提交检查保留；调参后不需重录基线。此前重录记录属于历史证据，见 migration。
- 保存续跑（`check_committed_replay.py --checkpoint --trace`、`check_replay_matrix.py`）：不中断、重放、保存不中断、另进程读档四条轨迹逐日比较，读档后至少八日。默认矩阵 4 个场景：save1、calendar5、multicountry5、military20；`--military-annual` 单跑 military365（真实年度自动存档，受时序影响不稳定，见 migration 已知问题）；`--full` 另加 save2/5/9 与 mixed5；`--annual` 保存第 365 日；`--annual-neighbors` 保存 364/366（手动档）。
- 未覆盖：其他种子与平台、实际占领与战斗（测试地图路径不可达，只有合成占领自测）、任意 worker 日内命令位置、真实浏览器 Web 导出、图形长跑。

## 规模（2026-11-11）

- 长度检查扫描 1018 个源码文件，0 违规；C++ 依赖 522 引用键（399 债务键），`header_exposed=519`、`total=2181`；域对 30。
- `DCWorldExt` 的 646 个脚本方法分在 15 个模块绑定文件，`world_ext_bind_methods.cpp` 只顺序调用各模块；`world_ext.h` 的绑定声明按同样顺序分段，头文件 4050 行。数据归属和实现不变，入口与模块文件由 `tools/ci/world_ext_binding_modules.json` 登记，`check_world_ext_bindings.py` 核对归属；阶段 1 的验证见 [feature-status.md](feature-status.md)。
- 阶段 2 第 1–2 步已登记 15 模块的脚本访问目录，`check_script_native_access.py` 冻结现有越界并接入本地/PR 护栏；没有迁移调用或替换接口探测。匹配规则见 [feature-guides.md](feature-guides.md)，本轮数量和验证见 [feature-status.md](feature-status.md)。
- `world_runtime_host.gd` 2943 行；`map_generator.gd` 22563 行（超限债务，未拆）。
- `economy_runtime.cpp` 2000 行、`economy_runtime.h` 2408 行（内部头另 5 个，均 ≤2000）；`native_simulation_host.h` 2147 行、`.cpp` 481 行；`country_runtime.cpp` 11463 行（超限债务，未拆）。
