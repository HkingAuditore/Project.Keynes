# 营造窗口（右栏建筑页 → 外附营造目录）

在地块档案的「建筑」页签里点「选择项目」，右侧档案面板会变宽并展开一张**营造目录**：
按产业部门浏览本格可以营造的建筑、每一项的建造成本，以及「现在能不能建」。

它是外挂在土地档案上的窗口，与对象详情、家族档案、军务档案共用同一个
`InspectorPanel`（`UIRoot/PanelLayer/RightPanel`），因此共享页头语法、
加宽分栏、开合动效与 ESC 关闭。

```
建筑页签（地块档案）
  → 底部纸笺「营造新建筑」（CellInspectorViewModel.build_construction_entry）
     └ 只报目录规模，不报价
  → 点「选择项目」：InspectorPanel._open_building_workspace()
     → 发出 construction_page_requested(sector="", search="", sort="recommended", offset=0)
     → GameUIManager._on_construction_page_requested()
     → CellInspectorViewModel.build_construction_model(cell, sector, search, sort, offset)
        ├ 建筑快照（同格同日 memo）
        ├ EconomyFacade.construction_type_columns()     部门 / 工期 / 成熟度档
        ├ EconomyFacade.construction_candidates(...)    部门 + 科技 + 搜索过滤（不分页）
        ├ EconomyFacade.construction_quotes(...)        整部门一次报价（国库/市场/现金）
        ├ 排序（可建优先 → 推荐/造价/最新）→ 切一页
        └ EconomyFacade.market_cell_snapshot()          本地现货（估算毛利与现货提示）
     → BuildingWorkspace.set_model(model)
  → 点行内「营造」：construction_requested → PlayerController.request_command("construction.build")
     → 次日结算 → construction_command_settled → 强制刷新窗口
```

## 1. 面板行为

| 事件 | 结果 |
| --- | --- |
| 点入口纸笺「选择项目」 | 面板变宽到 `min(1040, max(860, 视口×0.62))`，显示营造目录；首次打开由 VM 选默认部门（第一个有可选项目的部门） |
| 点部门索引签 | 换部门并从第 1 页重取；滚动回顶 |
| 点排序签（推荐 / 造价 / 最新） | 换排序档并从第 1 页重取；再点当前档不重取 |
| 点「上一页 / 下一页」 | `offset ± 16`；越界时 VM 回落到第 1 页 |
| 搜索框回车 | 在当前部门内按名称/稳定 id 过滤；搜索词非空时搜索行常驻 |
| 点行内「营造」 | 立即提交 `construction.build`；该行进入「营造中…」1.2 s（防手抖重复下单，不阻止当天连排两座） |
| 命令被立即拒绝 | 反馈纸笺转朱红，清掉 pending |
| 次日结算 | 结算回执到达后强制重取同一页；未结算时按 1 s 墙钟节流重取 |
| × / ESC | 关闭详情；有地块档案则回到目录列，没有则面板整体收起 |
| 换选中地块 | 清掉上一格的目录模型；再打开时重新解析默认部门 |

## 2. 页面骨架（`scenes/ui/building_workspace.tscn`）

```
BuildingWorkspace (Control)
└ Margin (10/8/6/10)
  └ Body (VBox, sep 8)
    ├ TitleRow: HeaderIcon(剪纸徽记) + Kicker/Title/Subtitle + CloseButton
    ├ RuleTop  (2px 朱红细线)
    ├ SectorNav (DossierChapterNav)          部门索引签
    ├ SortRow (PKDossierChip ×3)             排序签：推荐 / 造价 / 最新
    ├ FilterRow (LineEdit + 计数)            仅 total > limit 或搜索词非空
    ├ ListArea (VBox)
    │   ├ Scroll → Rows (VBox)               运行时实例化 building_option_row.tscn
    │   └ EmptyNote (PKDossierNote)          空/不可用时的纸笺
    ├ Footer (上一页 / 页码 / 下一页)         仅 total > limit
    └ StatusNote (PKDossierNote)             命令回执与刷新提示，空则隐藏
```

页头文案：`营造目录` / `新建建筑` / `{地貌} · {地形} · 国库出资，缺料市购`。

**这里没有 KPI 带。** 曾经有过「可营造 / 国库资金 / 现金支出 / 市场采购」四格，已删除：
前三格把整页 16 行加起来（一个玩家永远同时建不完的假设值），国库余额顶栏本来就有；
一格「市场采购」只是同页里需要外购的行数。玩家的决定是「这一座建不建」，
答案已经在行里（成本 + 按钮可用性 + 短因由 + hover 拆解），所以页面只留
部门签、排序签、行与翻页。

## 3. 排序

三档，均为「**可建优先**」之后再排，且都在**整个部门**范围内排序、然后才切页
（整部门一次报价实测 0.14–0.26 ms，见第六节）：

| 档 | 主键 | 次序 | 说明 |
| --- | --- | --- | --- |
| 推荐（默认） | 估算毛利/日 | 高 → 低 | `Σ产出量×本地价 − Σ投入量×本地价`（本地市价，未计工资与税）；同分按现金支出升序 |
| 造价 | 现金支出 | 低 → 高 | 同分按估算毛利降序 |
| 最新 | 生产成熟度档 `maturity_rank` | 高 → 低 | 自然获取 → 自动化；同档按估算毛利降序 |

排序只是**视图启发式**：估算毛利不进模拟，也不写成建筑状态；它的用途是决定行的先后，
并在 hover 的「概况」里给出量级。

## 4. 行契约（`scenes/ui/building_option_row.tscn`）

```
BuildingOptionRow (PanelContainer, PKPaperCard)
└ Row: Icon(剪纸徽记) + Info(Name / Meta) + Cash(金币+数字) + BuildButton(PKPrimaryButton)
```

- **按钮即可用性**：可建 = 深胭脂纸钮 +「营造」；不可建 = 浅纸 + 弱墨字且禁用。
  这是「能不能建」的唯一视觉表达，行本身不可点（避免手滑花掉国库）。
- **Meta 单行**：可建写建材（`木材 2.4 · 石料 1.2`，超过 3 组写「等 N 项」）；
  不可建时**先说因由**（`缺建材 · 木材 2.4 …`）并转朱红。
- **现金列**：`cash_required > 0` 时显示，为 0 时整列隐藏。
- **hover 详情**（行 tooltip，先答「提供什么岗位、吃什么、产什么」，再答成本与卡点）：
  ```
  岗位：业主 工匠 ×1 · 雇员 工匠 ×4
  投入：原木 0.500/日
  产出：木材 0.250/日
  建材：木材 2.4（国库 1.8 / 市购 0.6 · 单价 12）
  现金：3.20
  现货：木材 现有 0.200 / 缺口 0.600
  概况：机械化 · 工期 3 日 · 估算毛利 12.4/日
  不满足：市场缺货
  ```
  每段独立成行、段名在前；没有数据的段整行不出。投入若有可替代物资，最多列 3 种
  再写「等 N 种」。tooltip 里金额只写数字（不支持内联金币）。

原生拒绝码 → 行内短因由：

| code | 文案 |
| --- | --- |
| `construction_cell_not_owned` | 非本国领土 |
| `construction_technology_locked` | 科技未解锁（**出现在这里只作兜底**：这类条目在 VM 里被直接剔除，不进列表） |
| `construction_obsolete` | 已被高阶取代 |
| `construction_conditions_failed` | 地块不符 |
| `construction_resource_unavailable` | 自然资源不足 |
| `construction_materials_insufficient` | 建材不足（市场现货不够缺口时显示「市场缺货」） |
| `construction_treasury_cash_insufficient` | 资金不足 |
| `construction_market_unavailable` | 市场不可结算 |
| `construction_owner_signature_unavailable` | 无合适业主 |

## 5. 数据契约

`CellInspectorViewModel.build_construction_model(cell, sector, search, sort, offset)` 输出：

| 键 | 内容 |
| --- | --- |
| `available` / `message` / `data_pending` | 可用性；`data_pending` 时窗口保留上一份行只提示「正在刷新」 |
| `cell` / `sector` / `search` / `sort` / `offset` / `limit` / `total` / `sector_total` / `page_label` | 分页身份 |
| `header` | `{kicker, title, subtitle}` |
| `sectors` | `[{id,label,icon,count,question,selected}]`（count=0 的部门不出现） |
| `sorts` | `[{id,label,tooltip,selected}]`，固定三档 |
| `items` | 当前页行数据（见第四节；`building_id/name/icon/eligible/reason_text/materials_text/cash_text/tooltip`…） |
| `query` | `{sector,search,sort,offset}`，窗口据此重发同一页 |

模型里**没有 `kpis`**：窗口不显示任何聚合读数（见第二节）。

目录口径：**科技可用 + 非官营**。官营建筑（`building_kinds == 3`：兵营 / 城防 / 军校）
只从军事页签的建造入口下达，不进民用目录；部门取 `building_economic_sectors`
（`agriculture / extractive / manufacturing / energy / knowledge`，见
`EconomyCatalog.BUILDING_SECTOR_IDS`，顺序即编译列索引，只准追加）。

科技未解锁的条目在目录层就被 `building_technology_available` 过滤（原生侧它就是完整的
`building_available`：直接科技标签 + 必需科技标签 + 依赖闭包），VM 再按报价的
`construction_technology_locked` 兜底剔除一次。

报价来源是原生的 `get_treasury_construction_quotes`：`eligible` 已经同时包含
科技、地形、自然资源、建材（国库 + 本地市场）、市场可结算与国库现金五道门；
UI 不重算这些规则，只做展示、排序与细分因由。报价对象是**整个部门**的候选
（`EconomyFacade.construction_candidates` + `construction_quotes`），排序与分页都在 GD 侧完成。

## 6. 性能与刷新契约

| 操作 | 复杂度 | 频率 | 预算 |
| --- | --- | --- | --- |
| 打开 / 切部门 / 切排序 / 翻页 / 搜索 | 1×建筑快照（memo）+ **整部门**报价 + 市场快照 | 玩家操作 | p95 ≤ 4 ms |
| 窗口打开时日推进 | 同上 | ≤ 1 次 / 1000 ms | ≤ 4 ms |
| 结算回执 | 同上 | 每次 `construction.build` | ≤ 4 ms |
| 建筑页签每日 patch | 只读建筑快照 + 条目计数 | 现有 750 ms 节流 | 比以前少一次 32 项报价 |

整部门报价实测（release GDExtension，单格）：农业 107 项 0.22 ms、采掘 67 项 0.14 ms、
制造 242 项 0.26 ms、能源 5 项 0.02 ms、知识 21 项 0.06 ms；全部 442 项 0.50 ms；
同一次刷新里建筑快照本身 0.44 ms。因此「整部门排序再分页」与「只报当前页」同量级。

- 查询身份 = `cell|sector|search|sort|offset`：身份不变只写值（名称/成本/因由/按钮态/现金），
  节点数不变；身份变化才重建行节点。
- 行节点用 `PackedScene.instantiate()`；页面脚本不 `new()` 任何 Control
  （`tests/ui/ui_scene_structure_test.gd` 的静态规则对本页生效）。
- 快照忙（`busy` / `read_view_pending`）时保留上一份行，只挂 `data_pending`。

## 7. 验证

```text
godot --headless --path Project/project-keynes -s res://tests/ui/building_workspace_test.gd
godot --headless --path Project/project-keynes -s res://tests/ui/inspector_live_patch_test.gd
godot --headless --path Project/project-keynes -s res://tests/ui/ui_scene_structure_test.gd
godot --headless --path Project/project-keynes -s res://tests/economy/treasury_construction_runtime_test.gd
godot --path Project/project-keynes --resolution 1920x1080 \
  -s res://tests/qa/building_workspace_screenshot_qa.gd
```

截图输出在 `res://tmp/building_workspace_qa/`（424 / 604 / 1236 三种页宽 ×
可营造 / 被拒 / 空目录）。
