# 源文件职责拆分

最初拆分处理长度检查发现的 19 处增长超限。17 个已有登记收紧或删除，另外两处回到
800 行以内。后续修复也按职责抽出代码。600/800/2000 行默认限制与原有豁免条件继续生效。
历史大文件仍按已登记大小只能变小，本轮通过检查不表示这些文件都已达到默认限制。

以下是已接入的实现位置。脚本路径相对于 `Project/project-keynes/scripts/`，
C++ 路径相对于 `gdext/src/`。

| 入口 | 抽出的职责与实现 | 输入、状态和回调边界 |
|---|---|---|
| `era/era_advancement_service.gd` | `era/era_advancement_conditions.gd`：晋升条件与文字 | 只读科技、经济、领土和贸易数；订单冻结、收购及保存仍归 service |
| `game/player_controller.gd` | `game/player_command_validation.gd`：命令标识、参数检查、税率解析与结果结构；`audio/music_situation_playback.gd`：显示用音乐平滑；`game/player_controller/{military,progression,selection,narrative}.gd`：军事、时代/理念、地图选择和叙事职责 | 每次传当前代际和指定查询回调；序号分配、提交和结算仍归 controller；G5 协作者每次接收宿主，不保存宿主或可变会话状态 |
| `geography/map_generator.gd` | `simulation/runtime_climate_hash.gd`：气候摘要编码；`geography/map_generation/native_generation_bridge.gd`：生成请求、检查与 PKMAP 读取；`terrain_gen.gd`：结果校验、装配与基线快照 | 生成助手仅借用 generator_context 的弱引用；原生实例、报告字典、装配器与加载状态仍归 generator；异步入口保留 return await，装配让帧与调用时点不变 |
| `geography/world_clock.gd` | `diagnostics/world_day_cost_probe.gd`：日耗时桶与报告 | 探针独占诊断状态，原入口和属性转发；不推进或暂停时间 |
| `main.gd` | `diagnostics/daily_simulation_breakdown.gd`：每日报告格式；`main/{debug_tools,setup_controls,diagnostics,overlay,mobile_overlay}.gd`：调试开关、设置/速度控件、性能报告、覆盖层和移动调试层 | 保留生命周期、每日编排、只读入口和状态所有权；协作者每次接收 main，不保存 generator，不增加推进入口 |
| `rendering/building_visual_layer.gd` | `building_visual_assets.gd`：网格、材质与宏观索引字节 | 无场景/仿真状态；原生建筑缓存、上传顺序和可见性仍归原层 |
| `rendering/hex_renderer.gd` | `detail_profile_selection.gd`、`renderer_weather_inputs.gd`、`renderer_lighting_bindings.gd`、`renderer_map_assets.gd`、`renderer_sea_ice_diagnostics.gd` | 分别负责档位选层、天气数组、光照绑定、共享资源和诊断；只接收对应数据、节点或绑定到 renderer 的回调 |
| `rendering/map_baker.gd` | `map_material_assets.gd`：共享地形材质和噪声资源 | 无世界继续态；烘焙、运行期缓冲、纹理上传时点不变 |
| `rendering/military_army_token_layer.gd` | `military_token_lod.gd`：缩放切档与名称 | 纯函数；切档状态、动画和节点仍归 token layer |
| `rendering/resource_visual_layer.gd` | `resource_shader_variants.gd`、`resource_instance_plan.gd` | 分别负责运行/预热着色器来源、资源形态与稳定实例筛选；情报记忆和几何缓存仍归原层 |
| `rendering/shrub_layer.gd` | `vegetation_shader_variants.gd`：植被着色器变体与预热来源；`vegetation_node_lifecycle.gd`：附属/临时移出节点的释放 | 原始源码与前缀保持一致；编译缓存仍只有原层持有 |
| `rendering/vegetation_family_layer.gd` | `vegetation_family_style_lut.gd`：家族样式纹理 | 从现有 profile 编码；批次、LOD 和阴影上传仍归原层 |
| `ui/cell_inspector_view_model.gd` | `ui/family_workspace_projection.gd`：家族档案显示模型 | 从显示行副本整理，不更改家族状态；去重保留不同分支 |
| `ui/country_view_model.gd` | `ui/country_ideology_presentation.gd`：理念面板、卡牌及失败提示 | 只整理显示数据；保留原来三个调用入口 |
| `ui/components/inspector_panel.gd` | `inspector_category_patch.gd`：对现有控件写值 | 接收指定控件和宿主绑定回调；建节点、信号接收者和对象生命周期不变 |
| `ui/components/military_workspace.gd` | `military_table_rows.gd`：兵营、训练、部队、运输表格 | 只接收对应表格和显示行；选择、信号和命令操作仍归 workspace |
| `ui/game_ui_manager.gd` | `ui/game_hud_layout.gd`：HUD 排版和地图安全区；`ui/game_ui/{country_routes,era_progression,overlays}.gd`：国家卷宗路由、时代/奖励和覆盖层流程 | 每次刷新借用的独立控件；协作者接收 manager，不持有整个 manager；信号和动态节点仍绑定宿主 |
| `ui/components/ideology_workspace.gd` | `ui/components/ideology_workspace_presentation.gd`：工作区节点构造、布局、模型索引和牌面刷新 | 宿主保留引擎回调、动画/命令入口和可变状态；显示协作者每次接收 workspace，动态回调仍绑定宿主 |
| `ui/military_view_model.gd` | `ui/military_logistics_projection.gd`：运输显示 | 只读已提交模型、日期及名称查询；不保留世界引用 |
| `world_ext_atlas.cpp` | `world_ext_cell_luts.cpp`：逐格 enum/dyn/eco/weather LUT 与 bounce 字节编码；共享量化/signature 在 `world_ext_internal_cell_luts.h` | `encode_cell_luts` 签名、绑定不变；原 prev 状态仍归 `AtlasPipelineState`；颜色参数与贴图上传仍归 MapBaker |
| `rendering/resource_visual_geometry.gd` | `gdext/src/resource_visual_builder.h`、`gdext/src/resource_visual_builder.cpp`：纯值选择与单样式布局；`rendering/resource_visual_native_slice.gd`：单片段适配 | 原脚本算法保留作兼容路径及字节对照；预算、单格进度、发布顺序与状态归属仍在原宿主，大数组不跨帧持有 |
| `rendering/resource_visual_layer.gd` | `rendering/resource_visual_chunk_inputs.gd`：首次未知可见格的区域准备计数 | 只限制新任务创建，不取消进行中的任务；当前区域准备完成即可推进，不等待整图 |
| `rendering/bakers/terrain_baker.gd`、`terrain_index_baker.gd` | `geography/world_data.gd`：像素对象表、数值归属列与反向列表发布 | 原三处烘焙写入顺序与对象仍一致；数值列是可失效的显示派生数据，不进入存档 |
| `world_ext_bake.cpp` | `world_ext_bake_encoders.cpp`、`world_ext_bake_visual_tiles.cpp` | 成员函数原样迁移；声明、绑定、slot、对象所有者不变；无状态局部 helper 可复制 |
| `economy_runtime_persistence.cpp` | `economy_runtime_continuation_checkpoint.cpp` 汇集已有继续段；`economy_runtime_climate_checkpoint.cpp` 独占降雨继续段；`economy_runtime_restore_scratch.cpp` 清理读档候选所需的运行时暂存并使冻结输入缓存失效 | 继续段通过 `EconomyAuthorityTransfer` 访问 Economy 状态，解码和验证后再安装；scratch 仍是同一 `NativeEconomyRuntime` 的成员定义，安装与失败回滚顺序归原 persistence |
| `economy_runtime_country_epoch_capture.cpp` | `economy_runtime_country_cache.cpp`：科技可用性、领土索引与拓扑 hash 的精确输入复用、重建及输入报告；`economy_runtime_internal_country_cache.h`：私有缓存身份与诊断计数 | 原 capture 保留采样和准备顺序；缓存及结果归同一运行时，完整比较输入，新世界/配置 reset 与读档准备使其失效，不进入存档或业务 hash |
| `economy_runtime_family_buff.cpp` | `economy_runtime_family_effect_inputs.cpp`：领土查询、不可变标签快照、地理/家族/科技等指标准备、效果输入声明与测试输入覆盖 | 同一 `NativeEconomyRuntime` 成员定义；家族效果执行留在原文件，输入准备仍在原冻结边界，标签发布与读取的共享快照契约不变 |
| `economy_runtime.h` | `economy_runtime_test_access.h`：原生选择器及缓存测试的访问结构声明；`economy_runtime_country_cache_tests.cpp`：缓存输入与失效用例 | 仅测试实现与既有自测绑定实现包含测试声明头；运行时保留原 friend，脚本接口和业务状态布局不由测试头定义 |
| `world_ext_economy.cpp` | `world_ext_economy_topology.cpp`：交易地图、可见性绑定和输入采集缓存失效 | 只经公开 Economy 接口；调用者负责执行边界 |
| `ui/` 动态内容部件 | `ui_control_parts.gd` 与 `scenes/ui/parts/`：内建控件的类型与默认场景资源 | 数据、排列和回调仍归原组件；没有放宽禁止直接创建控件的检查 |
| `world_ext_generate.cpp` | `world_ext_generate_base.cpp`、`world_ext_season_refresh.cpp` | base 生成与季节阶段各自成文件；post-base/full/publish 留在入口，继续游标仍归同一个 DCWorldExt |
| `economy/technology_catalog.gd` | `economy/technology_catalog_validation.gd`：内容绑定与 support-only 建筑审核 | 只接收待编译行和绑定数组；编译顺序、缓存及错误结构仍归 catalog |
| `military/military_catalog_compiler.gd` | `military/military_catalog_support.gd`：装备消费集合与 PKMI catalog hash | 纯静态计算；原编译器保留 `slot_accepted_goods` / `unit_consumed_goods` 薄转发，目录编译与测试调用契约不变 |
| `economy_runtime_building_employment.cpp` | `economy_runtime_building_employment_metrics.cpp`：按 cell 替换已填岗位和失业汇总 | 同一 `NativeEconomyRuntime` 成员定义；只访问运行时已有指标数组，不新增调度或状态所有者 |
| `economy_runtime_colonization_kit.cpp` | `economy_runtime_colonization_cargo.cpp`：物资合并、排序、绑定建筑计划和返还货物 | 四个同一 `NativeEconomyRuntime` 成员定义原样搬迁；既有货物范围、建造消耗和市场写入顺序不变 |
| `military_core.cpp` | `military_core_store.cpp`、`military_core_personnel.cpp`、`military_core_commands.cpp`、`military_core_payroll.cpp` | 同一 MilitaryCore 的存储/查询、人员、命令和工资职责；共享无状态人员 helper 在 `military_core_personnel_internal.h`，有状态局部变量保持单一原职责所有者。采购范围和交战成员派生索引分别在 `military_core_supply_index.cpp`、`military_core_engagement_index.cpp` |
| `military_core_save.cpp` | `military_core_store.cpp` | 保存的驻军/部队位置链校验移到位置链所有者，完整校验体保持不变；保存入口仍先验证再安装，不扩展 PKMI 格式 |
| `military_core_procurement.inc` | `military_core_flight_sums.h`：单次采购使用的在途数量查询表 | 完整四字段键；只替换满足整数求和等价条件的排序查询，不决定采购顺序、不跨调用复用结果；原始行与原排序路径保留 |
| `native_simulation_host.h` | `native_simulation_host.cpp` | 主线程服务完成方法的实现移出公共头，公开签名和请求位行为不变；受控唤醒测试直接抽取该实现体 |
| `military_core_selftest.cpp` | `military_core_navigation_selftest.inc`、`military_core_performance_selftest.inc`、`military_core_payroll_selftest.inc` | 原导航/探路用例按原文移出，新性能用例仍由唯一 `self_test` 入口执行；共享 Sim 夹具不复制、不改变保存字段 |

## 后续修改与验证

- 新逻辑进入对应职责文件，不继续把公式或控件整理塞回入口。入口保留兼容调用，
  纯函数之间的调用留在模块内部，不持久保存调用方或另建可写业务副本。
- 传给显示助手的 Callable 必须绑定原接收者。不能因拆分改变信号接收者、序号分配、
  命令/保存顺序，或把跨帧的实时检查换成启动时捕获的值。
- `module_projection_boundaries_test.gd` 覆盖必达条件、当前代际、回调接收者、
  不消耗命令序号、显示副本隔离，以及天气数组和风场的发布顺序与旧值清理。
- 原生函数以原源码逐段字节对照；脚本以显式输入/回调替换后的函数体对照。
  同时运行长度与依赖检查、默认回归、重复运行一致与改前临时候选对照、保存恢复和相关显示测试。
  测试和审查已经发现的问题必须在更新 PR 前本地修好；与修改前对照只用于定位，
  不能作为留下失败的理由。不放宽检查、不删掉错误，也不用改后结果覆盖改前临时候选来掩盖问题。

## 800 行拆分

2026-11-26 的清单按现有行数检查的源码范围冻结，共 268 个当时超过 800 行的文件。
原有入口和数据所有者继续承担原来的职责。按符号名可以从入口定位到单独实现文件。

- 军事事件、侦察观察者、国家 AI 自测、理念切换和家族分支各有单独的 C++ 实现。存档解码、每日结算等需要同一作用域的步骤使用原位置引入的命名 `.inc`，保持局部变量和执行顺序。
- 地图装配由 `native_generation_sequence.gd` 承载，地块列写入和地形发布分别位于 `map_data_bake_arrays.gd` 和 `map_data_terrain_columns.gd`。时钟仍拥有日期和信号，逐帧推进归 `world_clock_frame_advance.gd`。
- `DCWorld` 的列读写、地图绑定、实体池和继续状态各有协作者。列类型在 `world_component_slot.gd`，列本身仍归原来的 World 实例。
- `MapGenerator`、`WorldRuntimeHost` 和需要保留原场景或资源字段的脚本沿用原入口。单层脚本基类让编辑器和存档继续使用原来的字段名称，游戏运行、界面和加载阶段的具体行为留在对应实现。
- 源码检查按原拥有者读取私有包含段。原有受限引用移到同职责文件时逐项核对来源和减少量。脚本引用也按方法、调用形式和原文件对照后登记。

## 扩大检查后的修复

以下十组检查现已全部接入默认回归。旧测试按照当前界面和物理输入契约修正；
实际运行缺漏在相应所有者修复。

| 用例 | 当前处理 |
|---|---|
| `era_advancement_panel_test.gd` | 跟随当前晋升条件目录；检查单一状态数字，继续要求文字只出现一次 |
| `player_controller_contract_test.gd` | 控制器改订阅时钟通知；音乐平滑由独立显示节点负责；保留本地人口与命令隔离检查并释放测试节点 |
| `inspector_live_patch_test.gd` | 加载卡检查底部安全区和水平居中；进度按 0..96% 生成阶段检查，仍拒绝较旧阶段倒退 |
| `building_visual_catalog_test.gd` | 补齐军事生产建筑的明确外观映射和 service 行业；未知生产类型仍不能猜测匹配，全部目录禁止默认匹配 |
| `vegetation_family_layer_test.gd` | 植被所有者删除时释放临时移出场景的节点；新增立即释放断言，退出不允许资源泄漏 |
| `veg_variant_parity_probe.gd` | 当前运行与预热源码逐字节比较；覆盖早期/完整世界、远景/近景、PC HIGH 和完整参数组合，保留同长度错误宏反例及桌面源码检查 |
| `visual_tile_native_bake_test.gd` | 不同地图使用相同物理坡度；扩大合法格网、避开海平面夹值与边界，保留 3/255 容差并检查理论倾角 |
| `web_water_pass_node_test.gd` | 固定 67 个参数和七张明确纹理，包括洋流；继续验证纹理预算、绑定和切换节点 |
| `family_workspace_ui_test.gd` | 正文使用真实 Regular；数字使用真实 Bold 字体，修复原本误接 Regular 的数字字体 |
| `ui_scene_structure_test.gd` | 检查当前菜单主题、纸质 HUD 和奖励树；共享基础控件从场景实例化（23 个脚本的 226 处调用仅替换构造方式，类型与其余语句逐项对照），禁止直接创建内建控件的检查继续生效，并修正误命中 ChipButton 的匹配边界 |

`era_advancement_service_test.gd` 补上时代推进服务的缺失用例，覆盖十次时代转换、
必达科技条件、采购量冻结与完成条件。`ideology_draw_flow_test.gd` 覆盖抽取失败后解除
操作锁、恢复时钟并显示原因，也检查权重配置无效时的提示。两组加入默认回归。

保存链路同时修复：

- 后台保存采用已验证的 Country 提交身份；不能用较旧的主线程 Country 阻挡它。
  捕获被拒绝时向请求者报告失败，保持执行器运行。
- 首次结算检查先于跨模块日期检查，后台和内联都稳定返回
  `save_requires_first_settlement`。受控开局测试连续拒绝两次，随后继续八日并成功保存。
- 两次结算之间也可能有未完成的计算。请求要求包含 ECP2 时，捕获被拒绝就拒绝整个存档。
  `economy_settlement_save_boundary_test.gd` 用真实保存请求验证拒绝后可继续结算和保存完整段。
- ECP2 60 的内部 OSOA 格式升为 4，新增块 13：当天已采样的降雨边沿和当时冻结的门槛。
  这些数据在下一次计算前会被读取，不能清零或重复采样代替；旧 OSOA3 明确拒绝。
- 启动执行器会再次安装 ECP2，现保留已经绑定到同一世界的交易地图，并使国家分组重新计算。
- 正式军事比较覆盖模块实际写出的 PKMI + MDJ1 完整段，避免拿原始 PKMI 与带尾部的段比较。

黄金回放首次严格复验还检出一次退出对象残留（账目与完整状态匹配）；共享测试退出入口
改为延后退出，让当前回调和局部所有者先释放。未删除泄漏检查，主回放随后连续三次通过，
表外三次及八场景回放也通过。此处只调整测试的退出顺序，不改变模拟或比较字段。
3650 日开局测试在启动后台前采集开局数据。场景就绪时后台可能已在结算，不能用此刻的查询
验证初始 40 人、食物建筑与创始家族。日后检查仍在实际结算提交后进行。

固定气候档 `climate_save_v9` 及其生成、校验脚本已于 2026-11-11 删除，原因是不再保留提交的快照基线；CLM2 续跑改由当场存读档的回放检查覆盖。
没有修改主黄金链、交易基线或放宽兼容检查。

## 本轮验证

2026-11-15 性能改造补充：经济黄金检查的人口和市场字段计算移到
`economy_golden.cpp`，字段顺序、计算方法与日期元数据保持原样；正式运行时从
实际持有完整数据的经济对象读取，纯数据测试仍读取其自身列。旧检查在开局交接前
读取部分镜像，可能随线程时机产生假差异。`GoodsBill` 私有类型及原友元声明
机械移到已有 `economy_runtime_internal_market_types.h`，不改变可见性和成员布局。

最初拆分阶段的源码对照确认 115 段搬迁内容、102 组常量、110 组原参数和 2,546 个
未搬迁函数保持一致；后续功能修复不再声称逐字节等同于拆分前行为。

本次提交前重新执行长度/依赖检查、默认回归（包含固定气候档和正式场景读档）、
相关显示与规则测试、重复黄金链、交易保存回放、八场景与真实年度续跑，以及 Debug/Release
构建和独立 Release 实载。实际结果在工作记录与 PR 中给出；命令整体通过才算通过。
其他平台构建、完整导出和实际画面对比不在本次本地验证范围内。

### 资源视觉职责

`ResourceVisualLayer` 保留配置、变化队列、预算、记忆与 chunk 生命周期；`resource_visual_geometry.gd` 承载不改变规则的实例选择/摆放/上传，`resource_visual_materials.gd` 承载 shader、纹理及样式绑定，`resource_visual_work_queue.gd` 管理稀疏队列与完整扫描进度。`MapData` 的只读统计和慢层查询由 `map_data_queries.gd` 实现，原接口保持。生成器的生物占领日志汇总移入 `map_generation/bio_occupancy_summary.gd`，原生写回入口仍留在 `terrain_gen.gd`。

### 加载期目录准备

- `economy_building_catalog_compiler.gd` 保留同步/协作公开入口，
  `economy_building_catalog_compile_steps.gd` 拥有唯一的建筑目录编译过程。
- `economy_carrying_catalog_compiler.gd` 拥有承载力目录列，EconomyCatalog 仍负责总目录组合。
- `effect_metric_keys.gd` 保留 Effect 与 C++ 对齐的稳定指标顺序；
  `modifier_catalog_stat_tables.gd` 保留科技与军事固定属性表的稳定顺序。
- `map_rules_initializer.gd` 接管 Effect 的加载编译与安装，`map_runtime_bridge.gd` 按原位置调用。
- `economy_facade_display.gd` 接管加载显示名称，状态继续归 EconomyFacade。

- `economy_facade_configuration.gd` 拥有经济冷配置的共同实现；Facade 保留同步与协作薄入口，显示目录准备归 `economy_facade_display.gd`，原生安装顺序不变。

- `loading_resource_request.gd` 只管理一个引擎异步资源请求的完成回收，与加载上下文/世界取消生命周期分离。

### Economy 保存头校验（2026-11-16）

`economy_runtime_persistence_read.cpp` 的保存头验证与候选列准备移入
`economy_runtime_persistence_header.cpp`；875行原方法体仅改变缩进，读取顺序、返回与
校验保持不变。原文件从3168行降至2291行，新文件896行。私有恢复声明归入既有
`economy_runtime_internal_operations.h`，不增加状态所有者或脚本入口。

### 移动端 PR 提交前的长度与依赖修复

本轮按现有职责拆分上游增长超限文件。公开脚本方法继续转发；协作者没有世界、
界面节点或任务状态的第二份所有权，也没有新增计时器、延迟回调或推进入口。

| 原入口 | 实现位置 | 保持的边界 |
|---|---|---|
| `audio/game_audio_service.gd`、`main/debug_tools.gd` | `audio/audio_backend_policy.gd`、`main/temperature_diagnostics.gd` | 平台选择与只读温度诊断；音频实例、设置和场景生命周期仍在原入口 |
| `narrative/narrative_event_catalog_war.gd`、`narrative_event_service.gd` | `narrative_event_catalog_war_pulse.gd`、`narrative_calendar.gd` | 事件注册顺序、内容和日历文字保持原样；脉冲包不拥有服务状态 |
| `rendering/shrub/scatter.gd` | `rendering/shrub/vegetation_colors.gd` | 只整理原有颜色选择；采样、随机数、预算和缓存仍归原层 |
| `technology/technology_network_validator.gd`、`trigger/trigger_catalog.gd` | `technology/technology_network_presentation.gd`、`trigger/trigger_research_definitions.gd` | 说明文字与研究触发目录；校验顺序、目录编号和规则不变，共用常量仅保留一份定义 |
| `ui/cell_inspector/{construction,object_dossiers,population_market}.gd`、`cell_inspector_view_model.gd` | 同目录 `construction_recipes.gd`、`building_dossier.gd`、`population_presentation.gd` | 配方、建筑卷宗、需求分组和 GDP 显示；输入仍由原宿主提供 |
| `ui/components/colonization_planner_{panel,presentation}.gd` | 同目录 `colonization_planner_labels.gd`、`colonization_preview_cards.gd` | 原提示和预览卡构造；信号、选择、命令、动画回调仍绑定原面板 |
| `ui/components/{inspector_panel,narrative_event_dialog,object_detail_dialog}.gd` | 同目录 `inspector_structure.gd`、`narrative_chapter_style.gd`、`dossier_ledger_facts.gd` | 显示结构签名、纸签样式和账目文字，原公开入口保留 |
| `ui/{country_view_model,icon_catalog,game_ui_manager,main_menu}.gd` | `military_maintenance_presentation.gd`、`paper_building_icon.gd`、`game_ui/touch_metrics.gd`、`main_menu_layout.gd` | 维护显示、图标选择和现有布局计算；布局协作者每次借用宿主，不捕获节点 |
| `economy_runtime_colonization.cpp` | `economy_runtime_colonization_{store,queries,payload}.cpp` 与 `economy_runtime_colonization_internal.h` | 同一运行时的存储、查询与人口迁移定义；无状态工具保持原算法，预留目标人口槽的重复遍历合并，失败时停止或继续的策略由原调用方明确传入 |
| `runtime_economy_family_side_tables.h` | `runtime_economy_person_store.h` | 人物列和人物需求遍历从家族专用声明中分开；仍由同一 `RuntimeEconomyOwnedState` 持有，字段顺序和登记编号不变。载荷自己提供按归属分组的人数，审计不再解释载荷标志 |
| `economy_runtime_trade.cpp` | `economy_runtime_trade_settlement.cpp` | 收付款、到货和发运的原成员定义；计算次序、舍入与账目不变 |
| `economy_runtime_persistence_read.cpp` | `economy_runtime_persistence_lineage.cpp` | 家族与人物保存段的原解码分支；调用方仍持有游标、版本检查与末尾长度检查，不改变保存格式 |
| `economy_runtime.h` | `economy_runtime_internal_arithmetic.h` | 原内联金额算法，仅移动定义位置，保持内联与极值处理 |

长度基线只收紧，跨模块引用的搬迁使用检查器登记来源，原引用同步减少。
改前和改后对照、编译与运行结果见 `feature-status.md`。
