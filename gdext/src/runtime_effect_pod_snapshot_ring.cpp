#include "runtime_effect_pod.h"

namespace pk {

RuntimeEffectSnapshotRing::RuntimeEffectSnapshotRing() { reset(); }

void RuntimeEffectSnapshotRing::reset() {
    for (Slot &slot : _slots) {
        slot.snapshot = RuntimeEffectPodSnapshot{};
        slot.state.store(FREE, std::memory_order_relaxed);
    }
    _published_generation.store(0, std::memory_order_relaxed);
    _publish_drop_count.store(0, std::memory_order_relaxed);
}

bool RuntimeEffectSnapshotRing::try_begin_write(uint32_t &index) {
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

void RuntimeEffectSnapshotRing::publish(uint32_t index) {
    if (index >= _slots.size()) return;
    _published_generation.store(_slots[index].snapshot.generation,
                                std::memory_order_relaxed);
    _slots[index].state.store(READY, std::memory_order_release);
}

bool RuntimeEffectSnapshotRing::try_acquire_latest(uint64_t after_generation,
                                                   uint32_t &index) {
    const bool accept_initial =
        after_generation == std::numeric_limits<uint64_t>::max();
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
            std::memory_order_acq_rel, std::memory_order_relaxed)) {
        return false;
    }
    index = best_index;
    return true;
}

void RuntimeEffectSnapshotRing::release(uint32_t index) {
    if (index >= _slots.size()) return;
    _slots[index].state.store(READY, std::memory_order_release);
}

bool RuntimeEffectSnapshotRing::self_test() {
    RuntimeEffectSnapshotRing ring;
    uint32_t slot = 0;
    if (!ring.try_begin_write(slot)) return false;
    ring.write_buffer(slot).generation = 7;
    ring.publish(slot);
    uint32_t acquired = 0;
    if (!ring.try_acquire_latest(0, acquired)) return false;
    if (ring.read_buffer(acquired).generation != 7) return false;
    ring.release(acquired);
    return true;
}

} // namespace pk
