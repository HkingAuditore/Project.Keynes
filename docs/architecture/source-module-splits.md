# 源文件职责拆分

本轮处理长度检查发现的 19 处增长超限。没有修改 600/800/2000 行默认限制，
也没有增加任何历史豁免；17 个已有登记只收紧或删除，另外两处回到 800 行以内。
历史大文件仍按已登记大小只能变小，本轮通过检查不表示这些文件都已达到默认限制。

以下是已接入的实现位置。脚本路径相对于 `Project/project-keynes/scripts/`，
C++ 路径相对于 `gdext/src/`。

| 入口 | 抽出的职责与实现 | 输入、状态和回调边界 |
|---|---|---|
| `era/era_advancement_service.gd` | `era/era_advancement_conditions.gd`：晋升条件与文字 | 只读科技、经济、领土和贸易数；订单冻结、收购及保存仍归 service |
| `game/player_controller.gd` | `game/player_command_validation.gd`：命令标识、参数检查、税率解析与结果结构 | 每次传当前代际和指定查询回调；序号分配、提交和结算仍归 controller |
| `geography/map_generator.gd` | `simulation/runtime_climate_hash.gd`：气候摘要编码 | 只抽出字节编码和摘要转换；目录/地图缓存与发布时点不变 |
| `geography/world_clock.gd` | `diagnostics/world_day_cost_probe.gd`：日耗时桶与报告 | 探针独占诊断状态，原入口和属性转发；不推进或暂停时间 |
| `main.gd` | `diagnostics/daily_simulation_breakdown.gd`：每日报告格式 | 保留既有只读诊断查询，不保存 generator，不增加推进入口 |
| `rendering/building_visual_layer.gd` | `building_visual_assets.gd`：网格、材质与宏观索引字节 | 无场景/仿真状态；原生建筑缓存、上传顺序和可见性仍归原层 |
| `rendering/hex_renderer.gd` | `detail_profile_selection.gd`、`renderer_weather_inputs.gd`、`renderer_lighting_bindings.gd`、`renderer_map_assets.gd`、`renderer_sea_ice_diagnostics.gd` | 分别负责档位选层、天气数组、光照绑定、共享资源和诊断；只接收对应数据、节点或绑定到 renderer 的回调 |
| `rendering/map_baker.gd` | `map_material_assets.gd`：共享地形材质和噪声资源 | 无世界继续态；烘焙、运行期缓冲、纹理上传时点不变 |
| `rendering/military_army_token_layer.gd` | `military_token_lod.gd`：缩放切档与名称 | 纯函数；切档状态、动画和节点仍归 token layer |
| `rendering/resource_visual_layer.gd` | `resource_shader_variants.gd`、`resource_instance_plan.gd` | 分别负责运行/预热着色器来源、资源形态与稳定实例筛选；情报记忆和几何缓存仍归原层 |
| `rendering/shrub_layer.gd` | `vegetation_shader_variants.gd`：植被着色器变体与预热来源 | 原始源码与前缀保持一致；编译缓存仍只有原层持有 |
| `rendering/vegetation_family_layer.gd` | `vegetation_family_style_lut.gd`：家族样式纹理 | 从现有 profile 编码；批次、LOD 和阴影上传仍归原层 |
| `ui/cell_inspector_view_model.gd` | `ui/family_workspace_projection.gd`：家族档案显示模型 | 从显示行副本整理，不更改家族状态；去重保留不同分支 |
| `ui/components/inspector_panel.gd` | `inspector_category_patch.gd`：对现有控件写值 | 接收指定控件和宿主绑定回调；建节点、信号接收者和对象生命周期不变 |
| `ui/components/military_workspace.gd` | `military_table_rows.gd`：兵营、训练、部队、运输表格 | 只接收对应表格和显示行；选择、信号和命令操作仍归 workspace |
| `ui/game_ui_manager.gd` | `ui/game_hud_layout.gd`：HUD 排版和地图安全区 | 每次刷新借用的独立控件；仅独占排版诊断标记，不持有整个 manager |
| `ui/military_view_model.gd` | `ui/military_logistics_projection.gd`：运输显示 | 只读已提交模型、日期及名称查询；不保留世界引用 |
| `world_ext_bake.cpp` | `world_ext_bake_encoders.cpp`、`world_ext_bake_visual_tiles.cpp` | 成员函数原样迁移；声明、绑定、slot、对象所有者不变；无状态局部 helper 可复制 |
| `world_ext_generate.cpp` | `world_ext_generate_base.cpp`、`world_ext_season_refresh.cpp` | base 生成与季节阶段各自成文件；post-base/full/publish 留在入口，继续游标仍归同一个 DCWorldExt |

## 后续修改与验证

- 新逻辑进入对应职责文件，不继续把公式或控件整理塞回入口。入口保留兼容调用，
  纯函数之间的调用留在模块内部，不持久保存调用方或另建可写业务副本。
- 传给显示助手的 Callable 必须绑定原接收者。不能因拆分改变信号接收者、序号分配、
  命令/保存顺序，或把跨帧的实时检查换成启动时捕获的值。
- `module_projection_boundaries_test.gd` 覆盖必达条件、当前代际、回调接收者、
  不消耗命令序号、显示副本隔离，以及天气数组和风场的发布顺序与旧值清理。
- 原生函数以原源码逐段字节对照；脚本以显式输入/回调替换后的函数体对照。
  同时运行长度与依赖检查、默认回归、黄金回放、保存恢复和相关显示测试。
  对修改前已失败的额外用例，使用同一提交的独立检出复跑，保留两边诊断；
  不通过放宽断言、删除错误或重录行为基线来通过。

## 扩大检查中的既有失败

修改前 `c5c9e299` 的独立检出与修改后各跑相同用例，下面十组的错误结果和
完整错误行逐项一致。它们保留失败状态，没有算作通过；另外三组排版/刷新/家族浏览
对照均通过。探针引用的旧浏览器指纹也未被更新。

| 用例 | 两边相同的问题 |
|---|---|
| `era_advancement_panel_test.gd` | 旧晋升文案断言与缺失的 `progress_text` |
| `player_controller_contract_test.gd` | 逐帧更新约束、派遣名称与人口文字，及退出资源未释放 |
| `inspector_live_patch_test.gd` | 加载卡居中与较旧阶段的进度回退 |
| `building_visual_catalog_test.gd` | 建筑目录仍有未匹配显式外观规则的类型 |
| `vegetation_family_layer_test.gd` | 16 项功能断言通过，退出仍报告相同资源未释放 |
| `veg_variant_parity_probe.gd` | 当前源码与固定旧浏览器指纹不一致 |
| `visual_tile_native_bake_test.gd` | 地图边界尺寸的法线比较仍为 ref=-0.146431 / got=-0.103137 |
| `web_water_pass_node_test.gd` | 旧紧凑变体断言期待的 uniform/sampler 数已过时，两边同为 67/7 |
| `family_workspace_ui_test.gd` | 家族正文显式加粗的旧字体断言 |
| `ui_scene_structure_test.gd` | 按下材质投影、HUD 内容空间与主菜单主题等旧结构断言 |

默认命令的 71 个脚本全部通过，但其附带的固定气候档检查仍失败；额外的
`--roundtrip` 正式场景检查也失败。这两项同样在修改前独立检出复现：

- `climate_save_v9/day2.pksv` 被当前 Modifier 目录校验拒绝，原因同为
  `modifier_restore_catalog_mismatch`，未更新存档样本或降低校验。
- 开局首次经济结算前保存，后台同在第 1 日报告两次
  `save_requires_idle_country_runtime` 并进入故障状态，随后九项保存/命令断言失败。
  两边故障行和失败断言逐项一致。此正式保存问题仍待单独修复。

因此，默认命令整体保留退出码 1，不能把脚本通过数写成整条命令通过。

## 本轮验证

macOS arm64 / Godot 4.6.3，无界面运行：

- 996 个源文件，长度违规 0；C++ 依赖仍为 522 个引用键/399 个债务键，
  暴露 519、总计 2181。12 组检查通过，含 33 项架构测试和 9 项证据测试。
- debug/release 串行构建，debug 最后交付；指定 release 库独立实载六组，
  合计 1,164 项检查全部通过，实载文件摘要与交付文件一致。
- 39 个变更/新增脚本分别解析通过。115 段搬迁内容（含字面量）、102 组常量、
  110 组原参数及 2,546 个未搬迁函数均保持一致。
- 71 个默认脚本与 17 个相关脚本全部通过；新增边界脚本含 28 项检查。
  另有 12 个扩大检查脚本通过。上节十组及两个正式保存检查保留失败，
  与修改前版本对照一致；未通过放宽断言或重录行为基线来通过。
- 主回放、表外回放各连续 3 次，七类交易保存各 3 次，共 21 次通过。
  完整八场景保存续跑 8/8，每场景四条轨迹逐日一致；10 日单场景、
  16 日年度自动保存及 365 日年度保存亦通过，载入后至少继续八日。

复审覆盖参数与默认值、实际传参、回调接收者、缓存和状态所有者、共享 helper、
编译与脚本依赖、保存及每日继续。未发现本次拆分引入的可确认新问题。
本轮未做其他平台构建、完整导出和实际画面对比。
