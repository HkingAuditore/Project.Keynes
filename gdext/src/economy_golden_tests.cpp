#include "economy_runtime.h"
#include "economy_runtime_test_access.h"
#include "runtime_economy_pod.h"

#include <memory>

namespace pk {

bool EconomyTargetSelectorTests::run_golden_population_market(std::string &error) {
    auto runtime = std::make_unique<NativeEconomyRuntime>();
    auto authority = std::make_unique<RuntimeEconomyPodAuthority>();
    auto &rt = *runtime;
    auto &owned = authority->state();
    owned.sample_day = 2;
    owned.committed_day = 2;
    // These columns are absent from the early compatibility ledger. A golden
    // read must nevertheless include them, before and after the store handoff.
    rt._population_local.income_ema = {17, -8};
    rt._population_local.demography_residual = {31, 47};
    rt._population_local.flags = {32768, 0};
    owned.population = rt._population_local;
    const uint64_t complete = rt.golden_population_market_hash(2, 2);
    if (complete != authority->golden_population_market_hash()) {
        error = "golden_economy_same_stores_different_hash";
        return false;
    }
    owned.population.income_ema = {0, 0};
    if (rt.golden_population_market_hash(2, 2) != complete ||
        authority->golden_population_market_hash() == complete) {
        error = "golden_economy_reads_incomplete_mirror";
        return false;
    }
    owned.population = std::move(rt._population_local);
    rt._formula_owned = &owned;
    const bool stable = rt.golden_population_market_hash(2, 2) == complete;
    owned.population.income_ema = {18, -8};
    const bool live = rt.golden_population_market_hash(2, 2) != complete;
    rt._formula_owned = nullptr;
    if (!stable || !live) {
        error = "golden_economy_formula_owner_handoff";
        return false;
    }
    return true;
}

} // namespace pk
