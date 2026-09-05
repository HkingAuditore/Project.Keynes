#pragma once

#include <atomic>
#include <condition_variable>
#include <cstdint>
#include <mutex>
#include <thread>
#include <vector>

namespace pk {

// Process-local fixed worker pool for native simulation kernels. It deliberately
// has no Godot includes or callbacks, so it remains valid when the caller is the
// simulation coordinator thread rather than the Godot main thread.
class NativeParallelExecutor {
public:
    using TaskFn = void (*)(void *, uint32_t);

    struct Report {
        uint32_t hardware_threads = 1;
        uint32_t worker_threads = 0;
        uint32_t active_worker_limit = 0;
        uint64_t dispatch_count = 0;
        uint64_t serial_dispatch_count = 0;
        uint64_t task_count = 0;
        uint64_t fault_count = 0;
        bool interactive = false;
    };

    static NativeParallelExecutor &instance();

    NativeParallelExecutor(const NativeParallelExecutor &) = delete;
    NativeParallelExecutor &operator=(const NativeParallelExecutor &) = delete;

    bool has_workers() const;
    void set_interactive(bool interactive);
    Report report() const;
    void run_group(uint32_t task_count, TaskFn fn, void *userdata);

private:
    NativeParallelExecutor();
    ~NativeParallelExecutor();

    void worker_loop(uint32_t worker_index);
    uint32_t active_worker_limit() const;

    const uint32_t _hardware_threads;
    std::vector<std::thread> _workers;
    std::atomic<bool> _interactive{false};
    std::atomic<bool> _stopping{false};

    // A group owns stack-backed userdata until run_group returns, therefore
    // only one producer may publish a group at a time.
    mutable std::mutex _dispatch_mutex;
    mutable std::mutex _state_mutex;
    std::condition_variable _work_cv;
    std::condition_variable _done_cv;
    uint64_t _generation = 0;
    TaskFn _task_fn = nullptr;
    void *_task_userdata = nullptr;
    uint32_t _published_task_count = 0;
    uint32_t _participating_workers = 0;
    std::atomic<uint32_t> _next_task{0};
    std::atomic<uint32_t> _remaining_tasks{0};

    std::atomic<uint64_t> _dispatch_count{0};
    std::atomic<uint64_t> _serial_dispatch_count{0};
    std::atomic<uint64_t> _task_count{0};
    std::atomic<uint64_t> _fault_count{0};
};

} // namespace pk
