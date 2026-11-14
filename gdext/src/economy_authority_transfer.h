#pragma once
#include <cstdint>
#include <string>
#include <vector>

namespace pk {
class NativeEconomyRuntime;
class RuntimeEconomyPodAuthority;
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
    static bool bind_restored_owner(NativeEconomyRuntime &runtime,
        RuntimeEconomyPodAuthority &authority, std::string &error);
    static bool capture(NativeEconomyRuntime &runtime,
                        RuntimeEconomyEcp2State &out, std::string &error,
                        uint32_t flags, const CountryIdentity *country = nullptr);
    static bool restore_before_country(NativeEconomyRuntime &runtime,
                                       const RuntimeEconomyEcp2State &state,
                                       std::string &error);
    static bool restore_country_replica(NativeEconomyRuntime &runtime,
                                        const std::vector<uint8_t> &bytes, std::string &error);
    static std::vector<uint8_t> capture_resource_continuation(const NativeEconomyRuntime &runtime);
    static bool validate_resource_continuation(const NativeEconomyRuntime &runtime,
        const RuntimeEconomyEcp2State &state, std::string &error);
    static bool restore_resource_continuation(NativeEconomyRuntime &runtime,
        const RuntimeEconomyEcp2State &state, std::string &error);
    static std::vector<uint8_t> capture_owner_mobility_continuation(
        const NativeEconomyRuntime &runtime);
    static bool validate_owner_mobility_continuation(
        const NativeEconomyRuntime &runtime,
        const RuntimeEconomyEcp2State &state, std::string &error);
    static bool restore_owner_mobility_continuation(
        NativeEconomyRuntime &runtime,
        const RuntimeEconomyEcp2State &state, std::string &error);
    static std::vector<uint8_t> capture_cadence_continuation(const NativeEconomyRuntime &runtime);
    static bool validate_cadence_continuation(const NativeEconomyRuntime &runtime,
        const RuntimeEconomyEcp2State &state, std::string &error);
    static bool restore_cadence_continuation(NativeEconomyRuntime &runtime,
        const RuntimeEconomyEcp2State &state, std::string &error);
    static std::vector<uint8_t> capture_population_continuation(const NativeEconomyRuntime &runtime);
    static bool validate_population_continuation(const NativeEconomyRuntime &runtime,
        const RuntimeEconomyEcp2State &state, std::string &error);
    static bool restore_population_continuation(NativeEconomyRuntime &runtime,
        const RuntimeEconomyEcp2State &state, std::string &error);
    static std::vector<uint8_t> capture_climate_continuation(const NativeEconomyRuntime &runtime);
    static bool validate_climate_continuation(const NativeEconomyRuntime &runtime,
        const RuntimeEconomyEcp2State &state, std::string &error);
    static bool restore_climate_continuation(NativeEconomyRuntime &runtime,
        const RuntimeEconomyEcp2State &state, std::string &error);
    static void append_continuations(const NativeEconomyRuntime &runtime, std::vector<uint8_t> &wire);
    static bool validate_continuations(const NativeEconomyRuntime &runtime,
        const RuntimeEconomyEcp2State &state, std::string &error);
    static bool restore_continuations(NativeEconomyRuntime &runtime,
        const RuntimeEconomyEcp2State &state, std::string &error);
    static bool verify_after_country(const NativeEconomyRuntime &runtime,
                                     std::string &error);
};
} // namespace pk
