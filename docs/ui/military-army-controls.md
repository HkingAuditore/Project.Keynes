# 部队指挥交互

桌面战略地图上的部队档案。主要输入是鼠标与键盘，触摸可使用相同的显式按钮；
手柄可以遍历按钮与下拉框，地图选点的手柄指针未在本轮实现或验证。

## 玩家决策与布局

先回答「哪支部队、当前在做什么、能下什么令」，再读战备和后勤。
部队档案使用 520 设计像素的单页纸笺，不携带地块目录；战线档案继续使用原有分栏。
编号、位置、当前任务、任务按钮、姿态和草稿固定在上方；攻击/防御/速度、兵力、
士气、补给、军饷、编成和同格部队放入同一个垂直滚动区。

行动按钮按文字自然宽度排布，空间不足时换行。选中态、焦点与按下态沿用纸面主题；
`PKMilitaryCommandButton` 补齐浅纸面上的焦点/按下悬停墨色，避免确认键获得焦点后变成白字。
攻击、防御、速度继续平级；没有新添装饰图表或改变军事数值。

## 状态与操作

| 状态 | 反馈与下一步 |
| --- | --- |
| 浏览己方部队 | 定位、行军、区域控制、探路、停止任务、姿态；没有正在执行的任务时停止禁用 |
| 浏览其他国家部队 | 保留定位和只读战备信息，不显示指挥控件 |
| 行军选点 | 地图点击只更新路线，档案保留；显示预计天数与明确确认键 |
| 区域选点 | 选择中心，显示 1–6 格半径、覆盖格数、中心行军时间和范围高亮 |
| 探路选点 | 选择中心，显示 1–6 格半径、选格数与“完成后返回出发点”；只画范围高亮，不预览路径 |
| 探路提交 | 中心不可直达仍可提交；外军隐藏、交战禁用；成功提示次日开始规划 |
| 探路运行 | 显示已解决/总数、返程、交战中暂停、完成、受阻或无法返回；不显示 ETA |
| 目标不可达 | 撤销旧预览、禁用确认，显示原因；继续选点 |
| 确认 | 再调用同一个原生路径预览，校验快进期间的新位置/通行条件，然后提交既有命令 |
| 提交拒绝 | 保留草稿与目标，显示原因，允许改选或重试 |
| 提交接受 | 退出草稿，显示排队结果；真实任务与姿态仍读取已提交军事快照 |
| 取消 | 清除路线/区域草稿，保留部队档案 |
| 再点同一部队 | 保留档案、滚动位置与草稿 |
| 换部队、关闭详情、隐藏档案、打开国家页或暂停菜单 | 取消未提交草稿，避免隐藏状态继续吞地图点击 |

快捷键：M 行军、C 区域控制、E 探路、X 停止任务；目标可用后确认键获得焦点，Enter 确认；
右键/Esc 取消草稿，再按 Esc 返回地块档案。文本输入与弹出菜单保留自己的输入优先级。
半径同时支持可点击的增减按钮，不要求玩家输入格数。

探路状态只读快照计数，文案固定为：

```text
探路 12/31
探路 12/31 · 返程中
探路暂停 · 交战中
探路完成 · 已返回
探查结束 · 3 格无法探明 · 已返回
探路完成 · 无法返回 · 原地待命
```

取消后的任务显示“待命”，不伪装成活动任务；无探路任务不渲染空占位。

## 数据与命令契约

`MilitaryCore` 继续拥有所有军事实体、任务与路径。`MilitaryViewModel.army_dossier()`
只从已有 `facade.army()` 组装 `own / stance / mission_text / actions`。
`PlayerController` 的 `_military_order_*` 仅保存会话输入草稿，不存档、不驱动每日模拟。

```text
MilitaryDossier.action_requested
  → InspectorPanel.military_dossier_action_requested
  → GameUIManager（动作路由、反馈、面板生命周期）
  → PlayerController.begin / click / radius / confirm / cancel
      → MilitaryFacade.preview_path（仅 move/area 的预览及确认前重验）
      → request_command（army.move / area_control / explore / stop / stance）
  → update_military_arm_order → InspectorPanel → MilitaryDossier.set_order_state
```

探路草稿**不调用** `preview_path()`，只由中心 + 半径生成 `cells`；提交参数为
`{army, cell, cells, radius}`，`cells` 升序去重且 1..256。中心不可直达不是失败条件。
地图重复点同一格不再提交命令。move/area 确认前原生预览失败时禁止提交；命令被拒绝时不清空草稿。
半径变化重新生成预览/高亮区域，最多沿用既有 256 格上限。
同格名录跟随渲染快照中的部队当前位置；每日补丁只写值，不改变节点数、焦点或草稿。
打开档案时先取消旧位移动画并完成布局，再刷新静止坐标、播放入场，避免动画把收窄后的
面板送回旧坐标而裁掉右缘。

指挥区现在用语义纸贴图标配短标签：定位、行军、控区、停止、执行、返回均保留 44px
以上热区和键盘焦点链；完整后果说明放在 tooltip，地图上不再堆成长句按钮。档案打开时
优先把焦点落到可执行的第一个动作，外军档案则落到定位。

## 验证（2026-11-10）

使用 Windows Godot 4.6.2、D3D12 Forward Mobile 与 v14 debug/release DLL。

- `tests/military/military_dossier_test.gd`：0 failures；覆盖探路按钮、半径标签、确认文案、
  焦点链、`E/Enter/Esc/右键`、外军隐藏、交战禁用、无 ETA、同身份节点稳定、状态文案。
- `tests/military/military_auto_exploration_test.gd`：0 failures；覆盖草稿不调用
  `preview_path()`、中心不可直达仍 ready、256 格上限、命令参数与取消。
- `tests/qa/military_dossier_screenshot_qa.gd`：0 failures；1280、1920、520px 窄栏、21:9
  四种布局，浏览/探路草稿/active/paused/completed/blocked 与战线，本次生成 28 PNG。
  输出 `Project/project-keynes/tmp/military_dossier_qa/`。
- headless editor import 无 Parse/Script Error；存档契约 0 violations。
- 渲染退出仍有 FMOD 未连接调试器与资源释放警告；截图脚本退出码仍为 0。
- 未完成真实战局长时间运行、手柄地图指针或触摸真机验收。
