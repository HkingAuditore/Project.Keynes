#include "military_core_internal.h"

namespace pk {

bool military_validate_restored_exploration_paths(MilitaryCore &core, std::string &error) {
    // Exploration routes are regular army paths; the last cell must still name
    // the observation / return target the task persisted.
    for (const MilitaryExplorationTask &task : core._explorations) {
        if (!task.active) continue;
        // Terminal records remain attached to the army as history. Any
        // subsequent route belongs to the army's current orders.
        if (task.phase == MILITARY_EXPLORATION_COMPLETE ||
            task.phase == MILITARY_EXPLORATION_FAILED_NO_RETURN) continue;
        int32_t army_slot = -1;
        if (!core.resolve_army(task.army_handle, army_slot)) {
            error = "pkmi_exploration_army_missing";
            return false;
        }
        const MilitaryArmyStore &a = core._armies;
        const int32_t len = a.path_len[(size_t)army_slot];
        if (len <= 0) continue;
        const int32_t off = a.path_offset[(size_t)army_slot];
        if (off < 0 || (size_t)(off + len) > core._path_cells.size()) {
            error = "pkmi_exploration_bad_phase";
            return false;
        }
        const int32_t expected =
            task.phase == MILITARY_EXPLORATION_RETURNING
                ? task.return_cell : task.current_observation_cell;
        if (expected < 0 ||
            core._path_cells[(size_t)(off + len - 1)] != expected) {
            error = "pkmi_exploration_bad_phase";
            return false;
        }
        if (task.phase == MILITARY_EXPLORATION_PAUSED_BATTLE) {
            error = "pkmi_exploration_bad_phase";
            return false;
        }
    }
    return true;
}

} // namespace pk
