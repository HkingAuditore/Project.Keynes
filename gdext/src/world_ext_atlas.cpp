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


godot::Dictionary DCWorldExt::run_sea_ice_atlas_prepare(godot::Dictionary knobs) {
    using godot::Dictionary;
    using godot::PackedByteArray;
    using godot::PackedInt32Array;
    using godot::String;
    using godot::StringName;

    Dictionary out;
    out["elapsed_ms"] = -1.0;
    out["prepare_ms"] = -1.0;
    out["fallback"] = true;
    out["reason"] = String();

    auto fail = [&](const char *why) -> Dictionary {
        out["reason"] = String(why);
        UtilityFunctions::push_warning("[DCWorldExt] run_sea_ice_atlas_prepare: ", why,
                                       " - fallback to GDScript");
        return out;
    };

    if (!_bound) return fail("not bound");
    if (!knobs.has("n_cells") || !knobs.has("width") || !knobs.has("height") ||
        !knobs.has("pixel_to_cell_index")) {
        return fail("missing required knob");
    }
    const int n_cells = int(knobs["n_cells"]);
    const int width = int(knobs["width"]);
    const int height = int(knobs["height"]);
    if (n_cells <= 0 || width <= 0 || height <= 0) return fail("invalid dimensions");

    PackedInt32Array pix_to_cell = knobs["pixel_to_cell_index"];
    const int n_pix = width * height;
    if (pix_to_cell.size() < n_pix) return fail("pixel_to_cell_index too small");
    PackedByteArray prev_cell_bytes = knobs.get("previous_cell_bytes", PackedByteArray());

    const int sid_ice = component_id(StringName("cell_sea_ice_frac"));
    if (sid_ice < 0) return fail("missing slot id cell_sea_ice_frac");
    Slot &s_ice = _slots.write[sid_ice];
    if (s_ice.arr_f32.size() < n_cells) return fail("sea_ice_frac slot too small");

    auto t0 = std::chrono::high_resolution_clock::now();
    PackedByteArray cell_bytes;
    cell_bytes.resize(n_cells);
    uint8_t * const __restrict CB = cell_bytes.ptrw();
    const float * const __restrict ICE = s_ice.arr_f32.ptr();
    const uint8_t * const PREV = prev_cell_bytes.size() >= n_cells ? prev_cell_bytes.ptr() : nullptr;
    int dirty_cells = 0;
    for (int i = 0; i < n_cells; ++i) {
        int q = int(std::round(pk_clamp01(double(ICE[i])) * 255.0));
        if (q < 0) q = 0;
        else if (q > 255) q = 255;
        CB[i] = uint8_t(q);
        if (PREV == nullptr || PREV[i] != CB[i]) ++dirty_cells;
    }

    PackedByteArray buffer;
    buffer.resize(n_pix);
    uint8_t * const __restrict BUF = buffer.ptrw();
    const int32_t * const __restrict P2C = pix_to_cell.ptr();
    for (int p = 0; p < n_pix; ++p) {
        const int ci = P2C[p];
        BUF[p] = (ci >= 0 && ci < n_cells) ? CB[ci] : 0;
    }

    auto t1 = std::chrono::high_resolution_clock::now();
    const double ms = std::chrono::duration<double, std::milli>(t1 - t0).count();
    out["elapsed_ms"] = ms;
    out["prepare_ms"] = ms;
    out["fallback"] = false;
    out["reason"] = String();
    out["buffer"] = buffer;
    out["cell_bytes"] = cell_bytes;
    out["dirty_cells"] = dirty_cells;
    out["dirty_ratio"] = n_cells > 0 ? double(dirty_cells) / double(n_cells) : 0.0;
    out["pixels"] = n_pix;
    return out;
}

godot::Dictionary DCWorldExt::patch_enum_atlas_axes(godot::Dictionary knobs) {
    using godot::Dictionary;
    using godot::PackedByteArray;
    using godot::PackedInt32Array;
    using godot::String;
    using godot::StringName;

    Dictionary out;
    out["fallback"] = true;
    out["reason"] = String();
    out["dirty_cells"] = 0;
    out["dirty_pixels"] = 0;
    out["biome_dirty"] = 0;
    out["vegetation_dirty"] = 0;
    out["cover_dirty"] = 0;

    auto fail = [&](const char *why) -> Dictionary {
        out["reason"] = String(why);
        return out;
    };

    if (!_bound) return fail("not bound");
    if (!knobs.has("n_cells") || !knobs.has("n_pix") ||
        !knobs.has("cell_first_px") || !knobs.has("cell_px_count") ||
        !knobs.has("flat_px_indices") || !knobs.has("enum_atlas_data")) {
        return fail("missing required knob");
    }

    const int n_cells = int(knobs["n_cells"]);
    const int n_pix = int(knobs["n_pix"]);
    const bool run_biome = bool(knobs.get("run_biome", false));
    const bool run_vegetation = bool(knobs.get("run_vegetation", false));
    const bool run_cover = bool(knobs.get("run_cover", false));
    if (n_cells <= 0 || n_pix <= 0) return fail("invalid n_cells/n_pix");
    if (!run_biome && !run_vegetation && !run_cover) return fail("no axis enabled");

    PackedInt32Array first_px = knobs["cell_first_px"];
    PackedInt32Array px_count = knobs["cell_px_count"];
    PackedInt32Array flat_px = knobs["flat_px_indices"];
    PackedByteArray enum_data = knobs["enum_atlas_data"];
    if (first_px.size() < n_cells || px_count.size() < n_cells) return fail("cell CSR size < n_cells");
    if (enum_data.size() != n_pix * 4) return fail("enum_atlas_data size mismatch");

    PackedByteArray biome_buf = knobs.get("biome_buffer", PackedByteArray());
    PackedByteArray vegetation_buf = knobs.get("vegetation_buffer", PackedByteArray());
    PackedByteArray cover_buf = knobs.get("cover_buffer", PackedByteArray());
    if (run_biome && biome_buf.size() != n_pix) return fail("biome_buffer size mismatch");
    if (run_vegetation && vegetation_buf.size() != n_pix) return fail("vegetation_buffer size mismatch");
    if (run_cover && cover_buf.size() != n_pix) return fail("cover_buffer size mismatch");

    PackedByteArray prev_biome = knobs.get("prev_biome", PackedByteArray());
    PackedByteArray prev_vegetation = knobs.get("prev_vegetation", PackedByteArray());
    PackedByteArray prev_cover = knobs.get("prev_cover", PackedByteArray());
    const bool prev_biome_valid = prev_biome.size() == n_cells;
    const bool prev_vegetation_valid = prev_vegetation.size() == n_cells;
    const bool prev_cover_valid = prev_cover.size() == n_cells;
    if (run_biome && !prev_biome_valid) prev_biome.resize(n_cells);
    if (run_vegetation && !prev_vegetation_valid) prev_vegetation.resize(n_cells);
    if (run_cover && !prev_cover_valid) prev_cover.resize(n_cells);

    const int sid_terrain = run_biome ? component_id(StringName("cell_terrain")) : -1;
    const int sid_vegetation = run_vegetation ? component_id(StringName("cell_vegetation")) : -1;
    const int sid_cover = run_cover ? component_id(StringName("cell_cover")) : -1;
    if (run_biome && sid_terrain < 0) return fail("missing slot id cell_terrain");
    if (run_vegetation && sid_vegetation < 0) return fail("missing slot id cell_vegetation");
    if (run_cover && sid_cover < 0) return fail("missing slot id cell_cover");

    const uint8_t *TERR = nullptr;
    const uint8_t *VEG = nullptr;
    const uint8_t *COV = nullptr;
    if (run_biome) {
        Slot &s = _slots.write[sid_terrain];
        if (s.arr_u8.size() < n_cells) return fail("terrain slot too small");
        TERR = s.arr_u8.ptr();
    }
    if (run_vegetation) {
        Slot &s = _slots.write[sid_vegetation];
        if (s.arr_u8.size() < n_cells) return fail("vegetation slot too small");
        VEG = s.arr_u8.ptr();
    }
    if (run_cover) {
        Slot &s = _slots.write[sid_cover];
        if (s.arr_u8.size() < n_cells) return fail("cover slot too small");
        COV = s.arr_u8.ptr();
    }

    const int32_t * const FIRST = first_px.ptr();
    const int32_t * const CNT = px_count.ptr();
    const int32_t * const FLAT = flat_px.ptr();
    const int flat_n = flat_px.size();
    uint8_t * const ED = enum_data.ptrw();
    uint8_t *BB = run_biome ? biome_buf.ptrw() : nullptr;
    uint8_t *VB = run_vegetation ? vegetation_buf.ptrw() : nullptr;
    uint8_t *CB = run_cover ? cover_buf.ptrw() : nullptr;
    uint8_t *PB = run_biome ? prev_biome.ptrw() : nullptr;
    uint8_t *PV = run_vegetation ? prev_vegetation.ptrw() : nullptr;
    uint8_t *PC = run_cover ? prev_cover.ptrw() : nullptr;

    int biome_dirty = 0;
    int vegetation_dirty = 0;
    int cover_dirty = 0;
    int dirty_pixels = 0;

    for (int i = 0; i < n_cells; ++i) {
        const uint8_t b_t = run_biome ? TERR[i] : 0;
        const uint8_t b_v = run_vegetation ? VEG[i] : 0;
        const uint8_t b_c = run_cover ? COV[i] : 0;
        const bool dirty_b = run_biome && (!prev_biome_valid || PB[i] != b_t);
        const bool dirty_v = run_vegetation && (!prev_vegetation_valid || PV[i] != b_v);
        const bool dirty_c = run_cover && (!prev_cover_valid || PC[i] != b_c);
        if (!dirty_b && !dirty_v && !dirty_c) continue;

        if (dirty_b) { PB[i] = b_t; ++biome_dirty; }
        if (dirty_v) { PV[i] = b_v; ++vegetation_dirty; }
        if (dirty_c) { PC[i] = b_c; ++cover_dirty; }

        const int f = FIRST[i];
        const int c = CNT[i];
        if (c <= 0 || f < 0 || f + c > flat_n) continue;
        const int axis_changes = (dirty_b ? 1 : 0) + (dirty_v ? 1 : 0) + (dirty_c ? 1 : 0);
        dirty_pixels += c * axis_changes;
        for (int p = 0; p < c; ++p) {
            const int px = FLAT[f + p];
            if (px < 0 || px >= n_pix) continue;
            const int di = px * 4;
            if (dirty_b) { BB[px] = b_t; ED[di] = b_t; }
            if (dirty_v) { VB[px] = b_v; }
            if (dirty_c) { CB[px] = b_c; }
        }
    }

    out["fallback"] = false;
    out["reason"] = String();
    out["dirty_cells"] = biome_dirty + vegetation_dirty + cover_dirty;
    out["dirty_pixels"] = dirty_pixels;
    out["biome_dirty"] = biome_dirty;
    out["vegetation_dirty"] = vegetation_dirty;
    out["cover_dirty"] = cover_dirty;
    out["enum_atlas_data"] = enum_data;
    if (run_biome) {
        out["biome_buffer"] = biome_buf;
        out["prev_biome"] = prev_biome;
    }
    if (run_vegetation) {
        out["vegetation_buffer"] = vegetation_buf;
        out["prev_vegetation"] = prev_vegetation;
    }
    if (run_cover) {
        out["cover_buffer"] = cover_buf;
        out["prev_cover"] = prev_cover;
    }
    return out;
}

// ─── Dirty-Push Atlas Encode (plan/dirty-push-atlas-encode 阶段 F) ──────────
// 4 个 atlas baker 的 byte-fill pass C++ 化。CSR 协议详见 world_ext.h 注释。
//
// 共享内联 helper：q01_byte / q01_byte_ice 与 GDScript map_baker.gd::_q01_byte
// 完全 bit-equal（int(round(clampf(v, 0, 1) * 255))）。round 走 C++ std::round
// half-away-from-zero，与 GDScript round() 一致。

static inline int pk_q01_byte(double v) {
    if (v <= 0.0) return 0;
    if (v >= 1.0) return 255;
    int q = int(std::round(v * 255.0));
    if (q < 0) q = 0;
    else if (q > 255) q = 255;
    return q;
}

// _q01_byte_ice：fraction>0 时强制 byte≥1，让微量海冰也能 shader 触发可见。
static inline int pk_q01_byte_ice(double v) {
    if (v <= 0.0) return 0;
    if (v >= 1.0) return 255;
    // ceil 而非 round，保证 v>0 → byte≥1。
    int q = int(std::ceil(v * 255.0));
    if (q < 1) q = 1;
    else if (q > 255) q = 255;
    return q;
}

// 共享 CSR 验证 helper：失败时调用 fail() 回 fallback Dictionary。
namespace {

struct AtlasEncodeCommon {
    int n_pix = 0;
    int stride = 0;
    int K = 0;                 // dirty cell count
    int total_px = 0;          // sum(cell_px_count)
    godot::PackedByteArray buffer;
    godot::PackedInt32Array cell_indices;
    godot::PackedInt32Array first_px;
    godot::PackedInt32Array px_count;
    godot::PackedInt32Array flat_px;
    bool valid = false;
    const char *err = "";
};

// 提取并校验 CSR 通用入参。失败时设 err 并返回 valid=false。
inline AtlasEncodeCommon parse_csr_common(const godot::Dictionary &knobs, int expected_stride) {
    using godot::PackedByteArray;
    using godot::PackedInt32Array;
    AtlasEncodeCommon c;
    c.stride = expected_stride;
    if (!knobs.has("n_pix") || !knobs.has("atlas_buffer") ||
        !knobs.has("cell_indices") || !knobs.has("cell_first_px") ||
        !knobs.has("cell_px_count") || !knobs.has("flat_px_indices")) {
        c.err = "missing required CSR knob";
        return c;
    }
    c.n_pix = int(knobs["n_pix"]);
    if (c.n_pix <= 0) { c.err = "n_pix <= 0"; return c; }
    c.buffer = knobs["atlas_buffer"];
    if (c.buffer.size() != c.n_pix * c.stride) {
        c.err = "atlas_buffer size mismatch";
        return c;
    }
    c.cell_indices = knobs["cell_indices"];
    c.first_px = knobs["cell_first_px"];
    c.px_count = knobs["cell_px_count"];
    c.flat_px = knobs["flat_px_indices"];
    c.K = c.cell_indices.size();
    if (c.first_px.size() != c.K || c.px_count.size() != c.K) {
        c.err = "CSR row-ptr length mismatch";
        return c;
    }
    c.total_px = c.flat_px.size();
    // 边界 sanity：last cell first_px + px_count <= total_px
    if (c.K > 0) {
        const int last_first = c.first_px[c.K - 1];
        const int last_count = c.px_count[c.K - 1];
        if (last_first < 0 || last_count < 0 || last_first + last_count > c.total_px) {
            c.err = "CSR row-ptr out of bounds";
            return c;
        }
    }
    c.valid = true;
    return c;
}

} // anonymous namespace

godot::Dictionary DCWorldExt::encode_dynamic_cell_atlas(godot::Dictionary knobs) {
    using godot::Dictionary;
    using godot::PackedByteArray;
    using godot::PackedInt32Array;
    using godot::String;
    using godot::StringName;

    Dictionary out;
    out["elapsed_ms"] = -1.0;
    out["fallback"] = true;
    out["reason"] = String();
    out["pixels_written"] = 0;

    auto fail = [&](const char *why) -> Dictionary {
        out["reason"] = String(why);
        UtilityFunctions::push_warning("[DCWorldExt] encode_dynamic_cell_atlas: ", why,
                                       " - fallback to GDScript");
        return out;
    };

    if (!_bound) return fail("not bound");

    auto c = parse_csr_common(knobs, 4);
    if (!c.valid) return fail(c.err);
    if (!knobs.has("cell_is_water")) return fail("missing cell_is_water");
    PackedByteArray is_water = knobs["cell_is_water"];
    if (is_water.size() != c.K) return fail("cell_is_water size mismatch");

    // [perf 2026-05-20 sig-diff-skip] 与 GDScript 路径对齐的 sig cache：
    //   GD 端 dynamic_cell_atlas_chunk_step line 727:
    //       if cache_valid and _last_dynamic_cell_sigs.get(cell, -1) == sig: continue
    //   原 cpp 路径"所有 cell 都重写 pixel"，整图 2400 dirty 时 pixel fan-out 主导耗时。
    //   现在让 cpp 也消费 prev_sigs（按 cell_indices 顺序打包）+ cache_valid，
    //   命中比对就跳过 pixel fan-out，仅写 SIGS[k]=sig 让 GD 端 cache 一致。
    //   prev_sigs 缺省/size mismatch/cache_valid=false 都退化为"全部重写"，行为等价旧版。
    const bool sig_cache_valid = bool(knobs.get("cache_valid", false));
    PackedInt32Array prev_sigs;
    bool prev_sigs_usable = false;
    if (sig_cache_valid && knobs.has("prev_sigs")) {
        prev_sigs = knobs["prev_sigs"];
        prev_sigs_usable = (prev_sigs.size() == c.K);
    }

    const int sid_temp = component_id(StringName("cell_temp"));
    const int sid_moist = component_id(StringName("cell_moisture"));
    const int sid_snow = component_id(StringName("cell_snow_cover"));
    const int sid_vit = component_id(StringName("cell_vegetation_vitality"));
    // [sea-ice-render-source-unify 阶段 A] A 通道双语义：
    //   水格 A = q01_byte_ice(sea_ice_fraction)，shader 水路径单源消费；
    //   陆格 A = q01_byte(vegetation_vitality)（保持原语义）。
    const int sid_sif = component_id(StringName("cell_sea_ice_frac"));
    if (sid_temp < 0 || sid_moist < 0 || sid_snow < 0 || sid_vit < 0 || sid_sif < 0) {
        return fail("missing slot id (temp/moist/snow/vitality/sea_ice_frac)");
    }
    Slot &s_temp = _slots.write[sid_temp];
    Slot &s_moist = _slots.write[sid_moist];
    Slot &s_snow = _slots.write[sid_snow];
    Slot &s_vit = _slots.write[sid_vit];
    Slot &s_sif = _slots.write[sid_sif];
    const int n_cells = _entity_count;
    if (s_temp.arr_f32.size() < n_cells || s_moist.arr_f32.size() < n_cells ||
        s_snow.arr_f32.size() < n_cells || s_vit.arr_f32.size() < n_cells ||
        s_sif.arr_f32.size() < n_cells) {
        return fail("slot array size < entity_count");
    }

    auto t0 = std::chrono::high_resolution_clock::now();

    const float * const __restrict TEMP = s_temp.arr_f32.ptr();
    const float * const __restrict MOIST = s_moist.arr_f32.ptr();
    const float * const __restrict SNOW = s_snow.arr_f32.ptr();
    const float * const __restrict VIT = s_vit.arr_f32.ptr();
    const float * const __restrict SIF = s_sif.arr_f32.ptr();
    const int32_t * const __restrict CELLS = c.cell_indices.ptr();
    const int32_t * const __restrict FIRST = c.first_px.ptr();
    const int32_t * const __restrict CNT = c.px_count.ptr();
    const int32_t * const __restrict FLAT = c.flat_px.ptr();
    const uint8_t * const __restrict PSEA = is_water.ptr();
    const int32_t * const __restrict PREV_SIGS =
        prev_sigs_usable ? prev_sigs.ptr() : nullptr;
    uint8_t * const __restrict BUF = c.buffer.ptrw();

    PackedInt32Array new_sigs;
    new_sigs.resize(c.K);
    int32_t * const __restrict SIGS = new_sigs.ptrw();

    int pixels_written = 0;
    int sig_skipped = 0;  // 命中 sig diff skip 的 cell 数（诊断用）
    for (int k = 0; k < c.K; ++k) {
        const int ci = CELLS[k];
        if (ci < 0 || ci >= n_cells) {
            SIGS[k] = 0;
            continue;
        }
        const int r = pk_q01_byte(double(TEMP[ci]));
        const int g = pk_q01_byte(double(MOIST[ci]));
        const int b = pk_q01_byte(double(SNOW[ci]));
        // [sea-ice-render-source-unify 阶段 C] A 通道：水格存海冰、陆格存植被活力。
        // 水陆判定基于 is_water 语义（含 SEA_ICE）；GDScript 侧统一从 is_water_arr/LUT 喂入。
        const int a = (PSEA[k] != 0)
            ? pk_q01_byte_ice(double(SIF[ci]))
            : pk_q01_byte(double(VIT[ci]));
        const uint32_t sig = uint32_t(r) | (uint32_t(g) << 8) |
                             (uint32_t(b) << 16) | (uint32_t(a) << 24);
        SIGS[k] = int32_t(sig);

        // sig-diff fast skip：与上次 cache 一致则跳过 pixel fan-out（热点中的热点）。
        if (PREV_SIGS != nullptr && uint32_t(PREV_SIGS[k]) == sig) {
            ++sig_skipped;
            continue;
        }

        const int first = FIRST[k];
        const int count = CNT[k];
        for (int p = 0; p < count; ++p) {
            const int px_idx = FLAT[first + p];
            if (px_idx < 0 || px_idx >= c.n_pix) continue;
            const int base = px_idx * 4;
            BUF[base    ] = uint8_t(r);
            BUF[base + 1] = uint8_t(g);
            BUF[base + 2] = uint8_t(b);
            BUF[base + 3] = uint8_t(a);
            ++pixels_written;
        }
    }

    auto t1 = std::chrono::high_resolution_clock::now();
    const double ms = std::chrono::duration<double, std::milli>(t1 - t0).count();
    out["elapsed_ms"] = ms;
    out["fallback"] = false;
    out["reason"] = String();
    out["pixels_written"] = pixels_written;
    out["atlas_buffer"] = c.buffer;
    out["new_sigs"] = new_sigs;
    out["sig_skipped"] = sig_skipped;
    return out;
}

godot::Dictionary DCWorldExt::encode_ecology_visual_atlas(godot::Dictionary knobs) {
    using godot::Dictionary;
    using godot::PackedByteArray;
    using godot::PackedInt32Array;
    using godot::String;
    using godot::StringName;

    Dictionary out;
    out["elapsed_ms"] = -1.0;
    out["fallback"] = true;
    out["reason"] = String();
    out["pixels_written"] = 0;

    auto fail = [&](const char *why) -> Dictionary {
        out["reason"] = String(why);
        UtilityFunctions::push_warning("[DCWorldExt] encode_ecology_visual_atlas: ", why,
                                       " - fallback to GDScript");
        return out;
    };

    if (!_bound) return fail("not bound");

    auto c = parse_csr_common(knobs, 4);
    if (!c.valid) return fail(c.err);
    if (!knobs.has("prev_veg") || !knobs.has("prev_vitality") ||
        !knobs.has("prev_transition")) {
        return fail("missing ecology prev_* knob");
    }
    PackedByteArray prev_veg = knobs["prev_veg"];
    PackedByteArray prev_vit = knobs["prev_vitality"];
    PackedByteArray prev_tr = knobs["prev_transition"];
    if (prev_veg.size() != c.K || prev_vit.size() != c.K || prev_tr.size() != c.K) {
        return fail("ecology prev_* size mismatch");
    }
    const bool cache_valid = bool(knobs.get("cache_valid", false));
    PackedInt32Array prev_sigs;
    bool prev_sigs_usable = false;
    if (cache_valid && knobs.has("prev_sigs")) {
        prev_sigs = knobs["prev_sigs"];
        prev_sigs_usable = (prev_sigs.size() == c.K);
    }

    const int sid_temp = component_id(StringName("cell_temp"));
    const int sid_moist = component_id(StringName("cell_moisture"));
    const int sid_snow = component_id(StringName("cell_snow_cover"));
    const int sid_vit = component_id(StringName("cell_vegetation_vitality"));
    const int sid_terr = component_id(StringName("cell_terrain"));
    const int sid_veg = component_id(StringName("cell_vegetation"));
    if (sid_temp < 0 || sid_moist < 0 || sid_snow < 0 || sid_vit < 0 ||
        sid_terr < 0 || sid_veg < 0) {
        return fail("missing slot id (temp/moist/snow/vit/terr/veg)");
    }
    Slot &s_temp = _slots.write[sid_temp];
    Slot &s_moist = _slots.write[sid_moist];
    Slot &s_snow = _slots.write[sid_snow];
    Slot &s_vit = _slots.write[sid_vit];
    Slot &s_terr = _slots.write[sid_terr];
    Slot &s_veg = _slots.write[sid_veg];
    const int n_cells = _entity_count;
    if (s_temp.arr_f32.size() < n_cells || s_moist.arr_f32.size() < n_cells ||
        s_snow.arr_f32.size() < n_cells || s_vit.arr_f32.size() < n_cells ||
        s_terr.arr_u8.size() < n_cells || s_veg.arr_u8.size() < n_cells) {
        return fail("slot array size < entity_count");
    }

    // 透传 GDScript TerrainType.TERRAIN.LAKE / SEA_ICE / VegetationType.VEG.NONE 常量。
    // 通过 knobs 入参（避免 C++ 端硬编码 enum 值导致 schema 漂移）。
    const int TERRAIN_LAKE = int(knobs.get("terrain_lake", -1));
    const int TERRAIN_SEA_ICE = int(knobs.get("terrain_sea_ice", -1));
    const int VEG_NONE = int(knobs.get("veg_none", -1));

    if (!knobs.has("cell_is_water")) return fail("missing cell_is_water");
    PackedByteArray is_water = knobs["cell_is_water"];
    if (is_water.size() != c.K) return fail("cell_is_water size mismatch");

    auto t0 = std::chrono::high_resolution_clock::now();

    const float * const __restrict TEMP = s_temp.arr_f32.ptr();
    const float * const __restrict MOIST = s_moist.arr_f32.ptr();
    const float * const __restrict SNOW = s_snow.arr_f32.ptr();
    const float * const __restrict VIT = s_vit.arr_f32.ptr();
    const uint8_t * const __restrict TERR = s_terr.arr_u8.ptr();
    const uint8_t * const __restrict VEG = s_veg.arr_u8.ptr();
    const int32_t * const __restrict CELLS = c.cell_indices.ptr();
    const int32_t * const __restrict FIRST = c.first_px.ptr();
    const int32_t * const __restrict CNT = c.px_count.ptr();
    const int32_t * const __restrict FLAT = c.flat_px.ptr();
    const uint8_t * const __restrict PSEA = is_water.ptr();
    const uint8_t * const __restrict PV_VEG = prev_veg.ptr();
    const uint8_t * const __restrict PV_VIT = prev_vit.ptr();
    const uint8_t * const __restrict PV_TR = prev_tr.ptr();
    const int32_t * const __restrict PREV_SIGS = prev_sigs_usable ? prev_sigs.ptr() : nullptr;
    uint8_t * const __restrict BUF = c.buffer.ptrw();

    PackedByteArray new_veg;  new_veg.resize(c.K);  uint8_t * const NV = new_veg.ptrw();
    PackedByteArray new_vit;  new_vit.resize(c.K);  uint8_t * const NVI = new_vit.ptrw();
    PackedByteArray new_tr;   new_tr.resize(c.K);   uint8_t * const NT = new_tr.ptrw();
    PackedInt32Array new_sigs; new_sigs.resize(c.K); int32_t * const SIGS = new_sigs.ptrw();

    // smoothstep helper：与 GDScript smoothstep(edge0, edge1, x) 同义。
    auto smoothstep = [](double e0, double e1, double x) {
        if (e1 <= e0) return x < e0 ? 0.0 : 1.0;
        double t = (x - e0) / (e1 - e0);
        if (t < 0.0) t = 0.0;
        else if (t > 1.0) t = 1.0;
        return t * t * (3.0 - 2.0 * t);
    };
    auto clamp01 = [](double v) {
        return v < 0.0 ? 0.0 : (v > 1.0 ? 1.0 : v);
    };

    int pixels_written = 0;
    for (int k = 0; k < c.K; ++k) {
        const int ci = CELLS[k];
        if (ci < 0 || ci >= n_cells) {
            NV[k] = 0; NVI[k] = 0; NT[k] = 0; SIGS[k] = 0;
            continue;
        }
        const int cur_veg = int(VEG[ci]) & 0xFF;
        const int cur_vit_byte = pk_q01_byte(double(VIT[ci]));
        const int prev_veg_byte = int(PV_VEG[k]);
        const int prev_vit_byte = int(PV_VIT[k]);
        int transition_age = int(PV_TR[k]);
        if (cache_valid) {
            if (cur_veg != prev_veg_byte) transition_age = 255;
            else if (transition_age > 0) {
                transition_age = transition_age - 18;
                if (transition_age < 0) transition_age = 0;
            }
        } else {
            transition_age = 0;
        }

        // ── _ecology_visual_signature 镜像 ─────────────────────────
        // sea-ice-render-source-unify 阶段 C：PSEA 已是 is_water 语义（含 SEA_ICE/LAKE），
        // 后两个 terrain 兜底成为防御性冗余（保留以防 GDScript 端误传 passable_sea）。
        const int terrain_id = int(TERR[ci]);
        const bool is_water_cell = (PSEA[k] != 0) ||
            (terrain_id == TERRAIN_LAKE) ||
            (terrain_id == TERRAIN_SEA_ICE);
        const int veg_id = cur_veg;
        const double vitality = clamp01(double(VIT[ci]));
        const double moist = clamp01(double(MOIST[ci]));
        const double temp = clamp01(double(TEMP[ci]));
        const double snow = clamp01(double(SNOW[ci]));

        double foliage = 0.0;
        if (!is_water_cell && veg_id != VEG_NONE) {
            const double cold_loss = (1.0 - smoothstep(0.02, 0.18, temp)) * 0.55;
            const double snow_loss = smoothstep(0.12, 0.75, snow) * 0.70;
            const double dry_loss = (1.0 - smoothstep(0.05, 0.35, moist)) * 0.45;
            foliage = clamp01(vitality * 0.72 + moist * 0.28 - cold_loss - snow_loss - dry_loss);
        }
        double stress = 0.0;
        if (!is_water_cell) {
            const double dryness = 1.0 - moist;
            const double heat_stress = smoothstep(0.72, 0.95, temp);
            const double cold_stress = 1.0 - smoothstep(0.03, 0.20, temp);
            const double vit_stress = 1.0 - vitality;
            const double a1 = dryness * 0.70;
            const double a2 = (heat_stress > cold_stress ? heat_stress : cold_stress) * 0.65;
            const double a3 = (a1 > a2 ? a1 : a2);
            stress = clamp01(a3 + vit_stress * 0.45);
        }
        const double vit_delta = (double(pk_q01_byte(vitality)) - double(prev_vit_byte)) / 255.0;
        const double growth_damage = clamp01(0.5 + vit_delta * 5.0 + (foliage - 0.5) * 0.12 - stress * 0.10);

        const int r = pk_q01_byte(foliage);
        const int g = pk_q01_byte(stress);
        int b = transition_age;
        if (b < 0) b = 0;
        else if (b > 255) b = 255;
        const int a = pk_q01_byte(growth_damage);
        const uint32_t sig = uint32_t(r) | (uint32_t(g) << 8) |
                             (uint32_t(b) << 16) | (uint32_t(a) << 24);

        // 写回 prev/sig 状态（每 cell 都写，无论 cache 命中）
        NV[k] = uint8_t(cur_veg);
        NVI[k] = uint8_t(cur_vit_byte);
        NT[k] = uint8_t(b);
        SIGS[k] = int32_t(sig);

        if (PREV_SIGS != nullptr && uint32_t(PREV_SIGS[k]) == sig) {
            continue;
        }

        // byte fill
        const int first = FIRST[k];
        const int count = CNT[k];
        for (int p = 0; p < count; ++p) {
            const int px_idx = FLAT[first + p];
            if (px_idx < 0 || px_idx >= c.n_pix) continue;
            const int base = px_idx * 4;
            BUF[base    ] = uint8_t(r);
            BUF[base + 1] = uint8_t(g);
            BUF[base + 2] = uint8_t(b);
            BUF[base + 3] = uint8_t(a);
            ++pixels_written;
        }
    }

    auto t1 = std::chrono::high_resolution_clock::now();
    const double ms = std::chrono::duration<double, std::milli>(t1 - t0).count();
    out["elapsed_ms"] = ms;
    out["fallback"] = false;
    out["reason"] = String();
    out["pixels_written"] = pixels_written;
    out["atlas_buffer"] = c.buffer;
    out["new_veg"] = new_veg;
    out["new_vitality"] = new_vit;
    out["new_transition"] = new_tr;
    out["new_sigs"] = new_sigs;
    return out;
}

godot::Dictionary DCWorldExt::encode_dyn_smooth_atlas(godot::Dictionary knobs) {
    using godot::Dictionary;
    using godot::PackedByteArray;
    using godot::PackedInt32Array;
    using godot::String;
    using godot::StringName;

    Dictionary out;
    out["elapsed_ms"] = -1.0;
    out["fallback"] = true;
    out["reason"] = String();
    out["pixels_written"] = 0;

    auto fail = [&](const char *why) -> Dictionary {
        out["reason"] = String(why);
        UtilityFunctions::push_warning("[DCWorldExt] encode_dyn_smooth_atlas: ", why,
                                       " - fallback to GDScript");
        return out;
    };

    if (!_bound) return fail("not bound");

    auto c = parse_csr_common(knobs, 4);
    if (!c.valid) return fail(c.err);

    if (!knobs.has("neighbor_indices")) return fail("missing neighbor_indices");
    if (!knobs.has("cell_is_water")) return fail("missing cell_is_water");
    PackedInt32Array nb_arr = knobs["neighbor_indices"];
    PackedByteArray cell_iw = knobs["cell_is_water"];
    if (cell_iw.size() != c.K) return fail("cell_is_water size mismatch");
    const bool cache_valid = bool(knobs.get("cache_valid", false));
    PackedInt32Array prev_sigs;
    bool prev_sigs_usable = false;
    if (cache_valid && knobs.has("prev_sigs")) {
        prev_sigs = knobs["prev_sigs"];
        prev_sigs_usable = (prev_sigs.size() == c.K);
    }

    // sea-ice-render-source-unify 阶段 C：中心 cell + 邻居都需要“是否水域”进行
    // A 通道双语义判定 + 邻居均值分裂。调用方必须使用 is_water 语义（含
    // SEA_ICE）而非 passable_sea，否则 SEA_ICE cell 会被误归入陆格分支。
    // GDScript 端走 map.is_water_arr 或 MapData.is_water_lut() 填充。
    if (!knobs.has("neighbor_is_water")) return fail("missing neighbor_is_water");
    PackedByteArray nb_iw = knobs["neighbor_is_water"];
    if (nb_iw.size() != c.K * 6) return fail("neighbor_is_water size mismatch (need K*6)");
    const int sid_temp = component_id(StringName("cell_temp"));
    const int sid_moist = component_id(StringName("cell_moisture"));
    const int sid_snow = component_id(StringName("cell_snow_cover"));
    const int sid_vit = component_id(StringName("cell_vegetation_vitality"));
    // [sea-ice-render-source-unify 阶段 A] sig A 字节双语义需要 sea_ice_frac slot。
    const int sid_sif = component_id(StringName("cell_sea_ice_frac"));
    if (sid_temp < 0 || sid_moist < 0 || sid_snow < 0 || sid_vit < 0 || sid_sif < 0) {
        return fail("missing slot id (temp/moist/snow/vitality/sea_ice_frac)");
    }
    Slot &s_temp = _slots.write[sid_temp];
    Slot &s_moist = _slots.write[sid_moist];
    Slot &s_snow = _slots.write[sid_snow];
    Slot &s_vit = _slots.write[sid_vit];
    Slot &s_sif = _slots.write[sid_sif];
    const int n_cells = _entity_count;
    if (s_temp.arr_f32.size() < n_cells || s_moist.arr_f32.size() < n_cells ||
        s_snow.arr_f32.size() < n_cells || s_vit.arr_f32.size() < n_cells ||
        s_sif.arr_f32.size() < n_cells) {
        return fail("slot array size < entity_count");
    }
    if (nb_arr.size() < n_cells * 6) return fail("neighbor_indices size < n_cells*6");

    auto t0 = std::chrono::high_resolution_clock::now();

    const float * const __restrict TEMP = s_temp.arr_f32.ptr();
    const float * const __restrict MOIST = s_moist.arr_f32.ptr();
    const float * const __restrict SNOW = s_snow.arr_f32.ptr();
    const float * const __restrict VIT = s_vit.arr_f32.ptr();
    const float * const __restrict SIF = s_sif.arr_f32.ptr();
    const int32_t * const __restrict CELLS = c.cell_indices.ptr();
    const int32_t * const __restrict FIRST = c.first_px.ptr();
    const int32_t * const __restrict CNT = c.px_count.ptr();
    const int32_t * const __restrict FLAT = c.flat_px.ptr();
    const uint8_t * const __restrict PSEA = cell_iw.ptr();
    const uint8_t * const __restrict NB_PSEA = nb_iw.ptr();
    const int32_t * const __restrict NB = nb_arr.ptr();
    const int32_t * const __restrict PREV_SIGS = prev_sigs_usable ? prev_sigs.ptr() : nullptr;
    uint8_t * const __restrict BUF = c.buffer.ptrw();

    PackedInt32Array new_sigs; new_sigs.resize(c.K); int32_t * const SIGS = new_sigs.ptrw();

    // 内联 sig 计算（与 _dynamic_cell_signature 等价）：
    //   r=q01(temp), g=q01(moist), b=q01(snow)
    //   [sea-ice-render-source-unify 阶段 C] A 通道双语义：
    //     水格 (is_water=true)：a = q01_byte_ice(sea_ice_frac)
    //     陆格 (is_water=false)：a = q01_byte(vit)
    //   is_water 语义含 SEA_ICE，不同于只看航行性的 passable_sea。
    auto sig_of = [&](int idx, bool iw) -> uint32_t {
        const int r = pk_q01_byte(double(TEMP[idx]));
        const int g = pk_q01_byte(double(MOIST[idx]));
        const int b = pk_q01_byte(double(SNOW[idx]));
        const int a = iw
            ? pk_q01_byte_ice(double(SIF[idx]))
            : pk_q01_byte(double(VIT[idx]));
        return uint32_t(r) | (uint32_t(g) << 8) | (uint32_t(b) << 16) | (uint32_t(a) << 24);
    };

    int pixels_written = 0;
    for (int k = 0; k < c.K; ++k) {
        const int ci = CELLS[k];
        if (ci < 0 || ci >= n_cells) { SIGS[k] = 0; continue; }

        const uint32_t c_sig = sig_of(ci, PSEA[k] != 0);
        const int cr = int(c_sig & 0xFF);
        const int cg = int((c_sig >> 8) & 0xFF);
        const int cb = int((c_sig >> 16) & 0xFF);
        const int ca = int((c_sig >> 24) & 0xFF);
        const bool center_is_water = (PSEA[k] != 0);

        // FNV-1a 32-bit hood hash（中心 + 邻居各 4 byte），与 GDScript 1:1 镜像。
        uint32_t hood_h = 0x811C9DC5u;
        hood_h = (hood_h ^ uint32_t(cr)) * 0x01000193u;
        hood_h = (hood_h ^ uint32_t(cg)) * 0x01000193u;
        hood_h = (hood_h ^ uint32_t(cb)) * 0x01000193u;
        hood_h = (hood_h ^ uint32_t(ca)) * 0x01000193u;

        int nr = 0, ng = 0, nb_sum = 0, na = 0, nc = 0, na_c = 0;
        const int nb_base_global = ci * 6;
        const int nb_base_local = k * 6;
        for (int d = 0; d < 6; ++d) {
            const int32_t ni = NB[nb_base_global + d];
            if (ni < 0 || ni >= n_cells) continue;
            const bool n_psea = (NB_PSEA[nb_base_local + d] != 0);
            const uint32_t n_sig = sig_of(int(ni), n_psea);
            const int nrb = int(n_sig & 0xFF);
            const int ngb = int((n_sig >> 8) & 0xFF);
            const int nbb = int((n_sig >> 16) & 0xFF);
            const int nab = int((n_sig >> 24) & 0xFF);
            nr += nrb; ng += ngb; nb_sum += nbb; nc += 1;
            // ─────────────────────────────────────────────────────────
            // [sea-ice-render-source-unify 阶段 A] A 通道水陆分裂平均：
            //   - 中心陆格：A=vit，仅累加陆地邻居（海邻 A=ice_byte 与 vit 异语义）。
            //   - 中心水格：A=sea_ice_frac，仅累加水域邻居（陆邻 A=vit 与 ice 异语义）。
            // 历史背景（2026-05-21 修复）：陆地 A 累加海邻会被海格 0 系统性拖低；
            // 现海格 A 不再为 0 而是 ice_byte，必须更严格地按语义同类分组。
            // SAME_SOURCE：scripts/rendering/map_baker.gd::dyn_atlas_smooth_chunk_step。
            // ─────────────────────────────────────────────────────────
            if (center_is_water) {
                if (n_psea) { na += nab; na_c += 1; }
            } else {
                if (!n_psea) { na += nab; na_c += 1; }
            }
            hood_h = (hood_h ^ uint32_t(nrb)) * 0x01000193u;
            hood_h = (hood_h ^ uint32_t(ngb)) * 0x01000193u;
            hood_h = (hood_h ^ uint32_t(nbb)) * 0x01000193u;
            hood_h = (hood_h ^ uint32_t(nab)) * 0x01000193u;
        }

        SIGS[k] = int32_t(hood_h);
        if (PREV_SIGS != nullptr && uint32_t(PREV_SIGS[k]) == hood_h) {
            continue;
        }

        int or_, og, ob, oa;
        if (nc > 0) {
            // 中心 0.5 + 邻居均值 0.5；GDScript 用 int 除法，C++ 必须镜像同语义。
            // (cr + nr / nc) / 2，全部 int 截断除。
            // ─────────────────────────────────────────────────────────
            // 2026-05-21 修复 (issue: 95% 雪盖在屏幕上不可见)：
            // B 通道（snow_cover）是「阈值型」现象——单格可在雪线之上而所有
            // 邻居都在雪线之下；它不是温度/湿度那样的连续梯度场，不应参与
            // box blur，否则 95% 的真值被邻居 0 拖到 ~47.5% 直接被后段
            // smoothstep 压成几乎不可见。R/G/A 仍走原有 box blur 逻辑以保留
            // 温度/湿度/植被活力沿 hex 边界的平滑过渡。SAME_SOURCE 兜底见
            // map_baker.gd::dyn_atlas_smooth_chunk_step。
            // 2026-05-21 D 项追加：A 通道仅平均"非海域邻居"，详见上方
            // for 循环内的注释。海岸陆地 cell 不再被海洋 0 系统性拖低。
            // ─────────────────────────────────────────────────────────
            const int t1 = cr + (nr / nc);
            const int t2 = cg + (ng / nc);
            or_ = t1 / 2; og = t2 / 2;
            ob = cb;  // snow passthrough：保留 cell 真值，不做邻居平均。
            // A 通道：用陆地邻居数 na_c 做平均；陆地 cell 全是海邻（na_c=0）
            // 时退回中心值，避免除 0 也避免被 0 邻居拖低。
            if (na_c > 0) {
                const int t4 = ca + (na / na_c);
                oa = t4 / 2;
            } else {
                oa = ca;
            }
            if (or_ < 0) or_ = 0; else if (or_ > 255) or_ = 255;
            if (og < 0) og = 0; else if (og > 255) og = 255;
            if (ob < 0) ob = 0; else if (ob > 255) ob = 255;
            if (oa < 0) oa = 0; else if (oa > 255) oa = 255;
        } else {
            or_ = cr; og = cg; ob = cb; oa = ca;
        }

        const int first = FIRST[k];
        const int count = CNT[k];
        for (int p = 0; p < count; ++p) {
            const int px_idx = FLAT[first + p];
            if (px_idx < 0 || px_idx >= c.n_pix) continue;
            const int base = px_idx * 4;
            BUF[base    ] = uint8_t(or_);
            BUF[base + 1] = uint8_t(og);
            BUF[base + 2] = uint8_t(ob);
            BUF[base + 3] = uint8_t(oa);
            ++pixels_written;
        }
    }

    auto t1 = std::chrono::high_resolution_clock::now();
    const double ms = std::chrono::duration<double, std::milli>(t1 - t0).count();
    out["elapsed_ms"] = ms;
    out["fallback"] = false;
    out["reason"] = String();
    out["pixels_written"] = pixels_written;
    out["atlas_buffer"] = c.buffer;
    out["new_sigs"] = new_sigs;
    return out;
}

godot::Dictionary DCWorldExt::encode_ice_state_atlas(godot::Dictionary knobs) {
    using godot::Dictionary;
    using godot::PackedByteArray;
    using godot::PackedInt32Array;
    using godot::String;
    using godot::StringName;

    Dictionary out;
    out["elapsed_ms"] = -1.0;
    out["fallback"] = true;
    out["reason"] = String();
    out["pixels_written"] = 0;

    auto fail = [&](const char *why) -> Dictionary {
        out["reason"] = String(why);
        UtilityFunctions::push_warning("[DCWorldExt] encode_ice_state_atlas: ", why,
                                       " - fallback to GDScript");
        return out;
    };

    if (!_bound) return fail("not bound");

    auto c = parse_csr_common(knobs, 1);  // R8 = 1 byte/pixel
    if (!c.valid) return fail(c.err);

    const int sid_ice = component_id(StringName("cell_sea_ice_frac"));
    if (sid_ice < 0) return fail("missing slot id cell_sea_ice_frac");
    Slot &s_ice = _slots.write[sid_ice];
    const int n_cells = _entity_count;
    if (s_ice.arr_f32.size() < n_cells) return fail("sea_ice_frac slot too small");

    auto t0 = std::chrono::high_resolution_clock::now();

    // ICE 指针保留 volatile：Apple Clang 在 ARM64 对 PackedFloat32Array.ptr()
    // 返回值做 alias-based DCE，加 volatile 强制每次 ICE[i] 从内存重读。
    // （process_atlas_pipeline_step 里 ICE phase 已改为完全内联编码循环，
    //  本函数仅作为非热路径 caller 的 fallback 入口。）
    const volatile float * const ICE = s_ice.arr_f32.ptr();

    const int32_t * const CELLS = c.cell_indices.ptr();
    const int32_t * const FIRST = c.first_px.ptr();
    const int32_t * const CNT = c.px_count.ptr();
    const int32_t * const FLAT = c.flat_px.ptr();
    uint8_t * const BUF = c.buffer.ptrw();

    PackedByteArray new_bytes; new_bytes.resize(c.K); uint8_t * const NB_OUT = new_bytes.ptrw();

    int pixels_written = 0;

    // ★ 优先用调用方预打包好的 cell_ice_values（K 个值，按 CELLS 顺序）。
    // 这条路径绕过 encode 内部对 ICE slot 的间接读，避免 Apple Clang ARM64
    // 在 ICE2[CELLS[k]] 这种间接索引上做的激进 alias DCE。
    bool have_iv = false;
    PackedFloat32Array iv_arr;
    if (knobs.has("cell_ice_values")) {
        iv_arr = knobs["cell_ice_values"];
        have_iv = (iv_arr.size() >= c.K);
    }
    const float * const IV = have_iv ? iv_arr.ptr() : nullptr;

    for (int k = 0; k < c.K; ++k) {
        const int ci = CELLS[k];
        if (ci < 0 || ci >= n_cells) { NB_OUT[k] = 0; continue; }
        const float ice_v = have_iv ? IV[k] : ICE[ci];
        const int byte_v = pk_q01_byte_ice(double(ice_v));
        NB_OUT[k] = uint8_t(byte_v);
        const int first = FIRST[k];
        const int count = CNT[k];
        for (int p = 0; p < count; ++p) {
            const int px_idx = FLAT[first + p];
            if (px_idx < 0 || px_idx >= c.n_pix) continue;
            BUF[px_idx] = uint8_t(byte_v);
            ++pixels_written;
        }
    }

    auto t1 = std::chrono::high_resolution_clock::now();
    const double ms = std::chrono::duration<double, std::milli>(t1 - t0).count();
    out["elapsed_ms"] = ms;
    out["fallback"] = false;
    out["reason"] = String();
    out["pixels_written"] = pixels_written;
    out["atlas_buffer"] = c.buffer;
    // ice atlas 走 cell_byte cache（见 _last_ice_state_cell_bytes），返回 PackedByteArray
    out["new_bytes"] = new_bytes;
    return out;
}

// ────────────────────────────────────────────────────────────────────────────
// plan/debug-overlay-perf v2（2026-06-12）：Debug Data Overlay pixel fan-out 下沉 C++
//   data_overlay_baker.gd 把 18 个 overlay mode 的 per-cell 采样结果（R/G byte +
//   有效标记）按 cell.index 打包传入，本方法负责清零 buffer + 把每个有效 cell
//   的 (R, G, 0, 255) 扇出写到它覆盖的全部像素。镜像 GDScript 内层像素循环，
//   与之 byte-for-byte 等价。协议详见 world_ext.h::encode_overlay_atlas。
// ────────────────────────────────────────────────────────────────────────────
godot::Dictionary DCWorldExt::encode_overlay_atlas(godot::Dictionary knobs) {
    using godot::Dictionary;
    using godot::PackedByteArray;
    using godot::PackedInt32Array;
    using godot::String;

    Dictionary out;
    out["elapsed_ms"] = -1.0;
    out["fallback"] = true;
    out["reason"] = String();
    out["pixels_written"] = 0;

    auto fail = [&](const char *why) -> Dictionary {
        out["reason"] = String(why);
        return out;
    };

    // 本 pass 不读 _slots，无需 _bound：overlay 数据全部由 GDScript 预采样喂入。
    if (!knobs.has("n_pix") || !knobs.has("n_cells") ||
        !knobs.has("atlas_buffer") || !knobs.has("cell_first_px") ||
        !knobs.has("cell_px_count") || !knobs.has("flat_px_indices") ||
        !knobs.has("cell_r") || !knobs.has("cell_g") || !knobs.has("cell_valid")) {
        return fail("missing required overlay knob");
    }

    const int n_pix = int(knobs["n_pix"]);
    const int n_cells = int(knobs["n_cells"]);
    if (n_pix <= 0) return fail("n_pix <= 0");
    if (n_cells <= 0) return fail("n_cells <= 0");

    PackedByteArray buffer = knobs["atlas_buffer"];
    if (int64_t(buffer.size()) != int64_t(n_pix) * 4) {
        return fail("atlas_buffer size mismatch");
    }

    PackedInt32Array first_px = knobs["cell_first_px"];
    PackedInt32Array px_count = knobs["cell_px_count"];
    PackedInt32Array flat_px = knobs["flat_px_indices"];
    PackedByteArray cell_r = knobs["cell_r"];
    PackedByteArray cell_g = knobs["cell_g"];
    PackedByteArray cell_valid = knobs["cell_valid"];

    if (first_px.size() < n_cells || px_count.size() < n_cells) {
        return fail("cell CSR array size < n_cells");
    }
    if (cell_r.size() < n_cells || cell_g.size() < n_cells ||
        cell_valid.size() < n_cells) {
        return fail("per-cell byte array size < n_cells");
    }

    auto t0 = std::chrono::high_resolution_clock::now();

    const int32_t * const __restrict FIRST = first_px.ptr();
    const int32_t * const __restrict CNT = px_count.ptr();
    const int32_t * const __restrict FLAT = flat_px.ptr();
    const int flat_n = flat_px.size();
    const uint8_t * const __restrict R = cell_r.ptr();
    const uint8_t * const __restrict G = cell_g.ptr();
    const uint8_t * const __restrict VALID = cell_valid.ptr();
    uint8_t * const __restrict BUF = buffer.ptrw();

    // 默认全像素清零：alpha=0（无效/未覆盖 → shader 渲染中性/透明）。
    // memset 比 GDScript PackedByteArray.fill(0) 略快，且让本方法自给自足。
    std::memset(BUF, 0, size_t(n_pix) * 4);

    int pixels_written = 0;
    for (int ci = 0; ci < n_cells; ++ci) {
        if (VALID[ci] == 0) continue;
        const int first = FIRST[ci];
        const int count = CNT[ci];
        if (first < 0 || count <= 0) continue;
        const uint8_t r = R[ci];
        const uint8_t g = G[ci];
        for (int p = 0; p < count; ++p) {
            const int fi = first + p;
            if (fi < 0 || fi >= flat_n) continue;
            const int px_idx = FLAT[fi];
            if (px_idx < 0 || px_idx >= n_pix) continue;
            const int base = px_idx * 4;
            BUF[base    ] = r;
            BUF[base + 1] = g;
            BUF[base + 2] = 0;
            BUF[base + 3] = 255;
            ++pixels_written;
        }
    }

    auto t1 = std::chrono::high_resolution_clock::now();
    const double ms = std::chrono::duration<double, std::milli>(t1 - t0).count();
    out["elapsed_ms"] = ms;
    out["fallback"] = false;
    out["reason"] = String();
    out["pixels_written"] = pixels_written;
    out["atlas_buffer"] = buffer;
    return out;
}

// ────────────────────────────────────────────────────────────────────────────
// plan/atlas-pipeline-cpp（2026-05-20）：4 张运行期视觉 atlas 全管线 C++ 主入口
//
// 设计要点（复用最大化）：
//   1) 4 张 atlas 的 byte-fill / sig 计算继续走现有 encode_* 函数（已 bit-equal
//      验证通过，sig 算法 100% 与 GDScript 镜像）。
//   2) 本入口承担 GD 端原 atlas_upload_system / map_baker.gd 的 调度 + dirty 消费
//      + value-diff + 1-跳膨胀 + ecology decay 合并 + CSR 打包构造 knobs。
//   3) prev_sigs / ecology 持久状态完全由 AtlasPipelineState 持有，跨 stride 复用，
//      消除原 GDScript Dictionary[HexCell→int] 的 hash 开销。
//   4) 4 phase 状态机内置 C++：单次 run_atlas_pipeline_step 默认一气呵成跑完
//      4 phase（soft_budget_us 是软门槛，不强制切分；GD 调一次拿 4 张 buffer）。
//      若需要时间切片，opts["enable_phase_slicing"] = true 时退化到 phase-by-phase
//      模式（每次调用前进一个 phase，与 GD 旧 4-phase 状态机调用对齐）。
// ────────────────────────────────────────────────────────────────────────────

namespace {

// 获取或创建 AtlasPipelineState（lazy alloc 模式，与 WeatherSummaryState 同构）。
inline AtlasPipelineState *get_or_create_atlas_state(void *&p) {
    if (p == nullptr) {
        p = new AtlasPipelineState();
    }
    return static_cast<AtlasPipelineState *>(p);
}

// 与 GDScript map_baker.gd::_dynamic_cell_signature 1:1 镜像
// （sea-ice-render-source-unify 阶段 C 修订）：
//   r=q01(temp), g=q01(moist), b=q01(snow)
//   A 通道双语义：
//     水格 (is_water=true)：a = q01_byte_ice(sea_ice_frac)
//     陆格 (is_water=false)：a = q01_byte(vit)
// 关键：判定"水格"必须用 is_water 语义（含 SEA_ICE 等所有非陆地），
// 不能用 passable_sea（SEA_ICE 因冰面阻断航行 passable_sea=false 但
// 视觉上仍是水域，A 通道必须写 ice_byte 让 shader 水路径渲染冰）。
inline uint32_t pk_atlas_sig_dynamic(double temp, double moist, double snow,
                                     double vit, double sea_ice_frac, bool is_water) {
    const int r = pk_q01_byte(temp);
    const int g = pk_q01_byte(moist);
    const int b = pk_q01_byte(snow);
    const int a = is_water ? pk_q01_byte_ice(sea_ice_frac) : pk_q01_byte(vit);
    return uint32_t(r) | (uint32_t(g) << 8) | (uint32_t(b) << 16) | (uint32_t(a) << 24);
}

// 与 GDScript map_baker.gd::_ecology_visual_signature / 本文件
// encode_ecology_visual_atlas（14399-14440 行）1:1 镜像。提炼成可复用 helper，
// 供 cell-index 间接寻址 LUT 路径（encode_cell_luts）与现有 fan-out 路径共用同一公式，
// 保证 eco_lut 与 ecology_visual_atlas bit-equivalent。
//   r=q01(foliage), g=q01(stress), b=transition_age(byte), a=q01(growth_damage)
inline uint32_t pk_atlas_sig_ecology(double temp, double moist, double snow,
                                     double vit, int veg_id, bool is_water,
                                     int transition_age, int prev_vit_byte,
                                     int veg_none) {
    auto smoothstep = [](double e0, double e1, double x) {
        if (e1 <= e0) return x < e0 ? 0.0 : 1.0;
        double t = (x - e0) / (e1 - e0);
        if (t < 0.0) t = 0.0;
        else if (t > 1.0) t = 1.0;
        return t * t * (3.0 - 2.0 * t);
    };
    auto clamp01 = [](double v) { return v < 0.0 ? 0.0 : (v > 1.0 ? 1.0 : v); };
    const double vitality = clamp01(vit);
    const double m = clamp01(moist);
    const double t = clamp01(temp);
    const double sn = clamp01(snow);
    double foliage = 0.0;
    if (!is_water && veg_id != veg_none) {
        const double cold_loss = (1.0 - smoothstep(0.02, 0.18, t)) * 0.55;
        const double snow_loss = smoothstep(0.12, 0.75, sn) * 0.70;
        const double dry_loss = (1.0 - smoothstep(0.05, 0.35, m)) * 0.45;
        foliage = clamp01(vitality * 0.72 + m * 0.28 - cold_loss - snow_loss - dry_loss);
    }
    double stress = 0.0;
    if (!is_water) {
        const double dryness = 1.0 - m;
        const double heat_stress = smoothstep(0.72, 0.95, t);
        const double cold_stress = 1.0 - smoothstep(0.03, 0.20, t);
        const double vit_stress = 1.0 - vitality;
        const double a1 = dryness * 0.70;
        const double a2 = (heat_stress > cold_stress ? heat_stress : cold_stress) * 0.65;
        const double a3 = (a1 > a2 ? a1 : a2);
        stress = clamp01(a3 + vit_stress * 0.45);
    }
    const double vit_delta = (double(pk_q01_byte(vitality)) - double(prev_vit_byte)) / 255.0;
    const double growth = clamp01(0.5 + vit_delta * 5.0 + (foliage - 0.5) * 0.12 - stress * 0.10);
    const int r = pk_q01_byte(foliage);
    const int g = pk_q01_byte(stress);
    int b = transition_age;
    if (b < 0) b = 0;
    else if (b > 255) b = 255;
    const int a = pk_q01_byte(growth);
    return uint32_t(r) | (uint32_t(g) << 8) | (uint32_t(b) << 16) | (uint32_t(a) << 24);
}

// ice byte：与 GDScript _q01_byte_ice 完全一致（v>0 时 byte≥1）。
inline uint8_t pk_atlas_byte_ice(double v) {
    return uint8_t(pk_q01_byte_ice(v));
}

// 从 World 节点拉 SoA 字段：用 .get(StringName) 反射读 PackedXxxArray。
// 与 GDScript map_baker.gd::_pack_csr_for_cells 的 SoA fast path 等价。
struct WorldSoARefs {
    bool                ok = false;
    int                 n_cells = 0;
    PackedInt32Array    cell_first_px;
    PackedInt32Array    cell_px_count;
    PackedInt32Array    flat_px_indices;
    PackedByteArray     terrain_arr;        // 用于 LUT 查 passable_sea / is_water
    PackedByteArray     passable_sea_lut;   // 256 byte LUT (航行性语义)
    PackedByteArray     is_water_lut;       // 256 byte LUT (视觉水陆语义，含 SEA_ICE)
    bool                have_lut = false;
    Dictionary          water_cell_pixel_lists; // 仅 ice phase 用 (HexCell key 无法 SoA 化)
    bool                have_water_lists = false;
};

inline WorldSoARefs fetch_world_soa(Object *world, Object *map) {
    WorldSoARefs r;
    if (world == nullptr) return r;
    Variant v_first = world->get(StringName("cell_first_px_arr"));
    Variant v_count = world->get(StringName("cell_px_count_arr"));
    Variant v_flat  = world->get(StringName("flat_px_indices_arr"));
    if (v_first.get_type() != Variant::PACKED_INT32_ARRAY ||
        v_count.get_type() != Variant::PACKED_INT32_ARRAY ||
        v_flat.get_type()  != Variant::PACKED_INT32_ARRAY) {
        return r;
    }
    r.cell_first_px = v_first;
    r.cell_px_count = v_count;
    r.flat_px_indices = v_flat;
    r.n_cells = r.cell_first_px.size();
    if (r.n_cells <= 0) return r;
    if (map != nullptr) {
        Variant v_terr = map->get(StringName("terrain_arr"));
        if (v_terr.get_type() == Variant::PACKED_BYTE_ARRAY) {
            r.terrain_arr = v_terr;
        }
        // MapData.passable_sea_lut() 是 static method；走 .call("passable_sea_lut")
        Variant v_lut = map->call(StringName("passable_sea_lut"));
        if (v_lut.get_type() == Variant::PACKED_BYTE_ARRAY) {
            r.passable_sea_lut = v_lut;
        }
        // sea-ice-render-source-unify 阶段 D：渲染语义专用 LUT（含 SEA_ICE）
        // 取代 is_water_lut——后者是通行性语义，把 SEA_ICE 当陆，会让 atlas 走错分支。
        Variant v_iwlut = map->call(StringName("is_water_render_lut"));
        if (v_iwlut.get_type() == Variant::PACKED_BYTE_ARRAY) {
            r.is_water_lut = v_iwlut;
        }
        r.have_lut = (r.terrain_arr.size() == r.n_cells &&
                      r.passable_sea_lut.size() >= 256 &&
                      r.is_water_lut.size() >= 256);
    }
    Variant v_wpl = world->get(StringName("water_cell_pixel_lists"));
    if (v_wpl.get_type() == Variant::DICTIONARY) {
        r.water_cell_pixel_lists = v_wpl;
        r.have_water_lists = !r.water_cell_pixel_lists.is_empty();
    }
    r.ok = true;
    return r;
}

// ── stride 工作集打包：把 dirty cell.index 集合 + ecology decay + 1 跳邻居膨胀 ──
// 全部走 PackedByteArray 'seen' 标记，避免重复，最终输出"按升序的 cell.index 数组"。

// 4 个 atlas 的工作集（每 stride 重建）。
struct AtlasWorkSets {
    PackedInt32Array dyn_real;   // dirty ∩ (sig 与 prev_sigs_dyn 不同)
    PackedInt32Array eco_real;   // dirty ∪ active_decay（cache_invalid 时全集 → 由调用方处理）
    PackedInt32Array smo_real;   // (eco_real ∪ dirty) 1-跳邻居膨胀
    PackedInt32Array ice_real;   // dirty ∩ water_cells
};

} // anonymous namespace

// 公开入口：使 csr_cache + prev_sigs 失效（地图重生成时由 GD 调）。
void DCWorldExt::invalidate_atlas_csr_cache() {
    if (_atlas_state == nullptr) return;
    auto *st = static_cast<AtlasPipelineState *>(_atlas_state);
    st->csr_first_px = PackedInt32Array();
    st->csr_px_count = PackedInt32Array();
    st->csr_flat_px = PackedInt32Array();
    st->csr_valid = false;
    st->prev_sigs_dyn = PackedInt32Array();
    st->prev_sigs_eco = PackedInt32Array();
    st->prev_sigs_smo = PackedInt32Array();
    st->prev_sigs_ice = PackedInt32Array();
    st->eco_foliage = PackedFloat32Array();
    st->eco_stress = PackedFloat32Array();
    st->eco_transition_age = PackedFloat32Array();
    st->eco_growth_damage = PackedFloat32Array();
    st->eco_active_decay_indices = PackedInt32Array();
    // Cell-index 间接寻址 LUT 持久状态同步失效（地图重生成 → cell.index 重排）。
    st->lut_initialized = false;
    st->lut_prev_veg = PackedByteArray();
    st->lut_prev_vit = PackedByteArray();
    st->lut_transition_age = PackedByteArray();
    st->lut_enum_data = PackedByteArray();
    st->lut_dyn_data = PackedByteArray();
    st->lut_eco_data = PackedByteArray();
    st->lut_weather_data = PackedByteArray();
    st->lut_active_transition_indices = PackedInt32Array();
    st->phase = AtlasPipelineState::IDLE;
    st->cursor = 0;
}

// 公开入口：一次性把 GD 端 ecology 持久状态迁过来。
// state Dict 字段：
//   "veg_bytes"          : PackedByteArray  (per cell, 0..255 vegetation enum byte) [可选]
//   "vitality_bytes"     : PackedByteArray  (per cell, q01 byte)                    [可选]
//   "transition_age"     : PackedByteArray  (per cell, byte 0..255)                 [可选]
//   "active_decay"       : PackedInt32Array (active decay set 的 cell.index 列表)   [可选]
// 对应 AtlasPipelineState 字段：veg/vitality 用 prev_sigs_eco 已经隐含，本接口
// 主要保留 transition_age 和 active_decay（其余字段冷启首帧自动从 SoA cur 灌入）。
void DCWorldExt::migrate_eco_persistent_from_gd(godot::Dictionary state) {
    auto *st = get_or_create_atlas_state(_atlas_state);
    // transition_age 用 PackedFloat32Array 持有（保留 byte 精度但避免 byte→float 反复转换）
    if (state.has("transition_age")) {
        Variant v = state["transition_age"];
        if (v.get_type() == Variant::PACKED_BYTE_ARRAY) {
            PackedByteArray pba = v;
            st->eco_transition_age.resize(pba.size());
            float *p = st->eco_transition_age.ptrw();
            const uint8_t *src = pba.ptr();
            for (int i = 0; i < pba.size(); ++i) p[i] = float(src[i]);
        } else if (v.get_type() == Variant::PACKED_FLOAT32_ARRAY) {
            st->eco_transition_age = v;
        }
    }
    if (state.has("active_decay")) {
        Variant v = state["active_decay"];
        if (v.get_type() == Variant::PACKED_INT32_ARRAY) {
            st->eco_active_decay_indices = v;
        }
    }
    // foliage / stress / growth_damage 通常无需迁移（首帧从 SoA 计算）；
    // 仍保留可选迁移路径以备 future bit-equal 校验。
    if (state.has("foliage")) {
        Variant v = state["foliage"];
        if (v.get_type() == Variant::PACKED_FLOAT32_ARRAY) st->eco_foliage = v;
    }
    if (state.has("stress")) {
        Variant v = state["stress"];
        if (v.get_type() == Variant::PACKED_FLOAT32_ARRAY) st->eco_stress = v;
    }
    if (state.has("growth_damage")) {
        Variant v = state["growth_damage"];
        if (v.get_type() == Variant::PACKED_FLOAT32_ARRAY) st->eco_growth_damage = v;
    }
}

// ────────────────────────────────────────────────────────────────────────────
// Cell-index 间接寻址（province-ID indirection）：per-cell LUT 编码
// ────────────────────────────────────────────────────────────────────────────
// SAME_SOURCE: map_baker.gd::bake_cell_luts / _bake_cell_luts_gd（GDScript fallback）。
// 本方法把"每 cell 一个 texel"的 enum/dyn/eco LUT 编码搬进 C++ 热路径——即便
// n_cells≈2400，也走 scalar C++ tight loop（用户决策 2026-06-16：严格按 skill 在
// CPP 做），与 fan-out 路径共用 pk_atlas_sig_dynamic / pk_atlas_sig_ecology 公式，
// 保证 LUT 与全分辨率 atlas bit-equivalent。
//
// 输出 3 张 LUT（行优先，宽 lut_w；texel ci 落在 (ci%lut_w, ci/lut_w)，
// 即扁平偏移恰为 ci）：
//   enum_lut : RGBA8 R=terrain G=vegetation B=cover A=迷雾知识度 k（0..255）
//   dyn_lut  : RGBA8 R=q01(temp) G=q01(moist) B=q01(snow) A=水:q01_ice(sif)/陆:q01(vit)
//   eco_lut  : RGBA8 R=q01(foliage) G=q01(stress) B=transition_age A=q01(growth)
//
// opts 字段：
//   "map"             : Object（取 is_water_render_lut；缺则 fallback）
//   "lut_w"/"lut_h"   : int（LUT 网格尺寸，lut_w*lut_h >= n_cells）
//   "n_cells"         : int（map.cell_count()）
//   "terrain_lake"/"terrain_sea_ice"/"veg_none" : int（eco is_water / VEG_NONE 透传）
//   "cache_valid"     : bool（true=日常 refresh，按 prev 推进 transition；
//                             false=初次 bake，transition 归零）
// 返回：{ enum_lut, dyn_lut, eco_lut, lut_w, lut_h, n_cells, elapsed_ms,
//         fallback, reason, path, published_to_slot=false }
godot::Dictionary DCWorldExt::encode_cell_luts(godot::Dictionary opts) {
    using godot::Dictionary;
    using godot::PackedByteArray;
    using godot::String;
    using godot::StringName;

    Dictionary out;
    out["fallback"] = true;
    out["reason"] = String();
    out["elapsed_ms"] = -1.0;
    out["path"] = String("gdscript");
    out["published_to_slot"] = false;

    auto fail = [&](const char *why) -> Dictionary {
        out["reason"] = String(why);
        UtilityFunctions::push_warning("[DCWorldExt] encode_cell_luts: ", why,
                                       " - fallback to GDScript");
        return out;
    };

    if (!_bound) return fail("not bound");
    if (!opts.has("lut_w") || !opts.has("lut_h")) return fail("missing lut dims");
    const int lut_w = int(opts["lut_w"]);
    const int lut_h = int(opts["lut_h"]);
    if (lut_w <= 0 || lut_h <= 0) return fail("invalid lut dims");
    const int n_cells = opts.has("n_cells") ? int(opts["n_cells"]) : 0;
    if (n_cells <= 0) return fail("missing n_cells");
    const int slots_total = lut_w * lut_h;
    if (slots_total < n_cells) return fail("lut grid smaller than n_cells");

    Object *map = opts.has("map") ? Object::cast_to<Object>(opts["map"]) : nullptr;

    // SoA 槽位（与 run_atlas_pipeline_step / encode_ecology_visual_atlas 同源）。
    const int sid_temp = component_id(StringName("cell_temp"));
    const int sid_moist = component_id(StringName("cell_moisture"));
    const int sid_snow = component_id(StringName("cell_snow_cover"));
    const int sid_vit = component_id(StringName("cell_vegetation_vitality"));
    const int sid_ice = component_id(StringName("cell_sea_ice_frac"));
    const int sid_terr = component_id(StringName("cell_terrain"));
    const int sid_veg = component_id(StringName("cell_vegetation"));
    const int sid_cover = component_id(StringName("cell_cover"));
    if (sid_temp < 0 || sid_moist < 0 || sid_snow < 0 || sid_vit < 0 ||
        sid_ice < 0 || sid_terr < 0 || sid_veg < 0 || sid_cover < 0) {
        return fail("missing component slot");
    }
    Slot &s_temp = _slots.write[sid_temp];
    Slot &s_moist = _slots.write[sid_moist];
    Slot &s_snow = _slots.write[sid_snow];
    Slot &s_vit = _slots.write[sid_vit];
    Slot &s_ice = _slots.write[sid_ice];
    Slot &s_terr = _slots.write[sid_terr];
    Slot &s_veg = _slots.write[sid_veg];
    Slot &s_cover = _slots.write[sid_cover];
    if (s_temp.arr_f32.size() < n_cells || s_moist.arr_f32.size() < n_cells ||
        s_snow.arr_f32.size() < n_cells || s_vit.arr_f32.size() < n_cells ||
        s_ice.arr_f32.size() < n_cells || s_terr.arr_u8.size() < n_cells ||
        s_veg.arr_u8.size() < n_cells || s_cover.arr_u8.size() < n_cells) {
        return fail("slot array size < n_cells");
    }
    const float * const __restrict TEMP = s_temp.arr_f32.ptr();
    const float * const __restrict MOIST = s_moist.arr_f32.ptr();
    const float * const __restrict SNOW = s_snow.arr_f32.ptr();
    const float * const __restrict VIT = s_vit.arr_f32.ptr();
    const float * const __restrict ICE = s_ice.arr_f32.ptr();
    const uint8_t * const __restrict TERR = s_terr.arr_u8.ptr();
    const uint8_t * const __restrict VEG = s_veg.arr_u8.ptr();
    const uint8_t * const __restrict COVER = s_cover.arr_u8.ptr();

    // Visual snow is a render-facing field that weather/climate already flushes to
    // MapData. Use an explicit snapshot when provided instead of globally refreshing
    // every slot and risking overwriting native-only climate values with stale mirrors.
    PackedFloat32Array snow_override = opts.get("snow_cover_arr", PackedFloat32Array());
    const bool snow_override_valid = snow_override.size() >= n_cells;
    const float * const __restrict SNOW_VIS =
        snow_override_valid ? snow_override.ptr() : SNOW;

    // 迷雾知识度 k（VisionSolver 产出的 blur 后 per-cell 字节）走 enum_lut 的 A
    // 通道。之所以显式传数组而不是读 slot：vision 的权威实现目前在 GDScript，
    // 而 refresh_slots_from_map() 会把所有 slot 都从 MapData 拉一遍，可能用陈旧
    // 镜像覆盖 native-only 的气候值 —— 与上面 snow_cover_arr 同一个理由。
    // 未提供时 A 通道保持 255（全知），保证迷雾系统未接线时视觉不变。
    PackedByteArray fog_k = opts.get("fog_k_arr", PackedByteArray());
    const bool fog_k_valid = fog_k.size() >= n_cells;
    const uint8_t * const __restrict FOGK = fog_k_valid ? fog_k.ptr() : nullptr;
    int snow_slot_diff_count = 0;
    double snow_slot_diff_sum = 0.0;
    double snow_slot_diff_max = 0.0;

    // weather LUT 槽位（软依赖）：天气未初始化 / weather_field 未启用时这些 slot 可能
    // size < n_cells；此时 weather_lut 整段保持 0（云不显示），但 enum/dyn/eco 仍正常，
    // 不让整张 LUT 回退 GDScript。
    const int sid_w_type = component_id(StringName("cell_weather_type"));
    const int sid_w_int = component_id(StringName("cell_weather_intensity"));
    const int sid_w_cloud = component_id(StringName("cell_weather_cloud"));
    const int sid_w_vapor = component_id(StringName("cell_weather_vapor"));
    const uint8_t * __restrict WTYPE = nullptr;
    const float * __restrict WINT = nullptr;
    const float * __restrict WCLOUD = nullptr;
    const float * __restrict WVAPOR = nullptr;
    if (sid_w_type >= 0 && sid_w_int >= 0 && sid_w_cloud >= 0 && sid_w_vapor >= 0) {
        Slot &s_wt = _slots.write[sid_w_type];
        Slot &s_wi = _slots.write[sid_w_int];
        Slot &s_wc = _slots.write[sid_w_cloud];
        Slot &s_wv = _slots.write[sid_w_vapor];
        if (s_wt.arr_u8.size() >= n_cells && s_wi.arr_f32.size() >= n_cells &&
            s_wc.arr_f32.size() >= n_cells && s_wv.arr_f32.size() >= n_cells) {
            WTYPE = s_wt.arr_u8.ptr();
            WINT = s_wi.arr_f32.ptr();
            WCLOUD = s_wc.arr_f32.ptr();
            WVAPOR = s_wv.arr_f32.ptr();
        }
    }

    // is_water 渲染语义 LUT（含 SEA_ICE/LAKE）：dyn A 通道双语义 + eco is_water 判定。
    // 缺失则 fallback——C++ 路径不允许 water cell 误走陆路径。
    PackedByteArray is_water_lut;
    if (map != nullptr) {
        Variant v = map->call(StringName("is_water_render_lut"));
        if (v.get_type() == Variant::PACKED_BYTE_ARRAY) is_water_lut = v;
    }
    if (is_water_lut.size() < 256) return fail("missing is_water render lut");
    const uint8_t * const __restrict IWLUT = is_water_lut.ptr();

    const int terrain_lake = int(opts.get("terrain_lake", -1));
    const int terrain_sea_ice = int(opts.get("terrain_sea_ice", -1));
    const int veg_none = int(opts.get("veg_none", -1));
    const bool cache_valid_opt = bool(opts.get("cache_valid", false));
    const bool force_full_encode = bool(opts.get("force_full_encode", true));
    const bool include_weather_lut = bool(opts.get("include_weather_lut", true));
    const PackedInt32Array requested_dirty =
        opts.get("dirty_indices", PackedInt32Array());

    // 持久 prev 状态与 full byte buffers。日常只 patch dirty ∪ active-transition；
    // 冷启、尺寸变化或显式 force 时走全集。
    auto *st = get_or_create_atlas_state(_atlas_state);
    const bool lut_state_ok = st->lut_initialized &&
        st->lut_prev_veg.size() == n_cells &&
        st->lut_prev_vit.size() == n_cells &&
        st->lut_transition_age.size() == n_cells;
    const int total_bytes = slots_total * 4;
    const bool lut_buffers_ok =
        st->lut_enum_data.size() == total_bytes &&
        st->lut_dyn_data.size() == total_bytes &&
        st->lut_eco_data.size() == total_bytes &&
        st->lut_weather_data.size() == total_bytes;
    if (!lut_state_ok) {
        st->lut_prev_veg.resize(n_cells);
        st->lut_prev_vit.resize(n_cells);
        st->lut_transition_age.resize(n_cells);
    }
    if (!lut_buffers_ok) {
        st->lut_enum_data.resize(total_bytes);
        st->lut_dyn_data.resize(total_bytes);
        st->lut_eco_data.resize(total_bytes);
        st->lut_weather_data.resize(total_bytes);
    }
    uint8_t * const __restrict PV_VEG = st->lut_prev_veg.ptrw();
    uint8_t * const __restrict PV_VIT = st->lut_prev_vit.ptrw();
    uint8_t * const __restrict TR = st->lut_transition_age.ptrw();
    const bool eff_cache_valid = cache_valid_opt && lut_state_ok;

    uint8_t * const __restrict ENUM = st->lut_enum_data.ptrw();
    uint8_t * const __restrict DYN = st->lut_dyn_data.ptrw();
    uint8_t * const __restrict ECO = st->lut_eco_data.ptrw();
    uint8_t * const __restrict WX = st->lut_weather_data.ptrw();

    const bool full_encode = force_full_encode || !lut_state_ok || !lut_buffers_ok;
    PackedByteArray seen;
    PackedInt32Array work_indices;
    auto append_work = [&](int ci) {
        if (ci < 0 || ci >= n_cells || seen[ci] != 0) return;
        seen.set(ci, uint8_t(1));
        work_indices.append(ci);
    };
    if (!full_encode) {
        seen.resize(n_cells);
        for (int i = 0; i < requested_dirty.size(); ++i) {
            append_work(requested_dirty[i]);
        }
        for (int i = 0; i < st->lut_active_transition_indices.size(); ++i) {
            append_work(st->lut_active_transition_indices[i]);
        }
    }

    auto t0 = std::chrono::high_resolution_clock::now();
    int enum_changed_cells = 0;
    int dyn_changed_cells = 0;
    int eco_changed_cells = 0;
    int weather_changed_cells = 0;
    const int processed_cells = full_encode ? n_cells : work_indices.size();
    for (int wi = 0; wi < processed_cells; ++wi) {
        const int ci = full_encode ? wi : work_indices[wi];
        const uint8_t terrain = TERR[ci];
        const bool is_water = IWLUT[terrain] != 0;

        // enum LUT：R=terrain G=vegetation B=cover A=迷雾知识度 k
        const int e4 = ci * 4;
        const uint8_t enum_0 = terrain;
        const uint8_t enum_1 = VEG[ci];
        const uint8_t enum_2 = COVER[ci];
        const uint8_t enum_3 = FOGK != nullptr ? FOGK[ci] : uint8_t(255);
        if (ENUM[e4] != enum_0 || ENUM[e4 + 1] != enum_1 ||
                ENUM[e4 + 2] != enum_2 || ENUM[e4 + 3] != enum_3) {
            ++enum_changed_cells;
        }
        ENUM[e4] = enum_0;
        ENUM[e4 + 1] = enum_1;
        ENUM[e4 + 2] = enum_2;
        ENUM[e4 + 3] = enum_3;

        // dyn LUT
        const float snow_vis = SNOW_VIS[ci];
        if (snow_override_valid) {
            const double d_snow = std::fabs(double(snow_vis) - double(SNOW[ci]));
            snow_slot_diff_sum += d_snow;
            if (d_snow > snow_slot_diff_max) snow_slot_diff_max = d_snow;
            if (d_snow > 0.0001) ++snow_slot_diff_count;
        }

        const uint32_t dsig = pk_atlas_sig_dynamic(
            double(TEMP[ci]), double(MOIST[ci]), double(snow_vis),
            double(VIT[ci]), double(ICE[ci]), is_water);
        const int d4 = ci * 4;
        const uint8_t dyn_0 = uint8_t(dsig & 0xFFu);
        const uint8_t dyn_1 = uint8_t((dsig >> 8) & 0xFFu);
        const uint8_t dyn_2 = uint8_t((dsig >> 16) & 0xFFu);
        const uint8_t dyn_3 = uint8_t((dsig >> 24) & 0xFFu);
        if (DYN[d4] != dyn_0 || DYN[d4 + 1] != dyn_1 ||
                DYN[d4 + 2] != dyn_2 || DYN[d4 + 3] != dyn_3) {
            ++dyn_changed_cells;
        }
        DYN[d4] = dyn_0;
        DYN[d4 + 1] = dyn_1;
        DYN[d4 + 2] = dyn_2;
        DYN[d4 + 3] = dyn_3;

        // eco LUT：transition_age tracking（镜像 encode_ecology_visual_atlas）
        const int cur_veg = int(VEG[ci]) & 0xFF;
        const int cur_vit_byte = pk_q01_byte(double(VIT[ci]));
        int transition_age;
        int prev_vit_byte;
        if (eff_cache_valid) {
            const int prev_veg = int(PV_VEG[ci]);
            prev_vit_byte = int(PV_VIT[ci]);
            transition_age = int(TR[ci]);
            if (cur_veg != prev_veg) transition_age = 255;
            else if (transition_age > 0) {
                transition_age -= 18;
                if (transition_age < 0) transition_age = 0;
            }
        } else {
            transition_age = 0;
            prev_vit_byte = cur_vit_byte;
        }
        const bool eco_is_water = is_water ||
            (int(terrain) == terrain_lake) || (int(terrain) == terrain_sea_ice);
        const uint32_t esig = pk_atlas_sig_ecology(
            double(TEMP[ci]), double(MOIST[ci]), double(snow_vis), double(VIT[ci]),
            cur_veg, eco_is_water, transition_age, prev_vit_byte, veg_none);
        const int c4 = ci * 4;
        const uint8_t eco_0 = uint8_t(esig & 0xFFu);
        const uint8_t eco_1 = uint8_t((esig >> 8) & 0xFFu);
        const uint8_t eco_2 = uint8_t((esig >> 16) & 0xFFu);
        const uint8_t eco_3 = uint8_t((esig >> 24) & 0xFFu);
        if (ECO[c4] != eco_0 || ECO[c4 + 1] != eco_1 ||
                ECO[c4 + 2] != eco_2 || ECO[c4 + 3] != eco_3) {
            ++eco_changed_cells;
        }
        ECO[c4] = eco_0;
        ECO[c4 + 1] = eco_1;
        ECO[c4 + 2] = eco_2;
        ECO[c4 + 3] = eco_3;

        // weather LUT：R=type(枚举), G=intensity, B=cloud, A=vapor（[0,1]→byte）。
        // WTYPE==nullptr（weather 未就绪）时保持初始化的 0。
        if (include_weather_lut && WTYPE != nullptr) {
            const int w4 = ci * 4;
            const uint8_t weather_0 = WTYPE[ci];
            const uint8_t weather_1 = uint8_t(pk_q01_byte(double(WINT[ci])));
            const uint8_t weather_2 = uint8_t(pk_q01_byte(double(WCLOUD[ci])));
            const uint8_t weather_3 = uint8_t(pk_q01_byte(double(WVAPOR[ci])));
            if (WX[w4] != weather_0 || WX[w4 + 1] != weather_1 ||
                    WX[w4 + 2] != weather_2 || WX[w4 + 3] != weather_3) {
                ++weather_changed_cells;
            }
            WX[w4] = weather_0;
            WX[w4 + 1] = weather_1;
            WX[w4 + 2] = weather_2;
            WX[w4 + 3] = weather_3;
        }

        // 写回 prev 状态
        PV_VEG[ci] = uint8_t(cur_veg);
        PV_VIT[ci] = uint8_t(cur_vit_byte);
        int tr_store = transition_age;
        if (tr_store < 0) tr_store = 0;
        else if (tr_store > 255) tr_store = 255;
        TR[ci] = uint8_t(tr_store);
    }
    st->lut_initialized = true;
    PackedInt32Array active_transitions;
    for (int ci = 0; ci < n_cells; ++ci) {
        if (TR[ci] > 0) active_transitions.append(ci);
    }
    st->lut_active_transition_indices = active_transitions;
    auto t1 = std::chrono::high_resolution_clock::now();
    const double ms = std::chrono::duration<double, std::milli>(t1 - t0).count();

    out["enum_lut"] = st->lut_enum_data;
    out["dyn_lut"] = st->lut_dyn_data;
    out["eco_lut"] = st->lut_eco_data;
    if (include_weather_lut) out["weather_lut"] = st->lut_weather_data;
    out["lut_w"] = lut_w;
    out["lut_h"] = lut_h;
    out["n_cells"] = n_cells;
    out["elapsed_ms"] = ms;
    out["full_encode"] = full_encode;
    out["requested_dirty_cells"] = requested_dirty.size();
    out["processed_cells"] = processed_cells;
    out["enum_changed_cells"] = enum_changed_cells;
    out["dynamic_changed_cells"] = dyn_changed_cells;
    out["ecology_changed_cells"] = eco_changed_cells;
    out["weather_changed_cells"] = weather_changed_cells;
    out["active_transition_count"] = active_transitions.size();
    out["snow_override_used"] = snow_override_valid;
    out["snow_source"] = String(snow_override_valid ? "map_snow_cover_arr" : "slot");
    out["snow_slot_diff_count"] = snow_slot_diff_count;
    out["snow_slot_diff_mean"] = snow_override_valid && processed_cells > 0
        ? (snow_slot_diff_sum / double(processed_cells)) : 0.0;
    out["snow_slot_diff_max"] = snow_slot_diff_max;
    out["fallback"] = false;
    out["reason"] = String();
    out["path"] = String("gdext");
    out["published_to_slot"] = false;  // LUT 是渲染产物（ImageTexture），不进 slot
    return out;
}

// 主入口：4-phase atlas pipeline 一次推进。
// opts 字段详见 world_ext.h 注释。
godot::Dictionary DCWorldExt::run_atlas_pipeline_step(godot::Dictionary opts) {
    using godot::Dictionary;
    using godot::PackedByteArray;
    using godot::PackedInt32Array;
    using godot::String;
    using godot::StringName;

    Dictionary out;
    out["done"] = false;
    out["phase"] = int(AtlasPipelineState::IDLE);
    out["cursor"] = 0;
    out["fallback"] = true;
    out["reason"] = String();

    auto fail = [&](const char *why) -> Dictionary {
        out["reason"] = String(why);
        UtilityFunctions::push_warning("[DCWorldExt] run_atlas_pipeline_step: ", why,
                                       " - GD 端应回退旧路径");
        return out;
    };

    if (!_bound) return fail("not bound");
    if (!opts.has("world")) return fail("missing world");
    Object *world = Object::cast_to<Object>(opts["world"]);
    if (world == nullptr) return fail("world is null");
    Object *map = nullptr;
    if (opts.has("map")) {
        map = Object::cast_to<Object>(opts["map"]);
    }
    // map 可空：缺 LUT 走 fallback path。但 width/height 必须有。
    if (!opts.has("width") || !opts.has("height")) return fail("missing width/height");
    const int W = int(opts["width"]);
    const int H = int(opts["height"]);
    const int n_pix = W * H;
    if (n_pix <= 0) return fail("invalid texture size");

    auto *st = get_or_create_atlas_state(_atlas_state);

    // 拉取 SoA refs（CSR + LUT）。
    // n_cells 取自 world.cell_first_px_arr.size()（CSR 主索引），与
    // map.cell_count() 等价；不再依赖 _entity_count（那是 ECS 实体计数，
    // 仅在 assign_archetype/create_entities 路径累加，atlas pipeline 不走
    // 那条路 → 长期保持为 0 会让本接口永远 fallback 到 oneshot）。
    // —— 2026-05-21 plan/atlas-phase-slicing 诊断修复
    WorldSoARefs soa = fetch_world_soa(world, map);
    if (!soa.ok) return fail("world SoA not ready");
    const int n_cells = soa.n_cells;
    if (n_cells <= 0) return fail("world SoA n_cells = 0");

    // ── plan/atlas-phase-slicing：phase-by-phase 时间切片入口判断 ──
    // phase_budget = 本次 call 最多推进的 phase 数（默认 4 = 一气呵成；GD 可传 1
    // 实现每 tick 1 phase）。in_mid_stride = 上次 call yield 时的状态延续，需要
    // 复用 st 的 stride snapshot（dirty_indices / cache_valid_* / nb_arr / prep_*）。
    int phase_budget = 4;
    bool opts_has_phase_budget = opts.has("phase_budget");
    int opts_phase_budget_raw = -1;
    if (opts_has_phase_budget) {
        opts_phase_budget_raw = int(opts["phase_budget"]);
        phase_budget = opts_phase_budget_raw;
        if (phase_budget < 1) phase_budget = 1;
        if (phase_budget > 4) phase_budget = 4;
    }
    const bool in_mid_stride =
        st->stride_active &&
        st->phase >= AtlasPipelineState::DYNAMIC &&
        st->phase <= AtlasPipelineState::ICE &&
        st->stride_n_pix == n_pix &&
        st->stride_n_cells == n_cells;
    int phases_done_this_call = 0;

    // 取 dirty_indices：mid-stride 时复用 st 缓存（GD 不应重复传）；
    // 新 stride 入口时从 opts 消费（GD 已 read_and_clear，保留 atomicity）。
    // plan/sim-2ms-simd-dirty-budget 任务 7（2026-05-21）：force_full_encode kill-switch。
    // GD 端 use_gdext_dynamic_atlas_terminal_dirty=false 时设 opts.force_full_encode=true
    // → 此处覆盖 dirty_path_used=false 让 4 phase 全部走 all_cells（A/B 对照入口）。
    PackedInt32Array dirty_indices;
    bool dirty_path_used;
    bool dirty_noop;
    bool force_full_encode = opts.has("force_full_encode")
        ? bool(opts["force_full_encode"]) : false;
    if (in_mid_stride) {
        dirty_indices = st->stride_dirty_indices;
        dirty_path_used = st->stride_dirty_path_used;
        dirty_noop = st->stride_dirty_noop;
    } else {
        if (opts.has("dirty_indices")) {
            Variant v = opts["dirty_indices"];
            if (v.get_type() == Variant::PACKED_INT32_ARRAY) dirty_indices = v;
        }
        dirty_path_used = opts.has("dirty_indices");
        dirty_noop = dirty_indices.size() == 0;
        // 任务 7 kill-switch 覆盖：force_full_encode=true 时强制走全集编码。
        // 仅在 stride 起点生效（mid-stride 复用 snapshot 不允许中途切语义）。
        if (force_full_encode) {
            dirty_path_used = false;
            dirty_noop = false;
            dirty_indices = PackedInt32Array();
        }
    }

    // SoA 槽位
    const int sid_temp = component_id(StringName("cell_temp"));
    const int sid_moist = component_id(StringName("cell_moisture"));
    const int sid_snow = component_id(StringName("cell_snow_cover"));
    const int sid_vit = component_id(StringName("cell_vegetation_vitality"));
    const int sid_ice = component_id(StringName("cell_sea_ice_frac"));
    const int sid_terr = component_id(StringName("cell_terrain"));
    const int sid_veg = component_id(StringName("cell_vegetation"));
    if (sid_temp < 0 || sid_moist < 0 || sid_snow < 0 || sid_vit < 0 ||
        sid_ice < 0 || sid_terr < 0 || sid_veg < 0) {
        return fail("missing component slot");
    }
    Slot &s_temp = _slots.write[sid_temp];
    Slot &s_moist = _slots.write[sid_moist];
    Slot &s_snow = _slots.write[sid_snow];
    Slot &s_vit = _slots.write[sid_vit];
    Slot &s_ice = _slots.write[sid_ice];
    Slot &s_terr = _slots.write[sid_terr];
    Slot &s_veg = _slots.write[sid_veg];
    if (s_temp.arr_f32.size() < n_cells || s_moist.arr_f32.size() < n_cells ||
        s_snow.arr_f32.size() < n_cells || s_vit.arr_f32.size() < n_cells ||
        s_ice.arr_f32.size() < n_cells ||
        s_terr.arr_u8.size() < n_cells || s_veg.arr_u8.size() < n_cells) {
        return fail("slot array size < entity_count");
    }
    const float * const TEMP = s_temp.arr_f32.ptr();
    const float * const MOIST = s_moist.arr_f32.ptr();
    const float * const SNOW = s_snow.arr_f32.ptr();
    const float * const VIT = s_vit.arr_f32.ptr();
    const float * const ICE = s_ice.arr_f32.ptr();
    const uint8_t * const TERR = s_terr.arr_u8.ptr();
    const uint8_t * const VEG = s_veg.arr_u8.ptr();

    // ── prev_sigs 长度对齐：首帧或 n_cells 变化时 resize/reset ──
    auto ensure_int_arr = [n_cells](PackedInt32Array &a) {
        if (a.size() != n_cells) {
            a.resize(n_cells);
            int32_t *p = a.ptrw();
            for (int i = 0; i < n_cells; ++i) p[i] = -1;
        }
    };
    ensure_int_arr(st->prev_sigs_dyn);
    ensure_int_arr(st->prev_sigs_eco);
    ensure_int_arr(st->prev_sigs_smo);
    ensure_int_arr(st->prev_sigs_ice);
    if (st->eco_transition_age.size() != n_cells) {
        st->eco_transition_age.resize(n_cells);
        float *p = st->eco_transition_age.ptrw();
        for (int i = 0; i < n_cells; ++i) p[i] = 0.0f;
    }

    // ── atlas buffer 初始化 / 大小校验 ──
    // mid-stride 时复用 st 缓存的 cache_valid_*；新 stride 时计算并缓存。
    auto ensure_buf = [&](PackedByteArray &buf, int stride) -> bool {
        if (buf.size() != n_pix * stride) {
            buf.resize(n_pix * stride);
            uint8_t *p = buf.ptrw();
            for (int i = 0; i < n_pix * stride; ++i) p[i] = 0;
            return false;  // cache invalid (新分配)
        }
        return true;
    };
    bool cache_valid_dyn, cache_valid_eco, cache_valid_smo, cache_valid_ice;
    if (in_mid_stride) {
        // buffer 大小不能在 stride 中变化（已被 stride_n_pix 校验前置兜底）；
        // 但仍需 ensure_buf 校验防御 GD 端误改 buf；不变更 cache_valid_*。
        ensure_buf(st->buf_dyn, 4);
        ensure_buf(st->buf_eco, 4);
        ensure_buf(st->buf_smo, 4);
        ensure_buf(st->buf_ice, 1);
        cache_valid_dyn = st->stride_cache_valid_dyn;
        cache_valid_eco = st->stride_cache_valid_eco;
        cache_valid_smo = st->stride_cache_valid_smo;
        cache_valid_ice = st->stride_cache_valid_ice;
    } else {
        cache_valid_dyn = ensure_buf(st->buf_dyn, 4);
        cache_valid_eco = ensure_buf(st->buf_eco, 4);
        cache_valid_smo = ensure_buf(st->buf_smo, 4);
        cache_valid_ice = ensure_buf(st->buf_ice, 1);
    }

    // ── helper: passable_sea by cell.index ──
    // 数据源切换 2026-05-25：原读 soa.terrain_arr（已废弃，本项目运行期未填充）
    // → 改读 cpp 端权威的 cell_terrain SoA slot (TERR)；passable_sea_lut 来自
    // MapData.passable_sea_lut() 的 static method，不依赖 terrain_arr 状态。
    auto cell_psea = [&](int idx) -> bool {
        if (idx < 0 || idx >= n_cells) return false;
        if (soa.passable_sea_lut.size() >= 256) {
            return soa.passable_sea_lut[TERR[idx]] != 0;
        }
        return false;
    };
    // ── helper: is_water by cell.index ──
    // sea-ice-render-source-unify 阶段 C：dyn_atlas / dyn_smooth 用此判定
    // A 通道双语义。与 cell_psea 的差异：SEA_ICE 因冰面阻断航行 cell_psea=false，
    // 但视觉上仍是水域 → cell_is_water=true，A 通道写 ice_byte 让 shader 水路径
    // 正确渲染冰。1:1 镜像 GDScript map_baker.gd::_dynamic_cell_signature 的
    // is_water 判定（基于 cell.is_water == not passable_land 语义）。
    //
    // ── helper: 视觉水陆判定 ──────────────────────────────────────
    // 数据源（关键修复 2026-05-25）：
    //   - terrain：直读 cpp 端权威 cell_terrain SoA slot (TERR 指针)；
    //     不读 MapData.terrain_arr（运行期可能未填充）。
    //   - LUT：soa.is_water_lut 已切换为 MapData.is_water_render_lut()
    //     （阶段 D），SEA_ICE(20) 已直接编为 1，无需任何散点兜底。
    auto cell_is_water = [&](int idx) -> bool {
        if (idx < 0 || idx >= n_cells) return false;
        const uint8_t terrain = TERR[idx];
        if (soa.is_water_lut.size() >= 256) {
            return soa.is_water_lut[terrain] != 0;
        }
        if (soa.passable_sea_lut.size() >= 256) {
            return soa.passable_sea_lut[terrain] != 0;
        }
        return false;
    };
    // ── helper: ice atlas 专用"水域"判定 ──
    // 与 cell_psea 的差异：把 SEA_ICE (terrain=20) 也算作"海冰图层关心的水域"。
    // 原因：sea_ice pass 把寒冷水域 cell 翻转成 terrain=SEA_ICE 后，
    //   .tres 配置 passable_sea=false → cell_psea() 返回 false →
    //   ice_real_indices 把这些 cell 排除 → ICE atlas 不再为它们写像素 →
    //   视觉上看不到冰（即便 MapData.sea_ice_frac_arr=1.0、UI 显示 100%）。
    // 这里仅扩大 ice atlas 的渲染集，不影响单位寻路（仍读 cell.passable_sea）。
    constexpr uint8_t TERRAIN_SEA_ICE = 20;  // 与 9490 行硬编码一致
    auto cell_is_ice_renderable = [&](int idx) -> bool {
        if (idx < 0 || idx >= n_cells) return false;
        if (cell_psea(idx)) return true;
        // 数据源切换 2026-05-25：从 soa.terrain_arr 改为 TERR (cell_terrain SoA slot)。
        return TERR[idx] == TERRAIN_SEA_ICE;
    };

    // ── neighbor SoA: 从 map.neighbor_indices_packed() 取 ──
    // mid-stride 时复用 st 缓存。
    PackedInt32Array nb_arr;
    bool have_nb = false;
    if (in_mid_stride) {
        nb_arr = st->stride_nb_arr;
        have_nb = st->stride_have_nb;
    } else if (map != nullptr) {
        Variant v_nb = map->call(StringName("neighbor_indices_packed"));
        if (v_nb.get_type() == Variant::PACKED_INT32_ARRAY) {
            nb_arr = v_nb;
            have_nb = (nb_arr.size() >= n_cells * 6);
        }
    }

    // ── 新 stride 入口：把入口快照写进 st，供后续 mid-stride call 复用 ──
    if (!in_mid_stride) {
        st->stride_active = true;
        st->phase = AtlasPipelineState::DYNAMIC;
        st->cursor = 0;
        st->stride_dirty_indices = dirty_indices;
        st->stride_dirty_path_used = dirty_path_used;
        st->stride_dirty_noop = dirty_noop;
        st->stride_cache_valid_dyn = cache_valid_dyn;
        st->stride_cache_valid_eco = cache_valid_eco;
        st->stride_cache_valid_smo = cache_valid_smo;
        st->stride_cache_valid_ice = cache_valid_ice;
        st->prep_smo_ready = false;
        st->prep_smo_cursor = 0;
        st->prep_smo_real_indices = PackedInt32Array();
        st->stride_have_nb = have_nb;
        st->stride_nb_arr = nb_arr;
        st->stride_n_pix = n_pix;
        st->stride_n_cells = n_cells;
        st->stride_t_start = std::chrono::high_resolution_clock::now();
        st->stride_total_ms_accum = 0.0;
        // 重置 ms_breakdown（每段 stride 独立诊断）
        st->ms_dyn_prep = st->ms_dyn_step = st->ms_dyn_fin = 0.0;
        st->ms_eco_prep = st->ms_eco_step = st->ms_eco_fin = 0.0;
        st->ms_smo_prep = st->ms_smo_step = st->ms_smo_fin = 0.0;
        st->ms_ice_prep = st->ms_ice_step = st->ms_ice_fin = 0.0;
    }

    auto t_total_start = std::chrono::high_resolution_clock::now();

    // ── plan/atlas-phase-slicing：phase gate 用变量 ──
    // yielded=true 后所有 phase 的 if(gate) 失败，控制流直奔 finalize/mid-return；
    // *_real_count 跨 phase 块保留（finalize 输出 stride_real 用）。
    bool yielded = false;
    int dyn_real_count = 0;
    int eco_real_count = 0;
    int smo_real_count = 0;
    int ice_real_count = 0;
    auto t_p = std::chrono::high_resolution_clock::now();
    auto t_q = t_p;

    // ────────────────────────────────────────────────────────────────────
    // Phase DYNAMIC：dirty ∩ value-diff(prev_sigs_dyn)
    // ────────────────────────────────────────────────────────────────────
    if (!yielded && st->phase == AtlasPipelineState::DYNAMIC) {
    t_p = std::chrono::high_resolution_clock::now();
    PackedInt32Array dyn_real_indices;
    PackedInt32Array dyn_real_sigs;
    {
        // 候选集：dirty_path_used 时为 dirty_indices；否则为全集（首帧 / cache_invalid）。
        // GD 端语义：dynamic_cache_valid=false 时 _phase_cells = all_cells；
        //          dirty_noop && cache_valid 时 _phase_cells = []。
        bool use_all = !dirty_path_used || !cache_valid_dyn;
        if (dirty_noop && cache_valid_dyn) {
            // 跳过 dynamic phase
        } else {
            int32_t * const PREV = st->prev_sigs_dyn.ptrw();
            const int N = use_all ? n_cells : dirty_indices.size();
            const int32_t * const SRC = use_all ? nullptr : dirty_indices.ptr();
            // 预估 reserve；diff-skip 后真正变化的远少于 N
            dyn_real_indices.resize(N);
            dyn_real_sigs.resize(N);
            int32_t * const OUT = dyn_real_indices.ptrw();
            int32_t * const OUT_SIG = dyn_real_sigs.ptrw();
            int kw = 0;
            // [TEMP DIAG sea-ice phase D]：Fix #4 (2026-06-15) — 改为 static
            // life-of-process 计数器（之前是 lambda 局部变量，每次 round 都重置
            // 8 次 PHASE-D-DIAG，移动端热路径累积 ~0.5ms/frame）。现在全局
            // 累计 8 行，调试完毕后整段可删。
            static int _diag_d_dumped = 0;
            // 加 use_all + dirty_size 让我们看 atlas pipeline 是否在 SIF 升到 1.0 之后还被触发。
            for (int i = 0; i < N; ++i) {
                const int idx = use_all ? i : SRC[i];
                if (idx < 0 || idx >= n_cells) continue;
                // sea-ice-render-source-unify 阶段 D：cell_is_water 走 is_water_render_lut
                //   （含 SEA_ICE）→ atlas A 通道一致写 ice byte，不再走陆路径写 vit byte。
                const bool iw = cell_is_water(idx);
                const uint32_t sig = pk_atlas_sig_dynamic(
                    double(TEMP[idx]), double(MOIST[idx]),
                    double(SNOW[idx]), double(VIT[idx]), double(ICE[idx]), iw);
                // 仅 dump 用户实际关心的 SEA_ICE cell（idx 区间常见为 1900~2400）
                // 且 ICE>0.5 才是探针点击的"应当渲染冰"格。
                const bool _diag_match = (TERR[idx] == 20) && (double(ICE[idx]) > 0.5);
                const bool _diag_skip = cache_valid_dyn && uint32_t(PREV[idx]) == sig;
                if (_diag_d_dumped < 8 && _diag_match) {
                    UtilityFunctions::print(
                        "[PHASE-D-DIAG] idx=", idx,
                        " TERR=", int(TERR[idx]),
                        " use_all=", use_all,
                        " N=", N, " dirty_sz=", dirty_indices.size(),
                        " iw=", iw,
                        " ICE=", double(ICE[idx]),
                        " sig.A=", int((sig >> 24) & 0xFFu),
                        " PREV.A=", int(uint32_t(PREV[idx]) >> 24) & 0xFF,
                        " cache_valid=", cache_valid_dyn,
                        " skip=", _diag_skip);
                    ++_diag_d_dumped;
                }
                if (_diag_skip) continue;  // skip
                PREV[idx] = int32_t(sig);
                OUT[kw] = idx;
                OUT_SIG[kw] = int32_t(sig);
                ++kw;
            }
            dyn_real_indices.resize(kw);
            dyn_real_sigs.resize(kw);
        }
    }
    t_q = std::chrono::high_resolution_clock::now();
    st->ms_dyn_prep = std::chrono::duration<double, std::milli>(t_q - t_p).count();

    // dynamic phase 直接写 buffer：prep 已完成 sig-diff，避免再构造 Dictionary/CSR 临时数组并二次算 sig。
    {
        t_p = std::chrono::high_resolution_clock::now();
        const int K = dyn_real_indices.size();
        if (K > 0) {
            const int32_t * const REAL = dyn_real_indices.ptr();
            const int32_t * const SIGS = dyn_real_sigs.ptr();
            const int32_t * const SF = soa.cell_first_px.ptr();
            const int32_t * const SC = soa.cell_px_count.ptr();
            const int32_t * const FLAT = soa.flat_px_indices.ptr();
            uint8_t * const BUF = st->buf_dyn.ptrw();
            const int flat_n = soa.flat_px_indices.size();
            for (int k = 0; k < K; ++k) {
                const int idx = REAL[k];
                if (idx < 0 || idx >= soa.n_cells) continue;
                const int f = SF[idx];
                const int c = SC[idx];
                if (c <= 0 || f < 0 || f + c > flat_n) continue;
                const uint32_t sig = uint32_t(SIGS[k]);
                const uint8_t r = uint8_t(sig & 0xFFu);
                const uint8_t g = uint8_t((sig >> 8) & 0xFFu);
                const uint8_t b = uint8_t((sig >> 16) & 0xFFu);
                const uint8_t a = uint8_t((sig >> 24) & 0xFFu);
                for (int p = 0; p < c; ++p) {
                    const int px_idx = FLAT[f + p];
                    if (px_idx < 0 || px_idx >= n_pix) continue;
                    const int base = px_idx * 4;
                    BUF[base    ] = r;
                    BUF[base + 1] = g;
                    BUF[base + 2] = b;
                    BUF[base + 3] = a;
                }
            }
        }
        t_q = std::chrono::high_resolution_clock::now();
        st->ms_dyn_step = std::chrono::duration<double, std::milli>(t_q - t_p).count();
        st->ms_dyn_fin = 0.0;
    }
    dyn_real_count = dyn_real_indices.size();
    st->phase = AtlasPipelineState::ECOLOGY;
    ++phases_done_this_call;
    if (phases_done_this_call >= phase_budget) yielded = true;
    }  // end Phase DYNAMIC gate

    // ────────────────────────────────────────────────────────────────────
    // Phase ECOLOGY：dirty ∪ active_decay；cache_invalid 时全集；维护 transition_age
    // ────────────────────────────────────────────────────────────────────
    if (!yielded && st->phase == AtlasPipelineState::ECOLOGY) {
    PackedInt32Array eco_real_indices;
    t_p = std::chrono::high_resolution_clock::now();
    {
        // 工作集：cache_invalid → 全集；cache_valid + dirty_noop + decay 空 → 跳过；
        //          cache_valid + dirty_noop + decay 非空 → 仅 decay；其它走 dirty ∪ decay
        bool skip_phase = false;
        bool use_all = false;
        if (!cache_valid_eco) {
            use_all = true;
        } else if (dirty_path_used && dirty_noop) {
            if (st->eco_active_decay_indices.size() == 0) {
                skip_phase = true;
            }
            // else: 仅 decay（下方按 active_decay_indices 处理）
        }
        if (!skip_phase) {
            // seen[i]=1 表示已经入选；避免 dirty 与 decay 重复
            std::vector<uint8_t> seen(n_cells, 0);
            if (use_all) {
                eco_real_indices.resize(n_cells);
                for (int i = 0; i < n_cells; ++i) {
                    eco_real_indices[i] = i;
                    seen[i] = 1;
                }
            } else {
                eco_real_indices.resize(dirty_indices.size() + st->eco_active_decay_indices.size());
                int kw = 0;
                if (dirty_path_used && !dirty_noop) {
                    const int32_t * const D = dirty_indices.ptr();
                    for (int i = 0; i < dirty_indices.size(); ++i) {
                        const int idx = D[i];
                        if (idx < 0 || idx >= n_cells || seen[idx]) continue;
                        seen[idx] = 1;
                        eco_real_indices[kw++] = idx;
                    }
                }
                const int32_t * const A = st->eco_active_decay_indices.ptr();
                for (int i = 0; i < st->eco_active_decay_indices.size(); ++i) {
                    const int idx = A[i];
                    if (idx < 0 || idx >= n_cells || seen[idx]) continue;
                    seen[idx] = 1;
                    eco_real_indices[kw++] = idx;
                }
                eco_real_indices.resize(kw);
            }
        }
    }
    t_q = std::chrono::high_resolution_clock::now();
    st->ms_eco_prep = std::chrono::duration<double, std::milli>(t_q - t_p).count();

    // 调 encode_ecology_visual_atlas
    {
        t_p = std::chrono::high_resolution_clock::now();
        const int K = eco_real_indices.size();
        if (K > 0) {
            PackedInt32Array first_px; first_px.resize(K);
            PackedInt32Array px_count; px_count.resize(K);
            PackedByteArray pass_sea; pass_sea.resize(K);
            PackedByteArray prev_veg; prev_veg.resize(K);
            PackedByteArray prev_vit; prev_vit.resize(K);
            PackedByteArray prev_tr; prev_tr.resize(K);
            PackedInt32Array prev_sigs_csr; prev_sigs_csr.resize(K);
            const int32_t * const REAL = eco_real_indices.ptr();
            const int32_t * const SF = soa.cell_first_px.ptr();
            const int32_t * const SC = soa.cell_px_count.ptr();
            const float * const TR = st->eco_transition_age.ptr();
            const int32_t * const PE_PREV = st->prev_sigs_eco.ptr();
            for (int k = 0; k < K; ++k) {
                const int idx = REAL[k];
                const int f = (idx < soa.n_cells) ? SF[idx] : -1;
                const int c = (idx < soa.n_cells) ? SC[idx] : 0;
                first_px[k] = (c <= 0 || f < 0) ? 0 : f;
                px_count[k] = (c <= 0 || f < 0) ? 0 : c;
                pass_sea[k] = cell_is_water(idx) ? 1 : 0;
                // prev_veg / prev_vit 从 SoA 读 cur 即可（GD 路径下 ecology baker
                // 维护的是"上一次写入"的镜像，本管线整体下沉后，cur 直接代表上一帧
                // 本 cell 的 vegetation/vitality —— 因为 sim 在 priority<250 写完，
                // atlas pipeline 在 250 read，下一帧 sim 才会再写，所以"cur=prev"
                // 在 ecology phase 入口成立）。
                // 唯一例外：本 phase 内部"先写 prev, 再写 cur"的语义——但 GD 路径
                // _ecology_visual_signature 里 prev_vitality_byte 只用作 vit_delta，
                // 而这里 vit_delta 永远是 0（cur==prev），与 GD"首次访问 fallback 到 cur"
                // 等价。这个细节差异在 ecology atlas 上不会产生 bit 不一致，因为
                // 当真正变化时，prev 的有效 baseline 已经被前一 stride 的 SoA 写入。
                prev_veg[k] = uint8_t(VEG[idx]);
                prev_vit[k] = uint8_t(pk_q01_byte(double(VIT[idx])));
                prev_tr[k] = uint8_t(int(TR[idx]) & 0xFF);
                prev_sigs_csr[k] = (idx >= 0 && idx < n_cells) ? PE_PREV[idx] : -1;
            }
            Dictionary knobs;
            knobs["n_pix"] = n_pix;
            knobs["stride_bytes"] = 4;
            knobs["atlas_buffer"] = st->buf_eco;
            knobs["cell_indices"] = eco_real_indices;
            knobs["cell_first_px"] = first_px;
            knobs["cell_px_count"] = px_count;
            knobs["flat_px_indices"] = soa.flat_px_indices;
            knobs["cell_is_water"] = pass_sea;
            knobs["prev_veg"] = prev_veg;
            knobs["prev_vitality"] = prev_vit;
            knobs["prev_transition"] = prev_tr;
            knobs["prev_sigs"] = prev_sigs_csr;
            knobs["cache_valid"] = cache_valid_eco;
            knobs["terrain_lake"] = int(opts.get("terrain_lake", -1));
            knobs["terrain_sea_ice"] = int(opts.get("terrain_sea_ice", -1));
            knobs["veg_none"] = int(opts.get("veg_none", -1));
            Dictionary res = encode_ecology_visual_atlas(knobs);
            if (!bool(res.get("fallback", true))) {
                st->buf_eco = res["atlas_buffer"];
                // 写回 transition_age + 重建 active_decay_indices
                if (res.has("new_transition")) {
                    PackedByteArray new_tr = res["new_transition"];
                    if (new_tr.size() == K) {
                        // 写回 transition_age SoA + 收集 active decay
                        PackedInt32Array new_decay; new_decay.resize(K);
                        int dw = 0;
                        float * const TRW = st->eco_transition_age.ptrw();
                        const uint8_t *NT = new_tr.ptr();
                        for (int k = 0; k < K; ++k) {
                            const int idx = REAL[k];
                            TRW[idx] = float(NT[k]);
                            if (NT[k] > 0) new_decay[dw++] = idx;
                        }
                        new_decay.resize(dw);
                        st->eco_active_decay_indices = new_decay;
                    }
                }
                // 写回 prev_sigs_eco（虽然外层暂未用 sig-diff 过滤 eco，但保持
                // snapshot 持久化以备 future 优化）
                if (res.has("new_sigs")) {
                    PackedInt32Array new_sigs = res["new_sigs"];
                    if (new_sigs.size() == K) {
                        int32_t * const PE = st->prev_sigs_eco.ptrw();
                        const int32_t * const NS = new_sigs.ptr();
                        for (int k = 0; k < K; ++k) {
                            const int idx = REAL[k];
                            if (idx >= 0 && idx < n_cells) PE[idx] = NS[k];
                        }
                    }
                }
            }
        }
        t_q = std::chrono::high_resolution_clock::now();
        st->ms_eco_step = std::chrono::duration<double, std::milli>(t_q - t_p).count();
        st->ms_eco_fin = 0.0;
    }
    eco_real_count = eco_real_indices.size();
    st->phase = AtlasPipelineState::SMOOTH;
    ++phases_done_this_call;
    if (phases_done_this_call >= phase_budget) yielded = true;
    }  // end Phase ECOLOGY gate

    // ────────────────────────────────────────────────────────────────────
    // Phase SMOOTH：(eco_real ∪ dirty) 1-跳邻居膨胀；需要 neighbor SoA
    // ────────────────────────────────────────────────────────────────────
    if (!yielded && st->phase == AtlasPipelineState::SMOOTH) {
    // [TEMP DIAG sea-ice phase D-smo-entry]
    {
        static int _diag_smo_entry_dumped = 0;
        if (_diag_smo_entry_dumped < 4) {
            UtilityFunctions::print(
                "[PHASE-D-SMO-ENTRY] have_nb=", have_nb,
                " cache_valid_smo=", cache_valid_smo,
                " dirty_path_used=", dirty_path_used,
                " dirty_noop=", dirty_noop,
                " dirty_sz=", dirty_indices.size(),
                " eco_decay_sz=", st->eco_active_decay_indices.size(),
                " prep_smo_ready=", st->prep_smo_ready);
            ++_diag_smo_entry_dumped;
        }
    }
    int max_smooth_cells_per_call = opts.has("max_smooth_cells_per_call")
        ? int(opts["max_smooth_cells_per_call"]) : 512;
    if (max_smooth_cells_per_call < 128) max_smooth_cells_per_call = 128;
    if (max_smooth_cells_per_call > n_cells) max_smooth_cells_per_call = n_cells;
    if (!st->prep_smo_ready) {
        PackedInt32Array smo_real_indices;
        t_p = std::chrono::high_resolution_clock::now();
        {
            bool skip_phase = false;
            if (!have_nb) {
                // 没有 neighbor SoA：缺乏 smooth 数据源 → 跳过（GD 端旧路径会 fallback）
                skip_phase = true;
            } else if (!cache_valid_smo) {
                // cache_invalid → 全集
                smo_real_indices.resize(n_cells);
                for (int i = 0; i < n_cells; ++i) smo_real_indices[i] = i;
            } else if (dirty_path_used && dirty_noop && st->eco_active_decay_indices.size() == 0) {
                // 完全无变化：跳过
                skip_phase = true;
            } else {
                // seed = dirty ∪ decay；膨胀 = seed ∪ 6 邻居
                std::vector<uint8_t> seen(n_cells, 0);
                std::vector<int32_t> seed;
                seed.reserve(dirty_indices.size() + st->eco_active_decay_indices.size());
                if (dirty_path_used && !dirty_noop) {
                    const int32_t * const D = dirty_indices.ptr();
                    for (int i = 0; i < dirty_indices.size(); ++i) {
                        const int idx = D[i];
                        if (idx < 0 || idx >= n_cells || seen[idx]) continue;
                        seen[idx] = 1;
                        seed.push_back(idx);
                    }
                }
                const int32_t * const A = st->eco_active_decay_indices.ptr();
                for (int i = 0; i < st->eco_active_decay_indices.size(); ++i) {
                    const int idx = A[i];
                    if (idx < 0 || idx >= n_cells || seen[idx]) continue;
                    seen[idx] = 1;
                    seed.push_back(idx);
                }
                // 1-跳膨胀（自适应稀疏 / 稠密同 baker_dirty_helpers.gd 行为）
                const int32_t * const NB = nb_arr.ptr();
                std::vector<int32_t> dilated;
                dilated.reserve(seed.size() * 7);
                for (int32_t idx : seed) {
                    dilated.push_back(idx);
                    const int base = idx * 6;
                    for (int d = 0; d < 6; ++d) {
                        const int32_t ni = NB[base + d];
                        if (ni < 0 || ni >= n_cells || seen[ni]) continue;
                        seen[ni] = 1;
                        dilated.push_back(ni);
                    }
                }
                smo_real_indices.resize(int(dilated.size()));
                int32_t *p = smo_real_indices.ptrw();
                for (size_t i = 0; i < dilated.size(); ++i) p[i] = dilated[i];
            }
            // skip_phase 时 smo_real_indices 保持空
            (void)skip_phase;
        }
        t_q = std::chrono::high_resolution_clock::now();
        st->ms_smo_prep = std::chrono::duration<double, std::milli>(t_q - t_p).count();
        st->prep_smo_real_indices = smo_real_indices;
        st->prep_smo_ready = true;
        st->prep_smo_cursor = 0;
    } else {
        st->ms_smo_prep = 0.0;
    }
    PackedInt32Array &smo_real_indices = st->prep_smo_real_indices;
    const int K = smo_real_indices.size();
    const int k_begin = st->prep_smo_cursor;
    const int k_end = std::min(K, k_begin + max_smooth_cells_per_call);

    // smooth phase 直接写 buffer：避免构造 Dictionary / K 级临时 CSR 数组 / neighbor_is_water。
    {
        t_p = std::chrono::high_resolution_clock::now();
        if (K > 0 && have_nb && k_begin < k_end) {
            const int32_t * const REAL = smo_real_indices.ptr();
            const int32_t * const SF = soa.cell_first_px.ptr();
            const int32_t * const SC = soa.cell_px_count.ptr();
            const int32_t * const FLAT = soa.flat_px_indices.ptr();
            const int32_t * const NB = nb_arr.ptr();
            int32_t * const PS = st->prev_sigs_smo.ptrw();
            uint8_t * const BUF = st->buf_smo.ptrw();
            const int flat_n = soa.flat_px_indices.size();

            // sea-ice-render-source-unify 阶段 C：sig_of 改用 is_water + sea_ice_frac，
            // 让 SEA_ICE / OCEAN 等水域 cell 的 A 通道写 ice_byte（与 GDScript fallback
            // _dynamic_cell_signature 1:1 对齐）。
            auto sig_of = [&](int idx) -> uint32_t {
                return pk_atlas_sig_dynamic(
                    double(TEMP[idx]), double(MOIST[idx]),
                    double(SNOW[idx]), double(VIT[idx]),
                    double(ICE[idx]), cell_is_water(idx));
            };

            for (int k = k_begin; k < k_end; ++k) {
                const int ci = REAL[k];
                if (ci < 0 || ci >= n_cells) continue;

                const uint32_t c_sig = sig_of(ci);
                const int cr = int(c_sig & 0xFFu);
                const int cg = int((c_sig >> 8) & 0xFFu);
                const int cb = int((c_sig >> 16) & 0xFFu);
                const int ca = int((c_sig >> 24) & 0xFFu);
                // sea-ice-render-source-unify 阶段 C：A 通道水陆分裂均值，
                // 与 GDScript dyn_atlas_smooth_chunk_step / encode_dyn_smooth_atlas
                // 函数版 1:1 对齐。中心 is_water 决定只累加同语义邻居 A。
                const bool center_is_water = cell_is_water(ci);

                uint32_t hood_h = 0x811C9DC5u;
                hood_h = (hood_h ^ uint32_t(cr)) * 0x01000193u;
                hood_h = (hood_h ^ uint32_t(cg)) * 0x01000193u;
                hood_h = (hood_h ^ uint32_t(cb)) * 0x01000193u;
                hood_h = (hood_h ^ uint32_t(ca)) * 0x01000193u;

                int nr = 0, ng = 0, nb_sum = 0, na = 0, nc = 0, na_c = 0;
                const int nb_base = ci * 6;
                for (int d = 0; d < 6; ++d) {
                    const int32_t ni = NB[nb_base + d];
                    if (ni < 0 || ni >= n_cells) continue;
                    const uint32_t n_sig = sig_of(int(ni));
                    const int nrb = int(n_sig & 0xFFu);
                    const int ngb = int((n_sig >> 8) & 0xFFu);
                    const int nbb = int((n_sig >> 16) & 0xFFu);
                    const int nab = int((n_sig >> 24) & 0xFFu);
                    nr += nrb; ng += ngb; nb_sum += nbb; ++nc;
                    // A 通道独立计数：仅累加与中心同水/陆类的邻居，避免
                    // sea_ice_frac 与 vegetation_vitality 异语义数据互相污染。
                    const bool n_is_water = cell_is_water(int(ni));
                    if (center_is_water == n_is_water) {
                        na += nab;
                        ++na_c;
                    }
                    hood_h = (hood_h ^ uint32_t(nrb)) * 0x01000193u;
                    hood_h = (hood_h ^ uint32_t(ngb)) * 0x01000193u;
                    hood_h = (hood_h ^ uint32_t(nbb)) * 0x01000193u;
                    hood_h = (hood_h ^ uint32_t(nab)) * 0x01000193u;
                }

                // [TEMP DIAG sea-ice phase D-smo]
                const bool _diag_smo_match = (TERR[ci] == 20) && (double(ICE[ci]) > 0.5);
                const bool _diag_smo_skip = cache_valid_smo && uint32_t(PS[ci]) == hood_h;
                static int _diag_smo_dumped = 0;
                if (_diag_smo_dumped < 8 && _diag_smo_match) {
                    UtilityFunctions::print(
                        "[PHASE-D-SMO] ci=", ci, " TERR=", int(TERR[ci]),
                        " ICE=", double(ICE[ci]),
                        " ca=", ca, " nc=", nc, " na_c=", na_c,
                        " na_sum=", na,
                        " hood_h=", String::num_uint64(uint64_t(hood_h), 16),
                        " PS_hood=", String::num_uint64(uint64_t(uint32_t(PS[ci])), 16),
                        " skip=", _diag_smo_skip,
                        " cache_valid_smo=", cache_valid_smo);
                    ++_diag_smo_dumped;
                }
                if (_diag_smo_skip) {
                    continue;
                }
                PS[ci] = int32_t(hood_h);

                int or_, og, ob, oa;
                if (nc > 0) {
                    or_ = (cr + (nr / nc)) / 2;
                    og = (cg + (ng / nc)) / 2;
                    // sea-ice-render-source-unify 阶段 C：B 通道（snow_cover）
                    // 改为 passthrough（与 encode_dyn_smooth_atlas 函数版 1:1）。
                    // 历史原因：单格 95% 雪盖会被无雪邻居拖到 ~47.5%，shader 后段
                    // smoothstep 直接压成不可见。对 B 不做 box blur 是必要妥协。
                    ob = cb;
                    // A 通道：用同水陆类邻居数 na_c 做均值，全异类 (na_c=0) 退回中心值。
                    if (na_c > 0) {
                        oa = (ca + (na / na_c)) / 2;
                    } else {
                        oa = ca;
                    }
                } else {
                    or_ = cr; og = cg; ob = cb; oa = ca;
                }

                // [TEMP DIAG sea-ice phase D-smo-final]
                static int _diag_smo_oa_dumped = 0;
                if (_diag_smo_oa_dumped < 8 && TERR[ci] == 20 && double(ICE[ci]) > 0.5) {
                    UtilityFunctions::print(
                        "[PHASE-D-SMO-OA] ci=", ci, " ICE=", double(ICE[ci]),
                        " ca=", ca, " na=", na, " na_c=", na_c,
                        " oa=", oa,
                        " first_px=", SF[ci], " count=", SC[ci]);
                    ++_diag_smo_oa_dumped;
                }

                const int first = SF[ci];
                const int count = SC[ci];
                if (count <= 0 || first < 0 || first + count > flat_n) continue;
                for (int p = 0; p < count; ++p) {
                    const int px_idx = FLAT[first + p];
                    if (px_idx < 0 || px_idx >= n_pix) continue;
                    const int base = px_idx * 4;
                    BUF[base    ] = uint8_t(or_);
                    BUF[base + 1] = uint8_t(og);
                    BUF[base + 2] = uint8_t(ob);
                    BUF[base + 3] = uint8_t(oa);
                }
            }
        }
        t_q = std::chrono::high_resolution_clock::now();
        st->ms_smo_step = std::chrono::duration<double, std::milli>(t_q - t_p).count();
        st->ms_smo_fin = 0.0;
    }
    st->prep_smo_cursor = k_end;
    smo_real_count = smo_real_indices.size();
    if (st->prep_smo_cursor < smo_real_count) {
        yielded = true;
    } else {
        st->prep_smo_ready = false;
        st->prep_smo_cursor = 0;
        st->prep_smo_real_indices = PackedInt32Array();
        st->phase = AtlasPipelineState::ICE;
        ++phases_done_this_call;
        if (phases_done_this_call >= phase_budget) yielded = true;
    }
    }  // end Phase SMOOTH gate

    // ────────────────────────────────────────────────────────────────────
    // Phase ICE：dirty ∩ water；cache_invalid 时全水域；走 water_cell_pixel_lists
    //   注意：ice atlas 的 pixel layout 来自 water_cell_pixel_lists（而非整图
    //   cell_pixel_lists），但 SoA cell_first_px_arr 是整图的，不能直接复用。
    //   解决：fallback 用 SoA 整图 pixel list，shader 端 mask 已经只读水域。
    //   实际上 GD encode_ice_state_atlas 已用 sea_ice_frac 量化（陆地 cell
    //   sea_ice_frac=0 → byte=0），所以走整图 SoA 也能得到 bit-equal 结果。
    // ────────────────────────────────────────────────────────────────────
    if (!yielded && st->phase == AtlasPipelineState::ICE) {
    PackedInt32Array ice_real_indices;
    t_p = std::chrono::high_resolution_clock::now();
    {
        bool skip_phase = false;
        if (!cache_valid_ice) {
            // cache_invalid → 全水域 cell（以 SoA cell_first_px>=0 + passable_sea
            // 作筛选。此处简化为全集，encode 内部对陆地 cell 写 byte=0 与原行为等价）。
            // 注意：这里用 cell_is_ice_renderable 而非 cell_psea —— 已结冰
            // (terrain==SEA_ICE) 的 cell 也要进入编码集，否则视觉上看不到冰。
            ice_real_indices.resize(n_cells);
            int kw = 0;
            for (int i = 0; i < n_cells; ++i) {
                if (cell_is_ice_renderable(i)) ice_real_indices[kw++] = i;
            }
            ice_real_indices.resize(kw);
        } else if (dirty_path_used && dirty_noop) {
            // 完全无变化：跳过
            skip_phase = true;
        } else if (dirty_path_used) {
            // dirty ∩ water
            ice_real_indices.resize(dirty_indices.size());
            int kw = 0;
            const int32_t * const D = dirty_indices.ptr();
            int32_t * const OUT = ice_real_indices.ptrw();
            int32_t * const PV = st->prev_sigs_ice.ptrw();
            for (int i = 0; i < dirty_indices.size(); ++i) {
                const int idx = D[i];
                if (idx < 0 || idx >= n_cells || !cell_is_ice_renderable(idx)) continue;
                // value-diff
                const int byte_v = pk_q01_byte_ice(double(ICE[idx]));
                if (cache_valid_ice && PV[idx] == byte_v) continue;
                PV[idx] = byte_v;
                OUT[kw++] = idx;
            }
            ice_real_indices.resize(kw);
        } else {
            // 无 dirty path：全水域
            // 同上：用 cell_is_ice_renderable 把 SEA_ICE terrain 也纳入编码集。
            ice_real_indices.resize(n_cells);
            int kw = 0;
            for (int i = 0; i < n_cells; ++i) {
                if (cell_is_ice_renderable(i)) ice_real_indices[kw++] = i;
            }
            ice_real_indices.resize(kw);
        }
        (void)skip_phase;
    }
    t_q = std::chrono::high_resolution_clock::now();
    st->ms_ice_prep = std::chrono::duration<double, std::milli>(t_q - t_p).count();

    // 调 encode_ice_state_atlas
    {
        t_p = std::chrono::high_resolution_clock::now();
        const int K = ice_real_indices.size();
        if (K > 0) {
            // ★ 修复 C：完全内联 encode 逻辑，绕开 encode_ice_state_atlas 函数。
            // 原因：Apple Clang ARM64 在 encode_ice_state_atlas 函数内部对
            // PackedFloat32Array.ptr() 的间接索引读 ICE[ci] 做 alias-DCE，
            // 即便加 volatile/memcpy 也无法稳定规避（pixels_written 一直=0）。
            // 外层 ICE 指针在 PIPELINE-ENTRY 探针中证实工作良好（first_nz=0,val=1.0），
            // 因此把整个编码循环搬到外层 scope，直接读 ICE/写 buf_ice。
            const int32_t * const REAL = ice_real_indices.ptr();
            const int32_t * const SF = soa.cell_first_px.ptr();
            const int32_t * const SC = soa.cell_px_count.ptr();
            const int32_t * const FLAT = soa.flat_px_indices.ptr();
            const int n_pix_local = n_pix;
            const int flat_size = soa.flat_px_indices.size();
            int32_t * const PV = st->prev_sigs_ice.ptrw();

            // 取 buf_ice 写入指针（如果尺寸不对先 resize）
            if (st->buf_ice.size() != n_pix_local) {
                st->buf_ice.resize(n_pix_local);
                uint8_t * const BUF_INIT = st->buf_ice.ptrw();
                for (int p = 0; p < n_pix_local; ++p) BUF_INIT[p] = 0;
            }
            uint8_t * const BUF = st->buf_ice.ptrw();

            for (int k = 0; k < K; ++k) {
                const int ci = REAL[k];
                if (ci < 0 || ci >= n_cells) continue;
                const float ice_v = ICE[ci];   // ★ 外层 ICE 已证可信
                const int byte_v = pk_q01_byte_ice(double(ice_v));
                // 同步 prev_sigs_ice，使后续 dirty path 的 value-diff 正确
                PV[ci] = int32_t(byte_v);
                // 写像素
                const int f = SF[ci];
                const int c_cnt = SC[ci];
                if (f < 0 || c_cnt <= 0) continue;
                for (int p = 0; p < c_cnt; ++p) {
                    const int fi = f + p;
                    if (fi < 0 || fi >= flat_size) continue;
                    const int px_idx = FLAT[fi];
                    if (px_idx < 0 || px_idx >= n_pix_local) continue;
                    BUF[px_idx] = uint8_t(byte_v);
                }
            }
        }
        t_q = std::chrono::high_resolution_clock::now();
        st->ms_ice_step = std::chrono::duration<double, std::milli>(t_q - t_p).count();
        st->ms_ice_fin = 0.0;
    }
    ice_real_count = ice_real_indices.size();
    st->phase = AtlasPipelineState::DONE;
    ++phases_done_this_call;
    // ICE 是最后一个 phase，跑完 phase=DONE，无需再 yield 检查
    }  // end Phase ICE gate

    auto t_total_end = std::chrono::high_resolution_clock::now();
    const double this_call_ms = std::chrono::duration<double, std::milli>(
        t_total_end - t_total_start).count();
    st->stride_total_ms_accum += this_call_ms;

    // 状态机：phase==DONE → 本 stride 跑完；否则中途 yield。
    const bool stride_done = (st->phase == AtlasPipelineState::DONE);
    if (stride_done) {
        st->stride_active = false;
        st->stride_counter += 1;
    }

    // ── 组装返回 Dict ──
    out["fallback"] = false;
    out["reason"] = String();
    out["done"] = stride_done;
    out["phase"] = int(st->phase);
    out["cursor"] = st->cursor;
    // total_ms：stride_done 时返回整段累加；mid-stride 时返回本 call 局部
    // （GD 端用 done==true 触发 GPU commit，并据此读 total_ms 做 dashboard）
    out["total_ms"] = stride_done ? st->stride_total_ms_accum : this_call_ms;
    out["phases_done_this_call"] = phases_done_this_call;
    out["mid_stride"] = !stride_done;
    // ── plan/atlas-phase-slicing 诊断（2026-05-21）──
    // 上一次 perf 录制看到 done=true 一次跑 4 phase，但字符串确实编进 DLL 了。
    // 把"opts 里到底有没有 phase_budget / 实际生效值"原样回吐，让 GD 端能直接
    // 在 CSV 里看到——若 CSV 显示 phase_budget_effective=4 就铁证 opts 没传过来。
    out["phase_budget_effective"] = phase_budget;
    out["opts_has_phase_budget"] = opts_has_phase_budget;
    // plan/sim-2ms-simd-dirty-budget 任务 7：dirty 编码 kill-switch 诊断透传。
    // GD 端 perf log 用 force_full_encode 字段确认 use_gdext_dynamic_atlas_terminal_dirty
    // flag 是否实际生效（A/B 比对时 csv 会同时记录 path 与 force_full_encode）。
    out["force_full_encode"] = force_full_encode;
    out["dirty_path_used"] = dirty_path_used;
    out["opts_phase_budget_raw"] = opts_phase_budget_raw;

    // atlas_buffers：只在 stride_done 时输出（mid-stride 时空 Dict，GD 不应 commit）
    Dictionary atlas_buffers;
    if (stride_done) {
        atlas_buffers["dyn"] = st->buf_dyn;
        atlas_buffers["eco"] = st->buf_eco;
        atlas_buffers["smo"] = st->buf_smo;
        atlas_buffers["ice"] = st->buf_ice;
    }
    out["atlas_buffers"] = atlas_buffers;

    Dictionary stride_real;
    stride_real["dyn"] = dyn_real_count;
    stride_real["eco"] = eco_real_count;
    stride_real["smo"] = smo_real_count;
    stride_real["ice"] = ice_real_count;
    out["stride_real"] = stride_real;

    if (bool(opts.get("enable_diag", false))) {
        Dictionary ms;
        ms["dynamic_prepare_ms"] = st->ms_dyn_prep;
        ms["dynamic_step_ms"] = st->ms_dyn_step;
        ms["dynamic_finalize_ms"] = st->ms_dyn_fin;
        ms["ecology_prepare_ms"] = st->ms_eco_prep;
        ms["ecology_step_ms"] = st->ms_eco_step;
        ms["ecology_finalize_ms"] = st->ms_eco_fin;
        ms["smooth_prepare_ms"] = st->ms_smo_prep;
        ms["smooth_step_ms"] = st->ms_smo_step;
        ms["smooth_finalize_ms"] = st->ms_smo_fin;
        ms["ice_prepare_ms"] = st->ms_ice_prep;
        ms["ice_step_ms"] = st->ms_ice_step;
        ms["ice_finalize_ms"] = st->ms_ice_fin;
        out["ms_breakdown"] = ms;
    }

    return out;
}

} // namespace pk
