#include "gdext/src/runtime_protocol_guard.h"
#include "gdext/src/runtime_authoritative_domains.h"
#include "gdext/src/runtime_climate_authority.h"
#include "gdext/src/runtime_climate_trace.h"
#include "gdext/src/runtime_domain_pod.h"
#include "gdext/src/runtime_snapshot_ring.h"

#include <iostream>
#include <string>

int main() {
    std::string error;
    if (!pk::RuntimeProtocolGuard::self_test(error)) {
        std::cerr << "protocol: " << error << "\n";
        return 1;
    }
    if (!pk::RuntimeAuthoritativeDomainStores::self_test(error)) {
        std::cerr << "stores: " << error << "\n";
        return 2;
    }
    if (!pk::RuntimeDomainPodPipeline::self_test(error)) {
        std::cerr << "pipeline: " << error << "\n";
        return 3;
    }
    if (!pk::RuntimeClimateAuthority::self_test(error)) {
        std::cerr << "climate: " << error << "\n";
        return 4;
    }
    if (!pk::RuntimeClimateTrace::self_test(error)) {
        std::cerr << "trace: " << error << "\n";
        return 5;
    }
    if (!pk::RuntimeSnapshotRing::self_test()) {
        std::cerr << "snapshot_ring\n";
        return 6;
    }
    std::cout << "runtime POD self-tests: PASS\n";
    return 0;
}
