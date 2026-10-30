# 玩家界面字体与辨识度

主入口：`scripts/ui/ui_tokens.gd`、`assets/themes/player_session_theme.tres`。
主菜单与家族主题使用同一套正文/标题字面。年度纪事的封面展示排版仍由其专用字阶管理。

## 字体职责

| 内容 | 字体 | 常用字号（100% UI 缩放） |
| --- | --- | --- |
| 主标题与档案标题 | Muyao Softbrush | 34–36 |
| 章节标题 | Muyao Softbrush | 26–28 |
| 科技名称、列表名称 | Swei Gothic Leg Bold | 18–21 |
| 正文、条件说明、事实表 | Swei Gothic Leg Regular | 17–18 |
| 注释、列头、次级说明 | Swei Gothic Leg Regular | 15–16 |
| 关键读数、金额、百分比 | Swei Gothic Leg Bold | 20–28 |

标题的手写字面只用于有足够显示空间的短文案。科技卡名称需要快速扫读，使用 Swei 粗体。
`dossier_font("serif")` 是保留旧调用的 Muyao 标题别名；数字用 `numeral`。
`font_with_weight()` 选择真实 Swei Regular/Bold 字体，不模拟描粗。
Muyao 使用完整 Swei 回退；字体来源与授权说明位于各自的字体目录。

旧思源可变字体使用字符串 `wght` 时，在当前 Godot 4.6.2 中实测 200 和 900
字重的拉丁字符宽度相同；改用数值轴后才分别为 261px 和 304px。
新的静态字面避免这一默认 ExtraLight 退回问题。

## 图标和布局

- 复用 `IconCatalog` 已有的彩铅剪纸位图，保持原色、纸边和透明背景。
- 顶部控制图标 36px，国家入口 56px，图层主图标 48px、子图标 40px。
- 顶栏左上角的日历块（日期 + 时代）宽度由字体度量推出，不写死像素：纸框宽度 =
  图标 + 段间距 + 日期字宽 + 时代字宽 + 纸框左右留白，只向大取；每个 Label 另留
  3px 余量，字不会压到纸边。日期列按"数字全换成 8、月/日按两位"预留，所以逐日推进
  纸框不抖；横向吃紧时先整体降字号（18/14 → 14/11），降到地板仍不够就让纸框变宽，
  不再出现"第1年 · 1月…"这种裁字。
- 列表物资/职业图标 32px，档案章节图标 28px，事实/指标图标 24px。
- 顶栏国库/人口纸签同样按实测字宽定宽（Row 留白 + 图标 + 段间距 + 读数），读数
  变长时纸签变宽而不是压字。hover 在纸签下方弹出一张纸片卡：国库页给当日「收入
  构成 / 支出构成」两条构成条与净额，人口页给职业构成条与逐职业的满意度、生活档
  （只列人口最多的前几项，其余并成「其他职业」）。卡宽固定 400，高度由内容撑开，
  贴到视口边缘时自动收进视口或翻到纸签上方；整张卡 `mouse_filter = IGNORE`，不抢
  地图点击，也不打断纸签的 hover。点击纸签直接进入「国家经济 · 总览 / 阶层民生」。
- 悬浮卡的投影走 `shaders/ui/ideology_paper_shadow.gdshader`（padding 12 / softness 8
  / 15% 深褐）：比纸面小一圈、边缘是渐变而不是 StyleBoxFlat 的硬边。别再用第二张
  纸片纹理当阴影——撕边叠撕边会看成"铺了两层纸"。
- 金额一律「金币纸贴 + 数字」（`MoneyDisplay`）：玩家文案里不再出现 `¥` / `元` /
  「货币单位」，构成条的图例与合计由 `DossierStackedBar.set_segments(..., money_icon)`
  统一画同一枚金币，避免一段带符号、一段不带。
- 科技加入/移出按钮使用大图标，悬停提供完整操作说明，点击范围同步扩大。
- 窄 KPI 卡优先呈现图标和关键读数，完整标签与解释在 tooltip 中提供。
- 科技队列与发展目标按两行排版；条件、事实和建造配方按实际内容换行并保留滚动。
- `ConstructionOptionRow` 根据自由布局子树的实际最小高度同步外层 Button 高度。
- 继续保留每日补丁更新、节点复用、迷雾门控和点击命令路径。

## 验证入口

- `tests/ui/player_top_bar_fit_test.gd`：顶栏日历块的字宽、纸框边缘余量与逐日稳定性。
- `tests/ui/hud_status_card_test.gd`：国库/人口悬浮卡的收支构成、职业行、金额只画
  金币不写单位、出卡位置与翻转、卡片不参与命中测试。
- `tests/ui/ui_font_readability_test.gd`：真实粗细字体输出、主题字面与中文字符覆盖。
- `tests/ui/inspector_responsive_layout_test.gd`：档案列与详情列的响应式宽度。
- `tests/ui/paper_aux_visual_qa.gd`：纸片注释、换行、标签与节点稳定性。
- `tests/technology/technology_workspace_smoke_test.gd`：研究交互、队列复用、布局及刷新预算。
- `tools/preview_ui_readability.gd`：复用回归数据，渲染地理/人口/市场/建筑档案。
- `tests/qa/technology_workspace_screenshot_qa.gd`：真实开局研究流程和科技工作区截图。

截图保存在仓库 `artifacts/ui-readability/`。正式科技路径另外验收 2560×1392，
与用户提供的窗口尺寸一致。

旧 `inspector_live_patch_test` 的加载页中心与进度断言在 HEAD 基线中也失败：
基线卡片中心相距 226px，阶段进度为 62，而旧断言要求 65。
本次不修改该加载页的布局/进度语义；档案交互和稳定性断言均通过。
