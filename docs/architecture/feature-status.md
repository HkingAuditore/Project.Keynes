# 专项现状与验证记录

按功能记录最近一次改动后的现状、验证证据和未覆盖范围；带日期的条目写在这里。
运行架构的现状（十二域、跨模块交接、存档、哈希）在 [current-state.md](current-state.md)，本页不是它的替代。

## 国库收支滚动窗口（2026-11-10）

国库顶栏悬停卡与经济卷宗总览不再把「最近一次结算」冒充当天流水。
`EconomyFiscalHistory` 现在同时保存逐已提交日国库现金与按财政 `sample_day`
去重的结算事件；展示层默认显示近 30 日日均，总览可切换近 7 日/近 30 日。
窗口内税种、补贴和非税支出先按真实结算事件汇总，净额再用国库现金首尾差校准，
差额单列为「其他国库变动」。历史不足时按实际覆盖天数折算；不足两个现金样本时
回退到最近一次结算，不补零、不伪造整月。折线保留逐日结算读数（未结算日沿用上次），
用于观察波动；
顶栏悬停与经济卷宗共用 `EconomyDossierViewModel.cashflow_from_history()`。

验证：`tests/economy/economy_fiscal_history_rolling_test.gd` 覆盖结算去重、无结算日、
7/30 日边界、历史不足、未归类现金变化和净额与国库差一致；`tests/ui/hud_status_card_test.gd`
通过。`tests/economy/economy_dossier_view_model_test.gd` 的滚动窗口与切换断言通过，
整页套件仍有一项既有的跨章区段滚动断言失败：断言硬编码要求滚动量大于 100，
而本次空产业台账下页面最多只能滚到 74；跨章跳转本身已落到产业章投资段。
C++、存档格式与存档字段未改。

## 派遣来源目录、进度与筹备缩编（2026-11-10）

已实现：目标入口直接按出发地分组列当地家族，使用地点与家族的组合身份；
顶部派遣按钮打开全国进行中队伍，按日事件、控制器绑定与命令回执刷新。
筹备详情保留当前队伍并显示三项实际物资进度、状态和采购阻碍；取消/召回放在
详情底部。紧凑视口保留两栏，极窄视口才上下排列；顶部空间不足时缩紧留白与字号，
派遣按钮保留文字入口，时代名回到宽视口显示。没有增加逐帧轮询或 UI 模拟权威。

Economy 筹备重验取 `min(计划人数, 当前当地可派人数)`，保留最后族人/商人与军人
排除规则；缩编后重算采购目标及进度分母。已有成交托管与在途采购续接保留，
后续只补实际缺口。状态沿用既有远征列，存档布局、跨域财政契约和 cadence 不变。
契约与回归入口见 [家族开拓运行时](../cpp-dots-runtime/family-colonization-runtime.md)。

验证：Windows/Godot 4.6.2，Debug `dots_ext_dispatch_v3` 与 Release
`dots_ext_dispatch_v2` 完成构建，人数缩减定向回归均零失败，实际出发后人口/货币/物资
误差均为零。来源目录/刷新/取消/顶部入口及 workbench 回归通过；1280×720、
2560×1080、1024×600 与移动 QA 档执行带渲染检查，含 125% UI 缩放和 10 倍速度。
全项目编辑器脚本编译无 Parse Error / Failed to load script / SCRIPT ERROR。
模块 API 与 C++ 依赖检查零违规。

共享工作区随后将正式 Debug 库切到 `dots_ext_supply_chain_v4`，在该映射下复跑人数
缩减专项仍为零失败。全项目编译时遇到同时新增经济历史脚本的两处数组元素类型推断
错误，只补 `Dictionary` 注解后编译通过；其视图模型测试的章节跳转断言仍失败，未改
相关导航逻辑，不把该测试报告为通过。

完整家族旧套件仍有 12 项失败；修改前 `dots_ext_army_explore_v14` 在同一内容与脚本下
也有全部这 12 项，另加本次新增缩编用例的 3 项失败；修复后这 3 项通过，没有新增失败。
旧失败涉及 worker authority、旧存档断言、开工包内容/落成、效果奖励等，不能宣称完整套件
已通过。PlayerController 旧契约测试仍有未改动的 `no frame polling` 失败。
渲染进程另有既有 FMOD 调试器注册/退出日志；截图与 UI 断言正常完成。
日志、基线对照与截图在 `.codex-temp/dispatch-20261110/`；UI 反模式扫描已人工复核
本次新增行，未将全库机械命中数当作本次缺陷数。

## 军事维护实物化（PKMI v6，2026-11-11）

军事维护从“现金账单”改为“实物采购与消耗”：需求 → 国库付款给商人 → 物资交付与运输 →
库存消耗 → 维修满足率 → 装备完好度或建筑失修。详见
`docs/cpp-dots-runtime/military-runtime.md` §5.4 与 `docs/plans/military-physical-maintenance.md`。

- Military 新增 `MilitaryMaintenanceRow`（按国家/地块/建筑类型与持有者/兵种分组）、
  `run_maintenance`、`get_military_maintenance_snapshot`；固定点余量 `acc_q32` 与 5 日窗口进存档。
- 采购走 opcode 37（`COMMAND_MILITARY_PURCHASE`）与 38/39 回执；`queue_purchase` 只登记订单，
  `settle_purchase` 才入库/建车队/记账，订单身份进 PKMI section 24。
- 预算顺序固定为 军饷预占 → 维护份额 → 一般采购，三者共用同一份冻结国库快照。
- 经济侧新增 `kind == 3` 显式跳过（私营建筑维护不得为军事建筑买单）。
- 验证：原生自检全绿（1500 日 AI soak `reconcile_max=0`）；三份维护验收用例
  （snapshot / flow / conservation）均 0 failures；种子 1812289715 的 60×40 世界跑到第 5500 日
  零错误、账目恒等式为 0。

## 军事维护回执与经济审计（2026-11-10）

`SPEND_CASH` 的 D+1 兼容路径仍调用 Country 财政 reserve/collect：先扣后加，
国库现金净变化为零。军事桥不再将返回额登记为货币销毁，经济也不再暂存这类
跨 epoch burn；正式 cohort burn 命令和零误差守恒故障保护保留。维护费真实终端
支出尚未接入，不能把回执金额当作已销毁现金。C++ 权威、周期和存档布局不变。
定向回归见 `tests/economy/military_deferred_cash_conservation_test.gd`。
Windows/Godot 4.6.2：旧 DLL 稳定复现 `money_error=1000`；修复后 Debug/Release
各通过 37 项检查，含待回执恢复、九日续跑和第十日真实 cohort burn。
正式 Debug 加载的 `dots_ext_supply_chain_v2` 亦通过该回归；Release 加载
`dots_ext_cash_audit_v1`。经济 cadence、parity（26 项）、merchant debt 回归通过；
市场综合测试 246 项中唯一失败为旧的 2x 产出断言与当前 1.5x 配置不符，
旧 DLL 同样失败。未宣称已恢复玩家当前被 fatal 锁住的进程或完整重放第 5447 日。
模块 API 检查与定向 diff 检查通过；UTF-8 模式的依赖检查在并行修改的
`economy_runtime_colonization.cpp` 报 FamilyMembershipEdge 7>6、总量 2182>2181，
本次未修改该文件或放宽基线。验证日志在 `.codex-temp/military_deferred_*.log`、
`.codex-temp/cash_audit_*.log`，构建日志在 `.codex-temp/military_cash_build_*.log`。

## DCWorldExt 模块绑定拆分（2026-11-11）

阶段 1 已将 646 条绑定按定义文件归属搬到 15 个 `world_ext_bind_*.cpp`：core 49、runtime 81、climate 75、economy 112、country 94、military 32、effect 37、modifier 37、ideology 30、trigger 24、events 13、generation 18、bake_encoders 7、visual 21、demo 16。绑定语句和模块内顺序逐字核对不变，说明注释随绑定移动。入口按该顺序调用模块函数，仅保留原来的 `using namespace godot;`，没有常量、枚举或信号等其他登记。绑定声明全部在原 public 区按模块分段，没有跳过项；非绑定声明、数据成员、访问级别及实现代码不变。清理搬移留下的空行后，头文件 4080 → 4050 行。

清单新增 `bind_file`，定义扫描排除绑定文件；新护栏检查文件归属、入口调用次数及缺失/多余文件，已加入本地回归和 PR 检查。8 个权威 skill 及镜像同步了绑定位置，country/modifier 的 PowerShell 检查改为扫描所有模块绑定文件。正式 `--sync` 同步也消除了这些 skill 的既有镜像差异，随后用 `check_skill_mirrors.py --write-baseline` 删除 23 条过期记录（49 → 26）；只收紧镜像基线，没有修改长度、依赖、游戏结果或方法列表基线。

已验证：macOS arm64 debug、release 串行构建成功；两份日志各有 14 条未修改文件的警告，没有本次改动文件的警告。16 个静态脚本逐个运行全部通过（架构测试 37 项、回归证据测试 9 项），清单默认及 `--audit` 均为 646 条、0 problems；`--json --refs` 输出与原清单除新增字段外一致。Godot 4.6.3 导出 646 个方法，`cmp` 与指定拆分前基线逐字节相同，SHA-256 为 `dab184126aadbd58fd5e2659397fd89729de581bf1583022b07bb874996c39a8`。构建生成的两个已追踪 macOS 程序库保留在工作区；运行检查日志在 `/tmp/keynes-binding-split-validation`。

额外检查：release 程序库的 8 项实际加载/运行检查全过；黄金主链与表外链各重复 3 轮，全部与既有基线一致，没有首个差异。默认回归 exit=0：86 个脚本、固定气候存档、10 日保存续跑、save1/calendar5/multicountry5/military20 回放矩阵、自动保存和真实第 365 日保存均通过，所有继续轨迹没有首个差异。未验证 Windows、Web、其他架构及图形界面，两个 PowerShell 脚本未在 Windows 实跑；未实施阶段 2/3，也没有改变数据归属或脚本接口。

## 大文件拆分（2026-11-11 至 11-13）

完成 G1–G5、C1–C7，规则并入 `development-guide.md`「机械搬迁与拆分」，计划文档已删除。GDScript 超标文件都降到 1700 行以下（`map_generator.gd` 22331 → 1672，期间删掉 GDScript 气候计算回退），最大协作者 `ideology_workspace_presentation.gd` 1782 行。C++：`runtime_climate_passes.cpp` 1212、`world_ext_climate_async.cpp` 1788、`country_runtime.cpp` 1018、`effect_runtime.cpp` 1542、`ideology_runtime.cpp` 415，`economy_runtime_building_investment_candidates.cpp` 2000。C8（其余 3000–4000 行的 C++ 文件）改到哪个拆哪个。

已验证：debug/release 构建与全部静态护栏通过；绑定方法 dump 改前改后一致（653 个）；黄金主链与外部链对拆前候选逐字段一致。搬迁中发现 `player_controller` 协作者把 4 个 player_view 存档键和 4 处日志文本误加了 `host.` 前缀，已修，扫描规则写入开发指南。

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

原生 base 生成在 `world_ext_generate_base.cpp` 冻结山脊基底，按陆地 p99 分配统一增量比例；
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

核查日期：2026-11-10。本页只写今天源码里是什么样，以及有哪些运行证据；目标方向见 [design.md](design.md)，迁移进度和待办见 [migration.md](migration.md)。代码与本页不符时以代码和可复现的运行结果为准。

范围：正式玩家会话请求 ACTIVE、十二域掩码 `0xFFF`。“请求 ACTIVE”“实际授权”“POD_ACTIVE”是三件不同的事。

19 处文件增长超限已按职责抽出 22 个脚本助手与 4 个 C++ 文件。
默认长度限制未修改，已有登记只收紧；新文件没有超限豁免。
诊断耗时桶与排版诊断标记分别只有 `WorldDayCostProbe`、`GameHudLayout` 持有；
原生世界、命令序号、保存段、生成算法、编译缓存与日推进所有者不变。
具体实现位置和回调边界见 [源文件职责拆分](source-module-splits.md)。
后续修复补齐后台/内联开局保存、未完成经济结算时的保存拒绝、正式读档继续、军事完整段比较、
军事建筑外观与植被节点释放。十组显示检查、时代推进服务与理念抽取流程已纳入默认回归。
固定气候样本以当前内容重建，保留旧内容拒绝测试。
OSOA4 块 13 保存已采样降雨标记与冻结门槛；旧 OSOA3 不兼容。

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

## 部队指挥 UI（2026-11-10）

已接入固定指挥区、路径/区域/探路草稿、显式确认/取消、停止任务与姿态。探路只生成中心 +
半径的选点并提交 `army.explore`，不调用路径预览；Native 任务、战斗暂停/恢复、返程与
PKMI v6 已落地（section 23 探路 / 24 采购订单 / 25 维护行），Host 只合并 explored-only trail。部队页为 520 设计像素单页，
军事权威与存档边界不变。输入/接线、原生探路集成、视野、存档契约及 1280/1920/520/21:9
真实渲染夹具已验证；100k 军事日 p95 与征兵 smoke fixture 仍未达标，详见
[部队自动探路计划](../plans/army-auto-exploration-plan.md) 与
[部队指挥交互](../ui/military-army-controls.md)。

## 军事长期失败清理（2026-11-13）

军事短测试已跟随当前接口和目录：render snapshot 替身改用 `render_snapshot`，兵种与科技
断言读取当前编译目录，纸片 fallback 允许新兵种，军队拆编在目标格没有 soldier cohort 时
使用随军 lane 自己的 signature。12 个专项测试中 9 个通过；原生自测和小图性能通过。
仍有三类未收口：100k 军事基准 p95 超过 2ms、活世界 smoke 的 Economy/Military 读数在
worker 延迟下不同步且中立空格 station 回流未读到、装备科技生产链一致性测试的 17 个内容
缺口。内容缺口保留给军事目录与科技树决策，不改基线。

## 军需需求接入市场（2026-11-08）

已接通零库存军需报价、受资金约束的未满足采购预测、D+1 替换命令和 Economy 通用采购需求汇总；商人补货目标、生产规划与投资共享该汇总。预测只传递购买意愿，实际货物/现金仍由原采购结算处理。装备成交桥改传真实商品编号。继续态复用现有命令队列，没有新增存档字段。定向回归覆盖提前生效、撤销/重复/替换、零国库、未来需求 ECP2 保存及十日逐日完整经济哈希一致，并运行原生军事自测。

验证证据：Debug/Release GDExtension 均构建成功；军需定向用例（含完整原生军事自测）与整图 ACTIVE POD 用例通过。相同弓箭营地开局五日累计产量：无军需 12,745，有军需 15,895（GOODS_SCALE）。模块 API、C++ 依赖及 Resolve/Apply 检查均为 0 violations。本轮未跑全量性能/长年测试；行数护栏仍有 14 个未触及的既有脚本超限。殖民与科研采购的旧基线字节断言仍失败，但修复前 `dots_ext_equip_v1` DLL 与本次 DLL 的两份测试输出逐字段完全一致，未更新基线。

## 脚本侧原生访问护栏（2026-11-11）

阶段 2 第 1–2 步完成。核实 `Project/project-keynes/scripts/` 下登记目录全部存在；`events` 继续使用 `scripts/narrative`，依据是模块地图的 Events 脚本入口与该目录内的 narrative 服务/流程文件。`script_dirs` 使用相对 `Project/project-keynes` 的路径（因此写成 `scripts/...`），`demo` 登记为单文件 `scripts/main.gd`。本轮未改任何 `.gd`、C++ 或 `Project/perf-validation` 文件，也未迁移调用点。

新增 `check_script_native_access.py`，复用 `world_ext_bindings.py` 的绑定清单；扫描正式项目中的全部 `.gd`，排除 `tests/`、`addons/`、`.godot/`，并冻结 `tmp/` 中已跟踪脚本的现状。候选包括点调用和 `has_method`/`call`/`callv`/`call_deferred`/`Callable` 的绑定名字符串。最终接收者规则、facade 规则和词法限制见 [feature-guides.md](feature-guides.md) 的“脚本原生访问边界”。

首次基线为 49 个文件、102 个文件—模块组合、918 处越界。`--write-baseline` 只在首次生成或减少时写入；已有基线遇到增加仍失败。报告如下：

```text
script native access report (cross-module references):
core: 11 files, 217 references
   109 Project/project-keynes/scripts/geography/map_generator.gd
    40 Project/project-keynes/scripts/geography/hex_cell.gd
    24 Project/project-keynes/scripts/main.gd
    20 Project/project-keynes/scripts/rendering/map_baker.gd
    10 Project/project-keynes/tmp/family_baseline_test.gd
runtime: 6 files, 105 references
    87 Project/project-keynes/scripts/geography/map_generator.gd
    10 Project/project-keynes/scripts/geography/native_loading_tasks.gd
     3 Project/project-keynes/tmp/manual2_research_replay.gd
     2 Project/project-keynes/scripts/rendering/bakers/atlas_encoders.gd
     2 Project/project-keynes/scripts/rendering/map_baker.gd
climate: 2 files, 159 references
   131 Project/project-keynes/scripts/geography/map_generator.gd
    28 Project/project-keynes/scripts/rendering/map_baker.gd
economy: 14 files, 115 references
    61 Project/project-keynes/tmp/family_baseline_test.gd
    10 Project/project-keynes/scripts/geography/map_generator.gd
     7 Project/project-keynes/scripts/simulation/systems/economy_daily_system.gd
     7 Project/project-keynes/scripts/ui/economy_data_recorder.gd
     7 Project/project-keynes/tmp/preview_reference_both.gd
country: 15 files, 66 references
    24 Project/project-keynes/scripts/geography/map_generator.gd
    11 Project/project-keynes/scripts/game/game_save_coordinator.gd
     4 Project/project-keynes/scripts/game/save_modules/history_state.gd
     3 Project/project-keynes/scripts/game/runtime_forensics.gd
     3 Project/project-keynes/tmp/manual2_research_audit.gd
military: 3 files, 5 references
     2 Project/project-keynes/scripts/rendering/military_map_layers.gd
     2 Project/project-keynes/scripts/rendering/military_render_feed.gd
     1 Project/project-keynes/scripts/geography/map_generator.gd
effect: 15 files, 96 references
    22 Project/project-keynes/scripts/simulation/systems/effect_runtime_system.gd
    20 Project/project-keynes/scripts/game/world_runtime_daily_adapter_part2.gd
    12 Project/project-keynes/scripts/geography/map_generator.gd
     7 Project/project-keynes/scripts/game/game_save_coordinator.gd
     6 Project/project-keynes/scripts/country/country_facade.gd
modifier: 5 files, 16 references
     6 Project/project-keynes/scripts/game/save_modules/rules_state.gd
     6 Project/project-keynes/scripts/geography/map_generator.gd
     2 Project/project-keynes/scripts/simulation/systems/modifier_daily_system.gd
     1 Project/project-keynes/tmp/family_baseline_test.gd
     1 Project/project-keynes/tmp/modifier_catalog_probe.gd
ideology: 6 files, 29 references
    10 Project/project-keynes/scripts/geography/map_generator.gd
     6 Project/project-keynes/scripts/game/save_modules/rules_state.gd
     4 Project/project-keynes/scripts/game/world_runtime_daily_adapter_part2.gd
     4 Project/project-keynes/scripts/simulation/systems/ideology_runtime_system.gd
     3 Project/project-keynes/scripts/game/game_save_coordinator.gd
trigger: 8 files, 41 references
    11 Project/project-keynes/scripts/game/world_runtime_daily_adapter_part2.gd
     7 Project/project-keynes/tmp/technology_save_audit.gd
     6 Project/project-keynes/scripts/game/save_modules/rules_state.gd
     6 Project/project-keynes/tmp/manual2_research_audit.gd
     4 Project/project-keynes/scripts/simulation/systems/trigger_daily_system.gd
events: 4 files, 34 references
    20 Project/project-keynes/scripts/data_core/gameplay_event_bus.gd
    10 Project/project-keynes/scripts/geography/map_generator.gd
     3 Project/project-keynes/scripts/simulation/systems/gameplay_effect_system.gd
     1 Project/project-keynes/tmp/family_baseline_test.gd
generation: 4 files, 10 references
     4 Project/project-keynes/scripts/rendering/bakers/terrain_baker.gd
     2 Project/project-keynes/scripts/rendering/bakers/climate_baker.gd
     2 Project/project-keynes/scripts/rendering/bakers/terrain_index_baker.gd
     2 Project/project-keynes/scripts/rendering/map_baker.gd
bake_encoders: 3 files, 5 references
     2 Project/project-keynes/scripts/rendering/hex_renderer.gd
     2 Project/project-keynes/scripts/rendering/map_baker.gd
     1 Project/project-keynes/scripts/geography/native_loading_tasks.gd
visual: 5 files, 17 references
     8 Project/project-keynes/scripts/simulation/systems/dynamic_visual_atlas_upload_system.gd
     3 Project/project-keynes/scripts/game/world_runtime_visual_adapter.gd
     2 Project/project-keynes/scripts/economy/economy_facade.gd
     2 Project/project-keynes/scripts/geography/native_loading_tasks.gd
     2 Project/project-keynes/scripts/simulation/systems/bio_occupancy_daily_system.gd
demo: 1 files, 3 references
     3 Project/project-keynes/scripts/ui/tile_data_recorder.gd
script native access guard: 603 scripts; 1408 native references; 49 files / 102 file-module pairs / 918 cross-module references; 0 problems
```

`--audit` 的精度统计为：2018 个候选；规则 a 命中 1216、未命中 802；规则 b 命中 1113、未命中 905；a-only 295、b-only 192、两者均命中 921、两者均未命中 610；计入样例和排除样例各 10 条已由命令完整打印。该统计是词法护栏的精度参考，不是运行时调用图。

验证：`check_script_native_access.py`、`world_ext_bindings.py`、`check_world_ext_bindings.py` 均通过；`test_architecture_guards.py` 为 43 项全过；其余现有架构护栏通过。除 `check_skill_mirrors.py` 仍报告既有的 1 条可收紧 baseline（`project-keynes-ideology-runtime/references/pitfalls-and-build.md`）外，其余现有架构护栏通过；本轮未修改其他护栏 baseline。

精度样例（`--audit` 原样抽取）：

```text
counted samples (10):
  Project/project-keynes/scripts/annual/annual_report_session.gd:90 [country/call; receiver=_ext; a=1 b=0; outside=0] _ext.mark_annual_report_presented(report_id)
  Project/project-keynes/scripts/game/game_save_coordinator.gd:552 [country/string; receiver=country_ext; a=0 b=1; outside=1] if country_ext != null and country_ext.has_method("get_country_peer_protocol_status"):
  Project/project-keynes/scripts/annual/annual_report_session.gd:21 [country/string; receiver=_ext; a=1 b=1; outside=0] if _ext == null or not _ext.has_method("configure_annual_reports") or handle == 0:
  Project/project-keynes/scripts/country/country_facade.gd:627 [effect/call; receiver=_world_ext; a=1 b=0; outside=1] return _world_ext.bind_era_reward_player_country(handle) if _configured \
  Project/project-keynes/scripts/game/game_save_coordinator.gd:553 [country/call; receiver=country_ext; a=0 b=1; outside=1] out["country_peer"] = country_ext.get_country_peer_protocol_status()
  Project/project-keynes/scripts/annual/annual_report_session.gd:27 [country/call; receiver=_ext; a=1 b=1; outside=0] var result: Dictionary = _ext.configure_annual_reports(handle, clock.days_per_year(),
  Project/project-keynes/scripts/country/country_facade.gd:628 [effect/string; receiver=_world_ext; a=1 b=0; outside=1] and _world_ext.has_method("bind_era_reward_player_country") else {
  Project/project-keynes/scripts/game/game_save_coordinator.gd:555 [country/string; receiver=None; a=0 b=1; outside=1] out["country_should_run"] = bool(country_ext.country_should_run(int(out["day"])))
  Project/project-keynes/scripts/country/country_ai_facade.gd:26 [country/string; receiver=_world_ext; a=1 b=1; outside=0] if _world_ext == null or not _world_ext.has_method("configure_country_ai"):
  Project/project-keynes/scripts/country/country_facade.gd:646 [country/call; receiver=_world_ext; a=1 b=0; outside=0] return _world_ext.get_country_report() if _configured else {"configured": false}
excluded samples (10):
  Project/project-keynes/scripts/annual/annual_report_flow.gd:55 [country/string; receiver=_host; a=0 b=0; outside=0] if _host != null and _host.has_method("mark_annual_report_presented"):
  Project/project-keynes/scripts/annual/annual_report_flow.gd:56 [country/call; receiver=_host; a=0 b=0; outside=0] _host.mark_annual_report_presented(id)
  Project/project-keynes/scripts/data_core/command_buffer.gd:63 [core/call; receiver=_world; a=0 b=0; outside=0] var occupied_idx: int = _world.entity_count() + _pending_create_count
  Project/project-keynes/scripts/data_core/dc_system.gd:98 [core/call; receiver=w; a=0 b=0; outside=0] var c: int = int(w.component_id(comp_name))
  Project/project-keynes/scripts/data_core/view_adapter.gd:252 [core/string; receiver=_world; a=0 b=0; outside=0] if _world.has_method("entity_count"):
  Project/project-keynes/scripts/data_core/world.gd:217 [core/string; receiver=None; a=0 b=0; outside=0] "entity_count": _entity_count,
  Project/project-keynes/scripts/diagnostics/daily_simulation_breakdown.gd:95 [core/call; receiver=_dcc_w; a=0 b=0; outside=1] if _dcc_w != null and _dcc_w.is_bound():
  Project/project-keynes/scripts/diagnostics/daily_simulation_breakdown.gd:265 [core/call; receiver=_dc_w; a=0 b=0; outside=1] if _dc_w != null and _dc_w.is_bound():
  Project/project-keynes/scripts/era/era_advancement_service.gd:178 [economy/string; receiver=_economy; a=0 b=0; outside=1] or not _economy.has_method("set_country_procurement_policy"):
  Project/project-keynes/scripts/era/era_advancement_service.gd:181 [economy/call; receiver=_economy; a=0 b=0; outside=1] var result: Dictionary = _economy.set_country_procurement_policy(_handle, true,
```

## 存档边界续跑修复（2026-11-12）

合并上游后，进程内存档续跑（checkpoint）与不存档的原始运行在气候域分叉。原因有两处，都已修复：

- `map_generator.gd` 的 `advance_save_boundary()` 构造 `SusTickContext` 时把季节相位和速度倍率两个参数传反。
- ACTIVE 模式下气候由 worker 负责时，主线程的原生日图仍会发布气候结果。现在 `native_daily_sim_job.gd` 在 `native_daily_climate_suppressed()` 为真时不启动新一轮，日图切片完成时按 `climate_authority_suppressed` 跳过气候相关发布。

验证（宿主机）：`check_committed_replay.py --checkpoint --trace --days 10` 四段一致；年度自动存档（`--autosave --year-days 16 --save-day 16 --days 24`）四段一致；`check_replay_matrix.py` 的 save2、calendar5 四段一致；三个存档边界测试和五个架构护栏通过。

未解决，推送前处理：

- 第 1 天存档在新进程读档后，第 2 天的 ECONOMY 哈希不同，第 3 天起恢复一致。原因是首日的视野解算顺序：原始运行在第 1 天结束前还没按玩家国家解算过战争迷雾，全图可见；读档后立即解算，只有玩家周边可见，殖民逻辑读到的视野不同。没有持久状态分叉，所以矩阵默认用例由 save1 改为 save2，没有为它增加存档字段。
- multicountry5 的 checkpoint 在最后一天 EFFECT 哈希偶发不同（三次中两次），与 `migration.md` 已记录的 Effect→Country 命令到达时机问题同类。
- military20 的 resume 在读档后第一天 COUNTRY 哈希不同，尚未定位。
