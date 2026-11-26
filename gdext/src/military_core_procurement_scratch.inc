// Procurement demand lanes, scratch storage and unit conversion helpers.

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
constexpr int32_t PROCURE_MARKETS = 4;
// A market row an entry can reach.
struct ReachRow {
    int32_t row = -1;
    int64_t price_q16 = 0;      // price per need unit (q16 of MONEY_SCALE)
    uint8_t quality_priority = 0; // secondary below-minimum quality sorts last
};
// One need class (or equipment category) of one demander.
struct DemandEntry {
    int32_t country = -1;
    int32_t cell = -1;
    int32_t slot = -1;          // demander index
    uint8_t kind = 0;           // MILITARY_LOT_GARRISON / ARMY / TRAINING
    int32_t cls = -1;           // supply class (equipment: -1)
    int32_t category = -1;
    int32_t min_quality = 0;
    uint8_t core = 0;
    int64_t want = 0;           // need units (equipment: GOODS_SCALE)
    int64_t sourced = 0;
    int64_t in_flight = 0;
    int32_t reach_begin = 0;
    int32_t reach_end = 0;
    int32_t cursor = 0;         // next reach row to offer
    int32_t markets = 0;        // distinct markets that served it
    // Set when this entry was cut short by its country's procurement quota
    // (任务 8). Deliberately a flag rather than a running total: the shortfall is
    // read off `want - sourced` once the selling pass is over, so a partial buy
    // followed by a second truncation cannot be counted twice.
    uint8_t quota_hit = 0;
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
    // Per country: procurement money still spendable this pass. -1 = no
    // envelope (buy the whole gap, the legacy behaviour). Only the procurement
    // channel is metered this way - 军饷 and 维护 are high priority and settle
    // against cash, not against a quota.
    std::vector<int64_t> quota_left;
    std::vector<int64_t> cash_left;
    using FlightKey = MilitaryFlightSums::Key;
    std::vector<std::pair<FlightKey, int64_t>> in_flight;
    MilitaryFlightSums flight_sums;
    bool flight_sums_ready = false;
    std::vector<std::pair<uint64_t, int32_t>> training_in_flight;
    void clear() {
        holders.clear();
        entries.clear();
        reach.clear();
        takes.clear();
        row_left.clear();
        open.clear();
        quota_left.clear();
        cash_left.clear();
        in_flight.clear();
        flight_sums.clear();
        flight_sums_ready = false;
        training_in_flight.clear();
    }
};
DemandScratch &demand_scratch() {
    static thread_local DemandScratch s;
    return s;
}

bool equipment_candidate_allowed(const MilitaryCatalog &catalog,
                                 const DemandEntry &entry, int32_t good) {
    if (entry.cls >= 0) return true;
    const int32_t quality = equip_good_quality(catalog, good);
    return equipment_quality_allowed(entry.core != 0, entry.min_quality, quality);
}

uint8_t equipment_quality_priority(const MilitaryCatalog &catalog,
                                   const DemandEntry &entry, int32_t good) {
    if (entry.cls >= 0) return 0;
    return equip_good_quality(catalog, good) < entry.min_quality ? 1 : 0;
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
