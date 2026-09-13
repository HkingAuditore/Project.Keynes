# NativeSimulationHost 线程边界

本文记录后台模拟线程隔离的当前实现边界。它描述的是已经落到代码里的契约，不表示
所有游戏领域已经迁移完成。

## 当前状态

`DCWorldExt` 持有唯一的 `NativeSimulationHost`。Godot 主线程只通过
`world_ext_simulation_host.cpp` 做参数校验、PackedArray 深拷贝和轻量轮询；worker 不保存
`Object`、`Variant`、`Dictionary`、`MapData` 或场景树引用。

当前 `implemented_domain_mask()` 为 `CLIMATE | COUNTRY | TRIGGER_INPUT | IDEOLOGY | MODIFIER | EFFECT | ECONOMY | EVENTS | COMMIT = 0xB7E`（Economy Phase 2–6）。整图 `required` 仍是 `0xFFF`，`missing_domain_mask = 0x481`。因此：

- `SHADOW` 可以启动，用于时钟、命令排序、环境快照、提交环和故障路径测试；
- `ACTIVE` 在缺少任一 native POD domain handler 时直接返回
  `runtime_native_domains_incomplete`，不会以“假 ACTIVE”运行；
- 生产 Country 在 `runtime_climate_authority_enabled` 下由 Host worker 负责，主线程消费 immutable
  read-view；关闭开关、启动失败或未取得 Country grant 时回退同步 `NativeCountryRuntime`；
- D7 Country–Economy 事务仍有同步 Economy-owned coordinator 作为生产回退；Host 已有内存
  request/result transport 与独立 `D7T1` transaction journal，Economy-owned fiscal peer
  journal 也已在 PKEC v52 持久化。当前只有 fiscal reserve/return/collect 进入 M1 bridge
  gate；cohort、market、research、treasury 的跨帧 continuation 和逐 operation gated
  rollout 尚未完成，Economy 未加入 ACTIVE mask。
- 生产 Trigger 在同一开关下由 Host worker 负责（H7/H8），主线程 `run_trigger_daily`
  被抑制、快照回灌 legacy `TriggerRuntime`；Events（I8）只拿到 stage 位与 worker 侧
  镜像 snapshot，legacy `GameplayEventBus` journal 仍是生产消费源。
  Economy 仍需完成独立 authority/barrier。

## POD domain pipeline（当前 SHADOW）

`runtime_domain_pod.h/.cpp` 已提供独立于 Godot 的 worker ABI v3 和固定顺序
`INPUT_CAPTURE → CLIMATE → COUNTRY → TRIGGER_INPUT → IDEOLOGY → EFFECT → MODIFIER →
GAMEPLAY_EFFECT → ECONOMY → EVENTS → VISUAL → COMMIT` barrier。它包含 Climate 输入投影、
Country 研究输入、Trigger、Ideology、Effect、Modifier、Gameplay Effect、Economy、Events、
Visual、Commit 的 plan/commit 记录，
以及 worker-owned 的数值状态（温度/水分、国库、修正项、效果实例、意识形态点数、触发器
 累加器和事件 journal）。所有输出使用 numeric handle、定长 payload、ACK 和 dirty family，
 不保存 `Object`、`Variant`、`Dictionary` 或 `MapData` 指针。

`runtime_authoritative_domains.h/.cpp` 进一步提供真实迁移所需的独立 POD store aggregate，
包括 Climate、Country、Modifier、Effect、Ideology、Trigger、Economy、Events 的预分配状态、
shape/finite/CSR 校验和确定性 state hash。该 aggregate 当前只作为 worker-owned bootstrap
边界；没有通过 OFF/SHADOW 对拍的 domain 不会进入 `implemented_domain_mask`。

SHADOW 每个模拟日会执行该 pipeline 并将 `pod_completed_domain_mask`、`pod_work_units`、
`pod_intent_count`、`pod_fallback_count` 写入线程诊断；视觉 intent 不会驱动画面，旧同步
runtime 仍是权威。这样可以先做逐日 hash/工作量对拍，再逐域接入真实 state/replay/ACK，
避免用占位 domain 错误开启 ACTIVE。`runtime_domain_pod_self_test()` 覆盖全阶段完成、
有限输入、事件/研究意图和 hash 随日期推进。

### Ideology G2-G7 SHADOW stage

The SHADOW block below is the diagnostic path only. G8 ACTIVE Ideology runs from
the stage loop; see "Ideology POD ACTIVE stage (G8)".

Ideology is wired between Country and Effect. The host publishes the previous
committed Economy class-opinion snapshot, captures Country technology/research
state, and invokes the worker POD plan at the daily barrier. Worker commands
and snapshots cross the boundary as numeric copies only. Equip, unequip,
promotion, level replacement, and active progression emit deferred typed Effect
intents; the host exposes those intents and accepts only real Effect ACKs. A
missing, stale, rejected, or not-yet-returned ACK leaves the transition pending
and never becomes final ACTIVE ideology state. The synchronous ideology runtime
remains the production reference in SHADOW, and this stage does not by itself
grant authority. `implemented_domain_mask() == 0xA7E` since H7/H8/I8.

Climate 边界现在还保留一份独立的 `RuntimeClimatePodSnapshot`：温度、湿度、雪盖、
30 日 EMA、水分平衡、降水、天气强度、植被活力、anomaly 和 RNG 均为深拷贝 POD。
`snapshot_climate()`/`restore_climate()` 在 worker 内提供事务式导出/恢复；缺失字段按
零值初始化，NaN、尺寸不一致或损坏 payload 会拒绝且不改变上一份状态。该状态目前只在
SHADOW 诊断中计算，旧 weather front、ImageTexture 和 GPU 上传仍由主线程负责，因此
不会误报 Climate 已具备 ACTIVE 权威资格。

Climate SHADOW 的 reference hash 是日提交屏障：worker 先完成 plan 并比较 next-state
hash，只有 reference hash 非零且完全匹配时才执行 commit。reference 缺失或不一致会记录
`climate_reference_hash_missing` / `climate_reference_hash_mismatch`，丢弃 pending plan，
将 `climate_pod_ready` 和日 `preflight_ok` 置为 false，保留最后成功的 worker Climate
generation/day；不会把失败日发布到 commit ring，也不会自动切换另一套权威。

## 生命周期

状态转换为 `STOPPED → STARTING → RUNNING/PAUSED → SAVE_PENDING → STOPPING → STOPPED`，
任意 worker 异常进入 `FAULTED`。`request_runtime_stop()` 只写原子标志并唤醒 condition
variable。

停止请求一旦被接受，后续 `request_runtime_save()` 会立即返回
`runtime_worker_stopping`；不会再向一个即将退出的 worker 投递保存任务。
worker 创建失败也会回滚到可复用的 `STOPPED` 状态，并在诊断报告中保留
`worker_thread_create_failed` 与故障计数，避免 host 永久停在 `STARTING`。

worker 发布 `STOPPED` 后，其 `std::thread` 句柄仍可能保持 joinable。重开局/复用 host 时，
句柄移交给 detached reaper，Godot 主线程不执行 `join()`。只有 `DCWorldExt` 析构的兜底路径
会等待 worker 和 reaper 完成；这条路径不属于 UI 或输入流程。

模式在一次 host 生命周期内不可热切换。新世界必须先停止旧 host，再在下一帧确认
`STOPPED/FAULTED` 后替换 generator。

## 数据流

主线程在 `capture_runtime_inputs_for_worker()` 中从 `MapData` 读取字段并复制到
`RuntimeEnvironmentSnapshot`。发布前校验数组尺寸、邻接范围、交易 LUT 和 finite 值；旧 generation
被拒绝。worker 每个模拟日只持有该 immutable snapshot 的临时指针。

Country 快照还携带 `research_active_country_slots` 与
`research_active_index_valid`。索引由 Country native 研究热循环维护并按 slot 升序发布；
索引有效时 worker/SHADOW 探针只遍历实际有研究工作的国家，合法空索引表示当天没有研究
工作，不会退回全国家扫描。旧快照未携带标记时才使用保守全扫描兼容路径。

命令通过固定容量 4096 的 MPMC ring 入队，payload 最大 1024 字节；worker 在日边界按
`(effective_day, producer_id, sequence, request_id)` 稳定排序。拒绝也生成回执，不能静默丢弃。

提交头与视觉内容分离。权威 generation/day/hash 即使三缓冲都处于 `READING` 也会发布；视觉
快照最多 20Hz，缓冲满时只丢视觉发布并累计 `snapshot_publish_drop_count`。

线程诊断同时提供 `simulation_time_debt_days`（CSV/性能记录字段）和
`time_debt_days`（直接 host 查询别名）；两者均受 100 天上限约束。`main_wait_on_sim_us`
固定为 0，任何非零值都视为主线程隔离回归。

## 保存边界

`SAVE_REQUEST` 在完整日边界抓取 immutable `PKSR v2` bundle，包含时钟、generation/hash、
环境元数据、未到期命令和 producer sequence。bundle 通过 checksum 校验并只消费一次。
PKSV v1 容器由 `SaveRepository` 保留并标记为不兼容，加载明确返回
`save_format_version_incompatible`；不会被删除或误报为文件缺失。

PKSR v1 runtime envelope 同样明确拒绝，v2 必须携带
`runtime_domain_abi_version`、`section_mask`、pending command tail 和 producer
cursor；checksum 校验通过后才允许进入下一次 worker start。

When present, the worker ideology state is encoded as an independent `IDP1`
section with its own ABI, catalog/state hash, bounded length, and checksum.
`IDP1` is restored transactionally after worker stop and catalog/bootstrap
completion. It is never reconstructed from `PDP3` or synchronous `PKID`.

## 后续迁移顺序

1. 为每个 domain 实现 `RuntimeDayPlan` 的纯 POD calculate/replay adapter；
2. 将 Country/Economy 状态快照和 domain ACK 接入 worker-owned store；
3. 逐日 OFF/SHADOW hash、事件和回执对拍 1000 日；
4. 只有 `implemented_domain_mask == RUNTIME_ALL_DOMAIN_MASK` 且无 GDScript 权威 daily/yearly
   系统时开放 ACTIVE；
5. 最后迁移 WorldClock 展示信号和渲染 patch 预算。
# Country POD capture boundary

`capture_country_runtime_snapshot()` is a main-thread-only capture boundary. It
copies the numeric Country projection into an immutable `RuntimeCountryPodSnapshot`;
the worker never receives `NativeCountryRuntime`, `Object`, `Variant`, or
`Dictionary`. In `SHADOW`, the worker runs a read-only Country workload probe and
publishes `country_pod_*` diagnostics. The probe intentionally reports
`cross_domain_ack_adapter_missing` and does not claim Country authority. ACTIVE
remains rejected until all domain handlers and ACK barriers are native POD.

## D7 transaction journal boundary

The Host owns the transport-level `D7T1` section for Country/Economy asset traffic.
It serializes typed request/result identities, queue membership, dispatch and
commit idempotency markers, terminal results, protocol counters, and the restored
worker session rebinding. A dispatched request without a terminal result is
requeued after restore in deterministic `(day, operation_sequence,
continuation_index, request_id)` order; its old-session result is rejected and
the same transaction/request identity continues under the new session. This is
a coordination journal, not the Economy store. The M1 fiscal peer side has its
own Economy-owned journal in PKEC v52, containing terminal request
identity/result data and escrow state; its state hash participates in restore.
Restore validates both sides independently before rebinding pending requests;
it does not silently drop an unresolved transaction. Economy remains outside
the ACTIVE mask until all asset operations have peer reservation/apply
persistence, cross-frame continuation, generation reconciliation, and
long-run conservation evidence.

## Modifier POD ACTIVE stage (E8)

Modifier stage 位于 EFFECT -> MODIFIER -> ... -> COMMIT，SHADOW 与 ACTIVE 共用 `execute_modifier_worker_stage`。生产 ACTIVE（mask `0xA7E`）在 Country 之后、Climate park 日跳过对齐 Country：独立 Trigger stage → 独立 Ideology stage → 独立 Effect stage → Modifier；成功日写入 TRIGGER_INPUT/IDEOLOGY/EFFECT/MODIFIER 位。失败隔离。

grant 后：Host 为 Modifier/Effect 唯一写者；主线程抑制 modifier/effect daily；非阻塞 snapshot 回灌；非 Modifier Effect intents 主线程 pump+ACK；`main_wait_on_sim_us` 保持 0。

## Effect POD ACTIVE stage (F8)

F8 在 Ideology 之后、Modifier 之前跑独立 ACTIVE Effect stage：

1. grant `0x020` 后 submit/retire 只走 Host transport（sole-writer）。
2. Worker：drain → apply_acks → plan_day → intents → commit_day → snapshot ring。
3. MODIFIER intents 同日 Modifier stage ACK；COUNTRY/ECONOMY/GAMEPLAY 由主线程非阻塞 poll→ACK。
4. Behavior 经 EffectRuntime 注册表桥接；缺实现 hard-fail。
5. 主线程回灌 EffectRuntime；graph/SUS 抑制 evaluate+dispatch。

Report 暴露 `effect_pod_*` 与 `effect_worker_authoritative`。

## Ideology POD ACTIVE stage (G8)

G8 在 Country 之后、Effect 之前跑独立 ACTIVE Ideology stage：

1. grant `0x010` 后 `submit_ideology_commands` 只入 Host POD 队列（sole-writer），不再先改 legacy 队列。
2. Worker：drain commands/acks → plan_day/commit_day 的 same-day continuation → intents → `_ideology_snapshots` ring。
3. Ideology 的 transition intent 目标域是 EFFECT：同日 Effect ACTIVE stage 成功后由
   `ack_ideology_intents_in_worker()` 在 worker 内 ACK；主线程
   `poll_ideology_worker_intent` / `submit_ideology_worker_ack` pump 保留为协议路径，
   也覆盖只授予 IDEOLOGY 的会话。
4. Climate park 日与 Country/Effect/Modifier 一起跳过；失败隔离，不回滚当日已提交的 Climate/Country。
5. 主线程回灌 `NativeIdeologyRuntime`（`apply_runtime_ideology_snapshot`）；graph/SUS 抑制
   `run_ideology_daily` 与 `ideology_should_run`。

Report 暴露 `ideology_pod_*` 与 `ideology_worker_authoritative`。SHADOW 模式的 G7 诊断 stage 原样保留。

## Trigger POD ACTIVE stage (H7/H8)

H7/H8 在 Country 之后、Ideology 之前跑独立 ACTIVE Trigger stage
（`execute_trigger_worker_stage`）：

1. grant `0x008` 后 `submit_*` 只入 Host POD 队列（sole-writer）；`trigger_should_run`
   返回 false，`run_trigger_daily` 被抑制。
2. Worker：drain commands → 取 reference frame / catalog → `run_trigger_active_day`
   （plan + commit，用 `_trigger_acks` 里的**真实** ACK，不合成）→ intents →
   `_trigger_snapshots` ring。
3. intents 在判定成功**之前**发布：ACK barrier 未满的当日计划会被丢弃并在下次访问重放
   同一批单调 id，`_trigger_published_intent_id` 水位线负责去重。同日 Effect ACTIVE stage
   成功后由 `ack_trigger_intents_in_worker()` 在 worker 内 ACK；主线程
   `poll_trigger_worker_intent` / `submit_trigger_worker_ack` pump 保留为协议路径，
   覆盖只授予 TRIGGER 的会话。
4. Climate park 日与 Country/Ideology/Effect/Modifier 一起跳过。
5. **soft-complete**：`trigger_pod_not_configured`、`trigger_pod_not_bootstrapped`、
   `ack_barrier_incomplete`、`ack_retry`、`stale_generation`、`ack_rejected` 仍置
   TRIGGER 位，避免 Climate|Country|Effect|Modifier 的 grant 被 Trigger 扣住；
   `trigger_pod_ready` 保持 false，`trigger_pod_fallback_reason` 留诊断。硬失败仍隔离。
6. 主线程回灌 `TriggerRuntime`（`apply_runtime_trigger_snapshot`，按 generation 门控）。

Report 暴露 `trigger_pod_*` 与 `trigger_worker_authoritative`。

## Events POD ACTIVE stage (I8)

I8 的 EVENTS grant（`0x200`）**只是 worker 侧镜像 + stage 位**：POD store 拥有 EVENTS
stage 位和自己的 snapshot ring，legacy `GameplayEventBus` journal 仍是生产消费源，
主线程的 append/ACK 一条都没有抑制，POD snapshot 也不会回灌 GameplayEventBus。
`start()` 在 requested mask 含 EVENTS 时强制打开 `_events_probe_enabled`，否则该 stage
会永远 soft-complete 却从不产出 snapshot。stage 无条件 soft-complete（含空日与被拒批次），
真实结果由 `events_pod_ready` / `events_pod_fallback_reason` 承载。

Report 暴露 `events_pod_*` 与 `events_worker_authoritative`。消费者迁移是后续 PR。
