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
                 PAUSED, OVERHEAD, BOUNDARY_WAIT, COUNT };
    using Totals = std::array<uint64_t, COUNT>;
    void start() { std::lock_guard<std::mutex> lock(mutex); totals = {}; phase = OVERHEAD; active = true; last = Clock::now(); }
    void stop() { std::lock_guard<std::mutex> lock(mutex); settle(); active = false; }
    void set(Phase next) { std::lock_guard<std::mutex> lock(mutex); settle(); phase = next; }
    void save(bool value) { std::lock_guard<std::mutex> lock(mutex); settle(); saving = value; }
    void pause(bool value) { std::lock_guard<std::mutex> lock(mutex); settle(); paused = value; }
    Totals snapshot() const {
        std::lock_guard<std::mutex> lock(mutex);
        auto out = totals;
        if (active) out[bucket()] += elapsed(Clock::now());
        return out;
    }
private:
    using Clock = std::chrono::steady_clock;
    mutable std::mutex mutex;
    Totals totals{};
    Phase phase = OVERHEAD;
    bool active = false, saving = false, paused = false;
    Clock::time_point last{};
    Phase bucket() const {
        if (phase == INPUT_WAIT || phase == CLOCK_WAIT) {
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
