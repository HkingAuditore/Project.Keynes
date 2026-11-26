#include "economy_runtime_building_commit_includes.inc"

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
    const int32_t sorted_group_count = static_cast<int32_t>(building_count());
    // The sorted prefix contains all groups that existed before this commit.
    // Groups appended while committing this batch are not in that prefix, so
    // keep a transient exact-key index instead of re-scanning the growing
    // suffix for every ready construction record.
    struct AppendedGroupKey {
        int32_t cell = -1;
        int32_t type_id = -1;
        int32_t owner_signature_id = -1;

        bool operator==(const AppendedGroupKey &other) const {
            return cell == other.cell && type_id == other.type_id &&
                   owner_signature_id == other.owner_signature_id;
        }
    };
    struct AppendedGroupKeyHash {
        size_t operator()(const AppendedGroupKey &key) const {
            uint64_t value = static_cast<uint32_t>(key.cell);
            value = (value << 21) ^ static_cast<uint32_t>(key.type_id);
            value = (value << 21) ^ static_cast<uint32_t>(key.owner_signature_id);
            value ^= value >> 33;
            value *= 0xff51afd7ed558ccdULL;
            value ^= value >> 33;
            return static_cast<size_t>(value);
        }
    };
    std::unordered_map<AppendedGroupKey, int32_t, AppendedGroupKeyHash>
        appended_group_indices;
    appended_group_indices.reserve(std::min<size_t>(
        pending_construction_count(), 8192));
    const RuntimeEconomyBuildingStore &group_store = buildings_store();
    const auto group_key = [&](int32_t row) {
        return std::tuple(group_store.cell[row], group_store.type_id[row],
                          group_store.owner_signature_id[row]);
    };
    const auto find_for_commit = [&](int32_t cell, int32_t type_id,
                                     int32_t owner_signature_id) {
        const auto target = std::tuple(cell, type_id, owner_signature_id);
        int32_t low = 0;
        int32_t high = sorted_group_count;
        while (low < high) {
            const int32_t mid = low + (high - low) / 2;
            if (group_key(mid) < target) {
                low = mid + 1;
            } else {
                high = mid;
            }
        }
        if (low < sorted_group_count && group_key(low) == target) return low;
        const auto appended = appended_group_indices.find(
            {cell, type_id, owner_signature_id});
        if (appended != appended_group_indices.end()) return appended->second;
        return -1;
    };
    // Appending a group must not invalidate a reference into the pending
    // columns, so rows are copied out by index instead of iterated in place.
    for (size_t pending_row = 0; pending_row < pending_construction_count();
         ++pending_row) {
        const PendingConstruction pending =
            pending_construction_copy(pending_row);
        if (pending.ready_day > _current_day.get()) continue;
        if (pending.sponsor_family_handle != 0)
            sponsored_completed.push_back(pending);
        changed = true;
        changed_cells.push_back(pending.cell);
        const int32_t existing = find_for_commit(
            pending.cell, pending.type_id, pending.owner_signature_id);
        const int64_t before_count = existing >= 0 ? buildings_store().group_units[existing] : 0;
        record_annual_event(pending.cell, AnnualMetric::BUILT, pending.count);
        int32_t group_index = existing;
        if (existing >= 0) {
            ++_building_structure_count_only_updates;
            buildings_store().group_units.write_scalar(existing, saturating_add(buildings_store().group_units[existing],
                                                        pending.count, _saturation_count));
            _building_handle_index_clean = false;
            buildings_store().merchant_debt_principal.write_scalar(existing, saturating_add(
                buildings_store().merchant_debt_principal[existing],
                pending.merchant_debt_principal, _saturation_count));
            buildings_store().merchant_debt_premium.write_scalar(existing, saturating_add(
                buildings_store().merchant_debt_premium[existing],
                pending.merchant_debt_premium, _saturation_count));
            if (pending.merchant_debt_principal > 0 ||
                pending.merchant_debt_premium > 0) {
                buildings_store().merchant_debt_term_cycles_left.write_scalar(existing, static_cast<uint16_t>(_merchant_credit_term_cycles.get()));
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
            append_building_group(group);
            group_index = static_cast<int32_t>(building_count()) - 1;
            appended_group_indices.emplace(
                AppendedGroupKey{pending.cell, pending.type_id,
                    pending.owner_signature_id},
                group_index);
            topology_changed = true;
            ++_building_structure_new_groups;
        }
        // Investment without seating is meaningless. Seat exactly the owner
        // lots this pending batch created (count × slots) — the same headcount
        // investment already moved onto the owner signature — not the entire
        // cohort or every prior empty opening on the group.
        if (group_index >= 0 &&
            pending.type_id >= 0 &&
            pending.type_id < static_cast<int32_t>(_building_types.size())) {
            const BuildingType &type = _building_types[pending.type_id];
            const int64_t add_owners = saturating_mul(
                std::max<int64_t>(0, pending.count),
                std::max<int64_t>(1, type.owner_slots_per_building),
                _saturation_count);
            const int64_t owner_required = saturating_mul(
                std::max<int64_t>(0, buildings_store().group_units[group_index]),
                std::max<int64_t>(1, type.owner_slots_per_building),
                _saturation_count);
            int64_t seated = saturating_add(
                std::max<int64_t>(0, buildings_store().filled_owner[group_index]),
                add_owners, _saturation_count);
            seated = std::min(seated, owner_required);
            buildings_store().filled_owner.write_scalar(group_index, seated);
        }
        const int64_t after_count = existing >= 0 ? buildings_store().group_units[existing]
                                                   : buildings_store().group_units.back();
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
            // Same registry the economy rows use, so a trigger effect aimed at
            // this building lands on the handle production evaluates.
            if (_modifier_runtime != nullptr)
                fact.entity_handle = modifier_api::ensure_building_identity(
                    *_modifier_runtime, pending.cell, pending.type_id,
                    pending.owner_signature_id);
            _staging_gameplay_facts.push_back(fact);
        }
    }
    changed = erase_ready_pending_construction(_current_day.get()) > 0 || changed;
    if (prune_empty_groups || topology_changed) {
        for (size_t pk_row = 0; pk_row < building_count(); ++pk_row) {
            const auto group = building_view(pk_row);
            if (group.count > 0) continue;
            // A zero-count row now stays in the store for the rest of the
            // session (collapse v2, 2026-11-26). Retiring its identity was
            // already idempotent, but the sweep treated the row as a fresh
            // structural change every period, so one collapsed lot rebuilt the
            // whole role storage and re-counted itself once per epoch forever.
            // Only the call that actually retires an identity is a change.
            //
            // With no modifier runtime there is no identity to observe, so the
            // "first visit" question cannot be answered; keep treating the row
            // as a structural change instead of assuming it was pruned earlier.
            // Skipping there would leave the cell topology stale, which is the
            // fail-open this guard must not reintroduce.
            bool retired_now = true;
            if (_modifier_runtime != nullptr) {
                retired_now = modifier_api::retire_building_identity(
                    *_modifier_runtime, group.cell, group.type_id,
                    group.owner_signature_id, _current_day.get());
            }
            if (!retired_now) continue;  // already pruned in an earlier period
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
        if (!families_store().valid_handle(pending.sponsor_family_handle, family))
            continue;
        const int32_t group_index = find_building_group(
            pending.cell, pending.type_id, pending.owner_signature_id);
        if (group_index < 0 || buildings_store().modifier_handle[group_index] == 0)
            continue;
        family_ownerships().push_back({pending.sponsor_family_handle,
            buildings_store().modifier_handle[group_index], pending.count, 0});
        _family_indices_dirty = true;
    }
    return changed;
}

using namespace variant_helpers;

bool NativeEconomyRuntime::seed_worker_resource_reserves(
        int64_t initial_day, const std::vector<const float *> &reserves,
        const std::vector<const float *> &changes) {
    if (_worker_resource_seeded) return true;
    const int32_t count = _cell_count.get();
    const size_t resource_count = _resource_ids.size();
    if (count <= 0 || reserves.size() != resource_count || changes.size() != resource_count)
        return false;
    const size_t lanes = static_cast<size_t>(count) * resource_count;
    const bool restored = _resource_stock_restored_pending_capture &&
        resource_stock_lanes().size() == lanes;
    _worker_resource_reserve.assign(lanes, 0.0f);
    _worker_resource_extra.assign(lanes, 0.0f);
    for (size_t resource = 0; resource < resource_count; ++resource) {
        for (int32_t cell = 0; cell < count; ++cell) {
            const size_t lane = resource * static_cast<size_t>(count) + cell;
            if (restored) {
                _worker_resource_reserve[lane] = static_cast<float>(
                    static_cast<double>(resource_stock_lanes()[lane]) /
                    static_cast<double>(GOODS_SCALE));
            } else {
                if (reserves[resource]) _worker_resource_reserve[lane] = reserves[resource][cell];
                if (changes[resource]) _worker_resource_extra[lane] = changes[resource][cell];
            }
        }
    }
    if (resource_stock_lanes().size() != lanes)
        resource_stock_lanes().assign(lanes, 0);
    _worker_resource_extra_dirty.assign(resource_count, 1);
    const int32_t last_day = static_cast<int32_t>(std::clamp<int64_t>(
        initial_day, 0, std::numeric_limits<int32_t>::max()));
    _worker_resource_last_day.assign(static_cast<size_t>(count), last_day);
    _worker_resource_was_live.assign(static_cast<size_t>(count), 0);
    _worker_resource_cell_live.assign(static_cast<size_t>(count), 0);
    _worker_resource_mirror_mark.assign(static_cast<size_t>(count), 0);
    _worker_resource_mirror_cells.clear();
    _worker_resource_regen_factors.assign(static_cast<size_t>(count), 1.0f);
    _worker_resource_seeded = true;
    for (size_t lane = 0; lane < lanes; ++lane) write_worker_resource_stock(lane);
    for (int32_t cell = 0; cell < count; ++cell) mark_worker_resource_mirror_cell(cell);
    return true;
}

bool NativeEconomyRuntime::advance_worker_resource_reserves(
        const RuntimeEconomyDayInput &input, std::string &error) {
    const int32_t count = _cell_count.get();
    const size_t resource_count = _resource_ids.size();
    const size_t lanes = static_cast<size_t>(count) * resource_count;
    if (count <= 0 || resource_count == 0) return true;
    const int32_t day = static_cast<int32_t>(std::clamp<int64_t>(
        input.day, 0, std::numeric_limits<int32_t>::max()));
    if (!_worker_resource_seeded || _worker_resource_reserve.size() != lanes || _worker_resource_extra.size() != lanes ||
        _worker_resource_last_day.size() != static_cast<size_t>(count)) {
        error = "economy_worker_resource_shape_invalid";
        return false;
    }

    // Economy is still between epochs here. Use the committed population and
    // buildings both after a normal commit and after restoring that commit.
    collect_economy_live_cells(_worker_resource_live_cells, nullptr);
    const auto plan = plan_natural_resource_recovery(day, _worker_resource_live_cells.data(),
        _worker_resource_live_cells.size(), true, _worker_resource_last_day,
        _worker_resource_was_live, _worker_resource_cell_live);
    const auto &cells = plan.cells;
    const auto &cell_dt = plan.elapsed_days;
    _worker_resource_recovered_cells = static_cast<int32_t>(cells.size());

    const bool have_habitat = input.resource_habitat.size() == static_cast<size_t>(count);
    const uint8_t *habitat = have_habitat ? input.resource_habitat.data() : nullptr;
    const bool have_water = input.geography[3].size() == static_cast<size_t>(count);
    const uint8_t *water = have_water ? input.geography[3].data() : nullptr;
    const auto *modifier = _modifier_runtime;
    const bool modifier_ready = modifier != nullptr && modifier_api::configured(*modifier);
    const int32_t generic_stat = modifier_ready
        ? modifier_api::stat_id_for_key(*modifier, "economy.city.resource.regen_factor") : -1;

    if (!cells.empty()) {
        std::vector<NatResRuntime> active;
        active.reserve(resource_count);
        for (size_t r = 0; r < resource_count; ++r) {
            const WorkerNaturalResource &config = _worker_natural_resources[r];
            if (config.habitat_mode < 0 || config.habitat_mode > 5) continue;
            if (!config.constants.has_natural_dynamics && _worker_resource_extra_dirty[r] == 0)
                continue;
            NatResRuntime rr = config.constants;
            rr.resource_index = static_cast<int>(r);
            rr.R = _worker_resource_reserve.data() + r * static_cast<size_t>(count);
            rr.X = _worker_resource_extra.data() + r * static_cast<size_t>(count);
            rr.use_extra = true;
            rr.temperature = config.temperature_signal == 1
                ? input.fields[1].data() : input.fields[0].data();
            rr.moisture = config.moisture_signal == 1
                ? input.fields[3].data() : input.fields[2].data();
            rr.land_gate = config.habitat_mode == 1 && have_water;
            rr.habitat_bit = natres_habitat_bit(config.habitat_mode);
            rr.regen_factors = nullptr;
            rr.has_regen_modifier = false;
            active.push_back(rr);
        }
        double seg = 0.0;
        for (NatResRuntime &rr : active) {
            const int32_t resource_stat = modifier_ready
                ? modifier_api::stat_id_for_key(*modifier, "economy.city.resource." +
                    _resource_ids[static_cast<size_t>(rr.resource_index)] + ".regen_factor")
                : -1;
            if (generic_stat >= 0 || resource_stat >= 0) {
                std::vector<float> &factors = _worker_resource_regen_factors;
                bool any = false;
                for (const int32_t cell : cells) {
                    double factor = 1.0;
                    if (generic_stat >= 0)
                        factor = modifier_api::effective_value(*modifier, ModifierApi::ECONOMY,
                            generic_stat, 0, static_cast<uint64_t>(cell), 1.0);
                    if (resource_stat >= 0)
                        factor = modifier_api::effective_value(*modifier, ModifierApi::ECONOMY,
                            resource_stat, 0, static_cast<uint64_t>(cell), factor);
                    if (!std::isfinite(factor) || factor < 0.0) factor = 1.0;
                    factors[static_cast<size_t>(cell)] = static_cast<float>(factor);
                    if (std::fabs(factor - 1.0) > 1e-7) any = true;
                }
                if (any) {
                    // Factors are rewritten per resource; run this resource now.
                    rr.regen_factors = factors.data();
                    rr.has_regen_modifier = true;
                    for (size_t k = 0; k < cells.size(); ++k)
                        natres_apply_one_cell(rr, cells[k], cell_dt[k], have_habitat,
                                              habitat, have_water, water, seg);
                    rr.R = nullptr;
                }
            }
        }
        for (size_t k = 0; k < cells.size(); ++k) {
            for (const NatResRuntime &rr : active) {
                if (rr.R == nullptr) continue;
                natres_apply_one_cell(rr, cells[k], cell_dt[k], have_habitat,
                                      habitat, have_water, water, seg);
            }
        }
        commit_natural_resource_recovery(day, plan, _worker_resource_last_day,
                                         _worker_resource_was_live);
        for (const int32_t cell : cells) {
            for (size_t r = 0; r < resource_count; ++r)
                write_worker_resource_stock(r * static_cast<size_t>(count) + cell);
            mark_worker_resource_mirror_cell(cell);
        }
    }
    return true;
}

} // namespace pk
