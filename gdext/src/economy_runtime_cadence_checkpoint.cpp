#include "economy_authority_transfer.h"
#include "economy_runtime.h"
#include "economy_runtime_owned_state_codec.h"
#include "economy_runtime_publication_codec.h"
#include "runtime_economy_ecp2.h"
#include <array>
#include <cmath>
#include <cstring>
namespace pk {
namespace {
bool decode(const RuntimeEconomyEcp2State &state, std::array<double, 6> &values, std::string &error) {
    auto found = state.domain_blobs.find(ECP2_DOMAIN_OWNED_STATE);
    if (found == state.domain_blobs.end()) { error = "ecp2_cadence_missing"; return false; }
    auto wire = persistence_codec::publication_block(found->second, 11u);
    publication_codec::PublicationReader in{wire};
    for (double &value : values) {
        uint64_t bits = 0;
        if (!in.scalar(bits)) { error = "ecp2_cadence_truncated"; return false; }
        std::memcpy(&value, &bits, sizeof(value));
        if (!std::isfinite(value) || value < 0.0) { error = "ecp2_cadence_invalid"; return false; }
    }
    if (in.cursor != wire.size()) { error = "ecp2_cadence_trailing"; return false; }
    return true;
}
}
std::vector<uint8_t> EconomyAuthorityTransfer::capture_cadence_continuation(const NativeEconomyRuntime &runtime) {
    publication_codec::PublicationWriter out;
    // Preserve measured continuation; injection/forced-period hooks remain test configuration.
    for (double value : std::array<double, 6>{runtime._market_ms_per_knife_ema, runtime._slow_ms_per_knife_ema, runtime._investment_ms_per_knife_ema, runtime._cycle_market_ms_accum, runtime._cycle_slow_ms_accum, runtime._cycle_investment_ms_accum}) {
        uint64_t bits; std::memcpy(&bits, &value, sizeof(bits)); out.scalar(bits);
    }
    return std::move(out.bytes);
}
bool EconomyAuthorityTransfer::validate_cadence_continuation(const NativeEconomyRuntime &, const RuntimeEconomyEcp2State &state, std::string &error) {
    std::array<double, 6> values{}; return decode(state, values, error);
}
bool EconomyAuthorityTransfer::restore_cadence_continuation(NativeEconomyRuntime &runtime, const RuntimeEconomyEcp2State &state, std::string &error) {
    std::array<double, 6> values{};
    if (!decode(state, values, error)) return false;
    runtime._market_ms_per_knife_ema = values[0];
    runtime._slow_ms_per_knife_ema = values[1];
    runtime._investment_ms_per_knife_ema = values[2];
    runtime._cycle_market_ms_accum = values[3];
    runtime._cycle_slow_ms_accum = values[4];
    runtime._cycle_investment_ms_accum = values[5];
    return true;
}
} // namespace pk
