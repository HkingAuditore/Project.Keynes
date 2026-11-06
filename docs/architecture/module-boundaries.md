# 模块边界

## 已落地的数据归属

完整写入者与线程证据见 [现状](current-state.md)。国家、气候、触发、理念、效果、修正、事件各由对应 POD authority 推进；经济计算仍依赖 NativeEconomyRuntime，POD_ACTIVE 时数据绑定 OwnedState。家庭、人物与建筑目前属于经济状态。军事另由主线程 runtime 推进，自然资源恢复由主线程 pass 推进。视野与显示不在十二域表里。

每日表是 Host 的装配层，`DayExecution` 仅借用本次调用的计划、输入和输出，不跨日保存引用。各 stage 仍访问同一个 Host 的私有成员；拆方法不是独立 store 迁移。公共类名、绑定、scheduler/slot id 与保存格式未改变。

## 模块公开接口（当前）

规则与迁移步骤见 [开发指南](development-guide.md#模块公开接口module-api试点economy)。契约文件按模块分开放在 `tools/ci/module_api/`，由 `check_module_api.py` 检查。

| 模块 | 接口头 | 待迁移的同级包含者 | 组合根 |
|---|---|---|---|
| Economy | `economy_api.h` / `economy_api.cpp`；宿主端口 `economy_host_port.h` | 0。Modifier、Effect、Trigger、Ideology（含 `ideology_opinion_bridge.h`）、Country 和三个军事适配文件已迁；`trade_visual_cache.*` 是 Economy 自己的组件，登记为所有者 | 36：22 个 `native_simulation_*`、14 个 `world_ext*` |
| Country | `country_api.h` / `country_api.cpp`（Military 组） | 19 | 32：20 个 `native_simulation_*`、12 个 `world_ext*` |
| Modifier | `modifier_api.h` / `modifier_api.cpp`（Military/Economy/Effect/Ideology 组） | 1 | 9 个 `world_ext*` |
| Military | `military_bridge.h`（纯 C++ 契约） | 0 | 2：`world_ext.cpp`、`world_ext_military.cpp` |

共享契约头（`tools/ci/module_api_shared.json`）：`metric_mask.h`、`effect_selector_cap.h`、`country_read_view.h`、`derived_cell_layer.h`。后两者仅含系统头，分别提供国家只读快照和已发布的逐格修正值；后者保留既有独立构建器，不持有运行时。

军事核心只依赖 `military_bridge.h` 和系统头；`military.json` 禁止军事所有者包含其他模块、宿主与 Godot 头（引号、尖括号都检查）。三个军事适配文件经由 `economy_api.h`、`country_api.h`、`modifier_api.h` 调用其他模块；宿主和 `MilitaryCore` 仍由适配层拥有。五项旧编译期探测均为 true，已改为公开函数调用，空对象判断和 split/pay 方法的实际返回值不变。

Country 本轮只锁 `country_runtime*.h`：`country_core.h`、`country_core_apply.h`、`country_ai_core.h`、`country_ai_runtime.h` 的其他跨模块调用尚未迁移；`country_fiscal_return_intent.h`、`country_procurement_intent.h` 是已有请求契约，`country_read_view.h` 是共享只读契约，不将它们误标成实现头。

依赖扫描已修复将 `template<class A, class B>` 参数识别为类型定义的误判。军事自测的局部变量 `A` 不再形成 `military->economy` 债务边；基线仅由 `check_cpp_deps.py --write-baseline` 收紧。当前 515 引用键（462 债务键）、header_exposed=524、total=2193；原基线为 517 键、total=2220，域对没有增加。

经济的 11 个宿主调用实现文件已经改用 `economy_host_port.h` 的 24 个纯虚方法；`NativeSimulationHost final` 实现端口并保持原有方法体和调用顺序。经济所有者文件直接包含 `native_simulation_host*.h` 的数量为 0，`forbidden_owner_includes.allowed` 为空。端口指针调用仍是虚调用，未改写热循环。Country 已为军事提供窄接口；其他直接包含者保留在待迁移清单中。

## 允许方向与现存债务

目标依赖方向：外部命令 → 状态所有者；业务模块 → 对方已提交只读视图；业务后果 → 对方接受的 intent；显示 → 已发布结果。所有者之外不能直接写状态。

当前检查只禁止新增依赖债务，不宣称已强制目标方向。`check_cpp_deps.py` 对 country、economy、effect、ideology、modifier、trigger、military、family、climate 的命名文件检查 include 和外域类型词；`runtime_` / `native_` 前缀也识别，经济目录名下的 family 叶实现按 family 统计。Host、world_ext、共用协议和装配适配器暂不归为业务域，不能以改文件名规避检查。

它是文本检查，不是 C++ 名称解析：忽略注释/字符串，检查条件编译的全部分支；类型通过域前缀或唯一声明来源识别，多个域都有的未限定嵌套名称（例如 Command）不据此判越界。宏生成、类型别名、间接 include、函数调用方向和运行时指针权限尚无完整检测。

权威清单是 [cpp_deps_baseline.json](../../tools/ci/cpp_deps_baseline.json)。`references` 保存受限依赖，`contract_references` 单列已批准的 `country_read_view.h`、`CountryReadView` 与其限定名 `Snapshot`；只有这一明确的只读接口允许按实际使用接入，不能扩展成 Country 前缀通行证。**header_exposed/total 包含两张表全部计数**；前者只数 `.h`，后者数全部文件。域对集合不能扩展，普通引用不能增加。

已审查的头文件移位和S12经济实现文件之间的机械位移是依赖位置增长例外：`relocations` 中目标键记录 `moved_from`、来源前后次数、目标原次数和移入次数。头→实现必须同目录、同名或下划线后缀；cpp→cpp仅限同目录economy_runtime*.cpp。两类都必须同域对、同 include/类型；来源减少量必须足够，同一减少量不能重复使用。`--write-baseline` 也先验证两个总量、域对和逐键变化，不能用重建基线洗掉新债务。已批准的只读接口仍受两个总量限制，纯新增具体 runtime 依赖即使被其他删除抵消也失败。完整规则与反例在检查器和护栏测试中。

S4 前后：header_exposed **527→522**，total **2404→2400**，全部键 **435→433**（421 个受限键 + 12 个只读接口键），域对仍为 31。以下不是运行时调用量：

| S4历史方向（S12当前汇总见文末） | 引用键数 | 出现次数 |
| --- | ---: | ---: |
| climate->economy | 10 | 94 |
| climate->modifier | 1 | 40 |
| country->economy | 30 | 111 |
| country->effect | 8 | 22 |
| country->modifier | 3 | 25 |
| economy->country | 75 | 456 |
| economy->effect | 37 | 91 |
| economy->family | 92 | 353 |
| economy->military | 2 | 3 |
| economy->modifier | 9 | 49 |
| economy->trigger | 4 | 6 |
| effect->country | 4 | 26 |
| effect->economy | 6 | 55 |
| effect->family | 5 | 19 |
| effect->modifier | 9 | 76 |
| family->country | 2 | 6 |
| family->economy | 47 | 297 |
| family->effect | 6 | 40 |
| family->modifier | 2 | 2 |
| ideology->country | 10 | 199 |
| ideology->economy | 8 | 61 |
| ideology->effect | 25 | 192 |
| ideology->family | 2 | 25 |
| ideology->modifier | 4 | 22 |
| military->economy | 2 | 23 |
| modifier->country | 2 | 4 |
| modifier->economy | 4 | 26 |
| modifier->effect | 3 | 3 |
| trigger->economy | 8 | 40 |
| trigger->effect | 8 | 28 |
| trigger->ideology | 5 | 6 |

现存越界：经济写入仍直连 Country 的事务方法，税种/模式/存档常量仍直接使用 Country 类型；family 叶仍通过经济操作其状态。`economy_runtime*.h` 已不再 include 两个具体 Country 头；只读查询已走视图，但这不等于所有者数据实现已隔离。Country→Economy 的逐键计数与 S4 开始时相同。

## 第二阶段核实的诊断边界

- 经济完整哈希并非只含经济账目：还读同步国家对象与 Modifier 的 ECONOMY 序列（`gdext/src/economy_runtime.cpp:25458`、`:26102`）。生产调用方仍需处理其回写日期边界；黄金测试现在明确等待同日回写。E1 已证明第 1 天 `2/1` 的日期差异改变完整经济哈希；具体字段和日志见 [现状](current-state.md)。S4 只把 Country 访问改经视图，取值来源和时点仍保持。
- `get_country_state_hash` 仍取保留的同步对象；`get_country_report` 则使用 `country_query_runtime` 查询工作线程快照副本（`gdext/src/world_ext_country.cpp:1941`、`:1948`、`:1952`）。不能因两个 API 都名为 country 就把它们作为同一提交边界。
- 开局资源生成属于初始化链，先生成储量，再生成地图研究信号，再写国家开局观察集合（`gdext/src/world_ext_boot_facade.cpp:310`、`:337`；`gdext/src/country_runtime.cpp:1242`）。E1 发现并在用户授权后修复资源排除表越界读取，已影响国家初始发现计数；仅增加编号小于行宽的判断。十二域日表正确排序不能弥补初始输入不一致。
- E2 只读诊断直接借用真实 worker authority/store，不以同步 getter 或 Country preview 为替代。入口受整日边界锁和黄金开关约束；`world_ext_golden.cpp` 只负责转换为既有报告的追加字段。七域投影具体范围见 current-state.md；E2 曾因信号 121 的登记日期 5/6 日差异排除 Country；S3-A 修复交付/收件边界后，Country 单独进入 v4 追加链。
- v2 整体经济哈希仍含旧同步依赖；v3 ECONOMY 只读 worker 的人口/市场列。两者都不能宣称是经济、家庭、人物、建筑、贸易全部逻辑状态的完整摘要。

## E3 登记边界

清单 [runtime_advancers.json](../../tools/ci/runtime_advancers.json) 及空未登记基线 [runtime_advancers_baseline.json](../../tools/ci/runtime_advancers_baseline.json) 管理表外推进/消费；生成的 `runtime_external_advancers.h` 不依赖 Godot，由模块描述符头引入。条目供 C++ 读取和审查，不拥有调度权或访问隔离能力。

| 登记项 | 线程 | 归属及交接 |
| --- | --- | --- |
| military | 主线程 | 原 military runtime 读已提交 Country/Economy、写军事实体并发后续意图；逐帧追赶 |
| natural_resource_recovery | 主线程 | 原资源 pass 读资源/环境，写资源 slot 和 MapData；逐帧追赶；不同于经济消耗资源 |
| family / person | 执行线程 | 仍在经济 FAMILY_COMMIT/PERSON_COMMIT；worker 或 inline 调用线程；没有独立日域 |
| vision | 主线程 | 读地形/领地/研究信号，写可见性与探索并提交 Country 观察意图 |
| visual_delivery | 主线程 | 消费已发布脏类别补丁，写显示/MapData；family_cursors 的 family 指脏类别 |
| climate_writeback | 主线程 | 只消费已提交 Climate 快照，写 slot/MapData，不是另跑气候公式 |

新检查覆盖 Host 的约定游标、日期与追赶函数，当前 7 字段/4 函数全部登记；不替代 C++ include 检查，也不证明任意命名的新函数都能被检测。所有执行位置、提交顺序和已有依赖均保留；军事/资源移入日表未开始。


## 行数棘轮

编排入口 600 行，普通 GDScript 800 行，`gdext/src` C++ 源码/头文件 2000 行；编排入口清单显式写在 `check_size_ratchet.py`。统计物理行，排除 tests、addons、生成物等指定目录/文件。现有超限文件仅能保持或缩短，新文件不准超限。

本轮缩短的文件在验证后收紧基线。以后删除依赖或缩短超限文件时同步降低对应基线；默认检查绝不写基线。修改基线需要审查实际 diff，不能用重新生成来放行增长。旧文档中的 GDScript 叶 1200、公共头 1000 等例外不用于本轮规则；本轮按任务指定的三个阈值执行。

## S3-B 历史交付（S4 接续前）

`country_read_view.h` 仅依赖 `<cstdint>`，提供三个返回整数的只读函数；回调只接收 `const void *` 所有者。`country_read_view.cpp:5` 由 Country 实现并返回短期借用。经济已迁移 16 处国库读取，仍通过既有 Country 指针取得视图；这不是彻底去除具体 runtime 连接，也不声称多个查询绑定同一快照。

`check_cpp_deps.py` 新增对这些直接读取的拒绝规则；`test_architecture_guards.py` 用三个故意绕过视图的调用验证失败，视图调用通过。S3 交付时原 include/类型基线未放宽，仍 435 键、零违规。原 `country_ai_core.h` 公共 include 尚未移除：把它转入使用它的实现文件，在现有“逐文件键只许减少”规则下会产生新键，当时向用户提出规则澄清；S4 用户已授权移位并指定新规则，当前实现见上文。未用改名、间接 include 或删检查规避这个约束；S3-B 的“头文件移除、键数下降”验收尚未达成。

## S3-B 历史盘点（以下行号是 S3 交付时）

范围为 `economy_runtime.cpp` 与 `economy_runtime.h`，不是所有 `economy_runtime_*.cpp`。同一方法/常量的引用按行号合并；这些是文本出现次数，不是运行次数。下表覆盖 cpp 中全部 212 个含 `_country_runtime` / `NativeCountryRuntime` 的源码行，分类依据实际调用是否只读。公共名称以 Country 开头但在经济内部定义的数据（例如阶层意见、贸易聚合、采购继续状态）不冒充国家所有者引用。

| 文件:行（相对 gdext/src） | 类别 | 方法 / 字段或类型 |
| --- | --- | --- |
| economy_runtime.cpp:1041, 4072, 6000, 6442, 6561 | (a) 只读 | `cash_for_slot；本刀经 read_view() 读取` |
| economy_runtime.cpp:5132 | (a) 只读 | `copy_economy_snapshot；读取国家冻结副本，税率/模式/科技/领土等列` |
| economy_runtime.cpp:2426, 14132, 14414, 14552, 14803, 19267 | (a) 只读 | `country_handle_for_cell` |
| economy_runtime.cpp:5001 | (a) 只读 | `country_slot_for_cell` |
| economy_runtime.cpp:864, 3370, 3526, 3702, 3821, 3987, 5125, 6374 | (a) 只读 | `economy_available` |
| economy_runtime.cpp:5126 | (a) 只读 | `good_count` |
| economy_runtime.cpp:5002 | (a) 只读 | `has_technology` |
| economy_runtime.cpp:835 | (a) 只读 | `research_consumed_total` |
| economy_runtime.cpp:848 | (a) 只读 | `sample_economy_goods_audit；const，仅写调用者传入的输出总数` |
| economy_runtime.cpp:13222 | (a) 只读 | `should_run` |
| economy_runtime.cpp:5141 | (a) 只读 | `starting_country_slot` |
| economy_runtime.cpp:964, 1250, 1507, 3381, 13224, 15059 | (a) 只读 | `sync_store_writes_forbidden` |
| economy_runtime.cpp:5127 | (a) 只读 | `technology_count` |
| economy_runtime.cpp:3988, 6379 | (a) 只读 | `technology_points_good_id` |
| economy_runtime.cpp:406, 6585, 14134, 14151, 14418, 14437, 14554, 14598, 14895 | (a) 只读 | `total_cash；本刀经 read_view() 读取` |
| economy_runtime.cpp:462, 14950 | (a) 只读 | `total_good；本刀经 read_view() 读取` |
| economy_runtime.cpp:2466, 14235, 14260 | (a) 只读 | `valid_handle` |
| economy_runtime.cpp:1212, 3500, 3684, 3801, 3974 | (b) 命令/提交 | `acknowledge_economy_asset_peer_applied` |
| economy_runtime.cpp:880, 1109, 3458, 3466, 3473, 3636, 3643, 3651, 3759, 3767, 3774, 3932 | (b) 命令/提交 | `acknowledge_economy_asset_peer_prepared` |
| economy_runtime.cpp:3607 | (b) 命令/提交 | `begin_economy_cash_from_cohort` |
| economy_runtime.cpp:3604 | (b) 命令/提交 | `begin_economy_cash_to_cohort` |
| economy_runtime.cpp:3429 | (b) 命令/提交 | `begin_economy_fiscal_collect` |
| economy_runtime.cpp:3423 | (b) 命令/提交 | `begin_economy_fiscal_reserve` |
| economy_runtime.cpp:3426 | (b) 命令/提交 | `begin_economy_fiscal_return` |
| economy_runtime.cpp:3734 | (b) 命令/提交 | `begin_economy_good_from_market` |
| economy_runtime.cpp:3731 | (b) 命令/提交 | `begin_economy_good_to_market` |
| economy_runtime.cpp:1072 | (b) 命令/提交 | `begin_economy_research_purchase` |
| economy_runtime.cpp:3911 | (b) 命令/提交 | `begin_economy_treasury_spend` |
| economy_runtime.cpp:1123, 3481, 3659, 3782, 3940 | (b) 命令/提交 | `commit_economy_asset_transaction` |
| economy_runtime.cpp:5344 | (c) 常量/类型 | `CellTaxPolicy` |
| economy_runtime.cpp:2447, 3533, 3564, 14424, 14566, 14808 | (c) 常量/类型 | `ECONOMY_ASSET_CASH_FROM_COHORT` |
| economy_runtime.cpp:2446, 3532, 3566, 3603, 3633, 3673, 14141 | (c) 常量/类型 | `ECONOMY_ASSET_CASH_TO_COHORT` |
| economy_runtime.cpp:3428 | (c) 常量/类型 | `ECONOMY_ASSET_FISCAL_COLLECT` |
| economy_runtime.cpp:3422, 3456, 3464, 3492 | (c) 常量/类型 | `ECONOMY_ASSET_FISCAL_RESERVE` |
| economy_runtime.cpp:3425 | (c) 常量/类型 | `ECONOMY_ASSET_FISCAL_RETURN` |
| economy_runtime.cpp:2477, 3709, 3757, 14272 | (c) 常量/类型 | `ECONOMY_ASSET_GOOD_FROM_MARKET` |
| economy_runtime.cpp:2476, 3708, 3730, 3765, 3795, 14246 | (c) 常量/类型 | `ECONOMY_ASSET_GOOD_TO_MARKET` |
| economy_runtime.cpp:1049 | (c) 常量/类型 | `ECONOMY_ASSET_RESEARCH_PURCHASE` |
| economy_runtime.cpp:3851 | (c) 常量/类型 | `ECONOMY_ASSET_TREASURY_SPEND` |
| economy_runtime.cpp:5131, 25497 | (c) 常量/类型 | `EconomySnapshot` |
| economy_runtime.cpp:6028, 6044, 6192, 6206, 6306, 10010, 10018, 10075, 10085, 10358, 10600, 10604, 11861, 11881, 11893, 22453 | (c) 常量/类型 | `TAX_BUSINESS` |
| economy_runtime.cpp:6030, 6042, 6190, 6204, 6303 | (c) 常量/类型 | `TAX_CONSUMPTION` |
| economy_runtime.cpp:6032, 6048, 6312 | (c) 常量/类型 | `TAX_EXPORT` |
| economy_runtime.cpp:6031, 6046, 6194, 6208, 6309 | (c) 常量/类型 | `TAX_IMPORT` |
| economy_runtime.cpp:6026, 6040, 6188, 6202, 6300, 10029, 10033, 10097, 10107, 10369, 10611, 10614, 11192, 11194, 11196, 11208, 11860, 11901, 11910, 12892, 22449, 22452 | (c) 常量/类型 | `TAX_INCOME` |
| economy_runtime.cpp:6121, 6214, 25504 | (c) 常量/类型 | `TAX_KIND_COUNT` |
| economy_runtime.cpp:5723, 6083, 6133, 6262, 6295, 11197 | (c) 常量/类型 | `TAX_MODE_ABSOLUTE` |
| economy_runtime.cpp:6129, 6155, 6158 | (c) 常量/类型 | `TAX_MODE_INHERIT` |
| economy_runtime.cpp:6130, 6159, 6227 | (c) 常量/类型 | `TAX_MODE_PERCENT_BP` |
| economy_runtime.cpp:6153, 6162 | (c) 常量/类型 | `TAX_RATE_INHERIT` |
| economy_runtime.cpp:5741 | (c) 常量/类型 | `TAX_RATE_MAX_BP` |
| economy_runtime.cpp:5740 | (c) 常量/类型 | `TAX_RATE_MIN_BP` |
| economy_runtime.cpp:12482, 12485 | (c) 常量/类型 | `TAX_TRANSACTION` |
| economy_runtime.cpp:460, 831, 841, 1249, 1506, 1512, 2424, 2465, 3559, 5000, 5999, 6553, 6584, 13221, 14234, 14259, 14551, 14553, 14802, 14947, 15058, 19265, 25498 | (c) 指针/存在性检查 | `_country_runtime 空值或权威路由门禁` |
| economy_runtime.cpp:25499 | (d) 哈希 | `copy_economy_snapshot；读取国家冻结副本，税率/模式/科技/领土等列` |
| economy_runtime.cpp:25458 | (d) 哈希 | `state_hash` |

头文件中的实际对外类型/连接点如下；AI 接口中的 intent 是提交给经济的旧协议，本刀不改变其含义。

| 文件:行 | 类别 | 内容 |
| --- | --- | --- |
| economy_runtime.h:38 | (c) 类型/头文件 | `include country_ai_core.h` |
| economy_runtime.h:71, 712, 7075 | (c) 类型/头文件 | `NativeCountryRuntime` |
| economy_runtime.h:1553, 6682 | (c) 类型/头文件 | `CountryAiEconomyDigest` |
| economy_runtime.h:1555, 6683 | (c) 类型/头文件 | `CountryAiFamilyPreferenceRow` |
| economy_runtime.h:1557, 1567, 1571, 6684 | (c) 类型/头文件 | `CountryAiColonizationIntent` |
| economy_runtime.h:1561, 1568, 1572, 6685 | (c) 类型/头文件 | `CountryAiColonizationStat` |
| economy_runtime.h:6680, 6689, 6689 | (c) 类型/头文件 | `CountryAiShared` |

cpp 的哈希路径仍读旧同步国家 `state_hash()`，并用 `copy_economy_snapshot` 计算财政哈希；本刀不更改读取时点或保存字节。命令/写入表中的全部方法和参数保持原样。

## S4 读取接口（当前）

经济统一用 `country_reads()` 取得所有者提供的 27 种只读查询；`country_read_view.cpp` 的每个回调都调用同名原 const getter。视图只持有所有者和静态函数表的借用，不缓存结果。`Snapshot`/地块税政策的字段与顺序原样移到无 Godot 头；`country_runtime.h:148`、`:156` 保留原类型名的别名，三个税列常量由 static_assert 核对。冻结调用仍在 `capture_country_epoch`，即时余额仍在原交易检查点，旧哈希仍取旧对象；不能据此声称所有查询都来自同一 worker 提交快照。

当前所有 `economy_runtime*.cpp` 的只读调用位置如下（文件均位于 `gdext/src/`）；工厂 `_country_runtime->read_view()` 是唯一保留的读取连接点，位于 `economy_runtime.cpp:4927`。常量、类型和空值门禁不是查询，仍保留。

| 查询 | 文件:行（全部调用点） | 内容/边界 |
| --- | --- | --- |
| `cash_for_handle` | `economy_runtime_building_construction.cpp:344`；`economy_runtime_canal.cpp:337,505`；`economy_runtime_queries_market_building.cpp:1905` | 按句柄现金 |
| `cash_for_slot` | `economy_runtime.cpp:1041,4072,5996,6438,6557`；`economy_runtime_colonization_kit.cpp:94`；`economy_runtime_fiscal.cpp:707`；`economy_runtime_procurement.cpp:280,399,586,690,878` | 按槽位现金 |
| `copy_economy_snapshot` | `economy_runtime.cpp:5129,25495`；`economy_runtime_colonization.cpp:502,852`；`economy_runtime_colonization_kit.cpp:623`；`economy_runtime_persistence.cpp:452`；`economy_runtime_persistence_read.cpp:1616` | 周期冻结与财政哈希/保存校验：领土、科技、税率、稀疏地块政策；复制位置不变 |
| `copy_technology_domains` | `economy_runtime_configuration.cpp:582` | 科技目录分组 |
| `country_handle_for_cell` | `economy_runtime.cpp:2426,14128,14410,14548,14799,19263`；`economy_runtime_building_construction.cpp:283`；`economy_runtime_canal.cpp:121,136,414`；`economy_runtime_colonization.cpp:286,330,377,550,560,718,769,1118,2203,2400`；`economy_runtime_country_ai.cpp:313`；`economy_runtime_family_buff.cpp:708,764`；`economy_runtime_family_founding.cpp:82`；`economy_runtime_queries_market_building.cpp:1787` | 地块所属国家句柄 |
| `country_slot_for_cell` | `economy_runtime.cpp:4998`；`economy_runtime_canal.cpp:120`；`economy_runtime_colonization.cpp:507`；`economy_runtime_queries_market_building.cpp:1788` | 地块所属国家槽位 |
| `economy_available` | `economy_runtime.cpp:864,3370,3526,3702,3821,3987,5122,6370`；`economy_runtime_colonization_kit.cpp:79,1345`；`economy_runtime_configuration.cpp:572`；`economy_runtime_military_view.cpp:312`；`economy_runtime_persistence.cpp:304`；`economy_runtime_persistence_read.cpp:596,616`；`economy_runtime_procurement.cpp:561` | 已配置、已初始化与运行模式门禁 |
| `generation` | `economy_runtime_persistence.cpp:1855`；`economy_runtime_persistence_read.cpp:599,611`；`economy_runtime_persistence_write.cpp:30` | 旧 generation/存档兼容判断 |
| `good_count` | `economy_runtime.cpp:5123` | 物资目录宽度 |
| `good_for_handle` | `economy_runtime_building_construction.cpp:308,328`；`economy_runtime_canal.cpp:324,407,494`；`economy_runtime_queries_market_building.cpp:1795,1874` | 按句柄物资 |
| `good_for_slot` | `economy_runtime_procurement.cpp:297,404,590,894` | 按槽位物资 |
| `has_research_signal` | `economy_runtime_events.cpp:391,421,978` | 国家研究信号 |
| `has_technology` | `economy_runtime.cpp:4999`；`economy_runtime_canal.cpp:128`；`economy_runtime_water.cpp:88,91,94,97` | 国家已获科技 |
| `research_consumed_total` | `economy_runtime.cpp:835` | 累计研究物资消耗 |
| `research_procurement_policy` | `economy_runtime_procurement.cpp:237,286` | 采购开关、预算、剩余点数 |
| `research_signal_evidence_count` | `economy_runtime_events.cpp:386` | 国家研究证据计数 |
| `sample_economy_goods_audit` | `economy_runtime.cpp:848`；`economy_runtime_epoch.cpp:1329` | 一次取同一国家资产快照中的库存、研究消耗、现金 |
| `should_run` | `economy_runtime.cpp:13218`；`economy_runtime_diagnostics.cpp:2939`；`economy_runtime_persistence.cpp:306` | 既有日推进门禁 |
| `starting_country_slot` | `economy_runtime.cpp:5138`；`economy_runtime_family_founding.cpp:81`；`economy_runtime_trade.cpp:216` | 玩家开局国家槽位 |
| `state_hash` | `economy_runtime.cpp:25454`；`economy_runtime_persistence.cpp:1856`；`economy_runtime_persistence_read.cpp:565`；`economy_runtime_persistence_write.cpp:33` | 旧同步哈希，保持原保存/经济链语义；不是 v4 worker 摘要 |
| `state_hash_v3_compat` | `economy_runtime_persistence_read.cpp:563` | 旧存档兼容哈希 |
| `sync_store_writes_forbidden` | `economy_runtime.cpp:964,1250,1507,3381,13220,15055` | 现有权威路由门禁（查询，不设置） |
| `technology_count` | `economy_runtime.cpp:5124` | 科技目录宽度 |
| `technology_points_good_id` | `economy_runtime.cpp:3988,6375` | 科技点物资编号 |
| `total_cash` | `economy_runtime.cpp:406,6581,14130,14147,14414,14433,14550,14594,14891`；`economy_runtime_publish.cpp:140` | 国家总现金 |
| `total_good` | `economy_runtime.cpp:462,14946`；`economy_runtime_publish.cpp:348` | 国家总物资 |
| `valid_handle` | `economy_runtime.cpp:2466,14231,14256`；`economy_runtime_building_construction.cpp:279`；`economy_runtime_canal.cpp:100,386`；`economy_runtime_colonization.cpp:448`；`economy_runtime_colonization_kit.cpp:128`；`economy_runtime_configuration.cpp:1423`；`economy_runtime_country_ai.cpp:288`；`economy_runtime_epoch.cpp:1432,1437`；`economy_runtime_persistence.cpp:1171,1178,1192`；`economy_runtime_persistence_read.cpp:2165`；`economy_runtime_procurement.cpp:46,84,185,817`；`economy_runtime_queries_market_building.cpp:693,1767`；`economy_runtime_water.cpp:105` | 句柄有效性 |

检查器覆盖全部 `economy_runtime*.cpp` 的 `_country_runtime->方法` 调用：现有写入清单和工厂以外的调用一律失败；头文件恢复具体 Country include 也失败。它仍是文本护栏，改指针名/增加别名等间接绕过不能完整识别，代码审查必须检查真实调用方向。

## S4-C 写入盘点与设计留存（S5 已接续首条）

以下是全部 47 处直接写入调用：主实现 31 处，殖民补给 9 处，采购 5 处，军事适配 2 处。S4 没有改任何一处的参数或先后顺序（`stage4/source-audit.json` 对比本轮开始副本）。下表为 S4 结束时盘点；FISCAL_RETURN 已由后文 S5 端口接续，其余拟议名称仍不是现有 API。

| 现有方法 | 文件:行（全部调用点） | 建议 intent/回执 | 顺序 | 风险 |
| --- | --- | --- | --- | --- |
| `acknowledge_economy_asset_peer_applied` | `economy_runtime.cpp:1212,3500,3684,3801,3974`；`economy_runtime_colonization_kit.cpp:1421,1500,1513`；`economy_runtime_procurement.cpp:541` | `AssetPeerAppliedAck` | 随相应业务路径 | peer 真正写入后才确认；同步模式的既有 ACK 处理不能改 |
| `acknowledge_economy_asset_peer_prepared` | `economy_runtime.cpp:880,1109,3458,3466,3473,3636,3643,3651,3759,3767,3774,3932`；`economy_runtime_colonization_kit.cpp:1486,1751`；`economy_runtime_procurement.cpp:779,787` | `AssetPeerPreparedAck` | 随相应业务路径 | 含接受和拒绝分支；事务/session/双方 generation 必须匹配 |
| `begin_economy_cash_from_cohort` | `economy_runtime.cpp:3607` | `CashFromCohortIntent` | 3 | 遗产/余款交国库后才可回收人口槽；不能延迟到下日 |
| `begin_economy_cash_to_cohort` | `economy_runtime.cpp:3604` | `CashToCohortIntent` | 3 | 国库扣款与 cohort 收入同日守恒；保留同线程完成边界 |
| `begin_economy_fiscal_collect` | `economy_runtime.cpp:3429` | `FiscalCollectIntent` | 2 | 已代扣税转入国库；不能先销 escrow 后丢失国家提交 |
| `begin_economy_fiscal_reserve` | `economy_runtime.cpp:3423` | `FiscalReserveIntent` | 2 | 预算封存决定后续补贴；保留现金裁剪及冻结国家句柄 |
| `begin_economy_fiscal_return` | `economy_runtime.cpp:3426` | `FiscalReturnIntent` | 1（首选候选） | 退回既有 escrow；须保持 transport_request_id、同日终态和审计前回写 |
| `begin_economy_good_from_market` | `economy_runtime.cpp:3734`；`economy_runtime_colonization_kit.cpp:1725`；`economy_runtime_procurement.cpp:764` | `GoodFromMarketIntent` | 4 | 交易同时涉及市场库存和付款；采购延续状态不能丢失 |
| `begin_economy_good_to_market` | `economy_runtime.cpp:3731` | `GoodToMarketIntent` | 4 | 物资列、市场所有者、库存裁剪和重复提交身份 |
| `begin_economy_research_purchase` | `economy_runtime.cpp:1072` | `ResearchPurchaseIntent` | 5 | 市场扣库存、国库扣钱、研究点入账和 continuation 须一起完成 |
| `begin_economy_treasury_spend` | `economy_runtime.cpp:3911`；`economy_runtime_colonization_kit.cpp:1469` | `TreasurySpendIntent` | 5 | 建造/殖民/军饷可能多物资、全额成功；保留预检和 peer 更新顺序 |
| `collect_fiscal_cash` | `economy_runtime_military_view.cpp:319` | `MilitaryTreasuryCollectIntent` | 6 | 与上条成对迁移；军事日表执行位置仍不动 |
| `commit_economy_asset_transaction` | `economy_runtime.cpp:1123,3481,3659,3782,3940`；`economy_runtime_colonization_kit.cpp:1494,1760`；`economy_runtime_procurement.cpp:794` | `ApplyPreparedAssetIntent` | 随相应业务路径 | 只能在 peer 预检通过的原位置应用；不得重新排序 |
| `reserve_fiscal_cash` | `economy_runtime_military_view.cpp:316` | `MilitaryTreasuryReserveIntent` | 6 | 原 military_collect_cash 立即调用 reserve 再 collect；单迁一半会改变会计窗口 |

优先候选是 FISCAL_RETURN：现有资金从经济 escrow 返回国库，金额边界和零误差最易核对。S4 当时只做设计，未试加/回退队列；S5 实施结果见后文。已有 `RuntimeEconomyAssetRequest`（`runtime_pod_protocol.h:950`）包含类型、day、operation_sequence、request_id、continuation_index、双方 generation；`gdext/src/native_simulation_host_asset_worker.cpp:320` 按日期/序号/延续位置/id 排序。后续应复用这条所有者消费通道，避免再造独立序号或第二份待处理存档。

建议端到端方案：由经济在原 `coordinate_country_fiscal_transaction` 调用点构造 FiscalReturnIntent，复用现有 transport_request_id；Country 在原 prepare/Apply 点接受、验证和应用，经济仅在原终态消费点减少 escrow、发 peer-applied 回执。同步模式如需排队，必须在原调用点消费并返回结果；不能把即时结果改成下一日完成。`gdext/src/native_simulation_host_asset_worker.cpp:392` 的 finish 会提交国家并发布其快照，随后经济才审计；cohort cash 还有 `gdext/src/native_simulation_host_asset_worker.cpp:342` 的同线程 prepare。这些边界已存在，不属于本次新增成果。

S4 提出的验证要求为：FISCAL_RETURN 需补 的非空请求、拒绝、重复提交、保存恢复、OFF/SHADOW/ACTIVE 各路径证据；当前八日黄金没有完整覆盖这些分支。若需要改变应用顺序、保存字节、守恒或任一既有链，应撤回该原型并另行审查。公开协议和绑定全部保留；S5 具体覆盖及未验证分支见后文，不把一个同步端口说成通用队列迁移。


## S5 当前写入边界

已实现一个 FISCAL_RETURN 同步请求端口（`country_fiscal_return_intent.{h,cpp}`）。这不是通用异步总线：已有 worker `RuntimeEconomyAssetRequest` 队列保持原样；同步请求由 Country 在调用点立即消费，沿用它的日期、下一序号与下一 transaction id，先验证顺序身份，再走原事务。经济在原位置做 escrow 预检、Country apply、escrow 扣减与 applied ACK，不引入跨日等待。所有者保存格式、请求编号分配和 worker 排序不变。拒绝仍返回旧事务错误；新增过期顺序键会返回 `country_fiscal_return_intent_order_mismatch`，这项负例未做动态覆盖。

S4 留存表是当时行号；本轮实测起点是 **47** 处直接写调用（31+9+5+2），不是任务描述中的 46。S5 后为 **46**：主文件30、其余16。共享 prepare/commit/ACK 仍用于未迁移操作，不能从词数里减去它们的全部出现次数。`check_cpp_deps.py` 的 `country_writes` 按文件/方法冻结剩余调用数，只许减少；在经济实现内出现 `begin_economy_fiscal_return`（包括别名或方法指针）直接失败，禁止恢复旧入口。扫描仍非完整 C++ 权限检查，新增别名/宏需人工审查。

| 尚未迁移的直接写方法 | 当前全部位置 |
| --- | --- |
| `acknowledge_economy_asset_peer_applied`（9） | `economy_runtime.cpp:1212`；`economy_runtime.cpp:3453`；`economy_runtime.cpp:3637`；`economy_runtime.cpp:3754`；`economy_runtime.cpp:3927`；`economy_runtime_colonization_kit.cpp:1421`；`economy_runtime_colonization_kit.cpp:1500`；`economy_runtime_colonization_kit.cpp:1513`；`economy_runtime_procurement.cpp:541` |
| `acknowledge_economy_asset_peer_prepared`（16） | `economy_runtime.cpp:880`；`economy_runtime.cpp:1109`；`economy_runtime.cpp:3409`；`economy_runtime.cpp:3417`；`economy_runtime.cpp:3425`；`economy_runtime.cpp:3589`；`economy_runtime.cpp:3596`；`economy_runtime.cpp:3604`；`economy_runtime.cpp:3712`；`economy_runtime.cpp:3720`；`economy_runtime.cpp:3727`；`economy_runtime.cpp:3885`；`economy_runtime_colonization_kit.cpp:1486`；`economy_runtime_colonization_kit.cpp:1751`；`economy_runtime_procurement.cpp:779`；`economy_runtime_procurement.cpp:787` |
| `begin_economy_cash_from_cohort`（1） | `economy_runtime.cpp:3560` |
| `begin_economy_cash_to_cohort`（1） | `economy_runtime.cpp:3557` |
| `begin_economy_fiscal_collect`（1） | `economy_runtime.cpp:3377` |
| `begin_economy_fiscal_reserve`（1） | `economy_runtime.cpp:3371` |
| `begin_economy_good_from_market`（3） | `economy_runtime.cpp:3687`；`economy_runtime_colonization_kit.cpp:1725`；`economy_runtime_procurement.cpp:764` |
| `begin_economy_good_to_market`（1） | `economy_runtime.cpp:3684` |
| `begin_economy_research_purchase`（1） | `economy_runtime.cpp:1072` |
| `begin_economy_treasury_spend`（2） | `economy_runtime.cpp:3864`；`economy_runtime_colonization_kit.cpp:1469` |
| `collect_fiscal_cash`（1） | `economy_runtime_military_view.cpp:319` |
| `commit_economy_asset_transaction`（8） | `economy_runtime.cpp:1123`；`economy_runtime.cpp:3433`；`economy_runtime.cpp:3612`；`economy_runtime.cpp:3735`；`economy_runtime.cpp:3893`；`economy_runtime_colonization_kit.cpp:1494`；`economy_runtime_colonization_kit.cpp:1760`；`economy_runtime_procurement.cpp:794` |
| `reserve_fiscal_cash`（1） | `economy_runtime_military_view.cpp:316` |

后续建议仍按 S4 表：FISCAL_RESERVE/COLLECT → cohort cash → 货物 → 研究/大额支出 → 军事成对收支。上述后续迁移**未开始**。不要延迟那些必须即时完成才可释放人口槽或完成守恒检查的写入。

`economy_runtime_asset_receipts.cpp` 只是原样移出三个回执辅助函数（54 行），不代表第二条业务迁移或删除旧实现。主文件 26748→26701（净减47），host 14888 行未改。依赖仍为433键/421债务键，header_exposed=522、total=2400；本轮减少的是直接写调用，不是类型引用数量。

验证：专用非零返还用例比对旧二进制两次捕获的完整回执、Country/PKEC 保存流及恢复后输出；黄金四链10/10相同。具体值与未覆盖分支见 current-state.md。没有删除任何公开写方法/绑定，Country→Economy 未改。


## S6 当前写入边界（替代 S5 的剩余数量）

采购5处和同族财政7处已迁移，剩余 **34** 处。CountryProcurementPort复用CountryFiscalReturnPort的顺序键和完成协议；不是另一条延迟队列。同步请求在原调用点被所有者立即消费，worker已有队列在此之前接管。该接口只减少经济直接写Country的方法连接，未消除其NativeCountryRuntime常量/指针，也未迁移Country→Economy。

采购保存原先预检/quantity drift拒绝/commit/市场库存扣减/商人分账/ACK顺序。财政保持Country现金先提交、经济escrow再更新、最后ACK。暂存于栈上的类型化请求不新增保存字段；回执仍是原Dictionary。

| 仍未迁移方法 | 数量 | 当前所有位置 |
| --- | --- | --- |
| `acknowledge_economy_asset_peer_applied` | 7 | `economy_runtime.cpp:1212`；`economy_runtime.cpp:3627`；`economy_runtime.cpp:3744`；`economy_runtime.cpp:3917`；`economy_runtime_colonization_kit.cpp:1421`；`economy_runtime_colonization_kit.cpp:1500`；`economy_runtime_colonization_kit.cpp:1513` |
| `acknowledge_economy_asset_peer_prepared` | 11 | `economy_runtime.cpp:880`；`economy_runtime.cpp:1109`；`economy_runtime.cpp:3579`；`economy_runtime.cpp:3586`；`economy_runtime.cpp:3594`；`economy_runtime.cpp:3702`；`economy_runtime.cpp:3710`；`economy_runtime.cpp:3717`；`economy_runtime.cpp:3875`；`economy_runtime_colonization_kit.cpp:1486`；`economy_runtime_colonization_kit.cpp:1751` |
| `begin_economy_cash_from_cohort` | 1 | `economy_runtime.cpp:3550` |
| `begin_economy_cash_to_cohort` | 1 | `economy_runtime.cpp:3547` |
| `begin_economy_good_from_market` | 2 | `economy_runtime.cpp:3677`；`economy_runtime_colonization_kit.cpp:1725` |
| `begin_economy_good_to_market` | 1 | `economy_runtime.cpp:3674` |
| `begin_economy_research_purchase` | 1 | `economy_runtime.cpp:1072` |
| `begin_economy_treasury_spend` | 2 | `economy_runtime.cpp:3854`；`economy_runtime_colonization_kit.cpp:1469` |
| `collect_fiscal_cash` | 1 | `economy_runtime_military_view.cpp:319` |
| `commit_economy_asset_transaction` | 6 | `economy_runtime.cpp:1123`；`economy_runtime.cpp:3602`；`economy_runtime.cpp:3725`；`economy_runtime.cpp:3883`；`economy_runtime_colonization_kit.cpp:1494`；`economy_runtime_colonization_kit.cpp:1760` |
| `reserve_fiscal_cash` | 1 | `economy_runtime_military_view.cpp:316` |

后续建议：cohort现金双向与其ACK → 通用物资及殖民采购 → research/treasury spend → 军事成对收支。风险仍是人口槽回收前必须完成现金转移、多物资全额成功、市场/国库同时守恒；本轮没有试改这些34处，状态为未开始，不能称为“不可迁移”。所选12处无撤回项。原清单的建议intent类型仍适用。

护栏：经济任何文件出现`begin_economy_fiscal_return/reserve/collect`词（含别名/方法指针）会失败；采购文件及财政协调函数中的旧完成协议词也失败；其它写入按文件/方法的次数基线只许减少。新端口工厂被明确放行，不放宽只读绕行、头文件或跨域预算。参考 `check_cpp_deps.py` 的 `country_write_errors` 与11项护栏测试。

表外依赖仍是登记而非调度迁移。v5读取军事国家投影、全地图资源列、家庭/人物投影和已发布视野；完整范围/缺口见 current-state.md 的S6表。军事向下一日提交意图的时点、本轮全部所有者与线程均未改。


## S7 当前写入边界（替代 S6 的剩余数量）

直接写入 **34→2**；跨域类型/包含引用仍433键（421债务键），header_exposed=522、total=2400。剩下两处是有明确覆盖缺口的暂缓项，不代表它们已经证明无法接口化。Country→Economy方向、worker队列与公共绑定均未改。

| 本轮分组 | 转接处数 | 当前入口（gdext/src/） | 保留的顺序与证据 |
| --- | --- | --- | --- |
| cohort现金双向、市场物资双向及完成协议 | 14 | economy_runtime.cpp:3461,3636 → country_fiscal_return_intent.cpp:43 | 先worker路由，再在原同步点构造TransferIntent；Country Apply后写经济余额/库存，再ACK。用例实际转移500000/12345现金及10000/4321物资 |
| 科研采购及完成协议 | 5 | economy_runtime.cpp:859 → country_fiscal_return_intent.cpp:67 | 保留continuation各phase，不跨phase留借用请求；采购100000点，现金1017900；全部回执与保存流对照迁移前 |
| 国库建造支出及完成协议 | 4 | economy_runtime.cpp:3753 → country_fiscal_return_intent.cpp:78 | 保留市场与商人预检、多物资全额提交、原分账及ACK；实际现金114029 |
| 殖民市场采购、国库转出及完成协议 | 9 | economy_runtime_colonization_kit.cpp:1341及发起采购函数 | 复用procurement_port和SpendIntent；保留“市场→国库→远征货物”的两次原提交，不合并。专用用例包含5对8/9操作，资金130290、4104、130290、488480、98800 |

`CountryFiscalReturnPort`沿用历史名称，目前也承载上述类型化请求与共同完成协议。TransferIntent/ResearchIntent/SpendIntent均带原所有者生成的day/sequence/request_id；SpendIntent只借用既有数组并立即消费，不能跨pulse保存。没有建立第二条排队通道，没有新持久字段；返回值仍是原Godot事务字典。重复提交/过期顺序键等异常组合未新增全面动态覆盖，不将成功用例等同于协议全覆盖。

| 暂不可迁移项（逐条） | 必须保持的边界 / 暂缓理由 | 后续设计与验证 |
| --- | --- | --- |
| economy_runtime_military_view.cpp:316 `reserve_fiscal_cash`（1处） | 与随后collect配对，即时取得国库实际扣款；现有v5无士兵/军费，没有证明这笔资金转移及裁剪 | 先做有士兵、非零军饷/返还、国库不足裁剪的独立固定用例及保存往返；再成对使用原位置消费的intent。若以后要延迟消费，需先设计预留+确认 |
| economy_runtime_military_view.cpp:319 `collect_fiscal_cash`（1处） | 依赖上一步返回金额；单迁一半可能改变中间会计窗口；同样覆盖不足 | 与reserve共同验证金额、顺序与回执；本轮不移动军事执行位置 |

`cpp_deps_baseline.json`的country_writes只剩上述两个键，各自附country_write_exceptions原因。检查器全局禁止经济实现内所有已迁移旧方法的词（包括别名/方法指针），军事例外不得移到别的文件或增长；声明/公开绑定仍保留。文本检查仍不是完整C++权限系统，宏和间接连接必须审查。

专用用例为asset_transfer_intent/research_intent/treasury_spend_intent/colonization_intent_test.gd，各有独立迁移前JSON基线；intent_save_evidence.gd只用于测试。保存流逐位等价指“同一用例改前/改后输出相同”，不声称所有恢复后重编码都等于输入：殖民原有Modifier版本字节1→3被显式记录，两边完整SHA256都入参照；逻辑国家与经济哈希另行检查。

开关注册表属于通用宿主支撑，不持有域状态；各域只通过RuntimeSwitch枚举读取原始环境值，解析与默认值归原调用点。它不获得修改Country/Economy状态的权限。登记元数据中的diagnostic_only是用途描述，不是新的运行门禁。


## S8 文件边界与实验限制

Host拆为17个同类成员实现文件，职责/行数表见current-state.md；核心仍拥有原有锁、队列、store与控制面。`native_simulation_host_support.h`只共享无状态匿名函数，带静态缓存的函数不得复制到多个编译单元。不得把搬文件当成消除跨域访问。依赖护栏实测仍为433引用键/421债务键，header_exposed=522、total=2400，Country直接写2；未提高依赖基线。

测试专用的外围按日入口复用原资源与军事drain，限主线程、同日已提交、worker空闲、原资源回写成功且下一日尚未提交。资源读取当前live cells/气候/Modifier并写资源列和逐格日期；军事读取国家/经济并写军事状态、口粮视图、D+1请求和事件。正式宿主仍逐帧追赶，读档/积压等边界尚未验证，生产日表接入未开始。旧过程文档已清理，29份待决定文档未动。


## S9 军事现金两阶段方案（设计，未实现）

以下保留S9当时的评估；确认语义已经被后文S11修订，勿把reserve+collect当作现行军饷接入规则。

两处白名单仍为 `economy_runtime_military_view.cpp:316` 的 reserve 和 `:319` 的 collect，检查器和计数 **2→2** 不变。不能把它们概括成“已证明必须同步”：已确认的是当前调用立即返回实际金额，接收方在同一调用窗口据此记账；异步迁移需要新的持续状态，且非零路径覆盖不足。

| 已核实连接 | 当前行为 / 证据 |
| --- | --- |
| 军事 D+1 桥接 | `world_ext_military.cpp:1750` 的 `apply_military_deferred_cash` 按 pending 数组原顺序处理已到日的 authority=3 请求；经济命令窗口关闭就重试；调用后以实际返回额更新 amount/count/receipt_pending。原 receipt 超时处理在 `:1732` 附近 |
| 另一调用方 | `runtime_economy_army_personnel.cpp:673` 的同步军饷分支立即给军队人口资金和收入加上返回值；worker 分支 `:699` 则用现有 TREASURY_SPEND peer 通道在同一经济结算窗口 prepare/service/finish，不能把二者混为一条路径 |
| 实际 reserve/collect | `country_runtime.cpp:9751,9761` → `:7201,7215` → `:7170` 的兼容完成器，分别做 begin/prepared/commit/applied；不是仅设置一个临时预留后才共同提交 |
| 重要的语义疑点 | `country_runtime.cpp:7003` 把 FISCAL_COLLECT 列为 credits_country；`:7025` 附近对它增加国库现金，reserve 则减少。两步都成功且中间无其它写入时，静态推导是国库现金先减后加，净额零；与军事桥接“debit/non-tax expenditure”注释不符。同步军饷分支还增加接收方余额。**S9时仅为静态推导；S10已在独立原生付款分支复现现金多12345，见current-state.md的S10证据；正式整图军费路径尚未动态验证。** |
| 存档边界 | Country `begin_save` 在有未完成资产事务时拒绝，`country_runtime.cpp:11366`；读档清空在途事务并将预留列置零，`:11347`。军事 adapter 自己保存 pending 行、sequence、request_id，`world_ext_military.cpp:3389,3412,3421`；但没有一个跨 Country 与军事的持久两阶段预留对象 |

拟议的预留记录（字段名是设计，不是现存 API）：`session_epoch, country_generation, country_handle, receiver_handle/source_id, effective_day, sequence, request_id, requested_amount, reserved_amount, confirmed_amount, reserve_transaction_id, confirm_transaction_id, phase, terminal_receipt, expiry_day`。原请求、预留和确认必须能互相关联；排序沿用原 pending 顺序与既有请求分配器，不能另按句柄重排。Country 所有者持有资金预留，军事只持有请求身份及回执状态，不缓存可独立花费的余额。

1. **预留**：沿现有 worker 资产通道申请，Country 在原允许写入的位置按可用金额裁剪，返回唯一身份与金额。保持已有请求先后顺序，不插入第二条优先队列。若走同步兼容路径，仍须等同日、原命令窗口内完成两步，不能用“已排队”冒充成功金额。
2. **确认**：只有接收方有能力记账，才使用同一预留身份请求确认；Country 完成原定操作后，接收方应用一次、再 ACK。重发返回原回执，不再转移资金。先确定上述 collect 语义疑点的正确产品口径，再决定确认是旧等价两笔操作还是新的净支出；后者是行为修复，不属于机械迁移。
3. **取消/过期**：未决定提交的预留可释放；已决定提交的只能补完，不能超时当作从未发生。期限用模拟日，不用墙钟；到期处理与同日确认的顺序要固定。现有 pending 超时不能直接删除一个已经占用 Country 资金的记录。跨日超时规则的取值需要单独审定，本轮不新增默认值。
4. **保存/崩溃/读档**：当前格式只允许在途事务清空后保存。若保持此规则，可在保存前完成/取消预留，拒绝尚未收齐回执的保存；这仍需要验证不会改变既有保存边界。若允许预留跨保存，必须为 Country 资产日志和军事 adapter 的关联身份、金额、phase、终态去重记录设计版本升级，两个分段由同一个提交点捕获。读档先重建占用与去重，再续跑；编号分配器大于全部历史编号。不得读档清零占用却保留军事待确认行。崩溃只能恢复最后一个一致存档；没有持久提交决定就不能承诺崩溃前未保存操作恰好一次。
5. **验证门槛**：有士兵的非零军饷、资金不足裁剪、零额、重复确认、取消、同日到期冲突、worker backpressure、两种权威路径、各 phase 保存/读档/中断，以及 Country+军队+托管合计守恒。还要固定原始完整保存流与回执作为参照；v5 的移动目标/自然恢复覆盖不能替代这些用例。

本轮结论：**只交设计，代码原型未开始**。既有五条链不含上述非零现金证明；真正延迟的两阶段机制又会触及顺序、在途保存或 schema。先做非零旧路径复现并决定 collect 语义，再讨论原位置等价端口或持久预留。现有白名单及原实现全部保留。


## S10：原所有者不变，未迁移两处军事写入

审计、研究需求、回执服务与建筑适配器的新cpp仍属于NativeEconomyRuntime；没有新状态所有者、队列、数据布局或Country写法。依赖仍433引用键/421债务键、header_exposed522/total2400，直接写仍2。`country_reads()`判空与视图调用不需要搬入Country完整头，是本次可拆1,001行的来源。

两处白名单仍为`economy_runtime_military_view.cpp:316`的reserve和`:319`的collect。S10动态证据将阻塞从“覆盖不足”进一步明确为：同步原生付款净增加现金，不能把旧两笔事务机械包装成正确的转账。下一步需要批准行为修正，并分别确定工资接收方与D+1 SPEND_CASH的消耗口径；已有worker TREASURY_SPEND可作候选，不新建第二队列。未完成的持久预留设计、day/sequence/request_id/回执、保存schema要求仍沿S9方案，代码原型未开始。不要通过修改两处白名单或当前五链掩盖这个缺陷。

### S10 未搬函数与依赖键清单

下面每行的候选文件为`gdext/src/economy_runtime_split_<函数名小写>.cpp`。键格式仍为`候选文件|域对|引用`；表内给后两段，所有这些键当前额度为0。行号为S10后主文件位置；只列依赖扫描已确认的最低集合，真实编译还可能需要其它include。逐函数候选合计167个新债务键；合并候选文件会改变数量，不能消除新增键违规。完整机器清单与按原规则试算输入在`/tmp/keynes-arch-phase1/stage10/blocked-moves.json`和`dependency-proposals/`。

`moved_from`在`check_cpp_deps.py:135`限定h→cpp，同目录且同名前缀；没有cpp→cpp豁免。不能借此提高基线、藏入中转头或换文件归属。若以后允许等量cpp迁移，需另行审定并机检“源减少、目标相等增加、总量/头暴露/域对不增”的规则；本轮未实施。

| 函数（economy_runtime.cpp:行） | 候选会新增的键（去掉文件前缀） |
| --- | --- |
| `advance_country_research_procurement` :143 | `economy->country / include:country_runtime.h`；`economy->country / type:CountryResearchProcurementContinuation`；`economy->country / type:CountryWorkerAssetRoute`；`economy->country / type:NativeCountryRuntime` |
| `block_or_enqueue_country_worker_asset` :508 | `economy->country / type:CountryWorkerAssetRoute` |
| `block_or_enqueue_country_worker_asset` :524 | `economy->country / type:CountryWorkerAssetRoute` |
| `pull_owned_command_result` :605 | `economy->country / type:NativeCountryRuntime` |
| `sync_owned_family_store` :718 | `family->economy / include:economy_runtime.h`；`family->economy / type:NativeEconomyRuntime`；`family->economy / type:RuntimeEconomyFamilyStore` |
| `coordinate_country_fiscal_transaction` :1002 | `economy->country / include:country_runtime.h`；`economy->country / type:CountryWorkerAssetRoute`；`economy->country / type:NativeCountryRuntime` |
| `coordinate_country_cohort_cash` :1156 | `economy->country / include:country_runtime.h`；`economy->country / type:CountryWorkerAssetRoute`；`economy->country / type:NativeCountryRuntime` |
| `coordinate_country_market_goods` :1331 | `economy->country / include:country_runtime.h`；`economy->country / type:CountryWorkerAssetRoute`；`economy->country / type:NativeCountryRuntime` |
| `coordinate_country_treasury_spend` :1448 | `economy->country / include:country_runtime.h`；`economy->country / type:CountryWorkerAssetRoute`；`economy->country / type:NativeCountryRuntime` |
| `run_government_research_procurement` :1621 | `economy->country / type:CountryResearchProcurementCandidate`；`economy->country / type:CountryResearchProcurementContinuation` |
| `advance_worker_resource_reserves` :1969 | `economy->modifier / type:ModifierRuntime` |
| `country_reads` :2128 | `economy->country / include:country_runtime.h` |
| `cell_has_technology` :2132 | `economy->country / type:NativeCountryRuntime` |
| `capture_country_epoch` :2155 | `economy->country / type:NativeCountryRuntime`；`economy->modifier / include:modifier_runtime.h`；`economy->modifier / type:ModifierRuntime` |
| `refresh_city_modifier_factors` :3406 | `economy->modifier / include:modifier_runtime.h`；`economy->modifier / type:ModifierRuntime` |
| `neighbor_count_with_tag` :3609 | `economy->effect / type:EffectRuntime` |
| `refresh_city_output_modifier_factors` :3631 | `economy->modifier / include:modifier_runtime.h`；`economy->modifier / type:ModifierRuntime` |
| `prepare_building_economic_plan_body` :3778 | `economy->country / type:NativeCountryRuntime` |
| `pay_building_wage_amount` :5370 | `economy->country / type:NativeCountryRuntime` |
| `refresh_building_modifier_factors` :5495 | `economy->modifier / include:modifier_runtime.h`；`economy->modifier / type:ModifierRuntime` |
| `effective_building_output_quantity_for_target` :5723 | `economy->modifier / include:modifier_runtime.h`；`economy->modifier / type:ModifierRuntime` |
| `projected_owner_income_per_day` :5829 | `economy->country / type:NativeCountryRuntime` |
| `owner_opportunity_quote_uncached` :6032 | `economy->country / type:NativeCountryRuntime` |
| `projected_employee_tax_retention_q16` :6921 | `economy->country / type:NativeCountryRuntime` |
| `find_entrepreneur_source` :6952 | `economy->family / type:FamilyMembershipEdge` |
| `apply_family_population_reward` :7134 | `family->economy / include:economy_runtime.h`；`family->economy / type:EventLeg`；`family->economy / type:NativeEconomyRuntime`；`family->economy / type:Stage` |
| `apply_family_absorb_anonymous` :7259 | `family->economy / include:economy_runtime.h`；`family->economy / type:NativeEconomyRuntime` |
| `apply_family_colonization_population_reward` :7304 | `family->economy / include:economy_runtime.h`；`family->economy / type:EventLeg`；`family->economy / type:NativeEconomyRuntime`；`family->economy / type:Stage` |
| `apply_command` :7392 | `economy->country / type:NativeCountryRuntime` |
| `commit_structural` :7767 | `economy->country / type:NativeCountryRuntime` |
| `move_cohort_population` :7912 | `economy->country / type:NativeCountryRuntime`；`economy->family / type:FamilyMovePlanRow` |
| `run_slice_internal` :8172 | `economy->effect / include:effect_runtime.h`；`economy->effect / type:EffectCommandResult` |
| `family_population` :9152 | `family->economy / include:economy_runtime.h`；`family->economy / type:NativeEconomyRuntime` |
| `family_cash_claim` :9182 | `family->economy / include:economy_runtime.h`；`family->economy / type:NativeEconomyRuntime` |
| `family_owned_buildings` :9214 | `family->economy / include:economy_runtime.h`；`family->economy / type:NativeEconomyRuntime` |
| `assign_core_family_traits` :9234 | `family->economy / include:economy_runtime.h`；`family->economy / type:NativeEconomyRuntime` |
| `rebuild_family_behavior_cache` :9259 | `family->economy / include:economy_runtime.h`；`family->economy / type:EconomyCostProbe`；`family->economy / type:NativeEconomyRuntime` |
| `fill_family_behavior_metrics` :9578 | `family->country / type:CountryClassOpinionSnapshot`；`family->economy / include:economy_runtime.h`；`family->economy / type:BuildingType`；`family->economy / type:NativeEconomyRuntime`；`family->economy / type:TagSnapshot` |
| `sample_effect_metrics` :10601 | `economy->effect / type:EffectMetricOverrideSet` |
| `family_trait_behavior_factor_q16` :10639 | `family->economy / include:economy_runtime.h`；`family->economy / type:NativeEconomyRuntime` |
| `family_behavior_score_term_q16` :10740 | `family->economy / include:economy_runtime.h`；`family->economy / type:NativeEconomyRuntime` |
| `family_purchase_pay_factor_q16` :10800 | `family->economy / include:economy_runtime.h`；`family->economy / type:NativeEconomyRuntime` |
| `family_free_building_type_id` :10829 | `family->economy / include:economy_runtime.h`；`family->economy / type:NativeEconomyRuntime` |
| `family_consumption_factor_q16` :10885 | `family->economy / include:economy_runtime.h`；`family->economy / type:NativeEconomyRuntime` |
| `family_good_consumption_factor_q16` :10926 | `family->economy / include:economy_runtime.h`；`family->economy / type:NativeEconomyRuntime` |
| `preferred_family_for_cohort` :10964 | `family->economy / include:economy_runtime.h`；`family->economy / type:NativeEconomyRuntime` |
| `rebuild_family_effect_binding_index` :11009 | `family->economy / include:economy_runtime.h`；`family->economy / type:NativeEconomyRuntime` |
| `add_family_effect_binding` :11028 | `family->economy / include:economy_runtime.h`；`family->economy / type:NativeEconomyRuntime` |
| `remove_family_effect_binding` :11048 | `family->economy / include:economy_runtime.h`；`family->economy / type:NativeEconomyRuntime` |
| `publish_family_effect_metrics` :11081 | `family->economy / include:economy_runtime.h`；`family->economy / type:NativeEconomyRuntime` |
| `clear_family_branch_effects` :11107 | `family->economy / include:economy_runtime.h`；`family->economy / type:NativeEconomyRuntime`；`family->modifier / include:modifier_runtime.h` |
| `reconcile_family_branch_effects` :11186 | `family->economy / include:economy_runtime.h`；`family->economy / type:NativeEconomyRuntime`；`family->effect / include:effect_runtime.h`；`family->effect / type:EffectRuntime`；`family->modifier / include:modifier_runtime.h` |
| `rebuild_family_indices` :11916 | `family->economy / include:economy_runtime.h`；`family->economy / type:EconomyCostProbe`；`family->economy / type:NativeEconomyRuntime` |
| `normalize_family_memberships` :12141 | `family->economy / include:economy_runtime.h`；`family->economy / type:EconomyCostProbe`；`family->economy / type:NativeEconomyRuntime` |
| `family_people_on_slot` :12282 | `family->economy / include:economy_runtime.h`；`family->economy / type:NativeEconomyRuntime` |
| `family_owned_owner_slots_in_cell` :12300 | `family->economy / include:economy_runtime.h`；`family->economy / type:NativeEconomyRuntime` |
| `add_family_household_people` :12325 | `family->economy / include:economy_runtime.h`；`family->economy / type:NativeEconomyRuntime` |
| `absorb_family_households` :12366 | `family->economy / include:economy_runtime.h`；`family->economy / type:NativeEconomyRuntime` |
| `attribute_family_owner_employment_for_cell` :12488 | `family->economy / include:economy_runtime.h`；`family->economy / type:NativeEconomyRuntime` |
| `sanitize_family_membership_edge` :12589 | `family->economy / include:economy_runtime.h`；`family->economy / type:NativeEconomyRuntime` |
| `sanitize_family_ownership_edges` :12604 | `family->economy / include:economy_runtime.h`；`family->economy / type:NativeEconomyRuntime` |
| `update_family_employment_attribution` :12645 | `family->economy / include:economy_runtime.h`；`family->economy / type:NativeEconomyRuntime` |
| `create_family_for_building` :12746 | `family->economy / include:economy_runtime.h`；`family->economy / type:NativeEconomyRuntime` |
| `build_family_split_offer` :12889 | `family->economy / include:economy_runtime.h`；`family->economy / type:NativeEconomyRuntime` |
| `resolve_family_split_offer` :13166 | `family->economy / include:economy_runtime.h`；`family->economy / type:NativeEconomyRuntime`；`family->economy / type:PendingFamilySplitGift` |
| `split_family_branches` :13303 | `family->economy / include:economy_runtime.h`；`family->economy / type:NativeEconomyRuntime` |
| `dissolve_family` :13341 | `family->economy / include:economy_runtime.h`；`family->economy / type:NativeEconomyRuntime` |
| `rebuild_family_influences` :13371 | `family->economy / include:economy_runtime.h`；`family->economy / type:NativeEconomyRuntime` |
| `apply_due_family_trait_commands` :13645 | `family->economy / include:economy_runtime.h`；`family->economy / type:NativeEconomyRuntime` |
| `review_family_lifecycle` :13736 | `family->economy / include:economy_runtime.h`；`family->economy / type:NativeEconomyRuntime` |
| `advance_household_market_chunk` :13792 | `economy->country / type:NativeCountryRuntime` |
| `run_ledger_apply_drain` :14629 | `economy->effect / type:EffectCommandResult` |
| `retire_person` :14700 | `economy->modifier / include:modifier_runtime.h` |
| `register_person_effect` :14729 | `economy->modifier / include:modifier_runtime.h` |
| `promote_person_for_family` :14757 | `family->economy / include:economy_runtime.h`；`family->economy / type:NativeEconomyRuntime` |
| `bind_notable_person_jobs` :14908 | `economy->family / type:FamilyBuildingOwnership` |
| `reconcile_person_claims` :15001 | `economy->family / type:FamilyMembershipEdge` |
| `sponsor_family_for_cohort` :15045 | `family->economy / include:economy_runtime.h`；`family->economy / type:NativeEconomyRuntime` |
| `state_hash_internal` :15068 | `economy->country / type:NativeCountryRuntime`；`economy->family / type:FamilyBuildingOwnership`；`economy->family / type:FamilyExpeditionCargoLine`；`economy->family / type:FamilyExpeditionKitBuilding`；`economy->family / type:FamilyExpeditionPayload`；`economy->family / type:FamilyMembershipEdge`；`economy->family / type:FamilyTraitCommand`；`economy->family / type:FamilyTraitRoll`；`economy->modifier / include:modifier_runtime.h`；`economy->modifier / type:ModifierRuntime` |


## S11-A 先行评估（2026-11-04，生产修改前记录）

结论：授权修复范围限定为 `runtime_economy_army_personnel.cpp:673` 的同步军饷调用。使用既有 Country 端口只完成一次 FISCAL_RESERVE 的 begin/prepared/commit/applied，随后仍在原位置给军队记入实际扣款。不修改共用 `military_collect_cash`：D+1 SPEND_CASH 也调用它，贸然去掉 collect 会把维护/建造的现有净零操作改成无接收方的扣款，其消耗账目尚未核实，不属于这次军饷修复。此处是风险隔离，不宣称已修复整个军事财政。

| 入口 | 已核实事实 / 证据 |
| --- | --- |
| 玩家军事日推进 | `world_runtime_host.gd:3575` 调 facade.run_daily；`military_facade.gd:228` → `run_military_daily`，绑定在 `world_ext_bind_methods.cpp:437`。MilitaryCore 产生军饷/招兵等意图，桥接再走 Economy 入口 |
| 普通脚本/GM 的经济入口 | `economy_runtime_configuration.cpp:1517` 验证只接受 1–19 和特定家族命令，30/34 被拒；S10独立测试已测，S11将重跑。公开 `apply_pod_command` 是 C++ 方法，不是 Godot 绑定，不能用其测试结果声称普通GDScript可直接调用 |
| 军事命令与 AI | `military_facade.gd:349` army.create 与 `military_core_ai.cpp:383` 起的军队创建/调动均走 MilitaryCore；`world_ext_military.cpp:1448` 桥接先尝试普通入口，仅 legacy_ingress_disabled 时在 `:1528` 后转 POD；`:1632` 提交 lane。POD在 `runtime_economy_pod.cpp:1674` 接受30–34。普通入口拒绝并不证明所有生产配置都不可达 |
| ACTIVE整图军饷 | `runtime_economy_army_personnel.cpp:653` 的 Country worker 权威与操作闸门条件满足时用 `pay_army_lane_from_worker_country`，`:699` 后为 TREASURY_SPEND 的 prepare/service/finish，接收方由 peer 入账。本轮不改。混合权威/闸门关闭能否实际到同步分支未作全配置动态覆盖；原生测试明确可达 |
| 征兵、入伍、维护费 | 征兵/转职和30号入伍本身搬运人口及原资金，并非这笔军饷；34号才付款。`military_core.cpp:2343,3322` 的维护/建造 SPEND_CASH → `world_ext_military.cpp:2030` authority=3 → `:1750` D+1共用helper；不是军队资金接收路径，本轮保留 |
| 读档 | `world_ext_military.cpp:3389` 保存pending请求，`:3434`后恢复；Economy保存军队funds，Country保存国库。历史上若进入有缺陷的同步分支，增加的钱可随正常余额保存；现有格式没有能可靠区分合法余额与该错误增量的来源标记。没有检查用户实际存档，不能断言已有存档受损，也不能自动扣钱 |

正确语义是国库减少X、军队增加X：`docs/plans/military-system-design.md:79,717` 明确军饷不是铸币。Country事务契约不是按军事注释解释：`country_runtime.cpp:7170` 的兼容完成器每次都独立完成事务；reserve已在`:7028`扣款，collect属于`:7002`的credits_country并在`:7026`加回。`:7096`的conservation_ok只核对**本笔**Country余额差，所以两笔各自通过，随后军队再加X，组合净增加X。不是军队重复入账，也不是尚未扣款的预留需要collect确认。同类科研/采购在事务commit一次扣国库，接收方获得现金/货物，不能用反方向的collect作确认。

影响预测：v1–v4不触发该非零同步军饷；v5基线四日soldiers均为0，仅目标2→3→4→5，预测五链逐位不变。修复应把独立用例总额+12345变为0，并使国库-12345、军队+12345；不改变worker军饷。存档读写代码、schema、字段顺序均不改：同一逻辑状态的字节表示保持原格式；**修复后非零军饷的余额和少一次collect的事务历史当然不同**，这属于获授权的行为纠错，不承诺错误运行与正确运行的存档内容相同。历史余额不回溯修正。money_error需使用结算完成的审计或独立全钱包合计，不能用未重算的报告值代替守恒证据。

评估时未发现第二项经动态证实的守恒缺陷；D+1维护/建造注释与净额不符列为未解决口径，避免顺手修改。实施和红绿结果另记于current-state；本节先行结论副本保存在 `/tmp/keynes-arch-phase1/stage11/assessment-before-fix.md`。


### S11 实施边界与两阶段方案修订

修复准入依据是原生测试已明确可达、正确收支可用独立合计验证，且修改局限于一个同步分支；不是把尚未证明的正式玩家同步可达性当作事实。

同步军饷改为原位置消费的 Country intent：`runtime_economy_army_personnel.cpp:673` 附近复用 `fiscal_return_port()`，提交RESERVE并完成prepared/commit/applied，再按返回金额增加军队funds/epoch_income。Country原有金额裁剪、失败处理和所有者限制不变；无第二队列、无新开关。worker TREASURY_SPEND、D+1维护helper、公开绑定、保存布局均未改。两处直接写白名单**2→2**，仅继续承载旧D+1 helper；基线只更新解释，额度未放宽。

GM需单独说明：`world_runtime_host.gd:4402`先查登记的命令，`:5012`的经济分发没有30/34或军饷入口；玩家军事操作在`player_controller.gd:2392`经军事facade提交（`:2550`消费结果）。AI在`military_core_ai.cpp:383`之后生成Military命令。它们可能通过军队日推进间接产生34，但正式整图应走worker付款。同步分支的动态证明来自原生公开方法，不是声称已在正式玩家整图触发同步付款。

S9方案的“确认可能沿用reserve+collect”现已排除：**确认必须完成同一笔国库扣款及军队等额入账，COLLECT是反方向收款，不是确认**。未来预留仍由Country持有；记录day/sequence/request_id、国家/军队身份、请求额/批准额、generation、阶段、终态回执。Country begin只锁占用，双方prepared后在同一允许提交窗口决定扣款并入账；不能把同步兼容reserve（已完成扣款）误当作尚未提交的锁。

- 未决定提交前取消/过期：释放占用，军队不入账；已决定提交后仅重放至完成，不能既退钱又保留军队资金。
- 重复确认用同一request_id返回原终态；同日确认/到期按既有请求顺序处理。复用现有worker通道，不另建优先队列。
- 若维持当前“在途清空后保存”，无需新格式，但要证明保存不会穿过半笔付款；若预留跨日并可存档，需要版本化Country与军事关联记录并同步捕获。恢复先重建占用/去重/编号上界，再续跑；崩溃只能恢复最后一致存档。
- 历史错误余额缺少可追溯来源，不自动修正；读取兼容不等于能够识别已造出的每一笔钱。
- 持久两阶段原型**未开始**。当前修复只是同步行为纠错；worker非零军饷、跨phase崩溃/读档、D+1维护真实收款方仍是后续验证项。

S11-B逐项复查：79个显式成员仍全部带有搬迁障碍；另两个METHOD匹配是宏模板。只判空的audit/should_run/peer service/research demand/bullion函数已在S10四个叶文件中。`country_reads:2128`本身调用具体Country的read_view工厂，需要完整头；`retire_person:14700`、`register_person_effect:14729`实际调用Modifier，不能归为只判空。上面的79行清单继续有效（修正一个重载定位：508与524是两处不同定义）。逐函数最低新增167个债务键；本轮不放宽仅h→cpp的moved_from规则，不新增拆分文件，主文件15783→15783、头10240→10240。


## S12 钱流、搬迁额度与剩余边界

### D+1 调用点的钱流（现状，不是目标）

| 入口/步骤 | 国库 | cohort | 军队 | 在途占用 | 铸造/销毁 |
| --- | --- | --- | --- | --- | --- |
| helper的兼容reserve完成 | -X | 0 | 0 | 完成后0 | 未登记新铸造/销毁 |
| 紧接collect完成 | +X | 0 | 0 | 完成后0 | 两笔组合净0 |
| D+1材料通知/维护费消费后 | 合计0 | 0 | 0 | 0 | 合计0；返回成功额度X |
| S11同步军饷成功（不再调用helper） | -X | 0 | +X | 完成后0 | 0 |
| worker军饷成功（只读推导） | -X | 0 | +X | 既有peer完成后清理 | 0 |

实际D+1位置 `world_ext_military.cpp:1767`；来源 `military_core.cpp:2343,3322`。两个国家直接写白名单继续2项，仍在 `economy_runtime_military_view.cpp:316,319`，不能用维护费修正名义直接去掉collect。测试证明：helper足额返回12345、部分返回777、无效/空库返回0；均无净钱包变化。真实桥接的第5日维护记录50000，第6日确认后仍有国库500000。设计文档 `docs/plans/military-system-design.md:281` 要求维护费经财政支出并计入military_upkeep，但尚不能从这一句确定最终资金接受者。

待用户决定：①维护费是支付实际服务者/物资供应者（需要接收方及现有采购结算）；②确实是现金销毁（需要显式burn及同窗审计，不可仅删collect）；③只记录预算/估价（须使回执和“已付款”显示准确）。建筑估价应与真实经济建造付款区分，避免两次扣费。本轮没有改这些产品语义。

两阶段方案仍仅设计：军饷确认须一次国库扣款+军队等额入账；维护费与材料通知在确定收款方前不能直接复用军饷确认。持久预留、取消/到期、读档恢复仍须此前所述版本化记录与一致提交窗口；本轮无schema或队列修改。

### C++搬迁后的剩余19个成员

已到7989行目标后保留跨所有者协调、epoch冻结、经营计划、命令/人口提交、分支效果、家庭购买与哈希的相邻实现。继续拆不再被“cpp位移一律禁止”阻挡，但仍需完整类型include预算和对应源减少；不为数字目标复制跨域include。头文件未动。

| 当前行 | 成员 | 行数 |
| --- | --- | --- |
| 165 | `coordinate_country_fiscal_transaction` | 153 |
| 319 | `coordinate_country_cohort_cash` | 174 |
| 494 | `coordinate_country_market_goods` | 116 |
| 611 | `coordinate_country_treasury_spend` | 172 |
| 784 | `country_reads` | 3 |
| 788 | `cell_has_technology` | 19 |
| 811 | `capture_country_epoch` | 1246 |
| 2077 | `prepare_building_economic_plan_body` | 1591 |
| 3672 | `projected_owner_income_per_day` | 202 |
| 3875 | `owner_opportunity_quote_uncached` | 888 |
| 4786 | `apply_command` | 374 |
| 5161 | `commit_structural` | 144 |
| 5306 | `move_cohort_population` | 253 |
| 5566 | `clear_family_branch_effects` | 78 |
| 5645 | `reconcile_family_branch_effects` | 729 |
| 6376 | `advance_household_market_chunk` | 835 |
| 7216 | `retire_person` | 28 |
| 7245 | `register_person_effect` | 27 |
| 7274 | `state_hash_internal` | 713 |

检查器中的moved_from证明引用额度来自哪里；函数体是否机械相同由独立词元证据证明，检查器不是C++语义分析器。新增文件仍归经济所有，不通过改名前缀或隐藏include规避跨域统计。

## S13：Web失败门与命令/录制适配边界

- 会话和日准入仍归host。`_reject_web_daily_fallback`只在Web且逃生关闭时写host故障诊断/时钟锁，复用原错误展示；不写任何业务store，不替C++报告伪造提交。桌面同步分支、公开SHADOW/parity设置、原生worker→inline尝试均保留。
- `world_runtime_gm_commands.gd`无存储所有权；接收当次generator与resolve_country/resolve_start/resolve_cell等Callable。不能把序号、当前日、故障状态搬进去，不能提前求值这些resolver。host原公开方法继续转发，`Project/project-keynes/scripts/game/world_runtime_host.gd:4411`保留实际接纳顺序。
- `world_runtime_recorders.gd`只消费当前sample与recorder回执。host持有引用并负责时间采样；helper不绑定会话，不创建新帧回调。年报仍由AnnualReportSession/C++所有者计算，测试中的固定年报数据仅验证输出转发。
- C++依赖计数仍为457键/522头暴露/2400总引用，Country直接写仍2；无基线放宽、无维护费语义变更。D+1钱流产品决策与模块自有存档schema设计仍未实施，见[S13目标差距](s13-design-gap-audit.md)。


## S14：第一条有所有者提交版本的读边

| 边 | 所有者与读取位置 | 契约/限制 |
| --- | --- | --- |
| Climate→Economy环境列 | `RuntimeClimateAuthority::copy_committed_view`→`native_simulation_stage_economy.cpp:134` | 仅原气候提交后的执行线程边界；独立8个float列及4个分类列，标记generation/day/committed，读取断言不倒退；不读_next，不持有live store |
| Modifier worker→兼容对象 | host原四处消费→`world_runtime_modifier_writeback.gd:5` | generation由host持有；只同原位置consume，无ACK、无延迟调度、无持久资源引用 |

视图是原读取拷贝的所有者化，不是更改日表顺序，也不是全域freeze。CountryReadView仍是借用查询；本轮没有把其它读边冒充快照。视图游标是进程内诊断，不保存；reset/restore开始新所有者读周期。NDEBUG关闭断言时不执行版本记录，不改变业务决定。

依赖基线不放宽，仍457引用键/445债务键、header_exposed522/total2400、直接Country写2。新增`check_committed_views.py`专门保护stage的实际访问，要求反例验证，不能通过宏/间接调用绕开审查。暂不扩大为所有域的完整语义检查。

存档归属/兼容矩阵、在途intent和失败原子性设计见[s14-save-sections-review.md](s14-save-sections-review.md)。保存后继续存在改前已可复现的差异，不能因原有字节往返测试通过就认为后续轨迹相同；该项停止、未修。军事维护费产品口径及两处白名单不变。


## S15：气候续跑边界与第二条视图候选（仅评审）

Climate的逻辑所有权不能按“在store里/名为scratch”判断。`runtime_climate_kernel.cpp:886–889,1400–1402,2251–2293`实际跨天读取soil、日照与天气初始化状态；CLM2未包含这些值，dynamic_world镜像又落后。S15已通过分组输入替换及field_init单变量实验定位，正式生产未修。新保存契约必须以最后完整提交态为准，不能混合MapData可见日、worker提交日与时钟日。此项触发保存内容变更评审，不通过把恢复字段全置1或丢掉哈希字段规避。

第二条已提交视图本轮**仅分析，未实现、未新增护栏边**；优先处理已证实的保存缺失，避免同时改变读边和恢复来源。

| 优先级 / 候选 | 当前借用与版本来源 | 建议最小切片 | 风险与验证缺口 |
| --- | --- | --- | --- |
| 1 Events→Trigger | `native_simulation_host_trigger.cpp:65`借用`_events_authority.snapshot().events`；`:77–95`组装D+1请求；`native_simulation_stage_events.cpp:37`在既有位置调用；`runtime_events_authority.h:47,87`已有generation/committed_day但返回引用 | owner按原顺序复制events+day+generation；consumer检查同会话版本不退，保持2048上限、过滤、sequence和D+1日期；原getter绕行反例纳入现有护栏 | v3涵盖两域且非空回放有事件；但两域读档已分叉，需非空积压/队列拒绝/恢复水印专测；不能凭现有黄金宣称全部转发分支覆盖 |
| 2 Modifier→Ideology | `native_simulation_host_ideology.cpp:746`借用bucket做加成；`runtime_modifier_pod.h:123`snapshot已有版本 | 独立bucket投影，保留乘加/clamp/lround逐位顺序 | Ideology先于当日Modifier；视图允许上一提交日，不能要求“等于今天”而改行为；现有黄金未证明非零全部stat命中 |
| 3 Economy→Ideology意见 | `native_simulation_host_ideology.cpp:709–711`已原子读shared_ptr country/opinion；`economy_runtime.h:1536,1545`源读取接口 | 先核实主线程输入与worker已提交意见的一致身份，再定所有者投影 | 已有不可变指针不自动等于同日权威提交；跨主线程冻结/多个源更高风险，且本轮禁止改经济头 |

三个候选都未改生产调用，不声称第二条视图已落地。29份待决定文档未动，D+1维护费与Web默认worker不变。


## S16：恢复继续态的所有权

Climate owner新增CLM2 v9继续态（字段盘点见current-state S16）。主线程捕获游标随同一次Climate提交保存，恢复writeback只安装恢复专用游标；普通快照清空该字段，不能把旧游标反复写回。镜像不是继续态的第二个所有者。完整解码/长度/有限性/checksum通过后才安装，worker启动后才允许首次输入捕获。

Economy→Events缺失的发布记忆与Economy→Ideology上一日意见快照均归Economy。Trigger的30→108游标差异来自额外事件，不在Trigger补过滤。PKEC/ECP2继续态须同时保留这些已发布视图，不能只保存本日可见列或在恢复时再次发事件；设计与未实施原因见current-state S16。开发期不保证旧档，任何新格式明确升版、旧版拒绝。其他域本轮无字节变化，维护费与两处军事白名单未动。


## S17：经济发布状态的所有者与恢复边界

ECP2 schema 55、OSOA version 2 的块 8 属于 Economy；PKEC 59 未改。`economy_runtime_publication_codec.h:37`统一字段顺序，`economy_runtime_persistence.cpp:1736`先读入局部候选并检查形状、日期和版本，`:2098`在原恢复成功位置安装。不能在恢复时调用 `publish_country_development_facts()`：它会发新事件，改变原执行顺序。候选失败走既有备份恢复，备份也包含块 8。

| 保存字段 | 用途 / 缺失后果 | 恢复方式 |
| --- | --- | --- |
| `_development_fact_country_handles` u64、`_development_fact_last_day` i64、`_development_fact_qualified` u8 三列 | 已发布指标的国家、日期、达标状态；缺失会在第3日多发78条事件，下一日Trigger水印跟着变化 | 原样安装，不重新发送 |
| `_class_opinion_revision` 与已提交意见快照 | revision/class_hash/content_hash、epoch/commit/period、国家/阶级数量及handle/generation、人口/资金/雇佣/满意度/建筑/贸易列、period_days | 只存已提交缓冲；恢复到buffer 0；另一缓冲在下一次发布时被完整覆盖 |

本例块 8 为1,167字节，立即重存逐字节相同。未增加Country、Ideology、Events、Trigger段字段：它们的分叉来自Economy漏存的发布状态。ECP2旧53/54明确拒绝，错误 `ecp2_schema_version_incompatible_expected_55`，不以迁移开关降级加载。原OSOA块1–7逐字节不变。旧独立PKEC流没有新发布块，不能把该兼容接口宣称为完整世界继续态；正式PKSV保存使用ECP2。

整体经济hash还引用 `country_read_view.cpp:62` 的同步Country对象：连续运行税务版本0、研究日期-1，恢复后为1/2；worker Country摘要则一致。`country_runtime.cpp:5356,5400`把worker提交快照的研究日期/代数安装到兼容对象，`compute_state_hash():10051`又混入两字段。这是所有权/比较边界仍混合的证据，不应把兼容对象伪装成worker摘要，也不应为消除差异把正确恢复的日期改回旧值。本轮保留严格比较及其失败，未改既有hash或五条链。


## S18：权威、兼容输入与资源继续态

Country worker的canonical PKCN仍是唯一业务权威；经济旧查询对象是另一份会影响现有hash/查询的兼容输入，不能用权威快照覆盖它后声称恢复等价，也不能把它反向安装进worker。`request_runtime_save`分别捕获二者；CPD2 revision1尾部保存兼容PKCN（清除仅属旧主线程的命令/peer队列、断开Effect/Modifier后编码）。恢复经`country_runtime_compatibility.cpp`的局部候选解码，不触发Modifier恢复/peer调用；`native_simulation_country_restore.cpp`只是现有保存适配器入口。先验证canonical Country与ECP2身份并安装worker，再恢复兼容对象，最后启动执行线程。没有新 gameplay intent 或第二条读视图。

| 保存字段 | 原owner/读写 | 形式 / 本用例大小 | 恢复规则 |
| --- | --- | --- | --- |
| compatibility_pkcn | Country启动兼容对象；经济既有country_reads读取 | CPD2 revision1尾部，50,562B | 候选PKCN解码，不装入worker、不回写Modifier；整个兼容业务副本保留，而非只补两个日期/版本 |
| seeded | Economy资源integrator初始化状态 | u8 | 0要求后续列为空，1要求完整形状 |
| reserve / extra | `advance_worker_resource_reserves`及`fold_worker_resource_deltas` | 两列float32，按位LE；各31×1120 | 有限值；储量非负；不从整数stock反推 |
| extra_dirty | 静态资源是否仍有待消费变化 | u8×31 | 必须0/1，不能读档后一律设1 |
| last_day / was_live | `building_commit.cpp:294`计算恢复间隔 | i32×1120 / u8×1120 | 日不超current_day，0/1有效；保持每格日历 |
| cell_live / regen_factors / mirror queue | 每次计算覆写的暂存列、主线程发布队列 | 不新增字节 | 前两项确定性重建；镜像对全部格重发一次，恢复真实owner列而非落后脚本镜像 |

资源六字段位于ECP2 OWNED_STATE的OSOA3必需块9；块1–8不改。验证、安装、回滚捕获均由`EconomyAuthorityTransfer`的保存能力封装，不扩展`economy_runtime.h`、不赋予业务消费者直接写权限。现有依赖457键、header522、total2400和两处军事直接写白名单均未放宽。

研究/发展发布状态仍在块8；不用重跑publisher生成事件。军事职业编号是可由catalog确定性重建的缓存，只在恢复完成时填充，不新增存档字段。正式完整PKSV路径已验证；独立PKEC导出和其他授权组合仍需独立继续态覆盖。

## S19 新边界

Events 所有者在 `runtime_events_authority.{h,cpp}` 生成 `RuntimeEventsCommittedView`，只复制已提交 `_current` 的事件、generation 和 day；Trigger 消费前用 `observe_trigger_view` 检查版本不倒退。不得在 `native_simulation_host_trigger.cpp` 直接调用 Events 的 snapshot/store。`check_committed_views.py` 与护栏单元测试覆盖该规则。

S19 宿主适配只持有本次调用的 Callable/RefCounted 依赖，不保存模拟状态：`world_runtime_preparation.gd` 处理表现准备回调和停止等待，host 保留恢复、信号、唯一 `_process` 与取消语义。


## S20 已提交视图扩展

S20 新增两条只读边界：Modifier→Ideology 使用 `RuntimeModifierPodAuthority::copy_committed_view()`，只复制已提交 bucket，并由 `observe_committed_view()` 检查 generation/day；Effect→Modifier 使用对应的 `RuntimeEffectPodAuthority` 视图，只复制目标 instance。两条视图均不保存、不暴露 plan 指针，消费顺序和原有计算循环不变。`tools/ci/check_committed_views.py` 现在检查四条边界，并用真实绕行文本反例验证直接 snapshot 会失败。

年度自动存档仍由 `GameSaveCoordinator._on_year_changed` 触发，先等 `AnnualReportSession.waiting_for_year` 清除再写 `year_N` 槽；测试专用短年历不会改变生产天数。

## S20 视图与年度边界

Modifier→Ideology 使用 `RuntimeModifierCommittedView` 的拥有者副本，Effect→Modifier 使用按实例筛选的 `RuntimeEffectCommittedView`；两者均以 generation/day 规则拒绝回退或在途数据。直接 snapshot、别名和成员指针由 `tools/ci/check_committed_views.py` 拒绝。

年度自动存档仍由 `GameSaveCoordinator` 负责，年报等待和 coordinator 保存槽在短年历用例中已验证。365 日跨年目前显示 `base_moisture` 的保存/写回边界问题，不能把 MapData 动态列视为已完成的模块继续态；未新增字节，等待单独字段盘点与授权。


## S21 年度保存边界

Geography 的保存输出以 native climate slot 为输入快照，写入已有 `dynamic_world.cells.cell_base_moisture` 字段；恢复后刷新 DCWorld 的同一列。该读取只影响保存输出和恢复，不在连续日推进中同步三份 live mirror。年度 ECONOMY 仍有槽位重建分叉，暂不新增字段或升 ECP2 版本；需先证明 slot/signature 排序契约。

安全边界规则：保存请求必须经过 `GameSaveCoordinator._wait_for_safe_boundary()`，在途日暂停并等待 committed/idle；超时返回拒绝。

## S22 已发布视图与恢复所有者

`native_simulation_host_committed_views.cpp`新增Economy意见→Ideology、Ideology发布→年度报告两条拥有副本的读边；generation/day取原所有者发布值，不能按消费日伪造。消费者只调用工厂并用`observe`断言，原缺失/SHADOW选择语义不变。Country `_country_snapshot`会含计划预览，仍不能据其名字当成已提交视图。

恢复ECP2时未来命令不能把已提交公式状态留在不完整兼容镜像：只在执行线程尚未启动的指定ACTIVE自动接管路径绑定完整OwnedState；普通运行时切换门禁不变。就业冷却属于Economy块10，事件序号/转发水印属于PKSR宿主传输继续态，天气发布返回码属于environment适配状态，不能放进不相干模块。格式及根因见[S22记录](s22-annual-continuation.md)。


## S23 边界更新

存档方面，Country 只通过 `pkcn` contract 写/恢复 Country 段，Economy 只通过 `ecp2` contract 写/恢复 Economy 段，coordinator 按 `restore_after` 安装；旧版本集合按开发期策略只接受当前版本。跨域读取新增 Country AI→Economy、年度报告→Country、Family metrics→Economy 三条 committed view，均带 generation/day 检查。

仍未迁移的读边：Country 快照中含计划预览，不能直接称为 committed；Trigger→Effect 主要是 intent，不是稳定快照查询；Effect 身份查询包含已接受但尚未安装的队列；Economy 中的 Country 读取已通过 `CountryReadView`，剩余写入白名单为军事 reserve/collect 两处。

### S23 读边清单与保留理由

方向按“消费者←所有者”表示。下面覆盖已审查的生产交接族；所有 include/类型位置仍以依赖基线为机器清单。**它不是全仓库每个间接调用的穷举证明，G2 的全读边语义盘点仍为部分**。

| 读边 | 当前入口/证据（gdext/src） | 状态与未迁移原因 |
| --- | --- | --- |
| Economy←Climate | native_simulation_stage_economy.cpp / copy_committed_view | S14已提交视图 |
| Trigger←Events | native_simulation_host_trigger.cpp / forward_events_to_trigger | S19已提交视图 |
| Ideology←Modifier | native_simulation_host_ideology.cpp / execute_ideology_worker_stage | S20已提交视图 |
| Modifier←Effect | native_simulation_host_modifier.cpp / copy_committed_view | S20已提交视图 |
| Ideology←Economy意见 | native_simulation_host_committed_views.cpp / copy_economy_opinion_view | S22已提交视图 |
| 年报←Ideology | annual_development_host.cpp / commit_annual_worker_day | S22已提交视图 |
| Country AI←Economy | native_simulation_host_country_stage.cpp / copy_country_ai_economy_view | S23新增，保留原digest日与revision |
| 年报←Country | annual_development_host.cpp / copy_annual_country_view | S23新增，仅Country plan关闭后读取 |
| Family指标←Economy意见 | economy_runtime_family_buff.cpp / refresh_class_opinion_metrics | S23新增，读取已发布buffer的独立副本；测试override仍在原位置应用 |
| Economy←Country27种查询 | country_read_view.cpp；本文件S4查询表 | 借用只读函数表；即时财政余额、周期冻结、哈希/保存校验时点不同，尚非统一提交版本 |
| Ideology←Country | native_simulation_host_ideology.cpp / _country_snapshot | 同一指针可发布Country计划预览，不能强标committed |
| Country←Effect身份/完成 | native_simulation_host_effect.cpp / effect_pod_instance_exists、effect_pod_instance_fire_acked | 身份查询包含接受未安装的upsert；完成查询读取交易ACK，不能替换为只含instance的既有投影 |
| Trigger→Effect、Ideology→Effect | native_simulation_host_trigger.cpp；native_simulation_host_ideology.cpp | 主要为intent/ACK交接，不以“多一条读视图”计数；目录/身份查询仍需逐调用分类 |
| Economy/Family←Effect、Modifier | economy_effect_forward.h；economy_runtime_family_buff.cpp | 同步/worker路由、计划和发布时点并存，尚未全量迁移 |
| Military←Country/Economy | world_ext_military.cpp；economy_runtime_military_view.cpp | 主线程digest与即时财政helper并存；维护费口径未变 |
| Climate←Modifier/Economy | runtime_climate_kernel.cpp 与环境捕获入口 | 已冻结输入不等于所有底层查询均有独立视图；未扩展 |
| 保存/诊断读取 | native_simulation_golden.cpp、native_simulation_host_persistence.cpp | 已有安全边界；不作为业务读边新增数 |

### G4 剩余成员（S23未搬）

保留主文件7989行；以下19成员未改词元。多数需要Country税种/事务枚举的完整定义；切为新cpp要重复country_runtime.h include，而原文件仍需它，当前逐键位移规则要求来源计数同步减少，不能用净总量抵消新增键。capture/hash另有Modifier/Effect类型，家庭处理还有Trigger；本轮没有为了行数放宽此规则。头拆分只允许原头到同目录指定内部头，151个传递包含者未变；不是降低重编范围。

| 成员 | 原/现主文件行 | 行数 | 外域类型 |
| --- | ---: | ---: | --- |
| `coordinate_country_fiscal_transaction` | 165 | 153 | CountryWorkerAssetRoute, NativeCountryRuntime |
| `coordinate_country_cohort_cash` | 319 | 174 | CountryWorkerAssetRoute, NativeCountryRuntime |
| `coordinate_country_market_goods` | 494 | 116 | CountryWorkerAssetRoute, NativeCountryRuntime |
| `coordinate_country_treasury_spend` | 611 | 172 | CountryWorkerAssetRoute, NativeCountryRuntime |
| `country_reads` | 784 | 3 | CountryReadView |
| `cell_has_technology` | 788 | 19 | NativeCountryRuntime |
| `capture_country_epoch` | 811 | 1246 | CountryReadView, ModifierRuntime, NativeCountryRuntime, Snapshot |
| `prepare_building_economic_plan_body` | 2077 | 1591 | NativeCountryRuntime |
| `projected_owner_income_per_day` | 3672 | 202 | NativeCountryRuntime |
| `owner_opportunity_quote_uncached` | 3875 | 888 | NativeCountryRuntime |
| `apply_command` | 4786 | 374 | NativeCountryRuntime |
| `commit_structural` | 5161 | 144 | NativeCountryRuntime |
| `move_cohort_population` | 5306 | 253 | FamilyMovePlanRow, NativeCountryRuntime |
| `clear_family_branch_effects` | 5566 | 78 | FamilyEffectBinding, FamilyModifierBinding, FamilyTriggerBinding |
| `reconcile_family_branch_effects` | 5645 | 729 | EffectRuntime, FamilyEffectBinding, FamilyEffectMetadataPod, FamilyModifierBinding, FamilyTraitRoll |
| `advance_household_market_chunk` | 6376 | 835 | NativeCountryRuntime |
| `retire_person` | 7216 | 28 |  |
| `register_person_effect` | 7245 | 27 |  |
| `state_hash_internal` | 7274 | 713 | CountryReadView, FamilyBuildingOwnership, FamilyExpeditionCargoLine, FamilyExpeditionKitBuilding, FamilyExpeditionPayload, FamilyMembershipEdge, FamilyTraitCommand, FamilyTraitRoll, ModifierRuntime, NativeCountryRuntime, Snapshot |

存档契约中的version是provider manifest版本，不与内层magic版本混用：Country provider为11，内层PKCN由原owner编码器检查；Economy契约接收当前ECP2 schema（57）。本轮未改任一内层字节或金样。既有显式PK_SAVE_MIGRATE路径保留，默认拒绝不支持版本；本轮没有新增兼容降级。

依赖次数2399只表示Family消费点改用auto后少了一个显式外域类型词，不能据此声称真实耦合少了一条；本轮新价值是独立副本和提交版本检查。


S23军事保存待办：MilitaryCore的pending_enlist、桥接pending_intents、Economy的army_personnel分别有保存位置，不能凭单个snapshot字段变化就把缺陷归给PKMI。跨日命令、ACK读取游标和经济行恢复须在同一保存边界核对；本轮非零军队读档红测试保留，生产军费语义不改。明细与两个首差见current-state。


## S24 跨域读边总表与周期/命令继续态

`tools/ci/cross_domain_inventory.json` 列出当前依赖基线中的31个域对，每项标为“已迁移 / 明确不迁移 / 待逐函数核查”，并附原因；`check_cross_domain_inventory.py` 要求表与基线域对集合完全相同，表外新增域对直接失败。它与 `check_committed_views.py` 的9条实际视图边互补：前者保证全量登记，后者检查已迁移边的直接、别名和成员指针绕行。由于当前检查按文本和依赖键工作，间接函数调用仍需 R2 做语义核查。

S24 将已接纳但未执行的 Economy POD 命令作为保存继续态写入 PKSR v4；恢复前完整校验，再在所有者绑定后安装。ECP2 schema 58 的 owned-state block 11 保存六个生产周期测量量；周期天数和起始日由既有字段保存。测试入口必须调用固定周期注入，生产仍使用真实耗时自适应。

军事未闭合项：PKMI 中已有 pending_enlist/桥接记录，但连续运行保留停用 lot 的索引链，恢复只重建有效 lot，导致 barracks present 4→1。需要下一轮按索引生命周期证明后再决定是否增加段字段。
### S26 / R2 冻结输入与军事边界

`RuntimeFrozenInputVersion` 是跨域只读版本契约；消费方只能接受 committed、非 in-flight 且 day/generation 不倒退的版本。Climate、Country、Economy 已登记读取集合，缺登记反例由 `test_architecture_guards.py` 覆盖。模块顺序检查只报告依赖违反，不自动重排；上一日视图债务在模块契约 JSON 中显式登记。

Climate 当前先完成环境输入捕获和提交，再进入统一 day plan。这是现行边界；下一步需要证明同一日输入的捕获游标、环境 generation 和 writeback 顺序完全等价后才能合并。

原 J1/K1 过滤方案已撤回。PKMI v1 丢失仍挂链的 inactive 槽位 payload，恢复重建链与连续运行不等价；本次在 PKMI v2 保存原始链与槽位继续态，不保存派生 present。
### K1 / K2 证据更新

**撤回 J1/K1 结论**：此前把 inactive 行称为“幽灵兵力”并保留全局过滤是错误的。变更型调用方必须看到这些行才能保持原有槽位复用语义；过滤使连续 day20 总兵力1→4、驻军0→3、军饷141819→158220，违反连续运行不变。过滤已删除，不能再作为修复方案。

Climate 的冻结登记覆盖环境 generation/day；环境捕获、FIFO 消费和 writeback 仍在统一 day plan 之前，不能只移动函数名来宣称已合并。

### R2 原始继续态的所有者

Military拥有PKMI2的lot payload、链和槽位顺序，inactive行不能由通用遍历过滤。Economy拥有ECP2 59 block12的实物收入累计列。Host拥有PKSR5 TCQ1的Trigger传输请求/ACK/发布游标与Host请求分配游标，不能用外部编号最大值推导其继续态。保存不推进业务，不补发伪成功，不把派生present作为原始状态。字段和对照见 [军事继续态记录](s26-military-continuation.md)。


## R3 / S29：请求与提交边界切片

详见 [R3实现、请求清单与保留债务](s29-resolve-apply.md)。本轮三个已有请求队列共享契约，军事最后两处Country直接写改走现有所有者端口；十二域写声明与三个实际Apply入口增加护栏。未改阶段顺序或存档格式。Ideology宽泛错误软完成与Effect忽略错误已收紧；启动/ACK兼容仍保留，不宣称全域soft-complete消除。四个文件型诊断只接受绝对路径，测试前后检查新增非源码文件。R3最终批次（修复兼容债登记后）已完成：生产构建和财政 probe 构建均 exit 0；静态护栏全过（size 920 文件 0 违规；C++ 496 引用键/484 债务键、header_exposed=518、total=2210、Country direct writes=0；Resolve/Apply 3 队列/3 Apply 入口 0 违规；架构单测 24 项）。主链 runs=3、外部 runs=2 均 first_difference=None。默认回归 exit 0，耗时 807.05 秒；full 矩阵 7 场景 exit 0，410.73 秒；annual exit 0，83.58 秒；military-annual exit 0，91.41 秒。默认回归含 61 个日志项及保存续跑/矩阵/年度检查。


## R4 / S30：宿主生命周期与 C++ 存档段契约

本轮把关闭、取消和释放流程提取到 `scripts/game/world_runtime_lifecycle.gd`。`WorldRuntimeHost` 仍保留原公开入口、信号、状态所有权和 Web 回退；组件只通过 host 引用执行原顺序。host 7010→6970 行。冻结检查 18 项、WorldSession 29 项、准备测试 15 项通过；完整 host ≤3000 行目标尚未达到，生成主流程、日调度和存档装配仍保留在 host，继续列入 R4。

新增 `tools/ci/cpp_save_section_contracts.json` 与 `check_save_section_contracts.py`。12 个域登记 owner、tag、当前版本、写入/恢复证据和恢复依赖：Climate/CLM2 v9、Country/PKCN v14、Economy/ECP2 v59、Military/PKMI v2、Trigger/PKTR v6、Effect/PKEF v14、Modifier/PKMD v3、Ideology/PKID v14、Family/Technology 的所属段、Host/PKSR v5、Annual/PKAR。契约检查拒绝缺版本拒绝证据、恢复顺序倒置和未登记域；Family/Technology/Annual 目前是所属段委托，未另造第二套存档格式。

本轮没有改变存档字节、公式、调度顺序或五条黄金链。Economy cpp 7989 行和额外读边迁移未开始，作为后续 R4 切片。


### R4 最终验证（2026-11-05）

构建 exit 0。静态护栏：921 文件、0 违规；依赖 496/484、`header_exposed=518`、`total=2210`；开关95、视图9、存档契约2个脚本 owner+12个C++域、模块12/9、跨域31对、Resolve/Apply 3/3、架构护栏25项。主链3/3和外部2/2均 `first_difference=None`。默认回归 exit 0，61个测试日志及保存/回放/金样检查通过。`check_replay_matrix.py --full` 为9个场景36进程，`--annual`和`--military-annual`各4进程，全部 `valid=True; first_difference=None`。

宿主生命周期抽取后的 host 为6970行；`economy_runtime.cpp`仍7989行。完整 host≤3000和经济文件收口未完成，列入后续R4切片。工作区相对起点新增文件全部为源码、测试或文档，未新增非源码游离文件。

## S31 拆分后的实现边界

`world_runtime_host.gd` 只保留会话公开入口、信号和状态转发；生成/恢复、日推进、GM/记录、视觉查询分别由 `world_runtime_generation_adapter.gd`、`world_runtime_daily_adapter*.gd`、`world_runtime_gm_adapter*.gd`、`world_runtime_visual_adapter.gd` 承接，生命周期仍由既有 `world_runtime_lifecycle.gd` 承接。

Economy 的六个大成员由 `economy_runtime_country_epoch_capture.cpp`、`economy_runtime_building_plan_body.cpp`、`economy_runtime_lineage_branch_effects.cpp`、`economy_runtime_state_hash.cpp` 承接；这些文件通过私有 `.inc` 聚合所需的 Country/Modifier/Trigger 完整类型，未形成公共 ABI。`check_cpp_deps.py` 统计该 `.inc` 的真实依赖，并要求每个迁移项登记 `moved_from`；`header_exposed=518`、`total=2209`。
