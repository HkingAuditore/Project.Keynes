// Synthetic-grid self check for the shared effect target selector.
//
// Why this exists: the selector reads _cell_count / _building_neighbors /
// _building_terrain and friends, all of which are only populated when a real
// map_data drives capture_building_context() through an epoch. Headless tests
// therefore had zero cells to select from and every selector returned an empty
// array, which made the whole target-selector milestone unverifiable.
//
// This file builds the same snapshot by hand (the EconomyPricingTests pattern:
// a friend struct writing private columns directly) so every branch of
// collect_effect_target_cells() can be asserted without a live world.
//
// Note on access: friendship is not transitive. Every private write below must
// stay inside EconomyTargetSelectorTests::run (or a lambda defined in it) --
// moving the fixture setup into a helper struct silently loses access.

#include "economy_runtime.h"
#include "effect_runtime.h"

#include <algorithm>
#include <cstdint>
#include <memory>
#include <string>
#include <vector>

namespace pk {

namespace {

using ER = EffectRuntime;

constexpr int32_t kCols = 6;
constexpr int32_t kRows = 5;
constexpr int32_t kCells = kCols * kRows;
// Left half of the grid is terrain 0, right half terrain 1.
constexpr int32_t kTerrainSplitCol = 3;
// Interior cell used as the selector source: row 2, col 2.
constexpr int32_t kInteriorRow = 2;
constexpr int32_t kInteriorCol = 2;
constexpr int32_t kInteriorCell = kInteriorRow * kCols + kInteriorCol;

int32_t cell_id(int32_t row, int32_t col) { return row * kCols + col; }

// odd-r offset hex layout: odd rows shove their side neighbours one column
// right, which is the same convention capture_building_context() consumes.
void build_hex_neighbors(std::vector<int32_t> &neighbors) {
    neighbors.assign(static_cast<size_t>(kCells) * 6, -1);
    const int32_t dr[6] = {0, 0, -1, -1, 1, 1};
    const int32_t dc_even[6] = {-1, 1, -1, 0, -1, 0};
    const int32_t dc_odd[6] = {-1, 1, 0, 1, 0, 1};
    for (int32_t row = 0; row < kRows; ++row) {
        for (int32_t col = 0; col < kCols; ++col) {
            const int32_t cell = cell_id(row, col);
            const bool odd = (row % 2) != 0;
            for (int32_t dir = 0; dir < 6; ++dir) {
                const int32_t nr = row + dr[dir];
                const int32_t nc = col + (odd ? dc_odd[dir] : dc_even[dir]);
                if (nr < 0 || nr >= kRows || nc < 0 || nc >= kCols) continue;
                neighbors[static_cast<size_t>(cell) * 6 + static_cast<size_t>(dir)] =
                    cell_id(nr, nc);
            }
        }
    }
}

// Independent breadth-first hop count, used as the oracle for the hop-limit
// selector. Deliberately re-implemented here instead of reusing anything the
// runtime exposes, so a bug in the selector cannot hide behind a shared helper.
void bfs_distances(int32_t source, const std::vector<int32_t> &neighbors,
                   std::vector<int32_t> &dist) {
    dist.assign(static_cast<size_t>(kCells), -1);
    if (source < 0 || source >= kCells) return;
    dist[static_cast<size_t>(source)] = 0;
    std::vector<int32_t> frontier;
    frontier.push_back(source);
    std::vector<int32_t> next;
    for (int32_t depth = 1; !frontier.empty() && depth <= kCells; ++depth) {
        next.clear();
        for (const int32_t cell : frontier) {
            for (int32_t dir = 0; dir < 6; ++dir) {
                const int32_t nb = neighbors[static_cast<size_t>(cell) * 6 +
                                             static_cast<size_t>(dir)];
                if (nb < 0 || nb >= kCells) continue;
                if (dist[static_cast<size_t>(nb)] >= 0) continue;
                dist[static_cast<size_t>(nb)] = depth;
                next.push_back(nb);
            }
        }
        frontier.swap(next);
    }
}

bool expect(bool condition, const char *label, std::string &error) {
    if (condition) return true;
    if (error.empty()) error = label;
    return false;
}

bool contains(const std::vector<int32_t> &cells, int32_t cell) {
    return std::find(cells.begin(), cells.end(), cell) != cells.end();
}

bool all_cells_in_left_half(const std::vector<int32_t> &cells) {
    for (const int32_t cell : cells)
        if ((cell % kCols) >= kTerrainSplitCol) return false;
    return true;
}

} // namespace

bool EconomyTargetSelectorTests::run(std::string &error) {
    error.clear();

    // Access to the runtime's private per-cell snapshot is limited to this
    // function and lambdas defined in it; see the note at the top of the file.
    std::vector<int32_t> neighbors;
    build_hex_neighbors(neighbors);
    // EconomyTrackedColumn deletes its copy constructor, so the runtime is
    // rebuilt from scratch for each scenario rather than assigned.
    auto rt = std::make_unique<NativeEconomyRuntime>();
    auto fill_snapshot = [&]() {
        rt = std::make_unique<NativeEconomyRuntime>();
        rt->_cell_count = kCells;
        rt->_building_neighbors = neighbors;
        rt->_epoch_cell_country.assign(static_cast<size_t>(kCells), 0);
        rt->_building_elevation_q16.assign(static_cast<size_t>(kCells), 0);
        rt->_building_terrain.assign(static_cast<size_t>(kCells), 0);
        rt->_building_landform.assign(static_cast<size_t>(kCells), 0);
        rt->_building_vegetation.assign(static_cast<size_t>(kCells), 0);
        rt->_building_is_water.assign(static_cast<size_t>(kCells), 0);
        rt->_building_has_river.assign(static_cast<size_t>(kCells), 0);
        // Terrain: a hard split so a component walk that ignores terrain
        // identity is immediately visible.
        for (int32_t cell = 0; cell < kCells; ++cell)
            if ((cell % kCols) >= kTerrainSplitCol)
                rt->_building_terrain[static_cast<size_t>(cell)] = 1;
        // River predicate: the whole top row only, so the expected hit count
        // is a constant the assertion can state exactly.
        for (int32_t col = 0; col < kCols; ++col)
            rt->_building_has_river[static_cast<size_t>(cell_id(0, col))] = 1;
        // Resource lanes: resource 0 dominates the left half, resource 1 the
        // right half, so "same dominant resource" must never cross the split.
        rt->_resource_ids.clear();
        rt->_resource_ids.push_back("iron");
        rt->_resource_ids.push_back("corn");
        auto &stock = rt->resource_stock_lanes();
        stock.assign(static_cast<size_t>(kCells) * 2, static_cast<int64_t>(0));
        for (int32_t cell = 0; cell < kCells; ++cell) {
            const bool left = (cell % kCols) < kTerrainSplitCol;
            stock.write_scalar(
                static_cast<size_t>(0 * kCells + cell), left ? 100 : 10);
            stock.write_scalar(
                static_cast<size_t>(1 * kCells + cell), left ? 10 : 100);
        }
    };
    fill_snapshot();
    std::vector<int32_t> out;

    // Legacy kinds must keep their pre-existing "anchor only" contract: the
    // selector generalisation must not silently change family effect numbers.
    rt->collect_effect_target_cells(kInteriorCell, ER::SELECTOR_OWNER, 0, 0, out);
    if (!expect(out.size() == 1 && out[0] == kInteriorCell,
                "selector_owner_anchor_only", error)) return false;
    rt->collect_effect_target_cells(kInteriorCell, ER::SELECTOR_ID, 0, 0, out);
    if (!expect(out.size() == 1 && out[0] == kInteriorCell,
                "selector_id_anchor_only", error)) return false;

    // 1-2. R1 = exactly the six hex neighbours, never the source itself.
    rt->collect_effect_target_cells(kInteriorCell, ER::SELECTOR_NEIGHBORS_R1, 0, 0, out);
    if (!expect(out.size() == 6, "selector_r1_count", error)) return false;
    {
        const std::vector<int32_t> expected = {7, 8, 13, 15, 19, 20};
        if (!expect(out == expected, "selector_r1_members", error)) return false;
    }
    if (!expect(!contains(out, kInteriorCell), "selector_r1_excludes_source", error))
        return false;

    // 3-4. R2 must be sorted and duplicate free (the sort/unique contract).
    rt->collect_effect_target_cells(kInteriorCell, ER::SELECTOR_NEIGHBORS_R2, 0, 0, out);
    if (!expect(std::is_sorted(out.begin(), out.end()), "selector_r2_sorted", error))
        return false;
    if (!expect(std::adjacent_find(out.begin(), out.end()) == out.end(),
                "selector_r2_unique", error)) return false;
    if (!expect(!contains(out, kInteriorCell), "selector_r2_excludes_source", error))
        return false;
    // 5. A corner cell cannot reach the 18-cell ceiling, and never exceeds it.
    rt->collect_effect_target_cells(0, ER::SELECTOR_NEIGHBORS_R2, 0, 0, out);
    if (!expect(out.size() <= 18, "selector_r2_cap", error)) return false;

    // 6-7. Terrain component: stays inside terrain 0 and includes its anchor.
    rt->collect_effect_target_cells(
        kInteriorCell, ER::SELECTOR_SAME_TERRAIN_COMPONENT, 8, 0, out);
    if (!expect(!out.empty(), "selector_terrain_non_empty", error)) return false;
    if (!expect(all_cells_in_left_half(out), "selector_terrain_no_cross", error))
        return false;
    if (!expect(contains(out, kInteriorCell), "selector_terrain_includes_anchor", error))
        return false;
    if (!expect(out.size() <= 8, "selector_terrain_cap", error)) return false;

    // 8. Resource component: same split, driven by dominant_resource_at().
    rt->collect_effect_target_cells(
        kInteriorCell, ER::SELECTOR_SAME_RESOURCE_COMPONENT, 8, 0, out);
    if (!expect(!out.empty(), "selector_resource_non_empty", error)) return false;
    if (!expect(all_cells_in_left_half(out), "selector_resource_no_cross", error))
        return false;
    if (!expect(contains(out, kInteriorCell), "selector_resource_includes_anchor", error))
        return false;

    // 9. Predicate over the whole grid: hit count must equal the planted count.
    rt->collect_effect_target_cells(
        kInteriorCell, ER::SELECTOR_PREDICATE_ANY_CELL, 32, 1, out);
    {
        const std::vector<int32_t> expected = {0, 1, 2, 3, 4, 5};
        if (!expect(out == expected, "selector_predicate_river_hits", error))
            return false;
    }
    // A predicate the source cell itself satisfies must include the source.
    rt->collect_effect_target_cells(
        cell_id(0, 2), ER::SELECTOR_PREDICATE_ANY_CELL, 32, 1, out);
    if (!expect(contains(out, cell_id(0, 2)),
                "selector_predicate_includes_matching_source", error)) return false;
    // A predicate nothing satisfies must yield nothing, not the anchor.
    rt->collect_effect_target_cells(
        kInteriorCell, ER::SELECTOR_PREDICATE_ANY_CELL, 32, 2, out);
    if (!expect(out.empty(), "selector_predicate_no_hits", error)) return false;

    // 10. Hop limit: every result within param1 hops, and a cell beyond that
    //     limit must be excluded (proving the limit is actually applied).
    {
        std::vector<int32_t> dist;
        bfs_distances(kInteriorCell, neighbors, dist);
        rt->collect_effect_target_cells(kInteriorCell, ER::SELECTOR_DISTANCE_N, 32, 2, out);
        if (!expect(!out.empty(), "selector_distance_non_empty", error)) return false;
        for (const int32_t cell : out) {
            const int32_t hop = dist[static_cast<size_t>(cell)];
            if (!expect(hop >= 0 && hop <= 2, "selector_distance_in_range", error))
                return false;
        }
        bool found_far = false;
        for (int32_t cell = 0; cell < kCells; ++cell) {
            if (dist[static_cast<size_t>(cell)] <= 2) continue;
            found_far = true;
            if (!expect(!contains(out, cell), "selector_distance_excludes_far", error))
                return false;
        }
        // Guard against a degenerate grid where the assertion above is vacuous.
        if (!expect(found_far, "selector_distance_far_cell_exists", error)) return false;
        if (!expect(contains(out, kInteriorCell),
                    "selector_distance_includes_anchor", error)) return false;
    }

    // 11. param0 is the fan-out cap for every generalised kind. This is the
    //     regression guard for param0 doubling as the hop count.
    rt->collect_effect_target_cells(kInteriorCell, ER::SELECTOR_DISTANCE_N, 4, 2, out);
    if (!expect(out.size() <= 4, "selector_distance_cap_applied", error)) return false;
    rt->collect_effect_target_cells(
        kInteriorCell, ER::SELECTOR_SAME_TERRAIN_COMPONENT, 3, 0, out);
    if (!expect(out.size() <= 3, "selector_terrain_cap_applied", error)) return false;
    // param0 above the hard ceiling is clamped, never trusted.
    rt->collect_effect_target_cells(
        kInteriorCell, ER::SELECTOR_PREDICATE_ANY_CELL,
        ER::SELECTOR_MAX_CELLS + 100, 1, out);
    if (!expect(out.size() <= ER::SELECTOR_MAX_CELLS,
                "selector_cap_hard_clamped", error)) return false;

    // 12. Determinism: the selector must be a pure function of the snapshot.
    {
        std::vector<int32_t> reference;
        rt->collect_effect_target_cells(
            kInteriorCell, ER::SELECTOR_SAME_TERRAIN_COMPONENT, 8, 0, reference);
        for (int32_t repeat = 0; repeat < 100; ++repeat) {
            rt->collect_effect_target_cells(
                kInteriorCell, ER::SELECTOR_SAME_TERRAIN_COMPONENT, 8, 0, out);
            if (!expect(out == reference, "selector_deterministic", error)) return false;
        }
    }

    // 13-16. Country territory index. The fixture is rebuilt here because the
    //        ownership column above is deliberately all-zero (one owner for the
    //        whole grid); a territory assertion on that grid would be vacuous.
    fill_snapshot();
    // Two countries split along the same column the terrain split uses, so a
    // selector that leaks across the border is visible in both dimensions.
    for (int32_t cell = 0; cell < kCells; ++cell)
        rt->_epoch_cell_country[static_cast<size_t>(cell)] =
            (cell % kCols) < kTerrainSplitCol ? 0 : 1;
    rt->_epoch_country_count = 2;
    rt->rebuild_country_territory_index();
    if (!expect(rt->country_territory_index_ready(),
                "territory_index_ready", error)) return false;
    if (!expect(rt->country_cell_count(0) == 15, "territory_count_left", error))
        return false;
    if (!expect(rt->country_cell_count(1) == 15, "territory_count_right", error))
        return false;
    // The anchor must stay the lowest owned cell -- the CSR replaced the linear
    // scan, so this asserts the fast path returns the identical value.
    if (!expect(rt->country_anchor_cell(0) == 0, "territory_anchor_left", error))
        return false;
    if (!expect(rt->country_anchor_cell(1) == 3, "territory_anchor_right", error))
        return false;
    if (!expect(rt->country_cell_at(1, 0) == 3, "territory_cell_at_head", error))
        return false;
    if (!expect(rt->country_cell_at(1, 14) == cell_id(4, 5),
                "territory_cell_at_tail", error)) return false;
    // Ascending order is the contract a cell cap relies on.
    {
        bool ascending = true;
        for (int32_t index = 1; index < rt->country_cell_count(1); ++index) {
            if (rt->country_cell_at(1, index) <= rt->country_cell_at(1, index - 1)) {
                ascending = false;
                break;
            }
        }
        if (!expect(ascending, "territory_cells_ascending", error)) return false;
    }

    // 17. Out-of-range slots and indices never read past their slice.
    for (const int32_t bad_slot : {-1, 2, 9}) {
        if (!expect(rt->country_cell_count(bad_slot) == 0,
                    "territory_count_out_of_range", error)) return false;
        if (!expect(rt->country_cell_at(bad_slot, 0) == -1,
                    "territory_cell_at_out_of_range", error)) return false;
        if (!expect(rt->country_anchor_cell(bad_slot) == -1,
                    "territory_anchor_out_of_range", error)) return false;
    }
    for (const int32_t bad_index : {-1, 15, 99}) {
        if (!expect(rt->country_cell_at(0, bad_index) == -1,
                    "territory_index_out_of_range", error)) return false;
    }

    // 18-19. The territory selector answers with the owner's cells only. A hex
    //        walk from either anchor can never produce the opposite half, so the
    //        expected sets are exact rather than merely capped.
    {
        std::vector<int32_t> expected_left;
        std::vector<int32_t> expected_right;
        for (int32_t cell = 0; cell < kCells; ++cell) {
            if ((cell % kCols) < kTerrainSplitCol) expected_left.push_back(cell);
            else expected_right.push_back(cell);
        }
        rt->collect_effect_target_cells(
            kInteriorCell, ER::SELECTOR_OWN_TERRITORY, 32, 0, out);
        if (!expect(out == expected_left, "territory_selector_left_set", error))
            return false;
        rt->collect_effect_target_cells(
            cell_id(2, 4), ER::SELECTOR_OWN_TERRITORY, 32, 0, out);
        if (!expect(out == expected_right, "territory_selector_right_set", error))
            return false;
    }

    // 20. Cap keeps the lowest cell ids of the owner, never a foreign cell.
    rt->collect_effect_target_cells(
        kInteriorCell, ER::SELECTOR_OWN_TERRITORY, 7, 0, out);
    if (!expect(out.size() == 7, "territory_selector_cap_count", error))
        return false;
    if (!expect(std::is_sorted(out.begin(), out.end()),
                "territory_selector_cap_sorted", error)) return false;
    if (!expect(all_cells_in_left_half(out),
                "territory_selector_cap_in_territory", error)) return false;
    // param0 above the hard ceiling is clamped, same as every other kind.
    rt->collect_effect_target_cells(
        kInteriorCell, ER::SELECTOR_OWN_TERRITORY,
        ER::SELECTOR_MAX_CELLS + 100, 0, out);
    if (!expect(out.size() == 15, "territory_selector_hard_clamp", error))
        return false;

    // 21. Predicate ids filter the territory instead of the grid: the river row
    //     exists on both sides, so a left-owned query must return only the left
    //     three. SELECTOR_PREDICATE_ANY_CELL over the same snapshot returns all
    //     six -- the two kinds are asserted side by side so a regression that
    //     makes territory grid-wide is unmissable.
    rt->collect_effect_target_cells(
        kInteriorCell, ER::SELECTOR_OWN_TERRITORY, 32, 1, out);
    {
        const std::vector<int32_t> expected = {0, 1, 2};
        if (!expect(out == expected, "territory_predicate_river_scoped", error))
            return false;
    }
    rt->collect_effect_target_cells(
        kInteriorCell, ER::SELECTOR_PREDICATE_ANY_CELL, 32, 1, out);
    if (!expect(out.size() == 6, "territory_predicate_grid_still_wide", error))
        return false;

    // 22. A predicate nothing satisfies yields nothing. Falling back to the
    //     anchor here would apply a "matching cells only" card to a non-matching
    //     cell, which is exactly the bug L1-5 exists to prevent.
    rt->collect_effect_target_cells(
        kInteriorCell, ER::SELECTOR_OWN_TERRITORY, 32, 2, out);
    if (!expect(out.empty(), "territory_predicate_no_hits", error)) return false;
    // An unknown predicate id is rejected rather than treated as "match all".
    rt->collect_effect_target_cells(
        kInteriorCell, ER::SELECTOR_OWN_TERRITORY, 32, 77, out);
    if (!expect(out.empty(), "territory_predicate_unknown_id", error)) return false;

    // 23. Dropping the index must not change any answer: the linear fallback has
    //     to agree with the CSR byte for byte, or a fixture-built runtime and a
    //     live epoch would behave differently.
    {
        std::vector<int32_t> indexed;
        rt->collect_effect_target_cells(
            kInteriorCell, ER::SELECTOR_OWN_TERRITORY, 32, 1, indexed);
        const int32_t indexed_count = rt->country_cell_count(0);
        const int32_t indexed_anchor = rt->country_anchor_cell(1);
        rt->_epoch_country_cell_offsets.clear();
        rt->_epoch_country_cells.clear();
        if (!expect(!rt->country_territory_index_ready(),
                    "territory_index_cleared", error)) return false;
        std::vector<int32_t> scanned;
        rt->collect_effect_target_cells(
            kInteriorCell, ER::SELECTOR_OWN_TERRITORY, 32, 1, scanned);
        if (!expect(scanned == indexed, "territory_fallback_matches_index", error))
            return false;
        if (!expect(rt->country_cell_count(0) == indexed_count,
                    "territory_fallback_count", error)) return false;
        if (!expect(rt->country_anchor_cell(1) == indexed_anchor,
                    "territory_fallback_anchor", error)) return false;
    }

    // 24. Unowned cells belong to nobody. A negative slot must never appear in
    //     any country's slice, and the counts must drop accordingly.
    fill_snapshot();
    for (int32_t cell = 0; cell < kCells; ++cell)
        rt->_epoch_cell_country[static_cast<size_t>(cell)] =
            (cell % kCols) < kTerrainSplitCol ? 0 : 1;
    for (int32_t col = 0; col < kCols; ++col)
        rt->_epoch_cell_country[static_cast<size_t>(cell_id(0, col))] = -1;
    rt->_epoch_country_count = 2;
    rt->rebuild_country_territory_index();
    if (!expect(rt->country_cell_count(0) == 12, "territory_unowned_left", error))
        return false;
    if (!expect(rt->country_cell_count(1) == 12, "territory_unowned_right", error))
        return false;
    rt->collect_effect_target_cells(
        kInteriorCell, ER::SELECTOR_OWN_TERRITORY, 32, 0, out);
    for (const int32_t cell : out) {
        if (!expect((cell % kCols) < kTerrainSplitCol,
                    "territory_excludes_unowned_row", error)) return false;
        if (!expect((cell / kCols) != 0,
                    "territory_skips_unowned_cells", error)) return false;
    }
    // A country that owns nothing is a legal state, not an error. Country 0 has
    // been emptied while country 1 now owns the whole grid, so the two answers
    // must differ: 0 cells / no anchor for the empty slot, and the full grid for
    // the slot that actually holds the source cell.
    rt->_epoch_cell_country.assign(static_cast<size_t>(kCells), 1);
    rt->rebuild_country_territory_index();
    if (!expect(rt->country_cell_count(0) == 0, "territory_empty_count", error))
        return false;
    if (!expect(rt->country_anchor_cell(0) == -1, "territory_empty_anchor", error))
        return false;
    if (!expect(rt->country_cell_at(0, 0) == -1, "territory_empty_cell_at", error))
        return false;
    rt->collect_effect_target_cells(
        kInteriorCell, ER::SELECTOR_OWN_TERRITORY, 32, 0, out);
    if (!expect(out.size() == static_cast<size_t>(kCells),
                "territory_single_owner_covers_grid", error)) return false;
    // An unowned source cell has no country to enumerate, so the selector keeps
    // the pre-existing "resolve to the anchor only" contract instead of
    // inventing a territory. This is the only path that still returns the source.
    rt->_epoch_cell_country[static_cast<size_t>(kInteriorCell)] = -1;
    rt->rebuild_country_territory_index();
    rt->collect_effect_target_cells(
        kInteriorCell, ER::SELECTOR_OWN_TERRITORY, 32, 0, out);
    if (!expect(out.size() == 1 && out[0] == kInteriorCell,
                "territory_unowned_source_anchor", error)) return false;

    // 25. Territory is an ownership question, so it must survive a missing
    //     building snapshot. The radial kinds correctly return nothing there;
    //     conflating the two would make territory effects vanish between an
    //     epoch capture and the first building refresh.
    fill_snapshot();
    for (int32_t cell = 0; cell < kCells; ++cell)
        rt->_epoch_cell_country[static_cast<size_t>(cell)] =
            (cell % kCols) < kTerrainSplitCol ? 0 : 1;
    rt->_epoch_country_count = 2;
    rt->rebuild_country_territory_index();
    rt->_building_neighbors.clear();
    rt->_building_terrain.clear();
    rt->_building_is_water.clear();
    rt->_building_has_river.clear();
    rt->collect_effect_target_cells(
        kInteriorCell, ER::SELECTOR_OWN_TERRITORY, 32, 0, out);
    if (!expect(out.size() == 15, "territory_needs_no_building_snapshot", error))
        return false;
    rt->collect_effect_target_cells(
        kInteriorCell, ER::SELECTOR_OWN_TERRITORY, 32, 1, out);
    if (!expect(out.empty(), "territory_predicate_needs_columns", error))
        return false;

    // 26. Determinism: territory must be a pure function of the snapshot too.
    fill_snapshot();
    for (int32_t cell = 0; cell < kCells; ++cell)
        rt->_epoch_cell_country[static_cast<size_t>(cell)] =
            (cell % kCols) < kTerrainSplitCol ? 0 : 1;
    rt->_epoch_country_count = 2;
    rt->rebuild_country_territory_index();
    {
        std::vector<int32_t> reference;
        rt->collect_effect_target_cells(
            kInteriorCell, ER::SELECTOR_OWN_TERRITORY, 32, 0, reference);
        for (int32_t repeat = 0; repeat < 100; ++repeat) {
            rt->collect_effect_target_cells(
                kInteriorCell, ER::SELECTOR_OWN_TERRITORY, 32, 0, out);
            if (!expect(out == reference, "territory_deterministic", error))
                return false;
        }
    }

    // 27-29. Degenerate snapshots degrade to "no targets" instead of crashing
    //        or indexing past the end of a shorter column.
    fill_snapshot();
    rt->_building_neighbors.clear();
    rt->collect_effect_target_cells(kInteriorCell, ER::SELECTOR_NEIGHBORS_R1, 0, 0, out);
    if (!expect(out.empty(), "selector_missing_neighbors", error)) return false;

    fill_snapshot();
    rt->_building_terrain.clear();
    rt->collect_effect_target_cells(
        kInteriorCell, ER::SELECTOR_SAME_TERRAIN_COMPONENT, 8, 0, out);
    if (!expect(out.empty(), "selector_missing_terrain_column", error)) return false;

    // Out-of-range sources never yield a cell, including the cell_count edge.
    fill_snapshot();
    for (const int32_t bad : {-7, -1, kCells, kCells + 9}) {
        rt->collect_effect_target_cells(bad, ER::SELECTOR_NEIGHBORS_R1, 0, 0, out);
        if (!expect(out.empty(), "selector_source_out_of_range", error)) return false;
    }

    return true;
}

} // namespace pk
