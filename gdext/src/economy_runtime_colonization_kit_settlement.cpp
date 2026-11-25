#include "economy_runtime.h"
#include "country_api.h"
#include "modifier_api.h"
#include "economy_host_port.h"

#include <algorithm>
#include <limits>
#include <tuple>

namespace pk {

bool NativeEconomyRuntime::settle_family_expedition_kit(
        int32_t expedition, int32_t destination_cell, std::string &error) {
    if (!restore_family_expedition_cargo(expedition, destination_cell, true,
            error))
        return false;
    const uint32_t count = family_expeditions_store().kit_building_count[expedition];
    const uint32_t begin = family_expeditions_store().kit_building_begin[expedition];
    const uint32_t end = begin + count;
    if (end > family_expedition_kit_buildings().size()) {
        error = "colonization_kit_building_range_invalid";
        return false;
    }
    if (count == 0) return true;
    const uint64_t family_handle =
        family_expeditions_store().family_handle[expedition];
    int32_t family = -1;
    // 无家族移民队也会安家：族裔取目标格已有住户，产业不登记到任何家族名下。
    const bool caravan = family_handle == 0;
    if (!caravan && !families_store().valid_handle(family_handle, family)) {
        error = "colonization_family_invalid";
        return false;
    }
    int32_t ethnicity = caravan ? -1 : families_store().origin_ethnicity[family];
    if (ethnicity < 0) {
        population_store().for_each_in_cell(destination_cell, [&](int32_t slot) {
            if (ethnicity >= 0) return;
            const int32_t signature =
                static_cast<int32_t>(population_store().signature_id[slot]);
            if (signature >= 0 &&
                signature < static_cast<int32_t>(_signatures.size()))
                ethnicity = _signatures[signature].ethnicity_id;
        });
    }
    bool inserted = false;
    bool inserted_new_group = false;
    std::vector<std::pair<int32_t, int64_t>> placed;
    for (uint32_t i = begin; i < end; ++i) {
        const FamilyExpeditionKitBuilding &row =
            family_expedition_kit_buildings()[i];
        if (row.type_id < 0 ||
            row.type_id >= static_cast<int32_t>(_building_types.size()) ||
            row.count <= 0)
            continue;
        const BuildingType &type = _building_types[row.type_id];
        const int32_t owner_signature = signature_for_profession_ethnicity(
            type.owner_profession_id, std::max(0, ethnicity));
        if (owner_signature < 0) continue;
        const int32_t existing = find_building_group(
            destination_cell, row.type_id, owner_signature);
        if (existing >= 0) {
            buildings_store().group_units.write_scalar(existing, saturating_add(
                buildings_store().group_units[existing], row.count, _saturation_count));
            _building_handle_index_clean = false;
            if (_modifier_runtime != nullptr &&
                buildings_store().modifier_handle[existing] == 0) {
                buildings_store().modifier_handle.write_scalar(existing, modifier_api::ensure_building_identity(*_modifier_runtime,
                        destination_cell, row.type_id, owner_signature));
            }
        } else {
            BuildingGroup group;
            group.cell = destination_cell;
            group.type_id = row.type_id;
            group.owner_signature_id = owner_signature;
            group.count = row.count;
            if (_modifier_runtime != nullptr) {
                group.modifier_handle =
                    modifier_api::ensure_building_identity(*_modifier_runtime,
                        destination_cell, row.type_id, owner_signature);
            }
            append_building_group(group);
            ++_building_structure_new_groups;
            inserted_new_group = true;
        }
        placed.push_back({row.type_id, row.count});
        inserted = true;
    }
    ColonizationKitPlan extra;
    int64_t used_slots = 0;
    for (int32_t group = 0; group < static_cast<int32_t>(building_count());
         ++group) {
        if (buildings_store().cell[group] != destination_cell ||
            buildings_store().group_units[group] <= 0)
            continue;
        const int32_t type_id = buildings_store().type_id[group];
        if (type_id < 0 ||
            type_id >= static_cast<int32_t>(_building_types.size()))
            continue;
        used_slots = saturating_add(used_slots, saturating_mul(
            buildings_store().group_units[group],
            std::max<int64_t>(1,
                _building_types[type_id].owner_slots_per_building),
            _saturation_count), _saturation_count);
    }
    const int64_t remaining_slots = std::max<int64_t>(0,
        family_expeditions_store().population[expedition] +
            family_expeditions_store().anonymous[expedition] - used_slots);
    if (remaining_slots > 0 &&
        plan_colonization_kit(destination_cell, destination_cell,
            remaining_slots, 1, true, extra, true) &&
        extra.place_buildings != 0 && !extra.buildings.empty()) {
        bool extra_affordable = true;
        for (const FamilyExpeditionCargoLine &line : extra.cargo) {
            if (line.flags != EXPEDITION_CARGO_CONSTRUCTION ||
                line.quantity <= 0)
                continue;
            if (market_stock(destination_cell, line.good_id) < line.quantity) {
                extra_affordable = false;
                break;
            }
        }
        if (extra_affordable) {
            int64_t extra_construction_consumed = 0;
            for (const FamilyExpeditionCargoLine &line : extra.cargo) {
                if (line.flags != EXPEDITION_CARGO_CONSTRUCTION ||
                    line.quantity <= 0)
                    continue;
                std::string ignored;
                if (adjust_market_stock(destination_cell, line.good_id,
                        -line.quantity, ignored)) {
                    extra_construction_consumed = saturating_add(
                        extra_construction_consumed, line.quantity,
                        _saturation_count);
                }
            }
            if (_epoch_active)
                _construction_goods_consumed = saturating_add(
                    _construction_goods_consumed, extra_construction_consumed,
                    _saturation_count);
            for (const FamilyExpeditionKitBuilding &row : extra.buildings) {
                if (row.type_id < 0 ||
                    row.type_id >= static_cast<int32_t>(_building_types.size()) ||
                    row.count <= 0)
                    continue;
                const BuildingType &type = _building_types[row.type_id];
                const int32_t owner_signature =
                    signature_for_profession_ethnicity(
                        type.owner_profession_id, std::max(0, ethnicity));
                if (owner_signature < 0) continue;
                const int32_t existing = find_building_group(
                    destination_cell, row.type_id, owner_signature);
                if (existing >= 0) {
                    buildings_store().group_units.write_scalar(existing, saturating_add(
                        buildings_store().group_units[existing], row.count,
                        _saturation_count));
                    _building_handle_index_clean = false;
                    if (_modifier_runtime != nullptr &&
                        buildings_store().modifier_handle[existing] == 0) {
                        buildings_store().modifier_handle.write_scalar(existing, modifier_api::ensure_building_identity(*_modifier_runtime,
                                destination_cell, row.type_id, owner_signature));
                    }
                } else {
                    BuildingGroup group;
                    group.cell = destination_cell;
                    group.type_id = row.type_id;
                    group.owner_signature_id = owner_signature;
                    group.count = row.count;
                    if (_modifier_runtime != nullptr) {
                        group.modifier_handle =
                            modifier_api::ensure_building_identity(*_modifier_runtime,
                                destination_cell, row.type_id, owner_signature);
                    }
                    append_building_group(group);
                    ++_building_structure_new_groups;
                    inserted_new_group = true;
                }
                placed.push_back({row.type_id, row.count});
                inserted = true;
            }
        }
    }
    if (!inserted) return true;
    // Do not rebuild market/labor CSRs during LEDGER_APPLY. Frozen epoch
    // production reserves and group-parallel arrays are keyed by the
    // epoch-begin permutation; inserting a mid-index cell would shift every
    // later signal and fail goods conservation on a live map. Append like
    // commit_ready_construction and wait for BUILDING_COMMIT. Idle landings
    // have no frozen workset, so they rebuild immediately for Inspector.
    if (inserted_new_group) {
        if (_epoch_active)
            _pending_building_topology_rebuild = true;
        else {
            rebuild_building_role_storage();
            refresh_building_modifier_factors();
        }
    }

    for (const auto &row : placed) {
        const BuildingType &type = _building_types[row.first];
        const int32_t owner_signature = signature_for_profession_ethnicity(
            type.owner_profession_id, std::max(0, ethnicity));
        if (owner_signature < 0) continue;
        const int64_t needed = saturating_mul(row.second,
            std::max<int64_t>(1, type.owner_slots_per_building),
            _saturation_count);
        int32_t owner_slot = find_cohort_slot(destination_cell, owner_signature);
        int64_t have = owner_slot >= 0 ? population_store().population[owner_slot] : 0;
        int64_t missing = std::max<int64_t>(0, needed - have);
        struct Candidate {
            int32_t slot = -1;
            bool unemployed = false;
            int32_t profession = 0;
            int32_t ethnicity_id = 0;
            uint64_t handle = 0;
        };
        std::vector<Candidate> candidates;
        population_store().for_each_in_cell(destination_cell, [&](int32_t slot) {
            if (population_store().population[slot] <= 0) return;
            const int32_t signature =
                static_cast<int32_t>(population_store().signature_id[slot]);
            if (signature == owner_signature) return;
            if (signature < 0 ||
                signature >= static_cast<int32_t>(_signatures.size()))
                return;
            candidates.push_back({slot,
                _signatures[signature].profession_id ==
                    _unemployed_profession_id,
                _signatures[signature].profession_id,
                _signatures[signature].ethnicity_id,
                population_store().handle_for_slot(slot)});
        });
        std::sort(candidates.begin(), candidates.end(),
            [](const Candidate &a, const Candidate &b) {
                return std::tuple(!a.unemployed, a.profession, a.ethnicity_id,
                    a.handle) <
                    std::tuple(!b.unemployed, b.profession, b.ethnicity_id,
                        b.handle);
            });
        int64_t remaining_merchants = living_merchant_population(destination_cell);
        for (const Candidate &candidate : candidates) {
            if (missing <= 0) break;
            if (candidate.slot < 0 ||
                candidate.slot >= static_cast<int32_t>(population_store().active.size()) ||
                population_store().active[candidate.slot] == 0)
                continue;
            const bool from_merchant = is_merchant_slot(candidate.slot);
            int64_t take = std::min(missing,
                population_store().population[candidate.slot]);
            if (from_merchant)
                take = std::min(take, std::max<int64_t>(0, remaining_merchants - 1));
            if (take <= 0) continue;
            if (!move_cohort_population(candidate.slot, destination_cell,
                    owner_signature, take, error, nullptr, family_handle, true))
                return false;
            missing -= take;
            if (from_merchant)
                remaining_merchants = std::max<int64_t>(
                    0, remaining_merchants - take);
        }
        owner_slot = find_cohort_slot(destination_cell, owner_signature);
        const int32_t group_index = find_building_group(
            destination_cell, row.first, owner_signature);
        if (group_index >= 0) {
            const int64_t filled = owner_slot >= 0
                ? std::min(needed, population_store().population[owner_slot]) : 0;
            buildings_store().filled_owner.write_scalar(group_index, filled);
            if (owner_slot >= 0)
                population_store().owner_employed.write_scalar(owner_slot, std::max(
                    population_store().owner_employed[owner_slot], filled), market_mutation_sink());
            if (!caravan && buildings_store().modifier_handle[group_index] != 0) {
                bool found = false;
                for (size_t edge_row = 0; edge_row < family_ownerships().size(); ++edge_row) {
        auto edge_write = family_ownerships().edit_row(edge_row, market_mutation_sink());
        FamilyBuildingOwnership &edge = edge_write[0];
                    if (edge.family_handle == family_handle &&
                        edge.building_handle ==
                            buildings_store().modifier_handle[group_index]) {
                        edge.owned_count = saturating_add(
                            edge.owned_count, row.second, _saturation_count);
                        edge.filled_owner = std::max(edge.filled_owner,
                            filled);
                        found = true;
                        break;
                    }
                }
                if (!found) {
                    family_ownerships().push_back({family_handle,
                        buildings_store().modifier_handle[group_index], row.second,
                        filled});
                }
                _family_indices_dirty = true;
            }
        }
    }
    _structural_touched_cells.push_back(destination_cell);
    // Staffing moved people out of cohorts that may carry job lanes restored
    // from the source, and raised owner lanes without looking at employees.
    clip_cell_employment_and_defer_reconcile(destination_cell);
    return true;
}

} // namespace pk
