# 议和窗口（MilitaryPeaceWindow）

战争议和不是国家卷宗里的一张卡，而是一块**独立、非模态、左停靠**的窗口：它不遮地图、不暂停时钟，
玩家在窗口里勾条款，同时在地图上点选要交割的占领格。设计依据是 `docs/plans/military-system-design.md`
§12.3（条款与接受倾向）与 §14.3（军事面板），交互范式沿用开拓面板的「map-first 作业面」。

```
打开：国家事务 → 军事 → 战争 →「打开议和窗口」
     总览 → 战争卡「议和条款 ›」
窗口：MilitaryPeaceWindow（左停靠，560 × 剩余高度）
      ├ 战况：战争分 / 我方占领 / 敌方残土 / 战线 / 伤亡 / 最近战事
      ├ 条款：白和平 · 割地（地图点选）· 一次性赔款 · 分期赔款 · 吞并
      └ 页脚：条款总价 / 对方意愿 / 接受倾向 +「用印递交」
地图：带斜纹的占领格 = 可选交割格，点一下加入草案，再点一下撤销
```

## 1. 不挡屏的硬约束

| 约束 | 做法 |
| --- | --- |
| 不压暗、不暂停 | 没有遮罩 ColorRect，不开暂停；日推进时窗口自己刷新数值 |
| 不挡地图 | 左停靠，宽 `clamp(视口 × 0.42, 560, 760)`；1280×720 下 560×534，右侧仍留 ~55% 地图 |
| 地图可点 | 地图点击在 `PlayerController.select_cell()` 里、**清高亮之前**交给窗口；命中候选格就切换草案并 return |
| 右键仍是平移 | 窗口从不消费右键；ESC 由 `GameUIManager._unhandled_input` 处理 |
| 不抢部队拾取 | 窗口开着时 `_on_tile_tapped` 跳过 `military_map_pick()`，否则点在被占领格上的部队棋子会抢走交割点击 |
| 镜头避让 | `map_safe_area()` 把窗口右沿算进去，`ensure_point_visible` 不会把目标格推到纸下面 |

## 2. 打开 / 关闭

| 事件 | 结果 |
| --- | --- |
| 战争页「打开议和窗口」/ 总览战争卡动作 | 关掉国家卷宗 → 隐藏右栏 Inspector 与地图悬浮工具条 → `open(war_id, military_model)` |
| 打开时 | 草案重置为白和平；全部候选占领格在地图上描边；镜头对准第一块候选（没有候选就对准会战格） |
| ESC | 关窗（不是取消选点：选点是隐式的，任何点击都算） |
| 关闭 | 清空候选/草案两组高亮，恢复被抑制的 Inspector 与工具条；不自动重开国家卷宗 |
| 战争在打开期间结束 | 下一次刷新进入「战争已结束 / 和约已生效」态：全部禁用、清高亮、只留关闭 |

## 3. 战况（要求 0）

数据全部来自 `MilitaryViewModel` 的同一份战争快照，不新增模拟读取：

| 块 | 内容 | 来源 |
| --- | --- | --- |
| 页头 | 与〈敌国〉议和 · 已战 N 日 · 进攻/防守方 · 双方伤亡 | `war_card()` |
| KPI（宽 ≥640 四枚，窄屏两枚） | 战争分（四项拆解有数据时展开）· 我方占领格 · 敌方残土 · 战线数 | `war_card()` / `ceded_cells()` / owner map |
| 战况行尾 | 敌土 N 格 · N 处战线 / 全境沦陷 | 同上 |
| 最近战事 | ≤3 条会战/占领/歼灭 | 军事事件环 `war_log()` |
| 四项拆解 | 会战 / 占领·歼灭 / 损耗 | 快照带 `score_parts` 时才显示（当前原生未导出，见 §8） |

窄屏（1280×720 的实际停靠宽度）只显示两枚 KPI：720p 停靠后滚动区只剩约 380 px，
四枚 2×2 会挤掉整块条款；另外两个数字折进战况行尾与页头，读数不丢。

## 4. 条款（要求 1）与编码

| 条款 | UI | 编码（`encode_peace_terms`） |
| --- | --- | --- |
| 白和平 | 默认勾选；与其它条款互斥（勾它清空草案与赔款） | `{kind:"white"}` |
| 割地 | 地图点选 / 清单勾选，一格一条；勾选任意格即取消白和平 | 每格一条 `{kind:"cede", cell}` |
| 一次性赔款 | 金额（金币图标 + 数字，无货币符号） | `{kind:"lump_sum", amount}` |
| 分期赔款 | 每期金额 + 期数 2–12，显示总额 | `{kind:"installments", amount, n}` |
| 吞并 | 仅「对方全境沦陷且我方独占其全部领土」可选 | `{kind:"annex"}` |

- 接受倾向与总价由**原生评估器**给：`evaluate_military_peace()` 返回 `price / willing / gap / band`，
  窗口显示「条款总价 X 分 · 意愿 Y · 分差 Z · 接受倾向 高/中/低」。旧桥没有评估器时标注为估算并说明。
- 递交走 `military.peace.propose`（D+1 生效）。递交当天按钮禁用；次日战争还在 → 显示「对方未接受，
  第 N 日后可再提」并禁用 30 天（会话内推算，见 §8）。
- 未勾选任何条款 → 递交禁用；白和平单独就是一份合法和约。

## 5. 地图交割（要求 2）

- 候选集 = 控制快照里 `controller == 我方` **且** 所有权属于敌国的格（`ceded_cells()` 同一条规则）。
- 打开时用候选高亮节点把候选格描出来；点选后草案高亮跟上（两块 `CellHighlightSet`，互不覆盖）。
- 点击候选格：加入/移出草案 → 清单勾选、`N / M 格`、条款总价、地图高亮同帧更新。
- 点击非候选格：消费这次点击并给出原因（「只有我方占领的敌国领土能写进和约」），**不打开地块档案**。
- 不勾选的占领格会随和约自动交还（原生 `execute_treaty` 的语义），条款区底部写明这一点。

## 6. 材质与版面（剪纸 / 撕纸 / 手绘）

| 元素 | 材料 | 资产 |
| --- | --- | --- |
| 窗口外壳 | 象牙纸面 + 朱红九宫撕边 | `MilitaryFramePanel`（`ideology_paper_v3/ivory_sheet + edge_cinnabar_gold`） |
| 战况 / 条款块 | 撕纸便笺 | 主题变体 `PKPaperNote`（`paper_aux_v1/torn_note_v1`） |
| 小标题 | 剪纸标签 | `PKPaperTag`（`paper_aux_v1/cut_tag_v1`） |
| 交割清单 | 自绘纸贴勾选框（无运行期节点） | `MilitaryToggleList` |
| 主按钮 | 印章纸 | `PKSealPrimaryButton` |
| 图标 | 彩铅剪纸图集 | `IconCatalog`：`military.war.peace` / `military.war.front` / `military.war.battle` / `military.plan.target` |
| 金额 | 金币纸贴 + 数字 | `MoneyIcon`（文案不出现 `¥`/`元`） |

版面：单列 + 内部滚动 + 固定页脚。纸边按 `48 × frame_scale` 像素绘制，内容边距由 `MilitaryFramePanel`
自动让开；关键词数写在 `military_peace_window.gd` 顶部常量里（最小宽 560、KPI 折行阈值 640、
交割清单视口 48–104 px）。

## 7. 文件与接线

| 文件 | 角色 |
| --- | --- |
| `scenes/ui/military_peace_window.tscn` | 静态节点树（运行期只写值） |
| `scripts/ui/components/military/military_peace_window.gd` | 窗口外壳：布局、草案、递交门控、地图点击入口 |
| `scripts/ui/military_peace_view_model.gd` | 只读模型：战况 / 候选 / 条款编码 / 评估 |
| `tests/military/military_peace_window_test.gd` | headless 契约测试 |
| `tests/qa/military_peace_window_screenshot_qa.gd` | 渲染验收（1280/1920 两种 UI 宽 × 白和平/已点选） |

接线（`player_game.tscn`、`GameUIManager`、`PlayerController`、`CountryPanel`）已完成；旧内联 `PeaceEditor`
的下线与 `MilitaryWorkspace` 的启动卡替换等 `military_workspace.*` 这一批编辑停手后落地。
窗口本身不依赖它们，可以单独挂载与测试。

### 7.1 接线契约（下一步照此实现）

| 位置 | 必须提供 | 说明 |
| --- | --- | --- |
| `MilitaryWorkspace` | `signal peace_negotiation_requested(war_id)` | 战争页启动卡与总览战争卡动作都发它 |
| `CountryPanel` | 同名信号转发 | 和 `locate_cell_requested` / `target_cells_requested` 同一个转发位 |
| `GameUIManager` | `open_military_peace(war_id)`、`close_military_peace()`、`is_peace_window_open()`、`handle_peace_map_cell(cell) -> bool` | 开窗时先 `close_country_panel()` + `_suppress_ui_for_dispatch()`；`map_safe_area()` 加左沿；`_hover_blocked()` 加判断；ESC 关窗 |
| `PlayerController` | `highlight_cells(cells, frame := true)`、`highlight_peace_candidates(cells)`、`highlight_peace_draft(cells)`、`clear_peace_highlights()`、`focus_map_cell(cell)` | 测试里的 `FakeController` 精确记录这三个高亮方法；`select_cell()` 在 `clear_cell_highlights()` **之前**把点击交给 `handle_peace_map_cell`，窗口开着时跳过 `military_map_pick` |
| `player_game.tscn` | `ModalLayer/MilitaryPeaceWindow`（紧跟 ColonizationPlannerPanel）、`WorldRoot/CellHighlightSetDraft` | 候选/草案两层高亮互不覆盖 |
| `military_workspace.tscn` | 删除 `WarGrid/PeaceEditor`，加 `WarGrid/PeaceCard` | 启动卡只读汇总 + 印章按钮 |
| 日刷新 | `notify_committed_day()`、`_on_military_command_settled()` 里 `invalidate_cache(COUNTRY_DIRTY_MILITARY)` → `build("military")` → `_peace_window.refresh_model(model)` | 窗口自带 200 ms 合并；节点数不变 |

窗口直接调用控制器的三个高亮方法（`has_method` 探测），同时发 `draft_changed(cells)` 供外层记录；
`submit_requested({war_id, terms})` 由 `GameUIManager` 转成 `military.peace.propose`，回执再喂
`set_command_result(result)`。


## 8. 已知缺口（不在本窗口内解决）

1. **四项战争分拆解**：`get_military_country_snapshot()` 不导出 `score_parts`，窗口有则显示、无则隐藏，不伪造数据。
2. **和议冷却的权威来源**：快照没有 `last_rejected_offer_day`，本版按「递交日 + 30」在会话内推算；读档后失效。
3. **交还条款**：原生 `return` 的价格是负值，而未割让格本来就会自动交还，等价于免费降价；要先做设计决策再暴露。
4. **赔物资条款**：原生支持 `goods`，但需要货物选择器与败方库存语义，延后。
5. **对方提议的接受/拒绝**：`peace.respond` 没有 pending offer 状态，原生侧直接成交；需要 native 改动。
6. 以上 1/2 都需要重新构建 GDExtension 并切换 `dots_ext.gdextension` 的 DLL 名，与本窗口的 UI 工作分开做。

## 9. 验证

```powershell
$godot = 'D:\Godot\Godot_v4.6.2-stable_win64.exe\Godot_v4.6.2-stable_win64_console.exe'
$project = 'D:\Godot\ProjectKeynes\Project.Keynes\Project\project-keynes'

& $godot --headless --path $project -s res://tests/military/military_peace_window_test.gd
& $godot --path $project -s res://tests/qa/military_peace_window_screenshot_qa.gd
```

截图在 `res://tmp/military_peace_qa/`（`peace_1280*.png` / `peace_1920*.png`）。
注意项目跑 1.25× 桌面缩放：1600×900 的窗口才是 1280×720 的 UI，QA 按逻辑视口断言。
