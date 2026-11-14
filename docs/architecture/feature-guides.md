# 专项开发约束

只在改到对应功能时读本页；通用规则在 [development-guide.md](development-guide.md)。
每节写该功能的数据归属、不能破坏的约束和必跑的验证入口。新增专项约束写在这里，不写进通用开发指南。

## 脚本原生访问边界

`world_ext_binding_modules.json` 的 `script_dirs` 为 15 个绑定模块登记允许直接访问的目录或单个文件，路径相对 `Project/project-keynes`。正式脚本访问其他模块须经该模块的 facade；现有越界只是待迁移记录，不是永久许可。

`check_script_native_access.py` import 同目录 `world_ext_bindings.py` 的清单解析，扫描项目内全部 `.gd`，排除路径分段为 `tests`、`addons`、`.godot` 的目录；`tmp`、`tools` 内的 `.gd` 也按此范围检查。先跳过注释，区分代码和字符串；每处 `.绑定名(` 或内容恰好为绑定名的字符串算一个候选，不把字符串中的代码当调用。

候选只在 a 或 b 成立时计入。a：接收者是本文件直接由 `ClassDB.instantiate("DCWorldExt")` 赋值的变量、类型标注为 `DCWorldExt` 的变量或参数，或变量名匹配 `(?:^|_)(?:data_core_)?world_ext$|^_?ext$|^ext_obj$|^world$|^dc$`。直接调用、`has_method/call/callv/call_deferred` 的首个字符串参数，以及 `Callable(receiver, "绑定名")` 可识别接收者；点链取末端变量名。b：所有正式脚本中均无同名 `func name(` 定义。其他绑定名字符串仍按 b 判断，每个出现位置只计一次。a、b 都不成立时排除，`--audit` 输出两条规则各自的数量、交集和计入/排除各 10 条样例。

普通文件按完整目录边界匹配，不能用目录名前缀绕过。`*_facade.gd` 只继承最深的登记目录所属模块（例如 bakers 不继承 rendering 的 visual 权限）；若最深目录由多个模块共享，按 `<module>_` 文件名前缀选定所属模块，无法选定时不允许直接访问任何模块。

`script_native_access_baseline.json` 是 `{仓库相对文件: {模块: 越界次数}}`。新增文件/模块组合或超过该组合原次数均失败；减少时普通检查通过并提示收紧。`--write-baseline` 只用于首次生成或收紧，已有基线时也拒绝增加；不要通过删基线重新生成来接受新增越界。`--report` 给出 15 模块各自的越界文件数、次数和前五文件，已接入本地回归和 PR 的 `architecture-guards`。验证入口为该护栏、`test_architecture_guards.py`、`world_ext_bindings.py` 和 `check_world_ext_bindings.py`。

这是按词法和局部变量线索检查，不追踪跨文件返回类型、变量别名、运行时拼接或从变量传入的方法名，也不按作用域区分同名变量；同名脚本函数新增或删除会影响 b 的判定。计数不等于精确的运行时调用图，迁移前用 `--audit` 与实际代码复核。

## 原生扩展握手

`Project/project-keynes/data/native_binding_manifest.json` 是提交到仓库的 `DCWorldExt` 方法清单。绑定新增或删除后，在仓库根目录运行 `python3 tools/ci/world_ext_bindings.py --write-manifest` 重新生成；`check_world_ext_bindings.py` 会检查清单与静态绑定解析结果完全一致。启动会话时由 `NativeWorld.create()` 一次性把清单与 Godot 的 `ClassDB` 方法列表比较；类不存在时仍沿用没有扩展的回退行为，类已注册但握手失败时会明确报错并阻止进入会话。

Windows 编辑器锁住 DLL 时，可以用新文件名构建并切换加载映射，但切换前仍要先更新并提交这份清单，避免脚本与新 DLL 的接口版本不一致。

## 山地起伏调参与验收

生成高程归 `gdext/src/world_ext_generate_base.cpp`；山脊增量必须读冻结基底，
先用统一高度预算再收尾尖峰，不恢复按格逐点压缩或读已写邻格。
预算诊断通过 base/full 结果包的 `ridge_*` 字段检查；正常软收尾应不超过
陆地约 1%，高海平面也须保留正的山脊预算。初始 elevation 改动必须重新生成地图。

视觉地形参数归 `terrain_index_baker.gd::DEM_DEFAULTS` 与 `world_ext_bake.cpp`
对应 native 默认值；`project_keynes/rendering/dem/*` 可覆盖。
主脊振幅、波长、尖化指数分别使用 `ridge_amp_per_relief`、
`ridge_wavelength_hex`、`ridge_crest_exp`；谷深和谷壁使用
`valley_depth_per_relief`、`valley_wall_per_relief`，谷壁系数越大则同深度谷壁越窄陡。
`mountain_relief_floor`/`peak_relief_floor` 只对相应地貌提供最小起伏。
standalone、fused geometry、visual tile 都传 `cell_landform`，不得只修分块路径。
镜像项目的脚本和 Windows DLL 加载路径同时维护。

验证运行 `tests/world/mountain_relief_bake_test.gd`、
`tests/world/terrain_index_edge_bake_test.gd`、
`tests/runtime/native_generation_equivalence_test.gd`，
并检查 `tests/ui/visual_tile_native_bake_test.gd`。
验收需重启 Godot 后新生成地图，检查中远景主脊、近景谷壁、高原内部与海岸。
DLL 可通过 `DOTS_EXT_OUTPUT_BASENAME` 使用新文件名构建，避开现有编辑器锁定，
构建完成后再切换 `.gdextension` 的 debug/release 映射；不要结束用户编辑器进程。

## 经济平衡调参

经济平衡调整先用 `tests/economy/economy_balance_soak.gd` 跑固定种子的正式多国开局，
用 `tools/analysis/compare_economy_balance.py` 对齐同种子、同日和各国/职业分布。
现金日流量须除以真实结算天数，累计发行按 epoch 去重；未发布快照不得填零。
本轮产出默认1.5x、派生维护2x、开局60货币/人、黄金/白银发行8/0.5货币/单位；
开局规划须读取真实 profile，软投入按基础100%加额外增产处理。
满意度公式更改应提升 `EconomyCatalog.SATISFACTION_MODEL_VERSION`，由内容身份拒绝
旧模型存档；只有新增持久列时才改字节 schema。当前模型为2、保存布局仍为60。
验收与边界见 [经济平衡记录](../cpp-dots-runtime/economy-balance-2026-11-08.md)。

上游经济需求修复须运行
`tests/building/building_runtime_test.gd -- --supply-chain-only`。
派生计算实现归 `gdext/src/economy_runtime_derived_demand.cpp`，仍是同一个
`NativeEconomyRuntime` 成员；派生需求必须继续展开投入队列并阻止已访问回边。
工具等替代品的临时列在 epoch
取样前会清空，须由已提交的企业需求 EMA 和原投入槽活动上限重建冻结种子，
不能将预测写成真实销量、提款或资金。保留资源、库存、利润与业主生计门槛，
验证缺少下游与上游建筑时仍能形成原料价格和首座生产者机会；细节见
[经济公式](../cpp-dots-runtime/economy-fixed-point-ledger-formulas.md)。

## 天气与光照 Shader

- 降雪散点归 weather_cell_curtain.gdshader：全格位置随机与独立摆动必须配合
  邻格补画，不能把随机偏移再次乘小系数缩回格心。查找坐标的旋转不应旋转
  雪花投影形状；桌面与移动/Web 使用同一散点算法，保留天气 LUT、视野门控、
  三层视差。修改时检查五种宏变体的三层空间分布、连续帧和跨格完整性，
  以更大邻域逐像素对照验证查找范围；同步性能验证项目的 shader。

- 云影和天气云平流沿用局地风 LUT + 双相位有界位移，禁止直接用当前风乘总运行时间。
  LOW/MID/HIGH 必须编译期裁剪并在切档时重建材质、重绑 LUT；云影按档缩小 field，
  天气云低/中与移动/Web 使用轻量梯度噪声，高档光照复用屏幕导数，不重复求云密度。
  修改时运行 `tests/rendering/cloud_weather_quality_test.gd`；预算与 GPU 证据见
  [云 Shader 分档验证](../cpp-dots-runtime/cloud-weather-shader-quality-2026-11-09.md)。
  云影场在天气发布边界上传风 LUT，经 `wind_lut_changed` 共享给天气云；新旧风只在
  显示端按 `weather_lerp` 过渡，不新增仿真状态。机制与验证见
  [云影的世界空间连续性](../cpp-dots-runtime/vision-fog-and-borders.md#云影的世界空间连续性)。

- 永昼视觉日照统一使用 `earth_daylight.gdshaderinc::compute_eternal_visual_sun_dir`，高度以当地当日正午为基线，日内时角在 ±70° 浮动并保留 10° 下限；默认一个游戏年完成两个 Shader 日，按实际游戏日历进度映射。水面 specials 和各实例层不能另算全局光向。修改时运行 `tests/ui/dynamic_eternal_day_direction_test.gd`（`-- --render-noon` 验证实际 shader）及地被光照测试，GM 覆盖仍优先。
  Shader 日/游戏年的比例在 HexRenderer 的 `shader_days_per_game_year` 调整，默认2，允许0和小数；renderer 经窄 Callable 配置 WorldClock，默认相位按累计年进度映射，跨年不重置小数比例。
  永昼最大时角和最低高度在 HexRenderer 的“永昼太阳”分组通过 `eternal_max_hour_angle_deg` / `eternal_min_elevation_deg` 调整（默认 70°/10°）；setter 统一换算弧度并推送各材质，初始化/重建时重放，不随日相位重复推送。

## 时代晋升

- 时代晋升规则统一放在 `EraAdvancementCatalog`：科技 80% 必达，人口/已落成建筑/本时代贸易三选二；经济门槛为目标时代基数加每地块要求。物资篮子按时代倍率放大，筹备基数与逐格量相加。`EraAdvancementService` 仅在开始时冻结物资订单，原生采购与 Country 原子消耗保持既有路径；条件投影运行 `tests/game/module_projection_boundaries_test.gd`，玩家界面运行 `tests/game/player_country_ui_smoke_test.gd`。已启动订单（含旧存档）沿用保存的冻结数量。

## 军事界面命令

- 军事兵种份额：玩家局部修改经 `MilitaryFacade.submit` 将稳定 id 解析为完整 `int_pairs` 后提交；原生 `config.set` 是整表替换。改动此链路时运行 `tests/ui/military_config_command_test.gd`，避免空命令或清除其他兵种配比。
- 军事部队编成：地块军事页从格快照中的本国驻军 lots 形成 `army.create` 请求；PlayerController 复核本国领土与占领状态，GDScript 不直接改写驻军或部队。入口与请求契约见 `docs/ui/military-cell-tab.md`。

- 军事部队视野：玩家部队的位置从已提交的 `get_military_render_snapshot()` 读取，作为低预算移动源交给 `VisionSolver`；城市/领土源仍拥有更高预算。军事 `render_revision` 变化时由 Host 合并触发一次视野刷新，不在 Military 内写 `MapData.visible_arr`，也不新增存档段。验证用 `tests/ui/vision_solver_test.gd` 的部队源覆盖，并在真实运行时检查部队移动后的 `vision_revision`。
- 玩家自动探路：任务、观察点、返程和战斗暂停归 `MilitaryCore`（`military_core_explore.cpp`，PKMI v4 section 23）；`army.explore` 只接受 Host 安装的玩家 observer。探路 passability 独立于普通 `find_path()`，战争状态也不进入他国控制格；每国每日 8 个规划槽、16 次 A*，并保留至少 16 次共享路径预算给区域控制。`run_movement()` 逐实际进入格产生 trail，Host 在 `_prepare_military_exploration_day()` 只合并 `MapData.explored_arr`，visible/fog 仍由既有 `_refresh_vision()` 生成；保存前必须 flush trail，失败拒绝保存。验证入口：`tests/military/military_auto_exploration_test.gd`、`tests/military/military_dossier_test.gd`、`tests/runtime/military_index_continuation_test.gd`、`tests/qa/military_dossier_screenshot_qa.gd`。

## GM 屏蔽与叙事弹窗

- GM 的 `ui.suppress_popups` 必须同时阻止事件/年报/时代奖励/家族创立/理念抽取流程进入暂停展示路径，并在运行时切换时清理已锁定弹窗；新增 UI 屏蔽开关应经 `gm_toggle_changed` 接入 PlayerGame，由 `GameUIManager` 保存并恢复层可见性，GM 面板保持可用。
- 叙事自动选择/确认未取得弹窗暂停锁时不得恢复 `_was_paused` / `_previous_speed`：它们可能是默认值或上一事件的快照。`NarrativeEventFlow` 仅在持有 `locked` / `reopen_pending` 时登记恢复，`restore_pending` 消费一次；其他弹窗忙碌时延后释放。回归入口：`tests/game/narrative_popup_suppression_test.gd`，覆盖连续事件、手动暂停、倍速、运行中切换屏蔽、读档弹窗和故障锁。

叙事事件额度统一为每格每游戏年两次：周期抽样、事实触发、普通 AI 事件共用
`NarrativeEventService` 的入队检查和展示检查。队列出队时丢弃当年已超额的普通事件，
全局弹窗间隔未到则等待；定时后续事件可以越过等待项，且不消耗年度额度。
AI 定时后续请求携带 `scheduled_followup`，生成结果重新进入定时队列，
不得提前展示，也不得将普通 AI 预热结果当作定时后续豁免。

AI 事件有三个入口：脉冲预热、事实驱动（`GameplayEventBus` 白名单 `AI_FACT_HINTS`）
和定时后续预取，共用 `ai_min_request_gap_days`（默认 60 日）节流与单条在途；概率按
`situation_pressure_score()` 从基础值抬到上限。回执统一走
`NarrativeEventService.accept_ai_generation()`：超过 `ai_max_staleness_days` 或读档后
迟到一律丢弃，落地时重新采样地块上下文，避免文案与到达时的世界状态错位。
状态探针（`NarrativeStateProbe`，首批粮食紧缺/民生不满/连旱）在条件维持 `dwell_days`
后预取，回执复核失败则入 `_ai_event_pool`，等同一状态复现时出池；池子随 `pknr` 存读档。
AI 叙事文本只写处境与后果，不写气温/价格/库存/人口/百分比/日期这类读数（prompt 明确约束；
「三人」「三成」这类数量词照常写），validator 仅把温度读数改写成 `{temperature}` 占位符，不删句子；
`custom_label` 例外，仍写幅度与时长。
回归同上。

叙事事件触发扫描保留居民汇总查询；`NarrativeEventService.choose_option` 执行选项时，
须通过 `sample_cell_context(..., include_cohort_details=true)` 取得真实居民句柄，
现金效果经 EconomyFacade 向原生经济/国家权威提交守恒转账，在后续结算边界生效。
回归见 `tests/game/narrative_event_runtime_test.gd` 的寒潮 3% 国库援助用例；
汇总快照没有 `handles/populations`，不能据此选择转账收款人。

## 家族派遣面板

派遣面板以 `(source_cell, family_handle)` 标识来源行，目标已选时直接按地点分组展示
当地家族。全国进行中入口与详情都复用 PlayerController 查询，按日事件和回执更新；
不新增轮询或显示侧人口修改。筹备人数由 Economy 在推进时取计划人数与实际可派人数
的较小值，随后重新规划采购与进度分母；军人、最后族人及最后商人的限制共用同一计算。
已成交物资及在途采购沿用原托管/续接，不从 UI 退货或补账。回归用
`tests/country/colonization_planner_context_test.gd`、`colonization_workbench_ui_test.gd`
及 `tests/family/family_colonization_runtime_test.gd -- --population-shrink-only`。
旧套件基线限制见 current-state；机制契约见家族开拓运行时文档。

## 国库收支展示

玩家看到的国库收支默认是近 30 日日均，总览页可切换近 7 日/近 30 日。数据入口仍是
`CountryViewModel.sample_fiscal_history()`，每已提交日同时采样财政快照与国家摘要里的
国库现金；不要从 `EconomyFiscalHistory` 的逐日展示序列直接求和，未结算日会沿用上次
结算值。滚动窗口只汇总去重后的真实结算事件，并用现金首尾差校准净额，未细分差额
进入「其他国库变动」。历史不足时按实际覆盖天数折算，少于两个现金样本则回退到最近
一次结算。顶栏悬停与总览共用 `EconomyDossierViewModel.cashflow_from_history()`。
定向回归运行 `tests/economy/economy_fiscal_history_rolling_test.gd`、
`tests/ui/hud_status_card_test.gd` 和 `tests/economy/economy_dossier_view_model_test.gd`。

## 军事现金回执与审计

军事 D+1 `SPEND_CASH` 的现有 reserve/collect 适配器是现金中性的：reserve 扣国库，
collect 将同额加回国库，不能因回执非零就登记 Economy `explicit_money_burn`。
军事维护真实终端支出尚未接入。审计窗口外已完成的资产变化也不能直接搬成下一
epoch 的 mint/burn；先判断 opening snapshot 是否已包含该变化。回归运行
`tests/economy/military_deferred_cash_conservation_test.gd`，同时验证真实待回执行恢复、
防重、后续经济结算与三项守恒；只观察军事回执成功不足以证明账目正确。

## 科技前置

科技前置修改只写 `data/technology/technology_network.json`，同步知识基础、前置理由和静态连线；
开局赠送的生存技能除外，正式研究须依赖早期知识机构。资源或发展信号不能绕过这一基础，
也不能替代取样工具、用火、窑烧、繁育等不可替代知识；新增硬边后保留原有时代与稳定 ID，
只按真实前置做最小拓扑重排，不能以时代标签充当普通科技的统一研究锁。
运行 `tests/technology/technology_knowledge_foundation_test.gd` 验证铁矿辨识、露头煤辨识和市场制度的
锁定及入队；权威与内容身份规则见 [科技运行时](../cpp-dots-runtime/technology-tree-runtime.md)。
全树知识闭包、静态连线及玉米实践领域回归运行
`python tools/technology_tree/test_prerequisite_foundations.py`。

## 科技内容节奏审计（2026-11-08）

新建或再平衡科技解锁前，先阅读 `docs/architecture/design.md` 和本指南，明确目录仍归 `technology_network.json`、建筑/物资/自然资源仍归各自 Profile，科技路线只负责研究资格，建筑完整门槛由直接科技与 `required_technology_tags` 合并而成。不要以应用交汇卡、目录标注时代或软投入伪造硬解锁。

全量审计使用 `Project/project-keynes/tools/technology_tree/rebalance_content_pacing.py`，审查416个稳定科技ID与459建筑、167物资、31自然资源的绑定和理论生产闭包；完整逐项决策及变化前后时代计数见 `Project/project-keynes/tools/technology_tree/technology_content_pacing_audit.md` 与 `content_pacing_revision.json`。本轮石器/农耕研究从75/67调整到56/51，王国/帝国为57/43；没有加入运行时时代锁或新的运行时信号。

核查顺序：Godot `build_technology_network_authoring.gd` 规范化；`run_content_pacing_checks.py` 串行运行 design、binding、closure、construction、industry、catalog、research、activation、application 测试；运行离线9个负例测试；成功后用 `--refresh-manifest` 刷新稳定目录指纹，生成并 `--check` 科技树报告。每次修改科技绑定后都重做全量闭包；逐时代同代假设不足以证明直接先修祖先可达。

## 部队指挥 UI（2026-11-10）

预览草稿归 `PlayerController`，命令仍走军事 facade；`MilitaryDossier` 固定指挥区通过
`GameUIManager.update_military_arm_order` 事件更新。move/area 确认前重验路径，失败保留草稿；
探路草稿只生成中心 + 半径的 `cells`，不调用 `preview_path()`，中心不可直达仍可提交。每日只写值，
同身份刷新不重建节点。交互与验证边界见 `docs/ui/military-army-controls.md`。

军事 UI 的显示层改动保持同一边界：主军事卷宗、地块军事页、部队/战线档案只读
`MilitaryViewModel` / `CellInspectorViewModel`；地图工具条只切换 `MilitaryMapLayers` 的
单层可见性，不直接查询或写入 MilitaryCore。按钮使用语义纸贴图标、44px 以上热区和显式
焦点链；训练行只展示目标兵种、人数、进度和剩余天数，不把“源自某职业”当成玩家决策字段。

地图军事视觉也只在表现层扩展：部队纸旗、交战纸章和 frontier grain 位图由
`MilitaryArmyTokenLayer` / `MilitaryBattleLayer` / `MilitaryFrontLayer` /
`MilitaryOccupationLayer` 的 shader 消费，不改变快照字段、军事状态、迷雾判定或存档。
真实渲染必须用 `military_formation_map_visual_harness.gd` 验证；仅通过 headless 不代表 shader
在图形后端可用。

## 军需市场需求（2026-11-08）

军事缺货预测走 Military intent 17 → Economy opcode 36 的既有 D+1 命令桥。每批先 reset 再按真实 SKU/市场格写入缺口；不要伪造销售、消费、财政扣款或库存。Economy 在 epoch 冻结时核对国家句柄、归属与可用国库资金，扣除其他公共采购承诺，并按 10 天窗口折算到通用采购需求。最新快照复用已保存/哈希的 pending command 队列，派生日需求缓存不入档，不增加保存 schema。验证入口：`tests/runtime/military_procurement_demand_test.gd`、`military_procurement_pod_test.gd`。
