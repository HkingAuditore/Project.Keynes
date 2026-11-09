# 开发指南

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

## 会话与宿主脚本

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

- 会话扩展用 `WorldRuntimeHost.register_session_module`（`world_session.gd` 管准备、取消、关闭）；保存扩展用 `game_save_coordinator.gd` 的 `register_state_module(provider, restore_after)`。
- `world_runtime_host.gd` 只保留公开入口、信号和状态转发；生成/恢复、日推进、GM/录制、视觉查询、生命周期在 `world_runtime_generation_adapter.gd`、`world_runtime_daily_adapter*.gd`、`world_runtime_gm_adapter*.gd`、`world_runtime_visual_adapter.gd`、`world_runtime_lifecycle.gd`。
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
```

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

## 部队指挥 UI（2026-11-08）

预览草稿归 `PlayerController`，命令仍走军事 facade；`MilitaryDossier` 固定指挥区通过 `GameUIManager.update_military_arm_order` 事件更新。确认前重验路径，失败保留草稿，每日只写值。交互与验证边界见 `docs/ui/military-army-controls.md`。

## 军需市场需求（2026-11-08）

军事缺货预测走 Military intent 17 → Economy opcode 36 的既有 D+1 命令桥。每批先 reset 再按真实 SKU/市场格写入缺口；不要伪造销售、消费、财政扣款或库存。Economy 在 epoch 冻结时核对国家句柄、归属与可用国库资金，扣除其他公共采购承诺，并按 10 天窗口折算到通用采购需求。最新快照复用已保存/哈希的 pending command 队列，派生日需求缓存不入档，不增加保存 schema。验证入口：`tests/runtime/military_procurement_demand_test.gd`、`military_procurement_pod_test.gd`。
