// NativeMilitaryRuntime - logistics (design sec 9).
//
// Automatic supply: 3-cell procurement (design 9.3), threat/guard fields,
// convoys + interception, daily consumption and requisition. Pure integer /
// fixed point, no Godot types, stamp-reused scratch, deterministic SplitMix64
// keyed by (seed, key, day) through mil::rng.
//
// Custody (contract sec 0.5): PROCURE_GOOD pays a market and lands the goods in
// the national treasury, which is the single "received" side of the sec 9.7
// ledger. Military's own stock (garrison cell / army slot) is the working
// buffer that is decremented in lock-step with the CONSUME_TREASURY_GOOD
// intent, so the ledger invariant stays exact:
//   received = stock + in_transit + consumed + intercepted_out
//              - intercepted_in + returned

#include "military_core.h"
#include "military_core_internal.h"

#include <algorithm>
#include <utility>

namespace pk {
namespace mil {

constexpr int32_t SUPPLY_CLASS_COUNT = MILITARY_MAX_SUPPLY_CLASSES;
constexpr int32_t STOCK_CLASS_EQUIPMENT = MILITARY_SUPPLY_EQUIPMENT;
// Target inventory: 10 days of consumption; reorder below 5 (sec 9.3).
constexpr int64_t TARGET_DAYS = 10;
// Reorder point: below 5 days of stock a holder buys up to a 10-day target.
constexpr int64_t REORDER_DAYS = 5;
// One market may sell at most 50% of its sellable stock per day (sec 9.3).
constexpr int64_t MARKET_DAY_SALE_CAP_Q16 = 32768;
// Procurement fallback probes up to 4 alternative sources (sec 9.3).
constexpr int32_t PROCURE_SOURCE_PROBES = 4;
constexpr int64_t PROCURE_MIN_QTY = 100;
// Convoy interception (sec 9.5).
constexpr int64_t INTERCEPT_CAP_Q16 = 32768;
constexpr int32_t INTERCEPT_PLANES = 6;
constexpr int64_t BLOCKED_RETURN_DAYS = 30;
constexpr int32_t EVENT_CAP_CONVOY = 32;
// Equipment condition decay / recovery (sec 4.2).
constexpr int32_t CONDITION_FLOOR_Q16 = 32768;
constexpr int32_t CONDITION_DECAY_Q16 = 328;
constexpr int32_t CONDITION_RECOVER_Q16 = 655;
// Ration EMA (sec 10): 3-day mean.
constexpr int32_t RATION_EMA_WEIGHT_Q16 = 21845;
// Requisition penalty window (sec 9.7).
constexpr int64_t REQUISITION_PENALTY_DAYS = 30;
constexpr int64_t REQUISITION_STOCK_BP = 1000;   // up to 10% of local stock/day
// Transport: base 1 cell/day, scaled by country.military.supply_transport (sec 9.4).
constexpr int32_t ESCORT_BASE_Q16 = 13107;    // 0.2 (sec 9.5)

inline int64_t mul_q16(int64_t value, int32_t factor_q16) {
    return (value * static_cast<int64_t>(factor_q16)) >> 16;
}

inline int32_t clamp_q16(int64_t value, int32_t lo, int32_t hi) {
    if (value < lo) return lo;
    if (value > hi) return hi;
    return static_cast<int32_t>(value);
}

// ------------------------------------------------------------- small structs

// Dense open-address map cell -> (class, source) of the current supply probe.
// Every cell stores at most one source, updated only by a nearer class probe,
// which matches the "nearest owned+controlled market within the radius" rule of
// design 9.3 without keeping a per-class field for the whole world.
struct FieldIndex {
    std::vector<uint32_t> keys;
    std::vector<int32_t> values;
    uint32_t mask = 0;
    int32_t cell_count = 1;

    void clear(int32_t cells) {
        size_t capacity = 64;
        const size_t wanted = static_cast<size_t>(std::max<int32_t>(cells, 1)) * 2 + 8;
        while (capacity < wanted) capacity <<= 1;
        keys.assign(capacity, 0xffffffffu);
        values.assign(capacity, -1);
        mask = static_cast<uint32_t>(capacity - 1);
        cell_count = std::max<int32_t>(cells, 1);
    }

    // Records (cell, class) -> source cell; a later write for the same cell
    // replaces the entry only with a lower class (the caller walks rings in
    // nearest-first order, so the first hit of a class is also the nearest).
    void set(int32_t cell, int32_t cls, int32_t source) {
        if (keys.empty() || cell < 0 || source < 0 || cell_count <= 0) return;
        uint32_t h = (static_cast<uint32_t>(cell) * 2654435761u) & mask;
        while (keys[h] != 0xffffffffu) {
            if (keys[h] == static_cast<uint32_t>(cell)) {
                if (values[h] / cell_count > cls) values[h] = cls * cell_count + source;
                return;
            }
            h = (h + 1u) & mask;
        }
        keys[h] = static_cast<uint32_t>(cell);
        values[h] = cls * cell_count + source;
    }

    // engine 0 = source cell, 1 = class.
    int32_t lookup(int32_t cell, int32_t engine) const {
        if (keys.empty() || cell < 0) return -1;
        uint32_t h = (static_cast<uint32_t>(cell) * 2654435761u) & mask;
        while (keys[h] != 0xffffffffu) {
            if (keys[h] == static_cast<uint32_t>(cell)) {
                const int32_t packed = values[h];
                return engine == 0 ? (packed % cell_count) : (packed / cell_count);
            }
            h = (h + 1u) & mask;
        }
        return -1;
    }
};

// Market rows for the current day, indexed by (cell, good).
struct MarketDay {
    std::vector<uint32_t> keys;
    std::vector<int32_t> offsets;
    std::vector<int32_t> row_cell;
    std::vector<int32_t> row_good;
    std::vector<int64_t> row_sellable;
    std::vector<int64_t> row_price;
    uint32_t mask = 0;

    static uint32_t hash_key(int32_t cell, int32_t good) {
        uint64_t v = (static_cast<uint64_t>(static_cast<uint32_t>(cell)) << 32U) |
                     static_cast<uint32_t>(good);
        v ^= v >> 33U;
        v *= 0xff51afd7ed558ccdULL;
        v ^= v >> 33U;
        return static_cast<uint32_t>(v);
    }

    void build(const MilitaryWorldDigest &digest) {
        size_t capacity = 64;
        const size_t wanted =
            static_cast<size_t>(std::max<size_t>(digest.market_cell.size(), 1)) * 2 + 8;
        while (capacity < wanted) capacity <<= 1;
        keys.assign(capacity, 0xffffffffu);
        offsets.assign(capacity, -1);
        mask = static_cast<uint32_t>(capacity - 1);
        row_cell.clear();
        row_good.clear();
        row_sellable.clear();
        row_price.clear();
        const size_t rows = digest.market_cell.size();
        row_cell.reserve(rows);
        row_good.reserve(rows);
        row_sellable.reserve(rows);
        row_price.reserve(rows);
        for (size_t i = 0; i < rows; ++i) {
            const int32_t cell = digest.market_cell[i];
            const int32_t good = digest.market_good[i];
            if (cell < 0 || good < 0) continue;
            uint32_t h = hash_key(cell, good) & mask;
            int32_t row = -1;
            while (keys[h] != 0xffffffffu) {
                const int32_t candidate = offsets[h];
                if (row_cell[static_cast<size_t>(candidate)] == cell &&
                    row_good[static_cast<size_t>(candidate)] == good) {
                    row = candidate;
                    break;
                }
                h = (h + 1u) & mask;
            }
            const int64_t sellable =
                i < digest.market_sellable.size() ? digest.market_sellable[i] : 0;
            const int64_t price = i < digest.market_price.size() ? digest.market_price[i] : 0;
            if (row >= 0) {
                row_sellable[static_cast<size_t>(row)] = sellable;
                row_price[static_cast<size_t>(row)] = price;
                continue;
            }
            keys[h] = 1;
            offsets[h] = static_cast<int32_t>(row_cell.size());
            row_cell.push_back(cell);
            row_good.push_back(good);
            row_sellable.push_back(sellable);
            row_price.push_back(price);
        }
    }

    int32_t find(int32_t cell, int32_t good) const {
        if (keys.empty()) return -1;
        uint32_t h = hash_key(cell, good) & mask;
        while (keys[h] != 0xffffffffu) {
            const int32_t row = offsets[h];
            if (row_cell[static_cast<size_t>(row)] == cell &&
                row_good[static_cast<size_t>(row)] == good) {
                return row;
            }
            h = (h + 1u) & mask;
        }
        return -1;
    }
};

// 4-ary min-heap over packed (dist << 32 | node).
struct CellHeap {
    std::vector<int64_t> data;
    void clear() { data.clear(); }
    bool empty() const { return data.empty(); }
    static int64_t pack(int32_t dist, int32_t node) {
        return (static_cast<int64_t>(static_cast<uint32_t>(dist)) << 32) |
               static_cast<int64_t>(static_cast<uint32_t>(node) & 0x7fffffffu);
    }
    static int32_t node_of(int64_t v) { return static_cast<int32_t>(v & 0x7fffffff); }
    static int32_t dist_of(int64_t v) {
        return static_cast<int32_t>((static_cast<uint64_t>(v) >> 32U) & 0x7fffffffu);
    }
    void push(int64_t v) {
        data.push_back(v);
        size_t i = data.size() - 1;
        while (i > 0) {
            const size_t parent = (i - 1) >> 2;
            if (data[parent] <= data[i]) break;
            std::swap(data[parent], data[i]);
            i = parent;
        }
    }
    int64_t pop() {
        const int64_t top = data[0];
        const int64_t last = data.back();
        data.pop_back();
        if (!data.empty()) {
            data[0] = last;
            size_t i = 0;
            const size_t n = data.size();
            for (;;) {
                const size_t first = i * 4 + 1;
                if (first >= n) break;
                size_t best = first;
                const size_t end = std::min(first + 4, n);
                for (size_t c = first + 1; c < end; ++c) {
                    if (data[c] < data[best]) best = c;
                }
                if (data[i] <= data[best]) break;
                std::swap(data[i], data[best]);
                i = best;
            }
        }
        return top;
    }
};
// Allocation-free scratch reused across the logistics day.
struct Scratch {
    FieldIndex index;
    MarketDay markets;
    CellHeap heap;
    std::vector<int64_t> sellable_left;             // per market row
    std::vector<uint8_t> owned_mask;                // per cell: controller == slot
    std::vector<int64_t> cost_by_cell;              // per cell: cost to source
    std::vector<int64_t> class_units;               // per class need units today
    std::vector<uint32_t> event_stamp;              // per country: convoy event day
    std::vector<int32_t> army_heads;                // per army cached headcount

    void reset_day() {
        sellable_left.clear();
        class_units.clear();
    }
};

Scratch &scratch() {
    static thread_local Scratch s;
    return s;
}

// --------------------------------------------------------------- utilities

int32_t stat_or(const MilitaryWorldDigest &digest, int32_t slot, int32_t stat,
                int32_t base_q16 = MILITARY_Q16) {
    if (slot < 0 || slot >= digest.country_capacity) return base_q16;
    if (stat < 0 || stat >= digest.stat_count) return base_q16;
    const size_t index = static_cast<size_t>(slot) * static_cast<size_t>(digest.stat_count) +
                         static_cast<size_t>(stat);
    if (index >= digest.country_stat_q16.size()) return base_q16;
    const int32_t value = digest.country_stat_q16[index];
    return value > 0 ? value : base_q16;
}

int32_t landform_supply_mult_q16(const MilitaryCatalog &catalog, int32_t landform) {
    const int32_t count = static_cast<int32_t>(catalog.landform_supply_q8.size());
    if (landform >= 0 && landform < count) {
        const int32_t q8 = catalog.landform_supply_q8[static_cast<size_t>(landform)];
        if (q8 > 0) return q8 * 256;
    }
    return MILITARY_Q16;
}

int32_t terrain_of_cell(const MilitaryTerrainInput &terrain, int32_t cell) {
    if (cell < 0 || cell >= static_cast<int32_t>(terrain.landform.size())) return -1;
    return terrain.landform[static_cast<size_t>(cell)];
}

int32_t controller_of_cell(const MilitaryCore &core, const MilitaryWorldDigest &digest,
                           int32_t cell) {
    if (cell < 0) return -1;
    if (cell < static_cast<int32_t>(core._cell_controller.size())) {
        const int32_t controller = core._cell_controller[static_cast<size_t>(cell)];
        if (controller >= 0) return controller;
    }
    if (cell < static_cast<int32_t>(digest.cell_owner_slot.size())) {
        return digest.cell_owner_slot[static_cast<size_t>(cell)];
    }
    return -1;
}

uint64_t country_handle_for(const MilitaryWorldDigest &digest, int32_t slot) {
    if (slot < 0 || slot >= static_cast<int32_t>(digest.country_handle.size())) return 0;
    return digest.country_handle[static_cast<size_t>(slot)];
}

int32_t classifier_good(const MilitaryCatalog &catalog, int32_t cls, int32_t ordinal) {
    const std::vector<int32_t> &goods = catalog.supply_goods[static_cast<size_t>(cls)];
    if (ordinal < 0 || ordinal >= static_cast<int32_t>(goods.size())) return -1;
    return goods[static_cast<size_t>(ordinal)];
}

int32_t class_index_of_good(const MilitaryCatalog &catalog, int32_t cls, int32_t good) {
    if (cls < 0 || cls >= MILITARY_MAX_SUPPLY_CLASSES) return -1;
    const std::vector<int32_t> &goods = catalog.supply_goods[static_cast<size_t>(cls)];
    for (size_t g = 0; g < goods.size(); ++g) {
        if (goods[g] == good) return static_cast<int32_t>(g);
    }
    return -1;
}

int32_t category_of_good(const MilitaryCatalog &catalog, int32_t good) {
    for (size_t c = 0; c < catalog.categories.size(); ++c) {
        const MilitaryEquipCategory &cat = catalog.categories[c];
        for (size_t g = 0; g < cat.good_ids.size(); ++g) {
            if (cat.good_ids[g] == good) return static_cast<int32_t>(c);
        }
    }
    return -1;
}

} // namespace mil

using namespace mil;

// ================================================================ stock APIs

namespace {

// Open addressing over _stocks rows keyed by (holder_kind, holder, country,
// good). `_stock_rows[h]` holds row index + 1; 0 = empty bucket. Validity is
// transient: every structural change (insert / erase / swap-from-back) drops
// the index and the next lookup rebuilds it in O(rows).
struct StockKey {
    uint64_t a = 0, b = 0;
};

StockKey stock_key(uint8_t holder_kind, int32_t holder, int32_t country_slot, int32_t good) {
    StockKey k;
    k.a = (uint64_t)holder_kind ^ ((uint64_t)(uint32_t)holder << 8);
    k.b = (uint64_t)(uint32_t)country_slot ^ ((uint64_t)(uint32_t)(good + 1) << 32);
    return k;
}

inline uint64_t hash_stock_key(const StockKey &k) {
    return mil::splitmix_final(k.a * 0x9e3779b97f4a7c15ull ^ k.b);
}

} // namespace

void military_stock_index_rebuild(const MilitaryCore &cc) {
    MilitaryCore &c = const_cast<MilitaryCore &>(cc);
    size_t capacity = 16;
    while (capacity < c._stocks.size() * 2 + 8) capacity <<= 1;
    c._stock_rows.assign(capacity, 0);
    c._stock_index_ok = true;
    for (size_t i = 0; i < c._stocks.size(); ++i) {
        const MilitaryStockRow &row = c._stocks[i];
        const uint64_t h = hash_stock_key(stock_key(row.holder_kind, row.holder, row.country_slot, row.good));
        size_t at = (size_t)(h & (capacity - 1));
        while (c._stock_rows[at] != 0) at = (at + 1) & (capacity - 1);
        c._stock_rows[at] = (int32_t)i + 1;
    }
}

int32_t military_stock_row(const MilitaryCore &cc, uint8_t holder_kind, int32_t holder,
                           int32_t country_slot, int32_t good) {
    MilitaryCore &c = const_cast<MilitaryCore &>(cc);
    if (!c._stock_index_ok) military_stock_index_rebuild(c);
    if (c._stock_rows.empty()) return -1;
    const size_t mask = c._stock_rows.size() - 1;
    const uint64_t h = hash_stock_key(stock_key(holder_kind, holder, country_slot, good));
    size_t at = (size_t)(h & mask);
    for (;;) {
        const int32_t packed = c._stock_rows[at];
        if (packed == 0) return -1;
        const size_t i = (size_t)(packed - 1);
        if (i >= c._stocks.size()) return -1;
        const MilitaryStockRow &row = c._stocks[i];
        if (row.holder_kind == holder_kind && row.holder == holder && row.country_slot == country_slot &&
            row.good == good) {
            return (int32_t)i;
        }
        at = (at + 1) & mask;
    }
}

int64_t MilitaryCore::stock_get(uint8_t holder_kind, int32_t holder, int32_t country_slot,
                                int32_t good) const {
    const int32_t row = military_stock_row(*this, holder_kind, holder, country_slot, good);
    return row >= 0 ? _stocks[(size_t)row].qty : 0;
}

// Need units of <cls> a holder currently owns: every stocked candidate good of
// that class converted with its supply yield (design 9.2), in need units.
int64_t MilitaryCore::stock_units(int32_t country_slot, uint8_t holder_kind, int32_t holder,
                                  int32_t cls) const {
    if (cls < 0 || cls >= MILITARY_MAX_SUPPLY_CLASSES) return 0;
    const std::vector<int32_t> &goods = _catalog.supply_goods[(size_t)cls];
    const std::vector<int32_t> &yield_q16 = _catalog.supply_yield_q16[(size_t)cls];
    int64_t units = 0;
    for (size_t g = 0; g < goods.size(); ++g) {
        const int64_t qty = stock_get(holder_kind, holder, country_slot, goods[g]);
        if (qty <= 0) continue;
        const int64_t y = g < yield_q16.size() && yield_q16[g] > 0 ? yield_q16[g] : MILITARY_Q16;
        units += qty * y / MILITARY_Q16;
    }
    return units;
}

int64_t MilitaryCore::stock_add(uint8_t holder_kind, int32_t holder, int32_t country_slot,
                                int32_t good, int64_t delta) {
    if (delta == 0) return stock_get(holder_kind, holder, country_slot, good);
    const int32_t at = military_stock_row(*this, holder_kind, holder, country_slot, good);
    if (at >= 0) {
        MilitaryStockRow &row = _stocks[(size_t)at];
        row.qty += delta;
        if (row.qty < 0) row.qty = 0;
        const int64_t result = row.qty;
        if (row.qty == 0) {
            _stocks[(size_t)at] = _stocks.back();
            _stocks.pop_back();
            _stock_index_ok = false;
        }
        return result;
    }
    if (delta <= 0) return 0;
    MilitaryStockRow row;
    row.holder_kind = holder_kind;
    row.holder = holder;
    row.country_slot = country_slot;
    row.good = good;
    row.qty = delta;
    _stocks.push_back(row);
    _stock_index_ok = false;
    return delta;
}

void MilitaryCore::stock_clear_holder(uint8_t holder_kind, int32_t holder) {
    size_t write = 0;
    for (size_t i = 0; i < _stocks.size(); ++i) {
        if (_stocks[i].holder_kind == holder_kind && _stocks[i].holder == holder) continue;
        if (write != i) _stocks[write] = _stocks[i];
        ++write;
    }
    if (write != _stocks.size()) {
        _stocks.resize(write);
        _stock_index_ok = false;
    }
}

// ========================================================= supply indexes
// Design 9.3 (user decision): a demander (garrison cell, army cell, training
// order) may only buy from markets in cells it OWNS and CONTROLS within hex
// distance <= MILITARY_SUPPLY_RADIUS (at most 19 cells). Nothing here is a
// per-country field and nothing ever scans all markets: the market rows of the
// committed digest are bucketed once per day (O(rows)) and every ring is
// precomputed once per topology.

namespace {

// Wrap-aware BFS over the neighbour table; neighbours already carry the wrap,
// so this is the exact hex distance on the wrapped map. Built once per topology
// change (MILITARY_SUPPLY_RADIUS rings, at most 19 cells).
void build_rings(MilitaryCore &core) {
    const int32_t cells = core._terrain.cell_count;
    core._ring_off.assign((size_t)std::max(0, cells) + 1, 0);
    core._ring_len.assign((size_t)std::max(0, cells), 0);
    core._ring_cells.clear();
    core._ring_dist.clear();
    if (cells <= 0) return;
    core._ring_cells.reserve((size_t)cells * (size_t)MILITARY_SUPPLY_RING_CELLS);
    core._ring_dist.reserve((size_t)cells * (size_t)MILITARY_SUPPLY_RING_CELLS);
    static thread_local std::vector<int32_t> dist;
    static thread_local std::vector<uint32_t> stamp;
    static thread_local uint32_t gen = 0;
    static thread_local std::vector<int32_t> queue;
    if ((int32_t)stamp.size() < cells) {
        stamp.assign((size_t)cells, 0);
        dist.assign((size_t)cells, 0);
        gen = 0;
    }
    const int32_t neighbor_total = (int32_t)core._terrain.neighbors.size();
    const int32_t *neighbours = core._terrain.neighbors.data();
    for (int32_t cell = 0; cell < cells; ++cell) {
        core._ring_off[(size_t)cell] = (int32_t)core._ring_cells.size();
        ++gen;
        if (gen == 0) {
            std::fill(stamp.begin(), stamp.end(), 0u);
            gen = 1;
        }
        queue.clear();
        queue.push_back(cell);
        stamp[(size_t)cell] = gen;
        dist[(size_t)cell] = 0;
        int32_t head = 0;
        while (head < (int32_t)queue.size()) {
            const int32_t at = queue[(size_t)head++];
            const int32_t d = dist[(size_t)at];
            core._ring_cells.push_back(at);
            core._ring_dist.push_back((uint8_t)d);
            if (d >= MILITARY_SUPPLY_RADIUS) continue;
            if (at * 6 + 5 >= neighbor_total) continue;
            for (int32_t k = 0; k < 6; ++k) {
                const int32_t nb = neighbours[(size_t)(at * 6 + k)];
                if (nb < 0 || nb >= cells) continue;
                if (stamp[(size_t)nb] == gen) continue;
                stamp[(size_t)nb] = gen;
                dist[(size_t)nb] = d + 1;
                queue.push_back(nb);
            }
        }
        core._ring_len[(size_t)cell] = (uint8_t)(queue.size() > 255 ? 255 : queue.size());
    }
    core._ring_off[(size_t)cells] = (int32_t)core._ring_cells.size();
}

bool rings_ready(const MilitaryCore &core) {
    const size_t cells = (size_t)std::max(0, core._terrain.cell_count);
    if (cells <= 0) return false;
    if (core._ring_off.size() != cells + 1 || core._ring_len.size() != cells) return false;
    return (size_t)core._ring_off[cells] <= core._ring_cells.size();
}

// Market-good slot of a digest good id: the frozen digest carries one dense
// good id per economy good, so the good id itself is the slot (ids below 128).
int32_t market_good_slot(const MilitaryWorldDigest &digest, int32_t good) {
    (void)digest;
    return good >= 0 && good < 128 ? good : -1;
}

// One pass over the committed market rows: per-cell CSR (rows in (cell, row)
// order), the day quota (50% of the sellable stock, design 9.3) and the
// per-cell merchant flag used by the connectivity probes.
void build_market_csr(MilitaryCore &core, const MilitaryWorldDigest &digest) {
    const int32_t cells = core._terrain.cell_count;
    const size_t n = (size_t)std::max(0, cells);
    const size_t rows = digest.market_cell.size();
    core._md_row_cell.clear();
    core._md_row_good.clear();
    core._md_row_sellable.clear();
    core._md_row_price.clear();
    core._md_row_cell.reserve(rows);
    core._md_row_good.reserve(rows);
    core._md_row_sellable.reserve(rows);
    core._md_row_price.reserve(rows);
    for (size_t i = 0; i < rows; ++i) {
        const int32_t cell = digest.market_cell[i];
        const int32_t good = i < digest.market_good.size() ? digest.market_good[i] : -1;
        if (cell < 0 || cell >= cells || good < 0) continue;
        const int32_t slot = market_good_slot(digest, good);
        if (slot < 0) continue;
        const int64_t sellable = i < digest.market_sellable.size() ? digest.market_sellable[i] : 0;
        const int64_t price = i < digest.market_price.size() ? digest.market_price[i] : 0;
        core._md_row_cell.push_back(cell);
        core._md_row_good.push_back(slot);
        core._md_row_sellable.push_back(sellable > 0 ? (sellable * MARKET_DAY_SALE_CAP_Q16) >> 16 : 0);
        core._md_row_price.push_back(price);
    }
    const size_t live = core._md_row_cell.size();
    core._md_cell_off.assign(n + 1, 0);
    for (int32_t cell : core._md_row_cell) ++core._md_cell_off[(size_t)cell + 1];
    for (size_t c = 0; c < n; ++c) core._md_cell_off[c + 1] += core._md_cell_off[c];
    core._md_cell_rows.assign(live, -1);
    std::vector<int32_t> cursor(core._md_cell_off.begin(), core._md_cell_off.end() - 1);
    for (size_t i = 0; i < live; ++i) {
        const size_t cell = (size_t)core._md_row_cell[i];
        core._md_cell_rows[(size_t)cursor[cell]++] = (int32_t)i;
    }
    core._md_cell_has_merchant.assign(n, 0);
    const size_t merchants = digest.cell_has_merchant.size();
    for (size_t c = 0; c < n; ++c) {
        if (c < merchants) {
            core._md_cell_has_merchant[c] = digest.cell_has_merchant[c] != 0 ? 1 : 0;
        } else {
            core._md_cell_has_merchant[c] = core._md_cell_off[c + 1] > core._md_cell_off[c] ? 1 : 0;
        }
    }
}

bool market_csr_current(const MilitaryCore &core, const MilitaryWorldDigest &digest) {
    if (core._md_day != digest.day) return false;
    if (core._md_cell_off.size() != (size_t)std::max(0, core._terrain.cell_count) + 1) return false;
    const size_t live = core._md_row_cell.size();
    return live == core._md_row_good.size() && live == core._md_row_sellable.size() &&
           live == core._md_row_price.size() && live == core._md_cell_rows.size();
}

void market_csr_drop(MilitaryCore &core) {
    core._md_cell_off.clear();
    core._md_cell_rows.clear();
    core._md_row_cell.clear();
    core._md_row_good.clear();
    core._md_row_sellable.clear();
    core._md_row_price.clear();
    core._md_cell_has_merchant.clear();
    core._md_row_left.clear();
    core._sup_row_own.clear();
    core._md_day = -1;
}

} // namespace

void military_market_reset(MilitaryCore &core) {
    market_csr_drop(core);
    core._connected_valid = false;
    core._connected_day = -1;
    core._connected_revision = -1;
    core._conn_group.clear();
    core._conn_group_slot.clear();
    core._conn_mark_cells.clear();
    core._cache_rows.clear();
}

MilitaryCore::MarketDayScope::MarketDayScope(MilitaryCore &c) : core(c) {}

MilitaryCore::MarketDayScope::~MarketDayScope() {
    // The indexes are per day (design 9.3: built once, dropped for the rest of
    // the day), so a day without a demander and without a disconnection probe
    // pays nothing at all.
    market_csr_drop(core);
}

void MilitaryCore::MarketDayScope::ensure(const MilitaryWorldDigest &digest) {
    if (!rings_ready(core)) build_rings(core);
    if (market_csr_current(core, digest)) return;
    market_csr_drop(core);
    build_market_csr(core, digest);
    core._md_day = digest.day;
    core._connected_valid = false;   // the connectivity marks follow the rows
}

void MilitaryCore::MarketDayScope::drop() { market_csr_drop(core); }

bool military_owns_cell(const MilitaryCore &core, const MilitaryWorldDigest &digest, int32_t cell,
                        int32_t slot) {
    if (cell < 0 || slot < 0) return false;
    if ((size_t)cell >= digest.cell_owner_slot.size() || digest.cell_owner_slot[(size_t)cell] != slot) {
        return false;
    }
    return controller_of_cell(core, digest, cell) == slot;
}

// Connectivity per design 9.3: one BFS per country over the cells it owns and
// controls. A cell is connected when its group holds at least one cell with a
// market row. Built lazily on the first probe of a day (or after control moved)
// over the occupied cells only, never over every cell.
bool military_connectivity_connected(const MilitaryCore &cc, const MilitaryWorldDigest &digest,
                                     int32_t slot, int32_t cell) {
    MilitaryCore &core = const_cast<MilitaryCore &>(cc);
    const int32_t cells = core._terrain.cell_count;
    if (cells <= 0 || slot < 0 || cell < 0 || cell >= cells) return false;
    if (core._connected_valid && core._connected_day == digest.day &&
        core._connected_revision == (int64_t)core._control_revision &&
        core._conn_group.size() == (size_t)cells) {
        const int32_t group = core._conn_group[(size_t)cell];
        if (group < 0 || core._conn_group_slot[(size_t)group] != slot) return false;
        return core._conn_mark_cells[(size_t)group] > 0;
    }
    if (!market_csr_current(core, digest)) return false;   // the caller builds the day
    static thread_local std::vector<int32_t> seeds;
    seeds.clear();
    const int32_t ctrl_size = (int32_t)core._ct_ctrl_cells.size();
    for (int32_t i = 0; i < ctrl_size; ++i) {
        const int32_t c = core._ct_ctrl_cells[(size_t)i];
        if (c < 0 || c >= cells) continue;
        seeds.push_back(c);
    }
    core._conn_group.assign((size_t)cells, -1);
    core._conn_group_slot.clear();
    core._conn_mark_cells.clear();
    const int32_t neighbor_total = (int32_t)core._terrain.neighbors.size();
    const int32_t *neighbors = core._terrain.neighbors.data();
    core._bfs_queue.clear();
    for (int32_t seed : seeds) {
        if (core._conn_group[(size_t)seed] >= 0) continue;
        if (!military_owns_cell(core, digest, seed, slot)) continue;
        const int32_t group = (int32_t)core._conn_group_slot.size();
        core._conn_group_slot.push_back(slot);
        core._conn_mark_cells.push_back(0);
        core._bfs_queue.clear();
        core._bfs_queue.push_back(seed);
        core._conn_group[(size_t)seed] = group;
        for (size_t head = 0; head < core._bfs_queue.size(); ++head) {
            const int32_t at = core._bfs_queue[head];
            if (core._md_cell_off[(size_t)at + 1] > core._md_cell_off[(size_t)at] &&
                core._md_cell_has_merchant[(size_t)at]) {
                ++core._conn_mark_cells[(size_t)group];
            }
            if (at * 6 + 5 >= neighbor_total) continue;
            for (int32_t k = 0; k < 6; ++k) {
                const int32_t nb = neighbors[(size_t)(at * 6 + k)];
                if (nb < 0 || nb >= cells) continue;
                if (core._conn_group[(size_t)nb] >= 0) continue;
                if (!military_owns_cell(core, digest, nb, slot)) continue;
                core._conn_group[(size_t)nb] = group;
                core._bfs_queue.push_back(nb);
            }
        }
    }
    core._bfs_queue.clear();
    core._connected_valid = true;
    core._connected_day = digest.day;
    core._connected_revision = (int64_t)core._control_revision;
    const int32_t group = core._conn_group[(size_t)cell];
    if (group < 0 || core._conn_group_slot[(size_t)group] != slot) return false;
    return core._conn_mark_cells[(size_t)group] > 0;
}

// Cheap disconnection probe of design 9.3: the ring of the cell holds at least
// one market cell of the same country (owned AND controlled). No day CSR and no
// BFS is needed, so a requisition / last-stand probe never builds global state.
bool military_supply_connected(const MilitaryCore &core, const MilitaryWorldDigest &digest, int32_t slot,
                               int32_t cell) {
    if (slot < 0 || cell < 0 || cell >= core._terrain.cell_count) return false;
    if (!rings_ready(core)) return false;
    const bool have_rows = market_csr_current(core, digest);
    const int32_t begin = core._ring_off[(size_t)cell];
    const int32_t end = core._ring_off[(size_t)cell + 1];
    for (int32_t i = begin; i < end; ++i) {
        const int32_t at = core._ring_cells[(size_t)i];
        if (have_rows && core._md_cell_off[(size_t)at + 1] <= core._md_cell_off[(size_t)at]) continue;
        if (!military_owns_cell(core, digest, at, slot)) continue;
        return true;
    }
    return false;
}

// ============================================================= procurement
// Design 9.3 (user decision): a demander (garrison cell, army cell, training
// order) only buys from markets in cells it OWNS and CONTROLS within hex
// distance <= 3 of its own cell, via the precomputed rings and the per-day
// per-cell market CSR. Lowest price per need unit first, one market may sell at
// most 50% of its sellable stock per day. Nothing in range means unmet demand
// (report counter); there is no fallback scan and no per-country field.
//
// Four linear passes (none is O(cells) or O(markets x demanders)):
//   1. DEMAND  - garrison cells holding lots, army slots and training orders
//      are inspected once. Only holders BELOW the reorder point (< 5 days of
//      stock against a 10-day target) take part; each writes one entry per need
//      class whose stock is short.
//   2. WANT    - per entry, the market rows of its 19-cell rings (owned and
//      controlled cells only) are collected and put in (price per need unit,
//      row) order, so a cheap market wins over a nearer dear one.
//   3. SELL    - round robin over the entries' ordered rows: rank 0 of every
//      demand is bought before rank 1 of any, a demand stops after
//      PROCURE_MARKETS distinct markets, and no market exceeds its day quota.
//   4. DELIVER - per demander, its takes in ring order (market cell ascending):
//      a same-cell purchase lands today, a farther one becomes a convoy whose
//      route is the ring distance.
namespace {

// Distinct markets a single demand may be served by before it is cut off. The
// design cap is 4 markets; the ring implementation allows 8, which keeps a
// large garrison from starving on a few small markets.
constexpr int32_t PROCURE_MARKETS = 8;

// A market row an entry can reach.
struct ReachRow {
    int32_t row = -1;
    int64_t price_q16 = 0;      // price per need unit (q16 of MONEY_SCALE)
};

// One need class (or equipment category) of one demander.
struct DemandEntry {
    int32_t country = -1;
    int32_t cell = -1;
    int32_t slot = -1;          // demander index
    uint8_t kind = 0;           // MILITARY_LOT_GARRISON / ARMY / TRAINING
    int32_t cls = -1;           // supply class (equipment: -1)
    int32_t category = -1;
    int64_t want = 0;           // need units (equipment: GOODS_SCALE)
    int64_t sourced = 0;
    int32_t reach_begin = 0;
    int32_t reach_end = 0;
    int32_t cursor = 0;         // next reach row to offer
    int32_t markets = 0;        // distinct markets that served it
};

// One delivery of an entry, in the order the markets were offered.
struct Take {
    int32_t entry = -1;
    int32_t row = -1;
    int64_t units = 0;          // need units (equipment: GOODS_SCALE)
};

// One demander of the day.
struct Demander {
    int32_t country = -1;
    int32_t cell = -1;
    uint8_t kind = 0;
    int32_t holder = -1;
    uint8_t in_combat = 0;
    int32_t entry_begin = 0;
    int32_t entry_count = 0;
    int64_t want[MILITARY_MAX_SUPPLY_CLASSES] = {};   // 10-day target, need units
    int64_t held[MILITARY_MAX_SUPPLY_CLASSES] = {};   // need units in stock
    uint64_t equip_covered = 0;                       // equipment categories held
};

struct DemandScratch {
    std::vector<Demander> holders;
    std::vector<DemandEntry> entries;
    std::vector<ReachRow> reach;      // per entry: rows of its rings
    std::vector<Take> takes;
    std::vector<int64_t> row_left;    // per live row: need units for sale
    std::vector<int32_t> open;        // entries still wanted, deterministic order
    void clear() {
        holders.clear();
        entries.clear();
        reach.clear();
        takes.clear();
        row_left.clear();
        open.clear();
    }
};

DemandScratch &demand_scratch() {
    static thread_local DemandScratch s;
    return s;
}

int64_t class_units_of(int64_t goods, int32_t yield_q16) {
    if (goods <= 0) return 0;
    const int32_t y = yield_q16 > 0 ? yield_q16 : MILITARY_Q16;
    return (goods * (int64_t)y) >> 16;
}

int64_t price_per_unit_q16(int64_t goods_price, int32_t yield_q16) {
    const int32_t y = yield_q16 > 0 ? yield_q16 : MILITARY_Q16;
    const int64_t price = goods_price > 0 ? goods_price : 0;
    return (price * MILITARY_Q16 + y - 1) / y;
}

} // namespace

void MilitaryCore::run_procurement(const MilitaryWorldDigest &digest,
                                   std::vector<MilitaryIntent> &out) {
    const int32_t cells = _terrain.cell_count;
    const int32_t capacity = digest.country_capacity;
    if (cells <= 0 || capacity <= 0) return;
    if ((int32_t)_cell_controller.size() < cells) _cell_controller.resize((size_t)cells, -1);
    const int32_t unit_count = (int32_t)_catalog.units.size();
    if (unit_count > MILITARY_MAX_UNIT_TYPES) return;

    // ---- 1. DEMAND --------------------------------------------------------
    DemandScratch &ds = demand_scratch();
    ds.clear();
    const int64_t ration_per_head =
        _catalog.ration_need_per_head_q16 > 0 ? _catalog.ration_need_per_head_q16 : MILITARY_Q16;
    const int32_t category_count = (int32_t)_catalog.categories.size();

    auto scale_of = [&](int32_t slot, int32_t cell) {
        const int32_t landform = terrain_of_cell(_terrain, cell);
        const int64_t terrain_mult = landform_supply_mult_q16(_catalog, landform);
        const int64_t consume_mult = stat_or(digest, slot, MSTAT_SUPPLY_CONSUMPTION);
        return (int32_t)clamp_q16((terrain_mult * consume_mult) >> 16, 1, 8 * MILITARY_Q16);
    };

    auto add_demander = [&](uint8_t kind, int32_t holder, int32_t country, int32_t cell,
                            bool in_combat) {
        if (country < 0 || country >= capacity || cell < 0 || cell >= cells) return;
        // One walk over the holder's lot chain (no per-call chain copy).
        const bool army_kind = kind == (uint8_t)MILITARY_LOT_ARMY;
        const int32_t head = military_lot_head(*this, kind, holder);
        if (head < 0) return;
        bool seen[MILITARY_MAX_UNIT_TYPES] = {};
        int64_t heads[MILITARY_MAX_UNIT_TYPES] = {};
        bool any = false;
        for (int32_t i = head; i >= 0; i = (size_t)i < _lot_next.size() ? _lot_next[(size_t)i] : -1) {
            if (!_lots.active[(size_t)i]) continue;
            if (_lots.location_kind[(size_t)i] != kind) continue;
            if (_lots.location[(size_t)i] != holder) continue;
            const int64_t count = _lots.count[(size_t)i];
            if (count <= 0) continue;
            if (_lots.country_slot[(size_t)i] != country) continue;
            const int32_t unit = _lots.unit_type[(size_t)i];
            if (unit < 0 || unit >= unit_count) continue;
            seen[unit] = true;
            heads[unit] += count;
            any = true;
        }
        (void)army_kind;
        if (!any) return;
        Demander h;
        h.country = country;
        h.cell = cell;
        h.kind = kind;
        h.holder = holder;
        h.in_combat = in_combat ? 1 : 0;
        const int32_t scale = scale_of(country, cell);
        for (int32_t unit = 0; unit < unit_count; ++unit) {
            if (!seen[unit] || heads[unit] <= 0) continue;
            const MilitaryUnitType &type = _catalog.units[(size_t)unit];
            int64_t per_head = ration_per_head;
            if (in_combat) per_head = (per_head * 5) >> 2;
            h.want[MILITARY_SUPPLY_RATION] += mul_q16(mul_q16(heads[unit], (int32_t)per_head), scale);
            for (int32_t cls = MILITARY_SUPPLY_FODDER; cls < MILITARY_MAX_SUPPLY_CLASSES; ++cls) {
                if (cls == STOCK_CLASS_EQUIPMENT) continue;
                int64_t per_100 = type.idle_per_100_day[(size_t)cls];
                if (in_combat) per_100 += type.combat_per_100_day[(size_t)cls];
                if (per_100 <= 0) continue;
                int64_t units = (heads[unit] * per_100) / (100 * MILITARY_GOODS_SCALE);
                if (units <= 0) units = 1;
                h.want[(size_t)cls] += mul_q16(units, scale);
            }
        }
        // Held stock (need units per class, equipment categories covered) through
        // the stock row index, so a holder never scans the whole row table.
        for (int32_t cls = 0; cls < MILITARY_MAX_SUPPLY_CLASSES; ++cls) {
            if (cls == STOCK_CLASS_EQUIPMENT) continue;
            const std::vector<int32_t> &goods = _catalog.supply_goods[(size_t)cls];
            const std::vector<int32_t> &yields = _catalog.supply_yield_q16[(size_t)cls];
            for (size_t g = 0; g < goods.size(); ++g) {
                const int32_t at = military_stock_row(*this, kind, holder, country, goods[g]);
                if (at < 0) continue;
                const int32_t y = g < yields.size() && yields[g] > 0 ? yields[g] : MILITARY_Q16;
                h.held[(size_t)cls] += class_units_of(_stocks[(size_t)at].qty, y);
            }
        }
        for (size_t cat = 0; cat < _catalog.categories.size() && cat < 64; ++cat) {
            if (military_stock_row(*this, kind, holder, country, -1 - (int32_t)cat) >= 0) {
                h.equip_covered |= (1ull << cat);
            }
        }
        bool below = false;
        for (int32_t cls = 0; cls < MILITARY_MAX_SUPPLY_CLASSES; ++cls) {
            if (cls == STOCK_CLASS_EQUIPMENT) continue;
            const int64_t want = h.want[(size_t)cls] * TARGET_DAYS;
            h.want[(size_t)cls] = want;
            if (want <= 0) continue;
            if (h.held[(size_t)cls] * TARGET_DAYS < want * REORDER_DAYS) below = true;
        }
        if (!below) return;
        h.entry_begin = (int32_t)ds.entries.size();
        h.entry_count = 0;
        ds.holders.push_back(h);
    };

    for (int32_t a = 0; a < (int32_t)_armies.active.size(); ++a) {
        if (!_armies.active[(size_t)a]) continue;
        add_demander((uint8_t)MILITARY_LOT_ARMY, a, _armies.owner_slot[(size_t)a],
                     _armies.cell[(size_t)a], _armies.engagement[(size_t)a] >= 0);
    }
    for (size_t c = 0; c < _lot_cell_head.size(); ++c) {
        if (_lot_cell_head[c] < 0) continue;
        const int32_t cell = (int32_t)c;
        int32_t country = -1;
        military_for_each_lot(*this, (uint8_t)MILITARY_LOT_GARRISON, cell, [&](int32_t i) {
            if (_lots.count[(size_t)i] <= 0) return;
            const int32_t slot = _lots.country_slot[(size_t)i];
            if (country < 0 || slot < country) country = slot;
        });
        if (country < 0) continue;
        add_demander((uint8_t)MILITARY_LOT_GARRISON, cell, country, cell, false);
    }
    // Training orders waiting for equipment (design 5.6): one delivery each,
    // sourced from the same 3-cell market ring as the garrison that trains.
    for (size_t t = 0; t < _training.size(); ++t) {
        const MilitaryTrainingOrder &order = _training[t];
        if (order.equipment_ready != 0 || order.count <= 0) continue;
        const int32_t slot = order.country_slot;
        if (slot < 0 || slot >= capacity) continue;
        if (order.cell < 0 || order.cell >= cells) continue;
        if (order.to_unit < 0 || order.to_unit >= unit_count) continue;
        Demander h;
        h.country = slot;
        h.cell = order.cell;
        h.kind = MILITARY_LOT_TRAINING;
        h.holder = (int32_t)t;
        h.in_combat = 0;
        h.entry_begin = (int32_t)ds.entries.size();
        h.entry_count = 0;
        ds.holders.push_back(h);
    }
    if (ds.holders.empty()) return;

    // ---- 2. ENTRIES -------------------------------------------------------
    std::vector<DemandEntry> &entries = ds.entries;
    for (size_t hi = 0; hi < ds.holders.size(); ++hi) {
        Demander &h = ds.holders[hi];
        h.entry_begin = (int32_t)entries.size();
        if (h.kind == MILITARY_LOT_TRAINING) {
            const MilitaryTrainingOrder &order = _training[(size_t)h.holder];
            const MilitaryUnitType &type = _catalog.units[(size_t)order.to_unit];
            for (int32_t si = 0; si < type.slot_count; ++si) {
                const int64_t per_100 = type.slot_qty_per_100[(size_t)si];
                if (per_100 <= 0) continue;
                const int32_t category = type.slot_category[(size_t)si];
                if (category < 0 || category >= category_count) continue;
                const int64_t qty = (order.count * per_100 + 50 * MILITARY_GOODS_SCALE) /
                                    (100 * MILITARY_GOODS_SCALE);
                if (qty <= 0) continue;
                DemandEntry e;
                e.country = h.country;
                e.cell = h.cell;
                e.slot = (int32_t)hi;
                e.kind = MILITARY_LOT_TRAINING;
                e.cls = -1;
                e.category = category;
                e.want = qty;
                entries.push_back(e);
            }
        } else {
            for (int32_t cls = 0; cls < MILITARY_MAX_SUPPLY_CLASSES; ++cls) {
                if (cls == STOCK_CLASS_EQUIPMENT) continue;
                const int64_t missing = h.want[(size_t)cls] - h.held[(size_t)cls];
                if (missing <= 0) continue;
                if (_catalog.supply_goods[(size_t)cls].empty()) continue;
                DemandEntry e;
                e.country = h.country;
                e.cell = h.cell;
                e.slot = (int32_t)hi;
                e.kind = h.kind;
                e.cls = cls;
                e.want = missing;
                entries.push_back(e);
            }
        }
        h.entry_count = (int32_t)entries.size() - h.entry_begin;
    }
    if (entries.empty()) return;

    // ---- 3. WANT + SELL ---------------------------------------------------
    MarketDayScope day(*this);
    day.ensure(digest);
    const size_t live = _md_row_cell.size();
    if (live == 0) return;
    ds.row_left.assign(live, 0);
    for (size_t r = 0; r < live; ++r) ds.row_left[r] = _md_row_sellable[r];
    const int32_t ring_cells = MILITARY_SUPPLY_RING_CELLS;

    for (size_t ei = 0; ei < entries.size(); ++ei) {
        DemandEntry &e = entries[(size_t)ei];
        e.reach_begin = (int32_t)ds.reach.size();
        const int32_t begin = _ring_off[(size_t)e.cell];
        const int32_t end = _ring_off[(size_t)e.cell + 1];
        for (int32_t i = begin; i < end && i < begin + ring_cells; ++i) {
            const int32_t at = _ring_cells[(size_t)i];
            const int32_t first = _md_cell_off[(size_t)at];
            const int32_t last = _md_cell_off[(size_t)at + 1];
            if (first >= last) continue;
            if (!military_owns_cell(*this, digest, at, e.country)) continue;
            for (int32_t k = first; k < last; ++k) {
                const int32_t row = _md_cell_rows[(size_t)k];
                if (row < 0 || (size_t)row >= live) continue;
                int64_t price = 0;
                if (e.cls >= 0) {
                    const int32_t good = _md_row_good[(size_t)row];
                    const int32_t index = class_index_of_good(_catalog, e.cls, good);
                    if (index < 0) continue;
                    const std::vector<int32_t> &yields = _catalog.supply_yield_q16[(size_t)e.cls];
                    const int32_t y = (size_t)index < yields.size() ? yields[(size_t)index] : MILITARY_Q16;
                    price = price_per_unit_q16(_md_row_price[(size_t)row], y);
                } else {
                    if (category_of_good(_catalog, _md_row_good[(size_t)row]) != e.category) continue;
                    price = _md_row_price[(size_t)row];
                }
                ReachRow rr;
                rr.row = row;
                rr.price_q16 = price;
                ds.reach.push_back(rr);
            }
        }
        e.reach_end = (int32_t)ds.reach.size();
        // (price, row) order: the cheapest need unit is served first.
        for (int32_t a = e.reach_begin + 1; a < e.reach_end; ++a) {
            const ReachRow key = ds.reach[(size_t)a];
            int32_t b = a;
            while (b > e.reach_begin) {
                const ReachRow &prev = ds.reach[(size_t)(b - 1)];
                if (prev.price_q16 < key.price_q16 ||
                    (prev.price_q16 == key.price_q16 && prev.row <= key.row)) {
                    break;
                }
                ds.reach[(size_t)b] = prev;
                --b;
            }
            ds.reach[(size_t)b] = key;
        }
    }

    for (size_t ei = 0; ei < entries.size(); ++ei) {
        if (entries[ei].reach_begin < entries[ei].reach_end) ds.open.push_back((int32_t)ei);
    }
    while (!ds.open.empty()) {
        int32_t next_open = 0;
        const int32_t open_count = (int32_t)ds.open.size();
        for (int32_t oi = 0; oi < open_count; ++oi) {
            const int32_t ei = ds.open[(size_t)oi];
            DemandEntry &e = entries[(size_t)ei];
            if (e.sourced >= e.want || e.cursor >= e.reach_end || e.markets >= PROCURE_MARKETS) {
                continue;
            }
            ds.open[(size_t)next_open++] = ei;
            const ReachRow rr = ds.reach[(size_t)e.cursor];
            ++e.cursor;
            int64_t left = ds.row_left[(size_t)rr.row];
            if (left <= 0) continue;
            const int64_t need = e.want - e.sourced;
            int64_t goods = left;
            int64_t units = 0;
            if (e.cls >= 0) {
                const int32_t index = class_index_of_good(_catalog, e.cls, _md_row_good[(size_t)rr.row]);
                const std::vector<int32_t> &yields = _catalog.supply_yield_q16[(size_t)e.cls];
                const int32_t y = index >= 0 && (size_t)index < yields.size() ? yields[(size_t)index]
                                                                              : MILITARY_Q16;
                const int64_t need_goods = (need * MILITARY_Q16 + y - 1) / y;
                if (goods > need_goods) goods = need_goods;
                units = class_units_of(goods, y);
                if (units > need) units = need;
            } else {
                if (goods > need) goods = need;
                units = goods;
            }
            if (units <= 0) continue;
            ds.row_left[(size_t)rr.row] = left - goods;
            e.sourced += units;
            ++e.markets;
            Take take;
            take.entry = ei;
            take.row = rr.row;
            take.units = units;
            ds.takes.push_back(take);
        }
        ds.open.resize((size_t)next_open);
        if (next_open == 0) break;
    }

    // ---- 4. DELIVER -------------------------------------------------------
    // Takes are grouped by entry, and each entry's takes by market cell, so a
    // demander only walks its own deliveries and the order stays deterministic.
    static thread_local std::vector<int32_t> order;
    order.clear();
    for (size_t ti = 0; ti < ds.takes.size(); ++ti) order.push_back((int32_t)ti);
    std::stable_sort(order.begin(), order.end(), [&](int32_t a, int32_t b) {
        const Take &ta = ds.takes[(size_t)a];
        const Take &tb = ds.takes[(size_t)b];
        if (ta.entry != tb.entry) return ta.entry < tb.entry;
        const int32_t ca = _md_row_cell[(size_t)ta.row];
        const int32_t cb = _md_row_cell[(size_t)tb.row];
        if (ca != cb) return ca < cb;
        return ta.row < tb.row;
    });
    // Entry -> its slice of `order`.
    static thread_local std::vector<int32_t> entry_first;
    static thread_local std::vector<int32_t> entry_last;
    entry_first.assign(entries.size() + 1, 0);
    for (size_t k = 0; k < order.size(); ++k) {
        ++entry_first[(size_t)ds.takes[(size_t)order[k]].entry + 1];
    }
    for (size_t i = 1; i < entry_first.size(); ++i) entry_first[i] += entry_first[i - 1];
    entry_last = entry_first;

    uint32_t unmet_holders = 0;
    int64_t unmet_units = 0;
    for (size_t hi = 0; hi < ds.holders.size(); ++hi) {
        const Demander &h = ds.holders[hi];
        bool any_take = false;
        int32_t delivered_markets = 0;
        for (int32_t ei = h.entry_begin; ei < h.entry_begin + h.entry_count; ++ei) {
            for (int32_t k = entry_first[(size_t)ei]; k < entry_first[(size_t)ei + 1]; ++k) {
                const Take &take = ds.takes[(size_t)order[(size_t)k]];
                any_take = true;
                const DemandEntry &e = entries[(size_t)ei];
                const int32_t market_cell = _md_row_cell[(size_t)take.row];
                const int32_t good_slot = _md_row_good[(size_t)take.row];
                // Goods bought and the price paid (need units -> goods at the yield).
                int64_t qty = take.units;
                int64_t good_id = good_slot;
                if (e.cls >= 0) {
                    int32_t index = 0;
                    const std::vector<int32_t> &goods = _catalog.supply_goods[(size_t)e.cls];
                    for (size_t g = 0; g < goods.size(); ++g) {
                        if (market_good_slot(digest, goods[g]) == good_slot) {
                            index = (int32_t)g;
                            good_id = goods[g];
                            break;
                        }
                    }
                    const std::vector<int32_t> &yields = _catalog.supply_yield_q16[(size_t)e.cls];
                    const int32_t y = (size_t)index < yields.size() ? yields[(size_t)index] : MILITARY_Q16;
                    qty = (take.units * MILITARY_Q16 + y - 1) / y;
                    if (qty <= 0) continue;
                } else {
                    good_id = -1 - e.category;
                }
                const int64_t price = _md_row_price[(size_t)take.row];
                const int64_t cost = (price * qty) / MILITARY_GOODS_SCALE;
                MilitaryIntent buy;
                buy.kind = MILITARY_INTENT_PROCURE_GOOD;
                buy.cell = market_cell;
                buy.good = (int32_t)good_id;
                buy.country_a = country_handle_for(digest, h.country);
                buy.count = qty;
                buy.amount = cost;
                buy.source_id = static_cast<uint64_t>(e.kind) << 32 |
                                static_cast<uint32_t>(e.slot < 0 ? 0 : e.slot);
                out.push_back(buy);
                ++_report.intents_emitted;
                ++_report.procure_markets_used;
                ++delivered_markets;
                if (market_cell == h.cell) {
                    // Own-cell purchase arrives the same day, no convoy (sec 9.3).
                    stock_add(e.kind, h.holder, h.country, (int32_t)good_id, qty);
                    _ledger_received += qty;
                    continue;
                }
                MilitaryShipment shipment;
                shipment.id = _next_id++;
                shipment.country_slot = h.country;
                shipment.dest_kind = e.kind;
                shipment.dest = h.holder;
                shipment.dest_handle = e.kind == MILITARY_LOT_ARMY ? army_handle(h.holder)
                                                                  : static_cast<uint64_t>(h.holder);
                shipment.origin_cell = market_cell;
                shipment.current_cell = market_cell;
                shipment.good = (int32_t)good_id;
                shipment.qty = qty;
                shipment.value = cost;
                shipment.departure_day = digest.day;
                // Convoy route = ring distance (design 9.3 / 9.4).
                const int32_t distance = std::max(1, cell_distance(market_cell, h.cell));
                shipment.route_cost_q16 = distance * MILITARY_Q16;
                const int32_t speed_q16 = stat_or(digest, h.country, MSTAT_SUPPLY_TRANSPORT);
                int32_t days = (shipment.route_cost_q16 + speed_q16 - 1) / speed_q16;
                if (days < 1) days = 1;
                shipment.eta_day = digest.day + days;
                _ledger_received += qty;   // A3: in-transit goods were never booked as received
                _shipments.push_back(shipment);
            }
        }
        int64_t missing = 0;
        for (int32_t ei = h.entry_begin; ei < h.entry_begin + h.entry_count; ++ei) {
            missing += entries[(size_t)ei].want - entries[(size_t)ei].sourced;
        }
        if (missing <= 0) continue;
        unmet_units += missing;
        if (!any_take) ++unmet_holders;
        // Per-country unmet demand (report / UI / AI demand signal).
        if (h.country >= 0 && h.country < capacity) {
            if (_unmet_procure_units.size() < (size_t)capacity) {
                _unmet_procure_units.resize((size_t)capacity, 0);
            }
            _unmet_procure_units[(size_t)h.country] += missing;
        }
    }
    _report.unmet_procurement_holders += (int32_t)unmet_holders;
    _report.unmet_procurement_units += unmet_units;
}

// ============================================================ threat fields

void MilitaryCore::build_threat_fields(const MilitaryWorldDigest &digest) {
    const int32_t cells = _terrain.cell_count;
    if (cells <= 0) return;
    if (static_cast<int32_t>(_threat.size()) < cells) {
        _threat.assign(static_cast<size_t>(cells), 0);
        _guard.assign(static_cast<size_t>(cells), 0);
        _threat_stamp.assign(static_cast<size_t>(cells), 0);
    }
    _stamp += 1;
    if (_stamp == 0) {
        std::fill(_threat_stamp.begin(), _threat_stamp.end(), 0);
        _stamp = 1;
    }
    const uint32_t stamp = _stamp;
    const int32_t neighbor_total = static_cast<int32_t>(_terrain.neighbors.size());
    const int32_t *neighbors = _terrain.neighbors.data();
    const int32_t ring_weight = 39322;   // 0.6
    int32_t touched = 0;

    // threat[c] = sum of hostile strength within distance 1; guard[c] = own
    // presence. _threat_owner keeps the strongest adjacent owner so convoys can
    // decide who intercepts (sec 9.5).
    if (static_cast<int32_t>(_threat_owner.size()) < cells) {
        _threat_owner.assign(static_cast<size_t>(cells), 0);
    }
    const size_t army_count = _armies.active.size();
    for (size_t a = 0; a < army_count; ++a) {
        if (_armies.active[a] == 0) continue;
        const int32_t cell = _armies.cell[a];
        if (cell < 0 || cell >= cells) continue;
        const int64_t strength = _armies.cached_attack_q16[a] + _armies.cached_defense_q16[a];
        if (strength <= 0) continue;
        const int32_t slot = _armies.owner_slot[a];
        if (slot < 0 || slot > 65533) continue;
        for (int32_t plane = 0; plane < INTERCEPT_PLANES; ++plane) {
            int32_t at = cell;
            int32_t weight_q16 = MILITARY_Q16;
            if (plane > 0) {
                if (cell * 6 + 5 >= neighbor_total) continue;
                at = neighbors[cell * 6 + (plane - 1)];
                if (at < 0 || at >= cells) continue;
                weight_q16 = ring_weight;
            }
            if (_threat_stamp[static_cast<size_t>(at)] != stamp) {
                _threat_stamp[static_cast<size_t>(at)] = stamp;
                _threat[static_cast<size_t>(at)] = 0;
                _guard[static_cast<size_t>(at)] = 0;
                _threat_owner[static_cast<size_t>(at)] = 0;
                ++touched;
            }
            const int64_t weighted = mul_q16(strength, weight_q16);
            _threat[static_cast<size_t>(at)] += weighted;
            _guard[static_cast<size_t>(at)] += weighted;
            if (weighted > _threat[static_cast<size_t>(at)] / 2) {
                _threat_owner[static_cast<size_t>(at)] = static_cast<uint16_t>(slot + 1);
            }
        }
    }
    _report.threat_field_cells = touched;
    (void)digest;
}

// Destination cell of a shipment (-1 when the destination vanished).
int32_t shipment_dest_cell(const MilitaryCore &core, const MilitaryShipment &shipment) {
    if (shipment.dest_kind == MILITARY_LOT_ARMY) {
        int32_t slot = -1;
        if (core.resolve_army(shipment.dest_handle, slot)) {
            return core._armies.cell[static_cast<size_t>(slot)];
        }
        if (shipment.dest >= 0 &&
            shipment.dest < static_cast<int32_t>(core._armies.active.size()) &&
            core._armies.active[static_cast<size_t>(shipment.dest)] != 0) {
            return core._armies.cell[static_cast<size_t>(shipment.dest)];
        }
        return -1;
    }
    return shipment.dest;
}

// Neighbour of <from> that reduces the hex distance to <target>; ties keep the
// lowest neighbour id so replays are deterministic.
int32_t convoy_step(const MilitaryTerrainInput &terrain, const MilitaryCore &core, int32_t from,
                    int32_t target) {
    const int32_t neighbor_total = static_cast<int32_t>(terrain.neighbors.size());
    if (from < 0 || from * 6 + 5 >= neighbor_total) return -1;
    int32_t best = -1;
    int32_t best_distance = 0;
    for (int32_t dir = 0; dir < 6; ++dir) {
        const int32_t next = terrain.neighbors[from * 6 + dir];
        if (next < 0) continue;
        const int32_t distance = core.cell_distance(next, target);
        if (best < 0 || distance < best_distance ||
            (distance == best_distance && next < best)) {
            best = next;
            best_distance = distance;
        }
    }
    return best;
}

void MilitaryCore::run_convoys(const MilitaryWorldDigest &digest,
                               std::vector<MilitaryIntent> &out) {
    const int32_t cells = _terrain.cell_count;
    if (cells <= 0) return;
    if (static_cast<int32_t>(_cell_controller.size()) < cells) {
        _cell_controller.resize(static_cast<size_t>(cells), -1);
    }
    if (static_cast<int32_t>(_threat.size()) < cells) return;   // threat field not built
    Scratch &s = scratch();
    if (static_cast<int32_t>(s.event_stamp.size()) < digest.country_capacity) {
        s.event_stamp.assign(static_cast<size_t>(digest.country_capacity), 0xffffffffu);
    }
    int32_t intercepted_events = 0;

    const auto deliver = [&](const MilitaryShipment &shipment) {
        const int32_t slot = shipment.country_slot;
        if (shipment.dest_kind == MILITARY_LOT_ARMY) {
            int32_t army = -1;
            if (resolve_army(shipment.dest_handle, army)) {
                stock_add(MILITARY_LOT_ARMY, army, slot, shipment.good, shipment.qty);
                return true;
            }
            _ledger_returned += shipment.qty;   // army gone: refund to treasury
            return false;
        }
        stock_add(0, shipment.dest, slot, shipment.good, shipment.qty);
        if (shipment.dest_kind == 2) {
            for (size_t t = 0; t < _training.size(); ++t) {
                if (_training[t].cell == shipment.dest && _training[t].country_slot == slot) {
                    _training[t].equipment_ready = 1;
                }
            }
        }
        return true;
    };

    size_t write = 0;
    for (size_t i = 0; i < _shipments.size(); ++i) {
        MilitaryShipment shipment = _shipments[i];
        const int32_t slot = shipment.country_slot;
        const int32_t dest_cell = shipment_dest_cell(*this, shipment);
        if (dest_cell < 0) {
            _ledger_returned += shipment.qty;
            continue;
        }
        if (digest.day >= shipment.eta_day || shipment.current_cell == dest_cell) {
            deliver(shipment);
            continue;
        }
        ++_report.convoys_due;
        const int32_t next = convoy_step(_terrain, *this, shipment.current_cell, dest_cell);
        const int32_t dest_controller = controller_of_cell(*this, digest, dest_cell);
        bool blocked = next < 0;
        if (!blocked) {
            const int32_t next_controller = controller_of_cell(*this, digest, next);
            if (dest_controller != slot) {
                blocked = true;   // destination lost: wait for reconnection
            } else if (next != dest_cell && next_controller != slot) {
                blocked = true;
            }
        }
        if (blocked) {
            shipment.blocked_days += 1;
            if (shipment.blocked_days >= BLOCKED_RETURN_DAYS) {
                _ledger_returned += shipment.qty;   // returned to the treasury
                continue;
            }
            _shipments[write++] = shipment;
            continue;
        }
        shipment.blocked_days = 0;
        shipment.current_cell = next;
        shipment.progress_q16 += MILITARY_Q16;
        ++_report.convoy_hops;

        // Interception on the traversed cell (sec 9.5).
        const int64_t threat = _threat[static_cast<size_t>(next)];
        if (threat > 0) {
            const int64_t guard = _guard[static_cast<size_t>(next)];
            const int64_t value_units = std::max<int64_t>(1, shipment.value / MILITARY_MONEY_SCALE);
            const int64_t escort = (static_cast<int64_t>(ESCORT_BASE_Q16) * value_units) >> 16;
            const int64_t denominator = threat + guard + escort;
            int64_t risk_q16 = denominator > 0 ? (threat * INTERCEPT_CAP_Q16) / denominator : 0;
            if (risk_q16 > INTERCEPT_CAP_Q16) risk_q16 = INTERCEPT_CAP_Q16;
            const uint64_t roll = rng(_seed, shipment.id, digest.day) & 0xffffu;
            if (static_cast<int64_t>(roll) < risk_q16) {
                const uint16_t owner_plus = _threat_owner[static_cast<size_t>(next)];
                const int32_t interceptor = owner_plus > 0 ? static_cast<int32_t>(owner_plus) - 1
                                                           : -1;
                if (interceptor >= 0) {
                    // Nearest interceptor army takes custody of the goods.
                    int32_t best_army = -1;
                    int32_t best_distance = 0x7fffffff;
                    for (size_t a = 0; a < _armies.active.size(); ++a) {
                        if (_armies.active[a] == 0) continue;
                        if (_armies.owner_slot[a] != interceptor) continue;
                        const int32_t distance = cell_distance(next, _armies.cell[a]);
                        if (distance < best_distance) {
                            best_distance = distance;
                            best_army = static_cast<int32_t>(a);
                        }
                    }
                    if (best_army >= 0) {
                        stock_add(MILITARY_LOT_ARMY, best_army, interceptor, shipment.good,
                                  shipment.qty);
                        _ledger_intercepted_in += shipment.qty;   // A3: only when custody is taken
                    }
                    _ledger_intercepted_out += shipment.qty;
                    bool emit = intercepted_events < EVENT_CAP_CONVOY;
                    if (interceptor < static_cast<int32_t>(s.event_stamp.size())) {
                        if (s.event_stamp[static_cast<size_t>(interceptor)] ==
                            static_cast<uint32_t>(digest.day)) {
                            emit = false;
                        }
                        s.event_stamp[static_cast<size_t>(interceptor)] =
                            static_cast<uint32_t>(digest.day);
                    }
                    if (emit && best_army >= 0) {
                        MilitaryEvent event;
                        event.day = digest.day;
                        event.type = MILITARY_EVENT_CONVOY_INTERCEPTED;
                        event.payload_schema = 24;
                        event.cell = next;
                        event.i0 = static_cast<uint64_t>(interceptor);
                        event.i1 = static_cast<uint64_t>(slot);
                        event.i2 = shipment.id;
                        event.value = shipment.value;
                        push_event(event);
                        ++intercepted_events;
                    } else {
                        ++_report.event_coalesced;
                    }
                }
                continue;   // goods left our custody
            }
        }
        if (shipment.current_cell == dest_cell) {
            deliver(shipment);
            continue;
        }
        _shipments[write++] = shipment;
    }
    _shipments.resize(write);
    (void)out;
}

// ============================================================== consumption

namespace {

int32_t ema_3day(int32_t previous_q16, int64_t sample_q16) {
    const int64_t sample = std::min<int64_t>(std::max<int64_t>(sample_q16, 0), MILITARY_Q16);
    if (previous_q16 <= 0) return static_cast<int32_t>(sample);
    const int64_t blended =
        (static_cast<int64_t>(previous_q16) * (MILITARY_Q16 - RATION_EMA_WEIGHT_Q16) +
         sample * RATION_EMA_WEIGHT_Q16) >>
        16;
    return static_cast<int32_t>(std::min<int64_t>(std::max<int64_t>(blended, 0), MILITARY_Q16));
}

// One holder's daily use: garrison cell or army slot.
struct HolderUse {
    int32_t country_slot = -1;
    uint8_t holder_kind = 0;
    int32_t holder = -1;
    int32_t cell = -1;
    uint8_t in_combat = 0;
    int64_t heads[MILITARY_MAX_UNIT_TYPES] = {};
    int64_t need[MILITARY_MAX_SUPPLY_CLASSES] = {};     // need units per class
    int64_t satisfied[MILITARY_MAX_SUPPLY_CLASSES] = {}; // need units actually met
};

} // namespace

void MilitaryCore::run_consumption(const MilitaryWorldDigest &digest,
                                   std::vector<MilitaryIntent> &out) {
    const int32_t cells = _terrain.cell_count;
    const int32_t capacity = digest.country_capacity;
    if (cells <= 0 || capacity <= 0) return;
    const int32_t unit_count = std::min<int32_t>(static_cast<int32_t>(_catalog.units.size()),
                                                 MILITARY_MAX_UNIT_TYPES);
    const size_t lot_count = _lots.active.size();

    // --- Group lots into holders (deterministic: first-appearance order).
    static thread_local std::vector<HolderUse> holders;
    static thread_local std::vector<int32_t> holder_bucket;   // +1 packed holder row
    holders.clear();
    // Open-addressed (kind, location, slot) -> holder row. A linear scan here
    // is O(lots x holders), which dominates the stage at 100k cells with two
    // thousand field armies; the table keeps grouping O(lots).
    size_t bucket_count = 64;
    while (bucket_count < lot_count * 2 + 16) bucket_count <<= 1;
    holder_bucket.assign(bucket_count, 0);
    const size_t bucket_mask = bucket_count - 1;
    const auto holder_key = [](uint8_t kind, int32_t location, int32_t slot) {
        uint64_t k = (uint64_t)kind << 56;
        k ^= (uint64_t)(uint32_t)location * 0x9e3779b97f4a7c15ull;
        k ^= (uint64_t)(uint32_t)slot * 0xc2b2ae3d27d4eb4full;
        return mil::splitmix_final(k);
    };
    for (size_t i = 0; i < lot_count; ++i) {
        if (_lots.active[i] == 0) continue;
        const int32_t unit = _lots.unit_type[i];
        if (unit < 0 || unit >= unit_count) continue;
        const int32_t slot = _lots.country_slot[i];
        if (slot < 0 || slot >= capacity) continue;
        const int64_t count = _lots.count[i];
        if (count <= 0) continue;
        const uint8_t kind = _lots.location_kind[i];
        const int32_t location = _lots.location[i];
        int32_t cell = location;
        if (kind == MILITARY_LOT_ARMY) {
            if (location < 0 || location >= static_cast<int32_t>(_armies.active.size())) continue;
            if (_armies.active[static_cast<size_t>(location)] == 0) continue;
            cell = _armies.cell[static_cast<size_t>(location)];
        }
        const uint64_t key = holder_key(kind, location, slot);
        size_t at = (size_t)key & bucket_mask;
        int32_t found = -1;
        for (;;) {
            const int32_t packed = holder_bucket[at];
            if (packed == 0) break;
            const int32_t row = packed - 1;
            if (row >= 0 && (size_t)row < holders.size() &&
                holders[(size_t)row].holder_kind == kind &&
                holders[(size_t)row].holder == location &&
                holders[(size_t)row].country_slot == slot) {
                found = row;
                break;
            }
            at = (at + 1) & bucket_mask;
        }
        if (found < 0) {
            HolderUse use;
            use.country_slot = slot;
            use.holder_kind = kind;
            use.holder = location;
            use.cell = cell;
            use.in_combat = (kind == MILITARY_LOT_ARMY && _armies.engagement[static_cast<size_t>(location)] >= 0)
                                ? 1
                                : 0;
            holders.push_back(use);
            found = static_cast<int32_t>(holders.size()) - 1;
            holder_bucket[at] = found + 1;
        }
        holders[static_cast<size_t>(found)].heads[unit] += count;
    }

    // --- Compute needs per holder.
    for (size_t h = 0; h < holders.size(); ++h) {
        HolderUse &use = holders[h];
        if (use.cell < 0 || use.cell >= cells) continue;
        const int32_t landform = terrain_of_cell(_terrain, use.cell);
        const int64_t terrain_mult = landform_supply_mult_q16(_catalog, landform);
        const int64_t consume_mult = stat_or(digest, use.country_slot, MSTAT_SUPPLY_CONSUMPTION);
        const int32_t scale = static_cast<int32_t>(
            clamp_q16((terrain_mult * consume_mult) >> 16, 1, 8 * MILITARY_Q16));
        const int32_t ration_per_head =
            _catalog.ration_need_per_head_q16 > 0 ? _catalog.ration_need_per_head_q16
                                                  : MILITARY_Q16;
        for (int32_t unit = 0; unit < unit_count; ++unit) {
            const int64_t heads = use.heads[unit];
            if (heads <= 0) continue;
            const MilitaryUnitType &type = _catalog.units[static_cast<size_t>(unit)];
            // Ration: need units, combat day x1.25 (sec 9.2).
            int64_t per_head = ration_per_head;
            if (use.in_combat != 0) per_head = (per_head * 5) >> 2;
            int64_t ration = mul_q16(heads, static_cast<int32_t>(per_head));
            ration = mul_q16(ration, scale);
            use.need[MILITARY_SUPPLY_RATION] += ration;
            for (int32_t cls = MILITARY_SUPPLY_FODDER; cls < MILITARY_MAX_SUPPLY_CLASSES; ++cls) {
                if (cls == STOCK_CLASS_EQUIPMENT) continue;
                int64_t per_100 = type.idle_per_100_day[static_cast<size_t>(cls)];
                if (use.in_combat != 0) {
                    per_100 += type.combat_per_100_day[static_cast<size_t>(cls)];
                }
                if (per_100 <= 0) continue;
                int64_t goods = (heads * per_100) / (100 * MILITARY_GOODS_SCALE);
                if (goods <= 0) goods = 0;
                goods = mul_q16(goods, scale);
                // Same quantity, expressed in need units for the ration ratio.
                use.need[static_cast<size_t>(cls)] += goods * MILITARY_GOODS_SCALE;
            }
        }
    }

    // --- Consume from stock (highest yield first) and emit the treasury
    // consumption intents that keep the sec 9.7 ledger exact.
    for (size_t h = 0; h < holders.size(); ++h) {
        HolderUse &use = holders[h];
        if (use.cell < 0 || use.cell >= cells) continue;
        for (int32_t cls = 0; cls < MILITARY_MAX_SUPPLY_CLASSES; ++cls) {
            if (cls == STOCK_CLASS_EQUIPMENT) continue;
            int64_t want_units = use.need[static_cast<size_t>(cls)];
            if (want_units <= 0) continue;
            const std::vector<int32_t> &goods = _catalog.supply_goods[static_cast<size_t>(cls)];
            const std::vector<int32_t> &yields = _catalog.supply_yield_q16[static_cast<size_t>(cls)];
            // Preference: higher yield per good first (better nutrition).
            size_t order[MILITARY_MAX_SUPPLY_CLASSES * 2] = {};
            size_t order_len = 0;
            for (size_t g = 0; g < goods.size() && order_len < sizeof(order) / sizeof(order[0]);
                 ++g) {
                order[order_len++] = g;
            }
            for (size_t a = 1; a < order_len; ++a) {
                const size_t key = order[a];
                const int32_t key_yield = key < yields.size() ? yields[key] : MILITARY_Q16;
                size_t b = a;
                while (b > 0) {
                    const int32_t prev_yield =
                        order[b - 1] < yields.size() ? yields[order[b - 1]] : MILITARY_Q16;
                    if (prev_yield >= key_yield) break;
                    order[b] = order[b - 1];
                    --b;
                }
                order[b] = key;
            }
            for (size_t k = 0; k < order_len && want_units > 0; ++k) {
                const int32_t good = goods[order[k]];
                const int64_t held = stock_get(use.holder_kind, use.holder, use.country_slot, good);
                if (held <= 0) continue;
                const int32_t y = order[k] < yields.size() ? yields[order[k]] : MILITARY_Q16;
                const int64_t unit_yield = y > 0 ? y : MILITARY_Q16;
                int64_t goods_needed = (want_units * MILITARY_Q16 + unit_yield - 1) / unit_yield;
                if (goods_needed <= 0) goods_needed = 1;
                const int64_t take = std::min(held, goods_needed);
                if (take <= 0) continue;
                stock_add(use.holder_kind, use.holder, use.country_slot, good, -take);
                const int64_t met = mul_q16(take, static_cast<int32_t>(unit_yield));
                use.satisfied[static_cast<size_t>(cls)] += std::min(met, want_units);
                want_units -= std::min(met, want_units);
                _ledger_consumed += take;
                MilitaryIntent consume;
                consume.kind = MILITARY_INTENT_CONSUME_TREASURY_GOOD;
                consume.cell = use.cell;
                consume.good = good;
                consume.country_a = country_handle_for(digest, use.country_slot);
                consume.count = take;
                consume.source_id = (static_cast<uint64_t>(use.holder_kind) << 32) |
                                    static_cast<uint32_t>(use.holder);
                out.push_back(consume);
                ++_report.intents_emitted;
            }
        }
        // --- Ration ratio EMA on the army (sec 10 morale input).
        if (use.holder_kind == MILITARY_LOT_ARMY) {
            const int32_t army = use.holder;
            if (army < 0 || army >= static_cast<int32_t>(_armies.active.size())) continue;
            if (_armies.active[static_cast<size_t>(army)] == 0) continue;
            const int64_t need = use.need[MILITARY_SUPPLY_RATION];
            const int64_t sample_q16 = need > 0
                                           ? (use.satisfied[MILITARY_SUPPLY_RATION] * MILITARY_Q16) / need
                                           : MILITARY_Q16;
            _armies.ration_ratio_q16[static_cast<size_t>(army)] =
                ema_3day(_armies.ration_ratio_q16[static_cast<size_t>(army)], sample_q16);
            int64_t need_total = 0;
            int64_t met_total = 0;
            for (int32_t cls = 0; cls < MILITARY_MAX_SUPPLY_CLASSES; ++cls) {
                if (cls == STOCK_CLASS_EQUIPMENT) continue;
                need_total += use.need[static_cast<size_t>(cls)];
                met_total += use.satisfied[static_cast<size_t>(cls)];
            }
            const int64_t supply_q16 =
                need_total > 0 ? (met_total * MILITARY_Q16) / need_total : MILITARY_Q16;
            _armies.supply_ratio_q16[static_cast<size_t>(army)] =
                ema_3day(_armies.supply_ratio_q16[static_cast<size_t>(army)], supply_q16);
        }
    }

    // --- Equipment condition decay / recovery (sec 4.2).
    // Condition falls 0.5%/day when maintenance stock is short and recovers
    // 1%/day otherwise; floor 50%.
    for (size_t i = 0; i < lot_count; ++i) {
        if (_lots.active[i] == 0) continue;
        if (_lots.count[i] <= 0) continue;
        const int32_t slot = _lots.country_slot[i];
        int64_t need_total = 0;
        int64_t met_total = 0;
        for (size_t h = 0; h < holders.size(); ++h) {
            if (holders[h].country_slot != slot) continue;
            if (holders[h].holder_kind != _lots.location_kind[i]) continue;
            if (holders[h].holder != _lots.location[i]) continue;
            for (int32_t cls = 0; cls < MILITARY_MAX_SUPPLY_CLASSES; ++cls) {
                if (cls == STOCK_CLASS_EQUIPMENT) continue;
                need_total += holders[h].need[static_cast<size_t>(cls)];
                met_total += holders[h].satisfied[static_cast<size_t>(cls)];
            }
            break;
        }
        const bool maintained = need_total <= 0 || met_total * 2 >= need_total;
        int32_t condition = _lots.condition_q16[i];
        if (condition <= 0) condition = MILITARY_Q16;
        condition += maintained ? CONDITION_RECOVER_Q16 : -CONDITION_DECAY_Q16;
        if (condition < CONDITION_FLOOR_Q16) condition = CONDITION_FLOOR_Q16;
        if (condition > MILITARY_Q16) condition = MILITARY_Q16;
        _lots.condition_q16[i] = condition;
    }
}

// ============================================================= requisition

void MilitaryCore::run_requisition(const MilitaryWorldDigest &digest,
                                   std::vector<MilitaryIntent> &out) {
    const int32_t cells = _terrain.cell_count;
    if (cells <= 0) return;
    if (static_cast<int32_t>(_cell_controller.size()) < cells) {
        _cell_controller.resize(static_cast<size_t>(cells), -1);
    }
    // Requisition is available to armies that lost their supply connection and
    // sit on an occupied (foreign-owned) cell (sec 9.7). Disconnection is the
    // design 9.3 test: no market cell of the same country inside the ring. The
    // probe needs the market rows, so the day scope is built here; the ring is
    // precomputed once per topology.
    MarketDayScope day(*this);
    const int32_t unit_count = static_cast<int32_t>(_catalog.units.size());
    for (size_t a = 0; a < _armies.active.size(); ++a) {
        if (_armies.active[a] == 0) continue;
        const int32_t slot = _armies.owner_slot[a];
        if (slot < 0) continue;
        const int32_t cell = _armies.cell[a];
        if (cell < 0 || cell >= cells) continue;
        // Occupied cell only: controller is us, owner is someone else.
        int64_t owner = -1;
        if (cell < static_cast<int32_t>(digest.cell_owner_slot.size())) {
            owner = digest.cell_owner_slot[static_cast<size_t>(cell)];
        }
        if (owner < 0 || owner == slot) continue;
        const int32_t controller = controller_of_cell(*this, digest, cell);
        if (controller != slot) continue;
        day.ensure(digest);
        if (military_supply_connected(*this, digest, slot, cell)) continue;

        // Daily demand of the army, per unit type, from the lot index.
        int64_t unit_heads[MILITARY_MAX_UNIT_TYPES] = {};
        bool any = false;
        military_for_each_lot(*this, (uint8_t)MILITARY_LOT_ARMY, static_cast<int32_t>(a),
                              [&](int32_t i) {
                                  if (_lots.count[(size_t)i] <= 0) return;
                                  const int32_t unit = _lots.unit_type[(size_t)i];
                                  if (unit < 0 || unit >= unit_count) return;
                                  unit_heads[unit] += _lots.count[(size_t)i];
                                  any = true;
                              });
        if (!any) continue;
        const int32_t landform = terrain_of_cell(_terrain, cell);
        const int64_t terrain_mult = landform_supply_mult_q16(_catalog, landform);
        const int32_t scale = static_cast<int32_t>(clamp_q16(terrain_mult, 1, 8 * MILITARY_Q16));
        const bool combat = _armies.engagement[a] >= 0;
        bool emitted = false;
        for (int32_t unit = 0; unit < unit_count; ++unit) {
            if (unit_heads[unit] <= 0) continue;
            const MilitaryUnitType &type = _catalog.units[static_cast<size_t>(unit)];
            for (int32_t cls = 0; cls < MILITARY_MAX_SUPPLY_CLASSES; ++cls) {
                if (cls == STOCK_CLASS_EQUIPMENT) continue;
                int64_t per_100 = type.idle_per_100_day[static_cast<size_t>(cls)];
                if (combat) per_100 += type.combat_per_100_day[static_cast<size_t>(cls)];
                if (per_100 <= 0) continue;
                int64_t demand = (unit_heads[unit] * per_100) / (100 * MILITARY_GOODS_SCALE);
                if (demand <= 0) demand = 1;
                demand = mul_q16(demand, scale);
                int64_t remaining = demand;
                const std::vector<int32_t> &goods = _catalog.supply_goods[static_cast<size_t>(cls)];
                for (size_t g = 0; g < goods.size() && remaining > 0; ++g) {
                    // The market of the occupied cell itself (no scan).
                    const int32_t slot_good = market_good_slot(digest, goods[g]);
                    if (slot_good < 0) continue;
                    for (int32_t k = _md_cell_off[(size_t)cell]; k < _md_cell_off[(size_t)cell + 1]; ++k) {
                        const int32_t row = _md_cell_rows[(size_t)k];
                        if (_md_row_good[(size_t)row] != slot_good) continue;
                        const int64_t stock = _md_row_sellable[(size_t)row];
                        if (stock <= 0) break;
                        const int64_t cap = (stock * REQUISITION_STOCK_BP) / 10000;
                        const int64_t qty = std::min(cap, remaining);
                        if (qty <= 0) break;
                        MilitaryIntent req;
                        req.kind = MILITARY_INTENT_REQUISITION;
                        req.cell = cell;
                        req.good = goods[g];
                        req.country_a = country_handle_for(digest, slot);
                        req.count = qty;
                        req.amount = 0;
                        req.source_id = army_handle(static_cast<int32_t>(a));
                        out.push_back(req);
                        ++_report.intents_emitted;
                        remaining -= qty;
                        emitted = true;
                        break;
                    }
                }
            }
        }
        if (!emitted) continue;
        // Requisition penalty on the cell (sec 9.7): 30-day consumption penalty.
        MilitaryCellState *state = cell_state(cell, true);
        if (state != nullptr) {
            state->requisition_until_day = digest.day + REQUISITION_PENALTY_DAYS;
        }
    }
}

// ================================================================== ledger

int64_t MilitaryCore::ledger_stock_total() const {
    int64_t total = 0;
    for (size_t i = 0; i < _stocks.size(); ++i) {
        if (_stocks[i].qty > 0) total += _stocks[i].qty;
    }
    return total;
}

int64_t MilitaryCore::ledger_transit_total() const {
    int64_t total = 0;
    for (size_t i = 0; i < _shipments.size(); ++i) {
        if (_shipments[i].qty > 0) total += _shipments[i].qty;
    }
    return total;
}


// Daily sec 9.7 check. reconcile_delta is the residual of
//   received ? stock + transit + consumed + intercepted_out - intercepted_in + returned
// and must stay 0: every term is written by the stage that moves goods, so a
// non-zero residual means a path moved a quantity without booking it.
void MilitaryCore::reconcile_ledger() {
    _ledger_stock = ledger_stock_total();
    _ledger_transit = ledger_transit_total();
    const int64_t right = _ledger_stock + _ledger_transit + _ledger_consumed +
                          _ledger_intercepted_out - _ledger_intercepted_in + _ledger_returned;
    _report.reconcile_delta = _ledger_received - right;
}
} // namespace pk
