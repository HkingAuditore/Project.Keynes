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

namespace {

using namespace mil;

constexpr int32_t kMaskWords = 4;

inline bool mask_test(const std::array<uint64_t, kMaskWords> &mask, int32_t index) {
    if (index < 0 || index >= MILITARY_MAX_EXPLORATION_CELLS) return false;
    return (mask[(size_t)(index >> 6)] & (1ull << (uint32_t)(index & 63))) != 0ull;
}

inline void mask_set(std::array<uint64_t, kMaskWords> &mask, int32_t index) {
    if (index < 0 || index >= MILITARY_MAX_EXPLORATION_CELLS) return;
    mask[(size_t)(index >> 6)] |= 1ull << (uint32_t)(index & 63);
}

inline void mask_clear(std::array<uint64_t, kMaskWords> &mask, int32_t index) {
    if (index < 0 || index >= MILITARY_MAX_EXPLORATION_CELLS) return;
    mask[(size_t)(index >> 6)] &= ~(1ull << (uint32_t)(index & 63));
}

inline bool task_resolved(const MilitaryExplorationTask &task, int32_t index) {
    return mask_test(task.seen_mask, index) || mask_test(task.visited_mask, index) ||
           mask_test(task.blocked_mask, index);
}

inline void set_seen(MilitaryExplorationTask &task, int32_t index) {
    mask_set(task.seen_mask, index);
    mask_clear(task.visited_mask, index);
    mask_clear(task.blocked_mask, index);
}

inline void set_visited(MilitaryExplorationTask &task, int32_t index) {
    if (mask_test(task.seen_mask, index)) return;
    mask_set(task.visited_mask, index);
    mask_clear(task.blocked_mask, index);
}

inline void set_blocked(MilitaryExplorationTask &task, int32_t index) {
    if (mask_test(task.seen_mask, index)) return;
    if (mask_test(task.visited_mask, index)) return;
    mask_set(task.blocked_mask, index);
}

int32_t resolved_count(const MilitaryExplorationTask &task) {
    int32_t resolved = 0;
    for (int32_t i = 0; i < task.selected_count; ++i) {
        if (task_resolved(task, i)) ++resolved;
    }
    return resolved;
}

int32_t blocked_count(const MilitaryExplorationTask &task) {
    int32_t count = 0;
    for (int32_t i = 0; i < task.selected_count; ++i) {
        if (mask_test(task.blocked_mask, i)) ++count;
    }
    return count;
}

bool all_resolved(const MilitaryExplorationTask &task) {
    return task.selected_count > 0 && resolved_count(task) == task.selected_count;
}

int32_t effective_controller_for(const MilitaryCore &core, const MilitaryWorldDigest &digest,
                                 int32_t cell) {
    if (cell < 0 || cell >= core.terrain().cell_count) return -1;
    const int32_t ctrl = core.controller_of(cell);
    if (ctrl >= 0) return ctrl;
    if ((size_t)cell < digest.cell_owner_slot.size()) return digest.cell_owner_slot[(size_t)cell];
    return -1;
}

void clear_army_route(MilitaryArmyStore &armies, int32_t army_slot, bool clear_mission) {
    if (army_slot < 0 || (size_t)army_slot >= armies.active.size()) return;
    const size_t s = (size_t)army_slot;
    armies.path_len[s] = 0;
    armies.path_cursor[s] = 0;
    armies.target_cell[s] = -1;
    armies.move_points_q16[s] = 0;
    if (clear_mission) armies.mission[s] = (uint8_t)MILITARY_MISSION_NONE;
}

void begin_return(MilitaryExplorationTask &task, MilitaryArmyStore &armies,
                  int32_t army_slot) {
    task.result = blocked_count(task) > 0
                      ? (uint8_t)MILITARY_EXPLORATION_RESULT_SEEN_WITH_UNOBSERVABLE
                      : (uint8_t)MILITARY_EXPLORATION_RESULT_ALL_SEEN;
    task.phase = (uint8_t)MILITARY_EXPLORATION_RETURNING;
    task.pause_reason = (uint8_t)MILITARY_EXPLORATION_PAUSE_NONE;
    task.resume_phase = (uint8_t)MILITARY_EXPLORATION_RETURNING;
    task.focus_index = -1;
    task.current_observation_cell = -1;
    task.observer_tries = 0;
    task.tried_observer_mask = 0;
    task.reached_observer_cells.fill(-1);
    clear_army_route(armies, army_slot, false);
}

bool route_is_valid(const MilitaryCore &core, const MilitaryExplorationTask &task,
                    const MilitaryWorldDigest &digest) {
    const MilitaryArmyStore &armies = core.armies();
    int32_t army_slot = -1;
    if (!core.resolve_army(task.army_handle, army_slot)) return false;
    const size_t s = (size_t)army_slot;
    if (armies.mission[s] != (uint8_t)MILITARY_MISSION_EXPLORE) return false;
    if (armies.path_cursor[s] >= armies.path_len[s]) return false;
    const int32_t expected = task.phase == (uint8_t)MILITARY_EXPLORATION_RETURNING
                                 ? task.return_cell : task.current_observation_cell;
    if (expected < 0) return false;
    if (armies.path_offset[s] < 0 || armies.path_len[s] <= 0) return false;
    // Validate the whole remaining route, not only the next cell. Control can
    // change between planning days; a later foreign cell must cause a replan
    // instead of opening an engagement midway through an exploration day.
    for (int32_t cursor = armies.path_cursor[s]; cursor < armies.path_len[s];
         ++cursor) {
        const int32_t step = core.path_cell_at(army_slot, cursor);
        if (step < 0 ||
            !core.exploration_passable_for(step, task.owner_slot, digest)) {
            return false;
        }
    }
    const int32_t last = core.path_cell_at(army_slot, armies.path_len[s] - 1);
    return last == expected;
}

void install_path(MilitaryCore &core, MilitaryExplorationTask &task,
                  int32_t army_slot, const std::vector<int32_t> &path, int32_t target) {
    MilitaryArmyStore &armies = core.armies_mutable();
    const size_t s = (size_t)army_slot;
    const int32_t offset = path.empty() ? 0 : (int32_t)core.path_arena_size();
    core.append_path(path);
    armies.path_offset[s] = offset;
    armies.path_len[s] = (int32_t)path.size();
    armies.path_cursor[s] = 0;
    armies.target_cell[s] = target;
    armies.mission[s] = (uint8_t)MILITARY_MISSION_EXPLORE;
    task.last_progress_day = core.last_day();
}

int32_t focus_cell(const MilitaryExplorationTask &task) {
    if (task.focus_index < 0 || task.focus_index >= task.selected_count) return -1;
    return task.selected_cells[(size_t)task.focus_index];
}

bool has_reached_observer(const MilitaryExplorationTask &task, int32_t cell) {
    for (int32_t reached : task.reached_observer_cells) {
        if (reached == cell) return true;
    }
    return false;
}

void mark_candidate_tried(MilitaryExplorationTask &task, int32_t candidate_index) {
    if (candidate_index < 0 || candidate_index >= 32) return;
    task.tried_observer_mask |= (1u << (uint32_t)candidate_index);
}

struct ObserverCandidateList {
    std::array<int32_t, MILITARY_MAX_EXPLORATION_CELLS> cells{};
    int32_t count = 0;
};

void build_observer_candidates(const MilitaryCore &core, int32_t target,
                               ObserverCandidateList &out) {
    out.count = 0;
    if (target < 0 || target >= core.terrain().cell_count) return;
    std::vector<int32_t> cells = core.ring_cells(target, MILITARY_EXPLORATION_OBSERVER_RADIUS);
    std::sort(cells.begin(), cells.end(), [&core, target](int32_t a, int32_t b) {
        const int32_t da = core.cell_distance(a, target);
        const int32_t db = core.cell_distance(b, target);
        if (da != db) return da < db;
        return a < b;
    });
    for (int32_t cell : cells) {
        if (out.count >= (int32_t)out.cells.size()) break;
        out.cells[(size_t)out.count++] = cell;
    }
}

int32_t candidate_index_of(const ObserverCandidateList &list, int32_t cell) {
    for (int32_t i = 0; i < list.count; ++i) {
        if (list.cells[(size_t)i] == cell) return i;
    }
    return -1;
}

void mark_observation_reached(MilitaryCore &core, MilitaryExplorationTask &task,
                              int32_t army_slot) {
    if (task.current_observation_cell < 0) return;
    const MilitaryArmyStore &armies = core.armies();
    if (armies.cell[(size_t)army_slot] != task.current_observation_cell) return;
    ObserverCandidateList candidates;
    build_observer_candidates(core, focus_cell(task), candidates);
    const int32_t candidate = candidate_index_of(candidates, task.current_observation_cell);
    if (candidate >= 0) mark_candidate_tried(task, candidate);
    if (!has_reached_observer(task, task.current_observation_cell) &&
        task.observer_tries < MILITARY_EXPLORATION_OBSERVERS) {
        task.reached_observer_cells[(size_t)task.observer_tries++] =
            task.current_observation_cell;
    }
    task.current_observation_cell = -1;
    task.last_progress_day = core.last_day();
    if (task.observer_tries >= MILITARY_EXPLORATION_OBSERVERS &&
        task.focus_index >= 0 && !task_resolved(task, task.focus_index)) {
        set_blocked(task, task.focus_index);
    }
}

void refresh_seen_from_view(MilitaryCore &core, MilitaryExplorationTask &task) {
    const std::vector<uint8_t> &view = core.exploration_view();
    const MilitaryArmyStore &armies = core.armies();
    int32_t army_slot = -1;
    if (!core.resolve_army(task.army_handle, army_slot)) return;
    const int32_t army_cell = army_alive(armies, army_slot)
                                  ? armies.cell[(size_t)army_slot] : -1;
    for (int32_t i = 0; i < task.selected_count; ++i) {
        const int32_t cell = task.selected_cells[(size_t)i];
        if (cell < 0 || (size_t)cell >= view.size()) {
            if (cell == army_cell) set_visited(task, i);
            continue;
        }
        if (view[(size_t)cell] != 0) {
            set_seen(task, i);
        } else if (cell == army_cell && !mask_test(task.seen_mask, i)) {
            set_visited(task, i);
        }
    }
}

void choose_focus(MilitaryCore &core, MilitaryExplorationTask &task, int32_t army_slot) {
    if (task.focus_index >= 0 && task.focus_index < task.selected_count &&
        !task_resolved(task, task.focus_index)) {
        return;
    }
    const MilitaryArmyStore &armies = core.armies();
    const int32_t army_cell = armies.cell[(size_t)army_slot];
    int32_t best = -1;
    int32_t best_distance = std::numeric_limits<int32_t>::max();
    int32_t best_cell = std::numeric_limits<int32_t>::max();
    for (int32_t i = 0; i < task.selected_count; ++i) {
        if (task_resolved(task, i)) continue;
        const int32_t cell = task.selected_cells[(size_t)i];
        const int32_t distance = core.cell_distance(army_cell, cell);
        if (distance < best_distance || (distance == best_distance && cell < best_cell)) {
            best = i;
            best_distance = distance;
            best_cell = cell;
        }
    }
    if (best < 0) {
        task.focus_index = -1;
        return;
    }
    task.focus_index = best;
    task.current_observation_cell = -1;
    task.observer_tries = 0;
    task.reached_observer_cells.fill(-1);
    task.tried_observer_mask = 0;
}

enum PlanAttemptResult : uint8_t {
    PLAN_DONE = 0,
    PLAN_TEMPORARY = 1,
    PLAN_BLOCKED = 2,
};

PlanAttemptResult plan_observer(MilitaryCore &core, MilitaryExplorationTask &task,
                                int32_t army_slot, const MilitaryWorldDigest &digest,
                                int32_t &attempts) {
    const int32_t target = focus_cell(task);
    if (target < 0) return PLAN_BLOCKED;
    ObserverCandidateList candidates;
    build_observer_candidates(core, target, candidates);
    if (candidates.count <= 0) return PLAN_BLOCKED;

    std::array<int32_t, 32> order{};
    int32_t order_count = 0;
    const int32_t army_cell = core.armies().cell[(size_t)army_slot];
    for (int32_t i = 0; i < candidates.count; ++i) {
        const int32_t cell = candidates.cells[(size_t)i];
        if ((task.tried_observer_mask & (1u << (uint32_t)i)) != 0) continue;
        if (has_reached_observer(task, cell)) continue;
        order[(size_t)order_count++] = i;
    }
    std::sort(order.begin(), order.begin() + order_count, [&](int32_t a, int32_t b) {
        const int32_t ca = candidates.cells[(size_t)a];
        const int32_t cb = candidates.cells[(size_t)b];
        const int32_t da = core.cell_distance(army_cell, ca);
        const int32_t db = core.cell_distance(army_cell, cb);
        if (da != db) return da < db;
        return ca < cb;
    });
    if (order_count <= 0) return PLAN_BLOCKED;

    for (int32_t k = 0; k < order_count; ++k) {
        if (attempts >= 2) {
            // There are untried candidates left; leave this task for tomorrow.
            return PLAN_TEMPORARY;
        }
        const int32_t candidate_index = order[(size_t)k];
        const int32_t candidate_cell = candidates.cells[(size_t)candidate_index];
        if (!core.exploration_passable_for(candidate_cell, task.owner_slot, digest)) {
            mark_candidate_tried(task, candidate_index);
            continue;
        }
        std::vector<int32_t> path;
        ++attempts;
        const MilitaryExplorationPathResult result =
            core.find_exploration_path(army_slot, candidate_cell, digest, path);
        if (result == MILITARY_EXPLORATION_PATH_OK) {
            task.last_plan_day = core.last_day();
            task.current_observation_cell = candidate_cell;
            install_path(core, task, army_slot, path, candidate_cell);
            return PLAN_DONE;
        }
        if (result == MILITARY_EXPLORATION_PATH_DAILY_BUDGET_EXHAUSTED) {
            // No A* ran: keep last_plan_day old so this task gets its next
            // planning slot instead of starving behind freshly planned rows.
            --attempts;
            break;
        }
        mark_candidate_tried(task, candidate_index);
    }

    int32_t untried = 0;
    for (int32_t i = 0; i < candidates.count; ++i) {
        if ((task.tried_observer_mask & (1u << (uint32_t)i)) == 0 &&
            !has_reached_observer(task, candidates.cells[(size_t)i])) {
            ++untried;
        }
    }
    if (untried > 0) return PLAN_TEMPORARY;
    return PLAN_BLOCKED;
}

PlanAttemptResult plan_return(MilitaryCore &core, MilitaryExplorationTask &task,
                              int32_t army_slot, const MilitaryWorldDigest &digest,
                              int32_t &attempts) {
    const MilitaryArmyStore &armies = core.armies();
    if (armies.cell[(size_t)army_slot] == task.return_cell) return PLAN_DONE;
    int32_t target = task.return_cell;
    if (target < 0) {
        target = core.nearest_friendly_cell(armies.cell[(size_t)army_slot],
                                            task.owner_slot, digest);
        task.return_cell = target;
        task.return_fallback = 1;
    }
    for (int32_t pass = 0; pass < 2; ++pass) {
        if (target < 0) break;
        if (attempts >= 2) return PLAN_TEMPORARY;
        std::vector<int32_t> path;
        ++attempts;
        const MilitaryExplorationPathResult result =
            core.find_exploration_path(army_slot, target, digest, path);
        if (result == MILITARY_EXPLORATION_PATH_OK) {
            task.return_cell = target;
            task.last_plan_day = core.last_day();
            task.current_observation_cell = -1;
            install_path(core, task, army_slot, path, target);
            if (armies.cell[(size_t)army_slot] == target) return PLAN_DONE;
            return PLAN_DONE;
        }
        if (result == MILITARY_EXPLORATION_PATH_DAILY_BUDGET_EXHAUSTED) {
            --attempts;
            return PLAN_TEMPORARY;
        }
        if (pass == 0) {
            const int32_t friendly =
                core.nearest_friendly_cell(armies.cell[(size_t)army_slot],
                                           task.owner_slot, digest);
            if (friendly < 0 || friendly == target) break;
            target = friendly;
            task.return_fallback = 1;
            continue;
        }
        break;
    }
    return PLAN_BLOCKED;
}

void finish_task(MilitaryCore &core, MilitaryExplorationTask &task,
                 int32_t army_slot, bool no_return) {
    MilitaryArmyStore &armies = core.armies_mutable();
    clear_army_route(armies, army_slot, true);
    armies.area_id[(size_t)army_slot] = -1;
    task.phase = no_return ? (uint8_t)MILITARY_EXPLORATION_FAILED_NO_RETURN
                           : (uint8_t)MILITARY_EXPLORATION_COMPLETE;
    if (no_return) task.result = (uint8_t)MILITARY_EXPLORATION_RESULT_FAILED_NO_RETURN;
    task.pause_reason = (uint8_t)MILITARY_EXPLORATION_PAUSE_NONE;
    task.current_observation_cell = -1;
    task.focus_index = -1;
    task.complete_day = core.last_day();
}

} // namespace

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

bool MilitaryCore::has_exploration_work() const {
    if (!_exploration_trail.empty()) return true;
    for (const MilitaryCommand &cmd : _pending) {
        if (cmd.op == MCMD_ARMY_EXPLORE) return true;
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

void MilitaryCore::record_exploration_trail(int32_t army_slot, int32_t owner_slot, int32_t cell) {
    if (_exploration_observer_slot < 0 || owner_slot != _exploration_observer_slot) return;
    if (cell < 0 || cell >= _terrain.cell_count) return;
    const size_t cells = (size_t)_terrain.cell_count;
    if (_exploration_trail_stamp.size() < cells) _exploration_trail_stamp.resize(cells, 0u);
    if (_exploration_trail_stamp[(size_t)cell] == _exploration_trail_gen) return;
    _exploration_trail_stamp[(size_t)cell] = _exploration_trail_gen;
    _exploration_trail.push_back(cell);
    // Entering a selected target resolves it immediately. `seen` wins over
    // `visited`, exactly like the explored snapshot does on the next day.
    const int32_t row = exploration_row_for_army(army_slot);
    if (row < 0) return;
    MilitaryExplorationTask &task = _explorations[(size_t)row];
    if (!exploration_is_live_for_army(army_slot)) return;
    for (int32_t i = 0; i < task.selected_count; ++i) {
        if (task.selected_cells[(size_t)i] != cell) continue;
        if (!mask_test(task.seen_mask, i)) {
            mask_set(task.visited_mask, i);
            mask_clear(task.blocked_mask, i);
        }
        task.last_progress_day = _last_day;
        break;
    }
}

void MilitaryCore::rebuild_exploration_index() {
    _exploration_by_army.assign((size_t)MILITARY_MAX_ARMIES, -1);
    for (int32_t row = 0; row < (int32_t)_explorations.size(); ++row) {
        MilitaryExplorationTask &task = _explorations[(size_t)row];
        if (!task.active) continue;
        task.row_index = row;
        int32_t army_slot = -1;
        if (!resolve_army(task.army_handle, army_slot)) continue;
        _exploration_by_army[(size_t)army_slot] = (int16_t)row;
    }
}

bool MilitaryCore::can_create_exploration_task(int32_t army_slot) const {
    if (army_slot < 0 || (size_t)army_slot >= _armies.active.size()) return false;
    if (exploration_row_for_army(army_slot) >= 0) return true;
    if ((int32_t)_explorations.size() < MILITARY_MAX_EXPLORATION_TASKS) return true;
    for (const MilitaryExplorationTask &task : _explorations) {
        if (!task.active ||
            task.phase == MILITARY_EXPLORATION_COMPLETE ||
            task.phase == MILITARY_EXPLORATION_FAILED_NO_RETURN) {
            return true;
        }
    }
    return false;
}

void MilitaryCore::cancel_exploration_task(int32_t army_slot, uint8_t result) {
    const int32_t row = exploration_row_for_army(army_slot);
    if (row < 0) return;
    MilitaryExplorationTask &task = _explorations[(size_t)row];
    task.result = result;
    task.phase = (uint8_t)MILITARY_EXPLORATION_COMPLETE;
    task.pause_reason = (uint8_t)MILITARY_EXPLORATION_PAUSE_NONE;
    task.complete_day = _last_day;
    task.focus_index = -1;
    task.current_observation_cell = -1;
    _exploration_by_army[(size_t)army_slot] = -1;
    MilitaryArmyStore &armies = _armies;
    const size_t s = (size_t)army_slot;
    armies.path_len[s] = 0;
    armies.path_cursor[s] = 0;
    armies.target_cell[s] = -1;
    armies.area_id[s] = -1;
    if (armies.mission[s] == (uint8_t)MILITARY_MISSION_EXPLORE) {
        armies.mission[s] = (uint8_t)MILITARY_MISSION_NONE;
    }
}

bool MilitaryCore::create_exploration_task(const MilitaryCommand &cmd, int64_t day,
                                           int32_t army_slot, int32_t owner_slot) {
    if (!army_alive(_armies, army_slot)) return false;
    if (cmd.cells.empty() ||
        cmd.cells.size() > (size_t)MILITARY_MAX_EXPLORATION_CELLS) return false;

    int32_t row = exploration_row_for_army(army_slot);
    if (row < 0) {
        for (int32_t i = 0; i < (int32_t)_explorations.size(); ++i) {
            if (!_explorations[(size_t)i].active) {
                row = i;
                break;
            }
        }
    }
    if (row < 0) {
        // Reclaim the oldest terminal row only. A live task is never evicted.
        int64_t oldest_day = std::numeric_limits<int64_t>::max();
        for (int32_t i = 0; i < (int32_t)_explorations.size(); ++i) {
            const MilitaryExplorationTask &task = _explorations[(size_t)i];
            if (task.phase != MILITARY_EXPLORATION_COMPLETE &&
                task.phase != MILITARY_EXPLORATION_FAILED_NO_RETURN) continue;
            const int64_t completed = task.complete_day >= 0 ? task.complete_day : 0;
            if (completed < oldest_day ||
                (completed == oldest_day && (row < 0 || i < row))) {
                oldest_day = completed;
                row = i;
            }
        }
    }
    if (row < 0 && (int32_t)_explorations.size() < MILITARY_MAX_EXPLORATION_TASKS) {
        row = (int32_t)_explorations.size();
        _explorations.emplace_back();
    }
    if (row < 0) return false;

    MilitaryExplorationTask task;
    task.active = true;
    task.row_index = row;
    task.army_handle = army_handle(army_slot);
    task.owner_slot = owner_slot;
    task.owner_handle = country_handle_for_slot(owner_slot);
    task.origin_cell = _armies.cell[(size_t)army_slot];
    task.return_cell = task.origin_cell;
    task.anchor_cell = cmd.cell;
    task.radius = cmd.radius;
    task.selected_count = (int32_t)cmd.cells.size();
    for (int32_t i = 0; i < task.selected_count; ++i) {
        task.selected_cells[(size_t)i] = cmd.cells[(size_t)i];
    }
    task.phase = (uint8_t)MILITARY_EXPLORATION_ACTIVE;
    task.resume_phase = (uint8_t)MILITARY_EXPLORATION_ACTIVE;
    task.started_day = day;
    task.last_progress_day = day;
    _explorations[(size_t)row] = task;
    _exploration_by_army[(size_t)army_slot] = (int16_t)row;

    const size_t s = (size_t)army_slot;
    _armies.path_len[s] = 0;
    _armies.path_cursor[s] = 0;
    _armies.target_cell[s] = -1;
    _armies.area_id[s] = -1;
    _armies.mission[s] = (uint8_t)MILITARY_MISSION_EXPLORE;
    if (_armies.stance[s] == (uint8_t)MILITARY_STANCE_RETREAT) {
        _armies.stance[s] = (uint8_t)MILITARY_STANCE_HOLD;
    }
    return true;
}

void MilitaryCore::pause_exploration_for_battle(int32_t army_slot) {
    const int32_t row = exploration_row_for_army(army_slot);
    if (row < 0) return;
    MilitaryExplorationTask &task = _explorations[(size_t)row];
    if (task.phase == MILITARY_EXPLORATION_COMPLETE ||
        task.phase == MILITARY_EXPLORATION_FAILED_NO_RETURN ||
        task.phase == MILITARY_EXPLORATION_PAUSED_BATTLE) {
        return;
    }
    task.resume_phase = task.phase;
    task.phase = (uint8_t)MILITARY_EXPLORATION_PAUSED_BATTLE;
    task.pause_reason = (uint8_t)MILITARY_EXPLORATION_PAUSE_ENGAGEMENT;
    task.last_progress_day = _last_day;
    MilitaryArmyStore &armies = _armies;
    const size_t s = (size_t)army_slot;
    armies.path_len[s] = 0;
    armies.path_cursor[s] = 0;
    armies.target_cell[s] = -1;
    armies.move_points_q16[s] = 0;
    armies.mission[s] = (uint8_t)MILITARY_MISSION_EXPLORE;
}

void MilitaryCore::settle_exploration_day() {
    for (int32_t row = 0; row < (int32_t)_explorations.size(); ++row) {
        MilitaryExplorationTask &task = _explorations[(size_t)row];
        if (!task.active) continue;
        int32_t army_slot = -1;
        if (!resolve_army(task.army_handle, army_slot)) {
            // A dangling task row must not survive as "active" without a
            // resolvable formation. Retire it transactionally and drop the
            // derived index entry; a later save then has a terminal row.
            task.active = false;
            task.phase = (uint8_t)MILITARY_EXPLORATION_COMPLETE;
            task.result = (uint8_t)MILITARY_EXPLORATION_RESULT_CANCELLED;
            task.pause_reason = (uint8_t)MILITARY_EXPLORATION_PAUSE_NONE;
            task.current_observation_cell = -1;
            task.focus_index = -1;
            task.complete_day = std::max(task.started_day, _last_day);
            for (int16_t &indexed : _exploration_by_army) {
                if (indexed == row) indexed = -1;
            }
            continue;
        }
        if (task.phase != MILITARY_EXPLORATION_PAUSED_BATTLE) continue;
        const size_t s = (size_t)army_slot;
        if (_armies.engagement[s] >= 0) continue;
        // A battle-produced RETREAT is not a player stance (an explicit stance
        // command cancels exploration). After the engagement has closed, let
        // the auto-exploration controller return to HOLD and resume; otherwise
        // the task would wait forever for a recovery step no other system owns.
        if (_armies.stance[s] == (uint8_t)MILITARY_STANCE_RETREAT) {
            _armies.stance[s] = (uint8_t)MILITARY_STANCE_HOLD;
        } else if (_armies.stance[s] == (uint8_t)MILITARY_STANCE_EMBARKED) {
            continue;
        }
        task.phase = task.resume_phase == (uint8_t)MILITARY_EXPLORATION_RETURNING
                         ? (uint8_t)MILITARY_EXPLORATION_RETURNING
                         : (uint8_t)MILITARY_EXPLORATION_ACTIVE;
        task.pause_reason = (uint8_t)MILITARY_EXPLORATION_PAUSE_NONE;
        task.last_progress_day = _last_day;
        task.last_plan_day = -1;
    }
}

void MilitaryCore::prepare_exploration_day(const MilitaryWorldDigest &digest) {
    if (_explorations.empty()) return;
    static thread_local std::vector<int32_t> eligible;
    static thread_local std::vector<int32_t> slots;
    eligible.clear();
    slots.assign(std::max<size_t>(_policies.size(), 1), 0);

    for (int32_t row = 0; row < (int32_t)_explorations.size(); ++row) {
        MilitaryExplorationTask &task = _explorations[(size_t)row];
        if (!task.active) continue;
        if (task.phase == MILITARY_EXPLORATION_COMPLETE ||
            task.phase == MILITARY_EXPLORATION_FAILED_NO_RETURN) continue;
        int32_t army_slot = -1;
        if (!resolve_army(task.army_handle, army_slot)) {
            // Same fail-closed retirement as settle_exploration_day(): never
            // leave an active row without an army behind.
            task.active = false;
            task.phase = (uint8_t)MILITARY_EXPLORATION_COMPLETE;
            task.result = (uint8_t)MILITARY_EXPLORATION_RESULT_CANCELLED;
            task.pause_reason = (uint8_t)MILITARY_EXPLORATION_PAUSE_NONE;
            task.current_observation_cell = -1;
            task.focus_index = -1;
            task.complete_day = std::max(task.started_day, _last_day);
            for (int16_t &indexed : _exploration_by_army) {
                if (indexed == row) indexed = -1;
            }
            continue;
        }
        const size_t s = (size_t)army_slot;
        if (task.phase == MILITARY_EXPLORATION_PAUSED_BATTLE) {
            if (_armies.engagement[s] >= 0 ||
                _armies.stance[s] == (uint8_t)MILITARY_STANCE_EMBARKED) {
                continue;
            }
            if (_armies.stance[s] == (uint8_t)MILITARY_STANCE_RETREAT) {
                _armies.stance[s] = (uint8_t)MILITARY_STANCE_HOLD;
            }
            task.phase = task.resume_phase == (uint8_t)MILITARY_EXPLORATION_RETURNING
                             ? (uint8_t)MILITARY_EXPLORATION_RETURNING
                             : (uint8_t)MILITARY_EXPLORATION_ACTIVE;
            task.pause_reason = (uint8_t)MILITARY_EXPLORATION_PAUSE_NONE;
            task.last_plan_day = -1;
        }
        if (_armies.engagement[s] >= 0) {
            pause_exploration_for_battle(army_slot);
            continue;
        }

        refresh_seen_from_view(*this, task);
        if (task.phase == MILITARY_EXPLORATION_ACTIVE) {
            mark_observation_reached(*this, task, army_slot);
        }
        if (task.phase == MILITARY_EXPLORATION_ACTIVE && all_resolved(task)) {
            begin_return(task, _armies, army_slot);
        }
        if (task.phase == MILITARY_EXPLORATION_ACTIVE) {
            choose_focus(*this, task, army_slot);
            if (task.focus_index < 0) {
                begin_return(task, _armies, army_slot);
            }
        }
        if (task.phase == MILITARY_EXPLORATION_RETURNING) {
            if (_armies.cell[s] == task.return_cell) {
                finish_task(*this, task, army_slot, false);
                continue;
            }
            if (route_is_valid(*this, task, digest)) continue;
            clear_army_route(_armies, army_slot, false);
        } else if (task.phase == MILITARY_EXPLORATION_ACTIVE) {
            if (route_is_valid(*this, task, digest)) continue;
            clear_army_route(_armies, army_slot, false);
        } else {
            continue;
        }
        eligible.push_back(row);
    }

    std::sort(eligible.begin(), eligible.end(), [this](int32_t a, int32_t b) {
        const MilitaryExplorationTask &ta = _explorations[(size_t)a];
        const MilitaryExplorationTask &tb = _explorations[(size_t)b];
        if (ta.last_plan_day != tb.last_plan_day) return ta.last_plan_day < tb.last_plan_day;
        return ta.row_index < tb.row_index;
    });

    for (int32_t row : eligible) {
        MilitaryExplorationTask &task = _explorations[(size_t)row];
        if (!task.active) continue;
        if (task.phase != MILITARY_EXPLORATION_ACTIVE &&
            task.phase != MILITARY_EXPLORATION_RETURNING) continue;
        int32_t army_slot = -1;
        if (!resolve_army(task.army_handle, army_slot)) continue;
        if (task.owner_slot < 0 || (size_t)task.owner_slot >= slots.size()) continue;
        if (slots[(size_t)task.owner_slot] >= MILITARY_EXPLORATION_PLANS_PER_DAY) continue;
        ++slots[(size_t)task.owner_slot];
        int32_t attempts = 0;
        if (task.phase == MILITARY_EXPLORATION_ACTIVE) {
            const PlanAttemptResult result = plan_observer(*this, task, army_slot, digest, attempts);
            if (result == PLAN_BLOCKED && task.focus_index >= 0) {
                set_blocked(task, task.focus_index);
                if (all_resolved(task)) {
                    begin_return(task, _armies, army_slot);
                }
            }
            if (attempts > 0) task.last_plan_day = _last_day;
        } else {
            MilitaryArmyStore &armies = _armies;
            if (armies.cell[(size_t)army_slot] == task.return_cell) {
                finish_task(*this, task, army_slot, false);
                continue;
            }
            const PlanAttemptResult result = plan_return(*this, task, army_slot, digest, attempts);
            if (attempts > 0) task.last_plan_day = _last_day;
            if (result == PLAN_BLOCKED) {
                finish_task(*this, task, army_slot, true);
            }
        }
    }
}

} // namespace pk
