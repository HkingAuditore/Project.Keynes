# 开发指南

先读 [current-state.md](current-state.md) 和 [design.md](design.md)，确定数据所有者、运行线程和真正的提交点；边界规则见 [module-boundaries.md](module-boundaries.md)。目标接口不是已有 API。

所有命令从仓库根目录运行；Python 用 `/Users/herh/.local/bin/python3`，Godot 用 `/opt/homebrew/bin/godot`。日志目录必须是新目录。

改到具体功能（地形起伏、经济平衡、天气/光照 Shader、时代晋升、军事界面、GM 屏蔽、科技节奏、军需市场）时，另读 [专项开发约束](feature-guides.md) 的对应小节。

## 改一个模块

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
- 首次结算前的保存拒绝不能终止执行器。`startup_save_boundary_test.gd` 固定首次输入尚未送入的开局，分别验证后台和内联的两次拒绝、八日继续和之后的正常保存。正式场景 ready 可能已完成首次结算，不能用 ready 信号推断尚未结算。
- 已开启 ECP2 捕获时，整份保存要求经济段捕获并编码成功。`economy_settlement_save_boundary_test.gd` 在首次成功结算后停在下一轮计算中，验证原生请求返回 `save_requires_committed_boundary`，原执行器和经济状态保留，结算完成后可重试并获得完整存档。
- ECP2 60 的内部 OSOA4 块 13 保存 `_cell_rain_event_q16` 和 `_epoch_cell_rain_event_threshold_q16`；已采样但尚未开算的当天也可能是合法边界，恢复不能以零值代替。`economy_cadence_runtime_test.gd` 检查完整块、旧版本/未知块/非法值/形状及失败原子性；正式读档检查后续完整结算。
- 固定气候档候选用 `capture_climate_archive.py --godot … --candidate <新目录> --log-dir <新目录>` 生成并验证，再审查安装；默认回归只读固定样本，不自动更新。旧内容拒绝用 `legacy_catalog.pkcm` 覆盖。不得把候选的通过与真实旧版兼容混为一谈。
- `PlayerController` 订阅时钟通知并在重新配置时解除旧订阅；音乐的逐帧平滑归 `audio/music_situation_playback.gd`。弹窗屏蔽只释放已知来源的自动暂停；手动、保存和故障暂停继续生效，见 `player_clock_event_test.gd`。
- 手动推进后台日的测试必须同时运行生产的结果接收步骤。`ideology_save_worker_authority_test.gd` 在等待中调用宿主的 `_service_runtime_liveness`，日提交后再接收一次结果，然后重建逐格效果。只等待后台日期变大、不接收新快照，会把旧的主线程显示状态误判为业务失败；不能靠增加天数或放宽比较掩盖。

## 会话与宿主脚本

- 会话扩展用 `WorldRuntimeHost.register_session_module`（`world_session.gd` 管准备、取消、关闭）；保存扩展用 `game_save_coordinator.gd` 的 `register_state_module(provider, restore_after)`。
- `world_runtime_host.gd` 只保留公开入口、信号和状态转发；生成/恢复、日推进、GM/录制、视觉查询、生命周期在 `world_runtime_generation_adapter.gd`、`world_runtime_daily_adapter*.gd`、`world_runtime_gm_adapter*.gd`、`world_runtime_visual_adapter.gd`、`world_runtime_lifecycle.gd`。策略重启也由生命周期组件执行，必须等执行器真实退出，并传回捕获或启动失败。
- 组件只接收窄 Callable/RefCounted 依赖，不持有整个 host，不建立第二个日推进入口。传给信号和存档服务的回调必须是 host 绑定的 Callable，不能是组件自身的未绑定方法。停止顺序：先停执行器、等 `simulation_executor_exited`，再释放资源。

## Skills

各智能体目录（`.agents`、`.claude`、`.codex`、`.cursor`、`.dsh`、`.codebuddy`）下的 `skills/` 是同一批 skill 的副本，`.agents/skills` 是权威副本。改 skill 时改权威副本，再运行 `tools/ci/check_skill_mirrors.py --sync <skill>` 覆盖其他已有该 skill 的目录；某个目录可以不带某个 skill。

现有分歧冻结在 `tools/ci/skill_mirrors_baseline.json`（每个文件的不同版本数），`check_skill_mirrors.py` 拒绝新增分歧和版本数增加。多数分歧文件是各副本分别改过的真分叉，`--sync` 前先把其他副本独有的内容合并进权威副本；合并后用 `--write-baseline` 收紧。

## 环境开关与故障点

1. 在 `runtime_switch_registry.h` 的 `RuntimeSwitch` 枚举加键，在 `.cpp` 的 switches 数组同位置填名称、未设置行为、作用、是否仅诊断。
2. 用 `pk::runtime_switch_value(pk::RuntimeSwitch::PK_名称)` 取原始字符串，在调用处显式解析；不直接 `getenv`。
3. 新故障名加入 faults 数组，在既有合法边界调用 `try_fault_injection`。
4. 文件型诊断开关（如 `PK_SIM_DAY_TRACE`）只接受绝对路径；测试前后会检查新增的非源码文件，有就失败。

## 机械搬迁与拆分

已接入的脚本助手和原生生成/烘焙文件见 [源文件职责拆分](source-module-splits.md)。
晋升条件、命令参数检查、显示模型、资源构造、HUD 排版与诊断各有明确入口；
助手只接收对应输入或原接收者绑定的 Callable。抽出函数时除函数体外还要核对参数名、
返回类型、默认值及实际传参，逐个脚本做 `--check-only`，不能只依据编辑器导入成功。

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

静态护栏（默认回归会先跑；PR 上由 `runtime-checks.yml` 的 `architecture-guards` 自动运行）：

```bash
cd tools/ci && for g in check_size_ratchet.py check_cpp_deps.py check_cross_domain_inventory.py check_runtime_advancers.py check_runtime_switches.py check_committed_views.py check_save_contracts.py check_module_contracts.py check_resolve_apply.py check_module_api.py check_skill_mirrors.py check_module_map.py world_ext_bindings.py test_architecture_guards.py; do /Users/herh/.local/bin/python3 $g >/dev/null 2>&1; echo "$g exit=$?"; done
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

## 运行回归与内容变化

诊断开局使用 `bootstrap/test_start_policy.gd` 明确声明的建筑和科技；商人根使用早期商栈，主科技满足任一项、辅助科技必须全部满足。`building_placement_catalog.gd` 只投影目录，校验辅助科技列长度/范围，不读取运行状态；`bootstrap_catalog_contract_test.gd` 覆盖主/辅助要求和后期建筑拒绝。对诊断开局的长跑须按该政策配置国家，授予全科技会让未列入开局方案的产业参与后续投资。

技术交接测试须提供当前目录里的研究前置，并先处理初始科技效果；同时保留缺前置拒绝、不消耗科研点、无交接请求的反例。经营用例区分业主生活费与真实维护成本，成对检查零成本不凭空亏损、真实维护记入经营支出，保留守恒检查。

思想输入变动须运行 `runtime_opinion_input_lifecycle_test.gd`，检查后台/inline 的缺输入、复用对象读档后的实际意见日期和版本、受控输入，以及再次读档时旧接收记录清理。`ideology_social_media_worker_test.gd` 保留低意见下限、1.4 倍人口点数和真实 Effect 确认后的撤销检查；人口探针给所有阶级加过人口，撤销前须恢复实际阶级分布，满足当前内容的撤销支持条件。手动推进测试用 `wait_for_runtime_day` 等待已提交的实际日期，并接收宿主的后台请求和结果；不能用观测后的“再下一天”作完成条件。

复用已有对象读档，须先准备有效 PKSR、恢复各所有者和地图输入，再启动执行器。停止后的恢复输入按存档日期暂存，不进入旧世界队列；启动从暂存副本重建队列，不能让旧队列的较新输入遮住它。上述用例覆盖无存档时拒绝旧日期、旧队列满、恢复后第一次继续及重复读档。

内容和公式更新后的保存字节、整份经济及回放对照不能直接沿用旧值。`check_intent_baselines.py --capture-candidate --runs 5` 只收集候选并逐字段比较重复结果，保留原断言、完整回执、保存前后字节摘要与继续状态；`test_regression_evidence.py` 拒绝脚本错误、零退出码失败、泄漏、丢记录及重复记录。审查差异并安装候选后，去掉捕获开关重新核查。

负例主动调用会打印错误的公开拒绝入口时，只能在 `EXPECTED_ERRORS` 按夹具登记完整且唯一的错误行；遗漏、重复、其他错误和泄漏仍失败。参数覆盖夹具的无效堆叠上限用例保留其原始拒绝调用，证据测试覆盖这条例外的边界。

## 黄金基线维护

- `tests/runtime/golden_day_hash_test.gd`：seed=20260727、40×28、无外国、正式开局，固定日序 1..8，无玩家命令。每次等同日提交（worker 无在途日任务、Modifier 已消费相同 generation）后取值，不靠睡眠。
- 正常运行读 v4 `golden_day_hash_baseline.json`，同时核对当前内容的 v2/v3；v5 在 `golden_external_advancers_baseline.v5.json`。v1 文件保留作历史记录。
- 更新基线：先保留旧结果并解释业务变化，用同一二进制 `--capture-candidate` 连续至少 5 次逐日逐域比较，人工审查新旧取值，建立后跑 `--runs 10`。不能删字段、改种子或删失败样本拼连续次数。捕获模式允许暂不核对旧 v2/v3/v4 内容；普通运行仍逐项核对全部投影。既有内容/数值变化必须单独登记，架构迁移不允许改变五条链。
- 诊断开关：`PK_GOLDEN_CAPTURE=1` 只打印结果；`PK_GOLDEN_DIAGNOSTICS=1` 打印初始化资源列与每日完整经济哈希；`PK_GOLDEN_COUNTRY_TRACE=<绝对路径>` 记录 Country 原始列。

## 性能验证

无界面录制：`godot --headless --path Project/project-keynes --script res://tests/game/headless_perf_record.gd -- days=N speed=50 seed=… width=60 height=40 …`，产出 `tmp/perf_record_*.csv`。结果行是 `[headless-perf/result] … run_ms=… ledger_failures=… fatal=… rows=… expected_rows=… path=…`。有效运行要求 `fatal=false`、`ledger_failures=0`、`rows=expected_rows`；exit 9 只表示 M7 吞吐门槛（≥50 日/秒）没过，不使结果无效。

模拟在 worker 上跑时 `t_sus_ms` 恒为 0，不能用来比较。看这三项：结果行的 `run_ms`；CSV 中 `runtime_graph_worker_time_execute_us` 末行减首行（worker 实际执行时间）；`sched_day_total_ms` 的均值/p95/最大值（每日墙钟）。比较两个版本时，用两个检出（旧版本用 `git worktree` 建、构建并 `--import`），同参数交替运行至少 3 轮，各用独立 `HOME`，取中位数；单次噪声很大。

## 交付要求

- 同步更新本目录对应页面；区分源码核查、构建、无界面运行、图形和其他平台验证。拆文件不是所有权迁移完成。
- 报告里写实际跑过的命令和输出；未跑的写明未跑。构建改动了被追踪的二进制时列出来，不用版本还原覆盖现场。
