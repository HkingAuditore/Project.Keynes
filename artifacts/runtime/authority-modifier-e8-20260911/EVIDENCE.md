# E8 Modifier ACTIVE evidence — 20260911

## Scope
Production Modifier ACTIVE grant (`CLIMATE|COUNTRY|MODIFIER|COMMIT = 0x846`).
Does **not** include F8 Effect ACTIVE.

## Automation
`tools/runtime/Invoke-RuntimeTests.ps1` → **24/25** then isolated re-check:

| Test | Result |
| --- | --- |
| `runtime_modifier_pod_test` | PASS (suite) |
| `runtime_effect_pod_test` | PASS |
| `runtime_protocol_guard_test` | PASS (`0x846` / missing `0x7B9`) |
| `dots_completion_gate` | PASS |
| `runtime_climate_*` / save / thread isolation | PASS |
| `runtime_country_parity_test` | suite once `exit=-1` (empty markers); **isolated PASS** 33/0 |

## Headless soak (ACTIVE vs OFF)
Directory: `artifacts/runtime/authority-modifier-e8-20260911/`

| | ACTIVE (`active-30`) | OFF (`off-30`) |
| --- | --- | --- |
| seed / map / days | 20260911 / 40×30 / 30 | same |
| `authoritative_domain_mask` | **2118 (`0x846`)** | 0 |
| `modifier_worker_authoritative` | **true** | false |
| `modifier_pod_ready` | true | true |
| `modifier_pod_snapshot_generation` | **23** (advances) | 0 |
| `modifier_pod_fallback_reason` | empty | empty |
| `main_wait_on_sim_us` | 0 | 0 |
| `worker_fault_count` | 0 | 0 |
| `first_bad_tick` / writeback drops | -1 / 0 | -1 / 0 |

Summary JSON: `e8-soak-modifier-summary.json`.

## C2 client dual-recording
**Not run in this session** (visible Debug client ACTIVE/OFF TileDataRecorder SOP).

Comparator + policy are ready:
- `TileDataRecorder` emits `ModifierClientEvidence`
- `authority-stage-c-field-policy.json` → `modifier_evidence`
- `compare_authority_stage_c_tiles.py` → `compare_modifier_evidence` (undeclared diffs = blocker)

When C2 is recorded, use same seed/absolute tick window and compare via
`tools/runtime/Compare-AuthorityStageCTiles.ps1`. Measured soak shows ACTIVE
generation advances while OFF SHADOW may stay at 0 — declare any expected
generation divergence in policy before treating C2 as green.
