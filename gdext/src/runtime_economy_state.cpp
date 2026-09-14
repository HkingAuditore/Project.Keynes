#include "runtime_economy_state.h"
#include <cstddef>

namespace pk {
void RuntimeEconomyMarketStore::clear() {
    market_count = 0;
    good_count = 0;
    stock.clear();
    price.clear();
    demand_ema.clear();
    last_shortage_q16.clear();
    cell_to_market.clear();
    price_ceilings.clear();
}

namespace {
constexpr uint64_t FNV_OFFSET = 1469598103934665603ull;
constexpr uint64_t FNV_PRIME = 1099511628211ull;

uint64_t mix(uint64_t hash, uint64_t value) noexcept {
    hash ^= value;
    return hash * FNV_PRIME;
}

template <typename T>
void mix_vector(uint64_t &hash, const std::vector<T> &values) noexcept {
    hash = mix(hash, values.size());
    for (const T value : values)
        hash = mix(hash, static_cast<uint64_t>(value));
}
} // namespace

void RuntimeEconomyLedgerState::clear() noexcept {
    source_state_hash = 0;
    ledger_hash = 0;
    generation = 0;
    committed_day = -1;
    market_count = 0;
    good_count = 0;
    cohort_active.clear();
    cohort_signature_id.clear();
    cohort_population.clear();
    cohort_funds.clear();
    cohort_epoch_income.clear();
    cohort_epoch_expense.clear();
    market_stock.clear();
    market_price.clear();
    market_demand_ema.clear();
}

bool RuntimeEconomyLedgerState::valid() const noexcept {
    if (generation == 0 || committed_day < 0 || market_count < 0 || good_count < 0)
        return false;
    const std::size_t cohorts = cohort_active.size();
    const std::size_t market_lanes = static_cast<std::size_t>(market_count) *
        static_cast<std::size_t>(good_count);
    return
        cohort_signature_id.size() == cohorts &&
        cohort_population.size() == cohorts && cohort_funds.size() == cohorts &&
        cohort_epoch_income.size() == cohorts &&
        cohort_epoch_expense.size() == cohorts &&
        market_stock.size() == market_lanes && market_price.size() == market_lanes &&
        market_demand_ema.size() == market_lanes;
}

uint64_t RuntimeEconomyLedgerState::recompute_hash() noexcept {
    uint64_t hash = FNV_OFFSET;
    hash = mix(hash, generation);
    hash = mix(hash, static_cast<uint64_t>(committed_day));
    hash = mix(hash, static_cast<uint32_t>(market_count));
    hash = mix(hash, static_cast<uint32_t>(good_count));
    mix_vector(hash, cohort_active);
    mix_vector(hash, cohort_signature_id);
    mix_vector(hash, cohort_population);
    mix_vector(hash, cohort_funds);
    mix_vector(hash, cohort_epoch_income);
    mix_vector(hash, cohort_epoch_expense);
    mix_vector(hash, market_stock);
    mix_vector(hash, market_price);
    mix_vector(hash, market_demand_ema);
    ledger_hash = hash;
    return hash;
}

} // namespace pk
