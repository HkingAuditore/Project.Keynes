#include "runtime_economy_population_store.h"

#include <algorithm>
#include <cstddef>
#include <limits>

namespace pk {
RuntimeEconomyPopulationStore::RuntimeEconomyPopulationStore()
    : cell_first_page(changes, {{1, 1}, "population.cell_first_page", EconomyFieldEncoding::I32, 4}),
      page_next(changes, {{1, 2}, "population.page_next", EconomyFieldEncoding::I32, 4}),
      page_cell(changes, {{1, 3}, "population.page_cell", EconomyFieldEncoding::I32, 4}),
      free_pages(changes, {{1, 4}, "population.free_pages", EconomyFieldEncoding::I32, 4}),
      active(changes, {{1, 5}, "population.active", EconomyFieldEncoding::U8, 1}),
      reserved(changes, {{1, 6}, "population.reserved", EconomyFieldEncoding::U8, 1}),
      reservation_owner(changes, {{1, 7}, "population.reservation_owner", EconomyFieldEncoding::U64, 8}),
      signature_id(changes, {{1, 8}, "population.signature_id", EconomyFieldEncoding::U32, 4}),
      generation(changes, {{1, 9}, "population.generation", EconomyFieldEncoding::U32, 4}),
      population(changes, {{1, 10}, "population.population", EconomyFieldEncoding::I64, 8}),
      funds(changes, {{1, 11}, "population.funds", EconomyFieldEncoding::I64, 8}),
      epoch_income(changes, {{1, 12}, "population.epoch_income", EconomyFieldEncoding::I64, 8}),
      epoch_expense(changes, {{1, 13}, "population.epoch_expense", EconomyFieldEncoding::I64, 8}),
      epoch_in_kind_income(changes, {{1, 14}, "population.epoch_in_kind_income", EconomyFieldEncoding::I64, 8}),
      income_ema(changes, {{1, 15}, "population.income_ema", EconomyFieldEncoding::I64, 8}),
      epoch_tax_paid(changes, {{1, 16}, "population.epoch_tax_paid", EconomyFieldEncoding::I64, 8}),
      epoch_subsidy_received(changes, {{1, 17}, "population.epoch_subsidy_received", EconomyFieldEncoding::I64, 8}),
      income_baseline_ema(changes, {{1, 18}, "population.income_baseline_ema", EconomyFieldEncoding::I64, 8}),
      needs_satisfaction(changes, {{1, 19}, "population.needs_satisfaction", EconomyFieldEncoding::U16, 2}),
      worst_need_id(changes, {{1, 20}, "population.worst_need_id", EconomyFieldEncoding::U16, 2}),
      composite_satisfaction(changes, {{1, 21}, "population.composite_satisfaction", EconomyFieldEncoding::U16, 2}),
      satisfaction_dims(changes, {{1, 22}, "population.satisfaction_dims", EconomyFieldEncoding::U16, 2}),
      worst_dimension_id(changes, {{1, 23}, "population.worst_dimension_id", EconomyFieldEncoding::U8, 1}),
      flags(changes, {{1, 24}, "population.flags", EconomyFieldEncoding::U16, 2}),
      demography_residual(changes, {{1, 25}, "population.demography_residual", EconomyFieldEncoding::I64, 8}),
      owner_employed(changes, {{1, 26}, "population.owner_employed", EconomyFieldEncoding::I64, 8}),
      employee_employed(changes, {{1, 27}, "population.employee_employed", EconomyFieldEncoding::I64, 8}),
      active_count(changes, {{1, 1001}, "population.active_count", EconomyFieldEncoding::I64, 8}),
      high_water_slots(changes, {{1, 1002}, "population.high_water_slots", EconomyFieldEncoding::I64, 8}) {}

RuntimeEconomyPopulationStore::RuntimeEconomyPopulationStore(const RuntimeEconomyPopulationStore &other)
    : RuntimeEconomyPopulationStore() { *this = other; }
RuntimeEconomyPopulationStore &RuntimeEconomyPopulationStore::operator=(const RuntimeEconomyPopulationStore &other) {
    if (this == &other) return *this;
    cell_first_page.assign(other.cell_first_page.values());
    page_next.assign(other.page_next.values());
    page_cell.assign(other.page_cell.values());
    free_pages.assign(other.free_pages.values());
    active.assign(other.active.values());
    reserved.assign(other.reserved.values());
    reservation_owner.assign(other.reservation_owner.values());
    signature_id.assign(other.signature_id.values());
    generation.assign(other.generation.values());
    population.assign(other.population.values());
    funds.assign(other.funds.values());
    epoch_income.assign(other.epoch_income.values());
    epoch_expense.assign(other.epoch_expense.values());
    epoch_in_kind_income.assign(other.epoch_in_kind_income.values());
    income_ema.assign(other.income_ema.values());
    epoch_tax_paid.assign(other.epoch_tax_paid.values());
    epoch_subsidy_received.assign(other.epoch_subsidy_received.values());
    income_baseline_ema.assign(other.income_baseline_ema.values());
    needs_satisfaction.assign(other.needs_satisfaction.values());
    worst_need_id.assign(other.worst_need_id.values());
    composite_satisfaction.assign(other.composite_satisfaction.values());
    satisfaction_dims.assign(other.satisfaction_dims.values());
    worst_dimension_id.assign(other.worst_dimension_id.values());
    flags.assign(other.flags.values());
    demography_residual.assign(other.demography_residual.values());
    owner_employed.assign(other.owner_employed.values());
    employee_employed.assign(other.employee_employed.values());
    active_count = other.active_count; high_water_slots = other.high_water_slots; scan_steps = other.scan_steps;
    return *this;
}

RuntimeEconomyPopulationStore::RuntimeEconomyPopulationStore(RuntimeEconomyPopulationStore &&other)
    : RuntimeEconomyPopulationStore() { *this = std::move(other); }
RuntimeEconomyPopulationStore &RuntimeEconomyPopulationStore::operator=(RuntimeEconomyPopulationStore &&other) {
    if (this == &other) return *this;
    cell_first_page.move_from(other.cell_first_page);
    page_next.move_from(other.page_next);
    page_cell.move_from(other.page_cell);
    free_pages.move_from(other.free_pages);
    active.move_from(other.active);
    reserved.move_from(other.reserved);
    reservation_owner.move_from(other.reservation_owner);
    signature_id.move_from(other.signature_id);
    generation.move_from(other.generation);
    population.move_from(other.population);
    funds.move_from(other.funds);
    epoch_income.move_from(other.epoch_income);
    epoch_expense.move_from(other.epoch_expense);
    epoch_in_kind_income.move_from(other.epoch_in_kind_income);
    income_ema.move_from(other.income_ema);
    epoch_tax_paid.move_from(other.epoch_tax_paid);
    epoch_subsidy_received.move_from(other.epoch_subsidy_received);
    income_baseline_ema.move_from(other.income_baseline_ema);
    needs_satisfaction.move_from(other.needs_satisfaction);
    worst_need_id.move_from(other.worst_need_id);
    composite_satisfaction.move_from(other.composite_satisfaction);
    satisfaction_dims.move_from(other.satisfaction_dims);
    worst_dimension_id.move_from(other.worst_dimension_id);
    flags.move_from(other.flags);
    demography_residual.move_from(other.demography_residual);
    owner_employed.move_from(other.owner_employed);
    employee_employed.move_from(other.employee_employed);
    active_count = other.active_count; high_water_slots = other.high_water_slots; scan_steps = other.scan_steps;
    other.active_count = other.high_water_slots = other.scan_steps = 0;
    return *this;
}


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
        store.cell_first_page.write_scalar(cell, page);
        return;
    }
    int32_t tail = store.cell_first_page[cell];
    while (store.page_next[tail] >= 0) tail = store.page_next[tail];
    store.page_next.write_scalar(tail, page);
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
    epoch_tax_paid.write_scalar(slot, 0);
    epoch_subsidy_received.write_scalar(slot, 0);
    income_baseline_ema.write_scalar(slot, 0);
    needs_satisfaction.write_scalar(slot, static_cast<uint16_t>(Q16_ONE - 1));
    worst_need_id.write_scalar(slot, std::numeric_limits<uint16_t>::max());
    composite_satisfaction.write_scalar(slot, static_cast<uint16_t>(Q16_ONE - 1));
    worst_dimension_id.write_scalar(slot, std::numeric_limits<uint8_t>::max());
    const size_t base = static_cast<size_t>(slot) * static_cast<size_t>(SAT_DIM_COUNT);
    for (int32_t dim = 0; dim < SAT_DIM_COUNT; ++dim) {
        satisfaction_dims.write_scalar(base + static_cast<size_t>(dim), static_cast<uint16_t>(Q16_ONE - 1));
    }
}

int32_t RuntimeEconomyPopulationStore::allocate_page(int32_t cell) {
    int32_t page = -1;
    if (!free_pages.empty()) {
        page = free_pages.back();
        free_pages.pop_back();
        page_cell.write_scalar(page, cell);
        page_next.write_scalar(page, -1);
        const int32_t base = page * COHORT_PAGE_SIZE;
        active.fill_range(base, COHORT_PAGE_SIZE, uint8_t{0});
        reserved.fill_range(base, COHORT_PAGE_SIZE, uint8_t{0});
        reservation_owner.fill_range(base, COHORT_PAGE_SIZE, uint64_t{0});
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
            active.write_scalar(slot, 1);
            signature_id.write_scalar(slot, signature);
            population.write_scalar(slot, 0);
            funds.write_scalar(slot, 0);
            epoch_income.write_scalar(slot, 0);
            epoch_expense.write_scalar(slot, 0);
            epoch_in_kind_income.write_scalar(slot, 0);
            income_ema.write_scalar(slot, 0);
            reset_satisfaction_slot(slot);
            flags.write_scalar(slot, 0);
            demography_residual.write_scalar(slot, 0);
            owner_employed.write_scalar(slot, 0);
            employee_employed.write_scalar(slot, 0);
            ++active_count;
            return slot;
        }
    }
    const int32_t page = allocate_page(cell);
    const int32_t slot = page * COHORT_PAGE_SIZE;
    active.write_scalar(slot, 1);
    signature_id.write_scalar(slot, signature);
    population.write_scalar(slot, 0);
    funds.write_scalar(slot, 0);
    epoch_income.write_scalar(slot, 0);
    epoch_expense.write_scalar(slot, 0);
    epoch_in_kind_income.write_scalar(slot, 0);
    income_ema.write_scalar(slot, 0);
    reset_satisfaction_slot(slot);
    flags.write_scalar(slot, 0);
    demography_residual.write_scalar(slot, 0);
    owner_employed.write_scalar(slot, 0);
    employee_employed.write_scalar(slot, 0);
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
        active.write_scalar(slot, 1);
        signature_id.write_scalar(slot, signature);
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
            reserved.write_scalar(slot, 1);
            reservation_owner.write_scalar(slot, owner);
            signature_id.write_scalar(slot, signature);
            return slot;
        }
    }
    const int32_t page = allocate_page(cell);
    const int32_t slot = page * COHORT_PAGE_SIZE;
    reserved.write_scalar(slot, 1);
    reservation_owner.write_scalar(slot, owner);
    signature_id.write_scalar(slot, signature);
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
    reserved.write_scalar(slot, 0);
    reservation_owner.write_scalar(slot, 0);
    active.write_scalar(slot, 1);
    population.write_scalar(slot, 0);
    funds.write_scalar(slot, 0);
    epoch_income.write_scalar(slot, 0);
    epoch_expense.write_scalar(slot, 0);
    epoch_in_kind_income.write_scalar(slot, 0);
    income_ema.write_scalar(slot, 0);
    reset_satisfaction_slot(slot);
    flags.write_scalar(slot, 0);
    demography_residual.write_scalar(slot, 0);
    owner_employed.write_scalar(slot, 0);
    employee_employed.write_scalar(slot, 0);
    ++active_count;
    return slot;
}

void RuntimeEconomyPopulationStore::release_reserved_slot(
        int32_t slot, uint64_t owner) {
    if (slot < 0 || slot >= static_cast<int32_t>(reserved.size()) ||
        active[slot] != 0 || reserved[slot] == 0 ||
        reservation_owner[slot] != owner) return;
    reserved.write_scalar(slot, 0);
    reservation_owner.write_scalar(slot, 0);
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
    active.write_scalar(slot, 0);
    population.write_scalar(slot, 0);
    funds.write_scalar(slot, 0);
    epoch_income.write_scalar(slot, 0);
    epoch_expense.write_scalar(slot, 0);
    epoch_in_kind_income.write_scalar(slot, 0);
    income_ema.write_scalar(slot, 0);
    reset_satisfaction_slot(slot);
    demography_residual.write_scalar(slot, 0);
    owner_employed.write_scalar(slot, 0);
    employee_employed.write_scalar(slot, 0);
    generation.write_scalar(slot, generation[slot] == std::numeric_limits<uint32_t>::max()
                           ? 1u : generation[slot] + 1u);
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
            if (previous < 0) cell_first_page.write_scalar(cell, next);
            else page_next.write_scalar(previous, next);
            page_next.write_scalar(page, -1);
            page_cell.write_scalar(page, -1);
            free_pages.push_back(page);
        } else {
            previous = page;
        }
        page = next;
    }
}

} // namespace pk

