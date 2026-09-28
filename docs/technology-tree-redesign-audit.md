# Project Keynes 科技树重构基线审计

本报告由 `audit_technology_redesign.py` 从 schema v4 权威源生成。它不修改生产科技网络。

## 总览

- 节点：369；应用交汇：355；时代：11
- 时代分布：{"stone": 73, "agrarian": 64, "kingdom": 33, "empire": 28, "exploration": 26, "enlightenment": 26, "steam": 25, "electrical": 24, "atomic": 24, "information": 24, "intelligent": 22}
- 领域分布：{"society": 82, "agriculture": 73, "science": 70, "engineering": 144}
- 角色分布：{"branch": 308, "backbone": 61}

## 需要重构的基线问题

- 非终端支线无后继：157
- 无直接效果或解锁摘要：17
- Kingdom 及以后没有 research route：17
- reveal 与 route 信号重叠：2
- 重复绑定组：106
- 硬前置循环：0

## 分支族群

| branch family | 节点 | 时代跨度 | 时代数 | 无后继节点 |
|---|---:|---:|---:|---:|
| `backbone.food_storage` | 16 | 0–10 | 7 | 6 |
| `backbone.institutions_exchange` | 21 | 0–10 | 11 | 11 |
| `backbone.knowledge_computation` | 15 | 0–8 | 8 | 8 |
| `backbone.tools_machinery` | 9 | 0–8 | 7 | 8 |
| `branch.commerce_finance` | 8 | 0–9 | 4 | 7 |
| `branch.computation_control` | 16 | 7–10 | 4 | 6 |
| `branch.construction_materials` | 13 | 0–6 | 4 | 11 |
| `branch.electric_intelligent_energy` | 10 | 7–10 | 3 | 6 |
| `branch.forest_biomass` | 7 | 0–6 | 5 | 2 |
| `branch.geoscience_gis` | 10 | 4–10 | 5 | 5 |
| `branch.heavy_industry` | 26 | 1–10 | 8 | 16 |
| `branch.industrial_chemistry` | 10 | 0–8 | 8 | 6 |
| `branch.labor_management` | 19 | 3–10 | 7 | 6 |
| `branch.land_institutions` | 11 | 1–5 | 5 | 5 |
| `branch.maize_horticulture` | 13 | 0–9 | 5 | 8 |
| `branch.maritime_logistics` | 14 | 0–10 | 9 | 5 |
| `branch.measurement_instruments` | 10 | 0–7 | 7 | 6 |
| `branch.natural_history` | 14 | 0–10 | 6 | 7 |
| `branch.nonferrous_metals` | 14 | 0–8 | 6 | 6 |
| `branch.pastoral_livestock` | 19 | 0–8 | 8 | 6 |
| `branch.petroleum_materials` | 8 | 7–8 | 2 | 3 |
| `branch.public_health` | 6 | 2–8 | 4 | 3 |
| `branch.rice_irrigation` | 13 | 0–10 | 7 | 8 |
| `branch.textile_fibers` | 14 | 0–8 | 6 | 5 |
| `branch.tropical_commodities` | 16 | 0–4 | 3 | 9 |
| `branch.tuber_highland` | 10 | 0–3 | 3 | 4 |
| `branch.water_wind` | 9 | 0–5 | 5 | 5 |
| `branch.wheat_rainfed` | 18 | 0–8 | 8 | 12 |

## 实施顺序

1. **backbones_and_milestones**：主干、时代里程碑、硬前置和首批研究入口
2. **core_industry_branches**：农业、畜牧、材料、水利、贸易和测量
3. **modern_capabilities**：能源、控制、信息、生物和智能时代
4. **long_tail_and_presentation**：低影响长尾、重复内容、中文展示和来源追溯

## 分类规则

- `topology_review`：支线没有后继且没有明确终端理由。
- `content_review`：没有内容效果或 Modifier 记录，需要绑定真实对象或明确标记为发现型节点。
- `route_review`：Kingdom 以后没有 research route，需要补充独立证据入口或写明豁免理由。
- `reveal_route_overlap`：同一信号同时承担发现和路线条件，需要拆分。
- `retain_or_minor_rebind`：当前基线没有触发上述审计项，仍需在内容波次中复核名称与效果关联。

## 兼容边界

- 本报告不改变 stable ID、catalog hash、存档 schema 或运行时 authority。
- 生产修改必须继续通过 TechnologyCatalog、Country、Economy、Effect、Modifier 和 UI 现有验证链。
