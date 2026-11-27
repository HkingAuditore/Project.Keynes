#include "runtime_modifier_pod.h"

namespace pk {

RuntimeModifierSnapshotRing::RuntimeModifierSnapshotRing() { reset(); }

void RuntimeModifierSnapshotRing::reset() {
    for (Slot &slot : _slots) {
        slot.snapshot = RuntimeModifierPodSnapshot{};
        slot.state.store(FREE, std::memory_order_relaxed);
    }
    _published_generation.store(0, std::memory_order_relaxed);
    _publish_drop_count.store(0, std::memory_order_relaxed);
}

bool RuntimeModifierSnapshotRing::try_begin_write(uint32_t &index) {
    for (uint32_t i = 0; i < _slots.size(); ++i) {
        uint8_t expected = FREE;
        if (_slots[i].state.compare_exchange_strong(expected, WRITING,
                std::memory_order_acq_rel, std::memory_order_relaxed)) {
            index = i;
            return true;
        }
    }
    uint64_t oldest_generation = std::numeric_limits<uint64_t>::max();
    uint32_t oldest_index = 0;
    bool ready_found = false;
    for (uint32_t i = 0; i < _slots.size(); ++i) {
        if (_slots[i].state.load(std::memory_order_acquire) != READY) continue;
        const uint64_t generation = _slots[i].snapshot.generation;
        if (!ready_found || generation < oldest_generation) {
            oldest_generation = generation;
            oldest_index = i;
            ready_found = true;
        }
    }
    if (ready_found) {
        uint8_t expected = READY;
        if (_slots[oldest_index].state.compare_exchange_strong(
                expected, WRITING, std::memory_order_acq_rel,
                std::memory_order_relaxed)) {
            index = oldest_index;
            return true;
        }
    }
    _publish_drop_count.fetch_add(1, std::memory_order_relaxed);
    return false;
}

void RuntimeModifierSnapshotRing::publish(uint32_t index) {
    if (index >= _slots.size()) return;
    _published_generation.store(_slots[index].snapshot.generation,
                                std::memory_order_relaxed);
    _slots[index].state.store(READY, std::memory_order_release);
}

bool RuntimeModifierSnapshotRing::try_acquire_latest(uint64_t after_generation,
                                                     uint32_t &index) {
    const bool accept_initial = after_generation == std::numeric_limits<uint64_t>::max();
    uint64_t best = 0;
    uint32_t best_index = 0;
    bool found = false;
    for (uint32_t i = 0; i < _slots.size(); ++i) {
        if (_slots[i].state.load(std::memory_order_acquire) != READY) continue;
        const uint64_t generation = _slots[i].snapshot.generation;
        if ((accept_initial || generation > after_generation) &&
            (!found || generation > best)) {
            best = generation;
            best_index = i;
            found = true;
        }
    }
    if (!found) return false;
    uint8_t expected = READY;
    if (!_slots[best_index].state.compare_exchange_strong(expected, READING,
            std::memory_order_acq_rel, std::memory_order_relaxed)) return false;
    index = best_index;
    return true;
}

bool RuntimeModifierSnapshotRing::try_acquire_generation(uint64_t generation,
                                                         uint32_t &index) {
    if (generation == 0) return false;
    for (uint32_t i = 0; i < _slots.size(); ++i) {
        if (_slots[i].snapshot.generation != generation) continue;
        uint8_t expected = READY;
        if (_slots[i].state.compare_exchange_strong(expected, READING,
                std::memory_order_acq_rel, std::memory_order_relaxed)) {
            index = i;
            return true;
        }
    }
    return false;
}

void RuntimeModifierSnapshotRing::release(uint32_t index) {
    if (index < _slots.size()) _slots[index].state.store(FREE, std::memory_order_release);
}

bool RuntimeModifierSnapshotRing::self_test() {
    RuntimeModifierSnapshotRing ring;
    uint32_t index = 0;
    if (!ring.try_begin_write(index)) return false;
    ring.write_buffer(index).generation = 1;
    ring.publish(index);
    if (!ring.try_acquire_latest(0, index) ||
        ring.read_buffer(index).generation != 1) return false;
    ring.release(index);
    return true;
}

} // namespace pk
