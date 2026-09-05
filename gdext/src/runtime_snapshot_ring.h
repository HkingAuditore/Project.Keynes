#pragma once

#include "runtime_pod_protocol.h"

#include <array>
#include <atomic>
#include <cstdint>

namespace pk {

class RuntimeSnapshotRing {
public:
    RuntimeSnapshotRing();

    // Worker-only. Returns false when all non-reading buffers are occupied.
    bool try_begin_write(uint32_t &index);
    RuntimeCommit &write_buffer(uint32_t index) { return _buffers[index]; }
    void publish(uint32_t index);

    // Main-thread-only. This never waits. The newest READY buffer wins.
    bool try_acquire_latest(uint64_t after_generation, uint32_t &index);
    // Main-thread-only exact lookup.  Older generations may already have been
    // discarded when the worker has published newer visual state.
    bool try_acquire_generation(uint64_t generation, uint32_t &index);
    const RuntimeCommit &read_buffer(uint32_t index) const { return _buffers[index]; }
    void release(uint32_t index);

    // Small deterministic contract test used by the headless runtime smoke
    // suite. It exercises state transitions without touching Godot types.
    static bool self_test();

    // Called only after the worker has stopped and no reader is active.
    void reset();

    uint64_t publish_drop_count() const {
        return _publish_drop_count.load(std::memory_order_relaxed);
    }

private:
    enum BufferState : uint8_t { FREE = 0, WRITING = 1, READY = 2, READING = 3 };

    std::array<RuntimeCommit, RUNTIME_SNAPSHOT_RING_SIZE> _buffers;
    std::array<std::atomic<uint8_t>, RUNTIME_SNAPSHOT_RING_SIZE> _states;
    std::atomic<uint32_t> _published_index{0};
    std::atomic<uint64_t> _publish_drop_count{0};
};

} // namespace pk
