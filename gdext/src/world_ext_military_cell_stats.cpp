// Military -> derived-cell-layer feed (docs/plans/military-system-design.md §17.1).
//
// §17.1 channel A/C cards are authored with the SAME trigger + effect machinery
// the land cards already use:
//
//   * channel A ("地块光环") is a managed ideology Effect program whose target
//     selector is OWN_TERRITORY / TAG_ANY_CELL / TAG_SOURCE_COUNT over the cell
//     tag dictionary (`target_tag.h`), emitting `military.cell.*` Modifier stats
//     into the derived cell layer (`derived_cell_layer.h`);
//   * channel C ("会战事件叠层") is a duration Modifier instance refreshed by a
//     TriggerRuntime rule fed from the Military GameplayEvents 40..47.
//
// Both need Military facts that the engine had no way to express:
//
//   cell tags    cell.barracks / cell.fortified / cell.military_industry /
//                cell.occupied_by_us / cell.occupied_by_enemy
//   country      country.at_war, country.soldier_share_q16
//   per cell     cell.garrison_soldiers
//
// THE SHAPE
// ---------
// Military owns these facts, and the tag dictionary cannot be re-derived by a
// card: a tag is a compiled predicate over Economy metrics, while barracks and
// fortification live in `pk::MilitaryCore`. So this file PUBLISHES the facts:
//
//   set_military_country_metrics(rows)   -> per-country at_war / soldier_share
//   set_military_cell_tags(tags)         -> per-country cell tag bitsets
//   get_military_cell_stat_q16(...)      -> what a `military.cell.*` stat resolved to
//
// The GDScript side (`scripts/military/military_cell_stats_publisher.gd`) reads
// the already-exposed Military snapshots, publishes the rows here once per
// military day, and compiles the tag names into the same dictionary the land
// cards use. A channel-A card therefore needs no new selector kind and a
// channel-C card needs no new Trigger operator.
//
// DELIBERATELY DOES NOT INCLUDE military_core.h. The two things this TU needs
// from the core -- the grid size and per-cell controller -- are already
// published by `get_military_report()` and `get_military_control_snapshot()`,
// and reading them through those bridges keeps this file compilable on its own
// (military_core.h currently fails to compile in isolation: it declares
// `_connected_label` twice with different element types, so every TU that
// includes it is red until its owner fixes it). It also avoids a second reader
// of the private core columns, which is the same reason the facade exists.

#include "world_ext.h"

#include "economy_runtime.h"
#include "modifier_runtime.h"

#include <algorithm>
#include <cstdint>
#include <cstring>
#include <string>
#include <vector>

namespace pk {

using namespace godot;

namespace {

// Cell tag bits published by Military. The ORDER is the ABI visible to
// GDScript through `get_military_cell_tag_cells(tag)`, so these ids must never
// be renumbered: `scripts/military/military_cell_stats_publisher.gd` mirrors
// them and appends to the end.
enum MilitaryCellTagBit : int32_t {
    MIL_TAG_BARRACKS = 0,          // a barracks of any tier stands here
    MIL_TAG_FORTIFIED = 1,         // fortification tier >= 0
    MIL_TAG_MILITARY_INDUSTRY = 2, // an `industry.military` building stands here
    MIL_TAG_OCCUPIED_BY_US = 3,    // enemy-owned cell held by the querier
    MIL_TAG_OCCUPIED_BY_ENEMY = 4, // own cell held by somebody else
    MIL_TAG_GARRISONED = 5,        // a garrison lot is present
    MIL_TAG_BIT_COUNT = 6,
};

constexpr int32_t kMilitaryQ16 = 65536;

uint32_t tag_bit_mask(int32_t tag) {
    if (tag < 0 || tag >= MIL_TAG_BIT_COUNT) return 0;
    return uint32_t{1} << static_cast<uint32_t>(tag);
}

// The stable tag name for a bit. `set_cell_tag_override_for_test` is keyed by
// name, not by id, so this table is the single place the ABI meets the
// dictionary; `target_tag_dictionary.gd` must declare exactly these names.
const char *tag_name_for_bit(int32_t bit) {
    switch (bit) {
        case MIL_TAG_BARRACKS: return "cell.barracks";
        case MIL_TAG_FORTIFIED: return "cell.fortified";
        case MIL_TAG_MILITARY_INDUSTRY: return "cell.military_industry";
        case MIL_TAG_OCCUPIED_BY_US: return "cell.occupied_by_us";
        case MIL_TAG_OCCUPIED_BY_ENEMY: return "cell.occupied_by_enemy";
        case MIL_TAG_GARRISONED: return "cell.garrisoned";
        default: return "";
    }
}

// Grid size as Military sees it, through the already-published report. -1 when
// Military is unconfigured or no terrain has been pushed yet, which the callers
// turn into `military_terrain_missing`.
int64_t military_grid_cells(const DCWorldExt &world) {
    const Dictionary report = const_cast<DCWorldExt &>(world).get_military_report();
    if (!static_cast<bool>(report.get("ok", false))) return -1;
    if (!static_cast<bool>(report.get("has_terrain", false))) return -1;
    return static_cast<int64_t>(report.get("cell_count", -1));
}

} // namespace

// ---------------------------------------------------------------------------
// Country metrics (§17.1 metric row).
// ---------------------------------------------------------------------------
//
// `rows` is one Dictionary per country handle:
//   handle            int  country handle (0 rows are ignored)
//   slot              int  Military country slot
//   at_war            int  0/1 -- the caller's committed answer
//   soldier_share_q16 int  soldiers / (soldiers + population), Q16
//
// Both values are DERIVED and never persisted: after a restore the caller
// republishes them from the restored Military state, and an absent row means
// "not at war, no soldiers", which is the truthful answer for a country the
// core has never opened a slot for rather than an unknown one.
Dictionary DCWorldExt::set_military_country_metrics(const Array &rows) {
    Dictionary out;
    out["ok"] = true;
    if (_military_runtime == nullptr) {
        out["ok"] = false;
        out["reason"] = "military_unavailable";
        return out;
    }
    int64_t at_war_rows = 0;
    int64_t nonzero_share_rows = 0;
    int64_t rejected = 0;
    for (int64_t i = 0; i < rows.size(); ++i) {
        if (rows[i].get_type() != Variant::DICTIONARY) {
            ++rejected;
            continue;
        }
        const Dictionary row = rows[i];
        const int64_t handle = static_cast<int64_t>(row.get("handle", 0));
        const int32_t slot = static_cast<int32_t>(row.get("slot", -1));
        if (handle == 0 || slot < 0) {
            ++rejected;
            continue;
        }
        const bool at_war = static_cast<int32_t>(row.get("at_war", 0)) != 0;
        // A share outside [0, 1] is a caller unit bug rather than a value to
        // clamp silently, so it is clamped AND counted: the report then shows
        // the mistake instead of hiding it behind a plausible 100%.
        const int32_t raw_share =
            static_cast<int32_t>(row.get("soldier_share_q16", 0));
        const int32_t share = std::clamp<int32_t>(raw_share, 0, kMilitaryQ16);
        if (share != raw_share) ++rejected;
        if (at_war) ++at_war_rows;
        if (share > 0) ++nonzero_share_rows;
        _military_country_metrics[handle] = {slot, at_war ? 1 : 0, share};
    }
    out["at_war_rows"] = at_war_rows;
    out["soldier_share_rows"] = nonzero_share_rows;
    out["rejected"] = rejected;
    out["rows"] = static_cast<int64_t>(_military_country_metrics.size());
    return out;
}

// ---------------------------------------------------------------------------
// Cell tags (§17.1 tag row).
// ---------------------------------------------------------------------------
//
// `tags` is one Dictionary per published tag:
//   name    String            stable tag name (cell.barracks, ...)
//   bit     int               0..MIL_TAG_BIT_COUNT-1, the ABI constant above
//   cells   PackedInt32Array  cells carrying the tag
//   owner   PackedInt32Array  optional, parallel to `cells`: the owning
//           Military country slot of each cell. The two OCCUPATION bits need
//           it, because "held by somebody who is not the owner" is only
//           "occupied by us" or "by the enemy" relative to an owner.
//   us      int               the querier's Military country slot; the
//                             occupation bits are resolved against it.
//
// HOW THE TAG REACHES THE SELECTOR
// --------------------------------
// A tag is a compiled predicate over Economy metrics (`target_tag.h`), so the
// union of every tag's metrics is sampled once per cell per epoch. Military
// facts have no Economy metric and cannot get one: the sampler's row count is
// `FAMILY_METRIC_COUNT`, an Economy-owned compile-time constant, and appending
// ids past it would be an Economy catalog change rather than a Military one.
//
// Economy therefore ships the second half of the mechanism already:
// `CellTagOverrideSet` forces one (tag, cell) pair true or false AFTER the
// predicate is evaluated, in the same pass that builds the tag bitset, so the
// bitset and its digest see one consistent answer. That is the documented
// "publisher could not name them" lane, and it is what this file drives.
//
// CONSEQUENCE, stated so it cannot surprise anyone: forcing true means "this
// cell is a barracks cell" REGARDLESS of the predicate. The dictionary entries
// for these tags still carry a metric row (the native table rejects a tag with
// no rows), so the predicate side must read a metric that is always TRUE, and
// the override is what narrows it. `cell.barracks`-style tags are authored
// against `cell.military.garrison_soldiers >= 0`, which is every cell.
Dictionary DCWorldExt::set_military_cell_tags(const Array &tags) {
    Dictionary out;
    out["ok"] = true;
    if (_military_runtime == nullptr) {
        out["ok"] = false;
        out["reason"] = "military_unavailable";
        return out;
    }
    if (_economy_runtime == nullptr) {
        out["ok"] = false;
        out["reason"] = "economy_unavailable";
        return out;
    }
    const int64_t cell_count = military_grid_cells(*this);
    if (cell_count <= 0) {
        out["ok"] = false;
        out["reason"] = "military_terrain_missing";
        return out;
    }
    NativeEconomyRuntime *economy =
        static_cast<NativeEconomyRuntime *>(_economy_runtime);
    // The controller column, read ONCE for the whole publish. It is a sparse
    // snapshot (occupied cells only), so it is inverted into a dense slot row
    // here: the per-tag loops below then ask an array index instead of
    // searching the sparse list per cell, and "controller < 0 means the owner
    // still holds it" becomes the default fill.
    std::vector<int32_t> controller_by_cell;
    {
        const Dictionary control = get_military_control_snapshot();
        if (static_cast<bool>(control.get("ok", false))) {
            controller_by_cell.assign(static_cast<size_t>(cell_count), -1);
            const Variant cells_value = control.get("cells", Variant());
            const Variant slots_value = control.get("controller_slots", Variant());
            if (cells_value.get_type() == Variant::PACKED_INT32_ARRAY &&
                    slots_value.get_type() == Variant::PACKED_INT32_ARRAY) {
                const PackedInt32Array held = cells_value;
                const PackedInt32Array slots = slots_value;
                const int64_t pairs = std::min(held.size(), slots.size());
                for (int64_t i = 0; i < pairs; ++i) {
                    const int32_t cell = held[i];
                    if (cell < 0 || cell >= cell_count) continue;
                    controller_by_cell[static_cast<size_t>(cell)] = slots[i];
                }
            }
        }
    }
    const size_t cells_size = static_cast<size_t>(cell_count);
    if (_military_cell_tag_bits.size() != cells_size) {
        _military_cell_tag_bits.assign(cells_size, 0);
    }
    std::fill(_military_cell_tag_bits.begin(), _military_cell_tag_bits.end(),
        static_cast<uint8_t>(0));
    // The override table is rebuilt from the DENSE bitset this call produces,
    // in two steps: mark every forced-true cell, then force every other cell of
    // each published tag FALSE. Forcing false is what makes the tag mean
    // "Military says so" rather than "the predicate happened to pass": without
    // it a cell whose placeholder metric row matched would be tagged by the
    // predicate and never cleared.
    int64_t published_tags = 0;
    int64_t rejected = 0;
    int64_t forced_true = 0;
    int64_t forced_false = 0;
    std::vector<uint8_t> published;
    published.assign(static_cast<size_t>(MIL_TAG_BIT_COUNT), 0);
    // First pass: resolve the occupation bits against the controller column and
    // fold every tag into the dense per-cell column.
    for (int64_t i = 0; i < tags.size(); ++i) {
        if (tags[i].get_type() != Variant::DICTIONARY) {
            ++rejected;
            continue;
        }
        const Dictionary row = tags[i];
        const int32_t bit = static_cast<int32_t>(row.get("bit", -1));
        const uint32_t mask = tag_bit_mask(bit);
        const Variant cells_value = row.get("cells", Variant());
        if (mask == 0 || cells_value.get_type() != Variant::PACKED_INT32_ARRAY) {
            ++rejected;
            continue;
        }
        const PackedInt32Array cells = cells_value;
        PackedInt32Array owners;
        int32_t us_slot = -1;
        const bool occupation =
            bit == MIL_TAG_OCCUPIED_BY_US || bit == MIL_TAG_OCCUPIED_BY_ENEMY;
        if (occupation) {
            const Variant owners_value = row.get("owner", Variant());
            us_slot = static_cast<int32_t>(row.get("us", -1));
            if (owners_value.get_type() != Variant::PACKED_INT32_ARRAY ||
                    us_slot < 0) {
                ++rejected;
                continue;
            }
            owners = owners_value;
            if (owners.size() != cells.size()) {
                ++rejected;
                continue;
            }
        }
        for (int64_t k = 0; k < cells.size(); ++k) {
            const int32_t cell = cells[k];
            if (cell < 0 || static_cast<size_t>(cell) >= cells_size) continue;
            if (occupation) {
                // `controller_of` is -1 while the owner still holds the cell,
                // which is neither tag: nobody occupies their own land. A
                // controller snapshot that is missing therefore reads as
                // "nobody occupies anything", narrowing the card instead of
                // inventing an occupation.
                if (controller_by_cell.empty()) continue;
                const int32_t controller =
                    controller_by_cell[static_cast<size_t>(cell)];
                if (controller < 0) continue;
                const bool held_by_us = controller == us_slot;
                if (bit == MIL_TAG_OCCUPIED_BY_US && !held_by_us) continue;
                if (bit == MIL_TAG_OCCUPIED_BY_ENEMY && held_by_us) continue;
            }
            _military_cell_tag_bits[static_cast<size_t>(cell)] |=
                static_cast<uint8_t>(mask);
        }
        published[static_cast<size_t>(bit)] = 1;
        ++published_tags;
    }
    // Second pass: push the dense column into Economy's tag overrides.
    // `set_cell_tag_override_for_test(tag_key, cell, on)` is keyed by the tag's
    // STABLE NAME, so a catalogue whose tag order changed still addresses the
    // same tag -- which is the whole reason ids are not used here.
    for (int32_t bit = 0; bit < MIL_TAG_BIT_COUNT; ++bit) {
        if (published[static_cast<size_t>(bit)] == 0) continue;
        const uint32_t mask = tag_bit_mask(bit);
        const std::string key(tag_name_for_bit(bit));
        if (key.empty()) continue;
        for (size_t cell = 0; cell < cells_size; ++cell) {
            const bool on = (_military_cell_tag_bits[cell] &
                static_cast<uint8_t>(mask)) != 0;
            if (on) ++forced_true; else ++forced_false;
            economy->set_cell_tag_override_for_test(
                key, static_cast<int32_t>(cell), on);
        }
    }
    out["tags"] = published_tags;
    out["rejected"] = rejected;
    out["forced_true"] = forced_true;
    out["forced_false"] = forced_false;
    out["cells"] = cell_count;
    return out;
}

// ---------------------------------------------------------------------------
// Per-cell q16 stat reader.
// ---------------------------------------------------------------------------
//
// Returns the value a military card writes into `cell` for `cell_key`. The read
// goes through `ModifierRuntime::effective_value` on the ECONOMY domain with
// `group_handle = cell` -- the same call every per-cell economy reader makes --
// so the derived layer is merged exactly as it is for the land cards.
//
// `ok=false` with `reason=stat_unknown` when the catalog has no such stat: an
// unregistered stat must not silently read as the base value, because a card
// that applies nothing and a card that applies 1.0 look identical otherwise.
Dictionary DCWorldExt::get_military_cell_stat_q16(const String &cell_key,
                                                  int64_t cell,
                                                  int64_t entity_handle,
                                                  int64_t base_value_q16) const {
    Dictionary out;
    out["ok"] = false;
    if (_modifier_runtime == nullptr) {
        out["reason"] = "modifier_runtime_unavailable";
        return out;
    }
    const ModifierRuntime *runtime =
        static_cast<const ModifierRuntime *>(_modifier_runtime);
    const std::string key(cell_key.utf8().get_data());
    const int32_t stat_id = runtime->stat_id_for_key(key);
    if (stat_id < 0) {
        out["reason"] = "stat_unknown";
        return out;
    }
    const double base = static_cast<double>(base_value_q16) /
        static_cast<double>(kMilitaryQ16);
    const double effective = runtime->effective_value(
        ModifierRuntime::ECONOMY, stat_id, static_cast<uint64_t>(entity_handle),
        static_cast<uint64_t>(cell), base);
    out["ok"] = true;
    out["stat_id"] = stat_id;
    out["value_q16"] = static_cast<int64_t>(effective * kMilitaryQ16);
    // The derived layer's own slice, reported separately so a fixture can tell
    // "the channel-A cell program contributed" from "a national row did".
    bool derived_present = false;
    const DerivedCellFront *front = runtime->derived_cell_front();
    if (front != nullptr && cell >= 0) {
        const DerivedCellStatRow *row = front->row_for_stat(stat_id);
        if (row != nullptr) {
            const DerivedCellContribution *slot =
                row->find(static_cast<int32_t>(cell));
            if (slot != nullptr) {
                derived_present = true;
                out["derived_add"] = slot->sum_add;
                out["derived_factor"] = slot->product_nonzero;
            }
        }
    }
    out["derived_present"] = derived_present;
    return out;
}

// ---------------------------------------------------------------------------
// Read-back for the tag publisher and for fixtures.
// ---------------------------------------------------------------------------
//
// `cells` is the ascending list of cells carrying `tag`. An unpublished tag
// reads as an empty list, never as "every cell": fail-closed narrowing is the
// rule the native tag table itself uses for an unknown tag id.
Dictionary DCWorldExt::get_military_cell_tag_cells(int64_t tag) const {
    Dictionary out;
    out["ok"] = true;
    PackedInt32Array cells;
    const uint32_t mask = tag_bit_mask(static_cast<int32_t>(tag));
    if (mask == 0) {
        out["cells"] = cells;
        out["count"] = static_cast<int64_t>(0);
        return out;
    }
    for (size_t cell = 0; cell < _military_cell_tag_bits.size(); ++cell) {
        if ((_military_cell_tag_bits[cell] & mask) != 0) {
            cells.push_back(static_cast<int32_t>(cell));
        }
    }
    out["count"] = static_cast<int64_t>(cells.size());
    out["cells"] = cells;
    return out;
}

// The committed per-country metrics row for `handle`; all-zero when the
// country has never been published (which is the truthful "peace, no army").
Dictionary DCWorldExt::get_military_country_metrics(int64_t handle) const {
    Dictionary out;
    out["ok"] = true;
    const auto it = _military_country_metrics.find(handle);
    if (it == _military_country_metrics.end()) {
        out["present"] = false;
        out["slot"] = static_cast<int64_t>(-1);
        out["at_war"] = static_cast<int64_t>(0);
        out["soldier_share_q16"] = static_cast<int64_t>(0);
        return out;
    }
    out["present"] = true;
    out["slot"] = static_cast<int64_t>(it->second.slot);
    out["at_war"] = static_cast<int64_t>(it->second.at_war);
    out["soldier_share_q16"] = static_cast<int64_t>(it->second.soldier_share_q16);
    return out;
}

// Drops every published row. Called when Military is reconfigured or the map
// changes: a stale tag on a rebuilt grid would name different cells.
Dictionary DCWorldExt::clear_military_cell_stats() {
    Dictionary out;
    _military_country_metrics.clear();
    _military_cell_tag_bits.clear();
    // The Economy overrides must go too: they are the published form of these
    // tags, so clearing one without the other would leave a card matching cells
    // Military no longer claims.
    if (_economy_runtime != nullptr) {
        static_cast<NativeEconomyRuntime *>(_economy_runtime)
            ->clear_cell_tag_overrides_for_test();
    }
    out["ok"] = true;
    return out;
}

Dictionary DCWorldExt::get_military_cell_stats_report() const {
    Dictionary out;
    out["ok"] = true;
    out["country_rows"] = static_cast<int64_t>(_military_country_metrics.size());
    out["cells"] = static_cast<int64_t>(_military_cell_tag_bits.size());
    int64_t tagged_cells = 0;
    for (const uint8_t bits : _military_cell_tag_bits) {
        if (bits != 0) ++tagged_cells;
    }
    out["tagged_cells"] = tagged_cells;
    return out;
}

} // namespace pk
