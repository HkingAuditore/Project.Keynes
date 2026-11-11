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

## GM 屏蔽与叙事弹窗

- GM 的 `ui.suppress_popups` 必须同时阻止事件/年报/时代奖励/家族创立/理念抽取流程进入暂停展示路径，并在运行时切换时清理已锁定弹窗；新增 UI 屏蔽开关应经 `gm_toggle_changed` 接入 PlayerGame，由 `GameUIManager` 保存并恢复层可见性，GM 面板保持可用。
- 叙事自动选择/确认未取得弹窗暂停锁时不得恢复 `_was_paused` / `_previous_speed`：它们可能是默认值或上一事件的快照。`NarrativeEventFlow` 仅在持有 `locked` / `reopen_pending` 时登记恢复，`restore_pending` 消费一次；其他弹窗忙碌时延后释放。回归入口：`tests/game/narrative_popup_suppression_test.gd`，覆盖连续事件、手动暂停、倍速、运行中切换屏蔽、读档弹窗和故障锁。

## 科技内容节奏审计（2026-11-08）

新建或再平衡科技解锁前，先阅读 `docs/architecture/design.md` 和本指南，明确目录仍归 `technology_network.json`、建筑/物资/自然资源仍归各自 Profile，科技路线只负责研究资格，建筑完整门槛由直接科技与 `required_technology_tags` 合并而成。不要以应用交汇卡、目录标注时代或软投入伪造硬解锁。

全量审计使用 `Project/project-keynes/tools/technology_tree/rebalance_content_pacing.py`，审查416个稳定科技ID与459建筑、167物资、31自然资源的绑定和理论生产闭包；完整逐项决策及变化前后时代计数见 `Project/project-keynes/tools/technology_tree/technology_content_pacing_audit.md` 与 `content_pacing_revision.json`。本轮石器/农耕研究从75/67调整到56/51，王国/帝国为57/43；没有加入运行时时代锁或新的运行时信号。

核查顺序：Godot `build_technology_network_authoring.gd` 规范化；`run_content_pacing_checks.py` 串行运行 design、binding、closure、construction、industry、catalog、research、activation、application 测试；运行离线9个负例测试；成功后用 `--refresh-manifest` 刷新稳定目录指纹，生成并 `--check` 科技树报告。每次修改科技绑定后都重做全量闭包；逐时代同代假设不足以证明直接先修祖先可达。

## 部队指挥 UI（2026-11-08）

预览草稿归 `PlayerController`，命令仍走军事 facade；`MilitaryDossier` 固定指挥区通过 `GameUIManager.update_military_arm_order` 事件更新。确认前重验路径，失败保留草稿，每日只写值。交互与验证边界见 `docs/ui/military-army-controls.md`。

## 军需市场需求（2026-11-08）

军事缺货预测走 Military intent 17 → Economy opcode 36 的既有 D+1 命令桥。每批先 reset 再按真实 SKU/市场格写入缺口；不要伪造销售、消费、财政扣款或库存。Economy 在 epoch 冻结时核对国家句柄、归属与可用国库资金，扣除其他公共采购承诺，并按 10 天窗口折算到通用采购需求。最新快照复用已保存/哈希的 pending command 队列，派生日需求缓存不入档，不增加保存 schema。验证入口：`tests/runtime/military_procurement_demand_test.gd`、`military_procurement_pod_test.gd`。
