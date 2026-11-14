// Private implementation of military_core_logistics.cpp; included once inside namespace pk.
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
    using FlightKey = std::tuple<int32_t, uint8_t, int32_t, int32_t>;
    std::vector<std::pair<FlightKey, int64_t>> in_flight;
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
        training_in_flight.clear();
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
    MilitaryIntent reset;
    reset.kind = MILITARY_INTENT_PROCUREMENT_DEMAND;
    reset.cell = -1;
    if (!_lots.active.empty() || !_training.empty()) out.push_back(reset);
    // The maintenance channel's unfunded gap (design S4-4) rides the same
    // forecast lane. It is appended after the reset row above so the reset cannot
    // wipe it, and it carries no custody or cash - it is a signal, never a sale.
    for (const MilitaryIntent &maint_signal : _maint_forecast) out.push_back(maint_signal);
    const int32_t cells = _terrain.cell_count;
    const int32_t capacity = digest.country_capacity;
    if (cells <= 0 || capacity <= 0) return;
    if ((int32_t)_cell_controller.size() < cells) _cell_controller.resize((size_t)cells, -1);
    const int32_t unit_count = (int32_t)_catalog.units.size();
    if (unit_count > MILITARY_MAX_UNIT_TYPES) return;
    // ---- 0. QUOTA (任务 8 / 需求 5.4, 7.1) --------------------------------
    // 采购量 = min(缺口, 预算配额). The quota is money, taken from the same
    // envelope split that pays wages and upkeep, so all three channels read one
    // arithmetic and cannot disagree about what the day's cash is.
    //
    // Procurement is a LOW-priority channel (需求 7.2): unlike 军饷 it never
    // overspends, it just stops. `-1` marks "no envelope" and leaves the legacy
    // full-gap purchase untouched, which is what every foreign AI country runs.
    //
    // Both outcome fields are reset here, before any early return, so a day with
    // no demanders or no markets reports zero instead of last pass's numbers.
    for (size_t slot = 0; slot < _policies.size(); ++slot) {
        _policies[slot].procurement_budget_used = 0;
        _policies[slot].procurement_deferred_units = 0;
    }
    DemandScratch &ds = demand_scratch();
    ds.clear();
    ds.quota_left.assign((size_t)capacity, -1);
    ds.cash_left.assign((size_t)capacity, 0);
    for (int32_t country = 0; country < capacity; ++country) {
        if ((size_t)country >= digest.country_cash.size()) continue;
        int64_t cash = std::max<int64_t>(0, digest.country_cash[(size_t)country]);
        // Payroll was planned first (design S4-1); this pass may only promise
        // what is left of the same frozen snapshot.
        if ((size_t)country < _policies.size()) {
            const MilitaryCountryPolicy &policy = _policies[(size_t)country];
            cash = std::max<int64_t>(0, cash - policy.wage_planned_today -
                                            policy.maintenance_planned_today);
        }
        ds.cash_left[(size_t)country] = cash;
    }
    for (const auto &purchase : _purchase_orders) {
        const int32_t country = ensure_country_slot(purchase.intent.country_a);
        for (int32_t cls = 0; cls < MILITARY_MAX_SUPPLY_CLASSES; ++cls) {
            if (cls == STOCK_CLASS_EQUIPMENT) continue;
            const int32_t index = class_index_of_good(_catalog, cls, purchase.intent.good);
            if (index >= 0) ds.in_flight.push_back({{country, purchase.dest_kind, purchase.dest, cls},
                class_units_of(purchase.intent.count, _catalog.supply_yield_q16[cls][index])});
        }
        if (purchase.dest_kind == MILITARY_LOT_TRAINING)
            ds.training_in_flight.emplace_back(purchase.dest_handle, purchase.stock_good);
    }
    for (const MilitaryShipment &shipment : _shipments) {
        if (shipment.qty <= 0) continue;
        if (shipment.dest_kind == MILITARY_LOT_TRAINING) {
            ds.training_in_flight.emplace_back(shipment.dest_handle, -1 - shipment.good);
            continue;
        }
        if (shipment.dest_kind == MILITARY_LOT_ARMY &&
            army_handle(shipment.dest) != shipment.dest_handle) continue;
        for (int32_t cls = 0; cls < MILITARY_MAX_SUPPLY_CLASSES; ++cls) {
            if (cls == STOCK_CLASS_EQUIPMENT) continue;
            const int32_t index = class_index_of_good(_catalog, cls, shipment.good);
            if (index < 0) continue;
            const auto &yields = _catalog.supply_yield_q16[(size_t)cls];
            ds.in_flight.push_back({{shipment.country_slot, shipment.dest_kind, shipment.dest, cls},
                class_units_of(shipment.qty, (size_t)index < yields.size()
                    ? yields[(size_t)index] : MILITARY_Q16)});
        }
    }
    std::sort(ds.in_flight.begin(), ds.in_flight.end());
    std::sort(ds.training_in_flight.begin(), ds.training_in_flight.end());
    for (size_t slot = 0; slot < _policies.size() && (int32_t)slot < capacity; ++slot) {
        if (_policies[slot].budget_share_bp <= 0) continue;
        const int64_t cash = (size_t)slot < digest.country_cash.size()
                                 ? digest.country_cash[slot] : 0;
        const MilitaryBudgetSplit split = budget_split((int32_t)slot, cash);
        if (!split.enabled) continue;
        ds.quota_left[slot] = std::max<int64_t>(0, split.procurement_ceiling);
    }
    // ---- 1. DEMAND --------------------------------------------------------
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
                e.min_quality = type.slot_min_quality[(size_t)si];
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
                const DemandScratch::FlightKey key{h.country, h.kind, h.holder, cls};
                auto cargo = std::lower_bound(ds.in_flight.begin(), ds.in_flight.end(), key,
                    [](const auto &row, const auto &value) { return row.first < value; });
                while (cargo != ds.in_flight.end() && cargo->first == key) {
                    e.in_flight += cargo->second;
                    ++cargo;
                }
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
            // Quota exhausted for this country: drop the entry from the round
            // robin outright (it is not re-queued below) instead of walking the
            // rest of its reach rows only to be refused at every one. The flag
            // survives so the shortfall is still reported as 待购.
            if (e.country >= 0 && (size_t)e.country < ds.quota_left.size() &&
                ds.quota_left[(size_t)e.country] == 0) {
                e.quota_hit = 1;
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
            // ---- quota gate (任务 8 / 需求 5.4, 7.2) ----------------------
            // 采购量 = min(缺口, 预算配额). Procurement is a LOW-priority channel
            // (需求 7.2): it never overspends, it just stops, and the gap it
            // leaves is reported as 待购 rather than as arrears.
            //
            // The cost is computed exactly as the DELIVER pass will charge it -
            // need units -> goods at the row's yield, then price x goods /
            // GOODS_SCALE - instead of using a per-unit approximation. That
            // matters here and nowhere else: a rounded-down unit price would let
            // a full quota buy one good more than it can pay for, and a budget
            // that can be exceeded by rounding is not a budget.
            {
                const int32_t raw_price = _md_row_price[(size_t)rr.row];
                int32_t yield_q16 = MILITARY_Q16;
                if (e.cls >= 0) {
                    const int32_t index = class_index_of_good(_catalog, e.cls,
                                                              _md_row_good[(size_t)rr.row]);
                    const std::vector<int32_t> &yields = _catalog.supply_yield_q16[(size_t)e.cls];
                    if (index >= 0 && (size_t)index < yields.size() && yields[(size_t)index] > 0) {
                        yield_q16 = yields[(size_t)index];
                    }
                }
                auto goods_of = [&](int64_t count) {
                    return e.cls >= 0 ? (count * MILITARY_Q16 + yield_q16 - 1) / yield_q16
                                      : count;
                };
                auto cost_of = [&](int64_t count) {
                    return (raw_price * goods_of(count)) / MILITARY_GOODS_SCALE;
                };
                // Shared cash pool (design S4-1). Payroll is planned first and the
                // maintenance channel takes its share next, so a purchase may only
                // promise what is still left of the treasury - independent of how
                // big this channel's own quota is. Applying it BEFORE the quota
                // makes the stricter of the two win, which is what "one cash pool"
                // has to mean.
                if (e.country >= 0 && (size_t)e.country < ds.cash_left.size()) {
                    const int64_t cash = ds.cash_left[(size_t)e.country];
                    if (cost_of(units) > cash) {
                        const int64_t unit_cost = std::max<int64_t>(1,
                            (raw_price + MILITARY_GOODS_SCALE - 1) / MILITARY_GOODS_SCALE);
                        int64_t fit = std::min(units, cash / unit_cost);
                        while (fit > 0 && cost_of(fit) > cash) --fit;
                        units = fit;
                        if (units <= 0) continue;
                        goods = goods_of(units);
                        if (goods > left) goods = left;
                    }
                }
                if (e.country >= 0 && (size_t)e.country < ds.quota_left.size() &&
                    ds.quota_left[(size_t)e.country] >= 0) {
                    const int64_t quota = ds.quota_left[(size_t)e.country];
                    if (cost_of(units) > quota) {
                        // Start from the per-unit ceiling estimate (always an upper
                        // bound) and walk down until the exact charge fits. The walk
                        // is one or two steps: the estimate is off by at most a good,
                        // never by a whole unit of demand.
                        const int64_t unit_cost =
                            std::max<int64_t>(1, (raw_price + MILITARY_GOODS_SCALE - 1) /
                                                    MILITARY_GOODS_SCALE);
                        int64_t fit = std::min(units, quota / unit_cost);
                        while (fit > 0 && cost_of(fit) > quota) --fit;
                        // Flagged so the shortfall is counted as 待购 rather than as
                        // "no market in range"; the two mean different things to the
                        // panel and only this one recovers when the quota does.
                        e.quota_hit = 1;
                        units = fit;
                        if (units <= 0) continue;
                        goods = goods_of(units);
                        if (goods > left) goods = left;
                    }
                    ds.quota_left[(size_t)e.country] = quota - cost_of(units);
                }
            }
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
                int32_t real_good = -1;
                int32_t delivered_quality = 0;
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
                    // v3: keep the good actually bought and its quality tier.
                    // The pseudo id above is private military stock identity.
                    real_good = good_slot;
                    delivered_quality = equip_good_quality(_catalog, real_good);
                }
                const int64_t price = _md_row_price[(size_t)take.row];
                const int64_t cost = (price * qty) / MILITARY_GOODS_SCALE;
                ds.cash_left[(size_t)h.country] = std::max<int64_t>(0,
                    ds.cash_left[(size_t)h.country] - cost);
                // 任务 8: how much of the channel QUOTA this pass consumed. Only
                // counted when a quota exists - `quota_left` stays -1 for a
                // country with no envelope, which is what makes "no envelope
                // reports nothing" a fact of the code rather than a convention.
                // Read from the same `cost` the intent carries, so the panel's
                // 已用配额 reconciles with the treasury one-for-one.
                if (h.country >= 0 && (size_t)h.country < _policies.size() &&
                    (size_t)h.country < ds.quota_left.size() &&
                    ds.quota_left[(size_t)h.country] >= 0) {
                    _policies[(size_t)h.country].procurement_budget_used += cost;
                }
                MilitaryIntent buy;
                buy.kind = MILITARY_INTENT_PROCURE_GOOD;
                buy.cell = market_cell;
                buy.good = real_good >= 0 ? real_good : (int32_t)good_id;
                buy.country_a = country_handle_for(digest, h.country);
                buy.count = qty;
                buy.amount = cost;
                buy.source_id = static_cast<uint64_t>(e.kind) << 32 |
                                static_cast<uint32_t>(e.slot < 0 ? 0 : e.slot);
                // Goods remain unavailable until the committed purchase receipt.
                ++_report.intents_emitted;
                ++_report.procure_markets_used;
                ++delivered_markets;
                // Nothing is created here: no convoy id is spent, no stock is
                // credited, no ledger term moves. The order below is only a
                // destination description; `settle_purchase` turns the real
                // filled quantity into custody on the receipt day.
                MilitaryPurchaseOrder order;
                order.channel = 0;
                order.destination_cell = h.cell;
                order.dest_kind = e.kind;
                order.dest = h.holder;
                order.dest_handle = e.kind == MILITARY_LOT_ARMY ? army_handle(h.holder)
                                                               : static_cast<uint64_t>(h.holder);
                order.stock_good = (int32_t)good_id;
                order.real_good = real_good;
                order.category = e.cls < 0 ? e.category : -1;
                order.quality = static_cast<int8_t>(delivered_quality);
                // Convoy route = ring distance (design 9.3 / 9.4), fixed now so a
                // later market move cannot rewrite the distance already paid for.
                const int32_t distance = std::max(1, cell_distance(market_cell, h.cell));
                order.route_cost_q16 = distance * MILITARY_Q16;
                const int32_t speed_q16 = stat_or(digest, h.country, MSTAT_SUPPLY_TRANSPORT);
                int32_t days = (order.route_cost_q16 + speed_q16 - 1) / speed_q16;
                if (days < 1) days = 1;
                order.days = days;
                if (e.kind == MILITARY_LOT_TRAINING && h.holder >= 0
                    && (size_t)h.holder < _training.size()) {
                    // Stable order id, not the compacting vector index.
                    order.dest_handle = _training[(size_t)h.holder].id;
                }
                queue_purchase(buy, order, out);
            }
        }
        int64_t missing = 0;
        int64_t deferred = 0;
        for (int32_t ei = h.entry_begin; ei < h.entry_begin + h.entry_count; ++ei) {
            const DemandEntry &e = entries[(size_t)ei];
            const int64_t gap = e.want - e.sourced;
            if (gap <= 0) continue;
            missing += gap;
            // 任务 8 / 需求 5.4: only the part the BUDGET refused counts as 待购.
            // A gap with no quota flag means no market in range could serve it,
            // which is a supply problem the panel must not blame on the budget.
            if (e.quota_hit != 0) deferred += gap;
        }
        if (missing <= 0) continue;
        if (deferred > 0 && h.country >= 0 && (size_t)h.country < _policies.size()) {
            _policies[(size_t)h.country].procurement_deferred_units += deferred;
        }
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
    // Publish only the residual, funded gap, choosing one cheapest reachable
    // substitute even when every market has zero stock. This is a forecast,
    // never a sale, delivery, treasury debit or military stock credit.
    for (int32_t country = 0; country < capacity; ++country)
        if (ds.quota_left[(size_t)country] >= 0)
            ds.cash_left[(size_t)country] = std::min(ds.cash_left[(size_t)country], ds.quota_left[(size_t)country]);
    for (const DemandEntry &entry : entries) {
        if (entry.want <= entry.sourced + entry.in_flight || entry.reach_begin >= entry.reach_end) continue;
        if (entry.kind == MILITARY_LOT_TRAINING) {
            const Demander &holder = ds.holders[(size_t)entry.slot];
            if (entry.sourced > 0 || std::binary_search(ds.training_in_flight.begin(),
                    ds.training_in_flight.end(), std::make_pair(_training[(size_t)holder.holder].id,
                        entry.category))) continue;
        }
        int32_t candidate = entry.reach_begin;
        while (candidate < entry.reach_end && entry.cls < 0 &&
            equip_good_quality(_catalog, _md_row_good[(size_t)ds.reach[(size_t)candidate].row]) < entry.min_quality)
            ++candidate;
        if (candidate >= entry.reach_end) continue;
        const int32_t row = ds.reach[(size_t)candidate].row;
        const int32_t good = _md_row_good[(size_t)row];
        const int64_t price = _md_row_price[(size_t)row];
        if (price <= 0) continue;
        int64_t quantity = entry.want - entry.sourced - entry.in_flight;
        if (entry.cls >= 0) {
            const int32_t index = class_index_of_good(_catalog, entry.cls, good);
            const auto &yields = _catalog.supply_yield_q16[(size_t)entry.cls];
            const int64_t yield = index >= 0 && (size_t)index < yields.size()
                ? std::max<int32_t>(1, yields[(size_t)index]) : MILITARY_Q16;
            quantity = (quantity * MILITARY_Q16 + yield - 1) / yield;
        }
        int64_t &cash = ds.cash_left[(size_t)entry.country];
        quantity = std::min(quantity, mul_div(cash, MILITARY_GOODS_SCALE, price));
        if (quantity <= 0) continue;
        cash -= mul_div(quantity, price, MILITARY_GOODS_SCALE);
        MilitaryIntent demand;
        demand.kind = MILITARY_INTENT_PROCUREMENT_DEMAND;
        demand.country_a = country_handle_for(digest, entry.country);
        demand.cell = _md_row_cell[(size_t)row];
        demand.good = good;
        demand.count = quantity;
        demand.amount = TARGET_DAYS;
        out.push_back(demand);
    }
}

// ============================================================= purchase settle
// Physical-maintenance design §3 / D1 / D6.
//
// `run_procurement` (and, from S2 on, the maintenance pass) only RECORDS an
// intention to buy. This pair is the only place a purchase turns into custody:
//   queue_purchase  -> a pending order with a stable request id, nothing else
//   settle_purchase -> the real filled quantity, credited as stock (same cell)
//                      or as a convoy (other cell); the real paid amount is the
//                      only money that enters the procurement/maintenance spend.
// A receipt that names an unknown id is a duplicate (or a save that already
// settled it) and is a no-op: a repeated fill must never credit twice.
void MilitaryCore::queue_purchase(MilitaryIntent intent,
                                  const MilitaryPurchaseOrder &destination,
                                  std::vector<MilitaryIntent> &out) {
    MilitaryPurchaseOrder order = destination;
    order.intent = intent;
    if (_next_purchase_id <= 0) _next_purchase_id = 1;
    // The stable identity travels in `source_id`: the bridge copies it to the
    // pending row and back into the receipt (world_ext_military.cpp:1592/2167).
    order.intent.source_id = static_cast<uint64_t>(_next_purchase_id++);
    _purchase_orders.push_back(order);
    out.push_back(order.intent);
}

void MilitaryCore::settle_purchase(const MilitaryIntentReceipt &receipt) {
    const uint64_t request_id = receipt.source_id;
    if (request_id == 0) return;
    size_t index = _purchase_orders.size();
    for (size_t i = 0; i < _purchase_orders.size(); ++i) {
        if (_purchase_orders[i].intent.source_id == request_id) {
            index = i;
            break;
        }
    }
    if (index == _purchase_orders.size()) return;   // duplicate / already settled
    const MilitaryPurchaseOrder order = _purchase_orders[index];
    _purchase_orders.erase(_purchase_orders.begin() + static_cast<std::ptrdiff_t>(index));
    const int32_t slot = ensure_country_slot(order.intent.country_a);
    const int64_t requested = std::max<int64_t>(0, order.intent.count);
    // Only a real fill counts. A row can be acknowledged with a zero fill
    // (out of stock, no merchant, treasury empty) and that is not a delivery.
    int64_t filled = receipt.ok ? std::min<int64_t>(receipt.committed_count, requested) : 0;
    int64_t paid = receipt.ok ? std::max<int64_t>(0, std::min<int64_t>(receipt.committed_amount,
                                                                      order.intent.amount))
                              : 0;
    if (filled <= 0) {
        // Keep the shortfall visible as unmet demand; it is re-detected from the
        // stock level on the next procurement pass, so it is never lost.
        ++_report.unmet_procurement_holders;
        _report.unmet_procurement_units += requested;
        if (slot >= 0) {
            if ((int32_t)_unmet_procure_units.size() < slot + 1) {
                _unmet_procure_units.resize(static_cast<size_t>(slot + 1), 0);
            }
            _unmet_procure_units[static_cast<size_t>(slot)] += requested;
        }
        return;
    }
    // Paid money that the treasury actually moved. The maintenance channel books
    // it as maintenance spend; the general channel keeps its own rolling term.
    if (slot >= 0 && static_cast<size_t>(slot) < _policies.size()) {
        MilitaryCountryPolicy &p = _policies[static_cast<size_t>(slot)];
        if (order.channel == 1) {
            p.spend_upkeep_30 = p.spend_upkeep_30 - p.spend_upkeep_30 / 6 + paid;
            _report.maintenance_spend += paid;
        } else {
            p.spend_procurement_30 = p.spend_procurement_30 - p.spend_procurement_30 / 30 + paid;
        }
    }
    // Handover: the goods are now in military custody, so `_ledger_received` must
    // move at exactly this point. A same-cell purchase is inventory today; a
    // farther one is a real convoy, and the reconciliation identity
    // (received = stock + transit + consumed + ...) stays exact either way.
    const int32_t market_cell = order.intent.cell;
    if (order.dest_kind == MILITARY_LOT_ARMY) {
        int32_t army = -1;
        if (!resolve_army(order.dest, army)) {
            // The formation died while the purchase was in flight. The goods were
            // really bought (the market lost them and the treasury paid), so they
            // enter custody and leave it again in the same step: booking ONLY the
            // return term would break the goods identity
            // (received = stock + transit + consumed + ... + returned) by exactly
            // the refunded quantity, which is what the war scenario caught.
            _ledger_received += filled;
            _ledger_returned += filled;
            return;
        }
    }
    if (market_cell >= 0 && market_cell == order.destination_cell) {
        stock_add(order.dest_kind, order.dest, slot, order.stock_good, filled);
        _ledger_received += filled;
        if (order.dest_kind == MILITARY_LOT_TRAINING && order.quality > 0) {
            note_training_delivery(_training, _catalog, order.dest_handle,
                                   order.category, static_cast<int32_t>(order.quality));
        }
        return;
    }
    MilitaryShipment shipment;
    shipment.id = _next_id++;
    shipment.country_slot = slot;
    shipment.dest_kind = order.dest_kind;
    shipment.dest = order.dest;
    shipment.dest_handle = order.dest_handle;
    shipment.origin_cell = market_cell;
    shipment.current_cell = market_cell;
    shipment.good = order.stock_good;
    shipment.real_good = order.real_good;
    shipment.quality = order.quality;
    shipment.qty = filled;
    shipment.value = paid;
    shipment.departure_day = _last_day;
    shipment.eta_day = _last_day + std::max(1, order.days);
    shipment.route_cost_q16 = order.route_cost_q16;
    shipment.progress_q16 = 0;
    shipment.blocked_days = 0;
    _shipments.push_back(shipment);
    _ledger_received += filled;
}
