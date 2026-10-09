#pragma once

#include <cstdint>
#include <vector>
#include "economy_tracked_column.h"

namespace pk {

// Phase-2.5.2: live building SoA for the committed ledger mirror.
// Group scalars + CSR role lanes + pending construction. ECP ABI7 wire remains
// the historical packed layout (group record + nested roles + pending records).
struct RuntimeEconomyBuildingStore {
    ChangeRegistry changes;
    // --- group SoA (one row per building group) ---
    EconomyTrackedColumn<int32_t> cell;
    EconomyTrackedColumn<int32_t> type_id;
    EconomyTrackedColumn<int32_t> owner_signature_id;
    // Begin index into the sparse `_building_employee_*` role lanes owned by
    // NativeEconomyRuntime. Distinct from `role_begin`, which is the packed
    // projection used by the ECP wire.
    EconomyTrackedColumn<int32_t> employee_fill_begin;
    EconomyTrackedColumn<int32_t> last_input_selection_begin;
    EconomyTrackedColumn<int64_t> group_units;
    EconomyTrackedColumn<int64_t> filled_owner;
    EconomyTrackedColumn<int64_t> last_capacity_q16;
    EconomyTrackedColumn<int64_t> last_temperature_fit_q16;
    EconomyTrackedColumn<int64_t> last_water_fit_q16;
    EconomyTrackedColumn<int64_t> last_climate_capacity_q16;
    EconomyTrackedColumn<int64_t> last_climate_lost_output;
    EconomyTrackedColumn<int64_t> last_input;
    EconomyTrackedColumn<int64_t> last_output;
    EconomyTrackedColumn<int64_t> last_sold;
    EconomyTrackedColumn<int64_t> last_discarded;
    EconomyTrackedColumn<int64_t> last_resource;
    EconomyTrackedColumn<int64_t> last_resource_generated;
    EconomyTrackedColumn<int64_t> last_revenue;
    EconomyTrackedColumn<int64_t> last_input_cost;
    EconomyTrackedColumn<int64_t> last_wages_paid;
    EconomyTrackedColumn<int64_t> last_wages_due;
    EconomyTrackedColumn<int64_t> last_expected_revenue;
    EconomyTrackedColumn<int64_t> last_operating_cost;
    EconomyTrackedColumn<int64_t> last_maintenance_cost;
    EconomyTrackedColumn<int32_t> last_margin_gap_q16;
    EconomyTrackedColumn<int32_t> planned_utilization_q16;
    EconomyTrackedColumn<int64_t> sample_unit_input_cost;
    EconomyTrackedColumn<int64_t> sample_unit_maintenance_cost;
    EconomyTrackedColumn<int64_t> last_base_wages_paid;
    EconomyTrackedColumn<int64_t> last_base_wages_due;
    EconomyTrackedColumn<int64_t> last_bonus_paid;
    EconomyTrackedColumn<int64_t> last_bonus_due;
    EconomyTrackedColumn<uint8_t> wage_suspended;
    EconomyTrackedColumn<int64_t> purchase_intent_capacity_q16;
    EconomyTrackedColumn<int32_t> realized_profit_margin_q16;
    EconomyTrackedColumn<uint16_t> severe_loss_cycles;
    EconomyTrackedColumn<uint16_t> recovery_cycles;
    EconomyTrackedColumn<uint8_t> operating_state;
    EconomyTrackedColumn<uint8_t> pending_operating_state;
    EconomyTrackedColumn<uint16_t> recovery_cooldown_cycles;
    EconomyTrackedColumn<uint16_t> recovery_failed_reviews;
    EconomyTrackedColumn<uint16_t> merchant_debt_term_cycles_left;
    EconomyTrackedColumn<uint16_t> merchant_debt_delinquent_cycles;
    EconomyTrackedColumn<int64_t> merchant_debt_principal;
    EconomyTrackedColumn<int64_t> merchant_debt_premium;
    EconomyTrackedColumn<int64_t> last_in_kind_livelihood_value;
    EconomyTrackedColumn<int64_t> last_market_receipt;
    EconomyTrackedColumn<int64_t> last_bullion_mint_receipt;
    EconomyTrackedColumn<int64_t> last_producer_support_receipt;
    EconomyTrackedColumn<int64_t> last_business_tax_paid;
    EconomyTrackedColumn<int64_t> last_business_subsidy_received;
    EconomyTrackedColumn<int64_t> last_maintenance_due;
    EconomyTrackedColumn<int64_t> last_observed_capacity_days_q16;
    EconomyTrackedColumn<int64_t> last_quoted_market_receipt;
    EconomyTrackedColumn<int64_t> last_quoted_operating_cost;
    EconomyTrackedColumn<uint64_t> modifier_handle;
    EconomyTrackedColumn<int32_t> output_factor_q16;
    EconomyTrackedColumn<int32_t> role_count;
    EconomyTrackedColumn<int32_t> role_begin;

    // --- role lane SoA (CSR via role_begin/role_count) ---
    EconomyTrackedColumn<int64_t> role_filled;
    EconomyTrackedColumn<int64_t> role_contract_wage;
    EconomyTrackedColumn<int64_t> role_base_living_cost;
    EconomyTrackedColumn<int64_t> role_living_cost;
    EconomyTrackedColumn<int64_t> role_local_average_wage;
    EconomyTrackedColumn<int64_t> role_base_wage_due;
    EconomyTrackedColumn<int64_t> role_base_wage_paid;
    EconomyTrackedColumn<int64_t> role_bonus_due;
    EconomyTrackedColumn<int64_t> role_bonus_paid;

    // --- pending construction SoA ---
    EconomyTrackedColumn<int32_t> pending_cell;
    EconomyTrackedColumn<int32_t> pending_type_id;
    EconomyTrackedColumn<int32_t> pending_owner_signature_id;
    EconomyTrackedColumn<int64_t> pending_count;
    EconomyTrackedColumn<int64_t> pending_ready_day;
    EconomyTrackedColumn<int64_t> pending_sequence;
    EconomyTrackedColumn<int64_t> pending_merchant_debt_principal;
    EconomyTrackedColumn<int64_t> pending_merchant_debt_premium;
    EconomyTrackedColumn<uint16_t> pending_merchant_debt_term_cycles_left;
    EconomyTrackedColumn<uint64_t> pending_sponsor_family_handle;


    RuntimeEconomyBuildingStore();
    RuntimeEconomyBuildingStore(const RuntimeEconomyBuildingStore &other);
    RuntimeEconomyBuildingStore(RuntimeEconomyBuildingStore &&other);
    RuntimeEconomyBuildingStore &operator=(const RuntimeEconomyBuildingStore &other);
    RuntimeEconomyBuildingStore &operator=(RuntimeEconomyBuildingStore &&other);
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
    uint64_t mix_wire_hash(uint64_t hash) const noexcept;

private:
    template <typename Sink> void visit_wire(Sink &out) const;
    // Canonical field traversal uses the same bindings as the writers.
    template<class Visitor> void visit_registered_columns(Visitor &&visit) const {
        visit(cell);
        visit(type_id);
        visit(owner_signature_id);
        visit(employee_fill_begin);
        visit(last_input_selection_begin);
        visit(group_units);
        visit(filled_owner);
        visit(last_capacity_q16);
        visit(last_temperature_fit_q16);
        visit(last_water_fit_q16);
        visit(last_climate_capacity_q16);
        visit(last_climate_lost_output);
        visit(last_input);
        visit(last_output);
        visit(last_sold);
        visit(last_discarded);
        visit(last_resource);
        visit(last_resource_generated);
        visit(last_revenue);
        visit(last_input_cost);
        visit(last_wages_paid);
        visit(last_wages_due);
        visit(last_expected_revenue);
        visit(last_operating_cost);
        visit(last_maintenance_cost);
        visit(last_margin_gap_q16);
        visit(planned_utilization_q16);
        visit(sample_unit_input_cost);
        visit(sample_unit_maintenance_cost);
        visit(last_base_wages_paid);
        visit(last_base_wages_due);
        visit(last_bonus_paid);
        visit(last_bonus_due);
        visit(wage_suspended);
        visit(purchase_intent_capacity_q16);
        visit(realized_profit_margin_q16);
        visit(severe_loss_cycles);
        visit(recovery_cycles);
        visit(operating_state);
        visit(pending_operating_state);
        visit(recovery_cooldown_cycles);
        visit(recovery_failed_reviews);
        visit(merchant_debt_term_cycles_left);
        visit(merchant_debt_delinquent_cycles);
        visit(merchant_debt_principal);
        visit(merchant_debt_premium);
        visit(last_in_kind_livelihood_value);
        visit(last_market_receipt);
        visit(last_bullion_mint_receipt);
        visit(last_producer_support_receipt);
        visit(last_business_tax_paid);
        visit(last_business_subsidy_received);
        visit(last_maintenance_due);
        visit(last_observed_capacity_days_q16);
        visit(last_quoted_market_receipt);
        visit(last_quoted_operating_cost);
        visit(modifier_handle);
        visit(output_factor_q16);
        visit(role_count);
        visit(role_begin);
        visit(role_filled);
        visit(role_contract_wage);
        visit(role_base_living_cost);
        visit(role_living_cost);
        visit(role_local_average_wage);
        visit(role_base_wage_due);
        visit(role_base_wage_paid);
        visit(role_bonus_due);
        visit(role_bonus_paid);
        visit(pending_cell);
        visit(pending_type_id);
        visit(pending_owner_signature_id);
        visit(pending_count);
        visit(pending_ready_day);
        visit(pending_sequence);
        visit(pending_merchant_debt_principal);
        visit(pending_merchant_debt_premium);
        visit(pending_merchant_debt_term_cycles_left);
        visit(pending_sponsor_family_handle);
    }

};

} // namespace pk
