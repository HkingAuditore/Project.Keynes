#include "runtime_control_wakeup.h"

#include <atomic>
#include <cassert>
#include <chrono>
#include <future>
#include <iostream>
#include <thread>

int main() {
    using namespace std::chrono_literals;
    for (int iteration = 0; iteration < 32; ++iteration) {
        std::mutex mutex;
        std::condition_variable cv;
        std::atomic<bool> requested{false};
        std::promise<void> predicate_checked, enter_wait, producer_started,
            published, finished;
        auto checked = predicate_checked.get_future();
        auto wait_gate = enter_wait.get_future();
        auto producer = producer_started.get_future();
        auto publication = published.get_future();
        auto completion = finished.get_future();
        std::thread waiter([&] {
            std::unique_lock<std::mutex> lock(mutex);
            bool first = true;
            cv.wait(lock, [&] {
                const bool value = requested.load(std::memory_order_acquire);
                if (first) {
                    first = false;
                    predicate_checked.set_value();
                    wait_gate.wait(); // Hold the exact check-to-wait window open.
                }
                return value;
            });
            finished.set_value();
        });
        checked.wait();
        std::thread sender([&] {
            producer_started.set_value();
            pk::runtime_control_wakeup(mutex, cv, [&] {
                requested.store(true, std::memory_order_release);
                published.set_value();
            });
        });
        producer.wait();
        const bool held_until_wait = publication.wait_for(10ms) == std::future_status::timeout;
        enter_wait.set_value();
        const bool woke_once = completion.wait_for(2s) == std::future_status::ready;
        if (!woke_once) cv.notify_all(); // Only release a failed test's waiter.
        sender.join();
        waiter.join();
        assert(held_until_wait);
        assert(woke_once);
    }
    std::cout << "runtime control wakeup: PASS (32 controlled wait transitions)\n";
}
