# PlayerController 命令与交互契约

## 当前入口

- 实现：`Project/project-keynes/scripts/game/player_controller.gd`
- 场景：`Project/project-keynes/scenes/player_game.tscn`
- UI 注入：`scripts/ui/game_ui_manager.gd` → `CountryPanel` → `TechnologyWorkspace`
- 存档：`scripts/game/game_save_coordinator.gd` 的 `player_view`

## 正式命令白名单

| ID | 参数 | facade 委托 | 规则 |
| --- | --- | --- | --- |
| `research.set_weights` | `weights_bp: PackedInt32Array` | `set_research_weights` | 恰好 4 项，非负，总和 10000 |
| `research.set_budget` | `enabled: bool`, `daily_cash_limit: int` | `set_research_budget` | 参数齐全，现金上限非负 |
| `research.enqueue` | `technology_id`, `domain` | `enqueue_research` | 科技 ID 非空，领域 0..3，位置由首项语义传 `-1` |
| `research.remove` | `technology_id` | `remove_research` | 科技 ID 非空 |
| `research.move` | `technology_id`, `domain`, `position` | `move_research` | 科技 ID 非空，领域 0..3，位置非负 |
| `country.tax.set_default` | `kind`, `rate_percent` | `set_tax_default` | kind 0..4，rate -100..100 |
| `country.tax.set_override` | `kind`, `item_id`, `rate_percent` | `set_tax_override` | stable item 必须属于对应目录 |
| `country.tax.clear_override` | `kind`, `item_id` | `clear_tax_override` | 只清全国细项 |
| `country.tax.cell.set_default/clear_default` | `cell`, `kind`, optional rate | cell default facade | cell 必须属于玩家领土 |
| `country.tax.cell.set_override/clear_override` | `cell`, `kind`, `item_id`, optional rate | cell override facade | stable item、所有权、范围先验证 |
| `country.tax.cell.clear_all` | `cell` | `clear_cell_tax_policy` | 恢复完整全国继承 |
| `construction.build` | `cell_idx`, `building_id`, `ownership_policy` | `treasury_sponsored_build` | 仅玩家领土；首版只接受 `treasury_sponsored_private` 且固定一栋 |

其余 `country.*`、`economy.*` 可以作为协议命名空间，但未逐项登记前必须返回
`unsupported_command`。GM、作弊、诊断和调试开关不属于这张表。

## 结果与顺序

控制器在验证正式会话、玩家国家归属和参数后才分配 sequence。有效命令：

```text
effective_day = WorldClock.day_index() + 1
sequence      = PlayerController 的单调递增整数
```

提交结果发出 `command_completed(id, result)`。成功排队返回 `code=queued`；经济边界
处理后，同一 sequence 另由 `command_settled(id, result)` 发布实际结果及
`settled_day/cash_paid/treasury_goods_used/market_goods_used`。早期失败没有可分配序号时
使用 `effective_day=-1, sequence=-1`；facade 返回的 `reason` 会归一化到
`message`，缺少 `code` 时归一化为 `ok` 或 `command_rejected`。

常见稳定 code：

- `unsupported_command`
- `runtime_unavailable`
- `session_unavailable`
- `player_country_unavailable`
- `invalid_args`
- `command_rejected`
- `construction_cell_not_owned`
- `construction_technology_locked`
- `construction_obsolete`
- `construction_conditions_failed`
- `construction_resource_unavailable`
- `construction_materials_insufficient`
- `construction_treasury_cash_insufficient`
- `construction_market_unavailable`
- `unsupported_ownership_policy`

## 输入动作

`project.godot` 中的语义动作由 `PlayerController` 统一门控：

- `player_pause`
- `player_cancel`
- `player_fit_view`
- `player_regenerate`（仅 debug）
- `player_open_gm`、`player_perf_hud`（仅 debug）
- `player_zoom_in`、`player_zoom_out`

地图鼠标、触摸、拖拽、捏合和镜头缩放由
`PlayerController → MapCamera.handle_player_input()` 转发。MapCamera 保留
帧更新，但不再接收全局输入。`_unhandled_input` 到达控制器前应经过 Godot UI
消费阶段：`LineEdit`/`TextEdit` 挡住全部地图手势；普通 `Control` 焦点只挡住
`handle_input()` 直接分发。HUD 图层/顶栏/国家栏按钮使用 `FOCUS_NONE`；空地图
指针事件会释放残留的普通 UI 焦点。

## 视图存档

`capture_view_state()` 保存 `selected_cell`、`camera_position`、`camera_zoom` 和
`next_command_sequence`。
`GameSaveCoordinator` 将其写入 PKSV 的 `player_view`，读档时在
`world_ready`、地图绑定和渲染资源完成后调用 `restore_view_state()`。无效或
缺失选中格必须清除选中态，不能留下上一场景的高亮。
