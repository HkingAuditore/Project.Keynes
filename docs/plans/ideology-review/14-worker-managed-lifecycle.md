# 14 - Worker Effect pod has no managed lifecycle (reviewer, 2026-10-23 21:40)

Found while R was idle (no R-7 output on disk). This is an infra correctness gap on
the production (worker) path, so it goes into the R queue right after R-7 A-D and
before F: F's cell-card acceptance would otherwise pass on equip and silently miss
"condition falls -> row goes away".

## 1. Facts (checked against the tree)

Main thread (`EffectRuntime`), managed programs:

- `uses_managed_lifecycle(def) = lifecycle != 0 || managed_declared`
  (`effect_runtime.cpp:2887`).
- Every ideology program is managed: `ideology_effect_definition.gd:183`
  sets `out.managed = true`, compiled into `managed_flags`
  (`effect_catalog.gd:166`).
- Daily evaluation (`effect_runtime.cpp:5101-5125`):
  - condition fails and the row is applied -> `create_retirement_transaction(...,
    false)` (the Modifier row is removed);
  - condition passes -> a new transaction only when `managed_update_due`
    (not applied yet, `input_revision > applied_input_revision`, or the stack count
    changed). Otherwise it just reschedules. Idle day = 0 transactions.

Worker (`RuntimeEffectPodAuthority`):

- `RuntimeEffectPodDefinition` (`runtime_effect_pod.h:204-237`) has no managed flag;
  `RuntimeEffectPodInstance` (`:296-336`) has no `effect_applied` /
  `applied_input_revision`. The forwarder reads `managed_declared` only for
  row validation (`effect_instance_forwarder.cpp:296-305`), never passes it on.
- `plan_day` (`runtime_effect_pod.cpp:1462-1505`, mirrored in
  `catchup_fire_never_fired_instances` `:707-760`):
  - condition fails -> `latched = 0`, reschedule, `continue`. **No retire.**
  - condition passes -> `execute_program` -> new transaction **every cadence day**
    (`next_due_day = day + cadence_days`, ideology cadence is 1), regardless of
    input revision.
- ACKed transactions are never removed: there is no erase/compaction anywhere in
  `runtime_effect_pod.cpp` (the main thread has `compact_terminal_transactions`,
  `effect_runtime.cpp:4344`). Capacity is 8192 (`runtime_effect_pod.h:36`);
  at the cap `append_transaction` fails with `effect_transaction_capacity_exhausted`
  and `plan_day` returns false, which fails the whole Effect stage.

Measured (reviewer probe, current DLL 17:23:54, 0xFFF worker, 16x12, seed
20261023, `tmp/reviewer/refire_probe*.txt`):

- `effect_pod_intent_count` is 1 on every idle day before any card is equipped,
  and stays 1-2 every day after equipping (days 9-33), never 0;
  (which program fires on the pre-equip days is not attributed yet - it can be a
  non-ideology program; the code path above is the reason it can never reach 0 for a
  managed ideology program either);
- PKSR `effect_bytes`: day 2 = 4520, day 12 = 6540, day 34 = 13936, day 44 = 17432,
  day 64 = 22948 - monotonic, ~200-350 B/day; `modifier_bytes` also keeps growing
  (577 -> 666 -> 755 over days 34-64).
- Side lead for R-7 F (not verified): after equipping `land_value`,
  `three_field_rotation` (selector 12, `cell.sector.agriculture`) and `free_exchange`
  through `submit_ideology_commands` (all `ok=true`, no draw-gate grant),
  `get_ideology_effect_instance_report(handle)` returned `count=0` on day 64. Either
  the equips never landed in the pod (gates), or cell instances are not reported on
  the worker path. F must assert the instance report is non-empty before reading
  cells.

## 2. Consequences

1. Condition-gated cards on the worker never switch off. 21 programs carry
   conditions today: `v1/v3/v4/v5/v6` diagnostics, `hunting_tradition_l1-3`,
   `household_weaving_l1-3`, `guild_charters_l1-3`, `village_compact_l1-3`,
   `land_reclamation_l1-3`, `land_tax_reform_l3`. Once true, the Modifier row stays
   forever (duration -1). Every future X2/X3/X12/X13 threshold card inherits this.
2. Hysteresis (`STATE_LATCHED`, P2-C) is moot on the worker: latch flips, nothing
   follows it.
3. Unbounded transaction log: save size grows every day; a long game (or many
   cadence-1 instances) eventually hits 8192 and the Effect stage stops. Roughly
   8192 / (firing instances per day) days.
4. Idle cost is not zero on the production path (Doc 03 "idle = 0" goal).
5. Same root, unverified: an explicit retire on the worker
   (`EffectInstanceForwarder::retire` -> `queue_effect_pod_remove` ->
   `RuntimeEffectPodAuthority::remove_instance`, `runtime_effect_pod.cpp:602-614`)
   only sets `active = 0` / `retire_requested = 1`; `plan_day` skips inactive
   instances, so no Modifier REMOVE is ever emitted for that instance. Country-row
   unequip works because ideology sends an explicit remove batch
   (`ideology_runtime.cpp:2352-2375`), but per-cell instances (selector 12/14) have
   no such batch. Expect "cell card unequipped, cell factor stays" on the worker. The
   retire transaction from section 3 step 3 (with `retire_instance = true`) fixes both.

## 3. Fix (R)

One concept, mirrored from the main thread. Do not invent a new protocol.

1. POD catalog: add `uint8_t managed` to `RuntimeEffectPodDefinition`, filled from
   the same `managed_flags` / `uses_managed_lifecycle` rule when the pod catalog is
   compiled (`world_ext_effect.cpp` builds it, `:93`). Include it in the catalog hash.
2. POD instance: add `uint8_t effect_applied` and `int64_t applied_input_revision`
   (+ keep `applied_stack_count`). Set on ACK OK of an APPLY transaction
   (`apply_ack`, `runtime_effect_pod.cpp:1620-1633`), clear on ACK OK of a retire.
3. `plan_day` and `catchup_fire_never_fired_instances`, for `definition.managed`:
   - condition fails && `effect_applied` -> emit the same REMOVE command set the
     main thread's `create_retirement_transaction(..., false)` emits (Modifier
     REMOVE by source), as a transaction with `transition_stack_count = 0`;
     `effect_applied` clears on its ACK. Instance stays active (it may re-apply).
   - condition passes -> fire only if `!effect_applied ||
     input_revision > applied_input_revision || stack changed`; otherwise reschedule
     with no transaction.
   - unmanaged programs keep today's behaviour.
4. Compaction: drop ACKED transactions (and their command-arena slices) at the
   end of `commit_day`, like `compact_terminal_transactions`. Keep REJECTED /
   RESYNC until handled. Rebuild offsets; `resolve_modifier_definition_id_for_effect_intent`
   and `reemit_effect_committed_pending_intents` only look at live transactions, so
   they are unaffected.
5. Versions: `RUNTIME_EFFECT_POD_ABI_VERSION` 3 -> 4 (new instance fields in EFP1 and
   in the snapshot wire). `EffectRuntime::apply_pod_snapshot` must carry
   `effect_applied` / `applied_input_revision` into the main-thread instance so an
   authority flip does not re-apply or forget to retire. Old saves fail closed.
6. `runtime_worker_source_scan_test` and `runtime_domain_pod_test` must stay green;
   add pod self-tests: (a) managed instance, condition true 3 days -> 1 transaction;
   (b) then false -> 1 retire transaction, then 0; (c) 100 idle days -> transaction
   count constant.

## 4. Worker acceptance (new test, one process)

`tests/ideology/ideology_worker_managed_lifecycle_test.gd`, 0xFFF worker, same
fixture as `ideology_x16_worker_test`:

1. Equip `village_compact` (condition metric 54 >= 800). Use
   `set_effect_metric_override_for_test` on one owned agriculture cell to force the
   metric above, then below the threshold (this is the condition input, not the
   result under test).
2. Above: `evaluate_modifier_stat(2, 0, cell, "economy.city.building.agriculture_output_factor", 1.0)`
   reads 1.08. Below: reads 1.00 within 3 days. Above again: 1.08.
3. 30 idle days with the card equipped and the metric fixed: `effect_pod_intent_count`
   is 0 on every day after the first apply, and PKSR `effect_bytes` does not grow.
4. Save at "below", restore, step 3 days: still 1.00 (no resurrected row).

Report the raw lines: build tail, pod self-test result, the four assertions, and the
`effect_bytes` series.
