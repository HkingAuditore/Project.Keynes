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

bool MilitaryCore::validate_command(MilitaryCommand &command, std::string &error) const {
    error.clear();
    if (!_configured) {
        error = "military_not_configured";
        return false;
    }
    const int64_t cmd_day = command.effective_day;
    if (cmd_day < _last_day) {
        error = "command_day_in_past";
        return false;
    }
    // Army-scoped commands (move / stance / stop / area_control) may omit the
    // country: the formation knows its owner, and requiring the caller to
    // repeat it only surfaces command_missing_country from the map layer.
    if (command.country == 0 && command.army != 0) {
        int32_t owner_army = -1;
        if (resolve_army(command.army, owner_army) && owner_army >= 0) {
            const int32_t owner = _armies.owner_slot[(size_t)owner_army];
            if (owner >= 0 && (size_t)owner < _policy_handle.size())
                command.country = _policy_handle[(size_t)owner];
        }
    }
    if (command.country == 0) {
        error = "command_missing_country";
        return false;
    }
    const bool has_country = country_slot_for_handle(command.country) >= 0;
    int32_t army_slot = -1;
    const bool has_army = resolve_army(command.army, army_slot);
    auto need_country = [&]() -> bool {
        if (has_country) return true;
        error = "command_unknown_country";
        return false;
    };
    auto need_army = [&]() -> bool {
        if (has_army) return true;
        error = "command_unknown_army";
        return false;
    };

    auto need_cell = [&](int32_t cell) -> bool {
        if (cell >= 0 && cell < _terrain.cell_count) return true;
        error = "command_bad_cell";
        return false;
    };
    auto unit_ok = [&](int32_t unit) -> bool {
        return unit >= 0 && unit < (int32_t)_catalog.units.size();
    };
    switch (command.op) {
        case MCMD_FORCE_SET_TARGET:
            if (!need_country()) return false;
            if (command.count < 0 || command.count > 1) {
                error = "command_bad_target_mode";
                return false;
            }
            if (command.value < 0) {
                error = "command_bad_target_value";
                return false;
            }
            break;
        case MCMD_FORCE_SET_LEVY:
        case MCMD_FORCE_SET_AUTO_DISCHARGE:
        case MCMD_CONFIG_AUTO_RETRAIN:
            if (!need_country()) return false;
            break;
        case MCMD_CONFIG_SET_QUALITY_POLICY:
            if (!need_country()) return false;
            if (command.value < 0 || command.value > 1) {
                error = "command_bad_quality_policy";
                return false;
            }
            break;
        case MCMD_CONFIG_SET: {
            if (!need_country()) return false;
            if (command.ints.size() % 2 != 0) {
                error = "command_bad_shares";
                return false;
            }
            int64_t sum = 0;
            for (size_t i = 0; i + 1 < command.ints.size(); i += 2) {
                if (!unit_ok(command.ints[i])) {
                    error = "command_bad_unit";
                    return false;
                }
                const int32_t bp = command.ints[i + 1];
                if (bp < 0 || bp > 10000) {
                    error = "command_bad_share_bp";
                    return false;
                }
                sum += bp;
            }
            if (sum > 10000) {
                error = "command_shares_exceed_10000";
                return false;
            }
            break;
        }
        case MCMD_BARRACKS_PAUSE: {
            if (!need_country()) return false;
            if (!need_cell(command.cell)) return false;
            const int32_t owner = military_cell_garrison_slot(*this, command.cell);
            if (owner >= 0 && owner != country_slot_for_handle(command.country)) {
                error = "command_not_owner";
                return false;
            }
            break;
        }
        case MCMD_TRAIN: {
            if (!need_country()) return false;
            if (!need_cell(command.cell)) return false;
            if (!unit_ok(command.unit_to)) {
                error = "command_bad_unit";
                return false;
            }
            if (command.unit_from >= (int32_t)_catalog.units.size()) {
                error = "command_bad_unit";
                return false;
            }
            if (command.count <= 0) {
                error = "command_bad_count";
                return false;
            }
            break;
        }
        case MCMD_STATE_BUILD:
        case MCMD_STATE_DEMOLISH: {
            if (!need_country()) return false;
            if (!need_cell(command.cell)) return false;
            if (command.unit_to < 0 || command.unit_to >= (int32_t)_catalog.state_buildings.size()) {
                error = "command_bad_state_building";
                return false;
            }
            break;
        }
        case MCMD_POLICY_SET_WAGE:
            if (!need_country()) return false;
            if (command.count < 0 || command.count > 1) {
                error = "command_bad_wage_mode";
                return false;
            }
            if (command.value < 0) {
                error = "command_bad_wage";
                return false;
            }
            break;
        case MCMD_POLICY_SET_PROCUREMENT:
            if (!need_country()) return false;
            if (command.value < 0 || command.value > 10000) {
                error = "command_bad_procurement_share";
                return false;
            }
            break;
        case MCMD_POLICY_SET_BUDGET: {
            if (!need_country()) return false;
            if (command.value < -1 || command.value > 10000) {
                error = "command_bad_budget_share";
                return false;
            }
            if (command.ints.size() > 3) {
                error = "command_bad_budget_channels";
                return false;
            }
            for (const int32_t bp : command.ints) {
                if (bp < -1 || bp > 10000) {
                    error = "command_bad_budget_channel_share";
                    return false;
                }
            }
            break;
        }
        case MCMD_ARMY_CREATE: {
            if (!need_country()) return false;
            if (!need_cell(command.cell)) return false;
            if (command.ints.size() % 2 != 0) {
                error = "command_bad_units";
                return false;
            }
            const int32_t owner = country_slot_for_handle(command.country);
            if (command.value == 0 && military_cell_garrison_slot(*this, command.cell) != owner) {
                error = "command_no_local_garrison";
                return false;
            }
            break;
        }
        case MCMD_ARMY_STATION:
            if (!need_country()) return false;
            if (!need_country_owns_army(has_country, command)) {
                error = "command_not_owner";
                return false;
            }
            if (!need_army()) return false;
            break;
        case MCMD_ARMY_TRANSFER: {
            if (!need_country()) return false;
            if (!need_army()) return false;
            int32_t other = -1;
            if (!resolve_army(command.other, other)) {
                error = "command_unknown_army";
                return false;
            }
            if (_armies.cell[(size_t)army_slot] != _armies.cell[(size_t)other]) {
                error = "command_armies_not_colocated";
                return false;
            }
            break;
        }
        case MCMD_ARMY_MERGE: {
            if (!need_country()) return false;
            if (!need_army()) return false;
            int32_t other = -1;
            if (!resolve_army(command.other, other)) {
                error = "command_unknown_army";
                return false;
            }
            if (_armies.cell[(size_t)army_slot] != _armies.cell[(size_t)other]) {
                error = "command_armies_not_colocated";
                return false;
            }
            break;
        }
        case MCMD_ARMY_SPLIT:
        case MCMD_ARMY_SET_TEMPLATE: {
            if (!need_country()) return false;
            if (!need_army()) return false;
            if (command.ints.size() % 2 != 0) {
                error = "command_bad_units";
                return false;
            }
            break;
        }
        case MCMD_ARMY_REINFORCE:
            if (!need_country()) return false;
            if (!need_army()) return false;
            break;
        case MCMD_ARMY_MOVE:
            if (!need_country()) return false;
            if (!need_army()) return false;
            if (!need_cell(command.cell)) return false;
            break;
        case MCMD_ARMY_AREA_CONTROL: {
            if (!need_country()) return false;
            if (!need_army()) return false;
            if (command.cells.empty()) {
                if (!need_cell(command.cell)) return false;
                if (command.radius < 1 || command.radius > MILITARY_MAX_AREA_RADIUS) {
                    error = "command_bad_area_radius";
                    return false;
                }
            } else if (command.cells.size() > (size_t)MILITARY_MAX_AREA_CELLS) {
                error = "command_area_too_large";
                return false;
            }
            for (int32_t cell : command.cells) {
                if (cell < 0 || cell >= _terrain.cell_count) {
                    error = "command_bad_cell";
                    return false;
                }
            }
            break;
        }
        case MCMD_ARMY_STOP:
            if (!need_country()) return false;
            if (!need_army()) return false;
            break;
        case MCMD_ARMY_STANCE:
            if (!need_country()) return false;
            if (!need_army()) return false;
            if (command.count < 0 || command.count > MILITARY_STANCE_EMBARKED) {
                error = "command_bad_stance";
                return false;
            }
            break;
        case MCMD_ARMY_RENAME:
            if (!need_country()) return false;
            if (!need_army()) return false;
            break;
        case MCMD_ARMY_DISBAND:
            if (!need_country()) return false;
            if (!need_army()) return false;
            break;
        case MCMD_ARMY_EXPLORE: {
            if (!need_country()) return false;
            if (command.value <= 0 && !need_country_owns_army(has_country, command)) {
                error = "command_not_owner";
                return false;
            }
            if (!need_army()) return false;
            if (!need_cell(command.cell)) return false;
            if (command.radius < 1 || command.radius > MILITARY_MAX_AREA_RADIUS) {
                error = "command_bad_exploration_radius";
                return false;
            }
            if ((command.cells.empty() && command.value <= 0) ||
                command.cells.size() > (size_t)MILITARY_MAX_EXPLORATION_CELLS) {
                error = "command_bad_exploration_cells";
                return false;
            }
            std::sort(command.cells.begin(), command.cells.end());
            command.cells.erase(std::unique(command.cells.begin(), command.cells.end()),
                                command.cells.end());
            for (int32_t cell : command.cells) {
                if (cell < 0 || cell >= _terrain.cell_count) {
                    error = "command_bad_exploration_cells";
                    return false;
                }
            }
            if (command.value <= 0 && _armies.engagement[(size_t)army_slot] >= 0) {
                error = "command_army_in_engagement";
                return false;
            }
            if (command.value <= 0 && !can_create_exploration_task(army_slot)) {
                error = "command_exploration_capacity_full";
                return false;
            }
            break;
        }
        case MCMD_WAR_DECLARE:
        case MCMD_WAR_DECLARE_FORCED:
        case MCMD_PEACE_PROPOSE:
        case MCMD_PEACE_RESPOND:
            if (!need_country()) return false;
            break;
        case MCMD_GARRISON_TRANSFER_CELL:
            if (!need_country()) return false;
            if (command.cell < 0 || command.cell >= _terrain.cell_count) {
                error = "command_bad_cell";
                return false;
            }
            if (country_slot_for_handle(command.other) < 0) {
                error = "command_country_unknown";
                return false;
            }
            break;
        default:
            error = "command_unknown_op";
            return false;
    }
    return true;
}

bool MilitaryCore::need_country_owns_army(bool has_country, const MilitaryCommand &command) const {
    if (!has_country) return false;
    int32_t slot = -1;
    if (!resolve_army(command.army, slot)) return false;
    const int32_t owner = _armies.owner_slot[(size_t)slot];
    return owner >= 0 && _policy_handle.size() > (size_t)owner && _policy_handle[(size_t)owner] == command.country;
}

} // namespace pk
