# ideology_tag_snapshot_stress_test — root causes and fix

Status: **fixed**. `=== ideology tag snapshot stress: 38 checks, 0 failures ===`
(was `38 checks, 2 failures`). Check count unchanged — no assertion was weakened,
added or removed.

> 2026-11-16 follow-up: the four product gaps this round recorded at the bottom are
> fixed in C++, and this fixture now also asserts them — `43 checks, 0 failures`
> (the original 38 untouched). See "2026-11-16 follow-up" at the end of this file.

File touched: `Project/project-keynes/tests/ideology/ideology_tag_snapshot_stress_test.gd`
only. No C++ / no `scons` / no `data/**.tres` change.

Reproduce:

```powershell
$env:PK_PEER_STALL_TIMEOUT_MS="45000"
& "<GODOT_BIN>" `
  --headless --path "<repo>\Project\project-keynes" `
  -s tests/ideology/ideology_tag_snapshot_stress_test.gd
```

Verdict is the `N checks, M failures` line; the process exit code is always 1.

---

## Summary

The tag machinery was **never** the problem. Every measurement of the tag layer
passed from the start:

* `tag_snapshot_needed=true`, `consumer_tag_ids=1`;
* `tag_snapshot_builds=31` (one per committed epoch), `tag_snapshot_skips=0`,
  `tag_snapshot_miss_count=0`, concurrent writes 0;
* the direct selector probe flipped correctly:
  `[probe d1] tagged_cells=0` → `[probe d15] tagged_cells=6` → `[probe d30] tagged_cells=6`;
* `tag_revision` 1 → 2 at the flip, and the card's activation signature changed
  with it (`4115825120105921287` → `-6040816621929935228`).

The two failures were two **fixture** defects stacked on top of each other, each
of which alone was enough to make the card resolve nothing.

---

## Root cause 1 — the fixture's own worker request suppressed the main-thread ideology day

The fixture started the worker with `authoritative_domain_mask: 0x10` (IDEOLOGY)
and then relied on `run_ideology_daily` on the main thread, gating that call on
`get_runtime_thread_report().authoritative_domain_mask & 0x10`.

That gate reads the *achieved* mask. The product gate is different:

`NativeSimulationHost::domain_main_thread_suppressed()` (`native_simulation_host.h:1113`)
is suppressed when the domain is authoritative **or** when it was *requested* and
the worker is alive (`STARTING/RUNNING/PAUSED/SAVE_PENDING`). That is the
deliberate "authorization window": while the worker has asked for a domain, the
main thread must not push into it.

This fixture can never *grant* a domain (the grant needs one fully committed day,
and a bare `DCWorldExt` world has no climate trace), so with `0x10` requested the
window opened at `start_runtime_worker` and **never closed**. `run_ideology_daily`
therefore answered `{suppressed: true, path: "IDEOLOGY_WORKER"}` on every one of
the 30 days.

Measured before the fix:

```
[diag d1 ] managed=0        collect_entries=0   cmds_applied=0  rejected=0
[diag d15] managed=0        collect_entries=0   cmds_applied=0  rejected=0
[diag d1 ] inst_count=-1 (ideology_country_unknown -> _countries empty)
[diag d1 ] refresh visits=0 skips=0 passes=0
```

12 staged commands (6 DISCOVER + 6 EQUIP, `pending: 12`) sat in the queue forever:
the card was never equipped, `_level_managed` had no managed level, no selector
ever ran, and `tag_changes` could not move no matter what the tag bits did.

**Fix:** request `0x2` (CLIMATE) instead of `0x10`. CLIMATE is a domain this
fixture never drives from the main thread, so requesting it keeps a live worker
thread (the boundary lock `step_ideology_instance_refresh` takes is still a real
lock) while leaving IDEOLOGY to the main thread — which is the authority split the
assertions actually measure. With CLIMATE in the mask the worker becomes
`climate_driven` and parks in the control wait (no climate trace), so it holds no
boundary lock; the lock assertions tolerate that by design (`lock_skips >= 0`,
`max_consecutive <= 12`) and measured `0`.

After: `cmds_applied=12`, `managed=6`, `backend=DerivedCell`, `own_pushed_raw`
6 → 636 across the run.

## Root cause 2 — the effect condition read the wrong metric (dense vs key indexing)

This is the defect that actually kept `front_cells` at 0 even after the card
equipped.

`effect_catalog.compile_native_catalog` resolves a **tag row** by metric *key*
(`"cell.population"` → runtime id 9) but a **condition row** by *dense index* into
`metric_keys`. The fixture built its condition with `gate.arg0 = 0`, commented as
"dense id of TAG_METRIC_KEY". That was correct while `metric_keys` was a
one-entry list, and became wrong when the fixture switched `metric_keys` to the
**production** table (`_production_metric_keys()`, needed so the tag row's dense
index equals `FamilyEffectMetricId`) — in that table `cell.population` is index 9.

So the program's own condition evaluated `metric_keys[0] >= 400 << 16`, a metric
that is constant here, and was therefore FALSE on every cell. Consequences,
measured:

* `collect_derived_emitted=0` for the whole run (the per-target condition filtered
  every target before the derived contribution was built);
* `derived_materialize_report` all zeros, `derived_cell_layer.installed=false`,
  `cell_count=0`;
* `instances=0` — and legitimately so, because I01 routes `SELECTOR_OWN_TERRITORY`
  (kind 12) to the DerivedCell backend, so the instance path emits nothing for it
  (`collect_effect_activations`, the `derive_this_program && out_derived == nullptr`
  branch);
* the fingerprint that named the bug: the consumer mask carried the wrong bit.
  `metrics[0].revision` went 0 → 1 while `metrics[9].revision` stayed 0
  (`metric_head=[1,0,0,...]`). A condition on `cell.population` must move
  `metrics[9]`.

**Fix:** derive the index from the same table the catalog ships.

```gdscript
gate.arg0 = _metric_dense_index()   # finds TAG_METRIC_KEY in _production_metric_keys()
```

After: `derived_emitted=36` at the flip day and 576 by day 30, and
`metrics[9].revision` 1 → 2 at the flip.

## Root cause 3 — the drain was asked for the wrong day

`drain_derived_cell_layer(0)` was called before reading the layer.
`step_derived_rebuild` treats `day != _derived_rebuild_day` as "the epoch's inputs
changed, splicing two days together would be wrong" and **resets the entire job**
(`_derived_rebuild_contributions.clear()`, `_derived_rebuild_job.reset()`). Asking
for day 0 after a rebuild had been started for day 30 threw the in-flight fold
away and returned `complete: true` with nothing installed — which reads as
"the layer is empty" rather than "the caller reset it".

**Fix:** drain with `MEASURED_DAYS` (the day the rebuild belongs to).
After: `[drain d30] steps=1 complete=true layer_installed=true` and
`front_cells=36` (6 countries × 6 tagged cells).

---

## Final measured result

```
[probe d1 ] tagged_cells=0 untagged_cells=6
[probe d15] tagged_cells=6 untagged_cells=6
[probe d30] tagged_cells=6 untagged_cells=6
refreshes=240 inflight_skips=0 lock_skips=0 max_consecutive_skips=0
tag_changes=0 misses=0 tag_needed=true
snapshot_builds=31 snapshot_skips=0 concurrent_writes=0
refresh_visits=6 refresh_skips=6 refresh_passes=2
instances before_flip=0 after_flip=0
[drain d30] steps=1 complete=true layer_installed=true
after flip: instances=0 front_cells=36
[OK] tag flip is observed by target resolution (instances=0 front_cells=36 expected>=192)
[OK] cell targeting tracked the tag change (tag_changes=0 changes)
=== ideology tag snapshot stress: 38 checks, 0 failures ===
```

Both assertions are satisfied through the `front_cells > 0` disjunct, which the
test was already written to accept ("I01: a SELECTOR_OWN_TERRITORY program is
DerivedCell, so it contributes FRONT ROWS and creates no instances"). Assertion
text, thresholds and check count are untouched.

Note `tag_changes=0` and `instances=0` are **correct** for this backend: with I01
in force a kind-12 card produces zero instances, so an instance-count-derived
`tag_changes` can only ever be 0. Only the currently-shipped `front_cells > 0`
half of that assertion can pass, and it does.

---

## Observations for the product owners (all four fixed on 2026-11-16)

These are honest gaps the debug round exposed. None blocked the test once the
fixture was correct, but each one cost a round of investigation:

1. **Swallowed reconcile error in the refresh path.**
   `NativeIdeologyRuntime::step_effect_instance_refresh` calls
   `reconcile_effect_activations(country, state, day, ignored)` with a local
   `std::string ignored` (`ideology_runtime_effects_derived.cpp:571`). A failed
   `submit_instances` (`effect_instance_columns_invalid`, a rejected row, …) is
   therefore completely invisible: the visit is counted, nothing is created, and
   `get_ideology_report()["last_error"]` stays empty. Storing it in `_last_error`
   (as the command path already does) would make "the card matched cells but
   produced no instances" diagnosable from the report.

2. **`cell_layer_collect_count` / `_rows` / `_ideas` are dead counters.**
   `_derived_collect_count` is declared (`ideology_runtime.h:1434`), initialised to
   0, and exported (`ideology_runtime_queries.cpp:843`), but **never written**.
   The report therefore always says `cell_layer_collect_count=0`, which reads as
   "the collect step never ran" — it sent this investigation down a false trail.
   Either increment it at the collect site in `step_derived_rebuild` or delete the
   field; a permanently-zero diagnostic is worse than none.

3. **`authoritative_domain_mask` vs `domain_main_thread_suppressed` is a trap for
   fixtures.** A test that asks the worker for a domain it can never be granted
   silently loses that domain on the main thread forever, with no error anywhere.
   Consider exporting the suppressed state (or the requested mask) on
   `get_runtime_thread_report()` next to `authoritative_domain_mask`, so a fixture
   can tell "the worker owns it" from "the worker is blocking it".

4. **`drain_derived_cell_layer(day_index)` silently resets on a day mismatch.**
   Returning `{ok: true, steps: 1, complete: true}` after discarding the job makes
   a caller's wrong argument look like success. Reporting
   `{reset: true, reason: "day_changed"}` would have turned a silent empty layer
   into one obvious line.

---

## 2026-11-16 follow-up: all four are fixed, and this fixture asserts them

This is the first change to product code in this file's subject. Four independent
defects, each one "a failure that reads as success":

* **1 (swallowed reconcile error).** `step_effect_instance_refresh` and
  `reconcile_country_effect_activations` now record the reason in `_last_error` and
  count it in the new `effect_reconcile_failures` (exported from
  `get_ideology_report()`). Counter and string are separate on purpose: `last_error`
  is sticky and gets overwritten, so "did this ever fail" needs a number.
* **2 (dead collect counters).** Written at the collect site in
  `step_derived_rebuild`, with a fixed meaning each: `count` = target-cell rows
  handed to the fold, `rows` = distinct (country, card, level, program) rows,
  `ideas` = cards that emitted at least one row. They are reset with
  `_derived_collect_ms`, so a refused collect reads 0 instead of last day's numbers.
* **3 (mask trap).** `get_runtime_thread_report()` (also the start reply,
  `thread_report` and the perf snapshot) now exports
  `main_thread_suppressed_domain_mask`, `authority_window_domain_mask` and a named
  `authority_window_blocker`. The masks are computed by calling
  `domain_main_thread_suppressed()` itself, twelve times, so they cannot drift from
  the gate that suppresses work.
* **4 (silent drain reset).** `drain_derived_cell_layer(day)` reports
  `reset: true, reason: "day_changed", discarded_day, requested_day`, and surfaces
  the step error it used to drop as `error`.

New assertions in this fixture (the original 38 checks are untouched; 38 → 43):

* the requested domain is blocked, not owned: `suppressed=0x802 window=0x802
  granted=0x0` (0x2 CLIMATE and the 0x800 COMMIT the host adds to any ACTIVE
  request; IDEOLOGY is NOT in the window, which is why the main thread keeps it);
* the open window names its blocker: `awaiting_first_commit`;
* the drain that matches the in-flight day reports `reset=false`;
* a drain for a different day reports
  `reset=true reason=day_changed discarded=31 requested=30` — the exact argument
  mistake this file made in root cause 3.

`=== ideology tag snapshot stress: 43 checks, 0 failures ===`

---

## What was tried and rejected

* `PK_TAG_FORCE_ALL=1` — irrelevant; the consumer narrowing was already correct
  (`tag_ids=[0]`, `active_tags=1`, bits set). Confirms the previously recorded
  measurement.
* `set_cell_tag_override_for_test` instead of moving `cell.population` — would
  have moved the tag bits but **not** the program's own condition (which samples
  `cell.population` through the metric override), so the fix would have papered
  over root cause 2 rather than fixing it. The metric-override flip exercises both
  the tag table and the condition, which is what the test is for.
* Treating `refresh_skips=6` as a signature bug — the signature does change at the
  flip (`compute_idea_activation_signature_for_test` differs before/after); the
  skip is the *pre*-flip pass and the post-flip pass visits all 6 countries.
