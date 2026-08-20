# Scheduling Save And Verification

## Schedule

`modifier_daily` priority 90 runs before climate 100, country 255, and economy 260:

Keep it `must_run=false`, but set `use_job_deadline_critical=true` and return `should_run(ctx)` from
`is_deadline_critical()`. Due commands/expiry must not be skipped while same-day consumers advance.

1. process expiry;
2. sort due commands by day, producer, sequence, submit order;
3. mutate instances/buckets;
4. publish snapshot versions;
5. let domain consumers read frozen results;
6. publish journal/report.

Do not mutate a store from a worker or domain pass. SHADOW compares output only.

## Save Order

- PKCM v1: Climate store.
- PKCN v11: Country state, technology/research-signal identity, and Country store.
- PKEC v41 / Modifier schema v3: Economy state, family/cell effects,
  BuildingIdentityStore, exact-good/building stat identity, and Economy store.
- PKGP v1: Gameplay identities/base plus Gameplay store.

Restore dynamic world -> environment -> PKCM -> clock -> PKCN -> PKEF -> prepare economy -> PKEC ->
PKGP -> vision/journal/player. Older PKCN/PKEC schemas are rejected. Unknown keys, invalid numeric data,
bad handles, invalid magnitude, and incompatible normalized terms fail. The current domain restore
also requires an exact catalog hash; append-only compatibility needs an explicit migration path.
`persistable=false` is not yet enforced by native serialization.

## Tests

Cover math, magnitude add/factor interpolation, zero factor, non-finite rejection, stack power,
`SET_MAGNITUDE`, expiry boundary, stale heap node,
generation reuse, exact removal, target cleanup, global/group/entity, deterministic producer
ordering, explain recomputation, journal events, domain isolation, climate insertion, economy
actual/forecast parity, Family/Branch stale-handle rejection, exact-good sparse overrides,
Gameplay base/effective separation, and all four save round-trips.

Use `Project/project-keynes/tests/modifier_runtime_test.gd` as the focused entry. Also run country,
building/economy save tests and a Godot project parse.

## Performance

Inspect active/peak/buckets/query/bucket-read/rebuild/snapshot/event/memory arrays, sorted error
counts, and command/expiry/publish/bucket-update/bucket-rebuild times. A hot consumer should not
query strings or parent stores per output line. Final acceptance also records exact-good
shared/non-neutral/override counts and cache bytes, and
requires same-machine 50+ day baseline/after: median regression <= 3 percent and p95 <= 5 percent.
