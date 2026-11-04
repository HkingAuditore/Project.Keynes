#pragma once

#include <atomic>
#include <cstdint>

namespace pk {

// One atomic decision for live grants, graph readiness and lifetime closure.
// A day finishing after stop/fault cannot reopen the closed lifetime. The
// proven mask survives closure and may be granted again by an explicit start.
class RuntimeAuthorityControl {
public:
    struct Snapshot {
        uint32_t granted_mask = 0;
        uint32_t proven_mask = 0;
        bool ready = false;
    };

    Snapshot snapshot() const noexcept {
        const uint64_t state = _state.load(std::memory_order_acquire);
        return {static_cast<uint32_t>(state & MASK),
                static_cast<uint32_t>((state >> PROVEN_SHIFT) & MASK),
                (state & READY) != 0};
    }

    // Lifecycle caller only, after the previous executor has exited.
    void begin_lifetime() noexcept {
        _state.fetch_and(PROVEN, std::memory_order_acq_rel);
    }

    void revoke() noexcept {
        uint64_t observed = _state.load(std::memory_order_acquire);
        while (!_state.compare_exchange_weak(observed,
                (observed & PROVEN) | CLOSED,
                std::memory_order_acq_rel, std::memory_order_acquire)) {}
    }

    bool grant(uint32_t mask) noexcept {
        if (mask == 0 || (static_cast<uint64_t>(mask) & ~MASK) != 0) return false;
        uint64_t observed = _state.load(std::memory_order_acquire);
        while (true) {
            // Completion is still useful restart evidence after stop, but it
            // cannot restore live authority until begin_lifetime is called.
            const bool open = (observed & CLOSED) == 0;
            const uint64_t next = (observed & (READY | CLOSED)) |
                (open ? mask : 0u) |
                (static_cast<uint64_t>(mask) << PROVEN_SHIFT);
            if (_state.compare_exchange_weak(observed, next,
                    std::memory_order_acq_rel, std::memory_order_acquire))
                return open;
        }
    }

    bool mark_graph_ready() noexcept {
        uint64_t observed = _state.load(std::memory_order_acquire);
        while ((observed & CLOSED) == 0) {
            if (_state.compare_exchange_weak(observed, observed | READY,
                    std::memory_order_acq_rel, std::memory_order_acquire))
                return true;
        }
        return false;
    }

private:
    static constexpr uint64_t MASK = 0xffffu;
    static constexpr unsigned PROVEN_SHIFT = 16;
    static constexpr uint64_t PROVEN = MASK << PROVEN_SHIFT;
    static constexpr uint64_t READY = uint64_t{1} << 32;
    static constexpr uint64_t CLOSED = uint64_t{1} << 33;
    std::atomic<uint64_t> _state{CLOSED};
};

} // namespace pk
