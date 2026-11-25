#include "economy_runtime.h"
#include "economy_cohort_move_cash.h"
#include "economy_runtime_internal_external_types.inc"

#include <algorithm>

namespace pk {

int64_t NativeEconomyRuntime::plan_cohort_move_cash(int32_t source_slot,
        int32_t destination_cell, int64_t moved_population,
        uint64_t preferred_family_handle, bool preferred_family_strict,
        bool *will_drain_out) {
    if (will_drain_out != nullptr) *will_drain_out = false;
    if (source_slot < 0 ||
        source_slot >= static_cast<int32_t>(population_store().active.size()))
        return 0;
    const int64_t source_pop = std::max<int64_t>(0,
        population_store().population[source_slot]);
    const int64_t move_pop = std::min(std::max<int64_t>(0, moved_population), source_pop);
    if (move_pop == 0) return 0;
    if (will_drain_out != nullptr) *will_drain_out = move_pop == source_pop;
    const int64_t source_funds = std::max<int64_t>(0,
        population_store().funds[source_slot]);
    if (family_memberships().empty()) {
        // No family lanes anywhere: the whole cohort is anonymous and the move
        // is the plain per-capita share (same as before the split existed).
        return cohort_move_cash(source_funds, source_pop, move_pop, false, 0, 0,
            0, 0, _saturation_count, mul_div_sat);
    }
    // Same split the write performs: resolve the family/anonymous parties
    // first, then let the shared rule turn that split into cash.
    const int64_t anonymous_moved = plan_family_membership_move(source_slot,
        destination_cell, move_pop, preferred_family_handle, preferred_family_strict);
    int64_t family_claim = 0;
    int64_t family_people = 0;
    int64_t moved_claim = 0;
    for (int32_t edge : _family_edge_scratch) {
        family_people += std::max<int64_t>(0, family_memberships()[edge].people);
        family_claim += std::max<int64_t>(0, family_memberships()[edge].cash_claim);
    }
    for (const FamilyMovePlanRow &row : _family_move_plan)
        moved_claim = saturating_add(moved_claim, row.claim, _saturation_count);
    const bool family_plan_valid = move_pop < source_pop &&
        !_family_edge_scratch.empty();
    const int64_t anonymous_people = std::max<int64_t>(0, source_pop - family_people);
    return cohort_move_cash(source_funds, source_pop, move_pop, family_plan_valid,
        moved_claim, family_claim, anonymous_moved, anonymous_people,
        _saturation_count, mul_div_sat);
}

bool NativeEconomyRuntime::move_cohort_population(int32_t source, int32_t dest_cell,
                                                   int32_t dest_signature,
                                                   int64_t requested_pop,
                                                   std::string &error,
                                                   bool *source_drained_out,
                                                   uint64_t preferred_family_handle,
                                                   bool preferred_family_strict) {
    if (source_drained_out != nullptr) *source_drained_out = false;
    const int32_t source_cell = population_store().page_cell[source / COHORT_PAGE_SIZE];
    const int64_t source_handle = static_cast<int64_t>(population_store().handle_for_slot(source));
    const int32_t cmd_cell = dest_cell;
    const int32_t cmd_signature = dest_signature;
    const int64_t source_pop = std::max<int64_t>(0, population_store().population[source]);
    const int64_t move_pop = std::min(std::max<int64_t>(0, requested_pop), source_pop);
    if (move_pop == 0) return true;
    _structural_touched_cells.push_back(source_cell);
    _structural_touched_cells.push_back(cmd_cell);
    // Money follows people: family members carry their per-capita claim,
    // anonymous movers the per-capita anonymous remainder. Resolved through the
    // shared rule so the portfolio replay and the investment pre-write gate
    // compute exactly this transfer (economy_cohort_move_cash.h).
    bool will_drain = false;
    const int64_t move_funds = plan_cohort_move_cash(source, cmd_cell, move_pop,
        preferred_family_handle, preferred_family_strict, &will_drain);
    (void)will_drain;
    const int64_t move_income = move_pop == source_pop
                                    ? population_store().epoch_income[source]
                                    : mul_div_sat(population_store().epoch_income[source], move_pop, source_pop,
                                                  _saturation_count);
    const int64_t move_expense = move_pop == source_pop
                                     ? population_store().epoch_expense[source]
                                     : mul_div_sat(population_store().epoch_expense[source], move_pop, source_pop,
                                                   _saturation_count);
    const int64_t move_in_kind = move_pop == source_pop
                                     ? population_store().epoch_in_kind_income[source]
                                     : mul_div_sat(population_store().epoch_in_kind_income[source],
                                                   move_pop, source_pop, _saturation_count);
    const int64_t move_ema = move_pop == source_pop
                                 ? population_store().income_ema[source]
                                 : mul_div_sat(population_store().income_ema[source], move_pop, source_pop,
                                               _saturation_count);
    const int64_t move_residual = move_pop == source_pop
                                      ? population_store().demography_residual[source]
                                      : mul_div_sat(population_store().demography_residual[source], move_pop,
                                                    source_pop, _saturation_count);
    const int64_t move_tax_paid = move_pop == source_pop
                                      ? population_store().epoch_tax_paid[source]
                                      : mul_div_sat(population_store().epoch_tax_paid[source],
                                                    move_pop, source_pop, _saturation_count);
    const int64_t move_subsidy = move_pop == source_pop
                                     ? population_store().epoch_subsidy_received[source]
                                     : mul_div_sat(population_store().epoch_subsidy_received[source],
                                                   move_pop, source_pop, _saturation_count);
    const int64_t move_baseline_ema = move_pop == source_pop
                                          ? population_store().income_baseline_ema[source]
                                          : mul_div_sat(population_store().income_baseline_ema[source],
                                                        move_pop, source_pop, _saturation_count);
    const uint16_t move_satisfaction = population_store().needs_satisfaction[source];
    const uint16_t move_composite = population_store().composite_satisfaction[source];
    const uint8_t move_worst_dimension = population_store().worst_dimension_id[source];

    const int64_t source_population_before = population_store().population[source];
    const int64_t source_funds_before = population_store().funds[source];
    const int64_t source_income_before = population_store().epoch_income[source];
    const int64_t source_expense_before = population_store().epoch_expense[source];
    const int64_t source_ema_before = population_store().income_ema[source];
    const int64_t source_residual_before = population_store().demography_residual[source];

    const int32_t destination = population_store().allocate_slot(cmd_cell, static_cast<uint32_t>(cmd_signature));
    if (destination < 0) {
        _family_move_plan.clear();
        error = "structural_destination_allocation_failed";
        return false;
    }
    const int64_t destination_pop_before = population_store().population[destination];
    if ((move_pop == source_pop && slot_has_merchant_profession(source)) ||
        (destination_pop_before == 0 && slot_has_merchant_profession(destination)))
        _merchant_ranges_dirty = true;
    const int64_t destination_funds_before = population_store().funds[destination];
    const int64_t destination_income_before = population_store().epoch_income[destination];
    const int64_t destination_expense_before = population_store().epoch_expense[destination];
    const int64_t destination_ema_before = population_store().income_ema[destination];
    const int64_t destination_residual_before = population_store().demography_residual[destination];
    touch_accounting_slot(destination);
    audit_touch_population_lane(destination);
    const int64_t destination_handle = static_cast<int64_t>(
        population_store().handle_for_slot(destination));
    population_store().population.write_scalar(destination, saturating_add(destination_pop_before, move_pop,
                                                         _saturation_count), market_mutation_sink());
    population_store().funds.write_scalar(destination, saturating_add(population_store().funds[destination], move_funds,
                                                    _saturation_count), market_mutation_sink());
    population_store().epoch_income.write_scalar(destination, saturating_add(
        population_store().epoch_income[destination], move_income, _saturation_count), market_mutation_sink());
    population_store().epoch_expense.write_scalar(destination, saturating_add(
        population_store().epoch_expense[destination], move_expense, _saturation_count), market_mutation_sink());
    population_store().epoch_in_kind_income.write_scalar(destination, saturating_add(
        population_store().epoch_in_kind_income[destination], move_in_kind, _saturation_count), market_mutation_sink());
    population_store().income_ema.write_scalar(destination, saturating_add(population_store().income_ema[destination],
                                                         move_ema, _saturation_count), market_mutation_sink());
    population_store().demography_residual.write_scalar(destination, saturating_add(
        population_store().demography_residual[destination], move_residual, _saturation_count), market_mutation_sink());
    population_store().epoch_tax_paid.write_scalar(destination, saturating_add(
        population_store().epoch_tax_paid[destination], move_tax_paid, _saturation_count), market_mutation_sink());
    population_store().epoch_subsidy_received.write_scalar(destination, saturating_add(
        population_store().epoch_subsidy_received[destination], move_subsidy, _saturation_count), market_mutation_sink());
    population_store().income_baseline_ema.write_scalar(destination, saturating_add(
        population_store().income_baseline_ema[destination], move_baseline_ema,
        _saturation_count), market_mutation_sink());
    // Satisfaction is an intensive per-capita quantity, so merging two cohorts
    // blends it by population rather than summing it.
    const int64_t merged_pop = population_store().population[destination];
    const auto blend_satisfaction = [&](uint16_t destination_value,
                                        uint16_t incoming_value) -> uint16_t {
        if (merged_pop <= 0) return static_cast<uint16_t>(Q16_ONE - 1);
        const int64_t weighted = saturating_add(
            mul_div_sat(destination_value, destination_pop_before, 1, _saturation_count),
            mul_div_sat(incoming_value, move_pop, 1, _saturation_count),
            _saturation_count);
        return static_cast<uint16_t>(
            std::clamp<int64_t>(weighted / merged_pop, 0, Q16_ONE - 1));
    };
    population_store().needs_satisfaction.write_scalar(destination, blend_satisfaction(
        population_store().needs_satisfaction[destination], move_satisfaction), market_mutation_sink());
    population_store().composite_satisfaction.write_scalar(destination, blend_satisfaction(
        population_store().composite_satisfaction[destination], move_composite), market_mutation_sink());
    {
        const size_t destination_base =
            static_cast<size_t>(destination) * static_cast<size_t>(SAT_DIM_COUNT);
        const size_t source_base =
            static_cast<size_t>(source) * static_cast<size_t>(SAT_DIM_COUNT);
        for (int32_t dim = 0; dim < SAT_DIM_COUNT; ++dim) {
            population_store().satisfaction_dims.write_scalar(destination_base + static_cast<size_t>(dim), blend_satisfaction(
                    population_store().satisfaction_dims[destination_base +
                                                  static_cast<size_t>(dim)],
                    population_store().satisfaction_dims[source_base + static_cast<size_t>(dim)]), market_mutation_sink());
        }
    }
    if (destination_pop_before <= 0)
        population_store().worst_dimension_id.write_scalar(destination, move_worst_dimension, market_mutation_sink());

    audit_touch_population_lane(source);
    population_store().population.write_scalar(source, population_store().population[source] - (move_pop), market_mutation_sink());
    population_store().funds.write_scalar(source, population_store().funds[source] - (move_funds), market_mutation_sink());
    population_store().epoch_income.write_scalar(source, population_store().epoch_income[source] - (move_income), market_mutation_sink());
    population_store().epoch_expense.write_scalar(source, population_store().epoch_expense[source] - (move_expense), market_mutation_sink());
    population_store().epoch_in_kind_income.write_scalar(source, population_store().epoch_in_kind_income[source] - (move_in_kind), market_mutation_sink());
    population_store().income_ema.write_scalar(source, population_store().income_ema[source] - (move_ema), market_mutation_sink());
    population_store().epoch_tax_paid.write_scalar(source, population_store().epoch_tax_paid[source] - (move_tax_paid), market_mutation_sink());
    population_store().epoch_subsidy_received.write_scalar(source, population_store().epoch_subsidy_received[source] - (move_subsidy), market_mutation_sink());
    population_store().income_baseline_ema.write_scalar(source, population_store().income_baseline_ema[source] - (move_baseline_ema), market_mutation_sink());
    population_store().demography_residual.write_scalar(source, population_store().demography_residual[source] - (move_residual), market_mutation_sink());
    if (!family_memberships().empty())
        move_family_membership(source, destination, move_funds);
    if (population_store().population[source] == 0) {
        // Any rounding residue is money, not an implicit burn.
        const int64_t residue_funds = population_store().funds[source];
        const int64_t country_handle = _country_runtime == nullptr ? 0
            : country_reads().country_handle_for_cell(source_cell);
        int64_t moved = 0;
        std::string cohort_cash_error;
        if (!coordinate_country_cohort_cash(
                source, country_handle,
                CountryApi::ECONOMY_ASSET_CASH_FROM_COHORT,
                residue_funds, moved, cohort_cash_error)) {
            error = cohort_cash_error.empty()
                ? "country_treasury_residue_transfer_failed" : cohort_cash_error;
            return false;
        }
        if (moved != residue_funds) {
            // Same gate soft-unavailable path as STRUCTURAL_REMOVE_EMPTY:
            // keep residual funds on the drained slot until Country peer opens.
            if (moved == 0 &&
                (cohort_cash_error == "country_economy_operation_gate_closed" ||
                 cohort_cash_error == "country_cohort_cash_treasury_unowned" ||
                 cohort_cash_error == "country_cohort_cash_negative_balance")) {
                if (source_drained_out != nullptr) *source_drained_out = false;
                return true;
            }
            error = "country_treasury_residue_transfer_failed";
            return false;
        }
        _structural_funds_to_treasury = saturating_add(
            _structural_funds_to_treasury, residue_funds, _saturation_count);
        population_store().funds.write_scalar(source, 0, market_mutation_sink());
        population_store().release_slot(source);
        population_store().reclaim_empty_pages(source_cell);
        if (source_drained_out != nullptr) *source_drained_out = true;
    }
    std::vector<EventLeg> legs;
    if (trace_detail_for_cell(source_cell) || trace_detail_for_cell(cmd_cell)) {
        legs.push_back({FIELD_COHORT_POPULATION, SUBJECT_COHORT, source_handle, -1,
                        source_population_before, source_population_before - move_pop});
        legs.push_back({FIELD_COHORT_FUNDS, SUBJECT_COHORT, source_handle, -1,
                        source_funds_before, source_funds_before - move_funds});
        legs.push_back({FIELD_COHORT_EPOCH_INCOME, SUBJECT_COHORT, source_handle, -1,
                        source_income_before, source_income_before - move_income});
        legs.push_back({FIELD_COHORT_EPOCH_EXPENSE, SUBJECT_COHORT, source_handle, -1,
                        source_expense_before, source_expense_before - move_expense});
        legs.push_back({FIELD_COHORT_INCOME_EMA, SUBJECT_COHORT, source_handle, -1,
                        source_ema_before, source_ema_before - move_ema});
        legs.push_back({FIELD_COHORT_DEMOGRAPHY_RESIDUAL, SUBJECT_COHORT,
                        source_handle, -1, source_residual_before,
                        source_residual_before - move_residual});
        legs.push_back({FIELD_COHORT_POPULATION, SUBJECT_COHORT, destination_handle, -1,
                        destination_pop_before, population_store().population[destination]});
        legs.push_back({FIELD_COHORT_FUNDS, SUBJECT_COHORT, destination_handle, -1,
                        destination_funds_before, population_store().funds[destination]});
        legs.push_back({FIELD_COHORT_EPOCH_INCOME, SUBJECT_COHORT, destination_handle, -1,
                        destination_income_before, population_store().epoch_income[destination]});
        legs.push_back({FIELD_COHORT_EPOCH_EXPENSE, SUBJECT_COHORT, destination_handle, -1,
                        destination_expense_before, population_store().epoch_expense[destination]});
        legs.push_back({FIELD_COHORT_INCOME_EMA, SUBJECT_COHORT, destination_handle, -1,
                        destination_ema_before, population_store().income_ema[destination]});
        legs.push_back({FIELD_COHORT_DEMOGRAPHY_RESIDUAL, SUBJECT_COHORT,
                        destination_handle, -1, destination_residual_before,
                        population_store().demography_residual[destination]});
    }
    trace_append(EVENT_STRUCTURAL_CHANGE,
                 static_cast<int32_t>(Stage::STRUCTURAL_COMMIT), source_cell,
                 SUBJECT_COHORT, source_handle, cmd_signature, cmd_cell,
                 move_pop, move_funds, source_cell, cmd_cell,
                 legs.empty() ? nullptr : &legs);
    if (source_cell != cmd_cell) {
        if (source_cell >= 0 && source_cell < static_cast<int32_t>(_cell_moved_out.size()))
            _cell_moved_out[static_cast<size_t>(source_cell)] =
                saturating_add(_cell_moved_out[static_cast<size_t>(source_cell)],
                    move_pop, _saturation_count);
        if (cmd_cell >= 0 && cmd_cell < static_cast<int32_t>(_cell_moved_in.size()))
            _cell_moved_in[static_cast<size_t>(cmd_cell)] =
                saturating_add(_cell_moved_in[static_cast<size_t>(cmd_cell)],
                    move_pop, _saturation_count);
    }
    return true;
}


// Country/Economy asset backpressure surfaced from inside a cursor-driven
// stage drain. The cursor has not advanced past the failing command, so the
// same command replays on the next pulse. Drain the peer queue on the way out
// so Country-origin terminals keep landing while this stage is parked;
// otherwise the Country plan window that caused the park can never close.

} // namespace pk
