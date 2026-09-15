#pragma once

#include <cstdint>
#include <vector>

namespace pk {

// Phase-2.5.2: live building SoA for the committed ledger mirror.
// Group scalars + CSR role lanes + pending construction. ECP ABI7 wire remains
// the historical packed layout (group record + nested roles + pending records).
struct RuntimeEconomyBuildingStore {
    // --- group SoA (one row per building group) ---
    std::vector<int32_t> cell;
    std::vector<int32_t> type_id;
    std::vector<int32_t> owner_signature_id;
    std::vector<int32_t> last_input_selection_begin;
    std::vector<int64_t> group_units;
    std::vector<int64_t> filled_owner;
    std::vector<int64_t> last_capacity_q16;
    std::vector<int64_t> last_temperature_fit_q16;
    std::vector<int64_t> last_water_fit_q16;
    std::vector<int64_t> last_climate_capacity_q16;
    std::vector<int64_t> last_climate_lost_output;
    std::vector<int64_t> last_input;
    std::vector<int64_t> last_output;
    std::vector<int64_t> last_sold;
    std::vector<int64_t> last_discarded;
    std::vector<int64_t> last_resource;
    std::vector<int64_t> last_resource_generated;
    std::vector<int64_t> last_revenue;
    std::vector<int64_t> last_input_cost;
    std::vector<int64_t> last_wages_paid;
    std::vector<int64_t> last_wages_due;
    std::vector<int64_t> last_expected_revenue;
    std::vector<int64_t> last_operating_cost;
    std::vector<int64_t> last_maintenance_cost;
    std::vector<int32_t> last_margin_gap_q16;
    std::vector<int32_t> planned_utilization_q16;
    std::vector<int64_t> sample_unit_input_cost;
    std::vector<int64_t> sample_unit_maintenance_cost;
    std::vector<int64_t> last_base_wages_paid;
    std::vector<int64_t> last_base_wages_due;
    std::vector<int64_t> last_bonus_paid;
    std::vector<int64_t> last_bonus_due;
    std::vector<uint8_t> wage_suspended;
    std::vector<int64_t> purchase_intent_capacity_q16;
    std::vector<int32_t> realized_profit_margin_q16;
    std::vector<uint16_t> severe_loss_cycles;
    std::vector<uint16_t> recovery_cycles;
    std::vector<uint8_t> operating_state;
    std::vector<uint8_t> pending_operating_state;
    std::vector<uint16_t> recovery_cooldown_cycles;
    std::vector<uint16_t> recovery_failed_reviews;
    std::vector<uint16_t> merchant_debt_term_cycles_left;
    std::vector<uint16_t> merchant_debt_delinquent_cycles;
    std::vector<int64_t> merchant_debt_principal;
    std::vector<int64_t> merchant_debt_premium;
    std::vector<int64_t> last_in_kind_livelihood_value;
    std::vector<int64_t> last_market_receipt;
    std::vector<int64_t> last_bullion_mint_receipt;
    std::vector<int64_t> last_producer_support_receipt;
    std::vector<int64_t> last_business_tax_paid;
    std::vector<int64_t> last_business_subsidy_received;
    std::vector<int64_t> last_maintenance_due;
    std::vector<int64_t> last_observed_capacity_days_q16;
    std::vector<int64_t> last_quoted_market_receipt;
    std::vector<int64_t> last_quoted_operating_cost;
    std::vector<uint64_t> modifier_handle;
    std::vector<int32_t> output_factor_q16;
    std::vector<int32_t> role_count;
    std::vector<int32_t> role_begin;

    // --- role lane SoA (CSR via role_begin/role_count) ---
    std::vector<int64_t> role_filled;
    std::vector<int64_t> role_contract_wage;
    std::vector<int64_t> role_base_living_cost;
    std::vector<int64_t> role_living_cost;
    std::vector<int64_t> role_local_average_wage;
    std::vector<int64_t> role_base_wage_due;
    std::vector<int64_t> role_base_wage_paid;
    std::vector<int64_t> role_bonus_due;
    std::vector<int64_t> role_bonus_paid;

    // --- pending construction SoA ---
    std::vector<int32_t> pending_cell;
    std::vector<int32_t> pending_type_id;
    std::vector<int32_t> pending_owner_signature_id;
    std::vector<int64_t> pending_count;
    std::vector<int64_t> pending_ready_day;
    std::vector<int64_t> pending_sequence;
    std::vector<int64_t> pending_merchant_debt_principal;
    std::vector<int64_t> pending_merchant_debt_premium;
    std::vector<uint16_t> pending_merchant_debt_term_cycles_left;
    std::vector<uint64_t> pending_sponsor_family_handle;

    void clear() noexcept;
    uint32_t num_groups() const noexcept {
        return static_cast<uint32_t>(cell.size());
    }
    uint32_t num_pending() const noexcept {
        return static_cast<uint32_t>(pending_cell.size());
    }
    uint32_t num_role_lanes() const noexcept {
        return static_cast<uint32_t>(role_filled.size());
    }
    bool shape_valid(uint32_t expected_groups, uint32_t expected_pending,
                     uint32_t expected_roles) const noexcept;
    void append_wire(std::vector<uint8_t> &out) const;
    bool load_wire(const uint8_t *data, size_t size, uint32_t expected_groups,
                   uint32_t expected_pending, uint32_t expected_roles);
    uint64_t wire_content_hash() const noexcept;
};

} // namespace pk
