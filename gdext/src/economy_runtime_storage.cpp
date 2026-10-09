#include "economy_runtime.h"

#include <algorithm>
#include <cstdint>
#include <limits>

namespace pk {
EconomyNotablePersonStore::EconomyNotablePersonStore()
    : active_count(changes, {{6, 1001}, "person.active_count", EconomyFieldEncoding::I64, 8}, 0),
      active(changes, {{6, 1}, "person.active", EconomyFieldEncoding::U8, 1}),
      generation(changes, {{6, 2}, "person.generation", EconomyFieldEncoding::U32, 4}),
      stable_id(changes, {{6, 3}, "person.stable_id", EconomyFieldEncoding::I64, 8}),
      family_handle(changes, {{6, 4}, "person.family_handle", EconomyFieldEncoding::U64, 8}),
      cohort_handle(changes, {{6, 5}, "person.cohort_handle", EconomyFieldEncoding::U64, 8}),
      given_name_id(changes, {{6, 6}, "person.given_name_id", EconomyFieldEncoding::I32, 4}),
      name_disambiguator(changes, {{6, 7}, "person.name_disambiguator", EconomyFieldEncoding::U32, 4}),
      notable_since_day(changes, {{6, 8}, "person.notable_since_day", EconomyFieldEncoding::I64, 8}),
      flags(changes, {{6, 9}, "person.flags", EconomyFieldEncoding::U16, 2}),
      cash_claim(changes, {{6, 10}, "person.cash_claim", EconomyFieldEncoding::I64, 8}),
      family_equity_share_q32(changes, {{6, 11}, "person.family_equity_share_q32", EconomyFieldEncoding::I64, 8}),
      epoch_job_income(changes, {{6, 12}, "person.epoch_job_income", EconomyFieldEncoding::I64, 8}),
      epoch_business_result(changes, {{6, 13}, "person.epoch_business_result", EconomyFieldEncoding::I64, 8}),
      epoch_consumption_expense(changes, {{6, 14}, "person.epoch_consumption_expense", EconomyFieldEncoding::I64, 8}),
      epoch_tax(changes, {{6, 15}, "person.epoch_tax", EconomyFieldEncoding::I64, 8}),
      income_ema(changes, {{6, 16}, "person.income_ema", EconomyFieldEncoding::I64, 8}),
      needs_satisfaction(changes, {{6, 17}, "person.needs_satisfaction", EconomyFieldEncoding::U16, 2}),
      worst_need_id(changes, {{6, 18}, "person.worst_need_id", EconomyFieldEncoding::U16, 2}),
      building_handle(changes, {{6, 19}, "person.building_handle", EconomyFieldEncoding::U64, 8}),
      job_kind(changes, {{6, 20}, "person.job_kind", EconomyFieldEncoding::U8, 1}),
      employee_role_index(changes, {{6, 21}, "person.employee_role_index", EconomyFieldEncoding::I32, 4}),
      job_since_day(changes, {{6, 22}, "person.job_since_day", EconomyFieldEncoding::I64, 8}),
      free_indices(changes, {{6, 23}, "person.free_indices", EconomyFieldEncoding::I32, 4}) {}
EconomyNotablePersonStore::EconomyNotablePersonStore(const EconomyNotablePersonStore &other)
    : EconomyNotablePersonStore() { *this = other; }
EconomyNotablePersonStore &EconomyNotablePersonStore::operator=(const EconomyNotablePersonStore &other) {
    if (this == &other) return *this;
    active.assign(other.active.values());
    generation.assign(other.generation.values());
    stable_id.assign(other.stable_id.values());
    family_handle.assign(other.family_handle.values());
    cohort_handle.assign(other.cohort_handle.values());
    given_name_id.assign(other.given_name_id.values());
    name_disambiguator.assign(other.name_disambiguator.values());
    notable_since_day.assign(other.notable_since_day.values());
    flags.assign(other.flags.values());
    cash_claim.assign(other.cash_claim.values());
    family_equity_share_q32.assign(other.family_equity_share_q32.values());
    epoch_job_income.assign(other.epoch_job_income.values());
    epoch_business_result.assign(other.epoch_business_result.values());
    epoch_consumption_expense.assign(other.epoch_consumption_expense.values());
    epoch_tax.assign(other.epoch_tax.values());
    income_ema.assign(other.income_ema.values());
    needs_satisfaction.assign(other.needs_satisfaction.values());
    worst_need_id.assign(other.worst_need_id.values());
    building_handle.assign(other.building_handle.values());
    job_kind.assign(other.job_kind.values());
    employee_role_index.assign(other.employee_role_index.values());
    job_since_day.assign(other.job_since_day.values());
    free_indices.assign(other.free_indices.values());
    active_count = other.active_count;
    return *this;
}
EconomyNotablePersonStore::EconomyNotablePersonStore(EconomyNotablePersonStore &&other)
    : EconomyNotablePersonStore() { *this = std::move(other); }
EconomyNotablePersonStore &EconomyNotablePersonStore::operator=(EconomyNotablePersonStore &&other) {
    if (this == &other) return *this;
    active.move_from(other.active);
    generation.move_from(other.generation);
    stable_id.move_from(other.stable_id);
    family_handle.move_from(other.family_handle);
    cohort_handle.move_from(other.cohort_handle);
    given_name_id.move_from(other.given_name_id);
    name_disambiguator.move_from(other.name_disambiguator);
    notable_since_day.move_from(other.notable_since_day);
    flags.move_from(other.flags);
    cash_claim.move_from(other.cash_claim);
    family_equity_share_q32.move_from(other.family_equity_share_q32);
    epoch_job_income.move_from(other.epoch_job_income);
    epoch_business_result.move_from(other.epoch_business_result);
    epoch_consumption_expense.move_from(other.epoch_consumption_expense);
    epoch_tax.move_from(other.epoch_tax);
    income_ema.move_from(other.income_ema);
    needs_satisfaction.move_from(other.needs_satisfaction);
    worst_need_id.move_from(other.worst_need_id);
    building_handle.move_from(other.building_handle);
    job_kind.move_from(other.job_kind);
    employee_role_index.move_from(other.employee_role_index);
    job_since_day.move_from(other.job_since_day);
    free_indices.move_from(other.free_indices);
    active_count = other.active_count;
    other.active_count = 0;
    return *this;
}


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
    active.write_scalar(index, 1); stable_id.write_scalar(index, 0);
    family_handle.write_scalar(index, 0); cohort_handle.write_scalar(index, 0);
    given_name_id.write_scalar(index, -1); name_disambiguator.write_scalar(index, 0);
    notable_since_day.write_scalar(index, -1); flags.write_scalar(index, 0); cash_claim.write_scalar(index, 0);
    family_equity_share_q32.write_scalar(index, 0); epoch_job_income.write_scalar(index, 0);
    epoch_business_result.write_scalar(index, 0); epoch_consumption_expense.write_scalar(index, 0);
    epoch_tax.write_scalar(index, 0); income_ema.write_scalar(index, 0);
    needs_satisfaction.write_scalar(index, static_cast<uint16_t>(RuntimeEconomyPopulationStore::Q16_ONE - 1));
    worst_need_id.write_scalar(index, std::numeric_limits<uint16_t>::max());
    building_handle.write_scalar(index, 0); job_kind.write_scalar(index, 0);
    employee_role_index.write_scalar(index, -1); job_since_day.write_scalar(index, -1);
    ++active_count;
    return index;
}

void EconomyNotablePersonStore::release(int32_t index) {
    if (index < 0 || index >= static_cast<int32_t>(active.size()) || active[index] == 0)
        return;
    active.write_scalar(index, 0);
    generation.write_scalar(index, generation[index] == UINT32_MAX ? 1 : generation[index] + 1);
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
