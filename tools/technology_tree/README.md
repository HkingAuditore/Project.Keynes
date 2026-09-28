# 科技树重构工具

生产数据的唯一作者源仍是 `Project/project-keynes/data/technology/technology_network.json`，
这些脚本只做确定性的批量修订与离线校验，全部可重复执行（幂等）。

## 2026-09-28 polytech 参照重构（生产修订）

按顺序执行，每一步都会在写盘前做离线校验：

```powershell
python tools/technology_tree/wave_b_prerequisites.py --apply   # 前置手术、节点增删、分支族
python tools/technology_tree/wave_a_unlock_integrity.py --repair # 建筑定义性科技与最小附加门槛（不动点）
python tools/technology_tree/wave_d_presentation.py --apply      # 摘要去重、可视边重建、消费者审计
```

- `techtree_lib.py`：离线模型。复刻 `EconomyCatalog` 的建筑依赖组、运行闭包、商品生产许可与
  应用交汇规则，结果与 `technology_unlock_closure_audit_test` / 内容绑定审计一致。
- `wave_b_prerequisites.py`：按 polytech-tree 史实前置重写约 140 个节点的硬前置（每条带中文理由），
  新增 12 个有真实内容或运行时消费者的节点、删除 1 个错放节点，修复路线/知识基础/揭示条件并做
  时代内拓扑排序。
- `wave_a_unlock_integrity.py`：每栋建筑只挂在“使它真正可建”的定义性科技下；附加门槛只保留运行
  闭包（硬投入、资源、产出所需的先验知识）确实需要的最小集合，建材不再是隐藏研究门槛。
  `DEFINING_OVERRIDES` 记录把旧生成器节奏标记换成同时代语义科技的决定。不带参数运行为干跑。
- `wave_d_presentation.py`：已在硬前置链或更早时代可生产的物资，保留绑定但标记
  `summary_visible: false`，不再重复出现在效果摘要；“作为必要支撑”只列一个时代内的直接下游。
- `polytech_lookup.py`：查询 `tmp/polytech/techs.json`（secwind7/polytech-tree 数据，结构化字段
  CC BY 4.0）中的年代、时代与前置，用作前置改动的史实依据。

官方规范化器 `tools/build_technology_network_authoring.gd` 与 `wave_d` 使用同一摘要规则；
HEAD 上遗留的 23 处“同一科技解锁并加成同一物资”冲突会让它拒绝写盘，需先处理这些平衡数据。

## 早期只读审计

`audit_technology_redesign.py` / `build_redesign_wave1.py` 是本轮之前的只读提案工具，
输出 `technology_tree_redesign_*.json/csv` 与 `docs/technology-tree-redesign-*.md`，不写回生产数据。
