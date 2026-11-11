#include "economy_authority_transfer.h"
#include "economy_runtime.h"
#include "economy_runtime_owned_state_codec.h"
#include "economy_runtime_publication_codec.h"
#include "runtime_economy_ecp2.h"

namespace pk {
namespace {
struct RainObservationState {
    std::vector<int32_t> rain_event, rain_threshold;
};

bool decode(const RuntimeEconomyEcp2State &state,
            RainObservationState &out, std::string &error) {
    const auto found = state.domain_blobs.find(ECP2_DOMAIN_OWNED_STATE);
    if (found == state.domain_blobs.end()) {
        error = "ecp2_climate_continuation_missing"; return false;
    }
    const auto wire = persistence_codec::publication_block(found->second, 13u);
    publication_codec::PublicationReader in{wire};
    if (!in.lanes(out.rain_event) || !in.lanes(out.rain_threshold) ||
        in.cursor != wire.size()) {
        error = "ecp2_climate_continuation_invalid"; return false;
    }
    const size_t cells = static_cast<size_t>(std::max(0, state.envelope.cell_count));
    if (out.rain_event.size() != cells ||
        (!out.rain_threshold.empty() && out.rain_threshold.size() != cells)) {
        error = "ecp2_climate_continuation_shape"; return false;
    }
    for (int32_t value : out.rain_event) {
        if (value != 0 && value != NativeEconomyRuntime::Q16_ONE) {
            error = "ecp2_climate_continuation_rain_invalid"; return false;
        }
    }
    for (int32_t value : out.rain_threshold) {
        if (value <= 0 || value > NativeEconomyRuntime::Q16_ONE) {
            error = "ecp2_climate_continuation_threshold_invalid"; return false;
        }
    }
    return true;
}
} // namespace

std::vector<uint8_t> EconomyAuthorityTransfer::capture_climate_continuation(
        const NativeEconomyRuntime &runtime) {
    publication_codec::PublicationWriter out;
    // A sampled day may not have opened its economy epoch yet. Its rain edge
    // cannot be reconstructed from the latest precipitation observation.
    auto rain = runtime._cell_rain_event_q16;
    auto threshold = runtime._epoch_cell_rain_event_threshold_q16;
    out.lanes(rain);
    out.lanes(threshold);
    return std::move(out.bytes);
}

bool EconomyAuthorityTransfer::validate_climate_continuation(
        const NativeEconomyRuntime &, const RuntimeEconomyEcp2State &state,
        std::string &error) {
    RainObservationState candidate;
    return decode(state, candidate, error);
}

bool EconomyAuthorityTransfer::restore_climate_continuation(
        NativeEconomyRuntime &runtime, const RuntimeEconomyEcp2State &state,
        std::string &error) {
    RainObservationState candidate;
    if (!decode(state, candidate, error)) return false;
    runtime._cell_rain_event_q16 = std::move(candidate.rain_event);
    runtime._epoch_cell_rain_event_threshold_q16 = std::move(candidate.rain_threshold);
    return true;
}
} // namespace pk
