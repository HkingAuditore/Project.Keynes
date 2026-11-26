#include "military_core_naval_selftest.inc"
// --- 11. player auto-exploration
int32_t make_exploration_army(MilitaryCore &core, int32_t owner, int32_t cell,
                              int64_t heads = 1000) {
    const int32_t army = core.create_army(owner, cell);
    if (army < 0) return -1;
    const int32_t lot = core.lot_find_or_create(
        MILITARY_LOT_ARMY, army, owner, 0, 256);
    if (lot < 0) return -1;
    core._lots.count[(size_t)lot] = heads;
    core.refresh_army_cache(army);
    return army;
}

bool seed_exploration_task(MilitaryCore &core, int32_t army, int64_t day,
                           int32_t anchor, std::vector<int32_t> cells,
                           int32_t radius = 2) {
    MilitaryCommand command;
    command.army = core.army_handle(army);
    command.cell = anchor;
    command.radius = radius;
    command.cells = std::move(cells);
    std::sort(command.cells.begin(), command.cells.end());
    command.cells.erase(std::unique(command.cells.begin(), command.cells.end()),
                        command.cells.end());
    const int32_t owner = core._armies.owner_slot[(size_t)army];
    return core.create_exploration_task(command, day, army, owner);
}

int32_t blocked_exploration_targets(const MilitaryExplorationTask &task) {
    int32_t blocked = 0;
    for (int32_t index = 0; index < task.selected_count; ++index) {
        const size_t word = (size_t)(index >> 6);
        if ((task.blocked_mask[word] & (1ull << (uint32_t)(index & 63))) != 0)
            ++blocked;
    }
    return blocked;
}

uint16_t read_u16_le(const std::vector<uint8_t> &bytes, size_t at) {
    return (uint16_t)((uint16_t)bytes[at] |
                      ((uint16_t)bytes[at + 1] << 8));
}

uint32_t read_u32_le(const std::vector<uint8_t> &bytes, size_t at) {
    uint32_t value = 0;
    for (int32_t i = 0; i < 4; ++i)
        value |= (uint32_t)bytes[at + (size_t)i] << (8 * i);
    return value;
}

void write_u32_le(std::vector<uint8_t> &bytes, size_t at, uint32_t value) {
    for (int32_t i = 0; i < 4; ++i)
        bytes[at + (size_t)i] = (uint8_t)(value >> (8 * i));
}

void write_u64_le(std::vector<uint8_t> &bytes, size_t at, uint64_t value) {
    for (int32_t i = 0; i < 8; ++i)
        bytes[at + (size_t)i] = (uint8_t)(value >> (8 * i));
}

// PKMI has a fixed 44-byte header, then [u16 id][u32 length][payload].
bool pkmi_section_span(const std::vector<uint8_t> &bytes, uint16_t wanted,
                       size_t &start, size_t &length) {
    size_t at = 44;
    while (at + 6 <= bytes.size()) {
        const uint16_t id = read_u16_le(bytes, at);
        if (id == 0xFFFFu) return false;
        const uint32_t size = read_u32_le(bytes, at + 2);
        if ((size_t)size > bytes.size() - at - 6) return false;
        if (id == wanted) {
            start = at;
            length = (size_t)size;
            return true;
        }
        at += 6 + (size_t)size;
    }
    return false;
}

// Section 23 starts with a u32 row count, followed by fixed-layout rows. A
// one-cell row is 210 bytes; keeping the arithmetic here makes the malformed
// stream cases readable instead of a wall of magic offsets.
constexpr size_t kPkmiExplorationRowHeader = 45;
constexpr size_t kPkmiExplorationMasksAt = kPkmiExplorationRowHeader + 4;
constexpr size_t kPkmiExplorationPhaseAt = kPkmiExplorationMasksAt + 96;
constexpr size_t kPkmiExplorationRowBytes = 210;

bool test_exploration(const MilitaryTerrainInput &t, std::string &report) {
    // Command -> task, mission preservation, actual-cell trail, then a frozen
    // explored snapshot resolves the target and the formation returns home.
    {
        Sim sim;
        std::string error;
        ST_CHECK(sim.init(t, 7341), "exploration: sim init");
        const int32_t A = cell_at(5, 5);
        const int32_t B = cell_at(9, 5);
        const int32_t army = make_exploration_army(sim.core, 0, A);
        ST_CHECK(army >= 0, "exploration: army created");
        std::vector<uint8_t> explored((size_t)t.cell_count, 0);
        sim.core.set_exploration_view(0, explored.data(), explored.size(),
                                      sim.day, 1);
        MilitaryCommand command;
        command.army = sim.core.army_handle(army);
        command.cell = B;
        command.radius = 2;
        command.cells = {B};
        ST_CHECK(sim.submit(MCMD_ARMY_EXPLORE, 0, command),
                 "exploration: army.explore accepted");
        ST_STEP(sim, sim.day + 1);
        const MilitaryExplorationTask *task =
            sim.core.exploration_task_for_army(army);
        ST_CHECK(task != nullptr && task->active,
                 "exploration: D-day command created a task");
        ST_CHECK(sim.core.armies().mission[(size_t)army] ==
                     (uint8_t)MILITARY_MISSION_EXPLORE,
                 "exploration: mission survives path installation");
        ST_CHECK(sim.core.has_exploration_work(),
                 "exploration: active task reports work");
        const std::vector<int32_t> &trail = sim.core.exploration_trail(0);
        ST_CHECK(!trail.empty(),
                 "exploration: movement records every entered cell");
        bool trail_valid = true;
        for (int32_t cell : trail)
            trail_valid = trail_valid && cell >= 0 && cell < t.cell_count;
        ST_CHECK(trail_valid, "exploration: trail cells stay in bounds");

        explored[(size_t)B] = 1;
        sim.core.clear_exploration_trail(0);
        sim.core.set_exploration_view(0, explored.data(), explored.size(),
                                      sim.day, 2);
        bool completed = false;
        for (int32_t day = 0; day < 12 && !completed; ++day) {
            ST_STEP(sim, sim.day + 1);
            task = sim.core.exploration_task_for_army(army);
            completed = task != nullptr &&
                        task->phase == MILITARY_EXPLORATION_COMPLETE;
        }
        task = sim.core.exploration_task_for_army(army);
        ST_CHECK(completed && task != nullptr,
                 "exploration: resolved target returns and completes");
        ST_CHECK(task->result == MILITARY_EXPLORATION_RESULT_ALL_SEEN,
                 "exploration: completed result is ALL_SEEN");
        ST_CHECK(sim.core.armies().mission[(size_t)army] ==
                     (uint8_t)MILITARY_MISSION_NONE,
                 "exploration: completion retires the mission");
        sim.core.clear_exploration_trail(0);
        ST_CHECK(!sim.core.has_exploration_work(),
                 "exploration: completed task reports no work");

        // Player-only gate: the observer country can explore, a foreign country
        // cannot create a task even with an otherwise valid command.
        const int32_t foreign_army = make_exploration_army(sim.core, 1, cell_at(3, 3));
        ST_CHECK(foreign_army >= 0, "exploration: foreign army fixture");
        MilitaryCommand foreign_command;
        foreign_command.army = sim.core.army_handle(foreign_army);
        foreign_command.cell = cell_at(7, 3);
        foreign_command.radius = 2;
        foreign_command.cells = {cell_at(7, 3)};
        ST_CHECK(sim.submit(MCMD_ARMY_EXPLORE, 1, foreign_command),
                 "exploration: foreign command is structurally accepted");
        ST_STEP(sim, sim.day + 1);
        ST_CHECK(sim.core.exploration_task_for_army(foreign_army) == nullptr,
                 "exploration: observer-only gate rejects foreign task creation");

        // Add one live task before the v4 round-trip.
        const int32_t C = cell_at(3, 4);
        const int32_t D = cell_at(8, 4);
        const int32_t active_army = make_exploration_army(sim.core, 0, C);
        ST_CHECK(active_army >= 0, "exploration: save fixture army");
        MilitaryCommand save_command;
        save_command.army = sim.core.army_handle(active_army);
        save_command.cell = D;
        save_command.radius = 2;
        save_command.cells = {D};
        ST_CHECK(sim.submit(MCMD_ARMY_EXPLORE, 0, save_command),
                 "exploration: save fixture command");
        ST_STEP(sim, sim.day + 1);
        const std::vector<uint8_t> bytes = sim.core.encode();
        size_t section_start = 0, section_length = 0;
        ST_CHECK(pkmi_section_span(bytes, 23, section_start, section_length),
                 "exploration: PKMI v4 writes section 23");
        MilitaryCore copy;
        ST_CHECK(copy.configure(make_catalog(), 7341, error) &&
                     copy.set_terrain(t, error) &&
                     copy.restore(bytes.data(), bytes.size(), error),
                 "exploration: PKMI v4 active task restores");
        ST_CHECK(copy.state_hash() == sim.core.state_hash(),
                 "exploration: restore preserves state_hash");
        ST_CHECK(copy.encode() == bytes,
                 "exploration: v4 restore re-encodes byte-identically");
        ST_CHECK(copy.exploration_task_for_army(active_army) != nullptr &&
                     copy.exploration_task_for_army(active_army)->selected_count == 1,
                 "exploration: restored task rebuilds its army index");

        std::vector<uint8_t> old_version = bytes;
        old_version[4] = 3;
        ST_CHECK(!copy.restore(old_version.data(), old_version.size(), error) &&
                     error == (std::string("pkmi_version_mismatch_expected_") + std::to_string(PKMI_VERSION)),
                 "exploration: PKMI v3 is explicitly refused");
        std::vector<uint8_t> missing = bytes;
        missing.erase(missing.begin() + (ptrdiff_t)section_start,
                      missing.begin() +
                          (ptrdiff_t)(section_start + 6 + section_length));
        MilitaryCore missing_copy;
        ST_CHECK(missing_copy.configure(make_catalog(), 7341, error) &&
                     missing_copy.set_terrain(t, error) &&
                     !missing_copy.restore(missing.data(), missing.size(), error) &&
                     error == "pkmi_exploration_section_missing",
                 "exploration: missing section 23 is refused");

        MilitaryCore empty;
        ST_CHECK(empty.configure(make_catalog(), 7341, error) &&
                     empty.set_terrain(t, error),
                 "exploration: empty save fixture");
        const std::vector<uint8_t> empty_bytes = empty.encode();
        size_t empty_start = 0, empty_length = 0;
        ST_CHECK(pkmi_section_span(empty_bytes, 23, empty_start, empty_length) &&
                     empty_length == 4,
                 "exploration: empty task table still writes section 23");
        ST_CHECK(empty.restore(empty_bytes.data(), empty_bytes.size(), error),
                 "exploration: empty section 23 round-trips");
    }

    // An unexpected control change after planning pauses the task on the border,
    // never converts it into a manual MOVE/NONE mission.
    {
        Sim sim;
        ST_CHECK(sim.init(t, 7342), "exploration pause: sim init");
        const int32_t A = cell_at(5, 5);
        const int32_t enemy = cell_at(6, 5);
        const int32_t army = make_exploration_army(sim.core, 0, A);
        ST_CHECK(army >= 0 &&
                     seed_exploration_task(
                         sim.core, army, sim.day, cell_at(9, 5),
                         {cell_at(9, 5)}),
                 "exploration pause: task seeded");
        sim.core._last_day = sim.day;
        sim.core._last_digest = sim.dg;
        sim.core._cell_controller.assign((size_t)t.cell_count, -1);
        sim.dg.cell_owner_slot[(size_t)enemy] = 1;
        MilitaryWar war;
        war.id = 9001;
        war.attacker_slot = 0;
        war.defender_slot = 1;
        war.attacker_handle = handle_for(0);
        war.defender_handle = handle_for(1);
        war.start_day = sim.day;
        war.active = 1;
        sim.core._wars.push_back(war);
        MilitaryArmyStore &armies = sim.core._armies;
        sim.core._path_cells.clear();
        sim.core._path_cells.push_back(enemy);
        armies.path_offset[(size_t)army] = 0;
        armies.path_len[(size_t)army] = 1;
        armies.path_cursor[(size_t)army] = 0;
        armies.move_points_q16[(size_t)army] = 0;
        armies.cached_speed_q16[(size_t)army] = MILITARY_Q16;
        armies.stance[(size_t)army] = (uint8_t)MILITARY_STANCE_ADVANCE;
        armies.mission[(size_t)army] = (uint8_t)MILITARY_MISSION_EXPLORE;
        sim.core.run_movement(sim.dg);
        const MilitaryExplorationTask *task =
            sim.core.exploration_task_for_army(army);
        ST_CHECK(task != nullptr &&
                     task->phase == MILITARY_EXPLORATION_ACTIVE &&
                     armies.cell[(size_t)army] == A &&
                     armies.path_len[(size_t)army] == 0,
                 "exploration pause: stale foreign route is cleared, not entered");
        ST_CHECK(armies.mission[(size_t)army] ==
                     (uint8_t)MILITARY_MISSION_EXPLORE &&
                     armies.path_len[(size_t)army] == 0,
                 "exploration pause: mission kept while the stale route is dropped");

        // A battle that is already open pauses the task, and a battle-produced
        // RETREAT recovers to HOLD after the engagement closes.
        armies.engagement[(size_t)army] = 77;
        sim.core.prepare_exploration_day(sim.dg);
        task = sim.core.exploration_task_for_army(army);
        ST_CHECK(task != nullptr &&
                     task->phase == MILITARY_EXPLORATION_PAUSED_BATTLE &&
                     task->pause_reason == MILITARY_EXPLORATION_PAUSE_ENGAGEMENT,
                 "exploration pause: an open engagement pauses the task");
        armies.engagement[(size_t)army] = -1;
        armies.stance[(size_t)army] = (uint8_t)MILITARY_STANCE_RETREAT;
        sim.core.settle_exploration_day();
        task = sim.core.exploration_task_for_army(army);
        ST_CHECK(task != nullptr &&
                     task->phase == MILITARY_EXPLORATION_ACTIVE &&
                     armies.stance[(size_t)army] ==
                         (uint8_t)MILITARY_STANCE_HOLD,
                 "exploration pause: task resumes after battle and retreat");

        sim.core._path_daily_requests.assign(1, 0);
        sim.core._exploration_daily_path_requests.assign(1, 0);
        std::vector<int32_t> path;
        ST_CHECK(sim.core.find_exploration_path(army, enemy, sim.dg, path) ==
                     MILITARY_EXPLORATION_PATH_UNREACHABLE,
                 "exploration pause: war never opens a path into foreign land");
        ST_CHECK(sim.core._path_daily_requests[0] == 0 &&
                     sim.core._exploration_daily_path_requests[0] == 0,
                 "exploration pause: refused foreign target spends no A*");
        sim.core._exploration_daily_path_requests[0] = 16;
        ST_CHECK(sim.core.find_exploration_path(army, cell_at(9, 5), sim.dg,
                                                path) ==
                     MILITARY_EXPLORATION_PATH_DAILY_BUDGET_EXHAUSTED,
                 "exploration pause: per-country A* ceiling is explicit");
        sim.core._exploration_daily_path_requests[0] = 0;
        sim.core._path_daily_requests[0] = 16;
        ST_CHECK(sim.core.find_exploration_path(army, cell_at(9, 5), sim.dg,
                                                path) ==
                     MILITARY_EXPLORATION_PATH_DAILY_BUDGET_EXHAUSTED,
                 "exploration pause: area-control reserve is preserved");
    }

    // Three reached observers that still cannot reveal an impassable target
    // mark exactly that target unobservable, then the task returns.
    {
        MilitaryTerrainInput water = t;
        const int32_t target = cell_at(10, 10);
        water.is_water[(size_t)target] = 1;
        Sim sim;
        ST_CHECK(sim.init(water, 7343), "exploration observers: sim init");
        const int32_t army =
            make_exploration_army(sim.core, 0, cell_at(8, 10));
        ST_CHECK(army >= 0 &&
                     seed_exploration_task(sim.core, army, sim.day, target,
                                           {target}),
                 "exploration observers: water target seeded");
        std::vector<uint8_t> explored((size_t)t.cell_count, 0);
        sim.core.set_exploration_view(0, explored.data(), explored.size(),
                                      sim.day, 1);
        bool terminal = false;
        for (int32_t day = 0; day < 30 && !terminal; ++day) {
            ST_STEP(sim, sim.day + 1);
            const MilitaryExplorationTask *current =
                sim.core.exploration_task_for_army(army);
            terminal = current != nullptr &&
                       (current->phase == MILITARY_EXPLORATION_COMPLETE ||
                        current->phase == MILITARY_EXPLORATION_FAILED_NO_RETURN);
        }
        const MilitaryExplorationTask *task =
            sim.core.exploration_task_for_army(army);
        ST_CHECK(terminal && task != nullptr &&
                     task->phase == MILITARY_EXPLORATION_COMPLETE &&
                     task->result ==
                         MILITARY_EXPLORATION_RESULT_SEEN_WITH_UNOBSERVABLE &&
                     blocked_exploration_targets(*task) == 1,
                 "exploration observers: three failed observers block the target");
    }

    // A stale origin falls back to the nearest friendly cell. With no friendly
    // cell left at all the task fails closed instead of crossing foreign land.
    {
        Sim fallback;
        ST_CHECK(fallback.init(t, 7345), "exploration return: fallback init");
        const int32_t A = cell_at(5, 5);
        const int32_t B = cell_at(9, 5);
        const int32_t foreign = cell_at(15, 5);
        const int32_t army = make_exploration_army(fallback.core, 0, A);
        ST_CHECK(army >= 0, "exploration return: fallback army");
        std::vector<uint8_t> explored((size_t)t.cell_count, 0);
        explored[(size_t)B] = 1;
        fallback.core.set_exploration_view(0, explored.data(), explored.size(),
                                           fallback.day, 1);
        ST_CHECK(seed_exploration_task(fallback.core, army, fallback.day, B, {B}),
                 "exploration return: fallback task");
        MilitaryExplorationTask *fallback_task = const_cast<MilitaryExplorationTask *>(
            fallback.core.exploration_task_for_army(army));
        fallback_task->origin_cell = foreign;
        fallback_task->return_cell = foreign;
        for (int32_t d = 0; d < 12; ++d) {
            const MilitaryExplorationTask *current =
                fallback.core.exploration_task_for_army(army);
            if (current != nullptr &&
                current->phase == MILITARY_EXPLORATION_COMPLETE) break;
            ST_STEP(fallback, fallback.day + 1);
        }
        const MilitaryExplorationTask *task =
            fallback.core.exploration_task_for_army(army);
        ST_CHECK(task != nullptr &&
                     task->phase == MILITARY_EXPLORATION_COMPLETE &&
                     task->result == MILITARY_EXPLORATION_RESULT_ALL_SEEN &&
                     task->return_fallback == 1,
                 "exploration return: invalid origin falls back to friendly");

        Sim no_return;
        ST_CHECK(no_return.init(t, 7346), "exploration return: no-return init");
        const int32_t no_return_army =
            make_exploration_army(no_return.core, 0, A);
        ST_CHECK(no_return_army >= 0, "exploration return: no-return army");
        std::vector<uint8_t> no_return_view((size_t)t.cell_count, 0);
        no_return_view[(size_t)B] = 1;
        no_return.core.set_exploration_view(
            0, no_return_view.data(), no_return_view.size(), no_return.day, 1);
        ST_CHECK(seed_exploration_task(no_return.core, no_return_army,
                                       no_return.day, B, {B}),
                 "exploration return: no-return task");
        MilitaryExplorationTask *no_return_task =
            const_cast<MilitaryExplorationTask *>(
                no_return.core.exploration_task_for_army(no_return_army));
        no_return_task->origin_cell = foreign;
        no_return_task->return_cell = foreign;
        // Remove every friendly cell from the digest. The formation may stand
        // on an edge but must not route through it to reach a foreign "home".
        std::fill(no_return.dg.cell_owner_slot.begin(),
                  no_return.dg.cell_owner_slot.end(), 1);
        no_return.core._cell_controller.assign((size_t)t.cell_count, -1);
        ST_STEP(no_return, no_return.day + 1);
        no_return_task = const_cast<MilitaryExplorationTask *>(
            no_return.core.exploration_task_for_army(no_return_army));
        ST_CHECK(no_return_task != nullptr &&
                     no_return_task->phase ==
                         MILITARY_EXPLORATION_FAILED_NO_RETURN &&
                     no_return_task->result ==
                         MILITARY_EXPLORATION_RESULT_FAILED_NO_RETURN &&
                     no_return.core.armies().mission[(size_t)no_return_army] ==
                         (uint8_t)MILITARY_MISSION_NONE,
                 "exploration return: no safe route fails without trespassing");
    }

    // A saturated table reuses only a retired row. This also covers the
    // inactive rows created by destroy_army, which must not wedge acceptance.
    {
        Sim sim;
        ST_CHECK(sim.init(t, 7347), "exploration capacity: sim init");
        const int32_t army =
            make_exploration_army(sim.core, 0, cell_at(5, 5));
        ST_CHECK(army >= 0, "exploration capacity: army");
        sim.core._explorations.assign(MILITARY_MAX_EXPLORATION_TASKS,
                                      MilitaryExplorationTask{});
        for (int32_t row = 0; row < MILITARY_MAX_EXPLORATION_TASKS; ++row) {
            sim.core._explorations[(size_t)row].active = true;
            sim.core._explorations[(size_t)row].row_index = row;
        }
        ST_CHECK(!sim.core.can_create_exploration_task(army),
                 "exploration capacity: a live full table rejects a new task");
        sim.core._explorations[7].active = false;
        ST_CHECK(sim.core.can_create_exploration_task(army),
                 "exploration capacity: a retired row is reusable");
        ST_CHECK(seed_exploration_task(sim.core, army, sim.day,
                                       cell_at(9, 5), {cell_at(9, 5)}),
                 "exploration capacity: retired row accepted");
        const MilitaryExplorationTask *task =
            sim.core.exploration_task_for_army(army);
        ST_CHECK(task != nullptr && task->row_index == 7,
                 "exploration capacity: the retired row is reused in place");
    }

    // Cancellation owners clear the derived index; destroy retires the row so a
    // restored save can never reference a dead formation.
    {
        Sim sim;
        ST_CHECK(sim.init(t, 7344), "exploration cancel: sim init");
        const int32_t army =
            make_exploration_army(sim.core, 0, cell_at(5, 5));
        ST_CHECK(army >= 0, "exploration cancel: army");
        const int32_t target = cell_at(9, 5);
        ST_CHECK(seed_exploration_task(sim.core, army, sim.day, target, {target}),
                 "exploration cancel: task");
        MilitaryCommand stop;
        stop.army = sim.core.army_handle(army);
        ST_CHECK(sim.submit(MCMD_ARMY_STOP, 0, stop),
                 "exploration cancel: stop accepted");
        ST_STEP(sim, sim.day + 1);
        ST_CHECK(sim.core.exploration_task_for_army(army) == nullptr,
                 "exploration cancel: stop clears the army index");
        ST_CHECK(!sim.core.has_exploration_work(),
                 "exploration cancel: cancelled task has no active work");
        const uint64_t army_handle = sim.core.army_handle(army);
        ST_CHECK(seed_exploration_task(sim.core, army, sim.day, target, {target}),
                 "exploration cancel: task reseeded");
        sim.core.destroy_army(army);
        bool dangling = false;
        for (const MilitaryExplorationTask &row : sim.core._explorations) {
            if (row.active && row.army_handle == army_handle)
                dangling = true;
        }
        ST_CHECK(!dangling && sim.core.exploration_task_for_army(army) == nullptr,
                 "exploration cancel: destroy retires rows and index");
    }

    // Every actually entered cell enters the trail exactly once. Clearing the
    // trail starts a new generation without leaking the previous stamps.
    {
        Sim sim;
        ST_CHECK(sim.init(t, 7350), "exploration trail: sim init");
        const int32_t A = cell_at(5, 5);
        const int32_t B = cell_at(12, 5);
        const int32_t army = make_exploration_army(sim.core, 0, A);
        std::vector<uint8_t> explored((size_t)t.cell_count, 0);
        sim.core.set_exploration_view(0, explored.data(), explored.size(),
                                      sim.day, 1);
        ST_CHECK(seed_exploration_task(sim.core, army, sim.day, B, {B}),
                 "exploration trail: task seeded");
        ST_STEP(sim, sim.day + 3);
        std::vector<int32_t> trail = sim.core.exploration_trail(0);
        std::vector<int32_t> sorted = trail;
        std::sort(sorted.begin(), sorted.end());
        const size_t unique = (size_t)(std::unique(sorted.begin(), sorted.end()) -
                                       sorted.begin());
        ST_CHECK(trail.size() >= 2 && unique == trail.size(),
                 "exploration trail: multi-day movement records unique cells");
        sim.core.clear_exploration_trail(0);
        ST_CHECK(sim.core.exploration_trail(0).empty(),
                 "exploration trail: clear drops the accumulated trail");
    }

    // PKMI v4 round-trips every live/terminal phase, not only ACTIVE. A save
    // taken while paused and restored into a fresh core must keep running.
    {
        Sim sim;
        ST_CHECK(sim.init(t, 7351), "exploration phases: sim init");
        const int32_t A = cell_at(4, 4);
        const int32_t B = cell_at(10, 4);
        const int32_t C = cell_at(4, 9);
        const int32_t D = cell_at(10, 9);
        const int32_t E = cell_at(4, 14);
        const int32_t F = cell_at(10, 14);
        const int32_t paused_army = make_exploration_army(sim.core, 0, A);
        const int32_t returning_army = make_exploration_army(sim.core, 0, C);
        const int32_t completed_army = make_exploration_army(sim.core, 0, E);
        ST_CHECK(paused_army >= 0 && returning_army >= 0 && completed_army >= 0,
                 "exploration phases: armies created");
        std::vector<uint8_t> explored((size_t)t.cell_count, 0);
        sim.core.set_exploration_view(0, explored.data(), explored.size(),
                                      sim.day, 1);
        ST_CHECK(seed_exploration_task(sim.core, paused_army, sim.day, B, {B}) &&
                     seed_exploration_task(sim.core, returning_army, sim.day, D, {D}) &&
                     seed_exploration_task(sim.core, completed_army, sim.day, F, {F}),
                 "exploration phases: tasks seeded");
        ST_STEP(sim, sim.day + 1);
        MilitaryExplorationTask *paused = const_cast<MilitaryExplorationTask *>(
            sim.core.exploration_task_for_army(paused_army));
        MilitaryExplorationTask *returning = const_cast<MilitaryExplorationTask *>(
            sim.core.exploration_task_for_army(returning_army));
        MilitaryExplorationTask *completed = const_cast<MilitaryExplorationTask *>(
            sim.core.exploration_task_for_army(completed_army));
        ST_CHECK(paused != nullptr && returning != nullptr && completed != nullptr,
                 "exploration phases: tasks live");
        for (int32_t army : {paused_army, returning_army, completed_army}) {
            MilitaryArmyStore &a = sim.core._armies;
            a.path_len[(size_t)army] = 0;
            a.path_cursor[(size_t)army] = 0;
            a.target_cell[(size_t)army] = -1;
        }
        paused->phase = (uint8_t)MILITARY_EXPLORATION_PAUSED_BATTLE;
        paused->pause_reason = (uint8_t)MILITARY_EXPLORATION_PAUSE_ENGAGEMENT;
        paused->resume_phase = (uint8_t)MILITARY_EXPLORATION_ACTIVE;
        paused->result = (uint8_t)MILITARY_EXPLORATION_RESULT_NONE;
        paused->focus_index = -1;
        paused->current_observation_cell = -1;
        paused->observer_tries = 0;
        paused->reached_observer_cells.fill(-1);
        paused->complete_day = -1;
        returning->phase = (uint8_t)MILITARY_EXPLORATION_RETURNING;
        returning->pause_reason = (uint8_t)MILITARY_EXPLORATION_PAUSE_NONE;
        returning->resume_phase = (uint8_t)MILITARY_EXPLORATION_RETURNING;
        returning->result = (uint8_t)MILITARY_EXPLORATION_RESULT_ALL_SEEN;
        returning->focus_index = -1;
        returning->current_observation_cell = -1;
        returning->complete_day = -1;
        completed->phase = (uint8_t)MILITARY_EXPLORATION_COMPLETE;
        completed->pause_reason = (uint8_t)MILITARY_EXPLORATION_PAUSE_NONE;
        completed->result = (uint8_t)MILITARY_EXPLORATION_RESULT_ALL_SEEN;
        completed->focus_index = -1;
        completed->current_observation_cell = -1;
        completed->observer_tries = 0;
        completed->reached_observer_cells.fill(-1);
        completed->complete_day = sim.core.last_day();

        const std::vector<uint8_t> bytes = sim.core.encode();
        MilitaryCore restored;
        std::string error;
        ST_CHECK(restored.configure(make_catalog(), 7351, error) &&
                     restored.set_terrain(t, error) &&
                     restored.restore(bytes.data(), bytes.size(), error),
                 "exploration phases: PKMI v4 round-trips paused/returning/complete");
        ST_CHECK(restored.state_hash() == sim.core.state_hash(),
                 "exploration phases: state_hash survives all phases");
        ST_CHECK(restored.encode() == bytes,
                 "exploration phases: re-encode is byte-identical");
        const MilitaryExplorationTask *restored_paused =
            restored.exploration_task_for_army(paused_army);
        const MilitaryExplorationTask *restored_returning =
            restored.exploration_task_for_army(returning_army);
        const MilitaryExplorationTask *restored_completed =
            restored.exploration_task_for_army(completed_army);
        ST_CHECK(restored_paused != nullptr && restored_returning != nullptr &&
                     restored_completed != nullptr &&
                     restored_paused->phase ==
                         (uint8_t)MILITARY_EXPLORATION_PAUSED_BATTLE &&
                     restored_returning->phase ==
                         (uint8_t)MILITARY_EXPLORATION_RETURNING &&
                     restored_completed->phase ==
                         (uint8_t)MILITARY_EXPLORATION_COMPLETE,
                 "exploration phases: phases and index rebuild exactly");

        Sim continuation;
        ST_CHECK(continuation.init(t, 7351), "exploration phases: continuation init");
        continuation.day = sim.day;
        ST_CHECK(continuation.core.restore(bytes.data(), bytes.size(), error),
                 "exploration phases: continuation restore");
        ST_STEP(continuation, continuation.day + 8);
        const std::vector<uint8_t> continued = continuation.core.encode();
        MilitaryCore continued_copy;
        ST_CHECK(continued_copy.configure(make_catalog(), 7351, error) &&
                     continued_copy.set_terrain(t, error) &&
                     continued_copy.restore(continued.data(), continued.size(), error),
                 "exploration phases: 8 continued days remain saveable");
    }

    // Malformed section 23 payloads must be rejected by structural validation,
    // not accepted and repaired silently.
    {
        Sim sim;
        ST_CHECK(sim.init(t, 7352), "exploration malformed: sim init");
        const int32_t A = cell_at(4, 4);
        const int32_t B = cell_at(10, 4);
        const int32_t army = make_exploration_army(sim.core, 0, A);
        std::vector<uint8_t> explored((size_t)t.cell_count, 0);
        sim.core.set_exploration_view(0, explored.data(), explored.size(),
                                      sim.day, 1);
        ST_CHECK(seed_exploration_task(sim.core, army, sim.day, B, {B}),
                 "exploration malformed: task seeded");
        ST_STEP(sim, sim.day + 1);
        MilitaryArmyStore &a = sim.core._armies;
        a.path_len[(size_t)army] = 0;
        a.path_cursor[(size_t)army] = 0;
        a.target_cell[(size_t)army] = -1;
        const std::vector<uint8_t> bytes = sim.core.encode();
        size_t start = 0, length = 0;
        ST_CHECK(pkmi_section_span(bytes, 23, start, length),
                 "exploration malformed: section 23 present");
        const size_t row = start + 6 + 4;
        auto restore_with = [&](const std::vector<uint8_t> &candidate,
                                const char *expected) {
            MilitaryCore copy;
            std::string error;
            if (!copy.configure(make_catalog(), 7352, error) ||
                !copy.set_terrain(t, error)) {
                return false;
            }
            if (copy.restore(candidate.data(), candidate.size(), error)) return false;
            return error == expected;
        };

        std::vector<uint8_t> bad_cells = bytes;
        write_u32_le(bad_cells, row + 45, 0x7FFFFFFFu);
        ST_CHECK(restore_with(bad_cells, "pkmi_exploration_bad_cells"),
                 "exploration malformed: out-of-range cell is refused");

        std::vector<uint8_t> bad_masks = bytes;
        write_u64_le(bad_masks, row + 49, 2ull);
        ST_CHECK(restore_with(bad_masks, "pkmi_exploration_bad_masks"),
                 "exploration malformed: mask bit past the selected set is refused");

        std::vector<uint8_t> bad_phase = bytes;
        bad_phase[row + 145] = 99;
        ST_CHECK(restore_with(bad_phase, "pkmi_exploration_bad_phase"),
                 "exploration malformed: unknown phase is refused");

        // Two rows naming the same army violate the one-task-per-formation
        // invariant even when both rows are otherwise well formed.
        const int32_t second_army = make_exploration_army(sim.core, 0, cell_at(4, 7));
        ST_CHECK(second_army >= 0 &&
                     seed_exploration_task(sim.core, second_army, sim.day,
                                           cell_at(10, 7), {cell_at(10, 7)}),
                 "exploration malformed: duplicate fixture");
        ST_STEP(sim, sim.day + 1);
        for (int32_t handle_army : {army, second_army}) {
            a.path_len[(size_t)handle_army] = 0;
            a.path_cursor[(size_t)handle_army] = 0;
            a.target_cell[(size_t)handle_army] = -1;
        }
        std::vector<uint8_t> duplicate = sim.core.encode();
        size_t duplicate_start = 0, duplicate_length = 0;
        ST_CHECK(pkmi_section_span(duplicate, 23, duplicate_start,
                                   duplicate_length),
                 "exploration malformed: duplicate section present");
        const size_t duplicate_row0 = duplicate_start + 6 + 4;
        const size_t duplicate_row1 = duplicate_row0 + kPkmiExplorationRowBytes;
        const uint64_t first_army_handle =
            sim.core.army_handle(army);
        write_u64_le(duplicate, duplicate_row1 + 5, first_army_handle);
        ST_CHECK(restore_with(duplicate, "pkmi_exploration_duplicate_army"),
                 "exploration malformed: duplicate army is refused");
    }
    return true;
}
