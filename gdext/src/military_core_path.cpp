// military_core_path.cpp - terrain step cost, A*, bounded Dijkstra, movement,
// ZOC and the intrusive cell -> army index (owner: A1).
//
// Hex convention: cells are row-major offset ids on an "odd-r" layout with the
// map wrapping east-west (Project/.../scripts/geography/hex_utils.gd). The six
// neighbours arrive in HexUtils.CUBE_DIRECTIONS order (0=E,1=NE,2=NW,3=W,4=SW,
// 5=SE) and already carry the wrap, so every graph walk here is wrap-aware.
// This file keeps its own per-cell scratch in function-local static arrays
// (keyed by the current cell count) so it never needs header fields.
//
// Naval transport (army-personnel contract 2 §2.1, design §7.4 "v1 简化"):
// water is impassable until the country's unlock bits carry a transport
// technology. `tech.military.coastal_transport` allows runs of at most
// kSeaRunMax consecutive water cells with a land cell at both ends (embark and
// disembark), `tech.military.naval_transport` lifts the run limit. A sea step
// costs 1.5x a land step, an army standing on water is forced to EMBARKED (and
// gets its previous stance back on landing), and it takes kSeaAttritionBp of
// daily attrition at sea instead of the land environment loss. The run limit
// cannot be checked per cell, so both searches run over (cell, water-run)
// states; with the ocean technology the run dimension collapses to one state.

#include "military_core.h"
#include "military_core_internal.h"

#include <algorithm>
#include <cstdlib>
#include <vector>

namespace pk {

namespace {

using namespace mil;

constexpr int32_t kOne = MILITARY_Q16;
constexpr int32_t kMaxPathNodes = 4096;
constexpr int32_t kDijExpansionsDefault = 512;

// ---- naval transport (contract §2.1)
constexpr int32_t kSeaRunMax = 3;             // coastal: <= 3 consecutive water cells
constexpr int32_t kSeaRunStates = kSeaRunMax + 1;
constexpr int32_t kSeaCostNumer = 3;          // sea step = 1.5x the land step
constexpr int32_t kSeaCostDenom = 2;
constexpr int32_t kSeaAttritionBp = 20;       // 0.2% per day while at sea
constexpr int64_t kBp100PerBp = 100;          // bp100 unit = 1e-6 (100 == 0.01%)
constexpr int64_t kBp100Scale = 1000000;
// Preview days are half-days per step: land 1 day, sea 1.5 days (contract §2.2).
constexpr int32_t kLandStepHalves = 2;
constexpr int32_t kSeaStepHalves = 3;
constexpr uint64_t kSeaAttritionKey = 0x53454141ull;   // 'SEAA'

int32_t abs_i32(int32_t v) {
    return v < 0 ? -v : v;
}

struct HeapEntry {
    int32_t priority;
    int32_t node;
};

inline bool heap_less(const HeapEntry &a, const HeapEntry &b) {
    if (a.priority != b.priority) return a.priority < b.priority;
    return a.node < b.node;
}

void heap_push(std::vector<HeapEntry> &heap, HeapEntry e) {
    heap.push_back(e);
    size_t i = heap.size() - 1;
    while (i > 0) {
        const size_t parent = (i - 1) / 4;
        if (!heap_less(heap[i], heap[parent])) break;
        std::swap(heap[i], heap[parent]);
        i = parent;
    }
}

HeapEntry heap_pop(std::vector<HeapEntry> &heap) {
    HeapEntry top = heap.front();
    heap.front() = heap.back();
    heap.pop_back();
    size_t i = 0;
    const size_t n = heap.size();
    for (;;) {
        const size_t first = i * 4 + 1;
        if (first >= n) break;
        size_t best = first;
        for (size_t k = first + 1; k < first + 4 && k < n; ++k) {
            if (heap_less(heap[k], heap[best])) best = k;
        }
        if (!heap_less(heap[best], heap[i])) break;
        std::swap(heap[i], heap[best]);
        i = best;
    }
    return top;
}

// Per-state scratch shared by every call in this TU (single-threaded stage).
// A state is `cell * run_states + run`, where `run` counts the consecutive
// water cells entered so far (always 0 when the ocean technology collapses the
// dimension or when no transport is unlocked).
struct PathScratch {
    std::vector<int32_t> dist;
    std::vector<int32_t> parent;
    std::vector<uint32_t> stamp;
    std::vector<uint8_t> closed;
    std::vector<HeapEntry> heap;
    std::vector<int32_t> queue;      // BFS order (preview_path)
    uint32_t gen = 1;

    void ensure(size_t states) {
        if (dist.size() < states) {
            dist.resize(states, 0);
            parent.assign(states, -1);
            stamp.assign(states, 0);
            closed.assign(states, 0);
        }
        // Shrink only when the map really got smaller: searches alternate
        // between one state per cell (no transport / ocean) and the coastal
        // run dimension, and reallocating every call would cost more than the
        // high-water mark.
        if (dist.size() > states && states * 8 < dist.size()) {
            dist.resize(states);
            parent.resize(states);
            stamp.resize(states);
            closed.resize(states);
        }
        if (++gen == 0) {
            std::fill(stamp.begin(), stamp.end(), 0u);
            gen = 1;
        }
        heap.clear();
        queue.clear();
    }
};

PathScratch &scratch() {
    static thread_local PathScratch s;
    return s;
}

// ------------------------------------------------------------ naval gate

// A command-path search is planned against an empty digest (no committed view);
// it falls back to the last committed day so an unlocked country does not lose
// its naval transport while planning.
inline bool has_unlock_view(const MilitaryWorldDigest &d) {
    return d.unlock_words > 0 && !d.country_unlock_bits.empty();
}

// Unlike `unlocked()`, a negative (unconfigured) slot is never granted: for a
// water gate "-1 = always" would silently make every sea passable.
inline bool sea_bit_set(const MilitaryWorldDigest &d, int32_t slot, int32_t bit) {
    if (bit < 0) return false;
    if (slot < 0 || slot >= d.country_capacity) return false;
    if (d.unlock_words <= 0) return false;
    if (bit >= d.unlock_words * 64) return false;
    const size_t idx = (size_t)slot * (size_t)d.unlock_words + (size_t)(bit >> 6);
    if (idx >= d.country_unlock_bits.size()) return false;
    return ((d.country_unlock_bits[idx] >> (uint32_t)(bit & 63)) & 1ull) != 0;
}

// 0 = no transport, 1 = coastal (<= kSeaRunMax water cells), 2 = ocean.
inline int32_t sea_transport_level(const MilitaryCatalog &catalog,
                                   const MilitaryWorldDigest &digest, int32_t country_slot) {
    if (country_slot < 0) return 0;
    if (sea_bit_set(digest, country_slot, catalog.ocean_transport_bit)) return 2;
    if (sea_bit_set(digest, country_slot, catalog.coastal_transport_bit)) return 1;
    return 0;
}

inline bool cell_is_water(const MilitaryTerrainInput &terrain, int32_t cell) {
    return cell >= 0 && (size_t)cell < terrain.is_water.size() &&
           terrain.is_water[(size_t)cell] != 0;
}

// Preview duration in days: one day per land cell, 1.5 days per water cell,
// divided by the naval-transport capacity the same way the A* step cost is.
inline int32_t preview_days(const MilitaryTerrainInput &terrain,
                            const std::vector<int32_t> &cells,
                            int32_t sea_scale_q16) {
    if (sea_scale_q16 < 65536 / 8) sea_scale_q16 = 65536 / 8;
    if (sea_scale_q16 > 65536 * 8) sea_scale_q16 = 65536 * 8;
    // Halves in q16 so a scaled sea step keeps sub-day precision.
    int64_t halves_q16 = 0;
    for (const int32_t cell : cells) {
        if (!cell_is_water(terrain, cell)) {
            halves_q16 += (int64_t)kLandStepHalves * 65536;
            continue;
        }
        int64_t sea_q16 = (int64_t)kSeaStepHalves * 65536;
        sea_q16 = sea_q16 * 65536 / sea_scale_q16;
        const int64_t floor_q16 = (int64_t)kLandStepHalves * 65536;
        if (sea_q16 < floor_q16) sea_q16 = floor_q16;   // never cheaper than land
        halves_q16 += sea_q16;
    }
    // Round the q16 half-days up to whole halves first, then to days: 11 halves
    // must read as 6 days, not 5.
    const int64_t halves = (halves_q16 + 65535) / 65536;
    return (int32_t)((halves + 1) / 2);
}

// Stance an army had before it was forced to EMBARKED. Derived only: it mirrors
// a documented invariant of the stance store, is never saved or hashed, and a
// restore in the middle of a crossing simply lands on HOLD. Guarded by the army
// generation so a recycled slot never inherits the previous formation's row.
struct SeaStanceCache {
    std::vector<uint32_t> generation;
    std::vector<int32_t> stance;

    void ensure(size_t n) {
        if (generation.size() < n) {
            generation.resize(n, 0);
            stance.resize(n, -1);
        }
    }
};

SeaStanceCache &sea_stance_cache() {
    static thread_local SeaStanceCache cache;
    return cache;
}

} // namespace

// ============================================================== coordinates

int32_t MilitaryCore::cell_distance(int32_t a, int32_t b) const {
    if (a < 0 || b < 0 || a >= _terrain.cell_count || b >= _terrain.cell_count) return 0x0FFFFFFF;
    if (a == b) return 0;
    if (_terrain.width <= 0 || _terrain.height <= 0) return 0x0FFFFFFF;
    const int32_t w = _terrain.width;
    const int32_t ac = a % w, ar = a / w;
    const int32_t bc = b % w, br = b / w;
    const int32_t aq = ac - (ar - (ar & 1)) / 2;   // odd-r -> cube q
    const int32_t bq = bc - (br - (br & 1)) / 2;
    const int32_t dq = bq - aq;
    const int32_t dr = br - ar;
    const int32_t adq = abs_i32(dq);
    const int32_t adx = abs_i32(dq + dr);
    int32_t dx = adq < adx ? adq : adx;
    if (w > 0 && dx > w / 2) dx = w - dx;
    const int32_t dy = abs_i32(dr);
    const int32_t rest = dx - dy;
    return dy + (rest > 0 ? rest : 0);
}

// ============================================================== passability

bool MilitaryCore::passable_for(int32_t cell, int32_t country_slot, const MilitaryWorldDigest &digest) const {
    if (cell < 0 || cell >= _terrain.cell_count) return false;
    if (_terrain.is_water[(size_t)cell]) {
        // Design 7.4 / contract §2.1: water only opens with a transport
        // technology. The landform table describes land, so it is not consulted
        // here; the consecutive-water-cell limit needs path context and is
        // enforced by the search in find_path / preview_path.
        const MilitaryWorldDigest &view = has_unlock_view(digest) ? digest : _last_digest;
        return sea_transport_level(_catalog, view, country_slot) > 0;
    }
    const uint8_t lf = _terrain.landform[(size_t)cell];
    const uint8_t passable = (size_t)lf < _catalog.landform_passable.size()
                                 ? _catalog.landform_passable[(size_t)lf]
                                 : (uint8_t)((lf == 8 || lf == 12 || lf <= 3) ? 0 : 1);
    if (!passable) return false;
    if (country_slot < 0) return true;
    const int32_t owner = (size_t)cell < digest.cell_owner_slot.size() ? digest.cell_owner_slot[(size_t)cell] : -1;
    const int32_t ctrl = controller_of(cell);
    const int32_t effective = ctrl >= 0 ? ctrl : owner;
    if (effective < 0) return true;              // unowned land is walkable
    if (effective == country_slot) return true;
    return at_war(country_slot, effective);      // enemy land only while at war
}

// Player auto-exploration never crosses a foreign controller, even while at
// war. Water keeps the ordinary naval gate; the source-cell exception is
// implicit because a search never re-checks its start cell.
bool MilitaryCore::exploration_passable_for(int32_t cell, int32_t country_slot,
                                            const MilitaryWorldDigest &digest) const {
    if (cell < 0 || cell >= _terrain.cell_count) return false;
    if (_terrain.is_water[(size_t)cell]) return passable_for(cell, country_slot, digest);
    const uint8_t lf = _terrain.landform[(size_t)cell];
    const uint8_t passable = (size_t)lf < _catalog.landform_passable.size()
                                 ? _catalog.landform_passable[(size_t)lf]
                                 : (uint8_t)((lf == 8 || lf == 12 || lf <= 3) ? 0 : 1);
    if (!passable) return false;
    if (country_slot < 0) return true;
    const int32_t owner = (size_t)cell < digest.cell_owner_slot.size()
                              ? digest.cell_owner_slot[(size_t)cell]
                              : -1;
    const int32_t ctrl = controller_of(cell);
    const int32_t effective = ctrl >= 0 ? ctrl : owner;
    return effective < 0 || effective == country_slot;
}

int32_t MilitaryCore::step_cost_q16(int32_t from, int32_t to, int32_t country_slot,
                                    const MilitaryWorldDigest &digest) const {
    if (from < 0 || to < 0 || from >= _terrain.cell_count || to >= _terrain.cell_count) return -1;
    if (!passable_for(to, country_slot, digest)) return -1;
    const bool to_water = _terrain.is_water[(size_t)to] != 0;
    const uint8_t lf = _terrain.landform[(size_t)to];
    const uint8_t veg = _terrain.vegetation[(size_t)to];
    const uint8_t cv = _terrain.cover[(size_t)to];
    int32_t cost = 0;
    cost += lf < _catalog.landform_flat.size() ? _catalog.landform_flat[(size_t)lf] : 1;
    cost += lf < _catalog.landform_rough.size() ? _catalog.landform_rough[(size_t)lf] : 0;
    cost += veg < _catalog.vegetation_rough.size() ? _catalog.vegetation_rough[(size_t)veg] : 0;
    cost += cv < _catalog.cover_flat.size() ? _catalog.cover_flat[(size_t)cv] : 0;
    // River crossing into a dry cell from a dry land cell.
    if (_terrain.has_river[(size_t)to] && !_terrain.has_river[(size_t)from] &&
        !_terrain.is_water[(size_t)from] && !_terrain.is_water[(size_t)to]) {
        cost += 1;
    }
    if (cost < 1) cost = 1;
    int32_t out = (int32_t)std::min<int64_t>((int64_t)cost * kOne, 0x07FFFFFF);
    if (to_water) {
        // Sea steps cost 1.5x a land step, divided by the naval-transport stat
        // ("海运运力", registered 0..8 with 1.0 neutral): more capacity buys a
        // cheaper crossing, never a free one and never cheaper than land.
        int64_t sea = mul_div(out, kSeaCostNumer, kSeaCostDenom);
        if (country_slot >= 0) {
            int32_t transport = stat_q16(digest, country_slot, MSTAT_NAVAL_TRANSPORT);
            if (transport < MILITARY_Q16 / 8) transport = MILITARY_Q16 / 8;
            if (transport > MILITARY_Q16 * 8) transport = MILITARY_Q16 * 8;
            sea = mul_div(sea, MILITARY_Q16, transport);
            if (sea < out) sea = out;
        }
        return (int32_t)std::min<int64_t>(sea, 0x07FFFFFF);
    }
    // Own territory movement divided by the logistics-move stat (roads/rail).
    if (country_slot >= 0) {
        const int32_t owner = (size_t)to < digest.cell_owner_slot.size() ? digest.cell_owner_slot[(size_t)to] : -1;
        const int32_t ctrl = controller_of(to);
        const int32_t effective = ctrl >= 0 ? ctrl : owner;
        if (effective == country_slot) {
            const int64_t stat = stat_q16(digest, country_slot, MSTAT_LOGISTICS_MOVE);
            out = (int32_t)std::max<int64_t>(kOne / 4, mul_div(out, MILITARY_Q16, stat));
        }
    }
    return out;
}

// ============================================================== Dijkstra

void MilitaryCore::bounded_dijkstra(int32_t source, int32_t country_slot, int32_t max_expansions,
                                    const MilitaryWorldDigest &digest) {
    const int32_t n = _terrain.cell_count;
    if (_dij_dist.size() < (size_t)n) {
        _dij_dist.resize((size_t)n, 0);
        _dij_parent.resize((size_t)n, -1);
        _dij_stamp.assign((size_t)n, 0);
    }
    if (++_dij_gen == 0) {
        std::fill(_dij_stamp.begin(), _dij_stamp.end(), 0u);
        _dij_gen = 1;
    }
    static thread_local std::vector<HeapEntry> heap;
    heap.clear();
    if (source < 0 || source >= n) return;
    if (max_expansions <= 0) max_expansions = kDijExpansionsDefault;
    _dij_dist[(size_t)source] = 0;
    _dij_parent[(size_t)source] = -1;
    _dij_stamp[(size_t)source] = _dij_gen;
    heap_push(heap, HeapEntry{0, source});
    int32_t expansions = 0;
    while (!heap.empty() && expansions < max_expansions) {
        const HeapEntry e = heap_pop(heap);
        if (_dij_stamp[(size_t)e.node] != _dij_gen) continue;
        if (e.priority != _dij_dist[(size_t)e.node]) continue;   // stale heap row
        ++expansions;
        const int32_t base = e.node * 6;
        for (int32_t d = 0; d < 6; ++d) {
            const int32_t nb = _terrain.neighbors[(size_t)(base + d)];
            if (nb < 0) continue;
            const int32_t cost = step_cost_q16(e.node, nb, country_slot, digest);
            if (cost < 0) continue;
            const int32_t cand = e.priority + cost;
            if (_dij_stamp[(size_t)nb] == _dij_gen && _dij_dist[(size_t)nb] <= cand) continue;
            _dij_stamp[(size_t)nb] = _dij_gen;
            _dij_dist[(size_t)nb] = cand;
            _dij_parent[(size_t)nb] = e.node;
            heap_push(heap, HeapEntry{cand, nb});
        }
    }
    _report.astar_expansions += expansions;
    _heap.clear();
}

// ============================================================== A*

bool MilitaryCore::find_path(int32_t army_slot, int32_t target, const MilitaryWorldDigest &digest,
                             std::vector<int32_t> &out) {
    out.clear();
    if (!army_alive(_armies, army_slot)) return false;
    if (target < 0 || target >= _terrain.cell_count) return false;
    const int32_t owner = _armies.owner_slot[(size_t)army_slot];
    if (owner < 0) return false;
    const int32_t src = _armies.cell[(size_t)army_slot];
    if (src < 0 || src >= _terrain.cell_count) return false;
    if (src == target) return true;
    // A per-country daily request budget (design 21.3): extra requests are
    // deferred, which the UI shows as "planning".
    const size_t slot_index = (size_t)owner;
    if (_path_daily_requests.size() <= slot_index) _path_daily_requests.resize(slot_index + 1, 0);
    if (_path_daily_requests[slot_index] >= MILITARY_PATH_REQUESTS_PER_COUNTRY_DAY) return false;
    if (!passable_for(target, owner, digest)) return false;
    ++_path_daily_requests[slot_index];

    const int32_t n = _terrain.cell_count;
    // Naval transport capability: only the coastal gate needs the run
    // dimension (no transport never enters water, the ocean technology has no
    // limit), so every other case searches one state per cell.
    const MilitaryWorldDigest &view = has_unlock_view(digest) ? digest : _last_digest;
    const int32_t sea_level = sea_transport_level(_catalog, view, owner);
    const int32_t run_states = sea_level == 1 ? kSeaRunStates : 1;
    PathScratch &s = scratch();
    s.ensure((size_t)n * (size_t)run_states);
    auto heuristic = [this, target](int32_t cell) -> int32_t {
        const int32_t dist = cell_distance(cell, target);
        return dist > kMaxPathNodes ? 0x07FFFFF0 : dist * kOne;
    };
    // The start state always carries run 0: an army already standing on water
    // continues with a fresh run budget (its crossing began before this search).
    const int32_t src_state = src * run_states;
    s.dist[(size_t)src_state] = 0;
    s.parent[(size_t)src_state] = -1;
    s.stamp[(size_t)src_state] = s.gen;
    s.closed[(size_t)src_state] = 0;
    heap_push(s.heap, HeapEntry{heuristic(src), src_state});
    int32_t expansions = 0;
    bool found = false;
    int32_t target_state = -1;
    while (!s.heap.empty() && expansions < kMaxPathNodes) {
        const HeapEntry e = heap_pop(s.heap);
        if (s.closed[(size_t)e.node]) continue;
        s.closed[(size_t)e.node] = 1;
        ++expansions;
        const int32_t cell = e.node / run_states;
        if (cell == target) {
            found = true;
            target_state = e.node;
            break;
        }
        const int32_t run = e.node - cell * run_states;
        const int32_t base = cell * 6;
        for (int32_t d = 0; d < 6; ++d) {
            const int32_t nb = _terrain.neighbors[(size_t)(base + d)];
            if (nb < 0) continue;
            const int32_t cost = step_cost_q16(cell, nb, owner, digest);
            if (cost < 0) continue;
            int32_t next_run = 0;
            if (run_states > 1 && cell_is_water(_terrain, nb)) {
                next_run = run + 1;
                if (next_run > kSeaRunMax) continue;   // coastal: 4th water cell in a row
            }
            const int32_t nb_state = nb * run_states + next_run;
            // closed[] is only valid for states stamped this generation (A3 fix).
            if (s.stamp[(size_t)nb_state] == s.gen && s.closed[(size_t)nb_state]) continue;
            const int32_t cand = s.dist[(size_t)e.node] + cost;
            if (s.stamp[(size_t)nb_state] == s.gen && s.dist[(size_t)nb_state] <= cand) continue;
            if (s.stamp[(size_t)nb_state] != s.gen) s.closed[(size_t)nb_state] = 0;
            s.stamp[(size_t)nb_state] = s.gen;
            s.dist[(size_t)nb_state] = cand;
            s.parent[(size_t)nb_state] = e.node;
            heap_push(s.heap, HeapEntry{cand + heuristic(nb), nb_state});
        }
    }
    _report.astar_expansions += expansions;
    if (!found) return false;
    int32_t cursor = target_state;
    while (cursor >= 0 && cursor != src_state) {
        out.push_back(cursor / run_states);
        cursor = s.parent[(size_t)cursor];
        if (out.size() > (size_t)kMaxPathNodes) {
            out.clear();
            return false;
        }
    }
    std::reverse(out.begin(), out.end());
    return true;
}

MilitaryExplorationPathResult MilitaryCore::find_exploration_path(
        int32_t army_slot, int32_t target, const MilitaryWorldDigest &digest,
        std::vector<int32_t> &out) {
    out.clear();
    if (!army_alive(_armies, army_slot)) return MILITARY_EXPLORATION_PATH_INVALID;
    if (target < 0 || target >= _terrain.cell_count)
        return MILITARY_EXPLORATION_PATH_INVALID;
    const int32_t owner = _armies.owner_slot[(size_t)army_slot];
    if (owner < 0) return MILITARY_EXPLORATION_PATH_INVALID;
    const int32_t src = _armies.cell[(size_t)army_slot];
    if (src < 0 || src >= _terrain.cell_count)
        return MILITARY_EXPLORATION_PATH_INVALID;
    if (src == target) return MILITARY_EXPLORATION_PATH_OK;

    const size_t slot_index = (size_t)owner;
    if (_path_daily_requests.size() <= slot_index)
        _path_daily_requests.resize(slot_index + 1, 0);
    if (_exploration_daily_path_requests.size() <= slot_index)
        _exploration_daily_path_requests.resize(slot_index + 1, 0);
    // Exploration is planned before area control. Never spend the last 16
    // shared requests: those remain available for the 5-day area evaluation.
    if (_exploration_daily_path_requests[slot_index] >=
            MILITARY_EXPLORATION_PATH_REQUESTS_PER_COUNTRY_DAY ||
        _path_daily_requests[slot_index] >=
            MILITARY_PATH_REQUESTS_PER_COUNTRY_DAY - 16) {
        return MILITARY_EXPLORATION_PATH_DAILY_BUDGET_EXHAUSTED;
    }
    if (!exploration_passable_for(target, owner, digest))
        return MILITARY_EXPLORATION_PATH_UNREACHABLE;
    ++_path_daily_requests[slot_index];
    ++_exploration_daily_path_requests[slot_index];

    const int32_t n = _terrain.cell_count;
    const MilitaryWorldDigest &view = has_unlock_view(digest) ? digest : _last_digest;
    const int32_t sea_level = sea_transport_level(_catalog, view, owner);
    const int32_t run_states = sea_level == 1 ? kSeaRunStates : 1;
    PathScratch &s = scratch();
    s.ensure((size_t)n * (size_t)run_states);
    auto heuristic = [this, target](int32_t cell) -> int32_t {
        const int32_t dist = cell_distance(cell, target);
        return dist > kMaxPathNodes ? 0x07FFFFF0 : dist * kOne;
    };
    const int32_t src_state = src * run_states;
    s.dist[(size_t)src_state] = 0;
    s.parent[(size_t)src_state] = -1;
    s.stamp[(size_t)src_state] = s.gen;
    s.closed[(size_t)src_state] = 0;
    heap_push(s.heap, HeapEntry{heuristic(src), src_state});
    int32_t expansions = 0;
    bool found = false;
    int32_t target_state = -1;
    while (!s.heap.empty()) {
        if (expansions >= kMaxPathNodes) {
            _report.astar_expansions += expansions;
            // Expansion exhaustion is a temporary budget failure, not a proof
            // that no observer can ever be reached.
            return MILITARY_EXPLORATION_PATH_DAILY_BUDGET_EXHAUSTED;
        }
        const HeapEntry e = heap_pop(s.heap);
        if (s.closed[(size_t)e.node]) continue;
        s.closed[(size_t)e.node] = 1;
        ++expansions;
        const int32_t cell = e.node / run_states;
        if (cell == target) {
            found = true;
            target_state = e.node;
            break;
        }
        const int32_t run = e.node - cell * run_states;
        const int32_t base = cell * 6;
        for (int32_t d = 0; d < 6; ++d) {
            const int32_t nb = _terrain.neighbors[(size_t)(base + d)];
            if (nb < 0) continue;
            if (!exploration_passable_for(nb, owner, digest)) continue;
            const int32_t cost = step_cost_q16(cell, nb, owner, digest);
            if (cost < 0) continue;
            int32_t next_run = 0;
            if (run_states > 1 && cell_is_water(_terrain, nb)) {
                next_run = run + 1;
                if (next_run > kSeaRunMax) continue;
            }
            const int32_t nb_state = nb * run_states + next_run;
            if (s.stamp[(size_t)nb_state] == s.gen && s.closed[(size_t)nb_state]) continue;
            const int32_t cand = s.dist[(size_t)e.node] + cost;
            if (s.stamp[(size_t)nb_state] == s.gen && s.dist[(size_t)nb_state] <= cand)
                continue;
            if (s.stamp[(size_t)nb_state] != s.gen) s.closed[(size_t)nb_state] = 0;
            s.stamp[(size_t)nb_state] = s.gen;
            s.dist[(size_t)nb_state] = cand;
            s.parent[(size_t)nb_state] = e.node;
            heap_push(s.heap, HeapEntry{cand + heuristic(nb), nb_state});
        }
    }
    _report.astar_expansions += expansions;
    if (!found) return MILITARY_EXPLORATION_PATH_UNREACHABLE;
    int32_t cursor = target_state;
    while (cursor >= 0 && cursor != src_state) {
        out.push_back(cursor / run_states);
        cursor = s.parent[(size_t)cursor];
        if (out.size() > (size_t)kMaxPathNodes) {
            out.clear();
            return MILITARY_EXPLORATION_PATH_DAILY_BUDGET_EXHAUSTED;
        }
    }
    std::reverse(out.begin(), out.end());
    return MILITARY_EXPLORATION_PATH_OK;
}

int32_t MilitaryCore::path_cell_at(int32_t army_slot, int32_t cursor) const {
    if (army_slot < 0 || (size_t)army_slot >= _armies.active.size()) return -1;
    const size_t s = (size_t)army_slot;
    if (cursor < 0 || cursor >= _armies.path_len[s]) return -1;
    const int64_t at = (int64_t)_armies.path_offset[s] + cursor;
    if (at < 0 || (size_t)at >= _path_cells.size()) return -1;
    return _path_cells[(size_t)at];
}

bool MilitaryCore::preview_path(uint64_t army, int32_t target_cell, std::vector<int32_t> &out_cells,
                                int32_t &out_days) const {
    out_cells.clear();
    out_days = 0;
    int32_t slot = -1;
    if (!resolve_army(army, slot)) return false;
    const MilitaryArmyStore &a = _armies;
    const int32_t src = a.cell[(size_t)slot];
    const int32_t owner = a.owner_slot[(size_t)slot];
    if (target_cell < 0 || target_cell >= _terrain.cell_count) return false;
    if (src == target_cell) return true;
    // A pre-planned route to this target is authoritative (design 7.1: a
    // planned route is not recomputed when the season changes), so a preview
    // always matches what the army will actually walk.
    // Naval transport capacity (海运运力) scales the sea leg of the day count the
    // same way it scales the A* step cost.
    const int32_t naval_transport_q16 = owner >= 0
        ? stat_q16(_last_digest, owner, MSTAT_NAVAL_TRANSPORT) : MILITARY_Q16;
    const int32_t off = a.path_offset[(size_t)slot];
    const int32_t len = a.path_len[(size_t)slot];
    const int32_t cursor = a.path_cursor[(size_t)slot];
    if (cursor < len && off >= 0 && (size_t)(off + len - 1) < _path_cells.size() &&
        _path_cells[(size_t)(off + len - 1)] == target_cell) {
        for (int32_t k = cursor; k < len; ++k) out_cells.push_back(_path_cells[(size_t)(off + k)]);
        // Contract §2.2: the sea part must show up in the day count.
        out_days = preview_days(_terrain, out_cells, naval_transport_q16);
        return true;
    }
    // Otherwise BFS over the walkable graph (control-agnostic variant): only the
    // unlock bits of the last committed day are carried over, never ownership.
    MilitaryWorldDigest view;
    if (has_unlock_view(_last_digest)) {
        view.country_capacity = _last_digest.country_capacity;
        view.unlock_words = _last_digest.unlock_words;
        view.country_unlock_bits = _last_digest.country_unlock_bits;
    }
    const int32_t sea_level = sea_transport_level(_catalog, view, owner);
    const int32_t run_states = sea_level == 1 ? kSeaRunStates : 1;
    const int32_t n = _terrain.cell_count;
    PathScratch &s = scratch();
    s.ensure((size_t)n * (size_t)run_states);
    if (!passable_for(src, owner, view)) return false;
    if (!passable_for(target_cell, owner, view)) return false;
    const int32_t src_state = src * run_states;
    s.stamp[(size_t)src_state] = s.gen;
    s.parent[(size_t)src_state] = -1;
    s.queue.push_back(src_state);
    bool found = false;
    for (size_t head = 0; head < s.queue.size() && !found; ++head) {
        const int32_t state = s.queue[head];
        const int32_t cell = state / run_states;
        const int32_t run = state - cell * run_states;
        const int32_t base = cell * 6;
        for (int32_t d = 0; d < 6; ++d) {
            const int32_t nb = _terrain.neighbors[(size_t)(base + d)];
            if (nb < 0) continue;
            if (!passable_for(nb, owner, view)) continue;
            int32_t next_run = 0;
            if (run_states > 1 && cell_is_water(_terrain, nb)) {
                next_run = run + 1;
                if (next_run > kSeaRunMax) continue;   // coastal: 4th water cell in a row
            }
            const int32_t nb_state = nb * run_states + next_run;
            if (s.stamp[(size_t)nb_state] == s.gen) continue;
            s.stamp[(size_t)nb_state] = s.gen;
            s.parent[(size_t)nb_state] = state;
            if (nb == target_cell) {
                found = true;
                s.queue.push_back(nb_state);
                break;
            }
            s.queue.push_back(nb_state);
        }
    }
    if (!found) return false;
    int32_t cursor2 = s.queue.back();
    while (cursor2 >= 0 && cursor2 != src_state) {
        out_cells.push_back(cursor2 / run_states);
        cursor2 = s.parent[(size_t)cursor2];
    }
    std::reverse(out_cells.begin(), out_cells.end());
    out_days = preview_days(_terrain, out_cells, naval_transport_q16);
    return true;
}

// ============================================================== cell index

void MilitaryCore::index_insert(int32_t army_slot, int32_t cell) {
    if (!army_alive(_armies, army_slot)) return;
    if (cell < 0 || (size_t)cell >= _cell_head.size()) return;
    const size_t a = (size_t)army_slot;
    _armies.prev_in_cell[a] = -1;
    _armies.next_in_cell[a] = _cell_head[(size_t)cell];
    if (_cell_head[(size_t)cell] >= 0) _armies.prev_in_cell[(size_t)_cell_head[(size_t)cell]] = army_slot;
    _cell_head[(size_t)cell] = army_slot;
}

void MilitaryCore::index_remove(int32_t army_slot) {
    if (army_slot < 0 || (size_t)army_slot >= _armies.active.size()) return;
    const size_t a = (size_t)army_slot;
    const int32_t prev = _armies.prev_in_cell[a];
    const int32_t next = _armies.next_in_cell[a];
    if (prev >= 0) {
        _armies.next_in_cell[(size_t)prev] = next;
    } else {
        const int32_t cell = _armies.cell[a];
        if (cell >= 0 && (size_t)cell < _cell_head.size()) _cell_head[(size_t)cell] = next;
    }
    if (next >= 0) _armies.prev_in_cell[(size_t)next] = prev;
    _armies.prev_in_cell[a] = -1;
    _armies.next_in_cell[a] = -1;
}

void MilitaryCore::rebuild_cell_index() {
    _cell_head.assign((size_t)std::max(0, _terrain.cell_count), -1);
    for (int32_t i = 0; i < (int32_t)_armies.active.size(); ++i) {
        _armies.prev_in_cell[(size_t)i] = -1;
        _armies.next_in_cell[(size_t)i] = -1;
    }
    for (int32_t i = 0; i < (int32_t)_armies.active.size(); ++i) {
        if (!_armies.active[(size_t)i]) continue;
        const int32_t cell = _armies.cell[(size_t)i];
        if (cell < 0 || (size_t)cell >= _cell_head.size()) continue;
        _armies.next_in_cell[(size_t)i] = _cell_head[(size_t)cell];
        if (_cell_head[(size_t)cell] >= 0) _armies.prev_in_cell[(size_t)_cell_head[(size_t)cell]] = i;
        _cell_head[(size_t)cell] = i;
    }
}

// ============================================================== movement

namespace {

// Contract §2.1: an army standing on water is EMBARKED; landing restores the
// stance it had before embarkation. RETREAT formations are driven by the war
// stage and are left alone.
void sync_sea_stance(MilitaryCore &core, int32_t slot) {
    MilitaryArmyStore &a = core._armies;
    const size_t s = (size_t)slot;
    if (a.stance[s] == (uint8_t)MILITARY_STANCE_RETREAT) return;
    const bool at_sea = cell_is_water(core._terrain, a.cell[s]);
    SeaStanceCache &cache = sea_stance_cache();
    cache.ensure(a.active.size());
    const uint32_t generation = a.generation[s];
    if (at_sea) {
        if (a.stance[s] != (uint8_t)MILITARY_STANCE_EMBARKED) {
            cache.stance[s] = (int32_t)a.stance[s];
            cache.generation[s] = generation;
            a.stance[s] = (uint8_t)MILITARY_STANCE_EMBARKED;
        }
        return;
    }
    if (a.stance[s] != (uint8_t)MILITARY_STANCE_EMBARKED) return;
    const bool restored = cache.generation[s] == generation && cache.stance[s] >= 0 &&
                          cache.stance[s] != (int32_t)MILITARY_STANCE_EMBARKED &&
                          cache.stance[s] <= (int32_t)MILITARY_STANCE_RETREAT;
    a.stance[s] = (uint8_t)(restored ? cache.stance[s] : (int32_t)MILITARY_STANCE_HOLD);
    cache.stance[s] = -1;
}

} // namespace

void MilitaryCore::run_movement(const MilitaryWorldDigest &digest) {
    MilitaryArmyStore &a = _armies;
    static thread_local std::vector<uint8_t> touched;
    bool moved_any = false;
    const size_t cells = (size_t)std::max(0, _terrain.cell_count);
    touched.assign(cells, 0);
    int32_t moving = 0;
    // Naval transport: settle the stance of every formation against the cell it
    // occupies before the day's movement, so the embarked exemption below and
    // the sea attrition are never a day behind.
    for (int32_t slot = 0; slot < (int32_t)a.active.size(); ++slot) {
        if (!a.active[(size_t)slot]) continue;
        if (a.owner_slot[(size_t)slot] < 0) continue;
        sync_sea_stance(*this, slot);
    }
    for (int32_t slot = 0; slot < (int32_t)a.active.size(); ++slot) {
        if (!a.active[(size_t)slot]) continue;
        const size_t s = (size_t)slot;
        const int32_t owner = a.owner_slot[s];
        if (owner < 0) continue;
        if (a.path_cursor[s] >= a.path_len[s]) continue;
        // RETREAT formations get their route from the war stage only.
        if (a.stance[s] == (uint8_t)MILITARY_STANCE_RETREAT) continue;
        ++moving;
        // ---- daily move budget (design 7.3)
        const int64_t speed_stat = stat_q16(digest, owner, MSTAT_SPEED);
        int64_t mp = a.move_points_q16[s] + mul_div((int64_t)a.cached_speed_q16[s], speed_stat, MILITARY_Q16);
        if (a.supply_ratio_q16[s] < (MILITARY_Q16 / 2)) mp = mul_div(mp, 4, 5);           // supply x0.8
        if (a.organization_q16[s] < (MILITARY_Q16 * 3 / 10)) mp = mul_div(mp, 7, 10);     // org x0.7
        const int64_t mp_cap = (int64_t)MILITARY_Q16 * 8;
        if (mp > mp_cap) mp = mp_cap;
        const bool engaged = a.engagement[s] >= 0;
        const bool exploring = exploration_is_live_for_army(slot);
        while (a.path_cursor[s] < a.path_len[s]) {
            const int32_t idx = a.path_offset[s] + a.path_cursor[s];
            if (idx < 0 || (size_t)idx >= _path_cells.size()) break;
            const int32_t next = _path_cells[(size_t)idx];
            const int32_t cur = a.cell[s];
            if (exploring &&
                !exploration_passable_for(next, owner, digest)) {
                // Exploration never crosses a foreign controller. A route can
                // become stale when control changes between days; stop here and
                // let the next prepare replan instead of opening an engagement.
                a.path_len[s] = 0;
                a.path_cursor[s] = 0;
                a.target_cell[s] = -1;
                a.move_points_q16[s] = 0;
                break;
            }
            const int32_t cost = step_cost_q16(cur, next, owner, digest);
            if (cost < 0) break;                        // lost access: wait
            if (mp < cost) break;                       // out of move points
            // ZOC: an army already in a fight cannot slip past into another
            // cell that is adjacent to a hostile formation (design 7.3).
            if (engaged && has_hostile_adjacent_army(next, owner)) break;
            // Entering an enemy-controlled cell opens an engagement instead of
            // stepping in; the army halts on the border. Water carries no land
            // engagement (design §7.4: a seaborne army never fights on the way),
            // so a sea cell is entered whatever its nominal owner.
            if (!cell_is_water(_terrain, next)) {
                const int32_t owner_next = (size_t)next < digest.cell_owner_slot.size()
                                               ? digest.cell_owner_slot[(size_t)next]
                                               : -1;
                const int32_t ctrl_next = controller_of(next);
                const int32_t effective = ctrl_next >= 0 ? ctrl_next : owner_next;
                if (effective >= 0 && effective != owner) {
                    int32_t defender = has_hostile_adjacent_army(next, owner) ? effective : effective;
                    open_engagement(cur, next, slot, defender);
                    a.path_cursor[s] = a.path_len[s];
                    if (exploration_row_for_army(slot) >= 0) {
                        // Automatic exploration keeps its mission while the
                        // engagement resolves so the next day can resume the
                        // planned phase instead of silently becoming a manual
                        // idle formation.
                        pause_exploration_for_battle(slot);
                    } else {
                        a.mission[s] = (uint8_t)MILITARY_MISSION_NONE;
                    }
                    mp = 0;
                    break;
                }
            }
            // ---- step in
            index_remove(slot);
            a.prev_cell[s] = cur;
            a.cell[s] = next;
            a.moved_day[s] = _last_day;
            index_insert(slot, next);
            // Every actually entered cell feeds the explored-only trail. The
            // final cell remains the ordinary vision source; this is the extra
            // history for multi-cell days.
            record_exploration_trail(slot, owner, next);
            if ((size_t)next < touched.size()) touched[(size_t)next] = 1;
            moved_any = true;
            mp -= cost;
            ++a.path_cursor[s];
        }
        a.move_points_q16[s] = (int32_t)std::min<int64_t>(mp, 0x07FFFFFF);

        // ---- end-of-day losses (design 7.1 / 7.3, contract §2.1)
        const int32_t cell = a.cell[s];
        if (cell < 0 || cell >= _terrain.cell_count) continue;
        int64_t heads = a.cached_headcount[s];
        if (heads <= 0) continue;
        if (cell_is_water(_terrain, cell)) {
            // At sea there is no land environment attrition, but the crossing
            // costs kSeaAttritionBp per day. The dead are booked on the last
            // land cell they left, so Economy never creates a cohort at sea.
            const int64_t bp100 = (int64_t)kSeaAttritionBp * kBp100PerBp;
            int64_t loss = mul_div(heads * bp100, 1, kBp100Scale);
            if (loss <= 0) {
                const int32_t roll = rng_q16(_seed, mix_key(kSeaAttritionKey, (uint64_t)slot), _last_day);
                if ((int64_t)roll * kBp100Scale < heads * bp100) loss = 1;
            }
            if (loss <= 0) continue;
            const int64_t removed = lot_remove_casualties((uint8_t)MILITARY_LOT_ARMY, slot, loss);
            if (removed <= 0) continue;
            int32_t book_cell = cell;
            const int32_t prev = a.prev_cell[s];
            if (prev >= 0 && prev < _terrain.cell_count && !cell_is_water(_terrain, prev)) book_cell = prev;
            emit_army_personnel_loss(slot, book_cell, removed, removed, _attrition_intents);
            refresh_army_cache(slot);
            continue;
        }
        int64_t attr_bp100 = 0;
        const uint8_t lf = _terrain.landform[(size_t)cell];
        const uint8_t veg = _terrain.vegetation[(size_t)cell];
        const uint8_t cv = _terrain.cover[(size_t)cell];
        if ((size_t)lf < _catalog.landform_attrition_bp100.size()) attr_bp100 += _catalog.landform_attrition_bp100[(size_t)lf];
        if ((size_t)veg < _catalog.vegetation_attrition_bp100.size()) attr_bp100 += _catalog.vegetation_attrition_bp100[(size_t)veg];
        if ((size_t)cv < _catalog.cover_attrition_bp100.size()) attr_bp100 += _catalog.cover_attrition_bp100[(size_t)cv];
        if (a.stance[s] == (uint8_t)MILITARY_STANCE_EMBARKED) attr_bp100 = 0;   // at sea: no land attrition
        if (attr_bp100 <= 0) continue;
        const int64_t attr_stat = stat_q16(digest, owner, MSTAT_ATTRITION);
        // bp100 (0.01%) -> fraction; stat divides the loss.
        int64_t loss = mul_div(mul_div(heads * attr_bp100, MILITARY_Q16, attr_stat), 1, kBp100Scale);
        if (loss <= 0) {
            // Sub-one-head attrition is rolled deterministically per (army, day).
            const int32_t roll = rng_q16(_seed, mix_key(0x41545452ull, (uint64_t)slot), _last_day);
            if ((int64_t)roll * kBp100Scale < heads * attr_bp100) loss = 1;
        }
        if (loss <= 0) continue;
        const int64_t removed = lot_remove_casualties((uint8_t)MILITARY_LOT_ARMY, slot, loss);
        if (removed <= 0) continue;
        // Harsh-environment deaths (army-personnel contract §2.1): the formation's
        // people live in an Economy lane row, so the loss is released to the cell
        // the formation died in (opcode 31) and booked there as a casualty in the
        // same D+1 batch. A casualty row alone would target the home cell's
        // soldier cohort, which these men are not part of any more.
        emit_army_personnel_loss(slot, cell, removed, removed, _attrition_intents);
        refresh_army_cache(slot);
    }
    // A formation that ended the day on water is embarked from now on, and one
    // that landed gets its previous stance back in the same frame.
    for (int32_t slot = 0; slot < (int32_t)a.active.size(); ++slot) {
        if (!a.active[(size_t)slot]) continue;
        if (a.owner_slot[(size_t)slot] < 0) continue;
        sync_sea_stance(*this, slot);
    }
    if (moved_any && !touched.empty()) rebuild_cell_index();
    _report.armies_moving = moving;
}

bool MilitaryCore::has_hostile_adjacent_army(int32_t cell, int32_t country_slot) const {
    if (cell < 0 || cell >= _terrain.cell_count) return false;
    const int32_t base = cell * 6;
    for (int32_t d = 0; d < 6; ++d) {
        const int32_t nb = _terrain.neighbors[(size_t)(base + d)];
        if (nb < 0 || (size_t)nb >= _cell_head.size()) continue;
        int32_t a = _cell_head[(size_t)nb];
        while (a >= 0) {
            const int32_t owner = _armies.owner_slot[(size_t)a];
            if (owner >= 0 && owner != country_slot && at_war(country_slot, owner)) return true;
            a = _armies.next_in_cell[(size_t)a];
        }
    }
    return false;
}

} // namespace pk
