#include "runtime_snapshot_ring.h"

namespace pk {

RuntimeSnapshotRing::RuntimeSnapshotRing() {
    for (auto &state : _states) state.store(FREE, std::memory_order_relaxed);
    // The worker may publish a command burst at any day boundary. Reserve the
    // protocol maximum up front so publishing a READY buffer never performs a
    // vector allocation while the simulation thread is catching up.
    for (auto &buffer : _buffers) {
        buffer.visual_intents.reserve(RUNTIME_COMMAND_QUEUE_CAPACITY);
        buffer.receipts.reserve(RUNTIME_RECEIPT_QUEUE_CAPACITY);
    }
}

bool RuntimeSnapshotRing::try_begin_write(uint32_t &index) {
    for (uint32_t i = 0; i < RUNTIME_SNAPSHOT_RING_SIZE; ++i) {
        uint8_t expected = FREE;
        if (_states[i].compare_exchange_strong(expected, WRITING,
                std::memory_order_acquire, std::memory_order_relaxed)) {
            index = i;
            return true;
        }
    }
    _publish_drop_count.fetch_add(1, std::memory_order_relaxed);
    return false;
}

void RuntimeSnapshotRing::publish(uint32_t index) {
    if (index >= RUNTIME_SNAPSHOT_RING_SIZE) return;
    _states[index].store(READY, std::memory_order_release);
    const uint32_t previous = _published_index.exchange(index, std::memory_order_acq_rel);
    if (previous != index && previous < RUNTIME_SNAPSHOT_RING_SIZE) {
        uint8_t expected = READY;
        _states[previous].compare_exchange_strong(expected, FREE,
                std::memory_order_acq_rel, std::memory_order_relaxed);
    }
}

bool RuntimeSnapshotRing::try_acquire_latest(uint64_t after_generation, uint32_t &index) {
    const uint32_t candidate = _published_index.load(std::memory_order_acquire);
    if (candidate >= RUNTIME_SNAPSHOT_RING_SIZE) return false;
    uint8_t expected = READY;
    if (!_states[candidate].compare_exchange_strong(expected, READING,
            std::memory_order_acq_rel, std::memory_order_relaxed)) {
        return false;
    }
    // Claim the buffer before reading its header. Otherwise publish() can
    // recycle READY -> FREE -> WRITING between the old state load and the
    // generation read, creating a real data race with the worker.
    if (_buffers[candidate].header.generation <= after_generation) {
        _states[candidate].store(FREE, std::memory_order_release);
        return false;
    }
    index = candidate;
    return true;
}

bool RuntimeSnapshotRing::try_acquire_generation(uint64_t generation, uint32_t &index) {
    if (generation == 0) return false;
    for (uint32_t i = 0; i < RUNTIME_SNAPSHOT_RING_SIZE; ++i) {
        uint8_t expected = READY;
        if (_states[i].compare_exchange_strong(expected, READING,
                std::memory_order_acq_rel, std::memory_order_relaxed)) {
            if (_buffers[i].header.generation != generation) {
                _states[i].store(FREE, std::memory_order_release);
                continue;
            }
            index = i;
            return true;
        }
    }
    return false;
}

void RuntimeSnapshotRing::release(uint32_t index) {
    if (index >= RUNTIME_SNAPSHOT_RING_SIZE) return;
    uint8_t expected = READING;
    _states[index].compare_exchange_strong(expected, FREE,
        std::memory_order_release, std::memory_order_relaxed);
}

bool RuntimeSnapshotRing::self_test() {
    RuntimeSnapshotRing ring;
    auto publish_generation = [&ring](uint64_t generation) {
        uint32_t index = 0;
        if (!ring.try_begin_write(index)) return false;
        ring.write_buffer(index).header.generation = generation;
        ring.publish(index);
        return true;
    };

    if (!publish_generation(1)) return false;
    uint32_t read_a = 0;
    if (!ring.try_acquire_latest(0, read_a)) return false;
    if (!publish_generation(2)) return false;
    uint32_t read_b = 0;
    if (!ring.try_acquire_generation(2, read_b)) return false;
    if (!publish_generation(3)) return false;
    uint32_t read_c = 0;
    if (!ring.try_acquire_generation(3, read_c)) return false;
    // All three buffers are being read. The worker must drop the visual
    // publication instead of overwriting any of them.
    uint32_t rejected = 0;
    if (ring.try_begin_write(rejected)) return false;
    if (ring.publish_drop_count() == 0) return false;
    ring.release(read_a);
    ring.release(read_b);
    ring.release(read_c);
    if (!publish_generation(4)) return false;
    uint32_t expired = 0;
    if (ring.try_acquire_generation(1, expired)) return false;
    ring.reset();
    if (ring.try_acquire_latest(0, expired)) return false;
    return ring.try_begin_write(expired);
}

void RuntimeSnapshotRing::reset() {
    _published_index.store(0, std::memory_order_relaxed);
    for (uint32_t i = 0; i < RUNTIME_SNAPSHOT_RING_SIZE; ++i) {
        // Keep the constructor's bounded capacities across world restarts.
        // Assigning a temporary RuntimeCommit here would release the vectors
        // and reintroduce allocator work on the first post-restart publish.
        _buffers[i].header = RuntimeCommitHeader{};
        _buffers[i].visual_intents.clear();
        _buffers[i].receipts.clear();
        _states[i].store(FREE, std::memory_order_relaxed);
    }
    _publish_drop_count.store(0, std::memory_order_relaxed);
}

} // namespace pk
