#include "economy_runtime.h"

#include <algorithm>
#include <cstdint>
#include <limits>

namespace pk {

using namespace godot;

void NativeEconomyRuntime::PopulationStore::clear(int32_t cells) {
    cell_first_page.assign(std::max(0, cells), -1);
    page_next.clear();
    page_cell.clear();
    free_pages.clear();
    active.clear();
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

void NativeEconomyRuntime::PopulationStore::reset_satisfaction_slot(int32_t slot) {
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

int32_t NativeEconomyRuntime::PopulationStore::allocate_page(int32_t cell) {
    int32_t page = -1;
    if (!free_pages.empty()) {
        page = free_pages.back();
        free_pages.pop_back();
        page_cell[page] = cell;
        page_next[page] = -1;
        const int32_t base = page * COHORT_PAGE_SIZE;
        std::fill(active.begin() + base, active.begin() + base + COHORT_PAGE_SIZE, uint8_t{0});
    } else {
        page = static_cast<int32_t>(page_next.size());
        page_next.push_back(-1);
        page_cell.push_back(cell);
        const size_t next_size = static_cast<size_t>(page + 1) * COHORT_PAGE_SIZE;
        active.resize(next_size, 0);
        signature_id.resize(next_size, 0);
        generation.resize(next_size, 1);
        population.resize(next_size, 0);
        funds.resize(next_size, 0);
        epoch_income.resize(next_size, 0);
        epoch_expense.resize(next_size, 0);
        epoch_in_kind_income.resize(next_size, 0);
        income_ema.resize(next_size, 0);
        epoch_tax_paid.resize(next_size, 0);
        epoch_subsidy_received.resize(next_size, 0);
        income_baseline_ema.resize(next_size, 0);
        needs_satisfaction.resize(next_size, static_cast<uint16_t>(Q16_ONE - 1));
        worst_need_id.resize(next_size, std::numeric_limits<uint16_t>::max());
        composite_satisfaction.resize(next_size, static_cast<uint16_t>(Q16_ONE - 1));
        satisfaction_dims.resize(next_size * static_cast<size_t>(SAT_DIM_COUNT),
                                 static_cast<uint16_t>(Q16_ONE - 1));
        worst_dimension_id.resize(next_size, std::numeric_limits<uint8_t>::max());
        flags.resize(next_size, 0);
        demography_residual.resize(next_size, 0);
        owner_employed.resize(next_size, 0);
        employee_employed.resize(next_size, 0);
        high_water_slots = static_cast<int64_t>(next_size);
    }
    if (cell_first_page[cell] < 0) {
        cell_first_page[cell] = page;
    } else {
        int32_t tail = cell_first_page[cell];
        while (page_next[tail] >= 0) tail = page_next[tail];
        page_next[tail] = page;
    }
    return page;
}

int32_t NativeEconomyRuntime::PopulationStore::find_signature(int32_t cell,
                                                               uint32_t signature) const {
    int32_t result = -1;
    for_each_in_cell(cell, [&](int32_t slot) {
        ++scan_steps;
        if (result < 0 && signature_id[slot] == signature) result = slot;
    });
    return result;
}

int32_t NativeEconomyRuntime::PopulationStore::allocate_slot(int32_t cell,
                                                              uint32_t signature) {
    if (cell < 0 || cell >= static_cast<int32_t>(cell_first_page.size())) return -1;
    const int32_t existing = find_signature(cell, signature);
    if (existing >= 0) return existing;
    if (cell_first_page[cell] < 0) allocate_page(cell);
    for (int32_t p = cell_first_page[cell]; p >= 0; p = page_next[p]) {
        const int32_t base = p * COHORT_PAGE_SIZE;
        for (int32_t lane = 0; lane < COHORT_PAGE_SIZE; ++lane) {
            const int32_t slot = base + lane;
            if (active[slot] != 0) continue;
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

bool NativeEconomyRuntime::PopulationStore::valid_handle(uint64_t handle,
                                                          int32_t &slot_out) const {
    const uint32_t slot = static_cast<uint32_t>(handle & 0xffffffffULL);
    const uint32_t gen = static_cast<uint32_t>(handle >> 32);
    if (slot >= active.size() || active[slot] == 0 || generation[slot] != gen) return false;
    slot_out = static_cast<int32_t>(slot);
    return true;
}

uint64_t NativeEconomyRuntime::PopulationStore::handle_for_slot(int32_t slot) const {
    if (slot < 0 || slot >= static_cast<int32_t>(generation.size()) || active[slot] == 0)
        return 0;
    return (static_cast<uint64_t>(generation[slot]) << 32) | static_cast<uint32_t>(slot);
}

void NativeEconomyRuntime::PopulationStore::release_slot(int32_t slot) {
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

void NativeEconomyRuntime::PopulationStore::reclaim_empty_pages(int32_t cell) {
    if (cell < 0 || cell >= static_cast<int32_t>(cell_first_page.size())) return;
    int32_t previous = -1;
    int32_t page = cell_first_page[cell];
    while (page >= 0) {
        const int32_t next = page_next[page];
        const int32_t base = page * COHORT_PAGE_SIZE;
        bool any = false;
        for (int32_t lane = 0; lane < COHORT_PAGE_SIZE; ++lane)
            any |= active[base + lane] != 0;
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

void NativeEconomyRuntime::FamilyStore::clear() {
    active.clear(); generation.clear(); stable_id.clear(); surname_id.clear();
    surname_disambiguator.clear(); founded_day.clear(); home_cell.clear();
    origin_ethnicity.clear(); decline_reviews.clear(); flags.clear();
    free_indices.clear(); active_count = 0;
}

int32_t NativeEconomyRuntime::FamilyStore::allocate() {
    int32_t index = -1;
    if (!free_indices.empty()) {
        const auto reusable = std::min_element(free_indices.begin(), free_indices.end());
        index = *reusable;
        free_indices.erase(reusable);
    } else {
        index = static_cast<int32_t>(active.size());
        active.push_back(0); generation.push_back(1); stable_id.push_back(0);
        surname_id.push_back(-1); surname_disambiguator.push_back(0);
        founded_day.push_back(-1); home_cell.push_back(-1);
        origin_ethnicity.push_back(-1); decline_reviews.push_back(0);
        flags.push_back(0);
    }
    active[index] = 1;
    stable_id[index] = 0; surname_id[index] = -1;
    surname_disambiguator[index] = 0; founded_day[index] = -1;
    home_cell[index] = -1; origin_ethnicity[index] = -1;
    decline_reviews[index] = 0; flags[index] = 0;
    ++active_count;
    return index;
}

void NativeEconomyRuntime::FamilyStore::release(int32_t index) {
    if (index < 0 || index >= static_cast<int32_t>(active.size()) || active[index] == 0)
        return;
    active[index] = 0;
    generation[index] = generation[index] == UINT32_MAX ? 1 : generation[index] + 1;
    free_indices.push_back(index);
    --active_count;
}

uint64_t NativeEconomyRuntime::FamilyStore::handle_for_index(int32_t index) const {
    if (index < 0 || index >= static_cast<int32_t>(active.size()) || active[index] == 0)
        return 0;
    return (static_cast<uint64_t>(generation[index]) << 32) |
        static_cast<uint32_t>(index);
}

bool NativeEconomyRuntime::FamilyStore::valid_handle(uint64_t handle,
                                                      int32_t &index_out) const {
    const uint32_t index = static_cast<uint32_t>(handle & 0xffffffffULL);
    const uint32_t gen = static_cast<uint32_t>(handle >> 32);
    if (index >= active.size() || active[index] == 0 || generation[index] != gen)
        return false;
    index_out = static_cast<int32_t>(index);
    return true;
}

void NativeEconomyRuntime::NotablePersonStore::clear() {
    active.clear(); generation.clear(); stable_id.clear();
    family_handle.clear(); cohort_handle.clear(); given_name_id.clear();
    name_disambiguator.clear(); notable_since_day.clear(); flags.clear();
    cash_claim.clear(); family_equity_share_q32.clear();
    epoch_job_income.clear(); epoch_business_result.clear();
    epoch_consumption_expense.clear(); epoch_tax.clear(); income_ema.clear();
    needs_satisfaction.clear(); worst_need_id.clear(); building_handle.clear();
    job_kind.clear(); employee_role_index.clear(); job_since_day.clear();
    free_indices.clear(); active_count = 0;
}

int32_t NativeEconomyRuntime::NotablePersonStore::allocate() {
    int32_t index = -1;
    if (!free_indices.empty()) {
        const auto reusable = std::min_element(free_indices.begin(), free_indices.end());
        index = *reusable;
        free_indices.erase(reusable);
    } else {
        index = static_cast<int32_t>(active.size());
        active.push_back(0); generation.push_back(1); stable_id.push_back(0);
        family_handle.push_back(0); cohort_handle.push_back(0);
        given_name_id.push_back(-1); name_disambiguator.push_back(0);
        notable_since_day.push_back(-1); flags.push_back(0);
        cash_claim.push_back(0); family_equity_share_q32.push_back(0);
        epoch_job_income.push_back(0); epoch_business_result.push_back(0);
        epoch_consumption_expense.push_back(0); epoch_tax.push_back(0);
        income_ema.push_back(0); needs_satisfaction.push_back(Q16_ONE - 1);
        worst_need_id.push_back(std::numeric_limits<uint16_t>::max());
        building_handle.push_back(0); job_kind.push_back(0);
        employee_role_index.push_back(-1); job_since_day.push_back(-1);
    }
    active[index] = 1; stable_id[index] = 0;
    family_handle[index] = 0; cohort_handle[index] = 0;
    given_name_id[index] = -1; name_disambiguator[index] = 0;
    notable_since_day[index] = -1; flags[index] = 0; cash_claim[index] = 0;
    family_equity_share_q32[index] = 0; epoch_job_income[index] = 0;
    epoch_business_result[index] = 0; epoch_consumption_expense[index] = 0;
    epoch_tax[index] = 0; income_ema[index] = 0;
    needs_satisfaction[index] = static_cast<uint16_t>(Q16_ONE - 1);
    worst_need_id[index] = std::numeric_limits<uint16_t>::max();
    building_handle[index] = 0; job_kind[index] = 0;
    employee_role_index[index] = -1; job_since_day[index] = -1;
    ++active_count;
    return index;
}

void NativeEconomyRuntime::NotablePersonStore::release(int32_t index) {
    if (index < 0 || index >= static_cast<int32_t>(active.size()) || active[index] == 0)
        return;
    active[index] = 0;
    generation[index] = generation[index] == UINT32_MAX ? 1 : generation[index] + 1;
    free_indices.push_back(index);
    --active_count;
}

uint64_t NativeEconomyRuntime::NotablePersonStore::handle_for_index(int32_t index) const {
    if (index < 0 || index >= static_cast<int32_t>(active.size()) || active[index] == 0)
        return 0;
    return (static_cast<uint64_t>(generation[index]) << 32) |
        static_cast<uint32_t>(index);
}

bool NativeEconomyRuntime::NotablePersonStore::valid_handle(
        uint64_t handle, int32_t &index_out) const {
    const uint32_t index = static_cast<uint32_t>(handle & 0xffffffffULL);
    const uint32_t gen = static_cast<uint32_t>(handle >> 32);
    if (index >= active.size() || active[index] == 0 || generation[index] != gen)
        return false;
    index_out = static_cast<int32_t>(index);
    return true;
}

void NativeEconomyRuntime::MarketStore::clear() {
    market_count = 0;
    good_count = 0;
    stock.clear();
    price.clear();
    demand_ema.clear();
    last_shortage_q16.clear();
    cell_to_market.clear();
}

} // namespace pk
