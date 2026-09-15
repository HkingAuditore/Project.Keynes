#include "runtime_economy_building_store.h"

#include <cstring>

namespace pk {
namespace {

constexpr uint64_t kFnvOffset = 1469598103934665603ull;
constexpr uint64_t kFnvPrime = 1099511628211ull;

template <typename T>
void append_pod(std::vector<uint8_t> &out, const T &value) {
    const auto *bytes = reinterpret_cast<const uint8_t *>(&value);
    out.insert(out.end(), bytes, bytes + sizeof(T));
}

template <typename T>
bool read_pod(const uint8_t *&p, const uint8_t *end, T &value) {
    if (static_cast<size_t>(end - p) < sizeof(T)) return false;
    std::memcpy(&value, p, sizeof(T));
    p += sizeof(T);
    return true;
}

template <typename T>
bool column_size(const std::vector<T> &column, size_t expected) {
    return column.size() == expected;
}

} // namespace

void RuntimeEconomyBuildingStore::clear() noexcept {
    cell.clear();
    type_id.clear();
    owner_signature_id.clear();
    employee_fill_begin.clear();
    last_input_selection_begin.clear();
    group_units.clear();
    filled_owner.clear();
    last_capacity_q16.clear();
    last_temperature_fit_q16.clear();
    last_water_fit_q16.clear();
    last_climate_capacity_q16.clear();
    last_climate_lost_output.clear();
    last_input.clear();
    last_output.clear();
    last_sold.clear();
    last_discarded.clear();
    last_resource.clear();
    last_resource_generated.clear();
    last_revenue.clear();
    last_input_cost.clear();
    last_wages_paid.clear();
    last_wages_due.clear();
    last_expected_revenue.clear();
    last_operating_cost.clear();
    last_maintenance_cost.clear();
    last_margin_gap_q16.clear();
    planned_utilization_q16.clear();
    sample_unit_input_cost.clear();
    sample_unit_maintenance_cost.clear();
    last_base_wages_paid.clear();
    last_base_wages_due.clear();
    last_bonus_paid.clear();
    last_bonus_due.clear();
    wage_suspended.clear();
    purchase_intent_capacity_q16.clear();
    realized_profit_margin_q16.clear();
    severe_loss_cycles.clear();
    recovery_cycles.clear();
    operating_state.clear();
    pending_operating_state.clear();
    recovery_cooldown_cycles.clear();
    recovery_failed_reviews.clear();
    merchant_debt_term_cycles_left.clear();
    merchant_debt_delinquent_cycles.clear();
    merchant_debt_principal.clear();
    merchant_debt_premium.clear();
    last_in_kind_livelihood_value.clear();
    last_market_receipt.clear();
    last_bullion_mint_receipt.clear();
    last_producer_support_receipt.clear();
    last_business_tax_paid.clear();
    last_business_subsidy_received.clear();
    last_maintenance_due.clear();
    last_observed_capacity_days_q16.clear();
    last_quoted_market_receipt.clear();
    last_quoted_operating_cost.clear();
    modifier_handle.clear();
    output_factor_q16.clear();
    role_count.clear();
    role_begin.clear();
    role_filled.clear();
    role_contract_wage.clear();
    role_base_living_cost.clear();
    role_living_cost.clear();
    role_local_average_wage.clear();
    role_base_wage_due.clear();
    role_base_wage_paid.clear();
    role_bonus_due.clear();
    role_bonus_paid.clear();
    pending_cell.clear();
    pending_type_id.clear();
    pending_owner_signature_id.clear();
    pending_count.clear();
    pending_ready_day.clear();
    pending_sequence.clear();
    pending_merchant_debt_principal.clear();
    pending_merchant_debt_premium.clear();
    pending_merchant_debt_term_cycles_left.clear();
    pending_sponsor_family_handle.clear();
}

bool RuntimeEconomyBuildingStore::shape_valid(
        uint32_t expected_groups, uint32_t expected_pending,
        uint32_t expected_roles) const noexcept {
    const size_t groups = static_cast<size_t>(expected_groups);
    const size_t pending = static_cast<size_t>(expected_pending);
    const size_t roles = static_cast<size_t>(expected_roles);
    if (!(column_size(cell, groups) && column_size(type_id, groups) &&
          column_size(owner_signature_id, groups) &&
          column_size(employee_fill_begin, groups) &&
          column_size(last_input_selection_begin, groups) &&
          column_size(group_units, groups) && column_size(filled_owner, groups) &&
          column_size(last_capacity_q16, groups) &&
          column_size(last_temperature_fit_q16, groups) &&
          column_size(last_water_fit_q16, groups) &&
          column_size(last_climate_capacity_q16, groups) &&
          column_size(last_climate_lost_output, groups) &&
          column_size(last_input, groups) && column_size(last_output, groups) &&
          column_size(last_sold, groups) && column_size(last_discarded, groups) &&
          column_size(last_resource, groups) &&
          column_size(last_resource_generated, groups) &&
          column_size(last_revenue, groups) &&
          column_size(last_input_cost, groups) &&
          column_size(last_wages_paid, groups) &&
          column_size(last_wages_due, groups) &&
          column_size(last_expected_revenue, groups) &&
          column_size(last_operating_cost, groups) &&
          column_size(last_maintenance_cost, groups) &&
          column_size(last_margin_gap_q16, groups) &&
          column_size(planned_utilization_q16, groups) &&
          column_size(sample_unit_input_cost, groups) &&
          column_size(sample_unit_maintenance_cost, groups) &&
          column_size(last_base_wages_paid, groups) &&
          column_size(last_base_wages_due, groups) &&
          column_size(last_bonus_paid, groups) &&
          column_size(last_bonus_due, groups) &&
          column_size(wage_suspended, groups) &&
          column_size(purchase_intent_capacity_q16, groups) &&
          column_size(realized_profit_margin_q16, groups) &&
          column_size(severe_loss_cycles, groups) &&
          column_size(recovery_cycles, groups) &&
          column_size(operating_state, groups) &&
          column_size(pending_operating_state, groups) &&
          column_size(recovery_cooldown_cycles, groups) &&
          column_size(recovery_failed_reviews, groups) &&
          column_size(merchant_debt_term_cycles_left, groups) &&
          column_size(merchant_debt_delinquent_cycles, groups) &&
          column_size(merchant_debt_principal, groups) &&
          column_size(merchant_debt_premium, groups) &&
          column_size(last_in_kind_livelihood_value, groups) &&
          column_size(last_market_receipt, groups) &&
          column_size(last_bullion_mint_receipt, groups) &&
          column_size(last_producer_support_receipt, groups) &&
          column_size(last_business_tax_paid, groups) &&
          column_size(last_business_subsidy_received, groups) &&
          column_size(last_maintenance_due, groups) &&
          column_size(last_observed_capacity_days_q16, groups) &&
          column_size(last_quoted_market_receipt, groups) &&
          column_size(last_quoted_operating_cost, groups) &&
          column_size(modifier_handle, groups) &&
          column_size(output_factor_q16, groups) &&
          column_size(role_count, groups) && column_size(role_begin, groups))) {
        return false;
    }
    if (!(column_size(role_filled, roles) &&
          column_size(role_contract_wage, roles) &&
          column_size(role_base_living_cost, roles) &&
          column_size(role_living_cost, roles) &&
          column_size(role_local_average_wage, roles) &&
          column_size(role_base_wage_due, roles) &&
          column_size(role_base_wage_paid, roles) &&
          column_size(role_bonus_due, roles) &&
          column_size(role_bonus_paid, roles))) {
        return false;
    }
    if (!(column_size(pending_cell, pending) &&
          column_size(pending_type_id, pending) &&
          column_size(pending_owner_signature_id, pending) &&
          column_size(pending_count, pending) &&
          column_size(pending_ready_day, pending) &&
          column_size(pending_sequence, pending) &&
          column_size(pending_merchant_debt_principal, pending) &&
          column_size(pending_merchant_debt_premium, pending) &&
          column_size(pending_merchant_debt_term_cycles_left, pending) &&
          column_size(pending_sponsor_family_handle, pending))) {
        return false;
    }
    uint32_t role_sum = 0;
    for (size_t i = 0; i < groups; ++i) {
        if (role_count[i] < 0) return false;
        if (role_begin[i] != static_cast<int32_t>(role_sum)) return false;
        role_sum += static_cast<uint32_t>(role_count[i]);
    }
    return role_sum == expected_roles;
}

void RuntimeEconomyBuildingStore::append_wire(
        std::vector<uint8_t> &out) const {
    const size_t groups = cell.size();
    for (size_t g = 0; g < groups; ++g) {
        append_pod(out, cell[g]);
        append_pod(out, type_id[g]);
        append_pod(out, owner_signature_id[g]);
        append_pod(out, group_units[g]);
        append_pod(out, filled_owner[g]);
        append_pod(out, last_capacity_q16[g]);
        append_pod(out, last_temperature_fit_q16[g]);
        append_pod(out, last_water_fit_q16[g]);
        append_pod(out, last_climate_capacity_q16[g]);
        append_pod(out, last_climate_lost_output[g]);
        append_pod(out, last_input[g]);
        append_pod(out, last_output[g]);
        append_pod(out, last_sold[g]);
        append_pod(out, last_discarded[g]);
        append_pod(out, last_resource[g]);
        append_pod(out, last_resource_generated[g]);
        append_pod(out, last_revenue[g]);
        append_pod(out, last_input_cost[g]);
        append_pod(out, last_wages_paid[g]);
        append_pod(out, last_wages_due[g]);
        append_pod(out, last_expected_revenue[g]);
        append_pod(out, last_operating_cost[g]);
        append_pod(out, last_margin_gap_q16[g]);
        append_pod(out, planned_utilization_q16[g]);
        append_pod(out, last_base_wages_paid[g]);
        append_pod(out, last_base_wages_due[g]);
        append_pod(out, last_bonus_paid[g]);
        append_pod(out, last_bonus_due[g]);
        append_pod(out, wage_suspended[g]);
        append_pod(out, purchase_intent_capacity_q16[g]);
        append_pod(out, realized_profit_margin_q16[g]);
        append_pod(out, severe_loss_cycles[g]);
        append_pod(out, recovery_cycles[g]);
        append_pod(out, operating_state[g]);
        append_pod(out, pending_operating_state[g]);
        append_pod(out, recovery_cooldown_cycles[g]);
        append_pod(out, recovery_failed_reviews[g]);
        append_pod(out, merchant_debt_term_cycles_left[g]);
        append_pod(out, merchant_debt_delinquent_cycles[g]);
        append_pod(out, merchant_debt_principal[g]);
        append_pod(out, merchant_debt_premium[g]);
        append_pod(out, last_in_kind_livelihood_value[g]);
        append_pod(out, last_market_receipt[g]);
        append_pod(out, last_bullion_mint_receipt[g]);
        append_pod(out, last_producer_support_receipt[g]);
        append_pod(out, last_business_tax_paid[g]);
        append_pod(out, last_business_subsidy_received[g]);
        append_pod(out, last_maintenance_due[g]);
        append_pod(out, last_observed_capacity_days_q16[g]);
        append_pod(out, last_quoted_market_receipt[g]);
        append_pod(out, last_quoted_operating_cost[g]);
        append_pod(out, role_count[g]);
        const int32_t begin = role_begin[g];
        const int32_t roles = role_count[g];
        for (int32_t r = 0; r < roles; ++r) {
            const size_t index = static_cast<size_t>(begin + r);
            append_pod(out, role_filled[index]);
            append_pod(out, role_contract_wage[index]);
            append_pod(out, role_base_living_cost[index]);
            append_pod(out, role_living_cost[index]);
            append_pod(out, role_local_average_wage[index]);
            append_pod(out, role_base_wage_due[index]);
            append_pod(out, role_base_wage_paid[index]);
            append_pod(out, role_bonus_due[index]);
            append_pod(out, role_bonus_paid[index]);
        }
    }
    const size_t pending = pending_cell.size();
    for (size_t i = 0; i < pending; ++i) {
        append_pod(out, pending_cell[i]);
        append_pod(out, pending_type_id[i]);
        append_pod(out, pending_owner_signature_id[i]);
        append_pod(out, pending_count[i]);
        append_pod(out, pending_ready_day[i]);
        append_pod(out, pending_sequence[i]);
        append_pod(out, pending_merchant_debt_principal[i]);
        append_pod(out, pending_merchant_debt_premium[i]);
        append_pod(out, pending_merchant_debt_term_cycles_left[i]);
        append_pod(out, pending_sponsor_family_handle[i]);
    }
}

bool RuntimeEconomyBuildingStore::load_wire(
        const uint8_t *data, size_t size, uint32_t expected_groups,
        uint32_t expected_pending, uint32_t expected_roles) {
    clear();
    if (data == nullptr && size != 0) return false;
    const uint8_t *p = data;
    const uint8_t *end = data + size;
    cell.reserve(expected_groups);
    role_filled.reserve(expected_roles);
    pending_cell.reserve(expected_pending);
    for (uint32_t g = 0; g < expected_groups; ++g) {
        int32_t v_i32 = 0;
        int64_t v_i64 = 0;
        uint8_t v_u8 = 0;
        uint16_t v_u16 = 0;
        auto push_i32 = [&](std::vector<int32_t> &dst) -> bool {
            if (!read_pod(p, end, v_i32)) return false;
            dst.push_back(v_i32);
            return true;
        };
        auto push_i64 = [&](std::vector<int64_t> &dst) -> bool {
            if (!read_pod(p, end, v_i64)) return false;
            dst.push_back(v_i64);
            return true;
        };
        auto push_u8 = [&](std::vector<uint8_t> &dst) -> bool {
            if (!read_pod(p, end, v_u8)) return false;
            dst.push_back(v_u8);
            return true;
        };
        auto push_u16 = [&](std::vector<uint16_t> &dst) -> bool {
            if (!read_pod(p, end, v_u16)) return false;
            dst.push_back(v_u16);
            return true;
        };
        if (!push_i32(cell) || !push_i32(type_id) ||
            !push_i32(owner_signature_id) || !push_i64(group_units) ||
            !push_i64(filled_owner) || !push_i64(last_capacity_q16) ||
            !push_i64(last_temperature_fit_q16) ||
            !push_i64(last_water_fit_q16) ||
            !push_i64(last_climate_capacity_q16) ||
            !push_i64(last_climate_lost_output) || !push_i64(last_input) ||
            !push_i64(last_output) || !push_i64(last_sold) ||
            !push_i64(last_discarded) || !push_i64(last_resource) ||
            !push_i64(last_resource_generated) || !push_i64(last_revenue) ||
            !push_i64(last_input_cost) || !push_i64(last_wages_paid) ||
            !push_i64(last_wages_due) || !push_i64(last_expected_revenue) ||
            !push_i64(last_operating_cost) || !push_i32(last_margin_gap_q16) ||
            !push_i32(planned_utilization_q16) ||
            !push_i64(last_base_wages_paid) || !push_i64(last_base_wages_due) ||
            !push_i64(last_bonus_paid) || !push_i64(last_bonus_due) ||
            !push_u8(wage_suspended) ||
            !push_i64(purchase_intent_capacity_q16) ||
            !push_i32(realized_profit_margin_q16) ||
            !push_u16(severe_loss_cycles) || !push_u16(recovery_cycles) ||
            !push_u8(operating_state) || !push_u8(pending_operating_state) ||
            !push_u16(recovery_cooldown_cycles) ||
            !push_u16(recovery_failed_reviews) ||
            !push_u16(merchant_debt_term_cycles_left) ||
            !push_u16(merchant_debt_delinquent_cycles) ||
            !push_i64(merchant_debt_principal) ||
            !push_i64(merchant_debt_premium) ||
            !push_i64(last_in_kind_livelihood_value) ||
            !push_i64(last_market_receipt) ||
            !push_i64(last_bullion_mint_receipt) ||
            !push_i64(last_producer_support_receipt) ||
            !push_i64(last_business_tax_paid) ||
            !push_i64(last_business_subsidy_received) ||
            !push_i64(last_maintenance_due) ||
            !push_i64(last_observed_capacity_days_q16) ||
            !push_i64(last_quoted_market_receipt) ||
            !push_i64(last_quoted_operating_cost)) {
            clear();
            return false;
        }
        int32_t roles = 0;
        if (!read_pod(p, end, roles) || roles < 0) {
            clear();
            return false;
        }
        role_count.push_back(roles);
        role_begin.push_back(static_cast<int32_t>(role_filled.size()));
        for (int32_t r = 0; r < roles; ++r) {
            if (!push_i64(role_filled) || !push_i64(role_contract_wage) ||
                !push_i64(role_base_living_cost) ||
                !push_i64(role_living_cost) ||
                !push_i64(role_local_average_wage) ||
                !push_i64(role_base_wage_due) ||
                !push_i64(role_base_wage_paid) || !push_i64(role_bonus_due) ||
                !push_i64(role_bonus_paid)) {
                clear();
                return false;
            }
        }
    }
    for (uint32_t i = 0; i < expected_pending; ++i) {
        int32_t v_i32 = 0;
        int64_t v_i64 = 0;
        uint16_t v_u16 = 0;
        uint64_t v_u64 = 0;
        if (!read_pod(p, end, v_i32)) {
            clear();
            return false;
        }
        pending_cell.push_back(v_i32);
        if (!read_pod(p, end, v_i32)) {
            clear();
            return false;
        }
        pending_type_id.push_back(v_i32);
        if (!read_pod(p, end, v_i32)) {
            clear();
            return false;
        }
        pending_owner_signature_id.push_back(v_i32);
        if (!read_pod(p, end, v_i64)) {
            clear();
            return false;
        }
        pending_count.push_back(v_i64);
        if (!read_pod(p, end, v_i64)) {
            clear();
            return false;
        }
        pending_ready_day.push_back(v_i64);
        if (!read_pod(p, end, v_i64)) {
            clear();
            return false;
        }
        pending_sequence.push_back(v_i64);
        if (!read_pod(p, end, v_i64)) {
            clear();
            return false;
        }
        pending_merchant_debt_principal.push_back(v_i64);
        if (!read_pod(p, end, v_i64)) {
            clear();
            return false;
        }
        pending_merchant_debt_premium.push_back(v_i64);
        if (!read_pod(p, end, v_u16)) {
            clear();
            return false;
        }
        pending_merchant_debt_term_cycles_left.push_back(v_u16);
        if (!read_pod(p, end, v_u64)) {
            clear();
            return false;
        }
        pending_sponsor_family_handle.push_back(v_u64);
    }
    if (p != end) {
        clear();
        return false;
    }
    // ABI7 wire omits live-only AoS columns; default them after unpack.
    const size_t groups = cell.size();
    employee_fill_begin.assign(groups, -1);
    last_input_selection_begin.assign(groups, -1);
    last_maintenance_cost.assign(groups, 0);
    sample_unit_input_cost.assign(groups, 0);
    sample_unit_maintenance_cost.assign(groups, 0);
    modifier_handle.assign(groups, 0);
    output_factor_q16.assign(groups, 65536);
    return shape_valid(expected_groups, expected_pending, expected_roles);
}

uint64_t RuntimeEconomyBuildingStore::wire_content_hash() const noexcept {
    std::vector<uint8_t> wire;
    append_wire(wire);
    uint64_t hash = kFnvOffset;
    for (uint8_t byte : wire) {
        hash ^= byte;
        hash *= kFnvPrime;
    }
    return hash;
}

} // namespace pk
