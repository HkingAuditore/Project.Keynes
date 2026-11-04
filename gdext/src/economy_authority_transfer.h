#pragma once
#include <cstdint>
#include <string>

namespace pk {
class NativeEconomyRuntime;
struct RuntimeEconomyEcp2State;

// Executor/save adapter. Only this capability may temporarily defer the Country
// identity check or stamp an independently committed Country checkpoint.
// Callers never receive mutable runtime state or a persistent override switch.
class EconomyAuthorityTransfer final {
public:
    struct CountryIdentity {
        uint64_t generation = 0;
        uint64_t state_hash = 0;
    };
    static bool service_country_requests(NativeEconomyRuntime &runtime,
                                         uint32_t max_requests, std::string &error);
    static int64_t sample_day(const NativeEconomyRuntime &runtime) noexcept;
    static bool capture(NativeEconomyRuntime &runtime,
                        RuntimeEconomyEcp2State &out, std::string &error,
                        uint32_t flags, const CountryIdentity *country = nullptr);
    static bool restore_before_country(NativeEconomyRuntime &runtime,
                                       const RuntimeEconomyEcp2State &state,
                                       std::string &error);
    static bool verify_after_country(const NativeEconomyRuntime &runtime,
                                     std::string &error);
};
} // namespace pk
