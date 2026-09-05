#include "native_parallel_executor.h"

#include <algorithm>

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
} // namespace

NativeParallelExecutor &NativeParallelExecutor::instance() {
    static NativeParallelExecutor executor;
    return executor;
}

NativeParallelExecutor::NativeParallelExecutor()
    : _hardware_threads(detected_hardware_threads()) {
    // Normal simulation keeps two logical cores for the main/render threads.
    const uint32_t worker_count = _hardware_threads > 2
        ? std::min<uint32_t>(_hardware_threads - 2, 16) : 0;
    _workers.reserve(worker_count);
    for (uint32_t index = 0; index < worker_count; ++index)
        _workers.emplace_back([this, index]() { worker_loop(index); });
}

NativeParallelExecutor::~NativeParallelExecutor() {
    _stopping.store(true, std::memory_order_release);
    _work_cv.notify_all();
    for (std::thread &worker : _workers)
        if (worker.joinable()) worker.join();
}

bool NativeParallelExecutor::has_workers() const {
    return !_workers.empty();
}

void NativeParallelExecutor::set_interactive(bool interactive) {
    _interactive.store(interactive, std::memory_order_release);
}

uint32_t NativeParallelExecutor::active_worker_limit() const {
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
    return out;
}

void NativeParallelExecutor::run_group(uint32_t task_count, TaskFn fn,
                                       void *userdata) {
    if (task_count == 0 || fn == nullptr) return;
    std::lock_guard<std::mutex> dispatch_guard(_dispatch_mutex);
    ++_dispatch_count;
    _task_count.fetch_add(task_count, std::memory_order_relaxed);
    const uint32_t participants = std::min(task_count, active_worker_limit());
    if (participants == 0) {
        ++_serial_dispatch_count;
        for (uint32_t task = 0; task < task_count; ++task) fn(userdata, task);
        return;
    }

    {
        std::lock_guard<std::mutex> state_guard(_state_mutex);
        _task_fn = fn;
        _task_userdata = userdata;
        _published_task_count = task_count;
        _participating_workers = participants;
        _next_task.store(0, std::memory_order_relaxed);
        _remaining_tasks.store(task_count, std::memory_order_release);
        ++_generation;
    }
    _work_cv.notify_all();

    std::unique_lock<std::mutex> state_lock(_state_mutex);
    _done_cv.wait(state_lock, [this]() {
        return _remaining_tasks.load(std::memory_order_acquire) == 0;
    });
    _task_fn = nullptr;
    _task_userdata = nullptr;
    _published_task_count = 0;
    _participating_workers = 0;
}

void NativeParallelExecutor::worker_loop(uint32_t worker_index) {
#if defined(_WIN32)
    SetThreadPriority(GetCurrentThread(), THREAD_PRIORITY_BELOW_NORMAL);
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
        }
        if (!participates || fn == nullptr) continue;

        while (true) {
            const uint32_t task = _next_task.fetch_add(1,
                                                       std::memory_order_relaxed);
            if (task >= task_count) break;
            // Native kernels are required to be noexcept in production. A
            // thrown exception would violate the deterministic group barrier;
            // keep this path allocation-free and let the process-level fault
            // handler own such programmer errors.
            fn(userdata, task);
            if (_remaining_tasks.fetch_sub(1, std::memory_order_acq_rel) == 1) {
                std::lock_guard<std::mutex> state_guard(_state_mutex);
                _done_cv.notify_one();
            }
        }
    }
}

} // namespace pk
