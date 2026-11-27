#include "runtime_economy_army_personnel_includes.inc"

namespace pk {

// File-local Q16 one: the store is standalone and the runtime constants are
// nested, so both sides share this alias instead of repeating the literal.
constexpr int32_t kLaneQ16One = ArmyPersonnelStore::LANE_Q16_ONE;

// ─────────────────── NativeEconomyRuntime: structural commit ─────────────────

bool NativeEconomyRuntime::pay_army_lane_from_worker_country(
        uint64_t army_handle, int64_t country_handle, int64_t requested,
        int64_t &moved, std::string &error) {
    moved = 0;
    error.clear();
    if (army_handle == 0 || country_handle == 0 || requested <= 0) {
        error = "army_lane_pay_request_invalid";
        return false;
    }
    const int32_t row = _army_personnel.find(army_handle);
    if (row == ArmyPersonnelStore::NO_ROW) {
        error = "army_lane_pay_lane_missing";
        return false;
    }
    if (_simulation_host == nullptr || _country_runtime == nullptr) {
        error = "army_lane_pay_worker_boundary_unavailable";
        return false;
    }
    if (!_simulation_host->on_worker_thread()) {
        error = "army_lane_pay_worker_boundary_invalid";
        return false;
    }
    // Same synchronous peer cycle the cohort cash lane uses (coordinate_country_
    // cohort_cash): prepare on Country's POD authority, let this runtime's own
    // executor apply the Economy side, then finish. Running all three inside one
    // epoch is what keeps the debit and the credit in the same audit window; the
    // enqueue-only route would let them land in different ones.
    RuntimeEconomyAssetRequest request;
    request.operation = RuntimeEconomyAssetOperation::TREASURY_SPEND;
    request.origin_epoch = _epoch_id.get();
    request.origin_stage = static_cast<int32_t>(_stage);
    request.day = _current_day.get();
    request.country_handle = static_cast<uint64_t>(country_handle);
    request.target_slot = -1;
    request.target_handle = army_handle;   // <- the lane to credit on the peer side
    request.peer_generation = _committed_generation;
    request.requested_cash = requested;
    request.requested_quantity = requested;
    if (!_simulation_host->prepare_worker_cohort_cash(request, error)) return false;
    if (!service_country_economy_asset_peer(RUNTIME_ECONOMY_ASSET_QUEUE_CAPACITY,
                                            error))
        return false;
    RuntimeEconomyAssetResult terminal;
    if (!_simulation_host->finish_worker_country_asset(request.request_id, terminal,
                                                       error))
        return false;
    moved = std::max<int64_t>(0, std::min(requested, terminal.committed_cash));
    if (moved <= 0) {
        error = "army_lane_pay_treasury_empty";
        return false;
    }
    // The peer side already credited the lane through apply_peer_asset_side_effects
    // (TREASURY_SPEND with a formation handle). Only the cashflow trace is booked
    // here, and only when the side effect did not already do it.
    return true;
}

bool NativeEconomyRuntime::commit_structural_army_lane(const StructuralCommand &cmd,
                                                       std::string &error,
                                                       int64_t *moved_out) {
    if (moved_out != nullptr) *moved_out = 0;
    const uint64_t army = static_cast<uint64_t>(cmd.funds);
    if (army == 0) return true;
    if (cmd.cell < 0 || cmd.cell >= _cell_count.get() || cmd.signature < 0 ||
        cmd.signature >= static_cast<int32_t>(_signatures.size())) {
        error = "structural_army_lane_target_invalid";
        return false;
    }
    const int64_t requested = std::max<int64_t>(0, cmd.population);
    if (requested <= 0) return true;
    // The cohort fill/ownership reconcile and the merchant-range rebuild of this
    // cell only run from the structural stage. A record committed inline (POD
    // drain between epochs) must therefore ask for that reconcile explicitly;
    // inside an epoch the touched list already reaches it before it is cleared.
    const auto defer_reconcile_if_idle = [&]() {
        if (!_epoch_active) _deferred_population_reconcile_cells.push_back(cmd.cell);
    };

    if (cmd.opcode == STRUCTURAL_ARMY_EMBARK) {
        // Re-resolve the source cohort from (cell, signature): the recorded slot
        // is a hint only, and a producer from another context never owns one.
        int32_t source = cmd.source_slot;
        const bool slot_ok = source >= 0 &&
            source < static_cast<int32_t>(population_store().active.size()) &&
            population_store().active[source] != 0;
        // A hint that still names a live slot may name a DIFFERENT cohort when an
        // earlier command in the same batch released and reallocated it, so the
        // signature must agree before the slot is trusted.
        if (!slot_ok || population_store().signature_id[source] !=
                static_cast<uint32_t>(cmd.signature)) {
            source = population_store().find_signature(
                cmd.cell, static_cast<uint32_t>(cmd.signature));
        }
        if (source < 0 ||
            source >= static_cast<int32_t>(population_store().active.size()) ||
            population_store().active[source] == 0) {
            // The cohort was already drained by an earlier command in the same
            // batch: deterministic no-op, never a fatal.
            return true;
        }
        const int64_t source_pop =
            std::max<int64_t>(0, population_store().population[source]);
        const int64_t moved = std::min(requested, source_pop);
        if (moved <= 0) return true;
        // Money follows people proportionally; the remainder stays on the
        // source cohort (contract §1.2).
        const int64_t source_funds = population_store().funds[source];
        const int64_t moved_funds = moved == source_pop
            ? source_funds
            : mul_div_sat(source_funds, moved, source_pop, _saturation_count);
        const int64_t moved_income = moved == source_pop
            ? population_store().epoch_income[source]
            : mul_div_sat(population_store().epoch_income[source], moved,
                          source_pop, _saturation_count);
        const int64_t moved_expense = moved == source_pop
            ? population_store().epoch_expense[source]
            : mul_div_sat(population_store().epoch_expense[source], moved,
                          source_pop, _saturation_count);
        const uint16_t moved_satisfaction = population_store().needs_satisfaction[source];
        const uint16_t moved_composite = population_store().composite_satisfaction[source];
        const int64_t source_handle =
            static_cast<int64_t>(population_store().handle_for_slot(source));
        const int32_t signature = static_cast<int32_t>(population_store().signature_id[source]);
        const int32_t profession = signature >= 0 &&
                signature < static_cast<int32_t>(_signatures.size())
            ? _signatures[signature].profession_id : -1;
        const int32_t plan = signature >= 0 &&
                signature < static_cast<int32_t>(_signatures.size())
            ? _signatures[signature].plan_id : -1;

        const int32_t row = _army_personnel.ensure(army);
        if (row == ArmyPersonnelStore::NO_ROW) {
            error = "army_lane_allocation_failed";
            return false;
        }
        const size_t r = static_cast<size_t>(row);
        if (_army_personnel.population[r] <= 0) {
            // Fresh lane: identity, country and consumption plan come from the
            // cohort that just boarded.
            _army_personnel.cell[r] = cmd.cell;
            _army_personnel.country_handle[r] = static_cast<uint64_t>(
                army_lane_country_handle(cmd.cell));
            _army_personnel.profession_id[r] = profession;
            _army_personnel.plan_id[r] = plan;
            _army_personnel.signature_id[r] = signature;
            _army_personnel.satisfaction_q16[r] = moved_composite;
            _army_personnel.survival_q16[r] = moved_satisfaction;
        } else {
            const int64_t before_pop = std::max<int64_t>(0, _army_personnel.population[r]);
            const int64_t after_pop = before_pop + moved;
            if (after_pop > 0) {
                const int64_t weighted = saturating_add(
                    mul_div_sat(_army_personnel.satisfaction_q16[r], before_pop, 1,
                                _saturation_count),
                    mul_div_sat(moved_composite, moved, 1, _saturation_count),
                    _saturation_count);
                _army_personnel.satisfaction_q16[r] = static_cast<int32_t>(
                    std::clamp<int64_t>(weighted / after_pop, 0, kLaneQ16One - 1));
                const int64_t survival_weighted = saturating_add(
                    mul_div_sat(_army_personnel.survival_q16[r], before_pop, 1,
                                _saturation_count),
                    mul_div_sat(moved_satisfaction, moved, 1, _saturation_count),
                    _saturation_count);
                _army_personnel.survival_q16[r] = static_cast<int32_t>(
                    std::clamp<int64_t>(survival_weighted / after_pop, 0, kLaneQ16One - 1));
            }
        }
        _army_personnel.population[r] = saturating_add(
            _army_personnel.population[r], moved, _saturation_count);
        _army_personnel.funds[r] = saturating_add(
            _army_personnel.funds[r], moved_funds, _saturation_count);
        _army_personnel.epoch_income[r] = saturating_add(
            _army_personnel.epoch_income[r], moved_income, _saturation_count);
        _army_personnel.epoch_expense[r] = saturating_add(
            _army_personnel.epoch_expense[r], moved_expense, _saturation_count);

        // Cohort side, on the structural path (slot/page bookkeeping included).
        audit_touch_population_lane(source);
        population_store().population.write_scalar(
            source, source_pop - moved, market_mutation_sink());
        population_store().funds.write_scalar(
            source, source_funds - moved_funds, market_mutation_sink());
        population_store().epoch_income.write_scalar(
            source, population_store().epoch_income[source] - moved_income,
            market_mutation_sink());
        population_store().epoch_expense.write_scalar(
            source, population_store().epoch_expense[source] - moved_expense,
            market_mutation_sink());
        const int64_t remaining_pop = population_store().population[source];
        if (remaining_pop == 0) {
            // Any rounding residue is money, not an implicit burn.
            const int64_t residue = population_store().funds[source];
            const int64_t country_handle = army_lane_country_handle(cmd.cell);
            int64_t transferred = 0;
            std::string cohort_cash_error;
            if (!coordinate_country_cohort_cash(
                    source, country_handle,
                    CountryApi::ECONOMY_ASSET_CASH_FROM_COHORT,
                    residue, transferred, cohort_cash_error)) {
                error = cohort_cash_error.empty()
                    ? "country_treasury_residue_transfer_failed"
                    : cohort_cash_error;
                return false;
            }
            if (transferred != residue) {
                // Same soft-unavailable path as commit_structural: keep the
                // residue on the drained slot until the Country peer opens.
                if (transferred == 0 &&
                    (cohort_cash_error == "country_economy_operation_gate_closed" ||
                     cohort_cash_error == "country_cohort_cash_treasury_unowned" ||
                     cohort_cash_error == "country_cohort_cash_negative_balance")) {
                    _structural_touched_cells.push_back(cmd.cell);
                    return true;
                }
                error = "country_treasury_residue_transfer_failed";
                return false;
            }
            _structural_funds_to_treasury = saturating_add(
                _structural_funds_to_treasury, residue, _saturation_count);
            population_store().funds.write_scalar(source, 0, market_mutation_sink());
            _filled_owner_jobs = saturating_sub(
                _filled_owner_jobs,
                std::max<int64_t>(0, population_store().owner_employed[source]),
                _saturation_count);
            _filled_employee_jobs = saturating_sub(
                _filled_employee_jobs,
                std::max<int64_t>(0, population_store().employee_employed[source]),
                _saturation_count);
            if (slot_has_merchant_profession(source)) _merchant_ranges_dirty = true;
            population_store().release_slot(source);
            population_store().reclaim_empty_pages(cmd.cell);
        }
        _structural_touched_cells.push_back(cmd.cell);
        std::vector<EventLeg> legs;
        if (trace_detail_for_cell(cmd.cell)) {
            legs.push_back({FIELD_COHORT_POPULATION, SUBJECT_COHORT,
                            source_handle, -1, source_pop, source_pop - moved});
        }
        trace_append(EVENT_STRUCTURAL_CHANGE,
                     static_cast<int32_t>(Stage::STRUCTURAL_COMMIT), cmd.cell,
                     SUBJECT_COHORT, static_cast<int64_t>(army), signature,
                     cmd.cell, moved, moved_funds, cmd.cell, cmd.cell,
                     legs.empty() ? nullptr : &legs);
        if (moved_out != nullptr) *moved_out = moved;
        // Between epochs the structural reconcile is a day away, but the
        // committed ledger is exported right after this drain. Soldiers who
        // left a barracks must stop counting as its employees before that
        // export (cohort employment <= population), so reconcile this cell now;
        // the deferred pass next epoch then finds nothing left to move.
        if (!_epoch_active &&
            !reconcile_building_employment_after_population_change({cmd.cell}, error)) {
            if (error.empty()) error = "army_embark_employment_reconcile_failed";
            return false;
        }
        defer_reconcile_if_idle();
        return true;
    }

    if (cmd.opcode == STRUCTURAL_ARMY_DISEMBARK) {
        const int32_t row = _army_personnel.find(army);
        if (row == ArmyPersonnelStore::NO_ROW) return true;
        const size_t r = static_cast<size_t>(row);
        const int64_t lane_pop = std::max<int64_t>(0, _army_personnel.population[r]);
        const int64_t moved = std::min(requested, lane_pop);
        if (moved <= 0) return true;
        const int64_t lane_funds = _army_personnel.funds[r];
        const int64_t moved_funds = moved == lane_pop
            ? lane_funds
            : mul_div_sat(lane_funds, moved, lane_pop, _saturation_count);
        const int64_t moved_income = moved == lane_pop
            ? _army_personnel.epoch_income[r]
            : mul_div_sat(_army_personnel.epoch_income[r], moved, lane_pop,
                          _saturation_count);
        const int64_t moved_expense = moved == lane_pop
            ? _army_personnel.epoch_expense[r]
            : mul_div_sat(_army_personnel.epoch_expense[r], moved, lane_pop,
                          _saturation_count);
        const int32_t destination = population_store().allocate_slot(
            cmd.cell, static_cast<uint32_t>(cmd.signature));
        if (destination < 0) {
            error = "structural_disembark_allocation_failed";
            return false;
        }
        const int64_t destination_pop_before = population_store().population[destination];
        const int64_t destination_handle =
            static_cast<int64_t>(population_store().handle_for_slot(destination));
        touch_accounting_slot(destination);
        audit_touch_population_lane(destination);
        if (destination_pop_before == 0 && slot_has_merchant_profession(destination))
            _merchant_ranges_dirty = true;
        const int64_t merged_pop = destination_pop_before + moved;
        population_store().population.write_scalar(
            destination, merged_pop, market_mutation_sink());
        population_store().funds.write_scalar(
            destination,
            saturating_add(population_store().funds[destination], moved_funds,
                           _saturation_count),
            market_mutation_sink());
        population_store().epoch_income.write_scalar(
            destination,
            saturating_add(population_store().epoch_income[destination],
                           moved_income, _saturation_count),
            market_mutation_sink());
        population_store().epoch_expense.write_scalar(
            destination,
            saturating_add(population_store().epoch_expense[destination],
                           moved_expense, _saturation_count),
            market_mutation_sink());
        const auto blend = [&](int64_t destination_value, int64_t incoming_value) {
            if (merged_pop <= 0) return static_cast<uint16_t>(kLaneQ16One - 1);
            const int64_t weighted = saturating_add(
                mul_div_sat(destination_value, destination_pop_before, 1,
                            _saturation_count),
                mul_div_sat(incoming_value, moved, 1, _saturation_count),
                _saturation_count);
            return static_cast<uint16_t>(
                std::clamp<int64_t>(weighted / merged_pop, 0, kLaneQ16One - 1));
        };
        population_store().needs_satisfaction.write_scalar(
            destination,
            blend(population_store().needs_satisfaction[destination],
                  _army_personnel.survival_q16[r]),
            market_mutation_sink());
        population_store().composite_satisfaction.write_scalar(
            destination,
            blend(population_store().composite_satisfaction[destination],
                  _army_personnel.satisfaction_q16[r]),
            market_mutation_sink());

        _army_personnel.population[r] = lane_pop - moved;
        _army_personnel.funds[r] = lane_funds - moved_funds;
        _army_personnel.epoch_income[r] =
            _army_personnel.epoch_income[r] - moved_income;
        _army_personnel.epoch_expense[r] =
            _army_personnel.epoch_expense[r] - moved_expense;
        if (_army_personnel.population[r] <= 0) {
            // Emptied lane: release the row (compacts the SoA and the CSR).
            _army_personnel.population[r] = 0;
            _army_personnel.funds[r] = 0;
            _army_personnel.release(row);
        }
        _structural_touched_cells.push_back(cmd.cell);
        std::vector<EventLeg> legs;
        if (trace_detail_for_cell(cmd.cell)) {
            legs.push_back({FIELD_COHORT_POPULATION, SUBJECT_COHORT,
                            destination_handle, -1, destination_pop_before,
                            merged_pop});
        }
        trace_append(EVENT_STRUCTURAL_CHANGE,
                     static_cast<int32_t>(Stage::STRUCTURAL_COMMIT), cmd.cell,
                     SUBJECT_COHORT, destination_handle, cmd.signature, cmd.cell,
                     moved, moved_funds, -1, cmd.cell,
                     legs.empty() ? nullptr : &legs);
        if (moved_out != nullptr) *moved_out = moved;
        defer_reconcile_if_idle();
        return true;
    }
    return true;
}

} // namespace pk
