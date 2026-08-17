# Native Effect Runtime

`EffectRuntime` is the generic plan and transaction layer for configurable
gameplay effects. It is intentionally not a country, economy, Modifier, or
DataCore store. The runtime owns immutable effect programs, active effect
instances, frozen input snapshots, deterministic plans, and cross-domain ACK
state. Domain runtimes remain the only writers of authoritative state.

## Data flow

```text
EffectCatalog Resource
  -> compile_native_catalog() packed IR
  -> EffectRuntime::configure()
  -> submit_instances() + submit_snapshots()
  -> run_effect_daily()
  -> typed transaction queue
  -> native Modifier batch -> Modifier safe commit -> native ACK
     or GDScript/domain-adapter compatibility transport
  -> terminal transaction state
```

The hot loop uses dense program IDs, POD rows, fixed-size value stacks, Q16
integers, runtime-wide flat metric slabs, a shared command arena, and bounded
candidate work. It does
not evaluate GDScript, Callable, Godot Objects, String lookups, or Dictionary
values. Catalog and snapshots are cold-boundary operations that translate stable
keys to dense IDs. A definition's
`max_work` is both a scheduler work charge and a compile-time upper bound for
its condition/value program; the global `max_work_per_slice` limits how many
definition evaluations a cooperative slice can visit. A single oversized
definition is admitted once so it cannot starve forever.

## Catalog contract

`Project/project-keynes/scripts/effect/effect_catalog.gd` emits metric keys,
effect keys and versions, cadence/enable flags, condition IR, value IR, and
typed command definitions. Conditions support metric/state comparisons and
boolean composition. Value instructions include `CONST`, `READ_METRIC`,
`READ_STATE`, arithmetic, clamp, and `EMIT_COMMAND`.

Technology programs use the unique recipe IDs and versions compiled by
`TechnologyCatalog`; `EffectDomainCatalog` does not regroup them by research
domain or profile. Every non-starting technology recipe emits its own permanent
Modifier definition and `technology.adopted` event. These recipe columns enter
the technology identity hash as well as the PKEF program hash.

All numeric values use Q16. `DIV_FLOOR` returns a Q16 integer quotient. New
configuration operators must be bounded and validated at catalog compile time.
Command rows are validated twice: the GDScript compiler rejects missing keys,
invalid target layouts, wrong adapter domains, and unsupported opcode ranges;
`EffectRuntime::configure()` repeats the same checks before exposing a catalog.
The configured command row is the native command template ID carried by a
runtime command. Known Modifier producer variants are also classified once at
configure time, so declarative dispatch does not compare command-key strings in
the daily adapter path; only the compile-time Behavior compatibility extension
retains a cold legacy key branch.
The current native ABI therefore covers Country opcodes `1..14`, Economy
opcodes `1..15`, Modifier apply/remove, Gameplay rows on domain `3`, journal
events on domain `4`, and only the registered CustomDomain audit opcode
`domain=6/opcode=1`.
An effect with `behavior_id` calls a compile-time registered
`EffectRuntime::BehaviorFn`; the callback reads a frozen `BehaviorInput` and
returns POD commands. Behavior commands use integer key IDs from the catalog's
`behavior_command_keys` table; adapter strings are resolved only when polling
or serializing. Behaviors never mutate domain stores directly.

## Instances and snapshots

`submit_effect_instances()` accepts stable instance IDs, generation, program
key, source/target handles, level, active flag, and next due day. A generation
change resets fire sequence and input presence. `submit_effect_snapshots()`
accepts CSR-style metric rows (`metric_offsets`, dense metric IDs, Q16 values)
and an input revision. Missing metrics read as zero; callers should publish all
metrics used by a program in the same committed snapshot revision.
An instance consumes a revision at most once. A strictly newer snapshot revision
may re-enter the current day's dirty candidate list before its normal cadence;
an unchanged snapshot never bypasses cadence.

Native owners with already-packed state may use the equivalent POD instance and
metric entry points at their structural boundary. Metrics live in contiguous
value/presence slabs, while a due min-heap plus dirty queue produces a stable
candidate list; daily evaluation never scans dormant instances. Stale heap rows
are token-rejected and heap growth is compacted to a bounded multiple of active
instances. This avoids constructing Godot Dictionaries in hot loops and does
not transfer domain state ownership to Effect Runtime.

Completed retirement removes the active ID only after its final domain ACK. The
backing instance/metric-slab slot becomes a persisted tombstone and enters a
native free list, so a later instance reuses the slot without consuming active
capacity. Transaction IDs and pending-source counts use native hash indexes;
native ACK, adapter ACK, and retirement do not linearly search every pending
transaction. The default catalog permits up to 16,000,000 active instances and
transactions. `max_native_modifier_commands` bounds one C++ Modifier enqueue
batch independently (default 4,096, configurable up to 4,000,000).

## Parallel planning

For a contiguous batch of at least 64 declarative candidates and a platform
with real worker threads, the runtime evaluates conditions and packed value IR
in C++ workers. Workers read only frozen catalog, instance and metric slabs and
write one private `PlannedCandidate` result each. The calling thread merges
those results in stable candidate order, and is the only writer of fire
sequences, due scheduling, transaction IDs, idempotency state and ACK masks.
This makes the worker path result-equivalent to serial evaluation while keeping
cross-domain commit ownership unchanged. Platforms without workers use the same
planning/merge representation serially. C++ behavior callbacks remain serial
until their owning module explicitly supplies a thread-safe behavior contract.

## Plans, transactions, and ACK

Each due instance is evaluated once per cadence. A successful program produces a
transaction containing commands, a deterministic plan hash, and an idempotency
key derived from `(instance_id, generation, fire_sequence, command_index)`.
Command domains contribute bits to `required_ack_mask`. Adapters may ACK only
after their own preflight and safe commit. Until all required bits are received,
the transaction remains pollable and is persisted in `PKEF`.

Commands carry both target handle and target generation; domains must reject
stale handles before commit. Known `technology.modifier`, `family.modifier`,
`person.modifier`, and `trigger.modifier` commands use the native batch bridge: C++ creates
`ModifierRuntime::NativeCommand` rows, Modifier Runtime commits them at
`modifier_daily`, and C++ ACKs the Effect transaction. A native-bound
transaction is hidden from the fallback poll path to prevent duplicate enqueue.
Native adapters claim complete POD transactions for Modifier, all current Country
opcodes (1..14), all current Economy opcodes (1..15), `GAMEPLAY_COMMAND`,
`PUBLISH_EVENT`, and the registered CustomDomain audit command. Country and
Economy only stage requests; their own command/ledger boundary preflights and
commits them, then Effect observes a durable idempotent ACK. Gameplay,
PublishEvent, and the registered CustomDomain command share the fixed-capacity
native gameplay ingress and journal-backed idempotency table at
`gameplay_effect` priority 95. ACK means the event is durable, not that a UI
subscriber has consumed it. New CustomDomain opcodes are rejected at catalog
compile time until a C++ adapter explicitly registers their domain/opcode
shape; they never fall through to GDScript.
Native-owned transactions are excluded from `EffectFacade.poll_transactions()`,
so ideology never reaches the GDScript compatibility transport.

Transaction ACK masks are keyed by native adapter identity, not by the authored
`command.domain`. This distinction is required because a Modifier command uses
`domain` for its Modifier subdomain (for example Country = 1), while a real
Country command also authors domain 1. The fixed adapter bits are Modifier,
Country, Economy, Gameplay, PublishEvent, and CustomDomain. A mixed transaction
therefore remains `COMMITTED` until every adapter bit is durable; an adapter
whose bit is already received skips its commands on retry instead of submitting
them again.

Unsupported legacy commands use `EffectFacade.dispatch_transactions()` as the
compatibility transport. Each fallback adapter receives `phase=preflight` first
and must validate without mutation; after the runtime enters `PREFLIGHTED`, the
adapter receives `phase=commit` at its domain safe boundary. The runtime then
enters `COMMITTED` and accepts ACK masks. A transaction can be `PLANNED`, `PREFLIGHTED`,
`COMMITTED`, `ACKED`, `REJECTED`, or `RESYNC_REQUIRED`; failed adapters never
advance the contiguous transport cursor. Adapters must carry
`command_idempotency_key` into their domain command dedupe. Technology and
family Modifier producers now use this path. Technology completion creates a
stable country/technology instance; family branch reconciliation creates a
stable branch/cell/modifier instance and publishes the final Q16 magnitude as
its metric. Native person promotion and `PERSON_COMMIT` register a stable
`person.modifier.gameplay.generic.bonus` instance and target before the native
bridge applies it. `NotablePersonStore` and `PERSON_COMMIT` remain the
authority for jobs, needs, population, and cash attribution. A full bounded queue returns retryable
backpressure without advancing the instance cursor; terminal `ACKED` and
`REJECTED` records are compacted before new plans are accepted. Behavior lookup
or program arithmetic failures likewise preserve the fire sequence and due day
for retry instead of silently consuming the effect.

## Domain migration boundary

`EffectDomainCatalog.build()` compiles executable definitions from the existing
technology and family-trait catalogs at startup, so content does not maintain a
second Modifier-definition copy.

- Technology: `CountryRuntime` still owns research and technology bits. On
  completion it registers a generation-safe instance; `technology.modifier`
  emits the existing country Modifier apply command through the native bridge.
- Family: `NativeEconomyRuntime` still computes traits, strength, prestige and
  branch lifecycle at `FAMILY_COMMIT`. It publishes only the final branch Q16
  Modifier magnitude to `family.modifier`; the native bridge uses the established
  `(cell, FAMILY, branch_stable_id)` Modifier identity. Trait state and Trigger
  bindings remain Economy/Trigger authority.
- Person: native promotion and every `PERSON_COMMIT` reconcile a
  generation-safe `person.modifier.gameplay.generic.bonus` instance. The public
  `EffectFacade.submit_person_modifier_instance()` remains the extension entry
  point for future authored definitions. Neither path can write population,
  cash, needs, employment, or other person authority.

## Scheduling

`EffectRuntimeSystem` is registered in `DCSystemScheduler` at priority 85:

```text
trigger_runtime 80
effect_runtime  85
modifier_daily   90
country_daily   255
economy_daily   260
```

`MapGenerator._setup_sus()` registers the Effect Runtime before country and
economy bootstrap. Its availability therefore depends only on the native
Effect API and catalog compilation, not on whether either downstream domain
finishes initialization.

The system uses `effect_should_run(day)` and one cooperative bounded slice.
Pending `PLANNED`/`PREFLIGHTED`/`COMMITTED` transactions also keep the system
eligible between instance cadences so missing adapters can be retried.
`done=false` keeps the same-day cursor alive without unbounded work. Empty
catalogs and empty instance sets are no-op and do not consume a slice.

After planning, `EffectRuntimeSystem` invokes
`dispatch_effect_native_modifier()` (a C++-only batch). `ModifierDailySystem`
invokes `ack_effect_native_modifier()` immediately after `run_modifier_daily()`,
which is the Modifier safe boundary. The facade transport is retained only for
transactions not claimed by the native bridge.

## Persistence and diagnostics

`PKEF v9` stores catalog hash, runtime cursors, an in-progress candidate list,
instances, input metrics, published and consumed input revisions, fire sequences, and pending
transactions/commands. It additionally stores durable `ExternalSourceBinding`
rows for peer-owned persistent sources: source identity, target handle/generation,
ideology level/location, binding generation, persistent-template signature and
program hash. Native adapter request IDs are process-local and are
not serialized: a native-bound `PREFLIGHTED` transaction is written as
`PLANNED` and is safely re-submitted with the same command idempotency key after
restore. Restore rejects
wrong protocol, schema, catalog hash, truncation, invalid IDs, and invalid
transaction status. Domain state is not duplicated in PKEF; its domain-side
idempotency evidence remains in PKCN, PKEC, or the gameplay journal.

PKEF v9 also owns the complete frozen era-reward Alternative Offer Plan:
three alternatives, visible weighting reasons, generation-safe targets,
plan hash, selected choice and its transaction. PKCN v11 stores only the matching
plan reference and status. PKEF restore rejects any cross-section mismatch with
`era_reward_cross_section_mismatch`; older PKEF/PKCN streams are rejected with
`catalog_hash_mismatch` rather than redrawing an offer.

Strict peer restore also audits pending external transactions. PKID supplies the
exact transaction IDs and ideology source prefixes it owns; PKEF rejects a
missing/mismatched source as well as any additional pending ideology transaction
for the same country. This prevents an orphaned pre-load transaction from being
silently granted after the ideology state has forgotten it.

Peer runtimes can enqueue a precompiled external command and retain only the
returned transaction ID. `transaction_status_pod()` reports a live state or an
ACKED result through the contiguous durable ACK cursor after ACK compaction;
REJECTED rows remain queryable so a producer (currently ideology progression)
can roll back its local intent instead of treating an unknown transaction as a
successful grant.

`get_effect_report()` exposes catalog hash, instance/transaction counts,
pending ACKs, explicit transaction-state counts, work, elapsed time, behavior
failures, overflow, due/dirty/candidate counts, flat-slab bytes, native Modifier
batch timings, worker planning/serial merge timings, worker/fallback path fields,
the pending idempotency-key count, per-native-adapter pending ACK counts, and last error. `PKEF v9` restore parses into temporary
vectors and swaps only after all bounds, command masks, plan hash and end marker
checks pass, so a truncated save cannot clear the live state.
`explain_effect(instance_id)` reports the resolved program, input revision,
last consumed revision, level, next due day, fire sequence, and condition result.

## Extension procedure

1. Add a Resource field and packed compiler column only at the cold boundary.
2. Add a typed command and domain adapter for new authoritative writes.
3. Use a C++ behavior for algorithms that cannot be represented by bounded IR.
   Register it at native startup and emit through the preallocated bounded
   `BehaviorOutput.emit()` buffer; never mutate a domain from the callback.
4. Add deterministic plan, ACK, overflow, and PKEF round-trip tests.
5. Update the authority matrix, scheduler graph, save-flow document, and this
   document together.

Focused fixtures:

- `Project/project-keynes/tests/effect_runtime_test.gd` — native IR, cursor,
  same-day input-revision replay, parallel declarative planning,
  transaction-state, persistence, and generic adapter protocol.
- `Project/project-keynes/tests/effect_domain_integration_test.gd` — country
  technology activation through Effect → Modifier → ACK, including duplicate
  stack prevention.

- `Project/project-keynes/tests/effect_native_modifier_bridge_test.gd` validates
  C++ Effect-to-Modifier batching and the post-Modifier native ACK boundary.
- `Project/project-keynes/tests/effect_trigger_handoff_test.gd` validates the
  contiguous native Trigger-to-Effect-to-Modifier handoff.
- `Project/project-keynes/tests/effect_lifecycle_test.gd` validates native
  application/removal, independent Modifier cleanup, PKEF tombstones, and
  instance-slot reuse.
- `Project/project-keynes/tests/effect_fallback_adapter_test.gd` validates the
  family/person GDScript compatibility adapters without involving the native
  evaluation hot path.

## Current adapter guarantees

Technology activation is ACK-gated. `NativeCountryRuntime` keeps a completed
technology in its pending bitset until the stable technology Effect instance
has fired and both its permanent Modifier plus `technology.adopted` publication
have reached their owning safe boundaries. Research completion registers that
instance on the same country research day, because Effect (priority 85) runs
before Country (255) on the following morning. A recipe that adds Country/Economy
commands extends the same required ACK mask; the completed bit is written only
after every required adapter ACK.
The country retry does not re-upsert an already existing instance, so the
configured cadence is preserved and a second Modifier stack is not produced.
If Effect registration itself fails, the existing direct Modifier path remains
an explicit compatibility fallback; a merely pending Effect never falls back.

Person programs are compiled as `person.modifier.<modifier_definition_key>`
for existing ECONOMY and GAMEPLAY Modifier definitions. Native person promotion
and `PERSON_COMMIT` currently use `person.modifier.gameplay.generic.bonus`;
`submit_person_modifier_instance()` carries future authored definition keys
into the typed adapter. PersonStore/PERSON_COMMIT remain authoritative.

## Reuse research decision

The prebuild review considered EnTT, Flecs, and Microsoft RulesEngine as
reference patterns. Their dispatcher/observer and compiled-rule ideas informed
the dense IR and adapter split, but none is imported: each would duplicate the
existing DataCore/SUS authority or introduce an object/dynamic-script hot path.
The repository therefore uses a small custom runtime with a narrow, testable
surface.
