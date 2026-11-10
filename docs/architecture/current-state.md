# 当前运行状态

## 降雪散点显示（2026-11-09）

逐地块雪幕仍由 WeatherLayer 的 MultiMesh 和已发布 weather_lut 驱动。
weather_cell_curtain.gdshader 将格心附近抖动改为全格散点，按 patch/layer
旋转查找坐标，逐雪花独立摆动，并以 3×3 邻格补画跨格雪花；形状距离转回
世界方向，保留俯视椭圆及三层大小/速度/密度。移动/Web 同样保留完整散点，
不再缩小位置随机范围。没有新增模拟、存档或上传状态；性能验证项目 shader 同步。

Godot 4.6.2 / RTX4080 隔离 GPU 检查：五种宏变体、三层深度的 15 组空间
频谱集中峰值降为旧版的 0.004–0.174 倍；五组连续帧确认动画仍推进。
3×3 与 5×5 邻域在三层、三个时刻（含 12006 秒）逐像素一致，45 项通过；
五种变体实际天气 LUT/flag 雪幕路径均出图。上述 50 项在 OpenGL Compatibility
与 D3D12/Mobile 各通过一次。隔离脚本和对照图位于
.codex-temp/snow-scatter-20261109/。尚未覆盖实际手机、浏览器及正式会话长时间画面。

## 山地高度与烘焙起伏（2026-11-09）

原生 base 生成在 `world_ext_generate.cpp` 冻结山脊基底，按陆地 p99 分配统一增量比例；
必要时基底以海平面为锚线性缩放。只有顶部约 1% 使用导数连续的软收尾，
不再按地图尺寸混入旧的逐点指数压缩。`ridge_budget_scale`、`ridge_base_scale`、
`ridge_tail_cells`、`ridge_land_cells`、`ridge_elevation_cap` 由 base/full 结果包返回。
这一步改变权威初始 elevation，后续水文和气候仍在既有生成管线中重算。

terrain-index/fused geometry/visual tile 共同读取可选 `cell_landform` U8 SoA。
山地/高峰/火山将邻格起伏与两圈区域起伏合并，山地/高峰起伏下限为 0.055/0.080；
高原内部减弱细纹，陡坎仍由邻格高差驱动。三中心插值保持地貌权重连续。
主脊振幅系数 0.55、波长 2.4 hex、尖化指数 2.2、倍频增益 0.40；
汇流谷深/谷壁系数为 1.4/5.0，保留只降不升与陆地不低于水面的约束。
这些烘焙细节写视觉高度 buffer，不新增 DataCore slot 或存档列。
缺少 landform 的旧调用可继续按邻格起伏烘焙，非空错误长度明确 fallback。

Windows Debug/Release DLL 为 `dots_ext_relief_v1`，正式项目已切换加载路径。
定向测试 `tests/world/mountain_relief_bake_test.gd` 61 项通过，覆盖三尺寸、
三海平面、确定性、软收尾比例、平原/高原保护、经度周期与刻谷约束；
原生生成接口 32 项、地形边界索引 11 项通过。具体画面待玩家新生成地图验收。
扩大分块检查的 `visual_tile_native_bake_test.gd` 在地图边界尺寸不变性断言失败，
旧 `dots_ext_military_demand_v7` 与新 DLL 均为 ref=-0.146431/got=-0.103137，
未改该既有断言或将完整分块检查计为通过。
仅在临时夹具跳过上述既有失败后，其余分块测试通过，覆盖载荷、确定性、
分辨率一致性、边界距离、细节、运河补丁和 horizon 重采样；正式测试文件保持原样。

2026-11-09 天气云方块修复：低/中及移动/Web的廉价值噪声改为无循环的三角格点
梯度噪声，旋转第二层并取消零线折叠；保留分档/双相位。均匀天气GPU回归：
旧方格轮廓反例失败，新LOW/MID/Web通过；7天气变体连续性检查通过。证据见
[云Shader分档验证的后续修复](../cpp-dots-runtime/cloud-weather-shader-quality-2026-11-09.md#后续天气云方块修复)。

2026-11-09 云 Shader 分档：云影桌面 128×64 / 256×128 / 512×256，移动/Web
128×64 / 192×96 / 256×128；单相位云形采样2/4/6次。天气云LOW主云、MID加卷云、
HIGH加低雾；移动/Web均编译掉解析噪声栈，高档光照不再重复计算邻域云密度。
17个shader变体连续性检查119项与正式节点切档39项通过。RTX4080桌面GL、1600×900
隔离天气云HIGH GPU平均4.5855→0.6353ms；真机移动和浏览器未验。详见
[云Shader分档验证](../cpp-dots-runtime/cloud-weather-shader-quality-2026-11-09.md)。

2026-11-09 云影/天气云视觉平流：删除全图累计位移，改用局地风 + 24 秒双相位有界
位移和零权重重置；新旧风仅在显示端按天气提交间隔混合。天气云经 HexRenderer 的
信号连接复用云影已上传风 LUT，中云/卷云/低雾均接入，Web 裁剪卷云移除固定东向漂移。
Godot 4.6.2 / OpenGL Compatibility 隔离渲染探针：云影、桌面天气云、Web 裁剪天气云
共 21 项通过，周期边界和 12006 秒换风起点的最大像素变化为 1/255。反例仅恢复
风乘总时间，12006 秒换风变化达 0.768627，检查按预期失败。三个宿主脚本解析通过；
尚未覆盖正式会话长时间画面、移动设备性能和浏览器实际渲染。机制见
[云影的世界空间连续性](../cpp-dots-runtime/vision-fog-and-borders.md#云影的世界空间连续性)。

核查日期：2026-11-09。本页只写今天源码里是什么样，以及有哪些运行证据；目标方向见 [design.md](design.md)，迁移进度和待办见 [migration.md](migration.md)。代码与本页不符时以代码和可复现的运行结果为准。

范围：正式玩家会话请求 ACTIVE、十二域掩码 `0xFFF`。“请求 ACTIVE”“实际授权”“POD_ACTIVE”是三件不同的事。

2026-11-08 经济平衡：C++仍为唯一结算权威，生存/生活需求评分寄生于既有市场循环。
基本生活采用75%需求均值与25%最弱项；适用且职业正权重的舒适/奢侈需求分别提供
70%→100%与90%→100%的综合分上限。环境需求恰为零时不制造最小需求。
正式失业计划补齐12类生活需求；开局规划已接入真实全局倍率并纠正软投入语义。
没有新增保存列、调度阶段、跨模块写边或第二套评分。数值、运行证据及尚未覆盖的全时代
校准范围见 [经济平衡记录](../cpp-dots-runtime/economy-balance-2026-11-08.md)。

2026-11-09 永昼视觉：共享日照 shader 按当地纬度与当日赤纬取正午高度
`max(10°, 90° - abs(latitude - declination))`，日内时角在 ±70° 内浮动，默认一个游戏年完成两个 Shader 日，按实际游戏日历进度映射，水面高光与实例层同源，GM 手动方向优先。
生产与性能验证项目的日历映射回归各 26 项通过，覆盖 365/360/10 日年历及固定日历时的倍速/帧 delta 独立性。
Shader 日/游戏年比例也已接入 HexRenderer.shader_days_per_game_year；生产/性能验证项目各42项通过，含小数比例跨年和运行时调参。
永昼调参已集中到 HexRenderer 的角度 export；实际 renderer/渲染层传参检查和 GPU uniform 调整检查在 Compatibility、D3D12/Mobile 各 43 项通过。
Godot 4.6.2 的 Compatibility 与 D3D12/Mobile 实际 shader 检查各 23 项通过；
地被桌面/移动/分块档回归 28 项通过。详见 [TOD 光照](../cpp-dots-runtime/vision-fog-and-borders.md#tod-光照)。

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

## GM 界面与事件屏蔽

正式玩家 GM 的 `ui.suppress_popups` 在 Host 设置后通过 `gm_toggle_changed` 同步到
PlayerController 的年度报告、叙事、时代奖励、家族创立和理念抽取流程。所有流程在展示前
拦截，并在开关运行时切换时清理已排队或已锁定的弹窗，恢复由弹窗持有的时钟暂停，避免
“屏蔽事件”仍偶发暂停。时代晋升大典也会只同步基线而不创建暂停演出。
另有 `ui.hide_all_except_gm` 开关，隐藏 HUD、面板、模态层和过场层，只保留 DebugLayer
中的 GM 面板；关闭后恢复切换前的可见性。
GM 总览的时钟诊断还显示 `last_pause_source`、`last_pause_day` 和
`authority_fault_hold`，用于区分 UI 自动暂停与运行时故障保护。
2026-11-09：修正叙事自动确认未持有暂停锁却恢复默认「暂停 / 1倍速」的问题
（截图入口 `_restore_clock:125`）。恢复只消费真实弹窗或读档弹窗登记的
`restore_pending`，并保留其他弹窗忙碌时的延后恢复。验证入口为
`tests/game/narrative_popup_suppression_test.gd`（24 项通过）、
`narrative_event_runtime_test.gd`（36 项通过）和 `gm_runtime_host_test.gd`（PASS）。
GM 屏蔽开关返回补齐实际 `enabled`。未新增时钟或模拟权威；
扩大检查的 `player_controller_contract_test.gd` 仍有既有的逐帧更新约束及两项殖民派遣文案失败，未计为通过。

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

后台与原生 inline 共用 `native_simulation_host_executor_boundary.cpp` 的保存服务：冻结已接收的命令，丢弃可重新生成的未来环境帧，构建 PKSR，并明确发布成功或失败。保存、停止和时钟控制通过 `runtime_control_wakeup.h` 在后台等待所用的锁内发布条件，防止检查条件与进入等待之间漏收通知。后台在日循环的空闲边界保存；inline 在 request/poll 时尝试取得同一把日边界锁，并安装相同的执行上下文。inline 的未完成日标记跨调用保留，整日提交后才清除，因此不能在两次续算调用之间捕获半完成状态。

`_executor_pending_commands` 与未完成日的 `_executor_day_environment` 属于世界，由当前执行器独占访问。后台和 inline 共用待执行列表及冻结输入；停止不销毁它们。`native_simulation_host_lifecycle.cpp` 负责执行器启动：同一世界保持 ACTIVE 且授权范围不变时，只更换执行器，保留业务状态、日期、编号、确认结果、发布游标和日内继续位置；不重新初始化已提交的域。未完成日标记也随后台/inline 交接，不能在替换执行器后保存半日状态。

新世界与重启分开：已启动过的 `DCWorldExt` 再 `configure_country` 时，先要求执行器确实退出，并在私有候选对象中验证配置；失败保留旧世界。成功后解除经济对旧 OwnedState 的借用，替换 Host 并重新连接适配层，Country 对象地址保持稳定，区分新旧世界的 session epoch 继续递增，新的 Host 回复协议编号也从旧值继续增加；同一世界重启则保持编号。`make_new_world_host` 在替换前重新验证并安装已配置的 Modifier、Effect、Trigger、Ideology 规则定义，以及 Modifier 稳定键到内部编号的映射；不复制旧实例、命令、确认记录、输入、意见、快照或读取进度。主线程的规则对象也清理旧实例和读取进度，使新世界从较小编号发布的结果可立即接收；同一世界重启不执行这项清理。Effect 与 Modifier 的状态清理分别集中在 `effect_runtime_lifecycle.cpp` 和 `modifier_runtime_lifecycle.cpp`。旧世界日期及授权证明不会进入新世界。读档则安装存档中的世界状态。未来命令及需要重试的命令不重新挤入实时入口。保存格式仍为 PKSR v5；待执行命令超过原有 4096 条容量时明确拒绝保存并保留现场全部命令。

同一世界重新捕获 Country 输入时，已由原生运行时接管的国家状态取自最近一次已提交副本，不覆盖成冻结的旧同步副本；重复发布同一内容身份的目录不清除请求及确认记录。新的国家配置会经过上述新世界入口。CLOCK_WAIT 在等待锁内复查停止、保存、暂停和速度变化；通知早于实际等待也不会遗失。

正式保存入口按 `worker_day_inflight` 和 `inline_day_pending` 判断 inline 的真实日边界，不能把无后台线程更新的 RUNNING 状态当成仍在计算。inline 返回前同步首次提交授予的归属，关闭 Country/Economy 的旧同步写入口。正式策略重启由 `world_runtime_lifecycle.gd` 等待 `simulation_executor_exited` 后再捕获并启动，失败会传回设置入口。`get_runtime_thread_report` 提供 `executor_serial_only` 检查调用线程的并行配置。重复启动及 inline+SHADOW 冲突在修改执行方式、并行设置、绑定或消耗待恢复存档之前拒绝。

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

## 规模（2026-11-09）

- 护栏扫描 967 个源码文件；C++ 依赖 522 引用键（399 债务键），`header_exposed=519`、`total=2181`；域对 30。
- `world_runtime_host.gd` 2943 行；`map_generator.gd` 22563 行（超限债务，未拆）。
- `economy_runtime.cpp` 2000 行、`economy_runtime.h` 2408 行（内部头另 5 个，均 ≤2000）；`native_simulation_host.h` 2147 行、`.cpp` 481 行；`country_runtime.cpp` 11463 行（超限债务，未拆）。

## 部队指挥 UI（2026-11-08）

已接入固定指挥区、路径/区域草稿、显式确认/取消、停止任务与姿态。部队页为 520 设计像素单页，军事权威与存档不变。输入/接线检查及 1280×720、1920×1080 渲染夹具已验证，未完成实战长时间与触摸/手柄验收；扩展检查的失败与具体契约见 [部队指挥交互](../ui/military-army-controls.md)。

## 军需需求接入市场（2026-11-08）

已接通零库存军需报价、受资金约束的未满足采购预测、D+1 替换命令和 Economy 通用采购需求汇总；商人补货目标、生产规划与投资共享该汇总。预测只传递购买意愿，实际货物/现金仍由原采购结算处理。装备成交桥改传真实商品编号。继续态复用现有命令队列，没有新增存档字段。定向回归覆盖提前生效、撤销/重复/替换、零国库、未来需求 ECP2 保存及十日逐日完整经济哈希一致，并运行原生军事自测。

验证证据：Debug/Release GDExtension 均构建成功；军需定向用例（含完整原生军事自测）与整图 ACTIVE POD 用例通过。相同弓箭营地开局五日累计产量：无军需 12,745，有军需 15,895（GOODS_SCALE）。模块 API、C++ 依赖及 Resolve/Apply 检查均为 0 violations。本轮未跑全量性能/长年测试；行数护栏仍有 14 个未触及的既有脚本超限。殖民与科研采购的旧基线字节断言仍失败，但修复前 `dots_ext_equip_v1` DLL 与本次 DLL 的两份测试输出逐字段完全一致，未更新基线。
