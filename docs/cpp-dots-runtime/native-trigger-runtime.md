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

## Production worker authority (H7/H8)

H7/H8 promoted the worker Trigger POD store from a SHADOW parity mirror to the
production writer. When the session grants `TRIGGER_INPUT` (`0x008`, part of
`implemented_domain_mask() == 0xFFF`), `NativeSimulationHost` runs
`execute_trigger_worker_stage` between Country and Ideology in the fixed stage
order, and the worker is the **sole Trigger writer**:

- `submit_trigger_*` only queues POD commands; the synchronous facade no longer
  stages them.
- `trigger_should_run()` returns false and `run_trigger_daily()` is suppressed,
  so `trigger_daily_system.gd` no-ops with `path=TRIGGER_WORKER`.
- The committed day is copied back through `RuntimeTriggerSnapshotRing` and
  `TriggerRuntime::apply_pod_snapshot`, gated on the snapshot generation. The
  legacy facade stays the read surface for UI, save, and the Effect handoff.
  `WorldRuntimeHost._consume_trigger_worker_snapshot_if_authoritative` calls
  `MapGenerator.apply_runtime_trigger_snapshot`, which forwards to `DCWorldExt`.
  Until 2026-10-13 that forwarder was missing, the host's `has_method` probe
  failed silently, and no worker-fired trigger (development signals included)
  ever reached a country. Ideology got the same forwarder. Modifier and Effect
  forwarders are also present (2026-10-14): earlier joint enablement crashed
  within ~100 ACTIVE days because Effect write-back wiped Economy-owned
  `program_id == -1` colonization transactions/bindings while still holding
  ring-buffer references into snapshots the worker could overwrite. Apply paths
  now copy the POD snapshot out of the ring before rebuilding, and Effect
  `apply_pod_snapshot` preserves colonization builtins across the swap.
- Event ingress under ACTIVE: the Economy stage drains committed gameplay facts
  into Events `APPEND_BATCH` packets (construction facts excluded, since they need
  a main-thread Modifier building identity), and after Events commits,
  `forward_committed_events_to_trigger` queues every new journal row as an
  `INGEST_EVENT` command (producer 3, effective next day, at most 2048 a day,
  rows outside the catalog's source/type span skipped). The main-thread
  `ingest_trigger_events` only sees the synchronous journal, which stays empty
  while Events is worker-authoritative.
- Effect intents are real, not synthetic. The stage publishes them before
  deciding success, so a day whose ACK barrier is incomplete replays the same
  intent ids on its next visit instead of queueing duplicates: the worker's
  Effect stage drains them in-worker under a joint `TRIGGER|EFFECT` grant, and
  `poll_trigger_worker_intent` / `submit_trigger_worker_ack` is the main-thread
  protocol path for a TRIGGER-only grant.

Input-not-ready outcomes (`trigger_pod_not_configured`,
`trigger_pod_not_bootstrapped`, `ack_barrier_incomplete`, `ack_retry`,
`stale_generation`, `ack_rejected`) **soft-complete**: the stage bit is set so
the shared Climate/Country/Effect/Modifier grant is not withheld, while
`trigger_pod_ready` stays false and `trigger_pod_fallback_reason` carries the
diagnosis. Hard kernel or command failures still isolate Trigger for that day.
`trigger_worker_authoritative` in the runtime graph report is the single gate
every main-thread suppression reads.

## Packed contract

当前 packed protocol 为 v3，PKTR save schema 为 v5。Gameplay event 同时携带兼容
`entity_id` 和 64 位 generation-safe `entity_handle`。

`TriggerCatalog.compile_native_catalog()` emits dense IDs and packed columns for
`EventSelector`, `AggregatorSpec`, condition RPN opcodes, `TargetResolver`, and
typed `EffectSpec`. Hot loops use POD/SoA and integer values; no String, Dictionary,
Callable, or arbitrary script is evaluated in the native loop. New aggregators or
actions add a compiler column and adapter without changing the main evaluator.

Supported aggregators are COUNT, SUM, MIN/MAX, STATE_LEVEL, WINDOW_COUNT/SUM,
DISTINCT_COUNT, SNAPSHOT_DIFF, and CONSECUTIVE_DURATION. The consecutive aggregator
stores the last sample day, rejects same-day double progress, resets on threshold
failure, and restarts after a committed-day gap. Conditions support threshold/crossing/level
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
Effect ids are allocated at ingress (`next_effect_id`) while that delivery order is
canonical, so the two orders diverge after any re-sort or PKTR restore and a numeric
high-water cursor would delete an effect that was never handed off (`ONE_SHOT`
achievements are completed, so they never re-emit). Delivery therefore ACKs the
explicit id set returned in `handoff_effects()["effect_ids"]` through
`ACK_EFFECT_IDS`; the legacy `ACK_EFFECTS` high-water cursor is retained only for old
peers and only advances over the gap-free numeric prefix. Adapters still ACK only the
contiguous prefix they applied successfully.

Supported Modifier actions are handed to EffectRuntime as one contiguous native
prefix through `handoff_trigger_effects()`. EffectRuntime owns the ensuing
transaction and native Modifier ACK; TriggerRuntime removes exactly the handed-off
effect ids, preserving PKTR as the authority for unhanded or unsupported actions.
Remaining actions continue through the GDScript compatibility adapter and cannot be
skipped by the native handoff.

`replay_completed_research_signal(trigger_id, target, cell, day)` is the recovery
backfill for the completed-record-without-signal failure. It accepts only `ONE_SHOT`
definitions with `development_metric_id >= 0` and exactly one
`COUNTRY_COMMAND(opcode 14 / domain 1 / CONSTANT value 4)` effect, re-emits it with
the event day backfilled to `day - 1` (so it delivers at `day`), and packs
`payload_i0 = (signal_index << 32) | cell`. `target` is the packed country handle
`(generation << 32) | slot`. The trigger layer does not dedupe a replay after the
effect was delivered; idempotence is owned by Country's
`DISCOVER_COUNTRY_SIGNAL`, which ignores an already-observed `(signal, cell)` pair.

`IDEOLOGY_COMMAND` is also a typed native handoff. Its opcode is an ideology
command; target is the country handle; payload slots carry ideology dense ID,
offer generation, choice index, and gate ID. Trigger accepts it only into the
deterministically sorted ideology command queue, then advances its own cursor.
It never writes ideology storage, Country, or Modifier directly.

动态家族分支 binding 以 `(definition, branch_handle, cell)` 标识，并建立
`(source,event_type,cell)` 稀疏索引。建筑完工和跨 settlement-cell 贸易只向 GameplayEventBus
发布一次，再扇出到本地合资格分支；无需为每个家族重复发布事实。解绑会立即删除对应 state 和
未派发 effect，威望降级不会保留旧累计。

2026-10-15 hotloop v24 corrects a missing native-kernel application of that
index: the worker had still scanned every dynamic binding per event. The kernel
now builds an exact `(source,event_type,cell,original_index)` sorted workset from
the sealed branch bindings and visits the matching range. Original index order
preserves state creation, fire sequence and effect allocation. This scratch never
survives the evaluate call, so command changes cannot leave a stale binding index.
The original manual-save fixture currently has zero dynamic bindings; this fix
does not account for its measured throughput gain.

Dual Trigger FNV-1a still includes every distinct-key byte and every field. Its
INT64_MIN empty-key lane contains seven zero bytes; those multiplications are
combined exactly into a precomputed power of the same prime. The hash ABI and
strength are unchanged. `PK_TRIGGER_BINDING_SCAN_SCALAR=1` and
`PK_TRIGGER_HASH_SCALAR=1` select the original paths. `PK_TRIGGER_MEMO_VERIFY=1`
re-evaluates the sealed day with the full binding scan and compares complete state
and effect hashes, then independently computes both original full-byte hashes.
Probes `trigger.kernel`, `trigger.hash_dual`, `trigger.hash_empty_keys`,
`trigger.binding_candidates` and `trigger.binding_scalar_candidates` distinguish
compute, hash and candidate work.

Hotloop v28 avoids copying the large `RuntimeTriggerCommand` records into a
temporary sort table. An already ordered queue is visited directly; an unordered
queue is stable-sorted through const pointers using the same four-field key.
Consumed/retained commands remain owned copies, and the queue changes only after
successful preflight. Discard, future-day retention and ACK semantics are unchanged.
`PK_TRIGGER_COMMAND_COPY_SCALAR=1` restores the copied sort. The POD self-test
covers unordered commands, equal-key stability, discard/replay and future retention.
`trigger.commands`, `trigger.plan_copy`, `trigger.canonicalize`,
`trigger.commit_copy` and `trigger.snapshot_copy` split host-side costs;
`trigger.command_order_copy_bytes/reference_bytes` count temporary ordering storage.

`ECONOMY_SOCIAL_PRESSURE = 8` / `SOCIAL_PRESSURE_V1 = 5` 走同一条 committed gameplay fact
通路，**只在地块的人口加权满意度等级（0 最紧张 .. 4 最满足）跨越时**发布，沿用聚落繁荣度的
level-change 去重模式，所以每 epoch 的事件量以滚动 workset 为上界。payload 为
`i0` 新等级、`i1` 最差维度、`i2` 最差需求、`i3` 上一等级，`value` 是人口加权 composite（Q16），
`entity_id` 是人口，`flags=1` 表示等级下降，天然匹配既有 `STATE_LEVEL` / `PUSH_CROSSING`
聚合器。示例条目见 `data/triggers/default_trigger_catalog.tres` 的
`economy.social_pressure_relief`；维度语义见[综合满意度运行时](./satisfaction-runtime.md)。

## Persistence and recovery

`PKTR v5` stores catalog hash/version, source cursors, dynamic branch bindings, trigger SoA (accumulator,
remainder, last event, fire sequence, cooldown/reset, observed snapshot, target
generation, last development sample day, resync flags), and pending effects. Restore rejects catalog mismatch,
truncated payloads, stale definitions, invalid handles, or any older schema with
`catalog_hash_mismatch`; there is no empty-trigger migration. Family reward adapters queue native free-building or
population commands at the next Economy safe boundary; they never mutate economy authority directly.

## Technology breakthroughs

Country development facts use event 17 / payload 10. `DevelopmentAchievementCatalog`
compiles their dense metric IDs, thresholds, eras and permanent country-signal effects.
`development_progress(country_handle, era_index)` is a cold UI query; the native
evaluation path remains dense and allocation-free.

Economy publishes `EVENT_TECHNOLOGY_PRACTICE` only from committed, producing
BuildingGroups. Eleven one-shot rules aggregate maize selection, dryland days/windows,
hydraulic practice, metal-tool and print output, steam/electric/factory/automation
group-days, and climate-research cycles. The fixed thresholds are 365 maize days
with three observed maize cells; 730 dryland days or three drought windows; two
hydraulic groups plus one flood window; 5,000 tools; 10,000 printed units with a
research institution; 3×1,095 steam, 3×730 electric, 3×365 factory, 2×365
automation group-days; and five climate-research cycles with three extreme-weather
samples each.

Automation practice is produced by digital-control or automated-logistics groups before
`autonomous_systems` is researchable. Autonomous/robotic buildings also continue the same practice
after the breakthrough, so the route has a prototype-to-breakthrough chain instead of a circular gate.

Crossing a threshold hands a precompiled `trigger.country.breakthrough.*` command
to EffectRuntime. Effect submits `DISCOVER_COUNTRY_SIGNAL` to the Country safe
boundary, using the first producing cell and Trigger fire sequence as provenance
and idempotency. Trigger never writes the signal bitset or technology completion.

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

When a Trigger reward is a configurable multi-step effect, it may enqueue an
EffectRuntime instance or typed effect input. EffectRuntime then owns only the
plan/transaction/ACK lifecycle; TriggerRuntime still owns event cursors and
PKTR state, and the target domain still owns the eventual mutation. See
[`native-effect-runtime.md`](./native-effect-runtime.md).
