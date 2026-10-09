#pragma once
#include "economy_change_registry.h"
#include <memory>
#include <thread>

namespace pk {
// A row reference may be copied, but all copies retain the same write lease.
// Scalars are compared once when the last reference dies, preserving their
// original C++ arithmetic and lvalue semantics without an untracked escape.
class EconomyRowWriteLease {
public:
    EconomyWorkerChanges *sink() const noexcept { return _sink; }
    using Finish = void (*)(void *, size_t, uint64_t, EconomyWorkerChanges *);
private:
    struct Entry { void *column; size_t index; uint64_t before; Finish finish; };
    std::array<Entry, 128> _entries{};
    size_t _count = 0;
    EconomyWorkerChanges *_sink = nullptr;
    struct Pool {
        std::vector<EconomyRowWriteLease *> free;
        ~Pool() { for (auto *lease : free) delete lease; }
    };
    static Pool &pool() { thread_local Pool value; return value; }
    void finish() {
        for (size_t index = 0; index < _count; ++index) {
            const auto &entry = _entries[index];
            entry.finish(entry.column, entry.index, entry.before, _sink);
        }
        _count = 0; _sink = nullptr;
    }
public:
    static std::shared_ptr<EconomyRowWriteLease> create(EconomyWorkerChanges *sink = nullptr) {
        auto &cache = pool();
        auto *lease = cache.free.empty() ? new EconomyRowWriteLease : cache.free.back();
        if (!cache.free.empty()) cache.free.pop_back();
        lease->_count = 0; lease->_sink = sink;
        const auto thread = std::this_thread::get_id();
        return std::shared_ptr<EconomyRowWriteLease>(lease, [thread](EconomyRowWriteLease *value) {
            value->finish();
            if (std::this_thread::get_id() == thread && pool().free.size() < 128)
                pool().free.push_back(value);
            else delete value;
        });
    }
    void add(void *column, size_t index, uint64_t before, Finish finish) {
        if (_count == _entries.size()) throw std::logic_error("economy_row_lease_capacity_exceeded");
        _entries[_count++] = {column, index, before, finish};
    }
};
} // namespace pk
