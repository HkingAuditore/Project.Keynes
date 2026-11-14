#include "world_ext.h"

#include "component_bind_table.gen.h"  // A1 / dots-migration-roadmap §3 — autogen by tools/codegen/gen_cpp_bind_table.py
#include "system_schedule.h"           // Phase C.1 — 静态 DAG 调度图
#include "parallel_dispatcher.h"       // Phase C.3a — 并行分发 helper（统一 5 个手写 _thread）
#include "modifier_runtime.h"

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
// S3：Climate pass POD buffer + 9 个纯内核的共享定义。
#include "runtime_climate_passes.h"

namespace pk {

using namespace godot;
// ───────────────────────────────────────────────────────────────────────────
// EXPERIMENTAL: D-async — long-lived worker thread + double buffering
// ───────────────────────────────────────────────────────────────────────────
//
// IMPORTANT THREAD-SAFETY CONTRACT:
//   * Worker threads run in the anonymous namespace below and only touch
//     std::vector<float> / atomics / std::mutex / std::condition_variable.
//   * They MUST NOT call any Godot API. The kernel `_demo_complex_kernel_pure`
//     is a verbatim port of `run_demo_complex_pass` algorithm with all
//     PackedFloat32Array / push_warning / etc. replaced by std::vector and
//     silent clamps.
//   * Errors are reported via atomic int `error_code`; the main thread
//     translates them to push_warning inside async_climate_poll().

namespace {

// Error codes set by the worker (read by main thread in poll).
// 0 = ok. Values must be stable — main thread translates them by switch.
constexpr int PK_ASYNC_ERR_OK              = 0;
constexpr int PK_ASYNC_ERR_INVALID_GRID    = 1;
constexpr int PK_ASYNC_ERR_INPUT_SIZE      = 2;

struct AsyncTask {
    int task_id = 0;
    std::thread worker;

    // Inputs (main thread writes under mtx; worker copies to private buffers).
    std::vector<float> in_temp;
    std::vector<float> in_elev;

    // Worker-private buffers (only touched on the worker thread).
    std::vector<float> w_in_temp;
    std::vector<float> w_in_elev;
    std::vector<double> w_buf_a;
    std::vector<double> w_buf_b;
    std::vector<float>  w_out;

    // Result buffer that main thread will memcpy out of in poll().
    std::vector<float> result_buf;

    // Pending request parameters (main writes under mtx; worker reads under mtx).
    int   r_grid_w = 0, r_grid_h = 0;
    int   r_iterations = 16, r_kernel_radius = 2;
    float r_coriolis = 0.5f, r_drag = 0.6f, r_gain = 1.5f, r_k = 0.5f;

    std::mutex mtx;
    std::condition_variable cv;
    std::atomic<bool> request_pending{false};
    std::atomic<bool> result_ready{false};
    std::atomic<bool> should_exit{false};

    // Stats.
    std::atomic<int64_t> last_worker_compute_us{0};
    std::atomic<int64_t> last_worker_total_us{0};
    std::atomic<int64_t> total_ticks{0};
    std::atomic<int64_t> total_reused{0};
    std::atomic<int>     error_code{PK_ASYNC_ERR_OK};
};

struct AsyncState {
    std::unordered_map<int, std::unique_ptr<AsyncTask>> tasks;
    std::mutex tasks_mtx;
};

// ── Pure-C++ kernel — algorithm verbatim from run_demo_complex_pass ────────
// Inputs and outputs are std::vector<float>. Returns false on invalid inputs.
// Knob clamps mirror the synchronous path silently (no push_warning here —
// worker thread cannot call Godot API).
static bool _demo_complex_kernel_pure(int grid_w, int grid_h,
                                      int iterations, int kernel_radius,
                                      float coriolis_strength,
                                      float terrain_drag,
                                      float elevation_gain,
                                      float normalize_k,
                                      const std::vector<float> &T_in_v,
                                      const std::vector<float> &E_v,
                                      std::vector<double> &buf_a,
                                      std::vector<double> &buf_b,
                                      std::vector<float>  &out_v) {
    if (grid_w <= 0 || grid_h <= 0) return false;
    const int n = grid_w * grid_h;
    if ((int)T_in_v.size() != n || (int)E_v.size() != n) return false;

    if (iterations < 1) iterations = 1;
    if (iterations > 64) iterations = 64;
    if (kernel_radius < 1) kernel_radius = 1;
    if (kernel_radius > 5) kernel_radius = 5;
    if (coriolis_strength < -1.0f) coriolis_strength = -1.0f;
    if (coriolis_strength >  1.0f) coriolis_strength =  1.0f;
    if (terrain_drag < 0.0f) terrain_drag = 0.0f;
    if (terrain_drag > 1.0f) terrain_drag = 1.0f;

    if ((int)buf_a.size() != n) buf_a.assign(n, 0.0);
    if ((int)buf_b.size() != n) buf_b.assign(n, 0.0);
    if ((int)out_v.size() != n) out_v.assign(n, 0.0f);

    const float *__restrict T_in = T_in_v.data();
    const float *__restrict E    = E_v.data();

    const int kr   = kernel_radius;
    const int ksz  = 2 * kr + 1;
    double kernel[121];
    double kernel_sum = 0.0;
    for (int dy = -kr; dy <= kr; ++dy) {
        for (int dx = -kr; dx <= kr; ++dx) {
            const double w = std::exp(-(double)(dx*dx + dy*dy) * 0.5);
            kernel[(dy+kr)*ksz + (dx+kr)] = w;
            kernel_sum += w;
        }
    }
    const double kernel_inv_sum = (kernel_sum > 0.0) ? (1.0 / kernel_sum) : 0.0;

    for (int i = 0; i < n; ++i) buf_a[i] = (double)T_in[i];

    const double step_size = 0.05;
    const double cor  = (double)coriolis_strength;
    const double drag = (double)terrain_drag;

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

                const int xw = (x > 0)            ? (x - 1) : x;
                const int xe = (x < grid_w - 1)   ? (x + 1) : x;
                const int yn = (y > 0)            ? (y - 1) : y;
                const int ys = (y < grid_h - 1)   ? (y + 1) : y;
                const int row_n = yn * grid_w;
                const int row_c = y  * grid_w;
                const int row_s = ys * grid_w;
                const double gx = (S[row_n + xe] + 2.0*S[row_c + xe] + S[row_s + xe]
                                  - S[row_n + xw] - 2.0*S[row_c + xw] - S[row_s + xw]) * 0.125;
                const double gy = (S[row_s + xw] + 2.0*S[row_s + x ] + S[row_s + xe]
                                  - S[row_n + xw] - 2.0*S[row_n + x ] - S[row_n + xe]) * 0.125;

                const double cs = std::cos(rot_rad);
                const double sn = std::sin(rot_rad);
                const double gx_p = gx * cs - gy * sn;
                const double gy_p = gx * sn + gy * cs;

                const double damp = 1.0 - drag * (double)E[i];
                const double flux = gx_p + gy_p;
                D[i] = smooth + flux * damp * step_size;
            }
        }
    }

    const std::vector<double> &last = (iterations & 1) ? buf_b : buf_a;

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

    const double gain = (double)elevation_gain;
    const double k    = (double)normalize_k;
    for (int i = 0; i < n; ++i) {
        const double norm = (last[i] - out_min) * inv_denom;
        const double amp  = 1.0 + gain * (double)E[i];
        double v = norm * amp * k;
        if (v < 0.0) v = 0.0;
        else if (v > 1.0) v = 1.0;
        out_v[i] = (float)v;
    }
    return true;
}

// ── Worker thread main loop ────────────────────────────────────────────────
static void _async_worker_main(AsyncTask *t) {
    using clock = std::chrono::steady_clock;

    while (true) {
        // Snapshot params under the lock, then release it during compute.
        int   grid_w, grid_h, iters, kr;
        float coriolis, drag, gain, k;
        {
            std::unique_lock<std::mutex> lk(t->mtx);
            t->cv.wait(lk, [t]{
                return t->request_pending.load(std::memory_order_acquire)
                    || t->should_exit.load(std::memory_order_acquire);
            });
            if (t->should_exit.load(std::memory_order_acquire)) return;

            // Copy inputs into worker-private buffers (cheap; ~9.6 KB at 60×40).
            t->w_in_temp = t->in_temp;
            t->w_in_elev = t->in_elev;
            grid_w = t->r_grid_w;
            grid_h = t->r_grid_h;
            iters  = t->r_iterations;
            kr     = t->r_kernel_radius;
            coriolis = t->r_coriolis;
            drag     = t->r_drag;
            gain     = t->r_gain;
            k        = t->r_k;
        }

        const auto t0 = clock::now();
        const auto t_compute_start = clock::now();

        const bool ok = _demo_complex_kernel_pure(
            grid_w, grid_h, iters, kr,
            coriolis, drag, gain, k,
            t->w_in_temp, t->w_in_elev,
            t->w_buf_a, t->w_buf_b, t->w_out);

        const auto t_compute_end = clock::now();

        if (!ok) {
            // Set error code; do not modify result_buf (keep last good result).
            t->error_code.store(PK_ASYNC_ERR_INPUT_SIZE,
                                std::memory_order_release);
        } else {
            // Publish: copy w_out → result_buf under lock (so main-thread poll
            // never sees a partially-written buffer).
            std::lock_guard<std::mutex> lk(t->mtx);
            t->result_buf.resize(t->w_out.size());
            std::memcpy(t->result_buf.data(), t->w_out.data(),
                        t->w_out.size() * sizeof(float));
            t->error_code.store(PK_ASYNC_ERR_OK, std::memory_order_release);
        }

        const auto t1 = clock::now();
        t->last_worker_compute_us.store(
            (int64_t)std::chrono::duration_cast<std::chrono::microseconds>(
                t_compute_end - t_compute_start).count(),
            std::memory_order_relaxed);
        t->last_worker_total_us.store(
            (int64_t)std::chrono::duration_cast<std::chrono::microseconds>(
                t1 - t0).count(),
            std::memory_order_relaxed);
        t->total_ticks.fetch_add(1, std::memory_order_relaxed);

        t->request_pending.store(false, std::memory_order_release);
        t->result_ready.store(true, std::memory_order_release);
    }
}

inline AsyncState *_get_or_create_async_state(void *&slot) {
    if (!slot) slot = new AsyncState();
    return reinterpret_cast<AsyncState*>(slot);
}

inline AsyncState *_get_async_state(void *slot) {
    return reinterpret_cast<AsyncState*>(slot);
}

} // namespace (anonymous)

// ── Public API ────────────────────────────────────────────────────────────

void DCWorldExt::async_climate_register_task(int task_id, int n_workers) {
    (void)n_workers; // currently always 1 — multi-worker per task left for future
    AsyncState *st = _get_or_create_async_state(_async_state);
    std::lock_guard<std::mutex> g(st->tasks_mtx);
    auto it = st->tasks.find(task_id);
    if (it != st->tasks.end()) {
        UtilityFunctions::push_warning(
            "[DCWorldExt][async] task ", task_id,
            " already registered; ignoring duplicate register");
        return;
    }
    auto t = std::make_unique<AsyncTask>();
    t->task_id = task_id;
    AsyncTask *raw = t.get();
    st->tasks.emplace(task_id, std::move(t));
    raw->worker = std::thread(&_async_worker_main, raw);
}

void DCWorldExt::async_climate_set_inputs(int task_id,
                                          const PackedFloat32Array &temp,
                                          const PackedFloat32Array &elev) {
    AsyncState *st = _get_async_state(_async_state);
    if (!st) {
        UtilityFunctions::push_warning("[DCWorldExt][async] set_inputs: no async state");
        return;
    }
    AsyncTask *t = nullptr;
    {
        std::lock_guard<std::mutex> g(st->tasks_mtx);
        auto it = st->tasks.find(task_id);
        if (it == st->tasks.end()) {
            UtilityFunctions::push_warning(
                "[DCWorldExt][async] set_inputs: task ", task_id, " not registered");
            return;
        }
        t = it->second.get();
    }
    const int n_t = temp.size();
    const int n_e = elev.size();
    std::lock_guard<std::mutex> lk(t->mtx);
    t->in_temp.resize(n_t);
    if (n_t > 0) std::memcpy(t->in_temp.data(), temp.ptr(), n_t * sizeof(float));
    t->in_elev.resize(n_e);
    if (n_e > 0) std::memcpy(t->in_elev.data(), elev.ptr(), n_e * sizeof(float));
}

void DCWorldExt::async_climate_request(int task_id,
                                       int grid_w, int grid_h,
                                       int iterations, int kernel_radius,
                                       float coriolis_strength,
                                       float terrain_drag,
                                       float elevation_gain,
                                       float normalize_k) {
    AsyncState *st = _get_async_state(_async_state);
    if (!st) {
        UtilityFunctions::push_warning("[DCWorldExt][async] request: no async state");
        return;
    }
    AsyncTask *t = nullptr;
    {
        std::lock_guard<std::mutex> g(st->tasks_mtx);
        auto it = st->tasks.find(task_id);
        if (it == st->tasks.end()) {
            UtilityFunctions::push_warning(
                "[DCWorldExt][async] request: task ", task_id, " not registered");
            return;
        }
        t = it->second.get();
    }
    {
        std::lock_guard<std::mutex> lk(t->mtx);
        // If a previous request is still in flight or unread, count this main
        // thread tick as a "reuse" frame (worker not keeping up). The main
        // thread will keep using the last-published result until poll picks it.
        if (t->request_pending.load(std::memory_order_acquire)) {
            t->total_reused.fetch_add(1, std::memory_order_relaxed);
            return;
        }
        t->r_grid_w = grid_w;
        t->r_grid_h = grid_h;
        t->r_iterations = iterations;
        t->r_kernel_radius = kernel_radius;
        t->r_coriolis = coriolis_strength;
        t->r_drag = terrain_drag;
        t->r_gain = elevation_gain;
        t->r_k    = normalize_k;
        t->request_pending.store(true, std::memory_order_release);
    }
    t->cv.notify_one();
}

bool DCWorldExt::async_climate_poll(int task_id) {
    AsyncState *st = _get_async_state(_async_state);
    if (!st) return false;
    AsyncTask *t = nullptr;
    {
        std::lock_guard<std::mutex> g(st->tasks_mtx);
        auto it = st->tasks.find(task_id);
        if (it == st->tasks.end()) return false;
        t = it->second.get();
    }
    if (!t->result_ready.load(std::memory_order_acquire)) return false;

    // Translate any pending error from the worker into a single push_warning
    // (called on the main thread → safe to call Godot API).
    const int ec = t->error_code.exchange(PK_ASYNC_ERR_OK, std::memory_order_acq_rel);
    if (ec != PK_ASYNC_ERR_OK) {
        UtilityFunctions::push_warning(
            "[DCWorldExt][async] worker error code=", ec, " (task ", task_id, ")");
        // Do NOT consume result_ready on error; main thread sees stale result.
        return false;
    }

    // Snapshot result_buf under lock; copy into _slots[CELL_DEMO_THERMAL_GRADIENT].
    std::vector<float> snapshot;
    {
        std::lock_guard<std::mutex> lk(t->mtx);
        snapshot = t->result_buf;
    }
    t->result_ready.store(false, std::memory_order_release);

    const int sid_out = component_id(StringName("cell_demo_thermal_gradient"));
    if (sid_out < 0) return true; // no output slot — client just got the timing info
    Slot &s_out = _slots.write[sid_out];
    if (s_out.dtype != SlotDType::F32) return true;
    const int n_slot = s_out.arr_f32.size();
    const int n_snap = (int)snapshot.size();
    if (n_slot != n_snap || n_slot <= 0) return true;
    float *p = s_out.arr_f32.ptrw();
    std::memcpy(p, snapshot.data(), n_slot * sizeof(float));
    return true;
}

Dictionary DCWorldExt::async_climate_stats(int task_id) {
    Dictionary d;
    AsyncState *st = _get_async_state(_async_state);
    if (!st) {
        d["registered"] = false;
        return d;
    }
    AsyncTask *t = nullptr;
    {
        std::lock_guard<std::mutex> g(st->tasks_mtx);
        auto it = st->tasks.find(task_id);
        if (it == st->tasks.end()) {
            d["registered"] = false;
            return d;
        }
        t = it->second.get();
    }
    d["registered"] = true;
    d["worker_compute_us"] = (int64_t)t->last_worker_compute_us.load(std::memory_order_relaxed);
    d["worker_total_us"]   = (int64_t)t->last_worker_total_us.load(std::memory_order_relaxed);
    d["total_ticks"]       = (int64_t)t->total_ticks.load(std::memory_order_relaxed);
    d["total_reused"]      = (int64_t)t->total_reused.load(std::memory_order_relaxed);
    d["request_pending"]   = t->request_pending.load(std::memory_order_acquire);
    d["result_ready"]      = t->result_ready.load(std::memory_order_acquire);
    return d;
}

void DCWorldExt::async_climate_shutdown_task(int task_id) {
    AsyncState *st = _get_async_state(_async_state);
    if (!st) return;
    std::unique_ptr<AsyncTask> owned;
    {
        std::lock_guard<std::mutex> g(st->tasks_mtx);
        auto it = st->tasks.find(task_id);
        if (it == st->tasks.end()) return;
        owned = std::move(it->second);
        st->tasks.erase(it);
    }
    // Signal the worker to exit then join. cv.notify_one BEFORE join.
    owned->should_exit.store(true, std::memory_order_release);
    owned->cv.notify_all();
    if (owned->worker.joinable()) owned->worker.join();
}

void DCWorldExt::async_climate_shutdown_all() {
    AsyncState *st = _get_async_state(_async_state);
    if (!st) return;
    // Move out all tasks under lock so the destructors run unlocked.
    std::vector<std::unique_ptr<AsyncTask>> dead;
    {
        std::lock_guard<std::mutex> g(st->tasks_mtx);
        dead.reserve(st->tasks.size());
        for (auto &kv : st->tasks) dead.push_back(std::move(kv.second));
        st->tasks.clear();
    }
    for (auto &t : dead) {
        t->should_exit.store(true, std::memory_order_release);
        t->cv.notify_all();
    }
    for (auto &t : dead) {
        if (t->worker.joinable()) t->worker.join();
    }
    delete st;
    _async_state = nullptr;
}

// ───────────────────────────────────────────────────────────────────────────
// Async Climate Round（plan §async-stage-1，2026-06-14）
// ───────────────────────────────────────────────────────────────────────────
//
// 整 round 异步：worker thread 跑完整 8 pass round，主线程 kick + poll。
// 设计要点见 world_ext.h 中 async_climate_round_register 上方的契约说明。
//
// Stage 1 范围：
//   - 框架完整：input/output/work buf + worker thread + cv 唤醒 + 序列化
//   - transp 实现 pure std::vector kernel（移植自 run_transpiration_pass，
//     算法逐行 1:1，但不调任何 Godot API，不写 _slots，只读写 std::vector）
//   - 7 个其它 pass 留 stub（input → output 直传，不修改）。后续 Stage 2
//     逐个移植到 pure kernel
//   - 主线程 poll 时把 output 写回 _slots，调 _flush_slot_to_map 推到
//     MapData，复用现有 dirty_world.mark_dirty_all() 信号
//
// 单元测试 / A-B 验证策略：见 docs/architecture/current-state.md
// 中 transpiration 段落新增的 "async parity" 描述（Stage 1 写文档时补）。

namespace pk_async_climate {
// ClimateRoundScalars / ClimateInputBuf / ClimateOutputBuf / ClimateWorkBuf /
// ClimateRoundStaticKnobs 与 9 个 _async_*_kernel_pure 已在 S3 搬到
// runtime_climate_passes.h/.cpp（Godot 无依赖，生产与 SHADOW worker 共用）。
// 本文件保留 AsyncClimateRoundTask / AsyncClimateRoundState 与 worker 线程驱动，
// 它们属于主线程侧的 async round 生命周期，不属于共享算法层。

// Round async task。本设计只支持单 round 任务（不需要 task_id 多路），
// 全局只有一个实例，由 _async_climate_round_state 持有。
struct AsyncClimateRoundTask {
    std::thread worker;
    std::mutex  mtx;
    std::condition_variable cv;
    std::atomic<bool> request_pending{false};
    std::atomic<bool> result_ready{false};
    std::atomic<bool> should_exit{false};

    // 主线程写 in_buf，worker copy 到 w_in_buf。kick 时整体 vector assignment
    // 拷贝，约 220 KB（Stage 1 只用了 transp 三个 field 共 ~12 KB）。
    ClimateInputBuf in_buf;
    ClimateInputBuf w_in_buf;
    ClimateWorkBuf  w_work_buf;
    ClimateOutputBuf w_out_buf;
    ClimateOutputBuf result_buf;

    // round-invariant：bind 后填一次，所有 round 共享。worker 直接 read-only
    // 引用，不需要拷贝（worker 跑期间主线程不会改它）。
    ClimateRoundStaticKnobs static_knobs;

    // Stats
    std::atomic<int64_t> last_worker_total_us{0};
    std::atomic<int64_t> last_worker_compute_us{0};
    std::atomic<int64_t> total_rounds{0};
    std::atomic<int64_t> total_reused{0};      // request 被 pending block 的次数
    std::atomic<int>     error_code{PK_ASYNC_ROUND_ERR_OK};

    // 上次 round 的 per-pass 耗时（worker 写，主线程在 stats 里读）。
    // Stage 1 只填 transp_us，其它留 0。
    std::atomic<int64_t> last_pass_a_us{0};
    std::atomic<int64_t> last_pass_b_us{0};
    std::atomic<int64_t> last_ocean_water_us{0};
    std::atomic<int64_t> last_ocean_land_us{0};
    std::atomic<int64_t> last_wind_air_us{0};
    std::atomic<int64_t> last_wind_surface_us{0};
    std::atomic<int64_t> last_sea_ice_us{0};
    std::atomic<int64_t> last_transp_us{0};
    // Stage 9（2026-06-16）finalizer pass timing
    std::atomic<int64_t> last_finalizer_us{0};
};

struct AsyncClimateRoundState {
    std::unique_ptr<AsyncClimateRoundTask> task;
    std::mutex state_mtx;  // 保护 task 创建/销毁
    bool lifecycle_round_active = false;
    bool lifecycle_async_kicked = false;
    int lifecycle_pass_cursor = 0;
    int64_t lifecycle_round_id = 0;
    int64_t lifecycle_tick_index = -1;
    int64_t lifecycle_poll_attempts = 0;
    double lifecycle_phase_locked = 0.0;
    std::string lifecycle_stage = "idle";
    std::string lifecycle_owner = "native_probe_lifecycle";
    std::vector<std::string> lifecycle_start_state_intents;
    std::vector<std::string> lifecycle_boundary_intents;
    std::vector<std::string> lifecycle_finish_boundary_intents;
    std::vector<std::string> lifecycle_finalize_tail_boundary_intents;
};

// ─── 7 个 stub kernel（Stage 2 替换为 pure kernel） ─────────────────────────
// 当前行为：直接把 input 拷贝到 output（如果 output 字段存在），不修改 climate
// 状态。GDScript 端在 cp.use_climate_round_async=true 时，仍然走原 sync sub-pass
// 路径跑这 7 个 pass，async 路径只接管 transpiration（验证框架可行性）。

// 未来 Stage 2 各 pass 移植成 pure kernel 时，把对应 stub 替换即可。每个 pass
// 应接受 (in, knobs, work, out) 参数，返回 bool。

// ─── Worker thread main loop ─────────────────────────────────────────────
//
// 与 demo async 模式严格对齐：cv.wait → snapshot inputs under lock → 释放锁
// 跑算法 → 锁住 publish → mark result_ready。should_exit 时直接 return。

static void _async_climate_round_worker_main(AsyncClimateRoundTask *t) {
    using clock = std::chrono::steady_clock;
    while (true) {
        // Snapshot inputs under lock, then release for compute.
        {
            std::unique_lock<std::mutex> lk(t->mtx);
            t->cv.wait(lk, [t]{
                return t->request_pending.load(std::memory_order_acquire)
                    || t->should_exit.load(std::memory_order_acquire);
            });
            if (t->should_exit.load(std::memory_order_acquire)) return;
            // Vector assignment（~12 KB Stage 1，~220 KB Stage 2）
            t->w_in_buf = t->in_buf;
        }

        const auto t0 = clock::now();
        const auto compute_t0 = clock::now();

        // Stage 2：根据 passes_mask 选择性跑 pass_a + transp pure kernel。
        // 其它 6 pass 仍是 stub（即使 mask 启用也不修改 output）。
        // 主线程 poll 时把 output 字段写回 _slots + flush 到 MapData。
        // Stage 3 stub 全部实装后，passes_mask 默认 0xFF 即整 round async。
        // S3：9-pass 编排已搬到共享 TU（runtime_climate_passes.cpp），runtime
        // worker 调的是同一份。这里只负责把逐 pass 耗时搬回 atomic 供 poll 读。
        pk_async_climate::ClimateRoundPassTiming timing;
        const bool ok = pk_async_climate::run_climate_round_passes(
            t->w_in_buf, t->static_knobs, t->w_work_buf, t->w_out_buf, &timing);
        t->last_pass_a_us.store(timing.pass_us[0], std::memory_order_relaxed);
        t->last_pass_b_us.store(timing.pass_us[1], std::memory_order_relaxed);
        t->last_ocean_water_us.store(timing.pass_us[2], std::memory_order_relaxed);
        t->last_ocean_land_us.store(timing.pass_us[3], std::memory_order_relaxed);
        t->last_wind_air_us.store(timing.pass_us[4], std::memory_order_relaxed);
        t->last_wind_surface_us.store(timing.pass_us[5], std::memory_order_relaxed);
        t->last_sea_ice_us.store(timing.pass_us[6], std::memory_order_relaxed);
        t->last_transp_us.store(timing.pass_us[7], std::memory_order_relaxed);
        t->last_finalizer_us.store(timing.pass_us[8], std::memory_order_relaxed);

        const auto compute_t1 = clock::now();
        t->w_out_buf.n_cells = t->w_in_buf.n_cells;

        if (!ok) {
            // 不 publish output，保留上一次结果
            t->error_code.store(PK_ASYNC_ROUND_ERR_KERNEL_FAILED,
                                std::memory_order_release);
        } else {
            // Publish: vector assignment 把 w_out_buf 拷到 result_buf 让主线程读。
            std::lock_guard<std::mutex> lk(t->mtx);
            t->result_buf = t->w_out_buf;
            t->error_code.store(PK_ASYNC_ROUND_ERR_OK, std::memory_order_release);
        }

        const auto t1 = clock::now();
        t->last_worker_compute_us.store(
            (int64_t)std::chrono::duration_cast<std::chrono::microseconds>(
                compute_t1 - compute_t0).count(),
            std::memory_order_relaxed);
        t->last_worker_total_us.store(
            (int64_t)std::chrono::duration_cast<std::chrono::microseconds>(
                t1 - t0).count(),
            std::memory_order_relaxed);
        t->total_rounds.fetch_add(1, std::memory_order_relaxed);

        t->request_pending.store(false, std::memory_order_release);
        t->result_ready.store(true, std::memory_order_release);
    }
}

// 帮助函数：从 Godot Dictionary 提取 PackedFloat32Array → std::vector<float>。
// 不存在时填默认值 default_v 长度为 expect_n 的 zero vector。
inline void _read_pf32_to_vec(const godot::Dictionary &dict, const char *key,
                              std::vector<float> &out, int expect_n) {
    using godot::PackedFloat32Array;
    using godot::Variant;
    if (!dict.has(key)) {
        out.assign(expect_n, 0.0f);
        return;
    }
    Variant v = dict[key];
    if (v.get_type() != Variant::PACKED_FLOAT32_ARRAY) {
        out.assign(expect_n, 0.0f);
        return;
    }
    PackedFloat32Array p = v;
    const int n = p.size();
    out.resize(n);
    if (n > 0) std::memcpy(out.data(), p.ptr(), n * sizeof(float));
}

inline void _read_pu8_to_vec(const godot::Dictionary &dict, const char *key,
                             std::vector<uint8_t> &out, int expect_n) {
    using godot::PackedByteArray;
    using godot::Variant;
    if (!dict.has(key)) {
        out.assign(expect_n, 0);
        return;
    }
    Variant v = dict[key];
    if (v.get_type() != Variant::PACKED_BYTE_ARRAY) {
        out.assign(expect_n, 0);
        return;
    }
    PackedByteArray p = v;
    const int n = p.size();
    out.resize(n);
    if (n > 0) std::memcpy(out.data(), p.ptr(), n);
}

inline void _read_pi32_to_vec(const godot::Dictionary &dict, const char *key,
                              std::vector<int32_t> &out) {
    using godot::PackedInt32Array;
    using godot::Variant;
    if (!dict.has(key)) {
        out.clear();
        return;
    }
    Variant v = dict[key];
    if (v.get_type() != Variant::PACKED_INT32_ARRAY) {
        out.clear();
        return;
    }
    PackedInt32Array p = v;
    const int n = p.size();
    out.resize(n);
    if (n > 0) std::memcpy(out.data(), p.ptr(), n * sizeof(int32_t));
}

inline AsyncClimateRoundState *_get_or_create_round_state(void *&slot) {
    if (!slot) slot = new AsyncClimateRoundState();
    return reinterpret_cast<AsyncClimateRoundState*>(slot);
}

inline AsyncClimateRoundState *_get_round_state(void *slot) {
    return reinterpret_cast<AsyncClimateRoundState*>(slot);
}

}  // namespace pk_async_climate

// ─── Public API: async climate round ─────────────────────────────────────

void DCWorldExt::async_climate_round_register() {
    using namespace pk_async_climate;
    AsyncClimateRoundState *st = _get_or_create_round_state(_async_climate_round_state);
    std::lock_guard<std::mutex> g(st->state_mtx);
    if (st->task != nullptr) {
        // 幂等：已注册过直接返回，不打 warning（GDScript 可能多次重 bind 调本函数）。
        return;
    }
    st->task = std::make_unique<AsyncClimateRoundTask>();
    AsyncClimateRoundTask *raw = st->task.get();
    raw->worker = std::thread(&_async_climate_round_worker_main, raw);
    UtilityFunctions::print(String("[async_climate_round] worker thread started"));
}

void DCWorldExt::async_climate_round_set_static_knobs(const Dictionary &knobs) {
    using namespace pk_async_climate;
    AsyncClimateRoundState *st = _get_round_state(_async_climate_round_state);
    if (!st || st->task == nullptr) {
        UtilityFunctions::push_warning(
            "[async_climate_round] set_static_knobs called before register; ignoring");
        return;
    }
    AsyncClimateRoundTask *t = st->task.get();
    // worker 跑 round 时不会读 static_knobs（worker 只在 cv.wait 唤醒后跑算法），
    // 但写 static_knobs 应在 worker idle 时（kick 之间）。保守：抓 mtx 防御。
    std::lock_guard<std::mutex> lk(t->mtx);
    t->static_knobs.n_cells = int(knobs.get("n_cells", 0));
    _read_pi32_to_vec(knobs, "neighbor_indices", t->static_knobs.neighbor_indices);
    _read_pf32_to_vec(knobs, "donor_table",    t->static_knobs.donor_table, 0);
    _read_pf32_to_vec(knobs, "foliage_table",  t->static_knobs.foliage_table, 0);
    _read_pf32_to_vec(knobs, "albedo_table",   t->static_knobs.albedo_table, 0);
}

// ─── Dictionary → ClimateInputBuf 提取（生产 kick 与 SHADOW capture 共用）────
//
// S3：原来这段只存在于 async_climate_round_kick 的锁内。SHADOW worker 需要拿到
// **与生产 round 完全相同的输入缓冲**才谈得上对拍——如果 worker 自己另写一套
// snapshot→buf 映射，就等于把断点 1 的"两套实现比结果"从算法层挪到了输入层。
// 所以把提取逻辑收成一个方法：生产 kick 与 capture_runtime_inputs 都调它，
// 输入侧差异被消除，剩下的分叉只可能来自执行顺序与状态所有权。
//
// 调用方负责持锁（kick 在 task mtx 内调用）。radiative modifier 与 insol 年均
// LUT 都在这里就地烘焙，因为它们必须由主线程算（worker 不能触 member 缓存）。
bool DCWorldExt::override_climate_round_input_from_slots(int n_cells,
        pk_async_climate::ClimateInputBuf &buf) {
    if (!_bound || n_cells <= 0) return false;

    // 只覆盖 pass_a 真正读的 slot-backed lane。maritime_factor 不是 slot（由
    // cp_struct 侧携带），radiative modifier 与 insol LUT 由调用方烘焙。
    struct F32Lane { const char *component; std::vector<float> *dst; bool required; };
    struct U8Lane  { const char *component; std::vector<uint8_t> *dst; bool required; };
    const F32Lane f32_lanes[] = {
        {"cell_elevation",          &buf.elevation,         true},
        {"cell_base_moisture",      &buf.base_moisture,     true},
        {"cell_lat_norm",           &buf.lat_norm,          true},
        {"cell_temp_baseline_year", &buf.temp_baseline_year, true},
        {"cell_temp",               &buf.temp,              true},
        {"cell_temp_30d",           &buf.temp_30d,          true},
        {"cell_temp_365d",          &buf.temp_365d,         true},
        {"cell_thermal_energy",     &buf.thermal_energy,    true},
        {"cell_snowpack",           &buf.snowpack,          true},
        {"cell_moisture",           &buf.moisture,          true},
        // 可选水文列：slot 缺失时清空，让内核走"这条 lane 不参与"的分支——与
        // run_climate_pass_a 里 nullptr 指针的语义一致。
        {"cell_weather_vapor",      &buf.weather_vapor,     false},
        {"cell_weather_precip",     &buf.weather_precip,    false},
        {"cell_soil_moisture",      &buf.soil_moisture,     false},
        {"cell_water_balance_30d",  &buf.water_balance_30d, false},
    };
    const U8Lane u8_lanes[] = {
        {"cell_is_water",        &buf.is_water,        true},
        {"cell_terrain",         &buf.terrain,         true},
        {"cell_cover",           &buf.cover,           true},
        {"cell_ema_initialized", &buf.ema_initialized, true},
    };

    // 先整体校验，避免只覆盖一半 lane 留下混合来源的 buffer。
    for (const F32Lane &lane : f32_lanes) {
        const int sid = component_id(StringName(lane.component));
        const bool ok = sid >= 0 && _slots.write[sid].arr_f32.size() == n_cells;
        if (!ok && lane.required) return false;
    }
    for (const U8Lane &lane : u8_lanes) {
        const int sid = component_id(StringName(lane.component));
        const bool ok = sid >= 0 && _slots.write[sid].arr_u8.size() == n_cells;
        if (!ok && lane.required) return false;
    }

    for (const F32Lane &lane : f32_lanes) {
        const int sid = component_id(StringName(lane.component));
        if (sid < 0 || _slots.write[sid].arr_f32.size() != n_cells) {
            lane.dst->clear();
            continue;
        }
        lane.dst->resize(size_t(n_cells));
        std::memcpy(lane.dst->data(), _slots.write[sid].arr_f32.ptr(),
                    size_t(n_cells) * sizeof(float));
    }
    for (const U8Lane &lane : u8_lanes) {
        const int sid = component_id(StringName(lane.component));
        if (sid < 0 || _slots.write[sid].arr_u8.size() != n_cells) {
            lane.dst->clear();
            continue;
        }
        lane.dst->resize(size_t(n_cells));
        std::memcpy(lane.dst->data(), _slots.write[sid].arr_u8.ptr(), size_t(n_cells));
    }

    // ─── pass_b..sea_ice 读的 slot-backed lane ────────────────────────────
    //
    // 这些 lane 此前只从 GDScript 的 round-input Dictionary 取，而那份 Dictionary
    // 走的是 MapData 镜像。风场是纯 slot 产物（physics 只写 DCWorldExt slot，从不
    // 回灌 MapData），于是 worker 拿到的 wind_x/wind_y/wind_speed 是长度对、内容
    // 全零的数组 —— 长度对所以 pass 守卫全过、不报 starve，但 wind_air 每个 cell
    // 都在 wind_len2 < 1e-6 处 continue，wind_surface 的平流权重全被跳过，weather
    // solve 也拿不到风。分叉矩阵里 temperature 的 2266 格、vapor 的全图偏移、
    // precipitation 归零，都是这一条。
    //
    // 与上面两组的区别：slot 不可用时**保留** Dictionary 给的内容而不是清空。
    // 清空会把当前唯一的来源也一并抹掉，比拿到零值更糟。
    struct OverlayF32 { const char *component; std::vector<float> *dst; };
    struct OverlayU8  { const char *component; std::vector<uint8_t> *dst; };
    const OverlayF32 overlay_f32[] = {
        // wind_air / wind_surface / weather solve
        {"cell_wind_x",                        &buf.wind_x},
        {"cell_wind_y",                        &buf.wind_y},
        {"cell_wind_speed",                    &buf.wind_speed},
        // 邻居方向几何（pass_b / ocean_* / wind_* 都用）
        {"cell_pos_x",                         &buf.pos_x},
        {"cell_pos_y",                         &buf.pos_y},
        // pass_b
        {"cell_insolation_dev",                &buf.insolation_dev},
        {"cell_temperature_transport_anomaly", &buf.temp_transport_anomaly},
        // wind_surface 的合成 baseline 与 air anomaly 快照
        {"cell_temp_baseline",                 &buf.temp_baseline},
        {"cell_air_mass_temp_anomaly",         &buf.air_mass_temp_anomaly},
        // ocean_water / ocean_land
        {"cell_ocean_current_x",               &buf.ocean_current_x},
        {"cell_ocean_current_y",               &buf.ocean_current_y},
        {"cell_ocean_thermal_anomaly",         &buf.ocean_thermal_anomaly},
        // sea_ice
        {"cell_upwelling_strength",            &buf.upwelling_strength},
        {"cell_insolation_now",                &buf.insolation_now},
        {"cell_sea_ice_frac",                  &buf.sea_ice_frac_inout},
    };
    const OverlayU8 overlay_u8[] = {
        {"cell_landform",     &buf.landform},
        {"cell_vegetation",   &buf.vegetation},
        {"cell_base_terrain", &buf.base_terrain},
    };
    for (const OverlayF32 &lane : overlay_f32) {
        const int sid = component_id(StringName(lane.component));
        if (sid < 0 || _slots.write[sid].arr_f32.size() != n_cells) continue;
        lane.dst->resize(size_t(n_cells));
        std::memcpy(lane.dst->data(), _slots.write[sid].arr_f32.ptr(),
                    size_t(n_cells) * sizeof(float));
    }
    for (const OverlayU8 &lane : overlay_u8) {
        const int sid = component_id(StringName(lane.component));
        if (sid < 0 || _slots.write[sid].arr_u8.size() != n_cells) continue;
        lane.dst->resize(size_t(n_cells));
        std::memcpy(lane.dst->data(), _slots.write[sid].arr_u8.ptr(), size_t(n_cells));
    }
    return true;
}


void DCWorldExt::fill_climate_round_input(const Dictionary &input, int n_cells,
                                          pk_async_climate::ClimateInputBuf &buf,
                                          bool prefer_slot_lanes) {
    using namespace pk_async_climate;
    if (n_cells <= 0) {
        buf = ClimateInputBuf{};
        return;
    }
    buf.n_cells = n_cells;

    // Stage 1 字段（transp 读）
    _read_pu8_to_vec(input,  "landform",   buf.landform,   n_cells);
    _read_pu8_to_vec(input,  "vegetation", buf.vegetation, n_cells);
    _read_pf32_to_vec(input, "moisture",   buf.moisture,   n_cells);

    // Stage 2 字段（pass_a 读）。如不提供则填空（0）；worker 内的 pass_a
    // 维度校验会拒绝跑（passes_mask & 0x01 但 is_water.size() != n_cells）。
    _read_pu8_to_vec(input,  "is_water",            buf.is_water,            n_cells);
    _read_pu8_to_vec(input,  "terrain",             buf.terrain,             n_cells);
    _read_pu8_to_vec(input,  "cover",               buf.cover,               n_cells);
    _read_pu8_to_vec(input,  "ema_initialized",     buf.ema_initialized,     n_cells);
    _read_pf32_to_vec(input, "elevation",           buf.elevation,           n_cells);
    _read_pf32_to_vec(input, "base_moisture",       buf.base_moisture,       n_cells);
    _read_pf32_to_vec(input, "weather_vapor",       buf.weather_vapor,       n_cells);
    _read_pf32_to_vec(input, "weather_precip",      buf.weather_precip,      n_cells);
    _read_pf32_to_vec(input, "soil_moisture",       buf.soil_moisture,       n_cells);
    _read_pf32_to_vec(input, "water_balance_30d",   buf.water_balance_30d,   n_cells);
    _read_pf32_to_vec(input, "lat_norm",            buf.lat_norm,            n_cells);
    // [climate-zone-fix P2] 海洋性调温因子（静态 per-cell；缺省空→不调温）
    _read_pf32_to_vec(input, "maritime_factor",     buf.maritime,            n_cells);
    _read_pf32_to_vec(input, "temp_baseline_year",  buf.temp_baseline_year,  n_cells);
    _read_pf32_to_vec(input, "temp",                buf.temp,                n_cells);
    _read_pf32_to_vec(input, "temp_30d",            buf.temp_30d,            n_cells);
    _read_pf32_to_vec(input, "temp_365d",           buf.temp_365d,           n_cells);
    _read_pf32_to_vec(input, "thermal_energy",      buf.thermal_energy,      n_cells);
    _read_pf32_to_vec(input, "snowpack",            buf.snowpack,            n_cells);
    buf.radiative_modifier_add.assign(
        static_cast<size_t>(n_cells), 0.0f);
    buf.radiative_modifier_factor.assign(
        static_cast<size_t>(n_cells), 1.0f);
    if (_modifier_runtime != nullptr) {
        const ModifierRuntime *modifier =
            static_cast<const ModifierRuntime *>(_modifier_runtime);
        for (int cell = 0; cell < n_cells; ++cell) {
            double add = 0.0;
            double factor = 1.0;
            modifier->climate_radiative_terms(cell, add, factor);
            buf.radiative_modifier_add[static_cast<size_t>(cell)] =
                static_cast<float>(add);
            buf.radiative_modifier_factor[static_cast<size_t>(cell)] =
                static_cast<float>(factor);
        }
    }

    // Stage 2 字段（pass_b 读）。snow_cover/moisture 与 pass_a 共享。
    _read_pf32_to_vec(input, "pos_x",                     buf.pos_x,                     n_cells);
    _read_pf32_to_vec(input, "pos_y",                     buf.pos_y,                     n_cells);
    _read_pf32_to_vec(input, "insolation_dev",            buf.insolation_dev,            n_cells);
    _read_pf32_to_vec(input, "temp_transport_anomaly",    buf.temp_transport_anomaly,    n_cells);
    _read_pf32_to_vec(input, "local_thermal_anomaly",     buf.local_thermal_anomaly,     n_cells);
    _read_pf32_to_vec(input, "sea_ice_frac",              buf.sea_ice_frac,              n_cells);

    // Stage 2 字段（ocean_water/ocean_land 读）
    _read_pf32_to_vec(input, "ocean_current_x",           buf.ocean_current_x,           n_cells);
    _read_pf32_to_vec(input, "ocean_current_y",           buf.ocean_current_y,           n_cells);
    _read_pf32_to_vec(input, "ocean_thermal_anomaly",     buf.ocean_thermal_anomaly,     n_cells);

    // Stage 2 字段（wind_air/wind_surface 读）
    _read_pf32_to_vec(input, "wind_x",                    buf.wind_x,                    n_cells);
    _read_pf32_to_vec(input, "wind_y",                    buf.wind_y,                    n_cells);
    _read_pf32_to_vec(input, "wind_speed",                buf.wind_speed,                n_cells);
    _read_pf32_to_vec(input, "temp_baseline",             buf.temp_baseline,             n_cells);
    _read_pf32_to_vec(input, "air_mass_temp_anomaly",     buf.air_mass_temp_anomaly,     n_cells);

    // Stage 2 字段（sea_ice 读）
    _read_pu8_to_vec(input,  "base_terrain",              buf.base_terrain,              n_cells);
    _read_pf32_to_vec(input, "upwelling_strength",        buf.upwelling_strength,        n_cells);
    _read_pf32_to_vec(input, "insolation_now",            buf.insolation_now,            n_cells);
    _read_pf32_to_vec(input, "cell_temperature_arr",      buf.cell_temperature_arr,      n_cells);
    _read_pf32_to_vec(input, "sea_ice_frac_inout",        buf.sea_ice_frac_inout,        n_cells);
    _read_pu8_to_vec(input,  "water_terrain_ids",         buf.water_terrain_ids,         0);

    // Round-level scalars
    buf.scalars.season_phase     = double(input.get("season_phase", 0.0));
    buf.scalars.axial_tilt_deg   = double(input.get("axial_tilt_deg", 23.5));
    buf.scalars.day_length_gain  = double(input.get("day_length_gain", 0.35));
    buf.scalars.solar_gain       = double(input.get("solar_gain", 1.0));
    buf.scalars.insol_amp        = double(input.get("insol_amp", 0.20));
    buf.scalars.insol_gain       = double(input.get("insol_gain", 1.0));
    buf.scalars.moist_scale_now  = double(input.get("moist_scale_now", 1.0));
    buf.scalars.runtime_moisture_base_relax_rate = float(input.get("runtime_moisture_base_relax_rate", 0.24));
    buf.scalars.runtime_moisture_weather_vapor_weight = float(input.get("runtime_moisture_weather_vapor_weight", 0.12));
    buf.scalars.runtime_moisture_precip_weight = float(input.get("runtime_moisture_precip_weight", 0.78));
    buf.scalars.runtime_moisture_soil_weight = float(input.get("runtime_moisture_soil_weight", 1.82));
    buf.scalars.runtime_moisture_soil_dry_weight = float(input.get("runtime_moisture_soil_dry_weight", 2.21));
    buf.scalars.runtime_moisture_water_balance_weight = float(input.get("runtime_moisture_water_balance_weight", 1.04));
    buf.scalars.runtime_moisture_water_balance_dry_weight = float(input.get("runtime_moisture_water_balance_dry_weight", 1.30));
    buf.scalars.days_per_year    = int(input.get("days_per_year", 365));
    buf.scalars.sea_level        = double(input.get("sea_level", 0.5));
    // pass_a 扩展 scalars
    buf.scalars.insol_dev_min               = double(input.get("insol_dev_min", -1.0));
    buf.scalars.insol_dev_max               = double(input.get("insol_dev_max", 1.0));
    buf.scalars.thermal_inertia_land        = double(input.get("thermal_inertia_land", 0.35));
    buf.scalars.thermal_inertia_water       = double(input.get("thermal_inertia_water", 0.045));
    buf.scalars.thermal_inertia_snow        = double(input.get("thermal_inertia_snow", 0.09));
    buf.scalars.thermal_inertia_high_mountain = double(input.get("thermal_inertia_high_mountain", 0.16));
    buf.scalars.thermal_daily_delta_cap     = double(input.get("thermal_daily_delta_cap", 0.15));
    buf.scalars.thermal_dt_days             = double(input.get("thermal_dt_days", 1.0));
    buf.scalars.snowpack_cover_low          = double(input.get("snowpack_cover_low", 0.05));
    buf.scalars.snowpack_cover_full         = double(input.get("snowpack_cover_full", 0.32));
    buf.scalars.maritime_season_damp        = double(input.get("maritime_season_damp", 0.0));
    // transp scalars
    buf.scalars.transp_outflow_rate = float(input.get("transp_outflow_rate", 0.025));
    buf.scalars.transp_self_rate    = float(input.get("transp_self_rate", 0.015));

    // pass_b scalars（Stage 2）
    buf.scalars.pb_winter_boost  = float(input.get("pb_winter_boost", 1.0));
    buf.scalars.pb_snow_cool     = float(input.get("pb_snow_cool", 0.0));
    buf.scalars.pb_veg_cool      = float(input.get("pb_veg_cool", 0.0));
    buf.scalars.pb_diurnal_amp   = float(input.get("pb_diurnal_amp", 0.0));
    buf.scalars.pb_evap_gain     = float(input.get("pb_evap_gain", 0.0));
    buf.scalars.pb_rs_threshold  = float(input.get("pb_rs_threshold", 0.0));
    buf.scalars.pb_rs_factor     = float(input.get("pb_rs_factor", 1.0));
    buf.scalars.pb_rs_lookback   = int(input.get("pb_rs_lookback", 0));
    buf.scalars.pb_t_freeze      = float(input.get("pb_t_freeze", 0.0));
    buf.scalars.pb_coupling_gain = float(input.get("pb_coupling_gain", 0.0));
    buf.scalars.pb_coast_leak    = float(input.get("pb_coast_leak", 0.0));
    buf.scalars.pb_sea_ice_albedo_cooling = float(input.get("pb_sea_ice_albedo_cooling", 0.01));

    // seam-advection-fix：环绕周期。常驻值优先，input 显式给了才覆盖（单测用）。
    buf.scalars.wrap_period_x = float(input.get("wrap_period_x", _native_wrap_period_x));

    // ocean_water / ocean_land scalars（Stage 2）
    buf.scalars.ow_advect_steps  = int(input.get("ow_advect_steps", 3));
    buf.scalars.ow_heat_mix      = float(input.get("ow_heat_mix", 0.55));
    buf.scalars.ow_tta_source_cap = float(input.get("ow_tta_source_cap", 0.22));
    buf.scalars.ow_cold_transport_form =
        float(input.get("ow_cold_transport_form", 0.06));
    buf.scalars.ow_cold_transport_melt =
        float(input.get("ow_cold_transport_melt", 0.11));
    buf.scalars.ow_tta_blend_rate = float(input.get("ow_tta_blend_rate", 0.70));
    buf.scalars.ow_tta_zero_current_decay = float(input.get("ow_tta_zero_current_decay", 0.06));
    buf.scalars.ol_effective_leak = float(input.get("ol_effective_leak", 0.55));
    buf.scalars.ol_tta_source_cap = float(input.get("ol_tta_source_cap", 0.22));
    buf.scalars.ol_tta_blend_rate = float(input.get("ol_tta_blend_rate", 0.70));
    buf.scalars.ol_tta_decay_rate = float(input.get("ol_tta_decay_rate", 0.04));

    // wind_air / wind_surface scalars（Stage 2）
    buf.scalars.wa_advect_steps = int(input.get("wa_advect_steps", 3));
    buf.scalars.wa_heat_mix     = float(input.get("wa_heat_mix", 0.25));
    buf.scalars.ws_air_leak     = float(input.get("ws_air_leak", 0.35));
    buf.scalars.ws_cold_transport_form = float(input.get("ws_cold_transport_form", 0.06));
    buf.scalars.ws_cold_transport_melt = float(input.get("ws_cold_transport_melt", 0.11));

    // sea_ice scalars（Stage 2）
    buf.scalars.si_k_freeze     = float(input.get("si_k_freeze", 0.40));
    buf.scalars.si_k_melt       = float(input.get("si_k_melt", 1.45));
    buf.scalars.si_t_form       = float(input.get("si_t_form", 0.06));
    buf.scalars.si_t_melt       = float(input.get("si_t_melt", 0.11));
    buf.scalars.si_contagion    = float(input.get("si_contagion", 0.035));
    buf.scalars.si_threshold    = float(input.get("si_threshold", 0.68));
    buf.scalars.si_hysteresis   = float(input.get("si_hysteresis", 0.12));
    buf.scalars.si_ice_delay    = float(input.get("si_ice_delay", 1.0));
    buf.scalars.si_enable_oht   = bool(input.get("si_enable_oht", true));
    buf.scalars.si_apply_terrain_flips = bool(input.get("si_apply_terrain_flips", false));
    buf.scalars.si_solar_gate_enabled = bool(input.get("si_solar_gate_enabled", true));
    buf.scalars.si_freeze_insol_low  = float(input.get("si_freeze_insol_low", 0.22));
    buf.scalars.si_freeze_insol_high = float(input.get("si_freeze_insol_high", 0.45));
    buf.scalars.si_solar_melt_start  = float(input.get("si_solar_melt_start", 0.28));
    buf.scalars.si_solar_melt_gain   = float(input.get("si_solar_melt_gain", 1.35));
    buf.scalars.si_min_thick_ice_solar_exposure = float(input.get("si_min_thick_ice_solar_exposure", 0.32));
    buf.scalars.si_daily_delta_cap   = float(input.get("si_daily_delta_cap", 0.070));
    buf.scalars.si_edge_mix_rate     = float(input.get("si_edge_mix_rate", 0.035));
    buf.scalars.si_dt_days           = float(input.get("si_dt_days", 1.0));
    buf.scalars.si_terrain_lake_id    = int(input.get("si_terrain_lake_id", -1));
    buf.scalars.si_terrain_sea_ice_id = int(input.get("si_terrain_sea_ice_id", -1));
    buf.scalars.si_terrain_ocean_id   = int(input.get("si_terrain_ocean_id", -1));

    // ─── finalizer pass fields（Stage 9，2026-06-16） ─────────────────
    // _temp_start_of_day_arr / _tta_start_of_day_arr / sea_ice_frac_prev /
    // weather_precip 由 GDScript 主线程在 begin_round 时打快照传入。
    _read_pf32_to_vec(input, "fin_temp_start_of_day",   buf.temp_start_of_day,   n_cells);
    _read_pf32_to_vec(input, "fin_tta_start_of_day",    buf.tta_start_of_day,    n_cells);
    _read_pf32_to_vec(input, "fin_sea_ice_frac_prev",   buf.sea_ice_frac_prev,   n_cells);
    _read_pf32_to_vec(input, "fin_weather_precip",      buf.weather_precip,      n_cells);
    buf.scalars.fin_temp_cap_enabled = bool(input.get("fin_temp_cap_enabled", true));
    buf.scalars.fin_temp_cap         = float(input.get("fin_temp_cap", 0.15));
    buf.scalars.fin_tta_cap          = float(input.get("fin_tta_cap", 0.12));
    buf.scalars.fin_has_temp_start   = bool(input.get("fin_has_temp_start", false));
    buf.scalars.fin_has_tta_start    = bool(input.get("fin_has_tta_start", false));

    // passes_mask（默认 0x1FF 含 finalizer bit）
    buf.scalars.passes_mask = int(input.get("passes_mask", 0x1FF));

    // ─── S3：把 pass_a 的 per-cell lane 换成 _slots 的内容 ─────────────────
    // 必须在下面烘焙 insol LUT 之前做，因为 LUT 由 buf.lat_norm 导出。
    if (prefer_slot_lanes) {
        override_climate_round_input_from_slots(n_cells, buf);
    }

    // ─── Item 4 (perf 2026-07-05)：主线程预烘焙年均日照 LUT ────────────────
    // pass_a worker 每 cell 需 dc_insolation_annual_mean(clamp01(ny), axial_tilt, daylen)，
    // 该值 season-无关（16×9 trig/cell）。async kernel 跑在 worker thread、无法安全用 member
    // 缓存，故在此（持锁、主线程）按 lat_norm 逐 cell 预算好，worker 直接读 → bit-equal。
    // 仅 pass_a 参与时（passes_mask & 0x01）才烘焙，省无谓开销；否则清空退回 inline。
    if ((buf.scalars.passes_mask & 0x01) != 0 &&
        (int)buf.lat_norm.size() == n_cells) {
        const float ax_tilt = float(buf.scalars.axial_tilt_deg);
        const float dl_amp  = float(buf.scalars.day_length_gain);
        buf.insol_annual_mean.resize(static_cast<size_t>(n_cells));
        for (int i = 0; i < n_cells; ++i) {
            buf.insol_annual_mean[static_cast<size_t>(i)] =
                dc_insolation_annual_mean(dc_clamp01f(buf.lat_norm[static_cast<size_t>(i)]),
                                          ax_tilt, dl_amp);
        }
    } else {
        buf.insol_annual_mean.clear();
    }

    // 输入边界诊断：只留存 SHADOW capture 交给 worker 的那一份。
    if (prefer_slot_lanes) {
        _captured_climate_round_input = buf;
        _captured_climate_round_input_valid = true;
        ++_capture_call_count;
    }
}

bool DCWorldExt::async_climate_round_kick(const Dictionary &input) {
    using namespace pk_async_climate;
    AsyncClimateRoundState *st = _get_round_state(_async_climate_round_state);
    if (!st || st->task == nullptr) {
        UtilityFunctions::push_warning(
            "[async_climate_round] kick called before register; returning false");
        return false;
    }
    AsyncClimateRoundTask *t = st->task.get();

    // worker 还没消费上一次 request → 跳过本次 kick，主线程沿用上次 result_buf。
    // 这是 x20 速度下追不上的自然降频 fallback。
    if (t->request_pending.load(std::memory_order_acquire)) {
        t->total_reused.fetch_add(1, std::memory_order_relaxed);
        return false;
    }

    const int n_cells = int(input.get("n_cells", 0));
    if (n_cells <= 0) {
        UtilityFunctions::push_warning(
            "[async_climate_round] kick: n_cells <= 0, refusing");
        return false;
    }

    // Snapshot inputs into in_buf under lock.
    {
        std::lock_guard<std::mutex> lk(t->mtx);
        fill_climate_round_input(input, n_cells, t->in_buf);

        t->request_pending.store(true, std::memory_order_release);
    }
    t->cv.notify_one();
    return true;
}

Dictionary DCWorldExt::async_climate_round_poll() {
    using namespace pk_async_climate;
    Dictionary out;
    AsyncClimateRoundState *st = _get_round_state(_async_climate_round_state);
    if (!st || st->task == nullptr) {
        return out;
    }
    AsyncClimateRoundTask *t = st->task.get();
    if (!t->result_ready.load(std::memory_order_acquire)) {
        return out;
    }

    // 错误时不消费 result_ready（保留上一次成功结果），主线程仍能继续。
    const int ec = t->error_code.exchange(PK_ASYNC_ROUND_ERR_OK,
                                          std::memory_order_acq_rel);
    if (ec != PK_ASYNC_ROUND_ERR_OK) {
        UtilityFunctions::push_warning(
            "[async_climate_round] worker error code=", ec);
        return out;
    }

    // 把 result_buf 内容 snapshot 出来 + 立刻 flip result_ready，让 worker
    // 准备好下一轮（如果主线程下一帧立刻 kick）。
    ClimateOutputBuf snapshot;
    {
        std::lock_guard<std::mutex> lk(t->mtx);
        snapshot = t->result_buf;
    }
    t->result_ready.store(false, std::memory_order_release);

    // ─── Sync output → _slots[]，同 sync 路径调 _flush_slot_to_map 推到 MapData ───
    // Stage 2：transp 输出 moisture；pass_a 输出 16 字段（与 run_climate_pass_a
    // 末尾 16 个 _flush_slot_to_map 一一对应）。worker 只在 mask 启用且输入完整时
    // 才填充对应 output 字段；poll 端按 size() != n_cells 来判断是否要写。
    const int n = snapshot.n_cells;
    Array published_slots;
    Array visual_dirty_intents;
    auto append_published_slot = [&](const char *slot_name) {
        const String name(slot_name);
        if (!published_slots.has(name)) {
            published_slots.push_back(name);
        }
    };
    if (n > 0) {
        // 通用 helper：把 vector<float> 写回 _slots[slot_name] + flush。
        auto write_f32_slot = [&](const char *slot_name, const std::vector<float> &src) {
            if ((int)src.size() != n) return;
            const int sid = component_id(StringName(slot_name));
            if (sid < 0 || sid >= _slots.size()) return;
            Slot &s = _slots.write[sid];
            if (s.dtype != SlotDType::F32 || s.arr_f32.size() != n) return;
            std::memcpy(s.arr_f32.ptrw(), src.data(), n * sizeof(float));
            _flush_slot_to_map(sid);
            append_published_slot(slot_name);
        };
        auto write_u8_slot = [&](const char *slot_name, const std::vector<uint8_t> &src) {
            if ((int)src.size() != n) return;
            const int sid = component_id(StringName(slot_name));
            if (sid < 0 || sid >= _slots.size()) return;
            Slot &s = _slots.write[sid];
            if (s.dtype != SlotDType::U8 || s.arr_u8.size() != n) return;
            std::memcpy(s.arr_u8.ptrw(), src.data(), n);
            _flush_slot_to_map(sid);
            append_published_slot(slot_name);
        };

        // pass_a 输出（16 字段，sync 路径同样 16 个 _flush_slot_to_map）
        write_f32_slot("cell_moisture",                snapshot.moisture);
        write_f32_slot("cell_temp_baseline",           snapshot.temp_baseline);
        write_f32_slot("cell_temp_season_offset",      snapshot.temp_season_offset);
        write_u8_slot ("cell_ema_initialized",         snapshot.ema_initialized);
        write_f32_slot("cell_temp_30d",                snapshot.temp_30d);
        write_f32_slot("cell_temp_365d",               snapshot.temp_365d);
        write_f32_slot("cell_temp_anomaly",            snapshot.temp_anomaly);
        write_f32_slot("cell_insolation_now",          snapshot.insolation_now);
        write_f32_slot("cell_insolation_dev",          snapshot.insolation_dev);
        write_f32_slot("cell_day_length",              snapshot.day_length);
        write_f32_slot("cell_heat_input",              snapshot.heat_input);
        write_f32_slot("cell_thermal_energy",          snapshot.thermal_energy);
        write_f32_slot("cell_snowpack",                snapshot.snowpack);
        write_f32_slot("cell_ocean_thermal_anomaly",   snapshot.ocean_thermal_anomaly);
        write_f32_slot("cell_local_thermal_anomaly",   snapshot.local_thermal_anomaly);
        // wind pass 输出（Stage 2）
        write_f32_slot("cell_air_mass_temp_anomaly",   snapshot.air_mass_temp_anomaly);
        write_f32_slot("cell_temp",                    snapshot.temp);  // wind_surface 最终温度
        // sea_ice 输出（Stage 2）。terrain 翻转 sync 路径在 apply_terrain_flips=true
        // 时由 C++ ptrw + flush；async 模式下 worker 已把翻转写入 out.terrain。
        write_f32_slot("cell_sea_ice_frac",            snapshot.sea_ice_frac);
        write_u8_slot ("cell_terrain",                 snapshot.terrain);
        // transp 的 moisture 输出（若 transp 跑过会覆盖 pass_a 的 moisture）。
        // write_f32_slot 是幂等的；如果 transp 没跑 moisture 用 pass_a 的值。

        // ─── finalizer 输出（Stage 9，2026-06-16） ────────────────────────
        // finalizer 写 cell_temp / cell_temperature_transport_anomaly / cell_thermal_energy。
        // cell_temp 已经被 wind_surface 写过（snapshot.temp 上面写过了），finalizer
        // 在 kernel 内对 out.temp in-place clamp。再 write_f32_slot 即覆盖之前的非 clamped 值。
        // TTA 是 finalizer 独有 buffer（tta_final）。thermal_energy 在 kernel 里 init NaN/inf 后写出。
        if (snapshot.fin_applied) {
            write_f32_slot("cell_temp",                         snapshot.temp);          // 已 clamp 后版本
            write_f32_slot("cell_temperature_transport_anomaly", snapshot.tta_final);    // 已 clamp
            write_f32_slot("cell_thermal_energy",                snapshot.thermal_energy); // 已 init
        }
    }

    // 返回 round-level metrics + dirty info 供 GDScript 后处理。
    const int64_t worker_compute_us = (int64_t)t->last_worker_compute_us.load(std::memory_order_relaxed);
    const int64_t worker_total_us = (int64_t)t->last_worker_total_us.load(std::memory_order_relaxed);
    const int64_t transp_us = (int64_t)t->last_transp_us.load(std::memory_order_relaxed);
    const int64_t finalizer_us = (int64_t)t->last_finalizer_us.load(std::memory_order_relaxed);
    const int64_t pass_a_us = (int64_t)t->last_pass_a_us.load(std::memory_order_relaxed);
    const int64_t pass_b_us = (int64_t)t->last_pass_b_us.load(std::memory_order_relaxed);
    const int64_t ocean_water_us = (int64_t)t->last_ocean_water_us.load(std::memory_order_relaxed);
    const int64_t ocean_land_us = (int64_t)t->last_ocean_land_us.load(std::memory_order_relaxed);
    const int64_t wind_air_us = (int64_t)t->last_wind_air_us.load(std::memory_order_relaxed);
    const int64_t wind_surface_us = (int64_t)t->last_wind_surface_us.load(std::memory_order_relaxed);
    const int64_t sea_ice_us = (int64_t)t->last_sea_ice_us.load(std::memory_order_relaxed);
    out["n_cells"]            = snapshot.n_cells;
    out["worker_compute_us"]  = worker_compute_us;
    out["worker_total_us"]    = worker_total_us;
    out["transp_us"]          = transp_us;
    out["finalizer_us"]       = finalizer_us;
    out["pass_a_us"]          = pass_a_us;
    out["pass_b_us"]          = pass_b_us;
    out["ocean_water_us"]     = ocean_water_us;
    out["ocean_land_us"]      = ocean_land_us;
    out["wind_air_us"]        = wind_air_us;
    out["wind_surface_us"]    = wind_surface_us;
    out["sea_ice_us"]         = sea_ice_us;
    out["moisture_dirty_count"] = (int64_t)snapshot.moisture_dirty_indices.size();
    out["published_slots"] = published_slots;
    out["published_slot_count"] = (int64_t)published_slots.size();
    out["visual_dirty_intents"] = visual_dirty_intents;
    Dictionary breakdown;
    breakdown["path"] = String("native_climate_round_poll");
    breakdown["pass_a_ms"] = double(pass_a_us) / 1000.0;
    breakdown["pass_b_ms"] = double(pass_b_us) / 1000.0;
    breakdown["ocean_water_ms"] = double(ocean_water_us) / 1000.0;
    breakdown["ocean_land_ms"] = double(ocean_land_us) / 1000.0;
    breakdown["ocean_ms"] = double(ocean_water_us + ocean_land_us) / 1000.0;
    breakdown["wind_air_ms"] = double(wind_air_us) / 1000.0;
    breakdown["wind_surface_ms"] = double(wind_surface_us) / 1000.0;
    breakdown["wind_ms"] = double(wind_air_us + wind_surface_us) / 1000.0;
    breakdown["sea_ice_ms"] = double(sea_ice_us) / 1000.0;
    breakdown["transp_ms"] = double(transp_us) / 1000.0;
    breakdown["finalizer_ms"] = double(finalizer_us) / 1000.0;
    breakdown["worker_compute_ms"] = double(worker_compute_us) / 1000.0;
    breakdown["worker_total_ms"] = double(worker_total_us) / 1000.0;
    breakdown["published_slot_count"] = (int64_t)published_slots.size();
    breakdown["visual_dirty_intent_count"] = (int64_t)visual_dirty_intents.size();
    out["breakdown"] = breakdown;
    // ─── finalizer diag（Stage 9，2026-06-16） ───────────────────────────
    // 一一对应 GDScript _apply_daily_climate_finalizer 返回 diag 的字段名。
    // GDScript 端 _finalize_round 优先用这些 worker 算好的值，跳过 _apply_*_finalizer。
    out["fin_applied"]                  = snapshot.fin_applied;
    out["fin_max_temp_delta"]           = double(snapshot.fin_max_temp_delta);
    out["fin_p95_temp_delta"]           = double(snapshot.fin_p95_temp_delta);
    out["fin_p99_temp_delta"]           = double(snapshot.fin_p99_temp_delta);
    out["fin_preclamp_max_temp_delta"]  = double(snapshot.fin_preclamp_max_temp_delta);
    out["fin_preclamp_p99_temp_delta"]  = double(snapshot.fin_preclamp_p99_temp_delta);
    out["fin_temp_delta_gt_005_count"]  = (int64_t)snapshot.fin_temp_delta_gt_005_count;
    out["fin_temp_delta_gt_010_count"]  = (int64_t)snapshot.fin_temp_delta_gt_010_count;
    out["fin_temp_delta_gt_020_count"]  = (int64_t)snapshot.fin_temp_delta_gt_020_count;
    out["fin_temp_delta_clamped_count"] = (int64_t)snapshot.fin_temp_delta_clamped_count;
    out["fin_max_transport_anomaly"]    = double(snapshot.fin_max_transport_anomaly);
    out["fin_tta_clamped_count"]        = (int64_t)snapshot.fin_tta_clamped_count;
    out["fin_thermal_init_count"]       = (int64_t)snapshot.fin_thermal_init_count;
    out["fin_sea_ice_delta_max"]        = double(snapshot.fin_sea_ice_delta_max);
    out["fin_precip_p95"]               = double(snapshot.fin_precip_p95);
    out["fin_cells_seen"]               = (int64_t)snapshot.fin_cells_seen;
    // sea_ice flip events（Stage 2）：主线程 poll 后可据此做 atlas dirty mark /
    // map.terrain mirror sync。GDScript 端把它当 PackedInt32Array / PackedByteArray
    // 消费即可。
    if (!snapshot.flipped_cell_indices.empty()) {
        PackedInt32Array flipped_idx;
        flipped_idx.resize((int)snapshot.flipped_cell_indices.size());
        std::memcpy(flipped_idx.ptrw(),
                    snapshot.flipped_cell_indices.data(),
                    snapshot.flipped_cell_indices.size() * sizeof(int32_t));
        PackedByteArray flipped_terr;
        flipped_terr.resize((int)snapshot.flipped_new_terrain.size());
        std::memcpy(flipped_terr.ptrw(),
                    snapshot.flipped_new_terrain.data(),
                    snapshot.flipped_new_terrain.size());
        out["flipped_cell_indices"] = flipped_idx;
        out["flipped_new_terrain"]  = flipped_terr;
        Dictionary intent;
        intent["kind"] = String("sea_ice_terrain_flips");
        intent["dirty_cells"] = (int64_t)snapshot.flipped_cell_indices.size();
        intent["source"] = String("native_climate_round_poll");
        visual_dirty_intents.push_back(intent);
        out["visual_dirty_intents"] = visual_dirty_intents;
        breakdown["visual_dirty_intent_count"] = (int64_t)visual_dirty_intents.size();
        out["breakdown"] = breakdown;
    }
    return out;
}

Dictionary DCWorldExt::async_climate_round_stats() {
    using namespace pk_async_climate;
    Dictionary out;
    AsyncClimateRoundState *st = _get_round_state(_async_climate_round_state);
    if (!st || st->task == nullptr) {
        out["registered"] = false;
        return out;
    }
    AsyncClimateRoundTask *t = st->task.get();
    out["registered"]      = true;
    out["total_rounds"]    = (int64_t)t->total_rounds.load(std::memory_order_relaxed);
    out["total_reused"]    = (int64_t)t->total_reused.load(std::memory_order_relaxed);
    out["request_pending"] = t->request_pending.load(std::memory_order_acquire);
    out["result_ready"]    = t->result_ready.load(std::memory_order_acquire);
    out["worker_compute_us"] = (int64_t)t->last_worker_compute_us.load(std::memory_order_relaxed);
    out["worker_total_us"]   = (int64_t)t->last_worker_total_us.load(std::memory_order_relaxed);
    out["transp_us"]         = (int64_t)t->last_transp_us.load(std::memory_order_relaxed);
    return out;
}

Dictionary DCWorldExt::native_climate_round_begin(const Dictionary &static_knobs) {
    Dictionary out;
    async_climate_round_register();
    if (!static_knobs.is_empty()) {
        async_climate_round_set_static_knobs(static_knobs);
    }
    out["rc"] = 0;
    out["path"] = String("native_climate_round_begin");
    out["authority"] = String("probe_native_state");
    out["simulation_authority"] = false;
    out["state"] = get_native_climate_round_state_report();
    return out;
}

Dictionary DCWorldExt::native_climate_round_begin_round(const Dictionary &ctx) {
    using namespace pk_async_climate;
    async_climate_round_register();
    AsyncClimateRoundState *st = _get_or_create_round_state(_async_climate_round_state);
    {
        std::lock_guard<std::mutex> g(st->state_mtx);
        st->lifecycle_round_id += 1;
        st->lifecycle_round_active = true;
        st->lifecycle_async_kicked = false;
        st->lifecycle_pass_cursor = int(ctx.get("pass_cursor", 0));
        st->lifecycle_tick_index = (int64_t)ctx.get("tick_index", (int64_t)-1);
        st->lifecycle_poll_attempts = 0;
        st->lifecycle_phase_locked = double(ctx.get("phase_locked", 0.0));
        st->lifecycle_stage = "round_started";
        st->lifecycle_owner = "native_probe_lifecycle";
        st->lifecycle_start_state_intents.clear();
        st->lifecycle_start_state_intents.push_back("set_round_active");
        st->lifecycle_start_state_intents.push_back("set_phase_locked");
        st->lifecycle_start_state_intents.push_back("set_pass_cursor");
        st->lifecycle_start_state_intents.push_back("reset_async_kicked");
        st->lifecycle_start_state_intents.push_back("reset_poll_attempts");
        st->lifecycle_start_state_intents.push_back("record_tick_index");
        st->lifecycle_boundary_intents.clear();
        st->lifecycle_boundary_intents.push_back("sync_runtime_terrain_views");
        st->lifecycle_boundary_intents.push_back("begin_round_pass_state");
        st->lifecycle_boundary_intents.push_back("soa_begin_climate_transaction");
        st->lifecycle_finish_boundary_intents.clear();
        st->lifecycle_finalize_tail_boundary_intents.clear();
    }
    Dictionary out;
    out["rc"] = 0;
    out["path"] = String("native_climate_round_begin_round");
    out["authority"] = String("probe_native_lifecycle");
    out["simulation_authority"] = false;
    out["boundary_intent_owner"] = String("native_probe_lifecycle");
    Dictionary state = get_native_climate_round_state_report();
    out["state"] = state;
    out["start_state_intents"] = state.get("start_state_intents", Array());
    out["start_state_intent_owner"] = state.get("start_state_intent_owner", String("native_probe_lifecycle"));
    out["boundary_intents"] = state.get("boundary_intents", Array());
    return out;
}

Dictionary DCWorldExt::native_climate_round_kick(const Dictionary &input) {
    using namespace pk_async_climate;
    Dictionary out;
    async_climate_round_register();
    const bool kicked = async_climate_round_kick(input);
    AsyncClimateRoundState *st = _get_round_state(_async_climate_round_state);
    if (st) {
        std::lock_guard<std::mutex> g(st->state_mtx);
        if (kicked) {
            st->lifecycle_async_kicked = true;
            st->lifecycle_stage = "worker_kicked";
        } else if (st->lifecycle_round_active) {
            st->lifecycle_stage = "worker_busy_or_rejected";
        }
    }
    Dictionary state = get_native_climate_round_state_report();
    out["rc"] = 0;
    out["path"] = String("native_climate_round_kick");
    out["authority"] = String("probe_native_state");
    out["simulation_authority"] = false;
    out["kicked"] = kicked;
    out["substage"] = kicked ? String("kicked") : String("worker_busy_or_rejected");
    out["state"] = state;
    return out;
}

Dictionary DCWorldExt::native_climate_round_poll() {
    using namespace pk_async_climate;
    Dictionary out;
    Dictionary result = async_climate_round_poll();
    const bool done = !result.is_empty();
    AsyncClimateRoundState *st = _get_round_state(_async_climate_round_state);
    if (st) {
        std::lock_guard<std::mutex> g(st->state_mtx);
        if (st->lifecycle_round_active && st->lifecycle_async_kicked) {
            st->lifecycle_poll_attempts += 1;
        }
        st->lifecycle_stage = done ? "poll_done" : "poll_pending";
        if (done) {
            st->lifecycle_finish_boundary_intents.clear();
            st->lifecycle_finish_boundary_intents.push_back("apply_sea_ice_flips");
            st->lifecycle_finish_boundary_intents.push_back("finalize_round");
            st->lifecycle_finish_boundary_intents.push_back("finish_native_lifecycle");
            st->lifecycle_finalize_tail_boundary_intents.clear();
            st->lifecycle_finalize_tail_boundary_intents.push_back(bool(result.get("fin_applied", false)) ? "use_worker_finalizer_diag" : "apply_gdscript_finalizer_fallback");
            st->lifecycle_finalize_tail_boundary_intents.push_back("advance_full_sweep_counter");
            st->lifecycle_finalize_tail_boundary_intents.push_back("publish_climate_breakdown");
            st->lifecycle_finalize_tail_boundary_intents.push_back("annual_log");
            st->lifecycle_finalize_tail_boundary_intents.push_back("soa_noop");
            st->lifecycle_finalize_tail_boundary_intents.push_back("soak_dump");
            st->lifecycle_finalize_tail_boundary_intents.push_back("integrity_check");
            st->lifecycle_finalize_tail_boundary_intents.push_back("finish_active_pass");
            st->lifecycle_finalize_tail_boundary_intents.push_back("reset_transpiration_state");
            st->lifecycle_finalize_tail_boundary_intents.push_back("reset_round_local_state");
            st->lifecycle_finalize_tail_boundary_intents.push_back("flush_pending_mark_dirty_all");
            st->lifecycle_finalize_tail_boundary_intents.push_back("mark_round_slots_stale");
            st->lifecycle_finalize_tail_boundary_intents.push_back("dump_round_slot_stats");
        }
    }
    Dictionary state = get_native_climate_round_state_report();
    out["rc"] = 0;
    out["path"] = String("native_climate_round_poll");
    out["authority"] = String("probe_native_state");
    out["simulation_authority"] = false;
    out["done"] = done;
    out["result"] = result;
    out["published_slots"] = result.get("published_slots", Array());
    out["published_slot_count"] = result.get("published_slot_count", (int64_t)0);
    out["visual_dirty_intents"] = result.get("visual_dirty_intents", Array());
    out["breakdown"] = result.get("breakdown", Dictionary());
    out["finish_boundary_intents"] = state.get("finish_boundary_intents", Array());
    out["finish_boundary_intent_owner"] = state.get("finish_boundary_intent_owner", String("native_probe_lifecycle"));
    out["finalize_tail_boundary_intents"] = state.get("finalize_tail_boundary_intents", Array());
    out["finalize_tail_boundary_intent_owner"] = state.get("finalize_tail_boundary_intent_owner", String("native_probe_lifecycle"));
    out["worker_total_us"] = result.get("worker_total_us", (int64_t)0);
    out["worker_compute_us"] = result.get("worker_compute_us", (int64_t)0);
    out["finalizer_us"] = result.get("finalizer_us", (int64_t)0);
    out["state"] = state;
    return out;
}

Dictionary DCWorldExt::native_climate_round_finish_round(const Dictionary &ctx) {
    using namespace pk_async_climate;
    Dictionary out;
    AsyncClimateRoundState *st = _get_round_state(_async_climate_round_state);
    if (!st) {
        out["rc"] = -1;
        out["path"] = String("native_climate_round_finish_round");
        out["fallback_reason"] = String("native_climate_round_state_missing");
        out["authority"] = String("probe_native_lifecycle");
        out["simulation_authority"] = false;
        out["state"] = get_native_climate_round_state_report();
        return out;
    }
    {
        std::lock_guard<std::mutex> g(st->state_mtx);
        st->lifecycle_round_active = false;
        st->lifecycle_async_kicked = false;
        st->lifecycle_pass_cursor = int(ctx.get("pass_cursor", st->lifecycle_pass_cursor));
        st->lifecycle_stage = String(ctx.get("stage", String("round_finished"))).utf8().get_data();
    }
    out["rc"] = 0;
    out["path"] = String("native_climate_round_finish_round");
    out["authority"] = String("probe_native_lifecycle");
    out["simulation_authority"] = false;
    out["state"] = get_native_climate_round_state_report();
    return out;
}

Dictionary DCWorldExt::get_native_climate_round_hot_state() {
    using namespace pk_async_climate;
    Dictionary out;
    out["owner"] = String("DCWorldExt.AsyncClimateRoundState");
    out["authority"] = String("native_ready_capsule");
    out["simulation_authority"] = false;
    out["climate_round_authority_ready"] = true;
    out["compact_state_capsule"] = true;
    AsyncClimateRoundState *st = _get_round_state(_async_climate_round_state);
    if (!st) {
        out["ready"] = false;
        out["round_active"] = false;
        out["pass_cursor"] = 0;
        out["generation"] = int64_t(0);
        out["boundary_intent_mask"] = int64_t(0);
        return out;
    }
    std::lock_guard<std::mutex> g(st->state_mtx);
    int64_t boundary_intent_mask = 0;
    if (!st->lifecycle_start_state_intents.empty())
        boundary_intent_mask |= 1;
    if (!st->lifecycle_boundary_intents.empty())
        boundary_intent_mask |= 2;
    if (!st->lifecycle_finish_boundary_intents.empty())
        boundary_intent_mask |= 4;
    if (!st->lifecycle_finalize_tail_boundary_intents.empty())
        boundary_intent_mask |= 8;
    out["ready"] = st->task != nullptr;
    out["round_active"] = st->lifecycle_round_active;
    out["async_kicked"] = st->lifecycle_async_kicked;
    out["pass_cursor"] = st->lifecycle_pass_cursor;
    out["round_id"] = st->lifecycle_round_id;
    out["generation"] = st->lifecycle_round_id;
    out["tick_index"] = st->lifecycle_tick_index;
    out["phase_locked"] = st->lifecycle_phase_locked;
    out["stage"] = String(st->lifecycle_stage.c_str());
    out["dirty"] = boundary_intent_mask != 0;
    out["boundary_intent_mask"] = boundary_intent_mask;
    return out;
}

Dictionary DCWorldExt::get_native_climate_round_state_report() {
    using namespace pk_async_climate;
    Dictionary out;
    out["owner"] = String("DCWorldExt.AsyncClimateRoundState");
    out["authority"] = String("probe_native_state");
    out["simulation_authority"] = false;
    out["registered"] = false;
    out["lifecycle_state"] = String("unregistered");
    out["reset_owner"] = String("DCWorldExt.reset_native_climate_round_state");
    out["gdscript_authority_expected"] = false;
    out["climate_round_state_owner_candidate"] = String("DCWorldExt.AsyncClimateRoundState");
    out["climate_round_authority_ready"] = true;
    out["climate_round_authority_phase"] = String("native_ready_probe");
    Array authority_blockers;
    out["climate_round_authority_blockers"] = authority_blockers;
    Array remaining_gdscript_authority;
    remaining_gdscript_authority.push_back(String("should_run_stride_policy"));
    remaining_gdscript_authority.push_back(String("godot_mapdata_boundary_execution"));
    remaining_gdscript_authority.push_back(String("reset_abort_boundary_execution"));
    remaining_gdscript_authority.push_back(String("sync_sliced_fallback"));
    out["remaining_gdscript_authority"] = remaining_gdscript_authority;
    out["remaining_gdscript_simulation_authority"] =
        Array::make(String("should_run_stride_policy"),
                    String("sync_sliced_fallback"));
    out["remaining_godot_boundary_authority"] =
        Array::make(String("godot_mapdata_boundary_execution"),
                    String("reset_abort_boundary_execution"));
    out["native_owned_lifecycle_authority"] =
        Array::make(String("round_active"),
                    String("phase_locked"),
                    String("pass_cursor"),
                    String("async_kick_poll"),
                    String("pass_token"),
                    String("finalizer_source_intent"));

    AsyncClimateRoundState *st = _get_round_state(_async_climate_round_state);
    if (!st) {
        return out;
    }

    std::lock_guard<std::mutex> g(st->state_mtx);
    out["lifecycle_owner"] = String(st->lifecycle_owner.c_str());
    out["lifecycle_round_active"] = st->lifecycle_round_active;
    out["lifecycle_async_kicked"] = st->lifecycle_async_kicked;
    out["lifecycle_pass_cursor"] = st->lifecycle_pass_cursor;
    out["lifecycle_round_id"] = st->lifecycle_round_id;
    out["lifecycle_tick_index"] = st->lifecycle_tick_index;
    out["lifecycle_poll_attempts"] = st->lifecycle_poll_attempts;
    out["phase_locked"] = st->lifecycle_phase_locked;
    out["phase_lock_owner"] = String("native_probe_lifecycle");
    out["lifecycle_stage"] = String(st->lifecycle_stage.c_str());
    Array start_state_intents;
    for (const std::string &intent : st->lifecycle_start_state_intents) {
        start_state_intents.push_back(String(intent.c_str()));
    }
    out["start_state_intents"] = start_state_intents;
    out["start_state_intent_owner"] = String("native_probe_lifecycle");
    Array boundary_intents;
    for (const std::string &intent : st->lifecycle_boundary_intents) {
        boundary_intents.push_back(String(intent.c_str()));
    }
    out["boundary_intents"] = boundary_intents;
    out["boundary_intent_owner"] = String("native_probe_lifecycle");
    Array finish_boundary_intents;
    for (const std::string &intent : st->lifecycle_finish_boundary_intents) {
        finish_boundary_intents.push_back(String(intent.c_str()));
    }
    out["finish_boundary_intents"] = finish_boundary_intents;
    out["finish_boundary_intent_owner"] = String("native_probe_lifecycle");
    Array finalize_tail_boundary_intents;
    for (const std::string &intent : st->lifecycle_finalize_tail_boundary_intents) {
        finalize_tail_boundary_intents.push_back(String(intent.c_str()));
    }
    out["finalize_tail_boundary_intents"] = finalize_tail_boundary_intents;
    out["finalize_tail_boundary_intent_owner"] = String("native_probe_lifecycle");
    if (st->task == nullptr) {
        out["lifecycle_state"] = String("state_allocated_without_task");
        return out;
    }

    AsyncClimateRoundTask *t = st->task.get();
    const bool request_pending = t->request_pending.load(std::memory_order_acquire);
    const bool result_ready = t->result_ready.load(std::memory_order_acquire);
    const bool should_exit = t->should_exit.load(std::memory_order_acquire);
    out["registered"] = true;
    out["request_pending"] = request_pending;
    out["result_ready"] = result_ready;
    out["should_exit"] = should_exit;
    out["lifecycle_state"] = should_exit
        ? String("shutting_down")
        : (request_pending ? String("request_pending")
                           : (result_ready ? String("result_ready") : String("idle")));
    out["total_rounds"] = (int64_t)t->total_rounds.load(std::memory_order_relaxed);
    out["total_reused"] = (int64_t)t->total_reused.load(std::memory_order_relaxed);
    out["error_code"] = t->error_code.load(std::memory_order_relaxed);
    out["worker_compute_us"] = (int64_t)t->last_worker_compute_us.load(std::memory_order_relaxed);
    out["worker_total_us"] = (int64_t)t->last_worker_total_us.load(std::memory_order_relaxed);
    out["pass_a_us"] = (int64_t)t->last_pass_a_us.load(std::memory_order_relaxed);
    out["pass_b_us"] = (int64_t)t->last_pass_b_us.load(std::memory_order_relaxed);
    out["ocean_water_us"] = (int64_t)t->last_ocean_water_us.load(std::memory_order_relaxed);
    out["ocean_land_us"] = (int64_t)t->last_ocean_land_us.load(std::memory_order_relaxed);
    out["wind_air_us"] = (int64_t)t->last_wind_air_us.load(std::memory_order_relaxed);
    out["wind_surface_us"] = (int64_t)t->last_wind_surface_us.load(std::memory_order_relaxed);
    out["sea_ice_us"] = (int64_t)t->last_sea_ice_us.load(std::memory_order_relaxed);
    out["transp_us"] = (int64_t)t->last_transp_us.load(std::memory_order_relaxed);
    out["finalizer_us"] = (int64_t)t->last_finalizer_us.load(std::memory_order_relaxed);
    {
        std::lock_guard<std::mutex> lk(t->mtx);
        out["static_n_cells"] = t->static_knobs.n_cells;
        out["input_n_cells"] = t->in_buf.n_cells;
    }
    return out;
}

Dictionary DCWorldExt::reset_native_climate_round_state(const String &reason) {
    Dictionary before = get_native_climate_round_state_report();
    async_climate_round_shutdown();
    Dictionary out;
    out["rc"] = 0;
    out["reason"] = reason;
    out["reset_owner"] = String("DCWorldExt.reset_native_climate_round_state");
    out["authority"] = String("probe_native_state");
    out["simulation_authority"] = false;
    out["previous_state"] = before;
    out["current_state"] = get_native_climate_round_state_report();
    Array reset_boundary_intents;
    reset_boundary_intents.push_back(String("abort_active_pass"));
    reset_boundary_intents.push_back(String("abort_all_climate_passes"));
    reset_boundary_intents.push_back(String("reset_round_local_state"));
    reset_boundary_intents.push_back(String("reset_async_lifecycle_local_state"));
    reset_boundary_intents.push_back(String("reset_round_timings"));
    reset_boundary_intents.push_back(String("reset_start_snapshots"));
    reset_boundary_intents.push_back(String("reset_last_diagnostics"));
    reset_boundary_intents.push_back(String("reset_transpiration_state"));
    reset_boundary_intents.push_back(String("reset_dirty_season_state"));
    reset_boundary_intents.push_back(String("seed_full_sweep_counter"));
    out["reset_boundary_intents"] = reset_boundary_intents;
    out["reset_boundary_intent_owner"] = String("native_probe_lifecycle");
    return out;
}

void DCWorldExt::async_climate_round_shutdown() {
    using namespace pk_async_climate;
    AsyncClimateRoundState *st = _get_round_state(_async_climate_round_state);
    if (!st) return;
    std::unique_ptr<AsyncClimateRoundTask> dead;
    {
        std::lock_guard<std::mutex> g(st->state_mtx);
        dead = std::move(st->task);
    }
    if (dead) {
        dead->should_exit.store(true, std::memory_order_release);
        dead->cv.notify_all();
        if (dead->worker.joinable()) dead->worker.join();
    }
    delete st;
    _async_climate_round_state = nullptr;
}

} // namespace pk
