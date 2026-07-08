#pragma once

// SusSchedulerExt — C++ mirror of `scripts/simulation/sus/sus_scheduler.gd`
// (SlicedUpdateScheduler).
//
// Phase 1A scope (plan/sus-cpp-port, "真·激进版"):
//   ① Main dispatch loop (priority sort, frame_budget gate, depends_on gate,
//      per-job slice loop, starvation guard, strict_budget rotation) all in
//      C++.
//   ② Policy gate (Always / Stride / ContinuousSliced / And / Or) evaluated
//      in C++ without crossing into GDScript. Accumulator policy still
//      crosses once per gate (Callable getter); on_job_completed stays in C++
//      except for the optional resetter Callable.
//   ③ Job entry state (id / priority / depends_on / must_run /
//      starvation_threshold / max_slices_per_tick / slice_budget_ms /
//      _starvation_count / _in_flight) is owned by C++. The actual SusJob
//      RefCounted object lives on the GDScript side; C++ holds its Object*
//      and dispatches `run_slice(ctx)` / `should_run(ctx)` (only when
//      `use_job_should_run=true`) / `policy.on_job_completed`
//      via Object::call() — exactly mirroring the GDScript scheduler's
//      virtual dispatch.
//   ④ Telemetry buffers (last_report / last_tick_summary /
//      tick_budget_samples / per-job stats / periodic log) are 1:1 mirrored.
//
// Job inner work (run_slice body) is NOT ported in Phase 1A — it stays in
// GDScript. C++ → GDScript crossings per tick drop from ~40 (per-job loop
// overhead + policy + dep + reporting) to ~5–10 (one call per actually-run
// slice, plus accumulator getter calls), giving the bulk of the planned
// SUS-orchestration speedup. Phase 2 will port hot baker/generator methods
// to C++ to eliminate the remaining per-slice crossings.
//
// SAME-SOURCE A/B contract:
//   GDScript-side `SusScheduler.gd::use_gdext_sus_scheduler` flips between
//   the legacy GDScript SlicedUpdateScheduler and this C++ port. Behaviour
//   must be **bit-equal** — same job order per tick, same slice counts,
//   same skipped reasons. Telemetry numbers (elapsed_ms / total_ms) are
//   timing-dependent and only required to be within ±20% perf budget.

#include <cstdint>
#include <vector>

#include <godot_cpp/classes/object.hpp>
#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/callable.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_string_array.hpp>
#include <godot_cpp/variant/string_name.hpp>

namespace pk {

class SusSchedulerExt : public godot::RefCounted {
    GDCLASS(SusSchedulerExt, godot::RefCounted);

public:
    SusSchedulerExt();
    ~SusSchedulerExt() override;

    // ─── Configuration mirrors of SlicedUpdateScheduler exports ──────────
    // GDScript/SUS and C++ mirror share one cross-platform safety clamp. The
    // actual budget is owned by ClimateProfile.sim_frame_budget_ms; earth_like.tres
    // intentionally uses the same value on desktop and mobile.
    void   set_frame_budget_ms      (float v) {
        _frame_budget_ms = v < 0.25f ? 0.25f : (v > 16.0f ? 16.0f : v);
    }
    float  get_frame_budget_ms      () const  { return _frame_budget_ms; }
    void   set_strict_budget_enabled(bool v)  { _strict_budget_enabled = v; }
    bool   get_strict_budget_enabled() const  { return _strict_budget_enabled; }
    void   set_log_interval_ticks   (int v)   { _log_interval_ticks = v; }
    int    get_log_interval_ticks   () const  { return _log_interval_ticks; }
    // Fix #11 second pass (2026-06-16) — 镜像 GDScript 端 PKLog.enabled 全局开关。
    // false 时跳过 _emit_periodic_log 里所有 print 站点（每 log_interval_ticks
    // 一次的 7 job × 1 budget summary = 8 行 print，每行 logcat ~5-10ms = mobile
    // 60FPS budget 杀手）。GDScript 通过 set_diag_logs_enabled 推到 C++ 端。
    void   set_diag_logs_enabled    (bool v)  { _diag_logs_enabled = v; }
    bool   get_diag_logs_enabled    () const  { return _diag_logs_enabled; }
    void   set_sim_budget_window_size(int v);
    int    get_sim_budget_window_size() const { return _sim_budget_window_size; }
    void   set_sim_budget_warn_ms   (float v) { _sim_budget_warn_ms = v; }
    float  get_sim_budget_warn_ms   () const  { return _sim_budget_warn_ms; }

    // ─── World binding (DataCore world reference; opaque Object*) ────────
    // Stored as a strong reference via _world_ref (Variant). Forwarded to
    // every registered job and to any future register_job by calling
    // job->call("bind_world", w).
    void bind_world(godot::Variant w);

    // ─── Registration ────────────────────────────────────────────────────
    //
    // The GDScript caller wraps SusJob fields into a descriptor Dictionary
    // so C++ can mirror them without poking at GDScript-side property
    // reflection on every tick:
    //
    //   { "id"                   : StringName,
    //     "priority"             : int,
    //     "must_run"             : bool,
    //     "use_job_should_run"   : bool,   // opt-in GDScript should_run gate
    //     "starvation_threshold" : int,
    //     "max_slices_per_tick"  : int,
    //     "slice_budget_ms"      : float,
    //     "depends_on"           : Array[StringName],
    //     "policy"               : Dictionary {  // see PolicyKind
    //          "kind" : "always"|"stride"|"accumulator"|"continuous"|"and"|"or",
    //          // stride / continuous:
    //          "stride" : int,             // also used for ticks_per_slice
    //          "phase"  : int,             // phase or _phase_offset
    //          // accumulator:
    //          "threshold": float,
    //          "getter"   : Callable,
    //          "resetter" : Callable,      // optional
    //          // and / or:
    //          "a" : Dictionary,
    //          "b" : Dictionary,
    //     }
    //   }
    //
    // The Object* SusJob is held weak (GDScript keeps the strong RefCounted
    // ref via SlicedUpdateScheduler._jobs in its facade). C++ never owns
    // the lifetime; unregister_job / reset_all_progress drop the pointer.
    void register_job(godot::Object *job, godot::Dictionary descriptor);

    void unregister_job(const godot::StringName &id);
    bool has_job       (const godot::StringName &id) const;
    int  job_count     () const { return static_cast<int>(_jobs.size()); }

    // ─── Dispatch ────────────────────────────────────────────────────────
    // ctx is a GDScript SusTickContext RefCounted (passed as Object* so the
    // existing GDScript Job.run_slice(ctx) call works unchanged). C++ reads
    // tick_index / source via ctx->get(...) once at tick start — no per-job
    // reflection.
    void tick(godot::Object *ctx);

    void reset_all_progress();

    // ─── Reporting (1:1 with GDScript scheduler) ─────────────────────────
    godot::Dictionary report_last_tick         () const;
    godot::Dictionary report_last_tick_summary () const;
    godot::Dictionary report_sim_budget_window () const;
    godot::Dictionary report_skipped_summary   () const;
    godot::Dictionary report_job_stats         () const;

protected:
    static void _bind_methods();

private:
    // ─── Policy node (C++ mirror of SusPolicy hierarchy) ─────────────────
    enum class PolicyKind : int {
        Always       = 0,
        Stride       = 1,
        Accumulator  = 2,
        Continuous   = 3,
        And          = 4,
        Or           = 5,
    };

    struct PolicyNode {
        PolicyKind kind = PolicyKind::Always;

        // Stride / Continuous shared params.
        int   stride       = 1;     // stride for Stride, ticks_per_slice for Continuous
        int   phase        = 0;     // phase offset for both

        // Accumulator params.
        float           threshold = 1.0f;
        godot::Callable getter;
        godot::Callable resetter;

        // And / Or children (heap-owned via unique_ptr, but we use raw
        // pointers + manual delete in JobEntry destructor for simplicity
        // — Godot's Vector cannot hold non-copyable types easily).
        PolicyNode *a = nullptr;
        PolicyNode *b = nullptr;
    };

    // ─── Job entry (C++ shadow of registered SusJob) ─────────────────────
    struct JobEntry {
        godot::StringName id;
        int               priority             = 100;
        bool              must_run             = false;
        bool              use_job_should_run   = false;
        int               starvation_threshold = 0;
        int               max_slices_per_tick  = 0;
        float             slice_budget_ms      = 4.0f;
        godot::PackedStringArray depends_on;       // StringName stored as String for
                                                   // PackedArray compatibility; compared
                                                   // by string equality at gate time.
        PolicyNode       *policy               = nullptr;

        // Live state (mirrors SusJob._in_flight / _starvation_count).
        bool              in_flight        = false;
        int               starvation_count = 0;

        // Weak ref to GDScript SusJob RefCounted. Lifetime owned by GD-side
        // SusScheduler facade (which holds it inside _jobs Array).
        godot::Object    *job_obj = nullptr;
    };

    // ─── Per-job rolling stats (mirrors _stats[id]) ──────────────────────
    struct JobStats {
        std::vector<float>  samples;
        int                 slices_total = 0;
        // skipped reason → count.
        struct SkippedKV { godot::String reason; int count = 0; };
        std::vector<SkippedKV> skipped;
        float               max_ms       = 0.0f;
    };

    // ─── Tick budget rolling sample (mirrors _tick_budget_samples entry) ─
    struct BudgetSample {
        float           total_ms;
        godot::StringName largest_slice_job;
        godot::String     largest_slice_stage;
        godot::String     largest_slice_substage;
        godot::String     largest_slice_path;
        float           largest_slice_ms;
        int             largest_slice_work_done = 0;
        int             largest_slice_processed_cells = 0;
        int             largest_slice_processed_pixels = 0;
        int             largest_slice_processed_indices = 0;
        int             largest_slice_cursor_start = -1;
        int             largest_slice_cursor_end = -1;
        godot::String   largest_slice_fallback_path;
    };

    // ─── Helpers ─────────────────────────────────────────────────────────
    PolicyNode *_build_policy(const godot::Dictionary &d) const;
    void        _free_policy(PolicyNode *p);
    bool        _policy_should_run(PolicyNode *p, godot::Object *job, godot::Object *ctx, int tick_index) const;
    void        _policy_on_completed(PolicyNode *p, godot::Object *job, godot::Object *ctx) const;

    int         _find_job_idx(const godot::StringName &id) const;
    JobEntry   *_find_job_ptr(const godot::StringName &id);
    void        _resort_jobs(); // by priority ascending

    void        _record_stats  (const godot::StringName &id, float elapsed_ms, int slices_run);
    void        _record_skipped(const godot::StringName &id, const godot::String &reason);
    void        _record_tick_budget_sample(float total_ms,
                                           const godot::StringName &largest_job,
                                           const godot::String &largest_stage,
                                           const godot::String &largest_substage,
                                           const godot::String &largest_path,
                                           float largest_ms,
                                           int largest_work_done = 0,
                                           int largest_processed_cells = 0,
                                           int largest_processed_pixels = 0,
                                           int largest_processed_indices = 0,
                                           int largest_cursor_start = -1,
                                           int largest_cursor_end = -1,
                                           const godot::String &largest_fallback_path = godot::String());
    godot::Dictionary _sim_budget_window_dict() const;

    static godot::String _slice_stage_name   (const godot::Dictionary &slice_result);
    static godot::String _slice_substage_name(const godot::Dictionary &slice_result);
    static bool          _is_upload_job      (const godot::StringName &id);
    static bool          _slice_stage_looks_cell_based (const godot::String &stage);
    static bool          _slice_stage_looks_pixel_based(const godot::String &stage);
    static double        _processed_per_ms(int work_done, int processed_cells,
                                           int processed_pixels, int processed_indices,
                                           float elapsed_ms);
    float       _max_registered_slice_budget_ms(bool upload_jobs) const;

    void        _emit_periodic_log();

    // ─── State ───────────────────────────────────────────────────────────
    float _frame_budget_ms        = 2.0f;
    bool  _strict_budget_enabled  = false;
    int   _sim_budget_window_size = 300;
    float _sim_budget_warn_ms     = 1.0f;
    int   _log_interval_ticks     = 30;
    bool  _diag_logs_enabled      = true;  // Fix #11 second pass (2026-06-16)，GDScript PKLog.enabled 镜像

    std::vector<JobEntry>                                       _jobs;
    godot::Dictionary                                           _last_report;
    godot::Dictionary                                           _last_tick_summary;
    std::vector<BudgetSample>                                   _tick_budget_samples;

    // Per-job rolling stats. Keyed by StringName via linear scan over a
    // small vector (N ≤ 10 in practice — same as GDScript scheduler).
    struct StatEntry { godot::StringName id; JobStats s; };
    std::vector<StatEntry>                                      _stats;
    JobStats *                                                  _get_or_create_stats(const godot::StringName &id);

    int   _tick_counter            = 0;
    int   _strict_next_job_index   = 0;

    // World ref kept as Variant to retain strong reference / proper RefCounted
    // accounting when passed in from GDScript.
    godot::Variant _world_ref;
};

} // namespace pk
