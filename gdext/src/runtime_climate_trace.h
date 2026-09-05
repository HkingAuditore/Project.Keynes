#pragma once

#include "runtime_climate_kernel.h"

#include <array>
#include <atomic>
#include <cstdint>
#include <limits>
#include <memory>
#include <string>

namespace pk {

enum class RuntimeClimateTraceState : uint8_t {
    CAPTURED = 0,
    REFERENCE_READY = 1,
    CONSUMABLE = 2,
    CONSUMED = 3,
};

// Immutable data returned to the worker after a successful pop. The ring's
// internal state is atomic; this value intentionally remains a cheap POD-like
// view for existing host code and parity diagnostics.
struct RuntimeClimateReferenceFrame {
    std::shared_ptr<const RuntimeEnvironmentSnapshot> environment;
    uint64_t input_hash = 0;
    uint64_t reference_state_hash = 0;
    uint64_t catalog_hash = 0;
    uint64_t trace_hash = 0;
    RuntimeClimateTraceState state = RuntimeClimateTraceState::CAPTURED;
};

enum class RuntimeClimateTracePopResult : uint8_t {
    EMPTY = 0,
    REFERENCE_PENDING = 1,
    FUTURE_FRAME = 2,
    CONSUMED = 3,
};

// Single-producer (main thread), single-consumer (simulation worker) bounded
// trace. A captured frame remains in the ring until the synchronous reference
// has supplied a matching hash and explicitly released it for consumption.
// No worker path reads the latest live environment as a fallback.
class RuntimeClimateTrace {
public:
    static constexpr uint32_t CAPACITY = 2048u;

    bool push(const RuntimeEnvironmentSnapshot &snapshot) {
        const uint64_t write = _write.load(std::memory_order_relaxed);
        const uint64_t read = _read.load(std::memory_order_acquire);
        if (write - read >= CAPACITY) {
            _capacity_exceeded.fetch_add(1, std::memory_order_relaxed);
            return false;
        }
        Slot &slot = _slots[write % CAPACITY];
        // A slot is reused only after _read has advanced. Consequently the
        // producer owns this shared_ptr assignment exclusively.
        slot.frame = std::make_shared<TraceFrame>();
        slot.frame->environment =
            std::make_shared<const RuntimeEnvironmentSnapshot>(snapshot);
        slot.frame->input_hash = RuntimeClimateKernel::input_hash(snapshot);
        slot.frame->reference_state_hash = 0;
        slot.frame->catalog_hash = snapshot.climate_catalog_hash;
        // The trace identity must cover every captured lane, not just the
        // day/topology tuple. Reusing the canonical input hash makes a
        // malformed or partially-copied frame visible to the parity report
        // without storing a second dynamic payload in the ring.
        slot.frame->trace_hash = RuntimeClimateKernel::input_hash(snapshot);
        slot.frame->state.store(RuntimeClimateTraceState::CAPTURED,
                                std::memory_order_relaxed);
        slot.day.store(snapshot.day, std::memory_order_relaxed);
        slot.generation.store(snapshot.generation, std::memory_order_relaxed);
        _write.store(write + 1u, std::memory_order_release);
        return true;
    }

    bool mark_reference_ready(int64_t day, uint64_t input_hash,
                              uint64_t reference_state_hash,
                              std::string &error) {
        error.clear();
        if (reference_state_hash == 0) {
            error = "climate_trace_reference_hash_invalid";
            _reference_rejected.fetch_add(1, std::memory_order_relaxed);
            return false;
        }
        const uint64_t read = _read.load(std::memory_order_acquire);
        const uint64_t write = _write.load(std::memory_order_acquire);
        for (uint64_t cursor = read; cursor < write; ++cursor) {
            Slot &slot = _slots[cursor % CAPACITY];
            auto frame = slot.frame;
            if (!frame || !frame->environment ||
                frame->environment->day != day) continue;
            if (frame->input_hash != input_hash) {
                error = "climate_trace_input_hash_mismatch";
                _reference_rejected.fetch_add(1, std::memory_order_relaxed);
                return false;
            }
            const RuntimeClimateTraceState observed =
                frame->state.load(std::memory_order_acquire);
            if (observed != RuntimeClimateTraceState::CAPTURED) {
                error = observed == RuntimeClimateTraceState::REFERENCE_READY
                    ? "climate_trace_reference_already_recorded"
                    : "climate_trace_reference_not_captured";
                _reference_rejected.fetch_add(1, std::memory_order_relaxed);
                return false;
            }
            // Publish the reference bytes before opening REFERENCE_READY. A
            // concurrent consumer can therefore never observe CONSUMABLE with
            // an unwritten reference hash.
            frame->reference_state_hash.store(reference_state_hash,
                                               std::memory_order_relaxed);
            RuntimeClimateTraceState expected = RuntimeClimateTraceState::CAPTURED;
            if (!frame->state.compare_exchange_strong(
                    expected, RuntimeClimateTraceState::REFERENCE_READY,
                    std::memory_order_acq_rel, std::memory_order_acquire)) {
                error = expected == RuntimeClimateTraceState::REFERENCE_READY
                    ? "climate_trace_reference_already_recorded"
                    : "climate_trace_reference_not_captured";
                _reference_rejected.fetch_add(1, std::memory_order_relaxed);
                return false;
            }
            return true;
        }
        error = "climate_trace_reference_frame_missing";
        _reference_rejected.fetch_add(1, std::memory_order_relaxed);
        return false;
    }

    bool input_hash_for_day(int64_t day, uint64_t &out_hash) const {
        const uint64_t read = _read.load(std::memory_order_acquire);
        const uint64_t write = _write.load(std::memory_order_acquire);
        for (uint64_t cursor = read; cursor < write; ++cursor) {
            const Slot &slot = _slots[cursor % CAPACITY];
            const auto frame = slot.frame;
            if (frame && frame->environment && frame->environment->day == day) {
                out_hash = frame->input_hash;
                return true;
            }
        }
        out_hash = 0;
        return false;
    }

    bool mark_consumable(int64_t day, std::string &error) {
        error.clear();
        const uint64_t read = _read.load(std::memory_order_acquire);
        const uint64_t write = _write.load(std::memory_order_acquire);
        for (uint64_t cursor = read; cursor < write; ++cursor) {
            Slot &slot = _slots[cursor % CAPACITY];
            auto frame = slot.frame;
            if (!frame || !frame->environment ||
                frame->environment->day != day) continue;
            RuntimeClimateTraceState expected = RuntimeClimateTraceState::REFERENCE_READY;
            if (frame->state.compare_exchange_strong(
                    expected, RuntimeClimateTraceState::CONSUMABLE,
                    std::memory_order_acq_rel, std::memory_order_acquire)) {
                return true;
            }
            error = expected == RuntimeClimateTraceState::CAPTURED
                ? "climate_trace_reference_pending"
                : "climate_trace_reference_not_ready";
            _reference_rejected.fetch_add(1, std::memory_order_relaxed);
            return false;
        }
        error = "climate_trace_reference_frame_missing";
        _reference_rejected.fetch_add(1, std::memory_order_relaxed);
        return false;
    }

    RuntimeClimateTracePopResult pop_for_day(
            int64_t max_day, RuntimeClimateReferenceFrame &out) {
        out = RuntimeClimateReferenceFrame{};
        const uint64_t read = _read.load(std::memory_order_relaxed);
        const uint64_t write = _write.load(std::memory_order_acquire);
        if (read == write) return RuntimeClimateTracePopResult::EMPTY;
        Slot &slot = _slots[read % CAPACITY];
        auto frame = slot.frame;
        if (!frame || !frame->environment)
            return RuntimeClimateTracePopResult::EMPTY;
        if (frame->environment->day > max_day)
            return RuntimeClimateTracePopResult::FUTURE_FRAME;
        if (frame->state.load(std::memory_order_acquire) !=
            RuntimeClimateTraceState::CONSUMABLE) {
            _reference_pending.fetch_add(1, std::memory_order_relaxed);
            return RuntimeClimateTracePopResult::REFERENCE_PENDING;
        }
        out.environment = frame->environment;
        out.input_hash = frame->input_hash;
        out.reference_state_hash = frame->reference_state_hash.load(
            std::memory_order_acquire);
        out.catalog_hash = frame->catalog_hash;
        out.trace_hash = frame->trace_hash;
        out.state = RuntimeClimateTraceState::CONSUMED;
        // Keep slot.frame until the producer reuses the slot after observing
        // _read. This avoids a concurrent shared_ptr reset race with the
        // main-thread reference marker.
        frame->state.store(RuntimeClimateTraceState::CONSUMED,
                           std::memory_order_release);
        _read.store(read + 1u, std::memory_order_release);
        return RuntimeClimateTracePopResult::CONSUMED;
    }

    bool pop_consumable(RuntimeClimateReferenceFrame &out) {
        return pop_for_day(std::numeric_limits<int64_t>::max(), out) ==
            RuntimeClimateTracePopResult::CONSUMED;
    }

    // Compatibility accessor used by existing diagnostics. It only returns a
    // reference-backed frame; there is intentionally no latest-input fallback.
    std::shared_ptr<const RuntimeEnvironmentSnapshot> pop() {
        RuntimeClimateReferenceFrame frame;
        return pop_consumable(frame) ? std::move(frame.environment) : nullptr;
    }

    uint32_t depth() const {
        const uint64_t write = _write.load(std::memory_order_acquire);
        const uint64_t read = _read.load(std::memory_order_acquire);
        return static_cast<uint32_t>(write >= read ? write - read : 0u);
    }
    bool front_day(int64_t &out_day) const {
        const uint64_t read = _read.load(std::memory_order_acquire);
        const uint64_t write = _write.load(std::memory_order_acquire);
        if (read == write) return false;
        const auto frame = _slots[read % CAPACITY].frame;
        if (!frame || !frame->environment) return false;
        out_day = frame->environment->day;
        return true;
    }

    uint32_t state_count(RuntimeClimateTraceState state) const {
        const uint64_t write = _write.load(std::memory_order_acquire);
        const uint64_t read = _read.load(std::memory_order_acquire);
        uint32_t count = 0;
        for (uint64_t cursor = read; cursor < write; ++cursor) {
            const auto frame = _slots[cursor % CAPACITY].frame;
            if (frame != nullptr &&
                frame->state.load(std::memory_order_acquire) == state) {
                ++count;
            }
        }
        return count;
    }

    uint32_t captured_depth() const {
        return state_count(RuntimeClimateTraceState::CAPTURED);
    }
    uint32_t reference_ready_depth() const {
        return state_count(RuntimeClimateTraceState::REFERENCE_READY);
    }
    uint32_t consumable_depth() const {
        return state_count(RuntimeClimateTraceState::CONSUMABLE);
    }
    uint32_t reference_pending_depth() const {
        return captured_depth() + reference_ready_depth();
    }
    uint64_t capacity_exceeded() const {
        return _capacity_exceeded.load(std::memory_order_acquire);
    }
    uint64_t reference_rejected() const {
        return _reference_rejected.load(std::memory_order_acquire);
    }
    uint64_t reference_pending() const {
        return _reference_pending.load(std::memory_order_acquire);
    }

    void reset() {
        // Called only before a worker starts or after it has stopped. Do not
        // reset a slot concurrently with pop_for_day/mark_reference_ready.
        for (auto &slot : _slots) {
            slot.frame.reset();
            slot.day.store(-1, std::memory_order_relaxed);
            slot.generation.store(0, std::memory_order_relaxed);
        }
        _read.store(0, std::memory_order_release);
        _write.store(0, std::memory_order_release);
        _capacity_exceeded.store(0, std::memory_order_release);
        _reference_rejected.store(0, std::memory_order_release);
        _reference_pending.store(0, std::memory_order_release);
    }

    static bool self_test(std::string &error) {
        RuntimeClimateTrace trace;
        RuntimeEnvironmentSnapshot frame;
        frame.generation = 1;
        frame.day = 0;
        frame.cell_count = 1;
        frame.climate_catalog_abi_version = RUNTIME_DOMAIN_POD_ABI_VERSION;
        frame.cell_temp = {1.0f};
        if (!trace.push(frame)) {
            error = "climate_trace_initial_push_failed";
            return false;
        }
        const uint64_t input_hash = RuntimeClimateKernel::input_hash(frame);
        if (trace.mark_consumable(0, error) ||
            error != "climate_trace_reference_pending") {
            error = "climate_trace_capture_barrier_invalid";
            return false;
        }
        if (!trace.mark_reference_ready(0, input_hash, 77, error) ||
            !trace.mark_consumable(0, error)) {
            error = "climate_trace_reference_transition_invalid";
            return false;
        }
        RuntimeClimateReferenceFrame consumed;
        if (!trace.pop_consumable(consumed) || !consumed.environment ||
            consumed.reference_state_hash != 77 || trace.depth() != 0) {
            error = "climate_trace_reference_state_invalid";
            return false;
        }

        RuntimeClimateTrace bounded;
        for (uint32_t i = 0; i < CAPACITY; ++i) {
            frame.day = static_cast<int64_t>(i + 1u);
            frame.generation = i + 2u;
            if (!bounded.push(frame)) {
                error = "climate_trace_capacity_order_invalid";
                return false;
            }
        }
        frame.day = CAPACITY + 1u;
        if (bounded.push(frame) || bounded.capacity_exceeded() != 1u) {
            error = "climate_trace_capacity_not_rejected";
            return false;
        }
        error.clear();
        return true;
    }

private:
    struct TraceFrame {
        std::shared_ptr<const RuntimeEnvironmentSnapshot> environment;
        uint64_t input_hash = 0;
        std::atomic<uint64_t> reference_state_hash{0};
        uint64_t catalog_hash = 0;
        uint64_t trace_hash = 0;
        std::atomic<RuntimeClimateTraceState> state{
            RuntimeClimateTraceState::CAPTURED};
    };

    struct Slot {
        std::shared_ptr<TraceFrame> frame;
        std::atomic<int64_t> day{-1};
        std::atomic<uint64_t> generation{0};
    };

    std::array<Slot, CAPACITY> _slots{};
    std::atomic<uint64_t> _write{0};
    std::atomic<uint64_t> _read{0};
    std::atomic<uint64_t> _capacity_exceeded{0};
    std::atomic<uint64_t> _reference_rejected{0};
    std::atomic<uint64_t> _reference_pending{0};
};

} // namespace pk
