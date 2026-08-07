---
name: project-keynes-effect-runtime
description: Develop and review Project.Keynes Native Effect Runtime catalog IR, C++ behaviors, effect instances, plans, cross-domain transactions, ACKs, PKEF persistence, scheduling, diagnostics, and domain adapters.
---

# Project Keynes Effect Runtime

Use this skill for any configurable Buff/Effect/Ideology/technology/family/person
effect work that crosses a runtime domain. Read `cpp-dots-runtime-development`,
`project-keynes-runtime-architecture`, `project-keynes-trigger-runtime`, and
`project-keynes-modifier-runtime` first when the change crosses those owners.

## Authority

`EffectRuntime` owns catalog compilation, dense IR, active instance lifecycle,
frozen input revisions, deterministic plans, transactions, idempotency, and
ACK cursors. Country, Economy, Modifier, Trigger, GameplayEventBus, DataCore,
and conserved ledgers keep their existing ownership. An Effect Runtime method
must never write one of those stores directly.

## Hot-path contract

- Compile Resource data into packed columns and dense IDs before simulation.
- Use POD/SoA, Q16 integer arithmetic, fixed stacks, bounded work, and cursors.
- Do not evaluate GDScript, Callable, Godot Object, String, or Dictionary in the
  native evaluation loop.
- Declare metric reads and command domains in the catalog. Reject bad offsets,
  opcodes, capacities, duplicate keys, and invalid targets at configure time.
- Preserve generation and fire-sequence idempotency. Overflow is a diagnostic
  failure, never a silent drop. Propagate target generation with every command;
  an instance generation change rejects its old pending transactions.

## Configuration and C++ behaviors

Use `EffectCatalog` plus `EffectDefinition`, `EffectCondition`,
`EffectInstruction`, and `EffectCommand` Resources for bounded arithmetic and
simple Modifier-like commands. Register open-ended algorithms with
`EffectRuntime::register_behavior()` at compile time. A behavior receives a
frozen `BehaviorInput` and emits POD commands through the preallocated bounded
`BehaviorOutput.emit()` buffer; it must not mutate domains or grow an
unbounded output container.

## Transaction boundary

The required flow is `evaluate -> plan -> adapter preflight -> runtime
PREFLIGHTED -> safe commit -> runtime COMMITTED -> ACK`. Cross-domain
transactions remain pending until every required domain bit is acknowledged.
Known Modifier commands should use the native batch bridge first:
`EffectRuntime::dispatch_native_modifier()` -> `ModifierRuntime` POD enqueue ->
`modifier_daily` -> `ack_native_modifier()`. `EffectFacade` is only the
fallback adapter/transport layer; it must preserve the contiguous cursor and
pass each command's idempotency key to the domain adapter.
Existing technology, family, and person producers are not migrated implicitly.

Current repository migration boundary:

- technology completion registers `technology.<id>` instances and the
  `technology.modifier` adapter emits the existing country Modifier command;
- family branch Modifier reconciliation registers
  `family.modifier.<definition_key>` instances and publishes branch Q16
  magnitude through the `family.magnitude_q16` metric;
- native person promotion and `PERSON_COMMIT` register the current
  `person.modifier.gameplay.generic.bonus` instance; `NotablePersonStore` and
  `PERSON_COMMIT` remain authoritative for people state, ledgers, and structure.

Technology activation is ACK-gated: while a country technology is pending,
`NativeCountryRuntime` waits for the corresponding Effect instance fire to
finish its Modifier transaction. It must not reset an existing instance's
cadence or use the direct Modifier fallback merely because the Effect is still
pending. The direct path is only a registration/configuration failure fallback.
Person instances use precompiled `person.modifier.<modifier_definition_key>`
programs for existing ECONOMY and GAMEPLAY Modifier definitions; an empty
authored key is invalid.

## Scheduling and persistence

Register `effect_runtime` after `trigger_runtime` and before `modifier_daily`.
Use `effect_should_run(day)` and a cooperative `done=false` cursor. Persist
instances, metric snapshots/revisions, program hash, fire sequence, and pending
transactions plus the in-progress candidate list and last consumed input revision
in `PKEF v4`; reject catalog mismatch or truncation. Store a native-bound
`PREFLIGHTED` transaction as `PLANNED`: native Modifier request IDs are not
valid after restart, while the command idempotency key is. A strictly newer metric
revision may re-evaluate once in the same day; unchanged input obeys cadence.
For large declarative batches, workers may read frozen slabs into per-candidate
plans, but a stable serial merge remains the only writer of transactions and
instance state. Behavior callbacks stay serial unless their owner supplies a
thread-safe contract. Report due/dirty/candidate counts, flat metric slab bytes,
dormant scan count, parallel plan/merge path/timings, and native Modifier
dispatch/ACK timings. Keep pending command idempotency and transaction/source
state in native hash indexes; never reintroduce a scan across every pending
transaction in the merge hot path. Use the runtime-wide command arena,
per-transaction `(command_begin, command_count)`, and reusable instance
slots/tombstones rather than an allocation per transaction or permanent
historical instance slots. Batch native Modifier commands by command count up to
`max_native_modifier_commands`, not by a fixed transaction count.

## Required validation

Add focused tests for catalog validation, Q16 arithmetic, condition gating,
stable target/generation, deterministic plan hash, duplicate idempotency,
multi-domain ACK, explicit transaction states, overflow, cursor slicing,
atomic PKEF round-trip/truncation rejection, native-bound restore replay,
instance-slot reuse, and Trigger handoff. Run
`scripts/verify_effect_runtime.ps1`, `git diff --check`, the native build, and
the headless `tests/effect_runtime_test.gd` and
`tests/effect_domain_integration_test.gd` fixtures. Do not claim a performance
regression target without same-machine baseline and after measurements.
