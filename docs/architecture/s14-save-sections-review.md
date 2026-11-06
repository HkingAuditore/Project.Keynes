# S14 模块存档段设计评审

S14原为设计评审；**S16已实施CLM2 v9，其他业务段字节未改**。开发期不保证旧档，旧版本明确拒绝。版本以2026-11-04工作区为准。下表区分 PKSV provider 的版本、内部格式版本、内容身份；同一个整数不能跨这三层比较。保存续跑实验的结果另见 current-state.md 的 S14 记录。

## 当前字节归属与兼容矩阵（源码事实）

路径未写前缀的 C++ 文件均在 `gdext/src/`，脚本均在 `Project/project-keynes/scripts/`；`save_modules/` 简写指 `scripts/game/save_modules/`。

| 段/格式 | 所有者、写入/读取证据 | 当前写版本 / 可读范围 | 恢复依赖及跨段引用 |
| --- | --- | --- | --- |
| PKSV 外容器 | `game/save_repository.gd:140`组头、`:157`临时文件与回读后替换；`game/save_container_reader.gd:5,24`读取校验 | 容器2；拒绝1，不自动迁移 | 每段长度/SHA、provider manifest、行业内容版本；外容器本身不恢复业务对象 |
| PKSR / simulation_runtime | `native_simulation_host_persistence.cpp:97`解析、`:943`起捕获各域；`game/save_modules/simulation_state.gd:11,32`选择原生bundle/字典与恢复 | provider2；原生bundle2、domain ABI1（`pksr_bundle_header.gd:32`） | 环境、PKCM、时钟在前；读取ECP2副本用于已知64MiB截断恢复，不能当任意坏档修复 |
| PKCN | `country_runtime.cpp:10245`encode_save、`:10435`decode版本、`:11360`begin_save/`:11449`end_restore；`save_modules/country_state.gd`适配 | provider11；内部14，读取11/12/13/14 | Country catalog与格数/国家handle；内嵌Country Modifier；Economy/军队/AI/视野引用国家；worker CPD2还包含canonical PKCN |
| PKEC 分块流 | `economy_runtime_persistence_codec.h:15,81`帧；`economy_runtime_persistence_write.cpp`写各section；`economy_runtime_persistence_read.cpp:40`读取 | 当前59；读取56/57/58/59 | 行业/物资/家族/人物目录、国家schema及Modifier、家庭/人物、订单、交易、继续游标；不是独立PKSV顶层provider |
| ECP2 | `runtime_economy_ecp2.h:14`、`runtime_economy_ecp2.cpp:386,478`编解码；`economy_runtime_persistence.cpp:1923,2040`校验/捕获；`save_modules/economy_state.gd:12,32`适配 | provider向当前库协商；内部schema54/ABI3；仅显式迁移开关允许schema53/ABI2 | 包含PKEC派生域blob、OwnedState、可能的epoch resume；PKCN/PKMI/PKEF先恢复；建筑目录供后续视野校验 |
| PKCM / PKGP（片段名） | `save_modules/rules_state.gd:17,39,46`分别调用Modifier domain0/domain3；`modifier_runtime.cpp:2546,2606`编解码 | provider3；**字节魔数实际PKMD、版本3**，不是PKCM/PKGP | 目录hash、domain、日期、实例handle/定义版本；Country/Economy还内嵌各自Modifier，不能重复安装或先清后丢 |
| PKTR | `trigger_runtime.cpp:1592,1680`、`trigger_runtime.h:25`；`rules_state.gd:62,69` | provider6 / 内部6，仅当前 | journal事件、国家/经济/规则目录，待处理命令与生产者身份；journal先恢复 |
| PKEF | `effect_runtime.cpp:7590,7749`、`effect_runtime.h:49`；`rules_state.gd:85,92` | provider11 / 内部14，仅当前 | 实例、激活顺序、事务、候选及Country/Economy回执；先于ECP2，让SETTLING事务可交叉核对 |
| PKID | `ideology_runtime.cpp:7182,7383`、`ideology_runtime.h:75`；`rules_state.gd:108,115,128` | provider2（可读1/2）/ 内部14，仅当前 | PKTR/PKEF/ECP2/PKGP先恢复；execution_contract_hash独立于schema，还包含目录与规则身份 |
| PKMI | `military_core.h:41`、`military_core_save.cpp`编解码；`save_modules/country_state.gd` | provider向库协商 / 内部1 | 国家/领土及player_context；军事资金通知/军队身份；不得借分段改变D+1维护费语义 |
| PKAI | `country_ai_runtime.cpp:412,428`编解码；`save_modules/country_state.gd`适配 | provider1 / 内部PKAI2，仅当前 | PKCN/ECP2与player_context；AI记忆和未完成殖民请求 |
| PKFG | `save_modules/vision_state.gd:31,64` | provider4，可读1–4 | 格数、探索进度、建筑intel；PKCN/ECP2/PKGP在前，完整验证后安装探索列 |
| journal / PKAR / PKNR | `save_modules/history_state.gd:10,28,45`；年报`annual_development_ledger.cpp:229,236`编解码 | journal4（可读1–4）、年报PKAR1、叙事provider1（Variant字典，不是原生PKNR魔数） | Country/Economy/视野与事件身份；本轮不声称审计所有字段的旧版迁移 |
| dynamic_world / environment / world_clock / player_session | `save_modules/geography_state.gd`、`clock_state.gd`、`player_state.gd` | provider分别1、2（可读1/2）、1、1 | 配置、地理、环境继续态、时间及玩家视角；先建地图，再恢复环境/时钟，玩家最后 |

`world_state_modules.gd:11–38`是实际恢复依赖表；`:151`附近指定simulation_runtime额外读取ecp2，PKMI/PKAI额外读取player_context。这不是C++十二域的执行次序。

PKSR内部另有CLM2、CPD2、MDF2、TPD1、EVT1、GMP1、EFP1、IDP2、D7T1、经济POD/ECP2。封装/验证入口见`native_simulation_host_persistence.cpp:307–835`；CLM2当前版本9、只接受9，包含RNG/历史环/日期/代数与目录身份（`runtime_climate_authority.cpp:28,620,660`）。这些内部段与顶层兼容对象的片段存在重复，不能简单一域一文件地拆除。此评审没有声称每个POD内部子格式的历史版本均已跑过真实旧档。

## 建议沿用现有 provider，而非第二套登记（仅设计）

`world_state_modules.gd:64`已提供provider id、section集合、schema、restore_after、context capability和独立codec；`runtime_module_registry.gd`检查重复所有者与依赖。足以承载C++模块的**薄适配器**：provider只调用C++所有者的冻结/验证/安装接口，仍由同一coordinator组织。

建议先增加只读的“模块→现有section/嵌套范围”描述并验证唯一归属，不挪字节。现有C++每日描述符仅有reads/writes文字，不要把它当成熟存档API。真正拆出内部子段时再由provider引用新schema，避免同时存在两套顺序图、两套迁移开关。

## 必须评审的契约（尚未实施）

1. **跨段引用**：稳定handle必须携带所属模块、generation/内容身份；国家、cohort、建筑、人物、效果事务先完整验证再链接。保留当前原始整数编码时可先做只读一致性检查；增加字段属于新字节格式，需新授权。
2. **恢复次序**：按现有provider依赖创建候选世界，先配置目录/地理，再安装所有者，最后重建引用/缓存并开启worker。不得用主线程兼容对象替代worker权威的恢复证据。
3. **在途intent**：Country `begin_save`拒绝未完成资产事务（`country_runtime.cpp:11366`）；ECP2有resume flags/继续态（`runtime_economy_ecp2.h:51,84`）；Effect保存事务状态。它们不是统一“任意时点可存”。初期保留当前安全边界；未来跨日预留须同时保存请求身份、双方prepared/applied/ACK、冻结金额与幂等水印，先决定崩溃后重放或取消，不能凭超时退款。需要新schema和授权。
4. **内容身份**：schema、catalog hash、execution contract与行业revision分别校验。禁止仅因schema相同接纳不同规则；迁移开关只控制已明确的版本变换，不能把未知目录当兼容。
5. **失败原子性**：PKSV先临时写、完整回读、rename；这是文件层保证。coordinator逐provider恢复后遇错即return（`game_save_coordinator.gd:304`），**不等于世界级回滚**。目标是在未激活的候选会话验证/安装，全部成功才交换owner；失败丢候选、保留原世界。实现此交换须独立评审资源/线程生命周期。
6. **开发期版本策略**：用户已决定不保证旧档。格式升级时明确拒绝旧版本，错误带期望/实际版本；不静默填中性值。既存其他reader支持范围按表保留，本轮只收紧CLM2。每个新版本保留真实当前writer生成的金样；合成旧版本仅用于验证拒绝，不冒充兼容金样。

## 金样存档计划（CLM2单个金样已实施，其余未开始）

| 金样 | 生成时点/来源 | 必须验证 |
| --- | --- | --- |
| 当前最小世界，首次完整结算 | 任何字节改动前固定种子/目录；保留二进制与commit身份 | PKSV及所有原始section SHA/长度，恢复即时逻辑摘要，再继续同命令日志 |
| 非空税收/采购/科研/军饷事务 | 各现有专用用例的安全边界；预留未ACK另存“应拒绝”的证据 | 金额/回执/去重、守恒、保存拒绝不能留下半档；军费维护口径不顺改 |
| Effect SETTLING、Ideology执行契约、Country未来命令 | 已能合法保存的状态；不允许状态应保存拒绝日志 | 双方事务引用、日期、水印与内容hash，重放不重复应用 |
| 家庭/人物/大地图/大于64MiB ECP2 | 当前writer，及真实旧截断档 | 完整非截断长度、恢复继续态、已知截断恢复只在准确条件触发 |
| 历史PKSV2及支持的内部旧格式 | 从实际发布构建收集，保持只读 | 兼容矩阵逐格PASS/明确拒绝；显式迁移生成新槽，不覆盖原件 |
| 坏checksum/缺段/错catalog/中途失败 | 复制金样到scratch再定点损坏 | 拒绝原因、无部分激活、无旧档损坏、无线程/资源泄漏 |
| Web/桌面相同逻辑轨迹 | 有工具链机器另行生成 | 明确区分字节级跨平台承诺与逻辑摘要承诺，不能由macOS推定Web |

每个金样清单记录：种子、完整命令日志、保存日/相位、内容与运行库身份、原始容器和每段SHA-256、恢复后流SHA、逐日摘要。**原始流比原始流，恢复后流比恢复后流**；已知Modifier snapshot_version恢复自增不得清零掩盖。若重编码本就不同，应保留首个差异偏移与语义说明，不能泛化忽略某个字节区间。

审查门：先获得旧档窗口、在途请求策略及schema变更授权，再实现一段；使用同一组金样比较旧writer/新writer、旧reader/新reader及保存续跑。当前五条黄金链保持原样，它们不证明上述金样矩阵全覆盖。真实Web闭环仍需用户在有emcc的机器上验证；回退删除第2步未开始。


### S14实验存档字节证据（非金样全集）

本轮改前/改后checkpoint的21个顶层片段中，20个原始解压字节SHA-256完全相同，包括PKSR、ECP2、PKCN、PKEF、PKID、Modifier。world_clock唯一区别经解码为`rng_seed/rng_state`：该headless夹具的WorldClock._ready本来随机化，未触发年度漂移；这不是格式变更，也不能声称整档逐字节相同。证据`/tmp/keynes-arch-phase1/stage14/saved-section-comparison.json`与`clock-byte-differences.json`。未来正式金样应显式固定时钟RNG初态；本轮发现恢复差异后没有调种子、删字段或修改存档来让结果相等。


## S15评审记录（下方S16实施与版本政策已覆盖旧提案）

**已验证而非计划：** 第2提交日的CLM2保存成功，但未存`_distribute_soil_scratch`、`_round_out.insolation_now/dev/heat_input`和`_weather_field_init_scratch`；这些在后续kernel中实际跨天使用。dynamic_world同名列存在却不是该提交的权威值，不能视为冗余备份：519格soil不同、1120格weather_field_init为0而worker为1。Environment段亦没有这些权威列。出处与控制实验见[current-state S15](current-state.md)。这不是仅漏掉可由地理重算的缓存。

**S15原提案（S16已实施，见文末）：** 由Climate owner在原提交点保存这些必要续跑列和有效性；优先放入PKSR的CLM2新版本（S15时为8，S16已升9），保留形状、有限性、校验及内容身份。诊断缓存/耗时不进段。盘点conv_inhib、weather/stage_b计数、hydrology累积等后再决定完整字段集合；本用例conv_inhib为空，不能据静态风险声称它已导致实测分叉。动态镜像可继续保存兼容数据，但恢复后必须从同一提交版本投影，避免两份所有者。

另一个备选是先使已有dynamic_world列在保存边界等于真实worker提交，再从其恢复extras；它未必需要增加字段宽度，却仍改变保存内容及一致性契约，并需解决未包含的跨天状态、读档前缓存和未来旧档识别。S15没有实施，也不宣称现有档可无损补齐。

| 版本组合（S16状态） | 处理 |
| --- | --- |
| CLM2≤8旧档→新reader | S16已实施明确拒绝，错误含expected_9/got_X；不再保留降级选项 |
| CLM2 v9→新reader | 已实现校验后安装与恢复后捕获；气候八日一致，全域仍未通过 |
| 新CLM2→旧reader | 按版本明确拒绝，不能伪标为8或自动去掉尾部 |

金样增补计划：保存第2日后继续到4日（本轮现有红样保留）；天气首次初始化前/后各一份；非零对流抑制、非零soil/积雪/水文、weather/stage_b节拍边界、物理环流冷/热缓存各一份。每份保留owner列、镜像列、各段原始字节与摘要，比较不中断/保存不中断/新进程读档，不只验证writer-reader往返。**金样全集未完成；CLM2 v9及单个金样已在S16实施**。年度clock RNG另测；本轮固定RNG未消除分叉，Modifier版本未改也可让Climate对齐，两者不是本四日实验的必要原因。


## S16落地与原评审差异

仅CLM2升9，magic/位置/原store摘要不变；新尾部保存owner已提交继续态及11个主线程气候输入节拍游标。完整字段/大小/读写点见current-state S16表。原先建议旧版降级已撤销：开发期不保证旧档，旧版本明确拒绝。未改其他reader的既有版本支持面。

固定日2金样`tests/runtime/fixtures/climate_save_v9/`已入工作区，CLM2载入立即重存逐字节相同（1,901,228B），八日Climate相同。比改前库仅CLM2变化，31个非气候比较单元相同；PKSV封装长度/压缩/checksum随之改变。没有承诺全档重编码相同或完整续跑通过：Events/Trigger/Ideology仍存在经济发布继续态缺失；完整checker保持红。

后续经济段建议同时保存指标发布三列与上一日class opinion快照，包括其日/版本/分组统计/已发布缓冲选择。需在PKEC分块编码、ECP2候选安装两条路径都验证，不能只补一条或恢复时调用有发事件副作用的publisher。应各升内部版本并明确拒绝旧版；本轮未实施，也未修改economy_runtime.h。缺失字段本身已确认，是否能完成小而完整的修复仍待具体方案与金样，不能凭“允许升版”跳过原子恢复检查。

未覆盖金样：非零conv_inhib/雪/可选水文、季节刷新/年度边界、任意worker计划失败后的保存。继续态数组长度/有限性/校验在reader验证，但不等价于这些场景已动态验证。维护费语义、Web默认worker和29份待决定文档未动。


## S17实际落地：ECP2发布继续态

在用户已授权的小范围变更内，ECP2 schema54→55，OSOA1→2，必需块8保存经济指标发布三列和上一日已提交意见快照；具体字段见module-boundaries的S17表。PKEC59及所有其他模块格式不变。与原提案不同：本轮没有同时扩展独立PKEC导出，因为正式完整存档以ECP2为权威，块8在候选验证和安装位置恢复，无需改 `economy_runtime.h` 或另造一套保存登记。

| 版本/验证对象 | S17结果 |
| --- | --- |
| ECP2 53/54→新reader | 明确拒绝，包括显式hash迁移模式；native self-test覆盖 |
| ECP2 55 / OSOA2块8 | 局部解码校验后才安装，备份恢复包含同一块 |
| 同日改前/改后完整PKSV | 只有顶层ecp2、PKSR/ECP2改变；ECP2内原有其他domain与OSOA块1–7相同，envelope只变schema字节54→55 |
| 块8即时重存 | 1,167字节相同；CLM2仍1,901,228字节相同 |
| 完整PKSV重编码 | 不承诺幂等，既存Modifier等差异未被抹去 |

既有 `fixtures/climate_save_v9/day2.pksv`重新生成以包含ECP2 55；CLM2内容SHA和八日轨迹不变。manifest同时记录publication长度/SHA。开发期不保证旧档，旧版本明确拒绝；不保留旧ECP2金样作为兼容承诺。完整续跑仍需处理兼容Country哈希、军事冷查询和资源节拍；不能因八域通过宣称所有字段保真。


S17重编码限制进一步量化：旧、新ECP2均有envelope 10字节、AUDIT 160→232B、MODIFIERS 1字节、OSOA旧块7的1字节变化（另有派生hash变化）。因此本轮承诺的是新块8和CLM2精确往返，以及改前/改后其他段逐字节相同；不承诺整份ECP2幂等。`ecp2-existing-roundtrip-differences.json`保留未归一化的对照。完整checkpoint仍失败，需继续核查兼容Country/资源/军事，不用新金样的部分通过替代全部保真。


## S18落地：兼容输入与资源owner分段

评审新增两类必须保存的状态：经济实际借用的非权威Country副本，以及资源float integrator继续态。前者保存在原CPD2段尾部（公开ABI2不变，原保留字升为payload revision1）；后者在原ECP2 OWNED_STATE新增OSOA3块9，ECP2 schema55→56。没有另建provider登记，也不把它们塞进CLM2。PKCN14/PKEC59/CLM2v9保持原格式。

| 兼容矩阵 / 金样 | 当前证据 |
| --- | --- |
| CPD2 payload revision0 | 明确拒绝`country_checkpoint_payload_version_mismatch_expected_1`；独立C++测试重新计算checksum后验证旧版拒绝，截断亦拒绝 |
| CPD2 ABI2 / revision1 | canonical PKCN和兼容PKCN分开；整个CPD2编解码逐字节往返，兼容PKCN跨世界恢复即时重存50,562B相同 |
| ECP2 53/54/55、OSOA≤2 | 明确版本拒绝；native ECP2自测包含55 |
| ECP2 56 / OSOA3（S18历史证据） | 块1–8与改前同日存档逐字节相同；块9为283,412B，加载立即重存相同；候选校验长度/有限值/日期/标志后才安装 |
| 同日改前/改后PKSV | 32个比较单元中29个不变；仅CPD2及两份ECP2改变。PKSR固定头、CLM2、其他模块片段不变 |
| 完整续跑 | 同种子/命令第2日保存，第3–10日八域、整体经济hash、军事、资源全部相同；严格checker退出0 |

既有`fixtures/climate_save_v9/`按同一轨迹更新为新格式，保留CLM2原SHA与原块8SHA；manifest新增资源块/兼容PKCN长度和SHA。完整ECP2/PKSV即时重编码仍有已记录的旧AUDIT/Modifier等差异，不承诺整文件幂等；新字段逐字节稳定。开发期不保证旧档，旧版本明确拒绝。

未完成：独立PKEC继续态、季节/年度边界、多国/非零军队、在途业务请求的金样全集和统一全世界恢复原子性。已有一个完整用例转绿，不是这些场景已经验证。29份待决定未动。

## S19 影响

新增续跑矩阵只读取现有保存段，不改变 schema。独立测试分别验证 PKMI 的待处理维护费（建筑夹具）及 PKEC/PKCN 的非零军饷在保存边界后投影一致；尚未证明非零军队完整PKSV新进程恢复和去重历史；没有新增字节。Events 读边只复制已提交视图，不改变存档格式。

## S22 实际落地

ECP2 57/OSOA3块10保存就业冷却（原记录顺序、cell/source/target/until_day）；PKSR3保存经济事实生产序号和Trigger转发id/序号；environment provider3追加天气发布返回码。各自的旧版本明确拒绝，CLM2v9、CPD2 revision1、PKEC59不变。其余28/32比较单元及ECP2旧块1–9逐字节不变；详细证据见[S22记录](s22-annual-continuation.md)。当前方案仍使用已有provider登记，没有另建第二套保存注册。

年度证据扩大到保存364/365/366并各续跑8日；不是完整生命周期/所有地图/战争保存证明。只有新字段及指定继续态要求即时重存一致，不把既存整档重编码差异掩盖成幂等。


## S23 保存契约切片

Country与Economy provider新增相同的`archive_contract()`声明，包含id/version/sections/write/restore/readable_versions/restore_after；现有coordinator使用原Registry按依赖安装，没有第二套登记。业务I/O函数体不变；S22金样与S23同种子同日输出32/32比较单元逐字节相同，未改金样或格式（证据stage23/save-byte-final.json）。这不是全C++模块统一保存事务：其他provider及独立PKEC继续态仍按现有路径。

新增非零军队的20日/365日PKSV继续比较失败，见current-state；军队桥接游标、经济军队行与待征召回执必须作为下一批联合核对对象。已有零军队年度金样不能证明非零军事保真。

### R2 / L1–L3 已实施补充

PKMI2 section22保存含inactive的原始lot payload、索引链/空闲顺序与army继续态；军事provider以MDJ1保存事件转发游标，晚创建的日任务由facade一次性交接。ECP2 59/OSOA3 block12保存实物收入累计列；PKSR5/TCQ1保存Trigger传输请求/ACK/发布游标及Host自有请求编号。旧版本明确拒绝，原生ABI域号/公式/提交顺序不变。

实际年度保存点的索引74721字节、MDJ1 28字节、TCQ1 134字节与恢复后立即重存精确一致；365日保存续跑8日全域比较已通过。完整根因、逐字段证据和限制见[军事继续态记录](s26-military-continuation.md)。这没有代替R4的所有模块统一契约与候选安装。
