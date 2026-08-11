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
已经消费的事件不会进入世界交互；控制器额外检查 viewport focus，任何
`Control` 焦点都会阻止直接分发，文本编辑状态则阻止所有快捷键、点击、拖拽、
滚轮和触摸。语义键位在 `project.godot` InputMap 中声明，PlayerGame 和
MapCamera 不得重新加入硬编码玩家快捷键。

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
   人口的家族开拓使用当前安全边界日；
5. 调用领域 facade；
6. 归一化 `{ok, code, message, effective_day, sequence}` 并发射
   `command_completed`。

建设提交成功只表示 `queued`。`EconomyFacade` 在提交后的经济边界读取轻量 receipt，
控制器以同一 sequence 发射 `command_settled`；UI 据此区分排队与实际开工/失败，不能把
非锁定报价当作预留或最终成交价。

技术、国家经济和地块税务工作台只提交结构化意图，不再保存 facade、玩家句柄或自己的
命令序列。对象详情默认编辑当前地块细项；全国税率只在国家经济页编辑。

## 存档恢复

`GameSaveCoordinator.bind_runtime()` 绑定 PlayerController。保存时通过
`capture_view_state()` 写入 `player_view`；恢复时严格等待地图、derived map
资源、renderer 和 `world_ready`，再由 `restore_view_state(map, state)` 恢复
镜头和选中态，并保存 `next_command_sequence`，避免 PKCN pending 命令恢复后发生序号
冲突。无效 cell 会清除高亮和 cell panel。

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
