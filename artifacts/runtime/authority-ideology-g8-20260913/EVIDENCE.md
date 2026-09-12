# Ideology G8 ACTIVE — implementation evidence

Date: 2026-09-13
Target mask: `IDEOLOGY = 0x010`, production request `0x876 = 0x866 | 0x010`
(`CLIMATE|COUNTRY|IDEOLOGY|EFFECT|MODIFIER|COMMIT`), missing mask `0x789`.
Switch: unchanged — `runtime_climate_authority_enabled` requests `0x876`.

## What was implemented

Host / worker (`gdext/src`):

- `implemented_domain_mask()` ORs `RuntimeDomainId::IDEOLOGY` (`0x876`).
- `RuntimeIdeologySnapshotRing` + ACTIVE Ideology stage + in-worker Effect ACK
  for Ideology intents after Effect stage.
- Soft-complete Ideology on missing Economy opinion so day-0 cold start cannot
  withhold the whole `0x876` grant.
- `NativeIdeologyRuntime::apply_pod_snapshot` write-back; suppress
  `run_ideology_daily` / sole-writer `submit_ideology_commands`.

GDScript: request `0x876`, snapshot consume + intent pump (ACK `code=0`),
`ideology_runtime_system` no-op when authoritative.

Tests/docs: mask gates `0x876` / missing `0x789`; migration matrix + host docs.

Also fixed Effect intent pump ACK `code` `1→0` (`OK==0`, `RETRY==1`).

## Validation status — PASS

| Check | Result |
| --- | --- |
| GDExtension `template_debug` rebuild | OK |
| `Invoke-RuntimeTests.ps1` | **25/25 PASS** (`tests-run/`) |
| ACTIVE soak 12d `drive=serial` seed 20260913 40×30 | **green** (`g8-active-12-serial/`) |

12-day end-report:

- `authoritative_domain_mask=2166` (`0x876`)
- `ideology_worker_authoritative=true`, `ideology_pod_ready=true`
- `ideology_pod_snapshot_generation=8`, `fallback` empty
- `main_wait_on_sim_us=0`, `worker_fault_count=0`

Optional follow-ups (not blockers for this session): Stage-C2 ideology dual
recording; formal `serial_wait` A/B; UniqueSource Modifier template replay from
POD intents (POD catalog does not carry effect templates).
