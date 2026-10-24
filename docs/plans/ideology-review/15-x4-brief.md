# 15 - X4 事件叠层 + P1-E 收口（reviewer brief，2026-10-23 21:55）

队列位置：`12-r7-brief` A-G → `14-worker-managed-lifecycle` → X1-b → X5（`13`）→ **本文** → X13 → X9/X10/X12/X14。
本文依赖 14 先落地（worker 上 managed 实例要能 retire、只在输入变化时 fire、ACK 后压缩事务），否则
叠层的「层数下降」不会落到 Modifier 上。

只走 worker 路径（用户决定）。主线程 `EffectRuntime` 只要求「能读 snapshot、能报告层数」，不要求执行。

## 1. 现状事实（逐条对过代码）

- 「层」是静态展开：`ideology_runtime.cpp:1619-1621` 按 `templ.stacks` 展开成 N 个实例，
  `effect_instance_id(..., layer)` 把层号放进身份。所有层同时创建、同一个 expiry，过期后永不再生。
- 生成器已拦截：`generate_ideology_catalog.py:4641-4656` 拒绝 `ADD_STACK + duration>=0`（P1-E 的临时闸）；
  `:4749` 拒绝 `max_stacks > 6`。设计表里有 10/15/25 层的卡，这条上限要随本文改。
- Modifier 端：`modifier_runtime.cpp:1010` 把 `command.stacks` 钳到 `definition.max_stacks`；城市定义
  生成时 `stack_policy=1`、无 `max_stacks`（生成器 `:3939` 附近），所以 stacks>1 在 Modifier 层被压成 1。
  今天的多层能叠加，只是因为每层是独立 Effect 实例 → 独立 `source_id` → 独立 Modifier 行 → SUM。
- Effect POD 实例已有 `stack_count / applied_stack_count / max_stacks / expires_day`
  （`runtime_effect_pod.h:315-318`），过期处理在 `plan_day`（`runtime_effect_pod.cpp:1389`）：
  `expires_day<=day` → `active=0`，**不发 REMOVE**，靠 Modifier 自己的 `duration_days` 到期。
- 缩放通道已有：`intent.magnitude_q16 = effect_scaled_magnitude_q16(value, instance.magnitude_scale_q16)`
  （`runtime_effect_pod.cpp:1432`），X5 倍率走的就是它；MULTIPLY 在 Modifier 是 `1+(f-1)*mag`
  （`modifier_runtime.cpp:765`），所以「mag = 层数」= 每层线性叠加，正是设计表「每层 +3%」的语义。
- 事件源在代码里的位置：
  - 降雨日：`_cell_rain_event_q16`（`economy_runtime.cpp:4500` 每日写），metric 13。
  - 建筑完工：`economy_runtime_building_commit.cpp:84-93`（`pending.ready_day` 到达，`changed_cells`）。
  - 职业：metrics 51-53 只有「主导职业/份额/种类数」，**没有「上次出现日」**，新职业事件需要新列。
  - 重抽：`runtime_ideology_pod.cpp:1267`（`REROLL_OFFER`，在 ideology POD 内）。
  - 时代：`notify_era_milestone_activated`（`economy_runtime_family_buff.cpp:772`）。
- 提交尾已有不可变快照发布模式：`refresh_effect_input_digest`（`economy_runtime_publish.cpp:725`）→
  `_effect_input_snapshot`（`economy_runtime.h:6564`，`atomic_store`/`atomic_load` 一次）。

## 2. 设计决定（R 照做；有异议先报，不要自行换方案）

### D1. 一格一实例，层 = stack_count，不再按层建实例

理由：25 层 × 32 格 = 800 实例/卡级，`max_instances=4096` 放不下；且每层独立实例意味着每层一笔事务/ACK。

- 叠层 program 的实例身份**去掉层号**（`effect_instance_id(..., layer=0)`），一个 `(country, idea, program, cell)`
  只有一个实例。
- 实例的有效倍率 = `synergy_scale_q16 × live_layers`（Q16 乘法，饱和）。`live_layers==0` 时实例不 fire，
  已 applied 则走 14 的 retire。
- 不改 Modifier 的 stack 语义，不给城市定义加 `max_stacks`：层数通过 magnitude 进 Modifier，一行就够。

### D2. 层环放在 Effect POD 实例上（不是 IDP2，不是 PKID）

理由：Effect POD 是 worker 权威、已经进 EFP1 存档、已经有 expiry 逻辑；层环放这里，
Ideology 侧保持无历史状态，读档后不需要「重放事件」。

- `RuntimeEffectPodInstance` 新增：
  - `std::array<int32_t, X4_MAX_LAYERS> layer_expires_day`（或按 `max_stacks` 的定长数组；`X4_MAX_LAYERS = 32`），
    未用槽 = -1，保持按到期日升序；
  - `int32_t live_layers`；
  - `int64_t last_layer_day`（冷却用，见 D5）。
- 新输入动作：`RuntimeEffectPodLayerInput{instance_id, generation, event_day, duration_days}`，
  走与 upsert/remove **同一条有序队列**（`native_simulation_host.cpp:10528` 那套按 sequence 合并的 drain），
  不能另开队列，否则「装备→加层」顺序会乱。
- 加层：若 `live_layers < max_stacks` 追加；否则替换**最早到期**那层（设计 02 §4.4「超上限替换最早层」）。
- 每日 `plan_day`：弹出 `layer_expires_day <= day` 的层；`live_layers` 变化 → 视作「stack changed」，
  按 14 的 managed 规则发一笔更新事务（magnitude 用新层数）；变 0 → retire。没有层到期、没有新层 → 0 事务。
- 到期扫描成本：每个叠层实例只看 `layer_expires_day[0]`（升序），O(叠层实例数)，不用全局堆；
  若基准测试显示有问题再换分日桶。
- 版本：`RUNTIME_EFFECT_POD_ABI_VERSION` +1（在 14 的 3→4 之后，即 4→5；若 14 与本文同一轮做，可合并为一次 3→4）。
  EFP1 存新字段；`EffectRuntime::apply_pod_snapshot` 把 `live_layers` 带到主线程实例，供报告/UI。
  旧档 fail-closed。

### D3. 事件由 Economy 在提交尾发布，Ideology 在 refresh 阶段消费

- 新增不可变快照 `CommitEventSnapshot{uint64_t generation; int64_t commit_day; std::vector<CommitEvent> events;}`，
  `CommitEvent{uint16_t kind; int32_t country; int32_t cell; int32_t value;}`，事件按 `(kind, cell)` 排序。
  在 `refresh_effect_input_digest()` 旁边同一位置发布，同一套 `atomic_store`。
- `NativeIdeologyRuntime::step_effect_instance_refresh`（worker 模式下由 host 驱动，P1-A 已接）读一次快照；
  `generation > _commit_events_seen` 才处理。对每个事件：查「该国已装备的、订阅该 kind 的叠层 program」
  的反向索引 `kind → [(ideology, level, program)]`（configure 时建，O(1) 查），目标格满足 program 的
  选择器/过滤 tag 才入队 `LayerInput`。没有事件的日子：0 次访问（加计数器 `x4_event_visits`）。
- Ideology POD 产生的事件（重抽、替换理念）不走 Economy：POD 在 `apply_command` 里追加到自己的
  `pending_events`，随 snapshot 出来，消费路径相同。**本期只做 Economy 事件**，POD 事件随 X6 一起做。
- `_commit_events_seen` 不存档：读档后第一次 refresh 把它设为当前快照 generation（不补发）。
  这要求「读档当天的事件」在存档前已经消费——存档点在日边界、refresh 在提交后同日完成，满足；
  R 需在测试里证明（见 §4 T5）。
- 目标格有两种：`EVENT_CELL`（事件所在格，汛期农法）与 `EVENT_RING1`（事件格的 1 环邻格，弭役）。
  这是事件相对选择器，与现有 selector 12-15 不同；用 `_building_neighbors` 解析，只保留本国领土格，
  仍受 program 的过滤 tag 约束；目标格若尚无实例则创建（`live_layers=0` 的实例不进 reconcile 的
  desired 集合，否则每次 refresh 会把它当成「不该存在」退掉——reconcile 要把叠层 program 的实例
  视为由事件路径拥有，只在卸下卡时一并 retire）。

### D4. 事件种类分两批

**X4-a（本期，无需新基线列）**

| kind | 来源 | 事件条件 | 卡 |
|---|---|---|---|
| `RAIN_DAY` | `_cell_rain_event_q16` | 当日 > 0 | `monsoon_farming` |
| `BUILDING_COMPLETED` | building commit `ready_day` 到达 | 每个 pending 行一次，value=count | `corvee` |
| `ERA_CHANGED` | `notify_era_milestone_activated` | 国家级，cell=-1 | `moon_race`（另需 X10，暂存） |

**X4-b（下一期，需要 Economy 存基线，Economy schema 56→57）**

| kind | 需要的新状态 | 卡 |
|---|---|---|
| `PROFESSION_APPEARED` | 每格每职业 `last_present_day`（int32，cells × professions），提交尾更新 | `national_education`（90 天窗口） |
| `WORKER_GAINED` | 每格「产业工人+矿工」上次提交人数 | `labour_legislation` |
| 连续计时（非叠层） | 每格「主产粮作 + since_day」 | `seed_saving`（这是 streak，不是层，单列一个 `STREAK` 条件，不走层环） |

X13（洪水/预警）、X9（分家）、X10（科技完成）作为新 kind 随各自能力加入，层环不用再改。

### D5. V5 防刷：冷却写在 program 上

- program 新字段 `layer_cooldown_days`（默认 0）。加层时 `event_day - last_layer_day < cooldown` → 丢弃并计数
  `x4_layer_cooldown_drops`。
- 生成器规则：事件 kind 属于「玩家可零成本重复」白名单（重抽、替换理念、调税）时，`layer_cooldown_days` 必须 > 0，
  否则硬失败。本期 Economy 事件都不在白名单里。

### D6. 生成器 DSL 与 P1-E

```python
prog("monsoon_farming_l1",
     selector=cell(tag="cell.crop.rice"),
     on_event=OnEvent(kind="RAIN_DAY", duration_days=30, max_stacks=6, cooldown_days=0),
     cmds=[CITY("agriculture_output", per_layer=1.03)])
```

- 有 `on_event` 的 program：`stack_policy=ADD_STACK`、`duration_days` = 每层持续期、`max_stacks` ≤ 32。
- P1-E 闸改为：`ADD_STACK + duration>=0` **且没有 `on_event`** → 硬失败；有 `on_event` → 放行。
- `max_stacks > 6` 闸改为：无 `on_event` 的静态多层仍 ≤ 6；有 `on_event` 的 ≤ 32。
- `on_event` 只能用 `AVAILABLE_CAPABILITIES` 里已开的 kind：新增能力名 `X4a`（RAIN_DAY / BUILDING_COMPLETED），
  `X4b` 留到下一期。卡用 `CARD_REQUIRES` 声明，缺能力就暂存（沿用 C 已做的机制）。
- Effect 定义编译：`on_event` program 的 `kind` 与 `cooldown` 进 pod 定义与 catalog hash。

## 3. 不要做的事

- 不要在 IDP2 / PKID 里存层环（D2）。
- 不要给每层建实例（D1）。
- 不要改 Modifier 的 ADD_STACK / max_stacks 语义。
- 不要做主线程执行路径；主线程 authority 下遇到 `on_event` program 时 `configure` 报
  `effect_x4_requires_worker` 并 fail-closed。
- 不要调数值（cap、每层值按设计表照抄，平衡不在本期）。

## 4. 验收（worker，0xFFF，同 `ideology_x16_worker_test` 夹具，单进程）

新测试 `tests/ideology/ideology_worker_x4_layers_test.gd`，诊断 program 用生成器里新加的
`v7_rain_layers`（`RAIN_DAY`、duration 10、max 3、每层 +10%）；用 `set_effect_metric_override_for_test`
或测试入口直接注入事件来控制输入（注入的是输入，不是结果）。

- **T1** 第 0/3/6 天各一次事件 → 该格因子依次 1.10 / 1.20 / 1.30。
- **T2** 第 10/13/16 天依次降到 1.20 / 1.10 / 1.00；第 16 天后实例已 retire（报告里 `live_layers=0`、无 Modifier 行）。
- **T3** 3 层满时再来一次事件 → 仍是 1.30，且最早那层被替换（第 10 天不降）。
- **T4** 无事件的 30 天：`effect_pod_intent_count` 每天 0，`x4_event_visits` 每天 0，PKSR `effect_bytes` 不增长。
- **T5** 第 4 天（2 层）存档→读档→跑到第 16 天，因子序列与不读档的同一局逐日相等。
- **T6** 卸下卡 → 当天或次日因子回到 1.00（依赖 14 的 retire）。
- **T7** 生成器：`ADD_STACK + duration` 无 `on_event` 仍硬失败；`on_event` + `max_stacks=33` 硬失败；
  白名单 kind + `cooldown_days=0` 硬失败（用临时假 program 跑 `--check`，跑完恢复）。
- **T8** pod 自测：加层/满替换/到期弹出/层变 0 retire 各一条，`runtime_domain_pod_test` 与
  `runtime_worker_source_scan_test` 保持绿。
- 卡：`monsoon_farming` 已以 v0（国家级 PROFILE/LF/T 近似，生成器 `:628`）发布，改成 v1 X4 写法
  （降雨日后稻作格每层 +3%），并加一条 worker 断言；`corvee` 生成器里还没有，由 C 恢复后写
  （本文只要求 R 把 `EVENT_RING1` + `BUILDING_COMPLETED` 用诊断 program 测通）。

汇报原文：构建末行、各测试末行、T1-T6 的逐日因子序列、`cards_published` 行、ABI/schema 版本变化表。
