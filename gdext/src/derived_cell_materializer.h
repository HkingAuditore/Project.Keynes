#pragma once
#include <cstdint>
#include <functional>
#include <memory>
#include <vector>

#include "cell_program_eligibility.h"
#include "derived_cell_layer.h"

namespace pk {

class ModifierRuntime;

// ---------------------------------------------------------------------------
// Derived cell materializer (plan 22 §4.2 / §8.1 / §8.5, M1).
//
// THE GAP THIS FILLS
//
// By M1-8 the pieces existed but nothing joined them:
//   * `decide_cell_program_backend` decided DerivedCell,
//   * `DerivedCellFrontBuilder` could build a front,
//   * `ModifierRuntime::install_derived_cell_layer` could publish it,
// and the ONLY caller of the last two was a test bridge. So the 32-cell cap was
// still in force at runtime: nothing ever turned an equipped card into derived
// rows.
//
// This file is that middle. It takes the already-resolved per-program facts and
// the already-resolved per-target cells, and emits rows.
//
// WHAT IT DELIBERATELY DOES NOT DO
//
// It does not read `NativeIdeologyRuntime`, `EffectRuntime` or
// `NativeEconomyRuntime` state, and it does not decide policy. The caller
// supplies:
//   * which programs are live and their `CellProgramFacts`,
//   * which cells each program targets (already resolved by the shared visitor
//     from §6.1, so the cap is applied once, in one place),
//   * which resolved terms each program's commands expand to.
//
// That keeps this testable with plain data (§13.1 layer 1) and keeps the
// eligibility decision single-sourced (§4.5).
//
// SCOPE LINE, STATED EXPLICITLY
//
// This is M1: it folds all source countries for a (stat, cell) into ONE row. The
// per-source undo required by §8.1 ("two source countries affecting the same
// cell must MULTIPLY, and unequipping one must not disturb the other") needs a
// second-level structure and a replacement path. That is M2. Folding here means
// a cell touched by two countries is arithmetically correct TODAY but cannot be
// partially undone -- recorded in the findings rather than silently assumed.
// ---------------------------------------------------------------------------

// One program's contribution, already resolved by the caller.
struct DerivedProgramContribution {
    // Stable identity for diagnostics and for the per-source bookkeeping M2 adds.
    uint64_t source_country = 0;
    // The eligibility verdict. A program that is not DerivedCell must be skipped
    // by the caller, not coerced here -- `I01` forbids one program having two
    // backends in the same configuration.
    CellProgramBackend backend = CellProgramBackend::EffectInstance;
    // Cells this program reaches. Unbounded by design (§1.1): the selector
    // resolves the whole target set and the 32-cell cap is NOT applied.
    std::vector<int32_t> cells;
    // Per-target magnitude scale, mirroring `EffectTarget::magnitude_scale_q16`.
    //
    // SELECTOR_TAG_SOURCE_COUNT normalises it to `min(count, cap) / cap` on the
    // instance path (ideology_runtime.cpp:2079-2081). Ignoring it here made the
    // derived path read 1.23999 where the instance path reads 1.12 -- one source
    // contribution too many (M4-2). Kind 12/14/15 always carry 1.0.
    double magnitude_scale = 1.0;
    // Resolved modifier terms, flattened across the program's commands. A
    // program with two commands contributes two groups and both must be folded.
    // How a term's magnitude is produced (plan §15.5, M3).
    //
    // A CONSTANT term carries its magnitude in `add` / `factor` and needs nothing
    // else. A RAMP term's magnitude is a function of a live per-cell metric, so it
    // cannot be folded into a constant at materialise time -- doing that is exactly
    // the "threshold bucket freezing" §15.5 forbids, because the value would then
    // be stale the moment the metric moved without changing its bucket.
    enum class MagnitudeSource : uint8_t {
        Constant = 0,
        RampMetric = 1,
    };

    struct Term {
        int32_t stat_id = -1;
        // `operation == ADD` folds by summation, otherwise by multiplication,
        // mirroring `ModifierRuntime::scaled_add` / `scaled_factor`.
        int32_t operation = 0;
        // Already includes stacks and the command magnitude: the caller applies
        // `term.add * stacks * magnitude` (plan §5.4) so this struct never has to
        // know about Q16 or clamp order.
        double add = 0.0;
        double factor = 1.0;

        // ── Ramp terms ────────────────────────────────────────────────────
        //
        // `magnitude_source == RampMetric` means the effective magnitude is
        //   clamp(sample(metric_id, cell) * ramp_scale, ramp_floor, ramp_ceil)
        // evaluated PER CELL, then used in place of `add`/`factor` above.
        MagnitudeSource magnitude_source = MagnitudeSource::Constant;
        // Which metric to sample. 0 is a legal metric id (family.magnitude_q16),
        // so `metric_id < 0` is the "none" sentinel, not 0.
        int32_t metric_id = -1;
        // The program whose INSTRUCTION STREAM produces this ramp's magnitude.
        //
        // A ramp is not `metric * scale`: the shipped cards compute
        // `CONST a -> READ_METRIC m -> CONST b -> MIN -> MUL -> EMIT`, so the metric is
        // clamped and scaled BY THE PROGRAM. Measured on `salt_monopoly_l1`
        // (`min(metric,15) * 655 / Q16` vs the derived path's `metric / Q16`): the
        // derived numbers were 40 and 120 where the interpreter gives a constant 9825,
        // and the resulting contribution saturated the stat at its clamp_max.
        //
        // So the materializer asks for a PROGRAM magnitude when this is set, and only
        // falls back to `metric * ramp_scale` when nothing can supply one.
        //
        // A POINTER, not a value. `Term` is copied once per (term, target cell), so a
        // `std::string` member meant an allocation per copy: measured on the 6400-cell
        // fixture the worst step went 0.61 ms -> 1.43 ms with the string in place, on a
        // fixture whose card has NO ramp term at all (so the copies bought nothing).
        // The key is interned by the collector, which is what makes a pointer safe.
        const std::string *program_key = nullptr;
        // Multiply the sampled value by this. Q16 magnitudes arrive as integers,
        // so the caller passes the already-normalised ratio.
        double ramp_scale = 1.0;
        // Floors and ceilings applied AFTER scaling, matching the authored
        // `CONST -> MIN` / `MAX` instruction pair.
        double ramp_floor = 0.0;
        double ramp_ceil = 0.0;
        // True when `ramp_ceil` is meaningful. An unbounded ramp leaves this
        // false rather than carrying a magic large number.
        bool ramp_has_ceil = false;
    };
    std::vector<Term> terms;
};

// Counters for plan §12.4. Populated even when the build is empty, so a report
// can distinguish "nothing to do" from "everything was rejected".
struct DerivedMaterializeReport {
    int32_t programs_seen = 0;
    int32_t programs_derived = 0;
    int32_t programs_skipped_legacy = 0;
    int64_t cells_visited = 0;
    int64_t commands_folded = 0;
    int64_t rows_emitted = 0;
    // Container-growth / node-insertion events in the fold.
    //
    // NOT a malloc counter: this build has no allocator hook, and `scratch_bytes` above is
    // an estimate for the same reason. What this counts is exact -- every `push_back` on
    // the touched-stat list, every `push_back` on an output cell list, and every NEW
    // inner-map node in the (stat, cell) accumulator. That is the number of times the
    // fold had to make room, which is the decision `scratch_bytes` is guessing at.
    int64_t allocations = 0;
    // Hard requirement from §12.4: the derived path must never truncate. A
    // non-zero value here is a defect, not a budget outcome.
    int32_t truncated = 0;
    int32_t missing_stat = 0;
    // Ramp terms skipped because no metric sampler was supplied. Counted rather
    // than folded to zero: a zero magnitude would mute the effect with no signal.
    int32_t ramp_terms_deferred = 0;
    // Ramp terms actually evaluated per cell; non-zero proves the live path ran.
    int64_t ramp_terms_evaluated = 0;
    // Bytes held by the fold's WORKING SET while the job ran: the per-(stat, cell)
    // accumulator map plus the touched-stat list. This is the `scratch` figure plan
    // §18.3 asks for, computed structurally the same way `derived_cell_front_bytes`
    // reports the installed front.
    //
    // It is an ESTIMATE of bytes, not a count of allocations: the per-node overhead is a
    // labelled constant for the standard library's hash node, and nothing in this build
    // counts allocations. Reporting an estimate and saying so is better than inventing a
    // count.
    int64_t scratch_bytes = 0;
    // Live accumulator nodes (one per (stat, cell) pair the fold touched). The byte
    // estimate is derived from this, so a reader can recompute it.
    int32_t scratch_nodes = 0;

    // -- Backlog (plan 18.3's third item, after memory and allocations) ------
    //
    // Cell-visits this rebuild still OWED when the report was last updated:
    // `total_cells - cells_visited`, where `total_cells` is the cell count of the
    // contribution list the job was handed. That is the fold job's queue depth at the
    // last slice boundary.
    //
    // WHY THIS COUNT AND NOT ANOTHER
    //
    // The candidates the code offers are: the fold job's remaining work, how many
    // slices a day still owes, the per-country instance-refresh budget left, and
    // `pending_transitions`. Three of those are already reported somewhere, so a
    // fourth copy would be a proxy of a proxy:
    //   * `pending_transitions` is already `out["pending_transitions"]` in the daily
    //     slice report (`NativeIdeologyRuntime::run_daily_slices`),
    //   * the instance-refresh budget is the `cursor/total` progress in that same report,
    //   * "slices owed" is a function of `DERIVED_REBUILD_STEP_BUDGET_MS`, not of the
    //     world -- which is exactly why the previous evidence for this row (B3's
    //     "9 calls per day") could not be compared across budgets.
    //
    // What is left, and what only this job can answer, is: after this slice, how much
    // cell work is STILL queued. `cells_visited` above counts work done; this counts
    // work left, and the denominator (`total_cells`) is not reported anywhere else, so
    // the two are complements rather than duplicates. The unit is cell-visits because
    // that is the unit of work the fold actually spends time on: the QUEUE TOTAL is fixed
    // by the day's live programs and their target cells, and the peak is the part of it a
    // slice failed to retire. A larger budget therefore shows up as a SHALLOWER peak,
    // which is the correct reading ("the rebuild fell this far behind") and is exactly
    // the distinction B3's per-day call count could not express.
    //
    // A reader acts on it as "how far behind is this rebuild": read it between slices
    // through `DerivedCellMaterializeJob::live_report()`. A depth that does not shrink
    // across slices means the budget is being spent without retiring the queue.
    //
    // NOTE: 0 once the fold completes, so the report `finish()` publishes always reads
    // 0 here. The depth that survives into the published report is
    // `rebuild_backlog_peak_cells` below.
    int64_t rebuild_backlog_cells = 0;
    // Deepest `rebuild_backlog_cells` seen at a slice boundary during this rebuild,
    // i.e. how deep the queue actually got.
    //
    // Non-zero exactly when the fold needed more than one slice. Kept because the
    // terminal report's `rebuild_backlog_cells` is 0 by construction, and a field that
    // only ever reads 0 at the one point it can be observed is a dead field -- this
    // codebase has shipped several (M5-64: `cell_layer_collect_ms` read 0.0 for months
    // while the perf table quoted it as data).
    int64_t rebuild_backlog_peak_cells = 0;
};

// Builds a front from already-resolved contributions.
//
// Returns true when a front was produced (which may be an empty-but-valid front
// meaning "every program contributes nothing"), false when the build was refused
// outright. `out_skipped` is set when the content matched `previous`, so the
// caller can avoid an install and avoid a version bump (plan I13 / §7.4).
// Supplies a metric sample for one cell (plan \u00a715.5, M3).
//
// A Ramp term's magnitude is a live function of its metric, so the materializer
// must ask for the value per cell instead of receiving a pre-folded constant. The
// callback is the seam that keeps this file free of any economy dependency: the
// caller passes `NativeEconomyRuntime::sample_effect_metrics` in production and a
// synthetic function in tests.
//
// Returning nothing / not supplying the sampler is legal: such terms are counted
// in `DerivedMaterializeReport::ramp_terms_deferred` rather than being folded to
// zero, because a zero would silently mute the effect.
// Supplies a metric sample for one cell of one source country.
//
// `source_country` is part of the signature because a COUNTRY-scope metric (e.g.
// `country.extractive_cell_count`, ids 56..61 and 63..69) does not vary per cell:
// a 1000-cell territory would otherwise recompute the same national count 1000
// times. The caller can memoise on `(source_country, metric_id)` -- the
// materializer deliberately does not, because only the caller knows which metrics
// are country-scoped.
using DerivedRampSampler = std::function<double(
    int32_t metric_id, int32_t cell, uint64_t source_country)>;

// Runs the program's own instruction stream for one cell and returns the magnitude as
// a ratio (already divided by Q16).
//
// WHY THIS EXISTS INSTEAD OF RE-DERIVING THE ARITHMETIC
//
// The cards' magnitudes are programs, not formulas. `min(metric,15) * 655 / Q16` is one
// shipped shape out of 24; re-implementing each shape here is how the derived path
// drifted (M5-13). The runtime already owns a shipping stack machine
// (`EffectRuntime::run_program_machine`) and a non-mutating entry for exactly this use
// (`evaluate_program_magnitude_for_metrics`), so the materializer calls it rather than
// guessing.
using DerivedProgramMagnitudeSampler = std::function<double(
    const std::string &program_key, int32_t cell, uint64_t source_country)>;

struct DerivedMaterializeOptions {
    // Null means "no metric input available"; ramp terms are then deferred.
    const DerivedRampSampler *ramp_sampler = nullptr;
    // Preferred over `ramp_sampler` for every ramp term that names a program. Null falls
    // back to `metric * ramp_scale`, which is only correct for a program whose stream is
    // exactly `EMIT metric` with unit scale.
    const DerivedProgramMagnitudeSampler *program_magnitude_sampler = nullptr;
};

// A RESUMABLE materialise.
//
// WHY THIS EXISTS
//
// A full materialise measured 1.2833 ms at 6400 cells against §14.3's 1 ms per-slice
// gate. Splitting it needs the fold state to survive BETWEEN calls, because the
// state that matters lives across every contribution:
//
//   * `folded`         -- stat -> cell -> accumulator, the partially built result;
//   * `touched_stats`  -- which stats received a row, for the version bump;
//   * the running report counters.
//
// A first attempt kept those as locals in `build_derived_cell_front` and merely
// looped a `slice` vector over them; the slice was never passed to the builder, so
// the "sharded" path still did one full build and the numbers it produced were
// meaningless (M4-18). This class is the fix: the state IS the object.
//
// USAGE
//
//   DerivedCellMaterializeJob job(world_identity, map_generation, sample_day,
//                                epoch_id, execution_contract_hash, options);
//   while (!job.done()) job.fold_step(contributions, max_ms);
//   job.finish(previous, out_front, out_report, out_skipped);
//
// `fold_step` resumes where the previous step stopped, so a caller can hold it
// across engine frames without any per-step rework.
class DerivedCellMaterializeJob {
public:
    DerivedCellMaterializeJob(uint64_t world_identity, uint64_t map_generation,
                              int64_t sample_day, uint64_t epoch_id,
                              uint64_t execution_contract_hash,
                              DerivedMaterializeOptions options);
    // Declared out of line so `Impl` may stay incomplete here: a `unique_ptr` to an
    // incomplete type cannot be destroyed in the header (MSVC: "can't delete an
    // incomplete type").
    ~DerivedCellMaterializeJob();
    DerivedCellMaterializeJob(DerivedCellMaterializeJob &&) noexcept;
    DerivedCellMaterializeJob &operator=(DerivedCellMaterializeJob &&) noexcept;
    DerivedCellMaterializeJob(const DerivedCellMaterializeJob &) = delete;
    DerivedCellMaterializeJob &operator=(const DerivedCellMaterializeJob &) = delete;

    // Folds contributions from the current cursor until `budget_ms` is spent or the
    // list is exhausted. Returns true when there is nothing left to fold.
    //
    // A whole contribution is always folded: a single contribution is one target
    // cell (the collector emits one per cell), so the granularity is already fine
    // and cutting inside one would need per-term state.
    bool fold_step(const std::vector<DerivedProgramContribution> &contributions,
                   double budget_ms);

    // NOT `_index >= _total`: before the first `fold_step` both are 0, which would
    // report "done" on a job that has folded nothing. A job is done only once a step
    // has actually consumed a non-empty list.
    bool done() const { return _started && _index >= _total; }
    size_t cursor() const { return _index; }
    size_t total() const { return _total; }

    // The report accumulated SO FAR. Valid at any point, unlike `finish()` which
    // requires `done()`.
    //
    // This is the only place `rebuild_backlog_cells` is observable while work is still
    // queued: `finish()` hands out the terminal report, where the fold owes nothing and
    // the field is 0 by construction. A caller that wants "how much is left" between
    // slices reads it here.
    const DerivedMaterializeReport &live_report() const;

    // Builds and returns the front. Only valid once `done()`.
    bool finish(const DerivedCellFront *previous, DerivedCellFront &out_front,
                DerivedMaterializeReport &out_report, bool &out_skipped);

private:
    struct Impl;
    // Pimpl so the accumulator type stays out of the header; the fold state is an
    // implementation detail and the header is included by Godot-facing code.
    std::unique_ptr<Impl> _impl;
    size_t _index = 0;
    size_t _total = 0;
    bool _started = false;
};

bool build_derived_cell_front(
    const std::vector<DerivedProgramContribution> &contributions,
    uint64_t world_identity,
    uint64_t map_generation,
    int64_t sample_day,
    uint64_t epoch_id,
    uint64_t execution_contract_hash,
    const DerivedCellFront *previous,
    DerivedCellFront &out_front,
    DerivedMaterializeReport &out_report,
    bool &out_skipped);

// Ramp-aware overload. The 10-argument form above delegates to this one with no
// sampler, which is why every existing caller keeps compiling unchanged.
bool build_derived_cell_front(
    const std::vector<DerivedProgramContribution> &contributions,
    uint64_t world_identity,
    uint64_t map_generation,
    int64_t sample_day,
    uint64_t epoch_id,
    uint64_t execution_contract_hash,
    const DerivedCellFront *previous,
    DerivedCellFront &out_front,
    DerivedMaterializeReport &out_report,
    bool &out_skipped,
    const DerivedMaterializeOptions &options);

// Evaluate one ramp term for one cell.
//
// Lives AFTER `DerivedProgramContribution` because it names that type; an
// earlier placement above the struct failed to compile. Both the materializer
// (which folds) and any test predicting the value use this one function, so the
// arithmetic cannot drift between them.
// Evaluate one ramp term for one cell.
//
// Kept in this header because both the materializer (which folds) and any test
// that wants to predict the value must agree on the arithmetic, and a second copy
// would drift. `metric_value` is the raw Q16 sample for that cell.
inline double evaluate_ramp_magnitude(
        const DerivedProgramContribution::Term &term, double metric_value) {
    double value = metric_value * term.ramp_scale;
    if (value < term.ramp_floor) value = term.ramp_floor;
    if (term.ramp_has_ceil && value > term.ramp_ceil) value = term.ramp_ceil;
    return value;
}

} // namespace pk
