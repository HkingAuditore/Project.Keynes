# Project.Keynes 全域权威运行时重构状态报告

更新时间：2026-09-05

## 1. 文档目的

本文总结 Project.Keynes 从当前 GDScript/同步 daily 权威迁移到纯 C++ POD worker 权威的整体进展。

本文严格区分三种状态：

1. **基础设施已完成**：协议、队列、快照、错误状态等已经具备并经过测试。
2. **SHADOW 诊断已存在**：代码可以在独立 worker-owned POD store 中运行，用于测量和对拍，但尚未成为真实权威。
3. **生产权威迁移已完成**：只有完成逐日确定性对拍、保存恢复、线程隔离和性能门禁后，才能归入此类。

当前不能把第二类描述为第三类。

## 2. 最终目标

最终运行时必须形成以下边界：

```text
主线程输入捕获
    ↓
immutable native input snapshot
    ↓
worker-owned POD state
    ↓
固定顺序 plan/replay
    ↓
typed intent / ACK barrier
    ↓
immutable committed snapshot
    ↓
主线程视觉和 UI 消费
```

最终要求：

- worker 不调用任何 Godot API；
- worker 不访问 MapData、场景树、renderer、GPU 或 Godot 对象；
- 主线程不读取 worker store；
- 主线程不等待 simulation、mutex、任务或保存编码；
- OFF 是同步参考权威；
- SHADOW 是后台对拍权威，不驱动画面；
- ACTIVE 只能在所有 domain、保存恢复、对拍、审计和性能门禁全部通过后开放；
- 权威模拟不跳过日期；
- 50 倍速目标为 50 个权威模拟日/秒；
- worker 停顿不造成 UI 帧尖峰。

## 3. 当前硬状态

当前必须继续保持：

```text
simulation_thread_mode = OFF / SHADOW
domain_pod_mode        = SHADOW
graph_coverage_state   = partial
implemented_domain_mask = COMMIT (0x800)
ACTIVE                 = 禁止
```

当前真实权威仍然是：

```text
WorldClock._process()
→ day_changed
→ WorldRuntimeHost.run_daily_tick()
→ 同步 SUS/native daily graph
```

`RuntimeDomainAuthorityRunner`、Climate POD、Country POD 都不能改变这一事实。

## 4. 已完成的基础设施

### 4.1 Runtime Domain ABI v3

已经完成并保留：

- Runtime Domain ABI 升级到 v3；
- stage 数量固定为 12；
- `CLIMATE` 与 `TRIGGER_INPUT` 已拆为不同 bit；
- `RUNTIME_ALL_DOMAIN_MASK == 0xFFF`；
- stage 顺序固定为：

```text
INPUT_CAPTURE
→ CLIMATE
→ COUNTRY
→ TRIGGER_INPUT
→ IDEOLOGY
→ EFFECT
→ MODIFIER
→ GAMEPLAY_EFFECT
→ ECONOMY
→ EVENTS
→ VISUAL
→ COMMIT
```

- `COMMIT` 是目前唯一允许进入 `implemented_domain_mask` 的 bit；
- ACTIVE gate 会拒绝不完整的 mask；
- ABI 不匹配必须在 worker 启动前拒绝。

### 4.2 公共运行时协议

已经建立统一的运行时数据边界，包含：

```text
RuntimeDayInput
RuntimeDomainPlan
RuntimeDomainCommit
RuntimeDomainIntent
RuntimeDomainAck
RuntimeDomainReport
RuntimeDomainSnapshot
RuntimeDomainSaveSection
```

公共 header 已包含：

```text
domain
abi_version
day
input_generation
base_generation
dirty_families
state_hash
work_units
intent_count
ack_count
preflight_ok
fallback_reason
```

### 4.3 命令与回执队列

已固定：

```text
command queue = 4096
receipt queue = 8192
```

命令排序键固定为：

```text
effective_day
→ producer_id
→ sequence
→ request_id
```

队列满不阻塞、不静默丢弃，必须返回：

```text
command_queue_capacity_exceeded
receipt_queue_capacity_exceeded
```

### 4.4 Snapshot ring

三缓冲 snapshot ring 已存在，状态为：

```text
FREE
→ WRITING
→ READY
→ READING
→ FREE
```

已经覆盖：

- READY 不覆盖 READING；
- 没有 FREE buffer 时只丢视觉发布，不丢模拟状态；
- generation 过期 patch 可以被丢弃；
- snapshot publish drop 可记录；
- 主线程不得等待 worker。

### 4.5 Worker 生命周期与时间债务

已有：

- worker state/faulted 状态；
- STOP、PAUSE、SPEED、SAVE 控制消息；
- condition variable 唤醒路径；
- 时间债务上限 100 天；
- worker fault 保留最后成功 snapshot；
- fallback reason 不允许静默丢失。

## 5. 输入边界和 Climate trace

### 5.1 Native input snapshot

已扩展 `RuntimeEnvironmentSnapshot`/native environment snapshot，覆盖：

- cell 温度、湿度、植物可用水；
- 降水、积雪、天气强度；
- 邻接 CSR；
- terrain、landform、vegetation、cover、water；
- 河流、运河与水量；
- trade passability 和 move cost；
- visibility；
- building resource reserve/extra；
- topology generation；
- vision revision；
- input generation 和 day。

### 5.2 输入验证

已有验证覆盖：

- 数组长度必须与 `cell_count` 一致；
- 浮点字段必须 finite；
- CSR offsets 单调递增；
- CSR 末值必须等于 indices 长度；
- 邻接索引必须在合法范围内；
- hydro parent 必须合法；
- trade cost 不得为非法负值；
- generation 必须递增；
- 输入 day 不得早于最后 committed day；
- topology generation 变化时必须重新捕获拓扑数据。

### 5.3 Climate trace barrier

已实现固定状态：

```text
CAPTURED
→ REFERENCE_READY
→ CONSUMABLE
→ CONSUMED
```

关键行为已经固定：

- worker 不能只拿实时 MapData 推进；
- 没有 OFF reference 时不能推进 SHADOW Climate day；
- trace 缺失时返回明确 fallback reason；
- trace ring 满时返回 `climate_trace_capacity_exceeded`；
- trace frame 携带输入 hash、reference state hash、day 和环境快照；
- trace 的容量和顺序有 self-test。

## 6. Climate 当前实现状态

### 6.1 已完成内容

已经存在：

- `RuntimeClimateStore` 初版；
- `RuntimeClimateKernel`；
- `RuntimeClimateAuthority`；
- Climate plan/replay/commit 边界；
- Climate snapshot；
- Climate save/restore 初版；
- Climate state hash；
- Climate reference hash 比较；
- Climate plan/replay timing；
- Climate parity compared/matched/mismatch count；
- Climate parity day/stage/cell/generation/trace hash 字段；
- Climate 共享公式文件：

```text
runtime_climate_formulas.h
runtime_climate_formulas.cpp
```

- 生产 graph 和 shadow kernel 已开始共用 Climate helper；
- Climate self-test 和 trace self-test 已存在。

### 6.2 当前仍不是生产权威的原因

Climate 目前仍不能加入 `implemented_domain_mask`，原因是：

1. 尚未完成真实生产同步图与 worker 的 1000 日逐字段 bit-identical 对拍；
2. 当前 parity 主要是 state hash 比较，完整 field/cell 首差异 payload 仍需补齐；
3. 尚未完成 60×40 和 100×64 两种地图的完整固定 trace 验收；
4. 尚未完成所有异常天气、河流、运河、海冰、跨年和 topology revision 场景的稳定报告；
5. 尚未完成 Climate save/restore 后继续 1000 日的全量对拍；
6. 当前 worker 结果仍只用于 SHADOW 诊断，不驱动画面。

### 6.3 Climate 需要补齐的工作

需要继续完成：

- OFF reference runner；
- 固定 seed/map/catalog/config 的 trace 生成器；
- reference payload 或版本化 delta；
- stage hash；
- field/cell 级首次差异；
- reference/worker bit pattern；
- 60×40、100×64 1000 日对拍；
- Climate CLM2 section 完整 roundtrip；
- restore 后继续 1000 日对拍；
- 无 fallback、无 fatal、无 ledger failure 的 gate 报告。

## 7. Country 当前实现状态

### 7.1 已完成内容

已经存在 `RuntimeCountryPodAuthority`，覆盖：

- country handle/identity；
- generation；
- treasury；
- territory CSR；
- technology bitset；
- prerequisite CSR；
- discovery/frontier；
- research queue；
- research weights；
- technology completion；
- stable command ordering；
- stale generation 校验；
- ACK 状态；
- Country snapshot；
- CPD2 save/restore；
- Country self-test；
- GDExtension capture binding。

### 7.2 尚未完成内容

Country 尚未成为 Host 的真实 COUNTRY authority：

- 尚未完整接入 `NativeSimulationHost` daily stage；
- 尚未替代同步 Country daily；
- 尚未完成 Country 1000 日 OFF/SHADOW parity；
- 尚未完成 Country 与 Economy/Modifier/Effect 的真实 ACK barrier；
- 尚未完成正式 Country save section；
- 尚未证明研究变化不会触发 territory sync；
- 尚未允许增加 COUNTRY bit。

## 8. 全域诊断 runner 当前状态

`RuntimeDomainAuthorityRunner` 已新增并接入 SHADOW 诊断流程，覆盖：

```text
INPUT_CAPTURE
CLIMATE
COUNTRY
TRIGGER_INPUT
IDEOLOGY
EFFECT
MODIFIER
GAMEPLAY_EFFECT
ECONOMY
EVENTS
VISUAL
COMMIT
```

它目前可以：

- 运行预分配 scratch plan；
- 生成 typed intent；
- 生成 ACK；
- 执行稳定排序；
- 处理 Trigger distinct/dedupe；
- 处理 Ideology deterministic RNG/transition；
- 处理 Effect due/Modifier intent；
- 处理 Modifier expiry；
- 进行 Economy 基础守恒诊断；
- 进行 Events stable journal ordering；
- 输出 stage report、hash、work units、timing 和 fallback。

但它明确不是 authority：

```cpp
capability_mask() == 0
```

它不能替代各 domain 的真实算法，也不能用于开启 ACTIVE。

## 9. 已完成的测试和构建验证

已经验证通过的基础测试包括：

- ABI/protocol guard；
- runtime domain POD test；
- Climate authority self-test；
- Climate trace self-test；
- Country POD test；
- snapshot ring test；
- save domain section test；
- worker source scan；
- thread isolation test；
- RuntimeDomainAuthorityRunner standalone self-test；
- 关键 C++ 文件 MSVC C++17 单文件编译。

Debug/Release DLL 曾成功构建过，构建产物位于：

```text
Project/project-keynes/addons/dots_ext/bin/windows/
```

需要注意：最近新增 parity report 字段后，必须重新执行完整 GDExtension Debug/Release 构建和 headless suite，不能只依赖旧 DLL。

## 10. 尚未完成的 domain 清单

### Modifier

尚需实现真实：

- catalog；
- target generation；
- expiry heap；
- stack policy；
- bucket revision；
- cache invalidation；
- snapshot/save/restore；
- ACK 输出；
- 1000 日 parity。

### Effect

尚需实现真实：

- effect catalog；
- effect instance lifecycle；
- idempotency；
- duration/expiry；
- typed intent；
- required/received ACK mask；
- retry/reject/retire；
- stale target；
- save/restore；
- 1000 日 parity。

### Ideology

尚需实现真实：

- support/exclusion/synergy；
- dominant ideology；
- pending transition；
- offer generation；
- deterministic RNG；
- Effect ACK cursor；
- save/restore；
- 1000 日 parity。

### Trigger

尚需实现真实：

- window；
- distinct；
- consecutive；
- cooldown；
- dedupe；
- resync/gap；
- stable fire order；
- save/restore；
- 1000 日 parity。

### Events

尚需实现真实：

- committed journal；
- stable event IDs；
- gameplay/visual/debug separation；
- event dedupe；
- journal ordering；
- Trigger input boundary；
- save/restore；
- 1000 日 parity。

### Economy

Economy 是最大剩余迁移面，尚未完成：

- PopulationCohort；
- Family/Person；
- Settlement；
- Building/Employment；
- Production；
- Market/Inventory；
- Domestic Trade/Cargo；
- Construction/Investment；
- Fiscal Settlement；
- Treasury/Cash；
- Price State；
- Rolling Cadence；
- Economy RNG；
- population/money/goods conservation audit；
- 并行 chunk/replay 边界；
- 1000 日 parity；
- 双地图尺寸性能门禁。

## 11. Host 和主线程仍未完成的部分

### NativeSimulationHost

当前 Host 已能运行诊断链，但尚未做到所有 domain 的真实 ownership：

- Country/Modifier/Effect/Ideology/Trigger/Economy/Events 仍未完整接管；
- ACK barrier 目前不是全域生产 barrier；
- global committed state hash 还不是完整 authority hash；
- save bundle 还未包含所有 domain section；
- worker snapshot 仍不能作为正式画面权威。

### WorldClock

WorldClock 仍保留同步日期推进和 daily authority。

以下逻辑还没有清退：

```text
主线程 daily 推进
run_daily_tick()
同步 SUS daily
权威 year rollover
Climate anomaly 的同步写入
```

在所有 domain parity 和 save/restore 完成之前，不应清退这些逻辑。

### WorldRuntimeHost

`_process()` 尚未完全变为纯 snapshot consumer。

最终需要做到：

- 只 poll 最新 commit；
- 只应用 dirty family patch；
- 不驱动 daily simulation；
- 不访问 worker store；
- 不等待 worker；
- 不让兼容信号触发权威逻辑。

## 12. 存档当前状态

已经有部分 domain save section 和 Climate/Country 独立 save/restore 骨架。

但完整 PKSR v2 尚未完成。最终必须包含：

```text
simulation_runtime
climate
country
modifier
effect
ideology
trigger
economy
events
```

每个 section 必须包含：

```text
section ABI
committed day
generation
catalog hash
state hash
payload size
payload checksum
payload
```

必须完成：

- PKSV v1 明确拒绝；
- PKSR v2 roundtrip；
- 单 section 损坏整体拒绝；
- checksum 错误整体拒绝；
- catalog/map shape 不匹配整体拒绝；
- restore 后继续 1000 日 parity；
- 保存不暂停玩家原有运行状态；
- 主线程只写临时文件和最终文件，不读取 worker store。

## 13. 三缓冲视觉和 UI 隔离

snapshot ring 基础设施已存在，但完整 family consumer 尚未完成。

尚需独立实现：

```text
CLOCK
COUNTRY_STATE
COUNTRY_TERRITORY
COUNTRY_VISUAL_ERA
CLIMATE_FIELDS
WEATHER
ECONOMY_UI
EVENTS
OVERLAY
```

必须实现：

- dirty ratio 小于 25% 使用 sparse patch；
- 达到 25% 使用完整 staging array；
- staging 完成后一次性替换；
- 每个 family 每帧最多上传一次；
- 旧 generation patch 丢弃；
- 无 FREE buffer 时只丢视觉发布；
- UI 不读取 worker store；
- 交互期间 patch budget 不超过 0.25ms；
- 普通帧 patch budget 不超过 0.75ms；
- snapshot staleness 不超过 100ms；
- `main_wait_on_sim_us == 0`。

## 14. 性能和线程隔离差距

当前已有基础 timing/report 字段，但尚未完成最终验收。

最终报告必须同时展示：

```text
simulation compute
plan
replay
ACK barrier
snapshot publish
visual apply
GPU upload
time debt
command queue depth
receipt queue depth
snapshot publish drop
fallback count
snapshot staleness
main_wait_on_sim_us
```

目标：

```text
无限速诊断能力 >= 65 天/秒
50 倍速持续 10 分钟 = 49–51 天/秒
country_daily P95 <= 2ms
country_daily max <= 4ms
steady full_flush_count = 0
research territory sync = 0
UI frame P99 <= 16.7ms
input feedback P99 <= 50ms
snapshot staleness <= 100ms
visual patch P99 <= 1ms
main_wait_on_sim_us = 0
ledger_failures = 0
fatal = false
```

必须测试：

- worker 人为停顿 100ms；
- 连续拖拽 30 秒；
- resize/zoom；
- queue full；
- receipt full；
- snapshot buffer full；
- trace ring full；
- worker exception；
- pause/resume；
- speed change；
- 连续 100 次启停；
- 返回菜单；
- 重新开局。

## 15. 距离最终目标的主要差距

按影响排序：

### 第一优先级：证明 Climate 能力

- 固定输入 trace；
- OFF reference runner；
- 1000 日逐日 hash；
- field/cell 首差异；
- save/restore 后继续对拍。

### 第二优先级：Country 真实接入

- Host COUNTRY stage；
- command/ACK/save；
- Country 1000 日 parity。

### 第三优先级：完成跨 domain gameplay 链

```text
Modifier
→ Effect
→ Ideology
→ Trigger
→ Events
```

### 第四优先级：Economy

Economy 需要独立的字段矩阵、并行边界、守恒审计和完整 parity。

### 第五优先级：完整保存恢复

没有全域 restore，就不能清退同步 authority。

### 第六优先级：主线程权威清退

只有所有 domain 通过后才能迁移 WorldClock 和 WorldRuntimeHost。

### 第七优先级：视觉隔离和 ACTIVE

最后才允许：

- 全域 snapshot consumer；
- 完整 UI patch budget；
- ACTIVE gate 验证；
- Windows ACTIVE 默认。

## 16. 下一步具体执行顺序

### 工作包 A：重新构建和验证 parity report

1. 用成功的 SCons/VS 环境重建 Debug/Release DLL；
2. 运行 source scan；
3. 运行 ABI、trace、Climate、snapshot、save、thread isolation tests；
4. 确认新增 parity 字段可从 Godot Dictionary 读取；
5. 保存构建日志和测试日志。

### 工作包 B：Climate reference/worker 1000 日 harness

1. 固定 map/config/catalog/seed；
2. 生成 2048 日 trace；
3. 运行 1000 日 OFF reference；
4. 逐日写 reference frame；
5. 运行 SHADOW worker；
6. 逐日比较 hash；
7. 首次差异写入 JSON/CSV；
8. 两张地图各运行 5 次；
9. 加入跨季、跨年、天气和 topology 场景。

### 工作包 C：Climate promotion gate

只有以下条件全部满足才考虑增加 CLIMATE bit：

```text
1000 日逐日 parity
save/restore parity
fallback_count = 0
fatal = false
source scan = 0
worker 不访问 Godot 类型
main_wait_on_sim_us = 0
```

否则保持 `COMMIT` mask。

### 工作包 D：Country Host 接入

在 Climate 通过后：

1. 将 Country authority 接入 Host；
2. 完整接入 Country command queue；
3. 接入 Country ACK；
4. 增加 Country save section；
5. 做 1000 日 parity；
6. 仅通过后再增加 COUNTRY bit。

## 17. 最终完成判定

只有以下条件全部满足，才算达到最终目标：

```text
implemented_domain_mask == 0xFFF
graph_coverage_state == complete
remaining_gdscript_simulation_authority == empty
save_codec_complete == true
shadow_parity_passed == true
fatal == false
ledger_failures == 0
main_wait_on_sim_us == 0
UI/frame/performance gates passed
```

在此之前，任何“ACTIVE 已完成”“worker 已经是完整权威”“Climate/Country 已经生产替代”的表述都不准确。

## 18. 结论

当前项目已经从单纯的线程边界和协议外壳，推进到具备 immutable input、trace barrier、POD store、plan/replay、ACK、snapshot、save skeleton 和统一 shadow diagnostics 的阶段。

最重要的剩余工作不是再增加诊断字段，而是用固定输入完成可复现的 1000 日逐日证明，并把每个 domain 从“诊断实现”逐一推进为“拥有真实状态、真实命令、真实 ACK、真实保存恢复和真实对拍证据的 worker authority”。

因此当前最合理的策略是：先完成 Climate 证明，再完成 Country 接入，然后逐 domain 扩大 mask，最后才清退 WorldClock 和同步 daily authority。

## 19. 文件与模块责任映射

下表用于工程交接。文件存在不代表该模块已经具备生产 authority。

| 模块 | 主要文件 | 当前责任 | 当前状态 |
|---|---|---|---|
| ABI/协议 | `gdext/src/runtime_pod_protocol.h` | domain ID、stage、header、report、队列容量 | 基础设施已完成 |
| Worker Host | `gdext/src/native_simulation_host.h/.cpp` | worker 生命周期、时间债务、输入、trace、诊断 stage | 已接入 SHADOW 诊断 |
| 输入快照 | `gdext/src/runtime_environment_snapshot.*`、`world_ext_simulation_host.cpp` | Godot → immutable native copy | 已有校验，仍需完整 trace harness |
| Climate trace | `gdext/src/runtime_climate_trace.h` | reference barrier、ring、消费顺序 | 已完成基础协议 |
| Climate kernel | `gdext/src/runtime_climate_kernel.*` | Climate plan/replay/store/hash | SHADOW/probe，未证明等价 |
| Climate authority | `gdext/src/runtime_climate_authority.*` | Climate store、commit、save/restore | 初版已存在，未提升 mask |
| Climate 公式 | `gdext/src/runtime_climate_formulas.*` | 共享公式 helper | 已建立，需继续逐公式核对 |
| Country authority | `gdext/src/runtime_country_pod.*` | Country POD、CSR、研究、领土 | adapter/self-test 已完成，未接管 Host |
| 全域诊断 | `gdext/src/runtime_domain_authorities.*` | 12-stage shadow 诊断 | 诊断专用，`capability_mask=0` |
| Report bridge | `gdext/src/world_ext_simulation_host.cpp`、`world_ext_runtime_graph.cpp` | C++ report → Godot Dictionary | 已扩展字段 |
| GDScript host | `scripts/game/world_runtime_host.gd` | daily authority、snapshot/UI orchestration | 仍保留同步权威 |
| WorldClock | `scripts/game/world_clock.gd` | 日期和 daily 驱动 | 仍是主线程权威 |
| Perf recorder | `scripts/ui/perf_recorder.gd` | 指标 CSV | 已有基础字段，需加入 parity 明细 |

## 20. 全域 domain 状态矩阵

| Domain | POD store | plan/replay | 命令 | ACK | snapshot | save/restore | 1000 日 parity | Host authority | mask |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| COMMIT | 是 | 是 | 基础 | 基础 | 是 | 部分 | 未完成 | 仅协议 | 已加入 |
| CLIMATE | 初版 | 部分 | trace 输入 | 部分 | 是 | CLM2 初版 | 未完成 | SHADOW | 未加入 |
| COUNTRY | 是 | 是 | 是 | 部分 | 是 | CPD2 初版 | 未完成 | 未接入 | 未加入 |
| MODIFIER | store/诊断 | 诊断 | 未完成 | 诊断 | 诊断 | 未完成 | 未完成 | 未接入 | 未加入 |
| EFFECT | store/诊断 | 诊断 | 未完成 | 诊断 | 诊断 | 未完成 | 未完成 | 未接入 | 未加入 |
| IDEOLOGY | store/诊断 | 诊断 | 未完成 | 诊断 | 诊断 | 未完成 | 未完成 | 未接入 | 未加入 |
| TRIGGER_INPUT | store/诊断 | 诊断 | 未完成 | 诊断 | 诊断 | 未完成 | 未完成 | 未接入 | 未加入 |
| ECONOMY | store/诊断 | 诊断 | 未完成 | 诊断 | 诊断 | 未完成 | 未完成 | 未接入 | 未加入 |
| EVENTS | store/诊断 | 诊断 | 诊断 | 诊断 | 诊断 | 未完成 | 未完成 | 未接入 | 未加入 |
| VISUAL | snapshot 基础 | 部分 | 不适用 | 不适用 | ring 基础 | 不适用 | 不适用 | 主线程消费未完成 | 不单独开放 |

“诊断”表示能产生测试数据，不表示与旧权威逐字段一致。

## 21. 每日数据流的当前状态和目标状态

### 当前实际路径

```text
WorldClock._process()
→ WorldRuntimeHost.run_daily_tick()
→ GDScript/native synchronous daily
→ MapData/视觉状态修改
→ day_changed/season_changed/year_changed
```

SHADOW 路径并行存在，但不驱动上述显示：

```text
主线程 capture input
→ trace CAPTURED
→ OFF reference 写 reference hash
→ trace REFERENCE_READY/CONSUMABLE
→ worker pop trace
→ Climate shadow plan/replay/compare
→ domain diagnostic runner
→ report/snapshot diagnostics
```

### 最终目标路径

```text
主线程 capture immutable input
→ worker INPUT_CAPTURE
→ Climate
→ Country
→ Trigger input
→ Ideology
→ Effect
→ Modifier
→ Gameplay Effect
→ Economy
→ Events
→ Visual snapshot
→ Commit barrier
→ 主线程 poll snapshot
→ staging/patch/UI/GPU
```

两条路径不能在同一局同时写同一份权威状态。

## 22. Climate 完整实施分解

### C0：构建收口

完成定义：

- Debug/Release DLL 使用最新源码重新构建；
- report 新字段可由 Godot 读取；
- source scan 通过；
- 所有已有 Climate self-test 通过；
- 生成 build manifest，记录编译时间、ABI、catalog hash。

证据：

```text
artifacts/climate/c0-build-debug.log
artifacts/climate/c0-build-release.log
artifacts/climate/c0-test.log
artifacts/climate/c0-manifest.json
```

### C1：固定输入生成

完成定义：

- 地图种子、尺寸、生成器版本固定；
- catalog 编译结果固定；
- 输入 generation 单调；
- topology generation 变化能形成新 frame；
- dynamic-only 更新不重复复制静态 topology；
- trace 满时不覆盖未消费 frame。

测试：

```text
长度错误
NaN/Inf
非法 CSR
非法 hydro parent
错误 catalog hash
旧 generation
day 倒退
trace ring full
topology revision
```

### C2：reference frame

每个 frame 必须至少保存：

```text
day
input_generation
topology_generation
catalog_hash
input_hash
reference_state_hash
stage_hash[14]
reference payload checksum
```

生产路径只负责写 reference，不允许修改 worker store。

### C3：worker replay

worker 每日必须执行：

```text
读取唯一 trace frame
→ preflight
→ Pass-A
→ Pass-B
→ ocean/wind
→ sea ice
→ vegetation
→ weather
→ hydrology
→ year state
→ hash
→ compare
→ matched 才 commit
```

任何失败都必须：

- discard pending lane；
- 不增加 generation；
- 不推进 committed day；
- 设置 fallback reason；
- 保留上一份成功 snapshot。

### C4：差异报告

当前已有 hash 级字段，仍需补充完整首次差异：

```text
first divergent stage
field name
cell id
reference float/int bit pattern
worker float/int bit pattern
base generation
input generation
trace hash
catalog hash
last command sequence
```

输出格式固定为 JSON，并另外生成简短 CSV 摘要。

### C5：Climate gate

必须同时通过：

```text
60×40 1000 日
100×64 1000 日
普通天气
暴雨
干旱
降雪
海冰
河流/运河
跨季
跨年
topology revision
save/restore 后继续 1000 日
```

只有 C5 全部通过，才允许把 CLIMATE 加入 mask。

## 23. Country 完整实施分解

### K0：输入和 catalog

固定：

- country catalog hash；
- technology catalog hash；
- territory CSR；
- country slot order；
- 初始 treasury；
- research weights；
- initial generation。

### K1：命令边界

主线程完成：

```text
Dictionary → typed command
handle 解析
value/range 校验
weights sum=10000
observed generation 校验
payload copy
request_id/sequence 分配
```

worker 完成：

```text
stable sort
preflight
plan
replay
receipt
ACK
```

### K2：真实 Host stage

Country stage 只能读取：

```text
上一日 Country snapshot
immutable catalog
sorted commands
上一阶段 ACK/snapshot
```

不能读取 MapData 或其他 domain 的临时 plan。

### K3：Country gate

必须证明：

- technology completion 一致；
- discovery frontier 一致；
- territory CSR 一致；
- treasury 一致；
- command receipt 一致；
- ACK 顺序一致；
- research 不触发无关 territory sync；
- CPD2 roundtrip 一致；
- 1000 日 parity 一致。

## 24. 其余 domain 的依赖关系

不能并行任意迁移，依赖关系固定如下：

```text
Country
  ↓
Modifier
  ↓
Effect
  ├──→ Ideology
  └──→ Economy
       ↓
Events
       ↓
Trigger
```

实际交付顺序仍固定为：

```text
Climate
→ Country
→ Modifier
→ Effect
→ Ideology
→ Trigger
→ Economy
→ Events
```

原因：

- Effect 需要 Country/Modifier/Ideology/Economy ACK；
- Trigger 只能消费 committed Events；
- Events 需要完整日 barrier；
- Economy 需要 Climate、Country、Modifier、Effect 的已提交 snapshot；
- Ideology 需要 Country 和 Effect ACK。

## 25. 每个 domain 的最小完成包

任何 domain 不允许只实现 store 就增加 bit。必须同时交付：

```text
catalog
store
typed command
validation
stable sort
plan
replay
intent
ACK
snapshot
state hash
save section
restore validation
unit tests
1000-day parity
fault/fallback report
performance report
```

缺任何一项都只能标记为 SHADOW 或 partial。

## 26. 测试证据目录规范

每个阶段必须写入独立目录：

```text
artifacts/runtime/<stage>/
```

至少包含：

```text
build-debug.log
build-release.log
unit-test.log
headless-test.log
source-scan.log
parity-1000d.json
parity-summary.csv
save-roundtrip.json
performance.csv
failure.log
rollback.md
mask.txt
```

`mask.txt` 必须明确记录：

```text
before_mask
after_mask
promotion_reason
fallback_reason
gate_result
```

## 27. 失败分类和处理

### 输入失败

```text
不推进当日
不修改 worker store
返回明确 input error
保留上一份 snapshot
```

### parity 失败

```text
discard pending plan
不推进 generation/day
输出首次差异
保持当前 mask
```

### ACK 失败

```text
retry/reject 按 domain 协议处理
不能静默完成 effect
不能部分提交跨 domain 事务
```

### save/restore 失败

```text
整体拒绝 restore
不污染当前 state
保留旧存档
不自动切换同步权威
```

### worker fault

```text
进入 FAULTED
保留最后成功 snapshot
记录 fault_count/fallback_reason
不自动热切换 authority
```

## 28. 当前距离最终目标的量化判断

可以确认已经完成的比例主要集中在“边界和诊断基础设施”，而不是“真实 domain authority”。

当前已完成：

```text
协议边界：高
输入校验：中高
trace barrier：中高
snapshot ring：中
命令/回执容器：中
Climate POD 外壳：中
Country POD 外壳：中
全域诊断 runner：中
```

当前仍明显不足：

```text
逐字段 1000 日 parity：未完成
全域真实 domain authority：未完成
完整 PKSR v2：未完成
WorldClock 清退：未完成
视觉/UI 完整隔离：未完成
ACTIVE gate：未通过
正式 Windows 性能验收：未完成
```

因此当前项目处于：

```text
架构和诊断基础设施阶段
→ Climate 证明阶段
→ 尚未进入全域 authority 切换阶段
```
