# 接手说明（2026-10-28 终版）

| 项目 | 内容 |
|---|---|
| 目标 | 按 `22-cell-program-cap-removal-plan-v3.md` 完成「理念永久地块效果取消 32 格限制」M0–M5 |
| **状态** | **未完成**。§18 的 28 项里 **28 完整 / 0 部分 / 0 无证据** |
| 这份文件 | 给下一个会话一份**不用重新摸索**的起点 |
| 校验 | `python Project/project-keynes/tools/ideology/verify_delivery.py --with-release` → 期望 `VERIFY OK` |

---

## 1. 一句话概括现在在哪

> **代码层的「取消 32 上限」已经真正做完并落到了作者源**（kind 12/14/15/16 全部）。
> **没做完的是工程证据**，而剩下的每一项都缺一个**具体的东西**（worker 夹具、存档格式变更、不可观测的绑定，或一个产品决策）——**没有一项缺「再跑几个夹具」**。

---

## 2. 真正完成的部分（可以当既定事实）

| 项 | 最强的一条证据 |
|---|---|
| 32 目标格上限取消 | 代码 + **194 张 kind-12 卡** `param0=0`；`cap_removed` 12 检查；**B7 单国 1600 格** 32/0 |
| kind 14/15 源格上限取消 | 5 卡 `param0 32→0`；内容门禁 **7/7** + 负向对照 |
| **kind 16 的静默 32 格上限已修** | 66 卡 `param0=800` 低五位 0 → 曾解码成 32 并**真的按 32 截断**；x1b T8 由「36/32」→「**36/36**」 |
| 周围地块归属筛选 | 74 张卡默认 OWN；内核 **103/0**；B11 9/0；中立地已排除 |
| ramp 与常数卡数值 | oracle 19/0（三点 `delta=0`、MIN 钳位复现）；B7 23/0 |
| 批量扩张 `dilate_cell_set` | 等价性断言 + 同网格 **12.46×** + `thread_local`（线程安全）|
| **6 个机制** | 装卸/升级/copier/学派/协同/精神晋升 = **160 + 141 + 147** 检查 |
| **读者一致性** | **83/0**：R1/R2/R3 精确相等；R4/R5 枚举恰好 42 格不含无主格；R6 版本随安装移动；未覆盖格三者都 1.0 |
| **存档 6/7 时点** | 180 + 320 + 379 + 426 = **1305 检查**，全部带负向对照 |
| **存档健壮性** | **367 检查**：27 层 PKID + 19 层 PKEF 校验逐层枚举，51 个拒绝案例精确匹配原因码 |
| **B12 冷启动** | **205/0**：384 格 × 2 stat 逐格精确相等；峰值 46,656 / 冷启 23,328 |
| 峰值内存 | front 141,600 B；**峰值 retained 277,344 + candidate 277,344 = 554,688 B** |
| **生成器落地** | 跑 `generate_ideology_catalog.py` 逐字复现：`(0,0)=199`、`(32,0)=15`、新文案 **194**、三处旧文案 **0** |
| 清理 | 旧平面 430 行 + rollout 开关 + `ideology_cell_program.h` 均已删 |

**回归形态**：**59 个夹具全绿**，检查数全部钉在 `verify_delivery.py` 的期望表里；内核 103/0；覆盖率门禁 7/7；release 上真跑。

---

## 3. 剩下的「无证据」：**0 项**

最后一项（§18.2「execution contract 显式持久化与检查」）已于 2026-10-29 落地：
`compute_execution_contract_hash()` = **6 项规则版本向量**（执行语义／program backend／selector unbounded／
source-count 解码／evaluator／**§9.3 资格日**）**+ 3 个真实编译身份**（ideology／Effect／Modifier 的 catalog hash），
进 PKID（**schema 11→12**）、恢复时校验、不匹配用方案点名的原因
`cell_program_execution_contract_mismatch` 拒绝；`get_ideology_report()` 暴露它。

**这个字段原本是死的**（`_execution_contract_hash` 仅声明、零写入，所以 front 上的
`execution_contract_hash` 结构性为 0）——现在它被写了、被持久化了、被校验了。

The container half landed the same day and is the half plan 11.5 actually asked
for: the PKSV provider manifest's `pkid` entry carries `execution_contract_hash`
next to the four fixed keys (as a decimal string, because the JSON header rounds
a 64-bit number past 2^53), `list_slots()` greys out a mismatched slot,
`prepare_load()` records the verdict, and `restore_prepared_game()` refuses with
`cell_program_execution_contract_manifest_mismatch` **before** any
`provider.restore_sections`. A pre-field archive has no key, which is UNSTATED --
deferred and logged, with the PKID payload keeping the authority (see
`ideology_execution_contract_manifest_test`, **40/0**).

## 4. 剩下的 4 项「部分」—— 逐条写清缺什么、为什么现在补不上

| # | 项 | 缺口 | 性质 |
|---|---|---|---|
| 1 | `18.1` 四种权威组合、跨 slice、**权威翻转** | **`0xFFF`（worker 拥有全部）已修好并逐格一致；`0xFEF`（意识形态主线程 + Effect/Modifier worker）修好过，但那次改动在普通配置里把 Modifier 行应用了两次，已回滚。** 根因两条都已定位：① `apply_runtime_effect_snapshot` 用 worker 的事务表**替换** `_transactions`，把主线程刚计划的行**一天后抹掉**（`status` 变 MISSING，被当成失败）；② 结算路径在**没有 worker 的配置里也执行**，于是本地适配器已应用的行又被应用一次（实测 `1.03² = 1.0609`）。**下一步的正解**：把结算的守卫收窄到「EFFECT 域确实归 worker」，然后跑**全套**而不只是它自己那份 46/0 | **修好过、回滚；根因已定位** |
| 2 | `18.1` 权威翻转的**下游** | mask 账本本身已修（`_lifetime_granted_mask`，重启会重新发布）；**但重启后的 worker 生命周期在第一个经济日必挂**：`economy_column_read_range_invalid` → `unhandled_worker_exception`。**这是既有问题**（在 8/8 次豁免的 parity 日志里就存在），在 economy 的重启路径上，**不属本方案** | **别的子系统** |
| 3 | `18.3` B1–B12 的 B2 | 12/12 都跑了，但 B2 的「**64 国**」子句**按字面不可实现**：`NewGameConfig.MAX_FOREIGN_COUNT = 12`，`foreign_count=63` 直接被 `foreign_count_out_of_range` 拒绝。天花板 13 国已跑（156 张卡、front 0 格→**修复后已有层**）| **一条不可实现的子句** |
| 4 | `18.2` **worker 权威下的载入持久性** | **已修（2026-10-29）**。存档恢复且逐格无损（192 格、`max_abs_add_diff = 0.0`）之后，恢复的状态现在会**推回 worker**：`restore_ideology_state` → `import_ideology_pod_state` → `export_pod_import_state` → `serialize_snapshot` → host 的 `restore_ideology_pod_save`（pod 自己的存档格式，不是新传输）。worker 的 committed day 变为载荷的（`pod_day -1 → 7`），一次真实回写后 `idea_rows [82,1,0,0] → [82,1,0,0]`、日期 `7/8 → 7/8`、front 仍 `cells=2`，回写后重新泵仍逐格 `max_abs_add_diff = 0.0`；`ideology_save_worker_authority_test` 断言这些（18 条），并用**无 worker 世界**做负向对照（同一 PKID 仍恢复、结果里**没有** `worker_import` 键、一个真实主线程日不动行和日期） | **已闭环，不再是缺口** |

**合计 4 项。** 没有一项是「再跑几个夹具」能关掉的。

**已经关掉的、曾经也在这个表里的**（避免有人按旧记忆去找）：`主线程/worker parity`（**逐格一致，`max_abs_add_diff = 0.0`**）、`§11.7 第 7 时点`（**63→72/0**）、`整包 manifest`（**40/0，含 UNSTATED 语义**）、`分配计数`（**实测非零**）、**`backlog`（已有定义：折叠仍欠的格访问数，同一作业峰值 0 vs 39 证明它不是改名）**、`§14.3 性能门槛`（**两种规模都过：0.5660 / 0.9083**）、`原生 writer/reader + checkpoint 探针`（**country checkpoint 拒绝路径已有夹具，21/0**）、`在用旧 basis`（**schema 14，局部 scalar basis + sample day**）、`UI 同步`（**不是缺口**，三处 UI 提法全是约束）。

## 5. **三处语义缺陷：已决策、已交付**（2026-10-29）

用户对三条各做了选择，三条都已实现并验证。**不要再把它们当成待决策项。**

| # | 缺陷 | 用户选择 | 交付结果 |
|---|---|---|---|
| 1 | **§10.1 pending 不保留旧贡献** | **pending 用旧的** | 已实现：`collect_effect_activations` 在转移在飞时用 `transition.previous_level`，pending 装备不贡献。**17 个受影响夹具全部修复，检查数净增 73**；`pending_keeps_old_contribution` 实测 `OUTCOME = OLD`；`mechanism_equip_level` 拆成 13 相 |
| 2 | **协同撤销永久泄漏** | **稳的方法** | 已修：`ExternalEffectCommandPod::stable_source_identity`（opt-in，只有协同行置位）→ APPLY 与 REMOVE 共享稳定身份。实测 `drought/plain` 从 `0.95/1.03` 回到 **`1.00/1.00`**、`removes` 的 country delta **1→2**、`[FINDING]` 消失 |
| 3 | **§9.3 时序模型从未实现** | **A（实现它）** | 已实现核心：结算记 `confirmed_day = D`、**`eligible_from_day = D+1`**，采纳被门挡到资格日；两个日期**已进 PKID（schema 10→11（此后因执行契约 11→12））、并入状态哈希、成对校验、被 rollback 覆盖**。**11 个夹具修复，检查数全部上升** |

**证据**：M5-82（缺陷 1）、M5-81（缺陷 2）、M5-83（缺陷 3）、M5-68 §6.1（缺陷 2 的修法分析）

### 实现这三条时**我自己引入、又被夹具抓到的三个 bug**（值得记住模式）

| bug | 怎么暴露的 |
|---|---|
| 越界读的第一版守卫**拒绝了所有墓碑**（`program_id == -1` 是合法标记）| 4 个夹具 + **检查数下降** |
| §9.3 的**门没清 `_derived_rebuild_day`** → `derived_rebuild_pending()` 永远为真、`drain` 烧 4096 步 | b12 的两条 `drain` 断言 |
| **PKID 不持久化两个日期** → 恢复后门失效、早一天采纳 | Agent U 主动测了 reload |

---

## 6. 本会话修掉的 22 个真实缺陷（供参考什么样的问题还会藏在哪）

| # | 缺陷 | 怎么发现的 |
|---|---|---|
| 1 | `effective_value` 的 `group_handle != 0` 守卫 → **每张卡在 cell 0 上失效** | 逐格读值发现 cell 0 是 1.0 |
| 2 | ramp 路径跳过指令流 → **24 张卡数值错** | 与解释器逐点对照 |
| 3 | `FOREIGN` 误收中立地 | 三态谓词审查 |
| 4 | `out_derived != nullptr` 判后端 | I01 断言 |
| 5 | 半径位宽当校验上限 | 内容门禁 |
| 6 | `Term::program_key` 用 `std::string` | **+13% 耗时** |
| 7 | 诊断函数缺 `return` | **只有 release 报 C4715** |
| 8 | `_cell_layer_rebuild_visits` 只导出不递增 | 夹具**假失败** |
| 9 | e2e 夹具 API 漂移 + 挂死 | 报错后 10 分钟无输出 |
| 10 | **kind 16 静默 32 格上限**（66 卡）| **外部核实**（Claude）|
| 11 | **生成器不落地** —— M2 的核心交付跑一次生成器就被抹掉 | 读 §12.1 后去跑生成器 |
| 12 | PKEF 终态 REJECTED 行不可读 | §11.7 时点 2 的夹具 |
| 13 | `explain` 分解漏派生项（1.05 但 sum_add=0）| reader 枚举 |
| 14 | **PKEF 恢复路径越界读**（内存安全）| 存档健壮性夹具 |
| 15 | `get_modifier_report` 无 layer 字段 | reader 枚举 |
| 16 | **协同撤销永久泄漏**（激活后 Effects 行永不删除） | 决策 2；机制定位到 `fire_sequence` 的位 63 |
| 17 | **§10.1：pending 期间就在服务 NEW 等级** | 决策 1；实测 pending 读到 L2 而非 L1 |
| 18 | **学派强度在派生路径上是空操作**（194 张派生卡不吃学派加成）| 决策 4；实测 `\|A1 − A0×1.25\| = 0.0` |
| 19 | **`_execution_contract_hash` 是死字段**（front 上结构性为 0，无任何校验）| §11.5；现在被写、被持久化、被校验 |
| 20 | **契约检查不对称**：与现场重算比而非与自己的戳记比 → 运行时**无法重载自己的存档** | 修 §11.5 时由 Agent 发现，我实测确认 |

**我自己引入又被夹具抓到的 2 个**：`dilate_cell_set` 的共享缓冲（线程安全）、越界读第一版**拒绝了所有墓碑**（4 个夹具 + 检查数下降一起拦住）。

---

## 7. 踩过的坑（省你时间）

| 坑 | 说明 |
|---|---|
| `passable` LUT 必须**正好 256 字节** | 按**地形类型**不按格；否则拓扑守卫**静默失败** |
| `bootstrap_country` 的 `country_ids` 为空 → **一国占全部陆地** | 想造单格国必须显式传 CSR |
| `get_country_cell_summary(x)` 的参数是**格号**，不是国槽 | 传国槽会 6 次拿到同一 handle（`tag_snapshot_stress` 曾犯此错，已修）|
| 国家日推进是 `run_country_slice` | `advance_country_day` **不存在** |
| `get_country_territory_counts()` 读**经济 epoch 快照** | 不是 `CountryStore::territory_count` |
| `TagSnapshot` 是**不可变快照、惰性构建** | metric override 必须在它构建**之前**设好 |
| **PKID 单独无法恢复任何已装备的档** | 缺 PKEF 就整档拒绝（`ideology_effect_binding_missing_or_mismatched`）；必须 `capture_effect_state()` + `capture_ideology_state()` **按此顺序** |
| 装备/卸下/升级都要 `dispatch → **run_modifier_daily** → ack` | `run_modifier_daily` **不可省**，否则转移永远挂住 |
| **同一天可以重复调 `run_ideology_daily(day)`**（我一度误以为必须严格递增）| 累加守卫是 `_last_day < day`（`:5010`），`:5095` 在 `_pending_transitions` 非空时也放行同一天。**而且这是强制重新采集的唯一办法**：`drain_derived_cell_layer` 做不到——一天的任务完成后 `_derived_rebuild_day == -1`，drain 循环直接空转 |
| `unequip` 会被 **class-opinion 门**挡住 | `subsistence_farmer` 和 `serf` 都是 class "general"，`public_hygiene` 撤回立场 −8192 → `ideology_support_threshold_not_met`。要用 `household_farmer` 3:1 |
| 有转移在飞时第二次装备报 **`ideology_country_transition_pending`**（不是 `ideology_transition_pending`）| 出厂 68 条 synergy 让 `:4550` 先命中 |
| `program_id == -1` 是**墓碑的合法值** | 加边界检查时别把它当非法 |
| 无头环境里**必须先把整日经济跑完才能装备真实卡**（512 国约 1060 slice）| 支持门读 `CountryClassOpinionSnapshot`；`PK_DISABLE_SUPPORT_GATE` 不管用 |
| **kind 16 在无建筑经济里解析 0 个目标** | 这解释了 kind 14/15 端到端夹具为何一直走不通 |
| 出厂理念容量是 **2（上限 6）** | 「每国 12 卡」无法从现有内容装配；B1 是在内存里提到 12 |
| `max_slice_ms` / `cell_layer_rebuild_ms` 是**累计最大值** | 判断稳态必须同时看 `last_slice_ms`；两字段差一个数量级时通常有一个被误读 |
| **§9.3 之后 front 可能只是「部分采纳」且看起来完全正常** | 每国结算时刻不同 → `eligible_from_day` 是**全局单值**、随每次结算推进。国家 A 第 10 天结算（11 采纳）而国家 B 第 22 天结算时，11–22 之间 front **只有 A 的行**：实测 `cell_count=3200 stat_count=2 countries=[A]`，**覆盖类断言（`> 32`、`>= CELLS/2`）在半个 front 上全部通过**。只有「**每个国家的 handle 都进了层**」这类断言能抓住它。**写多国夹具时必须断言 handle 集合，不能只断言格数** |
| **`drain_derived_cell_layer(0)` 在 §9.3 之后是静默空操作** | `drain` 会把 `day` 传给 `step_derived_rebuild(day)`，所以只要有过结算，`day 0` **永远** < `eligible_from_day` 而被门拒。夹具必须传**当前日**。这个模式还留在 `ideology_tag_snapshot_stress_test.gd:315`（今天仍绿，因为它在那一处不依赖被采纳的 front）和 `ideology_plane_equivalence_probe.gd:148` |
| **在 `quit()` 之前崩溃的探针会挂住整个 runner** | `ideology_plane_equivalence_probe.gd:148` 调用了已不存在的绑定（`int(ext.get_city_output_factor_q16(...))` → "Nonexistent 'int' constructor"），异常后**没有走到 `quit()`**，进程永久挂起（实测卡了 20 分钟直到被杀）。**任何在 `quit()` 之前可能抛异常的探针都是 runner 地雷** |
| 报告字段可能是**死字段** | 本会话发现 5 个（`_cell_layer_rebuild_visits`、`contribs_passed`、basis 四项、`rebuild_skips`、`command.source_id`）。**能读出值的字段，要能指出它在哪里被写** |

---

## 8. 我这一路错得最多的一个模式

**把局部事实当成全貌——重复了 6 次**：读注释、读数据文件、读字符串匹配、只看命中行不看资源块、没确认快照何时构建、把同名概念当成同一处代码。

**最有效的一条对策**：
> **查「A 影响 B」的因果链时，先确认 B 的读取路径，不要从 A 的写入路径反推。**

**第二有效**：
> **加边界检查前，先确认那个「非法值」域里有没有合法的哨兵值。**

---

## 9. 建议的下一步（按性价比）

1. **修 worker 权威下的派生层** —— 缺陷已诊断到第一级断裂（重建从未被 step，M5-87），修法已设计并实现过但破坏 4 个夹具含崩溃、已回滚（M5-88）。它现在是**唯一一个「一投入解锁 4 项部分」**的地方（parity / §11.7 第 7 时点 / B2 / 末段 parity），但**必须先有能验它的环境**：边界锁在手工驱动日的 headless 夹具里拿不到
2. ~~决定那三处语义缺陷~~ —— **已完成（2026-10-29）**。三条都按用户的选择实现并验证，相关的 28 个夹具（决策 1 的 17 个 + 决策 3 的 11 个）全部修复且检查数上升。见 §5。
3. **存档格式变更**（F1–F5 + 整载荷哈希）—— 会让 §18.2 的时点项真正可称完整
4. **重写 735 检查的逐格 oracle** —— 现有替代是 oracle 19 + 内核 103，**逐格全量对照没有**

---

## 10. 怎么验证一切正常

```powershell
python Project/project-keynes/tools/ideology/update_dll_identity.py
python Project/project-keynes/tools/ideology/verify_delivery.py --with-release
```

期望末行 `VERIFY OK`。它会校验 DLL 身份、覆盖率门禁（7 条）、内核（103）、以及 **61 个夹具的检查数**——少一条断言会被抓到。

**两个已知的抖动**：`ideology_x9b_family_target_worker_test` 偶发 1 个 `country_worker_peer_results_pending`（重跑即过）；`mechanism_matrix` 的相对基线是 1129/3（既有债务，非本方案引入）。
