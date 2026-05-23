#include "sus_scheduler_ext.h"

#include <godot_cpp/classes/time.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/core/error_macros.hpp>
#include <godot_cpp/variant/utility_functions.hpp>
#include <godot_cpp/variant/variant.hpp>

#include <algorithm>
#include <cmath>
#include <cstdint>

namespace pk {

using namespace godot;

namespace {

// Helper: pull SusTickContext fields once via Object::get; avoid 2N reflection.
struct TickCtxView {
    int      tick_index   = 0;
    StringName source;
};

inline TickCtxView _read_tick_ctx(Object *ctx) {
    TickCtxView v;
    if (ctx == nullptr) {
        return v;
    }
    Variant ti = ctx->get("tick_index");
    Variant src = ctx->get("source");
    v.tick_index = (int)ti;
    v.source     = (StringName)src;
    return v;
}

// posmod (GDScript posmod semantics).
inline int _posmod(int a, int n) {
    if (n <= 0) return 0;
    int r = a % n;
    if (r < 0) r += n;
    return r;
}

inline int64_t _now_us() {
    return Time::get_singleton()->get_ticks_usec();
}

} // anonymous namespace

// ─────────────────────────────────────────────────────────────────────────
// ctor / dtor
// ─────────────────────────────────────────────────────────────────────────

SusSchedulerExt::SusSchedulerExt() = default;

SusSchedulerExt::~SusSchedulerExt() {
    // Free heap-owned policy trees.
    for (auto &je : _jobs) {
        _free_policy(je.policy);
        je.policy = nullptr;
    }
    _jobs.clear();
}

void SusSchedulerExt::set_sim_budget_window_size(int v) {
    _sim_budget_window_size = v < 1 ? 1 : v;
    while ((int)_tick_budget_samples.size() > _sim_budget_window_size) {
        _tick_budget_samples.erase(_tick_budget_samples.begin());
    }
}

// ─────────────────────────────────────────────────────────────────────────
// Policy build / eval / free
// ─────────────────────────────────────────────────────────────────────────

SusSchedulerExt::PolicyNode *SusSchedulerExt::_build_policy(const Dictionary &d) const {
    PolicyNode *p = new PolicyNode();
    if (d.is_empty()) {
        p->kind = PolicyKind::Always;
        return p;
    }
    String kind_str = String(d.get("kind", "always"));
    if (kind_str == "always") {
        p->kind = PolicyKind::Always;
    } else if (kind_str == "stride") {
        p->kind   = PolicyKind::Stride;
        p->stride = std::max(1, (int)d.get("stride", 1));
        p->phase  = (int)d.get("phase", 0);
    } else if (kind_str == "accumulator") {
        p->kind      = PolicyKind::Accumulator;
        p->threshold = (float)(double)d.get("threshold", 1.0);
        Variant g = d.get("getter",   Variant());
        Variant r = d.get("resetter", Variant());
        if (g.get_type() == Variant::CALLABLE) p->getter   = (Callable)g;
        if (r.get_type() == Variant::CALLABLE) p->resetter = (Callable)r;
    } else if (kind_str == "continuous") {
        // ContinuousSlicedPolicy: "stride" stores ticks_per_slice (=
        // period_ticks / slice_count), "phase" stores _phase_offset. The GD
        // wrapper precomputes ticks_per_slice so C++ doesn't need to know
        // period_ticks / slice_count separately.
        p->kind   = PolicyKind::Continuous;
        p->stride = std::max(1, (int)d.get("stride", 1));
        p->phase  = (int)d.get("phase", 0);
    } else if (kind_str == "and") {
        p->kind = PolicyKind::And;
        Variant av = d.get("a", Variant());
        Variant bv = d.get("b", Variant());
        if (av.get_type() == Variant::DICTIONARY) p->a = _build_policy((Dictionary)av);
        if (bv.get_type() == Variant::DICTIONARY) p->b = _build_policy((Dictionary)bv);
    } else if (kind_str == "or") {
        p->kind = PolicyKind::Or;
        Variant av = d.get("a", Variant());
        Variant bv = d.get("b", Variant());
        if (av.get_type() == Variant::DICTIONARY) p->a = _build_policy((Dictionary)av);
        if (bv.get_type() == Variant::DICTIONARY) p->b = _build_policy((Dictionary)bv);
    } else {
        // Unknown kind → behave as Always (safe fallback, mirrors SusPolicy
        // base class default).
        p->kind = PolicyKind::Always;
    }
    return p;
}

void SusSchedulerExt::_free_policy(PolicyNode *p) {
    if (p == nullptr) return;
    _free_policy(p->a);
    _free_policy(p->b);
    delete p;
}

bool SusSchedulerExt::_policy_should_run(PolicyNode *p, Object *job, Object *ctx, int tick_index) const {
    if (p == nullptr) return true; // null policy = AlwaysPolicy default
    switch (p->kind) {
        case PolicyKind::Always:
            return true;

        case PolicyKind::Stride: {
            // sus_policy.gd::StridePolicy: ((tick_index + phase) % stride) == 0
            int s = std::max(1, p->stride);
            return _posmod(tick_index + p->phase, s) == 0;
        }

        case PolicyKind::Continuous: {
            // sus_policy.gd::ContinuousSlicedPolicy: ((tick_index + _phase_offset) % tps) == 0
            int s = std::max(1, p->stride);
            return _posmod(tick_index + p->phase, s) == 0;
        }

        case PolicyKind::Accumulator: {
            // sus_policy.gd::AccumulatorPolicy: getter ≥ threshold, getter
            // invalid → false.
            if (!p->getter.is_valid()) return false;
            Variant v = p->getter.callv(Array());
            float val = (float)(double)v;
            return val >= p->threshold;
        }

        case PolicyKind::And: {
            bool ra = (p->a == nullptr) || _policy_should_run(p->a, job, ctx, tick_index);
            bool rb = (p->b == nullptr) || _policy_should_run(p->b, job, ctx, tick_index);
            return ra && rb;
        }

        case PolicyKind::Or: {
            bool ra = (p->a != nullptr) && _policy_should_run(p->a, job, ctx, tick_index);
            bool rb = (p->b != nullptr) && _policy_should_run(p->b, job, ctx, tick_index);
            return ra || rb;
        }
    }
    return true;
}

void SusSchedulerExt::_policy_on_completed(PolicyNode *p, Object *job, Object *ctx) const {
    if (p == nullptr) return;
    if (p->kind == PolicyKind::Accumulator) {
        if (p->resetter.is_valid()) {
            p->resetter.callv(Array());
        }
    } else if (p->kind == PolicyKind::And || p->kind == PolicyKind::Or) {
        // Mirror sus_policy.gd: combinators don't override on_job_completed,
        // but for safety propagate to children (the GDScript base class
        // implementation does nothing, so this is a no-op net).
        _policy_on_completed(p->a, job, ctx);
        _policy_on_completed(p->b, job, ctx);
    }
}

// ─────────────────────────────────────────────────────────────────────────
// Registry
// ─────────────────────────────────────────────────────────────────────────

void SusSchedulerExt::bind_world(Variant w) {
    _world_ref = w;
    if (_world_ref.get_type() == Variant::NIL) return;
    Object *w_obj = (Object*)_world_ref;
    for (auto &je : _jobs) {
        if (je.job_obj != nullptr) {
            je.job_obj->call("bind_world", w);
        }
    }
}

int SusSchedulerExt::_find_job_idx(const StringName &id) const {
    for (int i = 0; i < (int)_jobs.size(); ++i) {
        if (_jobs[i].id == id) return i;
    }
    return -1;
}

SusSchedulerExt::JobEntry *SusSchedulerExt::_find_job_ptr(const StringName &id) {
    int idx = _find_job_idx(id);
    return idx >= 0 ? &_jobs[idx] : nullptr;
}

void SusSchedulerExt::_resort_jobs() {
    std::stable_sort(_jobs.begin(), _jobs.end(),
                     [](const JobEntry &a, const JobEntry &b) { return a.priority < b.priority; });
}

void SusSchedulerExt::register_job(Object *job, Dictionary descriptor) {
    if (job == nullptr) {
        ERR_PRINT("[SUS-cpp] register_job: nil job");
        return;
    }
    StringName id = (StringName)descriptor.get("id", StringName());
    if (id == StringName()) {
        ERR_PRINT("[SUS-cpp] register_job: empty id");
        return;
    }
    if (_find_job_idx(id) >= 0) {
        ERR_PRINT(String("[SUS-cpp] register_job: duplicate id ") + String(id));
        return;
    }

    JobEntry je;
    je.id                   = id;
    je.priority             = (int)  descriptor.get("priority",             100);
    je.must_run             = (bool) descriptor.get("must_run",             false);
    je.starvation_threshold = (int)  descriptor.get("starvation_threshold", 0);
    je.max_slices_per_tick  = (int)  descriptor.get("max_slices_per_tick",  0);
    je.slice_budget_ms      = (float)(double)descriptor.get("slice_budget_ms", 4.0);
    je.job_obj              = job;

    Variant deps_v = descriptor.get("depends_on", Variant());
    if (deps_v.get_type() == Variant::ARRAY) {
        Array deps = (Array)deps_v;
        for (int i = 0; i < deps.size(); ++i) {
            // Store as String for PackedStringArray (hot-path comparison
            // uses String equality; StringName converts cheaply via String()).
            je.depends_on.append(String(deps[i]));
        }
    }

    Variant policy_v = descriptor.get("policy", Variant());
    if (policy_v.get_type() == Variant::DICTIONARY) {
        je.policy = _build_policy((Dictionary)policy_v);
    } else {
        // Mirror SusScheduler.register_job default: AlwaysPolicy.
        je.policy = new PolicyNode();
    }

    _jobs.push_back(je);
    _resort_jobs();

    // bind_world if already bound.
    if (_world_ref.get_type() != Variant::NIL) {
        job->call("bind_world", _world_ref);
    }
}

void SusSchedulerExt::unregister_job(const StringName &id) {
    int idx = _find_job_idx(id);
    if (idx < 0) return;
    _free_policy(_jobs[idx].policy);
    _jobs[idx].policy = nullptr;
    _jobs.erase(_jobs.begin() + idx);
}

bool SusSchedulerExt::has_job(const StringName &id) const {
    return _find_job_idx(id) >= 0;
}

// ─────────────────────────────────────────────────────────────────────────
// Stats helpers
// ─────────────────────────────────────────────────────────────────────────

SusSchedulerExt::JobStats *SusSchedulerExt::_get_or_create_stats(const StringName &id) {
    for (auto &kv : _stats) {
        if (kv.id == id) return &kv.s;
    }
    StatEntry e;
    e.id = id;
    _stats.push_back(e);
    return &_stats.back().s;
}

void SusSchedulerExt::_record_stats(const StringName &id, float elapsed_ms, int slices_run) {
    JobStats *s = _get_or_create_stats(id);
    s->samples.push_back(elapsed_ms);
    s->slices_total += slices_run;
    if (elapsed_ms > s->max_ms) s->max_ms = elapsed_ms;
}

void SusSchedulerExt::_record_skipped(const StringName &id, const String &reason) {
    JobStats *s = _get_or_create_stats(id);
    for (auto &kv : s->skipped) {
        if (kv.reason == reason) {
            kv.count += 1;
            return;
        }
    }
    JobStats::SkippedKV kv;
    kv.reason = reason;
    kv.count  = 1;
    s->skipped.push_back(kv);
}

void SusSchedulerExt::_record_tick_budget_sample(float total_ms,
                                                 const StringName &largest_job,
                                                 const String &largest_stage,
                                                 const String &largest_substage,
                                                 const String &largest_path,
                                                 float largest_ms,
                                                 int largest_work_done,
                                                 int largest_processed_cells,
                                                 int largest_processed_pixels,
                                                 int largest_processed_indices,
                                                 int largest_cursor_start,
                                                 int largest_cursor_end,
                                                 const String &largest_fallback_path) {
    BudgetSample s;
    s.total_ms              = total_ms;
    s.largest_slice_job     = largest_job;
    s.largest_slice_stage   = largest_stage;
    s.largest_slice_substage= largest_substage;
    s.largest_slice_path    = largest_path;
    s.largest_slice_ms      = largest_ms;
    s.largest_slice_work_done = largest_work_done;
    s.largest_slice_processed_cells = largest_processed_cells;
    s.largest_slice_processed_pixels = largest_processed_pixels;
    s.largest_slice_processed_indices = largest_processed_indices;
    s.largest_slice_cursor_start = largest_cursor_start;
    s.largest_slice_cursor_end = largest_cursor_end;
    s.largest_slice_fallback_path = largest_fallback_path;
    _tick_budget_samples.push_back(s);
    int cap = std::max(1, _sim_budget_window_size);
    while ((int)_tick_budget_samples.size() > cap) {
        _tick_budget_samples.erase(_tick_budget_samples.begin());
    }
}

String SusSchedulerExt::_slice_stage_name(const Dictionary &r) {
    static const char *keys[] = { "stage_name", "stage", "pass", "axis" };
    for (auto k : keys) {
        if (r.has(k)) return String(r[k]);
    }
    return String();
}

String SusSchedulerExt::_slice_substage_name(const Dictionary &r) {
    static const char *keys[] = { "substage", "micro_stage", "stage_detail" };
    for (auto k : keys) {
        if (r.has(k)) return String(r[k]);
    }
    return String();
}

bool SusSchedulerExt::_is_upload_job(const StringName &id) {
    static const StringName k_enum_atlas("enum_atlas_upload");
    static const StringName k_sea_ice("sea_ice_atlas_upload");
    static const StringName k_dynamic_visual("dynamic_visual_atlas_upload");
    return id == k_enum_atlas || id == k_sea_ice || id == k_dynamic_visual;
}

bool SusSchedulerExt::_slice_stage_looks_cell_based(const String &stage) {
    return stage.begins_with("weather_") || stage.begins_with("pass_")
        || stage == "ocean_water" || stage == "ocean_land"
        || stage == "sea_ice" || stage == "transp";
}

bool SusSchedulerExt::_slice_stage_looks_pixel_based(const String &stage) {
    return stage.find("pixel") >= 0 || stage.find("raster") >= 0;
}

double SusSchedulerExt::_processed_per_ms(int work_done, int processed_cells,
                                          int processed_pixels, int processed_indices,
                                          float elapsed_ms) {
    if (elapsed_ms <= 0.0f) return 0.0;
    int processed = std::max(work_done, std::max(processed_cells, std::max(processed_pixels, processed_indices)));
    return (double)processed / (double)elapsed_ms;
}

float SusSchedulerExt::_max_registered_slice_budget_ms(bool upload_jobs) const {
    float out = 0.0f;
    for (const auto &job : _jobs) {
        if (_is_upload_job(job.id) == upload_jobs) {
            out = std::max(out, job.slice_budget_ms);
        }
    }
    return out;
}

// ─────────────────────────────────────────────────────────────────────────
// Main dispatch — 1:1 with sus_scheduler.gd::tick (line 125-343).
// ─────────────────────────────────────────────────────────────────────────

void SusSchedulerExt::tick(Object *ctx) {
    if (ctx == nullptr) {
        ERR_PRINT("[SUS-cpp] tick: nil context");
        return;
    }
    _tick_counter += 1;
    _last_report.clear();

    TickCtxView ctx_view = _read_tick_ctx(ctx);

    int64_t tick_start_us = _now_us();
    int64_t budget_us     = (int64_t)(_frame_budget_ms * 1000.0f);

    // Per-tick scratch.
    Dictionary completed_this_tick;
    Dictionary in_flight_after_tick;
    int  jobs_ran                  = 0;
    int  optional_jobs_ran         = 0;
    int  jobs_skipped              = 0;
    int  slices_total_this_tick    = 0;
    StringName largest_slice_job_tick;
    String largest_slice_stage_tick;
    String largest_slice_substage_tick;
    String largest_slice_path_tick;
    float  largest_slice_ms_tick   = 0.0f;
    int    largest_slice_work_done_tick = 0;
    int    largest_slice_processed_cells_tick = 0;
    int    largest_slice_processed_pixels_tick = 0;
    int    largest_slice_processed_indices_tick = 0;
    int    largest_slice_cursor_start_tick = -1;
    int    largest_slice_cursor_end_tick = -1;
    String largest_slice_fallback_path_tick;
    float  sim_total_ms_tick       = 0.0f;

    // Build ordered_jobs (strict_budget rotation mirrors GDScript line 150-155).
    std::vector<int> ordered_idx;
    ordered_idx.reserve(_jobs.size());
    int n = (int)_jobs.size();
    if (_strict_budget_enabled && n > 1) {
        int start_idx = _posmod(_strict_next_job_index, n);
        for (int o = 0; o < n; ++o) {
            ordered_idx.push_back((start_idx + o) % n);
        }
    } else {
        for (int o = 0; o < n; ++o) ordered_idx.push_back(o);
    }

    for (int oi = 0; oi < (int)ordered_idx.size(); ++oi) {
        int j_idx = ordered_idx[oi];
        JobEntry &job = _jobs[j_idx];

        Dictionary report;
        report["id"]             = job.id;
        report["elapsed_ms"]     = 0.0;
        report["slices_run"]     = 0;
        report["progress_ratio"] = 0.0;
        report["skipped_reason"] = String();
        report["tick_index"]     = ctx_view.tick_index;
        report["source"]         = ctx_view.source;

        // ─── Budget / starvation gate (GD line 179-196) ──────────────────
        int64_t elapsed_us_now = _now_us() - tick_start_us;
        bool starving = (!_strict_budget_enabled)
                     && (job.starvation_threshold > 0)
                     && (job.starvation_count >= job.starvation_threshold);

        if (_strict_budget_enabled && optional_jobs_ran > 0 && !job.must_run) {
            report["skipped_reason"] = String("strict_budget_one_job");
            _last_report[Variant(job.id)] = report;
            _record_skipped(job.id, String("strict_budget_one_job"));
            job.starvation_count += 1;
            jobs_skipped += 1;
            continue;
        }
        if (elapsed_us_now >= budget_us && !job.must_run && !starving) {
            report["skipped_reason"] = String("frame_budget_exhausted");
            _last_report[Variant(job.id)] = report;
            _record_skipped(job.id, String("frame_budget_exhausted"));
            job.starvation_count += 1;
            jobs_skipped += 1;
            continue;
        }

        // ─── Policy gate (GD line 199-204) ───────────────────────────────
        // SusJob.should_run() default forwards to policy.should_run. Our
        // C++ policy eval covers all 6 PolicyKind cases without crossing
        // into GDScript (Accumulator getter still calls back for value).
        // If a Job overrides should_run, GD-side behaviour is still
        // policy-forwarding (per sus_job.gd line 87-90 default), so C++
        // policy eval is bit-equal.
        if (!_policy_should_run(job.policy, job.job_obj, ctx, ctx_view.tick_index)) {
            report["skipped_reason"] = String("policy_gated");
            _last_report[Variant(job.id)] = report;
            _record_skipped(job.id, String("policy_gated"));
            jobs_skipped += 1;
            continue;
        }

        // ─── Dependency gate (GD line 207-221) ───────────────────────────
        StringName blocked_by;
        for (int di = 0; di < job.depends_on.size(); ++di) {
            String dep_str = job.depends_on[di];
            StringName dep_id = StringName(dep_str);
            JobEntry *dep = _find_job_ptr(dep_id);
            if (dep != nullptr && dep->in_flight) {
                blocked_by = dep_id;
                break;
            }
            // in_flight_after_tick check (mirrors GD line 213-215).
            Variant key = Variant(dep_id);
            if (in_flight_after_tick.has(key) && (bool)in_flight_after_tick[key]) {
                blocked_by = dep_id;
                break;
            }
        }
        if (blocked_by != StringName()) {
            report["skipped_reason"] = String("dep_pending:") + String(blocked_by);
            _last_report[Variant(job.id)] = report;
            _record_skipped(job.id, String("dep_pending"));
            jobs_skipped += 1;
            continue;
        }

        // ─── Slice loop (GD line 223-285) ────────────────────────────────
        int64_t job_start_us       = _now_us();
        int64_t slice_budget_us    = (int64_t)(job.slice_budget_ms * 1000.0f);
        bool    done               = false;
        int     slices_run         = 0;
        int     work_done_total    = 0;
        float   last_progress_ratio= 0.0f;
        String  last_slice_stage;
        String  last_slice_substage;
        String  last_slice_path;
        int     last_slice_work_done = 0;
        int     last_slice_processed_cells = 0;
        int     last_slice_processed_pixels = 0;
        int     last_slice_processed_indices = 0;
        int     last_slice_cursor_start = -1;
        int     last_slice_cursor_end = -1;
        String  last_slice_fallback_path;
        job.in_flight = true;

        // Mirror sus_job.gd:_in_flight via Object::set so GDScript-side
        // diagnostics (if any reach into job._in_flight directly) still see
        // the right value. Keep this single set per slice loop (not per
        // slice) to minimise crossings.
        if (job.job_obj != nullptr) {
            job.job_obj->set("_in_flight", true);
        }

        while (true) {
            elapsed_us_now = _now_us() - tick_start_us;
            if (slices_run > 0 && elapsed_us_now >= budget_us && !job.must_run) break;
            int max_slices_this_tick = job.max_slices_per_tick;
            if (_strict_budget_enabled && max_slices_this_tick <= 0) max_slices_this_tick = 1;
            if (max_slices_this_tick > 0 && slices_run >= max_slices_this_tick) break;
            if (starving && slices_run >= 1) break;

            int64_t slice_start_us = _now_us();
            // The one unavoidable per-slice GD crossing — calling the SusJob's
            // run_slice(ctx) so the existing GDScript implementation runs
            // verbatim. This is exactly what plan B preserves: SUS shell
            // native, slice body still GD.
            Variant slice_result_v;
            if (job.job_obj != nullptr) {
                slice_result_v = job.job_obj->call("run_slice", Variant(ctx));
            }
            float slice_actual_ms = (float)(_now_us() - slice_start_us) / 1000.0f;
            slices_run += 1;

            if (slice_result_v.get_type() != Variant::DICTIONARY) {
                ERR_PRINT(String("[SUS-cpp] job ") + String(job.id) + " run_slice did not return Dictionary");
                done = true;
                break;
            }
            Dictionary slice_result = (Dictionary)slice_result_v;

            float slice_reported_ms = (float)(double)slice_result.get("elapsed_ms", (double)slice_actual_ms);
            float slice_ms = slice_actual_ms > slice_reported_ms ? slice_actual_ms : slice_reported_ms;
            last_slice_stage    = _slice_stage_name(slice_result);
            last_slice_substage = _slice_substage_name(slice_result);
            last_slice_path     = String(slice_result.get("path", String()));
            last_slice_work_done = (int)slice_result.get("work_done", 0);
            last_slice_processed_cells = (int)slice_result.get("processed_cells", 0);
            last_slice_processed_pixels = (int)slice_result.get("processed_pixels", 0);
            last_slice_processed_indices = (int)slice_result.get("processed_indices", 0);
            if (last_slice_processed_cells <= 0 && _slice_stage_looks_cell_based(last_slice_stage)) {
                last_slice_processed_cells = last_slice_work_done;
            }
            if (last_slice_processed_pixels <= 0 && _slice_stage_looks_pixel_based(last_slice_stage)) {
                last_slice_processed_pixels = last_slice_work_done;
            }
            if (last_slice_processed_indices <= 0 && last_slice_processed_cells <= 0 && last_slice_processed_pixels <= 0) {
                last_slice_processed_indices = last_slice_work_done;
            }
            last_slice_cursor_start = (int)slice_result.get("cursor_start", slice_result.get("start_idx", -1));
            last_slice_cursor_end = (int)slice_result.get("cursor_end", slice_result.get("end_idx", -1));
            last_slice_fallback_path = String(slice_result.get("fallback_path", String()));
            if (last_slice_fallback_path.is_empty() && (bool)slice_result.get("fallback", false)) {
                last_slice_fallback_path = last_slice_path;
            }

            if (!_is_upload_job(job.id) && slice_ms > largest_slice_ms_tick) {
                largest_slice_ms_tick       = slice_ms;
                largest_slice_job_tick      = job.id;
                largest_slice_stage_tick    = last_slice_stage;
                largest_slice_substage_tick = last_slice_substage;
                largest_slice_path_tick     = last_slice_path;
                largest_slice_work_done_tick = last_slice_work_done;
                largest_slice_processed_cells_tick = last_slice_processed_cells;
                largest_slice_processed_pixels_tick = last_slice_processed_pixels;
                largest_slice_processed_indices_tick = last_slice_processed_indices;
                largest_slice_cursor_start_tick = last_slice_cursor_start;
                largest_slice_cursor_end_tick = last_slice_cursor_end;
                largest_slice_fallback_path_tick = last_slice_fallback_path;
            }

            done                = (bool)slice_result.get("done", true);
            work_done_total    += (int)slice_result.get("work_done", 0);
            last_progress_ratio = (float)(double)slice_result.get("progress_ratio", 0.0);
            if (done) break;

            int64_t job_elapsed_us = _now_us() - job_start_us;
            if (job_elapsed_us >= slice_budget_us) break;
        }

        float job_elapsed_ms = (float)(_now_us() - job_start_us) / 1000.0f;
        report["elapsed_ms"]     = (double)job_elapsed_ms;
        report["slices_run"]     = slices_run;
        report["progress_ratio"] = (double)last_progress_ratio;
        report["stage"]          = last_slice_stage;
        report["substage"]       = last_slice_substage;
        report["path"]           = last_slice_path;
        report["work_done"]      = work_done_total;
        report["last_slice_work_done"] = last_slice_work_done;
        report["last_slice_processed_cells"] = last_slice_processed_cells;
        report["last_slice_processed_pixels"] = last_slice_processed_pixels;
        report["last_slice_processed_indices"] = last_slice_processed_indices;
        report["last_slice_cursor_start"] = last_slice_cursor_start;
        report["last_slice_cursor_end"] = last_slice_cursor_end;
        report["last_slice_fallback_path"] = last_slice_fallback_path;
        _last_report[Variant(job.id)] = report;
        _record_stats(job.id, job_elapsed_ms, slices_run);
        if (!_is_upload_job(job.id)) sim_total_ms_tick += job_elapsed_ms;

        jobs_ran += 1;
        if (!job.must_run) optional_jobs_ran += 1;
        if (_strict_budget_enabled && !job.must_run) {
            // Mirror GD line 303-305: rotate strict_next_job_index relative
            // to the original (pre-rotation) index.
            int original_idx = j_idx;
            int sz = std::max(1, n);
            _strict_next_job_index = (original_idx + 1) % sz;
        }
        slices_total_this_tick += slices_run;
        job.starvation_count = 0;

        if (done) {
            job.in_flight = false;
            if (job.job_obj != nullptr) {
                job.job_obj->set("_in_flight", false);
            }
            completed_this_tick[Variant(job.id)] = true;
            in_flight_after_tick[Variant(job.id)] = false;
            _policy_on_completed(job.policy, job.job_obj, ctx);
        } else {
            in_flight_after_tick[Variant(job.id)] = true;
        }
    }

    // ─── Tick-end summary (GD line 320-339) ──────────────────────────────
    float total_ms = (float)(_now_us() - tick_start_us) / 1000.0f;
    _record_tick_budget_sample(sim_total_ms_tick,
                               largest_slice_job_tick,
                               largest_slice_stage_tick,
                               largest_slice_substage_tick,
                               largest_slice_path_tick,
                               largest_slice_ms_tick,
                               largest_slice_work_done_tick,
                               largest_slice_processed_cells_tick,
                               largest_slice_processed_pixels_tick,
                               largest_slice_processed_indices_tick,
                               largest_slice_cursor_start_tick,
                               largest_slice_cursor_end_tick,
                               largest_slice_fallback_path_tick);
    Dictionary budget_window = _sim_budget_window_dict();

    _last_tick_summary.clear();
    _last_tick_summary["tick_index"]            = ctx_view.tick_index;
    _last_tick_summary["source"]                = ctx_view.source;
    _last_tick_summary["total_ms"]              = (double)total_ms;
    _last_tick_summary["jobs_ran"]              = jobs_ran;
    _last_tick_summary["jobs_skipped"]          = jobs_skipped;
    _last_tick_summary["slices_total"]          = slices_total_this_tick;
    _last_tick_summary["largest_slice_job"]     = largest_slice_job_tick;
    _last_tick_summary["largest_slice_stage"]   = largest_slice_stage_tick;
    _last_tick_summary["largest_slice_substage"]= largest_slice_substage_tick;
    _last_tick_summary["largest_slice_path"]    = largest_slice_path_tick;
    _last_tick_summary["largest_slice_ms"]      = (double)largest_slice_ms_tick;
    _last_tick_summary["largest_slice_work_done"] = largest_slice_work_done_tick;
    _last_tick_summary["largest_slice_processed_cells"] = largest_slice_processed_cells_tick;
    _last_tick_summary["largest_slice_processed_pixels"] = largest_slice_processed_pixels_tick;
    _last_tick_summary["largest_slice_processed_indices"] = largest_slice_processed_indices_tick;
    _last_tick_summary["largest_slice_cursor_start"] = largest_slice_cursor_start_tick;
    _last_tick_summary["largest_slice_cursor_end"] = largest_slice_cursor_end_tick;
    _last_tick_summary["largest_slice_fallback_path"] = largest_slice_fallback_path_tick;
    _last_tick_summary["largest_slice_processed_per_ms"] = _processed_per_ms(
        largest_slice_work_done_tick,
        largest_slice_processed_cells_tick,
        largest_slice_processed_pixels_tick,
        largest_slice_processed_indices_tick,
        largest_slice_ms_tick);
    _last_tick_summary["sus_sim_avg_300"]       = (double)(float)budget_window.get("sus_sim_avg_300", 0.0);
    _last_tick_summary["sim_frame_budget_ms"]   = (double)_frame_budget_ms;
    _last_tick_summary["sim_slice_budget_ms"]   = (double)_max_registered_slice_budget_ms(false);
    _last_tick_summary["sim_upload_slice_budget_ms"] = (double)_max_registered_slice_budget_ms(true);
    _last_tick_summary["sim_strict_budget_enabled"] = _strict_budget_enabled;
    _last_tick_summary["sim_budget_warn_ms"]    = (double)_sim_budget_warn_ms;
    _last_tick_summary["economy_reserved_budget_ms"] = (double)std::max(0.0f, 16.666f - _frame_budget_ms);
    _last_tick_summary["sus_sim_p95_300"]       = (double)(float)budget_window.get("sus_sim_p95_300", 0.0);
    _last_tick_summary["sus_sim_max_300"]       = (double)(float)budget_window.get("sus_sim_max_300", 0.0);
    _last_tick_summary["over_1ms_count_300"]    = (int)budget_window.get("over_1ms_count_300", 0);

    if (_log_interval_ticks > 0 && (_tick_counter % _log_interval_ticks) == 0) {
        _emit_periodic_log();
    }
}

// ─────────────────────────────────────────────────────────────────────────
// Reset / reporting
// ─────────────────────────────────────────────────────────────────────────

void SusSchedulerExt::reset_all_progress() {
    for (auto &je : _jobs) {
        if (je.job_obj != nullptr) {
            je.job_obj->call("reset_progress");
        }
        je.in_flight        = false;
        je.starvation_count = 0;
    }
    _last_report.clear();
    _last_tick_summary.clear();
    _tick_budget_samples.clear();
    _stats.clear();
    _tick_counter           = 0;
    _strict_next_job_index  = 0;
}

Dictionary SusSchedulerExt::report_last_tick() const {
    return _last_report.duplicate(true);
}

Dictionary SusSchedulerExt::report_last_tick_summary() const {
    return _last_tick_summary.duplicate(true);
}

Dictionary SusSchedulerExt::report_sim_budget_window() const {
    return _sim_budget_window_dict();
}

Dictionary SusSchedulerExt::report_skipped_summary() const {
    Dictionary out;
    for (const auto &kv : _stats) {
        Dictionary entry;
        Dictionary skipped;
        for (const auto &sk : kv.s.skipped) {
            skipped[sk.reason] = sk.count;
        }
        entry["skipped"] = skipped;
        entry["max_ms"]  = (double)kv.s.max_ms;
        out[Variant(kv.id)] = entry;
    }
    return out;
}

Dictionary SusSchedulerExt::report_job_stats() const {
    Dictionary out;
    for (const auto &kv : _stats) {
        Dictionary entry;
        // samples → Array of float
        Array samples;
        for (float v : kv.s.samples) samples.append((double)v);
        entry["samples"]      = samples;
        entry["slices_total"] = kv.s.slices_total;
        Dictionary skipped;
        for (const auto &sk : kv.s.skipped) skipped[sk.reason] = sk.count;
        entry["skipped"] = skipped;
        entry["max_ms"]  = (double)kv.s.max_ms;
        out[Variant(kv.id)] = entry;
    }
    return out;
}

Dictionary SusSchedulerExt::_sim_budget_window_dict() const {
    int sample_count = (int)_tick_budget_samples.size();
    Dictionary out;
    if (sample_count <= 0) {
        out["sus_sim_avg_300"]    = 0.0;
        out["sus_sim_p95_300"]    = 0.0;
        out["sus_sim_max_300"]    = 0.0;
        out["over_1ms_count_300"] = 0;
        out["largest_slice_job"]  = StringName();
        out["largest_slice_stage"]= String();
        out["largest_slice_substage"]= String();
        out["largest_slice_path"] = String();
        out["largest_slice_ms"]   = 0.0;
        out["largest_slice_work_done"] = 0;
        out["largest_slice_processed_cells"] = 0;
        out["largest_slice_processed_pixels"] = 0;
        out["largest_slice_processed_indices"] = 0;
        out["largest_slice_cursor_start"] = -1;
        out["largest_slice_cursor_end"] = -1;
        out["largest_slice_fallback_path"] = String();
        out["largest_slice_processed_per_ms"] = 0.0;
        out["sim_frame_budget_ms"] = (double)_frame_budget_ms;
        out["sim_slice_budget_ms"] = (double)_max_registered_slice_budget_ms(false);
        out["sim_upload_slice_budget_ms"] = (double)_max_registered_slice_budget_ms(true);
        out["sim_strict_budget_enabled"] = _strict_budget_enabled;
        out["sim_budget_warn_ms"] = (double)_sim_budget_warn_ms;
        out["economy_reserved_budget_ms"] = (double)std::max(0.0f, 16.666f - _frame_budget_ms);
        out["sample_count"]       = 0;
        return out;
    }
    std::vector<float> totals;
    totals.reserve(sample_count);
    float sum_total_ms = 0.0f;
    float max_total_ms = 0.0f;
    int   over_count   = 0;
    StringName largest_job;
    String largest_stage, largest_substage, largest_path;
    float  largest_ms = 0.0f;
    int largest_work_done = 0;
    int largest_processed_cells = 0;
    int largest_processed_pixels = 0;
    int largest_processed_indices = 0;
    int largest_cursor_start = -1;
    int largest_cursor_end = -1;
    String largest_fallback_path;
    for (const auto &s : _tick_budget_samples) {
        totals.push_back(s.total_ms);
        sum_total_ms += s.total_ms;
        if (s.total_ms > max_total_ms) max_total_ms = s.total_ms;
        if (s.total_ms > _sim_budget_warn_ms) over_count += 1;
        if (s.largest_slice_ms > largest_ms) {
            largest_ms       = s.largest_slice_ms;
            largest_job      = s.largest_slice_job;
            largest_stage    = s.largest_slice_stage;
            largest_substage = s.largest_slice_substage;
            largest_path     = s.largest_slice_path;
            largest_work_done = s.largest_slice_work_done;
            largest_processed_cells = s.largest_slice_processed_cells;
            largest_processed_pixels = s.largest_slice_processed_pixels;
            largest_processed_indices = s.largest_slice_processed_indices;
            largest_cursor_start = s.largest_slice_cursor_start;
            largest_cursor_end = s.largest_slice_cursor_end;
            largest_fallback_path = s.largest_slice_fallback_path;
        }
    }
    std::sort(totals.begin(), totals.end());
    int p95_idx = (int)std::ceil(totals.size() * 0.95) - 1;
    if (p95_idx < 0) p95_idx = 0;
    if (p95_idx >= (int)totals.size()) p95_idx = (int)totals.size() - 1;
    float avg_total_ms = sum_total_ms / (float)std::max(1, sample_count);
    double processed_per_ms = _processed_per_ms(largest_work_done, largest_processed_cells,
                                                largest_processed_pixels, largest_processed_indices,
                                                largest_ms);
    out["sus_sim_avg_300"]      = (double)avg_total_ms;
    out["sus_sim_p95_300"]      = (double)totals[p95_idx];
    out["sus_sim_max_300"]      = (double)max_total_ms;
    out["over_1ms_count_300"]   = over_count;
    out["largest_slice_job"]    = largest_job;
    out["largest_slice_stage"]  = largest_stage;
    out["largest_slice_substage"]= largest_substage;
    out["largest_slice_path"]   = largest_path;
    out["largest_slice_ms"]     = (double)largest_ms;
    out["largest_slice_work_done"] = largest_work_done;
    out["largest_slice_processed_cells"] = largest_processed_cells;
    out["largest_slice_processed_pixels"] = largest_processed_pixels;
    out["largest_slice_processed_indices"] = largest_processed_indices;
    out["largest_slice_cursor_start"] = largest_cursor_start;
    out["largest_slice_cursor_end"] = largest_cursor_end;
    out["largest_slice_fallback_path"] = largest_fallback_path;
    out["largest_slice_processed_per_ms"] = processed_per_ms;
    out["sim_frame_budget_ms"] = (double)_frame_budget_ms;
    out["sim_slice_budget_ms"] = (double)_max_registered_slice_budget_ms(false);
    out["sim_upload_slice_budget_ms"] = (double)_max_registered_slice_budget_ms(true);
    out["sim_strict_budget_enabled"] = _strict_budget_enabled;
    out["sim_budget_warn_ms"] = (double)_sim_budget_warn_ms;
    out["economy_reserved_budget_ms"] = (double)std::max(0.0f, 16.666f - _frame_budget_ms);
    out["sample_count"]         = sample_count;
    return out;
}

void SusSchedulerExt::_emit_periodic_log() {
    // Mirror GD line 527-572 verbatim. Per-job line + budget tail line.
    for (auto &kv : _stats) {
        JobStats &s = kv.s;
        if (s.samples.empty() && s.skipped.empty()) continue;
        float avg_ms = 0.0f, p95_ms = 0.0f;
        float max_ms_local = s.max_ms;
        if (!s.samples.empty()) {
            float sum = 0.0f;
            for (float v : s.samples) sum += v;
            avg_ms = sum / (float)s.samples.size();
            std::vector<float> sorted = s.samples;
            std::sort(sorted.begin(), sorted.end());
            int p95_idx = (int)std::ceil(sorted.size() * 0.95) - 1;
            if (p95_idx < 0) p95_idx = 0;
            if (p95_idx >= (int)sorted.size()) p95_idx = (int)sorted.size() - 1;
            p95_ms = sorted[p95_idx];
        }
        String skipped_str;
        if (!s.skipped.empty()) {
            String parts;
            for (size_t i = 0; i < s.skipped.size(); ++i) {
                if (i > 0) parts += ",";
                parts += s.skipped[i].reason + "=" + String::num_int64(s.skipped[i].count);
            }
            skipped_str = String(" skipped[") + parts + "]";
        }
        UtilityFunctions::print(
            String("[SUS-cpp] last ") + String::num_int64(_log_interval_ticks)
            + " ticks: " + String(kv.id)
            + " ran=" + String::num_int64(s.samples.size())
            + " avg=" + String::num(avg_ms, 2) + "ms"
            + " p95=" + String::num(p95_ms, 2) + "ms"
            + " max=" + String::num(max_ms_local, 2) + "ms"
            + " slices=" + String::num_int64(s.slices_total)
            + skipped_str);
        s.samples.clear();
        s.slices_total = 0;
        s.skipped.clear();
        s.max_ms = 0.0f;
    }
    Dictionary bw = _sim_budget_window_dict();
    int sc = (int)bw.get("sample_count", 0);
    if (sc > 0) {
        UtilityFunctions::print(
            String("[SUS-cpp] budget last ") + String::num_int64(sc)
            + " ticks: total_p95=" + String::num((double)bw.get("sus_sim_p95_300", 0.0), 2) + "ms"
            + " max=" + String::num((double)bw.get("sus_sim_max_300", 0.0), 2) + "ms"
            + " over_1ms=" + String::num_int64((int)bw.get("over_1ms_count_300", 0))
            + " largest=" + String(bw.get("largest_slice_job", String()))
            + "/" + String(bw.get("largest_slice_stage", String()))
            + "/" + String(bw.get("largest_slice_substage", String()))
            + " path=" + String(bw.get("largest_slice_path", String()))
            + " " + String::num((double)bw.get("largest_slice_ms", 0.0), 2) + "ms");
    }
    // World-bound diagnostic tail: mirror GD line 575-581.
    if (_world_ref.get_type() != Variant::NIL) {
        Object *w = (Object*)_world_ref;
        if (w != nullptr && w->has_method("is_bound") && (bool)w->call("is_bound")) {
            int ent_n  = w->has_method("entity_count")    ? (int)w->call("entity_count")    : 0;
            int comp_n = w->has_method("component_count") ? (int)w->call("component_count") : 0;
            int pool_n = w->has_method("pool_count")      ? (int)w->call("pool_count")      : 0;
            UtilityFunctions::print(
                String("[SUS-cpp] world: bound=true entities=") + String::num_int64(ent_n)
                + " components=" + String::num_int64(comp_n)
                + " pools=" + String::num_int64(pool_n));
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────
// _bind_methods
// ─────────────────────────────────────────────────────────────────────────

void SusSchedulerExt::_bind_methods() {
    ClassDB::bind_method(D_METHOD("set_frame_budget_ms",       "v"),  &SusSchedulerExt::set_frame_budget_ms);
    ClassDB::bind_method(D_METHOD("get_frame_budget_ms"),              &SusSchedulerExt::get_frame_budget_ms);
    ClassDB::bind_method(D_METHOD("set_strict_budget_enabled", "v"),  &SusSchedulerExt::set_strict_budget_enabled);
    ClassDB::bind_method(D_METHOD("get_strict_budget_enabled"),        &SusSchedulerExt::get_strict_budget_enabled);
    ClassDB::bind_method(D_METHOD("set_log_interval_ticks",    "v"),  &SusSchedulerExt::set_log_interval_ticks);
    ClassDB::bind_method(D_METHOD("get_log_interval_ticks"),           &SusSchedulerExt::get_log_interval_ticks);
    ClassDB::bind_method(D_METHOD("set_sim_budget_window_size","v"),  &SusSchedulerExt::set_sim_budget_window_size);
    ClassDB::bind_method(D_METHOD("get_sim_budget_window_size"),       &SusSchedulerExt::get_sim_budget_window_size);
    ClassDB::bind_method(D_METHOD("set_sim_budget_warn_ms",    "v"),  &SusSchedulerExt::set_sim_budget_warn_ms);
    ClassDB::bind_method(D_METHOD("get_sim_budget_warn_ms"),           &SusSchedulerExt::get_sim_budget_warn_ms);

    ClassDB::bind_method(D_METHOD("bind_world",       "world"),                  &SusSchedulerExt::bind_world);
    ClassDB::bind_method(D_METHOD("register_job",     "job", "descriptor"),     &SusSchedulerExt::register_job);
    ClassDB::bind_method(D_METHOD("unregister_job",   "id"),                     &SusSchedulerExt::unregister_job);
    ClassDB::bind_method(D_METHOD("has_job",          "id"),                     &SusSchedulerExt::has_job);
    ClassDB::bind_method(D_METHOD("job_count"),                                  &SusSchedulerExt::job_count);

    ClassDB::bind_method(D_METHOD("tick",             "ctx"),                    &SusSchedulerExt::tick);
    ClassDB::bind_method(D_METHOD("reset_all_progress"),                         &SusSchedulerExt::reset_all_progress);

    ClassDB::bind_method(D_METHOD("report_last_tick"),         &SusSchedulerExt::report_last_tick);
    ClassDB::bind_method(D_METHOD("report_last_tick_summary"), &SusSchedulerExt::report_last_tick_summary);
    ClassDB::bind_method(D_METHOD("report_sim_budget_window"), &SusSchedulerExt::report_sim_budget_window);
    ClassDB::bind_method(D_METHOD("report_skipped_summary"),   &SusSchedulerExt::report_skipped_summary);
    ClassDB::bind_method(D_METHOD("report_job_stats"),         &SusSchedulerExt::report_job_stats);
}

} // namespace pk
