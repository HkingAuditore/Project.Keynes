#include "military_core.h"
#include "military_core_personnel_internal.h"
#include "pk_log.h"

#include <algorithm>
#include <atomic>
#include <cmath>
#include <string>
#include <utility>

namespace pk {

using namespace mil;

// ============================================================== cross-TU helpers

int32_t military_cell_garrison_slot(const MilitaryCore &core, int32_t cell) {
    int32_t owner = -1;
    for (size_t i = 0; i < core._lots.active.size(); ++i) {
        if (!core._lots.active[i] || core._lots.count[i] <= 0) continue;
        if (core._lots.location_kind[i] != (uint8_t)MILITARY_LOT_GARRISON) continue;
        if (core._lots.location[i] != cell) continue;
        if (owner < 0 || core._lots.country_slot[i] < owner) owner = core._lots.country_slot[i];
    }
    return owner;
}

namespace {

// Moves heads army -> army (same cell), preserving equipment quality.
int64_t transfer_army_to_army(MilitaryCore &core, int32_t from, int32_t to, int32_t unit,
                              int64_t count) {
    int64_t left = count;
    for (size_t i = 0; i < core._lots.active.size() && left > 0; ++i) {
        if (!core._lots.active[i] || core._lots.count[i] <= 0) continue;
        if (core._lots.location_kind[i] != (uint8_t)MILITARY_LOT_ARMY) continue;
        if (core._lots.location[i] != from) continue;
        if (unit >= 0 && core._lots.unit_type[i] != unit) continue;
        const int64_t take = std::min(left, core._lots.count[i]);
        if (take <= 0) continue;
        core._lots.count[i] -= take;
        const int32_t dest = core.lot_find_or_create((uint8_t)MILITARY_LOT_ARMY, to,
                                                     core._lots.country_slot[i], core._lots.unit_type[i],
                                                     core._lots.equip_quality_q8[i],
                                                     core._lots.kit_q16[i], core._lots.partial_equipment[i]);
        if (dest < 0) {
            core._lots.count[i] += take;
            break;
        }
        core._lots.count[(size_t)dest] += take;
        // A source lot that gave everything away must stop pointing at the army:
        // a zero-count row with a live location encodes an army reference that
        // PKMI validates and rejects (pkmi_lot_army_missing after merges).
        if (core._lots.count[i] <= 0) {
            core._lots.active[i] = 0;
            core._lots.free_list.push_back((int32_t)i);
        }
        left -= take;
    }
    return count - left;
}

// Sets an army template from (unit, count) pairs in `ints`.
void set_template(MilitaryCore &core, int32_t army, const std::vector<int32_t> &ints) {
    if (!army_alive(core._armies, army)) return;
    const size_t s = (size_t)army;
    // Compact the arena: append the new rows and mark the old span dead by
    // pointing the army at the fresh tail (save compacts further).
    const int32_t off = (int32_t)core._template_rows.size();
    int32_t rows = 0;
    for (size_t i = 0; i + 1 < ints.size(); i += 2) {
        if (ints[i] < 0 || ints[i] >= (int32_t)core._catalog.units.size()) continue;
        if (ints[i + 1] <= 0) continue;
        core._template_rows.push_back(ints[i]);
        core._template_rows.push_back(ints[i + 1]);
        rows += 2;
    }
    core._armies.template_offset[s] = rows > 0 ? off : 0;
    core._armies.template_len[s] = rows;
    if (core._template_rows.size() > 200000) {
        // Defensive compaction so a long session cannot grow without bound.
        core._template_rows.resize((size_t)off);
        core._armies.template_len[s] = 0;
    }
}

} // namespace

int32_t military_embark_army(MilitaryCore &core, int32_t owner, int32_t cell, int64_t count) {
    if (owner < 0 || cell < 0 || cell >= core._terrain.cell_count) return -1;
    if (count <= 0) return -1;
    const int32_t army = core.create_army(owner, cell);
    if (army < 0) return -1;
    int64_t left = count;
    for (size_t i = 0; i < core._lots.active.size() && left > 0; ++i) {
        if (!core._lots.active[i] || core._lots.count[i] <= 0) continue;
        if (core._lots.location_kind[i] != (uint8_t)MILITARY_LOT_GARRISON) continue;
        if (core._lots.location[i] != cell) continue;
        if (core._lots.country_slot[i] != owner) continue;
        const int64_t take = std::min(left, core._lots.count[i]);
        core._lots.count[i] -= take;
        const int32_t dest = core.lot_find_or_create((uint8_t)MILITARY_LOT_ARMY, army, owner,
                                                     core._lots.unit_type[i], core._lots.equip_quality_q8[i],
                                                     core._lots.kit_q16[i], core._lots.partial_equipment[i]);
        if (dest < 0) {
            core._lots.count[i] += take;
            break;
        }
        core._lots.count[(size_t)dest] += take;
        // A source lot that gave everything away must stop pointing at the army:
        // a zero-count row with a live location encodes an army reference that
        // PKMI validates and rejects (pkmi_lot_army_missing after merges).
        if (core._lots.count[i] <= 0) {
            core._lots.active[i] = 0;
            core._lots.free_list.push_back((int32_t)i);
        }
        left -= take;
    }
    core.refresh_army_cache(army);
    if (left == count) {   // nothing boarded: no empty formations
        core.destroy_army(army);
        return -1;
    }
    // Personnel lane (contract §2.1): the boarded heads leave the cell's soldier
    // cohort on the Economy side and live in this formation's lane. One intent
    // per formation, so the lane row is created once and named by army handle.
    core.emit_army_lane_intent(MILITARY_INTENT_ARMY_EMBARK, army, cell, count - left);
    return army;
}

bool military_disembark_army(MilitaryCore &core, int32_t army) {
    if (!army_alive(core._armies, army)) return false;
    const int32_t cell = core._armies.cell[(size_t)army];
    const int32_t owner = core._armies.owner_slot[(size_t)army];
    if (cell < 0) return false;
    // Heads the formation actually carries: its army lots, which mirror the
    // Economy lane row 1:1. Captured before the lots move to the garrison.
    int64_t lane_heads = 0;
    for (size_t i = 0; i < core._lots.active.size(); ++i) {
        if (!core._lots.active[i] || core._lots.count[i] <= 0) continue;
        if (core._lots.location_kind[i] != (uint8_t)MILITARY_LOT_ARMY) continue;
        if (core._lots.location[i] != army) continue;
        lane_heads += core._lots.count[i];
    }
    // Queued (not emitted directly) because the army must still be alive when
    // the intent carries its handle; destroy_army runs below.
    core.emit_army_lane_intent(MILITARY_INTENT_ARMY_DISEMBARK, army, cell, lane_heads);
    for (size_t i = 0; i < core._lots.active.size(); ++i) {
        if (!core._lots.active[i] || core._lots.count[i] <= 0) continue;
        if (core._lots.location_kind[i] != (uint8_t)MILITARY_LOT_ARMY) continue;
        if (core._lots.location[i] != army) continue;
        const int32_t dest = core.lot_find_or_create((uint8_t)MILITARY_LOT_GARRISON, cell, owner,
                                                     core._lots.unit_type[i], core._lots.equip_quality_q8[i],
                                                     core._lots.kit_q16[i], core._lots.partial_equipment[i]);
        if (dest < 0) break;
        core._lots.count[(size_t)dest] += core._lots.count[i];
        core._lots.count[i] = 0;
    }
    for (size_t i = 0; i < core._lots.active.size(); ++i) {
        if (core._lots.active[i] && core._lots.count[i] <= 0) {
            core._lots.active[i] = 0;
            core._lots.free_list.push_back((int32_t)i);
        }
    }
    core.destroy_army(army);
    return true;
}

// ============================================================== submit

bool MilitaryCore::submit(MilitaryCommand command, std::string &error) {
    if (_configured && command.effective_day >= _last_day && command.sequence == 0)
        command.sequence = _next_sequence++;
    if (!validate_command(command, error)) return false;
    _pending.push_back(std::move(command));
    return true;
}


// ============================================================== commands (apply)

void MilitaryCore::apply_due_commands(int64_t day) {
    if (_pending.empty()) return;
    // Stable sort by (effective_day, sequence): the contract's apply order.
    std::stable_sort(_pending.begin(), _pending.end(), [](const MilitaryCommand &a, const MilitaryCommand &b) {
        if (a.effective_day != b.effective_day) return a.effective_day < b.effective_day;
        return a.sequence < b.sequence;
    });
    // Commands are applied on their effective day or on the first day after it
    // (e.g. a request queued while the world was paused). Commands dated in the
    // future wait for their day.
    size_t applied = 0;
    while (applied < _pending.size() && _pending[applied].effective_day <= day) {
        // Country handles map to slots for the whole lifetime of the world, so
        // a handle accepted by submit() still resolves here.
        apply_command(_pending[applied], day);
        ++applied;
    }
    if (applied > 0) _pending.erase(_pending.begin(), _pending.begin() + static_cast<std::ptrdiff_t>(applied));
}

std::vector<MilitaryPlayerCommandRejection> MilitaryCore::take_player_command_rejections() {
    std::vector<MilitaryPlayerCommandRejection> result;
    result.swap(_player_command_rejections);
    return result;
}

void MilitaryCore::apply_command(const MilitaryCommand &cmd, int64_t day) {
    const int32_t country = country_slot_for_handle(cmd.country);
    const char *map_order = cmd.op == MCMD_ARMY_MOVE ? "military.army.move" :
        cmd.op == MCMD_ARMY_AREA_CONTROL ? "military.army.area_control" :
        cmd.op == MCMD_ARMY_EXPLORE ? "military.army.explore" : nullptr;
    const bool player_map_order = map_order != nullptr && cmd.value > 0;
    int32_t army_slot = -1;
    if (player_map_order) {
        const char *reason = nullptr;
        if (!resolve_army(cmd.army, army_slot)) reason = "command_unknown_army";
        else if (country < 0 || _armies.owner_slot[static_cast<size_t>(army_slot)] != country)
            reason = "command_not_owner";
        else if (cmd.op == MCMD_ARMY_EXPLORE) {
            if (_armies.engagement[static_cast<size_t>(army_slot)] >= 0)
                reason = "command_army_in_engagement";
            else if (country != _exploration_observer_slot)
                reason = "command_not_owner";
            else if (!can_create_exploration_task(army_slot))
                reason = "command_exploration_capacity_full";
        }
        if (reason != nullptr) {
            _player_command_rejections.push_back({map_order, cmd.value, reason});
            return;
        }
    }
    const bool player_order = cmd.value > 0 &&
        (cmd.op == MCMD_TRAIN || cmd.op == MCMD_ARMY_CREATE);
    if (player_order) {
        const char *reason = nullptr;
        if (country < 0) {
            reason = "command_unknown_country";
        } else if (cmd.op == MCMD_TRAIN) {
            const int32_t bit = _catalog.units[static_cast<size_t>(cmd.unit_to)].unlock_bit;
            if (!unlocked(_last_digest, country, bit)) reason = "technology_locked";
        } else {
            const int32_t controller = controller_of(cmd.cell);
            if (cmd.cell < 0 || static_cast<size_t>(cmd.cell) >= _last_digest.cell_owner_slot.size() ||
                _last_digest.cell_owner_slot[static_cast<size_t>(cmd.cell)] != country)
                reason = "not_own_territory";
            else if (controller >= 0 && controller != country)
                reason = "cell_occupied";
            else if (military_cell_garrison_slot(*this, cmd.cell) != country)
                reason = "command_no_local_garrison";
        }
        if (reason != nullptr) {
            const char *command = cmd.op == MCMD_TRAIN ? "military.train" : "military.army.create";
            _player_command_rejections.push_back({command, cmd.value, reason});
            return;
        }
    }
    if (country < 0) return;   // country vanished before the order took effect
    MilitaryCountryPolicy &policy = _policies[(size_t)country];
    switch (cmd.op) {
        case MCMD_GARRISON_TRANSFER_CELL: {
            const int32_t new_owner = country_slot_for_handle(cmd.other);
            if (cmd.cell < 0 || cmd.cell >= _terrain.cell_count || new_owner < 0)
                return;
            // Occupation is void once the cell changes sovereign, and every
            // garrison lot at the cell follows it (from < 0 = all lots).
            clear_controller(cmd.cell);
            transfer_garrison_owner(cmd.cell, -1, new_owner);
            if ((size_t)cmd.cell < _cell_owner_dirty.size())
                _cell_owner_dirty[(size_t)cmd.cell] = 1;
            return;
        }
        case MCMD_FORCE_SET_TARGET:
            policy.target_mode = (uint8_t)cmd.count;
            policy.target_value = cmd.value;
            if (cmd.count == 0) policy.effective_target = cmd.value;
            return;
        case MCMD_FORCE_SET_LEVY:
            policy.levy_enabled = cmd.count != 0 ? 1 : 0;
            return;
        case MCMD_FORCE_SET_AUTO_DISCHARGE:
            policy.auto_discharge = cmd.count != 0 ? 1 : 0;
            return;
        case MCMD_CONFIG_AUTO_RETRAIN:
            policy.auto_retrain = cmd.count != 0 ? 1 : 0;
            return;
        case MCMD_CONFIG_SET_QUALITY_POLICY:
            policy.quality_policy = (uint8_t)cmd.value;
            return;
        case MCMD_CONFIG_SET: {
            if (cmd.count == 1) {
                // Apply a partial edit to the policy at its effective day.
                auto updated = policy.config_share_bp;
                updated.resize(_catalog.units.size(), 0);
                for (size_t i = 0; i + 1 < cmd.ints.size(); i += 2)
                    updated[static_cast<size_t>(cmd.ints[i])] = cmd.ints[i + 1];
                int64_t sum = 0;
                for (const int32_t share : updated) sum += share;
                if (sum > 10000) {
                    if (cmd.value > 0) _player_command_rejections.push_back(
                        {"military.config.set", cmd.value, "command_shares_exceed_10000"});
                    return;
                }
                policy.config_share_bp = std::move(updated);
                return;
            }
            if (policy.config_share_bp.size() < _catalog.units.size()) {
                policy.config_share_bp.resize(_catalog.units.size(), 0);
            }
            for (int32_t &bp : policy.config_share_bp) bp = 0;
            for (size_t i = 0; i + 1 < cmd.ints.size(); i += 2) {
                policy.config_share_bp[(size_t)cmd.ints[i]] = cmd.ints[i + 1];
            }
            return;
        }
        case MCMD_POLICY_SET_WAGE:
            policy.wage_mode = (uint8_t)cmd.count;
            policy.wage_absolute = cmd.value;
            return;
        case MCMD_POLICY_SET_PROCUREMENT:
        case MCMD_POLICY_SET_BUDGET: {
            const auto share = [&](size_t index, int32_t current) {
                return index < cmd.ints.size() && cmd.ints[index] >= 0
                    ? cmd.ints[index] : current;
            };
            const bool procurement_only = cmd.op == MCMD_POLICY_SET_PROCUREMENT;
            const int32_t wage = share(0, policy.budget_wage_bp);
            const int32_t upkeep = share(1, policy.budget_upkeep_bp);
            const int32_t procurement = procurement_only ? static_cast<int32_t>(cmd.value)
                : share(2, policy.procurement_share_bp);
            if (wage + upkeep + procurement > 10000) {
                if (cmd.count > 0) _player_command_rejections.push_back({
                    procurement_only ? "military.policy.set_procurement" : "military.policy.set_budget",
                    cmd.count, "command_budget_channels_exceed_10000"});
                return;
            }
            if (!procurement_only && cmd.value >= 0)
                policy.budget_share_bp = static_cast<int32_t>(cmd.value);
            policy.budget_wage_bp = wage;
            policy.budget_upkeep_bp = upkeep;
            policy.procurement_share_bp = procurement;
            return;
        }
        case MCMD_BARRACKS_PAUSE:
            if (MilitaryCellState *st = cell_state(cmd.cell, cmd.count != 0)) st->paused = cmd.count != 0 ? 1 : 0;
            return;
        case MCMD_TRAIN: {
            // Manual order: only from heads that exist in the local garrison.
            const int32_t from_unit = cmd.unit_from >= 0 ? cmd.unit_from : _catalog.militia_unit;
            if (from_unit < 0) return;
            int64_t reserved = 0;
            for (const MilitaryTrainingOrder &o : _training) {
                if (o.cell == cmd.cell && o.country_slot == country) reserved += o.count;
            }
            const int64_t have = std::max<int64_t>(0,
                garrison_heads_for_unit(_lots, cmd.cell, country, (int16_t)from_unit) - reserved);
            const int64_t count = std::min(have, cmd.count);
            if (count <= 0) {
                if (player_order) _player_command_rejections.push_back({
                    "military.train", cmd.value, "command_no_training_garrison"});
                return;
            }
            const MilitaryUnitType &to = _catalog.units[(size_t)cmd.unit_to];
            MilitaryCellState *st = cell_state(cmd.cell, false);
            int32_t speed = MILITARY_Q16;
            MilitaryWorldDigest empty;
            if (st) {
                int32_t found = 0;
                if (barracks_speed_index_matches(_catalog, st->college_tier, &found)) speed = found;
                if (st->disrepair) speed = MILITARY_Q16 + (speed - MILITARY_Q16) / 2;
            }
            const uint8_t from_class = (from_unit == cmd.unit_to)
                                           ? to.unit_class
                                           : _catalog.units[(size_t)from_unit].unit_class;
            const int64_t kind = kind_factor_q16(from_class, to.unit_class, from_unit == cmd.unit_to);
            int64_t days = ceil_div_pos((int64_t)to.training_days * kind, MILITARY_Q16);
            days = std::max<int64_t>(1, mul_div(days, MILITARY_Q16, speed));
            MilitaryTrainingOrder o;
            o.id = _next_id++;
            o.country_slot = country;
            o.cell = cmd.cell;
            o.from_unit = (int16_t)from_unit;
            o.to_unit = (int16_t)cmd.unit_to;
            o.count = count;
            o.days_total = (int32_t)std::min<int64_t>(days, 100000);
            o.equipment_ready = 0;
            o.manual = 1;
            o.quality_q8 = (int16_t)(policy.quality_policy == 0 ? 5 * 256 : 256);
            _training.push_back(o);
            return;
        }
        case MCMD_STATE_BUILD: {
            if (cmd.unit_to < 0 || (size_t)cmd.unit_to >= _catalog.state_buildings.size()) return;
            const MilitaryStateBuilding &b = _catalog.state_buildings[(size_t)cmd.unit_to];
            MilitaryCellState *st = cell_state(cmd.cell, true);
            if (!st) return;
            // Compatibility opcode for internal AI echoes and core fixtures.
            // A player build reserves a slot as part of the treasury order.
            //
            // `construction_done_day` is a cache of the economy's schedule:
            // the authoritative completion is the economy building group's
            // pending-construction row. Only compatibility orders approximate
            // that date with the catalog duration.
            for (int32_t slot = 0; slot < MILITARY_STATE_BUILD_SLOTS; ++slot) {
                if (!st->construction_slot_available(slot, day)) continue;
                st->construction_building[slot] = cmd.unit_to;
                st->construction_done_day[slot] = day + std::max(1, b.build_days);
                return;
            }
            log_error("[military] military_construction_schedule_full cell=%d building=%d day=%lld",
                cmd.cell, cmd.unit_to, static_cast<long long>(day));
            return;
        }
        case MCMD_STATE_DEMOLISH: {
            // Deliberately a no-op on the cache. The removal already happened in
            // the economy ledger - the bridge only forwards this command after
            // `queue_treasury_sponsored_demolish` accepted it (requirement 6.5) -
            // and the next `refresh_state_building_cache` reads the smaller
            // group back. Decrementing here as well would take the building down
            // twice: once in the ledger, once in the cache, and every demolition
            // would then look like a stale cache to the repair probe.
            //
            // The opcode is kept because the bridge still echoes an accepted
            // removal through the ordinary command lane, and removing it would
            // renumber the wire format.
            (void)cmd;
            return;
        }
        case MCMD_ARMY_CREATE: {
            const int64_t total = [&]() {
                int64_t sum = 0;
                for (size_t i = 0; i + 1 < cmd.ints.size(); i += 2) sum += std::max(0, cmd.ints[i + 1]);
                return sum > 0 ? sum : 0x7FFFFFFFFFFFFFFFll;
            }();
            const int32_t army = military_embark_army(*this, country, cmd.cell, total);
            if (army < 0) {
                if (player_order)
                    _player_command_rejections.push_back({
                        "military.army.create", cmd.value, "command_no_local_garrison"});
                return;
            }
            if (!cmd.ints.empty()) set_template(*this, army, cmd.ints);
            refresh_army_cache(army);
            return;
        }
        case MCMD_ARMY_STATION:
            if (resolve_army(cmd.army, army_slot)) {
                cancel_exploration_task(army_slot, MILITARY_EXPLORATION_RESULT_CANCELLED);
                military_disembark_army(*this, army_slot);
            }
            return;
        case MCMD_ARMY_TRANSFER:
        case MCMD_ARMY_MERGE: {
            int32_t other = -1;
            // army absorbs `other`.
            if (!resolve_army(cmd.army, army_slot) || !resolve_army(cmd.other, other)) return;
            if (cmd.op == MCMD_ARMY_MERGE) {
                // Personnel lane (contract §1.2 opcode 32): the absorbed
                // formation's whole lane folds into the survivor. Counted before
                // the lots move, because those heads are the lane's population.
                int64_t absorbed_heads = 0;
                for (size_t i = 0; i < _lots.active.size(); ++i) {
                    if (!_lots.active[i] || _lots.count[i] <= 0) continue;
                    if (_lots.location_kind[i] != (uint8_t)MILITARY_LOT_ARMY) continue;
                    if (_lots.location[i] != other) continue;
                    absorbed_heads += _lots.count[i];
                }
                for (size_t i = 0; i < _lots.active.size(); ++i) {
                    if (!_lots.active[i] || _lots.count[i] <= 0) continue;
                    if (_lots.location_kind[i] != (uint8_t)MILITARY_LOT_ARMY) continue;
                    if (_lots.location[i] != other) continue;
                    const int32_t dest = lot_find_or_create((uint8_t)MILITARY_LOT_ARMY, army_slot,
                                                            _lots.country_slot[i], _lots.unit_type[i],
                                                            _lots.equip_quality_q8[i], _lots.kit_q16[i],
                                                            _lots.partial_equipment[i]);
                    if (dest < 0) continue;
                    _lots.count[(size_t)dest] += _lots.count[i];
                    _lots.count[i] = 0;
                }
                for (size_t i = 0; i < _lots.active.size(); ++i) {
                    if (_lots.active[i] && _lots.count[i] <= 0) {
                        _lots.active[i] = 0;
                        _lots.free_list.push_back((int32_t)i);
                    }
                }
                _armies.reinforce_enabled[(size_t)army_slot] =
                    _armies.reinforce_enabled[(size_t)army_slot] | _armies.reinforce_enabled[(size_t)other];
                // Fold the absorbed lane into the survivor (opcode 32) before the
                // source formation disappears, so `other` still resolves.
                emit_army_lane_intent(MILITARY_INTENT_ARMY_MERGE_LANES, army_slot,
                                      _armies.cell[(size_t)army_slot], absorbed_heads,
                                      army_handle(other));
                destroy_army(other);
                refresh_army_cache(army_slot);
                return;
            }
            // Transfer keeps the source formation alive; its old explore
            // mission is cancelled. Merge goes through destroy_army below,
            // which owns cancellation and retires the task row.
            cancel_exploration_task(other, MILITARY_EXPLORATION_RESULT_CANCELLED);
            // transfer: (unit, count) pairs, -1 unit means "any".
            // Personnel lane (contract §1.2): the people move with the lots. The
            // head count is what `transfer_army_to_army` actually moved (it clamps
            // to the source's lots), never the template the player asked for.
            int64_t moved = 0;
            for (size_t i = 0; i + 1 < cmd.ints.size(); i += 2) {
                const int32_t unit = cmd.ints[i];
                const int64_t count = cmd.ints[i + 1];
                if (count <= 0) continue;
                moved += transfer_army_to_army(*this, other, army_slot,
                                               unit < 0 ? -1 : unit, count);
            }
            if (moved > 0) {
                // Whole formation transferred -> fold the source lane into the
                // receiver (opcode 32, the army.merge semantics). A partial
                // transfer only moves the heads that left (opcode 33), so the
                // rest of the source formation keeps its own people.
                int64_t remaining = 0;
                for (size_t i = 0; i < _lots.active.size(); ++i) {
                    if (!_lots.active[i] || _lots.count[i] <= 0) continue;
                    if (_lots.location_kind[i] != (uint8_t)MILITARY_LOT_ARMY) continue;
                    if (_lots.location[i] != other) continue;
                    remaining += _lots.count[i];
                }
                emit_army_lane_intent(
                    remaining <= 0 ? MILITARY_INTENT_ARMY_MERGE_LANES
                                   : MILITARY_INTENT_ARMY_SPLIT_LANES,
                    army_slot, _armies.cell[(size_t)army_slot], moved,
                    army_handle(other));
                // `moved` raises this formation's in-flight ceiling on purpose:
                // its lane is still short of those heads until the command lands,
                // and the lane reconcile at the end of this same day would
                // otherwise trim them straight off the lots. The receipt releases
                // the ceiling once the lane has caught up.
            }
            refresh_army_cache(army_slot);
            refresh_army_cache(other);
            return;
        }
        case MCMD_ARMY_SPLIT: {
            if (!resolve_army(cmd.army, army_slot)) return;
            cancel_exploration_task(army_slot, MILITARY_EXPLORATION_RESULT_CANCELLED);
            const int32_t cell = _armies.cell[(size_t)army_slot];
            const int32_t owner = _armies.owner_slot[(size_t)army_slot];
            // Split out (unit, count) pairs into a new formation at the same cell.
            int64_t total = 0;
            for (size_t i = 0; i + 1 < cmd.ints.size(); i += 2) total += std::max(0, cmd.ints[i + 1]);
            if (total <= 0) return;
            const int32_t created = create_army(owner, cell);
            if (created < 0) return;
            int64_t moved = 0;
            for (size_t i = 0; i + 1 < cmd.ints.size(); i += 2) {
                const int32_t unit = cmd.ints[i];
                const int64_t count = cmd.ints[i + 1];
                if (count <= 0) continue;
                moved += transfer_army_to_army(*this, army_slot, created, unit, count);
            }
            // Personnel lane (contract §1.2 opcode 33): the detached formation gets
            // its own people, not a copy of the template. `moved` is the sum of the
            // lot counts that actually left the source formation; the source lane
            // loses exactly those heads and the new formation's lane gains them.
            if (moved > 0) {
                emit_army_lane_intent(MILITARY_INTENT_ARMY_SPLIT_LANES, created, cell, moved,
                                      army_handle(army_slot));
                // Same rule as the transfer above: the new formation's lots run
                // ahead of its lane until the split command lands, so the heads
                // stay in flight (the reconcile at the end of this day must not
                // trim them). `emit_army_lane_intent` puts the receipt on this
                // formation, so the ceiling is released when the lane catches up.
            }
            refresh_army_cache(army_slot);
            refresh_army_cache(created);
            if (moved <= 0) destroy_army(created);
            return;
        }
        case MCMD_ARMY_SET_TEMPLATE:
            if (resolve_army(cmd.army, army_slot)) set_template(*this, army_slot, cmd.ints);
            return;
        case MCMD_ARMY_REINFORCE:
            if (resolve_army(cmd.army, army_slot)) _armies.reinforce_enabled[(size_t)army_slot] = cmd.count != 0 ? 1 : 0;
            return;
        case MCMD_ARMY_MOVE: {
            if (!resolve_army(cmd.army, army_slot)) return;
            if (!player_map_order)
                cancel_exploration_task(army_slot, MILITARY_EXPLORATION_RESULT_CANCELLED);
            const int32_t owner = _armies.owner_slot[(size_t)army_slot];
            MilitaryWorldDigest empty;
            std::vector<int32_t> path;
            if (!find_path(army_slot, cmd.cell, empty, path)) {
                if (player_map_order)
                    _player_command_rejections.push_back(
                        {map_order, cmd.value, "military_path_unreachable"});
                return;
            }
            if (player_map_order)
                cancel_exploration_task(army_slot, MILITARY_EXPLORATION_RESULT_CANCELLED);
            const size_t s = (size_t)army_slot;
            const int32_t off = (int32_t)_path_cells.size();
            _path_cells.insert(_path_cells.end(), path.begin(), path.end());
            _armies.path_offset[s] = path.empty() ? 0 : off;
            _armies.path_len[s] = (int32_t)path.size();
            _armies.path_cursor[s] = 0;
            _armies.target_cell[s] = cmd.cell;
            _armies.mission[s] = (uint8_t)MILITARY_MISSION_MOVE;
            if (_armies.stance[s] == (uint8_t)MILITARY_STANCE_RETREAT) {
                _armies.stance[s] = (uint8_t)MILITARY_STANCE_HOLD;
            }
            (void)owner;
            return;
        }
        case MCMD_ARMY_AREA_CONTROL: {
            if (!resolve_army(cmd.army, army_slot)) return;
            if (player_map_order && cmd.cell >= 0) {
                std::vector<int32_t> route;
                int32_t travel_days = 0;
                if (!preview_path(cmd.army, cmd.cell, route, travel_days)) {
                    _player_command_rejections.push_back(
                        {map_order, cmd.value, "military_path_unreachable"});
                    return;
                }
            }
            cancel_exploration_task(army_slot, MILITARY_EXPLORATION_RESULT_CANCELLED);
            std::vector<int32_t> cells = cmd.cells;
            if (cells.empty() && cmd.cell >= 0) {
                // Centre + radius: ring walk via BFS on the neighbour table.
                cells = ring_cells(cmd.cell, cmd.radius);
            }
            if (cells.empty()) return;
            std::sort(cells.begin(), cells.end());
            cells.erase(std::unique(cells.begin(), cells.end()), cells.end());
            if (cells.size() > (size_t)MILITARY_MAX_AREA_CELLS) cells.resize((size_t)MILITARY_MAX_AREA_CELLS);
            const int32_t owner = _armies.owner_slot[(size_t)army_slot];
            int32_t area_id = _armies.area_id[(size_t)army_slot];
            if (area_id < 0 || (size_t)area_id >= _areas.size() || !_areas[(size_t)area_id].active) {
                MilitaryArea area;
                area.id = (int32_t)_areas.size();
                area.owner_slot = owner;
                area.last_eval_day = -100000;
                area.active = 1;
                area.cells = cells;
                _areas.push_back(area);
                area_id = area.id;
            } else {
                _areas[(size_t)area_id].cells = cells;
                _areas[(size_t)area_id].owner_slot = owner;
                _areas[(size_t)area_id].last_eval_day = -100000;
                _areas[(size_t)area_id].active = 1;
            }
            _armies.area_id[(size_t)army_slot] = area_id;
            _armies.mission[(size_t)army_slot] = (uint8_t)MILITARY_MISSION_AREA_CONTROL;
            return;
        }
        case MCMD_ARMY_STOP: {
            if (!resolve_army(cmd.army, army_slot)) return;
            cancel_exploration_task(army_slot, MILITARY_EXPLORATION_RESULT_CANCELLED);
            const size_t s = (size_t)army_slot;
            _armies.path_len[s] = 0;
            _armies.path_cursor[s] = 0;
            _armies.target_cell[s] = -1;
            _armies.mission[s] = (uint8_t)MILITARY_MISSION_NONE;
            _armies.area_id[s] = -1;
            return;
        }
        case MCMD_ARMY_STANCE: {
            if (!resolve_army(cmd.army, army_slot)) return;
            cancel_exploration_task(army_slot, MILITARY_EXPLORATION_RESULT_CANCELLED);
            _armies.stance[(size_t)army_slot] = (uint8_t)cmd.count;
            if (cmd.count != MILITARY_STANCE_RETREAT) {
                // leaving RETREAT resumes normal movement
            }
            return;
        }
        case MCMD_ARMY_RENAME: {
            if (!resolve_army(cmd.army, army_slot)) return;
            _armies.name_seed[(size_t)army_slot] = (uint32_t)(cmd.value & 0xFFFFFFFFll);
            return;
        }
        case MCMD_ARMY_DISBAND:
            if (resolve_army(cmd.army, army_slot)) military_disembark_army(*this, army_slot);
            return;
        case MCMD_ARMY_EXPLORE: {
            if (!resolve_army(cmd.army, army_slot)) return;
            if (_armies.owner_slot[(size_t)army_slot] != country) return;
            // Exploration is a player-only command. The host installs the
            // observer before a day with pending work; every other country is
            // rejected here even if it can submit a structurally valid command.
            if (_exploration_observer_slot < 0 ||
                country != _exploration_observer_slot) {
                return;
            }
            if (cmd.cells.empty() && player_map_order) {
                MilitaryCommand order = cmd;
                order.cells = ring_cells(cmd.cell, cmd.radius);
                create_exploration_task(order, day, army_slot, country);
            } else {
                create_exploration_task(cmd, day, army_slot, country);
            }
            return;
        }
        default:
            apply_war_command(cmd, day);
            return;
    }
}

std::vector<int32_t> MilitaryCore::ring_cells(int32_t center, int32_t radius) const {
    std::vector<int32_t> out;
    if (center < 0 || center >= _terrain.cell_count) return out;
    if (radius <= 0) {
        out.push_back(center);
        return out;
    }
    static thread_local std::vector<int32_t> frontier;
    static thread_local std::vector<int32_t> next;
    static thread_local std::vector<int32_t> dist;
    dist.assign((size_t)_terrain.cell_count, -1);
    frontier.clear();
    frontier.push_back(center);
    dist[(size_t)center] = 0;
    out.push_back(center);
    for (int32_t r = 0; r < radius; ++r) {
        next.clear();
        for (int32_t cell : frontier) {
            const int32_t base = cell * 6;
            for (int32_t d = 0; d < 6; ++d) {
                const int32_t nb = _terrain.neighbors[(size_t)(base + d)];
                if (nb < 0 || nb >= _terrain.cell_count) continue;
                if (dist[(size_t)nb] >= 0) continue;
                dist[(size_t)nb] = r + 1;
                next.push_back(nb);
                out.push_back(nb);
            }
        }
        frontier.swap(next);
        if (frontier.empty()) break;
    }
    std::sort(out.begin(), out.end());
    return out;
}

} // namespace pk
