#include "runtime_worker_timing.h"
#include <thread>
#include <chrono>
#include <cassert>
int main() {
    pk::RuntimeWorkerTiming t;
    t.start();
    auto wait = [] { std::this_thread::sleep_for(std::chrono::milliseconds(3)); };
    t.set(pk::RuntimeWorkerTiming::INPUT_WAIT); wait();
    auto a = t.snapshot();
    assert(a[pk::RuntimeWorkerTiming::INPUT_WAIT] > 0);
    t.save(true); wait();
    auto b = t.snapshot();
    assert(b[pk::RuntimeWorkerTiming::SAVE_PAUSE] > 0);
    t.set(pk::RuntimeWorkerTiming::SAVE_BUILD); wait();
    t.set(pk::RuntimeWorkerTiming::EXECUTE); wait();
    t.save(false); t.pause(true);
    t.set(pk::RuntimeWorkerTiming::INPUT_WAIT); wait();
    t.pause(false); t.set(pk::RuntimeWorkerTiming::CLOCK_WAIT); wait();
    t.stop();
    auto c=t.snapshot(); wait(); auto d=t.snapshot();
    assert(c==d);
    for(auto i:{pk::RuntimeWorkerTiming::EXECUTE,pk::RuntimeWorkerTiming::CLOCK_WAIT,
        pk::RuntimeWorkerTiming::SAVE_BUILD,pk::RuntimeWorkerTiming::PAUSED}) assert(c[i]>0);
    t.start();t.stop();assert(t.snapshot()[pk::RuntimeWorkerTiming::SAVE_BUILD]==0);
}
