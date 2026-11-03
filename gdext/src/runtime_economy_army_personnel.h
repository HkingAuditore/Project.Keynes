#pragma once

// Army personnel lane store (Economy side of the army personnel lane).
//
// Contract: docs/plans/army-personnel-implementation-contract.md §1.1.
// Soldiers are ordinary Economy cohorts while they garrison their home cell.
// Once they are embarked (`COMMAND_ARMY_EMBARK`) the people, their cash and
// their satisfaction live here, keyed by the Military army handle, because the
// army is the only owner that knows where those people are on any given day.
// They are NOT a cohort: they have no (cell, signature) identity, they never
// enter the population store, and they never appear in a cell summary.
//
// Design notes:
// * Structure-of-arrays, dense rows, integer state only, no Dictionary/string.
// * Row identity is the army handle (`gen << 32 | slot`); a handle that has no
//   lane has no row. Releasing a row compacts the SoA by moving the last row
//   into the hole and rebuilds the open-addressing handle index, so CSR
//   (family/person sub-ledger) segments always belong to the row they name.
// * `cell` is the army's cell as published by Military through
//   `set_military_army_ration`; it is the cell the lane consumes in (guest
//   consumption) and the cell DISEMBARK returns the people to.
// * `country_handle` is resolved from the cell owner when the lane is created
//   (contract calls the field `country_slot`; a full 64-bit country handle is
//   used instead of a 32-bit slot index so the comparison against
//   `country_handle_for_cell()` is exact).
// * family/person sub-ledgers are stored as CSR segments and are empty in v1
//   (contract §3: family effects and commander candidates are a later step),
//   but the storage and the merge/disembark paths already handle them.

#include <cstdint>
#include <vector>

namespace pk {

class ArmyPersonnelStore {
public:
    static constexpr int32_t NO_ROW = -1;
    // Local copy of the runtime's Q16 one (the store is a standalone type and
    // must not depend on NativeEconomyRuntime's nested constants).
    static constexpr int32_t LANE_Q16_ONE = 65536;
    // Bounded like every other SoA in the runtime; armies beyond this simply
    // fail to allocate a lane (the command reports an error instead of
    // silently dropping people).
    static constexpr int32_t MAX_ROWS = 4096;

    void clear();
    int32_t size() const { return static_cast<int32_t>(active.size()); }

    // Row of `army_handle` (NO_ROW when the army has no lane).
    int32_t find(uint64_t army_handle) const;
    // Row of `army_handle`, creating an empty lane when absent (NO_ROW on
    // capacity exhaustion).
    int32_t ensure(uint64_t army_handle);
    // Drops a row and compacts the SoA. Callers must have removed the people
    // first; this only releases the storage.
    void release(int32_t row);

    bool valid_row(int32_t row) const {
        return row >= 0 && static_cast<size_t>(row) < active.size() &&
            active[static_cast<size_t>(row)] != 0;
    }
    uint64_t handle_at(int32_t row) const {
        return valid_row(row) ? handle[static_cast<size_t>(row)] : 0;
    }
    int64_t total_population() const;
    int64_t total_funds() const;
    bool empty() const { return active.empty(); }

    // SoA columns. `active` gates every read; inactive rows are never
    // referenced by a handle lookup.
    std::vector<uint8_t> active;
    std::vector<uint64_t> handle;
    std::vector<uint64_t> country_handle;
    std::vector<int32_t> cell;
    // Consumption identity, captured from the source cohort signature at
    // embark time: guest consumption needs the soldier plan even when the
    // home cohort has been drained.
    std::vector<int32_t> profession_id;
    std::vector<int32_t> plan_id;
    std::vector<int32_t> signature_id;
    std::vector<int64_t> population;
    std::vector<int64_t> funds;
    std::vector<int64_t> epoch_income;
    std::vector<int64_t> epoch_expense;
    // Q16 [0, 1]. `satisfaction_q16` is the population-weighted fill ratio of
    // the lane's non-state-supplied needs; `survival_q16` only the survival
    // basket (food + clothing); `ration_q16` is the Military-published
    // in-kind ration fill ratio for the two state-supplied needs.
    std::vector<int32_t> satisfaction_q16;
    std::vector<int32_t> survival_q16;
    std::vector<int32_t> ration_q16;
    // CSR segments into family_handles/family_people/family_funds and
    // person_handles.
    std::vector<int32_t> family_offset;
    std::vector<int32_t> family_len;
    std::vector<int32_t> person_offset;
    std::vector<int32_t> person_len;
    std::vector<uint64_t> family_handles;
    std::vector<int64_t> family_people;
    std::vector<int64_t> family_funds;
    std::vector<uint64_t> person_handles;

private:
    void push_empty_row(uint64_t army_handle);
    void rebuild_index();
    // Open-addressing (linear probe) handle -> row index. Rebuilt on release;
    // never saved, never hashed.
    std::vector<int32_t> _buckets;
    size_t _mask = 0;
};

} // namespace pk
