# 世界运行架构：接入与验证记录

本记录对应世界运行架构改造，以 `1de2d472` 为改动前对照。提交 PR 前与上游整合的结果单独列于文末。
设计与实际迁移范围见 [世界运行架构](world-runtime-design.md#13-实际接入状态)，扩展方法见
[开发指南](development-guide.md)。以下通过结果不代表所有平台、所有界面或全部旧测试通过。

## 已接入并验证的功能

- 一局游戏由独立的 `WorldSession` 管理。开局、读档、重建、返回菜单和退出使用同一套关闭顺序。
- 新模块先登记依赖和数据归属，准备完成后才开放模拟；取消会唤醒准备中的等待，释放按依赖逆序执行。
- 模拟停止采用实际退出确认；故障状态或接受停止请求都不能冒充资源已释放。
- 在途计算保留原数据归属，停止新工作不会把经济事务切回旧国家副本。
- 18 个现有保存模块不仅登记依赖，读写、解析、恢复及恢复后准备也迁入独立适配器；装配层每次调用才提供所需接口，旧总控实现已删除。
- 时间控制独立于界面，直接由时钟通知执行者；绑定跟随会话创建/解除，旧世界不能控制新世界。
- 真实扩展样例验证准备/关闭顺序，另一保存样例验证保存后修改状态、读档后恢复原值。

## 本机验证

环境：macOS arm64，Godot 4.6.3；运行检查使用无画面模式及调试原生库。
调试与发布原生库均已构建成功；发布库没有被冒充为本次运行测量使用的库。

| 检查 | 结果 | 本机证据 |
| --- | --- | --- |
| 最终导入、11 个针对性脚本 | 276 项断言，0 失败 | `/tmp/keynes-architecture-accepted-v2-summary.log` |
| 真实开局→保存→载入→继续结算→正常退出 | 49 条通过断言，0 失败；包含扩展状态及旧世界关闭确认 | `/tmp/keynes-architecture-accepted-v2/game_save_roundtrip.log` |
| 最终线程隔离与重启执行域恢复 | 30 + 53 项检查，0 失败，0 退出泄漏报告 | `/tmp/keynes-architecture-final-native-summary.log` |
| 上述所有进程退出 | 0 ObjectDB、Resource、RID 泄漏报告；检查器不豁免这些报告 | `/tmp/keynes-architecture-accepted-v2/` |
| 调试原生库构建 | 通过 | `/tmp/keynes-session-final-debug-build.log` |
| 发布原生库构建 | 通过 | `/tmp/keynes-session-final-release-build.log` |
| 执行范围隔离的独立内存检查 | 256 次停止/事务交接，另含线程、世界、嵌套及异常退出隔离 | `gdext/tests/runtime_execution_context_test.cpp`；ASan/UBSan 本机已通过 |
| 线程句柄回收的独立内存检查 | 256 次销毁交接及 128 次重启 | `gdext/tests/runtime_thread_retirement_test.cpp`；ASan/UBSan 本机已通过 |

重跑主要检查：

```sh
python3 tools/ci/run_regression_checks.py --godot /opt/homebrew/bin/godot \
  --import --roundtrip --log-dir /tmp/keynes-runtime-validation
```

应先完成原生库构建，再运行检查。不同配置的 SCons 构建共用中间文件，不能同时运行。
已加入 GitHub Actions 工作流，但本机结果不等于远端 Linux 工作流已经执行。

连续运行也在最终会话接入后执行：正式开局，32×24 地图、种子 20260718、50 倍速度、
5 天预热、请求 50 个样本，2 个国家、初始人口 80。CSV 实际 50 行，必需字段齐全；
账目失败 0、人口/钱/物资差额均为 0、`fatal=false`，退出无泄漏报告。
生成耗时 5433.8 ms，测量循环 725.5 ms，等待推进 5 次，经济内存 24,707,103 字节。
本次没有触发贸易订单、路线扩展或关税结算，不能作为贸易场景通过的证据。

并行推进使观测次数与提交天数不同：测量记录为 46 次观测、52 个提交日，
按提交时点计算为 85.273 日/秒。它是小地图调试库测量，不是发布版或图形性能承诺。
原始数据在 `/tmp/keynes-session-continuous/perf.csv`、`headless_session.json`，
日志在 `/tmp/keynes-session-continuous.log`。更早的 30 样本试跑得到 31 行，
不满足精确行数要求，未计入通过记录；本次未修改记录器或截断 CSV。

## 经济重启故障的证据与边界

旧故障已在资源释放改动之前的脚本快照中复现：第 16 天出现
`money_conservation_failed`，国库读回开局值、国家物资重复加入。
停止新工作会撤回执行许可，而在途事务原先也据此改选了旧国家副本。
公共执行上下文使一次计算从开始到结束使用相同的数据归属；不再用可变线程句柄判断执行身份。

修复后，在接入世界会话之前独立重复的六轮重启测试均为 29/29。
世界会话接入后的最终完整检查中，原样重启测试也是 29/29；没有删除断言或延长等待门槛。
原始复现日志为 `/tmp/keynes-restart-pre-lifetime-1.log`，六轮复核位于
`/tmp/keynes-architecture-restart-1/` 至 `/tmp/keynes-architecture-restart-6/`。

另一次集成检查与发布库编译同时进行时，遇到 `country_worker_peer_stall_timeout`，
为 24 项检查、8 个失败；日志保留在 `/tmp/keynes-session-integrated-summary.log`。
编译结束后的独立复核及最终完整检查通过。争用可能触发既有的 5 秒等待门槛，
但这些结果不足以证明争用是唯一原因，也不证明所有等待问题都已消除。

## 开局和界面失败的修复

上一阶段用独立工作区在 `1de2d472` 复现的开局 6 项、界面 6 项失败均保留历史证据。
本轮已处理其原因，不再把这些失败作为架构改造的未完成项：

| 原问题 | 原因与本轮修复 |
| --- | --- |
| 开局粮食建筑没有经营者 | 拾柴与采集共用职业，按建筑排序分配时，拾柴先占走了粮食生产所需人员。开局明确声明 `building_owner_fill`，原生层先验证并执行该分配，再进行一般匹配；每国仍为 40 人，保留地区创始家族身份。 |
| 小窗口财政列表被挤出窗口 | 固定头部占满高度；紧凑布局改为整个财政内容共用一个外层滚动区。 |
| 卷宗在刷新、隐藏或重开后丢失阅读位置 | 隐藏容器归零及迟到的恢复回调相互覆盖；在隐藏前记录，显示后恢复，并拒绝覆盖较新的切章/滚动操作。 |
| 50 倍运行停在剧情日期 | 测试没有处理正式剧情选择；现通过玩家选择和结果确认继续，不清锁或循环强制恢复时间。 |
| 军事按钮和科技树断言过时 | 军事现已开放，只有外交禁用；科技树使用一个共享效果节点，检查改为验证该节点及跨日对象身份。 |
| Escape 暂停断言偶发失败 | 原测试用整段运行之前的暂停值与最后状态比较；现确认面板已打开，在按键调用前后比较暂停值，独立核对关闭动画结果。 |

开局经营者断言保留，新增反序输入及无效人员分配检查。卷宗检查使用 640×480 的实际可滚动页面，
要求初始阅读位置大于零；没有把“内容刚好放得下”时的零位置相等算成滚动保留。
保存模块边界检查覆盖独立实现、接口收窄、恢复时重新取依赖、拒绝越界写入/解析和私有摘要输入。

历史证据：`/tmp/keynes-session-followup/`、`/tmp/keynes-start-fixture-cleanup/`、
`/tmp/keynes-architecture-baseline-logs/`；临时对照工作区已清理。
开局与长期检查自行创建的未入树时钟现在显式释放。

## 旧模块接入后的连续运行

`starter_settlement_soak_test.gd` 已改用正式世界会话、日输入和后台提交结果。
默认 40×28 地图、种子 20260727、玩家加 3 个外国，完整运行 3650 日；逐日读取对应日期的
经济结果，人口、资金、物资差额全为 0，全部数值有限。第 60/730/3650 日快照检查通过，
最终关闭成功：21 项检查，0 失败，0 退出泄漏报告。
证据：`/tmp/keynes-legacy-soak-frame-service-summary.log` 及同名目录中的详细日志。

迁移测试时发现并修复了正式路径上的第 591 日停顿：理念实例刷新/派生重建请求了
主线程服务，后台因此让出执行，但宿主仅在下一次日更新里重试；日历等待后台提交，
形成互相等待。宿主现按帧继续原日期的未完成阶段，完成后停止调用。
科技效果仍经过真实执行与确认，没有人工回复或超时放行。
9 项定向检查覆盖日期阻塞、分阶段继续、完成后空闲及下一天重新执行。

失败过程保留：`/tmp/keynes-legacy-soak-production-v3-summary.log` 是上述真实停顿；
更早的 `keynes-legacy-soak`、`-v2`、`-v3`、`-production`、`-production-v2` 等试跑包含
旧测试入口失效、把未来研究待办误作当日完成条件、取样字段与年度额外推进等测试驱动问题。
`/tmp/keynes-legacy-soak-v4/` 的旧同步混合路径曾停在 Effect `RESYNC_REQUIRED`；本轮没有
证明该诊断路径已修好，也没有把它计入正式 3650 日通过结果。

## 本轮旧模块迁移的最终回归

下表是旧保存实现、时间控制、开局经营者、界面滚动以及逐帧收尾全部接入后的结果；
上面的 `keynes-architecture-*` 保留为前一阶段证据。

| 检查 | 结果 | 本机证据 |
| --- | --- | --- |
| 项目导入、17 个针对性脚本 | 720 项检查，0 失败；其中正式开局 265 项、界面 126 项 | `/tmp/keynes-legacy-accepted-summary.log` |
| 真实保存→载入→继续结算 | 49 条通过断言，0 失败 | `/tmp/keynes-legacy-accepted/game_save_roundtrip.log` |
| 上述 19 个进程 | 全部退出码 0，0 脚本错误及退出泄漏报告 | `/tmp/keynes-legacy-accepted/` |
| 调试、发布原生库 | 两种配置分别构建成功，均有 `scons: done building targets.` | `/tmp/keynes-legacy-debug-build.log`、`/tmp/keynes-legacy-release-build.log` |

检查器同时检查进程状态、脚本错误、失败断言和退出泄漏，不把 Godot 的零退出码单独当作通过。
新增脚本的 UID 齐全，`git diff --check` 和 Python 检查器语法检查通过。

补充专项检查：资源显示 60 项、理念运行 92 项、民意/协同 24 项、内容 67 项、
效果实例 51 项、停止后执行域恢复 53 项全部通过，退出无泄漏。
`ideology_effect_override_test.gd` 的 25 项断言通过，但其故意提交非法堆叠上限会打印
`effect_catalog_ideology_effect_parameter_max_stacks_invalid`；严格日志检查因此判失败。
未把这条预期错误悄悄豁免为整组通过，也未改变其业务断言。

上一阶段扩大范围时，`building_runtime_test.gd` 有 58 项失败，
`economy_test_bootstrap_test.gd`（可选测试经济数据生成）有 6 项失败。
在独立 `1de2d472` 工作区使用原脚本及原生库对照，两套失败名称与数量逐项相同；
理念非法覆盖的日志也相同。当时它们未修复；本次经济接口整理已处理 58＋6 项，
最新结果见下方经济专项记录，不能再把这段历史对照读成当前未完成清单。
基线导入及经济测试原有资源泄漏也保留记录；当前版本这几项没有退出泄漏。
本机证据：`/tmp/keynes-legacy-domain-summary.log`、
`/tmp/keynes-legacy-domain-baseline-summary.log`、
`/tmp/keynes-legacy-domain-baseline-comparison.json`。

## 真实图形资源的关闭检查

图形检查额外发现 `VisualTileHorizonBaker._cleanup()` 只释放资源句柄并清空设备变量，
没有销毁自行创建的本地图形设备。无画面测试不创建该设备，因此此前无法覆盖此问题。
当前清理同时释放设备；取消时先等待已提交的 GPU 工作完成，销毁路径也使用同一个
静态释放方法。`visual_tile_horizon_smoke_test.gd` 在 Metal 上验证正常计算的输出和接缝、
计算中取消、未完成准备时销毁；通过弱引用确认设备确已销毁，退出没有泄漏或脚本错误。
证据：`/tmp/keynes-legacy-gpu-lifetime-v4.log`。

桌面界面测试同时改为等待自动加载完成后创建场景，并在结束时等待会话关闭再销毁场景。
macOS 的窗口模式切换可能在准备调用内部处理帧，单纯 `call_deferred` 或等待一帧不够。
初次启动失败日志为 `/tmp/keynes-legacy-graphical-ui.log`、`-v2.log`；
实际设备泄漏在 `/tmp/keynes-legacy-graphical-ui-v4.log` 中有 `RenderingDevice` 对象证据。

最终 Metal 实际窗口检查通过 143 条断言，包含正式场景、七张截图、50 倍连续运行、
640×480 的国库滚动到实际条目、阶层阅读位置 40→40、Escape 及正常关闭。
实际大窗口截图为 2940×1846；不是把系统全屏尺寸标成 1280×720。
截图位于 `/tmp/keynes-legacy-ui-captures-final/`，已查看大窗口经济概览、小窗口国库顶部、
滚动后的国库条目和阶层页面。日志 `/tmp/keynes-legacy-graphical-ui-final.log`：
退出码 0、0 脚本错误、0 ObjectDB/Resource/RID 泄漏报告。
最终脚本也再次以无画面模式通过 129 条断言，0 退出泄漏；
`/tmp/keynes-legacy-ui-final-summary.log`。该次含新增可达条目和会话关闭检查，
剧情选择次数随图形/无画面运行时点不同，检查数不能当作完全相同的固定用例数比较。

## 尚未覆盖及保留的迁移边界

Web 实机与 Linux 工作流尚未执行。图形模式检查的具体范围另列，不能据此宣称所有窗口与所有分辨率已验收。
本次已收窄经济与主机/存档/记录文件的交接，拆分测试开局的外部读取与计算。
其余原生大类、旧总控内部展示方法、生产与部分域诊断模式的进一步分离仍保留在迁移清单中；
纯聚落规划叶模块约 1550 行是已记录的大小例外。业务算法没有被整体重写。
经济中途保存尚不具备完整恢复状态，现明确拒绝；完整结算边界的保存恢复单独验证。


## 经济专项与大型接口整理（2026-11-04）

原 58＋6 项失败的修复包含业务错误与测试前提漂移，两类不能混为一谈：

| 范围 | 修复或明确的契约 |
| --- | --- |
| 就业与收入 | 首次招聘先计算生活成本；报价与实际招工使用同一工资基础；经营者收入按真实已结算收入，实物收入只计一次。 |
| 停业与恢复 | 用真实投入亏损建立停业场景；恢复报价考虑可回岗人员携带的储蓄，实际招工与生产仍核对真实现金。 |
| 当期物资 | 周期内服务在保留经营者自用后过期，丢弃量纳入账目；补贴接收量避免重复计数。 |
| 投资 | 本周期准备和完成同一批到期评估，不把旧候选列表带入新周期。 |
| 继续运行 | ECP2 精确整数资源不再被浮点副本覆盖；恢复前次降雨观测，避免持续降雨被当成新事件。 |
| 测试开局 | 可选科技按任一满足解锁；地区人口分配遵守物理容量，输入复制后不持有活动世界。 |
| 测试内容 | 显式声明家庭需求、硬投入、建材、资金及真实来源岗位；不再依赖正式内容中某项旧配方或固定工资。仍核对真实就业、债务和人口/钱/物资总量。 |

扩展检查还发现：StageOps 的分批需求准备使用前一天日期，现由共同入口提前更新日期，保留 Track B 并核对逐日完整状态。
物资测试按当前 PKEC 59 及本轮冻结的企业需求检查库存周期；出生测试使原成人有真实商人岗位，避免其既有存款混入新生失业人口。
重启检查等待 `simulation_executor_exited`，不把停止请求当作线程已退出。

中途 ECP2 检查揭露了旧能力声明不成立：此前只保存游标，补足已提交基底后实际恢复会崩溃。
现拒绝中途导出、活动周期替换及旧 resume 片段；检查拒绝不修改状态、继续计算与对照相同，结算完成后能正常保存恢复。
这修复了危险接口，但不宣称实现完整中途保存。复现保留在 `/tmp/keynes-domain-extra-v18/economy_cadence_runtime_test.log`。

内部接口落地：`EconomyAuthorityTransfer`、`EconomyInvariantProbe`、`EconomyRecordSource` 与复制 `Batch`，
以及开局的输入/策略/规划/资金四模块。无主机或文件写入器对经济类的整类友元权限；
CSV 仍为 25，PKEC 59、ECP2 ABI 3/schema 54，不靠改格式掩盖状态恢复问题。

最终调试库检查：

| 检查 | 结果 | 本机证据 |
| --- | --- | --- |
| 导入及 13 个经济脚本 | 全部通过；建筑 517 条通过断言、物资 246 项、周期 131 条通过断言；测试开局 120 周期人口 31→33、失业 5→0 | `/tmp/keynes-domain-final-economy-summary.log` |
| compact / StageOps 逐日对照 | 60 天、370 项检查，完整状态一致，人口/钱/物资账目均无差额 | `/tmp/keynes-domain-final-economy/runtime_economy_stage_ops_soak_parity_test.log` |
| 17 个会话/开局/界面/生命周期脚本 | 全部通过，含真实停止重启 29 项和按帧继续 9 项 | `/tmp/keynes-domain-final-session-summary.log` |
| 真实保存→载入→继续 | 通过，载入后完整结算仍非故障 | `/tmp/keynes-domain-final-session/game_save_roundtrip.log` |
| 正式世界连续 3650 日 | 40×28、种子 20260727、4 国；21 项检查，逐日账目和数值有效性通过，60/730/3650 日取样通过 | `/tmp/keynes-domain-final-soak-summary.log` |
| 以上 33 个进程 | 全部退出码 0，0 失败断言、脚本错误及退出泄漏报告 | `/tmp/keynes-domain-final-gates.log` 与上述目录 |
| 调试库构建 | 成功 | `/tmp/keynes-domain-debug-v20.log` |

默认检查器与 CI 现包含这 30 个脚本及补充的原生交接检查，共 31 个脚本，`--roundtrip` 再加真实保存载入；
本地按经济与会话两组执行，清单逐项核对一致。长程与真实图形仍单独执行。
补充原生交接检查 `runtime_authority_m5_m6_gate_test.gd` 通过，覆盖新提取的资金/债务探针与
旧 resume 输入安装前拒绝；证据 `/tmp/keynes-domain-final-native-summary.log`。

发布库构建成功：`/tmp/keynes-domain-final-release-build.log`。性能测量在 Godot 4.6.3
无画面编辑器进程中明确将 macOS debug 映射临时指向 release 原生库；执行完成后逐字恢复映射。
原生库路径、SHA-256 及恢复确认见 `/tmp/keynes-domain-final-release-perf/native_build_evidence.json`。
这证明使用了发布原生库，不代表整个游戏已导出为发布应用。

正式开局，32×24、种子 20260718、50 倍速度、5 天预热、2 国、初始人口 80：
CSV 准确 50 行，实际提交 50 天，每秒 63.559 天，达到该检查的 50 天/秒门槛。
生成 5820.4 ms，测量循环 888.0 ms；等待推进 5 次，后台故障/退回旧路径均 0，
经济内存 24,167,021 字节，人口/钱/物资差额均 0，退出无泄漏。
SUS 每样本平均/p95/最大 0.695/4.600/8.779 ms，最大单次分片的平均/p95/最大为
0.446/0.869/0.920 ms；这是小地图无画面数据，不是图形帧率或大型世界性能承诺。
本次未发生外国贸易订单、路线扩展或关税结算，不作为贸易压力测试。
证据：`/tmp/keynes-domain-final-release-perf/perf.csv`、`headless_session.json` 及
`/tmp/keynes-domain-final-release-perf.log`。

首次测量得到 51 行，严格数量检查拒绝。原因是已经收满 50 行后，测试程序仍发布一次迟到采样。
修复后只在请求样本尚缺失时发布最后回调，且 expected_rows 对照请求值；没有截断文件或重写真实样本。
失败日志和 51 行文件保留在 `/tmp/keynes-domain-final-release-perf.log-first` 与
`/tmp/keynes-domain-final-release-perf-first/`。

最终真实 Metal 窗口检查：143 条通过断言、0 失败、0 脚本错误和退出泄漏。
覆盖 50 倍运行、640×480 国库滚动、阅读位置保持、Escape 和会话关闭；实际大窗口为 2940×1846。
7 张截图在 `/tmp/keynes-domain-final-ui-captures/`，已查看经济总览与小窗口滚动后的国库条目。
日志 `/tmp/keynes-domain-final-graphical-ui.log`；进程和严格错误核对在
`/tmp/keynes-domain-final-visual-gates.log`。未执行 Web 实机或远端 Linux CI。

## PR 提交前的上游整合复核（2026-11-04）

全部本地改动先保存于 `2df19a33`，并包含此前未推送的 `1de2d472`；随后合入
上游 `0fa5a071`。保存协调器、世界宿主、测试 UID 和玩家开发文档的冲突已处理，
保留上游保存起始格/种子校验、失败详情和军事/建筑界面，以及本次会话关闭与保存模块边界。
下列结果来自合并后的实际代码，不以之前的检查替代。

| 检查 | 结果 | 本机证据 |
| --- | --- | --- |
| 导入、默认 31 个脚本及真实保存载入 | 33 个进程全部通过；1435 条通过断言，0 失败断言、0 退出泄漏报告 | `/tmp/keynes-pr-integration-regression-summary.log` 及同名目录 |
| 正式世界 3650 日 | 两次均为 21 项业务检查通过；第一次退出有 ObjectDB 警告，详细复跑未再出现，见下方限制 | `/tmp/keynes-pr-integration-soak-summary.log`、`/tmp/keynes-pr-integration-soak-verbose.log` |
| Metal 实际窗口 | 137 条通过断言、0 失败、0 脚本错误及 ObjectDB/Resource/RID 泄漏报告；7 张截图，已查看军事页及 640×480 国库滚动结果 | `/tmp/keynes-pr-integration-graphical.log`、`/tmp/keynes-pr-integration-ui/` |
| 地图作者工具 | 16 项通过 | `/tmp/keynes-pr-authoring-tests.log` |
| 原生执行范围与线程回收 | ASan/UBSan 下通过 256 次停止交接、256 次销毁及 128 次重启 | `/tmp/keynes-pr-native-lifetime.log` |
| macOS arm64 调试库 | 构建成功 | `/tmp/keynes-pr-integration-debug-build.log` |
| macOS arm64 发布库 | 构建成功，构建期间未运行 Godot | `/tmp/keynes-pr-integration-release-build.log` |

**仍需跟踪的退出提示：**首次 3650 日进程虽然全部业务断言通过、退出码为 0，
检查器仍因一条 `ObjectDB instances leaked at exit` 将该次执行判为失败。
相同代码、配置的 `--verbose` 完整复跑未出现 ObjectDB/Resource/RID 泄漏；没有修改代码
或放宽检查规则。首次原因尚未定位，不能用一次成功复跑宣称已彻底排除偶发泄漏。
详细模式另输出 44 个（长程）及 50 个（图形）未回收 StringName 名称，保留在原日志。

图形断言数量从之前的 143 变为 137：合入新的剧情节奏后，实际剧情选择检查由 7 次变为 1 次；
仍执行原界面检查脚本，没有移除断言。发布库性能 63.559 日/秒仍只对应上游整合前的测量；
合并后的版本未重新测量性能。Windows/Web 未在本机重建，远端 Linux CI 以 PR 检查为准。
