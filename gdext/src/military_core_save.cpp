// military_core_save.cpp - PKMI v2 encode/restore of the whole Military state
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

#include <algorithm>
#include <cstring>
#include <limits>
#include <vector>

namespace pk {

namespace {

constexpr uint16_t kSection_HeaderEnd = 0;
constexpr uint16_t kSection_Counters = 1;
constexpr uint16_t kSection_Pending = 2;
constexpr uint16_t kSection_Lots = 3;
constexpr uint16_t kSection_Training = 4;
constexpr uint16_t kSection_Armies = 5;
constexpr uint16_t kSection_PathArena = 6;
constexpr uint16_t kSection_Templates = 7;
constexpr uint16_t kSection_Stocks = 8;
constexpr uint16_t kSection_Shipments = 9;
constexpr uint16_t kSection_Engagements = 10;
constexpr uint16_t kSection_Wars = 11;
constexpr uint16_t kSection_Truces = 12;
constexpr uint16_t kSection_Reparations = 13;
constexpr uint16_t kSection_BattleLog = 14;
constexpr uint16_t kSection_Areas = 15;
constexpr uint16_t kSection_Policies = 16;
constexpr uint16_t kSection_CellStates = 17;
constexpr uint16_t kSection_Controller = 18;
constexpr uint16_t kSection_Ledger = 19;
constexpr uint16_t kSection_Events = 20;
constexpr uint16_t kSection_Ai = 21;
constexpr uint16_t kSection_IndexContinuation = 22;
constexpr uint16_t kSection_End = 0xFFFF;

// Sanity caps so a corrupt length can never trigger an enormous allocation.
constexpr uint32_t kMaxRows = 4u * 1024u * 1024u;
constexpr uint32_t kMaxStrings = 4096u;

class Writer {
public:
    std::vector<uint8_t> out;

    void u8(uint8_t v) { out.push_back(v); }
    void u16(uint16_t v) {
        out.push_back((uint8_t)(v & 0xFF));
        out.push_back((uint8_t)(v >> 8));
    }
    void u32(uint32_t v) {
        for (int i = 0; i < 4; ++i) out.push_back((uint8_t)((v >> (8 * i)) & 0xFF));
    }
    void u64(uint64_t v) {
        for (int i = 0; i < 8; ++i) out.push_back((uint8_t)((v >> (8 * i)) & 0xFF));
    }
    void i8(int8_t v) { u8((uint8_t)v); }
    void i16(int16_t v) { u16((uint16_t)v); }
    void i32(int32_t v) { u32((uint32_t)v); }
    void i64(int64_t v) { u64((uint64_t)v); }
    void f64(double v) {
        uint64_t bits = 0;
        std::memcpy(&bits, &v, sizeof(bits));
        u64(bits);
    }
    void str(const std::string &s) {
        u32((uint32_t)s.size());
        out.insert(out.end(), s.begin(), s.end());
    }
    void begin(uint16_t id) {
        u16(id);
        u32(0);   // patched by end()
        _patch.push_back(out.size() - 4);
    }
    void end() {
        const size_t patch = _patch.back();
        _patch.pop_back();
        const uint32_t len = (uint32_t)(out.size() - patch - 4);
        for (int i = 0; i < 4; ++i) out[patch + (size_t)i] = (uint8_t)((len >> (8 * i)) & 0xFF);
    }

private:
    std::vector<size_t> _patch;
};

class Reader {
public:
    Reader(const uint8_t *data, size_t size) : _data(data), _size(size) {}

    bool ok() const { return _ok; }
    size_t pos() const { return _pos; }
    size_t remaining() const { return _ok ? _size - _pos : 0; }
    bool need(size_t n) {
        if (!_ok || _pos + n > _size) {
            _ok = false;
            return false;
        }
        return true;
    }
    uint8_t u8() {
        if (!need(1)) return 0;
        return _data[_pos++];
    }
    uint16_t u16() {
        if (!need(2)) return 0;
        const uint16_t v = (uint16_t)(_data[_pos] | ((uint16_t)_data[_pos + 1] << 8));
        _pos += 2;
        return v;
    }
    uint32_t u32() {
        if (!need(4)) return 0;
        uint32_t v = 0;
        for (int i = 0; i < 4; ++i) v |= (uint32_t)_data[_pos + (size_t)i] << (8 * i);
        _pos += 4;
        return v;
    }
    uint64_t u64() {
        if (!need(8)) return 0;
        uint64_t v = 0;
        for (int i = 0; i < 8; ++i) v |= (uint64_t)_data[_pos + (size_t)i] << (8 * i);
        _pos += 8;
        return v;
    }
    int8_t i8() { return (int8_t)u8(); }
    int16_t i16() { return (int16_t)u16(); }
    int32_t i32() { return (int32_t)u32(); }
    int64_t i64() { return (int64_t)u64(); }
    double f64() {
        const uint64_t bits = u64();
        double v = 0.0;
        std::memcpy(&v, &bits, sizeof(v));
        return v;
    }
    std::string str() {
        const uint32_t n = u32();
        if (n > kMaxStrings * 64u) {
            _ok = false;
            return std::string();
        }
        if (!need(n)) return std::string();
        std::string s((const char *)(_data + _pos), n);
        _pos += n;
        return s;
    }
    uint32_t open_section() {
        const uint16_t id = u16();
        const uint32_t len = u32();
        if (!_ok) return 0;
        if (id == kSection_End) {   // END carries a checksum (magic ^ size), not a length
            _section_end = _pos;
            return id;
        }
        if (len > remaining()) {
            _ok = false;
            return 0;
        }
        _section_end = _pos + len;
        return id;
    }
    void close_section() {
        if (!_ok) return;
        if (_pos != _section_end) {
            // Tolerate forward-compatible extra bytes inside a section.
            if (_section_end > _pos) _pos = _section_end;
        }
    }

private:
    const uint8_t *_data = nullptr;
    size_t _size = 0;
    size_t _pos = 0;
    size_t _section_end = 0;
    bool _ok = true;
};

// -------------------------------------------------------------- writers

void write_lots(Writer &w, const MilitaryLotStore &s) {
    w.u32((uint32_t)s.active.size());
    for (size_t i = 0; i < s.active.size(); ++i) {
        w.u8(s.active[i]);
        if (!s.active[i]) continue;
        w.u8(s.location_kind[i]);
        w.i32(s.location[i]);
        w.i32(s.country_slot[i]);
        w.i16(s.unit_type[i]);
        w.i16(s.equip_quality_q8[i]);
        w.i32(s.condition_q16[i]);
        w.i64(s.count[i]);
    }
}

void write_armies(Writer &w, const MilitaryArmyStore &s) {
    w.u32((uint32_t)s.active.size());
    for (size_t i = 0; i < s.active.size(); ++i) {
        w.u8(s.active[i]);
        if (!s.active[i]) continue;
        w.u32(s.generation[i]);
        w.i32(s.owner_slot[i]);
        w.i32(s.cell[i]);
        w.i32(s.next_cell[i]);
        w.i32(s.move_points_q16[i]);
        w.u8(s.stance[i]);
        w.u8(s.mission[i]);
        w.i32(s.target_cell[i]);
        w.i32(s.area_id[i]);
        w.i32(s.organization_q16[i]);
        w.i32(s.morale_q16[i]);
        w.i32(s.supply_ratio_q16[i]);
        w.i32(s.ration_ratio_q16[i]);
        w.i32(s.pay_ratio_q16[i]);
        // Path spans are stored relative to the compacted arena; encode() has
        // already remapped path_offset into the compacted numbering.
        w.i32(s.path_offset[i]);
        w.i32(s.path_len[i]);
        w.i32(s.path_cursor[i]);
        w.u8(s.reinforce_enabled[i]);
        w.i32(s.template_offset[i]);
        w.i32(s.template_len[i]);
        w.u64(s.commander_slot[i]);
        w.i64(s.cached_headcount[i]);
        w.i64(s.cached_attack_q16[i]);
        w.i64(s.cached_defense_q16[i]);
        w.i32(s.cached_speed_q16[i]);
        w.i32(s.engagement[i]);
        w.i64(s.moved_day[i]);
        w.i32(s.prev_cell[i]);
        w.u32(s.name_seed[i]);
        w.i64(s.funds[i]);
    }
}

void write_policies(Writer &w, const MilitaryCore &core) {
    w.u32((uint32_t)core._policies.size());
    for (size_t i = 0; i < core._policies.size(); ++i) {
        const MilitaryCountryPolicy &p = core._policies[i];
        w.u64(i < core._policy_handle.size() ? core._policy_handle[i] : 0);
        w.u8(p.target_mode);
        w.i64(p.target_value);
        w.i64(p.effective_target);
        w.u8(p.levy_enabled);
        w.u8(p.auto_retrain);
        w.u8(p.auto_discharge);
        w.u8(p.quality_policy);
        w.u8(p.wage_mode);
        w.i64(p.wage_absolute);
        w.i32(p.procurement_share_bp);
        w.i32(p.pay_ratio_30_q16);
        w.i64(p.spend_payroll_30);
        w.i64(p.spend_procurement_30);
        w.i64(p.spend_upkeep_30);
        w.i64(p.per_soldier_cost);
        w.u32((uint32_t)p.config_share_bp.size());
        for (int32_t bp : p.config_share_bp) w.i32(bp);
    }
}


template<class T> void write_index_vector(Writer &w, const std::vector<T> &values) {
    w.u32((uint32_t)values.size());
    for (T value : values) w.i64((int64_t)value);
}
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
void write_index_continuation(Writer &w, const MilitaryCore &c) {
    write_index_vector(w, c._lots.location_kind);
    write_index_vector(w, c._lots.location);
    write_index_vector(w, c._lots.country_slot);
    write_index_vector(w, c._lots.unit_type);
    write_index_vector(w, c._lots.equip_quality_q8);
    write_index_vector(w, c._lots.condition_q16);
    write_index_vector(w, c._lots.count);
    write_index_vector(w, c._lots.free_list);
    w.u8(c._lot_index_ok ? 1 : 0);
    write_index_vector(w, c._lot_next);
    write_index_vector(w, c._lot_link_kind);
    write_index_vector(w, c._lot_link_loc);
    write_index_vector(w, c._lot_army_head);
    write_index_vector(w, c._lot_cell_head);
    write_index_vector(w, c._armies.generation);
    write_index_vector(w, c._armies.free_list);
    write_index_vector(w, c._army_lane_pending);
}
bool read_index_continuation(Reader &r, MilitaryCore &c) {
    if (!read_index_vector(r, c._lots.location_kind) ||
        !read_index_vector(r, c._lots.location) ||
        !read_index_vector(r, c._lots.country_slot) ||
        !read_index_vector(r, c._lots.unit_type) ||
        !read_index_vector(r, c._lots.equip_quality_q8) ||
        !read_index_vector(r, c._lots.condition_q16) ||
        !read_index_vector(r, c._lots.count) ||
        !read_index_vector(r, c._lots.free_list)) return false;
    c._lot_index_ok = r.u8() != 0;
    return read_index_vector(r, c._lot_next) &&
        read_index_vector(r, c._lot_link_kind) && read_index_vector(r, c._lot_link_loc) &&
        read_index_vector(r, c._lot_army_head) && read_index_vector(r, c._lot_cell_head) &&
        read_index_vector(r, c._armies.generation) && read_index_vector(r, c._armies.free_list) &&
        read_index_vector(r, c._army_lane_pending);
}
bool valid_index_continuation(const MilitaryCore &c) {
    const size_t n = c._lots.active.size();
    if (c._lots.location_kind.size() != n || c._lots.location.size() != n ||
        c._lots.country_slot.size() != n || c._lots.unit_type.size() != n ||
        c._lots.equip_quality_q8.size() != n || c._lots.condition_q16.size() != n ||
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
    return walk(c._lot_army_head, (uint8_t)MILITARY_LOT_ARMY) &&
        walk(c._lot_cell_head, (uint8_t)MILITARY_LOT_GARRISON);
}

} // namespace

// ============================================================== encode

std::vector<uint8_t> MilitaryCore::encode() const {

    Writer w;
    w.out.reserve(1u << 16);
    // ---- header
    w.u32(PKMI_MAGIC);
    w.u32(PKMI_VERSION);
    w.u64(_catalog.hash);
    w.u64(_seed);
    w.i32(_terrain.cell_count);
    w.i32(_terrain.width);
    w.i32(_terrain.height);
    w.i64(_last_day);

    // ---- counters
    w.begin(kSection_Counters);
    w.u64(_next_sequence);
    w.u64(_next_id);
    w.u64(_next_event_id);
    w.u64(_control_revision);
    w.u64(_front_revision);
    w.u32((uint32_t)_path_daily_requests.size());
    for (int32_t n : _path_daily_requests) w.i32(n);
    w.u32((uint32_t)_pending.size());
    w.end();

    // ---- pending commands
    w.begin(kSection_Pending);
    w.u32((uint32_t)_pending.size());
    for (const MilitaryCommand &c : _pending) {
        w.u16(c.op);
        w.i64(c.effective_day);
        w.u64(c.sequence);
        w.u64(c.country);
        w.u64(c.army);
        w.u64(c.other);
        w.i32(c.cell);
        w.i32(c.radius);
        w.i32(c.unit_from);
        w.i32(c.unit_to);
        w.i64(c.count);
        w.i64(c.value);
        w.u32((uint32_t)c.cells.size());
        for (int32_t v : c.cells) w.i32(v);
        w.u32((uint32_t)c.ints.size());
        for (int32_t v : c.ints) w.i32(v);
        w.u32((uint32_t)c.longs.size());
        for (int64_t v : c.longs) w.i64(v);
    }
    w.end();

    // ---- lots
    w.begin(kSection_Lots);
    write_lots(w, _lots);
    w.end();

    // ---- training orders
    w.begin(kSection_Training);
    w.u32((uint32_t)_training.size());
    for (const MilitaryTrainingOrder &o : _training) {
        w.u64(o.id);
        w.i32(o.country_slot);
        w.i32(o.cell);
        w.i16(o.from_unit);
        w.i16(o.to_unit);
        w.i64(o.count);
        w.i32(o.days_total);
        w.i32(o.days_done);
        w.u8(o.equipment_ready);
        w.u8(o.manual);
        w.i16(o.quality_q8);
    }
    w.end();

    // ---- armies (with a compacted path arena and template arena)
    std::vector<int32_t> path_out;
    std::vector<int32_t> template_out;
    std::vector<int32_t> remap_off(_armies.active.size(), 0);
    std::vector<int32_t> remap_tpl(_armies.active.size(), 0);
    for (size_t i = 0; i < _armies.active.size(); ++i) {
        if (!_armies.active[i]) continue;
        const int32_t off = _armies.path_offset[i];
        const int32_t len = _armies.path_len[i];
        if (off >= 0 && len > 0 && (size_t)(off + len) <= _path_cells.size()) {
            remap_off[i] = (int32_t)path_out.size();
            path_out.insert(path_out.end(), _path_cells.begin() + off, _path_cells.begin() + off + len);
        } else {
            remap_off[i] = 0;
        }
        const int32_t toff = _armies.template_offset[i];
        const int32_t tlen = _armies.template_len[i];
        if (toff >= 0 && tlen > 0 && (size_t)(toff + tlen) <= _template_rows.size()) {
            remap_tpl[i] = (int32_t)template_out.size();
            template_out.insert(template_out.end(), _template_rows.begin() + toff,
                                _template_rows.begin() + toff + tlen);
        } else {
            remap_tpl[i] = 0;
        }
    }
    w.begin(kSection_Armies);
    {
        // Write armies with remapped spans by temporarily shadowing the offsets.
        MilitaryArmyStore shadow = _armies;
        for (size_t i = 0; i < shadow.active.size(); ++i) {
            if (!shadow.active[i]) continue;
            shadow.path_offset[i] = remap_off[i];
            shadow.template_offset[i] = remap_tpl[i];
        }
        write_armies(w, shadow);
    }
    w.end();

    w.begin(kSection_PathArena);
    w.u32((uint32_t)path_out.size());
    for (int32_t v : path_out) w.i32(v);
    w.end();

    w.begin(kSection_Templates);
    w.u32((uint32_t)template_out.size());
    for (int32_t v : template_out) w.i32(v);
    w.end();

    // ---- stocks
    w.begin(kSection_Stocks);
    w.u32((uint32_t)_stocks.size());
    for (const MilitaryStockRow &r : _stocks) {
        w.u8(r.holder_kind);
        w.i32(r.holder);
        w.i32(r.country_slot);
        w.i32(r.good);
        w.i64(r.qty);
    }
    w.end();

    // ---- shipments
    w.begin(kSection_Shipments);
    w.u32((uint32_t)_shipments.size());
    for (const MilitaryShipment &s : _shipments) {
        w.u64(s.id);
        w.i32(s.country_slot);
        w.u8(s.dest_kind);
        w.i32(s.dest);
        w.u64(s.dest_handle);
        w.i32(s.origin_cell);
        w.i32(s.current_cell);
        w.i32(s.good);
        w.i64(s.qty);
        w.i64(s.value);
        w.i64(s.departure_day);
        w.i64(s.eta_day);
        w.i32(s.route_cost_q16);
        w.i32(s.progress_q16);
        w.i32(s.blocked_days);
    }
    w.end();

    // ---- engagements
    w.begin(kSection_Engagements);
    w.u32((uint32_t)_engagements.size());
    for (const MilitaryEngagement &e : _engagements) {
        w.i32(e.cell_a);
        w.i32(e.cell_b);
        w.i32(e.attacker_side_cell);
        w.i32(e.attacker_slot);
        w.i32(e.defender_slot);
        w.i32(e.war_id);
        w.i32(e.progress_q16);
        w.i64(e.start_day);
        w.i32(e.idle_days);
        w.i32(e.days_since_battle);
        w.i64(e.casualties_attacker);
        w.i64(e.casualties_defender);
        w.u8(e.active);
    }
    w.end();

    // ---- wars
    w.begin(kSection_Wars);
    w.u32((uint32_t)_wars.size());
    for (const MilitaryWar &x : _wars) {
        w.i32(x.id);
        w.i32(x.attacker_slot);
        w.i32(x.defender_slot);
        w.u64(x.attacker_handle);
        w.u64(x.defender_handle);
        w.i64(x.start_day);
        w.i32(x.score_battle_q16);
        w.i32(x.score_annihilation_q16);
        w.i32(x.score_attrition_q16);
        w.i64(x.attacker_losses);
        w.i64(x.defender_losses);
        w.i64(x.last_rejected_offer_day_a);
        w.i64(x.last_rejected_offer_day_b);
        w.i64(x.fully_occupied_since_a);
        w.i64(x.fully_occupied_since_b);
        w.u8(x.active);
    }
    w.end();

    // ---- truces
    w.begin(kSection_Truces);
    w.u32((uint32_t)_truces.size());
    for (const MilitaryTruce &t : _truces) {
        w.i32(t.slot_a);
        w.i32(t.slot_b);
        w.i64(t.until_day);
    }
    w.end();

    // ---- reparation schedules
    w.begin(kSection_Reparations);
    w.u32((uint32_t)_reparations.size());
    for (const MilitaryReparation &r : _reparations) {
        w.u64(r.payer);
        w.u64(r.receiver);
        w.i64(r.installment);
        w.i32(r.remaining);
        w.i64(r.next_day);
        w.i64(r.arrears);
        w.i32(r.war_id);
    }
    w.end();

    // ---- battle log (last MILITARY_BATTLE_LOG_CAPACITY rows)
    w.begin(kSection_BattleLog);
    {
        const size_t keep = std::min<size_t>(_battle_log.size(), (size_t)MILITARY_BATTLE_LOG_CAPACITY);
        const size_t first = _battle_log.size() - keep;
        w.u32((uint32_t)keep);
        for (size_t i = first; i < _battle_log.size(); ++i) {
            const MilitaryBattleLogRow &b = _battle_log[i];
            w.i64(b.day);
            w.i32(b.cell);
            w.i32(b.war_id);
            w.i32(b.winner_slot);
            w.i32(b.loser_slot);
            w.i64(b.winner_losses);
            w.i64(b.loser_losses);
            w.i32(b.score_gain_q16);
        }
    }
    w.end();

    // ---- areas
    w.begin(kSection_Areas);
    w.u32((uint32_t)_areas.size());
    for (const MilitaryArea &a : _areas) {
        w.i32(a.id);
        w.i32(a.owner_slot);
        w.i64(a.last_eval_day);
        w.u8(a.active);
        w.u32((uint32_t)a.cells.size());
        for (int32_t c : a.cells) w.i32(c);
    }
    w.end();

    // ---- per-country policy
    w.begin(kSection_Policies);
    write_policies(w, *this);
    w.end();

    // ---- sparse cell state
    w.begin(kSection_CellStates);
    w.u32((uint32_t)_cell_states.size());
    for (const MilitaryCellState &st : _cell_states) {
        w.i32(st.cell);
        for (int32_t t = 0; t < 8; ++t) w.i32(st.barracks_count[t]);
        w.i32(st.fort_tier);
        w.i32(st.college_tier);
        w.u8(st.paused);
        w.u8(st.disrepair);
        w.i64(st.pending_enlist);
        w.i64(st.quota);
        w.i64(st.requisition_until_day);
        for (int32_t k = 0; k < 3; ++k) {
            w.i64(st.construction_done_day[k]);
            w.i32(st.construction_building[k]);
        }
    }
    w.end();

    // ---- cell controller (sparse: write (cell, slot) pairs)
    w.begin(kSection_Controller);
    {
        uint32_t count = 0;
        for (int32_t v : _cell_controller) {
            if (v >= 0) ++count;
        }
        w.u32((uint32_t)_cell_controller.size());
        w.u32(count);
        for (size_t i = 0; i < _cell_controller.size(); ++i) {
            if (_cell_controller[i] < 0) continue;
            w.i32((int32_t)i);
            w.i32(_cell_controller[i]);
        }
    }
    w.end();

    // ---- ledger
    w.begin(kSection_Ledger);
    w.i64(_ledger_received);
    w.i64(_ledger_consumed);
    w.i64(_ledger_intercepted_out);
    w.i64(_ledger_intercepted_in);
    w.i64(_ledger_returned);
    w.i64(_ledger_stock);
    w.i64(_ledger_transit);
    w.end();

    // ---- events ring
    w.begin(kSection_Events);
    w.u32((uint32_t)_events.size());
    for (const MilitaryEvent &e : _events) {
        w.u64(e.id);
        w.i64(e.day);
        w.u16(e.type);
        w.u16(e.payload_schema);
        w.i32(e.cell);
        w.u64(e.i0);
        w.u64(e.i1);
        w.u64(e.i2);
        w.u64(e.i3);
        w.i64(e.value);
    }
    w.end();

    // ---- AI agenda memory
    w.begin(kSection_Ai);
    w.u32((uint32_t)_ai_country.size());
    for (size_t i = 0; i < _ai_country.size(); ++i) {
        w.u8(_ai_country[i]);
        w.i64(i < _ai_next_decision_day.size() ? _ai_next_decision_day[i] : 0);
    }
    w.end();

    w.begin(kSection_IndexContinuation);
    write_index_continuation(w, *this);
    w.end();

    w.u16(kSection_End);
    w.u32(PKMI_MAGIC ^ (uint32_t)w.out.size());
    return w.out;
}

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
        error = "pkmi_version_mismatch_expected_2";
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
            case kSection_Pending: {
                const uint32_t n = r.u32();
                if (n > kMaxRows) {
                    error = "pkmi_bad_pending";
                    return false;
                }
                tmp._pending.clear();
                tmp._pending.reserve(n);
                for (uint32_t i = 0; i < n; ++i) {
                    MilitaryCommand c;
                    c.op = r.u16();
                    c.effective_day = r.i64();
                    c.sequence = r.u64();
                    c.country = r.u64();
                    c.army = r.u64();
                    c.other = r.u64();
                    c.cell = r.i32();
                    c.radius = r.i32();
                    c.unit_from = r.i32();
                    c.unit_to = r.i32();
                    c.count = r.i64();
                    c.value = r.i64();
                    uint32_t m = r.u32();
                    if (m > kMaxRows) {
                        error = "pkmi_bad_pending";
                        return false;
                    }
                    c.cells.resize(m);
                    for (uint32_t k = 0; k < m; ++k) c.cells[k] = r.i32();
                    m = r.u32();
                    if (m > kMaxRows) {
                        error = "pkmi_bad_pending";
                        return false;
                    }
                    c.ints.resize(m);
                    for (uint32_t k = 0; k < m; ++k) c.ints[k] = r.i32();
                    m = r.u32();
                    if (m > kMaxRows) {
                        error = "pkmi_bad_pending";
                        return false;
                    }
                    c.longs.resize(m);
                    for (uint32_t k = 0; k < m; ++k) c.longs[k] = r.i64();
                    if (!r.ok()) break;
                    tmp._pending.push_back(std::move(c));
                }
                break;
            }
            case kSection_Lots: {
                const uint32_t n = r.u32();
                if (n > kMaxRows) {
                    error = "pkmi_bad_lots";
                    return false;
                }
                tmp._lots = MilitaryLotStore();
                for (uint32_t i = 0; i < n; ++i) {
                    const uint8_t active = r.u8();
                    if (!active) {
                        tmp._lots.active.push_back(0);
                        tmp._lots.location_kind.push_back(0);
                        tmp._lots.location.push_back(-1);
                        tmp._lots.country_slot.push_back(-1);
                        tmp._lots.unit_type.push_back(-1);
                        tmp._lots.equip_quality_q8.push_back(256);
                        tmp._lots.condition_q16.push_back(MILITARY_Q16);
                        tmp._lots.count.push_back(0);
                        tmp._lots.free_list.push_back((int32_t)i);
                        continue;
                    }
                    const uint8_t kind = r.u8();
                    const int32_t loc = r.i32();
                    const int32_t cslot = r.i32();
                    const int16_t unit = r.i16();
                    const int16_t quality = r.i16();
                    const int32_t cond = r.i32();
                    const int64_t count = r.i64();
                    if (!r.ok()) break;
                    if (kind > (uint8_t)MILITARY_LOT_ARMY || cslot < 0 ||
                        unit < 0 || (size_t)unit >= tmp._catalog.units.size() || count < 0) {
                        error = "pkmi_bad_lot_row";
                        return false;
                    }
                    tmp._lots.active.push_back(1);
                    tmp._lots.location_kind.push_back(kind);
                    tmp._lots.location.push_back(loc);
                    tmp._lots.country_slot.push_back(cslot);
                    tmp._lots.unit_type.push_back(unit);
                    tmp._lots.equip_quality_q8.push_back(quality);
                    tmp._lots.condition_q16.push_back(cond);
                    tmp._lots.count.push_back(count);
                }
                break;
            }
            case kSection_Training: {
                const uint32_t n = r.u32();
                if (n > kMaxRows) {
                    error = "pkmi_bad_training";
                    return false;
                }
                tmp._training.clear();
                tmp._training.reserve(n);
                for (uint32_t i = 0; i < n; ++i) {
                    MilitaryTrainingOrder o;
                    o.id = r.u64();
                    o.country_slot = r.i32();
                    o.cell = r.i32();
                    o.from_unit = r.i16();
                    o.to_unit = r.i16();
                    o.count = r.i64();
                    o.days_total = r.i32();
                    o.days_done = r.i32();
                    o.equipment_ready = r.u8();
                    o.manual = r.u8();
                    o.quality_q8 = r.i16();
                    if (!r.ok()) break;
                    tmp._training.push_back(o);
                }
                break;
            }
            case kSection_Armies: {
                // Restore into scratch arrays first because the arena spans are
                // remapped once the PathArena / Templates sections are read.
                MilitaryArmyStore store;
                const uint32_t n = r.u32();
                if (n != (uint32_t)MILITARY_MAX_ARMIES) {
                    error = "pkmi_bad_army_table";
                    return false;
                }
                const size_t cap = (size_t)n;
                store.generation.assign(cap, 0);
                store.active.assign(cap, 0);
                store.owner_slot.assign(cap, -1);
                store.cell.assign(cap, -1);
                store.next_cell.assign(cap, -1);
                store.move_points_q16.assign(cap, 0);
                store.stance.assign(cap, (uint8_t)MILITARY_STANCE_HOLD);
                store.mission.assign(cap, (uint8_t)MILITARY_MISSION_NONE);
                store.target_cell.assign(cap, -1);
                store.area_id.assign(cap, -1);
                store.organization_q16.assign(cap, MILITARY_Q16);
                store.morale_q16.assign(cap, MILITARY_Q16 / 2);
                store.supply_ratio_q16.assign(cap, MILITARY_Q16);
                store.ration_ratio_q16.assign(cap, MILITARY_Q16);
                store.pay_ratio_q16.assign(cap, MILITARY_Q16);
                store.path_offset.assign(cap, 0);
                store.path_len.assign(cap, 0);
                store.path_cursor.assign(cap, 0);
                store.reinforce_enabled.assign(cap, 0);
                store.template_offset.assign(cap, 0);
                store.template_len.assign(cap, 0);
                store.commander_slot.assign(cap, 0);
                store.cached_headcount.assign(cap, 0);
                store.cached_attack_q16.assign(cap, 0);
                store.cached_defense_q16.assign(cap, 0);
                store.cached_speed_q16.assign(cap, 0);
                store.engagement.assign(cap, -1);
                store.moved_day.assign(cap, -1);
                store.prev_cell.assign(cap, -1);
                store.name_seed.assign(cap, 0);
                store.funds.assign(cap, 0);
                store.next_in_cell.assign(cap, -1);
                store.prev_in_cell.assign(cap, -1);
                store.free_list.clear();
                for (uint32_t i = 0; i < n; ++i) {
                    const uint8_t active = r.u8();
                    if (!active) {
                        store.free_list.push_back((int32_t)i);
                        continue;
                    }
                    const size_t s = (size_t)i;
                    store.active[s] = 1;
                    store.generation[s] = r.u32();
                    store.owner_slot[s] = r.i32();
                    store.cell[s] = r.i32();
                    store.next_cell[s] = r.i32();
                    store.move_points_q16[s] = r.i32();
                    store.stance[s] = r.u8();
                    store.mission[s] = r.u8();
                    store.target_cell[s] = r.i32();
                    store.area_id[s] = r.i32();
                    store.organization_q16[s] = r.i32();
                    store.morale_q16[s] = r.i32();
                    store.supply_ratio_q16[s] = r.i32();
                    store.ration_ratio_q16[s] = r.i32();
                    store.pay_ratio_q16[s] = r.i32();
                    store.path_offset[s] = r.i32();   // compacted numbering
                    store.path_len[s] = r.i32();
                    store.path_cursor[s] = r.i32();
                    store.reinforce_enabled[s] = r.u8();
                    store.template_offset[s] = r.i32();   // compacted numbering
                    store.template_len[s] = r.i32();
                    store.commander_slot[s] = r.u64();
                    store.cached_headcount[s] = r.i64();
                    store.cached_attack_q16[s] = r.i64();
                    store.cached_defense_q16[s] = r.i64();
                    store.cached_speed_q16[s] = r.i32();
                    store.engagement[s] = r.i32();
                    store.moved_day[s] = r.i64();
                    store.prev_cell[s] = r.i32();
                    store.name_seed[s] = r.u32();
                    store.funds[s] = r.i64();
                    if (!r.ok()) break;
                }
                if (!r.ok()) break;
                tmp._armies = std::move(store);
                break;
            }
            case kSection_PathArena: {
                const uint32_t n = r.u32();
                if (n > kMaxRows) {
                    error = "pkmi_bad_path_arena";
                    return false;
                }
                remap_path.clear();
                remap_path.reserve(n);
                for (uint32_t i = 0; i < n; ++i) remap_path.push_back(r.i32());
                if (!r.ok()) break;
                tmp._path_cells.clear();
                break;
            }
            case kSection_Templates: {
                const uint32_t n = r.u32();
                if (n > kMaxRows) {
                    error = "pkmi_bad_templates";
                    return false;
                }
                remap_tpl.clear();
                remap_tpl.reserve(n);
                for (uint32_t i = 0; i < n; ++i) remap_tpl.push_back(r.i32());
                if (!r.ok()) break;
                tmp._template_rows.clear();
                break;
            }
            case kSection_Stocks: {
                const uint32_t n = r.u32();
                if (n > kMaxRows) {
                    error = "pkmi_bad_stocks";
                    return false;
                }
                tmp._stocks.clear();
                tmp._stocks.reserve(n);
                for (uint32_t i = 0; i < n; ++i) {
                    MilitaryStockRow row;
                    row.holder_kind = r.u8();
                    row.holder = r.i32();
                    row.country_slot = r.i32();
                    row.good = r.i32();
                    row.qty = r.i64();
                    if (!r.ok()) break;
                    tmp._stocks.push_back(row);
                }
                break;
            }
            case kSection_Shipments: {
                const uint32_t n = r.u32();
                if (n > kMaxRows) {
                    error = "pkmi_bad_shipments";
                    return false;
                }
                tmp._shipments.clear();
                tmp._shipments.reserve(n);
                for (uint32_t i = 0; i < n; ++i) {
                    MilitaryShipment s;
                    s.id = r.u64();
                    s.country_slot = r.i32();
                    s.dest_kind = r.u8();
                    s.dest = r.i32();
                    s.dest_handle = r.u64();
                    s.origin_cell = r.i32();
                    s.current_cell = r.i32();
                    s.good = r.i32();
                    s.qty = r.i64();
                    s.value = r.i64();
                    s.departure_day = r.i64();
                    s.eta_day = r.i64();
                    s.route_cost_q16 = r.i32();
                    s.progress_q16 = r.i32();
                    s.blocked_days = r.i32();
                    if (!r.ok()) break;
                    tmp._shipments.push_back(s);
                }
                break;
            }
            case kSection_Engagements: {
                const uint32_t n = r.u32();
                if (n > kMaxRows) {
                    error = "pkmi_bad_engagements";
                    return false;
                }
                tmp._engagements.clear();
                tmp._engagements.reserve(n);
                for (uint32_t i = 0; i < n; ++i) {
                    MilitaryEngagement e;
                    e.cell_a = r.i32();
                    e.cell_b = r.i32();
                    e.attacker_side_cell = r.i32();
                    e.attacker_slot = r.i32();
                    e.defender_slot = r.i32();
                    e.war_id = r.i32();
                    e.progress_q16 = r.i32();
                    e.start_day = r.i64();
                    e.idle_days = r.i32();
                    e.days_since_battle = r.i32();
                    e.casualties_attacker = r.i64();
                    e.casualties_defender = r.i64();
                    e.active = r.u8();
                    if (!r.ok()) break;
                    tmp._engagements.push_back(e);
                }
                break;
            }
            case kSection_Wars: {
                const uint32_t n = r.u32();
                if (n > kMaxRows) {
                    error = "pkmi_bad_wars";
                    return false;
                }
                tmp._wars.clear();
                tmp._wars.reserve(n);
                for (uint32_t i = 0; i < n; ++i) {
                    MilitaryWar x;
                    x.id = r.i32();
                    x.attacker_slot = r.i32();
                    x.defender_slot = r.i32();
                    x.attacker_handle = r.u64();
                    x.defender_handle = r.u64();
                    x.start_day = r.i64();
                    x.score_battle_q16 = r.i32();
                    x.score_annihilation_q16 = r.i32();
                    x.score_attrition_q16 = r.i32();
                    x.attacker_losses = r.i64();
                    x.defender_losses = r.i64();
                    x.last_rejected_offer_day_a = r.i64();
                    x.last_rejected_offer_day_b = r.i64();
                    x.fully_occupied_since_a = r.i64();
                    x.fully_occupied_since_b = r.i64();
                    x.active = r.u8();
                    if (!r.ok()) break;
                    tmp._wars.push_back(x);
                }
                break;
            }
            case kSection_Truces: {
                const uint32_t n = r.u32();
                if (n > kMaxRows) {
                    error = "pkmi_bad_truces";
                    return false;
                }
                tmp._truces.clear();
                tmp._truces.reserve(n);
                for (uint32_t i = 0; i < n; ++i) {
                    MilitaryTruce t;
                    t.slot_a = r.i32();
                    t.slot_b = r.i32();
                    t.until_day = r.i64();
                    if (!r.ok()) break;
                    tmp._truces.push_back(t);
                }
                break;
            }
            case kSection_Reparations: {
                const uint32_t n = r.u32();
                if (n > kMaxRows) {
                    error = "pkmi_bad_reparations";
                    return false;
                }
                tmp._reparations.clear();
                tmp._reparations.reserve(n);
                for (uint32_t i = 0; i < n; ++i) {
                    MilitaryReparation x;
                    x.payer = r.u64();
                    x.receiver = r.u64();
                    x.installment = r.i64();
                    x.remaining = r.i32();
                    x.next_day = r.i64();
                    x.arrears = r.i64();
                    x.war_id = r.i32();
                    if (!r.ok()) break;
                    tmp._reparations.push_back(x);
                }
                break;
            }
            case kSection_BattleLog: {
                const uint32_t n = r.u32();
                if (n > (uint32_t)MILITARY_BATTLE_LOG_CAPACITY) {
                    error = "pkmi_bad_battle_log";
                    return false;
                }
                tmp._battle_log.clear();
                tmp._battle_log.reserve(n);
                for (uint32_t i = 0; i < n; ++i) {
                    MilitaryBattleLogRow b;
                    b.day = r.i64();
                    b.cell = r.i32();
                    b.war_id = r.i32();
                    b.winner_slot = r.i32();
                    b.loser_slot = r.i32();
                    b.winner_losses = r.i64();
                    b.loser_losses = r.i64();
                    b.score_gain_q16 = r.i32();
                    if (!r.ok()) break;
                    tmp._battle_log.push_back(b);
                }
                break;
            }
            case kSection_Areas: {
                const uint32_t n = r.u32();
                if (n > kMaxRows) {
                    error = "pkmi_bad_areas";
                    return false;
                }
                tmp._areas.clear();
                tmp._areas.reserve(n);
                for (uint32_t i = 0; i < n; ++i) {
                    MilitaryArea a;
                    a.id = r.i32();
                    a.owner_slot = r.i32();
                    a.last_eval_day = r.i64();
                    a.active = r.u8();
                    const uint32_t m = r.u32();
                    if (m > (uint32_t)MILITARY_MAX_AREA_CELLS) {
                        error = "pkmi_bad_area_cells";
                        return false;
                    }
                    a.cells.resize(m);
                    for (uint32_t k = 0; k < m; ++k) a.cells[k] = r.i32();
                    if (!r.ok()) break;
                    std::sort(a.cells.begin(), a.cells.end());
                    tmp._areas.push_back(std::move(a));
                }
                break;
            }
            case kSection_Policies: {
                const uint32_t n = r.u32();
                if (n > kMaxRows) {
                    error = "pkmi_bad_policies";
                    return false;
                }
                tmp._policies.clear();
                tmp._policy_handle.clear();
                tmp._policies.resize(n);
                tmp._policy_handle.assign(n, 0);
                for (uint32_t i = 0; i < n; ++i) {
                    MilitaryCountryPolicy &p = tmp._policies[i];
                    tmp._policy_handle[i] = r.u64();
                    p.target_mode = r.u8();
                    p.target_value = r.i64();
                    p.effective_target = r.i64();
                    p.levy_enabled = r.u8();
                    p.auto_retrain = r.u8();
                    p.auto_discharge = r.u8();
                    p.quality_policy = r.u8();
                    p.wage_mode = r.u8();
                    p.wage_absolute = r.i64();
                    p.procurement_share_bp = r.i32();
                    p.pay_ratio_30_q16 = r.i32();
                    p.spend_payroll_30 = r.i64();
                    p.spend_procurement_30 = r.i64();
                    p.spend_upkeep_30 = r.i64();
                    p.per_soldier_cost = r.i64();
                    const uint32_t m = r.u32();
                    if (m > (uint32_t)MILITARY_MAX_UNIT_TYPES) {
                        error = "pkmi_bad_policy_shares";
                        return false;
                    }
                    p.config_share_bp.assign(m, 0);
                    for (uint32_t k = 0; k < m; ++k) p.config_share_bp[k] = r.i32();
                    if (!r.ok()) break;
                }
                break;
            }
            case kSection_CellStates: {
                const uint32_t n = r.u32();
                if (n > kMaxRows) {
                    error = "pkmi_bad_cell_states";
                    return false;
                }
                tmp._cell_states.clear();
                tmp._cell_states.reserve(n);
                for (uint32_t i = 0; i < n; ++i) {
                    MilitaryCellState st;
                    st.cell = r.i32();
                    for (int32_t t = 0; t < 8; ++t) st.barracks_count[t] = r.i32();
                    st.fort_tier = r.i32();
                    st.college_tier = r.i32();
                    st.paused = r.u8();
                    st.disrepair = r.u8();
                    st.pending_enlist = r.i64();
                    st.quota = r.i64();
                    st.requisition_until_day = r.i64();
                    for (int32_t k = 0; k < 3; ++k) {
                        st.construction_done_day[k] = r.i64();
                        st.construction_building[k] = r.i32();
                    }
                    if (!r.ok()) break;
                    if (st.cell < 0 || st.cell >= tmp._terrain.cell_count) {
                        error = "pkmi_bad_cell_state_cell";
                        return false;
                    }
                    tmp._cell_states.push_back(st);
                }
                std::sort(tmp._cell_states.begin(), tmp._cell_states.end(),
                          [](const MilitaryCellState &a, const MilitaryCellState &b) { return a.cell < b.cell; });
                break;
            }
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
    if (!saw_index_continuation || !valid_index_continuation(tmp)) {
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
    tmp._path_cells.assign(remap_path.begin(), remap_path.begin() + (ptrdiff_t)max_path_end);
    tmp._template_rows.assign(remap_tpl.begin(), remap_tpl.begin() + (ptrdiff_t)max_tpl_end);

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
        error = "pkmi_version_mismatch_expected_2";
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
    _army_lane_pending = std::move(tmp._army_lane_pending);
    _lots = std::move(tmp._lots);
    _training = std::move(tmp._training);
    _armies = std::move(tmp._armies);
    _path_cells = std::move(tmp._path_cells);
    _template_rows = std::move(tmp._template_rows);
    _stocks = std::move(tmp._stocks);
    _shipments = std::move(tmp._shipments);
    _engagements = std::move(tmp._engagements);
    _wars = std::move(tmp._wars);
    _truces = std::move(tmp._truces);
    _reparations = std::move(tmp._reparations);
    _battle_log = std::move(tmp._battle_log);
    _areas = std::move(tmp._areas);
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

    // ---- rebuild every derived scratch structure
    _cell_head.assign(cells, -1);
    _cell_engagement_mask.assign(cells, 0);
    _front_edge_set.assign(cells * 6, 0);
    _front_edges.clear();
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
    pending_spend.clear();
    _last_digest = MilitaryWorldDigest();
    _country_annual_revenue.clear();
    _war_intents.clear();
    _event_counter_control = 0;
    rebuild_cell_index();
    // Cached army stats were restored verbatim from the save (hash parity).

    return true;
}

} // namespace pk
