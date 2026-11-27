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
#include "economy_runtime_test_access.h"
#include "effect_runtime.h"
#include "effect_selector_cap.h"
#include "selector_ownership.h"

#include <algorithm>
#include <array>
#include <chrono>
#include <cstdio>
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
// Q16 one. Tag thresholds are uniformly Q16 (see target_tag.h), including ids
// and counts, so every assertion below states its threshold in this unit.
constexpr int64_t kQ16One = 65536;

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
    bool tag_work_matches = true;
    if (!run_country_epoch_cache(error)) return false;
    if (!run_building_chain_metrics(error)) return false;
    if (!run_building_investment_review(error)) return false;
    if (!run_golden_population_market(error)) return false;
    if (!run_owned_stock_audit(error)) return false;
    if (!run_producer_continuation(error)) return false;

    // P2-B: the cap keeps a KEYED subset, not the lowest ids. Asserted on the
    // helper directly -- planting 40 tag-matching cells needs a tag table this
    // fixture does not have, and the property under test belongs to the helper.
    {
        std::vector<int32_t> many;
        for (int32_t cell = 0; cell < 40; ++cell) many.push_back(cell);
        EffectSelectorStats stats;
        std::vector<int32_t> capped = many;
        effect_stable_cap(capped, 32, 7, 99, &stats);
        if (!expect(capped.size() == 32, "selector_cap_size", error)) return false;
        if (!expect(stats.matched_total == 40, "selector_cap_matched_total", error))
            return false;
        if (!expect(stats.truncated == 1, "selector_cap_truncated_flag", error))
            return false;
        if (!expect(std::is_sorted(capped.begin(), capped.end()),
                    "selector_cap_keeps_id_order", error)) return false;
        // "The lowest 32 ids" is exactly what this replaced. A good hash lands
        // on it with probability ~1/7.7e7, so this is not a coin flip.
        if (!expect(!(capped.front() == 0 && capped.back() == 31),
                    "selector_cap_not_lowest_ids", error)) return false;
        std::vector<int32_t> again = many;
        EffectSelectorStats again_stats;
        effect_stable_cap(again, 32, 7, 99, &again_stats);
        if (!expect(again == capped, "selector_cap_deterministic", error))
            return false;
        std::vector<int32_t> under = many;
        EffectSelectorStats under_stats;
        effect_stable_cap(under, 64, 7, 99, &under_stats);
        if (!expect(under.size() == 40, "selector_cap_no_truncation_when_under",
                    error)) return false;
        if (!expect(under_stats.truncated == 0,
                    "selector_cap_no_flag_when_under", error)) return false;
    }

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

    // ── Ownership scope for a source fan-out (plan 22, M5-5/M5-6) ──────────────
    //
    // The fan-out used to be ownership-blind, so a "周围地块" card reached foreign
    // cells across a border. This is where that can actually be MEASURED: the fixture
    // owns the hex neighbour table and `_epoch_cell_country`, so a real ring can be
    // produced and split by real ownership.
    //
    // What this pins:
    //   1. the UNFILTERED ring really does straddle a country border (otherwise every
    //      scope would agree and the feature would be untestable);
    //   2. `pk::ownership_accepts` partitions that ring exactly, so OWN + FOREIGN == ANY;
    //   3. the DEFAULT decodes to OWN, so a card that names no scope stays home.
    {
        // Two countries, split down the middle column of the fixture grid.
        rt->_epoch_cell_country.assign(static_cast<size_t>(kCells), 0);
        for (int32_t cell = 0; cell < kCells; ++cell)
            if ((cell % kCols) >= kTerrainSplitCol)
                rt->_epoch_cell_country[static_cast<size_t>(cell)] = 1;
        rt->_epoch_country_count = 2;
        const int32_t border_source = kInteriorRow * kCols + (kTerrainSplitCol - 1);

        std::vector<int32_t> ring;
        rt->collect_effect_target_cells(border_source, ER::SELECTOR_NEIGHBORS_R2, 0, 0,
                                        ring);
        if (!expect(!ring.empty(), "ownership_ring_non_empty", error)) return false;

        // 1. The ring must contain BOTH countries, or the rest proves nothing.
        int32_t raw_own = 0;
        int32_t raw_foreign = 0;
        for (const int32_t cell : ring) {
            const bool is_own =
                rt->_epoch_cell_country[static_cast<size_t>(cell)] == 0;
            if (is_own) ++raw_own; else ++raw_foreign;
        }
        if (!expect(raw_own > 0 && raw_foreign > 0,
                    "ownership_ring_straddles_the_border", error)) {
            return false;
        }

        // 2. The predicate must partition the ring exactly.
        int32_t own_kept = 0;
        int32_t foreign_kept = 0;
        int32_t any_kept = 0;
        for (const int32_t cell : ring) {
            const bool is_own =
                rt->_epoch_cell_country[static_cast<size_t>(cell)] == 0;
            if (pk::ownership_accepts(pk::OWNERSHIP_OWN, is_own)) ++own_kept;
            if (pk::ownership_accepts(pk::OWNERSHIP_FOREIGN, is_own)) ++foreign_kept;
            if (pk::ownership_accepts(pk::OWNERSHIP_ANY, is_own)) ++any_kept;
        }
        if (!expect(own_kept == raw_own && foreign_kept == raw_foreign,
                    "ownership_predicate_matches_country_split", error)) {
            return false;
        }
        if (!expect(own_kept + foreign_kept == any_kept &&
                    any_kept == static_cast<int32_t>(ring.size()),
                    "ownership_own_plus_foreign_partitions_any", error)) {
            return false;
        }
        // 3. The whole change: OWN must actually DROP cells here.
        if (!expect(own_kept < any_kept, "ownership_own_drops_foreign_cells", error))
            return false;

        // The DEFAULT must be OWN: a param that carries only a cap.
        if (!expect(pk::decode_ownership_scope(32) == pk::OWNERSHIP_OWN,
                    "ownership_default_is_own", error)) return false;

        // ── Magnitude of the default-value change ────────────────────────────
        //
        // "The cards get smaller" is not a number a balance reviewer can use. This
        // sweeps every interior cell as a source, splits its own ring by ownership, and
        // reports the FOREIGN share -- i.e. how much of a fan-out the new OWN default
        // removes at a border, which is the worst case for the change.
        //
        // Reported, not asserted: the exact share depends on the map and the source
        // position, and pinning it here would turn a content question into a brittle
        // constant.
        int64_t total_ring = 0;
        int64_t total_foreign = 0;
        int32_t worst_foreign = 0;
        for (int32_t row = 1; row < kRows - 1; ++row) {
            for (int32_t col = 1; col < kCols - 1; ++col) {
                std::vector<int32_t> sweep;
                rt->collect_effect_target_cells(row * kCols + col,
                                                ER::SELECTOR_NEIGHBORS_R2, 0, 0, sweep);
                int32_t foreign_here = 0;
                for (const int32_t cell : sweep) {
                    ++total_ring;
                    if (rt->_epoch_cell_country[static_cast<size_t>(cell)] != 0) {
                        ++total_foreign;
                        ++foreign_here;
                    }
                }
                if (foreign_here > worst_foreign) worst_foreign = foreign_here;
            }
        }
        if (!expect(total_ring > 0, "ownership_sweep_has_cells", error)) return false;
        // Surface the number rather than hiding it in a local: a reviewer needs to see
        // "the new default removes N% of a border fan-out".
        std::printf(
            "[ownership] R2 ring sweep: %lld of %lld cells foreign (%.1f%%), "
            "worst single ring %d foreign\n",
            static_cast<long long>(total_foreign),
            static_cast<long long>(total_ring),
            total_ring == 0 ? 0.0
                            : 100.0 * static_cast<double>(total_foreign) /
                                  static_cast<double>(total_ring),
            worst_foreign);
        // The change must MATTER: if no ring ever crossed the border, the new default
        // would be a no-op and the whole item would have been unnecessary.
        if (!expect(total_foreign > 0,
                    "ownership_sweep_finds_foreign_cells", error)) return false;
    }


    // ── Ring-walk cost after the source cap was removed (2026-10-28) ──────────
    //
    // Removing the 32-source cap multiplies the number of RING WALKS by the country's
    // tagged cell count (32 -> N). Measuring the source collection alone is not enough:
    // that part actually got FASTER (the stable-hash truncation is skipped), so the
    // entire cost of the change lives here, one walk per source.
    //
    // This fixture owns a real hex neighbour table, so the walks here are the same shape
    // the production path performs. The number is REPORTED, not asserted: a wall-clock
    // threshold would be a claim about the machine, not about correctness. The single
    // assertion is a loose sanity bound that catches "a walk became catastrophically
    // slow", which is the only failure mode worth failing on.
    {
        constexpr int32_t kWalkIterations = 2000;
        std::vector<int32_t> walk_out;
        // Warm up: the first calls pay branch-cache misses and were what made earlier
        // single-shot measurements unusable.
        for (int32_t i = 0; i < 200; ++i)
            rt->collect_effect_target_cells(kInteriorCell, ER::SELECTOR_NEIGHBORS_R1, 0, 0,
                                            walk_out);
        const auto walk_start = std::chrono::steady_clock::now();
        for (int32_t i = 0; i < kWalkIterations; ++i)
            rt->collect_effect_target_cells(kInteriorCell, ER::SELECTOR_NEIGHBORS_R1, 0, 0,
                                            walk_out);
        const auto walk_end = std::chrono::steady_clock::now();
        const double total_us =
            std::chrono::duration<double, std::micro>(walk_end - walk_start).count();
        const double per_walk_us = total_us / static_cast<double>(kWalkIterations);
        // The two source counts that matter: the old cap, and a 1600-cell country.
        const double capped_us = per_walk_us * 32.0;
        const double uncapped_us = per_walk_us * 1600.0;
        std::printf(
            "[ringwalk] R1 walk: %.3f us/walk over %d iterations -> "
            "32 sources %.1f us, 1600 sources %.1f us (%.0fx)\n",
            per_walk_us, kWalkIterations, capped_us, uncapped_us,
            32.0 > 0.0 ? uncapped_us / (capped_us == 0.0 ? 1.0 : capped_us) : 0.0);
        if (!expect(!walk_out.empty(), "ringwalk_produces_cells", error)) return false;
        // A single R1 walk over a 6-neighbour cell must be far under a millisecond on any
        // machine this runs on; 100 us is loose by two orders of magnitude on purpose.
        if (!expect(per_walk_us < 100.0, "ringwalk_per_call_is_not_absurd", error))
            return false;
    }

    // ── per-source loop vs batch dilation (2026-10-28) ───────────────────────
    //
    // Removing the source cap turned a 32-iteration fan-out into one iteration per
    // tagged cell. The old shape called `collect_effect_target_cells` once per source,
    // and that call allocates AND ZEROES a `cells`-sized `seen` buffer every time
    // (`economy_runtime_family_buff.cpp:2663`) -- so the cost was O(sources x cells), not
    // O(sources x 6). `dilate_cell_set` replaces it with one pass and a stamp buffer.
    //
    // Both are measured HERE, on the SAME grid and neighbour table, so the ratio is a
    // property of the implementations rather than of two different fixtures.
    {
        constexpr int32_t kIterations = 400;
        std::vector<int32_t> all_cells;
        all_cells.reserve(static_cast<size_t>(kCells));
        for (int32_t c = 0; c < kCells; ++c) all_cells.push_back(c);

        std::vector<int32_t> loop_out;
        std::vector<int32_t> ring_scratch;
        // Warm up both paths before timing either.
        for (int32_t i = 0; i < 5; ++i) {
            loop_out.clear();
            for (const int32_t source : all_cells) {
                ring_scratch.clear();
                rt->collect_effect_target_cells(source, ER::SELECTOR_NEIGHBORS_R1, 0, 0,
                                                ring_scratch);
                loop_out.insert(loop_out.end(), ring_scratch.begin(), ring_scratch.end());
            }
            std::vector<int32_t> warm_dilated;
            rt->dilate_cell_set(all_cells, 1, warm_dilated);
        }

        const auto loop_start = std::chrono::steady_clock::now();
        for (int32_t i = 0; i < kIterations; ++i) {
            loop_out.clear();
            for (const int32_t source : all_cells) {
                ring_scratch.clear();
                rt->collect_effect_target_cells(source, ER::SELECTOR_NEIGHBORS_R1, 0, 0,
                                                ring_scratch);
                loop_out.insert(loop_out.end(), ring_scratch.begin(), ring_scratch.end());
            }
        }
        const auto loop_end = std::chrono::steady_clock::now();

        std::vector<int32_t> batch_out;
        const auto batch_start = std::chrono::steady_clock::now();
        for (int32_t i = 0; i < kIterations; ++i)
            rt->dilate_cell_set(all_cells, 1, batch_out);
        const auto batch_end = std::chrono::steady_clock::now();

        const double loop_us = std::chrono::duration<double, std::micro>(
            loop_end - loop_start).count() / static_cast<double>(kIterations);
        const double batch_us = std::chrono::duration<double, std::micro>(
            batch_end - batch_start).count() / static_cast<double>(kIterations);
        std::printf(
            "[dilate] %d sources on a %d-cell grid: per-source loop %.2f us, "
            "batch %.2f us (%.2fx)\n",
            kCells, kCells, loop_us, batch_us,
            batch_us == 0.0 ? 0.0 : loop_us / batch_us);

        // The batch path must produce the same UNION the loop does. Comparing sorted
        // sets (not raw order) is the right check: the loop appends per source and the
        // batch sorts once, so order genuinely differs while the set must not.
        std::vector<int32_t> loop_sorted = loop_out;
        std::sort(loop_sorted.begin(), loop_sorted.end());
        loop_sorted.erase(std::unique(loop_sorted.begin(), loop_sorted.end()),
                          loop_sorted.end());
        if (!expect(loop_sorted == batch_out, "dilate_matches_per_source_union", error)) {
            return false;
        }
        if (!expect(!batch_out.empty(), "dilate_produces_cells", error)) return false;
        // Sanity only: a batch dilation of the whole small grid must not be slower than
        // the loop it replaced on the same data.
        if (!expect(batch_us <= loop_us * 1.5 + 1.0,
                    "dilate_is_not_slower_than_the_loop", error)) return false;
    }

    // T11: kind 16's two-int packed layout. The GDScript side has its own
    // implementation on purpose; this pins the C++ bit positions and the
    // documented boundary values so either side drifting fails by name.
    {
        const int32_t boundary[2] = {
            ((31 & 0x1F) | ((4 & 0x07) << 5) | ((15 & 0x0F) << 8)),
            65535};
        const ER::SourceCountSelector decoded =
            ER::decode_source_count_selector(boundary);
        if (!expect(decoded.target_cap == 31, "source_count_pack_cap_31",
                    error)) return false;
        if (!expect(decoded.radius == 4, "source_count_pack_radius_4",
                    error)) return false;
        if (!expect(decoded.cap == 15, "source_count_pack_count_15",
                    error)) return false;
        if (!expect(decoded.tag == 65535, "source_count_pack_tag_65535",
                    error)) return false;
        // An UNAUTHORED target cap means "no cell limit", not "32".
        //
        // This assertion used to require 32 (`source_count_pack_zero_is_default_32`),
        // which documented the very defect that silently truncated all 66 kind-16 cards
        // to 32 target cells. The expectation is inverted here, and the name says why.
        const int32_t default_cap[2] = {((2 & 0x07) << 5), 1};
        const ER::SourceCountSelector zero_cap =
            ER::decode_source_count_selector(default_cap);
        if (!expect(zero_cap.target_cap == pk::kSelectorNoCellCap,
                    "source_count_pack_zero_is_unbounded", error)) return false;
        // The decoder and the declared ceiling must never disagree again: they are two
        // representations of the same fact, and their disagreement is what produced the
        // silent 32-cell cap. Pin them together.
        if (!expect(pk::selector_cell_ceiling(ER::SELECTOR_TAG_SOURCE_COUNT) ==
                        pk::kSelectorNoCellCap,
                    "source_count_ceiling_is_unbounded", error)) return false;
        // An AUTHORED cap must still be honoured -- the fix removes the default, not the
        // feature.
        // THE PRODUCTION VALUE. All 66 kind-16 cards author `param0 = 800`, whose low
        // five bits are 0 -- so this exact input is what every shipped card decodes to.
        // It must be UNBOUNDED; while it decoded to 32, `effect_stable_cap` truncated
        // every one of those cards' target sets to 32 cells.
        const int32_t production_16[2] = {800, 1};
        const ER::SourceCountSelector production_decoded =
            ER::decode_source_count_selector(production_16);
        if (!expect(production_decoded.target_cap == pk::kSelectorNoCellCap,
                    "source_count_production_800_is_unbounded", error)) return false;
        if (!expect(production_decoded.radius == 1,
                    "source_count_production_800_radius_1", error)) return false;
        if (!expect(production_decoded.cap == 3,
                    "source_count_production_800_source_cap_3", error)) return false;
        const int32_t authored_cap[2] = {(7 & 0x1F), 1};
        if (!expect(ER::decode_source_count_selector(authored_cap).target_cap == 7,
                    "source_count_authored_cap_honoured", error)) return false;
    }

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

#include "economy_runtime_effect_selector_tests_territory.inc"
#include "economy_runtime_effect_selector_tests_tag_predicates.inc"
#include "economy_runtime_effect_selector_tests_consumer_narrowing.inc"
    // ── Plan 22 §13.4 `unbounded`: 31 / 32 / 33 / 200 / 1000+ ──────────────
    //
    // The migration's central promise is that a territory card covers the WHOLE
    // territory, not the first 32 cells. Everything up to here exercised the
    // selector at or below the old cap, so this block is the only place the
    // 33..N range is asserted against the REAL selector.
    //
    // It goes through `collect_effect_target_cells` rather than a synthetic cap
    // helper because the promise is about the shipping path, and the old bug was
    // precisely a cap applied inside that path.
    {
        // A country owning `n` cells, anchored so the walk has somewhere to start.
        const auto territory_of = [&](int32_t n) -> std::unique_ptr<NativeEconomyRuntime> {
            auto rt2 = std::make_unique<NativeEconomyRuntime>();
            // NOT `kCells`: that fixture grid is 6x5 = 30 cells, which cannot
            // express 200 or 1000. The unbounded block needs its own size.
            constexpr int32_t kBigCells = 2400;
            rt2->_cell_count = kBigCells;
            rt2->_building_neighbors.assign(static_cast<size_t>(kBigCells) * 6, -1);
            rt2->_epoch_cell_country.assign(static_cast<size_t>(kBigCells), -1);
            // Ownership is contiguous from cell 0 so `country_cell_at` order is
            // predictable; the selector sorts anyway, but a predictable fixture
            // makes a failure readable.
            for (int32_t cell = 0; cell < n && cell < kBigCells; ++cell)
                rt2->_epoch_cell_country[static_cast<size_t>(cell)] = 0;
            rt2->_epoch_country_count = 1;
            rt2->rebuild_country_territory_index();
            return rt2;
        };

        for (const int32_t n : {31, 32, 33, 200}) {
            auto rt2 = territory_of(n);
            std::vector<int32_t> got;
            // param0 = 0 means "the kind's own default", which for a territory
            // query is now the whole territory (M2-5).
            rt2->collect_effect_target_cells(0, ER::SELECTOR_OWN_TERRITORY, 0, 0, got);
            if (!expect(static_cast<int32_t>(got.size()) == n,
                        "unbounded_territory_count", error)) return false;
            // And an explicit oversized author is not clamped to 32 either.
            std::vector<int32_t> explicit_cap;
            rt2->collect_effect_target_cells(
                0, ER::SELECTOR_OWN_TERRITORY, 1000, 0, explicit_cap);
            if (!expect(static_cast<int32_t>(explicit_cap.size()) == n,
                        "unbounded_explicit_cap", error)) return false;
            // Sorted + unique is the contract every caller relies on.
            if (!expect(std::is_sorted(explicit_cap.begin(), explicit_cap.end()),
                        "unbounded_sorted", error)) return false;
            if (!expect(std::adjacent_find(explicit_cap.begin(),
                        explicit_cap.end()) == explicit_cap.end(),
                        "unbounded_unique", error)) return false;
        }

        // 1000+ cells: the grid is 60x40 = 2400, so 1000 is a large but legal
        // territory. This is the size §13.2 names as impossible to validate by
        // diffing two worlds.
        auto big = territory_of(1000);
        std::vector<int32_t> many;
        big->collect_effect_target_cells(0, ER::SELECTOR_OWN_TERRITORY, 0, 0, many);
        if (!expect(static_cast<int32_t>(many.size()) == 1000,
                    "unbounded_1000_count", error)) return false;
        // The old cap must be gone, not merely raised: the 33rd cell specifically.
        if (!expect(contains(many, 32), "unbounded_includes_old_cap_boundary",
                    error)) return false;
        if (!expect(contains(many, 999), "unbounded_includes_last_cell",
                    error)) return false;
        // An explicit author of 32 still gets 32: the migration removed the
        // DEFAULT cap, not the ability to ask for one (M2-5 §4).
        std::vector<int32_t> asked_32;
        big->collect_effect_target_cells(
            0, ER::SELECTOR_OWN_TERRITORY, 32, 0, asked_32);
        if (!expect(static_cast<int32_t>(asked_32.size()) == 32,
                    "unbounded_explicit_32_respected", error)) return false;
        // A map smaller than the territory cannot yield more cells than it has;
        // "no policy cap" must not become "no limit at all" (plan §1.1).
        std::vector<int32_t> capped_by_map;
        big->collect_effect_target_cells(
            0, ER::SELECTOR_OWN_TERRITORY, 5000, 0, capped_by_map);
        if (!expect(static_cast<int32_t>(capped_by_map.size()) == 1000,
                    "unbounded_map_is_outer_limit", error)) return false;
    }

    return expect(tag_work_matches, "tag_consumer_work_matches_requested_metrics", error);
}

} // namespace pk
