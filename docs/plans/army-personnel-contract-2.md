# 随军人口 · 第二批契约（split/transfer 搬人 + 海运运兵）

> 2026-11-03。接 `army-personnel-implementation-contract.md`，只补充两条链路。
> 代码为准；实现后同步 `docs/cpp-dots-runtime/military-recruitment-pipeline.md` 与本契约。

## 1. 分兵 / 转移必须搬人（E1b + M1b）

现状：`MCMD_ARMY_SPLIT` 新建一支部队并搬 lot，`MCMD_ARMY_TRANSFER` 在部队间搬 lot，
但随军人员 lane 不动 → 部队人数与 lot 人数错位。

### 1.1 经济侧：新增 opcode 33

| opcode | 名称 | payload0 | payload1 | target_cohort | target_cell | target_country |
| --- | --- | --- | --- | --- | --- | --- |
| 33 | `ARMY_SPLIT_LANES` | 人数 | dst army handle | src army handle | — | — |

- 从 src lane 取 `min(人数, lane 人口)`，人口/资金按比例并入 dst lane（dst 不存在则创建，
  `country_slot`/`cell` 取 src 的）。
- 守恒：两 lane 合计人口/资金不变；与 30/31/32 一样按 `sequence` 幂等，POD 准入白名单放行到 33。
- lane 不需要结构提交（lane→lane 不碰 cohort），与 32 同路径。
- 若 `payload0 <= 0`：整条 lane 移动（等价 32 的语义），保留给"整支部队转移"。

### 1.2 军事侧

- `army.split`：按分出去的人头数发 `MILITARY_INTENT_ARMY_SPLIT_LANES {src army, dst army, heads}`。
  heads = 本次搬走的 lot 人数合计（用 lot 的 count，不用模板）。
- `army.transfer`：目标部队已存在时同样走 33（部分搬迁）；若整支部队并入，走 32。
- `army.merge`：维持 32。
- 记账：lane 人数与 lot 人数必须在同一日对齐；短差按现有 `reconcile` 规则处理（谁少扣谁）。

## 2. 海运运兵（N1）

### 2.1 规则（设计 §7.4 简化版）

- 水体默不可通行（现状）。解锁后允许**连续水格**通过：
  - `tech.military.coastal_transport`（近海运兵）：连续水格 ≤ 3，且出发/登陆必须是陆地格；
  - `tech.military.naval_transport`（远洋运兵）：无连续水格上限。
- 需要新增两条科技节点（内容在 `data/technology/technology_network.json`）与
  `data/military/military_catalog.json` 的两个 unlock 位（`unlock_tech_ids` 追加，不重排已有位）。
- 部队在水格上时姿态自动为 `MILITARY_STANCE_EMBARKED`；登陆当帧恢复原姿态。
- 水格移动力消耗 = 陆地的 1.5 倍（q16 1.5），且 `MSTAT_NAVAL_TRANSPORT` 只影响消耗不影响门控。
- 海运部队在海上不承受陆地恶劣环境减员（已有豁免），但每日受 `kSeaAttritionBp`（默认 20bp，
  即 0.2%/日）损耗，且不参与陆地交战（保持现状）。
- 没有解锁科技时，`find_path` 必须像现在一样拒绝水格（不得静默放行）。

### 2.2 接口

- `MilitaryCatalog` 增加 `coastal_transport_bit` / `ocean_transport_bit`（默认 -1），
  由 `MilitaryCatalogCompiler` 从这两个 tech id 解析；未配置则视为未解锁。
- 判定用 digest 的 `country_unlock_bits`，不用新的运行时字段。
- `preview_path` 返回的 `days` 必须把海运段的 1.5 倍消耗算进去。

## 3. 验证

1. `military_runtime_smoke_test.gd` 增加：split 后两支部队 lane 人数之和 = 原人数；
   transfer 后人数守恒；split 出的部队可以独立行军且人口随行。
2. 新增 `tests/military/naval_transport_probe.gd`：无科技时 `preview_path` 到海外格返回失败；
   给国家解锁 `tech.military.coastal_transport` 后 3 格内海峡可通、4 格不可；解锁远洋后可通过。
3. 120 天活世界探针不得回归（无 fault、名册与经济一致）。
4. 内核自测扩充：split/transfer lane 守恒；海运门控与消耗。

## 4. 不做

- 不做海军单位、海战、封锁。
- 不做运兵船库存与航渡时间（水格只是更贵的移动力）。
