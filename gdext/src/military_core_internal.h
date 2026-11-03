#pragma once

// Private helpers shared by the military_core*.cpp translation units.
// Not part of the frozen contract (military_core.h / military_bridge.h).
// owner: A1 (military_core*.cpp, military_core_path.cpp, military_core_save.cpp)

#include <algorithm>

#include "military_core.h"

#include <cstdint>

namespace pk {
namespace mil {

// ------------------------------------------------------------ integers

inline int32_t clamp32(int32_t v, int32_t lo, int32_t hi) {
    return v < lo ? lo : (v > hi ? hi : v);
}

inline int64_t clamp64(int64_t v, int64_t lo, int64_t hi) {
    return v < lo ? lo : (v > hi ? hi : v);
}

// Truncating integer division of a * b / c with an exact 128-bit intermediate;
// all callers pass c > 0.
inline int64_t mul_div(int64_t a, int64_t b, int64_t c) {
    if (c == 0) return 0;
#if defined(_MSC_VER) && !defined(__clang__)
    // Exact signed 128-bit product, truncating division, saturating when the
    // quotient does not fit in int64 (_udiv128 would fault).
    __int64 hi = 0;
    const __int64 lo = _mul128(a, b, &hi);
    const bool neg = (hi < 0) != (c < 0);
    unsigned __int64 mhi = (unsigned __int64)hi, mlo = (unsigned __int64)lo;
    if (hi < 0) { mlo = ~mlo + 1; mhi = ~mhi + (mlo == 0 ? 1 : 0); }
    const unsigned __int64 uc = c < 0 ? (unsigned __int64)(-(c + 1)) + 1 : (unsigned __int64)c;
    if (mhi >= uc) return neg ? INT64_MIN : INT64_MAX;
    unsigned __int64 rem = 0;
    const unsigned __int64 q = _udiv128(mhi, mlo, uc, &rem);
    if (q > (unsigned __int64)INT64_MAX) return neg ? INT64_MIN : INT64_MAX;
    return neg ? -(int64_t)q : (int64_t)q;
#else
    return (int64_t)(((__int128)a * (__int128)b) / (__int128)c);
#endif
}

inline int64_t ceil_div_pos(int64_t a, int64_t b) {
    if (b <= 0) return 0;
    return a <= 0 ? 0 : (a + b - 1) / b;
}

// ------------------------------------------------------------ RNG

inline uint64_t splitmix_final(uint64_t z) {
    z = (z ^ (z >> 30)) * 0xbf58476d1ce4e5b9ull;
    z = (z ^ (z >> 27)) * 0x94d049bb133111ebull;
    return z ^ (z >> 31);
}

// Deterministic SplitMix64 hash keyed by (seed, key, day). Independent of the
// thread or iteration order, which the design requires for battle parallel
// replay parity.
inline uint64_t rng(uint64_t seed, uint64_t key, int64_t day) {
    uint64_t z = seed + 0x9e3779b97f4a7c15ull;
    z ^= key + 0xbf58476d1ce4e5b9ull;
    z ^= (uint64_t)day + 0x94d049bb133111ebull;
    return splitmix_final(z);
}

// Uniform value in [0, 1) as q16.
inline int32_t rng_q16(uint64_t seed, uint64_t key, int64_t day) {
    return (int32_t)((rng(seed, key, day) >> 48) & 0xFFFF);
}

inline uint64_t mix_key(uint64_t a, uint64_t b) {
    return splitmix_final(a ^ (b + 0x9e3779b97f4a7c15ull + (a << 6) + (a >> 2)));
}

// ------------------------------------------------------------ stats

inline bool has_stat(const MilitaryWorldDigest &d, int32_t slot, MilitaryStatId id) {
    return slot >= 0 && slot < d.country_capacity && d.stat_count > (int32_t)id;
}

inline int32_t stat_q16(const MilitaryWorldDigest &d, int32_t slot, MilitaryStatId id) {
    if (!has_stat(d, slot, id)) return MILITARY_Q16;
    const size_t idx = (size_t)slot * (size_t)d.stat_count + (size_t)id;
    if (idx >= d.country_stat_q16.size()) return MILITARY_Q16;
    const int32_t v = d.country_stat_q16[idx];
    return v > 0 ? v : MILITARY_Q16;
}

inline int32_t stat_bp(const MilitaryWorldDigest &d, int32_t slot, MilitaryStatId id) {
    return (int32_t)(((int64_t)stat_q16(d, slot, id) * 10000) / MILITARY_Q16);
}

inline int32_t stat_add(const MilitaryWorldDigest &d, int32_t slot, MilitaryStatId id) {
    if (!has_stat(d, slot, id)) return 0;
    const size_t idx = (size_t)slot * (size_t)d.stat_count + (size_t)id;
    if (idx >= d.country_stat_q16.size()) return 0;
    return d.country_stat_q16[idx];
}

inline int32_t unlock_bit_count(const MilitaryWorldDigest &d) {
    return d.unlock_words > 0 ? d.unlock_words * 64 : 0;
}

inline bool unlocked(const MilitaryWorldDigest &d, int32_t slot, int32_t bit) {
    if (bit < 0) return true;
    if (slot < 0 || slot >= d.country_capacity) return false;
    const int32_t words = unlock_bit_count(d);
    if (bit >= words) return false;
    const size_t idx = (size_t)slot * (size_t)d.unlock_words + (size_t)(bit >> 6);
    if (idx >= d.country_unlock_bits.size()) return false;
    return ((d.country_unlock_bits[idx] >> (uint32_t)(bit & 63)) & 1ull) != 0;
}

// design 4.3: militia attack/defense scale with 1.35^era_index (eras 0..10).
inline int64_t era_factor_militia_q16(int32_t era) {
    static const int64_t kTable[11] = {
        65536, 88474, 119439, 161243, 217678, 293865, 396718, 535569, 723018, 976074, 1317700};
    if (era < 0) era = 0;
    if (era > 10) era = 10;
    return kTable[era];
}

inline int64_t quality_mult_q16(int32_t quality_1_5) {
    const int32_t q = clamp32(quality_1_5, 1, 5);
    return MILITARY_QUALITY_MULT_Q16[(size_t)(q - 1)];
}

// ------------------------------------------------------------ armies / lots

inline bool army_alive(const MilitaryArmyStore &s, int32_t slot) {
    return slot >= 0 && (size_t)slot < s.active.size() && s.active[(size_t)slot] != 0;
}

// Packs/unpacks the low 32 bits of a handle. Telemetry only.
inline uint32_t handle_slot_bits(uint64_t handle) {
    return (uint32_t)(handle & 0xFFFFFFFFull);
}

} // namespace mil

// -------------------------------------------------------------- cross-TU

// Owner slot a garrison cell's lots belong to (-1 when the cell has no lots).
// Every time a garrison lot is created its owner is the only owner in that
// cell, so the lowest owner slot is the roster owner.
int32_t military_cell_garrison_slot(const MilitaryCore &core, int32_t cell);

// ------------------------------------------------------------ lot index
// Derived per-location lot lists (O(1) link/unlink). Inactive lots may stay
// linked until their slot is reused, so every reader filters on
// active/location_kind/location. `military_for_each_lot` yields every row of the
// (kind, location) list in the given direction; {ASCENDING} keeps the
// pre-index full-table order, so callers that mutate the lot (lot_find_or_create,
// removal) see exactly the rows the former scan saw.
enum MilitaryLotOrder : uint8_t { MILITARY_LOT_ASC = 0, MILITARY_LOT_DESC = 1 };
void military_lot_index_rebuild(const MilitaryCore &core);
void military_lot_index_link(MilitaryCore &core, int32_t lot);
void military_lot_index_unlink(MilitaryCore &core, int32_t lot);

inline int32_t military_lot_head(const MilitaryCore &core, uint8_t kind, int32_t loc) {
    if (!core._lot_index_ok || core._lot_next.size() != core._lots.active.size()) military_lot_index_rebuild(core);
    if (loc < 0) return -1;
    if (kind == (uint8_t)MILITARY_LOT_ARMY) {
        return (size_t)loc < core._lot_army_head.size() ? core._lot_army_head[(size_t)loc] : -1;
    }
    return (size_t)loc < core._lot_cell_head.size() ? core._lot_cell_head[(size_t)loc] : -1;
}

inline bool military_lot_matches(const MilitaryCore &core, int32_t lot, uint8_t kind, int32_t loc) {
    const size_t s = (size_t)lot;
    return core._lots.active[s] && core._lots.location_kind[s] == kind && core._lots.location[s] == loc;
}

template <MilitaryLotOrder O, typename F>
inline void military_for_each_lot_ordered(const MilitaryCore &core, uint8_t kind, int32_t loc, F &&fn) {
    static thread_local std::vector<int32_t> chain;
    chain.clear();
    for (int32_t i = military_lot_head(core, kind, loc); i >= 0;
         i = (size_t)i < core._lot_next.size() ? core._lot_next[(size_t)i] : -1) {
        chain.push_back(i);
    }
    if (O == MILITARY_LOT_ASC) {
        for (size_t k = chain.size(); k-- > 0;) fn(chain[k]);
    } else {
        for (size_t k = 0; k < chain.size(); ++k) fn(chain[k]);
    }
}

template <typename F>
inline void military_for_each_lot(const MilitaryCore &core, uint8_t kind, int32_t loc, F &&fn) {
    military_for_each_lot_ordered<MILITARY_LOT_ASC>(core, kind, loc, std::forward<F>(fn));
}

// Unambiguous names for the market demand kinds (the m_intent constants are
// capture-only in the bridge header).
constexpr int32_t MIL_KIND_GOOD = 0;
constexpr int32_t MIL_KIND_EQUIP_CATEGORY = 1;
// Internal holder kind of a training order's equipment delivery.
constexpr uint8_t MILITARY_LOT_TRAINING = 2;

// ------------------------------------------------------------ supply access
// Design decision (user, overrides §9.3 fields): a demander sources only from
// markets in cells OWNED and CONTROLLED by its country within hex distance
// <= 3 of its cell. Market rows are indexed per cell once per day.
constexpr int32_t MILITARY_SUPPLY_RADIUS = 3;
constexpr int32_t MILITARY_SUPPLY_RING_CELLS = 19;    // rings of radius 3
// True when a stocked ration market of `slot` lies within the supply radius of
// `cell` (design 9.3 connectivity; no global field, O(19 x rows in ring)).
bool military_supply_connected(const MilitaryCore &core, const MilitaryWorldDigest &digest, int32_t slot,
                               int32_t cell);
// True when `slot` owns and still controls `cell`.
bool military_owns_cell(const MilitaryCore &core, const MilitaryWorldDigest &digest, int32_t cell,
                        int32_t slot);
// Drops the per-day market state (indexes, connectivity, replay rows).
void military_market_reset(MilitaryCore &core);
// ------------------------------------------------------------ helpers
inline uint64_t military_edge_key(int32_t a, int32_t b) {
    const int64_t lo = a < b ? a : b;
    const int64_t hi = a < b ? b : a;
    return (uint64_t)lo * 2147483647ll + hi;
}

// ------------------------------------------------------------ stock rows
// _stocks is an unordered sparse row table (stock_add removes a row by swapping
// the last row into its place), so the open-addressing index is rebuilt on any
// structural change and is only a lookup accelerator.
void military_stock_index_rebuild(const MilitaryCore &core);
// Row index of (holder_kind, holder, country_slot, good), or -1.
int32_t military_stock_row(const MilitaryCore &core, uint8_t holder_kind, int32_t holder,
                           int32_t country_slot, int32_t good);

// ------------------------------------------------------------ connectivity
// Connectivity labels: one BFS per country over the cells it owns AND
// controls, built lazily on the first disconnection probe of a day (or after
// control moved). A cell is connected when its group holds at least one cell
// with a stocked market row (sellable or already sold out today).
bool military_connectivity_connected(const MilitaryCore &core, const MilitaryWorldDigest &digest,
                                     int32_t slot, int32_t cell);

// ------------------------------------------------------------ events
// Design 19.1 payload schema (20..25) of a Military gameplay event type.
uint16_t military_event_payload_schema(uint16_t type);

// ------------------------------------------------------------ receipts
// DISCHARGE intents pre-apply to Military lots; the receipt reconciles a
// shortfall. source_id = cell | (slot+1) << 32 | requested << 48.
constexpr int64_t MILITARY_DISCHARGE_CHUNK = 0xFFFF;
inline uint64_t military_discharge_source(int32_t cell, int32_t slot, int64_t requested) {
    return (uint64_t)(uint32_t)cell | ((uint64_t)(uint16_t)(slot + 1) << 32) |
           ((uint64_t)(requested & 0xFFFF) << 48);
}

// Per-stage wall time of the last step_day (diagnostics only; not state).
constexpr int32_t MILITARY_STAGE_COUNT = 20;
const double *military_stage_ms();
const char *military_stage_name(int32_t stage);

} // namespace pk
