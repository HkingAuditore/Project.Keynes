# 叙事事件 × 家族机制：桥接设计

> 结论先行：**当前没有深度联动。** 家族运行时（FamilyStore / 影响力 / 特质 / 名人 / 产业）是完整的，叙事系统这一侧缺三样东西：**不读家族快照、没有家族条件、没有家族效果**。本文只定义桥的契约与实施顺序，不改任何运行时代码。

- 相关资产：`scripts/narrative/`、`scripts/economy/economy_facade.gd`、`scripts/family/`、`docs/design/narrative-event-web.md`
- 现有家族内容：`narrative_event_catalog_family.gd`（4 条，题材层）
- 家族运行时手册：`project-keynes-family-runtime` skill

---

## 0. 实施状态（2026-11-12）

| 阶段 | 状态 | 证据 |
| --- | --- | --- |
| Phase 0 · 特质语义 | 已确认 | 读原生 `apply_due_family_trait_commands()`：`grant` 对已存在的**非 core** 特质是**改强度**（同强度 no-op），对 core 特质跳过；`remove` 只删非 core；`set_strength` 对已存在特质生效；前置/排斥在 grant 时强制。**重复授予不会叠加**，内容不需要 remove+grant。 |
| Phase 1 · 读家族 | 已实现 | `narrative_context_sampler.gd::_sample_primary_family`，取 `family_cell_snapshot(cell, 0, 8)` 第一条（原生已按人口降序）；只在 `include_cohort_details=true` 的扫描/结算路径调用；算子 40–43，第二批补 `HAS_FAMILY_TRAIT = 44` 与 `get_family_traits` 一次读取。 |
| Phase 2 · 写特质 | 已实现 | `Kind.GRANT_FAMILY_TRAIT = 14` / `REMOVE_FAMILY_TRAIT = 15`；适配器调 `queue_family_trait_mutation`，强度夹在 49152–81920；无族/无 key/未配置 → simulated。 |
| Phase 3 · 内容 | 已实现 | `family2` 10 条 + `family3` 12 条，共 22 条，已注册；`{family_name}` 在正文/标签/结果都可用；B 层 6 条按既有特质分岔。 |
| Phase 4 · 验证 | 部分 | `narrative_family_bridge_test.gd` 28 项 0 失败；`narrative_event_web_test.gd` 14111 项 0 失败；四个既有叙事测试全绿。**未跑** `tests/family/family_runtime_test.gd`：工作区里 `game_save_coordinator.gd` 的编译错误导致该脚本无法加载，该错误在本次改动前就存在，与家族桥无关；原生 trait 命令路径未改动。 |

---

## 1. 现状审计（代码证据）

| 层 | 位置 | 现状 |
| --- | --- | --- |
| 效果 | `narrative_effect_spec.gd` `Kind` | 13 种，**无家族类** |
| 条件 | `narrative_condition.gd` `Op` | 0–39，**无家族算子** |
| 采样 | `narrative_context_sampler.gd` | 读气候/地理/cohort/市场/国家；**从不调用 `family_cell_snapshot`** |
| 内容 | `narrative_event_catalog_family.gd` | 4 条“写家族”的事件，效果是通用城修正/现金/权重 |
| 旧键 | `family.city.*` | MULTIPLY 1.02–1.05 的旧族，实测被弱化 2–8 倍；`family.city.trade_output_boost` 零读取点。**不能作为桥** |

家族运行时已具备的读接口（`EconomyFacade`）：

- `family_cell_snapshot(cell, offset, limit)`：按家族人口降序、`stable_id` 升序排列；字段见 §2。
- `family_snapshot(handle)`：族名（`family_name`）、姓氏、起源地、职业构成。
- `get_family_traits(handle)`、`family_industries(handle)`、`family_notable_people(handle)`。
- `queue_family_trait_mutation(handle, op, trait_key, strength_q16, effective_day, priority, sequence)`：`grant` / `remove` / `set_strength`，异步命令，返回 order。
- 另有立族报价、家族殖民等，本文不动。

---

## 2. 家族快照契约（已核实）

`family_cell_snapshot` 返回的并行数组（长度一致，按人口降序）：

| 字段 | 类型 | 语义 |
| --- | --- | --- |
| `ok` | bool | 运行时可用且 cell 合法 |
| `cell_idx` | int | 请求的格 |
| `family_handles` | PackedInt64Array | 句柄（稳定，跨日不变，除非家族消亡） |
| `stable_ids` | PackedInt64Array | 稳定 id（排序 tie-break） |
| `surnames` | PackedStringArray | 姓 |
| `surname_disambiguators` | PackedInt32Array | 同姓消歧序号 |
| `family_names` | PackedStringArray | 已合成的族名（优先用它） |
| `populations` | PackedInt64Array | 本格家族人口 |
| `cash_claims` | PackedInt64Array | 家族现金 |
| `owned_buildings` | PackedInt64Array | 家族在本格拥有的建筑数 |
| `notable_person_counts` | PackedInt32Array | 名人数量 |
| `prestige_levels` | PackedInt32Array | **本格**影响力档位（不是全局威望） |
| `prestige_scores` | PackedInt32Array | 本格影响力分数 Q16 |
| `home_cells` / `origin_cells` | PackedInt32Array | 本籍 / 起源格 |
| `origin_ethnicities` / `culture_groups` | PackedInt32Array | 族群与文化组 |

**两个必须写进契约的事实：**

1. **“最大族”是定义好的**：快照已按 `population desc, stable_id asc` 排序，所以 `family_handles[0]` 就是本格最大族。不要自己再写一套排序。
2. **威望是“每族 × 每格”的**：`prestige_levels[i]` 来自 `family_influences` 里 `(family, cell)` 的分支，不是全国声望。事件文案不能写“这个家族天下闻名”，只能写“在这一带说话有分量”。

---

## 3. 选族规则（确定性）

```
primary_family(cell):
  snap = economy_facade.family_cell_snapshot(cell, 0, 1)
  if not snap.ok or snap.family_handles.is_empty(): return NONE
  return FamilyRef(
      handle   = snap.family_handles[0],
      name     = snap.family_names[0] if可用 else 由 surname+disambiguator 合成,
      prestige = snap.prestige_levels[0],
      pop      = snap.populations[0],
      share    = snap.populations[0] / max(1, cell_population),
      owned    = snap.owned_buildings[0],
      notables = snap.notable_person_counts[0])
```

- `limit=1` 只取最大族，成本最低；需要“前 N 族名”时再取 `limit=8`。
- 兜底：`family_runtime_unavailable` / `economy_not_bootstrapped` / 空数组 → `NONE`，条件一律 false，效果转 simulated。
- **结算时重新采样**：`choose_option` 走 `sample_cell_context(..., include_cohort_details=true)`，家族也要在这条路径里取；否则玩家看到的族与授 trait 的族可能不是同一个。

---

## 4. 上下文扩展（采样器新增字段）

| 字段 | 类型 | 默认 | 用途 |
| --- | --- | --- | --- |
| `family_available` | bool | false | 条件总开关 |
| `family_count` | int | 0 | 本格家族数（`limit=8` 时的数组长度） |
| `primary_family_handle` | int | 0 | 效果目标 |
| `primary_family_name` | String | "" | `{family_name}` |
| `primary_family_prestige` | int | 0 | 条件 |
| `primary_family_prestige_score_q16` | int | 0 | 排序/文案备用 |
| `primary_family_population` | int | 0 | 条件 |
| `primary_family_population_share` | float | 0.0 | 条件（人口占比） |
| `primary_family_owned_buildings` | int | 0 | 条件 |
| `primary_family_notable_people` | int | 0 | 条件 |
| `family_names_top` | PackedStringArray | 空 | 文案里点第二个族 |

成本：每格一次 `committed_read`。脉冲扫描每 20 日只抽 1–8 格，可接受；`choose_option` 每事件一次；**不要**在 `enqueue_event_offer` 的汇总路径加这次读取（沿用 cohort 的“入队不取明细”契约）。

---

## 5. 条件算子（新增 4 个，追加到 43）

| op | 名称 | 参数 | 语义 | 无家族时 |
| --- | --- | --- | --- | --- |
| 40 | `HAS_NOTABLE_FAMILY` | `bool_value` | 本格有家族，且（名人数 ≥1 或 威望档 ≥1） | false |
| 41 | `FAMILY_PRESTIGE_GTE` | `int_value` | 最大族在本格的威望档 ≥ N | false |
| 42 | `FAMILY_POP_SHARE_GTE` | `float_value` 0–1 | 最大族人口 / 本格人口 ≥ N | false |
| 43 | `FAMILY_OWNS_BUILDINGS_GTE` | `int_value` | 最大族在本格拥有的建筑数 ≥ N | false |

- 全部走 `ctx` 字段，和现有 40 个算子同构；`negated` 照常生效。
- 不做“第 N 大族”条件（需要额外协议）；需要时用 `family_names_top` 只做文案，不做门槛。

---

## 6. 效果（新增 2 个 Kind，追加到 15）

| Kind | 名称 | 字段用法 | 语义 |
| --- | --- | --- | --- |
| 14 | `GRANT_FAMILY_TRAIT` | `target_key` = trait key；`magnitude_q16` = 强度；`duration_days` 忽略（特质是持久的） | 给**本格最大族**授予特质 |
| 15 | `REMOVE_FAMILY_TRAIT` | `target_key` = trait key | 从最大族移除特质 |

适配器行为（新增分支，和 `DISCOVER_RESEARCH_SIGNAL` 同一套“不可用则 simulated”模式）：

```gdscript
Kind.GRANT_FAMILY_TRAIT / REMOVE_FAMILY_TRAIT:
    if economy_facade == null or not configured: simulated
    handle = int(ctx.get("primary_family_handle", 0))
    if handle <= 0: simulated
    if trait key 不在编译后的 trait 目录: simulated
    economy_facade.queue_family_trait_mutation(
        handle,
        "grant" / "remove",
        trait_key,
        clampi(magnitude_q16, 49152, 81920),
        effective_day,
        100,
        _alloc_seq(sequence_alloc))
```

**为什么不做“加威望/加家族现金”**：`EconomyFacade` 没有公开的威望或家族现金写命令；`family.city.*` 修正族已经证明是弱化/空转的坑。用特质是唯一“真实、持久、能在家族档案里看见”的写入面。

**特质来源（已核实）**：`FamilyTraitCatalog.load_default()` 会调用 `FamilyOfficialCatalog.hydrate_trait_catalog`，把 `data/economy/family_official_buffs.json` 里的 **98 条 trait / 48 条 effect** 灌进目录；`default_family_traits.tres` 本身是空壳。所以 key 是真实可用的，例如 `i005_knowledge`（学术赞助）、`j009_letters`（书香门第）、`j020_gentry`（士绅门第）、`i029_coastal`（沿海资本）。Phase 0 只需从这 98 条里挑 6–8 条语义合适的，并验证重复授予同一 trait 的行为。

---

## 7. 占位符

- `{family_name}`：正文、标题、结果、`custom_label` 都可用；由 `format_text` / `format_label` 填；无家族时回退“本地大族”。
- 不新增 `{family_prestige}` 之类数值占位符——正文不写读数，档位只进 `custom_label`（例如“本地最大族获特质「…」，永久”）。
- 标签建议：`"本地最大族「{family_name}」获特质「…」，永久"`；`remove` 同理。

---

## 8. 存档、兼容与失败模式

| 项 | 处理 |
| --- | --- |
| 旧存档 | `Kind` / `Op` 都是**追加**，旧值语义不变；`pknr` 里的 effect kind 仍是原整数 |
| 家族命令 | 走 `queue_family_trait_mutation` 的命令队列，由 PKEC 保存；叙事侧不重复持久化 |
| 家族在“看到事件”与“结算”之间消亡 | 结算路径重新采样 handle；`handle<=0` → simulated，不报错 |
| 特质目录为空 / key 漂移 | 适配器查编译目录，找不到即 simulated；契约测试对内容里用到的 key 做存在性断言 |
| 事件刷在没家族的格子 | 条件 `HAS_NOTABLE_FAMILY` 兜住；效果仍写 simulated 兜底 |
| 性能 | 每格一次 `family_cell_snapshot(limit=1)`；只在脉冲/事实/探针/结算路径取，不在入队路径取 |

---

## 9. 测试计划

1. **契约**（扩展 `narrative_event_web_test.gd`）：
   - 新 op 编号唯一、`from_dict/to_dict` 往返；
   - 新 Kind 的标签非空、不含内部 id；
   - 内容里出现的 trait key 在编译目录里存在（否则 fail）。
2. **行为**（新 `narrative_family_bridge_test.gd`，stub `EconomyFacade`）：
   - 快照排序 → `primary_family_handle` 取第一个；
   - 四个条件在“有族/无族/低威望/高威望”下的真假；
   - `GRANT_FAMILY_TRAIT` 调用参数（handle、op、key、strength、effective_day）；
   - 无族时 simulated、不调用 facade；
   - `choose_option` 结算路径重新采样 handle（改了快照后授 trait 给新族）。
3. **回归**：`narrative_event_runtime_test`、`family_baseline_test`、`save_repository_test`。
4. **性能**：50 日 headless，比较加桥前后脉冲扫描耗时（目标是采样成本 < 单日预算的 1%）。

---

## 10. 内容蓝图（10 条，`family2` 包）

前置：Phase 0 从 98 条 trait 里选定下表 key（已填真实 key），并验证重复授予语义。

| id | 标题 | 时代 | 门槛 | 效果（摘要） | 代价 |
| --- | --- | --- | --- | --- | --- |
| family2.school | 族学 | 2–7 | 威望≥2、拥建筑≥1 | 授 `i005_knowledge`（学术赞助）；知识 +4%/540 | 现金出库 1.5% |
| family2.granary | 族仓 | 2–8 | 人口占比≥0.25 | 授 `i001_agrarian`（重农）；主食 −4%/360 | 农业 −3%/360 |
| family2.feud | 争产 | 1–8 | 家族数≥2 | 授 `j016_shrewd`（精明）；动荡×1.25 | 制造 −3%/360 |
| family2.loan | 借粮 | 2–8 | 威望≥3 | 授 `i028_counter`（逆周期经营）；向本地人数最多的人群征收 1.5% | 动荡×1.2 |
| family2.office | 求官 | 3–8 | 威望≥3 | 授 `j020_gentry`（士绅门第）；建设成本 −3% | 向该族现金 1% |
| family2.migration | 迁族 | 2–9 | 人口占比≥0.3、满意度≤0.45 | 授 `i025_pioneer`（拓荒者）；出生 −4% | 农业 +3%（人走了地空出来） |
| family2.guild | 族与行会 | 3–7 | 威望≥2、工匠≥8% | 授 `j004_craft`（工匠世家）；制造 +4% | 工具开销 +5% |
| family2.marriage | 联姻 | 1–8 | 家族数≥2 | 授 `i026_magnate`（家大业大）；出生 +4% | 现金出库 1% |
| family2.relief | 族赈 | 1–8 | 威望≥2、最不满≤0.5 | 授 `j017_loyal`（老实）；主食 −5% | 向本地人数最多的人群征收 1.5% |
| family2.sea | 族船 | 4–7 | 沿海、威望≥3 | 授 `i029_coastal`（沿海资本）；贸易 +5% | 动荡×1.15 |

> 每条只给**一个** trait 变化，其余用现有通用效果；不要在同一选项里既授 trait 又删 trait。
> 文案里用 `{family_name}`，并始终写“在这一带”，不写“天下”。
>
> **诚实约束**：除了 trait，家族没有别的写入面。上表里的“现金”“主食”“贸易”“动荡”仍是通用杠杆——
> 现金转移只作用于「本地人数最多的那一群」，不是这个家族；不要写成“该族出钱/该族得钱”。
> 想要真正的家族现金转移，需要先给 `EconomyFacade` 加家族现金命令，那是另一个工程。

---

## 11. 实施顺序与风险

| 阶段 | 内容 | 风险 |
| --- | --- | --- |
| 0 | 从 98 条 trait 选定 10 个叙事用 key；探针验证「重复授予同一 trait」与强度上下限 | 语义未验证前不要写“授予”类内容 |
| 1 | 采样器 + 4 条件（只读） | 每格多一次 committed read；需测成本 |
| 2 | 2 个 Kind + 适配器 + 契约/行为测试 | 命令异步、家族可能在结算前消亡 |
| 3 | 10 条 family2 事件 + 文档 | 特质语义与文案要对得上；否则玩家看不懂档位 |
| 4 | 回归 + 性能 + 更新 web/coverage 文档 | — |

**非目标**：不改家族内部算法；不直接写威望/家族现金；不动家族 UI；不做殖民事件；不新增 story flag。

**已确认**：重复授予同一 trait 不叠加（已存在则改强度，同强度 no-op；core 特质跳过）。见 §0。
