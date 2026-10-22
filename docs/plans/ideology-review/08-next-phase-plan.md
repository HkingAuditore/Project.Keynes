# 08 下一阶段执行计划（第 7 轮 review 结论 + 新会话开工手册）

> **2026-10-22 起，执行顺序以 `10-roadmap.md` 为准。** 要点：只认 worker 路径、主线程冻结；
> parity 不阻塞（A1/R9-1 后半停工）；本文件阶段 A–D 的顺序作废，具体技术细节仍可引用。

> 读者：新开的 DeepSeek 会话。本文件是 01/02/03 的执行入口，取代 05 里的“下一步”段落。
> 状态基准：2026-10-22，DLL 构建于 12:41:35；本文中所有“实测”均由 reviewer 在该 DLL 上跑出。

---

## 0. 开工纪律（每轮都适用）

1. 必读：`project-keynes-ideology-runtime` skill（含 `references/pitfalls-and-build.md`）、effect / modifier / economy runtime skill；
   `docs/plans/ideology-review/01..03`、`06-round1-review.md`、本文件、`baseline-2026-10-21.md` §6。
2. 构建（唯一成功判据是末行 `scons: done building targets.`；禁止 `rebuild.bat`）：
   ```
   cd gdext && PYTHONPATH= VSLANG=1033 "C:/Users/hkinghuang/AppData/Local/Programs/Python/Python313/Scripts/scons.exe" platform=windows target=template_debug dev_build=no -j8
   ```
3. 测试（逐个跑，不加 `--quit`，必须贴出 `N checks, M failures` 行，并 grep `SCRIPT ERROR`——GDScript 运行时错误不计入 failures）：
   ```
   . ./tools/runtime/Resolve-GodotBin.ps1; $g = Resolve-GodotBin; & $g --headless --path Project/project-keynes -s tests/<path>.gd
   ```
4. 工作树是脏的，**不准 revert 任何不是本轮写的改动**；整块删除前逐行确认（上轮误删 `_effect_input_snapshot` 的教训）。
5. 结论分级：没有实测输出的一律写“推断”；“完成”必须附原始输出、checks 数、以及改动的 `file:line`。
6. 禁止弱断言：不准用“>0 即通过”“存在 key 即通过”代替值断言；门禁测试允许保持红，但不准为了变绿去掉比较项。
7. 任何存档 / ABI / catalog hash 变化：先写明版本号 old→new、fail-closed 行为、受影响测试，再动手。`latched` 的 Effect POD ABI 2→3 **须用户在开工指令里明确同意**（见 A5）。
8. 每轮收尾更新 `05-implementation-status.md` 状态表和 baseline，列出“未达成项”。

---

## 1. 当前实测状态

| 测试 | 结果 |
|---|---|
| `tests/runtime/runtime_ideology_parity_test.gd` | 14 checks / 2 failures：`compared=12 matched=5 first_mismatch_day=3 field=points_revision worker_opinion_rev=13 ref_points_rev=1` |
| `tests/runtime/runtime_ideology_parity_guard_test.gd` | 16 / 0 |
| `tests/ideology/ideology_draw_flow_test.gd` | 16 / 0 |

day 3 slot 1 的 diff：reference `baseline_buildings=9 points=0 revision=1`，worker `baseline_buildings=10 points=23002 revision=4 history=[23002,...]`。
baseline §6.7i 声称“跳过 worker 起步前的主线程日后 matched 升到 8”，本次实测仍是 5 —— **夹具结果不确定**，这本身是 A1 的验收项。

---

## 2. 第 7 轮 review 结论（按严重度）

> 第 8 轮（DLL 14:34:50）复核结果见 §2.9。R7-2/R7-3/R7-6/R7-7 已修；R7-1 只撤回了泄漏，根因未修；R7-4/R7-5 修法不到位。

### R7-1 [P1] parity 时序修法放错了层，并泄漏到生产路径

- `DCWorldExt::publish_ideology_worker_inputs`（`gdext/src/world_ext_ideology.cpp:221-225`）无条件调用 `settle_points_for_opinion`，后者调用 `accrue_points(_last_day)`（`ideology_runtime.cpp:2725-2733`）。
- 该函数的生产调用点：`world_ext_runtime_graph.cpp:473`（**每个 graph pulse 无条件**）、`:375`、`world_ext_ideology.cpp:458`、`world_ext_country.cpp:1051`。
- 后果：
  - 主线程权威时，点数结算时机从 `run_daily` 挪到了“任意一次 publish”，ledger day 写的是 `_last_day`（前一天），生产语义被测试需求改变；
  - worker 权威时，主线程 runtime 被 settle 改写，随后又被 `apply_pod_snapshot` 覆盖，纯浪费且破坏“worker 权威下主线程 ideology 不演化”的不变量。
- 根因没解决：worker 一天内读到的是“最新” opinion（`native_simulation_host.cpp:9430` `atomic_load(&_ideology_opinion_snapshot)`），accrual 按 `opinion.revision` 去重。两侧 revision 推进节奏不同（13 vs 1），而 trade 收益是**每次 accrual 都发**、baseline 是**第一次看到的值**，所以节奏差就是业务差，不是诊断噪声。
- 正确修法见 A1（opinion 按日绑定 + accrual 按日/期去重）。在 A1 落地前，settle 调用必须用 parity 开关门控。

### R7-2 [P1] parity reference 在生产路径每天全量导出并保留 128 份完整快照

- `run_ideology_daily`（`world_ext_ideology.cpp:346-363`）只要 `_runtime_host != nullptr` 就每天 `export_pod_business_snapshot` + `ideology_business_hash` + 拷进 `_ideology_references`（`native_simulation_host.cpp:3925-3927`，`std::map<int64_t, RuntimeIdeologyPodSnapshot>`，保留 128 天）。
- `_runtime_host` 在 country catalog 发布时就会创建（`world_ext_country.cpp:1042`），即生产必然命中。
- 后果：主线程每日 O(countries × (bits + ideas + history)) 的拷贝和哈希，外加 128 份完整快照常驻内存；`record_ideology_parity_locked` 还在锁内整份拷贝 reference（`:3956`）。违反 03 的“空闲零开销”。
- 修法见 A2。

### R7-3 [P2] `field=` 报告误导

- `record_ideology_parity_locked`（`native_simulation_host.cpp:3994-3996`）在 `points` 段不等时**先**比较 `points_revision`，而 `points_revision` 已被移出业务哈希（`runtime_ideology_pod.cpp:2021-2037`）。
- 本次实测 balance 是 0 vs 23002，报告却是 `field=points_revision`。
- 修法：`field` 只能从参与哈希的子段里选（`points_balance` → `points_lifetime` → `baseline` → `history` → ...）；诊断子哈希（`points_revision`、`history_cursor`）另报 `ideology_parity_diag_fields`。

### R7-4 [P2] catalog 前置条件按构造永远不等

- 两侧 `catalog_hash` 由两个不同函数计算（注释 `runtime_ideology_pod.cpp:1984-1991` 自认），于是 `ideology_parity_catalog_mismatch_count` 永远增长，这道“前置条件”实际上不检查任何东西。
- 修法：抽一个共享的 `ideology_catalog_content_hash(const compiled IR&)`，两侧都用它；parity 测试断言 mismatch_count == 0。

### R7-5 [P2] RNG 种子与世界无关

- `runtime_ideology_country_rng_seed(handle) = handle ^ const`（`runtime_ideology_pod.h:290-293`），主线程 `ideology_runtime.cpp:946`、pod `runtime_ideology_pod.cpp:595` 共用。
- 两侧一致是对的，但种子不含世界/开局种子：同一 handle 在每一局都抽到相同序列（原先基于 catalog hash，同样缺世界种子，问题被延续并固化）。
- 修法：`seed = splitmix64(new_game_seed ^ splitmix64(handle))`，new_game_seed 在 NewGameConfig 确定、两侧都能拿到；存档里已保存 `rng_state`，旧档不受影响；`ideology_draw_flow_test` 需补“两个不同世界种子 → 首次 offer 不同”的断言。若本轮不做，至少在 05 记为债务。

### R7-6 [P2] 运行器登记无效

- `tools/runtime/Invoke-RuntimeTests.ps1:33-80` 列表里的路径是 `tests/runtime_*.gd`，实际文件在 `tests/runtime/`（`Test-Path` 实测 False）。这是既有问题，新加的两项沿用了错误约定，所以“已登记进套件”没有意义。
- 修法见 A3。

### R7-7 [P3] 其他

- guard test 只有 key 存在性和“立即重抓 hash 稳定”断言，没有**敏感性**断言（改一个字段 → 对应子段变化、`field` 指对）。
- 报告里 `worker_day=1` 而 compared=12，诊断字段陈旧。
- 测试夹具里“worker 未起步就跳过主线程日”（`runtime_ideology_parity_test.gd:186-205`）只在测试里，**不是**生产泄漏；但 A1 完成后应能删掉，作为 A1 的 DoD。

### 本轮做对的

- 承认并纠正“单世界双权威不可行”；照搬 country parity 驱动成功，`compared>0`；
- guard 与门禁拆分，门禁保持红而不是绿色空集；
- 定位到“两侧 opinion revision 不同”这一方向是对的。

### 2.9 第 8 轮复核（2026-10-22，DLL 14:34:50，reviewer 实测）

实测：
- `runtime_ideology_parity_test`：14 checks / 2 failures，`compared=12 matched=4 first_mismatch_day=1 field=points_balance paired_ref=12 paired_worker=12 worker_opinion_rev=11 ref_points_rev=1`
- `runtime_ideology_parity_guard_test`：21 / 0
- `Invoke-RuntimeTests.ps1`：39 条路径全部存在

已确认修好：`settle_points_for_opinion` 已删；reference 导出受 `ideology_parity_enabled()` 门控（`world_ext_ideology.cpp:341`、`native_simulation_host.cpp:3908`）；`field` 改为只从参与哈希的子段选；运行器路径；guard 敏感性断言。

新问题：

- **R8-1 [P1] 存档/协议布局变了但版本号没变。** `trade_paid_day` 写进了 PKID（`ideology_runtime.cpp:4548/4679`）和 pod serialize（`runtime_ideology_pod.cpp:1502/1602`），但 `SAVE_SCHEMA_VERSION` 仍是 7（`ideology_runtime.h:38`）、`RUNTIME_IDEOLOGY_POD_ABI_VERSION` 仍是 5。旧 v7 存档会被当作新布局读，字段错位，最好情况是报误导性的 `ideology_save_truncated` / `state_hash_mismatch`。必须 PKID 7→8、pod ABI 5→6，并加“旧版本字节被以 `schema_unsupported` 拒绝”的测试。
- **R8-2 [P1] `trade_paid_day` 没有解决结算次数差，还可能改了经济数值。** accrual 仍按 `opinion.revision` 去重：主线程整个窗口只看到 revision 1，worker 看到 11 个，所以 worker 在 11 个不同的日子各付一次 trade，主线程只付 1 次——“每天最多一次”对这个差无效（实测 46859 vs 67969）。同时，如果生产里 revision 是每个 period 发一次，那么“每次结算付 `trade_per_day`”本来就少付了 `period_days` 倍，这个修改没有核对这一点。正确的流量结算是**节奏无关**的：`trade_q16 = trade_per_day × clamp(day - trade_paid_day, 0, period_days)`，再把 `trade_paid_day = day`。这样结算 1 次还是 11 次，总额只取决于经过的天数。见 A1。
- **R8-3 [P2] `world_seed` 在生产里永远是 0。** `configure` 读 `catalog.get("world_seed", 0)`（`ideology_runtime.cpp:555`），但 `IdeologyFacade.configure` → `compile_native_catalog` 从不写这个键（`scripts/ideology/` 下 0 处），唯一的 `world_seed` 在 `map_generator.gd:7007` 的气候参数里。R7-5 实际未修；另外种子公式从 `handle ^ C` 变成 splitmix(handle)，新开局抽卡序列已经变了（旧档存了 `rng_state` 不受影响），这需要在 05 登记。修法：在 map_generator 两处 `ideology_facade.configure(...)` 把 `seed_value` / `_save_restore_seed` 传进去并写入 native catalog；测试：同 handle 不同世界种子 → 首次 offer 不同，同种子 → 相同。
- **R8-4 [P2] “最近日历”配对会静默地拿不同日子比较。** `record_ideology_parity_locked`（`native_simulation_host.cpp:3981-3990`）取距离最小的一帧，但不要求距离为 0。距离 > 0 必须记 `ideology_parity_uncompared_day_offset` 而不计入 compared；两侧日历不一致本身是夹具问题，应该在驱动里修（主线程用 worker 的 committed_day 跑 `run_ideology_daily`），不该在比较器里模糊匹配。另：day-keyed map 现在无人读，可删。
- **R8-5 [P3] catalog 检查降级为“是否为 0”。** 可以接受为过渡，但 R7-4 的真正目标（内容一致）未达成，05 里不能写“已修”。

---

## 3. 阶段 A：M0 收尾（01 的剩余项 + parity）

### 2.10 第 9 轮复核（DLL 16:17:24，reviewer 实测）

实测：`runtime_ideology_parity_test` 15 checks / 3 failures，`compared=12 matched=4 first_mismatch_day=3 field=points_balance uncompared=2`（测试前后 DLL 时间戳一致）。

已确认：R8-1（PKID 8 / pod ABI 6，旧版本拒绝测试在 `ideology_runtime_test.gd:137-162`）；6b 共享核 `ideology_trade_flow_q16`（`runtime_ideology_pod.h:355`）两侧都调用；R8-4 只接受距离 0 的配对；R8-3 两处 `configure` 传入种子。
更正：§2.9 R8-2 里我建议的 `clamp(..., period_days)` 确实破坏不变性，去掉 clamp 是对的。

新问题：

- **R9-1 [P1] parity 不确定的根因是两侧从同一个并发推进的 Economy 读“最新”。** 主线程 `accrue_points` 直接读 `_economy_runtime->country_class_opinion_snapshot()`（`ideology_runtime.cpp:2745`），worker 读 `atomic_load(&_ideology_opinion_snapshot)`（`native_simulation_host.cpp:9601`）。同一个 Economy 实例被 worker 线程推进，谁先读到哪一版取决于线程调度，所以五次结果不同。不要再试“按日选 opinion”的规则：parity 验证的是“同输入 → 同输出”，正确做法是 **parity 模式下主线程的 `run_daily(D)` 直接消费 worker 规划第 D 天时实际用的那一份 opinion**——已经写好但从未调用的 `worker_opinion_snapshot_for_day`（`native_simulation_host.cpp:7687`）就是这个入口。具体：
  1. worker 在 `execute_ideology_worker_stage` 里把 `(plan_day → shared_ptr<opinion>)` 放进小环（容量 16，锁保护），不要用三个独立 atomic（读到的三元组可能来自不同天）。
  2. `NativeIdeologyRuntime` 加 `accrue_points_from(const RuntimeIdeologyOpinionSnapshot&, day)`，生产路径经 `ideology_opinion_from_economy` 调它，parity 路径经 host 取 worker 用过的那份调它；只有一个结算函数体。
  3. 取不到当天的 opinion → 当天不发 reference（计 uncompared），不要退回“最新”。
  4. 验收：`matched == compared`，五次完全一致。
  5. 同时删掉未接线的死代码：`select_ideology_opinion_for_day`、`const bool opinion_for_day = true` 及其不可达分支（`native_simulation_host.cpp:9620/9649`），以及未被读取的 day-keyed `_ideology_references` map。
- **R9-2 [P1] 结算键 `period_index = commit_day / period_days` 用了会变的除数。** `period_days` 来自 `_epoch_days`，而 `_epoch_days = workset_elapsed_days(day_index)`（`economy_runtime_epoch.cpp:1003`）每个 epoch 都可能变。例：day 10 / 5 = 2、day 12 / 6 = 2 → 第二次是新的提交却被当作“同一期”跳过；反过来也会把同一期拆成两次。修法：结算键直接用 `commit_day`（与发布次数无关、单调），配合 R9-1 两侧吃同一份输入后即确定；删掉 `period_index`（或仅作诊断）。
- **R9-3 [P1] “结算 1 次 = 30 次”只在核函数层成立，ledger 层不成立。** 每次结算后 `gain = min(gain, _point_gain_cap_q16)`（`ideology_runtime.cpp:2847`、`runtime_ideology_pod.cpp:1211`，生成器配置 `131072` = 2.0 点/次）。trade 现在按跨度一次付清，跨度越长越容易撞上限，结算次数少的一侧拿得更少。self-test 只测了 `ideology_trade_flow_q16`，没经过 cap。修法二选一并写明：(a) cap 改为按天计 `cap × span_days`；(b) cap 只作用于 population/building 增量。断言必须在 ledger 层（经 `accrue_points`）做。
- **R9-4 [P2] R8-3 没有测试。** `tests/` 下 0 处 `world_seed`。补：同 handle、不同种子 → 首次 offer 不同；同种子 → 相同；存档恢复后用存档里的 `rng_state` 而不是重新播种。
- **R9-5 [P3] trade 前两次结算都不付款。** `baseline_ready == 0` 时 `continue` 在核函数之前，`trade_paid_day` 要到第二次才播种。两侧一致，但白丢一期；在基线分支里同时播种 `trade_paid_day = day`。

> **路线调整（2026-10-22，取代下文“A 未完成不准进入 B/C”的门槛）**
>
> 阶段 A 拆成两类：
> - **阻塞内容的（必须先做，限 1 轮）**：R8-1 存档/ABI 版本号；A1-6b trade 按经过天数付款 + 单测。这两项会影响玩家存档和点数数值。
> - **不阻塞内容的（转为并行轨道；双会话时由会话 R 全职负责，单会话时每轮最多占 30% 精力，见 §3.6）**：parity 全绿（A1 其余、R8-4、A4）、R8-3 world_seed、A5-A9。
>   理由：parity 差异在点数结算，与卡牌效果路径（Effect/Modifier/每格实例）无关；卡牌效果的正确性由 metric publish / worker forward / scale override 等测试保障，它们已绿。
>
> 紧接着进入**内容轨道**（见 §3.5）。阶段 C（系数平面）仍然要等 B1 基准有数字。

按顺序做，每项独立提交到状态表。

### A1 opinion 按日绑定，accrual 按期去重（修 R7-1 根因）

目标：两侧对同一天消费**同一份** opinion，且每期最多 accrue 一次。

1. `RuntimeIdeologyOpinionSnapshot` 增加 `committed_day`（Economy 生成该 opinion 时的提交日）与 `period_index`（`committed_day / period_days` 或 Economy 自己的开发期计数，二者择一，写进注释）。
2. host 侧把单槽 `_ideology_opinion_snapshot` 换成小环（容量 8，按 `committed_day` 排序，锁保护或 shared_ptr 数组 + 原子游标），提供 `select_opinion_for_day(D)`：返回 `committed_day <= D-1` 的最新一份。
3. worker `execute_ideology_worker_stage`（`native_simulation_host.cpp:9421`）改用 `select_opinion_for_day(plan.day)`；拿不到就报 `ideology_opinion_for_day_missing` 并当天不 accrue（不要退回“最新”）。
4. 主线程 `run_daily(D)` 用同一选择规则读 opinion（经 Economy 的同名 API 或 host 环，二者必须是同一个函数）。
5. accrual 去重键从 `opinion.revision` 改为 `period_index`（两侧都改：`ideology_runtime.cpp:2736+`、`runtime_ideology_pod.cpp:1128+`）。
   - 存档字段 `points_revision` 语义改变 → PKID 7→8，旧档 fail-closed 或按“未就绪”迁移（二选一，写明）。
6. 删除 `publish_ideology_worker_inputs` 里的 `settle_points_for_opinion` 调用；删除 parity 夹具里的“跳过主线程日”。
6b. （第 8 轮补充）trade 流量改为节奏无关：`trade_q16 = trade_per_day × clamp(day - trade_paid_day, 0, period_days)`，首次观测只设 `trade_paid_day = day` 不付款；两侧同一函数。替换第 8 轮的“每天最多一次”。写一个纯主线程单测：同样 30 天输入，结算 1 次 / 30 次 / 随机次数，trade 总额相等。
   - **第 9 轮更正（已实测）**：上式里的 `clamp(..., 0, period_days)` **不成立**。30 天 / period=5 实测：
     钳制版「结算 1 次 = 5000、结算 30 次 = 29000」，既与该条自己写的“总额只取决于经过天数”
     矛盾，也让本条要求的「1 次 = 30 次」单测写不出来。**已去掉 clamp**（用户裁定）：
     `trade_q16 = trade_per_day × (day - trade_paid_day)`，落点 `ideology_trade_flow_q16`
     （`gdext/src/runtime_ideology_pod.h`）。详见 05 §2.6。
6c. 版本：PKID 7→8、ideology pod ABI 5→6（R8-1），加旧版本拒绝测试。
   - **已落地**（05 §2.6）：版本门是精确相等，旧档在解码第一行前即被拒。
6d. **第 9 轮实测阻塞**：本条的 `select_opinion_for_day(D) = committed_day <= D-1` 规则在
   parity 夹具里选不到快照——Economy 的 `commit_day` 与 worker 的 `plan.day` 不是同一日标
   （trace：worker 计划第 1 天时最新提交是第 4 天）。下一步应先把两侧
   `(plan_day, committed_day, period_index)` 的映射打成对照表，再定绑定规则。
   另：parity 门禁本轮发现**不确定**（同一 DLL 连跑 5 次：4 次 matched=4、1 次 matched=9），
   存在竞态，须先消除才能谈 `matched == compared`。
7. **不要**去节流 worker economy（`execute_economy_worker_stage`），那会为测试改变 economy 语义。

验收：
- parity：`matched == compared`，`compared >= 12`；连续 5 次运行 compared/matched/每日 hash 序列完全一致（贴 5 次输出）；
- 主线程-only 世界（无 worker）点数与 A1 前同种子 60 天对比：允许差异，但必须解释（期去重改变了什么）；
- `ideology_draw_flow_test`、`ideology_progression_test`、`ideology_runtime_test` 全绿。

### A2 parity 只在 parity 模式下有成本（修 R7-2）

1. host 加 `std::atomic<bool> _ideology_parity_enabled`，由 `set_runtime_climate_parity_forcing` 或独立 setter 打开；`run_ideology_daily` 的 reference 导出整段受它门控。
2. reference 只存 `IdeologyBusinessSections` + 每国小行（handle、balance、lifetime、baseline、非零 history）用于 diff，不存完整快照；保留天数降到 32。
3. `record_ideology_parity_locked` 只在锁内拷 sections，不拷整份快照。
4. 新计数器 `ideology_reference_exports`；在一个非 parity 的 60 天测试里断言 == 0。

### A3 修套件运行器

- `Invoke-RuntimeTests.ps1` 列表改为真实路径（`tests/runtime/...`、`tests/effect/...` 等，逐个 `Test-Path` 验证）；加一条：脚本不存在时直接记 failed（不要靠日志 marker）。
- parity 门禁在 A1 前是预期红：加 `$knownRed` 列表并在 summary 单独列出，不准从列表里删掉。
- 跑一次全套，把 summary 贴进 baseline。

### A4 parity 自身的健壮性

- R7-3 的 `field` 修正；R7-4 共享 catalog hash；
- pending 门槛：任一侧当天有未 ACK 的 transition → 记 `ideology_parity_uncompared_pending`，不计入 compared；
- `export → apply_pod_snapshot → export` 往返测试：业务 hash 逐位相等，`effect_instances`/`activation_signature` 保留；
- guard test 加敏感性断言：对 balance / baseline / ideas.level / offer 各改一个值，只有对应子段变化，`field` 指向它。

### A5 `latched` 上 wire（Effect POD ABI 2→3，须用户同意）

- `runtime_effect_pod.h:286` 的字段由 forwarder（`effect_instance_forwarder.cpp`，目前 0 处读写）在 worker 与 shadow 两条路径写入；worker 命令生成与 `EffectRuntime::apply_pod_snapshot` 回写 `STATE_LATCHED`；
- 跑 `runtime_worker_source_scan_test`、`runtime_effect_pod_test`；
- 新测试：worker 权威下 latched 卡在条件回落后保持、存档往返后保持。

### A6 mask 重新加入时强制 bump

- 修 `economy_runtime_family_buff.cpp:1248` 的 KNOWN GAP：consumers `generation` 变化且某列从 mask 外回到 mask 内时，强制 digest 重发（或把该列上次值清空）。
- 测试：列 X 离开 mask → 值变化 → 回到 mask，实例必须看到新值。

### A7 协同反向索引

- 编译期建 `synergy → (ideology, level) 程序列表` 与 `program → synergies`；`magnitude_scale_for`（当前 O(S) 扫描）改为按程序查表；`collect_affected_synergies` 只把受影响卡标脏。
- 计数器 `synergy_scale_scans`，空闲日断言 0。

### A8 P3-B tag 快照不可变化

- `_epoch_tag_bits` / `_country_tag_counts`（`economy_runtime.h:6423`、`:6438`）改为 COMMIT 尾部构建的 `shared_ptr<const EpochTagSnapshot>`，读者单次 `atomic_load`；const 方法内不再惰性构建。
- 同步 X7 count 的读者；跑 metric publish、gate chain、tag selector 测试。

### A9 文档漂移

- 五份 SKILL.md（`.agents/.claude/.codex/.cursor/.dsh`）第 218-221 行仍写 `51..55`，更新为 51..67 并写明 56..66 tag count、67 distinct specialized goods；
- 设计文档 §35 / §37.7 / §41.5 按真实状态修订（01 P3-A）。

阶段 A 的 DoD：parity 绿且确定、套件真实可跑、A2 生产零开销计数器为 0、05 表里 01 的 P1/P2 全部有实测证据。

---

## 3.5 内容轨道（与阶段 A 并行，占主要精力）

依据：`ideology-build-redesign.md` 末尾可达性矩阵——179 张卡中 9 张可直接做，79 张只缺 1 项，其中 **55 张只卡在 X1**。

C0 当前可达卡落地（生成器-only，第 1 轮）
- 先核对 9 张“可直接做”卡在生成器里的现状（`generate_ideology_catalog.py` 里已能搜到 7 张的 id，`land_tax_reform`、`excise` 未搜到），列出“已按新设计实现 / 旧版本 / 未实现”。
- 按设计文档的 L1/L2/L3 数值补齐或改写，重新生成 catalog。
- 每张卡一条端到端断言：装备 → 条件满足 → 目标格/国家的 stat 变化等于设计值；条件不满足 → 无变化；卸下 → 恢复。放进 `ideology_mechanism_matrix_test` 或新建 `ideology_card_content_test`。
- 跑 `ideology_content_test`、`ideology_effect_metric_publish_test`、`ideology_effect_worker_forward_test`。catalog hash 变化 → 旧档 fail-closed，写进 05。

C1 X1-b（每源叠加 + 半径 N），解锁 55 张
- 设计见 02 的 X1 行和 03 的 bitset 模型：Economy 在 COMMIT 派生每程序的 source-count 列，magnitude = min(count, cap) × per_source；半径 N 用 BFS。
- 开工前先跑一个最小基准（B1：64 国 × 12 卡 × 32 格，主线程 + worker），写下当前 p95，用于判断 X1-b 有没有把成本放大。
- 生成器 DSL：`per_source`、`radius`、`cap` 三个参数；校验非法组合。
- 完成后按矩阵顺序批量写卡（每批 10-15 张，每张一条端到端断言），每批后重跑 `tools/ideology/audit_card_reachability.py --write`。

C2 之后按矩阵“单独卡住多少张”排序：X5（8）→ X4 / X13（各 5）→ X6（4）→ X10 / X11。每项都是“先补能力，再写卡”。

内容轨道的红线：不引入新的每日全量扫描；不修改共享 Effect 模板语义；新 stat 同步 `stat_key_families.gd`；不动系数平面（保持关闭）。

---

## 3.6 双会话分工（同一工作树）

两个 DeepSeek 会话共用 `D:\Godot\ProjectKeynes\Project.Keynes`（未提交改动很多，新 worktree 拿不到它们，所以不拆 worktree）。

| | 会话 R（runtime，已在跑） | 会话 C（内容落地，新开） |
|---|---|---|
| 任务 | §2.9 R8-*、§3 A1-A9、parity | §3.5 C0 → C1 → C2 |
| 独占文件 | `runtime_ideology_pod.*`、`native_simulation_host.*`、`world_ext_*.cpp`、`runtime_pod_protocol.h`、`effect_instance_forwarder.cpp`、`runtime_effect_pod.*`、`tests/runtime/*`、`baseline-2026-10-21.md`、`05-implementation-status.md` | `tools/ideology/generate_ideology_catalog.py`、`data/ideologies/*.tres`（生成物）、新建 `tests/ideology/ideology_card_content_test.gd`、`ideology-build-redesign.md` 可达性矩阵、新建 `09-content-status.md` |
| 共享文件（改前先在各自状态文档写一行“正在改 X 的 Y 函数”） | `ideology_runtime.{h,cpp}`：R 只动 accrual / save / restore / export_pod_*；C 只动 effect activation / resolution | `economy_runtime_family_buff.cpp`、`effect_runtime.cpp`、`stat_key_families.gd`：C1 起由 C 使用，R 不动 |

规则：
1. **构建互斥**：同一时刻只能有一个 scons。构建前检查 `tmp/scons.lock`；不存在就写入“会话名 + 时间”，构建结束（成功或失败）立即删除；存在就等。超过 20 分钟的锁视为遗留，可删并在汇报里写明。
2. **测试前后对 DLL 时间戳**：`addons/dots_ext/bin/windows/dots_ext_annual_v1.windows.template_debug.x86_64.dll` 的 LastWriteTime 在测试前后不同 → 结果作废重跑。汇报里写明测试所用 DLL 的时间戳。
3. **编译失败归属**：报错文件不在自己的独占范围 → 不要修，等 1 分钟重试；仍失败就在汇报里写“被对方阻塞”。
4. **catalog hash**：C 重新生成 catalog 会改变 hash，R 的 parity/存档测试会看到变化。C 每次重新生成后在 `09-content-status.md` 顶部写一行时间和新 hash；R 遇到 `catalog_mismatch` 类失败先查这一行。
5. **不准 revert 对方的改动**，包括对方的临时探针（`tests/**/_tmp_*.gd`）。
6. C0 是生成器-only，不需要 scons；先做 C0 可以最大限度避开构建冲突。

---

## 4. 阶段 B：03 基准先行（没有数字不准开始平面重做）

1. 在 `ideology_runtime_stress_test.gd` 加场景生成器，覆盖 03 §6 的 B1-B6：64 国 × 12 张已装备 × 每卡 32 格 cell program；worker 与主线程两种权威；固定种子；同一 debug DLL。
2. 输出：每日 ideology 阶段 p50/p95、reconcile 次数、submit_batch 次数、metric 发布/跳过数、digest 成本、`instance_refresh_visits`。
3. 空闲场景（无人口/建筑变化 30 天）断言：`sparse_idea_scan_count`、`dormant_scan_count`、`command_queue_resorts`、`command_queue_shift_steps`、`instance_refresh_visits`、`instance_submit_batches`、`ideology_reference_exports`、`synergy_scale_scans` 全为 0。
4. 门槛（skill）：64 国 p95 ≤ 0.35 ms，512 国续跑 p95 ≤ 0.42 ms，单次 native 调用 ≤ 1 ms。
5. 在 baseline 写下第一组数字，再做 O4-O8：
   - O4 每日共享 cell metric cache（mask 并集）；
   - O5 热路径 5 处 `effect_program_key` 字符串查找 → 编译期 dense program id；
   - O6 held/desired 用排序向量或 hash-set 求差，去掉 O(held×desired)；
   - O7 reconcile 批次用可复用 scratch，去掉 Dictionary/Packed 分配（`ideology_runtime.cpp` 1601-1666 一带）；
   - O8 签名只混入该卡实际消费的列/标签的 digest（按列 digest，而不是全局 `effect_input_revision`），解决“活经济下每天全量 reconcile”。
   每项附前后数字。

---

## 5. 阶段 C：系数平面重做（03 推荐架构）

前置：阶段 A、B 完成。当前 v1 默认关闭（`_ideology_cell_plane_enabled`），保持关闭直到本阶段验收。

1. generation 改为内容 digest（`ideology_runtime.cpp:3614` 现为冻结的 `_cell_program_generation + 1`）；Economy 缓存键 = (plane digest, tag snapshot generation, modifier stat version)。
2. 生成器给卡加 `plane: true`；plane 卡**不**进入 `collect_effect_activations` 实例路径，消除重复计算；PKEF binding 审计对 plane 卡豁免并在审计里显式列出。
3. MUL 语义与 Modifier 一致：`1 + (factor - 1) * magnitude`（`modifier_runtime.cpp:765`），支持 stacks。
4. 单一发布点：ideology 状态变更（ACK 成功、synergy 翻转、apply_pod_snapshot）后由同一函数生成表；worker 权威下也发布（不要挂在会被 suppressed 的 `run_ideology_daily` 尾部）。
5. 只在结构变化时发布；`set_ideology_cell_programs` 与 economy worker 的读取用不可变快照交换，不在主线程原地改 CSR。
6. explain/UI 从平面读取。
7. 验收：plane 与实例路径同场景同值（非重复）；B 阶段空闲计数器仍为 0；p95 不劣化；worker/主线程 parity 覆盖 plane digest。

---

## 6. 阶段 D：02 能力补齐

每项交付前写一段：owner 域、数据源、存储/派生方式、存档影响、生成器 DSL 改动、测试。

顺序：
1. 便宜的只读量：X2（邻接 tag 计数、连通分量大小，COMMIT 派生列）、X12（边境/河流/运河/流域）、X10（国家科技位/时代里程碑）、X14（`CountryClassOpinionSnapshot`）。
2. P2-D 内容阻塞项：每格贸易 stat 的 Economy 读者（生成器 `DEAD_STAT_KEYS` 第 143 行仍列着 `economy.city.trade_output_factor`）、`ideology.city.*` 的 `.mul` 孪生、×3 每格软上限；同步 `stat_key_families.gd`。
3. X4 事件叠层：per (country, program, cell) 层环 + 独立到期，由 commit-diff 事件驱动；PKID/Economy 存档字段。
4. X5 其余覆盖形式（范围/阈值/上限/条件），在 ideology 解析时按国覆盖，不改共享 Effect 模板。
5. X9 家族影响、X13 气候计数器。

每完成一项，重跑 `tools/ideology/audit_card_reachability.py`，在 05 记录可达卡数变化。

---

## 7. 每轮交付格式

```
## 本轮改动
- 项目编号 / 文件:行 / 一句话
## 实测
- 构建末行
- 每个测试的 "N checks, M failures" 原文 + SCRIPT ERROR grep 结果
- 基准数字（如有）
## 版本变化
- PKID / PKEF / POD ABI / catalog hash：old→new，fail-closed 行为
## 未达成 / 推断
- ...
```
