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
namespace {
struct RampValue {
    double magnitude = 0.0;
    bool available = false;
};

RampValue sample_fold_ramp(const DerivedMaterializeOptions &options,
        const DerivedProgramContribution &program,
        const DerivedProgramContribution::Term &term, int32_t cell) {
    if (options.program_magnitude_sampler != nullptr && term.program_key != nullptr) {
        double magnitude = (*options.program_magnitude_sampler)(
            *term.program_key, cell, program.source_country);
        if (program.magnitude_scale != 1.0) magnitude *= program.magnitude_scale;
        return {magnitude, true};
    }
    if (options.ramp_sampler == nullptr || term.metric_id < 0) return {};
    const double sample = (*options.ramp_sampler)(term.metric_id, cell, program.source_country);
    return {evaluate_ramp_magnitude(term, sample), true};
}
} // namespace

// Flat dense fold table indexed by (stat_id, cell) for realistic map sizes, with
// an overflow map only for synthetic tests that pass out-of-range cell ids.
// Replaces the per-(stat, cell) std::unordered_map heap node allocations that
// dominated both `fold_step` and `finish()` destruction on large countries.
constexpr int32_t kDenseCellLimit = 262144;
constexpr size_t kFoldBudgetCheckStride = 256;

struct StatFoldBucket {
    int32_t stat_id = -1;
    std::vector<Accumulator> dense_cells;
    std::vector<uint8_t> dense_present;
    std::vector<int32_t> touched_cells;
    std::unordered_map<int32_t, Accumulator> overflow_cells;

    Accumulator &touch(int32_t cell, int64_t &allocations, bool &inserted) {
        if (cell >= 0 && cell < kDenseCellLimit) {
            const size_t idx = static_cast<size_t>(cell);
            if (idx >= dense_cells.size()) {
                size_t next_size = dense_cells.empty() ? 256u : dense_cells.size();
                while (next_size <= idx) next_size *= 2u;
                if (next_size > static_cast<size_t>(kDenseCellLimit))
                    next_size = static_cast<size_t>(kDenseCellLimit);
                dense_cells.resize(next_size);
                dense_present.resize(next_size, 0);
                ++allocations;
            }
            if (dense_present[idx] == 0) {
                dense_present[idx] = 1;
                touched_cells.push_back(cell);
                inserted = true;
            } else {
                inserted = false;
            }
            return dense_cells[idx];
        }
        const size_t before = overflow_cells.size();
        Accumulator &slot = overflow_cells[cell];
        inserted = overflow_cells.size() != before;
        if (inserted) {
            touched_cells.push_back(cell);
            ++allocations;
        }
        return slot;
    }

    const Accumulator &at(int32_t cell) const {
        if (cell >= 0 && cell < kDenseCellLimit &&
                static_cast<size_t>(cell) < dense_cells.size()) {
            return dense_cells[static_cast<size_t>(cell)];
        }
        return overflow_cells.at(cell);
    }
};

struct FlatFoldTable {
    std::vector<int32_t> stat_to_bucket;
    std::unordered_map<int32_t, int32_t> stat_overflow;
    std::vector<StatFoldBucket> buckets;

    StatFoldBucket &bucket_for(int32_t stat_id, int64_t &allocations) {
        if (stat_id >= 0 && stat_id < 65536) {
            const size_t idx = static_cast<size_t>(stat_id);
            if (idx >= stat_to_bucket.size()) {
                stat_to_bucket.resize(idx + 1u, -1);
            }
            int32_t &slot = stat_to_bucket[idx];
            if (slot < 0) {
                slot = static_cast<int32_t>(buckets.size());
                buckets.emplace_back();
                buckets.back().stat_id = stat_id;
                ++allocations;
            }
            return buckets[static_cast<size_t>(slot)];
        }
        auto it = stat_overflow.find(stat_id);
        if (it != stat_overflow.end())
            return buckets[static_cast<size_t>(it->second)];
        const int32_t slot = static_cast<int32_t>(buckets.size());
        buckets.emplace_back();
        buckets.back().stat_id = stat_id;
        stat_overflow[stat_id] = slot;
        ++allocations;
        return buckets[static_cast<size_t>(slot)];
    }

    bool emit_to_builder(DerivedCellFrontBuilder &builder,
                         int64_t &rows_emitted) {
        for (StatFoldBucket &bucket : buckets) {
            if (bucket.touched_cells.empty()) continue;
            if (!std::is_sorted(bucket.touched_cells.begin(),
                                bucket.touched_cells.end())) {
                std::sort(bucket.touched_cells.begin(),
                          bucket.touched_cells.end());
            }
            std::vector<int32_t> cells;
            std::vector<DerivedCellContribution> contribs;
            const size_t count = bucket.touched_cells.size();
            cells.reserve(count);
            contribs.reserve(count);
            for (const int32_t cell : bucket.touched_cells) {
                const Accumulator &slot = bucket.at(cell);
                cells.push_back(cell);
                DerivedCellContribution row;
                row.source_country = slot.source_country;
                row.contributor_count = slot.contributor_count > 0
                    ? slot.contributor_count : 1u;
                row.sum_add = slot.sum_add;
                row.product_nonzero = slot.product_nonzero;
                row.zero_factor_count = slot.zero_factor_count;
                contribs.push_back(row);
            }
            if (!builder.add_sorted_stat_row(
                    bucket.stat_id, std::move(cells), std::move(contribs))) {
                return false;
            }
            builder.bump_stat_version(bucket.stat_id);
            rows_emitted += static_cast<int64_t>(count);
        }
        return true;
    }

    void measure_scratch(int32_t &out_nodes, int64_t &out_bytes) const {
        constexpr int64_t kNodeOverhead = 32;
        constexpr int64_t kBucketSlot = 16;
        int64_t nodes = 0;
        int64_t bytes =
            static_cast<int64_t>(stat_to_bucket.capacity()) *
                static_cast<int64_t>(sizeof(int32_t)) +
            static_cast<int64_t>(buckets.capacity()) *
                static_cast<int64_t>(sizeof(StatFoldBucket));
        for (const StatFoldBucket &bucket : buckets) {
            nodes += static_cast<int64_t>(bucket.touched_cells.size());
            bytes += static_cast<int64_t>(bucket.dense_cells.capacity()) *
                         static_cast<int64_t>(sizeof(Accumulator)) +
                     static_cast<int64_t>(bucket.dense_present.capacity()) +
                     static_cast<int64_t>(bucket.touched_cells.capacity()) *
                         static_cast<int64_t>(sizeof(int32_t)) +
                     static_cast<int64_t>(bucket.overflow_cells.size()) *
                         (static_cast<int64_t>(sizeof(int32_t)) +
                          static_cast<int64_t>(sizeof(Accumulator)) + kNodeOverhead) +
                     static_cast<int64_t>(bucket.overflow_cells.bucket_count()) *
                         kBucketSlot;
        }
        out_nodes = static_cast<int32_t>(nodes);
        out_bytes = bytes;
    }
};

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
    std::vector<RampValue> frozen_ramps;
    size_t ramp_cursor = 0;
    bool ramps_frozen = false;

    FlatFoldTable folded;
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

void DerivedCellMaterializeJob::freeze_ramp_inputs(
        const std::vector<DerivedProgramContribution> &contributions) {
    for (const auto &program : contributions) {
        if (program.backend != CellProgramBackend::DerivedCell) continue;
        for (const auto &term : program.terms) {
            if (term.stat_id < 0 ||
                term.magnitude_source != DerivedProgramContribution::MagnitudeSource::RampMetric)
                continue;
            for (const int32_t cell : program.cells) {
                if (cell >= 0)
                    _impl->frozen_ramps.push_back(sample_fold_ramp(_impl->options, program, term, cell));
            }
        }
    }
    _impl->options = {};
    _impl->ramps_frozen = true;
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
    DerivedMaterializeReport &out_report = _impl->report;
    const StepClock::time_point started = StepClock::now();

    // Resume from `(_index, _term_index, _cell_index)`. Nothing before it is re-folded.
    size_t since_budget_check = 0;
    while (_index < _total) {
        const DerivedProgramContribution &program = contributions[_index];
        const int32_t unit_count = program.count_per_cell
            ? static_cast<int32_t>(program.cells.size()) : int32_t{1};
        if (_term_index == 0 && _cell_index == 0) {
            out_report.programs_seen += unit_count;
            // I01: the backend is decided once, by the shared eligibility pass.
            if (program.backend != CellProgramBackend::DerivedCell) {
                out_report.programs_skipped_legacy += unit_count;
                ++_index;
                continue;
            }
            out_report.programs_derived += unit_count;
            if (program.terms.empty() || program.cells.empty()) {
                ++_index;
                continue;
            }
        }

        bool budget_hit = false;
        while (_term_index < program.terms.size()) {
            const DerivedProgramContribution::Term &term =
                program.terms[_term_index];
            if (_cell_index == 0) {
                if (term.stat_id < 0) {
                    out_report.missing_stat += unit_count;
                    ++_term_index;
                    continue;
                }
                out_report.commands_folded += unit_count;
            }
            StatFoldBucket &bucket =
                _impl->folded.bucket_for(term.stat_id, out_report.allocations);
            const bool is_ramp = term.magnitude_source ==
                DerivedProgramContribution::MagnitudeSource::RampMetric;
            const bool is_add = term.operation == 0;
            const double base_add = term.add;
            const double base_factor = term.factor;
            const size_t cell_count = program.cells.size();
            while (_cell_index < cell_count) {
                const int32_t cell = program.cells[_cell_index];
                ++_cell_index;
                if (cell < 0) continue;
                ++out_report.cells_visited;
                bool inserted = false;
                Accumulator &slot =
                    bucket.touch(cell, out_report.allocations, inserted);
                if (slot.contributor_count == 0) {
                    slot.source_country = program.source_country;
                    slot.contributor_count = 1;
                } else if (program.source_country != 0 &&
                           slot.source_country != program.source_country) {
                    ++slot.contributor_count;
                }
                double term_add = base_add;
                double term_factor = base_factor;
                if (is_ramp) {
                    const RampValue ramp = _impl->ramps_frozen
                        ? _impl->frozen_ramps[_impl->ramp_cursor++]
                        : sample_fold_ramp(_impl->options, program, term, cell);
                    if (!ramp.available) {
                        ++out_report.ramp_terms_deferred;
                        continue;
                    }
                    ++out_report.ramp_terms_evaluated;
                    if (is_add) {
                        term_add = ramp.magnitude;
                        term_factor = 1.0;
                    } else {
                        term_add = 0.0;
                        term_factor = ramp.magnitude;
                    }
                }
                if (is_add) {
                    slot.sum_add += term_add;
                    if (term_factor != 1.0) {
                        if (term_factor == 0.0) ++slot.zero_factor_count;
                        else slot.product_nonzero *= term_factor;
                    }
                } else {
                    if (term_factor == 0.0) ++slot.zero_factor_count;
                    else slot.product_nonzero *= term_factor;
                }
                if (++since_budget_check >= kFoldBudgetCheckStride) {
                    since_budget_check = 0;
                    if (elapsed_ms_since(started) >= budget_ms) {
                        budget_hit = true;
                        break;
                    }
                }
            }
            if (_cell_index >= cell_count) {
                _cell_index = 0;
                ++_term_index;
            }
            if (budget_hit) break;
        }
        if (_term_index >= program.terms.size()) {
            _term_index = 0;
            _cell_index = 0;
            ++_index;
        }
        if (budget_hit || elapsed_ms_since(started) >= budget_ms) break;
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
    _impl->folded.measure_scratch(_impl->report.scratch_nodes,
                                  _impl->report.scratch_bytes);
    out_report = _impl->report;
    out_skipped = false;
    out_front = DerivedCellFront{};

    DerivedCellFrontBuilder builder;
    builder.reset(_impl->world_identity, _impl->map_generation, _impl->sample_day,
                  _impl->epoch_id, _impl->execution_contract_hash);

    const uint64_t next_generation =
        previous == nullptr ? uint64_t{1} : previous->generation + 1;
    (void)next_generation;  // kept for the generation contract; unused by the emit
    if (!_impl->folded.emit_to_builder(builder, out_report.rows_emitted)) {
        return false;
    }

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
