---
name: project-keynes-economy-analysis
description: Analyze Project.Keynes economy recorder CSV families and related runtime code. Use for data cleaning, schema and conservation checks, time-series and lagged correlation analysis, market shortages and price formation, merchant liquidity and trade, natural-resource allocation and depletion, building employment/production/viability/investment, cohort wealth/livelihood/satisfaction/demography, balance diagnosis, regression comparison, and evidence-backed investigation of economy_record_*_summary/cohorts/market/resources/buildings.csv exports.
---

# Project.Keynes Economy Analysis

Use this skill with `project-keynes-economy-runtime`. Also load
`cpp-dots-runtime-development` or `project-keynes-runtime-architecture` when the diagnosis crosses
scheduler, authority, DataCore, save, or publish boundaries. Treat current source and content as the
truth; recorder filenames and old reports are only clues.

## Establish the evidence boundary

1. Resolve the common recorder prefix and discover the available dimensions.
2. Read every header before selecting metrics. Detect schema from columns, not the `_vNN` filename.
3. State scope explicitly. `summary` is global; the other tables contain only sampled or selected
   cells. Do not present a local/global correlation as a world-level causal result.
4. Confirm that detail `epoch_row_id` values align with summary rows and check missing days,
   malformed rows, duplicates, blank identifiers, and partial writer termination.
5. Separate stocks, per-epoch flows, EMAs, pending values, and applied values before aggregation.
6. Decode money, goods, price, Q16, and resource units only after checking the recorder/runtime ABI.

Run the bundled streaming preflight from the repository root:

```powershell
python .codex/skills/project-keynes-economy-analysis/scripts/profile_economy_record.py `
  --prefix tmp/economy_record_<timestamp>_vNN_cell... `
  --repo-root .
```

Use its JSON as an index, not as the final diagnosis. It reports schema fingerprints, row/epoch
coverage, entity summaries, warning signals, and level/change/lag correlations without loading the
entire export into memory. If `tools/analysis/analyze_economy_record_v18.py` exists and its accessed
columns pass preflight, run it as an additional baseline; disregard its version label and recheck its
interpretations against current code.

Read [analysis-playbook.md](references/analysis-playbook.md) for any full diagnosis. Read
[code-tracing.md](references/code-tracing.md) whenever the user requests code linkage, a likely root
cause, a fix recommendation, or comparison across recorder/runtime versions.

## Build the diagnosis

Analyze in this order:

1. Data integrity and scope.
2. Exact population, money, and goods audits, including explicit source/sink exceptions.
3. Global trajectory and structural breakpoints.
4. Selected-cell cohort distribution and merchant versus nonmerchant outcomes.
5. Market availability, demand, reserve locks, price, liquidity, and trade response.
6. Building staffing, inputs, output disposition, wages, margin, lifecycle, debt, and investment.
7. Resource stock-flow, pending/applied extraction, regeneration, safe yield, and projected life.
8. Cross-domain chains and time-aware correlations.
9. Source-to-metric trace and competing explanations.

Use first/last, early/late windows, extrema, event onset, duration, and population- or
quantity-weighted rates. Do not infer health from exact conservation alone. A zero audit proves
accounting closure, not adequate supply, fair distribution, viable firms, good price response, or
acceptable cadence approximation.

## Treat correlation as supporting evidence

- Report sample count, transformation, lag direction, and scope for each important correlation.
- Check levels and first differences. Strong level correlation between trending series is weak
  evidence unless changes and event timing agree.
- Test lags in simulation days that match the current market cycle, price EMA, investment review,
  trade planning, and demography cadence.
- Prefer a chain with temporal precedence and a matching code path over the largest coefficient.
- Do not sum merchant fields repeated on every good row; deduplicate by `(day, cell)` first.
- Do not correlate mixed stocks and flows until they are converted to compatible period semantics.

## Ground conclusions in current code

Trace every P0/P1 claim through recorder header, capture assignment, runtime owner, mutation formula,
profile/content inputs, and publish cadence. Quote symbol names and clickable file/line references in
the report. Distinguish:

- recorder or schema defect;
- invariant/authority bug;
- scheduling, frozen-cycle, or visibility issue;
- balance/calibration problem;
- missing economic mechanism or intentional non-goal;
- local sample limitation.

Do not modify runtime code or content during a diagnosis-only request. Recommend the smallest
validation or code/content surface that can falsify the leading hypothesis.

## Report the result

Write in the user's language and lead with the decision-relevant findings. Include:

- data range, recorder schema fingerprint, global/local scope, and validation gaps;
- P0/P1/P2 findings with onset day, magnitude, persistence, affected entities, and confidence;
- market, resource, building, and cohort sections with distributional effects;
- only the correlations that change or strengthen the diagnosis;
- a causal chain from observed symptom to current code/content path;
- alternative explanations and what evidence would distinguish them;
- prioritized code, content, instrumentation, or rerun recommendations;
- artifact paths and exact commands used.

When comparing runs, normalize horizon and scope, align by simulation day or lifecycle phase, and
separate changed recorder schema from changed economic behavior.

## Verify before completion

- Reconcile reported row counts and horizons with the source CSVs.
- Spot-check at least one raw row behind every major finding.
- Recompute key ratios independently from numerator and denominator.
- Check catalog dense-ID mapping against sorted stable IDs.
- Confirm cited code still writes the named field.
- Run `git diff --check` if the analysis created or changed repository artifacts.
