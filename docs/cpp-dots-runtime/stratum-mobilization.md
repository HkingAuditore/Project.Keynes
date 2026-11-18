# 阶层组织度（Stratum Mobilization）运行时

- 状态：**Phase 0 + M1 原生核心 + M2 玩家链 + 独立/宣战/驻军转移 + AI 原生自动决议 + 地图/顶栏告警 + 黄金基线已落地**。
- 设计来源：[阶层组织度与叛乱事件链：评估与设计提案](../plans/stratum-organization-rebellion-assessment.md)
- 关联：[综合满意度运行时](satisfaction-runtime.md)、[显赫家族运行时](notable-family-runtime.md)、[军事运行时](military-runtime.md)

本页只写**已经存在**的代码契约。未实现部分标为"目标"。

## 1. 为什么放在 Economy

组织度的输入是 per-(地块 × 职业) 的满意度、人口份额和本地家族影响力，这些全部由 Economy 拥有；独立建国/宣战则属于 Country/Military。把组织度放在 Economy 可以：

- 复用结算循环里的 cohort 扫描，不新增全图遍历；
- 让组织度与满意度、社会压力事实在同一个提交边界发布；
- 避免新增第十三个日域（`RuntimeDomainId` 会改 ABI）。

`Country` 只新增了首都字段（PKCN v16），供"首都不可独立"规则使用；组织度本身不写入 Country。

## 2. 数据模型

`gdext/src/runtime_economy_stratum_mobilization.h`

```cpp
struct StratumMobilizationRow {
    int32_t cell;
    uint16_t profession;
    int32_t owner_slot;              // 上次归属；变化即整行重置
    uint16_t mobilization_q16;       // 组织度 0..65535
    uint16_t satisfaction_ema_q16;   // 输入 EMA
    uint16_t share_q16;              // 本职业人口份额
    uint16_t local_sat_q16;          // 排除本职业的影响力加权满意度
    uint8_t stage;                   // 0 无链 / 1 不满 / 2 抗议 / 3 示威 / 4 叛乱
    uint8_t flags;                   // bit0 玩家国 / bit1 首都
    int32_t next_check_day;
    int32_t cooldown_until_day;
    int32_t last_event_day;
    uint16_t trauma_q16;
};
```

- 行按 `(cell, profession)` 排序，`cell_offsets` 是派生的 CSR；插入/删除时整体重建（行很少）。
- **只有"有不满或曾在链中"的 (cell, profession) 才有行**。和平年代行数为 0；这是性能契约。
- 归属变化：`owner_slot` 不一致 → 清空组织度/阶段、给 90 天冷却。
- 休眠清理：`stage == 0 && mobilization ≤ 1% && satisfaction_ema ≥ θ_low` → 删行。

## 3. 更新位置

`NativeEconomyRuntime::publish_country_development_facts()` 已经在每个 econ epoch 扫描 `_market_cells × for_each_in_cell`（class-opinion / 发展指标共用）。组织度复用这次扫描：

1. 在 cohort lambda 里按 `profession` 累加 `people` 与 `people × composite` 到 `thread_local` 小数组；
2. 该格扫描结束后调用 `advance_cell_mobilization(cell, country, cell_population, cell_satisfaction, ...)`；
3. `dt = cell_elapsed_days(cell)`（1–5 天，既有函数）。

因此**没有新增全图循环**；per cohort 只多两次加法，行更新只发生在危机格。

## 4. 公式（当前实现）

```text
s_ema  += (s − s_ema) × min(1, dt/12)
grievance = clamp((0.50 − s_ema)/0.50, 0, 1)
capacity  = floor(p) + (1−floor(p)) × grievance × (0.6 + 0.4×min(1, share/0.25))
mob      += (capacity − mob) × dt / (capacity≥mob ? 60 : 35)
capacity += trauma/2（钳 0..1）
```

职业 `floor` 与政治权重由 stable id 在首次使用时编译：

| 职业 | floor | 权重 |
|---|---:|---:|
| soldier | 0.20 | 1.30 |
| merchant / industrialist / landlord | 0.12 | 1.20 |
| artisan / apprentice / journeyman / dyer / guild_master | 0.08 | 1.00 |
| miner / industrial_worker / construction_worker / metallurgist / machinist / technician / electrician / transport_worker / petroleum_worker / chemist | 0.10 | 1.00 |
| scholar / scribe / lorekeeper / natural_philosopher / scientist / researcher / engineer / data_scientist / ai_researcher / agronomist | 0.06 | 1.00 |
| serf / unemployed / enslaved_laborer / indentured_laborer / corvee_worker | 0.02 | 0.70（农奴类） |
| 农业类（farmer / tenant / sharecropper / fisher / hunter / forager …） | 0.03 | 1.00 |
| 其它 | 0.05 | 1.00 |

触发与升阶：

```text
power = mob × (0.55 + 0.45×min(1, share/0.25)) + 0.20 × (1 − local_sat)
stage_gate = [0, 0.30, 0.45, 0.62, 0.78]
tier_gate  = [0, 0.25, 0.45, 0.62, 0.80]

stage 0 → 1：mob ≥ 0.30 且冷却结束，按 epoch 掷骰
  p = 0.10 × (mob−gate)/(1−gate) × influence × weight × (0.6+0.4×(1−local_sat)) × dt
  上限 5%
stage k → k+1：到达 next_check_day 时掷 0.35，且需同时满足
  mob ≥ stage_gate[k+1] 且 power ≥ tier_gate[k+1]
  否则停在当前阶，next_check 再延 10 天
```

- 掷骰是无状态哈希：`hash64(day, cell, profession, stage, salt)`；不保存 RNG 状态。
- **首都免疫**：`cell == _epoch_country_capital_cells[country]` 且该格仍属该国 → `stage` 封顶 3，`flags` 置首都位，不发第 4 阶事实。
- 当前 `stage 4` 只产生事实，不会自动建国；独立由 M3 的服务处理。

## 5. 事实

`GAMEPLAY_FACT_STRATUM_MOBILIZATION = 10` → `PK_EVENT_STRATUM_MOBILIZATION = 18` / `PK_PAYLOAD_STRATUM_MOBILIZATION_V1 = 26`：

```text
cell = 格
i0 = stage, i1 = previous_stage, i2 = profession, i3 = country_slot
value = mobilization_q16, entity_id = 该职业人口
flags = bit0 玩家国 / bit1 首都
```

只在 stage 变化时发。GDScript 常量见 `gameplay_event_bus.gd` 的 `EVENT_STRATUM_MOBILIZATION` / `PAYLOAD_STRATUM_MOBILIZATION_V1`。

## 6. 查询与绑定

- `DCWorldExt.get_cell_mobilization_snapshot(cell_idx)` → `{ok, cell_index, rows[], row_count}`
  - 每行：`profession / mobilization_q16 / satisfaction_ema_q16 / share_q16 / local_sat_q16 / stage / flags / cooldown_until_day / next_check_day / trauma_q16`
- `DCWorldExt.get_country_mobilization_summary(country_slot)` → `{ok, country_slot, row_count, stage_counts[5], top_cells[≤8]}`
- GDScript 包装：`EconomyFacade.cell_mobilization_snapshot()` / `country_mobilization_summary()`。

## 7. 军事输入

- 新增 dense 通道 `_cell_garrison_heads` / `_cell_garrison_present`，由 `world_ext_military.cpp` 在每日 `publish_military_ration_satisfaction()` 里随 ration 一起 sparse 推送（只推有驻军 lot 的格）。
- `set_military_cell_garrison(cells, heads)` 是 Economy 的公开 seam（`economy_api.h`），不暴露运行时布局。
- 组织度阶段判定当前**不读**驻军；驻军只用于 M2 的镇压成功率公式。
- 新增军事命令 `MCMD_WAR_DECLARE_FORCED = 43`：payload 同 `war.declare`，但跳过"攻方必须有兵"检查；独立后的原主权国用它"朝廷讨伐"。
- 新增 `MCMD_GARRISON_TRANSFER_CELL = 44`：`cell` + `other`（新主权国句柄）；清 controller、把该格全部驻军 lot 转给新国。GDScript 入口 `MilitaryFacade.transfer_cell_garrison(country, cell, new_owner)`。

## 8. 存档

- PKEC `SCHEMA_VERSION` 61 → **62**；新增 `SAVE_SECTION_STRATUM_MOBILIZATION = 37`，稀疏行按 `(cell, profession)` 顺序写出，支持跨 chunk。
- 读取校验：cell/profession 范围、owner ≥ -1、stage ≤ 4、Q16 范围、last_event_day ≥ -1；越界拒绝整档。
- 行进入 `state_hash`（逐字段混合，不依赖 struct padding）。
- PKCN 15 → **16**：每国多一个 `capital_cell`（i32）。bootstrap 包新增可选 `capital_cells`；缺省回退到该国第一个领地块；`CREATE_COUNTRY` 把首都设为新格。旧 PKCN（v11–v15）仍可读，缺失首都按 -1 处理。
- 契约：`tools/ci/cpp_save_section_contracts.json` 的 PKCN=16、ECP2=62。

## 9. 已验证

- `tests/country/country_capital_test.gd`：16 checks / 0 failures（bootstrap、缺省回退、非法首都、CREATE_COUNTRY、PKCN 往返、state hash）。
- `tests/economy/satisfaction_runtime_test.gd`：58 checks / 0 failures，新增 9 项组织度覆盖（空表、饥饿格长行、组织度累积、概率查询、成功让步降组织度、PKEC v62 往返、state hash、行一致）。
- `tests/military/military_native_binding_test.gd`：核心自测 PASS，新增 `cession transfer (from=-1)`、显式来源转移与 `war.declare_forced` 三项。
- `tests/game/narrative_event_runtime_test.gd`：71 checks / 0 failures（采样器改读 `cell_satisfaction_attractiveness` 后）。
- `tests/politics/stratum_unrest_service_test.gd`：7 checks / 0 failures（让步付款、弃城→建国→宣战、队列清空）。
- `check_module_api.py`、`check_save_contracts.py`、`check_module_contracts.py`、`check_committed_views.py`、`check_resolve_apply.py` 通过。
- `check_cpp_deps.py` 的失败项来自工作区已有的 `ideology_support_incidence.*`，不是本功能；`check_size_ratchet.py` 的失败项来自既有超限 UI 文件。

## 10. M2 玩家链（已落地）

- `get_mobilization_odds(cell, profession, action, spend_bp)`：native 单一公式，返回 `p_success_q16`、`cost_bp` 与逐项加数（local_sat / garrison / family / cost / org / share）。`action` 0 让步、1 收买、2 镇压、3 无视、4 招安、5 弃城。
- `apply_mobilization_result(cell, profession, action, success)`：在叙事弹窗持锁暂停时钟时同步调用；只改稀疏行，不碰守恒账本。成功按阶降低组织度并进冷却；失败升阶并可能置 `flags & 8`（独立待处理）。
- `scripts/politics/stratum_unrest_service.gd`：轮询事实 → 玩家国投递四阶事件 → 玩家选择后按 `chain_salt` 掷骰、付让步成本、调 native 应用结果；`flags & 8` 进入独立队列（D+1 `create_country`，D+2 原主权国 `declare_war_forced` + `transfer_cell_garrison`）。AI 阶段在 native epoch 更新里自动决议（有驻军则镇压、否则无视，50% 确定性掷骰），服务只处理玩家事实与独立位。
- **AI 原生自动决议**：`advance_cell_mobilization` 在 AI 行跨阶时直接调用 `apply_mobilization_result`；失败到第 4 阶置 `flags & 8`，由服务建国/宣战。没有弹窗，也不依赖时钟暂停。
- `scripts/politics/stratum_rebellion_content.gd`：四阶 × 3–4 选项的中文内容，选项概率由服务在投递时注入。
- 地块档案新增「民情」页签：按职业显示组织度条、阶段、最高阶段与其余阶层满意度（走 `metrics/gauges/insights` 通用渲染）。
- 地图告警：`cell_situation_snapshot` 追加 `mobilization_stage` / `mobilization_q16` 两列（不改变原 severity stride）；`cell_situation_layer` 增加第 9 个「阶层组织度」图标，鼠标悬停显示阶段与说明。
- 顶栏：`PlayerTopBar.set_unrest_status(count)` 程序化生成「离心 N」纸签（不改编排场景），`GameUIManager` 用 `country_mobilization_summary` 的 stage 3+4 计数刷新；为 0 时隐藏。
- 玩家控制器在叙事运行时绑定时配置服务，并在每日提交后推进，先消费动员事实再处理普通叙事。动员事实使用独立游标和事件类型过滤。
- 服务存档并入 `pknr.stratum_unrest`，与叙事队列一同恢复（事实游标、独立队列、升阶复核待办和旧 AI 待办）。缺少服务状态的旧存档在提交后从玩家领地的动员快照恢复当前未处于冷却的阶段。玩家选择失败时，下一次提交后复核受影响的职业行，以接续可能在经济周期切换时丢失的升阶事实。

测试：`tests/politics_parse_probe.gd`（PASS）、`tests/politics/stratum_unrest_service_test.gd`（7/0，覆盖让步付款、弃城→建国→宣战、队列清空）。

## 11. 黄金基线

- 2026-11-13 按 5 次 `PK_GOLDEN_CAPTURE=1` 捕获更新 v4 `golden_day_hash_baseline.json`，并由同一结果派生 v2/v3；`golden_day_hash_test.gd` 176 checks / 0 failures。
- 外部推进器 `golden_external_advancers_baseline.v5.json` 同样按 5 次捕获更新；`golden_external_advancers_test.gd` 338 checks / 0 failures。
- `tools/ci/check_golden_determinism.py` 现在显式设置 `PK_GOLDEN_DOMAINS=1`：Godot 的 `OS.set_environment` 在 Windows 上不会传到 GDExtension 的 CRT 环境，否则逐域摘要是空的。
- 长跑平衡仍建议在 Ideology 工作流收口后另跑；本轮只保证逐日确定性基线一致。

