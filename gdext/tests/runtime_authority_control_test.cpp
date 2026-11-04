#include "runtime_authority_control.h"

#include <atomic>
#include <cassert>
#include <iostream>
#include <thread>

int main() {
    constexpr uint32_t climate = 2u;
    constexpr uint32_t all = 0xfffu;
    pk::RuntimeAuthorityControl control;
    assert(!control.grant(climate));
    assert(control.snapshot().granted_mask == 0u);
    control.begin_lifetime();
    assert(control.grant(climate));
    assert(!control.snapshot().ready);
    assert(control.mark_graph_ready());
    control.revoke();
    assert(!control.snapshot().ready);
    assert(control.snapshot().granted_mask == 0u);
    assert(control.snapshot().proven_mask == climate);
    // An outstanding commit is restart evidence, never permission to restart.
    assert(!control.grant(all));
    assert(!control.mark_graph_ready());
    assert(control.snapshot().proven_mask == all);
    assert(control.snapshot().granted_mask == 0u);
    control.begin_lifetime();
    assert(control.grant(control.snapshot().proven_mask));
    assert(control.snapshot().granted_mask == all);

    // Race the exact day-tail order against stop. Whichever side wins first,
    // once both return the lifetime must remain closed and retain its proof.
    for (int iteration = 0; iteration < 256; ++iteration) {
        control.begin_lifetime();
        std::atomic<bool> go{false};
        std::thread publisher([&] {
            while (!go.load(std::memory_order_acquire)) std::this_thread::yield();
            control.mark_graph_ready();
            control.grant(all);
        });
        go.store(true, std::memory_order_release);
        control.revoke();
        publisher.join();
        const auto stopped = control.snapshot();
        assert(stopped.granted_mask == 0u && !stopped.ready);
        assert(stopped.proven_mask == all);
        assert(!control.grant(all) && !control.mark_graph_ready());
    }
    std::cout << "runtime authority control: PASS (256 stop/commit races)\n";
}
