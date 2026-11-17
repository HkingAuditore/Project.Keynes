#pragma once

#include "economy_tracked_column.h"
#include "economy_tracked_scalar.h"

namespace pk {

// Notable persons (generation-stamped handle slots).
struct EconomyNotablePersonStore {
    ChangeRegistry changes;
    EconomyTrackedColumn<uint8_t> active;
    EconomyTrackedColumn<uint32_t> generation;
    EconomyTrackedColumn<int64_t> stable_id;
    EconomyTrackedColumn<uint64_t> family_handle;
    EconomyTrackedColumn<uint64_t> cohort_handle;
    EconomyTrackedColumn<int32_t> given_name_id;
    EconomyTrackedColumn<uint32_t> name_disambiguator;
    EconomyTrackedColumn<int64_t> notable_since_day;
    EconomyTrackedColumn<uint16_t> flags;
    EconomyTrackedColumn<int64_t> cash_claim;
    EconomyTrackedColumn<int64_t> family_equity_share_q32;
    EconomyTrackedColumn<int64_t> epoch_job_income;
    EconomyTrackedColumn<int64_t> epoch_business_result;
    EconomyTrackedColumn<int64_t> epoch_consumption_expense;
    EconomyTrackedColumn<int64_t> epoch_tax;
    EconomyTrackedColumn<int64_t> income_ema;
    EconomyTrackedColumn<uint16_t> needs_satisfaction;
    EconomyTrackedColumn<uint16_t> worst_need_id;
    EconomyTrackedColumn<uint64_t> building_handle;
    EconomyTrackedColumn<uint8_t> job_kind; // 0=none, 1=owner, 2=employee.
    EconomyTrackedColumn<int32_t> employee_role_index;
    EconomyTrackedColumn<int64_t> job_since_day;
    EconomyTrackedColumn<int32_t> free_indices;
    EconomyTrackedScalar<int64_t> active_count;


    EconomyNotablePersonStore();
    EconomyNotablePersonStore(const EconomyNotablePersonStore &other);
    EconomyNotablePersonStore(EconomyNotablePersonStore &&other);
    EconomyNotablePersonStore &operator=(const EconomyNotablePersonStore &other);
    EconomyNotablePersonStore &operator=(EconomyNotablePersonStore &&other);
    void clear();
    int32_t allocate();
    void release(int32_t index);
    uint64_t handle_for_index(int32_t index) const;
    bool valid_handle(uint64_t handle, int32_t &index_out) const;
    // Canonical field traversal uses the same bindings as the writers.
    template<class Visitor> void visit_registered_columns(Visitor &&visit) const {
        visit(active);
        visit(generation);
        visit(stable_id);
        visit(family_handle);
        visit(cohort_handle);
        visit(given_name_id);
        visit(name_disambiguator);
        visit(notable_since_day);
        visit(flags);
        visit(cash_claim);
        visit(family_equity_share_q32);
        visit(epoch_job_income);
        visit(epoch_business_result);
        visit(epoch_consumption_expense);
        visit(epoch_tax);
        visit(income_ema);
        visit(needs_satisfaction);
        visit(worst_need_id);
        visit(building_handle);
        visit(job_kind);
        visit(employee_role_index);
        visit(job_since_day);
        visit(free_indices);
        visit(active_count.column());
    }

};

// Sparse per-person need rows. Authoritative; the CSR offsets built over them
// are derived and stay NER-local.
struct EconomyPersonNeedState {
    uint64_t person_handle = 0;
    int32_t stable_need_id = -1;
    int64_t desired_period_units = 0;
    uint16_t satisfaction_q16 = 0;
    int64_t attributed_spend = 0;
};

template<class Visitor> void economy_visit_record(const EconomyPersonNeedState &row, Visitor &visit) {
    visit(row.person_handle);
    visit(row.stable_need_id);
    visit(row.desired_period_units);
    visit(row.satisfaction_q16);
    visit(row.attributed_spend);
}

} // namespace pk
