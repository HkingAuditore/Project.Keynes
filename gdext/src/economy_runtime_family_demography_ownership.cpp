#include "economy_runtime_family_demography_includes.inc"

namespace pk {

void NativeEconomyRuntime::rebuild_family_owner_seats() {
    _family_owner_seat_rows.clear();
    if (_family_runtime_mode.get() != 2 || family_ownerships().empty()) return;
    int64_t sat = 0;
    for (int32_t i = 0; i < static_cast<int32_t>(family_ownerships().size()); ++i) {
        const FamilyBuildingOwnership &ownership = family_ownerships().read_at(
            i, __FILE__, __LINE__);
        if (ownership.owned_count <= 0 || ownership.family_handle == 0) continue;
        const int32_t building = building_index_for_handle(ownership.building_handle);
        if (building < 0) continue;
        const auto group = building_view(static_cast<size_t>(building));
        if (group.owner_signature_id < 0 || group.type_id < 0 ||
            group.type_id >= static_cast<int32_t>(_building_types.size())) continue;
        const int64_t seats = saturating_mul(ownership.owned_count,
            _building_types[group.type_id].owner_slots_per_building, sat);
        if (seats <= 0) continue;
        const int32_t owner_slot = find_cohort_slot(group.cell, group.owner_signature_id);
        if (owner_slot < 0) continue;
        _family_owner_seat_rows.push_back({population_store().handle_for_slot(owner_slot),
                                           ownership.family_handle, seats});
    }
    std::sort(_family_owner_seat_rows.begin(), _family_owner_seat_rows.end(),
        [](const FamilyOwnerSeatRow &a, const FamilyOwnerSeatRow &b) {
            return std::tie(a.cohort_handle, a.family_handle) <
                std::tie(b.cohort_handle, b.family_handle);
        });
    size_t merged = 0;
    for (size_t i = 0; i < _family_owner_seat_rows.size(); ++i) {
        if (merged > 0 &&
            _family_owner_seat_rows[merged - 1].cohort_handle ==
                _family_owner_seat_rows[i].cohort_handle &&
            _family_owner_seat_rows[merged - 1].family_handle ==
                _family_owner_seat_rows[i].family_handle) {
            _family_owner_seat_rows[merged - 1].seats = saturating_add(
                _family_owner_seat_rows[merged - 1].seats,
                _family_owner_seat_rows[i].seats, sat);
        } else {
            _family_owner_seat_rows[merged++] = _family_owner_seat_rows[i];
        }
    }
    _family_owner_seat_rows.resize(merged);
    _saturation_count = saturating_add(_saturation_count, sat, _saturation_count);
}

int64_t NativeEconomyRuntime::family_owner_seats(uint64_t cohort_handle,
                                                 uint64_t family_handle) const {
    if (_family_owner_seat_rows.empty()) return 0;
    const auto found = std::lower_bound(_family_owner_seat_rows.begin(),
        _family_owner_seat_rows.end(), std::make_pair(cohort_handle, family_handle),
        [](const FamilyOwnerSeatRow &row, const std::pair<uint64_t, uint64_t> &key) {
            return std::tie(row.cohort_handle, row.family_handle) <
                std::tie(key.first, key.second);
        });
    return found != _family_owner_seat_rows.end() &&
            found->cohort_handle == cohort_handle && found->family_handle == family_handle
        ? found->seats : 0;
}

uint64_t NativeEconomyRuntime::owning_family_for_owner_hire(
        int32_t group_index, int32_t pool_slot) const {
    if (group_index < 0 || pool_slot < 0 ||
        _family_building_offsets.size() != building_count() + 1 ||
        _family_cohort_offsets.size() != population_store().active.size() + 1 ||
        static_cast<size_t>(pool_slot) + 1 >= _family_cohort_offsets.size()) return 0;
    const int32_t pool_begin = _family_cohort_offsets[pool_slot];
    const int32_t pool_end = _family_cohort_offsets[pool_slot + 1];
    if (pool_begin == pool_end) return 0;
    const uint64_t building_handle = buildings_store().modifier_handle[group_index];
    const uint64_t pool_handle = population_store().handle_for_slot(pool_slot);
    uint64_t best = 0;
    int64_t best_owned = 0;
    for (int32_t p = _family_building_offsets[group_index];
         p < _family_building_offsets[group_index + 1]; ++p) {
        const int32_t index = _family_building_edge_indices[p];
        if (index < 0 || index >= static_cast<int32_t>(family_ownerships().size())) continue;
        const FamilyBuildingOwnership &ownership = family_ownerships().read_at(
            index, __FILE__, __LINE__);
        if (ownership.building_handle != building_handle || ownership.owned_count <= 0 ||
            ownership.owned_count < best_owned) continue;
        for (int32_t q = pool_begin; q < pool_end; ++q) {
            const int32_t edge = _family_cohort_edge_indices[q];
            if (edge < 0 || static_cast<size_t>(edge) >= family_memberships().size()) continue;
            const FamilyMembershipEdge &member = family_memberships()[edge];
            if (member.cohort_handle != pool_handle ||
                member.family_handle != ownership.family_handle || member.people <= 0)
                continue;
            if (ownership.owned_count > best_owned ||
                (ownership.owned_count == best_owned && ownership.family_handle < best)) {
                best = ownership.family_handle;
                best_owned = ownership.owned_count;
            }
            break;
        }
    }
    return best;
}

void NativeEconomyRuntime::settle_family_claim_ledger() {
    const size_t edge_count = family_memberships().size();
    _family_ledger_business_by_edge.assign(edge_count, 0);
    if (_family_ledger_business_by_slot.size() < population_store().active.size())
        _family_ledger_business_by_slot.resize(population_store().active.size(), 0);
    _family_ledger_touched_slots.clear();
    int64_t sat = 0;
    if (_family_building_offsets.size() == building_count() + 1 &&
        _family_cell_offsets.size() == static_cast<size_t>(_cell_count.get()) + 1 &&
        _building_cell_offsets.size() == static_cast<size_t>(_cell_count.get()) + 1) {
        for (int32_t cell = 0; cell < _cell_count.get(); ++cell) {
            if (_family_cell_offsets[cell] == _family_cell_offsets[cell + 1]) continue;
            for (int32_t g = _building_cell_offsets[cell];
                 g < _building_cell_offsets[cell + 1]; ++g) {
                const auto group = building_view(static_cast<size_t>(g));
                if (group.count <= 0 || group.owner_signature_id < 0) continue;
                const int32_t owner_slot = find_cohort_slot(cell, group.owner_signature_id);
                if (owner_slot < 0 || static_cast<size_t>(owner_slot) + 1 >=
                        _family_cohort_offsets.size() ||
                    _family_cohort_offsets[owner_slot] ==
                        _family_cohort_offsets[owner_slot + 1]) continue;
                const int64_t net = saturating_sub(saturating_sub(saturating_sub(
                    group.last_revenue, group.last_input_cost, sat),
                    group.last_wages_paid, sat), group.last_maintenance_cost, sat);
                if (net == 0) continue;
                if (_family_ledger_business_by_slot[owner_slot] == 0)
                    _family_ledger_touched_slots.push_back(owner_slot);
                _family_ledger_business_by_slot[owner_slot] = saturating_add(
                    _family_ledger_business_by_slot[owner_slot], net, sat);
                for (int32_t p = _family_building_offsets[g];
                     p < _family_building_offsets[g + 1]; ++p) {
                    const FamilyBuildingOwnership &ownership = family_ownerships().read_at(
                        _family_building_edge_indices[p], __FILE__, __LINE__);
                    // Profit follows the posts the family actually staffs;
                    // an idle group's carrying cost follows ownership.
                    const int64_t share = group.filled_owner > 0
                        ? mul_div_sat(net, std::max<int64_t>(0, ownership.filled_owner),
                                      group.filled_owner, sat)
                        : mul_div_sat(net, std::max<int64_t>(0, ownership.owned_count),
                                      group.count, sat);
                    if (share == 0) continue;
                    for (int32_t q = _family_cohort_offsets[owner_slot];
                         q < _family_cohort_offsets[owner_slot + 1]; ++q) {
                        const int32_t edge = _family_cohort_edge_indices[q];
                        if (family_memberships()[edge].family_handle !=
                                ownership.family_handle) continue;
                        _family_ledger_business_by_edge[edge] = saturating_add(
                            _family_ledger_business_by_edge[edge], share, sat);
                        break;
                    }
                }
            }
        }
    }
    _saturation_count = saturating_add(_saturation_count, sat, _saturation_count);
}

void NativeEconomyRuntime::release_unstaffable_family_ownership(int32_t family_index) {
    if (family_index < 0 ||
        _family_owned_offsets.size() != families_store().active.size() + 1) return;
    const uint64_t handle = families_store().handle_for_index(family_index);
    for (int32_t p = _family_owned_offsets[family_index];
         p < _family_owned_offsets[family_index + 1]; ++p) {
        const int32_t ownership_index = _family_owned_edge_indices[p];
        const FamilyBuildingOwnership &ownership = family_ownerships().read_at(
            ownership_index, __FILE__, __LINE__);
        if (ownership.family_handle != handle || ownership.owned_count <= 0) continue;
        const int32_t building = building_index_for_handle(ownership.building_handle);
        if (building < 0) continue;
        const auto group = building_view(static_cast<size_t>(building));
        const int32_t owner_slot = find_cohort_slot(group.cell, group.owner_signature_id);
        int64_t members = 0;
        if (owner_slot >= 0) {
            collect_family_edges_for_cohort(owner_slot, _family_edge_scratch);
            for (int32_t edge : _family_edge_scratch)
                if (family_memberships()[edge].family_handle == handle)
                    members += std::max<int64_t>(0, family_memberships()[edge].people);
        }
        if (members > 0) continue;
        // Open owner seats plus idle members of the owner ethnicity: owner
        // hiring pulls this family first, so keep the units for that pass.
        if (group.owner_signature_id >= 0 &&
            group.owner_signature_id < static_cast<int32_t>(_signatures.size()) &&
            group.filled_owner < planned_owner_demand(group, _saturation_count)) {
            const int32_t unemployed = unemployed_signature_for_ethnicity(
                _signatures[group.owner_signature_id].ethnicity_id);
            const int32_t pool = unemployed >= 0
                ? find_cohort_slot(group.cell, unemployed) : -1;
            bool idle_members = false;
            if (pool >= 0) {
                collect_family_edges_for_cohort(pool, _family_edge_scratch);
                for (int32_t edge : _family_edge_scratch)
                    if (family_memberships()[edge].family_handle == handle &&
                        family_memberships()[edge].people > 0) {
                        idle_members = true;
                        break;
                    }
            }
            if (idle_members) {
                ++_family_release_deferred;
                continue;
            }
        }
        // Release in steps so one bad review cannot strip a branch.
        auto ownership_write = family_ownerships().edit_row(ownership_index,
                                                           market_mutation_sink());
        const int64_t owned = ownership_write[0].owned_count;
        const int64_t released = std::min(owned, std::max<int64_t>(1,
            (owned + FAMILY_RELEASE_STEP_DIVISOR - 1) / FAMILY_RELEASE_STEP_DIVISOR));
        _family_units_released += released;
        ownership_write[0].owned_count = owned - released;
        ownership_write[0].filled_owner = 0;
        _family_indices_dirty = true;
    }
}

} // namespace pk
