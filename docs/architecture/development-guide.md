# 开发指南

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

军事 D+1 `SPEND_CASH` 的现有 reserve/collect 适配器是现金中性的：reserve 扣国库，
collect 将同额加回国库，不能因回执非零就登记 Economy `explicit_money_burn`。
军事维护真实终端支出尚未接入。审计窗口外已完成的资产变化也不能直接搬成下一
epoch 的 mint/burn；先判断 opening snapshot 是否已包含该变化。回归运行
`tests/economy/military_deferred_cash_conservation_test.gd`，同时验证真实待回执行恢复、
防重、后续经济结算与三项守恒；只观察军事回执成功不足以证明账目正确。

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

科技前置修改只写 `data/technology/technology_network.json`，同步知识基础、前置理由和静态连线；
开局赠送的生存技能除外，正式研究须依赖早期知识机构。资源或发展信号不能绕过这一基础，
也不能替代取样工具、用火、窑烧、繁育等不可替代知识；新增硬边后保留原有时代与稳定 ID，
只按真实前置做最小拓扑重排，不能以时代标签充当普通科技的统一研究锁。
运行 `tests/technology/technology_knowledge_foundation_test.gd` 验证铁矿辨识、露头煤辨识和市场制度的
锁定及入队；权威与内容身份规则见 [科技运行时](../cpp-dots-runtime/technology-tree-runtime.md)。
全树知识闭包、静态连线及玉米实践领域回归运行
`python tools/technology_tree/test_prerequisite_foundations.py`。

## 山地起伏调参与验收

生成高程归 `gdext/src/world_ext_generate.cpp`；山脊增量必须读冻结基底，
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

先读 [current-state.md](current-state.md) 和 [design.md](design.md)，确定数据所有者、运行线程和真正的提交点；边界规则见 [module-boundaries.md](module-boundaries.md)。目标接口不是已有 API。

所有命令从仓库根目录运行；Python 用 `/Users/herh/.local/bin/python3`，Godot 用 `/opt/homebrew/bin/godot`。日志目录必须是新目录。

## 改一个模块

上游经济需求修复须运行
`tests/building/building_runtime_test.gd -- --supply-chain-only`。
派生计算实现归 `gdext/src/economy_runtime_derived_demand.cpp`，仍是同一个
`NativeEconomyRuntime` 成员；派生需求必须继续展开投入队列并阻止已访问回边。
工具等替代品的临时列在 epoch
取样前会清空，须由已提交的企业需求 EMA 和原投入槽活动上限重建冻结种子，
不能将预测写成真实销量、提款或资金。保留资源、库存、利润与业主生计门槛，
验证缺少下游与上游建筑时仍能形成原料价格和首座生产者机会；细节见
[经济公式](../cpp-dots-runtime/economy-fixed-point-ledger-formulas.md)。

经济平衡调整先用 `tests/economy/economy_balance_soak.gd` 跑固定种子的正式多国开局，
用 `tools/analysis/compare_economy_balance.py` 对齐同种子、同日和各国/职业分布。
现金日流量须除以真实结算天数，累计发行按 epoch 去重；未发布快照不得填零。
本轮产出默认1.5x、派生维护2x、开局60货币/人、黄金/白银发行8/0.5货币/单位；
开局规划须读取真实 profile，软投入按基础100%加额外增产处理。
满意度公式更改应提升 `EconomyCatalog.SATISFACTION_MODEL_VERSION`，由内容身份拒绝
旧模型存档；只有新增持久列时才改字节 schema。当前模型为2、保存布局仍为60。
验收与边界见 [经济平衡记录](../cpp-dots-runtime/economy-balance-2026-11-08.md)。

只要接口不变，改模块内部不需要读其他模块。

1. 在模块自己的文件里改；公式留在数据所有者的现有实现中。
2. 别的模块需要新能力时，在 `<module>_api.h/.cpp` 对应调用方的组里加转发函数：签名与成员一致，前面多一个 `Runtime&` 或 `const Runtime&` 参数，函数体一行。已有同签名转发直接复用。
3. 外部要用的常量、枚举或嵌套类型，移进 `struct XApi` 或命名空间作用域，运行时类里留 `using X = ...;`，内部写法不变。
4. 需要另一个头里的值类型时，先确认那个头只包含系统头，再登记进 `tools/ci/module_api_shared.json` 并写原因。
5. 跑 `check_module_api.py` 与 `check_cpp_deps.py`。

### 把一个外部文件迁到接口

`#include "x_runtime.h"` 换成 `#include "x_api.h"`；`Runtime::CONST` 改成 `XApi::CONST`；`x->m(a)` 改成 `x_api::m(*x, a)`；然后从 `tools/ci/module_api/<module>.json` 的 `legacy_includers` 删掉这个文件，不删会报“过期条目”。指针和引用在不完整类型上照常可用；需要完整类型的地方（按值成员、`sizeof`、`unique_ptr` 析构、复制）用接口里的工厂/析构转发，例如 `modifier_api::copy_runtime` / `replace_runtime`。

### 新建一个模块接口

建 `<module>_api.h/.cpp` 和 `tools/ci/module_api/<module>.json`（字段见 `check_module_api.py` 的文档串：`api_headers`、`internal_header_patterns`、`owner_file_patterns`、`composition_roots`、`legacy_includers`、`forbidden_owner_includes`）。先把现有外部包含者全部放入 `legacy_includers`，再逐个迁移。

### 模块调用宿主

只能经 `<module>_host_port.h`。新增宿主能力：在端口里加纯虚方法（签名与宿主方法完全一致），宿主方法加 `override`，方法体不变。端口头只包含系统头和不含宿主类的协议头；宿主的嵌套类型若出现在签名里，先移到协议头并在宿主里留别名。两个端口声明同一方法时，宿主只写一个 override。模块契约的 `forbidden_owner_includes` 禁止所有者文件包含 `native_simulation_host*.h`。

## 改每日模块

1. 在 `native_simulation_host.cpp` 的 modules 表找到对应域，改 `native_simulation_stage_<domain>.cpp` 的成员函数。
2. 阶段返回 true 表示继续遍历，不表示业务成功；成功、等待、失败由原有 stage/commit 字段和故障状态表达。返回 false 提前结束本次日计划。
3. inline 与 worker 共用这些函数，不能在里面用 Godot 对象或 GPU。
4. 保留气候前置提交、域前后故障点、Events 尾部调用、完成检查和 publish 顺序；改这些语义要另行设计并提供回放证据。
5. 新独立日域会改 ABI（`RuntimeDomainId`），不能当普通表项加。
6. 改 reads/writes 后同步模块描述符（`runtime_module_contracts.json`），跑 `check_module_contracts.py`；描述符是只读契约，不改调度顺序。新业务域要在 Freeze 入口登记 `RuntimeFrozenInputVersion`。

## 跨域读取与请求

- **新读边**：所有者提供返回独立副本的 `copy_committed_view()`，带 generation/day；消费端调用 `observe_committed_view()`，不保存 snapshot 引用，不读 plan，不把 plan preview 标成 committed。同步给 `check_committed_views.py` 加正例和直接/别名/成员指针绕行反例，并更新 `test_architecture_guards.py`。
- **新请求**：先登记 `resolve_apply_contracts.json`，复用既有保存队列，不重复分配请求身份、不改排序字段。只能在原同步边界立即消费；worker 请求优先分支不能被越过；`prepared/apply/applied` 次序和经济侧入账位置不变。现金/物资用 `fiscal_return_port()` 的 `cash_to_cohort/cash_from_cohort/good_to_market/good_from_market` 再 `submit_transfer`；科研用 `research_intent/submit_research`；国库多物资支出用 `spend_intent/submit_spend`；采购用 `procurement_port()`。
- **新域对**：先在 `cross_domain_inventory.json` 登记并写明是已迁移、明确不迁移还是待核查。
- **新软完成原因**：必须对应真实的等待依赖，并加入反例；不能静默加入。

## 存档

- 脚本侧 provider 实现 `archive_contract()`（id、版本、段名、恢复依赖、可读版本），在 `world_state_modules.gd` 组合；不能从另一个所有者直接读写字节。C++ 段登记在 `cpp_save_section_contracts.json`。
- 新增影响后续日推进的状态（包括小数余量、逐格日期、发布记忆、被实际读取的兼容副本、请求/ACK 游标、编号游标）：先确定所有者，在原 commit 边界冻结副本，升段内版本，严格校验长度、有限性、内容身份，完整解码后才安装，旧版本以明确错误拒绝。能由 catalog 无副作用重建的缓存在恢复时重建。
- 验证：新段逐字节往返、其他业务段逐字节不变、非空字段往返、旧版拒绝测试、checkpoint 逐日比较读档后至少八日。不能用整数投影或落后的显示镜像代替所有者继续态，不能改哈希算法来让回放通过，不能删字段或放宽比较。
- 保存只在已提交安全边界进行（`GameSaveCoordinator._save()` 统一等待；`inflight_save_boundary_test` 覆盖），不从 provider 直接捕获 Plan 中间状态。读档失败不能换新世界或继续半恢复的会话。
- 修改执行器保存或命令交接时，复用 `native_simulation_host_executor_boundary.cpp` 的共同服务与排序规则。inline 的保存处理也必须取得日边界锁，并检查跨调用的未完成日标记；不能仅以当前没有 C++ 调用正在执行来认定可保存。运行 `runtime_inline_save_restore_test.gd`，覆盖后台/inline 四种存读档组合、未来命令、一次性回执、重复保存、未完成日和保存失败。命令超出 PKSR 既定容量时要明确失败并保留全部命令，检查处理完命令后可再次保存，不能静默截断。
- 正式 inline 保存还必须运行 `runtime_inline_coordinator_save_test.gd`，覆盖运行中/暂停时保存、读档后继续及经济状态比较。协调器按 `inline_day_pending` 和真实调用边界判断，不能要求 inline 的 RUNNING 自动变成 PAUSED。
- 停止、保存及时钟控制条件统一经 `runtime_control_wakeup` 在等待锁内发布。`runtime_control_wakeup_test.cpp` 固定检查与等待之间的窗口；`runtime_executor_boundary_test.gd` 验证实际停止通知、四种执行器重启组合、入口及待执行命令、编号连续、一次性结算，以及启动拒绝后原会话可继续。待执行列表归世界，停止不能销毁，重启不能清空；重复或无效启动必须先拒绝再修改配置。
- CLOCK_WAIT 必须带停止、保存、暂停与速度变化的条件检查；仅把通知放在锁内仍不能保护无条件的计时等待。执行器测试覆盖单次控制通知、inline+SHADOW 拒绝后的存档恢复，以及未完成日跨后台/inline 替换后的冻结输入和保存阻止。
- `runtime_world_lifecycle_test.gd` 区分同一世界重启与复用对象创建新世界，检查已提交国家状态、未领取确认、连续日期、新世界命令隔离及运行中拒绝重配；新世界身份编号必须递增，无效配置（包括后段校验失败）保留旧世界及其编号。正式 inline 用例还在保存恢复后重复应用策略，并逐项比较国家状态及下一日整份经济哈希。保留这些比较，不能只检查重启成功或名称未变。`runtime_world_rules_rebuild_test.gd` 另在后台和 inline 各覆盖三代新世界：规则在 Country 前配置、规则内容变化、直接复用定义、无效配置后旧世界续跑。检查实际 Effect 执行与 Modifier 数值、Trigger 输出及规则快照接收，并确认旧实例/事件没有混入；仅有日期推进或 ready=true 不算规则生效。
- 相同 ACTIVE 授权范围的重启走 `native_simulation_host_lifecycle.cpp`，只替换执行器，世界状态与日内继续位置不重建。新世界由停止后的 `configure_country` 建立：先在私有候选中验证，成功后再配置原 Country 对象，保持地址稳定及 session epoch 递增。新 Host 从旧 Host 带入回复协议编号作为起点，首次启动再递增，不能让旧回复与新请求复用身份；同一世界重启保持原编号。替换前用 `make_new_world_host` 把当前已验证的 Modifier、Effect、Trigger、Ideology 规则定义及 Modifier 稳定键映射安装到私有候选中，任何失败都保留旧世界。规则定义与世界状态分开：不复制旧实例、请求、回执、输入、意见、快照或读取进度。替换成功时清理规则主线程对象中的旧世界状态，Effect/Modifier 的快照读取进度必须随状态清理重置，不能保留成新世界首份结果的拒收门槛。替换 Host 前必须解除经济对其 OwnedState 的借用，并重新连接 Country/Economy/Effect 适配层。重复捕获相同 Country 目录不能清掉终态确认；新世界和读档才更换相应记录。
- 手动推进后台日的测试必须同时运行生产的结果接收步骤。`ideology_save_worker_authority_test.gd` 在等待中调用宿主的 `_service_runtime_liveness`，日提交后再接收一次结果，然后重建逐格效果。只等待后台日期变大、不接收新快照，会把旧的主线程显示状态误判为业务失败；不能靠增加天数或放宽比较掩盖。

## 会话与宿主脚本

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

- 时代晋升规则统一放在 `EraAdvancementCatalog`：科技 80% 必达，人口/已落成建筑/本时代贸易三选二；经济门槛为目标时代基数加每地块要求。物资篮子按时代倍率放大，筹备基数与逐格量相加。`EraAdvancementService` 仅在开始时冻结物资订单，原生采购与 Country 原子消耗保持既有路径；调整后运行 `tests/technology/era_advancement_service_test.gd`。已启动订单（含旧存档）沿用保存的冻结数量。

- 军事兵种份额：玩家局部修改经 `MilitaryFacade.submit` 将稳定 id 解析为完整 `int_pairs` 后提交；原生 `config.set` 是整表替换。改动此链路时运行 `tests/ui/military_config_command_test.gd`，避免空命令或清除其他兵种配比。
- 军事部队编成：地块军事页从格快照中的本国驻军 lots 形成 `army.create` 请求；PlayerController 复核本国领土与占领状态，GDScript 不直接改写驻军或部队。入口与请求契约见 `docs/ui/military-cell-tab.md`。
- 军事部队视野：玩家部队的位置从已提交的 `get_military_render_snapshot()` 读取，作为低预算移动源交给 `VisionSolver`；城市/领土源仍拥有更高预算。军事 `render_revision` 变化时由 Host 合并触发一次视野刷新，不在 Military 内写 `MapData.visible_arr`，也不新增存档段。验证用 `tests/ui/vision_solver_test.gd` 的部队源覆盖，并在真实运行时检查部队移动后的 `vision_revision`。
- 玩家自动探路：任务、观察点、返程和战斗暂停归 `MilitaryCore`（`military_core_explore.cpp`，PKMI v4 section 23）；`army.explore` 只接受 Host 安装的玩家 observer。探路 passability 独立于普通 `find_path()`，战争状态也不进入他国控制格；每国每日 8 个规划槽、16 次 A*，并保留至少 16 次共享路径预算给区域控制。`run_movement()` 逐实际进入格产生 trail，Host 在 `_prepare_military_exploration_day()` 只合并 `MapData.explored_arr`，visible/fog 仍由既有 `_refresh_vision()` 生成；保存前必须 flush trail，失败拒绝保存。验证入口：`tests/military/military_auto_exploration_test.gd`、`tests/military/military_dossier_test.gd`、`tests/runtime/military_index_continuation_test.gd`、`tests/qa/military_dossier_screenshot_qa.gd`。

- 会话扩展用 `WorldRuntimeHost.register_session_module`（`world_session.gd` 管准备、取消、关闭）；保存扩展用 `game_save_coordinator.gd` 的 `register_state_module(provider, restore_after)`。
- `world_runtime_host.gd` 只保留公开入口、信号和状态转发；生成/恢复、日推进、GM/录制、视觉查询、生命周期在 `world_runtime_generation_adapter.gd`、`world_runtime_daily_adapter*.gd`、`world_runtime_gm_adapter*.gd`、`world_runtime_visual_adapter.gd`、`world_runtime_lifecycle.gd`。策略重启也由生命周期组件执行，必须等执行器真实退出，并传回捕获或启动失败。
- GM 的 `ui.suppress_popups` 必须同时阻止事件/年报/时代奖励/家族创立/理念抽取流程进入暂停展示路径，并在运行时切换时清理已锁定弹窗；新增 UI 屏蔽开关应经 `gm_toggle_changed` 接入 PlayerGame，由 `GameUIManager` 保存并恢复层可见性，GM 面板保持可用。
- 叙事自动选择/确认未取得弹窗暂停锁时不得恢复 `_was_paused` / `_previous_speed`：它们可能是默认值或上一事件的快照。`NarrativeEventFlow` 仅在持有 `locked` / `reopen_pending` 时登记恢复，`restore_pending` 消费一次；其他弹窗忙碌时延后释放。回归入口：`tests/game/narrative_popup_suppression_test.gd`，覆盖连续事件、手动暂停、倍速、运行中切换屏蔽、读档弹窗和故障锁。
- 组件只接收窄 Callable/RefCounted 依赖，不持有整个 host，不建立第二个日推进入口。传给信号和存档服务的回调必须是 host 绑定的 Callable，不能是组件自身的未绑定方法。停止顺序：先停执行器、等 `simulation_executor_exited`，再释放资源。

## 环境开关与故障点

1. 在 `runtime_switch_registry.h` 的 `RuntimeSwitch` 枚举加键，在 `.cpp` 的 switches 数组同位置填名称、未设置行为、作用、是否仅诊断。
2. 用 `pk::runtime_switch_value(pk::RuntimeSwitch::PK_名称)` 取原始字符串，在调用处显式解析；不直接 `getenv`。
3. 新故障名加入 faults 数组，在既有合法边界调用 `try_fault_injection`。
4. 文件型诊断开关（如 `PK_SIM_DAY_TRACE`）只接受绝对路径；测试前后会检查新增的非源码文件，有就失败。

## 机械搬迁与拆分

- 一组一组做：冻结参照、按成员比较签名与函数体词元（含字面量）、串行构建、主黄金三次。静态缓存、`thread_local` 和有初始化副作用的辅助函数保持单一归属；无状态匿名辅助函数可以复制。
- 新文件不超过 2000 行，不为新文件开超限豁免。超限文件变短后用 `check_size_ratchet.py` 写候选，确认只有变小的条目变化再收紧。
- 依赖基线只能用 `check_cpp_deps.py --write-baseline` 收紧；位移用 `--moves <json>`（“目标完整键 → 原文件”）。绝不手改；若总量或域对增加，说明有新债务，停下来处理。改文件名前确认不会改变域归属（见 `_family_` 规则）。
- 跨域完整类型若因拆分需要聚合，只能放在私有实现 `.inc` 里并在基线登记来源。
- GDScript 拆分给调用加 `host.` 前缀时，不能碰字符串字面量和注释。拆分后要与拆分前源码比对：带 `host.` 的字面量若在原文件里不存在、去掉前缀后存在，就是误改。还要检查 `Callable(self, …)` 和以方法名当值传递的地方，它们应该指向宿主，而不是适配器里多一个 `host` 参数的同名方法。

## 内存错误排查（ASAN，macOS）

两次相同运行只有一次分叉、某个字段出现不合法的值（例如权重和不再是 10000）时，先怀疑越界写或释放后写，用 ASAN 构建来定位。

1. 在 `gdext/SConstruct` 的 `objects = env.SharedObject(sources)` 之前临时加 `env.Append(CCFLAGS=["-fsanitize=address", "-fno-omit-frame-pointer"], LINKFLAGS=["-fsanitize=address", "-Wl,-rpath,<clang 运行时目录>"])`。运行时目录是 Xcode 工具链的 `usr/lib/clang/<版本>/lib/darwin`。构建时加 `debug_symbols=yes`，否则链接会去掉符号，栈里只剩偏移。
2. Homebrew 的 Godot 有 hardened runtime，会拒绝加载 sanitizer 运行时。把 `Godot.app` 复制到临时目录，用 `codesign --force --deep -s -` 重新做 ad-hoc 签名。
3. SIP 保护的程序（如 `/usr/bin/timeout`）和带 hardened runtime 的 Python 会剥掉 `DYLD_*` 环境变量。所以要写一个 bash 包装脚本，在脚本里 `export DYLD_INSERT_LIBRARIES=<…>/libclang_rt.asan_osx_dynamic.dylib` 和 `ASAN_OPTIONS=detect_container_overflow=0:detect_leaks=0:log_path=<目录>/asan`，然后 `exec` 复制出的 Godot，再把这个脚本作为 `--godot` 传给 CI 脚本。
4. 查完把 `SConstruct` 恢复原样，再做一次普通构建，并用 `otool -L` 确认产物里不再依赖 asan。

## 护栏与检查

静态护栏（默认回归也会先跑）：

```bash
cd tools/ci && for g in check_size_ratchet.py check_cpp_deps.py check_cross_domain_inventory.py check_runtime_advancers.py check_runtime_switches.py check_committed_views.py check_save_contracts.py check_module_contracts.py check_resolve_apply.py check_module_api.py test_architecture_guards.py; do /Users/herh/.local/bin/python3 $g >/dev/null 2>&1; echo "$g exit=$?"; done
```

构建（不同 SCons 配置共用中间文件，必须串行；跑带墙钟故障门槛的检查时不要并行编译）：

```bash
/Users/herh/.local/bin/scons -C gdext platform=macos target=template_debug arch=arm64 dev_build=no -j8
/Users/herh/.local/bin/scons -C gdext platform=macos target=template_release arch=arm64 dev_build=no -j8
```

交付已追踪的 macOS arm64 程序库时，两种配置都要重编。编辑器默认只加载 debug，不能据此判定 release 可用。运行 `check_macos_runtime_extension.py --godot … --library <程序库绝对路径> --log-dir <新>`，它在临时小项目中加载指定库，复用完整的 inline/后台存读档用例并核对 PKSR v5；不会改正式项目的扩展映射。

| 检查 | 命令要点 | 何时必须跑 |
|---|---|---|
| 黄金五链 | `check_golden_determinism.py --godot … --log-dir <新> --runs 3`；`--external-only` 只跑 v5 | 每次改 C++ |
| 默认回归 | `run_regression_checks.py --godot … --log-dir <新>`（约 15–20 分钟；首次导入加 `--import`） | 每次提交前 |
| 保存续跑矩阵 | `check_replay_matrix.py --godot … --log-dir <新>`；`--full`、`--annual`、`--annual-neighbors`、`--military`、`--military-annual` | 改继续态、事件/ACK 游标、军事 lot、军饷、累计收入、编号恢复 |
| 单场景续跑 | `check_committed_replay.py --checkpoint --trace --days 10` | 定位首个差异 |
| 气候存档 | `check_climate_archive.py --godot … --log-dir <新>` | 改 CLM2 或经济发布块 |
| 军费专用库 | 用 `gdext/tests/SConstruct.military_fiscal_probe` 构建，回归加 `--military-fiscal-probe <绝对路径>` | 改军饷、财政端口 |
| 外围同日对齐实验 | `check_external_day_alignment.py --runs 3`（不进默认回归，不写基线） | 只在评估对齐方案时 |

测试必须用固定经济周期：黄金、回放、矩阵入口都安装 `tests/runtime/replay_cadence.gd`，检查器发现缺失即失败；生产仍按真实耗时自适应。

## 黄金基线维护

- `tests/runtime/golden_day_hash_test.gd`：seed=20260727、40×28、无外国、正式开局，固定日序 1..8，无玩家命令。每次等同日提交（worker 无在途日任务、Modifier 已消费相同 generation）后取值，不靠睡眠。
- 正常运行读 v4 `golden_day_hash_baseline.json`，同时核对原样保留的 v1/v2/v3；v5 在 `golden_external_advancers_baseline.v5.json`。
- 更新基线：先保留旧结果并解释业务变化，用同一二进制 `--capture-candidate` 连续至少 5 次逐日逐域比较，人工审查新旧取值，建立后跑 `--runs 10`。不能删字段、改种子或删失败样本拼连续次数。架构迁移不允许改变五条链。
- 诊断开关：`PK_GOLDEN_CAPTURE=1` 只打印结果；`PK_GOLDEN_DIAGNOSTICS=1` 打印初始化资源列与每日完整经济哈希；`PK_GOLDEN_COUNTRY_TRACE=<绝对路径>` 记录 Country 原始列。

## 性能验证

无界面录制：`godot --headless --path Project/project-keynes --script res://tests/game/headless_perf_record.gd -- days=N speed=50 seed=… width=60 height=40 …`，产出 `tmp/perf_record_*.csv`。结果行是 `[headless-perf/result] … run_ms=… ledger_failures=… fatal=… rows=… expected_rows=… path=…`。有效运行要求 `fatal=false`、`ledger_failures=0`、`rows=expected_rows`；exit 9 只表示 M7 吞吐门槛（≥50 日/秒）没过，不使结果无效。

模拟在 worker 上跑时 `t_sus_ms` 恒为 0，不能用来比较。看这三项：结果行的 `run_ms`；CSV 中 `runtime_graph_worker_time_execute_us` 末行减首行（worker 实际执行时间）；`sched_day_total_ms` 的均值/p95/最大值（每日墙钟）。比较两个版本时，用两个检出（旧版本用 `git worktree` 建、构建并 `--import`），同参数交替运行至少 3 轮，各用独立 `HOME`，取中位数；单次噪声很大。

## 交付要求

- 同步更新本目录对应页面；区分源码核查、构建、无界面运行、图形和其他平台验证。拆文件不是所有权迁移完成。
- 报告里写实际跑过的命令和输出；未跑的写明未跑。构建改动了被追踪的二进制时列出来，不用版本还原覆盖现场。

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
