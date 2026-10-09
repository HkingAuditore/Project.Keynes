#pragma once

#include <array>
#include <cstdint>
#include <limits>
#include <vector>
#include "economy_tracked_column.h"
#include "economy_tracked_scalar.h"

#include "runtime_economy_population_store.h"

namespace pk {

// A+Y N5: live notable-family side tables.
//
// These were nested inside NativeEconomyRuntime. They are freestanding so
// RuntimeEconomyOwnedState can own the live instances; NativeEconomyRuntime
// aliases them through persons_store()/family_memberships()/... whenever a
// formula OwnedState is bound, exactly like population/market/live_families.
//
// Only authoritative mutation targets live here. Derived CSR rebuild caches
// (_family_member_offsets, _person_family_offsets, _person_need_offsets, ...)
// stay NER-local because they are recomputed from these tables at
// FAMILY_COMMIT/PERSON_COMMIT and restore boundaries.
//
// The ECP projection (RuntimeEconomyFamilyStore) remains a separate
// wire-facing mirror packed from these live tables at flush/capture time.

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

struct EconomyFamilyMembershipEdge {
    uint64_t family_handle = 0;
    uint64_t cohort_handle = 0;
    int64_t people = 0;
    int64_t cash_claim = 0;
    int64_t population_basis = 0;
    int64_t funds_basis = 0;
    int64_t owner_employed = 0;
    int64_t employee_employed = 0;
};

struct EconomyFamilyBuildingOwnership {
    uint64_t family_handle = 0;
    uint64_t building_handle = 0;
    int64_t owned_count = 0;
    int64_t filled_owner = 0;
};

struct EconomyFamilyTraitRoll {
    uint64_t family_handle = 0;
    int32_t trait_id = -1;
    int32_t strength_q16 = RuntimeEconomyPopulationStore::Q16_ONE;
    uint8_t core = 0;
};

// Per-cell family branch prestige/influence (generation-stamped handle slots).
struct EconomyFamilyCellInfluenceStore {
    ChangeRegistry changes;
    EconomyTrackedColumn<uint8_t> active;
    EconomyTrackedColumn<uint32_t> generation;
    EconomyTrackedColumn<uint64_t> family_handle;
    EconomyTrackedColumn<int32_t> cell;
    EconomyTrackedColumn<int64_t> stable_id;
    EconomyTrackedColumn<int64_t> population;
    EconomyTrackedColumn<int64_t> cash;
    EconomyTrackedColumn<int64_t> building_asset;
    EconomyTrackedColumn<int32_t> population_share_q16;
    EconomyTrackedColumn<int32_t> cash_share_q16;
    EconomyTrackedColumn<int32_t> building_share_q16;
    EconomyTrackedColumn<int32_t> score_q16;
    // Population-weighted composite satisfaction of the member cohorts in
    // this cell. Feeds branch-survival review; the prestige formula is
    // deliberately unchanged.
    EconomyTrackedColumn<int32_t> satisfaction_q16;
    EconomyTrackedColumn<uint8_t> prestige_level;
    EconomyTrackedColumn<uint8_t> pending_target_level;
    EconomyTrackedColumn<uint8_t> review_streak;
    EconomyTrackedColumn<int64_t> last_review_day;
    EconomyTrackedColumn<uint32_t> free_indices;


    EconomyFamilyCellInfluenceStore();
    EconomyFamilyCellInfluenceStore(const EconomyFamilyCellInfluenceStore &other);
    EconomyFamilyCellInfluenceStore(EconomyFamilyCellInfluenceStore &&other);
    EconomyFamilyCellInfluenceStore &operator=(const EconomyFamilyCellInfluenceStore &other);
    EconomyFamilyCellInfluenceStore &operator=(EconomyFamilyCellInfluenceStore &&other);
    void clear();
    int32_t allocate();
    void release(int32_t index);
    uint64_t handle_for_index(int32_t index) const;
    bool valid_handle(uint64_t handle, int32_t &index_out) const;
    // Canonical field traversal uses the same bindings as the writers.
    template<class Visitor> void visit_registered_columns(Visitor &&visit) const {
        visit(active);
        visit(generation);
        visit(family_handle);
        visit(cell);
        visit(stable_id);
        visit(population);
        visit(cash);
        visit(building_asset);
        visit(population_share_q16);
        visit(cash_share_q16);
        visit(building_share_q16);
        visit(score_q16);
        visit(satisfaction_q16);
        visit(prestige_level);
        visit(pending_target_level);
        visit(review_streak);
        visit(last_review_day);
        visit(free_indices);
    }

};

enum FamilyExpeditionState : uint8_t {
    EXPEDITION_OUTBOUND = 1,
    EXPEDITION_SETTLING = 2,
    EXPEDITION_RETURNING = 3,
    EXPEDITION_PREPARING = 4,
};

struct EconomyFamilyExpeditionPayload {
    uint64_t source_cohort_handle = 0;
    int32_t signature = -1;
    int64_t people = 0;
    int64_t funds = 0;
    int64_t epoch_income = 0;
    int64_t epoch_expense = 0;
    int64_t epoch_in_kind_income = 0;
    int64_t income_ema = 0;
    int64_t epoch_tax_paid = 0;
    int64_t epoch_subsidy_received = 0;
    int64_t income_baseline_ema = 0;
    int64_t demography_residual = 0;
    int64_t cash_claim = 0;
    int64_t owner_employed = 0;
    int64_t employee_employed = 0;
    uint32_t person_begin = 0;
    uint32_t person_count = 0;
    uint16_t needs_satisfaction = 0;
    uint16_t worst_need_id = std::numeric_limits<uint16_t>::max();
    uint16_t composite_satisfaction = 0;
    std::array<uint16_t, RuntimeEconomyPopulationStore::SAT_DIM_COUNT>
        satisfaction_dims{};
    uint8_t worst_dimension_id = 0;
    // Transient lane reservation rebuilt from authoritative payload data.
    int32_t reserved_slot = -1;
};

struct EconomyFamilyExpeditionCargoLine {
    int32_t good_id = -1;
    int64_t quantity = 0;
    uint8_t flags = 0;
};

struct EconomyFamilyExpeditionKitBuilding {
    int32_t type_id = -1;
    int64_t count = 0;
};

// In-flight colonization parties (generation-stamped handle slots). The CSR
// spans index the companion route/payload/cargo/kit/missing-good vectors,
// which move with this store.
struct EconomyFamilyExpeditionStore {
    ChangeRegistry changes;
    EconomyTrackedColumn<uint8_t> active;
    EconomyTrackedColumn<uint32_t> generation;
    EconomyTrackedColumn<int64_t> stable_id;
    EconomyTrackedColumn<uint64_t> country_handle;
    EconomyTrackedColumn<uint64_t> family_handle;
    EconomyTrackedColumn<int32_t> source_cell;
    EconomyTrackedColumn<int32_t> target_cell;
    EconomyTrackedColumn<int64_t> departure_day;
    EconomyTrackedColumn<int64_t> due_day;
    EconomyTrackedColumn<int32_t> route_cost;
    EconomyTrackedColumn<int32_t> speed;
    EconomyTrackedColumn<uint8_t> state;
    EconomyTrackedColumn<int64_t> population;
    EconomyTrackedColumn<uint32_t> route_begin;
    EconomyTrackedColumn<uint32_t> route_count;
    EconomyTrackedColumn<uint32_t> payload_begin;
    EconomyTrackedColumn<uint32_t> payload_count;
    EconomyTrackedColumn<uint32_t> cargo_begin;
    EconomyTrackedColumn<uint32_t> cargo_count;
    EconomyTrackedColumn<uint32_t> kit_building_begin;
    EconomyTrackedColumn<uint32_t> kit_building_count;
    // Fixed at the moment a PREPARING expedition is created.  The UI must
    // not let a later market re-plan change the progress denominator.
    EconomyTrackedColumn<int64_t> kit_bridge_required_units;
    EconomyTrackedColumn<int64_t> kit_material_required_units;
    EconomyTrackedColumn<uint64_t> kit_missing_stock_identity;
    EconomyTrackedColumn<uint32_t> missing_good_begin;
    EconomyTrackedColumn<uint32_t> missing_good_count;
    EconomyTrackedColumn<int64_t> effect_transaction_id;
    EconomyTrackedColumn<uint64_t> idempotency_key;
    EconomyTrackedColumn<int32_t> free_indices;
    EconomyTrackedScalar<int64_t> active_count;


    EconomyFamilyExpeditionStore();
    EconomyFamilyExpeditionStore(const EconomyFamilyExpeditionStore &other);
    EconomyFamilyExpeditionStore(EconomyFamilyExpeditionStore &&other);
    EconomyFamilyExpeditionStore &operator=(const EconomyFamilyExpeditionStore &other);
    EconomyFamilyExpeditionStore &operator=(EconomyFamilyExpeditionStore &&other);
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
        visit(country_handle);
        visit(family_handle);
        visit(source_cell);
        visit(target_cell);
        visit(departure_day);
        visit(due_day);
        visit(route_cost);
        visit(speed);
        visit(state);
        visit(population);
        visit(route_begin);
        visit(route_count);
        visit(payload_begin);
        visit(payload_count);
        visit(cargo_begin);
        visit(cargo_count);
        visit(kit_building_begin);
        visit(kit_building_count);
        visit(kit_bridge_required_units);
        visit(kit_material_required_units);
        visit(kit_missing_stock_identity);
        visit(missing_good_begin);
        visit(missing_good_count);
        visit(effect_transaction_id);
        visit(idempotency_key);
        visit(free_indices);
        visit(active_count.column());
    }

};

// Explicit persisted record fields. Never include padding or reserved_slot.
template<class Visitor> void economy_visit_record(const EconomyFamilyMembershipEdge &row, Visitor &visit) {
    visit(row.family_handle);
    visit(row.cohort_handle);
    visit(row.people);
    visit(row.cash_claim);
    visit(row.population_basis);
    visit(row.funds_basis);
    visit(row.owner_employed);
    visit(row.employee_employed);
}
template<class Visitor> void economy_visit_record(const EconomyFamilyBuildingOwnership &row, Visitor &visit) {
    visit(row.family_handle);
    visit(row.building_handle);
    visit(row.owned_count);
    visit(row.filled_owner);
}
template<class Visitor> void economy_visit_record(const EconomyFamilyTraitRoll &row, Visitor &visit) {
    visit(row.family_handle);
    visit(row.trait_id);
    visit(row.strength_q16);
    visit(row.core);
}
template<class Visitor> void economy_visit_record(const EconomyPersonNeedState &row, Visitor &visit) {
    visit(row.person_handle);
    visit(row.stable_need_id);
    visit(row.desired_period_units);
    visit(row.satisfaction_q16);
    visit(row.attributed_spend);
}
template<class Visitor> void economy_visit_record(const EconomyFamilyExpeditionPayload &row, Visitor &visit) {
    visit(row.source_cohort_handle);
    visit(row.signature);
    visit(row.people);
    visit(row.funds);
    visit(row.epoch_income);
    visit(row.epoch_expense);
    visit(row.epoch_in_kind_income);
    visit(row.income_ema);
    visit(row.epoch_tax_paid);
    visit(row.epoch_subsidy_received);
    visit(row.income_baseline_ema);
    visit(row.demography_residual);
    visit(row.cash_claim);
    visit(row.owner_employed);
    visit(row.employee_employed);
    visit(row.person_begin);
    visit(row.person_count);
    visit(row.needs_satisfaction);
    visit(row.worst_need_id);
    visit(row.composite_satisfaction);
    visit(row.satisfaction_dims);
    visit(row.worst_dimension_id);
}
template<class Visitor> void economy_visit_record(const EconomyFamilyExpeditionCargoLine &row, Visitor &visit) {
    visit(row.good_id);
    visit(row.quantity);
    visit(row.flags);
}
template<class Visitor> void economy_visit_record(const EconomyFamilyExpeditionKitBuilding &row, Visitor &visit) {
    visit(row.type_id);
    visit(row.count);
}

} // namespace pk
