# 当前运行状态

核查日期：2026-11-04。最新状态：S17已由用户验收；S18的实现、八日完整续跑证据与限制见文末。前文各阶段数字是历史截面，不能替代最新结果。以下“已验证事实”指已读到的源码与明确列出的运行证据。范围是正式玩家会话请求 ACTIVE、十二域掩码 `0xFFF`；请求、实际授权和 POD_ACTIVE 不是同一件事。第一阶段记录的初始状态为空；第二阶段接手时工作区已有大量变更，起始清单保存在 `/tmp/keynes-arch-phase1/stage2-status-before.txt`，本次保留这些变更。

## 已验证事实：十二域

本次仅拆执行组织，未迁移数据所有权。域内函数现在位于 `native_simulation_stage_*.cpp`。

| 域 | 真正写入者与边界 | 生产对拍情况 | 证据（文件:行） |
| --- | --- | --- | --- |
| INPUT_CAPTURE | Host 冻结输入清单与哈希；不是旧业务 runtime | 无独立双算 | `gdext/src/native_simulation_stage_input_capture.cpp:7`；`gdext/src/native_simulation_day_capture_day_input.cpp:6` |
| CLIMATE | RuntimeClimateAuthority store；plan/commit 先于模块循环，表内只登记结果 | ACTIVE 关闭完整输出哈希及 parity 标记 | `gdext/src/native_simulation_stage_climate.cpp:194`；`gdext/src/native_simulation_stage_climate.cpp:90` |
| COUNTRY | RuntimeCountryPodAuthority，旧国家对象保留初始化/查询/适配 | 记录 parity 的钩子仍调用；缺参考帧时 uncompared，非另跑旧日 | `gdext/src/native_simulation_stage_country.cpp:8`；`gdext/src/native_simulation_host_country_boundary.cpp:280` |
| TRIGGER_INPUT | Trigger POD；ACK 等待等指定状态可以软完成 | ACTIVE 抑制旧 run_daily，故不生成同日旧参考 | `gdext/src/native_simulation_stage_trigger_input.cpp:7`；`gdext/src/world_ext_trigger.cpp:221` |
| IDEOLOGY | Ideology POD；缺 opinion 等指定状态可软完成 | Ideology parity 默认 false，可显式开启 | `gdext/src/native_simulation_stage_ideology.cpp:7`；`gdext/src/native_simulation_host.h:1950` |
| EFFECT | Effect POD 及意图/ACK；重试还要处理补交 | 独立影子推进留在 SHADOW 分支 | `gdext/src/native_simulation_stage_effect.cpp:8`；`gdext/src/native_simulation_day_shadow.cpp:424` |
| MODIFIER | Modifier POD；部分授权时仍可内嵌 Effect | 整图不走 SHADOW 诊断管线 | `gdext/src/native_simulation_stage_modifier.cpp:7`；`gdext/src/native_simulation_host.cpp:235` |
| GAMEPLAY_EFFECT | Host 解码、摘要、去重，排入 Events/Ideology 命令；不是独立玩法库 | 无旧日双算 | `gdext/src/native_simulation_stage_gameplay_effect.cpp:7` |
| ECONOMY | StageOps 调度调用 NativeEconomyRuntime 的真实计算；POD_ACTIVE 时绑定 OwnedState | 默认 ACTIVE_ONLY，不跑影子 StageOps；显式 ACTIVE_WITH_PARITY 才跑 | `gdext/src/native_simulation_stage_economy.cpp:70`；`gdext/src/economy_graph_stage_dispatch.cpp:68`；`gdext/src/native_simulation_host_economy.cpp:287` |
| EVENTS | RuntimeEventsAuthority 写事件日志与消费者游标；GameplayEventBus 仍是主线程适配入口 | 沿用 events_probe_enabled 开关；名称含 probe 不代表仅诊断 | `gdext/src/native_simulation_stage_events.cpp:7`；`gdext/src/native_simulation_day_run_day_events.cpp:39` |
| VISUAL | Host 产生刷新意图；publish_day 排序去重，实际显示归 Godot | 无旧日双算 | `gdext/src/native_simulation_stage_visual.cpp:7`；`gdext/src/native_simulation_host_commands.cpp:813` |
| COMMIT | 表内记时钟完成位；之后检查请求域全部完成，由外层发布 | 无旧日双算 | `gdext/src/native_simulation_stage_commit.cpp:7`；`gdext/src/native_simulation_host.cpp:361` |

### 配置与非直观边界

- 默认请求 `0xFFF`：`Project/project-keynes/scripts/game/world_runtime_host.gd:127`。配置 StageOps 与 ACTIVE：`Project/project-keynes/scripts/game/world_runtime_host.gd:1756`。Host 的 auto POD 默认 false，正式 PlayerGame 明确设为 true：`Project/project-keynes/scripts/game/player_game.gd:121`；完整镜像、空闲边界满足后才切换（`Project/project-keynes/scripts/game/world_runtime_host.gd:3747`）。因此经济是“原计算实现 + 可切换的数据承载”，不是两份独立公式简单二选一。
- Country 的 parity 钩子在 ACTIVE 提交后仍会被调用（`gdext/src/native_simulation_host_country_boundary.cpp:280`），旧 `run_country_slice` 则在 worker 授权时被抑制（`gdext/src/world_ext_country.cpp:1828`）。不能写成“生产中完全没有 parity 代码”。缺少同日参考会报告 uncompared，不凭钩子调用次数声称发生了双算。
- TRIGGER_INPUT / IDEOLOGY 对若干未就绪原因记软完成；COMMIT 的完成位不足以证明每个域都推进了业务状态（上表函数内 `trigger_soft` / `ideology_soft`）。
- 模块表前保留气候实际提交，表后保留 Events 补调用、覆盖检查和日故障点：`gdext/src/native_simulation_host.cpp:199`。这不是新设计所要求的全域原子提交。

## 已验证事实：线程与十二域以外的推进

| 系统 | 调用链与线程 | 证据 |
| --- | --- | --- |
| 十二域 | 普通 worker 通过 std::thread 调用 worker_main；inline 复用 execute_day_plan，运行在调用线程 | `gdext/src/native_simulation_host_startup.cpp:1083`；`gdext/src/native_simulation_host_commands.cpp:575` |
| 军事 | Host `_process` 消费提交后逐帧追赶日期，facade.run_daily 在主线程同步运行；首次观察与每帧上限沿用旧规则 | `Project/project-keynes/scripts/game/world_runtime_host.gd:2150`；`Project/project-keynes/scripts/game/world_runtime_host.gd:3561` |
| 自然资源恢复 | 主线程追赶已提交日期，转 native resource pass 写 slot 后回传 MapData；仍有脚本 fallback。经济自身消耗资源是另一个入口 | `Project/project-keynes/scripts/game/world_runtime_host.gd:3528`；`Project/project-keynes/scripts/geography/map_generator.gd:11168`；`Project/project-keynes/scripts/geography/map_generator.gd:11077` |
| 家庭/人物 | 经济 FAMILY_COMMIT / PERSON_COMMIT 调原 runtime 的 drain，随经济执行线程运行；不是独立日域 | `gdext/src/economy_graph_stage_dispatch.cpp:270`；`gdext/src/economy_graph_stage_dispatch.cpp:292` |
| 视野 | Host 根据变化，在主线程调用 run_vision_research_pass 并刷新 LUT、边界和建筑情报 | `Project/project-keynes/scripts/game/world_runtime_host.gd:6882`；`Project/project-keynes/scripts/game/world_runtime_host.gd:6559` |

## 已验证事实：哈希和验证范围

- `runtime_day_waterfall.h` 记录耗时与完成掩码，不是状态哈希链（`gdext/src/runtime_day_waterfall.h:47`）。输入哈希也不能替代输出状态。
- `simulation_state_hash` 来自 `_state_hash`；每天只将日期混入前值（`gdext/src/native_simulation_host_commands.cpp:711`），不是业务状态总摘要。
- 气候 ACTIVE `compute_hashes=false`（上表气候前置函数），不能把报告里的零值当真实状态摘要。
- 经济整体哈希读取原 runtime 的状态与关联输入/国家等字段（`gdext/src/economy_runtime.cpp:25412`）。第一阶段第三次运行第 1、3、5 天变化；第二阶段已定位原间歇差异到 Modifier 日期，并发现独立的资源初始化越界读取，证据见下文。本轮授权修复与验证见文末。
- 第一阶段黄金用例只采用开局地块的明确账目字段；本轮 v2 已扩到整体经济（见文末）。改前两次与改后八天账目链一致；默认回归改前 31 项、改后 32 项通过。命令、平台和失败记录见 [迁移状态](migration.md)。

## 推断与范围

本轮已测量黄金种子的资源/开局发现变化（见文末），其他种子、长期研究与经济结果仍未测量。不能从八天开局账目不变推断修复没有数值影响。

## 未知与未做

未证明十二域完整状态逐位确定、所有可选授权组合、跨平台浮点一致或保存中途恢复的哈希链；未运行玩家图形长跑。经济 NativeEconomyRuntime 与 POD 的全面解耦、军事/资源接入日表、视图与 intent 强制隔离都未开始。

## 已验证事实：规模与基线口径

第一阶段扫描 819 个源码文件（E2/E3 新增后为 824）；超过 800 行的 GDScript 为 69 份，超过 2000 行的 C++ 实现为 41 份、头文件为 4 份。与背景中的 65 个脚本不同，计数以 `check_size_ratchet.py` 的明确范围为准。`economy_runtime.cpp` 中 `NativeCountryRuntime` 词出现 107 次；这只是静态引用计数，不代表调用频率。完整依赖债务由 `cpp_deps_baseline.json` 记录。

## 第二阶段 E1：上一轮定位与停止记录（本轮结果见下文）

### 已验证事实：原间歇差异在 Modifier 日期

`economy-detail` 两次取样第 1 天的完整经济哈希分别为 `3990282708482571163` 与 `8315549730929947551`。临时逐项探针证明：到 Modifier 字节循环之前，全部混入值和中间哈希相同；149 字节的 Modifier ECONOMY 序列只有偏移 20 和 28 不同，分别是日期 `2/1`、快照版本 `1/2`。版本低位被现有哈希循环排除，实际导致这两个哈希不同的是日期。

- 用例 `_run_day(day)` 设置日历并提交 `day+1`，然后等账目 `sample_day==day`：`Project/project-keynes/tests/game/starter_settlement_soak_test.gd:152`。
- 主线程 Modifier `run_daily` 写 `_current_day=day_index`：`gdext/src/modifier_runtime.cpp:1418`；工作线程快照回写又将其设为 `snapshot.committed_day`：`gdext/src/modifier_runtime.cpp:559`。Host 非阻塞地消费回写，可能本帧尚未消费：`Project/project-keynes/scripts/game/world_runtime_host.gd:2851`。
- 序列化布局是 magic/schema/domain/catalog 后接日期，日期占 `[20,28)`，版本占 `[28,36)`：`gdext/src/modifier_runtime.cpp:2553`。经济哈希读取这个兼容对象的序列：`gdext/src/economy_runtime.cpp:26102`。现有排除范围却是 `[24,32)`（`:26111`），与注释声称的版本字段范围不符；本次未修改哈希算法或存档。
- `get_economy_report` 有短暂读取锁，`get_economy_state_hash` 没有相同的锁：`gdext/src/world_ext_economy.cpp:1545`、`:2373`。前一个调用完成不能作为后一个调用的原子读取保证。

证据：`/tmp/keynes-arch-phase1/stage2/economy-detail/economy-{1,2}.log`、`modifier-detail/economy-{1,2}.log`。临时 C++ 探针源码留在 scratch 的 `*.diagnostic.cpp`；正式 C++ 文件已与任务开始时副本逐字核对相同。下一步应固定用例的同日回写读取边界，而非删掉日期来掩盖时点差异；本次因下面的独立数值问题停止，尚未实施该调整。

### 已验证事实：更早的资源初始化越界读取

六轮原始重复的第 1 天账目完全相同，但国家初始哈希出现 `8296185428492860197`、`2271313942955443353` 等不同值。原始经济输入跟踪也显示资源储量列不同，气候输入列相同。逐字段核对定位到国家 `_country_research_signal_cells`：多出的键为 `(signal=39, cell=166)`，对应 `resource.flint`；该信号的发现计数由 14 变为 15。

- 开局可见信号来自地图 CSR：`Project/project-keynes/scripts/game/start_location_policy.gd:480`；写入国家开局包：`Project/project-keynes/scripts/geography/map_generator.gd:3510`；国家写观察集合与计数：`gdext/src/country_runtime.cpp:1242`。经济混入国家哈希：`gdext/src/economy_runtime.cpp:25458`，这是这组运行最先不同的经济哈希输入。
- 地图资源信号以储量 `>0.0001f` 判定：`gdext/src/world_ext_generate.cpp:163`；资源初始化结果被用于该信号合并：`gdext/src/world_ext_boot_facade.cpp:337`。
- 排除表行宽从 1 起，只按配置中明确排除的编号扩展：`Project/project-keynes/scripts/geography/map_generator.gd:10287`。本用例 31 种资源没有配置排除项，两张表均长 31、行宽 1。
- C++ 先取第 r 行指针，再直接按实际地形/植被编号索引，没有检查编号小于行宽：`gdext/src/world_ext_resource_deposits.cpp:447`、`:477`、`:481`。三轮探针均记录 `resource=29 cell=166 terrain=10 vegetation=27 terrain_width=1 vegetation_width=1 terrain_length=31 vegetation_length=31`，并记录 `skipped=vegetation`。实际索引是 `29+10=39` 和 `29+27=56`，均越过 31 字节数组；排除判定读取了不属于表的数据。

证据：`original-six/summary.json` 与 `trace-*.log`；`country-detail/country-{1,3}.log` 中观察键及计数差异；`deposit-detail/run-{1,2,3}.log` 中实际索引与跳过分支。目录均在 `/tmp/keynes-arch-phase1/stage2/`。最终移除 C++ 探针后再跑十轮，`final-repeat/run-5.log` 的 `GOLDEN_BOOTSTRAP` 直接记录第 166 格燧石储量 `83292136`，其余九轮为 `0`；相应全列 SHA-256 为 `df26dfe65180bfdc545a5d4ea1c989fe14f39b6986d1bd1fcaaad6203081c072` / `d4f04fb2bebbdfffe8017a7ec52aa6e08b8b6e8b98c6bae04ad475df356d273a`。这已是业务初始化数据差异，不是仅有哈希或计时抖动。修复会改变当前被误排除地块的资源结果与发现计数，因此按用户停止条件未应用修复、未更新黄金基线；不存在修复后哈希，不虚报改后相同。

### 仍未知与后续门槛

尚未证明排除表修复后的全部数值变化范围，也未证明以上两处是全部不确定来源。最终十轮均匹配原账目基线，但 E1 完整经济哈希检查失败：第二轮第 6 天为 `2262008862672660491`，首轮为 `1360362806380858045`（`final-repeat/summary.json`）。E2 每域摘要及五轮一致验证、E3 推进者登记与检查均未开始。诊断中的 Country 公共哈希来自保留的同步对象（`gdext/src/world_ext_country.cpp:1948`），不能当作工作线程已提交 Country 全域摘要。


## E1 授权修复：资源边界与取样边界

已验证源码：`gdext/src/world_ext_resource_deposits.cpp:477`、`:482` 在解引用前检查编号小于对应行宽。输入为无符号 byte，编号不可能为负；超出该行按“未排除”处理。总数组长度检查仍在 `:346`，没有改变表构造或 `map_generator.gd:10287` 的宽度语义。全 `gdext/src` 搜索同一对表，仅有此处消费；栖息地使用 switch/位掩码（`:98`），核心列长度在 `:307` 检查，稀疏权重的范围在 `:239` 检查，未发现另外的同类直接索引。

针对性测试 `tests/runtime/resource_exclusion_bounds_test.gd:1` 用两行宽度 1 的表 `[0,1]`，检查编号 0、1、255：行内 1 标记仍排除、越过当前行不借用下一行，terrain/vegetation 两种输入均通过（2 checks, 0 failures）。

本轮旧二进制与仅含边界修复的新二进制各运行同一黄金用例，全部资源数组保存在 `authorized/resource-before.log` 和 `resource-after-old-baseline.log`。对比脚本与完整差异在 `authorized/compare_resources.py`、`resource-comparison.json`，均位于 `/tmp/keynes-arch-phase1/stage2/`。以下是这两个样本的差异，不是未定义读取在所有进程里的固定旧结果。

| 资源 | 储量变化格数 |
| --- | ---: |
| bauxite | 63 |
| flint | 24 |
| freshwater_fish | 4 |
| gold_ore | 66 |
| iron_ore | 112 |
| lead_ore | 57 |
| limestone | 92 |
| manganese_ore | 61 |
| marine_fish | 599 |
| phosphate_rock | 64 |
| rare_earth | 47 |
| saltpeter | 30 |
| silver_ore | 105 |
| sulfur | 56 |
| tin_ore | 55 |
| wild_game | 5 |
| zinc_ore | 55 |

共 17 种资源、1495 个“资源×格”值变化。例：flint 格 166 从 0 到 83,292,136；bauxite 格 246 从 0 到 8,757,114,880；gold_ore 开局格 247 从 492,151,808 到 488,868,512。入选候选格改变后，原有排序/预算分配会重新分配其它格储量；不是额外修改了公式。国家开局发现计数变化的 signal id 为 21：2→4、29：50→58、30：3→4、36：4→5、39（flint）：14→15，其余计数相同。

出乎预期的是，这次修复后旧八天账目逐字段仍完全相同，旧基线检查通过，末日仍为 `2242b25110adb22d74a7ce175f8b6e0dce2ef2442741d3dc2a318efa8c7e28c2`。变化先出现在生成期资源/发现计数，而非开局账目。修复前后此次唯一 C++ 差异就是上述两处边界判断；构建日志也只编译该源文件。旧基线不是账目值错误，而是覆盖不足，不能再作为完整经济确定性的凭据。

黄金脚本新增 `_wait_golden_read_boundary`：同日账目后继续等待 `worker_day_inflight==0`、Host 消费的 Modifier generation 等于已发布 generation、Modifier current_day 等于采样日；期间不提交下一日。使用既有受锁保护的回写方法，不改游戏推进、不靠延时、不删日期。完整经济哈希仍包括其原有同步国家/Modifier 依赖，不能称为独立经济域全状态摘要。

第一次连续十轮全部八天整体经济哈希相同（`authorized/e1-candidate/summary.json`）。据这十轮生成 v2：保留账目链，新增逐日 whole_economy_hash/whole_economy_chain；完整链末日为 `30ea61f1e05f12b02d01ebe3aa1bf6060655e39663251100b4be8ae358db73d3`。旧内容原样保存在 `golden_day_hash_baseline.v1.json`，不覆盖历史证据。新基线后的十轮与回归结果见迁移记录。

待用户决定：`economy_runtime.cpp:26111` 跳过 `[24,32)`，而 Modifier 版本字段实际为 `[28,36)`。本轮没有修复、掩盖或重新解释该范围；现有哈希算法继续保留这一缺陷，后续修复会改变哈希值。

另核对两组共 20 次的全部 31 种资源列摘要，均完全相同；v1 留存文件与本轮开始时副本逐字节相同。

## E2：工作线程已提交状态的只读摘要

诊断入口是现有 `get_runtime_perf_snapshot(3)` 的 `golden_domains` 字段（`gdext/src/world_ext_runtime_graph.cpp:1877`），还必须设置 `PK_GOLDEN_DOMAINS=1`（`world_ext_golden.cpp:12`）。默认 detail=0 不执行新增摘要、锁或环境变量查询。未增加 Godot 绑定、保存字段或 ABI 常量。

`native_simulation_golden.cpp:429` 尝试取得整日边界锁，要求 worker 没有在途日任务、Country 没有开放计划，再借用实际 authority 的已提交 store。worker 同一把锁覆盖执行到发布（`gdext/src/native_simulation_host_worker.cpp:513`），inline 使用 `gdext/src/native_simulation_host_commands.cpp:531`。诊断不推进计划、不消费环、不发布回写。Trigger 另在其已有互斥锁内复制快照（`native_simulation_golden.cpp:423`）。测试仍先满足 E1 同日回写边界。

下表的源码相对 `gdext/src/`。摘要是明确范围的逻辑数据投影，不宣称包含完整恢复所需的全部状态。状态日期单独输出；不能把 bootstrap 的 -1 改成当天来假装已完成。

| 域 | 原入口判断 → 本轮实现 | 取值范围 / 入基线情况 | 证据 |
| --- | --- | --- | --- |
| INPUT_CAPTURE | 暂不可作输出状态摘要 | 输入清单不是独立已提交业务 store；未入 | `native_simulation_day_capture_day_input.cpp:6` |
| CLIMATE | 要新增 → 已有只读投影 | store 的气候/植被/历史/RNG 列，加解码后的物理状态；入 v3 | `native_simulation_golden.cpp:209`、`:446` |
| COUNTRY | 原报告为 0、同步 getter 不合格 → 新增实际 authority 借用 | `country_core_hash_business_state` 保留业务字段；E2 曾因真实跨日差异排除，S3-A 修复后追加 v4 Country 链 | `native_simulation_golden.cpp:448`；`country_core_apply.cpp:1383` |
| TRIGGER_INPUT | 要新增规范化摘要 → 受锁快照 | 触发状态、来源游标、分支、待处理事件/效果；入 v3 | `native_simulation_golden.cpp:371`、`:423` |
| IDEOLOGY | 能取已有业务摘要，需提交边界 | 真实 authority snapshot 的 points/baseline/history/draw/bits/offer/ideas 投影；入 v3，第 1 日 state_day=-1 | `native_simulation_golden.cpp:456`；`runtime_ideology_pod.cpp:2665` |
| EFFECT | 要新增规范化摘要 → 显式逻辑字段 | metrics、实例内容、命令、事务；不混入实例编号/重试计数/报告代数；入 v3，非完整身份恢复证明 | `native_simulation_golden.cpp:364`、`:461` |
| MODIFIER | 要新增规范化摘要 → 显式逻辑字段 | 已提交 entries/buckets；不含实例分配器和 ACK 传输记录；入 v3 | `native_simulation_golden.cpp:358`、`:465` |
| GAMEPLAY_EFFECT | 暂不可取完整摘要 | Host 解码/去重/意图，不是独立业务 store；未定义完整续跑摘要，未入 | `native_simulation_stage_gameplay_effect.cpp:7` |
| ECONOMY | 要新增 worker 侧投影 → OwnedState 读取 | 人口和市场列入 v3；不覆盖建筑、家庭/人物、贸易、资源和价格上限稀疏表。v2 旧整经济链另行保留，不能替代这些缺口 | `native_simulation_golden.cpp:388`、`:469` |
| EVENTS | 要新增规范化摘要 → 显式逻辑字段 | 日志、消费者 ACK、去重证据；入 v3 | `native_simulation_golden.cpp:381`、`:473` |
| VISUAL | 暂不可取完整摘要 | 输出显示意图，真实主线程消费不在原子日边界内；未入 | `native_simulation_stage_visual.cpp:7` |
| COMMIT | 暂不可作业务状态摘要 | 日期/完成位不是业务状态；未入 | `native_simulation_stage_commit.cpp:7` |

Climate 没有开启 ACTIVE 的 `compute_hashes`；只在诊断读取时遍历已提交 store。物理保存 blob 含输入/输出代数、诊断计数和完整性哈希，故解码到局部临时对象后逐字段混入逻辑状态（`native_simulation_golden.cpp:254`；原编码 `runtime_climate_physics.cpp:2124`）。不改 live store 或保存字节。人口 `epoch_in_kind_income` 按原声明是派生诊断且不参与保存/权威哈希（`runtime_economy_population_store.h:29`），未混入此投影。所有摘要按固定列/元素顺序计算，不读取指针、耗时、Godot 实例 ID 或结构体填充。

### E2 历史差异：Country 研究信号登记日期（S3-A 已收尾）

证据根目录 `/tmp/keynes-arch-phase1/stage2/e2-e3/`。首次 `domain-candidate` 第 2 轮第 5 日 Country 摘要由 `13496816054293946391` 变为 `1890452361256404135`，其余七域及 v1/v2 全部相同。带字段探针的 `country-probe` 五轮暂未复现；下一组 `country-probe-more` 第 5 轮再次复现。保留失败样本，没有拼接为连续通过。

`country-fields-more.log`、`compare_country.py` 和 `country-differences.json` 记录实际已提交字段：第 5 日 `country_research_signals[1]` 为 `1302528` 或 `144115188077158400`；观察集合多出 `(signal=121, cell=247)`，证据条数 37→38。后者的 `first_day/last_day` 为 5/5，前者在第 6 日登记为 6/6；之后第 6～8 日只有该证据日期仍不同（忽略不参与业务摘要的 state_version）。这不是摘要结构体填充，也不是读取同步旧对象。

已核实的机制：主线程逐帧服务 Trigger→Country 交接（`world_runtime_host.gd:3198`，`world_ext_trigger.cpp:478`），worker 将迟到命令的 effective_day 改为当前计划日（`gdext/src/native_simulation_host_country_stage.cpp:136`），Country 用该日期写发现证据（`country_core_apply.cpp:753`、`:763`）。两份首次分歧报告中命令队列深度为 1/0、Country 提交代数为 1/2。**当时推断**：同一信号命令在第 5 日收件之前/之后到达，造成 5/6 日之差；没有进一步插桩测量线程唤醒先后，也没有修改这条生产交接路径。信号的具体内容名称未用运行期目录确认，不按静态行号猜测。

E2 时 Country 摘要由 C++ 返回，测试用 `GOLDEN_DOMAIN_EXCLUDED` 单独打印；v3 的 excluded_domains 明列 COUNTRY，整个域不进入链，而非删掉日期。可选 `PK_GOLDEN_COUNTRY_TRACE=<scratch文件>` 记录字段以复现问题，只在显式逐域诊断调用时工作。S3-A 的命令取样和修复证据见下节；v3 历史文件仍保持这一排除声明。

### 黄金链契约与验收范围

v1/v2 文件原样保留。v3 只追加七域的 `{state_day, scope, hash}` 与 domain_chain；每次运行（包括候选模式）都先核对去掉追加字段后的完整结果等于 v2。每日日链按十二域中的固定相对顺序，对 `[id,state_day,scope,hash]` 数组序列化后链接前日摘要。重复读取同一边界还检查摘要相同、旧完整经济哈希未变。

七域候选连续 5/5 一致后才建立 v3（`seven-candidate/summary.json`）。最终重复、构建、回归及生产关闭开关的旧基线结果见 [迁移记录](migration.md)。这里只证明该固定世界八日、该平台和所列投影；不是完整十二域确定性，也没有覆盖非空玩家命令、跨平台或中途存档恢复。

## E3：表外推进与回写登记

`tools/ci/runtime_advancers.json` 是人工审查的清单；`check_runtime_advancers.py` 生成并校验 Godot 无关的 `gdext/src/runtime_external_advancers.h`，由 `runtime_module_descriptor.h` 引入。C++ 可读取 `RUNTIME_EXTERNAL_ADVANCERS` 的 id、线程、读写声明、触发方式、源码入口及 Host 字段。它没有调度功能，也不改变 RuntimeDomainId 或十二域顺序。

七项为 military、natural_resource_recovery、family、person、vision、visual_delivery、climate_writeback。后两项是已提交数据的主线程消费/显示，不是新增模拟域。family/person 标记 EXECUTOR，指普通 worker 或既有 inline 调用线程，不误标为始终主线程。实际入口与线程证据沿用本文上方表格；气候回写补充证据 `world_runtime_host.gd:3648`。

检查扫描 Host 声明中的 `_runtime_*cursor*`、catchup、以 `_day`/`_day_index` 结尾的 last/pending/target/commit 字段，以及 `_queue_runtime_*_commit` / `_drain_runtime_*_commits` 函数。目前 7 个字段、4 个追赶函数全部登记；未登记基线为空，只允许旧未登记项减少，不能新增。`*_days` 累计计数不当作日期游标，例如 inline_pending_days 是重试计数（`world_runtime_host.gd:583`）。

`_runtime_commit_family_cursors` 其实是显示脏数据类别的分段消费位置（`:3485`），不是家庭模拟游标。静态检查只约束这套命名/入口惯例；不能发现所有绕开惯例的推进函数，新增功能仍需人工确认数据所有者。它也不验证 reads/writes 文本是否等于真实访问权限。

反例日志 `e2-e3/negative-advancer.log`：在 scratch 副本加入 `_runtime_unregistered_cursor` 后 CLI 报 1 violation 并 exit=1，副本随后删除，真实 Host 文件未改。四项护栏测试还覆盖漏登记追赶函数、日期字段、头文件漂移、旧债务减少和注释/字符串排除。构建及最终回归证据见 migration.md。

军事/资源没有改由日表调度：它们仍需主线程回写边界，而且本轮七域摘要尚不覆盖军事、资源恢复全状态，Country 在 E2 时还存在交接日期差异（S3-A 的限定修复见下节）。仍没有足够证据支持移动执行位置；该后续迁移仍为未开始。


## S3-A：Country 命令交接日期

**已验证事实**：这不是黄金读取过早，也不是墙钟直接生成日期。Trigger 在 `trigger_runtime.cpp:950` 以事件日 + 1 生成 effective_day。主线程把它交给 Effect，再提交 Country（`world_runtime_host.gd:3214`、`:3237`；`effect_runtime.cpp:6252`、`:6320`；`country_runtime.cpp:2325`）。旧 `handoff_trigger_effects_unlocked` 在提交 Country 前完成主线程服务；worker 又在等待这个服务之前取走命令环。这两个先后窗口让同一命令有机会错过当前日。

本轮临时只读命令探针的 `stage3/admission/run-{1,2}.log` 实测同一条 `id=1 producer=0 op=14 cell=247 aux=121 requested=3 effective=3` 到第 6 日才被接纳。结合 E2 保留的第 5/6 日实际 Country 字段差异，根因是跨线程交付/收件没有完整的先后约束；不是仅修测试读取就能消失的差异。迟到命令仍按原规则改为计划日（`gdext/src/native_simulation_host_country_stage.cpp:136`），`country_core_apply.cpp:753`、`:763` 将该日期持久记录为 first_day/last_day。

**S3-A 是生产路径的命令接纳时点行为修正，不是仅修测试稳定性。** 命令原定第 3 日，改前可能到第 5/6 日生效；限定修复后，本用例稳定在第 5 日生效，并未把它追溯改写成第 3 日。修复在现有边界内完成：`world_ext_trigger.cpp:493` 在 Country worker 权威下先入队，再完成主线程服务；`native_simulation_host.cpp` 的 `country_delivery_boundary` 分支在等待服务、取得日边界锁后取命令，之后沿用原排序和日提交过程。OFF/SHADOW 保留原先取命令位置，非 Country worker 的 handoff 不提前提交。未修改日期字段、公式、存档格式、权威开关或域提交顺序。主线程脚本原有 dispatch 保留，已有幂等状态使其不会重复提交。

`stage3/admission-fixed` 连续 10 次与旧 v3 完全相同，Country 每次在第 5 日接纳，八日 Country 摘要也相同。临时命令探针随后移除；`v4-candidate` 连续 10 次一致后建立 v4，`v4-reviewed` 再连续 10 次通过。实际指令与最终构建/回归见 migration.md。v4 只在 `domain_hashes` 追加 Country，并单独链接 `country_chain`；原七域 `domain_chain` 不重算。v1、v2、v3 文件保留，测试包括候选模式也独立核对旧 v2/v3 投影。

**范围与未知**：这些证据覆盖固定八日世界的实际发现命令，不证明任意玩家输入、连续高速追赶、多生产者命令或跨平台全部确定。信号 121 的内容名称仍未用运行期目录确认；本轮不猜名称。军事/自然恢复/视野的执行位置未移动；经济全状态之外的覆盖缺口和 Modifier 哈希 `[24,32)` / 注释 `[28,36)` 不符问题仍保留。

## S3-B 历史交付：第一批国库读取

新增不依赖 Godot 的 `country_read_view.h`，只公开 total_cash、cash_for_slot、total_good 三个标量查询；Country 在 `country_read_view.cpp` 构造借用视图。`economy_runtime.cpp` 的 9 处总现金、5 处分国现金、2 处物资库存读取改经 read_view()。原空值判断、参数、取值时点和全部写入/命令保持原样。

这些读取原本已按所有者规则选择 worker 已提交审计快照（`country_runtime.cpp:7775`、`:7800`、`:7815`），新接口直接调用原函数；不复制公式、不缓存余额、不把它伪装成整周期冻结副本。total_good 原有的部分活动位/列宽仍来自同步对象，此次原样保留；这也是窄接口不等于完成数据所有权迁移的限制。S3 交付时 `capture_country_epoch` 的税率/科技/领土冻结快照和哈希路径尚未迁移；S4 已接续，见下节。全部引用分类见 module-boundaries.md。

## S4：头文件隔离与全部经济 Country 只读调用

**已验证事实**：`economy_runtime.h:38` 改用无 Godot 的 `country_read_view.h`；AI 类型只保留不完整声明，AI 共享数据定义和构造/析构放入 `economy_runtime_country_ai.cpp:21`。该定义原来只有同一实现文件使用。扫描全部 `economy_runtime*.h`，已无 `country_ai_core.h` 或 `country_runtime.h` include。

`CountryReadView`（`country_read_view.h:12`）目前有 27 种查询。`country_read_view.cpp:8` 由 Country 构造静态函数表，每项直接调用原 const getter。经济主实现及叶实现共 156 处查询统一通过 `country_reads()`；唯一具体对象读取连接是 `economy_runtime.cpp:4927` 的工厂。全清单见 module-boundaries.md。27 是查询种类数，156 是调用点数，不是运行次数。

税/领土/科技快照的数据声明移入 `CountryReadView::Snapshot`（`country_read_view.h:56`），原 `NativeCountryRuntime::CellTaxOverride/CellTaxPolicy/EconomySnapshot` 名称保留别名（`country_runtime.h:148`、`:149`、`:156`），字段顺序、默认值、相等比较及复制实现不变；税列宽和继承标志通过三个 static_assert 核对（`country_read_view.cpp:5`）。`capture_country_epoch` 仍在原处复制，余额查询仍即时发生；保存与哈希读取仍走原 getter。视图两个借用指针，不保存状态、不保存新字段，单独 C++17 编译无需 Godot。

**限制**：接口化没有把原同步 getter 变成新的 worker 摘要，也没有改变原 authority 选择。旧 state_hash 与 v4 Country 摘要含义仍不同。47 处写入调用的完整表达式和文件内顺序与 S4 起始副本相同；Country→Economy 的逐键计数也相同（`stage4/source-audit.json`）。没有改公式、ABI 常量、模块提交顺序、序列化编码或保存版本。保存字节的依据是编码代码未改及回归保存/恢复检查；未声称另做了所有状态的字节级跨版本穷举。

**护栏事实**：全部引用（包含允许的只读接口）header_exposed 527→522、total 2404→2400、键数 435→433，域对 31 不变。普通依赖 421 键，明确只读接口 12 键；实现文件的六条增长键都记录了对应头文件的减少证据。检查与显式基线更新均禁止预算增长和无来源的新依赖。八项护栏测试覆盖纯新增拒绝、仅移位通过、来源不足/重复使用拒绝、头文件增长拒绝、只读接口计入总量、绕过接口拒绝。

**运行证据**：`/tmp/keynes-arch-phase1/stage4/` 下 `build-a.log`、`build-b-scalars.log`、`build-b-snapshots.log` 均构建成功；`a-golden`、`b-scalars-golden`、`b-snapshots-golden` 各 3/3，`final-golden` 连续 10/10 无差异。`final-legacy` 关闭逐域摘要后 2/2 与 v2 一致。四份黄金基线文件均未修改；末日链仍为账目 2242b251…、v2 30ea61f1…、v3 95aedaac…、v4 6786a230…。默认回归前后结果与完整链见 migration.md。

**S4-C 设计/未知**：既有资产请求已经携带日期、序号并由 Country 应用；新增另一队列是否能保留同步返回、同日守恒与中途恢复，本轮没有实现或验证。优先建议 FISCAL_RETURN，但原型未开始；47 处写入、拟议 intent 类型、次序与风险已逐项盘点。Modifier 哈希排除范围问题仍未修，军事/资源仍在原位置。旧过程文档已清理；29 份待决定文档未动。


## S5：财政返还请求与退役核查

**已实现**：同步 FISCAL_RETURN 改由 `CountryFiscalReturnIntent` / `CountryFiscalReturnPort` 交接（`gdext/src/country_fiscal_return_intent.h:10`、`.cpp:16`）。经济仍先走既有 worker 队列；只有不适用 worker 通道时，才在原位置提交同步请求（`economy_runtime.cpp:3358`、`:3367`）。所有者检查 day/sequence/request_id，再调用原 prepare；Country commit → 经济 escrow 扣减 → applied ACK 的顺序不变（`:3423`、`:3432`、`:3443`、`:3451`）。新增端口没有存档字段、绑定或第二条队列。worker 请求仍按 `gdext/src/native_simulation_host_asset_worker.cpp:320` 的 day/operation_sequence/continuation_index/request_id 排序；原收件、Apply、发布均未修改。

**实测**：改前二进制专用用例连续两次，返还 amount=9900、transaction/request/sequence=4、effective_country_day=3、Country cash 480000→489900；改后完整回执与旧值一致。固定用例先关闭研究采购预留款，再将第 1 日绝对收入补贴 100 降到第 2 日 1，上一批申请额留下 9900 余款。每次日提交人口/资金/物资误差都为零。来源：`tests/runtime/fiscal_return_intent_test.gd`、同名 JSON 基线；日志统一在 `/tmp/keynes-arch-phase1/stage5/`。

保存前完整流 SHA256：Country `7938d1e030726e9be8fc806fce8b8aeeef0b4b900e32410dfa66601b27ca8ec3`；Economy `cf4be1f5b7c46f389a1e9755d95d48162a3d62192dc28485ca0556591e885f00`。恢复后 Economy 流为 `e2aaa16ebdaddc9bca1f48d6b8a99e8c6bb2d9f42f68bb94c8effe5a4006a3f4`，恢复前后逻辑哈希均为 `2911339119633021043`。这些值改前改后均一致。**恢复再保存的 PKEC 字节在改前就不等于输入流**，本轮不声称原有保存具备字节幂等性，也不改这个行为；具体哪些重建字段导致差异未进一步定位。Country 的恢复再保存字节完全相同。

额外旧用例 `economy_fiscal_reservation_continuation_test.gd` 改前改后均失败同样 4 项（57检查，`fiscal-before-1.log`、`fiscal-existing-after.log`），未修改它。其非零财政申请被研究预留款挡住：`economy_runtime_fiscal.cpp:697`—`:713` 在采购开启时扣除 daily budget×epoch days（不以剩余研究需求为条件），日志 `fiscal-before-1.log`；诊断 `fiscal-diag.log` 记录 request=10000/cash=500000 但最终 reserve=0，明确关闭研究预算后 `fiscal-diag-2.log` 得到非零 reserve/return。临时 C++ 日志已移除。该旧测试不在默认 33 项中，不能把它的失败归因于本次原型，也不把默认全绿说成全部财政测试全绿。

**验证边界**：黄金连续 10 次匹配四条既有链（`golden-final/summary.json`）；本机 macOS arm64 调试构建通过（`build-final-a.log`）。专用保存/回执用例通过（`fiscal-after.log`）。默认改前 33/33（`before.log`），改后 34/34（`after.log`，新增返还用例），全部无退出泄漏。护栏829文件/433引用键/421债务键/header_exposed=522/total=2400、7推进者、9项护栏测试，均零违规。未覆盖新的端口过期顺序键拒绝、全部故障注入与 Web/release 运行；worker 通道未改，不以本同步用例声称完整覆盖 worker 的所有返还重试。

### S5-B 非生产路径删除资格表（只读核查；未删除）

正式入口 `player_game.gd:125` 指定 0xFFF；Host 默认 `ACTIVE_ONLY`、parity forcing=false、events probe=false（`world_runtime_host.gd:86`—`:95`）。下表“默认不走”不等于无法打开。所有路径均保留；没有验证出满足本轮全部删除条件的较大实现。以下为实际入口与代表性依赖，不声称枚举了所有外部调用者。

| 候选 | 正式路径/开关与证据 | 测试或工具依赖 | 删除资格及兼容影响 |
| --- | --- | --- | --- |
| 整日 SHADOW，705 行 | ACTIVE 不调用；`gdext/src/native_simulation_host.cpp:234` 仍按公开 mode 调用。Host `world_runtime_host.gd:1735,1788` 根据 authority 配置选 SHADOW/ACTIVE | `tests/runtime/native_daily_shadow_test.gd`、`runtime_country_parity_test.gd` | 不合格：公开 `start_runtime_worker` 可选 SHADOW；不是内部死分支；不能删除后保留空壳语义 |
| OFF/旧同步 run_daily | 整图获得 authority 后相应 getter 抑制同步推进；`world_ext_ideology.cpp:413,442`、`world_ext_trigger.cpp:223`。Host 禁用 worker 或 Web authority 关闭仍用脚本日 tick（`world_runtime_host.gd:1677,1700`） | `tests/economy/economy_rolling_runtime_test.gd`、各域同步测试 | 不合格：仍有生产配置入口；绑定 `run_country_slice/run_economy_slice`（`world_ext_bind_methods.cpp:404,847`）及加载初始化路径必须保留 |
| Climate parity/forcing | ACTIVE 不作普通 parity（`native_simulation_stage_climate.cpp:175`）；Host 可显式打开 forcing（`world_runtime_host.gd:1726`） | `runtime_climate_save_roundtrip_test.gd`、Country/Ideology parity 用例 | 不合格：公开 setter（`world_ext_bind_methods.cpp:132`），parity 槽也属既有接口；未改保存 |
| Country parity | 提交后仍调用比较记录（`gdext/src/native_simulation_host_country_boundary.cpp:140；gdext/src/native_simulation_host_country_stage.cpp:845`）；缺同日 reference 时为 uncompared（`:4337`）。同步成功可发布 reference（`world_ext_country.cpp:1877`） | `runtime_country_parity_test.gd`、`runtime_country_host_protocol_test.gd` | 不合格：ACTIVE 可达记录；公开 self-test（绑定 `:176`），不是纯未调用算法 |
| Ideology parity | 参考捕获默认 false，可公开打开（host.h:202；`world_ext_ideology.cpp:427,474`）；提交仍记录 worker hash（host.cpp:10513） | `ideology_worker_authority_parity_test.gd`、`ideology_x12_worker_test.gd` 等 | 不合格：公开 setter（绑定 `:134`）；不能因默认 false 删除 |
| Modifier SHADOW 镜像 | `world_ext_modifier.cpp:66,142` 根据 authority 入队；Host SHADOW 收件（host.cpp:8403,13611） | `runtime_modifier_pod_test.gd` | 不合格：公开 mode、提交与日推进入口仍可达；不碰 Modifier 存档/哈希排除范围 |
| Trigger shadow reference | ACTIVE worker 抑制旧推进，非 worker 的 `run_trigger_daily` 发布 reference（`world_ext_trigger.cpp:223`） | `runtime_trigger_pod_test.gd`、`trigger_runtime_test.gd` | 不合格：公开同步入口可达；报告字段名字不是不可达证明 |
| Effect parity/self-test | `runtime_effect_adapter_parity_self_test` 公开绑定（`world_ext_bind_methods.cpp:342`） | `ideology_effect_worker_forward_test.gd` | 不合格：绑定方法保留；未更改保存、scheduler 或 slot |
| Economy shadow StageOps/LEGACY_ONLY | ACTIVE_ONLY 默认不作影子比对；`host.h:354`；`world_ext_simulation_host.cpp:606,711,721` 接受 LEGACY_ONLY/ACTIVE_WITH_PARITY；`economy_graph_live_ops.cpp:82` 的只读分支仍被这些配置使用 | 默认回归 `runtime_economy_parity_test.gd`、`runtime_economy_stage_ops_soak_parity_test.gd` | 不合格：有公开配置与共享生产 StageOps；184 行文件不能整体删 |
| Events probe | 虽默认 false，0xFFF 请求在 `host.cpp:721`—`:726` 强制 true；`native_simulation_day_run_day_events.cpp:10` 检查此位 | `runtime_events_pod_test.gd`、黄金 Events 域 | **生产可达且必需**；名称有 probe 不代表仅诊断 |
| 成本、数学、invariant 等 probe | `economy_cost_probe.h:35` 读 `PK_ECONOMY_COST_CSV`；生产 dispatch `economy_graph_stage_dispatch.cpp:83` 使用；数学探针公开绑定（`:1075,1078`）；invariant 由 host.cpp:1925 调用 | `production_climate_math_test.gd`、默认 D7/authority 检查 | 不合格：生产可开启或公开绑定；未确认不可达，不能删除 |

删除代码块 **0 行**，被删测试 **无**。“疑似无调用、待用户决定”：`run_economy_fixed_math_probe` 在本仓库代码全文检索仅找到声明、绑定和实现（`world_ext.h:1283`、`world_ext_bind_methods.cpp:1075`、`world_ext_economy.cpp:2359`），未找到调用者。它仍是公开绑定，本轮保留；仓库外脚本是否使用未知。**未知**：本轮没有证明所有非生产实现均不可退役，只是上述候选均不满足批准的标准。后续若要关闭公共配置面，需要新的明确授权与对应兼容方案。


S5 最终验证命令（仓库根目录，构建命令在 gdext）：

```sh
scons platform=macos target=template_debug arch=arm64 dev_build=no -j8
python3 tools/ci/check_golden_determinism.py --godot /opt/homebrew/bin/godot --runs 10 --log-dir /tmp/keynes-arch-phase1/stage5/golden-final
python3 tools/ci/run_regression_checks.py --godot /opt/homebrew/bin/godot --log-dir /tmp/keynes-arch-phase1/stage5/before
python3 tools/ci/run_regression_checks.py --godot /opt/homebrew/bin/godot --log-dir /tmp/keynes-arch-phase1/stage5/after
```

四条末日链逐位不变：

- 账目：`2242b25110adb22d74a7ce175f8b6e0dce2ef2442741d3dc2a318efa8c7e28c2`
- 整体经济：`30ea61f1e05f12b02d01ebe3aa1bf6060655e39663251100b4be8ae358db73d3`
- 七域：`95aedaac2fd631d72657f0d27fbb04009d3ab489b577f3e7c59788ee25ab537a`
- Country：`6786a230e8f9b5859c0f9baa13eefd65ec89976e3d1fd119a5131df35a3e8fef`

存档原格式/原序列化函数未改的源码核对、完整回执与流哈希、两次默认结果和文件清单汇总于 `stage5/verification-summary.json`。未执行图形、Web、release或性能验收；本次不作这些通过声明。


## S6：资产写入与表外黄金（当前实现）

### 已验证的实现事实

- 采购组的五处直接写入迁到 `CountryProcurementIntent/Port`（`country_procurement_intent.h:5`、`.cpp:10`；`economy_runtime_procurement.cpp:541,764,780,788,795`）。请求带 day/sequence/request_id，`next_order_key()` 复用 Country 原编号（`country_fiscal_return_intent.cpp:10`），Country 在原位置核对后调用原 begin。准备、应用、ACK 复用 S5 的同一个资产账本，不建第二条队列。
- 财政组七处写入迁到同一端口的 `CountryFiscalCashIntent`（`country_fiscal_return_intent.cpp:29`；`economy_runtime.cpp:3371,3377,3406,3414,3420,3426,3444`）。RESERVE/COLLECT 的参数、Country commit → Economy escrow → applied ACK 次序未改。worker 仍在同步分支之前走原 `block_or_enqueue_country_worker_asset`（`:3359`）；没有改 worker 请求/排序/提交实现。
- 直接写入 **46→41→34**。未迁移：主经济23、殖民补给9、军事适配2。依赖433键/421债务键、header_exposed=522、total=2400不变。主经济26701→26691行，行数基线只收紧这一项；未放宽其它项。
- 两个专用用例均先在本轮改前二进制上捕获两次相同输出，再与改后比较完整回执及存档。采购实际买入10000、现金48850、请求/序号2；财政实际操作2/3/4均出现（预留10000/10000/100、返还9900/100、征收100）。每个经济日检查人口/钱/物资误差0。Country恢复后字节相同；PKEC重编码本来不字节幂等，因此分别比对原始保存流和恢复后保存流，不能把二者混作一个断言。
- 没有删除实现，没有改模式、保存函数、ABI、绑定名、scheduler/slot id或军事/资源推进位置。所选12处均可保留原即时完成边界，**本轮不可迁移项：无**。其余34处未开始，不代表已证明它们不可迁移。

### 表外摘要入口及覆盖边界

摘要只在独立测试脚本中计算，复用既有读取入口；没有增加生产侧扫描、诊断字段或轮询。生产默认路径无新增摘要开销。新用例是独立世界，未改 v1–v4 用例与四份基线。

| 类别 | 已提交读取入口与依据（gdext/src，另标脚本） | v5范围与限制 |
| --- | --- | --- |
| 军事 | `world_ext_military.cpp:2470` 读主线程 MilitaryCore 的国家快照；host `world_runtime_host.gd:3561` 追赶 | 国家军额、政策、训练/战争摘要；按键稳定排序，不用含修订号的整个 `state_hash`。每日人数目标2/3/4/5实际生效；士兵始终0，未验证征募/移动/战斗/军队完整store |
| 自然资源恢复 | `world_runtime_host.gd:3528` 主线程恢复完成后，既有 `snapshot_f32` 读每种资源的 reserve、extra_change 原始float32列；测试`golden_external_advancers_test.gd:166` | 全地图储量和待处理变化；不含耗时。四天相对开局增长的资源×格数量57/119/195/265；不是只看日期 |
| 家庭 | `world_ext_economy.cpp:1960` → `committed_read`（`:97`）→ `economy_runtime_queries_market_building.cpp:1966` | 遍历全部地块并翻页，按声明列读取家庭句柄、人口、现金、资产/声望等。worker拥有时只在读边界取当前状态，或取同日已提交视图；不接受旧日缓存。未含inactive槽和全部内部行为缓存 |
| 人物 | `world_ext_economy.cpp:2304`，同一 `committed_read`；查询实现`:2697` | 遍历已发现家庭的人物，身份、归属、现金、收入/消费/税、岗位等列；非完整人物store。四日家庭/人物摘要均变化，各有1条有效实体 |
| 视野 | host `world_runtime_host.gd:6882` 发布的物理visible、MapData explored/fog数组 | 只读已发布输出，不为取摘要再运行pass；四日固定边界相同，尚未覆盖扩张/远程观察导致的变化、内部eligibility和待提交研究观察 |

**更正旧覆盖表述**：家庭/人物并非完全未进入旧链。`economy_runtime.cpp:25505`附近的家庭列与`:25666`的人物列已参与整体经济 `state_hash_internal`，因而v2已有间接覆盖；v5新增各自可定位的独立投影，仍不声称是全部内部状态。

v5等待同日Modifier回写和worker空闲，再继续host消费，直到军事/资源两个推进游标都等于目标日；没有改变主线程执行位置。固定种子20260727、40×28、无外国、4天，每日提交一个真实军事目标命令。基线候选连续10/10一致（`stage6/external-candidate/summary.json`），末日链 `0f85a96f0e1a994ede564409e7e1bc5fdac282cbca2da42672da266f9b663c22`；本轮未观察到不稳定类别，无排除类别。视野恒定和军事无士兵是明确覆盖缺口，不能由这10次推论战斗或领土变化也确定。

### 证据与尚未验证

本轮证据统一在 `/tmp/keynes-arch-phase1/stage6/`。改前默认34/34通过；两组串行debug构建成功，各3/3四链一致，专用用例改后与改前输出一致。最终旧四链10/10不变；v5候选、入基线复验、增加边界/守恒/列宽断言后的最终脚本各10/10；默认改后37/37（最终新增断言随后由单独十次验证覆盖）。详细顺序见 migration.md 的 S6 记录。

采购存档摘要（原始Country / 原始Economy / 恢复后Economy）：
- `13d8d3ceb67405b86efa774e33080c369267e516268c717abfc8169c85add609`
- `8486a3eb674de2850b9d1ba22245dddf9cadefa3a32e71421d48ded35efd9d0a`
- `b3fa8883cfd9d859a649820814baa56919e1b86ccfb5422ad8966dde00d0cf35`

财政对应摘要：
- `001c5f85b2087ecf4e31a75c1fe5b7ca0742061ee17a1dcd65d9196d967497be`
- `87e22f6241eb555301011d45c515b334dbf8ed942eefb3a143206f591b49b5e5`
- `ad51db8ad716425386c8d6f10668ff742ec8637764e37e1d0b1ae993ae5b0c6f`

未验证release/Web运行、全部故障/拒绝/过期顺序键分支和所有保存状态；不以两个专用用例声称完成全状态证明。既存 restart-day 等待窗口、Modifier `[24,32)`/注释`[28,36)`问题、财政续跑测试4项既存失败继续只记录；本轮未修。S5-B公开同步回退/SHADOW/parity仍保留，Web产品范围尚待用户决定。旧过程文档已清理，29份待决定文档不动。

## S7 当前：写入端口与显式开关（2026-11-04）

本节是 S7 当前结果；上文 S4–S6 数量为历史截面。已验证源码：经济直接写 Country 从 34 减至 2，所有者与执行线程不变。现金/物资14处、研究/国库支出9处、殖民9处通过原位置消费的类型化请求和既有完成协议接通；worker仍优先走原队列，不新增序号、保存字段或第二条队列。军事两处因非零收支覆盖不足保留，详见 module-boundaries.md。

**已验证的保存差异（迁移前已存在）**：殖民用例原始 PKCN 长度42079，往返后唯一差异是偏移42047的1→3；这是尾部内嵌Modifier snapshot_version。`country_runtime.cpp:10389`序列化内嵌域，`modifier_runtime.cpp:2559`写版本、`:2806`恢复时递增版本。两份逻辑国家哈希均为-8865209123777288790。专用基线保留原始和重编码的完整流SHA256及该字节差异，不改保存代码、不删字段、不修改此前已记录的Modifier哈希排除范围。经济PKEC重编码也按原有做法分别对照迁移前结果。

**实现与边界**：`runtime_switch_registry.{h,cpp}`集中登记93个环境键、46个故障名称（含12域×前后边界，以及无效域回退unknown的两个名字）；37个旧文件的135处读取改用枚举入口。27处故障调用及原字符串构造均未改。默认值描述只供审计，getter直接返回原环境指针；不注入默认字符串，不把空串变成未设置，不改变原static缓存。标为“诊断”的条目也未增加生产禁用门禁，因此不能据此删除。

**已验证语义**：独立C++程序对93项各检查未设置、空串、0、1、10、true、-7、file.csv，共744种情况，返回指针与std::getenv相同。源码对照确认36个读取文件除include/getter外逐词一致；经济主文件另含本轮intent改动，全部环境读取后240字符的解析窗口保持一致。证据：`/tmp/keynes-arch-phase1/stage7/environment-replacement-audit.json`。这不是全部93种非默认配置组合的游戏回放。

**验证记录**：改前默认回归37/37；三组intent分别构建、主黄金3/3、v5 3/3和专用非零/保存用例通过。开关版构建通过；最终默认回归41/41，主黄金和v5各10/10，见本节末尾。

### C++ 环境读取清单

位置均相对`gdext/src/`；列出全部读取位置。生产列表示是否可能由正式进程走到读取处，不表示默认开启。测试/工具列只列显式名称检索样例，“未检索到”不等于证明无人依赖。默认值的细节和每处解析仍以所列调用点为准（例如首字符1与精确字符串1仍有区别）。

| 名称 | 位置 | 未设置时 / 作用 | 仅诊断用途 | 生产读取 | 测试/工具引用例 |
| --- | --- | --- | --- | --- | --- |
| `PK_CLIMATE_CYCLONE_FORCE` | runtime_climate_kernel.cpp:1081；runtime_climate_kernel.cpp:2377 | 关闭覆盖；原调用点解析；强制开启气旋 | 否 | 可；相应分支执行时 | 未检索到显式名称 |
| `PK_CLIMATE_CYCLONE_GENESIS_GATE` | runtime_climate_kernel.cpp:2667 | 0（不覆盖原阈值）；覆盖气旋生成强度阈值 | 否 | 可；相应分支执行时 | 未检索到显式名称 |
| `PK_CLIMATE_FIELD_DIAG` | runtime_climate_parity.cpp:355 | 关闭覆盖；原调用点解析；气候对拍逐字段差异 | 是 | parity比较分支；默认不走 | 未检索到显式名称 |
| `PK_CLIMATE_HISTORY_COPY_FULL` | runtime_climate_kernel.cpp:106 | 关闭覆盖；原调用点解析；完整复制气候历史 | 是 | 可；相应分支执行时 | 未检索到显式名称 |
| `PK_CLIMATE_HISTORY_COPY_VERIFY` | runtime_climate_kernel.cpp:110 | 关闭覆盖；原调用点解析；核对气候历史增量复制 | 是 | 可；相应分支执行时 | 未检索到显式名称 |
| `PK_CLIMATE_INPUT_HASH_FULL` | runtime_climate_kernel.cpp:1262 | 关闭覆盖；原调用点解析；完整计算气候输入哈希 | 是 | 可；相应分支执行时 | 未检索到显式名称 |
| `PK_CLIMATE_LANE_DIAG` | runtime_climate_passes.cpp:2052 | 关闭覆盖；原调用点解析；气候列覆盖诊断 | 是 | 可；相应分支执行时 | 未检索到显式名称 |
| `PK_CLIMATE_PHYSICS_RESIDENT_VERIFY` | runtime_climate_authority.cpp:382 | 关闭覆盖；原调用点解析；核对气候驻留状态复用 | 是 | 可；相应分支执行时 | 未检索到显式名称 |
| `PK_CLIMATE_PHYSICS_RESTORE_FULL` | runtime_climate_kernel.cpp:894 | 关闭覆盖；原调用点解析；完整恢复气候物理状态 | 是 | 可；相应分支执行时 | 未检索到显式名称 |
| `PK_CLIMATE_SCALAR_DIAG` | runtime_climate_passes.cpp:2220 | 关闭覆盖；原调用点解析；气候标量覆盖诊断 | 是 | 可；相应分支执行时 | 未检索到显式名称 |
| `PK_CLIMATE_STAGE_ORDER_LEGACY` | runtime_climate_kernel.cpp:2121 | 关闭覆盖；原调用点解析；采用旧气候阶段顺序 | 否 | 可；相应分支执行时 | 未检索到显式名称 |
| `PK_CLIMATE_STAGE_TRACE` | runtime_climate_passes.cpp:2832 | 关闭覆盖；原调用点解析；气候阶段执行追踪 | 是 | 可；相应分支执行时 | 未检索到显式名称 |
| `PK_CLIMATE_SYNOPTIC_OFF` | runtime_climate_kernel.cpp:1066；runtime_climate_kernel.cpp:2481 | 关闭覆盖；原调用点解析；关闭大尺度天气推进 | 否 | 可；相应分支执行时 | 未检索到显式名称 |
| `PK_CLIMATE_TRACE_CELL` | runtime_climate_kernel.cpp:3053 | -1（不追踪）；指定地块气候追踪 | 是 | 可；相应分支执行时 | 未检索到显式名称 |
| `PK_COUNTRY_HASH_PROBE` | economy_runtime_persistence_read.cpp:601 | 关闭；任意已设置值（含空串）开启；国家恢复哈希错误诊断 | 是 | 可；相应分支执行时 | 未检索到显式名称 |
| `PK_DIAG_NO_FOOD_SUBSTITUTE` | economy_runtime_market.cpp:1300 | 关闭；任意已设置值（含空串）开启；禁止食品替代价格上限（改变模拟） | 否 | 可；相应分支执行时 | 未检索到显式名称 |
| `PK_DIAG_NO_STARVING_RELEASE` | economy_runtime_building_employment.cpp:3167 | 关闭；任意已设置值（含空串）开启；禁止饥饿所有者释放岗位（改变模拟） | 否 | 可；相应分支执行时 | 未检索到显式名称 |
| `PK_DIAG_STAGE_MONEY` | economy_runtime.cpp:15330 | -1（不追踪）；从指定日开始逐阶段资金诊断 | 是 | 可；相应分支执行时 | 未检索到显式名称 |
| `PK_DISABLE_SUPPORT_GATE` | world_ext_ideology.cpp:165 | 关闭；任意已设置值（含空串）开启；清空意识形态支持门槛（改变模拟） | 否 | 可；相应分支执行时 | Project/project-keynes/tests/ideology/ideology_card_content_worker_test.gd:402；Project/project-keynes/tests/ideology/run_cell_card_worker.ps1:26 |
| `PK_ECONOMY_ACTIVE_WORKSET_DISABLE` | economy_runtime.cpp:16904；economy_runtime.cpp:23180；economy_runtime.cpp:8490；economy_runtime_building_investment.cpp:1738；economy_runtime_building_production.cpp:866；economy_runtime_market.cpp:351 | 关闭覆盖；原调用点解析；关闭经济活动集合优化 | 是 | 可；相应分支执行时 | Project/project-keynes/tests/economy/economy_preview_basis_parity_test.gd:18；Project/project-keynes/tests/economy/economy_preview_basis_parity_test.gd:38 |
| `PK_ECONOMY_ATTRIBUTION_MEMO_DISABLE` | economy_runtime.h:1954 | 关闭覆盖；原调用点解析；关闭冻结价归属缓存 | 是 | 可；相应分支执行时 | Project/project-keynes/tests/economy/economy_preview_basis_parity_test.gd:26；Project/project-keynes/tests/economy/economy_preview_basis_parity_test.gd:46 |
| `PK_ECONOMY_AUDIT_SHADOW_REUSE` | economy_runtime.cpp:242 | 开启；仅精确字符串 0 关闭；复用守恒审计前像 | 是 | 可；相应分支执行时 | 未检索到显式名称 |
| `PK_ECONOMY_AUDIT_VERIFY_EVERY_DAY` | economy_runtime_epoch.cpp:1309；economy_runtime_publish.cpp:91 | 关闭覆盖；原调用点解析；每天核对全量守恒审计 | 是 | 可；相应分支执行时 | 未检索到显式名称 |
| `PK_ECONOMY_COST_CSV` | economy_cost_probe.h:36 | 不输出文件；空串也不打开；经济阶段耗时 CSV 文件 | 是 | 可；相应分支执行时 | tools/perf/run_replay_probe.ps1:55；tools/perf/run_replay_probe.ps1:59 |
| `PK_ECONOMY_COST_CSV_FULL` | economy_cost_probe.h:39 | 关闭覆盖；原调用点解析；逐条输出经济耗时 | 是 | 可；相应分支执行时 | tools/perf/run_replay_probe.ps1:56；tools/perf/run_replay_probe.ps1:61 |
| `PK_ECONOMY_DERIVED_PARALLEL` | economy_runtime_building_investment.cpp:1756 | 开启；仅精确字符串 0 关闭；派生数据并行计算 | 是 | 可；相应分支执行时 | 未检索到显式名称 |
| `PK_ECONOMY_DERIVED_TASKS` | economy_runtime_building_investment.cpp:1762 | 0（使用原自动任务数）；覆盖派生数据任务数 | 是 | 可；相应分支执行时 | 未检索到显式名称 |
| `PK_ECONOMY_DERIVED_TRACE` | economy_runtime_building_investment.cpp:1809 | 关闭覆盖；原调用点解析；派生任务耗时诊断 | 是 | 可；相应分支执行时 | 未检索到显式名称 |
| `PK_ECONOMY_FAMILY_GOOD_CACHE_DISABLE` | economy_runtime_market.cpp:1305 | 关闭覆盖；原调用点解析；关闭家庭物资折扣缓存 | 是 | 可；相应分支执行时 | Project/project-keynes/tests/economy/economy_preview_basis_parity_test.gd:28；Project/project-keynes/tests/economy/economy_preview_basis_parity_test.gd:48 |
| `PK_ECONOMY_FAMILY_LOOKUP_LINEAR` | economy_runtime.cpp:18345；economy_runtime.cpp:18446 | 关闭覆盖；原调用点解析；家庭行为查询改走线性参考 | 是 | 可；相应分支执行时 | Project/project-keynes/tests/economy/economy_preview_basis_parity_test.gd:19；Project/project-keynes/tests/economy/economy_preview_basis_parity_test.gd:39 |
| `PK_ECONOMY_FAMILY_LOOKUP_VERIFY` | economy_runtime.cpp:18349；economy_runtime.cpp:18450 | 关闭覆盖；原调用点解析；核对家庭查询索引 | 是 | 可；相应分支执行时 | Project/project-keynes/tests/economy/economy_preview_basis_parity_test.gd:15 |
| `PK_ECONOMY_FAMILY_METRIC_MASK_DISABLE` | economy_runtime.cpp:16714；economy_runtime.cpp:17225 | 关闭覆盖；原调用点解析；计算完整家庭指标 | 是 | 可；相应分支执行时 | Project/project-keynes/tests/economy/economy_preview_basis_parity_test.gd:30；Project/project-keynes/tests/economy/economy_preview_basis_parity_test.gd:50 |
| `PK_ECONOMY_FOOD_CAPACITY_SERIAL` | economy_runtime_carrying.cpp:117 | 关闭覆盖；原调用点解析；食物承载计算串行 | 是 | 可；相应分支执行时 | Project/project-keynes/tests/economy/economy_preview_basis_parity_test.gd:35；Project/project-keynes/tests/economy/economy_preview_basis_parity_test.gd:55 |
| `PK_ECONOMY_FOOD_STOCK_SCAN_SCALAR` | economy_runtime_carrying.cpp:157；economy_runtime_carrying.cpp:203 | 关闭覆盖；原调用点解析；食物库存改走完整扫描 | 是 | 可；相应分支执行时 | Project/project-keynes/tests/economy/economy_preview_basis_parity_test.gd:29；Project/project-keynes/tests/economy/economy_preview_basis_parity_test.gd:49 |
| `PK_ECONOMY_HASH_V2` | runtime_chunk_hash.h:17 | 开启；仅精确字符串 0 关闭；启用分块哈希 | 否 | 可；相应分支执行时 | tools/runtime/Invoke-SaveMigration.ps1:24 |
| `PK_ECONOMY_HASH_VERIFY` | economy_runtime.cpp:25961；runtime_chunk_hash.h:187；runtime_chunk_hash.h:61；runtime_economy_state.cpp:181 | 关闭覆盖；原调用点解析；核对经济增量哈希 | 是 | 可；相应分支执行时 | 未检索到显式名称 |
| `PK_ECONOMY_MARKET_PUBLISH_FULL` | runtime_economy_pod.cpp:627 | 关闭覆盖；原调用点解析；市场发布完整复制 | 是 | 可；相应分支执行时 | 未检索到显式名称 |
| `PK_ECONOMY_MEMO_DISABLE` | economy_runtime.h:1948；economy_runtime_building_investment.cpp:636 | 关闭覆盖；原调用点解析；关闭生活成本缓存 | 是 | 可；相应分支执行时 | 未检索到显式名称 |
| `PK_ECONOMY_MEMO_VERIFY` | economy_runtime.cpp:11910；economy_runtime.cpp:12293；economy_runtime.cpp:16718；economy_runtime.cpp:16908；economy_runtime.cpp:18223；economy_runtime.cpp:18725；economy_runtime.cpp:8705；economy_runtime_building_investment.cpp:702；economy_runtime_carrying.cpp:139；economy_runtime_carrying.cpp:207；economy_runtime_market.cpp:573；economy_runtime_market.cpp:83；economy_runtime_math.cpp:222 | 关闭覆盖；原调用点解析；核对经济缓存命中结果 | 是 | 可；相应分支执行时 | Project/project-keynes/tests/economy/economy_preview_basis_parity_test.gd:14；Project/project-keynes/tests/economy/economy_preview_basis_parity_test.gd:78 |
| `PK_ECONOMY_MIRROR_VERIFY` | runtime_economy_pod.cpp:592；runtime_economy_pod.cpp:630 | 关闭覆盖；原调用点解析；核对经济镜像导入与发布 | 是 | 可；相应分支执行时 | 未检索到显式名称 |
| `PK_ECONOMY_MUL_DIV_SCALAR` | economy_runtime_math.cpp:90 | 关闭覆盖；原调用点解析；乘除改走宽整数参考 | 是 | 可；相应分支执行时 | Project/project-keynes/tests/economy/economy_preview_basis_parity_test.gd:32；Project/project-keynes/tests/economy/economy_preview_basis_parity_test.gd:52 |
| `PK_ECONOMY_OWNER_QUOTE_TRACE` | economy_runtime.cpp:12014 | 关闭覆盖；原调用点解析；建筑所有者报价耗时诊断 | 是 | 可；相应分支执行时 | 未检索到显式名称 |
| `PK_ECONOMY_POW_CACHE_DISABLE` | economy_runtime_math.cpp:218 | 关闭覆盖；原调用点解析；关闭定点幂缓存 | 是 | 可；相应分支执行时 | Project/project-keynes/tests/economy/economy_preview_basis_parity_test.gd:20；Project/project-keynes/tests/economy/economy_preview_basis_parity_test.gd:40 |
| `PK_ECONOMY_PREVIEW_BASIS_DISABLE` | economy_runtime_market.cpp:346；economy_runtime_market.cpp:79 | 关闭覆盖；原调用点解析；关闭需求预估基底复用 | 是 | 可；相应分支执行时 | Project/project-keynes/tests/economy/economy_preview_basis_parity_test.gd:17；Project/project-keynes/tests/economy/economy_preview_basis_parity_test.gd:37 |
| `PK_ECONOMY_PRODUCTION_TASKS` | economy_runtime.cpp:15940；economy_runtime.cpp:24062 | 0（使用原自动任务数）；覆盖生产任务数量 | 是 | 可；相应分支执行时 | 未检索到显式名称 |
| `PK_ECONOMY_RESOURCE_PROJECTION_SCALAR` | economy_runtime.cpp:2880；economy_runtime.cpp:2955 | 关闭覆盖；原调用点解析；资源投影改走标量复制 | 是 | 可；相应分支执行时 | Project/project-keynes/tests/economy/economy_preview_basis_parity_test.gd:31；Project/project-keynes/tests/economy/economy_preview_basis_parity_test.gd:51 |
| `PK_ECONOMY_RESOURCE_WIRE_CACHE_DISABLE` | runtime_economy_state.cpp:177 | 关闭覆盖；原调用点解析；关闭资源保存哈希缓存 | 是 | 可；相应分支执行时 | Project/project-keynes/tests/economy/economy_preview_basis_parity_test.gd:21；Project/project-keynes/tests/economy/economy_preview_basis_parity_test.gd:41 |
| `PK_ECONOMY_RESOURCE_WIRE_HASH_SCALAR` | runtime_economy_state.cpp:169 | 关闭覆盖；原调用点解析；资源保存哈希标量参考 | 是 | 可；相应分支执行时 | Project/project-keynes/tests/economy/economy_preview_basis_parity_test.gd:33；Project/project-keynes/tests/economy/economy_preview_basis_parity_test.gd:53 |
| `PK_ECONOMY_RETENTION_MEMO_DISABLE` | economy_runtime.cpp:12242 | 关闭覆盖；原调用点解析；关闭留存估值缓存 | 是 | 可；相应分支执行时 | Project/project-keynes/tests/economy/economy_preview_basis_parity_test.gd:24；Project/project-keynes/tests/economy/economy_preview_basis_parity_test.gd:44 |
| `PK_ECONOMY_STAGE_PLAN_SERIAL` | economy_runtime.cpp:23288 | 关闭覆盖；原调用点解析；经济计划任务串行 | 是 | 可；相应分支执行时 | Project/project-keynes/tests/economy/economy_preview_basis_parity_test.gd:22；Project/project-keynes/tests/economy/economy_preview_basis_parity_test.gd:42 |
| `PK_ECONOMY_STARTUP_TRACE` | economy_runtime_building_investment.cpp:731 | 关闭覆盖；原调用点解析；启动生产者选择耗时 | 是 | 可；相应分支执行时 | 未检索到显式名称 |
| `PK_ECONOMY_TRACK_B` | economy_runtime.cpp:16629；economy_runtime.cpp:16675；economy_runtime.cpp:21918；economy_runtime_building_employment.cpp:1083；economy_runtime_building_employment.cpp:1916；economy_runtime_building_investment.cpp:1672 | 开启；仅精确字符串 0 关闭；开启分日刷新和缓存节拍 | 否 | 可；相应分支执行时 | 未检索到显式名称 |
| `PK_ECONOMY_TRACK_B_COMMIT_CADENCE` | economy_runtime.cpp:21922 | 4；正数上限 30；建筑提交刷新周期 | 否 | 可；相应分支执行时 | 未检索到显式名称 |
| `PK_ECONOMY_TRACK_B_DERIVED_CADENCE` | economy_runtime_building_investment.cpp:1676 | 5；正数上限 30；派生数据刷新周期 | 否 | 可；相应分支执行时 | 未检索到显式名称 |
| `PK_ECONOMY_TRACK_B_DERIVED_SPREAD` | economy_runtime_building_investment.cpp:1685 | 4；正数上限 32；派生数据分日分桶数 | 否 | 可；相应分支执行时 | 未检索到显式名称 |
| `PK_ECONOMY_TRACK_B_FAMILY_ATTRIBUTION_CADENCE` | economy_runtime_building_employment.cpp:1920 | 5；正数上限 30；家庭归属刷新周期 | 否 | 可；相应分支执行时 | 未检索到显式名称 |
| `PK_ECONOMY_TRACK_B_FAMILY_ATTRIBUTION_SPREAD` | economy_runtime_building_employment.cpp:1925 | 1；正数上限 32；家庭归属分日分桶数 | 否 | 可；相应分支执行时 | 未检索到显式名称 |
| `PK_ECONOMY_TRACK_B_FAMILY_CACHE_CADENCE` | economy_runtime.cpp:16679 | 5；正数上限 30；家庭缓存刷新周期 | 否 | 可；相应分支执行时 | 未检索到显式名称 |
| `PK_ECONOMY_TRACK_B_FAMILY_CACHE_OFFSET` | economy_runtime.cpp:16684 | 1；非零取绝对值；家庭缓存刷新相位 | 否 | 可；相应分支执行时 | 未检索到显式名称 |
| `PK_ECONOMY_TRACK_B_HASH_CADENCE` | economy_runtime.cpp:16633 | 8；正数上限 30；哈希全量刷新周期 | 否 | 可；相应分支执行时 | 未检索到显式名称 |
| `PK_ECONOMY_TRACK_B_HASH_OFFSET` | economy_runtime.cpp:16638 | 2；非零取绝对值；哈希刷新相位 | 否 | 可；相应分支执行时 | 未检索到显式名称 |
| `PK_ECONOMY_TRACK_B_MOBILITY_CADENCE` | economy_runtime_building_employment.cpp:1087 | 5；正数上限 30；就业流动刷新周期 | 否 | 可；相应分支执行时 | 未检索到显式名称 |
| `PK_ECONOMY_TRACK_B_MOBILITY_SPREAD` | economy_runtime_building_employment.cpp:1092 | 1；正数上限 32；就业流动分日分桶数 | 否 | 可；相应分支执行时 | 未检索到显式名称 |
| `PK_ECONOMY_TRACK_B_RECOVERY_OFFSET` | economy_runtime.cpp:21927 | 1；非零取绝对值；恢复提交刷新相位 | 否 | 可；相应分支执行时 | 未检索到显式名称 |
| `PK_ECONOMY_VARIANT_PRICE_BASIS_DISABLE` | economy_runtime_market.cpp:356；economy_runtime_market.cpp:89 | 关闭覆盖；原调用点解析；关闭变体价格基底复用 | 是 | 可；相应分支执行时 | Project/project-keynes/tests/economy/economy_preview_basis_parity_test.gd:27；Project/project-keynes/tests/economy/economy_preview_basis_parity_test.gd:47 |
| `PK_ECONOMY_VARIANT_WEIGHT_SCALAR` | economy_runtime.cpp:18736 | 关闭覆盖；原调用点解析；变体权重改走标量参考 | 是 | 可；相应分支执行时 | Project/project-keynes/tests/economy/economy_preview_basis_parity_test.gd:25；Project/project-keynes/tests/economy/economy_preview_basis_parity_test.gd:45 |
| `PK_ECONOMY_WORKER_TASK_CAP` | economy_runtime_profile.cpp:123 | 0（使用原自动任务数）；覆盖经济工作任务上限 | 是 | 可；相应分支执行时 | 未检索到显式名称 |
| `PK_EVENTS_APPEND_SCALAR` | runtime_events_authority.cpp:379 | 关闭覆盖；原调用点解析；事件追加采用标量压缩 | 是 | 可；相应分支执行时 | 未检索到显式名称 |
| `PK_GOLDEN_COUNTRY_TRACE` | native_simulation_golden.cpp:294 | 不输出文件；空串也不打开；国家逐列黄金诊断文件 | 是 | 黄金摘要启用时 | 未检索到显式名称 |
| `PK_GOLDEN_DOMAINS` | world_ext_golden.cpp:11 | 关闭覆盖；原调用点解析；只读逐域黄金摘要 | 是 | 可；相应分支执行时 | Project/project-keynes/tests/runtime/golden_day_hash_test.gd:17；Project/project-keynes/tests/runtime/golden_external_advancers_test.gd:16 |
| `PK_INLINE_DAY_BUDGET_MS` | gdext/src/native_simulation_host_commands.cpp:503 | 30000 ms；空串同；非正数为 0；内联日执行预算 | 否 | 可；相应分支执行时 | 未检索到显式名称 |
| `PK_INLINE_PARALLEL` | world_ext_simulation_host.cpp:486 | 关闭覆盖；原调用点解析；允许内联日线程池 | 否 | 可；相应分支执行时 | 未检索到显式名称 |
| `PK_PEER_STALL_TIMEOUT_MS` | gdext/src/native_simulation_host_worker.cpp:49 | RUNTIME_DAY_STALL_PEER_FAULT_TIMEOUT_MS；空串同；仅允许增大；国家经济互等故障超时 | 否 | 可；相应分支执行时 | Project/project-keynes/tests/ideology/run_cell_card_worker.ps1:27 |
| `PK_RUNTIME_INPUT_HASH_FULL` | native_simulation_day_capture_day_input.cpp:33 | 关闭覆盖；原调用点解析；完整重算冻结输入哈希 | 是 | 可；相应分支执行时 | 未检索到显式名称 |
| `PK_RUNTIME_INPUT_HASH_VERIFY` | native_simulation_day_capture_day_input.cpp:37 | 关闭覆盖；原调用点解析；核对冻结输入哈希复用 | 是 | 可；相应分支执行时 | 未检索到显式名称 |
| `PK_RUNTIME_WATERFALL_CSV` | runtime_day_waterfall.h:66 | 不输出文件；空串也不打开；运行时阶段耗时 CSV 文件 | 是 | 可；相应分支执行时 | tools/perf/run_replay_probe.ps1:54；tools/perf/run_replay_probe.ps1:58 |
| `PK_SAVE_BYTE_HASH_SCALAR` | economy_hash.h:79 | 关闭覆盖；原调用点解析；保存字节哈希改走标量参考实现 | 是 | 可；相应分支执行时 | 未检索到显式名称 |
| `PK_SAVE_BYTE_HASH_VERIFY` | economy_hash.h:83 | 关闭覆盖；原调用点解析；核对保存字节哈希 | 是 | 可；相应分支执行时 | 未检索到显式名称 |
| `PK_SAVE_CODEC_SCALAR` | economy_runtime_binary_codec.h:18；runtime_climate_authority.cpp:71 | 关闭覆盖；原调用点解析；保存编码改走标量参考 | 是 | 可；相应分支执行时 | Project/project-keynes/tests/economy/economy_preview_basis_parity_test.gd:23；Project/project-keynes/tests/economy/economy_preview_basis_parity_test.gd:43 |
| `PK_SAVE_CODEC_VERIFY` | economy_runtime_persistence.cpp:2161；economy_runtime_persistence_write.cpp:1337；runtime_economy_ecp2.cpp:464 | 关闭覆盖；原调用点解析；核对保存编码字节 | 是 | 可；相应分支执行时 | 未检索到显式名称 |
| `PK_SAVE_MIGRATE` | runtime_chunk_hash.h:24 | 关闭覆盖；原调用点解析；允许旧哈希保存迁移 | 否 | 可；相应分支执行时 | Project/project-keynes/tests/game/headless_save_replay.gd:87；tools/runtime/Invoke-SaveMigration.ps1:24 |
| `PK_SAVE_SHAPE_PROBE` | economy_runtime.cpp:3134；economy_runtime_persistence.cpp:354 | 关闭；任意已设置值（含空串）开启；保存形状错误诊断 | 是 | 可；相应分支执行时 | 未检索到显式名称 |
| `PK_SIM_DAY_TRACE` | native_simulation_day_support.cpp:6 | 不输出文件；空串也不打开；逐日环境和阶段追踪文件 | 是 | 可；相应分支执行时 | tools/perf/run_replay_probe.ps1:66；tools/perf/run_replay_probe.ps1:70 |
| `PK_TAG_FORCE_ALL` | economy_runtime_family_buff.cpp:1317 | 关闭覆盖；原调用点解析；家庭效果计算全部标签 | 是 | 可；相应分支执行时 | 未检索到显式名称 |
| `PK_TRIGGER_BINDING_SCAN_SCALAR` | runtime_trigger_kernel.cpp:425 | 关闭覆盖；原调用点解析；触发绑定完整扫描 | 是 | 可；相应分支执行时 | 未检索到显式名称 |
| `PK_TRIGGER_COMMAND_COPY_SCALAR` | runtime_trigger_pod.cpp:1074 | 关闭覆盖；原调用点解析；触发命令复制并排序参考 | 是 | 可；相应分支执行时 | Project/project-keynes/tests/economy/economy_preview_basis_parity_test.gd:34；Project/project-keynes/tests/economy/economy_preview_basis_parity_test.gd:54 |
| `PK_TRIGGER_HASH_SCALAR` | runtime_trigger_pod.cpp:182 | 关闭覆盖；原调用点解析；触发状态哈希标量参考 | 是 | 可；相应分支执行时 | 未检索到显式名称 |
| `PK_TRIGGER_MEMO_VERIFY` | runtime_trigger_pod.cpp:1110 | 关闭覆盖；原调用点解析；核对触发缓存结果 | 是 | 可；相应分支执行时 | 未检索到显式名称 |
| `PK_TTA_CARRY_OFF` | runtime_climate_kernel.cpp:1420 | 继承开启；任意已设置值（含空串）关闭；关闭温度输送异常跨日继承 | 否 | 可；相应分支执行时 | 未检索到显式名称 |
| `PK_TTA_DIAG` | runtime_climate_kernel.cpp:1554 | 关闭；任意已设置值（含空串）开启；打印温度输送异常统计 | 是 | 可；相应分支执行时 | 未检索到显式名称 |
| `PK_WEB_PARALLEL` | world_ext_simulation_host.cpp:503 | 关闭覆盖；原调用点解析；允许 Web 线程池 | 否 | 可；相应分支执行时 | 未检索到显式名称 |
| `PK_WS_PROBE_CELL` | runtime_climate_passes.cpp:710 | -1（不追踪）；指定地块地表风探针 | 是 | 可；相应分支执行时 | 未检索到显式名称 |
| `PK_X16_PROBE` | economy_runtime.cpp:5797 | 关闭；任意已设置值（含空串）开启；冻结 Modifier 职业容忍参数诊断 | 是 | 可；相应分支执行时 | 未检索到显式名称 |

### 故障注入名称

全部默认未武装；`world_ext_bind_methods.cpp:358`保留公开arm/clear绑定，`world_ext_simulation_host.cpp:3242`转发，`gdext/src/native_simulation_host.cpp:459`保留一次性故障行为。正式日图/保存/恢复/切换能经过这些检查，但不武装就不触发。unknown域只是在非法枚举下的回退名字。

| 名称 | 检查位置 | 作用 / 生产范围 | 测试/工具引用例 |
| --- | --- | --- | --- |
| `authority.switch.after` | gdext/src/native_simulation_host_economy.cpp:272；gdext/src/native_simulation_host_economy.cpp:282；gdext/src/native_simulation_host_economy.cpp:309 | 同名提交/切换/保存/恢复边界；相应生产操作 | 未检索到显式名称 |
| `authority.switch.before` | gdext/src/native_simulation_host_economy.cpp:130 | 同名提交/切换/保存/恢复边界；相应生产操作 | 未检索到显式名称 |
| `climate.plan.after` | gdext/src/native_simulation_host.cpp:74；gdext/src/native_simulation_host.cpp:311；gdext/src/native_simulation_host.cpp:320；gdext/src/native_simulation_host.cpp:351（域名拼接） | 域计划前/后；生产日图 | 未检索到显式名称 |
| `climate.plan.before` | gdext/src/native_simulation_host.cpp:74；gdext/src/native_simulation_host.cpp:311；gdext/src/native_simulation_host.cpp:320；gdext/src/native_simulation_host.cpp:351（域名拼接） | 域计划前/后；生产日图 | 未检索到显式名称 |
| `commit.plan.after` | gdext/src/native_simulation_host.cpp:74；gdext/src/native_simulation_host.cpp:311；gdext/src/native_simulation_host.cpp:320；gdext/src/native_simulation_host.cpp:351（域名拼接） | 域计划前/后；生产日图 | 未检索到显式名称 |
| `commit.plan.before` | gdext/src/native_simulation_host.cpp:74；gdext/src/native_simulation_host.cpp:311；gdext/src/native_simulation_host.cpp:320；gdext/src/native_simulation_host.cpp:351（域名拼接） | 域计划前/后；生产日图 | 未检索到显式名称 |
| `country.plan.after` | gdext/src/native_simulation_host.cpp:74；gdext/src/native_simulation_host.cpp:311；gdext/src/native_simulation_host.cpp:320；gdext/src/native_simulation_host.cpp:351（域名拼接） | 域计划前/后；生产日图 | 未检索到显式名称 |
| `country.plan.before` | gdext/src/native_simulation_host.cpp:74；gdext/src/native_simulation_host.cpp:311；gdext/src/native_simulation_host.cpp:320；gdext/src/native_simulation_host.cpp:351（域名拼接） | 域计划前/后；生产日图 | 未检索到显式名称 |
| `day.commit.after` | gdext/src/native_simulation_host_commands.cpp:847 | 同名提交/切换/保存/恢复边界；相应生产操作 | 未检索到显式名称 |
| `day.commit.before` | gdext/src/native_simulation_host_commands.cpp:715 | 同名提交/切换/保存/恢复边界；相应生产操作 | 未检索到显式名称 |
| `day.plan.after` | gdext/src/native_simulation_host.cpp:377 | 域计划前/后；生产日图 | 未检索到显式名称 |
| `day.plan.before` | gdext/src/native_simulation_host.cpp:221 | 域计划前/后；生产日图 | 未检索到显式名称 |
| `economy.commit.after` | gdext/src/native_simulation_host_economy.cpp:753 | 同名提交/切换/保存/恢复边界；相应生产操作 | 未检索到显式名称 |
| `economy.commit.before` | gdext/src/native_simulation_host_economy.cpp:740 | 同名提交/切换/保存/恢复边界；相应生产操作 | 未检索到显式名称 |
| `economy.plan.after` | gdext/src/native_simulation_host_economy.cpp:699；gdext/src/native_simulation_host.cpp:74；gdext/src/native_simulation_host.cpp:311；gdext/src/native_simulation_host.cpp:320；gdext/src/native_simulation_host.cpp:351（域名拼接） | 域计划前/后；生产日图 | 未检索到显式名称 |
| `economy.plan.before` | gdext/src/native_simulation_host_economy.cpp:666；gdext/src/native_simulation_host.cpp:74；gdext/src/native_simulation_host.cpp:311；gdext/src/native_simulation_host.cpp:320；gdext/src/native_simulation_host.cpp:351（域名拼接） | 域计划前/后；生产日图 | 未检索到显式名称 |
| `economy.reservation.after` | gdext/src/native_simulation_host_economy.cpp:728 | 同名提交/切换/保存/恢复边界；相应生产操作 | 未检索到显式名称 |
| `economy.reservation.before` | gdext/src/native_simulation_host_economy.cpp:708 | 同名提交/切换/保存/恢复边界；相应生产操作 | 未检索到显式名称 |
| `effect.plan.after` | gdext/src/native_simulation_host.cpp:74；gdext/src/native_simulation_host.cpp:311；gdext/src/native_simulation_host.cpp:320；gdext/src/native_simulation_host.cpp:351（域名拼接） | 域计划前/后；生产日图 | 未检索到显式名称 |
| `effect.plan.before` | gdext/src/native_simulation_host.cpp:74；gdext/src/native_simulation_host.cpp:311；gdext/src/native_simulation_host.cpp:320；gdext/src/native_simulation_host.cpp:351（域名拼接） | 域计划前/后；生产日图 | 未检索到显式名称 |
| `events.append.after` | native_simulation_day_run_day_events.cpp:47 | 同名提交/切换/保存/恢复边界；相应生产操作 | 未检索到显式名称 |
| `events.append.before` | native_simulation_day_run_day_events.cpp:35 | 同名提交/切换/保存/恢复边界；相应生产操作 | 未检索到显式名称 |
| `events.commit.after` | native_simulation_day_run_day_events.cpp:63 | 同名提交/切换/保存/恢复边界；相应生产操作 | 未检索到显式名称 |
| `events.commit.before` | native_simulation_day_run_day_events.cpp:54 | 同名提交/切换/保存/恢复边界；相应生产操作 | 未检索到显式名称 |
| `events.plan.after` | gdext/src/native_simulation_host.cpp:74；gdext/src/native_simulation_host.cpp:311；gdext/src/native_simulation_host.cpp:320；gdext/src/native_simulation_host.cpp:351（域名拼接） | 域计划前/后；生产日图 | 未检索到显式名称 |
| `events.plan.before` | gdext/src/native_simulation_host.cpp:74；gdext/src/native_simulation_host.cpp:311；gdext/src/native_simulation_host.cpp:320；gdext/src/native_simulation_host.cpp:351（域名拼接） | 域计划前/后；生产日图 | 未检索到显式名称 |
| `gameplay_effect.plan.after` | gdext/src/native_simulation_host.cpp:74；gdext/src/native_simulation_host.cpp:311；gdext/src/native_simulation_host.cpp:320；gdext/src/native_simulation_host.cpp:351（域名拼接） | 域计划前/后；生产日图 | 未检索到显式名称 |
| `gameplay_effect.plan.before` | gdext/src/native_simulation_host.cpp:74；gdext/src/native_simulation_host.cpp:311；gdext/src/native_simulation_host.cpp:320；gdext/src/native_simulation_host.cpp:351（域名拼接） | 域计划前/后；生产日图 | 未检索到显式名称 |
| `ideology.plan.after` | gdext/src/native_simulation_host.cpp:74；gdext/src/native_simulation_host.cpp:311；gdext/src/native_simulation_host.cpp:320；gdext/src/native_simulation_host.cpp:351（域名拼接） | 域计划前/后；生产日图 | 未检索到显式名称 |
| `ideology.plan.before` | gdext/src/native_simulation_host.cpp:74；gdext/src/native_simulation_host.cpp:311；gdext/src/native_simulation_host.cpp:320；gdext/src/native_simulation_host.cpp:351（域名拼接） | 域计划前/后；生产日图 | 未检索到显式名称 |
| `input_capture.plan.after` | gdext/src/native_simulation_host.cpp:74；gdext/src/native_simulation_host.cpp:311；gdext/src/native_simulation_host.cpp:320；gdext/src/native_simulation_host.cpp:351（域名拼接） | 域计划前/后；生产日图 | 未检索到显式名称 |
| `input_capture.plan.before` | gdext/src/native_simulation_host.cpp:74；gdext/src/native_simulation_host.cpp:311；gdext/src/native_simulation_host.cpp:320；gdext/src/native_simulation_host.cpp:351（域名拼接） | 域计划前/后；生产日图 | 未检索到显式名称 |
| `modifier.plan.after` | gdext/src/native_simulation_host.cpp:74；gdext/src/native_simulation_host.cpp:311；gdext/src/native_simulation_host.cpp:320；gdext/src/native_simulation_host.cpp:351（域名拼接） | 域计划前/后；生产日图 | 未检索到显式名称 |
| `modifier.plan.before` | gdext/src/native_simulation_host.cpp:74；gdext/src/native_simulation_host.cpp:311；gdext/src/native_simulation_host.cpp:320；gdext/src/native_simulation_host.cpp:351（域名拼接） | 域计划前/后；生产日图 | 未检索到显式名称 |
| `restore.decode.before` | gdext/src/native_simulation_host_persistence.cpp:102 | 同名提交/切换/保存/恢复边界；相应生产操作 | 未检索到显式名称 |
| `restore.swap.before` | gdext/src/native_simulation_host_persistence.cpp:901 | 同名提交/切换/保存/恢复边界；相应生产操作 | 未检索到显式名称 |
| `restore.validate.before` | gdext/src/native_simulation_host_persistence.cpp:879 | 同名提交/切换/保存/恢复边界；相应生产操作 | 未检索到显式名称 |
| `save.barrier.after` | gdext/src/native_simulation_host_persistence.cpp:1487 | 同名提交/切换/保存/恢复边界；相应生产操作 | 未检索到显式名称 |
| `save.barrier.before` | gdext/src/native_simulation_host_persistence.cpp:914 | 同名提交/切换/保存/恢复边界；相应生产操作 | 未检索到显式名称 |
| `trigger_input.plan.after` | gdext/src/native_simulation_host.cpp:74；gdext/src/native_simulation_host.cpp:311；gdext/src/native_simulation_host.cpp:320；gdext/src/native_simulation_host.cpp:351（域名拼接） | 域计划前/后；生产日图 | 未检索到显式名称 |
| `trigger_input.plan.before` | gdext/src/native_simulation_host.cpp:74；gdext/src/native_simulation_host.cpp:311；gdext/src/native_simulation_host.cpp:320；gdext/src/native_simulation_host.cpp:351（域名拼接） | 域计划前/后；生产日图 | 未检索到显式名称 |
| `unknown.plan.after` | gdext/src/native_simulation_host.cpp:74；gdext/src/native_simulation_host.cpp:311；gdext/src/native_simulation_host.cpp:320；gdext/src/native_simulation_host.cpp:351（域名拼接） | 无效域回退；正常十二域不可达 | 未检索到显式名称 |
| `unknown.plan.before` | gdext/src/native_simulation_host.cpp:74；gdext/src/native_simulation_host.cpp:311；gdext/src/native_simulation_host.cpp:320；gdext/src/native_simulation_host.cpp:351（域名拼接） | 无效域回退；正常十二域不可达 | 未检索到显式名称 |
| `visual.plan.after` | gdext/src/native_simulation_host.cpp:74；gdext/src/native_simulation_host.cpp:311；gdext/src/native_simulation_host.cpp:320；gdext/src/native_simulation_host.cpp:351（域名拼接） | 域计划前/后；生产日图 | 未检索到显式名称 |
| `visual.plan.before` | gdext/src/native_simulation_host.cpp:74；gdext/src/native_simulation_host.cpp:311；gdext/src/native_simulation_host.cpp:320；gdext/src/native_simulation_host.cpp:351（域名拼接） | 域计划前/后；生产日图 | 未检索到显式名称 |
| `worker.inflight.before` | gdext/src/native_simulation_host_worker.cpp:513 | 同名提交/切换/保存/恢复边界；相应生产操作 | 未检索到显式名称 |

### GDScript 运行时环境入口（只盘点，未改）

下表涵盖日推进、AI配置、生成/开局诊断和运行时保存；音频、截图、UI样式和外部AI凭据不属于模拟入口。GDScript空环境值仍由OS返回空串；本轮没有把这些入口改接C++注册表。

| 名称 | 位置 | 默认 / 作用 / 生产可达 | 测试或工具引用例 |
| --- | --- | --- | --- |
| `PK_AUTOTEST_QUERY` | Project/project-keynes/scripts/game/web_autotest.gd:78 | 默认无注入查询；Web自动测试入口可达 | 未检索到显式名称 |
| `PK_BOOT_FACADE_AB` | Project/project-keynes/scripts/geography/map_generator.gd:10650 | 默认关；去空白后1启用开局对比；开局可达 | 未检索到显式名称 |
| `PK_BOOT_FACADE_DISABLE` | Project/project-keynes/scripts/geography/map_generator.gd:10655 | 默认关；去空白后1关闭开局facade；开局可达 | 未检索到显式名称 |
| `PK_COUNTRY_AI_CATALOG` | Project/project-keynes/scripts/country/country_ai_catalog.gd:113 | 空串采用默认资源；可覆盖国家AI目录；配置时可达 | tools/country_ai_tune/cmaes_tune.py:7；tools/country_ai_tune/cmaes_tune.py:206 |
| `PK_COUNTRY_AI_DIFFICULTY` | Project/project-keynes/scripts/country/country_ai_catalog.gd:132 | 未设沿用目录difficulty；接受easy/normal/hard；配置时可达 | 未检索到显式名称 |
| `PK_COUNTRY_AI_MODE` | Project/project-keynes/scripts/country/country_ai_catalog.gd:128 | 未设沿用目录mode；接受OFF/PROBE/ACTIVE；配置时可达 | tools/country_ai_tune/cmaes_tune.py:207 |
| `PK_DAY_COST_PROBE` | Project/project-keynes/scripts/geography/world_clock.gd:258 | 默认不由环境强制；1开启日耗时；可达 | 未检索到显式名称 |
| `PK_ECONOMY_FORCE_CADENCE` | Project/project-keynes/scripts/economy/economy_facade.gd:2005 | 空串不覆盖；逗号分隔强制节拍；配置时可达 | 未检索到显式名称 |
| `PK_FOG_OFF` | Project/project-keynes/scripts/game/world_runtime_host.gd:6824 | 默认雾正常；1隐藏雾；视野主线程可达 | 未检索到显式名称 |
| `PK_FORCE_MAPGEN_FAIL` | Project/project-keynes/scripts/geography/map_generator.gd:13471 | 默认关；1强制生成失败；生成可达 | 未检索到显式名称 |
| `PK_FORCE_WEB_SEMANTICS` | Project/project-keynes/scripts/game/world_runtime_host.gd:1630 | 默认关；1模拟Web判据；可达 | 未检索到显式名称 |
| `PK_MAPGEN_SELFCHECK` | Project/project-keynes/scripts/geography/map_generator.gd:13352 | 默认关；1运行生成自检；生成可达 | 未检索到显式名称 |
| `PK_MOBILE_NATIVE_WORKER` | Project/project-keynes/scripts/game/world_runtime_host.gd:1617 | 默认移动端内联；1恢复worker实验；可达 | 未检索到显式名称 |
| `PK_NATIVE_DAILY_INLINE` | Project/project-keynes/scripts/game/world_runtime_host.gd:1619 | 桌面默认不强制内联；移动/Web另有平台规则；可达 | 未检索到显式名称 |
| `PK_NO_ENV_PREFETCH` | Project/project-keynes/scripts/game/world_runtime_host.gd:1877；Project/project-keynes/scripts/game/world_runtime_host.gd:1912 | 默认允许预取；1关闭；可达 | 未检索到显式名称 |
| `PK_PREFETCH_DIAG` | Project/project-keynes/scripts/game/world_runtime_host.gd:2377；Project/project-keynes/scripts/game/world_runtime_host.gd:2414；Project/project-keynes/scripts/game/world_runtime_host.gd:2548 | 默认关；1打印预取诊断；可达 | 未检索到显式名称 |
| `PK_SAVE_DIR` | Project/project-keynes/scripts/game/save_repository.gd:26 | 空串用默认目录；保存仓库可达 | Project/project-keynes/tests/country/colonization_probe.gd:12；tools/ci/run_regression_checks.py:119 |
| `PK_SAVE_ECP2_REUSE_DISABLE` | Project/project-keynes/scripts/game/save_modules/economy_state.gd:15 | 默认允许复用；保存可达 | 未检索到显式名称 |
| `PK_SAVE_ECP2_REUSE_VERIFY` | Project/project-keynes/scripts/game/save_modules/economy_state.gd:16 | 默认不核对复用；保存可达 | 未检索到显式名称 |
| `PK_SAVE_MIGRATE` | Project/project-keynes/scripts/game/save_modules/clock_state.gd:17；Project/project-keynes/scripts/game/world_state_modules.gd:142 | 默认不允许旧格式迁移；恢复可达 | Project/project-keynes/tests/game/headless_save_replay.gd:87；tools/runtime/Invoke-SaveMigration.ps1:24 |
| `PK_SAVE_PROFILE` | Project/project-keynes/scripts/game/game_save_coordinator.gd:689 | 默认不打印耗时；保存可达 | 未检索到显式名称 |
| `PK_SAVE_PROVIDER_HASH_SYNC` | Project/project-keynes/scripts/game/game_save_coordinator.gd:365 | 默认不强制同步哈希；保存可达 | 未检索到显式名称 |
| `PK_SAVE_PROVIDER_HASH_VERIFY` | Project/project-keynes/scripts/game/game_save_coordinator.gd:690 | 默认不额外校验；保存可达 | 未检索到显式名称 |
| `PK_SAVE_SYNC_WRITE` | Project/project-keynes/scripts/game/game_save_coordinator.gd:363 | 默认不强制同步；保存可达 | 未检索到显式名称 |
| `PK_TECH_DELIVERY_DIAG` | Project/project-keynes/scripts/game/world_runtime_host.gd:3227 | 默认关；1打印科技交付诊断；可达 | 未检索到显式名称 |
| `PK_WEB_WORKER` | Project/project-keynes/scripts/game/world_runtime_host.gd:1649；Project/project-keynes/scripts/game/world_runtime_host.gd:1673；Project/project-keynes/scripts/game/world_runtime_host.gd:2443 | 未设沿用Engine meta/导出项/真实Web平台默认；0或1覆盖；可达 | 未检索到显式名称 |
| `PK_GAME_SAVE_ROUNDTRIP_TEST` | game_flow_service.gd:24,41 | 默认关；精确1时autoload挂载诊断节点，正式进程也可打开 | `res://tests/game/game_save_roundtrip_test.gd` |
| `PK_SAVE_REPLAY` | game_flow_service.gd:28,41 | 默认关；精确1时autoload挂载诊断节点，正式进程也可打开 | `res://tests/game/headless_save_replay.gd` |
| `PK_FAMILY_PROBE` | game_flow_service.gd:30,41 | 默认关；精确1时autoload挂载诊断节点，正式进程也可打开 | `res://tests/family/family_economy_probe.gd` |
| `PK_COLONIZATION_PROBE` | game_flow_service.gd:32,41 | 默认关；精确1时autoload挂载诊断节点，正式进程也可打开 | `res://tests/country/colonization_probe.gd` |
| `PK_AUTOPLAY_PROBE` | game_flow_service.gd:36,41 | 默认关；精确1时autoload挂载诊断节点，正式进程也可打开 | `res://tests/probes/_tmp_autoplay.gd` |

**未验证/推断**：没有运行所有环境覆盖组合；没有证明文本检查能识别任意宏/指针别名或外部环境注入。动态故障只接受既有域名生成形式，新生成形式必须明确扩展检查，不能在基线中无理由放行。Web同步回退产品决定仍待用户答复，本轮未删任何实现/配置入口。旧过程文档已清理，29份待决定文档未动。

### S7 最终实测结果

- 四次串行调试构建（transfers、research-spend、colonization、switches）均`done building targets`。仅验证macOS arm64 template_debug/dev_build=no，未构建Web/Android/release。
- 改前默认回归37/37，改后41/41；新增四项写入用例均通过，worker restart day在改前/改后均通过。财政续跑4项既存失败的独立用例本轮未另跑；没有改它的等待/断言。
- 最终主黄金10/10、独立v5 10/10，逐日逐域无分歧。下列五条末日链与S7起点完全相同；旧黄金脚本和JSON文件亦逐字节未变。
- 护栏833文件0违规，依赖433键/421债务键、header_exposed=522、total=2400，直接写2，表外登记7项，开关93项/135读取/46故障名/27调用且0例外，13项护栏测试通过。裸getenv和未登记故障名两个命令行反例均exit=1，删除反例后exit=0。
- 本轮未出现外部提交；HEAD仍为a712203f48663315620e9dc3dc6bd2fb2b3e1f49，暂存状态未变。没有删除代码/测试/旧实现/待决定文档。

| 链 | 末日值 |
| --- | --- |
| 账目 v1 | `2242b25110adb22d74a7ce175f8b6e0dce2ef2442741d3dc2a318efa8c7e28c2` |
| 整体经济 v2 | `30ea61f1e05f12b02d01ebe3aa1bf6060655e39663251100b4be8ae358db73d3` |
| 七域 v3 | `95aedaac2fd631d72657f0d27fbb04009d3ab489b577f3e7c59788ee25ab537a` |
| Country v4 | `6786a230e8f9b5859c0f9baa13eefd65ec89976e3d1fd119a5131df35a3e8fef` |
| 表外 v5 | `0f85a96f0e1a994ede564409e7e1bc5fdac282cbca2da42672da266f9b663c22` |

实际完整命令、每组日志与文件清单：`/tmp/keynes-arch-phase1/stage7/commands.md`、`verification-summary.json`、`change-manifest.md`。这是本机固定用例的证据，不代表跨平台或所有非默认开关组合的确定性。


## S8：host机械拆分与主线程按日实验

### 已验证：起点规模与拆分范围

下表为`check_size_ratchet.py`基线中行数最多的10个C++文件（含头文件）与5个GDScript，已逐文件核对实测值。只搬迁host；经济主文件、Godot正式脚本和其他大实现文件未修改。

| 文件（S8起点） | 基线/实测行数 | 主要关注点 |
| --- | ---: | --- |
| `gdext/src/economy_runtime.cpp` | 26688 / 26688 | 经济周期、资金/物资结算、国家交接、状态哈希与恢复 |
| `gdext/src/native_simulation_host.cpp` | 14888 / 14888 | 启动与控制、日计划、域桥接、资产协议、worker、保存与报告 |
| `gdext/src/country_runtime.cpp` | 11465 / 11465 | 国家/领土、科技、财政资产协议、命令与保存 |
| `gdext/src/economy_runtime.h` | 10240 / 10240 | 经济运行时接口、内部状态/表结构、阶段与保存声明 |
| `gdext/src/effect_runtime.cpp` | 8479 / 8479 | 效果目录与实例、计划/提交、意图回执与保存 |
| `gdext/src/ideology_runtime.cpp` | 8302 / 8302 | 卡牌/路线与观点、命令、派生指标及保存 |
| `gdext/src/world_ext_climate.cpp` | 6951 / 6951 | 气候各pass的Godot桥接、异步任务、输入捕获与回写 |
| `gdext/src/world_ext_generate.cpp` | 6303 / 6303 | 原生地图base/post-base生成、分阶段任务与结果装配 |
| `gdext/src/runtime_climate_passes.cpp` | 5615 / 5615 | 气候物理各pass、分片执行及诊断 |
| `gdext/src/economy_runtime_building_investment.cpp` | 5592 / 5592 | 建筑投资候选、需求、开业选择与资金可行性 |
| `Project/project-keynes/scripts/geography/map_generator.gd` | 22547 / 22547 | 地图生成、气候与资源pass、会话/原生桥接 |
| `Project/project-keynes/scripts/rendering/map_baker.gd` | 8588 / 8588 | 地图几何/物理场及纹理烘焙、分片与增量刷新 |
| `Project/project-keynes/scripts/game/world_runtime_host.gd` | 7368 / 7368 | 会话、主线程回写/追赶、日历服务和显示更新 |
| `Project/project-keynes/scripts/ui/cell_inspector_view_model.gd` | 7023 / 7023 | 地块面板的经济/国家/资源等查询与展示模型 |
| `Project/project-keynes/scripts/rendering/shrub_layer.gd` | 5940 / 5940 | 植被实例、分块、远近细节与材质参数 |

`native_simulation_host.cpp`由14888行降为480行，保留构造/控制快读、日模块表、故障状态与原有追踪入口；`native_simulation_host.h`原样不动。以下仍是同一个类的成员实现，没有迁移数据所有权或执行位置。

| 新文件（`gdext/src/`） | 行数 | 原有职责 |
| --- | ---: | --- |
| `native_simulation_host_journal.cpp` | 640 | 资产日志编码/恢复 |
| `native_simulation_host_persistence.cpp` | 1490 | 保存屏障、PKSR恢复与封装 |
| `native_simulation_host_report.cpp` | 802 | 线程/域/性能报告 |
| `native_simulation_host_startup.cpp` | 1114 | 启动、配置与初始权威准备 |
| `native_simulation_host_economy.cpp` | 926 | 经济权威切换、StageOps运行 |
| `native_simulation_host_country_assets.cpp` | 973 | 资产请求/回执/协议自测 |
| `native_simulation_host_asset_worker.cpp` | 412 | worker资产准备、提交与完成 |
| `native_simulation_host_country_boundary.cpp` | 1450 | Country快照、交接、参考对拍和命令自测 |
| `native_simulation_host_country_stage.cpp` | 880 | Country阶段执行 |
| `native_simulation_host_worker.cpp` | 1079 | 停止/时钟、停滞检查、worker循环 |
| `native_simulation_host_climate.cpp` | 362 | 环境发布、气候消费等待与对拍 |
| `native_simulation_host_ideology.cpp` | 1138 | 意识形态配置、参考/观点与阶段执行 |
| `native_simulation_host_trigger.cpp` | 312 | 触发器配置、保存、传输与阶段执行 |
| `native_simulation_host_effect.cpp` | 931 | 效果配置、传输与阶段执行 |
| `native_simulation_host_effect_tests.cpp` | 661 | 既有效果/适配自测 |
| `native_simulation_host_modifier.cpp` | 687 | 修改器映射/阶段执行及域快照消费 |
| `native_simulation_host_commands.cpp` | 880 | 命令队列、inline日运行与提交发布 |

另新增426行`native_simulation_host_support.h`，只放原匿名命名空间的无状态辅助函数，保持匿名链接并加inline；两个无状态写整数函数原样复制。带静态缓存的`peer_stall_fault_timeout_ms`与两个调用者一起进入worker文件，未复制缓存。

三组词元证据分别为`/tmp/keynes-arch-phase1/stage8/token-proof-group{1,2,3}.json`：208个成员定义的签名与函数体完全相同，37个辅助函数仅允许inline修饰和无状态副本，无遗漏/重复成员。`host-symbol-proof.json`核对二进制唯一导出`dots_ext_init`未变；二进制不暴露私有成员符号，不能用空nm列表声称完成成员符号证明。头文件逐字节相同及源码词元检查提供签名/可见性证据。

`gdext/SConstruct:92`的统一`Glob("src/*.cpp")`收集所有新文件；macOS `rebuild.sh`、Windows `rebuild.bat`/`tools/runtime/build_gdext.ps1`、Linux `.github/workflows/runtime-full-checks.yml`、Android `build_android.bat`、Web `build_web.bat`/`Build-Web.cmd`及web构建流程均调用同一SConstruct。没有平台单独的host源文件列表需要更新。只实跑macOS arm64调试构建；其他平台仅核查入口，不声称编译通过。

### 已验证：外围推进现状与实验契约

- `world_runtime_host.gd:3365`消费最新提交；`:3400`/`:3404`登记资源与军事目标日。提交信号与记录器先执行（`:3427`/`:3435`），然后资源回写/恢复（`:3450`），再军事（`:3464`）；不是对每个历史提交分别取得独立视图。
- 资源游标从0开始，每帧最多8日（`:38`、`:355`、`:3536`），失败不前移；先非阻塞消费经济资源回写。`map_generator.gd:11168`取得当前live cells，按逐格上次日期、live标记、荒野分桶计算dt（`:11175`–`:11255`），原生pass或脚本fallback后写资源列/MapData及逐格日期。气候、恢复Modifier和当前live cells均属于其输入，不能将历史日期参数等同于历史输入快照。
- 军事每帧最多4日（`world_runtime_host.gd:44`），首次观察从`min(target,max(0,target-4))`开始（`:3578`）；跳过日仍更新host游标。`military_facade.gd:228`调用`world_ext_military.cpp:1099`，捕获当前国家/经济摘要、结算回执、推进军事、发布口粮满意度并发送D+1命令（`:1166`），随后host转发事件。
- Host两个追赶游标为会话内状态，在`:1247`/`:1250`重置，未检索到保存模块直接序列化这两个字段。军事核心的最后日已保存（`military_core_save.cpp:283`），适配器的last_step_day也保存在封装中（`world_ext_military.cpp:3404`）；两者不可替换成新host游标。资源逐格日期在generator内维护，本轮未证明其保存恢复连续性。

**实验，非生产接入**：`tests/runtime/fixtures/day_aligned_external_host.gd`继承原Host，仅在注册的`PK_EXPERIMENT_EXTERNAL_DAY_ALIGNMENT`精确等于`1`时暂停两个逐帧drain；默认关闭。`golden_external_day_alignment_test.gd`等待同日worker空闲和Modifier回写后，在下一日提交前显式调用原两个drain，保持资源→军事、首次观察、跳过、事件转发规则。相邻日/目标日不满足则拒绝，不猜历史视图。原v5只新增创建Host的测试替换点；正式脚本不构造此子类，生产没有实验入口。开关仅追加注册项，既有枚举值、默认值和135处C++读取保持。

**框架决定（2026-11-05）**：日期对齐属于调度框架，不是玩法，目标如下。
- 资源和军事对每个日 D 恰好推进一次，读第 D 日已提交的输入，按资源 → 军事的固定顺序。不再跳日；首次观察从模块已保存的 last_step_day 接续，不再使用 `target-4`。
- 两者完成后，第 D 日才算完整：`simulation_committed` 和记录器在外围完成之后才可见。主线程在 D 提交和接纳 D+1 输入之间设确认屏障。
- 保存时先排空外围边界，不新增存档字段。
- 长期把两者收进原生日图，作为普通日模块。
- 对模块作者的契约是：“每日一次、当日输入”，不能依赖追赶或跳日。军事内部规则仍归军事设计方。

实施排在合并 upstream 之后。验收要求：5 条黄金链不变，另新增带兵、战争、多日积压的链和吞吐测量。

最小实验只验证v5的四个逐日边界；不能证明批量积压、带兵军费/战争、读档后首次观察、帧内信号可见性或高倍速吞吐。完整产品方案需在生产的D提交与D+1输入接纳之间建立主线程确认屏障，资源回写就绪后按固定顺序执行，确认前继续服务peer但不接纳下一日；再明确simulation_committed/记录器是在外围完成前还是完成后可见。保存时需选择排空外围边界还是记录可恢复游标；任何涉及保存格式或原命令接纳顺序的变化须另轮授权。本轮不切默认。


### S8-B 实验实测与建议

`/tmp/keynes-arch-phase1/stage8/alignment-corrected/summary.json`：关闭/开启各连续3次，全部4天、5类摘要及每日日链完全相同，末日均`0f85a96f0e1a994ede564409e7e1bc5fdac282cbca2da42672da266f9b663c22`，无首个状态分歧。开启模式的资源/军事游标依次从`[0,-1]→[1,1]`、`[1,1]→[2,2]`、`[2,2]→[3,3]`、`[3,3]→[4,4]`，每次worker_day_inflight=0；不是仅打开了开关但仍由旧逐帧入口执行。

最初试跑开启模式未取得摘要：实验错误地把回写缺少pending字段解释为true。`world_ext_economy.cpp:518`的成功结果可以没有pending，原Host在`:3455`以false为默认值。诊断日志`alignment-boundary-diagnostic.log`记录host_day=1、两个target=1、拒绝码experiment_writeback_not_ready；将测试默认值与原Host一致后完成上述六次比对。此失败是实验夹具错误，不是模拟状态分歧；原日志`alignment/`保留。

**建议**：此固定v5用例可在两种测试调度方式间等价切换；暂不建议切生产默认。仍须验证带兵/军费/战争、跨多日积压、保存恢复及D+1接纳屏障，测量同步完成外围工作的帧时长。需要用户决定提交信号/记录器是否等外围模块完成、保存时排空还是保存待办，以及是否接受减少worker领先量；本轮没有作这些产品选择。旧过程文档已清理，29份待决定文档未动。


### S8 最终本机验证

- 默认关闭实验：改前41/41、改后41/41，两个入口exit=0；主黄金最终10/10、独立v5最终10/10，五条链不变。每组拆分另有主黄金3轮＋v5 3轮通过，实验开/关各3轮通过；不是只检查末日值，还比较全部逐日字段。
- 静态护栏851文件0违规；依赖433引用键/421债务键、header_exposed=522、total=2400；Country直接写2；推进者7项；注册94开关/135处C++读取、46故障名/27调用，裸读取0，13项护栏测试通过。默认回归仍41项，没有增加实验耗时。
- 仅S8-A主文件行数额度收紧：14888→480，低于600后移除超限记录；193个成员搬迁，15个留在原文件。所有声明、193个搬迁成员和15个保留成员的词元证明均通过；其他大小/依赖基线未放宽。
- 4次成功串行macOS arm64调试构建；另保留首组缺少编码辅助函数的失败日志。未构建其他平台/发布版，未运行图形长跑。既存Modifier排除范围、worker等待窗口、财政续跑4项失败均未修；worker相关默认用例本轮改前/后通过，财政续跑独立用例未重跑。
- 完整命令与日志索引：`/tmp/keynes-arch-phase1/stage8/commands.md`；文件清单`change-manifest.md`，原函数/新位置映射`method-locations.json`，两模式实验`alignment-corrected/summary.json`。

| 链 | 未改变的末日值 |
| --- | --- |
| 账目 | `2242b25110adb22d74a7ce175f8b6e0dce2ef2442741d3dc2a318efa8c7e28c2` |
| v2 | `30ea61f1e05f12b02d01ebe3aa1bf6060655e39663251100b4be8ae358db73d3` |
| v3 | `95aedaac2fd631d72657f0d27fbb04009d3ab489b577f3e7c59788ee25ab537a` |
| v4 | `6786a230e8f9b5859c0f9baa13eefd65ec89976e3d1fd119a5131df35a3e8fef` |
| v5 | `0f85a96f0e1a994ede564409e7e1bc5fdac282cbca2da42672da266f9b663c22` |


## S9 经济实现拆分（已实现部分）

本轮仅机械搬迁 `NativeEconomyRuntime` 成员，未改经济头文件与任何 GDScript。`economy_runtime.cpp` **26688→16784行（减少9904行，37.1%）**；236个完整定义搬到21个新cpp，最大1084行。跨域函数及全域哈希等89个成员定义仍在主文件，主文件仍超限；不把本轮说成已经达到2000行或已经完成模块解耦。

为保留按文件冻结的依赖债务，本轮不迁移包含跨域类型/对象访问的函数，不复制其country/effect/modifier/trigger头引用，不扩大已允许的h→cpp移位规则。家庭相关局部函数仍由原经济类和状态所有者持有（lineage文件），不是另建家庭模块；真正涉及Family类型的债务引用留原处。依赖基线文件未修改。

| 新文件（gdext/src/，统一前缀economy_runtime_） | 行数 | 关注点 |
| --- | --- | --- |
| `population_audit.cpp` | 646 | 人口商人不变量、增量账目审计 |
| `fiscal_receipt_journal.cpp` | 280 | 财政终态日志、peer已提交副作用 |
| `owned_bridge.cpp` | 1084 | POD/公式OwnedState列绑定与账目捕获 |
| `environment_capture.cpp` | 479 | 环境输入、资源列镜像及采样 |
| `availability.cpp` | 208 | 生产/消费资格查询 |
| `satisfaction.cpp` | 565 | 满意度、发展度、定额查询 |
| `market_signals.cpp` | 544 | 市场信号索引与dirty处理 |
| `input_reserves.cpp` | 566 | 生产输入储备、维护/需求缓存 |
| `living_cost.cpp` | 514 | 劳动力信号、生活成本 |
| `pricing.cpp` | 370 | 价格压力、上限、调价及建筑条件 |
| `production_queries.cpp` | 376 | 产出/成本/本地商人收支查询 |
| `trade_scheduling.cpp` | 707 | 分片边界、贸易计划及采购因子 |
| `slice_execution.cpp` | 459 | 分片入口、故障/恢复诊断 |
| `lineage_queries.cpp` | 427 | 经济拥有的家庭资格/索引查询 |
| `lineage_metrics.cpp` | 321 | 经济拥有的家庭条件与资源指标 |
| `lineage_membership.cpp` | 140 | 经济拥有的家庭成员/分支局部操作 |
| `commit_execution.cpp` | 932 | 建筑/家庭提交、建筑计划调度 |
| `stage_drains.cpp` | 722 | 日stage调用及各drain |
| `person_commit.cpp` | 763 | 人物索引/提交、stage名称与算术探针 |
| `reset_state.cpp` | 678 | reset与哈希入口转发 |
| `committed_summaries.cpp` | 120 | 已提交格摘要与市场格范围 |

证据：`/tmp/keynes-arch-phase1/stage9/token-proof-group{1,2,3}.json`及`token-proof-groupfinal.json`比较325个成员定义（含重载）的完整签名/函数体词元，全部相同；236个搬迁定义的去除可逐字节重建当前主文件，见`residual-proof.json`，原宏访问器、全局popcount函数和executor类未改。只复制无状态匿名elapsed_ms/price_adjustment_reference辅助函数，未复制函数内静态缓存。所有成员的原/新位置见`method-locations.json`。这不是完整形式化行为证明，仍需下面实跑证据。

构建入口：`gdext/SConstruct:92`统一`Glob("src/*.cpp")`，新增文件自动进入同一平台分支；Windows `rebuild.bat`、Web `build_web.bat`、Android `build_android.bat`均在gdext调用该构建文件，Linux同一SConstruct直接选择platform。未改源文件列表；本轮只实跑macOS arm64 debug，未实跑其它平台。

头文件10240行、GDScript宿主7368行只读评估见[s9-split-plan.md](s9-split-plan.md)。S9前历史阶段表中的行号是当时验证位置；查本轮搬迁位置应使用上表及method-locations，不把旧行号当当前定义位置。

军事两处白名单保持2。当前collect入账与桥接扣款注释不一致，静态证据与两阶段设计见[module-boundaries.md](module-boundaries.md#s9-军事现金两阶段方案设计未实现)；没有把它擅改成新军费规则。既有worker路径另有同epoch peer处理，非零同步路径仍缺本轮动态证明。旧过程文档已清理，29份待决定文档未动。


### S9 实跑结果

macOS arm64 debug串行构建4次均通过（三组搬迁，另一次仅校正新文件名）。每组核心黄金3/3，最终命名完成后核心10/10、v5外围3/3，逐日与各基线一致；命名校正前另有10/10记录，未替代最终结果。默认回归**改前41/41、改后41/41**，均exit 0。前置护栏：872文件/0违规，依赖433键（421债务键）、header_exposed=522、total=2400，直接写2；推进者7；开关94/裸读取0；13个护栏测试通过。

五条末日链均未变化：

- ledger_chain: `2242b25110adb22d74a7ce175f8b6e0dce2ef2442741d3dc2a318efa8c7e28c2`
- whole_economy_chain: `30ea61f1e05f12b02d01ebe3aa1bf6060655e39663251100b4be8ae358db73d3`
- domain_chain: `95aedaac2fd631d72657f0d27fbb04009d3ab489b577f3e7c59788ee25ab537a`
- country_chain: `6786a230e8f9b5859c0f9baa13eefd65ec89976e3d1fd119a5131df35a3e8fef`
- external_chain: `0f85a96f0e1a994ede564409e7e1bc5fdac282cbca2da42672da266f9b663c22`

命令、完整输出与限制：`/tmp/keynes-arch-phase1/stage9/commands.md`、`verification-summary.json`、`before.log`、`after.log`、`final-names-golden/summary.json`、`final-external/summary.json`。没有修改任何黄金脚本或基线。未验证其它平台构建或所有游戏输入；不把固定用例等价说成全场景证明。worker restart等待窗口本轮前后均通过但未修；Modifier哈希排除问题仍在`economy_runtime.cpp:16768`附近，原样保留；财政续跑4项既存失败的独立用例本轮未重跑。


## S10：机械拆分与同步军饷动态证据

本节是 S10 的当前核实结果；此前阶段行号保留当时快照。本轮未改变公式、提交顺序、存档字节、头文件、公共入口或配置默认值。旧过程文档已清理，29 份待决定文档未动。

### 已实施：经济实现继续分文件（目标部分达到）

`economy_runtime.cpp` 16,784→15,783 行，减少1,001行，**未达到≤8,000**。搬出10个完整成员定义，另随建筑适配器搬出其类定义和execute；89个显式成员的签名/函数体词元集合一致，保留部分及宏访问器逐字节一致；`economy_runtime.h`仍10,240行且字节不变。证明在`/tmp/keynes-arch-phase1/stage10/token-proof-group2.json`和`residual-proof.json`。

| 新实现文件（gdext/src/） | 行数 | 归属与证据 |
| --- | --- | --- |
| economy_runtime_audit_boundary.cpp | 315 | 原NativeEconomyRuntime审计、Country只读视图、should_run和故障上下文；`:45,131,141,160,197,274` |
| economy_runtime_asset_peer_service.cpp | 367 | 原回执服务循环，包括回压与托管列处理；`:45` |
| economy_runtime_epoch_demand.cpp | 383 | 研究需求与旧额度列清理，连原`#if 0`代码一起保留；`:45,174` |
| economy_runtime_building_plan_adapter.cpp | 116 | 原NativeEconomyBuildingPlanExecutor类/execute和成员转发；`:45,97` |

不能因看到`_country_runtime`就认定需要完整Country类型：这次搬出的多处仅判空，其余使用既有`country_reads()`视图。其余79个成员逐个试算仍会产生新的按文件跨域债务键，详见module-boundaries.md中的清单；两个人物函数虽无显式跨域类型词，仍调用Modifier方法，需要新增对应include键。当前`check_cpp_deps.py:135`只支持h→cpp的`moved_from`，不支持cpp→cpp；本轮未放宽也未重写依赖基线。宏生成的资源列访问器与原文件内部辅助函数仍保留。

全部平台源收集沿用`gdext/SConstruct:92`的`Glob("src/*.cpp")`（以及components/systems/profiles子目录glob）；没有逐平台显式新文件清单。仅实际构建macOS arm64 template_debug/dev_build=no；不能据glob宣称其他平台已编译。

### 已验证缺陷：同步军饷的付款方没有净扣款

测试：`tests/runtime/military_fiscal_semantics_test.gd`＋测试专用`gdext/tests/military_fiscal_probe.cpp`。后者链接现有生产`.os`，不改其实现，也不加入生产源码glob；独立测试扩展及描述文件只写scratch。普通GDScript入口拒收opcode30/34（`economy_runtime_configuration.cpp:1517`），所以没有绕改它来制造一个“可用”入口。原生测试调用现有`apply_pod_command`→`apply_command`→同步军饷分支；未证明正式整图或Web玩家路径实际触发了该分支。

金额均为原始整数单位，只有一格、一支军队，没有贸易/家庭/其它资金持有者：

| 实际步骤 | 国库 | cohort现金 | 军队资金 | 三方合计 / 返回 |
| --- | ---: | ---: | ---: | --- |
| 开始 | 500000 | 1000000 | 0 | 1500000 |
| Country reserve12345提交 | 487655 | 1000000 | 0 | 返回12345；Country已扣款 |
| Country collect12345提交 | 500000 | 1000000 | 0 | 返回12345；国库已加回 |
| 实际military_collect_cash(12345) | 500000 | 1000000 | 0 | 返回12345，净扣款0 |
| 无效Country | 500000 | 1000000 | 0 | 返回0，无变化 |
| 临时耗尽国库后付款 | 0 | 1000000 | 0 | 返回0；测试用FISCAL_RETURN恢复原余额 |
| 实际opcode30入伍1人 | 500000 | 900000 | 100000 | 1500000，人口/资金转移一致 |
| 实际opcode34付款12345 | 500000 | 900000 | 112345 | **1512345，多12345** |

另通过现有Country公开事务接口逐步记录begin/prepared/commit/applied，预留未提交时不改现金；prepared=false取消释放777占用，国库仍500000；余额不足reserve1被拒绝。原生同步兼容调用本身立即完成两笔事务，没有一个可插入取消的跨调用预留对象。不要把Country取消测试说成军事跨日取消已覆盖。

原因有直接代码证据：`economy_runtime_military_view.cpp:316,319`连续调用reserve/collect；`country_runtime.cpp:7003`把FISCAL_COLLECT归入国库入账，`:7025`按该方向修改现金；`runtime_economy_army_personnel.cpp:673`再给军队funds/epoch_income增加返回额。Country每笔事务报告`conservation_ok=true`、ledger_failures=0，并不证明两域转账守恒。军事“扣军费/记非税支出”的注释与实际不符；这不仅是注释问题，同步原生付款分支产生了真实的现金增量。

最终专用测试exit=1，唯一失败断言是`native army pay conserves cash`，`money_delta=12345`。按停止条件，此条停在取证，**未修生产逻辑、未迁移两处白名单、未改断言迁就结果**。此诊断需显式构建/加载测试扩展，不加入默认绿色回归。现有v5仍是零军费场景，不能证明上述分支正确。完整步骤、失败入口和原始数值：`/tmp/keynes-arch-phase1/stage10/military-fiscal-final.log`、`military-trace.json`、`military-native-summary.json`。

推断/待决定：同步工资可评估复用既有TREASURY_SPEND来保证国库与接收方只转一次；D+1的SPEND_CASH还要明确其接收方/消耗口径，不能全局删collect了事。该修复会改变非零军费结果，需要另行批准；worker付款通道、完整征募/战争/存档/中断验证未开始。两阶段设计必须先确定正确净支出语义，再讨论持久预留。

### 已实施：宿主纯值函数提取

正式host 7,368→7,319行；新增被动`world_runtime_host_values.gd`（88行），9个原方法名保留转发。仅提取错误摘要、PackedFloat32Array统计、Image格式编号映射及6个GM参数/返回值构造函数；没有采样时间、发信号、访问World或GPU、消费回写或推进日期。body除`static`声明外与S10前完全相同。候选与排除原因见s9-split-plan.md。

独立旧实现保存在测试reference脚本，`world_runtime_host_values_test.gd`对比新helper和host转发，93项通过：空值、Unicode、NaN/Inf、抽样步长、大数组、默认参数、输入不变与数组/字典借用引用语义。没有用新实现与自己对比。

perf-validation是有独立project.godot/场景的另一份工程，其host4,739行、并非本工程7,368行文件的当前镜像；`Project/perf-validation/scenes/player_game.tscn:8`指向该工程自己的res路径。未在已检查的tools/gdext/.github中找到自动同步入口。按本轮约束保持逐字节不动；其独立运行和是否同步升级未验证，不能直接覆盖旧宿主。


### S10 最终本机验证记录

- 两组串行macOS arm64调试构建均exit0、`scons: done building targets`；每组核心黄金3/3；收尾核心10/10、外围v5 3/3，逐日字段和基线均一致。没有更新五条黄金基线。
- 默认回归改前41/41、改后42/42，均exit0；新增纯值测试93项通过，player_country_ui_smoke_test两次均通过（实际启动player_game、close_world和释放）。未做图形观感/截图验证。
- 护栏877文件0违规；依赖433引用键/421债务键、header_exposed522、total2400；Country直接写2；推进者7；开关94、C++读取135、故障名46/调用27、裸读取0；13项护栏测试通过。
- 军事专用诊断**exit1，1项守恒失败，净现金+12345**。没有因此修改生产逻辑或默认回归，未做完整军事玩家流程/worker军费验证。测试扩展最初因缺少类型定义include和独立SCons对象属性各失败一次，修正测试构建后通过；首个GDScript尝试被现有命令校验拒绝，未改接纳规则。原始失败日志保留。
- 仅行数基线两项收紧：economy_runtime.cpp 16784→15783，world_runtime_host.gd 7368→7319；依赖基线未改。新cpp最大383行，新helper88行，均低于各自上限。
- 未改economy_runtime.h、perf-validation宿主、旧实现、公共配置面；29份待决定文档仍在。HEAD仍a712203f48663315620e9dc3dc6bd2fb2b3e1f49；暂存状态相同，没有外部提交基线调整。既存Modifier范围、worker等待窗口、财政续跑4项失败未修；后者独立用例本轮未重跑。
- 证据：`/tmp/keynes-arch-phase1/stage10/commands.md`、`verification-summary.json`、`change-manifest.md`、`token-proof-group1.json`、`token-proof-group2.json`、`residual-proof.json`、`military-fiscal-final.log`。未构建Linux/Windows/Web/Android/release；glob收集检查不等于这些平台构建通过。

| 链 | 不变的末日值 |
| --- | --- |
| 账目 | `2242b25110adb22d74a7ce175f8b6e0dce2ef2442741d3dc2a318efa8c7e28c2` |
| v2 | `30ea61f1e05f12b02d01ebe3aa1bf6060655e39663251100b4be8ae358db73d3` |
| v3 | `95aedaac2fd631d72657f0d27fbb04009d3ab489b577f3e7c59788ee25ab537a` |
| v4 | `6786a230e8f9b5859c0f9baa13eefd65ec89976e3d1fd119a5131df35a3e8fef` |
| v5 | `0f85a96f0e1a994ede564409e7e1bc5fdac282cbca2da42672da266f9b663c22` |


## S11：同步军饷修复与拆分复核（2026-11-04）

**已验证事实**：先行评估见module-boundaries的S11-A（修改生产代码之前的副本在`stage11/assessment-before-fix.md`）。普通经济GDScript入口拒绝30/34；军事POD入口接受，整图Country权威路径应使用worker TREASURY_SPEND。同一原生测试能直接触达同步分支，但不能据此声称已在玩家整图中触发该分支。GM当前登记分发无军饷命令；玩家与AI可提交军事命令再经日推进产生付款请求。没有审计用户实际存档；历史错误钱若已进入余额，原格式不会自动识别或冲销。

**已实施**：仅`runtime_economy_army_personnel.cpp:675`同步付款改为Country端口完成一笔RESERVE，`:693`接收实际扣款后在原位置入军队账。Country拥有国库，Economy拥有军队资金；顺序仍为同步扣款后入账，不改worker路径。COLLECT原来给国库加回钱，而军队又增加同额；Country单笔检查都通过，并不能保证组合守恒。D+1维护/建造的旧`military_collect_cash`未动：其接收方/消耗口径尚未确定，不能把本次军饷修复扩大为修改全部共用调用。

专用红→绿证据：`stage11/military-red.log`退出1，4项失败（同一缺陷的金额/裁剪/空库表现）；`military-green.log`退出0，0失败。测试扩展链接真实生产对象；未新增正式绑定。原生八项金额/边界断言全通过，另有GDScript Country事务取消、无效句柄、空库断言；取消是事务层prepared拒绝，不是跨日军事取消。

| 原生调用阶段 | 修前 Country / 军队 / 全钱包总额 | 修后 Country / 军队 / 全钱包总额 |
| --- | --- | --- |
| 入伍完成（cohort资金900000） | 500000 / 100000 / 1500000 | 相同 |
| 支付12345 | 500000 / 112345 / 1512345 | 487655 / 112345 / 1500000 |
| 请求超过剩余国库100 | 500000 / 612345 / 2012345 | 0 / 600000 / 1500000 |
| 再请求1 | 500000 / 612346 / 2012346，仍成功 | 0 / 600000 / 1500000，拒绝 |

修前修后Country单笔ledger_failures都为0；独立钱包合计才捕获组合造钱。未结算的money_error不作为此表依据。修复不会回溯旧余额；没有改变任何保存读写代码/字段布局，修复后非零军饷余额与少一笔collect历史不同是预期行为纠错，不能声称错误轨迹和正确轨迹的保存内容逐字节相同。

**S11-B核实**：`economy_runtime.cpp`仍15783行，头10240行，79个显式成员。S10已搬完只判空批次；当前没有新的合格项。`country_reads:2128`仍依赖完整Country工厂；两个无显式跨域类型名的人物方法在14700/14729调用Modifier。保留逐函数新键清单（最低167键）；重载508/524定位分开。主文件和头本轮逐字节未改，无需伪造一次机械拆分或放宽基线。

**仍未知/未验证**：所有混合权威配置的非零军饷、worker非零付款端到端、跨日军事取消/崩溃恢复、用户存档是否含历史增量。持久两阶段预留未开始；D+1维护口径待定。既存Modifier哈希排除范围、worker restart等待窗口、财政续跑4项历史失败不在本轮修复范围。旧过程文档已清理，29份待决定文档未动。


### S11 已取得的黄金与构建证据

生产macOS arm64 template_debug构建通过（build-fix-retry.log）；首次构建缺Variant完整定义，补include与godot::String限定后通过，未改变接口。测试库红/绿两次构建通过。核心`--runs 10`为10/10，外围`--external-only --runs 3`为3/3，均退出0且无逐日分歧；没有更新黄金基线。命令完整路径见`/tmp/keynes-arch-phase1/stage11/commands.md`。

| 链 | 末日值（与S10逐位相同） |
| --- | --- |
| 账目 | `2242b25110adb22d74a7ce175f8b6e0dce2ef2442741d3dc2a318efa8c7e28c2` |
| v2 | `30ea61f1e05f12b02d01ebe3aa1bf6060655e39663251100b4be8ae358db73d3` |
| v3 | `95aedaac2fd631d72657f0d27fbb04009d3ab489b577f3e7c59788ee25ab537a` |
| v4 | `6786a230e8f9b5859c0f9baa13eefd65ec89976e3d1fd119a5131df35a3e8fef` |
| v5 | `0f85a96f0e1a994ede564409e7e1bc5fdac282cbca2da42672da266f9b663c22` |

未做release或其它平台构建。121个头文件以及保存读写实现与S11开始副本逐字节相同；生产唯一修改为runtime_economy_army_personnel.cpp（1387→1407）。主经济文件与头未改，既有依赖额度不变。


### S11 最终回归证据

`run_regression_checks.py --godot /opt/homebrew/bin/godot`改前默认 **42/42**，改后同一默认清单 **42/42**；改后另加`--military-fiscal-probe /tmp/keynes-arch-phase1/stage11/military_fiscal_probe.gdextension`的专用用例 **1/1**，总计43/43，两个回归进程都退出0。`economy_worker_restart_day_test`两次均16 checks / 0 failures；财政续跑历史4失败用例本轮未重跑，不能写成已修复。

护栏：877文件零超限增长，433引用键/421债务键、header_exposed=522、total=2400，Country直接写2，推进者7，开关94/裸读0，13护栏测试通过；数值基线没有放宽。核心十次和外围三次五链不变（上表/`stage11/chains.json`）。完整命令、初次编译缺头的失败及修正、红绿逐步余额、范围证明见`/tmp/keynes-arch-phase1/stage11/commands.md`、`verification-summary.json`、`source-scope-proof.json`。HEAD未变化，未commit/git add/还原工作区。已追踪macOS debug dylib由构建更新并保留，测试dylib仅在scratch。


## S12：维护费核查、受控搬迁与表现适配（2026-11-04）

### 已验证事实

- `military_collect_cash` 生产调用只剩 `world_ext_military.cpp:1767`，入口为 `run_military_daily:1132` → `apply_military_deferred_cash:1750`。声明与测试调用不算第二个生产入口。helper在 `economy_runtime_military_view.cpp:309–320` 完成reserve扣款后再collect入账；没有军队入账。
- 两种来源共用这个入口：`military_core.cpp:2343` 的五日维护费，以及 `:3322` 的建筑材料估价。后者在 `:2927` 明说实际材料结算属于经济，通知仅维护军事财政记录。因此不能把所有SPEND_CASH盲目改成扣款。
- 独立测试通过真实 `submit_military_commands(state.build)`、`run_military_daily` 运行0..6日：第0日材料通知→第1日1条回执；第5日维护费记录50000→第6日1条回执；国库各日500000。原生helper在足额、重复、零额、无效国家、余额777不足请求12345、空库六种情况均返回预期额度且钱包合计不变。事务取消仍走原有prepared=false检查。证据：`tests/runtime/military_fiscal_semantics_test.gd`、`gdext/tests/military_fiscal_probe.cpp`；测试库不进入生产glob。
- 这不是S11的军队造钱：当前是**显示已付款但净支出为零**。维护费接收方/销毁口径尚未确定，本轮不修生产资金逻辑、不新增行为开关。不能称为“修复红→绿”；S11的付款守恒断言继续保留，新增的是现状钱流与边界断言。
- worker军饷只读核查：`runtime_economy_army_personnel.cpp:719` 使用带军队handle的TREASURY_SPEND；`native_simulation_host_asset_worker.cpp:342,392` 在同一worker窗口准备、消费peer、终结并发布Country；`country_core_apply.cpp:1155` 扣国库，`economy_runtime_fiscal_receipt_journal.cpp:240–268` 给军队等额入账，成功路径无collect加回。未新增完整worker非零军饷动态夹具，不把静态核查称为全失败路径守恒证明。

### 已实施的机械拆分

`economy_runtime.cpp` 15783→7989行，79个显式成员搬走60个、剩19个；8个新cpp各≤2000行。既有procurement/building_commit/fiscal分别承接采购续跑、修饰因素刷新、工资税务，最终1835/1072/1981行。整组925个经济成员签名及函数体词元逐项一致，`economy_runtime.h` 10240行逐字节不变。辅助计时/换算函数只原样复制到匿名命名空间；没有新公共符号。证明见`stage12/token-proof-final.json`；剩余成员见module-boundaries的S12表。

依赖规则现仅额外允许同目录 `economy_runtime*.cpp` 内的显式搬迁：同一个域对/符号的源计数必须同步减少，每份减少额度只能使用一次，total/header_exposed不增加；没有新域对。每个增长键在基线记录moved_from与前后计数。433→457文件引用键（421→445债务键）是搬迁位置拆开，header_exposed=522、total=2400均未增。不是允许任意新引用。新增正反例连同旧13项检查共14项通过。

### 表现边界

新增 `world_runtime_overlay.gd` 与 `world_runtime_presentation.gd`，9个原方法体逐字节搬迁；host保留同名转发、唯一_process、信号与所有await取消检查，270个其它方法体不变。两处会话释放方法新增显式解绑，缓存/渲染引用不进入模拟状态或存档。host 7319→7179行。`tests/game/world_runtime_presentation_test.gd` 使用冻结的旧实现对照，84项覆盖请求合并/清空、刷新间隔、渲染调用次序、fog/全量刷新/失败、资料缓存与引用释放；不含真实GPU烘焙图像比较。

昼夜预览仍留host：它会hold/release视觉时钟，且依赖渲染器状态；本轮没有足够的图形及时钟交互对照证明，不把这部分称为已迁移。视野pass、军事/资源位置不动。perf-validation副本逐字节不变。截图、显示效果以及非macOS平台实际构建未验证。

旧过程文档已清理，29份待决定未动；Web同步回退、Modifier哈希排除范围、worker等待窗口和财政续跑4项既存问题未改。

### S12 最终实跑证据

- 两组机械搬迁分别构建通过、核心黄金各3/3；第二组首次缺少Clock/elapsed_ms的4条编译错误，原样补入匿名辅助函数后构建通过，失败日志保留。最终macOS arm64 debug及独立probe均构建通过。所有平台仍由`gdext/SConstruct:93`的Glob收集，无源列表修改；未实际构建Linux/Windows/Web/Android/release。
- 收尾核心10/10、独立v5 3/3全部逐日字段与基线一致；没有改任何黄金脚本或基线。925成员词元一致、主文件删除60成员后的剩余文本逐字节相同，头文件不变。
- 默认回归42/42→43/43，另加军事probe1/1；player_country_ui_smoke实际加载player_game并关闭，resource/worker lifetime与loading exit均通过。表现对照84项通过；最终军事加强为10格全部cohort合计，仍0失败：D+1各日国库500000、cohort合计9500000、占用0，维护记录50000有回执但无现金支出。
- **额外native_loading_tasks_test未通过**：当前库和S12前库（隔离项目/原host）均退出1、同样2项失败。`loading_catalog_cache.gd:66–71`因快照源指纹不匹配而保持未就绪，测试仍要求返回缓存。939条清单中的相同4项改前/改后不匹配：climate_profile.gd、economy_test_bootstrap.gd、starter_settlement_bootstrap.gd、modifier_catalog.gd；本轮未动这4项。没有重烘或修改断言。证据`native-loading-pre-s12.log`、`native_loading_tasks_test.log`、`loading-manifest-differences.json`，不能称所有加载测试全绿。
- 静态护栏887文件0违规，457引用键/445债务键、header_exposed522/total2400、直接写2、推进者7、开关94/裸读取0；14项护栏测试通过。基线只收紧经济主文件和正式host，未调整外部提交额度。HEAD未变，暂存状态未变。
- 早期测试开发中出现Variant推断警告及误搬Web心跳字段引发的解析错误，已分别显式类型标注、把原声明及注释放回host；最终对照、黄金与回归均无解析错误。没有把这些失败日志当通过证据。
- 财政续跑4项既存失败独立用例本轮未重跑；Modifier范围、worker等待窗口未修。无图形截图/真实GPU输出一致性证明；昼夜预览保留。完整命令、清单和结果位于`/tmp/keynes-arch-phase1/stage12/commands.md`、`change-manifest.md`、`verification-summary.json`。

| 链 | 本轮不变的末日值 |
| --- | --- |
| ledger_chain | `2242b25110adb22d74a7ce175f8b6e0dce2ef2442741d3dc2a318efa8c7e28c2` |
| whole_economy_chain | `30ea61f1e05f12b02d01ebe3aa1bf6060655e39663251100b4be8ae358db73d3` |
| domain_chain | `95aedaac2fd631d72657f0d27fbb04009d3ab489b577f3e7c59788ee25ab537a` |
| country_chain | `6786a230e8f9b5859c0f9baa13eefd65ec89976e3d1fd119a5131df35a3e8fef` |
| external_chain | `0f85a96f0e1a994ede564409e7e1bc5fdac282cbca2da42672da266f9b663c22` |

## S13：Web 失败边界与被动命令适配

本节是 S13 当前结论；前面各轮状态/行号是当轮记录，不把历史“等待决定”当作本轮状态。旧过程文档已清理，29 份待决定未动。D+1 维护费收款方/销毁/只统计仍待用户决定，本轮未改。

### 已验证代码事实：Web 回退

| 入口与触发者 | 原行为及桌面可达性 | S13 Web 默认行为 / 证据 |
| --- | --- | --- |
| 两种执行器均未请求：脚本/导出项关闭 inline，并用 `?worker=0`、环境值0或`pk_web_worker=false`元数据关闭 worker | 原先直接 return，由 host SUS 日推进；该双关闭早退只在 Web 生效，桌面仍走原启动流程 | `web_native_executor_not_requested`；`Project/project-keynes/scripts/game/world_runtime_host.gd:1761` |
| 气候策略关闭：session request=false、FORCE_OFF、或显式正阈值下的小地图；默认 AUTO 无正阈值保持开启 | Web直接return；桌面允许SHADOW＋同步权威，保持原行为 | `web_climate_authority_disabled`；`Project/project-keynes/scripts/game/world_runtime_host.gd:1774`；`scripts/game/climate_authority_policy.gd:76` |
| side module缺失真正日推进API / 启动失败最终无可用执行器 | inline缺API会清active标记，下一日可能走SUS；桌面亦有该兼容分支，本轮不改它 | `web_native_daily_api_missing`、`web_native_start_failed`；`Project/project-keynes/scripts/game/world_runtime_host.gd:559`、`Project/project-keynes/scripts/game/world_runtime_host.gd:1898` |
| 关闭原生启动、无启动接口、Country捕获失败、inline回报标志不符 | 都可留下无执行器的会话；桌面的旧返回/日志保持 | 同一Web失败通道，防止绕过前三个门；`Project/project-keynes/scripts/game/world_runtime_host.gd:1742` |

**纠正旧前提**：真实 Web 当前默认请求 worker（`_web_worker_requested` 最终返回 `OS.has_feature("web")`），不是默认 inline。`web_autotest.gd:207`可通过URL worker参数覆盖；关闭worker且允许inline才选inline。缺少环境预发布API仍先转**原生inline**，它不是脚本回退，保留原行为（`Project/project-keynes/scripts/game/world_runtime_host.gd:1793`）。这轮没有把worker默认切走；“Web只留inline”的默认选择若要实施需另一个有浏览器验证的切片。

脚本路径并非只动日历：`map_generator.gd:8652`的`sus_tick_daily`（函数名为`sus_tick_daily`）捕获环境、执行SUS、推进原生图及分片继续；`Project/project-keynes/scripts/game/world_runtime_host.gd:2026`继续处理Country/Effect等回执、显示与年报。可用的同步系统能真正改状态，不能仅据旧注释称它必定无效；旧模块缺哪些API决定实际缺失范围，**完整世界与ACTIVE等价性未验证**。

逃生键 `PK_WEB_ALLOW_GDSCRIPT_DAILY_FALLBACK` 仅精确字符串`1`有效；或者在导出场景/会话启动前将 host 导出属性 `runtime_web_allow_gdscript_daily_fallback=true`。两者取OR，默认均关闭。选择属性是因为浏览器不能保证提供环境变量；不新增URL解析、公共原生绑定或新UI。注册元数据：`gdext/src/runtime_switch_registry.cpp:102`。这是一项脚本端消费的行为开关，不是假装已有C++读取调用。

失败设置`_web_worker_start_code`、`_runtime_last_fault_diagnostics.fault_code`并锁住WorldClock，发`web_daily_executor_failed`遥测，再复用`_emit_world_generation_failure`和`player_game.gd:236`的加载失败面板。加载准备返回失败，不能随后发world_ready；运行中原生日接口缺失也走同一面板，后续日回调/公开tick被阻断。新会话在旧会话完整关闭后只清除本通道的锁，不清除native故障（`Project/project-keynes/scripts/game/world_runtime_host.gd:1686`）。既有C++故障状态没有被伪造写入，host诊断明确标`source=web_daily_executor`。

### 第2步范围决定（2026-11-05）

Web 正式执行器定为“worker ＋ 原生 inline”：worker 仍是默认；inline 作为兼容路径保留，因为它不依赖 worker，代价是重日在主线程上卡顿。GDScript 每日回退和配套逃生开关在第 2 步删除，因为它和 ACTIVE 路径的完整世界等价性从未验证，相当于另一套规则。删除前须满足两项：下列测试先迁离同步/SHADOW 配置，并有一次 emcc 构建的真实浏览器验证。这是工程范围决定，不改变玩法规则。

### 第2步删除前必须复核的依赖

以下是实际源码调用/配置依赖，**本轮未删除或迁移**，并不表示每个都依赖Web：

- 同步/SHADOW配置：`tests/runtime/runtime_country_parity_test.gd:224`、`runtime_climate_save_roundtrip_test.gd:88`、`runtime_ideology_parity_test.gd:79`、`runtime_ideology_parity_guard_test.gd:184`、`tests/world/climate_parity_probe.gd:90`。
- Ideology固定或矩阵配置：`tests/probes/_probe_ideology_shadow_driver.gd:51`、`_probe_ideology_worker_loop.gd:55`；`tests/ideology/ideology_colonization_passable_probe.gd:46`、`ideology_colonization_gate_probe.gd:56`、`ideology_cell_layer_realworld_over32_test.gd:143`、`ideology_cell_layer_e2e_realworld_test.gd:83`、`ideology_d4_multi_cell_country_test.gd:76`；`ideology_worker_authority_parity_test.gd:898`、`ideology_worker_derived_pump_test.gd:668`、`ideology_save_worker_authority_test.gd:1574`按用例设置authority。`ideology_card_content_worker_test.gd`中的SHADOW说明是调查线索，不单凭注释判可删。
- `tests/ui/annual_report_runtime_test.gd:19,27`的`sync`模式；`tests/game/headless_perf_record.gd:165`的`climate_authority=off`。相关`tools/runtime/Invoke-AuthorityStageCHeadless.ps1`、`Invoke-AuthorityStageCClient.ps1`仍区分OFF/SHADOW测量口径。
- 新`web_daily_fallback_test.gd`与冻结的`world_runtime_web_reference.gd`覆盖逃生兼容；公开绑定/GM气候策略依然存在。全仓搜索清单保存在`/tmp/keynes-arch-phase1/stage13/fallback-test-locations.txt`，不能据这份有限关键词检索声称所有动态调用已穷尽。

### GM与录制器

`world_runtime_gm_commands.gd`接入6项原GM规格/校验/换算/提交组装；只接收每次调用的generator与窄Callable，不留host引用。日默认值、序号递增、暂停/故障门、拒绝转译及信号均留在`Project/project-keynes/scripts/game/world_runtime_host.gd:4411`。resolver仍延迟到原调用位置，显式country参数也保留原`Dictionary.get`默认表达式求值次序。

`world_runtime_recorders.gd`封装可录制判定、状态读取、样本交付、tile/economy回执字段。host仍持有recorder引用，组件无状态、无_process、无持久资源引用；时钟采样、所有统计读取/清零、调用次序仍留在`Project/project-keynes/scripts/game/world_runtime_host.gd:5603`。年度报告服务及其提交/发奖时点不动。实际耗时不会逐位相同；固定输入的请求、回执、行内容/CSV格式是本次等价比较对象。

已验证：`token-proof.json`记录269个host方法未变、13个提取/复用方法体词元相同；展开录制器转发后原采样方法词元相同。固定输入对照`world_runtime_commands_test.gd`364项通过（11种Country/Economy请求、默认/指定日、拒绝、错误参数、故障/未就绪、CSV及年报转发）；`annual_report_test`与三类recorder既有测试通过。年报固定数据转发对照不等于实跑一年奖励；完整年度场景未跑。host行数7179→7087；新组件分别196/41行（以本轮文件测量为准）。

额外旧`gm_runtime_host_test`失败：`autosave disabled advances year marker without writing`及退出泄漏。用S13前host＋S13前动态库的隔离项目复跑同样失败。`game_save_coordinator.gd:1082`先检查有效会话，旧测试未绑定有效会话就期待`_last_autosave_year=5`；这是本轮发现的既存用例契约差异，不改保存逻辑/测试。证据`stage13/focused/gm_runtime_host_test.log`与`stage13/pre-gm.log`。

真实浏览器、Wasm导出、遥测网络送达及失败面板图形观感**未验证**；headless测试使用已有虚方法覆盖Web判断，执行真实失败/信号/时钟逻辑，对期望push_error仅在测试内临时关闭错误打印。没有测试专用生产默认。

### S13 最终实跑证据

日志根 `/tmp/keynes-arch-phase1/stage13/`；完整命令见其中`commands.md`，汇总见`verification-summary.json`。

- macOS arm64 template_debug串行构建1次，exit0、`scons: done building targets`。
- 默认回归：改前43/43，改后45/45，均exit0；player_country_ui_smoke、loading/resource lifetime、worker restart均通过。
- 新Web对照149项、命令/录制对照364项，0失败；C++开关95（94+1）、裸读取0；棘轮889文件0违规，依赖457键/header522/total2400、直接写2，推进者7，护栏单测14项通过。
- 核心黄金`--runs 10`：10/10；外围`--external-only --runs 3`：3/3，逐日基线相同、first_difference=None。旧黄金脚本/基线未更新。
- 额外旧用例：年报、perf/economy/tile录制4项通过；旧gm_runtime_host_test失败（自动保存无有效会话断言＋退出泄漏），改前隔离复现相同；不能合称全部额外用例通过。
- `emcc`/`emcmake`不在当前PATH（which exit1），未准备新的Web side module、未验证真实浏览器/图形面板/网络遥测；未跑完整年度场景和release。

五条末日链保持：

- ledger: `2242b25110adb22d74a7ce175f8b6e0dce2ef2442741d3dc2a318efa8c7e28c2`
- v2: `30ea61f1e05f12b02d01ebe3aa1bf6060655e39663251100b4be8ae358db73d3`
- v3: `95aedaac2fd631d72657f0d27fbb04009d3ab489b577f3e7c59788ee25ab537a`
- v4: `6786a230e8f9b5859c0f9baa13eefd65ec89976e3d1fd119a5131df35a3e8fef`
- v5: `0f85a96f0e1a994ede564409e7e1bc5fdac282cbca2da42672da266f9b663c22`

范围核对：无暂存区变化、无外部HEAD变化（a712203f）、无删除；仅host行数基线7179→7087收紧；perf-validation副本相同，29份待决定未动。已追踪debug动态库受构建影响，未还原。


## S14：已提交气候读边、Modifier适配及保存续跑

### 已实施事实

- 选择Climate→Economy的当日环境读边，因为原来已在气候commit后读取，已有主黄金覆盖；不是借用CountryReadView的另一层别名。`native_simulation_stage_economy.cpp:134`调用所有者`copy_committed_view`，返回`RuntimeClimateCommittedView`（`runtime_climate_committed_view.h:9`）：独立vector、generation、day、committed，无store指针。8个float列与天气/覆盖/可选地形/植被原值复制，旧形状条件原样保留；消费时move进原`RuntimeEconomyDayInput`，不改变取值日或提交顺序。
- 所有者在`runtime_climate_authority.cpp:445`完整swap后发布；新factory只读`_store`，debug断言没有待提交plan。消费者在`native_simulation_stage_economy.cpp:137`断言代数/日期不倒退，允许同一提交重复读取；游标在owner reset/成功restore时重置，不进存档。断言关闭时不执行observe，无新增扫描或哈希；新增副本替代原列拷贝，不增加一套生产持久状态。它是执行线程内的即时只读投影，不是可在并发commit时任意获取的跨线程API。
- `check_committed_views.py`禁止这个stage恢复store/planned_store/snapshot绕行，要求消费版本断言。真实旧语句反例exit1，删除后exit0；别名、成员指针、移除断言有单元反例。文本检查不能替代C++完整访问控制。
- `world_runtime_modifier_writeback.gd:5`只抽Modifier回写。host四处调用位置仍在`:771,846,2052,2706`，`:2899`保留原名字转发；generation仍归host。组件无持久资源、await、信号或跨域ACK。冻结旧实现对照112项通过，包含授权/失败/相同及倒退generation、控制查询与消费顺序。host7087→7074；perf-validation副本未动。

### 已验证与未通过，严格分开

非空日志`tests/runtime/committed_view_commands.json`记录四日军事target=2/3/4/5；`committed_view_replay_test.gd`逐日读取八域、整体经济、军事与资源摘要。`check_committed_replay.py`先比较独立进程重放，再可选做保存/读档实验，不写任何旧基线。该日志验证政策变化，不声称覆盖非零军费。

- 同日志original/replay完全一致；checkpoint模式在提交日2存档，继续到日4也与不中断相同。
- **保存后重新载入的续跑不一致，按停止条件停此项**：首个采样差异为日3 `domains.CLIMATE.hash`，`8506758247628532623 → 9206377192278548470`。整体经济为`3695777885834853347 → 7629283173490331547`；Economy/Events/Ideology/Trigger投影、资源与军事部分报价也不同，不能只排除Climate后声称成功。
- 用S14前动态库和原host组成scratch隔离项目，四种模式逐日结果与改后**完全相同**，首差异相同，确认不是本轮引入。日志`/tmp/keynes-arch-phase1/stage14/{replay,pre-replay}/summary.json`，逐项对比`pre-post-replay-comparison.json`。
- **线索而非最终根因**：驱动`starter_settlement_soak_test.gd:154`在提交日2时将clock置为3；存档头day=3。读档后host准备阶段捕获day3（`world_runtime_host.gd:1469`附近），`map_generator.gd:2803,2832`按clock取日并缓存；正常续跑day3从callsite2捕获，恢复后则callsite0预捕获、callsite2命中缓存。日志中恢复day3没有对应weather_solve，日4才恢复。尚未区分全部差异来自输入准备时点、恢复缓存还是未持久化继续态；不改驱动日期或剔除字段来隐藏它。后续应先评审正式时钟/提交边界契约。
- 版本测试通过现有`runtime_climate_authority_self_test`：真实owner plan→discard→同日retry→commit、旧视图数据不受新commit影响、相同版本可重读、倒退/在途元数据拒绝、CLM2恢复后下一日相同。它是所有者级模拟等待/重试，不是对任意worker调度的穷尽证明；真实worker等待/重启仍由默认回归和黄金覆盖。

存档分段评审见[s14-save-sections-review.md](s14-save-sections-review.md)，仅设计；没有改字节、ABI或economy_runtime.h。当前Web默认worker已由代码与用户复核，旧inline描述不作为默认依据；真实Web需用户在有emcc的机器上验证，回退删除第2步未开始。D+1维护费语义未动。旧过程文档已清理，29份待决定未动。

补充字节证据：改前/改后本用例21个顶层片段中20个SHA相同，world_clock只差现有_ready随机化产生的rng_seed/rng_state（解码证据见stage14/clock-byte-differences.json）；不宣称整档相同。该四日驱动没有年度随机漂移，所有实际采样轨迹在改前/改后逐位相同。正式金样须固定时钟RNG初态，不能用本用例替代完整存档兼容认证。


### S14 最终验证记录

macOS arm64 debug串行构建最终exit0；首批核心3/3、收尾核心10/10、v5 3/3均匹配既有基线。默认改前45/45、改后47/47，均exit0。护栏892文件0违规、457引用键/445债务键、header_exposed522/total2400、直接Country写2、外围7、开关95/裸读取0、视图1条零违规；15项护栏单测通过。Modifier冻结对照112项；其余285个host方法逐字节不变。默认包括玩家场景、worker restart/stop、资源/加载生命周期与保存相关检查；非默认历史失败未重测。本轮没有真实Web或其他平台图形验证。

完整命令/失败日志与修正记录：`/tmp/keynes-arch-phase1/stage14/commands.md`；汇总`verification-summary.json`。保存续跑诊断exit1是已确认的既存差异，仍未通过，不计入默认47项通过。

- ledger_chain: `2242b25110adb22d74a7ce175f8b6e0dce2ef2442741d3dc2a318efa8c7e28c2`
- whole_economy_chain: `30ea61f1e05f12b02d01ebe3aa1bf6060655e39663251100b4be8ae358db73d3`
- domain_chain: `95aedaac2fd631d72657f0d27fbb04009d3ab489b577f3e7c59788ee25ab537a`
- country_chain: `6786a230e8f9b5859c0f9baa13eefd65ec89976e3d1fd119a5131df35a3e8fef`
- external_chain: `0f85a96f0e1a994ede564409e7e1bc5fdac282cbca2da42672da266f9b663c22`

Modifier原生消费仍在`world_ext_modifier.cpp:1167`：`:1188`取得日边界锁、`:1200`取ring、`:1211`释放slot后`:1224`应用副本。这些原生方法本轮逐字节未改，未新增跨域ACK；脚本对照记录control/consume，native slot释放顺序由未变源码及默认生命周期回归共同举证。


## S15：保存后气候分叉，已定位；未修保存内容

**已验证事实，2026-11-04。** 使用正式S14库/正式工程，第2提交日保存（时钟头为第3日），继续第3/4日。独立original/replay相同、checkpoint不中断相同、resume不同。S15没有修改生产C++/GDScript、存档或黄金基线；下面的强制补值只在`/tmp/keynes-arch-phase1/stage15/experiment-project`与独立诊断库发生，不是交付的修复。

### 因果链及分组对照

1. **恢复输入先错。** `world_runtime_host.gd:1470`在`:1498`启动worker之前预捕获。`map_generator.gd:2989,3019`按当时report的`climate_worker_authoritative=false`组装；`:5562`与`:5423`分别返回空round参数、空stage参数；`:2832`随后复用同日缓存。正常第3日season为0.043836，恢复round退为0；physics/weather阶段参数也缺失。这是(a)类初始化边界问题，但不是唯一根因。
2. **输入字典全部替换仍不够。** 连续运行第3日Climate=`8506758247628532623`，原恢复=`9206377192278548470`；只补flag=`12227590439717750260`；flag+round=`14661699158410136606`；flag+stage=`10695232319675273992`；三者=`18260941893396135031`；完整捕获字典=`18324236529660543188`。`fill_climate_round_input`仍从native slots读列（`world_ext_climate.cpp:6302`），不能把字典相同当全部输入相同。
3. **土壤列定位到计算。** 全字典对齐后，round实际输入只剩soil/insolation两列组和未使用的season镜像不同。`runtime_climate_kernel.cpp:886,1400`连续运行读取上一日distribute scratch；恢复没有它，读到旧slot。Pass A在`runtime_climate_passes.cpp:84,158`使用soil参与湿度计算。再把土壤slot换为连续运行值，round的温湿/积雪等分组hash恢复一致，首差异移到weather。第83格存档soil=0，而连续下一日输入为-0.0008911321638152。
4. **天气初始化记忆定位到具体分支。** `runtime_climate_kernel.cpp:2251–2293`恢复scratch为全0，触发`prev_vapor=moisture*0.15`并清零prev_precip；不中断路径1120格初始化标志全1，保留已提交水汽。第0格进入时两边vapor都是0.100893959；仅因初始化分支，下一步vapor从应得0.0939545变为0.0570876，precip从0变为0.0365777。只补日照不能修复；只补conv_inhib也不能修复（本用例该数组为空）。
5. **控制成功但不是生产修复。** 独立诊断库只导出/可注入第3日field_init/conv_inhib；在完整输入+土壤slot对齐基础上，只补回原field_init，日3Climate逐位恢复。对日3、4都供应原轨迹输入/slot后，Climate分别恢复为`8506758247628532623`、`10230635849912990213`。未改Modifier、时钟或其他域。此实验依赖不中断轨迹提供的正确值，不能当通用恢复算法。经济等域仍不同。

### 分类与存档证据

**总体按(b)停止生产修复**，同时记录(a)的预捕获问题；不是(c)“比较了耗时/版本”的误报。`RuntimeClimateSnapshot`在`runtime_climate_authority.h:68`仍注释extras“不需要跨天自持”，但kernel明确跨天读取。CLM2 serializer只写store列、history、cyclone与physics（`runtime_climate_authority.cpp:581–633`），未保存这些extras/天气初始化记忆。顶层dynamic_world虽有同名列，实际保存的不是当日worker值：

| 字段 | 本用例保存值 vs 连续下一日读取值 | 不同格数 |
| --- | --- | --- |
| weather_field_init | 存档全0；worker全1 | 1120 |
| soil_moisture | 例第83格0→-0.0008911321638152 | 519 |
| insolation_now | 存档全0；例第160格0→0.0194957964122295 | 920 |
| insolation_dev | 存档全0；例第40格0→-0.374165713787079 | 1040 |
| heat_input | 存档全0；例第160格同上日照值 | 920 |

`save_modules/geography_state.gd:10`调用DCWorld.serialize；`data_core/world.gd:1674`枚举其镜像slot，不是worker scratch。`EnvironmentRuntime::export_runtime_state`（`environment_runtime.cpp:868–929`）也不含上述权威extras。旧档缺少精确续跑依据，不能承诺新reader无损恢复原未来；不等于每一份旧档都会在同一天分叉。是否改CLM2、或先将真实已提交值写入既有段，均须独立授权保存内容/兼容策略，详见存档评审。

**排除与限制。** 两条路径的捕获day=3及顶层season_phase相同；错误的0发生在空round参数的默认值，不是把时钟日与提交日简单相减就能修复。隔离fixture把时钟RNG固定为150015后，checkpoint和resume完整轨迹各自与原结果完全相同；排除了本四日窗口中随机时钟初态的影响，不证明年度漂移无关。只修正气候输入/field_init就使Climate相同，期间Modifier恢复版本未动，故既存1→3不是此气候分叉的必要原因；Modifier哈希排除范围仍不修。首轮加载API、所有provider“读取成功”不证明世界继续态完整。最意外的是标为scratch/“不需要跨天自持”的字段实际影响未来；CLM2与当前摘要都不覆盖它们，所以序列化往返hash相同仍能在下一日分叉，并非哈希碰撞。

### 各域恢复扫描（提交日2保存，观察日3/4）

| 域/摘要 | 第3日 | 第4日 | 结论范围 |
| --- | --- | --- | --- |
| Climate | 不同 | 不同 | 上述分组控制使两日恢复一致；正式路径仍失败 |
| Economy域 / 整体Economy | 不同 | 不同 | 对齐Climate后仍不同，独立问题待定位 |
| Country | 相同 | 不同 | 未归因，不顺手修 |
| Ideology | 不同（恢复state_day=2） | 相同 | 不等于整域恢复正确；未归因 |
| Modifier | 相同 | 相同 | 仅现有逻辑投影及两日窗口，不含版本字节承诺 |
| Effect | 相同 | 相同 | 同上，不能推定全部未完成事务 |
| Events / Trigger input | 不同 | 不同 | 未归因；Trigger日3状态日期也不同 |
| 资源 / 军事完整快照 | 资源不同；军事报价不同 | 资源不同；军事相同 | 零士兵轨迹，不涉及维护费口径 |

证据目录`/tmp/keynes-arch-phase1/stage15/`：`experiments/`7组输入对照、`experiment-slots/`5组、`experiment-kernel/`5组、`experiment-full-control/`2组、`experiment-clock/`2组；每组是一个独立进程，共21次。`saved-field-differences.json`、`clock-control.json`、`replay/continuation-scan.json`保留数量/样例/逐域结果。正式`check_committed_replay.py --checkpoint --trace`仍exit1，默认回归不将其当通过项。


### S15最终验证

完整命令与日志索引：`/tmp/keynes-arch-phase1/stage15/commands.md`；机器汇总`verification-summary.json`。正式macOS arm64 debug构建exit0（目标up to date）；独立诊断库另编译通过，未安装到正式项目。核心黄金10/10、v5 3/3匹配既有基线；默认改前47/47、改后47/47。护栏892文件0违规、457引用键/445债务键、header_exposed522/total2400、直接Country写2、推进者7、开关95/裸读取0、视图1条；15项护栏单测通过。`git diff --check`通过。

保存续跑`--checkpoint --trace`仍exit1；原轨迹/独立重放/保存不中断相同，resume日3首差异仍在Climate。21次隔离控制进程均正常退出且无脚本错误/失败断言/退出泄漏，但仅“完整输入+slot+field_init”的控制使Climate日3/4相同，其他域仍有差异，不能称保存修复通过。

- ledger_chain: `2242b25110adb22d74a7ce175f8b6e0dce2ef2442741d3dc2a318efa8c7e28c2`
- whole_economy_chain: `30ea61f1e05f12b02d01ebe3aa1bf6060655e39663251100b4be8ae358db73d3`
- domain_chain: `95aedaac2fd631d72657f0d27fbb04009d3ab489b577f3e7c59788ee25ab537a`
- country_chain: `6786a230e8f9b5859c0f9baa13eefd65ec89976e3d1fd119a5131df35a3e8fef`
- external_chain: `0f85a96f0e1a994ede564409e7e1bc5fdac282cbca2da42672da266f9b663c22`

正式C++、正式GDScript、黄金脚本/基线与轮次起点逐字节相同。已追踪debug库SHA前后均为`d3c2dadbd31c95658ffd4258db8035a0c0aa70122b9d0abb7f46cd282a607128`；本轮没有新增受影响的已追踪二进制，原有脏状态未还原。未改暂存区，HEAD仍a712203f；没有外部提交引起的基线调整。未运行release/真实Web/年度轨迹/全部内容组合，非默认既存失败未重测。29份待决定未动。


## S16：气候继续态已落地，全域续跑仍有缺口

本节为当前状态，覆盖S14/S15的“未授权/未修”记录。**开发期不保证旧档，旧版本明确拒绝**；用户授权CLM2升版，以及根因明确且范围小的其他域格式修复。本轮实际只改CLM2字节，其他域仅定位，未改PKEC/ECP2等格式。

### A 初始化边界

`world_runtime_host.gd:1467`只在新世界预捕获；读档不在worker授权前缓存空气候参数。恢复启动在`native_simulation_host_startup.cpp:1012`发布已恢复气候镜像，host`:1497,3707`消费后才进入正式每日输入边界。`world_runtime_climate_restore.gd`传递11个捕获游标，map_generator`:3033`在knob构造之后记录它们；季节刷新“已消费”游标记录本次成功捕获后的值，失败输入不会进入已提交继续态。未修改新世界的日期、公式或提交顺序。

### B CLM2 v9与字段盘点

`runtime_climate_authority.cpp:28,469,620,660`定义版本、在原commit末保存继续态、追加编码、完整校验后安装；`runtime_climate_continuation.cpp:5,19`负责复制/恢复。只保存owner已提交副本，不序列化正在plan的缓冲。magic/段位置不变，v8前缀保留，尾部按既有小端长度+数组编码；浮点按位保存。段状态摘要算法不变，新增尾部受完整payload checksum保护。所有公开POD ABI常量不变。

N为格数；可选列为空表示该阶段尚未运行，非空必须恰为N。

| 状态/类型/大小 | 写入→读取证据（gdext/src） | 处理及理由 |
| --- | --- | --- |
| soil，float，4N | kernel.cpp:2833 distribute→:886,891下一日round/PAW | 不能从旧镜像重建，保存 |
| insolation_now/dev/heat_input，float，12N | round输出→kernel.cpp:887–889、weather distribute:2854 | 跨日继续值，保存 |
| conv_inhib，float，4N | kernel.cpp:2243、2372 weather in/out | 自持时跨日，保存；本用例为空，不能声称已覆盖非零状态 |
| field_init uint8 N + seeded bool编码u32 | kernel.cpp:2251–2293初始化/commit→次日初始化判定 | 保存真实标记；不以全1默认掩盖冷启动 |
| accumulated_snow_days/pre_snow_cover，int32，8N | kernel.cpp:2838–2842、2872 weather distribute | 自持计数，保存；非零雪场仍需扩大金样 |
| day_length/temp_season_offset，float，8N | round输出→authority.snapshot_into发布 | 保存恢复镜像；未认定为本用例下一日分叉的独立根因 |
| 11捕获游标，double，88B+长度 | map_generator.gd:3033及weather/sea_ice/season节拍；world_runtime_climate_restore.gd:4 | 前次pass日、dt缓存、weather嵌入日、stage_b调用序号、season刷新/消费日；不能从单个committed_day推出，随CLM2保存 |
| sea_ice、温湿/历史环、锋面ψ、风/洋流/海洋热状态 | authority原store lanes、physics_state与cyclone_state；kernel.cpp:895起恢复 | 已在原段，不重复新增；物理几何缓存由输入确定性重建 |
| weather prev五列、wx_next中间列 | kernel.cpp weather阶段从store复制、同日写后读 | 当日工作缓冲，不加字节 |
| cover、distribute_field_init | kernel.cpp:2827从next.cover复制、:2866填1 | 可由已存store/算法常量重建，不加字节 |
| hydrology soil/q30/canal、feedback、regen、几何/dirty缓冲 | kernel.cpp:2932–2933每次从输入赋值；:2016重新赋值；几何由坐标/邻接生成 | 不作为owner跨日自持新增；非默认hydrology输入侧保存保真仍未实测，不声称全配置闭环 |

CLM2只接受9：错误`climate_section_version_mismatch_expected_9_got_X`，启动恢复沿已有fault通道返回。原生self_test合成版本1、3–8验证拒绝；没有旧版金样，也没有中性降级加载。候选解码失败不安装新继续态。

金样：`tests/runtime/fixtures/climate_save_v9/day2.pksv`，种子20260727、40×28、clock RNG150015、提交日2。`check_climate_archive.py`读取固定金样、立即重存、与新生成不中断轨迹比较第3–10日气候；该检查接入默认回归。CLM2 v9往返**1,901,228字节逐字节相同**，SHA256=`31fd39b27926cb42315a85bc6647a966fbd9f58677e3fcce9554e739a6cf48f8`。旧库同轨迹CLM2为1,864,132字节，新增37,096字节；**31个非CLM2比较单元（顶层片段、PKSR固定头及其他子段）逐字节相同**。外层长度/压缩/校验和自然随气候段变化，不算其他业务段变化。证据`/tmp/keynes-arch-phase1/stage16/final-save-byte-comparison.json`。整档恢复再编码仍含既存Modifier版本变化，不宣称整份PKSV字节幂等。

### C 八日扫描与剩余根因

`check_committed_replay.py --checkpoint --trace --days 10`仍保留全字段比较，**完整续跑未转绿**。original/replay/checkpoint一致；resume首差异变为日3 EVENTS，`696556395103080423 → 14821903203339855985`。完整记录在`stage16/final-replay2/continuation-scan.json`。

| 域/摘要 | 恢复后日3–10 | 结论 |
| --- | --- | --- |
| Climate | 8/8一致 | 日3原9206377192278548470恢复为连续运行8506758247628532623；后7日也相同 |
| Country | 8/8一致 | 本用例的此前分叉随气候恢复消失，不推广到所有国家命令 |
| Economy人口/市场投影 | 8/8一致 | 此投影相同不代表整体经济全部状态相同 |
| Effect / Modifier | 各8/8一致 | 本用例覆盖范围内相同；未改Modifier字节排除问题 |
| Events | 0/8一致 | 经济未存发展指标发布记忆；第3日重发78条事件 |
| Trigger | 仅日3一致，日4–10不同 | 第4日source_cursor[1]从应为30变为108，消费上述额外事件 |
| Ideology | 日3不同，日4–10一致 | 上一日经济意见快照未恢复，首日soft-complete |
| 整体经济哈希 | 0/8一致 | 已证明发布记忆/冻结视图缺失，但尚未逐项归因此hash全部差异；不能当成仅版本字段 |
| 外围军事/资源 | 军事日3报价不同、日4–10相同；资源八日不同 | 零士兵未付款；资源恢复日期数组未保存是候选，未做充分控制实验，未修改 |

Events证据：`economy_runtime_events.cpp:932–937`将缺失的`_development_fact_country_handles / _development_fact_last_day / _development_fact_qualified`初始化为NEVER_PUBLISHED/0；`:985–1003`连续路径跳过近期未达门槛指标，读档却重发。focused原始事件表为30→108条，next_event_id31→109。三列未进入现有保存代码。Trigger是其D+1下游，不应在Trigger里截断事件或改游标迁就。

Ideology证据：`economy_runtime_reset_state.cpp:317`清空`_class_opinion_buffers`；`economy_runtime_events.cpp:439`在经济提交时重新发布意见快照；`native_simulation_host_ideology.cpp:714–724`读档首日返回`ideology_opinion_snapshot_missing`，stage_ideology.cpp:47–65跳过当日。下一经济提交补出快照，因此次日起相同。不能调用整个publish函数作为恢复修复，它同时发事件。

两项归类(b)：应归Economy继续态（PKEC/ECP2），而非塞入CLM2。**本轮未改**：这些是NativeEconomyRuntime的非OwnedState发布缓冲，现有ECP2候选恢复及PKEC分块恢复都需要覆盖；还需冻结读端、快照revision/内容身份、解析临时状态与候选安装一致性。没有证明它们能在“不动economy_runtime.h”的范围内做完整且小的格式修复，也未证明旧列能无副作用重建上一日快照。用户已允许后续明确的小修升版，不需要再讨论旧档迁移；此处仅列缺失状态与版本方案。建议先为上述发布记忆与意见快照一起建立Economy继续态段，PKEC/ECP2各自升版本、旧版明确拒绝、加非空事件/首日Ideology续跑金样。实现未开始。

第二条已提交视图未做；Web仍默认worker、真实Web待有emcc的机器验证；D+1维护费语义未动。旧过程文档已清理，29份待决定未动。


### S16默认回归的新增未通过项（不隐去）

改前默认47/47，改后**46/47**，新增独立气候金样门禁通过。失败用例是`runtime_economy_worker_restart_test`（不是另一个`economy_worker_restart_day_test`，后者本轮通过）：卡牌激活及重启继续推进两个断言失败。没有worker fault，mask为0xFEF，提交日停22而测试已请求到31。正式测试与生产等待策略均未改。

两轮定位：原用例新库+新脚本再次29检查/2失败，隔离旧库+旧脚本29/0；交叉的新库+旧脚本、旧库+新脚本均29/0。测试`ideology_worker_authority_parity_test.gd:1055–1060`仅在Ideology由worker执行时等待，切到主线程Ideology/worker Effect后没有同等完成等待，立即连推并断言。仅在scratch副本补worker时钟驱动、主线程消费与等待，新库+新脚本变成29/0（`stage16/restart-wait-control.log`）。其中请求日D通常只提交D−1，按D等待会用满原等待窗口，因此该实验不是可直接采用的测试修复。

S17起点更正（本轮结论见文末）：上述少量交叉实验只能提出“测试等待缺口”的假设，不能归因，也不能证明问题既存。用户三次复跑出现一次气候输入等待失败；需以S15/S16两状态、两个独立测试各至少20次的串行对照及字段证据重新判定。S16结束时默认回归不恶化的验收未满足。


### S16连续运行与护栏证据

macOS arm64 debug串行最终构建通过；核心黄金10/10、外围v5 3/3，未改任何旧基线。默认回归与专项结果单独列，不用黄金替代。护栏：894源码文件/457引用键（445债务键）、header_exposed522/total2400、Country直接写2、外围7、开关95（裸读取0）、已提交视图1条，零违规；15项护栏单测通过。HEAD未变化，未做暂存/提交，未放宽任何基线。

- ledger_chain: `2242b25110adb22d74a7ce175f8b6e0dce2ef2442741d3dc2a318efa8c7e28c2`
- whole_economy_chain: `30ea61f1e05f12b02d01ebe3aa1bf6060655e39663251100b4be8ae358db73d3`
- domain_chain: `95aedaac2fd631d72657f0d27fbb04009d3ab489b577f3e7c59788ee25ab537a`
- country_chain: `6786a230e8f9b5859c0f9baa13eefd65ec89976e3d1fd119a5131df35a3e8fef`
- external_chain: `0f85a96f0e1a994ede564409e7e1bc5fdac282cbca2da42672da266f9b663c22`


### S16最终验证与限制

- 串行macOS arm64 debug构建成功；核心黄金10/10、外围v5 3/3，五条末日链逐位不变。
- 改前默认47/47，改后46/47；新气候金样检查通过。失败的runtime_economy_worker_restart_test及隔离等待实验见current-state，未修改正式测试迁就。
- 13项现有存档专项前后均10/13；Climate42检查、Country/Ideology基础/Trigger/运行时段/ECP2/Effect往返通过。其余3项失败错误文本逐行完全相同：ideology_save_worker_authority_test的5条字符串格式错误，ideology_save_transaction_states_test的21条NEG事务比较失败，ideology_save_basis_and_midmaterialize_test的1条tp6边界失败。旧库为隔离pre-project，不曾替换工作区库。
- 完整checkpoint仍exit1，首差Events；仅Climate的金样/八日门禁exit0，不合并宣称完整保真。新版CLM2字节往返相同，整档字节幂等仍不保证。
- 护栏894文件、457键/522/2400、开关95/裸读取0、推进者7、视图1，15项单测通过，零违规。基线未放宽，economy_runtime.h与五条黄金脚本/基线未改。
- 未验证真实Web、其他平台/release、非默认水文/非零对流抑制/季节年度边界；未修财政续跑既存问题、Modifier哈希排除范围或维护费语义。29份待决定文档未动。

完整命令、首次失败与修正过程：`/tmp/keynes-arch-phase1/stage16/commands.md`；文件清单`change-manifest.md`，机器可读汇总`verification-summary.json`，字节证据`final-save-byte-comparison.json`，剩余分叉字段`remaining-causes.json`。S16未达到“完整续跑转绿及默认回归不恶化”的全部验收，不标为整体完成。


## S17实测：重启边界与经济发布继续态

### 重启：对照结果与可证明的归因

同机、相同测试及依赖，冻结S15/S16项目，串行交替轮次（不替换正式库）：

| 测试 | S15末状态 | S16起点 | 修正后的正式测试，S16库 |
| --- | --- | --- | --- |
| runtime_economy_worker_restart_test | 0/20失败 | 2/20失败（第15、17轮，23 checks/4 failures） | 30/30通过，逐轮29检查 |
| economy_worker_restart_day_test | 0/20失败 | 0/20失败 | 30/30通过，逐轮16检查 |

两失败的首个错误都是authority flip重启被拒绝；末尾的气候等待、mask0是测试继续推进后的次生现场。0/20与2/20不能证明真实失败率相同，也不足以指认某条S16气候改动。此前“既存等待问题”的无对照归因已撤回。

已证明的等待契约缺口：两版 `native_simulation_host_worker.cpp:1072`先发布STOPPED，`native_simulation_host_startup.cpp:1089`在worker_main返回后才标returned，而`:49`在returned之前拒绝start。正式host的 `_stop_previous_runtime_worker`已等待 `simulation_executor_exited`；旧测试只等STOPPED。自然快速重启探针两版各100次均未复现；隔离库仅延长这两个标志之间30ms后，100/100首次start被同一worker_not_returned检查拒绝，100/100等退出再请求成功。此诊断库没有装入正式工程。

测试等待修正：`tests/runtime/worker_restart_boundary.gd:6,13`等STOPPED+退出，并按tick D实际捕获D−1等提交；等待期间服务host原_process和Country peer。原断言调用词元不变。仅修退出/日期的第一版虽然两测试各30过，额外观察仍有5/38等待未就绪；加主线程服务后38/38就绪，再从零各跑30次，均通过。最终证据 `fixed-serviced-30/`；不拿第一版结果代替最后版本。不加生产睡眠/重试，不改断言语义。S16可能改变竞争窗口暴露概率，但本实验未定位这种概率变化到某条指令。

### 保存：字段、版本与反向对照

`economy_runtime_events.cpp:932–1003`依赖三列发展指标发布记忆，`:439–582`发布上一日意见快照；此前两者均未持久化。已在ECP2 schema55 / OSOA2的块8保存，字段表见module-boundaries S17。PKEC59未改；`economy_runtime_persistence.cpp:1736,1987,2098`先验证局部候选再按原位置安装，恢复不重新发事件。`runtime_economy_ecp2.cpp`拒绝旧53/54，错误含expected_55；包括显式hash迁移模式。

| 隔离对照 | Events | Trigger | Ideology | 其他五域 |
| --- | --- | --- | --- | --- |
| S16起点缺两组状态 | 第3–10日不同，日3多78条 | 第4–10日不同 | 第3日不同 | 8/8相同 |
| S17补全两组 | 8/8相同 | 8/8相同 | 8/8相同 | 8/8相同 |
| 仅在隔离恢复中清空发布记忆 | 第3–10日重现差异 | 第4–10日重现差异 | 8/8相同 | 8/8相同 |
| 仅在隔离恢复中清空意见快照 | 8/8相同 | 8/8相同 | 仅第3日重现差异 | 8/8相同 |

逐项实测资料：`/tmp/keynes-arch-phase1/stage17/publication-field-controls.json`。字节比较：32个业务比较单元中仅顶层ecp2及PKSR/ECP2改变，其他30个相同；两个ECP2副本内容相同。内部原domain块相同，envelope仅schema字节54→55，OSOA原块1–7相同；新块8为1,167B，立即读回重存逐字节相同。CLM2仍1,901,228B，SHA不变。证据 `publication-byte-comparison.json`、`publication-inner-byte-proof.json`；不把压缩容器checksum/长度变化算作额外业务段修改，也不宣称整档重编码幂等。

### 八日扫描与未收口部分

| 比较对象 | 第3–10日一致性 | 结论 |
| --- | --- | --- |
| Climate、Country、Economy人口/市场、Effect、Events、Ideology、Modifier、Trigger | 每项8/8 | 上述原域摘要及state_day均比较，未删字段 |
| 整体经济hash | 0/8 | 第3日23,020个混入值唯一差异为兼容Country hash；展开后仅税务版本0→1、研究日期−1→2 |
| 军事snapshot | 7/8 | 第3日daily_wage 5467→0、soldier_living_cost 4206→0；零士兵未发生付款。冷查询读取 `_last_digest`（military_core.cpp:2206），它不是worker Country摘要；未改维护费语义 |
| 资源全部储量/extra_change | 0/8 | 实际储量差异，未通过；只补日期/活跃标记/host游标的隔离实验未消除，不能声称仅漏存游标 |

整体hash证据 `whole-hash-field-evidence.json`：`economy_runtime.cpp:7320`通过 `country_read_view.cpp:62`读同步Country hash；`country_runtime.cpp:5356,5400`从worker快照安装研究日/代数，`:10051–10052`又把它们混入hash。连续兼容对象未跟随worker推进，读档后则来自提交快照；完整hash因此不是纯worker业务摘要。不能为了比对把正确恢复的日期降回−1，也不在本轮替换原hash或修改五条链。保留严格失败，后续需明确兼容镜像与摘要版本的契约。字段追踪目前只展开第3日，未把后续七日逐字段展开，不能据此断言所有后续差异都只有这两项。

资源隔离实验第3日16个储量列有差异（extra_change未见差异）；如timber第123格2081234.375→2077610.75、arable_land第483格272.6968079→91.0802612。`map_generator.gd:11175–11229`每格日期/was_live确实影响增量，但恢复这两列及host日期仍失败，还需核查恢复时浮点镜像与定点权威、恢复准备是否已推进资源；未确定唯一根因，不在本轮扩展PKNR/PKMI或改它们的恢复行为。证据 `resource-field-evidence.json`、`resource-cursors-fixed/`。scratch第一版实验因未创建目录而store_var空指针，已终止并修正后重跑；不属于正式代码回归。

完整 `check_committed_replay.py --checkpoint`仍应保持红；部分门禁现扩大为八域与精确发布块往返，不代表完整世界继续态已完成。开发期不保证旧档，旧版明确拒绝。第二条已提交视图继续推迟；旧过程文档已清理，29份待决定未动。


### S17最终验证与限制

- macOS arm64 debug正式构建exit0；先跑核心3/3，再收尾核心10/10、外围v5 3/3，全部逐位匹配原基线。没有更改原黄金脚本/基线。
- 默认回归改前47/47、改后47/47；最终S17库上的两个重启用例均通过；新金样门禁验证八域第3–10日和CLM2/发布块精确往返。两测试各30次重复使用最终测试代码、S16起点库，证明等待修正独立于B的格式变更；它们不等于最终库额外各30次，最终库由默认清单再次验证。
- 13项存档专项前后均10/13；原有三个Ideology失败不变，5/21/1条错误文本逐行相同，未修改测试迁就。Climate/Country/Ideology基础/Trigger/运行时段/大ECP2/Effect等通过。
- 严格checkpoint exit1：原轨迹、重放、保存不中断三者一致；读档后八域相同，但日3军事报价首差，整体hash0/8、资源0/8，未删比较字段。S17-B只能标部分完成。
- 896文件，457依赖键/445债务键，header_exposed=522、total=2400、直接写2、推进者7、开关95/裸读取0、视图1、15项护栏单测；零违规。持久化主文件2404→2217行，已有9个编码helper词元相同地移入内部头，仅收紧对应基线项，未放宽别处。
- ECP2整体重编码本来不幂等：前后均在envelope、AUDIT、MODIFIERS及OSOA原块7有相同规模差异；新块8精确相同。不能将“新发布块稳定”写为“整份ECP2或PKSV字节稳定”。证据ecp2-existing-roundtrip-differences.json。
- 没有运行其他平台/release/真实Web，也没有新增非零军事付款、季节年度或全部存档相位金样；维护费语义、Modifier哈希范围、财政续跑既存问题未修，第二条视图继续推迟。29份待决定未动。

完整绝对命令与输出在 `/tmp/keynes-arch-phase1/stage17/commands.md`、`final-commands.json`；机器可读结果 `verification-summary.json`，本轮文件清单 `change-manifest.md`。暂存状态未变，HEAD仍a712203f，未做任何提交/回退或外部基线补偿。已追踪debug库从05e1e4f…变为70beaa8a…，保留工作区产物。


## S18：完整保存续跑用例收口

以下为本轮实测，范围是固定40×28、seed=20260727、非空军事target命令日志，第2日保存、新进程继续第3–10日；不代表所有地图、季节、非零军费和任意中途保存均已覆盖。

| 差异 / 分类 | 连续路径与旧恢复路径 | 已实施与证据 |
| --- | --- | --- |
| 整体经济hash，(b)兼容输入副本缺失 | 八天分别比较23,020/23,047个mix输入，唯一不同均为Country子hash。进一步展开只有`_tax_policy_version` 0→1、`_last_research_day` -1→2；其余输入相同 | `economy_runtime.cpp:7320`借用兼容Country；`country_runtime.cpp:5356,5400`将worker研究日/generation转成查询副本字段，PKCN正确保存该权威副本，但恢复时覆盖了经济原来读取的启动兼容对象。CPD2另存兼容PKCN，由`native_simulation_host_startup.cpp:1052`在权威身份检查/worker初始化之后、执行线程启动之前恢复；不改hash算法，不用固定0/-1补值 |
| 军事首日工资5467→0、生活费4206→0，(a)缓存重建 | `economy_runtime_military_view.cpp:149`直接读`_soldier_profession_id`；`:40`按需填缓存。恢复后的第一次digest在后续intent查询填缓存之前运行，下一日自然恢复 | `economy_runtime_persistence.cpp:1502`在恢复完成时按原catalog查询填缓存；金额/公式/付款均未改。只有这一恢复改动即令军事第3–10日8/8相同 |
| 资源，(b)经济worker继续态缺失，另有落后镜像 | 保存边界native列与dynamic_world脚本镜像已有205处不同；例如timber格122为2599774.5/2594929。补主线程游标、甚至补native列后仍0/8。`economy_runtime_building_commit.cpp:253`旧恢复从整数stock重新初始化float储量，丢extra并把所有last_day设成day−1 | ECP2 56 / OSOA3块9保存seeded、float reserve/extra、extra_dirty、逐格last_day/was_live；`economy_runtime_resource_checkpoint.cpp`校验后安装。暂存live标记/regen因子可确定性重建，镜像全量重发布，不运行一天公式 |

字段写入链补充：`country_runtime.cpp:462,468`（reset）及`:1104,1110`（configure）把税务版本设0、研究日设−1；同步政策提交在`:4321,4333`递增税务版本，`:9438`在研究日推进后写日期。本用例ACTIVE权威在worker，启动兼容对象没有执行这些日推进；查询副本则由`:5356,5400`装入worker提交日期/generation。原保存只带后者，`:11298–11299`解码后替换前者，才改变经济读入值。S18分别保存两个对象的业务内容；没有把权威日期回退为−1。后续七日展开没有发现第三个不同的mix输入，证据`eight-day-hash-fields.json`及`fields2/*.countrycompat`。

资源首个续跑差异在第3日：按原资源列顺序，timber零基格123为2081234.375→2077610.75；同列15格不同。八天逐列/格比较保留于`/tmp/keynes-arch-phase1/stage18/resource-daily-field-differences.json`，没有靠全局摘要推测字段。保存前镜像差异与续跑差异分开记录。

本轮确认的所有者纠正：在这个ACTIVE配置下，资源恢复实际由经济worker推进；`world_ext_resource.cpp:402`跳过worker已拥有的资源，主线程仍保留登记/回写/兼容入口。单独保存宿主追赶游标不能修复worker内部日期。没有移动任何日执行位置。

| 读档后第3–10日 | 改前相同日数 | S18相同日数 |
| --- | --- | --- |
| Climate / Country / Economy列投影 / Effect / Events / Ideology / Modifier / Trigger | 各8/8 | 各8/8 |
| 整体经济hash | 0/8 | 8/8 |
| 军事完整snapshot | 7/8 | 8/8 |
| 31种资源储量/extra完整摘要 | 0/8 | 8/8 |

严格入口`check_committed_replay.py --checkpoint --trace --days 10`已退出0：original/replay/checkpoint/resume全部有效，无首个差异；没有删字段、改黄金投影或归一化版本。核心黄金10/10、v5 3/3与原五链逐位相同。改前默认47/47，改前存档专项10/13（原三项Ideology失败）；改后默认与专项的最终记录见migration。

字节证据：`/tmp/keynes-arch-phase1/stage18/save-byte-comparison.json`中32个比较单元，29个相同；仅CPD2和两份ECP2改变。原OSOA块1–8逐字节不变；新块9为283,412B，兼容PKCN为50,562B，二者即时重存完全相同。CLM2仍1,901,228B，原发布块8仍1,167B。PKSV压缩/长度/校验随内容变化，不计作其他业务段改变。整档/ECP2旧块既有重编码差异没有被抹平。

所有旧版本拒绝：ECP2要求56（原生自测含53/54/55）；OSOA要求3；CPD2公开ABI仍2，原保留字显式成为payload revision=1，旧revision=0以清晰错误拒绝。没有修改PKCN14、PKEC59、CLM2v9或公共POD ABI常量。维护费、Web默认worker、第二条视图未改；29份待决定未动。


### S18最终验证与限制

- 三次正式macOS arm64 debug串行构建均exit0（build-ab/build-c/build-final.log）；AB后核心3/3，最终核心10/10、v5 3/3，原五条链未变。没有改整体经济hash算法或黄金基线。
- 默认改前47/47；第一轮改后45/47，原因已定位为建筑测试仍断言ECP2 schema55、大ECP2合成用例仍写55。按本轮已授权格式更新到56，保留全部原断言；同类headless_save_replay格式检查同步更新。最终重新完整运行47/47、exit0，金样检查及严格四进程checkpoint均通过。未把第一轮失败隐去或归为既存问题。
- 严格`--checkpoint --trace --days 10`已接入默认入口；original/replay/checkpoint/resume均有效、无差异，保存后3–10日八域、整体经济、军事与资源各8/8。默认新增四个Godot进程，本机最终日志跨度约40秒；这是本机日志测量，不是性能承诺。原默认黄金仍各跑一次。
- 13项存档专项改前/改后均10/13；ideology_save_worker_authority_test、ideology_save_transaction_states_test、ideology_save_basis_and_midmaterialize_test仍失败，分别5/21/1条错误文本逐行相同。证据`save-tests-comparison.json`。其余Climate/Country/Trigger/大ECP2/Effect等通过。
- 护栏：899文件、457引用键/445债务键、header_exposed522、total2400、Country直接写2、推进者7、开关95/裸读取0、已提交视图1、15项单测；零违规。本轮没有更新或放宽任何护栏基线。
- 字节对照及新版往返：`save-byte-comparison.json`、`save-inner-byte-proof.json`、`save-roundtrip-byte-proof.json`。正式库与金样manifest一致；CPD2单独C++测试验证整段编解码一致、重算checksum后的旧revision拒绝、截断拒绝。完整PKSV/ECP2重编码的既存差异仍未修，不能称整档字节幂等。
- 尚未验证：独立PKEC继续态、多国/非零军事财务、季节年度交界、未初始化资源及在途请求等全部保存边界；其他平台/release/真实Web未构建。维护费语义、Web默认worker、第二条视图未改。29份待决定文档未动。

完整命令见`/tmp/keynes-arch-phase1/stage18/commands.md`，结果见`verification-summary.json`，本轮文件清单见`change-manifest.md`。未commit、未git add、未还原他人改动；暂存状态与起点相同，HEAD仍a712203f。已追踪debug库70beaa8a…→f00b7b9e…，保留构建产物。

五条末日链（本轮实测，逐位不变）：

- ledger_chain: `2242b25110adb22d74a7ce175f8b6e0dce2ef2442741d3dc2a318efa8c7e28c2`

- whole_economy_chain: `30ea61f1e05f12b02d01ebe3aa1bf6060655e39663251100b4be8ae358db73d3`

- domain_chain: `95aedaac2fd631d72657f0d27fbb04009d3ab489b577f3e7c59788ee25ab537a`

- country_chain: `6786a230e8f9b5859c0f9baa13eefd65ec89976e3d1fd119a5131df35a3e8fef`

- external_chain: `0f85a96f0e1a994ede564409e7e1bc5fdac282cbca2da42672da266f9b663c22`

## S19 覆盖和边界（2026-11-04）

已验证：`tools/ci/check_replay_matrix.py --full` 串行运行6场景、24进程。每个场景都比较八域（Climate、Country、Economy、Effect、Events、Ideology、Modifier、Trigger）和整体经济hash、军队快照、资源摘要；不删除差异字段。用例入口 `tests/runtime/committed_view_replay_test.gd:12` 保存日参数、`:30`短日历、`:80` GM命令。

| 场景 | 保存后观察日 | 八域 | 整体经济 / 军队 / 资源 |
| --- | --- | --- | --- |
| 第1日保存 | 2–9 | 8/8一致 | 各8/8一致 |
| 第2日保存 | 3–10 | 8/8一致 | 各8/8一致 |
| 第5日保存 | 6–13 | 8/8一致 | 各8/8一致 |
| 第9日保存 | 10–17 | 8/8一致 | 各8/8一致 |
| 八日一年，保存日5 | 6–13 | 8/8一致 | 各8/8一致；季节/年/气候异常/RNG状态也相同 |
| 军事目标＋GM改名，保存日5 | 6–13 | 8/8一致 | 各8/8一致；GM返回回执也相同 |

日历是测试配置：调用真实季节信号和`WorldClock._apply_year_rollover`，但仍由headless日驱动提交模拟。测试关闭当次GameSave自动存档（不写GameSettings），避免把无PlayerController/年报驱动的异步自动存档混入手动保存用例；**不代表真实365日年报/自动存档闭环已验证**。保存都在已提交、同日回写与外围追赶完成的边界；尚未构造计算在途的日提交前保存。混合GM覆盖改名，没有覆盖全部GM命令或跨进程重复命令的去重历史。

独立非零军事：`gdext/tests/military_fiscal_probe.cpp:157`读取旧对象保存字节到新的Country/Economy对象，再执行8次不同序号付款；1名士兵、已有12345军饷，再付1235…1242，金额/国库/军人/原cohort现金和守恒均与不中断路径相同。用两进程分别运行连续/恢复方案，但恢复方案在进程内重建对象，**不能证明进程重启后thread_local去重历史保真**。`military_fiscal_semantics_test.gd:134`在第5日保存带待处理维护费的PKMI，精确重编码，比较第6–13日真实run_daily和回执；此D+1夹具为非零建筑维护费、零士兵，与非零军饷夹具分开。维护费产品语义未改。

测试开发记录：第一次军事恢复被`resource_rows`完整性检查拒绝，因为独立一格夹具没有地图输入；仅在测试里补齐空资源行后转绿。一次完整矩阵在构建重叠期间于第2日、尚未保存时出现Economy/Events/资源差异，日志保留，未证明构建是唯一原因；重跑未复现。另一轮calendar checkpoint摘要完全相同但有ObjectDB退出警告，verbose重跑未复现；关闭无关自动存档后矩阵通过，未宣称已定位该警告的确切对象。

第二条读边：`gdext/src/runtime_events_authority.h:37`拥有事件副本与generation/day，`runtime_events_authority.cpp:145`只复制`_current`并断言无在途计划；`native_simulation_host_trigger.cpp:65`消费前检查版本不倒退。reset/restore重置诊断游标，原转发循环体逐字节相同。诊断游标不入存档；默认关闭断言的配置不更新该游标。`check_committed_views.py`拒绝直接snapshot、别名和成员指针反例；隔离CLI反例exit1、删掉后exit0。

宿主：只提取`world_runtime_preparation.gd:5`准备表现和`:41`停止等待。原host生成、恢复`:1405`、模拟启动`:1434`、关闭入口及release顺序不动；除了2处转发和1个帧等待方法，其余原方法体不变。host7074→7037；perf-validation副本未动。生成和恢复涉及多个宿主状态、信号、await后的取消检查，本轮没有把整个host作为属性袋传给组件来凑拆分，完整步骤5仍未完成。

证据目录 `/tmp/keynes-arch-phase1/stage19/`：`matrix-final/matrix.json`、各场景`continuation-scan.json`、`military-continuation/summary.json`、`host-proof.json`、`adapter-proof.json`、`events-loop-proof.txt`、`view-negative.json`。旧过程文档已清理，29份待决定未动；Web默认worker、维护费语义保持。


## S20 当前核实

29 份阶段记录中的待决定文档本轮逐份保留，分级与理由见 [document-disposition.md](document-disposition.md)。它们不是架构事实入口；代码证据仍以本目录现状文档和可复现实验为准。

### S20 最终核实（2026-11-04）

- 29 份文档逐份列在 [document-disposition.md](document-disposition.md)。本轮全部保留：运行时规格是参考契约，军事、理念与价格材料保留为玩法或接口依据；仓库内隐藏目录与仓库外 `~/.claude/skills/project-keynes-*` 均做了只读引用扫描，未改外部文件，也没有产生悬空引用。
- 四条已提交视图（Climate→Economy、Events→Trigger、Modifier→Ideology、Effect→Modifier）均有拥有者复制、generation/day 检查和反例护栏；`check_committed_views.py` 报告 4 条、0 违规，架构单测 15 项通过。
- 年度自动存档短年历实验（16 天年、保存日16、观察到24日）四进程均 `valid=True; first_difference=None`，年报已产生且自动存档槽写入成功。历史记录：S20时真实365日年在保存日365跨年后第366日仍分叉；连续运行 `base_moisture` 为 `16825879274537167275`，恢复运行是 `17103708155533410081`，随后 Climate/Economy/Events 也不同。该问题尚未修复，不能把短年历结果外推为真实年度闭环。
- S20 未删除实现或玩法文档；五条连续黄金链未改变。

S20 验证补充：完整回放矩阵的 6 个场景全部 `valid=True; first_difference=None`（24 个进程）；短年历自动存档四进程通过。历史记录（S21）：真实365日跨年曾在第366日以 `base_moisture` 首先分叉；该问题已在S22通过继续态与写回修复，当前结果见文末S22记录。最终护栏为903文件、457键/445债务键、header_exposed=522、total=2400、开关95、已提交视图4、架构护栏15项通过；主链10/10、v5 3/3，五条链不变。


## S21：年度读档核查

已验证：真实 365 日场景保存第 365 日后，连续运行与读档继续的首个气候差异来自三份基础湿度副本不同步。`map_generator.gd:2870-2892` 的 season capture round 写 native slot 与 MapData，`world.gd:1636-1648` 的 `serialize()` 读 DCWorld；保存前因此可能取到旧副本。阶段修复位于 `scripts/game/world_state_bindings.gd` 与 `save_modules/geography_state.gd`：保存时只读 native `cell_base_moisture` 覆盖输出字典，恢复后刷新 DCWorld 对应列，不改连续运行中的 live mirror。证据：`stage21/annual-narrow/refresh.log` 的 `S21_LANES` 在恢复、day366 前后均为三份副本 0 差异。

仍未解决：同一用例读档后的 ECONOMY 从 day366 起分叉。`stage21/annual-final` 首差为 ECONOMY；逐字段 trace 显示连续人口为 `21,20,4,5,3`，恢复为 `20,21,4,5,3`，而保存 PKEC 已含人口、EMA、demography residual 字段（`economy_runtime_persistence_write.cpp:201-216`）。S21当时推测为槽位重建/保存边界顺序问题；S22已证实是职业人口数差异及缺失继续态，见文末纠正。

S21-B 在途保存：`game_save_coordinator.gd:356-373, _wait_for_safe_boundary` 先暂停时钟并等待 committed/idle 条件，超时返回拒绝；本轮未新增专用断言。S21-C、S21-D 未开始。

## S22：年度继续态已定位并修复

真实365日自动保存与相邻364/366手动保存均已八日全域一致。根因、逐字段控制实验、版本和限制见[S22记录](s22-annual-continuation.md)。特别更正S21：“21/20互换”是职业人口数变化，不是身份槽位交换。缺失就业冷却、恢复所有者绑定、Events/Trigger游标、入口ID重建和天气发布返回码分别处理，未改公式。已提交视图4→6，在途保存专用测试7项、宿主格式对照99项已通过；最终统一回归结果见migration。

### S22 最终统一验证

- 最终macOS arm64 debug构建exit0。按用户最后补充的验收次数：目标收口核心3/3＋外围2/2，最终再核心3/3＋外围2/2；五条链逐位不变。未声称本轮跑10次。
- 默认改前49/49、改后52/52，均exit0；改后包括新金样、四进程checkpoint、两个边界矩阵、短年自动存档和真实365日场景，总547.31秒。默认内365日场景83.51秒、四进程全部valid，first_difference=None；相邻364/366各八日也一致。目标1无剩余阻塞。
- 护栏906文件、457键/445债务键、header522、total2400、直接写2、推进者7、开关95/裸读取0、视图6、16项单测；零违规。size仅收紧host基线7037→7029（本轮实际7036→7029）、persistence2217→2216。
- 专项：在途7项、environment9项、入口游标4项、宿主格式99项、气候往返43项、线程隔离30项、领域POD15项，全部通过。6个真实源码绕行反例全部拒绝，隔离反例已删除。
- 中间失败保留：冷却保存首次链接缺三个新定义，补齐后构建通过；专项曾误用不存在的runtime_ideology_pod_test.gd，已用真实runtime_domain_pod_test.gd补跑。另一次重复金样命令因目标日志目录已存在被拒绝；原金样运行及默认金样检查均通过。不是隐藏回归或降低断言。
- 32个字节比较单元仅4个预期改变；新块10、传输游标和environment往返相同，年度10条非空冷却也验证204字节完全相同。完整PKSV/ECP2旧重编码差异仍保留。
- 未验证：其他平台/release/真实Web、全地图/非零战争年度、任意真实worker日内指令强停；三项既存Ideology保存专项本轮未重跑。维护费语义、Web默认、economy_runtime.h未改。29份文档继续按S20分级保留。

完整命令、文件、失败历史及字节证据见`/tmp/keynes-arch-phase1/stage22/commands.md`、`change-manifest.md`、`verification-summary.json`。HEAD仍a712203f，暂存状态与起点相同，未commit/add/还原他人改动。

五条末日链：

- ledger_chain: `2242b25110adb22d74a7ce175f8b6e0dce2ef2442741d3dc2a318efa8c7e28c2`

- whole_economy_chain: `30ea61f1e05f12b02d01ebe3aa1bf6060655e39663251100b4be8ae358db73d3`

- domain_chain: `95aedaac2fd631d72657f0d27fbb04009d3ab489b577f3e7c59788ee25ab537a`

- country_chain: `6786a230e8f9b5859c0f9baa13eefd65ec89976e3d1fd119a5131df35a3e8fef`

- external_chain: `0f85a96f0e1a994ede564409e7e1bc5fdac282cbca2da42672da266f9b663c22`


## S23 实施状态

- G1：Country `pkcn` 与 Economy `ecp2` 通过 `archive_contract()` 登记自己的段、版本、写入/恢复入口和恢复依赖；`check_save_contracts.py` 报告 2 owners、0 violations。业务写入和恢复函数未改。
- G2：新增三条只读边：Country AI 读取 Economy 摘要、年度报告读取 Country 摘要、家庭指标读取 Economy 已提交意见快照。视图复制 owner 已提交数据，并在消费处检查 generation/day；`check_committed_views.py` 报告 9 edges、0 violations。
- G3：模块契约现在有 cadence、reads、store、intent_types、view_version、save_sections；12 个日域和消费者读边已登记，`check_module_contracts.py` 为 0 violations。
- G4：`economy_runtime.h` 10240→2742 行，5 个内部头均不超过 2000 行；`economy_runtime.cpp` 仍 7989 行，未达到目标。包含者集合仍为 151，`header_exposed=522`、`total=2399`。
- G5：恢复准备组件使 `world_runtime_host.gd` 7029→7010 行，16 项冻结对照通过；生成/关闭流程仍未开始。
- G6：两国场景保存第5日后8日全域一致；三项 Ideology 专项已修正测试前提并通过。非零军队年度保存已复现分叉，尚未通过。

S23证据范围：头文件展开逐字节证明对应机械拆分阶段；后续新增 `copy_lineage_opinion_view` 和非存档版本游标是独立读边变更。513依赖键的位置变化不表示新增域对，头暴露522未增；Family消费点去掉直接类型借用使总次数2400→2399。全读边语义盘点、主cpp目标4000、host目标5500、非零军队年度场景尚未完成，不把局部通过当整项目标验收。


### S23 非零军事覆盖：发现分叉，未修复

独立 `military` 轨迹使用固定种子20260727、两个电脑国家：第1日建role=0兵营并开放征召，第20日组建军队，第21日宣战并请求行军；不修改任何兵种、工资或维护费规则。连续第366日有4士兵、1支野战军、1场战争，30日工资统计655066、维护费统计59999883。命令接纳不等于占领已生效：该地图目标路径未证明可达，本轮不声称占领覆盖。

两次严格比较都只有resume失败：保存日20→第21日Country首差 `2842744092386703869` / `4985869367930426184`，兵营pending_enlist为3 / 0；保存日365→第366日Country首差 `14565665992812907108` / `1598430533223594240`，国库98108418 / 98113885（差5467，等于单兵日工资）。原始、重放、保存不中断三条轨迹完全相同；所有域继续比较，没有删字段或重新生成黄金基线。证据：`stage23/matrix-military2`、`military-annual`、`military-findings.json`。

静态检查确认PKMI会保存pending_enlist与桥接待处理记录（`military_core_save.cpp:542,1163`；`world_ext_military.cpp:3411,3479`）；恢复同时把经济回执读取游标重置（同文件3512–3514），而军队经济行另由PKEC section36保存（`economy_runtime_persistence_write.cpp:1477`、`economy_runtime_persistence_read.cpp:2982`）。这些证据排除了“军队人数完全未保存”的简单解释，但尚未以单字段干预证明唯一根因。疑点是恢复后的军饷/征召回执与经济行安装边界；未改财政或维护费语义。

保留手动红测试 `check_replay_matrix.py --military` / `--military-annual`；不纳入默认或绿色full集合，不把失败当期望成功。后续先对保存前/恢复后立即的PKEC军队行、PKMI桥接记录及D+1命令队列逐字段比较，再隔离恢复游标和命令去重；根因未证实前不新增存档字段。G6因此部分完成：多国保存及三项Ideology专项已绿，非零战争年度读档与占领仍未验收。

进一步字节核查（stage23/military-archive-fields.json）：第365日ECP2内PKEC section36含army=4294967296、population=1、funds=4496078；第20日同一行population=0、country=0、cell=-1，军事侧已经有1人野战军，处于跨日接纳边界。不是整个军队经济段遗漏。此证据只缩小范围，尚未证明回执游标、待处理命令或恢复安装中的哪一个字段是唯一根因，不能据此直接修财政代码。

### S23 最终复核补充

真实年度场景单独复跑 `check_replay_matrix.py --annual` 成功（86.62 秒，四轨迹无首个差异）。但最后一次 `--full` 在 `mixed5` 第 8 日出现一次保存前的间歇性 Economy 分叉：失败进程记录 `economy_runtime_cadence.cpp:726–764` 的耗时自适应周期由未调整状态变为 `n=4`，人口 accounting flag、资金和资源随之不同。改前隔离副本一次通过，当前版本定向重跑也通过；因此目前只能确认存在未收口的时序不确定性，不能声称是 S23 引入，也不能把 full 说成稳定全绿。未改生产 cadence、未放宽回放比较，失败现场保留在 `/tmp/keynes-arch-phase1/stage23/final-full3/mixed5/`。


## S24 R1 现场与当前证据（2026-11-05）

- 经济命令续存已接入 PKSR v4：保存点会保留已接纳但尚未执行的 Economy POD 命令、普通回执和终态回执，恢复前校验候选队列后安装。旧 PKSR 版本按开发期策略明确拒绝。10 日 checkpoint 四进程均 `valid=True; first_difference=None`。
- 经济周期继续态已接入 ECP2 schema 58 的 owned-state block 11，保存六个 EMA/累计耗时字段；锁定周期天数和起始日沿用既有段字段。生产自适应计算未改。黄金、回放和矩阵入口都调用 `replay_cadence.gd` 固定测试周期，并由 Python 入口检查缺失即失败。
- 军事全局 inactive 过滤已撤回；保留原连续计数。军事20日恢复已由 PKMI v2 原始链继续态修复，年度场景仍在逐项核实。
- 跨域读边现有9条；本轮增加 `cross_domain_inventory.json` 与 `check_cross_domain_inventory.py`，把依赖基线中的31个域对逐一列出。该表保证新域对不会绕过登记，但对间接调用仍是文本级清单，逐函数语义核查列为 R2。
- `world_ext_military.cpp` 与 `economy_runtime_persistence.cpp` 棘轮分别压回3665/2216行；本轮未上调任何阈值。
### S26 / R2 Freeze 记录

`RuntimeFrozenInputVersion` 与 `RuntimeFreezeReadSet` 已在 `gdext/src/runtime_freeze_contract.h` 登记 session、day、generation、command watermark 及 committed/in-flight；Climate、Country、Economy 的 Freeze 入口登记并检查版本。`check_module_contracts.py` 报告 12 modules、9 reviewed reads、0 violations，架构护栏 22 项通过。Climate 仍按现有输入准备/提交顺序先于 day plan，避免改变黄金链。

原 J1/K1 过滤方案已撤回。PKMI v1 丢失仍挂链的 inactive 槽位 payload，恢复重建链与连续运行不等价；本次在 PKMI v2 保存原始链与槽位继续态，不保存派生 present。
### K1 / K2 追加核查

**撤回 J1/K1 结论**：此前把 inactive 行称为“幽灵兵力”并保留全局过滤是错误的。变更型调用方必须看到这些行才能保持原有槽位复用语义；过滤使连续 day20 总兵力1→4、驻军0→3、军饷141819→158220，违反连续运行不变。过滤已删除，不能再作为修复方案。

Climate 已在统一 day plan 的 Freeze 读集合登记环境版本；它仍在 day plan 之前完成输入捕获和提交，因为环境 FIFO、generation、writeback 游标必须先稳定。当前最小安全步骤是登记与校验，合并执行顺序仍需同轨迹证明。

### R2 L1–L3：原语义军事继续态

已撤回全局 inactive 过滤。军事20日 PKMI 原始索引恢复已验证四进程一致；年度继续态继续按首差逐层修复，包含 ECP2 59 实物收入列与 PKSR5 ACK/自有编号游标。根因、字段和限制见 [军事继续态记录](s26-military-continuation.md)。最终统一验证结果追加在本节后，不以中间红测试当最终结果。

### R2 L1–L5 最终实跑（2026-11-05）

军事全局过滤已撤回；PKMI2保存原始索引，ECP2 59补实物收入列，PKSR5保存ACK/编号，MDJ1保存军事事件转发进度。军事20日与365日保存均续跑8日全域一致。年度保存点与恢复重存索引74721字节逐字段相同，原连续day20保持驻军0/总兵力1/军饷141819。未改变军饷、维护费、公式或Web默认。

| 实跑入口 | 结果 | 耗时 |
| --- | --- | --- |
| 构建 / 主链 `--runs 3` / 外部 `--runs 2` | 全部通过，五条末日链不变 | 2.5 / 28.7 / 19.0秒 |
| `--military-annual`（含立即重存） | 4进程valid、first_difference=None | 91.1秒 |
| `--full`（新增两个军事场景） | 9场景、36进程全绿 | 409.9秒 |
| `--annual` | 4进程全绿 | 83.2秒 |
| 默认回归，带重建的military fiscal probe | 58/58脚本＋探针1/1；全部附带回放/金样检查通过 | 796.8秒 |
| 原生军事定向 / 气候存档专项 | 153项native及脚本游标检查通过 / 43检查0失败 | 定向3.4秒 / 专项40.1秒 |

最终静态护栏：919文件0违规；496引用键/484债务键，header_exposed518、total2210（均低于522/2399上限，基线未改；不把计数下降归功于本轮）；Country直接写2，推进者7，开关95/裸读取0，视图9、存档契约2、模块12/读边9、域对31，22项反例单测通过。`git diff --check`通过。

字节比较32单元中28个不变；变化仅PKMI、ECP2及其嵌套副本、PKSR头。ECP2原OSOA块1–10、其余15域payload与PKMI原section1–21不变；真实计时块11跨进程可变，同档立即重存48字节相同。细节见[根因记录](s26-military-continuation.md)和临时目录的verification-summary.json/commands.md。

L4未开始：经济cpp7989行、头2742行、host7010行与本轮起点相同；未加视图，perf-validation副本未改。实际地图未发生占领（路径没有安装，军队仍在原格）；合成占领自测通过，不能混为同一覆盖。其他种子/平台、军事364/366保存未重跑；旧的改前默认批曾中断，不作完成基线。R3–R5固定计划保持，29份文档仍保留分级。


## R3 / S29：请求与提交边界切片

详见 [R3实现、请求清单与保留债务](s29-resolve-apply.md)。本轮三个已有请求队列共享契约，军事最后两处Country直接写改走现有所有者端口；十二域写声明与三个实际Apply入口增加护栏。未改阶段顺序或存档格式。Ideology宽泛错误软完成与Effect忽略错误已收紧；启动/ACK兼容仍保留，不宣称全域soft-complete消除。四个文件型诊断只接受绝对路径，测试前后检查新增非源码文件。R3最终批次（修复兼容债登记后）已完成：生产构建和财政 probe 构建均 exit 0；静态护栏全过（size 920 文件 0 违规；C++ 496 引用键/484 债务键、header_exposed=518、total=2210、Country direct writes=0；Resolve/Apply 3 队列/3 Apply 入口 0 违规；架构单测 24 项）。主链 runs=3、外部 runs=2 均 first_difference=None。默认回归 exit 0，耗时 807.05 秒；full 矩阵 7 场景 exit 0，410.73 秒；annual exit 0，83.58 秒；military-annual exit 0，91.41 秒。默认回归含 61 个日志项及保存续跑/矩阵/年度检查。


## R4 / S30：宿主生命周期与 C++ 存档段契约

本轮把关闭、取消和释放流程提取到 `scripts/game/world_runtime_lifecycle.gd`。`WorldRuntimeHost` 仍保留原公开入口、信号、状态所有权和 Web 回退；组件只通过 host 引用执行原顺序。host 7010→6970 行。冻结检查 18 项、WorldSession 29 项、准备测试 15 项通过；完整 host ≤3000 行目标尚未达到，生成主流程、日调度和存档装配仍保留在 host，继续列入 R4。

新增 `tools/ci/cpp_save_section_contracts.json` 与 `check_save_section_contracts.py`。12 个域登记 owner、tag、当前版本、写入/恢复证据和恢复依赖：Climate/CLM2 v9、Country/PKCN v14、Economy/ECP2 v59、Military/PKMI v2、Trigger/PKTR v6、Effect/PKEF v14、Modifier/PKMD v3、Ideology/PKID v14、Family/Technology 的所属段、Host/PKSR v5、Annual/PKAR。契约检查拒绝缺版本拒绝证据、恢复顺序倒置和未登记域；Family/Technology/Annual 目前是所属段委托，未另造第二套存档格式。

本轮没有改变存档字节、公式、调度顺序或五条黄金链。Economy cpp 7989 行和额外读边迁移未开始，作为后续 R4 切片。


### R4 最终验证（2026-11-05）

构建 exit 0。静态护栏：921 文件、0 违规；依赖 496/484、`header_exposed=518`、`total=2210`；开关95、视图9、存档契约2个脚本 owner+12个C++域、模块12/9、跨域31对、Resolve/Apply 3/3、架构护栏25项。主链3/3和外部2/2均 `first_difference=None`。默认回归 exit 0，61个测试日志及保存/回放/金样检查通过。`check_replay_matrix.py --full` 为9个场景36进程，`--annual`和`--military-annual`各4进程，全部 `valid=True; first_difference=None`。

宿主生命周期抽取后的 host 为6970行；`economy_runtime.cpp`仍7989行。完整 host≤3000和经济文件收口未完成，列入后续R4切片。工作区相对起点新增文件全部为源码、测试或文档，未新增非源码游离文件。

## S31 R4b 实际状态（2026-11-05）

宿主拆分已完成本轮目标：`scripts/game/world_runtime_host.gd` 为 2,955 行，生成/恢复准备、日调度、GM/诊断、视觉查询和生命周期由适配组件承接；`perf-validation` 宿主和 Web 回退路径未改。Economy 主实现 `gdext/src/economy_runtime.cpp` 为 1,974 行，六个最大成员函数搬到四个 `economy_runtime_residual_*.cpp`，新文件分别为 1,357、1,695、1,749、1,653 行。逐词元和逐行证明记录在 `/tmp/keynes-arch-phase1/stage31/economy-token-proof.json` 与 `economy_move_proof.json`。

依赖棘轮当前为 506 keys、491 debt、`header_exposed=518`、`total=2209`、0 violations；新增 `.inc` 只供 Economy 实现聚合完整跨域类型，并在 `cpp_deps_baseline.json` 中有受控 relocation 记录。最终验证已完成：主链 runs=3、external runs=2、默认回归、full（7 场景）、annual、military-annual 全部 exit 0，所有回放进程 `first_difference=None`。

