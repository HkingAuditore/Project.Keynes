#include "runtime_authority_control.h"
#include "runtime_execution_context.h"

#include <atomic>
#include <cassert>
#include <iostream>
#include <thread>

int main() {
    constexpr uint32_t country = 4u;
    constexpr uint32_t economy = 256u;
    constexpr uint32_t domains = country | economy;
    pk::RuntimeAuthorityControl admission;
    int other_world = 0;
    for (int iteration = 0; iteration < 256; ++iteration) {
        admission.begin_lifetime();
        assert(admission.grant(domains));
        std::atomic<bool> executing{false};
        std::atomic<bool> stopped{false};
        std::thread executor([&] {
            {
                const pk::RuntimeExecutionContext call(&admission, domains);
                assert(pk::RuntimeExecutionContext::active_for(&admission));
                executing.store(true, std::memory_order_release);
                while (!stopped.load(std::memory_order_acquire))
                    std::this_thread::yield();
                // A fiscal transfer must select the same treasury for both
                // debit and credit even when admission closes between them.
                assert(pk::RuntimeExecutionContext::domains_for(&admission, 0) == domains);
                assert(pk::RuntimeExecutionContext::domains_for(&other_world, 0) == 0);
                {
                    const pk::RuntimeExecutionContext nested(&other_world, country);
                    assert(!pk::RuntimeExecutionContext::active_for(&admission));
                    assert(pk::RuntimeExecutionContext::active_for(&other_world));
                    assert(pk::RuntimeExecutionContext::domains_for(&other_world, 0) == country);
                    assert(pk::RuntimeExecutionContext::domains_for(&admission, 0) == 0);
                }
                assert(pk::RuntimeExecutionContext::domains_for(&admission, 0) == domains);
                assert(!admission.grant(domains));
            }
            assert(pk::RuntimeExecutionContext::domains_for(&admission, 0) == 0);
            assert(!pk::RuntimeExecutionContext::active_for(&admission));
        });
        while (!executing.load(std::memory_order_acquire)) std::this_thread::yield();
        admission.revoke();
        assert(admission.snapshot().granted_mask == 0);
        assert(pk::RuntimeExecutionContext::domains_for(&admission, 0) == 0);
        stopped.store(true, std::memory_order_release);
        executor.join();
        assert(admission.snapshot().granted_mask == 0);
    }
    try {
        const pk::RuntimeExecutionContext call(&admission, domains);
        throw 1;
    } catch (int) {}
    assert(pk::RuntimeExecutionContext::domains_for(&admission, 0) == 0);
    std::cout << "runtime execution context: PASS (256 stop/transaction races)\n";
}
