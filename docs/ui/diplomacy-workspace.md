# 外交章（`DiplomacyWorkspace`）

国家事务的第五个章节。它回答三个问题：**世界上还有谁**、**谁在跟我打**、**我还能出多少兵**，
并把两件不可撤销的事放在这里——**宣战**与**议和**。议和不在这里写条款：它把战争交给停靠的
`MilitaryPeaceWindow`（与军事章的「议和」同一条链路，见 `docs/ui/military-peace-window.md`）。

```
国家事务 → 外交
  ├ 总览：已知国家 / 交战中 / 我方兵力 / 占领格 · 战事摘要 · 列强榜（带本国基线）· 时局
  ├ 国家：已发现国家名录（国名 / 纪元 / 领土 / 科技 / 关系）+ 单国撕纸档案
  └ 战事：我方参战的战争名录 + 战争档案（战争分 / 战线 / 近日战事）+「议和」
```

## 1. 数据从哪来

| 块 | 来源 | 说明 |
| --- | --- | --- |
| 每格归属 | `MapData.country_slot_arr` | 和国界线、迷雾同一份只读镜像（`CountryMapQuery.owner_map()`） |
| 已发现 / 通视 | `MapData.explored_arr` / `visible_arr` | 迷雾门禁只在这里 |
| 国名 / 领土 / 科技 / 国库 / 纪元 | `CountryFacade.cell_summary(代表格)`、`current_era_index(handle)` | 一国一次，按名单签名缓存 |
| 句柄 | `cell_summary(代表格).country_handle` | 句柄 = `generation << 32 \| slot`，代际只有 Country 知道，所以按格反查 |
| 战争 / 兵力 / 兵营 / 占领 | `MilitaryFacade.country_snapshot(handle)`、`control_snapshot()`、`MilitaryViewModel` | 战事卡、战线、战事记录全部复用军事视图模型 |
| 地名 / 区域名 | `MilitaryViewModel.cell_name()/zone_name()` | 不另造第二套命名 |

名单的扫描是**一次 O(格数)**（每槽位的格数 / 通视 / 已探明 / 代表格 / 与本国相邻的边数），
再按国家做 2 次只读调用（`cell_summary` + `current_era_index`）。结果按
`日 | 国家代际 | 视野修订 | 本国槽位` 缓存，只在签名变化时重扫；日推进只改值，不重建节点。

## 2. 迷雾规则

- **已发现 = 该国任一格 `explored_arr != 0`**；未探索的国家不进名录。
- `fog_solved == false`（视野还没解算 / 测试挂载）时按**全通**处理——与
  `VisionSolver.fog_state()` 的降级规则一致。
- 已发现但当前无通视的国家标「已探明」，有通视标「通视」。只有这一个区别：
  不为外交再发明一套情报模型，其余读数（领土、科技、纪元、兵营、国库）都是 Cabinet
  本来就掌握的事实。
- 本国不进名录（它是「我方」，不是「别国」），但列强榜里有它的基线标记。

## 3. 宣战门控

原生 `MilitaryCore::apply_war_command()` 只校验三件事：**有兵**（`country_soldiers > 0`）、
**未交战**、**无停战**。接壤不是前置——海军科技下远洋同样可及，所以面板也不拿接壤当硬门控，
只在名录的关系列写「接壤 / 远方」，在档案脚注写「不接壤 · 跋涉不易」。

| 状态 | 表现 |
| --- | --- |
| 可用 | 「宣战」按钮可点；tooltip「向〈国名〉递交宣战」 |
| 正在交战 | 按钮换成「议和」（直接指向该 `war_id`） |
| `soldiers_total <= 0` | 禁用，理由「无兵可战 · 先在军事中募兵」；总览时局同步提醒 |
| 军事机构未接通 | 禁用，理由「军事尚未接通」 |
| 无 Country 句柄 | 禁用，理由「未建立往来」（行仍在，领土看得见） |

命令走 `PlayerController.request_command("military.war.declare", {target: handle})`，
D+1 生效。递交成功后本页记 `{槽位, 当日}`，按钮显示「已递交 · 次日生效」并禁用，
直到下一天或战事里真的出现该国——避免连点递交两次。

**动作永远在折叠线以上**：档案页脚（定位 / 宣战 / 议和）排在标题与关系说明之后、
事实与对比条之前；战争名单的每一行还带一个「议和」行内动作。窄屏（1024×576 UI）
下档案会滚动，但两条动作通路都不需要滚动才能点到。

## 4. 战争档案

复用 `MilitaryViewModel.war_card()` / `front_rows()` / `war_log()`：

- 页头：对〈敌国〉· 进攻/防守方 · 已战 N 日 · 双方伤亡（全境沦陷时补一句）。
- 战争分：有 `score_parts` 时画四项拆解（会战 / 占领 / 歼灭 / 损耗，diverging bar）；
  **没有时画一条 −100…+100 的刻度条并标注为总分**——原生目前不导出 `score_parts`，
  这一块是「有则显示、无则换一种画法」，不伪造拆解。
- 战线：`front_rows()`（全局战线，最多 6 条），点行 = 在地图上定位该扇区。
- 近日战事：`war_log()` 取最近 5 条（军事事件环；它不分战争，所以标题写「近日战事」）。
  没有战报时整块（标签 + 行）隐藏，不留一个悬空的小标题。
- 页脚「议和」→ `CountryPanel.peace_negotiation_requested` → `GameUIManager.open_military_peace(war_id)`；
  战争名单的每一行还有一个「议和」行内动作，窄屏不必先滚到档案。

## 5. 材质与版面

| 元素 | 材料 |
| --- | --- |
| 卡片外壳 | `MilitaryFramePanel`（象牙纸 + 九宫撕边；常规 `jade`，国家/战争档案 `cinnabar`） |
| 撕纸便笺 / 剪纸标签 | 主题变体 `PKPaperNote`（时局便笺）/ `PKPaperTag`（战争分、战线、近日战事、纪元、通视） |
| 手绘分隔 | `MilitaryPaperRule`（确定性抖动，不闪） |
| 主按钮 | `PKSealPrimaryButton`（印章纸）；指针动作 `PKDossierLink` |
| 数据 viz | `DossierKpiCard`（4 枚纸带）· `DossierLedgerTable`（名录 / 战事）· `DossierBarList`（列强榜带 `marker` 基线、战争分 diverging、战线）· `DossierStackedBar`（领土 / 兵力两段对比）· `InspectorFactGrid`（6 项国家事实）· `InsightList`（≤3 条时局） |
| 图标 | 既有语义键：`country.world` / `military.war.front` / `military.plan.target` / `military.army.attack` / `military.plan.barracks` / `metric.territory` / `metric.treasury` / `country.technology` / `system.calendar` / `action.pin` |
| 金额 | 只写数字，单位由金币图标承载（`fact.money`）；文案不出现 `¥`/`元` |

版面：`HeaderPlate`（章节页签）+ 可滚动 `PageViewport`，宽屏两列、窄屏一列
（`NARROW_WIDTH = 820`；停靠/紧凑时同样折行）。名录用 `ScrollContainer` 限高（表头 + 7 行），
超出的国家在名录内部滚动，不把整页拉长。1280×720 下 KPI 纸带按 `SHORT_HEIGHT` 切单行密排。

## 6. 文件与接线

| 文件 | 角色 |
| --- | --- |
| `scenes/ui/diplomacy_workspace.tscn` | 静态节点树（运行期只写值，不 `Control.new()`） |
| `scripts/ui/components/diplomacy_workspace.gd` | 章节、版式、按钮、命令提交与回执 |
| `scripts/ui/diplomacy_view_model.gd` | 只读模型：名单 / 国家档案 / 战事 / 总览 |
| `scripts/ui/country_map_query.gd` | 「格归属 → 槽位 → 句柄 → 国名」的唯一解析处（军事视图模型与议和视图模型也用它） |
| `scripts/ui/country_view_model.gd` | `build("diplomacy")`：装配 `military` 段 + `diplomacy` 段 |
| `scripts/ui/components/country_panel.gd` / `scenes/ui/country_panel.tscn` | 第五节章节 + 工作区挂载 + 两个信号转发 |
| `scripts/ui/components/country_action_bar.gd` | 底栏「外交」解锁 |
| `scripts/ui/game_ui_manager.gd` | `COUNTRY_DIRTY_DIPLOMACY` 脏位、日推进与领土/军事提交的标脏 |
| `tests/ui/diplomacy_workspace_test.gd` | headless 契约测试（名单 / 门控 / 刷新不重建 / 议和信号 / 定位） |
| `tests/ui/diplomacy_map_source_test.gd` | 归属与句柄解析的回归（只有 `country_slot_arr` 的世界也必须算出邻国、句柄、割地候选） |
| `tests/qa/diplomacy_workspace_screenshot_qa.gd` | 渲染验收（1280/1600 两种 UI 宽 + 三章 + 两张档案） |

刷新链路：`notify_committed_day()` / `_on_military_command_settled()` / `_on_country_committed()`
标脏 `COUNTRY_DIRTY_DIPLOMACY` → `CountryViewModel.build("diplomacy")` →
`CountryPanel.refresh_summary()` → `DiplomacyWorkspace.refresh_model()`（200 ms 合并，只写值）。

## 7. 已知缺口

1. **停战期不显示日期**：`get_military_country_snapshot()` 不导出 `military_truces`，
   `PlayerController.military_truce_until()` 是返回 −1 的桩。被停战挡下的宣战由运行时静默拒绝。
   补这一条要加原生访问器（需重建 GDExtension），不在本页范围内。
2. **只有我方参战的战争**：原生只按国家导出战争，第三方战事要逐国全量快照，代价与收益不成比。
3. **四项战争分拆解**仍然缺席（同议和窗口 §8.1），本页给刻度条兜底。
4. **外交部名只是名录**：没有常驻使节、关系值、宣战理由或条约清单，这些属于后续外交系统。
5. `MilitaryFramePanel` / `MilitaryPaperRule` / `MilitaryPaperStyle` 是**共享纸材质**，
   名字带 Military 是历史包袱；本页只按路径复用，不改名（改名会动到三个军事场景）。

## 8. 验证

```powershell
$godot = 'D:\Godot\Godot_v4.6.2-stable_win64.exe\Godot_v4.6.2-stable_win64_console.exe'
$project = 'D:\Godot\ProjectKeynes\Project.Keynes\Project\project-keynes'

& $godot --headless --path $project -s res://tests/ui/diplomacy_workspace_test.gd
& $godot --headless --path $project -s res://tests/ui/diplomacy_map_source_test.gd
& $godot --headless --path $project -s res://tests/ui/ui_scene_structure_test.gd
& $godot --headless --path $project -s res://tests/game/player_country_ui_smoke_test.gd
& $godot --path $project -s res://tests/qa/diplomacy_workspace_screenshot_qa.gd
```

截图落在 `res://tmp/diplomacy_ui/`（`diplomacy_<章>_1280x720.png` 等）。
冒烟测试支持 `--capture_dir=<dir>`，会多出一张 `country_diplomacy_1280x720.png`。
