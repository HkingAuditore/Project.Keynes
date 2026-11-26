#include "economy_runtime.h"

#include <algorithm>
#include <numeric>

namespace pk {

bool NativeEconomyRuntime::restore_family_expedition_payload(
        int32_t expedition, int32_t destination_cell, std::string &error) {
    if (destination_cell < 0 || destination_cell >= _cell_count.get()) {
        error = "colonization_destination_invalid"; return false;
    }
    const uint64_t family_handle = family_expeditions_store().family_handle[expedition];
    const uint32_t begin = family_expeditions_store().payload_begin[expedition];
    const uint32_t end = begin + family_expeditions_store().payload_count[expedition];
    if (end > family_expedition_payloads().size()) {
        error = "colonization_payload_range_invalid"; return false;
    }
    for (uint32_t p = begin; p < end; ++p) {
        auto payload_write = family_expedition_payloads().edit_row(p, market_mutation_sink());
        FamilyExpeditionPayload &payload = payload_write[0];
        const uint64_t reservation_owner =
            family_expeditions_store().handle_for_index(expedition);
        int32_t slot = -1;
        if (destination_cell == family_expeditions_store().target_cell[expedition]) {
            slot = population_store().claim_reserved_slot(payload.reserved_slot,
                destination_cell, static_cast<uint32_t>(payload.signature),
                reservation_owner);
        } else {
            population_store().release_reserved_slot(payload.reserved_slot,
                                               reservation_owner);
            slot = population_store().allocate_slot(destination_cell,
                static_cast<uint32_t>(payload.signature));
        }
        if (slot < 0) { error = "colonization_reserved_slot_unavailable"; return false; }
        payload.reserved_slot = -1;
        const int64_t old_population = population_store().population[slot];
        const int64_t merged_population = old_population + payload.people;
        // Employment leaves the source cohort together with the payload.  Put
        // it back on the destination lane as part of the same atomic merge;
        // otherwise family attribution can reconstruct jobs against a stale
        // population and the next POD export rejects the ledger.
        const int64_t incoming_employment = std::min<int64_t>(
            payload.people,
            std::max<int64_t>(0, payload.owner_employed) +
            std::max<int64_t>(0, payload.employee_employed));
        const int64_t incoming_owner_employed = std::min<int64_t>(
            std::max<int64_t>(0, payload.owner_employed), incoming_employment);
        const int64_t incoming_employee_employed = std::min<int64_t>(
            std::max<int64_t>(0, payload.employee_employed),
            incoming_employment - incoming_owner_employed);
        auto blend = [&](uint16_t old_value, uint16_t incoming) {
            if (merged_population <= 0) return incoming;
            return static_cast<uint16_t>((static_cast<int64_t>(old_value) *
                old_population + static_cast<int64_t>(incoming) * payload.people) /
                merged_population);
        };
        audit_touch_population_lane(slot); touch_accounting_slot(slot);
        population_store().population.write_scalar(slot, merged_population, market_mutation_sink());
        population_store().owner_employed.write_scalar(slot, saturating_add(
            population_store().owner_employed[slot],
            incoming_owner_employed, _saturation_count), market_mutation_sink());
        population_store().employee_employed.write_scalar(slot, saturating_add(
            population_store().employee_employed[slot],
            incoming_employee_employed, _saturation_count), market_mutation_sink());
        const int64_t total_employment =
            population_store().owner_employed[slot] +
            population_store().employee_employed[slot];
        if (total_employment > merged_population) {
            population_store().employee_employed.write_scalar(slot, std::max<int64_t>(
                0, merged_population - population_store().owner_employed[slot]), market_mutation_sink());
        }
        population_store().funds.write_scalar(slot, population_store().funds[slot] + (payload.funds), market_mutation_sink());
        population_store().epoch_income.write_scalar(slot, population_store().epoch_income[slot] + (payload.epoch_income), market_mutation_sink());
        population_store().epoch_expense.write_scalar(slot, population_store().epoch_expense[slot] + (payload.epoch_expense), market_mutation_sink());
        population_store().epoch_in_kind_income.write_scalar(slot, population_store().epoch_in_kind_income[slot] + (payload.epoch_in_kind_income), market_mutation_sink());
        population_store().income_ema.write_scalar(slot, population_store().income_ema[slot] + (payload.income_ema), market_mutation_sink());
        population_store().epoch_tax_paid.write_scalar(slot, population_store().epoch_tax_paid[slot] + (payload.epoch_tax_paid), market_mutation_sink());
        population_store().epoch_subsidy_received.write_scalar(slot, population_store().epoch_subsidy_received[slot] + (payload.epoch_subsidy_received), market_mutation_sink());
        population_store().income_baseline_ema.write_scalar(slot, population_store().income_baseline_ema[slot] + (payload.income_baseline_ema), market_mutation_sink());
        population_store().demography_residual.write_scalar(slot, population_store().demography_residual[slot] + (payload.demography_residual), market_mutation_sink());
        population_store().needs_satisfaction.write_scalar(slot, blend(
            population_store().needs_satisfaction[slot], payload.needs_satisfaction), market_mutation_sink());
        population_store().composite_satisfaction.write_scalar(slot, blend(
            population_store().composite_satisfaction[slot],
            payload.composite_satisfaction), market_mutation_sink());
        for (int32_t dim = 0; dim < SAT_DIM_COUNT; ++dim) {
            const size_t lane = static_cast<size_t>(slot) * SAT_DIM_COUNT + dim;
            population_store().satisfaction_dims.write_scalar(lane, blend(
                population_store().satisfaction_dims[lane],
                payload.satisfaction_dims[dim]), market_mutation_sink());
        }
        if (old_population == 0) {
            population_store().worst_need_id.write_scalar(slot, payload.worst_need_id, market_mutation_sink());
            population_store().worst_dimension_id.write_scalar(slot, payload.worst_dimension_id, market_mutation_sink());
        }
        const uint64_t cohort_handle = population_store().handle_for_slot(slot);
        shift_family_ledger_basis(slot, payload.funds);
        // 随行平民落地后仍是本地无家族人口：登记成员边会凭空把移民变成族人，
        // 也会污染目标地的家族份额。他们只能经招收/absorb 正常入籍。
        if (payload.anonymous == 0) {
            family_memberships().push_back({family_handle, cohort_handle,
                payload.people, payload.cash_claim, merged_population,
                family_ledger_basis_for_slot(slot), incoming_owner_employed,
                incoming_employee_employed});
        }
        if (static_cast<size_t>(payload.person_begin) + payload.person_count >
                family_expedition_person_handles().size()) {
            error = "colonization_person_payload_range_invalid"; return false;
        }
        for (uint32_t i = 0; i < payload.person_count; ++i) {
            int32_t person = -1;
            if (persons_store().valid_handle(
                    family_expedition_person_handles()[payload.person_begin + i],
                    person))
                persons_store().cohort_handle.write_scalar(person, cohort_handle, market_mutation_sink());
        }
    }
    _family_indices_dirty = true; _person_indices_dirty = true;
    _structural_touched_cells.push_back(destination_cell);
    clip_cell_employment_and_defer_reconcile(destination_cell);
    return true;
}

bool NativeEconomyRuntime::finalize_immediate_family_expedition_settlement(
        int32_t destination_cell, std::string &error) {
    if (!repair_cell_merchant_and_rebuild(destination_cell, error)) return false;

    normalize_family_memberships(false);
    update_family_employment_attribution();
    if (_family_indices_dirty) rebuild_family_indices(false);
    rebuild_family_industry_metrics();
    rebuild_family_influences(false);
    rebuild_family_behavior_cache();
    rebuild_family_owned_output_csr();
    if (_person_indices_dirty) rebuild_person_indices();

    if (destination_cell >= 0 && destination_cell < _cell_count.get()) {
        const CellSummary summary = build_cell_summary(destination_cell);
        if (destination_cell < static_cast<int32_t>(_committed_cells.size()))
            _committed_cells[destination_cell] = summary;
        if (destination_cell < static_cast<int32_t>(_staging_cells.size()))
            _staging_cells[destination_cell] = summary;
        if (destination_cell < static_cast<int32_t>(
                _cell_population_gen.size()))
            _cell_population_gen.write_scalar(destination_cell, _cell_population_gen[destination_cell] + 1, market_mutation_sink());
    }
    // Restore already audit-touches the destination lane. Rebuilding the
    // incremental shadow after that would snapshot post-merge population and
    // drop the +people / -transit delta for this epoch.
    if (!_epoch_active) rebuild_incremental_audit_shadow();
    note_family_expedition_audit_invalidation();
    return true;
}

void NativeEconomyRuntime::release_family_expedition_reservations(
        int32_t expedition) {
    if (expedition < 0 || expedition >= static_cast<int32_t>(
            family_expeditions_store().active.size()) ||
        family_expeditions_store().active[expedition] == 0) return;
    const uint64_t owner = family_expeditions_store().handle_for_index(expedition);
    const uint32_t begin = family_expeditions_store().payload_begin[expedition];
    const uint32_t end = std::min<uint32_t>(
        begin + family_expeditions_store().payload_count[expedition],
        static_cast<uint32_t>(family_expedition_payloads().size()));
    for (uint32_t p = begin; p < end; ++p) {
        auto payload_write = family_expedition_payloads().edit_row(p, market_mutation_sink());
        FamilyExpeditionPayload &payload = payload_write[0];
        population_store().release_reserved_slot(payload.reserved_slot, owner);
        payload.reserved_slot = -1;
    }
    population_store().reclaim_empty_pages(family_expeditions_store().target_cell[expedition]);
}

bool NativeEconomyRuntime::person_in_expedition_transit(
        uint64_t person_handle) const {
    if (person_handle == 0) return false;
    const auto &handles = family_expedition_person_handles();
    return std::find(handles.begin(), handles.end(), person_handle) !=
        handles.end();
}

void NativeEconomyRuntime::drop_expedition_transit_person(
        uint64_t person_handle) {
    if (person_handle == 0) return;
    auto &handles = family_expedition_person_handles();
    if (handles.empty()) return;
    const int32_t expedition_count = static_cast<int32_t>(
        family_expeditions_store().active.size());
    int32_t removed = -1;
    size_t owner_payload = 0;
    const auto &payloads = family_expedition_payloads();
    for (int32_t e = 0; e < expedition_count && removed < 0; ++e) {
        if (family_expeditions_store().active[e] == 0) continue;
        const size_t begin = family_expeditions_store().payload_begin[e];
        const size_t end = std::min<size_t>(begin +
            family_expeditions_store().payload_count[e],
            payloads.size());
        for (size_t p = begin; p < end && removed < 0; ++p) {
            const auto &lane = payloads[p];
            const size_t lane_end = std::min<size_t>(
                static_cast<size_t>(lane.person_begin) + lane.person_count,
                handles.size());
            for (size_t i = lane.person_begin; i < lane_end; ++i) {
                if (handles[i] != person_handle) continue;
                removed = static_cast<int32_t>(i);
                owner_payload = p;
                break;
            }
        }
    }
    if (removed < 0) return;
    handles.erase(static_cast<size_t>(removed), 1);
    {
        auto owner_write = family_expedition_payloads().edit_row(
            owner_payload, market_mutation_sink());
        if (owner_write[0].person_count > 0) --owner_write[0].person_count;
    }
    // The flat handle lane stays contiguous, so every payload that begins after
    // the removed entry shifts left by one.
    std::vector<size_t> shifted;
    for (int32_t e = 0; e < expedition_count; ++e) {
        if (family_expeditions_store().active[e] == 0) continue;
        const size_t begin = family_expeditions_store().payload_begin[e];
        const size_t end = std::min<size_t>(begin +
            family_expeditions_store().payload_count[e],
            family_expedition_payloads().size());
        for (size_t p = begin; p < end; ++p)
            if (family_expedition_payloads()[p].person_begin >
                    static_cast<uint32_t>(removed))
                shifted.push_back(p);
    }
    for (const size_t p : shifted) {
        auto write = family_expedition_payloads().edit_row(p,
            market_mutation_sink());
        --write[0].person_begin;
    }
    _person_indices_dirty = true;
}

} // namespace pk
