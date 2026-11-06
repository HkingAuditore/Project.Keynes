#pragma once

#include "runtime_pod_protocol.h"
#include <atomic>
#include <cstdio>
#include <cstdlib>
#include <cstring>

namespace pk {
class NativeSimulationHost;
class NativeEconomyRuntime;
std::FILE *sim_day_trace_file();
void sim_trace_environment_fields(std::FILE *, const RuntimeEnvironmentSnapshot &);
void open_granted_economy_d7_gates(const NativeSimulationHost &, NativeEconomyRuntime &) noexcept;
RuntimeCommandPacket make_effect_intent_events_packet(const RuntimeDomainIntent &, int64_t);
bool d7_read_u32(const uint8_t *, size_t, size_t &, uint32_t &);
bool d7_read_u64(const uint8_t *, size_t, size_t &, uint64_t &);
bool d7_read_i32(const uint8_t *, size_t, size_t &, int32_t &);
bool d7_read_i64(const uint8_t *, size_t, size_t &, int64_t &);

// The trace file is shared by the worker and the main thread; multi-call
// records must hold the stream lock or lines interleave mid-record.
struct SimTraceLock {
    std::FILE *file;
    explicit SimTraceLock(std::FILE *f) : file(f) {
#if defined(_WIN32)
        _lock_file(file);
#else
        flockfile(file);
#endif
    }
    ~SimTraceLock() {
#if defined(_WIN32)
        _unlock_file(file);
#else
        funlockfile(file);
#endif
    }
};

template <typename Column>
uint64_t sim_trace_vector_hash(const Column &values) {
    uint64_t hash = 1469598103934665603ull;
    const size_t count = static_cast<size_t>(values.size());
    for (size_t i = 0; i < count; ++i) {
        const auto value = values[i];
        const auto *bytes = reinterpret_cast<const uint8_t *>(&value);
        for (size_t b = 0; b < sizeof(value); ++b)
            hash = (hash ^ bytes[b]) * 1099511628211ull;
    }
    return hash ^ count;
}

// Scope helper for the two authority-boundary counters below.  The worker
// never exposes a partially executed day as an epoch boundary; the counters
// make that fact available to a concurrent switch request without taking a
// mutex in the hot path.
class AtomicCounterScope {
public:
    explicit AtomicCounterScope(std::atomic<uint32_t> &counter) noexcept
        : _counter(counter) {
        _counter.fetch_add(1u, std::memory_order_acq_rel);
    }
    AtomicCounterScope(const AtomicCounterScope &) = delete;
    AtomicCounterScope &operator=(const AtomicCounterScope &) = delete;
    ~AtomicCounterScope() {
        _counter.fetch_sub(1u, std::memory_order_release);
    }

private:
    std::atomic<uint32_t> &_counter;
};
} // namespace pk
