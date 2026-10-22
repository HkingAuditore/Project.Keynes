#pragma once
#include <cstdint>
#include <vector>

namespace pk {

// Per-cell coefficient table (Doc 03 §4.2), v1.
//
// Why this exists: a cell card is a function -- "for every cell my country owns,
// stat[c] += coef * f(column[c]) * [filter bitmap]" -- and it needs no instance,
// no transaction and no ACK. Building it as one Effect instance per cell is what
// hit the 4096-instance ceiling and forced the 32-cell cap; the table does not.
//
// v1 scope, deliberately narrow:
//   * the filter is ONE tag (-1 = the whole territory), so selectors 0/12/13 map
//     onto it directly and the radial kinds (14/15) do not;
//   * the column is modelled but only two kinds exist (`CONSTANT`,
//     `NEIGHBOR_COUNT`); no generator DSL emits the second one yet, so every
//     shipped entry is still CONSTANT;
//   * `cap_units` and the MUL accumulator are reserved but unused.
// Anything outside that scope is counted as unsupported rather than guessed at,
// so the report can say how much of the catalog the plane really covers.

// Which per-cell quantity the coefficient is multiplied by. `CONSTANT` is the
// flat bonus that 41 bare-B cards ask for; `NEIGHBOR_COUNT` is X2's "one step
// per adjacent matching cell". The kind is a closed enum, never a string: the
// Economy side dispatches on it in a hot loop.
enum CellColumnKind : int32_t {
    CELL_COLUMN_CONSTANT = 0,
    CELL_COLUMN_NEIGHBOR_COUNT = 1,
};

struct CellProgramEntry {
    int32_t stat_id = -1;      // Modifier stat the card writes
    int32_t filter_tag = -1;   // 0-based tag id, -1 = every owned cell
    int32_t operation = 0;     // ModifierRuntime::ADD / MULTIPLY
    int32_t coef_q16 = 0;      // the command's magnitude, verbatim
    int32_t column_kind = CELL_COLUMN_CONSTANT;
    int32_t column_tag = -1;   // NEIGHBOR_COUNT: which tag to count, -1 = any
    int32_t cap_units = 0;     // 0 = no cap; else min(column, cap)
};

struct CellProgramTable {
    // Bumped whenever the table is rebuilt. Economy keys its cache on this plus
    // the effect input revision, so an unchanged world does no work.
    uint64_t generation = 0;
    // CSR over country slot: entries for slot c are
    // [country_offsets[c], country_offsets[c + 1]).
    std::vector<int32_t> country_offsets;
    std::vector<CellProgramEntry> entries;
    // Diagnostics. A card that fell outside v1 is COUNTED, never silently
    // dropped: "the plane covers 30 of 179 cards" is a fact the roadmap needs.
    int32_t unsupported_selector = 0;
    int32_t unsupported_definition = 0;
    int32_t unsupported_stack = 0;
    int32_t unsupported_domain = 0;
    // How far the scan actually got. Without these an empty table is
    // indistinguishable from "no cards" and from "cards with no persistent row",
    // which is exactly the ambiguity that cost a debugging round.
    int32_t scanned_cards = 0;
    int32_t scanned_templates = 0;

    bool empty() const { return entries.empty(); }
};

} // namespace pk
