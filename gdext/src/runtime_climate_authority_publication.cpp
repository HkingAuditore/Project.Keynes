#include "runtime_climate_authority.h"
#include "runtime_switch_registry.h"
#include "runtime_climate_parity.h"
#include "runtime_climate_physics.h"

#include <chrono>
#include <cmath>
#include <cstring>
#include <cstdlib>
#include <limits>

namespace pk {

// ─── RuntimeClimateWritebackRing ──────────────────────────────────────────

RuntimeClimateWritebackRing::RuntimeClimateWritebackRing() {
    for (auto &state : _states) state.store(FREE, std::memory_order_relaxed);
}

bool RuntimeClimateWritebackRing::try_begin_write(uint32_t &index) {
    for (size_t i = 0; i < SLOT_COUNT; ++i) {
        uint8_t expected = FREE;
        if (_states[i].compare_exchange_strong(expected, WRITING,
                std::memory_order_acq_rel, std::memory_order_relaxed)) {
            index = static_cast<uint32_t>(i);
            return true;
        }
    }
    // A READY slot the main thread has not taken yet is recyclable: the newer
    // day supersedes it. Only a slot actively being READ is untouchable.
    for (size_t i = 0; i < SLOT_COUNT; ++i) {
        uint8_t expected = READY;
        if (_states[i].compare_exchange_strong(expected, WRITING,
                std::memory_order_acq_rel, std::memory_order_relaxed)) {
            _publish_drop_count.fetch_add(1, std::memory_order_relaxed);
            index = static_cast<uint32_t>(i);
            return true;
        }
    }
    _publish_drop_count.fetch_add(1, std::memory_order_relaxed);
    return false;
}

void RuntimeClimateWritebackRing::publish(uint32_t index) {
    if (index >= SLOT_COUNT) return;
    _published_generation.store(_buffers[index].generation,
                                std::memory_order_release);
    _states[index].store(READY, std::memory_order_release);
}

bool RuntimeClimateWritebackRing::try_acquire_latest(uint64_t after_generation,
                                                     uint32_t &index) {
    // Pick the newest READY slot strictly newer than the caller's cursor. The
    // scan is over three slots, so there is no reason to keep a hint.
    bool found = false;
    size_t best = 0;
    uint64_t best_generation = 0;
    for (size_t i = 0; i < SLOT_COUNT; ++i) {
        if (_states[i].load(std::memory_order_acquire) != READY) continue;
        const uint64_t generation = _buffers[i].generation;
        if (generation <= after_generation) continue;
        if (!found || generation > best_generation) {
            found = true;
            best = i;
            best_generation = generation;
        }
    }
    if (!found) return false;
    uint8_t expected = READY;
    if (!_states[best].compare_exchange_strong(expected, READING,
            std::memory_order_acq_rel, std::memory_order_relaxed)) {
        // The worker recycled it between the scan and the claim. The caller
        // retries on the next frame against a newer day.
        return false;
    }
    index = static_cast<uint32_t>(best);
    return true;
}

void RuntimeClimateWritebackRing::release(uint32_t index) {
    if (index >= SLOT_COUNT) return;
    _states[index].store(FREE, std::memory_order_release);
}

void RuntimeClimateWritebackRing::reset() {
    for (auto &state : _states) state.store(FREE, std::memory_order_relaxed);
    for (auto &buffer : _buffers) buffer = RuntimeClimateSnapshot{};
    _published_generation.store(0, std::memory_order_relaxed);
    _publish_drop_count.store(0, std::memory_order_relaxed);
}

bool RuntimeClimateWritebackRing::self_test(std::string &error) {
    RuntimeClimateWritebackRing ring;
    uint32_t slot = 0;
    if (ring.try_acquire_latest(0, slot)) {
        error = "climate_writeback_empty_ring_acquired";
        return false;
    }
    if (!ring.try_begin_write(slot)) {
        error = "climate_writeback_first_write_refused";
        return false;
    }
    ring.write_buffer(slot).generation = 1;
    ring.write_buffer(slot).committed_day = 7;
    ring.publish(slot);
    uint32_t read_slot = 0;
    if (!ring.try_acquire_latest(0, read_slot)) {
        error = "climate_writeback_published_not_visible";
        return false;
    }
    if (ring.read_buffer(read_slot).committed_day != 7) {
        error = "climate_writeback_payload_mismatch";
        return false;
    }
    // Re-reading the same generation must not hand out the same day twice.
    uint32_t again = 0;
    if (ring.try_acquire_latest(1, again)) {
        error = "climate_writeback_stale_generation_acquired";
        return false;
    }
    // The worker must keep making progress while that slot is held.
    uint32_t next_write = 0;
    if (!ring.try_begin_write(next_write) || next_write == read_slot) {
        error = "climate_writeback_write_blocked_by_reader";
        return false;
    }
    ring.write_buffer(next_write).generation = 2;
    ring.write_buffer(next_write).committed_day = 8;
    ring.publish(next_write);
    ring.release(read_slot);
    uint32_t newest = 0;
    if (!ring.try_acquire_latest(1, newest) ||
        ring.read_buffer(newest).committed_day != 8) {
        error = "climate_writeback_newest_not_selected";
        return false;
    }
    ring.release(newest);
    return true;
}

// ─── RuntimeEnvironmentInputRing ──────────────────────────────────────────

size_t RuntimeEnvironmentInputRing::size() const {
    std::lock_guard<std::mutex> lock(_mutex);
    return _queue.size();
}

bool RuntimeEnvironmentInputRing::try_push(
        std::shared_ptr<const RuntimeEnvironmentSnapshot> snapshot) {
    if (!snapshot) return false;
    std::lock_guard<std::mutex> lock(_mutex);
    if (_queue.size() >= SLOT_COUNT) return false;
    _queue.push_back(snapshot);
    _latest = std::move(snapshot);
    return true;
}

bool RuntimeEnvironmentInputRing::force_push(
        std::shared_ptr<const RuntimeEnvironmentSnapshot> snapshot,
        bool &dropped) {
    dropped = false;
    if (!snapshot) return false;
    std::lock_guard<std::mutex> lock(_mutex);
    if (_queue.size() >= SLOT_COUNT) {
        _queue.pop_front();
        dropped = true;
    }
    _queue.push_back(snapshot);
    _latest = std::move(snapshot);
    return true;
}

std::shared_ptr<const RuntimeEnvironmentSnapshot>
RuntimeEnvironmentInputRing::peek_oldest() const {
    std::lock_guard<std::mutex> lock(_mutex);
    if (_queue.empty()) return nullptr;
    return _queue.front();
}

std::shared_ptr<const RuntimeEnvironmentSnapshot>
RuntimeEnvironmentInputRing::latest() const {
    std::lock_guard<std::mutex> lock(_mutex);
    return _latest;
}

bool RuntimeEnvironmentInputRing::pop_generation(uint64_t generation) {
    std::lock_guard<std::mutex> lock(_mutex);
    if (_queue.empty() || !_queue.front() ||
        _queue.front()->generation != generation) {
        return false;
    }
    _queue.pop_front();
    return true;
}

size_t RuntimeEnvironmentInputRing::pop_while_day_at_most(int64_t day) {
    std::lock_guard<std::mutex> lock(_mutex);
    size_t popped = 0;
    while (!_queue.empty() && _queue.front() &&
           _queue.front()->day <= day) {
        _queue.pop_front();
        ++popped;
    }
    return popped;
}

void RuntimeEnvironmentInputRing::reset() {
    std::lock_guard<std::mutex> lock(_mutex);
    _queue.clear();
    _latest.reset();
}

bool RuntimeEnvironmentInputRing::self_test(std::string &error) {
    RuntimeEnvironmentInputRing ring;
    if (ring.peek_oldest() != nullptr) {
        error = "environment_ring_empty_peek";
        return false;
    }
    auto make = [](uint64_t generation, int64_t day) {
        auto snap = std::make_shared<RuntimeEnvironmentSnapshot>();
        snap->generation = generation;
        snap->day = day;
        snap->cell_count = 1;
        snap->topology_validated = true;
        return snap;
    };
    if (!ring.try_push(make(1, 10)) || ring.size() != 1) {
        error = "environment_ring_first_push_failed";
        return false;
    }
    for (uint64_t g = 2; g <= RuntimeEnvironmentInputRing::SLOT_COUNT; ++g) {
        if (!ring.try_push(make(g, static_cast<int64_t>(10 + g)))) {
            error = "environment_ring_fill_failed";
            return false;
        }
    }
    if (ring.try_push(make(99, 99))) {
        error = "environment_ring_overfill_accepted";
        return false;
    }
    bool dropped = false;
    if (!ring.force_push(make(100, 100), dropped) || !dropped) {
        error = "environment_ring_force_drop_failed";
        return false;
    }
    auto oldest = ring.peek_oldest();
    if (!oldest || oldest->generation != 2) {
        error = "environment_ring_fifo_order_broken";
        return false;
    }
    if (!ring.pop_generation(2) || ring.peek_oldest()->generation != 3) {
        error = "environment_ring_pop_failed";
        return false;
    }
    if (ring.latest() == nullptr || ring.latest()->generation != 100) {
        error = "environment_ring_latest_broken";
        return false;
    }
    // After force_push the queue holds gens 2..SLOT_COUNT then 100 was a drop of
    // gen1 and push 100 — then we popped 2, so head is 3. Days were 10+g.
    // Pop everything through day 14 (gen 4 has day 14).
    const size_t drained = ring.pop_while_day_at_most(14);
    if (drained == 0) {
        error = "environment_ring_day_drain_empty";
        return false;
    }
    oldest = ring.peek_oldest();
    if (oldest != nullptr && oldest->day <= 14) {
        error = "environment_ring_day_drain_left_old";
        return false;
    }
    return true;
}

} // namespace pk
