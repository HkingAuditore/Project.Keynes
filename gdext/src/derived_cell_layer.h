#pragma once
#include <algorithm>
#include <cstdint>
#include <unordered_map>
#include <vector>

namespace pk {

// ---------------------------------------------------------------------------
// Derived cell layer (plan 22 ADR01/ADR02, M1).
//
// ADR01 puts the derived contribution in ModifierRuntime so every internal
// reader shares one formula. ADR02 forbids putting it in the instance Store,
// because `apply_pod_snapshot` rebuilds the whole store from scratch
// (`modifier_runtime.cpp:459-557`) and clears the legacy queue (`:558`) -- a
// derived row living there would be wiped on every worker snapshot.
//
// So this is a SEPARATE, immutable-after-install value object:
//   * `install()` publishes a candidate front atomically;
//   * readers only ever see a whole front, never a half-built one;
//   * `clear()` is the only way to empty it, and nothing in the snapshot path
//     calls it.
//
// STORAGE (plan §8.2 decision, M0-7): `stat -> sorted (cell, contribution)`
// rather than a flat `(stat, cell)` hash. The reader pattern is "given a cell,
// ask 156 different stats" (`refresh_city_modifier_factors`,
// `economy_runtime.cpp:7085-7095`), and `collect_scope_ids` needs
// "which cells have any contribution for this stat" -- both are ordered scans
// per stat. A flat hash would need a full key sweep for the second question,
// which is exactly the cost the plan's §14.1 table forbids.
// ---------------------------------------------------------------------------

// One (source country, stat, cell) contribution.
//
// Kept per SOURCE country, not merged into the target cell, because plan §8.1
// requires correct undoing when a country unequips or loses territory. Two
// source countries affecting the same cell and stat must MULTIPLY their
// factors, not add -- merging them would lose that.
struct DerivedCellContribution {
    uint64_t source_country = 0;   // generation-bearing country handle
    // How many DISTINCT source countries contributed to this (stat, cell).
    //
    // A border target can be covered by two countries' cards. The VALUE is the fold
    // of both, so this is the only way to tell "one country" from "two countries
    // agreeing", and the only way to see a revocation: the count drops while the
    // value may not move at all. Two sources contributing 0.5 + 0.5 and one
    // contributing 1.0 resolve identically, but only the first disappears when one
    // of them is revoked.
    uint32_t contributor_count = 0;
    // ADD term sum and factor product are kept separately, mirroring
    // ModifierRuntime::Bucket, so the final formula can be applied once at the
    // end (plan §5.1: `clamp((base + add_total) * factor_total)`).
    double sum_add = 0.0;
    double product_nonzero = 1.0;
    uint32_t zero_factor_count = 0;
};

// Sorted-by-cell row for one stat.
struct DerivedCellStatRow {
    int32_t stat_id = -1;
    // Ascending cell ids; parallel to `contributions`.
    std::vector<int32_t> cells;
    // One entry per cell, already folded over that cell's source countries.
    std::vector<DerivedCellContribution> contributions;

    bool empty() const { return cells.empty(); }

    // Binary search. Returns nullptr when the cell has no derived contribution,
    // which callers must treat as "no derived term", never as a zero factor.
    const DerivedCellContribution *find(int32_t cell) const {
        const auto it = std::lower_bound(cells.begin(), cells.end(), cell);
        if (it == cells.end() || *it != cell) return nullptr;
        return &contributions[static_cast<size_t>(it - cells.begin())];
    }
};

// An immutable published front. Copying one is cheap: the rows are shared by
// value only during construction and never mutated after `install()`.
struct DerivedCellFront {
    uint64_t world_identity = 0;
    uint64_t map_generation = 0;
    uint64_t generation = 0;          // bumped on every successful install
    int64_t sample_day = -1;
    uint64_t epoch_id = 0;
    uint64_t execution_contract_hash = 0;
    // Ascending by stat_id so readers can binary-search the stat too.
    std::vector<DerivedCellStatRow> rows;
    // Per-stat version, indexed by stat id. Independent of the legacy
    // `Store::stat_versions` because `apply_pod_snapshot` bumps those
    // unconditionally (`modifier_runtime.cpp:463-464`) -- keying a derived cache
    // on them would rebuild every day even when nothing changed (plan §7.4).
    std::vector<uint64_t> stat_versions;

    bool empty() const { return rows.empty(); }

    // Content digest over (stat, cell, add, factor, zero_count). Used to make a
    // re-install of identical results a no-op (plan I13), so an unchanged world
    // does not bump `layer_stat_version` and does not look like work (§7.4).
    //
    // Deliberately excludes `generation` and `sample_day`: those advance for
    // reasons that are not semantic change, and including them would defeat the
    // whole purpose.
    uint64_t content_digest() const {
        uint64_t hash = 1469598103934665603ULL;
        const auto mix = [&hash](uint64_t value) {
            hash = (hash ^ value) * 1099511628211ULL;
        };
        mix(static_cast<uint64_t>(rows.size()));
        for (const DerivedCellStatRow &row : rows) {
            mix(static_cast<uint64_t>(static_cast<uint32_t>(row.stat_id)));
            mix(static_cast<uint64_t>(row.cells.size()));
            for (size_t i = 0; i < row.cells.size(); ++i) {
                mix(static_cast<uint64_t>(
                    static_cast<uint32_t>(row.cells[i])));
                const DerivedCellContribution &c = row.contributions[i];
                // Bit-cast through memcpy-free unions is unnecessary: doubles are
                // compared by value elsewhere, and two equal doubles hash equal.
                const uint64_t add_bits = static_cast<uint64_t>(
                    static_cast<int64_t>(c.sum_add * 1000000.0));
                const uint64_t factor_bits = static_cast<uint64_t>(
                    static_cast<int64_t>(c.product_nonzero * 1000000.0));
                mix(add_bits);
                mix(factor_bits);
                mix(static_cast<uint64_t>(c.zero_factor_count));
            }
        }
        return hash;
    }

    const DerivedCellStatRow *row_for_stat(int32_t stat_id) const {
        const auto it = std::lower_bound(
            rows.begin(), rows.end(), stat_id,
            [](const DerivedCellStatRow &row, int32_t value) {
                return row.stat_id < value;
            });
        if (it == rows.end() || it->stat_id != stat_id) return nullptr;
        return &*it;
    }
};

// Bytes held by one front's structure: per-row cell ids, per-cell contributions and the
// per-stat version vector.
//
// ONE definition, used by both the report and the peak tracker. The formula used to live
// inline in `world_ext_modifier.cpp`; a second copy would be free to drift, which is the
// exact failure mode that produced the kind-16 and territory-count defects.
//
// These are BYTES OF THE STRUCTURE, not process RSS. Read it as "the derived layer costs
// this much", never as "the game costs this much".
inline int64_t derived_cell_front_bytes(const DerivedCellFront &front) {
    int64_t total = 0;
    for (const DerivedCellStatRow &row : front.rows) {
        total += static_cast<int64_t>(row.cells.size()) *
                 static_cast<int64_t>(sizeof(int32_t));
        total += static_cast<int64_t>(row.contributions.size()) *
                 static_cast<int64_t>(sizeof(DerivedCellContribution));
        total += static_cast<int64_t>(sizeof(DerivedCellStatRow));
    }
    total += static_cast<int64_t>(front.stat_versions.size()) *
             static_cast<int64_t>(sizeof(uint64_t));
    return total;
}

// Builder -> front. Kept separate from the front so a partially built candidate
// can be discarded without publishing anything (plan §8.2 step 4, §9.6).
class DerivedCellFrontBuilder {
public:
    void reset(uint64_t world_identity, uint64_t map_generation, int64_t sample_day,
               uint64_t epoch_id, uint64_t execution_contract_hash) {
        _front = DerivedCellFront{};
        // `_index` maps stat -> position in `_front.rows`; leaving it populated
        // after clearing the rows makes every subsequent `_row()` return a stale
        // pointer position and the fresh candidate silently loses its content.
        // (Caught by `test_reset_discards_candidate`.)
        _index.clear();
        _front.world_identity = world_identity;
        _front.map_generation = map_generation;
        _front.sample_day = sample_day;
        _front.epoch_id = epoch_id;
        _front.execution_contract_hash = execution_contract_hash;
        _open = true;
        _dirty = false;
    }

    bool open() const { return _open; }

    // Adds or folds one contribution. Folding is by (stat, cell, source): a
    // second contribution from the SAME source country for the same (stat, cell)
    // multiplies/accumulates into the existing row rather than creating a
    // duplicate, which is what makes re-materialising idempotent (plan I13).
    //
    // Returns false when the builder is closed, so a caller that forgets
    // `reset()` fails visibly instead of silently writing into a published front.
    bool add(int32_t stat_id, int32_t cell, uint64_t source_country,
             double add, double factor, uint32_t contributor_count = 0) {
        if (!_open || stat_id < 0 || cell < 0) return false;
        DerivedCellStatRow &row = _row(stat_id);
        // `cells` is kept sorted; the common case during one materialise pass is
        // an append, so check the tail first before paying for a lower_bound.
        size_t index;
        if (row.cells.empty() || row.cells.back() < cell) {
            row.cells.push_back(cell);
            row.contributions.push_back(DerivedCellContribution{});
            index = row.cells.size() - 1;
        } else {
            const auto it = std::lower_bound(row.cells.begin(), row.cells.end(), cell);
            index = static_cast<size_t>(it - row.cells.begin());
            if (it == row.cells.end() || *it != cell) {
                row.cells.insert(it, cell);
                row.contributions.insert(
                    row.contributions.begin() + static_cast<ptrdiff_t>(index),
                    DerivedCellContribution{});
            }
        }
        DerivedCellContribution &slot = row.contributions[index];
        // A row that already holds a different source keeps accumulating into the
        // same folded slot; per-source undo needs per-source rows, which is the M2
        // replacement path, not this builder.
        //
        // Provenance is FIRST-WRITER-WINS. Overwriting it made a border cell report
        // whichever country happened to be folded last, so B10 could not tell "two
        // countries agree here" from "one country".
        if (slot.source_country == 0) {
            slot.source_country = source_country;
        } else if (source_country != 0 && slot.source_country != source_country) {
            ++slot.contributor_count;
        }
        // The caller's own count wins when supplied, because it was measured over the
        // real fold (where one program may contribute twice to the same cell).
        if (contributor_count > slot.contributor_count)
            slot.contributor_count = contributor_count;
        if (slot.contributor_count == 0) slot.contributor_count = 1;
        slot.sum_add += add;
        if (factor == 0.0) {
            ++slot.zero_factor_count;
        } else {
            slot.product_nonzero *= factor;
        }
        _dirty = true;
        return true;
    }

    // Marks a stat's version as changed. Called once per stat that received any
    // contribution, so the front's per-stat version reflects real content change
    // rather than "the builder ran".
    void bump_stat_version(int32_t stat_id) {
        if (!_open || stat_id < 0) return;
        auto &versions = _front.stat_versions;
        if (static_cast<size_t>(stat_id) >= versions.size()) {
            versions.resize(static_cast<size_t>(stat_id) + 1, 0);
        }
        ++versions[static_cast<size_t>(stat_id)];
        _dirty = true;
    }

    // True when anything was added since `reset()`. An empty builder must NOT
    // produce a generation bump: plan §7.4 requires zero installs and zero layer
    // version bumps on an idle day.
    bool dirty() const { return _dirty; }

    // Publishes. Closes the builder; a second call without `reset()` returns
    // false rather than silently republishing.
    bool install(DerivedCellFront &out) {
        if (!_open) return false;
        if (!_dirty) {
            // Nothing was added since `reset()`: leave `out` untouched and report
            // "nothing installed". The caller distinguishes this from a failure.
            //
            // The builder stays OPEN. Closing it here would make every later
            // `add()` a silent no-op, so a candidate that first materialised
            // zero rows (a legitimate empty selector result) could never be
            // rebuilt without noticing. (Caught by
            // `test_reset_discards_candidate`.)
            return false;
        }
        // Sort rows by stat so `row_for_stat` can binary-search.
        std::sort(_front.rows.begin(), _front.rows.end(),
                  [](const DerivedCellStatRow &a, const DerivedCellStatRow &b) {
                      return a.stat_id < b.stat_id;
                  });
        // Drop rows that ended up with no cells (stat requested but no target).
        _front.rows.erase(
            std::remove_if(_front.rows.begin(), _front.rows.end(),
                           [](const DerivedCellStatRow &row) {
                               return row.cells.empty();
                           }),
            _front.rows.end());
        out = std::move(_front);
        _front = DerivedCellFront{};
        _open = false;
        _dirty = false;
        return true;
    }

private:
    DerivedCellStatRow &_row(int32_t stat_id) {
        auto it = _index.find(stat_id);
        if (it != _index.end()) return _front.rows[it->second];
        const size_t position = _front.rows.size();
        DerivedCellStatRow row;
        row.stat_id = stat_id;
        _front.rows.push_back(std::move(row));
        _index[stat_id] = position;
        return _front.rows[position];
    }

    DerivedCellFront _front;
    std::unordered_map<int32_t, size_t> _index;  // stat -> position in _front.rows
    bool _open = false;
    bool _dirty = false;
};

} // namespace pk
