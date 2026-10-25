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
- 列表物资/职业图标 32px，档案章节图标 28px，事实/指标图标 24px。
- 科技加入/移出按钮使用大图标，悬停提供完整操作说明，点击范围同步扩大。
- 窄 KPI 卡优先呈现图标和关键读数，完整标签与解释在 tooltip 中提供。
- 科技队列与发展目标按两行排版；条件、事实和建造配方按实际内容换行并保留滚动。
- `ConstructionOptionRow` 根据自由布局子树的实际最小高度同步外层 Button 高度。
- 继续保留每日补丁更新、节点复用、迷雾门控和点击命令路径。

## 验证入口

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
