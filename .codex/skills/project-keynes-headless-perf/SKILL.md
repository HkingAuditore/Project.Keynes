---
name: project-keynes-headless-perf
description: Run and validate Project.Keynes production-path performance recording without a graphical interface. Use when Codex is asked to run 50 or another number of simulation days, generate perf_record_YYYYMMDD_HHMMSS.csv, benchmark SUS/C++/economy jobs or continuation behavior headlessly, or reproduce performance CSV data without clicking the GM panel.
---

# Project.Keynes Headless Performance Recording

Use the repository test entry `Project/project-keynes/tests/headless_perf_record.gd`. It reuses
`WorldRuntimeHost` and `PerfRecorder`; do not substitute `economy_runtime_bench.gd` or
`tmp_economy_two_year_50x_probe.gd` when the requested artifact is `perf_record_*.csv`.

## Run

From the repository root, execute:

```powershell
& .\.codex\skills\project-keynes-headless-perf\scripts\run_headless_perf.ps1 `
  -Days 50 -Speed 50 -Seed 20260718
```

Pass `-RepoRoot` or `-GodotExe` only when the current workspace or Godot installation differs.
Prefer the Godot console executable so logs remain visible.

Use `-UseSavedSetup` when the request refers to the player's current setup or current map preset.
This loads `user://world_setup_settings.json`, including map size, seed, continents, climate knobs,
render flags, and test-economy scale. For an isolated size comparison, pass `-Width` and `-Height`
without `-UseSavedSetup`.

Use `-ClosingAuditMode FULL|PROBE|INCREMENTAL` for an explicit audit A/B.
Use `-WorkerMode ON|OFF` for deterministic worker/scalar A/B.
The runner uses the formal `NewGameConfig` multi-country start by default. Use
`-ForeignCount`, `-ImportTariffRate`, and `-ExportTariffRate` for a comparable
cross-country tariff A/B. `-SyntheticTestEconomy` is an explicit legacy/synthetic
benchmark mode and must not be reported as formal gameplay-start evidence.
Use `-TradeScenario` when the benchmark must exercise actual foreign trade. It
applies a deterministic cold-path supply/demand perturbation between two formally
started countries, then requires route search, dispatched orders, and partner
aggregates before accepting the sample.
The runner restores the loaded resource after world generation and does not edit the `.tres`.

The wrapper must fail unless:

- Godot exits with code 0.
- The result contains a real `tmp/perf_record_*.csv`.
- The CSV has exactly `Days` data rows.
- Required fixed columns such as `tick_idx`, `speed_multiplier`, and `t_sus_ms` exist.
- The economy reports `economy_configured=true` and a positive opening population.
- Formal mode reports `formal_start=true` and at least `ForeignCount + 1` countries.
- The headless result reports `ledger_failures=0` and `fatal=false`.

Godot's dummy renderer may print RID/resource cleanup warnings after a successful headless run.
Treat the verified marker, process exit code, CSV checks, and economy validation as authoritative;
do not report those shutdown-only warnings as a benchmark failure.

## Build boundary

If C++ changed since the loaded DLLs were built, close any running Godot instance and run
`gdext/rebuild.bat` before recording. The headless editor executable loads the DLL selected by the
current `dots_ext.gdextension` debug mapping. Do not label it a release benchmark unless the release
mapping or exported release build was selected explicitly.

## Interpret

Use headless CSV for SUS, native C++ passes, economy jobs, continuation slices, fallback paths, and
CPU breakdown comparisons. Report row count, map size, speed, seed, total run time, barrier pulses,
ledger failures, fatal state, formal/synthetic start mode, country count, opening population, trade
orders, route expansions, tariff lanes, country-good/country-partner aggregate counts, economy
memory, and CSV path.

Do not compare headless `fps`, GPU behavior, `t_render_ms`, or UI timings directly with graphical
player recordings. Run the graphical player scene when the question concerns GPU upload, rendering,
present, interactive UI, or end-to-end player FPS.

Keep `perf_record_*.csv` distinct from:

- `economy_record_*.csv`: economic state/epoch evidence.
- `tile_data_record_*.csv`: per-cell state recording.
- `economy_runtime_bench.gd`: synthetic native economy microbenchmark.

For performance diagnosis, inspect avg/p95/max, `largest_slice_*`, skipped reasons,
`continuation_*`, job stage/substage/path, fallback counts, and native compute/apply/flush/sync
breakdowns. Read `docs/cpp-dots-runtime/performance-diagnostics-playbook.md` before drawing a root
cause conclusion.

Once a specific native stage is implicated, load `project-keynes-runtime-hotloop-optimization`.
It covers probe wiring, the ±15% wall-clock noise floor and the deterministic `scan_steps_*`
counters to use instead, the known cache-invalidation traps in `gdext/src`, and the
stashed-baseline regression protocol.
