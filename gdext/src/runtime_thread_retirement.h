#pragma once

#include <condition_variable>
#include <memory>
#include <mutex>
#include <thread>

namespace pk {

// Joins completed workers off the caller's thread. The cleanup task owns only
// its thread handle and this shared completion state: it never captures the
// simulation host, whose lifetime may end as soon as wait() returns.
class RuntimeThreadRetirement {
    struct Completion {
        std::mutex mutex;
        std::condition_variable changed;
        size_t pending = 0;
    };
    std::shared_ptr<Completion> _completion = std::make_shared<Completion>();

public:
    RuntimeThreadRetirement() = default;
    RuntimeThreadRetirement(const RuntimeThreadRetirement &) = delete;
    RuntimeThreadRetirement &operator=(const RuntimeThreadRetirement &) = delete;
    ~RuntimeThreadRetirement() { wait(); }

    // Caller must first establish that the worker will no longer touch host
    // state. On failure the caller retains ownership of the joinable handle.
    bool retire(std::thread &worker) {
        if (!worker.joinable()) return true;
        std::shared_ptr<std::thread> holder;
        try {
            holder = std::make_shared<std::thread>();
        } catch (...) {
            return false;
        }
        *holder = std::move(worker);
        const auto completion = _completion;
        {
            std::lock_guard<std::mutex> lock(completion->mutex);
            ++completion->pending;
        }
        try {
            std::thread([holder, completion] {
                holder->join();
                std::lock_guard<std::mutex> lock(completion->mutex);
                --completion->pending;
                completion->changed.notify_all();
            }).detach();
        } catch (...) {
            worker = std::move(*holder);
            std::lock_guard<std::mutex> lock(completion->mutex);
            --completion->pending;
            completion->changed.notify_all();
            return false;
        }
        return true;
    }

    void wait() {
        const auto completion = _completion;
        std::unique_lock<std::mutex> lock(completion->mutex);
        completion->changed.wait(lock, [&] { return completion->pending == 0; });
    }
};

} // namespace pk
