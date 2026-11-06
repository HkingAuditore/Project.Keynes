# 迁移状态

核查日期：2026-11-05。本页写迁移目标各项做到哪一步、怎么验收的、还剩什么。今天的源码事实见 [current-state.md](current-state.md)。

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
| 保存续跑保真 | 默认 5 场景、full 9、annual、military-annual 全绿 | 非零军队/战争的 365 日读档 | 其他种子/平台、实际占领、任意日内命令位置 |
| 宿主与大文件拆分 | `world_runtime_host.gd` 2955 行；`economy_runtime.cpp` 1975 行 | 逐词元证明 | `country_runtime.cpp` 11463、`map_generator.gd` 22547 行仍超限 |
| 黄金回放 | 五条链不变 | 每次提交前验证 | 投影不是完整十二域状态 |

## 推迟项（已决定推迟，不是遗漏）

- **表外推进者的同日对齐**（军事、资源恢复等按日进日表）：等上游合并之后再做。上游正在改 `world_runtime_host.gd` 和军事时序，现在做会大面积冲突。实验开关与检查器已在（`check_external_day_alignment.py`）。
- **Web 回退第 2 步**：Web 正式执行器定为“worker + 原生 inline”，删除 GDScript 每日回退和 `PK_WEB_ALLOW_GDSCRIPT_DAILY_FALLBACK`。删除前要先把依赖同步/SHADOW 配置的测试迁走，并有一次 emcc 构建的真实浏览器验证；本机没有这个环境。
- **多种子与战争覆盖（R5）**：军事没有行为测试是用户决定，先只做解耦。
- **D+1 军事维护费的收款方/销毁/只统计**：玩法决定，等军事设计完成。

## 最近一次完整验证

每个迁移提交前都跑了：构建、静态护栏全过、黄金五链 `--runs 2` 末日摘要不变、默认回归全过（60 项）。保存续跑矩阵的 full/annual/military-annual 在 R4b（提交 `569b36e8`）收尾时全绿，之后的提交只改包含与调用写法，由默认回归里的矩阵覆盖。

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
