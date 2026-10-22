#pragma once

// Economy's committed class-opinion snapshot -> the ideology POD opinion struct.
//
// One direction, one function.
//
// The conversion used to live twice: `world_ext_ideology.cpp` copied Economy's
// struct for the worker publish, and `NativeIdeologyRuntime::accrue_points` read
// Economy directly. Adding a field in one place and not the other is how the two
// authorities end up accruing from subtly different inputs, which presents as a
// business divergence rather than as a missing field. Both paths now go through
// this header.

#include "economy_runtime.h"
#include "runtime_ideology_pod.h"

#include <algorithm>
#include <cstdint>

namespace pk {

inline RuntimeIdeologyOpinionSnapshot ideology_opinion_from_economy(
        const NativeEconomyRuntime::CountryClassOpinionSnapshot &source) {
    RuntimeIdeologyOpinionSnapshot out;
    out.revision = source.revision;
    out.class_hash = source.class_hash;
    out.committed_day = source.commit_day;
    out.period_index = source.period_index;
    out.country_count = static_cast<uint32_t>(std::max(0, source.country_count));
    out.class_count = static_cast<uint32_t>(std::max(0, source.class_count));
    out.country_handles = source.country_handles;
    out.country_generations = source.country_generations;
    out.population = source.population;
    out.funds = source.funds;
    out.owner_employed = source.owner_employed;
    out.satisfaction_weighted = source.satisfaction_weighted;
    out.satisfaction_q16 = source.satisfaction_q16;
    out.country_population = source.country_population;
    out.country_buildings_installed = source.country_buildings_installed;
    out.country_trade_base_value = source.country_trade_base_value;
    out.period_days = std::max<int64_t>(1, source.period_days);
    return out;
}

} // namespace pk
