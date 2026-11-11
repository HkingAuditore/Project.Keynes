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

顶部中央 `EraIndicator` 和日历旁时代名读取玩家国家的已提交研究快照。纸徽挂在 `HUDLayer`，
与日期栏同级：打开国家卷宗、检视面板或暂停菜单时会被遮罩盖住。只有时代里程碑
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
  `docs/architecture/current-state.md`、`references/system-map.md` 和对应专项文档。

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

## 玩家国家叙事事件系统（Narrative Event System）

`PlayerController` 挂载 `NarrativeEventService`、`NarrativeEventFlow` 与异步 `NarrativeAiClient`：
- 正式命令白名单包含 `narrative.choose`，校验 `(offer_id, offer_generation, option_index)` 后，通过确定性 Q16 权重掷骰决出命中的 `NarrativeOutcome`，并由 `NarrativeEffectAdapter` 在下一安全边界提交 `ModifierFacade`（单城/全国属性修正）或 `EconomyFacade`/`CountryFacade` 守恒命令。
- 弹窗开启时复用 `AnnualReportFlow` 同款时钟锁（保存原速度与暂停态并同步 Worker 暂停），与 `EraReward`、`FamilyFounding`、`AnnualReport` 互斥排队。
- 持久化通过 `GameSaveCoordinator` 的可选兼容 provider `pknr`（`PKNarrativeRuntime v1`）与 `player_view.narrative_event_view` 完成存读档恢复。

文字与图片服务使用独立密钥，由 `narrative_ai_credentials.gd` 管理文件读写。
缺少图片密钥时不会复用文字密钥。设置页保存空字段会清除该密钥；环境变量
`PK_AI_LLM_API_KEY` / `PK_AI_IMAGE_API_KEY` 只为尚未保存的字段提供初始值。
凭据回归测试使用独立文件及虚构密钥，不发送网络请求。

AI 生成配置的入口在**游戏设置**：暂停菜单（顶栏齿轮）→ 设置 → AI 生成设置
（`pause_menu.gd::_show_ai_settings`，自动化见 `tests/ui/pause_menu_ai_settings_test.gd`）。
事件弹窗与史册面板不再提供入口，玩家在没有任何事件时也能配置模型与密钥。

### 弹窗节奏（Pacing，2026-11）

旧节奏约为「每 8 天一次弹窗」（x5 速度下约 1.6 秒），实测过密，已整体下调一个数量级。
`NarrativeEventService` 用三个常量控制，全部集中在文件头部：

| 常量 | 旧值 | 新值 | 作用 |
| --- | --- | --- | --- |
| `DEFAULT_PULSE_INTERVAL_DAYS` | 5 | 20 | 脉冲采样间隔 |
| `DEFAULT_MIN_POPUP_GAP_DAYS` | 15 | 60 | 全局弹窗间隔闸门 |
| `pulse_trigger_chance_q16` | ~60% | ~25% | 单次脉冲放行概率 |
| `ai_slot_chance_q16` | ~25% | ~4% | AI 事件预热**基础**概率（局势拉满抬到 `ai_max_chance_q16`） |

要点：
- `popup_pacing_blocked(day)` 是唯一闸门，对**脉冲采样、事实驱动、AI 生成**三条通道无条件生效，不再只在「弹窗未关闭」时才拦；`days_until_next_allowed_popup(day)` 供诊断/UI 查询。
- 脉冲顺序改为「闸门先掷、候选后采」：闸门只依赖 `(day, 首都格)`，未过闸时跳过 8 格上下文采样，顺带省下大部分脉冲开销。
- 链式后续与 `SCHEDULE_FOLLOWUP_EVENT` 走 `enqueue_event_offer(..., bypass_gap = true)`，不受间隔限制，保证剧情链因果连续。
- 事实驱动通道即使被闸门拦下也会推进 `_last_fact_event_id` 游标，避免解冻后把积压事实一次性补弹。
- 实测节奏：1440 天（4 年）内约 10~16 次弹窗，平均 90~140 天一次（旧值约 8 天一次，约 10 倍削弱）；x5 速度下约 18~28 秒一次。
- 要再调紧/放松只改头部四个参数，不必动触发逻辑。
- 回归入口：`tests/game/narrative_event_runtime_test.gd`（内部直连 `enqueue_event_offer` 时均已传 `bypass_gap = true`，不受闸门影响）。

### AI 事件入口与时效（2026-11）

AI 事件不再只靠 20 天一次的脉冲抽签，共三个入口，全部收在
`NarrativeEventService` 的同一条请求出口 `_request_ai_generation()`：

| 入口 | 触发条件 | 基础概率 |
| --- | --- | --- |
| 脉冲预热 | 过了脉冲闸门与 AI 节流 | `ai_slot_chance_q16`（4%） |
| 事实驱动 | `GameplayEventBus` 事实类型命中 `AI_FACT_HINTS` | `ai_fact_chance_q16`（20%） |
| 状态探针 | 持续状态成立且维持 `dwell_days` | 不掷骰，按节流放行（见下节） |
| 定时后续预取 | 定时事件带 `ai_prompt_hint` 且无 event id | 不掷骰，按节流放行 |

要点：

- **事实白名单**：`AI_FACT_HINTS` 覆盖天气锋面、营造完工、商队抵达、民生压力、科研线索、地貌发现、技术采纳（3/6/7/8/9/10/13）与军事事实 40–45；未列出的类型（视觉脏标记、epoch 提交、天气观测等）不触发 AI。军事事实的 `cell = -1` 由 `_resolve_valid_player_cell()` 兜到首都格。
- **局势加权**：`situation_pressure_score()` 把即时快照折成 0..100（紧缺 ≤30、价格溢价 ≤25、满意度缺口 ≤25、极端气温 ≤20、积雪 ≤10），`_ai_chance_q16()` 在 `[基础概率, ai_max_chance_q16=40%]` 间线性抬升。掷骰仍只依赖 `(world_seed, day, country, cell, salt)`，同一节流状态下存读档不会换结果。
- **节流**：两条硬闸门 —— `ai_min_request_gap_days`（默认 60 游戏日，与弹窗间隔同档）与 `AI_MAX_IN_FLIGHT = 1`。一次战争或一次饥荒最多换来一条请求，不会刷出十几条 LLM 调用，也不会挤占静态事件的展示预算。
- **请求/回执事务**：`_request_ai_generation()` 分配 `ai_request_seq` 并登记 `_pending_ai_requests`；控制器只把回执与到达日转给 `accept_ai_generation()`，由服务层判时效、判归属、走 `enqueue_event_offer()` 的全局闸门与年度额度。
- **时效**：快照在请求日采样，回执超过 `ai_max_staleness_days`（默认 60 游戏日，x5 速度下约 12 现实秒，正好覆盖一次 LLM 往返）按 `ai_result_stale` 丢弃；落地时重新采样地块上下文，只有 `body_text` 仍出自请求日。读档会清空在途请求，迟到响应按 `ai_request_unknown` 丢弃；`_prune_expired()` 同时回收迟迟不回的登记项，避免永久占住在途名额。
- **持久化**：`pknr` 增补可选字段 `last_ai_request_day` / `next_ai_request_seq`，旧档按默认值恢复，`SCHEMA_VERSION` 仍为 1；`_pending_ai_requests` 不跨存档。
- **提示词**：事实入口通过 `fact_hint` 注入「本次触发事实」段，AI 被要求直接回应这条事实，而不是另起场景。
- 回归入口：`tests/game/narrative_event_runtime_test.gd` 覆盖事实即时触发、超时丢弃、读档丢弃、到达日重新采样与局势评分区间。

### 状态探针与 AI 事件池（2026-11）

事实是一次性的，状态是持续处境。状态探针让 AI 按「长期局势」预写事件，并把写好的稿子缓存到状态再次出现时才用：

- **定义**：`NarrativeStateProbe`（`state_id` / `display_name` / `prompt_hint` / `dwell_days` / `cooldown_days` / `conditions`）。首批三条见 `narrative_state_probe_catalog.gd`：粮食紧缺（粮价比 ≥ 1.35）、民生不满（满意度 ≤ 0.45）、连旱（湿度 ≤ 0.28 且气温 ≥ 28）。条件只能是 `NarrativeCondition` 支持的算子，**AI 不参与状态定义**。
- **判定**：`_poll_state_probes()` 每 `state_probe_interval_days`（默认 7 日）在最多 8 个领土地块上求值；已入状态的格子强制继续采样，避免随机抽样打断 dwell 计数。`situation_pressure_score()` 之外的 `_state_tracking` 记录 `since_day`、期间最高价格比、期间最低满意度。
- **预取**：`dwell_days` 满足、无同状态在途请求、且过了 `cooldown_days` 才发一次请求，`state_hint` 把状态、持续天数与期间极值写进 prompt 的「当前长期状态」段。
- **池化**：回执在 `accept_ai_generation()` 里用引擎条件复核「到达这一刻」的状态。成立 → 正常入队；不成立或闸门/年度额度拦住 → `_stash_pooled_event()` 进池，返回 `ai_event_pooled`（不是失败）。
- **出池**：`_flush_ai_pool()` 每天在弹窗闸门打开时尝试（每次最多 4 条，避免热路径采样），状态成立才 `enqueue_event_offer()`；池子上限 24 条、每状态 2 条、TTL 730 日，读档保留（`pknr` 可选字段 `ai_event_pool` / `next_pool_id` / `state_tracking` / `state_last_seed`）。
- **文案不写读数**：状态事件会被缓存数月，因此 `title` / `body_text` / 选项 / 结果标题只写处境与后果，不写气温、价格、库存、人口、百分比、日期等读数（prompt 第 5 条）。数字本身不是禁忌：「三人」「三成」「第 3 条」照常写。validator 只做一件无损修补：把 `34.2℃` / `34.2 °C` 改写成 `{temperature}`，由引擎在入队时填充当前气温；`custom_label` 例外，仍写「对象 + 幅度 + 时长」。
- 回归入口：`tests/game/narrative_event_runtime_test.gd` 覆盖 dwell 未满不请求、状态破裂入池、同状态复现出池（不再耗 API）、每状态 2 条上限、池子存读档、温度读数改写为占位符与「不写读数」规则入 prompt。

### 事件文案规范（2026-11）

事件 UI 只放可决策的信息，不写场景描写与修辞：

- 标题 `地点·事件`；题头只放日历 `第 N 年 · M 月 D 日`，不再堆聚落、地貌与气温（地名在标题里，气温属读数）。
  `NarrativeEventService` 在入队时按发生日算好 `date_text`，弹窗与史册共用；无 `WorldClock` 时退回 `第 N 日`。
- 正文 ≤ 2 短句，只写触发条件与影响。
- 叙事文本不写数据读数：气温、价格、库存、人口、百分比、金额、日期天数一律不写，需要指代气温时用 `{temperature}` 占位符（状态事件会缓存复用，读数必然过期）。叙述用的泛指数量照常写（三人、数十户、三成）。这条靠 prompt 约束；validator 只把 `34.2℃` 这类温度读数改写成 `{temperature}`，不删句子。
- 选项 = 动作（4-12 字）；`tooltip_hint` 留空，界面不显示重复说明。
- 结果只有标题 + 效果行；`outcome_narrative` 不再渲染，AI 也不再生成。
- 效果行统一「对象 + 幅度 + 时长」，如 `本地农业产出 +15%，90 日`；`NarrativeEffectSpec.describe()` 是唯一兜底。
- 分类标签不再上题头（`气候` / `干旱` / `农业` 这类信息由标题与正文承担）；题头右侧只保留 `定位` / `记录` 两个动作，AI 事件额外挂一枚「AI 生成」纸签。
- `NarrativeAiPromptBuilder` 要求模型按同一规范输出，`NarrativeAiValidator` 对正文做 160 字截断兜底。

## Clock control and modal regression coverage (2026-11-04)

PlayerController changes WorldClock and displays its state. Native clock synchronization
belongs to the session-owned `runtime_clock_binding.gd`, which subscribes directly to
`WorldClock.control_changed`; `sync_ui()` is no longer a native-control operation.
The country UI soak handles narrative choices through the player command and outcome
acknowledgement, then reopens country affairs. A narrative pause is an expected user
interaction, not evidence of a worker stall. Scroll preservation is checked with a
nonzero position in a compact viewport after layout settles.
