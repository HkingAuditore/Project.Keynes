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


// ─── Hot-loop implementations ──────────────────────────────────────────────

// Phase 3b Step 3b-1: real implementation of Pass-A (climate daily tick),
// MINUS the dirty-mask + global-drift accounting — that's Step 3b-1.5, kept
// out of this commit so we can A/B-validate the core math first without
// fighting two new behaviours at once.
//
// Truth source: `_climate_pass_a()` in
//   Project/project-keynes/scripts/geography/map_generator.gd
// (the SoA-aware branch, i.e. when `_use_dc=true`). Algorithm spec is in
//   .codebuddy/plan/dots-roadmap-to-gdextension/architecture.md  §"Step 3b-0"
//
// Performance contract: charter §0 M2 baseline = 0.30 ms / pass @ N=2400.
// Current GDScript implementation = ~4.1 ms / pass. Expected ~13× speedup.
//
// Return value:
//   ≥ 0.0 → C++ took ownership; GDScript should NOT run its legacy loop.
//   < 0.0 → fall-back signal (binding broken, missing slot, size mismatch,
//           etc.) — the GDScript caller already does `if rc >= 0: return`.
//
// IMPORTANT: this function ONLY writes to `_slots[id].arr_*.ptrw()`, never
// calls `map_data->set(prop, arr)` to flush. The Step-5 probe proved that
// the bind_map_data CoW alias survives ptrw() writes, so the GDScript
// renderer already sees C++-side mutations on `map.temp_arr[i]` etc. with
// zero per-pass flush cost. This is the M2 hot-path pattern from charter §11.
// ─── Mode-B reference implementation: temp_drift_pass ─────────────────────
//
// The minimal canonical example for the "Owned-by-C++ + GDScript snapshot"
// communication contract documented in `docs/architecture/current-state.md` §12.
// Behaviour: for every element in _slots[CELL_TEMP].arr_f32, add
// `drift_amount`. Pure scalar, no SIMD, no threading — the goal is to
// ship a template that is impossible to get wrong, not to be fast.
//
// Hot-loop discipline (copy this verbatim into new passes):
//   * Resolve slot ids ONCE before the loop.
//   * Take ONE ptrw() pointer per output buffer.
//   * Loop body contains ZERO Variant / set() / get() / push_back calls.
//   * NO obj.set() flush — Mode B says GDScript pulls via snapshot_f32,
//     it does NOT rely on push-back aliasing.
//
// Safety: if `cell_temp` was never registered (e.g. unit-test run before
// MapData binding), the call is a no-op. No crash, no error log spam.
void DCWorldExt::run_temp_drift_pass(float drift_amount) {
    const int sid = component_id(StringName("cell_temp"));
    if (sid < 0) {
        return; // slot not registered yet → safe no-op
    }
    Slot &s = _slots.write[sid];
    if (s.dtype != SlotDType::F32) {
        return; // type mismatch → safe no-op
    }
    const int n = s.arr_f32.size();
    if (n <= 0) {
        return;
    }
    float * const __restrict p = s.arr_f32.ptrw();
    for (int i = 0; i < n; ++i) {
        p[i] += drift_amount;
    }
}

// ─── Pass #2: thermal_gradient_pass (reference impl with neighbour access) ──
// Implements `out = clamp(|∇T| * (1 + gain*elev) * k, 0, 1)` over a 2-D grid
// laid out row-major in the cell SoA arrays. Every step that could trip up
// a copy-paste author is annotated inline so the doc in performance-charter
// §12.6 can quote this code verbatim.
void DCWorldExt::run_thermal_gradient_pass(int grid_w,
                                           int grid_h,
                                           float elevation_gain,
                                           float normalize_k) {
    // ─── 1. Resolve slot ids ONCE (zero string ops in the hot loop) ────
    const int sid_temp = component_id(StringName("cell_temp"));
    const int sid_elev = component_id(StringName("cell_elevation"));
    const int sid_out  = component_id(StringName("cell_demo_thermal_gradient"));
    if (sid_temp < 0 || sid_elev < 0 || sid_out < 0) {
        UtilityFunctions::push_warning(
            "[DCWorldExt] run_thermal_gradient_pass: missing slot (",
            "cell_temp=", sid_temp,
            ", cell_elevation=", sid_elev,
            ", cell_demo_thermal_gradient=", sid_out,
            ") — pass skipped (likely demo_thermal_gradient_enabled=false)");
        return;
    }
    Slot &s_temp = _slots.write[sid_temp];
    Slot &s_elev = _slots.write[sid_elev];
    Slot &s_out  = _slots.write[sid_out];
    if (s_temp.dtype != SlotDType::F32 || s_elev.dtype != SlotDType::F32 ||
            s_out.dtype != SlotDType::F32) {
        UtilityFunctions::push_warning(
            "[DCWorldExt] run_thermal_gradient_pass: slot dtype mismatch — pass skipped");
        return;
    }

    // ─── 2. Validate grid dimensions vs. SoA size (paranoia, not optimisation) ─
    if (grid_w <= 0 || grid_h <= 0) {
        UtilityFunctions::push_warning(
            "[DCWorldExt] run_thermal_gradient_pass: invalid grid ", grid_w, "x", grid_h);
        return;
    }
    const int n = grid_w * grid_h;
    if (s_temp.arr_f32.size() != n || s_elev.arr_f32.size() != n ||
            s_out.arr_f32.size() != n) {
        UtilityFunctions::push_warning(
            "[DCWorldExt] run_thermal_gradient_pass: size mismatch (expected ", n,
            ", got temp=", s_temp.arr_f32.size(),
            ", elev=", s_elev.arr_f32.size(),
            ", out=", s_out.arr_f32.size(), ") — pass skipped");
        return;
    }

    // ─── 3. Take ONE pointer per buffer (read + write) ──────────────────
    const float * const __restrict T    = s_temp.arr_f32.ptr();
    const float * const __restrict E    = s_elev.arr_f32.ptr();
    float       * const __restrict OUT  = s_out.arr_f32.ptrw();

    // ─── 4. Tight loop — neighbour access by integer index, clamp-to-edge ─
    // Border discipline: substitute self-value for out-of-range neighbours
    // (Neumann BC). NEVER use modulo-wrap and NEVER branch inside the
    // arithmetic — branches at the boundary are fine, the compiler handles
    // them just like a peeled prologue/epilogue.
    for (int y = 0; y < grid_h; ++y) {
        const int row    = y * grid_w;
        const int row_n  = (y > 0)            ? (row - grid_w) : row;
        const int row_s  = (y < grid_h - 1)   ? (row + grid_w) : row;
        for (int x = 0; x < grid_w; ++x) {
            const int i  = row + x;
            const int iw = (x > 0)            ? (i - 1) : i;
            const int ie = (x < grid_w - 1)   ? (i + 1) : i;
            const int in_ = row_n + x;
            const int is = row_s + x;

            // ── BIT-EQUAL DISCIPLINE ─────────────────────────────────────
            // GDScript reads from PackedFloat32Array as `float`, which is a
            // 64-bit double in GDScript. All intermediate arithmetic on the
            // GDScript side therefore happens in double; the narrow back to
            // float only occurs at the store. Mirror that here: promote to
            // double on every load and narrow exactly once at the store.
            // Without this, the float-domain (gx*gx + gy*gy) addition and
            // the float gmag*amp*k product each round-off at a different
            // bit than the GDScript path, yielding ~40% of cells diverging
            // by 1 ULP. This is the canonical fix for Pass-#2 bit-equal.
            const double t_ie = static_cast<double>(T[ie]);
            const double t_iw = static_cast<double>(T[iw]);
            const double t_is = static_cast<double>(T[is]);
            const double t_in = static_cast<double>(T[in_]);
            const double e_i  = static_cast<double>(E[i]);

            const double gx = (t_ie - t_iw) * 0.5;
            const double gy = (t_is - t_in) * 0.5;
            const double gmag = Math::sqrt(gx * gx + gy * gy);
            const double amp  = 1.0 + static_cast<double>(elevation_gain) * e_i;
            double v = gmag * amp * static_cast<double>(normalize_k);
            // clamp to [0, 1] so the result is overlay-ready (R8/R16F).
            if (v < 0.0) v = 0.0;
            else if (v > 1.0) v = 1.0;
            // Single narrow at the store — matches `out[i] = v` in GDScript.
            OUT[i] = static_cast<float>(v);
        }
    }
}

// ─── Pass #3: demo_complex_pass (iterated diffusion + wind approx) ──────────
// Algorithm spec lives next to the declaration in world_ext.h. This impl
// keeps every line easily reviewable so performance-charter §12.6.6 can
// quote it verbatim. The inner stencil is intentionally scalar — Pass #3
// stresses *algorithmic* complexity, not SIMD/threading (per §0 铁律 2).
void DCWorldExt::run_demo_complex_pass(int grid_w,
                                       int grid_h,
                                       int iterations,
                                       int kernel_radius,
                                       float coriolis_strength,
                                       float terrain_drag,
                                       float elevation_gain,
                                       float normalize_k) {
    // ─── 0. Knob clamps (single push_warning per process for each knob) ─
    static bool _warned_iter = false;
    static bool _warned_kr   = false;
    static bool _warned_cor  = false;
    static bool _warned_drag = false;
    if (iterations < 1 || iterations > 64) {
        if (!_warned_iter) {
            _warned_iter = true;
            UtilityFunctions::push_warning(
                "[DCWorldExt] run_demo_complex_pass: iterations out of [1,64], clamped (was ",
                iterations, ")");
        }
        if (iterations < 1) iterations = 1;
        if (iterations > 64) iterations = 64;
    }
    if (kernel_radius < 1 || kernel_radius > 5) {
        if (!_warned_kr) {
            _warned_kr = true;
            UtilityFunctions::push_warning(
                "[DCWorldExt] run_demo_complex_pass: kernel_radius out of [1,5], clamped (was ",
                kernel_radius, ")");
        }
        if (kernel_radius < 1) kernel_radius = 1;
        if (kernel_radius > 5) kernel_radius = 5;
    }
    if (coriolis_strength < -1.0f || coriolis_strength > 1.0f) {
        if (!_warned_cor) {
            _warned_cor = true;
            UtilityFunctions::push_warning(
                "[DCWorldExt] run_demo_complex_pass: coriolis_strength out of [-1,1], clamped");
        }
        if (coriolis_strength < -1.0f) coriolis_strength = -1.0f;
        if (coriolis_strength > 1.0f)  coriolis_strength = 1.0f;
    }
    if (terrain_drag < 0.0f || terrain_drag > 1.0f) {
        if (!_warned_drag) {
            _warned_drag = true;
            UtilityFunctions::push_warning(
                "[DCWorldExt] run_demo_complex_pass: terrain_drag out of [0,1], clamped");
        }
        if (terrain_drag < 0.0f) terrain_drag = 0.0f;
        if (terrain_drag > 1.0f) terrain_drag = 1.0f;
    }

    // ─── 1. Resolve slot ids ONCE (zero string ops in the hot loop) ────
    const int sid_temp = component_id(StringName("cell_temp"));
    const int sid_elev = component_id(StringName("cell_elevation"));
    const int sid_out  = component_id(StringName("cell_demo_thermal_gradient"));
    if (sid_temp < 0 || sid_elev < 0 || sid_out < 0) {
        UtilityFunctions::push_warning(
            "[DCWorldExt] run_demo_complex_pass: missing slot (",
            "cell_temp=", sid_temp,
            ", cell_elevation=", sid_elev,
            ", cell_demo_thermal_gradient=", sid_out,
            ") — pass skipped");
        return;
    }
    Slot &s_temp = _slots.write[sid_temp];
    Slot &s_elev = _slots.write[sid_elev];
    Slot &s_out  = _slots.write[sid_out];
    if (s_temp.dtype != SlotDType::F32 || s_elev.dtype != SlotDType::F32 ||
            s_out.dtype != SlotDType::F32) {
        UtilityFunctions::push_warning(
            "[DCWorldExt] run_demo_complex_pass: slot dtype mismatch — pass skipped");
        return;
    }
    if (grid_w <= 0 || grid_h <= 0) {
        UtilityFunctions::push_warning(
            "[DCWorldExt] run_demo_complex_pass: invalid grid ", grid_w, "x", grid_h);
        return;
    }
    const int n = grid_w * grid_h;
    if (s_temp.arr_f32.size() != n || s_elev.arr_f32.size() != n ||
            s_out.arr_f32.size() != n) {
        UtilityFunctions::push_warning(
            "[DCWorldExt] run_demo_complex_pass: size mismatch (expected ", n,
            ", got temp=", s_temp.arr_f32.size(),
            ", elev=", s_elev.arr_f32.size(),
            ", out=", s_out.arr_f32.size(), ") — pass skipped");
        return;
    }

    // ─── 2. Take ONE pointer per buffer (read-only inputs) ──────────────
    const float * const __restrict T_in = s_temp.arr_f32.ptr();
    const float * const __restrict E    = s_elev.arr_f32.ptr();

    // ─── 3. Pre-compute Gaussian kernel weights (one C-stack lookup) ────
    //   Max radius = 5 → max kernel size = 11×11 = 121 entries.
    //   Stored row-major over (dy = -kr..+kr) × (dx = -kr..+kr).
    const int kr   = kernel_radius;
    const int ksz  = 2 * kr + 1;
    const int klen = ksz * ksz;
    double kernel[121]; // 11*11 hard cap — enforced by knob clamp
    double kernel_sum = 0.0;
    for (int dy = -kr; dy <= kr; ++dy) {
        for (int dx = -kr; dx <= kr; ++dx) {
            // exp(-(dx²+dy²)/2) — fixed sigma=1 keeps the kernel compact
            // and the GDScript port byte-for-byte easy to replicate.
            const double w = std::exp(-(double)(dx * dx + dy * dy) * 0.5);
            kernel[(dy + kr) * ksz + (dx + kr)] = w;
            kernel_sum += w;
        }
    }
    const double kernel_inv_sum = (kernel_sum > 0.0) ? (1.0 / kernel_sum) : 0.0;

    // ─── 4. Allocate ping-pong buffers ONCE (outside iter loop) ─────────
    // Stored as double to keep bit-equal discipline with GDScript port.
    std::vector<double> buf_a(n);
    std::vector<double> buf_b(n);
    for (int i = 0; i < n; ++i) {
        buf_a[i] = static_cast<double>(T_in[i]);
    }

    const double step_size = 0.05;       // fixed stability constant (see §12.6.6)
    const double cor       = static_cast<double>(coriolis_strength);
    const double drag      = static_cast<double>(terrain_drag);

    // ─── 5. Iterate `iterations` steps (ping-pong) ──────────────────────
    for (int it = 0; it < iterations; ++it) {
        const std::vector<double> &src = (it & 1) ? buf_b : buf_a;
        std::vector<double>       &dst = (it & 1) ? buf_a : buf_b;
        const double *__restrict S = src.data();
        double       *__restrict D = dst.data();

        for (int y = 0; y < grid_h; ++y) {
            // Latitude-dependent coriolis sign: north hemisphere → +1, south → -1
            const double cor_sign = (y < grid_h / 2) ? -1.0 : 1.0;
            const double rot_rad  = cor * cor_sign * 1.5707963267948966; // π/2

            for (int x = 0; x < grid_w; ++x) {
                const int i = y * grid_w + x;

                // ─── 5.1 Gaussian-weighted smooth (2kr+1)² stencil ────
                double accum = 0.0;
                for (int dy = -kr; dy <= kr; ++dy) {
                    int ny = y + dy;
                    if (ny < 0)         ny = 0;
                    else if (ny >= grid_h) ny = grid_h - 1;
                    const int row = ny * grid_w;
                    const double *kw_row = &kernel[(dy + kr) * ksz];
                    for (int dx = -kr; dx <= kr; ++dx) {
                        int nx = x + dx;
                        if (nx < 0)         nx = 0;
                        else if (nx >= grid_w) nx = grid_w - 1;
                        accum += S[row + nx] * kw_row[dx + kr];
                    }
                }
                const double smooth = accum * kernel_inv_sum;

                // ─── 5.2 Sobel 3×3 gradient (clamp-to-edge) ───────────
                const int xw = (x > 0)            ? (x - 1) : x;
                const int xe = (x < grid_w - 1)   ? (x + 1) : x;
                const int yn = (y > 0)            ? (y - 1) : y;
                const int ys = (y < grid_h - 1)   ? (y + 1) : y;
                const int row_n = yn * grid_w;
                const int row_c = y  * grid_w;
                const int row_s = ys * grid_w;
                const double gx = (S[row_n + xe] + 2.0 * S[row_c + xe] + S[row_s + xe]
                                  - S[row_n + xw] - 2.0 * S[row_c + xw] - S[row_s + xw]) * 0.125;
                const double gy = (S[row_s + xw] + 2.0 * S[row_s + x ] + S[row_s + xe]
                                  - S[row_n + xw] - 2.0 * S[row_n + x ] - S[row_n + xe]) * 0.125;

                // ─── 5.3 Coriolis rotation (90° × cor_sign × strength) ─
                const double cs = std::cos(rot_rad);
                const double sn = std::sin(rot_rad);
                const double gx_p = gx * cs - gy * sn;
                const double gy_p = gx * sn + gy * cs;

                // ─── 5.4 Terrain damping ─────────────────────────────
                const double damp = 1.0 - drag * static_cast<double>(E[i]);

                // ─── 5.5 Flux-driven evolution ───────────────────────
                const double flux = gx_p + gy_p;
                D[i] = smooth + flux * damp * step_size;
            }
        }
    }

    // ─── 6. Pick the final buffer ───────────────────────────────────────
    const std::vector<double> &last = (iterations & 1) ? buf_b : buf_a;

    // ─── 7. Normalize to [0,1] over the whole field ─────────────────────
    double out_min =  std::numeric_limits<double>::infinity();
    double out_max = -std::numeric_limits<double>::infinity();
    for (int i = 0; i < n; ++i) {
        const double v = last[i];
        if (v < out_min) out_min = v;
        if (v > out_max) out_max = v;
    }
    const double denom = (out_max - out_min) > 1.0e-6
                       ? (out_max - out_min) : 1.0e-6;
    const double inv_denom = 1.0 / denom;

    // ─── 8. Apply (1 + gain·elev) · k + clamp to [0,1], narrow to float ─
    float * const __restrict OUT = s_out.arr_f32.ptrw();
    const double gain = static_cast<double>(elevation_gain);
    const double k    = static_cast<double>(normalize_k);
    for (int i = 0; i < n; ++i) {
        const double norm = (last[i] - out_min) * inv_denom;
        const double amp  = 1.0 + gain * static_cast<double>(E[i]);
        double v = norm * amp * k;
        if (v < 0.0) v = 0.0;
        else if (v > 1.0) v = 1.0;
        OUT[i] = static_cast<float>(v);
    }
}

// ─── DOTS-A1 EXPERIMENT: run_demo_complex_pass_archetyped ────────────────────
// See world_ext.h for the contract. Implementation strategy:
//
//   * The iteration kernel itself runs on EVERY cell (so neighbour stencils
//     stay valid — a LAND cell at the border of an OCEAN region must still
//     read its OCEAN neighbours' temp values during the smoothing/sobel
//     stage). This is the algorithmically faithful interpretation of
//     "archetype filter": filter the *write*, not the neighbour-read.
//
//   * The post-iter normalize+output stage (steps 7+8 in vanilla) honours
//     the archetype filter:
//       - cells with arch != target → OUT[i] = 0.0f, skipped from min/max.
//       - cells with arch == target → standard normalize + amp + clamp.
//
//   * `target_archetype < 0` is the "no filter" control row. It is
//     algorithmically identical to vanilla `run_demo_complex_pass` — the
//     bench uses this to confirm bit-equal with the vanilla pass and
//     measure the "extra branch overhead" on its own.
//
// NOTE: We deliberately keep this implementation as a near-verbatim copy
// of `run_demo_complex_pass`. Sharing code via a template/helper would
// make the bench less useful (we'd be measuring the helper's call cost
// rather than the archetype branch's cost on its own).
void DCWorldExt::run_demo_complex_pass_archetyped(int grid_w,
                                                  int grid_h,
                                                  int iterations,
                                                  int kernel_radius,
                                                  float coriolis_strength,
                                                  float terrain_drag,
                                                  float elevation_gain,
                                                  float normalize_k,
                                                  int target_archetype) {
    // ─── 0. Knob clamps (silent — vanilla version owns the warning prints) ─
    if (iterations < 1)        iterations = 1;
    if (iterations > 64)       iterations = 64;
    if (kernel_radius < 1)     kernel_radius = 1;
    if (kernel_radius > 5)     kernel_radius = 5;
    if (coriolis_strength < -1.0f) coriolis_strength = -1.0f;
    if (coriolis_strength >  1.0f) coriolis_strength =  1.0f;
    if (terrain_drag < 0.0f)   terrain_drag = 0.0f;
    if (terrain_drag > 1.0f)   terrain_drag = 1.0f;

    // ─── 1. Resolve slot ids ONCE ──────────────────────────────────────
    const int sid_temp = component_id(StringName("cell_temp"));
    const int sid_elev = component_id(StringName("cell_elevation"));
    const int sid_out  = component_id(StringName("cell_demo_thermal_gradient"));
    if (sid_temp < 0 || sid_elev < 0 || sid_out < 0) {
        UtilityFunctions::push_warning(
            "[DCWorldExt] run_demo_complex_pass_archetyped: missing slot");
        return;
    }
    Slot &s_temp = _slots.write[sid_temp];
    Slot &s_elev = _slots.write[sid_elev];
    Slot &s_out  = _slots.write[sid_out];
    if (s_temp.dtype != SlotDType::F32 || s_elev.dtype != SlotDType::F32 ||
            s_out.dtype != SlotDType::F32) {
        UtilityFunctions::push_warning(
            "[DCWorldExt] run_demo_complex_pass_archetyped: slot dtype mismatch — pass skipped");
        return;
    }
    if (grid_w <= 0 || grid_h <= 0) {
        UtilityFunctions::push_warning(
            "[DCWorldExt] run_demo_complex_pass_archetyped: invalid grid ", grid_w, "x", grid_h);
        return;
    }
    const int n = grid_w * grid_h;
    if (s_temp.arr_f32.size() != n || s_elev.arr_f32.size() != n ||
            s_out.arr_f32.size() != n) {
        UtilityFunctions::push_warning(
            "[DCWorldExt] run_demo_complex_pass_archetyped: size mismatch (expected ", n,
            ", got temp=", s_temp.arr_f32.size(),
            ", elev=", s_elev.arr_f32.size(),
            ", out=", s_out.arr_f32.size(), ") — pass skipped");
        return;
    }

    // Archetype array bound check (only meaningful if filter is active).
    const bool   filter_active = (target_archetype >= 0);
    const int32_t * const __restrict ARCH = filter_active
        ? _entity_archetype.ptr() : nullptr;
    if (filter_active && _entity_archetype.size() < n) {
        UtilityFunctions::push_warning(
            "[DCWorldExt] run_demo_complex_pass_archetyped: _entity_archetype size ",
            _entity_archetype.size(), " < n ", n,
            " — assign_archetype not called for all cells; pass skipped");
        return;
    }

    // ─── 2. Take ONE pointer per buffer (read-only inputs) ──────────────
    const float * const __restrict T_in = s_temp.arr_f32.ptr();
    const float * const __restrict E    = s_elev.arr_f32.ptr();

    // ─── 3. Pre-compute Gaussian kernel weights ──────────────────────────
    const int kr   = kernel_radius;
    const int ksz  = 2 * kr + 1;
    double kernel[121]; // 11*11 hard cap
    double kernel_sum = 0.0;
    for (int dy = -kr; dy <= kr; ++dy) {
        for (int dx = -kr; dx <= kr; ++dx) {
            const double w = std::exp(-(double)(dx * dx + dy * dy) * 0.5);
            kernel[(dy + kr) * ksz + (dx + kr)] = w;
            kernel_sum += w;
        }
    }
    const double kernel_inv_sum = (kernel_sum > 0.0) ? (1.0 / kernel_sum) : 0.0;

    // ─── 4. Allocate ping-pong buffers ONCE ──────────────────────────────
    std::vector<double> buf_a(n);
    std::vector<double> buf_b(n);
    for (int i = 0; i < n; ++i) {
        buf_a[i] = static_cast<double>(T_in[i]);
    }

    const double step_size = 0.05;
    const double cor       = static_cast<double>(coriolis_strength);
    const double drag      = static_cast<double>(terrain_drag);

    // ─── 5. Iterate (every cell participates in the stencil — see banner) ─
    for (int it = 0; it < iterations; ++it) {
        const std::vector<double> &src = (it & 1) ? buf_b : buf_a;
        std::vector<double>       &dst = (it & 1) ? buf_a : buf_b;
        const double *__restrict S = src.data();
        double       *__restrict D = dst.data();

        for (int y = 0; y < grid_h; ++y) {
            const double cor_sign = (y < grid_h / 2) ? -1.0 : 1.0;
            const double rot_rad  = cor * cor_sign * 1.5707963267948966;

            for (int x = 0; x < grid_w; ++x) {
                const int i = y * grid_w + x;

                double accum = 0.0;
                for (int dy = -kr; dy <= kr; ++dy) {
                    int ny = y + dy;
                    if (ny < 0)            ny = 0;
                    else if (ny >= grid_h) ny = grid_h - 1;
                    const int row = ny * grid_w;
                    const double *kw_row = &kernel[(dy + kr) * ksz];
                    for (int dx = -kr; dx <= kr; ++dx) {
                        int nx = x + dx;
                        if (nx < 0)            nx = 0;
                        else if (nx >= grid_w) nx = grid_w - 1;
                        accum += S[row + nx] * kw_row[dx + kr];
                    }
                }
                const double smooth = accum * kernel_inv_sum;

                const int xw = (x > 0)            ? (x - 1) : x;
                const int xe = (x < grid_w - 1)   ? (x + 1) : x;
                const int yn = (y > 0)            ? (y - 1) : y;
                const int ys = (y < grid_h - 1)   ? (y + 1) : y;
                const int row_n = yn * grid_w;
                const int row_c = y  * grid_w;
                const int row_s = ys * grid_w;
                const double gx = (S[row_n + xe] + 2.0 * S[row_c + xe] + S[row_s + xe]
                                  - S[row_n + xw] - 2.0 * S[row_c + xw] - S[row_s + xw]) * 0.125;
                const double gy = (S[row_s + xw] + 2.0 * S[row_s + x ] + S[row_s + xe]
                                  - S[row_n + xw] - 2.0 * S[row_n + x ] - S[row_n + xe]) * 0.125;

                const double cs = std::cos(rot_rad);
                const double sn = std::sin(rot_rad);
                const double gx_p = gx * cs - gy * sn;
                const double gy_p = gx * sn + gy * cs;

                const double damp = 1.0 - drag * static_cast<double>(E[i]);
                const double flux = gx_p + gy_p;
                D[i] = smooth + flux * damp * step_size;
            }
        }
    }

    const std::vector<double> &last = (iterations & 1) ? buf_b : buf_a;

    // ─── 6+7. Archetype-aware normalization (only filtered-in cells count) ─
    double out_min =  std::numeric_limits<double>::infinity();
    double out_max = -std::numeric_limits<double>::infinity();
    if (filter_active) {
        for (int i = 0; i < n; ++i) {
            if (ARCH[i] != target_archetype) continue;
            const double v = last[i];
            if (v < out_min) out_min = v;
            if (v > out_max) out_max = v;
        }
        // Edge case: no cell matched the filter at all → leave OUT untouched
        // for non-matching cells, write 0.0f. min/max never updated → guard.
        if (!std::isfinite(out_min) || !std::isfinite(out_max)) {
            float * const __restrict OUT = s_out.arr_f32.ptrw();
            for (int i = 0; i < n; ++i) OUT[i] = 0.0f;
            return;
        }
    } else {
        for (int i = 0; i < n; ++i) {
            const double v = last[i];
            if (v < out_min) out_min = v;
            if (v > out_max) out_max = v;
        }
    }
    const double denom = (out_max - out_min) > 1.0e-6
                       ? (out_max - out_min) : 1.0e-6;
    const double inv_denom = 1.0 / denom;

    // ─── 8. Write OUT (filtered-in: full formula; filtered-out: 0.0f) ─────
    float * const __restrict OUT = s_out.arr_f32.ptrw();
    const double gain = static_cast<double>(elevation_gain);
    const double k    = static_cast<double>(normalize_k);
    if (filter_active) {
        for (int i = 0; i < n; ++i) {
            if (ARCH[i] != target_archetype) {
                OUT[i] = 0.0f;
                continue;
            }
            const double norm = (last[i] - out_min) * inv_denom;
            const double amp  = 1.0 + gain * static_cast<double>(E[i]);
            double v = norm * amp * k;
            if (v < 0.0) v = 0.0;
            else if (v > 1.0) v = 1.0;
            OUT[i] = static_cast<float>(v);
        }
    } else {
        for (int i = 0; i < n; ++i) {
            const double norm = (last[i] - out_min) * inv_denom;
            const double amp  = 1.0 + gain * static_cast<double>(E[i]);
            double v = norm * amp * k;
            if (v < 0.0) v = 0.0;
            else if (v > 1.0) v = 1.0;
            OUT[i] = static_cast<float>(v);
        }
    }
}

// ─── Phase 3a Step 0: alias spike (TEMPORARY) ─────────────────────────────
// What we are testing: does godot-cpp's PackedFloat32Array share its
// underlying CowData with the GDScript-side property after we `set()` it
// back? If yes, ptrw() does not detach and the GDScript side sees C++ writes.
// If no, we need a different strategy for bind_map_data (likely write-then-
// set per hot-loop invocation, or reverse-anchor the buffer ownership).
//
// Reads `obj.<prop>` after the in-C++ mutation and returns it so the GDScript
// caller can verify directly (we don't trust C++-side reads to prove anything
// about cross-boundary visibility).


// ─── Phase-3 micro-bench API ────────────────────────────────────────────────
//
// All bench paths share the same per-cell math:
//   nb_sum = prev[nb[6*i+0]] + prev[nb[6*i+1]] + ... + prev[nb[6*i+5]]
//   new[i] = base + lat[i]*k1 + nb_sum*k2 + season
// and write into _slots[comp_id].arr_f32 via raw ptrw().
//
// Three implementations exist for fairness — same workload, different code:
//   - *_scalar : straight C++ for-loop, lets compiler decide on vectorisation.
//   - *_simd   : explicit AVX2 8-wide gather for the 6 neighbours.
//                Falls back to scalar when PK_HAVE_AVX2=0.
//   - *_thread : *_simd kernel split across n_tasks WorkerThreadPool workers.
//
// "_full" variants iterate every cell in the slot.
// "_indexed" variants iterate only `dirty` indices (sparse Pass-B style).
// All variants assume neighbours.size() == 6 * cell_count.
// ────────────────────────────────────────────────────────────────────────────


// ─── Class binding ─────────────────────────────────────────────────────────


} // namespace pk
