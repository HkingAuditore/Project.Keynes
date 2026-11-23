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

    using Timing = pk::RuntimeWorkerTiming;
    t.start();
    for (auto phase : {Timing::ENVIRONMENT_WAIT, Timing::INPUT_RETRY_WAIT}) {
        t.set(phase);
        wait();
        assert(t.snapshot()[phase] > 0);
    }
    // snapshot() adds the open interval without settling it, so a snapshot taken
    // before pause(true) can be a microsecond short of what pause() settles.
    // Compare against the state right after the pause has settled.
    t.pause(true);
    const auto before_pause = t.snapshot();
    t.set(Timing::INPUT_RETRY_WAIT);
    wait();
    const auto while_paused = t.snapshot();
    assert(while_paused[Timing::INPUT_RETRY_WAIT] == before_pause[Timing::INPUT_RETRY_WAIT]);
    assert(while_paused[Timing::PAUSED] > 0);
    t.save(true);
    wait();
    const auto while_saving = t.snapshot();
    assert(while_saving[Timing::SAVE_PAUSE] > 0);
    t.stop();
}
