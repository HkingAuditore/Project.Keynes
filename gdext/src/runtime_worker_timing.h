#pragma once
#include <array>
#include <chrono>
#include <cstdint>
#include <mutex>

namespace pk {
// 独立诊断锁，不访问公式状态；当前未结束区间也进入报告。
class RuntimeWorkerTiming {
public:
    enum Phase { EXECUTE, INPUT_WAIT, CLOCK_WAIT, SAVE_BUILD, SAVE_PAUSE,
                 PAUSED, OVERHEAD, BOUNDARY_WAIT, ENVIRONMENT_WAIT,
                 MAIN_TAIL_WAIT, INPUT_RETRY_WAIT, COUNT };
    using Totals = std::array<uint64_t, COUNT>;
    enum MainWaitReason { ENVIRONMENT_INPUT, DAY_TAIL, DAY_TAIL_TASK_SLOT,
                          OTHER, MAIN_WAIT_REASON_COUNT };
    enum DayTailTask { SEASON, DAY_TAIL_TASK_COUNT };
    struct MainWaitCounter {
        uint64_t count = 0;
        uint64_t usec = 0;
    };
    struct MainWaitDay {
        int64_t day = -1;
        std::array<MainWaitCounter, MAIN_WAIT_REASON_COUNT> reasons{};
        std::array<MainWaitCounter, DAY_TAIL_TASK_COUNT> tasks{};
    };
    using MainWaitDays = std::array<MainWaitDay, 64>;

    void start() {
        std::lock_guard<std::mutex> lock(mutex);
        totals = {};
        main_wait_days = {};
        main_wait_day = -1;
        phase = OVERHEAD;
        active = true;
        last = Clock::now();
    }
    void stop() {
        std::lock_guard<std::mutex> lock(mutex);
        finish_main_wait_locked(DAY_TAIL_TASK_COUNT);
        settle();
        active = false;
    }
    void set(Phase next) { std::lock_guard<std::mutex> lock(mutex); settle(); phase = next; }
    void save(bool value) { std::lock_guard<std::mutex> lock(mutex); settle(); saving = value; }
    void pause(bool value) { std::lock_guard<std::mutex> lock(mutex); settle(); paused = value; }
    Totals snapshot() const {
        std::lock_guard<std::mutex> lock(mutex);
        auto out = totals;
        if (active) out[bucket()] += elapsed(Clock::now());
        return out;
    }

    // Called only when the existing wait predicate fails. Unrelated wakeups
    // leave an episode open. A tail wait woken by a posted task is attributed
    // to the task slot; the final wait for the main thread's ACK stays DAY_TAIL.
    void observe_main_wait(int64_t day, MainWaitReason reason) {
        std::lock_guard<std::mutex> lock(mutex);
        if (main_wait_day == day && main_wait_reason == reason) return;
        finish_main_wait_locked(DAY_TAIL_TASK_COUNT);
        main_wait_day = day;
        main_wait_reason = reason;
        main_wait_started = Clock::now();
    }
    void finish_main_wait(DayTailTask task = DAY_TAIL_TASK_COUNT) {
        std::lock_guard<std::mutex> lock(mutex);
        finish_main_wait_locked(task);
    }
    MainWaitDays main_wait_snapshot() const {
        std::lock_guard<std::mutex> lock(mutex);
        MainWaitDays out = main_wait_days;
        if (main_wait_day >= 0) add_main_wait(out, main_wait_reason);
        return out;
    }

private:
    using Clock = std::chrono::steady_clock;
    mutable std::mutex mutex;
    Totals totals{};
    Phase phase = OVERHEAD;
    bool active = false, saving = false, paused = false;
    Clock::time_point last{};
    MainWaitDays main_wait_days{};
    int64_t main_wait_day = -1;
    MainWaitReason main_wait_reason = OTHER;
    Clock::time_point main_wait_started{};

    void add_main_wait(MainWaitDays &days, MainWaitReason reason,
                       DayTailTask task = DAY_TAIL_TASK_COUNT) const {
        MainWaitDay &entry = days[static_cast<size_t>(main_wait_day) % days.size()];
        if (entry.day != main_wait_day) {
            entry = {};
            entry.day = main_wait_day;
        }
        const auto usec = static_cast<uint64_t>(std::chrono::duration_cast<
            std::chrono::microseconds>(Clock::now() - main_wait_started).count());
        ++entry.reasons[reason].count;
        entry.reasons[reason].usec += usec;
        if (task != DAY_TAIL_TASK_COUNT) {
            ++entry.tasks[task].count;
            entry.tasks[task].usec += usec;
        }
    }
    void finish_main_wait_locked(DayTailTask task) {
        if (main_wait_day < 0) return;
        if (task != DAY_TAIL_TASK_COUNT && main_wait_reason == DAY_TAIL)
            add_main_wait(main_wait_days, DAY_TAIL_TASK_SLOT, task);
        else
            add_main_wait(main_wait_days, main_wait_reason);
        main_wait_day = -1;
    }
    Phase bucket() const {
        if (phase == INPUT_WAIT || phase == CLOCK_WAIT || phase == ENVIRONMENT_WAIT ||
                phase == MAIN_TAIL_WAIT || phase == INPUT_RETRY_WAIT) {
            if (saving) return SAVE_PAUSE;
            if (paused) return PAUSED;
        }
        return phase;
    }
    uint64_t elapsed(Clock::time_point now) const {
        return static_cast<uint64_t>(std::chrono::duration_cast<std::chrono::microseconds>(now-last).count());
    }
    void settle() { const auto now = Clock::now(); if (active) totals[bucket()] += elapsed(now); last = now; }
};
} // namespace pk
