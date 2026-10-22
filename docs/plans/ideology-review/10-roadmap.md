# 10 理念系统开发路线图（总入口）

> 日期：2026-10-22。读者：用户、会话 R、会话 C。
> 本文件取代 08 的「阶段 A→B→C→D」顺序，是 01/02/03 的**唯一执行入口**。
> 01/02/03 仍是「为什么、怎么做」的设计依据；本文件只回答三件事：**做了什么、还差什么、按什么顺序做**。

---

## 0. 三条总原则（2026-10-22 起生效）

1. **只认 worker 路径。** 正式游戏 `player_game.gd:98` 设 `runtime_authority_domain_mask = 0xFFF`，理念在 worker 上跑。
   - 主线程理念路径**冻结**：不删（大量测试、存档恢复、OFF/SHADOW 调试仍在用），不再为它加功能，不再要求它与 worker 逐位一致。
   - 主线程测试保留为「快速单测」；**验收一律以 worker 路径测试为准**。
2. **parity 不阻塞。** `runtime_ideology_parity_test` 标为已知红，移出门禁。A1、R9-1 后半停工，已有代码不回退。
   以后需要时再单独排期，不挂在任何里程碑上。
3. **内容优先。** 每个里程碑的价值用「可做的卡数」衡量（审计脚本 `tools/ideology/audit_card_reachability.py`），
   基建只做「解锁下一批卡」或「不做就会出错」的部分。

---

## 1. 现在在哪（一页纸）

| | 01 问题修复 | 02 能力补齐 | 03 性能 |
|---|---|---|---|
| 完成度（估） | 约 65% | 约 5%（9/179 卡） | 约 15% |
| 已做 | P1-B、P1-C、P1-D、P2-B、P2-C 存档半、R8/R9 大部分 | C0 9 张卡写进生成器 | O1（粗粒度）、O2、O8 反向索引、EffectInputConsumers 不可变对象 |
| 卡在哪 | world_seed 测试红；latched 未上 wire；P3-B；P1-E | 内容测试挂起，9 张卡还没有一次有效验收 | 没有任何基准数字 |
| 下一步 | M0（§3） | M1（§4） | B1 基线（§5） |

实测（DLL 17:04:01）：`ideology_runtime_test` 70 checks / 1 failure（`world_seed: a different world seed changes the offer`）；
`ideology_card_content_test` 挂起（120 秒无输出）；`ideology_card_content_worker_test.gd` 已新建（17:21），未见运行结果。

---

## 2. 01/02/03 全部条目的状态总账

图例：✅ 完成（有实测）｜🟡 部分｜⬜ 未做｜⏸ 冻结/不做。「里程碑」见 §3–§8。

### 2.1 Doc 01（问题修复）

| 条目 | 状态 | 剩余工作 | 里程碑 | 归属 |
|---|---|---|---|---|
| P1-A 实例每日刷新 | 🟡 | 刷新通道已通；digest 是全局的，活经济下每天全量 reconcile。剩余部分并入 03 的 O8（按列/按卡 digest），**等 B1 有数字再做** | M2 | R |
| P1-B 快照全量重算 | ✅ | — | — | — |
| P1-C revision 无条件前进 | ✅ | — | — | — |
| P1-D X5 倍率三个洞 | ✅ | — | — | — |
| P1-E L2-8 层数不是 X4 | ⬜ | 文档更正 + 生成器拦截「ADD_STACK + DURATION 且非 X4 事件驱动」；真正的 X4 在 M2 | M0 | R |
| P2-A L1-6 聚合粒度 | 🟡 | 理念侧不再用 L1-6；多源计数由 X1-b 解决，本条随 M1 关闭 | M1 | C |
| P2-B 32 格截断偏置 | ✅（短期） | 长期去掉 32 上限 = 系数平面 | M3 | R |
| P2-C latched / tag 迟滞 | 🟡 | ① latched 上 wire（Effect POD ABI 2→3，已获同意）② tag `exit_threshold` 迟滞平面 | ①M0 ②M2 | R |
| P2-D 三个 stat 缺口 | 🟡 | 每格贸易 stat 读者、`ideology.city.*` 的 `.mul` 孪生、×3 软上限 | M2 | C |
| P3-A 文档/skill 漂移 | 🟡 | 每个里程碑收尾时同步一次，不单独做 | 每个 | 收尾方 |
| P3-B mutable 惰性缓存线程安全 | 🟡 | consumers 已不可变；`_epoch_tag_bits` / `_country_tag_counts` 仍是 const 方法里惰性构建，需 COMMIT 时生成不可变快照 | M0 | R |
| R8-1 / R8-3 / R8-4 / 6b / R9-2 / R9-3 / R9-5 | ✅ | — | — | — |
| R9-4 world_seed 测试 | 🟡 | 测试写了但是红的：要么 seed 没进 offer，要么断言错 | M0 | R |
| A1 / R9-1 后半 / parity 绿 | ⏸ | 冻结，见 §0 | — | — |
| A2 parity 零开销 | ⬜ | 只需保证非 parity 模式下 `ideology_reference_exports == 0`，并入 B1 空闲计数器检查 | M0 | R |
| A6 mask 重新加入时强制 bump | ⬜ | 小修，跟 P3-B 一起 | M0 | R |
| A7 协同反向索引 | ✅ | `_synergy_override_index` | — | — |

**01 关闭条件（替换 01 §14 的原 DoD）：**
- `ideology_runtime_test`、`runtime_domain_pod_test`、`runtime_ideology_save_roundtrip_test`、`ideology_effect_worker_forward_test` 全绿；
- latched 在 worker 转发后保持（新测试）；
- P3-B 后 TSAN 不可用的前提下，用代码审查 + 「worker 运行中主线程读 tag 计数」的压力测试证明无竞态；
- P1-E 生成器拦截有一条反例测试；
- 05 状态表同步。parity **不在**关闭条件里。

### 2.2 Doc 02（能力补齐）

「单独卡住」= 只缺这一项的卡数；「涉及」= 用到这一项的卡数（审计脚本，2026-10-21）。

| 能力 | 现状 | 单独卡住 | 涉及 | 里程碑 | 归属 |
|---|---|---|---|---|---|
| 现有能力即可 | ✅ 9 张已写 | 9 | — | M1（验收） | C |
| X1-b 多源叠加 + 半径 N | 🟡 | **55** | 123 | **M1** | C |
| X5 协同改范围/阈值/上限/条件 | 🟡 | 8 | 21 | M2 | C |
| X4 事件叠层 | ⬜ | 5 | 13 | M2 | R（存档/ABI）+ C（DSL/卡） |
| X13 气候计数器 | ⬜ | 5 | 13 | M2 | R |
| X6 槽位顺序 / 免费抽取 | 🟡 | 4 | 8 | M4 | C |
| X10 时代/科技 | ⬜ | 1 | 9 | M4 | C |
| X11 税 | 🟡 | 1 | 9 | M3 | C |
| X7 理念侧计数 | 🟡 | 0 | 25 | M3（缺 2 项里 X1+X7 有 17 张） | C |
| X9 家族 | ⬜ | 0 | 16 | M3（X1+X9 有 9 张） | R |
| X2 邻接 | 🟡 | 0 | 14 | M3（X1+X2 有 8 张） | C |
| X12 水系/边境 | ⬜ | 0 | 7 | M4 | C |
| X3 职业份额 | 🟡 | 0 | 6 | M3 | C |
| X14 民心 | ⬜ | 0 | 4 | M4 | C |
| X8 上下游 | ⬜ | 0 | 3 | M4 | C |
| X15 路线倾斜 | ✅（缺权重） | 0 | — | M4 | C |
| 横向：tag 迟滞 / 每格贸易 / 每格乘法 / ×3 软上限 | ⬜ | — | — | M2 | C |

注意：X1 做完后，审计里「缺 2 项」的 91 张会有大量降到「缺 1 项」，所以 M3 的排序要在 M1 结束时**重跑审计后再定**。

### 2.3 Doc 03（性能）

| 条目 | 状态 | 剩余工作 | 里程碑 |
|---|---|---|---|
| B1–B6 基准 | ⬜ | **只做 worker 路径**：B2（64 国）、B3（512 国续跑）、B4（1% tag 翻转）、B5（空闲 30 天）、B6。B1 主线程版取消 | M0 尾 / M1 并行 |
| O1 签名门控 + 切片刷新 | 🟡 | 门控已有；粒度粗，见 O8' | M2 |
| O2 值变化才推进 revision | ✅ | — | — |
| O3 按需 mask，国家/格级分开 | 🟡 | MetricMask 已有；X7 计数仍会触发整网格 tag 重建，需确认只在声明时触发 | M2 |
| O4 按天共享 cell metric 缓存 | ⬜ | 看 B2 数字决定 | M2 |
| O5 稠密 program id | ⬜ | `ideology_runtime.cpp` 仍有 6 处 `effect_program_key(` | M2 |
| O6 held/desired 排序归并 | ⬜（未核） | 看 B2 数字决定 | M2 |
| O7 可复用 scratch，去 Variant | ⬜ | 看 B2 数字决定 | M2 |
| O8 协同倍率查表 | ✅ | 反向索引 | — |
| O8' 签名只混入该卡消费的列 digest（= P1-A 剩余） | ⬜ | B4 若显示「每日 reconcile 数 ∝ 卡数」就必须做 | M2 |
| O9 按 tag 的格列表 | ⬜ | X1-b 实现时顺带（源格列表） | M1 |
| O10 不可变 tag 快照 | 🟡 | = P3-B | M0 |
| 系数平面重做（03 §4 / 08 §5） | 🟡 v1 默认关 | 只在「卡需要超过 32 格」或 B2 显示实例路径超门槛时启动 | M3 |

---

## 3. M0：01 收尾（会话 R，预计 4–5 轮）

目标：把 01 关掉，之后 R 转去做基准和 X4/X13 的存档部分。每轮只做一项，按顺序：

| 轮 | 任务 | 改哪里 | 验收（贴原文） |
|---|---|---|---|
| R-1 | world_seed 测试红 | `ideology_facade.gd` → native catalog → offer RNG 的种子混入点；或测试断言 | `ideology_runtime_test` N/0；说明是代码错还是断言错，附 `file:line` |
| R-2 | latched 上 wire（Effect POD ABI 2→3） | `runtime_effect_pod.h` 的 Input/Instance 加字段、`effect_instance_forwarder.cpp` 两条路径、`EffectRuntime::apply_pod_snapshot`、ABI 常量 | 新测试：worker 下条件 latched 后转发回主线程仍 latched；旧 ABI 存档被拒；`runtime_worker_source_scan_test` 绿 |
| R-3 | P3-B + A6 | `_epoch_tag_bits` / `_country_tag_counts` 改为 COMMIT 尾生成 `shared_ptr<const TagSnapshot>`，读者只 load 一次；mask 重新加入时 bump generation | 现有 tag/metric 测试全绿；新增「worker 跑 30 天期间主线程反复读 tag 计数」压力测试不崩、值单调合理 |
| R-4 | P1-E | 01 §7 文档更正；生成器在 program 校验处拦截非 X4 的 ADD_STACK + DURATION | 生成器反例测试（或 Python 断言）；catalog 重新生成且 hash 不变（若现有卡都合法） |
| R-5 | 01 关闭 | 跑 §2.1 关闭条件全部测试；更新 05、skill（P3-A 的这一次） | 测试原文表 |

M0 期间 R **不碰**：parity、系数平面、O4–O7。

---

## 4. M1：第一个可玩版本（会话 C，预计 6–9 轮）

目标：约 64 张卡在 worker 路径上有端到端验收（9 + X1-b 解锁的 55）。

### 4.1 C0 验收（1–2 轮）

1. **修挂起**：`ideology_card_content_test` 在每个 configure / native 调用前后 `printerr("[stage] ...")`，只跑一张卡，90 秒超时，定位挂起点并修。
2. **worker 验收**：`ideology_card_content_worker_test.gd` 对 9 张卡断言：装备 → 目标 stat = 设计值；条件不满足 → 不变；卸下 → 恢复。
3. DoD：两个测试都有完整 `N checks, 0 failures` 原文；09 更新。

### 4.1b X16 职业态度 stat（1 轮，unequip 修复之后、X1-b 之前）

起因：改税率的卡面对玩家等于免费调税，价值为零。规则与逐卡改写见设计文档 §47。

1. 新增两族 stat：`economy.profession.<pid>.tax_tolerance_factor`（MULTIPLY）和 `economy.profession.<pid>.satisfaction_bp`（ADD）。
   Economy 在 epoch 冻结处建 `country × profession` 表，在 `update_cohort_satisfaction` 里读；偏置放在天花板之前。
2. 生成器：V1 lint（禁止 `country.tax.`）；`_clamped_noop_reason` 扩到全部卡；职业分组常量；
   重写 `land_tax_reform`、`excise`；修存量的 `labour_legislation`、`land_reclamation`、`agricultural_chemistry`（设计文档 §47.7）。
3. 同轮加 metric 68 `cell.net_tax_burden_q16`（设计文档 §47.9），用它实现摊丁入亩 L3「轻税的农业支柱地块出生率 +8%」。
4. DoD：worker 路径同税率两国对照（税维度、综合满意度、理念点）；卸卡恢复；低税/高税两块农地只有前者出生率上升；审计重跑；新 catalog hash 记入 09。

### 4.2 X1-b 设计（1 轮，只写文档不写代码）

在 09 新开一节，写清 02 §4.1 的落地细节：
- 派生列 `source_count[tag, R]`：在 Economy COMMIT 尾计算，存在哪个结构里、怎么进不可变快照（复用 R-3 的 TagSnapshot）；
- R ≤ 2 用邻居表，R ≤ 4 用有界 BFS；源格列表顺带实现 O9；
- 消费方式：**沿用现有实例路径**（每格实例的 magnitude = `min(count, cap) × per_source`），不依赖系数平面；32 格上限仍在，审计里需要 > 32 格的卡单独列出；
- 生成器 DSL：`per_source`、`radius`、`cap`；非法组合拒绝；
- 存档影响（预期无，派生列可重算）、worker 侧是否需要 POD 字段；
- 测试用例清单（两源夹一格 = 2 倍；移除一源 = 1 倍；R = 3 走 BFS；cap 生效）。

**用户/reviewer 确认设计后再写代码。**

### 4.3 X1-b 实现（2–3 轮）

- 一轮做 Economy 派生列 + 单测；一轮做生成器 DSL + ideology 解析 + worker 端到端测试。
- 头文件改动合并到一次构建；构建前查 `tmp/scons.lock`。
- 实现后跑 B2/B4（若 R 已建好基准），确认 X1-b 没让每日成本和格数成线性。

### 4.4 批量写卡（2–3 轮）

- 每批 10–15 张，按设计文档 §5 的数值；每张卡一条 worker 路径端到端断言（可以做成表驱动）。
- 每批后跑 `audit_card_reachability.py --write`，在 09 记录可做卡数变化和新 catalog hash。
- M1 DoD：worker 路径验收卡数 ≥ 60；审计重跑；M3 排序重定。

---

## 5. B 基线：性能数字（会话 R，M0 结束后 1–2 轮，可与 M1 并行）

- 在 `ideology_runtime_stress_test.gd`（或新建 worker 版）加 B2/B3/B4/B5/B6 场景，**只跑 worker 路径**。
- 输出写进 `baseline-2026-10-21.md` 新节：p50/p95/p99、reconcile 次数、submit_batch、metric 发布/跳过、digest 成本、`instance_refresh_visits`。
- B5 空闲 30 天断言所有空闲计数器为 0（含 `ideology_reference_exports`，即 A2）。
- 门槛：64 国 p95 ≤ 0.35 ms；512 国 p95 ≤ 0.42 ms；单次 native ≤ 1 ms。
- **这一步只出数字，不做优化。** 数字决定 M2 里 O4–O8' 做哪几项。

---

## 6. M2：解锁第二批 + 性能按数字修（预计 2–3 周）

| 项 | 解锁 | 归属 | 要点 |
|---|---|---|---|
| X5 范围/阈值/上限/条件 | 8 张 + 增益类前置 | C | 按国覆盖表，在 ideology 解析时切换预声明的列/tag 变体，不改共享 Effect 模板（02 §4.5） |
| P2-D 三个 stat 缺口 + tag 迟滞 | 横向 | C（stat）、R（迟滞存档） | 新 stat 同步 `stat_key_families.gd`；迟滞平面进 Economy 存档，版本 +1 |
| X4 事件叠层 | 5 张 | R 先做 PKID/IDP2 存档与层环，C 后做 DSL 和卡 | 02 §4.4；PKID 8→9、IDP2 ABI 6→7 |
| X13 气候计数器 | 5 张 | R | 干旱天数、年均温、灾害事件，进 Economy 存档 |
| O8'（= P1-A 剩余）、O4–O7 | 性能 | R | 只做 B 基线显示超门槛或线性增长的那几项，每项附前后数字 |

M2 DoD：审计「可直接做」≥ 80 张且都有 worker 验收；B2/B3 达门槛；B5 空闲计数器为 0。

---

## 7. M3：X1 组合卡 + 系数平面（视需要）

- 按 M1 结束时重跑的审计排序；当前预期 **X7 → X9 → X2 → X11 → X3**（X1+X7 17 张、X1+X9 9 张、X1+X2 8 张、X1+X11 6 张）。
- **系数平面重做**（08 §5 的 7 条）只在以下任一成立时启动：
  - 有卡需要 > 32 格且无法用设计改写；
  - B2/B4 显示实例路径（每格一个 Effect 实例 + ACK）超门槛。
- 平面重做时必须一次做齐：内容 digest 代替冻结 generation、`plane: true` 卡不走实例路径、MUL 语义与 Modifier 一致、worker 下单一发布点、不可变快照交换、explain/UI 读平面。

---

## 8. M4：收尾到「新卡只改生成器」（02 §19 目标）

X6 槽位/免费抽取、X10 时代科技、X12 水系边境、X14 民心、X8 上下游、X15 路线倾斜权重。
DoD：审计「缺 1 项」为 0；随机抽 10 张未实现卡，只改生成器即可落地。

---

## 9. 双会话分工与依赖

```
R: M0(R-1..R-5) ──> B 基线 ──> X4 存档 / X13 / 迟滞存档 / O4..O8' ──> (平面, 视需要)
                         │
C: C0 验收 ──> X1-b 设计 ──> X1-b 实现 ──> 批量写卡 ──> X5 / P2-D stat / X4 卡 ──> M3 能力
                              ▲
                   依赖 R-3 的 TagSnapshot（若 R-3 未完成，X1-b 先读现有 tag bits，R-3 完成后切换）
```

文件归属沿用 08 §3.6，新增：
- X1-b 的 Economy 派生列（`economy_runtime_family_buff.cpp` 及相关）归 C；
- TagSnapshot（R-3）归 R；C 在 R-3 合入前只读不改相关结构。

---

## 10. 每轮工作规则（两会话通用）

1. **一轮一项。** 开工第一句写「本轮做 §X 的 Y」。
2. **测试一律 90 秒超时**；只输出 Godot 版本行（约 80 字节）= 挂起，不是 DLL 冲突。
3. **同一问题最多试两次**，两次不成停下，贴原文和自己的判断。
4. **头文件改动合并为一次构建**；构建前查 `tmp/scons.lock`，测试前后核对 DLL 时间戳。
5. **不准 revert** 不是本轮写的改动；整块删除前逐行确认。
6. **存档/ABI/catalog hash 变化** 先写 old→new 和 fail-closed 行为。
7. **汇报三段**：改了哪些文件（`file:line`）、测试原文（`N checks, M failures` + SCRIPT ERROR 数 + DLL 时间戳）、下一步。不写长文档；状态只更新 05（R）或 09（C）的表格行。
8. 每个里程碑结束时更新本文件 §1 和 §2 的状态列。
