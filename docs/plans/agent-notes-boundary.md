# Agent notes — `ideology_boundary_lock_reachability_test.gd`

Date: 2026-11-16
Scope: one failing Godot test. Only
`Project/project-keynes/tests/ideology/ideology_boundary_lock_reachability_test.gd`
was edited. No C++, no `scons`, no `data/**.tres`.

Verdict before: `=== ideology boundary lock reachability: 42 checks, 6 failures ===`
Verdict after: `=== ideology boundary lock reachability: 42 checks, 0 failures ===` (exit 0)

---

## 1. What the 6 failures actually were

All six were downstream of one fact, not six problems:

```
[FAIL] LEG A: idea.public_hygiene is live (location=1) :: location=-1 last_error='' levels=[]
[FAIL] LEG B: idea.public_hygiene is live (location=1) :: location=-1 ...
[FAIL] A: the worker really was running in this leg (ideology pod committed day moved) :: pod_day -1..-1
[FAIL] B: same
[FAIL] LEG A: the same card is live before the measurement window :: live=0 location=-1
[FAIL] LEG B: same
```

`pod_day == -1` for the whole run means **the worker never committed a single ideology
pod day**, so the card could never be equipped and the "worker really was running"
guard fired. The per-day log made that unambiguous:

```
[DAY/A] day=1  ... pod_day=-1 completed_days=1 worker_state=PAUSED
[DAY/A] day=2  ... pod_day=-1 completed_days=1 worker_state=PAUSED
[DAY/A] day=22 ... pod_day=-1 completed_days=1 worker_state=RUNNING
```

The host advanced 22 days; the worker committed **one**, and its `ideology_pod_committed_day`
never left `-1`.

Note on the sibling hint that this might be a no-op wait helper
(`ideology_x3b_cards_worker_test`): checked and ruled out. `[DAY/A] day=7 … day=16`
are printed from inside `WorkerWaitHelper.wait_for(...)`'s step callback, so the wait
really did drive 10 days, and `wait_for` re-evaluates the predicate at the top of every
iteration. The wait was not the bug; the days it drove were.

## 2. Root cause (evidence chain)

### 2.1 The worker parks on day 2 waiting for a Country peer

```
[runtime-day-diag] day=2 preflight=0 missing=4 completed=4091 stages=11/12
                   ... country:0 effect:1 modifier:1 ...            <- only COUNTRY missing
[runtime-day-wait]  day=2 env_day=2 missing=0x4 stall=0x6
                    country=country_worker_peer_results_pending
[country][active]   day=2 failed=country_worker_peer_results_pending input_generation=2
```

`stall=0x6` = `RUNTIME_DAY_STALL_COUNTRY_PEER (0x2) | RUNTIME_DAY_STALL_EFFECT_ACK (0x4)`
(`runtime_pod_protocol.h:47-52`). The park is raised at
`gdext/src/native_simulation_host_country_stage.cpp:683`.

### 2.2 Which peer, and why it stays PENDING

```
[tech-ack-diag/wait]    day=2 intents=1 queued=0
                        [op=1 tech=196 req=1 result=1 intent=1 inst=0x10000000100c5 gen=1]
[tech-ack-diag/unacked] tech=196 fire_seq=-1 acked_seq=-1 next_due=-1 pod_day=1
[tech-ack-diag/unacked] tech=196 fire_seq=1 acked_seq=0 next_due=3652 pod_day=2
                        tx3:st=3 req=0x11 got=0x10
[tech-ack-diag/promote] pending→READY count=1 stall=0x6
```

* `op=1` is `CountryPeerIntentCode::ENSURE_TECHNOLOGY_EFFECT`, `result=1` is
  `CountryPeerResultCode::PENDING`. `queued=0` is expected: with EFFECT granted to the
  worker the intent is resolved **in-worker** (`native_simulation_host_country_stage.cpp:246-248`
  → `resolve_country_technology_effect`, `native_simulation_host_effect.cpp:406-459`), not
  handed to the main-thread adapter.
* `tx3` is the technology effect's transaction: `st=3` = `COMMITTED`, required ack mask
  `0x11` = `MODIFIER_COMMAND (0x01) | PUBLISH_EVENT (0x10)`
  (`RuntimeEffectPodAuthority::adapter_ack_bit`, `runtime_effect_pod.cpp:184-188`).
  `got=0x10`: the EVENTS half is ACKed, the MODIFIER half is not, so
  `effect_pod_instance_fire_acked()` is false and the peer cannot be promoted yet.
* The MODIFIER half is acked by the worker's Modifier stage
  (`native_simulation_host_modifier.cpp:537-539`, then
  `native_simulation_stage_modifier.cpp:83 resolve_pending_country_effect_peers()`).
* **The handshake does work**: the promote above fires and the peer becomes READY. That is
  what proves the peer protocol is not the defect.

### 2.3 Why the promoted result is never consumed — the fixture outruns the day barrier

The promote writes `_country_worker_results[request_id].code = READY` in place
(`native_simulation_host_effect.cpp:617` takes a reference; `:664` mutates it), and the
Country stage re-scans that same table after promoting
(`native_simulation_host_country_stage.cpp:587-631`). So the day *would* close on the next
Country stage visit.

It never gets that visit. The fixture drove the main thread ahead of the worker, and once
the host published later environments the retried day failed the climate gate **before**
the Country stage ran:

```gdscript
# native_simulation_host_country_stage.cpp:85-88
if (climate_authority_requested && !active_climate_ok) {
    stage.completed = 0;
    return true;              // Country stage skipped
}
```

Measured symptom of the overrun:

```
[capture] result day=6 ok=false code=climate_environment_pending
[runtime-day-wait] day=2 ... ring=3 country=country_worker_peer_results_pending
```

The Climate ring filled because the worker never consumed past day 2, so capture for day 6
could never publish, so the worker's input could never be repaired. Deadlock, but a
**fixture-induced** one: the state was reached by calling `run_daily_tick` 20 times without
waiting, while forcing `clock.current_day` directly on a paused `WorldClock`.

In the game this cannot happen: `WorldClock` holds the next day behind the day barrier
until the worker has committed the published one, and `WorldRuntimeHost._process` pumps the
Country peer transport / Effect+Modifier settle while it waits. Every other worker fixture
inherits that behaviour through `WorkerWaitHelper.drive_worker_day` → `wait_committed`,
which calls `host._process(0.0)` in its service callback. This fixture was the one that
drove days and did nothing in between.

## 3. The fix (test file only)

`_step_day()`, immediately after `host.finish_daily_tick(0.0, {})`:

```gdscript
var committed := WorkerWaitHelper.wait_committed(host, ext, maxi(0, day - 1),
        DAY_COMMIT_GUARD_MS)
```

plus `const DAY_COMMIT_GUARD_MS := 8000` and a rate-limited (3 per leg) diagnostic line when
the wait misses, printing `code`, `committed_day`, `day_stall_reason_mask` and
`day_wait_missing_mask`. `WorkerWaitHelper.wait_committed` does **not** pause the worker
(only `drive_worker_day` / `_wait_pod_day` call `set_runtime_clock(false, …)`), so the
deliberate "no pause between the day step and the refresh call" property of the file is
preserved:

* Leg A still fires its 8 refresh calls back to back with no `OS.delay_msec`, no `await`,
  no `process_frame` between them.
* Both legs remain byte-identical in their day step.
* No threshold, no assertion, no mask, no catalog value changed.

The header was extended with "WHY THE DAY STEP WAITS FOR `wait_committed(day - 1)`" and a
2026-11-16 re-measurement block, because the file documents its measurements in prose and
the old prose (25/48 acquired) was taken from a worker that had not advanced.

## 4. Measured after the fix

```
[DAY/A] day=1  ... pod_day=-1 ...                   (boot day, worker committed day 1)
[DAY/A] day=2  ... pod_day=-1 completed_days=1 worker_state=PAUSED
[DAY/A] day=3  ... pod_day=2  completed_days=2 worker_state=PAUSED
[DAY/A] day=7  ... pod_day=6  completed_days=6 worker_state=PAUSED
[DAY/A] day=15 ... pod_day=14 completed_days=14 worker_state=PAUSED
[LEG A] card idea.public_hygiene equipped=true live_cards=1 day=9
[LEG B] card idea.public_hygiene equipped=true live_cards=1 day=9
[COMPARE] LEG A (synchronous, no yield): calls=48 inflight=0 acquired=48 lock_skips+=12
          host_skips=12 max_consecutive=3
[COMPARE] LEG B (polled, OS.delay_msec(2)): calls=6 inflight=0 acquired=6 lock_skips+=12
          host_skips=12
[COMPARE] LEG B first non-inflight call: day=10 attempt=1
=== ideology boundary lock reachability: 42 checks, 0 failures ===
```

(`pod_day == day - 1` from day 3 on; the day-2 line is sampled before the worker first
commits an ideology pod day, so `-1` there is correct, not a stall.) No `[STEP/...]`
lockstep-miss line was printed in either leg: every wait succeeded on the first try.

Sign-level reading (the assertions test signs, per the file header):

* the boundary lock **is** reachable from GDScript (`acquired = 48` and `6`);
* a synchronous no-yield drive reaches it too, so the original premise stays falsified —
  `economy_day_inflight` is live contention, not the normal answer;
* `lock_skips += 12` with `host_skips == lock_skips` in both legs: all 12 skips in the
  windows came from the production call site inside `run_daily_tick`, none from this
  fixture's own calls.

## 5. Things deliberately NOT changed

| Candidate | Why not |
| --- | --- |
| `MASK_ALL` 0xFFF → 0xF7D | Trips the file's own consistency assertion; mask is documented as 0xFFF in the banner. Not the cause. |
| `{"op": 8, "idea": dense, "value": 0}` → a real understanding value | The failing assertion was `location == 1` (equipped), not a level. Understanding does not gate equipping; `ideology_x8_worker_test` needs `8 * Q16_ONE` only to reach the row that carries programs. Left alone after the stall was fixed, and the card equips at L1. |
| `_ack_effect_transactions` every day | The Effect transaction belongs to the worker-owned Effect POD, and `ack_effect_transactions` acks the *sync* `EffectRuntime`, not the POD. It would not have addressed `tx3`. |
| Removing/loosening any `_expect` | Not needed. The 42 checks pass unchanged. |
| C++ / `scons` | Out of scope by instruction; not required — see §6 for the residual observation. |

## 6. Residual product observations (not required for this test, worth a look)

These did **not** block the test after the fixture fix, and none of them is a change I made.
Recording them because they were measured, not suspected:

1. **No recovery from a promoted peer once the input generation moves on.** A Country day
   that parked on `country_worker_peer_results_pending` stays parked while
   `active_climate_ok` is false, because the climate gate returns before the Country stage
   can consume the promoted result (`native_simulation_host_country_stage.cpp:85-88`). Under
   the production day barrier the input is never superseded, so this is unreachable in game;
   a defensive re-check of promoted peers before the climate gate would make the worker
   recover instead of relying on the host not to overrun.
2. **The MODIFIER ack of a technology effect transaction can lag a day.** In this run it
   arrived via the Effect stage's soft-skip re-emit path
   (`native_simulation_host_effect.cpp:44-134` → `reemit_effect_committed_pending_intents`
   → Modifier stage), which is the documented design ("Modifier ACK of Effect catchup fires
   unlocks Country tech peers", `native_simulation_stage_modifier.cpp:82`). It works; it is
   just not same-visit.
3. `country_worker_peer_results_pending` is a *park*, not a fault: it sets
   `commit.continuation_pending = 1` and returns false (`native_simulation_host_country_stage.cpp:683-686`),
   which is why the run produced no `fault_code` and no stall timeout despite
   `PK_PEER_STALL_TIMEOUT_MS=120000`. Anyone debugging a similar park should look at the
   per-day `[tech-ack-diag/unacked]` line, not at `fault_code`.

## 7. How to reproduce / verify

```
$env:PK_PEER_STALL_TIMEOUT_MS="120000"
& "D:\Godot\Godot_v4.6.2-stable_win64.exe\Godot_v4.6.2-stable_win64_console.exe" `
  --headless --path "D:\Godot\ProjectKeynes\Project.Keynes\Project\project-keynes" `
  -s tests/ideology/ideology_boundary_lock_reachability_test.gd
```

Verdict is the `N checks, M failures` line. Runtime is dominated by the two worker
worlds' generation (a worker world costs ~170 s to build); the added lockstep wait costs
milliseconds per day when the worker is healthy, and its 8 s guard only bites when the
worker is actually stuck — in which case it prints why instead of silently measuring a
worker that is not running.
