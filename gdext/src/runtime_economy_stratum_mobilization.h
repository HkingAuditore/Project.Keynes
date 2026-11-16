#pragma once

#include <cstddef>
#include <cstdint>
#include <vector>

namespace pk {

// One sparse (cell, profession) mobilization record. Rows exist only where a
// profession is actually aggrieved or has an active chain, so a peaceful world
// keeps this table near-empty.
struct StratumMobilizationRow {
    int32_t cell = -1;
    uint16_t profession = 0;
    int32_t owner_slot = -1;
    uint16_t mobilization_q16 = 0;
    uint16_t satisfaction_ema_q16 = 0;
    uint16_t share_q16 = 0;
    uint16_t local_sat_q16 = 0;
    uint8_t stage = 0;
    uint8_t flags = 0;
    int32_t next_check_day = 0;
    int32_t cooldown_until_day = 0;
    int32_t last_event_day = -1;
    uint16_t trauma_q16 = 0;
};

// Row storage is sorted by (cell, profession); cell_offsets is a derived CSR
// over rows and is rebuilt on every structural change. Inserts/erases are rare
// (a cell only gains a row when it becomes aggrieved), so an O(rows) rebuild is
// cheaper and simpler than a hash map in the epoch loop.
struct StratumMobilizationStore {
    std::vector<int32_t> cell_offsets;
    std::vector<StratumMobilizationRow> rows;

    void clear(int32_t cell_count) {
        cell_offsets.assign(static_cast<size_t>(cell_count) + 1u, 0);
        rows.clear();
    }
    void rebuild_offsets(int32_t cell_count) {
        cell_offsets.assign(static_cast<size_t>(cell_count) + 1u, 0);
        for (const StratumMobilizationRow &row : rows) {
            if (row.cell < 0 || row.cell >= cell_count) continue;
            ++cell_offsets[static_cast<size_t>(row.cell) + 1u];
        }
        for (int32_t cell = 0; cell < cell_count; ++cell)
            cell_offsets[static_cast<size_t>(cell) + 1u] +=
                cell_offsets[static_cast<size_t>(cell)];
    }
    int32_t find(int32_t cell, int32_t profession) const {
        if (cell < 0 || static_cast<size_t>(cell) + 1u >= cell_offsets.size())
            return -1;
        const int32_t begin = cell_offsets[static_cast<size_t>(cell)];
        const int32_t end = cell_offsets[static_cast<size_t>(cell) + 1u];
        for (int32_t i = begin; i < end; ++i) {
            if (static_cast<int32_t>(rows[static_cast<size_t>(i)].profession) ==
                profession)
                return i;
        }
        return -1;
    }
    int32_t ensure(int32_t cell, int32_t profession, int32_t cell_count) {
        const int32_t found = find(cell, profession);
        if (found >= 0) return found;
        if (cell < 0 || cell >= cell_count) return -1;
        StratumMobilizationRow row;
        row.cell = cell;
        row.profession = static_cast<uint16_t>(profession);
        auto at = rows.begin() +
            static_cast<std::ptrdiff_t>(cell_offsets[static_cast<size_t>(cell) + 1u]);
        rows.insert(at, row);
        rebuild_offsets(cell_count);
        return find(cell, profession);
    }
    void erase_at(int32_t index, int32_t cell_count) {
        if (index < 0 || index >= static_cast<int32_t>(rows.size())) return;
        rows.erase(rows.begin() + static_cast<std::ptrdiff_t>(index));
        rebuild_offsets(cell_count);
    }
};

} // namespace pk
