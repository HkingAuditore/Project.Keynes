# Native Trigger Runtime

`TriggerRuntime` is a generic, native event-to-effect graph. It is deliberately
not an economy, country, modifier, or building rules engine. Gameplay supplies
catalog definitions; the runtime owns only committed event ingestion, aggregate
state, deterministic condition evaluation, and an ordered effect buffer.

## Authority and scheduling

GameplayEventBus remains the fact journal, replay source, and consumer cursor
owner. TriggerRuntime uses a dedicated consumer and exact `event_id` de-duplication.
It runs after the committed boundary and before domain consumers (SUS priority 80);
it never writes DataCore slots, ModifierStore, country state, or economy ledgers.
Effects are commands applied by domain adapters at their next safe boundary.

## Packed contract

当前 packed protocol 与 PKTR save schema 均为 v2。Gameplay event 同时携带兼容
`entity_id` 和 64 位 generation-safe `entity_handle`。

`TriggerCatalog.compile_native_catalog()` emits dense IDs and packed columns for
`EventSelector`, `AggregatorSpec`, condition RPN opcodes, `TargetResolver`, and
typed `EffectSpec`. Hot loops use POD/SoA and integer values; no String, Dictionary,
Callable, or arbitrary script is evaluated in the native loop. New aggregators or
actions add a compiler column and adapter without changing the main evaluator.

Supported aggregators are COUNT, SUM, MIN/MAX, STATE_LEVEL, WINDOW_COUNT/SUM,
DISTINCT_COUNT, and SNAPSHOT_DIFF. Conditions support threshold/crossing/level
change, boolean composition, cooldown, repeat/one-shot, and completion. Targets
resolve from static, source entity, event entity/group, or committed snapshots.
Conserved cash, goods, and population are domain commands, never modifier stats.

## Ingress, effects, idempotency

Each source has a cursor. Duplicate IDs are ignored. Strict contiguous cursor gap
checking is opt-in (`strict_source_cursors`) because the shared journal can contain
multiple interleaved sources. A gap or ring overflow marks affected state
`needs_resync`; effects pause until a committed snapshot rebuild succeeds.
Effects are sorted by `(effective_day, source_priority, trigger_id, target_handle,
fire_sequence)` and carry idempotency `(trigger_id, target_generation, fire_sequence)`.
Adapters ACK only the contiguous prefix they applied successfully.

动态家族分支 binding 以 `(definition, branch_handle, cell)` 标识，并建立
`(source,event_type,cell)` 稀疏索引。建筑完工和跨 settlement-cell 贸易只向 GameplayEventBus
发布一次，再扇出到本地合资格分支；无需为每个家族重复发布事实。解绑会立即删除对应 state 和
未派发 effect，威望降级不会保留旧累计。

`ECONOMY_SOCIAL_PRESSURE = 8` / `SOCIAL_PRESSURE_V1 = 5` 走同一条 committed gameplay fact
通路，**只在地块的人口加权满意度等级（0 最紧张 .. 4 最满足）跨越时**发布，沿用聚落繁荣度的
level-change 去重模式，所以每 epoch 的事件量以滚动 workset 为上界。payload 为
`i0` 新等级、`i1` 最差维度、`i2` 最差需求、`i3` 上一等级，`value` 是人口加权 composite（Q16），
`entity_id` 是人口，`flags=1` 表示等级下降，天然匹配既有 `STATE_LEVEL` / `PUSH_CROSSING`
聚合器。示例条目见 `data/triggers/default_trigger_catalog.tres` 的
`economy.social_pressure_relief`；维度语义见[综合满意度运行时](./satisfaction-runtime.md)。

## Persistence and recovery

`PKTR v2` stores catalog hash/version, source cursors, dynamic branch bindings, trigger SoA (accumulator,
remainder, last event, fire sequence, cooldown/reset, observed snapshot, target
generation, resync flags), and pending effects. Restore rejects catalog mismatch,
truncated payloads, stale definitions, or invalid handles. Old saves may omit PKTR
and are treated as an empty trigger state. Family reward adapters queue native free-building or
population commands at the next Economy safe boundary; they never mutate economy authority directly.

## Diagnostics and validation

Reports expose `stage`, `path=TRIGGER_GRAPH`, work, ingest/evaluate timings, event
dedupe/reject counts, state/effect capacity, gap/resync counters, pending effects,
and `last_error`. ACTIVE/SHADOW rollout compares emitted effect IDs and aggregate
hashes at committed boundaries. Required perf checks include CPU p95/p99, lag,
allocation count, rule count, scope count, effect count, and resync frequency.

## Extension procedure

1. Add a catalog resource/compiler column and a native POD field.
2. Validate bounds and catalog hash inputs at configure time.
3. Add a focused runtime test for accumulation, reset, save/restore, and gap paths.
4. Add a domain adapter that queues an existing command API; never mutate a store
   from TriggerRuntime.
5. Update this document, the runtime authority matrix, scheduler graph, bridge,
   diagnostics, modifier, and save-flow documents together.

## Reuse research

The design was compared against [EnTT](https://github.com/skypjack/entt),
[Flecs](https://github.com/SanderMertens/flecs), and
[Microsoft RulesEngine](https://github.com/microsoft/RulesEngine). Their mature
observer/dispatcher and compiled-rule patterns informed the indexed ingress and
condition IR. None was imported: each would duplicate the existing DataCore/SUS
authority or introduce a dynamic object model in the simulation hot path.
