#include "runtime_economy_building_store.h"

#include <cstring>
#include "economy_wire_sink.h"

namespace pk {
RuntimeEconomyBuildingStore::RuntimeEconomyBuildingStore()
    : cell(changes, {{4, 1}, "building.cell", EconomyFieldEncoding::I32, 4}),
      type_id(changes, {{4, 2}, "building.type_id", EconomyFieldEncoding::I32, 4}),
      owner_signature_id(changes, {{4, 3}, "building.owner_signature_id", EconomyFieldEncoding::I32, 4}),
      employee_fill_begin(changes, {{4, 4}, "building.employee_fill_begin", EconomyFieldEncoding::I32, 4}),
      last_input_selection_begin(changes, {{4, 5}, "building.last_input_selection_begin", EconomyFieldEncoding::I32, 4}),
      group_units(changes, {{4, 6}, "building.group_units", EconomyFieldEncoding::I64, 8}),
      filled_owner(changes, {{4, 7}, "building.filled_owner", EconomyFieldEncoding::I64, 8}),
      last_capacity_q16(changes, {{4, 8}, "building.last_capacity_q16", EconomyFieldEncoding::I64, 8}),
      last_temperature_fit_q16(changes, {{4, 9}, "building.last_temperature_fit_q16", EconomyFieldEncoding::I64, 8}),
      last_water_fit_q16(changes, {{4, 10}, "building.last_water_fit_q16", EconomyFieldEncoding::I64, 8}),
      last_climate_capacity_q16(changes, {{4, 11}, "building.last_climate_capacity_q16", EconomyFieldEncoding::I64, 8}),
      last_climate_lost_output(changes, {{4, 12}, "building.last_climate_lost_output", EconomyFieldEncoding::I64, 8}),
      last_input(changes, {{4, 13}, "building.last_input", EconomyFieldEncoding::I64, 8}),
      last_output(changes, {{4, 14}, "building.last_output", EconomyFieldEncoding::I64, 8}),
      last_sold(changes, {{4, 15}, "building.last_sold", EconomyFieldEncoding::I64, 8}),
      last_discarded(changes, {{4, 16}, "building.last_discarded", EconomyFieldEncoding::I64, 8}),
      last_resource(changes, {{4, 17}, "building.last_resource", EconomyFieldEncoding::I64, 8}),
      last_resource_generated(changes, {{4, 18}, "building.last_resource_generated", EconomyFieldEncoding::I64, 8}),
      last_revenue(changes, {{4, 19}, "building.last_revenue", EconomyFieldEncoding::I64, 8}),
      last_input_cost(changes, {{4, 20}, "building.last_input_cost", EconomyFieldEncoding::I64, 8}),
      last_wages_paid(changes, {{4, 21}, "building.last_wages_paid", EconomyFieldEncoding::I64, 8}),
      last_wages_due(changes, {{4, 22}, "building.last_wages_due", EconomyFieldEncoding::I64, 8}),
      last_expected_revenue(changes, {{4, 23}, "building.last_expected_revenue", EconomyFieldEncoding::I64, 8}),
      last_operating_cost(changes, {{4, 24}, "building.last_operating_cost", EconomyFieldEncoding::I64, 8}),
      last_maintenance_cost(changes, {{4, 25}, "building.last_maintenance_cost", EconomyFieldEncoding::I64, 8}),
      last_margin_gap_q16(changes, {{4, 26}, "building.last_margin_gap_q16", EconomyFieldEncoding::I32, 4}),
      planned_utilization_q16(changes, {{4, 27}, "building.planned_utilization_q16", EconomyFieldEncoding::I32, 4}),
      sample_unit_input_cost(changes, {{4, 28}, "building.sample_unit_input_cost", EconomyFieldEncoding::I64, 8}),
      sample_unit_maintenance_cost(changes, {{4, 29}, "building.sample_unit_maintenance_cost", EconomyFieldEncoding::I64, 8}),
      last_base_wages_paid(changes, {{4, 30}, "building.last_base_wages_paid", EconomyFieldEncoding::I64, 8}),
      last_base_wages_due(changes, {{4, 31}, "building.last_base_wages_due", EconomyFieldEncoding::I64, 8}),
      last_bonus_paid(changes, {{4, 32}, "building.last_bonus_paid", EconomyFieldEncoding::I64, 8}),
      last_bonus_due(changes, {{4, 33}, "building.last_bonus_due", EconomyFieldEncoding::I64, 8}),
      wage_suspended(changes, {{4, 34}, "building.wage_suspended", EconomyFieldEncoding::U8, 1}),
      purchase_intent_capacity_q16(changes, {{4, 35}, "building.purchase_intent_capacity_q16", EconomyFieldEncoding::I64, 8}),
      realized_profit_margin_q16(changes, {{4, 36}, "building.realized_profit_margin_q16", EconomyFieldEncoding::I32, 4}),
      severe_loss_cycles(changes, {{4, 37}, "building.severe_loss_cycles", EconomyFieldEncoding::U16, 2}),
      recovery_cycles(changes, {{4, 38}, "building.recovery_cycles", EconomyFieldEncoding::U16, 2}),
      operating_state(changes, {{4, 39}, "building.operating_state", EconomyFieldEncoding::U8, 1}),
      pending_operating_state(changes, {{4, 40}, "building.pending_operating_state", EconomyFieldEncoding::U8, 1}),
      recovery_cooldown_cycles(changes, {{4, 41}, "building.recovery_cooldown_cycles", EconomyFieldEncoding::U16, 2}),
      recovery_failed_reviews(changes, {{4, 42}, "building.recovery_failed_reviews", EconomyFieldEncoding::U16, 2}),
      merchant_debt_term_cycles_left(changes, {{4, 43}, "building.merchant_debt_term_cycles_left", EconomyFieldEncoding::U16, 2}),
      merchant_debt_delinquent_cycles(changes, {{4, 44}, "building.merchant_debt_delinquent_cycles", EconomyFieldEncoding::U16, 2}),
      merchant_debt_principal(changes, {{4, 45}, "building.merchant_debt_principal", EconomyFieldEncoding::I64, 8}),
      merchant_debt_premium(changes, {{4, 46}, "building.merchant_debt_premium", EconomyFieldEncoding::I64, 8}),
      last_in_kind_livelihood_value(changes, {{4, 47}, "building.last_in_kind_livelihood_value", EconomyFieldEncoding::I64, 8}),
      last_market_receipt(changes, {{4, 48}, "building.last_market_receipt", EconomyFieldEncoding::I64, 8}),
      last_bullion_mint_receipt(changes, {{4, 49}, "building.last_bullion_mint_receipt", EconomyFieldEncoding::I64, 8}),
      last_producer_support_receipt(changes, {{4, 50}, "building.last_producer_support_receipt", EconomyFieldEncoding::I64, 8}),
      last_business_tax_paid(changes, {{4, 51}, "building.last_business_tax_paid", EconomyFieldEncoding::I64, 8}),
      last_business_subsidy_received(changes, {{4, 52}, "building.last_business_subsidy_received", EconomyFieldEncoding::I64, 8}),
      last_maintenance_due(changes, {{4, 53}, "building.last_maintenance_due", EconomyFieldEncoding::I64, 8}),
      last_observed_capacity_days_q16(changes, {{4, 54}, "building.last_observed_capacity_days_q16", EconomyFieldEncoding::I64, 8}),
      last_quoted_market_receipt(changes, {{4, 55}, "building.last_quoted_market_receipt", EconomyFieldEncoding::I64, 8}),
      last_quoted_operating_cost(changes, {{4, 56}, "building.last_quoted_operating_cost", EconomyFieldEncoding::I64, 8}),
      modifier_handle(changes, {{4, 57}, "building.modifier_handle", EconomyFieldEncoding::U64, 8}),
      output_factor_q16(changes, {{4, 58}, "building.output_factor_q16", EconomyFieldEncoding::I32, 4}),
      role_count(changes, {{4, 59}, "building.role_count", EconomyFieldEncoding::I32, 4}),
      role_begin(changes, {{4, 60}, "building.role_begin", EconomyFieldEncoding::I32, 4}),
      role_filled(changes, {{4, 61}, "building.role_filled", EconomyFieldEncoding::I64, 8}),
      role_contract_wage(changes, {{4, 62}, "building.role_contract_wage", EconomyFieldEncoding::I64, 8}),
      role_base_living_cost(changes, {{4, 63}, "building.role_base_living_cost", EconomyFieldEncoding::I64, 8}),
      role_living_cost(changes, {{4, 64}, "building.role_living_cost", EconomyFieldEncoding::I64, 8}),
      role_local_average_wage(changes, {{4, 65}, "building.role_local_average_wage", EconomyFieldEncoding::I64, 8}),
      role_base_wage_due(changes, {{4, 66}, "building.role_base_wage_due", EconomyFieldEncoding::I64, 8}),
      role_base_wage_paid(changes, {{4, 67}, "building.role_base_wage_paid", EconomyFieldEncoding::I64, 8}),
      role_bonus_due(changes, {{4, 68}, "building.role_bonus_due", EconomyFieldEncoding::I64, 8}),
      role_bonus_paid(changes, {{4, 69}, "building.role_bonus_paid", EconomyFieldEncoding::I64, 8}),
      pending_cell(changes, {{4, 70}, "building.pending_cell", EconomyFieldEncoding::I32, 4}),
      pending_type_id(changes, {{4, 71}, "building.pending_type_id", EconomyFieldEncoding::I32, 4}),
      pending_owner_signature_id(changes, {{4, 72}, "building.pending_owner_signature_id", EconomyFieldEncoding::I32, 4}),
      pending_count(changes, {{4, 73}, "building.pending_count", EconomyFieldEncoding::I64, 8}),
      pending_ready_day(changes, {{4, 74}, "building.pending_ready_day", EconomyFieldEncoding::I64, 8}),
      pending_sequence(changes, {{4, 75}, "building.pending_sequence", EconomyFieldEncoding::I64, 8}),
      pending_merchant_debt_principal(changes, {{4, 76}, "building.pending_merchant_debt_principal", EconomyFieldEncoding::I64, 8}),
      pending_merchant_debt_premium(changes, {{4, 77}, "building.pending_merchant_debt_premium", EconomyFieldEncoding::I64, 8}),
      pending_merchant_debt_term_cycles_left(changes, {{4, 78}, "building.pending_merchant_debt_term_cycles_left", EconomyFieldEncoding::U16, 2}),
      pending_sponsor_family_handle(changes, {{4, 79}, "building.pending_sponsor_family_handle", EconomyFieldEncoding::U64, 8}) {}
RuntimeEconomyBuildingStore::RuntimeEconomyBuildingStore(const RuntimeEconomyBuildingStore &other)
    : RuntimeEconomyBuildingStore() { *this = other; }
RuntimeEconomyBuildingStore &RuntimeEconomyBuildingStore::operator=(const RuntimeEconomyBuildingStore &other) {
    if (this == &other) return *this;
    cell.assign(other.cell.values());
    type_id.assign(other.type_id.values());
    owner_signature_id.assign(other.owner_signature_id.values());
    employee_fill_begin.assign(other.employee_fill_begin.values());
    last_input_selection_begin.assign(other.last_input_selection_begin.values());
    group_units.assign(other.group_units.values());
    filled_owner.assign(other.filled_owner.values());
    last_capacity_q16.assign(other.last_capacity_q16.values());
    last_temperature_fit_q16.assign(other.last_temperature_fit_q16.values());
    last_water_fit_q16.assign(other.last_water_fit_q16.values());
    last_climate_capacity_q16.assign(other.last_climate_capacity_q16.values());
    last_climate_lost_output.assign(other.last_climate_lost_output.values());
    last_input.assign(other.last_input.values());
    last_output.assign(other.last_output.values());
    last_sold.assign(other.last_sold.values());
    last_discarded.assign(other.last_discarded.values());
    last_resource.assign(other.last_resource.values());
    last_resource_generated.assign(other.last_resource_generated.values());
    last_revenue.assign(other.last_revenue.values());
    last_input_cost.assign(other.last_input_cost.values());
    last_wages_paid.assign(other.last_wages_paid.values());
    last_wages_due.assign(other.last_wages_due.values());
    last_expected_revenue.assign(other.last_expected_revenue.values());
    last_operating_cost.assign(other.last_operating_cost.values());
    last_maintenance_cost.assign(other.last_maintenance_cost.values());
    last_margin_gap_q16.assign(other.last_margin_gap_q16.values());
    planned_utilization_q16.assign(other.planned_utilization_q16.values());
    sample_unit_input_cost.assign(other.sample_unit_input_cost.values());
    sample_unit_maintenance_cost.assign(other.sample_unit_maintenance_cost.values());
    last_base_wages_paid.assign(other.last_base_wages_paid.values());
    last_base_wages_due.assign(other.last_base_wages_due.values());
    last_bonus_paid.assign(other.last_bonus_paid.values());
    last_bonus_due.assign(other.last_bonus_due.values());
    wage_suspended.assign(other.wage_suspended.values());
    purchase_intent_capacity_q16.assign(other.purchase_intent_capacity_q16.values());
    realized_profit_margin_q16.assign(other.realized_profit_margin_q16.values());
    severe_loss_cycles.assign(other.severe_loss_cycles.values());
    recovery_cycles.assign(other.recovery_cycles.values());
    operating_state.assign(other.operating_state.values());
    pending_operating_state.assign(other.pending_operating_state.values());
    recovery_cooldown_cycles.assign(other.recovery_cooldown_cycles.values());
    recovery_failed_reviews.assign(other.recovery_failed_reviews.values());
    merchant_debt_term_cycles_left.assign(other.merchant_debt_term_cycles_left.values());
    merchant_debt_delinquent_cycles.assign(other.merchant_debt_delinquent_cycles.values());
    merchant_debt_principal.assign(other.merchant_debt_principal.values());
    merchant_debt_premium.assign(other.merchant_debt_premium.values());
    last_in_kind_livelihood_value.assign(other.last_in_kind_livelihood_value.values());
    last_market_receipt.assign(other.last_market_receipt.values());
    last_bullion_mint_receipt.assign(other.last_bullion_mint_receipt.values());
    last_producer_support_receipt.assign(other.last_producer_support_receipt.values());
    last_business_tax_paid.assign(other.last_business_tax_paid.values());
    last_business_subsidy_received.assign(other.last_business_subsidy_received.values());
    last_maintenance_due.assign(other.last_maintenance_due.values());
    last_observed_capacity_days_q16.assign(other.last_observed_capacity_days_q16.values());
    last_quoted_market_receipt.assign(other.last_quoted_market_receipt.values());
    last_quoted_operating_cost.assign(other.last_quoted_operating_cost.values());
    modifier_handle.assign(other.modifier_handle.values());
    output_factor_q16.assign(other.output_factor_q16.values());
    role_count.assign(other.role_count.values());
    role_begin.assign(other.role_begin.values());
    role_filled.assign(other.role_filled.values());
    role_contract_wage.assign(other.role_contract_wage.values());
    role_base_living_cost.assign(other.role_base_living_cost.values());
    role_living_cost.assign(other.role_living_cost.values());
    role_local_average_wage.assign(other.role_local_average_wage.values());
    role_base_wage_due.assign(other.role_base_wage_due.values());
    role_base_wage_paid.assign(other.role_base_wage_paid.values());
    role_bonus_due.assign(other.role_bonus_due.values());
    role_bonus_paid.assign(other.role_bonus_paid.values());
    pending_cell.assign(other.pending_cell.values());
    pending_type_id.assign(other.pending_type_id.values());
    pending_owner_signature_id.assign(other.pending_owner_signature_id.values());
    pending_count.assign(other.pending_count.values());
    pending_ready_day.assign(other.pending_ready_day.values());
    pending_sequence.assign(other.pending_sequence.values());
    pending_merchant_debt_principal.assign(other.pending_merchant_debt_principal.values());
    pending_merchant_debt_premium.assign(other.pending_merchant_debt_premium.values());
    pending_merchant_debt_term_cycles_left.assign(other.pending_merchant_debt_term_cycles_left.values());
    pending_sponsor_family_handle.assign(other.pending_sponsor_family_handle.values());
    return *this;
}
RuntimeEconomyBuildingStore::RuntimeEconomyBuildingStore(RuntimeEconomyBuildingStore &&other)
    : RuntimeEconomyBuildingStore() { *this = std::move(other); }
RuntimeEconomyBuildingStore &RuntimeEconomyBuildingStore::operator=(RuntimeEconomyBuildingStore &&other) {
    if (this == &other) return *this;
    cell.move_from(other.cell);
    type_id.move_from(other.type_id);
    owner_signature_id.move_from(other.owner_signature_id);
    employee_fill_begin.move_from(other.employee_fill_begin);
    last_input_selection_begin.move_from(other.last_input_selection_begin);
    group_units.move_from(other.group_units);
    filled_owner.move_from(other.filled_owner);
    last_capacity_q16.move_from(other.last_capacity_q16);
    last_temperature_fit_q16.move_from(other.last_temperature_fit_q16);
    last_water_fit_q16.move_from(other.last_water_fit_q16);
    last_climate_capacity_q16.move_from(other.last_climate_capacity_q16);
    last_climate_lost_output.move_from(other.last_climate_lost_output);
    last_input.move_from(other.last_input);
    last_output.move_from(other.last_output);
    last_sold.move_from(other.last_sold);
    last_discarded.move_from(other.last_discarded);
    last_resource.move_from(other.last_resource);
    last_resource_generated.move_from(other.last_resource_generated);
    last_revenue.move_from(other.last_revenue);
    last_input_cost.move_from(other.last_input_cost);
    last_wages_paid.move_from(other.last_wages_paid);
    last_wages_due.move_from(other.last_wages_due);
    last_expected_revenue.move_from(other.last_expected_revenue);
    last_operating_cost.move_from(other.last_operating_cost);
    last_maintenance_cost.move_from(other.last_maintenance_cost);
    last_margin_gap_q16.move_from(other.last_margin_gap_q16);
    planned_utilization_q16.move_from(other.planned_utilization_q16);
    sample_unit_input_cost.move_from(other.sample_unit_input_cost);
    sample_unit_maintenance_cost.move_from(other.sample_unit_maintenance_cost);
    last_base_wages_paid.move_from(other.last_base_wages_paid);
    last_base_wages_due.move_from(other.last_base_wages_due);
    last_bonus_paid.move_from(other.last_bonus_paid);
    last_bonus_due.move_from(other.last_bonus_due);
    wage_suspended.move_from(other.wage_suspended);
    purchase_intent_capacity_q16.move_from(other.purchase_intent_capacity_q16);
    realized_profit_margin_q16.move_from(other.realized_profit_margin_q16);
    severe_loss_cycles.move_from(other.severe_loss_cycles);
    recovery_cycles.move_from(other.recovery_cycles);
    operating_state.move_from(other.operating_state);
    pending_operating_state.move_from(other.pending_operating_state);
    recovery_cooldown_cycles.move_from(other.recovery_cooldown_cycles);
    recovery_failed_reviews.move_from(other.recovery_failed_reviews);
    merchant_debt_term_cycles_left.move_from(other.merchant_debt_term_cycles_left);
    merchant_debt_delinquent_cycles.move_from(other.merchant_debt_delinquent_cycles);
    merchant_debt_principal.move_from(other.merchant_debt_principal);
    merchant_debt_premium.move_from(other.merchant_debt_premium);
    last_in_kind_livelihood_value.move_from(other.last_in_kind_livelihood_value);
    last_market_receipt.move_from(other.last_market_receipt);
    last_bullion_mint_receipt.move_from(other.last_bullion_mint_receipt);
    last_producer_support_receipt.move_from(other.last_producer_support_receipt);
    last_business_tax_paid.move_from(other.last_business_tax_paid);
    last_business_subsidy_received.move_from(other.last_business_subsidy_received);
    last_maintenance_due.move_from(other.last_maintenance_due);
    last_observed_capacity_days_q16.move_from(other.last_observed_capacity_days_q16);
    last_quoted_market_receipt.move_from(other.last_quoted_market_receipt);
    last_quoted_operating_cost.move_from(other.last_quoted_operating_cost);
    modifier_handle.move_from(other.modifier_handle);
    output_factor_q16.move_from(other.output_factor_q16);
    role_count.move_from(other.role_count);
    role_begin.move_from(other.role_begin);
    role_filled.move_from(other.role_filled);
    role_contract_wage.move_from(other.role_contract_wage);
    role_base_living_cost.move_from(other.role_base_living_cost);
    role_living_cost.move_from(other.role_living_cost);
    role_local_average_wage.move_from(other.role_local_average_wage);
    role_base_wage_due.move_from(other.role_base_wage_due);
    role_base_wage_paid.move_from(other.role_base_wage_paid);
    role_bonus_due.move_from(other.role_bonus_due);
    role_bonus_paid.move_from(other.role_bonus_paid);
    pending_cell.move_from(other.pending_cell);
    pending_type_id.move_from(other.pending_type_id);
    pending_owner_signature_id.move_from(other.pending_owner_signature_id);
    pending_count.move_from(other.pending_count);
    pending_ready_day.move_from(other.pending_ready_day);
    pending_sequence.move_from(other.pending_sequence);
    pending_merchant_debt_principal.move_from(other.pending_merchant_debt_principal);
    pending_merchant_debt_premium.move_from(other.pending_merchant_debt_premium);
    pending_merchant_debt_term_cycles_left.move_from(other.pending_merchant_debt_term_cycles_left);
    pending_sponsor_family_handle.move_from(other.pending_sponsor_family_handle);
    return *this;
}

namespace {

constexpr uint64_t kFnvOffset = 1469598103934665603ull;
constexpr uint64_t kFnvPrime = 1099511628211ull;

template <typename Sink, typename T>
void append_pod(Sink &out, const T &value) {
    economy_wire_append(out, value);
}

template <typename T>
bool read_pod(const uint8_t *&p, const uint8_t *end, T &value) {
    if (static_cast<size_t>(end - p) < sizeof(T)) return false;
    std::memcpy(&value, p, sizeof(T));
    p += sizeof(T);
    return true;
}

template <typename T>
bool column_size(const EconomyTrackedColumn<T> &column, size_t expected) {
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

template <typename Sink>
void RuntimeEconomyBuildingStore::visit_wire(Sink &out) const {
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
        auto push_i32 = [&](EconomyTrackedColumn<int32_t> &dst) -> bool {
            if (!read_pod(p, end, v_i32)) return false;
            dst.push_back(v_i32);
            return true;
        };
        auto push_i64 = [&](EconomyTrackedColumn<int64_t> &dst) -> bool {
            if (!read_pod(p, end, v_i64)) return false;
            dst.push_back(v_i64);
            return true;
        };
        auto push_u8 = [&](EconomyTrackedColumn<uint8_t> &dst) -> bool {
            if (!read_pod(p, end, v_u8)) return false;
            dst.push_back(v_u8);
            return true;
        };
        auto push_u16 = [&](EconomyTrackedColumn<uint16_t> &dst) -> bool {
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

void RuntimeEconomyBuildingStore::append_wire(std::vector<uint8_t> &out) const {
    visit_wire(out);
}

uint64_t RuntimeEconomyBuildingStore::wire_content_hash() const noexcept {
    EconomyWireHashSink sink{kFnvOffset};
    visit_wire(sink);
    return sink.hash;
}

uint64_t RuntimeEconomyBuildingStore::mix_wire_hash(uint64_t hash) const noexcept {
    EconomyWireSizeSink size;
    visit_wire(size);
    EconomyWireHashSink sink{(hash ^ static_cast<uint64_t>(size.size)) * kFnvPrime};
    visit_wire(sink);
    return sink.hash;
}

} // namespace pk
