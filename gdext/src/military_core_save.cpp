// military_core_save.cpp - PKMI v7 restore of the whole Military state
// (owner: A1).
//
// Layout: every record is a little-endian fixed-width field sequence (no struct
// memcpy, so the format never depends on padding or MSVC layout). The header
// carries magic, version, the catalog hash and the world shape; the payload is
// a list of sections each prefixed with a section id and a byte length so a
// reader can skip unknown future sections, and terminated by an END sentinel.
// Restore is transactional: a temp instance is decoded first, bounds checked and
// only then swapped into the live object, so a corrupt save leaves the current
// game state untouched.

#include "military_core.h"
#include "military_core_internal.h"
#include "military_core_save_internal.h"

#include <algorithm>
#include <cstring>
#include <limits>
#include <vector>

namespace pk {

namespace {

template<class T> bool read_index_vector(Reader &r, std::vector<T> &values) {
    const uint32_t n = r.u32();
    if (n > kMaxRows || n > r.remaining() / 8) return false;
    values.resize(n);
    for (T &value : values) {
        const int64_t raw = r.i64();
        if (raw < (int64_t)std::numeric_limits<T>::min() ||
            raw > (int64_t)std::numeric_limits<T>::max()) return false;
        value = (T)raw;
    }
    return r.ok();
}
bool read_index_continuation(Reader &r, MilitaryCore &c) {
    if (!read_index_vector(r, c._lots.location_kind) ||
        !read_index_vector(r, c._lots.location) ||
        !read_index_vector(r, c._lots.country_slot) ||
        !read_index_vector(r, c._lots.unit_type) ||
        !read_index_vector(r, c._lots.equip_quality_q8) ||
        !read_index_vector(r, c._lots.kit_q16) ||
        !read_index_vector(r, c._lots.condition_q16) ||
        !read_index_vector(r, c._lots.count) ||
        !read_index_vector(r, c._lots.free_list)) return false;
    c._lot_index_ok = r.u8() != 0;
    if (!(read_index_vector(r, c._lot_next) &&
        read_index_vector(r, c._lot_link_kind) && read_index_vector(r, c._lot_link_loc) &&
        read_index_vector(r, c._lot_army_head) && read_index_vector(r, c._lot_cell_head) &&
        read_index_vector(r, c._armies.generation) && read_index_vector(r, c._armies.free_list) &&
        read_index_vector(r, c._army_lane_pending))) return false;
    c._lots.partial_equipment.resize(c._lots.active.size(), 0);
    if (r.section_remaining() == 0) return true;
    const size_t grades = c._lots.active.size() + c._training.size();
    if (r.section_remaining() < grades * sizeof(uint16_t)) return false;
    for (auto &kit : c._lots.partial_equipment) kit = r.u16();
    for (auto &order : c._training) order.source_partial_equipment = r.u16();
    return r.ok();
}


} // namespace

// ============================================================== restore

namespace {

// Decodes into `tmp`; returns false on any structural problem. `tmp` is
// discarded by the caller on failure (transactional restore).
bool decode_into(MilitaryCore &tmp, Reader &r, std::string &error) {
    if (r.u32() != PKMI_MAGIC) {
        error = "pkmi_bad_magic";
        return false;
    }
    const uint32_t version = r.u32();
    if (version != PKMI_VERSION) {
        error = "pkmi_version_mismatch_expected_" + std::to_string(PKMI_VERSION);
        return false;
    }
    const uint64_t saved_catalog_hash = r.u64();
    (void)saved_catalog_hash;   // checked by the caller against the live catalog
    tmp._seed = r.u64();
    const int32_t cells = r.i32();
    const int32_t width = r.i32();
    const int32_t height = r.i32();
    tmp._last_day = r.i64();
    if (!r.ok()) {
        error = "pkmi_truncated_header";
        return false;
    }
    if (cells < 0 || width < 0 || height < 0) {
        error = "pkmi_bad_terrain";
        return false;
    }
    // The live terrain is authoritative for shape; a save from a different map
    // would have a different catalog/terrain anyway, so require equality.
    if (cells != tmp._terrain.cell_count && cells != 0) {
        error = "pkmi_terrain_mismatch";
        return false;
    }

    std::vector<int32_t> remap_path;
    std::vector<int32_t> remap_tpl;
    bool saw_end = false;
    bool saw_index_continuation = false;
    bool saw_exploration = false;
    while (r.ok()) {
        const uint16_t id = (uint16_t)r.open_section();
        if (!r.ok()) break;
        switch (id) {
            case kSection_Counters: {
                tmp._next_sequence = r.u64();
                tmp._next_id = r.u64();
                tmp._next_event_id = r.u64();
                tmp._control_revision = r.u64();
                tmp._front_revision = r.u64();
                const uint32_t n = r.u32();
                if (n > kMaxRows) {
                    error = "pkmi_bad_counters";
                    return false;
                }
                tmp._path_daily_requests.resize(n, 0);
                for (uint32_t i = 0; i < n; ++i) tmp._path_daily_requests[i] = r.i32();
                const uint32_t pending = r.u32();
                if (pending > kMaxRows) {
                    error = "pkmi_bad_pending";
                    return false;
                }
                break;
            }
#include "military_core_save_section_personnel_and_forces.inc"
#include "military_core_save_section_supply_orders.inc"
#include "military_core_save_section_conflict_and_control.inc"
            case kSection_Controller: {
                const uint32_t cells_n = r.u32();
                const uint32_t count = r.u32();
                if (cells_n > kMaxRows || count > cells_n) {
                    error = "pkmi_bad_controller";
                    return false;
                }
                tmp._cell_controller.assign((size_t)cells_n, -1);
                for (uint32_t i = 0; i < count; ++i) {
                    const int32_t cell = r.i32();
                    const int32_t slot = r.i32();
                    if (!r.ok()) break;
                    if (cell < 0 || (size_t)cell >= tmp._cell_controller.size()) {
                        error = "pkmi_bad_controller_cell";
                        return false;
                    }
                    tmp._cell_controller[(size_t)cell] = slot;
                }
                break;
            }
            case kSection_Ledger:
                tmp._ledger_received = r.i64();
                tmp._ledger_consumed = r.i64();
                tmp._ledger_intercepted_out = r.i64();
                tmp._ledger_intercepted_in = r.i64();
                tmp._ledger_returned = r.i64();
                tmp._ledger_stock = r.i64();
                tmp._ledger_transit = r.i64();
                break;
            case kSection_Events: {
                const uint32_t n = r.u32();
                if (n > (uint32_t)MILITARY_EVENT_RING_CAPACITY) {
                    error = "pkmi_bad_events";
                    return false;
                }
                tmp._events.clear();
                tmp._events.reserve(n);
                for (uint32_t i = 0; i < n; ++i) {
                    MilitaryEvent e;
                    e.id = r.u64();
                    e.day = r.i64();
                    e.type = r.u16();
                    e.payload_schema = r.u16();
                    e.cell = r.i32();
                    e.i0 = r.u64();
                    e.i1 = r.u64();
                    e.i2 = r.u64();
                    e.i3 = r.u64();
                    e.value = r.i64();
                    if (!r.ok()) break;
                    tmp._events.push_back(e);
                }
                break;
            }
            case kSection_Ai: {
                const uint32_t n = r.u32();
                if (n > kMaxRows) {
                    error = "pkmi_bad_ai";
                    return false;
                }
                tmp._ai_country.assign(n, 0);
                tmp._ai_next_decision_day.assign(n, 0);
                for (uint32_t i = 0; i < n; ++i) {
                    tmp._ai_country[i] = r.u8();
                    tmp._ai_next_decision_day[i] = r.i64();
                    if (!r.ok()) break;
                }
                break;
            }
#include "military_core_save_section_exploration.inc"
            case kSection_IndexContinuation:
                if (saw_index_continuation || !read_index_continuation(r, tmp)) {
                    error = "pkmi_index_continuation_invalid"; return false;
                }
                saw_index_continuation = true;
                break;
            case kSection_End:
                saw_end = true;
                break;
            default:
                // Forward compatibility: skip a section we do not know.
                if (id == 0 && r.remaining() >= 4) {
                    // kSection_HeaderEnd is never written; treat as corruption.
                    error = "pkmi_bad_section";
                    return false;
                }
                break;
        }
        if (!r.ok()) break;
        r.close_section();
        if (saw_end) break;
    }
    if (!r.ok()) {
        error = "pkmi_truncated";
        return false;
    }
    if (!saw_exploration) {
        error = "pkmi_exploration_section_missing";
        return false;
    }
    if (!saw_index_continuation || !military_valid_index_continuation(tmp)) {
        error = "pkmi_index_continuation_missing_or_invalid"; return false;
    }
    if (!saw_end) {
        error = "pkmi_missing_end_sentinel";
        return false;
    }

    // ---- rebuild the derived spans from the compacted arenas
    size_t max_path_end = 0;
    size_t max_tpl_end = 0;
    for (size_t i = 0; i < tmp._armies.active.size(); ++i) {
        if (!tmp._armies.active[i]) continue;
        const int32_t off = tmp._armies.path_offset[i];
        const int32_t len = tmp._armies.path_len[i];
        if (len <= 0) {
            tmp._armies.path_len[i] = 0;
            tmp._armies.path_offset[i] = 0;
            tmp._armies.path_cursor[i] = 0;
        } else {
            if (off < 0 || (size_t)(off + len) > remap_path.size()) {
                error = "pkmi_bad_path_span";
                return false;
            }
            if (tmp._armies.path_cursor[i] < 0) tmp._armies.path_cursor[i] = 0;
            if (tmp._armies.path_cursor[i] > len) tmp._armies.path_cursor[i] = len;
            max_path_end = std::max(max_path_end, (size_t)(off + len));
        }
        const int32_t toff = tmp._armies.template_offset[i];
        const int32_t tlen = tmp._armies.template_len[i];
        if (tlen <= 0) {
            tmp._armies.template_len[i] = 0;
            tmp._armies.template_offset[i] = 0;
        } else {
            if (toff < 0 || (size_t)(toff + tlen) > remap_tpl.size()) {
                error = "pkmi_bad_template_span";
                return false;
            }
            max_tpl_end = std::max(max_tpl_end, (size_t)(toff + tlen));
        }
    }
    tmp._path_cells.assign(remap_path.begin(), remap_path.begin() + static_cast<std::ptrdiff_t>(max_path_end));
    tmp._template_rows.assign(remap_tpl.begin(), remap_tpl.begin() + static_cast<std::ptrdiff_t>(max_tpl_end));

    // Slot payload, free-list order and linked sets are continuation state.
    if (tmp._cell_states.size() > 1) {
        std::sort(tmp._cell_states.begin(), tmp._cell_states.end(),
                  [](const MilitaryCellState &a, const MilitaryCellState &b) { return a.cell < b.cell; });
        tmp._cell_states.erase(std::unique(tmp._cell_states.begin(), tmp._cell_states.end(),
                                           [](const MilitaryCellState &a, const MilitaryCellState &b) {
                                               return a.cell == b.cell;
                                           }),
                               tmp._cell_states.end());
    }
    if (tmp._cell_controller.size() != (size_t)tmp._terrain.cell_count) {
        if (tmp._cell_controller.size() < (size_t)tmp._terrain.cell_count) {
            error = "pkmi_controller_size_mismatch";
            return false;
        }
        tmp._cell_controller.resize((size_t)tmp._terrain.cell_count);
    }
    // Derived index + army cache.
    tmp._cell_head.assign((size_t)std::max(0, tmp._terrain.cell_count), -1);
    tmp._cell_state_index.assign((size_t)std::max(0, tmp._terrain.cell_count), -1);
    for (size_t i = 0; i < tmp._cell_states.size(); ++i) {
        const int32_t c = tmp._cell_states[i].cell;
        if (c >= 0 && (size_t)c < tmp._cell_state_index.size()) tmp._cell_state_index[(size_t)c] = (int32_t)i;
    }
    tmp.rebuild_cell_index();
    if (!military_validate_restored_exploration_paths(tmp, error)) return false;
    // Army caches are saved verbatim (refreshing here would diverge from the
    // live cache, which lags condition decay and needs the era mirror).
    return true;
}

} // namespace

bool MilitaryCore::restore(const uint8_t *data, size_t size, std::string &error) {
    error.clear();
    if (!_configured) {
        error = "military_not_configured";
        return false;
    }
    if (!data || size < 24) {
        error = "pkmi_empty";
        return false;
    }
    // Header pre-read: magic/version/catalog hash before any allocation.
    Reader head(data, size);
    if (head.u32() != PKMI_MAGIC) {
        error = "pkmi_bad_magic";
        return false;
    }
    if (head.u32() != PKMI_VERSION) {
        error = "pkmi_version_mismatch_expected_" + std::to_string(PKMI_VERSION);
        return false;
    }
    const uint64_t saved_hash = head.u64();
    if (saved_hash != _catalog.hash) {
        error = "pkmi_catalog_mismatch";
        return false;
    }
    // Decode into a temp copy of the configured object, then swap. The temp
    // shares catalog/terrain (cheap) but starts from a clean state.
    MilitaryCore tmp;
    tmp._configured = true;
    tmp._seed = _seed;
    tmp._catalog = _catalog;
    tmp._terrain = _terrain;
    tmp.reset_state();
    Reader r(data, size);
    if (!decode_into(tmp, r, error)) {
        // Transactional restore: `this` was never touched (decode_into works on
        // a temp instance created by restore()).
        return false;
    }
    // Sanity: every lot / army reference must resolve on this map.
    const size_t cells = (size_t)std::max(0, _terrain.cell_count);
    for (size_t i = 0; i < tmp._lots.active.size(); ++i) {
        if (!tmp._lots.active[i]) continue;
        if (tmp._lots.location_kind[i] == (uint8_t)MILITARY_LOT_GARRISON) {
            const int32_t loc = tmp._lots.location[i];
            if (loc < 0 || (size_t)loc >= cells) {
                error = "pkmi_lot_cell_out_of_range";
                return false;
            }
        } else if (!mil::army_alive(tmp._armies, tmp._lots.location[i])) {
            error = "pkmi_lot_army_missing";
            return false;
        }
    }
    for (size_t i = 0; i < tmp._armies.active.size(); ++i) {
        if (!tmp._armies.active[i]) continue;
        const int32_t cell = tmp._armies.cell[i];
        if (cell < 0 || (size_t)cell >= cells) {
            error = "pkmi_army_cell_out_of_range";
            return false;
        }
    }
    if (tmp._cell_controller.size() != cells) tmp._cell_controller.resize(cells, -1);

    // ---- commit (transactional swap)
    military_market_reuse_cancel(*this);
    _seed = tmp._seed;
    _last_day = tmp._last_day;
    _next_sequence = tmp._next_sequence;
    _next_id = tmp._next_id;
    _next_event_id = tmp._next_event_id;
    _control_revision = tmp._control_revision;
    _front_revision = tmp._front_revision;
    _path_daily_requests = std::move(tmp._path_daily_requests);
    _pending = std::move(tmp._pending);
    _lot_next = std::move(tmp._lot_next);
    _lot_link_kind = std::move(tmp._lot_link_kind);
    _lot_link_loc = std::move(tmp._lot_link_loc);
    _lot_army_head = std::move(tmp._lot_army_head);
    _lot_cell_head = std::move(tmp._lot_cell_head);
    _lot_index_ok = tmp._lot_index_ok;
    _lot_garrison_lookup_complete = tmp._lot_garrison_lookup_complete;
    _army_lane_pending = std::move(tmp._army_lane_pending);
    _lots = std::move(tmp._lots);
    _training = std::move(tmp._training);
    _armies = std::move(tmp._armies);
    _path_cells = std::move(tmp._path_cells);
    _template_rows = std::move(tmp._template_rows);
    _stocks = std::move(tmp._stocks);
    _shipments = std::move(tmp._shipments);
    _purchase_orders = std::move(tmp._purchase_orders);
    _next_purchase_id = tmp._next_purchase_id;
    _maint_rows = std::move(tmp._maint_rows);
    _engagements = std::move(tmp._engagements);
    _wars = std::move(tmp._wars);
    _truces = std::move(tmp._truces);
    _reparations = std::move(tmp._reparations);
    _battle_log = std::move(tmp._battle_log);
    _areas = std::move(tmp._areas);
    _explorations = std::move(tmp._explorations);
    _policies = std::move(tmp._policies);
    _policy_handle = std::move(tmp._policy_handle);
    _ai_country = std::move(tmp._ai_country);
    _ai_next_decision_day = std::move(tmp._ai_next_decision_day);
    _cell_states = std::move(tmp._cell_states);
    _cell_controller = std::move(tmp._cell_controller);
    _ledger_received = tmp._ledger_received;
    _ledger_consumed = tmp._ledger_consumed;
    _ledger_intercepted_out = tmp._ledger_intercepted_out;
    _ledger_intercepted_in = tmp._ledger_intercepted_in;
    _ledger_returned = tmp._ledger_returned;
    _ledger_stock = tmp._ledger_stock;
    _ledger_transit = tmp._ledger_transit;
    _events = std::move(tmp._events);
    rebuild_exploration_index();
    _exploration_daily_path_requests.clear();
    _exploration_observer_slot = -1;
    _exploration_explored_view.clear();
    _exploration_view_day = -1;
    _exploration_view_revision = 0;
    _exploration_trail.clear();
    _exploration_trail_stamp.clear();
    _exploration_trail_gen = 1;

    invalidate_engagement_members(); // Rebuild derived state only after successful commit.
    _cell_head.assign(cells, -1);
    _cell_engagement_mask.assign(cells, 0);
    _front_edge_set.assign(cells * 6, 0);
    _front_edges.clear();
    _front_edge_pos.clear();
    _threat.assign(cells, 0);
    _guard.assign(cells, 0);
    _threat_stamp.assign(cells, 0);
    _threat_owner.assign(cells, 0);
    _guard_owners.assign(cells, 0);
    _dij_dist.assign(cells, 0);
    _dij_parent.assign(cells, -1);
    _dij_stamp.assign(cells, 0);
    _dij_gen = 1;
    _heap.clear();
    _cell_owner_dirty.assign(cells, 0);
    _report = MilitaryReport();
    _report.day = _last_day;
    _attrition_intents.clear();
    _last_digest = MilitaryWorldDigest();
    // The previous-day ledger is a derived signal for the divergence probe, not
    // state: after a restore there is no "yesterday" to compare against, so the
    // first rebuild must not report the whole map as repaired.
    _state_ledger_prev.clear();
    _state_ledger_prev_valid = false;
    _country_annual_revenue.clear();
    _war_intents.clear();
    _event_counter_control = 0;
    rebuild_cell_index();
    // Cached army stats were restored verbatim from the save (hash parity).

    return true;
}

} // namespace pk
