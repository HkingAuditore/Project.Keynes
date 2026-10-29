# M0-5 frozen-input reconstructability audit — findings

| 项目 | 内容 |
|---|---|
| 里程碑 | [M0](../22-cell-program-cap-removal-plan-v3.md) |
| 任务 | §15.2 M0 task 5 / §11.3 |
| 日期 | 2026-10-26，Asia/Hong_Kong |
| 工具 | `Project/project-keynes/tools/ideology/m0_epoch_field_audit.py` |
| 产物 | `epoch_field_audit.csv`（169 行逐字段）、`epoch_field_audit_report.txt` |
| 结论 | 迁移依赖的 7 个冻结字段全部可再生，**不需要新增 checkpoint 字段**；但方案 §11.3 的工作量估计需要修正 |

## 1. 精确基数

方案 §11.3 与我的评估都用了「123 个 `_epoch_*` 字段」。**实际是 169 个声明**。差异来源：

- 早前用 `Select-String '^\s+std::vector<[^>]+>\s+_epoch_'` 只数了 `std::vector` 单名声明；
- 漏掉了多字段同行声明（`std::vector<int64_t> _epoch_a, _epoch_b;`）；
- 漏掉了 `std::vector<int32_t> _epoch_x, _epoch_y;` 这类成对声明；
- 漏掉了 `EconomyTrackedScalar` 类型（`_epoch_days`、`_epoch_id`）。

169 个逐字段清单见 `epoch_field_audit.csv`。这是本里程碑对 G4 的修正：**方案 §15.2 任务 5 的规模应写 169，不是 123。**

## 2. 分桶结果

| 桶 | 数量 | 含义 |
|---|---|---|
| `PERSISTED_RAW` | 5 | ECP2 有 section 逐值落盘 |
| `DERIVED_FROZEN` | 90 | epoch open 时从已恢复输入重算，恢复后值 == 原值 |
| `DERIVED_PARTIAL` | 56 | 重算，但来源本身不落盘 → §11.3 要求补字段 |
| `DIAGNOSTIC` | 18 | 墙钟计时/计数器，非仿真状态 |
| `UNKNOWN` | **0** | — |
| **仿真合计** | **151** | 169 − 18 |

## 3. 迁移实际依赖的 7 个字段：全部 DERIVED_FROZEN

这是本里程碑最重要的结论。方案 §8.5 要求接入的读者所读的冻结因子，没有一个落在 `DERIVED_PARTIAL`：

| 字段 | 桶 | epoch open 写入点 | 读取方 |
|---|---|---|---|
| `_epoch_cell_birth_factor_q16` | `DERIVED_FROZEN` | `refresh_city_modifier_factors` | birth_factor（30 条命令引用） |
| `_epoch_cell_need_consumption_factor_q16` | `DERIVED_FROZEN` | `refresh_city_modifier_factors` | need consumption（29 条） |
| `_epoch_cell_good_consumption_factor_q16` | `DERIVED_FROZEN` | `refresh_city_modifier_factors` | good consumption（与上同循环） |
| `_epoch_country_output_factor_q16` | `DERIVED_FROZEN` | `capture_country_epoch` | 国家产出项 |
| `_epoch_cell_country` | `DERIVED_FROZEN` | `capture_country_epoch` | 逐格归属国（目标解析） |
| `_epoch_country_cell_offsets` | `DERIVED_FROZEN` | `economy_runtime_family_buff.cpp` | 领土 CSR（OWN_TERRITORY） |
| `_epoch_country_cells` | `DERIVED_FROZEN` | `economy_runtime_family_buff.cpp` | 领土 CSR（OWN_TERRITORY） |

**推论：** 只要 restore 后的 epoch open 能从已恢复的 Country/tag/metric 输入重算出同一份因子，**cell-layer 派生层不需要任何新 checkpoint 字段**。方案 §11.4 步骤 6「用共享 builder 重建派生 front」已经涵盖这一点。

这把 §11.3 从「可能要给 56 个字段补 checkpoint」收敛为「确认这 56 个字段没有一个被 cell-layer 读取」。审计结果显示确实没有。

## 4. DERIVED_PARTIAL 的 56 个字段属于谁

按 `epoch_field_audit.csv` 的 `why` 列，56 个里只有 5 个是我据实现语义标注的已知不可恢复项，其余 51 个落在三条既有经济流水线上，与理念无关：

| 族 | 字段（示例） | 归属 | 与本迁移的关系 |
|---|---|---|---|
| 市场 EMA 与供给快照 | `_epoch_business_demand_ema`、`_epoch_offered_supply_ema`、`_epoch_previous_producer_sellable`、`_epoch_producer_merchant_sold_current` | 市场结算 | **无关** |
| 研究需求/铸币配额 | `_epoch_research_demand_by_cell`、`_epoch_bullion_quota_*` | 政府采购 | **无关** |
| 价格上限观测 | `_epoch_price_ceiling_observations`、`_epoch_ceiling_*` | 价格上限 | **无关** |
| 成本锚 | `_epoch_cost_anchor_price` | 生产计划 | **无关** |

**这是一个必须写进方案 §11 的边界：** 那 56 个字段的「是否补 checkpoint」是一个**既有的、独立的**经济持久化问题，不应被 cell-layer 迁移的 §18.2「冻结源逐字段审计完成」复选框覆盖。否则 M5 会背一个它没引入也没能力关闭的债。

建议在 §11.3 增一句：**cell-layer 迁移的审计义务只覆盖「本层 reader 实际读取的字段」；其余 `_epoch_*` 字段的可重建性属于既有 Economy 持久化范围，另行立项。**

## 5. 落盘现状

`PERSISTED_RAW` 只有 5 个：

| 字段 | 类型 | 落盘位置 |
|---|---|---|
| `_epoch_active` | `bool` | `economy_runtime_persistence.cpp` |
| `_epoch_begin_post_fiscal_pending` | `bool` | 同上 |
| `_epoch_begin_pending_day` | `int64_t` | 同上 |
| `_epoch_cell_development_q16` | `std::vector<int32_t>` | `economy_runtime_persistence_write.cpp` |
| `_epoch_country_count` | `int32_t` | 同上 |

另有 2 个 `EconomyTrackedScalar`（`_epoch_days`、`_epoch_id`）经 metadata 列落盘（`persistence_write.cpp:25,27`），它们是标量而非本表统计的容器成员，单独计入。

**这和我的评估结论一致**：169 个容器/标量成员里，真正进存档的只有 5 + 2 个。

## 6. 提交给 M1 的两条实现约束

1. **派生层的 `materialize_basis` 必须能在 restore 后重建**，不能依赖任何 `DERIVED_PARTIAL` 字段。可以用 `_epoch_country_cells` / `_epoch_cell_country` 与 `_epoch_cell_*_factor_q16`，这些在 restore 的 `capture_country_epoch()`（`persistence.cpp:1334`）之后即可用。
2. **`refresh_city_modifier_factors` 的调用时序**：它在 `capture_country_epoch` 内部（`economy_runtime.cpp:5530`）执行，而 `persistence.cpp` 的 restore 在 `1334` 调 `capture_country_epoch`、`1397` 调 `refresh_building_modifier_factors`。派生层若放在 Modifier 侧，其 front 安装必须在 `1334` 之后、`1397` 之前，否则 `1397` 会读到未含派生项的因子——这正是方案 §11.4 步骤 5「修复恢复期间过早建立的派生查询缓存」要解决的点，现在有了精确行号。

## 7. 复算方式

```powershell
python Project/project-keynes/tools/ideology/m0_epoch_field_audit.py `
    --csv artifacts/ideology-cell-layer/m0/epoch_field_audit.csv
```

脚本只读。`UNKNOWN > 0` 时返回非零，作为「还有字段没有归属」的哨兵。

## 8. 本报告的局限

- 分类依据是**写入点与字段名形态**，不是逐字段的等价性证明。`DERIVED_FROZEN` 的含义是「在某个 epoch-open 函数里被重算」，**不代表**我验证过重算结果与存档时的值逐位相同——那需要 §13.1 第 4 层「生产链路」的恢复对照测试，本里程碑未运行。
- `KNOWN_UNRESTORABLE` 的 5 条是我按语义标注的，不是测出来的。M2 的 `ideology_cell_layer_save_golden_test.gd` 应至少覆盖 `_epoch_cost_anchor_price` 一项，验证标注方向正确。
- 未核对 `_epoch_*` 之外的冻结状态（如 `_city_output_factors_q16`、`_building_factor_cache`），它们不叫 `_epoch_` 前缀但同样不落盘。M0-3 的调用序列会覆盖这一层。
