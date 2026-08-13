# Native Modifier Runtime

科技树通过永久 `UNIQUE_SOURCE` Country Modifier 提供四领域研究效率、研究成本、科研机构、
五部门、生产家族与精确建筑类型产出、施工/贸易和旱涝寒热适应效果。完成节点先 pending，Effect
中的 Modifier 与 `technology.adopted` 等全部命令 ACK 后才发布完成标签；详见
[科技树、科技值与科研经济运行时](./technology-tree-runtime.md)。
当前 361 节点目录显式作者化 516 个 term。每个非开局节点保留 1-3 个真实消费者条款；生产家族
或同一精确建筑作者合计不超过 +400%，全国部门/研究/贸易作者合计不超过 +400%，含泛化全国条款
的节点不超过非开局节点的 40%。目录钳制：家族/建筑/五部门/贸易 `[0, 8]`，四领域研究效率
`[0, 6]`，气候损失 `[0.20, 1]`，建设成本/时间 `[0.40, 4]`。所有泛化条款都与一个生产家族或
精确建筑效果配对。

本文是 Project.Keynes 全域 Modifier Runtime 的当前实现主说明。代码、测试、
架构文档和 `project-keynes-modifier-runtime` Skill 与本文不一致时，变更不能交付。

## 状态

截至 2026-08-03，原生 catalog、四域 store、命令、调度、气候双路径、国家到经济
桥、建筑产量、Gameplay identity、家族城市效果、protocol/save schema v2、PKEC v30、focused
test 已落地。两个隔离 agent forward-test 已完成，并据此补上 Modifier deadline-critical
边界、Economy parent generation 校验及 Skill 路由。60x40 目标规模的 50 日 after 记录已完成；
no-Modifier 同机 baseline 尚未取得，因此性能回归门槛仍是未验收项。

## 固定语义

Modifier 不写 base value。effective value 固定为：

```text
clamp((base + sum(add)) * product(factor), stat_min, stat_max)
```

- `SUBTRACT x` 编译为 `ADD -x`。
- `DIVIDE x` 编译为 `MULTIPLY 1/x`，`x == 0` 在 catalog 编译时拒绝。
- factor 为零合法；bucket 用 `zero_factor_count` 表示，移除时不做除零。
- 非有限 catalog 值、重复 key、跨域 term、非法范围和非法 operation 均拒绝配置。
- 移除只影响后续查询；已结算经济、温度、积雪和其他历史状态不倒带。
- 现金、商品、人口等守恒量不得成为 stat。Modifier 只能影响产能、效率、需求系数、
  阈值等计算参数。

## Catalog

资源入口是
`Project/project-keynes/data/modifiers/default_modifier_catalog.tres`。GDScript 资源类型位于
`scripts/modifier/`，`ModifierCatalog.compile_native_catalog()` 将字符串 key 编译成启动期
dense ID。运行时查询只使用 dense ID；存档、journal 和 explain 使用稳定 key。

当前 stat：

| key | domain | 范围 | 首个消费者 |
| --- | --- | --- | --- |
| `climate.cell.radiative_target` | Climate | `[0, 1]` | climate Pass-A |
| `country.economy_output_factor` | Country | `[0, 16]` | country epoch snapshot |
| `country.output.family.<id>_factor` | Country | `[0, 8]` | frozen country×family building output |
| `country.output.building.<id>_factor` | Country | `[0, 8]` | frozen country×building-type output |
| `economy.building.output_factor` | Economy | `[0, 16]` | building output helper |
| `economy.city.output_factor` | Economy | `[0, 8]` | settlement epoch output cache |
| `economy.city.birth_factor` | Economy | `[0, 4]` | household demography |
| `economy.city.consumption_factor` | Economy | `[0, 4]` | cohort demand helper |
| `economy.city.need.<id>.consumption_factor` | Economy | `[0, 4]` | selected need demand |
| `economy.city.good.<id>.consumption_factor` | Economy | `[0, 4]` | selected good/variant demand |
| `economy.city.resource.<id>.regen_factor` | Economy | `[0, 4]` | frozen native/fallback resource pass |
| `gameplay.generic.value` | Gameplay | `[-1e9, 1e9]` | NativeGameplayRuntime API |

一个 definition 的 term 必须全在同一 domain。跨域影响只能通过冻结发布值传递；例如
Country store 发布国家产出因子，Economy 再与 Building factor 组合。

当前 `allowed_operations` 由 GDScript catalog 编译器校验；`value_conversion` 尚未进入 native
catalog，Economy 仍由 consumer helper 显式做 Q16 转换。`persistable=false` 当前也未改变
序列化行为。新增依赖这两个字段的 stat 前必须先补 native packed contract、hash 和测试。

## 数据结构

`ModifierRuntime` 是 `DCWorldExt` 的内部 peer runtime。四个 domain 共享实现但各有独立
`Store`。实例列采用 SoA：active、generation、definition、entity/group、source、scope、
stack、`magnitude_q16`、applied/expiry day 和 expiry revision 分列存储。

term 先按 magnitude 从中性值缩放：ADD 使用 `value * magnitude`；MULTIPLY 使用
`1 + (factor - 1) * magnitude`，随后再应用 stacks。bucket 和 explain 保留 clamp 前值，并按
source 返回每个家族分支贡献；多个家族没有额外总上限，只有 stat 自身合法区间钳制。

`ModifierHandle` 编码为 `generation << 32 | index`。slot 复用时 generation 增长；stale
handle、重复移除和失效 identity 只拒绝当前命令。

bucket key 是 `(stat_id, scope, scope_id)`，缓存 `sum_add`、`product_nonzero`、
`zero_factor_count` 和成员引用。查询固定读取 global、可选 group、entity 三个 bucket，
不把国家或 group Modifier 展开到 cell、building 或 cohort。累计变更达到阈值或数值异常
时从成员表重建。

到期使用最小堆。heap node 携带 generation、expiry day 和 revision；refresh 后旧 node
惰性失效。永久实例使用 `expiry_day = -1`。

## 生命周期与叠层

- `INDEPENDENT`：每次 apply 分配独立 handle。
- `UNIQUE_SOURCE`：definition、scope target、source 相同则原位 replace，handle 不变。
- `STACK_REFRESH`：原位增加 stack 至上限并刷新到期日；add 线性，factor 幂次。
- N 日实例在 apply 日生效，在 `applied_day + N` 的消费者执行前过期。
- target cleanup 只移除该 entity scope 实例；global/group 不受影响。

Gameplay object 和 Economy building 都使用 generation-safe identity。building key 当前是
`(cell, type_id, owner_signature_id)`；建筑组消失时调用 `retire_building_identity()` 并写
`TARGET_CLEANUP` journal。

## 命令与冷查询

`ModifierFacade` 只提交 version 2 PackedArray batch：opcode、producer、sequence、day、
definition、domain、scope、entity/group handle、source、duration、stack 和 handle 都是平行
列，并包含 `magnitude_q16`。`ModifierDailySystem` 按 effective day、producer、sequence、submit order 稳定排序。

Facade API：

- `queue_apply`
- `queue_remove`
- `queue_refresh`
- `queue_set_stacks`
- `queue_set_magnitude`
- `get_command_result`
- `list_for_target`
- `explain_stat`
- `report`

`list`、`explain`、command result 和 journal 是冷路径。热循环不得出现字符串查找、
`Variant`、Godot Object 调用或 per-entity allocation。

## Daily Graph

`modifier_daily` priority 为 90，先于 climate 100、country 255 和 economy 260。它保持
`must_run=false`，但当 `modifier_should_run(day)` 为真时声明 deadline-critical，确保预算耗尽时
仍在同日 consumer 前获得一次执行机会。每日顺序：

1. WorldClock 提供 day index。
2. 处理到期 heap。
3. 稳定合并并执行到期命令。
4. 更新 bucket 与 snapshot version。
5. climate/country/economy/gameplay 消费冻结结果。
6. facade 在 system 返回后发布 journal batch。

并行 consumer 不修改 store；consumer 产生的新命令进入后续安全边界。当前 Modifier system
是 ACTIVE 单 slice 节点，没有独立的 SHADOW 双算实现；领域 SHADOW 必须只比较最终输出，
不能双写 store。

## 领域接入

### Climate

同步 scalar、生产 thread 和 GDScript SoA fallback 都在 `radiative_target` 基础计算完成后、
clamp 和 thermal inertia 前应用 Modifier。async pure kernel 由主线程预计算每 cell 的 frozen
add/factor 数组，worker 只读取 POD，不访问 Godot API 或可变 store。移除后下一次 Pass-A
恢复 base 加剩余项，已有温度与积雪不回滚。

### Country 与 Economy

`NativeCountryRuntime::EconomySnapshot` 发布 generation-safe country handles。Economy 在
`capture_country_epoch()` 中把国家总产出、部门、科研机构、生产家族和精确建筑类型因子转成
连续 Q16 数组，并为每个 BuildingGroup 缓存 generation-safe identity 和组合后的 output factor。

`effective_building_output_quantity()` 是统一定点入口：先计算 base、building days 和
utilization，再乘冻结的 country/building 组合因子。实际生产、工资可负担性、生存产量、
工作资本、恢复/清算和投资收益/发行量/缺口估算都复用该 helper。结果进入现有商品结算，
Modifier 从不直接写 market stock、country treasury 或 cohort funds。

家族以 settlement cell 作为 Economy group。城市总产出、建筑 selector 效率、出生率、need/good
消费量和资源再生率在 epoch/snapshot 边界冻结为连续 Q16 POD；资源原生 pass 与 GDScript fallback
读取同一冻结因子，不在逐资源热循环查询 ModifierStore。

### Gameplay

`NativeGameplayRuntime` 当前由 `ModifierRuntime` 的 gameplay identity/base SoA 实现，通过
`register_gameplay_modifier_object`、`unregister_gameplay_modifier_object`、
`set_gameplay_modifier_base` 和 `get_gameplay_modifier_effective` 暴露。它不接收 Godot Object
指针，也不反射任意字段。当前 archetype 仅保存稳定标签；“每 archetype stat 白名单”仍待
扩展，因此新增 Gameplay stat 前必须在 catalog 与调用侧共同校验。

## Journal 与报告

journal v2 固定容量，事件类型为 apply、replace、stack、refresh、remove、expire、target
cleanup、reject。列包括 day、domain、handle、definition、entity/group、scope、source、
旧/新 stack、request ID 和 reason；overflow 单独累计。

`get_modifier_report()` 当前发布 protocol/save schema、catalog hash、current day、pending、
累计 applied/rejected/expired、journal overflow、command merge/expiry/snapshot publish 时间，
bucket update/rebuild 当日与累计时间、排序后的错误原因计数，以及四域
active/peak/bucket/query/bucket read/rebuild/snapshot version、事件计数和估算内存数组。
估算内存是容器 capacity 加节点近似值，不是 allocator RSS。

## 存档与迁移

| section/schema | 内容 |
| --- | --- |
| PKCN v11 | Country authority, technology/research-signal identity, national/cell tax policy + Country Modifier domain blob + native Effect ingress idempotency |
| PKEC v34 / Modifier schema v2 | Economy authority, family-cell effects + BuildingIdentityStore + Economy Modifier section + native Effect ingress idempotency + canal projects/quotes |
| PKCM v1 | Climate Modifier domain |
| PKGP v1 | Gameplay identity/base SoA + Gameplay Modifier domain |

实例保存稳定 definition/stat key、definition version、target/source/scope、stack、日期和规范化
term payload。恢复会校验 catalog hash、definition version、term payload、handle 和 identity；
不兼容时失败，不重放 apply event。

当前恢复采用严格 catalog hash、definition version 和 term payload 校验。
PKEC reader 只接受 v30，v29 及更早版本不再通过税务或空 store 迁移；append-only
catalog 差异也继续拒绝。focused runtime 未配置 Modifier 时，PKCN/PKEC 写入显式空
domain marker。生产恢复顺序是 dynamic world、
environment、PKCM、WorldClock、PKCN、PKEC、PKGP，再恢复 vision/journal/player；PKCN 后先
准备 Economy topology。

## 验证

`tests/modifier_runtime_test.gd` 覆盖 apply/remove/expiry、stack refresh、global/group/entity、
UNIQUE_SOURCE、stale handle、零 factor、Gameplay base/effective、journal v2、report 诊断和四域 round-trip。
`country_runtime_test.gd` 验证 PKCN v11；`family_runtime_test.gd` 与
`building_runtime_test.gd` 验证 PKEC v34 save/restore 与状态哈希。
正式 `PK_GAME_SAVE_ROUNDTRIP_TEST=1` 也已通过新建世界、PKSV 保存/恢复、authority hash
对齐和恢复后首个经济周期。两套大型 economy suite 的 v20 存档断言虽通过，但各仍有 4 个
既有 catalog/平衡断言失败，整体退出码为 1，不能把它们列为全绿门禁。

交付前运行：

```powershell
.codex/skills/project-keynes-modifier-runtime/scripts/verify_modifier_runtime.ps1 -Build -Godot
```

性能目标仍是目标规模 50 日 benchmark 的 daily graph median 回归不超过 3%、p95 不超过
5%。2026-07-28 debug headless after（60x40、speed 50、seed 20260718）生成
`tmp/perf_record_20260728_042215.csv`：50 rows、ledger failures 0、fatal false；
`modifier_daily` avg/median/p95/max 为 0.0844/0.0765/0.1110/0.1140 ms，50 日无 skip，
总 SUS median/p95 为 7.4355/9.8540 ms，largest 50/50 为 `economy_daily`。该数据不是
no-Modifier baseline，不能据此判定 3%/5% 回归门槛。

## 非目标

首版不提供历史倒带、真实时间到期、任意字段反射、跨域直接写入、多父 scope 图或一次性
资源转移。伤害、人口变化、资源转账等一次性效果必须使用各领域 command/event。

Trigger effects may queue Modifier commands, but TriggerRuntime never fans out or
mutates ModifierStore directly. Modifier remains the owner of modifier lifecycle.

EffectRuntime may emit `MODIFIER_COMMAND` transactions for this runtime. The
Modifier adapter is responsible for preflight, safe-boundary command application,
generation validation and idempotent ACK. EffectRuntime never writes a
ModifierStore bucket, base value, effective cache, or modifier persistence
section directly. Known Effect Modifier commands use a C++ POD batch at
`modifier_daily`; the GDScript adapter remains a compatibility transport only.
Retiring an Effect-owned `INDEPENDENT` definition removes all rows with the same
definition, scope, source type, and source ID at that lifecycle boundary. See
[`native-effect-runtime.md`](./native-effect-runtime.md).
