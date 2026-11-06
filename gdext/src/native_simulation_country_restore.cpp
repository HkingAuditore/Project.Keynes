#include "country_runtime.h"
#include "economy_runtime.h"
#include "economy_authority_transfer.h"

namespace pk {
bool EconomyAuthorityTransfer::restore_country_replica(NativeEconomyRuntime &runtime,
        const std::vector<uint8_t> &bytes, std::string &error) {
    if (bytes.empty()) return true;
    if (runtime._country_runtime == nullptr) {
        error = "country_compatibility_runtime_missing";
        return false;
    }
    return runtime._country_runtime->restore_compatibility_state(bytes, error);
}
} // namespace pk
