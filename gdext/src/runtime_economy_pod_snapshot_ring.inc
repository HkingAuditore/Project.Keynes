bool RuntimeEconomySnapshotRing::try_begin_write(uint32_t &index) {
    for (uint32_t i = 0; i < RUNTIME_SNAPSHOT_RING_SIZE; ++i) {
        uint8_t expected = FREE;
        if (_states[i].compare_exchange_strong(
                expected, WRITING, std::memory_order_acq_rel)) {
            index = i;
            return true;
        }
    }
    for (uint32_t i = 0; i < RUNTIME_SNAPSHOT_RING_SIZE; ++i) {
        uint8_t expected = READY;
        if (_states[i].compare_exchange_strong(
                expected, WRITING, std::memory_order_acq_rel)) {
            index = i;
            _publish_drop_count.fetch_add(1, std::memory_order_relaxed);
            return true;
        }
    }
    return false;
}

void RuntimeEconomySnapshotRing::publish(uint32_t index) {
    if (index >= RUNTIME_SNAPSHOT_RING_SIZE) return;
    _states[index].store(READY, std::memory_order_release);
    _published_index.store(index, std::memory_order_release);
}

bool RuntimeEconomySnapshotRing::try_acquire_latest(uint64_t after_generation,
                                                    uint32_t &index) {
    const uint32_t published =
        _published_index.load(std::memory_order_acquire);
    if (published >= RUNTIME_SNAPSHOT_RING_SIZE) return false;
    uint8_t expected = READY;
    if (!_states[published].compare_exchange_strong(
            expected, READING, std::memory_order_acq_rel)) {
        return false;
    }
    if (_buffers[published].header.generation <= after_generation) {
        _states[published].store(READY, std::memory_order_release);
        return false;
    }
    index = published;
    return true;
}

void RuntimeEconomySnapshotRing::release(uint32_t index) {
    if (index >= RUNTIME_SNAPSHOT_RING_SIZE) return;
    _states[index].store(READY, std::memory_order_release);
}

void RuntimeEconomySnapshotRing::reset() {
    for (auto &state : _states) state.store(FREE, std::memory_order_release);
    _published_index.store(0, std::memory_order_release);
    _publish_drop_count.store(0, std::memory_order_release);
    _buffers = {};
}

bool RuntimeEconomySnapshotRing::self_test() {
    RuntimeEconomySnapshotRing ring;
    uint32_t index = 0;
    if (!ring.try_begin_write(index)) return false;
    ring.write_buffer(index).header.generation = 7;
    ring.write_buffer(index).header.committed = true;
    ring.publish(index);
    uint32_t read_index = 0;
    if (!ring.try_acquire_latest(0, read_index)) return false;
    if (ring.read_buffer(read_index).header.generation != 7) return false;
    ring.release(read_index);
    return true;
}
