#include "economy_authority_transfer.h"
#include "economy_runtime.h"
#include "runtime_economy_pod.h"

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
    // The session already rebound the regenerated map before executor startup.
    // Applying the same archive again clears that derived graph. Preserve this
    // same-world binding across the owner handoff; a plain archive restore still
    // clears it and must bind its own map explicitly.
    auto topology = runtime._trade_topology;
    const bool restored = runtime.apply_ecp2_authority(state, error);
    runtime._trade_topology = std::move(topology);
    if (restored) runtime._trade_topology.component_country_hash = 0;
    return restored;
}

bool EconomyAuthorityTransfer::verify_after_country(const NativeEconomyRuntime &runtime,
        std::string &error) {
    return runtime.verify_deferred_country_identity(error);
}

bool EconomyAuthorityTransfer::bind_restored_owner(NativeEconomyRuntime &runtime,
        RuntimeEconomyPodAuthority &authority, std::string &error) {
    // Startup only: no executor is running. Future queued commands must not
    // prevent restoring the requested owner of the already committed state.
    if (!runtime.formula_owned_bound()) {
        RuntimeEconomyLedgerState ledger;
        runtime.capture_committed_ledger_state(ledger);
        if (!authority.import_and_publish_committed_ledger(std::move(ledger), error) ||
            !runtime.bind_formula_owned_state(authority.state(), error)) return false;
    }
    runtime.flush_formula_owned_domain_mirrors();
    if (!authority.publish_owned_committed_mirror(runtime.committed_generation(),
            runtime.current_day(), error)) return false;
    authority.set_authority_mode(RuntimeEconomyAuthorityMode::POD_ACTIVE);
    return true;
}
} // namespace pk
