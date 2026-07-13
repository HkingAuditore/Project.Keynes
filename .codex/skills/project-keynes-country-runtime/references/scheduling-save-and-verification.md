# Scheduling, save, and verification

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

PKCN v1 contains catalog identity, country records, territory, technology, goods treasury, pending
commands, and an end marker. PKEC v11 contains no global treasury or per-cell technology; it records
the matching PKCN schema, generation, and hash plus domestic in-flight trade orders/escrow. Country
changes only affect new routes; dispatched orders do not mutate PKCN.

Save only when country commands are idle and economy is at a committed boundary. Restore PKCN first,
then PKEC. Validate cell/good/technology catalogs, country generation/hash, chunk truncation, and
restore order. PKEC v10 migrates with empty trade state; v2-v9 must return
`legacy_countryless_economy_save_unsupported`; do not keep a
compatibility decoder that silently synthesizes countries.

## Acceptance matrix

- Bootstrap: default, multi-country CSR, unowned land, enclave, water/duplicate rejection, all-water.
- Commands: deterministic order, atomic create+territory, rename, last-territory guard, stale handle.
- Technology: nationwide uniform result, unowned false, next-cycle visibility only.
- Treasury: both transfer directions, caps, bad handles/markets, exact combined conservation.
- Save: PKCN/PKEC round trip, truncation, catalog/hash/generation/order mismatch, legacy rejection.
- UI: 1280x720 no horizontal clipping, Chinese compact money, stable tabs/scroll/node count.
- Runtime: debug/release build, focused and existing tests, 30+ ACTIVE ticks, no fallback.

Performance gates in release:

- idle country fast-tick increment below 0.05 ms;
- 100k cells / 512 countries / 200 goods / 4096 technologies below 8 MB incremental memory;
- 100k-cell transfer plus CSR rebuild/publication p95 below 5 ms;
- existing economy benchmarks regress no more than 10%, with scalar/worker hashes equal and audit
  errors `0/0/0`.
