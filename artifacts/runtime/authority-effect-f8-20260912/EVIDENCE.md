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
**Not run in this session** (visible Debug client ACTIVE/OFF TileDataRecorder SOP).

Comparator + policy are ready:
- `TileDataRecorder` emits `EffectClientEvidence` (alongside `ModifierClientEvidence`)
- `authority-stage-c-field-policy.json` → `effect_evidence`
- `compare_authority_stage_c_tiles.py` → `compare_effect_evidence` (undeclared diffs = blocker)

When C2 is recorded, use same seed/absolute tick window and compare via
`tools/runtime/Compare-AuthorityStageCTiles.ps1`. Measured soak shows ACTIVE
generation advances while OFF stays at 0 — declare any expected generation
divergence in policy before treating C2 as green.
