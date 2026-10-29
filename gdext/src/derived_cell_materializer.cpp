#include "derived_cell_materializer.h"

#include <algorithm>
#include <chrono>
#include <unordered_map>

namespace {
// Local clock: this translation unit must stay Godot-free so the kernel is testable
// without linking godot_cpp.
using StepClock = std::chrono::steady_clock;
double elapsed_ms_since(const StepClock::time_point &start) {
    return std::chrono::duration<double, std::milli>(StepClock::now() - start)
        .count();
}
}  // namespace

namespace pk {

namespace {

// Fold order (plan §5.5): programs in the order the caller supplies them, terms
// in the order the caller supplies them, cells ascending. The caller is
// responsible for supplying programs in a canonical order (country slot, then
// dense program id); this function does not re-sort them, because re-sorting
// would make the fold order depend on slot allocation rather than on the
// authored identity.
//
// ADD and factor are kept separate per row and folded exactly like
// `ModifierRuntime::Bucket`: sum for ADD, product for factor, with a zero factor
// counted separately so it can annihilate the product without losing the
// survivors (plan §5.5).
struct Accumulator {
    double sum_add = 0.0;
    double product_nonzero = 1.0;
    uint32_t zero_factor_count = 0;
    // Which country first contributed to this (stat, cell), and how many DISTINCT
    // countries contributed in total.
    //
    // The resolved VALUE is the fold of every contributor, so a border cell covered
    // by two countries' cards produces one row either way. Provenance is the only
    // way to answer the two questions plan §15.6/B10 asks:
    //   * "two countries influence this border cell -- which row is it?" and
    //   * "one country revokes its card -- does the row vanish or just shrink?"
    // Neither is answerable from the folded value: two sources contributing 0.5+0.5
    // and one contributing 1.0 look identical, but only the first disappears when
    // one of them is revoked.
    uint64_t source_country = 0;
    uint32_t contributor_count = 0;
};

} // namespace

namespace {

// One entry per UNIQUE (stat, cell) pair, pointing at its accumulator.
//
// WHY A FLAT LIST INSTEAD OF RE-WALKING `folded` AT FINISH
//
// `finish()` used to walk the per-stat unordered_map once to collect cell keys, sort
// them, then do a SECOND hash lookup per cell (`stat_entry.second[cell]`) to read the
// value. At 12800 rows that is 12800 scattered node visits plus 12800 more hash probes,
// and it measured 0.84-1.09 ms of `finish()`'s ~0.93 ms -- i.e. the front build, not
// the fold, was the most expensive part of the whole rebuild slice.
//
// The list is filled at the one moment a node is CREATED (when `per_cell[cell]` had to
// insert), so it holds exactly one entry per unique pair, never a duplicate. Pointer
// stability is guaranteed: `std::unordered_map` rehashing invalidates iterators but not
// references or pointers to elements ([unord.req]), and nothing erases during a fold.
// `key` packs (stat, cell) so one sort yields rows in the order the builder wants.
struct TouchedSlot {
    uint64_t key = 0;              // (stat_id << 32) | cell
    const Accumulator *slot = nullptr;
};

uint64_t touched_slot_key(int32_t stat_id, int32_t cell) {
    return (static_cast<uint64_t>(static_cast<uint32_t>(stat_id)) << 32U) |
        static_cast<uint64_t>(static_cast<uint32_t>(cell));
}

int32_t touched_slot_stat(uint64_t key) {
    return static_cast<int32_t>(static_cast<uint32_t>(key >> 32U));
}

int32_t touched_slot_cell(uint64_t key) {
    return static_cast<int32_t>(static_cast<uint32_t>(key & 0xFFFFFFFFULL));
}

// How many cell-visits the whole contribution list will make, counted with the SAME
// skip rules the fold uses. Kept in one place so `rebuild_backlog_cells` really is
// `total - cells_visited` and cannot drift from the fold it describes.
//
// Counting it up front is what makes the backlog a measurement rather than a guess:
// `fold_step` is handed the whole immutable list on the first call, so the denominator
// is knowable before the first cell is folded.
int64_t count_derived_cell_visits(
        const std::vector<DerivedProgramContribution> &contributions) {
    int64_t total = 0;
    for (const DerivedProgramContribution &program : contributions) {
        // Mirrors the fold: a legacy backend is skipped before any cell is touched, and
        // a program with no terms or no cells contributes no visits at all.
        if (program.backend != CellProgramBackend::DerivedCell) continue;
        if (program.terms.empty() || program.cells.empty()) continue;
        for (const DerivedProgramContribution::Term &term : program.terms) {
            // A term with no stat is counted in `missing_stat` and its cells are never
            // visited, so it must not enter the denominator either.
            if (term.stat_id < 0) continue;
            for (const int32_t cell : program.cells) {
                if (cell < 0) continue;
                ++total;
            }
        }
    }
    return total;
}

} // namespace

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
        const DerivedMaterializeOptions &options) {
    const DerivedRampSampler *out_ramp_sampler = options.ramp_sampler;
    out_report = DerivedMaterializeReport{};
    out_skipped = false;
    out_front = DerivedCellFront{};

    DerivedCellFrontBuilder builder;
    builder.reset(world_identity, map_generation, sample_day, epoch_id,
                  execution_contract_hash);

    // stat -> cell -> accumulator. A map here is fine: this runs once per epoch
    // freeze, not per query, and the final front is rebuilt into sorted rows.
    std::unordered_map<int32_t, std::unordered_map<int32_t, Accumulator>> folded;
    // Track which stats actually received a row, so the version bump happens
    // once per stat rather than once per contribution.
    std::vector<int32_t> touched_stats;

    for (const DerivedProgramContribution &program : contributions) {
        ++out_report.programs_seen;
        // I01: the backend is decided once, by the shared eligibility pass.
        // Coercing an EffectInstance program into the derived layer here would
        // give it two backends in the same configuration.
        if (program.backend != CellProgramBackend::DerivedCell) {
            ++out_report.programs_skipped_legacy;
            continue;
        }
        ++out_report.programs_derived;
        if (program.terms.empty() || program.cells.empty()) continue;

        for (const DerivedProgramContribution::Term &term : program.terms) {
            if (term.stat_id < 0) {
                ++out_report.missing_stat;
                continue;
            }
            ++out_report.commands_folded;
            auto &per_cell = folded[term.stat_id];
            touched_stats.push_back(term.stat_id);
        ++out_report.allocations;
            for (const int32_t cell : program.cells) {
                if (cell < 0) continue;
                ++out_report.cells_visited;
                const size_t before_insert = per_cell.size();
        Accumulator &slot = per_cell[cell];
        if (per_cell.size() != before_insert) ++out_report.allocations;
                // First writer wins for the recorded handle; every distinct country
                // raises the count so a revocation is observable even when the value
                // hardly moves.
                if (slot.contributor_count == 0) {
                    slot.source_country = program.source_country;
                    slot.contributor_count = 1;
                } else if (slot.source_country != program.source_country) {
                    ++slot.contributor_count;
                }
                // A Ramp term's magnitude is a live function of its metric, so it
                // is evaluated HERE, per cell. Folding it earlier (at materialise)
                // would freeze the value at whatever the metric read then, which is
                // the stale "threshold bucket" plan §15.5 forbids.
                //
                // `term.add` / `term.factor` are neutral for a ramp; the sampled
                // magnitude replaces them.
                double term_add = term.add;
                double term_factor = term.factor;
                if (term.magnitude_source ==
                        DerivedProgramContribution::MagnitudeSource::RampMetric) {
                    if (out_ramp_sampler == nullptr || term.metric_id < 0) {
                        // No sampler means the caller cannot supply metric input
                        // (a pure-kernel test, or the economy has not sampled yet).
                        // Dropping the term is the honest choice: a ramp folded to
                        // 0 would silently zero the effect, and folding it to its
                        // scale would apply a magnitude the metric never justified.
                        ++out_report.ramp_terms_deferred;
                        continue;
                    }
                    const double sampled = (*out_ramp_sampler)(
                        term.metric_id, cell, program.source_country);
                    ++out_report.ramp_terms_evaluated;
                    const double magnitude =
                        evaluate_ramp_magnitude(term, sampled);
                    if (term.operation == 0) {
                        term_add = magnitude;
                        term_factor = 1.0;
                    } else {
                        term_add = 0.0;
                        term_factor = magnitude;
                    }
                }
                // NOTE: `program.magnitude_scale` is NOT applied here.
                //
                // The per-target scale is already folded into `term.add` by the
                // collector (`ideology_runtime.cpp:2353`, which multiplies each term
                // by that target's `magnitude_scale`). Scaling again here applied it
                // twice: a cell that should read 1.06 read 1.03, i.e. 0.12 x 0.5 x 0.5.
                // `DerivedProgramContribution::magnitude_scale` remains on the struct
                // so a caller that builds contributions by hand (the pure-kernel
                // tests) can still express a scale, but the production path has
                // already consumed it.

                // ADD folds by summation and MULTIPLY by product, decided by the
                // term's operation exactly like the instance path. A term that
                // is neither contributes nothing rather than guessing.
                if (term.operation == 0) {  // ADD
                    slot.sum_add += term_add;
                    if (!(term_factor == 1.0)) {
                        if (term_factor == 0.0) ++slot.zero_factor_count;
                        else slot.product_nonzero *= term_factor;
                    }
                } else {  // MULTIPLY
                    if (term_factor == 0.0) ++slot.zero_factor_count;
                    else slot.product_nonzero *= term_factor;
                }
            }
        }
    }

    // Emit rows. Cells are inserted ascending per stat so the front's binary
    // searches stay valid; `DerivedCellFrontBuilder::add` accepts any order and
    // keeps its own sorted invariant, but feeding it sorted input is cheaper.
    for (auto &stat_entry : folded) {
        const int32_t stat_id = stat_entry.first;
        std::vector<int32_t> cells;
        cells.reserve(stat_entry.second.size());
        for (const auto &cell_entry : stat_entry.second)
            cells.push_back(cell_entry.first);
            ++out_report.allocations;
        std::sort(cells.begin(), cells.end());
        for (const int32_t cell : cells) {
            const Accumulator &slot = stat_entry.second[cell];
            if (!builder.add(stat_id, cell, slot.source_country,
                             slot.sum_add, slot.zero_factor_count > 0 ? 0.0
                                 : slot.product_nonzero,
                             slot.contributor_count)) {
                return false;
            }
            ++out_report.rows_emitted;
        }
    }
    std::sort(touched_stats.begin(), touched_stats.end());
    touched_stats.erase(std::unique(touched_stats.begin(), touched_stats.end()),
                        touched_stats.end());
    for (const int32_t stat_id : touched_stats) builder.bump_stat_version(stat_id);

    // §12.4 hard condition: the derived path must never truncate. This builder
    // has no cap, so `truncated` stays 0 by construction -- it is reported so a
    // future refactor that reintroduces a cap fails a test instead of silently
    // dropping targets.
    out_report.truncated = 0;

    // Backlog is 0 on this path, deliberately and by construction: the single-shot
    // build folds every contribution before it returns, so no cell is ever left owed
    // BETWEEN slices. A non-zero value here would mean the fold skipped work it also
    // counted in `cells_visited`.
    out_report.rebuild_backlog_cells = 0;
    out_report.rebuild_backlog_peak_cells = 0;

    DerivedCellFront built;
    const bool produced = builder.install(built);
    if (!produced) {
        // Nothing was added. That is a legal empty result (§17): the caller must
        // retire any previous contribution, so an empty front is returned and
        // the caller decides whether to install it.
        out_front = DerivedCellFront{};
        out_front.world_identity = world_identity;
        out_front.map_generation = map_generation;
        out_front.sample_day = sample_day;
        out_front.epoch_id = epoch_id;
        out_front.execution_contract_hash = execution_contract_hash;
        // Identical-to-previous is a no-op (§7.4): if the previous front was also
        // empty, there is nothing to install and no version to bump.
        if (previous != nullptr && previous->rows.empty()) out_skipped = true;
        return true;
    }

    // I13: identical content is an idempotent no-op, so an unchanged world does
    // not bump a generation or invalidate every cache keyed on it (§7.4).
    if (previous != nullptr && !previous->rows.empty() &&
            built.content_digest() == previous->content_digest()) {
        out_skipped = true;
    }
    out_front = std::move(built);
    return true;
}

// 10-argument form: no metric input, so ramp terms are deferred and counted
// rather than folded to zero. Kept as the primary signature so every pre-M3
// caller compiles unchanged.
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
        bool &out_skipped) {
    return build_derived_cell_front(
        contributions, world_identity, map_generation, sample_day, epoch_id,
        execution_contract_hash, previous, out_front, out_report, out_skipped,
        DerivedMaterializeOptions{});
}

// ── Resumable materialise ────────────────────────────────────────────────
//
// The fold state lives HERE, not in a function body. That is the entire point: the
// first sharding attempt kept it as locals and looped a `slice` vector that was
// never passed to the builder, so it did one full build while looking sharded
// (M4-18, `contribs=1600` at build time against 3200 collected).
struct DerivedCellMaterializeJob::Impl {
    uint64_t world_identity = 0;
    uint64_t map_generation = 0;
    int64_t sample_day = 0;
    uint64_t epoch_id = 0;
    uint64_t execution_contract_hash = 0;
    DerivedMaterializeOptions options;

    std::unordered_map<int32_t, std::unordered_map<int32_t, Accumulator>> folded;
    // One entry per unique (stat, cell) pair, filled as nodes are created. This is what
    // `finish()` emits from instead of re-walking `folded` (see `TouchedSlot`).
    std::vector<TouchedSlot> touched_slots;
    std::vector<int32_t> touched_stats;
    DerivedMaterializeReport report;
    // Denominator for `rebuild_backlog_cells`: every cell-visit the contribution list
    // will make. Computed once, on the first `fold_step`, because the list is immutable
    // for the life of the pass.
    int64_t total_cells = 0;
    bool cell_total_known = false;
};

DerivedCellMaterializeJob::DerivedCellMaterializeJob(
        uint64_t world_identity, uint64_t map_generation, int64_t sample_day,
        uint64_t epoch_id, uint64_t execution_contract_hash,
        DerivedMaterializeOptions options)
    : _impl(new Impl()) {
    _impl->world_identity = world_identity;
    _impl->map_generation = map_generation;
    _impl->sample_day = sample_day;
    _impl->epoch_id = epoch_id;
    _impl->execution_contract_hash = execution_contract_hash;
    _impl->options = options;
}

DerivedCellMaterializeJob::~DerivedCellMaterializeJob() = default;
DerivedCellMaterializeJob::DerivedCellMaterializeJob(
        DerivedCellMaterializeJob &&) noexcept = default;
DerivedCellMaterializeJob &DerivedCellMaterializeJob::operator=(
        DerivedCellMaterializeJob &&) noexcept = default;

const DerivedMaterializeReport &DerivedCellMaterializeJob::live_report() const {
    return _impl->report;
}

bool DerivedCellMaterializeJob::fold_step(
        const std::vector<DerivedProgramContribution> &contributions,
        double budget_ms) {
    _total = contributions.size();
    _started = true;
    if (!_impl->cell_total_known) {
        _impl->cell_total_known = true;
        _impl->total_cells = count_derived_cell_visits(contributions);
    }
    const DerivedRampSampler *ramp_sampler = _impl->options.ramp_sampler;
    DerivedMaterializeReport &out_report = _impl->report;
    const StepClock::time_point started = StepClock::now();

    // Resume from `_index`. Nothing before it is re-folded.
    while (_index < _total) {
        const DerivedProgramContribution &program = contributions[_index];
        ++_index;
        ++out_report.programs_seen;
        // I01: the backend is decided once, by the shared eligibility pass.
        if (program.backend != CellProgramBackend::DerivedCell) {
            ++out_report.programs_skipped_legacy;
            continue;
        }
        ++out_report.programs_derived;
        if (program.terms.empty() || program.cells.empty()) continue;

        for (const DerivedProgramContribution::Term &term : program.terms) {
            if (term.stat_id < 0) {
                ++out_report.missing_stat;
                continue;
            }
            ++out_report.commands_folded;
            auto &per_cell = _impl->folded[term.stat_id];
            _impl->touched_stats.push_back(term.stat_id);
            ++out_report.allocations;
            for (const int32_t cell : program.cells) {
                if (cell < 0) continue;
                ++out_report.cells_visited;
                const size_t before_insert = per_cell.size();
                Accumulator &slot = per_cell[cell];
                if (per_cell.size() != before_insert) {
                    // A NEW (stat, cell) node. Record it once, here, so the emit pass
                    // never has to look it up again. This also makes `allocations`
                    // count what its comment claims -- the single-shot path already
                    // counted insertions, this one did not.
                    ++out_report.allocations;
                    _impl->touched_slots.push_back(
                        TouchedSlot{touched_slot_key(term.stat_id, cell), &slot});
                }
                if (slot.contributor_count == 0) {
                    slot.source_country = program.source_country;
                    slot.contributor_count = 1;
                } else if (program.source_country != 0 &&
                           slot.source_country != program.source_country) {
                    ++slot.contributor_count;
                }
                double term_add = term.add;
                double term_factor = term.factor;
                if (term.magnitude_source ==
                        DerivedProgramContribution::MagnitudeSource::RampMetric) {
                    // PREFER the program's own instruction stream. `metric * ramp_scale`
                    // is only correct for a stream that is exactly `EMIT metric` with
                    // unit scale; the shipped ramp cards compute
                    // `CONST a -> READ_METRIC -> CONST b -> MIN -> MUL -> EMIT`, so the
                    // fallback drops both the clamp and the constant (M5-13).
                    const DerivedProgramMagnitudeSampler *program_sampler =
                        _impl->options.program_magnitude_sampler;
                    if (program_sampler != nullptr && term.program_key != nullptr) {
                        const double magnitude = (*program_sampler)(
                            *term.program_key, cell, program.source_country);
                        ++out_report.ramp_terms_evaluated;
                        if (term.operation == 0) {
                            term_add = magnitude;
                            term_factor = 1.0;
                        } else {
                            term_add = 0.0;
                            term_factor = magnitude;
                        }
                        if (program.magnitude_scale != 1.0) {
                            if (term.operation == 0)
                                term_add *= program.magnitude_scale;
                            else
                                term_factor *= program.magnitude_scale;
                        }
                        if (term.operation == 0) {
                            slot.sum_add += term_add;
                            if (term_factor != 1.0) {
                                if (term_factor == 0.0) ++slot.zero_factor_count;
                                else slot.product_nonzero *= term_factor;
                            }
                        } else {
                            if (term_factor == 0.0) ++slot.zero_factor_count;
                            else slot.product_nonzero *= term_factor;
                        }
                        continue;
                    }
                    if (ramp_sampler == nullptr || term.metric_id < 0) {
                        ++out_report.ramp_terms_deferred;
                        continue;
                    }
                    const double sampled = (*ramp_sampler)(
                        term.metric_id, cell, program.source_country);
                    ++out_report.ramp_terms_evaluated;
                    const double magnitude = evaluate_ramp_magnitude(term, sampled);
                    if (term.operation == 0) {
                        term_add = magnitude;
                        term_factor = 1.0;
                    } else {
                        term_add = 0.0;
                        term_factor = magnitude;
                    }
                }
                if (term.operation == 0) {
                    slot.sum_add += term_add;
                    if (term_factor != 1.0) {
                        if (term_factor == 0.0) ++slot.zero_factor_count;
                        else slot.product_nonzero *= term_factor;
                    }
                } else {
                    if (term_factor == 0.0) ++slot.zero_factor_count;
                    else slot.product_nonzero *= term_factor;
                }
            }
        }
        // Budget check AFTER a whole contribution, so the unit is never cut in half.
        if (elapsed_ms_since(started) >= budget_ms) break;
    }
    // -- the backlog (plan 18.3) --------------------------------------------
    //
    // Updated at the SLICE BOUNDARY, which is the only moment the number means
    // anything: mid-contribution the job is still holding un-folded cells it has already
    // counted as visited on the way in. `cells_visited` is work done, `total_cells` is the
    // queue, so the difference is what is still owed.
    //
    // Clamped at 0 defensively: `count_derived_cell_visits` mirrors the fold's skip rules,
    // so a negative value would mean the two drifted, and silently publishing a negative
    // backlog would hide exactly that.
    _impl->report.rebuild_backlog_cells = std::max<int64_t>(
        0, _impl->total_cells - _impl->report.cells_visited);
    if (_impl->report.rebuild_backlog_cells >
            _impl->report.rebuild_backlog_peak_cells) {
        _impl->report.rebuild_backlog_peak_cells =
            _impl->report.rebuild_backlog_cells;
    }
    return done();
}

bool DerivedCellMaterializeJob::finish(
        const DerivedCellFront *previous, DerivedCellFront &out_front,
        DerivedMaterializeReport &out_report, bool &out_skipped) {
    if (!done()) return false;
    // ── the fold's working set (§18.3 `scratch`) ───────────────────────────────
    //
    // Computed here because this is the last moment the containers still exist: `finish`
    // builds the front out of `folded` and the job is then discarded.
    //
    // The two constants are ESTIMATES for the standard library's hash node and bucket
    // slot, and they are named so a reader can see exactly what was assumed.
    {
        constexpr int64_t kNodeOverhead = 32;  // one hash node's bookkeeping
        constexpr int64_t kBucketSlot = 16;    // a bucket pointer plus load-factor slack
        int64_t nodes = 0;
        int64_t buckets = static_cast<int64_t>(_impl->folded.bucket_count());
        for (const auto &stat_entry : _impl->folded) {
            nodes += static_cast<int64_t>(stat_entry.second.size());
            buckets += static_cast<int64_t>(stat_entry.second.bucket_count());
        }
        _impl->report.scratch_nodes = static_cast<int32_t>(nodes);
        _impl->report.scratch_bytes =
            nodes * (static_cast<int64_t>(sizeof(int32_t)) +
                     static_cast<int64_t>(sizeof(Accumulator)) + kNodeOverhead) +
            buckets * kBucketSlot +
            static_cast<int64_t>(_impl->touched_stats.capacity()) *
                static_cast<int64_t>(sizeof(int32_t)) +
            // The flat (stat, cell) emit list is part of the fold's working set too.
            static_cast<int64_t>(_impl->touched_slots.capacity()) *
                static_cast<int64_t>(sizeof(TouchedSlot));
    }
    out_report = _impl->report;
    out_skipped = false;
    out_front = DerivedCellFront{};

    DerivedCellFrontBuilder builder;
    builder.reset(_impl->world_identity, _impl->map_generation, _impl->sample_day,
                  _impl->epoch_id, _impl->execution_contract_hash);

    const uint64_t next_generation =
        previous == nullptr ? uint64_t{1} : previous->generation + 1;
    (void)next_generation;  // kept for the generation contract; unused by the emit
    // Emit from the flat list filled when each node was CREATED: one sort, no per-cell
    // hash probe, no second traversal of `folded`.
    //
    // The sort is skipped when the list is already ascending, which is the common
    // single-country case (each program emits its cells in ascending order, so the list
    // is already grouped by stat and ordered by cell). `is_sorted` is a linear pass and
    // costs a small fraction of the sort it replaces.
    if (!std::is_sorted(_impl->touched_slots.begin(), _impl->touched_slots.end(),
                        [](const TouchedSlot &a, const TouchedSlot &b) {
                            return a.key < b.key;
                        })) {
        std::sort(_impl->touched_slots.begin(), _impl->touched_slots.end(),
                  [](const TouchedSlot &a, const TouchedSlot &b) {
                      return a.key < b.key;
                  });
    }
    for (const TouchedSlot &entry : _impl->touched_slots) {
        const Accumulator &slot = *entry.slot;
        if (!builder.add(touched_slot_stat(entry.key), touched_slot_cell(entry.key),
                         slot.source_country, slot.sum_add,
                         slot.zero_factor_count > 0 ? 0.0 : slot.product_nonzero,
                         slot.contributor_count)) {
            return false;
        }
        ++out_report.rows_emitted;
    }
    std::sort(_impl->touched_stats.begin(), _impl->touched_stats.end());
    _impl->touched_stats.erase(
        std::unique(_impl->touched_stats.begin(), _impl->touched_stats.end()),
        _impl->touched_stats.end());
    for (const int32_t stat_id : _impl->touched_stats)
        builder.bump_stat_version(stat_id);

    DerivedCellFront built;
    builder.install(built);
    if (built.rows.empty()) {
        out_front = std::move(built);
        if (previous != nullptr && previous->rows.empty()) out_skipped = true;
        return true;
    }
    if (previous != nullptr && !previous->rows.empty() &&
            built.content_digest() == previous->content_digest()) {
        out_skipped = true;
    }
    out_front = std::move(built);
    return true;
}

}  // namespace pk
