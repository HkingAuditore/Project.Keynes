#include "runtime_thread_retirement.h"

#include <atomic>
#include <cassert>
#include <future>
#include <iostream>

int main() {
    // Destruction must retain every transferred worker, including one which
    // has not returned yet. Completion never needs the owner's mutex or CV.
    for (int iteration = 0; iteration < 256; ++iteration) {
        std::promise<void> release;
        auto ready = release.get_future();
        std::atomic<bool> finished{false};
        auto retirement = std::make_unique<pk::RuntimeThreadRetirement>();
        std::thread worker([&] {
            ready.wait();
            finished.store(true, std::memory_order_release);
        });
        assert(retirement->retire(worker));
        assert(!worker.joinable());
        std::thread destroyer([owner = std::move(retirement), &finished]() mutable {
            owner.reset();
            assert(finished.load(std::memory_order_acquire));
        });
        release.set_value();
        destroyer.join();
    }
    pk::RuntimeThreadRetirement retirement;
    for (int iteration = 0; iteration < 128; ++iteration) {
        std::thread worker([] {});
        assert(retirement.retire(worker));
    }
    retirement.wait();
    std::thread empty;
    assert(retirement.retire(empty));
    std::cout << "runtime thread retirement: PASS (256 destruction races, 128 restarts)\n";
}
