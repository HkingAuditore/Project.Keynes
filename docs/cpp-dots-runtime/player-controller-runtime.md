# PlayerController 玩家会话运行时

运河状态为 **API 已准备、尚未注册**。保留未来指令 ID
`infrastructure.canal.build`，参数仅 `quote_token`；当前 allowlist、分支、signal 连接、输入、
场景和 player_view 均不得增加该能力，被拒绝请求不得消耗 sequence。详见
[运河运行时](./canal-runtime.md)。

## 定位

`PlayerController` 是正式玩家会话的 Godot/UI 边界。它把玩家意图转换为
运行时 facade 调用，但不拥有模拟数据、DataCore slot、native SoA 或调度器。
这是一个输入和命令编排层，不是新的 simulation system，也不应被误判为
DOTS authority。

```text
Godot UI / unhandled input
        -> PlayerController
        -> WorldRuntimeHost / CountryFacade / EconomyFacade
        -> native runtime and scheduler
```

`PlayerGame` 只负责场景生命周期、会话请求、世界生成、场景切换和自动存档
完成后的流转。`MapCamera` 继续负责平滑缩放、惯性和聚焦动画；GM 控制台
继续使用独立入口，不复用正式玩家命令协议。

## 依赖绑定

`configure(camera, highlight, runtime_host, world_clock, ui_manager)` 一次性绑定
控制器依赖并连接：

- `MapCamera.tile_tapped`：转为当前地图 cell 选择；
- `WorldClock.day_changed/season_changed/year_changed`：驱动 host tick 和 UI 刷新；
- `GameUIManager` 的 pause、speed、clear-selection、菜单可见性意图；
- `CountryFacade.country_committed`：转发给 UI/vision/border 消费者。

控制器维护当前玩家国家 handle、命令 sequence、暂停菜单前的时钟状态和当前
选中 cell。国家 handle 从正式 `gameplay_start_report()` 的玩家起始格解析，
并通过 `cell_summary(...).owned` 校验归属；不会接受 UI 传入的任意 handle。

## 输入与 UI 优先

控制器实现 `_unhandled_input`，但不实现 `_process`，也不轮询 `Input`。UI
已经消费的事件不会进入世界交互。门控分两层：

- `LineEdit` / `TextEdit` 焦点会挡住 `_unhandled_input` 的全部快捷键和地图手势。
- 普通 `Control` 焦点只挡住 `handle_input()` 直接分发（`PlayerGame`、测试、嵌入工具），
  不锁死已经穿过 GUI 的地图点击、滚轮、拖拽和触摸。
- 空地图上的指针事件会 `gui_release_focus()`，清掉 HUD 按钮残留焦点。
- 地图 overlay、顶栏和国家栏按钮使用 `FOCUS_NONE`，避免点完图层后无法操作地图。

语义键位在 `project.godot` InputMap 中声明，PlayerGame 和 MapCamera 不得重新加入硬编码玩家快捷键。

## 正式命令网关

除研究写操作外，正式网关开放玩家主动建设 `construction.build`、家族开拓
`family.colonization.start/cancel`、全国税务
`country.tax.set_default/set_override/clear_override`，以及地块税务
`country.tax.cell.set_default/clear_default/set_override/clear_override/clear_all`。
控制器在分配 sequence 前校验税种、stable item ID、`[-100,100]`、cell 和玩家领土
所有权。建设命令在 sequence 分配前验证玩家领土、stable building ID 与
`treasury_sponsored_private`，但价格、库存、科技和放置规则仍在执行边界重新验证。
未知命令返回 `unsupported_command`，GM 命令永远不从这里透传。

每次调用 `request_command(id, args)` 的顺序是：

1. 静态白名单检查；
2. 正式会话和玩家国家归属检查；
3. 参数类型、范围和研究权重总和检查；
4. 分配单调 sequence；普通领域命令计算下一日 `effective_day`，需要即时抽离
   人口的家族开拓使用当前安全边界日。开拓报价在冻结周期内仍可读（`busy/nonbinding`），
   派遣/取消仍要求 committed 边界；
5. 调用领域 facade；
6. 归一化 `{ok, code, message, effective_day, sequence}` 并发射
   `command_completed`。

建设提交成功只表示 `queued`。`EconomyFacade` 在提交后的经济边界读取轻量 receipt，
控制器以同一 sequence 发射 `command_settled`；UI 据此区分排队与实际开工/失败，不能把
非锁定报价当作预留或最终成交价。

技术、国家经济和地块税务工作台只提交结构化意图，不再保存 facade、玩家句柄或自己的
命令序列。对象详情默认编辑当前地块细项；全国税率只在国家经济页编辑。地块税率
SpinBox 的草稿与次日 pending 不得被日常 live patch 回写成继承默认。

## 存档恢复

`GameSaveCoordinator.bind_runtime()` 绑定 PlayerController。保存时通过
`capture_view_state()` 写入 `player_view`；恢复时严格等待地图、derived map
资源、renderer 和 `world_ready`，再由 `restore_view_state(map, state)` 恢复
镜头和选中态，并保存 `next_command_sequence`，避免 PKCN pending 命令恢复后发生序号
冲突。无效 cell 会清除高亮和 cell panel。

## 时代纸徽与待领奖励

当前交互：纸徽默认半露；hover 只下探 28px 并放大 4.5%，约 130ms；点击才完整展开。
图标下方不再绘制时代名或晋升提示。点击打开纸片式国家概况：三列指标格显示年度 GDP、
人均 GDP、CPI、PPI、地块、人民平均满意度与人民生活水平。GDP 复用 `EconomyGdpLedger`，
货币按原生 1/10000 单位转换；价格指数、满意度与生活水平读取
`country_economy_overview(..., "summary")`；国土来自 `ui_snapshot(handle, 0)` 的国家摘要。
指标下方隔一条笺线接续国家问题：每条问题是一个 icon + 短标签，直接排在纸面上，沿用指标
格的三列对齐，不再包一层卡片或长条边框；纸贴图标保持自身彩铅配色，只用尺寸和文字传达
严重度，不叠加染色。无问题时不缩小成裸图标，而是显示一条「暂无突出问题」。
快照缺失显示破折号，不把未结算当作零。仅概况可见时合并刷新这些读数。

有待领奖励时，点击纸徽后仍由控制器暂停并保存时钟，但三选一现在是概况下方三张独立纸片，
已移除全屏暗幕与全屏卷宗。未提交可通过收起、Esc 或窗外点击关闭（窗外事件被消费）；
提交后关闭与时钟控件均受事务锁门控。ACK 移除奖励纸片，保留国家概况并恢复原时钟。
显示层 `is_era_reward_modal_open()` 保留兼容方法名，仅表示奖励选择流程打开，不代表全屏遮挡。

顶部中央 `EraIndicator` 和日历旁时代名读取玩家国家的已提交研究快照。只有时代里程碑
进入完成状态 5 才晋升；状态 4 等待 ACK 时仍停留旧时代，研究遮罩可显示 100%。
`GameUIManager` 合并每日提交、国家提交和奖励通知，最多每 100ms 刷新一次，不逐帧轮询。
新世界与读档建立显示基线；只有会话内真实晋升才播放纸徽庆祝，并让光点飞向日历旁，
抵达后更新时代名。

原生 `era_reward_offer()` 仍是候选与事务状态的唯一权威。`OPEN/ERROR` 只通知纸徽边缘
高亮，不暂停、不锁命令，也不强制弹窗。玩家点击纸徽触发 `era_reward_open_requested`，
由 `PlayerController.open_era_reward_offer()` 保存原速度/运行状态、暂停并打开三选一。
尚未选择时 Esc 触发 `era_reward_dismiss_requested`，恢复原时钟，奖励继续留待领取。
选择仍走既有 `era_reward.choose` 正式命令；`SELECTED_PENDING` 不允许取消，继续安全边界
排空或必要的单日推进，ACK 后关闭弹窗并恢复原速度/运行状态。

`player_view` 复用现有 `era_reward_*` 时钟/代际字段，不新增存档字段。
旧存档中未选择的 `OPEN/ERROR` 弹窗锁恢复为待领提醒并恢复时钟；已提交事务保持锁定直到 ACK。
回归：`tests/ui/era_indicator_ui_test.gd`、
`tests/technology/era_reward_notification_regression_test.gd`。

## 变更规则

- 新增正式命令必须先进入静态白名单，再补参数验证、facade API、结果码和契约测试。
- 不把国家/经济读模型迁移到控制器；只读 ViewModel 仍从各自 facade 快照读取。
- 不把 GM、诊断、作弊开关加入正式玩家协议。
- 改变输入动作、player_view 字段、命令序列或权威边界时，同步更新本文件、
  `runtime-authority-matrix.md`、`references/system-map.md` 和对应专项文档。

## 验证

```powershell
godot --headless --path Project/project-keynes --script tests/player_controller_contract_test.gd --quit
godot --headless --path Project/project-keynes --script tests/family_colonization_runtime_test.gd --quit
godot --headless --path Project/project-keynes --script tests/treasury_construction_runtime_test.gd --quit
godot --headless --path Project/project-keynes --script tests/technology_workspace_smoke_test.gd --quit
godot --headless --path Project/project-keynes --script tests/player_country_ui_smoke_test.gd
godot --headless --path Project/project-keynes --script tests/player_map_overlay_smoke_test.gd
$env:PK_GAME_SAVE_ROUNDTRIP_TEST = "1"
godot --headless --path Project/project-keynes
```

预期专用测试均为 `0 failures`。headless dummy renderer 的 RID/resource leak
告警是退出清理噪声，应与断言失败分开报告。

## 家族派遣只读入口（2026-10）

双入口工作区复用 `family.colonization.start/cancel`，不增加模拟命令或存档字段。
`get_family_dispatch_candidates(source_cell, offset, limit)` 校验玩家国家与源地归属后，
委托 EconomyFacade 读取当地家族分页摘要；不得先读全国家族再由 UI 隐藏外国行。
`get_family_dispatch_preview(family_handle, source_cell)` 先查到真实当地成员分支，再读取该家族的
特性与当地分支效果，并通过 Inspector 共用的只读视图模型生成 `behavior_rows`：按源城市的
科技可用位过滤建筑、商品、职业与需求；未就绪快照不回退展示全部目录。开拓/迁徙面板的
文字与标签都消费这些行，随每日预览缓存刷新。`can_family_colonize_from` 只检查合法当地来源与至少两人，路线与物资
仍在选择目的地之后由原生报价决定。`dispatch_cell_display_name` 只对本国或当前可见地块读取
聚落显示名；EconomyFacade 的 `settlement_display_name` 只补显示文本。

面板未选目的地时保存未报价的 UI 意图，不能提交 token=0；有效选点后绑定原生 token。
悬停预览与确认选择分开。GameUIManager 在派发工作区可见时始终消费地图选择，并按当前步骤
解释（未定出发城→出发城，已定→目的地），不要求先按面板按钮进入选点模式，也不打开普通
Inspector；工作区覆盖计入地图安全区，关闭恢复原来 Inspector／工具栏可见状态。
回归入口：`colonization_workbench_ui_test.gd`、`colonization_planner_context_test.gd`、
`player_controller_contract_test.gd`。原生领域权威、资金归属与 PKSV 保存顺序不变。
