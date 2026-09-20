#pragma once

#include <chrono>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <mutex>

namespace pk {
// Opt-in worker diagnostics; never reads live state from the main thread.
class EconomyCostProbe {
    using Clock = std::chrono::steady_clock;
    struct Output {
        std::mutex mutex;
        FILE *file = nullptr;
        Output() {
            const char *path = std::getenv("PK_ECONOMY_COST_CSV");
            if (path && *path) file = std::fopen(path, "w");
            if (file) std::fprintf(file, "day,phase,work,ms\n");
        }
        ~Output() { if (file) std::fclose(file); }
    };
    static Output &output() { static Output instance; return instance; }
    const char *phase;
    int64_t day;
    uint64_t work;
    bool enabled;
    Clock::time_point begin;
public:
    EconomyCostProbe(const char *name, int64_t sample_day, uint64_t units = 0)
        : phase(name), day(sample_day), work(units), enabled(output().file != nullptr) {
        if (enabled) begin = Clock::now();
    }
    static void record(const char *name, int64_t sample_day, double ms, uint64_t units = 0) {
        auto &out = output();
        if (!out.file) return;
        std::lock_guard<std::mutex> lock(out.mutex);
        std::fprintf(out.file, "%lld,%s,%llu,%.6f\n", static_cast<long long>(sample_day),
            name, static_cast<unsigned long long>(units), ms);
    }
    void set_work(uint64_t value) { work = value; }
    ~EconomyCostProbe() {
        if (!enabled) return;
        const double ms = std::chrono::duration<double, std::milli>(Clock::now() - begin).count();
        auto &out = output();
        std::lock_guard<std::mutex> lock(out.mutex);
        std::fprintf(out.file, "%lld,%s,%llu,%.6f\n", static_cast<long long>(day),
            phase, static_cast<unsigned long long>(work), ms);
    }
};
} // namespace pk
