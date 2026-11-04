#include "economy_authority_transfer.h"
#include "economy_runtime.h"

namespace pk {
namespace {
template <typename T> class RestoreValue final {
    T &target;
    T previous;
public:
    RestoreValue(T &value, T replacement) : target(value), previous(value) {
        target = replacement;
    }
    ~RestoreValue() { target = previous; }
    RestoreValue(const RestoreValue &) = delete;
    RestoreValue &operator=(const RestoreValue &) = delete;
};
}

bool EconomyAuthorityTransfer::service_country_requests(NativeEconomyRuntime &runtime,
        uint32_t max_requests, std::string &error) {
    return runtime.service_country_economy_asset_peer(max_requests, error);
}

int64_t EconomyAuthorityTransfer::sample_day(const NativeEconomyRuntime &runtime) noexcept {
    return runtime._sample_day;
}

bool EconomyAuthorityTransfer::capture(NativeEconomyRuntime &runtime,
        RuntimeEconomyEcp2State &out, std::string &error, uint32_t flags,
        const CountryIdentity *country) {
    if (country == nullptr) return runtime.capture_ecp2_authority(out, error, flags);
    RestoreValue<bool> override(runtime._save_country_identity_override, true);
    RestoreValue<uint64_t> generation(runtime._save_country_generation, country->generation);
    RestoreValue<uint64_t> hash(runtime._save_country_state_hash, country->state_hash);
    return runtime.capture_ecp2_authority(out, error, flags);
}

bool EconomyAuthorityTransfer::restore_before_country(NativeEconomyRuntime &runtime,
        const RuntimeEconomyEcp2State &state, std::string &error) {
    RestoreValue<bool> defer(runtime._accept_stale_country_identity, true);
    return runtime.apply_ecp2_authority(state, error);
}

bool EconomyAuthorityTransfer::verify_after_country(const NativeEconomyRuntime &runtime,
        std::string &error) {
    return runtime.verify_deferred_country_identity(error);
}
} // namespace pk
