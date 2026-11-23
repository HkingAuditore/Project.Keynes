#pragma once

#include <atomic>
#include <mutex>
#include <utility>

namespace pk {

// Only input producers take the mutex. The executor seals a day with an atomic
// exchange when there is no producer publishing a dated request. It never
// owns the producer mutex while moving commands, planning a day, or saving.
class RuntimeCommandAdmission {
public:
    RuntimeCommandAdmission() = default;
    explicit RuntimeCommandAdmission(bool accepted) : _accepted(accepted) {}
    RuntimeCommandAdmission(std::mutex &producers, std::atomic<int64_t> &seal)
        : _producer(producers), _seal(&seal), _accepted(true) {
        _seal->fetch_or(1, std::memory_order_acq_rel);
    }
    RuntimeCommandAdmission(RuntimeCommandAdmission &&other) noexcept
        : _producer(std::move(other._producer)), _seal(std::exchange(other._seal, nullptr)),
          _accepted(std::exchange(other._accepted, false)) {}
    ~RuntimeCommandAdmission() {
        if (_seal) _seal->fetch_and(~int64_t{1}, std::memory_order_release);
    }
    bool accepted() const noexcept { return _accepted; }

private:
    std::unique_lock<std::mutex> _producer;
    std::atomic<int64_t> *_seal = nullptr;
    bool _accepted = false;
};

} // namespace pk
