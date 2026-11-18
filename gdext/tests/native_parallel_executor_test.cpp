#include "native_parallel_executor.h"

#include <array>
#include <atomic>
#include <cstdio>
#include <thread>

namespace {
struct Batch {
    std::thread::id caller;
    bool caller_ran_first = false;
    std::array<std::atomic<unsigned>, 17> visits{};
};

bool run_batches() {
    auto &pool = pk::NativeParallelExecutor::instance();
    for (unsigned round = 0; round < 1500; ++round) {
        Batch batch{};
        batch.caller = std::this_thread::get_id();
        const unsigned count = 1 + round % batch.visits.size();
        pool.run_group(count, [](void *data, uint32_t index) {
            auto &b = *static_cast<Batch *>(data);
            if (index == 0) b.caller_ran_first = std::this_thread::get_id() == b.caller;
            if (index % 3 == 0) std::this_thread::yield();
            ++b.visits.at(index);
        }, &batch);
        if (!batch.caller_ran_first) return false;
        for (unsigned i = 0; i < batch.visits.size(); ++i)
            if (batch.visits[i] != (i < count ? 1u : 0u)) return false;
    }
    return true;
}
}

int main() {
    for (bool serial : {false, true}) {
        pk::set_parallel_serial_only(serial);
        bool other_ok = false;
        std::thread other([&] { other_ok = run_batches(); });
        bool ok = run_batches();
        other.join();
        if (!ok || !other_ok) return 1;
    }
    std::puts("native_parallel_executor_test PASS");
}
