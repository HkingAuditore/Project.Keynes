#include <cassert>
#include "runtime_events_authority.h"
#include "economy_cost_probe.h"
#include "runtime_switch_registry.h"
#include <algorithm>
#include <cstdlib>
#include <cstring>
#include <limits>
#include <type_traits>

namespace pk {

RuntimeEventsSnapshotRing::RuntimeEventsSnapshotRing() { reset(); }

bool RuntimeEventsSnapshotRing::try_begin_write(uint32_t &index) {
    std::lock_guard<std::mutex> lock(_mutex);
    uint32_t candidate = _slots.size();
    for (uint32_t i = 0; i < _slots.size(); ++i) {
        const Slot &slot = _slots[i];
        if (slot.state == State::free) {
            candidate = i;
            break;
        }
        if (slot.state == State::published && slot.readers == 0 && i != _latest &&
                (candidate == _slots.size() || slot.snapshot.generation < _slots[candidate].snapshot.generation)) {
            candidate = i;
        }
    }
    if (candidate == _slots.size()) {
        _publish_drop_count.fetch_add(1, std::memory_order_relaxed);
        return false;
    }
    Slot &slot = _slots[candidate];
    if (slot.state == State::published && !slot.observed) {
        _publish_drop_count.fetch_add(1, std::memory_order_relaxed);
    }
    slot.state = State::writing;
    slot.observed = false;
    index = candidate;
    return true;
}

void RuntimeEventsSnapshotRing::publish(uint32_t index) {
    std::lock_guard<std::mutex> lock(_mutex);
    if (index >= _slots.size() || _slots[index].state != State::writing) return;
    if (_latest < _slots.size()) {
        Slot &old = _slots[_latest];
        if (old.readers == 0 && old.observed) old.state = State::free;
    }
    _slots[index].state = State::published;
    _latest = index;
}

bool RuntimeEventsSnapshotRing::try_acquire_latest(uint64_t after_generation,
                                                   uint32_t &index) {
    std::lock_guard<std::mutex> lock(_mutex);
    if (_latest >= _slots.size()) return false;
    Slot &slot = _slots[_latest];
    if (slot.snapshot.generation <= after_generation) return false;
    ++slot.readers;
    slot.observed = true;
    index = _latest;
    return true;
}

void RuntimeEventsSnapshotRing::release(uint32_t index) {
    std::lock_guard<std::mutex> lock(_mutex);
    if (index >= _slots.size() || _slots[index].readers == 0) return;
    Slot &slot = _slots[index];
    if (--slot.readers == 0 && index != _latest) slot.state = State::free;
}

void RuntimeEventsSnapshotRing::reset() {
    std::lock_guard<std::mutex> lock(_mutex);
    for (Slot &slot : _slots) slot = Slot{};
    _latest = _slots.size();
    _publish_drop_count.store(0, std::memory_order_relaxed);
}

bool RuntimeEventsSnapshotRing::self_test() {
    RuntimeEventsSnapshotRing ring;
    uint32_t slot = 0;
    if (!ring.try_begin_write(slot)) return false;
    ring.write_buffer(slot).generation = 3;
    ring.publish(slot);
    uint32_t read = 0;
    if (!ring.try_acquire_latest(2, read) || ring.read_buffer(read).generation != 3) return false;
    uint32_t other = 0;
    if (!ring.try_acquire_latest(0, other) || ring.read_buffer(other).generation != 3) return false;
    ring.release(other);
    ring.release(read);
    if (!ring.try_acquire_latest(0, read) || ring.try_acquire_latest(3, other)) return false;
    if (!ring.try_begin_write(slot)) return false;
    ring.write_buffer(slot).generation = 4;
    ring.publish(slot);
    if (ring.read_buffer(read).generation != 3 || !ring.try_acquire_latest(3, other)) return false;
    ring.release(read);
    ring.release(other);
    return ring.publish_drop_count() == 0 && !ring.try_acquire_latest(4, read);
}

} // namespace pk
