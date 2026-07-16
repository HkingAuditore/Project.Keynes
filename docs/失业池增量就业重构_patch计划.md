# 失业池增量就业重构 —— Patch 计划

> 目标：把 `run_building_employment_cell` 从"每市场周期全量清零重建岗位"改为
> "**缩产建筑裁员 → 失业者进入显式持久失业 cohort → 按优先级从失业池增量招人**"，
> 并把失业者升级为一等（可存档、可 UI 查询、按 ethnicity 分桶）的 cohort。
>
> 责任边界（authority）：本 patch 触及 **#1 内容 / #2 native 热循环 / #3 状态布局+ABI+save schema / #4 调度（清零时机）**。不触 #6 policy。
> **商人不纳入失业机制**（维持 `ensure_merchant_invariant`）——本决策在下文与运行时文档中显式写明。

---

## 0. 背景与动机（诊断结论回顾）

- 现状 `run_building_employment_cell`（economy_runtime.cpp:4149）每个 `BUILDING_EMPLOYMENT` 阶段：
  1. L4190 把该 cell 所有 cohort `owner_employed/employee_employed` 清零；
  2. L4194 把所有建筑 `filled_owner`/`_building_employee_filled` 清零；
  3. L4203 用前缀和从零按比例重摊派。
- 后果：`owner 岗位 = population × slots × planned_utilization_q16`，与 util **线性绑定且每周期从零重算**。util 一旦被缩产公式从 100% 打到 3%（cell575 实测），下一周期 owner 岗位立刻塌到 3%、97% 当场失业，**零跨周期缓冲**——这是"无缓冲失业"的实现层根因。
- 现有 `_unemployed_population`（h:1048）只是**派生统计量**：L6841 归零、L4308 现推累加、导出 CSV/report，**未进 save/hash，失业者无独立身份**。

用户拍板的目标语义：
1. 优先级：**先喂最赚钱，再喂最想扩产，平局按稳定序**。
2. 已就业不动：util 不变的周期，存量岗位不刷新；只在缩产/扩产/人口变动时处理增量。
3. 失业者是**显式、可存档、按 ethnicity 分桶**的一等人群；允许长期失业。
4. profession 视为**可变就业状态**（不关心历史职业，只关心存款；消费随新职业变）。
5. **商人不失业**（本次不做，独立设计）。

---

## 1. 架构决策（已确认）

| 项 | 决策 | authority |
|---|---|---|
| 失业者身份 | 新增 `profession=UNEMPLOYED` 的 signature 组，**每 ethnicity 一个** | #1 内容 + #3 signature 表 |
| 失业者消费 | 新增极简 `plan_unemployed`（仅 survival_food） | #1 内容 |
| 裁员/招人机制 | **复用已有 `COMMAND_CHANGE_SIGNATURE` 的拆分/合并/资金守恒结构化命令**（cpp:7208 / L479-510 已实现拆分+按比例转资金+handle 重映射） | #2/#3/#4 |
| 招人优先级键 | `(realized_profit_margin_q16 desc, planned_utilization_q16 desc, group_index asc)` —— 全是 `BuildingGroup` 现成整数字段（h:349 / h:342） | #2 |
| 失业人数聚合 | `_unemployed_population` 从派生量**升级为按 (cell) 可查询 + 进 save/hash** | #3/#5 |
| count→0 / unavailable 建筑 | 显式归零 `filled_owner` + 扣减对应 cohort 在岗，释放入失业池 | #2 |
| 商人 | `is_merchant_slot` 直接跳过裁员/入池/招人 | 文档写明 |
| Schema | `SCHEMA_VERSION 12 → 13` | #3/#5 |

**为什么复用 CHANGE_SIGNATURE 而非新写迁移逻辑**：cpp:479-510 已实现"从一个 cohort 拆出 N 人、按比例带走资金、分配/合并到目标 signature slot、handle 重映射、touch_accounting 守恒"。裁员=原职业 signature→UNEMPLOYED signature；招人=UNEMPLOYED signature→目标职业 signature。资金随人走（符合用户"只关心存款"），plan/birth/death/ethnicity 随目标 signature 自动切换（符合"消费随新职业变"）。**不新增每-slot 逻辑分支，符合 DOTS。**

---

## 2. 内容层改动（authority #1，先做，无需 rebuild）

### 2.1 新增 `plan_unemployed`
- 位置：`data/economy/`（消费计划定义处，具体文件由 `economy_catalog` 编译）。
- 内容：只含 `staple_food`/`survival_food` need（最低生存），其余 need 移除或权重压到 floor。
- 校验：`desired_need_units`（cpp:881）会读该 plan 的 need 集；确保 survival_required_units（cpp:912）仍能对失业者取到 survival_food need_index，否则失业者不吃饭、必饿死（这是设计允许的"失业惩罚"，但要可控，不是 NaN）。

### 2.2 新增 UNEMPLOYED signature 组（每 ethnicity 一个）
- signature 定义（h:241 `Signature{profession_id, ethnicity_id, plan_id, birth_rate_q32, death_rate_q32, satisfaction_birth_weight_q16}`）：
  - `profession_id = UNEMPLOYED`（新增一个保留 profession id，catalog 里登记，**不可作为任何建筑 owner/employee 的 profession**）。
  - `ethnicity_id = 各族裔`。
  - `plan_id = plan_unemployed`。
  - `birth_rate_q32` 略低、`death_rate_q32` 略高（失业者过得差，Q1=a 已定；具体数值内容层可调）。
- 生成时机：与现有 signature 表一同在 catalog compile 阶段构建（cpp:2352 `_signatures[i] = {...}` 附近）。必须保证 UNEMPLOYED signature 的 id 在表中**稳定有序**（否则 hash 漂移）。
- 参照 `ensure_merchant_invariant`（cpp:481-488）"按 ethnicity 查找 merchant signature"的模式，新增 `unemployed_signature_for_ethnicity(eth)` 查找/缓存。

---

## 3. Native 状态布局改动（authority #3）

### 3.1 `BuildingGroup`（h:320）
- **不新增字段**：`filled_owner`（h:325）直接复用为"跨周期存量 owner 在岗数"，`_building_employee_filled[]` 复用为存量 employee 在岗。关键改动是**不在周期头清零它们**（见 §4）。

### 3.2 `PopulationStore`（h:365）
- **不新增每-slot 列**：失业者就是 `signature_id == UNEMPLOYED×eth` 的正常 cohort，`population[slot]` 即失业人数，`funds[slot]` 即其存款。`owner_employed/employee_employed` 对 UNEMPLOYED cohort 恒为 0。

### 3.3 失业聚合量（h:1054）
- `_unemployed_population` 语义变更：从"population−employed 现推"改为 **Σ(UNEMPLOYED cohort 的 population)**。
- **A1 下自动成立**：cpp:4544 的现有累加式 `unemployed = pop − owner_employed − employee_employed` 在 A1 下天然等于 Σ(unemployed cohort population)——因为在岗 slot 贡献 0（owner+employee==pop），unemployed slot 贡献全部 pop（owner=employee=0）。**无需改累加式**。
- 按 cell 查询：selected-cell 查询时现算（遵守 skill "never publish global cohort-by-good live snapshot"），全局只保留标量 `_unemployed_population`。

### 3.4 SCHEMA_VERSION —— **保持 12，不升 13（2026-07-16 用户确认）**
- **A1 使 Task #6 大幅简化**：失业者是一等 cohort（unemployed|eth signature），已**随 population section 进 save/hash/restore**。
- `_unemployed_population` 是**纯派生量**（=Σ unemployed cohort population），restore 后首个 employment tick 会重算得到相同值；唯一读取点是 CSV recorder（economy_csv_recorder.cpp:491）与 debug snapshot（cpp:9351），均非 gameplay 关键路径，restore 后到首 tick 之间读到陈旧值仅少一行准确 CSV，无害。
- `filled_owner`/`_building_employee_filled` **早在 save/hash 契约内**（BuildingGroup 状态），语义从"周期内重算"变"跨周期存量"但**二进制布局不变**，无需扩字段、无需升 schema。
- 结论：**不升 SCHEMA_VERSION、不把 _unemployed_population 写入 binary save/hash**（避免冗余 + 时序脆弱性：employment 前后值不同，若 hash 在 employment 前算会与存档往返不一致）。
- **旧存档兼容**：旧 v12 存档若无 unemployed cohort，restore 后首个 employment 周期按 A1 规则自然生成失业池（自愈），无需迁移代码。

---

## 4. 就业热循环改写（authority #2/#4，核心）

> **实施状态（2026-07-16 已落地 cpp:4223-4531）**：最终采用 **A1 路径（真实人口迁移）+
> 统一净增量两步**，数学上等价于下方"消失清理+建筑驱动裁员+优先级招人"三阶段，
> 但把三者合并为两步以让 owner/employee 在同一 profession|eth slot 内自然竞争 population，
> 免去阶段间显式传递 slot 剩余容量。用户 2026-07-16 连续拍板：
> ① 数据模型走 A1（人真实住在 signature slot，裁员=迁往 unemployed|eth，招人=迁回）；
> ② 裁员是**建筑驱动**（每 group 按自身 filled-target 独立裁，slot 被动承接）；
> ③ 裁员用性能最优聚合算法（同 type_id+同 owner_sig 聚合为一 group，逐栋盈利无区分度）；
> ④ 招人盈利排序粒度=**跨 BuildingGroup（跨建筑类型）**，组内不排（稳定序）；
> ⑤ slot 语义 A1：非 merchant/非 unemployed 的 profession|eth slot 恒有 owner_employed+
>    employee_employed==population（无闲置，未被雇佣者立即迁往 unemployed|eth）。
>
> **实际两步（cpp:4223-4531）**：
> - **第1步 析出**：按本周期 planned_utilization 目标夹紧各 group 的 filled_owner /
>   _building_employee_filled（filled>target 的差额即裁员）；再按 profession|eth slot
>   聚合应保留在岗人口（owner 按 signature 精确、employee 按 profession 跨 eth 稳定序摊派），
>   surplus = population − retained 的部分**遍历外**用 move_cohort_population 迁往 unemployed|eth。
>   消失/不可用建筑目标=0，其在岗人口自然全部进池。
> - **第2步 招人**：unemployed 池此刻汇集全部失业者；活跃 group 按
>   `(realized_profit_margin_q16 desc, planned_utilization_q16 desc, group_index asc)`
>   stable_sort 跨类型排序，依次把 filled_owner/filled_employee 补到目标，从 unemployed|eth
>   **遍历外**迁回对应 profession|eth slot（owner 精确 eth、employee 跨 eth 升序取池），
>   受池可用量约束→低优先级/亏损 group 招不满即长期缺人（"先喂最赚钱"）。
> - **关键约束**：move_cohort_population 会 allocate/release slot 破坏 for_each_in_cell 页链，
>   故三处迁移全部"先只读遍历收集计划到 thread_local 缓冲，遍历后统一迁移"（学
>   ensure_merchant_invariant）；trace 快照改存稳定 handle（迁移后裸 slot id 会失效），
>   事件生成用 valid_handle 解析，失效 cohort 记归零 leg 闭合审计；商人全程 is_merchant_slot 跳过。
> - **_filled_owner_jobs/_filled_employee_jobs**：改为 employment 末尾按 cell 重扫
>   Σ owner_employed / Σ employee_employed（等价旧逐步累加，A1 下 = 全局在岗数）。

### 4.1 目标伪代码（语义参照；实际实现见上方实施状态）

```text
run_building_employment_cell(cell):
  prepare_cell_wages(cell)                     // 保留(cpp:4150)

  // ---- 阶段 A：清理"消失的建筑"（用户第3点已确认）----
  for g in [first,last):
    if group.count==0 OR !building_available(...):
      释放 group.filled_owner 人 → owner cohort 的 owner_employed 扣减
      释放 employee_filled[] → 对应 cohort employee_employed 扣减
      被释放的人 → CHANGE_SIGNATURE(原→UNEMPLOYED×eth) 入失业池
      group.filled_owner = 0; employee_filled[]=0

  // ---- 阶段 B：缩产裁员（收缩侧，**建筑驱动**，确定性）----
  // 语义顺序（用户 2026-07-16 纠正）：是"建筑先决定裁多少"，
  // 而非"职业 slot 主动失业再摊派"。每个 group 按自己的
  // filled_owner - target 独立决定裁员量，slot 是被动承接方。
  // 排序：CSR 稳定序（group_index 升序）即可 —— 当前经济体系同类型
  // 建筑聚合为同一 BuildingGroup，realized_profit_margin/util 是 group
  // 级字段，逐栋盈利排序无额外区分度，纯浪费。裁员用一趟线性扫描（性能最优）。
  for g in [first,last) 按 CSR 序:
    if is_merchant(owner) : continue            // 商人不裁
    target_owner = planned_owner_demand(util_now, count_now)
    if group.filled_owner > target_owner:
      diff = group.filled_owner - target_owner
      从 owner 的 <profession>|eth slot 迁 diff 人 → unemployed|eth：
        move_cohort_population(owner_slot, cell, unemployed_sig, diff)（资金随人走）
        group.filled_owner -= diff ; slot.owner_employed -= diff
    // employee 侧同理：逐 role 比较 _building_employee_filled[r] 与
    // planned_role_demand，超出部分从 role 的 <profession>|eth slot 裁入池。
    // target==filled : 不动 ← "已就业不动"

  // ---- 阶段 C：优先级招人（扩张侧，消费失业池）----
  // 招人才需要盈利排序：多个有空缺的 group 竞争有限失业池时，先喂最赚钱的。
  // **排序粒度 = 跨 BuildingGroup（跨建筑类型）**，不是逐栋：
  //   realized_profit_margin_q16 是 group 级字段；同 cell 内同 type_id+同
  //   owner_signature 的 N 栋建筑聚合为一个 group，组内盈利完全相同，对该
  //   group 整体按 need=target-filled 一次性招，不逐栋。排序只在 bakery
  //   group vs weaver group vs iron_mine group 之间做，用于失业池不足以填满
  //   所有 group 空缺时决定先喂谁。cell 只有一个非商人 group 时退化为直接招满。
  收集本 cell 有空缺的 group：need = target - filled > 0
  按 (realized_profit_margin_q16 desc, planned_utilization_q16 desc, group_index asc) 排序
  for group in 排序后:
    need = target_owner - group.filled_owner
    从 unemployed|eth 池按 need 招人（跨原职业）：
      hired = min(need, 池中同 ethnicity 人数)
      move_cohort_population(unemployed_slot, cell, <owner_profession>|eth, hired)
      group.filled_owner += hired ; 目标 slot.owner_employed += hired
    // employee 空缺同理，按 role.profession 匹配招人

  // ---- 阶段 D：重算聚合 ----
  _unemployed_population += Σ(本 cell UNEMPLOYED cohort population)
  trace / event legs（保留 cpp:4311-4330 的 diff 事件）
```

### 4.2 确定性要点（保 worker/scalar hash）
- 阶段 B/C 的建筑遍历、cohort 遍历必须走**稳定序**：建筑按 `(cell,type,owner_sig)` CSR 序（现有 `_building_cell_offsets`）、cohort 按 slot 序（`for_each_in_cell` 页链序）。
- 招人优先级排序键全为整数、平局用 `group_index`（CSR 内偏移）破平 → 全序确定。
- `CHANGE_SIGNATURE` 的拆分/资金按比例（cpp:500 `mul_div_sat`）已是定点 saturating，复用即确定。
- 招人/裁员的"人数"用整数、`std::min(need, pool)` 截断，无浮点。

### 4.3 profession 匹配（跨职业招人，用户第4点）
- owner 岗位仍按 `type.owner_profession_id`（cpp:4005）匹配——但"匹配"现在指**目标 signature 的 profession**，招人时把 UNEMPLOYED cohort 的人 CHANGE_SIGNATURE 成 `owner_profession_id` 对应 signature。即失业者**可跨原职业**被任意缺人的建筑吸收（符合"职业只是当前状态"）。
- 唯一约束：UNEMPLOYED cohort 招进某职业时，目标 signature 的 ethnicity 必须等于该失业者的 ethnicity（signature = profession×ethnicity×plan，ethnicity 不可变，符合 §2.2 分桶）。

### 4.4 商人保护（本次范围外，显式写明）
- 阶段 A/B/C 全程 `if (is_merchant_slot(slot)) continue;`（cpp:440 `is_merchant_slot` 已有）。
- `ensure_merchant_invariant`（cpp:457）保持不变、仍在其原调用点运行。
- 文档明确：商人失业/商业萧条是独立后续设计，未纳入本 patch。

---

## 5. 结构化命令时序（authority #4）—— 已定 **5a**，方案据真实源码修正

### 5.1 复用目标 = `commit_structural`（cpp:8111-8294），不是 `ensure_merchant_invariant`
本轮查证修正了上一版的错误假设。真正通用的迁移核心是 **`commit_structural`**：
- 支持**任意 N 人**从 `source_slot` 迁到 `(cell, signature)`（cpp:8166-8168 `move_pop = min(cmd.population, source_pop)`）；
- 按比例迁移 `funds/epoch_income/epoch_expense/income_ema/demography_residual`（cpp:8171-8190），人口加权合并 `needs_satisfaction`（cpp:8226-8234）；
- source 归零时把 rounding 残渣**转国库（不 burn）**、`release_slot`+`reclaim_empty_pages`（cpp:8242-8258）——守恒严密；
- 生成完整 `EventLeg` trace（cpp:8259-8292）。

而 `ensure_merchant_invariant`（cpp:479-515）是**写死 1 人**的特例（`source_population==1`、`-=1`），不通用，**不作为复用来源**。

### 5.2 5a 落地：抽 `move_cohort_population(source_slot, dst_cell, dst_signature, count, error)`
- 从 `commit_structural`（cpp:8155-8293，opcode!=0 分支）抽出纯迁移函数 `move_cohort_population()`；`commit_structural` 改为薄封装调它（opcode==0 的国库清算分支保持独立）。
- employment 阶段裁员/招人**直接调 `move_cohort_population()`**（内联同步，不经 `_structural_commands` 队列），从而**同周期**先裁员入池、后招人出池，满足"同周期再分配"。

### 5.3 5a 的真正难点：跨阶段副作用隔离（必须处理，否则 hash/守恒破裂）
`commit_structural` 现在运行于 `Stage::STRUCTURAL_COMMIT`，其副作用依赖两个阶段级状态，employment 阶段内联调用**必须显式处理**：

1. **`_structural_touched_cells`（cpp:8169-8170 push）**：structural 阶段结束后用于触发 CSR/merchant range 重建。employment 阶段调用时若也 push，会与 structural 阶段的语义混叠。
   → 解法：`move_cohort_population` 增参 `std::vector<int32_t>* touched`，employment 传入**本函数局部的 touched 集**，在 `run_building_employment_cell` 末尾自行处理（见下条），不污染 `_structural_touched_cells`。
2. **CSR / merchant primary 重建（`rebuild_merchant_ranges` cpp:547）**：迁移会 `allocate_slot`/`release_slot` 改变 cohort 页布局。employment 只动**非商人** cohort（商人被排除），但新建的 UNEMPLOYED slot 会加入页链。
   → 解法：employment 内的迁移**不新增/不删除商人 slot**（商人不参与），故**无需触发 merchant range 重建**；但 `for_each_in_cell` 页链在迁移中被修改——**关键约束**：裁员/招人循环**不能在 `for_each_in_cell` 遍历途中 allocate/release slot**（会使迭代器/页链失效）。必须**先快照本 cell 的 cohort slot 列表到 thread_local vector，再在快照上迁移**（现有 employment 已用 thread_local `trace_slots` 模式，cpp:4179-4188，沿用）。
3. **`_structural_funds_to_treasury`（cpp:8245）**：source 归零残渣转国库。employment 迁移也可能触发（整组失业且有 rounding）。这笔钱进国库是守恒的，但审计归类需确认在 employment 阶段计入正确的 error bucket。
   → 解法：保留该行为（残渣转国库、不 burn），在 employment 的守恒审计里显式纳入 `_structural_funds_to_treasury` 增量。

### 5.4 实施子步（对应 §7 步骤 2，扩展为 bit-equal 三段）
- (2a) 抽 `move_cohort_population()`，`commit_structural` 改薄封装。**行为 bit-equal**：rebuild + N=1 + hash 相等（不改任何调用点，纯重构）。
- (2b) 给 `move_cohort_population` 加 `touched` 出参 + slot 快照保护；`commit_structural` 传 `&_structural_touched_cells` 维持原行为。再次 bit-equal 验证。
- (2c) 之后才允许 employment（§7 步骤 3-5）新增调用点。

> **风险闸门**：2a/2b 任何一步 hash 不 bit-equal，立即停并定位——这是本重构最重要的早期拦截点。

---

## 6. 文档同步清单（authority 要求，同一 patch 内完成）

> **实施状态（2026-07-16）**：§6 原列的 `references/architecture-and-data.md` 等文件在当前仓库不存在；
> 权威运行时文档实际是 `docs/cpp-dots-runtime/native-economy-runtime.md`（唯一描述就业机制处）。已同步：

- ✅ `docs/cpp-dots-runtime/native-economy-runtime.md`（L192 段）：失业者升级为一等 cohort（unemployed profession + plan_unemployed + 按 eth 分桶）；A1 存量语义（owner+employee==population，未雇佣者迁 unemployed|eth）；`_unemployed_population` 为派生量、不进 save/hash；starvation 自动施加失业惩罚。
- ✅ `docs/cpp-dots-runtime/native-economy-runtime.md`（就业时机段）：从"周期开始全量清零重建"改为"增量就业（夹紧裁员入池 + 跨类型优先级招人 + 跨周期缓冲）"；招人优先级键；跨原职业招人；**商人排除**显式落文。
- ✅ 本 patch 计划 §3.3/§3.4/§4/§7 更新为 A1 实际实现 + Task #6 保持派生量不升 schema 的结论。
- N/A `SCHEMA_VERSION`：经确认保持 12，无需改注释/契约（失业 cohort 随 population section 存档）。

---

## 7. 实施顺序（分步可验证）

> **实施进度（2026-07-16）**：步骤 1-6 源码全部落地；步骤 7 文档已同步。**本环境无法 rebuild/跑测**，
> 所有 rebuild + N=1 + hash bit-equal + 守恒 + 存档往返 + cell575 复跑验证**待用户本地执行**。

1. ✅ **内容层**（§2）：`plan_unemployed.tres` + `unemployed.tres` profession + catalog 登记 `UNEMPLOYED_PROFESSION_ID`（owner/employee 校验拒绝它）+ economy_profile `unemployed_profession_id` + native 镜像解析 + `_signature_by_profession_ethnicity` 稠密缓存 + `signature_for_profession_ethnicity`/`unemployed_signature_for_ethnicity` O(1) helper。
2. ✅ **无害重构**（§5.4）：(2a) 从 `commit_structural` 抽 `move_cohort_population()`（bit-equal）；(2b) 加 `source_drained_out` 出参 + slot 快照保护（commit_structural 传 nullptr → bit-equal）。
3-5. ✅ **就业热循环重写**（§4，cpp:4223-4531）：采用 **A1 统一净增量两步**（消失清理+建筑驱动裁员合并为"第1步 析出"，优先级招人为"第2步"）。去掉周期头全量清零；trace 快照改存 handle；商人全程跳过；`_filled_*_jobs` 末尾重扫。
6. ✅ **聚合+schema**（§3.3/3.4）：`_unemployed_population` 在 A1 下现有累加式已等于 Σ(unemployed cohort population)，**无需改累加式**；经用户确认 **保持派生量、不升 SCHEMA_VERSION、不进 binary save/hash**（失业 cohort 已随 population section 存档）。
7. ✅ **文档**（§6/本节）已同步；⏳ cell575 复跑验证待用户本地（util 坍缩后失业应平滑、可长期失业、无抖动）。

---

## 8. 验证门槛（每步必过）

- **rebuild**：debug + release GDExtension 编译通过。
- **N=1 参考对照**：与全量重建版在若干典型 cell（含 cell575）对比逐周期 owner/employee/unemployed，差异必须可解释（增量版应更平滑，不是 bug）。
- **worker/scalar hash**：确定性复算相等（同输入同输出）。
- **守恒**：population/money/goods audit error **严格 = 0**（裁员/招人=cohort 迁移，人和钱守恒）。
- **存档往返**：v13 save→restore→hash 一致；v12 旧档 restore 后首周期自愈。
- **性能**：release avg/p95/max，稳态应低于全量版（增量）。
- **商人不变量**：每有人口 cell 仍恰有商人，无抖动。
- **饥荒可控**：失业者走 `plan_unemployed` 只吃 survival_food，death_rate 生效，无 NaN/负库存。

---

## 9. 已知风险与遗留

- **风险**：UNEMPLOYED signature 若被误当作建筑 owner/employee 的合法 profession，会导致失业者"自己雇自己"——需在 catalog 校验层禁止任何建筑 role 使用 UNEMPLOYED profession。
- **风险**：`split_cohort_to_signature` 重构若与现有 CHANGE_SIGNATURE 行为不 bit-equal，会在第 2 步就被 hash 抓出——这是有意的早期拦截点。
- **遗留（本次不做）**：商人失业/商业萧条（市场清算、失业商人库存归属、复业机制）——独立设计项。
- **遗留**：跨 cell 失业迁移（失业者迁到有岗位的邻格）——属 MOVE_POPULATION + 贸易拓扑，另议。
