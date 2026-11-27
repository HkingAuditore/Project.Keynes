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
    return id == k_enum_atlas || id == k_sea_ice;
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

} // namespace pk
