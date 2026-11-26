// military_core_explore.cpp - player army auto-exploration.
//
// Exploration is deliberately a MilitaryCore concern: the task state machine,
// observer choice, path budgets and return trip all run inside the ordinary
// military day. The host only supplies a frozen copy of the player's explored
// map and drains the explored-only trail after movement.

#include "military_core.h"
#include "military_core_internal.h"

#include <algorithm>
#include <array>
#include <limits>

namespace pk {

// ============================================================== queries

int32_t MilitaryCore::exploration_row_for_army(int32_t army_slot) const {
    if (army_slot < 0 || (size_t)army_slot >= _exploration_by_army.size()) return -1;
    const int16_t row = _exploration_by_army[(size_t)army_slot];
    if (row < 0 || (size_t)row >= _explorations.size()) return -1;
    const MilitaryExplorationTask &task = _explorations[(size_t)row];
    if (!task.active || task.row_index != row) return -1;
    if (task.army_handle != army_handle(army_slot)) return -1;
    return row;
}

const MilitaryExplorationTask *MilitaryCore::exploration_task_for_army(int32_t army_slot) const {
    const int32_t row = exploration_row_for_army(army_slot);
    return row >= 0 ? &_explorations[(size_t)row] : nullptr;
}

bool MilitaryCore::exploration_is_live_for_army(int32_t army_slot) const {
    const MilitaryExplorationTask *task = exploration_task_for_army(army_slot);
    if (task == nullptr) return false;
    return task->phase == MILITARY_EXPLORATION_ACTIVE ||
           task->phase == MILITARY_EXPLORATION_RETURNING ||
           task->phase == MILITARY_EXPLORATION_PAUSED_BATTLE;
}

const std::vector<int32_t> &MilitaryCore::exploration_trail(int32_t observer_slot) const {
    static const std::vector<int32_t> empty;
    if (observer_slot < 0 || observer_slot != _exploration_observer_slot) return empty;
    return _exploration_trail;
}

bool MilitaryCore::has_exploration_work(int64_t through_day) const {
    if (!_exploration_trail.empty()) return true;
    for (const MilitaryCommand &cmd : _pending) {
        if (cmd.op == MCMD_ARMY_EXPLORE &&
            (through_day < 0 || cmd.effective_day <= through_day)) return true;
    }
    for (const MilitaryExplorationTask &task : _explorations) {
        if (!task.active) continue;
        if (task.phase == MILITARY_EXPLORATION_ACTIVE ||
            task.phase == MILITARY_EXPLORATION_RETURNING ||
            task.phase == MILITARY_EXPLORATION_PAUSED_BATTLE) {
            return true;
        }
    }
    return false;
}

void MilitaryCore::set_exploration_observer(int32_t observer_slot) {
    if (observer_slot < -1) observer_slot = -1;
    if (_exploration_observer_slot == observer_slot) return;
    _exploration_observer_slot = observer_slot;
    _exploration_trail.clear();
    if (++_exploration_trail_gen == 0) {
        std::fill(_exploration_trail_stamp.begin(), _exploration_trail_stamp.end(), 0u);
        _exploration_trail_gen = 1;
    }
}

void MilitaryCore::set_exploration_view(int32_t observer_slot, const uint8_t *explored,
                                        size_t explored_size, int64_t day, uint64_t revision) {
    set_exploration_observer(observer_slot);
    _exploration_view_day = day;
    _exploration_view_revision = revision;
    const size_t cells = (size_t)std::max(0, _terrain.cell_count);
    if (!explored || explored_size != cells) {
        _exploration_explored_view.clear();
        return;
    }
    _exploration_explored_view.assign(explored, explored + explored_size);
}

void MilitaryCore::clear_exploration_trail(int32_t observer_slot) {
    if (observer_slot < 0 || observer_slot != _exploration_observer_slot) return;
    _exploration_trail.clear();
    if (++_exploration_trail_gen == 0) {
        std::fill(_exploration_trail_stamp.begin(), _exploration_trail_stamp.end(), 0u);
        _exploration_trail_gen = 1;
    }
}

void MilitaryCore::rebuild_exploration_index() {
    _exploration_by_army.assign((size_t)MILITARY_MAX_ARMIES, -1);
    for (int32_t row = 0; row < (int32_t)_explorations.size(); ++row) {
        MilitaryExplorationTask &task = _explorations[(size_t)row];
        if (!task.active) continue;
        task.row_index = row;
        // Cancellation leaves the record for history but detaches it from
        // the army. Naturally completed tasks stay attached until replaced.
        if (task.result == MILITARY_EXPLORATION_RESULT_CANCELLED) continue;
        int32_t army_slot = -1;
        if (!resolve_army(task.army_handle, army_slot)) continue;
        _exploration_by_army[(size_t)army_slot] = (int16_t)row;
    }
}

} // namespace pk
