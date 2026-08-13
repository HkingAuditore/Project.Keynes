---
name: project-keynes-runtime-hotloop-optimization
description: Diagnose and fix Project.Keynes native runtime hot loops in gdext/src (economy, family, person, building commit stages). Covers how to pick the target and classify a cost as lookup / structural maintenance / compute, the tactic ladder from eliminating work to parallelizing it, the plan-then-replay pattern for stages that mutate shared state, probe placement and the epoch snapshot contract, index-keyed cache invalidation traps, replacing full-table scans with CSR indices plus a migration ledger, measurement noise handling, and the stashed-baseline regression protocol. Use when a stage such as building_commit, person_commit, family_commit, household_market, building_employment, or building_investment is too slow, when deciding whether to index / incrementalize / parallelize, when scan_steps_* counters look inflated, when a perf probe reports zero or an implausible value, or when converting a linear scan into an indexed lookup.
---

# Project.Keynes Runtime Hot-Loop Optimization

Companion to `project-keynes-headless-perf` (how to record) and
`project-keynes-economy-runtime` (what the code means). This skill is about
finding the real cost and not fooling yourself while measuring.

## Pick the target before touching code

**Optimize the worst slice, not the average.** The goal is a smooth 50x on
mobile and in a late game, which is a tail problem. One round of this work moved
total economy CPU by only -3.4% but cut `continuation_max_slice_ms` by -30%
(10.85 -> 7.62 ms), and that is the change the player feels. Rank work by
`continuation_max_slice_ms`, `largest_slice_ms` and per-stage max, not by the
sum.

**Do not trust a stage label until a probe confirms it.** `building_investment`
reported 15.86 ms. Sub-probes showed the stage itself was 5.95 ms (evaluate
5.04, allocate 0.37, prepare 0.55); the missing 9.9 ms was a mislabeled timer
billing `finalize_construction` (8.29 ms) to investment. Parallelizing
investment first would have bought almost nothing. Spend the first build/run
cycle on probes, not on a fix.

**Check whether the hot path is even in the runtime.**
`find_building_group` shows ~360M accumulated scan steps, which looks like the
top offender in a whole-run profile. Per-day it is ~3 calls: all of it is world
generation bootstrap. Always convert cumulative counters to a per-day rate
before ranking.

## Classify the cost, then apply the matching tactic

Each hot stage is dominated by one of three costs, and they want different
fixes. Answer this first; it determines everything downstream.

| Cost | Signature | Tactic |
| --- | --- | --- |
| Lookup | high `scan_steps_*` / `scan_calls_*` ratio, cost scales with table size not with work done | replace the scan with an index (hash map, CSR, stable-id set) |
| Structural maintenance | a full rebuild triggered by a handful of deltas; cost tracks entity count, not change count | make it incremental, or reduce its frequency |
| Compute | scan counters flat, cost tracks the number of entities actually processed | parallelize onto the worker pool |

Worked examples from this codebase: `move_notable_people` was lookup
(672k steps/day over the person table for a per-cohort question -> CSR, 182
steps/day). `rebuild_family_influences` was structural (full recompute every
epoch for rarely-changing data -> run on structure change or every N epochs).
`building_production` and `household_market` are compute and are already on the
worker pool.

## Try the tactics in cost order

1. **Do not do it.** `retire_person` ran an `erase-remove` over the whole
   `_person_needs` vector per retirement (15.93 ms). It became a flag plus a
   deferred single-pass compaction. Deleting work beats speeding it up.
2. **Do it less often.** Gate on a dirty flag, or on
   `(_epoch_id % N) == 0` for data that tolerates staleness. Two of the three
   `rebuild_family_indices()` calls per epoch turned out to be unconditional
   and redundant.
3. **Do it incrementally.** Rebuild only what changed, with a ledger covering
   the gap (see the CSR recipe below).
4. **Use a better algorithm.** `_person_needs` went from comparison sort to
   counting sort on `(person_index, stable_need_id)` — which also fixed a
   latent bug, because the CSR was built assuming index order while the sort
   produced handle order.
5. **Parallelize.** Last resort: it is the only tactic that adds determinism
   risk and merge complexity, and it cannot fix an algorithm that is
   quadratic.

**A large share of "optimization" here is bug-finding.** The building factor
cache was not slow because hashing is expensive; it was missing ~100% because
`_buildings` gets permuted and the cache did not follow. Fixing that identity
bug took it 4.8 -> 1.9 ms. When a cache, a dirty flag or an incremental path
already exists and the stage is still slow, suspect it is silently not working
before you design a replacement.

## Parallelizing a stage that mutates shared state

`building_employment` is serial and ~7-8 ms, but a naive worker split is
unsafe: `run_building_employment_cell` calls
`PopulationStore::allocate_slot`/`release_slot`, `move_family_membership` and
`move_notable_people`, and writes country treasury — all global mutations, some
with their own linear scans.

The pattern that works is **plan then replay**:

- Workers run a pure-read pass per cell and emit an intent buffer (who is
  hired/fired, which slot request, what cost), touching nothing global.
- The main thread replays intents in a fixed cell order and performs every
  allocation and mutation.

Determinism comes from the replay order, not from the worker order. Order
inside the plan is usually free, because the CSR buckets are already sorted by
the same `(stable_id, index)` key these loops use.

Before parallelizing anything, grep the callee tree for `allocate_slot`,
`release_slot`, `_dirty` writes, treasury and market-store writes, and RNG
draws. An RNG shared across workers silently destroys reproducibility even when
the arithmetic is correct.

## Measure with counters, not the clock

Wall-clock run-to-run variance on this project is roughly **±15%**, and can be
far worse. Two back-to-back runs of the **same DLL and same seed** produced
`j_economy_daily_ms` 8.64 vs 6.82 (-21%) and `t_sus_ms` -23.7%, while every
deterministic scan counter moved by under 3%. A single before/after pair of
`j_economy_daily_ms` or `t_sus_ms` proves nothing.

Trust these instead, because they are deterministic for a fixed seed:

- `bd_economy_scan_steps_*` — take the **per-day delta**, the raw column is
  cumulative over the run.
- `bd_economy_scan_calls_*`
- Cache hit/miss counters
- Structural counters such as `building_structure_new_groups`,
  `building_structure_topology_rebuilds`

A ms probe is only credible when a deterministic counter moved with it. When
reporting, lead with the counter and cite the ms as supporting evidence.

This also decides how to batch work. A single sub-1 ms win cannot be validated
by timing at all, only by a counter — so state the expected saving before
building, then either land several small changes together and validate them as
a group, or accept the counter as the sole evidence.

`scripts/compare_perf.py` diffs two `perf_record_*.csv` files and prints both
averaged ms columns and per-day counter deltas:

```powershell
python .cursor\skills\project-keynes-runtime-hotloop-optimization\scripts\compare_perf.py `
  tmp\perf_record_BEFORE.csv tmp\perf_record_AFTER.csv
```

## Probe contract

Adding a probe that reports zero wastes a 60 s build plus a 45 s run. The
plumbing has four steps and skipping any one produces a silent zero.

1. Declare `double _foo_ms = 0.0;` in the private members of
   `NativeEconomyRuntime`.
2. Reset it where the **epoch** counters reset (near
   `_investment_prepare_groups_ms = 0.0;`), not in `run_slice_internal`.
3. Copy it into the `PerfMetrics` snapshot next to
   `snapshot.investment_prepare_groups_ms = ...`. The snapshot assignment ends
   with `_last_completed_perf = snapshot;`.
4. Expose it in `report()` as `out["last_completed_foo_ms"]`.

Two hazards:

- **Per-slice arrays never survive to the snapshot.** `run_slice_internal`
  calls `_building_commit_slice_phase_ms.fill(0.0)` at the top of *every*
  slice, so `building_commit_breakdown_ms` only ever describes the slice that
  just ran. By the time the epoch snapshot is taken the active stage is
  something else and every entry reads 0. Use a dedicated epoch-scoped
  accumulator for anything you want in the CSV.
- **A timer started once and read many times over-counts.** The BUILDING_COMMIT
  phases each end in `continue`, which re-enters the stage block and creates a
  fresh mark, so per-phase attribution is correct there. What was wrong was
  three `_investment_ms += elapsed_ms(...)` lines sitting in the *finalize*
  phase, which billed construction commit time to `building_investment_ms`.
  Before optimizing a stage, confirm the probe measures what its name claims.

The two recording paths do not carry the same columns. `bd_economy_<key>` in a
**headless** CSV comes from the whole `get_economy_report()` dictionary
(`world_runtime_host.gd::get_sim_breakdowns`), so anything added to `report()`
appears automatically. The **graphical player** path goes through
`main.gd` -> `get_economy_perf_report()` -> `economy_daily_system.gd::last_perf_report()`,
which copies an explicit key list. A probe missing from a player recording but
present headless is usually just absent from that list.

## Trap catalog

### Index-keyed caches and array permutation

`_buildings` looks append-only but `rebuild_building_role_storage()` does
`_buildings.swap(_building_groups_rebuild_scratch)`, rewriting the array in
sorted `(cell, type_id, owner_signature_id)` order and dropping empty groups.
Every parallel array keyed by group index must be permuted in the same
`append_group` pass — that is why
`_building_investment_score_q16`, `_building_investment_payback_days`,
`_building_investment_rejection` and `_building_factor_cache` all have a
`*_rebuild_scratch` sibling. A cache that misses this shows ~100% miss rate on
any day a building finishes.

Before adding a new per-group array, grep `append_group` and add it there.

### `assign()` on growth wipes a cache

```cpp
// Wrong: one new group invalidates every entry.
if (cache.size() != _buildings.size()) cache.assign(_buildings.size(), Entry{});
// Right: append defaults, keep existing entries.
if (cache.size() != _buildings.size()) cache.resize(_buildings.size(), Entry{});
```

Pair `resize()` with a full identity check in the entry (`cell`, `type_id`,
`owner_signature_id`), so a slot that does get reused is detected instead of
silently returning another group's value.

### Diagnosing a cache that still misses

Add one counter per comparison field rather than guessing which field is
volatile. That is how `_building_factor_cache` was split into 16,837
identity misses (the permutation bug) versus 5,457 legitimate
`mod_version` misses per day.

## Recipe: full-table scan to CSR plus migration ledger

Applies to `move_notable_people`, `promote_person_for_family`, and any similar
"find all X whose owner is H" loop.

The CSR indices (`_person_cohort_offsets` / `_person_cohort_indices`,
`_person_family_offsets` / `_person_family_indices`,
`_family_cohort_offsets` / `_family_cohort_edge_indices`) are rebuilt at
PERSON_COMMIT / FAMILY_COMMIT and go stale mid-epoch. Do not fall back to a
full scan on staleness; cover the gap with a ledger.

1. Add `std::unordered_map<uint64_t, std::vector<int32_t>> _x_migrations;`
   keyed by the owner handle the entity moved **into**.
2. Record every mid-epoch owner change. Grep for direct writes to the owner
   field first — for persons only `move_notable_people` and
   `promote_person_for_family` assign `cohort_handle`, which is what makes the
   ledger complete.
3. Clear the ledger at the end of the matching `rebuild_*_indices()`, and at
   every site that clears the CSR (reset, reconfigure, restore).
4. Read the CSR span **plus** the ledger bucket, validating each candidate
   against the live fields. Deduplicate with a generation-stamp vector when the
   result is a sum; a max tolerates duplicates but a sum does not.
5. Size-check the slot, do not require an exact CSR length:

```cpp
// The population store keeps allocating slots mid-epoch, so the CSR is
// routinely shorter than the slot table.
const int32_t indexed_slots =
    static_cast<int32_t>(_person_cohort_offsets.size()) - 1;
if (source_slot < indexed_slots) { /* read span */ }
```

An exact `offsets.size() == active.size() + 1` guard sends most calls down the
fallback path and produces almost no win.

Ordering is preserved for free: CSR buckets are already sorted by
`(stable_id, index)`, the same key these loops sort by.

### Identity collision probes

`create_family_for_building` and `promote_person_for_family` resolved hash
collisions by scanning the whole table per probe. Replace with
`std::unordered_set<int64_t>` (`_person_stable_ids`, `_family_stable_ids`),
maintained on assign, on `release`, on reset, and in the save-restore decoder.

For "max disambiguator among same-surname families", bucket by surname
(`_family_surname_members`) and compact lazily on read rather than removing on
retire. Recomputing the max over the bucket keeps behavior identical to the old
full scan, including disambiguator reuse after a retirement.

## Regression protocol

`building_runtime_test` and `modern_economy_runtime_test` have a pre-existing
failure set. Never compare against a remembered count — capture a baseline.

```powershell
git stash push -m baseline -- gdext/src
scons -C gdext target=template_debug platform=windows -j8
# run the tests, save output as tmp\base_<name>.out
git stash pop
scons -C gdext target=template_debug platform=windows -j8
# run again, save as tmp\test_<name>.out
Compare-Object (Select-String tmp\base_X.out -Pattern '\[FAIL\]').Line `
               (Select-String tmp\test_X.out  -Pattern '\[FAIL\]').Line
```

`Compare-Object` returning nothing is the pass condition. Also confirm
population-shaped invariants held steady across the change:
`family_count`, `notable_person_count`, `building_group_count`,
`ledger_failures=0`, `fatal=false`.

`scripts/run_tests.ps1` runs the economy and family suites and prints a
per-suite `[FAIL]` count.

## Environment

- **The headless wrapper can kill its own run.** `run_headless_perf.ps1` sets
  `$ErrorActionPreference = 'Stop'`, so a harmless Godot stderr warning becomes
  a terminating error mid-generation. When that happens, invoke Godot directly:

```powershell
$ErrorActionPreference='Continue'
& $exe --headless --path "Project\project-keynes" `
  --script "res://tests/headless_perf_record.gd" -- `
  days=50 speed=50 seed=20260718 width=96 height=64 `
  population_scale=0 use_saved_setup=false label=probe *> tmp\hp.log
Select-String tmp\hp.log -Pattern 'headless-perf/result'
```

- **The headless editor loads the debug DLL.** `dots_ext.gdextension` maps
  `windows.debug.x86_64` to `template_debug`. Building only `template_release`
  leaves the measurement running on stale code; new probe columns simply will
  not appear in the CSV. Build `target=template_debug` for headless work.
- The Godot console executable path is not the one baked into the wrapper's
  default; pass `-GodotExe` or invoke directly.
- PowerShell has no heredoc. Use `python -c "..."` for one-liners and the
  editing tools for file edits; `python - <<EOF` fails to parse.

## Known remaining hot spots

Measured on a 96x64 map, seed 20260718, ~27k building groups, ~1.4k families,
~1.6k notable persons, per simulated day:

| Area | Cost | Nature |
| --- | --- | --- |
| `household_market_worker_ms` | ~8-10 ms | already parallel |
| `building_employment_ms` | ~7-8 ms | serial; `allocate_slot`/`release_slot` and treasury writes block naive parallelization |
| `building_production_ms` | ~7 ms | already parallel |
| `building_investment_ms` | ~6.5 ms | evaluate ~4.4 ms, per-cell independent, parallelizable |
| `building_role_storage_ms` | ~4.3 ms | full 27k-group rebuild triggered by ~14 new groups |
| `person_commit_index_ms` | ~4.8 ms | CSR rebuild |
| `family_commit_normalize_ms` | ~4.4 ms | edge normalization |

`find_building_group` accumulates ~360M scan steps, but essentially all of it
is world generation bootstrap, not runtime — the runtime rate is ~3 calls per
day. Do not chase it from a runtime profile.
