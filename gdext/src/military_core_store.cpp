#include "military_core.h"
#include "military_core_internal.h"

#include <algorithm>
#include <atomic>
#include <cmath>
#include <string>
#include <utility>

namespace pk {

using namespace mil;

namespace {

int32_t barracks_capacity_for_tier(const MilitaryCatalog &c, int32_t tier) {
    for (const MilitaryStateBuilding &b : c.state_buildings) {
        if (b.role == (uint8_t)MILITARY_STATE_BARRACKS && (int32_t)b.tier == tier) return b.capacity;
    }
    return 0;
}

} // namespace

// ============================================================== handles

int32_t MilitaryCore::country_slot_for_handle(uint64_t handle) const {
    if (handle == 0) return -1;
    const size_t n = std::min(_policy_handle.size(), _policies.size());
    for (size_t i = 0; i < n; ++i) {
        if (_policy_handle[i] == handle) return (int32_t)i;
    }
    return -1;
}

uint64_t MilitaryCore::country_handle_for_slot(int32_t slot) const {
    if (slot < 0 || (size_t)slot >= _policy_handle.size()) return 0;
    return _policy_handle[(size_t)slot];
}

int32_t MilitaryCore::ensure_country_slot(uint64_t handle) {
    if (handle == 0) return -1;
    const int32_t existing = country_slot_for_handle(handle);
    if (existing >= 0) return existing;
    for (size_t i = 0; i < _policy_handle.size(); ++i) {
        if (_policy_handle[i] == 0) {
            _policy_handle[i] = handle;
            _policies[i].config_share_bp.assign(_catalog.units.size(), 0);
            if (_ai_country.size() < i + 1) _ai_country.resize(i + 1, 0);
            if (_ai_next_decision_day.size() < i + 1) _ai_next_decision_day.resize(i + 1, 0);
            return (int32_t)i;
        }
    }
    const size_t slot = _policy_handle.size();
    _policy_handle.push_back(handle);
    _policies.emplace_back();
    _policies.back().config_share_bp.assign(_catalog.units.size(), 0);
    _ai_country.push_back(0);
    _ai_next_decision_day.push_back(0);
    _path_daily_requests.push_back(0);
    return (int32_t)slot;
}

uint64_t MilitaryCore::army_handle(int32_t slot) const {
    if (!army_alive(_armies, slot)) return 0;
    return ((uint64_t)_armies.generation[(size_t)slot] << 32) | (uint64_t)(uint32_t)slot;
}

bool MilitaryCore::resolve_army(uint64_t handle, int32_t &slot) const {
    slot = -1;
    if (handle == 0) return false;
    const uint32_t raw = (uint32_t)(handle & 0xFFFFFFFFull);
    const uint32_t gen = (uint32_t)(handle >> 32);
    if ((size_t)raw >= _armies.generation.size()) return false;
    const int32_t s = (int32_t)raw;
    if (!army_alive(_armies, s)) return false;
    if (_armies.generation[(size_t)s] != gen) return false;
    slot = s;
    return true;
}

int32_t MilitaryCore::controller_of(int32_t cell) const {
    if (cell < 0 || (size_t)cell >= _cell_controller.size()) return -1;
    return _cell_controller[(size_t)cell];
}


// ============================================================== armies

int32_t MilitaryCore::create_army(int32_t country_slot, int32_t cell) {
    if (_armies.free_list.empty()) return -1;
    const int32_t slot = _armies.free_list.back();
    _armies.free_list.pop_back();
    if (slot < 0 || (size_t)slot >= _armies.active.size()) return -1;
    const size_t s = (size_t)slot;
    _armies.active[s] = 1;
    _armies.owner_slot[s] = country_slot;
    _armies.cell[s] = cell;
    _armies.next_cell[s] = -1;
    _armies.move_points_q16[s] = 0;
    _armies.stance[s] = (uint8_t)MILITARY_STANCE_HOLD;
    _armies.mission[s] = (uint8_t)MILITARY_MISSION_NONE;
    _armies.target_cell[s] = -1;
    _armies.area_id[s] = -1;
    _armies.organization_q16[s] = MILITARY_Q16;
    _armies.morale_q16[s] = MILITARY_Q16 / 2;
    _armies.supply_ratio_q16[s] = MILITARY_Q16;
    _armies.ration_ratio_q16[s] = MILITARY_Q16;
    _armies.pay_ratio_q16[s] = MILITARY_Q16;
    _armies.path_offset[s] = 0;
    _armies.path_len[s] = 0;
    _armies.path_cursor[s] = 0;
    _armies.reinforce_enabled[s] = 0;
    _armies.template_offset[s] = 0;
    _armies.template_len[s] = 0;
    _armies.commander_slot[s] = 0;   // v1: commander slot always open (6.4)
    _armies.cached_headcount[s] = 0;
    _armies.cached_attack_q16[s] = 0;
    _armies.cached_defense_q16[s] = 0;
    _armies.cached_speed_q16[s] = MILITARY_Q16;
    set_army_engagement(slot, -1);
    _armies.moved_day[s] = _last_day;
    _armies.prev_cell[s] = cell;
    _armies.name_seed[s] =
        (uint32_t)(rng(_seed, mix_key(0x41524d59ull, (uint64_t)slot), _last_day) & 0xFFFFFFFFull);
    _armies.funds[s] = 0;
    _armies.next_in_cell[s] = -1;
    _armies.prev_in_cell[s] = -1;
    // Personnel lane bookkeeping (transient): a recycled slot never inherits the
    // previous formation's in-flight embarkation.
    if (_army_lane_pending.size() < _armies.active.size())
        _army_lane_pending.resize(_armies.active.size(), 0);
    _army_lane_pending[s] = 0;
    if (_armies.generation[s] == 0) _armies.generation[s] = 1;
    index_insert(slot, cell);
    return slot;
}

void MilitaryCore::destroy_army(int32_t army_slot) {
    if (!army_alive(_armies, army_slot)) return;
    const size_t s = (size_t)army_slot;
    const int32_t exploration_row = exploration_row_for_army(army_slot);
    if (exploration_row >= 0) {
        cancel_exploration_task(army_slot, MILITARY_EXPLORATION_RESULT_CANCELLED);
        // The formation no longer exists, so a retained terminal row would
        // make PKMI section 23 reference a dead handle.
        _explorations[(size_t)exploration_row].active = false;
    }
    // Any lot still pointing at this formation would be a dangling army
    // reference in PKMI (pkmi_lot_army_missing on the next restore).
    for (size_t i = 0; i < _lots.active.size(); ++i) {
        if (!_lots.active[i]) continue;
        if (_lots.location_kind[i] != (uint8_t)MILITARY_LOT_ARMY) continue;
        if (_lots.location[i] != army_slot) continue;
        _lots.active[i] = 0;
        _lots.free_list.push_back((int32_t)i);
    }
    if (s < _army_lane_pending.size()) _army_lane_pending[s] = 0;
    index_remove(army_slot);
    _armies.active[s] = 0;
    set_army_engagement(army_slot, -1);
    _armies.cell[s] = -1;
    _armies.next_cell[s] = -1;
    _armies.prev_cell[s] = -1;
    _armies.path_len[s] = 0;
    _armies.path_cursor[s] = 0;
    _armies.template_len[s] = 0;
    _armies.mission[s] = (uint8_t)MILITARY_MISSION_NONE;
    uint32_t gen = _armies.generation[s] + 1u;
    if (gen == 0) gen = 1;
    _armies.generation[s] = gen;
    _armies.free_list.push_back(army_slot);
}

// ============================================================== lots

namespace {

int32_t *lot_head_ptr(MilitaryCore &c, uint8_t kind, int32_t loc) {
    if (loc < 0) return nullptr;
    if (kind == (uint8_t)MILITARY_LOT_ARMY) {
        return (size_t)loc < c._lot_army_head.size() ? &c._lot_army_head[(size_t)loc] : nullptr;
    }
    return (size_t)loc < c._lot_cell_head.size() ? &c._lot_cell_head[(size_t)loc] : nullptr;
}

void lot_link_head(MilitaryCore &c, int32_t lot) {
    const size_t s = (size_t)lot;
    const uint8_t kind = c._lots.location_kind[s];
    const int32_t loc = c._lots.location[s];
    int32_t *head = lot_head_ptr(c, kind, loc);
    if (!head) return;
    c._lot_next[s] = *head;
    *head = lot;
    c._lot_link_kind[s] = kind;
    c._lot_link_loc[s] = loc;
}

} // namespace

void military_lot_index_rebuild(const MilitaryCore &cc) {
    MilitaryCore &c = const_cast<MilitaryCore &>(cc);
    const size_t n = c._lots.active.size();
    c._lot_next.assign(n, -1);
    c._lot_link_kind.assign(n, 255);
    c._lot_link_loc.assign(n, -1);
    c._lot_army_head.assign(c._armies.active.size(), -1);
    c._lot_cell_head.assign((size_t)std::max(0, c._terrain.cell_count), -1);
    // Ascending iteration order is produced by walking the list BACKWARDS in
    // military_for_each_lot; the list itself only has to be a set.
    for (size_t k = 0; k < n; ++k) {
        if (!c._lots.active[k]) continue;
        lot_link_head(c, (int32_t)k);
    }
    c._lot_index_ok = true;
    c._lot_garrison_lookup_complete = true;
}

bool military_valid_index_continuation(MilitaryCore &c) {
    const size_t n = c._lots.active.size();
    if (c._lots.location_kind.size() != n || c._lots.location.size() != n ||
        c._lots.country_slot.size() != n || c._lots.unit_type.size() != n ||
        c._lots.equip_quality_q8.size() != n || c._lots.kit_q16.size() != n ||
        c._lots.partial_equipment.size() != n ||
        c._lots.condition_q16.size() != n ||
        c._lots.count.size() != n || c._armies.generation.size() != c._armies.active.size()) return false;
    auto valid_free = [](const auto &free, const auto &active) {
        std::vector<uint8_t> seen(active.size(), 0);
        for (int32_t row : free) {
            if (row < 0 || (size_t)row >= active.size() || active[(size_t)row] || seen[(size_t)row]) return false;
            seen[(size_t)row] = 1;
        }
        for (size_t i = 0; i < active.size(); ++i) if (!active[i] && !seen[i]) return false;
        return true;
    };
    if (!valid_free(c._lots.free_list, c._lots.active) || !valid_free(c._armies.free_list, c._armies.active)) return false;
    for (size_t i = 0; i < n; ++i) {
        if (c._lots.active[i] && (c._lots.location_kind[i] > MILITARY_LOT_ARMY ||
            c._lots.country_slot[i] < 0 || c._lots.unit_type[i] < 0 ||
            (size_t)c._lots.unit_type[i] >= c._catalog.units.size() || c._lots.count[i] < 0)) return false;
    }
    if (!c._lot_index_ok) return true;
    if (c._lot_next.size() != n || c._lot_link_kind.size() != n || c._lot_link_loc.size() != n ||
        c._lot_army_head.size() != c._armies.active.size() ||
        c._lot_cell_head.size() != (size_t)c._terrain.cell_count) return false;
    std::vector<uint8_t> seen(n, 0);
    auto walk = [&](const auto &heads, uint8_t kind) {
        for (size_t loc = 0; loc < heads.size(); ++loc) {
            for (int32_t row = heads[loc]; row != -1; row = c._lot_next[(size_t)row]) {
                if (row < 0 || (size_t)row >= n || seen[(size_t)row]) return false;
                seen[(size_t)row] = 1;
                if (c._lot_link_kind[(size_t)row] != kind || c._lot_link_loc[(size_t)row] != (int32_t)loc) return false;
            }
        }
        return true;
    };
    if (!walk(c._lot_army_head, (uint8_t)MILITARY_LOT_ARMY) ||
        !walk(c._lot_cell_head, (uint8_t)MILITARY_LOT_GARRISON)) return false;
    // Coverage was never a save validity requirement. Preserve accepted lists
    // and their bytes; incomplete/misplaced rows keep the old full-scan query.
    c._lot_garrison_lookup_complete = true;
    for (size_t i = 0; i < n; ++i) {
        if (!c._lots.active[i] || c._lots.location_kind[i] != MILITARY_LOT_GARRISON) continue;
        const int32_t cell = c._lots.location[i];
        if (cell < 0 || (size_t)cell >= c._lot_cell_head.size()) continue;
        if (!seen[i] || c._lot_link_kind[i] != MILITARY_LOT_GARRISON ||
            c._lot_link_loc[i] != cell) c._lot_garrison_lookup_complete = false;
    }
    return true;
}

bool military_garrison_candidate_cells(MilitaryCore &core, std::vector<int32_t> &cells) {
    cells.clear();
    const size_t rows = core._lots.active.size();
    // Before a lazy rebuild the old dense loop can change its candidate set
    // mid-iteration. Keep that exact path, and prefer it when it is smaller.
    if (!core._lot_index_ok || core._lot_next.size() != rows ||
        core._lot_link_kind.size() != rows || core._lot_link_loc.size() != rows ||
        core._lot_cell_head.size() != (size_t)std::max(0, core._terrain.cell_count) ||
        rows >= core._lot_cell_head.size()) return false;
    for (size_t row = 0; row < rows; ++row) {
        ++core._report.procurement_garrison_links_visited;
        if (core._lot_link_kind[row] != MILITARY_LOT_GARRISON) continue;
        const int32_t cell = core._lot_link_loc[row];
        if (cell < 0 || (size_t)cell >= core._lot_cell_head.size() ||
            core._lot_cell_head[(size_t)cell] < 0) continue;
        // Every nonempty head is covered: both rebuild and the PKMI walk
        // guarantee that its head row names this linked kind/location. PKMI
        // may differ in active status or actual location; neither filters here.
        cells.push_back(cell);
    }
    std::sort(cells.begin(), cells.end());
    cells.erase(std::unique(cells.begin(), cells.end()), cells.end());
    return true;
}

void military_lot_index_unlink(MilitaryCore &c, int32_t lot) {
    if (!c._lot_index_ok) return;
    const size_t s = (size_t)lot;
    if (lot < 0 || s >= c._lot_link_kind.size() || c._lot_link_kind[s] == 255) return;
    int32_t *head = lot_head_ptr(c, c._lot_link_kind[s], c._lot_link_loc[s]);
    if (head) {
        if (*head == lot) {
            *head = c._lot_next[s];
        } else {
            int32_t p = *head;
            while (p >= 0 && c._lot_next[(size_t)p] != lot) p = c._lot_next[(size_t)p];
            if (p >= 0) c._lot_next[(size_t)p] = c._lot_next[s];
        }
    }
    c._lot_next[s] = -1;
    c._lot_link_kind[s] = 255;
    c._lot_link_loc[s] = -1;
}

void military_lot_index_link(MilitaryCore &c, int32_t lot) {
    if (!c._lot_index_ok) {
        military_lot_index_rebuild(c);
        return;
    }
    const size_t n = c._lots.active.size();
    if (c._lot_next.size() < n) {
        c._lot_next.resize(n, -1);
        c._lot_link_kind.resize(n, 255);
        c._lot_link_loc.resize(n, -1);
    }
    if (lot < 0 || (size_t)lot >= n) return;
    if (c._lot_link_kind[(size_t)lot] != 255) military_lot_index_unlink(c, lot);
    if (!c._lots.active[(size_t)lot]) return;
    lot_link_head(c, lot);
}

int32_t MilitaryCore::lot_find_or_create(uint8_t kind, int32_t location, int32_t country_slot,
                                         int16_t unit, int16_t quality_q8,
                                         int32_t kit_q16, uint16_t partial_equipment) {
    const size_t n = _lots.active.size();
    int32_t found = -1;
    military_for_each_lot(*this, kind, location, [&](int32_t i) {
        if (found >= 0) return;
        const size_t s = (size_t)i;
        if (_lots.country_slot[s] != country_slot) return;
        if (_lots.unit_type[s] != unit) return;
        if (_lots.partial_equipment[s] != partial_equipment) return;
        if (std::abs((int32_t)_lots.equip_quality_q8[s] - (int32_t)quality_q8) > 16) return;
        if (std::abs(_lots.kit_q16[s] - kit_q16) > MILITARY_Q16 / 64) return;
        found = i;
    });
    if (found >= 0) return found;
    int32_t slot = -1;
    if (!_lots.free_list.empty()) {
        slot = _lots.free_list.back();
        _lots.free_list.pop_back();
    } else {
        slot = (int32_t)n;
        _lots.active.push_back(0);
        _lots.location_kind.push_back(0);
        _lots.location.push_back(-1);
        _lots.country_slot.push_back(-1);
        _lots.unit_type.push_back(-1);
        _lots.equip_quality_q8.push_back(256);
        _lots.kit_q16.push_back(MILITARY_Q16);
        _lots.partial_equipment.push_back(0);
        _lots.condition_q16.push_back(MILITARY_Q16);
        _lots.count.push_back(0);
    }
    if (slot < 0) return -1;
    const size_t s = (size_t)slot;
    _lots.active[s] = 1;
    _lots.location_kind[s] = kind;
    _lots.location[s] = location;
    _lots.country_slot[s] = country_slot;
    _lots.unit_type[s] = unit;
    _lots.equip_quality_q8[s] = quality_q8;
    _lots.kit_q16[s] = std::clamp(kit_q16, 0, MILITARY_Q16);
    _lots.partial_equipment[s] = partial_equipment;
    _lots.condition_q16[s] = MILITARY_Q16;
    _lots.count[s] = 0;
    military_lot_index_link(*this, slot);
    return slot;
}

int64_t MilitaryCore::lot_remove_casualties(uint8_t kind, int32_t location, int64_t count) {
    if (count <= 0) return 0;
    // Proportional removal with largest-remainder rounding, ties by lot index.
    static thread_local std::vector<int32_t> rows;
    rows.clear();
    int64_t total = 0;
    military_for_each_lot(*this, kind, location, [&](int32_t i) {
        rows.push_back(i);
        total += _lots.count[(size_t)i];
    });
    if (total <= 0) return 0;
    const int64_t want = std::min(count, total);
    int64_t assigned = 0;
    for (int32_t i : rows) {
        const size_t s = (size_t)i;
        int64_t share = mul_div(_lots.count[s], want, total);
        if (share > _lots.count[s]) share = _lots.count[s];
        _lots.count[s] -= share;
        assigned += share;
    }
    int64_t rest = want - assigned;
    for (size_t k = 0; k < rows.size() && rest > 0; ++k) {
        const size_t idx = (size_t)rows[k];
        if (_lots.count[idx] > 0) {
            _lots.count[idx] -= 1;
            --rest;
        }
    }
    for (size_t k = 0; k < rows.size() && rest > 0; ++k) {
        const size_t idx = (size_t)rows[k];
        const int64_t take = std::min(rest, _lots.count[idx]);
        _lots.count[idx] -= take;
        rest -= take;
    }
    for (int32_t i : rows) {
        const size_t s = (size_t)i;
        if (_lots.active[s] && _lots.count[s] <= 0) {
            military_lot_index_unlink(*this, i);
            _lots.active[s] = 0;
            _lots.count[s] = 0;
            _lots.location[s] = -1;
            _lots.free_list.push_back(i);
        }
    }
    return want;
}

MilitaryCellState *MilitaryCore::cell_state(int32_t cell, bool create) {
    if (cell < 0 || cell >= _terrain.cell_count) return nullptr;
    // Flat occupancy mirror (stamp-free: rebuilt on restore, kept in sync here)
    // avoids a memmove of the whole sparse vector for every new cell.
    if (_cell_state_index.size() != (size_t)_terrain.cell_count) {
        _cell_state_index.assign((size_t)_terrain.cell_count, -1);
        for (size_t i = 0; i < _cell_states.size(); ++i) {
            const int32_t c = _cell_states[i].cell;
            if (c >= 0 && (size_t)c < _cell_state_index.size()) _cell_state_index[(size_t)c] = (int32_t)i;
        }
    }
    int32_t idx = _cell_state_index[(size_t)cell];
    if (idx >= 0 && (size_t)idx < _cell_states.size() && _cell_states[(size_t)idx].cell == cell) {
        return &_cell_states[(size_t)idx];
    }
    if (!create) return nullptr;
    MilitaryCellState st;
    st.cell = cell;
    // Keep rows sorted by cell (posts_for_cell binary-searches; PKMI restore sorts).
    auto it = std::lower_bound(_cell_states.begin(), _cell_states.end(), cell,
                               [](const MilitaryCellState &row, int32_t c) { return row.cell < c; });
    idx = (int32_t)(it - _cell_states.begin());
    _cell_states.insert(it, st);
    for (size_t i = (size_t)idx; i < _cell_states.size(); ++i) _cell_state_index[(size_t)_cell_states[i].cell] = (int32_t)i;
    return &_cell_states[(size_t)idx];
}

// Kept next to `cell_state` because it is the only other writer of the cache
// fields: everything else in this TU only reads them.
void MilitaryCore::refresh_state_building_cache(const MilitaryWorldDigest &digest) {
    // No lane at all means the producer predates this contract; the cache the
    // save restored is the only truth available, so leave it untouched.
    if (!digest.state_lanes_present) return;
    const size_t rows = std::min((size_t)std::max(0, digest.state_lane_rows),
        std::min(digest.state_cell.size(),
            std::min(digest.state_type_id.size(),
                std::min(digest.state_state_role.size(), digest.state_units.size()))));
    // Resolve each ledger row through the military catalog: `state_role` in the
    // digest is the economy's copy and is only used to detect drift, while the
    // military catalog stays the authority on what tier a lot represents.
    struct LedgerRow {
        int32_t cell;
        int32_t role;
        int32_t tier;
        int64_t units;
    };
    static thread_local std::vector<LedgerRow> parsed;
    parsed.clear();
    parsed.reserve(rows);
    for (size_t i = 0; i < rows; ++i) {
        const int32_t cell = digest.state_cell[i];
        const int32_t type_id = digest.state_type_id[i];
        const int64_t units = digest.state_units[i];
        if (cell < 0 || cell >= _terrain.cell_count || units <= 0) continue;
        int32_t role = -1;
        int32_t tier = -1;
        for (const MilitaryStateBuilding &b : _catalog.state_buildings) {
            if (b.economy_building_id != type_id) continue;
            role = (int32_t)b.role;
            tier = (int32_t)b.tier;
            break;
        }
        if (role < 0) {
            // A kind-3 lot with no military profile cannot contribute posts,
            // fort bonus or training speed. Report it instead of guessing a tier.
            ++_report.state_ledger_unmapped;
            continue;
        }
        if (digest.state_state_role[i] != role + 1) ++_report.state_role_mismatch;
        parsed.push_back({cell, role, tier, units});
    }
    // The producer reports rows sorted by (cell, type) and this function relies
    // on cell order twice, so the sort is enforced here rather than assumed:
    // a producer that ever changes its ordering would otherwise silently make
    // the divergence probe compare the wrong cells.
    std::stable_sort(parsed.begin(), parsed.end(),
        [](const LedgerRow &a, const LedgerRow &b) {
            if (a.cell != b.cell) return a.cell < b.cell;
            if (a.role != b.role) return a.role < b.role;
            return a.tier < b.tier;
        });
    // Divergence probe (requirement 6.4). The cache on entry is exactly what
    // yesterday's rebuild wrote, unless something else in this TU touched it -
    // which is the bug this counter exists to surface. "Yesterday's rebuild" is
    // reconstructible from `_state_ledger_prev`, so a legitimate arrival or
    // demolition (the ledger itself changed) is not mistaken for a stale cache.
    if (_state_ledger_prev_valid) {
        struct CachedCell {
            int32_t cell;
            int32_t barracks[MILITARY_STATE_BARRACKS_TIERS];
            int32_t fort;
            int32_t college;
        };
        static thread_local std::vector<CachedCell> expected;
        expected.clear();
        for (size_t i = 0; i < _state_ledger_prev.size();) {
            const int32_t cell = _state_ledger_prev[i].cell;
            CachedCell row;
            row.cell = cell;
            std::fill(row.barracks, row.barracks + MILITARY_STATE_BARRACKS_TIERS, 0);
            row.fort = -1;
            row.college = -1;
            while (i < _state_ledger_prev.size() && _state_ledger_prev[i].cell == cell) {
                const StateLedgerRow &prev = _state_ledger_prev[i];
                if (prev.role == (int32_t)MILITARY_STATE_BARRACKS) {
                    const int32_t tier = clamp32(prev.tier, 0, MILITARY_STATE_BARRACKS_TIERS - 1);
                    row.barracks[tier] += prev.units;
                } else if (prev.role == (int32_t)MILITARY_STATE_FORTIFICATION) {
                    row.fort = std::max<int32_t>(row.fort, prev.tier);
                } else {
                    row.college = std::max<int32_t>(row.college, prev.tier);
                }
                ++i;
            }
            expected.push_back(row);
        }
        // Both sides are sorted by cell, so one merge walk answers every cell.
        size_t cursor = 0;
        for (const MilitaryCellState &st : _cell_states) {
            while (cursor < expected.size() && expected[cursor].cell < st.cell) {
                // A cell the ledger believed in that no longer has a row: its
                // cache watched a building disappear without the ledger saying
                // so. The rebuild below creates the row again, so only the
                // mismatch is counted.
                for (int32_t t = 0; t < MILITARY_STATE_BARRACKS_TIERS; ++t) {
                    if (expected[cursor].barracks[t] != 0) { ++_report.state_cache_repairs; break; }
                }
                ++cursor;
            }
            bool same = true;
            if (cursor < expected.size() && expected[cursor].cell == st.cell) {
                const CachedCell &want = expected[cursor];
                same = want.fort == st.fort_tier && want.college == st.college_tier;
                for (int32_t t = 0; t < MILITARY_STATE_BARRACKS_TIERS && same; ++t) {
                    if (want.barracks[t] != st.barracks_count[t]) same = false;
                }
                ++cursor;
            } else {
                // No ledger row yesterday: the cache must be empty too.
                same = st.fort_tier < 0 && st.college_tier < 0;
                for (int32_t t = 0; t < MILITARY_STATE_BARRACKS_TIERS && same; ++t) {
                    if (st.barracks_count[t] != 0) same = false;
                }
            }
            if (!same) ++_report.state_cache_repairs;
        }
    }
    // Clear: a cell whose lots were all demolished must read as "no building",
    // and the ledger rows below are the only thing that may put one back.
    for (MilitaryCellState &st : _cell_states) {
        std::fill(st.barracks_count, st.barracks_count + MILITARY_STATE_BARRACKS_TIERS, 0);
        st.fort_tier = -1;
        st.college_tier = -1;
    }
    for (const LedgerRow &row : parsed) {
        MilitaryCellState *st = cell_state(row.cell, true);
        if (st == nullptr) continue;
        if (row.role == (int32_t)MILITARY_STATE_BARRACKS) {
            const int32_t tier = clamp32(row.tier, 0, MILITARY_STATE_BARRACKS_TIERS - 1);
            st->barracks_count[tier] += (int32_t)row.units;
        } else if (row.role == (int32_t)MILITARY_STATE_FORTIFICATION) {
            st->fort_tier = std::max<int32_t>(st->fort_tier, row.tier);
        } else {
            st->college_tier = std::max<int32_t>(st->college_tier, row.tier);
        }
    }
    // Remember what this rebuild produced, sorted by cell, so tomorrow can tell
    // a stale cache apart from a changed ledger.
    _state_ledger_prev.clear();
    _state_ledger_prev.reserve(parsed.size());
    for (const LedgerRow &row : parsed) {
        StateLedgerRow out;
        out.cell = row.cell;
        out.role = row.role;
        out.tier = row.tier;
        out.units = (int32_t)row.units;
        _state_ledger_prev.push_back(out);
    }
    _state_ledger_prev_valid = true;
}

// ============================================================== army cache

int32_t MilitaryCore::militia_era(int32_t country_slot) const {
    if (country_slot < 0) return 0;
    if ((size_t)country_slot < _country_era.size()) return _country_era[(size_t)country_slot];
    if ((size_t)country_slot < _last_digest.country_era.size()) return _last_digest.country_era[(size_t)country_slot];
    return 0;
}

void MilitaryCore::refresh_army_cache(int32_t army_slot) {
    if (!army_alive(_armies, army_slot)) return;
    const size_t a = (size_t)army_slot;
    const int32_t owner = _armies.owner_slot[a];
    int64_t head = 0;
    int64_t attack = 0;
    int64_t defense = 0;
    int32_t speed_q16 = INT32_MAX;
    for (int32_t li = military_lot_head(*this, (uint8_t)MILITARY_LOT_ARMY, army_slot); li >= 0;
         li = _lot_next[(size_t)li]) {
        const size_t i = (size_t)li;
        if (!_lots.active[i]) continue;
        if (_lots.location_kind[i] != (uint8_t)MILITARY_LOT_ARMY) continue;
        if (_lots.location[i] != army_slot) continue;
        const int32_t unit = _lots.unit_type[i];
        if (unit < 0 || (size_t)unit >= _catalog.units.size()) continue;
        const MilitaryUnitType &u = _catalog.units[(size_t)unit];
        const int64_t cnt = _lots.count[i];
        if (cnt <= 0) continue;
        head += cnt;
        const int64_t eq = lot_equip_factor_q16(u, _lots.equip_quality_q8[i],
            _lots.kit_q16[i], _lots.partial_equipment[i]);
        const int64_t cond = clamp64(_lots.condition_q16[i], MILITARY_Q16 / 2, MILITARY_Q16);
        const int64_t cond_factor = MILITARY_Q16 / 2 + cond / 2;   // 0.5 + 0.5 * condition
        const int64_t power = mul_div(cnt * eq, cond_factor, MILITARY_Q16);   // heads * factors
        int64_t atk = u.attack_q16;
        int64_t def = u.defense_q16;
        if (unit == _catalog.militia_unit) {
            const int64_t era = era_factor_militia_q16(militia_era(owner));
            atk = mul_div(atk, era, MILITARY_Q16);
            def = mul_div(def, era, MILITARY_Q16);
        }
        attack += mul_div(power, atk, MILITARY_Q16);
        defense += mul_div(power, def, MILITARY_Q16);
        const int32_t spd = u.speed_q16;   // militia speed stays 1.0 across eras
        if (spd < speed_q16) speed_q16 = spd;
    }
    _armies.cached_headcount[a] = head;
    _armies.cached_attack_q16[a] = attack;
    _armies.cached_defense_q16[a] = defense;
    _armies.cached_speed_q16[a] = head > 0 ? speed_q16 : 0;
}

// ============================================================== queries

int64_t MilitaryCore::country_soldiers(int32_t slot) const {
    const size_t n = _lots.active.size();
    int64_t total = 0;
    for (size_t i = 0; i < n; ++i) {
        if (_lots.active[i] && _lots.country_slot[i] == slot) total += _lots.count[i];
    }
    return total;
}

int32_t MilitaryCore::posts_for_cell(int32_t cell, int32_t country_slot) const {
    if (cell < 0 || cell >= _terrain.cell_count) return 0;
    size_t lo = 0, hi = _cell_states.size();
    while (lo < hi) {
        const size_t mid = (lo + hi) / 2;
        if (_cell_states[mid].cell < cell) lo = mid + 1; else hi = mid;
    }
    if (lo >= _cell_states.size() || _cell_states[lo].cell != cell) return 0;
    const MilitaryCellState &st = _cell_states[lo];
    int64_t posts = 0;
    for (int32_t tier = 0; tier < 8; ++tier) {
        const int32_t count = st.barracks_count[tier];
        if (count <= 0) continue;
        posts += (int64_t)count * (int64_t)barracks_capacity_for_tier(_catalog, tier);
    }
    // B1: barracks capacity scales the summed posts. `MSTAT_BARRACKS_CAPACITY`
    // is q16 with a 1.0 base (military_core.h), so the multiply divides by the
    // same constant the stat is expressed in: at 65536 the result is bit-equal
    // to the unscaled sum (no rounding), and both war_bands and standing_army
    // cards reach this one read point.
    if (country_slot >= 0) {
        posts = mul_div(posts,
            static_cast<int64_t>(stat_q16(_last_digest, country_slot,
                MSTAT_BARRACKS_CAPACITY)),
            MILITARY_Q16);
    }
    if (posts > (int64_t)MILITARY_MAX_ARMIES * 256) posts = (int64_t)MILITARY_MAX_ARMIES * 256;
    return (int32_t)posts;
}

int64_t MilitaryCore::present_for_cell(int32_t cell) const {
    if (cell < 0 || cell >= _terrain.cell_count) return 0;
    int64_t present = 0;
    int32_t slot = _cell_head.empty() ? -1 : _cell_head[(size_t)cell];
    while (slot >= 0) {
        present += _armies.cached_headcount[(size_t)slot];
        slot = _armies.next_in_cell[(size_t)slot];
    }
    military_for_each_lot(*this, (uint8_t)MILITARY_LOT_GARRISON, cell,
                          [&](int32_t i) { present += _lots.count[(size_t)i]; });
    return present;
}

bool MilitaryCore::at_war(int32_t slot_a, int32_t slot_b) const {
    return war_between(slot_a, slot_b) >= 0;
}

int32_t MilitaryCore::war_between(int32_t slot_a, int32_t slot_b) const {
    if (slot_a < 0 || slot_b < 0 || slot_a == slot_b) return -1;
    for (const MilitaryWar &w : _wars) {
        if (!w.active) continue;
        if ((w.attacker_slot == slot_a && w.defender_slot == slot_b) ||
            (w.attacker_slot == slot_b && w.defender_slot == slot_a)) {
            return w.id;
        }
    }
    return -1;
}

} // namespace pk
