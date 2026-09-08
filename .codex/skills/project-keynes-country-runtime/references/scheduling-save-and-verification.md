# Scheduling, save, and verification

As of 2026-09-08, the exact schemas are PKCN v13, PKEF v11, PKTR v6, and PKEC v51. PKCN restores
before PKEC; incompatible Country, Effect, Trigger, technology, signal, recipe, or content-binding
identity is rejected explicitly. Version numbers here describe the current tree, not a compatibility
promise for future schemas.

## Scheduler contract

Register `country_daily` at priority 255 before `economy_daily` at 260. Use `must_run=false` and
`use_job_should_run=true`; with no due command it must not consume a slice. Native stages are
`command_preflight -> command_apply -> aggregate_publish` and report cursor, changed cells/countries,
generation/hash, timing, pending latency, barrier, and publication.

If a due atomic batch needs multiple real frames, retain staged state and request
`country_day_barrier`. Economy may not open a new frozen cycle until that country batch commits.

For large territory batches, submit commands in ascending cell order when possible. The native
runtime recognizes unique sorted `TRANSFER_TERRITORY` batches and uses a direct sparse publication
path; mixed or duplicate-cell batches retain the general staged-delta validation path. Territory-only
batches do not clone technology or treasury matrices because they cannot mutate either matrix.

## Save boundary

PKCN v13 is the canonical Country payload. It contains catalog/content identity, country records,
territory, technology/discovery/pending state, sparse research and signal evidence, treasury, tax
policy, pending commands, era reward reference, and the Country Modifier subdomain. CPD2 ABI v2
wraps the exact same PKCN bytes plus session, command watermark, request state, terminal receipts,
event cursor, and boundary cursor. PKSR v2 carries CPD2 under section bit `0x8`; the standalone PKCN
provider reuses the embedded bytes rather than encoding Country a second time.

Save only when Country has no due batch, same-day ACK chain, or open boundary and Economy is at a
committed boundary. Restore PKCN/CPD2 first, then PKEC. Validate cell/good/technology/signal catalogs,
Country generation/day/hash, protocol metadata, chunk truncation, and restore order. Decode Country
and its Modifier subdomain into isolated staging copies; install only after all checks pass. The
current PKEC reader accepts only schema v51 and reports `economy_save_price_v6_requires_new_game`
for schema mismatch; do not silently synthesize countries.

PKFG v1 is not country authority, but it is ordered against it: fog restore follows PKCN because
re-solving visibility reads the restored territory. It persists only the monotonic `cell_explored`
array; current visibility and `fog_k` are derived and are recomputed through
`WorldRuntimeHost.refresh_country_visuals()`. Never fold exploration progress into PKCN. See
`docs/cpp-dots-runtime/vision-fog-and-borders.md`.

## Acceptance matrix

- Bootstrap: default, multi-country CSR, unowned land, enclave, water/duplicate rejection, all-water.
- Commands: deterministic order, atomic create+territory, rename, last-territory guard, stale handle.
- Technology: nationwide uniform result, unowned false, next-cycle visibility only.
- Treasury: both transfer directions, caps, bad handles/markets, exact combined conservation.
- Save: PKCN/PKEC and PKSR/CPD2 round trip, shared canonical PKCN bytes, truncation,
  catalog/hash/generation/order mismatch, atomic rejection, future-command and event-cursor recovery.
- Vision: PKFG `explored` round trip; after restore, visibility and border mesh match the territory.
- UI: 1280x720 no horizontal clipping, Chinese compact money, stable tabs/scroll/node count.
- Runtime: debug/release build, focused and existing tests, 30+ ACTIVE ticks, no fallback.

Performance gates in release:

- idle country fast-tick increment below 0.05 ms;
- 100k cells / 512 countries / 200 goods / 4096 technologies below 8 MB incremental memory;
- 100k-cell transfer plus CSR rebuild/publication p95 below 5 ms;
- existing economy benchmarks regress no more than 10%, with scalar/worker hashes equal and audit
  errors `0/0/0`.
