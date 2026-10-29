# M5-68 §18.1 六个机制全部有证据 —— 并撞出三个真实问题

| 项目 | 内容 |
|---|---|
| 覆盖 | §18.1「copier、学派、协同、装卸、升级与精神晋升结果正确」——**此前是「无证据」** |
| 夹具 | `ideology_mechanism_equip_level_test`（133）、`ideology_mechanism_copier_school_test`（77）、`ideology_mechanism_synergy_spirit_test`（144）|
| 结果 | 全部 **0 failures**，且都经我**独立复跑**确认 |
| 日期 | 2026-10-28，Asia/Hong_Kong |

## 1. 六个机制的证据（都不是「非零」这种弱断言）

| 机制 | 关键断言 | 精确值 |
|---|---|---|
| **装卸** | 装备后 84 行 / 卸下后 **84→0**（恰好该卡行数）/ 重新装备回到 84 行 | add `+0.05000305` = 3277/65536 |
| **升级** | `levels` 0→1、`understanding` 525108 > 阈值 524288 | L2 add `+0.08000183` = 5243/65536，cut `−0.10000610` = −6554/65536 |
| **copier** | 源单独 = A、源+复制器 = **2×A**、**无左槽 = 0**、**源不可复制 = 仅 A** | 0.0500030518 → 0.1000061035 |
| **学派** | 动员卡 1.00→**1.25**、商贸卡 1.00→**1.50**，互不影响 | 81920 / 98304（Q16）|
| **协同** | 达标组合 `drought=0.95 / plain=1.03`、**缺一张则两值都精确 1.00** | 由 modifier 定义**算出**，不是字面量 |
| **精神晋升** | 三道门依次为 `ideology_promotion_requires_equipped` → `ideology_national_spirit_level_insufficient` → `national_spirit_slot_capacity_exceeded`；成功后 location 1→2、ideology 槽 2→1、spirit 槽 0→1 | 与目录里的 `*_slot_costs` 精确相等 |

**每个数值都是从目录/定义算出来的期望值**，不是「跑出来多少就断言多少」。

## 2. 【真实缺陷】协同一旦激活就**永远无法撤销**

### 现象

`active_synergy_ids` 正确地丢掉了该 bond，但 **Modifier 行仍然活着**，两个因子永远停在 `0.95000 / 1.03000`。

卸下只产生**一次**国家级移除事件（卡片自己那一行），所以 bond 的 REMOVE **没匹配到任何东西**，`ModifierRuntime` 回 `already_removed`——**没有任何错误被报出来**。

### 机制（我已核实这两行）

```cpp
// ideology_runtime.cpp
:1468  command.fire_sequence = static_cast<uint64_t>(day) ^ (next ? 0ULL : (1ULL << 63U));
:1472  command.opcode = next ? templ.opcode : 2;      // 2 = REMOVE
```

- APPLY：`fire_sequence = day`
- REMOVE：`fire_sequence = day ^ (1<<63)` —— **位 63 被翻转**
- 而 Modifier 行的 `source_id` 是从 `fire_sequence` 派生的（`effect_runtime.cpp:3561-3566`）

**所以 REMOVE 的 `source_id` 永远不可能等于 APPLY 的**，而 `ModifierRuntime` 用
`(definition, scope, scope_id, source_type, source_id)` 作为唯一键（`modifier_runtime.cpp:1201-1202`），
匹配不上就回 `already_removed`（`:1207-1209`）。

### 后果

**协同效果在撤销后永久泄漏。** 卡片行不受影响——它们的身份是卡片（受管 Effect 实例），不是转移。

**这是 §18.1「协同…结果正确」的直接反例。** 我没有把它写成断言（那等于把泄漏固化成期望），
而是作为 `[FINDING]` 打印，夹具在规则侧保持绿。

## 3. 【真实缺口】学派强度因子在**派生路径上是空操作**

`school_strength_scale_q16` 只有两处调用：

| 行 | 用途 |
|---|---|
| `:2549` | **应用**（乘进 `activation_scale_q16`）—— 在**旧实例分支内** |
| `:3306` | **哈希**，不参与计算 |

**派生分支（`:2364-2516`）从不调用它。**

而 265 个 program 里绝大多数是派生卡，所以：

> **学派强度因子对出厂大多数卡片完全不生效。**

这份证据之所以能观测到学派机制，是因为夹具特意选了 `target_domain = 3` 的**实例路径卡**
（`cell_program_eligibility.h:114` 的第一个出口）——那是唯一能看见 `magnitude_scale_q16` 的地方。

另外：**出厂没有任何卡片写学派强度 stat**（`data/` 里只有 harmony 一个定义、2.0 MULTIPLY，
没有 program 引用它，其余五个学派 stat 连定义都没有）。夹具是用 `submit_modifier_commands`
注入两个测试定义来驱动的。

## 4. 【真实不一致】`explain_ideologies` 与命令用的容量不是同一个

| 用途 | 读的字段 |
|---|---|
| `promote_allowed`（预览）| `_spirit_capacity`（`:6004`）|
| `promote()`（命令）| `spirit_capacity_for(slot)`（`:4606-4608`）|
| `equip_allowed`（预览）| `_ideology_capacity`（`:5993-5994`）|
| `equip()`（命令）| `ideology_capacity_for(...)`（`:4561-4562`）|

**在拥有容量解锁科技的世界里，预览与命令会给出相反答案。**

我逐行核实过这两处（**差了两个东西，不只是容量**）：

```cpp
// promote()  :4606-4608  —— 命令侧
if (spirit_slot_cost(country) + definition.spirit_cost >
        spirit_capacity_for(country_slot))          // 按槽位算、含解锁科技
    error = "national_spirit_slot_capacity_exceeded";

// explain_ideologies  :6003-6004  —— 预览侧
if (country->spirit_slots_used + definition.spirit_cost <= _spirit_capacity)
    promote_allowed.append(1);                      // 基础容量
```

| | 成本取值 | 容量取值 |
|---|---|---|
| 命令 | `spirit_slot_cost(country)` | `spirit_capacity_for(slot)`（含解锁）|
| 预览 | `country->spirit_slots_used` | `_spirit_capacity`（基础）|

**所以不只是「容量取错」，成本也取成了另一个访问器。** 两者在无解锁科技的世界里恰好相等，所以平时看不出来。

夹具的容量阶段刻意跑在**没有解锁科技**的世界里（两者一致），所以它没有把任何一种行为固化成期望。

## 5. 顺带：一个既有夹具已经失效

`tests/ideology/ideology_school_strength_worker_test.gd` **装备的两张卡在当前目录里不存在**
（`idea.mandate_of_heaven`、`idea.shell_midden`——两个 `.tres` 里都零匹配），
`_dense_id()` 返回 −1，它在第一条 `_require` 就失败。

**它还在库里，但已经不能通过。** 我没有修它（不在本轮范围），但记在这里。

## 6. 这条证据改变了 §18.1 的判定

「copier、学派、协同、装卸、升级与精神晋升结果正确」从**无证据**改为**部分**：

| 子项 | 状态 |
|---|---|
| 装卸 | ✅ 正确（含两道守卫、容量释放）|
| 升级 | ✅ 正确（幅度精确换到 L2）|
| copier | ✅ 正确（含「无左槽」与「不可复制」两个负向）|
| 学派 | ⚠️ 机制存在，但**在派生路径上不生效** |
| 协同 | ❌ **撤销泄漏**（真实缺陷）|
| 精神晋升 | ✅ 正确（三道门 + 槽位账目）|

**「结果正确」这个要求，协同这一项目前不成立。**

## 6.1 协同泄漏的修法分析（我做了，但**没有采用**）

### 关键新信息：`command.source_id` 是死字段

| 事实 | 证据 |
|---|---|
| ideology 给它写了两处 | `:1463`（协同：`(0x7fff<<48) \| ((synergy_id+1)<<16) \| (effect+1)`，**稳定**）、`:1717`（卡片层级：`tier_source_id`）|
| `effect_runtime.cpp` 里**从不读它** | 只有 `:2139` 一处写、`:3540` 写 `external_source_id`；`:5663` 用的是 `source_instance->id` |

```cpp
:5663  native.source_id = static_cast<uint64_t>(source_instance->id);   // 含 fire_sequence
```

而 `source_instance->id = make_hash(source_type, transition_source_id, first.effect_id, first.fire_sequence)`（`:3561-3566`）——**含 `fire_sequence`，所以 APPLY 与 REMOVE 必然不同**。

### 候选修法 A：让 `:5663` 优先用命令自带的稳定值

```cpp
native.source_id = command->source_id != 0
    ? static_cast<uint64_t>(command->source_id)
    : static_cast<uint64_t>(source_instance->id);
```

**能修好协同**（APPLY/REMOVE 的 `source_id` 都变成稳定的 `(synergy_id, effect)`）。

**但影响面**：

| 行类型 | 现在的身份 | 改后 |
|---|---|---|
| 协同 | 按转移（含 fire） | 按 `(synergy, effect)` —— **这是修的目标** |
| 卡片层级行 | 按转移 | 按 `(ideology_id, level)` —— **更像"行属于卡片的层级"**，可能是好事 |
| **on-enter 一次性** | 按转移 | **按 `(ideology_id, level)`** —— 两次 on-enter 会共享 `source_id`，**第二次可能被当成"行已存在"而不新增** |

**最后一行是我不敢改的原因**：它会把「两次入场各触发一次」变成「只有一次」，而一次性效果的语义正是本次 §18.1 要验证的东西之一。

### 候选修法 B：给协同另开一条不经过 Effect 实例的路径

改动更大（要绕过 `submit_external_effect_commands`），但不动卡片与一次性的身份。

### 我的决定

**不修。** 理由：这是 Modifier 行身份的契约变更，波及卡片行与一次性行，而
`effect_stable_cap`/存档/哈希都可能受影响。我有一个 21 夹具的基线可以验证，但**改错会让基线全绿而语义已变**——这比留一个已记录的缺陷更危险。

**已把它记为待单独立项的缺陷，并在此写清两个候选修法与各自的 blast radius。**

## 7. 交付物

| 文件 | 检查数 |
|---|---:|
| `tests/ideology/ideology_mechanism_equip_level_test.gd` | 133 / 0 |
| `tests/ideology/ideology_mechanism_copier_school_test.gd` | 77 / 0 |
| `tests/ideology/ideology_mechanism_synergy_spirit_test.gd` | 144 / 0 |
| `tools/ideology/verify_delivery.py` | 三个夹具的检查数已钉进期望表 |

## 8. 未覆盖

- **容量超限拒绝**（`ideology_slot_capacity_exceeded`）：需要第二张卡自己的 ADOPT 门也通过，
  而**出厂 113 张卡全部带阶层立场**。
- **copier 在 level ≥ 2**（`copy_scale_q16 = 1.2×`）：那个缩放只在实例路径，而复制器自己没有受管 program。
- **`program_writes_school_strength` 返回真**的分支：没有 program 写学派 stat，无法从内容进入。
- **worker 冻结快照路径**（`native_simulation_host.cpp:9823-9853`）：需要运行中的 worker。
