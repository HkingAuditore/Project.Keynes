#pragma once

#include <chrono>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <map>
#include <mutex>
#include <string>

namespace pk {
// Opt-in worker diagnostics; never reads live state from the main thread.
//
// Default mode aggregates every (day, phase) pair into one CSV row per thread
// (work = summed units, ms = summed wall time). Each thread keeps its own
// bucket map and flushes it when it observes a new day, so the hot path never
// touches the global mutex. Parallel stages therefore report real wall time
// instead of serializing on the probe lock (the previous global aggregation
// inflated every parallel phase by 3-4x). Multiple threads may emit rows for
// the same (day, phase); analyzers sum them. The final day of a thread is not
// flushed at exit (process teardown may destroy the file first); fixtures
// always run a warmup period, so measured days are complete.
// Set PK_ECONOMY_COST_CSV_FULL=1 for per-sample rows when investigating a
// single call site; never use FULL rows for throughput evidence.
class EconomyCostProbe {
    using Clock = std::chrono::steady_clock;
    struct Bucket {
        uint64_t work = 0;
        double ms = 0.0;
    };
    struct Output {
        std::mutex mutex;
        FILE *file = nullptr;
        bool full = false;
        Output() {
            const char *path = std::getenv("PK_ECONOMY_COST_CSV");
            if (path && *path) {
                file = std::fopen(path, "w");
                const char *full_env = std::getenv("PK_ECONOMY_COST_CSV_FULL");
                full = full_env && std::string(full_env) == "1";
            }
            if (file) std::fprintf(file, "day,phase,work,ms\n");
        }
        ~Output() {
            if (file) std::fclose(file);
            file = nullptr;
        }
        void write_day_locked(const char *name, int64_t day, const Bucket &bucket) {
            if (!file) return;
            std::fprintf(file, "%lld,%s,%llu,%.6f\n",
                static_cast<long long>(day), name,
                static_cast<unsigned long long>(bucket.work), bucket.ms);
        }
        void flush_thread_buckets(
                int64_t day,
                std::map<std::string, Bucket, std::less<>> &buckets) {
            if (!file || buckets.empty()) return;
            std::lock_guard<std::mutex> lock(mutex);
            for (const auto &entry : buckets)
                write_day_locked(entry.first.c_str(), day, entry.second);
            buckets.clear();
        }
        void write_locked(const char *name, int64_t day, double ms, uint64_t units) {
            if (!file) return;
            std::fprintf(file, "%lld,%s,%llu,%.6f\n", static_cast<long long>(day),
                name, static_cast<unsigned long long>(units), ms);
        }
    };
    struct ThreadBuckets {
        int64_t day = -9223372036854775807LL;
        // Transparent comparator lets lookups use the literal phase name without
        // constructing a temporary std::string on every sample.
        std::map<std::string, Bucket, std::less<>> buckets;
    };
    static Output &output() {
        static Output instance;
        return instance;
    }
    static ThreadBuckets &thread_buckets() {
        static thread_local ThreadBuckets instance;
        return instance;
    }
    const char *phase;
    int64_t day;
    uint64_t work;
    bool enabled;
    bool full;
    Clock::time_point begin;

public:
    EconomyCostProbe(const char *name, int64_t sample_day, uint64_t units = 0)
        : phase(name), day(sample_day), work(units), enabled(false), full(false) {
        Output &out = output();
        if (out.file != nullptr) {
            enabled = true;
            full = out.full;
            if (!full) begin = Clock::now();
        }
    }
    static void record(const char *name, int64_t sample_day, double ms,
                       uint64_t units = 0) {
        Output &out = output();
        if (!out.file) return;
        if (out.full) {
            std::lock_guard<std::mutex> lock(out.mutex);
            out.write_locked(name, sample_day, ms, units);
            return;
        }
        ThreadBuckets &tb = thread_buckets();
        if (tb.day != sample_day) {
            out.flush_thread_buckets(tb.day, tb.buckets);
            tb.day = sample_day;
        }
        auto found = tb.buckets.find(name);
        if (found == tb.buckets.end())
            found = tb.buckets.emplace(name, Bucket{}).first;
        found->second.work += units;
        found->second.ms += ms;
    }
    void set_work(uint64_t value) { work = value; }
    ~EconomyCostProbe() {
        if (!enabled) return;
        Output &out = output();
        const double ms = std::chrono::duration<double, std::milli>(
            Clock::now() - begin).count();
        if (full) {
            std::lock_guard<std::mutex> lock(out.mutex);
            out.write_locked(phase, day, ms, work);
            return;
        }
        record(phase, day, ms, work);
    }
};
} // namespace pk
