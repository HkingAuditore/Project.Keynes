#include "economy_cost_probe.h"
#include "economy_runtime_variant_helpers.h"
#include "runtime_economy_pod.h"
#include "runtime_switch_registry.h"
#include <cmath>
#include <chrono>
#include <limits>
#include <cstring>
#include <numeric>
#include "economy_runtime.h"
#include "modifier_api.h"

#include <algorithm>
#include <tuple>
#include <unordered_map>

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
            _staging_gameplay_facts.push_back(fact);
        }
    }
    changed = erase_ready_pending_construction(_current_day.get()) > 0 || changed;
    if (prune_empty_groups || topology_changed) {
        for (size_t pk_row = 0; pk_row < building_count(); ++pk_row) {
            const auto group = building_view(pk_row);
            if (group.count > 0) continue;
            if (_modifier_runtime != nullptr)
                modifier_api::retire_building_identity(*_modifier_runtime,
                    group.cell, group.type_id, group.owner_signature_id,
                    _current_day.get());
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

namespace {
using Clock = std::chrono::steady_clock;
double elapsed_ms(const Clock::time_point &start) {
    return std::chrono::duration<double, std::milli>(Clock::now() - start).count();
}
} // namespace

namespace {
int32_t modifier_factor_q16(double factor) {
    if (!std::isfinite(factor) || factor <= 0.0) return 0;
    const double scaled = std::round(factor *
        static_cast<double>(NativeEconomyRuntime::Q16_ONE));
    return static_cast<int32_t>(std::clamp(
        scaled, 0.0, static_cast<double>(std::numeric_limits<int32_t>::max())));
}
} // namespace

bool NativeEconomyRuntime::advance_worker_resource_reserves(
        const RuntimeEconomyDayInput &input, std::string &error) {
    constexpr int32_t WILDERNESS_STRIDE = 60;
    constexpr int32_t LIVE_CATCHUP_MAX_DAYS = 5;
    const int32_t count = _cell_count.get();
    const size_t resource_count = _resource_ids.size();
    const size_t lanes = static_cast<size_t>(count) * resource_count;
    if (count <= 0 || resource_count == 0) return true;
    const int32_t day = static_cast<int32_t>(std::clamp<int64_t>(
        input.day, 0, std::numeric_limits<int32_t>::max()));
    if (!_worker_resource_seeded) {
        const bool restored = _resource_stock_restored_pending_capture &&
            resource_stock_lanes().size() == lanes;
        _worker_resource_reserve.assign(lanes, 0.0f);
        _worker_resource_extra.assign(lanes, 0.0f);
        for (size_t r = 0; r < resource_count; ++r) {
            const auto &src = input.reserves[r];
            const auto &change = input.changes[r];
            for (int32_t cell = 0; cell < count; ++cell) {
                const size_t lane = r * static_cast<size_t>(count) + cell;
                if (restored) {
                    _worker_resource_reserve[lane] = static_cast<float>(
                        static_cast<double>(resource_stock_lanes()[lane]) /
                        static_cast<double>(GOODS_SCALE));
                } else {
                    if (!src.empty()) _worker_resource_reserve[lane] = src[cell];
                    if (!change.empty()) _worker_resource_extra[lane] = change[cell];
                }
            }
        }
        if (resource_stock_lanes().size() != lanes)
            resource_stock_lanes().assign(lanes, 0);
        _worker_resource_extra_dirty.assign(resource_count, 1);
        _worker_resource_last_day.assign(static_cast<size_t>(count), std::max(day - 1, 0));
        _worker_resource_was_live.assign(static_cast<size_t>(count), 0);
        _worker_resource_cell_live.assign(static_cast<size_t>(count), 0);
        _worker_resource_mirror_mark.assign(static_cast<size_t>(count), 0);
        _worker_resource_mirror_cells.clear();
        _worker_resource_regen_factors.assign(static_cast<size_t>(count), 1.0f);
        _worker_resource_seeded = true;
        for (size_t lane = 0; lane < lanes; ++lane) write_worker_resource_stock(lane);
        for (int32_t cell = 0; cell < count; ++cell) mark_worker_resource_mirror_cell(cell);
    }
    if (_worker_resource_reserve.size() != lanes || _worker_resource_extra.size() != lanes ||
        _worker_resource_last_day.size() != static_cast<size_t>(count)) {
        error = "economy_worker_resource_shape_invalid";
        return false;
    }

    std::vector<int32_t> cells;
    std::vector<int32_t> cell_dt;
    cells.reserve(_economy_live_cells.size() + static_cast<size_t>(count / WILDERNESS_STRIDE + 1));
    auto dt_for = [&](int32_t cell, bool live) {
        int32_t elapsed = std::clamp(day - _worker_resource_last_day[static_cast<size_t>(cell)],
                                     1, WILDERNESS_STRIDE);
        if (live && _worker_resource_was_live[static_cast<size_t>(cell)] != 0)
            elapsed = std::clamp(elapsed, 1, LIVE_CATCHUP_MAX_DAYS);
        return elapsed;
    };
    for (const int32_t cell : _economy_live_cells) {
        if (cell < 0 || cell >= count) continue;
        _worker_resource_cell_live[static_cast<size_t>(cell)] = 1;
        if (_worker_resource_last_day[static_cast<size_t>(cell)] >= day) continue;
        cells.push_back(cell);
        cell_dt.push_back(dt_for(cell, true));
    }
    for (int32_t cell = day % WILDERNESS_STRIDE; cell < count; cell += WILDERNESS_STRIDE) {
        if (_worker_resource_cell_live[static_cast<size_t>(cell)] != 0 ||
            _worker_resource_last_day[static_cast<size_t>(cell)] >= day) continue;
        cells.push_back(cell);
        cell_dt.push_back(dt_for(cell, false));
    }

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
        for (const int32_t cell : cells) {
            _worker_resource_last_day[static_cast<size_t>(cell)] = day;
            _worker_resource_was_live[static_cast<size_t>(cell)] =
                _worker_resource_cell_live[static_cast<size_t>(cell)];
            for (size_t r = 0; r < resource_count; ++r)
                write_worker_resource_stock(r * static_cast<size_t>(count) + cell);
            mark_worker_resource_mirror_cell(cell);
        }
    }
    for (const int32_t cell : _economy_live_cells) {
        if (cell >= 0 && cell < count) _worker_resource_cell_live[static_cast<size_t>(cell)] = 0;
    }
    return true;
}

bool NativeEconomyRuntime::refresh_city_modifier_factors() {
    const size_t cells = static_cast<size_t>(std::max(0, _cell_count.get()));
    const size_t need_count = _need_ids.size();
    const size_t good_count = _good_ids.size();
    const bool shape_valid =
        _epoch_cell_birth_factor_q16.size() == cells &&
        _epoch_cell_need_consumption_factor_q16.size() == cells * need_count &&
        _epoch_cell_good_consumption_factor_q16.size() == cells * good_count;
    if (_modifier_runtime == nullptr) {
        if (_epoch_city_factor_valid && shape_valid) return true;
        _epoch_cell_birth_factor_q16.assign(cells, Q16_ONE);
        _epoch_cell_need_consumption_factor_q16.assign(cells * need_count, Q16_ONE);
        _epoch_cell_good_consumption_factor_q16.assign(cells * good_count, Q16_ONE);
        _city_factor_shared_birth_q16 = Q16_ONE;
        _city_factor_shared_needs_q16.assign(need_count, Q16_ONE);
        _city_factor_shared_goods_q16.assign(good_count, Q16_ONE);
        _city_factor_dirty_cells.clear();
        _epoch_city_factor_valid = true;
        return true;
    }

    _city_factor_stat_ids_scratch.clear();
    _city_factor_stat_ids_scratch.reserve(2 + need_count + good_count);
    _city_factor_stat_ids_scratch.push_back(_city_birth_stat_id);
    _city_factor_stat_ids_scratch.push_back(_city_consumption_stat_id);
    _city_factor_stat_ids_scratch.insert(
        _city_factor_stat_ids_scratch.end(),
        _city_need_consumption_stat_ids.begin(),
        _city_need_consumption_stat_ids.end());
    _city_factor_stat_ids_scratch.insert(
        _city_factor_stat_ids_scratch.end(),
        _city_good_consumption_stat_ids.begin(),
        _city_good_consumption_stat_ids.end());
    const uint64_t version = modifier_api::stat_bucket_version(*_modifier_runtime,
        ModifierApi::ECONOMY, _city_factor_stat_ids_scratch.data(),
        _city_factor_stat_ids_scratch.size());
    // A shard in flight must keep resuming even when the version has not moved:
    // otherwise the second entry short-circuits on `_epoch_city_factor_valid`,
    // which is exactly the state a partial paint leaves behind, and the work
    // set would stall forever with only the first shards applied.
    if (_city_factor_shard_cursor < 0 && _epoch_city_factor_valid &&
        shape_valid && _epoch_city_factor_stat_version == version) {
        return true;
    }
    // A cell id enters effective_value() as the GROUP key, so the GLOBAL and
    // ENTITY(0) contributions are shared by every cell. Resolve that shared row
    // once with an empty group handle, then re-probe only the cells that own a
    // group bucket.
    const auto shared_factor = [&](int32_t stat_id) {
        return modifier_factor_q16(modifier_api::effective_value(*_modifier_runtime,
            ModifierApi::ECONOMY, stat_id, 0,
            std::numeric_limits<uint64_t>::max(), 1.0));
    };
    const auto need_factor = [](int32_t general, int32_t selected) {
        int64_t sat = 0;
        return static_cast<int32_t>(std::clamp<int64_t>(mul_div_sat(
            general, selected, Q16_ONE, sat), 0, 4 * Q16_ONE));
    };
    const int32_t shared_birth = shared_factor(_city_birth_stat_id);
    const int32_t shared_general = shared_factor(_city_consumption_stat_id);
    std::vector<int32_t> shared_needs(need_count, Q16_ONE);
    for (size_t need = 0; need < need_count; ++need)
        shared_needs[need] = need_factor(
            shared_general, shared_factor(_city_need_consumption_stat_ids[need]));
    std::vector<int32_t> shared_goods(good_count, Q16_ONE);
    for (size_t good = 0; good < good_count; ++good)
        shared_goods[good] = shared_factor(_city_good_consumption_stat_ids[good]);

    const bool shared_changed = !_epoch_city_factor_valid || !shape_valid ||
        shared_birth != _city_factor_shared_birth_q16 ||
        shared_needs != _city_factor_shared_needs_q16 ||
        shared_goods != _city_factor_shared_goods_q16;
    const auto paint_shared = [&](size_t cell) {
        _epoch_cell_birth_factor_q16[cell] = shared_birth;
        std::copy(shared_needs.begin(), shared_needs.end(),
                  _epoch_cell_need_consumption_factor_q16.begin() +
                      static_cast<ptrdiff_t>(cell * need_count));
        std::copy(shared_goods.begin(), shared_goods.end(),
                  _epoch_cell_good_consumption_factor_q16.begin() +
                      static_cast<ptrdiff_t>(cell * good_count));
    };
    if (shared_changed) {
        _epoch_cell_birth_factor_q16.assign(cells, shared_birth);
        _epoch_cell_need_consumption_factor_q16.resize(cells * need_count);
        _epoch_cell_good_consumption_factor_q16.resize(cells * good_count);
        for (size_t cell = 0; cell < cells; ++cell) paint_shared(cell);
    } else {
        // Only the previously overridden cells can still hold a stale row.
        for (const int32_t cell : _city_factor_dirty_cells)
            if (cell >= 0 && static_cast<size_t>(cell) < cells)
                paint_shared(static_cast<size_t>(cell));
    }
    _city_factor_shared_birth_q16 = shared_birth;
    _city_factor_shared_needs_q16 = std::move(shared_needs);
    _city_factor_shared_goods_q16 = std::move(shared_goods);

    // ── Sharded work set (plan §14.3) ──────────────────────────────────────
    //
    // Everything above this point is O(map) and cheap relative to the per-cell
    // loop below, so it runs once. The per-cell loop is the part that must be
    // able to stop: M1-6 measured the whole reader at 0.465 ms (2400 cells) and
    // 1.264 ms (6400 cells), and the derived layer adds work in the SAME
    // indivisible window because `capture_country_epoch` has no shard point.
    //
    // Resume rules:
    //   cursor < 0                     -> collect, then start the loop at 0
    //   cursor >= 0, same version      -> resume at cursor
    //   cursor >= 0, version changed   -> discard the stale work set and restart
    //
    // A stale resume must NOT finish the old list: the caller started a new
    // version, so the earlier half-computed factors are about to be overwritten
    // anyway, and finishing it would bill time for work nobody reads.
    if (_city_factor_shard_cursor < 0 ||
            _city_factor_shard_version != version) {
        modifier_api::collect_scope_ids(*_modifier_runtime,
            ModifierApi::ECONOMY, ModifierApi::GROUP,
            _city_factor_stat_ids_scratch.data(),
            _city_factor_stat_ids_scratch.size(),
            _city_factor_group_cells_scratch);
        _city_factor_dirty_cells.clear();
        _city_factor_dirty_cells.reserve(_city_factor_group_cells_scratch.size());
        _city_factor_shard_cursor = 0;
        _city_factor_shard_version = version;
        _city_factor_work_cells =
            static_cast<int64_t>(_city_factor_group_cells_scratch.size());
        _city_factor_collected_cells =
            static_cast<int64_t>(_city_factor_group_cells_scratch.size());
    }

    const auto cell_factor = [&](int32_t stat_id, uint64_t scope_id) {
        return modifier_factor_q16(modifier_api::effective_value(*_modifier_runtime,
            ModifierApi::ECONOMY, stat_id, 0, scope_id, 1.0));
    };
    // Reset per pass so the counter answers "did THIS pass do the work", which
    // `_city_factor_work_cells` cannot: that field only moves when collect runs,
    // so a version-gate short-circuit leaves it reporting the previous pass.
    _city_factor_cells_processed = 0;
    // Cumulative epoch timing (plan §14.3): a full build spans many calls, and
    // `_epoch_begin_city_factor_ms` only measures one of them. Reset here when a
    // NEW build starts (collect branch ran, or a pass begins with no build open),
    // accumulate per slice below.
    if (!_city_factor_epoch_in_progress) {
        _city_factor_epoch_ms = 0.0;
        _city_factor_epoch_slices = 0;
        _city_factor_epoch_cells = 0;
        _city_factor_epoch_in_progress = true;
    }
    const Clock::time_point city_factor_pass_started = Clock::now();
    const int32_t shard_start = _city_factor_shard_cursor;
    int32_t &cursor = _city_factor_shard_cursor;
    const int32_t total = static_cast<int32_t>(_city_factor_group_cells_scratch.size());
    while (cursor < total) {
        const uint64_t scope_id =
            _city_factor_group_cells_scratch[static_cast<size_t>(cursor)];
        ++cursor;
        if (scope_id < cells) {
            ++_city_factor_cells_processed;
            _epoch_cell_birth_factor_q16[scope_id] =
                cell_factor(_city_birth_stat_id, scope_id);
            const int32_t general =
                cell_factor(_city_consumption_stat_id, scope_id);
            for (size_t need = 0; need < need_count; ++need) {
                _epoch_cell_need_consumption_factor_q16[
                    scope_id * need_count + need] = need_factor(general,
                        cell_factor(_city_need_consumption_stat_ids[need], scope_id));
            }
            for (size_t good = 0; good < good_count; ++good) {
                _epoch_cell_good_consumption_factor_q16[
                    scope_id * good_count + good] =
                    cell_factor(_city_good_consumption_stat_ids[good], scope_id);
            }
            _city_factor_dirty_cells.push_back(static_cast<int32_t>(scope_id));
        }
        // Yield check AFTER doing one cell, so a shard of size 0 can never spin.
        // The per-slice budget is a *slice* budget, not a per-cell one: spending
        // it on the cell we already started is always correct, and stopping
        // before doing any work would livelock a caller that re-enters with the
        // same deadline.
        // Cell-count shard rather than a wall-clock check: a deterministic bound
        // is testable, and §14.4 warns that wall-clock slicing moves work into
        // latency without proving anything. M1-6 measured ~6.0 us per covered
        // cell at B7 scale, so 64 cells ~= 0.38 ms -- comfortably inside the
        // 1 ms slice gate with room for the surrounding epoch-open work.
        if (cursor < total &&
                (cursor - shard_start) >= CITY_FACTOR_SHARD_CELLS) {
            // Accumulate before yielding: the slice cost belongs to the epoch
            // even though this call did not finish the build.
            _city_factor_epoch_ms += elapsed_ms(city_factor_pass_started);
            _city_factor_epoch_slices += 1;
            _city_factor_epoch_cells += _city_factor_cells_processed;
            return false;
        }
    }
    _city_factor_epoch_ms += elapsed_ms(city_factor_pass_started);
    _city_factor_epoch_slices += 1;
    _city_factor_epoch_cells += _city_factor_cells_processed;
    _city_factor_epoch_in_progress = false;  // build complete
    _city_factor_shard_cursor = -1;
    _epoch_city_factor_stat_version = version;
    _epoch_city_factor_valid = true;
    return true;
}

bool NativeEconomyRuntime::refresh_city_output_modifier_factors() {
    const size_t cells = static_cast<size_t>(std::max(0, _cell_count.get()));
    const size_t good_count = _good_ids.size();
    const bool shape_valid =
        _city_output_shared_goods_q16.size() == good_count &&
        _city_output_cell_offsets.size() == cells + 1 &&
        _city_output_good_indices.size() == _city_output_factors_q16.size();
    if (_modifier_runtime == nullptr) {
        if (_epoch_city_output_factor_valid && shape_valid) return true;
        _city_output_shared_goods_q16.assign(good_count, Q16_ONE);
        _city_output_cell_offsets.assign(cells + 1, 0);
        _city_output_good_indices.clear();
        _city_output_factors_q16.clear();
        _city_output_scope_cells_scratch.clear();
        _city_output_scope_stat_ids_scratch.clear();
        _epoch_city_output_factor_stat_version = 0;
        _epoch_city_output_factor_valid = true;
        _city_output_shard_cursor = -1;
        return true;
    }

    const uint64_t version = modifier_api::stat_bucket_version(*_modifier_runtime,
        ModifierApi::ECONOMY, _city_good_output_stat_ids.data(),
        _city_good_output_stat_ids.size());
    // Same rule as the city reader: a shard in flight must keep resuming, so the
    // version gate only short-circuits when no shard is pending.
    if (_city_output_shard_cursor < 0 && _epoch_city_output_factor_valid &&
        shape_valid && _epoch_city_output_factor_stat_version == version) {
        return true;
    }

    _city_output_shared_goods_q16.resize(good_count);
    for (size_t good = 0; good < good_count; ++good) {
        _city_output_shared_goods_q16[good] = modifier_factor_q16(
            modifier_api::effective_value(*_modifier_runtime,
                ModifierApi::ECONOMY,
                _city_good_output_stat_ids[good], 0,
                std::numeric_limits<uint64_t>::max(), 1.0));
    }

    struct OutputOverride {
        int32_t cell = -1;
        int32_t good = -1;
        int32_t factor_q16 = Q16_ONE;
        bool operator<(const OutputOverride &other) const {
            return cell != other.cell ? cell < other.cell : good < other.good;
        }
    };

    // ── Sharded per-cell query loop (plan §14.3) ───────────────────────────
    //
    // Only this loop is sharded. The sort + carry merge + CSR rebuild below
    // cannot stop mid-way, so the partial `overrides` list has to survive across
    // slices in `_city_output_shard_partial`. Keeping the two readers on
    // separate cursors is what stops the output factors from being updated only
    // on the LAST city shard.
    if (_city_output_shard_cursor < 0 ||
            _city_output_shard_version != version) {
        modifier_api::collect_scope_stat_entries(*_modifier_runtime,
            ModifierApi::ECONOMY, ModifierApi::GROUP,
            _city_good_output_stat_ids.data(), _city_good_output_stat_ids.size(),
            _city_output_scope_cells_scratch,
            _city_output_scope_stat_ids_scratch);
        _city_output_shard_partial.clear();
        _city_output_shard_partial.reserve(_city_output_scope_cells_scratch.size());
        _city_output_shard_cursor = 0;
        _city_output_shard_version = version;
    }

    std::unordered_map<int32_t, int32_t> good_by_stat;
    good_by_stat.reserve(good_count);
    for (size_t good = 0; good < good_count; ++good)
        good_by_stat.emplace(_city_good_output_stat_ids[good],
                             static_cast<int32_t>(good));

    {
        const int32_t shard_start = _city_output_shard_cursor;
        int32_t &cursor = _city_output_shard_cursor;
        const int32_t total = static_cast<int32_t>(
            std::min(_city_output_scope_cells_scratch.size(),
                     _city_output_scope_stat_ids_scratch.size()));
        while (cursor < total) {
            const size_t entry = static_cast<size_t>(cursor);
            ++cursor;
            const uint64_t scope = _city_output_scope_cells_scratch[entry];
            const auto found = good_by_stat.find(
                _city_output_scope_stat_ids_scratch[entry]);
            if (scope >= cells || found == good_by_stat.end()) continue;
            const int32_t good = found->second;
            const int32_t factor_q16 = modifier_factor_q16(
                modifier_api::effective_value(*_modifier_runtime,
                    ModifierApi::ECONOMY,
                    _city_good_output_stat_ids[static_cast<size_t>(good)], 0,
                    scope, 1.0));
            if (factor_q16 == _city_output_shared_goods_q16[
                    static_cast<size_t>(good)])
                continue;
            _city_output_shard_partial.push_back(
                {static_cast<int32_t>(scope), good, factor_q16});
            // Yield check after doing one entry, for the same reason the city
            // reader does: stopping before any work livelocks a re-entering
            // caller.
            if (cursor < total &&
                    (cursor - shard_start) >= CITY_FACTOR_SHARD_CELLS) {
                return false;
            }
        }
    }
    _city_output_shard_cursor = -1;

    std::vector<OutputOverride> overrides;
    overrides.reserve(_city_output_shard_partial.size());
    for (const CityOutputOverrideRow &row : _city_output_shard_partial) {
        overrides.push_back({row.cell, row.good, row.factor_q16});
    }
    _city_output_shard_partial.clear();
    std::sort(overrides.begin(), overrides.end());
    _city_output_cell_offsets.assign(cells + 1, 0);
    for (const OutputOverride &entry : overrides)
        ++_city_output_cell_offsets[static_cast<size_t>(entry.cell) + 1];
    for (size_t cell = 1; cell < _city_output_cell_offsets.size(); ++cell)
        _city_output_cell_offsets[cell] += _city_output_cell_offsets[cell - 1];
    _city_output_good_indices.resize(overrides.size());
    _city_output_factors_q16.resize(overrides.size());
    for (size_t index = 0; index < overrides.size(); ++index) {
        _city_output_good_indices[index] = overrides[index].good;
        _city_output_factors_q16[index] = overrides[index].factor_q16;
    }
    _epoch_city_output_factor_stat_version = version;
    _epoch_city_output_factor_valid = true;
    return true;
}

void NativeEconomyRuntime::refresh_building_modifier_factors() {
    const auto factor_refresh_started = Clock::now();
    struct RefreshTimer {
        NativeEconomyRuntime *self;
        const std::chrono::steady_clock::time_point &start;
        ~RefreshTimer() {
            self->_building_factor_refresh_ms += elapsed_ms(start);
        }
    } refresh_timer{this, factor_refresh_started};
    // Groups are only ever appended in place, so growing the cache must keep
    // the existing entries; a full assign() would force every group to
    // recompute its factor whenever a single building finishes construction.
    // The entry carries the full group identity, so a stale slot can never be
    // mistaken for a different group.
    if (_building_factor_cache.size() != building_count())
        _building_factor_cache.resize(building_count(),
                                      BuildingFactorCacheEntry{});
    // Gated on the building output stats alone: an unrelated economy modifier
    // must not invalidate every building group's cached factor.
    const uint64_t mod_version = _modifier_runtime != nullptr
        ? modifier_api::building_output_stat_version(*_modifier_runtime)
        : 0;
    // exact_building_mod_version 只由 type_id 决定，原来每个 group 各查一次 bucket
    // 版本。组数随存档单调增长，类型数不变，故按类型算一遍复用。-1 表示尚未解析。
    thread_local std::vector<uint64_t> exact_building_mod_version_by_type;
    exact_building_mod_version_by_type.assign(
        _city_building_output_stat_ids.size(),
        std::numeric_limits<uint64_t>::max());
    for (size_t group_index = 0; group_index < building_count();
         ++group_index) {
        const auto group = building_view(static_cast<size_t>(group_index));
        BuildingFactorCacheEntry &cache = _building_factor_cache[group_index];
        const uint8_t count_positive = group.count > 0 ? uint8_t{1} : uint8_t{0};
        const int32_t exact_building_stat_id = group.type_id >= 0 &&
                group.type_id < static_cast<int32_t>(
                    _city_building_output_stat_ids.size())
            ? _city_building_output_stat_ids[static_cast<size_t>(group.type_id)]
            : -1;
        uint64_t exact_building_mod_version = 0;
        if (_modifier_runtime != nullptr && exact_building_stat_id >= 0) {
            uint64_t &memo = exact_building_mod_version_by_type[
                static_cast<size_t>(group.type_id)];
            if (memo == std::numeric_limits<uint64_t>::max())
                memo = modifier_api::stat_bucket_version(*_modifier_runtime,
                    ModifierApi::ECONOMY, &exact_building_stat_id, 1);
            exact_building_mod_version = memo;
        }
        // 空组无产出，其唯一非平凡输入（family-owned 混合）也已早退成 Q16_ONE。
        // 身份与两个 modifier 版本都没变时，重算结果必然与缓存逐位一致，
        // 于是省掉十几次 epoch 因子查表和一次家族持股遍历。
        if (count_positive == 0 && cache.count_positive == 0 &&
            cache.cell == group.cell && cache.type_id == group.type_id &&
            cache.owner_signature_id == group.owner_signature_id &&
            cache.mod_version == mod_version &&
            cache.exact_building_mod_version == exact_building_mod_version) {
            ++_building_factor_cache_hits;
            ++_building_factor_cache_hits_epoch;
            continue;
        }
        const bool cell_country_valid = _modifier_runtime != nullptr &&
            group.cell >= 0 &&
            group.cell < static_cast<int32_t>(_epoch_cell_country.size());
        const int32_t country_slot = cell_country_valid
            ? _epoch_cell_country[static_cast<size_t>(group.cell)] : -1;
        const uint64_t country_handle = country_slot >= 0 &&
                country_slot < static_cast<int32_t>(_epoch_country_handles.size())
            ? _epoch_country_handles[static_cast<size_t>(country_slot)] : 0;
        const int64_t country_factor_q16 = country_slot >= 0 &&
                country_slot < static_cast<int32_t>(
                    _epoch_country_output_factor_q16.size())
            ? _epoch_country_output_factor_q16[
                static_cast<size_t>(country_slot)] : Q16_ONE;
        const int32_t sector = group.type_id >= 0 &&
                group.type_id < static_cast<int32_t>(_building_types.size())
            ? _building_types[static_cast<size_t>(group.type_id)].economic_sector
            : 2;
        const int64_t sector_factor_q16 = country_slot >= 0 &&
                static_cast<size_t>(country_slot) * 5U + sector <
                    _epoch_country_sector_output_factor_q16.size()
            ? _epoch_country_sector_output_factor_q16[
                static_cast<size_t>(country_slot) * 5U + sector] : Q16_ONE;
        int32_t family = -1;
        if (group.type_id >= 0 &&
            group.type_id < static_cast<int32_t>(
                _building_upgrade_family_indices.size())) {
            family = _building_upgrade_family_indices[
                static_cast<size_t>(group.type_id)];
        }
        const bool research_institution = family >= 0 &&
            family < static_cast<int32_t>(_building_upgrade_family_ids.size()) &&
            _building_upgrade_family_ids[static_cast<size_t>(family)] ==
                "research_institution";
        const int64_t research_factor_q16 = research_institution &&
                country_slot >= 0 &&
                country_slot < static_cast<int32_t>(
                    _epoch_country_research_output_factor_q16.size())
            ? _epoch_country_research_output_factor_q16[
                static_cast<size_t>(country_slot)] : Q16_ONE;
        const size_t family_factor_index = static_cast<size_t>(
            std::max(0, country_slot)) * _building_upgrade_family_ids.size() +
            static_cast<size_t>(std::max(0, family));
        const int64_t family_factor_q16 = country_slot >= 0 && family >= 0 &&
                family_factor_index < _epoch_country_family_output_factor_q16.size()
            ? _epoch_country_family_output_factor_q16[family_factor_index]
            : Q16_ONE;
        const size_t building_factor_index = static_cast<size_t>(
            std::max(0, country_slot)) * _building_type_ids.size() +
            static_cast<size_t>(std::max(0, group.type_id));
        const int64_t building_type_factor_q16 = country_slot >= 0 &&
                group.type_id >= 0 &&
                building_factor_index <
                    _epoch_country_building_output_factor_q16.size()
            ? _epoch_country_building_output_factor_q16[building_factor_index]
            : Q16_ONE;
        const int32_t terrain = group.cell >= 0 && group.cell < static_cast<int32_t>(
                _building_terrain.size()) ? _building_terrain[group.cell] : -1;
        const int32_t landform = group.cell >= 0 && group.cell < static_cast<int32_t>(
                _building_landform.size()) ? _building_landform[group.cell] : -1;
        const size_t terrain_index = (static_cast<size_t>(std::max(0, country_slot)) *
                _modifier_terrain_ids.size() + static_cast<size_t>(std::max(0, terrain))) *
                5U + static_cast<size_t>(sector);
        const size_t landform_index = (static_cast<size_t>(std::max(0, country_slot)) *
                _modifier_landform_ids.size() + static_cast<size_t>(std::max(0, landform))) *
                5U + static_cast<size_t>(sector);
        const int64_t terrain_sector_factor_q16 = country_slot >= 0 && terrain >= 0 &&
                terrain_index < _epoch_country_terrain_sector_output_factor_q16.size()
            ? _epoch_country_terrain_sector_output_factor_q16[terrain_index] : Q16_ONE;
        const int64_t landform_sector_factor_q16 = country_slot >= 0 && landform >= 0 &&
                landform_index < _epoch_country_landform_sector_output_factor_q16.size()
            ? _epoch_country_landform_sector_output_factor_q16[landform_index] : Q16_ONE;
        const int32_t family_owned_factor_q16 =
            family_group_owned_output_factor_q16(static_cast<int32_t>(group_index));
        const size_t cell_sector_index = static_cast<size_t>(
            std::max(0, group.cell)) * 5U + static_cast<size_t>(sector);
        const int32_t cell_sector_factor_q16 =
            group.cell >= 0 && cell_sector_index <
                _epoch_cell_sector_output_factor_q16.size()
            ? _epoch_cell_sector_output_factor_q16[cell_sector_index] : Q16_ONE;
        if (cache.country_factor_q16 == country_factor_q16 &&
            cache.sector_factor_q16 == sector_factor_q16 &&
            cache.research_factor_q16 == research_factor_q16 &&
            cache.family_factor_q16 == family_factor_q16 &&
            cache.building_type_factor_q16 == building_type_factor_q16 &&
            cache.terrain_sector_factor_q16 == terrain_sector_factor_q16 &&
            cache.landform_sector_factor_q16 == landform_sector_factor_q16 &&
            cache.family_owned_factor_q16 == family_owned_factor_q16 &&
            cache.cell_sector_factor_q16 == cell_sector_factor_q16 &&
            cache.country_handle == country_handle &&
            cache.mod_version == mod_version &&
            cache.exact_building_mod_version == exact_building_mod_version &&
            cache.output_key == BuildingOutputFactorKey{
                country_slot, group.type_id, terrain, landform, sector} &&
            cache.cell == group.cell &&
            cache.type_id == group.type_id &&
            cache.owner_signature_id == group.owner_signature_id &&
            cache.count_positive == count_positive) {
            ++_building_factor_cache_hits;
            ++_building_factor_cache_hits_epoch;
            continue;
        }
        ++_building_factor_cache_misses;
        ++_building_factor_cache_misses_epoch;
        if (cache.mod_version != mod_version ||
            cache.exact_building_mod_version != exact_building_mod_version)
            ++_building_factor_miss_modver_epoch;
        if (cache.country_factor_q16 != country_factor_q16 ||
            cache.country_handle != country_handle)
            ++_building_factor_miss_country_epoch;
        if (cache.sector_factor_q16 != sector_factor_q16)
            ++_building_factor_miss_sector_epoch;
        if (cache.research_factor_q16 != research_factor_q16)
            ++_building_factor_miss_research_epoch;
        if (cache.cell != group.cell || cache.type_id != group.type_id ||
            cache.owner_signature_id != group.owner_signature_id)
            ++_building_factor_miss_identity_epoch;
        // 命中缓存不申请整行写租约；只有实际重算才进入既有跟踪写路径。
        auto writable_group = building_at(group_index);
        writable_group.output_factor_q16 = Q16_ONE;
        if (!cell_country_valid) {
            writable_group.modifier_handle = 0;
            writable_group.output_factor_q16 = modifier_factor_q16(
                static_cast<double>(family_owned_factor_q16) / Q16_ONE *
                static_cast<double>(cell_sector_factor_q16) / Q16_ONE);
        } else {
            writable_group.modifier_handle = modifier_api::ensure_building_identity(*_modifier_runtime,
                group.cell, group.type_id, group.owner_signature_id);
            const double building_factor =
                modifier_api::economy_building_output_factor(*_modifier_runtime,
                    writable_group.modifier_handle, static_cast<uint64_t>(group.cell), sector);
            const double exact_building_factor = exact_building_stat_id >= 0
                ? modifier_api::effective_value(*_modifier_runtime,
                    ModifierApi::ECONOMY, exact_building_stat_id, 0,
                    static_cast<uint64_t>(group.cell), 1.0)
                : 1.0;
            writable_group.output_factor_q16 = modifier_factor_q16(
                (static_cast<double>(country_factor_q16) / Q16_ONE) *
                (static_cast<double>(sector_factor_q16) / Q16_ONE) *
                (static_cast<double>(research_factor_q16) / Q16_ONE) *
                (static_cast<double>(family_factor_q16) / Q16_ONE) *
                (static_cast<double>(building_type_factor_q16) / Q16_ONE) *
                (static_cast<double>(terrain_sector_factor_q16) / Q16_ONE) *
                (static_cast<double>(landform_sector_factor_q16) / Q16_ONE) *
                (static_cast<double>(family_owned_factor_q16) / Q16_ONE) *
                (static_cast<double>(cell_sector_factor_q16) / Q16_ONE) *
                building_factor * exact_building_factor);
        }
        cache.country_factor_q16 = country_factor_q16;
        cache.sector_factor_q16 = sector_factor_q16;
        cache.research_factor_q16 = research_factor_q16;
        cache.family_factor_q16 = family_factor_q16;
        cache.building_type_factor_q16 = building_type_factor_q16;
        cache.terrain_sector_factor_q16 = terrain_sector_factor_q16;
        cache.landform_sector_factor_q16 = landform_sector_factor_q16;
        cache.family_owned_factor_q16 = family_owned_factor_q16;
        cache.cell_sector_factor_q16 = cell_sector_factor_q16;
        cache.country_handle = country_handle;
        cache.mod_version = mod_version;
        cache.exact_building_mod_version = exact_building_mod_version;
        cache.output_key = BuildingOutputFactorKey{
            country_slot, group.type_id, terrain, landform, sector};
        cache.cell = group.cell;
        cache.type_id = group.type_id;
        cache.owner_signature_id = group.owner_signature_id;
        cache.count_positive = count_positive;
        _building_handle_index_clean = false;
    }
}

int64_t NativeEconomyRuntime::effective_building_output_quantity_for_target(
        int32_t cell, int32_t type_id, int32_t owner_signature_id,
        int32_t good_id, int64_t base_quantity, int64_t utilization_q16,
        int64_t building_days, int64_t &sat) {
    BuildingGroup target;
    target.cell = cell;
    target.type_id = type_id;
    target.owner_signature_id = owner_signature_id;
    target.output_factor_q16 = Q16_ONE;
    if (_modifier_runtime != nullptr) {
        const int32_t country_slot = cell >= 0 &&
                cell < static_cast<int32_t>(_epoch_cell_country.size())
            ? _epoch_cell_country[static_cast<size_t>(cell)] : -1;
        const uint64_t country_handle = country_slot >= 0 &&
                country_slot < static_cast<int32_t>(_epoch_country_handles.size())
            ? _epoch_country_handles[static_cast<size_t>(country_slot)] : 0;
        target.modifier_handle = owner_signature_id >= 0
            ? modifier_api::ensure_building_identity(*_modifier_runtime,
                cell, type_id, owner_signature_id)
            : 0;
        const double country_factor = country_slot >= 0 &&
                country_slot < static_cast<int32_t>(_epoch_country_output_factor_q16.size())
            ? static_cast<double>(_epoch_country_output_factor_q16[
                static_cast<size_t>(country_slot)]) / Q16_ONE
            : 1.0;
        const int32_t sector = type_id >= 0 &&
                type_id < static_cast<int32_t>(_building_types.size())
            ? _building_types[static_cast<size_t>(type_id)].economic_sector : 2;
        const double sector_factor = country_slot >= 0 &&
                static_cast<size_t>(country_slot) * 5U + sector <
                    _epoch_country_sector_output_factor_q16.size()
            ? static_cast<double>(_epoch_country_sector_output_factor_q16[
                static_cast<size_t>(country_slot) * 5U + sector]) / Q16_ONE
            : 1.0;
        int32_t family = -1;
        if (type_id >= 0 &&
            type_id < static_cast<int32_t>(_building_upgrade_family_indices.size())) {
            family = _building_upgrade_family_indices[
                static_cast<size_t>(type_id)];
        }
        const bool research_institution = family >= 0 &&
            family < static_cast<int32_t>(_building_upgrade_family_ids.size()) &&
            _building_upgrade_family_ids[static_cast<size_t>(family)] ==
                "research_institution";
        const double research_factor = research_institution && country_slot >= 0 &&
                country_slot < static_cast<int32_t>(
                    _epoch_country_research_output_factor_q16.size())
            ? static_cast<double>(_epoch_country_research_output_factor_q16[
                static_cast<size_t>(country_slot)]) / Q16_ONE
            : 1.0;
        const size_t family_factor_index = static_cast<size_t>(
            std::max(0, country_slot)) * _building_upgrade_family_ids.size() +
            static_cast<size_t>(std::max(0, family));
        const double family_factor = country_slot >= 0 && family >= 0 &&
                family_factor_index < _epoch_country_family_output_factor_q16.size()
            ? static_cast<double>(_epoch_country_family_output_factor_q16[
                family_factor_index]) / Q16_ONE
            : 1.0;
        const size_t building_factor_index = static_cast<size_t>(
            std::max(0, country_slot)) * _building_type_ids.size() +
            static_cast<size_t>(std::max(0, type_id));
        const double building_type_factor = country_slot >= 0 && type_id >= 0 &&
                building_factor_index <
                    _epoch_country_building_output_factor_q16.size()
            ? static_cast<double>(_epoch_country_building_output_factor_q16[
                building_factor_index]) / Q16_ONE
            : 1.0;
        const int32_t terrain = cell >= 0 && cell < static_cast<int32_t>(
                _building_terrain.size()) ? _building_terrain[cell] : -1;
        const int32_t landform = cell >= 0 && cell < static_cast<int32_t>(
                _building_landform.size()) ? _building_landform[cell] : -1;
        const size_t terrain_index = (static_cast<size_t>(std::max(0, country_slot)) *
                _modifier_terrain_ids.size() + static_cast<size_t>(std::max(0, terrain))) *
                5U + static_cast<size_t>(sector);
        const size_t landform_index = (static_cast<size_t>(std::max(0, country_slot)) *
                _modifier_landform_ids.size() + static_cast<size_t>(std::max(0, landform))) *
                5U + static_cast<size_t>(sector);
        const double terrain_factor = country_slot >= 0 && terrain >= 0 &&
                terrain_index < _epoch_country_terrain_sector_output_factor_q16.size()
            ? static_cast<double>(_epoch_country_terrain_sector_output_factor_q16[
                terrain_index]) / Q16_ONE : 1.0;
        const double landform_factor = country_slot >= 0 && landform >= 0 &&
                landform_index < _epoch_country_landform_sector_output_factor_q16.size()
            ? static_cast<double>(_epoch_country_landform_sector_output_factor_q16[
                landform_index]) / Q16_ONE : 1.0;
        const int32_t exact_building_stat_id = type_id >= 0 &&
                type_id < static_cast<int32_t>(
                    _city_building_output_stat_ids.size())
            ? _city_building_output_stat_ids[static_cast<size_t>(type_id)] : -1;
        const double exact_building_factor = exact_building_stat_id >= 0
            ? modifier_api::effective_value(*_modifier_runtime,
                ModifierApi::ECONOMY, exact_building_stat_id, 0,
                static_cast<uint64_t>(cell), 1.0)
            : 1.0;
        target.output_factor_q16 = modifier_factor_q16(
            country_factor * sector_factor * research_factor * family_factor *
            building_type_factor * terrain_factor * landform_factor *
            modifier_api::economy_building_output_factor(*_modifier_runtime,
                target.modifier_handle, static_cast<uint64_t>(cell), sector) *
            exact_building_factor);
    }
    return effective_building_output_quantity_at(target.cell,
        target.output_factor_q16, good_id, base_quantity, utilization_q16,
        building_days, sat);
}

} // namespace pk
