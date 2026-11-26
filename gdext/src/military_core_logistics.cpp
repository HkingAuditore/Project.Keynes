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
#include "military_core_flight_sums.h"

#include <algorithm>
#include <chrono>
#include <climits>
#include <utility>
#include <tuple>

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

// v3: fold one delivered equipment batch into its training order. Orders are
// matched by their stable id (the vector index compacts when orders finish),
// and only become ready once EVERY equipment category of the target unit has
// actually arrived. The weakest delivered tier sets the lot's final quality.
void note_training_delivery(std::vector<MilitaryTrainingOrder> &orders,
        const MilitaryCatalog &catalog, uint64_t order_id,
        int32_t category, int32_t quality) {
    if (order_id == 0) return;
    for (MilitaryTrainingOrder &o : orders) {
        if (o.id != order_id) continue;
        if (category >= 0 && category < 64)
            o.equipped_slot_mask |= (uint64_t{1} << category);
        const int32_t q8 = clamp32(quality, 1, 5) * 256;
        if (o.delivered_quality_q8 <= 0 || q8 < o.delivered_quality_q8)
            o.delivered_quality_q8 = static_cast<int16_t>(q8);
        if (o.to_unit >= 0 && o.to_unit < static_cast<int32_t>(catalog.units.size())) {
            const MilitaryUnitType &unit = catalog.units[(size_t)o.to_unit];
            for (int32_t s = 0; s < unit.slot_count && s < MILITARY_MAX_EQUIP_SLOTS; ++s) {
                if (unit.slot_category[(size_t)s] != category) continue;
                const int8_t delivered = static_cast<int8_t>(clamp32(quality, 1, 5));
                if (o.slot_delivered_quality[(size_t)s] <= 0 ||
                    delivered < o.slot_delivered_quality[(size_t)s]) {
                    o.slot_delivered_quality[(size_t)s] = delivered;
                }
                break;
            }
            const uint64_t needed = equipment_slot_mask(unit);
            o.equipment_ready = (o.equipped_slot_mask & needed) == needed ? 1 : 0;
        }
        return;
    }
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
    int64_t cleared = 0;
    for (size_t i = 0; i < _stocks.size(); ++i) {
        if (_stocks[i].holder_kind == holder_kind && _stocks[i].holder == holder) {
            if (_stocks[i].qty > 0) cleared += _stocks[i].qty;
            continue;
        }
        if (write != i) _stocks[write] = _stocks[i];
        ++write;
    }
    if (write != _stocks.size()) {
        _stocks.resize(write);
        _stock_index_ok = false;
    }
    // Goods that leave custody without being consumed (an annihilated formation,
    // a disbanded garrison, a dropped training order) are a ledger term, not a
    // silent disappearance: the identity
    //   received = stock + transit + consumed + intercepted_out - intercepted_in + returned
    // only balances if the cleared quantity lands in `returned`. Without this a
    // long AI soak drifts positive by exactly what the destroyed armies carried
    // (measured 1941 goods over 1500 days before the fix).
    if (cleared > 0) _ledger_returned += cleared;
}

// ========================================================= supply indexes
// Design 9.3 (user decision): a demander (garrison cell, army cell, training
// order) may only buy from markets in cells it OWNS and CONTROLS within hex
// distance <= MILITARY_SUPPLY_RADIUS. General procurement retains its first-19
// BFS-entry limit; maintenance and supply probes use the whole row. Market rows
// are bucketed once per day (O(rows)); each requested center is built once per
// topology, after the first logistics request has prepared the index.

namespace {
// Market-good slot of a digest good id: the frozen digest carries one dense
// good id per economy good, so the good id itself is the slot (ids below 128).
int32_t market_good_slot(const MilitaryWorldDigest &digest, int32_t good) {
    (void)digest;
    return good >= 0 ? good : -1;
}
// One pass over the committed market rows: per-cell CSR (rows in (cell, row)
// order), the day quota (50% of the sellable stock, design 9.3) and the
// per-cell merchant flag used by the connectivity probes.
void build_market_csr(MilitaryCore &core, const MilitaryWorldDigest &digest) {
    const int32_t cells = core._terrain.cell_count;
    const size_t n = (size_t)std::max(0, cells);
    ++core._report.market_index_builds;
    core._report.market_index_cells += (int64_t)n;
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
    military_market_reuse_cancel(core);
    market_csr_drop(core);
    core._connected_valid = false;
    core._connected_day = -1;
    core._connected_revision = -1;
    core._conn_group.clear();
    core._conn_group_slot.clear();
    core._conn_mark_cells.clear();
    core._cache_rows.clear();
}
MilitaryMarketDayReuse::MilitaryMarketDayReuse(MilitaryCore &c, const MilitaryWorldDigest &d)
    : core(c), digest(d), cells(c._terrain.cell_count) {
    core._market_day_reuse = this;
}
MilitaryMarketDayReuse::~MilitaryMarketDayReuse() {
    // Return the large column capacities to the original scratch before this
    // stack context dies. No cached values or borrowed input outlive step_day.
    if (parked) exchange_columns();
    market_csr_drop(core);
    core._market_day_reuse = nullptr;
}
void MilitaryMarketDayReuse::exchange_columns() {
    cell_off.swap(core._md_cell_off);
    cell_rows.swap(core._md_cell_rows);
    row_cell.swap(core._md_row_cell);
    row_good.swap(core._md_row_good);
    row_sellable.swap(core._md_row_sellable);
    row_price.swap(core._md_row_price);
    cell_has_merchant.swap(core._md_cell_has_merchant);
}
void MilitaryMarketDayReuse::invalidate() {
    allowed = parked = active_rows = false;
    cell_off.clear(); cell_rows.clear(); row_cell.clear(); row_good.clear();
    row_sellable.clear(); row_price.clear(); cell_has_merchant.clear();
    initial_sellable.clear();
}
void military_market_reuse_cancel(MilitaryCore &core) {
    if (core._market_day_reuse != nullptr) core._market_day_reuse->invalidate();
}
MilitaryCore::MarketDayScope::MarketDayScope(MilitaryCore &c) : core(c) {}
MilitaryCore::MarketDayScope::~MarketDayScope() {
    // The indexes are per day (design 9.3: built once, dropped for the rest of
    // the day), so a day without a demander and without a disconnection probe
    // pays nothing at all.
    MilitaryMarketDayReuse *reuse = core._market_day_reuse;
    if (reuse != nullptr && reuse->allowed && reuse->active_rows &&
        reuse->cells == core._terrain.cell_count && market_csr_current(core, reuse->digest)) {
        reuse->exchange_columns();
        reuse->parked = true;
        reuse->active_rows = false;
    }
    market_csr_drop(core);
}
void MilitaryCore::MarketDayScope::ensure(const MilitaryWorldDigest &digest) {
    military_prepare_supply_rings(core);
    if (market_csr_current(core, digest)) return;
    market_csr_drop(core);
    MilitaryMarketDayReuse *reuse = core._market_day_reuse;
    const bool same_input = reuse != nullptr && reuse->allowed &&
        &digest == &reuse->digest && reuse->cells == core._terrain.cell_count;
    if (same_input && reuse->parked) {
        reuse->exchange_columns();
        reuse->parked = false;
        // Maintenance writes sellable. The former separate scopes each rebuilt
        // the original quota, so sharing that mutation would change purchases.
        core._md_row_sellable = reuse->initial_sellable;
        ++core._report.market_index_reuses;
    } else {
        build_market_csr(core, digest);
        if (same_input) reuse->initial_sellable = core._md_row_sellable;
    }
    if (reuse != nullptr) reuse->active_rows = same_input;
    core._md_day = digest.day;
    core._connected_valid = false;   // the connectivity marks follow the rows
}
void MilitaryCore::MarketDayScope::drop() {
    military_market_reuse_cancel(core);
    market_csr_drop(core);
}
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
// global BFS is needed; an unseen center builds only its own cached row.
bool military_supply_connected(const MilitaryCore &core, const MilitaryWorldDigest &digest, int32_t slot,
                               int32_t cell) {
    if (slot < 0 || cell < 0 || cell >= core._terrain.cell_count) return false;
    if (!military_supply_rings_ready(core)) return false;
    const bool have_rows = market_csr_current(core, digest);
    int32_t begin = 0, end = 0;
    if (!military_supply_ring(const_cast<MilitaryCore &>(core), cell, begin, end)) return false;
    for (int32_t i = begin; i < end; ++i) {
        const int32_t at = core._ring_cells[(size_t)i];
        if (have_rows && core._md_cell_off[(size_t)at + 1] <= core._md_cell_off[(size_t)at]) continue;
        if (!military_owns_cell(core, digest, at, slot)) continue;
        return true;
    }
    return false;
}
#include "military_core_procurement.inc"
#include "military_core_maintenance.inc"
// ============================================================ threat fields
#include "military_core_logistics_section_convoys.inc"
// ============================================================== consumption
#include "military_core_logistics_section_consumption.inc"
// ============================================================= requisition
#include "military_core_logistics_section_requisition.inc"
} // namespace pk
