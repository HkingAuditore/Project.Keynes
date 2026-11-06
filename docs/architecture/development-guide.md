# 开发指南

先读 [现状](current-state.md) 与 [目标](design.md)，确认数据所有者、运行线程和真正提交点。不能把目标接口当已存在的 API。下方按轮次保留的历史记录，以文末 R2/L1–L5 的状态与入口为准。

## 修改现有每日模块

1. 在 `native_simulation_host.cpp` 的 modules 表找到对应域，修改其 `native_simulation_stage_<domain>.cpp` 成员函数；公式仍放数据所有者的现有实现中。
2. `DayExecution` 保存本次调用的引用和暂存事件；不得把这些引用留到调用之后。阶段返回 true 表示继续遍历，不表示业务成功；成功、等待、失败仍由原有 stage/commit 字段和故障状态表达。返回 false 提前结束本次日计划。
3. 更新表的 reads/writes 声明与现状文档。它们目前是描述文本，不产生访问权限。所有十二项都不是“只限主线程”；inline 与 worker 共用函数，不能在其中加入 Godot 对象或 GPU 操作。
4. 保留气候前置、域前后故障点、Events 尾部调用、原有完成检查和 publish 顺序。想改变这些语义需单独设计与回放证据。
5. 表顺序与 `runtime_domain_stage_order()` 由 static_assert 核对，计划数量/逐项域用 assert 检查。新增现有域内部功能不增加 RuntimeDomainId；新独立日域会涉及 ABI，不能作为普通表项随意加入。

## 现有会话与保存接入

每日表不替代脚本生命周期与保存登记。会话扩展使用 `WorldRuntimeHost.register_session_module`，由 `world_session.gd` 管理准备、取消和关闭。保存扩展使用 `game_save_coordinator.gd` 的 `register_state_module(provider, restore_after)`；内建装配在 `world_state_modules.gd`，依赖/片段所有权检查在 `runtime_module_registry.gd`。只读实际接口再接入，不新增全能宿主引用。

已有例子：`tests/game/world_session_test.gd`、`tests/game/runtime_module_registry_test.gd`、`tests/game/fixtures/extension_state_module.gd`。本轮没有增加 cadence 登记、通用 intent 总线或 C++ 存档模块注册 API。

## 护栏与检查

```sh
python3 tools/ci/check_size_ratchet.py
python3 tools/ci/check_cpp_deps.py
python3 tools/ci/check_runtime_advancers.py
python3 tools/ci/test_architecture_guards.py
cd gdext
scons platform=macos target=template_debug arch=arm64 dev_build=no -j8
```

返回仓库根目录再执行：

```sh
python3 tools/ci/run_regression_checks.py --godot /opt/homebrew/bin/godot \
  --log-dir /tmp/keynes-arch-phase1/regression
```

首次导入需要时加 `--import`。默认入口先执行静态护栏，再跑 47 个脚本；保留每项日志，并将 SCRIPT ERROR、失败断言和退出泄漏作为失败。不同 SCons 配置共用中间文件，必须串行构建；运行带墙钟故障门槛的检查时避免并行编译争用。

## 黄金用例维护

`tests/runtime/golden_day_hash_test.gd` 复用 starter soak 的正式会话与逐日提交入口。固定 seed=20260727、40×28、无外国、正式开局；固定调用日序 1..8，无玩家变更命令。每次等到同日经济账目已提交后取值，不靠固定睡眠假定完成。

`values` 顺序是：日、开局格、人口、人口/钱/物资误差、资金、周期收入、周期支出、cohort 数、满意度、完整市场库存数组、价格数组。按此固定顺序序列化，用 SHA-256 生成日摘要，再链接前日链。基线包含原始取值，不能仅核对八个非空哈希。

正常运行只读 v4 `golden_day_hash_baseline.json`，并独立核对原样保留的 `.v2.json`、`.v3.json` 投影。诊断采样可设置 `PK_GOLDEN_CAPTURE=1`，这只打印 GOLDEN_RESULT，不写基线，也不是通过验收。要更新基线，先保留旧结果、解释业务变化，再用同一二进制连续至少 5 次逐日逐域比较，人工审查新旧取值；建立后运行 `--runs 10`。数值 JSON 解码类型需统一，但哈希字符串必须逐字相等。

v2 同时校验开局账目与同日回写后的完整经济哈希；v3 追加七个 worker 域的明确范围投影，仍不证明完整十二域状态确定。不能通过删字段、改种子或更新基线掩盖未知差异。资源边界修复及取样边界见 [现状](current-state.md)。

### E1 诊断与重复运行

`PK_GOLDEN_DIAGNOSTICS=1` 打印全部初始化资源列与国家发现计数、每日完整经济哈希和原报告。报告含耗时，不得整包当黄金；整数哈希输出为十进制字符串。测试等待同日提交、worker 无在途日任务、Modifier 已消费相同 generation 且日期相同，再读完整经济哈希；等待时不提交下一日。

```sh
python3 tools/ci/check_golden_determinism.py --godot /opt/homebrew/bin/godot \
  --runs 10 --log-dir /tmp/keynes-arch-phase1/stage2/repeat-new
```

日志目录须全新。脚本串行运行，校验完整基线与整体经济逐日哈希；错误、泄漏、缺少诊断或基线不符立即失败，不能删失败样本拼连续次数。`--capture-candidate` 不比对当前基线，但始终核对旧 v2 的全部字段/链，再与第一轮候选完整结果比较，保存 candidate.json；它不写仓库基线，也不等价于验收。只在已授权的变更有证据后使用。

本轮授权的资源修复先与旧基线比较，账目未变；修复后连续十轮一致后才建立 v2，再独立十轮匹配 v2。v1 原内容保留在 `golden_day_hash_baseline.v1.json`；旧账目末日 2242b251…仍有效，但不再作为完整经济确定性的凭据。新增 `whole_economy_hash` 与 `whole_economy_chain` 不混入旧账目链，便于分辨状态变化来自哪里。

`get_country_state_hash` 仍取同步对象，不能作工作线程 Country 摘要。Modifier 序列版本字段的哈希排除范围问题仅记录，未修。E2 逐域诊断与 E3 登记的实际验收以 migration.md 为准。

### E2 增补域摘要

`get_runtime_perf_snapshot(3)` 在 `PK_GOLDEN_DOMAINS=1` 时追加 `golden_domains`。宿主只读实现位于 `native_simulation_golden.cpp`，Godot 转换位于 `world_ext_golden.cpp`；不新增绑定。普通 detail=0 不触发诊断。黄金用例自动开启；`PK_GOLDEN_LEGACY_ONLY=1` 或检查器 `--legacy-only` 关闭它并校验 v2。

新增摘要前先确认真正 authority 与提交边界；不得借用兼容 runtime、plan preview 或会发布状态的 capture 方法。只在整日锁保护下遍历已提交数据，明确 scope 和实际 state_day，逐字段固定顺序计算；保存 blob 中若有代数/校验和，应解码到局部副本，不能改 live store 或保存格式。不要以已提交日替换尚未提交域的日期。

修改摘要后先走候选采样，所有旧链仍必须通过。只将连续至少五轮一致的完整候选域加入 DOMAINS，再运行十轮正式基线比对。COUNTRY 曾在 E2 被排除；S3-A 修复生产交接边界后，已通过独立 country_chain 追加到 v4。不得删发现日期或替换同步 getter 使它看似稳定。其余覆盖缺口见 current-state.md。

默认回归只有一次黄金基线比对，重复次数由检查器 `--runs` 控制；日志目录必须是新目录，不能删除失败样本来拼接“连续通过”。`PK_GOLDEN_COUNTRY_TRACE=<scratch路径>` 可额外记录 Country 原始数值列，用于定位差异，不纳入黄金结果。

### E3 增补表外推进/消费入口

先确认它是真正业务推进还是回写/显示消费，再编辑 `tools/ci/runtime_advancers.json`：填写 id、thread（main/worker/executor）、reads、writes、trigger、source、entrypoint，以及该入口的 Host 日期/游标与追赶函数名。EXECUTOR 表示 worker 或现有 inline 调用线程。不要把显示的 family_cursors 当成家庭模块。

```sh
python3 tools/ci/check_runtime_advancers.py --write-header
python3 tools/ci/check_runtime_advancers.py
python3 tools/ci/test_architecture_guards.py
```

显式生成只更新 `gdext/src/runtime_external_advancers.h`；默认检查和回归不会写文件。审查 JSON 与 C++ 头的一致变更，构建、比对既有黄金链。空未登记基线不得用来放行新入口；已有例外若移除应收紧基线。新增 Host 推进保持约定的 cursor / last_commit_day / pending_target_day 与 queue/drain 名称，避免绕开检查。

这是登记流程，尚无统一 cadence、执行位置迁移或存档分段 API；军事/资源仍由原主线程入口执行。需要移动时另行提供完整状态与提交顺序证据，不能由登记完成推断迁移完成。

## 交付要求

同时更新现状、边界与迁移状态；区分源码核查、构建、无画面运行、图形与其他平台验证。源码拆分不能写成所有权迁移完成。构建若改动被追踪二进制，列出来交由工作区所有者处理，不用版本还原覆盖现场。


## S3 接入约束

- 交付 Trigger 的 Country 命令必须在主线程服务完成前入队；ACTIVE Country 的收件在服务完成并取得日边界锁之后。不得把 ACK 当作下游命令已经提交，也不要把取队列移回等待之前。OFF/SHADOW 路径保持原收件位置。
- 黄金 v4 的 `country_chain` 是追加链，七域 `domain_chain` 仍用 v3 的顺序和种子。新域必须先重复比较，再追加链并保留旧版本；不能修改旧链以适配新投影。普通回归仍只运行一次黄金。
- 经济全部 Country 查询使用 `country_reads()` 的 27 种只读方法。`CountryReadView` 借用所有者和静态函数表，不拥有状态、不保证多次即时查询共享一张快照。税率/科技/领土仍在 `capture_country_epoch` 调用 `copy_economy_snapshot` 冻结；不得改采样点。
- `check_cpp_deps.py` 拒绝所有 `economy_runtime*.cpp` 的 Country 直接查询（保留工厂与明确写入名单），也拒绝头文件恢复具体 Country include。新增查询先检查所有者原 getter，再在视图声明、Country 回调和调用清单中接入，分批构建及至少三轮黄金；不能新增另一可写 runtime 连接绕过。

## S4 依赖基线维护与只读接口

检查先运行 `check_cpp_deps.py`；`header_exposed` 是 `.h` 暴露引用次数，`total` 是全部次数，两者都包括 `contract_references` 中的获准只读接口；`references` 记录其余受限依赖。普通新键/次数增长不因别处删除而获得许可。域对集合不得新增；确有同头文件移入对应 `.cpp` 的引用，在更新时给出 `--moves <scratch.json>`，映射目标完整键到原头文件。只允许同目录同名/后缀实现、相同域对和符号，来源必须同时减少；多个目标不能重复花同一次减少。S12另准许同目录economy_runtime*.cpp之间的同键机械位移，约束与操作见文末。不要手工提高计数。

```sh
# moves.json 例：{"gdext/src/economy_runtime_country_ai.cpp|economy->country|include:country_ai_core.h": "gdext/src/economy_runtime.h"}
python3 tools/ci/check_cpp_deps.py --write-baseline --moves /tmp/keynes-arch-phase1/moves.json
# 单纯减少也必须先通过检查；更新会保留移位证据。
python3 tools/ci/check_cpp_deps.py --write-baseline
python3 tools/ci/test_architecture_guards.py
```

更新入口读取现有基线并核对来源差额、两个总量及域对；失败不写文件。`relocations` 保存 moved_from、来源前后数和目标原数/移入数，可审查而不是只附一句备注。纯新增依赖、伪造接口名、头文件暴露增加等反例由八项护栏测试覆盖。文本扫描不能替代对宏、别名与指针权限的审查。

只读视图的 `Snapshot` 是传输副本，Country 原嵌套名称保留别名，旧序列化方法原样使用。已有即时/冻结/兼容哈希的取值区别必须保留。增加字段不得自行改变存档字节或黄金基线；先界定需要哪一个已提交边界。Country→Economy 仍未迁移。

S5 已在既有资产协议上落地 FISCAL_RETURN 同步 intent 端口；通用写入入口仍未开始。后续按 module-boundaries.md 的剩余写入清单逐条验证原请求身份、原 Apply 顺序，不另建可跨日悬挂的队列。S3-A 则是已经落地的**生产行为修正**：原定第 3 日的命令改前可能第 5/6 日生效，修复后此用例稳定第 5 日；不能把它描述成仅测试等待变化。


## S5 返还请求与退役检查

- FISCAL_RETURN 的同步调用使用 `fiscal_return_port()`：在原位置取 `next_order_key()` 并 `submit`，随后 `prepared/apply/applied` 保持原顺序。不要缓存 borrowed port 跨过所有者生命周期；不能把它改为延迟消费。worker 分支先走已有 Host 队列，绝不同时提交同步 intent。
- 现有 Godot 事务字典是回执格式；类型化的是请求与身份，不声称已移除所有 Dictionary。新增写入迁移必须有非零发生量、金额/顺序/回执和保存流证据，不能只跑未触发路径的黄金。
- 默认回归新增 `tests/runtime/fiscal_return_intent_test.gd`。`PK_FISCAL_RETURN_CAPTURE=1` 只打印候选，不代表匹配基线；当前基线来自改前二进制两个一致样本，禁止用改后结果自动覆盖。PKEC chunks 带帧头，恢复必须逐块喂入，不可把合并流当一块。
- `check_cpp_deps.py --write-baseline` 仍先检查类型/头文件和剩余直接写入预算，再收紧 `country_writes`。FISCAL_RETURN 直接调用不能通过提高基线放行；九项护栏测试含别名/方法指针和未迁移写入增长反例。
- 退役前核查生产入口、所有可配置入口、测试/工具、公开绑定和存档。默认关闭不等于不可达；Events probe 实际用于生产。当前 S5-B 表没有满足全部条件的大块删除对象。下一轮不能把表中“默认不走”当删除许可。


## S6 写入与独立表外用例

- 采购通过`procurement_port()`构造带owner顺序键的`CountryProcurementIntent`，随后`prepared/apply/applied`；不要跨生命周期保留port，不把同步消费延迟到下一日。财政预留/征收由S5端口的`reserve_intent/collect_intent`构造，再`submit_cash`；原返还仍`submit`。worker必须先走原队列，不能双重提交。
- 新迁移先用旧二进制跑非零专用用例并保存两次相同的回执/金额/原始与恢复后存档摘要，再改C++、串行构建、三次黄金、专用基线比对。采购和财政用例分别是`tests/runtime/procurement_intent_test.gd`、`fiscal_cash_intent_test.gd`。capture开关只用于取证，默认回归必须关capture。
- `check_cpp_deps.py`在S6时把尚未迁移直接写冻结为34；S7后基线已收紧为军事适配2处；禁止在采购文件、财政协调函数恢复旧写调用。按原位置即时应用不是新增延迟队列；不得改变Country commit → Economy更新 → ACK顺序以凑通用接口。
- 表外独立用例`golden_external_advancers_test.gd`，基线`golden_external_advancers_baseline.v5.json`；不编辑旧黄金脚本或四份JSON。它等同日worker/Modifier边界、军事与资源追赶后取样。家庭/人物必须是live boundary或同日committed view；禁止取旧缓存或为哈希强跑业务pass。
- 摘要仅在测试中计算，生产代码不增加扫描。按固定字段/稳定键顺序编码；排除耗时、修订号、重试计数。读取更多字段前检查getter是否只读、权威是否正确；记录投影遗漏项，不能将投影称为完整store。
- 重复验证使用绝对路径命令（日志目录须新建）：

```sh
/Users/herh/.local/bin/python3 /Users/herh/MyFiles/games/keynes/tools/ci/check_golden_determinism.py --godot /opt/homebrew/bin/godot --runs 10 --external-only --log-dir /tmp/keynes-arch-phase1/stage6/new-external-run
```

不带`--external-only`仍验证v1–v4；`--capture-candidate`只生成scratch候选，连续10次一致后才人工接纳。默认回归对每个黄金用例仅跑一次。v5的完整诊断数据保存在重复脚本日志中，可从首个不同日期/类别继续比较字段。当前军事只有政策变化、无士兵；视野固定，不代替未来战斗/视野转移测试。S5-B删除仍暂停等产品决定，29份待决定文档保持不动。


## S7 当前接入规则

以下替代上文历史阶段的剩余数量：Country直接写仅剩军事适配2处；已迁移32处均禁止绕回。新增现金/物资请求使用fiscal_return_port的cash_to_cohort/cash_from_cohort/good_to_market/good_from_market构造，再submit_transfer；科研使用research_intent/submit_research；多物资国库支出使用spend_intent/submit_spend。已有采购仍走procurement_port。所有请求只能在原同步边界立即消费，原worker请求优先分支不能越过；prepared/apply/applied的次序和经济侧入账位置不变。详情与暂缓原因见module-boundaries.md的S7表。

专用验证包含非零现金/物资、原事务回执、0/0/0守恒，以及先Country后Economy的分块保存恢复。PKEC及含Modifier的PKCN可能原本就有重编码差异，必须对照迁移前原始流与恢复后流各自的完整摘要；不可为了相等清零版本/日期字段。新测试辅助类intent_save_evidence.gd可供复用；它对殖民夹具显式断言唯一既有版本差异，没有泛化忽略字节区间。

### 新增环境开关或故障点

1. 在`runtime_switch_registry.h`的RuntimeSwitch枚举添加键，在`.cpp`的switches数组同位置填名称、未设置行为、作用、是否仅诊断。名称不得改写；枚举与数组顺序由静态断言和检查器核对。此表的“默认”只描述现有行为，不返回替代值。
2. 调用`pk::runtime_switch_value(pk::RuntimeSwitch::PK_名称)`取得原始const char指针，在调用处显式解析。要逐项决定未设置与空串、首字符与整串、数值裁剪、是否static缓存。旧开关迁移不得顺便统一解析或读取时机；不得自行读取getenv或引入间接变量绕过登记。
3. 新故障名称加入`.cpp`的faults数组，再在既有合法边界调用try_fault_injection。默认未武装，公开arm/clear语义不变。动态生成目前仅接受既有runtime_domain_fault_tag与前后缀形式；新域名也必须登记两侧。新生成形式要同时扩展检查与反例，不增无理由白名单。
4. 运行check_runtime_switches.py、test_architecture_guards.py和默认回归。runtime_switches_baseline.json当前无例外。检查拒绝裸getenv、未登记/间接环境读取、未登记字面故障及未知动态故障；不能把它当成完整语义分析器。
5. 原生开关全覆盖在C++注册表；GDScript运行时环境入口本轮仅盘点，新增/改动时同步current-state.md。不要据“diagnostic_only”删公开配置面。Web同步回退仍等产品决定。

```sh
/Users/herh/.local/bin/python3 /Users/herh/MyFiles/games/keynes/tools/ci/check_runtime_switches.py
/Users/herh/.local/bin/python3 /Users/herh/MyFiles/games/keynes/tools/ci/test_architecture_guards.py
```

本轮没有删除旧实现或文档；旧过程文档已清理，29份待决定文档保持不动。生产默认五条黄金链仍须分别检查，v5需显式使用--external-only。


## S8 Host文件导航与机械搬迁

`native_simulation_host.cpp`保留十二域模块表与日编排；其他成员按职责放在同名前缀的startup、worker、commands、persistence、journal、report及域/资产实现文件，完整导航见current-state.md。成员声明仍只在原`native_simulation_host.h`中，新增叶文件必须不超过2000行。全部平台由同一SConstruct的`src/*.cpp`自动收集，不添加另一份显式源列表。

搬迁时保存起点，按成员和辅助函数分别比较忽略排版/注释的词元（字符串及签名必须保留），核对定义无遗漏/重复；仅允许include调整和无状态匿名辅助函数的原样复制/inline共享。静态缓存、thread_local与初始化副作用须保持唯一归属。每组串行构建、主黄金3轮及独立v5 3轮，再做最终10轮和默认回归。使用行数脚本向scratch写候选，确认仅已变小条目变化后再收紧基线；不能用写基线消除新超限。

`check_external_day_alignment.py`是可选实验，不进入默认回归。它用同一v5输入分别关闭/开启`PK_EXPERIMENT_EXTERNAL_DAY_ALIGNMENT`，检查关闭模式匹配原基线、开启模式实际到达4个同日边界，并保留首个差异和每模式重复结果。不写任何基线；实验相同仅证明该用例相同，不能直接切换产品默认。

```sh
/Users/herh/.local/bin/python3 /Users/herh/MyFiles/games/keynes/tools/ci/check_external_day_alignment.py --godot /opt/homebrew/bin/godot --runs 3 --log-dir /tmp/keynes-arch-phase1/stage8/new-alignment
```

新增开关仍按S7注册规则办理。S8开关只供测试子类读取，精确1开启；正式Host不读取它，默认配置面未变。


## S9 经济实现文件定位与机械搬迁要求

当前主类是`NativeEconomyRuntime`，`economy_runtime.h`仍为完整公共/私有声明入口。新的21个cpp按职责表见current-state.md；跨域读取、事务协调、家庭类型密集实现和全域哈希仍有部分在原cpp。修改既有行为前按成员名定位实现，不根据旧阶段行号猜文件。新的实现文件经`gdext/SConstruct`的`Glob("src/*.cpp")`自动收集。

本轮没有更改依赖lint：cpp→cpp不是现有h→cpp规则的隐含例外。不要通过新中转头、改归属名称或调高总数来让机械搬迁“变绿”；本轮只提取不移动跨域债务的函数，原所有者和类布局保持不变。S9末主文件16784行；S10继续到15783行，剩余跨域部分必须先解决等量迁移的可审计规则。

搬迁验证用完整签名和函数体词元（含字面量）比较，另核对主文件去除搬迁片段后的逐字节剩余；重载/嵌套析构和宏生成成员不能漏。允许复制无状态匿名辅助函数，带static/thread_local状态的辅助函数必须保持单一归属；不移动声明访问标记。每组串行构建后跑核心黄金3次；最终核心10次、外部至少3次、默认回归、全部护栏。具体命令和结果保存在本轮`/tmp/keynes-arch-phase1/stage9/commands.md`。

行数工具的JSON只保存超限债务；新文件≤2000按默认上限检查，**不给新文件创建超限豁免**。先将`--write-baseline`输出到scratch，再逐项验证仅目标文件缩小后同步；本轮只有economy_runtime.cpp基线26688→16784，未改任何其它项。头文件和GDScript下一步方案见[s9-split-plan.md](s9-split-plan.md)，尚未落地；尤其视野刷新会提交Country观察命令，不能作为纯表现移到任意帧。


## S10 开发边界与测试入口

- 经济审计/运行资格/故障上下文定位`economy_runtime_audit_boundary.cpp`；Country回执服务定位`economy_runtime_asset_peer_service.cpp`；研究需求/旧额度列定位`economy_runtime_epoch_demand.cpp`；建筑计划转发定位`economy_runtime_building_plan_adapter.cpp`。它们都仍是原类方法，不是新模块API。
- host纯值转换放`world_runtime_host_values.gd`，由原方法转发。参数必须显式给出；保持借用字典/数组语义，不能顺手deepcopy。时间采样、GPU/图像对象读取、World状态、信号和日推进留在host。新增或改变转换时先看`world_runtime_host_values_test.gd`；reference脚本是S10前实现，不能同步修改它来“证明”新实现。
- 同步军费的新诊断会真实失败，**不在默认回归中**。先串行构建通常的macOS arm64 debug，再运行下面两条。测试专用动态库链接现有生产对象，不替换生产二进制、不加生产绑定；不是全部平台测试。日志中`money_delta=12345`是缺陷，不能按预期值改成绿色。

```sh
/Users/herh/.local/bin/scons -C /Users/herh/MyFiles/games/keynes/gdext -f /Users/herh/MyFiles/games/keynes/gdext/tests/SConstruct.military_fiscal_probe platform=macos target=template_debug arch=arm64 dev_build=no probe_dir=/tmp/keynes-arch-phase1/stage10 -j8
/opt/homebrew/bin/godot --headless --path /Users/herh/MyFiles/games/keynes/Project/project-keynes --script res://tests/runtime/military_fiscal_semantics_test.gd -- --native-probe=/tmp/keynes-arch-phase1/stage10/military_fiscal_probe.gdextension
```

既存Modifier哈希排除范围、worker等待窗口、财政续跑4项失败未修。不要用零军费v5替代这次非零同步付款的守恒检查；修复需独立批准与非零worker/同步、保存和回执验证。旧过程文档已清理，29份待决定文档未动。


## S11：军事付款验证与边界

同步军饷只做一次国库扣款，并在同一调用内给军队入账。`FISCAL_COLLECT`是国库收款，不能作为支出完成信号；不要调用旧`military_collect_cash`实现军饷。当前同步分支复用Country intent端口，worker保持TREASURY_SPEND同步peer流程。D+1维护/建造仍用旧helper，支出接收方与审计口径未决定，勿顺手迁移。

非零专用验证需要测试扩展：先串行构建正式macOS arm64 debug库，再用`gdext/tests/SConstruct.military_fiscal_probe`和绝对`probe_dir`构建独立库；在`military_fiscal_semantics_test.gd`后通过用户参数`--native-probe=/绝对路径/military_fiscal_probe.gdextension`指定它。该库只注册测试类并链接当前生产对象，不新增正式绑定。默认回归不假定存在macOS专用测试库；可给`run_regression_checks.py`加`--military-fiscal-probe /绝对路径/military_fiscal_probe.gdextension`，将同一红绿用例作为额外检查运行。未提供时的默认43项不代表非零军饷已测，报告必须单列专用结果。

测试同时检查精确扣款/入账、全钱包合计、重复身份、零额、无效国家、缺失军队、资金不足裁剪、空国库；Country prepared拒绝取消需释放占用且无提交。取消证据是Country协议层，不冒充跨日军事取消验证。不得用尚未重新计算的money_error代替实时钱包总和。

继续拆经济文件前先核对已搬清单：S10已搬走只判空批次，S11复查无新增合格成员。不要把_country_runtime的出现次数当可迁/不可迁结论，也不要把只读view的工厂实现误当不需要具体Country头。现行moved_from只允许已审定的h→cpp移动，不涵盖cpp→cpp。


## S12：cpp搬迁与被动表现组件

- `check_cpp_deps.py --moves /绝对路径/moves.json --write-baseline` 接受“目标完整键→原文件”的审查映射。除既有h→cpp外，仅允许同目录economy_runtime*.cpp之间位移；不能跨域、跨目录、搬到头文件或把同一份源下降额度重复分配。total/header_exposed不增，新域对仍禁止；没有映射的增长仍报错。不要复制country/modifier等include到多个新文件而借此放宽基线。
- 先跑 `test_architecture_guards.py` 正反例；每组搬迁保存完整成员词元比较，构建再跑核心黄金3次；收尾10次与外围3次、默认回归。对基线写操作先生成scratch候选，逐项与轮次开始快照比较，只收紧实际变小项。新小文件按默认2000行门槛检查，超限清单无需额外豁免项。
- `world_runtime_overlay.gd` 管遮罩请求/缓存/烘焙；`world_runtime_presentation.gd` 管建筑资料与标签绑定。它们是RefCounted，没有_process或模拟命令。host的原方法按当前会话显式bind_resources再转发，遮罩通过Callable请求host是否继续处理帧；会话释放时release_resources断开地图、生成器、时钟、渲染资源引用。不要把host整体传给组件，也不要让组件建立第二个日推进入口。
- host仍负责时间顺序、await后的会话有效性、信号与视野pass。昼夜预览hold/release时钟尚未搬迁。修改表现组件需跑冻结旧实现对照、player_country_ui_smoke及loading/resource lifetime，headless通过不能替代图形验证。
- 军事专用库仍用 `gdext/tests/SConstruct.military_fiscal_probe` 串行链接生产对象，再传给回归入口 `--military-fiscal-probe /绝对路径/military_fiscal_probe.gdextension`。新增D+1用例明确断言当前钱流，不把“Country单笔守恒”或陈旧money_error当所有钱包组合守恒证明。

## S13：Web失败路径及GM/录制器接入

Web不允许静默掉到旧脚本日推进。扩展启动分支时，先区分“原生worker转原生inline”和“最终无原生执行器”，后者经`_reject_web_daily_fallback(code, reason)`报告；不要在桌面返回路径增加状态写入。故障后仍需遵守会话先关闭再释放，重试不能清掉其他native故障。

逃生仅用于诊断：在场景Inspector/启动前设`runtime_web_allow_gdscript_daily_fallback=true`，或环境`PK_WEB_ALLOW_GDSCRIPT_DAILY_FALLBACK=1`；浏览器优先用导出属性。它恢复旧路径，不能作为正常配置或完整世界等价性的证明。开关已登记在C++表；所有旧开关默认值未改。

GM规格/参数转换/提交组装在`world_runtime_gm_commands.gd`，host保留接纳、日期、序号、时钟/故障与信号。录制器无状态包装在`world_runtime_recorders.gd`，不得把采样时间或统计清零移进去。当前CSV数据、年报转发和命令序列的冻结对照见`world_runtime_commands_reference.gd`与`world_runtime_commands_test.gd`；冻结参考不能随实现修改。Web兼容对照见`world_runtime_web_reference.gd`与`web_daily_fallback_test.gd`，两测试进入默认回归（43→45项）。

S13仅macOS debug与headless验证，不代表浏览器导出通过。当前旧`gm_runtime_host_test`另有无有效会话的自动保存断言及资源退出泄漏，前后均复现；未进入默认45项，不修它来隐藏失败。既存Modifier哈希范围、worker等待窗口、财政续跑4失败、预烘缓存指纹问题继续只记录。本轮不重新验证这些历史失败数。


## S14：已提交视图与回写适配

新Climate投影只在原执行线程、提交完成后调用`copy_committed_view(day,cells,lane_size,out)`。保持旧形状检查/回退条件；消费者必须调用版本断言，不得重新访问store/planned_store或兼容主线程数据。out独立拥有列，使用后可以move进输入，不得修改owner。修改投影需保持黄金五链，并跑已提交视图护栏、owner重试/恢复自测；新跨线程读者须另行设计同步，不假定此factory自带锁。

Modifier适配使用无状态`world_runtime_modifier_writeback.consume`，显式传ready、generator、control Callable、当前generation，返回原游标或新游标。只有host保留调用序和游标，不把整个host传进去，不增加ACK或外围日推进。冻结reference测试不能跟着实现一起改。

```sh
/Users/herh/.local/bin/python3 /Users/herh/MyFiles/games/keynes/tools/ci/check_committed_views.py
/Users/herh/.local/bin/python3 /Users/herh/MyFiles/games/keynes/tools/ci/check_committed_replay.py --godot /opt/homebrew/bin/godot --log-dir /tmp/keynes-arch-phase1/stage14/new-replay
```

默认回归各运行一次命令轨迹/owner自测及Modifier对照；独立checker运行两个进程比较完整轨迹。加`--checkpoint`会运行保存与读档续跑，**当前已知失败**，不加入默认绿色回归、不改预期迁就；所有存档由工具指向新scratch目录。`--project`用于改前库隔离复现，不得替换正式工程的库。观察到首个差异时保留完整摘要/日志，不能静默丢域或更新既有链。

模块存档设计评审见[s14-save-sections-review.md](s14-save-sections-review.md)。provider版本、内部字节版本和内容身份分开审查；任何新schema/字节变更须另获授权。Web真实默认worker，不按旧inline注释改默认；真实导出在有emcc机器另验，回退删除第2步未开始。29份待决定未动。


## S15：保存续跑诊断，不能用普通回归替代

`check_committed_replay.py --checkpoint --trace --godot /opt/homebrew/bin/godot --log-dir /绝对路径/新目录`串行跑original/replay/checkpoint/resume。新增`--trace`只启用既有PK_SIM_DAY_TRACE，每进程单独文件；新增`continuation-scan.json`完整列出每个观察日的所有域、整体经济、军事、资源差异。仍按完整结果判失败，不能挑相同域作为通过。

本轮正式续跑仍为红测试。先做分组输入对照，再区分owner继续态与可见镜像；native slot会覆盖某些字典字段，必须比较真正进入计算的列。仅在scratch隔离项目/独立库做强制补值，生产工程不得读实验文件。S15独立诊断库由scratch的SConstruct.diagnostic链接当前生产对象，只替换一个诊断kernel对象，未替换正式动态库。

CLM2缺少权威extras/天气初始化状态、顶层镜像落后，已按字节限制停修；保存后的绿用例尚未建立。不得补一个无来源的全1初始化表作为通用恢复，不得重写旧黄金或忽略Modifier版本字段。本轮第二条视图仅候选评审，护栏仍为1条。正式金样需要将保存前worker状态、文件实际值、恢复后首个输入、每阶段输出串起来。旧过程文档已清理，29份待决定未动。


## S16：新增存档继续态

开发期不保证旧档，旧版本明确拒绝；不再要求旧版金样或中性默认恢复。新增影响后续日推进的字段须：盘点owner读取→写入及可重建性；在原commit边界冻结副本；升内部段版本（不顺改公共ABI）；严格校验长度、有限性、内容身份/checksum；完整解码后安装；以清晰版本错误拒绝旧档。

新版本金样必须固定seed、命令、时钟RNG和提交日，记录生成命令、库身份、原始段SHA/长度。验证新段逐字节往返、其他业务段逐字节不变、不中断与新进程载入后至少八日摘要。`check_climate_archive.py --godot /opt/homebrew/bin/godot --log-dir <绝对scratch目录>`是仅气候的已落地门禁；全域仍用`check_committed_replay.py --checkpoint --trace --days 10`，当前保持红，不能删掉Events/Ideology/Trigger来报通过。五条既有黄金基线不得重建。

非气候格式改动目前只在根因明确、改动小、证据充分时授权；否则先列字段/owner/候选安装方案。只读投影相同不足以证明全部经济状态保真。读取失败不得默默换新世界或继续半恢复会话。当前原子性是现有候选/文件边界，不声称统一世界回滚已实现。


## 重启测试的完成边界（S17）

STOPPED是状态标签，不单独保证线程已返回。测试请求stop后必须等待`simulation_executor_exited`才重新start；正式host已有此等待。日tick D的输入捕获约定是D−1，等待应绑定实际提交目标，不从某次异步采样的当前日推导“还要多一天”。测试helper为`tests/runtime/worker_restart_boundary.gd`，它只等待原接口，不重试业务命令、不改原断言。保留失败的首个请求及完整后续日志，不能仅凭末尾停滞报告推断首因。


## S17 保存发布状态与重启测试补充

- 不只保存公式直接读的列：事件去重/节拍记忆、下一域读取的上一日已提交视图也是继续态。先做独立遗漏字段对照，再由其所有者段编码；恢复不能重跑带发事件副作用的发布函数。
- 当前正式经济继续态为ECP2 schema 55 / OSOA 2块8。字段顺序在 `economy_runtime_publication_codec.h`，形状/日期/handle检查在解码候选中完成；开发期旧版明确拒绝，不静默填零。新增格式必须更新金样并比较所有未授权变化的段。
- `check_climate_archive.py`现在检查CLM2和经济发布块的精确往返、八域八日一致；名称沿用既有默认入口。它不认证完整经济hash、军事或资源；完整结果仍以未删字段的 `check_committed_replay.py --checkpoint --trace --days 10` 为准。
- 重启用例必须等待STOPPED且 `simulation_executor_exited`，然后才再次start；等待提交期间服务host原 `_process(0.0)`及Country peer。tick D捕获D−1，不能等未发布的D或“比稍后采样日期再多一天”。共享测试helper为 `tests/runtime/worker_restart_boundary.gd`；不向生产加睡眠、重试或改断言以隐藏问题。


## S18：新增跨日状态必须进入checkpoint比较

新增会影响未来的状态（包括资源小数余量、逐格上次日期、发布记忆、被实际读取的兼容副本）必须先确定owner，再加入其保存片段；能由catalog无副作用重建的缓存应恢复时重建。禁止以整数投影、落后显示镜像替代owner继续态，禁止为了通过回放改变既有hash算法。

完整验收入口为`check_committed_replay.py --checkpoint --trace --days 10`：同一非空命令日志的不中断、重放、保存不中断、另进程载入四条轨迹都必须相同，观察读档后至少八日。该入口现已接入默认回归。`check_climate_archive.py`沿用名称，但同时验证固定金样的八域、整体经济hash、军事和资源，以及CLM2/块8/块9/兼容PKCN的精确往返。不可把局部字段相同当整份ECP2重编码相同。

当前版本：CLM2 v9、ECP2 schema56、OSOA3（块8发布、块9资源）、CPD2 ABI2/payload revision1；旧版本明确拒绝。更改格式须更新对应版本、拒绝测试、金样manifest及生成说明，并逐字节核对所有未改业务段和既有子块。完整PKSV采用ECP2；不要宣称独立PKEC59也自动获得同样继续态。五条已有黄金链不能重建。

Country兼容副本仅在权威Country身份验证和worker种子安装后、线程启动前恢复，避免两个角色混用。资源恢复不推进公式，只安装owner字段和重建镜像发布队列；不要移动主线程日位置。维护费与Web默认不动；6条已提交视图已有generation/day检查，下一条仍需按读边证据推进。29份待决定未动。

## S19 接入规程

新增跨日场景必须加入 `check_committed_replay.py` 的完整摘要比较；保存日、季节/年份边界、非零军事和混合命令应作为独立场景记录。新增已提交读边必须复制 owner 的 committed 数据并带 generation/day，在消费处断言游标单调，同时给 `check_committed_views.py` 添加可失败的直接借用反例。宿主适配只能接收窄 Callable/RefCounted 依赖，停止顺序必须先停执行器再释放资源。


## S20 视图与年度存档规程

跨域读取必须通过所有者的 `copy_committed_view()`，视图带 generation/day，消费端调用 `observe_committed_view()`；不得在消费端保留 owner snapshot 引用或访问 plan。新增边界要在 `check_committed_views.py` 中同时加入正例和直接绕行反例。

年度自动存档测试要保留 coordinator 开启、年报等待和自动保存槽；手动 checkpoint 关闭自动保存只适用于不测年度闭环的回放。跨年用例至少比较保存后八日的域摘要、整体经济、军事、资源和年报状态，不能只检查文件存在。

## S20 新增读边与年度存档

新增跨域读边必须由 owner 返回独立 committed view，消费方调用 `observe_committed_view()`；不得保存 owner snapshot 引用或读取 plan。同步更新 `tools/ci/check_committed_views.py` 的直接绕行反例和 `test_architecture_guards.py`。

年度存档测试必须保留真实 coordinator、年报等待和自动存档槽，至少比较保存后八日的域摘要、整体经济、军事、资源和年报状态。短年历通过不等于365日通过；跨年失败时先定位写回边界，再改环境存档版本。


## 年度与在途保存

新增跨日字段前先在 checkpoint 逐字段比较保存后继续与不中断轨迹；不能用删除字段或放宽比较掩盖分叉。Geography 的基础湿度保存使用 owner 的 native slot，并在恢复后刷新 DCWorld。保存请求由 `GameSaveCoordinator._save()` 统一等待 safe boundary；不应从 provider 直接捕获 Plan 中间状态。年度完整矩阵仍需手动运行，直到 ECONOMY 槽位顺序问题解决。

## S22 年度保存与边界门禁

修改就业继续态、年度回调、事件发布/转发或恢复所有者时，必须运行真实年场景：

```sh
/Users/herh/.local/bin/python3 /Users/herh/MyFiles/games/keynes/tools/ci/check_replay_matrix.py --godot /opt/homebrew/bin/godot --annual --log-dir /tmp/keynes-arch-phase1/annual-check
/Users/herh/.local/bin/python3 /Users/herh/MyFiles/games/keynes/tools/ci/check_replay_matrix.py --godot /opt/homebrew/bin/godot --annual-neighbors --log-dir /tmp/keynes-arch-phase1/annual-neighbors
```

前者保存365日、比较366–373，已进入默认回归；后者分别保存364/366，比较各8日，手动档。日志目录须新建，不能删差异字段或以排序后的数组替换原比较。当前本机约84秒/场景，不是运行时间保证。

保存只允许已提交安全边界：`inflight_save_boundary_test`覆盖真实事务未ACK时拒绝、完成后允许及协调器等待/终止拒绝；新增保存入口不得绕过它。现有测试并未穷举真实worker所有日内指令位置。

读边增加时同时修改`check_committed_views.py`、直接/别名/成员指针反例及所有者复制自测。工厂只能读取sealed发布，不得把plan preview标成committed。新增保存字段必须有旧版拒绝、原无关字节比较、非空字段往返、checkpoint逐日比较；S22格式为ECP2 57、PKSR3、environment provider3，详见[S22记录](s22-annual-continuation.md)。


## S23 新增规则

新增存档段先在 owner provider 实现 `archive_contract()`，登记 id、版本、段名、恢复依赖及读版本；由 `world_state_modules.gd` 组合，不能从另一 owner 直接读写字节。新增跨域只读必须复制已提交数据，附 generation/day 游标并在消费处检查；同时在 `check_committed_views.py` 和模块契约 registry 加正例、直接访问/别名反例。

模块描述符的 cadence、store、intent_types、view_version、save_sections 是只读契约，改动后运行 `check_module_contracts.py`；它们不会自动改调度顺序。

本轮机械拆分阶段的证据：5个内部头展开后与起点逐字节相同；之后另加了已提交意见视图及非存档诊断游标，包含者集合保持151；宿主恢复准备对照16项通过。非零军队年度保存已测出分叉，不能用零士兵 v5 代替。

G4内部头只在NativeEconomyRuntime原class位置包含，不允许单独include：它们是机械拆分片段，不是新的公共接口。重建包含树仍为151个cpp，未宣称改善编译扇出。`check_cpp_deps.py --moves` 的内部头位移只接受同目录原economy_runtime.h到economy_runtime_internal_*.h；同符号源减少、总量和header_exposed不增加，反例见护栏单测。


S23默认矩阵增加两国场景（2个电脑国家，保存日5后8日），实测约40秒额外成本；`--full`仍检查7场景。非零军事诊断使用 `check_replay_matrix.py --military` 或 `--military-annual`：目前应实际返回非零并给首差，不可写成“预期失败所以通过”。修复后才升级为默认绿色门禁。普通 `--annual`仍为零野战军的365日闭环，不能替代战争场景。

Country/Economy契约的readable_versions由owner提供，coordinator仍保留既有显式PK_SAVE_MIGRATE路径；默认兼容集合、实际版本拒绝和内层字节校验均与S22相同。新增模块不能只改manifest版本而不核对内层格式。


## S24 周期与跨域登记规则

生产经济周期继续使用耗时自适应；黄金、回放和矩阵测试必须在入口安装 `tests/runtime/replay_cadence.gd` 的固定注入，不能让机器耗时决定测试轨迹。`check_golden_determinism.py` 和 `check_replay_matrix.py` 会在启动前检查该入口，缺失即失败。新增跨域依赖先更新 `cross_domain_inventory.json` 并说明是已迁移、明确不迁移还是待核查；`check_cross_domain_inventory.py` 会拒绝表外域对。

S24 新增保存继续态时，先校验候选命令/回执和周期字段，确认通过后再安装；开发期旧 PKSR/ECP2 版本明确拒绝。命令队列、周期 EMA/累计量和版本错误都要有非空测试与 checkpoint 逐日比较。
### R2 冻结输入规程

新增业务域必须在 Freeze 入口登记 `RuntimeFrozenInputVersion`，至少检查 session、day、generation 和 committed/in-flight；同时更新模块描述符 reads/writes，并运行 `check_module_contracts.py` 与架构反例测试。阶段检查只报错，不改变 scheduler 顺序。Climate 的前置输入准备属于独立边界，改动前必须有同轨迹对照。

原 J1/K1 过滤方案已撤回。PKMI v1 丢失仍挂链的 inactive 槽位 payload，恢复重建链与连续运行不等价；本次在 PKMI v2 保存原始链与槽位继续态，不保存派生 present。
### K1 / K2 新规程

**撤回 J1/K1 结论**：此前把 inactive 行称为“幽灵兵力”并保留全局过滤是错误的。变更型调用方必须看到这些行才能保持原有槽位复用语义；过滤使连续 day20 总兵力1→4、驻军0→3、军饷141819→158220，违反连续运行不变。过滤已删除，不能再作为修复方案。

Climate Freeze 目前登记环境版本并检查 generation/day；改变环境捕获或 writeback 顺序必须同时对照 FIFO 游标、提交日和黄金链。

### R2 军事与传输继续态规程

不得在 `military_for_each_lot_ordered` 全局过滤 inactive 行：变更型查找依赖原链复用行为。PKMI2要保持原槽位payload、链、free-list与generation，不能按派生人数重建。新增读取跨日累计列（例如实物收入）必须进入checkpoint比较。Host内部编号与外部指定编号分开保存，不得用混合journal最大值替代原游标。ACK barrier的请求、回执与发布水印也属于继续态。

开发期格式升级必须明确拒绝旧版，更新fixture、逐字段/字节往返和无关段比较；当前新增为PKMI2、ECP2 59与PKSR5。失败恢复保持候选安装。定向入口 `military_index_continuation_test.gd`；矩阵的military20及military365逐日比较≥8日，不能只检查快照人数或命令准入。默认矩阵加入这两项，逐项耗时见收尾记录。

最终验证记录见current-state的R2 L1–L5表。默认矩阵现为5场景（含军事20/365），较旧三场景增加约133秒；`--full`为9场景。本轮默认总796.8秒。凡修改lot索引/复用、军饷传输、事件游标、累计收入或编号恢复，必须运行military20、military365及完整checkpoint比较，不只看当前人数。旧版明确拒绝，不能用排序后比较或重建当前人数替代原始链。


## R3 / S29：请求与提交边界切片

详见 [R3实现、请求清单与保留债务](s29-resolve-apply.md)。本轮三个已有请求队列共享契约，军事最后两处Country直接写改走现有所有者端口；十二域写声明与三个实际Apply入口增加护栏。未改阶段顺序或存档格式。Ideology宽泛错误软完成与Effect忽略错误已收紧；启动/ACK兼容仍保留，不宣称全域soft-complete消除。四个文件型诊断只接受绝对路径，测试前后检查新增非源码文件。R3最终批次（修复兼容债登记后）已完成：生产构建和财政 probe 构建均 exit 0；静态护栏全过（size 920 文件 0 违规；C++ 496 引用键/484 债务键、header_exposed=518、total=2210、Country direct writes=0；Resolve/Apply 3 队列/3 Apply 入口 0 违规；架构单测 24 项）。主链 runs=3、外部 runs=2 均 first_difference=None。默认回归 exit 0，耗时 807.05 秒；full 矩阵 7 场景 exit 0，410.73 秒；annual exit 0，83.58 秒；military-annual exit 0，91.41 秒。默认回归含 61 个日志项及保存续跑/矩阵/年度检查。

新增请求先登记resolve_apply_contracts.json，复用既有保存队列；不得重复分配请求身份或改变排序字段。Apply入口变更须审查允许写的所有者成员与只读输入；新增软完成原因需解释真实等待依赖并加入反例。运行 `check_resolve_apply.py` 与 `test_architecture_guards.py`。诊断开关须传绝对文件路径，不能写 `PK_SIM_DAY_TRACE=1`；测试产物全部放指定日志目录，新增非源码文件会令默认回归失败。


## R4 / S30：宿主生命周期与 C++ 存档段契约

本轮把关闭、取消和释放流程提取到 `scripts/game/world_runtime_lifecycle.gd`。`WorldRuntimeHost` 仍保留原公开入口、信号、状态所有权和 Web 回退；组件只通过 host 引用执行原顺序。host 7010→6970 行。冻结检查 18 项、WorldSession 29 项、准备测试 15 项通过；完整 host ≤3000 行目标尚未达到，生成主流程、日调度和存档装配仍保留在 host，继续列入 R4。

新增 `tools/ci/cpp_save_section_contracts.json` 与 `check_save_section_contracts.py`。12 个域登记 owner、tag、当前版本、写入/恢复证据和恢复依赖：Climate/CLM2 v9、Country/PKCN v14、Economy/ECP2 v59、Military/PKMI v2、Trigger/PKTR v6、Effect/PKEF v14、Modifier/PKMD v3、Ideology/PKID v14、Family/Technology 的所属段、Host/PKSR v5、Annual/PKAR。契约检查拒绝缺版本拒绝证据、恢复顺序倒置和未登记域；Family/Technology/Annual 目前是所属段委托，未另造第二套存档格式。

本轮没有改变存档字节、公式、调度顺序或五条黄金链。Economy cpp 7989 行和额外读边迁移未开始，作为后续 R4 切片。


### R4 最终验证（2026-11-05）

构建 exit 0。静态护栏：921 文件、0 违规；依赖 496/484、`header_exposed=518`、`total=2210`；开关95、视图9、存档契约2个脚本 owner+12个C++域、模块12/9、跨域31对、Resolve/Apply 3/3、架构护栏25项。主链3/3和外部2/2均 `first_difference=None`。默认回归 exit 0，61个测试日志及保存/回放/金样检查通过。`check_replay_matrix.py --full` 为9个场景36进程，`--annual`和`--military-annual`各4进程，全部 `valid=True; first_difference=None`。

宿主生命周期抽取后的 host 为6970行；`economy_runtime.cpp`仍7989行。完整 host≤3000和经济文件收口未完成，列入后续R4切片。工作区相对起点新增文件全部为源码、测试或文档，未新增非源码游离文件。

## R4b 拆分规程（已核实）

宿主和大型 C++ 实现必须按“提取一组、冻结参照、比较测试、串行构建、主链三次”推进。宿主组必须保留公开方法签名、信号发出点和调用顺序；C++ 成员迁移必须逐词元比较，新增实现文件不得超过现有文件棘轮。跨域头若因拆分需要聚合，只能放在私有实现 include 中，并在依赖基线登记来源；`header_exposed` 与 `total` 不得上升，未登记依赖必须失败。

本轮实测：宿主 6,970→2,955 行；Economy 主文件 7,989→1,974 行，四个 residual 文件均低于 1,800 行。

### S31 最终验证证据

拆分后的公开 Host 入口必须用 Host 绑定的 Callable 传给信号和存档服务；组件自身方法不能作为未绑定回调。该规则由本轮回归暴露并修复。最终主链、external、默认回归、full/annual/military-annual 矩阵均通过。
