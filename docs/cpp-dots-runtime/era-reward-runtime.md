# 配置化时代三选一奖励

时代奖励不是独立 Runtime。`TechnologyCatalog` 只声明里程碑到奖励池的映射；
`EraRewardCatalog` 编译 11 个池、每池 9 个候选（其中 3 个无条件保底）以及资格、
Q16 权重规则、目标选择器和 Effect 模板。目录验证拒绝重复 ID、未知引用、
`Top-N` 超过 32、单候选展开上界超过 128、非国家目标的保底项和未注册 Effect。
奖励目录参与 Technology、Effect 与 Modifier 的 catalog identity。

里程碑研究进度达到成本时只进入 Country pending。只有其科技 Effect/Modifier ACK
并正式写入 completed bit 后，Country 才通知 Effect Offer Planner。Planner 只响应由
正式 `PlayerController` 显式绑定的玩家 country handle；它在边界上冻结 Country 状态、
国库、科研与研究信号摘要，过滤候选并使用
`(world_seed, country stable ID, pool ID, offer_generation)` 派生的 SplitMix64 纯整数
加权无放回抽取三项。普通候选不足时仅从三个保底项补齐。候选 ID、显示理由、
generation-safe 目标、权重与 plan hash 一经生成不再变化。

普通候选权重除原有现金、领土和科研状态外，还读取 `SIGNAL_PRESENT` 与
`ROUTE_COMPLETED` 规则：已发现的资源、河谷/海岸/高原/干旱等环境证据，以及已完成科技的
`route.*` 前缀都会产生稳定的权重增量和玩家可见理由。规则只改变三选一出现概率，不绕过
科技研究条件或直接授予科技。

玩家唯一入口是：

```text
era_reward.choose { offer_generation, choice_index }
```

`PlayerController` 在分配统一 sequence 前验证正式会话、玩家国家、Offer 代际和
`choice_index=0..2`。Effect 将选中备选转换为一个事务，复用既有整体 preflight、
幂等键、逐域提交和 ACK；未选中的两个备选永不执行。状态机为
`OPEN -> SELECTED_PENDING -> RESOLVED`，拒绝、目标代际失效或 resync 进入不可跳过的
`ERROR`。重复点击和旧 generation 都返回稳定拒绝。

全屏 `EraRewardDialog` 位于 `ModalLayer`。Offer 打开时保存原速度与运行状态并暂停
`WorldClock`，PlayerController 拒绝除选择以外的玩家命令。点击后三个按钮全部禁用，
通过现有 `advance_save_boundary()` 在不推进日期的情况下逐帧排空共享安全边界；全部
ACK 后才关闭弹窗，并按打开前状态恢复运行或继续暂停。`player_view` 保存锁定、恢复
意图、速度和 generation，读档后会重新挂载同一冻结 Offer。

科技工作台的「当前时代」仅取已生效（state=5）里程碑所属时代中的最高项，初始显示
石器时代。跨时代普通科技可按既有研究条件先行掌握，但不推进这个标签；待生效里程碑
同样不推进标签，避免把科技所属时代误显示为已经晋升。

## Worker 权威（ACTIVE）路径

- **Offer 打开**：Country worker 提交里程碑激活后，Host 在提交点排队
  `NOTIFY_ERA_REWARD`（`poll_country_worker_notification`）；主线程
  `service_country_worker_peer_adapter` 以该次提交的 Country 快照作为 Planner 的
  Country 视图交付通知。未交付的通知计入 drain-idle 判定。
  Host 与 PlayerController 都将 `notified > 0` 视为展示刷新事件，即使 `inspected=0`
  也立即同步奖励弹窗；空服务报告不触发 Offer 轮询。
- **选择提交**：EFFECT worker 权威时主线程 `EffectRuntime` 只是只读副本，不派发事务。
  `choose_era_reward` 改为 Host 提交：Offer 进入 `SELECTED_PENDING` 且
  `transaction_id=0`，选中备选的 Modifier 命令（仅支持 `MODIFIER_COMMAND` APPLY）
  以 `UNIQUE_SOURCE` 提交给 worker Modifier，字段为 producer 200、ENTITY 作用域、
  `source_type='ERAR'`、`source_id=offer_generation`。批次带
  `unbound_input_generation=true`，命令不受环境代次的陈旧检查约束。
- **ACK 判定**：读取 Host 最新发布的 Modifier POD 快照。主线程 legacy
  `ModifierRuntime` 在 worker 模式下不是活副本，不能用来判定。所有命令的唯一来源条目
  都存在时进入 `RESOLVED`。提交后两个已提交日内未落地就重提，最多三次，之后进入
  `ERROR(era_reward_modifier_commit_missing)`；重复提交由 `UNIQUE_SOURCE` 保证幂等。
- **时钟**：worker Modifier 命令只在模拟日落地，所以 `era_reward_offer()` 返回
  `settles_on_day_advance=true`。PlayerController 在该状态下以 1 倍速推进日期，其余
  玩家命令仍被锁定，`RESOLVED` 后恢复打开前的速度与运行状态。`era_reward.choose`
  成功后总会延迟同步一次 Offer，不依赖弹窗回调。时代奖励锁持有期间，家族立族锁不接管
  时钟，并继承时代奖励锁保存的恢复状态。
- **持久化**：PKEF 接受 `status=2, transaction_id=0`（要求 `selected_choice` 为
  0..2）。读档后 Host 会话计数清零并重新提交，`UNIQUE_SOURCE` 保证不会重复叠加。
  Country 查询副本会镜像主线程的 `era_reward_reference`，使副本捕获的 PKCN 与 PKEF
  跨段审计一致。
- **已知限制**：里程碑已经完成的旧存档不会补发 Offer；`NOTIFY_ECONOMY_MILESTONE`
  （家族祖训）在 worker 模式下尚未投递。

持久化采用精确版本：PKCN v11 保存 `{plan_id, offer_generation, milestone, status}`；
PKEF v10 保存完整三备选、理由、冻结目标、plan hash、选择和 pending 事务。恢复固定先
PKCN 后 PKEF，PKEF 逐字段审计 PKCN 引用；任何旧 schema 或目录差异返回
`catalog_hash_mismatch`，不迁移也不补发历史奖励。

当前正式 99 项内容使用 Country Modifier 白名单路径，六个状态化主题分别覆盖粮食、
制造、科研追赶、贸易、建设与社会组织，三个保底为国家组织、广域科研与生产动员。
主收益从早期约 12% 递增到终局约 25%，代价从约 6% 递增到约 12%。

验证入口：`era_reward_catalog_test.gd`、`era_reward_runtime_test.gd`、
`era_reward_ui_smoke_test.gd`、`player_controller_contract_test.gd`，以及 Technology、
Effect、Modifier、Country 与完整 PKSV round-trip 测试。
`era_reward_notification_regression_test.gd` 覆盖当前时代的里程碑判定、仅通知帧的
Host→PlayerController→真实弹窗链路，以及 50 倍速暂停与恢复意图保存。
