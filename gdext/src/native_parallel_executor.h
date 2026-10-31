#pragma once

#include <atomic>
#include <condition_variable>
#include <cstdint>
#include <mutex>
#include <thread>
#include <vector>

namespace pk {

// native_daily_inline：内联日 = 单线程日。
//
// 置位后 `run_group` 一律在调用线程上把闭包顺序跑完：不唤醒 worker、不在
// `_done_cv` 上等。两个理由都是浏览器特有的：
//   1. 主线程不允许阻塞在 futex/`Atomics.wait` 上，"等一组 worker"在 wasm 里
//      只能退化成忙等或直接抛异常 —— 主线程一旦不再返回，连 WebTelemetry 的
//      心跳都发不出去，页面表现为完全挂死；
//   2. wasm 的 pthread 池可能已被 Godot 自己的 WorkerThreadPool 占满，起不来
//      的 worker 会让 group barrier 永远等不到 `_remaining_tasks == 0`。
// 顺序路径与本文件原有的"无 worker" fallback 完全同一条代码，逐字节等价，
// 因此确定性不变。
void set_parallel_serial_only(bool enabled) noexcept;
bool parallel_serial_only() noexcept;

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
        bool serial_only = false;
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
    // Workers that have taken `_task_fn` out of the critical section and may
    // still call it. `_remaining_tasks == 0` alone does not imply this is 0: a
    // worker can be preempted between reading the group and entering its task
    // loop, and would then call the previous group's fn — whose stack-backed
    // userdata run_group has already released — against the next group's task
    // cursor. run_group must wait on both.
    uint32_t _active_workers = 0;
    std::atomic<uint32_t> _next_task{0};
    std::atomic<uint32_t> _remaining_tasks{0};

    std::atomic<uint64_t> _dispatch_count{0};
    std::atomic<uint64_t> _serial_dispatch_count{0};
    std::atomic<uint64_t> _task_count{0};
    std::atomic<uint64_t> _fault_count{0};
};

} // namespace pk
