#include "economy_authority_transfer.h"
#include "economy_runtime.h"
#include "economy_runtime_owned_state_codec.h"
#include "economy_runtime_publication_codec.h"
#include "runtime_economy_ecp2.h"

namespace pk {
namespace {
bool decode_population(const RuntimeEconomyEcp2State &state,
        std::vector<int64_t> &values, std::string &error) {
    const auto found = state.domain_blobs.find(ECP2_DOMAIN_OWNED_STATE);
    if (found == state.domain_blobs.end()) {
        error = "ecp2_population_continuation_missing"; return false;
    }
    const auto wire = persistence_codec::publication_block(found->second, 12u);
    publication_codec::PublicationReader in{wire};
    if (!in.lanes(values) || in.cursor != wire.size()) {
        error = "ecp2_population_continuation_invalid"; return false;
    }
    // Slot identity/order is supplied by the canonical PAGES payload. Keep every
    // lane, including inactive slots, because later reuse reads the owner state.
    const auto cohort_wire = persistence_codec::publication_block(found->second, 5u);
    publication_codec::PublicationReader cohorts{cohort_wire};
    uint32_t slots = 0;
    if (!cohorts.scalar(slots) || values.size() != slots ||
        values.size() % NativeEconomyRuntime::COHORT_PAGE_SIZE != 0) {
        error = "ecp2_population_continuation_shape"; return false;
    }
    return true;
}
}
std::vector<uint8_t> EconomyAuthorityTransfer::capture_population_continuation(
        const NativeEconomyRuntime &runtime) {
    publication_codec::PublicationWriter out;
    auto values = runtime.population_store().epoch_in_kind_income.values();
    out.lanes(values);
    return std::move(out.bytes);
}
bool EconomyAuthorityTransfer::validate_population_continuation(
        const NativeEconomyRuntime &, const RuntimeEconomyEcp2State &state,
        std::string &error) {
    std::vector<int64_t> values;
    return decode_population(state, values, error);
}
bool EconomyAuthorityTransfer::restore_population_continuation(
        NativeEconomyRuntime &runtime, const RuntimeEconomyEcp2State &state,
        std::string &error) {
    std::vector<int64_t> values;
    if (!decode_population(state, values, error)) return false;
    if (values.size() != runtime.population_store().active.size()) {
        error = "ecp2_population_continuation_shape"; return false;
    }
    runtime.population_store().epoch_in_kind_income = std::move(values);
    return true;
}
} // namespace pk
