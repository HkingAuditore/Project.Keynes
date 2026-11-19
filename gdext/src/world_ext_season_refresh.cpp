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
        const DCWorldExt &world, const std::function<Slot &(int)> &slot,
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

        const int sid_terrain      = world.component_id(StringName("cell_terrain"));
        const int sid_moist        = world.component_id(StringName("cell_moisture"));
        const int sid_base_m       = world.component_id(StringName("cell_base_moisture"));
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

        const int sid_terrain = world.component_id(StringName("cell_terrain"));
        const int sid_base_m  = world.component_id(StringName("cell_base_moisture"));
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
    // ─── stage 1：rain_shadow_per_cell ────────────────────────────────────
    // SAME_SOURCE: map_generator.gd::_apply_rain_shadow_per_cell (line 3149).
    // 流程：陆地 cell → wind_vector 优先 / WindBelt fallback → upwind hex dir
    // → lookback N 步 → 若上风 cell 海拔高 threshold → moisture *= factor。
    if (stage == 1) {
        if (!knobs.has("n_cells") || !knobs.has("rain_shadow_lookback") ||
            !knobs.has("rain_shadow_threshold") || !knobs.has("rain_shadow_factor") ||
            !knobs.has("neighbor_indices") || !knobs.has("season_phase") ||
            !knobs.has("jitter_arr")) {
            return fail("stage_1 missing required knob");
        }
        const int n_cells = int(knobs["n_cells"]);
        const int lookback = std::max(0, int(knobs["rain_shadow_lookback"]));
        const float threshold = float(knobs["rain_shadow_threshold"]);
        const float factor = float(knobs["rain_shadow_factor"]);
        const double season_phase = double(knobs["season_phase"]);
        if (n_cells <= 0) return fail("stage_1 n_cells <= 0");

        const int sid_terrain = world.component_id(StringName("cell_terrain"));
        const int sid_moist   = world.component_id(StringName("cell_moisture"));
        const int sid_elev    = world.component_id(StringName("cell_elevation"));
        const int sid_wx      = world.component_id(StringName("cell_wind_x"));
        const int sid_wy      = world.component_id(StringName("cell_wind_y"));
        const int sid_lat     = world.component_id(StringName("cell_lat_norm"));
        if (sid_terrain < 0 || sid_moist < 0 || sid_elev < 0 ||
            sid_wx < 0 || sid_wy < 0 || sid_lat < 0) {
            return fail("stage_1 missing slot id");
        }
        Slot &s_t = slot(sid_terrain);
        Slot &s_m = slot(sid_moist);
        Slot &s_e = slot(sid_elev);
        Slot &s_wx = slot(sid_wx);
        Slot &s_wy = slot(sid_wy);
        Slot &s_lat = slot(sid_lat);
        if (s_t.arr_u8.size() != n_cells || s_m.arr_f32.size() != n_cells ||
            s_e.arr_f32.size() != n_cells || s_wx.arr_f32.size() != n_cells ||
            s_wy.arr_f32.size() != n_cells || s_lat.arr_f32.size() != n_cells) {
            return fail("stage_1 slot size mismatch");
        }
        auto &nb_arr = arrays.neighbors;
        if (nb_arr.size() < n_cells * 6) return fail("stage_1 neighbor_indices size mismatch");
        auto &jitter_arr = arrays.jitter;
        if (jitter_arr.size() != n_cells) return fail("stage_1 jitter_arr size mismatch");

        const uint8_t * const __restrict TERR = s_t.arr_u8.ptr();
        float         * const __restrict M    = s_m.arr_f32.ptrw();
        const float   * const __restrict ELEV = s_e.arr_f32.ptr();
        const float   * const __restrict WX   = s_wx.arr_f32.ptr();
        const float   * const __restrict WY   = s_wy.arr_f32.ptr();
        const float   * const __restrict LAT  = s_lat.arr_f32.ptr();
        const int32_t * const __restrict NB   = nb_arr.ptr();
        const float   * const __restrict JITTER = jitter_arr.ptr();

        // 6 hex 方向（与 pk_upwind_dir_index_from_wind 内 DIRS 同源），
        // 用于把 wind 向量映射到 0..5 索引。
        constexpr int DIRS[6][3] = {
            { 1,  0, -1}, { 1, -1,  0}, { 0, -1,  1},
            {-1,  0,  1}, {-1,  1,  0}, { 0,  1, -1},
        };
        constexpr double inv_sqrt2 = 0.7071067811865475;

        auto pick_dir_from_wind = [=](double wx, double wy) -> int {
            const double len2 = wx * wx + wy * wy;
            if (len2 <= 0.0001) return -1;
            const double inv_len = 1.0 / std::sqrt(len2);
            const double nx = wx * inv_len;
            const double ny_ = wy * inv_len;
            const double wq = std::sqrt(3.0) / 3.0 * nx - ny_ / 3.0;
            const double wr = 2.0 / 3.0 * ny_;
            const double ws = -wq - wr;
            const double clen = std::sqrt(wq * wq + wr * wr + ws * ws);
            if (clen <= 0.0001) return -1;
            const double uq = -wq / clen;
            const double ur = -wr / clen;
            const double us = -ws / clen;
            int best = 0;
            double best_dot = -std::numeric_limits<double>::infinity();
            for (int d = 0; d < 6; ++d) {
                const double dot = uq * double(DIRS[d][0]) * inv_sqrt2
                                 + ur * double(DIRS[d][1]) * inv_sqrt2
                                 + us * double(DIRS[d][2]) * inv_sqrt2;
                if (dot > best_dot) { best_dot = dot; best = d; }
            }
            return best;
        };

        PreparedSeasonStage prepared;
        prepared.slots = {sid_moist};
        prepared.compute = [=]() -> SeasonStageCounts {
            int touched = 0;
            for (int i = 0; i < n_cells; ++i) {
                if (pk_is_water_terrain(TERR[i])) continue;
                if (lookback <= 0) continue;
                int dir;
                // 先用 cell.wind_vector（地形扰动后的实际盛行风），与 _pick_upwind_dir 一致。
                const double cell_wx = double(WX[i]);
                const double cell_wy = double(WY[i]);
                const double wv_len2 = cell_wx * cell_wx + cell_wy * cell_wy;
                if (wv_len2 > 0.0001) { // wv.length() > 0.01 等价
                    dir = pick_dir_from_wind(cell_wx, cell_wy);
                } else {
                    // Fallback：WindBelt.wind_at(ny, season_phase, lat_jitter)
                    const double ny = double(LAT[i]);
                    const double jitter = double(JITTER[i]);
                    const PkWind2 w = pk_wind_belt_wind_at(ny, season_phase, jitter);
                    dir = pick_dir_from_wind(double(w.x), double(w.y));
                }
                if (dir < 0) continue;

                int probe = i;
                for (int step = 0; step < lookback; ++step) {
                    const int ni = NB[probe * 6 + dir];
                    if (ni < 0 || ni >= n_cells) { probe = -1; break; }
                    probe = ni;
                }
                if (probe < 0) continue;
                if (ELEV[probe] > ELEV[i] + threshold) {
                    M[i] = M[i] * factor;
                    ++touched;
                }
            }
            return {touched};
        };
        return prepared;
    }

    // ─── stage 2：seasonal_redecide_terrain ───────────────────────────────
    // SAME_SOURCE: map_generator.gd::_seasonal_redecide_terrain (line 2474).
    // 流程：非永久气候 / 非永久地标 → 用 temp_365d + base_moisture/water_balance_30d
    //       算慢时间尺度 biome 气候 → _decide_terrain → apply_terrain（写 terrain + 派生 landform）。
    //       瞬时 moisture 只供实时气候；vegetation/cover 由后续慢速演替阶段维护。
    if (stage == 2) {
        if (!knobs.has("n_cells") || !knobs.has("height") || !knobs.has("sea_level") ||
            !knobs.has("lat_temp_rows") || !knobs.has("season_offset_rows") ||
            !knobs.has("row_indices")) {
            return fail("stage_2 missing required knob");
        }
        const int n_cells = int(knobs["n_cells"]);
        const int height = int(knobs["height"]);
        const float sea_level = float(knobs["sea_level"]);
        if (n_cells <= 0 || height <= 0) return fail("stage_2 invalid dims");

        auto &lat_tab = arrays.latitude;
        auto &off_tab = arrays.season_offsets;
        auto &row_idx = arrays.rows;
        if (lat_tab.size() < height || off_tab.size() < height) return fail("stage_2 row tables size");
        if (row_idx.size() != n_cells) return fail("stage_2 row_indices size");

        const int sid_terrain   = world.component_id(StringName("cell_terrain"));
        const int sid_base_t    = world.component_id(StringName("cell_base_terrain"));
        const int sid_elev      = world.component_id(StringName("cell_elevation"));
        const int sid_moist     = world.component_id(StringName("cell_moisture"));
        const int sid_base_m    = world.component_id(StringName("cell_base_moisture"));
        const int sid_wb30      = world.component_id(StringName("cell_water_balance_30d"));
        const int sid_landform  = world.component_id(StringName("cell_landform"));
        const int sid_vegetation= world.component_id(StringName("cell_vegetation"));
        const int sid_cover     = world.component_id(StringName("cell_cover"));
        const int sid_snow      = world.component_id(StringName("cell_snow_cover"));
        const int sid_is_water  = world.component_id(StringName("cell_is_water"));
        if (sid_terrain < 0 || sid_base_t < 0 || sid_elev < 0 || sid_moist < 0 ||
            sid_base_m < 0 || sid_wb30 < 0 ||
            sid_landform < 0 || sid_vegetation < 0 || sid_cover < 0 || sid_snow < 0 ||
            sid_is_water < 0) {
            return fail("stage_2 missing slot id");
        }
        Slot &s_t  = slot(sid_terrain);
        Slot &s_bt = slot(sid_base_t);
        Slot &s_e  = slot(sid_elev);
        Slot &s_m  = slot(sid_moist);
        Slot &s_bm = slot(sid_base_m);
        Slot &s_wb = slot(sid_wb30);
        Slot &s_lf = slot(sid_landform);
        Slot &s_vg = slot(sid_vegetation);
        Slot &s_cv = slot(sid_cover);
        Slot &s_sn = slot(sid_snow);
        Slot &s_iw = slot(sid_is_water);
        if (s_t.arr_u8.size() != n_cells || s_bt.arr_u8.size() != n_cells ||
            s_e.arr_f32.size() != n_cells || s_m.arr_f32.size() != n_cells ||
            s_bm.arr_f32.size() != n_cells || s_wb.arr_f32.size() != n_cells ||
            s_lf.arr_u8.size() != n_cells || s_vg.arr_u8.size() != n_cells ||
            s_cv.arr_u8.size() != n_cells || s_sn.arr_f32.size() != n_cells ||
            s_iw.arr_u8.size() != n_cells) {
            return fail("stage_2 slot size mismatch");
        }

        uint8_t       * const __restrict TERR  = s_t.arr_u8.ptrw();
        const uint8_t * const __restrict BTERR = s_bt.arr_u8.ptr();
        const float   * const __restrict ELEV  = s_e.arr_f32.ptr();
        const float   * const __restrict MOIST = s_m.arr_f32.ptr();
        const float   * const __restrict BASE_MOIST = s_bm.arr_f32.ptr();
        const float   * const __restrict WB30 = s_wb.arr_f32.ptr();
        const int sid_temp_365d = world.component_id(StringName("cell_temp_365d"));
        if (sid_temp_365d < 0 || slot(sid_temp_365d).arr_f32.size() != n_cells) {
            return fail("stage_2 temp_365d slot size mismatch");
        }
        const float * const __restrict TEMP365 = slot(sid_temp_365d).arr_f32.ptr();
        uint8_t       * const __restrict LF    = s_lf.arr_u8.ptrw();
        uint8_t       * const __restrict VG    = s_vg.arr_u8.ptrw();
        uint8_t       * const __restrict CV    = s_cv.arr_u8.ptrw();
        uint8_t       * const __restrict IW    = s_iw.arr_u8.ptrw();

        const float   * const __restrict SNOW  = s_sn.arr_f32.ptr();
        const float   * const __restrict LATT  = lat_tab.ptr();
        const float   * const __restrict OFFT  = off_tab.ptr();
        const int32_t * const __restrict ROWI  = row_idx.ptr();
        const float biome_wet_weight = std::max(0.0f, float(knobs.get("biome_water_balance_weight", 0.35)));
        const float biome_dry_penalty = std::max(0.0f, float(knobs.get("biome_drought_penalty", 0.25)));

        PreparedSeasonStage prepared;
        prepared.slots = {sid_terrain, sid_landform, sid_is_water};
        (void)MOIST;
        (void)LATT;
        (void)OFFT;
        (void)ROWI;
        prepared.compute = [=]() -> SeasonStageCounts {
            int touched = 0;
            const int max_row = height - 1;
            for (int i = 0; i < n_cells; ++i) {
                const uint8_t cur = TERR[i];
                const uint8_t bt = BTERR[i];
                if (pk_is_water_terrain(cur)) {
                    if (!pk_is_water_terrain(bt)) {
                        TERR[i] = bt;
                        LF[i] = pk_derive_landform(bt, ELEV[i], sea_level);
                        IW[i] = pk_is_water_terrain(bt) ? uint8_t(1) : uint8_t(0);
                        ++touched;

                    }
                    continue;
                }
                uint8_t new_t;

                if (bt == 9) { // SNOW base = 永久 SNOW
                    new_t = bt;
                } else if (pk_is_permanent_landform(bt)) {
                    new_t = bt;
                } else {
                    int row = ROWI[i];
                    if (row < 0) row = 0;
                    else if (row > max_row) row = max_row;
                    const double e = double(ELEV[i]);
                    const double temp_year = pk_clamp01(double(TEMP365[i]));
                    const double biome_moisture = pk_clamp01(
                        double(BASE_MOIST[i])
                        + std::max(double(WB30[i]), 0.0) * double(biome_wet_weight)
                        + std::min(double(WB30[i]), 0.0) * double(biome_dry_penalty));
                    new_t = pk_decide_terrain(e, temp_year, biome_moisture,
                                              double(sea_level));
                    // 生成期已排干/回填的内陆低洼陆地仍保留原始 below-sea elevation；
                    // runtime 季节重判不得把非水地块重新判回 COAST/OCEAN。
                    if (pk_is_water_terrain(new_t) && !pk_is_water_terrain(cur)) {
                        new_t = !pk_is_water_terrain(bt) ? bt : cur;
                    }
                }
                if (new_t != cur) ++touched;

                TERR[i] = new_t;
                IW[i] = pk_is_water_terrain(new_t) ? uint8_t(1) : uint8_t(0);
                // apply_terrain multi-axis sync（与 hex_cell.gd::apply_terrain 一致：

                // terrain 写后，三轴派生由 _sync_axes 完成。这里用 stage 8 同款 derive 路径。）
                uint8_t lf_new = pk_derive_landform(new_t, ELEV[i], sea_level);
                // 结构性地貌保留（与 stage 8 sync_current_state 同口径）：生成期通过多格邻域
                // 起伏分析写入的 PEAK(8)/VOLCANO(12)/PLATEAU(13)/RIFT_VALLEY(14)/CANYON(15)
                // 无法由单格 pk_derive_landform 复现，季节重判必须保留，否则首个 refresh round
                // 就会把高原/高峰/裂谷/峡谷整片塌缩成朴素 MOUNTAIN/HILL（见 tile_data 实测）。
                const uint8_t prev_lf = LF[i];
                if (prev_lf == 8 || prev_lf == 12 || prev_lf == 13 || prev_lf == 14 || prev_lf == 15) {
                    lf_new = prev_lf;
                }
                LF[i] = lf_new;
                // vegetation 用当前 moisture + 季节温度（由当前 runtime temp 派生；这里
                // 用 lat_tab 行温度 + off 近似；与 GDScript _seasonal_redecide_terrain
                // 路径不调用 _sync_axes_for_cell（只 apply_terrain），但下游 stage 9
                // 会 sync）。为保持 bit-equal：仅写 terrain + landform，veg/cover 留给
                // stage 9 (sync_current_state) 统一处理。
                (void)VG; (void)CV; (void)SNOW;
            }
            return {touched};
        };
        return prepared;
    }

    // ─── stage 3：river_ecology ───────────────────────────────────────────

    // SAME_SOURCE: map_generator.gd::_apply_river_ecology (line 3190).
    // 流程：has_river && 非水 → moisture=max(moist, 0.66~0.72)；
    //       河流穿越沙漠/恶地/寒漠时转为 FLOODPLAIN / OASIS / STEPPE；
    //       低地河道优先形成 FLOODPLAIN，避免大河边继续保持荒漠群系。
    if (stage == 3) {
        if (!knobs.has("n_cells") || !knobs.has("height") || !knobs.has("sea_level") ||
            !knobs.has("row_indices")) {
            return fail("stage_3 missing required knob");
        }
        const int n_cells = int(knobs["n_cells"]);
        const int height = int(knobs["height"]);
        const float sea_level = float(knobs["sea_level"]);
        if (n_cells <= 0 || height <= 1) return fail("stage_3 invalid dims");
        auto &row_idx = arrays.rows;
        if (row_idx.size() != n_cells) return fail("stage_3 row_indices size");

        const int sid_terrain  = world.component_id(StringName("cell_terrain"));
        const int sid_moist    = world.component_id(StringName("cell_moisture"));
        const int sid_elev     = world.component_id(StringName("cell_elevation"));
        const int sid_river    = world.component_id(StringName("cell_has_river"));
        const int sid_rflow    = world.component_id(StringName("cell_river_flow"));
        const int sid_landform = world.component_id(StringName("cell_landform"));
        if (sid_terrain < 0 || sid_moist < 0 || sid_elev < 0 || sid_river < 0 || sid_rflow < 0 ||
            sid_landform < 0) {
            return fail("stage_3 missing slot id");
        }
        Slot &s_t = slot(sid_terrain);
        Slot &s_m = slot(sid_moist);
        Slot &s_e = slot(sid_elev);
        Slot &s_r = slot(sid_river);
        Slot &s_rf= slot(sid_rflow);
        Slot &s_lf= slot(sid_landform);
        if (s_t.arr_u8.size() != n_cells || s_m.arr_f32.size() != n_cells ||
            s_e.arr_f32.size() != n_cells || s_r.arr_u8.size() != n_cells ||
            s_rf.arr_f32.size() != n_cells ||
            s_lf.arr_u8.size() != n_cells) {
            return fail("stage_3 slot size mismatch");
        }

        uint8_t       * const __restrict TERR = s_t.arr_u8.ptrw();
        float         * const __restrict M    = s_m.arr_f32.ptrw();
        const float   * const __restrict ELEV = s_e.arr_f32.ptr();
        const uint8_t * const __restrict RIV  = s_r.arr_u8.ptr();
        const float   * const __restrict RFLOW= s_rf.arr_f32.ptr();
        uint8_t       * const __restrict LF   = s_lf.arr_u8.ptrw();
        const int32_t * const __restrict ROWI = row_idx.ptr();
        const int max_row = height - 1;
        const double inv_max_row = 1.0 / double(max_row > 0 ? max_row : 1);

        PreparedSeasonStage prepared;
        prepared.slots = {sid_terrain, sid_moist, sid_landform};
        prepared.compute = [=]() -> SeasonStageCounts {
            int touched = 0;
            for (int i = 0; i < n_cells; ++i) {
                if (RIV[i] == 0) continue;
                const uint8_t t = TERR[i];
                if (pk_is_water_terrain(t)) continue;
                int row = ROWI[i];
                if (row < 0) row = 0;
                else if (row > max_row) row = max_row;
                const double ny = double(row) * inv_max_row;
                const double temp = double(pk_compute_temperature(ny, double(ELEV[i]), double(sea_level)));
                const double inv_above_sea = 1.0 / std::max(1.0 - double(sea_level), 0.001);
                const double lh = (double(ELEV[i]) - double(sea_level)) * inv_above_sea;
                const bool strong_river = RFLOW[i] >= 0.55f;
                const bool lowland_river = lh <= 0.18 || (strong_river && lh <= 0.28);
                const float target_m = strong_river ? 0.72f : 0.66f;
                if (M[i] < target_m) { M[i] = target_m; ++touched; }
                if (t == 22 || t == 23 || t == 29) continue;

                uint8_t new_t = t;
                if (t == 7 || t == 24 || t == 25 || t == 26 || t == 30) {
                    if (lowland_river) new_t = 29;        // FLOODPLAIN
                    else if (strong_river && temp > 0.35) new_t = 23; // OASIS
                    else if (temp > 0.30) new_t = 14;     // STEPPE riparian buffer
                } else if (!pk_is_permanent_landform(t)) {
                    if (lowland_river && (t == 2 || t == 3 || t == 12 || t == 14 || t == 15)) {
                        new_t = 29; // FLOODPLAIN
                    } else if (t == 2) {
                        if (temp > 0.55) new_t = strong_river ? uint8_t(11) : uint8_t(4);
                        else if (temp > 0.30) new_t = strong_river ? uint8_t(29) : uint8_t(3);
                    }
                }
                if (new_t != t) {
                    TERR[i] = new_t;
                    LF[i] = pk_derive_landform_preserve(new_t, ELEV[i], sea_level, LF[i]);
                    ++touched;
                }
            }
            return {touched};
        };
        return prepared;
    }

    // ─── stage 4：vegetation_feedback ─────────────────────────────────────
    // SAME_SOURCE: map_generator.gd::_apply_vegetation_feedback (line 3269).
    // 流程：1) 累加 donor 邻居 delta（陆地，elev_factor=clamp(1-elev*decay,0.1,1)）
    //       2) 应用 delta 到瞬时 moisture（限幅，供实时气候/vegetation）
    //       3) 重决策非永久 biome（不动 MOUNTAIN/SNOW/permanent_landform），
    //          仍使用 temp_365d + base_moisture/water_balance_30d，避免 donor 短期写入抖动 biome。
    if (stage == 4) {
        if (!knobs.has("n_cells") || !knobs.has("height") || !knobs.has("sea_level") ||
            !knobs.has("lat_temp_rows") || !knobs.has("row_indices") ||
            !knobs.has("neighbor_indices") || !knobs.has("donor_table") ||
            !knobs.has("elev_decay")) {
            return fail("stage_4 missing required knob");
        }
        const int n_cells = int(knobs["n_cells"]);
        const int height = int(knobs["height"]);
        const float sea_level = float(knobs["sea_level"]);
        const double elev_decay = double(knobs["elev_decay"]);
        if (n_cells <= 0 || height <= 0) return fail("stage_4 invalid dims");

        auto &lat_tab = arrays.latitude;
        auto &row_idx = arrays.rows;
        auto &nb_arr = arrays.neighbors;
        // donor_table[26]：每种 terrain 的 donor 强度（陆地非 donor=0）。
        auto &donor_tab = arrays.donors;
        if (lat_tab.size() < height) return fail("stage_4 lat_temp_rows size");
        if (row_idx.size() != n_cells) return fail("stage_4 row_indices size");
        if (nb_arr.size() < n_cells * 6) return fail("stage_4 neighbor_indices size");
        if (donor_tab.size() < 26) return fail("stage_4 donor_table size < 26");

        const int sid_terrain  = world.component_id(StringName("cell_terrain"));
        const int sid_moist    = world.component_id(StringName("cell_moisture"));
        const int sid_base_m   = world.component_id(StringName("cell_base_moisture"));
        const int sid_wb30     = world.component_id(StringName("cell_water_balance_30d"));
        const int sid_temp365  = world.component_id(StringName("cell_temp_365d"));
        const int sid_elev     = world.component_id(StringName("cell_elevation"));
        const int sid_landform = world.component_id(StringName("cell_landform"));
        if (sid_terrain < 0 || sid_moist < 0 || sid_base_m < 0 || sid_wb30 < 0 ||
            sid_temp365 < 0 || sid_elev < 0 || sid_landform < 0) {
            return fail("stage_4 missing slot id");
        }
        Slot &s_t = slot(sid_terrain);
        Slot &s_m = slot(sid_moist);
        Slot &s_bm = slot(sid_base_m);
        Slot &s_wb = slot(sid_wb30);
        Slot &s_t365 = slot(sid_temp365);
        Slot &s_e = slot(sid_elev);
        Slot &s_lf= slot(sid_landform);
        if (s_t.arr_u8.size() != n_cells || s_m.arr_f32.size() != n_cells ||
            s_bm.arr_f32.size() != n_cells || s_wb.arr_f32.size() != n_cells ||
            s_t365.arr_f32.size() != n_cells ||
            s_e.arr_f32.size() != n_cells || s_lf.arr_u8.size() != n_cells) {
            return fail("stage_4 slot size mismatch");
        }

        uint8_t       * const __restrict TERR = s_t.arr_u8.ptrw();
        float         * const __restrict M    = s_m.arr_f32.ptrw();
        const float   * const __restrict BASE_MOIST = s_bm.arr_f32.ptr();
        const float   * const __restrict WB30 = s_wb.arr_f32.ptr();
        const float   * const __restrict TEMP365 = s_t365.arr_f32.ptr();
        const float   * const __restrict ELEV = s_e.arr_f32.ptr();
        uint8_t       * const __restrict LF   = s_lf.arr_u8.ptrw();
        const int32_t * const __restrict NB   = nb_arr.ptr();
        const float   * const __restrict DTAB = donor_tab.ptr();
        const float biome_wet_weight = std::max(0.0f, float(knobs.get("biome_water_balance_weight", 0.35)));
        const float biome_dry_penalty = std::max(0.0f, float(knobs.get("biome_drought_penalty", 0.25)));

        PreparedSeasonStage prepared;
        prepared.slots = {sid_terrain, sid_moist, sid_landform};
        prepared.compute = [=]() -> SeasonStageCounts {
            // pass 1：累加 delta（per-target sum）
            std::vector<float> deltas(size_t(n_cells), 0.0f);
            for (int i = 0; i < n_cells; ++i) {
                const uint8_t t = TERR[i];
                const float donor = (t < 26) ? DTAB[t] : 0.0f;
                if (donor == 0.0f) continue;
                double elev_factor = 1.0 - double(ELEV[i]) * elev_decay;
                if (elev_factor < 0.1) elev_factor = 0.1;
                else if (elev_factor > 1.0) elev_factor = 1.0;
                const float donor_eff = float(double(donor) * elev_factor);
                for (int d = 0; d < 6; ++d) {
                    const int ni = NB[i * 6 + d];
                    if (ni < 0 || ni >= n_cells) continue;
                    if (pk_is_water_terrain(TERR[ni])) continue;
                    deltas[size_t(ni)] += donor_eff;
                }
            }
            // pass 2：应用 delta（陆地 only，限幅）
            for (int i = 0; i < n_cells; ++i) {
                if (pk_is_water_terrain(TERR[i])) continue;
                const float d = deltas[size_t(i)];
                if (d == 0.0f) continue;
                double m = double(M[i]) + double(d);
                if (m < 0.0) m = 0.0;
                else if (m > 1.0) m = 1.0;
                M[i] = float(m);
            }
            // pass 3：redecide（慢气候输入；不动 MOUNTAIN/SNOW/permanent_landform）
            int touched = 0;
            for (int i = 0; i < n_cells; ++i) {
                const uint8_t cur = TERR[i];
                if (pk_is_water_terrain(cur)) continue;
                if (cur == 6 || cur == 9) continue;            // MOUNTAIN/SNOW
                if (pk_is_permanent_landform(cur)) continue;
                const double e = double(ELEV[i]);
                const double temp = pk_clamp01(double(TEMP365[i]));
                const double biome_moisture = pk_clamp01(
                    double(BASE_MOIST[i])
                    + std::max(double(WB30[i]), 0.0) * double(biome_wet_weight)
                    + std::min(double(WB30[i]), 0.0) * double(biome_dry_penalty));
                uint8_t new_t = pk_decide_terrain(e, temp, biome_moisture,
                                                  double(sea_level));
                if (pk_is_water_terrain(new_t) && !pk_is_water_terrain(cur)) {
                    new_t = cur;
                }
                if (new_t != cur) {
                    TERR[i] = new_t;

                    LF[i] = pk_derive_landform_preserve(new_t, ELEV[i], sea_level, LF[i]);
                    ++touched;
                }
            }
            return {touched};
        };
        return prepared;
    }

    // ─── stage 5：shrubland_pass ──────────────────────────────────────────
    // SAME_SOURCE: map_generator.gd::_apply_shrubland_pass (line 3374).
    // 触发：陆地 + (GRASSLAND/STEPPE/SAVANNA/PLAIN) + !permanent_landform
    //   + land_h<=0.30 + temp>=0.50 + moisture∈[0.25, 0.40]
    //   + 至少 1 个 OCEAN/COAST 邻居 → SHRUBLAND(15)
    if (stage == 5) {
        if (!knobs.has("n_cells") || !knobs.has("height") || !knobs.has("sea_level") ||
            !knobs.has("row_indices") || !knobs.has("neighbor_indices")) {
            return fail("stage_5 missing required knob");
        }
        const int n_cells = int(knobs["n_cells"]);
        const int height = int(knobs["height"]);
        const float sea_level = float(knobs["sea_level"]);
        if (n_cells <= 0 || height <= 1) return fail("stage_5 invalid dims");
        auto &row_idx = arrays.rows;
        auto &nb_arr = arrays.neighbors;
        if (row_idx.size() != n_cells) return fail("stage_5 row_indices size");
        if (nb_arr.size() < n_cells * 6) return fail("stage_5 neighbor_indices size");

        const int sid_terrain  = world.component_id(StringName("cell_terrain"));
        const int sid_moist    = world.component_id(StringName("cell_moisture"));
        const int sid_elev     = world.component_id(StringName("cell_elevation"));
        const int sid_landform = world.component_id(StringName("cell_landform"));
        if (sid_terrain < 0 || sid_moist < 0 || sid_elev < 0 || sid_landform < 0) {
            return fail("stage_5 missing slot id");
        }
        Slot &s_t = slot(sid_terrain);
        Slot &s_m = slot(sid_moist);
        Slot &s_e = slot(sid_elev);
        Slot &s_lf= slot(sid_landform);
        if (s_t.arr_u8.size() != n_cells || s_m.arr_f32.size() != n_cells ||
            s_e.arr_f32.size() != n_cells || s_lf.arr_u8.size() != n_cells) {
            return fail("stage_5 slot size mismatch");
        }

        uint8_t       * const __restrict TERR = s_t.arr_u8.ptrw();
        const float   * const __restrict M    = s_m.arr_f32.ptr();
        const float   * const __restrict ELEV = s_e.arr_f32.ptr();
        uint8_t       * const __restrict LF   = s_lf.arr_u8.ptrw();
        const int32_t * const __restrict NB   = nb_arr.ptr();
        const int32_t * const __restrict ROWI = row_idx.ptr();
        const int max_row = height - 1;
        const double inv_max_row = 1.0 / double(max_row > 0 ? max_row : 1);
        const double inv_above_sea = 1.0 / std::max(1.0 - double(sea_level), 0.001);

        PreparedSeasonStage prepared;
        prepared.slots = {sid_terrain, sid_landform};
        prepared.compute = [=]() -> SeasonStageCounts {
            int touched = 0;
            for (int i = 0; i < n_cells; ++i) {
                const uint8_t t = TERR[i];
                if (pk_is_water_terrain(t)) continue;
                // 仅替换 GRASSLAND(3) / STEPPE(14) / SAVANNA(12) / PLAIN(2)
                if (t != 3 && t != 14 && t != 12 && t != 2) continue;
                if (pk_is_permanent_landform(t)) continue;
                const double e = double(ELEV[i]);
                const double land_h = (e - double(sea_level)) * inv_above_sea;
                if (land_h > 0.45) continue;
                int row = ROWI[i];
                if (row < 0) row = 0;
                else if (row > max_row) row = max_row;
                const double ny = double(row) * inv_max_row;
                const double temp = double(pk_compute_temperature(ny, e, double(sea_level)));
                // [climate-zone-fix P1] 与生成期 shrubland pass 同步：限真·暖温带地中海生态位
                // （temp 上限 0.58 排除热带/亚热带；湿度上沿收窄至 0.44）。
                if (temp < 0.42 || temp > 0.58) continue;
                const float mv = M[i];
                if (mv < 0.20f || mv > 0.44f) continue;
                bool has_sea = false;
                for (int d = 0; d < 6; ++d) {
                    const int ni = NB[i * 6 + d];
                    if (ni < 0 || ni >= n_cells) continue;
                    const uint8_t nt = TERR[ni];
                    if (nt == 0 || nt == 1) { has_sea = true; break; }
                }
                if (!has_sea) continue;
                TERR[i] = 15; // SHRUBLAND
                LF[i] = pk_derive_landform_preserve(15, ELEV[i], sea_level, LF[i]);
                ++touched;
            }
            return {touched};
        };
        return prepared;
    }

    // ─── stage 6：mangrove_pass ───────────────────────────────────────────
    // SAME_SOURCE: map_generator.gd::_apply_mangrove_pass (line 3413).
    // 触发：陆地 + !MOUNTAIN/SNOW/TUNDRA/SWAMP + !permanent_landform
    //   + land_h<=0.05 + temp>=0.65 + 紧邻 COAST + (has_river 或 SWAMP 邻接)
    //   → MANGROVE(16)
    if (stage == 6) {
        if (!knobs.has("n_cells") || !knobs.has("height") || !knobs.has("sea_level") ||
            !knobs.has("row_indices") || !knobs.has("neighbor_indices")) {
            return fail("stage_6 missing required knob");
        }
        const int n_cells = int(knobs["n_cells"]);
        const int height = int(knobs["height"]);
        const float sea_level = float(knobs["sea_level"]);
        if (n_cells <= 0 || height <= 1) return fail("stage_6 invalid dims");
        auto &row_idx = arrays.rows;
        auto &nb_arr = arrays.neighbors;
        if (row_idx.size() != n_cells) return fail("stage_6 row_indices size");
        if (nb_arr.size() < n_cells * 6) return fail("stage_6 neighbor_indices size");

        const int sid_terrain  = world.component_id(StringName("cell_terrain"));
        const int sid_elev     = world.component_id(StringName("cell_elevation"));
        const int sid_moist    = world.component_id(StringName("cell_moisture"));
        const int sid_river    = world.component_id(StringName("cell_has_river"));
        const int sid_landform = world.component_id(StringName("cell_landform"));
        if (sid_terrain < 0 || sid_elev < 0 || sid_moist < 0 || sid_river < 0 || sid_landform < 0) {
            return fail("stage_6 missing slot id");
        }
        Slot &s_t = slot(sid_terrain);
        Slot &s_e = slot(sid_elev);
        Slot &s_m = slot(sid_moist);
        Slot &s_r = slot(sid_river);
        Slot &s_lf= slot(sid_landform);
        if (s_t.arr_u8.size() != n_cells || s_e.arr_f32.size() != n_cells ||
            s_m.arr_f32.size() != n_cells || s_r.arr_u8.size() != n_cells ||
            s_lf.arr_u8.size() != n_cells) {
            return fail("stage_6 slot size mismatch");
        }

        uint8_t       * const __restrict TERR = s_t.arr_u8.ptrw();
        const float   * const __restrict ELEV = s_e.arr_f32.ptr();
        const float   * const __restrict M    = s_m.arr_f32.ptr();
        const uint8_t * const __restrict RIV  = s_r.arr_u8.ptr();
        uint8_t       * const __restrict LF   = s_lf.arr_u8.ptrw();
        const int32_t * const __restrict NB   = nb_arr.ptr();
        const int32_t * const __restrict ROWI = row_idx.ptr();
        const int max_row = height - 1;
        const double inv_max_row = 1.0 / double(max_row > 0 ? max_row : 1);
        const double inv_above_sea = 1.0 / std::max(1.0 - double(sea_level), 0.001);

        PreparedSeasonStage prepared;
        prepared.slots = {sid_terrain, sid_landform};
        prepared.compute = [=]() -> SeasonStageCounts {
            int touched = 0;
            for (int i = 0; i < n_cells; ++i) {
                const uint8_t t = TERR[i];
                if (pk_is_water_terrain(t)) continue;
                if (t == 6 || t == 9 || t == 8 || t == 10) continue; // MOUNTAIN/SNOW/TUNDRA/SWAMP
                if (pk_is_permanent_landform(t)) continue;
                const double e = double(ELEV[i]);
                const double land_h = (e - double(sea_level)) * inv_above_sea;
                if (land_h > 0.08) continue;
                int row = ROWI[i];
                if (row < 0) row = 0;
                else if (row > max_row) row = max_row;
                const double ny = double(row) * inv_max_row;
                const double temp = double(pk_compute_temperature(ny, e, double(sea_level)));
                if (temp < 0.60) continue;
                bool coast_nb = false;
                bool swamp_nb = false;
                for (int d = 0; d < 6; ++d) {
                    const int ni = NB[i * 6 + d];
                    if (ni < 0 || ni >= n_cells) continue;
                    const uint8_t nt = TERR[ni];
                    if (nt == 1) coast_nb = true;
                    else if (nt == 10) swamp_nb = true;
                }
                if (!coast_nb) continue;
                if (!(RIV[i] || swamp_nb || M[i] >= 0.70f)) continue;
                TERR[i] = 16; // MANGROVE
                LF[i] = pk_derive_landform_preserve(16, ELEV[i], sea_level, LF[i]);
                ++touched;
            }
            return {touched};
        };
        return prepared;
    }

    // ─── stage 7：glacier_pass ────────────────────────────────────────────
    // SAME_SOURCE: map_generator.gd::_apply_glacier_pass (line 3699).
    // 触发：(SNOW/TUNDRA) + temp<0.05 + (沿海冰舌 land_h<0.20 && OCEAN/COAST/SEA_ICE 邻居
    //                                  || alpine land_h>0.65)
    //       → GLACIER(17)
    if (stage == 7) {
        if (!knobs.has("n_cells") || !knobs.has("height") || !knobs.has("sea_level") ||
            !knobs.has("row_indices") || !knobs.has("neighbor_indices")) {
            return fail("stage_7 missing required knob");
        }
        const int n_cells = int(knobs["n_cells"]);
        const int height = int(knobs["height"]);
        const float sea_level = float(knobs["sea_level"]);
        if (n_cells <= 0 || height <= 1) return fail("stage_7 invalid dims");
        auto &row_idx = arrays.rows;
        auto &nb_arr = arrays.neighbors;
        if (row_idx.size() != n_cells) return fail("stage_7 row_indices size");
        if (nb_arr.size() < n_cells * 6) return fail("stage_7 neighbor_indices size");

        const int sid_terrain  = world.component_id(StringName("cell_terrain"));
        const int sid_elev     = world.component_id(StringName("cell_elevation"));
        const int sid_landform = world.component_id(StringName("cell_landform"));
        if (sid_terrain < 0 || sid_elev < 0 || sid_landform < 0) {
            return fail("stage_7 missing slot id");
        }
        Slot &s_t = slot(sid_terrain);
        Slot &s_e = slot(sid_elev);
        Slot &s_lf= slot(sid_landform);
        if (s_t.arr_u8.size() != n_cells || s_e.arr_f32.size() != n_cells ||
            s_lf.arr_u8.size() != n_cells) {
            return fail("stage_7 slot size mismatch");
        }

        uint8_t       * const __restrict TERR = s_t.arr_u8.ptrw();
        const float   * const __restrict ELEV = s_e.arr_f32.ptr();
        uint8_t       * const __restrict LF   = s_lf.arr_u8.ptrw();
        const int32_t * const __restrict NB   = nb_arr.ptr();
        const int32_t * const __restrict ROWI = row_idx.ptr();
        const int max_row = height - 1;
        const double inv_max_row = 1.0 / double(max_row > 0 ? max_row : 1);
        const double inv_above_sea = 1.0 / std::max(1.0 - double(sea_level), 0.001);

        PreparedSeasonStage prepared;
        prepared.slots = {sid_terrain, sid_landform};
        prepared.compute = [=]() -> SeasonStageCounts {
            int touched = 0;
            for (int i = 0; i < n_cells; ++i) {
                const uint8_t t = TERR[i];
                if (pk_is_water_terrain(t)) continue;
                if (t != 9 && t != 8) continue; // 仅 SNOW / TUNDRA
                const double e = double(ELEV[i]);
                const double land_h = (e - double(sea_level)) * inv_above_sea;
                int row = ROWI[i];
                if (row < 0) row = 0;
                else if (row > max_row) row = max_row;
                const double ny = double(row) * inv_max_row;
                const double temp = double(pk_compute_temperature(ny, e, double(sea_level)));
                if (temp >= 0.05) continue;
                bool coastal_glacier = false;
                if (land_h < 0.20) {
                    for (int d = 0; d < 6; ++d) {
                        const int ni = NB[i * 6 + d];
                        if (ni < 0 || ni >= n_cells) continue;
                        const uint8_t nt = TERR[ni];
                        if (nt == 0 || nt == 1 || nt == 20) {
                            coastal_glacier = true;
                            break;
                        }
                    }
                }
                const bool alpine_glacier = land_h > 0.65;
                if (!(coastal_glacier || alpine_glacier)) continue;
                TERR[i] = 17; // GLACIER
                LF[i] = pk_derive_landform_preserve(17, ELEV[i], sea_level, LF[i]);
                ++touched;
            }
            return {touched};
        };
        return prepared;
    }

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

        const int sid_terrain  = world.component_id(StringName("cell_terrain"));
        const int sid_moist    = world.component_id(StringName("cell_moisture"));
        const int sid_elev     = world.component_id(StringName("cell_elevation"));
        const int sid_river    = world.component_id(StringName("cell_has_river"));
        const int sid_landform = world.component_id(StringName("cell_landform"));
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

    const int sid_temp = world.component_id(StringName("cell_temp"));
    const int sid_moist = world.component_id(StringName("cell_moisture"));
    const int sid_snow = world.component_id(StringName("cell_snow_cover"));
    const int sid_elev = world.component_id(StringName("cell_elevation"));
    const int sid_terrain = world.component_id(StringName("cell_terrain"));
    const int sid_landform = world.component_id(StringName("cell_landform"));
    const int sid_vegetation = world.component_id(StringName("cell_vegetation"));
    const int sid_cover = world.component_id(StringName("cell_cover"));
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
        *this, [this](int id) -> Slot & { return _slots.write[id]; }, knobs, arrays, stage);
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
