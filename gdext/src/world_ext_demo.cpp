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
#include <godot_cpp/classes/worker_thread_pool.hpp>
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
// communication contract documented in `docs/performance-charter.md` §12.
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

float DCWorldExt::_spike_alias_v1_naive(Object *obj, const StringName &prop, int idx, float sentinel) {
    if (obj == nullptr) {
        UtilityFunctions::push_error("[spike v1] null obj");
        return -9999.0f;
    }
    Variant v = obj->get(prop);
    if (v.get_type() != Variant::PACKED_FLOAT32_ARRAY) {
        UtilityFunctions::push_error("[spike v1] prop is not PackedFloat32Array");
        return -9999.0f;
    }
    PackedFloat32Array arr = v;        // refcount: GDScript side + this local
    obj->set(prop, arr);                // explicit reseat (idempotent in theory)
    if (idx < 0 || idx >= arr.size()) {
        UtilityFunctions::push_error("[spike v1] idx out of range");
        return -9999.0f;
    }
    float *w = arr.ptrw();              // <-- may detach (CoW) here
    w[idx] = sentinel;
    // Read what GDScript side actually has now.
    Variant v_after = obj->get(prop);
    PackedFloat32Array arr_after = v_after;
    return arr_after[idx];
}

float DCWorldExt::_spike_alias_v2_release(Object *obj, const StringName &prop, int idx, float sentinel) {
    if (obj == nullptr) {
        UtilityFunctions::push_error("[spike v2] null obj");
        return -9999.0f;
    }
    {
        Variant v = obj->get(prop);
        PackedFloat32Array arr = v;
        obj->set(prop, arr);
        // arr / v go out of scope here, dropping the C++ ref.
    }
    // Re-acquire after we (hopefully) have GDScript as sole owner.
    Variant v2 = obj->get(prop);
    PackedFloat32Array arr2 = v2;
    if (idx < 0 || idx >= arr2.size()) {
        UtilityFunctions::push_error("[spike v2] idx out of range");
        return -9999.0f;
    }
    // Now refcount on Godot side: GDScript-prop + arr2 + Variant v2 = at least 2.
    // Still >1 because we are holding it. ptrw will likely still detach.
    float *w = arr2.ptrw();
    w[idx] = sentinel;
    Variant v_after = obj->get(prop);
    PackedFloat32Array arr_after = v_after;
    return arr_after[idx];
}

float DCWorldExt::_spike_alias_v3_write_then_set(Object *obj, const StringName &prop, int idx, float sentinel) {
    if (obj == nullptr) {
        UtilityFunctions::push_error("[spike v3] null obj");
        return -9999.0f;
    }
    Variant v = obj->get(prop);
    PackedFloat32Array arr = v;
    if (idx < 0 || idx >= arr.size()) {
        UtilityFunctions::push_error("[spike v3] idx out of range");
        return -9999.0f;
    }
    // Mutate first (will detach into a new buffer owned by `arr`),
    // then push the new buffer back to GDScript via set.
    float *w = arr.ptrw();
    w[idx] = sentinel;
    obj->set(prop, arr);
    Variant v_after = obj->get(prop);
    PackedFloat32Array arr_after = v_after;
    return arr_after[idx];
}

// ─── Phase 3a Step 1: alias verification helper (TEMPORARY) ───────────────
// Pure C++-side write into _slots[comp_id].arr_f32[idx], no obj.set.
// If bind_map_data's push-back contract works, the GDScript side sees this
// write immediately on the next read of the bound property.
float DCWorldExt::_debug_poke_f32(int comp_id, int idx, float sentinel) {
    if (comp_id < 0 || comp_id >= _slots.size()) {
        UtilityFunctions::push_error("[_debug_poke_f32] comp_id out of range: ", comp_id);
        return -9999.0f;
    }
    Slot &s = _slots.write[comp_id];
    if (s.dtype != SlotDType::F32) {
        UtilityFunctions::push_error("[_debug_poke_f32] slot is not F32: ", comp_id);
        return -9999.0f;
    }
    if (idx < 0 || idx >= s.arr_f32.size()) {
        UtilityFunctions::push_error("[_debug_poke_f32] idx out of range: ", idx, " / ", s.arr_f32.size());
        return -9999.0f;
    }
    // Same access pattern as a real hot loop: ptrw() on the C++-held buffer.
    // No obj.set() afterwards — the entire point is to prove the alias.
    float *w = s.arr_f32.ptrw();
    w[idx] = sentinel;
    return sentinel;
}

// ─── Phase 3a Step 1 (T1b): write-then-set per call ────────────────────────
// Same write as _debug_poke_f32, but immediately push s.arr_f32 back to the
// GDScript-side property via map_data->set(prop_name, s.arr_f32). If this
// PASSes the GDScript-visibility check while plain _debug_poke_f32 FAILs,
// then ptrw() on the C++-held buffer triggered a CoW detach (refcount 2 →
// private copy) and the only viable alias contract is "C++ end-of-pass set
// flush". Looks up prop_name from the file-local BIND_TABLE.
float DCWorldExt::_debug_poke_f32_with_flush(int comp_id, int idx, float sentinel) {
    if (_map_data == nullptr) {
        UtilityFunctions::push_error("[_debug_poke_f32_with_flush] not bound (call bind_map_data first)");
        return -9999.0f;
    }
    if (comp_id < 0 || comp_id >= _slots.size()) {
        UtilityFunctions::push_error("[_debug_poke_f32_with_flush] comp_id out of range: ", comp_id);
        return -9999.0f;
    }
    Slot &s = _slots.write[comp_id];
    if (s.dtype != SlotDType::F32) {
        UtilityFunctions::push_error("[_debug_poke_f32_with_flush] slot is not F32: ", comp_id);
        return -9999.0f;
    }
    if (idx < 0 || idx >= s.arr_f32.size()) {
        UtilityFunctions::push_error("[_debug_poke_f32_with_flush] idx out of range: ", idx, " / ", s.arr_f32.size());
        return -9999.0f;
    }
    // Reverse-lookup prop_name via slot.name in BIND_TABLE.
    const char *prop_cstr = nullptr;
    for (int i = 0; i < BIND_TABLE_SIZE; ++i) {
        if (s.name == StringName(BIND_TABLE[i].slot_name)) {
            prop_cstr = BIND_TABLE[i].property_name;
            break;
        }
    }
    if (prop_cstr == nullptr) {
        UtilityFunctions::push_error("[_debug_poke_f32_with_flush] slot ", s.name, " not in BIND_TABLE");
        return -9999.0f;
    }
    // Write via ptrw() (may CoW-detach into a private buffer)…
    float *w = s.arr_f32.ptrw();
    w[idx] = sentinel;
    // …then push the (possibly-new) buffer back so GDScript side sees it.
    _map_data->set(StringName(prop_cstr), s.arr_f32);
    return sentinel;
}

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

namespace {

// ── shared scalar kernel ─────────────────────────────────────────────────
inline void pass_a_kernel_scalar(float *out_ptr,
                                 const float   *lat_ptr,
                                 const float   *prev_ptr,
                                 const int32_t *nb_ptr,
                                 int            i,
                                 float k1, float k2, float base, float season) {
    const int32_t *nb6 = nb_ptr + i * 6;
    const float nb_sum = prev_ptr[nb6[0]] + prev_ptr[nb6[1]] + prev_ptr[nb6[2]]
                       + prev_ptr[nb6[3]] + prev_ptr[nb6[4]] + prev_ptr[nb6[5]];
    out_ptr[i] = base + lat_ptr[i] * k1 + nb_sum * k2 + season;
}

#if defined(PK_HAVE_AVX2) && PK_HAVE_AVX2
// ── AVX2 SIMD kernel (8 cells / iter) ────────────────────────────────────
// Strategy: 6 separate 8-wide gathers from prev[] using nb[6*i+k] indices,
// hsum into nb_sum, then fma chain for the result.
// Note: gather throughput on Skylake = 1 per cell on average; this is ~
// 4x faster than scalar despite gather not being free, because the loop
// body otherwise spends most of its time on memory dependency chains.
inline void pass_a_simd_block_full(float *out_ptr,
                                   const float   *lat_ptr,
                                   const float   *prev_ptr,
                                   const int32_t *nb_ptr,
                                   int   i_begin,    // must be in [0, count - 8]
                                   float k1, float k2, float base, float season) {
    // Load lat[i..i+7]
    __m256 lat = _mm256_loadu_ps(lat_ptr + i_begin);

    // For each of 6 neighbour slots, gather prev[nb[6*(i+k) + slot]] for k=0..7.
    // nb is laid out as flat [6*count] int32 — for a contiguous stride-1
    // group of 8 cells, the indices for slot s are at offsets
    //   nb_ptr[6*i + s], nb_ptr[6*(i+1) + s], ..., nb_ptr[6*(i+7) + s]
    // i.e. stride 6 in nb_ptr. Build that index vector once, then gather prev.
    __m256i stride6 = _mm256_setr_epi32(0, 6, 12, 18, 24, 30, 36, 42);
    __m256 nb_sum = _mm256_setzero_ps();
    const int32_t *nb_base = nb_ptr + 6 * i_begin;
    for (int s = 0; s < 6; ++s) {
        // Load 8 indices: nb_base[s + 6k] for k=0..7
        __m256i idx = _mm256_add_epi32(stride6, _mm256_set1_epi32(s));
        idx = _mm256_i32gather_epi32(nb_base, idx, 4);
        __m256 vals = _mm256_i32gather_ps(prev_ptr, idx, 4);
        nb_sum = _mm256_add_ps(nb_sum, vals);
    }

    __m256 vk1     = _mm256_set1_ps(k1);
    __m256 vk2     = _mm256_set1_ps(k2);
    __m256 vbase_s = _mm256_set1_ps(base + season);

    // result = (base+season) + lat*k1 + nb_sum*k2
    __m256 result = _mm256_fmadd_ps(lat,    vk1, vbase_s);
    result        = _mm256_fmadd_ps(nb_sum, vk2, result);

    _mm256_storeu_ps(out_ptr + i_begin, result);
}
#endif

// ── thread task payload ──────────────────────────────────────────────────
struct PassAFullTask {
    float         *out_ptr;
    const float   *lat_ptr;
    const float   *prev_ptr;
    const int32_t *nb_ptr;
    int            count;
    float          k1, k2, base, season;
    int            n_tasks;
};

// Each worker handles `chunk = ceil(count / n_tasks)` cells starting at
// `task_idx * chunk`. Tail handling is done with scalar.
static void pass_a_full_worker(void *userdata, uint32_t task_idx) {
    auto *t = static_cast<PassAFullTask *>(userdata);
    const int chunk = (t->count + t->n_tasks - 1) / t->n_tasks;
    const int begin = static_cast<int>(task_idx) * chunk;
    const int end   = std::min(begin + chunk, t->count);

    int i = begin;
#if defined(PK_HAVE_AVX2) && PK_HAVE_AVX2
    // SIMD body — leaves the last <8 cells to scalar tail.
    const int simd_end = end - ((end - begin) % 8);
    for (; i + 8 <= simd_end; i += 8) {
        pass_a_simd_block_full(t->out_ptr, t->lat_ptr, t->prev_ptr, t->nb_ptr,
                               i, t->k1, t->k2, t->base, t->season);
    }
#endif
    for (; i < end; ++i) {
        pass_a_kernel_scalar(t->out_ptr, t->lat_ptr, t->prev_ptr, t->nb_ptr,
                             i, t->k1, t->k2, t->base, t->season);
    }
}

struct PassAIndexedTask {
    float         *out_ptr;
    const int32_t *dirty_ptr;
    const float   *lat_ptr;
    const float   *prev_ptr;
    const int32_t *nb_ptr;
    int            cap;          // bounds for dirty[k]
    int            n_dirty;
    float          k1, k2, base, season;
    int            n_tasks;
};

static void pass_a_indexed_worker(void *userdata, uint32_t task_idx) {
    auto *t = static_cast<PassAIndexedTask *>(userdata);
    const int chunk = (t->n_dirty + t->n_tasks - 1) / t->n_tasks;
    const int begin = static_cast<int>(task_idx) * chunk;
    const int end   = std::min(begin + chunk, t->n_dirty);
    // Indexed paths can't use a contiguous SIMD block (gather indices are not
    // stride-1 across dirty[]). Stick with scalar; the win comes from
    // multi-threaded throughput.
    for (int k = begin; k < end; ++k) {
        const int i = t->dirty_ptr[k];
        if (i < 0 || i >= t->cap) continue;
        pass_a_kernel_scalar(t->out_ptr, t->lat_ptr, t->prev_ptr, t->nb_ptr,
                             i, t->k1, t->k2, t->base, t->season);
    }
}

} // namespace

// ─── full / scalar ───────────────────────────────────────────────────────
void DCWorldExt::bench_pass_a_full_scalar(int comp_id,
                                          const PackedFloat32Array &lat,
                                          const PackedFloat32Array &prev,
                                          const PackedInt32Array   &neighbors,
                                          float k1, float k2, float base, float season) {
    ERR_FAIL_INDEX(comp_id, _slots.size());
    Slot &s = _slots.write[comp_id];
    const int count = s.arr_f32.size();
    ERR_FAIL_COND(lat.size()       < count);
    ERR_FAIL_COND(prev.size()      < count);
    ERR_FAIL_COND(neighbors.size() < count * 6);

    float         *out_ptr  = s.arr_f32.ptrw();
    const float   *lat_ptr  = lat.ptr();
    const float   *prev_ptr = prev.ptr();
    const int32_t *nb_ptr   = neighbors.ptr();
    for (int i = 0; i < count; ++i) {
        pass_a_kernel_scalar(out_ptr, lat_ptr, prev_ptr, nb_ptr, i, k1, k2, base, season);
    }
}

// ─── full / SIMD ────────────────────────────────────────────────────────
void DCWorldExt::bench_pass_a_full_simd(int comp_id,
                                        const PackedFloat32Array &lat,
                                        const PackedFloat32Array &prev,
                                        const PackedInt32Array   &neighbors,
                                        float k1, float k2, float base, float season) {
    ERR_FAIL_INDEX(comp_id, _slots.size());
    Slot &s = _slots.write[comp_id];
    const int count = s.arr_f32.size();
    ERR_FAIL_COND(lat.size()       < count);
    ERR_FAIL_COND(prev.size()      < count);
    ERR_FAIL_COND(neighbors.size() < count * 6);

    float         *out_ptr  = s.arr_f32.ptrw();
    const float   *lat_ptr  = lat.ptr();
    const float   *prev_ptr = prev.ptr();
    const int32_t *nb_ptr   = neighbors.ptr();

    int i = 0;
#if defined(PK_HAVE_AVX2) && PK_HAVE_AVX2
    const int simd_end = count - (count % 8);
    for (; i + 8 <= simd_end; i += 8) {
        pass_a_simd_block_full(out_ptr, lat_ptr, prev_ptr, nb_ptr, i,
                               k1, k2, base, season);
    }
#endif
    for (; i < count; ++i) {
        pass_a_kernel_scalar(out_ptr, lat_ptr, prev_ptr, nb_ptr, i,
                             k1, k2, base, season);
    }
}

// ─── full / threaded ────────────────────────────────────────────────────
void DCWorldExt::bench_pass_a_full_thread(int comp_id,
                                          const PackedFloat32Array &lat,
                                          const PackedFloat32Array &prev,
                                          const PackedInt32Array   &neighbors,
                                          float k1, float k2, float base, float season,
                                          int n_tasks) {
    ERR_FAIL_INDEX(comp_id, _slots.size());
    Slot &s = _slots.write[comp_id];
    const int count = s.arr_f32.size();
    ERR_FAIL_COND(lat.size()       < count);
    ERR_FAIL_COND(prev.size()      < count);
    ERR_FAIL_COND(neighbors.size() < count * 6);
    if (n_tasks < 1) n_tasks = 1;

    PassAFullTask task = {
        s.arr_f32.ptrw(),
        lat.ptr(),
        prev.ptr(),
        neighbors.ptr(),
        count,
        k1, k2, base, season,
        n_tasks,
    };
    WorkerThreadPool *wtp = WorkerThreadPool::get_singleton();
    if (wtp == nullptr) {
        // Fallback: run in-thread.
        for (int t = 0; t < n_tasks; ++t) {
            pass_a_full_worker(&task, static_cast<uint32_t>(t));
        }
        return;
    }
    int64_t group_id = wtp->add_native_group_task(
        &pass_a_full_worker, &task, n_tasks, -1, true, String("pk_pass_a_full"));
    wtp->wait_for_group_task_completion(group_id);
}

// ─── indexed / scalar ───────────────────────────────────────────────────
void DCWorldExt::bench_pass_a_indexed_scalar(int comp_id,
                                             const PackedInt32Array   &dirty,
                                             const PackedFloat32Array &lat,
                                             const PackedFloat32Array &prev,
                                             const PackedInt32Array   &neighbors,
                                             float k1, float k2, float base, float season) {
    ERR_FAIL_INDEX(comp_id, _slots.size());
    Slot &s = _slots.write[comp_id];
    const int cap = s.arr_f32.size();
    float         *out_ptr   = s.arr_f32.ptrw();
    const int32_t *dirty_ptr = dirty.ptr();
    const float   *lat_ptr   = lat.ptr();
    const float   *prev_ptr  = prev.ptr();
    const int32_t *nb_ptr    = neighbors.ptr();
    const int      n_dirty   = dirty.size();
    for (int k = 0; k < n_dirty; ++k) {
        const int i = dirty_ptr[k];
        if (i < 0 || i >= cap) continue;
        pass_a_kernel_scalar(out_ptr, lat_ptr, prev_ptr, nb_ptr, i,
                             k1, k2, base, season);
    }
}

// ─── indexed / "SIMD" — same as scalar; no contiguous gather possible ───
// We still expose this as a separate API to keep bench tables symmetrical.
void DCWorldExt::bench_pass_a_indexed_simd(int comp_id,
                                           const PackedInt32Array   &dirty,
                                           const PackedFloat32Array &lat,
                                           const PackedFloat32Array &prev,
                                           const PackedInt32Array   &neighbors,
                                           float k1, float k2, float base, float season) {
    // Sparse access pattern — SIMD gather offers no advantage and complicates
    // tail handling. Punt to scalar (which compiler may still vectorise).
    bench_pass_a_indexed_scalar(comp_id, dirty, lat, prev, neighbors,
                                k1, k2, base, season);
}

// ─── indexed / threaded ─────────────────────────────────────────────────
void DCWorldExt::bench_pass_a_indexed_thread(int comp_id,
                                             const PackedInt32Array   &dirty,
                                             const PackedFloat32Array &lat,
                                             const PackedFloat32Array &prev,
                                             const PackedInt32Array   &neighbors,
                                             float k1, float k2, float base, float season,
                                             int n_tasks) {
    ERR_FAIL_INDEX(comp_id, _slots.size());
    Slot &s = _slots.write[comp_id];
    const int cap     = s.arr_f32.size();
    const int n_dirty = dirty.size();
    if (n_tasks < 1) n_tasks = 1;

    PassAIndexedTask task = {
        s.arr_f32.ptrw(),
        dirty.ptr(),
        lat.ptr(),
        prev.ptr(),
        neighbors.ptr(),
        cap,
        n_dirty,
        k1, k2, base, season,
        n_tasks,
    };
    WorkerThreadPool *wtp = WorkerThreadPool::get_singleton();
    if (wtp == nullptr) {
        for (int t = 0; t < n_tasks; ++t) {
            pass_a_indexed_worker(&task, static_cast<uint32_t>(t));
        }
        return;
    }
    int64_t group_id = wtp->add_native_group_task(
        &pass_a_indexed_worker, &task, n_tasks, -1, true, String("pk_pass_a_idx"));
    wtp->wait_for_group_task_completion(group_id);
}

// ─── Class binding ─────────────────────────────────────────────────────────

namespace {

inline void pk_csv_append_int(std::string &out, int64_t v) {
    char buf[32];
    auto res = std::to_chars(buf, buf + sizeof(buf), v);
    if (res.ec == std::errc()) {
        out.append(buf, res.ptr);
    }
}

inline void pk_csv_append_float(std::string &out, float v) {
    if (!std::isfinite(v)) {
        return;
    }
    char buf[64];
    const int n = std::snprintf(buf, sizeof(buf), "%.6f", double(v));
    if (n <= 0) {
        return;
    }
    int end = n;
    while (end > 0 && buf[end - 1] == '0') {
        --end;
    }
    if (end > 0 && buf[end - 1] == '.') {
        --end;
    }
    if (end <= 0 || (end == 1 && buf[0] == '-')) {
        out.push_back('0');
        return;
    }
    out.append(buf, buf + end);
}

struct TileCsvFieldRef {
    enum Kind : int {
        F32 = 0,
        I32 = 1,
        U8 = 2,
    };

    Kind kind = F32;
    PackedFloat32Array f32;
    PackedInt32Array i32;
    PackedByteArray u8;
    const float *f32_ptr = nullptr;
    const int32_t *i32_ptr = nullptr;
    const uint8_t *u8_ptr = nullptr;
};

} // anonymous namespace

godot::PackedByteArray DCWorldExt::encode_tile_csv_rows(godot::Dictionary knobs) {
    using godot::Array;
    using godot::CharString;
    using godot::PackedByteArray;
    using godot::PackedFloat32Array;
    using godot::PackedInt32Array;
    using godot::String;
    using godot::Variant;

    auto fail = []() -> PackedByteArray {
        return PackedByteArray();
    };

    if (!knobs.has("row_start") || !knobs.has("fixed_suffix") ||
        !knobs.has("cell_count") || !knobs.has("q_arr") ||
        !knobs.has("r_arr") || !knobs.has("s_arr") || !knobs.has("arrays")) {
        return fail();
    }

    const int row_start = int(knobs["row_start"]);
    const int cell_start = std::max(0, int(knobs.get("cell_start", 0)));
    const int cell_count = int(knobs["cell_count"]);
    const int cell_stride = std::max(1, int(knobs.get("cell_stride", 1)));
    if (row_start < 0 || cell_count <= 0 || cell_start >= cell_count) {
        return fail();
    }

    const String fixed_suffix = knobs.get("fixed_suffix", String());
    const CharString fixed_utf8 = fixed_suffix.utf8();
    const char *fixed_data = fixed_utf8.get_data();
    const int fixed_len = fixed_utf8.length();

    PackedInt32Array q_arr = knobs["q_arr"];
    PackedInt32Array r_arr = knobs["r_arr"];
    PackedInt32Array s_arr = knobs["s_arr"];
    if (q_arr.size() < cell_count || r_arr.size() < cell_count || s_arr.size() < cell_count) {
        return fail();
    }
    const int32_t * const q_ptr = q_arr.ptr();
    const int32_t * const r_ptr = r_arr.ptr();
    const int32_t * const s_ptr = s_arr.ptr();

    Array arrays = knobs["arrays"];
    std::vector<TileCsvFieldRef> fields;
    fields.reserve(size_t(arrays.size()));
    for (int i = 0; i < arrays.size(); ++i) {
        const Variant v = arrays[i];
        TileCsvFieldRef ref;
        switch (v.get_type()) {
            case Variant::PACKED_FLOAT32_ARRAY:
                ref.kind = TileCsvFieldRef::F32;
                ref.f32 = v;
                if (ref.f32.size() < cell_count) return fail();
                ref.f32_ptr = ref.f32.ptr();
                break;
            case Variant::PACKED_INT32_ARRAY:
                ref.kind = TileCsvFieldRef::I32;
                ref.i32 = v;
                if (ref.i32.size() < cell_count) return fail();
                ref.i32_ptr = ref.i32.ptr();
                break;
            case Variant::PACKED_BYTE_ARRAY:
                ref.kind = TileCsvFieldRef::U8;
                ref.u8 = v;
                if (ref.u8.size() < cell_count) return fail();
                ref.u8_ptr = ref.u8.ptr();
                break;
            default:
                return fail();
        }
        fields.push_back(ref);
    }

    const int rows = ((cell_count - cell_start - 1) / cell_stride) + 1;
    const size_t estimated = size_t(rows) *
        (size_t(std::max(0, fixed_len)) + 32u + size_t(fields.size()) * 12u);
    std::string text;
    text.reserve(estimated);

    int row_idx = row_start;
    for (int cell_idx = cell_start; cell_idx < cell_count; cell_idx += cell_stride, ++row_idx) {
        pk_csv_append_int(text, row_idx);
        if (fixed_len > 0) {
            text.append(fixed_data, fixed_data + fixed_len);
        }
        text.push_back(',');
        pk_csv_append_int(text, cell_idx);
        text.push_back(',');
        pk_csv_append_int(text, q_ptr[cell_idx]);
        text.push_back(',');
        pk_csv_append_int(text, r_ptr[cell_idx]);
        text.push_back(',');
        pk_csv_append_int(text, s_ptr[cell_idx]);
        for (const TileCsvFieldRef &field : fields) {
            text.push_back(',');
            switch (field.kind) {
                case TileCsvFieldRef::F32:
                    pk_csv_append_float(text, field.f32_ptr[cell_idx]);
                    break;
                case TileCsvFieldRef::I32:
                    pk_csv_append_int(text, field.i32_ptr[cell_idx]);
                    break;
                case TileCsvFieldRef::U8:
                    pk_csv_append_int(text, int(field.u8_ptr[cell_idx]));
                    break;
            }
        }
        text.push_back('\n');
    }

    if (text.empty()) {
        return fail();
    }

    PackedByteArray out;
    out.resize(int(text.size()));
    std::memcpy(out.ptrw(), text.data(), text.size());
    return out;
}

} // namespace pk
