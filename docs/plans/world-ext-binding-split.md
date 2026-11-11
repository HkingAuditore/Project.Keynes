# DCWorldExt 绑定面按模块拆分方案

状态：阶段 0 已完成（2026-11-10），阶段 1 已实现（2026-11-11），阶段 2 第 1–2 步已实现（目录登记、护栏和基线），第 3–5 步及阶段 3 未实施。验证见 `docs/architecture/feature-status.md`。本页保留目标与步骤；现状以 `docs/architecture/current-state.md` 和代码为准。不涉及玩法。

## 要解决的问题

脚本访问原生运行时只有 `DCWorldExt` 一个类。C++ 内部已有 `economy_api.h` 这类模块门，脚本一侧没有对应的门：

- 任何模块加一个脚本接口，都要改同一个 `world_ext_bind_methods.cpp` 和同一个 `world_ext.h`，并行修改必然冲突。
- 从脚本看不出一个文件依赖哪些模块，改一个绑定的影响范围只能全仓搜索。
- facade 把世界对象存成无类型的 `Object`，靠 `has_method` 逐个探测接口是否存在，同一功能留着“有绑定 / 没绑定”两条分支。

## 现状度量

以下为拆分前度量：当时解析 `world_ext_bind_methods.cpp` 的 `D_METHOD`，按成员函数的定义文件归组；脚本侧按 `.方法名(` 和 `"方法名"` 匹配 `Project/project-keynes` 下的 `scripts`、`tests`、`addons`。按名字匹配会有少量同名误计，量级可信。

| 项 | 数值 |
|---|---|
| 绑定方法 | 663 个，全在一个 `_bind_methods()` 里（1651 行）；没有改名绑定、静态方法、信号或属性 |
| `DCWorldExt` 数据成员 | 约 303 个；`world_ext.h` 4117 行 |
| 按定义文件归组 | economy 115、country 95（含年报、国家 AI）、runtime 82、climate 82（含天气、物理海洋、季节、生物）、core 52、effect 38、modifier 37、military 32、generation 31、ideology 30、trigger 24、visual 16、demo 16、events 13 |
| 调用方（正式脚本） | 共 92 个文件；59 个只碰 1 组，33 个碰 2 组以上；`map_generator.gd` 碰 12 组 |
| 调用方（测试） | 245 个测试直接实例化 `DCWorldExt`；economy 174、country 181、modifier 113 个测试文件直接调对应绑定 |
| 字符串引用 | 正式脚本 507 处、测试 442 处（`has_method("x")`、`call("x")` 等） |
| 可能无人使用 | 52 个绑定在脚本、测试、插件里都没有引用；另有 155 个只被测试引用；demo 组 16 个只被 `main.gd` 使用 |
| 镜像项目 | `Project/perf-validation` 加载同一个扩展，绑定改名会同时影响它 |

两个结论决定了方案的形状：

1. **绑定在 C++ 侧已经按文件分好组**，缺的只是把这个分组变成机检的边界。
2. **调用方的大头是测试和字符串引用**。直接把方法搬到新的 Godot 类并改名，要同时改约 250 个测试、近千处字符串引用和镜像项目，风险和收益不成比例。

## 设计决定

不一步拆成多个 Godot 类。分四个阶段，前三个阶段不改任何绑定的名字和签名，每个阶段单独可交付、可回退：

| 阶段 | 内容 | 改不改脚本可见接口 | 性质 |
|---|---|---|---|
| 0 | 清点：绑定清单生成器 + 删除确认无用的绑定 | 只删无人使用的 | 小，需逐个核对 |
| 1 | 绑定文件按模块拆开，加归属护栏 | 不改 | 机械，可外包 |
| 2 | 脚本侧的模块门：facade 成为唯一入口 + 一次性接口握手，替换 `has_method` 探测 | 不改 | 机械为主，探测分类需判断 |
| 3 | 原生侧拆类：只对状态已经独立的模块做 | 新增类，旧方法保留转发直到调用方迁完 | 设计工作，按模块逐个立项 |

阶段 3 放在最后，是因为新类只有在它自己持有状态时才有实际意义；在状态还留在 `DCWorldExt` 的 303 个成员里时，新类只是多一层转发。

## 阶段 0：清点

1. 新增 `tools/ci/world_ext_bindings.py`：解析绑定文件和 `world_ext*.cpp`，输出每个绑定的名字、参数个数、定义文件、所属模块；模块由“定义文件 → 模块”的表决定，表放在 `tools/ci/world_ext_binding_modules.json`。未归组的文件报错。
2. 新增 Godot 无界面脚本 `tests/runtime/dump_world_ext_bindings.gd`：用 `ClassDB.class_get_method_list("DCWorldExt")` 导出名字、参数名、参数类型、默认值个数、返回类型，排序后写成 JSON。这份导出是后续每个阶段的等价性判据。
3. 复核 52 个无引用绑定和 demo 组：在镜像项目、`tools/`、插件和文档里再搜一遍，确认无人使用的连同 C++ 实现一起删除；拿不准的保留并在清单里标注原因。
4. 把 155 个只被测试引用的绑定在模块表里标成 `test_only`，本阶段只标注不移动。

完成标准：清单生成器可重复运行且结果稳定；删除后导出的方法列表只少了被删的那些；静态护栏、两种配置构建、黄金五链通过。

### 阶段 0 结果（2026-11-10）

- 清单生成器 `tools/ci/world_ext_bindings.py`：默认模式检查模块表（每个定义文件恰属一个模块、表中文件存在、标注的名字仍是绑定），已加入 `run_regression_checks.py` 和 PR 的 `architecture-guards`；`--json` 输出清单，`--refs` 附引用计数，`--audit` 另要求 `test_only` 和 `keep_unreferenced` 与当前引用一致（要扫描镜像项目和 `tools/`，不在 PR 护栏里跑）。解析结果与 Godot 导出的参数名、默认值个数逐个一致。
- 方法列表导出 `Project/project-keynes/tests/runtime/dump_world_ext_bindings.gd`。
- 复核结果：上面的 52 个“无引用”里，19 个仍被 `Project/perf-validation` 调用（async_climate、demo/bench 一组），33 个在任何地方都没有调用方。
  - 删除 14 个绑定及其 `DCWorldExt` 实现：气候四个从未接入的并行/SIMD 变体（`run_albedo_pass_thread`、`run_climate_feedback_pass_thread`、`run_vegetation_dynamics_pass_thread`、`run_ocean_land_pass_simd`），三个 `write_*_scalar_indexed`，两个 `get_native_fronts_snapshot*`，旧档迁移 `begin_economy_restore_pkec_migrate`、`migrate_legacy_state_buildings`（存档兼容按尽力而为处理，不做迁移），`run_economy_fixed_math_probe`，旧的 `publish_runtime_climate_reference`（脚本用的是 `_state` 版本），`submit_country_worker_result` 包装。随之成为死代码的 `NativeEconomyRuntime::{begin_restore_pkec_migrate, migrate_legacy_state_buildings, fixed_math_probe}` 和 `economy_api::migrate_legacy_state_buildings` 一并删除。
  - 只解除绑定、保留实现 3 个（C++ 内部仍在调用）：`settle_split_authority_effects`、`run_bake_coast_sdf_pass`、`async_climate_shutdown_all`。
  - 保留 16 个并在 `keep_unreferenced` 写明原因：DataCore 基础查询 5 个、成对的复位/启停接口 4 个、军事 6 个、`invalidate_atlas_csr_cache` 1 个。其中 `set_military_ration_satisfaction`、`get_military_cell_*` 在文档或注释里被描述为在用，`invalidate_atlas_csr_cache` 的注释称地图重生成时会调用，但都没有调用方，可能是漏接，交给对应所有者核实。
- `test_only` 实际是 150 个（正式脚本不调用、测试调用；镜像和工具的引用不算正式调用）。上面度量表的 155 是旧口径。
- 绑定数 663 → 646。
- 验证：删除前后的方法列表导出相比，只少了上述 17 个，其余方法的参数、默认值和返回类型都没变；静态护栏全过；macOS debug、release 串行构建通过，无新增警告；黄金五链 3 次全过且与基线一致；默认回归通过。未在 Windows、Web 构建上验证。

## 阶段 1：绑定文件按模块拆开

1. `DCWorldExt::_bind_methods()` 改成依次调用 `_bind_<模块>_methods()`，每个模块一个 `world_ext_bind_<模块>.cpp`，只搬 `ClassDB::bind_method` 行，不改内容和相对顺序以外的任何东西。
2. `world_ext.h` 里的方法声明按同样的模块顺序分段，并加段注释；不拆头文件（拆头文件属于阶段 3）。
3. 新增护栏 `tools/ci/check_world_ext_bindings.py`：
   - 每个绑定必须出现在它所属模块的绑定文件里；
   - 绑定的成员函数必须定义在该模块的 `world_ext_*.cpp` 里；
   - 旧的 `world_ext_bind_methods.cpp` 不能再出现绑定行。
4. 把新护栏加入 `run_regression_checks.py` 的护栏列表和 `runtime-checks.yml` 的 `architecture-guards`，并在 `test_architecture_guards.py` 里加正例和反例。

完成标准：阶段 0 的方法列表导出在拆分前后逐字节相同；静态护栏、两种配置构建、黄金五链三次、默认回归通过。

外包方式：这一步是按清单搬行，适合交给 dsh 分模块批量做，每批一个模块，用方法列表导出验收。

## 阶段 2：脚本侧的模块门

目标：正式脚本里，一个模块的绑定只由该模块自己的脚本目录调用，其他脚本经 facade。

1. 在 `world_ext_binding_modules.json` 里给每个模块登记允许直接调用的脚本目录，例如 economy → `scripts/economy`、`scripts/family`；runtime → `scripts/game`、`scripts/simulation`。
2. 新增护栏 `tools/ci/check_script_native_access.py`：扫描正式脚本对各模块绑定的调用和字符串引用，目录不在允许范围内的记为越界。现有越界冻结进基线，只减不增；测试目录不检查。
3. 按越界清单逐个文件迁移到 facade。顺序按越界文件数从少到多：events、trigger、modifier、military、generation、climate、visual、ideology、effect、country、economy、runtime。`map_generator.gd` 和 `game_save_coordinator.gd` 跨组最多，放在各模块 facade 补齐之后。facade 缺方法时补一行转发，不在 facade 里加逻辑。
4. 接口握手替换逐方法探测：
   - 构建后用阶段 0 的导出生成 `Project/project-keynes/data/native_binding_manifest.json` 并提交；
   - 会话创建世界对象的入口（`map_generator.gd` 与 `game_flow_service.gd` 里的 `ClassDB.instantiate("DCWorldExt")`）统一成一处，在那里比较 `ClassDB` 的方法列表与清单，缺方法就明确失败并列出缺了哪些，不再进入会话；
   - facade 里的 `_world_ext: Object` 改成 `DCWorldExt` 类型；
   - 对清单内方法的 `has_method` 探测及其回退分支，逐模块删除。
5. 探测删除前先分类。扩展相关的约 520 处探测里，有些不是版本兼容而是平台或可选能力判断（例如 Web 回退）。分三类处理：版本兼容类删除；平台类改成显式的平台判断；确实可选的能力保留并写明原因。分类表先交用户或维护者过目再批量删除。

完成标准：越界基线逐模块归零或写明保留原因；握手失败用例（故意去掉清单里的一个方法）能明确报错；每删一个模块的探测后，该模块的测试目录和默认回归通过。

外包方式：第 3 步的调用点改写和第 4 步的探测删除按模块成批外包；第 5 步的分类由我做。

## 阶段 3：原生侧拆类（按模块逐个立项）

只在一个模块满足下面三条时才做：

- 它在 `DCWorldExt` 里的状态已经集中在少数成员上，或本来就在别的所有者那里（例如 Economy、Country 的状态在 `NativeSimulationHost`）；
- 阶段 2 之后，正式脚本只有它的 facade 在调用它；
- 有人正要改这个模块的所有权或要给它做独立的原生测试。

做法：

1. 新建 `Pk<模块>Binding : RefCounted`，由 `DCWorldExt` 持有并通过 `world.<模块>()` 返回；状态成员和方法实现一起从 `DCWorldExt` 搬过去，声明放在自己的头文件里，`world_ext.h` 不再包含它。
2. `DCWorldExt` 上的旧方法保留为一行转发，登记进“待移除转发”基线，只减不增。facade 先切到新类；测试和镜像项目随后成批迁移；某个模块的转发基线归零后删除旧方法。
3. 每个模块立项时先写它自己的状态清单和线程边界（哪些方法在主线程、哪些在执行线程调用），再动手。

建议的先后：

| 先后 | 模块 | 理由 |
|---|---|---|
| 先做 | 烘焙编码器（`world_ext_bake_encoders.cpp` 的 7 个方法） | 无状态；`atlas_encoders.gd` 现在为了调它专门实例化一个 `DCWorldExt`，改成独立的无状态类最直接，可作为整套做法的验证 |
| 其次 | Military、年报 | 状态独立（`MilitaryCore` 由适配层拥有），调用方少（正式脚本 7 个文件，测试 2 个） |
| 再次 | Modifier、Trigger、Effect、Ideology | 各有独立运行时，但测试直接调用多，转发要保留较久 |
| 最后 | Economy、Country、runtime、climate | 绑定最多、测试最多；等前面的做法稳定后再评估是否值得 |

`core` 组（组件注册、实体、池、slot 读写）是 DataCore 本体，留在 `DCWorldExt`。

## 不做的事

- 不在阶段 1、2 改任何绑定的名字、参数或返回值。
- 不一次性把 663 个方法搬到新类；不为了“看起来拆了”建只做转发的类。
- 不改存档格式、每日顺序、请求队列和哈希；任何阶段都不应改变黄金五链。
- 不动 `Project/perf-validation` 的结构；它只需要在阶段 0 删绑定前被搜索一遍，在阶段 3 迁移时和测试一起处理。

## 风险

| 风险 | 应对 |
|---|---|
| 字符串引用漏改（`call("x")`、`Callable(obj, "x")`、信号连接） | 阶段 1、2 不改名，所以不会断；阶段 3 用转发保留旧名，按基线逐步清 |
| 删掉实际有用的“无引用”绑定 | 阶段 0 第 3 步的复核范围包含镜像项目、工具和文档；拿不准就保留 |
| 握手让旧 DLL 直接启动失败 | 这是预期行为，但 Windows 上编辑器锁 DLL、用新文件名构建的流程要同步更新清单；写进 `docs/architecture/feature-guides.md` 的对应小节 |
| 探测里混有平台判断 | 阶段 2 第 5 步先分类再删 |
| 上游并行修改绑定文件 | 阶段 1 的拆分提交前先同步上游；拆分本身是纯搬行，冲突可用清单重新生成解决 |

## 每个阶段的验证

按 `docs/architecture/development-guide.md` 的“护栏与检查”：静态护栏全过；macOS 两种配置串行构建；黄金五链三次；提交前跑默认回归。另加本方案自己的判据：方法列表导出对比（阶段 0、1、3）和越界基线（阶段 2）。交付时同步更新 `docs/architecture/module-map.md` 的“别人怎样调用它”一列和 `current-state.md` 的规模一节。
