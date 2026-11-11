# 模块边界

本页写数据归属、模块之间允许怎样交接、以及哪些边界由护栏机检。怎样在这些规则下改代码见 [development-guide.md](development-guide.md)。

## 数据归属

- 国家、气候、触发、理念、效果、修正、事件各由自己的 POD authority 推进。
- 经济计算仍是 `NativeEconomyRuntime`，POD_ACTIVE 时数据绑定 OwnedState。家庭、人物、建筑属于经济状态。
- 军事由主线程的 `MilitaryCore` 推进，适配层是三个 `world_ext*military*.cpp`；自然资源恢复由主线程 pass 推进。视野与显示不在十二域表里。
- 每日表是 Host 的装配层。`DayExecution` 只借用本次调用的计划、输入和输出，不跨日保存引用。

存档段的所有者见 [current-state.md](current-state.md#存档)。

## 目标依赖方向

外部命令 → 状态所有者；业务模块 → 对方已提交的只读视图；业务后果 → 对方接受的 intent；显示 → 已发布结果。所有者之外不能直接写状态。护栏只禁止新增债务，现有债务冻结在基线里，不等于永久许可。

## 模块公开接口

其他模块只能经 `<module>_api.h` 访问一个模块，经 `<module>_host_port.h` 让模块调用宿主。契约文件在 `tools/ci/module_api/<module>.json`，由 `check_module_api.py` 检查。

| 模块 | 接口头 | 待迁移的外部包含者 | 组合根 | 宿主端口 |
|---|---|---|---|---|
| Economy | `economy_api.h/.cpp`（`struct EconomyApi`） | 0 | 36：22 个 `native_simulation_*`、14 个 `world_ext*` | `economy_host_port.h` |
| Country | `country_api.h/.cpp`（`struct CountryApi`） | 0 | 32：20 个 `native_simulation_*`、12 个 `world_ext*` | `country_host_port.h` |
| Modifier | `modifier_api.h/.cpp`（`struct ModifierApi`） | 0 | 9 个 `world_ext*` | — |
| Military | `military_bridge.h`（纯 C++ 契约） | 0 | 2：`world_ext.cpp`、`world_ext_military.cpp` | — |

- **接口头**只放 POD、枚举、常量、前向声明和 `<module>_api::` 自由函数；能包含系统头、其他模块的 `*_api.h` 和登记过的共享契约头。`struct XApi` 是运行时类的基类，运行时内部写法不变；外部写 `XApi::CONST`。
- 引号和尖括号引用都检查模块内部头。`gdext/src` 搜索路径中实际存在的头不因使用尖括号而变成系统头；接口和共享契约也适用此规则。
- **转发函数** `pk::x_api::fn(const Runtime&, ...)` 每个只转发一个成员，按调用方分组（`// ---- <调用方> (<文件>)`）。需要完整类型的操作（复制、移动、析构）也用转发：`modifier_api::copy_runtime` 返回带自定义删除器的 `ModifierRuntimeCopy`，`replace_runtime` 移动赋值；`attach_country_runtime/attach_economy_runtime` 的参数是 `void*`，因为在接口头里写对方的类名会给依赖棘轮新增 header 引用。
- **共享契约头**（`tools/ci/module_api_shared.json`，6 个）：`metric_mask.h`、`effect_selector_cap.h`、`country_read_view.h`、`derived_cell_layer.h`、`country_fiscal_return_intent.h`、`country_procurement_intent.h`。它们只能包含系统头或其他共享头。
- **组合根**：构造或拥有运行时的宿主（`native_simulation_*`）和绑定层（`world_ext*`），只减不增，每项写原因。
- **所有者文件**：`owner_file_patterns` 内的文件是模块自身组件（例如 `trade_visual_cache.*` 属 Economy）。`forbidden_owner_includes` 禁止所有者文件包含宿主头 `native_simulation_host*.h`（引号和尖括号都查），例外必须写原因。
- **宿主端口**：纯虚方法，签名与宿主原方法完全一致。`class NativeSimulationHost final : public EconomyHostPort, public CountryHostPort`；两个端口都有的方法（如 `domain_is_worker_authoritative`、`allocate_command_request_id`）由宿主的一个 override 同时实现。模块内成员仍叫 `_simulation_host`，类型是端口指针。端口调用是虚调用，都在命令/队列边界或循环外，没有进逐格热循环。Economy 端口 24 个方法，Country 端口 18 个。
- **交易地图绑定**：`world_ext_economy_topology.cpp` 只包含 `economy_api.h`，通过薄转发接入地形与可见性。完整报告 `detail_report` 属于组合层在停止执行或持有日边界时使用的兼容接口，不能代替已提交视图。存档执行器接管只保留该世界已经绑定的交易图，并清空派生国家分组标记。
- **军事**：核心只依赖 `military_bridge.h` 与系统头，`military.json` 禁止核心包含其他模块、宿主与 Godot 头。三个适配文件经 Economy/Country/Modifier 的接口头调用对方，宿主和 `MilitaryCore` 由适配层拥有。

Country 的 `country_core*.h`、`country_ai_*.h` 尚未锁进契约（只锁 `country_runtime*.h`）；其中跨模块调用是否全部走接口，靠依赖基线和跨域清单约束。

## 依赖棘轮

`check_cpp_deps.py` 对 country、economy、effect、ideology、modifier、trigger、military、family、climate 的命名文件统计 include 和外域类型词。它是文本检查：忽略注释与字符串，检查条件编译的所有分支；宏生成、类型别名、间接 include 和运行时指针权限不在检测范围。

- 文件名决定域：`runtime_` / `native_` 前缀也识别；文件名里含 `_family_` 的归 family 域。Economy 侧的家族实现因此用 `lineage_` 命名，否则依赖会被重新归类。Host、`world_ext`、共用协议与装配适配器暂不归业务域。
- 基线 [`cpp_deps_baseline.json`](../../tools/ci/cpp_deps_baseline.json)：`references` 是受限债务，`contract_references` 是经接口头的已审契约引用。`header_exposed`（只数 `.h`）和 `total` 两个总量都包括两张表。域对集合不能扩展，普通引用不能因别处删除而增加。
- 位移例外记在 `relocations`：头→同目录同名/下划线后缀实现、同目录 `economy_runtime*.cpp` 之间、原 `economy_runtime.h` → `economy_runtime_internal_*.h`。必须同域对、同符号，来源同步减少，同一减少量不能重复使用。
- `tools/ci/cross_domain_inventory.json` 把基线里的 30 个域对逐项标为已迁移（3）、明确不迁移（2）或待逐函数核查（25），`check_cross_domain_inventory.py` 拒绝表外域对。“待核查”指间接调用的语义还没逐函数审过，与 include 是否已走接口头是两回事。

## 已提交视图

9 条读边见 [current-state.md](current-state.md#跨模块交接)。规则：所有者提供 `copy_committed_view()`，视图带 generation/day，消费端调用 `observe_committed_view()`；消费端不保存所有者 snapshot 的引用，也不读 plan。`check_committed_views.py` 检查直接借用、别名和成员指针绕行。

## 请求与提交

`runtime_resolve_contract.h` 提供 `ResolveFlow`、`ResolveOrder`、`ResolveResult`、`resolve_enqueue`、`resolve_find_receipt`。共享契约不把各域不同的去重语义合并成一个全局 ID。

| 请求流 | 产生 → 消费 | 顺序与去重 | 保存位置 | 状态 |
|---|---|---|---|---|
| Host 通用命令 | world_ext submit → Host `enqueue_batch` → 各域 | submit_order、producer/sequence | PKSR5 pending_commands | 已登记 |
| Country 命令 | Host/Country AI → Country plan_day | effective_day, sequence, submit_order, request_id | PKCN | 共享入队与顺序键 |
| Economy 命令（含军事 24/30–34） | Host/军事桥 → `commit_pending_commands` | 原接纳顺序；先终态、再普通回执按 request_id 重放 | PKSR EQC1 | 共享入队与回执查找 |
| Trigger 命令 | Events/回执桥 → Trigger plan_day | day, producer, sequence, request_id；ACK 合并 | TPD1 + PKSR TCQ1 | 共享入队与顺序键 |
| Country/Economy 资产 | 财政/采购端口 → Country/peer 协调 | transaction/session/generation；prepared→commit→applied | Country 资产 journal + PKSR D7T1 | 所有者端口 |
| Military 命令/征召/军饷 | 军事日入口 → Economy/Country | 原军事序号、receipt cursor、次日命令 | PKMI2、MILB3、MDJ1、EQC1 | 经 Economy；军事自身队列未迁移 |
| Effect → Modifier/Events | Effect 计划 → 两个阶段 | instance/idempotency/transaction ACK | EFP1 与各域存档 | 原协议 |
| Ideology → Modifier | 转换计划 → Modifier 批次 ACK | transition 身份、目标 generation | PKID 与 Modifier 继续态 | 原协议 |
| 同步 Effect 外部批次 | Trigger/家族/运河 → EffectRuntime | 原批次身份 | PKEF | 仅登记 |

`resolve_apply_contracts.json` 登记 `queue_command` / `submit_*command` / `enqueue_*` 入口，新增这类入口或已接入函数直接 push/emplace/insert 会失败。Apply 写集合：十二域写声明与 Host 模块描述符逐项比较；`Country::commit_day`、`Economy::commit_pending_commands`、`Military::reconcile_receipts` 三个入口检查已审成员集合和跨域写调用。这是入口级文本检查，不是全调用树的别名分析，也不构成全域事务或失败回滚。

## 行数棘轮

编排入口 600 行，普通 GDScript 800 行，`gdext/src` C++ 2000 行（编排入口清单在 `check_size_ratchet.py`）。统计物理行，排除 tests、addons、生成物。现有超限文件只能保持或缩短，新文件不准超限。基线 `size_baseline.json` 只在文件变短后收紧。
