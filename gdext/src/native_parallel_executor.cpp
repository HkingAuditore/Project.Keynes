#include "native_parallel_executor.h"

#include <algorithm>
#include <cstring>

#include "runtime_switch_registry.h"

#if defined(_WIN32)
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h>
#endif

namespace pk {

namespace {
uint32_t detected_hardware_threads() {
    const uint32_t detected = std::thread::hardware_concurrency();
    return detected == 0 ? 1 : detected;
}

// native_daily_inline：全局串行开关。进程级而不是实例级，因为内联开关是在
// 世界生成之后（start_runtime_worker）才落下来的，而执行器可能在更早的
// configure_runtime_graph 里就已经构造过。置位后即使 worker 已经存在也不再
// 使用它们。
//
// [web-fix 2026-11-25] Web 上默认就要串行，而且必须在这里就置位：
//   * 本文件按 `hardware_concurrency()-2`（上限 16）spawn worker。浏览器报 32 核
//     时这一项就是 16 条，而 Emscripten 的 pthread 池只有 export_presets.cfg 的
//     threads/emscripten_pool_size（当前 16），Godot 自己的 WorkerThreadPool 还要
//     从同一个池里占一份。池子打满后 pthread_create 逐个阻塞，实测 21 条
//     "thread pool is exhausted"。
//   * 真正把 serial 置位的 set_parallel_serial_only() 在
//     world_ext_simulation_host.cpp 的 start_runtime_worker 里，而执行器早在
//     mapgen 阶段的第一次 parallel_for_range 就已经构造完了 —— 时序打穿，web 上
//     白 spawn 16 条注定要等池子的线程。
//   * 同一个文件里 2026-10-31 的实测也支持串行：worker 模式 2.70 天/秒，inline
//     模式 9.81 天/秒，web 上串行快 5-8 倍。
// 真机调试要放出并行器时仍可用 PK_WEB_PARALLEL=1（见下面 override）。
#if defined(__EMSCRIPTEN__)
const bool g_pk_web_parallel_override = [] {
    const char *value = runtime_switch_value(RuntimeSwitch::PK_WEB_PARALLEL);
    return value != nullptr && std::strcmp(value, "1") == 0;
}();
std::atomic<bool> g_parallel_serial_only{!g_pk_web_parallel_override};
#else
std::atomic<bool> g_parallel_serial_only{false};
#endif
} // namespace

void set_parallel_serial_only(bool enabled) noexcept {
    g_parallel_serial_only.store(enabled, std::memory_order_release);
}

bool parallel_serial_only() noexcept {
    return g_parallel_serial_only.load(std::memory_order_acquire);
}

NativeParallelExecutor &NativeParallelExecutor::instance() {
    static NativeParallelExecutor executor;
    return executor;
}

NativeParallelExecutor::NativeParallelExecutor()
    : _hardware_threads(detected_hardware_threads()) {
    // Normal simulation keeps two logical cores for the main/render threads.
    const uint32_t worker_count = _hardware_threads > 2
        ? std::min<uint32_t>(_hardware_threads - 2, 16) : 0;
    // 内联日不 spawn 任何 worker：浏览器里每一个 wasm pthread 都是一次真正的
    // worker 启动（池满时直接失败），而内联日不需要它们。
#if defined(__EMSCRIPTEN__) && !defined(__EMSCRIPTEN_PTHREADS__)
    return;
#else
    if (parallel_serial_only()) return;
    _workers.reserve(worker_count);
    for (uint32_t index = 0; index < worker_count; ++index)
        _workers.emplace_back([this, index]() { worker_loop(index); });
#endif
}

NativeParallelExecutor::~NativeParallelExecutor() {
    {
        std::lock_guard<std::mutex> lock(_state_mutex);
        _stopping.store(true, std::memory_order_release);
    }
    _work_cv.notify_all();
    for (std::thread &worker : _workers)
        if (worker.joinable()) worker.join();
}

bool NativeParallelExecutor::has_workers() const {
    // 串行开关优先：调用方（pk::parallel_for_range）看到"没有 worker"就走它
    // 原本的确定性串行分块路径，连 _done_cv 都不会碰。
    if (parallel_serial_only()) return false;
    return !_workers.empty();
}

void NativeParallelExecutor::set_interactive(bool interactive) {
    _interactive.store(interactive, std::memory_order_release);
#if defined(_WIN32)
    // Interactive sessions keep workers below normal so the render/main threads
    // stay responsive. Headless replay/benchmark runs are not interactive and
    // must not be starved by desktop processes: normal priority lets the
    // derived-demand parallel tasks actually use their cores.
    const int priority = interactive ? THREAD_PRIORITY_BELOW_NORMAL
                                     : THREAD_PRIORITY_NORMAL;
    for (std::thread &worker : _workers) {
        if (!worker.joinable()) continue;
        HANDLE handle = worker.native_handle();
        if (handle != nullptr) SetThreadPriority(handle, priority);
    }
#endif
}

uint32_t NativeParallelExecutor::active_worker_limit() const {
    if (parallel_serial_only()) return 0;
    if (!_interactive.load(std::memory_order_acquire))
        return static_cast<uint32_t>(_workers.size());
    // Four-core and smaller devices use only the simulation coordinator while
    // interacting. Larger devices reserve at least four logical cores.
    if (_hardware_threads <= 4) return 0;
    return std::min<uint32_t>(static_cast<uint32_t>(_workers.size()),
                              _hardware_threads - 4);
}

NativeParallelExecutor::Report NativeParallelExecutor::report() const {
    Report out;
    out.hardware_threads = _hardware_threads;
    out.worker_threads = static_cast<uint32_t>(_workers.size());
    out.active_worker_limit = active_worker_limit();
    out.dispatch_count = _dispatch_count.load(std::memory_order_relaxed);
    out.serial_dispatch_count =
        _serial_dispatch_count.load(std::memory_order_relaxed);
    out.task_count = _task_count.load(std::memory_order_relaxed);
    out.fault_count = _fault_count.load(std::memory_order_relaxed);
    out.interactive = _interactive.load(std::memory_order_acquire);
    out.serial_only = parallel_serial_only();
    return out;
}

void NativeParallelExecutor::run_group(uint32_t task_count, TaskFn fn,
                                       void *userdata) {
    if (task_count == 0 || fn == nullptr) return;
    std::lock_guard<std::mutex> dispatch_guard(_dispatch_mutex);
    ++_dispatch_count;
    _task_count.fetch_add(task_count, std::memory_order_relaxed);
    const uint32_t lanes = std::min(task_count, active_worker_limit());
    if (lanes <= 1) {
        ++_serial_dispatch_count;
        for (uint32_t task = 0; task < task_count; ++task) fn(userdata, task);
        return;
    }

    {
        std::lock_guard<std::mutex> state_guard(_state_mutex);
        _task_fn = fn;
        _task_userdata = userdata;
        _published_task_count = task_count;
        _participating_workers = lanes - 1;
        _next_task.store(1, std::memory_order_relaxed);
        ++_generation;
    }
    _work_cv.notify_all();
    // Task zero belongs to the caller. Short groups can finish here before
    // the first worker wakes, while longer ones use the other lanes.
    fn(userdata, 0);
    run_remaining_tasks(fn, userdata, task_count);

    std::unique_lock<std::mutex> state_lock(_state_mutex);
    _task_fn = nullptr;
    _task_userdata = nullptr;
    _done_cv.wait(state_lock, [this]() { return _active_workers == 0; });
}

void NativeParallelExecutor::run_remaining_tasks(TaskFn fn, void *userdata, uint32_t task_count) {
    for (uint32_t task = _next_task.fetch_add(1, std::memory_order_relaxed);
         task < task_count;
         task = _next_task.fetch_add(1, std::memory_order_relaxed)) {
        fn(userdata, task);
    }
}

void NativeParallelExecutor::worker_loop(uint32_t worker_index) {
#if defined(_WIN32)
    if (_interactive.load(std::memory_order_acquire)) {
        SetThreadPriority(GetCurrentThread(), THREAD_PRIORITY_BELOW_NORMAL);
    }
#endif
    uint64_t observed_generation = 0;
    while (true) {
        TaskFn fn = nullptr;
        void *userdata = nullptr;
        uint32_t task_count = 0;
        bool participates = false;
        {
            std::unique_lock<std::mutex> state_lock(_state_mutex);
            _work_cv.wait(state_lock, [this, observed_generation]() {
                return _stopping.load(std::memory_order_acquire) ||
                    _generation != observed_generation;
            });
            if (_stopping.load(std::memory_order_acquire)) return;
            observed_generation = _generation;
            fn = _task_fn;
            userdata = _task_userdata;
            task_count = _published_task_count;
            participates = worker_index < _participating_workers;
            // Claimed inside the critical section, before this thread can be
            // preempted, so run_group cannot return — and cannot invalidate
            // the userdata this thread just took — until the task loop below
            // has exited.
            if (participates && fn != nullptr) ++_active_workers;
        }
        if (!participates || fn == nullptr) continue;

        run_remaining_tasks(fn, userdata, task_count);

        {
            std::lock_guard<std::mutex> state_guard(_state_mutex);
            if (--_active_workers == 0) _done_cv.notify_one();
        }
    }
}

} // namespace pk
