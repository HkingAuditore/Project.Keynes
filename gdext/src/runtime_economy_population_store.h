#pragma once

#include <cstdint>
#include <vector>

namespace pk {

struct RuntimeEconomyPopulationStore {
    static constexpr int32_t COHORT_PAGE_SIZE = 64;
    static constexpr int32_t Q16_ONE = 65536;
    static constexpr int32_t SAT_DIM_COUNT = 8;
    std::vector<int32_t> cell_first_page;
    std::vector<int32_t> page_next;
    std::vector<int32_t> page_cell;
    std::vector<int32_t> free_pages;

    std::vector<uint8_t> active;
    std::vector<uint8_t> reserved;
    std::vector<uint64_t> reservation_owner;
    std::vector<uint32_t> signature_id;
    std::vector<uint32_t> generation;
    std::vector<int64_t> population;
    std::vector<int64_t> funds;
    std::vector<int64_t> epoch_income;
    std::vector<int64_t> epoch_expense;
    // Derived diagnostic: retail value of goods consumed from producer-retained output.
    // It is reset with the epoch and intentionally excluded from save/hash authority.
    std::vector<int64_t> epoch_in_kind_income;
    std::vector<int64_t> income_ema;
    // Gross fiscal flows realized this epoch. They are pure attribution of
    // transfers that already happened, so they never participate in money
    // conservation; they exist so the tax-burden dimension can be computed
    // without re-deriving rates.
    std::vector<int64_t> epoch_tax_paid;
    std::vector<int64_t> epoch_subsidy_received;
    // Slow per-capita income EMA. `income_ema` tracks the current level;
    // this baseline trails it so their ratio is a growth signal.
    std::vector<int64_t> income_baseline_ema;
    // Subsistence satisfaction. Retains its historical name because it is
    // still the sole input to starvation mortality.
    std::vector<uint16_t> needs_satisfaction;
    std::vector<uint16_t> worst_need_id;
    // Composite satisfaction plus its SAT_DIM_COUNT-strided breakdown and
    // the dimension responsible for the largest weighted shortfall.
    std::vector<uint16_t> composite_satisfaction;
    std::vector<uint16_t> satisfaction_dims;
    std::vector<uint8_t> worst_dimension_id;
    std::vector<uint16_t> flags;
    std::vector<int64_t> demography_residual;
    std::vector<int64_t> owner_employed;
    std::vector<int64_t> employee_employed;

    int64_t active_count = 0;
    int64_t high_water_slots = 0;

    void clear(int32_t cells);
    void reset_satisfaction_slot(int32_t slot);
    int32_t allocate_page(int32_t cell);
    bool restore_page_at(int32_t page, int32_t cell);
    mutable int64_t scan_steps = 0;  // Diagnostics only.
    int32_t find_signature(int32_t cell, uint32_t signature) const;
    int32_t allocate_slot(int32_t cell, uint32_t signature);
    int32_t restore_slot_at(int32_t slot, int32_t cell, uint32_t signature);
    int32_t reserve_slot(int32_t cell, uint32_t signature,
                         uint64_t owner);
    int32_t claim_reserved_slot(int32_t slot, int32_t cell,
                                uint32_t signature, uint64_t owner);
    void release_reserved_slot(int32_t slot, uint64_t owner);
    bool valid_handle(uint64_t handle, int32_t &slot_out) const;
    uint64_t handle_for_slot(int32_t slot) const;
    void release_slot(int32_t slot);
    void reclaim_empty_pages(int32_t cell);
    template <typename F> void for_each_in_cell(int32_t cell, F &&fn) const {
        if (cell < 0 || cell >= static_cast<int32_t>(cell_first_page.size())) return;
        for (int32_t p = cell_first_page[cell]; p >= 0; p = page_next[p]) {
            const int32_t base = p * COHORT_PAGE_SIZE;
            for (int32_t lane = 0; lane < COHORT_PAGE_SIZE; ++lane) {
                const int32_t slot = base + lane;
                if (active[slot] != 0) fn(slot);
            }
        }
    }
};

} // namespace pk

