#include "world_ext.h"

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


Dictionary DCWorldExt::run_native_world_generate_pass(int seed,
                                                      const Dictionary &cfg,
                                                      const Dictionary &profile) {
    Dictionary out = _run_native_generation_publish_pass(seed, cfg, profile, Dictionary());
    _native_generation_active = false;
    _native_generation_seed = seed;
    _native_generation_cfg = cfg.duplicate(true);
    _native_generation_profile = profile.duplicate(true);
    _native_generation_report = out.duplicate(true);
    return out;
}

// dots-total-cpp step4（2026-06-25）：base + post_base 融合单次驱动。
// base 的 10×n_cells SoA bundle 在 C++ 进程内直接喂给 post_base，不出语言边界。
Dictionary DCWorldExt::run_native_world_generate_full_pass(int seed,
                                                           const Dictionary &cfg,
                                                           const Dictionary &profile) {
    using godot::String;
    Dictionary base_res = run_native_world_generate_base_pass(seed, cfg, profile);
    if (int(base_res.get("rc", -1)) != 0 || bool(base_res.get("fallback", true))) {
        // base 失败：透传 base 结果（含 rc/fallback_reason），由 GDScript 中止。
        return base_res;
    }
    Dictionary post_res = run_native_world_generate_post_base_pass(seed, cfg, profile, base_res);
    // 合并 base 诊断键（GDScript 打印 base path 用），不覆盖 post_base 已有键。
    if (!post_res.has("native_algorithm") && base_res.has("native_algorithm")) {
        post_res["native_algorithm"] = base_res.get("native_algorithm", String("unknown"));
    }
    post_res["base_water_count"] = base_res.get("water_count", 0);
    post_res["base_land_count"] = base_res.get("land_count", 0);
    post_res["base_native_ms"] = base_res.get("native_ms", base_res.get("elapsed_ms", 0.0));
    post_res["base_n_cells"] = base_res.get("n_cells", 0);
    // [zonal-envelope 2026-08-01] 透传 base 期纬带湿度统计，供 headless 回归/审计断言。
    {
        static const char *kZonalKeys[] = {
            "zonal_moist_mean_eq", "zonal_moist_mean_subtrop",
            "zonal_moist_mean_midlat", "zonal_moist_mean_polar",
            "zonal_moist_min_subtrop",
            "zonal_land_cells_eq", "zonal_land_cells_subtrop",
            "zonal_land_cells_midlat", "zonal_land_cells_polar",
            "ridge_budget_scale", "ridge_base_scale", "ridge_tail_cells",
            "ridge_land_cells", "ridge_elevation_cap",
        };
        for (const char *key : kZonalKeys) {
            if (base_res.has(key) && !post_res.has(key)) {
                post_res[key] = base_res.get(key, Variant());
            }
        }
    }
    post_res["fused_base_post"] = true;
    return post_res;
}

Dictionary DCWorldExt::run_research_signal_generation_pass(const Dictionary &knobs) {
    using godot::PackedByteArray;
    using godot::PackedFloat32Array;
    using godot::PackedInt32Array;
    Dictionary out;
    out["ok"] = false;
    const String mode = knobs.get("mode", String("static"));
    if (mode == String("resources")) {
        const int n = int(knobs.get("cell_count", 0));
        const PackedInt32Array old_offsets = knobs.get(
            "cell_signal_offsets", PackedInt32Array());
        const PackedInt32Array old_ids = knobs.get(
            "cell_signal_ids", PackedInt32Array());
        const PackedInt32Array old_values = knobs.get(
            "cell_signal_values", PackedInt32Array());
        const PackedInt32Array resource_signal_ids = knobs.get(
            "resource_signal_ids", PackedInt32Array());
        const Array reserve_columns = knobs.get("resource_reserves", Array());
        if (n <= 0 || old_offsets.size() != n + 1 || old_ids.size() != old_values.size() ||
            old_offsets[0] != 0 || old_offsets[n] != old_ids.size() ||
            resource_signal_ids.is_empty() ||
            reserve_columns.size() != resource_signal_ids.size()) {
            out["reason"] = String("research_resource_signal_input_shape_invalid");
            return out;
        }
        std::vector<PackedFloat32Array> reserves;
        reserves.reserve(size_t(reserve_columns.size()));
        for (int resource = 0; resource < reserve_columns.size(); ++resource) {
            const PackedFloat32Array column = reserve_columns[resource];
            if (column.size() != n) {
                out["reason"] = String("research_resource_signal_reserve_shape_invalid");
                return out;
            }
            reserves.push_back(column);
        }
        PackedInt32Array offsets;
        PackedInt32Array ids;
        PackedInt32Array values;
        offsets.resize(n + 1);
        int32_t *offset = offsets.ptrw();
        std::vector<std::pair<int32_t, int32_t>> scratch;
        scratch.reserve(size_t(resource_signal_ids.size()) + 16U);
        int32_t cursor = 0;
        for (int cell = 0; cell < n; ++cell) {
            offset[cell] = cursor;
            scratch.clear();
            const int32_t begin = old_offsets[cell];
            const int32_t end = old_offsets[cell + 1];
            if (begin < 0 || end < begin || end > old_ids.size()) {
                out["reason"] = String("research_resource_signal_csr_invalid");
                return out;
            }
            for (int32_t edge = begin; edge < end; ++edge)
                scratch.emplace_back(old_ids[edge], old_values[edge]);
            for (int resource = 0; resource < resource_signal_ids.size(); ++resource) {
                if (reserves[size_t(resource)][cell] > 0.0001f)
                    scratch.emplace_back(resource_signal_ids[resource], 1);
            }
            std::sort(scratch.begin(), scratch.end(),
                      [](const auto &a, const auto &b) { return a.first < b.first; });
            for (const auto &entry : scratch) {
                if (entry.first < 0) continue;
                if (!ids.is_empty() && cursor > offset[cell] && ids[cursor - 1] == entry.first) {
                    values.set(cursor - 1, std::max(values[cursor - 1], entry.second));
                    continue;
                }
                ids.push_back(entry.first);
                values.push_back(entry.second);
                ++cursor;
            }
        }
        offset[n] = cursor;
        out["ok"] = true;
        out["path"] = String("gdext_resource_merge");
        out["cell_signal_offsets"] = offsets;
        out["cell_signal_ids"] = ids;
        out["cell_signal_values"] = values;
        return out;
    }
    const int width = int(knobs.get("width", 0));
    const int height = int(knobs.get("height", 0));
    const int seed = int(knobs.get("seed", 0));
    const int64_t n64 = int64_t(width) * int64_t(height);
    if (width <= 0 || height <= 0 || n64 <= 0 || n64 > 1000000) {
        out["reason"] = String("research_signal_generation_dimensions_invalid");
        return out;
    }
    const int n = int(n64);
    (void)seed;
    const PackedByteArray vegetation = knobs.get("generation_vegetation", PackedByteArray());
    const PackedByteArray landform = knobs.get("landform", PackedByteArray());
    const PackedByteArray rivers = knobs.get("has_river", PackedByteArray());
    const PackedByteArray volcanoes = knobs.get("has_volcano", PackedByteArray());
    const PackedByteArray water = knobs.get("is_water", PackedByteArray());
    const PackedFloat32Array temperature = knobs.get("temperature", PackedFloat32Array());
    const PackedFloat32Array moisture = knobs.get("moisture", PackedFloat32Array());
    const PackedFloat32Array elevation = knobs.get("elevation", PackedFloat32Array());
    const PackedInt32Array signal_ids = knobs.get("signal_ids", PackedInt32Array());
    if (vegetation.size() != n || landform.size() != n || rivers.size() != n ||
        volcanoes.size() != n || water.size() != n || temperature.size() != n ||
        moisture.size() != n || elevation.size() != n || signal_ids.size() != 21) {
        out["reason"] = String("research_signal_generation_input_shape_invalid");
        return out;
    }
    // Landform-only CSR. Bio occupancy is seeded after resource bootstrap.
    const uint8_t *veg = vegetation.ptr();
    const uint8_t *lf = landform.ptr();
    const uint8_t *riv = rivers.ptr();
    const uint8_t *volc = volcanoes.ptr();
    const uint8_t *is_water = water.ptr();
    const float *temp = temperature.ptr();
    const float *moist = moisture.ptr();
    const float *elev = elevation.ptr();
    const int32_t *sid = signal_ids.ptr();
    PackedByteArray realms;
    realms.resize(n);
    uint8_t *realm = realms.ptrw();
    std::memset(realm, 0, size_t(n));
    PackedInt32Array offsets;
    offsets.resize(n + 1);
    int32_t *offset = offsets.ptrw();
    PackedInt32Array ids;
    PackedInt32Array values;
    ids.resize(0); values.resize(0);
    std::vector<int32_t> scratch;
    scratch.reserve(24);
    auto has_water_neighbor = [&](int cell) {
        const int row = cell / width;
        const int col = cell - row * width;
        const int left = row * width + ((col + width - 1) % width);
        const int right = row * width + ((col + 1) % width);
        const int up = row > 0 ? cell - width : -1;
        const int down = row + 1 < height ? cell + width : -1;
        return is_water[left] || is_water[right] || (up >= 0 && is_water[up]) ||
               (down >= 0 && is_water[down]);
    };
    int32_t cursor = 0;
    for (int cell = 0; cell < n; ++cell) {
        offset[cell] = cursor;
        scratch.clear();
        if (is_water[cell] == 0) {
            const bool grass = veg[cell] == 4 || veg[cell] == 9 || veg[cell] == 10 ||
                               veg[cell] == 13;
            const bool forest = veg[cell] == 5 || veg[cell] == 7 || veg[cell] == 8 ||
                                veg[cell] == 12 || veg[cell] == 14 || veg[cell] == 15 ||
                                veg[cell] == 24 || veg[cell] == 25;
            const bool wetland = veg[cell] == 19 || veg[cell] == 20 ||
                                 veg[cell] == 21 || veg[cell] == 27 || lf[cell] == 9;
            const bool arid = veg[cell] == 16 || veg[cell] == 17 ||
                              lf[cell] == 10 || lf[cell] == 11;
            const bool coast = has_water_neighbor(cell);
            const bool cold = temp[cell] <= 0.34f;
            const bool warm = temp[cell] >= 0.62f;
            const bool moist_land = moist[cell] >= 0.58f;
            const bool dry_land = moist[cell] <= 0.38f;
            const bool highland = elev[cell] >= 0.62f ||
                                  lf[cell] == 7 || lf[cell] == 8 || lf[cell] == 13;
            if (riv[cell] != 0 || wetland) scratch.push_back(sid[0]);
            if (riv[cell] != 0) scratch.push_back(sid[1]);
            if (volc[cell] != 0 || lf[cell] == 12) scratch.push_back(sid[2]);
            if (lf[cell] == 13) scratch.push_back(sid[3]);
            if (riv[cell] != 0 && coast) scratch.push_back(sid[4]);
            if (coast) scratch.push_back(sid[5]);
            if (arid) scratch.push_back(sid[6]);
            if (wetland) scratch.push_back(sid[7]);
            if (forest) scratch.push_back(sid[8]);
            if (grass) scratch.push_back(sid[9]);
            if (lf[cell] == 7 || lf[cell] == 8 || lf[cell] == 13)
                scratch.push_back(sid[10]);
            if (riv[cell] != 0 && coast) scratch.push_back(sid[11]);
            if (riv[cell] != 0 && moist_land && elev[cell] <= 0.48f)
                scratch.push_back(sid[12]);
            if (warm && moist_land) scratch.push_back(sid[13]);
            if (grass && !arid && moist[cell] <= 0.56f) scratch.push_back(sid[14]);
            if (grass && dry_land) scratch.push_back(sid[15]);
            if (cold && !forest) scratch.push_back(sid[16]);
            if (cold && forest) scratch.push_back(sid[17]);
            if (arid && (riv[cell] != 0 || wetland)) scratch.push_back(sid[18]);
            if (highland) scratch.push_back(sid[19]);
            if ((coast || highland) && !forest) scratch.push_back(sid[20]);
        }
        std::sort(scratch.begin(), scratch.end());
        scratch.erase(std::unique(scratch.begin(), scratch.end()), scratch.end());
        for (int32_t signal : scratch) {
            if (signal < 0) continue;
            ids.push_back(signal);
            values.push_back(1);
            ++cursor;
        }
    }
    offset[n] = cursor;
    out["ok"] = true;
    out["path"] = String("gdext");
    out["generation_vegetation"] = vegetation;
    out["cell_biogeographic_realm"] = realms;
    out["cell_signal_offsets"] = offsets;
    out["cell_signal_ids"] = ids;
    out["cell_signal_values"] = values;
    return out;
}

Dictionary DCWorldExt::start_native_generation(int seed,
                                               const Dictionary &cfg,
                                               const Dictionary &profile) {
    _native_generation_active = true;
    _native_generation_seed = seed;
    _native_generation_cfg = cfg.duplicate(true);
    _native_generation_profile = profile.duplicate(true);
    _native_generation_report.clear();
    _native_generation_report["rc"] = 0;
    _native_generation_report["status"] = String("started");
    _native_generation_report["path"] = String("gdext");
    _native_generation_report["seed"] = seed;
    _native_generation_report["has_config"] = !cfg.is_empty();
    _native_generation_report["has_profile"] = !profile.is_empty();
    _native_generation_report["generation_progress"] = 0.0;
    _native_generation_report["implemented"] = true;
    _native_generation_report["published_to_slot"] = false;
    _native_generation_report["fallback"] = false;
    _native_generation_report["fallback_reason"] = String();
    _native_generation_report["fail_stage"] = String();
    return _native_generation_report.duplicate(true);
}

Dictionary DCWorldExt::run_native_generation_slice(const Dictionary &budget) {
    if (!_native_generation_active) {
        Dictionary out;
        out["rc"] = -1;
        out["status"] = String("idle");
        out["path"] = String("gdscript_fallback");
        out["fallback"] = true;
        out["fallback_reason"] = String("generation_not_started");
        out["reason"] = String("generation_not_started");
        out["seed"] = _native_generation_seed;
        out["budget"] = budget.duplicate(true);
        out["generation_progress"] = 0.0;
        out["implemented"] = true;
        out["published_to_slot"] = false;
        _native_generation_report = out.duplicate(true);
        return out;
    }
    Dictionary out = _run_native_generation_publish_pass(
        _native_generation_seed,
        _native_generation_cfg,
        _native_generation_profile,
        budget);
    _native_generation_active = false;
    _native_generation_report = out.duplicate(true);
    return out;
}

Dictionary DCWorldExt::finish_native_generation() {
    if (_native_generation_active) {
        Dictionary out = _run_native_generation_publish_pass(
            _native_generation_seed,
            _native_generation_cfg,
            _native_generation_profile,
            Dictionary());
        _native_generation_active = false;
        _native_generation_report = out.duplicate(true);
        return out;
    }
    if (!_native_generation_report.is_empty()) {
        return _native_generation_report.duplicate(true);
    }
    Dictionary out;
    out["rc"] = -1;
    out["status"] = String("idle");
    out["path"] = String("gdscript_fallback");
    out["fallback"] = true;
    out["fallback_reason"] = String("generation_not_started");
    out["reason"] = String("generation_not_started");
    out["seed"] = _native_generation_seed;
    out["generation_progress"] = 0.0;
    out["implemented"] = true;
    out["published_to_slot"] = false;
    _native_generation_report = out.duplicate(true);
    return out;
}

// ─────────────────────────────────────────────────────────────────────────
// run_temp_baseline_year_bake — cell_temp_baseline_year 的权威 C++ 烘焙
//   (cpp-dots-runtime：仿真量计算归 C++，GDScript 仅留 fallback)。
//
// 海冰 + 显示温度的运行期 baseline (cell_temp_baseline_year) 原本由 GDScript
//   map_data.bake_lat_temp_year_lut 就地 pow(cos,..) 烤出来再经
//   refresh_slots_from_map 推给 slot——仿真量的权威落在 GDScript，逼着
//   GDScript / C++ / Shader 三处镜像同一条 lat_temp_bell。本 pass 把这步收回 C++：
//   用唯一 C++ 实现 pk_lat_temp_bell 从 lat_norm 算 baseline，写
//   cell_temp_baseline_year slot 并 _flush_slot_to_map 回 MapData。
//
// 输入：knobs["lat_norm"] = PackedFloat32Array（归一化纬度 ny∈[0,1]，0=北极/1=南极；
//   依赖地图几何 cube_row_norm，仍由 GDScript 生成期烤）。lat_norm 走 knob 而非 slot：
//   本 pass 在生成期 bake_lat_temp_year_lut 之后立即调，此刻 cell_lat_norm slot 可能尚未 refresh。
// 输出：cell_temp_baseline_year slot（写满 + flush 回 MapData.temp_baseline_year_arr，
//   供 GDScript fallback pass / climate_daily / debug 消费）。
// fallback：未 bind / 缺 slot / 缺 knob / n<=0 → fallback=true，GDScript 自烤兜底。
godot::Dictionary DCWorldExt::run_temp_baseline_year_bake(godot::Dictionary knobs) {
    using godot::Dictionary;
    using godot::PackedFloat32Array;
    using godot::String;
    using godot::StringName;

    Dictionary out;
    out["path"] = String("gdscript_fallback");
    out["fallback"] = true;
    out["reason"] = String();
    out["elapsed_ms"] = -1.0;

    auto fail = [&](const char *why) -> Dictionary {
        out["reason"] = String(why);
        return out;
    };

    if (!_bound) return fail("not bound");
    const int sid_ty = component_id(StringName("cell_temp_baseline_year"));
    if (sid_ty < 0) return fail("no cell_temp_baseline_year slot");
    if (!knobs.has("lat_norm")) return fail("missing lat_norm knob");
    const PackedFloat32Array lat = knobs["lat_norm"];
    const int n = lat.size();
    if (n <= 0) return fail("lat_norm empty");

    auto t0 = std::chrono::high_resolution_clock::now();

    Slot &s_ty = _slots.write[sid_ty];
    if (s_ty.arr_f32.size() != n) s_ty.arr_f32.resize(n);
    const float * const __restrict LAT = lat.ptr();
    float       * const __restrict TY  = s_ty.arr_f32.ptrw();
    for (int i = 0; i < n; ++i) {
        // SAME_SOURCE: DCClimateMath.lat_temp_bell_from_ny —— ny∈[0,1] → 钟形∈[0,1]。
        TY[i] = float(pk_clamp01(pk_lat_temp_bell((double(LAT[i]) - 0.5) * 2.0)));
    }

    // 写回 MapData.temp_baseline_year_arr（GDScript fallback pass / climate_daily / debug 消费）。
    _flush_slot_to_map(sid_ty);

    auto t1 = std::chrono::high_resolution_clock::now();
    out["path"] = String("gdext");
    out["fallback"] = false;
    out["n_cells"] = n;
    out["published_to_slot"] = true;
    out["elapsed_ms"] = std::chrono::duration<double, std::milli>(t1 - t0).count();
    return out;
}


godot::Dictionary DCWorldExt::run_native_world_generate_post_base_pass(
    int seed,
    const Dictionary &cfg,
    const Dictionary &profile,
    const Dictionary &input) {
    using godot::Dictionary;
    using godot::PackedByteArray;
    using godot::PackedFloat32Array;
    using godot::PackedInt32Array;
    using godot::String;

    Dictionary out;
    out["rc"] = -1;
    out["status"] = String("failed");
    out["path"] = String("gdscript_fallback");
    out["fallback"] = true;
    out["fallback_reason"] = String();
    out["reason"] = String();
    out["fail_stage"] = String("native_generation_post_base");
    out["published_to_slot"] = false;
    out["n_cells"] = 0;
    out["elapsed_ms"] = -1.0;
    out["native_ms"] = -1.0;
    out["compute_ms"] = 0.0;
    out["native_algorithm"] = String("post_base_priority_flood_hydrology_v3");

    auto fail = [&](const char *why, const char *stage = "native_generation_post_base") -> Dictionary {
        out["fallback_reason"] = String(why);
        out["reason"] = String(why);
        out["fail_stage"] = String(stage);
        return out;
    };

    const int width = int(cfg.get("width", 0));
    const int height = int(cfg.get("height", 0));
    if (width <= 0 || height <= 0) return fail("invalid_dimensions", "config");
    const int64_t n64 = int64_t(width) * int64_t(height);
    if (n64 <= 0 || n64 > 1000000) return fail("invalid_cell_count", "config");
    const int n = int(n64);

    auto getd = [](const Dictionary &d, const char *key, double fallback) -> double {
        return d.has(key) ? double(d.get(key, fallback)) : fallback;
    };
    auto geti = [](const Dictionary &d, const char *key, int fallback) -> int {
        return d.has(key) ? int(d.get(key, fallback)) : fallback;
    };
    auto getb = [](const Dictionary &d, const char *key, bool fallback) -> bool {
        return d.has(key) ? bool(d.get(key, fallback)) : fallback;
    };

    const double sea_level = getd(cfg, "sea_level", 0.64);
    const bool ocean_enabled = getb(cfg, "enable_ocean_heat_transport", false);
    // ── [scale-fix 2026-07-30] 分辨率归一（与 base pass 湿度块同源）──────────────────
    // s = sqrt(N/15000)：固定世界的线性分辨率比。凡"以格数标定的物理距离"都要换算：
    // 雨影探针距离 ×s（下方 lookback）；relief 阈值 ×(15000/N)^0.5（relief_thresh_scale）；
    // 河流成河阈值 / RFLOW 归一见 river_map_scale（双向）与 flow_eq_scale。
    constexpr double PK_GEN_REF_CELLS = 15000.0;
    const double gen_dist_scale = std::sqrt(std::max(0.0625, double(n) / PK_GEN_REF_CELLS));
    // [scale-fix] lookback ×s 保持雨影物理到达距离恒定（0 仍是"关闭雨影"的语义，不改写）。
    const int lookback_base = std::max(0, geti(profile, "rain_shadow_lookback", 3));
    const int lookback = (lookback_base > 0)
            ? std::max(1, int(std::round(double(lookback_base) * gen_dist_scale)))
            : 0;
    const double rain_threshold = getd(profile, "rain_shadow_threshold", 0.13);
    const double rain_factor = getd(profile, "rain_shadow_factor", 0.65);
    const double river_percentile = getd(profile, "river_flow_percentile", 0.72);  // 干支流树状河网：0.80→0.72（绘出支流）
    const int hydro_river_min_length_base = std::max(1, geti(profile, "hydro_river_min_length", 5));  // 最短河长：8→5
    const int river_headwater_init_base = std::max(1, geti(profile, "river_headwater_init_cells", 10));  // [density-fix] 6→10
    const double river_headwater_min_land_h = getd(profile, "river_headwater_min_land_h", 0.30);
    const int hydro_lake_min_cells = std::max(1, geti(profile, "hydro_lake_min_cells", 8));  // 成湖最小面积：18→8
    const double hydro_lake_min_depth = std::max(0.0, getd(profile, "hydro_lake_min_depth", 0.018));
    const double hydro_lake_min_volume = std::max(0.0, getd(profile, "hydro_lake_min_volume", 0.22));
    const double orographic_boost = getd(profile, "orographic_boost", 1.2);
    const double veg_elev_decay = getd(profile, "veg_feedback_elev_decay", 0.5);
    const int max_volcanoes = std::max(0, geti(profile, "max_volcanoes", 8));
    const int volcano_min_dist = std::max(0, geti(profile, "volcano_min_dist", 6));
    const double volcano_min_land_h = getd(profile, "volcano_min_land_h", 0.55);
    // [volcano-crater 2026-06-25] 火山环形山高度场塑形幅度（归一化高程 0..1 空间，量级参考
    // 其他 relief pass 的 0.035~0.115）：中心 cell 下凹成 caldera，第一环邻居抬升成环山脊。
    const double volcano_crater_depth = std::max(0.0, getd(profile, "volcano_crater_depth", 0.05));
    const double volcano_rim_height   = std::max(0.0, getd(profile, "volcano_rim_height", 0.07));
    const double plateau_min_land_h = getd(profile, "plateau_min_land_h", 0.35);
    const double plateau_max_relief_base = std::max(0.0, getd(profile, "plateau_max_relief", 0.14));
    const int plateau_min_cells = std::max(1, geti(profile, "plateau_min_cells", 3));
    // [density-fix 2026-06-30] PLATEAU area-ratio cap: unlike PEAK (land/N count
    // cap) and RIFT (land/N cap), PLATEAU previously had no density limit at all.
    // Cap total plateau area to a fraction of land; when exceeded, keep the
    // largest connected components and demote smaller ones to HILL.
    const double plateau_max_land_ratio = std::max(0.0, std::min(1.0, getd(profile, "plateau_max_land_ratio", 0.25)));
    // [density-fix] plateau_max_relief scales down for large maps: finer cell
    // sampling makes per-cell relief naturally smaller (same gradient sampled at
    // higher resolution → smaller per-cell deltas), so a fixed threshold admits
    // too many plateau candidates on large maps. Tighten by (ref/N)^k; exponent
    // 0.25 is a mild, conservative factor — the area-ratio cap above is the
    // primary density control, this is a secondary nudge.
    // [relief-physical 2026-10-12] PLATEAU/MOUNTAIN 的局部起伏改在固定物理半径上测量：
    // 噪声在归一化坐标采样，N 增大时 1 圈邻格高差随之变小，1 圈 relief 会把大图高地整片
    // 判成 PLATEAU（实测 60x40→200x150 占陆 6%→30%）。N > relief_ref_cells 时取半径
    // k=round(sqrt(N/ref)) 圈的 max-min，并按 sqrt(N/ref)/k 换算回参考格距的 1 圈当量；
    // 阈值冻结在 ref 尺寸的值。N <= ref 时 k=1、换算系数 1，与旧行为逐位一致。
    // base pass 的造山/山脊噪声已按 feature_scale 改为格距定义，只剩未抵消的那部分放大需要扩半径。
    const double relief_ref_cells = std::max(100.0, getd(profile, "relief_ref_cells", 2400.0));
    const double relief_feature_scale = std::pow(
            std::max(1.0, std::sqrt(double(n) / std::max(100.0, getd(profile, "feature_ref_cells", 2400.0)))),
            std::clamp(getd(profile, "feature_scale_exp", 1.0), 0.0, 1.0));
    const double relief_ideal_radius = std::max(1.0, std::sqrt(double(n) / relief_ref_cells) / relief_feature_scale);
    const int relief_radius = std::clamp(int(std::lround(relief_ideal_radius)), 1, 6);
    const double relief_radius_norm = relief_ideal_radius / double(relief_radius);
    const double geomorph_relief_n = std::min(double(n), relief_ref_cells);
    constexpr double plateau_relief_ref_cells = 15000.0;
    constexpr double plateau_relief_scale_exp = 0.25;
    const double plateau_relief_scale = std::pow(
            std::min(1.0, plateau_relief_ref_cells / std::max(1.0, geomorph_relief_n)),
            plateau_relief_scale_exp);
    const double plateau_max_relief = plateau_max_relief_base * plateau_relief_scale;
    const double mountain_min_land_h = getd(profile, "mountain_min_land_h", 0.70);
    const double mountain_min_relief_base = std::max(0.0, getd(profile, "mountain_min_relief", 0.115));
    const double peak_min_land_h = getd(profile, "peak_min_land_h", 0.74);
    const double peak_min_prominence = std::max(0.0, getd(profile, "peak_min_prominence", 0.035));
    const int peak_land_cells_per_peak = std::max(1, geti(profile, "peak_land_cells_per_peak", 120));
    const double rift_min_wall_base = std::max(0.0, getd(profile, "rift_min_wall", 0.024));
    const double rift_min_axis_base = std::max(0.0, getd(profile, "rift_min_axis", 0.052));
    const int rift_min_length_base = std::max(1, geti(profile, "rift_min_length_cells", 3));
    const double badlands_min_relief_base = std::max(0.0, getd(profile, "badlands_min_relief", 0.06));
    const int badlands_min_rugged_neighbors = std::max(1, std::min(6,
            geti(profile, "badlands_min_rugged_neighbors", 2)));
    const double badlands_max_land_ratio = std::clamp(
            getd(profile, "badlands_max_land_ratio", 1.0), 0.0, 1.0);
    const double badlands_max_arid_ratio = std::clamp(
            getd(profile, "badlands_max_arid_ratio", 1.0), 0.0, 1.0);
    // 默认不截断自然候选区；调试极端地图时仍可显式设置安全阀。
    const int badlands_max_patch_cells = std::max(0,
            geti(profile, "badlands_max_patch_cells", 0));
    // [scale-fix 2026-07-30] mountain/badlands 的 relief 阈值参照 plateau 的 (ref/N)^k 模式
    // 补分辨率缩放，但双向、指数默认 0.25：保留分辨率补偿，同时避免 60x40 等小地图
    // 把 mountain/rift/badlands 的局部高差门槛放大到候选集之外。
    // peak_min_prominence 维持不缩（PEAK 有 land/N 数量上限主控）。
    const double relief_thresh_scale_exp = getd(profile, "relief_thresh_scale_exp", 0.25);
    const double relief_thresh_scale = std::pow(
            std::max(0.25, PK_GEN_REF_CELLS / std::max(1.0, double(n))),
            relief_thresh_scale_exp);
    const double geomorph_relief_scale = std::pow(
            std::max(0.25, PK_GEN_REF_CELLS / std::max(1.0, geomorph_relief_n)),
            relief_thresh_scale_exp);
    const double mountain_min_relief = mountain_min_relief_base * geomorph_relief_scale;
    const double badlands_min_relief = badlands_min_relief_base * relief_thresh_scale;
    const double rift_min_wall = rift_min_wall_base * relief_thresh_scale;
    const double rift_min_axis = rift_min_axis_base * relief_thresh_scale;
    const int rift_min_length = std::max(1, int(std::round(
            double(rift_min_length_base) * gen_dist_scale)));
    const int river_channel_init_base = std::max(2, geti(profile, "river_channel_init_cells", 16));
    // 15000 格(150×100)是 ClimateProfile 的调参基准。世界是固定大小的行星：同源点的
    // up_count ∝ N（流域物理面积不变 → 流域格数 ∝ N），成河阈值须随 N 线性缩放才能
    // 保持河网物理密度恒定。
    //
    // [density-fix 2026-06-30] exponent 0.65→1.0: 线性缩放等价于把 up_count 归一化。
    // [scale-fix 2026-07-30] max(1.0,…) clamp → 双向缩放：旧 clamp 使 N<15000 的小图
    // 不缩，阈值相对流域面积偏高(64×100 时 ~2.3×) → 支流发不出来，小图河稀反衬大图
    // 河多。下限 0.25 仅防极端小图阈值归零。
    constexpr double river_map_reference_cells = 15000.0;
    constexpr double river_map_scale_exponent = 1.0;
    const double river_map_scale = std::pow(
            std::max(0.25, double(n) / river_map_reference_cells),
            river_map_scale_exponent);
    const int channel_init = std::max(2, int(std::round(double(river_channel_init_base) * river_map_scale)));
    const int river_headwater_init = std::max(1, int(std::round(double(river_headwater_init_base) * river_map_scale)));
    // [density-fix] min_length scale exponent 0.75→1.0: keep prune strength in
    // lockstep with channel_init so large-map short tributaries are pruned
    // proportionally rather than retained at a relatively weaker rate.
    const int hydro_river_min_length = std::max(1, int(std::round(
            double(hydro_river_min_length_base) * std::pow(river_map_scale, 1.0))));

    PackedInt32Array q_arr = input.get("q_arr", PackedInt32Array());
    PackedInt32Array r_arr = input.get("r_arr", PackedInt32Array());
    PackedInt32Array s_arr = input.get("s_arr", PackedInt32Array());
    PackedFloat32Array elevation_arr = input.get("elevation_arr", PackedFloat32Array());
    PackedFloat32Array moisture_arr = input.get("moisture_arr", PackedFloat32Array());
    PackedFloat32Array base_moisture_arr = input.get("base_moisture_arr", PackedFloat32Array());
    PackedFloat32Array temp_arr = input.get("temp_arr", PackedFloat32Array());
    PackedFloat32Array temp_baseline_arr = input.get("temp_baseline_arr", PackedFloat32Array());
    PackedFloat32Array temp_30d_arr = input.get("temp_30d_arr", PackedFloat32Array());
    PackedFloat32Array temp_365d_arr = input.get("temp_365d_arr", PackedFloat32Array());
    PackedFloat32Array temp_anomaly_arr = input.get("temp_anomaly_arr", PackedFloat32Array());
    PackedFloat32Array thermal_energy_arr = input.get("thermal_energy_arr", PackedFloat32Array());
    PackedFloat32Array cell_lat_norm_arr = input.get("cell_lat_norm_arr", PackedFloat32Array());
    PackedFloat32Array temp_baseline_year_arr = input.get("temp_baseline_year_arr", PackedFloat32Array());
    PackedFloat32Array snow_cover_arr = input.get("snow_cover_arr", PackedFloat32Array());
    PackedFloat32Array upwelling_arr = input.get("upwelling_strength_arr", PackedFloat32Array());
    PackedInt32Array dist_ocean_arr = input.get("dist_ocean_arr", PackedInt32Array());
    PackedByteArray terrain_arr = input.get("terrain_arr", PackedByteArray());
    PackedByteArray cover_arr = input.get("cover_arr", PackedByteArray());
    PackedByteArray ema_initialized_arr = input.get("ema_initialized_arr", PackedByteArray());

    if (q_arr.size() != n || r_arr.size() != n || elevation_arr.size() != n ||
        moisture_arr.size() != n || terrain_arr.size() != n) {
        return fail("required_input_size_mismatch", "input");
    }
    if (s_arr.size() != n) {
        s_arr.resize(n);
        int32_t *S = s_arr.ptrw();
        const int32_t *Q = q_arr.ptr();
        const int32_t *R = r_arr.ptr();
        for (int i = 0; i < n; ++i) S[i] = -Q[i] - R[i];
    }
    if (base_moisture_arr.size() != n) base_moisture_arr = moisture_arr.duplicate();
    if (temp_arr.size() != n) {
        temp_arr.resize(n);
        float *T = temp_arr.ptrw();
        const float *E = elevation_arr.ptr();
        const int32_t *R = r_arr.ptr();
        const double inv_h = 1.0 / double(std::max(height - 1, 1));
        for (int i = 0; i < n; ++i) T[i] = pk_compute_temperature(double(R[i]) * inv_h, E[i], sea_level);
    }
    if (temp_baseline_arr.size() != n) temp_baseline_arr = temp_arr.duplicate();
    if (temp_30d_arr.size() != n) temp_30d_arr = temp_arr.duplicate();
    if (temp_365d_arr.size() != n) temp_365d_arr = temp_arr.duplicate();
    if (temp_anomaly_arr.size() != n) {
        temp_anomaly_arr.resize(n);
        float *TA = temp_anomaly_arr.ptrw();
        for (int i = 0; i < n; ++i) TA[i] = 0.0f;
    }
    if (thermal_energy_arr.size() != n) thermal_energy_arr = temp_arr.duplicate();
    if (cell_lat_norm_arr.size() != n) {
        cell_lat_norm_arr.resize(n);
        float *LAT = cell_lat_norm_arr.ptrw();
        const int32_t *R = r_arr.ptr();
        const double inv_h = 1.0 / double(std::max(height - 1, 1));
        for (int i = 0; i < n; ++i) LAT[i] = float(double(R[i]) * inv_h);
    }
    if (temp_baseline_year_arr.size() != n) {
        temp_baseline_year_arr.resize(n);
        const float *LAT = cell_lat_norm_arr.ptr();
        float *TY = temp_baseline_year_arr.ptrw();
        for (int i = 0; i < n; ++i) {
            TY[i] = float(pk_clamp01(pk_lat_temp_bell((double(LAT[i]) - 0.5) * 2.0)));
        }
    }
    if (snow_cover_arr.size() != n) {
        snow_cover_arr.resize(n);
        float *SN = snow_cover_arr.ptrw();
        for (int i = 0; i < n; ++i) SN[i] = 0.0f;
    }
    if (cover_arr.size() != n) {
        cover_arr.resize(n);
        uint8_t *C = cover_arr.ptrw();
        for (int i = 0; i < n; ++i) C[i] = 0;
    }
    if (ema_initialized_arr.size() != n) {
        ema_initialized_arr.resize(n);
        uint8_t *EMA = ema_initialized_arr.ptrw();
        for (int i = 0; i < n; ++i) EMA[i] = 1;
    }

    PackedByteArray base_terrain_arr;
    base_terrain_arr.resize(n);
    PackedByteArray landform_arr;
    landform_arr.resize(n);
    PackedByteArray base_landform_arr;
    base_landform_arr.resize(n);
    PackedByteArray vegetation_arr;
    vegetation_arr.resize(n);
    PackedByteArray base_vegetation_arr;
    base_vegetation_arr.resize(n);
    PackedFloat32Array vegetation_vitality_arr;
    PackedFloat32Array soil_moisture_arr;
    PackedFloat32Array water_balance_30d_arr;
    PackedFloat32Array plant_available_water_arr;
    PackedFloat32Array vegetation_growth_pressure_arr;
    PackedFloat32Array vegetation_heat_stress_arr;
    PackedFloat32Array vegetation_drought_stress_arr;
    PackedFloat32Array vegetation_cold_stress_arr;
    PackedFloat32Array vegetation_regen_score_arr;
    vegetation_vitality_arr.resize(n);
    soil_moisture_arr.resize(n);
    water_balance_30d_arr.resize(n);
    plant_available_water_arr.resize(n);
    vegetation_growth_pressure_arr.resize(n);
    vegetation_heat_stress_arr.resize(n);
    vegetation_drought_stress_arr.resize(n);
    vegetation_cold_stress_arr.resize(n);
    vegetation_regen_score_arr.resize(n);
    PackedByteArray is_water_arr;
    is_water_arr.resize(n);
    PackedByteArray has_river_arr;
    has_river_arr.resize(n);
    PackedFloat32Array river_flow_arr;
    river_flow_arr.resize(n);
    PackedInt32Array river_downstream_arr;
    river_downstream_arr.resize(n);
    PackedInt32Array hydro_parent_arr;
    hydro_parent_arr.resize(n);
    PackedByteArray has_volcano_arr;
    has_volcano_arr.resize(n);

    const auto t0 = std::chrono::high_resolution_clock::now();

    const int32_t * const Q = q_arr.ptr();
    const int32_t * const R = r_arr.ptr();
    const int32_t * const S = s_arr.ptr();
    // [volcano-crater 2026-06-25] E 改为可写(.ptrw 前置 CoW，确保唯一缓冲)：火山 pass 需对火山
    // 及第一环邻居写高程塑成环形山，写回经 out["elevation_arr"] 传播到 HexCell.elevation。所有既有
    // 只读用法不受影响；后续结构地貌 pass 读到的是塑形后的高程（自洽：环脊更易判为 PEAK/MOUNTAIN）。
    float * const E = elevation_arr.ptrw();
    float * const M = moisture_arr.ptrw();
    float * const BM = base_moisture_arr.ptrw();
    float * const TEMP = temp_arr.ptrw();
    float * const T30 = temp_30d_arr.ptrw();
    float * const T365 = temp_365d_arr.ptrw();
    uint8_t * const TERR = terrain_arr.ptrw();
    uint8_t * const BTERR = base_terrain_arr.ptrw();
    uint8_t * const LF = landform_arr.ptrw();
    uint8_t * const BLF = base_landform_arr.ptrw();
    uint8_t * const VEG = vegetation_arr.ptrw();
    uint8_t * const BVEG = base_vegetation_arr.ptrw();
    uint8_t * const COV = cover_arr.ptrw();
    uint8_t * const IW = is_water_arr.ptrw();
    uint8_t * const RIV = has_river_arr.ptrw();
    float * const RFLOW_OUT = river_flow_arr.ptrw();
    int32_t * const RDOWN = river_downstream_arr.ptrw();
    int32_t * const HPARENT_OUT = hydro_parent_arr.ptrw();
    uint8_t * const VOLC = has_volcano_arr.ptrw();
    float * const VITALITY = vegetation_vitality_arr.ptrw();
    float * const SOIL = soil_moisture_arr.ptrw();
    float * const WB30 = water_balance_30d_arr.ptrw();
    float * const PLANT_WATER = plant_available_water_arr.ptrw();
    float * const VG_PRESSURE = vegetation_growth_pressure_arr.ptrw();
    float * const VHEAT = vegetation_heat_stress_arr.ptrw();
    float * const VDROUGHT = vegetation_drought_stress_arr.ptrw();
    float * const VCOLD = vegetation_cold_stress_arr.ptrw();
    float * const VREGEN = vegetation_regen_score_arr.ptrw();
    float * const UP = (upwelling_arr.size() == n) ? upwelling_arr.ptrw() : nullptr;

    constexpr int DQ[6] = { 1, 1, 0, -1, -1, 0 };
    constexpr int DR[6] = { 0, -1, -1, 0, 1, 1 };
    auto index_for_qr = [&](int q, int r) -> int {
        // [cylindrical-earth-daylight] 东西经度环绕：r(南北)保持硬边界返回 -1，
        // col(经度)用 posmod 绕回 [0,width) → 生成期邻居访问与运行时 map_data 一样东西连通；
        // 雨影 upwind 探针、侵蚀/水文 BFS 等读此函数的 pass 自动获得东西环绕。
        if (r < 0 || r >= height) return -1;
        int col = q + ((r - (r & 1)) / 2);
        col = ((col % width) + width) % width;
        return r * width + col;
    };
    std::vector<int32_t> NB(size_t(n) * 6, -1);
    for (int i = 0; i < n; ++i) {
        for (int d = 0; d < 6; ++d) {
            NB[size_t(i) * 6 + d] = index_for_qr(Q[i] + DQ[d], R[i] + DR[d]);
        }
    }
    auto row_norm = [&](int i) -> double {
        return double(R[i]) / double(std::max(height - 1, 1));
    };
    auto land_h = [&](int i) -> double {
        return (double(E[i]) - sea_level) / std::max(1.0 - sea_level, 0.001);
    };
    auto geomorph_h = [&](int i) -> double {
        return pk_geomorph_h(double(E[i]), sea_level);
    };

    // ── 统一气候场（terrain-overhaul Phase 3）：距海距离 + 海洋温度调节 ──
    // 复用 base pass 传来的 dist_ocean_arr；缺失则按 elev<sea_level 现场重算 BFS。
    const double coastal_temp_moderation = getd(profile, "coastal_temp_moderation", 0.18);
    // [scale-fix 2026-07-30] 衰减长度 ×s（与 base pass 一致），保持海洋调温的物理范围恒定。
    const double coastal_temp_scale = std::max(0.5, getd(profile, "coastal_temp_scale", 6.0) * gen_dist_scale);
    std::vector<int32_t> dist_ocean(size_t(n), -1);
    if (dist_ocean_arr.size() == n) {
        const int32_t *DO = dist_ocean_arr.ptr();
        for (int i = 0; i < n; ++i) dist_ocean[size_t(i)] = DO[i];
    } else {
        std::vector<int> bfsq;
        bfsq.reserve(size_t(n));
        for (int i = 0; i < n; ++i) {
            if (double(E[i]) < sea_level) { dist_ocean[size_t(i)] = 0; bfsq.push_back(i); }
        }
        for (size_t qi = 0; qi < bfsq.size(); ++qi) {
            const int cur = bfsq[qi];
            const int nd = dist_ocean[size_t(cur)] + 1;
            for (int d = 0; d < 6; ++d) {
                const int ni = NB[size_t(cur) * 6 + d];
                if (ni < 0 || dist_ocean[size_t(ni)] >= 0) continue;
                dist_ocean[size_t(ni)] = nd;
                bfsq.push_back(ni);
            }
        }
    }
    auto ocean_influence = [&](int i) -> double {
        const int dd = dist_ocean[size_t(i)];
        if (dd < 0) return 0.0;
        return std::exp(-double(dd) / std::max(coastal_temp_scale, 0.5));
    };
    // 生成期分类温度：纬度钟形 - 海拔惩罚，再按海洋邻近度拉向温带。与 base pass gen_temp 一致，
    // 保证 base/post_base 同一套温度→biome 判定（gen_once）。运行时温度场 TEMP[] 不受影响。
    auto gen_temp = [&](int i) -> double {
        const double base = pk_lat_temp_bell((row_norm(i) - 0.5) * 2.0) - pk_alt_penalty(double(E[i]), sea_level);
        const double infl = ocean_influence(i);
        return pk_clamp01(base + infl * coastal_temp_moderation * (0.5 - base));
    };

    auto cube_distance = [&](int a, int b) -> int {
        // [cylindrical-earth-daylight] 东西环绕的最短 cube 距离：把 b 沿 col 方向 ±width
        // 平移（offset col±width ⇔ cube q±width, s∓width, r 不变），取三者最小 →
        // 火山间距等横向度量在接缝处也正确。
        const int dq = Q[a] - Q[b];
        const int dr = R[a] - R[b];
        const int ds = S[a] - S[b];
        const int d0 = (std::abs(dq) + std::abs(dr) + std::abs(ds)) / 2;
        const int d1 = (std::abs(dq - width) + std::abs(dr) + std::abs(ds + width)) / 2;
        const int d2 = (std::abs(dq + width) + std::abs(dr) + std::abs(ds - width)) / 2;
        return std::min(d0, std::min(d1, d2));
    };
    auto sync_axes = [&](int i) {
        const uint8_t lf = pk_derive_landform_with_volcano(TERR[i], E[i], float(sea_level), VOLC[i] != 0);
        const uint8_t veg = pk_derive_vegetation(TERR[i], lf, TEMP[i], M[i]);
        uint8_t cov = pk_derive_cover(TERR[i], 0.0f);
        if (ocean_enabled && UP != nullptr && TERR[i] == 0) {
            bool has_land_neighbor = false;
            for (int d = 0; d < 6; ++d) {
                const int ni = NB[size_t(i) * 6 + d];
                if (ni >= 0 && !pk_is_water_terrain(TERR[ni])) {
                    has_land_neighbor = true;
                    break;
                }
            }
            if (!has_land_neighbor && UP[i] > 0.6f) cov = 6; // PELAGIC_BLOOM
        }
        LF[i] = lf;
        BLF[i] = lf;
        VEG[i] = veg;
        BVEG[i] = veg;
        COV[i] = cov;
        IW[i] = pk_is_water_terrain(TERR[i]) ? uint8_t(1) : uint8_t(0);
        BTERR[i] = TERR[i];
    };

    for (int i = 0; i < n; ++i) {
        BM[i] = M[i];
        RIV[i] = 0;
        RFLOW_OUT[i] = 0.0f;
        RDOWN[i] = -1;
        HPARENT_OUT[i] = -1;
        VOLC[i] = 0;
        IW[i] = pk_is_water_terrain(TERR[i]) ? uint8_t(1) : uint8_t(0);
    }

    // Hydrologic correction: Priority-Flood style spill surface + parent graph.
    // This is the light-weight equivalent of DEM depression filling used by
    // RichDEM/FlowFill workflows: every cell gets an outlet path through its
    // lowest spill, so lakes and rivers are derived from one coherent drainage
    // surface rather than local raw-elevation pits.
    std::vector<uint8_t> connected(size_t(n), 0);
    std::vector<int> queue;
    queue.reserve(size_t(n));
    for (int i = 0; i < n; ++i) {
        if (!pk_is_ocean_connected_seed_terrain(TERR[i])) continue;
        // [cylindrical-earth-daylight] 仅南北极(row)作排水出口种子；东西经度环绕由 NB(已 posmod) 在 BFS 扩散时连通。
        const int row = R[i];
        if (row == 0 || row == height - 1) {
            connected[size_t(i)] = 1;
            queue.push_back(i);
        }
    }
    for (size_t qi = 0; qi < queue.size(); ++qi) {
        const int cur = queue[qi];
        for (int d = 0; d < 6; ++d) {
            const int ni = NB[size_t(cur) * 6 + d];
            if (ni < 0 || connected[size_t(ni)]) continue;
            if (!pk_is_ocean_connected_seed_terrain(TERR[ni])) continue;
            connected[size_t(ni)] = 1;
            queue.push_back(ni);
        }
    }

    using HydroNode = std::pair<float, int>;
    std::priority_queue<HydroNode, std::vector<HydroNode>, std::greater<HydroNode>> hydro_pq;
    std::vector<uint8_t> hydro_seen(size_t(n), 0);
    std::vector<float> hydro_fill(size_t(n), std::numeric_limits<float>::infinity());
    std::vector<int32_t> hydro_parent(size_t(n), -1);
    std::vector<int> hydro_order;
    hydro_order.reserve(size_t(n));
    for (int i = 0; i < n; ++i) {
        // [cylindrical-earth-daylight] 仅南北极(row)作水文 flood 出海口；东西经度环绕由 index_for_qr/NB 处理。
        const int row = R[i];
        if (row != 0 && row != height - 1) continue;
        hydro_seen[size_t(i)] = 1;
        hydro_fill[size_t(i)] = E[i];
        hydro_pq.push(HydroNode(E[i], i));
        hydro_order.push_back(i);
    }
    while (!hydro_pq.empty()) {
        const HydroNode cur_node = hydro_pq.top();
        hydro_pq.pop();
        const float cur_z = cur_node.first;
        const int cur = cur_node.second;
        if (cur_z > hydro_fill[size_t(cur)] + 0.000001f) continue;
        for (int d = 0; d < 6; ++d) {
            const int ni = NB[size_t(cur) * 6 + d];
            if (ni < 0 || hydro_seen[size_t(ni)] != 0) continue;
            hydro_seen[size_t(ni)] = 1;
            const float spill_z = std::max(E[ni], cur_z);
            hydro_fill[size_t(ni)] = spill_z;
            hydro_parent[size_t(ni)] = cur;
            hydro_pq.push(HydroNode(spill_z, ni));
            hydro_order.push_back(ni);
        }
    }
    for (int i = 0; i < n; ++i) {
        HPARENT_OUT[i] = hydro_parent[size_t(i)];
    }

    auto reclassify_drained_land = [&](int i) {
        const double eff_e = std::max(double(E[i]), sea_level + 0.012);
        const double eff_m = std::max(double(M[i]), 0.38);
        uint8_t nt = pk_decide_terrain_ex(eff_e, gen_temp(i),
                                          eff_m, sea_level, true);
        if (pk_is_water_terrain(nt)) nt = 2; // PLAIN fallback; drained tiny pits should not stay blue.
        TERR[i] = nt;
    };

    std::vector<uint8_t> lake_candidate(size_t(n), 0);
    for (int i = 0; i < n; ++i) {
        if (connected[size_t(i)] != 0) continue;
        const double depth = double(hydro_fill[size_t(i)]) - double(E[i]);
        if (depth >= hydro_lake_min_depth) lake_candidate[size_t(i)] = 1;
        if (pk_is_ocean_connected_seed_terrain(TERR[i]) && !connected[size_t(i)] && depth > 0.001) {
            lake_candidate[size_t(i)] = 1;
        }
    }

    int lake_count = 0;
    int lake_component_count = 0;
    int drained_tiny_lake_count = 0;
    std::vector<uint8_t> lake_seen(size_t(n), 0);
    std::vector<int> comp;
    comp.reserve(256);
    for (int i = 0; i < n; ++i) {
        if (lake_seen[size_t(i)] != 0 || lake_candidate[size_t(i)] == 0) continue;
        comp.clear();
        queue.clear();
        queue.push_back(i);
        lake_seen[size_t(i)] = 1;
        double volume = 0.0;
        double max_depth = 0.0;
        for (size_t qi = 0; qi < queue.size(); ++qi) {
            const int cur = queue[qi];
            comp.push_back(cur);
            const double depth = std::max(0.0, double(hydro_fill[size_t(cur)]) - double(E[cur]));
            volume += depth;
            max_depth = std::max(max_depth, depth);
            for (int d = 0; d < 6; ++d) {
                const int ni = NB[size_t(cur) * 6 + d];
                if (ni < 0 || lake_seen[size_t(ni)] != 0 || lake_candidate[size_t(ni)] == 0) continue;
                lake_seen[size_t(ni)] = 1;
                queue.push_back(ni);
            }
        }
        const bool keep_lake = int(comp.size()) >= hydro_lake_min_cells ||
                (int(comp.size()) >= 4 && volume >= hydro_lake_min_volume && max_depth >= hydro_lake_min_depth * 1.5);
        if (keep_lake) {
            ++lake_component_count;
            for (int v : comp) {
                TERR[v] = 18; // LAKE
                ++lake_count;
            }
        } else {
            for (int v : comp) {
                if (pk_is_water_terrain(TERR[v])) {
                    reclassify_drained_land(v);
                    ++drained_tiny_lake_count;
                }
            }
        }
    }
    for (int i = 0; i < n; ++i) {
        if (pk_is_ocean_connected_seed_terrain(TERR[i]) && !connected[size_t(i)]) {
            reclassify_drained_land(i);
            ++drained_tiny_lake_count;
        }
        IW[i] = pk_is_water_terrain(TERR[i]) ? uint8_t(1) : uint8_t(0);
    }

    // Snapshot base moisture before rain shadow / river ecology.
    for (int i = 0; i < n; ++i) BM[i] = M[i];

    // 复刻 _apply_rain_shadow_per_cell(season_phase=1.0)：
    //   1) jitter 来自 _height_warp.get_noise_2d(q*8, r*8)*0.04（需重建同款 FastNoiseLite）；
    //   2) upwind 目标是 cell + best_dir*lookback 的直接 cube 跳转（== get_cell_by_cube），
    //      而非逐步 NB 走步——后者在地图边缘对角方向会与 GDScript 差 1 格。
    Ref<FastNoiseLite> rs_warp;  rs_warp.instantiate();
    if (rs_warp.is_valid()) {
        rs_warp->set_noise_type(FastNoiseLite::TYPE_SIMPLEX_SMOOTH);
        rs_warp->set_seed(seed + 13);
        rs_warp->set_frequency(0.025);
        rs_warp->set_fractal_type(FastNoiseLite::FRACTAL_FBM);
        rs_warp->set_fractal_octaves(3);
    }
    int rain_shadow_touched = 0;
    if (lookback > 0 && rs_warp.is_valid()) {
        for (int i = 0; i < n; ++i) {
            if (pk_is_water_terrain(TERR[i])) continue;
            // [cylindrical-earth-daylight] 雨影 jitter 经度环绕：把原 Q*8 的经度轴换成周长 8*width
            // 的圆环(每 col 弧长≈8，特征尺度不变)，纬度仍 R*8 → 接缝处风扰动连续；配合下方
            // index_for_qr 的 upwind 探针(已环绕)，雨影在东西方向无缝、不再有边缘断层。
            const int rs_col = i % width;
            const double rs_rc = 8.0 * double(width) / PK_TWO_PI;
            const double rs_theta = PK_TWO_PI * (double(rs_col) / double(width));
            const double jitter = double(rs_warp->get_noise_3d(std::cos(rs_theta) * rs_rc,
                                                               std::sin(rs_theta) * rs_rc,
                                                               double(R[i]) * 8.0)) * 0.04;
            const PkWind2 wind = pk_wind_belt_wind_at(row_norm(i), 1.0, jitter);
            const int dir = pk_upwind_dir_index_from_wind(wind.x, wind.y);
            if (dir < 0) continue;
            const int probe = index_for_qr(Q[i] + DQ[dir] * lookback, R[i] + DR[dir] * lookback);
            if (probe < 0) continue;
            if (double(E[probe]) > double(E[i]) + rain_threshold) {
                M[i] = float(double(M[i]) * rain_factor);
                ++rain_shadow_touched;
            }
        }
    }

    int redecide_touched = 0;
    for (int i = 0; i < n; ++i) {
        const uint8_t t = TERR[i];
        if (pk_is_water_terrain(t) || t == 6 || t == 9 || t == 8) continue;
        // 用统一气候场温度(gen_temp，含海洋调节)重判 biome，与 base pass 同源。
        const uint8_t nt = pk_decide_terrain_ex(double(E[i]), gen_temp(i),
                                                double(M[i]), sea_level, true);
        // [破碎湖修复 2026-06-19] 绝不把陆地重新判回水：内陆低于海平面但已被 reclassify_
        // drained_land 排干成陆(PLAIN)的格，其原始 E 仍 < sea_level，若用原始 E 重判会被重新
        // 判成 COAST/OCEAN → 内陆遍布"碎水/破碎湖"(实测 ~144 内陆 COAST 格)。陆→水一律跳过；
        // 真正的内陆湖由上方基于洼地深度的 LAKE 检测专门生成。
        if (pk_is_water_terrain(nt) && !pk_is_water_terrain(t)) continue;
        if (nt != t) {
            TERR[i] = nt;
            ++redecide_touched;
        }
    }

    std::vector<int> land;
    land.reserve(size_t(n));
    for (int i = 0; i < n; ++i) {
        if (!pk_is_water_terrain(TERR[i])) land.push_back(i);
    }
    // Flow accumulation on the hydrologically corrected parent graph.
    std::vector<float> flow(size_t(n), 0.0f);
    const double inv_above_sea = 1.0 / std::max(1.0 - sea_level, 0.001);
    for (int i = 0; i < n; ++i) {
        if (connected[size_t(i)] != 0 && pk_is_water_terrain(TERR[i])) continue;
        if (pk_is_water_terrain(TERR[i]) && TERR[i] != 18) continue;
        const double base_rain = 0.4 + (1.6 - 0.4) * double(M[i]);
        const double lh = (double(hydro_fill[size_t(i)]) - sea_level) * inv_above_sea;
        const double oro = 1.0 + std::max(lh - 0.30, 0.0) * orographic_boost;
        flow[size_t(i)] = pk_is_water_terrain(TERR[i]) ? 0.0f : float(base_rain * oro);
    }
    for (auto it = hydro_order.rbegin(); it != hydro_order.rend(); ++it) {
        const int i = *it;
        const int p = hydro_parent[size_t(i)];
        if (p < 0) continue;
        if (connected[size_t(i)] != 0 && pk_is_water_terrain(TERR[i])) continue;
        flow[size_t(p)] += flow[size_t(i)];
    }
    // ── 河道起始：按"上游汇水面积(汇水格数)"有效阈值取河道 ───────────────────────
    // [river-rework 2026-06-19] 旧法按 flow 分位选 top-X% 地块为源头再向下追踪 → 标出 land 的
    // 固定比例(实测分位 0.72→占全图 ~10% 成"填满大陆的网"；调高分位又退化成贴海岸的短段)。
    // 改用地貌学经典 channel-initiation：汇水面积≥阈值才成河 → 天然稀疏树状网：上游细流在累积
    // 足够汇水后出现，向下汇成干流。大图会按 cell 数温和放大阈值，避免固定格数阈值把超大
    // 流域切出过密支流，同时保留 profile slider 的相对密度含义。
    std::vector<int> up_count(size_t(n), 0);
    for (int i : land) up_count[size_t(i)] = 1;
    for (auto it = hydro_order.rbegin(); it != hydro_order.rend(); ++it) {
        const int i = *it;
        if (up_count[size_t(i)] == 0) continue;
        const int p = hydro_parent[size_t(i)];
        if (p < 0) continue;
        up_count[size_t(p)] += up_count[size_t(i)];
    }
    float river_threshold = std::numeric_limits<float>::infinity();
    for (int i : land) {
        if (up_count[size_t(i)] >= channel_init) {
            RIV[i] = 1;
            river_threshold = std::min(river_threshold, flow[size_t(i)]);
        }
    }
    int headwater_touched = 0;
    if (river_headwater_init < channel_init) {
        for (int i : land) {
            if (RIV[i] != 0) continue;
            if (land_h(i) < river_headwater_min_land_h) continue;
            if (up_count[size_t(i)] < river_headwater_init) continue;
            std::vector<int> path;
            path.reserve(24);
            bool connects = false;
            int cur = i;
            for (int step = 0; step < 24 && cur >= 0 && cur < n; ++step) {
                if (pk_is_water_terrain(TERR[cur])) { connects = true; break; }
                path.push_back(cur);
                const int p = hydro_parent[size_t(cur)];
                if (p < 0 || p == cur) break;
                if (RIV[p] != 0 || pk_is_water_terrain(TERR[p])) { connects = true; break; }
                cur = p;
            }
            if (!connects || path.size() < 2) continue;
            for (int v : path) {
                if (RIV[v] == 0) {
                    RIV[v] = 1;
                    ++headwater_touched;
                }
                river_threshold = std::min(river_threshold, flow[size_t(v)]);
            }
        }
    }
    if (!std::isfinite(river_threshold)) river_threshold = 0.0f;
    (void)river_percentile;  // 旧分位参数保留读取以兼容，不再用于河道选择。
    // 清理：移除不接触水体或过短的孤立河段(channel-init 一般已连通到海/湖，此为安全网)。
    {
        std::vector<uint8_t> riv_seen(size_t(n), 0);
        for (int i : land) {
            if (RIV[i] == 0 || riv_seen[size_t(i)]) continue;
            std::vector<int> comp;
            comp.push_back(i);
            riv_seen[size_t(i)] = 1;
            bool touches_water = false;
            for (size_t qi = 0; qi < comp.size(); ++qi) {
                const int cur = comp[qi];
                for (int d = 0; d < 6; ++d) {
                    const int ni = NB[size_t(cur) * 6 + d];
                    if (ni < 0) continue;
                    if (pk_is_water_terrain(TERR[ni])) touches_water = true;
                    if (riv_seen[size_t(ni)] || RIV[ni] == 0) continue;
                    riv_seen[size_t(ni)] = 1;
                    comp.push_back(ni);
                }
            }
            if (!touches_water || int(comp.size()) < hydro_river_min_length) {
                for (int v : comp) RIV[v] = 0;
            }
        }
    }
    std::vector<int> unmark;
    for (int i : land) {
        if (RIV[i] == 0) continue;
        bool has_river_or_water = false;
        for (int d = 0; d < 6; ++d) {
            const int ni = NB[size_t(i) * 6 + d];
            if (ni >= 0 && (RIV[ni] != 0 || pk_is_water_terrain(TERR[ni]))) {
                has_river_or_water = true;
                break;
            }
        }
        if (!has_river_or_water) unmark.push_back(i);
    }
    for (int i : unmark) RIV[i] = 0;

    // [scale-fix 2026-07-30] RFLOW 归一化改用"基准等效流量" flow_eq = flow × (15000/N)。
    // 同源点汇流量 ∝ N（单位面积产流率 size-invariant × 流域格数 ∝ N）→ flow_eq 跨分辨率
    // 不变；min(≈channel-init 处流量)与 max(最大流域出口)同乘该系数，log min-max 两端不再
    // 缩放不一致（旧法大图 log 区间更宽、中流归一流量系统性偏高 → 同一条河在大图偏宽）。
    // 等效流量仍是 15000 格量级，log1p 的动态压缩特性不受影响。
    const double flow_eq_scale = river_map_reference_cells / std::max(1.0, double(n));
    float max_river_flow = 0.0f;
    for (int i = 0; i < n; ++i) {
        if (RIV[i] != 0) max_river_flow = std::max(max_river_flow, flow[size_t(i)] * float(flow_eq_scale));
    }
    const double river_threshold_eq = double(river_threshold) * flow_eq_scale;
    const double log_min_flow = std::log1p(std::max(river_threshold_eq, 0.0));
    const double log_max_flow = std::log1p(std::max(double(max_river_flow), river_threshold_eq + 0.001));
    const double inv_log_range = 1.0 / std::max(log_max_flow - log_min_flow, 0.001);
    // 生态保留旧归一标尺，视觉河宽调参不得静默改变大河、三角洲和泛滥平原阈值。
    std::vector<float> river_ecology_flow(size_t(n), 0.0f);
    int river_lake_snap_touched = 0;
    for (int i = 0; i < n; ++i) {
        if (RIV[i] == 0) continue;
        const int p = hydro_parent[size_t(i)];
        if (p >= 0 && (RIV[p] != 0 || pk_is_water_terrain(TERR[p]))) {
            RDOWN[i] = p;
        }
        // [river-hierarchy 2026-07-31] 地板 0.15→0.06、跨度 0.85→0.94：旧地板把大量
        // 近阈值支流顶到同一宽度带，再经 stamp 幂律后视觉几乎无差。压低地板后小支流
        // 真正变细，干流仍可顶到 1.0。
        const double raw_norm = (std::log1p(std::max(double(flow[size_t(i)]) * flow_eq_scale, 0.0)) - log_min_flow) * inv_log_range;
        river_ecology_flow[size_t(i)] = float(std::clamp(0.15 + raw_norm * 0.85, 0.15, 1.0));
        RFLOW_OUT[i] = float(std::clamp(0.06 + raw_norm * 0.94, 0.06, 1.0));
    }
    for (int i : land) {
        if (RIV[i] == 0) continue;
        const int cur_down = RDOWN[i];
        if (cur_down >= 0 && cur_down < n && pk_is_water_terrain(TERR[cur_down])) continue;
        int best_lake = -1;
        float best_e = std::numeric_limits<float>::infinity();
        for (int d = 0; d < 6; ++d) {
            const int ni = NB[size_t(i) * 6 + d];
            if (ni < 0 || TERR[ni] != 18) continue; // LAKE
            if (E[ni] < best_e) {
                best_e = E[ni];
                best_lake = ni;
            }
        }
        if (best_lake >= 0) {
            RDOWN[i] = best_lake;
            ++river_lake_snap_touched;
        }
    }

    // [river-confluence-snap 2026-06-26] 相邻河末端可视合并 ─────────────────────────────
    // 现象：河流线只沿"下游父边"(RDOWN)逐段 stamp(run_bake_river_sdf_pass / _bake_river_sdf)，
    // 六边形网格相邻 ≠ 会画连接线。两个直接相邻的 river cell 若不构成父子关系，中间不绘段 →
    // 渲染出"末端/起点贴边却不合并"的干缝。此处只缝合"可视悬空末端"：某 river cell 的 RDOWN<0
    // (其水文父非河/水 → trace 在它处断链)，若 1 格邻居存在 river cell 且接它不成环，就把 RDOWN
    // 接到最佳邻居(优先：其链能抵达终端水体 > 流量更大 > 高程更低)，让 trace 多画一段把两条链缝合。
    // 仅对 RDOWN<0 的悬空末端动手：不重路由已有正常下游的河格 → 不改动既有河链/流域。
    // RDOWN 仅供 SDF trace + cell.river_downstream(可视)消费；运行期汇流走 hydro_parent(HP，独立
    // 无环)，本 snap 完全不触碰运行期语义。成环检测：沿邻居 RDOWN 走 ≤64 步若回到自身则跳过；
    // 因只给原本 RDOWN<0(无出边)的 cell 添加唯一出边、且添加前已验证目标不可达自身，RDOWN 始终保持无环。
    int river_confluence_snap_touched = 0;
    {
        // 从 start 沿 RDOWN 行走：命中 target 返回 true(成环)；中途遇终端水体置 hits_water=true 返回 false。
        auto reaches = [&](int start, int target, bool &hits_water) -> bool {
            hits_water = false;
            int cur = start;
            for (int step = 0; step < 64 && cur >= 0 && cur < n; ++step) {
                if (cur == target) return true;
                if (pk_is_water_terrain(TERR[cur])) { hits_water = true; return false; }
                cur = RDOWN[cur];
            }
            return false;
        };
        for (int i : land) {
            if (RIV[i] == 0 || pk_is_water_terrain(TERR[i])) continue;
            if (RDOWN[i] >= 0) continue;  // 已有下游：保留既有河链，不重路由
            int best = -1;
            bool best_water = false;
            float best_flow = -1.0f;
            float best_e = std::numeric_limits<float>::infinity();
            for (int d = 0; d < 6; ++d) {
                const int ni = NB[size_t(i) * 6 + d];
                if (ni < 0 || RIV[ni] == 0 || pk_is_water_terrain(TERR[ni])) continue;
                bool ni_water = false;
                if (reaches(ni, i, ni_water)) continue;  // 接它会成环 → 跳过
                const bool better =
                    (best < 0) ||
                    (ni_water && !best_water) ||
                    (ni_water == best_water && RFLOW_OUT[ni] > best_flow) ||
                    (ni_water == best_water && RFLOW_OUT[ni] == best_flow && E[ni] < best_e);
                if (better) {
                    best = ni;
                    best_water = ni_water;
                    best_flow = RFLOW_OUT[ni];
                    best_e = E[ni];
                }
            }
            if (best >= 0) {
                RDOWN[i] = best;
                ++river_confluence_snap_touched;
            }
        }
    }

    // [river-incision 2026-06-25] #2b 河流切进仿真高程 E（cell 粒度）──────────────────
    // 现状：河流是独立 SDF overlay，从不进高度场 → 河岸/护岸在地形法线里完全无落差(平地上画线)。
    // 此处在河网最终化 + lake-snap 之后、河岸生态/floodplain 分类之前，沿河道下切 E + 两侧陆地邻居
    // 抬升成堤岸：① 给出河岸的宏观高程落差(coarse 法线/relief/height_tex 都看得到)；② 下切后 land_h
    // 降低 → 下游 floodplain/canyon/delta 分类自洽地在河谷成形(C 选项要的"影响分类")。下切按 RFLOW
    // 缩放(大河更深)；河道始终保持 land(>= sea_level+余量)不反转成海；堤岸抬 clamp≤1。crisp 像素级
    // 河岸由 bake 层(#2a，按 flow SDF 逐像素 V 形)叠加。base pass 已 100% C++ → 无 GDScript 镜像。
    {
        constexpr double PK_RIVER_INCISE   = 0.018;  // 河道最大下切(E 单位，× RFLOW)
        constexpr double PK_RIVER_BANK     = 0.008;  // 河岸最大抬升(堤)(E 单位，× RFLOW)
        constexpr double PK_RIVER_MIN_LAND = 0.004;  // 河道保留在 sea_level 之上的最小余量
        std::vector<float> e_bank(size_t(n), 0.0f);  // 堤岸抬升累积(读原始 RFLOW 计算，避免顺序依赖)
        const double floor_e = sea_level + PK_RIVER_MIN_LAND;
        for (int i : land) {
            if (RIV[i] == 0 || pk_is_water_terrain(TERR[i])) continue;
            const double rw = double(RFLOW_OUT[i]);
            double e = double(E[i]) - PK_RIVER_INCISE * rw;
            if (e < floor_e) e = floor_e;
            E[i] = float(e);
            const float bank = float(PK_RIVER_BANK * rw);
            for (int d = 0; d < 6; ++d) {
                const int ni = NB[size_t(i) * 6 + d];
                if (ni < 0 || RIV[ni] != 0 || pk_is_water_terrain(TERR[ni])) continue;
                if (bank > e_bank[size_t(ni)]) e_bank[size_t(ni)] = bank;  // 多河相邻取最强
            }
        }
        for (int i = 0; i < n; ++i) {
            if (e_bank[size_t(i)] <= 0.0f) continue;
            double e = double(E[i]) + double(e_bank[size_t(i)]);
            if (e > 1.0) e = 1.0;
            E[i] = float(e);
        }
    }

    // [coast-erosion 2026-06-26] #2c 水域波蚀：让水体(海/湖)像河流一样介入地形侵蚀——近岸陆地被
    // 邻接水体的波浪能量侵蚀，向"海蚀台地"下蚀(高处海崖蚀得快、渐近水线平台)。与河流下切 #2b 并列：
    // 河流沿河道切，水域沿岸线切。波能 ∝ 邻接水体的开阔/深度(深海邻居=大风区=强浪，浅滩/小湖弱) ×
    // 岸线包围度。只下蚀、clamp 在 sea_level 之上(不把陆地翻成海、不引发海岸级联);仅读邻居水体 E
    // (本 pass 不改水格)→ 顺序无关。下蚀后 land_h 降低 → 下游 floodplain/beach 分类自洽。base pass
    // 已 100% C++ → 无 GDScript 镜像。一键回退：profile coast_wave_erosion=0。
    int coast_erosion_touched = 0;
    {
        const double coast_wave_erosion = std::max(0.0, getd(profile, "coast_wave_erosion", 0.30));
        if (coast_wave_erosion > 0.0) {
            constexpr double PK_WAVE_MIN_LAND = 0.004;  // 蚀后保留在 sea_level 之上的最小余量
            constexpr double PK_LAKE_WAVE_MUL = 0.35;   // 湖泊波能(风区小)相对海洋折减
            const double floor_e = sea_level + PK_WAVE_MIN_LAND;
            const double inv_sea = 1.0 / std::max(sea_level, 0.001);
            for (int i : land) {
                if (pk_is_water_terrain(TERR[i])) continue;
                if (double(E[i]) <= floor_e) continue;  // 已贴水线的低地无可蚀
                double energy = 0.0;
                int wn = 0;
                for (int d = 0; d < 6; ++d) {
                    const int ni = NB[size_t(i) * 6 + d];
                    if (ni < 0 || !pk_is_water_terrain(TERR[ni])) continue;
                    ++wn;
                    // 深度代理：水体越深(离水线越远)风区越大、浪能越强；浅滩/海岸弱。
                    double depth_proxy = (sea_level - double(E[ni])) * inv_sea;
                    if (depth_proxy < 0.0) depth_proxy = 0.0; else if (depth_proxy > 1.0) depth_proxy = 1.0;
                    const double type_mul = (TERR[ni] == 18) ? PK_LAKE_WAVE_MUL : 1.0;  // 18=LAKE
                    energy += type_mul * (0.30 + 0.70 * depth_proxy);
                }
                if (wn == 0) continue;
                const double e_avg = energy / double(wn);
                const double coverage = double(wn) / 6.0;  // 被水包围越多蚀得越强
                double wave = e_avg * (0.45 + 0.55 * coverage);
                if (wave < 0.0) wave = 0.0; else if (wave > 1.0) wave = 1.0;
                // 海蚀台地：下蚀量 ∝ 高于水线的高度 → 高处海崖蚀得快、渐近水线成平台。
                double e = double(E[i]);
                e -= coast_wave_erosion * wave * (e - sea_level);
                if (e < floor_e) e = floor_e;
                E[i] = float(e);
                ++coast_erosion_touched;
            }
        }
    }

    int river_count = 0;
    for (int i = 0; i < n; ++i) river_count += int(RIV[i] != 0);

    int river_ecology_touched = 0;
    int river_desert_repaired = 0;
    int river_floodplain_channel_touched = 0;
    for (int i : land) {
        if (RIV[i] == 0 || pk_is_water_terrain(TERR[i])) continue;
        const uint8_t t = TERR[i];
        const double temp = gen_temp(i);
        const double lh = land_h(i);
        const float river_w = river_ecology_flow[size_t(i)];
        const bool strong_river = river_w >= 0.55f || flow[size_t(i)] >= river_threshold * 1.8f;
        const bool desert_like = (t == 7 || t == 24 || t == 25 || t == 26 || t == 30);
        const bool lowland_river = lh <= 0.18 || (strong_river && lh <= 0.28);
        const float target_m = strong_river ? 0.74f : 0.66f;
        if (M[i] < target_m) M[i] = target_m;
        if (t == 22 || t == 23 || t == 29) {
            ++river_ecology_touched;
            continue;
        }
        if (desert_like) {
            uint8_t nt = t;
            if (lowland_river) {
                nt = (temp > 0.45 && M[i] >= 0.78f) ? uint8_t(10) : uint8_t(29); // SWAMP/FLOODPLAIN
            } else if (strong_river && temp > 0.35) {
                nt = 23; // OASIS on arid upland channels
            } else if (temp > 0.30) {
                nt = 14; // STEPPE buffer around smaller arid channels
            } else {
                nt = 13; // TAIGA：寒冷河谷已有高湿地板，不应继续保持 COLD_DESERT
            }
            if (nt != t) {
                TERR[i] = nt;
                ++river_ecology_touched;
                ++river_desert_repaired;
            }
            continue;
        }
        if (pk_is_permanent_landform(t)) {
            ++river_ecology_touched;
            continue;
        }
        if (lowland_river && (t == 2 || t == 3 || t == 12 || t == 14 || t == 15)) {
            TERR[i] = 29; // FLOODPLAIN
            ++river_ecology_touched;
            ++river_floodplain_channel_touched;
            continue;
        }
        if (t == 2) {
            uint8_t nt = t;
            if (temp > 0.55) nt = strong_river ? uint8_t(11) : uint8_t(4); // JUNGLE/FOREST
            else if (temp > 0.30) nt = strong_river ? uint8_t(29) : uint8_t(3); // FLOODPLAIN/GRASSLAND
            if (nt != t) {
                TERR[i] = nt;
                ++river_ecology_touched;
            }
        }
    }

    // terrain-overhaul Phase 4：删除旧 vegetation-feedback 单向加湿棘轮 + 不一致温度
    // (纬度-only、permanent_only=false)的二次重判——它会把统一气候场重新抹湿、与 gen_temp
    // 判定打架，并是"陆地普遍过湿、沙漠消失"的元凶之一。biome 现在只在上方 redecide
    // (gen_temp + 风输送湿度)判一次，再叠 river_ecology 河岸微调，单遍联立、内陆干旱得以保留。
    (void)veg_elev_decay;
    int vegetation_feedback_touched = 0;

    // ─── 统一距水场（water-bodies systemic, dots-total-cpp）────────────────────
    // 海/湖/河流多源 BFS（lake/river 此处均已最终判定）：
    //   water_dist[i]      = 到最近水体的格距（-1 = 未达 / 远内陆，截断于 water_dist_max）
    //   water_src_kind[i]  = 最近水源类型（0=海洋性 / 1=湖 / 2=河流；255=无）
    // 海洋 source = ocean-connected 水格（OCEAN/COAST/REEF/SEA_ICE/KELP）；湖 = LAKE(18)；
    // 河流 = 所有 RIV；流量仅缩放局地增益。纯内部中间场：仅供下方气候回灌 / 水缘生态消费，
    // 不出境（架构铁律：O(n) 中间数据留 C++；M[]/TERR[] 的改动经既有导出自然下传）。
    const int   water_dist_max     = std::max(1, geti(cfg, "water_dist_max", 8));
    const float water_big_river_min = float(getd(cfg, "water_big_river_flow_min", 0.55));
    std::vector<int32_t> water_dist(size_t(n), -1);
    std::vector<uint8_t> water_src_kind(size_t(n), 255);
    std::vector<float> water_src_flow(size_t(n), 0.0f);
    int water_src_sea = 0, water_src_lake = 0, water_src_river = 0;
    {
        std::vector<int> wq;
        wq.reserve(size_t(n));
        for (int i = 0; i < n; ++i) {
            const uint8_t t = TERR[i];
            uint8_t kind = 255;
            if (t == 18) { kind = 1; ++water_src_lake; }                 // LAKE → 湖泊效应
            else if (pk_is_water_terrain(t)) { kind = 0; ++water_src_sea; } // 海洋性
            // 所有成形河道都维持窄河岸带；water_big_river_min 只控制流量加成，
            // 不再把多数支流排除在生态水源之外。
            else if (RIV[i] != 0) { kind = 2; ++water_src_river; }
            if (kind != 255) {
                water_dist[size_t(i)] = 0;
                water_src_kind[size_t(i)] = kind;
                if (kind == 2) water_src_flow[size_t(i)] = river_ecology_flow[size_t(i)];
                wq.push_back(i);
            }
        }
        for (size_t qi = 0; qi < wq.size(); ++qi) {
            const int cur = wq[qi];
            const int cd = water_dist[size_t(cur)];
            if (cd >= water_dist_max) continue;                          // 半径截断（控开销 + 仅近邻带回灌）
            for (int d = 0; d < 6; ++d) {
                const int ni = NB[size_t(cur) * 6 + d];
                if (ni < 0 || water_dist[size_t(ni)] >= 0) continue;     // 越界 / 已访问
                water_dist[size_t(ni)]     = cd + 1;
                water_src_kind[size_t(ni)] = water_src_kind[size_t(cur)];
                water_src_flow[size_t(ni)] = water_src_flow[size_t(cur)];
                wq.push_back(ni);
            }
        }
    }

    // ─── 水体气候回灌（仅新增 base 阶段不存在的湖/河项；海洋项不重做）──────────────
    // 职责收紧：海洋调温 / 沿海湿度地板 / land_continentality 由 base pass 维持，
    // 这里只补 post_base 才判定的湖泊与窄河岸湿润带。全部 floor(max)/additive 语义 +
    // 指数衰减 + water_dist_max 截断，不全局抬湿；回灌后由下方受保护的最终重判统一消费。
    // 改动写入 M[]，经既有 moisture_arr 导出自然下传给 HexCell / bake terrain-index。
    // 注：大河河道格(RIV)本身已在 river_ecology(上方)被 floor 到 0.66/0.74；这里把湿润带
    // 外扩到河道近邻的非河道陆地，与上方不冲突（仍是 floor，取较大值）。
    // [延后] 湖泊局地温度调节：TEMP[] 为只读、且 bind 后 republish 会重算温度场，
    // 在此写温度无持久收益，需要专门的 temp-adjust 通道后再做，本期只做湿度。
    int lakeshore_moist_touched = 0;
    int riparian_moist_touched = 0;
    {
        const float lake_moist_floor    = float(getd(cfg, "lake_moist_floor", 0.55));
        const float lake_moist_scale    = float(std::max(0.25, getd(cfg, "lake_moist_scale", 2.5)));
        const float river_riparian_floor= float(std::clamp(getd(cfg, "river_riparian_floor", 0.36), 0.0, 1.0));
        const float river_riparian_gain = float(getd(cfg, "river_riparian_gain", 0.12));
        const float river_riparian_scale= float(std::max(0.25, getd(cfg, "river_riparian_scale", 2.0)));
        for (int i : land) {
            const int wd = water_dist[size_t(i)];
            if (wd <= 0) continue;                                   // 0=水体自身/无效；只回灌陆地近邻带
            const uint8_t kind = water_src_kind[size_t(i)];
            if (kind == 1) {                                         // 湖滨增湿带（floor）
                const float decay = std::exp(-float(wd) / lake_moist_scale);
                const float floor_m = lake_moist_floor * decay;
                if (M[i] < floor_m) { M[i] = floor_m; ++lakeshore_moist_touched; }
            } else if (kind == 2) {                                 // 河谷 riparian 地板 + 增湿（封顶）
                if (wd > 2) continue;                               // 河岸带保持窄，不把整个流域抬湿
                const float flow_scale = std::max(0.01f, water_big_river_min);
                const float flow_strength = std::clamp(water_src_flow[size_t(i)] / flow_scale, 0.0f, 1.0f);
                if (wd == 1) {
                    const float floor_m = river_riparian_floor + 0.06f * flow_strength;
                    if (M[i] < floor_m) { M[i] = floor_m; ++riparian_moist_touched; }
                }
                const float add = river_riparian_gain * std::exp(-float(wd) / river_riparian_scale);
                if (add > 0.0f) {
                    float m = M[i] + add;
                    if (m > 1.0f) m = 1.0f;
                    if (m > M[i]) { M[i] = m; ++riparian_moist_touched; }
                }
            }
            // kind==0（海洋性）：base pass 已处理，这里不动，避免双重计算。
        }
    }

    // 所有静态水分驱动完成后，用同一 gen_temp + 分类器做唯一一次最终气候重判。
    // 河道和特征地形保留给专用覆盖 pass，避免恢复旧 vegetation-feedback 正反馈或抹掉绿洲/河漫滩。
    int final_climate_redecide_evaluated = 0;
    int final_climate_redecide_touched = 0;
    for (int i : land) {
        const uint8_t t = TERR[i];
        if (RIV[i] != 0 || pk_is_water_terrain(t) || pk_is_permanent_landform(t)) continue;
        if (t == 6 || t == 9 || t == 8) continue; // MOUNTAIN/SNOW/TUNDRA 保持生成期稳定边界
        ++final_climate_redecide_evaluated;
        const uint8_t nt = pk_decide_terrain_ex(double(E[i]), gen_temp(i),
                                                double(M[i]), sea_level, true);
        if (pk_is_water_terrain(nt)) continue; // 排干的 below-sea 陆地不得重新变回水体
        if (nt != t) {
            TERR[i] = nt;
            ++final_climate_redecide_touched;
        }
    }

    int shrubland_touched = 0;
    for (int i : land) {
        const uint8_t t = TERR[i];
        if (pk_is_water_terrain(t)) continue;
        if (!(t == 3 || t == 14 || t == 12 || t == 2)) continue;
        if (pk_is_permanent_landform(t)) continue;
        const double lh = land_h(i);
        if (lh > 0.45) continue;
        const double temp = gen_temp(i);
        // [climate-zone-fix P1] 限制为真·暖温带地中海生态位：加温度上限(0.58)排除热带/亚热带
        // 沿海格（原仅 temp>=0.42 无上限→把任意暖区沿海中湿格刷成 MEDIT，占陆地 21%、远超
        // 真地中海气候 ~6%），并收窄湿度上沿（地中海半干 moist≈0.35）。
        if (temp < 0.42 || temp > 0.58) continue;
        if (M[i] < 0.20f || M[i] > 0.44f) continue;
        bool has_sea = false;
        const int dd = dist_ocean[size_t(i)];
        if (dd >= 0 && dd <= 4) has_sea = true;
        for (int d = 0; d < 6; ++d) {
            const int ni = NB[size_t(i) * 6 + d];
            if (ni >= 0 && (TERR[ni] == 0 || TERR[ni] == 1)) { has_sea = true; break; }
        }
        if (has_sea) {
            TERR[i] = 15;
            ++shrubland_touched;
        }
    }

    int mangrove_touched = 0;
    for (int i : land) {
        const uint8_t t = TERR[i];
        if (pk_is_water_terrain(t)) continue;
        if (t == 6 || t == 9 || t == 8 || t == 10) continue;
        if (pk_is_permanent_landform(t)) continue;
        if (land_h(i) > 0.08) continue;
        const double temp = gen_temp(i);
        if (temp < 0.60) continue;
        bool coast_nb = false;
        bool swamp_nb = false;
        for (int d = 0; d < 6; ++d) {
            const int ni = NB[size_t(i) * 6 + d];
            if (ni < 0) continue;
            if (TERR[ni] == 1) coast_nb = true;
            else if (TERR[ni] == 10) swamp_nb = true;
        }
        if (coast_nb && (RIV[i] != 0 || swamp_nb || M[i] >= 0.70f)) {
            TERR[i] = 16;
            ++mangrove_touched;
        }
    }

    int glacier_touched = 0;
    for (int i : land) {
        const uint8_t t = TERR[i];
        if (!(t == 9 || t == 8)) continue;
        const double temp = gen_temp(i);
        if (temp >= 0.05) continue;
        bool coastal = false;
        if (land_h(i) < 0.20) {
            for (int d = 0; d < 6; ++d) {
                const int ni = NB[size_t(i) * 6 + d];
                if (ni >= 0 && (TERR[ni] == 0 || TERR[ni] == 1 || TERR[ni] == 20)) {
                    coastal = true;
                    break;
                }
            }
        }
        if (coastal || land_h(i) > 0.65) {
            TERR[i] = 17;
            ++glacier_touched;
        }
    }

    int swamp_touched = 0;
    const int swamp_water_band = std::max(0, geti(cfg, "swamp_water_band", 2));
    for (int i : land) {
        const uint8_t t = TERR[i];
        if (pk_is_water_terrain(t) || t == 6 || t == 9 || t == 8) continue;
        if (pk_is_permanent_landform(t)) continue;
        if (land_h(i) > 0.10 || M[i] < 0.75f) continue;
        const double temp = pk_clamp01(pk_lat_temp_bell((row_norm(i) - 0.5) * 2.0) - pk_alt_penalty(E[i], sea_level));
        if (temp < 0.30) continue;
        bool has_water = (RIV[i] != 0);
        if (!has_water) {
            for (int d = 0; d < 6; ++d) {
                const int ni = NB[size_t(i) * 6 + d];
                if (ni >= 0 && pk_is_water_terrain(TERR[ni])) { has_water = true; break; }
            }
        }
        // [water-bodies] 统一距水场：湖/大河近邻带(不止 1 格邻接)也算"近水"，让湿地沿
        // 湖滨/河谷成有宽度的连续带（与上方湿度回灌同源、graded）。高 M(0.75)+低地+暖温
        // 三道既有闸门仍在，故不会因放宽近水判定而泛滥。
        if (!has_water && swamp_water_band > 0) {
            const int wd = water_dist[size_t(i)];
            const uint8_t wk = water_src_kind[size_t(i)];
            if (wd > 0 && wd <= swamp_water_band && (wk == 1 || wk == 2)) has_water = true;
        }
        if (has_water) {
            TERR[i] = 10;
            ++swamp_touched;
        }
    }

    // 火山候选：镜像 _apply_volcano_pass —— 行主序（cell 索引升序）遍历 MOUNTAIN 且
    // land_h>=阈值，再用 Godot RandomNumberGenerator(seed+7717) Fisher-Yates 洗牌
    // （与 GDScript 逐位同源，不能用 xorshift 替代，否则洗牌序列不一致）。
    // 注意：必须用 0..n 索引序，不能用 `land`——`land` 已被 flow-accumulation 按高程
    // 降序排过序（见上方 std::sort），而 GDScript `_apply_volcano_pass` 遍历的
    // `map.all_cells()` = _cells.values() 是 set_cell 的 row-major 插入序。两者顺序
    // 不一致会让洗牌前的候选数组次序错位，导致火山落点分歧（parity FAIL）。
    std::vector<int> volcano_candidates;
    for (int i = 0; i < n; ++i) {
        if (TERR[i] != 6) continue;
        if (geomorph_h(i) < volcano_min_land_h) continue;
        volcano_candidates.push_back(i);
    }
    Ref<RandomNumberGenerator> volc_rng;  volc_rng.instantiate();
    if (volc_rng.is_valid()) {
        volc_rng->set_seed(uint64_t(seed + 7717));
        for (int i = int(volcano_candidates.size()) - 1; i > 0; --i) {
            const int j = volc_rng->randi_range(0, i);
            std::swap(volcano_candidates[size_t(i)], volcano_candidates[size_t(j)]);
        }
    }
    std::vector<int> volcano_placed;
    for (int cand : volcano_candidates) {
        if (int(volcano_placed.size()) >= max_volcanoes) break;
        bool ok = true;
        for (int p : volcano_placed) {
            if (cube_distance(cand, p) < volcano_min_dist) { ok = false; break; }
        }
        if (!ok) continue;
        VOLC[cand] = 1;
        LF[cand] = 12;   // VOLCANO
        BLF[cand] = 12;
        volcano_placed.push_back(cand);

        // [volcano-crater 2026-06-25] 生成期把火山塑成环形山高度场：中心 cell 下凹成火山口(caldera)，
        // 第一环 6 邻居抬升成环形山脊(rim)。map_baker 的 barycentric 高度插值(self+2 邻居)会把这组
        // per-cell 高差平滑烘进 height_tex，靠 hillshade 自然成形——取代旧 shader 的密集橙点。
        // 幅度以归一化高程(0..1)计；volcano_min_dist 默认 6 → 不同火山的环脊邻域不会重叠。
        E[cand] = float(pk_clamp01(double(E[cand]) - volcano_crater_depth));
        for (int d = 0; d < 6; ++d) {
            const int ni = NB[size_t(cand) * 6 + d];
            if (ni < 0) continue;
            if (pk_is_water_terrain(TERR[ni])) continue;   // 不抬海/湖/海岸，避免环山探进水里
            if (VOLC[ni]) continue;                         // 邻居自身是火山则不二次抬升
            // 方位抖动破除完美圆环 artifact（确定性 hash，无 RNG → 不影响落点 parity）。
            const double hv = std::sin(double(cand) * 12.9898 + double(d) * 78.233) * 43758.5453;
            const double jitter = 0.80 + 0.40 * (hv - std::floor(hv));
            E[ni] = float(pk_clamp01(double(E[ni]) + volcano_rim_height * jitter));
        }
    }

    int delta_touched = 0;
    for (int i : land) {
        if (pk_is_water_terrain(TERR[i]) || RIV[i] == 0 || pk_is_permanent_landform(TERR[i])) continue;
        if (land_h(i) > 0.20) continue;
        if (river_ecology_flow[size_t(i)] < 0.35f) continue;
        bool ocean_nb = false;
        bool coast_nb = false;
        for (int d = 0; d < 6; ++d) {
            const int ni = NB[size_t(i) * 6 + d];
            if (ni >= 0 && (TERR[ni] == 0 || TERR[ni] == 1)) { ocean_nb = true; coast_nb = TERR[ni] == 1; break; }
        }
        if (ocean_nb && (coast_nb || river_ecology_flow[size_t(i)] >= 0.55f)) {
            TERR[i] = 22;
            if (M[i] < 0.78f) M[i] = 0.78f;
            ++delta_touched;
        }
    }

    int oasis_touched = 0;
    for (int i : land) {
        const uint8_t t = TERR[i];
        if (pk_is_water_terrain(t) || pk_is_permanent_landform(t)) continue;
        // 回归修复(2026-06-18)：绿洲仅在真正的暖沙漠(DESERT)中生成，避免对任意干暖陆地
        // 滥铺(此前 698 格/5.5%)。寒漠/草原/灌丛不结绿洲。
        if (t != 7) continue;
        if (BM[i] > 0.38f && M[i] > 0.45f) continue;
        if (gen_temp(i) < 0.40) continue;
        bool has_water = (RIV[i] != 0);
        if (!has_water) {
            for (int d = 0; d < 6; ++d) {
                const int ni = NB[size_t(i) * 6 + d];
                if (ni >= 0 && TERR[ni] == 18) { has_water = true; break; }
            }
        }
        if (has_water) {
            if (M[i] < 0.55f) M[i] = 0.55f;
            TERR[i] = 23;
            ++oasis_touched;
        }
    }

    // terrain-overhaul Phase 5：盐滩收紧——仅真正内陆(距海 ≥ salt_flat_min_dist)的内流盆地
    // 底部(局部洼地)才结盐，消除沿海/坡地"错位盐滩" artifact。
    const int salt_flat_min_dist = std::max(0, geti(profile, "salt_flat_min_dist_ocean", 4));
    int salt_flat_touched = 0;
    for (int i : land) {
        if (TERR[i] != 7 && TERR[i] != 26) continue;
        if (land_h(i) > 0.18) continue;
        const int dd = dist_ocean[size_t(i)];
        if (dd >= 0 && dd < salt_flat_min_dist) continue; // 离海太近 → 非内流盐碱
        bool endorheic = (RIV[i] == 0);
        float min_nb = E[i];
        for (int d = 0; d < 6; ++d) {
            const int ni = NB[size_t(i) * 6 + d];
            if (ni < 0) continue;
            min_nb = std::min(min_nb, E[ni]);
            if (endorheic && (RIV[ni] != 0 || pk_is_water_terrain(TERR[ni]))) endorheic = false;
        }
        // 必须位于盆地底部（≤ 最低邻居 + 微容差），避免坡面误判。
        const bool basin_floor = (double(E[i]) <= double(min_nb) + 0.02);
        if (endorheic && basin_floor) {
            TERR[i] = 24;
            ++salt_flat_touched;
        }
    }

    int badlands_touched = 0;
    int badlands_candidate_count = 0;
    int badlands_candidate_components = 0;
    int badlands_budget_rejected = 0;
    int badlands_largest_component = 0;
    int badlands_budget = 0;
    int mesa_touched = 0;
    int arid_source_count = 0;
    for (int i : land) {
        if (TERR[i] == 7 || TERR[i] == 24 || TERR[i] == 26) ++arid_source_count;
    }

    std::vector<uint8_t> badlands_candidate_mask(size_t(n), 0);
    std::vector<double> badlands_score(size_t(n), 0.0);
    for (int i : land) {
        if (TERR[i] != 7 && TERR[i] != 26) continue;
        float min_e = E[i];
        float max_e = E[i];
        float max_nb = -1.0e9f;
        bool water_nb = false;
        int rugged_neighbors = 0;
        for (int d = 0; d < 6; ++d) {
            const int ni = NB[size_t(i) * 6 + d];
            if (ni < 0) continue;
            min_e = std::min(min_e, E[ni]);
            max_e = std::max(max_e, E[ni]);
            max_nb = std::max(max_nb, E[ni]);
            if (pk_is_water_terrain(TERR[ni]) || RIV[ni] != 0) water_nb = true;
            if (std::abs(double(E[ni]) - double(E[i])) >= badlands_min_relief * 0.35) {
                ++rugged_neighbors;
            }
        }
        // 荒原/方山是干旱侵蚀地貌，不应占用河道或紧贴海、湖、河岸。
        if (water_nb || RIV[i] != 0) continue;
        const double relief = double(max_e) - double(min_e);
        if (relief < badlands_min_relief) continue;
        // 方山(MESA)：高差地貌中本格为局部高点(平顶台地)且海拔够高；
        // 否则为侵蚀沟壑恶地(BADLANDS)。
        const bool flat_top = (double(E[i]) >= double(max_nb) - 0.004) && (geomorph_h(i) > 0.18);
        if (flat_top) {
            TERR[i] = 30; // MESA
            ++mesa_touched;
            continue;
        }
        if (rugged_neighbors < badlands_min_rugged_neighbors) continue;
        badlands_candidate_mask[size_t(i)] = 1;
        badlands_score[size_t(i)] = relief * 3.0
                + (1.0 - double(M[i])) * 0.15
                + double(rugged_neighbors) * 0.02;
        ++badlands_candidate_count;
    }

    // 荒原是沙漠中的局地侵蚀斑块，而不是所有崎岖沙漠的默认分类。候选区按
    // 连通分量处理，从最高分格向邻格生长；默认让候选区自身决定斑块大小，
    // 只有显式配置安全阀时才按总量/斑块格数截断。
    struct BadlandsComponent {
        std::vector<int> cells;
        int seed = -1;
        double best_score = -1.0;
    };
    std::vector<uint8_t> badlands_seen(size_t(n), 0);
    std::vector<BadlandsComponent> badlands_components;
    for (int i : land) {
        if (!badlands_candidate_mask[size_t(i)] || badlands_seen[size_t(i)]) continue;
        BadlandsComponent comp;
        comp.cells.push_back(i);
        badlands_seen[size_t(i)] = 1;
        for (size_t qi = 0; qi < comp.cells.size(); ++qi) {
            const int cur = comp.cells[qi];
            const double score = badlands_score[size_t(cur)];
            if (score > comp.best_score || (score == comp.best_score && cur < comp.seed)) {
                comp.best_score = score;
                comp.seed = cur;
            }
            for (int d = 0; d < 6; ++d) {
                const int ni = NB[size_t(cur) * 6 + d];
                if (ni < 0 || badlands_seen[size_t(ni)]
                        || !badlands_candidate_mask[size_t(ni)]) continue;
                badlands_seen[size_t(ni)] = 1;
                comp.cells.push_back(ni);
            }
        }
        badlands_components.push_back(std::move(comp));
    }
    badlands_candidate_components = int(badlands_components.size());
    std::sort(badlands_components.begin(), badlands_components.end(),
            [](const BadlandsComponent &a, const BadlandsComponent &b) {
                if (a.best_score == b.best_score) return a.seed < b.seed;
                return a.best_score > b.best_score;
            });

    const int land_budget = int(std::floor(double(land.size()) * badlands_max_land_ratio));
    const int arid_budget = int(std::floor(double(arid_source_count) * badlands_max_arid_ratio));
    badlands_budget = std::max(0, std::min(land_budget, arid_budget));
    std::vector<uint8_t> badlands_selected(size_t(n), 0);
    std::vector<uint8_t> badlands_queued(size_t(n), 0);
    for (const BadlandsComponent &comp : badlands_components) {
        if (badlands_touched >= badlands_budget) break;
        int patch_quota = std::min(int(comp.cells.size()), badlands_budget - badlands_touched);
        if (badlands_max_patch_cells > 0) {
            patch_quota = std::min(patch_quota, badlands_max_patch_cells);
        }
        if (patch_quota <= 0 || comp.seed < 0) continue;

        std::priority_queue<std::pair<double, int>> frontier;
        frontier.push({badlands_score[size_t(comp.seed)], -comp.seed});
        badlands_queued[size_t(comp.seed)] = 1;
        int patch_size = 0;
        while (!frontier.empty() && patch_size < patch_quota) {
            const int cur = -frontier.top().second;
            frontier.pop();
            if (badlands_selected[size_t(cur)]) continue;
            badlands_selected[size_t(cur)] = 1;
            TERR[cur] = 25; // BADLANDS
            ++patch_size;
            ++badlands_touched;
            for (int d = 0; d < 6; ++d) {
                const int ni = NB[size_t(cur) * 6 + d];
                if (ni < 0 || badlands_queued[size_t(ni)]
                        || !badlands_candidate_mask[size_t(ni)]) continue;
                badlands_queued[size_t(ni)] = 1;
                frontier.push({badlands_score[size_t(ni)], -ni});
            }
        }
        badlands_largest_component = std::max(badlands_largest_component, patch_size);
    }
    badlands_budget_rejected = badlands_candidate_count - badlands_touched;

    // ── terrain-overhaul 新增地形特征 pass（均仅作用于陆地，在水体清理之前）──
    // 泛滥平原(FLOODPLAIN)：紧邻河道的低海拔非干旱陆地 → 周期性泛滥的肥沃冲积带。
    int floodplain_touched = 0;
    for (int i : land) {
        const uint8_t t = TERR[i];
        if (pk_is_water_terrain(t) || pk_is_permanent_landform(t)) continue;
        if (t == 30) continue;            // 方山已定型
        if (RIV[i] != 0) continue;        // 河道本身前面已按流量定型
        if (land_h(i) > 0.18) continue;   // 低地/河漫滩
        if (M[i] < 0.34f) continue;       // 干旱区只有紧贴大河才形成泛滥平原
        bool river_nb = false;
        bool strong_river_nb = false;
        for (int d = 0; d < 6; ++d) {
            const int ni = NB[size_t(i) * 6 + d];
            if (ni >= 0 && RIV[ni] != 0) {
                river_nb = true;
                if (river_ecology_flow[size_t(ni)] >= 0.45f) strong_river_nb = true;
            }
        }
        if (river_nb && (strong_river_nb || M[i] >= 0.52f)) {
            TERR[i] = 29; // FLOODPLAIN
            if (M[i] < 0.62f) M[i] = 0.62f;
            ++floodplain_touched;
        }
    }

    // 泥炭湿原(MOOR)：凉冷 + 极湿 + 排水不畅(低坡)的非高山陆地 → 酸性泥炭湿原。
    int moor_touched = 0;
    for (int i : land) {
        const uint8_t t = TERR[i];
        if (pk_is_water_terrain(t) || pk_is_permanent_landform(t)) continue;
        if (t == 9 || t == 17 || t == 8 || t == 10 || t == 29) continue; // 雪/冰/冻原/沼泽/泛滥平原跳过
        const double gt = gen_temp(i);
        if (gt < 0.14 || gt > 0.50) continue; // 凉冷带
        if (M[i] < 0.62f) continue;            // 高湿
        if (land_h(i) > 0.55) continue;        // 非高山
        float min_e = E[i], max_e = E[i];
        for (int d = 0; d < 6; ++d) {
            const int ni = NB[size_t(i) * 6 + d];
            if (ni < 0) continue;
            min_e = std::min(min_e, E[ni]);
            max_e = std::max(max_e, E[ni]);
        }
        if ((max_e - min_e) > 0.035f) continue; // 坡陡→不积水
        TERR[i] = 28; // MOOR
        ++moor_touched;
    }

    // 硬叶灌丛(CHAPARRAL)：暖温带 + 中等偏旱 + 近海(地中海式干夏)。
    const int chaparral_max_dist = std::max(1, geti(profile, "chaparral_max_dist_ocean", 4));
    int chaparral_touched = 0;
    for (int i : land) {
        const uint8_t t = TERR[i];
        if (t != 3 && t != 14 && t != 15) continue; // 仅从草/灌过渡带转化
        const int dd = dist_ocean[size_t(i)];
        if (dd < 0 || dd > chaparral_max_dist) continue; // 仅近海
        const double gt = gen_temp(i);
        // [climate-zone-fix P1] 温度上限 0.62→0.58 排除亚热带，与 shrubland 对齐地中海生态位；
        // 湿度上沿 0.50→0.46 收窄到地中海半干区间。
        if (gt < 0.42 || gt > 0.58) continue;  // 暖温带
        if (M[i] < 0.20f || M[i] > 0.46f) continue; // 中等偏旱
        if (land_h(i) > 0.55) continue;
        TERR[i] = 27; // CHAPARRAL
        ++chaparral_touched;
    }

    int reef_touched = 0;
    int kelp_touched = 0;
    int pelagic_touched = 0;
    for (int i = 0; i < n; ++i) {
        const uint8_t t = TERR[i];
        if (t != 0 && t != 1) continue;
        const double temp = pk_compute_temperature(row_norm(i), E[i], sea_level);
        bool has_land_neighbor = false;
        bool has_river_outlet_neighbor = false;
        bool has_water_neighbor = false;
        for (int d = 0; d < 6; ++d) {
            const int ni = NB[size_t(i) * 6 + d];
            if (ni < 0) continue;
            if (pk_is_water_terrain(TERR[ni])) {
                has_water_neighbor = true;
            } else {
                has_land_neighbor = true;
                if (RIV[ni] != 0) has_river_outlet_neighbor = true;
            }
        }
        const float up = (ocean_enabled && UP != nullptr) ? UP[i] : 0.0f;
        const double widen = (has_land_neighbor && up > 0.4f) ? 0.08 : 0.0;
        // 必须同时邻接陆地与开放水域（真实海岸线），否则内陆孤立水格不得升级为礁/藻林。
        if (has_land_neighbor && has_water_neighbor) {
            if (temp > (0.60 - widen) && !has_river_outlet_neighbor && t == 1) {
                TERR[i] = 19;
                ++reef_touched;
                continue;
            }
            if (temp >= (0.30 - widen) && temp <= (0.55 + widen) && t == 1) {
                TERR[i] = 21;
                ++kelp_touched;
                continue;
            }
        }
        if (ocean_enabled && !has_land_neighbor && t == 0 && up > 0.6f) {
            COV[i] = 6;
            ++pelagic_touched;
        }
    }

    // ── 最终孤立水体清理（修复"大陆内部单格海洋"）──────────────────────────
    // 根因：connected[] 在湖泊/排水改写地形后变 stale，孤立残留的 OCEAN/COAST 又被
    // 升级成 REEF/KELP。这里在所有地形改写之后、最终轴派生之前，按当前地形重算一次
    // 海洋连通性：从地图边缘的水格 BFS。任何未连通主海洋的水体——达到湖泊最小面积者
    // 视作内陆湖(LAKE)，否则排干回收为陆地(reclassify_drained_land)。这样单格/碎小海洋
    // 不再出现在大陆内部，同时合法内陆湖/内海得以保留。
    int isolated_water_drained = 0;
    int isolated_water_to_lake = 0;
    {
        std::vector<uint8_t> ocean_conn(size_t(n), 0);
        std::vector<int> bfs;
        bfs.reserve(size_t(n));
        for (int i = 0; i < n; ++i) {
            if (!pk_is_water_terrain(TERR[i])) continue;
            // [cylindrical-earth-daylight] 仅南北极(row)作海洋种子；东西经度环绕由 NB 处理。
            const int row = R[i];
            if (row == 0 || row == height - 1) {
                ocean_conn[size_t(i)] = 1;
                bfs.push_back(i);
            }
        }
        for (size_t bi = 0; bi < bfs.size(); ++bi) {
            const int cur = bfs[bi];
            for (int d = 0; d < 6; ++d) {
                const int ni = NB[size_t(cur) * 6 + d];
                if (ni < 0 || ocean_conn[size_t(ni)]) continue;
                if (!pk_is_water_terrain(TERR[ni])) continue;
                ocean_conn[size_t(ni)] = 1;
                bfs.push_back(ni);
            }
        }
        // 安全阀：地图边缘必须存在主海洋；否则(全封闭水世界)跳过清理，避免误排干整片海。
        if (!bfs.empty()) {
            std::vector<uint8_t> visited_cl(size_t(n), 0);
            std::vector<int> comp_cl;
            comp_cl.reserve(256);
            for (int i = 0; i < n; ++i) {
                if (!pk_is_water_terrain(TERR[i]) || ocean_conn[size_t(i)] || visited_cl[size_t(i)]) continue;
                comp_cl.clear();
                comp_cl.push_back(i);
                visited_cl[size_t(i)] = 1;
                for (size_t qi = 0; qi < comp_cl.size(); ++qi) {
                    const int cur = comp_cl[qi];
                    for (int d = 0; d < 6; ++d) {
                        const int ni = NB[size_t(cur) * 6 + d];
                        if (ni < 0 || visited_cl[size_t(ni)]) continue;
                        if (!pk_is_water_terrain(TERR[ni]) || ocean_conn[size_t(ni)]) continue;
                        visited_cl[size_t(ni)] = 1;
                        comp_cl.push_back(ni);
                    }
                }
                const bool keep_as_lake = int(comp_cl.size()) >= hydro_lake_min_cells;
                for (int v : comp_cl) {
                    if (keep_as_lake) {
                        TERR[v] = 18; // LAKE
                        ++isolated_water_to_lake;
                    } else {
                        reclassify_drained_land(v);
                        ++isolated_water_drained;
                    }
                }
            }
            for (int i = 0; i < n; ++i) {
                IW[i] = pk_is_water_terrain(TERR[i]) ? uint8_t(1) : uint8_t(0);
            }
        }
    }



    // ── [water-depth-tex 2026-06-26] 统一水深信号 water_depth01 ∈ [0,1]（海/湖共用一张 R8 图）──────
    // 取代 shader 端"海洋 5×5 height 邻域 + 湖泊 16× biome-atlas 多半径"两套深浅估算：C++ 在此算好
    // 每格归一水深，bake 经 pixel_to_cell_index 扇出成 R8 water_depth_tex，shader 每水像素仅 1 次采样。
    // 海洋/海岸/礁/海草/海冰用 1-E/sea_level（E 已含洋底距岸 BFS 梯度）；湖泊用下方 bathymetry 的碗形
    // ramp × 湖体尺寸因子（小塘浅、大湖深）；非水格 0（shader 仅水像素读）。
    PackedFloat32Array water_depth_arr;
    water_depth_arr.resize(n);
    float * const WDEPTH = water_depth_arr.ptrw();
    for (int i = 0; i < n; ++i) WDEPTH[i] = 0.0f;

    // ── [lake-bathymetry 2026-06-26] 湖泊水下深度场（湖岸浅→湖心深，对标海洋距岸 BFS）──────────
    // 根因：海洋洋底由 base pass 两段距岸 BFS（§2.55 + water-tuning）刻出"大陆架→坡→深渊"的真实
    // 高程梯度，而湖泊只在 post_base 被打 TERR=18 标志、湖底高程仍是洼地填充后的近似平面 → 渲染端
    // 只能用 shader 邻域代理(compute_lake_shore_proxy)凑深浅，大湖中央一片均一（用户反馈"湖泊没有
    // 像海洋那样的深度/海拔变化"）。这里在所有 LAKE 最终确定后、sync_axes 之前，对每个湖泊连通域：
    // 从湖岸向湖心做多源 BFS 得每格离岸 hex 距离，按距离把湖底高程压向"以该湖水面(hydro_fill)为
    // 深度=0 基准的碗形梯度"。仅下切(min)、绝不抬升 → 不会把水翻到陆上；TERR 不改 → LAKE 分类/
    // landform 不受影响（pk_derive_landform 对 terrain==18 恒返回 LAKE）。湖深随湖体半径自适应（大湖
    // 更深）并叠低频噪声造湖底起伏。下游：HexCell.elevation→height 纹理→shader lake_bathy / relief /
    // hillshade 全部拿到真实湖盆深度。一键回退：profile lake_bathymetry_scale=0。
    {
        constexpr double PK_LAKE_SHELF_CELLS = 1.5;   // 近岸浅滩宽度(hex)：绝对离岸距离，不按湖半径归一
        constexpr double PK_LAKE_DEEP_CELLS  = 7.0;    // 到此离岸距离(hex)达满深 → 大湖内部整体判深水（关键修复）
        constexpr double PK_LAKE_MIN_DEPTH      = 0.050; // 物理碗形最小中心下切（height 单位）
        constexpr double PK_LAKE_MAX_DEPTH      = 0.240; // 物理下切上限（防穿到极端低高程）
        constexpr double PK_LAKE_BASIN_AMP      = 0.18;  // 湖底低频起伏幅度（×深度，仅深区生效）
        const double lake_bathy_scale = getd(profile, "lake_bathymetry_scale", 1.0); // 0=关闭

        if (lake_bathy_scale > 1e-4) {
            // 湖底起伏噪声（确定性，按 seed）：让湖盆不是完美碗形，出现水下浅丘/深潭。
            Ref<FastNoiseLite> lake_floor_noise;  lake_floor_noise.instantiate();
            if (lake_floor_noise.is_valid()) {
                lake_floor_noise->set_noise_type(FastNoiseLite::TYPE_SIMPLEX_SMOOTH);
                lake_floor_noise->set_seed(seed + 7757);
                lake_floor_noise->set_frequency(0.06);
                lake_floor_noise->set_fractal_type(FastNoiseLite::FRACTAL_FBM);
                lake_floor_noise->set_fractal_octaves(3);
            }
            std::vector<uint8_t> lb_seen(size_t(n), 0);
            std::vector<int32_t> sdist(size_t(n), -1);   // 离岸 hex 距离（仅湖内有效，逐域复位）
            std::vector<int> comp;  comp.reserve(256);
            std::vector<int> bfs;   bfs.reserve(256);
            int lake_bathy_components = 0;
            int lake_bathy_cells = 0;
            for (int s0 = 0; s0 < n; ++s0) {
                if (lb_seen[size_t(s0)] || TERR[s0] != 18) continue;
                // ① 收集该湖连通域。
                comp.clear();
                comp.push_back(s0);
                lb_seen[size_t(s0)] = 1;
                for (size_t qi = 0; qi < comp.size(); ++qi) {
                    const int cur = comp[qi];
                    for (int d = 0; d < 6; ++d) {
                        const int ni = NB[size_t(cur) * 6 + d];
                        if (ni < 0 || lb_seen[size_t(ni)] || TERR[ni] != 18) continue;
                        lb_seen[size_t(ni)] = 1;
                        comp.push_back(ni);
                    }
                }
                ++lake_bathy_components;
                // ② 多源 BFS：湖内紧邻非湖(或出界)的格 = 岸(dist=0)，向湖心逐 hex 递增。
                bfs.clear();
                for (int c : comp) {
                    bool on_shore = false;
                    for (int d = 0; d < 6; ++d) {
                        const int ni = NB[size_t(c) * 6 + d];
                        if (ni < 0 || TERR[ni] != 18) { on_shore = true; break; }
                    }
                    if (on_shore) { sdist[size_t(c)] = 0; bfs.push_back(c); }
                }
                int max_dist = 0;
                for (size_t bi = 0; bi < bfs.size(); ++bi) {
                    const int cur = bfs[bi];
                    const int cd = sdist[size_t(cur)];
                    for (int d = 0; d < 6; ++d) {
                        const int ni = NB[size_t(cur) * 6 + d];
                        if (ni < 0 || TERR[ni] != 18 || sdist[size_t(ni)] >= 0) continue;
                        sdist[size_t(ni)] = cd + 1;
                        if (cd + 1 > max_dist) max_dist = cd + 1;
                        bfs.push_back(ni);
                    }
                }
                // ③ 湖深（物理碗形下切幅度）随湖体半径自适应：小塘浅、大湖到上限。
                double depth_amp = (double(max_dist) / PK_LAKE_DEEP_CELLS) * PK_LAKE_MAX_DEPTH * lake_bathy_scale;
                if (depth_amp < PK_LAKE_MIN_DEPTH) depth_amp = PK_LAKE_MIN_DEPTH;
                if (depth_amp > PK_LAKE_MAX_DEPTH) depth_amp = PK_LAKE_MAX_DEPTH;
                const double inv_deep = 1.0 / std::max(1.0, PK_LAKE_DEEP_CELLS - PK_LAKE_SHELF_CELLS);
                // ④ 逐格压湖底：以该格水面 hydro_fill 为深度=0 基准，按归一离岸距离刻碗形（仅下切）。
                for (int c : comp) {
                    const double surface = std::isfinite(hydro_fill[size_t(c)])
                                         ? double(hydro_fill[size_t(c)])
                                         : double(E[c]);
                    // 绝对离岸距离 ramp（对标海洋 shelf→deep，不按湖半径归一 → 大湖内部整体判深水）。
                    const double sd = (sdist[size_t(c)] >= 0) ? double(sdist[size_t(c)]) : 0.0;
                    double ramp = (sd - PK_LAKE_SHELF_CELLS) * inv_deep;
                    if (ramp < 0.0) ramp = 0.0; else if (ramp > 1.0) ramp = 1.0;
                    double depth01 = pk_smoothstep(0.0, 1.0, ramp);
                    if (lake_floor_noise.is_valid() && depth01 > 0.0) {
                        // [cylindrical-earth-daylight] 经度环绕采样，接缝处湖底连续。
                        const int col = c % width;
                        const double th = PK_TWO_PI * (double(col) / double(width));
                        const double rc = double(width) / PK_TWO_PI;
                        const double bn = double(lake_floor_noise->get_noise_3d(
                            std::cos(th) * rc, std::sin(th) * rc, double(R[c])));
                        depth01 += bn * PK_LAKE_BASIN_AMP * depth01;
                        if (depth01 < 0.0) depth01 = 0.0; else if (depth01 > 1.0) depth01 = 1.0;
                    }
                    double floor_e = surface - depth01 * depth_amp;
                    if (floor_e < 0.0) floor_e = 0.0;
                    if (floor_e < double(E[c])) { E[c] = float(floor_e); ++lake_bathy_cells; }
                    // [water-depth-tex] per-cell 只存"水面高度"（湖=该湖 hydro_fill 水位）；真实逐像素
                    // 水深由 bake 用 surface - height_tex(像素) 算（见 world_ext_bake），直接吃生成的高程图。
                    WDEPTH[c] = float(surface);
                    sdist[size_t(c)] = -1; // 复位供下一连通域复用
                }
            }
            out["lake_bathymetry_components"] = lake_bathy_components;
            out["lake_bathymetry_cells_carved"] = lake_bathy_cells;
        }
    }

    // water_depth01 现承载 per-cell "水面高度"：湖泊已在上面存其 hydro_fill 水位；这里补海洋/海岸/
    // 礁/海草/海冰 = sea_level；陆地 = 0。真实逐像素水深由 bake 用 surface - height_tex 算。
    {
        for (int i = 0; i < n; ++i) {
            if (TERR[i] == 18) continue;                 // 湖：上面已存其水面
            if (!pk_is_water_terrain(TERR[i])) { WDEPTH[i] = 0.0f; continue; }  // 陆地 = 0
            WDEPTH[i] = float(sea_level);                // 海洋/海岸/礁/海草/海冰水面 = sea_level
        }
    }

    for (int i = 0; i < n; ++i) {
        sync_axes(i);
    }

    // ── 高原(PLATEAU) landform override：高海拔、低局部起伏、连通成片的陆地 ──
    // 不新增 terrain；只把三轴 landform 覆写为 PLATEAU，保留原 biome/vegetation。
    auto land_neighbor_count = [&](int i) -> int {
        int land_nb = 0;
        for (int d = 0; d < 6; ++d) {
            const int ni = NB[size_t(i) * 6 + d];
            if (ni >= 0 && !pk_is_water_terrain(TERR[ni])) ++land_nb;
        }
        return land_nb;
    };
    auto geomorph_relief = [&](int i) -> double {
        float min_e = E[i], max_e = E[i];
        for (int dq = -relief_radius; dq <= relief_radius; ++dq) {
            const int dr_lo = std::max(-relief_radius, -dq - relief_radius);
            const int dr_hi = std::min(relief_radius, -dq + relief_radius);
            for (int dr = dr_lo; dr <= dr_hi; ++dr) {
                if (dq == 0 && dr == 0) continue;
                const int ni = index_for_qr(Q[i] + dq, R[i] + dr);
                if (ni < 0 || pk_is_water_terrain(TERR[ni])) continue;
                min_e = std::min(min_e, E[ni]);
                max_e = std::max(max_e, E[ni]);
            }
        }
        return (double(max_e) - double(min_e)) * relief_radius_norm;
    };

    std::vector<uint8_t> plateau_candidate(size_t(n), 0);
    int plateau_candidate_count = 0;
    for (int i : land) {
        if (pk_is_water_terrain(TERR[i]) || VOLC[i] != 0) continue;
        if (pk_is_permanent_landform(TERR[i])) continue;
        const double lh = geomorph_h(i);
        if (lh < plateau_min_land_h || lh > 0.90) continue;
        if (land_neighbor_count(i) < 2) continue;
        const double relief = geomorph_relief(i);
        const bool broad_bench = lh >= plateau_min_land_h && relief <= plateau_max_relief;
        const bool high_bench = lh >= plateau_min_land_h + 0.10 && relief <= plateau_max_relief * 1.35;
        if (broad_bench || high_bench) {
            plateau_candidate[size_t(i)] = 1;
            ++plateau_candidate_count;
        }
    }
    int plateau_touched = 0;
    std::vector<uint8_t> plateau_seen(size_t(n), 0);
    for (int i : land) {
        if (!plateau_candidate[size_t(i)] || plateau_seen[size_t(i)]) continue;
        std::vector<int> comp;
        comp.push_back(i);
        plateau_seen[size_t(i)] = 1;
        for (size_t qi = 0; qi < comp.size(); ++qi) {
            const int cur = comp[qi];
            for (int d = 0; d < 6; ++d) {
                const int ni = NB[size_t(cur) * 6 + d];
                if (ni < 0 || plateau_seen[size_t(ni)] || !plateau_candidate[size_t(ni)]) continue;
                plateau_seen[size_t(ni)] = 1;
                comp.push_back(ni);
            }
        }
        const bool high_small_plateau = int(comp.size()) >= 2 && geomorph_h(comp[0]) >= plateau_min_land_h + 0.12;
        if (int(comp.size()) < plateau_min_cells && !high_small_plateau) continue;
        for (int v : comp) {
            LF[v] = 13;  // PLATEAU
            BLF[v] = 13;
            ++plateau_touched;
        }
    }

    // ── 山地(MOUNTAIN)瘦身：山脉应是高起伏地带，高海拔平缓面应落到 PLATEAU/HILL ──
    int mountain_demoted = 0;
    int mountain_to_plateau = 0;
    int mountain_height_candidates = 0;
    int mountain_relief_candidates = 0;
    int mountain_kept = 0;
    for (int i : land) {
        if (LF[i] != 7 || pk_is_water_terrain(TERR[i]) || VOLC[i] != 0) continue;
        if (TERR[i] == 22 || TERR[i] == 24 || TERR[i] == 25 || TERR[i] == 30) continue;
        const double lh = geomorph_h(i);
        if (land_neighbor_count(i) < 3) continue;
        const double relief = geomorph_relief(i);
        const bool summit_rugged = lh >= peak_min_land_h && relief >= mountain_min_relief * 0.65;
        const bool keep_mountain = lh >= mountain_min_land_h && (relief >= mountain_min_relief || summit_rugged);
        if (lh >= mountain_min_land_h) ++mountain_height_candidates;
        if (lh >= mountain_min_land_h && (relief >= mountain_min_relief || summit_rugged)) {
            ++mountain_relief_candidates;
        }
        if (keep_mountain) {
            ++mountain_kept;
            continue;
        }

        if (lh >= plateau_min_land_h && lh <= 0.90 && relief <= plateau_max_relief * 1.10) {
            LF[i] = 13;  // PLATEAU
            BLF[i] = 13;
            ++mountain_to_plateau;
        } else {
            LF[i] = 6;   // HILL
            BLF[i] = 6;
            ++mountain_demoted;
        }
    }

    // ── [density-fix 2026-06-30] PLATEAU 面积占比上限剪裁 ──
    // 高原此前无任何密度上限（PEAK 按 land/N 限量、RIFT 按 land/N 限量，唯独 PLATEAU 没有），
    // 导致大地图上所有满足 land_h/relief 条件的平坦中高海拔区全部标为 PLATEAU。
    // 现按连通分量面积从大到小累计，保留至 plateau_max_land_ratio × land 为止，
    // 其余较小连通分量整体降级为 HILL（保留大高原、清理碎片）。
    int plateau_demoted_to_hill = 0;
    if (plateau_max_land_ratio < 1.0) {
        std::vector<uint8_t> plat_seen(size_t(n), 0);
        std::vector<std::vector<int>> plat_comps;
        for (int i : land) {
            if (LF[i] != 13 || plat_seen[size_t(i)]) continue;
            std::vector<int> comp;
            comp.push_back(i);
            plat_seen[size_t(i)] = 1;
            for (size_t qi = 0; qi < comp.size(); ++qi) {
                const int cur = comp[qi];
                for (int d = 0; d < 6; ++d) {
                    const int ni = NB[size_t(cur) * 6 + d];
                    if (ni < 0 || plat_seen[size_t(ni)] || LF[ni] != 13) continue;
                    plat_seen[size_t(ni)] = 1;
                    comp.push_back(ni);
                }
            }
            plat_comps.push_back(std::move(comp));
        }
        std::sort(plat_comps.begin(), plat_comps.end(),
                [](const std::vector<int> &a, const std::vector<int> &b){ return a.size() > b.size(); });
        const int plateau_cap = std::max(0, int(double(land.size()) * plateau_max_land_ratio));
        int plateau_kept = 0;
        for (const auto &comp : plat_comps) {
            if (plateau_kept < plateau_cap) {
                plateau_kept += int(comp.size());
            } else {
                for (int v : comp) {
                    LF[v] = 6;   // HILL
                    BLF[v] = 6;
                    ++plateau_demoted_to_hill;
                }
            }
        }
    }

    // ── 峰顶(PEAK) landform sparsify：山脉是主体，高峰只保留局部 summit ──
    // 基础 landform helper 只能按单格海拔分段，容易把高海拔山原整片判成 PEAK。
    // 这里先退回为 MOUNTAIN，再按局部相对高度、邻域落差和最小间距选出少量真正峰顶。
    int peak_demoted = 0;
    for (int i : land) {
        if (LF[i] == 8) {
            LF[i] = 7;
            BLF[i] = 7;
            ++peak_demoted;
        }
    }
    struct PeakCandidate {
        int idx;
        double score;
    };
    std::vector<PeakCandidate> peak_candidates;
    peak_candidates.reserve(64);
    for (int i : land) {
        if (pk_is_water_terrain(TERR[i]) || VOLC[i] != 0) continue;
        if (TERR[i] == 22 || TERR[i] == 24 || TERR[i] == 25 || TERR[i] == 30) continue;
        const double lh = geomorph_h(i);
        if (lh < peak_min_land_h) continue;
        float min_nb = E[i];
        float max_nb = -1.0e9f;
        int land_nb = 0;
        int lower_prominent = 0;
        for (int d = 0; d < 6; ++d) {
            const int ni = NB[size_t(i) * 6 + d];
            if (ni < 0 || pk_is_water_terrain(TERR[ni])) continue;
            ++land_nb;
            min_nb = std::min(min_nb, E[ni]);
            max_nb = std::max(max_nb, E[ni]);
            if (double(E[i]) - double(E[ni]) >= peak_min_prominence) ++lower_prominent;
        }
        if (land_nb < 3) continue;
        const double relief = double(E[i]) - double(min_nb);
        const bool local_cap = double(E[i]) >= double(max_nb) - 0.006;
        if (!local_cap || lower_prominent < 2 || relief < peak_min_prominence) continue;
        peak_candidates.push_back({i, lh + relief * 2.0 + 0.01 * double(lower_prominent)});
    }
    std::sort(peak_candidates.begin(), peak_candidates.end(),
              [](const PeakCandidate &a, const PeakCandidate &b) {
                  if (a.score == b.score) return a.idx < b.idx;
                  return a.score > b.score;
              });
    const int peak_limit = std::max(1, int(land.size()) / peak_land_cells_per_peak);
    int peak_touched = 0;
    std::vector<int> peak_placed;
    peak_placed.reserve(size_t(peak_limit));
    for (const PeakCandidate &cand : peak_candidates) {
        if (peak_touched >= peak_limit) break;
        bool far_enough = true;
        for (int p : peak_placed) {
            if (cube_distance(cand.idx, p) < 3) { far_enough = false; break; }
        }
        if (!far_enough) continue;
        LF[cand.idx] = 8;
        BLF[cand.idx] = 8;
        peak_placed.push_back(cand.idx);
        ++peak_touched;
    }

    // ── 裂谷地貌(RIFT_VALLEY) override：两侧抬升夹住的连续线状洼地 ──
    // 局部剖面先确定两侧断崖方向，再只沿断崖之间的谷轴连接候选。裂谷是连续构造带，
    // 不使用全图数量、面积或格间距配额；最小物理长度仅过滤孤立洼点和短沟槽。
    int rift_touched = 0;
    int rift_candidate_count = 0;
    int rift_component_count = 0;
    int rift_rejected_fragment_count = 0;
    int rift_largest_component = 0;
    std::vector<uint8_t> rift_candidate(size_t(n), 0);
    std::vector<int8_t> rift_cross_axis(size_t(n), -1);
    for (int i = 0; i < n; ++i) {
        if (pk_is_water_terrain(TERR[i])) continue;
        if (LF[i] == 8 || LF[i] == 12 || LF[i] == 13) continue; // 高峰/火山/高原保留
        const double lh = geomorph_h(i);
        if (lh < 0.03 || lh > 0.72) continue;
        int higher = 0, land_nb = 0;
        double max_raise = 0.0;
        for (int d = 0; d < 6; ++d) {
            const int ni = NB[size_t(i) * 6 + d];
            if (ni < 0 || pk_is_water_terrain(TERR[ni])) continue;
            ++land_nb;
            const double raise = double(E[ni]) - double(E[i]);
            if (raise > rift_min_wall * (4.0 / 3.0)) ++higher;
            if (raise > max_raise) max_raise = raise;
        }
        if (land_nb < 3 || higher < 2 || max_raise < rift_min_wall * 1.875) continue;
        double best_axis = 0.0;
        int best_cross_axis = -1;
        for (int d = 0; d < 3; ++d) {
            const int a = NB[size_t(i) * 6 + d];
            const int b = NB[size_t(i) * 6 + ((d + 3) % 6)];
            if (a < 0 || b < 0 || pk_is_water_terrain(TERR[a]) || pk_is_water_terrain(TERR[b])) continue;
            const double ra = double(E[a]) - double(E[i]);
            const double rb = double(E[b]) - double(E[i]);
            if (ra <= rift_min_wall || rb <= rift_min_wall) continue;
            const double axis_score = std::min(ra, rb) + 0.35 * std::max(ra, rb);
            if (axis_score > best_axis) {
                best_axis = axis_score;
                best_cross_axis = d;
            }
        }
        if (best_axis < rift_min_axis || best_cross_axis < 0) continue;
        rift_candidate[size_t(i)] = 1;
        rift_cross_axis[size_t(i)] = int8_t(best_cross_axis);
        ++rift_candidate_count;
    }

    auto follows_rift_axis = [&](int cell, int dir) -> bool {
        const int cross = int(rift_cross_axis[size_t(cell)]);
        return cross >= 0 && dir != cross && dir != cross + 3;
    };
    std::vector<uint8_t> rift_seen(size_t(n), 0);
    for (int seed_cell : land) {
        if (!rift_candidate[size_t(seed_cell)] || rift_seen[size_t(seed_cell)]) continue;
        std::vector<int> component;
        component.push_back(seed_cell);
        rift_seen[size_t(seed_cell)] = 1;
        for (size_t qi = 0; qi < component.size(); ++qi) {
            const int cur = component[qi];
            for (int d = 0; d < 6; ++d) {
                const int ni = NB[size_t(cur) * 6 + d];
                if (ni < 0 || !rift_candidate[size_t(ni)] || rift_seen[size_t(ni)]) continue;
                if (!follows_rift_axis(cur, d) || !follows_rift_axis(ni, (d + 3) % 6)) continue;
                rift_seen[size_t(ni)] = 1;
                component.push_back(ni);
            }
        }
        ++rift_component_count;
        rift_largest_component = std::max(rift_largest_component, int(component.size()));

        int endpoint = component.front();
        int farthest_dist = -1;
        for (int cell : component) {
            const int dist = cube_distance(component.front(), cell);
            if (dist > farthest_dist) {
                farthest_dist = dist;
                endpoint = cell;
            }
        }
        int span_cells = 1;
        for (int cell : component) {
            span_cells = std::max(span_cells, cube_distance(endpoint, cell) + 1);
        }
        if (int(component.size()) < rift_min_length || span_cells < rift_min_length) {
            rift_rejected_fragment_count += int(component.size());
            continue;
        }
        for (int cell : component) {
            LF[cell] = 14;  // RIFT_VALLEY
            BLF[cell] = 14;
            ++rift_touched;
        }
    }

    // ── 峡谷(CANYON) override：河流深切、两壁陡立的线状侵蚀峡谷 ──
    // 与 BADLANDS(干旱软岩片状恶地)、RIFT_VALLEY(构造离散边界裂谷) 三者区分：
    //   * CANYON 必须有河道穿过(RIV != 0)，且对置两侧都有明显陡壁(河流下切成 gorge)；
    //   * 不限定干旱，湿润山区的深切河谷(如长江三峡型)也成峡谷；
    //   * 跑在 rift 之后并跳过已写入的结构性地貌，避免与裂谷/高原/高峰重复占用。
    const double canyon_min_wall = getd(profile, "canyon_min_wall", 0.05);
    const double canyon_min_axis = getd(profile, "canyon_min_axis", 0.06);
    int canyon_touched = 0;
    for (int i : land) {
        if (pk_is_water_terrain(TERR[i])) continue;
        if (RIV[i] == 0) continue;                                   // 必须有河道穿过
        if (LF[i] == 8 || LF[i] == 12 || LF[i] == 13 || LF[i] == 14) continue; // 峰/火山/高原/裂谷保留
        const double lh = geomorph_h(i);
        if (lh < 0.05 || lh > 0.85) continue;
        int land_nb = 0, higher = 0;
        double max_raise = 0.0;
        for (int d = 0; d < 6; ++d) {
            const int ni = NB[size_t(i) * 6 + d];
            if (ni < 0 || pk_is_water_terrain(TERR[ni])) continue;
            ++land_nb;
            const double raise = double(E[ni]) - double(E[i]);
            if (raise > canyon_min_wall) ++higher;
            if (raise > max_raise) max_raise = raise;
        }
        if (land_nb < 3 || higher < 2 || max_raise < canyon_min_wall) continue;
        // 对置轴：河谷两壁都明显抬升 → gorge（区别于单侧山坡上的河道）。
        double best_axis = 0.0;
        for (int d = 0; d < 3; ++d) {
            const int a = NB[size_t(i) * 6 + d];
            const int b = NB[size_t(i) * 6 + ((d + 3) % 6)];
            if (a < 0 || b < 0 || pk_is_water_terrain(TERR[a]) || pk_is_water_terrain(TERR[b])) continue;
            const double ra = double(E[a]) - double(E[i]);
            const double rb = double(E[b]) - double(E[i]);
            if (ra <= canyon_min_wall * 0.5 || rb <= canyon_min_wall * 0.5) continue;
            best_axis = std::max(best_axis, std::min(ra, rb) + 0.35 * std::max(ra, rb));
        }
        if (best_axis < canyon_min_axis) continue;
        LF[i] = 15;  // CANYON
        BLF[i] = 15;
        ++canyon_touched;
    }

    const PackedFloat32Array ideal_t_arr = profile.get("veg_ideal_temp", PackedFloat32Array());
    const PackedFloat32Array ideal_m_arr = profile.get("veg_ideal_moist", PackedFloat32Array());
    const PackedFloat32Array tol_t_arr = profile.get("veg_temp_tol", PackedFloat32Array());
    const PackedFloat32Array tol_m_arr = profile.get("veg_moist_tol", PackedFloat32Array());
    const bool have_veg_profiles = ideal_t_arr.size() >= 28 && ideal_m_arr.size() >= 28 &&
                                   tol_t_arr.size() >= 28 && tol_m_arr.size() >= 28;
    const float min_suitability = float(std::clamp(getd(profile, "vegetation_min_suitability", 0.18), 0.0, 1.0));
    const float tie_epsilon = float(std::max(0.0, getd(profile, "vegetation_tie_epsilon", 1e-6)));
    const float water_balance_weight = float(std::max(0.01, getd(profile, "plant_water_balance_weight", 0.35)));
    const float soil_buffer_weight = float(std::max(0.01, getd(profile, "plant_soil_buffer_weight", 0.30)));
    const float drought_penalty = float(std::max(0.01, getd(profile, "plant_drought_penalty", 0.25)));
    int vegetation_candidate_count = 0;
    int vegetation_none_count = 0;
    int vegetation_biome_reconciled_count = 0;
    int plant_water_nonzero_land_count = 0;
    int river_adjacent_desert_count = 0;
    int coastal_highland_desert_count = 0;
    double vegetation_score_sum = 0.0;
    float vegetation_score_min = 1.0f;
    float vegetation_score_max = 0.0f;
    float terrain_soft_weight_min = 1.25f;
    float terrain_soft_weight_max = 0.35f;
    const auto vegetation_t0 = std::chrono::high_resolution_clock::now();

    for (int i = 0; i < n; ++i) {
        const double temp_gen = gen_temp(i);
        TEMP[i] = float(temp_gen); // The same coastal-adjusted source used by terrain.
        T30[i] = TEMP[i];
        T365[i] = TEMP[i];
        const float delta = std::clamp(M[i] - BM[i], -0.5f, 0.5f);
        float wb30 = 0.0f;
        float soil = 0.0f;
        if (delta >= 0.0f) {
            wb30 = std::clamp(delta * 0.60f / water_balance_weight, 0.0f, 0.5f);
            soil = std::clamp(delta * 0.40f / soil_buffer_weight, 0.0f, 0.5f);
        } else {
            wb30 = std::clamp(delta / drought_penalty, -0.5f, 0.0f);
        }
        const float plant_water = std::clamp(
            BM[i] + std::max(wb30, 0.0f) * water_balance_weight +
            std::max(soil, 0.0f) * soil_buffer_weight +
            std::min(wb30, 0.0f) * drought_penalty, 0.0f, 1.0f);
        WB30[i] = wb30;
        SOIL[i] = soil;
        PLANT_WATER[i] = plant_water;
        if (IW[i] == 0 && plant_water > 0.01f) ++plant_water_nonzero_land_count;

        uint8_t selected = 0;
        float best_score = 0.0f;
        float current_score = 0.0f;
        if (IW[i] != 0) {
            // Water vegetation is a physical substrate constraint.
            if (TERR[i] == 1 && temp_gen > 0.42 && temp_gen < 0.74) selected = 26; // seagrass
            else if (TERR[i] == 19) selected = 23; // coral reef
            else if (TERR[i] == 21) selected = 22; // kelp forest
        } else if (TERR[i] != 17 && TERR[i] != 24 && have_veg_profiles) {
            for (uint8_t v = 1; v < 28; ++v) {
                if (!pk_vegetation_candidate_allowed(TERR[i], v)) continue;
                const float climate = pk_vegetation_climate_score_for_type(
                    v, TEMP[i], plant_water, ideal_t_arr[v], ideal_m_arr[v], tol_t_arr[v], tol_m_arr[v]);
                const float terrain_weight = pk_vegetation_terrain_weight(TERR[i], LF[i], v, plant_water);
                terrain_soft_weight_min = std::min(terrain_soft_weight_min, terrain_weight);
                terrain_soft_weight_max = std::max(terrain_soft_weight_max, terrain_weight);
                const float score = climate * terrain_weight;
                if (score > best_score + tie_epsilon) {
                    best_score = score;
                    selected = v;
                }
            }
            if (best_score < min_suitability) selected = 0;
            ++vegetation_candidate_count;
        } else if (IW[i] == 0) {
            selected = pk_derive_vegetation(TERR[i], LF[i], TEMP[i], M[i]);
            best_score = selected == 0 ? 0.0f : 0.5f;
        }

        // Keep ecological lag for compatible transitions, but repair an
        // obviously cross-biome winner before publishing the initial state.
        if (selected != 0 && pk_vegetation_needs_biome_reconcile(TERR[i], selected)) {
            const uint8_t repaired = pk_derive_vegetation(TERR[i], LF[i], TEMP[i], M[i]);
            if (repaired != selected) {
                selected = repaired;
                ++vegetation_biome_reconciled_count;
            }
        }

        if (have_veg_profiles && selected > 0 && selected < 28) {
            best_score = pk_vegetation_climate_score_for_type(
                selected, TEMP[i], plant_water, ideal_t_arr[selected], ideal_m_arr[selected],
                tol_t_arr[selected], tol_m_arr[selected]) *
                pk_vegetation_terrain_weight(TERR[i], LF[i], selected, plant_water);
            const uint8_t previous = BVEG[i];
            if (previous > 0 && previous < 28 && previous != 22 && previous != 23 && previous != 26) {
                current_score = pk_vegetation_climate_score_for_type(
                    previous, TEMP[i], plant_water, ideal_t_arr[previous], ideal_m_arr[previous],
                    tol_t_arr[previous], tol_m_arr[previous]) *
                    pk_vegetation_terrain_weight(TERR[i], LF[i], previous, plant_water);
            }
        }
        VEG[i] = selected;
        BVEG[i] = selected;
        if (selected == 0) ++vegetation_none_count;

        if (selected > 0) {
            const float vitality = std::clamp(0.15f + 0.85f * best_score, 0.0f, 1.0f);
            VITALITY[i] = vitality;
            VREGEN[i] = std::clamp(best_score, 0.0f, 1.0f);
            VG_PRESSURE[i] = std::clamp(best_score - current_score, 0.0f, 1.0f);
            if (have_veg_profiles && selected < 28) {
                const float tt = std::max(tol_t_arr[selected], 0.05f);
                const float tm = std::max(tol_m_arr[selected], 0.05f);
                VHEAT[i] = std::clamp((TEMP[i] - ideal_t_arr[selected] - tt) / tt, 0.0f, 1.0f);
                VCOLD[i] = std::clamp((ideal_t_arr[selected] - tt - TEMP[i]) / tt, 0.0f, 1.0f);
                VDROUGHT[i] = std::clamp((ideal_m_arr[selected] - tm - plant_water) / tm, 0.0f, 1.0f);
            } else {
                VHEAT[i] = 0.0f;
                VCOLD[i] = 0.0f;
                VDROUGHT[i] = 0.0f;
            }
            vegetation_score_sum += best_score;
            vegetation_score_min = std::min(vegetation_score_min, best_score);
            vegetation_score_max = std::max(vegetation_score_max, best_score);
        } else {
            VITALITY[i] = 0.0f;
            VG_PRESSURE[i] = 0.0f;
            VHEAT[i] = 0.0f;
            VDROUGHT[i] = 0.0f;
            VCOLD[i] = 0.0f;
            VREGEN[i] = 0.0f;
        }
        if (selected == 17 && (RIV[i] != 0 || [&]() {
                for (int d = 0; d < 6; ++d) { const int ni = NB[size_t(i) * 6 + d]; if (ni >= 0 && RIV[ni] != 0) return true; }
                return false;
            }())) {
            ++river_adjacent_desert_count;
        }
        if ((LF[i] == 6 || LF[i] == 7 || LF[i] == 8 || LF[i] == 13) &&
            !dist_ocean.empty() && dist_ocean[size_t(i)] >= 0 && dist_ocean[size_t(i)] <= 2 &&
            (selected == 16 || selected == 17)) {
            ++coastal_highland_desert_count;
        }
    }
    const auto vegetation_t1 = std::chrono::high_resolution_clock::now();
    const double vegetation_native_ms =
        std::chrono::duration<double, std::milli>(vegetation_t1 - vegetation_t0).count();

    int water_count = 0;
    int volcano_count = 0;
    int desert_class_count = 0;
    int cold_desert_count = 0;
    int plateau_count = 0;
    int peak_count = 0;
    int rift_count = 0;
    int highland_river_count = 0;
    int mountain_peak_river_count = 0;
    int xeric_desert_count = 0;
    int shrubland_count = 0;
    int mangrove_count = 0;
    int moor_count = 0;
    for (int i = 0; i < n; ++i) {
        if (IW[i]) ++water_count;
        if (VOLC[i]) ++volcano_count;
        if (TERR[i] == 7 || TERR[i] == 24 || TERR[i] == 25 || TERR[i] == 30 || TERR[i] == 26) ++desert_class_count;
        if (TERR[i] == 26) ++cold_desert_count;
        if (LF[i] == 13) ++plateau_count;
        if (LF[i] == 8) ++peak_count;
        if (LF[i] == 14) ++rift_count;
        if (RIV[i] != 0 && (LF[i] == 6 || LF[i] == 7 || LF[i] == 8 || LF[i] == 13)) ++highland_river_count;
        if (RIV[i] != 0 && (LF[i] == 7 || LF[i] == 8)) ++mountain_peak_river_count;
        if (VEG[i] == 17) ++xeric_desert_count;
        if (TERR[i] == 15) ++shrubland_count;
        if (TERR[i] == 16) ++mangrove_count;
        if (TERR[i] == 28) ++moor_count;
    }

    const auto t1 = std::chrono::high_resolution_clock::now();
    const double elapsed_ms = std::chrono::duration<double, std::milli>(t1 - t0).count();

    out["rc"] = 0;
    out["status"] = String("completed");
    out["path"] = String("gdext");
    out["fallback"] = false;
    out["fallback_reason"] = String();
    out["reason"] = String();
    out["fail_stage"] = String();
    out["published_to_slot"] = false;
    out["n_cells"] = n;
    out["width"] = width;
    out["height"] = height;
    out["seed"] = seed;
    out["water_count"] = water_count;
    out["land_count"] = n - water_count;
    out["lake_count"] = lake_count;
    out["river_count"] = river_count;
    out["volcano_count"] = volcano_count;
    out["elapsed_ms"] = elapsed_ms;
    out["native_ms"] = elapsed_ms;
    out["compute_ms"] = elapsed_ms;
    out["generation_progress"] = 1.0;

    // ── QA 度量（生成诊断，无行为副作用，t1 之后计算不计入 native_ms）──
    // 连通分量分析最终水体 → 抓单格海洋；陆地低于海平面比例；biome 香农熵；河流占比。
    // 作为每阶段改造的回归基线（GDScript 端会 print 出来）。
    Dictionary qa_metrics;
    {
        std::vector<uint8_t> seen_qa(size_t(n), 0);
        std::vector<int> stack_qa;
        stack_qa.reserve(256);
        int single_water = 0;   // size == 1
        int tiny_water = 0;     // size <= 3
        int small_water = 0;    // size <= 5
        int water_bodies = 0;
        int largest_water = 0;
        for (int i = 0; i < n; ++i) {
            if (IW[i] == 0 || seen_qa[size_t(i)]) continue;
            stack_qa.clear();
            stack_qa.push_back(i);
            seen_qa[size_t(i)] = 1;
            int sz = 0;
            while (!stack_qa.empty()) {
                const int cur = stack_qa.back();
                stack_qa.pop_back();
                ++sz;
                for (int d = 0; d < 6; ++d) {
                    const int ni = NB[size_t(cur) * 6 + d];
                    if (ni >= 0 && IW[ni] != 0 && !seen_qa[size_t(ni)]) {
                        seen_qa[size_t(ni)] = 1;
                        stack_qa.push_back(ni);
                    }
                }
            }
            ++water_bodies;
            if (sz == 1) ++single_water;
            if (sz <= 3) ++tiny_water;
            if (sz <= 5) ++small_water;
            if (sz > largest_water) largest_water = sz;
        }
        int land_below_sea = 0;
        int terr_hist[64] = {0};
        for (int i = 0; i < n; ++i) {
            if (IW[i] == 0 && double(E[i]) < sea_level) ++land_below_sea;
            const uint8_t t = TERR[i];
            if (t < 64) ++terr_hist[t];
        }
        double entropy = 0.0;
        int distinct_terr = 0;
        for (int t = 0; t < 64; ++t) {
            if (terr_hist[t] <= 0) continue;
            ++distinct_terr;
            const double p = double(terr_hist[t]) / double(n);
            entropy -= p * std::log2(p);
        }
        const int land_count_qa = n - water_count;
        qa_metrics["water_bodies"] = water_bodies;
        qa_metrics["single_tile_water"] = single_water;
        qa_metrics["tiny_water_le3"] = tiny_water;
        qa_metrics["small_water_le5"] = small_water;
        qa_metrics["largest_water_body"] = largest_water;
        qa_metrics["land_below_sealevel"] = land_below_sea;
        qa_metrics["land_below_sealevel_ratio"] = (land_count_qa > 0) ? double(land_below_sea) / double(land_count_qa) : 0.0;
        qa_metrics["terrain_entropy_bits"] = entropy;
        qa_metrics["terrain_distinct"] = distinct_terr;
        qa_metrics["river_ratio"] = (n > 0) ? double(river_count) / double(n) : 0.0;
        qa_metrics["badlands_land_ratio"] = (land_count_qa > 0)
                ? double(badlands_touched) / double(land_count_qa) : 0.0;
        qa_metrics["badlands_arid_ratio"] = (arid_source_count > 0)
                ? double(badlands_touched) / double(arid_source_count) : 0.0;
        qa_metrics["badlands_largest_component"] = badlands_largest_component;
    }
    out["qa_metrics"] = qa_metrics;

    Dictionary stage_counts;
    stage_counts["rain_shadow"] = rain_shadow_touched;
    stage_counts["redecide"] = redecide_touched;
    stage_counts["final_climate_redecide"] = final_climate_redecide_touched;
    stage_counts["headwater_river"] = headwater_touched;
    stage_counts["river_lake_snap"] = river_lake_snap_touched;
    stage_counts["river_confluence_snap"] = river_confluence_snap_touched;
    stage_counts["coast_wave_erosion"] = coast_erosion_touched;
    stage_counts["river_ecology"] = river_ecology_touched;
    stage_counts["river_desert_repaired"] = river_desert_repaired;
    stage_counts["river_floodplain_channel"] = river_floodplain_channel_touched;
    stage_counts["vegetation_feedback"] = vegetation_feedback_touched;
    stage_counts["shrubland"] = shrubland_touched;
    stage_counts["mangrove"] = mangrove_touched;
    stage_counts["glacier"] = glacier_touched;
    stage_counts["swamp"] = swamp_touched;
    stage_counts["delta"] = delta_touched;
    stage_counts["oasis"] = oasis_touched;
    stage_counts["salt_flat"] = salt_flat_touched;
    stage_counts["badlands"] = badlands_touched;
    stage_counts["badlands_candidates"] = badlands_candidate_count;
    stage_counts["badlands_budget_rejected"] = badlands_budget_rejected;
    stage_counts["mesa"] = mesa_touched;
    stage_counts["floodplain"] = floodplain_touched;
    stage_counts["moor"] = moor_touched;
    stage_counts["chaparral"] = chaparral_touched;
    stage_counts["plateau"] = plateau_touched;
    stage_counts["plateau_candidates"] = plateau_candidate_count;
    stage_counts["plateau_demoted_to_hill"] = plateau_demoted_to_hill;
    stage_counts["mountain_demoted"] = mountain_demoted;
    stage_counts["mountain_to_plateau"] = mountain_to_plateau;
    stage_counts["mountain_height_candidates"] = mountain_height_candidates;
    stage_counts["mountain_relief_candidates"] = mountain_relief_candidates;
    stage_counts["mountain_kept"] = mountain_kept;
    stage_counts["peak_summit"] = peak_touched;
    stage_counts["peak_candidates"] = int(peak_candidates.size());
    stage_counts["peak_demoted"] = peak_demoted;
    stage_counts["rift_valley"] = rift_touched;
    stage_counts["canyon"] = canyon_touched;
    stage_counts["reef"] = reef_touched;
    stage_counts["kelp"] = kelp_touched;
    stage_counts["pelagic_bloom"] = pelagic_touched;
    stage_counts["isolated_water_drained"] = isolated_water_drained;
    stage_counts["isolated_water_to_lake"] = isolated_water_to_lake;
    out["stage_counts"] = stage_counts;


    out["river_map_reference_cells"] = river_map_reference_cells;
    out["river_map_scale"] = river_map_scale;
    out["river_map_scale_exponent"] = river_map_scale_exponent;
    // [scale-fix 2026-07-30] 分辨率归一诊断：验证时核对 s / relief 阈值缩放 / 等效流量系数
    out["gen_dist_scale"] = gen_dist_scale;
    out["relief_thresh_scale"] = relief_thresh_scale;
    out["relief_thresh_scale_exp"] = relief_thresh_scale_exp;
    out["mountain_min_relief_effective"] = mountain_min_relief;
    out["plateau_max_relief_effective"] = plateau_max_relief;
    out["geomorph_relief_radius"] = relief_radius;
    out["geomorph_relief_radius_norm"] = relief_radius_norm;
    out["badlands_min_relief_effective"] = badlands_min_relief;
    out["flow_eq_scale"] = flow_eq_scale;
    out["rain_shadow_lookback_effective"] = lookback;
    out["river_channel_init_base"] = river_channel_init_base;
    out["river_channel_init_effective"] = channel_init;
    out["river_headwater_init_base"] = river_headwater_init_base;
    out["river_headwater_init_effective"] = river_headwater_init;
    out["hydro_river_min_length_base"] = hydro_river_min_length_base;
    out["hydro_river_min_length_effective"] = hydro_river_min_length;
    out["river_flow_threshold"] = double(river_threshold);
    out["river_ecology_source_count"] = water_src_river;
    out["lakeshore_moist_touched"] = lakeshore_moist_touched;
    out["riparian_moist_touched"] = riparian_moist_touched;
    out["final_climate_redecide_evaluated"] = final_climate_redecide_evaluated;
    out["final_climate_redecide_touched"] = final_climate_redecide_touched;
    out["river_lake_snap_count"] = river_lake_snap_touched;
    out["river_confluence_snap_count"] = river_confluence_snap_touched;
    out["desert_class_count"] = desert_class_count;
    out["rift_candidate_count"] = rift_candidate_count;
    out["mountain_height_candidates"] = mountain_height_candidates;
    out["mountain_relief_candidates"] = mountain_relief_candidates;
    out["mountain_kept"] = mountain_kept;
    out["peak_candidate_count"] = int(peak_candidates.size());
    out["plateau_candidate_count"] = plateau_candidate_count;
    out["rift_component_count"] = rift_component_count;
    out["rift_rejected_fragment_count"] = rift_rejected_fragment_count;
    out["rift_largest_component"] = rift_largest_component;
    out["rift_min_length_effective"] = rift_min_length;
    out["badlands_arid_source_count"] = arid_source_count;
    out["badlands_candidate_count"] = badlands_candidate_count;
    out["badlands_candidate_components"] = badlands_candidate_components;
    out["badlands_selected_count"] = badlands_touched;
    out["badlands_budget"] = badlands_budget;
    out["badlands_budget_rejected"] = badlands_budget_rejected;
    out["badlands_largest_component"] = badlands_largest_component;
    out["cold_desert_count"] = cold_desert_count;
    out["plateau_count"] = plateau_count;
    out["peak_count"] = peak_count;
    out["rift_valley_count"] = rift_count;
    out["highland_river_count"] = highland_river_count;
    out["mountain_peak_river_count"] = mountain_peak_river_count;
    out["xeric_desert_count"] = xeric_desert_count;
    out["shrubland_count"] = shrubland_count;
    out["mangrove_count"] = mangrove_count;
    out["moor_count"] = moor_count;
    out["vegetation_candidate_count"] = vegetation_candidate_count;
    out["vegetation_biome_reconciled_count"] = vegetation_biome_reconciled_count;
    out["vegetation_native_ms"] = vegetation_native_ms;
    out["vegetation_none_count"] = vegetation_none_count;
    out["vegetation_score_min"] = vegetation_candidate_count > vegetation_none_count ? vegetation_score_min : 0.0f;
    out["vegetation_score_mean"] = vegetation_candidate_count > 0
        ? float(vegetation_score_sum / double(std::max(1, vegetation_candidate_count))) : 0.0f;
    out["vegetation_score_max"] = vegetation_score_max;
    out["plant_water_nonzero_land_count"] = plant_water_nonzero_land_count;
    out["river_adjacent_desert_count"] = river_adjacent_desert_count;
    out["coastal_highland_desert_count"] = coastal_highland_desert_count;
    out["terrain_soft_weight_min"] = vegetation_candidate_count > 0 ? terrain_soft_weight_min : 0.0f;
    out["terrain_soft_weight_max"] = vegetation_candidate_count > 0 ? terrain_soft_weight_max : 0.0f;

    out["q_arr"] = q_arr;
    out["r_arr"] = r_arr;
    out["s_arr"] = s_arr;
    out["elevation_arr"] = elevation_arr;
    out["moisture_arr"] = moisture_arr;
    out["base_moisture_arr"] = base_moisture_arr;
    out["temp_arr"] = temp_arr;
    out["temp_baseline_arr"] = temp_baseline_arr;
    out["temp_30d_arr"] = temp_30d_arr;
    out["temp_365d_arr"] = temp_365d_arr;
    out["temp_anomaly_arr"] = temp_anomaly_arr;
    out["thermal_energy_arr"] = thermal_energy_arr;
    out["cell_lat_norm_arr"] = cell_lat_norm_arr;
    out["temp_baseline_year_arr"] = temp_baseline_year_arr;
    out["snow_cover_arr"] = snow_cover_arr;
    // 透传 base pass 生成的湖泊种子标记（仅 UI 信息面板用，post_base 不改写）。
    out["is_lake_seed_arr"] = input.get("is_lake_seed_arr", PackedByteArray());
    out["terrain_arr"] = terrain_arr;
    out["base_terrain_arr"] = base_terrain_arr;
    out["landform_arr"] = landform_arr;
    out["base_landform_arr"] = base_landform_arr;
    out["vegetation_arr"] = vegetation_arr;
    out["base_vegetation_arr"] = base_vegetation_arr;
    out["vegetation_vitality_arr"] = vegetation_vitality_arr;
    out["soil_moisture_arr"] = soil_moisture_arr;
    out["water_balance_30d_arr"] = water_balance_30d_arr;
    out["plant_available_water_arr"] = plant_available_water_arr;
    out["vegetation_growth_pressure_arr"] = vegetation_growth_pressure_arr;
    out["vegetation_heat_stress_arr"] = vegetation_heat_stress_arr;
    out["vegetation_drought_stress_arr"] = vegetation_drought_stress_arr;
    out["vegetation_cold_stress_arr"] = vegetation_cold_stress_arr;
    out["vegetation_regen_score_arr"] = vegetation_regen_score_arr;
    out["cover_arr"] = cover_arr;
    out["is_water_arr"] = is_water_arr;
    out["has_river_arr"] = has_river_arr;
    out["river_flow_arr"] = river_flow_arr;
    out["river_downstream_arr"] = river_downstream_arr;
    out["hydro_parent_arr"] = hydro_parent_arr;
    out["has_volcano_arr"] = has_volcano_arr;
    out["ema_initialized_arr"] = ema_initialized_arr;
    out["water_depth_arr"] = water_depth_arr;   // [water-depth-tex] 海/湖统一归一水深 ∈ [0,1]
    if (upwelling_arr.size() == n) out["upwelling_strength_arr"] = upwelling_arr;

    // ─── 暂存河流拓扑到 ext 成员（dots-total-cpp step1）──────────────────
    // 供同一 generation ext 实例的 run_bake_river_sdf_pass 直接 trace（零跨语言再传输）。
    // terrain/elevation/river_flow 此处均为 post_base 最终值；NB 是已建好的 n*6 邻居索引。
    {
        _gen_river_n = n;
        _gen_river_q.assign(size_t(n), 0);
        _gen_river_r.assign(size_t(n), 0);
        _gen_river_terrain.assign(size_t(n), 0);
        _gen_river_elev.assign(size_t(n), 0.0f);
        _gen_river_has.assign(size_t(n), 0);
        _gen_river_flow.assign(size_t(n), 0.0f);
        _gen_river_downstream.assign(size_t(n), -1);
        _gen_river_neighbors.assign(size_t(n) * 6, -1);
        for (int i = 0; i < n; ++i) {
            _gen_river_q[size_t(i)] = Q[i];
            _gen_river_r[size_t(i)] = R[i];
            _gen_river_terrain[size_t(i)] = TERR[i];
            _gen_river_elev[size_t(i)] = E[i];
            _gen_river_has[size_t(i)] = RIV[i];
            _gen_river_flow[size_t(i)] = RFLOW_OUT[i];
            _gen_river_downstream[size_t(i)] = RDOWN[i];
        }
        for (size_t k = 0; k < size_t(n) * 6; ++k) _gen_river_neighbors[k] = NB[k];
    }

    return out;
}

godot::Dictionary DCWorldExt::restuff_generation_river_cache(const godot::Dictionary &input) {
    using godot::Dictionary;
    using godot::PackedByteArray;
    using godot::PackedFloat32Array;
    using godot::PackedInt32Array;
    using godot::String;

    Dictionary out;
    out["rc"] = -1;
    out["ok"] = false;
    out["fallback"] = true;
    out["reason"] = String();
    out["n_cells"] = 0;

    const int width = int(input.get("width", 0));
    const int height = int(input.get("height", 0));
    const int n = int(input.get("n_cells", int64_t(width) * int64_t(height)));
    if (width <= 0 || height <= 0 || n <= 0 || n != width * height) {
        out["reason"] = String("invalid_dimensions");
        return out;
    }

    PackedInt32Array q_arr = input.get("q_arr", PackedInt32Array());
    PackedInt32Array r_arr = input.get("r_arr", PackedInt32Array());
    PackedFloat32Array elevation_arr = input.get("elevation_arr", PackedFloat32Array());
    PackedByteArray terrain_arr = input.get("terrain_arr", PackedByteArray());
    PackedByteArray has_river_arr = input.get("has_river_arr", PackedByteArray());
    PackedFloat32Array river_flow_arr = input.get("river_flow_arr", PackedFloat32Array());
    PackedInt32Array river_downstream_arr = input.get("river_downstream_arr", PackedInt32Array());
    if (q_arr.size() != n || r_arr.size() != n || elevation_arr.size() != n || terrain_arr.size() != n) {
        out["reason"] = String("required_input_size_mismatch");
        return out;
    }
    if (has_river_arr.size() != n) {
        has_river_arr.resize(n);
        uint8_t *H = has_river_arr.ptrw();
        for (int i = 0; i < n; ++i) H[i] = 0;
    }
    if (river_flow_arr.size() != n) {
        river_flow_arr.resize(n);
        float *F = river_flow_arr.ptrw();
        for (int i = 0; i < n; ++i) F[i] = 0.0f;
    }
    if (river_downstream_arr.size() != n) {
        river_downstream_arr.resize(n);
        int32_t *D = river_downstream_arr.ptrw();
        for (int i = 0; i < n; ++i) D[i] = -1;
    }

    const int32_t *Q = q_arr.ptr();
    const int32_t *R = r_arr.ptr();
    const float *E = elevation_arr.ptr();
    const uint8_t *TERR = terrain_arr.ptr();
    const uint8_t *RIV = has_river_arr.ptr();
    const float *RFLOW = river_flow_arr.ptr();
    const int32_t *RDOWN = river_downstream_arr.ptr();

    constexpr int DQ[6] = { 1, 1, 0, -1, -1, 0 };
    constexpr int DR[6] = { 0, -1, -1, 0, 1, 1 };
    auto index_for_qr = [&](int q, int r) -> int {
        if (r < 0 || r >= height) return -1;
        int col = q + ((r - (r & 1)) / 2);
        col = ((col % width) + width) % width;
        return r * width + col;
    };

    _gen_river_n = n;
    _gen_river_q.assign(size_t(n), 0);
    _gen_river_r.assign(size_t(n), 0);
    _gen_river_terrain.assign(size_t(n), 0);
    _gen_river_elev.assign(size_t(n), 0.0f);
    _gen_river_has.assign(size_t(n), 0);
    _gen_river_flow.assign(size_t(n), 0.0f);
    _gen_river_downstream.assign(size_t(n), -1);
    _gen_river_neighbors.assign(size_t(n) * 6, -1);
    for (int i = 0; i < n; ++i) {
        _gen_river_q[size_t(i)] = Q[i];
        _gen_river_r[size_t(i)] = R[i];
        _gen_river_terrain[size_t(i)] = TERR[i];
        _gen_river_elev[size_t(i)] = E[i];
        _gen_river_has[size_t(i)] = RIV[i];
        _gen_river_flow[size_t(i)] = RFLOW[i];
        _gen_river_downstream[size_t(i)] = RDOWN[i];
        for (int d = 0; d < 6; ++d) {
            _gen_river_neighbors[size_t(i) * 6 + size_t(d)] = index_for_qr(Q[i] + DQ[d], R[i] + DR[d]);
        }
    }

    out["rc"] = 0;
    out["ok"] = true;
    out["fallback"] = false;
    out["n_cells"] = n;
    return out;
}

Dictionary DCWorldExt::_run_native_generation_publish_pass(
    int seed,
    const Dictionary &cfg,
    const Dictionary &profile,
    const Dictionary &budget) {
    Dictionary out;
    out["rc"] = -1;
    out["status"] = String("failed");
    out["path"] = String("gdscript_fallback");
    out["fallback"] = true;
    out["fallback_reason"] = String();
    out["reason"] = String();
    out["fail_stage"] = String();
    out["seed"] = seed;
    out["has_config"] = !cfg.is_empty();
    out["has_profile"] = !profile.is_empty();
    out["implemented"] = true;
    out["published_to_slot"] = false;
    out["published_slots"] = Array();
    out["n_cells"] = 0;
    out["elapsed_ms"] = -1.0;
    out["native_ms"] = -1.0;
    out["compute_ms"] = 0.0;
    out["flush_ms"] = 0.0;
    out["generation_progress"] = 0.0;
    if (!budget.is_empty()) {
        out["budget"] = budget.duplicate(true);
    }

    auto fail = [&](const String &why, const String &stage = String("native_generation_publish")) -> Dictionary {
        out["fallback_reason"] = why;
        out["reason"] = why;
        out["fail_stage"] = stage;
        _native_generation_report = out.duplicate(true);
        return out;
    };

    if (!_bound || _map_data == nullptr) {
        return fail("not_bound", "bind_map_data");
    }

    const double sea_level = double(cfg.get("sea_level", 0.5));
    int n_cells = int(cfg.get("cell_count", 0));
    if (n_cells <= 0) {
        n_cells = _native_world_cell_count;
    }
    if (n_cells <= 0) {
        n_cells = _entity_count;
    }

    struct RequiredSlot {
        const char *name;
        SlotDType dtype;
        int sid = -1;
    };
    RequiredSlot req[] = {
        {"cell_lat_norm", SlotDType::F32, -1},
        {"cell_elevation", SlotDType::F32, -1},
        {"cell_temp_baseline_year", SlotDType::F32, -1},
        {"cell_temp", SlotDType::F32, -1},
        {"cell_temp_baseline", SlotDType::F32, -1},
        {"cell_temp_30d", SlotDType::F32, -1},
        {"cell_temp_365d", SlotDType::F32, -1},
        {"cell_base_moisture", SlotDType::F32, -1},
        {"cell_water_balance_30d", SlotDType::F32, -1},
        {"cell_temp_anomaly", SlotDType::F32, -1},
        {"cell_thermal_energy", SlotDType::F32, -1},
        {"cell_terrain", SlotDType::U8, -1},
        {"cell_is_water", SlotDType::U8, -1},
        {"cell_ema_initialized", SlotDType::U8, -1},
    };

    for (RequiredSlot &r : req) {
        r.sid = component_id(StringName(r.name));
        if (r.sid < 0 || r.sid >= _slots.size()) {
            String msg = String("missing_slot: ") + String(r.name);
            return fail(msg, "slot_lookup");
        }
        const Slot &s = _slots.write[r.sid];
        if (s.dtype != r.dtype) {
            String msg = String("slot_dtype_mismatch: ") + String(r.name);
            return fail(msg, "slot_dtype");
        }
        const int sz = (r.dtype == SlotDType::F32) ? s.arr_f32.size() : s.arr_u8.size();
        if (n_cells <= 0) {
            n_cells = sz;
        }
        if (sz != n_cells) {
            String msg = String("slot_size_mismatch: ") + String(r.name)
                + String(" size=") + String::num_int64(sz)
                + String(" expected=") + String::num_int64(n_cells);
            return fail(msg, "slot_size");
        }
    }
    if (n_cells <= 0) {
        return fail("empty_world", "slot_size");
    }

    auto sid_of = [&](const char *name) -> int {
        for (const RequiredSlot &r : req) {
            if (std::strcmp(r.name, name) == 0) {
                return r.sid;
            }
        }
        return -1;
    };

    const int sid_lat = sid_of("cell_lat_norm");
    const int sid_elev = sid_of("cell_elevation");
    const int sid_temp_year = sid_of("cell_temp_baseline_year");
    const int sid_temp = sid_of("cell_temp");
    const int sid_temp_baseline = sid_of("cell_temp_baseline");
    const int sid_temp_30d = sid_of("cell_temp_30d");
    const int sid_temp_365d = sid_of("cell_temp_365d");
    const int sid_temp_anom = sid_of("cell_temp_anomaly");
    const int sid_thermal = sid_of("cell_thermal_energy");
    const int sid_terrain = sid_of("cell_terrain");
    const int sid_is_water = sid_of("cell_is_water");
    const int sid_ema = sid_of("cell_ema_initialized");

    const float * const __restrict LAT = _slots.write[sid_lat].arr_f32.ptr();
    const float * const __restrict ELEV = _slots.write[sid_elev].arr_f32.ptr();
    const uint8_t * const __restrict TERR = _slots.write[sid_terrain].arr_u8.ptr();
    float * const __restrict TEMP_YEAR = _slots.write[sid_temp_year].arr_f32.ptrw();
    float * const __restrict TEMP = _slots.write[sid_temp].arr_f32.ptrw();
    float * const __restrict TEMP_BASE = _slots.write[sid_temp_baseline].arr_f32.ptrw();
    float * const __restrict TEMP_30D = _slots.write[sid_temp_30d].arr_f32.ptrw();
    float * const __restrict TEMP_365D = _slots.write[sid_temp_365d].arr_f32.ptrw();
    float * const __restrict TEMP_ANOM = _slots.write[sid_temp_anom].arr_f32.ptrw();
    float * const __restrict THERMAL = _slots.write[sid_thermal].arr_f32.ptrw();
    uint8_t * const __restrict IS_WATER = _slots.write[sid_is_water].arr_u8.ptrw();
    uint8_t * const __restrict EMA = _slots.write[sid_ema].arr_u8.ptrw();

    const auto t0 = std::chrono::high_resolution_clock::now();
    const auto tc0 = std::chrono::high_resolution_clock::now();
    int water_count = 0;
    for (int i = 0; i < n_cells; ++i) {
        const float ny = LAT[i];
        const float elev = ELEV[i];
        const float year = float(pk_clamp01(pk_lat_temp_bell((double(ny) - 0.5) * 2.0)));
        const float boot_temp = pk_compute_temperature(double(ny), double(elev), sea_level);
        const uint8_t water = pk_is_water_terrain(TERR[i]) ? uint8_t(1) : uint8_t(0);

        TEMP_YEAR[i] = year;
        TEMP[i] = boot_temp;
        TEMP_BASE[i] = boot_temp;
        TEMP_30D[i] = boot_temp;
        TEMP_365D[i] = boot_temp;
        TEMP_ANOM[i] = 0.0f;
        THERMAL[i] = boot_temp;
        EMA[i] = 1;
        IS_WATER[i] = water;
        water_count += int(water);
    }
    const auto tc1 = std::chrono::high_resolution_clock::now();

    Array published_slots;
    auto flush_publish = [&](int sid, const char *name) {
        if (sid >= 0) {
            _flush_slot_to_map(sid);
            published_slots.append(String(name));
        }
    };
    const auto tf0 = std::chrono::high_resolution_clock::now();
    flush_publish(sid_temp_year, "cell_temp_baseline_year");
    flush_publish(sid_temp, "cell_temp");
    flush_publish(sid_temp_baseline, "cell_temp_baseline");
    flush_publish(sid_temp_30d, "cell_temp_30d");
    flush_publish(sid_temp_365d, "cell_temp_365d");
    flush_publish(sid_temp_anom, "cell_temp_anomaly");
    flush_publish(sid_thermal, "cell_thermal_energy");
    flush_publish(sid_ema, "cell_ema_initialized");
    flush_publish(sid_is_water, "cell_is_water");
    const auto tf1 = std::chrono::high_resolution_clock::now();
    const auto t1 = std::chrono::high_resolution_clock::now();

    const double compute_ms = std::chrono::duration<double, std::milli>(tc1 - tc0).count();
    const double flush_ms = std::chrono::duration<double, std::milli>(tf1 - tf0).count();
    const double elapsed_ms = std::chrono::duration<double, std::milli>(t1 - t0).count();

    out["rc"] = 0;
    out["status"] = String("completed");
    out["path"] = String("gdext");
    out["fallback"] = false;
    out["fallback_reason"] = String();
    out["reason"] = String();
    out["fail_stage"] = String();
    out["published_to_slot"] = true;
    out["published_slots"] = published_slots;
    out["published_temp_baseline_year"] = true;
    out["n_cells"] = n_cells;
    out["water_count"] = water_count;
    out["land_count"] = n_cells - water_count;
    out["elapsed_ms"] = elapsed_ms;
    out["native_ms"] = elapsed_ms;
    out["compute_ms"] = compute_ms;
    out["flush_ms"] = flush_ms;
    out["generation_progress"] = 1.0;
    out["cfg_width"] = int(cfg.get("width", 0));
    out["cfg_height"] = int(cfg.get("height", 0));
    out["profile_keys"] = profile.keys();
    _native_generation_report = out.duplicate(true);
    return out;
}


} // namespace pk
