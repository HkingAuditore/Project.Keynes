# 科技树排查视图（technology_tree）

Civ 式交互科技树报告页，用于排查 `TechnologyCatalog` 的分布、前置链、研究条件与数值效果。
纯离线工具，不参与任何运行时、UI 或存档路径。

## 重新生成

科技作者目录（`data/technology/technology_network.json`）或经济内容绑定改动后，从
`Project/project-keynes` 运行：

```powershell
& "<godot_console.exe>" --headless --path . --script res://tools/export_technology_tree.gd
```

发布或提交前使用只读检查模式确认生成物没有落后于权威目录：

```powershell
& "<godot_console.exe>" --headless --path . --script res://tools/export_technology_tree.gd -- --check
```

脚本编译权威目录（361 节点 / 11 时代自检），一次生成两份确定性报告：

- `technology_tree_report.html`：把目录数据、预编译可视边和结构化内容效果注入
  `technology_tree_template.html` 后得到的自包含交互报告，无外部依赖，双击即可在浏览器打开；
- `technology_tree_report.md`：按时代分组的完整审计清单，记录每项科技的稳定 ID、领域、
  成本、节点标记、硬前置、替代证据、应用交汇、研究/揭示条件、路线、效果摘要、永久
  Modifier、结构化内容效果、机会成本、内容解锁、同路线后继、应用交汇、里程碑候选与
  直接后继。

两份文件都按权威目录顺序生成，不包含时间戳；它们是生成产物，不必手改。

同产物建筑的科技升级关系另由显式审查表守门。修改建筑科技标签、产物或升级层级后运行：

```powershell
python tools/audit_technology_unlock_progression.py
```

该审计禁止辨识科技直接解锁建筑，要求同升级家族的后继层级严格上升，并要求每条相邻
科技的同产物建筑关系在脚本中明确分类为升级、专门化或替代方案。报告写入
`technology_unlock_progression_audit.md`；任何新增或失效的关系都会使命令失败。

## 报告页操作

- 纵向行 = 全局依赖层（DAG 最长路径分层，自上而下推进，层内重心排序压减跨线）；
  每层最多 5 张卡一行，超宽的层自动折成多条居中行（折行行距小、换层行距大，易于区分）。
  里程碑独占一行横贯居中，终结本时代并承接下一时代；
  时代以横向条带 + 衬线标题呈现（左侧题名，右侧罗马数字水印）。
  里程碑为金框大卡，时代关键为菱形徽记，区域开局候选为圆点徽记。
  实线为硬前置，点线为替代说明，虚线为应用交汇；里程碑「16 选 5」候选边默认隐藏。
  顶栏边类型开关显示各类边数量并可独立切换。
- 点击节点：左侧详情面板显示成本、内容、解锁内容（建筑/物资/自然资源，来自
  EconomyCatalog 权威反向绑定）、前置、研究信号条件、永久 Modifier 数值条款、
  路线标签与后继；点击前后置芯片可跳转定位。
- 未选中时左栏显示「时代 × 领域」分布矩阵，点击单元格高亮对应分组。
- 悬停/选中节点高亮完整前置链与后继链；Esc 或点击空白清除；搜索框按名称/id/路线
  过滤（回车选中首个命中）；领域徽章可整域隐藏；右上有 100%/72%/50% 缩放。
