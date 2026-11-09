# 迁移状态

核查日期：2026-11-09。本页写迁移目标各项做到哪一步、怎么验收的、还剩什么。今天的源码事实见 [current-state.md](current-state.md)。

迁移目标：让 AI（和人）改一个模块时只读这个模块和它依赖的接口头，多个模块可以并行改，契约稳定，由护栏机检。约束：不改玩法、数值、调度顺序；五条黄金链不变；开发期不保证旧档兼容。

## 各项状态

| 能力 | 状态 | 已有 | 未做 |
|---|---|---|---|
| 模块公开接口 | Economy、Country、Modifier、Military 完成（外部包含者均为 0） | 4 个契约、6 个共享头，`check_module_api.py` 机检引号与尖括号包含 | Effect、Trigger、Ideology、Climate 尚无接口头；Country 的 `country_core*`/`country_ai_*` 未锁 |
| 宿主端口 | Economy、Country 完成 | 所有者文件包含宿主头为 0，宿主一个类实现两个端口 | 其他模块仍直接持有宿主 |
| 军事解耦 | 完成（不含行为测试） | 核心只依赖 `military_bridge.h`；适配层经接口头访问 | 军事自身请求队列未进共享契约；推进仍在主线程 |
| 依赖棘轮 | 默认检查 | 30 域对、`total=2181`、`header_exposed=519` | 文本检查，不是 C++ 名称解析；25 个域对待逐函数语义核查 |
| 已提交视图 | 9 条 | 副本 + generation/day，绕行反例 | 未迁移读边见 current-state |
| 请求与提交 | 共享入队与顺序键（4 队列）、3 个 Apply 入口检查 | Country 直接写 0 | 全域统一去重、全调用树写集合、全域事务/回滚未做 |
| 冻结输入 | Climate、Country、Economy 登记 | `RuntimeFrozenInputVersion` | Climate 仍在 day plan 前提交 |
| 存档段契约 | 12 域登记 | 版本、恢复依赖、旧版拒绝证据 | Family/Technology/Annual 是委托段；候选安装仍分散 |
| 后台 / inline 保存和命令交接 | 共用保存服务与命令排序，恢复命令接入两种执行方式 | 116 项检查：四种存读档组合、未来命令、重复保存、未完成日、容量拒绝及故障反馈 | 真实浏览器 Web 验证仍未做 |
| macOS arm64 交付库 | debug、release 均从当前源码重编 | 指定 release 库实载，PKSR v5 与 116 项存读档检查通过；新增独立检查入口 | 完整导出及其他平台未验证 |
| 保存续跑保真 | 默认 4 场景、full 8、annual 全绿；military-annual（military365）受已知问题影响不稳定，已移出默认集 | 非零军队/战争的 365 日读档 | 其他种子/平台、实际占领、任意日内命令位置 |
| 宿主与大文件拆分 | `world_runtime_host.gd` 2955 行；`economy_runtime.cpp` 1975 行 | 逐词元证明 | `country_runtime.cpp` 11463、`map_generator.gd` 22547 行仍超限 |
| 黄金回放 | 迁移提交五条链不变；合并上游 c849f255 后按维护流程重录 v2–v5（v1 不变，见 current-state） | 每次提交前验证 | 投影不是完整十二域状态 |

## 推迟项（已决定推迟，不是遗漏）

- **表外推进者的同日对齐**（军事、资源恢复等按日进日表）：原定等上游合并后做，上游 c849f255 已于 2026-11-06 合并，可以开始。实验开关与检查器已在（`check_external_day_alignment.py`）。
- **Web 回退第 2 步**：Web 正式执行器定为“worker + 原生 inline”，删除 GDScript 每日回退和 `PK_WEB_ALLOW_GDSCRIPT_DAILY_FALLBACK`。删除前要先把依赖同步/SHADOW 配置的测试迁走，并有一次 emcc 构建的真实浏览器验证；本机没有这个环境。
- **多种子与战争覆盖（R5）**：军事没有行为测试是用户决定，先只做解耦。
- **D+1 军事维护费的收款方/销毁/只统计**：玩法决定，等军事设计完成。

## 最近一次完整验证

2026-11-09 保存与命令交接修复，macOS arm64 / Godot 4.6.3，无界面验证：

- debug、release 串行构建成功；实际加载 release 库，保存版本为 PKSR v5，116 项针对性检查全过。暂停后台的保存通知与既定存档命令容量的反例也已纳入检查；超容量明确失败，保留全部命令，处理后可以重新保存。
- 理念用例失败的原因是同步等待时没有接收后台新结果，读到旧显示状态。测试改为运行正式结果接收流程，并核对真实的完成回执；主要用例独立复跑及完整回归均为 91/91，事务状态 320/320、保存基准与生成途中 460/460。原有日期与逐格精确比较保留，未放宽预算或重新生成黄金基线。
- 11 项静态护栏通过（包含 31 项护栏反例）；黄金五链各重复 3 次，均与现有基线一致。
- 默认回归 60/60 脚本通过；CLM2 v9 精确往返、10 日保存续跑、默认 4 场景、16 日及真实 365 日自动保存全部通过。扩展保存矩阵 `--full` 8/8，通过场景的 original/replay/checkpoint/resume 四条轨迹均无差异。

证据：`/tmp/keynes-architecture-fix-full-regression`、`/tmp/keynes-architecture-fix-replay-full`、`/tmp/keynes-architecture-fix-golden`、`/tmp/keynes-architecture-fix-golden-external`、`/tmp/keynes-architecture-fix-release-runtime-verified`。本轮未做完整导出、真实 Web 浏览器、其他平台或新的性能对比。

历史验证：各迁移提交曾完成构建、静态护栏、黄金五链 `--runs 2` 和默认回归。合并上游 `c849f255` 的提交（2026-11-06）另跑了保存续跑矩阵：`--full` 8/8、`--annual` 通过、`--military-annual` 不通过（见已知问题）；并用 ASAN 构建跑过默认回归和 military20，无报告。

### 性能对比（2026-11-05）

迁移前 `a712203f` 与迁移后 `5b40019a` 用两个检出交替运行，各 6 次：无界面 `headless_perf_record.gd`，300 日，speed=50，seed=20260718，60×40，3 个外国，无人口缩放与关税。12 次全部 `fatal=false`、`ledger_failures=0`、300/300 行；退出码均为 9，即吞吐门槛未过，两个版本相同。

| 指标（6 次中位数） | 迁移前 | 迁移后 | 差 |
|---|---|---|---|
| `run_ms` | 11140.7 | 11113.1 | −0.2% |
| worker 执行总时间（ms） | 6215.0 | 6231.3 | +0.3% |
| 每日 worker 执行，均值 / p95（ms） | 20.79 / 21.76 | 20.84 / 21.79 | +0.3% / +0.2% |
| 每日最大值（ms） | 27.4 | 23.5 | 噪声 |
| 主线程 `sched_proc_commit_ms` 均值 / p95 | 2.198 / 2.319 | 2.232 / 2.354 | +1.5% |

结论：模拟总耗时和每日 worker 耗时都在噪声内。主线程提交在 6 次里稳定高约 0.03 ms/日（1.5%），推测来自端口虚调用和转发函数，绝对值可忽略。只测了这一组参数和 macOS arm64；大地图、多国家、图形模式没有测。脚本做法见 [development-guide.md](development-guide.md#性能验证)。

## 历史

各阶段（E1–E3、S3–S31、R1–R4b）的过程记录、根因分析和当轮数字已从本目录删除，需要时看 git 历史中 `569b36e8` 及之前的 `docs/architecture/`。迁移提交从 `a712203f` 之后开始：

| 提交 | 内容 |
|---|---|
| `569b36e8` | R1–R4b：契约检查的模块架构、存档段契约、宿主拆分、Economy 主文件拆分 |
| `8755e817` | 外部模块经 `economy_api.h` 访问 Economy |
| `0ffb2d99` | 去掉经济文件里不用的宿主包含 |
| `1b5cb71b` | `EconomyHostPort` |
| `64d7685b` | 四个 residual 经济文件按职责命名 |
| `6f7f6ae3` | 军事适配层经接口头访问其他模块 |
| `007acdf2` | 经 `modifier_api.h` 访问 Modifier |
| `eeb9809b` | 经 `country_api.h` 访问 Country |
| `5b40019a` | `CountryHostPort`；Modifier 外部包含者清零 |
| 合并提交（2026-11-06） | 合并上游 `c849f255`（军事、建造/投资/采购/仓储、UI）；补回丢失的建造提交哈希行；修上游问题（Track-B 待审格子表未存档导致读档分叉、官营建筑审查列表堆越界写、兵营建军时就业未对账、分摊审查计数口径、anchor carry 缺花括号）；修 R1–R4b 宿主拆分误改的字符串与回调（Trigger ACK 键 `effective_day` 等）；重录黄金 v2–v5 |

## 已知问题

- **军事年度自动存档受时序影响**：第 365 天的 Effect→Country 命令是在年度存档检查 Effect 空闲之前还是之后到达，取决于实际运行时间。先到时，存档要等的 ACK 只有下一个游戏日才会来，等到超时就放弃、下一年再试（上游在 `game_save_coordinator.gd` 里写明的取舍），两次相同运行第 366 天后的状态也不同。`check_replay_matrix.py --military-annual` 因此不稳定，military365 已移出默认集。根治要让存档带上在途的 Effect→Country 事务，涉及 PKEF 与 Country 存档契约。
- **一条 Country 命令失败会拒掉同一天的其他命令**（上游）：Country `plan_day` 遇到任一失败命令就整天失败，军事的国家命令和 Effect 镜像共用 producer 0。军事场景里国库货物不够扣时，Effect 的研究信号发现大多被拒（`country_treasury_goods_insufficient`），只能反复重发。“只拒失败来源的批次、其余重新规划”能修好发现，但会让 military20 续跑受时序影响（6 次里 5 次 TRIGGER_INPUT 不一致），所以未合入。要先查清被拒回执的发布时机与军事回执轮询的先后。
- **R1–R4b 拆分的字面量损伤**：拆宿主时 `host.` 前缀被加进了字符串和注释，合并时已对照拆分前源码批量恢复（脚本做法：去掉 `host.` 后能在原文件找到、而带前缀的原文不存在的字面量才改）。以后再做机械拆分，要在拆分提交里就跑同样的比对。
