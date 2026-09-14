#pragma once

#include <cstdint>
#include <vector>

namespace pk {

struct RuntimeEconomyPriceCeilingState {
    int32_t good = -1;
    int32_t limit = 0;
    uint16_t confirmation_days = 0;
};

// Live market storage, independent of the Godot facade and formula executor.
// Preserve column order and sparse price-ceiling rows for existing PKEC I/O.
struct RuntimeEconomyMarketStore {
    int32_t market_count = 0;
    int32_t good_count = 0;
    std::vector<int64_t> stock;
    std::vector<int32_t> price;
    std::vector<int64_t> demand_ema;
    std::vector<uint16_t> last_shortage_q16;
    std::vector<int32_t> cell_to_market;
    std::vector<std::vector<RuntimeEconomyPriceCeilingState>> price_ceilings;

    void clear();
    int64_t index(int32_t market, int32_t good) const {
        return static_cast<int64_t>(market) * good_count + good;
    }
};

// Committed-only business columns shared by the legacy-to-POD migration.
// Derived CSR, catalog data, and any partially settled epoch state remain in
// their current owners until their stages move to the worker.
struct RuntimeEconomyLedgerState {
    uint64_t source_state_hash = 0;
    uint64_t ledger_hash = 0;
    uint64_t generation = 0;
    int64_t committed_day = -1;
    int32_t market_count = 0;
    int32_t good_count = 0;

    std::vector<uint8_t> cohort_active;
    std::vector<uint32_t> cohort_signature_id;
    std::vector<int64_t> cohort_population;
    std::vector<int64_t> cohort_funds;
    std::vector<int64_t> cohort_epoch_income;
    std::vector<int64_t> cohort_epoch_expense;
    std::vector<int64_t> market_stock;
    std::vector<int32_t> market_price;
    std::vector<int64_t> market_demand_ema;

    void clear() noexcept;
    uint64_t recompute_hash() noexcept;
    bool valid() const noexcept;
};

} // namespace pk
