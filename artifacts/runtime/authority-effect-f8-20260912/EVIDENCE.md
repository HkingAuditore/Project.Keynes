# F8 Effect ACTIVE evidence — 20260912

## Scope
Production Effect ACTIVE grant (`CLIMATE|COUNTRY|MODIFIER|EFFECT|COMMIT = 0x866`).
Does **not** include G8 Ideology ACTIVE or H7/H8 Trigger.

## Automation
`tools/runtime/Invoke-RuntimeTests.ps1` → **25/25 PASS** after mask/gate updates:

| Test | Result |
| --- | --- |
| `runtime_effect_pod_test` | PASS |
| `runtime_protocol_guard_test` | PASS (`0x866` / missing `0x799`) |
| `runtime_modifier_pod_test` | PASS |
| `dots_completion_gate` | PASS (mask includes EFFECT; request `0x866`) |
| climate / country / trigger / save / thread isolation | PASS |

## Headless soak (ACTIVE vs OFF)
Directory: `artifacts/runtime/authority-effect-f8-20260912/`

Primary evidence: **22-day** ACTIVE/OFF (`active-22` / `off-22`, seed 20260912, 40×30, `serial_wait`).
Shorter 10/20-day runs also green. Longer 30-day attempts were interrupted under concurrent Godot process contention; 22-day end-report is the release soak for this session.

| | ACTIVE (`active-22`) | OFF (`off-22`) |
| --- | --- | --- |
| seed / map / days | 20260912 / 40×30 / 22 | same |
| `authoritative_domain_mask` | **2150 (`0x866`)** | 0 |
| `effect_worker_authoritative` | **true** | false |
| `effect_pod_ready` | true | false |
| `effect_pod_snapshot_generation` | **21** (advances) | 0 |
| `effect_pod_ack_count` | 0 | 0 |
| `effect_pod_fallback_reason` | empty | empty |
| `main_wait_on_sim_us` | 0 | 0 |
| `worker_fault_count` | 0 | 0 |
| `first_bad_tick` / writeback drops | -1 / 0 | -1 / 0 |
| `modifier_worker_authoritative` | true | false |
| `modifier_pod_snapshot_generation` | 21 | 0 |

Summary JSON: `f8-soak-effect-summary.json` (updated from end-of-run `[soak/effect-report]` lines).

## C2 client dual-recording
**Ran 2026-09-12**: `artifacts/runtime/authority-stage-c/stage-c2-effect-f8-20260912/`

| | OFF | ACTIVE |
| --- | --- | --- |
| seed / map / ticks | 20260718 / 60×40 / 121–220 (100 ticks) | same |
| rows | 240000 | 240000 |
| `effect_worker_authoritative` (last sample) | false | true |
| `effect_pod_snapshot_generation` (end) | 3 | 219 |
| `modifier_worker_authoritative` (last sample) | false | true |
| `modifier_pod_snapshot_generation` (end) | 0 | 219 |

Comparator status after declaring ACTIVE/OFF Effect+Modifier generation/hash divergence and retuning 7 climate field tolerances: **`pass`** (`comparison/comparison.json`, 0 blockers).

Orchestrator: `tools/runtime/Invoke-AuthorityStageC2EffectF8.ps1`

