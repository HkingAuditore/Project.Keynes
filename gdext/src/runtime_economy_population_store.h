#pragma once

#include <cstdint>
#include <vector>
#include "economy_tracked_column.h"
#include "economy_tracked_scalar.h"

namespace pk {

struct RuntimeEconomyPopulationStore {
    ChangeRegistry changes;
    static constexpr int32_t COHORT_PAGE_SIZE = 64;
    static constexpr int32_t Q16_ONE = 65536;
    static constexpr int32_t SAT_DIM_COUNT = 8;
    EconomyTrackedColumn<int32_t> cell_first_page;
    EconomyTrackedColumn<int32_t> page_next;
    EconomyTrackedColumn<int32_t> page_cell;
    EconomyTrackedColumn<int32_t> free_pages;

    EconomyTrackedColumn<uint8_t> active;
    EconomyTrackedColumn<uint8_t> reserved;
    EconomyTrackedColumn<uint64_t> reservation_owner;
    EconomyTrackedColumn<uint32_t> signature_id;
    EconomyTrackedColumn<uint32_t> generation;
    EconomyTrackedColumn<int64_t> population;
    EconomyTrackedColumn<int64_t> funds;
    EconomyTrackedColumn<int64_t> epoch_income;
    EconomyTrackedColumn<int64_t> epoch_expense;
    // Derived diagnostic: retail value of goods consumed from producer-retained output.
    // It is reset with the epoch and intentionally excluded from save/hash authority.
    EconomyTrackedColumn<int64_t> epoch_in_kind_income;
    EconomyTrackedColumn<int64_t> income_ema;
    // Gross fiscal flows realized this epoch. They are pure attribution of
    // transfers that already happened, so they never participate in money
    // conservation; they exist so the tax-burden dimension can be computed
    // without re-deriving rates.
    EconomyTrackedColumn<int64_t> epoch_tax_paid;
    EconomyTrackedColumn<int64_t> epoch_subsidy_received;
    // Slow per-capita income EMA. `income_ema` tracks the current level;
    // this baseline trails it so their ratio is a growth signal.
    EconomyTrackedColumn<int64_t> income_baseline_ema;
    // Subsistence satisfaction. Retains its historical name because it is
    // still the sole input to starvation mortality.
    EconomyTrackedColumn<uint16_t> needs_satisfaction;
    EconomyTrackedColumn<uint16_t> worst_need_id;
    // Composite satisfaction plus its SAT_DIM_COUNT-strided breakdown and
    // the dimension responsible for the largest weighted shortfall.
    EconomyTrackedColumn<uint16_t> composite_satisfaction;
    EconomyTrackedColumn<uint16_t> satisfaction_dims;
    EconomyTrackedColumn<uint8_t> worst_dimension_id;
    EconomyTrackedColumn<uint16_t> flags;
    EconomyTrackedColumn<int64_t> demography_residual;
    EconomyTrackedColumn<int64_t> owner_employed;
    EconomyTrackedColumn<int64_t> employee_employed;

    EconomyTrackedScalar<int64_t> active_count;
    EconomyTrackedScalar<int64_t> high_water_slots;


    RuntimeEconomyPopulationStore();
    RuntimeEconomyPopulationStore(const RuntimeEconomyPopulationStore &other);
    RuntimeEconomyPopulationStore(RuntimeEconomyPopulationStore &&other);
    RuntimeEconomyPopulationStore &operator=(const RuntimeEconomyPopulationStore &other);
    RuntimeEconomyPopulationStore &operator=(RuntimeEconomyPopulationStore &&other);

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
    // Canonical field traversal uses the same bindings as the writers.
    template<class Visitor> void visit_registered_columns(Visitor &&visit) const {
        visit(cell_first_page);
        visit(page_next);
        visit(page_cell);
        visit(free_pages);
        visit(active);
        visit(reserved);
        visit(reservation_owner);
        visit(signature_id);
        visit(generation);
        visit(population);
        visit(funds);
        visit(epoch_income);
        visit(epoch_expense);
        visit(epoch_in_kind_income);
        visit(income_ema);
        visit(epoch_tax_paid);
        visit(epoch_subsidy_received);
        visit(income_baseline_ema);
        visit(needs_satisfaction);
        visit(worst_need_id);
        visit(composite_satisfaction);
        visit(satisfaction_dims);
        visit(worst_dimension_id);
        visit(flags);
        visit(demography_residual);
        visit(owner_employed);
        visit(employee_employed);
        visit(active_count.column());
        visit(high_water_slots.column());
    }

};

} // namespace pk

