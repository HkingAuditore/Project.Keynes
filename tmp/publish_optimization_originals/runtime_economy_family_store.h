#pragma once

#include <cstdint>
#include <vector>

namespace pk {

// Phase-2.5.5: live family/person/expedition SoA for the committed ledger mirror.
// ECP ABI8 wire remains the historical packed layout from capture_committed_ledger.
struct RuntimeEconomyFamilyStore {
    static constexpr int32_t kSatDimCount = 8;

    // --- family slot SoA ---
    std::vector<int32_t> family_slot;
    std::vector<uint8_t> family_active;
    std::vector<uint32_t> family_generation;
    std::vector<int64_t> family_stable_id;
    std::vector<int32_t> family_surname_id;
    std::vector<uint32_t> family_surname_disambiguator;
    std::vector<int64_t> family_founded_day;
    std::vector<int32_t> family_home_cell;
    std::vector<int32_t> family_origin_cell;
    std::vector<int32_t> family_origin_ethnicity;
    std::vector<int32_t> family_culture_group_id;
    std::vector<uint32_t> family_split_sequence;
    std::vector<uint16_t> family_decline_reviews;
    std::vector<uint16_t> family_flags;
    // Phase-3: consumption purchase factor (Q16), default Q16_ONE per family.
    std::vector<int32_t> purchase_factor_q16;

    // --- membership SoA ---
    std::vector<uint64_t> membership_family_handle;
    std::vector<uint64_t> membership_cohort_handle;
    std::vector<int64_t> membership_people;
    std::vector<int64_t> membership_cash_claim;
    std::vector<int64_t> membership_population_basis;
    std::vector<int64_t> membership_funds_basis;
    std::vector<int64_t> membership_owner_employed;
    std::vector<int64_t> membership_employee_employed;

    // --- ownership SoA ---
    std::vector<uint64_t> ownership_family_handle;
    std::vector<uint64_t> ownership_building_handle;
    std::vector<int64_t> ownership_owned_count;
    std::vector<int64_t> ownership_filled_owner;

    // --- person slot SoA ---
    std::vector<int32_t> person_slot;
    std::vector<uint8_t> person_active;
    std::vector<uint32_t> person_generation;
    std::vector<int64_t> person_stable_id;
    std::vector<uint64_t> person_family_handle;
    std::vector<uint64_t> person_cohort_handle;
    std::vector<int32_t> person_given_name_id;
    std::vector<uint32_t> person_name_disambiguator;
    std::vector<int64_t> person_notable_since_day;
    std::vector<uint16_t> person_flags;
    std::vector<int64_t> person_cash_claim;
    std::vector<int64_t> person_family_equity_share_q32;
    std::vector<int64_t> person_epoch_job_income;
    std::vector<int64_t> person_epoch_business_result;
    std::vector<int64_t> person_epoch_consumption_expense;
    std::vector<int64_t> person_epoch_tax;
    std::vector<int64_t> person_income_ema;
    std::vector<uint16_t> person_needs_satisfaction;
    std::vector<uint16_t> person_worst_need_id;
    std::vector<uint64_t> person_building_handle;
    std::vector<uint8_t> person_job_kind;
    std::vector<int32_t> person_employee_role_index;
    std::vector<int64_t> person_job_since_day;

    // --- person need SoA ---
    std::vector<uint64_t> need_person_handle;
    std::vector<int32_t> need_stable_need_id;
    std::vector<int64_t> need_desired_period_units;
    std::vector<uint16_t> need_satisfaction_q16;
    std::vector<int64_t> need_attributed_spend;

    // --- trait roll SoA ---
    std::vector<uint64_t> trait_family_handle;
    std::vector<int32_t> trait_trait_id;
    std::vector<int32_t> trait_strength_q16;
    std::vector<uint8_t> trait_core;

    // --- influence slot SoA ---
    std::vector<int32_t> influence_slot;
    std::vector<uint8_t> influence_active;
    std::vector<uint32_t> influence_generation;
    std::vector<uint64_t> influence_family_handle;
    std::vector<int32_t> influence_cell;
    std::vector<int64_t> influence_stable_id;
    std::vector<int64_t> influence_population;
    std::vector<int64_t> influence_cash;
    std::vector<int64_t> influence_building_asset;
    std::vector<int32_t> influence_population_share_q16;
    std::vector<int32_t> influence_cash_share_q16;
    std::vector<int32_t> influence_building_share_q16;
    std::vector<int32_t> influence_score_q16;
    std::vector<int32_t> influence_satisfaction_q16;
    std::vector<uint8_t> influence_prestige_level;
    std::vector<uint8_t> influence_pending_target_level;
    std::vector<uint8_t> influence_review_streak;
    std::vector<int64_t> influence_last_review_day;

    // --- trait command SoA ---
    std::vector<int32_t> command_operation;
    std::vector<uint64_t> command_family_handle;
    std::vector<int32_t> command_trait_id;
    std::vector<int32_t> command_strength_q16;
    std::vector<int64_t> command_effective_day;
    std::vector<int32_t> command_priority;
    std::vector<int64_t> command_sequence;
    std::vector<uint64_t> command_submit_order;

    // --- expedition slot SoA + CSR metadata ---
    std::vector<int32_t> expedition_slot;
    std::vector<uint8_t> expedition_active;
    std::vector<uint32_t> expedition_generation;
    std::vector<int64_t> expedition_stable_id;
    std::vector<uint64_t> expedition_country_handle;
    std::vector<uint64_t> expedition_family_handle;
    std::vector<int32_t> expedition_source_cell;
    std::vector<int32_t> expedition_target_cell;
    std::vector<int64_t> expedition_departure_day;
    std::vector<int64_t> expedition_due_day;
    std::vector<int32_t> expedition_route_cost;
    std::vector<int32_t> expedition_speed;
    std::vector<uint8_t> expedition_state;
    std::vector<int64_t> expedition_population;
    std::vector<int64_t> expedition_effect_transaction_id;
    std::vector<uint64_t> expedition_idempotency_key;
    std::vector<uint32_t> expedition_route_count;
    std::vector<uint32_t> expedition_route_begin;
    std::vector<uint32_t> expedition_payload_count;
    std::vector<uint32_t> expedition_payload_begin;
    std::vector<uint32_t> expedition_cargo_count;
    std::vector<uint32_t> expedition_cargo_begin;
    std::vector<uint32_t> expedition_kit_count;
    std::vector<uint32_t> expedition_kit_begin;
    std::vector<uint64_t> expedition_missing_identity;
    std::vector<uint32_t> expedition_missing_count;
    std::vector<uint32_t> expedition_missing_begin;

    // --- expedition route CSR ---
    std::vector<int32_t> route_cell;
    std::vector<int32_t> route_cost;

    // --- expedition payload lane SoA ---
    std::vector<uint64_t> payload_source_cohort_handle;
    std::vector<int32_t> payload_signature;
    std::vector<int64_t> payload_people;
    std::vector<int64_t> payload_funds;
    std::vector<int64_t> payload_epoch_income;
    std::vector<int64_t> payload_epoch_expense;
    std::vector<int64_t> payload_epoch_in_kind_income;
    std::vector<int64_t> payload_income_ema;
    std::vector<int64_t> payload_epoch_tax_paid;
    std::vector<int64_t> payload_epoch_subsidy_received;
    std::vector<int64_t> payload_income_baseline_ema;
    std::vector<int64_t> payload_demography_residual;
    std::vector<int64_t> payload_cash_claim;
    std::vector<int64_t> payload_owner_employed;
    std::vector<int64_t> payload_employee_employed;
    std::vector<uint16_t> payload_needs_satisfaction;
    std::vector<uint16_t> payload_worst_need_id;
    std::vector<uint16_t> payload_composite_satisfaction;
    std::vector<uint8_t> payload_worst_dimension_id;
    std::vector<uint16_t> payload_satisfaction_dims;
    std::vector<uint32_t> payload_person_count;
    std::vector<uint32_t> payload_person_begin;

    // --- expedition payload person-handle CSR ---
    std::vector<uint64_t> payload_person_handle;

    // --- expedition cargo CSR ---
    std::vector<int32_t> cargo_good_id;
    std::vector<int64_t> cargo_quantity;
    std::vector<uint8_t> cargo_flags;

    // --- expedition kit-building CSR ---
    std::vector<int32_t> kit_type_id;
    std::vector<int64_t> kit_count;

    // --- expedition missing-good CSR ---
    std::vector<int32_t> missing_good_id;
    std::vector<int64_t> missing_quantity;

    void clear() noexcept;
    uint32_t num_families() const noexcept {
        return static_cast<uint32_t>(family_slot.size());
    }
    uint32_t num_memberships() const noexcept {
        return static_cast<uint32_t>(membership_family_handle.size());
    }
    uint32_t num_ownerships() const noexcept {
        return static_cast<uint32_t>(ownership_family_handle.size());
    }
    uint32_t num_persons() const noexcept {
        return static_cast<uint32_t>(person_slot.size());
    }
    uint32_t num_person_needs() const noexcept {
        return static_cast<uint32_t>(need_person_handle.size());
    }
    uint32_t num_traits() const noexcept {
        return static_cast<uint32_t>(trait_family_handle.size());
    }
    uint32_t num_influences() const noexcept {
        return static_cast<uint32_t>(influence_slot.size());
    }
    uint32_t num_trait_commands() const noexcept {
        return static_cast<uint32_t>(command_operation.size());
    }
    uint32_t num_expeditions() const noexcept {
        return static_cast<uint32_t>(expedition_slot.size());
    }
    uint32_t num_routes() const noexcept {
        return static_cast<uint32_t>(route_cell.size());
    }
    uint32_t num_payload_lanes() const noexcept {
        return static_cast<uint32_t>(payload_source_cohort_handle.size());
    }
    uint32_t num_payload_person_handles() const noexcept {
        return static_cast<uint32_t>(payload_person_handle.size());
    }
    uint32_t num_cargo_lines() const noexcept {
        return static_cast<uint32_t>(cargo_good_id.size());
    }
    uint32_t num_kit_buildings() const noexcept {
        return static_cast<uint32_t>(kit_type_id.size());
    }
    uint32_t num_missing_goods() const noexcept {
        return static_cast<uint32_t>(missing_good_id.size());
    }
    bool shape_valid(uint32_t family_count, uint32_t membership_count,
                     uint32_t ownership_count, uint32_t person_count,
                     uint32_t person_need_count, uint32_t trait_count,
                     uint32_t influence_count, uint32_t trait_command_count,
                     uint32_t expedition_count) const noexcept;
    void append_wire(std::vector<uint8_t> &out) const;
    bool load_wire(const uint8_t *data, size_t size, uint32_t family_count,
                   uint32_t membership_count, uint32_t ownership_count,
                   uint32_t person_count, uint32_t person_need_count,
                   uint32_t trait_count, uint32_t influence_count,
                   uint32_t trait_command_count, uint32_t expedition_count);
    uint64_t wire_content_hash() const noexcept;
};

} // namespace pk
