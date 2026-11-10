#include "native_simulation_host.h"

#include <algorithm>

namespace pk {

bool NativeSimulationHost::resume_same_world_executor(double speed, bool paused) {
    // Only the executor is being replaced. Stores, clocks, cursors, receipts,
    // and the current day's frozen input belong to the same world.
    {
        std::lock_guard<std::mutex> lock(_command_enqueue_mutex);
        RuntimeCommandPacket queued;
        while (pop_command(queued)) _executor_pending_commands.push_back(std::move(queued));
    }
    seed_executor_command_orders();
    _economy_pending_command_count.store(static_cast<uint32_t>(
        _executor_pending_commands.size()), std::memory_order_release);
    _stage_ops_day_phase_atomic.store(static_cast<uint8_t>(_stage_ops_day_phase),
                                      std::memory_order_release);
    _paused.store(paused, std::memory_order_release);
    _speed_days_per_second.store(std::max(0.0, speed), std::memory_order_release);
    _authority_control.begin_lifetime();
    publish_authority_grant(lifetime_granted_mask() &
        _requested_authority_mask.load(std::memory_order_acquire));
    _stop_requested.store(false, std::memory_order_release);
    return launch_executor(paused);
}

bool NativeSimulationHost::launch_executor(bool paused) {
    // native_daily_inline：不要 worker 线程。日屏障改由调用线程逐日执行
    // （run_inline_day）。这里必须先把状态发布成 RUNNING —— 命令准入
    // （enqueue_batch）、`domain_grant_pending()` 的主线程抑制窗口、报告里的
    // state 都读它；留在 STOPPED 会让内联模式收不到任何命令、也不抑制主线程。
    //
    // 内联只对 ACTIVE 有意义：SHADOW 的定义就是"worker 侧影子对拍"，没有线程
    // 就没有影子可言。请求 inline+SHADOW 是调用方配置错误，按既有习惯用 fault
    // code 的可观测停止拒绝，而不是把 SHADOW 悄悄升级成 ACTIVE。
    if (inline_daily_mode()) {
        _state.store(RuntimeWorkerState::RUNNING, std::memory_order_release);
        // 与 worker_main 入口对齐：计时区间从这里开始，否则 worker_time_* 恒为 0。
        _worker_timing.pause(paused);
        _worker_timing.start();
        _has_started_once.store(true, std::memory_order_release);
        return true;
    }
    try {
        _worker_returned = std::make_shared<std::atomic<bool>>(false);
        const auto returned = _worker_returned;
        _worker = std::thread([this, returned] {
            worker_main();
            // This final signal owns no host reference and performs no further
            // host access. A caller can now release the world, even on fault.
            returned->store(true, std::memory_order_release);
        });
    } catch (...) {
        _worker_returned->store(true, std::memory_order_release);
        // A failed thread creation must leave the host reusable.  Returning
        // false while keeping STARTING would make every later start look like
        // a forbidden hot switch and would strand the caller without a
        // lifecycle completion signal.
        _worker_fault_count.fetch_add(1, std::memory_order_relaxed);
        const char *fault = "worker_thread_create_failed";
        size_t fault_size = 0;
        for (; fault_size + 1 < _fault_code.size() && fault[fault_size] != '\0';
             ++fault_size) {
            _fault_code[fault_size].store(fault[fault_size],
                                          std::memory_order_relaxed);
        }
        for (; fault_size < _fault_code.size(); ++fault_size)
            _fault_code[fault_size].store('\0', std::memory_order_relaxed);
        _stop_requested.store(true, std::memory_order_release);
        _authority_control.revoke();
        _state.store(RuntimeWorkerState::STOPPED, std::memory_order_release);
        return false;
    }
    _has_started_once.store(true, std::memory_order_release);
    return true;
}

} // namespace pk
