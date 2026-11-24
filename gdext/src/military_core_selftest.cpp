// military_core_selftest.cpp - MilitaryCore::self_test and the synthetic
// bench (owner: A3). Pure C++, no Godot types; the bridge exposes both through
// runtime_military_self_test / run_military_bench.
//
// The self test builds a 32x24 odd-r, east-west wrapping hex map (neighbour
// order = HexUtils.CUBE_DIRECTIONS, same convention as military_core_path.cpp),
// a four-entry catalog (militia + 2 units + 1 barracks) and a three-country
// digest, then drives step_day() through a tiny in-process "bridge" that turns
// ENLIST/LEVY/DISCHARGE/CASUALTY intents into next-day receipts.

#include "military_core.h"
#include "military_core_internal.h"
#include "military_core_flight_sums.h"

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <string>
#include <vector>

namespace pk {

namespace {

using namespace mil;

// ------------------------------------------------------------ fixtures

MilitaryTerrainInput make_hex_terrain(int32_t w, int32_t h) {
    MilitaryTerrainInput t;
    t.width = w;
    t.height = h;
    t.cell_count = w * h;
    const size_t n = (size_t)t.cell_count;
    t.neighbors.assign(n * 6, -1);
    static const int32_t kDir[6][2] = {{1, 0}, {1, -1}, {0, -1}, {-1, 0}, {-1, 1}, {0, 1}};   // (dq, dr)
    for (int32_t row = 0; row < h; ++row) {
        for (int32_t col = 0; col < w; ++col) {
            const int32_t q = col - (row - (row & 1)) / 2;
            for (int32_t d = 0; d < 6; ++d) {
                const int32_t nq = q + kDir[d][0];
                const int32_t nr = row + kDir[d][1];
                if (nr < 0 || nr >= h) continue;
                int32_t ncol = nq + (nr - (nr & 1)) / 2;
                ncol = ((ncol % w) + w) % w;
                t.neighbors[(size_t)(row * w + col) * 6 + (size_t)d] = nr * w + ncol;
            }
        }
    }
    t.landform.assign(n, 4);   // PLAIN
    t.vegetation.assign(n, 0);
    t.cover.assign(n, 0);
    t.is_water.assign(n, 0);
    t.has_river.assign(n, 0);
    t.settlement_tier.assign(n, 0);
    return t;
}

MilitaryCatalog make_catalog(int64_t barracks_upkeep = 0) {
    MilitaryCatalog c;
    MilitaryUnitType militia;
    militia.id = "a_militia";
    militia.unit_class = MILITARY_CLASS_LINE;
    militia.is_default_militia = 1;
    militia.attack_q16 = MILITARY_Q16;
    militia.defense_q16 = MILITARY_Q16;
    militia.training_days = 10;
    militia.idle_per_100_day[MILITARY_SUPPLY_RATION] = 500;
    MilitaryUnitType inf;
    inf.id = "b_infantry";
    inf.unit_class = MILITARY_CLASS_LINE;
    inf.attack_q16 = MILITARY_Q16 * 3 / 2;
    inf.defense_q16 = MILITARY_Q16 * 3 / 2;
    inf.training_days = 20;
    inf.slot_count = 1;
    inf.slot_category[0] = 0;
    inf.slot_min_quality[0] = 1;
    inf.slot_qty_per_100[0] = 1000 * MILITARY_GOODS_SCALE / 1000;
    inf.slot_power_weight_q16[0] = MILITARY_Q16;
    inf.idle_per_100_day[MILITARY_SUPPLY_RATION] = 500;
    MilitaryUnitType gun;
    gun.id = "c_cannon";
    gun.unit_class = MILITARY_CLASS_ARTILLERY;
    gun.unlock_bit = 0;
    gun.attack_q16 = MILITARY_Q16 * 3;
    gun.defense_q16 = MILITARY_Q16;
    gun.speed_q16 = MILITARY_Q16 / 2;
    gun.training_days = 30;
    c.units = {militia, inf, gun};
    MilitaryEquipCategory arms;
    arms.id = "arms";
    arms.good_ids = {1};
    arms.good_quality = {1};
    c.categories = {arms};
    MilitaryStateBuilding barracks;
    barracks.id = "barracks";
    // The economy type this lot is filed under. The core resolves the digest's
    // state rows back through this column, so a synthetic catalog without it
    // would make every ledger row unmappable.
    barracks.economy_building_id = 0;
    barracks.role = MILITARY_STATE_BARRACKS;
    barracks.tier = 0;
    barracks.capacity = 100;
    barracks.build_days = 5;
    // MONEY_SCALE per building per day. Zero by default: every other case bills
    // nothing for standing buildings, so the upkeep channel stays silent exactly
    // as before this parameter existed.
    barracks.upkeep_per_day = barracks_upkeep;
    c.state_buildings = {barracks};
    c.supply_goods[MILITARY_SUPPLY_RATION] = {0};
    c.supply_yield_q16[MILITARY_SUPPLY_RATION] = {MILITARY_Q16};
    c.economy_good_count = 2;
    c.unlock_count = 1;
    return c;
}

constexpr int32_t kW = 32, kH = 24;
inline int32_t cell_at(int32_t col, int32_t row) { return row * kW + col; }
const int32_t kEnclave = cell_at(14, 12);   // the single cell of country 2

uint64_t handle_for(int32_t slot) { return (7ull << 32) | (uint64_t)(slot + 1); }

MilitaryWorldDigest make_digest(const MilitaryTerrainInput &t) {
    MilitaryWorldDigest d;
    const size_t n = (size_t)t.cell_count;
    d.country_capacity = 3;
    d.cell_owner_slot.assign(n, -1);
    for (int32_t row = 0; row < kH; ++row) {
        for (int32_t col = 0; col < kW; ++col) {
            d.cell_owner_slot[(size_t)cell_at(col, row)] = col < 14 ? 0 : 1;
        }
    }
    d.cell_owner_slot[(size_t)kEnclave] = 2;
    d.country_handle = {handle_for(0), handle_for(1), handle_for(2)};
    d.country_cash = {1000000000000ll, 1000000000000ll, 1000000000000ll};
    d.country_era = {0, 0, 0};
    d.country_annual_revenue = {0, 0, 0};
    d.country_capital_cell = {cell_at(5, 12), cell_at(24, 12), kEnclave};
    d.country_soldier_living_cost = {0, 0, 0};
    d.cell_population.assign(n, 1000);
    d.cell_population[(size_t)kEnclave] = 200;
    d.cell_unemployed.assign(n, 200);
    d.cell_soldiers.assign(n, 0);
    d.cell_has_merchant.assign(n, 0);
    for (int32_t c = 0; c < t.cell_count; c += 37) {
        d.cell_has_merchant[(size_t)c] = 1;
        d.market_cell.push_back(c);
        d.market_good.push_back(0);
        d.market_sellable.push_back(1000000);
        d.market_price.push_back(20000);
        d.market_cell.push_back(c);
        d.market_good.push_back(1);
        d.market_sellable.push_back(500000);
        d.market_price.push_back(80000);
    }
    d.unlock_words = 1;
    d.country_unlock_bits = {0ull, 1ull, 0ull};   // only country 1 has cannons
    d.stat_count = 0;
    return d;
}
// In-process bridge: intents of day D become receipts for day D+1.
// It also stands in for the economy's building ledger. `MilitaryCellState`'s
// barracks/fort/college fields are a derived read of the economy's kind-3
// building groups (requirement 6.1), so a harness that only submitted
// `MCMD_STATE_BUILD` would hold a cache that is forever empty. Every lot the
// harness accepts is therefore recorded here and published on the digest from
// its completion day on - exactly what a re-read of the economy would report.
struct Sim {
    MilitaryCore core;
    MilitaryWorldDigest dg;
    std::vector<MilitaryIntentReceipt> receipts;
    std::vector<MilitaryIntent> last;
    std::vector<int64_t> enlist_by_cell;
    struct LedgerLot {
        int32_t cell = -1;
        int32_t building = -1;
        int64_t ready_day = 0;
        int32_t units = 0;
    };
    std::vector<LedgerLot> lots;
    int64_t day = 0;
    int64_t max_abs_reconcile = 0;
    int64_t first_leak_day = -1;
    std::string first_leak_events;
    std::string error;
    bool init(const MilitaryTerrainInput &t, uint64_t seed) {
        return init(t, seed, make_catalog());
    }
    bool init(const MilitaryTerrainInput &t, uint64_t seed, MilitaryCatalog catalog) {
        if (!core.configure(std::move(catalog), seed, error)) return false;
        if (!core.set_terrain(t, error)) return false;
        dg = make_digest(t);
        for (int32_t s = 0; s < dg.country_capacity; ++s) {
            if (core.ensure_country_slot(dg.country_handle[(size_t)s]) != s) {
                error = "slot_order";
                return false;
            }
        }
        enlist_by_cell.assign((size_t)t.cell_count, 0);
        return true;
    }
    bool submit(uint16_t op, int32_t slot, MilitaryCommand cmd) {
        cmd.op = op;
        cmd.country = handle_for(slot);
        cmd.effective_day = day;
        const int32_t build_cell = cmd.cell;
        const int32_t build_index = cmd.unit_to;
        if (!core.submit(std::move(cmd), error)) return false;
        // A submitted `state.build` is by contract one the economy already
        // accepted (the bridge only forwards after the bill settled), so the
        // harness's ledger has to know about it too.
        if (op == MCMD_STATE_BUILD) record_lot(build_cell, build_index);
        return true;
    }
    // The economy side of a `state.build`: one unit that starts standing on its
    // completion day.
    void record_lot(int32_t cell, int32_t building) {
        if (cell < 0 || building < 0 ||
            (size_t)building >= core.catalog().state_buildings.size())
            return;
        const MilitaryStateBuilding &sb = core.catalog().state_buildings[(size_t)building];
        if (sb.economy_building_id < 0) return;   // no economy profile, no bill
        LedgerLot lot;
        lot.cell = cell;
        lot.building = building;
        lot.ready_day = day + std::max(1, sb.build_days);
        lot.units = 1;
        lots.push_back(lot);
    }
    // Publishes the ledger as the digest's state lanes, the way
    // `capture_military_digest` reads the economy's building groups.
    void publish_state_ledger() {
        dg.state_cell.clear();
        dg.state_type_id.clear();
        dg.state_state_role.clear();
        dg.state_units.clear();
        for (const LedgerLot &lot : lots) {
            if (lot.units <= 0 || lot.ready_day > day) continue;
            const MilitaryStateBuilding &sb = core.catalog().state_buildings[(size_t)lot.building];
            dg.state_cell.push_back(lot.cell);
            dg.state_type_id.push_back(sb.economy_building_id);
            dg.state_state_role.push_back((int32_t)sb.role + 1);
            dg.state_units.push_back(lot.units);
        }
        dg.state_lanes_present = true;
        dg.state_lane_rows = (int32_t)dg.state_cell.size();
    }
    bool step() {
        last.clear();
        dg.day = day;
        publish_state_ledger();
        // Economy owns the soldier cohort count and Military reconciles against
        // it every day, so the synthetic digest has to expose what the "economy"
        // side of this harness would hold: the heads enlisted so far.
        for (size_t c = 0; c < enlist_by_cell.size() && c < dg.cell_soldiers.size(); ++c)
            dg.cell_soldiers[c] = enlist_by_cell[c];
        if (!core.step_day(day, dg, receipts, last, error)) return false;
        receipts.clear();
        for (const MilitaryIntent &in : last) {
            MilitaryIntentReceipt r;
            r.kind = in.kind;
            r.ok = 1;
            r.cell = in.cell;
            r.source_id = in.source_id;
            r.committed_count = in.count;
            r.committed_amount = in.amount;
            switch (in.kind) {
                case MILITARY_INTENT_ENLIST:
                case MILITARY_INTENT_LEVY:
                    if (in.cell >= 0) {
                        enlist_by_cell[(size_t)in.cell] += in.count;
                        dg.cell_unemployed[(size_t)in.cell] =
                            std::max<int64_t>(0, dg.cell_unemployed[(size_t)in.cell] - in.count);
                    }
                    receipts.push_back(r);
                    break;
                case MILITARY_INTENT_DISCHARGE:
                    if (in.cell >= 0) {
                        enlist_by_cell[(size_t)in.cell] = std::max<int64_t>(0,
                            enlist_by_cell[(size_t)in.cell] - in.count);
                        dg.cell_unemployed[(size_t)in.cell] += in.count;
                    }
                    receipts.push_back(r);
                    break;
                case MILITARY_INTENT_CASUALTY:
                    if (in.cell >= 0)
                        enlist_by_cell[(size_t)in.cell] = std::max<int64_t>(0,
                            enlist_by_cell[(size_t)in.cell] - in.count);
                    receipts.push_back(r);
                    break;
                case MILITARY_INTENT_STATE_BUILD: {
                    // The bridge's state.build lane: accept the lot in the
                    // ledger, then echo the bookkeeping command the way
                    // `translate_military_intent` does.
                    const int32_t building = static_cast<int32_t>(in.count);
                    if (building >= 0 &&
                        (size_t)building < core.catalog().state_buildings.size() &&
                        core.catalog().state_buildings[(size_t)building].economy_building_id >= 0 &&
                        in.cell >= 0) {
                        record_lot(in.cell, building);
                        MilitaryCommand echo;
                        echo.op = MCMD_STATE_BUILD;
                        echo.country = in.country_a;
                        echo.cell = in.cell;
                        echo.unit_to = building;
                        echo.effective_day = day;
                        std::string echo_error;
                        core.submit(std::move(echo), echo_error);
                    }
                    break;
                }
                case MILITARY_INTENT_PROCURE_GOOD: {
                    // Physical procurement settles ONLY on a real fill receipt
                    // (design D1/D6). This harness stands in for Economy, so it
                    // fills what was asked and echoes the paid amount; the core
                    // is what turns that into stock, a convoy and a ledger term.
                    // Without this row nothing would ever enter custody, which is
                    // the whole point of removing the optimistic booking.
                    r.ok = in.count > 0 ? 1 : 0;
                    r.committed_count = in.count;
                    r.committed_amount = in.amount;
                    receipts.push_back(r);
                    break;
                }
                default:
                    break;
            }
        }
        const int64_t rd = core.report().reconcile_delta;
        if (rd != 0 && max_abs_reconcile == 0) {
            first_leak_day = day;
            for (const MilitaryEvent &e : core.events_after(0, 100000)) {
                if (e.day == day) first_leak_events += std::to_string(e.type) + " ";
            }
            // Which ledger term moved without its pair? The identity is
            // received = stock + transit + consumed + intercepted_out
            //                    - intercepted_in + returned.
            first_leak_events += "|received=" + std::to_string(core._ledger_received) +
                                 " stock=" + std::to_string(core.ledger_stock_total()) +
                                 " transit=" + std::to_string(core.ledger_transit_total()) +
                                 " consumed=" + std::to_string(core._ledger_consumed) +
                                 " int_out=" + std::to_string(core._ledger_intercepted_out) +
                                 " int_in=" + std::to_string(core._ledger_intercepted_in) +
                                 " returned=" + std::to_string(core._ledger_returned) +
                                 " delta=" + std::to_string(rd);
        }
        if (std::llabs(rd) > max_abs_reconcile) max_abs_reconcile = std::llabs(rd);
        ++day;
        return true;
    }
    bool run_until(int64_t end_day) {
        while (day < end_day) {
            if (!step()) return false;
        }
        return true;
    }
    int32_t army_of(int32_t slot) const {
        const MilitaryArmyStore &a = core.armies();
        for (int32_t i = 0; i < (int32_t)a.active.size(); ++i) {
            if (a.active[(size_t)i] && a.owner_slot[(size_t)i] == slot) return i;
        }
        return -1;
    }
};
int64_t garrison_at(const MilitaryCore &core, int32_t cell) {
    const MilitaryLotStore &l = core.lots();
    int64_t total = 0;
    for (size_t i = 0; i < l.active.size(); ++i) {
        if (l.active[i] && l.location_kind[i] == MILITARY_LOT_GARRISON && l.location[i] == cell) total += l.count[i];
    }
    return total;
}
bool is_neighbor(const MilitaryTerrainInput &t, int32_t a, int32_t b) {
    if (a == b) return true;
    for (int32_t d = 0; d < 6; ++d) {
        if (t.neighbors[(size_t)a * 6 + (size_t)d] == b) return true;
    }
    return false;
}
// Names the first state component that differs after a PKMI round trip.
std::string describe_diff(const MilitaryCore &a, const MilitaryCore &b) {
    std::string out;
    auto note = [&out](bool same, const char *what) {
        if (!same) out += std::string("     diff: ") + what + "\n";
    };
    note(a._last_day == b._last_day && a._next_sequence == b._next_sequence && a._next_id == b._next_id &&
             a._next_event_id == b._next_event_id && a._control_revision == b._control_revision &&
             a._front_revision == b._front_revision,
         "counters");
    note(a._path_daily_requests == b._path_daily_requests, "path_daily_requests");
    note(a._pending.size() == b._pending.size(), "pending");
    note(a._lots.active == b._lots.active && a._lots.count == b._lots.count &&
             a._lots.condition_q16 == b._lots.condition_q16 && a._lots.location == b._lots.location,
         "lots");
    const MilitaryArmyStore &x = a._armies, &y = b._armies;
    for (size_t i = 0; i < x.active.size(); ++i) {
        if (!x.active[i]) continue;
        char buf[160];
        std::snprintf(buf, sizeof(buf), "army %zu head %lld/%lld atk %lld/%lld eng %d/%d spd %d/%d mvday %lld/%lld",
                      i, (long long)x.cached_headcount[i], (long long)y.cached_headcount[i],
                      (long long)x.cached_attack_q16[i], (long long)y.cached_attack_q16[i], x.engagement[i],
                      y.engagement[i], x.cached_speed_q16[i], y.cached_speed_q16[i], (long long)x.moved_day[i],
                      (long long)y.moved_day[i]);
        note(x.cached_headcount[i] == y.cached_headcount[i] && x.cached_attack_q16[i] == y.cached_attack_q16[i] &&
                 x.cached_defense_q16[i] == y.cached_defense_q16[i] && x.engagement[i] == y.engagement[i] &&
                 x.cached_speed_q16[i] == y.cached_speed_q16[i] && x.path_len[i] == y.path_len[i] &&
                 x.moved_day[i] == y.moved_day[i] && x.prev_cell[i] == y.prev_cell[i] &&
                 x.generation[i] == y.generation[i] && x.organization_q16[i] == y.organization_q16[i],
             buf);
    }
    note(a._stocks.size() == b._stocks.size(), "stocks");
    note(a._shipments.size() == b._shipments.size(), "shipments");
    note(a._engagements.size() == b._engagements.size(), "engagements");
    note(a._wars.size() == b._wars.size(), "wars");
    note(a._truces.size() == b._truces.size(), "truces");
    note(a._battle_log.size() == b._battle_log.size(), "battle_log");
    note(a._areas.size() == b._areas.size(), "areas");
    note(a._explorations.size() == b._explorations.size(), "explorations");
    if (a._explorations.size() == b._explorations.size()) {
        for (size_t i = 0; i < a._explorations.size(); ++i) {
            const MilitaryExplorationTask &x = a._explorations[i];
            const MilitaryExplorationTask &y = b._explorations[i];
            char buf[220];
            std::snprintf(buf, sizeof(buf),
                          "exploration %zu active %d/%d phase %u/%u result %u/%u "
                          "selected %d/%d seen %016llx/%016llx",
                          i, x.active ? 1 : 0, y.active ? 1 : 0,
                          (unsigned)x.phase, (unsigned)y.phase,
                          (unsigned)x.result, (unsigned)y.result,
                          x.selected_count, y.selected_count,
                          (unsigned long long)x.seen_mask[0],
                          (unsigned long long)y.seen_mask[0]);
            note(x.active == y.active && x.row_index == y.row_index &&
                     x.army_handle == y.army_handle &&
                     x.owner_slot == y.owner_slot &&
                     x.owner_handle == y.owner_handle &&
                     x.origin_cell == y.origin_cell &&
                     x.return_cell == y.return_cell &&
                     x.anchor_cell == y.anchor_cell &&
                     x.radius == y.radius &&
                     x.selected_count == y.selected_count &&
                     x.selected_cells == y.selected_cells &&
                     x.seen_mask == y.seen_mask &&
                     x.visited_mask == y.visited_mask &&
                     x.blocked_mask == y.blocked_mask &&
                     x.phase == y.phase &&
                     x.pause_reason == y.pause_reason &&
                     x.result == y.result &&
                     x.resume_phase == y.resume_phase &&
                     x.focus_index == y.focus_index &&
                     x.current_observation_cell == y.current_observation_cell &&
                     x.observer_tries == y.observer_tries &&
                     x.reached_observer_cells == y.reached_observer_cells &&
                     x.tried_observer_mask == y.tried_observer_mask &&
                     x.started_day == y.started_day &&
                     x.last_progress_day == y.last_progress_day &&
                     x.last_plan_day == y.last_plan_day &&
                     x.complete_day == y.complete_day &&
                     x.return_fallback == y.return_fallback,
                 buf);
        }
    }
    note(a._policies.size() == b._policies.size(), "policies");
    note(a._cell_states.size() == b._cell_states.size(), "cell_states");
    note(a._cell_controller == b._cell_controller, "controller");
    note(a._events.size() == b._events.size(), "events");
    note(a._ai_country == b._ai_country && a._ai_next_decision_day == b._ai_next_decision_day, "ai");
    note(a._ledger_received == b._ledger_received && a._ledger_consumed == b._ledger_consumed, "ledger");
    note(a._seed == b._seed && a._catalog.hash == b._catalog.hash, "seed/catalog");
    return out;
}
bool has_event(const MilitaryCore &core, uint16_t type) {
    for (const MilitaryEvent &e : core.events_after(0, 100000)) {
        if (e.type == type) return true;
    }
    return false;
}
#define ST_CHECK(cond, msg)                                    \
    do {                                                       \
        if (!(cond)) {                                         \
            report += std::string("FAIL ") + (msg) + "\n";     \
            return false;                                      \
        }                                                      \
        report += std::string("ok   ") + (msg) + "\n";         \
    } while (0)
#define ST_STEP(sim, end)                                                          \
    do {                                                                           \
        if (!(sim).run_until(end)) {                                               \
            report += "FAIL step_day: " + (sim).error + "\n";                      \
            return false;                                                          \
        }                                                                          \
    } while (0)
// --- 1. peaceful empty world
bool test_idle(const MilitaryTerrainInput &t, std::string &report) {
    MilitaryCore core;
    std::string error;
    ST_CHECK(core.configure(make_catalog(), 11, error) && core.set_terrain(t, error), "configure + terrain");
    bool any = false;
    for (int64_t d = 0; d < 60; ++d) any = any || core.should_run(d);
    ST_CHECK(!any, "peaceful empty world: should_run false for 60 days");
    // Registered countries with no target, no AI, no armies: off-cadence days idle.
    MilitaryCore core2;
    core2.configure(make_catalog(), 11, error);
    core2.set_terrain(t, error);
    for (int32_t s = 0; s < 3; ++s) core2.ensure_country_slot(handle_for(s));
    ST_CHECK(!core2.should_run(1) && !core2.should_run(7), "peaceful registered world idle off the 5-day cadence");
    return true;
}
// --- B1 read point: MSTAT_BARRACKS_CAPACITY scales the summed posts.
// Fixtures are deliberately separate and each pins one explicit q16 constant.
//   1,640 rows = 164,000 posts: far from the cap, and for kQ = 72089 the three
//   plausible implementations print three different numbers
//   (q16 180,398 / q16 of 72090 180,401 / decimal 11/10 180,400), so this
//   fixture fails whichever way the factor is mis-encoded.
//   4,800 rows = 480,000 posts: the only size that reaches the cap after a 1.1
//   factor; 527,995 truncates back to 524,288. Removing the cap (527,995) and
//   scaling after the cap (also 527,995) each fail this assertion.
bool test_barracks_capacity_scale(const MilitaryTerrainInput &t, std::string &report) {
    const int32_t A = cell_at(5, 5);
    const int64_t cap = (int64_t)MILITARY_MAX_ARMIES * 256;
    // q16 1.1 exactly as the tech chain encodes it. Every expected value below
    // is computed from this constant, never from posts * 11 / 10.
    const int64_t kQ = 72089;
    auto setup = [&](MilitaryCore &core, int32_t barracks_rows, int32_t slot0_q16,
                     int32_t slot1_q16) -> bool {
        std::string error;
        if (!core.configure(make_catalog(), 11, error) || !core.set_terrain(t, error)) {
            return false;
        }
        core.ensure_country_slot(handle_for(0));
        core.ensure_country_slot(handle_for(1));
        MilitaryCellState row = {};
        row.cell = A;
        row.barracks_count[0] = barracks_rows;
        core._cell_states.clear();
        core._cell_states.push_back(row);
        // Write the committed digest directly: posts_for_cell reads _last_digest,
        // which is the previous commit day's view, so the test cannot rely on
        // "change the stat and step one day". country_capacity and stat_count are
        // what has_stat gates on: without them stat_q16 silently returns 1.0.
        core._last_digest.country_capacity = 2;
        core._last_digest.stat_count = MSTAT_COUNT;
        core._last_digest.country_stat_q16.assign(2 * MSTAT_COUNT, MILITARY_Q16);
        core._last_digest.country_stat_q16[MSTAT_BARRACKS_CAPACITY] = slot0_q16;
        core._last_digest.country_stat_q16[MSTAT_COUNT + MSTAT_BARRACKS_CAPACITY] =
            slot1_q16;
        return true;
    };
    MilitaryCore core;
    // (1) factor 1.0 must be bit-identical to the unscaled sum: 48 rows.
    ST_CHECK(setup(core, 48, MILITARY_Q16, MILITARY_Q16), "barracks scale 1.0: configure + terrain");
    const int32_t posts_48 = core.posts_for_cell(A, 0);
    ST_CHECK(posts_48 == 4800, "factor 1.0: 48 rows -> 4800 posts unchanged");
    // Measured, not assumed: the catalog's tier-0 barracks capacity.
    const int64_t per_row = posts_48 / 48;
    // (2) q16 factor on 164,000 posts: one encoding, one number.
    const int64_t posts_164k = 1640 * per_row;
    const int64_t want_164k = posts_164k * kQ / MILITARY_Q16;
    ST_CHECK(setup(core, 1640, (int32_t)kQ, MILITARY_Q16),
             "barracks scale 72089: configure + terrain");
    const int32_t got_164k = core.posts_for_cell(A, 0);
    ST_CHECK((int64_t)got_164k == want_164k,
             "factor 72089: 164000 posts -> 180398 (q16 of 72090 would be 180401, decimal 180400)");
    // (3) the cap still holds after scaling: 480,000 -> 527,995 -> 524,288.
    const int64_t pre_cap = 4800 * per_row * kQ / MILITARY_Q16;
    ST_CHECK(pre_cap > cap, "cap fixture is above the cap before truncation (527995 > 524288)");
    ST_CHECK(setup(core, 4800, (int32_t)kQ, MILITARY_Q16),
             "barracks scale cap: configure + terrain");
    const int32_t got_cap = core.posts_for_cell(A, 0);
    ST_CHECK((int64_t)got_cap == cap, "cap still enforced after scaling (524288)");
    // (4) per-slot factors: same cell, different country -> different posts.
    ST_CHECK(setup(core, 1640, (int32_t)kQ, MILITARY_Q16),
             "barracks scale per-slot: configure + terrain");
    const int32_t got_slot0 = core.posts_for_cell(A, 0);
    const int32_t got_slot1 = core.posts_for_cell(A, 1);
    ST_CHECK((int64_t)got_slot0 == want_164k && (int64_t)got_slot1 == posts_164k,
             "per-country factor: slot0 scaled, slot1 neutral");
    report += "barracks_capacity_scale kQ=" + std::to_string(kQ) +
              " per_row=" + std::to_string(per_row) +
              " posts164000->" + std::to_string(got_164k) + "/want " +
              std::to_string(want_164k) + " precap=" + std::to_string(pre_cap) +
              " capped=" + std::to_string(got_cap) + "/cap " + std::to_string(cap) +
              " per-slot=" + std::to_string(got_slot0) + "," + std::to_string(got_slot1) +
              " all ok\n";
    return true;
}

// --- B2 read point: MSTAT_CONVOY_ESCORT scales `ESCORT_BASE_Q16` before the
// interception roll. The escort value is a local of the convoy loop, so the
// assertion pins the risk boundary it produces, with exact rng rolls:
//   stat 65536 -> escort = mul_div(13107, 65536, 65536) = 13107
//                 risk = 13107 * 32768 / (13107 + 13107) = 16384
//   stat 98304 -> escort = mul_div(13107, 98304, 65536) = 19660  (19660.5 truncated)
//                 risk = 13107 * 32768 / (13107 + 19660) = 13107
// Same shipments, same ids and the same rolls in both worlds, so the only
// variable is the stat. A missing read point leaves the 1.5 world at risk 16384
// and it would then also swallow the 13107 and 16383 rolls.
bool test_convoy_escort_scale(const MilitaryTerrainInput &t, std::string &report) {
    const int32_t A = cell_at(3, 5);
    const int32_t B = cell_at(9, 5);
    const int64_t day = 7;
    // value / MILITARY_MONEY_SCALE = 65536, so escort == escort_q16 (no shift loss).
    const int64_t value = 65536 * MILITARY_MONEY_SCALE;
    const int32_t rolls[4] = {13106, 13107, 16383, 16384};
    int64_t ids[4] = {-1, -1, -1, -1};
    int32_t found = 0;
    for (int64_t id = 1; id <= 4000000 && found < 4; ++id) {
        const int32_t roll = (int32_t)(rng(11, (uint64_t)id, day) & 0xffffu);
        for (int32_t k = 0; k < 4; ++k) {
            if (ids[k] < 0 && roll == rolls[k]) {
                ids[k] = id;
                ++found;
            }
        }
    }
    ST_CHECK(found == 4, "escort fixture: rolls 13106/13107/16383/16384 exist within 4M ids");
    auto run = [&](MilitaryCore &core, int32_t escort_stat_q16) -> bool {
        std::string error;
        if (!core.configure(make_catalog(), 11, error) || !core.set_terrain(t, error)) {
            return false;
        }
        const size_t cells = (size_t)core.terrain().cell_count;
        core._cell_controller.assign(cells, 0);
        core._threat.assign(cells, 13107);      // threat > 0 on every hop
        core._guard.assign(cells, 0);
        core._threat_owner.assign(cells, 0);    // no interceptor army: goods just vanish
        core._shipments.clear();
        for (int32_t k = 0; k < 4; ++k) {
            MilitaryShipment s;
            s.id = (uint64_t)ids[k];
            s.country_slot = 0;
            s.current_cell = A;
            s.origin_cell = A;
            s.dest = B;
            s.eta_day = 60;                     // day 7 < 60: one hop, never delivered
            s.good = 0;
            s.qty = 1;
            s.value = value;
            s.departure_day = 1;
            core._shipments.push_back(s);
        }
        MilitaryWorldDigest digest = make_digest(t);
        digest.day = day;
        digest.stat_count = MSTAT_COUNT;
        digest.country_stat_q16.assign(3 * MSTAT_COUNT, MILITARY_Q16);
        digest.country_stat_q16[MSTAT_CONVOY_ESCORT] = escort_stat_q16;
        std::vector<MilitaryIntent> out;
        core.run_convoys(digest, out);
        // Four hops proves the loop body ran; otherwise "all shipments present"
        // would be misread as "nothing intercepted".
        return core.report().convoys_due == 4 && core.report().convoy_hops == 4;
    };
    const auto survived = [](const MilitaryCore &core, int64_t id) {
        for (const MilitaryShipment &s : core.shipments()) {
            if ((int64_t)s.id == id) return true;
        }
        return false;
    };
    MilitaryCore neutral;
    ST_CHECK(run(neutral, MILITARY_Q16), "escort 1.0: four convoys each took one hop");
    MilitaryCore scaled;
    ST_CHECK(run(scaled, 98304), "escort 1.5: four convoys each took one hop");
    // 1.0 -> risk 16384: 13106 / 13107 / 16383 intercepted, 16384 survives.
    ST_CHECK(!survived(neutral, ids[0]) && !survived(neutral, ids[1]) &&
                 !survived(neutral, ids[2]) && survived(neutral, ids[3]),
             "escort 1.0: risk boundary 16384 (13106/13107/16383 hit, 16384 misses)");
    // 1.5 -> risk 13107: only 13106 intercepted.
    ST_CHECK(!survived(scaled, ids[0]) && survived(scaled, ids[1]) &&
                 survived(scaled, ids[2]) && survived(scaled, ids[3]),
             "escort 1.5: risk boundary 13107 (only 13106 hits; 13107/16383/16384 miss)");
    report += "convoy_escort_scale ids=" + std::to_string(ids[0]) + "/" +
              std::to_string(ids[1]) + "/" + std::to_string(ids[2]) + "/" +
              std::to_string(ids[3]) + " rolls=13106/13107/16383/16384 risk1.0=16384"
              " risk1.5=13107 all ok\n";
    return true;
}

bool test_recruit_and_move(const MilitaryTerrainInput &t, std::string &report, uint64_t &hash_out) {
    Sim sim;
    ST_CHECK(sim.init(t, 1234), "sim init");
    const int32_t A = cell_at(5, 5);
    const int32_t B = cell_at(8, 5);
    {
        MilitaryCommand c;
        c.cell = A;
        c.unit_to = 0;
        ST_CHECK(sim.submit(MCMD_STATE_BUILD, 0, c), "state.build barracks A");
        c.cell = B;
        ST_CHECK(sim.submit(MCMD_STATE_BUILD, 0, c), "state.build barracks B");
        MilitaryCommand target;
        target.count = 0;
        target.value = 150;
        ST_CHECK(sim.submit(MCMD_FORCE_SET_TARGET, 0, target), "force.set_target 150");
    }
    ST_STEP(sim, 41);
    ST_CHECK(sim.core.posts_for_cell(A, 0) == 100 && sim.core.posts_for_cell(B, 0) == 100,
             "barracks completed: 100 posts each");
    ST_CHECK(sim.core.country_soldiers(0) == 150, "recruitment reached target exactly (150)");
    ST_CHECK(garrison_at(sim.core, A) <= 100 && garrison_at(sim.core, B) <= 100, "per-cell garrison <= posts");
    const int64_t enlisted_before = sim.enlist_by_cell[(size_t)A] + sim.enlist_by_cell[(size_t)B];
    ST_STEP(sim, 61);
    ST_CHECK(sim.enlist_by_cell[(size_t)A] + sim.enlist_by_cell[(size_t)B] == enlisted_before,
             "no enlistment after target reached");
    ST_CHECK(sim.core.country_soldiers(1) == 0, "other countries untouched");
    // Cession path: `from < 0` means every garrison lot in the cell. The old
    // exact-match version made this a silent no-op and left the previous
    // owner's roster behind after a territory transfer.
    {
        const int64_t gA_before = garrison_at(sim.core, A);
        sim.core.transfer_garrison_owner(A, -1, 1);
        ST_CHECK(garrison_at(sim.core, A) == gA_before &&
                     sim.core.garrison_heads_at(A, 1) == gA_before &&
                     sim.core.garrison_heads_at(A, 0) == 0,
                 "cession transfer (from=-1) moves every garrison lot at the cell");
        sim.core.transfer_garrison_owner(A, 1, 0);
        ST_CHECK(sim.core.garrison_heads_at(A, 0) == gA_before &&
                     sim.core.garrison_heads_at(A, 1) == 0,
                 "explicit source transfer moves the lots back");
    }
    // Army from A's whole garrison marches to B (3 hexes east).
    const int64_t gA = garrison_at(sim.core, A);
    {
        MilitaryCommand c;
        c.cell = A;
        c.ints = {0, (int32_t)gA};
        ST_CHECK(sim.submit(MCMD_ARMY_CREATE, 0, c), "army.create at A");
    }
    ST_STEP(sim, sim.day + 1);
    const int32_t army = sim.army_of(0);
    ST_CHECK(army >= 0 && sim.core.armies().cached_headcount[(size_t)army] == gA, "army holds A's garrison");
    {
        MilitaryCommand c;
        c.army = sim.core.army_handle(army);
        c.cell = B;
        ST_CHECK(sim.submit(MCMD_ARMY_MOVE, 0, c), "army.move to B");
    }
    std::vector<int32_t> trail = {sim.core.armies().cell[(size_t)army]};
    for (int32_t k = 0; k < 8; ++k) {
        ST_STEP(sim, sim.day + 1);
        trail.push_back(sim.core.armies().cell[(size_t)army]);
    }
    bool contiguous = true;
    int32_t moves = 0;
    for (size_t i = 1; i < trail.size(); ++i) {
        contiguous = contiguous && is_neighbor(t, trail[i - 1], trail[i]);
        if (trail[i] != trail[i - 1]) ++moves;
    }
    ST_CHECK(trail.back() == B, "army arrived at B");
    ST_CHECK(contiguous && moves == sim.core.cell_distance(A, B), "army walked a contiguous shortest path, 1 hex/day");
    // Raise the target: A (emptied) gets quota, B (army present >= posts) gets none.
    {
        MilitaryCommand target;
        target.count = 0;
        target.value = 400;
        ST_CHECK(sim.submit(MCMD_FORCE_SET_TARGET, 0, target), "force.set_target 400");
    }
    const int64_t a0 = sim.enlist_by_cell[(size_t)A], b0 = sim.enlist_by_cell[(size_t)B];
    ST_STEP(sim, sim.day + 12);
    ST_CHECK(sim.enlist_by_cell[(size_t)B] == b0, "army presence at B suppresses B's quota");
    ST_CHECK(sim.enlist_by_cell[(size_t)A] > a0, "emptied barracks A recruits again");
    ST_CHECK(sim.max_abs_reconcile == 0, "ledger reconcile_delta == 0 every day (recruit run)");
    // A sovereign with no soldiers can still be forced into a rebellion war:
    // this is the "朝廷讨伐" path used after a cell secedes.
    {
        MilitaryCommand forced;
        forced.other = handle_for(0);
        ST_CHECK(sim.submit(MCMD_WAR_DECLARE_FORCED, 1, forced),
                 "war.declare_forced accepted for a soldier-less country");
        ST_STEP(sim, sim.day + 1);
        ST_CHECK(sim.core.at_war(1, 0),
                 "soldier-less country is at war after a forced declaration");
    }
    hash_out = sim.core.state_hash();
    return true;
}
// --- 5..8. war -> engagement -> capture -> peace (cede + annex) -> PKMI -> ledger
bool test_war_peace_save(const MilitaryTerrainInput &t, std::string &report, uint64_t &hash_out) {
    Sim sim;
    ST_CHECK(sim.init(t, 777), "war sim init");
    const int32_t C = cell_at(13, 12);   // country 0, west neighbour of the enclave
    ST_CHECK(is_neighbor(t, C, kEnclave), "enclave adjacent to staging cell");
    {
        MilitaryCommand c;
        c.cell = C;
        c.unit_to = 0;
        ST_CHECK(sim.submit(MCMD_STATE_BUILD, 0, c), "state.build barracks C");
        MilitaryCommand target;
        target.value = 100;
        ST_CHECK(sim.submit(MCMD_FORCE_SET_TARGET, 0, target), "force.set_target 100");
    }
    ST_STEP(sim, 21);
    ST_CHECK(sim.core.country_soldiers(0) == 100, "staging garrison recruited");
    {
        MilitaryCommand c;
        c.cell = C;
        c.ints = {0, 100};
        ST_CHECK(sim.submit(MCMD_ARMY_CREATE, 0, c), "army.create at C");
        MilitaryCommand w;
        w.other = handle_for(2);
        ST_CHECK(sim.submit(MCMD_WAR_DECLARE, 0, w), "war.declare 0 -> 2");
    }
    ST_STEP(sim, sim.day + 1);
    ST_CHECK(sim.core.at_war(0, 2) && has_event(sim.core, MILITARY_EVENT_WAR_DECLARED), "war active + WAR_DECLARED event");
    const int32_t army = sim.army_of(0);
    ST_CHECK(army >= 0, "army exists");
    {
        MilitaryCommand c;
        c.army = sim.core.army_handle(army);
        c.cell = kEnclave;
        ST_CHECK(sim.submit(MCMD_ARMY_MOVE, 0, c), "army.move into enemy cell");
    }
    bool engaged = false;
    for (int32_t k = 0; k < 90 && sim.core.controller_of(kEnclave) != 0; ++k) {
        ST_STEP(sim, sim.day + 1);
        for (const MilitaryEngagement &e : sim.core.engagements()) engaged = engaged || e.active;
    }
    ST_CHECK(engaged, "movement into enemy cell opened an engagement");
    ST_CHECK(sim.core.controller_of(kEnclave) == 0, "capture: controller of enclave is the attacker");
    ST_CHECK(has_event(sim.core, MILITARY_EVENT_CELL_CONTROL_CHANGED), "CELL_CONTROL_CHANGED event emitted");
    ST_CHECK(sim.core.report().cells_captured > 0 || sim.core.control_revision() > 0, "control revision bumped");
    {
        MilitaryCommand formation;
        formation.op = MCMD_ARMY_CREATE;
        formation.country = handle_for(2);
        formation.cell = kEnclave;
        formation.value = 912;
        sim.core.apply_command(formation, sim.day);
        const auto rejected = sim.core.take_player_command_rejections();
        ST_CHECK(rejected.size() == 1 && rejected[0].caller_sequence == 912 &&
                     std::string(rejected[0].reason) == "cell_occupied",
                 "player formation: a foreign controller rejects a local order");
    }
    ST_STEP(sim, sim.day + 2);   // let run_wars record the full occupation
    // PKMI round trip mid-war (armies, engagements history, wars, events).
    {
        const std::vector<uint8_t> bytes = sim.core.encode();
        MilitaryCore copy;
        std::string error;
        copy.configure(make_catalog(), 777, error);
        copy.set_terrain(t, error);
        const bool ok = copy.restore(bytes.data(), bytes.size(), error);
        ST_CHECK(ok, std::string("PKMI restore ") + error);
        if (copy.state_hash() != sim.core.state_hash()) report += describe_diff(sim.core, copy);
        ST_CHECK(copy.state_hash() == sim.core.state_hash(), "PKMI restore -> identical state_hash");
        ST_CHECK(copy.encode() == bytes, "PKMI re-encode byte-identical");
    }
    std::vector<int32_t> ints = {MPEACE_CEDE_CELL, kEnclave, 0, MPEACE_ANNEX, 0, 0};
    std::vector<int64_t> longs = {0, 0};
    int32_t war_id = sim.core.war_between(0, 2);
    const MilitaryPeaceEvaluation ev = sim.core.evaluate_peace(war_id, handle_for(0), ints, longs);
    ST_CHECK(ev.valid && ev.willing_q16 >= ev.price_q16, "fully occupied enemy willing to accept cede+annex");
    {
        MilitaryCommand c;
        c.other = (uint64_t)(uint32_t)war_id;
        c.ints = ints;
        c.longs = longs;
        ST_CHECK(sim.submit(MCMD_PEACE_PROPOSE, 0, c), "peace.propose cede+annex");
    }
    ST_STEP(sim, sim.day + 1);
    bool cede = false, annex = false;
    for (const MilitaryIntent &in : sim.last) {
        if (in.kind == MILITARY_INTENT_TRANSFER_TERRITORY && in.cell == kEnclave && in.count == 1 &&
            in.country_b == handle_for(0))
            cede = true;
        if (in.kind == MILITARY_INTENT_ANNEX_COUNTRY && in.country_a == handle_for(2) && in.country_b == handle_for(0))
            annex = true;
    }
    ST_CHECK(cede && annex, "treaty emits TRANSFER_TERRITORY + ANNEX_COUNTRY intents the same day");
    ST_CHECK(!sim.core.at_war(0, 2) && has_event(sim.core, MILITARY_EVENT_WAR_ENDED) &&
                 has_event(sim.core, MILITARY_EVENT_COUNTRY_ANNEXED),
             "war closed, WAR_ENDED + COUNTRY_ANNEXED events");
    // Bridge applies the cession (D+1) the way Country would.
    sim.dg.cell_owner_slot[(size_t)kEnclave] = 0;
    sim.dg.country_handle[2] = 0;
    ST_STEP(sim, sim.day + 10);
    {
        std::string leak = "ledger reconcile_delta == 0 throughout the war run";
        if (sim.max_abs_reconcile != 0 || sim.core.report().reconcile_delta != 0) {
            leak += " (max=" + std::to_string(sim.max_abs_reconcile) +
                    " first_leak_day=" + std::to_string(sim.first_leak_day) +
                    " live=" + std::to_string(sim.core.report().reconcile_delta) +
                    " events=" + sim.first_leak_events + ")";
        }
        ST_CHECK(sim.max_abs_reconcile == 0 && sim.core.report().reconcile_delta == 0,
                 leak.c_str());
    }
    {
        const std::vector<uint8_t> bytes = sim.core.encode();
        MilitaryCore copy;
        std::string error;
        copy.configure(make_catalog(), 777, error);
        copy.set_terrain(t, error);
        ST_CHECK(copy.restore(bytes.data(), bytes.size(), error) && copy.state_hash() == sim.core.state_hash() &&
                     copy.encode() == bytes,
                 "PKMI round trip after peace");
    }
    hash_out = sim.core.state_hash();
    return true;
}
// --- 9. auto-discharge reconciled against a partially applied Economy move
// run_recruitment removes the surplus garrison heads when it emits the
// DISCHARGE intent; the receipt must then only put back the heads Economy did
// NOT move (requested - committed). A receipt that removed them a second time
// (or a core that ignored the shortfall) leaves Military and Economy unequal.
bool test_partial_discharge(const MilitaryTerrainInput &t, std::string &report) {
    Sim sim;
    ST_CHECK(sim.init(t, 5252), "partial discharge sim init");
    const int32_t C = cell_at(5, 5);
    {
        MilitaryCommand c;
        c.cell = C;
        c.unit_to = 0;
        ST_CHECK(sim.submit(MCMD_STATE_BUILD, 0, c), "partial discharge: barracks C");
        MilitaryCommand target;
        target.count = 0;
        target.value = 100;
        ST_CHECK(sim.submit(MCMD_FORCE_SET_TARGET, 0, target), "partial discharge: target 100");
        MilitaryCommand auto_discharge;
        auto_discharge.count = 1;
        ST_CHECK(sim.submit(MCMD_FORCE_SET_AUTO_DISCHARGE, 0, auto_discharge),
                 "partial discharge: auto discharge on");
    }
    ST_STEP(sim, 21);
    ST_CHECK(garrison_at(sim.core, C) == 100, "partial discharge: 100 soldiers at C");
    // Lower the target so the next sample day discharges 40 of them, and apply
    // only 25 of the 40 on the Economy side.
    {
        MilitaryCommand target;
        target.count = 0;
        target.value = 60;
        ST_CHECK(sim.submit(MCMD_FORCE_SET_TARGET, 0, target), "partial discharge: target 60");
    }
    int64_t discharged = 0, committed = 0;
    bool saw_discharge = false;
    for (int32_t k = 0; k < 6 && !saw_discharge; ++k) {
        sim.last.clear();
        sim.receipts.clear();
        sim.dg.day = sim.day;
        ST_CHECK(sim.core.step_day(sim.day, sim.dg, sim.receipts, sim.last, sim.error),
                 "partial discharge: step_day");
        ++sim.day;
        for (const MilitaryIntent &in : sim.last) {
            if (in.kind != MILITARY_INTENT_DISCHARGE) continue;
            saw_discharge = true;
            discharged += in.count;
            MilitaryIntentReceipt r;
            r.kind = in.kind;
            r.ok = 1;
            r.cell = in.cell;
            r.source_id = in.source_id;
            r.committed_count = in.count * 5 / 8;   // Economy moved 5/8 of the request
            committed += r.committed_count;
            sim.enlist_by_cell[(size_t)C] = std::max<int64_t>(0,
                sim.enlist_by_cell[(size_t)C] - r.committed_count);
            sim.dg.cell_soldiers[(size_t)C] = sim.enlist_by_cell[(size_t)C];
            sim.dg.cell_unemployed[(size_t)C] += r.committed_count;
            sim.receipts.push_back(r);
        }
    }
    ST_CHECK(saw_discharge && discharged == 40, "partial discharge: emitted for the 40 surplus");
    const int64_t after_emit = garrison_at(sim.core, C);
    ST_CHECK(after_emit == 60, "partial discharge: lots already removed when emitted");
    // Next day: the shortfall goes back and nothing is removed twice.
    sim.last.clear();
    sim.dg.day = sim.day;
    ST_CHECK(sim.core.step_day(sim.day, sim.dg, sim.receipts, sim.last, sim.error),
             "partial discharge: receipt day");
    ++sim.day;
    ST_CHECK(garrison_at(sim.core, C) == after_emit + (discharged - committed),
             "partial discharge: only the unmoved heads return");
    ST_CHECK(garrison_at(sim.core, C) == 75, "partial discharge: 60 + 15 unmoved = 75");
    ST_CHECK(sim.core.country_soldiers(0) == 75, "partial discharge: country roster equals the cohort");
    // A failed receipt for the whole request puts every head back.
    {
        MilitaryCommand target;
        target.count = 0;
        target.value = 40;
        ST_CHECK(sim.submit(MCMD_FORCE_SET_TARGET, 0, target), "partial discharge: target 40");
    }
    bool failed_receipt = false;
    for (int32_t k = 0; k < 8 && !failed_receipt; ++k) {
        sim.last.clear();
        sim.receipts.clear();
        sim.dg.day = sim.day;
        ST_CHECK(sim.core.step_day(sim.day, sim.dg, sim.receipts, sim.last, sim.error),
                 "partial discharge: second step_day");
        ++sim.day;
        for (const MilitaryIntent &in : sim.last) {
            if (in.kind != MILITARY_INTENT_DISCHARGE) continue;
            failed_receipt = true;
            MilitaryIntentReceipt r;
            r.kind = in.kind;
            r.ok = 0;
            r.cell = in.cell;
            r.source_id = in.source_id;
            r.committed_count = 0;
            sim.receipts.push_back(r);
        }
    }
    ST_CHECK(failed_receipt, "partial discharge: second discharge emitted");
    const int64_t before_fail = garrison_at(sim.core, C);
    int64_t failed_request = 0;
    for (const MilitaryIntentReceipt &r : sim.receipts)
        failed_request += (int64_t)((r.source_id >> 48) & 0xFFFFull);
    sim.last.clear();
    sim.dg.day = sim.day;
    ST_CHECK(sim.core.step_day(sim.day, sim.dg, sim.receipts, sim.last, sim.error),
             "partial discharge: failed receipt day");
    ++sim.day;
    ST_CHECK(failed_request > 0 && garrison_at(sim.core, C) == before_fail + failed_request,
             "partial discharge: a failed receipt refunds the whole request");
    return true;
}
#include "military_core_payroll_budget_selftest.inc"

// --- 10. AI agenda soak
bool test_ai(const MilitaryTerrainInput &t, std::string &report, uint64_t &hash_out, std::string &stats) {
    Sim sim;
    ST_CHECK(sim.init(t, 4242), "ai sim init");
    sim.dg.country_soldier_living_cost = {50000, 50000, 50000};
    // Revenue so the peace budget buys ~400 / ~250 / ~40 soldiers.
    const int64_t per_soldier = 65000;   // 1.3 x living cost
    sim.dg.country_annual_revenue = {400 * per_soldier * 365 * 10000 / 800, 250 * per_soldier * 365 * 10000 / 800,
                                     40 * per_soldier * 365 * 10000 / 800};
    for (int32_t s = 0; s < 3; ++s) sim.core.set_ai_country(s, true);
    ST_STEP(sim, 1500);
    const MilitaryCore &c = sim.core;
    bool modes = true, configs = true;
    for (int32_t s = 0; s < 3; ++s) {
        modes = modes && c.policies()[(size_t)s].target_mode == 1 && c.policies()[(size_t)s].effective_target > 0;
        int32_t share = 0;
        for (int32_t bp : c.policies()[(size_t)s].config_share_bp) share += bp;
        configs = configs && share == 10000;
    }
    ST_CHECK(modes, "AI set BUDGET force targets for every country");
    ST_CHECK(configs, "AI configured unit shares summing to 100%");
    ST_CHECK(c.policies()[1].config_share_bp[2] == 1000 && c.policies()[0].config_share_bp[2] == 0,
             "artillery 10% only where unlocked");
    int32_t barracks = 0;
    for (const MilitaryCellState &st : c.cell_states()) barracks += st.barracks_count[0];
    ST_CHECK(barracks > 0 && c.country_soldiers(0) > 0, "AI built barracks and recruited");
    // The upkeep bill is per country, so its `disrepair` verdict has to stay
    // inside that country. Two things are checked, because the old writer broke
    // both at once by walking every cell state inside the per-country loop:
    //  - a flagged cell must actually hold a state building. `upkeep` is only
    //    ever charged for standing barracks / fortification / college, so a flag
    //    on an empty cell is a bill with no building behind it.
    //  - the flag may only appear on cells the billing country owns.
    {
        bool scope_ok = true;
        for (const MilitaryCellState &st : c.cell_states()) {
            if (st.disrepair == 0) continue;
            bool has_building = st.fort_tier >= 0 || st.college_tier >= 0;
            for (int32_t tier = 0; tier < MILITARY_STATE_BARRACKS_TIERS && !has_building; ++tier)
                has_building = st.barracks_count[tier] > 0;
            if (!has_building) { scope_ok = false; break; }
            if (st.cell < 0 || (size_t)st.cell >= sim.dg.cell_owner_slot.size()) { scope_ok = false; break; }
            if (sim.dg.cell_owner_slot[(size_t)st.cell] < 0) { scope_ok = false; break; }
        }
        ST_CHECK(scope_ok, "disrepair only marks cells that hold a state building");
    }
    // The cache is a derived read, so a rebuild that disagrees with the ledger
    // would already have been counted here.
    ST_CHECK(c.report().state_cache_repairs == 0 && c.report().state_ledger_unmapped == 0 &&
                 c.report().state_role_mismatch == 0,
             "state building cache tracks the ledger with no divergence");
    int32_t wars = 0, ended = 0;
    for (const MilitaryWar &w : c.wars()) {
        ++wars;
        if (!w.active) ++ended;
    }
    char buf[256];
    std::snprintf(buf, sizeof(buf),
                  "ai: day=%lld soldiers=[%lld,%lld,%lld] targets=[%lld,%lld,%lld] barracks=%d wars=%d ended=%d "
                  "armies=%d events=%zu reconcile_max=%lld\n",
                  (long long)sim.day, (long long)c.country_soldiers(0), (long long)c.country_soldiers(1),
                  (long long)c.country_soldiers(2), (long long)c.policies()[0].effective_target,
                  (long long)c.policies()[1].effective_target, (long long)c.policies()[2].effective_target, barracks,
                  wars, ended, c.report().armies_active, c.events_after(0, 100000).size(),
                  (long long)sim.max_abs_reconcile);
    stats = buf;
    if (sim.first_leak_day >= 0)
        stats += "first_leak_day=" + std::to_string(sim.first_leak_day) + " events=" + sim.first_leak_events + "\n";
    ST_CHECK(sim.max_abs_reconcile == 0, "ledger reconcile_delta == 0 in AI soak | " + stats);
    hash_out = c.state_hash();
    return true;
}
#include "military_core_procurement_selftest.inc"
// --- 12. Water crossing (army-personnel contract 2 §2.1 / design §7.4).
// The synthetic map only wraps east-west, so a full-width water band cuts it in
// two and every land route between the shores has to cross the band. The band's
// landform decides WHICH water it is (lake / shallow / far / deep) and that is
// the only gate: the number of water cells in a row is irrelevant.
MilitaryTerrainInput make_hex_terrain_with_water_band(int32_t first_row, int32_t band,
                                                      uint8_t water_landform = 2) {
    MilitaryTerrainInput t = make_hex_terrain(kW, kH);
    for (int32_t c = 0; c < t.cell_count; ++c) {
        const int32_t row = c / kW;
        if (row < first_row || row >= first_row + band) continue;
        t.is_water[(size_t)c] = 1;
        t.has_river[(size_t)c] = 0;
        // Landform ids mirror scripts/geography/landform_type.gd: 0 deep ocean,
        // 1 ocean, 2 coast (shallow), 3 lake.
        t.landform[(size_t)c] = water_landform;
    }
    return t;
}
// Unlock bits: 0 = cannon (existing fixture), 1..4 = lake/shallow/far/deep
// water tiers (army-personnel contract 2 §2.2 catalog slots).
constexpr int32_t kLakeBit = 1;
constexpr int32_t kShallowBit = 2;
constexpr int32_t kFarBit = 3;
constexpr int32_t kDeepBit = 4;
constexpr uint64_t kLakeUnlock = 1ull << kLakeBit;
constexpr uint64_t kShallowUnlock = 1ull << kShallowBit;
constexpr uint64_t kFarUnlock = 1ull << kFarBit;
constexpr uint64_t kDeepUnlock = 1ull << kDeepBit;
constexpr uint8_t kLandformDeepOcean = 0;
constexpr uint8_t kLandformOcean = 1;
constexpr uint8_t kLandformCoast = 2;
constexpr uint8_t kLandformLake = 3;
MilitaryCatalog make_naval_catalog() {
    MilitaryCatalog c = make_catalog();
    c.unlock_count = 5;
    c.water_lake_bit = kLakeBit;
    c.water_shallow_bit = kShallowBit;
    c.water_far_bit = kFarBit;
    c.water_deep_bit = kDeepBit;
    return c;
}
// Digest over a water-band map: water is unowned (crossing it must not open an
// engagement) and country 0 carries exactly `unlock_bits`.
MilitaryWorldDigest make_naval_digest(const MilitaryTerrainInput &t, uint64_t unlock_bits) {
    MilitaryWorldDigest d = make_digest(t);
    for (int32_t c = 0; c < t.cell_count; ++c) {
        if (t.is_water[(size_t)c]) d.cell_owner_slot[(size_t)c] = -1;
    }
    d.country_unlock_bits.assign((size_t)d.country_capacity, 0ull);
    d.country_unlock_bits[0] = unlock_bits;
    return d;
}
#include "military_core_navigation_selftest.inc"
#include "military_core_performance_selftest.inc"
#include "military_core_flight_selftest.inc"
#include "military_core_front_selftest.inc"
#include "military_core_market_reuse_selftest.inc"
#include "military_core_payroll_selftest.inc"
} // namespace
bool MilitaryCore::self_test(std::string &report) {
    report.clear();
    const MilitaryTerrainInput t = make_hex_terrain(kW, kH);
    // Neighbour symmetry of the synthetic map (same convention as path TU).
    bool symmetric = true;
    for (int32_t c = 0; c < t.cell_count && symmetric; ++c) {
        for (int32_t d = 0; d < 6; ++d) {
            const int32_t nb = t.neighbors[(size_t)c * 6 + (size_t)d];
            if (nb >= 0 && t.neighbors[(size_t)nb * 6 + (size_t)((d + 3) % 6)] != c) symmetric = false;
        }
    }
    ST_CHECK(symmetric, "32x24 wrap hex map: neighbour table symmetric");
    {
        Sim sim;
        ST_CHECK(sim.init(t, 2526), "index continuation init");
        auto &c = sim.core;
        const int32_t cell = cell_at(5, 5);
        const int32_t old = c.lot_find_or_create(MILITARY_LOT_GARRISON, cell, 0, 0, 256);
        c._lots.count[(size_t)old] = 0;
        c._lots.active[(size_t)old] = 0;
        c._lots.free_list.push_back(old);
        const int32_t reused = c.lot_find_or_create(MILITARY_LOT_GARRISON, cell, 0, 0, 256);
        c._lots.count[(size_t)reused] = 3;
        ST_CHECK(reused == old && c._lots.active[(size_t)old] == 0,
            "inactive linked slot reuse keeps original mutation semantics");
        const auto bytes = c.encode();
        MilitaryCore copy;
        std::string error;
        ST_CHECK(copy.configure(make_catalog(), 2526, error) && copy.set_terrain(t, error) &&
            copy.restore(bytes.data(), bytes.size(), error), "index continuation restore");
        ST_CHECK(copy._lot_army_head == c._lot_army_head && copy._lot_cell_head == c._lot_cell_head &&
            copy._lot_next == c._lot_next && copy._lot_link_kind == c._lot_link_kind &&
            copy._lot_link_loc == c._lot_link_loc && copy._lots.active == c._lots.active &&
            copy._lots.location_kind == c._lots.location_kind && copy._lots.location == c._lots.location &&
            copy._lots.count == c._lots.count && copy._lots.country_slot == c._lots.country_slot &&
            copy._lots.unit_type == c._lots.unit_type && copy._lots.equip_quality_q8 == c._lots.equip_quality_q8 &&
            copy._lots.condition_q16 == c._lots.condition_q16 && copy._lots.free_list == c._lots.free_list &&
            copy._armies.generation == c._armies.generation && copy._army_lane_pending == c._army_lane_pending &&
            copy._armies.free_list == c._armies.free_list,
            "index heads next inactive payload and free-slot order match field by field");
        ST_CHECK(copy.present_for_cell(cell) == c.present_for_cell(cell) && copy.encode() == bytes,
            "index continuation query and bytes stable");
        c._lot_next[(size_t)old] = old;
        auto cycle = c.encode();
        ST_CHECK(!copy.restore(cycle.data(), cycle.size(), error) && copy.encode() == bytes,
            "cyclic index rejected without modifying live state");
        c._lot_next[(size_t)old] = -1;
        auto legacy = bytes;
        legacy[4] = 1;
        ST_CHECK(!copy.restore(legacy.data(), legacy.size(), error) &&
            error == (std::string("pkmi_version_mismatch_expected_") + std::to_string(PKMI_VERSION)), "PKMI v1 explicitly refused");
    }
    if (!test_performance_supply(t, report)) return false;
    if (!test_performance_engagements(t, report)) return false;
    if (!test_performance_battle_plan(t, report)) return false;
    if (!test_performance_flight_sums(report)) return false;
    if (!test_performance_front(t, report)) return false;
    if (!test_performance_garrison(t, report)) return false;
    if (!test_performance_garrison_candidates(t, report)) return false;
    if (!test_performance_market_reuse(t, report)) return false;
    if (!test_performance_direct_wars(t, report)) return false;
    if (!test_performance_payroll_wars(t, report)) return false;
    if (!test_idle(t, report)) return false;
    if (!test_barracks_capacity_scale(t, report)) return false;
    if (!test_convoy_escort_scale(t, report)) return false;
    uint64_t h1 = 0, h2 = 0, w1 = 0, w2 = 0, a1 = 0, a2 = 0;
    std::string stats, stats2;
    if (!test_recruit_and_move(t, report, h1)) return false;
    if (!test_war_peace_save(t, report, w1)) return false;
    if (!test_partial_discharge(t, report)) return false;
    if (!test_procurement(t, report)) return false;
    if (!test_maintenance(t, report)) return false;
    if (!test_army_pay(t, report)) return false;
    if (!test_budget_envelope(t, report)) return false;
    if (!test_procurement_quota(t, report)) return false;
    if (!test_cross_channel_conservation(t, report)) return false;
    if (!test_naval_transport(t, report)) return false;
    if (!test_exploration(t, report)) return false;
    if (!test_ai(t, report, a1, stats)) return false;
    report += stats;
    std::string ignored;
    if (!test_recruit_and_move(t, ignored, h2) || !test_war_peace_save(t, ignored, w2) ||
        !test_ai(t, ignored, a2, stats2)) {
        report += "FAIL determinism rerun\n" + ignored.substr(ignored.find("FAIL") == std::string::npos ? ignored.size() : ignored.find("FAIL"));
        return false;
    }
    ST_CHECK(h1 == h2 && w1 == w2 && a1 == a2, "determinism: two runs give identical state_hash");
    {
        char hb[160];
        std::snprintf(hb, sizeof(hb), "hashes: recruit=%016llx war=%016llx ai=%016llx\n", (unsigned long long)h1,
                      (unsigned long long)w1, (unsigned long long)a1);
        report += hb;
    }
    return true;
}
// ================================================================= bench
bool MilitaryCore::bench(int32_t cells, int32_t armies, int32_t engagements, int32_t days, double &avg_ms,
                         double &p95_ms, double &max_ms, std::string &report) {
    avg_ms = p95_ms = max_ms = 0.0;
    report.clear();
    if (cells < 64 || armies < 1 || days < 1) {
        report = "bench_bad_config";
        return false;
    }
    armies = std::min(armies, MILITARY_MAX_ARMIES);
    int32_t w = std::max<int32_t>(16, (int32_t)std::lround(std::sqrt((double)cells * 1.5)));
    w &= ~1;
    int32_t h = std::max<int32_t>(4, cells / w);
    const MilitaryTerrainInput t = make_hex_terrain(w, h);
    const int32_t n = t.cell_count;
    constexpr int32_t kCountries = 8;
    MilitaryCore core;
    std::string error;
    if (!core.configure(make_catalog(), 99, error) || !core.set_terrain(t, error)) {
        report = error;
        return false;
    }
    MilitaryWorldDigest d;
    d.country_capacity = kCountries;
    d.cell_owner_slot.assign((size_t)n, -1);
    for (int32_t c = 0; c < n; ++c) d.cell_owner_slot[(size_t)c] = ((c % w) * kCountries) / w;
    for (int32_t s = 0; s < kCountries; ++s) {
        d.country_handle.push_back(handle_for(s));
        d.country_cash.push_back(1000000000000ll);
        d.country_era.push_back(2);
        d.country_annual_revenue.push_back(0);
        d.country_capital_cell.push_back(-1);
        d.country_soldier_living_cost.push_back(10000);
        core.ensure_country_slot(handle_for(s));
    }
    d.cell_population.assign((size_t)n, 1000);
    d.cell_unemployed.assign((size_t)n, 100);
    d.cell_soldiers.assign((size_t)n, 0);
    d.cell_has_merchant.assign((size_t)n, 0);
    for (int32_t c = 0; c < n; c += 64) {
        d.cell_has_merchant[(size_t)c] = 1;
        d.market_cell.push_back(c);
        d.market_good.push_back(0);
        d.market_sellable.push_back(100000000);
        d.market_price.push_back(10000);
    }
    d.unlock_words = 1;
    d.country_unlock_bits.assign(kCountries, 1ull);
    d.day = 0;
    core._last_day = 0;
    core._last_digest = d;
    // Wars between stripe pairs (0,1) (2,3) ...
    for (int32_t p = 0; p < kCountries / 2; ++p) {
        MilitaryWar war;
        war.id = p + 1;
        war.attacker_slot = 2 * p;
        war.defender_slot = 2 * p + 1;
        war.attacker_handle = handle_for(2 * p);
        war.defender_handle = handle_for(2 * p + 1);
        war.start_day = 0;
        war.active = 1;
        core._wars.push_back(war);
    }
    const int32_t stripe = w / kCountries;
    std::vector<uint8_t> used((size_t)n, 0);
    uint64_t r = 0x1234567ull;
    auto next_rand = [&r]() { r = splitmix_final(r + 0x9e3779b97f4a7c15ull); return r; };
    auto pick_cell = [&](int32_t country, int32_t margin) -> int32_t {
        for (int32_t tries = 0; tries < 1000; ++tries) {
            const int32_t col = country * stripe + margin + (int32_t)(next_rand() % (uint64_t)std::max(1, stripe - 2 * margin));
            const int32_t row = 1 + (int32_t)(next_rand() % (uint64_t)std::max(1, h - 2));
            const int32_t c = row * w + col;
            if (c >= 0 && c < n && !used[(size_t)c] && d.cell_owner_slot[(size_t)c] == country) return c;
        }
        return -1;
    };
    auto spawn = [&](int32_t owner, int32_t cell, int64_t heads) -> int32_t {
        const int32_t a = core.create_army(owner, cell);
        if (a < 0) return -1;
        const int32_t lot = core.lot_find_or_create(MILITARY_LOT_ARMY, a, owner, 0, 256);
        core._lots.count[(size_t)lot] = heads;
        core.refresh_army_cache(a);
        used[(size_t)cell] = 1;
        return a;
    };
    int32_t attackers = std::min<int32_t>(armies / 2, (engagements + 5) / 6);
    if (engagements <= 0) attackers = 0;
    int32_t made_eng = 0, spawned = 0;
    std::vector<int32_t> att_cells;
    for (int32_t i = 0; i < attackers; ++i) {
        const int32_t pair = i % (kCountries / 2);
        const int32_t att = 2 * pair, def = att + 1;
        const int32_t cell = pick_cell(def, 2);
        if (cell < 0) break;
        // Keep the invader's ring free so its six edges stay distinct.
        bool clash = false;
        for (int32_t k = 0; k < 6; ++k) {
            const int32_t nb = t.neighbors[(size_t)cell * 6 + (size_t)k];
            if (nb < 0 || used[(size_t)nb] || d.cell_owner_slot[(size_t)nb] != def) clash = true;
        }
        if (clash) { --i; if (++spawned > 100000) break; continue; }
        const int32_t a = spawn(att, cell, 1000);
        if (a < 0) break;
        core.set_controller(cell, att);
        for (int32_t k = 0; k < 6; ++k) used[(size_t)t.neighbors[(size_t)cell * 6 + (size_t)k]] = 1;
        att_cells.push_back(cell);
        for (int32_t k = 0; k < 6 && made_eng < engagements; ++k) {
            core.open_engagement(cell, t.neighbors[(size_t)cell * 6 + (size_t)k], a, def);
            ++made_eng;
        }
    }
    attackers = (int32_t)att_cells.size();
    // Defenders on engaged far cells, then movers in their own territory.
    int32_t remaining = armies - attackers;
    int32_t defenders = 0;
    for (size_t i = 0; i < att_cells.size() && defenders < remaining / 2; ++i) {
        const int32_t far = t.neighbors[att_cells[i] * 6 + (size_t)(i % 6)];
        const int32_t a = core.create_army(d.cell_owner_slot[(size_t)far], far);
        if (a < 0) break;
        const int32_t lot = core.lot_find_or_create(MILITARY_LOT_ARMY, a, d.cell_owner_slot[(size_t)far], 1, 256);
        core._lots.count[(size_t)lot] = 800;
        core.refresh_army_cache(a);
        ++defenders;
    }
    int32_t movers = 0;
    std::vector<int32_t> mover_slot, mover_target;
    for (int32_t i = defenders + attackers; i < armies; ++i) {
        const int32_t owner = i % kCountries;
        const int32_t cell = pick_cell(owner, 1);
        if (cell < 0) break;
        const int32_t a = spawn(owner, cell, 500);
        if (a < 0) break;
        const int32_t row = cell / w;
        const int32_t trow = row + (row < h / 2 ? h / 3 : -h / 3);
        mover_slot.push_back(a);
        mover_target.push_back(std::max(0, std::min(h - 1, trow)) * w + (cell % w));
        ++movers;
    }
    // Paths: per-country daily budget (32) is spent in setup "days".
    int32_t pathed = 0;
    for (int32_t round = 0; round < 64 && pathed < movers; ++round) {
        for (int32_t &v : core._path_daily_requests) v = 0;
        for (int32_t i = 0; i < movers; ++i) {
            const size_t s = (size_t)mover_slot[(size_t)i];
            if (core._armies.path_len[s] > 0) continue;
            std::vector<int32_t> path;
            if (core.find_path(mover_slot[(size_t)i], mover_target[(size_t)i], d, path) && !path.empty()) {
                core.assign_path(mover_slot[(size_t)i], path);
                ++pathed;
            }
        }
    }
    std::vector<double> samples;
    std::vector<MilitaryIntent> intents;
    std::vector<MilitaryIntentReceipt> receipts;
    int64_t astar = 0, convoy_hops = 0, front = 0, intents_total = 0, threat = 0;
    int32_t max_eng = 0, max_moving = 0, captured = 0, battles = 0;
    constexpr size_t work_count = 29;
    int64_t work_total[work_count] = {}, work_first[work_count] = {};
    double stage_sum[MILITARY_STAGE_COUNT] = {}, stage_max[MILITARY_STAGE_COUNT] = {};
    const auto wall0 = std::chrono::steady_clock::now();
    for (int32_t day = 1; day <= days; ++day) {
        d.day = day;
        intents.clear();
        if (!core.step_day(day, d, receipts, intents, error)) {
            report = "bench_step_failed:" + error;
            return false;
        }
        const MilitaryReport &rep = core.report();
        const int64_t work[] = {
            rep.supply_ring_requests, rep.supply_ring_cache_hits,
            rep.supply_ring_centers_built, rep.supply_ring_cells_visited,
            rep.payroll_lots_visited, rep.payroll_holders_visited, rep.war_cells_visited,
            rep.engagement_index_slots_visited, rep.engagement_members_cleared,
            rep.front_position_lookups, rep.front_position_rows, rep.front_removal_fallback_rows,
            rep.garrison_queries, rep.garrison_lots_visited, rep.garrison_scan_fallbacks,
            rep.event_evictions, rep.event_index_rows_visited,
            rep.market_index_builds, rep.market_index_reuses, rep.market_index_cells,
            rep.procurement_garrison_links_visited, rep.procurement_garrison_heads_visited,
            rep.battle_plan_value_queries, rep.battle_plan_value_builds,
            rep.battle_plan_fort_queries, rep.battle_plan_fort_builds,
            rep.procurement_inflight_rows, rep.procurement_inflight_keys,
            rep.procurement_inflight_sort_fallbacks,
        };
        static_assert(sizeof(work) / sizeof(work[0]) == work_count);
        for (size_t i = 0; i < work_count; ++i) {
            work_total[i] += work[i];
            if (day == 1) work_first[i] = work[i];
        }
        samples.push_back(rep.day_ms);
        astar += rep.astar_expansions;
        convoy_hops += rep.convoy_hops;
        front += rep.front_edges_touched;
        threat += rep.threat_field_cells;
        intents_total += (int64_t)intents.size();
        max_eng = std::max(max_eng, rep.engagements_active);
        max_moving = std::max(max_moving, rep.armies_moving);
        captured += rep.cells_captured;
        const double *sm = military_stage_ms();
        for (int32_t k = 0; k < MILITARY_STAGE_COUNT; ++k) {
            stage_sum[k] += sm[k];
            stage_max[k] = std::max(stage_max[k], sm[k]);
        }
    }
    const double wall = std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - wall0).count();
    const uint64_t timed_hash = core.state_hash();
    // Stage profile from the timed days themselves (step_day laps).
    std::string profile = " | stages avg/max(ms):";
    {
        int32_t idx[MILITARY_STAGE_COUNT];
        for (int32_t i = 0; i < MILITARY_STAGE_COUNT; ++i) idx[i] = i;
        std::sort(idx, idx + MILITARY_STAGE_COUNT, [&](int32_t a, int32_t b) { return stage_sum[a] > stage_sum[b]; });
        char sb[96];
        for (int32_t i = 0; i < MILITARY_STAGE_COUNT; ++i) {
            std::snprintf(sb, sizeof(sb), " %s=%.3f/%.3f", military_stage_name(idx[i]), stage_sum[idx[i]] / days,
                          stage_max[idx[i]]);
            profile += sb;
        }
    }    battles = (int32_t)core.battle_log().size();
    std::vector<double> sorted = samples;
    std::sort(sorted.begin(), sorted.end());
    double sum = 0.0;
    for (double v : samples) sum += v;
    avg_ms = sum / (double)samples.size();
    max_ms = sorted.back();
    size_t p95 = (size_t)std::ceil(0.95 * (double)sorted.size());
    p95 = p95 == 0 ? 0 : p95 - 1;
    p95_ms = sorted[std::min(p95, sorted.size() - 1)];
    // The first day includes cold derived-index work. Keep it separate from
    // warmed daily cost without changing the existing acceptance percentile.
    {
        std::vector<double> warm(samples.begin() + 1, samples.end());
        std::sort(warm.begin(), warm.end());
        double warm_sum = 0.0;
        for (double value : warm) warm_sum += value;
        size_t warm_p95 = warm.empty() ? 0 : (size_t)std::ceil(0.95 * (double)warm.size()) - 1;
        char cold[160];
        std::snprintf(cold, sizeof(cold), " | first_day=%.3fms warm_avg=%.3fms warm_p95=%.3fms warm_max=%.3fms",
                      samples.front(), warm.empty() ? 0.0 : warm_sum / warm.size(),
                      warm.empty() ? 0.0 : warm[warm_p95], warm.empty() ? 0.0 : warm.back());
        profile += cold;
    }
    char buf[640];
    std::snprintf(buf, sizeof(buf),
                  "cells=%d (%dx%d) armies=%d (att=%d def=%d movers=%d pathed=%d) engagements=%d days=%d | "
                  "avg=%.3fms p95=%.3fms max=%.3fms wall=%.1fms | max_engaged=%d max_moving=%d astar=%lld "
                  "threat_cells/day=%lld convoy_hops=%lld front_touched=%lld captured=%d intents=%lld "
                  "battle_log=%d reconcile=%lld",
                  n, w, h, attackers + defenders + movers, attackers, defenders, movers, pathed, made_eng, days, avg_ms,
                  p95_ms, max_ms, wall, max_eng, max_moving, (long long)astar, (long long)(threat / days),
                  (long long)convoy_hops, (long long)front, captured, (long long)intents_total, battles,
                  (long long)core.report().reconcile_delta);
    report = buf + profile;
    {
        static const char *names[] = {
            "ring_requests", "ring_hits", "ring_centers", "ring_cells",
            "payroll_lots", "payroll_holders", "war_cells", "engagement_index_slots",
            "engagement_members",
            "front_lookups", "front_position_rows", "front_fallback_rows",
            "garrison_queries", "garrison_lots", "garrison_fallbacks",
            "event_evictions", "event_index_rows",
            "market_builds", "market_reuses", "market_cells", "garrison_link_candidates",
            "garrison_head_candidates",
            "battle_value_queries", "battle_value_builds", "battle_fort_queries", "battle_fort_builds",
            "inflight_rows", "inflight_keys", "inflight_sort_fallbacks",
        };
        report += " | work total/first:";
        static_assert(sizeof(names) / sizeof(names[0]) == work_count);
        for (size_t i = 0; i < work_count; ++i)
            report += " " + std::string(names[i]) + "=" + std::to_string(work_total[i]) +
                      "/" + std::to_string(work_first[i]);
    }
    {
        char hb[96];
        std::snprintf(hb, sizeof(hb), " | hash_timed=%016llx hash_end=%016llx", (unsigned long long)timed_hash,
                      (unsigned long long)core.state_hash());
        report += hb;
    }
    return true;
}
} // namespace pk
