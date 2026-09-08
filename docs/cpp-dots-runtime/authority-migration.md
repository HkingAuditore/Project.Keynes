# 运行时权威迁移：目标、设计框架、当前状态与任务

更新时间：2026-09-08

**一句话现状**：十个 domain 里 Climate 已是生产默认权威（`implemented_domain_mask =
CLIMATE|COMMIT = 0x802`，滞后一日），Country 有完整 POD 实现但未接 Host，其余七个只有诊断级
占位。整图 ACTIVE 仍禁止，放行是**逐域**的。

---

## 如何使用这份文档

本文是这轮迁移的**总纲**：目标、框架、状态、任务四类分开，每类先总后分。它不复述架构细节，
细节在 `docs/cpp-dots-runtime/` 下的专项文档里，本文只负责给出准确的当前状态和指路。

| 你想知道 | 看 |
| --- | --- |
| 为什么做这件事、做到什么算完 | 第一部分 |
| 权威是怎么定义的、放行标准是什么 | 第二部分 |
| 某个域现在到哪一步了 | 第三部分（3.1 总表 → 3.2 逐域） |
| 接下来该做什么 | 第四部分 |
| 我要动 Climate/worker，有哪些坑 | 第五部分（**动手前必读**） |
| 某个符号在哪个文件 | 附录 A |
| 某个开关叫什么、默认值 | 附录 B |

与其他文档的关系：

- `architecture-overview.md` / `gdscript-cpp-data-bridge.md` / `scheduling-and-job-graph.md`：
  讲**架构怎么运作**，不讲迁移进度。本文引用它们。
- `runtime-authority-matrix.md`：按**系统**（climate daily / weather / ocean…）列 owner 与
  blocker，粒度比本文 3.2 的**域**更细。查具体 pass 归属看它。
- `full-authoritative-runtime-status.md`：本文的前身，**已降为历史归档**。它按时间顺序记录了
  迁移过程中每一次调查与反复，前后文互相矛盾是正常的（那是过程记录）。要考古某个决定为什么
  这么定，去那里；要知道现状，看本文。
- 各域专项文档（`native-economy-runtime.md`、`native-country-runtime.md` 等）：讲该域的业务
  实现，与它的 POD 迁移进度是两回事。

---

# 第一部分：目标

## 1.1 为什么做

把 gameplay 模拟从 GDScript/主线程同步 daily 搬到 C++ POD worker，要的是三样东西：

1. **帧延迟**：模拟不再占主线程，长节点不再表现为帧尖峰。这是玩家能直接感知的收益。
2. **吞吐**：50 倍速目标为 **50 个权威模拟日/秒**。
3. **确定性与可存档**：POD state 无 Godot 对象引用，可整份哈希、整份序列化、整份重放。

注意 1 和 2 是**两个不同的收益**，可以只拿到一个。Climate 实测就是这样：主线程 climate job
时间降 49%，但 SUS 总均值不动——CPU 总需求没变，只是换了个线程跑。搬迁只在"主线程是瓶颈"
时改善延迟，只在"有空闲核心"时改善吞吐。

## 1.2 最终边界（成功长什么样）

```text
主线程输入捕获
  → immutable native input snapshot
  → worker-owned POD state
  → 固定顺序 plan/replay
  → typed intent / ACK barrier
  → immutable committed snapshot
  → 主线程视觉和 UI 消费
```

硬约束，逐条可验证：

| 约束 | 怎么验 |
| --- | --- |
| worker 不调用任何 Godot API | 源码扫描（`source scan = 0`） |
| worker 不访问 MapData / 场景树 / renderer / GPU / Godot 对象 | 同上 |
| 主线程不读取 worker store | 代码审查 + 竞态测试 |
| 主线程不等待 simulation / mutex / 任务 / 保存编码 | `main_wait_on_sim_us = 0` |
| 权威模拟不跳过日期 | soak 的 `writeback_days` 连续性 |
| worker 停顿不造成 UI 帧尖峰 | 真实客户端会话帧统计（**目前无法测量，见 3.4**） |
| 50 权威模拟日/秒 | headless perf record |

三种模式的定位：**OFF** 是同步参考权威（也是 parity 的参照系）；**SHADOW** 是后台对拍权威，
不驱动画面；**ACTIVE** 是生产权威。

## 1.3 明确不做的

- **不追求消灭 Godot 边界对象**。WeatherFront、ImageTexture、RID、MultiMesh、atlas 上传仍在
  主线程，`graph_coverage_state=complete` 不要求消灭它们。它们是"保留边界"，不是 blocker。
- **不追求整图一次性 ACTIVE**。放行按域进行，见 2.2。
- **不追求 1000 日 bit-identical 作为放行硬指标**。理由见 2.5。

---

# 第二部分：设计框架

## 2.1 权威模型：不要用单一 "native=true" 概括

判断"某个东西是不是 DOTS 权威"要拆成七个维度分别回答。这是全套判断的基础，3.2 逐域状态也
按它组织。

| 维度 | 问题 |
| --- | --- |
| Formula authority | 哪个实现决定数值公式？其他实现是否只是 SAME_SOURCE fallback？ |
| Slot authority | 哪个 pass 写 C++ slot？slot 是否是 schema 单一字段？ |
| Stage authority | 谁持有 round active、cursor、phase lock、reset/abort？ |
| Tick authority | 谁决定本日执行哪些节点、何时提交？ |
| Visible authority | MapData、CSV、renderer 是否看到同一提交态？ |
| Object authority | WeatherFront、ImageTexture、RID、MultiMesh 由谁管理？ |
| Worker authority | 是否由 POD worker 在后台线程算、经回灌进 MapData？主线程写者是否已被抑制？ |

只有 native 同时拥有 state、slot、tick/cursor、graph report 和发布契约时，才称
DOTS-authoritative。`published_to_slot=true` 只证明该 pass 的 slot publish，**不证明**
front/LUT/GPU 可见。

Worker 权威下还要多问两层，这两层各让 Climate 栽过一次：

- **这个场有回灌写者吗？** worker 算了但没有 store 成员、也没进 writeback 的场，MapData 会
  停在世界生成值且不报错。表现是"字段冻结"，不是数值分叉。
- **主线程还有第二个写者吗？** 抑制门漏掉的写者会和回灌打架，表现为单 tick 跳变。

## 2.2 域模型与三个 mask

`RuntimeDomainId` 共 **12 个域**（`runtime_pod_protocol.h:328`），`RUNTIME_ALL_DOMAIN_MASK = 0xFFF`：

| 域 | 值 | bit | 域 | 值 | bit |
| --- | ---: | ---: | --- | ---: | ---: |
| INPUT_CAPTURE | 1 | 0x001 | GAMEPLAY_EFFECT | 8 | 0x080 |
| CLIMATE | 2 | 0x002 | ECONOMY | 9 | 0x100 |
| COUNTRY | 3 | 0x004 | EVENTS | 10 | 0x200 |
| TRIGGER_INPUT | 4 | 0x008 | VISUAL | 11 | 0x400 |
| IDEOLOGY | 5 | 0x010 | COMMIT | 12 | 0x800 |
| EFFECT | 6 | 0x020 | | | |
| MODIFIER | 7 | 0x040 | | | |

**三个 mask 是不同的东西，混淆过一次就会误判现状**：

| mask | 在哪 | 语义 | 当前值 |
| --- | --- | --- | --- |
| `implemented_domain_mask()` | **编译期 constexpr**（`native_simulation_host.h:101`） | 该域**有真实 POD handler**，不代表它是权威 | `CLIMATE|COMMIT = 0x802` |
| `authoritative_domain_mask` | 启动配置键，由 GDScript 传入（`world_runtime_host.gd:540`） | 本次会话**实际要 worker 承担权威**的域 | ACTIVE 时 `0x802` |
| `completed_domain_mask` | 每日报告 | 当天实际跑完的域 | ACTIVE 下 `COMMIT|CLIMATE` |

准入逻辑（`native_simulation_host.cpp:115`）：ACTIVE 要求
`authoritative_domain_mask & ~implemented_domain_mask() == 0` 且 `graph_coverage_complete`。
**整图 ACTIVE**（不传 `authoritative_domain_mask`）要求 `implemented == 0xFFF`，当前
`0x802 ≠ 0xFFF`，所以结构上就不可能——这是刻意的。

这三者的区别就写在 `implemented_domain_mask()` 的注释里（2026-09-08 重写；此前它说
"Climate POD handler is live in SHADOW，ACTIVE 还需要剩下十个 gameplay domain"，那是
per-domain 放行之前的语义）。

**放行是逐域的**——一个域通过就加一个 bit，其余不受影响。这是这轮迁移最重要的结构决定，它把
"十二个域全部就绪才能开 ACTIVE"的死锁拆开了。

代价是要维护混合状态，最麻烦的是**跨域读取**：主线程的域读 Climate 字段时，读到的是滞后一日
的回灌值。目前 Climate 的下游（经济的 plant water / temp30d）走 slot 冻结输入，本来就不要求
当日值，所以没暴露问题。**后续每个域放行前必须逐个确认这一点。**

## 2.3 两条执行路径

**主线程路径**（Climate 之外的全部域）：

```text
WorldClock._process() → day_changed
  → WorldRuntimeHost.run_daily_tick()
  → 同步 SUS / native daily graph
  → MapData / 视觉状态修改
```

**Worker 路径**（目前只有 Climate）：

```text
WorldClock._process() → day_changed
  → apply_runtime_climate_writeback(day N 的 worker 结果 → MapData)
  → season refresh
  → capture_runtime_inputs(day N+1 的输入)
  → 主线程该域节点被抑制门跳过
  → worker 后台算 day N+1，明天回灌
```

两条语义差异，后续每个域放行时都会再遇到一次：

- **滞后一日**：玩家在 day N+1 看到 worker 算的 day N。
- **顺序钉死**：回灌必须在主线程的同域改写（如 season refresh）之前。反过来的话，主线程那次
  写入会被次日回灌整体覆盖，且没有任何报错。

## 2.4 数据契约

四条通路，各有各的失效方式：

| 通路 | 载体 | 主要风险 |
| --- | --- | --- |
| 主线程 → worker（每日） | environment 快照 + scalars + stage knobs + static knobs | **缺失是静默的**：缺 lane 被填成等长全零，缺 knob 落到结构默认值 |
| worker → 主线程（次日） | store 字段 + snapshot 独立字段 | 没有回灌写者的场会冻结在旧值 |
| 存档 | 每域一个 section（Climate 是 CLM2，Country 是 CPD2） | 加字段进 store 会动存档格式 |
| parity | 两侧共用 `parity_hash()`，按 canonical 字段表逐字段比 | 字段表与实际 store 不同步时，比较的是子集 |

两条通用规则：

- **store 内 / store 外要分清**。需要跨天累积、需要存档的进 store；只是要让 MapData 看见的
  走 snapshot 独立字段（Climate 的 `soil_moisture` 和 pass_a 五条输出就是这么处理的），这样
  不动存档格式。
- **枚举跨边界必须给字符串**。Godot 4 的 `String()` 构造函数不接受 int，给序号会在 GDScript
  侧抛构造错误并打断整个字段收集，表现成 parity 全 0 而不是某字段分叉。

## 2.5 放行门（gate）

原定的准入清单是七条：1000 日逐日 parity、save/restore parity、`fallback_count=0`、
`fatal=false`、`source scan=0`、worker 不访问 Godot 类型、`main_wait_on_sim_us=0`。

**Climate 实际放行时改了两条，这个改动本身是框架的一部分**：

- **"1000 日逐日 parity" 降为"分叉矩阵逐条归因"**。理由是生产 round 按 stride 跑，30 日窗口
  只含约 4 个有效比较日，1000 日也只含约 130 个——加长窗口买不到多少信息量。判据换成了：
  每一条分叉都能一对一映射到某个具体原因（已知语义差 / 未实现 stage / 真实缺陷）。
- **"save/restore parity" 只做到 roundtrip 绿**，没做 restore 后继续长跑对拍。

**并且这份清单被证明不充分**：它全是 headless 指标，而 Climate 放行后在真实客户端又暴露了
四个 headless 没抓到的缺陷。**后续域放行必须补第八条：真实客户端会话下的字段录制对照。**

推荐的放行流程（Climate 走通的那条）：

```text
1. SHADOW 接线   → 每个 stage 单独接，接一个验一个（stage-days 计数）
2. 分叉矩阵归因 → 每条分叉写明原因，不允许"暂时未知"
3. ACTIVE soak  → 对着 PK_SOAK_AUTHORITY=0 的同 seed 基准读逐场 nz/mean/max
4. 回归全绿
5. 真实客户端录制对照  ← Climate 是在这一步之后才发现四个缺陷的
6. 翻默认开关
```

---

# 第三部分：当前状态

## 3.1 总表

十二个域按成熟度分四档。「诊断占位」的准确含义是：**代码能跑、能产出测试数据，但算的不是
生产公式**，多数只是把 environment 投影进 store 或递增计数器。

| 档 | 域 | 一句话 |
| --- | --- | --- |
| **A 生产权威** | CLIMATE、COMMIT | 已在 `implemented_domain_mask`，ACTIVE 下真实承担 |
| **B 实现完整未接入** | COUNTRY | POD authority 有完整 plan/commit/9 opcode/ACK/CPD2，但 host 主循环没引用它 |
| **C 诊断占位** | MODIFIER、EFFECT、IDEOLOGY、TRIGGER_INPUT、ECONOMY、EVENTS | 有 POD store，但 plan/replay 是投影或计数器 |
| **D 无 store** | GAMEPLAY_EFFECT、VISUAL、INPUT_CAPTURE | 结构上就没有可迁移的状态，或本就不该有 |

逐域 × 八维度（证据行号见 3.2）：

| 域 | POD store | plan/replay | opcode | ACK | snapshot | save | Host stage | mask |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| CLIMATE | 有 | **真实** | 定义 5 个，**无消费者** | 协议层有 | 有 | CLM2 | **ACTIVE 真 stage** | **在** |
| COMMIT | 无（barrier） | 真实 | — | — | 有 | PKSR envelope | 有 | **在** |
| COUNTRY | 有 | **真实但未接入** | 9 个已实现 | 有（grant tech 需 Effect ACK） | 有 | CPD2 | 仅 SHADOW adapter | 不在 |
| MODIFIER | 有 | 诊断 | legacy 5 | 部分 | 无 | PDP3 | 无 | 不在 |
| EFFECT | 有 | 诊断 | legacy 6 | 部分 | 无 | PDP3 | 无 | 不在 |
| IDEOLOGY | 有 | 诊断 | legacy 9 | 无 | 无 | 无独立 | 无 | 不在 |
| TRIGGER_INPUT | 有 | 诊断 | 无 POD | 部分 | 无 | PDP3 | 无 | 不在 |
| ECONOMY | 有 | 诊断 | legacy 23 | 空槽 | 无 | **无 POD section** | 无 | 不在 |
| EVENTS | 有 | 诊断 | 无 | 无 | 无 | PDP3 | 无 | 不在 |
| GAMEPLAY_EFFECT | **无** | 空转 | 无 | 无 | 无 | 无 | 无 | 不在 |
| VISUAL | 无（intent） | 诊断 | 无 | 无 | — | 无 | SHADOW 刻意不发布 | 不在 |
| INPUT_CAPTURE | 无（只读快照） | 校验 | — | — | 有 | — | 两模式均校验 | 不在 |

一条容易误读的：**「legacy N opcode」指主线程 runtime 的命令入口，不是 worker 队列**。
Economy 有 23 个 legacy opcode 不代表它的 POD 迁移进度靠前，它的 POD 侧仍是诊断投影。

## 3.2 逐域详述

### CLIMATE（A 档，生产权威）

- **store**：`RuntimeClimateStore`（`runtime_authoritative_domains.h:35`）；权威侧
  `RuntimeClimateAuthority::_store/_next`（`runtime_climate_authority.h:185`）。
- **执行**：ACTIVE 真 stage 在 `native_simulation_host.cpp:1339-1448`。round 内八个 pass 走共享
  纯内核，`albedo`/`vegetation_dynamics`/`climate_feedback`/`weather_distribute`/`weather_field`
  五个走 `climate_stage_knobs` 通道单独接线，`runtime_hydrology` 两侧都不跑。
- **save**：CLM2（marker `0x324d4c43`，`runtime_climate_authority.cpp:11`）。
- **注意**：pipeline / authority runner 里也有一份 climate，那是**诊断投影**
  （`runtime_domain_pod.cpp:255`、`runtime_domain_authorities.cpp:172` 注释写明），不是权威
  路径。对拍和排障只应看 `RuntimeClimateAuthority`。
- **悬空件**：`RuntimeClimateCommand` 定义了 5 个 opcode（`runtime_pod_protocol.h:119`），
  **全仓库只有定义处，没有任何消费代码**。

### COUNTRY（B 档，最接近就绪）

这是下一个该放行的域，因为它缺的不是实现而是接线：

- **已有**：`RuntimeCountryPodAuthority::plan_day` / `commit_day` 完整实现
  （`runtime_country_pod.cpp:1128-1244`）；`apply_command` 实现 9 个 opcode（`:846-1042`）；
  ACK 语义完整（grant tech 发 intent 并 `++required_ack_count`，`:895`；commit 校验 acks，`:1204`）；
  CPD2 存档；`encode_save` 存在（`:1257`）。
- **缺的**：`NativeSimulationHost` 主循环**没有 `_country_authority` 引用**。host 在 SHADOW 下
  只调 `RuntimeCountryPodAdapter::execute_day` 做诊断（`native_simulation_host.cpp:1450-1477`），
  且 adapter 显式标记 `ack_required=1` / `CROSS_DOMAIN_BARRIER_REQUIRED`（`runtime_country_pod.cpp:530`）。
- **两条并存的存档路径**：host 实际用 `encode_country_core_checkpoint`
  （`native_simulation_host.cpp:1978`），而 authority 自己的 `encode_save` 没被调用。接入前要
  先定这两条留哪条。
- legacy `NativeCountryRuntime` 有 20 个 opcode（`country_runtime.h:65`），POD 侧实现了 9 个，
  差额需要盘点。

### C 档六个域（诊断占位）

共同形态：有 store、有 PDP3 序列化、`stage_preflight` 返回 `domain_handler_not_migrated`
（`runtime_authoritative_domains.cpp:804`），只在 SHADOW 的 diagnostic runner 里跑。逐域差异：

| 域 | 诊断实现干了什么 | 证据 |
| --- | --- | --- |
| MODIFIER | 过期删除 / 应用 intent 到 entries | `runtime_domain_pod.cpp:437`、`runtime_domain_authorities.cpp:450` |
| EFFECT | 按 instance 调度、emit intent、synthetic ACK | `:411`、`:397` |
| IDEOLOGY | 仅 bump generation/rng；runner 做 pending_transition 排序 | `:396`、`:361` |
| TRIGGER_INPUT | 递增 accumulator、扫 events journal | `:371`、`:315` |
| ECONOMY | 从 country snapshot 复制 treasury；简化 population→production 投影 | `:471`、`:533`（注释写明"real Economy authority will replace"） |
| EVENTS | 每日 push 一条 journal | `:496`、`:584` |

**ECONOMY 额外缺一块**：PKSR bundle 里没有 ECONOMY section
（`native_simulation_host.cpp:1942-1987` 只有 ENVELOPE / DOMAIN_POD / CLIMATE / COUNTRY），
它的存档仍全在 legacy `economy_runtime_persistence_*`。

### D 档三个（无 store）

- **GAMEPLAY_EFFECT**：`RuntimeAuthoritativeDomainStores` 里没有对应成员，`run_gameplay_effect`
  只递增 generation/work_units（`runtime_domain_pod.cpp:457`）。**它是个空占位，不是待迁移项。**
- **VISUAL**：只有 `RuntimeVisualIntent` 向量。SHADOW 下**刻意不把 shadow intents 泄漏到
  visual ring**（`native_simulation_host.cpp:1318`）。
- **INPUT_CAPTURE**：只读 `RuntimeEnvironmentSnapshot`，两种模式下都只做校验。

## 3.3 测试与验收

### 怎么跑

```powershell
# 统一 runner：13 个 runtime_* + dots_completion_gate，产出 artifacts/runtime/s0-baseline/test-summary.json
tools\runtime\Invoke-RuntimeTests.ps1

# 单个测试
godot --headless --path Project/project-keynes --script res://tests/<name>.gd --quit

# Climate SHADOW 对拍
tools\runtime\run_climate_parity.ps1

# 性能录制（CLI 参数在 -- 之后，不是环境变量）
godot --headless --path Project/project-keynes --script res://tests/headless_perf_record.gd -- days=50 speed=50
```

Godot 可执行文件由 `GODOT_BIN` 环境变量或 `tools/runtime/Resolve-GodotBin.ps1` 定位。

### 关键测试

| 测试 | 覆盖 | 输出格式 |
| --- | --- | --- |
| `runtime_protocol_guard_test.gd` | ABI v3、SHADOW 启动、ACTIVE 门禁 | `%d checks, %d failures` |
| `runtime_climate_parity_test.gd` | 可比性契约（字段表、哈希、拒绝不完整输入） | 同上 |
| `climate_parity_probe.gd` | **SHADOW 对拍主力**，产出分叉矩阵 CSV | `compared_days=... matched_days=...` |
| `climate_authority_test.gd` | per-domain Climate ACTIVE 三门禁 | `%d checks, %d failures` |
| `climate_authority_soak_probe.gd` | **ACTIVE soak 主力**，NaN/写回/stage 统计 | `[soak/done] ticks=... drops=...` |
| `runtime_climate_save_roundtrip_test.gd` | CLM2 存读 | `%d checks, %d failures` |
| `runtime_worker_source_scan_test.gd` | **worker 不得依赖 Godot/MapData** | PASS 或 push_error |
| `runtime_thread_isolation_test.gd` | 线程 API、graph 不完整拒绝、三模式 | `%d checks, %d failures` |
| `native_daily_graph_order_test.gd` | 图节点顺序与 C++ 常量一致 | `PASS ... (%d checks)` |
| `runtime_country_pod_test.gd` | Country POD self-test | `%d checks, %d failures` |
| `dots_completion/dots_completion_gate.gd` | 静态门禁：巨石行数、直写 grep、flag registry | `ALL GATES PASSED` |

> 输出格式是 `checks / failures`，**没有** `passed=N failed=M` 那种格式；断言数是运行时累加的，
> 没有编译期固定总数。所以"某测试应该有 N 个断言"这种判断不成立，只能看 failures 是否为 0。

### soak 环境变量（`climate_authority_soak_probe.gd`）

| 变量 | 默认 | 变量 | 默认 |
| --- | --- | --- | --- |
| `PK_SOAK_DAYS` | 300 | `PK_SOAK_AUTHORITY` | 1（**设 0 取基准对照**） |
| `PK_SOAK_SEED` | 20260907 | `PK_SOAK_DRIVE` | serial |
| `PK_SOAK_W` / `PK_SOAK_H` | 50 / 48 | `PK_SOAK_SPEED` | 50 |
| `PK_SOAK_POP` | 100 | `PK_SOAK_FOREIGN` | 3 |
| `PK_SOAK_TRACE_DAYS` | 未设=关 | `PK_SOAK_DUMP_REPORT` | 未设=关 |

**A/B 的正确姿势**：同 seed 同尺寸跑两遍，只翻 `PK_SOAK_AUTHORITY`，对比逐场 nz/mean/max。

## 3.4 已知缺陷与限制

### Climate（已放行，带着这些限制）

| 项 | 状态 |
| --- | --- |
| stage 次序与生产不同 | worker 的 `climate_feedback` 排在 `weather`/`distribute` 前，生产是后。未重排 |
| ψ / cyclone / monsoon 未接 | 刻意留空（推进输入是风场，而 wind pass 在 round 里排在 weather 之后） |
| 量级偏差 | snow_cover nz 比对照高约 25%，moisture / WB30 偏高；VGP 均值符号与对照相反 |
| 大地图跟不上节拍 | 180x120 下 `writeback_days=30/50` |
| 小地图负收益 | 60x40 下 `sus_sim_avg` +5.5%。目前默认对所有尺寸开启，无按格数阈值 |
| C5 场景表未逐项验证 | 暴雨/干旱/降雪/河流运河/跨年/topology revision 从未单独构造 |
| `RuntimeClimateCommand` 悬空 | 5 个 opcode 定义了但无消费者 |

### 测量能力的缺口（影响所有域）

- **帧延迟收益无法测量**：headless 的 `frame_wall_ms` 恒 0，而这正是 worker 化的主要卖点。
  真实客户端会话下的帧统计从未采集过。
- **`run_ms` 在 ACTIVE 下不可直接比**：harness 每天 40ms 忙等轮询（`SceneTree -s` 下
  `_process` 不跑，回灌只能手动驱动），会淹没真实差异。

### 危险默认值

- **`simulation_thread_mode` 键缺失时，C++ 侧 raw 默认是 `"ACTIVE"`**
  （`world_ext_simulation_host.cpp:44`）。任何忘了传这个键的 harness 会静默跑成 ACTIVE。
  生产路径总是显式传，但自己写 probe 时要注意。

---

# 第四部分：任务表

按"解除阻塞的价值 / 成本"排序。每条给出**验收标准**——没有验收标准的任务不该进这张表。

## P0：补上测量能力（阻塞所有后续判断）

| # | 任务 | 为什么最优先 | 验收 |
| --- | --- | --- | --- |
| 1 | 真实客户端会话下采集帧统计 | 这是 worker 化的**主要收益**，目前完全没测过；也是历史上两次严重问题唯一暴露过的地方 | ACTIVE / OFF 各一次同 seed 会话，给出帧时间分布对比 |
| 2 | 把"客户端字段录制对照"固化成放行流程的一步 | Climate 四个缺陷全是它抓到的，而 headless 全绿 | 写成可重复的 SOP，Country 放行时首次执行 |

## P1：Country 接入（下一个域）

| # | 任务 | 前置 | 验收 |
| --- | --- | --- | --- |
| 3 | 定夺两条存档路径（`encode_country_core_checkpoint` vs `RuntimeCountryPodAuthority::encode_save`） | 无 | 单一路径，另一条删除或注明用途 |
| 4 | 盘点 legacy 20 opcode 与 POD 9 opcode 的差额 | 无 | 逐条列出：已实现 / 不需要 / 待实现 |
| 5 | 把 `RuntimeCountryPodAuthority` 接进 host 主循环 | 3、4 | ACTIVE 下 Country stage 真实执行 |
| 6 | 跨域读取确认：谁在读 Country 字段，能否接受滞后一日 | 5 | 逐个消费者确认，写进本文 2.2 |
| 7 | Country 按 2.5 的六步流程放行 | 1–6 | `implemented_domain_mask` 加 COUNTRY bit |

## P2：Climate 收尾

| # | 任务 | 验收 |
| --- | --- | --- |
| 8 | stage 重排：`feedback` 移到 `weather`/`distribute` 之后 | 与生产语义一致，soak 无回归 |
| 9 | 量级偏差归因（snow_cover +25%、moisture/WB30 偏高、VGP 符号相反） | 每条能一对一映射到原因 |
| 10 | 按格数的启用阈值（小地图负收益） | 阈值有实测依据 |
| 11 | 大地图回灌跟不上节拍 | `writeback_days` 达到 50/50 |
| 12 | ψ / cyclone / monsoon 自持推进 | 需先解决 wind pass 与 weather 的次序 |
| 13 | 清理 `RuntimeClimateCommand` 悬空定义 | 接上消费者或删除 |
| ~~14~~ | ~~修 `implemented_domain_mask()` 的过期注释~~ | 已完成（2026-09-08） |

## P3：其余域

C 档六个域的共同前置是**先决定它们是否值得迁移**。Economy 的 legacy 实现已经高度优化且有独立
worker（`economy_profile.worker_enabled`），把它搬进 POD worker 的收益需要先论证。
GAMEPLAY_EFFECT 是空占位，应确认它是否还需要存在。

---

# 第五部分：失效模式库

这一部分是这轮迁移里**每一条都对应至少一次实际走错**的教训，不是事后总结的漂亮话。动 worker
相关代码前建议整节读一遍——它们绝大多数不是 Climate 特有的。

## 5.1 归因方法

**一、归因要靠对照实验，不要靠读代码。** 代价最大的一条。`0xC0000005` 的定位：所有静态推断
都指向"双写"，方向全错，真正定位靠的是把 authority 关掉发现照样崩。冻结场那轮三次归因里两次
是读代码推出来的错误结论，唯一可靠的证据都来自双向 soak 对照。

**二、改动没有效果就回滚，不要因为"语义上更对"而保留。** 把 capture 挪到 season refresh 之后
在语义上确实更合理，但它不改变任何指标。保留它等于在代码里留一个没有依据、却改变了原有设计
约束的决策。

**三、先拿到实测再改，不要跳过验证步骤。** 上一条那次回滚正是因为跳过了这步：假设"季节信号被
capture 时点挡住"听起来自洽，直接改了执行序，零改善。同一个问题改成先静态确认
`fill_climate_round_input` 到底填不填 scalars，一次就中。

**四、争用与冻结类问题要看全场分布，单点 trace 会骗人。** `PK_CLIMATE_TRACE_CELL=1200` 显示
PAW 四十天不动，看着像全场冻结，实际那是个水域格，`IS_WATER` 分支把 PAW 清 0 是正确行为。
单个格子分不出"这个格子本来就该是这个值"和"全场都坏了"。

**五、"某个 stage 从不执行"不等于"它被漏接了"。** 先确认生产侧是否也不执行。hydrology 就是
这样：`runtime_hydrology_enabled=false` 时生产侧返回 `{}`，两侧都不跑。同理"worker 有这条
lane"不等于"生产没有"，两边都要看代码，不要靠对称性推断。

**六、平坦的场先查上游，不要逐条修。** 四条场在 worker 侧全部平坦，看着像四个独立缺陷。加一
条 `temp` 进对照就看清了：温度上限完全冻结，而温度是所有季节性的源头，下游平坦是必然的。
**顺带一条观测技巧**：温度要看极值而不是 nz/mean——全场 mean 随季节几乎不变（南北半球互相
抵消），振幅只体现在两端。

## 5.2 性能判断

**七、性能口径要先排除 harness 自身的开销。** `run_ms` 在 ACTIVE 下暴涨 3.5 倍，差值完全来自
harness 每天 40ms 的忙等轮询（`SceneTree -s` 下 `_process` 不跑，回灌只能手动驱动）。真实
客户端没有这段。同一件事的另一面：`frame_wall_ms` 在 headless 下恒 0，所以这条路径**最该看
的指标恰好测不出来**。

**八、"搬到后台线程"不等于"变快"。** 主线程 climate job 省了 49%，但 SUS 总均值不动——CPU
总需求没变，worker 与主线程抢核心。**要区分吞吐收益与延迟收益**，并且要知道自己在测哪个。
小地图上甚至是净负：固定的 capture 打包与回灌 memcpy 开销比被搬走的计算还大。

## 5.3 跨边界接线

**九、缺失是静默的，三种都是。** 缺 lane 被 `copy_f32` 填成等长全零（海冰因此每天从零冰起算，
max 恒等于当日增量上限）；缺 knob 落到结构默认值（默认值往往是个合理数字，于是表现为"物理
偏弱"而不是崩溃）；缺 comparable 字段曾被当零值哈希（会以假分叉形式浮出）。**边界解析处宁可
整份拒绝并报出缺失清单，也不要宽松填充**——一行守卫能定位的问题，宽松填充会变成要从分叉矩阵
反推的谜题。

**十、scalars 要整套传，不要逐个补。** 只补 `season_phase` 治不了病：`insol_amp` 取结构默认
0.20 而 profile 是 0.32，季节振幅还剩 62.5%。正确做法是复用生产那个构建函数，整份过边界。

**十一、门控标志的名字要说它门控什么。** `climate_own_paw` 后来同时门控了 scalars 补齐，名字
就开始误导，改成了 `climate_worker_authoritative`。它和 `own_snow_state` / `own_field_state`
是并列但不同的区分：后两者问"跨天状态谁持有"，它问"生产被抑制后，那些由生产 pass 顺带记录的
东西谁来补"。

**十二、共享 bit 的 stage 计数器会骗人。** `weather` 与 `distribute` 共用一个 stage bit，于是
"weather=15"在 weather field solve 一天没跑的情况下照样显示。诊断计数器的粒度要与接线粒度
一致，否则它会掩盖整个 stage 缺失。

## 5.4 验收

**十三、headless 全绿不等于玩家看到的是对的。** Climate 在 headless soak 字段统计全部对齐、
七项回归全绿的情况下，仍在真实客户端暴露了四个缺陷（温度振幅、日照冻结、湿度跳变、海冰不
显示）。原因是 headless 不跑 `_process`、不做视觉消费、不存档。**真实客户端录制对照是独立
的一步，不能被 soak 替代。**

**十四、单独盯过的场才算验过。** ACTIVE soak 覆盖的是"跑过的天数里碰到的情况"。暴雨、干旱、
降雪、跨年、topology revision 这些场景如果没有单独构造，就只是"可能碰到过"。

---

# 附录 A：文件地图

## 协议与 host

| 文件 | 内容 |
| --- | --- |
| `gdext/src/runtime_pod_protocol.h` | **契约单一源**：`RuntimeDomainId`（:328）、mask（:346）、stage 顺序（:353）、`RuntimeEnvironmentSnapshot`（:161）、各域命令与 ACK 结构 |
| `gdext/src/native_simulation_host.{h,cpp}` | worker 状态机、`implemented_domain_mask()`（h:101）、ACTIVE 准入（cpp:115）、day plan、save bundle（cpp:1942） |
| `gdext/src/world_ext_simulation_host.cpp` | GDScript 边界：capture 全部解析、writeback、parity 字段表、模式解析（:42） |
| `gdext/src/runtime_domain_pod.{h,cpp}` | 诊断级 POD pipeline（C 档六域都在这） |
| `gdext/src/runtime_domain_authorities.cpp` | 诊断 authority runner |
| `gdext/src/runtime_authoritative_domains.{h,cpp}` | 各域 store 定义、`stage_preflight` |

## Climate（唯一的生产权威域）

| 文件 | 内容 |
| --- | --- |
| `gdext/src/runtime_climate_authority.{h,cpp}` | **权威路径**：plan/commit、CLM2 序列化 |
| `gdext/src/runtime_climate_kernel.cpp` | worker round 编排、五个 stage_knobs stage 的守卫 |
| `gdext/src/runtime_climate_passes.{h,cpp}` | 九个 pass 的共享纯内核（生产与 worker 同一份） |
| `gdext/src/world_ext_climate.cpp` / `world_ext_weather.cpp` | 生产侧实现，**接线时的键名口径以它们为准** |
| `Project/.../scripts/geography/map_generator.gd` | capture、knobs 构建、stage 节拍 |
| `Project/.../scripts/game/world_runtime_host.gd` | worker 生命周期、模式决策（:520） |

## Country（下一个域）

`gdext/src/runtime_country_pod.{h,cpp}`（POD authority）、`gdext/src/country_runtime.{h,cpp}`
（legacy）、`gdext/src/world_ext_country.cpp`。

---

# 附录 B：开关清单

## B.1 决定权威模式的

| 开关 | 定义 | 默认 | 作用 |
| --- | --- | --- | --- |
| `runtime_climate_authority_enabled` | `world_runtime_host.gd:87` | **true** | true → 以 ACTIVE + `authoritative_domain_mask=0x802` 启动；false → SHADOW。**Climate 的总开关与回退路径** |
| `simulation_thread_mode` | 启动配置键，C++ 解析 `world_ext_simulation_host.cpp:42` | ⚠ **键缺失时 raw 默认 `"ACTIVE"`** | OFF / SHADOW / ACTIVE |
| `runtime_shadow_on_generate` | `world_runtime_host.gd:59` | true | generate 时是否启动 worker |
| `runtime_parity_forcing` | `world_runtime_host.gd:60` | false | 强制 parity 采集 |

## B.2 native daily 图（`ClimateProfile`，生产覆盖在 `earth_like.tres`）

| 开关 | 脚本默认 | earth_like.tres |
| --- | --- | --- |
| `native_daily_sim_mode` | OFF(0) | **ACTIVE(2)** |
| `native_daily_sim_stride` | 1 | **10** |
| `native_runtime_graph_mode` | ACTIVE | 2 |
| `native_daily_split_weather_node_enabled` | false | **true** |
| `native_daily_node_range_enabled` | false | **true** |
| `native_daily_ocean_thread_variant_enabled` | false | **true** |
| `native_daily_coarse_spread_yield_enabled` | false | **true** |
| `native_daily_finalizer_slice_enabled` | false | **true** |
| `native_daily_finalizer_native_publish_enabled` | false | **true** |
| `native_daily_legacy_daily_production_retired` | false | **true** |
| `native_climate_round_active_owner_enabled` | false | **true** |
| `native_weather_transaction_active_owner_enabled` | false | **true** |
| `native_ocean_physical_active_owner_enabled` | false | **true** |
| `native_season_refresh_active_owner_enabled` | false | **true** |
| `runtime_hydrology_enabled` | false | **true**（但生产 knobs 返回 `{}`，两侧都不跑） |
| `native_tropical_cyclone_enabled` | false | **true** |
| `physical_cell_slice_enabled` | false | **true** |
| `wind_traj_table_enabled` | false | **true** |

> **脚本默认值几乎全是 false，生产靠 `.tres` 覆盖**。所以任何不加载 `earth_like.tres` 的
> fixture 拿到的是一套完全不同的配置——这解释过好几次"测试里复现不出来"。

`project.godot` 里**没有**任何 `runtime_*` / `native_*` 项目设置项，不要去那里找。
