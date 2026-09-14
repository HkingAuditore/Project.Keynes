#include "runtime_economy_population_store.h"

#include <algorithm>
#include <cstddef>
#include <limits>

namespace pk {
namespace {

void append_page_storage(RuntimeEconomyPopulationStore &store,
                         int32_t cell) {
    const int32_t page = static_cast<int32_t>(store.page_next.size());
    store.page_next.push_back(-1);
    store.page_cell.push_back(cell);
    const size_t next_size =
        static_cast<size_t>(page + 1) *
        RuntimeEconomyPopulationStore::COHORT_PAGE_SIZE;
    store.active.resize(next_size, 0);
    store.reserved.resize(next_size, 0);
    store.reservation_owner.resize(next_size, 0);
    store.signature_id.resize(next_size, 0);
    store.generation.resize(next_size, 1);
    store.population.resize(next_size, 0);
    store.funds.resize(next_size, 0);
    store.epoch_income.resize(next_size, 0);
    store.epoch_expense.resize(next_size, 0);
    store.epoch_in_kind_income.resize(next_size, 0);
    store.income_ema.resize(next_size, 0);
    store.epoch_tax_paid.resize(next_size, 0);
    store.epoch_subsidy_received.resize(next_size, 0);
    store.income_baseline_ema.resize(next_size, 0);
    store.needs_satisfaction.resize(
        next_size,
        static_cast<uint16_t>(RuntimeEconomyPopulationStore::Q16_ONE - 1));
    store.worst_need_id.resize(next_size,
                               std::numeric_limits<uint16_t>::max());
    store.composite_satisfaction.resize(
        next_size,
        static_cast<uint16_t>(RuntimeEconomyPopulationStore::Q16_ONE - 1));
    store.satisfaction_dims.resize(
        next_size *
            static_cast<size_t>(RuntimeEconomyPopulationStore::SAT_DIM_COUNT),
        static_cast<uint16_t>(RuntimeEconomyPopulationStore::Q16_ONE - 1));
    store.worst_dimension_id.resize(next_size,
                                    std::numeric_limits<uint8_t>::max());
    store.flags.resize(next_size, 0);
    store.demography_residual.resize(next_size, 0);
    store.owner_employed.resize(next_size, 0);
    store.employee_employed.resize(next_size, 0);
    store.high_water_slots = static_cast<int64_t>(next_size);
}

void link_page_to_cell(RuntimeEconomyPopulationStore &store, int32_t page,
                       int32_t cell) {
    if (store.cell_first_page[cell] < 0) {
        store.cell_first_page[cell] = page;
        return;
    }
    int32_t tail = store.cell_first_page[cell];
    while (store.page_next[tail] >= 0) tail = store.page_next[tail];
    store.page_next[tail] = page;
}

} // namespace

void RuntimeEconomyPopulationStore::clear(int32_t cells) {
    cell_first_page.assign(std::max(0, cells), -1);
    page_next.clear();
    page_cell.clear();
    free_pages.clear();
    active.clear();
    reserved.clear();
    reservation_owner.clear();
    signature_id.clear();
    generation.clear();
    population.clear();
    funds.clear();
    epoch_income.clear();
    epoch_expense.clear();
    epoch_in_kind_income.clear();
    income_ema.clear();
    epoch_tax_paid.clear();
    epoch_subsidy_received.clear();
    income_baseline_ema.clear();
    needs_satisfaction.clear();
    worst_need_id.clear();
    composite_satisfaction.clear();
    satisfaction_dims.clear();
    worst_dimension_id.clear();
    flags.clear();
    demography_residual.clear();
    owner_employed.clear();
    employee_employed.clear();
    active_count = 0;
    high_water_slots = 0;
}

void RuntimeEconomyPopulationStore::reset_satisfaction_slot(int32_t slot) {
    epoch_tax_paid[slot] = 0;
    epoch_subsidy_received[slot] = 0;
    income_baseline_ema[slot] = 0;
    needs_satisfaction[slot] = static_cast<uint16_t>(Q16_ONE - 1);
    worst_need_id[slot] = std::numeric_limits<uint16_t>::max();
    composite_satisfaction[slot] = static_cast<uint16_t>(Q16_ONE - 1);
    worst_dimension_id[slot] = std::numeric_limits<uint8_t>::max();
    const size_t base = static_cast<size_t>(slot) * static_cast<size_t>(SAT_DIM_COUNT);
    for (int32_t dim = 0; dim < SAT_DIM_COUNT; ++dim) {
        satisfaction_dims[base + static_cast<size_t>(dim)] =
            static_cast<uint16_t>(Q16_ONE - 1);
    }
}

int32_t RuntimeEconomyPopulationStore::allocate_page(int32_t cell) {
    int32_t page = -1;
    if (!free_pages.empty()) {
        page = free_pages.back();
        free_pages.pop_back();
        page_cell[page] = cell;
        page_next[page] = -1;
        const int32_t base = page * COHORT_PAGE_SIZE;
        std::fill(active.begin() + base, active.begin() + base + COHORT_PAGE_SIZE, uint8_t{0});
        std::fill(reserved.begin() + base,
                  reserved.begin() + base + COHORT_PAGE_SIZE, uint8_t{0});
        std::fill(reservation_owner.begin() + base,
                  reservation_owner.begin() + base + COHORT_PAGE_SIZE,
                  uint64_t{0});
    } else {
        page = static_cast<int32_t>(page_next.size());
        append_page_storage(*this, cell);
    }
    link_page_to_cell(*this, page, cell);
    return page;
}

bool RuntimeEconomyPopulationStore::restore_page_at(int32_t page,
                                                     int32_t cell) {
    if (page != static_cast<int32_t>(page_next.size()) || cell < -1 ||
        cell >= static_cast<int32_t>(cell_first_page.size())) {
        return false;
    }
    append_page_storage(*this, cell);
    if (cell < 0) {
        free_pages.push_back(page);
    } else {
        link_page_to_cell(*this, page, cell);
    }
    return true;
}

int32_t RuntimeEconomyPopulationStore::find_signature(int32_t cell,
                                                               uint32_t signature) const {
    int32_t result = -1;
    for_each_in_cell(cell, [&](int32_t slot) {
        ++scan_steps;
        if (result < 0 && signature_id[slot] == signature) result = slot;
    });
    return result;
}

int32_t RuntimeEconomyPopulationStore::allocate_slot(int32_t cell,
                                                              uint32_t signature) {
    if (cell < 0 || cell >= static_cast<int32_t>(cell_first_page.size())) return -1;
    const int32_t existing = find_signature(cell, signature);
    if (existing >= 0) return existing;
    if (cell_first_page[cell] < 0) allocate_page(cell);
    for (int32_t p = cell_first_page[cell]; p >= 0; p = page_next[p]) {
        const int32_t base = p * COHORT_PAGE_SIZE;
        for (int32_t lane = 0; lane < COHORT_PAGE_SIZE; ++lane) {
            const int32_t slot = base + lane;
            if (active[slot] != 0 || reserved[slot] != 0) continue;
            active[slot] = 1;
            signature_id[slot] = signature;
            population[slot] = 0;
            funds[slot] = 0;
            epoch_income[slot] = 0;
            epoch_expense[slot] = 0;
            epoch_in_kind_income[slot] = 0;
            income_ema[slot] = 0;
            reset_satisfaction_slot(slot);
            flags[slot] = 0;
            demography_residual[slot] = 0;
            owner_employed[slot] = 0;
            employee_employed[slot] = 0;
            ++active_count;
            return slot;
        }
    }
    const int32_t page = allocate_page(cell);
    const int32_t slot = page * COHORT_PAGE_SIZE;
    active[slot] = 1;
    signature_id[slot] = signature;
    population[slot] = 0;
    funds[slot] = 0;
    epoch_income[slot] = 0;
    epoch_expense[slot] = 0;
    epoch_in_kind_income[slot] = 0;
    income_ema[slot] = 0;
    reset_satisfaction_slot(slot);
    flags[slot] = 0;
    demography_residual[slot] = 0;
    owner_employed[slot] = 0;
    employee_employed[slot] = 0;
    ++active_count;
    return slot;
}

int32_t RuntimeEconomyPopulationStore::restore_slot_at(
        int32_t slot, int32_t cell, uint32_t signature) {
    if (slot < 0 || slot >= static_cast<int32_t>(active.size()) || cell < 0 ||
        cell >= static_cast<int32_t>(cell_first_page.size())) {
        return -1;
    }
    const int32_t page = slot / COHORT_PAGE_SIZE;
    if (page_cell[page] != cell ||
        (active[slot] != 0 && signature_id[slot] != signature)) {
        return -1;
    }
    if (active[slot] == 0) {
        active[slot] = 1;
        signature_id[slot] = signature;
        ++active_count;
    }
    return slot;
}
int32_t RuntimeEconomyPopulationStore::reserve_slot(
        int32_t cell, uint32_t signature, uint64_t owner) {
    if (cell < 0 || cell >= static_cast<int32_t>(cell_first_page.size()) ||
        owner == 0) return -1;
    if (cell_first_page[cell] < 0) allocate_page(cell);
    for (int32_t p = cell_first_page[cell]; p >= 0; p = page_next[p]) {
        const int32_t base = p * COHORT_PAGE_SIZE;
        for (int32_t lane = 0; lane < COHORT_PAGE_SIZE; ++lane) {
            const int32_t slot = base + lane;
            if (active[slot] == 0 && reserved[slot] != 0 &&
                reservation_owner[slot] == owner &&
                signature_id[slot] == signature) return slot;
        }
    }
    for (int32_t p = cell_first_page[cell]; p >= 0; p = page_next[p]) {
        const int32_t base = p * COHORT_PAGE_SIZE;
        for (int32_t lane = 0; lane < COHORT_PAGE_SIZE; ++lane) {
            const int32_t slot = base + lane;
            if (active[slot] != 0 || reserved[slot] != 0) continue;
            reserved[slot] = 1;
            reservation_owner[slot] = owner;
            signature_id[slot] = signature;
            return slot;
        }
    }
    const int32_t page = allocate_page(cell);
    const int32_t slot = page * COHORT_PAGE_SIZE;
    reserved[slot] = 1;
    reservation_owner[slot] = owner;
    signature_id[slot] = signature;
    return slot;
}

int32_t RuntimeEconomyPopulationStore::claim_reserved_slot(
        int32_t slot, int32_t cell, uint32_t signature, uint64_t owner) {
    const int32_t existing = find_signature(cell, signature);
    if (existing >= 0) {
        release_reserved_slot(slot, owner);
        return existing;
    }
    if (slot < 0 || slot >= static_cast<int32_t>(active.size()) ||
        active[slot] != 0 || reserved[slot] == 0 ||
        reservation_owner[slot] != owner || signature_id[slot] != signature ||
        page_cell[slot / COHORT_PAGE_SIZE] != cell) return -1;
    reserved[slot] = 0;
    reservation_owner[slot] = 0;
    active[slot] = 1;
    population[slot] = 0;
    funds[slot] = 0;
    epoch_income[slot] = 0;
    epoch_expense[slot] = 0;
    epoch_in_kind_income[slot] = 0;
    income_ema[slot] = 0;
    reset_satisfaction_slot(slot);
    flags[slot] = 0;
    demography_residual[slot] = 0;
    owner_employed[slot] = 0;
    employee_employed[slot] = 0;
    ++active_count;
    return slot;
}

void RuntimeEconomyPopulationStore::release_reserved_slot(
        int32_t slot, uint64_t owner) {
    if (slot < 0 || slot >= static_cast<int32_t>(reserved.size()) ||
        active[slot] != 0 || reserved[slot] == 0 ||
        reservation_owner[slot] != owner) return;
    reserved[slot] = 0;
    reservation_owner[slot] = 0;
}

bool RuntimeEconomyPopulationStore::valid_handle(uint64_t handle,
                                                          int32_t &slot_out) const {
    const uint32_t slot = static_cast<uint32_t>(handle & 0xffffffffULL);
    const uint32_t gen = static_cast<uint32_t>(handle >> 32);
    if (slot >= active.size() || active[slot] == 0 || generation[slot] != gen) return false;
    slot_out = static_cast<int32_t>(slot);
    return true;
}

uint64_t RuntimeEconomyPopulationStore::handle_for_slot(int32_t slot) const {
    if (slot < 0 || slot >= static_cast<int32_t>(generation.size()) || active[slot] == 0)
        return 0;
    return (static_cast<uint64_t>(generation[slot]) << 32) | static_cast<uint32_t>(slot);
}

void RuntimeEconomyPopulationStore::release_slot(int32_t slot) {
    if (slot < 0 || slot >= static_cast<int32_t>(active.size()) || active[slot] == 0) return;
    active[slot] = 0;
    population[slot] = 0;
    funds[slot] = 0;
    epoch_income[slot] = 0;
    epoch_expense[slot] = 0;
    epoch_in_kind_income[slot] = 0;
    income_ema[slot] = 0;
    reset_satisfaction_slot(slot);
    demography_residual[slot] = 0;
    owner_employed[slot] = 0;
    employee_employed[slot] = 0;
    generation[slot] = generation[slot] == std::numeric_limits<uint32_t>::max()
                           ? 1u : generation[slot] + 1u;
    --active_count;
}

void RuntimeEconomyPopulationStore::reclaim_empty_pages(int32_t cell) {
    if (cell < 0 || cell >= static_cast<int32_t>(cell_first_page.size())) return;
    int32_t previous = -1;
    int32_t page = cell_first_page[cell];
    while (page >= 0) {
        const int32_t next = page_next[page];
        const int32_t base = page * COHORT_PAGE_SIZE;
        bool any = false;
        for (int32_t lane = 0; lane < COHORT_PAGE_SIZE; ++lane)
            any |= active[base + lane] != 0 || reserved[base + lane] != 0;
        if (!any) {
            if (previous < 0) cell_first_page[cell] = next;
            else page_next[previous] = next;
            page_next[page] = -1;
            page_cell[page] = -1;
            free_pages.push_back(page);
        } else {
            previous = page;
        }
        page = next;
    }
}

} // namespace pk

