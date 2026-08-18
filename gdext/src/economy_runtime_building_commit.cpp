#include "economy_runtime.h"
#include "modifier_runtime.h"

#include <algorithm>
#include <tuple>

namespace pk {

using namespace godot;

bool NativeEconomyRuntime::commit_ready_construction(
        std::vector<int32_t> &changed_cells, bool prune_empty_groups) {
    bool changed = false;
    bool topology_changed = false;
    if (_pending_building_topology_rebuild) {
        // Sort kit-appended groups into the compact lane before lower_bound
        // treats the current size as a fully ordered prefix.
        rebuild_building_role_storage();
        refresh_building_modifier_factors();
        _pending_building_topology_rebuild = false;
        changed = true;
    }
    std::vector<PendingConstruction> sponsored_completed;
    const int32_t sorted_group_count = static_cast<int32_t>(_buildings.size());
    const auto group_key = [](const BuildingGroup &group) {
        return std::tuple(group.cell, group.type_id, group.owner_signature_id);
    };
    const auto find_for_commit = [&](int32_t cell, int32_t type_id,
                                     int32_t owner_signature_id) {
        const auto target = std::tuple(cell, type_id, owner_signature_id);
        const auto first = _buildings.begin();
        const auto last = first + sorted_group_count;
        const auto it = std::lower_bound(first, last, target,
            [&](const BuildingGroup &group, const auto &value) {
                return group_key(group) < value;
            });
        if (it != last && group_key(*it) == target)
            return static_cast<int32_t>(it - first);
        for (int32_t index = sorted_group_count;
             index < static_cast<int32_t>(_buildings.size()); ++index) {
            if (group_key(_buildings[index]) == target) return index;
        }
        return -1;
    };
    for (const PendingConstruction &pending : _pending_construction) {
        if (pending.ready_day > _current_day) continue;
        if (pending.sponsor_family_handle != 0)
            sponsored_completed.push_back(pending);
        changed = true;
        changed_cells.push_back(pending.cell);
        const int32_t existing = find_for_commit(
            pending.cell, pending.type_id, pending.owner_signature_id);
        const int64_t before_count = existing >= 0 ? _buildings[existing].count : 0;
        if (existing >= 0) {
            ++_building_structure_count_only_updates;
            _buildings[existing].count = saturating_add(_buildings[existing].count,
                                                        pending.count, _saturation_count);
            _building_handle_index_clean = false;
            _buildings[existing].merchant_debt_principal = saturating_add(
                _buildings[existing].merchant_debt_principal,
                pending.merchant_debt_principal, _saturation_count);
            _buildings[existing].merchant_debt_premium = saturating_add(
                _buildings[existing].merchant_debt_premium,
                pending.merchant_debt_premium, _saturation_count);
            if (pending.merchant_debt_principal > 0 ||
                pending.merchant_debt_premium > 0) {
                _buildings[existing].merchant_debt_term_cycles_left =
                    static_cast<uint16_t>(_merchant_credit_term_cycles);
            }
        } else {
            BuildingGroup group;
            group.cell = pending.cell;
            group.type_id = pending.type_id;
            group.owner_signature_id = pending.owner_signature_id;
            group.count = pending.count;
            group.merchant_debt_principal = pending.merchant_debt_principal;
            group.merchant_debt_premium = pending.merchant_debt_premium;
            group.merchant_debt_term_cycles_left =
                pending.merchant_debt_term_cycles_left;
            _buildings.push_back(group);
            topology_changed = true;
            ++_building_structure_new_groups;
        }
        const int64_t after_count = existing >= 0 ? _buildings[existing].count
                                                   : _buildings.back().count;
        std::vector<EventLeg> legs;
        if (trace_detail_for_cell(pending.cell)) {
            legs.push_back({FIELD_BUILDING_COUNT, SUBJECT_BUILDING_GROUP,
                            pending.owner_signature_id, pending.type_id,
                            before_count, after_count});
        }
        trace_append(EVENT_CONSTRUCTION_COMPLETED,
                     static_cast<int32_t>(Stage::BUILDING_COMMIT), pending.cell,
                     SUBJECT_BUILDING_GROUP, pending.owner_signature_id,
                     pending.type_id, -1, pending.count, before_count,
                     after_count, pending.sequence,
                     legs.empty() ? nullptr : &legs);
        if (pending.sequence >= 0) {
            CommittedGameplayFact fact;
            fact.kind = GAMEPLAY_FACT_CONSTRUCTION_COMPLETED;
            fact.cell = pending.cell;
            fact.entity_id = pending.type_id;
            fact.value = pending.count;
            const uint32_t type_hash = String(
                _building_type_ids[pending.type_id].c_str()).hash();
            fact.payload = {static_cast<int32_t>(type_hash), pending.type_id,
                pending.owner_signature_id,
                static_cast<int32_t>(pending.sponsor_family_handle & 0x7fffffffULL)};
            _staging_gameplay_facts.push_back(fact);
        }
    }
    const size_t pending_before = _pending_construction.size();
    _pending_construction.erase(std::remove_if(_pending_construction.begin(),
                                               _pending_construction.end(),
        [&](const PendingConstruction &p) { return p.ready_day <= _current_day; }),
        _pending_construction.end());
    changed = changed || _pending_construction.size() != pending_before;
    if (prune_empty_groups || topology_changed) {
        for (const BuildingGroup &group : _buildings) {
            if (group.count > 0) continue;
            if (_modifier_runtime != nullptr)
                _modifier_runtime->retire_building_identity(
                    group.cell, group.type_id, group.owner_signature_id,
                    _current_day);
            changed_cells.push_back(group.cell);
            topology_changed = true;
            changed = true;
            ++_building_structure_removed_groups;
        }
    }
    if (topology_changed) {
        ++_building_structure_topology_rebuilds;
        rebuild_building_role_storage();
        refresh_building_modifier_factors();
    }
    for (const PendingConstruction &pending : sponsored_completed) {
        int32_t family = -1;
        if (!_families.valid_handle(pending.sponsor_family_handle, family))
            continue;
        const int32_t group_index = find_building_group(
            pending.cell, pending.type_id, pending.owner_signature_id);
        if (group_index < 0 || _buildings[group_index].modifier_handle == 0)
            continue;
        _family_ownerships.push_back({pending.sponsor_family_handle,
            _buildings[group_index].modifier_handle, pending.count, 0});
        _family_indices_dirty = true;
    }
    return changed;
}

} // namespace pk
