#include "economy_authority_transfer.h"
#include "economy_runtime_owned_state_codec.h"

namespace pk {
void EconomyAuthorityTransfer::append_continuations(
        const NativeEconomyRuntime &runtime, std::vector<uint8_t> &wire) {
    persistence_codec::append_publication_block(wire, capture_resource_continuation(runtime), 9u);
    persistence_codec::append_publication_block(wire, capture_owner_mobility_continuation(runtime), 10u);
    persistence_codec::append_publication_block(wire, capture_cadence_continuation(runtime), 11u);
    persistence_codec::append_publication_block(wire, capture_population_continuation(runtime), 12u);
    persistence_codec::append_publication_block(wire, capture_climate_continuation(runtime), 13u);
}
bool EconomyAuthorityTransfer::validate_continuations(
        const NativeEconomyRuntime &runtime, const RuntimeEconomyEcp2State &state,
        std::string &error) {
    return validate_resource_continuation(runtime, state, error) &&
           validate_owner_mobility_continuation(runtime, state, error) &&
           validate_cadence_continuation(runtime, state, error) &&
           validate_population_continuation(runtime, state, error) &&
           validate_climate_continuation(runtime, state, error);
}
bool EconomyAuthorityTransfer::restore_continuations(
        NativeEconomyRuntime &runtime, const RuntimeEconomyEcp2State &state,
        std::string &error) {
    return restore_resource_continuation(runtime, state, error) &&
           restore_owner_mobility_continuation(runtime, state, error) &&
           restore_cadence_continuation(runtime, state, error) &&
           restore_population_continuation(runtime, state, error) &&
           restore_climate_continuation(runtime, state, error);
}
} // namespace pk
