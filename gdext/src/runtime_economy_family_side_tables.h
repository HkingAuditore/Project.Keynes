#pragma once

#include <array>
#include <cstdint>
#include <limits>
#include <vector>

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
    std::vector<uint8_t> active;
    std::vector<uint32_t> generation;
    std::vector<int64_t> stable_id;
    std::vector<uint64_t> family_handle;
    std::vector<uint64_t> cohort_handle;
    std::vector<int32_t> given_name_id;
    std::vector<uint32_t> name_disambiguator;
    std::vector<int64_t> notable_since_day;
    std::vector<uint16_t> flags;
    std::vector<int64_t> cash_claim;
    std::vector<int64_t> family_equity_share_q32;
    std::vector<int64_t> epoch_job_income;
    std::vector<int64_t> epoch_business_result;
    std::vector<int64_t> epoch_consumption_expense;
    std::vector<int64_t> epoch_tax;
    std::vector<int64_t> income_ema;
    std::vector<uint16_t> needs_satisfaction;
    std::vector<uint16_t> worst_need_id;
    std::vector<uint64_t> building_handle;
    std::vector<uint8_t> job_kind; // 0=none, 1=owner, 2=employee.
    std::vector<int32_t> employee_role_index;
    std::vector<int64_t> job_since_day;
    std::vector<int32_t> free_indices;
    int64_t active_count = 0;

    void clear();
    int32_t allocate();
    void release(int32_t index);
    uint64_t handle_for_index(int32_t index) const;
    bool valid_handle(uint64_t handle, int32_t &index_out) const;
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
    std::vector<uint8_t> active;
    std::vector<uint32_t> generation;
    std::vector<uint64_t> family_handle;
    std::vector<int32_t> cell;
    std::vector<int64_t> stable_id;
    std::vector<int64_t> population;
    std::vector<int64_t> cash;
    std::vector<int64_t> building_asset;
    std::vector<int32_t> population_share_q16;
    std::vector<int32_t> cash_share_q16;
    std::vector<int32_t> building_share_q16;
    std::vector<int32_t> score_q16;
    // Population-weighted composite satisfaction of the member cohorts in
    // this cell. Feeds branch-survival review; the prestige formula is
    // deliberately unchanged.
    std::vector<int32_t> satisfaction_q16;
    std::vector<uint8_t> prestige_level;
    std::vector<uint8_t> pending_target_level;
    std::vector<uint8_t> review_streak;
    std::vector<int64_t> last_review_day;
    std::vector<uint32_t> free_indices;

    void clear();
    int32_t allocate();
    void release(int32_t index);
    uint64_t handle_for_index(int32_t index) const;
    bool valid_handle(uint64_t handle, int32_t &index_out) const;
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
    std::vector<uint8_t> active;
    std::vector<uint32_t> generation;
    std::vector<int64_t> stable_id;
    std::vector<uint64_t> country_handle;
    std::vector<uint64_t> family_handle;
    std::vector<int32_t> source_cell;
    std::vector<int32_t> target_cell;
    std::vector<int64_t> departure_day;
    std::vector<int64_t> due_day;
    std::vector<int32_t> route_cost;
    std::vector<int32_t> speed;
    std::vector<uint8_t> state;
    std::vector<int64_t> population;
    std::vector<uint32_t> route_begin;
    std::vector<uint32_t> route_count;
    std::vector<uint32_t> payload_begin;
    std::vector<uint32_t> payload_count;
    std::vector<uint32_t> cargo_begin;
    std::vector<uint32_t> cargo_count;
    std::vector<uint32_t> kit_building_begin;
    std::vector<uint32_t> kit_building_count;
    std::vector<uint64_t> kit_missing_stock_identity;
    std::vector<uint32_t> missing_good_begin;
    std::vector<uint32_t> missing_good_count;
    std::vector<int64_t> effect_transaction_id;
    std::vector<uint64_t> idempotency_key;
    std::vector<int32_t> free_indices;
    int64_t active_count = 0;

    void clear();
    int32_t allocate();
    void release(int32_t index);
    uint64_t handle_for_index(int32_t index) const;
    bool valid_handle(uint64_t handle, int32_t &index_out) const;
};

} // namespace pk
