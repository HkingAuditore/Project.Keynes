// The runner extracts the actual inline host methods into this header. Only
// the mutex type is instrumented; request bits and completion code are not
// duplicated here. No Godot runtime or simulation worker is started.
#include <atomic>
#include <condition_variable>
#include <cstdint>
#include <future>
#include <iostream>
#include <mutex>
#include <thread>

enum class ProducerProgress { LockAttempt, Completed };
struct ProgressProbe {
    std::promise<ProducerProgress> promise;
    std::atomic<bool> reported{false};
    void report(ProducerProgress value) {
        if (!reported.exchange(true)) promise.set_value(value);
    }
};
thread_local ProgressProbe *producer_probe = nullptr;

// A lock attempt is reported before taking the underlying real mutex. This
// makes the controlled interleaving observable without a sleep/time threshold.
class ProbeMutex {
public:
    void lock() {
        if (producer_probe) producer_probe->report(ProducerProgress::LockAttempt);
        mutex.lock();
    }
    void unlock() { mutex.unlock(); }
private:
    std::mutex mutex;
};

class ProbeConditionVariable {
public:
    void notify_all() {
        notifications.fetch_add(1);
        cv.notify_all();
    }
    void wait(std::unique_lock<ProbeMutex> &lock) { cv.wait(lock); }
    std::atomic<unsigned> notifications{0};
private:
    std::condition_variable_any cv;
};

#include "runtime_main_boundary_test_subject.h"

bool client_isolation() {
    MainBoundarySubject host;
    using Client = MainBoundarySubject::MainBoundaryClient;
    host.request_main_boundary_service(Client::TRIGGER);
    host.request_main_boundary_service(Client::IDEOLOGY);
    host.complete_main_boundary_service(Client::TRIGGER);
    const auto ideology = MainBoundarySubject::main_boundary_client_bit(Client::IDEOLOGY);
    bool ok = host._main_boundary_service_requested.load() == ideology;
    host.complete_main_boundary_service(Client::TRIGGER);
    ok = ok && host._main_boundary_service_requested.load() == ideology;
    host.complete_main_boundary_service(Client::IDEOLOGY);
    return ok && host._main_boundary_service_requested.load() == 0;
}

bool controlled_transition(MainBoundarySubject::MainBoundaryClient client) {
    MainBoundarySubject host;
    host.request_main_boundary_service(client);
    std::promise<void> checked, enter_wait;
    auto checked_future = checked.get_future();
    auto wait_gate = enter_wait.get_future();
    ProgressProbe probe;
    auto progress = probe.promise.get_future();
    std::atomic<bool> sender_done{false};
    std::thread waiter([&] {
        std::unique_lock<ProbeMutex> lock(host._control_mutex);
        bool first = true;
        while (host._main_boundary_service_requested.load(std::memory_order_acquire) != 0) {
            if (first) {
                first = false;
                checked.set_value();
                wait_gate.wait(); // Hold the already-checked predicate window open.
            }
            host._control_cv.wait(lock);
        }
    });
    checked_future.wait();
    std::thread sender([&] {
        producer_probe = &probe;
        host.complete_main_boundary_service(client);
        sender_done.store(true, std::memory_order_release);
        probe.report(ProducerProgress::Completed);
        producer_probe = nullptr;
    });
    const auto first_progress = progress.get();
    const bool paired = first_progress == ProducerProgress::LockAttempt &&
        host._main_boundary_service_requested.load(std::memory_order_acquire) != 0 &&
        !sender_done.load(std::memory_order_acquire);
    enter_wait.set_value();
    if (!paired) {
        // Negative-test cleanup only. Taking the predicate mutex ensures the
        // waiter has entered wait before this extra notification is sent.
        std::lock_guard<ProbeMutex> cleanup_lock(host._control_mutex);
        host._control_cv.notify_all();
    }
    sender.join();
    waiter.join();
    return paired && sender_done.load() &&
        host._main_boundary_service_requested.load() == 0 &&
        host._control_cv.notifications.load() == 1;
}

int main() {
    using Client = MainBoundarySubject::MainBoundaryClient;
    if (!client_isolation()) {
        std::cerr << "FAIL: completing one client changed another client's bit\n";
        return 1;
    }
    for (int iteration = 0; iteration < 16; ++iteration) {
        for (auto client : {Client::TRIGGER, Client::IDEOLOGY}) {
            if (!controlled_transition(client)) {
                std::cerr << "FAIL: completion crossed the locked check-to-wait window\n";
                return 1;
            }
        }
    }
    std::cout << "main boundary wakeup: PASS (32 controlled transitions; client isolation)\n";
}
