#include "economy_runtime.h"

#include <algorithm>
#include <cstdint>
#include <limits>

namespace pk {

using namespace godot;

static_assert(NativeEconomyRuntime::COHORT_PAGE_SIZE == RuntimeEconomyPopulationStore::COHORT_PAGE_SIZE);
static_assert(NativeEconomyRuntime::Q16_ONE == RuntimeEconomyPopulationStore::Q16_ONE);
static_assert(NativeEconomyRuntime::SAT_DIM_COUNT == RuntimeEconomyPopulationStore::SAT_DIM_COUNT);

void EconomyNotablePersonStore::clear() {
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

int32_t EconomyNotablePersonStore::allocate() {
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
        income_ema.push_back(0);
        needs_satisfaction.push_back(
            RuntimeEconomyPopulationStore::Q16_ONE - 1);
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
    needs_satisfaction[index] =
        static_cast<uint16_t>(RuntimeEconomyPopulationStore::Q16_ONE - 1);
    worst_need_id[index] = std::numeric_limits<uint16_t>::max();
    building_handle[index] = 0; job_kind[index] = 0;
    employee_role_index[index] = -1; job_since_day[index] = -1;
    ++active_count;
    return index;
}

void EconomyNotablePersonStore::release(int32_t index) {
    if (index < 0 || index >= static_cast<int32_t>(active.size()) || active[index] == 0)
        return;
    active[index] = 0;
    generation[index] = generation[index] == UINT32_MAX ? 1 : generation[index] + 1;
    free_indices.push_back(index);
    --active_count;
}

uint64_t EconomyNotablePersonStore::handle_for_index(int32_t index) const {
    if (index < 0 || index >= static_cast<int32_t>(active.size()) || active[index] == 0)
        return 0;
    return (static_cast<uint64_t>(generation[index]) << 32) |
        static_cast<uint32_t>(index);
}

bool EconomyNotablePersonStore::valid_handle(
        uint64_t handle, int32_t &index_out) const {
    const uint32_t index = static_cast<uint32_t>(handle & 0xffffffffULL);
    const uint32_t gen = static_cast<uint32_t>(handle >> 32);
    if (index >= active.size() || active[index] == 0 || generation[index] != gen)
        return false;
    index_out = static_cast<int32_t>(index);
    return true;
}

} // namespace pk
