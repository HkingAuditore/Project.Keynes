# 迁移状态与验收

核查日期：2026-11-04。目标见 design.md；实际权威、只读摘要范围与已知差异见 current-state.md。S18按授权只扩展继续态保存格式，不改生产公式、执行位置、提交顺序、公共绑定、scheduler/slot id 或 ABI 常量；未执行 commit、push、add、stash、reset、checkout。

## 当前状态

| 阶段 | 状态 | 证据与剩余工作 |
| --- | --- | --- |
| A 核实现状 | 第一阶段已验收 | 十二域及表外推进的所有者/线程有源码证据；不是所有授权组合都实跑 |
| B 行数与依赖护栏 | 已接入默认入口 | S13当前889个源码文件、457类跨域引用键（522头暴露/2400总次数），静态护栏零违规；全部已迁移读取/写入禁止绕回旧方法 |
| B 最小黄金 | 第一阶段已验收 | 八日开局账目链 v1 保留；它不覆盖整局状态 |
| C 十二域模块表 | 第一阶段已验收 | 十二个 stage、表驱动与 static_assert；没有迁移数据所有权或气候前置提交 |
| D 文档重写 | 第一阶段已验收；用户又清理一批过程文档 | 保留目标/实现/证据的区分，剩余 29 份待定文档本轮未动 |
| E1 确定性修复 | 用户已验收 | 资源排除表边界修复、同日 Modifier 回写等待；v2 两组各十轮通过，用户又复跑 5/5；本轮改前入口 32 过/1 败，E2 改后 33/33 通过，失败边界见下文 |
| E2 每域黄金 | 七域投影接入并验证；不等于完整十二域覆盖 | 五轮候选后建立 v3，十轮正式比对、E2 改后默认回归 33/33；Country 整域因发现日期差异未入，其余四域尚无独立业务摘要 |
| E3 表外登记 | 登记、构建、十轮链比对、反例和最终默认回归通过 | 七条 C++ 可读描述，七字段/四追赶函数全登记；原执行位置保留 |
| S3-A Country 交接日期确定性 | 已验收的生产行为修正，追加 v4 | 交付入队先于主线程服务完成，ACTIVE Country 收件位于服务之后；v4 候选/正式/最终分别十轮，三条原链不变，见下文 |
| 后续：完整 tick/每域全状态回放 | 部分摘要已落地，其余未开始 | 补齐经济的建筑/家庭/人物/贸易等；加入非空玩家命令、保存恢复、不同分片/线程与跨平台检验 |
| S3-B 经济读取接口第一刀 | S3 已验收，头文件/全查询由 S4 接续 | S3 三个国库查询、16 处读取通过；S4 用户已授权头文件移位规则 |
| S4-A 头文件隔离 | 构建、分批黄金及 S4-A 回归通过 | 具体 Country include 移出经济头，私有 AI 数据定义移入实现；计数及新规则见下文 |
| S4-B 经济全部 Country 读取 | 27 查询/156 调用点接入，构建和十轮黄金通过 | 两批各三轮；原冻结/实时/保存兼容来源不变；最终回归结果见下文 |
| S4-C 写入 intent 原型 | 盘点/设计已写，原型未开始 | 全部 47 处写入保持；先考虑 FISCAL_RETURN，须补非空请求/拒绝/恢复等证据 |
| 后续：cadence 与存档分段统一登记 | 未开始 | 与现有保存/会话模块接通，并验证原格式恢复后继续 |
| 后续：军事/资源收归日表、退役 SHADOW | 未开始 | 需完整状态回放及主线程交接证据；登记本身不授权移动推进位置 |
| S5-A FISCAL_RETURN intent | 原型及本轮验收通过 | 复用已有协议，原调用点消费；非零返还、旧存档流与四链10/10一致，默认33/33→34/34 |
| S5-B 非生产路径退役 | 盘点已完成；删除未实施 | 候选仍可由公开配置/绑定打开或在生产使用；0行代码/0个测试删除，详见current-state.md |
| S6-A 采购与财政intent | 用户已验收 | 直接写46→34；既有非零用例与v1–v4通过 |
| S6-B 表外独立黄金 | 用户已验收 | v5军事政策与资源恢复真实变化；无士兵/军费覆盖 |
| S7-A 剩余Country写入 | 用户已验收；军事2处暂缓 | 分三组构建、各3轮主黄金/3轮v5、非零回执和保存用例通过；仅军事2处因覆盖不足暂缓 |
| S7-B 开关与故障登记 | 用户已验收 | 93环境键/135读取，46故障名/27调用；0裸读取/0动态例外；未删配置面 |
| S8-A Host机械拆分 | 本机构建、词元与回归验证通过 | 14888→480行，193个成员搬至17个≤1490行实现；最终主黄金10/10、v5 10/10、默认41/41 |
| S8-B 外围按日实验 | 测试专用、默认关闭；生产接入未开始 | 关闭/开启各3次逐日摘要相同；积压、军费/战争、读档和帧内可见性仍待验证 |

当前接续：S22四个目标已完成，实际验收与限制见文末S22及s22-annual-continuation.md。历轮的“等待决定/未开始”及版本号保留当轮实测含义，不能替代最新状态。维护费产品语义未动。

## E1 历史与本轮前置核验

E1 授权修复只在 `world_ext_resource_deposits.cpp` 两处直接索引前检查行宽。原始越界导致固定种子下资源初始化不同；逐帧 Modifier 回写还使旧整体经济读取日期不同。资源差异、文件行号与样例见 current-state.md。`economy_runtime.cpp:26111` 的 Modifier 字节排除范围缺陷继续只记录，未修。

历史证据位于 `/tmp/keynes-arch-phase1/stage2/authorized/`：`e1-candidate` 十轮一致，建立 v2 后 `e1-reviewed` 十轮一致；旧 v1 账目未变。上轮默认入口曾因外部提交 `d288b36d` 给 `runtime_climate_kernel.cpp` 增加一行而被护栏挡住。用户随后提交 `0fad85c0`，并将该文件基线从 3421 改为 3422；本轮保留此修正，没有修改该源文件或再次提高基线。

本轮所有证据根目录为 `/tmp/keynes-arch-phase1/stage2/e2-e3/`。改前命令：

```sh
python3 tools/ci/run_regression_checks.py --godot /opt/homebrew/bin/godot \
  --log-dir /tmp/keynes-arch-phase1/stage2/e2-e3/before
# before.log：32 PASS，1 FAIL；护栏零违规。
```

改前失败为 `runtime_economy_worker_restart_test` 的两条断言：K2s 卡牌仍 location=-1，重启后 simulation_committed_day 停在 14；报告为 RUNNING、mask=4079，没有 worker fault。交接摘要曾把该日志误记为 33/33，本轮重新统计原始 PASS/FAIL 行后更正，没有重写原失败日志。

已核实的测试边界：该用例继承 `ideology_worker_authority_parity_test.gd`；split 模式 `_drive_days` 是同步循环（`:980`），只有 ideology 被 worker 抑制时才等待 POD 推进（`:1058`），split 模式不满足该等待分支，随后立即读取卡牌位置（`:662`）和已提交日期（重启测试 `:25`）。因此这两个断言存在读在 worker 完成之前的窗口；**推断**这解释了该次间歇失败，未进一步证明调度器具体哪次唤醒导致它。E2 改后、E3 最终入口的同一测试均为 29 checks/0 failures；没有修改测试或生产权威切换代码，也不宣称修复了这个既存窗口。

## E2 实现与验证

新增 `native_simulation_golden.cpp`、`runtime_golden_diagnostics.h`、`world_ext_golden.{h,cpp}`；修改 Host/Trigger 的只读声明以及既有详细报告入口。新增 `.v2.json` 原样留存，当前 `golden_day_hash_baseline.json` 升为 v3；修改黄金脚本与 `check_golden_determinism.py`。没有新 Godot 绑定。

调试构建均在 gdext/ 串行执行：

```sh
scons platform=macos target=template_debug arch=arm64 dev_build=no -j8
```

`build-e2-fixed.log`、`build-e2-logical.log`、`build-country-trace.log` 均为 `scons: done building targets.`。保留两次初始失败记录：`build-e2.log` 漏 include variant.hpp，修正后通过；`build-e2-retry.log` 误在仓库根目录调用，未找到 SConstruct。这些失败未被写成构建通过。

八域候选 `domain-candidate` 第 2 轮失败；Country 从第 5 日起不同。只读数值列探针 `country-probe` 五轮暂时相同，随后 `country-probe-more` 第 5 轮再次失败。具体字段与原因见 current-state.md，原始失败日志及 `country-differences.json` 保留。Country 整域移出黄金清单但继续输出诊断；没有修改该域生产行为，也没有删除它的日期字段。

```sh
python3 tools/ci/check_golden_determinism.py --godot /opt/homebrew/bin/godot \
  --runs 5 --capture-candidate \
  --log-dir /tmp/keynes-arch-phase1/stage2/e2-e3/seven-candidate
# 5/5 一致，始终核对旧 v2 全部字段；随后建立 v3。

python3 tools/ci/check_golden_determinism.py --godot /opt/homebrew/bin/godot \
  --runs 10 --log-dir /tmp/keynes-arch-phase1/stage2/e2-e3/v3-reviewed
# 10/10，first_difference=null。

python3 tools/ci/run_regression_checks.py --godot /opt/homebrew/bin/godot \
  --log-dir /tmp/keynes-arch-phase1/stage2/e2-e3/e2-after
# e2-after.log：33 PASS，0 FAIL；黄金 190 checks，0 failures。
```

普通回归仍只运行一次黄金，不在默认清单里重复十次。按测试日志创建至最后写入的时间近似估计，改前黄金为 9.397 秒，E2 改后 9.472 秒，最终 9.521 秒；没有明显增加，但这不是严格性能基准。计时、报告代数、指针和 Godot 实例 ID 未入摘要；每个 scope 和遗漏数据明确写在 current-state.md。气候 ACTIVE compute_hashes 仍为 false，通过读取已提交 store 的独立诊断投影取得摘要。

## E3 实现与验证

新增 `tools/ci/runtime_advancers.json`、`runtime_advancers_baseline.json`、`check_runtime_advancers.py` 和 `gdext/src/runtime_external_advancers.h`；修改模块描述符头、默认回归入口及护栏测试。军事/资源/家庭/人物/视野与显示、气候回写各自的原始执行入口未动。

登记检查为 7 entries、7 fields、4 catchup methods、0 violations；四项护栏测试通过。`negative_advancer_check.py` 在 scratch 副本故意新增 `_runtime_unregistered_cursor`，CLI 输出 `unregistered fields: _runtime_unregistered_cursor`，exit=1；副本已删除，日志 `negative-advancer.log`。另以 `c++ -std=c++17 -fsyntax-only -Igdext/src .../descriptor_read.cpp` 验证 C++ 能独立读取七项及线程枚举，不依赖 Godot。

`build-e3.log` 的调试构建成功。报告入口补充保证：开关关闭时即使请求 detail=3 也不新增 golden_domains 字段；detail=0 没有新增计算/锁/环境查询。此改动只影响新诊断的关闭方式，未改业务函数。

```sh
python3 tools/ci/check_golden_determinism.py --godot /opt/homebrew/bin/godot \
  --runs 10 --log-dir /tmp/keynes-arch-phase1/stage2/e2-e3/e3-reviewed
# 10/10，三条链和 E2 基线完全相同，first_difference=null。
```

最终关闭开关检查：

```sh
python3 tools/ci/check_golden_determinism.py --godot /opt/homebrew/bin/godot \
  --runs 2 --legacy-only \
  --log-dir /tmp/keynes-arch-phase1/stage2/e2-e3/final-legacy-off
# 2/2 匹配保留的 v2 全部值及两条链；detail=3 报告也不含 golden_domains。
```

最终默认入口：

```sh
python3 tools/ci/run_regression_checks.py --godot /opt/homebrew/bin/godot \
  --log-dir /tmp/keynes-arch-phase1/stage2/e2-e3/final-regression
# 33 PASS，0 FAIL；黄金 190 checks，0 failures。
# 行数 824 文件、依赖 435 引用键、新登记检查均零违规；4 个护栏测试通过。
```

改前 32 过/1 败，E2 改后及 E3 最终均 33 过/0 败；不能把改前失败记成通过。不运行 release、其他平台、图形长跑；本轮证据不能证明这些场景通过。

## 三条末日链

| 契约 | SHA-256 |
| --- | --- |
| v1 账目（原值不变） | `2242b25110adb22d74a7ce175f8b6e0dce2ef2442741d3dc2a318efa8c7e28c2` |
| v2 整体经济（原值不变） | `30ea61f1e05f12b02d01ebe3aa1bf6060655e39663251100b4be8ae358db73d3` |
| v3 七域投影（新增） | `95aedaac2fd631d72657f0d27fbb04009d3ab489b577f3e7c59788ee25ab537a` |

## 文档保留与构建产物

第一阶段删除 74 份明确架构/过程文档，原清单仍在 `/tmp/keynes-arch-phase1/change-manifest.md`。用户又清理了 `docs/plans/ideology-review/` 中 16 份、`docs/project-cleanup-audit.md`、`docs/project-structure-reorg.md` 和两份旧实现计划；这些均为**已清理**，不再写回待决定。

本轮开始仍存在的 29 份待定文档按 SHA-256 留存于 `e2-e3/originals/preserved-documents.json`：含业务/公式混合说明、军事合同/设计和剩余 ideology-review 文件；本轮不编辑、不删除。更新 current-state、migration、module-boundaries、development-guide，并将 design.md 中过期的“当前只实现账目”一句同步为 v3 的实际范围。技术树、产业链、音频、UI/美术/地形、构建/导出说明未改。

已追踪调试库 `Project/project-keynes/addons/dots_ext/bin/macos/libdots_ext.macos.template_debug.arm64.dylib` 被构建重写，保留现场由用户处理；未暂存，未以版本还原覆盖其他人的文件。


## S3 验证记录（本轮）

证据目录 `/tmp/keynes-arch-phase1/stage3/`，源码初始副本及 29 份保护文档摘要在 `originals/`。先执行：

```sh
python3 tools/ci/run_regression_checks.py --godot /opt/homebrew/bin/godot \
  --log-dir /tmp/keynes-arch-phase1/stage3/before
```

实际 **32 PASS、1 FAIL**：`economy_worker_restart_day_test` 的 worker 重启断言返回 `runtime_worker_start_failed`，报告 STOPPED、committed_day=2、runtime_graph_not_ready。与 E2 当时的失败项名称不同，不能混用历史原因。未修改这个用例，不宣称已经修复它。第一次改后 `stage3/after` 为 **33 PASS、0 FAIL**。

所有构建在 gdext/ 串行运行 `scons platform=macos target=template_debug arch=arm64 dev_build=no -j8`。`build-trace.log`、`build-admission-fix-retry.log`、`build-country-final.log`、`build-read-view.log`、`build-final.log` 均以 `scons: done building targets.` 结束。`build-admission-fix.log` 是误在仓库根目录调用 SCons 的 exit=2（没有 SConstruct），随即进入 gdext 重跑成功；没有把该次失败计为通过。最终版本进一步把交接调整限定到 ACTIVE 请求 Country，OFF/SHADOW 保留原收件位置。

重复命令统一为：

```sh
python3 tools/ci/check_golden_determinism.py --godot /opt/homebrew/bin/godot \
  --runs 10 --log-dir /tmp/keynes-arch-phase1/stage3/<目录名>
```

| 目录 | 次数 / 结果 | 说明 |
| --- | --- | --- |
| country-before | 10/10 | 改前 v3 保持一致；Country 仍是排除域，本组没有复现它的两种取值 |
| admission | 2/2（参数 --runs 2） | 临时命令探针，两次都证实 requested/effective=3、实际接纳日=6 |
| admission-fixed | 10/10 | 初步修复后保留旧 v3，Country 命令均在第 5 日接纳，Country 摘要一致 |
| v4-candidate | 10/10（另加 --capture-candidate） | 候选逐日逐域相同，并每次核对旧 v2/v3；之后才建立 v4 |
| v4-reviewed | 10/10 | 不带命令探针，与 v4 基线完整比对 |
| read-view-reviewed | 10/10 | 迁移 16 处国库读取后，四条链不变 |
| final-golden | 10/10 | 收窄到 ACTIVE Country 的最终二进制，四条链不变 |

新增 Country 末日链为 `6786a230e8f9b5859c0f9baa13eefd65ec89976e3d1fd119a5131df35a3e8fef`。此前三条末日链逐位不变（见上表）；v1/v2 留存文件与本轮开始副本相同，新留存 `.v3.json` 与本轮开始主基线文件逐字节相同。

`c++ -std=c++17 -fsyntax-only -Igdext/src /tmp/keynes-arch-phase1/stage3/country-view-contract.cpp` 成功，验证小视图可单独使用且三个方法都返回整数、不依赖 Godot。护栏测试新增三种直接国库查询反例，现在共 5 项通过。S3-B 的 cpp 212 个引用行、56 组方法/类型/门禁，以及 h 的外域类型连接点已逐处分类。

S3 交付时仍未完成（S4 已接续）：`economy_runtime.h` 的 AI include 移除、依赖键数下降；严格逐文件基线尚未放宽，所有 `*_baseline.json` 保留用户原有修正。本轮没有展开 Country→Economy、命令/写入、税率/科技冻结快照、Modifier 哈希范围或表外推进调度迁移。剩余 29 份待决定文档不动；旧过程文档已清理事实保留。


最终收窄后的验证：`final-regression.log` 为 **33 PASS、0 FAIL**（黄金 175 checks、0 failures；少掉的是 E2 排除域的重复声明检查，v4 增加旧 v3 投影核对，Country 已进入结果）。`final-legacy` 使用 `--runs 2 --legacy-only`，2/2 与旧 v2 完全一致，detail=3 也不输出 golden_domains。护栏为 826 文件、435 依赖键、7 推进者、零违规，5 个护栏测试通过。保护文档 SHA-256 核对 29/29 未变；行数和依赖 JSON 基线与本轮开始逐字节相同，气候 3422 项保留。

S3 结束时等待澄清的方案仅存在于 `/tmp/keynes-arch-phase1/stage3/header-proposal/header-isolation.patch`，**当时没有应用到工作区**（S4 用户已授权，现已复核应用并继续收拢）：进一步迁移身份查询以撤掉 AI 实现对具体国家 runtime 的 include；公共头以不完整类型声明替代 AI 头，构造/清理转入拥有完整类型的实现；明确允许已审查的只读视图头/类型。`dependency-delta.json` 计算为 435→434 键、2404→2401 次，但有两条现有引用移入实现文件形成新键（AI 头、私有 Shared 类型），五项减少。因此它不能在当前严格逐文件只减政策下直接落地；本轮不把候选补丁当作 S3-B 已完成证据。

## S4 验证（2026-11-04）

全部日志根目录 `/tmp/keynes-arch-phase1/stage4/`。无 commit/add/还原操作；本轮期间 HEAD 保持 a712203f。没有外部提交引起的新基线冲突，气候 3422 项保留，未修改其源文件。旧过程文档已清理，剩余 29 份待决定文档 SHA-256 不变。

S4-A 不仅移除 include，也把私有 AI 数据完整定义移入使用它的实现；S4-B 的 27 种查询/156 个调用点全部转发原 const getter，包含叶实现、保存兼容和财政快照。47 处直接写入表达式及顺序原样。无新存档字段，无 ABI 常量或玩法公式修改。S4-C 只交付设计，没有新 intent 原型，不把已有资产队列算成本轮新增。

依赖口径纠正：初步候选只数受限依赖时为 525/2401/434；这**不是全部引用统计**。最终检查和基线把明确允许的只读接口也计入 header_exposed/total，真实前后是 **527→522 / 2404→2400 / 435→433**，域对 31 不变。433 包含 421 个受限键和 12 个接口键。六条增长键记录从 economy_runtime.h 移出的相同 include/类型及次数；纯新增具体 runtime 依赖仍失败。行数基线仅收紧本次缩短的既有条目，未提高阈值。

实际命令（构建 cwd=gdext，其余 cwd=仓库根目录）：

```sh
scons platform=macos target=template_debug arch=arm64 dev_build=no -j8
python3 tools/ci/check_golden_determinism.py --godot /opt/homebrew/bin/godot --runs 3 --log-dir /tmp/keynes-arch-phase1/stage4/a-golden
python3 tools/ci/check_golden_determinism.py --godot /opt/homebrew/bin/godot --runs 3 --log-dir /tmp/keynes-arch-phase1/stage4/b-scalars-golden
python3 tools/ci/check_golden_determinism.py --godot /opt/homebrew/bin/godot --runs 3 --log-dir /tmp/keynes-arch-phase1/stage4/b-snapshots-golden
python3 tools/ci/check_golden_determinism.py --godot /opt/homebrew/bin/godot --runs 10 --log-dir /tmp/keynes-arch-phase1/stage4/final-golden
python3 tools/ci/check_golden_determinism.py --godot /opt/homebrew/bin/godot --runs 2 --legacy-only --log-dir /tmp/keynes-arch-phase1/stage4/final-legacy
python3 tools/ci/run_regression_checks.py --godot /opt/homebrew/bin/godot --log-dir /tmp/keynes-arch-phase1/stage4/before
python3 tools/ci/run_regression_checks.py --godot /opt/homebrew/bin/godot --log-dir /tmp/keynes-arch-phase1/stage4/after-a
python3 tools/ci/run_regression_checks.py --godot /opt/homebrew/bin/godot --log-dir /tmp/keynes-arch-phase1/stage4/final-regression
python3 tools/ci/check_size_ratchet.py
python3 tools/ci/check_cpp_deps.py
python3 tools/ci/check_runtime_advancers.py
PYTHONDONTWRITEBYTECODE=1 python3 tools/ci/test_architecture_guards.py
c++ -std=c++17 -fsyntax-only -Igdext/src /tmp/keynes-arch-phase1/stage4/read-view-contract.cpp
```

| 证据 | 实际结果 |
| --- | --- |
| build-a / build-b-scalars / build-b-snapshots.log | 三次串行调试构建成功，`scons: done building targets.` |
| a-golden / b-scalars-golden / b-snapshots-golden | 各 3/3，四条链逐位相同 |
| final-golden | 连续 10/10，first_difference=null，无缺失域或异常 |
| final-legacy | 关闭逐域摘要，2/2 与 v2 相同 |
| before.log | 33 PASS / 0 FAIL，restart-day 通过 |
| after-a.log | 33 PASS / 0 FAIL，restart-day 通过 |
| final-regression.log | 33 PASS / 0 FAIL，restart-day 通过；黄金 175 checks / 0 failures |
| 静态护栏 | 826 源文件、433 引用键、7 推进者；8 项护栏测试；零违规 |
| read-view-contract.cpp | 无 Godot 头独立编译通过；视图大小为两个指针 |

| 保持的链 | 最终日 SHA-256 |
| --- | --- |
| 账目 | `2242b25110adb22d74a7ce175f8b6e0dce2ef2442741d3dc2a318efa8c7e28c2` |
| v2 整体经济 | `30ea61f1e05f12b02d01ebe3aa1bf6060655e39663251100b4be8ae358db73d3` |
| v3 七域 | `95aedaac2fd631d72657f0d27fbb04009d3ab489b577f3e7c59788ee25ab537a` |
| v4 Country | `6786a230e8f9b5859c0f9baa13eefd65ec89976e3d1fd119a5131df35a3e8fef` |

四份黄金 JSON 未改。S3-A 明确是生产行为修正：命令原定第 3 日，改前第 5/6 日生效，固定用例修复后第 5 日生效；不是只加测试等待。Modifier 哈希排除范围和既有 restart-day 等待窗口未改；军事/资源未移入日表。未验证 release、其他平台、全部玩家命令或全状态保存字节穷举，不能从八日黄金推断这些已通过。

构建影响的已追踪二进制仍为 `Project/project-keynes/addons/dots_ext/bin/macos/libdots_ext.macos.template_debug.arm64.dylib`，未还原或暂存。完整 S4 增量文件清单与差异存于 stage4 的 changed-files.json / s4-changes.patch。


## S5（财政返还原型与退役核查）

- **S5-A 已实现并完成构建/黄金/默认与专用验证**：FISCAL_RETURN 同步 intent 由 Country 在原提交位置消费；worker 复用原队列，无新增保存字段。实际直接写入47→46；依赖433键、header_exposed522、total2400未涨。调试构建 `stage5/build-final-a.log`；旧二进制两次非零返还/保存捕获与改后相同；四条既有链连续10次相同，证据 `stage5/golden-final/summary.json`。默认回归改前33/33、改后34/34（新增返还用例），均零泄漏；额外旧财政续跑测试改前改后同为4失败，详见current-state.md。
- **S5-B 盘点完成，代码退役未实施**：705行整日SHADOW、Ideology parity、Economy影子StageOps等仍可由公共配置/绑定打开；Events probe属于生产推进。没有符合全部条件的候选，删除代码0行、删除测试0个。主经济文件净减47行来自原型接入与54行辅助函数移出，不计作旧路径退役；Host未改。
- **未开始**：其余46处直接写入迁移、通用intent接口、公开诊断面收敛、军事/资源迁入日表。Modifier哈希排除范围和restart-day等待窗口仅记录，未修。保存/ABI/模式语义均未修改。
- 旧过程文档已清理；29份待决定文档仍保留，本轮逐文件SHA256核对未变。没有撤销用户外部提交或放宽无关基线。


## S6（更多资产请求与表外独立黄金）

- **S6-A 已实现**：采购5处、财政预留/征收及完成协议7处接入Country所有者端口；直接写入46→34。同原有worker队列共存但不双提交，同步路径原位置立即消费，不新增保存字段。两组分别串行构建，各3次四链比对；专用用例均对比本轮改前二进制的两次相同输出（非零金额、完整回执、原始及恢复后存档摘要），改后相同。
- **S6-B 已实现独立v5投影**：军事国家政策/资产概览、全地图资源储量/待处理列、家庭、人物、视野分别摘要。4天独立命令用例的候选10/10相同后才入基线；四份旧基线和旧用例均逐文件SHA256不变。军事/资源执行位置未迁移。当前军事无士兵、视野没有边界变化，完整军事/视野内部状态覆盖**未开始**；不能把投影测试称为全状态证明。
- **未开始**：剩余34处写入、Country→Economy迁移、军事/资源入日表、全面战斗/视野变化黄金。所选12处无需改变提交顺序，未回退任何条目；没有新“不可迁移项”。
- S5-B删除本轮未开展；公开配置/Web同步回退保留，产品决定待用户答复。旧过程文档已清理，29份待决定未动（SHA256与S5结束记录一致）。

S6命令（均绝对路径，构建与运行串行；每个日志目录独立）：

```sh
/Users/herh/.local/bin/scons -C /Users/herh/MyFiles/games/keynes/gdext platform=macos target=template_debug arch=arm64 dev_build=no -j8
/Users/herh/.local/bin/python3 /Users/herh/MyFiles/games/keynes/tools/ci/check_golden_determinism.py --godot /opt/homebrew/bin/godot --runs 3 --log-dir /tmp/keynes-arch-phase1/stage6/procurement-golden
/Users/herh/.local/bin/python3 /Users/herh/MyFiles/games/keynes/tools/ci/check_golden_determinism.py --godot /opt/homebrew/bin/godot --runs 3 --log-dir /tmp/keynes-arch-phase1/stage6/fiscal-golden
/Users/herh/.local/bin/python3 /Users/herh/MyFiles/games/keynes/tools/ci/check_golden_determinism.py --godot /opt/homebrew/bin/godot --runs 10 --log-dir /tmp/keynes-arch-phase1/stage6/final-golden
/Users/herh/.local/bin/python3 /Users/herh/MyFiles/games/keynes/tools/ci/check_golden_determinism.py --godot /opt/homebrew/bin/godot --runs 10 --external-only --capture-candidate --log-dir /tmp/keynes-arch-phase1/stage6/external-candidate
/Users/herh/.local/bin/python3 /Users/herh/MyFiles/games/keynes/tools/ci/check_golden_determinism.py --godot /opt/homebrew/bin/godot --runs 10 --external-only --log-dir /tmp/keynes-arch-phase1/stage6/external-final
/Users/herh/.local/bin/python3 /Users/herh/MyFiles/games/keynes/tools/ci/run_regression_checks.py --godot /opt/homebrew/bin/godot --log-dir /tmp/keynes-arch-phase1/stage6/before
/Users/herh/.local/bin/python3 /Users/herh/MyFiles/games/keynes/tools/ci/run_regression_checks.py --godot /opt/homebrew/bin/godot --log-dir /tmp/keynes-arch-phase1/stage6/after
```

已完成的旧链最终验证10/10，first_difference=null。末日值：

| 链 | SHA-256 |
| --- | --- |
| 账目 | `2242b25110adb22d74a7ce175f8b6e0dce2ef2442741d3dc2a318efa8c7e28c2` |
| v2 | `30ea61f1e05f12b02d01ebe3aa1bf6060655e39663251100b4be8ae358db73d3` |
| v3 | `95aedaac2fd631d72657f0d27fbb04009d3ab489b577f3e7c59788ee25ab537a` |
| v4 | `6786a230e8f9b5859c0f9baa13eefd65ec89976e3d1fd119a5131df35a3e8fef` |
| v5（独立用例） | `0f85a96f0e1a994ede564409e7e1bc5fdac282cbca2da42672da266f9b663c22` |

最终证据：

| 验证 | 实际结果 |
| --- | --- |
| build-procurement / build-fiscal.log | 两次串行debug构建均成功 |
| procurement-golden / fiscal-golden | 各3/3四链不变 |
| final-golden/summary.json | 10/10四链逐日逐域不变 |
| external-candidate / external-final | v5候选10/10后入基线，再10/10匹配 |
| external-strict/summary.json | 增加整图ACTIVE、守恒、资源列宽断言后的最终脚本10/10匹配，每次337检查0失败 |
| before.log / after.log | 默认34/34→37/37，零退出泄漏；完整改后清单先于上述新增断言运行，相同输入和基线的最终v5脚本随后单独十次验证 |
| 静态护栏 | 831文件；433键/421债务键/header_exposed522/total2400；直接写34；推进者7；11测试，零违规 |
| intent-contract.cpp | 无Godot头的接口头独立语法检查通过 |

额外最终v5命令与external-final相同，只把日志目录改为 `/tmp/keynes-arch-phase1/stage6/external-strict`。完整实际命令、初始采购用例前提失败与修正、完整回执/保存摘要在 `stage6/commands.md` 和 `verification-summary.json`。改前日志跨度约271秒；改后进程实测279秒，新增用例未明显拉长本次默认回归，但这不是严格性能测量。

没有修复既有restart-day窗口（本轮前后均通过）；财政续跑4项既存失败本轮未重跑，不作通过声明；Modifier排除范围未动。无删除、无commit/git add/还原他人改动。仅构建影响已追踪debug arm64 dylib，留给用户处理。


## S7 验收证据与下一步

本轮证据目录`/tmp/keynes-arch-phase1/stage7/`；起点HEAD为a712203f48663315620e9dc3dc6bd2fb2b3e1f49。改前默认回归37/37；源码与基线副本在originals，三个intent构建日志及各组主黄金/v5三轮摘要分别以transfers、research-spend、colonization命名。所有写入专用基线在相应路径重建前，使用该路径尚未迁移的二进制捕获两次一致结果；新增保存辅助只用于测试，没有改变保存代码。

当前仅剩军事reserve/collect两处白名单；并未证明必须修改顺序才能迁移，而是v5的零士兵用例不足以验证非零财政转移。补非零军费与保存用例**未开始**，军事/资源移入日表**未开始**，Web同步回退产品决定仍等待，任何旧实现退役**未实施**。Country→Economy迁移、Modifier哈希排除范围修正均**未开始**。既存worker等待窗口及财政续跑4项失败不在本轮修复范围；最终默认回归的实际结果单独记录，不把历史失败数当本轮实跑结果。

开关注册表只是集中名称和审计入口：既有静态缓存、解析与故障检查位置都保留。未做93种非默认配置的笛卡尔组合验证；裸环境访问和故障名字检查是文本护栏。GDScript仅盘点，尚未迁入C++注册表。

旧过程文档已清理，剩余29份待决定文档本轮未动。无外部提交引起的基线调高；size_baseline只收紧经济主文件26691→26688、就业文件3804→3802，后者是多行环境读取改为单行登记调用；不代表删除业务代码。

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


## S8 当前迁移状态

- S8-A：host机械拆分已落地，14888→480行；17个新实现最大1490行，辅助头426行；208个成员/37个辅助函数词元核对通过。三组均构建并各跑主黄金3轮、v5 3轮；首组缺少两个编码辅助函数的编译错误已通过原样复制修正，失败日志保留。数据所有权迁移未开始。最终主黄金10/10、v5 10/10和默认41/41通过，证据见下方。
- S8-B：仅测试宿主中的默认关闭实验已验证：开/关各3次，逐日逐类摘要等于v5。生产接入、批量积压、军费/战争与读档场景未开始；不建议据此切生产默认。开关表追加第94项，原135处C++读取不变。
- 行数基线通过`check_size_ratchet.py --write-baseline --baseline /tmp/keynes-arch-phase1/stage8/size-candidate.json`生成候选，确认唯一差异为host已低于600行后写回；其他基线不放宽。各平台共用SConstruct glob，仅macOS arm64调试实际构建。
- 证据目录：`/tmp/keynes-arch-phase1/stage8/`；词元证明、原始行映射、每组构建/黄金、实验失败和成功样本均保留。旧过程文档已清理，29份待决定文档未动。


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


## S9 当前状态

| 工作 | 状态 | 已有证据 / 剩余条件 |
| --- | --- | --- |
| 经济cpp机械拆分 | 部分实施：236个定义、21个新cpp，26688→16784行 | 三组词元证明与串行debug构建通过；每组核心黄金3/3。未改签名/可见性/存档；主文件仍超限，跨域债务部分尚未拆出 |
| 继续拆剩余跨域函数 | 未开始 | 当前依赖护栏按文件冻结，只有h→cpp有受审移位通道；继续搬cpp会新建依赖键，重复头引用也可能增加total。先独立决定如何证明与登记等量搬迁，不能直接重生成放宽基线 |
| economy_runtime.h | 仅分析；代码拆分未开始 | 原文件逐字节不变；类型/成员片段、访问标记、包含者99→120的原因与护栏限制见S9方案 |
| 军事两阶段预留 | 仅设计；代码原型未开始 | 两处白名单保留；缺非零覆盖，且collect与注释语义不符；延迟预留还涉及存档和同epoch守恒，不适合机械迁移中试改 |
| GDScript宿主 | 仅分析；代码拆分未开始 | 281函数的职责/状态/信号/C++连接与6步可回退方案见S9方案；未改变执行位置或任何GDScript |

[S9后续方案](s9-split-plan.md)是设计，不是新增API或已完成的模块接入。Web同步回退决定仍待用户；S8实验默认仍关闭。旧过程文档已清理，29份待决定文档未动。

S9最终验收记录：4次debug构建；分组三轮各3次核心黄金，最终10次核心/3次外围全部相同；默认回归41/41→41/41，全部护栏通过。五条完整末日值见current-state.md。只完成当前约束内的实现拆分子集，剩余主文件、头文件拆分、GDScript拆分和军事两阶段代码仍未完成/未开始，不能据测试通过改写成全量迁移完成。


## S10 当前状态

| 工作 | 状态 | 证据与未完成事项 |
| --- | --- | --- |
| 经济cpp继续拆分 | 部分实施，16784→15783，目标8000未达到 | 两组构建及各3次核心黄金通过，10个成员/建筑适配器原样搬迁；79个跨域函数受现有逐文件键限制，未放宽规则；头文件不动 |
| 军事预留动态验证 | 已复现同步原生分支现金增加12345，按条件停此条 | 独立测试exit1；Country取消/余额不足及真实military_collect_cash、入伍和付款均记录。正式整图玩家军费路径、持久预留/存档中断未验证；不修生产代码 |
| 宿主步骤1 | 部分实施：9个纯值函数，7368→7319 | 独立旧实现对照93项通过；采样/信号/状态入口仍在host；perf-validation副本逐字节不动 |
| 后续状态/表现/日边界拆分 | 未开始 | 继续按s9-split-plan.md分步；不切S8默认，不删Web同步回退 |

旧过程文档已清理，29份待决定文档未动。本轮只收紧经济cpp和正式host两项行数基线；没有外部提交基线放宽、没有新增依赖额度。S10-B失败是新诊断揭示的旧分支缺陷，不是默认回归恶化，不能报告为“全部测试通过”。最终回归/黄金证据见本节后续验证记录。


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


## S11（2026-11-04）

| 子项 | 已实施 / 证据 / 未开始 |
| --- | --- |
| A评估 | 已先写module-boundaries并保留`stage11/assessment-before-fix.md`；区分普通入口拒收、POD接纳、worker付款、同步原生可达与未覆盖的生产配置 |
| A修复 | 同步军饷用既有Country intent端口完成一笔扣款，再在原位置给军队入账；无新队列/开关/绑定，无存档格式变更。D+1维护helper保留 |
| A专用红绿 | 同一测试扩展链接修前/修后生产对象：退出1/4失败→退出0/0失败；首次付款总额+12345→0；八项原生边界断言通过，Country协议取消通过 |
| B只判空批次 | 复查79成员，无新增合格项，S10已经搬走该批次；15783→15783，头10240→10240。剩余清单保留，重载行号508/524纠正；不放宽依赖规则 |
| C两阶段 | 设计已修订：COLLECT不能作确认，确认完成同一预留的扣款/入账；跨日持久预留及schema升级代码未开始 |

默认回归仍不隐含macOS测试扩展。指定`--military-fiscal-probe`才增加非零军饷检查，避免其它平台和未构建测试库时伪报覆盖。正式玩家非零worker付款、历史受影响存档、D+1维护/建造资金接收方仍未完成验证；Web同步回退不变。旧过程文档已清理，29份待决定未动。

最终验收证据（本轮实跑）：macOS arm64 debug构建通过；主黄金10/10、v5黄金3/3，五链未变；改前默认42/42→改后默认42/42，另加军事专用1/1；全部护栏零违规，13护栏测试通过。没有新增B拆分组，不声称执行了不存在的分组构建。详见current-state的S11末日链表与`/tmp/keynes-arch-phase1/stage11/verification-summary.json`。


## S12（2026-11-04）

| 子项 | 实施状态与验收范围 |
| --- | --- |
| A维护helper | 已核查唯一生产调用及两种来源；新增六种原生helper边界和真实0..6日D+1桥接测试。维护费50000有回执但国库不变；不是S11同类造钱。本轮不改资金逻辑，维护费收款/销毁与材料通知口径待用户决定 |
| A worker | 成功路径静态核查一次Country扣款/军队入账；完整非零worker付款及故障/恢复动态夹具未开始 |
| B规则 | 同目录economy_runtime*.cpp位移获授权落地；同键源减少、额度不可重复、总量及头暴露不升；14项护栏测试通过 |
| B拆分 | 两组搬60成员，主文件15783→7989；8新cpp最大1101行，3既有叶文件仍≤2000；头10240不变；925成员词元一致。433→457引用键但522/2400不变 |
| C步骤2 | 遮罩、建筑资料、标签9方法进入2个RefCounted，host7319→7179；84项固定输入对照通过。昼夜预览保留，步骤2部分实施；视野pass与perf-validation副本不动 |

旧过程文档已清理，29份待决定未动。既存问题继续只记录；本轮无军事产品语义修复、无持久预留原型、无Web配置变更。最终实跑证据见下方。

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

## S13：Web回退第1步、宿主步骤3、目标差距

| 切片 | 当前状态 | 证据/缺口 |
| --- | --- | --- |
| Web退役第1步 | 已实施：明确失败、默认关闭逃生，保留全部旧实现 | headless分支/时钟/信号/旧行为对照；真实浏览器未验 |
| Web退役第2步（删除回退与SHADOW/parity公开配置面） | **未开始** | 不能连带删除桌面仍使用的入口；需下面前置条件 |
| host步骤3 | GM校验/组装与被动录制器包装已接入 | 原序号/默认日/时钟/信号不移位；采样/年报提交仍在原处 |
| 目标设计差距审计 | 已按当前代码核查，不是新增实现 | [逐能力粗判与后续三阶段](s13-design-gap-audit.md)；比例不是测量覆盖率 |

第2步前置条件：先实测真实Web打包（正常worker/inline、缺失模块API、authority关闭、失败面板、关闭/重试与逃生）；明确当前worker默认是否另行切inline；列出仍须保留的桌面/性能/同步测试和公共绑定兼容清单；按用户批准的范围逐批迁移后才删。依赖清单见current-state.md的S13节，包括Country/Climate/Ideology parity、年度报告sync、headless性能OFF/SHADOW与工具入口。本轮零实现/零测试删除，开关只新增逃生一项94→95。旧过程文档已清理，29份待决定未动。

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


## S14 当前状态

| 项目 | 状态 | 实施/证据与边界 |
| --- | --- | --- |
| A 已提交视图读边 | 已实施 | Climate所有者返回独立generation/day投影，经济同位置消费；断言及绕行护栏/真实反例；未改Country借用接口 |
| A 非空命令重放 | 已验证 | 四日target=2/3/4/5，独立original/replay逐日八域/经济/军事/资源一致，保存但不中断也一致 |
| A 保存后继续 | **未通过，已停此项** | 日3气候首差异8506758247628532623→9206377192278548470；改前隔离库/host完全同样差异，未修存档/时点，不删除任何摘要字段 |
| A 等待/重试版本 | 已验证有限范围 | 真实Climate owner的plan/discard/retry、版本回退拒绝、旧视图持有、CLM2继续自测；真实worker任意调度非穷尽证明 |
| B 宿主步骤4 | 一种适配已实施 | 仅Modifier，无跨域ACK；112项冻结对照，host7087→7074，四处调用仍原位置，perf-validation未动 |
| C 存档分段评审 | 设计已写；字节迁移未开始 | 见s14-save-sections-review；复用provider、兼容矩阵/金样计划，任意新schema须新授权 |
| 真实Web闭环 / 回退删除第2步 | 未开始 | 用户已确认默认worker；有emcc机器验证后再审删除，未改默认 |

保存续跑独立入口的失败不计入默认回归通过数：它是本轮新增、改前同样复现的证据；不能据默认全绿抹掉该缺口。既存worker窗口、Modifier哈希范围、财政续跑等未修。旧过程文档已清理，29份待决定未动。


### S14 最终验证记录

macOS arm64 debug串行构建最终exit0；首批核心3/3、收尾核心10/10、v5 3/3均匹配既有基线。默认改前45/45、改后47/47，均exit0。护栏892文件0违规、457引用键/445债务键、header_exposed522/total2400、直接Country写2、外围7、开关95/裸读取0、视图1条零违规；15项护栏单测通过。Modifier冻结对照112项；其余285个host方法逐字节不变。默认包括玩家场景、worker restart/stop、资源/加载生命周期与保存相关检查；非默认历史失败未重测。本轮没有真实Web或其他平台图形验证。

完整命令/失败日志与修正记录：`/tmp/keynes-arch-phase1/stage14/commands.md`；汇总`verification-summary.json`。保存续跑诊断exit1是已确认的既存差异，仍未通过，不计入默认47项通过。

- ledger_chain: `2242b25110adb22d74a7ce175f8b6e0dce2ef2442741d3dc2a318efa8c7e28c2`
- whole_economy_chain: `30ea61f1e05f12b02d01ebe3aa1bf6060655e39663251100b4be8ae358db73d3`
- domain_chain: `95aedaac2fd631d72657f0d27fbb04009d3ab489b577f3e7c59788ee25ab537a`
- country_chain: `6786a230e8f9b5859c0f9baa13eefd65ec89976e3d1fd119a5131df35a3e8fef`
- external_chain: `0f85a96f0e1a994ede564409e7e1bc5fdac282cbca2da42672da266f9b663c22`


## S15当前状态

| 项目 | 状态 | 证据/限制 |
| --- | --- | --- |
| A 分叉定位 | 已定位首日输入错误、soil与weather初始化分支 | 21次隔离分组/单变量对照；对齐输入+soil+field_init后Climate日3/4逐位相同，不是生产修复 |
| A 分类/修复 | (a)预捕获问题与(b)缺失权威继续态并存；按字节限制停止修复 | CLM2没有extras，镜像字段落后；未改生产、存档、五链；续跑仍红 |
| A 同类域扫描 | 已记录8域及经济整体、军事、资源的日3/4结果 | 经济/Events/Trigger两日不同，Country日4不同，Ideology日3不同；Modifier/Effect两日相同；其他根因未修 |
| B 第二条视图 | 候选分析完成；实现未开始 | Events→Trigger优先，其次Modifier→Ideology；见module-boundaries；视图护栏仍1条 |
| 保存内容/schema迁移 | 未开始，需新授权 | 先决定旧档降级/拒绝策略，评审CLM2继续态全集；不以恢复成功代替续跑保真 |

复现入口增加`--trace`及完整逐域扫描输出，但仍保留exit1和所有差异；保存续跑未加入默认绿色清单。旧过程文档已清理，29份待决定未动；维护费产品语义、Web默认worker、回退删除第2步均不变。


### S15最终验证

完整命令与日志索引：`/tmp/keynes-arch-phase1/stage15/commands.md`；机器汇总`verification-summary.json`。正式macOS arm64 debug构建exit0（目标up to date）；独立诊断库另编译通过，未安装到正式项目。核心黄金10/10、v5 3/3匹配既有基线；默认改前47/47、改后47/47。护栏892文件0违规、457引用键/445债务键、header_exposed522/total2400、直接Country写2、推进者7、开关95/裸读取0、视图1条；15项护栏单测通过。`git diff --check`通过。

保存续跑`--checkpoint --trace`仍exit1；原轨迹/独立重放/保存不中断相同，resume日3首差异仍在Climate。21次隔离控制进程均正常退出且无脚本错误/失败断言/退出泄漏，但仅“完整输入+slot+field_init”的控制使Climate日3/4相同，其他域仍有差异，不能称保存修复通过。

- ledger_chain: `2242b25110adb22d74a7ce175f8b6e0dce2ef2442741d3dc2a318efa8c7e28c2`
- whole_economy_chain: `30ea61f1e05f12b02d01ebe3aa1bf6060655e39663251100b4be8ae358db73d3`
- domain_chain: `95aedaac2fd631d72657f0d27fbb04009d3ab489b577f3e7c59788ee25ab537a`
- country_chain: `6786a230e8f9b5859c0f9baa13eefd65ec89976e3d1fd119a5131df35a3e8fef`
- external_chain: `0f85a96f0e1a994ede564409e7e1bc5fdac282cbca2da42672da266f9b663c22`

正式C++、正式GDScript、黄金脚本/基线与轮次起点逐字节相同。已追踪debug库SHA前后均为`d3c2dadbd31c95658ffd4258db8035a0c0aa70122b9d0abb7f46cd282a607128`；本轮没有新增受影响的已追踪二进制，原有脏状态未还原。未改暂存区，HEAD仍a712203f；没有外部提交引起的基线调整。未运行release/真实Web/年度轨迹/全部内容组合，非默认既存失败未重测。29份待决定未动。


## S16当前状态（覆盖S15的未授权结论）

| 项目 | 实施状态 | 验收边界 |
| --- | --- | --- |
| A 读档预捕获 | 已修改：授权/恢复镜像之后才捕获 | 与B一起验证八日Climate一致；单修A不能消除缺失继续态 |
| B CLM2 v9 | 已实施新继续态、旧版本明确拒绝、新金样 | 1,901,228字节往返相同，31个非气候比较单元逐字节不变；默认新增仅气候门禁 |
| C 全域续跑 | 部分已定位，完整门禁仍红 | Climate/Country/Economy人口市场/Effect/Modifier八日一致；Events/Trigger/Ideology缺失发布状态见current-state |
| Economy继续态格式 | 未开始 | PKEC/ECP2及候选恢复需一起评审；不在Climate段存其他owner数据 |
| 第二条已提交视图 | 未开始 | 本轮明确范围外，先稳定读档保真 |

旧档政策已由用户调整：开发期不保证旧档，旧版本明确拒绝；不保留旧CLM2金样、不走中性降级。其他域虽可在明确小修时升版本，本轮未实施。Web默认worker不变；删除回退第2步未开始，真实Web需有emcc环境。维护费语义仍待决定。旧过程文档已清理，29份待决定未动。


S16默认回归：改前47/47；改后46/47，新增仅气候金样门禁通过。runtime_economy_worker_restart_test在拆分权威场景两断言失败，交叉库/脚本及scratch完成等待实验不足以归因；S17重新量化气候输入等待及重启完成边界，S16结束时正式用例未修、验收未全过；S17结果见文末。详见current-state S16；不以新增测试通过抵消旧测试失败。原economy_worker_restart_day_test本轮通过。


### S16最终验证与限制

- 串行macOS arm64 debug构建成功；核心黄金10/10、外围v5 3/3，五条末日链逐位不变。
- 改前默认47/47，改后46/47；新气候金样检查通过。失败的runtime_economy_worker_restart_test及隔离等待实验见current-state，未修改正式测试迁就。
- 13项现有存档专项前后均10/13；Climate42检查、Country/Ideology基础/Trigger/运行时段/ECP2/Effect往返通过。其余3项失败错误文本逐行完全相同：ideology_save_worker_authority_test的5条字符串格式错误，ideology_save_transaction_states_test的21条NEG事务比较失败，ideology_save_basis_and_midmaterialize_test的1条tp6边界失败。旧库为隔离pre-project，不曾替换工作区库。
- 完整checkpoint仍exit1，首差Events；仅Climate的金样/八日门禁exit0，不合并宣称完整保真。新版CLM2字节往返相同，整档字节幂等仍不保证。
- 护栏894文件、457键/522/2400、开关95/裸读取0、推进者7、视图1，15项单测通过，零违规。基线未放宽，economy_runtime.h与五条黄金脚本/基线未改。
- 未验证真实Web、其他平台/release、非默认水文/非零对流抑制/季节年度边界；未修财政续跑既存问题、Modifier哈希排除范围或维护费语义。29份待决定文档未动。

完整命令、首次失败与修正过程：`/tmp/keynes-arch-phase1/stage16/commands.md`；文件清单`change-manifest.md`，机器可读汇总`verification-summary.json`，字节证据`final-save-byte-comparison.json`，剩余分叉字段`remaining-causes.json`。S16未达到“完整续跑转绿及默认回归不恶化”的全部验收，不标为整体完成。


## S17当前状态（后续最终验证表为准）

| 项目 | 状态 | 验收边界 |
| --- | --- | --- |
| A 重启对照 | 已完成80次串行对照及定向窗口实验 | S15两测试0/20、0/20；S16为2/20、0/20；不把小样本当作概率相同的证明 |
| A 测试等待修正 | 已实施，两测试最终各30/30 | 等真实退出、D−1提交并服务host；生产调度未改，原断言不变 |
| B 发布状态保存 | 已实施ECP2 55 / OSOA2块8 | Events/Trigger/Ideology三项反向字段实验恢复原失败，补全后八域八日一致 |
| B 完整保存续跑 | 尚未通过 | 整体hash混入兼容Country日期/版本；军事第3日冷报价、资源数量仍不同，严格比较不放宽 |
| 第二条已提交视图 | 未开始 | 先收口完整世界继续态 |

ECP2金样已换为55；旧53/54明确拒绝，CLM2字节/轨迹保持不变。30个非经济业务比较单元逐字节相同。维护费语义、Web默认worker与其他默认配置不变，29份待决定未动。


### S17最终验证与限制

- macOS arm64 debug正式构建exit0；先跑核心3/3，再收尾核心10/10、外围v5 3/3，全部逐位匹配原基线。没有更改原黄金脚本/基线。
- 默认回归改前47/47、改后47/47；最终S17库上的两个重启用例均通过；新金样门禁验证八域第3–10日和CLM2/发布块精确往返。两测试各30次重复使用最终测试代码、S16起点库，证明等待修正独立于B的格式变更；它们不等于最终库额外各30次，最终库由默认清单再次验证。
- 13项存档专项前后均10/13；原有三个Ideology失败不变，5/21/1条错误文本逐行相同，未修改测试迁就。Climate/Country/Ideology基础/Trigger/运行时段/大ECP2/Effect等通过。
- 严格checkpoint exit1：原轨迹、重放、保存不中断三者一致；读档后八域相同，但日3军事报价首差，整体hash0/8、资源0/8，未删比较字段。S17-B只能标部分完成。
- 896文件，457依赖键/445债务键，header_exposed=522、total=2400、直接写2、推进者7、开关95/裸读取0、视图1、15项护栏单测；零违规。持久化主文件2404→2217行，已有9个编码helper词元相同地移入内部头，仅收紧对应基线项，未放宽别处。
- ECP2整体重编码本来不幂等：前后均在envelope、AUDIT、MODIFIERS及OSOA原块7有相同规模差异；新块8精确相同。不能将“新发布块稳定”写为“整份ECP2或PKSV字节稳定”。证据ecp2-existing-roundtrip-differences.json。
- 没有运行其他平台/release/真实Web，也没有新增非零军事付款、季节年度或全部存档相位金样；维护费语义、Modifier哈希范围、财政续跑既存问题未修，第二条视图继续推迟。29份待决定未动。

完整绝对命令与输出在 `/tmp/keynes-arch-phase1/stage17/commands.md`、`final-commands.json`；机器可读结果 `verification-summary.json`，本轮文件清单 `change-manifest.md`。暂存状态未变，HEAD仍a712203f，未做任何提交/回退或外部基线补偿。已追踪debug库从05e1e4f…变为70beaa8a…，保留工作区产物。

五条最终末日链（本轮实跑，均未变）：

- ledger_chain: `2242b25110adb22d74a7ce175f8b6e0dce2ef2442741d3dc2a318efa8c7e28c2`
- whole_economy_chain: `30ea61f1e05f12b02d01ebe3aa1bf6060655e39663251100b4be8ae358db73d3`
- domain_chain: `95aedaac2fd631d72657f0d27fbb04009d3ab489b577f3e7c59788ee25ab537a`
- country_chain: `6786a230e8f9b5859c0f9baa13eefd65ec89976e3d1fd119a5131df35a3e8fef`
- external_chain: `0f85a96f0e1a994ede564409e7e1bc5fdac282cbca2da42672da266f9b663c22`


## S18：完整续跑收口（本轮）

- A已实施：CPD2保存独立兼容Country输入副本；不改整体经济hash算法。八天逐字段诊断均只有Country子hash不同，修复后8/8相同。
- B已实施：恢复时重建军人职业catalog缓存，工资/生活费公式不变；军事8/8相同。
- C已实施：ECP2 56 / OSOA3块9保存worker资源继续态；原生储量并非能由整数stock无损重建，主线程游标补值不足。资源8/8相同，未移动执行位置。
- D严格入口已通过：`check_committed_replay.py --checkpoint --trace --days 10`四进程均有效、退出0；接入默认回归。核心10/10、v5 3/3保留五链；最终默认47/47及专项对照见本节后。
- 字节：29/32比较单元不变，唯一变化CPD2、顶层ecp2、PKSR/ECP2；原OSOA1–8块不变，新块9/兼容PKCN精确往返。旧版明确拒绝，公开ABI不变。

后续未开始：第二条已提交视图；独立PKEC保真、非零军队与季节/年度边界金样；统一全世界恢复事务。维护费语义仍待用户决定；Web默认worker保持，真实Web闭环仍需有emcc机器，第2步回退删除未开始。旧过程文档已清理，29份待决定未动。


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

## S19 状态

S19-A 已加入可选续跑矩阵：默认回归运行第1日保存和季节/年边界两个八日场景，`check_replay_matrix.py --full` 再运行第2/5/9日及混合 GM 场景。S19-B 的 Events→Trigger 已提交视图和护栏已实施。S19-C 仅完成准备表现/停止等待适配，恢复顺序和外围日执行位置保持原位；完整生成/恢复组件化未开始。非零军事探测为独立 opt-in，不改变五条链。


## S20 状态（文档处置与年度存档）

S20-A 已复核阶段记录中的 29 份待决定文档，全部保留：运行时契约列为参考，意识形态、军事、价格列为玩法依据/合同参考。它们没有被删除，因此没有产生悬空引用；完整逐份表见 [document-disposition.md](document-disposition.md)。仓库外的 `~/.claude/skills/project-keynes-*` 未修改。

S20-B 的真实年度自动存档仍以独立日历回放入口验证，测试不关闭 coordinator；结果和是否入默认回归以本轮末尾证据为准。

## S20 状态（最终核实）

S20-A：29 份文档逐份复核并全部保留，分级与引用数量见 `document-disposition.md`；没有删除和悬空引用修复。

S20-B：年度自动存档短年历（16 天年、保存日16、观察到24日）四进程通过，年报和自动存档槽均成功。历史记录：真实365日跨年在第366日的 `base_moisture` 曾首先分叉；S22已完成并接入默认。证据在 `/tmp/keynes-arch-phase1/stage20/annual365.log`。

S20-C：四条已提交视图和反例护栏已落地，五条链不变。S20-D 文档已同步。

S20 收尾实测：

- `check_replay_matrix.py --full` 的 6 个场景（24 个进程）均为 `valid=True; first_difference=None`；日志在 `/tmp/keynes-arch-phase1/stage20/matrix-final/`。
- 短年历自动存档（16 日年、保存日16）四个进程通过；真实365日年仍在第366日首先出现 `base_moisture` 差异，不能当作全年闭环通过。差异已缩小到保存前 MapData/DCWorld/native slot 的写回边界，未新增字节或绕过比较。
- 最终护栏：903文件、457依赖键（445债务键）、`header_exposed=522`、`total=2400`、Country直接写2、推进者7、开关95、已提交视图4；架构护栏15项全通过。
- 主链10/10、外围v5 3/3、默认回归改前/改后各49个日志且各项日志无失败；五条链末日值沿用本节列出的五个值。


## S21 状态

- A：部分实施。年度保存前使用 native 基础湿度作为 geography 输出，并在恢复后刷新 DCWorld；气候三份副本在 day365/day366 对齐，气候分叉消失。经济槽位顺序仍在 day366 首次分叉，完整年度续跑尚未转绿。
- B：已核实为安全边界保存。`GameSaveCoordinator._save()` 在写包前调用 `_wait_for_safe_boundary()`，期间暂停时钟；非安全边界返回明确错误。专用在途测试未开始。
- C：未开始；现有四条已提交视图保持不变。
- D：未开始；本轮没有修改 `world_runtime_host.gd`。

年度验证命令：`check_committed_replay.py --checkpoint --autosave --year-days 365 --save-day 365 --days 373 --trace`。当前结果 `original/replay/checkpoint valid`，`resume` 首差 `domains.ECONOMY.hash`；气候副本对齐记录在 `/tmp/keynes-arch-phase1/stage21/annual-narrow/refresh.log`。

## S22 状态

- A已实施：真实365日及364/366相邻保存八日全域一致，接入`check_replay_matrix.py --annual`与`--annual-neighbors`。365日单场景约84秒，纳入默认回归；邻日档手动运行。证据与五个根因见[S22记录](s22-annual-continuation.md)。
- B已实施：在途事务拒绝与协调器边界等待专用用例纳入默认，不改保存时序。
- C已实施：Economy意见→Ideology、Ideology→年度报告，6条读边护栏，真实源码6个绕行反例成立。
- D已实施小步：仅错误详情格式提取，host7036→7029行，99项对照；其余大型生命周期/有ACK回写抽取未开始。
- E文档同步，29份文档维持S20分级保留，没有删除。最终统一验证附后；本轮不动维护费语义、Web默认worker和旧实现。

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


## S23 实施状态与验证范围

G1 已落地 Country/Economy 存档契约登记，复用现有 `world_state_modules.gd` provider，不创建第二套保存系统。G2 已落地三条视图读边，共9条护栏边界；G3 已登记12域契约字段及9条读边。G4 只完成头文件安全子集（10240→2742），主 cpp 仍7989；G5 只完成恢复准备小步（7029→7010）。G6 两国回放和三项 Ideology 保存专项通过；非零军队年度场景已复现分叉，尚未通过。

验证入口：`check_module_contracts.py`、`check_save_contracts.py`、`check_committed_views.py`；full replay matrix 七场景及 annual 场景均记录在 `/tmp/keynes-arch-phase1/stage23/`。五条连续黄金链保持不变。29份待决定文档继续保留。


G6后续实测：非零军队/战争20日和365日保存都在恢复首日分叉，未修复，证据与后续定位方案见current-state文末。`--military`、`--military-annual`为明确的手动失败诊断，未放入默认绿色集合；两国场景约40秒，已加入默认矩阵，full仍7个通过场景。占领未证明生效。其余目标的通过不代表这项完成。

### S23 最终复核补充

`check_replay_matrix.py --annual` 独立复跑成功，耗时 86.62 秒；但最新 `--full` 的 mixed5 在第 8 日有一次保存前 Economy 间歇分叉，故不能把 full 报告为连续稳定全绿。失败进程的经济 cadence 记录显示耗时自适应锁定为 `n=4`，改前隔离运行与当前定向复跑均通过，根因尚未唯一确定。该问题列为未收口诊断，未改玩法、生产 cadence 或比较规则。军事非零年度场景仍为独立红诊断，不加入绿色集合。


## S24 / R1 收口记录

本轮固定五轮路线为：R1 军事年度读档、周期确定性、经济文件与宿主收口、跨域读边；R2 Freeze/Plan 输入快照契约；R3 Resolve/Apply 统一队列并清理两处 Country 白名单写入；R4 World owner 与统一存档段；R5 战争/多国/多种子覆盖、性能基线、旧路径清理和终稿。

R1 已完成：PKSR v4 经济命令队列续存；ECP2 schema 58 周期 EMA/累计耗时续存；黄金/矩阵/回放入口固定周期并有入口护栏；31 个现有 C++ 域对进入完整登记表。R1 未完成项：非零军事年度闭环和大文件拆分；此前保留全局 lot 过滤的结论已撤回，见本次 L1–L3 记录。

本轮未改变五条黄金链或玩法公式。维护费收款语义、Web 默认 worker 及旧实现继续保留。
### S26 / R2 实施状态

J2 已完成可机检的小步：冻结输入版本共用类型、三域登记、模块依赖与固定阶段顺序检查，未重排运行阶段；构建与黄金 3 次通过，五条链不变。Climate 先于统一 Freeze 的现状保留，原因是它先安装环境输入并发布提交镜像；若要改成同一 Freeze，需要下一轮先证明输入捕获和写回边界等价。

原 J1/K1 过滤方案已撤回。PKMI v1 丢失仍挂链的 inactive 槽位 payload，恢复重建链与连续运行不等价；本次在 PKMI v2 保存原始链与槽位继续态，不保存派生 present。
### K1 / K2 状态

**撤回 J1/K1 结论**：此前把 inactive 行称为“幽灵兵力”并保留全局过滤是错误的。变更型调用方必须看到这些行才能保持原有槽位复用语义；过滤使连续 day20 总兵力1→4、驻军0→3、军饷141819→158220，违反连续运行不变。过滤已删除，不能再作为修复方案。

K2 已完成最小安全步骤：Climate 使用共同冻结版本登记环境 day/generation，并拒绝 in-flight 或版本不符的输入。由于环境 FIFO 与 writeback 游标先于 day plan，执行重排暂缓，列入后续 R2 小步。

### R2 L1–L5 更正与落地

J1/K1 全局过滤已撤回：它破坏 inactive 槽位查找复用，改变连续兵力与军饷。新的修复仅保存/恢复原始继续态：PKMI2 section22、ECP2 schema59 block12、PKSR5 TCQ1。所有中间红测试与哈希定位证据见 [根因记录](s26-military-continuation.md)。没有修改连续计算、维护费或黄金投影。

L4 本轮未开始：economy_runtime.cpp 仍7989行、host仍7010行，未迁移额外视图；不把已完成的Freeze登记代替这些工作。固定后续计划保持：R3统一请求/去重、Country两处白名单写入与Apply写集合/soft-complete；R4宿主≤3000行及全模块存档契约；R5战争/多国/多种子、性能基线、清理与终稿。大文件与读边遗留随以上轮次显式跟踪，不新增轮次。

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

固定后续：R3尚余全域请求/完整Apply/启动与ACK软完成收口；R4宿主≤3000、全部C++日模块统一段契约，承接R2未开始的economy cpp/宿主/读边拆分；R5补覆盖、性能基线、旧路径与文档终稿。不会把未完事项改名为已完成。


## R4 / S30：宿主生命周期与 C++ 存档段契约

本轮把关闭、取消和释放流程提取到 `scripts/game/world_runtime_lifecycle.gd`。`WorldRuntimeHost` 仍保留原公开入口、信号、状态所有权和 Web 回退；组件只通过 host 引用执行原顺序。host 7010→6970 行。冻结检查 18 项、WorldSession 29 项、准备测试 15 项通过；完整 host ≤3000 行目标尚未达到，生成主流程、日调度和存档装配仍保留在 host，继续列入 R4。

新增 `tools/ci/cpp_save_section_contracts.json` 与 `check_save_section_contracts.py`。12 个域登记 owner、tag、当前版本、写入/恢复证据和恢复依赖：Climate/CLM2 v9、Country/PKCN v14、Economy/ECP2 v59、Military/PKMI v2、Trigger/PKTR v6、Effect/PKEF v14、Modifier/PKMD v3、Ideology/PKID v14、Family/Technology 的所属段、Host/PKSR v5、Annual/PKAR。契约检查拒绝缺版本拒绝证据、恢复顺序倒置和未登记域；Family/Technology/Annual 目前是所属段委托，未另造第二套存档格式。

本轮没有改变存档字节、公式、调度顺序或五条黄金链。Economy cpp 7989 行和额外读边迁移未开始，作为后续 R4 切片。


### R4 最终验证（2026-11-05）

构建 exit 0。静态护栏：921 文件、0 违规；依赖 496/484、`header_exposed=518`、`total=2210`；开关95、视图9、存档契约2个脚本 owner+12个C++域、模块12/9、跨域31对、Resolve/Apply 3/3、架构护栏25项。主链3/3和外部2/2均 `first_difference=None`。默认回归 exit 0，61个测试日志及保存/回放/金样检查通过。`check_replay_matrix.py --full` 为9个场景36进程，`--annual`和`--military-annual`各4进程，全部 `valid=True; first_difference=None`。

宿主生命周期抽取后的 host 为6970行；`economy_runtime.cpp`仍7989行。完整 host≤3000和经济文件收口未完成，列入后续R4切片。工作区相对起点新增文件全部为源码、测试或文档，未新增非源码游离文件。

## S31 R4b：宿主与 Economy 文件收口

本轮只处理 R4 遗留的两项机械拆分。宿主从 6,970 行降到 2,955 行，保留公开方法和信号，由生成/恢复、日调度、GM/诊断、视觉查询适配组件承接；冻结参照测试覆盖 Lifecycle、WorldSession、Preparation 和 Web fallback。Economy 从 7,989 行降到 1,974 行，六个大成员函数迁入四个 residual 文件，函数体逐词元相等，构建和主链验证后才继续收口。

为避免搬迁造成重复跨域依赖，新增私有 `economy_runtime_internal_external_types.inc`，并将 bridge/duplicate relocation 的来源写入 `tools/ci/cpp_deps_baseline.json`；依赖总量降至 2,209，未登记的新依赖仍由检查器拒绝。R4 的统一存档段契约已在前轮完成；本轮没有改存档字节、公式、调度顺序或 Web 行为。

### S31 最终验证证据

生产构建 exit 0；主链 `check_golden_determinism.py --runs 3` 与 external `--runs 2` 均逐次 `first_difference=None`。默认回归第二次运行 exit 0，包含 59 个脚本及存档/回放检查；`check_replay_matrix.py --full` 的 9 个场景（36 个进程）、`--annual`、`--military-annual` 均为四进程有效且无差异。提取期间发现并修复了视觉信号绑定、恢复回调绑定、GM 回调绑定三处参数错误，修复后重新完成上述验证。
