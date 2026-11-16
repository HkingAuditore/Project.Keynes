# 易用性 / 交互 / 动效

## 1. 焦点与键盘（最高频系统缺陷）

**唯一合法的 `FOCUS_NONE` 边界**：地图覆盖层模式按钮（`MapOverlayToolbar._mode_buttons`、`map_overlay_icon_button.tscn`）。`tests/game/player_map_overlay_smoke_test.gd:171-184` 与 `player_controller_contract_test.gd:134` 明确断言这些按钮必须 `FOCUS_NONE`，原因是持有焦点的普通 Control 会吞掉地图滚轮 / 拖拽手势（`player_controller.gd:979`）。

**这条约束不可外推**。实测 25 个 `.tscn`（58 行）+ 18 个脚本（28 行）逐处写入 `FOCUS_NONE`，其中绝大部分只是照抄沿用，本可正常聚焦。约 1/3 屏幕做对了（`grab_focus()` + `focus_neighbor`），说明不是能力缺失而是推广不均。

规则：
- 每个屏幕打开时 `grab_focus()` 到某个控件；定义 focus neighbor 或用可靠的自动邻居。
- 鼠标与焦点共存；切换输入设备不能把玩家晾在空焦点上。
- 需要保留地图手势时，用独立 InputMap 动作 / 焦点代理 / 过滤特定 focus owner，不要整层关掉焦点。
- `category_tab_button.tscn:11` 已显式 `focus_mode = 2`；`icon_button.gd` 全文不碰 `focus_mode`——基础按钮场景不是焦点缺失的源头，别去改它们。

## 2. 屏幕栈与导航

- 用 push/pop 栈管理界面，输入与可见性交给栈顶。禁止布尔标志堆叠：实测全库 741 处 `visible = true/false`，`game_ui_manager.gd` 的 `dismiss_overlay_menu()` 是 12 分支硬编码关闭链，多层叠加后无法全部关闭、STOP 遮罩残留吞点击。
- ESC / 返回语义全局一致。反例：`technology_workspace.gd:406` 整个可见期 `accept_event()` 吞掉按键（既关不掉也开不了暂停菜单），理念工作台只关内部弹层，其余交给全局关闭链——相邻工作台三套语义。
- 关闭后回到原地图位置与缩放；面板开关、选中 tab、选中地块、滚动位置在切界面后保持。
- 有后果的操作（宣战 / 营造 / 派遣 / 重置税率）要确认、可撤销、有当前状态回显与禁用原因。
- 新游戏参数要持久化：反例 `game_flow_service.gd:112` 返回即重建主菜单，`main_menu.gd:202` 种子重新随机、整套表单回默认。
- 首帧必须有「现在该做什么」的引导。`world_clock.gd:41,110` 默认 `auto_start=true / paused=false`，1× 下 1 现实秒 = 1 游戏天，而暂停态只藏在 hover tooltip。

## 3. 事件驱动与性能

- HUD 订阅信号（`health_changed` / `score_changed` / 每日提交），不在 `_process` 每帧读游戏状态刷新。
- **规范硬约束**：每日 tick 不重建右侧检视器节点树，只低频更新内部数据缓存；内容只在选中地块或切换 tab 时重建。快进时按钮不能被销毁重建、滚动位置不能跳。
- 实测仍违例：`game_ui_manager.gd` 的 `notify_committed_day():363-396` 每日扇出到子组件触发全量重建（`market_list.gd:12-14`、`inspector_panel.gd:423-424`）；fog 状态变化（`:775`）与 `selection_context` 变化（`:802`）仍走 `refresh_selected_panel()` 的 `remove_child + queue_free` 整棵重建。
- `world_runtime_host.gd` 的 `capture_economy_day_inputs(-1)` 返回值被丢弃之类的静默丢数据，要单独查。
- 触控目标 ≥44dp；实测被主动下调到 34/28/26dp。
- 鼠标过滤：纯装饰的全屏 Control 设 `MOUSE_FILTER_IGNORE`，否则吞掉地图点击。`hud_status_card.tscn:240` 写着「点击查看国家经济 · 总览」但 `hud_status_card.gd:50-52` 把包括页脚在内的全部子节点设成 IGNORE 且无任何点击处理——**假 CTA**。

## 4. 状态完备

每个可交互控件必须覆盖：normal / hover / pressed / active / toggled / disabled / selected / focus / empty / loading / error / cooldown 中适用的全部状态。

真实反例：
- `annual_reader_view.gd:171-172`（及 `:586-587`）`for state in ["font_color","font_pressed_color","font_focus_color","font_hover_pressed_color"]` 循环体内却硬编码 `add_theme_color_override("font_color", ...)` —— 4 个状态色只写了 1 个，pressed / focus 无文字色反馈。**循环里必须用循环变量**。
- `investment_page.gd:52-55`、`strata_page.gd:88-90` 在 `model.ok == false` 时静默 `return`，页面既无空态也无原因，还保留旧数据；同族 4 个 page 都走 `_show_empty(..., reason)`。
- `era_advancement_panel.gd:686-688` 在 `ok=false` 时只画一行「数据暂不可用」就 return，右栏整块不建，无原因 / 重试 / 去设置入口。
- `research_budget_notice.gd` 国家购买关闭态下 `daily_research_budget()` 归零、文案写「已关闭」，但大数字仍显示 30% 且染赭红——视觉与语义矛盾。
- 关键信息不得只在 hover tooltip（触屏 / 键盘 / 手柄无等价入口）。

## 5. 动效参数

| 类别 | 值 |
|---|---|
| Fast | 0.10–0.14s |
| Medium | 0.16–0.22s |
| Slow | 0.24–0.32s |
| 面板开 | 边缘滑入 + 淡入 0→1，ease-out，160–220ms |
| 面板关 | 轻微滑出 + 淡出，ease-in，120–160ms |
| 数值 | tween 到新值；高频 tick 不逐帧动文字 |
| 阈值脉冲 | 只在跨过有意义阈值时（风险等级、趋势翻号、天气转暴雨） |

实现约束：
- 统一走 `UIAnimation`。它的面板开合实现本身合规（0.18s / 0.12s，CUBIC / EASE_OUT / EASE_IN），问题在**纪律**：全库 `create_tween` 82 行 / 36 文件，扣掉库自身仍有 **72 行 / 35 文件绕过**；走库仅 68 行 / 25 文件。
- 14 个公开 API 里 **13 个不检查 `reduced_motion()`**，减弱动效全靠调用方自觉。新增 API 必须内置检查。
- 69 个面板 / 弹窗 / 工作区类脚本**仅 8 个有开合动效**；暂停菜单、对象详情、军事档案全是 `visible` 硬切。
- `UIAnimation.pulse()` 全库仅 2 个调用方，阈值脉冲基本未实现。
- 禁止无限循环 tween（`set_loops` / `loop`）、常驻闪烁、与暂停 / 快进冲突的动画。`era_ascension_ceremony.gd:97` 用 `PROCESS_MODE_ALWAYS` 逐帧播 6–8s 且与暂停冲突。
- 高速模拟时禁止整段内容滑入 / 淡出 / 交叉淡化。
- 两套动效体系要合并：`dossier/` 下 20+ 图表有生长 + `ANIM_MED` 补间，预算 / 滑块 / 自绘行等 6 类数值控件只有 `queue_redraw()` 瞬时跳变。
- `ui_audio_feedback.gd` 要与视觉状态 / `reduced_motion()` / 暂停态同步，不能各走各的。

## 6. 验收自查

- [ ] 每个屏幕打开有焦点；非覆盖层控件没有 `FOCUS_NONE`？
- [ ] ESC 在相邻工作台语义一致，没有 `accept_event()` 整期吞键？
- [ ] 每日 tick / 快进时按钮不被重建、滚动位置不跳？
- [ ] 空数据、全 0、极大值、禁用态下界面不空白、不裁切、不留旧数据？
- [ ] 触控目标 ≥44dp？装饰层 `MOUSE_FILTER_IGNORE`？
- [ ] 所有循环写入的状态 key 用的是循环变量？
- [ ] 动效走 `UIAnimation`、时长在表内、API 查 `reduced_motion()`、无无限循环？
- [ ] 关掉动效后界面仍完整可用（shader / 缩放 / 揭示动画全部摘除）？
