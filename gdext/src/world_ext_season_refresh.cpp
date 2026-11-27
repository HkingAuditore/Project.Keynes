#include "world_ext.h"
#include "world_ext_season_stage.h"

#include "component_bind_table.gen.h"  // A1 / dots-migration-roadmap §3 — autogen by tools/codegen/gen_cpp_bind_table.py
#include "system_schedule.h"           // Phase C.1 — 静态 DAG 调度图
#include "parallel_dispatcher.h"       // Phase C.3a — 并行分发 helper（统一 5 个手写 _thread）

// MSVC 默认不定义 M_PI；必须在引入 <cmath> 之前打开 _USE_MATH_DEFINES。
// 双保险：仍未定义时手动兜底，避免某些编译器/PCH 顺序问题。
#ifndef _USE_MATH_DEFINES
#define _USE_MATH_DEFINES
#endif

#include <godot_cpp/classes/global_constants.hpp>
#include <godot_cpp/classes/fast_noise_lite.hpp>          // native world-gen 复刻：与 GDScript _init_noise 同一引擎噪声
#include <godot_cpp/classes/random_number_generator.hpp>  // native world-gen 复刻：与 GDScript _rng 同一引擎 PCG
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/core/error_macros.hpp>
#include <godot_cpp/core/math.hpp>
#include <godot_cpp/variant/char_string.hpp>
#include <godot_cpp/variant/utility_functions.hpp>
#include <godot_cpp/variant/variant.hpp>

#include <algorithm>
#include <atomic>
#include <charconv>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstring>
#ifndef M_PI
#define M_PI 3.14159265358979323846
#endif
#include <condition_variable>
#include <cstring>
#include <limits>
#include <memory>
#include <mutex>
#include <functional>
#include <queue>
#include <string>
#include <thread>
#include <unordered_map>
#include <utility>
#include <vector>

#if defined(PK_HAVE_AVX2) && PK_HAVE_AVX2
#  include <immintrin.h>
#endif


#include "world_ext_internal.h"

namespace pk {

using namespace godot;

SeasonStageArrays::SeasonStageArrays(const Dictionary &knobs)
    : neighbors(knobs.get("neighbor_indices", PackedInt32Array())),
      rows(knobs.get("row_indices", PackedInt32Array())),
      latitude(knobs.get("lat_temp_rows", PackedFloat32Array())),
      season_offsets(knobs.get("season_offset_rows", PackedFloat32Array())),
      jitter(knobs.get("jitter_arr", PackedFloat32Array())),
      donors(knobs.get("donor_table", PackedFloat32Array())),
      soil(knobs.get("soil_moisture_arr", PackedFloat32Array())),
      growth_pressure(knobs.get("veg_growth_pressure_arr", PackedFloat32Array())) {}

// Preparation owns all Godot reads. The returned math captures scalars and
// pointers into the caller's retained columns and is independent of the scene.
PreparedSeasonStage prepare_season_stage(
        const std::function<int(const char *)> &component, const std::function<Slot &(int)> &slot,
        const Dictionary &knobs, SeasonStageArrays &arrays, int stage) {
    auto fail = [](const char *reason) {
        return PreparedSeasonStage{{}, {}, reason};
    };
    if (stage == 0) {
        if (!knobs.has("n_cells") || !knobs.has("moist_scale")) {
            return fail("stage_0 missing required knob (n_cells / moist_scale)");
        }
        const int n_cells = int(knobs["n_cells"]);
        const double moist_scale = double(knobs["moist_scale"]);
        if (n_cells <= 0) return fail("stage_0 n_cells <= 0");

        const int sid_terrain      = component("cell_terrain");
        const int sid_moist        = component("cell_moisture");
        const int sid_base_m       = component("cell_base_moisture");
        if (sid_terrain < 0 || sid_moist < 0 || sid_base_m < 0) {
            return fail("stage_0 missing slot id (terrain/moisture/base_moisture)");
        }
        Slot &s_t = slot(sid_terrain);
        Slot &s_m = slot(sid_moist);
        Slot &s_bm = slot(sid_base_m);
        if (s_t.arr_u8.size() != n_cells || s_m.arr_f32.size() != n_cells ||
            s_bm.arr_f32.size() != n_cells) {
            return fail("stage_0 slot array size mismatch");
        }
        const uint8_t * const __restrict TERR = s_t.arr_u8.ptr();
        const float   * const __restrict BASE = s_bm.arr_f32.ptr();
        float         * const __restrict M    = s_m.arr_f32.ptrw();

        PreparedSeasonStage prepared;
        prepared.slots = {sid_moist};
        prepared.compute = [=]() -> SeasonStageCounts {
            for (int i = 0; i < n_cells; ++i) {
                if (pk_is_water_terrain(TERR[i])) {
                    M[i] = BASE[i];
                } else {
                    double m = double(BASE[i]) * moist_scale;
                    if (m < 0.0) m = 0.0;
                    else if (m > 1.0) m = 1.0;
                    M[i] = float(m);
                }
            }
            return {n_cells};
        };
        return prepared;
    }
    if (stage == 10) {
        if (!knobs.has("n_cells") || !knobs.has("decay") ||
            !knobs.has("soil_moisture_arr") || !knobs.has("veg_growth_pressure_arr")) {
            return fail("stage_10 missing required knob (n_cells/decay/soil_moisture_arr/veg_growth_pressure_arr)");
        }
        const int n_cells = int(knobs["n_cells"]);
        const double decay = double(knobs["decay"]);
        if (n_cells <= 0) return fail("stage_10 n_cells <= 0");

        const int sid_terrain = component("cell_terrain");
        const int sid_base_m  = component("cell_base_moisture");
        if (sid_terrain < 0 || sid_base_m < 0) {
            return fail("stage_10 missing slot id (terrain/base_moisture)");
        }
        Slot &s_t = slot(sid_terrain);
        Slot &s_bm = slot(sid_base_m);
        if (s_t.arr_u8.size() != n_cells || s_bm.arr_f32.size() != n_cells) {
            return fail("stage_10 slot array size mismatch (terrain/base_moisture)");
        }
        auto &soil_arr = arrays.soil;
        auto &vg_arr = arrays.growth_pressure;
        if (soil_arr.size() != n_cells || vg_arr.size() != n_cells) {
            return fail("stage_10 soil/vg arr size mismatch");
        }

        const uint8_t * const __restrict TERR = s_t.arr_u8.ptr();
        float         * const __restrict BASE = s_bm.arr_f32.ptrw();
        float         * const __restrict SOIL = soil_arr.ptrw();
        float         * const __restrict VG   = vg_arr.ptrw();
        constexpr double FEEDBACK_SOIL_TO_BASE_W = 0.15;

        PreparedSeasonStage prepared;
        prepared.slots = {sid_base_m};
        prepared.compute = [=]() -> SeasonStageCounts {
            int touched = 0;
            for (int i = 0; i < n_cells; ++i) {
                if (pk_is_water_terrain(TERR[i])) continue;
                const double sm = double(SOIL[i]);
                if (sm > 1e-4 || sm < -1e-4) {
                    double bm = double(BASE[i]) + FEEDBACK_SOIL_TO_BASE_W * sm;
                    if (bm < 0.0) bm = 0.0;
                    else if (bm > 1.0) bm = 1.0;
                    BASE[i] = float(bm);
                    ++touched;
                }
                SOIL[i] = float(sm * decay);
                VG[i]   = float(double(VG[i]) * decay);
            }
            return {touched};
        };
        return prepared;
    }
#include "world_ext_season_refresh_section_terrain_and_rivers.inc"
#include "world_ext_season_refresh_section_vegetation_coast_and_glacier.inc"
    // ─── stage 8 was the original sentinel; rename to stage 9: swamp_pass ─
    // 注意：GDScript 的 12-stage 切片 stage 8=swamp_pass、stage 9=sync_current_state；
    // 而 C++ 端历史上把 stage 8 用作 sync_current_state（与 _run_season_refresh_stage8_gdext
    // 同步）。本次新增 swamp 用 stage_id=9 入口避免与已有 stage 8 冲突。GDScript caller
    // 在新 helper _run_season_refresh_stage_swamp_gdext 里发 stage=9。
    // SAME_SOURCE: map_generator.gd::_apply_swamp_pass (line 3330).
    if (stage == 9) {
        if (!knobs.has("n_cells") || !knobs.has("height") || !knobs.has("sea_level") ||
            !knobs.has("lat_temp_rows") || !knobs.has("row_indices") ||
            !knobs.has("neighbor_indices")) {
            return fail("stage_9 missing required knob");
        }
        const int n_cells = int(knobs["n_cells"]);
        const int height = int(knobs["height"]);
        const float sea_level = float(knobs["sea_level"]);
        if (n_cells <= 0 || height <= 0) return fail("stage_9 invalid dims");
        auto &lat_tab = arrays.latitude;
        auto &row_idx = arrays.rows;
        auto &nb_arr = arrays.neighbors;
        if (lat_tab.size() < height) return fail("stage_9 lat_temp_rows size");
        if (row_idx.size() != n_cells) return fail("stage_9 row_indices size");
        if (nb_arr.size() < n_cells * 6) return fail("stage_9 neighbor_indices size");

        const int sid_terrain  = component("cell_terrain");
        const int sid_moist    = component("cell_moisture");
        const int sid_elev     = component("cell_elevation");
        const int sid_river    = component("cell_has_river");
        const int sid_landform = component("cell_landform");
        if (sid_terrain < 0 || sid_moist < 0 || sid_elev < 0 || sid_river < 0 ||
            sid_landform < 0) {
            return fail("stage_9 missing slot id");
        }
        Slot &s_t = slot(sid_terrain);
        Slot &s_m = slot(sid_moist);
        Slot &s_e = slot(sid_elev);
        Slot &s_r = slot(sid_river);
        Slot &s_lf= slot(sid_landform);
        if (s_t.arr_u8.size() != n_cells || s_m.arr_f32.size() != n_cells ||
            s_e.arr_f32.size() != n_cells || s_r.arr_u8.size() != n_cells ||
            s_lf.arr_u8.size() != n_cells) {
            return fail("stage_9 slot size mismatch");
        }

        uint8_t       * const __restrict TERR = s_t.arr_u8.ptrw();
        const float   * const __restrict M    = s_m.arr_f32.ptr();
        const float   * const __restrict ELEV = s_e.arr_f32.ptr();
        const uint8_t * const __restrict RIV  = s_r.arr_u8.ptr();
        uint8_t       * const __restrict LF   = s_lf.arr_u8.ptrw();
        const int32_t * const __restrict NB   = nb_arr.ptr();
        const float   * const __restrict LATT = lat_tab.ptr();
        const int32_t * const __restrict ROWI = row_idx.ptr();
        const int max_row = height - 1;
        const double inv_above_sea = 1.0 / std::max(1.0 - double(sea_level), 0.001);

        PreparedSeasonStage prepared;
        prepared.slots = {sid_terrain, sid_landform};
        prepared.compute = [=]() -> SeasonStageCounts {
            int touched = 0;
            for (int i = 0; i < n_cells; ++i) {
                const uint8_t t = TERR[i];
                if (pk_is_water_terrain(t)) continue;
                if (t == 6 || t == 9 || t == 8) continue; // MOUNTAIN/SNOW/TUNDRA
                if (pk_is_permanent_landform(t)) continue;
                const double e = double(ELEV[i]);
                const double land_h = (e - double(sea_level)) * inv_above_sea;
                if (land_h > 0.10) continue;
                if (M[i] < 0.75f) continue;
                int row = ROWI[i];
                if (row < 0) row = 0;
                else if (row > max_row) row = max_row;
                const double lat_temp = double(LATT[row]);
                const double temp = pk_clamp01(lat_temp - pk_alt_penalty(e, double(sea_level)));
                if (temp < 0.30) continue;
                bool has_water = (RIV[i] != 0);
                if (!has_water) {
                    for (int d = 0; d < 6; ++d) {
                        const int ni = NB[i * 6 + d];
                        if (ni < 0 || ni >= n_cells) continue;
                        if (pk_is_water_terrain(TERR[ni])) { has_water = true; break; }
                    }
                }
                if (!has_water) continue;
                TERR[i] = 10; // SWAMP
                LF[i] = pk_derive_landform(10, ELEV[i], sea_level);
                ++touched;
            }
            return {touched};
        };
        return prepared;
    }

    // 历史上的 stage 8 = sync_current_state（_run_season_refresh_stage8_gdext 入口）。
    if (stage != 8) return fail("unsupported stage");
    if (!knobs.has("n_cells") || !knobs.has("sea_level")) {
        return fail("missing required knob (n_cells / sea_level)");
    }

    const int n_cells = int(knobs["n_cells"]);
    const float sea_level = float(knobs["sea_level"]);
    if (n_cells <= 0) return fail("n_cells <= 0");

    const int sid_temp = component("cell_temp");
    const int sid_moist = component("cell_moisture");
    const int sid_snow = component("cell_snow_cover");
    const int sid_elev = component("cell_elevation");
    const int sid_terrain = component("cell_terrain");
    const int sid_landform = component("cell_landform");
    const int sid_vegetation = component("cell_vegetation");
    const int sid_cover = component("cell_cover");
    if (sid_temp < 0 || sid_moist < 0 || sid_snow < 0 || sid_elev < 0 ||
        sid_terrain < 0 ||
        sid_landform < 0 || sid_vegetation < 0 || sid_cover < 0) {
        return fail("missing slot id");
    }

    Slot &s_temp = slot(sid_temp);
    Slot &s_moist = slot(sid_moist);
    Slot &s_snow = slot(sid_snow);
    Slot &s_elev = slot(sid_elev);
    Slot &s_terrain = slot(sid_terrain);
    Slot &s_landform = slot(sid_landform);
    Slot &s_vegetation = slot(sid_vegetation);
    Slot &s_cover = slot(sid_cover);
    if (s_temp.arr_f32.size() != n_cells || s_moist.arr_f32.size() != n_cells ||
        s_snow.arr_f32.size() != n_cells || s_elev.arr_f32.size() != n_cells ||
        s_terrain.arr_u8.size() != n_cells || s_landform.arr_u8.size() != n_cells ||
        s_vegetation.arr_u8.size() != n_cells || s_cover.arr_u8.size() != n_cells) {
        return fail("slot array size mismatch");
    }

    const float * const __restrict MOIST = s_moist.arr_f32.ptr();
    const float * const __restrict ELEV = s_elev.arr_f32.ptr();
    const float * const __restrict TEMP = s_temp.arr_f32.ptr();
    const uint8_t * const __restrict TERR = s_terrain.arr_u8.ptr();
    float * const __restrict SNOW = s_snow.arr_f32.ptrw();
    uint8_t * const __restrict LAND = s_landform.arr_u8.ptrw();
    uint8_t * const __restrict VEG = s_vegetation.arr_u8.ptrw();
    uint8_t * const __restrict COV = s_cover.arr_u8.ptrw();

    const bool skip_vegetation_rewrite = bool(knobs.get("skip_vegetation_rewrite", false));

    PreparedSeasonStage prepared;
    prepared.slots = {sid_snow, sid_landform, sid_cover};
    if (!skip_vegetation_rewrite)
        prepared.slots.insert(prepared.slots.begin() + 2, sid_vegetation);
    prepared.compute = [=]() -> SeasonStageCounts {
        int snow_cells = 0;
        for (int i = 0; i < n_cells; ++i) {
            // 2026-07-08：海拔惩罚基于 sea_level 以上 land_h，与 GDScript / shader SAME_SOURCE。
            const double e = double(ELEV[i]);
            // Runtime temperature is owned by wind_surface. Season refresh consumes it
            // for slow-layer derivation and must never prescribe a replacement value.
            const float temp_now = std::isfinite(TEMP[i]) ? pk_clamp01(double(TEMP[i])) : 0.0f;
            float snow = 0.0f;
            if (!pk_is_water_terrain(TERR[i])) {
                const float land_h = (ELEV[i] - sea_level) / std::max(1.0f - sea_level, 0.001f);
                if (TERR[i] == 9) {
                    snow = 1.0f;
                } else if (temp_now < 0.18f) {
                    snow = float(pk_clamp01((0.18f - temp_now) / 0.14f)) * 0.95f;
                } else if (land_h > 0.35f && temp_now < 0.45f) {
                    const float t1 = float(pk_clamp01((0.45f - temp_now) / 0.25f));
                    const float x = float(pk_clamp01((land_h - 0.35f) / (0.80f - 0.35f)));
                    const float t2 = x * x * (3.0f - 2.0f * x);
                    snow = t1 * t2;
                }
            }
            uint8_t lf = pk_derive_landform(TERR[i], ELEV[i], sea_level);
            const uint8_t prev_lf = LAND[i];
            if (!pk_is_water_terrain(TERR[i]) && (prev_lf == 8 || prev_lf == 12 || prev_lf == 13 || prev_lf == 14 || prev_lf == 15)) {
                lf = prev_lf;
            }
            SNOW[i] = snow;
            LAND[i] = lf;
            // Vegetation succession/streak is owned by vegetation_dynamics. Season
            // sync only repairs water/empty cells unless skip_vegetation_rewrite.
            if (!skip_vegetation_rewrite &&
                (pk_is_water_terrain(TERR[i]) || VEG[i] == 0 ||
                pk_vegetation_needs_biome_reconcile(TERR[i], VEG[i]))) {
                VEG[i] = pk_derive_vegetation(TERR[i], lf, temp_now, MOIST[i]);
            }
            COV[i] = pk_derive_cover(TERR[i], snow);
            if (snow > 0.5f) ++snow_cells;
        }
        return {n_cells, snow_cells};
    };
    return prepared;
}


godot::Dictionary DCWorldExt::run_season_refresh_stage(godot::Dictionary knobs) {
    SimTraceWriteGuard sim_trace_guard{this, "run_season_refresh_stage"};
    Dictionary out;
    const int stage = knobs.get("stage", 8);
    out["stage"] = stage;
    out["elapsed_ms"] = -1.0;
    out["fallback"] = true;
    out["reason"] = String();

    auto fail = [&](const char *reason) -> Dictionary {
        out["reason"] = String(reason);
        UtilityFunctions::push_warning("[DCWorldExt] run_season_refresh_stage: ",
                                       reason, " - fallback to GDScript");
        return out;
    };
    if (!_bound) return fail("not bound");
    _production_season_refresh_ran = true;
    SeasonStageArrays arrays(knobs);
    const auto prepared = prepare_season_stage(
        [this](const char *name) { return component_id(StringName(name)); },
        [this](int id) -> Slot & { return _slots.write[id]; }, knobs, arrays, stage);
    if (prepared.reason != nullptr) return fail(prepared.reason);
    const auto started = std::chrono::steady_clock::now();
    const auto counts = prepared.compute();
    for (const int id : prepared.slots) _flush_slot_to_map(id);
    if (stage == 8) out["snow_cells"] = counts.snow_cells;
    if (stage == 10) {
        _production_seasonal_feedback_ran = true;
        _production_seasonal_feedback_decay = float(knobs["decay"]);
        knobs["soil_moisture_arr"] = arrays.soil;
        knobs["veg_growth_pressure_arr"] = arrays.growth_pressure;
    }
    out["elapsed_ms"] = std::chrono::duration<double, std::milli>(
        std::chrono::steady_clock::now() - started).count();
    out["fallback"] = false;
    out["touched"] = counts.touched;
    return out;
}

godot::Dictionary DCWorldExt::run_season_refresh_micro_pass(godot::Dictionary knobs) {
    using godot::Dictionary;
    using godot::PackedInt32Array;
    using godot::String;
    using godot::StringName;

    Dictionary out;
    const int stage = int(knobs.get("stage", 1));
    out["stage"] = stage;
    out["stage_name"] = String("unknown");
    out["done"] = false;
    out["next_stage"] = stage;
    out["cursor"] = int(knobs.get("cursor", 0));
    out["elapsed_ms"] = 0.0;
    out["touched"] = 0;
    out["fallback"] = true;
    out["reason"] = String();

    auto fail = [&](const char *why) -> Dictionary {
        out["reason"] = String(why);
        return out;
    };

    if (!_bound) return fail("not bound");
    if (stage != 1) return fail("unsupported stage");
    out["stage_name"] = String("rain_shadow");

    if (!knobs.has("n_cells") || !knobs.has("cursor") || !knobs.has("max_usec") ||
        !knobs.has("rain_shadow_lookback") || !knobs.has("rain_shadow_threshold") ||
        !knobs.has("rain_shadow_factor") || !knobs.has("neighbor_indices")) {
        return fail("stage_1 missing required knobs");
    }

    const int n_cells = int(knobs["n_cells"]);
    int cursor = int(knobs["cursor"]);
    const int max_usec = std::max(50, int(knobs["max_usec"]));
    const int lookback = std::max(0, int(knobs["rain_shadow_lookback"]));
    const float threshold = float(knobs["rain_shadow_threshold"]);
    const float factor = float(knobs["rain_shadow_factor"]);
    if (n_cells <= 0) return fail("n_cells <= 0");
    if (cursor < 0 || cursor > n_cells) return fail("cursor out of range");

    PackedInt32Array nb_arr = knobs["neighbor_indices"];
    if (nb_arr.size() < n_cells * 6) return fail("neighbor_indices size < n_cells * 6");

    const int sid_terrain = component_id(StringName("cell_terrain"));
    const int sid_moist   = component_id(StringName("cell_moisture"));
    const int sid_elev    = component_id(StringName("cell_elevation"));
    const int sid_wx      = component_id(StringName("cell_wind_x"));
    const int sid_wy      = component_id(StringName("cell_wind_y"));
    if (sid_terrain < 0 || sid_moist < 0 || sid_elev < 0 || sid_wx < 0 || sid_wy < 0) {
        return fail("missing slot id (terrain/moisture/elevation/wind)");
    }

    Slot &s_t = _slots.write[sid_terrain];
    Slot &s_m = _slots.write[sid_moist];
    Slot &s_e = _slots.write[sid_elev];
    Slot &s_wx = _slots.write[sid_wx];
    Slot &s_wy = _slots.write[sid_wy];
    if (s_t.arr_u8.size() != n_cells || s_m.arr_f32.size() != n_cells ||
        s_e.arr_f32.size() != n_cells || s_wx.arr_f32.size() != n_cells ||
        s_wy.arr_f32.size() != n_cells) {
        return fail("slot array size mismatch");
    }

    const uint8_t * const __restrict TERR = s_t.arr_u8.ptr();
    float         * const __restrict M    = s_m.arr_f32.ptrw();
    const float   * const __restrict ELEV = s_e.arr_f32.ptr();
    const float   * const __restrict WX   = s_wx.arr_f32.ptr();
    const float   * const __restrict WY   = s_wy.arr_f32.ptr();
    const int32_t * const __restrict NB   = nb_arr.ptr();

    auto t0 = std::chrono::high_resolution_clock::now();
    int touched = 0;
    int processed = 0;
    bool budget_yield = false;

    for (; cursor < n_cells; ++cursor) {
        if (!pk_is_water_terrain(TERR[cursor]) && lookback > 0) {
            const int dir = pk_upwind_dir_index_from_wind(WX[cursor], WY[cursor]);
            if (dir < 0) {
                continue;
            }
            int probe = cursor;
            for (int step = 0; step < lookback; ++step) {
                const int ni = NB[probe * 6 + dir];
                if (ni < 0 || ni >= n_cells) {
                    probe = -1;
                    break;
                }
                probe = ni;
            }
            if (probe >= 0 && ELEV[probe] > ELEV[cursor] + threshold) {
                M[cursor] = M[cursor] * factor;
                ++touched;
            }
        }

        ++processed;
        if ((processed & 63) == 0) {
            auto now = std::chrono::high_resolution_clock::now();
            const double elapsed_us = std::chrono::duration<double, std::micro>(now - t0).count();
            if (elapsed_us >= double(max_usec)) {
                ++cursor;
                budget_yield = true;
                break;
            }
        }
    }

    _flush_slot_to_map(sid_moist);

    auto t1 = std::chrono::high_resolution_clock::now();
    const bool done = cursor >= n_cells;
    out["done"] = done;
    out["next_stage"] = done ? stage + 1 : stage;
    out["cursor"] = cursor;
    out["elapsed_ms"] = std::chrono::duration<double, std::milli>(t1 - t0).count();
    out["touched"] = touched;
    out["fallback"] = false;
    out["reason"] = budget_yield ? String("budget_yield") : String();
    return out;
}

} // namespace pk
