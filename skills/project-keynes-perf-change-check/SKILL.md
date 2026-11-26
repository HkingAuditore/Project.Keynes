---
name: project-keynes-perf-change-check
description: Verify a Project.Keynes performance change before it is called done. Use when a ticket, PR or commit claims the simulation got faster or cheaper, or when a change touches a hot loop, scheduling, caching, publishing or display refresh. It proves the daily results did not change, then compares every headless performance metric between the base and head commits on a quiet machine, and stores each measurement in a long-lived archive so later checks reuse it. It cannot measure windowed frame time, GPU work or open overlays; for such a claim it still proves the daily results unchanged and reports the claim as unmeasured.
---

# Performance change check

One script does the measuring and decides the result: `tools/perf/perf_change_check.py`.
The verdict is the script's `PERF_CHECK_RESULT=` line and `report.md`, not your reading of the
numbers. This skill says when to run it, with what, and when to stop and ask.

The tool uses Git, Godot, a C++ toolchain and Python. A fresh build can fetch godot-cpp.

## Inputs

| Input | Where it comes from | If missing |
|---|---|---|
| Base commit | Open PR: `git merge-base master <head>`. Merged PR: the first parent of its merge commit, `git log master --first-parent --merges --format='%H %P' --grep='Merge pull request #<n> '` (second field). Once a PR is merged, its merge base with `master` is the head itself, so do not use it | Stop and ask |
| Head commit | The commit to verify. Commit first: the script measures commits, not a dirty tree | Commit, then run |
| Claimed metric(s) | The ticket's acceptance criteria, as a regex over metric names (`--claim`) | The ticket names no gain: stop and ask. It names a gain no headless metric measures: run with `--unmeasured '<why>'` (step 1) |
| Tier | `quick` for every performance PR; `full` for scheduling or threading changes and for large refactors | Use `quick` |
| Scenario | Default 60×40, seed 20260718, 3 foreign countries, 50× speed, 50 days | Keep the default so archive records stay comparable |

Tools: `godot` 4.6 on PATH or `--godot`/`$GODOT_BIN`; `scons` on PATH or `--scons`; Python 3.10+.

## Steps

1. **Find the metric names for the claim.** Metrics are named `result.*`, `auth.*`, `harness.*`
   (from the recorder's summary lines), `csv.<column>.mean|p95|max|per_day` (every numeric column of
   `perf_record_*.csv`), `waterfall.*` (full tier) and `rusage.*` (wall, CPU, peak memory).
   Take exact names from `metrics[].metric` in an earlier `report.json` (`history` lists the
   records), not from the CSV header alone: the summary lines carry values the CSV does not. For
   example economy memory is `result.economy_memory_bytes`, while `rusage.maxrss_mb` is the whole
   process and moves far less. A claim such as "economy market stage is cheaper" becomes
   `--claim 'household_market.*_ms'`.

   If no metric measures the claim headlessly, do not stop yet. Examples: the claim counts work
   done while an overlay is open (the recorder leaves overlays closed, so
   `csv.tail_overlay_refresh_count.mean` is 0 on both sides), or it needs a window or the GPU. Run
   step 2 with `--unmeasured '<why, naming the metric you checked>'`. Keep a `--claim` for each
   part of the claim that a metric does measure; both are judged in the same run. The run still
   proves the daily results unchanged and checks the headline metrics. Its best status is
   `needs_human`. Do not pick a different metric that does move and call it the claim.

2. **Run the comparison** from the repository root:

   ```sh
   python3 tools/perf/perf_change_check.py compare <base> <head> --tier quick \
     --claim '<regex>' [--claim '<regex>'...]
   # when step 1 found no headless metric for (part of) the claim:
   python3 tools/perf/perf_change_check.py compare <base> <head> --tier quick \
     --unmeasured '<why>' [--claim '<regex>'...]
   ```

   Use the same archive across runs of this checkout so measurements can be reused. Pass
   `--home` before the subcommand to select a different archive. Use a separate archive for a
   separate Git checkout that has its own Git metadata.

   The script compiles each commit's `template_debug` library (the one the headless editor loads)
   in one long-lived build tree, `~/.keynes-perf/keynes/build/` (or `$KEYNES_PERF_HOME`), so SCons only
   recompiles what changed since the last build. It copies the library into a per-commit worktree
   under `~/.keynes-perf/keynes/worktrees/`, imports the project (reusing the newest imported asset cache,
   so only changed assets are imported again), and then:
   - checks the machine before each step: it waits while less than half the CPU was idle over the
     last second (`--min-idle`) or another Godot, scons, compiler or linker process is busy. The whole run has a 10-minute
     budget (`--budget`); waiting gets whatever the estimated work leaves, and when that is spent the
     run stops with exit 75 and status `deferred`;
   - runs `tools/ci/check_golden_determinism.py` twice on each side and compares base and head
     daily per-domain hashes field by field (full tier also runs
     `tools/ci/check_runtime_load_consistency.py`);
   - runs `tests/game/headless_perf_record.gd` three rounds per side, alternating, and rejects any
     round with a non-zero exit, a missing or short CSV, `fatal=true`, ledger failures, no economy,
     a synthetic start or too few countries;
   - compares every metric and writes `report.json` and `report.md`.

   The first build compiles godot-cpp and the extension. Use
   `measure <commit> --budget 0` if you want it to run without a time limit.
   Records from different recorder methods are kept separately in the reports. The tool
   checks daily results for both, and declines a timing verdict when the methods differ.

   When the archive already holds a record for a commit with the same scenario, machine,
   toolchain and method version, that record is reused and the commit is not built or run again.
   This is the normal case when a PR comes back from review: only the new head is measured.

3. **Read the verdict line** `PERF_CHECK_RESULT={"status": ..., "reasons": [...], "report": ...}`.

   | Status | Exit | Meaning | What you do |
   |---|---|---|---|
   | `pass` | 0 | Results unchanged, every claimed metric improved, no headline metric regressed | Report it as below |
   | `needs_human` | 2 | A claim matched no metric or did not improve, the claim was run as `--unmeasured`, or a headline metric regressed beyond noise | Stop. Report the reasons and the report; do not reword the claim to fit. With `--unmeasured` and no other reason, report the results as unchanged and the claim as unmeasured |
   | `fail` | 1 | Daily results differ, a repeat check failed, a round was invalid or a build failed | Stop. A result difference is a correctness bug, not a performance question; fix the root cause (AGENTS.md rule 1, rule 4). An invalid round (for example the recorder's own `CSV row count mismatch`, exit 6) is reported with the commit it happened on; do not rerun until it passes |
   | `deferred` | 75 | The machine stayed busy past what the time budget allows | Run again later; finished records are kept and reused. Never lower `--min-idle` or raise `--budget` to get through |

4. **Run the change's own targeted test** (for example a byte-for-byte fixture named in the PR)
   separately and record its command and output. The script does not run PR-specific tests.

5. **Report** in the PR or hand-off: status, base and head commits, which side was reused from the
   archive, the claimed metrics' rows, the headline table, the counts of metrics improved, regressed
   and within noise, and the path of `report.md`. Say plainly that windowed frame time and GPU work
   were not measured.

## How the numbers are judged

- Timings (`*_ms`, `*_us`, rates, waits, `rusage.*`) count as improved or regressed only when the
  medians differ by more than 15% **and** the two sides' ranges do not overlap. Everything else is
  `within_noise`. One round per side is refused.
- Work counters (`bd_economy_scan_*`, `scan_steps*`, `*_epoch`, as per-day increases) and memory or
  capacity values (names with `bytes`, `memory`, `_mb`, `_kb`) that repeat exactly within
  each side are compared exactly: `less_work`, `more_work`, `unchanged`. A memory value that varies
  between rounds is judged like a timing. Other gauges have no better direction and are only
  `changed` or `unchanged`.
- Headline metrics: `result.run_ms`, `auth.authoritative_days_per_second`,
  `harness.adjusted_days_per_second`, `result.generation_ms`, `rusage.maxrss_mb`, `rusage.cpu_s`.

## Stop and ask instead of continuing

- No base commit, or the ticket names no metric to improve.
- The base itself fails the repeat check: the baseline is already broken; report it, do not compare.
- Daily results differ between base and head, even if the change was meant to change behavior:
  this check is for pure performance changes, and a behavior change needs a person's decision.
- The build or import fails on the base commit.
- The claim depends on windowed frame time, GPU work, an open overlay or a real player window:
  stop after the `--unmeasured` run, and say what measurement the claim still needs.
- You are tempted to raise `--noise`, lower `--rounds`, edit the archive or delete a record to get
  a pass.

## What the script writes

It does not touch the checkout's files or branch. It writes only under `~/.keynes-perf/keynes` (or
`$KEYNES_PERF_HOME`) and registers its worktrees in the repository's git metadata:

- `build/`: the long-lived build tree.
- `worktrees/<commit12>/`: at most 3 cached worktrees. Adding one removes the oldest
  (`git worktree remove`). That is expected; the records of those commits stay and are reused.
- `records/`, `comparisons/`, `index.jsonl`: kept, never overwritten or removed.

Do not delete or edit anything there by hand.

## Evidence kept

Records live under `~/.keynes-perf/keynes/records/<commit12>/<scenario>/<time-machine>/`: `record.json`
(identity, golden result, every round's metrics, machine load before each round), build and import
logs, golden logs and candidate, and per-round `godot.log`, `perf.csv`, `headless_session.json`
and `waterfall.csv`. Every record is appended to `~/.keynes-perf/keynes/index.jsonl`. Comparisons are in
`~/.keynes-perf/keynes/comparisons/<base>..<head>-<time>/`. Measurement records are kept; a changed
scenario, machine, toolchain or method version produces a new record.

## Sources

The headless recorder and its validity rules come from the `project-keynes-headless-perf` skill;
the timing-noise and counter conventions come from `compare_perf.py` in the
`project-keynes-runtime-hotloop-optimization` skill. Both were written before this check.
