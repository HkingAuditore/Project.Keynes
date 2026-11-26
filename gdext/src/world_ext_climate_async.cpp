#include "world_ext.h"
#include "simulation_math.h"

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

#include "world_ext_climate_async_section_compatibility_tasks.inc"

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
#include "world_ext_climate_async_section_round_inputs.inc"

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

#include "world_ext_climate_async_section_round_session.inc"

} // namespace pk
