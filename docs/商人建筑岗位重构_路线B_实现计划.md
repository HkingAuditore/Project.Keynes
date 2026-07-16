# 商人建筑岗位重构 · 路线 B · 实现计划

> 状态：**已确认，编码进行中**（2026-07-16）
> 目标：真正让 merchant 成为「商栈」建筑提供的 owner 岗位，不再游离于就业体系之外。
> 决策已全部拍板（6 项）：
> ① **岗位类型**：仅 owner 岗（商栈每栋 1 个 owner=merchant，复用现有 owner 招募通路 cpp:4497）。
> ② **保底做市商**：建筑岗替代保底（生成测试经济数据时每个有人地块生成 1 个商栈，其 owner 即做市商）；`ensure_merchant_invariant` 降级为兜底。
> ③ **漂移问题**：本次一并修（merchant owner_employed 纳入第 1 步析出重算）。
> ④ **产出/时代**：无产出 + 全时代解锁（纯服务性建筑）。
> ⑤ **building_kind**：新增专门的「服务/做市」枚举值（kind==2），同步 schema + codegen，**SCHEMA_VERSION 12 → 13**（经核实当前基线为 12，Task#6 的递增未落地）。
> ⑥ **owner 成本**：商栈 owner（merchant）作为普通 owner 承担 living_cost / 工资诉求。

---

## 一、现状：商人为何游离于体系外

`merchant` 是市场中枢实体（家庭收款方 / 投入卖方 / 做市商 / 贸易持有 / 铸币持有），当前通过 6 处硬机制维持「每个有人 cell 至少 1 个 merchant」，且把 merchant 排除在就业分配之外：

| # | 位置 | 作用 | 路线 B 处理 |
|---|------|------|-------------|
| A | `ensure_merchant_invariant` cpp:457 | 每有人 cell 从最大人口非商人 cohort 拆出/转换出 1 个 merchant | **保留为兜底**（商栈已满足不变量，此处只在边缘情况触发） |
| B | `rebuild_merchant_ranges` cpp:547 | 依 merchant slot 建做市商索引 `_merchant_primary_slot` | **不变**（商栈 owner 即 merchant slot，天然被收录） |
| C | owner=merchant 硬限制 cpp:2743-2758 | 仅允许金/银矿做 merchant-owned 建筑 | **放行无产出商栈**（见 §3.1） |
| D | 就业跳过①容量统计 cpp:4398 | merchant slot 不计入 employee 容量 | **保留跳过**（商人只做 owner，不做 employee，容量统计无关） |
| E | 就业跳过②surplus 收集 cpp:4417 | merchant slot 不被裁员析出 | **改：不再无条件跳过**（见 §3.3，漂移根因） |
| F | 就业跳过③在岗聚合 cpp:4569 | merchant `owner_employed/employee_employed` 不计入全局在岗 | **改：纳入 owner 聚合**（见 §3.3） |

**漂移根因链**：owner 招募（cpp:4497-4526）把 `unemployed|eth` 的人 move 到 `merchant|eth` slot 并记 `owner_employed`；但 E/F 两处跳过使该 slot 的 `owner_employed` 从不被第 1 步析出重算、也不计入全局在岗 → 单调累加、裁员不同步 → 人口侧与建筑侧漂移。

---

## 二、目标语义

- 新增建筑类型 `merchant_post`（商栈）：`building_kind` 服务类、`owner_profession=merchant`、`owner_slots=1`、**无 employee role、无 output good、无 resource**、全时代解锁（无 tech 前置）。
- 生成测试经济数据时（`economy_test_bootstrap.gd`），每个有人居住地块放置 1 个 `merchant_post`，其 owner 即该 cell 的做市商。
- 商栈 owner（merchant）像普通 owner 一样：从失业池招募、计入 `filled_owner`、参与析出/裁员、计入全局在岗计数。
- `ensure_merchant_invariant` 降级为**兜底**：正常情况下商栈已保证不变量；仅当某 cell 有人但无商栈（异常/存量数据）时才触发旧的拆分逻辑，避免 `rebuild_merchant_ranges` 报 `merchant_invariant_broken`。

---

## 三、C++ 内核改动（economy_runtime.cpp / .h，需 rebuild DLL）

### 3.1 放行无产出商栈（cpp:2743-2758）
当前：`owner_prof==merchant` → 强制金/银矿采集器（单输出 gold/silver + 单资源 + behavior=1 + kind=0）。
改为：`owner_prof==merchant` 时，**允许两类**：
- (a) 旧的金/银矿采集器（保持原校验，向后兼容 gold_mine/silver_mine）；
- (b) 新的**无产出服务建筑**：`output_offsets` 空（0 输出）、`resource_offsets` 空（0 资源）、`generation` 空、`employee_count==0`、`building_kind` 为约定的服务类枚举值。
其余组合仍报 `merchant_building_must_be_matching_bullion_collector`。

### 3.2 owner 招募自然复用（cpp:4497-4526）
**无需改**：商栈 `owner_signature_id = merchant|eth`，owner 招募已按 owner_signature 的 eth 从失业池招人并记 `owner_employed`。仅需确保 owner_target 正确（=商栈 count × owner_slots）。

### 3.3 就业三处跳过点的精细化（核心风险区）
问题：merchant slot 现在既可能是「商栈 owner（应纳入就业）」，也可能是「invariant 兜底产生的游离做市商（不应被当雇员/业主处理）」。二者都是 `profession==merchant`，`is_merchant_slot` 无法区分。

**方案（拟）**：区分「merchant slot 上的 owner_employed 部分」与「游离部分」：
- **cpp:4398 容量统计**：保持跳过（商人不做 employee，不影响 employee 容量）。
- **cpp:4417 surplus 收集**：不再整段跳过 merchant slot。改为：对 merchant slot，`owner_here = min(sig_owner_retained[sig], pop)`（商栈 owner 份额），仅对 `pop - owner_here` 的**游离超出部分**判断是否析出。**关键约束**：游离做市商（invariant 兜底的那 1 个）必须保留，不能被裁进失业池——否则破坏做市商不变量。故 surplus 只对「超过 max(owner_here, 每 cell 保底 1)」的部分生效。
- **cpp:4569 在岗聚合**：merchant slot 的 `owner_employed` 计入 `_filled_owner_jobs`（不再跳过）；`employee_employed` 恒为 0 无需计。

> ⚠️ 这是全局在岗计数语义变更，会改变 `_filled_owner_jobs` 数值 → **bit-equal 基线会变**。需重新建立黄金基线，不能用旧基线判等。

### 3.4 ensure_merchant_invariant 降级为兜底（cpp:457）
逻辑不变，但语义上从「主力保底」变为「异常兜底」。正常流程下每个有人 cell 已有商栈 owner（merchant slot），`has_merchant==true` 直接 return，不触发拆分。仅存量数据/无商栈异常 cell 才拆分。**无需改代码**，行为自然退化。

### 3.5 SCHEMA_VERSION
若 BuildingType 序列化字段（如 building_kind 新枚举）变化，`SCHEMA_VERSION` 需 +1（当前 13 → 14）。存档/基线随之失效。

---

## 四、内容层改动（.tres）

### 4.1 新建 `merchant_post.tres`（两处镜像）
- `tools/codegen/economy_content/buildings/merchant_post.tres`（codegen 源）
- `Project/project-keynes/data/economy/buildings/merchant_post.tres`（运行时）
字段：`owner_profession="merchant"`、`employee_slots_per_building=0`、`output_quantities_per_day` 空、无 resource、无 tech 前置、`building_kind`=服务类。

### 4.2 building_profile.gd / 相关 schema
若新增 building_kind 服务枚举，需在 `building_profile.gd` 与 codegen（`gen_modern_economy_content.ps1` / `audit_economy_content.ps1`）同步。

---

## 五、GDScript 生成层改动

### 5.1 economy_test_bootstrap.gd（最终方案，2026-07-16 拍板）
**现状**：`economy_test_bootstrap.gd:189-199` 当前用「从最大非商人 profession 挖 1 人转成 merchant」（`merchant_bootstrap_substitutions`）来保底做市商。这个 merchant 是**游离做市商**——有 merchant cohort，但无建筑承载 → 数量与岗位脱节（本 bug 根源）。

**改法**（三处拍板的一致收敛）：
1. **每个有人居住地块显式生成 1 个 merchant cohort 作为商栈 owner 种子**（q-0：改成商栈会强行生成一个人作为 owner）。保留「每有人 cell 预置 1 merchant 种子」（q-2），但语义从「游离做市商」升级为「商栈业主」。
2. **同时为该 cell 放置 1 个 `merchant_post` 建筑**（count=1，owner_signature=merchant|default），承载这个 owner 岗位。
3. **做市预置资金仍挂在 merchant cohort 上**（q-1：保持挂 merchant cohort），行 233 逻辑基本不变（商栈 owner 即 merchant signature，`merchant_daily_inventory_value_by_cell` 继续按 cell 累计）。
4. **owner 招募兵源**：因种子人口直接预置，merchant cohort 从一开始就存在承载商栈 owner；native owner 招募会把该 cohort 从 `unemployed` 状态转为 `owner_employed`（若 bootstrap 初始全员 unemployed，则 merchant 种子也是 unemployed，招募把它转成商栈 owner 在岗）。

**与原挖人逻辑的关键区别**：
| | 原（挖人） | 新（商栈 owner） |
|---|---|---|
| merchant 来源 | 从别人岗位抢 1 人 | 每有人 cell 预置 1 种子 |
| 建筑承载 | 无 | merchant_post（1栋/cell） |
| 就业统计 | 被 is_merchant_slot 跳过 | 纳入 filled_owner 聚合/析出/裁员 |
| 数量关系 | 与岗位脱节（过剩） | ==商栈数==有人cell数 |

**实现要点**：merchant cohort 的预置需在人口 cohort 循环中完成（行 200-214 之前或之中），且 merchant_post 建筑放置需与之配对（同一 cell）。移除 189-199 的「挖人」替换，改为「无条件为有人 cell 追加 1 merchant 种子 + 1 商栈建筑」。

---

## 六、验证与风险

### 验证步骤（用户本地）
1. rebuild DLL（先完全退出 Godot，避免 dll 锁）。
2. bake 测试经济数据，确认每个有人地块生成 1 个 merchant_post。
3. 复跑 cell575（或指定 cell）CSV recorder，检查：
   - 商人数量 ≈ 商栈数量（不再远超岗位）；
   - 做市 / 家庭收款 / 铸币持有等市场功能正常；
   - 无 `merchant_invariant_broken` / 无 fallback；
   - 就业在岗计数 `_filled_owner_jobs` 含商栈 owner 且无漂移（多周期后人口侧==建筑侧）。

### 主要风险
- **R1 做市商不变量破坏**：§3.3 裁员若误裁游离做市商 → `rebuild_merchant_ranges` 报错。缓解：保底 1 个 merchant 永不析出。
- **R2 基线失效**：§3.3/§3.5 改变 `_filled_owner_jobs` 与可能的 schema → 旧 bit-equal 基线不可用，需重建。
- **R3 存量存档**：老存档无商栈，靠 invariant 兜底运行，但商人不进就业体系 → 与新逻辑混合行为需测试。
- **R4 双向依赖**：merchant slot 同时是「做市索引来源」和「就业 owner」，两套逻辑耦合，需仔细隔离游离份额 vs owner 份额。

---

## 七、实施顺序（拟，确认后执行）

1. **内容层**：新建 merchant_post.tres（两处）+ building_kind 服务枚举（若需）。
2. **C++ §3.1**：放行无产出商栈校验。
3. **C++ §3.3**：三处跳过点精细化（最高风险，单独提交 + 详细注释）。
4. **C++ §3.5**：SCHEMA_VERSION 递增（若字段变化）。
5. **GDScript §5.1**：bootstrap 每有人地块放置商栈。
6. **文档同步** + 用户本地 rebuild/bake/cell复跑验证。

---

## 待确认追加问题（如有）

- building_kind 服务类是否已有可复用枚举值，还是需新增？（影响 §3.1 校验条件与 schema 是否变更）
- merchant_post 是否需要 owner 消费 need（作为普通 owner，会有 living_cost / 工资诉求）？还是设为「零成本」纯做市实体？
