#include "ideology_runtime.h"
#include "ideology_runtime_internal.h"
#include "ideology_runtime_common.inc"
#include <atomic>
#include <cstdio>
#include <cstdlib>


namespace pk {
using namespace godot;

void NativeIdeologyRuntime::ensure_derived_program_sampler() {
    if (_derived_program_sampler) return;
    _derived_program_metric_scratch.assign(
        static_cast<size_t>(EconomyApi::FAMILY_METRIC_COUNT), 0);
    _derived_program_sampler = [this](const std::string &program_key, int32_t cell,
                                      uint64_t source_country) -> double {
        (void)source_country;   // the program reads cell metrics; scope is the cell
        if (_economy_runtime == nullptr || _effect_runtime == nullptr) return 0.0;
        // Every declared metric, not a narrowed mask: the program's own READ_METRIC
        // decides what it needs, and a mask here would be a second, drifting copy of
        // that knowledge.
        const int32_t count =
            static_cast<int32_t>(_derived_program_metric_scratch.size());
        const pk::MetricMask all = pk::MetricMask::all_declared(count);
        economy_api::sample_effect_metrics(*_economy_runtime, cell, count,
            _derived_program_metric_scratch.data(), all);
        int64_t magnitude = 0;
        std::string error;
        if (!_effect_runtime->evaluate_program_magnitude_for_metrics(
                program_key, _derived_program_metric_scratch.data(), count,
                magnitude, error)) {
            // Counted, never silently zeroed: a muted effect and an effect evaluated to
            // zero look identical in the output, and only the counter separates them.
            ++_derived_program_failures;
            return 0.0;
        }
        ++_derived_program_evaluations;
        return static_cast<double>(magnitude) / static_cast<double>(Q16_ONE);
    };
}

void NativeIdeologyRuntime::ensure_derived_ramp_sampler() {
    if (!_derived_ramp_sampler) {
        _derived_ramp_metric_scratch.resize(
            static_cast<size_t>(EconomyApi::FAMILY_METRIC_COUNT), 0);
        // Captures MEMBERS, not locals: the job outlives this call.
        _derived_ramp_sampler = [this](int32_t metric_id, int32_t cell,
                                       uint64_t source_country) -> double {
            const bool country_scope =
                (metric_id >= 56 && metric_id <= 61) ||
                (metric_id >= 63 && metric_id <= 69) || metric_id == 91;
            if (country_scope) {
                static_assert(EconomyApi::FAMILY_METRIC_COUNT <= 256,
                    "ramp country-metric cache key packs metric_id into 8 bits");
                const uint64_t key = (source_country << 8U) ^
                    static_cast<uint64_t>(metric_id);
                const auto found = _derived_ramp_country_cache.find(key);
                if (found != _derived_ramp_country_cache.end()) {
                    ++_derived_ramp_samples_memoised;
                    return found->second;
                }
            }
            economy_api::sample_effect_metrics(*_economy_runtime, cell,
                static_cast<int32_t>(_derived_ramp_metric_scratch.size()),
                _derived_ramp_metric_scratch.data());
            ++_derived_ramp_samples_taken;
            const double sample = metric_id >= 0 &&
                    metric_id < static_cast<int32_t>(_derived_ramp_metric_scratch.size())
                ? static_cast<double>(
                      _derived_ramp_metric_scratch[static_cast<size_t>(metric_id)])
                : 0.0;
            if (country_scope) {
                const uint64_t key = (source_country << 8U) ^
                    static_cast<uint64_t>(metric_id);
                _derived_ramp_country_cache[key] = sample;
            }
            return sample;
        };
    }
}

bool NativeIdeologyRuntime::step_derived_rebuild(int64_t day, std::string &error,
                                               bool finish_in_day) {
    error.clear();
    if (!_configured || _modifier_runtime == nullptr || _effect_runtime == nullptr)
        return true;
    // Counted HERE, not in the deleted `rebuild_derived_cell_layer`.
    //
    // When the old one-shot rebuild was removed its `++_cell_layer_rebuild_visits`
    // went with it while the export stayed, so the counter was permanently 0 and
    // `ideology_cell_layer_e2e_test` failed on a truthful-looking message
    // ("0 means run_daily never reached the hook") that was actually my oversight.
    ++_cell_layer_rebuild_visits;

    if (day != _derived_rebuild_day) {
        // A new day invalidates any half-built job: the epoch's inputs differ, so
        // splicing two days together would be wrong.
        _derived_rebuild_day = day;
        _derived_rebuild_slices = 0;
        _derived_rebuild_total_ms = 0.0;
        _cell_layer_rebuild_ms = 0.0;
        _derived_materialise_ms = 0.0;
        // Reset with the two above, not left to accumulate. `_derived_collect_ms` is a
        // MAX, so an un-reset member reports the worst collect of the WHOLE RUN while
        // `cell_layer_rebuild_ms` / `cell_layer_materialise_ms` describe the LAST day --
        // three numbers that cannot be compared with each other (measured: an un-reset
        // collect read 1.377 ms at 6400 against a per-day 0.69 ms, and the difference
        // looked like a regression that was not there).
        _derived_collect_ms = 0.0;
        // Same scope as `_derived_collect_ms`: the collect counters describe THIS
        // day's collect. Zero them with it so a day whose collect was refused (the
        // §9.3 eligibility gate below) reads 0 instead of repeating the previous
        // day's numbers.
        _derived_collect_count = 0;
        _derived_collect_rows = 0;
        _derived_collect_ideas = 0;
        _derived_rebuild_contributions.clear();
    _collect_pod_fail_keys.clear();
    _collect_pod_ok_keys.clear();
        _derived_rebuild_collected = false;
        _derived_rebuild_job.reset();
    }

    // ── plan §9.3: do not adopt a projection before its eligibility day ────
    //
    // Placed AFTER the day-reset above, deliberately. An earlier version sat before it,
    // so a refused rebuild left `_derived_rebuild_day` pointing at the confirmation day;
    // `derived_rebuild_pending()` then stayed true and `drain_derived_cell_layer` burned
    // its whole 4096-step budget and reported `complete=false` (measured). Clearing the
    // job first makes "refused" indistinguishable from "nothing to do", which is what a
    // caller should see.
    if (_derived_basis_eligible_day >= 0 && day < _derived_basis_eligible_day) {
        ++_derived_rebuild_gated_by_eligibility;
        // Clear the day marker as well. `derived_rebuild_pending()` is
        // `_derived_rebuild_day >= 0`, and the reset block above has just set it to
        // `day`, so leaving it set made a REFUSED rebuild look like an in-flight one:
        // `drain_derived_cell_layer` then looped its entire 4096-step budget and
        // reported `complete=false` (measured in B12's continuous branch). Clearing it
        // is what makes "refused" indistinguishable from "nothing to do", which is what
        // a caller should see.
        _derived_rebuild_day = -1;
        return true;
    }

    const Clock::time_point started = Clock::now();

    if (!_derived_rebuild_collected) {
        // Collect only after the day's own active progress finished. Collecting
        // earlier reads a half-advanced world: `run_daily_slices` walks
        // `_active_country_cursor` across slices, so a second country's card may not
        // be ACTIVE yet. That is exactly what produced `collect_count = 3200`
        // against 6400 in M4-18.
        if (_active_progress_day == day) return false;
        _derived_rebuild_contributions.clear();
        // ── THE COLLECT COUNTERS ARE WRITTEN HERE, AT THE COLLECT ─────────────
        //
        // `cell_layer_collect_count` / `_rows` / `_ideas` were declared, exported
        // (`ideology_runtime_queries.cpp`) and NEVER assigned, so the report said
        // `cell_layer_collect_count=0` on every run -- which reads as "the collect
        // step never ran" and is the false trail this assignment removes. All three
        // are written together, on the one pass that fills the accumulator, with one
        // meaning each:
        //   ideas = cards that emitted at least one row
        //   rows  = distinct (country, card, level, program) rows emitted
        //   count = target-cell rows handed to the fold
        int64_t collect_ideas = 0;
        for (const CountryState &country : _countries) {
            if (country.handle == 0) continue;
            for (const IdeaState &state : country.ideas) {
                if (state.location == INACTIVE || state.level < 0) continue;
                const size_t contributions_before =
                    _derived_rebuild_contributions.size();
                std::vector<EffectActivation> throwaway;
                collect_effect_activations(country, state, throwaway,
                    &_derived_rebuild_contributions);
                if (_derived_rebuild_contributions.size() != contributions_before)
                    ++collect_ideas;
            }
        }
        _derived_collect_count =
            static_cast<int64_t>(_derived_rebuild_contributions.size());
        _derived_collect_ideas = collect_ideas;
        {
            // A program emits one row per TARGET CELL, so the raw count above cannot
            // answer "how many programs fed the fold". The collector appends one
            // program's rows CONSECUTIVELY (it builds `per_target` and appends it
            // whole, `ideology_runtime_effects.cpp`), so a group boundary is exactly
            // "this row's program differs from the previous row's" -- O(1) memory,
            // no key set allocated in the day's collect step.
            int64_t collect_rows = 0;
            const DerivedProgramContribution *previous = nullptr;
            for (const DerivedProgramContribution &contribution :
                    _derived_rebuild_contributions) {
                if (previous == nullptr ||
                        previous->source_country != contribution.source_country ||
                        previous->ideology_id != contribution.ideology_id ||
                        previous->level != contribution.level ||
                        previous->program_hash != contribution.program_hash)
                    ++collect_rows;
                previous = &contribution;
            }
            _derived_collect_rows = collect_rows;
        }
        _derived_rebuild_collected = true;
        // Plan §18.2: record the basis this projection is being built from. Done HERE,
        // at the collect step, because the collect loop above already resolved exactly
        // these programs -- and because collection honours a pending transition's OLD
        // level (§10.1), so the rows describe the basis in force, not the one that is
        // still waiting for its ACK. Diagnostics only: a capture re-derives its own rows.
        rebuild_applied_program_basis(_countries, _applied_program_basis);
        // Collection is a STEP of its own. At 6400 cells it costs 0.68 ms, and folding
        // in the same call pushed the first step to 1.03 ms -- over the 1 ms gate even
        // though the fold itself was budgeted. Returning here keeps each step's work
        // bounded by ONE kind of cost.
        // The collect's own cost, and ONLY its own. This assignment is what makes
        // `cell_layer_collect_ms` a measurement instead of a constant: the field was
        // declared and exported but never written, so the report said 0.0 on every run
        // and the perf table quoted that zero as if it were data (found 2026-10-29).
        _derived_collect_ms = std::max(_derived_collect_ms, elapsed_ms(started));
        _cell_layer_rebuild_ms = std::max(_cell_layer_rebuild_ms,
                                          elapsed_ms(started));
        // `_derived_materialise_ms` is deliberately NOT set here. It used to be assigned
        // the same collect duration, which made a "materialise" number that contained no
        // materialisation; it is the fold's cost and is set in the fold branch only.
        _derived_rebuild_steps = ++_derived_rebuild_slices;
        // Ramp terms must be EVALUATED, not deferred. Passing an empty options struct
        // here silently turned every ramp program into "no contribution" on the
        // sharded path while the single-shot path still evaluated them.
        DerivedMaterializeOptions job_options;
        _derived_ramp_country_cache.clear();
        _derived_ramp_samples_taken = 0;
        _derived_ramp_samples_memoised = 0;
        if (_economy_runtime != nullptr) {
            ensure_derived_ramp_sampler();
            job_options.ramp_sampler = &_derived_ramp_sampler;
            // Preferred over the metric sampler for every ramp term that names a
            // program (which is all of them, since the collector fills `program_key`).
            if (_effect_runtime != nullptr) {
                ensure_derived_program_sampler();
                job_options.program_magnitude_sampler = &_derived_program_sampler;
            }
        }
        _derived_rebuild_job.reset(new DerivedCellMaterializeJob(
            _derived_world_identity, _derived_map_generation, day,
            _derived_epoch_id, compute_execution_contract_hash(), job_options));
        if (finish_in_day && !_derived_rebuild_contributions.empty())
            _derived_rebuild_job->freeze_ramp_inputs(_derived_rebuild_contributions);
        return false;   // fold happens in later steps
    }

    ++_derived_rebuild_slices;
    DerivedCellFront front;
    DerivedMaterializeReport report;
    bool skipped = false;
    const DerivedCellFront *previous = modifier_api::derived_cell_front(*_modifier_runtime);
    if (!_derived_rebuild_job) return true;
    const double budget = finish_in_day ? std::numeric_limits<double>::infinity()
                                        : DERIVED_REBUILD_STEP_BUDGET_MS;
    const bool folded = _derived_rebuild_job->fold_step(_derived_rebuild_contributions, budget);
    const double step_ms = elapsed_ms(started);
    if (folded && !_derived_rebuild_job->finish(previous, front, report, skipped)) {
        error = "derived_cell_layer_finish_failed";
        return false;
    }
    _cell_layer_rebuild_ms = std::max(_cell_layer_rebuild_ms, step_ms);
    _derived_materialise_ms = std::max(_derived_materialise_ms, step_ms);
    _derived_rebuild_steps = _derived_rebuild_slices;
    _derived_rebuild_total_ms += step_ms;

    if (!folded) return false;   // more steps needed; nothing installed yet

    _last_derived_materialize = report;
    // PEAK MEMORY (§18.3): the only point where the RETAINED front (still serving
    // readers) and the CANDIDATE front (just built, not yet installed) both exist.
    // `previous` is null on the very first build -- a real case, reported as retained 0.
    {
        const int64_t retained_bytes =
            previous != nullptr ? pk::derived_cell_front_bytes(*previous) : 0;
        const int64_t candidate_bytes = pk::derived_cell_front_bytes(front);
        _derived_peak_retained_bytes =
            std::max(_derived_peak_retained_bytes, retained_bytes);
        _derived_peak_candidate_bytes =
            std::max(_derived_peak_candidate_bytes, candidate_bytes);
        _derived_peak_total_bytes = std::max(
            _derived_peak_total_bytes, retained_bytes + candidate_bytes);
    }
    // Export the JOB's ramp counters.
    //
    // These were only ever assigned on the (now dead) single-shot path, so a fixture
    // reading `ramp_terms_evaluated` saw a stale 0 no matter what the job did -- which
    // made "the ramp path works" unprovable and "the ramp path is broken" equally
    // unfalsifiable.
    _ramp_terms_evaluated = report.ramp_terms_evaluated;
    _ramp_terms_deferred = report.ramp_terms_deferred;
    bool installed = true;
    if (!skipped) {
        bool install_skipped = false;
        installed = modifier_api::install_derived_cell_layer(*_modifier_runtime,
            std::move(front), 0, install_skipped, error);
        // §18.5: the sample day of the projection that is now serving readers. Read
        // back from the INSTALLED front rather than from the job argument, because
        // those are not the same thing: an idempotent install is skipped (§I13), an
        // install can be refused (`derived_cell_layer_identity_mismatch`), and a build
        // in flight is not a projection yet. Reading it back makes this member equal to
        // `derived_cell_front()->sample_day` by construction instead of by assumption.
        const DerivedCellFront *serving = modifier_api::derived_cell_front(*_modifier_runtime);
        _derived_basis_sample_day = serving != nullptr ? serving->sample_day : -1;
    }
    if (installed) {
        // A refused install keeps the previous attribution, which still matches the
        // front that is serving.
        _derived_installed_contributions.swap(_derived_rebuild_contributions);
        const DerivedCellFront *serving = modifier_api::derived_cell_front(*_modifier_runtime);
        _derived_installed_generation = serving != nullptr ? serving->generation : 0;
    }
    _derived_rebuild_contributions.clear();
    // ── the step does not END until the front is built and installed ────────────
    //
    // `step_ms` above is taken BEFORE `finish()` and `install_derived_cell_layer()`, so
    // `cell_layer_rebuild_ms` used to publish a number that excluded the most expensive
    // part of the tail: measured at 12800 rows, the front build alone was 0.93 ms, so a
    // slice that really took 1.32 ms reported itself as 0.69 ms. That is a green number
    // quoting a subset of the work (found 2026-10-29 against the 5-run per-call trace).
    //
    // The max now covers the WHOLE step. `_derived_materialise_ms` stays fold-only, so
    // the two reported numbers still answer different questions: "what did the fold
    // cost" versus "what did one slice of this stage cost".
    {
        const double whole_step_ms = elapsed_ms(started);
        _cell_layer_rebuild_ms = std::max(_cell_layer_rebuild_ms, whole_step_ms);
        // The tail (build + install + release) is part of the same day's total. The
        // fold's part was already added above, so only the delta is added here.
        _derived_rebuild_total_ms += whole_step_ms - step_ms;
    }
    _derived_rebuild_day = -1;
    _derived_rebuild_collected = false;
    _derived_rebuild_job.reset();
    return true;
}

} // namespace pk
